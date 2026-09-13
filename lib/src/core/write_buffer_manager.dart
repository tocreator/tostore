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
    final prior = trees.getPendingRecord(table.tableUid, recordId);
    bool skipQueueEnqueue = false;
    var effectiveUpdateStats = updateStats;

    if (prior != null) {
      // insert→update coalesces in trees; must NOT skip the write queue —
      // a concurrent flush may already have popped the insert, leaving the
      // merged pending row stranded with no schedule trigger.
      if (prior.operation == BufferOperationType.insert &&
          entry.operation == BufferOperationType.update) {
        effectiveUpdateStats = false;
      }

      // Recovery-only: pending-batch + WAL may replay the same op. Online
      // path never sees identical walPointer / duplicate insert for one PK.
      if (_dataStore.parallelJournalManager.isInRecoveryMode) {
        final sameWal = prior.walPointer != null &&
            entry.walPointer != null &&
            prior.walPointer == entry.walPointer;
        final dupInsert = prior.operation == BufferOperationType.insert &&
            entry.operation == BufferOperationType.insert;
        if (sameWal || dupInsert) {
          skipQueueEnqueue = true;
          effectiveUpdateStats = false;
        }
      }
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

    if (!skipQueueEnqueue && effective != null) {
      _dataStore.backgroundWriteScheduler.handleOnlineWrite(table, recordId);
      final bp = _dataStore.parallelJournalManager.applyEnqueueBackpressure();
      if (bp != null) await bp;
      if (effectiveUpdateStats) {
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

  /// Synchronous variant of [addRecord] for hot single-record insert/update/delete.
  /// Completely eliminates microtask yields and avoids async state machines.
  void addRecordSync({
    required TableContext table,
    required String recordId,
    required BufferEntry entry,
    Set<String>? changedFields,
    bool updateStats = true,
  }) {
    final prior = trees.getPendingRecord(table.tableUid, recordId);
    bool skipQueueEnqueue = false;
    var effectiveUpdateStats = updateStats;

    if (prior != null) {
      // insert→update coalesces in trees; must NOT skip the write queue —
      // a concurrent flush may already have popped the insert, leaving the
      // merged pending row stranded with no schedule trigger.
      if (prior.operation == BufferOperationType.insert &&
          entry.operation == BufferOperationType.update) {
        effectiveUpdateStats = false;
      }

      // Recovery-only: pending-batch + WAL may replay the same op. Online
      // path never sees identical walPointer / duplicate insert for one PK.
      if (_dataStore.parallelJournalManager.isInRecoveryMode) {
        final sameWal = prior.walPointer != null &&
            entry.walPointer != null &&
            prior.walPointer == entry.walPointer;
        final dupInsert = prior.operation == BufferOperationType.insert &&
            entry.operation == BufferOperationType.insert;
        if (sameWal || dupInsert) {
          skipQueueEnqueue = true;
          effectiveUpdateStats = false;
        }
      }
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

    if (!skipQueueEnqueue && effective != null) {
      _dataStore.backgroundWriteScheduler.handleOnlineWrite(table, recordId);
      if (effectiveUpdateStats) {
        final op = restoreDeletedCount
            ? BufferOperationType.insert
            : effective.operation;
        _dataStore.tableDataManager.updateTableRecordCountFast(table, op);
      }
      final wp = effective.walPointer;
      if (wp != null) {
        _writeQueue.add(WriteQueueEntry(
          tableUid: table.tableUid,
          recordId: recordId,
          walPointer: wp,
        ));
        _emitSizeChanged();
      }
    } else if (effective == null && !skipQueueEnqueue) {
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
      minCheckInterval: EngineCpuChunk.fastPathMinCheckInterval,
    );
    final tableUid = table.tableUid;
    final bgScheduler = _dataStore.backgroundWriteScheduler;
    final bool bgMaybeActive = !bgScheduler.isEmpty;
    // Commit apply always lands in pending (tx overlays cleared after).
    final String? batchTxId = installAllIndexes
        ? null
        : (entries.isEmpty ? null : entries.first.transactionId);

    final bp = _dataStore.parallelJournalManager
        .applyEnqueueBackpressure(recordIds.length);
    if (bp != null) await bp;

    for (int i = 0; i < recordIds.length; i++) {
      final y = yieldController.maybeYield();
      if (y != null) await y;
      final recordId = recordIds[i];
      final entry = entries[i];
      trees.applyVirginInsertWithPlan(
        plan: indexPlan,
        pk: recordId,
        entry: entry,
        transactionId: batchTxId,
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
  }

  /// High-throughput batch insertion for tables with ONLY a primary key,
  /// skipping index plan lookups and reservation checks. The write-queue
  /// build loop yields so a large window cannot monopolize the UI isolate.
  Future<void> addPurePkInsertBatch({
    required TableContext table,
    required List<String> recordIds,
    required List<BufferEntry> entries,
  }) async {
    final int count = recordIds.length;
    if (count == 0) return;

    await _dataStore.tableDataManager.updateTableRecordCountDelta(
      table,
      insertDelta: count,
    );

    final bp =
        _dataStore.parallelJournalManager.applyEnqueueBackpressure(count);
    if (bp != null) await bp;

    final tableUid = table.tableUid;
    final recordCache = trees.pendingRecordCache;
    final bgScheduler = _dataStore.backgroundWriteScheduler;
    final bool bgMaybeActive = !bgScheduler.isEmpty;

    recordCache.putFlatBatchNone(tableUid, recordIds, entries);

    final yieldController = YieldController(
      'WriteBufferManager.addPurePkInsertBatch',
      minCheckInterval: EngineCpuChunk.fastPathMinCheckInterval,
    );

    // Build queue entries directly into _writeQueue to avoid intermediate list allocation.
    for (int i = 0; i < count; i++) {
      final y = yieldController.maybeYield();
      if (y != null) await y;
      final wp = entries[i].walPointer;
      if (wp == null) continue;
      if (bgMaybeActive) {
        bgScheduler.handleOnlineWrite(table, recordIds[i]);
      }
      _writeQueue.add(WriteQueueEntry(
        tableUid: tableUid,
        recordId: recordIds[i],
        walPointer: wp,
      ));
    }

    _emitSizeChanged();
    CrontabManager.notifyActivity();
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
    final String? batchTxId = installAllIndexes
        ? null
        : (entries.isEmpty ? null : entries.first.transactionId);

    final bp = _dataStore.parallelJournalManager
        .applyEnqueueBackpressure(recordIds.length);
    if (bp != null) await bp;

    final pendingQueue = <WriteQueueEntry>[];
    for (int i = 0; i < recordIds.length; i++) {
      final y = yieldController.maybeYield();
      if (y != null) await y;

      final recordId = recordIds[i];
      final entry = entries[i];
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

      // Always enqueue (O(1)). insert→update coalesces in trees; skipping the
      // queue previously stranded rows when flush already popped the insert.
      if (effective != null && effective.walPointer != null) {
        pendingQueue.add(WriteQueueEntry(
          tableUid: table.tableUid,
          recordId: recordId,
          walPointer: effective.walPointer!,
        ));
      }
    }
    if (pendingQueue.isNotEmpty) {
      _writeQueue.addAll(pendingQueue);
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

    final yieldController = YieldController(
      'WriteBufferManager.addDeleteBatch',
      minCheckInterval: EngineCpuChunk.fastPathMinCheckInterval,
    );
    final tableUid = table.tableUid;
    final schema = table.schema;

    final bp = _dataStore.parallelJournalManager
        .applyEnqueueBackpressure(recordIds.length);
    if (bp != null) await bp;

    for (int i = 0; i < recordIds.length; i++) {
      final y = yieldController.maybeYield();
      if (y != null) await y;

      final recordId = recordIds[i];
      final entry = entries[i];
      trees.applyRecord(
        table: table,
        schema: schema,
        pk: recordId,
        entry: entry,
      );

      final wp = entry.walPointer;
      if (wp != null) {
        _writeQueue.add(WriteQueueEntry(
          tableUid: tableUid,
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
    trees.applyRecord(
      table: table,
      schema: table.schema,
      pk: recordId,
      entry: entry,
      transactionId: transactionId,
      changedFields: changedFields,
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
    await EngineCpuChunk.forEachIndexed(
      batch,
      (_, e) {
        byTable.putIfAbsent(e.tableUid, () => <String>{}).add(e.recordId);
      },
      kind: CpuChunkKind.light,
    );
    final flushAt = DateTime.now();
    final walByPk = flushedWalByPk ?? const <String, WalPointer?>{};
    final pathsByPk = indexPathsByPk ?? const <String, List<List<dynamic>>>{};

    // Last queue wal per pk (fallback when flush snapshot map omits a key).
    final queueWalByPk = <String, WalPointer>{};
    await EngineCpuChunk.forEachIndexed(
      batch,
      (_, q) {
        queueWalByPk[q.recordId] = q.walPointer;
      },
      kind: CpuChunkKind.light,
    );

    for (final entry in byTable.entries) {
      final tableUid = entry.key;
      final tableWal = <String, WalPointer?>{};
      final tablePaths = <String, List<List<dynamic>>>{};
      await EngineCpuChunk.forEachIterable(
        entry.value,
        (pk) {
          tableWal[pk] =
              walByPk.containsKey(pk) ? walByPk[pk] : queueWalByPk[pk];
          tablePaths[pk] = pathsByPk[pk] ?? const <List<dynamic>>[];
        },
        kind: CpuChunkKind.light,
      );
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
  /// Throws [UniqueViolation] on conflict.
  /// When [trackRollback] is true, returns paths newly inserted by this call
  /// (caller must pass them to [releaseReservedUniques] on abort). When false,
  /// returns an empty list and mid-call conflicts undo via by-data release.
  List<List<dynamic>> tryReserveUniques({
    required TableContext table,
    required TableSchema schema,
    required String recordId,
    required Map<String, dynamic> data,
    bool isUpdate = false,
    Set<String>? changedFields,
    String? transactionId,
    bool skipPrimaryKey = false,
    List<IndexSchema>? uniqueIndexes,
    bool trackRollback = true,
  }) {
    final List<List<dynamic>>? rollback =
        trackRollback ? <List<dynamic>>[] : null;
    final violation = trees.tryReserveUniqueInMemory(
      table: table,
      schema: schema,
      pk: recordId,
      data: data,
      isUpdate: isUpdate,
      changedFields: changedFields,
      transactionId: transactionId,
      rollbackKeys: rollback,
      skipPrimaryKey: skipPrimaryKey,
      uniqueIndexes: uniqueIndexes,
    );
    if (violation != null) {
      // Call sites historically catch UniqueViolation directly.
      // ignore: only_throw_errors
      throw violation;
    }
    if (rollback == null || rollback.isEmpty) {
      return const <List<dynamic>>[];
    }
    return rollback;
  }

  /// Release unique pre-reserve slots by reconstructing keys from [data].
  void releaseReservedUniquesByData({
    required TableContext table,
    required TableSchema schema,
    required String recordId,
    required Map<String, dynamic> data,
    String? transactionId,
    bool isUpdate = false,
    Set<String>? changedFields,
    bool skipPrimaryKey = false,
    List<IndexSchema>? uniqueIndexes,
  }) {
    trees.releaseReservedUniquesByData(
      table: table,
      schema: schema,
      pk: recordId,
      data: data,
      transactionId: transactionId,
      isUpdate: isUpdate,
      changedFields: changedFields,
      skipPrimaryKey: skipPrimaryKey,
      uniqueIndexes: uniqueIndexes,
    );
  }

  /// Drop reserved unique leaves using explicit [rollbackKeys] from
  /// [tryReserveUniques]. No global bookkeeping map.
  void releaseReservedUniques({
    required TableContext table,
    required String recordId,
    String? transactionId,
    List<List<dynamic>>? rollbackKeys,
  }) {
    if (rollbackKeys == null || rollbackKeys.isEmpty) return;
    trees.rollbackReserved(rollbackKeys, transactionId: transactionId);
  }

  /// Release many reserved rows by their path lists (update abort / chunk abort).
  Future<void> releaseReservedUniquesByPaths({
    required TableContext table,
    required Map<String, List<List<dynamic>>> pathsByPk,
    String? transactionId,
  }) async {
    if (pathsByPk.isEmpty) return;
    final yieldController = YieldController(
      'WriteBufferManager.releaseReservedUniquesByPaths',
      minCheckInterval: EngineCpuChunk.hotPathMinCheckInterval,
    );
    for (final entry in pathsByPk.entries) {
      final y = yieldController.maybeYield();
      if (y != null) await y;
      final paths = entry.value;
      if (paths.isEmpty) continue;
      try {
        trees.rollbackReserved(paths, transactionId: transactionId);
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
  ///
  /// [trackPaths]: when false (batchInsert), collect nothing — callers pass
  /// row data into [BufferBatchReserveContext.releaseForPk] /
  /// [BufferBatchReserveContext.releaseAll] on abort. When true (batchUpdate),
  /// keep per-pk path lists so partial unique re-reserves do not wipe
  /// pre-existing slots.
  BufferBatchReserveContext createBatchReserveContext(
    TableContext table,
    String? transactionId, {
    List<IndexSchema>? uniqueIndexes,
    bool skipPrimaryKey = false,
    bool trackPaths = true,
  }) {
    return BufferBatchReserveContext(
      this,
      table,
      transactionId,
      uniqueIndexes: uniqueIndexes,
      skipPrimaryKey: skipPrimaryKey,
      trackPaths: trackPaths,
    );
  }
}

/// Batch unique reservation helper for insert/update hot paths.
class BufferBatchReserveContext {
  final WriteBufferManager _buf;
  final TableContext table;
  final String? transactionId;

  /// Only used when [trackPaths] is true (batchUpdate partial unique re-reserve).
  final Map<String, List<List<dynamic>>> _rollbacksByPk = {};
  final List<IndexSchema>? uniqueIndexes;
  final bool skipPrimaryKey;
  final bool trackPaths;

  BufferBatchReserveContext(
    this._buf,
    this.table,
    this.transactionId, {
    this.uniqueIndexes,
    this.skipPrimaryKey = false,
    this.trackPaths = true,
  });

  /// Reserve uniques for one record.
  ///
  /// When [trackPaths] is false (batchInsert), nothing is collected — abort
  /// paths must call [releaseForPk]/[releaseAll] with the row [data].
  void tryReserve(
    String recordId,
    Map<String, dynamic> data, {
    required bool isUpdate,
    Set<String>? changedFields,
    TableSchema? schema,
    bool? skipPrimaryKey,
  }) {
    final effectiveSkip = skipPrimaryKey ?? this.skipPrimaryKey;
    final paths = _buf.tryReserveUniques(
      table: table,
      schema: schema ?? table.schema,
      recordId: recordId,
      data: data,
      isUpdate: isUpdate,
      changedFields: changedFields,
      transactionId: transactionId,
      skipPrimaryKey: effectiveSkip,
      uniqueIndexes: uniqueIndexes,
      trackRollback: trackPaths,
    );
    if (trackPaths && paths.isNotEmpty) {
      final existing = _rollbacksByPk[recordId];
      if (existing == null) {
        _rollbacksByPk[recordId] = paths;
      } else {
        existing.addAll(paths);
      }
    }
  }

  /// Drop path bookkeeping after buffer apply succeeded (leaves stay).
  void commitForPk(String recordId) {
    if (!trackPaths) return;
    _rollbacksByPk.remove(recordId);
  }

  void commitForPks(Iterable<String> recordIds) {
    if (!trackPaths || _rollbacksByPk.isEmpty) return;
    for (final id in recordIds) {
      _rollbacksByPk.remove(id);
    }
  }

  /// Release a reserved row. [data] is required when [trackPaths] is false.
  void releaseForPk(String recordId, [Map<String, dynamic>? data]) {
    if (!trackPaths) {
      if (data == null) return;
      _buf.releaseReservedUniquesByData(
        table: table,
        schema: table.schema,
        recordId: recordId,
        data: data,
        transactionId: transactionId,
        skipPrimaryKey: skipPrimaryKey,
        uniqueIndexes: uniqueIndexes,
      );
      return;
    }
    final paths = _rollbacksByPk.remove(recordId);
    if (paths != null && paths.isNotEmpty) {
      _buf.bufferTrees.rollbackReserved(paths, transactionId: transactionId);
    }
  }

  void releaseLast() {
    if (!trackPaths) return;
    if (_rollbacksByPk.isNotEmpty) {
      releaseForPk(_rollbacksByPk.keys.last);
    }
  }

  /// Release every tracked reservation, or (no-ledger mode) every row in
  /// [records] using [primaryKeyField] to resolve pk.
  void releaseAll({
    List<Map<String, dynamic>>? records,
    String? primaryKeyField,
  }) {
    if (!trackPaths) {
      if (records == null || primaryKeyField == null) return;
      for (final rec in records) {
        final pkVal = rec[primaryKeyField];
        final rid = pkVal is String ? pkVal : (pkVal?.toString() ?? '');
        if (rid.isEmpty) continue;
        releaseForPk(rid, rec);
      }
      return;
    }
    if (_rollbacksByPk.isEmpty) return;
    for (final entry in _rollbacksByPk.entries) {
      _buf.bufferTrees
          .rollbackReserved(entry.value, transactionId: transactionId);
    }
    _rollbacksByPk.clear();
  }

  /// Success path: drop path bookkeeping only (leaves stay until flush/evict).
  /// No-op when [trackPaths] is false (nothing was collected).
  void clear() {
    if (!trackPaths) return;
    _rollbacksByPk.clear();
  }
}
