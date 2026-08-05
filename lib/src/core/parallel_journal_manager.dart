import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../interface/storage_interface.dart';
import '../handler/encryption.dart';
import '../handler/logger.dart';
import '../handler/parallel_processor.dart';
import '../handler/value_matcher.dart';
import '../model/background_write_entry.dart';
import '../model/migration_write_mode.dart';
import '../model/background_write_type.dart';
import '../model/buffer_entry.dart';
import '../model/id_generator.dart';
import '../model/index_entry.dart';
import '../model/meta_info.dart';
import '../model/parallel_journal_entry.dart';
import '../model/table_schema.dart';
import '../model/table_context.dart';
import '../model/wal_pointer.dart';
import 'compute/wal_decode_batch_runner.dart';
import 'data_store_impl.dart';
import 'io_concurrency_planner.dart';
import 'migration_manager.dart';
import 'page_redo_log_codec.dart';
import 'storage_adapter.dart';
import 'wal_manager.dart';
import 'workload_scheduler.dart';
import 'write_buffer_manager.dart';
import 'yield_controller.dart';
import '../model/table_identity.dart';
import '../model/system_table.dart';
import '../model/space_stats.dart';

class ParallelJournalManager {
  final DataStoreImpl _dataStore;
  final WalManager _walManager;
  final WriteBufferManager _bufferManager;

  bool _running = false;
  Future<void>? _loopFuture;
  StreamSubscription<int>? _bufSizeSub;
  bool _flushInProgress = false;
  BatchContext? _activeBatchContext;
  bool _isRecovering = false; // Flag to indicate if currently in recovery mode

  // When set (close / switchSpace / flushCompletely), skip online tail-fill
  // delays and wake any in-flight wait so drain can proceed immediately.
  bool _immediateFlushRequested = false;
  Completer<void>? _tailWaitWake;

  // ── Write backpressure (measurement-based) ──
  // Measured per-record flush cost from the last completed batch (microseconds).
  int _perRecordFlushUs = 0;
  // Active throttle delay per record (us); 0 when not congested.
  // Set by _onBufferSizeChanged (1 compare + 1 assign), read by waitIfThrottled.
  int _throttleDelayPerRecordUs = 0;

  /// Minimum total delay (us) below which we skip the await entirely
  /// to avoid micro-delay overhead. 1000us = 1ms.
  static const int _kMinThrottleDelayUs = 1000;

  /// Interrupt online tail-fill wait so close/switchSpace/flush can drain now.
  void _requestImmediateFlush() {
    _immediateFlushRequested = true;
    final wake = _tailWaitWake;
    if (wake != null && !wake.isCompleted) {
      wake.complete();
    }
  }

  void _clearImmediateFlushRequest() {
    _immediateFlushRequested = false;
  }

  ParallelJournalManager(
      this._dataStore, this._walManager, this._bufferManager);

  /// Current active batch context during flush/recovery; null if idle
  BatchContext? get activeBatchContext => _activeBatchContext;

  /// Current active batch id during flush/recovery; null if idle
  String? get activeBatchId => _activeBatchContext?.batchId;

  /// Check if currently in recovery mode (recovering from a pending batch)
  /// Returns true only when actively recovering a pending batch, not just when pending batches exist
  bool get isInRecoveryMode => _isRecovering;

  /// Wait until background recovery (if any) is completed.
  Future<void> waitUntilRecoveryCompleted() async {
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    while (_isRecovering) {
      if (DateTime.now().isAfter(deadline)) {
        Logger.warn(
          'waitUntilRecoveryCompleted timed out after 2 minutes; '
          'clearing recovering flag to unblock drain/migration',
        );
        _isRecovering = false;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// First real (non-pseudo) WAL pointer in [batch], if any.
  static WalPointer? _firstRealWalPointer(List<WriteQueueEntry> batch) {
    for (final e in batch) {
      if (e.walPointer.partitionIndex >= 0) return e.walPointer;
    }
    return null;
  }

  /// Last real (non-pseudo) WAL pointer in [batch], if any.
  static WalPointer? _lastRealWalPointer(List<WriteQueueEntry> batch) {
    for (var i = batch.length - 1; i >= 0; i--) {
      if (batch[i].walPointer.partitionIndex >= 0) {
        return batch[i].walPointer;
      }
    }
    return null;
  }

  /// Write backpressure: called by WriteBufferManager before enqueue.
  ///
  /// Hot path cost: 1 multiply + 1 compare. Skips await when delay < 1ms.
  /// [count] = 1 for single addRecord, or N for periodic batch checks.
  Future<void> waitIfThrottled([int count = 1]) {
    if (_throttleDelayPerRecordUs < _kMinThrottleDelayUs) {
      return Future<void>.value();
    }
    final totalUs = _throttleDelayPerRecordUs * count;
    return Future<void>.delayed(Duration(microseconds: totalUs));
  }

  /// Hard backpressure: wait until write queue length is at or below [cap].
  /// Used by batch insert to avoid unbounded buffer growth when insert rate
  /// exceeds flush rate. Polls [pollInterval] until condition is met or [timeout].
  /// [timeout] prevents deadlock if flush is stuck; null = no timeout.
  Future<void> waitUntilQueueBelow(
    int cap, {
    Duration pollInterval = const Duration(milliseconds: 20),
    Duration? timeout,
  }) async {
    if (cap <= 0 || _bufferManager.queueLength <= cap) return;
    final stopAt = timeout != null ? DateTime.now().add(timeout) : null;
    while (_running && _bufferManager.queueLength > cap) {
      if (stopAt != null && DateTime.now().isAfter(stopAt)) break;
      await Future.delayed(pollInterval);
    }
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;

    // Initial per-record flush estimate from config, so throttling works
    // immediately before the first real measurement arrives.
    // e.g. mobile: 5000ms * 1000 / 100K = 50us per record.
    final bs = _dataStore.config.writeBatchSize;
    _perRecordFlushUs =
        bs > 0 ? _dataStore.config.maxFlushLatencyMs * 1000 ~/ bs : 50;

    // Reconcile incomplete pending batches: load flush WAL ranges into buffer
    // first; do not start recovery flush until _recoverFromWal finishes, so the
    // recovery pump cannot interleave with unrelated WAL-replayed queue entries.
    List<_WalRange>? excludeRanges;
    List<Future<void> Function()> recoveryFlushTasks = const [];
    try {
      if (_walManager.hasPendingParallelBatches) {
        final reconciled = await _reconcileWithParallelJournal();
        excludeRanges = reconciled.excludeRanges;
        recoveryFlushTasks = reconciled.flushTasks;
      }
      // Then recover remaining WAL entries into in-memory buffer/queue
      await _recoverFromWal(excludeRanges: excludeRanges);

      if (recoveryFlushTasks.isNotEmpty) {
        _executeRecoveryFlushChain(recoveryFlushTasks);
      } else if (_isRecovering) {
        _isRecovering = false;
      }
    } catch (e) {
      // Never leave [_isRecovering] stuck if chain was not started.
      if (_isRecovering && recoveryFlushTasks.isEmpty) {
        _isRecovering = false;
      }
      rethrow;
    }

    if (!_dataStore.config.enableJournal) {
      bool cleaned = false;
      if (_walManager.hasExistingLogs) {
        Logger.info(
            'Journal disabled but existing logs found. Draining legacy WAL...');
        await flushCompletely();
        await _walManager.destroyWal();
        cleaned = true;
      }

      if (cleaned) {
        Logger.info('Legacy WAL drained and destroyed.');
      }
    }

    // Subscribe to buffer size changes to drive event-driven flushing
    try {
      _bufSizeSub = _bufferManager.sizeStream.listen(_onBufferSizeChanged);
      _onBufferSizeChanged(_bufferManager.queueLength);
    } catch (_) {}
  }

  /// Flush all pending write buffers to disk without shutting down the journal manager.
  ///
  /// - Used in maintenance flows (backup, migration, "save all cache") where we need
  ///   a strong durability point but will continue to accept new writes afterwards.
  /// - Waits for any in-flight flush loop to complete, then runs a drain-mode pump
  ///   that ignores the batchSize early-exit heuristic and flushes until the queue is empty.
  Future<void> flushCompletely() async {
    if (!_running) return;

    // Wake any in-flight online tail wait before awaiting that pump.
    _requestImmediateFlush();

    // Drain must not silently no-op while recovery holds the flush gate.
    if (_isRecovering) {
      await waitUntilRecoveryCompleted();
      if (!_running) {
        _clearImmediateFlushRequest();
        return;
      }
    }

    // Wait for any in-flight flush first to avoid overlapping pumps.
    final existing = _loopFuture;
    if (existing != null) {
      try {
        await existing;
      } catch (_) {}
    }

    // Run a dedicated drain-mode pump.
    try {
      _flushInProgress = true;
      final fut = _pumpFlush(drainCompletely: true);
      _loopFuture = fut;
      await fut;
    } finally {
      _flushInProgress = false;
      _loopFuture = null;
      _clearImmediateFlushRequest();
    }
  }

  /// Drain all pending write buffers to disk and shut down the journal manager.
  ///
  /// Used for database close or switch space etc.:
  /// - Force flush all data in `_writeQueue` to table files/indexes until the queue is empty;
  /// - Wait for the currently running flush to complete, then execute a "complete flush" (ignore the early-exit rule);
  /// - After completion, close the timer and subscription, and set `_running` to false.
  Future<void> drainAndStop() async {
    // If not running and the queue is empty, no need to do anything
    if (!_running && _bufferManager.isEmpty) {
      return;
    }

    // Wake any in-flight online tail wait before awaiting that pump.
    _requestImmediateFlush();

    // Close the trigger, avoid being triggered again by sizeStream
    try {
      _running = true; // Ensure the while condition of _pumpFlush is met
      try {
        await _bufSizeSub?.cancel();
      } catch (_) {}
      _bufSizeSub = null;

      // Wait for the possibly running previous flush to complete
      final fut = _loopFuture;
      if (fut != null) {
        try {
          await fut;
        } catch (_) {}
      }

      // Finally execute a "complete flush" until the queue is truly empty
      _flushInProgress = true;
      await _pumpFlush(drainCompletely: true);
    } finally {
      _running = false;
      _loopFuture = null;
      _flushInProgress = false;
      _perRecordFlushUs = 0;
      _throttleDelayPerRecordUs = 0;
      _activeBatchContext = null;
      _isRecovering = false;
      _clearImmediateFlushRequest();
    }
  }

  /// Stop journal manager without flushing pending buffers to table files.
  ///
  /// Used for scenarios like backup/restore where "discard unpersisted data":
  /// - Close trigger and flush loop;
  /// - Wait for the possibly running flush task to complete naturally;
  /// - Clear memory buffers to avoid subsequent errors accessing closed TableDataManager/storage.
  Future<void> stopWithoutFlush() async {
    // Fast path: already stopped and queue empty
    if (!_running && _bufferManager.isEmpty) {
      try {
        await _bufSizeSub?.cancel();
      } catch (_) {}
      _bufSizeSub = null;
      _loopFuture = null;
      _flushInProgress = false;
      _activeBatchContext = null;
      _bufferManager.clearAll();
      return;
    }

    // Wake tail wait so stop is not blocked by maxFlushLatencyMs windows.
    _requestImmediateFlush();

    try {
      // Prevent new flush scheduling
      _running = false;
      // Cancel subscription so sizeStream no longer triggers new flush
      try {
        await _bufSizeSub?.cancel();
      } catch (_) {}
      _bufSizeSub = null;

      // Wait for possible in-flight flush loop to finish gracefully
      final fut = _loopFuture;
      if (fut != null) {
        try {
          await fut;
        } catch (_) {}
      }
    } finally {
      _loopFuture = null;
      _flushInProgress = false;
      _activeBatchContext = null;
      _clearImmediateFlushRequest();
      // Drop all pending buffered writes; caller has decided not to persist these data
      _bufferManager.clearAll();
    }
  }

  void scheduleFlushIfNeeded() {
    if (!_running) return;
    if (_flushInProgress) return;
    // Recovery owns the pump; scheduling a normal flush only sets
    // _flushInProgress and immediately no-ops inside _pumpFlush.
    if (_isRecovering) return;

    final hasNormalData = !_bufferManager.isEmpty;
    final hasBackgroundWriteData = !_dataStore.backgroundWriteScheduler.isEmpty;

    if (!hasNormalData && !hasBackgroundWriteData) return;

    _flushInProgress = true;
    final fut = _pumpFlush();
    _loopFuture = fut;
    fut.whenComplete(() {
      _flushInProgress = false;
    });
  }

  /// Tail-wait strategy for normal online flush:
  ///
  /// If the queue is below [targetSize], wait in [delayMs] windows.
  /// - If the queue grows during the wait but still doesn't reach [targetSize],
  ///   wait another window (up to [maxExtraRounds] times).
  /// - If the queue does not grow, return quickly so we flush the tail.
  /// - If [_immediateFlushRequested] (close / switchSpace / flush), return
  ///   immediately; the wait is interruptible via [_tailWaitWake].
  ///
  /// This matches "keep waiting 5s while data keeps arriving" for mobile,
  /// without starving durability indefinitely.
  Future<void> _waitTailFillWhileGrowing({
    required int targetSize,
    required int delayMs,
    int maxExtraRounds = 5,
  }) async {
    if (_immediateFlushRequested) return;
    if (delayMs <= 0) return;
    if (_bufferManager.queueLength >= targetSize) return;
    if (maxExtraRounds < 0) maxExtraRounds = 0;

    int rounds = 0;
    while (true) {
      if (_immediateFlushRequested) return;
      final before = _bufferManager.queueLength;
      if (before >= targetSize) return;
      if (before <= 0) return;

      // First window: respect configured latency when it is already short
      // (e.g. tests with maxFlushLatencyMs=100); keep up to 1s for energy-saving defaults.
      final windowMs =
          rounds == 0 ? (delayMs < 1000 ? delayMs : 1000) : delayMs;
      final wake = Completer<void>();
      _tailWaitWake = wake;
      try {
        await Future.any<void>([
          Future<void>.delayed(Duration(milliseconds: windowMs)),
          wake.future,
        ]);
      } finally {
        if (identical(_tailWaitWake, wake)) {
          _tailWaitWake = null;
        }
      }
      if (_immediateFlushRequested) return;

      final after = _bufferManager.queueLength;
      if (after >= targetSize) return;

      // If no growth in this window, flush now (tail is stable).
      if (after <= before) return;

      // If data is still coming in but we are below target, extend the wait.
      if (after > before && rounds < maxExtraRounds) {
        rounds++;
        continue;
      }
      return;
    }
  }

  /// Flush pump.
  ///
  /// - Normal mode (drainCompletely=false): Used for online flush
  /// - Drain mode (drainCompletely=true): Used for close/switch space, ignore the early-exit rule, continue flush until the queue is empty.
  Future<void> _pumpFlush({
    bool drainCompletely = false,
    BatchContext? recoveryBatchContext,
    int? batchSizeOverride,
  }) async {
    // 1. Guard: If we are in recovery mode, we MUST NOT run a "normal" flush (context == null).
    // Normal flushes would steal records meant for the recovery batch and write them with a new BatchId,
    // breaking idempotency. Only allow flushes explicitly triggered by recovery (context != null).
    // Drain mode (close / migration durability) must not silently no-op — wait for recovery
    // then continue, so callers like WAL cutover wait cannot hang forever.
    if (_isRecovering && recoveryBatchContext == null) {
      if (!drainCompletely) {
        return;
      }
      await waitUntilRecoveryCompleted();
      if (!_running) return;
    }

    // If a previous parallel flush batch was left pending (crash or in-run failure),
    // reconcile it first to guarantee durability and prevent overlapping batches.
    // The check above (isRecovering) handles the recursion case, but we keep the explicit
    // recoveryBatchContext check for clarity and safety.
    if (_dataStore.config.enableJournal &&
        _walManager.hasPendingParallelBatches &&
        recoveryBatchContext == null) {
      // After checkpoint advanced by recovery, drop already-committed queue entries
      // so we don't keep reprocessing persisted WAL operations.
      await _bufferManager.cleanupCommittedUpTo(
        _walManager.meta.checkpoint,
        _dataStore.config.logPartitionCycle,
      );
    }

    final batchSize = batchSizeOverride ?? _dataStore.config.writeBatchSize;
    bool firstIteration = true;
    final int delayMs = _dataStore.config.maxFlushLatencyMs;

    while (_running &&
        (!_bufferManager.isEmpty ||
            !_dataStore.backgroundWriteScheduler.isEmpty)) {
      List<WriteQueueEntry> batch = const <WriteQueueEntry>[];
      try {
        // This is the first iteration, we need to ensure at least one batch is flushed.
        // After the first iteration, if the queue length drops below batchSize in normal mode,
        // wait up to maxFlushLatencyMs before flushing the remaining tail, to avoid flushing
        // every tiny batch immediately while still bounding latency.
        // In drain mode (close/switch space) or when immediate flush is requested,
        // ignore this and ensure the queue is fully flushed.
        if (!drainCompletely && !_immediateFlushRequested) {
          final currentSize = _bufferManager.queueLength;
          if (currentSize < batchSize) {
            await _waitTailFillWhileGrowing(
              targetSize: batchSize,
              delayMs: delayMs,
              maxExtraRounds: 3,
            );
          }
        }

        // stopWithoutFlush set _running=false and woke the tail wait: exit
        // before popping more work so remaining buffers can be discarded.
        if (!_running && !drainCompletely) {
          break;
        }

        // Single-pass guard for recovery batches: process exactly one batch then stop.
        if (recoveryBatchContext != null && !firstIteration) {
          break;
        }

        final batchSw = Stopwatch()..start();

        final int backgroundRecordsCount;
        List<BackgroundWriteEntry> bgEntries = const [];

        final hasBackground = !_dataStore.backgroundWriteScheduler.isEmpty;
        int normalBatchSize = batchSize;
        int backgroundLimit = 0;

        // Allocate quota: reserve 10% for background task if it has work
        if (hasBackground) {
          final int minBgLimit = (batchSize * 0.1).ceil();
          normalBatchSize = batchSize - minBgLimit;
          backgroundLimit = minBgLimit;
        }

        // Pop normal batch from buffer manager
        if (normalBatchSize > 0) {
          batch = _bufferManager.popBatch(normalBatchSize);
        }

        // Poll background write entries using the remaining budget
        if (hasBackground) {
          final remainingCapacity = batchSize - batch.length;
          if (remainingCapacity > backgroundLimit) {
            backgroundLimit = remainingCapacity;
          }
          bgEntries = _dataStore.backgroundWriteScheduler
              .pollBackgroundWriteEntries(backgroundLimit);

          // If background entries are less than limit, give excess capacity back to normal writes
          if (bgEntries.length < backgroundLimit &&
              batch.length < normalBatchSize) {
            final extraNormalLimit = backgroundLimit - bgEntries.length;
            final extraNormal = _bufferManager.popBatch(extraNormalLimit);
            batch = [...batch, ...extraNormal];
          }
        }

        backgroundRecordsCount = bgEntries.length;

        if (batch.isEmpty && bgEntries.isEmpty) {
          // In drain mode, keep looping while background scheduler still has work.
          if (drainCompletely && !_dataStore.backgroundWriteScheduler.isEmpty) {
            continue;
          }
          // Both queues are empty; wait for next schedule in normal mode.
          break;
        }

        // Mute trailing SpaceStats KV singleton only: length short-circuit then
        // O(1) recordId == const key (InternalKv pk). No extra state.
        final quietSpaceStatsLog =
            batch.length == 1 && batch.first.recordId == SpaceStats.kvKey;
        if (!quietSpaceStatsLog) {
          final bgSuffix = backgroundRecordsCount > 0
              ? " and $backgroundRecordsCount background write items"
              : "";
          Logger.debug(
              "Executing batch with ${batch.length} normal items$bgSuffix");
        }

        firstIteration = false;
        // Compute WAL pointer range from normal buffer entries only.
        // Background-only batches have no WAL coverage — never use the
        // (-1,0) sentinel as start/end (that previously poisoned checkpoint).
        final startPtr =
            _firstRealWalPointer(batch) ?? _walManager.meta.checkpoint;
        final endPtr =
            _lastRealWalPointer(batch) ?? _walManager.meta.checkpoint;

        // Group by table and FINAL operation (derive from current buffer entry to allow coalescing and de-dup per PK)
        // Skip entries for tables that are being cleared to avoid race conditions where clearTable
        // deletes files while flush is processing queued operations.
        // Coalesce all records (migration + business) by PK to ensure consistency
        final Map<TableUid, Map<String, BufferEntry>> tablePkMap = {};
        final Map<TableUid, int> tableEpochs = {};
        final Map<TableUid, List<WriteQueueEntry>> entriesByTable = {};
        final Map<TableUid, List<BackgroundWriteEntry>> bgEntriesByTable = {};
        final Map<TableUid, List<BackgroundWriteEntry>> bgLargeUpdatesByTable =
            {};

        final yieldController =
            YieldController('ParallelJournalManager._pumpFlush');

        // Calculate the target checkpoint for each table in this batch
        final Map<TableUid, String> targetCheckpoints = {};
        final flushCheckpointMap = <String, BgTaskProgress>{};
        for (final entry in bgEntries) {
          bgEntriesByTable.putIfAbsent(entry.tableUid, () => []).add(entry);
          if (entry.type == BackgroundWriteType.largeUpdate) {
            bgLargeUpdatesByTable
                .putIfAbsent(entry.tableUid, () => [])
                .add(entry);
          }
          if (entry.type == BackgroundWriteType.schemaMigration &&
              entry.nextCursor != null) {
            targetCheckpoints[entry.tableUid] = entry.nextCursor!;
          }
          final currentProgress = flushCheckpointMap[entry.taskId];
          final count = (currentProgress?.count ?? 0) + 1;
          final String? latestCheckpointKey =
              entry.currentCursor ?? currentProgress?.checkpointKey;
          flushCheckpointMap[entry.taskId] = BgTaskProgress(
            checkpointKey: latestCheckpointKey,
            count: count,
          );
        }

        // Process business writes (as the "newer" data, overwriting migration)
        for (final e in batch) {
          final y1 = yieldController.maybeYield();
          if (y1 != null) await y1;
          final tableContext = await _tableContextFromUid(e.tableUid);
          if (tableContext == null) continue;
          tableEpochs.putIfAbsent(
              e.tableUid, () => _bufferManager.getClearEpoch(tableContext));

          final be = _bufferManager.getBufferedRecord(tableContext, e.recordId);
          if (be == null) continue;

          BufferEntry effectiveEntry = be;
          final migrationManager = _dataStore.migrationManager;
          if (migrationManager != null &&
              migrationManager.hasRuntimeMigrationForTable(tableContext) &&
              migrationManager.shouldNormalizeBufferedWrite(
                tableContext,
                be.walPointer,
              )) {
            final normalizedData = migrationManager.normalizeRecordToLatestSync(
              tableContext,
              be.data,
              fromVersion: be.schemaVersion,
            );
            final normalizedOldValues = be.oldValues != null
                ? migrationManager.normalizeRecordToLatestSync(
                    tableContext,
                    be.oldValues!,
                    fromVersion: be.schemaVersion,
                  )
                : null;
            effectiveEntry = be.copyWith(
                data: normalizedData, oldValues: normalizedOldValues);
          }

          // Check if table is being cleared - if so, skip this entry to avoid race condition
          if (_dataStore.tableDataManager.isTableBeingCleared(tableContext)) {
            continue;
          }

          // Business write ALWAYS overwrites migration data for the same PK
          final pkMap = tablePkMap.putIfAbsent(e.tableUid, () => {});
          pkMap[e.recordId] = effectiveEntry;

          entriesByTable.putIfAbsent(e.tableUid, () => []).add(e);
        }

        // 3. Finalize 'grouped' structure from the coalesced PK maps
        final Map<TableUid, Map<BufferOperationType, Map<String, BufferEntry>>>
            grouped = {};
        int totalBatchUniqueRecords = 0;

        tablePkMap.forEach((table, pkMap) {
          final byOp = grouped.putIfAbsent(
              table, () => <BufferOperationType, Map<String, BufferEntry>>{});
          pkMap.forEach((pk, entry) {
            final mapByOp = byOp.putIfAbsent(
                entry.operation, () => <String, BufferEntry>{});
            mapByOp[pk] = entry;
            totalBatchUniqueRecords++;
          });
        });

        final journaling = _dataStore.config.enableJournal;
        // Register pending batch in WAL meta (multi-batch)
        BatchContext? currentBatchContext;
        if (recoveryBatchContext != null) {
          // In recovery mode, use the provided context and skip creating a new pending batch
          currentBatchContext = recoveryBatchContext;
        }

        int estimatedTotalWorkOps = 0;
        final allTables = <TableUid>{...grouped.keys, ...bgEntriesByTable.keys};
        final tablePlans = <TableUid, BatchTablePlan>{};

        for (final tableUid in allTables) {
          final tableContext = await _resolveTableContext(tableUid);
          if (tableContext == null) continue;
          try {
            final schema = await _dataStore.tableMetaManager
                ?.getTableSchema(tableContext.tableUid);
            final tableDataMeta = await _dataStore.tableDataManager
                .getTableDataMeta(tableContext.tableUid);
            final indexUids = <IndexUid>[];
            final baseIndexTotalEntries = <IndexUid, int>{};
            final baseIndexTotalSizeInBytes = <IndexUid, int>{};

            if (schema != null) {
              // B+Tree indexes only (vector indexes have separate meta).
              final allIndexes = <IndexSchema>[
                ...?_dataStore.tableMetaManager?.getBtreeIndexesFor(schema),
                ...?_dataStore.indexManager
                    ?.getEngineManagedBtreeIndexes(tableContext, schema),
              ];
              for (final idx in allIndexes) {
                indexUids.add(idx.indexUid);

                // Fetch base index metadata
                final idxMeta = await _dataStore.indexManager
                    ?.getIndexMeta(tableContext.tableUid, idx.indexUid);
                if (idxMeta != null) {
                  baseIndexTotalEntries[idx.indexUid] = idxMeta.totalEntries;
                  baseIndexTotalSizeInBytes[idx.indexUid] =
                      idxMeta.totalSizeInBytes;
                }
              }
            }

            // Calculate ops for timeout: records * (1 + indexCount)
            int tableRecordCount = 0;
            grouped[tableUid]
                ?.forEach((_, map) => tableRecordCount += map.length);

            final bgRecords = bgEntriesByTable[tableUid] ?? [];
            tableRecordCount += bgRecords.length;

            estimatedTotalWorkOps += tableRecordCount * (1 + indexUids.length);

            tablePlans[tableUid] = BatchTablePlan(
              willUpdateTableDataMeta: true,
              indexes: indexUids,
              willUpdateIndexMeta: indexUids.isNotEmpty,
              baseTotalRecords: tableDataMeta?.totalRecords,
              baseTotalSizeInBytes: tableDataMeta?.totalSizeInBytes,
              baseIndexTotalEntries: baseIndexTotalEntries,
              baseIndexTotalSizeInBytes: baseIndexTotalSizeInBytes,
            );
          } catch (_) {}
        }

        if (recoveryBatchContext == null && journaling) {
          try {
            final batchId = GlobalIdGenerator.generate('flush_batch_');
            // Register pending BEFORE exposing BatchContext: if persist fails we
            // must not write redo / markers under an untracked batchId.
            await _walManager.addPendingParallelBatch(PendingParallelBatch(
              batchId: batchId,
              batchType: BatchType.flush,
              start: startPtr,
              end: endPtr,
              tablePlans: tablePlans,
              createdAt: DateTime.now().toIso8601String(),
            ));
            currentBatchContext = BatchContext.flush(batchId);
          } catch (e) {
            Logger.error(
              'Failed to register pending flush batch; aborting this pump turn',
              rawError: e,
            );
            if (batch.isNotEmpty) {
              try {
                _bufferManager.requeueFront(batch);
              } catch (_) {}
            }
            break;
          }
        }
        if (journaling && currentBatchContext != null) {
          _activeBatchContext = currentBatchContext;
        }

        // Build per-table tasks with unified insert/update/delete handling to minimize partition rewrites.
        final tasks = <Future<void> Function()>[];
        late final int plannedTableConcurrency;
        late final int perTableTokenBudget;

        for (final tableUid in allTables) {
          final tableContext = await _tableContextFromUid(tableUid);
          if (tableContext == null) continue;
          final tableName = tableContext.tableName;
          // Use the epoch captured before/during grouping
          final capturedEpoch = tableEpochs[tableUid] ??
              _bufferManager.getClearEpoch(tableContext);
          final tableQueueItems = entriesByTable[tableUid] ?? [];
          final tableBgEntries = bgEntriesByTable[tableUid] ?? [];

          final byOp = grouped[tableUid];
          final inserts = byOp?[BufferOperationType.insert]
                  ?.values
                  .toList(growable: false) ??
              const <BufferEntry>[];
          final updates = byOp?[BufferOperationType.update]
                  ?.values
                  .toList(growable: false) ??
              const <BufferEntry>[];
          final deletes = byOp?[BufferOperationType.delete]
                  ?.values
                  .toList(growable: false) ??
              const <BufferEntry>[];

          final allEntries = <BufferEntry>[
            ...inserts,
            ...updates,
            ...deletes,
          ];
          if (allEntries.isEmpty && tableBgEntries.isEmpty) continue;

          tasks.add(() async {
            try {
              if (_dataStore.tableDataManager
                  .isTableBeingCleared(tableContext)) {
                return;
              }
              if (_bufferManager.getClearEpoch(tableContext) != capturedEpoch) {
                Logger.info(
                    "Skipping stale batch for table $tableName because it was cleared/reset.");
                return;
              }

              await _dataStore.tableDataManager.withTableWriteLock(
                tableContext,
                (tableLock) async {
                  // clearTable sets this admission flag before it gets the
                  // table lock. A flush may win the lock race after that, so
                  // re-check here and let clearTable proceed first.
                  if (_dataStore.tableDataManager
                      .isTableBeingCleared(tableContext)) {
                    return;
                  }

                  // Verify epoch hasn't changed (O(1) check for table clear race)
                  if (_bufferManager.getClearEpoch(tableContext) !=
                      capturedEpoch) {
                    Logger.info(
                        "Skipping stale batch for table $tableName because it was cleared/reset.");
                    return;
                  }

                  // Unified flush: parallelize table data and index maintenance
                  final schema = await _resolveTableSchema(tableUid);
                  if (schema == null) return;
                  final pkName = schema.primaryKey;
                  final migrationManager = _dataStore.migrationManager;

                  // Extract and separate valid background write data
                  final activeBgEntries =
                      tableBgEntries.where((e) => e.isValid).toList();

                  // 1) Unified pk-map coalescing (overwrite background with business writes)
                  final Map<String, BufferEntry> unifiedPkMap = {};

                  // First load background writes (if mode includes table write)
                  for (final bgEntry in activeBgEntries) {
                    if (bgEntry.mode == MigrationWriteMode.tableOnly ||
                        bgEntry.mode == MigrationWriteMode.tableAndIndex) {
                      unifiedPkMap[bgEntry.primaryKey] = bgEntry.entry;
                    }
                  }

                  // Then overwrite with normal business writes (newer)
                  final businessPkMap = tablePkMap[tableUid];
                  if (businessPkMap != null) {
                    unifiedPkMap.addAll(businessPkMap);
                  }

                  final insertRecords = <Map<String, dynamic>>[];
                  final updateRecords = <Map<String, dynamic>>[];
                  final deleteRecords = <Map<String, dynamic>>[];

                  // 3) Symmetrically upgrade records to current active version and classify
                  for (final be in unifiedPkMap.values) {
                    final y2 = yieldController.maybeYield();
                    if (y2 != null) await y2;
                    var currentData = be.data;
                    if (migrationManager != null &&
                        be.schemaVersion.isNotEmpty &&
                        migrationManager
                            .hasRuntimeMigrationForTable(tableContext)) {
                      currentData =
                          migrationManager.normalizeRecordToLatestSync(
                        tableContext,
                        be.data,
                        fromVersion: be.schemaVersion,
                      );
                    }

                    if (be.operation == BufferOperationType.insert ||
                        be.operation == BufferOperationType.rewrite) {
                      insertRecords.add(currentData);
                    } else if (be.operation == BufferOperationType.update) {
                      updateRecords.add(currentData);
                    } else if (be.operation == BufferOperationType.delete) {
                      deleteRecords.add(currentData);
                    }
                  }

                  // 4) Identify missing old values for index updates
                  final missingOld = <String>[];
                  for (final be in unifiedPkMap.values) {
                    if (be.operation == BufferOperationType.update &&
                        be.oldValues == null) {
                      final pk = be.data[pkName]?.toString();
                      if (pk != null && pk.isNotEmpty) {
                        missingOld.add(pk);
                      }
                    }
                  }

                  final oldByPk = <String, Map<String, dynamic>>{};
                  if (missingOld.isNotEmpty) {
                    try {
                      final olds =
                          await _dataStore.tableDataManager.queryRecordsBatch(
                        tableContext,
                        missingOld,
                      );
                      for (final r in olds.records) {
                        final y3 = yieldController.maybeYield();
                        if (y3 != null) await y3;
                        final pk = r[pkName]?.toString();
                        if (pk == null || pk.isEmpty) continue;

                        var normalizedRecord = r;
                        if (migrationManager != null &&
                            migrationManager
                                .hasRuntimeMigrationForTable(tableContext)) {
                          normalizedRecord =
                              migrationManager.normalizeRecordToLatestSync(
                            tableContext,
                            r,
                            fromVersion: '',
                          );
                        }
                        oldByPk[pk] = normalizedRecord;
                      }
                    } catch (_) {}
                  }

                  // 5) Build coalesced index update buckets (global vs specific)
                  final idxInserts = <Map<String, dynamic>>[];
                  final idxUpdates = <IndexRecordUpdate>[];
                  final idxDeletes = <Map<String, dynamic>>[];
                  final Map<String, List<BackgroundWriteEntry>> bgIndexTasks =
                      {};

                  // Normal business writes
                  for (final be in inserts) {
                    idxInserts.add(be.data);
                  }
                  for (final be in deletes) {
                    idxDeletes.add(be.data);
                  }
                  for (final be in updates) {
                    final pk = be.data[pkName]?.toString();
                    if (pk == null || pk.isEmpty) continue;
                    final oldVals = be.oldValues ?? oldByPk[pk];
                    if (oldVals == null) {
                      idxInserts.add(be.data);
                    } else {
                      idxUpdates.add(IndexRecordUpdate(
                        primaryKey: pk,
                        // Share buffer maps by ref; index delta compute copies
                        // before any mutate.
                        newValues: be.data,
                        oldValues: oldVals,
                      ));
                    }
                  }

                  // Background writes (merged into global if specIdxs is empty)
                  for (final bgEntry in activeBgEntries) {
                    final mode = bgEntry.mode;
                    if (mode == MigrationWriteMode.indexOnly ||
                        mode == MigrationWriteMode.tableAndIndex) {
                      final specIdxs = bgEntry.specificIndexUids;
                      if (specIdxs == null || specIdxs.isEmpty) {
                        final be = bgEntry.entry;
                        if (be.operation == BufferOperationType.insert ||
                            be.operation == BufferOperationType.rewrite) {
                          idxInserts.add(be.data);
                        } else if (be.operation == BufferOperationType.update) {
                          final pk = bgEntry.primaryKey;
                          final oldVals = be.oldValues ?? oldByPk[pk];
                          if (oldVals == null) {
                            idxInserts.add(be.data);
                          } else {
                            idxUpdates.add(IndexRecordUpdate(
                              primaryKey: pk,
                              newValues: be.data,
                              oldValues: oldVals,
                            ));
                          }
                        } else if (be.operation == BufferOperationType.delete) {
                          idxDeletes.add(be.data);
                        }
                      } else {
                        final key = specIdxs.join(',');
                        bgIndexTasks.putIfAbsent(key, () => []).add(bgEntry);
                      }
                    }
                  }

                  final allIndexes = <IndexSchema>[
                    ...?_dataStore.tableMetaManager?.getAllIndexesFor(schema),
                    ...?_dataStore.indexManager
                        ?.getEngineManagedBtreeIndexes(tableContext, schema),
                  ];
                  final btreeIndexCount = allIndexes
                      .where((i) => i.type != IndexType.vector)
                      .length;
                  final split = IoConcurrencyPlanner.splitPerTableBudget(
                    perTableTokens: perTableTokenBudget,
                    indexCount: btreeIndexCount,
                  );

                  // 6) Execution actions
                  Future<void> writeTableData() async {
                    if (insertRecords.isNotEmpty ||
                        updateRecords.isNotEmpty ||
                        deleteRecords.isNotEmpty) {
                      await _dataStore.tableDataManager.writeChanges(
                        table: tableContext,
                        inserts: insertRecords,
                        updates: updateRecords,
                        deletes: deleteRecords,
                        batchContext: currentBatchContext,
                        concurrency: split.tableDataTokens,
                        tableLock: tableLock,
                      );
                    }
                  }

                  Future<void> indexWrite() async {
                    if (allIndexes.isNotEmpty &&
                        (idxInserts.isNotEmpty ||
                            idxUpdates.isNotEmpty ||
                            idxDeletes.isNotEmpty)) {
                      await (_dataStore.indexManager?.writeChanges(
                            table: tableContext,
                            inserts: idxInserts,
                            updates: idxUpdates,
                            deletes: idxDeletes,
                            batchContext: currentBatchContext,
                            concurrency: split.indexTokens,
                          ) ??
                          Future.value());
                    }

                    if (bgIndexTasks.isNotEmpty) {
                      for (final specKey in bgIndexTasks.keys) {
                        final entries = bgIndexTasks[specKey]!;
                        final specificIdxs = entries.first.specificIndexUids;

                        final specIns = <Map<String, dynamic>>[];
                        final specUps = <IndexRecordUpdate>[];
                        final specDels = <Map<String, dynamic>>[];

                        for (final entry in entries) {
                          final be = entry.entry;
                          final pk = entry.primaryKey;
                          if (be.operation == BufferOperationType.insert ||
                              be.operation == BufferOperationType.rewrite) {
                            specIns.add(be.data);
                          } else if (be.operation ==
                              BufferOperationType.update) {
                            final oldVals = be.oldValues ?? oldByPk[pk];
                            if (oldVals == null) {
                              specIns.add(be.data);
                            } else {
                              specUps.add(IndexRecordUpdate(
                                primaryKey: pk,
                                newValues: be.data,
                                oldValues: oldVals,
                              ));
                            }
                          } else if (be.operation ==
                              BufferOperationType.delete) {
                            specDels.add(be.data);
                          }
                        }

                        List<IndexSchema>? targetOverride;
                        if (specificIdxs != null) {
                          targetOverride = allIndexes
                              .where((i) => specificIdxs.contains(i.indexUid))
                              .toList();
                        }

                        await (_dataStore.indexManager?.writeChanges(
                              table: tableContext,
                              inserts: specIns,
                              updates: specUps,
                              deletes: specDels,
                              batchContext: currentBatchContext,
                              concurrency: split.indexTokens,
                              targetIndexesOverride: targetOverride,
                            ) ??
                            Future.value());
                      }
                    }
                  }

                  if (allIndexes.isEmpty) {
                    await writeTableData();
                  } else if (split.runInParallel) {
                    await Future.wait([writeTableData(), indexWrite()]);
                  } else {
                    await writeTableData();
                    await indexWrite();
                  }

                  // Cleanup in-memory buffers for this table IMMEDIATELY after it is written.
                  if (tableQueueItems.isNotEmpty) {
                    await _bufferManager.cleanupAfterBatch(tableQueueItems);
                  }

                  // Release unique key reservations for large update operations to prevent memory leaks and blocking
                  final largeUpdates = bgLargeUpdatesByTable[tableUid];
                  if (largeUpdates != null && largeUpdates.isNotEmpty) {
                    for (final bgEntry in largeUpdates) {
                      if (bgEntry.isValid) {
                        try {
                          _bufferManager.releaseReservedUniqueKeys(
                            table: tableContext,
                            recordId: bgEntry.primaryKey,
                          );
                        } catch (_) {}
                      }
                    }
                  }
                },
                operationPrefix: 'flush_batch_unified_',
              );
            } catch (e) {
              Logger.error('Flush task failed for table [$tableName]',
                  rawError: e);
              rethrow;
            }
          });
        }

        // Execute with controlled parallelism; allocate flush budget and split outer/inner
        if (tasks.isNotEmpty) {
          final type = (currentBatchContext?.batchType == BatchType.maintenance)
              ? WorkloadType.maintenance
              : WorkloadType.flush;
          final scheduler = _dataStore.workloadScheduler;
          final int typeCapacity = scheduler.capacityTokens(type);
          // Best-effort physical headroom (avoid oversubscribe when other workloads already hold tokens).
          final int physicalAvailable =
              max(0, scheduler.globalMax - scheduler.totalUsedTokens);
          final int effectiveCapacity =
              max(1, min(typeCapacity, max(1, physicalAvailable)));
          final int taskCount = tasks.length;
          plannedTableConcurrency = IoConcurrencyPlanner.planTableConcurrency(
            capacityTokens: effectiveCapacity,
            tableCount: taskCount,
            minTokensPerTable: 2,
          );
          perTableTokenBudget =
              max(1, (effectiveCapacity / plannedTableConcurrency).floor());

          final int outerConcurrency = plannedTableConcurrency;
          // Calculate dynamic timeout based on actual batch size and max partition file size
          // Base 300s + 50ms per atomic operation (record write or index update)
          final int timeoutSeconds =
              300 + (estimatedTotalWorkOps * 0.05).ceil();
          final timeout = Duration(seconds: timeoutSeconds);
          await ParallelProcessor.execute<void>(
            tasks,
            concurrency: outerConcurrency,
            label: 'ParallelJournalManager.flush',
            timeout: timeout,
            continueOnError: false,
          );

          // Clear map reference to release memory immediately for GC optimization
          bgLargeUpdatesByTable.clear();

          // ── Backpressure: measure per-record flush cost ──
          final batchElapsedUs = batchSw.elapsedMicroseconds;
          if (batch.isNotEmpty) {
            _perRecordFlushUs = batchElapsedUs ~/ batch.length;
          }
          // Reset throttle if queue is no longer congested after flush,
          // so remaining operations don't wait unnecessarily.
          if (_throttleDelayPerRecordUs > 0 &&
              _bufferManager.queueLength <= _dataStore.config.writeBatchSize) {
            _throttleDelayPerRecordUs = 0;
          }

          if (!quietSpaceStatsLog) {
            final now = DateTime.now();
            final at =
                '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${now.millisecond.toString().padLeft(3, '0')}';
            Logger.debug(
                'Batch flush completed: items=${batch.length}, tables=${grouped.length}, records=$totalBatchUniqueRecords, remaining=${_bufferManager.queueLength}, cost=${batchSw.elapsedMilliseconds}ms, at: $at');
          }

          // Trigger resource check after significant data writes
          if (batch.length >= (_dataStore.config.writeBatchSize * 0.8)) {
            _dataStore.resourceManager?.triggerImmediateCheck();
          }
        }

        // Mark completed and advance checkpoint
        if (journaling && currentBatchContext != null) {
          try {
            await _dataStore.storage.flushAll();
          } catch (_) {}

          await _walManager.advanceCheckpoint(endPtr);
          await _walManager
              .removePendingParallelBatch(currentBatchContext.batchId);
          await _deletePageRedoLogIfExists(currentBatchContext.batchId);
          await _walManager.cleanupObsoletePartitions();

          // Durability: flush recovery artifacts at batch end if enabled
          try {
            await _flushRecoveryArtifactsIfNeeded();
          } catch (_) {}

          // Handle migration completion callback after all tables in the batch are persisted
          if (bgEntries.isNotEmpty && _dataStore.migrationManager != null) {
            await _dataStore.migrationManager
                ?.onBackgroundWritePersisted(flushCheckpointMap);
          }

          _activeBatchContext = null;

          // If this was a recovery flush, check if we can clear the recovering flag
          if (recoveryBatchContext != null) {
            // After checkpoint advanced by recovery, drop already-committed queue entries
            // that might have been added by _recoverFromWal during the recovery window.
            await _bufferManager.cleanupCommittedUpTo(
              _walManager.meta.checkpoint,
              _dataStore.config.logPartitionCycle,
            );

            if (_walManager.meta.pendingBatches.isEmpty) {
              _isRecovering = false;
              scheduleFlushIfNeeded(); // Trigger non-batch WAL write queue
              Logger.debug('Parallel journal recovery completed.');
            }
          }
        } else {
          await _dataStore.storage.flushAll();
          // Handle migration completion callback after all tables in the batch are persisted
          if (bgEntries.isNotEmpty && _dataStore.migrationManager != null) {
            await _dataStore.migrationManager
                ?.onBackgroundWritePersisted(flushCheckpointMap);
          }
        }
        await _dataStore.tableDataManager.persistRuntimeMetaIfNeeded();
      } catch (e) {
        Logger.error('ParallelJournalManager loop failed', rawError: e);
        // IMPORTANT: do not drop popped queue entries on failure.
        // Requeue them so the next pump/recovery can safely retry.
        if (batch.isNotEmpty) {
          try {
            _bufferManager.requeueFront(batch);
          } catch (_) {}
        }
        // Backoff on errors and exit pump to avoid tight retry
        await Future.delayed(const Duration(milliseconds: 100));
        break;
      }
    }
  }

  void _onBufferSizeChanged(int size) {
    if (!_running) return;

    // ── Backpressure: O(1) — scale delay by queue backlog level ──
    // When congested (queue > batchSize) and we have a measurement,
    // throttle delay scales with backlog: multiplier = queue ~/ batchSize.
    // At 2x batchSize → 2x per-record cost, at 3x → 3x, etc.
    // When not congested or no measurement yet, throttle is 0 (disabled).
    final batchSize = _dataStore.config.writeBatchSize;
    if (size > batchSize && _perRecordFlushUs > 0) {
      _throttleDelayPerRecordUs = _perRecordFlushUs * (size ~/ batchSize);
    } else {
      _throttleDelayPerRecordUs = 0;
    }

    if (size <= 0) {
      return;
    }
    // Whenever the buffer becomes non-empty, trigger a flush pump if not running.
    // The pump itself will handle batching and tail latency via maxFlushLatencyMs.
    scheduleFlushIfNeeded();
    // Also notify WAL manager so that WAL append queue is flushed in a similar cadence.
    try {
      _walManager.scheduleFlushIfNeeded();
    } catch (_) {}
    // Notify recovery layer once per idle->active transition; debounced inside StorageAdapter.
    try {
      StorageAdapter.notifyRecoveryWrite();
    } catch (_) {}
  }

  Future<void> _recoverFromWal({List<_WalRange>? excludeRanges}) async {
    try {
      final hasLogs = _walManager.hasExistingLogs;
      if (!_dataStore.config.enableJournal && !hasLogs) return;
      final meta = _walManager.meta;
      // If there are no known WAL partitions, nothing to replay.
      if (meta.existingStartPartitionIndex < 0 ||
          meta.existingEndPartitionIndex < 0) {
        return;
      }

      // Fast-path: skip full replay when tail partition file is unchanged since last recovery
      // (single getFileSize check, no file content read).
      if (await _walManager.tryFastPathSkipRecovery()) return;

      final checkpoint = meta.checkpoint;

      // Fast-path: if checkpoint partition equals tail partition, only need last pointer
      // in the cycle, we know there is unprocessed WAL without examining entry
      // sequence numbers. Otherwise, we need to inspect the last WAL pointer
      // in the tail partition to decide.
      WalPointer? tailLastPtr;
      final int tailP = meta.existingEndPartitionIndex;
      if (checkpoint.partitionIndex == tailP) {
        tailLastPtr = await _walManager.readLastWalPointer();
        if (tailLastPtr == null ||
            tailLastPtr.entrySeq <= checkpoint.entrySeq) {
          final ptr = tailLastPtr ?? checkpoint;
          _walManager.updateCurrentPointerAfterRecovery(ptr);
          try {
            await _walManager.setLastRecoveredPointer(ptr);
          } catch (_) {}
          return;
        }
      }

      final startP = checkpoint.partitionIndex;
      // Use existingEndPartitionIndex as the logical tail of WAL partitions.
      final endP = tailP;
      final cap = _dataStore.config.logPartitionCycle;

      int p = startP;
      bool first = true;
      // Track the last WAL pointer we actually scanned so that WAL manager
      // can update its in-memory current pointer precisely after recovery.
      int lastPartition = startP;
      int lastSeq = checkpoint.entrySeq;
      // Whether there exists any WAL entry between [checkpoint, tail] that
      // still needs to be flushed to table files (i.e. not skipped by
      // clear/drop cutoff and not belonging to a dropped table).
      bool hasEffectiveEntry = false;
      // Track max primary key for each table during WAL recovery
      // This will be used to update maxId after recovery completes
      final Map<TableUid, dynamic> maxPkByTable = <TableUid, dynamic>{};
      final Map<TableUid, MatcherFunction> pkMatchersByTable =
          <TableUid, MatcherFunction>{};
      // Precompute table-level WAL cutoff pointers from WAL meta (clear/drop ops)
      final Map<TableUid, List<WalPointer>> tableCutoffs =
          <TableUid, List<WalPointer>>{};
      try {
        for (final op in _walManager.tableOps.values) {
          final normalized = await _dataStore.tableMetaManager
                  ?.normalizeTableFieldKey(op.tableUid) ??
              op.tableUid;
          final tableUid = TableUid(normalized);
          tableCutoffs
              .putIfAbsent(tableUid, () => <WalPointer>[])
              .add(op.cutoff);
        }
      } catch (_) {}
      final encoderConfig = EncryptionManager.getCurrentEncodingState();
      final partitionYieldController = YieldController(
          'ParallelJournalManager._recoverFromWal.partition',
          checkInterval: 1);
      while (true) {
        final y4 = partitionYieldController.maybeYield();
        if (y4 != null) await y4;
        final dirIndex = _walManager.getPartitionDirIndex(p);
        final path = dirIndex != null
            ? _dataStore.pathManager.getWalPartitionLogPath(dirIndex, p,
                spaceName: _dataStore.currentSpaceName)
            : _dataStore.pathManager.getWalPartitionLogPath(
                p ~/ _dataStore.maxEntriesPerDir, p,
                spaceName: _dataStore.currentSpaceName);
        int toSkip = 0;
        if (first) {
          toSkip = meta.checkpoint.entrySeq; // skip already processed
        }
        int seq = 0;
        try {
          // Check if file exists before reading to avoid PathNotFoundException
          final exists = await _dataStore.storage.existsFile(path);
          if (!exists) {
            // File doesn't exist, skip this partition (may be first startup or file was deleted)
            if (p == endP) break;
            p = (p + 1) % cap;
            first = false;
            if (p == startP) break;
            continue;
          }

          // Read WAL file as binary and decode using WalEncoder
          final fileBytes = await _dataStore.storage.readAsBytes(path);
          if (fileBytes.isEmpty) {
            if (p == endP) break;
            p = (p + 1) % cap;
            first = false;
            if (p == startP) break;
            continue;
          }

          // Decode all entries from file using isolate for performance
          // Pass partition index for AAD verification
          final entries = await WalDecodeBatchRunner.decodeFile(
            fileBytes: fileBytes,
            partitionIndex: p,
            encoderConfig: encoderConfig,
          );

          // Process each entry
          final yieldController =
              YieldController('ParallelJournalManager._recoverFromWal');

          for (final entry in entries) {
            final y5 = yieldController.maybeYield();
            if (y5 != null) await y5;
            seq++;
            if (first && seq <= toSkip) continue;

            final ptr = WalPointer(partitionIndex: p, entrySeq: seq);

            // Skip entries that were already handled by parallel journal reconciliation
            // to avoid duplicate data in buffer and incorrect record count stats.
            if (excludeRanges != null && excludeRanges.isNotEmpty) {
              bool inExclude = false;
              final cap = _dataStore.config.logPartitionCycle;
              for (final range in excludeRanges) {
                final bool afterStart =
                    ptr == range.start || ptr.isNewerThan(range.start, cap);
                if (!afterStart) continue;
                final bool beforeEnd =
                    ptr == range.end || !ptr.isNewerThan(range.end, cap);
                if (beforeEnd) {
                  inExclude = true;
                  break;
                }
              }
              if (inExclude) continue;
            }
            // Update last seen WAL pointer for reconstruction of current.
            lastPartition = p;
            lastSeq = seq;

            final table = entry['table'] as String?;
            var data = (entry['data'] as Map?)?.cast<String, dynamic>();
            final opIdx = entry['op'] as int?;
            if (table == null || data == null || opIdx == null) continue;

            var resolvedTable = await _resolvePersistedTableField(table);

            // Skip WAL entries that are logically before a clear/drop cutoff
            // for this table.
            final cutoffs = await _tableCutoffsFor(tableCutoffs, resolvedTable);
            if (cutoffs != null && cutoffs.isNotEmpty) {
              final ptr = WalPointer(partitionIndex: p, entrySeq: seq);
              bool skip = false;
              for (final c in cutoffs) {
                if (_walManager.isAtOrBefore(ptr, c)) {
                  skip = true;
                  break;
                }
              }
              if (skip) {
                continue;
              }
            }
            final op = BufferOperationType.values[opIdx];

            final schema = await _resolveTableSchema(resolvedTable);
            if (schema == null) {
              Logger.warn(
                'WAL recovery: skipping entry for unresolved table field '
                '"$table"${resolvedTable.value != table ? ' (resolved: "${resolvedTable.value}")' : ''}',
              );
              continue;
            }
            final recordId = data[schema.primaryKey]?.toString();
            if (recordId == null) continue;

            // At this point, this WAL entry represents a real data change that
            // should be flushed to table files during normal batch processing.
            hasEffectiveEntry = true;

            // Track max primary key for sequential primary keys during recovery
            // WAL entries are processed in order, so the last insert is the maximum
            if (op == BufferOperationType.insert &&
                schema.primaryKeyConfig.type == PrimaryKeyType.sequential) {
              final pkValue = data[schema.primaryKey];
              if (pkValue != null) {
                // Get or create matcher for this table
                MatcherFunction? pkMatcher = pkMatchersByTable[resolvedTable];
                if (pkMatcher == null) {
                  pkMatcher = ValueMatcher.getMatcher(
                      schema.getPrimaryKeyMatcherType());
                  pkMatchersByTable[resolvedTable] = pkMatcher;
                }

                // Update max primary key for this table
                final currentMax = maxPkByTable[resolvedTable];
                if (currentMax == null || pkMatcher(pkValue, currentMax) > 0) {
                  maxPkByTable[resolvedTable] = pkValue;
                }
              }
            }

            final be = BufferEntry(
              data: data,
              operation: op,
              timestamp: DateTime.now(),
              transactionId: entry['txId'] as String?,
              oldValues: (entry['oldValues'] as Map?)?.cast<String, dynamic>(),
              schemaVersion: entry['schemaVersion'] as String? ?? '',
            );
            final walPtr = WalPointer(partitionIndex: p, entrySeq: seq);
            final uniqueRefs =
                await _computeUniqueKeyRefs(TableUid(resolvedTable), data);
            final tableContext = await _resolveTableContext(resolvedTable);
            if (tableContext == null) continue;
            await _bufferManager.addRecord(
              table: tableContext,
              recordId: recordId,
              entry: be.copyWith(walPointer: walPtr),
              uniqueKeys: uniqueRefs,
            );
          }
        } catch (_) {}

        if (p == endP) break;
        p = (p + 1) % cap;
        first = false;
        if (p == startP) break; // safety
      }

      // After replaying WAL, update WAL manager's in-memory current pointer.
      final WalPointer lastPtr =
          WalPointer(partitionIndex: lastPartition, entrySeq: lastSeq);
      _walManager.updateCurrentPointerAfterRecovery(lastPtr);

      // No effective entries to recover: delete all WAL partitions and reset meta
      // so next startup sees no WAL (existingStart/End = -1) and returns
      // immediately, avoiding repeated full WAL read and unbounded growth.
      if (!hasEffectiveEntry) {
        try {
          await _walManager.clearWalPartitionsAndResetMeta();
        } catch (_) {}
        return;
      } else {
        Logger.debug('Recovery added effective entries');
      }

      try {
        // Persist recovery hint using tail partition so tryFastPathSkipRecovery
        // can match next startup (lastRecoveredPointer.partitionIndex must equal
        // existingEndPartitionIndex; otherwise fast path never triggers).
        final ptrForMeta = (lastPartition == endP)
            ? lastPtr
            : WalPointer(partitionIndex: endP, entrySeq: 0);
        await _walManager.setLastRecoveredPointer(ptrForMeta);
      } catch (_) {}

      // After WAL recovery completes, update maxId for all tables that had inserts
      // We tracked the max primary key during recovery (WAL entries are processed in order,
      // so the last insert is the maximum).
      //
      // Strategy: First update memory and FileMeta with tracked WAL max to preserve it,
      // then call updateMaxIdFromTable to get the true maximum from all sources (partitions + buffer).
      // updateMaxIdFromTable will compare partition max, buffer max, and current memory value,
      // and take the maximum of all three, ensuring we have the correct global max.
      // Note: This happens after batch recovery, so it will include both batch and WAL data
      if (maxPkByTable.isNotEmpty) {
        try {
          for (final entry in maxPkByTable.entries) {
            final tableContext = await _resolveTableContext(entry.key);
            if (tableContext == null) continue;
            final maxPk = entry.value;
            // First, update memory and FileMeta with tracked WAL max to preserve it
            // This ensures the WAL max is saved even if buffer is cleared later
            await _dataStore.tableDataManager
                .updateMaxIdInMemory(tableContext, maxPk, updateFileMeta: true);
            // Then, call updateMaxIdFromTable to get the true maximum from all sources
            // It will compare: partition max, buffer max, and current memory value (which includes WAL max)
            // and update to the global maximum. Since we set forceRecalculate=true, it will
            // always recalculate even if cache matches, ensuring we get the true max from all sources.
            await _dataStore.tableDataManager
                .updateMaxIdFromTable(tableContext, forceRecalculate: true);
          }
        } catch (e) {
          Logger.error('Failed to update maxId after WAL recovery',
              rawError: e);
        }
      }
    } catch (e) {
      Logger.error('Recover from WAL failed', rawError: e);
    }
  }

  Future<
      ({
        List<_WalRange> excludeRanges,
        List<Future<void> Function()> flushTasks
      })> _reconcileWithParallelJournal() async {
    final excludeRanges = <_WalRange>[];
    final tasks = <Future<void> Function()>[];
    try {
      _isRecovering = true; // Mark as recovering
      final batches =
          List<PendingParallelBatch>.from(_walManager.meta.pendingBatches)
            ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

      for (final b in batches) {
        // Load phase: synchronously restore flush ops to buffer; defer flush.
        final task = await _recoverPendingBatch(b);
        if (task != null) {
          tasks.add(task);
          // Only exclude ranges for FLUSH batches that were actually loaded into buffer.
          // Maintenance batches do not load record data into buffer.
          if (b.batchType == BatchType.flush) {
            excludeRanges.add(_WalRange(b.start, b.end));
          }
        }
      }
      // Caller must run _executeRecoveryFlushChain AFTER _recoverFromWal.
    } catch (e) {
      Logger.error('Parallel journal reconcile failed', rawError: e);
      _isRecovering = false;
    }
    return (excludeRanges: excludeRanges, flushTasks: tasks);
  }

  Future<void> _executeRecoveryFlushChain(
      List<Future<void> Function()> tasks) async {
    if (tasks.isEmpty) {
      _isRecovering = false;
      return;
    }

    // Wrap the background chain into a managed Future
    final recoveryChainFuture = Future(() async {
      try {
        for (final task in tasks) {
          // Check running state before each recovery task
          if (!_running) break;
          try {
            await task();
          } catch (e) {
            Logger.error('Recovery flush task failed', rawError: e);
          }
        }
      } finally {
        _isRecovering = false;
        _loopFuture = null;

        // If data was added during recovery, trigger a normal flush
        if (_running && !_bufferManager.isEmpty) {
          scheduleFlushIfNeeded();
        }
      }
    });

    _loopFuture = recoveryChainFuture;
  }

  Future<void> _restoreTableBaseTotals(
      TableUid tableUid, BatchTablePlan? plan) async {
    if (plan == null ||
        plan.baseTotalRecords == null ||
        plan.baseTotalSizeInBytes == null) {
      return;
    }
    final tableContext = await _resolveTableContext(tableUid);
    if (tableContext == null) return;
    try {
      final meta = await _dataStore.tableDataManager
          .getTableDataMeta(tableContext.tableUid);
      if (meta == null) return;
      final updated = meta.copyWith(
        totalRecords: plan.baseTotalRecords!,
        totalSizeInBytes: plan.baseTotalSizeInBytes!,
        timestamps: Timestamps(
            created: meta.timestamps.created, modified: DateTime.now()),
      );
      await _dataStore.tableDataManager.updateTableDataMeta(
        tableContext,
        updated,
        flush: true,
      );
    } catch (e) {
      Logger.warn(
          'Failed to restore table ${tableContext.tableName} base totals',
          rawError: e);
    }
  }

  Future<void> _restoreIndexBaseTotals(
    TableUid tableUid,
    IndexUid indexUid,
    BatchTablePlan? plan,
  ) async {
    if (plan == null) return;
    final baseEntries = plan.baseIndexTotalEntries?[indexUid];
    final baseSize = plan.baseIndexTotalSizeInBytes?[indexUid];
    if (baseEntries == null || baseSize == null) return;
    final tableContext = await _resolveTableContext(tableUid);
    if (tableContext == null) return;
    try {
      final idxMeta =
          await _dataStore.indexManager?.getIndexMeta(tableUid, indexUid);
      if (idxMeta == null) return;
      final updated = idxMeta.copyWith(
        totalEntries: baseEntries,
        totalSizeInBytes: baseSize,
        timestamps: Timestamps(
            created: idxMeta.timestamps.created, modified: DateTime.now()),
      );
      await _dataStore.indexManager?.updateIndexMeta(
        table: tableContext,
        indexUid: idxMeta.indexUid,
        updatedMeta: updated,
        flush: true,
      );
    } catch (e) {
      Logger.warn('Failed to restore index $tableUid.$indexUid base totals',
          rawError: e);
    }
  }

  /// Resolve a persisted journal/WAL table field to a stable uid key.
  ///
  /// Fast path (common): normalize once; if already a live uid, return immediately.
  /// Slow path (legacy name + in-flight rename): apply pending renames, then normalize.
  Future<TableUid> _resolvePersistedTableField(String rawField) async {
    if (rawField.isEmpty) return TableUid.empty;
    final mgr = _dataStore.tableMetaManager;
    final normalized = await mgr?.normalizeTableFieldKey(rawField) ?? rawField;
    if (mgr != null && await mgr.isActiveTableUidKey(normalized)) {
      return TableUid(normalized);
    }
    final migMgr = _dataStore.migrationManager;
    if (migMgr == null) return TableUid(normalized);
    final pendingRenames = migMgr.getPendingTableRenames();
    if (pendingRenames.isEmpty) return TableUid(normalized);
    final renamed = pendingRenames[rawField] ?? pendingRenames[normalized];
    if (renamed == null) return TableUid(normalized);
    return TableUid(await mgr?.normalizeTableFieldKey(renamed) ?? renamed);
  }

  Future<TableContext?> _resolveTableContext(TableUid tableUid) async {
    if (tableUid.isEmpty) return null;
    final ctx = await _dataStore.tableMetaManager?.getTableContext(tableUid);
    if (ctx != null) return ctx;
    // Interrupted v3 may leave meta-row inserts in WAL before the self-row is
    // readable via getTableMeta; bootstrap context is enough to replay them.
    if (tableUid == SystemTable.tableMetaTableUid) {
      return _dataStore.tableMetaManager?.bootstrapTableMetaContext();
    }
    return null;
  }

  BatchTablePlan? _tablePlanFor(
      Map<TableUid, BatchTablePlan> plans, TableUid tableUid) {
    if (plans.isEmpty || tableUid.isEmpty) return null;
    return plans[tableUid];
  }

  Future<List<WalPointer>?> _tableCutoffsFor(
    Map<TableUid, List<WalPointer>> tableCutoffs,
    TableUid tableUid,
  ) async {
    final mgr = _dataStore.tableMetaManager;
    if (mgr == null) {
      return tableCutoffs[tableUid];
    }
    final normalized =
        TableUid(await mgr.normalizeTableFieldKey(tableUid.value));
    return tableCutoffs[normalized] ?? tableCutoffs[tableUid];
  }

  Future<TableSchema?> _resolveTableSchema(TableUid tableUid) async {
    final ctx = await _resolveTableContext(tableUid);
    if (ctx == null) return null;
    // Prefer [TableContext.schema] so bootstrap meta context works when the
    // self-row is not yet loadable via getTableMeta.
    if (ctx.schema.name.isNotEmpty) return ctx.schema;
    return _dataStore.tableMetaManager?.getTableSchema(ctx.tableUid);
  }

  Future<TableContext?> _tableContextFromUid(TableUid tableUid) async {
    return _dataStore.tableMetaManager?.getTableContext(tableUid);
  }

  /// Resolve stable [IndexUid] for redo replay (legacy logs may store logical names).
  IndexUid _resolveRedoIndexUid(TableSchema schema, IndexUid uidOrName) {
    if (uidOrName.isEmpty ||
        uidOrName.looksLikeStableUid ||
        uidOrName == IndexUid('pk')) {
      return uidOrName;
    }
    final resolved = _dataStore.tableMetaManager
        ?.resolveIndexUidFromField(schema, uidOrName.value);
    if (resolved != null && resolved.isNotEmpty) {
      return resolved;
    }
    return uidOrName;
  }

  Future<Future<void> Function()?> _recoverPendingBatch(
      PendingParallelBatch batch) async {
    try {
      await _replayPageRedoLogIfExists(batch.batchId);

      if (batch.batchType == BatchType.maintenance) {
        await _walManager.removePendingParallelBatch(batch.batchId);
        await _deletePageRedoLogIfExists(batch.batchId);
        try {
          await _flushRecoveryArtifactsIfNeeded();
        } catch (_) {}
        return null;
      }

      // Partition markers are per-file, not table-complete. Never skip whole-table
      // WAL replay based on partition 0 (or any single partition) matching:
      // unmarked sibling partitions must still be rewritten by writeChanges, which
      // already skips individual durable partition files via alreadyDurableForBatch.
      final plans = Map<TableUid, BatchTablePlan>.from(batch.tablePlans);

      final _BatchWalData walData = await _collectBatchWalChanges(batch);
      walData.tablePlans.addAll(plans);

      final tablesNeedingReplay = <TableUid>{
        ...walData.orderedOpsByTable.keys,
        ...plans.keys,
      };

      // Roll totals back to batch-start base so delta replay cannot double-count.
      // writeChanges then skips already-marked partitions and rewrites unmarked ones.
      await _repairUnflushedTablesAndIndexes(
        batchTables: tablesNeedingReplay,
        walData: walData,
      );

      final maxIds = <TableUid, int>{};
      int count = 0;
      for (final item in walData.orderedOpsInWalOrder) {
        final tableUid = item.table;
        final op = item.op;
        if (op.walPointer == null) continue;
        final tableContext = await _resolveTableContext(tableUid);
        if (tableContext == null) {
          Logger.warn(
            'Batch recovery: skipping WAL op for unresolved table "$tableUid"',
          );
          continue;
        }
        final schema = tableContext.schema;
        final pkName = schema.primaryKey;
        final pkValue = op.data[pkName]?.toString();
        if (pkValue == null) continue;

        final be = BufferEntry(
          data: op.data,
          operation: op.op,
          timestamp: DateTime.now(),
          oldValues: op.oldValues,
          walPointer: op.walPointer,
          schemaVersion: schema.schemaVersion ?? '',
        );

        final uniqueKeys =
            await _computeUniqueKeyRefs(tableContext.tableUid, op.data);

        await _dataStore.tableDataManager.recoverRecordToBuffer(
          tableContext,
          op.data,
          op.op,
          entry: be,
          uniqueKeyRefs: uniqueKeys,
          oldValues: op.oldValues,
          updateStats: true,
        );

        // Track maxId for batch update
        if (schema.primaryKeyConfig.type == PrimaryKeyType.sequential &&
            op.op == BufferOperationType.insert) {
          final id = int.tryParse(pkValue) ?? 0;
          final currentMax = maxIds[tableUid] ?? 0;
          if (id > currentMax) {
            maxIds[tableUid] = id;
          }
        }
        count++;
      }

      // Batch update maxId
      for (final tableUid in maxIds.keys) {
        final tableContext = await _resolveTableContext(tableUid);
        if (tableContext == null) continue;
        await _dataStore.tableDataManager.updateMaxIdInMemory(
            tableContext, maxIds[tableUid]!,
            updateFileMeta: false);
      }

      if (count == 0 && tablesNeedingReplay.isEmpty) {
        if (batch.end.partitionIndex >= 0) {
          await _walManager.advanceCheckpoint(batch.end);
        }
        await _walManager.removePendingParallelBatch(batch.batchId);
        await _deletePageRedoLogIfExists(batch.batchId);
        try {
          await _flushRecoveryArtifactsIfNeeded();
        } catch (_) {}
        return null;
      }

      final captureCount = count;
      final captureBatchId = batch.batchId;
      final captureBatchType = batch.batchType;

      return () async {
        if (!_running) return;
        _flushInProgress = true;
        try {
          await _replayPageRedoLogIfExists(captureBatchId);
          await _pumpFlush(
            drainCompletely: false,
            recoveryBatchContext: BatchContext(
              batchId: captureBatchId,
              batchType: captureBatchType,
            ),
            batchSizeOverride: captureCount > 0 ? captureCount : null,
          );
        } finally {
          _flushInProgress = false;
        }
      };
    } catch (e) {
      Logger.error('Recover pending batch failed', rawError: e);
      return null;
    } finally {
      _activeBatchContext = null;
    }
  }

  /// Restore base totals for every table/index in the pending batch so a
  /// subsequent reflush does not double-count. Partition markers only gate
  /// per-file IO inside writeChanges — never whole-tree skip here.
  Future<void> _repairUnflushedTablesAndIndexes({
    required Set<TableUid> batchTables,
    required _BatchWalData walData,
  }) async {
    try {
      for (final tableUid in batchTables) {
        final plan = _tablePlanFor(walData.tablePlans, tableUid);
        await _restoreTableBaseTotals(tableUid, plan);
      }

      for (final tableUid in batchTables) {
        final tableContext = await _resolveTableContext(tableUid);
        if (tableContext == null) continue;
        final schema = tableContext.schema;
        final btreeIndexes = <IndexSchema>[
          ...?_dataStore.tableMetaManager?.getBtreeIndexesFor(schema),
          ...?_dataStore.indexManager
              ?.getEngineManagedBtreeIndexes(tableContext, schema),
        ];
        if (btreeIndexes.isEmpty) continue;

        final plan = _tablePlanFor(walData.tablePlans, tableUid);
        if (plan == null) continue;

        for (final idx in btreeIndexes) {
          await _restoreIndexBaseTotals(tableUid, idx.indexUid, plan);
        }
      }
    } catch (e) {
      Logger.error('Failed to repair unflushed tables/indexes', rawError: e);
    }
  }

  bool _reachedWalEnd(int partitionIndex, int entrySeq, WalPointer end) {
    if (partitionIndex == end.partitionIndex && entrySeq > end.entrySeq) {
      return true;
    }
    return false;
  }

  Future<_BatchWalData> _collectBatchWalChanges(
      PendingParallelBatch batch) async {
    final Map<TableUid, List<Map<String, dynamic>>> inserts = {};
    final Map<TableUid, List<Map<String, dynamic>>> updates = {};
    final Map<TableUid, List<Map<String, dynamic>>> deletes = {};
    final Map<TableUid, List<_WalOp>> ordered = {};
    final List<({TableUid table, _WalOp op})> orderedOpsInWalOrder = [];

    try {
      // Precompute table-level WAL cutoff pointers from WAL meta (clear/drop ops)
      final Map<TableUid, List<WalPointer>> tableCutoffs =
          <TableUid, List<WalPointer>>{};
      try {
        for (final op in _walManager.tableOps.values) {
          final normalized = await _dataStore.tableMetaManager
                  ?.normalizeTableFieldKey(op.tableUid) ??
              op.tableUid;
          final tableUid = TableUid(normalized);
          tableCutoffs
              .putIfAbsent(tableUid, () => <WalPointer>[])
              .add(op.cutoff);
        }
      } catch (_) {}
      final startP = batch.start.partitionIndex;
      final endP = batch.end.partitionIndex;
      if (startP < 0 || endP < 0) {
        return _BatchWalData(
          insertsByTable: inserts,
          updatesByTable: updates,
          deletesByTable: deletes,
          orderedOpsByTable: ordered,
          orderedOpsInWalOrder: [],
        );
      }
      final cap = _dataStore.config.logPartitionCycle;
      final encoderConfig = EncryptionManager.getCurrentEncodingState();
      int p = startP;
      bool first = true;
      while (true) {
        final dirIndex = _walManager.getPartitionDirIndex(p);
        final path = dirIndex != null
            ? _dataStore.pathManager.getWalPartitionLogPath(dirIndex, p,
                spaceName: _dataStore.currentSpaceName)
            : _dataStore.pathManager.getWalPartitionLogPath(
                p ~/ _dataStore.maxEntriesPerDir, p,
                spaceName: _dataStore.currentSpaceName);
        int toSkip = 0;
        if (first) {
          toSkip = batch.start.entrySeq;
        }
        int seq = 0;
        try {
          // Check if file exists before reading to avoid PathNotFoundException
          final exists = await _dataStore.storage.existsFile(path);
          if (!exists) {
            // File doesn't exist, skip this partition (may be first startup or file was deleted)
            if (p == endP) break;
            p = (p + 1) % cap;
            first = false;
            if (p == startP) break;
            continue;
          }

          // Read WAL file as binary and decode using WalEncoder
          final fileBytes = await _dataStore.storage.readAsBytes(path);
          if (fileBytes.isEmpty) {
            if (p == endP) break;
            p = (p + 1) % cap;
            first = false;
            if (p == startP) break;
            continue;
          }

          // Decode all entries from file using length-prefix format
          // Pass partition index for AAD verification
          final entries = await WalDecodeBatchRunner.decodeFile(
            fileBytes: fileBytes,
            partitionIndex: p,
            encoderConfig: encoderConfig,
          );

          // Process each entry
          final yieldController =
              YieldController('ParallelJournalManager._collectBatchWalChanges');
          for (final entry in entries) {
            final y6 = yieldController.maybeYield();
            if (y6 != null) await y6;
            seq++;
            if (first && seq < toSkip) continue;

            final table = entry['table'] as String?;
            final data = (entry['data'] as Map?)?.cast<String, dynamic>();
            final oldValues =
                (entry['oldValues'] as Map?)?.cast<String, dynamic>();
            final opIdx = entry['op'] as int?;
            if (table == null || data == null || opIdx == null) continue;

            var resolvedTable = await _resolvePersistedTableField(table);

            // Skip WAL entries that are logically before a clear/drop cutoff
            // for this table.
            final cutoffs = await _tableCutoffsFor(tableCutoffs, resolvedTable);
            if (cutoffs != null && cutoffs.isNotEmpty) {
              final ptr = WalPointer(partitionIndex: p, entrySeq: seq);
              bool skip = false;
              for (final c in cutoffs) {
                if (_walManager.isAtOrBefore(ptr, c)) {
                  skip = true;
                  break;
                }
              }
              if (skip) {
                continue;
              }
            }
            if (_reachedWalEnd(p, seq, batch.end)) break;
            final op = BufferOperationType.values[opIdx];
            final walPtr = WalPointer(partitionIndex: p, entrySeq: seq);
            _WalOp walOp;
            switch (op) {
              case BufferOperationType.insert:
                (inserts.putIfAbsent(
                    resolvedTable, () => <Map<String, dynamic>>[])).add(data);
                walOp = _WalOp(op, data, walPointer: walPtr);
                (ordered.putIfAbsent(resolvedTable, () => <_WalOp>[]))
                    .add(walOp);
                orderedOpsInWalOrder.add((table: resolvedTable, op: walOp));
                break;
              case BufferOperationType.update:
                (updates.putIfAbsent(
                    resolvedTable, () => <Map<String, dynamic>>[])).add(data);
                walOp =
                    _WalOp(op, data, oldValues: oldValues, walPointer: walPtr);
                (ordered.putIfAbsent(resolvedTable, () => <_WalOp>[]))
                    .add(walOp);
                orderedOpsInWalOrder.add((table: resolvedTable, op: walOp));
                break;
              case BufferOperationType.delete:
                (deletes.putIfAbsent(
                    resolvedTable, () => <Map<String, dynamic>>[])).add(data);
                walOp = _WalOp(op, data, walPointer: walPtr);
                (ordered.putIfAbsent(resolvedTable, () => <_WalOp>[]))
                    .add(walOp);
                orderedOpsInWalOrder.add((table: resolvedTable, op: walOp));
                break;
              case BufferOperationType.rewrite:
                break;
            }
          }
        } catch (_) {}

        if (p == endP) break;
        p = (p + 1) % cap;
        first = false;
        if (p == startP) break;
      }
    } catch (e) {
      Logger.error('collect WAL for batch failed', rawError: e);
    }
    return _BatchWalData(
      insertsByTable: inserts,
      updatesByTable: updates,
      deletesByTable: deletes,
      orderedOpsByTable: ordered,
      orderedOpsInWalOrder: orderedOpsInWalOrder,
    );
  }

  /// Begin an ad-hoc batch for table maintenance so recovery can reconcile partial progress.
  Future<BatchContext> beginMaintenanceBatch(
      {required TableContext table}) async {
    if (!_dataStore.config.enableJournal) return BatchContext.maintenance('');
    final tableContext = table;
    if (tableContext.tableUid.isEmpty) return BatchContext.maintenance('');
    final batchId = GlobalIdGenerator.generate('maint_batch_');
    final batchContext = BatchContext.maintenance(batchId);

    final tableUid = table.tableUid;
    final schema = tableContext.schema;
    final tableDataMeta = await _dataStore.tableDataManager
        .getTableDataMeta(tableContext.tableUid);
    final indexUids = <IndexUid>[];
    final baseIndexTotalEntries = <IndexUid, int>{};
    final baseIndexTotalSizeInBytes = <IndexUid, int>{};
    try {
      final btreeIndexes = <IndexSchema>[
        ...?_dataStore.tableMetaManager?.getBtreeIndexesFor(schema),
        ...?_dataStore.indexManager
            ?.getEngineManagedBtreeIndexes(tableContext, schema),
      ];
      for (final idx in btreeIndexes) {
        indexUids.add(idx.indexUid);
        final idxMeta = await _dataStore.indexManager
            ?.getIndexMeta(tableContext.tableUid, idx.indexUid);
        if (idxMeta != null) {
          baseIndexTotalEntries[idx.indexUid] = idxMeta.totalEntries;
          baseIndexTotalSizeInBytes[idx.indexUid] = idxMeta.totalSizeInBytes;
        }
      }
    } catch (_) {}

    final tablePlans = <TableUid, BatchTablePlan>{
      tableUid: BatchTablePlan(
        willUpdateTableDataMeta: true,
        indexes: indexUids,
        willUpdateIndexMeta: indexUids.isNotEmpty,
        baseTotalRecords: tableDataMeta?.totalRecords,
        baseTotalSizeInBytes: tableDataMeta?.totalSizeInBytes,
        baseIndexTotalEntries: baseIndexTotalEntries,
        baseIndexTotalSizeInBytes: baseIndexTotalSizeInBytes,
      ),
    };

    try {
      await _walManager.addPendingParallelBatch(PendingParallelBatch(
        batchId: batchId,
        batchType: BatchType.maintenance,
        start: const WalPointer(partitionIndex: -1, entrySeq: -1),
        end: const WalPointer(partitionIndex: -1, entrySeq: -1),
        tablePlans: tablePlans,
        createdAt: DateTime.now().toIso8601String(),
      ));
    } catch (e) {
      Logger.error(
        'Failed to register pending maintenance batch',
        rawError: e,
      );
      // Do not expose an untracked batchId for redo/markers.
      return BatchContext.maintenance('');
    }
    _activeBatchContext = batchContext;
    return batchContext;
  }

  /// Complete the ad-hoc maintenance batch after durable page writes.
  Future<void> completeMaintenanceBatch({BatchContext? batchContext}) async {
    if (!_dataStore.config.enableJournal) return;
    try {
      String? batchId;
      if (batchContext != null) {
        batchId = batchContext.batchId;
      } else {
        final pending = _walManager.meta.pendingBatches
            .where((b) => b.batchType == BatchType.maintenance)
            .toList();
        final current = pending.isNotEmpty ? pending.last : null;
        batchId = current?.batchId;
      }

      if (batchId != null && batchId.isNotEmpty) {
        // Same ordering as flush batches: durable page data first, then drop
        // pending + redo so a crash cannot lose work without a recovery handle.
        try {
          await _dataStore.storage.flushAll();
        } catch (_) {}
        await _walManager.removePendingParallelBatch(batchId);
        await _deletePageRedoLogIfExists(batchId);
      }
      try {
        await _flushRecoveryArtifactsIfNeeded();
      } catch (_) {}
    } catch (e) {
      Logger.error('Failed to complete ad-hoc batch', rawError: e);
    }
    _activeBatchContext = null;
  }

  /// Run [action] under a batch id that is registered in WAL `pendingBatches`,
  /// so page redo can be discovered on crash recovery.
  ///
  /// Resolution order:
  /// 1. Explicit [batchContext] with non-empty id (caller owns batch lifecycle)
  /// 2. Open a short-lived maintenance batch via [beginMaintenanceBatch], then
  ///    [completeMaintenanceBatch] in `finally`
  ///
  /// Does **not** reuse [activeBatchContext] from an in-flight flush batch —
  /// ad-hoc page-0 writes must not share redo / recovery scope with unrelated
  /// flush work.
  ///
  /// Skips opening a new batch when journal is off, during recovery, or when
  /// [table] cannot be resolved — [action] still runs (`batchContext` may be
  /// null; caller should force `flush: true` for single page writes).
  ///
  /// [action] receives `(ctx, ownedBatch)`. When [ownedBatch] is true the
  /// page write must be flushed before this method completes (redo is deleted
  /// on complete).
  Future<T> runWithPageRedoBatch<T>({
    required TableContext table,
    BatchContext? batchContext,
    required Future<T> Function(BatchContext? ctx, {required bool ownedBatch})
        action,
  }) async {
    if (batchContext != null && batchContext.batchId.isNotEmpty) {
      return action(batchContext, ownedBatch: false);
    }
    if (!_dataStore.config.enableJournal ||
        _isRecovering ||
        table.tableUid.isEmpty) {
      return action(null, ownedBatch: false);
    }

    final owned = await beginMaintenanceBatch(table: table);
    if (owned.batchId.isEmpty) {
      return action(null, ownedBatch: false);
    }
    try {
      return await action(owned, ownedBatch: true);
    } finally {
      await completeMaintenanceBatch(batchContext: owned);
    }
  }

  /// Replay page redo log for [batchId] if it exists and has content.
  /// Writes each (path, offset, payload) from the log so recovery does not read
  /// possibly corrupted pages.
  ///
  /// Redo log contains **intended page images** (what the batch was about to write).
  /// Partition-0 page0 images include full tree-global meta (TMP1).
  /// Legacy [PageRedoTreeMetaRecord] (structure-only) is applied only when page0
  /// was absent from the same redo log.
  ///
  /// Consistency: for **flush**, metadata may be restored to "before batch"
  /// totals then [_pumpFlush] re-runs the batch. For **maintenance**, redo is
  /// the commit image — keep replayed pages as-is; do not roll totals back to
  /// base (there is no WAL reflush to rebuild them).
  Future<void> _replayPageRedoLogIfExists(String batchId) async {
    final redoPath = _dataStore.pathManager
        .getPageRedoLogPath(batchId, spaceName: _dataStore.currentSpaceName);
    if (!await _dataStore.storage.existsFile(redoPath)) return;
    final size = await _dataStore.storage.getFileSize(redoPath);
    if (size <= 0) return;
    final bytes = await _dataStore.storage.readAsBytes(redoPath);
    int pos = 0;
    // Deduplicate by logical identity with last-write-wins.
    // Reason: redo log may contain multiple attempts or duplicates for the same page.
    final byPartition = <({
      PageRedoTreeKind kind,
      TableUid tableUid,
      IndexUid indexUid,
      int partitionNo
    }),
        Map<int, Uint8List>>{};
    final treeMeta = <({
      PageRedoTreeKind kind,
      TableUid tableUid,
      IndexUid indexUid
    }),
        PageRedoTreeMetaRecord>{};
    const yieldInterval = 50;
    final parseYc = YieldController(
        'ParallelJournalManager._replayPageRedoLog.parse',
        checkInterval: yieldInterval);
    while (pos < bytes.length) {
      final y7 = parseYc.maybeYield();
      if (y7 != null) await y7;
      final rec = PageRedoLogCodec.decodeRecord(bytes, pos);
      if (rec == null) break;
      pos = rec.nextStart;
      if (rec is PageRedoPageRecord) {
        final key = (
          kind: rec.treeKind,
          tableUid: rec.tableUid,
          indexUid: rec.indexUid ?? IndexUid.empty,
          partitionNo: rec.partitionNo,
        );
        byPartition.putIfAbsent(key, () => <int, Uint8List>{})[rec.pageNo] =
            rec.payload;
      } else if (rec is PageRedoTreeMetaRecord) {
        final key = (
          kind: rec.treeKind,
          tableUid: rec.tableUid,
          indexUid: rec.indexUid ?? IndexUid.empty,
        );
        treeMeta[key] = rec;
      }
    }
    final writeYc = YieldController(
        'ParallelJournalManager._replayPageRedoLog.write',
        checkInterval: 5);
    for (final e in byPartition.entries) {
      final y8 = writeYc.maybeYield();
      if (y8 != null) await y8;
      final key = e.key;
      final pages = e.value;
      if (pages.isEmpty) continue;
      if ((key.kind == PageRedoTreeKind.indexTree ||
              key.kind == PageRedoTreeKind.ngh) &&
          key.indexUid.isEmpty) {
        continue;
      }

      String path;
      try {
        if (key.kind == PageRedoTreeKind.table) {
          path = await _dataStore.pathManager
              .getPartitionFilePathByNo(key.tableUid, key.partitionNo);
        } else if (key.kind == PageRedoTreeKind.ngh) {
          final tableContext = await _tableContextFromUid(key.tableUid);
          if (tableContext == null) continue;
          final indexUid =
              _resolveRedoIndexUid(tableContext.schema, key.indexUid);
          path = await _dataStore.pathManager.getNghGraphPartitionPath(
              key.tableUid, indexUid, key.partitionNo);
        } else {
          final tableContext = await _tableContextFromUid(key.tableUid);
          if (tableContext == null) continue;
          final indexUid =
              _resolveRedoIndexUid(tableContext.schema, key.indexUid);
          path = await _dataStore.pathManager.getIndexPartitionPathByNo(
              key.tableUid, indexUid, key.partitionNo);
        }
      } catch (_) {
        continue;
      }

      // Ensure directory exists before writing.
      try {
        await _dataStore.storage.ensureDirectoryExists(p.dirname(path));
      } catch (_) {}

      // Use a consistent pageSize for this partition; skip inconsistent payloads.
      int pageSize = 0;
      for (final v in pages.values) {
        if (v.isNotEmpty) {
          pageSize = v.length;
          break;
        }
      }
      if (pageSize <= 0) continue;

      final pageNos = pages.keys.toList(growable: false)..sort();
      final writes = <ByteWrite>[];
      for (final pg in pageNos) {
        if (pg < 0) continue;
        final payload = pages[pg];
        if (payload == null || payload.isEmpty) continue;
        if (payload.length != pageSize) continue;
        final off = pg * pageSize;
        writes.add(ByteWrite(offset: off, bytes: payload));
      }
      if (writes.isEmpty) continue;
      writes.sort((a, b) => a.offset.compareTo(b.offset));
      await _dataStore.storage.writeManyAsBytesAt(path, writes, flush: true);

      // Partition-0 page0 carries global TableDataMeta / IndexMeta / NghIndexMeta.
      // Invalidate meta caches so later recovery reads the restored page0, not
      // a pre-crash in-memory snapshot.
      if (key.partitionNo == 0 && pages.containsKey(0)) {
        final tableContext = await _tableContextFromUid(key.tableUid);
        if (tableContext != null) {
          if (key.kind == PageRedoTreeKind.table) {
            _dataStore.tableDataManager
                .invalidateTableDataMetaCacheForTable(tableContext);
          } else if (key.kind == PageRedoTreeKind.indexTree) {
            final indexUid =
                _resolveRedoIndexUid(tableContext.schema, key.indexUid);
            _dataStore.indexManager
                ?.invalidateIndexMetaCache(key.tableUid, indexUid);
          } else if (key.kind == PageRedoTreeKind.ngh) {
            final indexUid =
                _resolveRedoIndexUid(tableContext.schema, key.indexUid);
            _dataStore.vectorIndexManager
                ?.clearCacheForIndex(key.tableUid, indexUid);
          }
        }
      }
    }

    // Legacy TreeMetaRecord: only apply when partition-0 page0 was NOT restored
    // in this redo (old logs before global meta lived in page0). New write path
    // embeds full meta in page0 images — applying TreeMetaRecord after p0 would
    // overwrite restored totals with a stale cache RMW.
    if (treeMeta.isNotEmpty) {
      final metaYc = YieldController(
        'ParallelJournalManager._replayPageRedoLog.meta',
        checkInterval: 5,
      );
      for (final rec in treeMeta.values) {
        final y9 = metaYc.maybeYield();
        if (y9 != null) await y9;
        try {
          final tableContext =
              await _tableContextFromUid(TableUid(rec.tableUid));
          if (tableContext == null) continue;

          final p0Key = (
            kind: rec.treeKind,
            tableUid: rec.tableUid,
            indexUid: rec.indexUid ?? IndexUid.empty,
            partitionNo: 0,
          );
          final p0Restored = byPartition[p0Key]?.containsKey(0) == true;
          if (p0Restored) {
            continue;
          }

          if (rec.treeKind == PageRedoTreeKind.table) {
            final meta = await _dataStore.tableDataManager
                .getTableDataMeta(tableContext.tableUid);
            if (meta == null) continue;
            final updated = meta.copyWith(
              btreeNextPageNo: rec.btreeNextPageNo,
              btreePartitionCount: rec.btreePartitionCount,
              btreeRoot:
                  TreePagePtr(rec.btreeRootPartitionNo, rec.btreeRootPageNo),
              btreeFirstLeaf: TreePagePtr(
                  rec.btreeFirstLeafPartitionNo, rec.btreeFirstLeafPageNo),
              btreeLastLeaf: TreePagePtr(
                  rec.btreeLastLeafPartitionNo, rec.btreeLastLeafPageNo),
              btreeHeight: rec.btreeHeight,
              timestamps: Timestamps(
                created: meta.timestamps.created,
                modified: DateTime.now(),
              ),
            );
            await _dataStore.tableDataManager
                .updateTableDataMeta(tableContext, updated, flush: true);
          } else if (rec.treeKind == PageRedoTreeKind.indexTree) {
            final idxUid = rec.indexUid;
            if (idxUid == null || idxUid.isEmpty) continue;
            final resolved = _resolveRedoIndexUid(tableContext.schema, idxUid);
            final meta = await _dataStore.indexManager
                ?.getIndexMeta(tableContext.tableUid, resolved);
            if (meta == null) continue;
            final updated = meta.copyWith(
              btreeNextPageNo: rec.btreeNextPageNo,
              btreePartitionCount: rec.btreePartitionCount,
              btreeRoot:
                  TreePagePtr(rec.btreeRootPartitionNo, rec.btreeRootPageNo),
              btreeFirstLeaf: TreePagePtr(
                  rec.btreeFirstLeafPartitionNo, rec.btreeFirstLeafPageNo),
              btreeLastLeaf: TreePagePtr(
                  rec.btreeLastLeafPartitionNo, rec.btreeLastLeafPageNo),
              btreeHeight: rec.btreeHeight,
              timestamps: Timestamps(
                created: meta.timestamps.created,
                modified: DateTime.now(),
              ),
            );
            await _dataStore.indexManager?.updateIndexMeta(
              table: tableContext,
              indexUid: resolved,
              updatedMeta: updated,
              flush: true,
            );
          }
          // NGH: global meta is only in page-0 images (never TreeMetaRecord).
        } catch (_) {}
      }
    }
  }

  /// Delete page redo log for [batchId] if it exists (after batch is fully flushed, before checkpoint).
  Future<void> _deletePageRedoLogIfExists(String batchId) async {
    try {
      final redoPath = _dataStore.pathManager
          .getPageRedoLogPath(batchId, spaceName: _dataStore.currentSpaceName);
      if (await _dataStore.storage.existsFile(redoPath)) {
        await _dataStore.storage.deleteFile(redoPath);
      }
    } catch (_) {}
  }

  Future<void> _flushRecoveryArtifactsIfNeeded() async {
    if (!_dataStore.config.persistRecoveryOnCommit) return;
    try {
      final walIdx = _walManager.currentPointer.partitionIndex;
      final walDirIndex = _walManager.getPartitionDirIndex(walIdx);
      final walPath = walDirIndex != null
          ? _dataStore.pathManager.getWalPartitionLogPath(walDirIndex, walIdx,
              spaceName: _dataStore.currentSpaceName)
          : _dataStore.pathManager.getWalPartitionLogPath(
              walIdx ~/ _dataStore.maxEntriesPerDir, walIdx,
              spaceName: _dataStore.currentSpaceName);
      final walMetaPath = _dataStore.pathManager
          .getWalMainMetaPath(spaceName: _dataStore.currentSpaceName);
      try {
        await _dataStore.storage.flushAll(path: walPath);
      } catch (_) {}
      try {
        await _dataStore.storage.flushAll(path: walMetaPath);
      } catch (_) {}
    } catch (_) {}
  }

  Future<List<UniqueKeyRef>> _computeUniqueKeyRefs(
      TableUid tableUid, Map<String, dynamic> data) async {
    final refs = <UniqueKeyRef>[];
    try {
      final schema =
          await _dataStore.tableMetaManager?.getTableSchema(tableUid);
      if (schema == null) return refs;

      // Unique indexes from schema (implicit/explicit)
      final allIndexes =
          _dataStore.tableMetaManager?.getUniqueIndexesFor(schema) ??
              <IndexSchema>[];
      for (final idx in allIndexes) {
        // Skip primary key check usually not needed if getAllIndexes doesn't include it or if we handle it
        if (idx.fields.length == 1 && idx.fields.first == schema.primaryKey) {
          continue;
        }
        final ck = schema.createCanonicalIndexKey(idx.fields, data);
        if (ck == null) continue;
        refs.add(UniqueKeyRef(idx.indexUid, ck));
      }
    } catch (_) {}
    return refs;
  }
}

class _BatchWalData {
  final Map<TableUid, List<Map<String, dynamic>>> insertsByTable;
  final Map<TableUid, List<Map<String, dynamic>>> updatesByTable;
  final Map<TableUid, List<Map<String, dynamic>>> deletesByTable;
  final Map<TableUid, List<_WalOp>> orderedOpsByTable;

  /// Same ops in exact WAL (partition+seq) order so recovery push order
  /// matches normal flush pop order and pop(captureCount) yields this batch.
  final List<({TableUid table, _WalOp op})> orderedOpsInWalOrder;
  final Map<TableUid, BatchTablePlan> tablePlans = {};

  _BatchWalData({
    required this.insertsByTable,
    required this.updatesByTable,
    required this.deletesByTable,
    required this.orderedOpsByTable,
    required this.orderedOpsInWalOrder,
  });
}

class _WalOp {
  final BufferOperationType op;
  final Map<String, dynamic> data;
  final Map<String, dynamic>? oldValues;
  final WalPointer? walPointer;
  _WalOp(this.op, this.data, {this.oldValues, this.walPointer});
}

class _WalRange {
  final WalPointer start;
  final WalPointer end;
  _WalRange(this.start, this.end);
}
