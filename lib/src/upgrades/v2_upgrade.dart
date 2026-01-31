import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import '../handler/common.dart';
import '../handler/encoder.dart';
import '../handler/logger.dart';
import '../handler/chacha20_poly1305_old.dart';
import '../model/global_config.dart';
import '../model/meta_info.dart';
import '../model/space_config.dart';
import '../core/data_store_impl.dart';
import '../core/workload_scheduler.dart';
import '../handler/parallel_processor.dart';
import '../core/yield_controller.dart';

/// Version 2 upgrade handler.
/// This upgrade adds stable partition directory mapping for table data partitions,
/// replacing the dynamic calculation `dirIndex = partitionIndex ~/ maxEntriesPerDir`
/// with persistent metadata-based mapping.
class V2Upgrade {
  final DataStoreImpl _dataStore;

  V2Upgrade(this._dataStore);

  /// Execute version 2 upgrade for the entire database.
  Future<void> execute(GlobalConfig oldGlobalConfig) async {
    Logger.info(
      'Starting database upgrade to version 2',
      label: 'V2Upgrade.execute',
    );

    // Upgrade Schema partition mapping (global, not space-specific)
    await _upgradeSchemaPartitionMapping(_dataStore);

    // Upgrade migration metadata (global, not space-specific)
    await _upgradeMigrationMeta(_dataStore);

    // Backup and upgrade encryption keys for each space before migration
    // This ensures we can recover from backup if migration fails
    final spaces = oldGlobalConfig.spaceNames.isNotEmpty
        ? oldGlobalConfig.spaceNames.toList()
        : <String>['default'];

    final yieldController =
        YieldController('upgrade_v2_execute', checkInterval: 1);

    bool globalUpgraded = false;
    for (final spaceName in spaces) {
      await _upgradeSpaceToV2(spaceName, upgradeGlobal: !globalUpgraded);
      globalUpgraded = true;
      await yieldController.maybeYield();
    }

    // After all spaces upgraded successfully, bump GlobalConfig.version
    final updatedGlobal =
        oldGlobalConfig.setVersion(InternalConfig.engineVersion);
    await _dataStore.saveGlobalConfig(updatedGlobal);

    Logger.info(
      'Database upgrade to version 2 completed',
      label: 'V2Upgrade.execute',
    );
  }

  /// Upgrade a specific space to version 2 using a dedicated migration instance.
  Future<void> _upgradeSpaceToV2(String spaceName,
      {bool upgradeGlobal = false}) async {
    Logger.info(
      'Upgrading space [$spaceName] to database version 2',
      label: 'V2Upgrade._upgradeSpaceToV2',
    );

    final spaceConfigPath =
        _dataStore.pathManager.getSpaceConfigPath(spaceName: spaceName);
    final backupConfigPath = '$spaceConfigPath.old';

    // 1. Backup space.config to space.config.old if not already backed up
    if (await _dataStore.storage.existsFile(spaceConfigPath) &&
        !await _dataStore.storage.existsFile(backupConfigPath)) {
      final content = await _dataStore.storage.readAsString(spaceConfigPath);
      if (content != null && content.isNotEmpty) {
        await _dataStore.storage.writeAsString(backupConfigPath, content);
        Logger.info('Backed up space config to $backupConfigPath',
            label: 'V2Upgrade._upgradeSpaceToV2');
      }
    }

    final baseConfig = _dataStore.config;
    final migrationInstance = DataStoreImpl(
      dbPath: baseConfig.dbPath,
      dbName: baseConfig.dbName,
      config: baseConfig.copyWith(spaceName: spaceName),
      isMigrationInstance: true,
    );

    try {
      // Initialize migration instance
      await migrationInstance.initialize();

      // Load keys from backup and setup fallback in EncoderHandler AFTER initialization
      // This ensures we have the old keys for decoding while migrating data
      await _setupFallbackKeysFromBackup(backupConfigPath);

      // Load space config for this space
      final spaceConfig = await migrationInstance.getSpaceConfig();
      if (spaceConfig != null &&
          spaceConfig.version >= InternalConfig.engineVersion) {
        // Already upgraded
        await migrationInstance.close();
        if (await _dataStore.storage.existsFile(backupConfigPath)) {
          await _dataStore.storage.deleteFile(backupConfigPath);
        }
        return;
      }

      // Upgrade tables in this space (including global tables if requested)
      final tableNames =
          await migrationInstance.schemaManager?.listAllTables() ??
              const <String>[];
      final yieldController = YieldController('upgrade_v2_space_tables');
      if (tableNames.isNotEmpty) {
        for (final tableName in tableNames) {
          final schema =
              await migrationInstance.schemaManager?.getTableSchema(tableName);
          if (schema == null) continue;

          if (schema.isGlobal) {
            if (!upgradeGlobal) continue;
          }
          // Upgrade table data to new range partition format
          await _upgradeTableDataToNewFormat(migrationInstance, tableName);
          await yieldController.maybeYield();
        }
      }

      // After successful upgrade for this space, bump SpaceConfig.version
      final updatedSpaceConfig = await migrationInstance.getSpaceConfig();
      if (updatedSpaceConfig != null) {
        final withVersion =
            updatedSpaceConfig.copyWith(version: InternalConfig.engineVersion);

        if (spaceName == _dataStore.currentSpaceName) {
          // Keep main instance cache in sync for current space
          await _dataStore.saveSpaceConfigToFile(withVersion);
        } else {
          await migrationInstance.saveSpaceConfigToFile(withVersion);
        }
      }

      // 4. Cleanup backup after successful upgrade
      if (await _dataStore.storage.existsFile(backupConfigPath)) {
        await _dataStore.storage.deleteFile(backupConfigPath);
        Logger.info(
            'Deleted backup config $backupConfigPath after successful upgrade',
            label: 'V2Upgrade._upgradeSpaceToV2');
      }
    } catch (e, stack) {
      Logger.error(
        'Failed to upgrade space [$spaceName] to version 2: $e\n$stack',
        label: 'V2Upgrade._upgradeSpaceToV2',
      );
      // Ensure we keep the backup on failure so we can resume
      rethrow;
    } finally {
      await migrationInstance.close();
    }
  }

  /// Load keys from backup and setup fallback in EncoderHandler using old algorithm
  Future<void> _setupFallbackKeysFromBackup(String backupPath) async {
    if (!await _dataStore.storage.existsFile(backupPath)) return;

    try {
      final content = await _dataStore.storage.readAsString(backupPath);
      if (content == null || content.isEmpty) return;

      final json = jsonDecode(content);
      final spaceConfig = SpaceConfig.fromJson(json);

      final key32Old = ChaCha20Poly1305Old.generateKeyFromString(
          _dataStore.config.encryptionConfig?.encryptionKey ??
              'E9n8C7r6y7P8T3ioNkEy');

      final Map<int, Uint8List> fallbackKeys = {};

      void processKey(EncryptionKeyInfo? info) {
        if (info == null || info.key.isEmpty) return;
        try {
          final decoded = base64.decode(info.key);
          final plain = ChaCha20Poly1305Old.decrypt(
              encryptedData: decoded, key: key32Old);
          fallbackKeys[info.keyId] = EncoderHandler.generateKey(plain);
        } catch (e) {
          // might be already upgraded if we are resuming?
          // but backup is "v1" config, so it should be old.
          Logger.warn('Failed to decrypt old key from backup: $e',
              label: 'V2Upgrade');
        }
      }

      processKey(spaceConfig.current);
      if (spaceConfig.previous != null) {
        processKey(spaceConfig.previous);
      }

      if (fallbackKeys.isNotEmpty) {
        EncoderHandler.setFallbackKeys(fallbackKeys);
        Logger.info(
            'Set ${fallbackKeys.length} fallback keys from backup config',
            label: 'V2Upgrade');
      }
    } catch (e) {
      Logger.error('Failed to setup fallback keys from backup: $e',
          label: 'V2Upgrade');
    }
  }

  /// Upgrade Schema partition directory mapping.
  Future<void> _upgradeSchemaPartitionMapping(DataStoreImpl db) async {
    try {
      final schemaMetaPath = db.pathManager.getSchemaMetaPath();
      if (!await db.storage.existsFile(schemaMetaPath)) return;

      final content = await db.storage.readAsString(schemaMetaPath);
      if (content == null || content.isEmpty) return;

      final schemaMeta = SchemaMeta.fromJson(jsonDecode(content));

      // If directoryMapping already exists and covers all partitions, skip.
      final existingMapping = schemaMeta.directoryMapping;
      final partitions = schemaMeta.tablePartitionMap.values.toSet().toList();
      bool needUpgrade = false;

      if (existingMapping == null) {
        needUpgrade = true;
      } else if (partitions.isEmpty) {
        needUpgrade = false;
      } else {
        // Check if all partitions have mappings
        for (final pIndex in partitions) {
          if (existingMapping.getDirIndex(pIndex) == null) {
            needUpgrade = true;
            break;
          }
        }
      }

      if (!needUpgrade) {
        return;
      }

      final maxEntriesPerDir = db.maxEntriesPerDir;
      final Map<int, int> p2d = <int, int>{};
      final Map<int, int> d2c = <int, int>{};

      for (final pIndex in partitions) {
        // Legacy algorithm (only used during this one-time upgrade).
        final dirIndex = pIndex ~/ maxEntriesPerDir;
        p2d[pIndex] = dirIndex;
        d2c[dirIndex] = (d2c[dirIndex] ?? 0) + 1;

        // Update partition meta dirIndex if needed
        final legacyDirIndex = pIndex ~/ maxEntriesPerDir;
        final partitionPath =
            db.pathManager.getSchemaPartitionFilePath(pIndex, legacyDirIndex);
        if (await db.storage.existsFile(partitionPath)) {
          final partitionContent = await db.storage.readAsString(partitionPath);
          if (partitionContent != null) {
            try {
              final partitionMeta =
                  SchemaPartitionMeta.fromJson(jsonDecode(partitionContent));
              if (partitionMeta.dirIndex == null) {
                final updatedMeta = partitionMeta.copyWith(dirIndex: dirIndex);
                await db.storage.writeAsString(
                    partitionPath, jsonEncode(updatedMeta.toJson()));
              }
            } catch (_) {}
          }
        }
      }

      final newMapping = DirectoryMapping(
        partitionToDir: p2d,
        dirToFileCount: d2c,
      );

      final updatedSchemaMeta =
          schemaMeta.copyWith(directoryMapping: newMapping);
      await db.storage.writeAsString(
          schemaMetaPath, jsonEncode(updatedSchemaMeta.toJson()));

      Logger.info(
        'Upgraded Schema partition directory mapping',
        label: 'V2Upgrade._upgradeSchemaPartitionMapping',
      );
    } catch (e, stack) {
      Logger.error(
        'Failed to upgrade Schema partition mapping: $e\n$stack',
        label: 'V2Upgrade._upgradeSchemaPartitionMapping',
      );
      // Do not rethrow here so that other upgrades can continue.
    }
  }

  /// Upgrade migration metadata from legacy format (v1) to new format (v2+).
  /// Converts dirUsage, taskIndex, currentDirIndex to DirectoryMappingString.
  Future<void> _upgradeMigrationMeta(DataStoreImpl db) async {
    try {
      final metaPath = db.pathManager.getMigrationMetaPath();
      if (!await db.storage.existsFile(metaPath)) return;

      final content = await db.storage.readAsString(metaPath);
      if (content == null || content.isEmpty) return;

      final json = jsonDecode(content);

      // Check if already upgraded (has directoryMapping, no legacy fields)
      if (json.containsKey('directoryMapping') &&
          !json.containsKey('dirUsage') &&
          !json.containsKey('taskIndex')) {
        // Already upgraded
        return;
      }

      // Convert legacy format to new format
      final Map<String, int> idToDir = <String, int>{};
      final Map<int, int> dirToFileCount = <int, int>{};

      // Convert taskIndex to idToDir
      if (json['taskIndex'] is Map) {
        final taskIndex = json['taskIndex'] as Map<dynamic, dynamic>;
        taskIndex.forEach((key, value) {
          if (key is String && value is int) {
            idToDir[key] = value;
          }
        });
      }

      // Convert dirUsage to dirToFileCount
      if (json['dirUsage'] is Map) {
        final dirUsage = json['dirUsage'] as Map<dynamic, dynamic>;
        dirUsage.forEach((key, value) {
          final idx = int.tryParse(key.toString());
          if (idx != null && value is int) {
            dirToFileCount[idx] = value;
          }
        });
      }

      // Create new format metadata
      final newMapping = DirectoryMappingString(
        idToDir: idToDir,
        dirToFileCount: dirToFileCount,
      );

      final newMeta = {
        'directoryMapping': newMapping.toJson(),
      };

      await db.storage.writeAsString(metaPath, jsonEncode(newMeta));

      Logger.info(
        'Upgraded migration metadata to version 2 format',
        label: 'V2Upgrade._upgradeMigrationMeta',
      );
    } catch (e, stack) {
      Logger.error(
        'Failed to upgrade migration metadata: $e\n$stack',
        label: 'V2Upgrade._upgradeMigrationMeta',
      );
      // Do not rethrow here so that other upgrades can continue.
    }
  }

  /// Upgrade table data from old JSON structure to new binary format
  /// This manually parses old structure to avoid dependency on removed models
  Future<void> _upgradeTableDataToNewFormat(
      DataStoreImpl db, String tableName) async {
    try {
      Logger.info(
        'Starting table data upgrade for table: $tableName',
        label: 'V2Upgrade._upgradeTableDataToNewFormat',
      );

      // Manually build old table meta path (old format: main.dat)
      final tablePath = await db.pathManager.getTablePath(tableName);
      final oldDataMetaPath = pathJoin(tablePath, 'data', 'main.dat');

      // Check if old data meta file exists
      if (!await db.storage.existsFile(oldDataMetaPath)) {
        return;
      }

      final oldMetaContent = await db.storage.readAsString(oldDataMetaPath);

      if (oldMetaContent == null || oldMetaContent.isEmpty) {
        Logger.info(
          'No old data meta file found for table: $tableName, skipping',
          label: 'V2Upgrade._upgradeTableDataToNewFormat',
        );
        return;
      }

      // Manually parse old JSON structure (no model dependency)
      final oldMetaJson = jsonDecode(oldMetaContent) as Map<String, dynamic>;
      if (oldMetaJson['meta'] == null) {
        return;
      }

      // Extract old partition information
      final oldPartitions = oldMetaJson['meta']['partitions'] as List<dynamic>?;
      if (oldPartitions == null || oldPartitions.isEmpty) {
        Logger.info(
          'No partitions found for table: $tableName, skipping',
          label: 'V2Upgrade._upgradeTableDataToNewFormat',
        );
        return;
      }

      // Parse old partition structure
      final oldPartitionMetas = <Map<String, dynamic>>[];
      for (final pJson in oldPartitions) {
        if (pJson is Map<String, dynamic>) {
          oldPartitionMetas.add(pJson);
        }
      }

      Logger.info(
        'Found ${oldPartitionMetas.length} old partitions for table: $tableName',
        label: 'V2Upgrade._upgradeTableDataToNewFormat',
      );

      // Delete new ranges directory and data meta file to avoid data migration confusion
      final newRangesPath =
          await db.pathManager.getPartitionsDirPath(tableName);
      final newDataMetaPath = await db.pathManager.getDataMetaPath(tableName);
      if (await db.storage.existsDirectory(newRangesPath)) {
        await db.storage.deleteDirectory(newRangesPath);
      }
      if (await db.storage.existsFile(newDataMetaPath)) {
        await db.storage.deleteFile(newDataMetaPath);
      }

      // delete index root directory
      final indexRootPath = await db.pathManager.getIndexDirPath(tableName);
      if (await db.storage.existsDirectory(indexRootPath)) {
        await db.storage.deleteDirectory(indexRootPath);
      }

      // Process partitions in parallel batches to avoid memory blowup.
      final int writeBatchSize =
          db.config.writeBatchSize > 0 ? db.config.writeBatchSize : 5000;

      List<dynamic> currentBatchMetas = [];
      int currentBatchRecordCount = 0;

      Future<void> processCurrentBatch() async {
        if (currentBatchMetas.isEmpty) return;

        // 1. Parallel Read with high-priority flush tokens but limited to 70% share
        // and released immediately after reading to avoid deadlocking with background flushes.
        final lease = await db.workloadScheduler.tryAcquire(
          WorkloadType.flush,
          requestedTokens:
              (db.workloadScheduler.capacityTokens(WorkloadType.flush) * 0.7)
                  .floor(),
          minTokens: 1,
          label: 'V2Upgrade.readPartitions',
        );

        final int batchConcurrency = max(1, lease?.asConcurrency(0.5) ?? 1);

        try {
          final readTasks = currentBatchMetas.map((partitionMeta) {
            return () => _parseOldPartitionFile(db, tableName, partitionMeta);
          }).toList();

          final results =
              await ParallelProcessor.execute<List<Map<String, dynamic>>>(
                  readTasks,
                  concurrency: batchConcurrency,
                  label: 'V2Upgrade.readPartitions',
                  continueOnError: false, // Fail fast on read errors
                  controller: ParallelController(),
                  timeout: const Duration(minutes: 5));

          // Release tokens immediately after reading phase to prioritize tokens for flushing
          lease?.release();

          // Flatten records
          final batchRecords =
              results.expand((r) => r ?? <Map<String, dynamic>>[]).toList();

          if (batchRecords.isNotEmpty) {
            final schema = await db.schemaManager?.getTableSchema(tableName);
            if (schema == null) {
              Logger.warn(
                'Schema not found for table $tableName, skipping batch',
                label: 'V2Upgrade._upgradeTableDataToNewFormat',
              );
              return;
            }

            // Use writeChanges directly for migration instances
            // This bypasses WAL/buffer and writes directly to table partitions
            // which is safe for migration since we're doing a one-time data transformation
            await db.tableDataManager.writeChanges(
              tableName: tableName,
              inserts: batchRecords,
              updates: const [],
              deletes: const [],
              batchContext: null,
              concurrency: null,
            );

            // Also write index changes for the inserted records
            if (db.indexManager != null && batchRecords.isNotEmpty) {
              await db.indexManager!.writeChanges(
                tableName: tableName,
                inserts: batchRecords,
                updates: const [],
                deletes: const [],
                batchContext: null,
                concurrency: null,
              );
            }

            Logger.debug(
              'Wrote ${batchRecords.length} records and indexes directly to table $tableName',
              label: 'V2Upgrade._upgradeTableDataToNewFormat',
            );
          }
        } finally {
          lease?.release();
        }

        // Reset batch
        currentBatchMetas.clear();
        currentBatchRecordCount = 0;
        await Future.delayed(Duration.zero);
      }

      final int heuristicConcurrency = db.workloadScheduler.globalMax;
      for (int i = 0; i < oldPartitionMetas.length; i++) {
        final partitionMeta = oldPartitionMetas[i];

        // Try to get count from metadata
        int totalRecords = 0;
        if (partitionMeta['totalRecords'] is int) {
          totalRecords = partitionMeta['totalRecords'] as int;
        } else if (partitionMeta['fileSizeInBytes'] is int) {
          totalRecords = (partitionMeta['fileSizeInBytes'] as int) ~/ 1024;
        } else {
          // fallback key just in case
          totalRecords = 1000;
        }

        currentBatchMetas.add(partitionMeta);
        currentBatchRecordCount += totalRecords;

        // If we have enough records, or this is the last partition, process.
        // We use >= writeBatchSize to trigger.
        if (currentBatchRecordCount >= writeBatchSize ||
            currentBatchMetas.length >= (heuristicConcurrency * 2)) {
          await processCurrentBatch();
        }
      }

      // Process remaining
      await processCurrentBatch();

      // Migrated data deletion: delete old data meta file and old partitions root directory
      if (await db.storage.existsFile(oldDataMetaPath)) {
        await db.storage.deleteFile(oldDataMetaPath);
      }
      if (await db.storage
          .existsDirectory(pathJoin(tablePath, 'data', 'partitions'))) {
        await db.storage
            .deleteDirectory(pathJoin(tablePath, 'data', 'partitions'));
      }
      Logger.info(
        'Table data upgrade preparation completed for table: $tableName (records ready for migration)',
        label: 'V2Upgrade._upgradeTableDataToNewFormat',
      );
    } catch (e, stack) {
      Logger.error(
        'Failed to upgrade table data for table $tableName: $e\n$stack',
        label: 'V2Upgrade._upgradeTableDataToNewFormat',
      );
      // Do not rethrow - allow other tables to continue upgrading
    }
  }

  /// Manually parse old partition file structure
  /// Returns list of records from old JSON partition file
  /// Uses manual path construction to avoid dependency on old path methods
  Future<List<Map<String, dynamic>>> _parseOldPartitionFile(DataStoreImpl db,
      String tableName, Map<String, dynamic> partitionMeta) async {
    try {
      // Extract old partition index and directory index from JSON
      final oldPartitionIndex = partitionMeta['index'] as int?;

      if (oldPartitionIndex == null) {
        Logger.warn(
          'Old partition meta missing index for table: $tableName',
          label: 'V2Upgrade._parseOldPartitionFile',
        );
        return [];
      }

      // Calculate old directory index if not present (legacy algorithm)
      final dirIndex = oldPartitionIndex ~/ db.maxEntriesPerDir;

      // Manually build old partition file path (old format: p{index}.dat)
      final tablePath = await db.pathManager.getTablePath(tableName);
      final oldPartitionPath = pathJoin(tablePath, 'data', 'partitions',
          'dir_$dirIndex', 'p$oldPartitionIndex.dat');

      // Check if old partition file exists
      if (!await db.storage.existsFile(oldPartitionPath)) {
        return [];
      }

      final partitionBytes = await db.storage.readAsBytes(oldPartitionPath);
      if (partitionBytes.isEmpty) {
        return [];
      }

      final decodedString = EncoderHandler.decode(partitionBytes);
      if (decodedString.isEmpty) {
        return [];
      }

      // Parse old JSON structure (no model dependency)
      final partitionJson = jsonDecode(decodedString) as Map<String, dynamic>;

      // Extract data records - handle both old formats
      List<dynamic>? data;

      // Try 'data' field first (newer format)
      if (partitionJson.containsKey('data')) {
        data = partitionJson['data'] as List<dynamic>?;
      }

      if (data == null || data.isEmpty) {
        return [];
      }

      // Convert to list of records
      final records = <Map<String, dynamic>>[];
      final yieldController =
          YieldController('V2Upgrade._parseOldPartitionFile');
      for (final item in data) {
        yieldController.maybeYield();
        if (item is Map<String, dynamic>) {
          if (item['_deleted_'] == true || item.isEmpty) {
            continue;
          }
          records.add(item);
        } else if (item is String) {
          // Try parsing as JSON string
          try {
            final parsed = jsonDecode(item) as Map<String, dynamic>;
            if (parsed['_deleted_'] == true || parsed.isEmpty) {
              continue;
            }
            records.add(parsed);
          } catch (_) {
            // Skip invalid entries
          }
        }
      }

      Logger.info(
        'Parsed ${records.length} records from old partition file: $oldPartitionPath (partition index: $oldPartitionIndex)',
        label: 'V2Upgrade._parseOldPartitionFile',
      );

      return records;
    } catch (e, stack) {
      Logger.error(
        'Failed to parse old partition file: $e\n$stack',
        label: 'V2Upgrade._parseOldPartitionFile',
      );
      return [];
    }
  }
}
