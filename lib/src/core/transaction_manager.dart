import 'dart:convert';

import '../handler/logger.dart';
import '../handler/txn_encoder.dart';
import '../model/buffer_entry.dart';
import '../model/data_store_config.dart';
import '../model/id_generator.dart';
import '../model/table_context.dart';
import '../model/table_identity.dart';
import '../model/table_schema.dart';
import '../model/transaction_models.dart';
import '../query/query_condition.dart';
import 'crontab_manager.dart';
import 'data_store_impl.dart';
// common utilities may be used by callers; keep imports minimal here
import 'transaction_context.dart';
import 'tree_cache.dart';
import 'write_buffer_manager.dart';
import 'yield_controller.dart';

/// Transaction manager: append-only per-partition logs with compact meta
class TransactionManager {
  final DataStoreImpl _dataStore;
  DataStoreConfig get _config => _dataStore.config;
  bool get _isMemoryMode => _config.persistenceMode == PersistenceMode.memory;

  TransactionMainMeta? _mainMetaCache;
  final Map<int, TransactionPartitionMeta> _partitionMetaCache = {};
  final Set<String> _activeTransactions = <String>{};

  // In-memory cache of transaction final status to avoid repeated file scans.
  // true => committed, false => rolled back. Absence => unknown/not finalized.
  final Map<String, bool> _txnStatusCache = <String, bool>{};

  // Track per-transaction write-set for SSI: txId -> { tableUid -> Set<pk> }
  final Map<String, Map<String, Set<String>>> _txnWriteSets =
      <String, Map<String, Set<String>>>{};
  // Recently committed write index for SSI: [tableUid, pk] -> lastCommitTimeMillis
  // Using TreeCache for automatic LRU eviction in large-scale data scenarios
  late final TreeCache<int> _recentCommittedWrites;

  // In-memory log size cache to avoid frequent filesystem size calls
  Map<String, int>? _logSizeCache;

  // Deferred heavy delete plans per transaction
  final Map<String, List<HeavyDeletePlan>> _txnHeavyDeletes =
      <String, List<HeavyDeletePlan>>{};

  // Deferred heavy update plans per transaction
  final Map<String, List<HeavyUpdatePlan>> _txnHeavyUpdates =
      <String, List<HeavyUpdatePlan>>{};

  // Deferred cascade delete operations per transaction
  // Structure: Map<txId, List<CascadeDeleteOp>>
  // Each CascadeDeleteOp represents a table record deletion that requires cascade delete
  final Map<String, List<_CascadeDeleteOp>> _txnCascadeDeletes =
      <String, List<_CascadeDeleteOp>>{};

  // Deferred cascade update operations per transaction
  // Structure: Map<txId, List<CascadeUpdateOp>>
  // Each CascadeUpdateOp represents a primary key update that requires cascade update
  final Map<String, List<_CascadeUpdateOp>> _txnCascadeUpdates =
      <String, List<_CascadeUpdateOp>>{};

  TransactionManager(this._dataStore);
  bool _cleanupRegistered = false;
  int _lastPeriodicCleanupMs = 0;
  bool _cleanupRunning = false;
  Function()? _cleanupCallback;

  /// Dispose transaction manager and remove crontab callbacks
  void dispose() {
    if (_cleanupCallback != null) {
      CrontabManager.removeCallback(
          ExecuteInterval.minutes5, _cleanupCallback!);
      _cleanupCallback = null;
    }
    _cleanupRegistered = false;
    _activeTransactions.clear();
    _txnStatusCache.clear();
    _txnWriteSets.clear();
    _recentCommittedWrites.clear();
    _logSizeCache?.clear();
    _txnHeavyDeletes.clear();
    _txnHeavyUpdates.clear();
    _txnCascadeDeletes.clear();
    _txnCascadeUpdates.clear();
  }

  /// Periodic cleanup of transaction-related in-memory metadata
  Future<void> periodicCleanup({int? nowMs, int? ttlMs}) async {
    if (_cleanupRunning) return;
    _cleanupRunning = true;
    try {
      final int now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
      final int ttl = ttlMs ?? _dataStore.config.transactionMetaTtlMs;

      // Clean txn status cache by TTL (size guard)
      try {
        if (_txnStatusCache.length > 20000) {
          _txnStatusCache.clear();
        }
      } catch (_) {}

      // Drop large log size cache to bound memory
      if (_logSizeCache != null && _logSizeCache!.length > 1000) {
        _logSizeCache!.clear();
      }

      // Clear deferred heavy deletes for inactive transactions
      try {
        final active = Set<String>.from(_activeTransactions);
        final toPurge = <String>[];
        _txnHeavyDeletes.forEach((tx, _) {
          if (!active.contains(tx)) toPurge.add(tx);
        });
        _txnHeavyUpdates.forEach((tx, _) {
          if (!active.contains(tx) && !toPurge.contains(tx)) toPurge.add(tx);
        });
        _txnCascadeDeletes.forEach((tx, _) {
          if (!active.contains(tx) && !toPurge.contains(tx)) toPurge.add(tx);
        });
        _txnCascadeUpdates.forEach((tx, _) {
          if (!active.contains(tx) && !toPurge.contains(tx)) toPurge.add(tx);
        });
        final yieldController = YieldController('txn_cleanup_deferred');
        for (final tx in toPurge) {
          await yieldController.maybeYield();
          _txnHeavyDeletes.remove(tx);
          _txnHeavyUpdates.remove(tx);
          _txnCascadeDeletes.remove(tx);
          _txnCascadeUpdates.remove(tx);
        }
      } catch (_) {}

      // Ask TableDataManager to cleanup its transactional state
      try {
        await _dataStore.tableDataManager.cleanupTransactionalState(
          nowMs: now,
          ttlMs: ttl,
          getActiveTxIds: () => Set<String>.from(_activeTransactions),
        );
      } catch (_) {}

      // Attempt partition directory cleanup for finished partitions
      try {
        if (_mainMetaCache != null &&
            _mainMetaCache!.activePartitions.isNotEmpty) {
          final yieldController = YieldController('txn_cleanup_partitions');
          for (final p in List<int>.from(_mainMetaCache!.activePartitions)) {
            await yieldController.maybeYield();
            await _maybeCleanupPartition(p);
          }
        }
      } catch (_) {}
    } catch (e) {
      Logger.warn('periodicCleanup failed', rawError: e);
    } finally {
      _cleanupRunning = false;
    }
  }

  Future<void> initialize() async {
    if (_mainMetaCache != null) {
      return;
    }
    try {
      // Memory mode must not touch storage; transaction meta is in-memory only.
      if (!_isMemoryMode) {
        final path = _dataStore.pathManager.getTransactionMainMetaPath();
        if (await _dataStore.storage.existsFile(path)) {
          final content = await _dataStore.storage.readAsString(path);
          if (content != null && content.isNotEmpty) {
            _mainMetaCache = TransactionMainMeta.fromJson(
                jsonDecode(content) as Map<String, dynamic>);
          }
        }
      }
    } catch (e) {
      Logger.warn('Load TransactionMainMeta failed', rawError: e);
    }
    _mainMetaCache ??= TransactionMainMeta();

    // Initialize TreeCache for recent committed writes (SSI index)
    // Key format: [tableUid, pk], Value: lastCommitTimeMillis (int)
    // Using TreeCache for automatic LRU eviction in large-scale data scenarios
    final resourceManager = _dataStore.resourceManager;
    final cacheSize = resourceManager?.getMetaCacheSize() ?? (32 * 1024 * 1024);
    // Allocate 10% of meta cache for transaction SSI index
    final int maxBytes = (cacheSize * 0.10).toInt();
    _recentCommittedWrites = TreeCache<int>(
      sizeCalculator: (_) => 8, // int timestamp = 8 bytes
      maxByteThreshold: maxBytes,
      minByteThreshold: 10 * 1024 * 1024, // 10MB minimum
      groupDepth: 1, // Group by tableUid
      debugLabel: 'RecentCommittedWrites',
    );

    // Register periodic cleanup via CrontabManager (idempotent)
    try {
      if (!_cleanupRegistered && _dataStore.config.enableTransactionCleanup) {
        _cleanupCallback = () async {
          try {
            final now = DateTime.now().millisecondsSinceEpoch;
            if (now - _lastPeriodicCleanupMs <
                _dataStore.config.transactionCleanupIntervalMs) {
              return;
            }
            _lastPeriodicCleanupMs = now;
            await periodicCleanup(
                nowMs: now, ttlMs: _dataStore.config.transactionMetaTtlMs);
          } catch (_) {}
        };
        CrontabManager.addCallback(ExecuteInterval.minutes5, _cleanupCallback!);
        _cleanupRegistered = true;
      }
    } catch (_) {}
  }

  /// Create new transaction id with embedded partition index
  Future<String> beginTransaction() async {
    await initialize();
    final partitionIndex = _mainMetaCache!.currentPartitionIndex;
    final unique = GlobalIdGenerator.generate('t');
    final txId =
        _dataStore.pathManager.buildTransactionId(partitionIndex, unique);

    if (!_isMemoryMode) {
      // Ensure current partition is marked active
      _mainMetaCache!.activePartitions.add(partitionIndex);
      await _persistMainMeta(flush: false);

      // Increment total transaction count for this partition and write begin status
      final meta = await _loadPartitionMeta(partitionIndex);
      meta.totalCount += 1;
      await _persistPartitionMeta(meta, flush: false);

      final dirIndex = partitionIndex ~/ _dataStore.maxEntriesPerDir;
      await _dataStore.storage.ensureDirectoryExists(_dataStore.pathManager
          .getTransactionPartitionDirPath(dirIndex, partitionIndex));
      final statusPath = _dataStore.pathManager
          .getTransactionPartitionStatusLogPathById(txId, dirIndex);
      await _appendTxnEvent(
        statusPath,
        TxnLogEvent.simple(transactionId: txId, event: TxnLogEventType.begin),
        partitionIndex,
      );
    }

    // Track active transaction in memory for fast checks
    _activeTransactions.add(txId);
    // initialize write set bucket
    _txnWriteSets.putIfAbsent(txId, () => <String, Set<String>>{});
    return txId;
  }

  /// Mark transaction committed; optionally persist recovery artifacts depending on policy, then remove transaction data.
  Future<void> commit(String transactionId, {bool? persistRecovery}) async {
    if (_isMemoryMode) {
      // No persistence / recovery artifacts in memory mode.
      _activeTransactions.remove(transactionId);
      _txnStatusCache[transactionId] = true;
      _txnWriteSets.remove(transactionId);
      _txnHeavyDeletes.remove(transactionId);
      _txnHeavyUpdates.remove(transactionId);
      _txnCascadeDeletes.remove(transactionId);
      _txnCascadeUpdates.remove(transactionId);
      try {
        await _dataStore.writeBufferManager
            .removeTransactionUniqueKeys(transactionId);
      } catch (_) {}
      return;
    }

    final pIndex =
        _dataStore.pathManager.parseTransactionPartitionIndex(transactionId);
    if (pIndex < 0) return;
    final meta = await _loadPartitionMeta(pIndex);
    meta.committedCount += 1;
    await _persistPartitionMeta(meta, flush: false);

    // Append commit status
    final dirIndex = pIndex ~/ _dataStore.maxEntriesPerDir;
    await _dataStore.storage.ensureDirectoryExists(_dataStore.pathManager
        .getTransactionPartitionDirPath(dirIndex, pIndex));
    final statusPath = _dataStore.pathManager
        .getTransactionPartitionStatusLogPathById(transactionId, dirIndex);
    await _appendTxnEvent(
      statusPath,
      TxnLogEvent.simple(
          transactionId: transactionId, event: TxnLogEventType.commit),
      pIndex,
    );

    // Determine whether to persist recovery artifacts (WAL/log/meta/journal)
    final bool shouldPersistRecovery =
        persistRecovery ?? _config.persistRecoveryOnCommit;
    try {
      if (shouldPersistRecovery) {
        // Collect recovery files touched by this transaction (multi-WAL-partition aware)
        final touched = TransactionContext.getTouchedPaths();
        final walRoot = _dataStore.pathManager
            .getWalRootPath(spaceName: _dataStore.currentSpaceName);
        final journalRoot = _dataStore.pathManager
            .getParallelJournalRootPath(spaceName: _dataStore.currentSpaceName);
        final walMetaPath = _dataStore.pathManager
            .getWalMainMetaPath(spaceName: _dataStore.currentSpaceName);

        final walPaths = <String>{};
        final journalPaths = <String>{};
        for (final p in touched) {
          if (p.startsWith(walRoot) && p.endsWith('.log')) {
            walPaths.add(p);
          } else if (p.startsWith(journalRoot) && p.endsWith('.log')) {
            journalPaths.add(p);
          }
        }
        // Fallback to current WAL partition if nothing was captured.
        // WAL append goes through WalManager's queue and may not register paths
        // in TransactionContext (common for schema-only / migration commits).
        if (walPaths.isEmpty && _dataStore.config.enableJournal) {
          final walIdx = _dataStore.walManager.currentPointer.partitionIndex;
          final walDirIndex =
              _dataStore.walManager.getPartitionDirIndex(walIdx) ??
                  walIdx ~/ _dataStore.maxEntriesPerDir;
          walPaths.add(_dataStore.pathManager.getWalPartitionLogPath(
              walDirIndex, walIdx,
              spaceName: _dataStore.currentSpaceName));
        }

        // Flush wal/journal; keep handles open to avoid frequent reopen.
        if (walPaths.isNotEmpty) {
          await _dataStore.storage
              .flushAll(paths: walPaths.toList(), closeHandles: false);
        }
        if (journalPaths.isNotEmpty) {
          await _dataStore.storage
              .flushAll(paths: journalPaths.toList(), closeHandles: false);
        }
        await _dataStore.storage
            .flushAll(path: walMetaPath, closeHandles: false);
      }
    } catch (e) {
      Logger.warn('Flush on commit failed', rawError: e);
    }

    await _maybeCleanupPartition(pIndex);
    // Remove from active set
    _activeTransactions.remove(transactionId);
    // Update cache for quick visibility checks
    _txnStatusCache[transactionId] = true;
    // Merge this tx's write-set into recent committed index
    try {
      final writesByTable = _txnWriteSets.remove(transactionId);
      if (writesByTable != null) {
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        writesByTable.forEach((tableUid, keys) {
          for (final k in keys) {
            // Use TreeCache: key format [tableUid, pk], value: timestamp
            // TreeCache automatically handles LRU eviction when size exceeds threshold
            _recentCommittedWrites.put([tableUid, k], nowMs);
          }
        });
      }
    } catch (_) {}

    // Opportunistic cleanup of caches to avoid growth
    if (_activeTransactions.isEmpty) {
      // drop stale status cache entries older than TTL window by scanning status logs lazily is expensive;
      // We keep size-bound: if cache > 10k, clear it to free memory.
      if (_txnStatusCache.length > 10000) {
        _txnStatusCache.clear();
      }
      if (_txnWriteSets.length > 1000) {
        _txnWriteSets.clear();
      }
      // Bound log size cache
      if (_logSizeCache != null && _logSizeCache!.length > 1000) {
        _logSizeCache!.clear();
      }
    }
    // Always clear deferred heavy deletes and updates for this tx
    _txnHeavyDeletes.remove(transactionId);
    _txnHeavyUpdates.remove(transactionId);
  }

  /// Build commit plan from in-memory deferred operations
  Future<TransactionCommitPlan> buildCommitPlan(String transactionId) async {
    try {
      final defOps = _dataStore.tableDataManager.getDeferredOps(transactionId);
      final heavyDeletes = getDeferredHeavyDeletes(transactionId);
      final heavyUpdates = getDeferredHeavyUpdates(transactionId);

      if ((defOps == null || defOps.isEmpty) &&
          heavyDeletes.isEmpty &&
          heavyUpdates.isEmpty) {
        return TransactionCommitPlan(
          transactionId: transactionId,
          inserts: const {},
          updates: const {},
          deletes: const {},
          heavyDeletes: const <HeavyDeletePlan>[],
          heavyUpdates: const <HeavyUpdatePlan>[],
        );
      }

      final inserts = <String, List<Map<String, dynamic>>>{};
      final updates = <String, List<Map<String, dynamic>>>{};
      final deletes = <String, List<Map<String, dynamic>>>{};

      if (defOps != null) {
        final yieldController = YieldController('txn_build_commit_plan');
        for (final entry in defOps.entries) {
          final table = entry.key;
          final ops = entry.value;
          for (final op in ops) {
            await yieldController.maybeYield();
            final rec = Map<String, dynamic>.from(op.data);

            // Embed unique key refs if present (for recovery application)
            if (op.uniqueKeyRefs != null && op.uniqueKeyRefs!.isNotEmpty) {
              rec['_uniqueKeys'] =
                  op.uniqueKeyRefs!.map((e) => e.toJson()).toList();
            }

            // Embed old values if present (for updates)
            if (op.oldValues != null) {
              rec['_oldValues'] = op.oldValues;
            }

            if (op.type == BufferOperationType.insert) {
              final list = inserts.putIfAbsent(table, () => []);
              list.add(rec);
            } else if (op.type == BufferOperationType.update) {
              final list = updates.putIfAbsent(table, () => []);
              list.add(rec);
            } else if (op.type == BufferOperationType.delete) {
              final list = deletes.putIfAbsent(table, () => []);
              list.add(rec);
            }
          }
        }
      }

      return TransactionCommitPlan(
        transactionId: transactionId,
        inserts: inserts,
        updates: updates,
        deletes: deletes,
        heavyDeletes: heavyDeletes,
        heavyUpdates: heavyUpdates,
      );
    } catch (_) {
      return TransactionCommitPlan(
        transactionId: transactionId,
        inserts: const {},
        updates: const {},
        deletes: const {},
        heavyDeletes: const <HeavyDeletePlan>[],
        heavyUpdates: const <HeavyUpdatePlan>[],
      );
    }
  }

  /// Persist compact commit plan for crash recovery
  Future<void> persistCommitPlan(TransactionCommitPlan plan) async {
    if (_isMemoryMode) return;
    try {
      // Unified storage with cross-partition continuation when hitting size threshold
      final currentIndex = _dataStore.pathManager
          .parseTransactionPartitionIndex(plan.transactionId);
      final currentDirIndex = _dirIndexForPartition(currentIndex);
      await _dataStore.storage.ensureDirectoryExists(_dataStore.pathManager
          .getTransactionPartitionDirPath(currentDirIndex, currentIndex));
      final currentLogPath = _dataStore.pathManager
          .getTransactionPartitionLogPath(currentDirIndex, currentIndex);

      final planEvent = TxnLogEvent.simple(
        transactionId: plan.transactionId,
        event: TxnLogEventType.plan,
        plan: plan,
      );
      final planRecord = await TxnEncoder.encodeAsRecord(
        planEvent,
        currentIndex,
        resolveTable: _resolveTxnTableCodec,
      );

      // Use in-memory size cache to avoid frequent filesystem size calls
      _logSizeCache ??= <String, int>{};
      final cachedSize = _logSizeCache![currentLogPath];
      final int currentSize =
          cachedSize ?? await _dataStore.storage.getFileSize(currentLogPath);
      final int planBytes = planRecord.length;
      final int threshold = _config.maxLogPartitionFileSize;

      if (currentSize > 0 && currentSize + planBytes > threshold) {
        // Mark continuation at tail and write plan into next partition's log
        final int nextIndex = _nextPartitionIndex(currentIndex);
        await initialize();
        _mainMetaCache!.activePartitions.add(nextIndex);
        await _persistMainMeta(flush: false);

        await _appendTxnEvent(
          currentLogPath,
          TxnLogEvent.simple(
            transactionId: plan.transactionId,
            event: TxnLogEventType.continueInNextPartition,
            nextPartitionIndex: nextIndex,
          ),
          currentIndex,
          knownBaseSize: currentSize,
        );

        // Ensure next partition directory exists
        final nextDirIndex = _dirIndexForPartition(nextIndex);
        final nextDir = _dataStore.pathManager
            .getTransactionPartitionDirPath(nextDirIndex, nextIndex);
        await _dataStore.storage.ensureDirectoryExists(nextDir);
        final nextLogPath = _dataStore.pathManager
            .getTransactionPartitionLogPath(nextDirIndex, nextIndex);
        // Plan may continue into another partition; re-encode with that AAD.
        final continuedPlanRecord = await TxnEncoder.encodeAsRecord(
          planEvent,
          nextIndex,
          resolveTable: _resolveTxnTableCodec,
        );
        final nextCached = _logSizeCache![nextLogPath];
        final nextBase =
            nextCached ?? await _dataStore.storage.getFileSize(nextLogPath);
        await _dataStore.storage
            .appendBytes(nextLogPath, continuedPlanRecord, flush: false);
        _logSizeCache![nextLogPath] = nextBase + continuedPlanRecord.length;

        // Write plan_persisted hints to both status logs (best-effort)
        try {
          final currStatus = _dataStore.pathManager
              .getTransactionPartitionStatusLogPathById(
                  plan.transactionId, currentDirIndex);
          final nextStatus = _dataStore.pathManager
              .getTransactionPartitionStatusLogPath(nextDirIndex, nextIndex);
          await _dataStore.storage.ensureDirectoryExists(_dataStore.pathManager
              .getTransactionPartitionDirPath(currentDirIndex, currentIndex));
          await _appendTxnEvent(
            currStatus,
            TxnLogEvent.simple(
              transactionId: plan.transactionId,
              event: TxnLogEventType.planPersisted,
              continuedTo: nextIndex,
            ),
            currentIndex,
          );
          await _appendTxnEvent(
            nextStatus,
            TxnLogEvent.simple(
              transactionId: plan.transactionId,
              event: TxnLogEventType.planPersisted,
            ),
            nextIndex,
          );
        } catch (_) {}
      } else {
        await _dataStore.storage
            .appendBytes(currentLogPath, planRecord, flush: false);
        _logSizeCache![currentLogPath] = currentSize + planBytes;
        try {
          final statusPath = _dataStore.pathManager
              .getTransactionPartitionStatusLogPathById(
                  plan.transactionId, currentDirIndex);
          await _dataStore.storage.ensureDirectoryExists(_dataStore.pathManager
              .getTransactionPartitionDirPath(currentDirIndex, currentIndex));
          await _appendTxnEvent(
            statusPath,
            TxnLogEvent.simple(
              transactionId: plan.transactionId,
              event: TxnLogEventType.planPersisted,
            ),
            currentIndex,
          );
        } catch (_) {}
      }
      // Rotate partition if needed (size-based)
      await rotateIfNeeded();
    } catch (e) {
      Logger.warn('Persist commit plan failed', rawError: e);
    }
  }

  /// Load commit plan (unified: from partition append-only log, early return on first match)
  Future<TransactionCommitPlan?> loadCommitPlan(String transactionId) async {
    if (_isMemoryMode) return null;
    try {
      int currentIndex =
          _dataStore.pathManager.parseTransactionPartitionIndex(transactionId);
      final visited = <int>{};
      // Follow continuation chain instead of blind looping all partitions
      while (!visited.contains(currentIndex)) {
        visited.add(currentIndex);
        final currentDirIndex = _dirIndexForPartition(currentIndex);
        final logPath = _dataStore.pathManager
            .getTransactionPartitionLogPath(currentDirIndex, currentIndex);
        if (!await _dataStore.storage.existsFile(logPath)) return null;
        int? nextIndex;
        final events = await _readTxnLogEvents(logPath, currentIndex);
        for (final ev in events) {
          if (ev.event == TxnLogEventType.plan &&
              ev.transactionId == transactionId) {
            if (ev.plan != null) {
              return await _withNormalizedTableKeys(ev.plan!);
            }
          }
          if (ev.event == TxnLogEventType.continueInNextPartition &&
              ev.transactionId == transactionId &&
              ev.nextPartitionIndex != null) {
            nextIndex = ev.nextPartitionIndex;
          }
        }
        if (nextIndex == null) return null; // no continuation
        currentIndex = nextIndex;
      }
      return null;
    } catch (e) {
      Logger.warn('Load commit plan from partition log failed', rawError: e);
      return null;
    }
  }

  /// Apply commit plan during crash recovery (idempotent): write updates/deletes into buffers and flush.
  Future<void> applyCommitPlan(TransactionCommitPlan plan) async {
    final commitPlan = await _withNormalizedTableKeys(plan);
    try {
      // Resume from plan progress checkpoint (per-table applied counts)
      final progress = await _loadPlanProgress(commitPlan.transactionId);

      int processedSinceLastCheckpoint = 0;
      const int checkpointEvery = 1000; // persist progress every N operations

      // Cache primary key names per table to reduce schema IO
      final Map<String, String> pkByTable = <String, String>{};

      Future<String> ensurePk(String table) async {
        var pk = pkByTable[table];
        if (pk != null && pk.isNotEmpty) return pk;
        final schema = await _resolveTableSchemaFromField(table);
        pk = schema?.primaryKey ?? 'id';
        pkByTable[table] = pk;
        return pk;
      }

      // Re-enact inserts as INSERT to unified range partition write
      final yieldController = YieldController('txn_apply_commit_plan');
      for (final entry in commitPlan.inserts.entries) {
        final tableUid = entry.key;
        final recs = entry.value;
        final tableCtx = await _dataStore.tableMetaManager
            ?.getTableContext(TableUid(tableUid));
        if (tableCtx == null) {
          Logger.warn(
              'Table context not found for $tableUid during applyCommitPlan');
          continue;
        }
        final schema = await _dataStore.tableMetaManager
            ?.getTableSchema(tableCtx.tableUid);
        if (schema == null) {
          Logger.warn(
              'Schema not found for table $tableUid during applyCommitPlan');
          continue;
        }

        final startIdx = progress['inserts']![tableUid] ?? 0;
        const int batchSize = 1000;
        final migrationManager = _dataStore.migrationManager;
        final hasRuntimeMigration = migrationManager != null &&
            migrationManager.hasRuntimeMigrationForTable(tableCtx);

        for (int i = startIdx; i < recs.length; i += batchSize) {
          await yieldController.maybeYield();
          final end =
              (i + batchSize < recs.length) ? i + batchSize : recs.length;

          final List<Map<String, dynamic>> records = [];
          final List<List<UniqueKeyRef>> uniqueKeysList = [];

          for (int j = i; j < end; j++) {
            final rec = Map<String, dynamic>.from(recs[j]);
            rec.remove('_oldValues'); // inserts do not use oldValues
            final uks = rec.remove('_uniqueKeys') as List?;
            final normalizedRec = (hasRuntimeMigration)
                ? migrationManager.normalizeRecordToLatestSync(tableCtx, rec,
                    fromVersion: '')
                : rec;
            uniqueKeysList.add(uks
                    ?.map(
                        (e) => UniqueKeyRef.fromJson(e as Map<String, dynamic>))
                    .toList() ??
                const <UniqueKeyRef>[]);
            records.add(normalizedRec);
          }

          await _dataStore.tableDataManager.addBatchToBuffer(
            table: tableCtx,
            records: records,
            operation: BufferOperationType.insert,
            schema: schema,
            uniqueKeyRefsList: uniqueKeysList,
            transactionId: commitPlan.transactionId,
            schemaVersion: schema.schemaVersion ?? '',
          );

          progress['inserts']![tableUid] = end;
          processedSinceLastCheckpoint += (end - i);
          if (processedSinceLastCheckpoint >= checkpointEvery) {
            await _persistPlanProgress(
                commitPlan.transactionId,
                progress['inserts']!,
                progress['updates']!,
                progress['deletes']!);
            processedSinceLastCheckpoint = 0;
          }
        }
      }
      for (final entry in commitPlan.updates.entries) {
        final tableUid = entry.key;
        final recs = entry.value;
        final tableCtx = await _dataStore.tableMetaManager
            ?.getTableContext(TableUid(tableUid));
        if (tableCtx == null) {
          Logger.warn(
              'Table context not found for $tableUid during applyCommitPlan');
          continue;
        }
        final schema = await _dataStore.tableMetaManager
            ?.getTableSchema(tableCtx.tableUid);
        if (schema == null) {
          Logger.warn(
              'Schema not found for table $tableUid during applyCommitPlan');
          continue;
        }

        final startIdx = progress['updates']![tableUid] ?? 0;
        const int batchSize = 1000;
        final migrationManager = _dataStore.migrationManager;
        final hasRuntimeMigration = migrationManager != null &&
            migrationManager.hasRuntimeMigrationForTable(tableCtx);

        for (int i = startIdx; i < recs.length; i += batchSize) {
          await yieldController.maybeYield();
          final end =
              (i + batchSize < recs.length) ? i + batchSize : recs.length;

          final List<Map<String, dynamic>> records = [];
          final List<List<UniqueKeyRef>> uniqueKeysList = [];
          final Map<String, Map<String, dynamic>> oldRecordsMap = {};

          final pkName = schema.primaryKey;

          for (int j = i; j < end; j++) {
            final rec = Map<String, dynamic>.from(recs[j]);
            final old = rec.remove('_oldValues') as Map<String, dynamic>?;
            final uks = rec.remove('_uniqueKeys') as List?;
            final normalizedRec = (hasRuntimeMigration)
                ? migrationManager.normalizeRecordToLatestSync(tableCtx, rec,
                    fromVersion: '')
                : rec;
            final normalizedOld = (hasRuntimeMigration && old != null)
                ? migrationManager.normalizeRecordToLatestSync(tableCtx, old,
                    fromVersion: '')
                : old;

            final rId = normalizedRec[pkName]?.toString();
            if (rId != null && normalizedOld != null) {
              oldRecordsMap[rId] = normalizedOld;
            }

            uniqueKeysList.add(uks
                    ?.map(
                        (e) => UniqueKeyRef.fromJson(e as Map<String, dynamic>))
                    .toList() ??
                const <UniqueKeyRef>[]);
            records.add(normalizedRec);
          }

          await _dataStore.tableDataManager.addBatchToBuffer(
            table: tableCtx,
            records: records,
            operation: BufferOperationType.update,
            schema: schema,
            uniqueKeyRefsList: uniqueKeysList,
            oldRecordsMap: oldRecordsMap,
            transactionId: commitPlan.transactionId,
            schemaVersion: schema.schemaVersion ?? '',
          );

          progress['updates']![tableUid] = end;
          processedSinceLastCheckpoint += (end - i);
          if (processedSinceLastCheckpoint >= checkpointEvery) {
            await _persistPlanProgress(
                commitPlan.transactionId,
                progress['inserts']!,
                progress['updates']!,
                progress['deletes']!);
            processedSinceLastCheckpoint = 0;
          }
        }
      }
      for (final entry in commitPlan.deletes.entries) {
        final tableUid = entry.key;
        final recs = entry.value; // now full records
        if (recs.isEmpty) continue;
        final tableCtx = await _dataStore.tableMetaManager
            ?.getTableContext(TableUid(tableUid));
        if (tableCtx == null) {
          Logger.warn(
              'Table context not found for $tableUid during applyCommitPlan');
          continue;
        }
        final startIdx = progress['deletes']![tableUid] ?? 0;
        const int batchSize = 1000;
        for (int i = startIdx; i < recs.length; i += batchSize) {
          await yieldController.maybeYield();
          final end =
              (i + batchSize < recs.length) ? i + batchSize : recs.length;
          final batch = <Map<String, dynamic>>[];
          final cacheKeys = <String>[];
          String? pkName;
          final migrationManager = _dataStore.migrationManager;
          final hasRuntimeMigration = migrationManager != null &&
              migrationManager.hasRuntimeMigrationForTable(tableCtx);
          for (int j = i; j < end; j++) {
            await yieldController.maybeYield();
            final rec = Map<String, dynamic>.from(recs[j]);
            rec.remove('_oldValues'); // delete: old values not used
            final normalizedRec = (hasRuntimeMigration)
                ? migrationManager.normalizeRecordToLatestSync(tableCtx, rec,
                    fromVersion: '')
                : rec;
            batch.add(normalizedRec);
            try {
              pkName ??= await ensurePk(tableUid);
              final k = normalizedRec[pkName]?.toString();
              if (k != null && k.isNotEmpty) cacheKeys.add(k);
            } catch (_) {}
          }
          final schema = await _resolveTableSchemaFromField(tableUid);
          final version = schema?.schemaVersion ?? '';
          await _dataStore.tableDataManager.addToDeleteBuffer(
            tableCtx,
            batch,
            schemaVersion: version,
          );
          progress['deletes']![tableUid] = end;
          processedSinceLastCheckpoint += (end - i);
          if (processedSinceLastCheckpoint >= checkpointEvery) {
            await _persistPlanProgress(
                commitPlan.transactionId,
                progress['inserts']!,
                progress['updates']!,
                progress['deletes']!);
            processedSinceLastCheckpoint = 0;
          }
        }
      }

      // Execute deferred cascade delete operations (commit-time, after all main operations)
      final cascadeDeletes =
          getDeferredCascadeDeletes(commitPlan.transactionId);
      if (cascadeDeletes.isNotEmpty && _dataStore.foreignKeyManager != null) {
        for (final cd in cascadeDeletes) {
          await yieldController.maybeYield();
          final tableContext =
              await _dataStore.tableMetaManager?.getTableContext(cd.tableUid);
          if (tableContext == null) continue;
          final tableName = tableContext.tableName;
          try {
            await _dataStore.foreignKeyManager!.handleCascadeDelete(
              table: tableContext,
              deletedPkValues: cd.deletedPkValues,
              skipRestrictCheck:
                  true, // RESTRICT already checked when delete was attempted
            );
          } catch (e) {
            Logger.warn(
                'Cascade delete during applyCommitPlan failed on $tableName',
                rawError: e);
            rethrow;
          }
        }
      }

      // Execute deferred cascade update operations (commit-time, after cascade deletes)
      final cascadeUpdates =
          getDeferredCascadeUpdates(commitPlan.transactionId);
      if (cascadeUpdates.isNotEmpty && _dataStore.foreignKeyManager != null) {
        for (final cu in cascadeUpdates) {
          await yieldController.maybeYield();
          final tableContext =
              await _dataStore.tableMetaManager?.getTableContext(cu.tableUid);
          if (tableContext == null) continue;
          final tableName = tableContext.tableName;
          try {
            await _dataStore.foreignKeyManager!.handleCascadeUpdate(
              table: tableContext,
              oldPkValues: cu.oldPkValues,
              newPkValues: cu.newPkValues,
              visitedTables: null,
              skipRestrictCheck:
                  true, // RESTRICT already checked when update was attempted
            );
          } catch (e) {
            Logger.warn(
                'Cascade update during applyCommitPlan failed on $tableName',
                rawError: e);
            rethrow;
          }
        }
      }

      // Execute deferred heavy delete plans (commit-time, idempotent via internal checkpoints)
      if (commitPlan.heavyDeletes.isNotEmpty) {
        for (final hd in commitPlan.heavyDeletes) {
          await yieldController.maybeYield();
          final table =
              await _dataStore.tableMetaManager?.getTableContext(hd.tableUid);
          if (table == null) continue;
          final tableName = table.tableName;
          try {
            final qc = QueryCondition.fromMap(hd.condition);
            await _dataStore.deleteInternal(
              table,
              qc,
              orderBy: hd.orderBy,
              limit: hd.limit,
              offset: hd.offset,
              allowAll: false,
            );
          } catch (e) {
            Logger.warn(
                'Heavy delete during applyCommitPlan failed on $tableName',
                rawError: e);
            rethrow;
          }
        }
      }

      // Execute deferred heavy update plans (commit-time, idempotent via internal checkpoints)
      if (commitPlan.heavyUpdates.isNotEmpty) {
        for (final hu in commitPlan.heavyUpdates) {
          await yieldController.maybeYield();
          final table =
              await _dataStore.tableMetaManager?.getTableContext(hu.tableUid);
          if (table == null) continue;
          final tableName = table.tableName;
          try {
            final qc = QueryCondition.fromMap(hu.condition);
            await _dataStore.updateInternal(
              table,
              hu.updateData,
              qc,
              orderBy: hu.orderBy,
              limit: hu.limit,
              offset: hu.offset,
              allowAll: false,
            );
          } catch (e) {
            Logger.warn(
                'Heavy update during applyCommitPlan failed on $tableName',
                rawError: e);
            rethrow;
          }
        }
      }

      // Final checkpoint before flush
      await _persistPlanProgress(commitPlan.transactionId, progress['inserts']!,
          progress['updates']!, progress['deletes']!);

      _dataStore.tableDataManager
          .clearTransactionState(commitPlan.transactionId);
    } catch (e) {
      Logger.warn('Apply commit plan failed', rawError: e);
      rethrow;
    }
  }

  /// Load plan application progress from status.log
  Future<Map<String, Map<String, int>>> _loadPlanProgress(
      String transactionId) async {
    if (_isMemoryMode) {
      return {
        // Use mutable maps in memory mode to allow in-place progress updates.
        'inserts': <String, int>{},
        'updates': <String, int>{},
        'deletes': <String, int>{},
      };
    }
    final inserts = <String, int>{};
    final updates = <String, int>{};
    final deletes = <String, int>{};
    try {
      final pIndex =
          _dataStore.pathManager.parseTransactionPartitionIndex(transactionId);
      if (pIndex < 0) return {'inserts': {}, 'updates': {}, 'deletes': {}};
      final dirIndex = _dirIndexForPartition(pIndex);
      final statusPath = _dataStore.pathManager
          .getTransactionPartitionStatusLogPathById(transactionId, dirIndex);
      if (await _dataStore.storage.existsFile(statusPath)) {
        final events = await _readTxnLogEvents(statusPath, pIndex);
        for (final ev in events) {
          if (ev.transactionId == transactionId &&
              ev.event == TxnLogEventType.planProgress) {
            if (ev.insertsApplied != null) {
              inserts.addAll(ev.insertsApplied!);
            }
            if (ev.updatesApplied != null) {
              updates.addAll(ev.updatesApplied!);
            }
            if (ev.deletesApplied != null) {
              deletes.addAll(ev.deletesApplied!);
            }
          }
        }
      }
    } catch (_) {}
    return {
      'inserts': inserts,
      'updates': updates,
      'deletes': deletes,
    };
  }

  /// Persist plan application progress to status.log (idempotent by overwrite of counts)
  Future<void> _persistPlanProgress(
      String transactionId,
      Map<String, int> insertsApplied,
      Map<String, int> updatesApplied,
      Map<String, int> deletesApplied) async {
    if (_isMemoryMode) return;
    try {
      final pIndex =
          _dataStore.pathManager.parseTransactionPartitionIndex(transactionId);
      if (pIndex < 0) return;
      final dirIndex = _dirIndexForPartition(pIndex);
      await _dataStore.storage.ensureDirectoryExists(_dataStore.pathManager
          .getTransactionPartitionDirPath(dirIndex, pIndex));
      final statusPath = _dataStore.pathManager
          .getTransactionPartitionStatusLogPathById(transactionId, dirIndex);
      await _appendTxnEvent(
        statusPath,
        TxnLogEvent.simple(
          transactionId: transactionId,
          event: TxnLogEventType.planProgress,
          insertsApplied: insertsApplied,
          updatesApplied: updatesApplied,
          deletesApplied: deletesApplied,
        ),
        pIndex,
      );
    } catch (_) {}
  }

  /// Recovery: continue unfinished transactions by applying plans or rolling back
  Future<void> recoverUnfinishedTransactionsOnStartup() async {
    if (_isMemoryMode) return;
    try {
      await initialize();
      await for (final txId in streamUnfinishedTransactions()) {
        try {
          final plan = await loadCommitPlan(txId);
          if (plan != null) {
            // Apply commit plan and mark committed
            await applyCommitPlan(plan);
            await commit(txId,
                persistRecovery: _config.persistRecoveryOnCommit);
          } else {
            // No plan: rollback uncommitted changes and clean placeholders/index reservations
            await _dataStore.tableDataManager.applyTransactionRollback(txId);
            await rollback(txId);
          }
        } catch (e) {
          Logger.warn('Recovery for $txId failed', rawError: e);
        }
      }
    } catch (e) {
      Logger.warn('recoverUnfinishedTransactionsOnStartup failed', rawError: e);
    }
  }

  /// Mark transaction rolled back; the caller should already have applied the compensating operations
  Future<void> rollback(String transactionId) async {
    if (_isMemoryMode) {
      _activeTransactions.remove(transactionId);
      _txnStatusCache[transactionId] = false;
      _txnWriteSets.remove(transactionId);
      _txnHeavyDeletes.remove(transactionId);
      _txnHeavyUpdates.remove(transactionId);
      _txnCascadeDeletes.remove(transactionId);
      _txnCascadeUpdates.remove(transactionId);
      try {
        await _dataStore.writeBufferManager
            .removeTransactionUniqueKeys(transactionId);
      } catch (_) {}
      return;
    }
    final pIndex =
        _dataStore.pathManager.parseTransactionPartitionIndex(transactionId);
    if (pIndex < 0) return;
    final meta = await _loadPartitionMeta(pIndex);
    meta.rolledBackCount += 1;
    await _persistPartitionMeta(meta, flush: false);

    // Append rollback status
    final dirIndex = _dirIndexForPartition(pIndex);
    await _dataStore.storage.ensureDirectoryExists(_dataStore.pathManager
        .getTransactionPartitionDirPath(dirIndex, pIndex));
    final statusPath = _dataStore.pathManager
        .getTransactionPartitionStatusLogPathById(transactionId, dirIndex);
    await _appendTxnEvent(
      statusPath,
      TxnLogEvent.simple(
          transactionId: transactionId, event: TxnLogEventType.rollback),
      pIndex,
    );

    await _maybeCleanupPartition(pIndex);
    // Remove from active set
    _activeTransactions.remove(transactionId);
    // Update cache for quick visibility checks
    _txnStatusCache[transactionId] = false;
    _txnWriteSets.remove(transactionId);

    // Opportunistic cleanup of caches to avoid growth
    if (_activeTransactions.isEmpty) {
      if (_txnStatusCache.length > 10000) {
        _txnStatusCache.clear();
      }
      if (_txnWriteSets.length > 1000) {
        _txnWriteSets.clear();
      }
    }
    // Clear deferred heavy deletes and updates for this tx
    _txnHeavyDeletes.remove(transactionId);
    _txnHeavyUpdates.remove(transactionId);
    // Clear deferred cascade operations for this tx
    _txnCascadeDeletes.remove(transactionId);
    _txnCascadeUpdates.remove(transactionId);

    // Ensure unique key reservations are cleaned up to prevent memory leaks
    try {
      await _dataStore.writeBufferManager
          .removeTransactionUniqueKeys(transactionId);
    } catch (_) {
      // Ignore errors during cleanup
    }
  }

  /// Register a write key (table, primaryKey) for current transaction (used by SSI)
  void registerWriteKey(String txId, TableContext table, String primaryKey) {
    try {
      final byTable =
          _txnWriteSets.putIfAbsent(txId, () => <String, Set<String>>{});
      final set = byTable.putIfAbsent(table.tableUid, () => <String>{});
      set.add(primaryKey);
    } catch (_) {}
  }

  /// Register a deferred heavy delete plan for a transaction
  void registerDeferredHeavyDelete(String txId, HeavyDeletePlan plan) {
    final list = _txnHeavyDeletes.putIfAbsent(txId, () => <HeavyDeletePlan>[]);
    list.add(plan);
  }

  /// Get deferred heavy delete plans for a transaction
  List<HeavyDeletePlan> getDeferredHeavyDeletes(String txId) {
    final list = _txnHeavyDeletes[txId];
    if (list == null) return const <HeavyDeletePlan>[];
    return List<HeavyDeletePlan>.from(list);
  }

  /// Register a deferred heavy update plan for a transaction
  void registerDeferredHeavyUpdate(String txId, HeavyUpdatePlan plan) {
    final list = _txnHeavyUpdates.putIfAbsent(txId, () => <HeavyUpdatePlan>[]);
    list.add(plan);
  }

  /// Get deferred heavy update plans for a transaction
  List<HeavyUpdatePlan> getDeferredHeavyUpdates(String txId) {
    final list = _txnHeavyUpdates[txId];
    if (list == null) return const <HeavyUpdatePlan>[];
    return List<HeavyUpdatePlan>.from(list);
  }

  /// Register a deferred cascade delete operation for a transaction
  void registerDeferredCascadeDelete(
      String txId, TableContext table, dynamic deletedPkValues) {
    final list =
        _txnCascadeDeletes.putIfAbsent(txId, () => <_CascadeDeleteOp>[]);
    list.add(_CascadeDeleteOp(
      tableUid: table.tableUid,
      deletedPkValues: deletedPkValues,
    ));
  }

  /// Get deferred cascade delete operations for a transaction
  // ignore: library_private_types_in_public_api
  List<_CascadeDeleteOp> getDeferredCascadeDeletes(String txId) {
    final list = _txnCascadeDeletes[txId];
    if (list == null) return const <_CascadeDeleteOp>[];
    return List<_CascadeDeleteOp>.from(list);
  }

  /// Register a deferred cascade update operation for a transaction
  void registerDeferredCascadeUpdate(String txId, TableContext table,
      dynamic oldPkValues, dynamic newPkValues) {
    final list =
        _txnCascadeUpdates.putIfAbsent(txId, () => <_CascadeUpdateOp>[]);
    list.add(_CascadeUpdateOp(
      tableUid: table.tableUid,
      oldPkValues: oldPkValues,
      newPkValues: newPkValues,
    ));
  }

  /// Get deferred cascade update operations for a transaction
  // ignore: library_private_types_in_public_api
  List<_CascadeUpdateOp> getDeferredCascadeUpdates(String txId) {
    final list = _txnCascadeUpdates[txId];
    if (list == null) return const <_CascadeUpdateOp>[];
    return List<_CascadeUpdateOp>.from(list);
  }

  /// SSI conflict detection: for each read key, if a different tx committed a write
  /// after this tx's start, report conflict.
  Future<List<String>> checkSerializableConflictsTransactional(
      Map<TableUid, Set<String>> readKeysByTable,
      DateTime startedAt,
      String currentTxId) async {
    final conflicts = <String>[];
    try {
      final startMs = startedAt.millisecondsSinceEpoch;

      for (final e in readKeysByTable.entries) {
        final tableUid = e.key;
        final keys = e.value;
        if (keys.isEmpty) continue;
        final yieldController = YieldController('txn_ssi_check');
        for (final k in keys) {
          await yieldController.maybeYield();
          // Use TreeCache: key format [tableUid, pk]
          final lastMs = _recentCommittedWrites.get([tableUid, k]);
          if (lastMs != null && lastMs > startMs) {
            final tableName =
                await _dataStore.tableMetaManager?.getNameByUid(tableUid) ??
                    TableName(tableUid);
            conflicts.add('$tableName:$k');
            return conflicts; // early return on first conflict
          }
        }
      }
    } catch (_) {}
    return conflicts;
  }

  /// Get next partition index with cycle
  int _nextPartitionIndex(int current) {
    final next = current + 1;
    if (next >= _dataStore.config.logPartitionCycle) return 0;
    return next;
  }

  /// Check if a transaction is still active (not committed/rolled back)
  bool isActive(String txId) {
    return _activeTransactions.contains(txId);
  }

  /// Get cached commit status if present (no IO). Returns true/false or null if unknown.
  bool? getCachedCommitStatus(String txId) => _txnStatusCache[txId];

  /// Check if a transaction has been committed by scanning the status log.
  /// Returns true if a commit event is found, false if a rollback event is found,
  /// otherwise false (unknown -> treated as not committed).
  Future<bool> isCommitted(String transactionId) async {
    try {
      // Fast path: cached
      final cached = _txnStatusCache[transactionId];
      if (cached != null) return cached;
      await initialize();
      final pIndex =
          _dataStore.pathManager.parseTransactionPartitionIndex(transactionId);
      if (pIndex < 0) return false;
      final dirIndex = _dirIndexForPartition(pIndex);
      final statusPath = _dataStore.pathManager
          .getTransactionPartitionStatusLogPathById(transactionId, dirIndex);
      if (!await _dataStore.storage.existsFile(statusPath)) return false;

      final events = await _readTxnLogEvents(statusPath, pIndex);
      for (final ev in events) {
        if (ev.transactionId == transactionId) {
          if (ev.event == TxnLogEventType.commit) {
            _txnStatusCache[transactionId] = true;
            return true;
          }
          if (ev.event == TxnLogEventType.rollback) {
            _txnStatusCache[transactionId] = false;
            return false;
          }
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  int _dirIndexForPartition(int partitionIndex) =>
      partitionIndex ~/ _dataStore.maxEntriesPerDir;

  /// Rotate partition if size exceeds threshold.
  Future<void> rotateIfNeeded() async {
    if (_isMemoryMode) return;
    await initialize();
    final pIndex = _mainMetaCache!.currentPartitionIndex;
    final dirIndex = _dirIndexForPartition(pIndex);
    final logPath =
        _dataStore.pathManager.getTransactionPartitionLogPath(dirIndex, pIndex);
    _logSizeCache ??= <String, int>{};
    final cached = _logSizeCache![logPath];
    final size = cached ?? await _dataStore.storage.getFileSize(logPath);
    if (size >= _config.maxLogPartitionFileSize) {
      _mainMetaCache!.currentPartitionIndex = _nextPartitionIndex(pIndex);
      _mainMetaCache!.activePartitions
          .add(_mainMetaCache!.currentPartitionIndex);
      await _persistMainMeta(flush: false);
    }
  }

  Future<TransactionPartitionMeta> _loadPartitionMeta(
      int partitionIndex) async {
    if (_isMemoryMode) {
      // In memory mode, partition meta is not persisted; keep a minimal in-memory record.
      return _partitionMetaCache.putIfAbsent(partitionIndex,
          () => TransactionPartitionMeta(partitionIndex: partitionIndex));
    }
    final cached = _partitionMetaCache[partitionIndex];
    if (cached != null) return cached;
    final dirIndex = _dirIndexForPartition(partitionIndex);
    await _dataStore.storage.ensureDirectoryExists(_dataStore.pathManager
        .getTransactionPartitionDirPath(dirIndex, partitionIndex));
    final path = _dataStore.pathManager
        .getTransactionPartitionMetaPath(dirIndex, partitionIndex);
    TransactionPartitionMeta meta;
    try {
      if (await _dataStore.storage.existsFile(path)) {
        final content = await _dataStore.storage.readAsString(path);
        if (content != null && content.isNotEmpty) {
          meta = TransactionPartitionMeta.fromJson(
              jsonDecode(content) as Map<String, dynamic>);
        } else {
          meta = TransactionPartitionMeta(partitionIndex: partitionIndex);
        }
      } else {
        meta = TransactionPartitionMeta(partitionIndex: partitionIndex);
      }
    } catch (e) {
      Logger.warn('Load txn partition meta failed', rawError: e);
      meta = TransactionPartitionMeta(partitionIndex: partitionIndex);
    }
    _partitionMetaCache[partitionIndex] = meta;
    return meta;
  }

  Future<void> _persistPartitionMeta(TransactionPartitionMeta meta,
      {bool flush = false}) async {
    if (_isMemoryMode) {
      _partitionMetaCache[meta.partitionIndex] = meta;
      return;
    }
    final dirIndex = _dirIndexForPartition(meta.partitionIndex);
    await _dataStore.storage.ensureDirectoryExists(_dataStore.pathManager
        .getTransactionPartitionDirPath(dirIndex, meta.partitionIndex));
    final path = _dataStore.pathManager
        .getTransactionPartitionMetaPath(dirIndex, meta.partitionIndex);
    await _dataStore.storage
        .writeAsString(path, jsonEncode(meta.toJson()), flush: flush);
    _partitionMetaCache[meta.partitionIndex] = meta;
  }

  Future<void> _persistMainMeta({bool flush = false}) async {
    if (_isMemoryMode) return;
    final path = _dataStore.pathManager.getTransactionMainMetaPath();
    await _dataStore.storage.writeAsString(
        path, jsonEncode(_mainMetaCache!.toJson()),
        flush: flush);
  }

  Future<void> _maybeCleanupPartition(int partitionIndex) async {
    if (_isMemoryMode) return;
    final meta = await _loadPartitionMeta(partitionIndex);
    if (meta.finishedCount >= meta.totalCount && meta.totalCount > 0) {
      // Never delete the latest active partition to avoid race with concurrent appends
      if (_mainMetaCache != null &&
          partitionIndex == _mainMetaCache!.currentPartitionIndex) {
        return;
      }
      // All finished; delete the whole partition directory
      final dirIndex = _dirIndexForPartition(partitionIndex);
      final dirPath = _dataStore.pathManager
          .getTransactionPartitionDirPath(dirIndex, partitionIndex);
      try {
        await _dataStore.storage.deleteDirectory(dirPath);

        // Check if the directory shard is now empty and remove it if so
        final shardPath =
            _dataStore.pathManager.getTransactionDirShardPath(dirIndex);
        bool shardIsEmpty = false;
        try {
          if (await _dataStore.storage.existsDirectory(shardPath)) {
            final files = await _dataStore.storage.listDirectory(shardPath);
            // Check if directory is empty or only contains temporary/metadata files
            shardIsEmpty = files.isEmpty ||
                files.every((f) =>
                    f.endsWith('.tmp') ||
                    f.endsWith('meta.json') ||
                    f.contains('meta.json'));
            if (shardIsEmpty) {
              await _dataStore.storage.deleteDirectory(shardPath);
            }
          } else {
            shardIsEmpty = true;
          }
        } catch (_) {
          // If we can't check, assume not empty to be safe
          shardIsEmpty = false;
        }
      } catch (e) {
        Logger.warn('Delete txn partition dir failed', rawError: e);
      }
      _partitionMetaCache.remove(partitionIndex);
      _mainMetaCache?.activePartitions.remove(partitionIndex);
      await _persistMainMeta(flush: false);
    }
  }

  /// Stream unfinished transaction IDs partition-by-partition to reduce memory usage
  Stream<String> streamUnfinishedTransactions() async* {
    await initialize();
    final partitions = List<int>.from(_mainMetaCache!.activePartitions);
    final yieldController = YieldController('txn_stream_unfinished');
    for (final p in partitions) {
      await yieldController.maybeYield();

      try {
        final pDirIndex = _dirIndexForPartition(p);
        final statusPath = _dataStore.pathManager
            .getTransactionPartitionStatusLogPath(pDirIndex, p);
        if (!await _dataStore.storage.existsFile(statusPath)) continue;

        final begins = <String>{};
        final finished = <String>{};
        final events = await _readTxnLogEvents(statusPath, p);
        for (final ev in events) {
          await yieldController.maybeYield();
          final id = ev.transactionId;
          if (ev.event == TxnLogEventType.begin) {
            begins.add(id);
          } else if (ev.event == TxnLogEventType.commit ||
              ev.event == TxnLogEventType.rollback) {
            finished.add(id);
          }
        }

        for (final id in begins) {
          await yieldController.maybeYield();
          if (!finished.contains(id)) {
            yield id;
          }
        }
      } catch (e) {
        Logger.warn('Stream unfinished tx failed for p=$p', rawError: e);
      }
    }
  }

  Future<TableSchema?> _resolveTableSchemaFromField(String tableField) async {
    final normalized =
        await _dataStore.tableMetaManager?.normalizeTableFieldKey(tableField) ??
            tableField;
    final ctx = await _dataStore.tableMetaManager
        ?.getTableContext(TableUid(normalized));
    if (ctx == null) return null;
    return _dataStore.tableMetaManager?.getTableSchema(ctx.tableUid);
  }

  Future<TxnTableCodecContext?> _resolveTxnTableCodec(String tableUid) async {
    final schema = await _resolveTableSchemaFromField(tableUid);
    if (schema == null) return null;
    final normalized =
        await _dataStore.tableMetaManager?.normalizeTableFieldKey(tableUid) ??
            tableUid;
    final struct = await _dataStore.tableMetaManager
            ?.getStorageFieldStructure(TableUid(normalized), schema: schema) ??
        const [];
    return TxnTableCodecContext(
      primaryKeyField: schema.primaryKey,
      fieldStructure: struct,
    );
  }

  Future<void> _appendTxnEvent(
    String path,
    TxnLogEvent event,
    int partitionIndex, {
    int? knownBaseSize,
  }) async {
    final record = await TxnEncoder.encodeAsRecord(
      event,
      partitionIndex,
      resolveTable: _resolveTxnTableCodec,
    );
    await _dataStore.storage.appendBytes(path, record, flush: false);
    _logSizeCache ??= <String, int>{};
    final cached = _logSizeCache![path];
    if (knownBaseSize != null) {
      _logSizeCache![path] = knownBaseSize + record.length;
    } else if (cached != null) {
      _logSizeCache![path] = cached + record.length;
    } else {
      // After append, filesystem size includes this record.
      _logSizeCache![path] = await _dataStore.storage.getFileSize(path);
    }
  }

  Future<List<TxnLogEvent>> _readTxnLogEvents(
    String path,
    int partitionIndex,
  ) async {
    if (!await _dataStore.storage.existsFile(path)) return const [];
    final bytes = await _dataStore.storage.readAsBytes(path);
    if (bytes.isEmpty) return const [];
    return TxnEncoder.decodeFile(
      bytes,
      partitionIndex,
      resolveTable: _resolveTxnTableCodec,
    );
  }

  Future<Map<String, List<Map<String, dynamic>>>> _normalizeCommitPlanTableMap(
    Map<String, List<Map<String, dynamic>>> byTable,
  ) async {
    final mgr = _dataStore.tableMetaManager;
    if (mgr == null) return byTable;
    final normalized = <String, List<Map<String, dynamic>>>{};
    for (final entry in byTable.entries) {
      final key = await mgr.normalizeTableFieldKey(entry.key);
      normalized.putIfAbsent(key, () => []).addAll(entry.value);
    }
    return normalized;
  }

  Future<TransactionCommitPlan> _withNormalizedTableKeys(
      TransactionCommitPlan plan) async {
    return TransactionCommitPlan(
      transactionId: plan.transactionId,
      inserts: await _normalizeCommitPlanTableMap(plan.inserts),
      updates: await _normalizeCommitPlanTableMap(plan.updates),
      deletes: await _normalizeCommitPlanTableMap(plan.deletes),
      heavyDeletes: plan.heavyDeletes,
      heavyUpdates: plan.heavyUpdates,
    );
  }
}

/// Internal class to represent a deferred cascade delete operation
class _CascadeDeleteOp {
  final TableUid tableUid;
  final dynamic
      deletedPkValues; // Can be a single value or Map for composite keys

  _CascadeDeleteOp({
    required this.tableUid,
    required this.deletedPkValues,
  });
}

/// Internal class to represent a deferred cascade update operation
class _CascadeUpdateOp {
  final TableUid tableUid;
  final dynamic oldPkValues; // Can be a single value or Map for composite keys
  final dynamic newPkValues; // Can be a single value or Map for composite keys

  _CascadeUpdateOp({
    required this.tableUid,
    required this.oldPkValues,
    required this.newPkValues,
  });
}
