import 'dart:async';
import 'dart:collection';

import '../handler/logger.dart';
import '../model/buffer_entry.dart';
import '../model/db_exception.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/table_context.dart';
import '../model/table_identity.dart';
import '../model/table_schema.dart';
import '../model/unique_violation.dart';
import '../model/wal_pointer.dart';
import 'buffer_tree_store.dart';
import 'cpu_work_chunk.dart';
import 'crontab_manager.dart';
import 'data_store_impl.dart';
import 'yield_controller.dart';

/// Ordered WAL flush queue entry (no full row payload; data lives in TreeCache).
class WriteQueueEntry {
  TableUid tableUid;
  final String recordId;
  final WalPointer walPointer;

  WriteQueueEntry({
    required this.tableUid,
    required this.recordId,
    required this.walPointer,
  });
}

/// Manages pending/txn TreeCaches and the WAL-ordered write queue.
class WriteBufferManager {
  final DataStoreImpl _dataStore;
  late final BufferTreeStore trees;

  final Map<TableUid, int> _tableClearEpochs = <TableUid, int>{};
  int _globalClearEpoch = 0;
  final Queue<WriteQueueEntry> _writeQueue = Queue<WriteQueueEntry>();
  final StreamController<int> _sizeController =
      StreamController<int>.broadcast();

  /// Rollback paths from the latest successful [tryReserveUniques] per record.
  final Map<String, List<List<dynamic>>> _lastReserveRollback =
      <String, List<List<dynamic>>>{};

  WriteBufferManager(this._dataStore) {
    trees = BufferTreeStore(_dataStore);
  }

  BufferTreeStore get bufferTrees => trees;

  bool get isEmpty => _writeQueue.isEmpty;
  int get queueLength => _writeQueue.length;

  bool hasPendingWritesForUid(TableUid tableUid) =>
      trees.hasPendingWritesForUid(tableUid);

  Stream<int> get sizeStream => _sizeController.stream;

  void _emitSizeChanged() {
    try {
      _sizeController.add(_writeQueue.length);
    } catch (_) {}
  }

  /// Drain deferred flushed-evict tasks, then idle-clear pending trees if safe.
  void tryDrainAndIdleClear() {
    trees.tryDrainFlushedEvict(onIdle: tryClearPendingTreesWhenIdle);
  }

  /// When flush queue is empty, no read view needs merge, no flushed-evict
  /// tasks remain, and no flush is in-flight, drop pending record/index trees.
  ///
  /// Must not clear while [ParallelJournalManager.isFlushInProgress]: the queue
  /// may already be empty after popBatch while disk write is still running.
  ///
  /// Guards ordered for the common busy case: queue non-empty -> return first.
  void tryClearPendingTreesWhenIdle() {
    if (_writeQueue.isNotEmpty) return;
    if (_dataStore.parallelJournalManager.isFlushInProgress) return;
    if (trees.hasPendingFlushedEvict) return;
    if (_dataStore.readViewManager.hasActiveViews) return;
    trees.clearPendingCaches();
    _emitSizeChanged();
  }

  int getClearEpoch(TableContext table) {
    return (_tableClearEpochs[table.tableUid] ?? 0) + _globalClearEpoch;
  }

  String _reserveKey(TableUid tableUid, String recordId, String? txId) =>
      '${txId ?? ''}|$tableUid|$recordId';

  void removeRecord(TableContext table, String recordId) {
    final tableUid = table.tableUid;
    final prior = trees.getPendingRecord(tableUid, recordId);
    if (prior != null) {
      trees.removeRecordEntirely(
        table: table,
        schema: table.schema,
        pk: recordId,
      );
    }
    if (_writeQueue.isNotEmpty) {
      _writeQueue
          .removeWhere((e) => e.tableUid == tableUid && e.recordId == recordId);
      _emitSizeChanged();
    }
  }

  /// Apply entry into pending record/index trees and enqueue for flush.
  Future<void> addRecord({
    required TableContext table,
    required String recordId,
    required BufferEntry entry,
    Set<String>? changedFields,
    bool updateStats = true,
  }) async {
    trees.ensureComparators(table, table.schema);
    final prior = trees.getPendingRecord(table.tableUid, recordId);
    bool skipQueueEnqueue = false;

    if (prior != null &&
        prior.operation == BufferOperationType.insert &&
        entry.operation == BufferOperationType.update) {
      skipQueueEnqueue = true;
    }

    final bool restoreDeletedCount = prior != null &&
        prior.operation == BufferOperationType.delete &&
        entry.operation == BufferOperationType.insert;

    final BufferEntry? effective;
    if (prior == null && entry.operation == BufferOperationType.insert) {
      trees.applyVirginInsert(
        table: table,
        schema: table.schema,
        pk: recordId,
        entry: entry,
      );
      effective = entry;
    } else {
      effective = trees.applyRecord(
        table: table,
        schema: table.schema,
        pk: recordId,
        entry: entry,
        changedFields: changedFields,
      );
    }
    commitReservedUniques(
      table: table,
      recordId: recordId,
      transactionId: entry.transactionId,
    );

    if (!skipQueueEnqueue && effective != null) {
      _dataStore.backgroundWriteScheduler.handleOnlineWrite(table, recordId);
      final bp = _dataStore.parallelJournalManager.applyEnqueueBackpressure();
      if (bp != null) await bp;
      if (updateStats) {
        if (restoreDeletedCount) {
          await _dataStore.tableDataManager
              .updateTableRecordCount(table, BufferOperationType.insert);
        } else {
          await _dataStore.tableDataManager
              .updateTableRecordCount(table, effective.operation);
        }
      }
      final wp = effective.walPointer;
      if (wp == null) {
        Logger.warn(
          'addRecord missing walPointer: table=${table.tableName} pk=$recordId',
        );
      } else {
        _writeQueue.add(WriteQueueEntry(
          tableUid: table.tableUid,
          recordId: recordId,
          walPointer: wp,
        ));
        _emitSizeChanged();
      }
    } else if (effective == null && !skipQueueEnqueue) {
      // Cancelled insert still may need a delete tombstone in queue if insert
      // was already queued -- enqueue delete when caller provided delete entry.
      if (entry.operation == BufferOperationType.delete &&
          entry.walPointer != null) {
        _writeQueue.add(WriteQueueEntry(
          tableUid: table.tableUid,
          recordId: recordId,
          walPointer: entry.walPointer!,
        ));
        _emitSizeChanged();
      }
    }
    CrontabManager.notifyActivity();
  }

  Future<void> addInsertBatch({
    required TableContext table,
    required List<String> recordIds,
    required List<BufferEntry> entries,

    /// Commit->pending: one pass installs PK+unique+non-unique.
    /// Online after reserve: false -> non-unique only.
    bool installAllIndexes = false,
  }) async {
    if (recordIds.isEmpty) return;
    if (recordIds.length != entries.length) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.engError,
          message:
              'addInsertBatch length mismatch: recordIds=${recordIds.length}, entries=${entries.length}',
          parameterName: 'recordIds/entries',
          passedValue: {
            'recordIdsLength': recordIds.length,
            'entriesLength': entries.length,
          },
        )
      ]);
    }

    await _dataStore.tableDataManager.updateTableRecordCountDelta(
      table,
      insertDelta: recordIds.length,
    );

    final schema = table.schema;
    // Hoist once: includeUniques decided by [installAllIndexes].
    final indexPlan = trees.prepareIndexWritePlan(
      table,
      schema,
      includeUniques: installAllIndexes,
    );
    final yieldController = YieldController(
      'WriteBufferManager.addInsertBatch',
      minCheckInterval: EngineCpuChunk.hotPathMinCheckInterval,
    );
    final int emitChunk = EngineCpuChunk.sizeFor(CpuChunkKind.light);
    final tableUid = table.tableUid;
    final bgScheduler = _dataStore.backgroundWriteScheduler;
    final bool bgMaybeActive = !bgScheduler.isEmpty;
    // Commit apply always lands in pending (tx overlays cleared after).
    final String? batchTxId = installAllIndexes
        ? null
        : (entries.isEmpty ? null : entries.first.transactionId);

    for (int i = 0; i < recordIds.length; i++) {
      final y = yieldController.maybeYield();
      if (y != null) await y;
      if (i % emitChunk == 0) {
        final bp = _dataStore.parallelJournalManager
            .applyEnqueueBackpressure(emitChunk);
        if (bp != null) await bp;
      }
      final recordId = recordIds[i];
      final entry = entries[i];
      trees.applyVirginInsertWithPlan(
        plan: indexPlan,
        pk: recordId,
        entry: entry,
        transactionId: batchTxId,
      );
      commitReservedUniques(
        table: table,
        recordId: recordId,
        transactionId: entry.transactionId ?? batchTxId,
      );

      final wp = entry.walPointer;
      if (wp == null) {
        Logger.warn(
          'Batch insert missing walPointer: table=${table.tableName} pk=$recordId',
        );
        continue;
      }
      if (bgMaybeActive) {
        bgScheduler.handleOnlineWrite(table, recordId);
      }
      _writeQueue.add(WriteQueueEntry(
        tableUid: tableUid,
        recordId: recordId,
        walPointer: wp,
      ));
    }

    _emitSizeChanged();
    CrontabManager.notifyActivity();
    // ignore: discarded_futures
    trees.pendingRecordCache.prepareOrderedViews();
  }

  Future<void> addUpdateBatch({
    required TableContext table,
    required List<String> recordIds,
    required List<BufferEntry> entries,
    List<Set<String>?>? changedFieldsList,

    /// Commit->pending: apply installs unique+non-unique in one path.
    /// Online after reserve: false -> non-unique / skip unique put.
    bool installAllIndexes = false,
  }) async {
    if (recordIds.isEmpty) return;
    if (recordIds.length != entries.length) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.engError,
          message:
              'addUpdateBatch length mismatch: recordIds=${recordIds.length}, entries=${entries.length}',
          parameterName: 'recordIds/entries',
          passedValue: {
            'recordIdsLength': recordIds.length,
            'entriesLength': entries.length,
          },
        )
      ]);
    }

    final schema = table.schema;
    final indexPlan = trees.prepareIndexWritePlan(
      table,
      schema,
      includeUniques: installAllIndexes,
    );
    final yieldController = YieldController(
      'WriteBufferManager.addUpdateBatch',
      minCheckInterval: EngineCpuChunk.hotPathMinCheckInterval,
    );
    final int emitChunk = EngineCpuChunk.sizeFor(CpuChunkKind.light);
    final String? batchTxId = installAllIndexes
        ? null
        : (entries.isEmpty ? null : entries.first.transactionId);

    for (int i = 0; i < recordIds.length; i++) {
      final y = yieldController.maybeYield();
      if (y != null) await y;
      if (i % emitChunk == 0) {
        final bp = _dataStore.parallelJournalManager
            .applyEnqueueBackpressure(emitChunk);
        if (bp != null) await bp;
      }

      final recordId = recordIds[i];
      final entry = entries[i];
      final prior = batchTxId != null
          ? trees.getTxnRecord(batchTxId, table.tableUid, recordId)
          : trees.getPendingRecord(table.tableUid, recordId);
      final skipQueue = prior != null &&
          prior.operation == BufferOperationType.insert &&
          entry.operation == BufferOperationType.update;
      final changed = changedFieldsList != null && i < changedFieldsList.length
          ? changedFieldsList[i]
          : null;

      final effective = trees.applyRecord(
        table: table,
        schema: schema,
        pk: recordId,
        entry: entry,
        changedFields: changed,
        transactionId: batchTxId,
        installAllIndexes: installAllIndexes,
        indexPlan: indexPlan,
      );
      commitReservedUniques(
        table: table,
        recordId: recordId,
        transactionId: entry.transactionId ?? batchTxId,
      );

      if (!skipQueue && effective != null && effective.walPointer != null) {
        _writeQueue.add(WriteQueueEntry(
          tableUid: table.tableUid,
          recordId: recordId,
          walPointer: effective.walPointer!,
        ));
      }
    }

    _emitSizeChanged();
    CrontabManager.notifyActivity();
  }

  Future<void> addDeleteBatch({
    required TableContext table,
    required List<String> recordIds,
    required List<BufferEntry> entries,
  }) async {
    if (recordIds.isEmpty) return;
    if (recordIds.length != entries.length) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.engError,
          message:
              'addDeleteBatch length mismatch: recordIds=${recordIds.length}, entries=${entries.length}',
          parameterName: 'recordIds/entries',
          passedValue: {
            'recordIdsLength': recordIds.length,
            'entriesLength': entries.length,
          },
        )
      ]);
    }

    await _dataStore.tableDataManager.updateTableRecordCountDelta(
      table,
      deleteDelta: recordIds.length,
    );

    trees.ensureComparators(table, table.schema);
    final yieldController = YieldController(
      'WriteBufferManager.addDeleteBatch',
      minCheckInterval: EngineCpuChunk.hotPathMinCheckInterval,
    );
    final int emitChunk = EngineCpuChunk.sizeFor(CpuChunkKind.light);

    for (int i = 0; i < recordIds.length; i++) {
      final y = yieldController.maybeYield();
      if (y != null) await y;
      if (i % emitChunk == 0) {
        final bp = _dataStore.parallelJournalManager
            .applyEnqueueBackpressure(emitChunk);
        if (bp != null) await bp;
      }

      final recordId = recordIds[i];
      final entry = entries[i];
      trees.applyRecord(
        table: table,
        schema: table.schema,
        pk: recordId,
        entry: entry,
      );

      final wp = entry.walPointer;
      if (wp != null) {
        _writeQueue.add(WriteQueueEntry(
          tableUid: table.tableUid,
          recordId: recordId,
          walPointer: wp,
        ));
      }
    }

    _emitSizeChanged();
    CrontabManager.notifyActivity();
  }

  /// Apply a transactional deferred write into txn TreeCaches.
  void applyTxnRecord({
    required String transactionId,
    required TableContext table,
    required String recordId,
    required BufferEntry entry,
    Set<String>? changedFields,
  }) {
    trees.ensureComparators(table, table.schema);
    trees.applyRecord(
      table: table,
      schema: table.schema,
      pk: recordId,
      entry: entry,
      transactionId: transactionId,
      changedFields: changedFields,
    );
    commitReservedUniques(
      table: table,
      recordId: recordId,
      transactionId: transactionId,
    );
  }

  List<WriteQueueEntry> popBatch(int size) {
    if (_writeQueue.isEmpty) return const <WriteQueueEntry>[];
    final result = <WriteQueueEntry>[];
    for (int i = 0; i < size && _writeQueue.isNotEmpty; i++) {
      result.add(_writeQueue.removeFirst());
    }
    _emitSizeChanged();
    return result;
  }

  void requeueFront(List<WriteQueueEntry> entries) {
    if (entries.isEmpty) return;
    for (int i = entries.length - 1; i >= 0; i--) {
      _writeQueue.addFirst(entries[i]);
    }
    _emitSizeChanged();
  }

  /// After a successful flush: wal-matched eviction (direct if no read view /
  /// backlog; otherwise deferred on [_evictQueue]), then idle-clear when safe.
  Future<void> cleanupAfterBatch(
    List<WriteQueueEntry> batch, {
    Map<String, WalPointer?>? flushedWalByPk,
    Map<String, List<List<dynamic>>>? indexPathsByPk,
  }) async {
    if (batch.isEmpty) return;

    final byTable = <TableUid, Set<String>>{};
    for (final e in batch) {
      byTable.putIfAbsent(e.tableUid, () => <String>{}).add(e.recordId);
    }
    final flushAt = DateTime.now();
    final walByPk = flushedWalByPk ?? const <String, WalPointer?>{};
    final pathsByPk = indexPathsByPk ?? const <String, List<List<dynamic>>>{};

    // Last queue wal per pk (fallback when flush snapshot map omits a key).
    final queueWalByPk = <String, WalPointer>{};
    for (final q in batch) {
      queueWalByPk[q.recordId] = q.walPointer;
    }

    for (final entry in byTable.entries) {
      final tableUid = entry.key;
      final tableWal = <String, WalPointer?>{};
      final tablePaths = <String, List<List<dynamic>>>{};
      for (final pk in entry.value) {
        tableWal[pk] = walByPk.containsKey(pk) ? walByPk[pk] : queueWalByPk[pk];
        tablePaths[pk] = pathsByPk[pk] ?? const <List<dynamic>>[];
      }
      // onIdle on every schedule: only the flight that actually runs drain/direct
      // invokes it; sibling no-ops are fine (idle clear is idempotent).
      trees.scheduleFlushedEvict(
        tableUid: tableUid,
        flushedWalByPk: tableWal,
        indexPathsByPk: tablePaths,
        flushAt: flushAt,
        onIdle: tryClearPendingTreesWhenIdle,
      );
    }
    _emitSizeChanged();
  }

  /// Build per-PK pending-index leaf paths for a flush snapshot (one schema pass).
  Future<Map<String, List<List<dynamic>>>> collectFlushIndexPathsByPk({
    required TableContext table,
    required TableSchema schema,
    required Map<String, BufferEntry> flushedByPk,
  }) async {
    if (flushedByPk.isEmpty) {
      return const <String, List<List<dynamic>>>{};
    }
    final out = <String, List<List<dynamic>>>{};
    await EngineCpuChunk.forEachIterable(
      flushedByPk.entries,
      (e) {
        final paths = trees.collectPendingIndexPathsForFlush(
          table: table,
          schema: schema,
          pk: e.key,
          entry: e.value,
        );
        if (paths.isNotEmpty) {
          out[e.key] = paths;
        }
      },
      kind: CpuChunkKind.medium,
    );
    return out;
  }

  BufferEntry? getBufferedRecord(TableContext table, String recordId) {
    return trees.getPendingRecord(table.tableUid, recordId);
  }

  BufferEntry? getBufferedRecordForRead(TableContext table, String recordId) {
    final migrationManager = _dataStore.migrationManager;
    final entry = getBufferedRecord(table, recordId);
    if (entry == null) return null;
    if (migrationManager == null ||
        !migrationManager.hasRuntimeMigrationForTable(table)) {
      return entry;
    }
    final normalizedData = migrationManager.normalizeRecordToLatestSync(
      table,
      entry.data,
      fromVersion: entry.schemaVersion,
    );
    final normalizedOldValues = entry.oldValues != null
        ? migrationManager.normalizeRecordToLatestSync(
            table,
            entry.oldValues!,
            fromVersion: entry.schemaVersion,
          )
        : null;
    if (identical(normalizedData, entry.data) &&
        identical(normalizedOldValues, entry.oldValues)) {
      return entry;
    }
    return entry.copyWith(data: normalizedData, oldValues: normalizedOldValues);
  }

  Future<dynamic> getMaxPrimaryKey(TableContext table, String pkField) async {
    return trees.getMaxPrimaryKey(table, pkField);
  }

  void clearAll() {
    _globalClearEpoch++;
    trees.clearAll();
    _writeQueue.clear();
    _lastReserveRollback.clear();
    _tableClearEpochs.clear();
    _globalClearEpoch = 0;
    _emitSizeChanged();
  }

  Future<void> clearTableByUid(TableUid tableUid) async {
    await trees.clearTable(tableUid);
    _tableClearEpochs[tableUid] = (_tableClearEpochs[tableUid] ?? 0) + 1;
    if (_writeQueue.isNotEmpty) {
      _writeQueue.removeWhere((e) => e.tableUid == tableUid);
    }
    _emitSizeChanged();
  }

  // -------------------- Unique reservation --------------------

  /// Memory unique pre-reserve via TreeCache.putIfAbsent.
  ///
  /// Throws [DbException] with [UniqueViolation] on conflict.
  /// Returns rollback paths for [releaseReservedUniques].
  List<List<dynamic>> tryReserveUniques({
    required TableContext table,
    required TableSchema schema,
    required String recordId,
    required Map<String, dynamic> data,
    bool isUpdate = false,
    Set<String>? changedFields,
    String? transactionId,
  }) {
    final rollback = <List<dynamic>>[];
    final violation = trees.tryReserveUniqueInMemory(
      table: table,
      schema: schema,
      pk: recordId,
      data: data,
      isUpdate: isUpdate,
      changedFields: changedFields,
      transactionId: transactionId,
      rollbackKeys: rollback,
    );
    if (violation != null) {
      // Call sites historically catch UniqueViolation directly.
      // ignore: only_throw_errors
      throw violation;
    }
    final key = _reserveKey(table.tableUid, recordId, transactionId);
    _lastReserveRollback[key] = rollback;
    return rollback;
  }

  /// Bookkeeping entries awaiting commit/release (diagnostics / tests).
  int get debugReserveBookkeepingCount => _lastReserveRollback.length;

  /// Drop rollback bookkeeping after buffer apply succeeded.
  /// Does not remove index leaves -- they remain until flush evict / delete.
  void commitReservedUniques({
    required TableContext table,
    required String recordId,
    String? transactionId,
  }) {
    _lastReserveRollback.remove(
      _reserveKey(table.tableUid, recordId, transactionId),
    );
  }

  void releaseReservedUniques({
    required TableContext table,
    required String recordId,
    String? transactionId,
    List<List<dynamic>>? rollbackKeys,
  }) {
    final key = _reserveKey(table.tableUid, recordId, transactionId);
    final paths = rollbackKeys ?? _lastReserveRollback.remove(key);
    if (rollbackKeys != null) {
      _lastReserveRollback.remove(key);
    }
    if (paths == null || paths.isEmpty) return;
    trees.rollbackReserved(paths, transactionId: transactionId);
  }

  /// Release reservations for many pks (failed / aborted rows only).
  ///
  /// Safe for rows that already [commitReservedUniques]: bookkeeping is gone
  /// and this becomes a no-op (does not wipe leaves of buffered rows).
  ///
  /// Yields on large sets to avoid UI jank (batch abort / fail-all paths).
  Future<void> releaseReservedUniquesForPks({
    required TableContext table,
    required Iterable<String> recordIds,
    String? transactionId,
  }) async {
    final yieldController = YieldController(
      'WriteBufferManager.releaseReservedUniquesForPks',
      minCheckInterval: EngineCpuChunk.hotPathMinCheckInterval,
    );
    final int chunk = EngineCpuChunk.sizeFor(CpuChunkKind.light);
    int i = 0;
    for (final recordId in recordIds) {
      if (recordId.isEmpty) continue;
      if (i % chunk == 0) {
        final y = yieldController.maybeYield();
        if (y != null) await y;
      }
      i++;
      try {
        releaseReservedUniques(
          table: table,
          recordId: recordId,
          transactionId: transactionId,
        );
      } catch (_) {}
    }
  }

  String? hasUniqueKeyOwnedByOther(
    TableContext table,
    IndexUid indexUid,
    dynamic compositeKey,
    String? selfRecordId, {
    String? transactionId,
  }) {
    final keyParts = compositeKey is List
        ? List<dynamic>.from(compositeKey)
        : <dynamic>[compositeKey];
    return trees.hasUniqueOwnedByOther(
      tableUid: table.tableUid,
      indexUid: indexUid,
      keyParts: keyParts,
      selfPk: selfRecordId,
      transactionId: transactionId,
    );
  }

  /// Drop all txn-scoped pending record/index overlays for [transactionId].
  void clearTransactionBuffers(String transactionId) {
    trees.clearTransaction(transactionId);
  }

  /// Wipe every txn TreeCache (dispose / full teardown). Prefer over looping
  /// [clearTransactionBuffers] per txId.
  void clearAllTransactionBuffers() {
    trees.clearAllTransactions();
  }

  /// Batch unique pre-reserve helper for multi-row insert/update paths.
  BufferBatchReserveContext createBatchReserveContext(
    TableContext table,
    String? transactionId,
  ) {
    return BufferBatchReserveContext(this, table, transactionId);
  }
}

/// Batch unique reservation helper for insert/update hot paths.
class BufferBatchReserveContext {
  final WriteBufferManager _buf;
  final TableContext table;
  final String? transactionId;
  final List<List<List<dynamic>>> _rollbacks = [];

  BufferBatchReserveContext(this._buf, this.table, this.transactionId);

  /// Reserve uniques for one record; returns rollback paths (empty if update self).
  List<List<dynamic>> tryReserve(
    String recordId,
    Map<String, dynamic> data, {
    required bool isUpdate,
    Set<String>? changedFields,
    TableSchema? schema,
  }) {
    final paths = _buf.tryReserveUniques(
      table: table,
      schema: schema ?? table.schema,
      recordId: recordId,
      data: data,
      isUpdate: isUpdate,
      changedFields: changedFields,
      transactionId: transactionId,
    );
    _rollbacks.add(paths);
    return paths;
  }

  void releaseAll() {
    for (final paths in _rollbacks) {
      _buf.bufferTrees.rollbackReserved(paths, transactionId: transactionId);
    }
    _rollbacks.clear();
  }
}
