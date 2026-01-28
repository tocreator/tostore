import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../model/data_store_config.dart';
import 'data_store_impl.dart';
import '../handler/chacha20_poly1305.dart';
import '../handler/logger.dart';
import '../handler/encoder.dart';
import '../model/space_config.dart';
import '../model/system_table.dart';

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
        aad: aad);
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
          aad: aad);
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
      Logger.error('Failed to set Encoder key: $e',
          label: 'KeyManager.initialize');
    }

    // trigger key migration after setting up keys, pass the key change info to avoid redundant work
    // If it is a migration instance, we skip the internal key migration as it will be handled by V2Upgrade
    await migrateKey(keyChangeInfo,
        skipMigration: _dataStore.isMigrationInstance);
  }

  /// Update EncoderHandler with current and fallback keys
  /// This method also checks if the encoding key has changed and prepares for migration
  /// Returns KeyChangeInfo containing information about key changes
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

    // Check if encoding key has changed
    String? currentPlain;
    if (spaceConfig.current.key.isNotEmpty) {
      try {
        currentPlain = _decodeKey(
            spaceConfig.current.key, spaceConfig.current.keyId,
            isPlaintext: true);
      } catch (e) {
        Logger.error('Failed to decrypt current key: $e');
      }
    }

    bool keyChanged = currentPlain != newKey;
    int keyIdToUse = spaceConfig.current.keyId;
    KeyChangeInfo? keyChangeInfo;

    if (keyChanged && newKey.isNotEmpty) {
      // Key has changed, add new key to fallback keys with incremented keyId
      final newKeyId = spaceConfig.current.keyId + 1;
      final newDecodedKey = EncoderHandler.generateKey(newKey);
      fallbackKeys[newKeyId] = newDecodedKey;
      keyIdToUse = newKeyId;
      Logger.info(
          'Encoding key changed, preparing for migration with new keyId: $newKeyId');

      // Create key change info for migration
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
            version: 0);
      } else {
        // If no key is provided, still create a valid config with an empty key.
        Logger.info(
            'No encoding key provided; creating space config with an empty key.');
        return SpaceConfig(
            current: const EncryptionKeyInfo(key: '', keyId: 0),
            previous: null,
            version: 0);
      }
    } catch (e) {
      Logger.error(
          'Failed to create or encrypt key during first-time initialization: $e');
      // Return a default empty config on error to allow the app to proceed.
      return SpaceConfig(
          current: const EncryptionKeyInfo(key: '', keyId: 0),
          previous: null,
          version: 0);
    }
  }

  /// Compares the encryptionKey in the configuration with the saved old key.
  /// If they are not the same, it performs data migration, encrypts the current key,
  /// and replaces the content in the key file.
  Future<void> migrateKey(KeyChangeInfo? keyChangeInfo,
      {bool skipMigration = false}) async {
    // If no key change info provided or no changes detected, skip migration
    if (keyChangeInfo == null || !keyChangeInfo.hasChanged) {
      return;
    }

    // Load space configuration from cache or file
    SpaceConfig? spaceConfig = await _dataStore.getSpaceConfig();
    if (spaceConfig == null) {
      Logger.error('Space config not found during migration');
      return;
    }

    if (!skipMigration) {
      Logger.info('Encoding key has changed. Starting data migration...');
      try {
        await _migrateData(keyChangeInfo.newKey, keyChangeInfo.newKeyId);
      } catch (e) {
        Logger.error('Key data migration failed: $e');
        return;
      }
    }

    // After successful migration, update init config by shifting current to previous and setting new key with incremented keyId
    try {
      await _dataStore.saveSpaceConfigToFile(
        spaceConfig.copyWith(
          current: EncryptionKeyInfo(
              key: keyChangeInfo.encryptKey, keyId: keyChangeInfo.newKeyId),
          previous:
              spaceConfig.current, // Move current key to previous position
        ),
      );
    } catch (e) {
      Logger.error('Failed to update the init file after migration: $e');
    }
    Logger.info(
        'Encoding key change and data migration completed successfully');
  }

  /// Data migration logic
  Future<void> _migrateData(Uint8List newKey, int newKeyId) async {
    final tableNames = await _dataStore.getTableNames();

    for (final tableName in tableNames) {
      // Concurrent partition processing interface
      await _dataStore.tableDataManager.processTablePartitions(
        tableName: tableName,
        processFunction: (records, partitionIndex, controller) async {
          return records;
        },
        customKey: newKey,
        customKeyId: newKeyId,
      );

      // Only log migration completion for user tables, not system tables
      if (!SystemTable.isSystemTable(tableName)) {
        Logger.info('Migration complete for table: $tableName');
      }
    }
  }
}

/// Information about key changes during initialization
class KeyChangeInfo {
  final bool hasChanged;
  final Uint8List newKey; // Key that can directly decode data
  final int newKeyId;
  final String encryptKey; // The encrypted key used for storage

  KeyChangeInfo({
    required this.hasChanged,
    required this.newKey,
    required this.newKeyId,
    required this.encryptKey,
  });
}
