import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../handler/chacha20_poly1305.dart';
import '../handler/encoder.dart';
import '../handler/logger.dart';
import '../model/data_store_config.dart';
import '../model/key_migration_info.dart';
import '../model/space_config.dart';
import 'data_store_impl.dart';
import 'key_migration_progress.dart';
import 'key_migration_runner.dart';

/// Manages the logic for migrating encryption keys.
/// When the encryptionKey in DataStoreConfig changes,
/// it reads the old key (through the StorageAdapter interface, i.e., DataStoreImpl.storage),
/// encrypts the current encryptionKey using ChaCha20Poly1305, and saves it to the key file.
/// It also performs data migration (calls EncoderHandler to re-encode/decode data files).
class KeyManager {
  final DataStoreImpl _dataStore;

  // Cached generated keys from encryption config
  String? _cachedEncodingKey;
  String? _cachedEncryptionKey;
  bool _keyMigrationScheduled = false;
  Future<void>? _keyMigrationFuture;
  KeyChangeInfo? _deferredKeyChangeInfo;

  KeyManager(DataStoreImpl dataStore) : _dataStore = dataStore;

  /// Get effective encryption config (use default if not provided)
  EncryptionConfig _getEncryptionConfig() {
    final config = _dataStore.config;
    return config.encryptionConfig ?? const EncryptionConfig();
  }

  /// Get effective encryption key
  String _getEncryptionKey() {
    if (_cachedEncryptionKey != null) {
      return _cachedEncryptionKey!;
    }

    final encryptionConfig = _getEncryptionConfig();
    // Use instancePath (final resolved path) instead of config.dbPath which may be null
    final dbPath = _dataStore.instancePath ?? _dataStore.config.dbPath;
    _cachedEncryptionKey = encryptionConfig.generateEncryptionKey(dbPath);
    return _cachedEncryptionKey!;
  }

  /// Get effective encoding key
  String _getEncodingKey() {
    if (_cachedEncodingKey != null) {
      return _cachedEncodingKey!;
    }

    final encryptionConfig = _getEncryptionConfig();
    // Use instancePath (final resolved path) instead of config.dbPath which may be null
    final dbPath = _dataStore.instancePath ?? _dataStore.config.dbPath;
    _cachedEncodingKey = encryptionConfig.generateEncodingKey(dbPath);
    return _cachedEncodingKey!;
  }

  /// Get effective encryption type
  EncryptionType _getEncryptionType() {
    return _getEncryptionConfig().encryptionType;
  }

  /// Generate AAD (Additional Authenticated Data) for key encryption
  /// This prevents key reuse across different databases or key versions
  Uint8List _generateAAD(int keyId) {
    // This ensures AAD is deterministic and verifiable
    final aadString = 'keyId:$keyId';
    return Uint8List.fromList(utf8.encode(aadString));
  }

  /// Encrypt a plain key using the encryption key from config
  /// AAD includes dbPath and keyId to ensure key is bound to specific database instance and version
  String _encryptKey(String plainKey, int keyId) {
    final encryptionKey = _getEncryptionKey();
    final aad = _generateAAD(keyId);
    final encryptedBytes = ChaCha20Poly1305.encrypt(
      plaintext: plainKey,
      key: ChaCha20Poly1305.generateKeyFromString(encryptionKey),
      aad: aad,
    );
    return base64.encode(encryptedBytes);
  }

  /// Decode an encrypted key
  /// Supports backward compatibility: tries with AAD first, then without AAD if keyId is not provided
  dynamic _decodeKey(String encodedKey, int keyId, {bool isPlaintext = false}) {
    try {
      final encryptionKey = _getEncryptionKey();
      final encodedBytes = base64.decode(encodedKey);

      final aad = _generateAAD(keyId);
      final decrypted = ChaCha20Poly1305.decrypt(
        encryptedData: encodedBytes,
        key: ChaCha20Poly1305.generateKeyFromString(encryptionKey),
        aad: aad,
      );
      if (isPlaintext) {
        return decrypted;
      }
      return EncoderHandler.generateKey(decrypted);
    } catch (e) {
      return null;
    }
  }

  /// initialize KeyManager and start key migration process
  Future<void> initialize() async {
    // Generate keys from encryption config
    // This ensures keys are available for the rest of initialization
    _getEncodingKey();
    _getEncryptionKey();

    // Set EncoderHandler encryption type
    EncoderHandler.setEncryptionType(_getEncryptionType());

    // Try to get existing space configuration to determine the correct keyId
    SpaceConfig? spaceConfig = await _dataStore.getSpaceConfig();

    if (spaceConfig == null) {
      spaceConfig = await createKeySpaceConfig();
      await _dataStore.saveSpaceConfigToFile(spaceConfig);
    }

    // Set EncoderHandler's encoding configuration and keys first
    KeyChangeInfo? keyChangeInfo;
    try {
      // This will handle key comparison and setup fallback keys including new key if changed
      keyChangeInfo = await updateEncoderHandlerKeys(spaceConfig);
    } catch (e) {
      Logger.error(
        'Failed to set Encoder key: $e',
        label: 'KeyManager.initialize',
      );
    }

    if (_dataStore.isMigrationInstance) {
      return;
    }

    if (keyChangeInfo?.hasChanged == true) {
      _deferredKeyChangeInfo = keyChangeInfo;
    }
  }

  /// Start or resume key migration after [MigrationManager.initialize] has recovered schema tasks.
  Future<void> startDeferredKeyMigrationWork() async {
    if (_dataStore.isMigrationInstance) return;

    final pendingChange = _deferredKeyChangeInfo;
    _deferredKeyChangeInfo = null;

    if (pendingChange != null) {
      await _beginKeyMigration(pendingChange);
    } else {
      await _resumeKeyMigrationIfNeeded();
    }
  }

  Future<KeyChangeInfo?> updateEncoderHandlerKeys(
      SpaceConfig spaceConfig) async {
    final newKey = _getEncodingKey();
    final fallbackKeys = <int, Uint8List>{};

    // Add current key to fallback keys
    final currentDecodedKey =
        _decodeKey(spaceConfig.current.key, spaceConfig.current.keyId);
    if (currentDecodedKey != null) {
      fallbackKeys[spaceConfig.current.keyId] = currentDecodedKey;
    }

    // Add previous key to fallback keys if exists
    if (spaceConfig.previous != null && spaceConfig.previous!.key.isNotEmpty) {
      final previousDecodedKey =
          _decodeKey(spaceConfig.previous!.key, spaceConfig.previous!.keyId);
      if (previousDecodedKey != null) {
        fallbackKeys[spaceConfig.previous!.keyId] = previousDecodedKey;
      }
    }

    // Add history keys to fallback keys
    for (final hist in spaceConfig.historyKeys) {
      if (hist.key.isEmpty) continue;
      final decoded = _decodeKey(hist.key, hist.keyId);
      if (decoded != null) {
        fallbackKeys[hist.keyId] = decoded;
      }
    }

    String? currentPlain;
    if (spaceConfig.current.key.isNotEmpty) {
      try {
        currentPlain = _decodeKey(
          spaceConfig.current.key,
          spaceConfig.current.keyId,
          isPlaintext: true,
        );
      } catch (e) {
        Logger.error('Failed to decrypt current key: $e');
      }
    }

    final bool keyChanged = currentPlain != newKey;
    int keyIdToUse = spaceConfig.current.keyId;
    KeyChangeInfo? keyChangeInfo;

    if (keyChanged && newKey.isNotEmpty) {
      // Key has changed, add new key to fallback keys with incremented keyId
      final newKeyId = spaceConfig.current.keyId + 1;
      final newDecodedKey = EncoderHandler.generateKey(newKey);
      fallbackKeys[newKeyId] = newDecodedKey;
      keyIdToUse = newKeyId;
      Logger.info(
        'Encoding key changed, preparing async migration with new keyId: $newKeyId',
        label: 'KeyManager.updateEncoderHandlerKeys',
      );
      keyChangeInfo = KeyChangeInfo(
        hasChanged: true,
        newKey: newDecodedKey,
        newKeyId: newKeyId,
        encryptKey: _encryptKey(newKey, newKeyId),
      );
    }

    EncoderHandler.setFallbackKeys(fallbackKeys);

    final encryptionType = _getEncryptionType();
    if (encryptionType != EncryptionType.none && newKey.isNotEmpty) {
      EncoderHandler.setCurrentKey(newKey, keyIdToUse);
    }

    return keyChangeInfo;
  }

  // when spaceConfig is null,then create key spaceConfig
  Future<SpaceConfig> createKeySpaceConfig() async {
    final newKey = _getEncodingKey();
    try {
      if (newKey.isNotEmpty) {
        // Use keyId 1 for initial key creation
        final encryptedKey = _encryptKey(newKey, 1);
        return SpaceConfig(
          current: EncryptionKeyInfo(key: encryptedKey, keyId: 1),
          previous: null,
          version: 0,
        );
      }
      Logger.info(
        'No encoding key provided; creating space config with an empty key.',
      );
      return SpaceConfig(
        current: const EncryptionKeyInfo(key: '', keyId: 0),
        previous: null,
        version: 0,
      );
    } catch (e) {
      Logger.error(
        'Failed to create or encrypt key during first-time initialization: $e',
      );
      return SpaceConfig(
        current: const EncryptionKeyInfo(key: '', keyId: 0),
        previous: null,
        version: 0,
      );
    }
  }

  Future<void> _beginKeyMigration(KeyChangeInfo info) async {
    final migrationManager = _dataStore.migrationManager;
    if (migrationManager == null) return;

    final existing = await migrationManager.getKeyMigrationInfo();
    if (existing != null && existing.isRunning) {
      if (existing.targetKeyId != info.newKeyId) {
        await _supersedeKeyMigration(info);
        return;
      }
      _scheduleKeyMigrationRun(info);
      return;
    }

    await migrationManager.persistKeyMigrationInfo(
      KeyMigrationInfo(
        targetKeyId: info.newKeyId,
        status: KeyMigrationStatus.running,
        createdAt: DateTime.now().toIso8601String(),
      ),
    );
    _scheduleKeyMigrationRun(info);
  }

  Future<void> _resumeKeyMigrationIfNeeded() async {
    final migrationManager = _dataStore.migrationManager;
    if (migrationManager == null) return;

    final info = await migrationManager.getKeyMigrationInfo();
    if (info == null || !info.isRunning) return;

    if (info.targetKeyId != EncoderHandler.getCurrentKeyId()) {
      Logger.warn(
        'Stale key migration meta (targetKeyId=${info.targetKeyId}, '
        'current=${EncoderHandler.getCurrentKeyId()}); abandoning resume',
        label: 'KeyManager._resumeKeyMigrationIfNeeded',
      );
      return;
    }

    final resumeInfo = _buildKeyChangeInfoForKeyId(info.targetKeyId);
    if (resumeInfo == null) {
      Logger.error(
        'Cannot resume key migration: failed to rebuild KeyChangeInfo',
        label: 'KeyManager._resumeKeyMigrationIfNeeded',
      );
      return;
    }

    Logger.info(
      'Resuming key migration for keyId ${info.targetKeyId}',
      label: 'KeyManager._resumeKeyMigrationIfNeeded',
    );
    _scheduleKeyMigrationRun(resumeInfo);
  }

  Future<void> _supersedeKeyMigration(KeyChangeInfo info) async {
    final spaceConfig = await _dataStore.getSpaceConfig();
    final migrationManager = _dataStore.migrationManager;
    if (spaceConfig == null || migrationManager == null) return;

    final history = [...spaceConfig.historyKeys];
    void addIfAbsent(EncryptionKeyInfo keyInfo) {
      if (keyInfo.key.isEmpty) return;
      if (history.any((k) => k.keyId == keyInfo.keyId)) return;
      history.add(keyInfo);
    }

    addIfAbsent(spaceConfig.current);
    if (spaceConfig.previous != null) {
      addIfAbsent(spaceConfig.previous!);
    }

    await _dataStore.saveSpaceConfigToFile(
      spaceConfig.copyWith(historyKeys: history),
    );
    await updateEncoderHandlerKeys(
      (await _dataStore.getSpaceConfig()) ?? spaceConfig,
    );

    await KeyMigrationProgressStore.clearAll(_dataStore);
    await migrationManager.clearKeyMigrationInfo();
    await migrationManager.persistKeyMigrationInfo(
      KeyMigrationInfo(
        targetKeyId: info.newKeyId,
        status: KeyMigrationStatus.running,
        createdAt: DateTime.now().toIso8601String(),
      ),
    );
    _scheduleKeyMigrationRun(info);
  }

  KeyChangeInfo? _buildKeyChangeInfoForKeyId(int keyId) {
    final plain = _getEncodingKey();
    if (plain.isEmpty) return null;
    return KeyChangeInfo(
      hasChanged: true,
      newKey: EncoderHandler.generateKey(plain),
      newKeyId: keyId,
      encryptKey: _encryptKey(plain, keyId),
    );
  }

  /// Cooperative pause for close / switchSpace; retains checkpoint for resume.
  Future<void> pauseKeyMigration({
    Duration timeout = const Duration(seconds: 120),
  }) async {
    KeyMigrationRunner.requestPause();
    final future = _keyMigrationFuture;
    if (future == null) return;
    try {
      await future.timeout(timeout);
    } on TimeoutException {
      Logger.warn(
        'Key migration did not stop within ${timeout.inSeconds}s; '
        'forcing shutdown flush',
        label: 'KeyManager.pauseKeyMigration',
      );
      await KeyMigrationRunner.pauseForShutdown(_dataStore);
    } catch (_) {}
  }

  void _scheduleKeyMigrationRun(KeyChangeInfo info) {
    if (_keyMigrationScheduled) return;
    _keyMigrationScheduled = true;
    Logger.info(
      'Scheduling background key migration for keyId ${info.newKeyId}',
      label: 'KeyManager._scheduleKeyMigrationRun',
    );
    unawaited(_keyMigrationFuture = _runKeyMigration(info));
  }

  Future<void> _runKeyMigration(KeyChangeInfo info) async {
    try {
      await KeyMigrationRunner.run(
        _dataStore,
        targetKeyId: info.newKeyId,
        keyChangeInfo: info,
      );
    } finally {
      _keyMigrationScheduled = false;
      _keyMigrationFuture = null;
    }
  }
}
