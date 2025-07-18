import 'dart:async';
import 'dart:convert';

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

  KeyManager(DataStoreImpl dataStore) : _dataStore = dataStore;

  /// Encrypt a plain key using the encryption key from config
  String _encryptKey(String plainKey) {
    final encryptedBytes = ChaCha20Poly1305.encrypt(
        plaintext: plainKey,
        key: ChaCha20Poly1305.generateKeyFromString(
            _dataStore.config.encryptionKey));
    return base64.encode(encryptedBytes);
  }

  dynamic _decodeKey(String encodedKey, {bool isPlaintext = false}) {
    try {
      final encodedBytes = base64.decode(encodedKey);
      final decrypted = ChaCha20Poly1305.decrypt(
          encryptedData: encodedBytes,
          key: ChaCha20Poly1305.generateKeyFromString(
              _dataStore.config.encryptionKey));
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
    // Set EncoderHandler encoding configuration
    EncoderHandler.setEncodingConfig(
      enableEncoding: _dataStore.config.enableEncoding,
      enableObfuscation: _dataStore.config.enableEncodingObfuscation,
    );

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
      keyChangeInfo = await _updateEncoderHandlerKeys(spaceConfig);
    } catch (e) {
      Logger.error('Failed to set Encoder key: $e',
          label: 'KeyManager.initialize');
    }

    // trigger key migration after setting up keys, pass the key change info to avoid redundant work
    await migrateKey(keyChangeInfo);
  }

  /// Update EncoderHandler with current and fallback keys
  /// This method also checks if the encoding key has changed and prepares for migration
  /// Returns KeyChangeInfo containing information about key changes
  Future<KeyChangeInfo?> _updateEncoderHandlerKeys(
      SpaceConfig spaceConfig) async {
    final newKey = _dataStore.config.encodingKey;
    final fallbackKeys = <int, List<int>>{};

    // Add current key to fallback keys
    final currentDecodedKey = _decodeKey(spaceConfig.current.key);
    if (currentDecodedKey != null) {
      fallbackKeys[spaceConfig.current.keyId] = currentDecodedKey;
    }

    // Add previous key to fallback keys if exists
    if (spaceConfig.previous != null && spaceConfig.previous!.key.isNotEmpty) {
      final previousDecodedKey = _decodeKey(spaceConfig.previous!.key);
      if (previousDecodedKey != null) {
        fallbackKeys[spaceConfig.previous!.keyId] = previousDecodedKey;
      }
    }

    // Check if encoding key has changed
    String? currentPlain;
    if (spaceConfig.current.key.isNotEmpty) {
      try {
        currentPlain = _decodeKey(spaceConfig.current.key, isPlaintext: true);
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
        encryptKey: _encryptKey(newKey),
      );
    }

    EncoderHandler.setFallbackKeys(fallbackKeys);

    if (_dataStore.config.enableEncoding && newKey.isNotEmpty) {
      EncoderHandler.setCurrentKey(newKey, keyIdToUse);
    }

    return keyChangeInfo;
  }

  // when spaceConfig is null,then create key spaceConfig
  Future<SpaceConfig> createKeySpaceConfig() async {
    final newKey = _dataStore.config.encodingKey;
    try {
      if (newKey.isNotEmpty) {
        final encryptedKey = _encryptKey(newKey);
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
  Future<void> migrateKey(KeyChangeInfo? keyChangeInfo) async {
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

    Logger.info('Encoding key has changed. Starting data migration...');
    try {
      await _migrateData(keyChangeInfo.newKey, keyChangeInfo.newKeyId);
    } catch (e) {
      Logger.error('Key data migration failed: $e');
      return;
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
  Future<void> _migrateData(List<int> newKey, int newKeyId) async {
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
  final List<int> newKey; // Key that can directly decode data
  final int newKeyId;
  final String encryptKey; // The encrypted key used for storage

  KeyChangeInfo({
    required this.hasChanged,
    required this.newKey,
    required this.newKeyId,
    required this.encryptKey,
  });
}
