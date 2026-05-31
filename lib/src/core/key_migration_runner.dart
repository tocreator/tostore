import 'dart:async';
import 'dart:typed_data';

import '../handler/encoder.dart';
import '../handler/logger.dart';
import '../model/background_write_entry.dart';
import '../model/background_write_mode.dart';
import '../model/background_write_type.dart';
import '../model/buffer_entry.dart';
import '../model/cancellation_token.dart';
import '../model/key_migration_info.dart';
import '../model/meta_info.dart';
import '../model/space_config.dart';
import '../model/system_table.dart';
import '../model/table_schema.dart' show IndexSchema, IndexType, TableSchema;
import 'data_store_impl.dart';
import 'key_migration_progress.dart';
import 'yield_controller.dart';

/// Thrown when key migration is paused (e.g. close / switchSpace) for later resume.
class KeyMigrationPausedException implements Exception {
  const KeyMigrationPausedException();

  @override
  String toString() => 'Key migration paused';
}

/// Background key re-encryption via [BackgroundWriteScheduler].
class KeyMigrationRunner {
  KeyMigrationRunner._();

  static const String taskIdPrefix = 'key_migration';

  /// Tables currently undergoing key migration (for index isBuilding guard).
  static final Set<String> _activeTableMigrations = <String>{};

  static CancellationToken? _runToken;

  static String taskIdForTable(String tableName) => '$taskIdPrefix:$tableName';

  static bool isKeyMigrationTaskId(String taskId) =>
      taskId.startsWith('$taskIdPrefix:');

  static String? tableNameFromTaskId(String taskId) {
    if (!isKeyMigrationTaskId(taskId)) return null;
    return taskId.substring(taskIdPrefix.length + 1);
  }

  static bool isTableMigrating(String tableName) =>
      _activeTableMigrations.contains(tableName);

  static bool get isRunning => _runToken != null;

  static bool get isPauseRequested => _runToken?.isCancelled ?? false;

  /// Request cooperative pause; in-flight work stops at the next checkpoint.
  static void requestPause() {
    _runToken?.cancel();
  }

  /// Called from [DataStoreImpl.close] / switchSpace before shutting down PJM.
  static Future<void> pauseForShutdown(DataStoreImpl dataStore) async {
    requestPause();
    await _flushSchedulerEntriesOfType(
      dataStore,
      BackgroundWriteType.keyMigration,
      respectPause: false,
      maxRounds: 64,
    );
  }

  static void _throwIfPaused() {
    if (isPauseRequested) {
      throw const KeyMigrationPausedException();
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
          label: 'KeyMigrationRunner.run',
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
    } on KeyMigrationPausedException {
      Logger.info(
        'Key migration paused',
        label: 'KeyMigrationRunner.run',
      );
    } catch (e, stack) {
      Logger.error(
        'Key migration runner failed: $e\n$stack',
        label: 'KeyMigrationRunner.run',
      );
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

      final schema = await dataStore.schemaManager?.getTableSchema(tableName);
      if (schema == null) continue;
      if (schema.isGlobal && !migrateGlobal) continue;
      if (!schema.isGlobal && !migrateNonGlobal) continue;

      if (await _isTableAlreadyMigrated(dataStore, tableName, targetKeyId)) {
        final scope = await scopeForTable(dataStore, tableName);
        await KeyMigrationProgressStore.markCompleted(
          dataStore,
          tableName: tableName,
          spaceName: scope,
        );
        continue;
      }

      _activeTableMigrations.add(tableName);
      try {
        final scope = await scopeForTable(dataStore, tableName);
        await _purgeTableIndexes(dataStore, tableName);
        await dataStore.cacheManager.invalidateCache(tableName);

        final startCursor = await KeyMigrationProgressStore.loadCheckpoint(
          dataStore,
          tableName: tableName,
          spaceName: scope,
        );

        await KeyMigrationProgressStore.upsertRunning(
          dataStore,
          tableName: tableName,
          spaceName: scope,
          checkpointKey: startCursor,
        );

        final pkName = schema.primaryKey;

        await dataStore.queryExecutor.queryEachBatch(
          tableName,
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

            for (final record in records) {
              if (isPauseRequested) return false;
              await yieldController.maybeYield();
              final pk = record[pkName]?.toString() ?? '';
              if (pk.isEmpty) continue;

              final entry = BufferEntry(
                operation: BufferOperationType.rewrite,
                data: record,
                timestamp: DateTime.now(),
              );

              dataStore.backgroundWriteScheduler.addEntry(
                BackgroundWriteEntry(
                  taskId: taskIdForTable(tableName),
                  tableName: tableName,
                  primaryKey: pk,
                  type: BackgroundWriteType.keyMigration,
                  mode: BackgroundWriteMode.tableAndIndex,
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
          await _drainBackgroundWrites(dataStore);
          throw const KeyMigrationPausedException();
        }

        await _drainBackgroundWrites(dataStore);

        await KeyMigrationProgressStore.markCompleted(
          dataStore,
          tableName: tableName,
          spaceName: scope,
        );
      } catch (e, stack) {
        if (e is KeyMigrationPausedException) rethrow;
        Logger.error(
          'Key migration failed for table $tableName: $e\n$stack',
          label: 'KeyMigrationRunner._migrateTables',
        );
        rethrow;
      } finally {
        _activeTableMigrations.remove(tableName);
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
          label: 'KeyMigrationRunner._flushSchedulerEntriesOfType',
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
          label: 'KeyMigrationRunner._drainBackgroundWrites',
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
        label: 'KeyMigrationRunner._finalizeKeyMigration',
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
      label: 'KeyMigrationRunner._finalizeKeyMigration',
    );
  }

  static Future<void> _purgeTableIndexes(
      DataStoreImpl dataStore, String tableName) async {
    final schema = await dataStore.schemaManager?.getTableSchema(tableName);
    if (schema == null) return;

    final indexes = <IndexSchema>[
      ...schema.getAllIndexes(),
      ...?dataStore.indexManager
          ?.getEngineManagedBtreeIndexes(tableName, schema),
    ];

    final indexManager = dataStore.indexManager;
    if (indexManager == null) return;

    for (final index in indexes) {
      if (index.type == IndexType.vector) continue;
      await indexManager.deletePhysicalIndexArtifacts(
        tableName,
        index.actualIndexName,
      );
    }
  }

  static Future<String> scopeForTable(
      DataStoreImpl dataStore, String tableName) async {
    final schema = await dataStore.schemaManager?.getTableSchema(tableName);
    return _scopeForSchema(dataStore, schema);
  }

  static String _scopeForSchema(DataStoreImpl? dataStore, TableSchema? schema) {
    if (schema?.isGlobal == true) {
      return SystemTable.globalMigrationScope;
    }
    return dataStore?.currentSpaceName ?? 'default';
  }

  static Future<bool> _isTableAlreadyMigrated(
    DataStoreImpl dataStore,
    String tableName,
    int targetKeyId,
  ) async {
    try {
      final tableMeta =
          await dataStore.tableDataManager.getTableMeta(tableName);
      if (tableMeta == null || tableMeta.btreeFirstLeaf.isNull) {
        return true;
      }
      final firstLeaf = tableMeta.btreeFirstLeaf;
      final lastLeaf = tableMeta.btreeLastLeaf;
      final btreePageSize = tableMeta.btreePageSize;

      Future<bool> checkPage(TreePagePtr leaf) async {
        if (leaf.isNull) return true;
        final path = await dataStore.pathManager
            .getPartitionFilePathByNo(tableName, leaf.partitionNo);
        final fileSize = await dataStore.storage.getFileSize(path);
        final offset = leaf.pageNo * btreePageSize + 20;
        if (fileSize < offset + 32) return false;
        final bytes = await dataStore.storage.readAsBytesAt(
          path,
          offset,
          length: 32,
        );
        return EncoderHandler.parseKeyId(bytes) == targetKeyId;
      }

      if (!await checkPage(firstLeaf)) return false;
      if (lastLeaf != firstLeaf) {
        return await checkPage(lastLeaf);
      }
      return true;
    } catch (e) {
      Logger.warn(
        'Could not probe key migration state for $tableName: $e',
        label: 'KeyMigrationRunner._isTableAlreadyMigrated',
      );
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
