import 'dart:async';
import 'dart:typed_data';

import '../handler/encryption.dart';
import '../handler/logger.dart';
import '../model/db_exception.dart';
import '../model/background_write_entry.dart';
import '../model/migration_write_mode.dart';
import '../model/background_write_type.dart';
import '../model/buffer_entry.dart';
import '../model/cancellation_token.dart';
import '../model/key_migration_info.dart';
import '../model/meta_info.dart';
import '../model/space_config.dart';
import '../model/system_table.dart';
import '../model/table_context.dart';
import '../model/table_schema.dart' show IndexSchema, IndexType, TableSchema;
import 'data_store_impl.dart';
import 'key_migration_progress.dart';
import 'yield_controller.dart';
import '../model/table_identity.dart';

/// Background key re-encryption via [BackgroundWriteScheduler].
class KeyMigrationRunner {
  KeyMigrationRunner._();

  static const String taskIdPrefix = 'key_migration';

  /// Tables currently undergoing key migration (for index isBuilding guard).
  static final Set<String> _activeTableMigrations = <String>{};

  static CancellationToken? _runToken;

  static String taskIdForTable(TableContext table) =>
      '$taskIdPrefix:${table.tableUid}';

  static bool isKeyMigrationTaskId(String taskId) =>
      taskId.startsWith('$taskIdPrefix:');

  static String? tableUidFromTaskId(String taskId) {
    if (!isKeyMigrationTaskId(taskId)) return null;
    return taskId.substring(taskIdPrefix.length + 1);
  }

  static bool isTableMigrating(TableContext table) =>
      _activeTableMigrations.contains(table.tableUid);

  static bool get isRunning => _runToken != null;

  static bool get isPauseRequested => _runToken?.isCancelled ?? false;

  /// Request cooperative pause; in-flight work stops at the next checkpoint.
  static void requestPause() {
    _runToken?.cancel();
  }

  static void _throwIfPaused() {
    if (isPauseRequested) {
      throw DbClosedException('Key migration paused');
    }
  }

  static Future<void> run(
    DataStoreImpl primaryInstance, {
    required int targetKeyId,
    required KeyChangeInfo keyChangeInfo,
  }) async {
    _runToken = CancellationToken();
    try {
      _throwIfPaused();

      final migrationManager = primaryInstance.migrationManager;
      if (migrationManager != null && migrationManager.hasPendingTasks) {
        Logger.info(
          'Completing pending schema migration before key migration',
        );
        await migrationManager.processMigrationTasks();
        _throwIfPaused();
      }

      await primaryInstance.parallelJournalManager.waitUntilRecoveryCompleted();
      await KeyMigrationProgressStore.ensureTable(primaryInstance);

      // Flush only leftover schema-migration scheduler entries (not entire DB idle).
      await _flushSchedulerEntriesOfType(
        primaryInstance,
        BackgroundWriteType.schemaMigration,
      );
      _throwIfPaused();

      await _migrateTables(
        primaryInstance,
        targetKeyId: targetKeyId,
        migrateGlobal: true,
        migrateNonGlobal: false,
      );
      _throwIfPaused();

      // Non-global tables: active space on primary.
      await _migrateTables(
        primaryInstance,
        targetKeyId: targetKeyId,
        migrateGlobal: false,
        migrateNonGlobal: true,
      );
      _throwIfPaused();

      // Non-global tables: other spaces via migration instances.
      final globalConfig = await primaryInstance.getGlobalConfig();
      final spaces = globalConfig?.spaceNames.toList() ??
          [primaryInstance.currentSpaceName];
      final activeSpace = primaryInstance.currentSpaceName;

      for (final space in spaces) {
        if (space == activeSpace) continue;
        _throwIfPaused();

        await _drainBackgroundWrites(primaryInstance);
        _throwIfPaused();

        final migrationInstance = DataStoreImpl(
          dbPath: primaryInstance.config.dbPath,
          dbName: primaryInstance.config.dbName,
          config: primaryInstance.config.copyWith(spaceName: space),
          isMigrationInstance: true,
        );

        try {
          await migrationInstance.initialize();
          _throwIfPaused();
          await _migrateTables(
            migrationInstance,
            targetKeyId: targetKeyId,
            migrateGlobal: false,
            migrateNonGlobal: true,
          );
          await _drainBackgroundWrites(migrationInstance);
        } finally {
          await migrationInstance.close();
        }
      }

      await _finalizeKeyMigration(primaryInstance, keyChangeInfo);
    } on DbClosedException {
      Logger.info(
        'Key migration paused',
      );
    } catch (e) {
      Logger.error('Key migration runner failed', rawError: e);
      final migrationManager = primaryInstance.migrationManager;
      if (migrationManager != null) {
        await migrationManager.persistKeyMigrationInfo(
          KeyMigrationInfo(
            targetKeyId: targetKeyId,
            status: KeyMigrationStatus.failed,
            createdAt: DateTime.now().toIso8601String(),
          ),
        );
        await migrationManager.syncHasMigrationTask();
      }
      _activeTableMigrations.clear();
    } finally {
      _runToken = null;
    }
  }

  static Future<void> _migrateTables(
    DataStoreImpl dataStore, {
    required int targetKeyId,
    required bool migrateGlobal,
    required bool migrateNonGlobal,
  }) async {
    final tableNames = await dataStore.getTableNames();
    final writeBatchSize = dataStore.config.writeBatchSize;

    for (final tableName in tableNames) {
      _throwIfPaused();

      if (tableName == SystemTable.keyMigrationProgressTableName) continue;

      final tableUid =
          await dataStore.tableMetaManager?.getUidByName(TableName(tableName));
      if (tableUid == null) continue;
      final table = await dataStore.tableMetaManager?.getTableContext(tableUid);
      if (table == null) continue;

      if (table.isGlobal && !migrateGlobal) continue;
      if (!table.isGlobal && !migrateNonGlobal) continue;

      if (await _isTableAlreadyMigrated(dataStore, table, targetKeyId)) {
        final scope = scopeForTable(dataStore, table);
        await KeyMigrationProgressStore.markCompleted(
          dataStore,
          table: table,
          spaceName: scope,
        );
        continue;
      }

      _activeTableMigrations.add(table.tableUid);
      try {
        final scope = scopeForTable(dataStore, table);
        await _purgeTableIndexes(dataStore, table);
        await dataStore.cacheManager.invalidateCache(table);

        final startCursor = await KeyMigrationProgressStore.loadCheckpoint(
          dataStore,
          table: table,
          spaceName: scope,
        );

        await KeyMigrationProgressStore.upsertRunning(
          dataStore,
          table: table,
          spaceName: scope,
          checkpointKey: startCursor,
        );

        final pkName = table.schema.primaryKey;

        await dataStore.queryExecutor.queryEachBatch(
          table,
          batchSize: writeBatchSize,
          checkpointCursor: startCursor,
          cancellationToken: _runToken,
          onBatch: (records, currentCursor, nextCursor) async {
            if (isPauseRequested) return false;

            await dataStore.backgroundWriteScheduler.waitIfCongested(
              writeBatchSize,
              dataStore.writeBufferManager.queueLength,
              cancellationToken: _runToken,
            );

            if (records.isEmpty) return true;

            final yieldController = YieldController(
              'KeyMigrationRunner.enqueue',
              checkInterval: 64,
            );

            var entryVersion = table.schema.schemaVersion ?? '';
            if (dataStore.migrationManager
                    ?.hasRuntimeMigrationForTable(table) ??
                false) {
              entryVersion = '';
            }

            for (final record in records) {
              if (isPauseRequested) return false;
              await yieldController.maybeYield();
              final pk = record[pkName]?.toString() ?? '';
              if (pk.isEmpty) continue;

              final entry = BufferEntry(
                operation: BufferOperationType.rewrite,
                data: record,
                timestamp: DateTime.now(),
                schemaVersion: entryVersion,
              );

              dataStore.backgroundWriteScheduler.addEntry(
                BackgroundWriteEntry(
                  taskId: taskIdForTable(table),
                  tableUid: table.tableUid,
                  primaryKey: pk,
                  type: BackgroundWriteType.keyMigration,
                  mode: MigrationWriteMode.tableAndIndex,
                  entry: entry,
                  currentCursor: currentCursor,
                  nextCursor: nextCursor,
                ),
                pk,
              );
            }

            dataStore.parallelJournalManager.scheduleFlushIfNeeded();
            return true;
          },
        );

        if (isPauseRequested) {
          // Do not drain: close/cutover clears unpersisted scheduler entries.
          throw DbClosedException('Key migration paused');
        }

        await _drainBackgroundWrites(dataStore);

        await KeyMigrationProgressStore.markCompleted(
          dataStore,
          table: table,
          spaceName: scope,
        );
      } catch (e) {
        if (e is DbClosedException) rethrow;
        Logger.error('Key migration failed for table ${table.tableName}',
            rawError: e);
        rethrow;
      } finally {
        _activeTableMigrations.remove(table.tableUid);
      }
    }
  }

  /// Flush scheduler entries of [type] already enqueued (bounded, not full task completion).
  static Future<void> _flushSchedulerEntriesOfType(
    DataStoreImpl dataStore,
    BackgroundWriteType type, {
    bool respectPause = true,
    int maxRounds = 512,
  }) async {
    var rounds = 0;
    while (dataStore.backgroundWriteScheduler.hasPendingEntriesOfType(type)) {
      if (respectPause && isPauseRequested) break;
      if (++rounds > maxRounds) {
        Logger.warn(
          'Stopped flushing $type scheduler entries after $maxRounds rounds',
        );
        break;
      }
      await dataStore.parallelJournalManager.flushCompletely();
    }
  }

  /// Drain this instance's key-migration scheduler queue (per-table boundary).
  static Future<void> _drainBackgroundWrites(DataStoreImpl dataStore) async {
    var rounds = 0;
    while (!dataStore.backgroundWriteScheduler.isEmpty) {
      if (isPauseRequested) break;
      if (++rounds > 512) {
        Logger.warn(
          'Background write drain hit round limit; scheduler may still have entries',
        );
        break;
      }
      await dataStore.parallelJournalManager.flushCompletely();
    }
  }

  static Future<void> _finalizeKeyMigration(
    DataStoreImpl dataStore,
    KeyChangeInfo keyChangeInfo,
  ) async {
    final spaceConfig = await dataStore.getSpaceConfig();
    if (spaceConfig == null) {
      Logger.error(
        'Space config missing when finalizing key migration',
      );
      return;
    }

    await dataStore.saveSpaceConfigToFile(
      spaceConfig.copyWith(
        current: EncryptionKeyInfo(
          key: keyChangeInfo.encryptKey,
          keyId: keyChangeInfo.newKeyId,
        ),
        previous: spaceConfig.current,
        historyKeys: const [],
      ),
    );

    await KeyMigrationProgressStore.clearAll(dataStore);

    final migrationManager = dataStore.migrationManager;
    if (migrationManager != null) {
      await migrationManager.persistKeyMigrationInfo(
        KeyMigrationInfo(
          targetKeyId: keyChangeInfo.newKeyId,
          status: KeyMigrationStatus.completed,
          createdAt: DateTime.now().toIso8601String(),
        ),
      );
      await migrationManager.clearKeyMigrationInfo();
      await migrationManager.syncHasMigrationTask();
    }

    Logger.info(
      'Key migration completed for keyId ${keyChangeInfo.newKeyId}',
    );
  }

  static Future<void> _purgeTableIndexes(
      DataStoreImpl dataStore, TableContext table) async {
    final indexes = <IndexSchema>[
      ...table.schema.getAllIndexes(),
      ...?dataStore.indexManager
          ?.getEngineManagedBtreeIndexes(table, table.schema),
    ];

    final indexManager = dataStore.indexManager;
    if (indexManager == null) return;

    for (final index in indexes) {
      if (index.type == IndexType.vector) continue;
      await indexManager.deletePhysicalIndexArtifacts(
        table,
        index.indexUid,
      );
    }
  }

  static String scopeForTable(DataStoreImpl dataStore, TableContext table) {
    return _scopeForSchema(dataStore, table.schema);
  }

  static String _scopeForSchema(DataStoreImpl? dataStore, TableSchema? schema) {
    if (schema?.isGlobal == true) {
      return SystemTable.globalMigrationScope;
    }
    return dataStore?.currentSpaceName ?? 'default';
  }

  static Future<bool> _isTableAlreadyMigrated(
    DataStoreImpl dataStore,
    TableContext table,
    int targetKeyId,
  ) async {
    try {
      final tableDataMeta =
          await dataStore.tableDataManager.getTableDataMeta(table.tableUid);
      if (tableDataMeta == null || tableDataMeta.btreeFirstLeaf.isNull) {
        return true;
      }
      final firstLeaf = tableDataMeta.btreeFirstLeaf;
      final lastLeaf = tableDataMeta.btreeLastLeaf;
      final btreePageSize = dataStore.configuredPageSize;

      Future<bool> checkPage(TreePagePtr leaf) async {
        if (leaf.isNull) return true;
        final path = await dataStore.pathManager
            .getPartitionFilePathByNo(table.tableUid, leaf.partitionNo);
        final fileSize = await dataStore.storage.getFileSize(path);
        final offset = leaf.pageNo * btreePageSize + 20;
        if (fileSize < offset + 32) return false;
        final bytes = await dataStore.storage.readAsBytesAt(
          path,
          offset,
          length: 32,
        );
        return EncryptionManager.parseKeyId(bytes) == targetKeyId;
      }

      if (!await checkPage(firstLeaf)) return false;
      if (lastLeaf != firstLeaf) {
        return await checkPage(lastLeaf);
      }
      return true;
    } catch (e) {
      Logger.warn('Could not probe key migration state for ${table.tableName}',
          rawError: e);
      return false;
    }
  }
}

/// Key change payload passed into the migration runner.
class KeyChangeInfo {
  final bool hasChanged;
  final Uint8List newKey;
  final int newKeyId;
  final String encryptKey;

  KeyChangeInfo({
    required this.hasChanged,
    required this.newKey,
    required this.newKeyId,
    required this.encryptKey,
  });
}
