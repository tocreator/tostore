import 'dart:convert';
import '../model/buffer_entry.dart';
import '../handler/logger.dart';
// common utilities may be used by callers; keep imports minimal here
import 'transaction_context.dart';
import '../model/transaction_models.dart';
import '../model/data_store_config.dart';
import 'data_store_impl.dart';
import '../query/query_condition.dart';
import 'crontab_manager.dart';
import '../model/id_generator.dart';
import 'write_buffer_manager.dart';
import 'yield_controller.dart';
import 'tree_cache.dart';

/// Transaction manager: append-only per-partition logs with compact meta
class TransactionManager {
  final DataStoreImpl _dataStore;
  DataStoreConfig get _config => _dataStore.config;

  TransactionMainMeta? _mainMetaCache;
  final Map<int, TransactionPartitionMeta> _partitionMetaCache = {};
  final Set<String> _activeTransactions = <String>{};

  // In-memory cache of transaction final status to avoid repeated file scans.
  // true => committed, false => rolled back. Absence => unknown/not finalized.
  final Map<String, bool> _txnStatusCache = <String, bool>{};

  // Track per-transaction write-set for SSI: txId -> { table -> Set<pk> }
  final Map<String, Map<String, Set<String>>> _txnWriteSets =
      <String, Map<String, Set<String>>>{};
  // Recently committed write index for SSI: [tableName, pk] -> lastCommitTimeMillis
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
      Logger.warn('periodicCleanup failed: $e', label: 'TxnManager');
    } finally {
      _cleanupRunning = false;
    }
  }

  Future<void> initialize() async {
    if (_mainMetaCache != null) {
      return;
    }
    try {
      final path = _dataStore.pathManager.getTransactionMainMetaPath();
      if (await _dataStore.storage.existsFile(path)) {
        final content = await _dataStore.storage.readAsString(path);
        if (content != null && content.isNotEmpty) {
          _mainMetaCache = TransactionMainMeta.fromJson(
              jsonDecode(content) as Map<String, dynamic>);
        }
      }
    } catch (e) {
      Logger.warn('Load TransactionMainMeta failed: $e', label: 'TxnManager');
    }
    _mainMetaCache ??= TransactionMainMeta();

    // Initialize TreeCache for recent committed writes (SSI index)
    // Key format: [tableName, pk], Value: lastCommitTimeMillis (int)
    // Using TreeCache for automatic LRU eviction in large-scale data scenarios
    final memoryManager = _dataStore.memoryManager;
    final cacheSize = memoryManager?.getMetaCacheSize() ?? (32 * 1024 * 1024);
    // Allocate 10% of meta cache for transaction SSI index
    final int maxBytes = (cacheSize * 0.10).toInt();
    _recentCommittedWrites = TreeCache<int>(
      sizeCalculator: (_) => 8, // int timestamp = 8 bytes
      maxByteThreshold: maxBytes,
      minByteThreshold: 10 * 1024 * 1024, // 10MB minimum
      groupDepth: 1, // Group by tableName
      debugLabel: 'RecentCommittedWrites',
    );

    // Register periodic cleanup via CrontabManager (idempotent)
    try {
      if (!_cleanupRegistered && _dataStore.config.enableTransactionCleanup) {
        CrontabManager.addCallback(ExecuteInterval.minutes5, () async {
          try {
            final now = DateTime.now().millisecondsSinceEpoch;
            if (now - _lastPeriodicCleanupMs <
                _dataStore.config.transactionCleanupIntervalMs) return;
            _lastPeriodicCleanupMs = now;
            await periodicCleanup(
                nowMs: now, ttlMs: _dataStore.config.transactionMetaTtlMs);
          } catch (_) {}
        });
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
    final statusLine = '${jsonEncode({
          'transactionId': txId,
          'event': 'begin',
          'timestamp': DateTime.now().toIso8601String(),
        })}\n';
    await _dataStore.storage.appendString(statusPath, statusLine, flush: false);

    // Track active transaction in memory for fast checks
    _activeTransactions.add(txId);
    // initialize write set bucket
    _txnWriteSets.putIfAbsent(txId, () => <String, Set<String>>{});
    return txId;
  }

  /// Mark transaction committed; optionally persist recovery artifacts depending on policy, then remove transaction data.
  Future<void> commit(String transactionId, {bool? persistRecovery}) async {
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
    final statusLine = '${jsonEncode({
          'transactionId': transactionId,
          'event': 'commit',
          'timestamp': DateTime.now().toIso8601String(),
        })}\n';
    await _dataStore.storage.appendString(statusPath, statusLine, flush: false);

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
        // Fallback to current WAL partition if nothing was captured
        if (walPaths.isEmpty) {
          final walIdx = _dataStore.walManager.currentPointer.partitionIndex;
          final walDirIndex =
              _dataStore.walManager.getPartitionDirIndex(walIdx);
          if (walDirIndex != null) {
            final fallbackWal = _dataStore.pathManager.getWalPartitionLogPath(
                walDirIndex, walIdx,
                spaceName: _dataStore.currentSpaceName);
            walPaths.add(fallbackWal);
          } else {
            Logger.warn(
              'Cannot find dirIndex for WAL partition $walIdx, skipping WAL flush',
              label: 'TxnManager.commit',
            );
          }
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
      Logger.warn('Flush on commit failed: $e', label: 'TxnManager');
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
        writesByTable.forEach((table, keys) {
          for (final k in keys) {
            // Use TreeCache: key format [tableName, pk], value: timestamp
            // TreeCache automatically handles LRU eviction when size exceeds threshold
            _recentCommittedWrites.put([table, k], nowMs);
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
    try {
      // Unified storage with cross-partition continuation when hitting size threshold
      final currentIndex = _dataStore.pathManager
          .parseTransactionPartitionIndex(plan.transactionId);
      final currentDirIndex = _dirIndexForPartition(currentIndex);
      await _dataStore.storage.ensureDirectoryExists(_dataStore.pathManager
          .getTransactionPartitionDirPath(currentDirIndex, currentIndex));
      final currentLogPath = _dataStore.pathManager
          .getTransactionPartitionLogPath(currentDirIndex, currentIndex);
      final planLine = jsonEncode({
        'transactionId': plan.transactionId,
        'event': 'plan',
        'timestamp': DateTime.now().toIso8601String(),
        'plan': plan.toJson(),
      });
      // Use in-memory size cache to avoid frequent filesystem size calls
      _logSizeCache ??= <String, int>{};
      final cachedSize = _logSizeCache![currentLogPath];
      final int currentSize =
          cachedSize ?? await _dataStore.storage.getFileSize(currentLogPath);
      final int planBytes = utf8.encode('$planLine\n').length;
      final int threshold = _config.maxLogPartitionFileSize;

      if (currentSize > 0 && currentSize + planBytes > threshold) {
        // Mark continuation at tail and write plan into next partition's log
        final int nextIndex = _nextPartitionIndex(currentIndex);
        final continueLine = jsonEncode({
          'transactionId': plan.transactionId,
          'event': 'continue_in_next_partition',
          'nextPartitionIndex': nextIndex,
          'timestamp': DateTime.now().toIso8601String(),
        });
        await _dataStore.storage
            .appendString(currentLogPath, '$continueLine\n', flush: false);
        _logSizeCache![currentLogPath] =
            (cachedSize ?? 0) + utf8.encode('$continueLine\n').length;

        // Ensure next partition directory exists
        final nextDirIndex = _dirIndexForPartition(nextIndex);
        final nextDir = _dataStore.pathManager
            .getTransactionPartitionDirPath(nextDirIndex, nextIndex);
        await _dataStore.storage.ensureDirectoryExists(nextDir);
        final nextLogPath = _dataStore.pathManager
            .getTransactionPartitionLogPath(nextDirIndex, nextIndex);
        await _dataStore.storage
            .appendString(nextLogPath, '$planLine\n', flush: false);
        _logSizeCache![nextLogPath] =
            (_logSizeCache![nextLogPath] ?? 0) + planBytes;

        // Write plan_persisted hints to both status logs (best-effort)
        try {
          final currStatus = _dataStore.pathManager
              .getTransactionPartitionStatusLogPathById(
                  plan.transactionId, currentDirIndex);
          final nextStatus = _dataStore.pathManager
              .getTransactionPartitionStatusLogPath(nextDirIndex, nextIndex);
          final hintCurr = jsonEncode({
            'transactionId': plan.transactionId,
            'event': 'plan_persisted',
            'timestamp': DateTime.now().toIso8601String(),
            'continuedTo': nextIndex,
          });
          final hintNext = jsonEncode({
            'transactionId': plan.transactionId,
            'event': 'plan_persisted',
            'timestamp': DateTime.now().toIso8601String(),
          });
          await _dataStore.storage.ensureDirectoryExists(_dataStore.pathManager
              .getTransactionPartitionDirPath(currentDirIndex, currentIndex));
          await _dataStore.storage
              .appendString(currStatus, '$hintCurr\n', flush: false);
          await _dataStore.storage
              .appendString(nextStatus, '$hintNext\n', flush: false);
        } catch (_) {}
      } else {
        await _dataStore.storage
            .appendString(currentLogPath, '$planLine\n', flush: false);
        _logSizeCache![currentLogPath] = (cachedSize ?? 0) + planBytes;
        try {
          final statusPath = _dataStore.pathManager
              .getTransactionPartitionStatusLogPathById(
                  plan.transactionId, currentDirIndex);
          final hint = jsonEncode({
            'transactionId': plan.transactionId,
            'event': 'plan_persisted',
            'timestamp': DateTime.now().toIso8601String(),
          });
          await _dataStore.storage.ensureDirectoryExists(_dataStore.pathManager
              .getTransactionPartitionDirPath(currentDirIndex, currentIndex));
          await _dataStore.storage
              .appendString(statusPath, '$hint\n', flush: false);
        } catch (_) {}
      }
      // Rotate partition if needed (size-based)
      await rotateIfNeeded();
    } catch (e) {
      Logger.warn('Persist commit plan failed: $e', label: 'TxnManager');
    }
  }

  /// Load commit plan (unified: from partition append-only log, early return on first match)
  Future<TransactionCommitPlan?> loadCommitPlan(String transactionId) async {
    // Try file first
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
        TransactionCommitPlan? found;
        int? nextIndex;
        final stream = _dataStore.storage.readLinesStream(logPath);
        await for (final line in stream) {
          if (line.isEmpty) continue;
          try {
            final obj = jsonDecode(line) as Map<String, dynamic>;
            final ev = obj['event'] as String?;
            if (ev == 'plan' && obj['transactionId'] == transactionId) {
              final planMap = obj['plan'] as Map<String, dynamic>;
              found = TransactionCommitPlan.fromJson(planMap);
              return found;
            }
            if (ev == 'continue_in_next_partition' &&
                obj['transactionId'] == transactionId) {
              final ni = obj['nextPartitionIndex'];
              if (ni is int) {
                nextIndex = ni;
              }
            }
          } catch (_) {}
        }
        if (nextIndex == null) return null; // no continuation
        currentIndex = nextIndex;
      }
      return null;
    } catch (e) {
      Logger.warn('Load commit plan from partition log failed: $e',
          label: 'TxnManager');
      return null;
    }
  }

  /// Apply commit plan during crash recovery (idempotent): write updates/deletes into buffers and flush.
  Future<void> applyCommitPlan(TransactionCommitPlan plan) async {
    try {
      // Resume from plan progress checkpoint (per-table applied counts)
      final progress = await _loadPlanProgress(plan.transactionId);

      int processedSinceLastCheckpoint = 0;
      const int checkpointEvery = 1000; // persist progress every N operations

      Future<void> maybeCheckpoint() async {
        processedSinceLastCheckpoint++;
        if (processedSinceLastCheckpoint >= checkpointEvery) {
          await _persistPlanProgress(plan.transactionId, progress['inserts']!,
              progress['updates']!, progress['deletes']!);
          processedSinceLastCheckpoint = 0;
        }
      }

      // Cache primary key names per table to reduce schema IO
      final Map<String, String> pkByTable = <String, String>{};

      Future<String> ensurePk(String table) async {
        var pk = pkByTable[table];
        if (pk != null && pk.isNotEmpty) return pk;
        final schema = await _dataStore.schemaManager?.getTableSchema(table);
        pk = schema?.primaryKey ?? 'id';
        pkByTable[table] = pk;
        return pk;
      }

      // Re-enact inserts as INSERT to unified range partition write
      final yieldController = YieldController('txn_apply_commit_plan');
      for (final entry in plan.inserts.entries) {
        final table = entry.key;
        final recs = entry.value;
        final startIdx = progress['inserts']![table] ?? 0;
        for (int i = startIdx; i < recs.length; i++) {
          await yieldController.maybeYield();
          final rec = Map<String, dynamic>.from(recs[i]);
          rec.remove('_oldValues'); // inserts do not use oldValues
          final uniqueKeysList = rec.remove('_uniqueKeys') as List?;
          final uniqueKeys = uniqueKeysList
              ?.map((e) => UniqueKeyRef.fromJson(e as Map<String, dynamic>))
              .toList();

          await _dataStore.tableDataManager.addToBuffer(
              table, rec, BufferOperationType.insert,
              uniqueKeyRefs: uniqueKeys);
          progress['inserts']![table] = i + 1;
          await maybeCheckpoint();
        }
      }
      for (final entry in plan.updates.entries) {
        final table = entry.key;
        final recs = entry.value;
        final startIdx = progress['updates']![table] ?? 0;
        for (int i = startIdx; i < recs.length; i++) {
          await yieldController.maybeYield();
          final rec = Map<String, dynamic>.from(recs[i]);
          final old = rec.remove('_oldValues') as Map<String, dynamic>?;
          final uniqueKeysList = rec.remove('_uniqueKeys') as List?;
          final uniqueKeys = uniqueKeysList
              ?.map((e) => UniqueKeyRef.fromJson(e as Map<String, dynamic>))
              .toList();

          await _dataStore.tableDataManager.addToBuffer(
              table, rec, BufferOperationType.update,
              oldValues: old, uniqueKeyRefs: uniqueKeys);
          progress['updates']![table] = i + 1;
          await maybeCheckpoint();
        }
      }
      for (final entry in plan.deletes.entries) {
        final table = entry.key;
        final recs = entry.value; // now full records
        if (recs.isEmpty) continue;
        final startIdx = progress['deletes']![table] ?? 0;
        const int batchSize = 1000;
        for (int i = startIdx; i < recs.length; i += batchSize) {
          await yieldController.maybeYield();
          final end =
              (i + batchSize < recs.length) ? i + batchSize : recs.length;
          final batch = <Map<String, dynamic>>[];
          final cacheKeys = <String>[];
          String? pkName;
          for (int j = i; j < end; j++) {
            await yieldController.maybeYield();
            final rec = Map<String, dynamic>.from(recs[j]);
            rec.remove('_oldValues'); // delete: old values not used
            batch.add(rec);
            try {
              pkName ??= await ensurePk(table);
              final k = rec[pkName]?.toString();
              if (k != null && k.isNotEmpty) cacheKeys.add(k);
            } catch (_) {}
          }
          await _dataStore.tableDataManager.addToDeleteBuffer(table, batch);
          progress['deletes']![table] = end;
          processedSinceLastCheckpoint += (end - i);
          if (processedSinceLastCheckpoint >= checkpointEvery) {
            await _persistPlanProgress(plan.transactionId, progress['inserts']!,
                progress['updates']!, progress['deletes']!);
            processedSinceLastCheckpoint = 0;
          }
        }
      }

      // Execute deferred cascade delete operations (commit-time, after all main operations)
      final cascadeDeletes = getDeferredCascadeDeletes(plan.transactionId);
      if (cascadeDeletes.isNotEmpty && _dataStore.foreignKeyManager != null) {
        for (final cd in cascadeDeletes) {
          await yieldController.maybeYield();
          try {
            await _dataStore.foreignKeyManager!.handleCascadeDelete(
              tableName: cd.tableName,
              deletedPkValues: cd.deletedPkValues,
              skipRestrictCheck:
                  true, // RESTRICT already checked when delete was attempted
            );
          } catch (e) {
            Logger.warn(
                'Cascade delete during applyCommitPlan failed on ${cd.tableName}: $e',
                label: 'TxnManager');
            rethrow;
          }
        }
      }

      // Execute deferred cascade update operations (commit-time, after cascade deletes)
      final cascadeUpdates = getDeferredCascadeUpdates(plan.transactionId);
      if (cascadeUpdates.isNotEmpty && _dataStore.foreignKeyManager != null) {
        for (final cu in cascadeUpdates) {
          await yieldController.maybeYield();
          try {
            await _dataStore.foreignKeyManager!.handleCascadeUpdate(
              tableName: cu.tableName,
              oldPkValues: cu.oldPkValues,
              newPkValues: cu.newPkValues,
              visitedTables: null,
              skipRestrictCheck:
                  true, // RESTRICT already checked when update was attempted
            );
          } catch (e) {
            Logger.warn(
                'Cascade update during applyCommitPlan failed on ${cu.tableName}: $e',
                label: 'TxnManager');
            rethrow;
          }
        }
      }

      // Execute deferred heavy delete plans (commit-time, idempotent via internal checkpoints)
      if (plan.heavyDeletes.isNotEmpty) {
        for (final hd in plan.heavyDeletes) {
          await yieldController.maybeYield();
          try {
            final qc = QueryCondition.fromMap(hd.condition);
            await _dataStore.deleteInternal(
              hd.tableName,
              qc,
              orderBy: hd.orderBy,
              limit: hd.limit,
              offset: hd.offset,
              allowAll: false,
            );
          } catch (e) {
            Logger.warn(
                'Heavy delete during applyCommitPlan failed on ${hd.tableName}: $e',
                label: 'TxnManager');
            rethrow;
          }
        }
      }

      // Execute deferred heavy update plans (commit-time, idempotent via internal checkpoints)
      if (plan.heavyUpdates.isNotEmpty) {
        for (final hu in plan.heavyUpdates) {
          await yieldController.maybeYield();
          try {
            final qc = QueryCondition.fromMap(hu.condition);
            await _dataStore.updateInternal(
              hu.tableName,
              hu.updateData,
              qc,
              orderBy: hu.orderBy,
              limit: hu.limit,
              offset: hu.offset,
              allowAll: false,
            );
          } catch (e) {
            Logger.warn(
                'Heavy update during applyCommitPlan failed on ${hu.tableName}: $e',
                label: 'TxnManager');
            rethrow;
          }
        }
      }

      // Final checkpoint before flush
      await _persistPlanProgress(plan.transactionId, progress['inserts']!,
          progress['updates']!, progress['deletes']!);

      _dataStore.tableDataManager.clearTransactionState(plan.transactionId);
    } catch (e) {
      Logger.warn('Apply commit plan failed: $e', label: 'TxnManager');
      rethrow;
    }
  }

  /// Load plan application progress from status.log
  Future<Map<String, Map<String, int>>> _loadPlanProgress(
      String transactionId) async {
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
        final stream = _dataStore.storage.readLinesStream(statusPath);
        await for (final line in stream) {
          if (line.isEmpty) continue;
          try {
            final obj = jsonDecode(line) as Map<String, dynamic>;
            if (obj['transactionId'] == transactionId &&
                obj['event'] == 'plan_progress') {
              final i = (obj['insertsApplied'] as Map<String, dynamic>?)
                      ?.map((k, v) => MapEntry(k, (v as num).toInt())) ??
                  const <String, int>{};
              final u = (obj['updatesApplied'] as Map<String, dynamic>?)
                      ?.map((k, v) => MapEntry(k, (v as num).toInt())) ??
                  const <String, int>{};
              final d = (obj['deletesApplied'] as Map<String, dynamic>?)
                      ?.map((k, v) => MapEntry(k, (v as num).toInt())) ??
                  const <String, int>{};
              inserts.addAll(i);
              updates.addAll(u);
              deletes.addAll(d);
            }
          } catch (_) {}
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
    try {
      final pIndex =
          _dataStore.pathManager.parseTransactionPartitionIndex(transactionId);
      if (pIndex < 0) return;
      final dirIndex = _dirIndexForPartition(pIndex);
      await _dataStore.storage.ensureDirectoryExists(_dataStore.pathManager
          .getTransactionPartitionDirPath(dirIndex, pIndex));
      final statusPath = _dataStore.pathManager
          .getTransactionPartitionStatusLogPathById(transactionId, dirIndex);
      final line = jsonEncode({
        'transactionId': transactionId,
        'event': 'plan_progress',
        'timestamp': DateTime.now().toIso8601String(),
        'insertsApplied': insertsApplied,
        'updatesApplied': updatesApplied,
        'deletesApplied': deletesApplied,
      });
      await _dataStore.storage
          .appendString(statusPath, '$line\n', flush: false);
    } catch (_) {}
  }

  /// Recovery: continue unfinished transactions by applying plans or rolling back
  Future<void> recoverUnfinishedTransactionsOnStartup() async {
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
          Logger.warn('Recovery for $txId failed: $e', label: 'TxnManager');
        }
      }
    } catch (e) {
      Logger.warn('recoverUnfinishedTransactionsOnStartup failed: $e',
          label: 'TxnManager');
    }
  }

  /// Mark transaction rolled back; the caller should already have applied the compensating operations
  Future<void> rollback(String transactionId) async {
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
    final statusLine = '${jsonEncode({
          'transactionId': transactionId,
          'event': 'rollback',
          'timestamp': DateTime.now().toIso8601String(),
        })}\n';
    await _dataStore.storage.appendString(statusPath, statusLine, flush: false);

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
  void registerWriteKey(String txId, String tableName, String primaryKey) {
    try {
      final byTable =
          _txnWriteSets.putIfAbsent(txId, () => <String, Set<String>>{});
      final set = byTable.putIfAbsent(tableName, () => <String>{});
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
      String txId, String tableName, dynamic deletedPkValues) {
    final list =
        _txnCascadeDeletes.putIfAbsent(txId, () => <_CascadeDeleteOp>[]);
    list.add(_CascadeDeleteOp(
      tableName: tableName,
      deletedPkValues: deletedPkValues,
    ));
  }

  /// Get deferred cascade delete operations for a transaction
  List<_CascadeDeleteOp> getDeferredCascadeDeletes(String txId) {
    final list = _txnCascadeDeletes[txId];
    if (list == null) return const <_CascadeDeleteOp>[];
    return List<_CascadeDeleteOp>.from(list);
  }

  /// Register a deferred cascade update operation for a transaction
  void registerDeferredCascadeUpdate(
      String txId, String tableName, dynamic oldPkValues, dynamic newPkValues) {
    final list =
        _txnCascadeUpdates.putIfAbsent(txId, () => <_CascadeUpdateOp>[]);
    list.add(_CascadeUpdateOp(
      tableName: tableName,
      oldPkValues: oldPkValues,
      newPkValues: newPkValues,
    ));
  }

  /// Get deferred cascade update operations for a transaction
  List<_CascadeUpdateOp> getDeferredCascadeUpdates(String txId) {
    final list = _txnCascadeUpdates[txId];
    if (list == null) return const <_CascadeUpdateOp>[];
    return List<_CascadeUpdateOp>.from(list);
  }

  /// SSI conflict detection: for each read key, if a different tx committed a write
  /// after this tx's start, report conflict.
  Future<List<String>> checkSerializableConflictsTransactional(
      Map<String, Set<String>> readKeysByTable,
      DateTime startedAt,
      String currentTxId) async {
    final conflicts = <String>[];
    try {
      final startMs = startedAt.millisecondsSinceEpoch;

      for (final e in readKeysByTable.entries) {
        final table = e.key;
        final keys = e.value;
        if (keys.isEmpty) continue;
        final yieldController = YieldController('txn_ssi_check');
        for (final k in keys) {
          await yieldController.maybeYield();
          // Use TreeCache: key format [tableName, pk]
          final lastMs = _recentCommittedWrites.get([table, k]);
          if (lastMs != null && lastMs > startMs) {
            conflicts.add('$table:$k');
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

      // Stream lines to avoid loading large files into memory.
      final stream = _dataStore.storage.readLinesStream(statusPath);
      final yieldController = YieldController('txn_is_committed_scan');
      await for (final line in stream) {
        await yieldController.maybeYield();
        if (line.isEmpty) continue;
        try {
          final m = jsonDecode(line) as Map<String, dynamic>;
          if (m['transactionId'] == transactionId) {
            final ev = (m['event'] as String?)?.toLowerCase();
            if (ev == 'commit') {
              _txnStatusCache[transactionId] = true;
              return true;
            }
            if (ev == 'rollback') {
              _txnStatusCache[transactionId] = false;
              return false;
            }
          }
        } catch (_) {}
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
      Logger.warn('Load txn partition meta failed: $e', label: 'TxnManager');
      meta = TransactionPartitionMeta(partitionIndex: partitionIndex);
    }
    _partitionMetaCache[partitionIndex] = meta;
    return meta;
  }

  Future<void> _persistPartitionMeta(TransactionPartitionMeta meta,
      {bool flush = false}) async {
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
    final path = _dataStore.pathManager.getTransactionMainMetaPath();
    await _dataStore.storage.writeAsString(
        path, jsonEncode(_mainMetaCache!.toJson()),
        flush: flush);
  }

  Future<void> _maybeCleanupPartition(int partitionIndex) async {
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
        Logger.warn('Delete txn partition dir failed: $e', label: 'TxnManager');
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
        // Strategy: small files -> readAsLines; large -> streaming
        final fileSize = await _dataStore.storage.getFileSize(statusPath);
        final threshold = _config.maxLogPartitionFileSize;

        final begins = <String>{};
        final finished = <String>{};
        if (fileSize <= threshold) {
          final lines = await _dataStore.storage.readAsLines(statusPath);
          for (final line in lines) {
            await yieldController.maybeYield();
            if (line.isEmpty) continue;
            try {
              final m = jsonDecode(line) as Map<String, dynamic>;
              final id = m['transactionId'] as String?;
              final ev = m['event'] as String?;
              if (id == null || ev == null) continue;
              if (ev == 'begin') {
                begins.add(id);
              } else if (ev == 'commit' || ev == 'rollback') {
                finished.add(id);
              }
            } catch (_) {}
          }
        } else {
          final stream = _dataStore.storage.readLinesStream(statusPath);
          await for (final line in stream) {
            await yieldController.maybeYield();
            if (line.isEmpty) continue;
            try {
              final m = jsonDecode(line) as Map<String, dynamic>;
              final id = m['transactionId'] as String?;
              final ev = m['event'] as String?;
              if (id == null || ev == null) continue;
              if (ev == 'begin') {
                begins.add(id);
              } else if (ev == 'commit' || ev == 'rollback') {
                finished.add(id);
              }
            } catch (_) {}
          }
        }

        for (final id in begins) {
          await yieldController.maybeYield();
          if (!finished.contains(id)) {
            yield id;
          }
        }
      } catch (e) {
        Logger.warn('Stream unfinished tx failed for p=$p: $e',
            label: 'TxnManager');
      }
    }
  }
}

/// Internal class to represent a deferred cascade delete operation
class _CascadeDeleteOp {
  final String tableName;
  final dynamic
      deletedPkValues; // Can be a single value or Map for composite keys

  _CascadeDeleteOp({
    required this.tableName,
    required this.deletedPkValues,
  });
}

/// Internal class to represent a deferred cascade update operation
class _CascadeUpdateOp {
  final String tableName;
  final dynamic oldPkValues; // Can be a single value or Map for composite keys
  final dynamic newPkValues; // Can be a single value or Map for composite keys

  _CascadeUpdateOp({
    required this.tableName,
    required this.oldPkValues,
    required this.newPkValues,
  });
}
