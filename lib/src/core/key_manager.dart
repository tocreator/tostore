import 'dart:async';
import 'dart:convert';

import 'data_store_impl.dart';
import '../handler/chacha20_poly1305.dart';
import '../handler/logger.dart';
import '../handler/encoder.dart';
import '../model/space_config.dart';

/// Manages the logic for migrating encryption keys.
/// When the encryptionKey in DataStoreConfig changes,
/// it reads the old key (through the StorageAdapter interface, i.e., DataStoreImpl.storage),
/// encrypts the current encryptionKey using ChaCha20Poly1305, and saves it to the key file.
/// It also performs data migration (calls EncoderHandler to re-encode/decode data files).
class KeyManager {
  final DataStoreImpl _dataStore;

  KeyManager(DataStoreImpl dataStore) : _dataStore = dataStore {
    // Set fallbackKeyProvider to retrieve the encryption key corresponding to a given keyId from the key file.
    // The key file is expected to be a JSON object with "current" and optionally "previous" keys.
    EncoderHandler.fallbackKeyProvider = (int keyId) async {
      try {
        final spaceConfig = await _dataStore.getSpaceConfig();
        if (spaceConfig != null) {
          // Exact match for the requested keyId
          if (spaceConfig.current.keyId == keyId) {
            return _decodeKey(spaceConfig.current.key);
          }
          if (spaceConfig.previous?.keyId == keyId) {
            return _decodeKey(spaceConfig.previous!.key);
          }
        }
      } catch (e) {
        Logger.error("Error retrieving key: $e",
            label: 'KeyManager.fallbackKeyProvider');
      }
      return null;
    };
  }

  List<int>? _decodeKey(String encodedKey) {
    try {
      final encodedBytes = base64.decode(encodedKey);
      final decrypted = ChaCha20Poly1305.decrypt(
          encryptedData: encodedBytes,
          key: ChaCha20Poly1305.generateKeyFromString(
              _dataStore.config.encryptionKey));
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

    // Directly set EncoderHandler's default key to the encodingKey in the configuration
    if (_dataStore.config.enableEncoding &&
        _dataStore.config.encodingKey.isNotEmpty) {
      try {
        final encodingKey = _dataStore.config.encodingKey;

        // Try to get existing space configuration to determine the correct keyId
        SpaceConfig? spaceConfig = await _dataStore.getSpaceConfig();
        int keyId = 1; // Default value is 1 (first-time initialization)

        if (spaceConfig != null && spaceConfig.current.keyId > 0) {
          // If there's an existing configuration, use the existing keyId
          keyId = spaceConfig.current.keyId;
        }

        // Set both the key and key ID at the same time
        EncoderHandler.setCurrentKey(encodingKey, keyId);
      } catch (e) {
        Logger.error('Failed to set EncoderHandler key: $e');
      }
    }

    // trigger key migration
    await migrateKey();
  }

  // when spaceConfig is null,then create key spaceConfig
  Future<SpaceConfig> createKeySpaceConfig() async {
    final newKey = _dataStore.config.encodingKey;
    try {
      if (newKey.isNotEmpty) {
        final encryptedBytes = ChaCha20Poly1305.encrypt(
            plaintext: newKey,
            key: ChaCha20Poly1305.generateKeyFromString(
                _dataStore.config.encryptionKey));
        final encryptedBase64 = base64.encode(encryptedBytes);
        return SpaceConfig(
            current: EncryptionKeyInfo(key: encryptedBase64, keyId: 1),
            previous: null,
            version: 0);
      } else {
        // If no key is provided, still create a valid config with an empty key.
        Logger.info(
            'No encoding key provided; creating space config with an empty key.');
        return SpaceConfig(
            current: const EncryptionKeyInfo(key: '', keyId: 1),
            previous: null,
            version: 0);
      }
    } catch (e) {
      Logger.error(
          'Failed to create or encrypt key during first-time initialization: $e');
      // Return a default empty config on error to allow the app to proceed.
      return SpaceConfig(
          current: const EncryptionKeyInfo(key: '', keyId: 1),
          previous: null,
          version: 0);
    }
  }

  /// Compares the encryptionKey in the configuration with the saved old key.
  /// If they are not the same, it performs data migration, encrypts the current key,
  /// and replaces the content in the key file.
  Future<void> migrateKey() async {
    final newKey = _dataStore.config.encodingKey; // may be null

    // Load space configuration from cache or file
    SpaceConfig? spaceConfig = await _dataStore.getSpaceConfig();

    // First-time initialization: if no space config available, store new key as current with keyId 1
    if (spaceConfig == null) {
      final spaceConfig = await createKeySpaceConfig();
      await _dataStore.saveSpaceConfigToFile(spaceConfig);
      return;
    }

    if (spaceConfig.current.key.isEmpty) {
      Logger.error(
          'Init file does not contain a current key. Aborting key migration.');
      return;
    }

    String currentPlain;
    try {
      final encodedKey = base64.decode(spaceConfig.current.key);
      currentPlain = ChaCha20Poly1305.decrypt(
          encryptedData: encodedKey,
          key: ChaCha20Poly1305.generateKeyFromString(
              _dataStore.config.encryptionKey));
    } catch (e) {
      Logger.error('Failed to decrypt current key: $e');
      return;
    }

    final effectiveOldKey = EncoderHandler.generateKey(currentPlain);
    final effectiveNewKey = EncoderHandler.generateKey(newKey);
    final newKeyId = spaceConfig.current.keyId + 1;

    if (currentPlain == (newKey)) {
      return;
    }

    Logger.info('Encoding key has changed. Starting data migration...');
    try {
      await _migrateData(effectiveOldKey, spaceConfig.current.keyId,
          effectiveNewKey, newKeyId);
    } catch (e) {
      Logger.error('Key data migration failed: $e');
      return;
    }

    // After successful migration, update init config by shifting current to previous and setting new key with incremented keyId
    try {
      final encryptedNewBytes = ChaCha20Poly1305.encrypt(
          plaintext: newKey,
          key: ChaCha20Poly1305.generateKeyFromString(
              _dataStore.config.encryptionKey));
      final encryptedNewBase64 = base64.encode(encryptedNewBytes);

      await _dataStore.saveSpaceConfigToFile(
        spaceConfig.copyWith(
          current: EncryptionKeyInfo(key: encryptedNewBase64, keyId: newKeyId),
        ),
      );
    } catch (e) {
      Logger.error('Failed to update the init file after migration: $e');
    }
  }

  /// Data migration logic
  Future<void> _migrateData(
      List<int> oldKey, int oldKeyId, List<int> newKey, int newKeyId) async {
    final tableNames = await _dataStore.getTableNames();

    for (final tableName in tableNames) {
      // Concurrent partition processing interface
      await _dataStore.tableDataManager.processTablePartitions(
        tableName: tableName,
        processFunction: (records, partitionIndex, controller) async {
          return records;
        },
        encryptionKey: newKey,
        encryptionKeyId: newKeyId,
      );

      Logger.info('Migration complete for table: $tableName');
    }
  }
}
