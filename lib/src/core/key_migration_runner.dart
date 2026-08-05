import 'dart:async';
import 'dart:typed_data';

import '../handler/logger.dart';
import '../model/applied_encryption.dart';
import '../model/db_exception.dart';
import '../model/background_write_entry.dart';
import '../model/encryption_domain.dart';
import '../model/migration_write_mode.dart';
import '../model/background_write_type.dart';
import '../model/buffer_entry.dart';
import '../model/cancellation_token.dart';
import '../model/key_migration_info.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/system_table.dart';
import '../model/table_context.dart';
import '../model/table_schema.dart' show TableSchema;
import 'data_store_impl.dart';
import 'key_migration_progress.dart';
import 'yield_controller.dart';
import '../model/table_identity.dart';

/// Background key re-encryption via [BackgroundWriteScheduler].
class KeyMigrationRunner {
  KeyMigrationRunner._();

  static const String taskIdPrefix = 'key_migration';

  /// Tables currently undergoing key migration (pause / lifecycle guards).
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

      // Ensure domain flags + natural-turnover snapshots exist.
      await _ensureMigrationInfoPrimed(primaryInstance, targetKeyId);

      // Flush only leftover schema-migration scheduler entries (not entire DB idle).
      await _flushSchedulerEntriesOfType(
        primaryInstance,
        BackgroundWriteType.schemaMigration,
      );
      _throwIfPaused();

      await _rewriteMigrationMetaDomain(primaryInstance);
      _throwIfPaused();

      // Page0 table/index meta (incl. empty trees with meta but no leaves).
      await _rewriteTableAndIndexMetaDomains(primaryInstance);
      _throwIfPaused();

      await _migrateTables(
        primaryInstance,
        targetKeyId: targetKeyId,
        migrateGlobal: true,
        migrateNonGlobal: false,
      );
      _throwIfPaused();

      // Non-global tables on the primary's *current* space (may be user space,
      // not "default" — e.g. mobile stays on login space; default may never open).
      await _migrateTables(
        primaryInstance,
        targetKeyId: targetKeyId,
        migrateGlobal: false,
        migrateNonGlobal: true,
      );
      _throwIfPaused();

      // Every other named space (including "default" when it is not current)
      // via short-lived migration instances.
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
          // Helper close must NOT cancel the primary KeyMigrationRunner token
          // (KeyManager.pauseKeyMigration no-ops for isMigrationInstance).
          await migrationInstance.close();
        }
      }

      await _markDataRewriteDomainsDone(primaryInstance);
      await _refreshNaturalTurnoverDomains(primaryInstance);
      await _finalizeKeyMigration(primaryInstance, keyChangeInfo);
    } on DbClosedException {
      Logger.info(
        'Key migration paused',
      );
    } catch (e) {
      Logger.error('Key migration runner failed', rawError: e);
      final migrationManager = primaryInstance.migrationManager;
      if (migrationManager != null) {
        final existing = await migrationManager.getKeyMigrationInfo();
        await migrationManager.persistKeyMigrationInfo(
          (existing ?? KeyMigrationInfo.start(targetKeyId: targetKeyId))
              .copyWith(status: KeyMigrationStatus.failed),
        );
        await migrationManager.syncHasMigrationTask();
      }
      _activeTableMigrations.clear();
    } finally {
      _runToken = null;
    }
  }

  static Future<void> _ensureMigrationInfoPrimed(
    DataStoreImpl dataStore,
    int targetKeyId,
  ) async {
    final migrationManager = dataStore.migrationManager;
    if (migrationManager == null) return;

    final existing = await migrationManager.getKeyMigrationInfo();
    if (existing != null &&
        existing.isRunning &&
        existing.targetKeyId == targetKeyId) {
      if (existing.snapshots != null) return;
      final snapshots = await captureNaturalSnapshots(dataStore);
      await migrationManager.persistKeyMigrationInfo(
        existing.copyWith(snapshots: snapshots),
      );
      return;
    }

    final snapshots = await captureNaturalSnapshots(dataStore);
    await migrationManager.persistKeyMigrationInfo(
      KeyMigrationInfo.start(
        targetKeyId: targetKeyId,
        snapshots: snapshots,
      ),
    );
  }

  /// Capture WAL / txn / page-redo watermarks for natural-turnover domains.
  static Future<KeyMigrationDomainSnapshots> captureNaturalSnapshots(
    DataStoreImpl dataStore,
  ) async {
    String? walCheckpoint;
    try {
      final walMeta = dataStore.walManager.meta;
      walCheckpoint =
          '${walMeta.checkpoint.partitionIndex}:${walMeta.checkpoint.entrySeq}';
    } catch (_) {
      // Leave null — refresh must not treat missing capture as "done".
    }

    final txnParts = <int>[];
    try {
      final main = dataStore.transactionManager?.mainMeta;
      if (main != null) {
        txnParts.addAll(main.activePartitions);
      }
    } catch (_) {}

    final redoBatches = <String>[];
    try {
      for (final batch in dataStore.walManager.meta.pendingBatches) {
        if (batch.batchId.isNotEmpty) {
          redoBatches.add(batch.batchId);
        }
      }
    } catch (_) {}

    return KeyMigrationDomainSnapshots(
      walCheckpointAtStart: walCheckpoint,
      txnActivePartitionsAtStart: txnParts,
      pageRedoBatchIdsAtStart: redoBatches,
    );
  }

  static Future<void> _rewriteMigrationMetaDomain(
      DataStoreImpl dataStore) async {
    final info = await dataStore.migrationManager?.getKeyMigrationInfo();
    if (info != null && info.isDomainDone(EncryptionDomain.migrationMeta)) {
      return;
    }
    // Persist current meta (re-encrypts under full scope with new encoding key).
    final migrationManager = dataStore.migrationManager;
    if (migrationManager != null && info != null) {
      await migrationManager.persistKeyMigrationInfo(info);
    }
    await _markDomainDone(dataStore, EncryptionDomain.migrationMeta);
  }

  /// Re-encrypt partition page0 [TableDataMeta] / [IndexMeta] under the current
  /// encodingKey. Required for empty trees (meta present, no leaf data) that
  /// the table-data rewrite path skips.
  static Future<void> _rewriteTableAndIndexMetaDomains(
    DataStoreImpl primaryInstance,
  ) async {
    final migrationManager = primaryInstance.migrationManager;
    final info = await migrationManager?.getKeyMigrationInfo();
    final tableMetaDone =
        info?.isDomainDone(EncryptionDomain.tableMeta) ?? false;
    final indexMetaDone =
        info?.isDomainDone(EncryptionDomain.indexMeta) ?? false;
    if (tableMetaDone && indexMetaDone) return;

    Future<void> rewriteOn(
      DataStoreImpl dataStore, {
      required bool migrateGlobal,
      required bool migrateNonGlobal,
    }) async {
      await _rewritePage0MetaForTables(
        dataStore,
        migrateGlobal: migrateGlobal,
        migrateNonGlobal: migrateNonGlobal,
        rewriteTableMeta: !tableMetaDone,
        rewriteIndexMeta: !indexMetaDone,
      );
    }

    await rewriteOn(
      primaryInstance,
      migrateGlobal: true,
      migrateNonGlobal: true,
    );
    _throwIfPaused();

    final globalConfig = await primaryInstance.getGlobalConfig();
    final spaces =
        globalConfig?.spaceNames.toList() ?? [primaryInstance.currentSpaceName];
    final activeSpace = primaryInstance.currentSpaceName;

    for (final space in spaces) {
      if (space == activeSpace) continue;
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
        await rewriteOn(
          migrationInstance,
          migrateGlobal: false,
          migrateNonGlobal: true,
        );
      } finally {
        // See multi-space table loop: helper close must not pause the primary run.
        await migrationInstance.close();
      }
    }

    if (!tableMetaDone) {
      await _markDomainDone(primaryInstance, EncryptionDomain.tableMeta);
    }
    if (!indexMetaDone) {
      await _markDomainDone(primaryInstance, EncryptionDomain.indexMeta);
    }
  }

  static Future<void> _rewritePage0MetaForTables(
    DataStoreImpl dataStore, {
    required bool migrateGlobal,
    required bool migrateNonGlobal,
    required bool rewriteTableMeta,
    required bool rewriteIndexMeta,
  }) async {
    if (!rewriteTableMeta && !rewriteIndexMeta) return;

    final tableNames = await dataStore.getTableNames();
    final yieldController = YieldController(
      'KeyMigrationRunner.rewritePage0Meta',
      checkInterval: 8,
    );

    for (final tableName in tableNames) {
      _throwIfPaused();
      final y1 = yieldController.maybeYield();
      if (y1 != null) await y1;

      if (tableName == SystemTable.keyMigrationProgressTableName) continue;

      final tableUid =
          await dataStore.tableMetaManager?.getUidByName(TableName(tableName));
      if (tableUid == null) continue;
      final table = await dataStore.tableMetaManager?.getTableContext(tableUid);
      if (table == null) continue;

      if (table.isGlobal && !migrateGlobal) continue;
      if (!table.isGlobal && !migrateNonGlobal) continue;

      if (rewriteTableMeta) {
        final meta =
            await dataStore.tableDataManager.getTableDataMeta(table.tableUid);
        if (meta != null) {
          await dataStore.tableDataManager.updateTableDataMeta(
            table,
            meta,
            flush: true,
            persistToDisk: true,
            acquireLock: true,
          );
        }
      }

      if (rewriteIndexMeta) {
        final indexes =
            dataStore.tableMetaManager?.getBtreeIndexesFor(table.schema) ??
                const [];
        for (final index in indexes) {
          _throwIfPaused();
          final y2 = yieldController.maybeYield();
          if (y2 != null) await y2;
          if (index.indexUid.isEmpty) continue;
          final indexMeta =
              await dataStore.treeMetaPageService.readIndexGlobalMeta(
            table.tableUid,
            index.indexUid,
          );
          if (indexMeta == null) continue;
          await dataStore.treeMetaPageService.persistIndexGlobalMeta(
            tableUid: table.tableUid,
            indexUid: index.indexUid,
            meta: indexMeta,
            flush: true,
          );
        }
      }
    }
  }

  static Future<void> _markDataRewriteDomainsDone(
      DataStoreImpl dataStore) async {
    await _markDomainDone(dataStore, EncryptionDomain.tableData);
    await _markDomainDone(dataStore, EncryptionDomain.btreeIndex);

    // Soft: vector pages rewritten with MigrationWriteMode.tableAndIndex when
    // present; explicit NGH full-scan deferred.
    await _markDomainDone(dataStore, EncryptionDomain.vectorIndex);
  }

  static Future<void> _refreshNaturalTurnoverDomains(
      DataStoreImpl dataStore) async {
    final migrationManager = dataStore.migrationManager;
    if (migrationManager == null) return;
    var info = await migrationManager.getKeyMigrationInfo();
    if (info == null) return;

    // Snapshots must exist; do not treat missing as complete.
    if (info.snapshots == null) {
      final snapshots = await captureNaturalSnapshots(dataStore);
      info = info.copyWith(snapshots: snapshots);
      await migrationManager.persistKeyMigrationInfo(info);
    }

    final snapshots = info.snapshots!;

    // WAL: done only when start watermark was captured and checkpoint advanced.
    if (!info.isDomainDone(EncryptionDomain.wal)) {
      var walDone = false;
      if (snapshots.walCheckpointAtStart != null) {
        try {
          final walMeta = dataStore.walManager.meta;
          final current =
              '${walMeta.checkpoint.partitionIndex}:${walMeta.checkpoint.entrySeq}';
          walDone = current != snapshots.walCheckpointAtStart;
        } catch (_) {
          // Keep waiting — do not mark done on read failure.
        }
      }
      if (walDone) {
        info = info.markDomainDone(EncryptionDomain.wal);
      }
    }

    // pageRedoLog: shrink start batch ids against current pending set.
    if (!info.isDomainDone(EncryptionDomain.pageRedoLog)) {
      final remaining = [...snapshots.pageRedoBatchIdsAtStart];
      if (remaining.isEmpty) {
        info = info.markDomainDone(EncryptionDomain.pageRedoLog);
      } else {
        try {
          final current = dataStore.walManager.meta.pendingBatches
              .map((b) => b.batchId)
              .where((id) => id.isNotEmpty)
              .toSet();
          remaining.removeWhere((id) => !current.contains(id));
        } catch (_) {
          // Keep remaining as-is on failure.
        }
        info = info.copyWith(
          snapshots: snapshots.copyWith(pageRedoBatchIdsAtStart: remaining),
        );
        if (remaining.isEmpty) {
          info = info.markDomainDone(EncryptionDomain.pageRedoLog);
        }
      }
    }

    // transactionLog: shrink activePartitions snapshot against current set.
    if (!info.isDomainDone(EncryptionDomain.transactionLog)) {
      final remaining = [...snapshots.txnActivePartitionsAtStart];
      try {
        final current =
            dataStore.transactionManager?.mainMeta?.activePartitions.toSet() ??
                <int>{};
        remaining.removeWhere((p) => !current.contains(p));
      } catch (_) {
        // Keep remaining on failure — do not clear.
      }
      info = info.copyWith(
        snapshots: (info.snapshots ?? snapshots)
            .copyWith(txnActivePartitionsAtStart: remaining),
      );
      if (remaining.isEmpty) {
        info = info.markDomainDone(EncryptionDomain.transactionLog);
      }
    }

    await migrationManager.persistKeyMigrationInfo(info);
  }

  static Future<void> _markDomainDone(
    DataStoreImpl dataStore,
    EncryptionDomain domain,
  ) async {
    final migrationManager = dataStore.migrationManager;
    if (migrationManager == null) return;
    final info = await migrationManager.getKeyMigrationInfo();
    if (info == null || info.isDomainDone(domain)) return;
    await migrationManager.persistKeyMigrationInfo(info.markDomainDone(domain));
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

      final scope = scopeForTable(dataStore, table);

      // Empty leaf tree: page0 meta already handled by tableMeta/indexMeta
      // domains; nothing left for tableData/btreeIndex rewrite.
      final tableDataMeta =
          await dataStore.tableDataManager.getTableDataMeta(table.tableUid);
      if (tableDataMeta == null || tableDataMeta.btreeFirstLeaf.isNull) {
        await KeyMigrationProgressStore.markCompleted(
          dataStore,
          table: table,
          spaceName: scope,
        );
        continue;
      }

      // Only skip when progress store already records completed for this run.
      if (await KeyMigrationProgressStore.isCompleted(
        dataStore,
        table: table,
        spaceName: scope,
      )) {
        continue;
      }

      _activeTableMigrations.add(table.tableUid);
      try {
        final startCursor = await KeyMigrationProgressStore.loadCheckpoint(
          dataStore,
          table: table,
          spaceName: scope,
        );
        await dataStore.cacheManager.invalidateCache(table);

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
              final y3 = yieldController.maybeYield();
              if (y3 != null) await y3;
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
          // Indexes remain complete under mixed keyIds + fallbackKeys.
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

  /// Drain key-migration scheduler queue; incomplete drain must not mark tables done.
  static Future<void> _drainBackgroundWrites(DataStoreImpl dataStore) async {
    var rounds = 0;
    while (dataStore.backgroundWriteScheduler
        .hasPendingEntriesOfType(BackgroundWriteType.keyMigration)) {
      if (isPauseRequested) {
        throw DbClosedException('Key migration paused');
      }
      if (++rounds > 512) {
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message:
                'Key migration drain hit round limit with pending keyMigration '
                'scheduler entries; refusing to mark table completed',
          ),
        ]);
      }
      await dataStore.parallelJournalManager.flushCompletely();
    }
  }

  static Future<void> _finalizeKeyMigration(
    DataStoreImpl dataStore,
    KeyChangeInfo keyChangeInfo,
  ) async {
    final global = await dataStore.getGlobalConfig();
    if (global == null) {
      Logger.error(
        'GlobalConfig missing when finalizing key migration',
      );
      return;
    }

    final migrationManager = dataStore.migrationManager;
    final info = await migrationManager?.getKeyMigrationInfo();
    final allDone = info?.allDomainsComplete ?? false;

    final applied = global.appliedEncryption ?? AppliedEncryption.empty();
    final history = [...applied.historyKeys];

    // Early promote: current should already be the target. Legacy path still
    // moves a mismatched current into history.
    if (applied.current.key.isNotEmpty &&
        applied.current.keyId != keyChangeInfo.newKeyId &&
        !history.any((k) => k.keyId == applied.current.keyId)) {
      history.add(applied.current);
    }

    final completedAt = allDone ? DateTime.now().toUtc() : null;
    final newCurrent = EncryptionKeyInfo(
      key: keyChangeInfo.plainEncodingKey,
      keyId: keyChangeInfo.newKeyId,
      migrationCompletedAt: completedAt,
    );

    final stampedHistory = history.map((k) {
      if (completedAt != null &&
          k.keyId < keyChangeInfo.newKeyId &&
          k.migrationCompletedAt == null) {
        return k.copyWith(migrationCompletedAt: completedAt);
      }
      return k;
    }).toList();

    await dataStore.saveGlobalConfig(
      global.copyWith(
        appliedEncryption: AppliedEncryption(
          current: newCurrent,
          historyKeys: stampedHistory,
        ),
      ),
      propagateErrors: true,
    );

    await KeyMigrationProgressStore.clearAll(dataStore);

    if (migrationManager != null) {
      if (allDone) {
        if (info != null) {
          await migrationManager.persistKeyMigrationInfo(
            info.copyWith(status: KeyMigrationStatus.completed),
          );
        }
        await migrationManager.clearKeyMigrationInfo();
        await migrationManager.syncHasMigrationTask();
        Logger.info(
          'Key migration fully completed for keyId ${keyChangeInfo.newKeyId}',
        );
      } else {
        // Keep running until natural-turnover domains finish.
        Logger.info(
          'Key migration rewrite done for keyId ${keyChangeInfo.newKeyId}; '
          'waiting for natural-turnover domains',
        );
        await migrationManager.syncHasMigrationTask();
      }
    }
  }

  /// Public entry for resume path: refresh natural domains and stamp completedAt.
  static Future<void> refreshNaturalTurnoverAndMaybeComplete(
    DataStoreImpl dataStore,
  ) async {
    await _refreshNaturalTurnoverDomains(dataStore);
    final info = await dataStore.migrationManager?.getKeyMigrationInfo();
    if (info == null || !info.allDomainsComplete) return;

    final global = await dataStore.getGlobalConfig();
    final applied = global?.appliedEncryption;
    if (global == null || applied == null) return;

    final completedAt = DateTime.now().toUtc();
    final current = applied.current.keyId == info.targetKeyId
        ? applied.current.copyWith(migrationCompletedAt: completedAt)
        : applied.current;

    final stampedHistory = applied.historyKeys.map((k) {
      if (k.keyId < info.targetKeyId && k.migrationCompletedAt == null) {
        return k.copyWith(migrationCompletedAt: completedAt);
      }
      return k;
    }).toList();

    await dataStore.saveGlobalConfig(
      global.copyWith(
        appliedEncryption: applied.copyWith(
          current: current,
          historyKeys: stampedHistory,
        ),
      ),
      propagateErrors: true,
    );

    await KeyMigrationProgressStore.clearAll(dataStore);
    await dataStore.migrationManager?.persistKeyMigrationInfo(
      info.copyWith(status: KeyMigrationStatus.completed),
    );
    await dataStore.migrationManager?.clearKeyMigrationInfo();
    await dataStore.migrationManager?.syncHasMigrationTask();
    Logger.info(
      'Key migration natural-turnover completed for keyId ${info.targetKeyId}',
    );
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
}

/// Key change payload passed into the migration runner.
class KeyChangeInfo {
  final bool hasChanged;
  final Uint8List newKey;
  final int newKeyId;

  /// Plaintext encodingKey to persist in [AppliedEncryption.current].
  final String plainEncodingKey;

  KeyChangeInfo({
    required this.hasChanged,
    required this.newKey,
    required this.newKeyId,
    required this.plainEncodingKey,
  });
}
