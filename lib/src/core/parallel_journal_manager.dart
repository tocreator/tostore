import 'dart:async';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../handler/encryption.dart';
import '../handler/logger.dart';
import '../handler/platform_handler.dart';
import '../handler/value_matcher.dart';
import '../interface/storage_interface.dart';
import '../model/background_write_entry.dart';
import '../model/background_write_type.dart';
import '../model/buffer_entry.dart';
import '../model/data_store_config.dart';
import '../model/db_exception.dart';
import '../model/encoder_config.dart';
import '../model/flush_pressure_state.dart';
import '../model/id_generator.dart';
import '../model/index_entry.dart';
import '../model/meta_info.dart';
import '../model/migration_write_mode.dart';
import '../model/parallel_journal_entry.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/space_stats.dart';
import '../model/system_table.dart';
import '../model/table_context.dart';
import '../model/table_identity.dart';
import '../model/table_schema.dart';
import '../model/wal_pointer.dart';
import 'compute/wal_decode_batch_runner.dart';
import 'cpu_work_chunk.dart';
import 'data_store_impl.dart';
import 'migration_manager.dart';
import 'page_redo_log_codec.dart';
import 'resource_manager.dart';
import 'storage_adapter.dart';
import 'wal_manager.dart';
import 'write_buffer_manager.dart';
import 'yield_controller.dart';

class ParallelJournalManager {
  final DataStoreImpl _dataStore;
  final WalManager _walManager;
  final WriteBufferManager _bufferManager;

  bool _running = false;
  Future<void>? _loopFuture;
  StreamSubscription<int>? _bufSizeSub;
  bool _flushInProgress = false;

  /// When true, online pump [whenComplete] must not chain another
  /// [scheduleFlushIfNeeded] (owned by [flushCompletely] / stop drain).
  bool _suppressOnlineReschedule = false;
  BatchContext? _activeBatchContext;
  bool _isRecovering = false; // Flag to indicate if currently in recovery mode

  /// Short-lived partition decode cache shared by batch reconcile + WAL replay
  /// during [start], so the same partition is not decrypted twice.
  Map<int, List<Map<String, dynamic>>>? _startupWalDecodeCache;

  /// Per-startup caches for table field / context / cutoff resolution.
  Map<String, TableUid>? _recoveryFieldCache;
  Map<TableUid, TableContext?>? _recoveryContextCache;
  Map<TableUid, List<WalPointer>?>? _recoveryCutoffCache;

  /// Number of records currently popped from queue and being actively flushed to disk.
  int _inFlightFlushCount = 0;

  /// Count of active large batch operations (e.g. batchInsert/batchUpsert/batchUpdate).
  int _activeBatchOperationCount = 0;

  /// Sampled average total bytes per record (table data + all indexes).
  int _averageRecordSizeBytes = 200;

  /// Timestamp (ms) when [_averageRecordSizeBytes] was last persisted to GlobalConfig.
  int _lastAverageRecordSavedAtMs = 0;

  /// Waiters suspended during [FlushPressureState.busy] waiting for flush release.
  final List<Completer<void>> _busyWaiters = <Completer<void>>[];

  /// True while a flush pump turn is executing (after queue pop, before turn ends).
  bool get isFlushInProgress => _flushInProgress;

  /// Current number of records in-flight being written to disk.
  int get inFlightFlushCount => _inFlightFlushCount;

  /// Current number of active batch client operations.
  int get activeBatchOperationCount => _activeBatchOperationCount;

  /// Register the start of an active batch operation.
  void beginBatchOperation() {
    _activeBatchOperationCount++;
  }

  /// Unregister an active batch operation.
  void endBatchOperation() {
    if (_activeBatchOperationCount > 0) {
      _activeBatchOperationCount--;
    }
  }

  // When set (close / switchSpace / flushCompletely), skip online tail-fill
  // delays and wake any in-flight wait so drain can proceed immediately.
  bool _immediateFlushRequested = false;
  Completer<void>? _tailWaitWake;

  /// Target flush batch bytes per platform.
  static int _getTargetFlushBatchBytes() {
    if (PlatformHandler.isWeb) {
      return 1 * 1024 * 1024; // 1MB
    } else if (PlatformHandler.isMobile) {
      return 30 * 1024 * 1024; // 30MB
    } else if (PlatformHandler.isServerEnvironment) {
      return 80 * 1024 * 1024; // 80MB
    } else {
      return 30 * 1024 * 1024; // Desktop: 30MB
    }
  }

  /// Dynamically calculated writeBatchSize based on target bytes and average record size.
  int get effectiveWriteBatchSize {
    final int targetBytes = _getTargetFlushBatchBytes();
    final int avgBytes =
        _averageRecordSizeBytes > 0 ? _averageRecordSizeBytes : 200;
    final int calculated = targetBytes ~/ avgBytes;
    if (PlatformHandler.isWeb) {
      return calculated.clamp(500, 10000);
    } else if (PlatformHandler.isMobile) {
      return calculated.clamp(50000, 200000);
    } else if (PlatformHandler.isServerEnvironment) {
      return calculated.clamp(50000, 500000);
    } else {
      return calculated.clamp(50000, 200000);
    }
  }

  /// Total records pending persistence: queued in buffer + actively in-flight flushing.
  int get totalPending => _bufferManager.queueLength + _inFlightFlushCount;

  /// Flush busy threshold calculated from 30% of ResourceManager memory threshold.
  /// Clamped between 3x and 10x [effectiveWriteBatchSize].
  int get busyThreshold {
    final rm = _dataStore.resourceManager;
    final int memoryThresholdMB = rm != null ? rm.memoryThresholdInMB : 256;
    final int avgBytes =
        _averageRecordSizeBytes > 0 ? _averageRecordSizeBytes : 200;
    final int availableBytes = (memoryThresholdMB * 0.30 * 1024 * 1024).toInt();
    final int maxPendingByMemory = availableBytes ~/ avgBytes;
    final int currentBatchSize = effectiveWriteBatchSize;
    return maxPendingByMemory.clamp(
        currentBatchSize * 3, currentBatchSize * 10);
  }

  /// Current flush pressure state.
  FlushPressureState get pressureState {
    final pending = totalPending;
    if (pending == 0) return FlushPressureState.idle;
    if (pending <= busyThreshold) return FlushPressureState.normal;
    return FlushPressureState.busy;
  }

  /// Notify suspended busy waiters when a flush batch finishes.
  void _notifyBusyWaiters() {
    if (_busyWaiters.isEmpty) return;
    final waiters = List<Completer<void>>.from(_busyWaiters);
    _busyWaiters.clear();
    for (final w in waiters) {
      if (!w.isCompleted) {
        w.complete();
      }
    }
  }

  /// Suspend caller until total pending drops below [busyThreshold] or timeout.
  Future<void> _waitUntilPressureRelieved({
    Duration timeout = const Duration(seconds: 120),
  }) async {
    if (pressureState != FlushPressureState.busy) return;
    final deadline = DateTime.now().add(timeout);

    while (_running && pressureState == FlushPressureState.busy) {
      if (DateTime.now().isAfter(deadline)) break;
      final c = Completer<void>();
      _busyWaiters.add(c);
      try {
        await Future.any<void>([
          Future<void>.delayed(const Duration(milliseconds: 50)),
          c.future,
        ]);
      } finally {
        _busyWaiters.remove(c);
      }
    }
  }

  /// Update running average record size using an authoritative sample from table persistence delta.
  void recordFlushRecordSizeSample(int sampleBytes) {
    if (sampleBytes <= 0) return;
    final clamped = sampleBytes.clamp(32, 100 * 1024 * 1024);
    _averageRecordSizeBytes =
        ((_averageRecordSizeBytes * 0.7) + (clamped * 0.3)).round();

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    const int oneDayMs = 24 * 60 * 60 * 1000;
    if (nowMs - _lastAverageRecordSavedAtMs > oneDayMs) {
      _lastAverageRecordSavedAtMs = nowMs;
      unawaited(_saveAverageRecordSizeToGlobalConfig());
    }
  }

  /// Asynchronously persist updated average record size to GlobalConfig (at most once per 24 hours).
  Future<void> _saveAverageRecordSizeToGlobalConfig() async {
    try {
      final currentCfg = await _dataStore.getGlobalConfig();
      if (currentCfg != null) {
        final updated = currentCfg.copyWith(
          averageRecordSizeBytes: _averageRecordSizeBytes,
          lastAverageRecordSavedAtMs: _lastAverageRecordSavedAtMs,
        );
        await _dataStore.saveGlobalConfig(updated);
      }
    } catch (e) {
      Logger.debug(
          'Failed to persist averageRecordSizeBytes to GlobalConfig: $e');
    }
  }

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

  /// First real (non-pseudo) WAL pointer in queue order (O(1)).
  ///
  /// The write queue is FIFO and WAL pointers are assigned monotonically on
  /// enqueue, so the first/last real pointers bound the batch's WAL span
  /// without scanning the whole batch.
  static WalPointer? _firstRealWalPointer(List<WriteQueueEntry> batch) {
    for (final e in batch) {
      if (e.walPointer.partitionIndex >= 0) return e.walPointer;
    }
    return null;
  }

  /// Last real (non-pseudo) WAL pointer in queue order (O(1)).
  static WalPointer? _lastRealWalPointer(List<WriteQueueEntry> batch) {
    for (var i = batch.length - 1; i >= 0; i--) {
      if (batch[i].walPointer.partitionIndex >= 0) {
        return batch[i].walPointer;
      }
    }
    return null;
  }

  /// Later of two real WAL pointers on the partition ring.
  static WalPointer _laterWalPointer(WalPointer a, WalPointer b, int cycle) {
    if (a.partitionIndex < 0) return b;
    if (b.partitionIndex < 0) return a;
    if (cycle <= 0) return a;
    return b.isNewerThan(a, cycle) ? b : a;
  }

  /// Scan start for generic WAL replay: durable checkpoint, or the recovered
  /// flush batch's [PendingParallelBatch.end] when that is further ahead.
  ///
  /// The temporary pointer is never written to [WalMeta.checkpoint].
  static WalPointer _replayStartCheckpoint(
    WalPointer durable,
    WalPointer? recoveredFlushEnd,
    int cycle,
  ) {
    if (recoveredFlushEnd == null || recoveredFlushEnd.partitionIndex < 0) {
      return durable;
    }
    if (durable.partitionIndex < 0) return recoveredFlushEnd;
    return _laterWalPointer(durable, recoveredFlushEnd, cycle);
  }

  /// Enqueue-path backpressure for [WriteBufferManager].
  ///
  /// Returns `null` on the hot path (normal pressure state / healthy system memory).
  /// Returns a [Future] only when flush is busy or hard resource wait is needed.
  Future<void>? applyEnqueueBackpressure([int count = 1]) {
    // Fast-path: When pressure is normal or idle and memory status is healthy,
    // execute pure-sync zero await to guarantee maximum throughput.
    if (pressureState != FlushPressureState.busy) {
      final rm = _dataStore.resourceManager;
      if (rm == null || rm.memoryStatus == ResourceStatus.normal) {
        return null;
      }
    }
    if (_dataStore.config.persistenceMode == PersistenceMode.memory) {
      return null;
    }
    if (_isRecovering) return null;
    return _applyEnqueueBackpressureSlow(count);
  }

  Future<void> _applyEnqueueBackpressureSlow(int count) async {
    final rm = _dataStore.resourceManager;
    if (rm != null) {
      if (pressureState == FlushPressureState.busy ||
          rm.memoryStatus != ResourceStatus.normal) {
        await rm.triggerImmediateCheck();
      }

      if (rm.isWriteBlocked) {
        throw DbException([
          GeneralStatus(
            type: ResultType.sysResourceExhaustedMemory,
            message:
                'Write buffer enqueue blocked: system memory is critically low.',
            operation: 'applyEnqueueBackpressure',
          ),
        ]);
      }

      if (rm.memoryStatus == ResourceStatus.warning) {
        scheduleFlushIfNeeded();
        final wake = _tailWaitWake;
        if (wake != null && !wake.isCompleted) {
          wake.complete();
        }
      }
    }

    if (pressureState == FlushPressureState.busy) {
      scheduleFlushIfNeeded();
      final wake = _tailWaitWake;
      if (wake != null && !wake.isCompleted) {
        wake.complete();
      }
      await _waitUntilPressureRelieved(timeout: const Duration(seconds: 60));
    }
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;

    // Load initial average record size from persisted GlobalConfig to avoid SpaceStats cold IO.
    try {
      final globalCfg = await _dataStore.getGlobalConfig();
      if (globalCfg != null && globalCfg.averageRecordSizeBytes > 0) {
        _averageRecordSizeBytes = globalCfg.averageRecordSizeBytes;
        _lastAverageRecordSavedAtMs = globalCfg.lastAverageRecordSavedAtMs;
      }
    } catch (_) {}

    // Reconcile incomplete pending batches: load flush WAL into buffer first;
    // do not start recovery flush until _recoverFromWal finishes, so the
    // recovery pump cannot interleave with unrelated WAL-replayed queue entries.
    // A loaded flush batch returns its end as a temporary replay checkpoint so
    // generic WAL replay starts after that span (durable checkpoint is unchanged).
    WalPointer? replayCheckpoint;
    List<Future<void> Function()> recoveryFlushTasks = const [];
    _startupWalDecodeCache = <int, List<Map<String, dynamic>>>{};
    _recoveryFieldCache = <String, TableUid>{};
    _recoveryContextCache = <TableUid, TableContext?>{};
    _recoveryCutoffCache = <TableUid, List<WalPointer>?>{};
    try {
      if (_walManager.hasPendingParallelBatches) {
        final reconciled = await _reconcileWithParallelJournal();
        replayCheckpoint = reconciled.replayCheckpoint;
        recoveryFlushTasks = reconciled.flushTasks;
      }
      // Then recover remaining WAL entries into in-memory buffer/queue
      await _recoverFromWal(replayCheckpoint: replayCheckpoint);

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
    } finally {
      _startupWalDecodeCache = null;
      _recoveryFieldCache = null;
      _recoveryContextCache = null;
      _recoveryCutoffCache = null;
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

  /// Flush all pending write buffers to disk without shutting down the journal.
  ///
  /// Used in maintenance flows (backup checkpoint, migration, "save all") where
  /// a durability point is required but the DB keeps accepting writes.
  Future<void> flushCompletely() async {
    if (!_running) return;

    // Wake any in-flight online tail wait before awaiting that pump.
    _requestImmediateFlush();
    // Block lost-wakeup chaining while we take exclusive drain ownership.
    _suppressOnlineReschedule = true;

    try {
      // Drain must not silently no-op while recovery holds the flush gate.
      if (_isRecovering) {
        await waitUntilRecoveryCompleted();
        if (!_running) {
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
      }
    } finally {
      _suppressOnlineReschedule = false;
      _clearImmediateFlushRequest();
      // Writes may have arrived while suppress blocked online chaining.
      if (_running &&
          (!_bufferManager.isEmpty ||
              !_dataStore.backgroundWriteScheduler.isEmpty)) {
        scheduleFlushIfNeeded();
      }
    }
  }

  /// Quiesce the flush pump before [TableDataManager.clearTable] acquires the
  /// table write lock.
  ///
  /// Batch planning reads partition-0 meta under shared storage path locks
  /// without holding the table write lock. If clear holds the table lock and
  /// writes p0.dat while planning still reads the same path, both sides block
  /// until lock timeout (~5 min).
  ///
  /// Must NOT be called while the target table write lock is already held.
  Future<void> prepareForTableClear(TableContext table) async {
    if (!_running) return;
    await _awaitActivePump();
    try {
      if (!_bufferManager.isEmpty ||
          !_dataStore.backgroundWriteScheduler.isEmpty ||
          _inFlightFlushCount > 0) {
        await flushCompletely();
      }
    } catch (_) {}
    await _awaitActivePump();
  }

  Future<void> _awaitActivePump() async {
    final fut = _loopFuture;
    if (fut != null) {
      try {
        await fut;
      } catch (_) {}
    }
  }

  /// Shut down the journal manager.
  ///
  /// - [flush] `true`: drain pending writes to disk, then stop (close / switchSpace
  ///   when persisting). Does **not** clear pending/txn trees -- flush reads them.
  /// - [flush] `false`: stop without draining and [WriteBufferManager.clearAll]
  ///   (discard unpersisted state, e.g. backup/restore).
  Future<void> stop({bool flush = true}) async {
    if (flush) {
      await _stopAfterFlush();
    } else {
      await _stopDiscardingBuffers();
    }
  }

  Future<void> _stopAfterFlush() async {
    if (!_running && _bufferManager.isEmpty) {
      return;
    }

    _requestImmediateFlush();
    _suppressOnlineReschedule = true;

    try {
      _running = true;
      try {
        await _bufSizeSub?.cancel();
      } catch (_) {}
      _bufSizeSub = null;

      if (_isRecovering) {
        await waitUntilRecoveryCompleted();
      }

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
      _suppressOnlineReschedule = false;
      _loopFuture = null;
      _flushInProgress = false;
      _activeBatchContext = null;
      _isRecovering = false;
      _inFlightFlushCount = 0;
      _notifyBusyWaiters();
      _clearImmediateFlushRequest();
    }
  }

  Future<void> _stopDiscardingBuffers() async {
    if (!_running && _bufferManager.isEmpty) {
      try {
        await _bufSizeSub?.cancel();
      } catch (_) {}
      _bufSizeSub = null;
      _loopFuture = null;
      _flushInProgress = false;
      _activeBatchContext = null;
      _inFlightFlushCount = 0;
      _notifyBusyWaiters();
      _bufferManager.clearAll();
      return;
    }

    // Wake tail wait so stop is not blocked by maxFlushLatencyMs windows.
    _requestImmediateFlush();

    try {
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
      _inFlightFlushCount = 0;
      _notifyBusyWaiters();
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
      // Only the pump that still owns [_loopFuture] may clear the gate.
      // [flushCompletely] / stop may have replaced it with a drain pump.
      if (!identical(_loopFuture, fut)) {
        return;
      }
      _loopFuture = null;
      _flushInProgress = false;

      // Lost-wakeup cover: entries (or requeued work after break) may have
      // arrived while [_flushInProgress] caused scheduleFlushIfNeeded to
      // no-op, and the pump then exited without another sizeStream event.
      if (_suppressOnlineReschedule) return;
      if (!_running || _isRecovering) return;
      if (!_bufferManager.isEmpty ||
          !_dataStore.backgroundWriteScheduler.isEmpty) {
        scheduleFlushIfNeeded();
      }
    });
  }

  /// Tail-wait strategy for normal online flush:
  ///
  /// Intelligently yields to active batch operations and continuously growing writes.
  Future<void> _waitTailFillWhileGrowing({
    required int targetSize,
  }) async {
    if (_immediateFlushRequested) return;

    while (_running) {
      if (_immediateFlushRequested) return;
      final before = _bufferManager.queueLength;
      if (before <= 0 && _inFlightFlushCount <= 0) return;

      // If pressure is already busy, flush immediately to relieve backpressure.
      if (pressureState == FlushPressureState.busy) return;

      final wake = Completer<void>();
      _tailWaitWake = wake;
      try {
        await Future.any<void>([
          Future<void>.delayed(const Duration(milliseconds: 1000)),
          wake.future,
        ]);
      } finally {
        if (identical(_tailWaitWake, wake)) {
          _tailWaitWake = null;
        }
      }
      if (_immediateFlushRequested) return;

      final after = _bufferManager.queueLength;
      // If busy threshold reached, trigger flush now.
      if (pressureState == FlushPressureState.busy) return;

      // If active batch operations are in-flight and state is normal, yield and keep waiting.
      if (_activeBatchOperationCount > 0) {
        continue;
      }

      // When writes stabilize (data did not grow in 1s window), flush immediately!
      if (after <= before) {
        return;
      }
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
    // Drain mode (close / migration durability) must not silently no-op -- wait for recovery
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

    final batchSize = batchSizeOverride ?? effectiveWriteBatchSize;
    bool firstIteration = true;

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
        // Recovery reflush must pop the restored batch as-is. Waiting for a
        // "full" online batch can merge live inserts after open() returns
        // (start() does not await the recovery chain).
        if (!drainCompletely &&
            !_immediateFlushRequested &&
            recoveryBatchContext == null) {
          final currentSize = _bufferManager.queueLength;
          if (currentSize < batchSize) {
            await _waitTailFillWhileGrowing(
              targetSize: batchSize,
            );
          }
        }

        // stop(flush: false) set _running=false and woke the tail wait: exit
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

        _inFlightFlushCount = batch.length;
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
        // Background-only batches have no WAL coverage -- never use the
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

        // Process business writes (as the "newer" data, overwriting migration).
        // Chunked so dual-pressure with batchInsert does not collapse yield interval.
        await EngineCpuChunk.forEachRangeAsync(
          length: batch.length,
          kind: CpuChunkKind.medium,
          process: (start, end) async {
            for (int i = start; i < end; i++) {
              final e = batch[i];
              final tableContext = await _tableContextFromUid(e.tableUid);
              if (tableContext == null) continue;
              tableEpochs.putIfAbsent(
                  e.tableUid, () => _bufferManager.getClearEpoch(tableContext));

              final be =
                  _bufferManager.getBufferedRecord(tableContext, e.recordId);
              if (be == null) continue;

              BufferEntry effectiveEntry = be;
              final migrationManager = _dataStore.migrationManager;
              if (migrationManager != null &&
                  migrationManager.hasRuntimeMigrationForTable(tableContext) &&
                  migrationManager.shouldNormalizeBufferedWrite(
                    tableContext,
                    be.walPointer,
                  )) {
                final normalizedData =
                    migrationManager.normalizeRecordToLatestSync(
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
              if (_dataStore.tableDataManager
                  .isTableBeingCleared(tableContext)) {
                continue;
              }

              // Business write ALWAYS overwrites migration data for the same PK
              final pkMap = tablePkMap.putIfAbsent(e.tableUid, () => {});
              pkMap[e.recordId] = effectiveEntry;

              entriesByTable.putIfAbsent(e.tableUid, () => []).add(e);
            }
          },
        );

        // 3. Finalize 'grouped' structure from the coalesced PK maps
        final Map<TableUid, Map<BufferOperationType, Map<String, BufferEntry>>>
            grouped = {};
        int totalBatchUniqueRecords = 0;

        for (final tableEntry in tablePkMap.entries) {
          final table = tableEntry.key;
          final pkMap = tableEntry.value;
          totalBatchUniqueRecords += pkMap.length;
          final byOp = grouped.putIfAbsent(
              table, () => <BufferOperationType, Map<String, BufferEntry>>{});
          await EngineCpuChunk.forEachIterable(
            pkMap.entries,
            (e) {
              final mapByOp = byOp.putIfAbsent(
                  e.value.operation, () => <String, BufferEntry>{});
              mapByOp[e.key] = e.value;
            },
            kind: CpuChunkKind.light,
          );
        }

        final journaling = _dataStore.config.enableJournal;
        // Register pending batch in WAL meta (multi-batch)
        BatchContext? currentBatchContext;
        if (recoveryBatchContext != null) {
          // In recovery mode, use the provided context and skip creating a new pending batch
          currentBatchContext = recoveryBatchContext;
        }

        final allTables = <TableUid>{...grouped.keys, ...bgEntriesByTable.keys};
        final tablePlans = <TableUid, BatchTablePlan>{};

        for (final tableUid in allTables) {
          final tableContext = await _resolveTableContext(tableUid);
          if (tableContext == null) continue;
          // Skip meta reads while clear holds the table lock and rewrites p0.dat.
          if (_dataStore.tableDataManager.isTableBeingCleared(tableContext)) {
            continue;
          }
          try {
            // Prefer schema already on [TableContext] -- avoids getTableMeta
            // cold load / bootstrap deadlock while flushing recovered meta rows.
            final schema = tableContext.schema.name.isNotEmpty
                ? tableContext.schema
                : await _dataStore.tableMetaManager
                    ?.getTableSchema(tableContext.tableUid);
            final tableDataMeta = await _dataStore.tableDataManager
                .getTableDataMeta(tableContext.tableUid);
            final indexUids = <IndexUid>[];
            final baseIndexTotalEntryCount = <IndexUid, int>{};
            final baseIndexTotalSizeBytes = <IndexUid, int>{};

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
                  baseIndexTotalEntryCount[idx.indexUid] =
                      idxMeta.totalEntryCount;
                  baseIndexTotalSizeBytes[idx.indexUid] =
                      idxMeta.totalSizeBytes;
                }
              }
            }

            tablePlans[tableUid] = BatchTablePlan(
              willUpdateTableDataMeta: true,
              indexes: indexUids,
              willUpdateIndexMeta: indexUids.isNotEmpty,
              baseTotalRecordCount: tableDataMeta?.totalRecordCount,
              baseTotalSizeBytes: tableDataMeta?.totalSizeBytes,
              baseIndexTotalEntryCount: baseIndexTotalEntryCount,
              baseIndexTotalSizeBytes: baseIndexTotalSizeBytes,
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

        // Execute tables sequentially with immediate in-memory buffer cleanup per table
        final tableYieldController = YieldController(
            'ParallelJournalManager.flush.tables',
            checkInterval: 1);

        for (final tableUid in allTables) {
          final yTable = tableYieldController.maybeYield();
          if (yTable != null) await yTable;

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

          try {
            if (_dataStore.tableDataManager.isTableBeingCleared(tableContext)) {
              continue;
            }
            if (_bufferManager.getClearEpoch(tableContext) != capturedEpoch) {
              Logger.info(
                  "Skipping stale batch for table $tableName because it was cleared/reset.");
              continue;
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

                // Unified flush: sequential table data then index maintenance
                final schema = await _resolveTableSchema(tableUid);
                if (schema == null) return;
                final pkName = schema.primaryKey;
                final migrationManager = _dataStore.migrationManager;

                // Extract and separate valid background write data
                final activeBgEntries = <BackgroundWriteEntry>[];
                await EngineCpuChunk.forEachIndexed(
                  tableBgEntries,
                  (_, e) {
                    if (e.isValid) activeBgEntries.add(e);
                  },
                  kind: CpuChunkKind.light,
                );

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
                  await EngineCpuChunk.forEachIterable(
                    businessPkMap.entries,
                    (e) {
                      unifiedPkMap[e.key] = e.value;
                    },
                    kind: CpuChunkKind.light,
                  );
                }

                final insertRecords = <Map<String, dynamic>>[];
                final updateRecords = <Map<String, dynamic>>[];
                final deleteRecords = <Map<String, dynamic>>[];
                final missingOld = <String>[];

                // 3) Upgrade + classify + collect missing old PKs in one chunked pass
                await EngineCpuChunk.forEachIterable(
                  unifiedPkMap.values,
                  (be) {
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
                      if (be.oldValues == null) {
                        final pk = be.data[pkName]?.toString();
                        if (pk != null && pk.isNotEmpty) {
                          missingOld.add(pk);
                        }
                      }
                    } else if (be.operation == BufferOperationType.delete) {
                      deleteRecords.add(currentData);
                    }
                  },
                  kind: CpuChunkKind.medium,
                );

                final oldByPk = <String, Map<String, dynamic>>{};
                if (missingOld.isNotEmpty) {
                  try {
                    final olds =
                        await _dataStore.tableDataManager.queryRecordsBatch(
                      tableContext,
                      missingOld,
                    );
                    await EngineCpuChunk.forEachIndexed(
                      olds.records,
                      (_, r) {
                        final pk = r[pkName]?.toString();
                        if (pk == null || pk.isEmpty) return;

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
                      },
                      kind: CpuChunkKind.medium,
                    );
                  } catch (_) {}
                }

                // 5) Build coalesced index update buckets (global vs specific)
                final idxInserts = <Map<String, dynamic>>[];
                final idxUpdates = <IndexRecordUpdate>[];
                final idxDeletes = <Map<String, dynamic>>[];
                final Map<String, List<BackgroundWriteEntry>> bgIndexTasks = {};

                // Normal business writes
                await EngineCpuChunk.forEachIndexed(
                  inserts,
                  (_, be) {
                    idxInserts.add(be.data);
                  },
                  kind: CpuChunkKind.light,
                );
                await EngineCpuChunk.forEachIndexed(
                  deletes,
                  (_, be) {
                    idxDeletes.add(be.data);
                  },
                  kind: CpuChunkKind.light,
                );
                await EngineCpuChunk.forEachIndexed(
                  updates,
                  (_, be) {
                    final pk = be.data[pkName]?.toString();
                    if (pk == null || pk.isEmpty) return;
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
                  },
                  kind: CpuChunkKind.light,
                );

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

                // 6) Execution actions: Sequential Table Data then Index writes
                if (insertRecords.isNotEmpty ||
                    updateRecords.isNotEmpty ||
                    deleteRecords.isNotEmpty) {
                  await _dataStore.tableDataManager.writeChanges(
                    table: tableContext,
                    inserts: insertRecords,
                    updates: updateRecords,
                    deletes: deleteRecords,
                    batchContext: currentBatchContext,
                    tableLock: tableLock,
                  );
                }

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
                      } else if (be.operation == BufferOperationType.update) {
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
                      } else if (be.operation == BufferOperationType.delete) {
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
                          targetIndexesOverride: targetOverride,
                        ) ??
                        Future.value());
                  }
                }

                // Cleanup in-memory buffers for this table IMMEDIATELY after it is written.
                if (tableQueueItems.isNotEmpty) {
                  final flushedWalByPk = <String, WalPointer?>{};
                  await EngineCpuChunk.forEachIterable(
                    unifiedPkMap.entries,
                    (e) {
                      flushedWalByPk[e.key] = e.value.walPointer;
                    },
                    kind: CpuChunkKind.light,
                  );
                  final indexPathsByPk =
                      await _bufferManager.collectFlushIndexPathsByPk(
                    table: tableContext,
                    schema: schema,
                    flushedByPk: unifiedPkMap,
                  );
                  await _bufferManager.cleanupAfterBatch(
                    tableQueueItems,
                    flushedWalByPk: flushedWalByPk,
                    indexPathsByPk: indexPathsByPk,
                  );
                }

                // Release unique key reservations for large update operations.
                final largeUpdates = bgLargeUpdatesByTable[tableUid];
                if (largeUpdates != null && largeUpdates.isNotEmpty) {
                  for (final bgEntry in largeUpdates) {
                    try {
                      _bufferManager.releaseReservedUniques(
                        table: tableContext,
                        recordId: bgEntry.primaryKey,
                        rollbackKeys: bgEntry.reserveRollbackKeys,
                      );
                    } catch (_) {}
                  }
                }
              },
              operationPrefix: 'flush_batch_unified_',
            );
          } catch (e) {
            if (!_running) {
              return;
            }
            Logger.error('Flush task failed for table [$tableName]',
                rawError: e);
            rethrow;
          }
        }

        // Clear map reference to release memory immediately for GC optimization
        bgLargeUpdatesByTable.clear();

        // Reset inFlightFlushCount and notify waiters immediately after physical data & index writes,
        // so front-end batchInsert is unblocked without waiting for checkpoint advancement.
        _inFlightFlushCount = 0;
        _notifyBusyWaiters();

        if (!quietSpaceStatsLog) {
          final now = DateTime.now();
          final at =
              '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${now.millisecond.toString().padLeft(3, '0')}';
          Logger.debug(
              'Batch flush completed: items=${batch.length}, tables=${grouped.length}, records=$totalBatchUniqueRecords, avgRecordBytes=$_averageRecordSizeBytes, state=${pressureState.name}, totalPending=$totalPending, remaining=${_bufferManager.queueLength}, cost=${batchSw.elapsedMilliseconds}ms, at: $at');
        }

        // Trigger resource check after significant data writes
        if (batch.length >= (effectiveWriteBatchSize * 0.8)) {
          _dataStore.resourceManager?.triggerImmediateCheck();
        }

        // Mark completed and advance checkpoint
        if (journaling && currentBatchContext != null) {
          try {
            await _dataStore.storage.flushAll();
          } catch (_) {}

          await _walManager.completePendingFlushBatch(
            batchId: currentBatchContext.batchId,
            checkpoint: endPtr,
          );
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
            // Flushed-evict enqueue + drain/idle clear handled by cleanupAfterBatch.
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
        _inFlightFlushCount = 0;
        _notifyBusyWaiters();
        if (!_running) {
          break;
        }
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

    // If newly enqueued writes cause busy state, immediately wake tail-wait to pump flush.
    if (pressureState == FlushPressureState.busy) {
      final wake = _tailWaitWake;
      if (wake != null && !wake.isCompleted) {
        wake.complete();
      }
    }

    if (size <= 0 && _inFlightFlushCount <= 0) {
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

  Future<void> _recoverFromWal({WalPointer? replayCheckpoint}) async {
    // Block online flush for the whole replay window. Without this, mid-replay
    final heldRecoveringFlag = _isRecovering;
    _isRecovering = true;
    try {
      final hasLogs = _walManager.hasExistingLogs;
      if (!_dataStore.config.enableJournal && !hasLogs) return;
      final meta = _walManager.meta;
      // Meta can claim a range/pending batch after a kill even when the
      // partition log was never written. Persist a clean checkpoint here;
      // otherwise idle restarts keep re-entering recovery until a later write.
      if (hasLogs && !await _walManager.hasReadablePartitionLogs()) {
        try {
          await _walManager.healStaleWalMetaIfLogsMissing();
        } catch (_) {}
        return;
      }
      // If there are no known WAL partitions, nothing to replay.
      if (meta.existingStartPartitionIndex < 0 ||
          meta.existingEndPartitionIndex < 0) {
        return;
      }

      // Fast-path: skip full replay when tail partition file is unchanged since last recovery
      // (single getFileSize check, no file content read).
      if (await _walManager.tryFastPathSkipRecovery()) return;

      final cap = _dataStore.config.logPartitionCycle;
      if (cap <= 0) {
        Logger.error(
          'WAL recovery: invalid logPartitionCycle=$cap, skipping replay',
        );
        return;
      }

      final durableCheckpoint = meta.checkpoint;
      final checkpoint = _replayStartCheckpoint(
        durableCheckpoint,
        replayCheckpoint,
        cap,
      );
      final flushBatchOwnsReplay =
          replayCheckpoint != null && replayCheckpoint.partitionIndex >= 0;

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
          // lastRecovered may skip the next start: only persist it when the
          // durable WAL-meta checkpoint already covers the tail. A temporary
          // flush-batch end is memory-only until table IO completes.
          if (durableCheckpoint.partitionIndex == tailP &&
              (tailLastPtr == null ||
                  tailLastPtr.entrySeq <= durableCheckpoint.entrySeq)) {
            try {
              await _walManager.setLastRecoveredPointer(ptr, flush: true);
            } catch (_) {}
          }
          return;
        }
      }

      final startP = normalizeWalPartitionIndex(checkpoint.partitionIndex, cap);
      final partitions = await _walManager.listPartitionsToScan(
        checkpoint.partitionIndex,
        tailP,
      );

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
          checkInterval: 1,
          budgetMs: 50);
      final recoveryNow = DateTime.now();
      if (partitions.isEmpty) {
        Logger.warn(
          'WAL recovery: no partitions to scan '
          '(checkpoint=$checkpoint end=$tailP cycle=$cap)',
        );
      }
      for (final p in partitions) {
        final y4 = partitionYieldController.maybeYield();
        if (y4 != null) await y4;

        final int toSkip =
            p == startP ? checkpoint.entrySeq : 0; // skip already processed
        int seq = toSkip;
        try {
          // Reuse startup decode cache before touching disk when possible.
          List<Map<String, dynamic>>? entries;
          final cached = _startupWalDecodeCache?[p];
          if (cached != null) {
            entries = toSkip <= 0
                ? cached
                : (toSkip >= cached.length
                    ? const <Map<String, dynamic>>[]
                    : cached.sublist(toSkip));
          } else {
            final path = _walManager.partitionLogPath(p);
            final exists = await _dataStore.storage.existsFile(path);
            if (!exists) {
              continue;
            }

            final fileBytes = await _dataStore.storage.readAsBytes(path);
            if (fileBytes.isEmpty) {
              continue;
            }

            // Decode entries; skipLeadingRecords avoids decrypt of checkpointed
            // prefix. Startup decode cache reuses partitions already decoded by
            // batch reconcile.
            entries = await _decodeWalPartitionForRecovery(
              fileBytes: fileBytes,
              partitionIndex: p,
              encoderConfig: encoderConfig,
              skipLeadingRecords: toSkip,
            );
          }

          // Process each entry
          final yieldController = YieldController(
            'ParallelJournalManager._recoverFromWal',
            budgetMs: 50,
          );

          for (final entry in entries) {
            final y5 = yieldController.maybeYield();
            if (y5 != null) await y5;
            seq++;

            final ptr = WalPointer(partitionIndex: p, entrySeq: seq);

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
              timestamp: recoveryNow,
              transactionId: entry['txId'] as String?,
              oldValues: (entry['oldValues'] as Map?)?.cast<String, dynamic>(),
              schemaVersion: entry['schemaVersion'] as String? ?? '',
            );
            final walPtr = WalPointer(partitionIndex: p, entrySeq: seq);
            final tableContext = await _resolveTableContext(resolvedTable);
            if (tableContext == null) continue;
            await _bufferManager.addRecord(
              table: tableContext,
              recordId: recordId,
              entry: be.copyWith(walPointer: walPtr),
            );

            // Meta rows land in the write buffer only; hydrate memory inventory
            if (resolvedTable == SystemTable.tableMetaTableUid &&
                (op == BufferOperationType.insert ||
                    op == BufferOperationType.update)) {
              try {
                _dataStore.tableMetaManager?.ingestRecoveredTableMetaRow(data);
              } catch (e) {
                Logger.warn(
                  'WAL recovery: failed to ingest tableMeta row pk=$recordId',
                  rawError: e,
                );
              }
            }
          }
        } catch (_) {}
      }
      // After replaying WAL, update WAL manager's in-memory current pointer.
      final WalPointer lastPtr =
          WalPointer(partitionIndex: lastPartition, entrySeq: lastSeq);
      _walManager.updateCurrentPointerAfterRecovery(lastPtr);

      // No effective entries after the replay start: only wipe WAL when
      // nothing remains to flush. A loaded flush batch is already in the
      // buffer and still needs the underlying WAL until table IO completes.
      if (!hasEffectiveEntry) {
        if (!flushBatchOwnsReplay) {
          try {
            await _walManager.clearWalPartitionsAndResetMeta();
          } catch (_) {}
        }
        return;
      } else {
        Logger.debug('Recovery added effective entries');
      }

      // Do not persist lastRecovered / checkpoint here. Entries are only in
      // the flush queue; a close/kill before table IO must still replay WAL.

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
    } finally {
      // Keep flag if pending-batch reconcile already owns recovery flush chain.
      if (!heldRecoveringFlag) {
        _isRecovering = false;
      }
    }
  }

  Future<
      ({
        WalPointer? replayCheckpoint,
        List<Future<void> Function()> flushTasks
      })> _reconcileWithParallelJournal() async {
    WalPointer? replayCheckpoint;
    final tasks = <Future<void> Function()>[];
    try {
      _isRecovering = true; // Mark as recovering
      final cap = _dataStore.config.logPartitionCycle;
      final batches =
          List<PendingParallelBatch>.from(_walManager.meta.pendingBatches)
            ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

      for (final b in batches) {
        // Load phase: synchronously restore flush ops to buffer; defer flush.
        final task = await _recoverPendingBatch(b);
        if (task != null) {
          tasks.add(task);
          // Flush batches own table/index/WAL rows. Maintenance is metadata
          // redo only and must not move the WAL replay start.
          if (b.batchType == BatchType.flush && b.end.partitionIndex >= 0) {
            replayCheckpoint = replayCheckpoint == null
                ? b.end
                : _laterWalPointer(replayCheckpoint, b.end, cap);
          }
        }
      }
      // Caller must run _executeRecoveryFlushChain AFTER _recoverFromWal.
    } catch (e) {
      Logger.error('Parallel journal reconcile failed', rawError: e);
      _isRecovering = false;
    }
    return (replayCheckpoint: replayCheckpoint, flushTasks: tasks);
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
        plan.baseTotalRecordCount == null ||
        plan.baseTotalSizeBytes == null) {
      return;
    }
    final tableContext = await _resolveTableContext(tableUid);
    if (tableContext == null) return;
    try {
      final meta = await _dataStore.tableDataManager
          .getTableDataMeta(tableContext.tableUid);
      if (meta == null) return;
      final updated = meta.copyWith(
        totalRecordCount: plan.baseTotalRecordCount!,
        totalSizeBytes: plan.baseTotalSizeBytes!,
        timestamps: Timestamps(
            created: meta.timestamps.created, modified: DateTime.now()),
      );
      await _dataStore.tableDataManager.updateTableDataMeta(
        tableContext,
        updated,
        flush: true,
      );
      // Enqueue reloads this cache then +1 per insert. Drop the pre-crash
      // value or replay would add on top of the unflushed count.
      _dataStore.tableDataManager.removeRecordCountCache(tableContext);
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
    final baseEntries = plan.baseIndexTotalEntryCount?[indexUid];
    final baseSize = plan.baseIndexTotalSizeBytes?[indexUid];
    if (baseEntries == null || baseSize == null) return;
    final tableContext = await _resolveTableContext(tableUid);
    if (tableContext == null) return;
    try {
      final idxMeta =
          await _dataStore.indexManager?.getIndexMeta(tableUid, indexUid);
      if (idxMeta == null) return;
      final updated = idxMeta.copyWith(
        totalEntryCount: baseEntries,
        totalSizeBytes: baseSize,
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
  /// Fast path (common): field is already a stable table uid -- return as-is
  /// must not query empty `_system_table_meta` data pages).
  /// Slow path (legacy name + in-flight rename): name→uid, then pending renames.
  Future<TableUid> _resolvePersistedTableField(String rawField) async {
    if (rawField.isEmpty) return TableUid.empty;

    // Hot path first: modern WAL already stores stable table uids.
    final asUid = TableUid(rawField);
    if (asUid == SystemTable.tableMetaTableUid || asUid.looksLikeStableUid) {
      return asUid;
    }

    // Recovery-only name→uid cache (null outside WAL/batch reconcile).
    final fieldCache = _recoveryFieldCache;
    if (fieldCache != null) {
      final hit = fieldCache[rawField];
      if (hit != null) return hit;
    }

    final mgr = _dataStore.tableMetaManager;
    final normalized = await mgr?.normalizeTableFieldKey(rawField) ?? rawField;
    TableUid result = TableUid(normalized);

    // Legacy name may still need in-flight rename remapping.
    final migMgr = _dataStore.migrationManager;
    if (migMgr != null) {
      final pendingRenames = migMgr.getPendingTableRenames();
      if (pendingRenames.isNotEmpty) {
        final renamed = pendingRenames[rawField] ?? pendingRenames[normalized];
        if (renamed != null) {
          result =
              TableUid(await mgr?.normalizeTableFieldKey(renamed) ?? renamed);
        }
      }
    }

    fieldCache?[rawField] = result;
    return result;
  }

  Future<TableContext?> _resolveTableContext(TableUid tableUid) async {
    if (tableUid.isEmpty) return null;

    final mgr = _dataStore.tableMetaManager;
    // Hot path first: memory inventory / pinned meta / tableMeta bootstrap.
    final sync = mgr?.getTableContextSync(tableUid);
    if (sync != null) return sync;
    if (tableUid == SystemTable.tableMetaTableUid) {
      return mgr?.bootstrapTableMetaContext();
    }

    // Recovery-only cache (null outside WAL/batch reconcile). Checked after
    // sync miss so online flush does not pay containsKey on every call.
    final ctxCache = _recoveryContextCache;
    if (ctxCache != null) {
      final cached = ctxCache[tableUid];
      // Never sticky-cache null: a later tableMeta WAL row may ingest the meta
      // for this uid in the same recovery pass (InternalKv bootstrap ordering).
      if (cached != null) return cached;
    }

    // Cold path: disk/buffer query (normal restart when meta not yet in memory).
    final ctx = await mgr?.getTableContext(tableUid);
    if (ctx != null) ctxCache?[tableUid] = ctx;
    return ctx;
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
    final cutoffCache = _recoveryCutoffCache;
    if (cutoffCache != null && cutoffCache.containsKey(tableUid)) {
      return cutoffCache[tableUid];
    }
    final mgr = _dataStore.tableMetaManager;
    List<WalPointer>? result;
    if (mgr == null) {
      result = tableCutoffs[tableUid];
    } else {
      final normalized =
          TableUid(await mgr.normalizeTableFieldKey(tableUid.value));
      result = tableCutoffs[normalized] ?? tableCutoffs[tableUid];
    }
    cutoffCache?[tableUid] = result;
    return result;
  }

  Future<TableSchema?> _resolveTableSchema(TableUid tableUid) async {
    // Fixed schema -- never await getTableMeta for the meta table itself.
    if (tableUid == SystemTable.tableMetaTableUid) {
      return SystemTable.tableMetaTable();
    }
    final ctx = await _resolveTableContext(tableUid);
    if (ctx == null) return null;
    // while `_system_table_meta` data pages are still empty.
    if (ctx.schema.name.isNotEmpty) return ctx.schema;
    return null;
  }

  Future<TableContext?> _tableContextFromUid(TableUid tableUid) async {
    return _resolveTableContext(tableUid);
  }

  /// Decode one WAL partition, reusing the startup decode cache when present.
  Future<List<Map<String, dynamic>>> _decodeWalPartitionForRecovery({
    required Uint8List fileBytes,
    required int partitionIndex,
    required EncoderConfig encoderConfig,
    int skipLeadingRecords = 0,
  }) async {
    final cache = _startupWalDecodeCache;
    final safeSkip = skipLeadingRecords < 0 ? 0 : skipLeadingRecords;

    if (cache != null) {
      final hit = cache[partitionIndex];
      if (hit != null) {
        if (safeSkip <= 0) return hit;
        if (safeSkip >= hit.length) return const <Map<String, dynamic>>[];
        return hit.sublist(safeSkip);
      }
    }

    final entries = await WalDecodeBatchRunner.decodeFile(
      fileBytes: fileBytes,
      partitionIndex: partitionIndex,
      encoderConfig: encoderConfig,
      skipLeadingRecords: safeSkip,
    );
    // Only cache complete partition decodes (no leading skip) so later passes
    // can slice arbitrary prefixes correctly.
    if (cache != null && safeSkip == 0) {
      cache[partitionIndex] = entries;
    }
    return entries;
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
      if (batch.batchType == BatchType.maintenance) {
        await _replayPageRedoLogIfExists(batch.batchId);
        await _walManager.removePendingParallelBatch(batch.batchId);
        await _deletePageRedoLogIfExists(batch.batchId);
        try {
          await _flushRecoveryArtifactsIfNeeded();
        } catch (_) {}
        return null;
      }

      // Durable checkpoint and pending-batch removal are one meta write.
      // A leftover flush handle whose end is already at or before checkpoint
      // must not roll totals back or reflush table/index rows.
      if (batch.end.partitionIndex >= 0 &&
          _walManager.isAtOrBefore(batch.end, _walManager.meta.checkpoint)) {
        Logger.debug(
          'Pending flush ${batch.batchId} already covered by WAL checkpoint; '
          'dropping without reflush',
        );
        await _walManager.removePendingParallelBatch(batch.batchId);
        await _deletePageRedoLogIfExists(batch.batchId);
        try {
          await _flushRecoveryArtifactsIfNeeded();
        } catch (_) {}
        return null;
      }

      await _replayPageRedoLogIfExists(batch.batchId);

      // Partition markers are per-file, not table-complete. Never skip whole-table
      // WAL replay based on partition 0 (or any single partition) matching:
      // unmarked sibling partitions must still be rewritten by writeChanges, which
      // already skips individual durable partition files via alreadyDurableForBatch.
      final plans = Map<TableUid, BatchTablePlan>.from(batch.tablePlans);
      final _BatchWalData walData = await _collectBatchWalChanges(batch);
      walData.tablePlans.addAll(plans);

      if (walData.orderedOpsInWalOrder.isEmpty &&
          walData.orderedOpsByTable.isEmpty) {
        Logger.warn(
          'Pending batch ${batch.batchId}: WAL logs missing or empty; '
          'dropping batch without table rollback or reflush',
        );
        await _walManager.removePendingParallelBatch(batch.batchId);
        await _deletePageRedoLogIfExists(batch.batchId);
        try {
          await _flushRecoveryArtifactsIfNeeded();
        } catch (_) {}
        return null;
      }

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
      final recoveryNow = DateTime.now();
      final loadYield = YieldController(
        'ParallelJournalManager._recoverPendingBatch.load',
        budgetMs: 50,
      );
      for (final item in walData.orderedOpsInWalOrder) {
        final yLoad = loadYield.maybeYield();
        if (yLoad != null) await yLoad;
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
          timestamp: recoveryNow,
          oldValues: op.oldValues,
          walPointer: op.walPointer,
          schemaVersion: schema.schemaVersion ?? '',
        );

        await _dataStore.tableDataManager.recoverRecordToBuffer(
          tableContext,
          op.data,
          op.op,
          entry: be,
          oldValues: op.oldValues,
          updateStats: true,
        );

        if (tableUid == SystemTable.tableMetaTableUid &&
            (op.op == BufferOperationType.insert ||
                op.op == BufferOperationType.update)) {
          try {
            _dataStore.tableMetaManager?.ingestRecoveredTableMetaRow(op.data);
          } catch (e) {
            Logger.warn(
              'Batch recovery: failed to ingest tableMeta row pk=$pkValue',
              rawError: e,
            );
          }
        }

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
        await _walManager.completePendingFlushBatch(
          batchId: batch.batchId,
          checkpoint: batch.end,
        );
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
              skipPageRedoRecord: true,
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
  /// per-file IO inside writeChanges -- never whole-tree skip here.
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
    final cap = _dataStore.config.logPartitionCycle;
    if (cap <= 0) return false;
    final endP = normalizeWalPartitionIndex(end.partitionIndex, cap);
    final p = normalizeWalPartitionIndex(partitionIndex, cap);
    if (p == endP && entrySeq > end.entrySeq) {
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
      if (cap <= 0) {
        return _BatchWalData(
          insertsByTable: inserts,
          updatesByTable: updates,
          deletesByTable: deletes,
          orderedOpsByTable: ordered,
          orderedOpsInWalOrder: [],
        );
      }
      final startN = normalizeWalPartitionIndex(startP, cap);
      final encoderConfig = EncryptionManager.getCurrentEncodingState();
      final partitions = await _walManager.listPartitionsToScan(startP, endP);
      for (final p in partitions) {
        final path = _walManager.partitionLogPath(p);
        final int toSkip = p == startN ? batch.start.entrySeq : 0;
        int seq = 0;
        try {
          List<Map<String, dynamic>> entries;
          final cached = _startupWalDecodeCache?[p];
          if (cached != null) {
            entries = cached;
          } else {
            final exists = await _dataStore.storage.existsFile(path);
            if (!exists) {
              continue;
            }

            final fileBytes = await _dataStore.storage.readAsBytes(path);
            if (fileBytes.isEmpty) {
              continue;
            }

            // Full-file decode (cached for subsequent _recoverFromWal). Leading
            // batch-start entries are skipped in the loop below.
            entries = await _decodeWalPartitionForRecovery(
              fileBytes: fileBytes,
              partitionIndex: p,
              encoderConfig: encoderConfig,
            );
          }

          // Process each entry
          final yieldController = YieldController(
            'ParallelJournalManager._collectBatchWalChanges',
            budgetMs: 50,
          );
          for (final entry in entries) {
            final y6 = yieldController.maybeYield();
            if (y6 != null) await y6;
            seq++;
            if (p == startN && seq < toSkip) continue;

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

    final Map<TableUid, BatchTablePlan> tablePlans;
    if (_dataStore.tableDataManager.isTableBeingCleared(tableContext)) {
      // clearTable rebuilds meta from scratch; avoid disk meta/index probes.
      tablePlans = <TableUid, BatchTablePlan>{
        tableUid: BatchTablePlan(
          willUpdateTableDataMeta: true,
          indexes: const <IndexUid>[],
          willUpdateIndexMeta: false,
          baseTotalRecordCount: 0,
          baseTotalSizeBytes: 0,
        ),
      };
    } else {
      final tableDataMeta = await _dataStore.tableDataManager
          .getTableDataMeta(tableContext.tableUid);
      final indexUids = <IndexUid>[];
      final baseIndexTotalEntryCount = <IndexUid, int>{};
      final baseIndexTotalSizeBytes = <IndexUid, int>{};
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
            baseIndexTotalEntryCount[idx.indexUid] = idxMeta.totalEntryCount;
            baseIndexTotalSizeBytes[idx.indexUid] = idxMeta.totalSizeBytes;
          }
        }
      } catch (_) {}

      tablePlans = <TableUid, BatchTablePlan>{
        tableUid: BatchTablePlan(
          willUpdateTableDataMeta: true,
          indexes: indexUids,
          willUpdateIndexMeta: indexUids.isNotEmpty,
          baseTotalRecordCount: tableDataMeta?.totalRecordCount,
          baseTotalSizeBytes: tableDataMeta?.totalSizeBytes,
          baseIndexTotalEntryCount: baseIndexTotalEntryCount,
          baseIndexTotalSizeBytes: baseIndexTotalSizeBytes,
        ),
      };
    }

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
  /// Does **not** reuse [activeBatchContext] from an in-flight flush batch --
  /// ad-hoc page-0 writes must not share redo / recovery scope with unrelated
  /// flush work.
  ///
  /// Skips opening a new batch when journal is off, during recovery, or when
  /// [table] cannot be resolved -- [action] still runs (`batchContext` may be
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
  /// possibly corrupted pages. Does **not** append to the redo log.
  ///
  /// Redo log contains **intended page images** (what the batch was about to write).
  /// Partition-0 page0 images include full tree-global meta (TMP1).
  /// Legacy [PageRedoTreeMetaRecord] (structure-only) is applied only when page0
  /// was absent from the same redo log.
  ///
  /// Consistency: for **flush**, metadata may be restored to "before batch"
  /// totals then [_pumpFlush] re-runs the batch. For **maintenance**, redo is
  /// the commit image -- keep replayed pages as-is; do not roll totals back to
  /// base (there is no WAL reflush to rebuild them).
  Future<void> _replayPageRedoLogIfExists(String batchId) async {
    try {
      final redoPath = _dataStore.pathManager
          .getPageRedoLogPath(batchId, spaceName: _dataStore.currentSpaceName);
      if (!await _dataStore.storage.existsFile(redoPath)) return;
      final size = await _dataStore.storage.getFileSize(redoPath);
      if (size <= 0) return;
      final bytes = await _dataStore.storage.readAsBytes(redoPath);
      if (bytes.isEmpty) return;
      final applicable = PageRedoLogCodec.collectApplicableRecords(bytes);
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
      for (var i = 0; i < applicable.pages.length; i++) {
        final y7 = parseYc.maybeYield();
        if (y7 != null) await y7;
        final rec = applicable.pages[i];
        final key = (
          kind: rec.treeKind,
          tableUid: rec.tableUid,
          indexUid: rec.indexUid ?? IndexUid.empty,
          partitionNo: rec.partitionNo,
        );
        byPartition.putIfAbsent(key, () => <int, Uint8List>{})[rec.pageNo] =
            rec.payload;
      }
      for (final rec in applicable.treeMetas) {
        final key = (
          kind: rec.treeKind,
          tableUid: rec.tableUid,
          indexUid: rec.indexUid ?? IndexUid.empty,
        );
        treeMeta[key] = rec;
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
        if (key.kind.requiresIndexUid && key.indexUid.isEmpty) {
          continue;
        }

        String path;
        try {
          if (key.kind == PageRedoTreeKind.table) {
            final tableContext = await _tableContextFromUid(key.tableUid);
            if (tableContext == null) continue;
            path = _dataStore.pathManager
                .getPartitionFilePathByContext(tableContext, key.partitionNo);
          } else if (key.kind == PageRedoTreeKind.ngh) {
            final tableContext = await _tableContextFromUid(key.tableUid);
            if (tableContext == null) continue;
            final indexUid =
                _resolveRedoIndexUid(tableContext.schema, key.indexUid);
            path = _dataStore.pathManager.getNghPostingPartitionPathByContext(
                tableContext, indexUid, key.partitionNo);
          } else if (key.kind == PageRedoTreeKind.nghNav) {
            final tableContext = await _tableContextFromUid(key.tableUid);
            if (tableContext == null) continue;
            final indexUid =
                _resolveRedoIndexUid(tableContext.schema, key.indexUid);
            path = _dataStore.pathManager.getNghNavPartitionPathByContext(
                tableContext, indexUid, key.partitionNo);
          } else {
            final tableContext = await _tableContextFromUid(key.tableUid);
            if (tableContext == null) continue;
            final indexUid =
                _resolveRedoIndexUid(tableContext.schema, key.indexUid);
            path = _dataStore.pathManager.getIndexPartitionPathByContext(
                tableContext, indexUid, key.partitionNo);
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
            } else if (key.kind == PageRedoTreeKind.ngh ||
                key.kind == PageRedoTreeKind.nghNav) {
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
      // embeds full meta in page0 images -- applying TreeMetaRecord after p0 would
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
              final resolved =
                  _resolveRedoIndexUid(tableContext.schema, idxUid);
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
    } catch (e) {
      Logger.warn(
        'Page redo replay skipped for batch $batchId '
        '(missing, empty, or unreadable log)',
        rawError: e,
      );
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
      await _walManager.flushRecoveryArtifactsToStorage();
    } catch (_) {}
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
