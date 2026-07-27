import 'dart:convert';
import 'dart:math';
import '../handler/common.dart';
import '../handler/encryption.dart';
import '../handler/logger.dart';
import '../handler/chacha20_poly1305_old.dart';
import '../model/global_config.dart';
import '../model/table_meta.dart';
import '../core/data_store_impl.dart';
import '../core/workload_scheduler.dart';
import '../handler/parallel_processor.dart';
import '../core/yield_controller.dart';
import 'legacy_model/pre_v3.dart';
import 'v3_upgrade.dart';
import '../model/table_identity.dart';

/// Version 2 upgrade handler.
///
/// Chains into [V3Upgrade] for schema → `_system_table_meta` / TOBF, then
/// rewrites legacy JSON table partitions and re-wraps pre-v2 ChaCha keys.
/// Schema partition mapping / migration_meta JSON shaping are owned by V3
/// ([LegacySchemaMetaJson], [MigrationMeta.fromJson] + [MigrationFormatMigration]).
class V2Upgrade {
  final DataStoreImpl _dataStore;

  V2Upgrade(this._dataStore);

  /// Execute version 2 upgrade for the entire database.
  Future<void> execute(GlobalConfig oldGlobalConfig) async {
    Logger.info(
      'Starting database upgrade to version 2',
    );

    final spaces = oldGlobalConfig.spaceNames.isNotEmpty
        ? oldGlobalConfig.spaceNames.toList()
        : <String>['default'];

    // Backup legacy JSON space configs BEFORE V3 deletes them (key re-wrap needs
    // the old ChaCha algorithm payload from JSON).
    for (final spaceName in spaces) {
      await _backupLegacySpaceConfigJson(spaceName);
    }

    // Decrypt legacy current/previous with Old ChaCha, then let KeyManager stash
    // them into history and mint a fresh current — must finish before V3's
    // keyManager.initialize so encoding-key migration is not scheduled.
    for (final spaceName in spaces) {
      final root = _dataStore.instancePath;
      if (root == null) break;
      final backupPath = '${LegacyConfigPaths.spaceJson(root, spaceName)}.old';
      final plainById = await _loadLegacyPlainEncodingKeys(backupPath);
      if (plainById.isEmpty) continue;

      await _dataStore.keyManager.prepareKeysForV2DataRewrite(
        spaceName: spaceName,
        legacyPlainEncodingKeysById: plainById,
      );
    }

    // Metadata / directory UID upgrade first so data rewrite resolves paths.
    final v3Upgrade = V3Upgrade(_dataStore);
    await v3Upgrade.execute(oldGlobalConfig, skipVersionBump: true);

    final yieldController =
        YieldController('upgrade_v2_execute', checkInterval: 1);

    bool globalUpgraded = false;
    for (final spaceName in spaces) {
      await _upgradeSpaceToV2(spaceName, upgradeGlobal: !globalUpgraded);
      globalUpgraded = true;
      await yieldController.maybeYield();
    }

    // After all spaces upgraded successfully, bump GlobalConfig.version
    // Prefer config already updated by v3 (pageSize, etc.).
    final currentGlobal = await _dataStore.getGlobalConfig() ?? oldGlobalConfig;
    await _dataStore.saveGlobalConfig(
      currentGlobal.setVersion(InternalConfig.engineVersion),
    );

    Logger.info(
      'Database upgrade to version 2 completed',
    );
  }

  Future<void> _backupLegacySpaceConfigJson(String spaceName) async {
    final root = _dataStore.instancePath;
    if (root == null) return;
    final legacyConfigPath = LegacyConfigPaths.spaceJson(root, spaceName);
    final backupConfigPath = '$legacyConfigPath.old';
    if (!await _dataStore.storage.existsFile(legacyConfigPath)) return;
    if (await _dataStore.storage.existsFile(backupConfigPath)) return;

    final content = await _dataStore.storage.readAsString(legacyConfigPath);
    if (content != null && content.isNotEmpty) {
      await _dataStore.storage.writeAsString(backupConfigPath, content);
      Logger.info('Backed up space config to $backupConfigPath');
    }
  }

  /// Upgrade a specific space to version 2 using a dedicated migration instance.
  Future<void> _upgradeSpaceToV2(String spaceName,
      {bool upgradeGlobal = false}) async {
    Logger.info(
      'Upgrading space [$spaceName] to database version 2',
    );

    final root = _dataStore.instancePath!;
    final legacyConfigPath = LegacyConfigPaths.spaceJson(root, spaceName);
    final backupConfigPath = '$legacyConfigPath.old';

    final baseConfig = _dataStore.config;

    // Primary already wrote wal/meta.tobf (etc.) during V3 via its own
    // FileStorageImpl pool. Release those handles before a migration instance
    // opens the same paths — otherwise Windows rename/delete fails (errno 5/32).
    try {
      await _dataStore.storage.flushAll(closeHandles: true);
    } catch (e) {
      Logger.warn(
        'Failed to flush primary storage handles before v2 space upgrade '
        '[$spaceName]',
        rawError: e,
      );
    }

    final migrationInstance = DataStoreImpl(
      dbPath: baseConfig.dbPath,
      dbName: baseConfig.dbName,
      config: baseConfig.copyWith(spaceName: spaceName),
      isMigrationInstance: true,
    );

    try {
      // Initialize migration instance
      await migrationInstance.initialize();

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

      // Upgrade all tables (globals gated by upgradeGlobal below)
      final tableNames =
          await migrationInstance.tableMetaManager?.listAllTables() ??
              const <String>[];
      final yieldController = YieldController('upgrade_v2_space_tables');
      if (tableNames.isNotEmpty) {
        for (final tableName in tableNames) {
          final schema = await migrationInstance.tableMetaManager
              ?.getTableSchemaByName(TableName(tableName));
          if (schema == null) continue;

          if (schema.isGlobal) {
            if (!upgradeGlobal) continue;
          }
          if (schema.isSystemTable) continue;
          // After V3: directories are under tableUid; read legacy JSON from that root.
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
            'Deleted backup config $backupConfigPath after successful upgrade');
      }
    } catch (e) {
      Logger.error('Failed to upgrade space [$spaceName] to version 2',
          rawError: e);
      // Ensure we keep the backup on failure so we can resume
      rethrow;
    } finally {
      await migrationInstance.close();
    }
  }

  /// Decrypt pre-v2 space_config key blobs (ChaCha20Poly1305Old wrapping)
  /// into plain encoding-key strings keyed by keyId.
  Future<Map<int, String>> _loadLegacyPlainEncodingKeys(
      String backupPath) async {
    final out = <int, String>{};
    if (!await _dataStore.storage.existsFile(backupPath)) return out;

    try {
      final content = await _dataStore.storage.readAsString(backupPath);
      if (content == null || content.isEmpty) return out;

      final map = LegacySpaceConfigJson.tryParseMap(content);
      if (map == null) return out;

      final key32Old = ChaCha20Poly1305Old.generateKeyFromString(
          _dataStore.config.encryptionConfig?.encryptionKey ??
              'E9n8C7r6y7P8T3ioNkEy');

      void processKey(Map<String, dynamic>? info) {
        if (info == null) return;
        final key = info['key'] as String? ?? '';
        final keyId = info['keyId'] as int? ?? 0;
        if (key.isEmpty) return;
        try {
          final decoded = base64.decode(key);
          final plain = ChaCha20Poly1305Old.decrypt(
              encryptedData: decoded, key: key32Old);
          out[keyId] = plain;
        } catch (e) {
          Logger.warn('Failed to decrypt old key from backup', rawError: e);
        }
      }

      processKey(map['current'] as Map<String, dynamic>?);
      processKey(map['previous'] as Map<String, dynamic>?);
      final history = map['historyKeys'];
      if (history is List) {
        for (final e in history) {
          if (e is Map) {
            processKey(Map<String, dynamic>.from(e));
          }
        }
      }
    } catch (e) {
      Logger.error('Failed to load fallback keys from backup', rawError: e);
    }
    return out;
  }

  /// Upgrade table data from old JSON (`main.dat` + `data/partitions`) to btree.
  ///
  /// Runs **after** V3: resolve [tableUid] / [TableMeta.dirIndex], locate legacy
  /// JSON under the post-rename UID root (fallback: leftover `tableName` dirs).
  Future<void> _upgradeTableDataToNewFormat(
      DataStoreImpl db, String tableName) async {
    try {
      Logger.info(
        'Starting table data upgrade for table: $tableName',
      );

      final tableUid =
          await db.tableMetaManager?.getUidByName(TableName(tableName));
      if (tableUid == null) {
        Logger.warn(
            'Table UID not found for table: $tableName, skipping data upgrade');
        return;
      }

      final meta = await db.tableMetaManager?.getTableMeta(tableUid);
      if (meta == null) {
        Logger.warn(
            'Table meta not found for $tableName ($tableUid), skipping');
        return;
      }

      final table = await db.tableMetaManager?.getTableContext(tableUid);
      if (table == null) {
        Logger.warn(
            'TableContext not found for $tableName ($tableUid), skipping');
        return;
      }

      final resolved = await _resolveLegacyJsonDataRoot(
        db,
        meta: meta,
        tableName: tableName,
      );
      if (resolved == null) {
        return;
      }
      final tableRoot = resolved.root;
      final oldDataMetaPath = pathJoin(tableRoot, 'data', 'main.dat');

      final oldMetaContent = await db.storage.readAsString(oldDataMetaPath);
      if (oldMetaContent == null || oldMetaContent.isEmpty) {
        Logger.info(
          'No old data meta file found for table: $tableName, skipping',
        );
        return;
      }

      final oldMetaJson = jsonDecode(oldMetaContent) as Map<String, dynamic>;
      if (oldMetaJson['meta'] == null) {
        return;
      }

      final oldPartitions = oldMetaJson['meta']['partitions'] as List<dynamic>?;
      if (oldPartitions == null || oldPartitions.isEmpty) {
        Logger.info(
          'No partitions found for table: $tableName, skipping',
        );
        return;
      }

      final oldPartitionMetas = <Map<String, dynamic>>[];
      for (final pJson in oldPartitions) {
        if (pJson is Map<String, dynamic>) {
          oldPartitionMetas.add(pJson);
        }
      }

      Logger.info(
        'Found ${oldPartitionMetas.length} old partitions for table: $tableName '
        '(root=$tableRoot, uid=${tableUid.value})',
      );

      // Clear post-V3 btree stubs only (`data/btree`), never legacy `data/partitions`.
      final newRangesPath = await db.pathManager.getPartitionsDirPath(tableUid);
      if (await db.storage.existsDirectory(newRangesPath)) {
        await db.storage.deleteDirectory(newRangesPath);
      }

      final indexRootPath = await db.pathManager.getIndexDirPath(tableUid);
      if (await db.storage.existsDirectory(indexRootPath)) {
        await db.storage.deleteDirectory(indexRootPath);
      }

      final int writeBatchSize =
          db.config.writeBatchSize > 0 ? db.config.writeBatchSize : 5000;

      List<dynamic> currentBatchMetas = [];
      int currentBatchRecordCount = 0;

      Future<void> processCurrentBatch() async {
        if (currentBatchMetas.isEmpty) return;

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
            return () => _parseOldPartitionFile(
                  db,
                  tableName: tableName,
                  tableRoot: tableRoot,
                  partitionMeta: partitionMeta,
                );
          }).toList();

          final results =
              await ParallelProcessor.execute<List<Map<String, dynamic>>>(
                  readTasks,
                  concurrency: batchConcurrency,
                  label: 'V2Upgrade.readPartitions',
                  continueOnError: false,
                  controller: ParallelController(),
                  timeout: const Duration(minutes: 5));

          lease?.release();

          final batchRecords =
              results.expand((r) => r ?? <Map<String, dynamic>>[]).toList();

          if (batchRecords.isNotEmpty) {
            await db.tableDataManager.writeChanges(
              table: table,
              inserts: batchRecords,
              updates: const [],
              deletes: const [],
              batchContext: null,
              concurrency: null,
            );

            if (db.indexManager != null) {
              await db.indexManager!.writeChanges(
                table: table,
                inserts: batchRecords,
                updates: const [],
                deletes: const [],
                batchContext: null,
                concurrency: null,
              );
            }

            Logger.debug(
              'Wrote ${batchRecords.length} records and indexes to '
              '${table.tableUid} ($tableName)',
            );
          }
        } finally {
          lease?.release();
        }

        currentBatchMetas.clear();
        currentBatchRecordCount = 0;
        await Future.delayed(Duration.zero);
      }

      final int heuristicConcurrency = db.workloadScheduler.globalMax;
      for (int i = 0; i < oldPartitionMetas.length; i++) {
        final partitionMeta = oldPartitionMetas[i];

        int totalRecords = 0;
        if (partitionMeta['totalRecords'] is int) {
          totalRecords = partitionMeta['totalRecords'] as int;
        } else if (partitionMeta['fileSizeInBytes'] is int) {
          totalRecords = (partitionMeta['fileSizeInBytes'] as int) ~/ 1024;
        } else {
          totalRecords = 1000;
        }

        currentBatchMetas.add(partitionMeta);
        currentBatchRecordCount += totalRecords;

        if (currentBatchRecordCount >= writeBatchSize ||
            currentBatchMetas.length >= (heuristicConcurrency * 2)) {
          await processCurrentBatch();
        }
      }

      await processCurrentBatch();

      if (await db.storage.existsFile(oldDataMetaPath)) {
        await db.storage.deleteFile(oldDataMetaPath);
      }
      final legacyPartitionsDir = pathJoin(tableRoot, 'data', 'partitions');
      if (await db.storage.existsDirectory(legacyPartitionsDir)) {
        await db.storage.deleteDirectory(legacyPartitionsDir);
      }

      // V3 wrote meta at UID path but left data under logical name — drop leftover.
      if (resolved.fromLegacyNamePath) {
        final uidRoot = _tableRootFromMeta(db, meta);
        if (tableRoot != uidRoot &&
            await db.storage.existsDirectory(tableRoot)) {
          final stillHasData = await db.storage
              .existsFile(pathJoin(tableRoot, 'data', 'main.dat'));
          if (!stillHasData) {
            // Best-effort: only remove if we cleared JSON artifacts.
            final dataDir = pathJoin(tableRoot, 'data');
            if (await db.storage.existsDirectory(dataDir)) {
              final children =
                  await db.storage.listDirectory(dataDir, recursive: false);
              final meaningful = children.where((p) {
                final base = p.split(RegExp(r'[\\/]')).last;
                return base.isNotEmpty && !base.startsWith('.');
              });
              if (meaningful.isEmpty) {
                await db.storage.deleteDirectory(tableRoot);
              }
            }
          }
        }
      }

      Logger.info(
        'Table data upgrade completed for table: $tableName '
        '(uid=${tableUid.value})',
      );
    } catch (e) {
      Logger.error('Failed to upgrade table data for table $tableName',
          rawError: e);
    }
  }

  /// Locate pre-v2 JSON data root after V3 directory rename.
  ///
  /// 1. `{tables_dirIndex}/{tableUid}/data/main.dat` (normal post-V3)
  /// 2. Same dirIndex with leftover `{tableName}`
  /// 3. Scan `tables_0..highWater` for leftover `{tableName}`
  Future<({String root, bool fromLegacyNamePath})?> _resolveLegacyJsonDataRoot(
    DataStoreImpl db, {
    required TableMeta meta,
    required String tableName,
  }) async {
    final uidRoot = _tableRootFromMeta(db, meta);
    final uidMain = pathJoin(uidRoot, 'data', 'main.dat');
    if (await db.storage.existsFile(uidMain)) {
      return (root: uidRoot, fromLegacyNamePath: false);
    }

    Future<String?> tryNameRoot(int d) async {
      final parent = meta.isGlobal
          ? db.pathManager.getGlobalPath()
          : db.pathManager.getSpacePath();
      final nameRoot = pathJoin(parent, 'tables_$d', tableName);
      final mainPath = pathJoin(nameRoot, 'data', 'main.dat');
      if (await db.storage.existsFile(mainPath)) return nameRoot;
      return null;
    }

    final sameDirName = await tryNameRoot(meta.dirIndex);
    if (sameDirName != null) {
      Logger.warn(
        'Legacy main.dat for [$tableName] found under name path $sameDirName; '
        'UID root $uidRoot has none (V3 move may have been skipped)',
      );
      return (root: sameDirName, fromLegacyNamePath: true);
    }

    final highWater =
        await _legacyDataDirHighWater(db, isGlobal: meta.isGlobal);
    final scanMax = max(meta.dirIndex, highWater);
    for (var d = 0; d <= scanMax; d++) {
      if (d == meta.dirIndex) continue;
      final found = await tryNameRoot(d);
      if (found != null) {
        Logger.warn(
          'Legacy main.dat for [$tableName] found under $found; '
          'expected UID root $uidRoot',
        );
        return (root: found, fromLegacyNamePath: true);
      }
    }

    Logger.info(
      'No legacy main.dat for [$tableName] under UID root $uidRoot '
      '(or leftover name paths); skipping JSON data upgrade',
    );
    return null;
  }

  Future<int> _legacyDataDirHighWater(
    DataStoreImpl db, {
    required bool isGlobal,
  }) async {
    final cfg = await db.getGlobalConfig();
    if (cfg == null) return 0;
    return isGlobal ? cfg.lastGlobalDirIndex : cfg.lastNonGlobalDirIndex;
  }

  String _tableRootFromMeta(DataStoreImpl db, TableMeta meta) {
    final parentDir = meta.isGlobal
        ? db.pathManager.getGlobalPath()
        : db.pathManager.getSpacePath();
    return pathJoin(parentDir, 'tables_${meta.dirIndex}', meta.tableUid);
  }

  /// Parse one legacy JSON partition file under [tableRoot].
  Future<List<Map<String, dynamic>>> _parseOldPartitionFile(
    DataStoreImpl db, {
    required String tableName,
    required String tableRoot,
    required Map<String, dynamic> partitionMeta,
  }) async {
    try {
      final oldPartitionIndex = partitionMeta['index'] as int?;

      if (oldPartitionIndex == null) {
        Logger.warn(
          'Old partition meta missing index for table: $tableName',
        );
        return [];
      }

      final dirIndex = oldPartitionIndex ~/ db.maxEntriesPerDir;
      final oldPartitionPath = pathJoin(tableRoot, 'data', 'partitions',
          'dir_$dirIndex', 'p$oldPartitionIndex.dat');

      if (!await db.storage.existsFile(oldPartitionPath)) {
        return [];
      }

      final partitionBytes = await db.storage.readAsBytes(oldPartitionPath);
      if (partitionBytes.isEmpty) {
        return [];
      }

      final decodedString = EncryptionManager.decode(partitionBytes);
      if (decodedString.isEmpty) {
        return [];
      }

      final partitionJson = jsonDecode(decodedString) as Map<String, dynamic>;

      List<dynamic>? data;
      if (partitionJson.containsKey('data')) {
        data = partitionJson['data'] as List<dynamic>?;
      }

      if (data == null || data.isEmpty) {
        return [];
      }

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
          try {
            final parsed = jsonDecode(item) as Map<String, dynamic>;
            if (parsed['_deleted_'] == true || parsed.isEmpty) {
              continue;
            }
            records.add(parsed);
          } catch (_) {}
        }
      }

      Logger.info(
        'Parsed ${records.length} records from old partition file: '
        '$oldPartitionPath (partition index: $oldPartitionIndex)',
      );

      return records;
    } catch (e) {
      Logger.error('Failed to parse old partition file', rawError: e);
      return [];
    }
  }
}
