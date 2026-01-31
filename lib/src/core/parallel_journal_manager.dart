import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../handler/wal_encoder.dart';
import '../handler/logger.dart';
import '../handler/parallel_processor.dart';
import '../handler/encoder.dart';
import '../model/encoder_config.dart';
import 'compute_manager.dart';
import '../model/buffer_entry.dart';
import '../model/wal_pointer.dart';
import 'data_store_impl.dart';
import 'page_redo_log_codec.dart';
import 'wal_manager.dart';
import '../model/parallel_journal_entry.dart';
import '../model/meta_info.dart';

import '../handler/value_matcher.dart';
import 'write_buffer_manager.dart';
import '../Interface/storage_interface.dart';
import 'storage_adapter.dart';
import 'btree_page.dart';

import 'workload_scheduler.dart';
import 'io_concurrency_planner.dart';
import '../model/table_schema.dart';
import '../model/id_generator.dart';
import '../model/index_entry.dart';
import 'yield_controller.dart';

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

  ParallelJournalManager(
      this._dataStore, this._walManager, this._bufferManager);

  /// Current active batch context during flush/recovery; null if idle
  BatchContext? get activeBatchContext => _activeBatchContext;

  /// Current active batch id during flush/recovery; null if idle
  String? get activeBatchId => _activeBatchContext?.batchId;

  /// Check if currently in recovery mode (recovering from a pending batch)
  /// Returns true only when actively recovering a pending batch, not just when pending batches exist
  bool get isInRecoveryMode => _isRecovering;

  Future<void> start() async {
    if (_running) return;
    _running = true;
    // Reconcile incomplete batch from active A/B journal if any
    List<_WalRange>? excludeRanges;
    if (_walManager.hasPendingParallelBatches) {
      excludeRanges = await _reconcileWithParallelJournal();
    }
    // Then recover pending WAL entries into in-memory buffer/queue
    await _recoverFromWal(excludeRanges: excludeRanges);

    if (!_dataStore.config.enableJournal) {
      bool cleaned = false;
      if (_walManager.hasExistingLogs) {
        Logger.info(
            'Journal disabled but existing logs found. Draining legacy WAL...',
            label: 'ParallelJournalManager');
        await flushCompletely();
        await _walManager.destroyWal();
        cleaned = true;
      }

      // Also clean up any parallel journal files (journal_a.log, journal_b.log)
      // These might exist if the previous run was abruptly terminated
      final pathA = _dataStore.pathManager
          .getParallelJournalAPath(spaceName: _dataStore.currentSpaceName);
      final pathB = _dataStore.pathManager
          .getParallelJournalBPath(spaceName: _dataStore.currentSpaceName);

      try {
        if (await _dataStore.storage.existsFile(pathA)) {
          await _dataStore.storage.deleteFile(pathA);
          cleaned = true;
        }
        if (await _dataStore.storage.existsFile(pathB)) {
          await _dataStore.storage.deleteFile(pathB);
          cleaned = true;
        }
      } catch (e) {
        Logger.warn('Failed to cleanup parallel journal files: $e',
            label: 'ParallelJournalManager');
      }

      if (cleaned) {
        Logger.info('Legacy WAL and journals drained and destroyed.',
            label: 'ParallelJournalManager');
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
      // Drop all pending buffered writes; caller has decided not to persist these data
      _bufferManager.clearAll();
    }
  }

  void _scheduleFlushIfNeeded() {
    if (!_running) return;
    if (_flushInProgress) return;
    if (_bufferManager.isEmpty) return;
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
  ///
  /// This matches "keep waiting 5s while data keeps arriving" for mobile,
  /// without starving durability indefinitely.
  Future<void> _waitTailFillWhileGrowing({
    required int targetSize,
    required int delayMs,
    int maxExtraRounds = 3,
  }) async {
    if (delayMs <= 0) return;
    if (_bufferManager.queueLength >= targetSize) return;
    if (maxExtraRounds < 0) maxExtraRounds = 0;

    int rounds = 0;
    while (true) {
      final before = _bufferManager.queueLength;
      if (before >= targetSize) return;
      if (before <= 0) return;

      await Future.delayed(
          Duration(milliseconds: rounds == 0 ? 1000 : delayMs));

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
    if (_isRecovering && recoveryBatchContext == null) {
      return;
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

    while (_running && !_bufferManager.isEmpty) {
      List<WriteQueueEntry> batch = const <WriteQueueEntry>[];
      try {
        // This is the first iteration, we need to ensure at least one batch is flushed.
        // After the first iteration, if the queue length drops below batchSize in normal mode,
        // wait up to maxFlushLatencyMs before flushing the remaining tail, to avoid flushing
        // every tiny batch immediately while still bounding latency.
        // In drain mode (close/switch space), ignore this and ensure the queue is fully flushed.
        if (!drainCompletely) {
          final currentSize = _bufferManager.queueLength;
          if (currentSize < batchSize) {
            await _waitTailFillWhileGrowing(
              targetSize: batchSize,
              delayMs: delayMs,
              maxExtraRounds: 3,
            );
          }
        }

        // Single-pass guard for recovery batches: process exactly one batch then stop.
        if (recoveryBatchContext != null && !firstIteration) {
          break;
        }

        final batchSw = Stopwatch()..start();
        batch = _bufferManager.popBatch(batchSize);
        if (batch.isEmpty) {
          break;
        }

        Logger.debug("Executing batch with ${batch.length} items",
            label: "ParallelJournalManager._pumpFlush");

        firstIteration = false;
        // Compute WAL pointer range (exclude pseudo pointers where partitionIndex == -1)
        final startPtr = batch.first.walPointer;
        final endPtr = batch.last.walPointer;

        // Group by table and FINAL operation (derive from current buffer entry to allow coalescing and de-dup per PK)
        // Skip entries for tables that are being cleared to avoid race conditions where clearTable
        // deletes files while flush is processing queued operations.
        final Map<String, Map<BufferOperationType, Map<String, BufferEntry>>>
            grouped = {};
        final Map<String, int> tableEpochs = {};
        // Track queue entries by table for granular cleanup
        final Map<String, List<WriteQueueEntry>> entriesByTable = {};

        int totalBatchUniqueRecords = 0;
        final yieldController =
            YieldController('ParallelJournalManager._pumpFlush');
        for (final e in batch) {
          await yieldController.maybeYield();
          // Capture epoch for this table if not already captured in this batch
          tableEpochs.putIfAbsent(
              e.tableName, () => _bufferManager.getClearEpoch(e.tableName));

          final be = _bufferManager.getBufferedRecord(e.tableName, e.recordId);
          if (be == null) continue; // may have been cleared by other flow

          // Check if table is being cleared - if so, skip this entry to avoid race condition
          if (_dataStore.tableDataManager.isTableBeingCleared(e.tableName)) {
            continue;
          }

          final currentOp = be.operation;
          final byOp = grouped.putIfAbsent(e.tableName,
              () => <BufferOperationType, Map<String, BufferEntry>>{});
          final mapByPk =
              byOp.putIfAbsent(currentOp, () => <String, BufferEntry>{});

          if (!mapByPk.containsKey(e.recordId)) {
            totalBatchUniqueRecords++;
            mapByPk[e.recordId] = be;
          }

          entriesByTable.putIfAbsent(e.tableName, () => []).add(e);
        }

        final journaling = _dataStore.config.enableJournal;
        // Register pending batch in WAL meta and write batch header (multi-batch)
        BatchContext? currentBatchContext;
        if (recoveryBatchContext != null) {
          // In recovery mode, use the provided context and skip creating a new pending batch
          currentBatchContext = recoveryBatchContext;
        } else if (journaling) {
          try {
            final active = _walManager.meta.activeParallelJournal;
            final path = active == 'A'
                ? _dataStore.pathManager.getParallelJournalAPath(
                    spaceName: _dataStore.currentSpaceName)
                : _dataStore.pathManager.getParallelJournalBPath(
                    spaceName: _dataStore.currentSpaceName);
            final size = await _dataStore.storage.getFileSize(path);
            final batchId = GlobalIdGenerator.generate('flush_batch_');
            currentBatchContext = BatchContext.flush(batchId);
            await _walManager.addPendingParallelBatch(PendingParallelBatch(
              batchId: batchId,
              batchType: BatchType.flush,
              journalFile: active,
              recoverStartOffset: size,
              start: startPtr,
              end: endPtr,
              tables: grouped.keys.toList(),
              createdAt: DateTime.now().toIso8601String(),
            ));
          } catch (_) {}
        }

        // Compute planned counts per table/op for recovery introspection
        final Map<String, Map<int, int>> planned = {};
        grouped.forEach((table, byOp) {
          byOp.forEach((op, mapByPk) {
            if (mapByPk.isEmpty) return;
            final byIdx = planned.putIfAbsent(table, () => <int, int>{});
            byIdx[op.index] = (byIdx[op.index] ?? 0) + mapByPk.length;
          });
        });
        // Build lightweight table plan with index names to indicate index meta involvement
        final Map<String, dynamic> tablePlan = {};
        int estimatedTotalWorkOps = 0;
        for (final table in grouped.keys) {
          try {
            final schema =
                await _dataStore.schemaManager?.getTableSchema(table);
            final tableMeta =
                await _dataStore.tableDataManager.getTableMeta(table);
            final indexNames = <String>[];
            final baseIndexTotalEntries = <String, int>{};
            final baseIndexTotalSizeInBytes = <String, int>{};

            if (schema != null) {
              // defined indexes (explicit + implicit unique/fk)
              for (final idx in schema.getAllIndexes()) {
                final idxName = idx.actualIndexName;
                indexNames.add(idxName);

                // Fetch base index metadata
                final idxMeta =
                    await _dataStore.indexManager?.getIndexMeta(table, idxName);
                if (idxMeta != null) {
                  baseIndexTotalEntries[idxName] = idxMeta.totalEntries;
                  baseIndexTotalSizeInBytes[idxName] = idxMeta.totalSizeInBytes;
                }
              }
            }

            // Calculate ops for timeout: records * (1 + indexCount)
            int tableRecordCount = 0;
            grouped[table]?.forEach((_, map) => tableRecordCount += map.length);
            estimatedTotalWorkOps += tableRecordCount * (1 + indexNames.length);

            tablePlan[table] = {
              'willUpdateTableMeta': true,
              'indexes': indexNames,
              'willUpdateIndexMeta': indexNames.isNotEmpty,
              'baseTotalRecords': tableMeta?.totalRecords,
              'baseTotalSizeInBytes': tableMeta?.totalSizeInBytes,
              'baseIndexTotalEntries': baseIndexTotalEntries,
              'baseIndexTotalSizeInBytes': baseIndexTotalSizeInBytes,
            };
          } catch (_) {}
        }
        if (journaling && currentBatchContext != null) {
          _activeBatchContext = currentBatchContext;
          // Only write BatchStartEntry if NOT recovering (it already exists in recovery scenario)
          if (recoveryBatchContext == null) {
            final entry = BatchStartEntry(
              at: DateTime.now().toIso8601String(),
              start: WalPointerRef(
                  partitionIndex: startPtr.partitionIndex,
                  entrySeq: startPtr.entrySeq),
              end: WalPointerRef(
                  partitionIndex: endPtr.partitionIndex,
                  entrySeq: endPtr.entrySeq),
              size: batch.length,
              plan: planned,
              tablePlan: tablePlan.map((k, v) => MapEntry(
                  k,
                  TablePlan(
                    willUpdateTableMeta:
                        v['willUpdateTableMeta'] as bool? ?? true,
                    indexes: ((v['indexes'] as List?) ?? const <dynamic>[])
                        .map((e) => e.toString())
                        .toList(),
                    willUpdateIndexMeta:
                        v['willUpdateIndexMeta'] as bool? ?? false,
                    baseTotalRecords: v['baseTotalRecords'] as int?,
                    baseTotalSizeInBytes: v['baseTotalSizeInBytes'] as int?,
                    baseIndexTotalEntries:
                        v['baseIndexTotalEntries'] as Map<String, int>?,
                    baseIndexTotalSizeInBytes:
                        v['baseIndexTotalSizeInBytes'] as Map<String, int>?,
                  ))),
              batchId: currentBatchContext.batchId,
              batchType: currentBatchContext.batchType,
            );
            await appendJournalEntry(entry);
          }
        }

        // Build per-table tasks with unified insert/update/delete handling to minimize partition rewrites.
        final tasks = <Future<void> Function()>[];
        late final int plannedTableConcurrency;
        late final int perTableTokenBudget;
        grouped.forEach((table, byOp) {
          // Use the epoch captured before/during grouping
          final capturedEpoch = tableEpochs[table] ?? 0;
          final tableQueueItems = entriesByTable[table] ?? [];

          final inserts = byOp[BufferOperationType.insert]
                  ?.values
                  .toList(growable: false) ??
              const <BufferEntry>[];
          final updates = byOp[BufferOperationType.update]
                  ?.values
                  .toList(growable: false) ??
              const <BufferEntry>[];
          final deletes = byOp[BufferOperationType.delete]
                  ?.values
                  .toList(growable: false) ??
              const <BufferEntry>[];

          final allEntries = <BufferEntry>[
            ...inserts,
            ...updates,
            ...deletes,
          ];
          if (allEntries.isEmpty) return;

          tasks.add(() async {
            try {
              final lockKey = 'table_$table';
              final opId = GlobalIdGenerator.generate('flush_batch_unified_');
              bool locked = false;
              try {
                if (_dataStore.tableDataManager.isTableBeingCleared(table)) {
                  return;
                }

                // Verify epoch hasn't changed (O(1) check for table clear race)
                if (_bufferManager.getClearEpoch(table) != capturedEpoch) {
                  Logger.info(
                      "Skipping stale batch for table $table because it was cleared/reset.",
                      label: "ParallelJournalManager");
                  return;
                }
                locked = await (_dataStore.lockManager
                        ?.acquireExclusiveLock(lockKey, opId) ??
                    true);
                if (!locked) {
                  Logger.warn('Skip write due to lock not acquired: $table',
                      label: 'ParallelJournalManager');
                  return;
                }
                // Unified flush: parallelize table data and index maintenance
                final schema =
                    await _dataStore.schemaManager?.getTableSchema(table);
                if (schema == null) return;
                final pkName = schema.primaryKey;

                final insertRecords =
                    inserts.map((e) => e.data).toList(growable: false);
                final updateRecords =
                    updates.map((e) => e.data).toList(growable: false);
                final deleteRecords =
                    deletes.map((e) => e.data).toList(growable: false);

                // Best-effort: fill missing oldValues from persisted table data (batch lookup).
                final missingOld = <String>[];
                for (final u in updates) {
                  if (u.oldValues != null) continue;
                  final pk = u.data[pkName]?.toString();
                  if (pk == null || pk.isEmpty) continue;
                  missingOld.add(pk);
                }
                final oldByPk = <String, Map<String, dynamic>>{};
                if (missingOld.isNotEmpty) {
                  try {
                    final olds =
                        await _dataStore.tableDataManager.queryRecordsBatch(
                      table,
                      missingOld,
                    );
                    for (final r in olds.records) {
                      final pk = r[pkName]?.toString();
                      if (pk == null || pk.isEmpty) continue;
                      oldByPk[pk] = r;
                    }
                  } catch (_) {}
                }

                // Prepare Index Updates (CPU bound mostly, but writes are IO)
                final idxInserts = <Map<String, dynamic>>[];
                idxInserts.addAll(insertRecords);
                final idxUpdates = <IndexRecordUpdate>[];
                for (final u in updates) {
                  final pk = u.data[pkName]?.toString();
                  if (pk == null || pk.isEmpty) continue;
                  final oldVals = u.oldValues ?? oldByPk[pk];
                  if (oldVals == null) {
                    // Cannot safely remove old index entries; treat as insert-only.
                    idxInserts.add(u.data);
                    continue;
                  }
                  idxUpdates.add(IndexRecordUpdate(
                    primaryKey: pk,
                    newValues: Map<String, dynamic>.from(u.data),
                    oldValues: Map<String, dynamic>.from(oldVals),
                  ));
                }

                // Execute Table Write and Index Write in Parallel
                // Compute per-table token budgets (data vs indexes) from planned batch plan.
                // IMPORTANT: budgets are request caps; actual concurrency is still bounded by scheduler grants.
                final indexesForBudget = schema.getAllIndexes().toList();
                final split = IoConcurrencyPlanner.splitPerTableBudget(
                  perTableTokens: perTableTokenBudget,
                  indexCount: indexesForBudget.length,
                );

                // 1) Table Data
                final tableWriteFuture =
                    _dataStore.tableDataManager.writeChanges(
                  tableName: table,
                  inserts: insertRecords,
                  updates: updateRecords,
                  deletes: deleteRecords,
                  batchContext: currentBatchContext,
                  concurrency: split.tableDataTokens, // token request cap
                );

                // 2) Index Data (budgeted) - IndexManager will internally split into index-level + partition-level.
                Future<void> indexWrite() async {
                  if (indexesForBudget.isEmpty) return;
                  await (_dataStore.indexManager?.writeChanges(
                        tableName: table,
                        inserts: idxInserts,
                        updates: idxUpdates,
                        deletes: deleteRecords,
                        batchContext: currentBatchContext,
                        concurrency:
                            split.indexTokens, // token budget for index IO
                      ) ??
                      Future.value());
                }

                if (indexesForBudget.isEmpty) {
                  await tableWriteFuture;
                } else if (split.runInParallel) {
                  await Future.wait([tableWriteFuture, indexWrite()]);
                } else {
                  // Budget too small to run both sides concurrently; prioritize table data first.
                  await tableWriteFuture;
                  await indexWrite();
                }

                // Cleanup in-memory buffers for this table IMMEDIATELY after it is written.
                if (tableQueueItems.isNotEmpty) {
                  await _bufferManager.cleanupAfterBatch(tableQueueItems);
                }
              } finally {
                if (locked && _dataStore.lockManager != null) {
                  _dataStore.lockManager!.releaseExclusiveLock(lockKey, opId);
                }
              }

              if (journaling && currentBatchContext != null) {
                final totalCount =
                    inserts.length + updates.length + deletes.length;
                if (totalCount > 0) {
                  await appendJournalEntry(TaskDoneEntry(
                    at: DateTime.now().toIso8601String(),
                    table: table,
                    count: totalCount,
                    batchId: currentBatchContext.batchId,
                    batchType: currentBatchContext.batchType,
                  ));
                }
              }
            } catch (e, s) {
              Logger.error(
                'Flush task failed for table [$table]: $e\n$s',
                label: 'ParallelJournalManager',
              );
              rethrow;
            }
          });
        });

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

          final now = DateTime.now();
          final at =
              '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${now.millisecond.toString().padLeft(3, '0')}';
          Logger.debug(
              'Batch flush completed: items=${batch.length}, tables=${grouped.length}, records=$totalBatchUniqueRecords, remaining=${_bufferManager.queueLength}, cost=${batchSw.elapsedMilliseconds}ms, at: $at',
              label: 'ParallelJournalManager');
        }

        // Mark completed and advance checkpoint
        if (journaling && currentBatchContext != null) {
          await appendJournalEntry(BatchCompletedEntry(
            at: DateTime.now().toIso8601String(),
            batchId: currentBatchContext.batchId,
            batchType: currentBatchContext.batchType,
          ));

          // Durability boundary:
          // Flush ALL open handles AFTER writing BatchCompletedEntry, then advance checkpoint.
          // This ensures recovery can trust that "completed" implies durable.
          try {
            await _dataStore.storage.flushAll();
          } catch (_) {}

          await _walManager.advanceCheckpoint(endPtr);
          await _walManager
              .removePendingParallelBatch(currentBatchContext.batchId);
          await _deletePageRedoLogIfExists(currentBatchContext.batchId);
          await _maybeRotateParallelJournal();
          await _walManager.cleanupObsoletePartitions();

          // Durability: flush recovery artifacts at batch end if enabled
          try {
            await _flushRecoveryArtifactsIfNeeded();
          } catch (_) {}
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
              _scheduleFlushIfNeeded(); // Trigger non-batch WAL write queue
              Logger.debug('Parallel journal recovery completed.',
                  label: 'ParallelJournalManager');
            }
          }
        }
        await _dataStore.tableDataManager.persistRuntimeMetaIfNeeded();
      } catch (e, s) {
        Logger.error('ParallelJournalManager loop failed: $e\n$s',
            label: 'ParallelJournalManager');
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
    if (size <= 0) {
      return;
    }
    // Whenever the buffer becomes non-empty, trigger a flush pump if not running.
    // The pump itself will handle batching and tail latency via maxFlushLatencyMs.
    _scheduleFlushIfNeeded();
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
      final Map<String, dynamic> maxPkByTable = <String, dynamic>{};
      // Store matcher functions for each table to compare primary keys
      final Map<String, MatcherFunction> pkMatchersByTable =
          <String, MatcherFunction>{};
      // Precompute table-level WAL cutoff pointers from WAL meta (clear/drop ops)
      final Map<String, List<WalPointer>> tableCutoffs =
          <String, List<WalPointer>>{};
      try {
        for (final op in _walManager.tableOps.values) {
          tableCutoffs
              .putIfAbsent(op.table, () => <WalPointer>[])
              .add(op.cutoff);
        }
      } catch (_) {}
      final partitionYieldController = YieldController(
          'ParallelJournalManager._recoverFromWal.partition',
          checkInterval: 1);
      while (true) {
        await partitionYieldController.maybeYield();
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
          final request = WalDecodeRequest(
            fileBytes: fileBytes,
            partitionIndex: p,
            encoderConfig: EncoderHandler.getCurrentEncodingState(),
          );

          final entries = await ComputeManager.run(
            _walDecodeTask,
            request,
            useIsolate: fileBytes.length > 4096,
          );

          // Process each entry
          final yieldController =
              YieldController('ParallelJournalManager._recoverFromWal');

          for (final entry in entries) {
            await yieldController.maybeYield();
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
            final data = (entry['data'] as Map?)?.cast<String, dynamic>();
            final opIdx = entry['op'] as int?;
            if (table == null || data == null || opIdx == null) continue;

            // Skip WAL entries that are logically before a clear/drop cutoff
            // for this table.
            final cutoffs = tableCutoffs[table];
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

            final schema =
                await _dataStore.schemaManager?.getTableSchema(table);
            if (schema == null) {
              // Table was dropped or schema unavailable; skip this WAL entry.
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
                MatcherFunction? pkMatcher = pkMatchersByTable[table];
                if (pkMatcher == null) {
                  pkMatcher = ValueMatcher.getMatcher(
                      schema.getPrimaryKeyMatcherType());
                  pkMatchersByTable[table] = pkMatcher;
                }

                // Update max primary key for this table
                final currentMax = maxPkByTable[table];
                if (currentMax == null || pkMatcher(pkValue, currentMax) > 0) {
                  maxPkByTable[table] = pkValue;
                }
              }
            }

            final be = BufferEntry(
              data: data,
              operation: op,
              timestamp: DateTime.now(),
              transactionId: entry['txId'] as String?,
              oldValues: (entry['oldValues'] as Map?)?.cast<String, dynamic>(),
            );
            final walPtr = WalPointer(partitionIndex: p, entrySeq: seq);
            final uniqueRefs = await _computeUniqueKeyRefs(table, data);
            await _bufferManager.addRecord(
              tableName: table,
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
        Logger.debug('Recovery added effective entries',
            label: 'ParallelJournalManager._recoverWAL');
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
            final table = entry.key;
            final maxPk = entry.value;
            // First, update memory and FileMeta with tracked WAL max to preserve it
            // This ensures the WAL max is saved even if buffer is cleared later
            await _dataStore.tableDataManager
                .updateMaxIdInMemory(table, maxPk, updateFileMeta: true);
            // Then, call updateMaxIdFromTable to get the true maximum from all sources
            // It will compare: partition max, buffer max, and current memory value (which includes WAL max)
            // and update to the global maximum. Since we set forceRecalculate=true, it will
            // always recalculate even if cache matches, ensuring we get the true max from all sources.
            await _dataStore.tableDataManager
                .updateMaxIdFromTable(table, forceRecalculate: true);
          }
        } catch (e) {
          Logger.error('Failed to update maxId after WAL recovery: $e',
              label: 'ParallelJournalManager._recoverFromWal');
        }
      }
    } catch (e, s) {
      Logger.error('Recover from WAL failed: $e\n$s',
          label: 'ParallelJournalManager');
    }
  }

  Future<List<_WalRange>> _reconcileWithParallelJournal() async {
    final excludeRanges = <_WalRange>[];
    try {
      _isRecovering = true; // Mark as recovering
      final batches =
          List<PendingParallelBatch>.from(_walManager.meta.pendingBatches)
            ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

      final tasks = <Future<void> Function()>[];
      for (final b in batches) {
        // Load phase: synchronously restore to buffer, but defer flush
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

      // Flush phase: chain flush tasks in background (fire-and-forget)
      // This prevents startup blocking while ensuring batches are processed in order.
      _executeRecoveryFlushChain(tasks);
    } catch (e, s) {
      Logger.error('Parallel journal reconcile failed: $e\n$s',
          label: 'ParallelJournalManager');
      _isRecovering = false;
    }
    // Note: _isRecovering reset is handled by _executeRecoveryFlushChain at the end of the recovery chain
    return excludeRanges;
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
          } catch (e, s) {
            Logger.error('Recovery flush task failed: $e\n$s',
                label: 'ParallelJournalManager');
          }
        }
      } finally {
        _isRecovering = false;
        _loopFuture = null;

        // If data was added during recovery, trigger a normal flush
        if (_running && !_bufferManager.isEmpty) {
          _scheduleFlushIfNeeded();
        }
      }
    });

    _loopFuture = recoveryChainFuture;
  }

  /// Recover maintenance batch metadata for tables and indexes
  /// This efficiently recovers by using the last flushed partition entry's statistics
  /// instead of traversing all partition files (critical for tables with hundreds of thousands of partitions)
  Future<void> _recoverMaintenanceBatch(PendingParallelBatch batch) async {
    final path = batch.journalFile == 'A'
        ? _dataStore.pathManager
            .getParallelJournalAPath(spaceName: _dataStore.currentSpaceName)
        : _dataStore.pathManager
            .getParallelJournalBPath(spaceName: _dataStore.currentSpaceName);

    // Collect per-table: max partitionNo and its corresponding TablePartitionFlushedEntry
    // Collect per-index: max partitionNo and its corresponding IndexPartitionFlushedEntry
    // This allows us to quickly check if metadata is consistent without traversing all partitions
    final Map<String, TablePartitionFlushedEntry> tableLastFlushedEntry = {};
    final Map<String, IndexPartitionFlushedEntry> indexLastFlushedEntry = {};

    try {
      if (await _dataStore.storage.existsFile(path)) {
        final stream = _dataStore.storage
            .readLinesStream(path, offset: batch.recoverStartOffset);
        final yieldController =
            YieldController('ParallelJournalManager._recoverMaintenanceBatch');
        await for (final line in stream) {
          await yieldController.maybeYield();
          if (line.isEmpty) continue;
          try {
            final json = jsonDecode(line);
            final entry = ParallelJournalEntry.fromJson(json);
            if (entry != null) {
              if (entry is TablePartitionFlushedEntry &&
                  entry.batchId == batch.batchId) {
                // Track the last flushed entry (max partitionNo) for each table
                final existing = tableLastFlushedEntry[entry.table];
                if (existing == null ||
                    entry.partitionNo > existing.partitionNo) {
                  tableLastFlushedEntry[entry.table] = entry;
                }
              } else if (entry is IndexPartitionFlushedEntry &&
                  entry.batchId == batch.batchId) {
                // Track the last flushed entry (max partitionNo) for each index
                final indexKey = '${entry.table}:${entry.index}';
                final existing = indexLastFlushedEntry[indexKey];
                if (existing == null ||
                    entry.partitionNo > existing.partitionNo) {
                  indexLastFlushedEntry[indexKey] = entry;
                }
              }
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      Logger.warn('Failed to scan journal for flushed partitions: $e',
          label: 'ParallelJournalManager._recoverMaintenanceBatch');
    }

    // Recover table metadata
    for (final entry in tableLastFlushedEntry.entries) {
      await _recoverTableMaintenanceMetadata(entry.key, entry.value);
    }

    // Recover index metadata
    for (final entry in indexLastFlushedEntry.entries) {
      final parts = entry.key.split(':');
      if (parts.length == 2) {
        await _recoverIndexMaintenanceMetadata(parts[0], parts[1], entry.value);
      }
    }
  }

  /// Recover table metadata from maintenance batch
  Future<void> _recoverTableMaintenanceMetadata(
      String tableName, TablePartitionFlushedEntry lastEntry) async {
    try {
      final tableMeta =
          await _dataStore.tableDataManager.getTableMeta(tableName);
      if (tableMeta == null) return;

      // Get expected values from the last flushed entry (if it has totalRecords/totalSizeInBytes)
      final expectedTotalRecords = lastEntry.totalRecords;
      final expectedTotalSize = lastEntry.totalSizeInBytes;
      final currentTotalRecords = tableMeta.totalRecords;
      final currentTotalSize = tableMeta.totalSizeInBytes;

      // Check if B+Tree structure fields need recovery (e.g., new partition created but metadata not updated)
      // If lastEntry.partitionNo >= tableMeta.btreePartitionCount, a new partition was created
      final needsBTreeRecovery =
          lastEntry.partitionNo >= tableMeta.btreePartitionCount;
      int? recoveredPartitionCount;
      int? recoveredNextPageNo;

      if (needsBTreeRecovery) {
        // New partition was created but metadata not updated, recover from last partition file
        final pageSize = tableMeta.btreePageSize;
        final lastPartitionNo = lastEntry.partitionNo;
        try {
          final lastPartitionPath = await _dataStore.pathManager
              .getPartitionFilePathByNo(tableName, lastPartitionNo);
          if (await _dataStore.storage.existsFile(lastPartitionPath)) {
            // Read last partition's meta page to get actual partition count
            final raw0 = await _dataStore.storage
                .readAsBytesAt(lastPartitionPath, 0, length: pageSize);
            if (raw0.isNotEmpty) {
              final parsed0 = BTreePageIO.parsePageBytes(raw0);
              if (parsed0.type == BTreePageType.meta) {
                final hdr =
                    PartitionMetaPage.tryDecodePayload(parsed0.encodedPayload);
                if (hdr != null && hdr.partitionNo == lastPartitionNo) {
                  // Recover B+Tree structure: partitionCount should be lastPartitionNo + 1
                  recoveredPartitionCount = lastPartitionNo + 1;
                  // btreeNextPageNo should be reset to 1 (pageNo=0 is reserved for PartitionMetaPage)
                  // but we don't know the actual value, so we'll use a safe default
                  // (it will be corrected on next write)
                  recoveredNextPageNo = 1;
                }
              }
            }
          }
        } catch (e) {
          Logger.warn(
            'Failed to recover B+Tree structure for $tableName from partition $lastPartitionNo: $e',
            label: 'ParallelJournalManager._recoverTableMaintenanceMetadata',
          );
        }
      }

      // Determine if metadata update is needed
      final hasCompleteStats =
          expectedTotalRecords != null && expectedTotalSize != null;
      final needsStatsUpdate = hasCompleteStats &&
          (expectedTotalRecords != currentTotalRecords ||
              expectedTotalSize != currentTotalSize);

      // Update metadata once if needed (combine stats and B+Tree structure updates)
      if (needsStatsUpdate || needsBTreeRecovery) {
        final updatedMeta = tableMeta.copyWith(
          // Update statistics if needed (needsStatsUpdate ensures non-null)
          totalRecords:
              needsStatsUpdate ? expectedTotalRecords : tableMeta.totalRecords,
          totalSizeInBytes:
              needsStatsUpdate ? expectedTotalSize : tableMeta.totalSizeInBytes,
          // Update B+Tree structure if needed
          btreePartitionCount:
              recoveredPartitionCount ?? tableMeta.btreePartitionCount,
          btreeNextPageNo: recoveredNextPageNo ?? tableMeta.btreeNextPageNo,
          timestamps: Timestamps(
            created: tableMeta.timestamps.created,
            modified: DateTime.now(),
          ),
        );
        await _dataStore.tableDataManager
            .updateTableMeta(tableName, updatedMeta);

        if (needsStatsUpdate && needsBTreeRecovery) {
          Logger.info(
            'Recovered maintenance batch metadata and B+Tree structure for $tableName: $expectedTotalRecords records (was $currentTotalRecords), $expectedTotalSize bytes (was $currentTotalSize), partitionCount=$recoveredPartitionCount (was ${tableMeta.btreePartitionCount})',
            label: 'ParallelJournalManager._recoverTableMaintenanceMetadata',
          );
        } else if (needsStatsUpdate) {
          Logger.info(
            'Recovered maintenance batch metadata for $tableName: $expectedTotalRecords records (was $currentTotalRecords), $expectedTotalSize bytes (was $currentTotalSize)',
            label: 'ParallelJournalManager._recoverTableMaintenanceMetadata',
          );
        } else if (needsBTreeRecovery) {
          Logger.info(
            'Recovered B+Tree structure for $tableName: partitionCount=$recoveredPartitionCount (was ${tableMeta.btreePartitionCount})',
            label: 'ParallelJournalManager._recoverTableMaintenanceMetadata',
          );
        }
      } else if (expectedTotalRecords != null && expectedTotalSize != null) {
        // Metadata is consistent, no need to update
        Logger.info(
          'Maintenance batch metadata for $tableName is already correct: $currentTotalRecords records, $currentTotalSize bytes (verified from last flushed partition ${lastEntry.partitionNo})',
          label: 'ParallelJournalManager._recoverTableMaintenanceMetadata',
        );
      } else {
        // Legacy entry without totalRecords/totalSizeInBytes, skip update
        Logger.info(
          'Skipping metadata update for $tableName: last flushed entry (partition ${lastEntry.partitionNo}) does not have complete statistics. Metadata will be corrected on next operation.',
          label: 'ParallelJournalManager._recoverTableMaintenanceMetadata',
        );
      }
    } catch (e, s) {
      Logger.error(
        'Failed to recover maintenance batch metadata for $tableName: $e\n$s',
        label: 'ParallelJournalManager._recoverTableMaintenanceMetadata',
      );
    }
  }

  /// Recover index metadata from maintenance batch
  Future<void> _recoverIndexMaintenanceMetadata(String tableName,
      String indexName, IndexPartitionFlushedEntry lastEntry) async {
    try {
      final indexMeta =
          await _dataStore.indexManager?.getIndexMeta(tableName, indexName);
      if (indexMeta == null) return;

      // Get expected values from the last flushed entry (if it has totalEntries/totalSizeInBytes)
      final expectedTotalEntries = lastEntry.totalEntries;
      final expectedTotalSize = lastEntry.totalSizeInBytes;
      final currentTotalEntries = indexMeta.totalEntries;
      final currentTotalSize = indexMeta.totalSizeInBytes;

      // Check if B+Tree structure fields need recovery (e.g., new partition created but metadata not updated)
      // If lastEntry.partitionNo >= indexMeta.btreePartitionCount, a new partition was created
      final needsBTreeRecovery =
          lastEntry.partitionNo >= indexMeta.btreePartitionCount;
      int? recoveredPartitionCount;
      int? recoveredNextPageNo;

      if (needsBTreeRecovery) {
        // New partition was created but metadata not updated, recover from last partition file
        final pageSize = indexMeta.btreePageSize;
        final lastPartitionNo = lastEntry.partitionNo;
        try {
          final lastPartitionPath = await _dataStore.pathManager
              .getIndexPartitionPathByNo(tableName, indexName, lastPartitionNo);
          if (await _dataStore.storage.existsFile(lastPartitionPath)) {
            // Read last partition's meta page to get actual partition count
            final raw0 = await _dataStore.storage
                .readAsBytesAt(lastPartitionPath, 0, length: pageSize);
            if (raw0.isNotEmpty) {
              final parsed0 = BTreePageIO.parsePageBytes(raw0);
              if (parsed0.type == BTreePageType.meta) {
                final hdr =
                    PartitionMetaPage.tryDecodePayload(parsed0.encodedPayload);
                if (hdr != null && hdr.partitionNo == lastPartitionNo) {
                  // Recover B+Tree structure: partitionCount should be lastPartitionNo + 1
                  recoveredPartitionCount = lastPartitionNo + 1;
                  // btreeNextPageNo should be reset to 1 (pageNo=0 is reserved for PartitionMetaPage)
                  // but we don't know the actual value, so we'll use a safe default
                  // (it will be corrected on next write)
                  recoveredNextPageNo = 1;
                }
              }
            }
          }
        } catch (e) {
          Logger.warn(
            'Failed to recover B+Tree structure for $tableName.$indexName from partition $lastPartitionNo: $e',
            label: 'ParallelJournalManager._recoverIndexMaintenanceMetadata',
          );
        }
      }

      // Determine if metadata update is needed
      final hasCompleteStats =
          expectedTotalEntries != null && expectedTotalSize != null;
      final needsStatsUpdate = hasCompleteStats &&
          (expectedTotalEntries != currentTotalEntries ||
              expectedTotalSize != currentTotalSize);

      // Update metadata once if needed (combine stats and B+Tree structure updates)
      if (needsStatsUpdate || needsBTreeRecovery) {
        final updatedMeta = indexMeta.copyWith(
          // Update statistics if needed (needsStatsUpdate ensures non-null)
          totalEntries:
              needsStatsUpdate ? expectedTotalEntries : indexMeta.totalEntries,
          totalSizeInBytes:
              needsStatsUpdate ? expectedTotalSize : indexMeta.totalSizeInBytes,
          // Update B+Tree structure if needed
          btreePartitionCount:
              recoveredPartitionCount ?? indexMeta.btreePartitionCount,
          btreeNextPageNo: recoveredNextPageNo ?? indexMeta.btreeNextPageNo,
          timestamps: Timestamps(
            created: indexMeta.timestamps.created,
            modified: DateTime.now(),
          ),
        );
        await _dataStore.indexManager?.updateIndexMeta(
          tableName: tableName,
          indexName: indexName,
          updatedMeta: updatedMeta,
          flush: false,
        );

        if (needsStatsUpdate && needsBTreeRecovery) {
          Logger.info(
            'Recovered maintenance batch metadata and B+Tree structure for $tableName.$indexName: $expectedTotalEntries entries (was $currentTotalEntries), $expectedTotalSize bytes (was $currentTotalSize), partitionCount=$recoveredPartitionCount (was ${indexMeta.btreePartitionCount})',
            label: 'ParallelJournalManager._recoverIndexMaintenanceMetadata',
          );
        } else if (needsStatsUpdate) {
          Logger.info(
            'Recovered maintenance batch metadata for $tableName.$indexName: $expectedTotalEntries entries (was $currentTotalEntries), $expectedTotalSize bytes (was $currentTotalSize)',
            label: 'ParallelJournalManager._recoverIndexMaintenanceMetadata',
          );
        } else if (needsBTreeRecovery) {
          Logger.info(
            'Recovered B+Tree structure for $tableName.$indexName: partitionCount=$recoveredPartitionCount (was ${indexMeta.btreePartitionCount})',
            label: 'ParallelJournalManager._recoverIndexMaintenanceMetadata',
          );
        }
      } else if (expectedTotalEntries != null && expectedTotalSize != null) {
        // Metadata is consistent, no need to update
        Logger.info(
          'Maintenance batch metadata for $tableName.$indexName is already correct: $currentTotalEntries entries, $currentTotalSize bytes (verified from last flushed partition ${lastEntry.partitionNo})',
          label: 'ParallelJournalManager._recoverIndexMaintenanceMetadata',
        );
      } else {
        // Legacy entry without totalEntries/totalSizeInBytes, skip update
        Logger.info(
          'Skipping metadata update for $tableName.$indexName: last flushed entry (partition ${lastEntry.partitionNo}) does not have complete statistics. Metadata will be corrected on next operation.',
          label: 'ParallelJournalManager._recoverIndexMaintenanceMetadata',
        );
      }
    } catch (e, s) {
      Logger.error(
        'Failed to recover maintenance batch metadata for $tableName.$indexName: $e\n$s',
        label: 'ParallelJournalManager._recoverIndexMaintenanceMetadata',
      );
    }
  }

  Future<Future<void> Function()?> _recoverPendingBatch(
      PendingParallelBatch batch) async {
    try {
      if (batch.batchType == BatchType.maintenance) {
        // Same as flush: replay page redo log first so any half-written pages
        // (including new partitions/splits) are fixed before metadata recovery.
        // Metadata recovery then uses journal + disk (last partition file) and
        // stays consistent with the replayed data.
        await _replayPageRedoLogIfExists(batch.batchId);
        // Recover metadata updates for maintenance batches
        await _recoverMaintenanceBatch(batch);

        await appendJournalEntry(BatchCompletedEntry(
            at: DateTime.now().toIso8601String(),
            batchId: batch.batchId,
            batchType: BatchType.maintenance));
        await _walManager.removePendingParallelBatch(batch.batchId);
        await _deletePageRedoLogIfExists(batch.batchId);
        await _maybeRotateParallelJournal();
        try {
          await _flushRecoveryArtifactsIfNeeded();
        } catch (_) {}
        return null;
      }

      final scanResult = await _scanBatchJournalStatus(batch);

      // If batch is already marked completed in journal, just remove from pending and skip replay.
      // This handles case where crash occurred after Journal update but before WAL meta cleanup.
      if (scanResult.isCompleted) {
        await _walManager.removePendingParallelBatch(batch.batchId);
        await _deletePageRedoLogIfExists(batch.batchId);
        await _maybeRotateParallelJournal();
        try {
          await _flushRecoveryArtifactsIfNeeded();
        } catch (_) {}
        return null;
      }

      final _BatchWalData walData = await _collectBatchWalChanges(batch);
      // Populate tablePlans from scanResult for repair
      walData.tablePlans.addAll(scanResult.tablePlans);

      final maxIds = <String, int>{};
      int count = 0;
      // Iterate in exact WAL order so buffer queue order matches normal flush;
      // then pop(captureCount) yields exactly this batch (all tables, no partial-table loss).
      for (final item in walData.orderedOpsInWalOrder) {
        final table = item.table;
        final op = item.op;
        if (op.walPointer == null) continue;
        final schema = await _dataStore.schemaManager?.getTableSchema(table);
        if (schema == null) continue;
        final pkName = schema.primaryKey;
        final pkValue = op.data[pkName]?.toString();
        if (pkValue == null) continue;

        final be = BufferEntry(
          data: op.data,
          operation: op.op,
          timestamp: DateTime.now(),
          oldValues: op.oldValues,
          walPointer: op.walPointer,
        );

        final uniqueKeys = await _computeUniqueKeyRefs(table, op.data);

        await _dataStore.tableDataManager.recoverRecordToBuffer(
          table,
          op.data,
          op.op,
          entry: be,
          uniqueKeyRefs: uniqueKeys,
          oldValues: op.oldValues,
          // Always update memory stats during recovery replay so that
          // memory total counts are correct before the recovery flush starts.
          updateStats: true,
        );

        // Track maxId for batch update
        if (schema.primaryKeyConfig.type == PrimaryKeyType.sequential &&
            op.op == BufferOperationType.insert) {
          final id = int.tryParse(pkValue) ?? 0;
          final currentMax = maxIds[table] ?? 0;
          if (id > currentMax) {
            maxIds[table] = id;
          }
        }
        count++;
      }

      // Batch update maxId
      for (final table in maxIds.keys) {
        await _dataStore.tableDataManager
            .updateMaxIdInMemory(table, maxIds[table], updateFileMeta: false);
      }

      // Return a task to flush this specific batch and repair statistics if needed.
      final captureCount = count;
      final captureBatchId = batch.batchId;
      final captureBatchType = batch.batchType;
      // Capture all tables involved in this batch for post-flush repair check.
      final captureBatchTables = walData.orderedOpsByTable.keys.toSet();
      // Capture tables/indexes already marked as flushed (metadata updated).
      final captureFlushedTables = scanResult.flushedTables;
      final captureFlushedIndexes = scanResult.flushedIndexes;
      // were NOT marked with TableMetaUpdatedEntry/IndexMetaUpdatedEntry.
      // This ensures metadata is consistent with actual B+Tree data.
      await _repairUnflushedTablesAndIndexes(
        batchTables: captureBatchTables,
        flushedTables: captureFlushedTables,
        flushedIndexes: captureFlushedIndexes,
        walData: walData,
        batchCreatedAt: batch.createdAt,
      );

      return () async {
        if (!_running) return;
        _flushInProgress = true;
        try {
          await _replayPageRedoLogIfExists(captureBatchId);
          await _pumpFlush(
            drainCompletely: false, // will just pop the batch we added
            recoveryBatchContext: BatchContext(
              batchId: captureBatchId,
              batchType: captureBatchType,
            ),
            batchSizeOverride:
                captureCount, // Ensure we take everything we just added
          );
        } finally {
          _flushInProgress = false;
        }
      };
    } catch (e, s) {
      Logger.error('Recover pending batch failed: $e\n$s',
          label: 'ParallelJournalManager._recoverPendingBatch');
      return null;
    } finally {
      _activeBatchContext = null;
    }
  }

  /// Repair statistics for tables/indexes that were NOT marked with
  /// TableMetaUpdatedEntry/IndexMetaUpdatedEntry during recovery.
  ///
  /// This handles the case where pages were written but metadata update
  /// was not journaled before crash.
  Future<void> _repairUnflushedTablesAndIndexes({
    required Set<String> batchTables,
    required Set<String> flushedTables,
    required Map<String, Set<String>> flushedIndexes,
    required _BatchWalData walData,
    required String batchCreatedAt,
  }) async {
    try {
      // Find tables that were in the batch but NOT marked as meta-updated.
      final unflushedTables = batchTables.difference(flushedTables);

      // Repair table totals using batch-level base values.
      for (final tableName in unflushedTables) {
        Logger.debug('Restoring unflushed table base totals: $tableName',
            label: 'ParallelJournalManager._repairUnflushedTablesAndIndexes');
        try {
          final plan = walData.tablePlans[tableName];
          if (plan == null ||
              plan.baseTotalRecords == null ||
              plan.baseTotalSizeInBytes == null) {
            continue;
          }

          final meta =
              await _dataStore.tableDataManager.getTableMeta(tableName);
          if (meta == null) continue;

          // Restore to the state BEFORE the batch.
          // The subsequent recover-flush (writeChanges) will re-apply the batch incrementally,
          // while startup queries use Disk Meta (Base) + Memory Buffer (Replayed) for accuracy.
          final updated = meta.copyWith(
            totalRecords: plan.baseTotalRecords!,
            totalSizeInBytes: plan.baseTotalSizeInBytes!,
            timestamps: Timestamps(
                created: meta.timestamps.created, modified: DateTime.now()),
          );

          await _dataStore.tableDataManager.updateTableMeta(
            tableName,
            updated,
            flush: true,
          );
        } catch (e) {
          Logger.warn('Failed to restore table $tableName base totals: $e',
              label: 'ParallelJournalManager._repairUnflushedTablesAndIndexes');
        }
      }

      // Repair index totals using batch-level base values.
      for (final tableName in batchTables) {
        final schema =
            await _dataStore.schemaManager?.getTableSchema(tableName);
        if (schema == null) continue;

        final allIndexes = schema
            .getAllIndexes()
            .map((i) => i.actualIndexName)
            .toList(growable: false);
        if (allIndexes.isEmpty) continue;

        final flushedForTable = flushedIndexes[tableName] ?? const <String>{};
        final plan = walData.tablePlans[tableName];
        if (plan == null) continue;

        for (final indexName in allIndexes) {
          if (flushedForTable.contains(indexName)) continue;

          Logger.debug(
              'Restoring unflushed index base totals: $tableName.$indexName',
              label: 'ParallelJournalManager._repairUnflushedTablesAndIndexes');
          try {
            final baseEntries = plan.baseIndexTotalEntries?[indexName];
            final baseSize = plan.baseIndexTotalSizeInBytes?[indexName];
            if (baseEntries == null || baseSize == null) continue;

            final idxMeta = await _dataStore.indexManager
                ?.getIndexMeta(tableName, indexName);
            if (idxMeta == null) continue;

            // Restore index meta to its base (pre-batch) state.
            final updated = idxMeta.copyWith(
              totalEntries: baseEntries,
              totalSizeInBytes: baseSize,
              timestamps: Timestamps(
                  created: idxMeta.timestamps.created,
                  modified: DateTime.now()),
            );

            await _dataStore.indexManager?.updateIndexMeta(
              tableName: tableName,
              indexName: indexName,
              updatedMeta: updated,
              flush: true,
            );
          } catch (e) {
            Logger.warn(
                'Failed to restore index $tableName.$indexName base totals: $e',
                label:
                    'ParallelJournalManager._repairUnflushedTablesAndIndexes');
          }
        }
      }
    } catch (e, s) {
      Logger.error('Failed to repair unflushed tables/indexes: $e\n$s',
          label: 'ParallelJournalManager._repairUnflushedTablesAndIndexes');
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
    final Map<String, List<Map<String, dynamic>>> inserts = {};
    final Map<String, List<Map<String, dynamic>>> updates = {};
    final Map<String, List<Map<String, dynamic>>> deletes = {};
    final Map<String, List<_WalOp>> ordered = {};
    // Same ops in exact WAL order so recovery push order matches normal flush pop order.
    final List<({String table, _WalOp op})> orderedOpsInWalOrder = [];

    try {
      // Precompute table-level WAL cutoff pointers from WAL meta (clear/drop ops)
      final Map<String, List<WalPointer>> tableCutoffs =
          <String, List<WalPointer>>{};
      try {
        for (final op in _walManager.tableOps.values) {
          tableCutoffs
              .putIfAbsent(op.table, () => <WalPointer>[])
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
          final entries = await WalEncoder.decodeFile(fileBytes, p);

          // Process each entry
          final yieldController =
              YieldController('ParallelJournalManager._collectBatchWalChanges');
          for (final entry in entries) {
            await yieldController.maybeYield();
            seq++;
            if (first && seq < toSkip) continue;

            final table = entry['table'] as String?;
            final data = (entry['data'] as Map?)?.cast<String, dynamic>();
            final oldValues =
                (entry['oldValues'] as Map?)?.cast<String, dynamic>();
            final opIdx = entry['op'] as int?;
            if (table == null || data == null || opIdx == null) continue;
            // Skip WAL entries that are logically before a clear/drop cutoff
            // for this table.
            final cutoffs = tableCutoffs[table];
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
                (inserts.putIfAbsent(table, () => <Map<String, dynamic>>[]))
                    .add(data);
                walOp = _WalOp(op, data, walPointer: walPtr);
                (ordered.putIfAbsent(table, () => <_WalOp>[])).add(walOp);
                orderedOpsInWalOrder.add((table: table, op: walOp));
                break;
              case BufferOperationType.update:
                (updates.putIfAbsent(table, () => <Map<String, dynamic>>[]))
                    .add(data);
                walOp =
                    _WalOp(op, data, oldValues: oldValues, walPointer: walPtr);
                (ordered.putIfAbsent(table, () => <_WalOp>[])).add(walOp);
                orderedOpsInWalOrder.add((table: table, op: walOp));
                break;
              case BufferOperationType.delete:
                (deletes.putIfAbsent(table, () => <Map<String, dynamic>>[]))
                    .add(data);
                walOp = _WalOp(op, data, walPointer: walPtr);
                (ordered.putIfAbsent(table, () => <_WalOp>[])).add(walOp);
                orderedOpsInWalOrder.add((table: table, op: walOp));
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
    } catch (e, s) {
      Logger.error('collect WAL for batch failed: $e\n$s',
          label: 'ParallelJournalManager');
    }
    return _BatchWalData(
      insertsByTable: inserts,
      updatesByTable: updates,
      deletesByTable: deletes,
      orderedOpsByTable: ordered,
      orderedOpsInWalOrder: orderedOpsInWalOrder,
    );
  }

  /// Begin an ad-hoc batch for table maintenance (e.g., processTablePartitions) so recovery can reconcile partial progress.
  Future<BatchContext> beginMaintenanceBatch({required String table}) async {
    if (!_dataStore.config.enableJournal) return BatchContext.maintenance('');
    // Register pending maintenance batch
    String batchId = GlobalIdGenerator.generate('maint_batch_');
    final batchContext = BatchContext.maintenance(batchId);
    try {
      final active = _walManager.meta.activeParallelJournal;
      final path = active == 'A'
          ? _dataStore.pathManager
              .getParallelJournalAPath(spaceName: _dataStore.currentSpaceName)
          : _dataStore.pathManager
              .getParallelJournalBPath(spaceName: _dataStore.currentSpaceName);
      final size = await _dataStore.storage.getFileSize(path);
      await _walManager.addPendingParallelBatch(PendingParallelBatch(
        batchId: batchId,
        batchType: BatchType.maintenance,
        journalFile: active,
        recoverStartOffset: size,
        start: const WalPointer(partitionIndex: -1, entrySeq: -1),
        end: const WalPointer(partitionIndex: -1, entrySeq: -1),
        tables: <String>[table],
        createdAt: DateTime.now().toIso8601String(),
      ));
    } catch (_) {}
    // Build minimal plan and table plan metadata
    final Map<String, Map<int, int>> planned = {
      table: {BufferOperationType.update.index: 0},
    };
    // Capture base totals so recovery can safely restore to "before maintenance batch".
    final schema = await _dataStore.schemaManager?.getTableSchema(table);
    final tableMeta = await _dataStore.tableDataManager.getTableMeta(table);
    final indexNames = <String>[];
    final baseIndexTotalEntries = <String, int>{};
    final baseIndexTotalSizeInBytes = <String, int>{};
    try {
      if (schema != null) {
        for (final idx in schema.getAllIndexes()) {
          final idxName = idx.actualIndexName;
          indexNames.add(idxName);
          final idxMeta =
              await _dataStore.indexManager?.getIndexMeta(table, idxName);
          if (idxMeta != null) {
            baseIndexTotalEntries[idxName] = idxMeta.totalEntries;
            baseIndexTotalSizeInBytes[idxName] = idxMeta.totalSizeInBytes;
          }
        }
      }
    } catch (_) {}
    final Map<String, TablePlan> tablePlan = {
      table: TablePlan(
        willUpdateTableMeta: true,
        indexes: indexNames,
        willUpdateIndexMeta: indexNames.isNotEmpty,
        baseTotalRecords: tableMeta?.totalRecords,
        baseTotalSizeInBytes: tableMeta?.totalSizeInBytes,
        baseIndexTotalEntries: baseIndexTotalEntries,
        baseIndexTotalSizeInBytes: baseIndexTotalSizeInBytes,
      ),
    };

    // Use pseudo WAL pointers to indicate ad-hoc batch (no WAL range)
    final entry = BatchStartEntry(
      at: DateTime.now().toIso8601String(),
      start: const WalPointerRef(partitionIndex: -1, entrySeq: -1),
      end: const WalPointerRef(partitionIndex: -1, entrySeq: -1),
      size: 0,
      plan: planned,
      tablePlan: tablePlan,
      batchId: batchId,
      batchType: BatchType.maintenance,
    );
    await appendJournalEntry(entry);
    return batchContext;
  }

  // Complete the ad-hoc batch, persist offsets and rotate journal if needed.
  Future<void> completeMaintenanceBatch({BatchContext? batchContext}) async {
    if (!_dataStore.config.enableJournal) return;
    try {
      // Use provided batchContext or find latest maintenance pending batch
      String? batchId;
      if (batchContext != null) {
        batchId = batchContext.batchId;
      } else {
        // Fallback: find latest maintenance pending batch (for backward compatibility)
        final pending = _walManager.meta.pendingBatches
            .where((b) => b.batchType == BatchType.maintenance)
            .toList();
        final current = pending.isNotEmpty ? pending.last : null;
        batchId = current?.batchId;
      }

      if (batchId != null && batchId.isNotEmpty) {
        await appendJournalEntry(BatchCompletedEntry(
            at: DateTime.now().toIso8601String(),
            batchId: batchId,
            batchType: BatchType.maintenance));
        await _walManager.removePendingParallelBatch(batchId);
        await _deletePageRedoLogIfExists(batchId);
      }
      await _maybeRotateParallelJournal();
      // Durability flush policy at batch end
      try {
        await _flushRecoveryArtifactsIfNeeded();
      } catch (_) {}
    } catch (e, s) {
      Logger.error('Failed to complete ad-hoc batch: $e\n$s',
          label: 'ParallelJournalManager');
    }
    _activeBatchContext = null;
  }

  /// Replay page redo log for [batchId] if it exists and has content.
  /// Writes each (path, offset, payload) from the log so recovery does not read possibly corrupted pages.
  ///
  /// Redo log contains **intended page images** (what the batch was about to write), not "before" images,
  /// so we always correct to latest. Consistency: for **flush**, metadata is restored to "before batch"
  /// and then [_pumpFlush] re-runs the batch (same pages written again, meta updated). For **maintenance**,
  /// we replay redo first so disk matches intended content, then [_recoverMaintenanceBatch] recovers
  /// metadata from journal + last partition file on disk, so meta aligns with replayed data.
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
      String table,
      String index,
      int partitionNo
    }),
        Map<int, Uint8List>>{};
    final treeMeta = <({PageRedoTreeKind kind, String table, String index}),
        PageRedoTreeMetaRecord>{};
    const yieldInterval = 50;
    final parseYc = YieldController(
        'ParallelJournalManager._replayPageRedoLog.parse',
        checkInterval: yieldInterval);
    while (pos < bytes.length) {
      await parseYc.maybeYield();
      final rec = PageRedoLogCodec.decodeRecord(bytes, pos);
      if (rec == null) break;
      pos = rec.nextStart;
      if (rec is PageRedoPageRecord) {
        final key = (
          kind: rec.treeKind,
          table: rec.tableName,
          index: rec.indexName ?? '',
          partitionNo: rec.partitionNo,
        );
        byPartition.putIfAbsent(key, () => <int, Uint8List>{})[rec.pageNo] =
            rec.payload;
      } else if (rec is PageRedoTreeMetaRecord) {
        final key = (
          kind: rec.treeKind,
          table: rec.tableName,
          index: rec.indexName ?? '',
        );
        treeMeta[key] = rec;
      }
    }
    final writeYc = YieldController(
        'ParallelJournalManager._replayPageRedoLog.write',
        checkInterval: 5);
    for (final e in byPartition.entries) {
      await writeYc.maybeYield();
      final key = e.key;
      final pages = e.value;
      if (pages.isEmpty) continue;
      if (key.kind == PageRedoTreeKind.indexTree && key.index.isEmpty) continue;

      String path;
      try {
        if (key.kind == PageRedoTreeKind.table) {
          path = await _dataStore.pathManager
              .getPartitionFilePathByNo(key.table, key.partitionNo);
        } else {
          path = await _dataStore.pathManager
              .getIndexPartitionPathByNo(key.table, key.index, key.partitionNo);
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
    }

    // Apply tree metadata snapshots after pages are restored.
    if (treeMeta.isNotEmpty) {
      final metaYc = YieldController(
        'ParallelJournalManager._replayPageRedoLog.meta',
        checkInterval: 5,
      );
      for (final rec in treeMeta.values) {
        await metaYc.maybeYield();
        try {
          if (rec.treeKind == PageRedoTreeKind.table) {
            final meta =
                await _dataStore.tableDataManager.getTableMeta(rec.tableName);
            if (meta == null) continue;
            final updated = meta.copyWith(
              btreePageSize: rec.btreePageSize,
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
                .updateTableMeta(rec.tableName, updated, flush: true);
          } else {
            final idxName = rec.indexName;
            if (idxName == null || idxName.isEmpty) continue;
            final meta = await _dataStore.indexManager
                ?.getIndexMeta(rec.tableName, idxName);
            if (meta == null) continue;
            final updated = meta.copyWith(
              btreePageSize: rec.btreePageSize,
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
              tableName: rec.tableName,
              indexName: idxName,
              updatedMeta: updated,
              flush: true,
            );
          }
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

  /// Scan journal to find batch status, flushed tables, and flushed indexes.
  Future<_BatchJournalScanResult> _scanBatchJournalStatus(
      PendingParallelBatch batch) async {
    final flushedTables = <String>{};
    final flushedIndexes = <String, Set<String>>{}; // table -> indexes
    final tablePlans = <String, TablePlan>{};
    bool isCompleted = false;
    final path = batch.journalFile == 'A'
        ? _dataStore.pathManager
            .getParallelJournalAPath(spaceName: _dataStore.currentSpaceName)
        : _dataStore.pathManager
            .getParallelJournalBPath(spaceName: _dataStore.currentSpaceName);

    try {
      if (!await _dataStore.storage.existsFile(path)) {
        return _BatchJournalScanResult(
          isCompleted: isCompleted,
          flushedTables: flushedTables,
          flushedIndexes: flushedIndexes,
          tablePlans: tablePlans,
        );
      }

      // Scan journal from recoverStartOffset
      final stream = _dataStore.storage
          .readLinesStream(path, offset: batch.recoverStartOffset);

      final yieldController =
          YieldController('ParallelJournalManager._scanBatchJournalStatus');

      await for (final line in stream) {
        await yieldController.maybeYield();
        if (line.isEmpty) continue;
        try {
          final json = jsonDecode(line);
          final entry = ParallelJournalEntry.fromJson(json);
          if (entry == null) continue;

          if (entry is BatchStartEntry && entry.batchId == batch.batchId) {
            tablePlans.addAll(entry.tablePlan);
          } else if (entry is BatchCompletedEntry &&
              entry.batchId == batch.batchId) {
            isCompleted = true;
          } else if (entry is TableMetaUpdatedEntry &&
              entry.batchId == batch.batchId) {
            flushedTables.add(entry.table);
          } else if (entry is IndexMetaUpdatedEntry &&
              entry.batchId == batch.batchId) {
            flushedIndexes
                .putIfAbsent(entry.table, () => <String>{})
                .add(entry.index);
          }
        } catch (_) {}
      }
    } catch (_) {}
    return _BatchJournalScanResult(
      isCompleted: isCompleted,
      flushedTables: flushedTables,
      flushedIndexes: flushedIndexes,
      tablePlans: tablePlans,
    );
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
      final active = _walManager.meta.activeParallelJournal;
      final journalPath = active == 'A'
          ? _dataStore.pathManager
              .getParallelJournalAPath(spaceName: _dataStore.currentSpaceName)
          : _dataStore.pathManager
              .getParallelJournalBPath(spaceName: _dataStore.currentSpaceName);
      try {
        await _dataStore.storage.flushAll(path: walPath);
      } catch (_) {}
      try {
        await _dataStore.storage.flushAll(path: walMetaPath);
      } catch (_) {}
      try {
        await _dataStore.storage.flushAll(path: journalPath);
      } catch (_) {}
    } catch (_) {}
  }

  Future<List<UniqueKeyRef>> _computeUniqueKeyRefs(
      String table, Map<String, dynamic> data) async {
    final refs = <UniqueKeyRef>[];
    try {
      final schema = await _dataStore.schemaManager?.getTableSchema(table);
      if (schema == null) return refs;

      // Unique indexes from schema (implicit/explicit)
      for (final idx in schema.getAllIndexes()) {
        if (!idx.unique) continue;
        // Skip primary key check usually not needed if getAllIndexes doesn't include it or if we handle it
        if (idx.fields.length == 1 && idx.fields.first == schema.primaryKey) {
          continue;
        }
        final ck = schema.createCanonicalIndexKey(idx.fields, data);
        if (ck == null) continue;
        refs.add(UniqueKeyRef(idx.actualIndexName, ck));
      }
    } catch (_) {}
    return refs;
  }

  /// Preferred typed API for appending journal entries
  Future<void> appendJournalEntry(ParallelJournalEntry entry) async {
    final active = _walManager.meta.activeParallelJournal;
    final path = active == 'A'
        ? _dataStore.pathManager
            .getParallelJournalAPath(spaceName: _dataStore.currentSpaceName)
        : _dataStore.pathManager
            .getParallelJournalBPath(spaceName: _dataStore.currentSpaceName);
    try {
      final root = _dataStore.pathManager
          .getParallelJournalRootPath(spaceName: _dataStore.currentSpaceName);
      await _dataStore.storage.ensureDirectoryExists(root);

      // Ensure batchId/batchType fields exist for multi-batch recovery
      final Map<String, dynamic> json = entry.toJson();
      final activeContext = _activeBatchContext;
      if (!json.containsKey('batchId')) {
        if (entry is BatchStartEntry) {
          json['batchId'] = entry.batchId;
        } else if (entry is BatchCompletedEntry)
          // ignore: curly_braces_in_flow_control_structures
          json['batchId'] = entry.batchId ?? (activeContext?.batchId ?? '');
        else if (entry is TaskDoneEntry)
          // ignore: curly_braces_in_flow_control_structures
          json['batchId'] = entry.batchId ?? (activeContext?.batchId ?? '');
        else if (entry is TablePartitionFlushedEntry)
          // ignore: curly_braces_in_flow_control_structures
          json['batchId'] = entry.batchId;
        else if (entry is TableMetaUpdatedEntry)
          // ignore: curly_braces_in_flow_control_structures
          json['batchId'] = entry.batchId ?? (activeContext?.batchId ?? '');
        else if (entry is IndexPartitionFlushedEntry)
          // ignore: curly_braces_in_flow_control_structures
          json['batchId'] = entry.batchId;
        else if (entry is IndexMetaUpdatedEntry)
          // ignore: curly_braces_in_flow_control_structures
          json['batchId'] = entry.batchId ?? (activeContext?.batchId ?? '');
        else
          // ignore: curly_braces_in_flow_control_structures
          json['batchId'] = activeContext?.batchId ?? '';
      }
      if (!json.containsKey('batchType')) {
        if (entry is BatchStartEntry) {
          json['batchType'] = entry.batchType.value;
        } else if (entry is BatchCompletedEntry)
          // ignore: curly_braces_in_flow_control_structures
          json['batchType'] = entry.batchType?.value ??
              (activeContext?.batchType.value ?? BatchType.flush.value);
        else if (entry is TaskDoneEntry)
          // ignore: curly_braces_in_flow_control_structures
          json['batchType'] = entry.batchType?.value ??
              (activeContext?.batchType.value ?? BatchType.flush.value);
        else if (entry is TablePartitionFlushedEntry)
          // ignore: curly_braces_in_flow_control_structures
          json['batchType'] = entry.batchType.value;
        else if (entry is TableMetaUpdatedEntry)
          // ignore: curly_braces_in_flow_control_structures
          json['batchType'] = entry.batchType?.value ??
              (activeContext?.batchType.value ?? BatchType.flush.value);
        else if (entry is IndexPartitionFlushedEntry)
          // ignore: curly_braces_in_flow_control_structures
          json['batchType'] = entry.batchType.value;
        else if (entry is IndexMetaUpdatedEntry)
          // ignore: curly_braces_in_flow_control_structures
          json['batchType'] = entry.batchType?.value ??
              (activeContext?.batchType.value ?? BatchType.flush.value);
        else
          // ignore: curly_braces_in_flow_control_structures
          json['batchType'] =
              activeContext?.batchType.value ?? BatchType.flush.value;
      }
      await _dataStore.storage.writeAsString(path, '${jsonEncode(json)}\n',
          append: true, flush: false);
    } catch (e) {
      Logger.error('Failed to append parallel journal: $e',
          label: 'ParallelJournalManager');
    }
  }

  Future<void> _maybeRotateParallelJournal() async {
    if (_walManager.hasPendingParallelBatches) return;
    final active = _walManager.meta.activeParallelJournal;
    final currentPath = active == 'A'
        ? _dataStore.pathManager
            .getParallelJournalAPath(spaceName: _dataStore.currentSpaceName)
        : _dataStore.pathManager
            .getParallelJournalBPath(spaceName: _dataStore.currentSpaceName);
    try {
      final size = await _dataStore.storage.getFileSize(currentPath);
      if (size >= _dataStore.config.parallelJournalMaxFileSize) {
        // Rotate A/B and close handle for the old (now inactive) file
        await _walManager.rotateParallelJournalActive();
        try {
          await _dataStore.storage
              .flushAll(path: currentPath, closeHandles: true);
        } catch (_) {}
      }
    } catch (_) {
      // ignore
    }
  }
}

/// Result of scanning batch journal for status, flushed tables, and flushed indexes.
class _BatchJournalScanResult {
  final bool isCompleted;

  /// Tables whose metadata has been successfully updated (TableMetaUpdatedEntry).
  final Set<String> flushedTables;

  /// Indexes whose metadata has been successfully updated (IndexMetaUpdatedEntry).
  ///
  /// Map: `tableName -> Set<indexName>`
  final Map<String, Set<String>> flushedIndexes;

  /// Table plans found in BatchStartEntry
  final Map<String, TablePlan> tablePlans;

  _BatchJournalScanResult({
    required this.isCompleted,
    required this.flushedTables,
    required this.flushedIndexes,
    this.tablePlans = const {},
  });
}

class _BatchWalData {
  final Map<String, List<Map<String, dynamic>>> insertsByTable;
  final Map<String, List<Map<String, dynamic>>> updatesByTable;
  final Map<String, List<Map<String, dynamic>>> deletesByTable;
  // Preserve ordered operations per table for coalescing within a batch
  final Map<String, List<_WalOp>> orderedOpsByTable;

  /// Same ops in exact WAL (partition+seq) order so recovery push order
  /// matches normal flush pop order and pop(captureCount) yields this batch.
  final List<({String table, _WalOp op})> orderedOpsInWalOrder;
  // Table plans for precise repair
  final Map<String, TablePlan> tablePlans = {};

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

class WalDecodeRequest {
  final Uint8List fileBytes;
  final int partitionIndex;
  final EncoderConfig encoderConfig;

  WalDecodeRequest({
    required this.fileBytes,
    required this.partitionIndex,
    required this.encoderConfig,
  });
}

Future<List<Map<String, dynamic>>> _walDecodeTask(
    WalDecodeRequest request) async {
  EncoderHandler.setEncodingState(request.encoderConfig);
  return WalEncoder.decodeFile(request.fileBytes, request.partitionIndex);
}

class _WalRange {
  final WalPointer start;
  final WalPointer end;
  _WalRange(this.start, this.end);
}
