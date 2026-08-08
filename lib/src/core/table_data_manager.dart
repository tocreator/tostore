import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../handler/binary_schema_codec.dart';
import '../handler/logger.dart';
import '../handler/memcomparable.dart';
import '../handler/parallel_processor.dart';
import '../handler/space_stats_codec.dart';
import '../handler/topk_heap.dart';
import '../handler/value_matcher.dart';
import '../model/buffer_entry.dart';
import '../model/data_store_config.dart';
import '../model/db_exception.dart';
import '../model/id_generator.dart';
import '../model/meta_info.dart';
import '../model/parallel_journal_entry.dart';
import '../model/query_aggregation.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/space_stats.dart';
import '../model/table_context.dart';
import '../model/table_identity.dart';
import '../model/table_schema.dart';
import '../model/transaction_models.dart';
import '../model/wal_pointer.dart';
import '../query/query_condition.dart';
import '../query/query_executor.dart';
import 'compute/batch_match_runner.dart';
import 'compute/compute_batch_planner.dart';
import 'compute/delete_batch_prepare_compute.dart';
import 'compute/query_aggregate_compute.dart';
import 'compute_manager.dart';
import 'cpu_work_chunk.dart';
import 'crontab_manager.dart';
import 'data_store_impl.dart';
import 'resource_manager.dart';
import 'transaction_context.dart';
import 'tree_cache.dart';
import 'weight_manager.dart';
import 'workload_scheduler.dart';
import 'write_buffer_manager.dart';
import 'yield_controller.dart';

/// table data manager - schedule data read/write, backup, index update, etc.
class TableDataManager {
  final DataStoreImpl _dataStore;

  // Table refresh status flags
  final Map<String, bool> _tableFlushingFlags = {};

  /// Check if a table is currently being cleared/flushed
  bool isTableBeingCleared(TableContext table) {
    return _tableFlushingFlags.containsKey(table.tableUid);
  }

  Future<TableContext?> _tableContextFromUid(TableUid tableUid) async {
    return _dataStore.tableMetaManager?.getTableContext(tableUid);
  }

  // Store table partition size configuration (in bytes)
  final Map<String, int> _tablePartitionSizes = {};

  // Store table file size information
  final Map<String, int> _fileSizes = {};
  // Store file last modified time
  final Map<String, DateTime> _lastModifiedTimes = {};
  // Cache for accurate table record counts.
  // Updated synchronously on write/delete, and lazily loaded from metadata.
  final Map<String, int> _tableRecordCounts = {};
  // Loading futures to prevent thundering herd on concurrent inserts
  final Map<String, Future<void>> _recordCountLoadingFutures = {};

  /// Map of table names to futures that are currently loading table data metadata
  final Map<String, Future<TableDataMeta?>> _metaLoadingFutures = {};

  // Table data meta cache for table file metadata (TableDataMeta).
  late final TreeCache<TableDataMeta> _tableDataMetaCache;

  // -------------------- Table record cache --------------------
  // Composite key format: [tableUid, pk]
  late final TreeCache<Map<String, dynamic>> _tableRecordCache;

  // -------------------- Transactional structures --------------------
  // Per-transaction deferred ops (insert/update/delete) not written until commit
  // txId -> tableUid -> pk -> TxnDeferredOp
  final Map<String, Map<String, Map<String, TxnDeferredOp>>> _txnDeferredOps =
      {};

  // Lightweight accounting for transaction data retained in memory. Record
  // sizes are sampled only, so normal-resource transactions remain unbounded.
  final Map<String, _TransactionResourceEstimate> _txnResourceEstimates = {};

  static const int _transactionOperationWarningLimit = 50000;
  static const int _transactionBytesWarningLimit = 50 * 1024 * 1024;
  static const int _transactionSampleSize = 10;

  /// Add auto-increment ID to write buffer
  final Map<String, dynamic> _maxIds = {};
  final Map<String, bool> _maxIdsDirty = {}; // Mark if need to write

  /// ID generator cache
  final Map<String, IdGenerator> _idGenerators = {};

  /// Pending generator creation per table (ensures single instance under concurrency)
  final Map<String, Future<IdGenerator>> _idGeneratorPending = {};

  /// ID range storage data
  final Map<String, Map<String, dynamic>> _idRanges = {};

  /// Whether table has checked ordered range
  final Map<String, bool> _checkedOrderedRange = {};

  /// Client connected to central server
  CentralServerClient? _centralClient;

  // ---------------------------------------------------------------------------
  // SpaceStats (InternalKv `stats.space.v1`) — owned entirely here.
  //
  // Model: effective = baseline + sessionDelta
  // - baseline: loaded once from KV (or set by full recalculate / persist fold)
  // - delta: user-table insert/delete/clear / size deltas in this session
  // KV is never re-applied after first hydrate (avoids stale disk clobbering
  // live memory). System/internal tables never touch these counters.
  // ---------------------------------------------------------------------------
  int _baselineRecordCount = 0;
  int _baselineTableDataSizeBytes = 0;
  int _baselineIndexDataSizeBytes = 0;
  int _deltaRecordCount = 0;
  int _deltaTableDataSizeBytes = 0;
  int _deltaIndexDataSizeBytes = 0;
  DateTime? _lastStatisticsTime;
  bool _spaceStatsHydrated = false;
  Future<void>? _spaceStatsHydrateFuture;

  /// Single-flight for the expensive full scan only (policy checks are cheap).
  Future<void>? _recalculateAllStatisticsFuture;

  /// Whether the hour24 SpaceStats reconcile cron was registered.
  bool _spaceStatsReconcileCronRegistered = false;
  bool _needSaveStats = false;
  bool _persistingSpaceStats = false;

  /// Close/teardown: discard SpaceStats KV I/O (stats are best-effort).
  bool _spaceStatsKvSuppressed = false;

  static const Duration _spaceStatsReconcileStartupDelay =
      Duration(seconds: 10);

  /// True when SpaceStats background work must stop without logging.
  bool get _isSpaceStatsWorkAborted =>
      _spaceStatsKvSuppressed ||
      !_dataStore.isInitialized ||
      _dataStore.isClosing;

  /// Auto full-reconcile intervals by `_system_table_meta` row count
  /// (system tables are few; no user-only filter). `null` interval = disabled.
  static const int _spaceStatsReconcileDisableTableCount = 5000;
  static const int _spaceStatsReconcileDailyMaxTables = 50;
  static const int _spaceStatsReconcileWeeklyMaxTables = 500;

  // Throttling state for lightweight meta persistence
  DateTime _lastMaxIdFlushTime = DateTime.fromMillisecondsSinceEpoch(0);

  // --- End: Intelligent Polling Methods ---

  // Comparator registry for table primary keys
  final Map<String, Comparator<dynamic>> _pkComparators = {};

  /// Factory to provide comparators for TreeCache based on path (Table Record Cache)
  Comparator<dynamic> _tableRecordComparatorFactory(List<dynamic> path) {
    if (path.isNotEmpty) {
      final tableUid = path[0] as String;
      return _pkComparators[tableUid] ?? TreeCache.compareNative;
    }
    return TreeCache.compareNative;
  }

  /// Register a comparator for a table's primary key
  void _registerTableComparator(TableContext table, TableSchema schema) {
    final tableUid = table.tableUid;
    if (_pkComparators.containsKey(tableUid)) return;

    // Use ValueMatcher to get the correct comparator for the PK type
    final pdType = schema.getPrimaryKeyMatcherType();
    _pkComparators[tableUid] = ValueMatcher.getMatcher(pdType);
  }

  TableDataManager(this._dataStore) {
    // Initialize table record cache (table data quota).
    final mem = _dataStore.resourceManager;
    // Initialize table data metadata cache (meta quota slice).
    final int metaQuota = mem?.getMetaCacheSize() ?? (64 * 1024 * 1024);
    // Meta quota is shared by multiple caches (index meta, footers, etc.).
    // Allocate a conservative slice for table data metadata.
    final int tableDataMetaMax = max(1, (metaQuota * 0.25).toInt());
    _tableDataMetaCache = TreeCache<TableDataMeta>(
      sizeCalculator: _estimateTableDataMetaSize,
      maxByteThreshold: tableDataMetaMax,
      minByteThreshold: 50 * 1024 * 1024,
      debugLabel: 'TableDataMetaCache',
    );

    final int tableQuota =
        mem?.getTableDataCacheSize() ?? (128 * 1024 * 1024); // Default 128MB
    // Reserve a portion for range-partition caches (blocks + sparse index).
    final int maxBytes = max(1, (tableQuota * 0.55).toInt());
    _tableRecordCache = TreeCache<Map<String, dynamic>>(
      sizeCalculator: estimateRecordSizeBytes,
      maxByteThreshold: maxBytes,
      minByteThreshold: 50 * 1024 * 1024,
      comparatorFactory: _tableRecordComparatorFactory,
      weightQueryCallback: _queryTableRecordWeight,
      debugLabel: 'TableRecordCache',
    );

    // Initialize auto-increment ID generator and set periodic check task
    CrontabManager.addCallback(
        ExecuteInterval.seconds3, TimeBasedIdGenerator.periodicPoolCheck);
    // SpaceStats → InternalKv off the journal/close hot path (best-effort).
    CrontabManager.addCallback(
        ExecuteInterval.seconds30, _onSpaceStatsPersistTick);
    // Register daily reconcile only after startup settles (avoids open contention).
    unawaited(_registerSpaceStatsReconcileCronDelayed());
  }

  void _onSpaceStatsPersistTick() {
    if (!_needSaveStats || !_canPersistSpaceStatsKv) return;
    unawaited(
        _persistSpaceStatsToKv().catchError(_onSpaceStatsBackgroundError));
  }

  void _onSpaceStatsReconcileTick() {
    if (_isSpaceStatsWorkAborted) return;
    unawaited(
        _maybeReconcileSpaceStats().catchError(_onSpaceStatsBackgroundError));
  }

  /// Swallow close/switchSpace races; log only unexpected failures.
  void _onSpaceStatsBackgroundError(Object e, [StackTrace? _]) {
    if (_isSpaceStatsWorkAborted || e is DbClosedException) return;
    Logger.warn('Space stats background work failed', rawError: e);
  }

  /// One-shot: wait startup delay, then register hour24 and run first check.
  Future<void> _registerSpaceStatsReconcileCronDelayed() async {
    await Future.delayed(_spaceStatsReconcileStartupDelay);
    if (_isSpaceStatsWorkAborted || _spaceStatsReconcileCronRegistered) return;
    if (_dataStore.config.persistenceMode == PersistenceMode.memory) return;

    CrontabManager.addCallback(
        ExecuteInterval.hour24, _onSpaceStatsReconcileTick);
    _spaceStatsReconcileCronRegistered = true;
    _onSpaceStatsReconcileTick();
  }

  void _unregisterSpaceStatsReconcileCron() {
    if (!_spaceStatsReconcileCronRegistered) return;
    CrontabManager.removeCallback(
        ExecuteInterval.hour24, _onSpaceStatsReconcileTick);
    _spaceStatsReconcileCronRegistered = false;
  }

  // -------------------- Table record cache APIs --------------------
  /// Get a cached record by [pk] if present.
  ///
  /// Returns the cached map by reference (no copy). Callers must not mutate
  /// the result in place — treat it as read-only or copy before writing.
  Map<String, dynamic>? getCachedTableRecord(TableContext table, String pk) {
    return _tableRecordCache.get([table.tableUid, pk]);
  }

  /// Check if a record exists in the table record cache (O(1) fast check).
  /// Note: This returns true even for tombstones (deleted records) if they are in the cache.
  bool hasTableRecord(TableContext table, String pk) {
    return _tableRecordCache.containsKey([table.tableUid, pk]);
  }

  /// Check if a record exists in the table record cache and is NOT a tombstone.
  ///
  /// This is safer than [hasTableRecord] for uniqueness/existence checks.
  /// Uses TreeCache.peek() to avoid polluting access stats during hot validation loops.
  bool hasLiveTableRecord(TableContext table, String pk) {
    final rec = _tableRecordCache.get([table.tableUid, pk], updateStats: false);
    return rec != null && !isDeletedRecord(rec);
  }

  /// Returns true when the record is hidden by a delete overlay in the current
  /// visibility context, even if the physical row still exists on disk.
  bool isRecordHiddenByDeleteOverlay(TableContext table, String pk,
      {String? transactionId}) {
    final tableUid = table.tableUid;
    final currentTxId =
        transactionId ?? TransactionContext.getCurrentTransactionId();

    if (currentTxId != null) {
      final txOp = _txnDeferredOps[currentTxId]?[tableUid]?[pk];
      if (txOp != null) {
        return txOp.type == BufferOperationType.delete ||
            isDeletedRecord(txOp.data);
      }
    }

    final bufferEntry =
        _dataStore.writeBufferManager.getBufferedRecord(table, pk);
    if (bufferEntry == null) {
      return false;
    }

    return bufferEntry.operation == BufferOperationType.delete ||
        isDeletedRecord(bufferEntry.data);
  }

  /// Cache a single table record
  void cacheTableRecord(TableContext table, String pk,
      Map<String, dynamic> record, TableSchema schema,
      {bool force = false}) {
    final tableUid = table.tableUid;
    if (_tableRecordCache.maxByteThreshold <= 0) {
      return;
    }

    if (isDeletedRecord(record)) {
      _tableRecordCache.remove([tableUid, pk]);
      return;
    }

    // [Cache Optimization] Use Fast O(1) checks
    final bool alreadyInCache = _tableRecordCache.containsKey([tableUid, pk]);

    if (alreadyInCache || force || _dataStore.isGlobalPrewarming) {
      // Lazy registration of comparator
      _registerTableComparator(table, schema);

      _tableRecordCache.put(
        [tableUid, pk],
        record,
        size: estimateRecordSizeBytes(record),
      );
    }
  }

  /// Cache (or update) multiple table records
  ///
  /// [isInsertOperation] should be true for internal batch insert paths.
  void cacheTableRecordsBatch(
    TableContext table,
    List<Map<String, dynamic>> records, {
    required String primaryKey,
    required TableSchema schema,
    bool isInsertOperation = false,
    bool force = false,
  }) {
    if (records.isEmpty) return;
    final tableUid = table.tableUid;
    if (_tableRecordCache.maxByteThreshold <= 0) {
      return;
    }

    // [Optimization] We only update if it's already there or forced

    final doNotCache = !_dataStore.isGlobalPrewarming && !force;
    if (isInsertOperation && doNotCache) {
      return;
    }

    // Lazy registration of comparator
    _registerTableComparator(table, schema);

    for (final r in records) {
      final pk = r[primaryKey]?.toString();
      if (pk == null || pk.isEmpty) continue;
      if (isDeletedRecord(r)) continue;

      final key = [tableUid, pk];

      // If not forced/prewarming, we only update if it's already there
      if (doNotCache) {
        if (!_tableRecordCache.containsKey(key)) continue;
      }

      final value = r;
      final size = estimateRecordSizeBytes(value);
      _tableRecordCache.put(key, value, size: size);
    }
  }

  /// Asynchronously cache results fetched from disk after validating against write buffer.
  /// This prevents Read-Through Cache Pollution without blocking the main query flow.
  void _asyncCacheDiskResults({
    required TableContext table,
    required List<Map<String, dynamic>> diskResults,
    required TableSchema schema,
  }) {
    if (diskResults.isEmpty || _tableRecordCache.maxByteThreshold <= 0) return;

    // Execute in microtask to avoid blocking the current execution flow
    scheduleMicrotask(() async {
      final validatedForCache = <Map<String, dynamic>>[];
      final primaryKey = schema.primaryKey;

      for (final r in diskResults) {
        final pk = r[primaryKey]?.toString();
        if (pk == null) continue;

        // Only cache if the record is NOT marked as deleted in the global write buffer.
        final bufferEntry =
            _dataStore.writeBufferManager.getBufferedRecordForRead(
          table,
          pk,
        );
        if (bufferEntry != null &&
            bufferEntry.operation == BufferOperationType.delete) {
          continue;
        }

        validatedForCache.add(r);
      }

      if (validatedForCache.isNotEmpty) {
        cacheTableRecordsBatch(
          table,
          validatedForCache,
          primaryKey: primaryKey,
          schema: schema,
          force: true,
        );
      }
    });
  }

  /// Remove a cached table record (if present).

  void removeTableRecord(TableContext table, String pk) {
    _tableRecordCache.remove([table.tableUid, pk]);
  }

  /// Remove multiple cached table records.
  Future<void> removeTableRecords(TableContext table, List<String> pks) async {
    if (pks.isEmpty) return;
    final yieldController =
        YieldController('TableDataManager.removeTableRecords');
    for (final pk in pks) {
      final y1 = yieldController.maybeYield();
      if (y1 != null) await y1;
      _tableRecordCache.remove([table.tableUid, pk]);
    }
  }

  /// Remove all cached records of a table (used for drop/clear/space switching).
  Future<void> clearTableRecordsForTable(TableContext table) async {
    _tableRecordCache.remove([table.tableUid]);

    // Also remove from record count cache
    _tableRecordCounts.remove(table.tableUid);
  }

  /// Remove record count cache for a table.
  void removeRecordCountCache(TableContext table) {
    _tableRecordCounts.remove(table.tableUid);
  }

  /// Remove record count cache for all tables.
  void removeRecordCountCacheAll() {
    _tableRecordCounts.clear();
  }

  /// Evict a ratio of table record cache entries under memory pressure.
  Future<void> evictTableRecordCache({double ratio = 0.3}) async {
    await _tableRecordCache.cleanup(removeRatio: ratio);
  }

  /// Current table record cache size in bytes.
  int getCurrentTableRecordCacheSize() {
    return _tableRecordCache.estimatedTotalSizeBytes;
  }

  /// Estimate table data metadata size (bytes)
  int _estimateTableDataMetaSize(TableDataMeta meta) {
    // v2+ meta is small and fixed-shape (no partition lists).
    // Keep a conservative estimate to guide cache sizing.
    return 160 + meta.tableUid.length * 2;
  }

  /// Query weight for table record cache entry
  /// Path format: [tableUid, pk]
  /// Weight object is the tableUid
  Future<int?> _queryTableRecordWeight(List<dynamic> path) async {
    if (path.isEmpty) return null;
    final tableUid = path[0]?.toString();
    if (tableUid == null || tableUid.isEmpty) return null;

    try {
      final weightManager = _dataStore.weightManager;
      if (weightManager == null) return null;

      return await weightManager.getWeight(
        WeightType.tableRecord,
        tableUid,
      );
    } catch (e) {
      final logTable = (await _dataStore.tableMetaManager
                  ?.resolveTableNameFromField(tableUid))
              ?.value ??
          'unknown';
      Logger.warn('Failed to query table record weight for $logTable',
          rawError: e);
      return null;
    }
  }

  // -------------------- Record size estimation (TableRecordCache) --------------------

  int estimateRecordSizeBytes(Map<String, dynamic> record) {
    // Lightweight approximation with bounded traversal (avoid deep/full encoding).
    int size = 64; // base overhead
    if (record.isEmpty) return size;

    const int maxFieldsSample = 32;
    int sampled = 0;

    for (final e in record.entries) {
      // key
      size += 16;
      size += e.key.length * 2;
      // value
      size += _estimateDynamicSizeBytes(e.value, depth: 0);
      sampled++;
      if (sampled >= maxFieldsSample) break;
    }

    // If truncated, extrapolate by average per sampled field.
    if (record.length > sampled && sampled > 0) {
      final int per =
          ((size - 64) / sampled).ceil().clamp(0, 1024 * 1024); // cap avg
      size = 64 + per * record.length;
    }
    return size;
  }

  int _estimateDynamicSizeBytes(dynamic v, {required int depth}) {
    if (v == null) return 0;
    if (v is bool) return 1;
    if (v is int) return 8;
    if (v is double) return 8;
    if (v is num) return 16;
    if (v is DateTime) return 16;
    if (v is Uint8List) return v.length;
    if (v is String) return v.length * 2;

    // Bound recursion depth to avoid pathological nested structures.
    if (depth >= 2) return 32;

    if (v is List) {
      const int sample = 8;
      int size = 24; // list header
      final int n = v.length;
      final int take = n < sample ? n : sample;
      for (int i = 0; i < take; i++) {
        size += _estimateDynamicSizeBytes(v[i], depth: depth + 1);
      }
      if (n > take && take > 0) {
        final int per = ((size - 24) / take).ceil().clamp(0, 1024 * 1024);
        size = 24 + per * n;
      }
      return size;
    }

    if (v is Map) {
      const int sample = 8;
      int size = 48; // map header
      int taken = 0;
      for (final e in v.entries) {
        size += 16;
        final k = e.key;
        if (k is String) {
          size += k.length * 2;
        } else {
          size += 16;
        }
        size += _estimateDynamicSizeBytes(e.value, depth: depth + 1);
        taken++;
        if (taken >= sample) break;
      }
      if (v.length > taken && taken > 0) {
        final int per = ((size - 48) / taken).ceil().clamp(0, 1024 * 1024);
        size = 48 + per * v.length;
      }
      return size;
    }

    // Fallback for other objects.
    return 64;
  }

  /// Persist runtime metadata (max IDs) with throttling.
  /// When [force] is true, persist immediately if anything is dirty.
  Future<void> persistRuntimeMetaIfNeeded({bool force = false}) async {
    // Memory mode must not persist any metadata/config to storage.
    if (_dataStore.config.persistenceMode == PersistenceMode.memory) {
      return;
    }
    try {
      final now = DateTime.now();
      final int minIntervalMs = _dataStore.config.maxFlushLatencyMs;

      // Flush max IDs when dirty
      final bool hasDirtyIds = _maxIdsDirty.values.any((v) => v);
      if (hasDirtyIds) {
        final bool due = force ||
            now.difference(_lastMaxIdFlushTime).inMilliseconds >= minIntervalMs;
        if (due) {
          await flushMaxIds();
          _lastMaxIdFlushTime = DateTime.now();
        }
      }
    } catch (e) {
      Logger.warn('persistRuntimeMetaIfNeeded failed', rawError: e);
    }
  }

  /// Evict a ratio of table data metadata cache entries under memory pressure.
  Future<void> evictTableDataMetaCache({double ratio = 0.3}) async {
    try {
      await _tableDataMetaCache.cleanup(removeRatio: ratio);
    } catch (e) {
      Logger.warn('Evict table data meta cache failed', rawError: e);
    }
  }

  /// Invalidate cached table data metadata for a single table (best-effort).
  void invalidateTableDataMetaCacheForTable(TableContext table) {
    _tableDataMetaCache.remove(table.tableUid);
  }

  // -------------------- SpaceStats (KV-backed aggregates) --------------------

  int get _effectiveRecordCount =>
      max(0, _baselineRecordCount + _deltaRecordCount);
  int get _effectiveTableDataSizeBytes =>
      max(0, _baselineTableDataSizeBytes + _deltaTableDataSizeBytes);
  int get _effectiveIndexDataSizeBytes =>
      max(0, _baselineIndexDataSizeBytes + _deltaIndexDataSizeBytes);

  SpaceStats _spaceStatsSnapshot() => SpaceStats(
        totalRecordCount: _effectiveRecordCount,
        totalTableDataSizeBytes: _effectiveTableDataSizeBytes,
        totalIndexDataSizeBytes: _effectiveIndexDataSizeBytes,
        lastStatisticsTime: _lastStatisticsTime,
      );

  /// Live space aggregates (baseline + session delta). Hydrates KV once.
  Future<SpaceStats> getSpaceStats() async {
    await ensureSpaceStatsHydrated();
    return _spaceStatsSnapshot();
  }

  /// Whether SpaceStats may touch InternalKv (steady open only).
  bool get _canPersistSpaceStatsKv =>
      !_spaceStatsKvSuppressed &&
      _dataStore.isInitialized &&
      !_dataStore.isClosing &&
      !_dataStore.parallelJournalManager.isInRecoveryMode;

  /// Called from [DataStoreImpl.close]: drop best-effort SpaceStats KV work so
  /// close/switchSpace never blocks on InternalKv → tableMeta.
  void suppressSpaceStatsKvPersistence() {
    _spaceStatsKvSuppressed = true;
    _needSaveStats = false;
    _persistingSpaceStats = false;
    _spaceStatsHydrateFuture = null;
    _recalculateAllStatisticsFuture = null;
    _unregisterSpaceStatsReconcileCron();
  }

  /// Single-flight: load KV baseline once per manager lifetime.
  ///
  /// Only runs while the engine is fully open — never during close/re-init.
  Future<void> ensureSpaceStatsHydrated() async {
    if (_spaceStatsHydrated || _spaceStatsKvSuppressed) return;

    if (_dataStore.config.persistenceMode == PersistenceMode.memory) {
      _spaceStatsHydrated = true;
      return;
    }

    // Steady-state only: avoid InternalKv during close / before ready.
    if (!_dataStore.isInitialized || _dataStore.isClosing) {
      return;
    }

    _spaceStatsHydrateFuture ??= _hydrateSpaceStatsFromKv();
    await _spaceStatsHydrateFuture;
  }

  Future<void> _hydrateSpaceStatsFromKv() async {
    try {
      if (!_canPersistSpaceStatsKv) {
        _spaceStatsHydrateFuture = null;
        return;
      }
      final bytes = await TransactionContext.runAsSystemOperation(() async {
        return await _dataStore.internalKv.get(
          SpaceStats.kvKey,
          isGlobal: false,
        );
      });
      if (_spaceStatsKvSuppressed) return;
      if (!_spaceStatsHydrated) {
        final stats =
            bytes == null ? SpaceStats.empty : SpaceStatsCodec.decode(bytes);
        _baselineRecordCount = stats.totalRecordCount;
        _baselineTableDataSizeBytes = stats.totalTableDataSizeBytes;
        _baselineIndexDataSizeBytes = stats.totalIndexDataSizeBytes;
        _lastStatisticsTime = stats.lastStatisticsTime;
        _spaceStatsHydrated = true;
      }
    } on DbClosedException {
      _spaceStatsHydrateFuture = null;
    } catch (e) {
      _spaceStatsHydrateFuture = null;
      if (_isSpaceStatsWorkAborted || e is DbClosedException) {
        // close / switchSpace race — silent.
      } else {
        Logger.warn('Failed to hydrate space stats from InternalKv',
            rawError: e);
        if (_dataStore.isInitialized && !_dataStore.isClosing) {
          _spaceStatsHydrated = true;
        }
      }
    }
  }

  /// Full-reconcile cadence by table-meta row count. `null` = auto reconcile off.
  static Duration? spaceStatsReconcileInterval(int tableCount) {
    if (tableCount <= _spaceStatsReconcileDailyMaxTables) {
      return const Duration(days: 1);
    }
    if (tableCount <= _spaceStatsReconcileWeeklyMaxTables) {
      return const Duration(days: 7);
    }
    if (tableCount > _spaceStatsReconcileDisableTableCount) return null;
    return const Duration(days: 30);
  }

  /// One-shot (missing index baseline) or due periodic drift reconcile.
  ///
  /// Concurrent callers may race the cheap policy checks; the full scan is
  /// coalesced by [_recalculateAllStatisticsFuture].
  Future<void> _maybeReconcileSpaceStats() async {
    if (_isSpaceStatsWorkAborted) return;
    if (_dataStore.config.persistenceMode == PersistenceMode.memory) {
      return;
    }

    await ensureSpaceStatsHydrated();
    if (_isSpaceStatsWorkAborted || !_spaceStatsHydrated) return;

    // One-shot: never full-reconciled. Covers upgrades where JSON/table meta
    // can supply table-data size but index occupancy was never aggregated.
    // Sticky via [_lastStatisticsTime] so true zero-index spaces do not loop.
    if (_lastStatisticsTime == null) {
      await recalculateAllStatistics();
      return;
    }

    final tableMetaManager = _dataStore.tableMetaManager;
    if (tableMetaManager == null) return;

    // O(1) `_system_table_meta` row count (includes a handful of system tables).
    // Exact user-only filtering is not worth an inventory walk for cadence.
    final tableCount = await getTableRecordCount(
      tableMetaManager.bootstrapTableMetaContext(),
    );
    if (_isSpaceStatsWorkAborted) return;
    final interval = spaceStatsReconcileInterval(tableCount);
    if (interval == null) return;

    final last = _lastStatisticsTime;
    if (last == null) return;
    if (DateTime.now().difference(last) < interval) return;

    await recalculateAllStatistics();
  }

  void _foldSpaceStatsDeltaIntoBaseline() {
    _baselineRecordCount = _effectiveRecordCount;
    _baselineTableDataSizeBytes = _effectiveTableDataSizeBytes;
    _baselineIndexDataSizeBytes = _effectiveIndexDataSizeBytes;
    _deltaRecordCount = 0;
    _deltaTableDataSizeBytes = 0;
    _deltaIndexDataSizeBytes = 0;
  }

  /// Space aggregate stats cover user tables only — never system/internal KV.
  /// Prefer [TableSchema.isSystemTable] (O(1)); name-set lookup is unnecessary
  /// on the per-record hot path when contexts carry a correct schema flag.
  bool _contributesToSpaceStats(TableContext table) =>
      !table.schema.isSystemTable;

  void _markSpaceStatsDirty(TableContext table) {
    if (!_contributesToSpaceStats(table)) return;
    _needSaveStats = true;
  }

  /// O(1) incremental adjust for persisted table-data size deltas.
  void applyTableDataSizeDelta(TableContext table, int sizeDelta) {
    if (sizeDelta == 0 || !_contributesToSpaceStats(table)) return;
    _deltaTableDataSizeBytes += sizeDelta;
    _needSaveStats = true;
  }

  /// O(1) incremental adjust for persisted index-data size deltas.
  void applyIndexDataSizeDelta(TableContext table, int sizeDelta) {
    if (sizeDelta == 0 || !_contributesToSpaceStats(table)) return;
    _deltaIndexDataSizeBytes += sizeDelta;
    _needSaveStats = true;
  }

  /// Sum index file sizes for one table (B+Tree + vector/NGH).
  Future<int> sumTableIndexDataSizeBytes(TableContext table) async {
    final indexManager = _dataStore.indexManager;
    final schemaMgr = _dataStore.tableMetaManager;
    if (indexManager == null || schemaMgr == null) return 0;

    var total = 0;
    final yieldController = YieldController(
        'TableDataManager.sumTableIndexDataSizeBytes',
        checkInterval: 2);
    for (final index in schemaMgr.getBtreeIndexesFor(table.schema)) {
      final meta =
          await indexManager.getIndexMeta(table.tableUid, index.indexUid);
      if (meta != null) total += meta.totalSizeBytes;
      final y = yieldController.maybeYield();
      if (y != null) await y;
    }
    final vectorMgr = _dataStore.vectorIndexManager;
    if (vectorMgr != null) {
      for (final index in schemaMgr.getVectorIndexesFor(table.schema)) {
        final ngh = await vectorMgr.getNghIndexMeta(table, index.indexUid);
        if (ngh != null) total += ngh.totalSizeBytes;
        final y = yieldController.maybeYield();
        if (y != null) await y;
      }
    }
    return total;
  }

  /// Full meta reconcile (expensive). Replaces baseline, clears deltas, persists.
  Future<void> recalculateAllStatistics() {
    final existing = _recalculateAllStatisticsFuture;
    if (existing != null) return existing;
    final future = _recalculateAllStatisticsBody();
    _recalculateAllStatisticsFuture = future;
    return future.whenComplete(() {
      if (identical(_recalculateAllStatisticsFuture, future)) {
        _recalculateAllStatisticsFuture = null;
      }
    });
  }

  Future<void> _recalculateAllStatisticsBody() async {
    try {
      if (_isSpaceStatsWorkAborted) return;

      // Get all table data metadata (only user tables, excluding system tables)
      final tableMetaManager = _dataStore.tableMetaManager;
      if (tableMetaManager == null) return;

      final tableNames =
          await tableMetaManager.listAllTables(onlyUserTables: true);
      if (_isSpaceStatsWorkAborted) return;

      int totalRecordCount = 0;
      int totalTableDataSize = 0;
      int totalIndexDataSize = 0;

      final statsLease = await _dataStore.workloadScheduler.tryAcquire(
        WorkloadType.maintenance,
        requestedTokens: _dataStore.workloadScheduler
            .capacityTokens(WorkloadType.maintenance),
        minTokens: 1,
        label: 'TableDataManager.recalculateAllStatistics',
      );
      if (_isSpaceStatsWorkAborted) {
        statsLease?.release();
        return;
      }
      final int statsConc = (statsLease?.asConcurrency(0.3) ?? 1);
      final aggList = await ParallelProcessor.execute<
          ({int records, int tableBytes, int indexBytes})?>(
        tableNames.map((name) {
          return () async {
            if (_isSpaceStatsWorkAborted) return null;
            final uid = await tableMetaManager.getUidByName(TableName(name));
            if (_isSpaceStatsWorkAborted || uid == null) return null;
            final ctx = await tableMetaManager.getTableContext(uid);
            if (ctx == null) return null;
            final meta = await getTableDataMeta(ctx.tableUid);
            final indexBytes = await sumTableIndexDataSizeBytes(ctx);
            return (
              records: meta?.totalRecordCount ?? 0,
              tableBytes: meta?.totalSizeBytes ?? 0,
              indexBytes: indexBytes,
            );
          };
        }).toList(),
        concurrency: statsConc,
        label: 'TableDataManager._calculateTableStatistics',
      );
      statsLease?.release();

      final yieldController =
          YieldController('TableDataManager.recalculateAllStatistics');
      for (final agg in aggList) {
        final y2 = yieldController.maybeYield();
        if (y2 != null) await y2;
        if (agg != null) {
          totalRecordCount += agg.records;
          totalTableDataSize += agg.tableBytes;
          totalIndexDataSize += agg.indexBytes;
        }
      }

      if (_isSpaceStatsWorkAborted) return;

      _baselineRecordCount = totalRecordCount;
      _baselineTableDataSizeBytes = totalTableDataSize;
      _baselineIndexDataSizeBytes = totalIndexDataSize;
      _deltaRecordCount = 0;
      _deltaTableDataSizeBytes = 0;
      _deltaIndexDataSizeBytes = 0;
      _spaceStatsHydrated = true;
      // Stamp only on full reconcile (index baseline included, may be 0).
      _lastStatisticsTime = DateTime.now();

      await _persistSpaceStatsToKv();

      Logger.debug(
          'Table statistics calculation completed: record count=$totalRecordCount, table data=${totalTableDataSize / 1024 / 1024}MB, index data=${totalIndexDataSize / 1024 / 1024}MB');
    } on DbClosedException {
      // close / switchSpace race — best-effort, no log.
    } catch (e) {
      if (_isSpaceStatsWorkAborted || e is DbClosedException) return;
      Logger.error('Failed to calculate table statistics', rawError: e);
    }
  }

  Future<void> _persistSpaceStatsToKv() async {
    if (!_canPersistSpaceStatsKv) {
      return;
    }
    if (_dataStore.config.persistenceMode == PersistenceMode.memory) {
      _needSaveStats = false;
      return;
    }
    if (_persistingSpaceStats) return;
    _persistingSpaceStats = true;
    try {
      await ensureSpaceStatsHydrated();
      if (!_canPersistSpaceStatsKv) return;
      final snapshot = _spaceStatsSnapshot();
      await TransactionContext.runAsSystemOperation(() async {
        await _dataStore.internalKv.set(
          SpaceStats.kvKey,
          SpaceStatsCodec.encode(snapshot),
          isGlobal: false,
        );
      });
      _foldSpaceStatsDeltaIntoBaseline();
      _needSaveStats = false;
    } on DbClosedException {
      // Shutdown race — stats are best-effort.
    } catch (e) {
      if (_isSpaceStatsWorkAborted || e is DbClosedException) return;
      Logger.error('Failed to save space stats', rawError: e);
    } finally {
      _persistingSpaceStats = false;
    }
  }

  /// Get current max ID in memory for a table
  dynamic getMaxIdInMemory(TableContext table) {
    return _maxIds[table.tableUid];
  }

  /// Update max ID value (only in memory)
  /// [updateFileMeta] if true, also updates FileMeta.maxAutoIncrementId to keep cache consistent
  Future<void> updateMaxIdInMemory(TableContext table, dynamic id,
      {bool updateFileMeta = false}) async {
    try {
      // Ensure id is in string format
      String idStr = id.toString();

      // Check if it's a numeric string
      if (!_isNumericString(idStr)) {
        return;
      }

      final currentMaxId = _maxIds[table.tableUid];
      bool shouldUpdate = false;

      if (currentMaxId == null) {
        // First set max ID
        _maxIds[table.tableUid] = idStr;
        _maxIdsDirty[table.tableUid] = true;
        shouldUpdate = true;
      } else {
        // Ensure currentMaxId is also a string
        String currentMaxIdStr = currentMaxId.toString();

        // Compare current value with max value
        final matcher = ValueMatcher.getMatcher(MatcherType.pkNumericString);
        if (matcher(idStr, currentMaxIdStr) > 0) {
          _maxIds[table.tableUid] = idStr;
          _maxIdsDirty[table.tableUid] = true;
          shouldUpdate = true;
        }
      }

      // If updateFileMeta is true and we updated the maxId, also update FileMeta
      // This ensures cache consistency and prevents unnecessary recalculations
      if (updateFileMeta && shouldUpdate) {
        try {
          await mutateTableDataMeta(table, (fileMeta) {
            if (fileMeta == null) return null;
            return fileMeta.copyWith(maxAutoIncrementId: idStr);
          });
        } catch (e) {
          Logger.error('Failed to update FileMeta maxAutoIncrementId',
              rawError: e);
        }
      }
    } catch (e) {
      Logger.error('Failed to update max ID, table=${table.tableName}, id=$id',
          rawError: e);
    }
  }

  /// Get next auto-increment ID
  Future<String> getNextId(TableContext table) async {
    try {
      final schema = table.schema;
      // Check if initialization of auto-increment ID is needed for the table (lazy loading)
      if (schema.primaryKeyConfig.type == PrimaryKeyType.sequential &&
          !_maxIds.containsKey(table.tableUid)) {
        // Load auto-increment ID value only when first used (lock is already held)
        await _updateMaxIdFromTableInternal(table);
      }

      // Get ID generator
      final generator = await _getIdGenerator(table);

      // Use ID pool optimization - batch generation method is implemented internally
      final ids = await generator.getId(1);
      if (ids.isEmpty) {
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message: 'Failed to generate ID, returned empty list',
          ),
        ]);
      }

      // If it's a sequential increment type, update max ID value
      if (schema.primaryKeyConfig.type == PrimaryKeyType.sequential) {
        await updateMaxIdInMemory(table, ids.first);
      }

      // Save ID range (if needed)
      await _saveIdRange(table);

      return ids.first;
    } catch (e) {
      Logger.error('Failed to get next ID', rawError: e);
      return '';
    }
  }

  /// Get batch of IDs (used for optimizing bulk insert scenarios)
  Future<List<String>> getBatchIds(TableContext table, int count) async {
    try {
      if (count <= 0) return [];

      final schema = table.schema;
      // Check if initialization of auto-increment ID is needed for the table (lazy loading)
      if (schema.primaryKeyConfig.type == PrimaryKeyType.sequential &&
          !_maxIds.containsKey(table.tableUid)) {
        // Load auto-increment ID value only when first used (lock is already held)
        await _updateMaxIdFromTableInternal(table);
      }

      // Get ID generator
      final generator = await _getIdGenerator(table);

      // Get IDs directly in batch
      final ids = await generator.getId(count);

      // If it's a sequential increment type, update max ID value
      if (schema.primaryKeyConfig.type == PrimaryKeyType.sequential &&
          ids.isNotEmpty) {
        await updateMaxIdInMemory(table, ids.last);
      }

      // Save ID range (if needed)
      await _saveIdRange(table);

      return ids;
    } catch (e) {
      Logger.error('Failed to get batch of IDs', rawError: e);
      return [];
    }
  }

  /// Remove scheduled task when instance is closed
  Future<void> dispose({bool persistChanges = true}) async {
    CrontabManager.removeCallback(
        ExecuteInterval.seconds3, TimeBasedIdGenerator.periodicPoolCheck);
    CrontabManager.removeCallback(
        ExecuteInterval.seconds30, _onSpaceStatsPersistTick);
    _unregisterSpaceStatsReconcileCron();

    try {
      if (persistChanges) {
        // Persist runtime metadata (max IDs) one last time.
        // SpaceStats intentionally skipped — close/switchSpace must not block
        // on InternalKv; periodic tick / recalculate covers durability.
        await persistRuntimeMetaIfNeeded(force: true);

        // Save ID range information for all tables
        final idGenKeys = List<String>.from(_idGenerators.keys);
        final yieldController = YieldController('TableDataManager.dispose');
        for (final tableUid in idGenKeys) {
          final y3 = yieldController.maybeYield();
          if (y3 != null) await y3;
          final ctx = await _tableContextFromUid(TableUid(tableUid));
          if (ctx != null) await _saveIdRange(ctx);
        }
      }

      _tableRecordCache.clear();
      _tableDataMetaCache.clear();
      _tableRecordCounts.clear();
      _recordCountLoadingFutures.clear();
      _metaLoadingFutures.clear();
      _txnDeferredOps.clear();
      _txnResourceEstimates.clear();
      _maxIds.clear();
      _maxIdsDirty.clear();
      _idGenerators.clear();
      _idGeneratorPending.clear();
      _idRanges.clear();
      _checkedOrderedRange.clear();
      _fileSizes.clear();
      _lastModifiedTimes.clear();
      _tablePartitionSizes.clear();
      _tableFlushingFlags.clear();
      _pkComparators.clear();
      _baselineRecordCount = 0;
      _baselineTableDataSizeBytes = 0;
      _baselineIndexDataSizeBytes = 0;
      _deltaRecordCount = 0;
      _deltaTableDataSizeBytes = 0;
      _deltaIndexDataSizeBytes = 0;
      _lastStatisticsTime = null;
      _spaceStatsHydrated = false;
      _spaceStatsHydrateFuture = null;
      _recalculateAllStatisticsFuture = null;
      _needSaveStats = false;
    } catch (e) {
      Logger.error('Failed to dispose TableDataManager', rawError: e);
    } finally {}
  }

  /// Flush max IDs to disk
  Future<void> flushMaxIds() async {
    try {
      if (_maxIdsDirty.isEmpty) return;
      final yieldController = YieldController('TableDataManager.flushMaxIds');
      for (final entry in _maxIdsDirty.entries.toList()) {
        final y4 = yieldController.maybeYield();
        if (y4 != null) await y4;
        if (!entry.value) continue; // Skip unchanged

        final tableUid = entry.key;
        final table = await _tableContextFromUid(TableUid(tableUid));
        if (table == null) continue;
        if (isTableBeingCleared(table)) continue;

        final maxId = _maxIds[tableUid];
        if (maxId == null) continue;

        // Save to FileMeta
        await mutateTableDataMeta(table, (fileMeta) {
          if (fileMeta == null) return null;
          return fileMeta.copyWith(maxAutoIncrementId: maxId);
        });

        _maxIdsDirty[tableUid] = false;
      }
    } catch (e) {
      Logger.error('Failed to flush max IDs', rawError: e);
    }
  }

  /// Get partition size limit for a table
  int _getPartitionSizeLimit(TableContext table) {
    // If table has specific partition size configuration, use it
    if (_tablePartitionSizes.containsKey(table.tableUid)) {
      final configuredSize = _tablePartitionSizes[table.tableUid]!;

      // Ensure configured partition size doesn't exceed system maximum
      final systemMax = _dataStore.config.maxPartitionFileSize;
      if (configuredSize > systemMax) {
        Logger.warn(
          'Table ${table.tableName} configured partition size ${configuredSize ~/ 1024}KB exceeds system limit ${systemMax ~/ 1024}KB, will use system limit',
        );
        return systemMax;
      }

      // Ensure partition size has a reasonable minimum value
      const minSize = 10 * 1024; // 10KB
      if (configuredSize < minSize) {
        Logger.warn(
          'Table ${table.tableName} configured partition size ${configuredSize ~/ 1024}KB is too small, will use minimum value ${minSize ~/ 1024}KB',
        );
        return minSize;
      }

      return configuredSize;
    }

    // Otherwise return default value from DataStoreConfig
    return _dataStore.config.maxPartitionFileSize;
  }

  /// Set partition size limit for a table
  void setTablePartitionSize(TableContext table, int sizeInBytes) {
    if (sizeInBytes <= 0) {
      Logger.warn(
        'Attempted to set partition size for table ${table.tableName} to $sizeInBytes, invalid value, will use default',
      );
      _tablePartitionSizes
          .remove(table.tableUid); // Remove invalid config, use default
      return;
    }

    _tablePartitionSizes[table.tableUid] = sizeInBytes;

    // Log configuration change
    Logger.debug(
      'Set partition size for table ${table.tableName} to ${sizeInBytes ~/ 1024}KB',
    );
  }

  /// Get partition size limit for a table (public method)
  int getTablePartitionSize(TableContext table) {
    return _getPartitionSizeLimit(table);
  }

  /// Add record to buffer
  Future<void> addToBuffer(
    TableContext table,
    Map<String, dynamic> data,
    BufferOperationType operationType, {
    List<UniqueKeyRef>? uniqueKeyRefs,
    Map<String, dynamic>? oldValues,
    String? transactionId,
    required String schemaVersion,
  }) async {
    final schema = table.schema;
    final primaryKey = schema.primaryKey;
    final recordId = data[primaryKey]?.toString();
    if (recordId == null) {
      Logger.error(
        'Record in table ${table.tableName} does not have a primary key value, cannot add to buffer',
      );
      return;
    }

    // Transaction-aware interception (must run BEFORE touching existing buffer state)
    final String? currentTxId =
        transactionId ?? TransactionContext.getCurrentTransactionId();
    if (currentTxId != null && !TransactionContext.isApplyingCommit()) {
      // Transaction-aware deferred operations
      final byTable = _txnDeferredOps.putIfAbsent(
          currentTxId, () => <String, Map<String, TxnDeferredOp>>{});
      final map =
          byTable.putIfAbsent(table.tableUid, () => <String, TxnDeferredOp>{});

      // Handle insert-then-update in same transaction: merge operations correctly.
      final existingOp = map[recordId];
      Map<String, dynamic>? mergedOldValues = oldValues;
      BufferOperationType finalOpType = operationType;
      // Copy only the map we will retain. Merge paths copy existingOp.data and
      // overlay [data]; non-merge paths take ownership via Map.from(data).
      late final Map<String, dynamic> finalData;

      if (existingOp != null) {
        if (existingOp.type == BufferOperationType.delete &&
            operationType == BufferOperationType.update) {
          throw DbException([
            ConstraintStatus(
              type: ResultType.bizRecordNotFound,
              tableName: table.tableName,
              fields: [primaryKey],
              conflictingKeys: [recordId],
              message:
                  'Cannot update record $recordId in table ${table.tableName} because it has already been deleted in the current transaction',
            ),
          ]);
        }
        if (existingOp.type == BufferOperationType.insert &&
            operationType == BufferOperationType.update) {
          // Insert then update: merge into a single insert with final data.
          // Since the record hasn't been committed yet, we should treat it as an insert
          // with the final updated data. This avoids index deletion complexity.
          finalOpType = BufferOperationType.insert;
          mergedOldValues = null; // Insert doesn't need oldValues
          // Merge: start with insert data, then overlay update data (update may have partial fields)
          finalData = Map<String, dynamic>.from(existingOp.data);
          finalData.addAll(data); // Update data overlays insert data
        } else if (existingOp.type == BufferOperationType.update &&
            operationType == BufferOperationType.update) {
          // Update then update: preserve the original oldValues from first update.
          mergedOldValues = existingOp.oldValues ?? oldValues;
          finalData = Map<String, dynamic>.from(existingOp.data);
          finalData.addAll(data); // Update data overlays first update data
        } else if (existingOp.type == BufferOperationType.delete &&
            operationType == BufferOperationType.insert) {
          finalOpType = BufferOperationType.insert;
          finalData = Map<String, dynamic>.from(existingOp.data);
          finalData.addAll(data); // Insert data overlays deleted record
        } else {
          // Other combinations: take ownership of the latest operation data.
          finalData = Map<String, dynamic>.from(data);
        }
      } else {
        finalData = Map<String, dynamic>.from(data);
      }

      _trackTransactionBufferBatch(
        currentTxId,
        [finalData],
        mergedOldValues != null ? {recordId: mergedOldValues} : null,
        primaryKey,
      );

      // We already checked recordId is not null above
      map[recordId] = TxnDeferredOp(
        finalOpType,
        finalData,
        uniqueKeyRefs: uniqueKeyRefs,
        oldValues: mergedOldValues,
      );

      // Register unique keys with WriteBufferManager for conflict detection
      if (uniqueKeyRefs != null && uniqueKeyRefs.isNotEmpty) {
        _dataStore.writeBufferManager.addTransactionUniqueKeys(
          transactionId: currentTxId,
          table: table,
          recordId: recordId,
          uniqueKeys: uniqueKeyRefs,
        );
      }
      return;
    }

    if (operationType == BufferOperationType.update) {
      final priorBuffered =
          _dataStore.writeBufferManager.getBufferedRecord(table, recordId);
      if (priorBuffered != null &&
          priorBuffered.operation == BufferOperationType.delete) {
        throw DbException([
          ConstraintStatus(
            type: ResultType.bizRecordNotFound,
            tableName: table.tableName,
            fields: [primaryKey],
            conflictingKeys: [recordId],
            message:
                'Cannot update record $recordId in table ${table.tableName} because it has already been deleted',
          ),
        ]);
      }
    }

    // -------------------- Memory mode: TreeCache-only (no WAL, no write queue, no IO) --------------------
    if (_dataStore.config.persistenceMode == PersistenceMode.memory) {
      final BufferOperationType finalOperation = operationType;

      if (finalOperation == BufferOperationType.delete) {
        removeTableRecord(table, recordId);
        // Best-effort stats.
        final cur = _tableRecordCounts[table.tableUid];
        if (cur != null && cur > 0) {
          _tableRecordCounts[table.tableUid] = cur - 1;
        }
      } else {
        // Insert/Update both materialize the full record in the table record cache.
        // Use force=true so memory mode treats cache as the primary store.
        cacheTableRecord(table, recordId, data, schema, force: true);
        if (finalOperation == BufferOperationType.insert) {
          _tableRecordCounts[table.tableUid] =
              (_tableRecordCounts[table.tableUid] ?? 0) + 1;
        }
      }

      // Update index cache
      if (_dataStore.indexManager != null) {
        Map<String, dynamic>? indexOldData;
        Map<String, dynamic>? indexNewData;

        if (finalOperation == BufferOperationType.insert) {
          indexOldData = null;
          indexNewData = data;
        } else if (finalOperation == BufferOperationType.update) {
          indexOldData = oldValues;
          indexNewData = data;
        } else if (finalOperation == BufferOperationType.delete) {
          indexOldData = data;
          indexNewData = null;
        }

        if (indexOldData != null || indexNewData != null) {
          // Fire and forget, don't block main flow
          await _dataStore.indexManager!.updateIndexDataCache(
            table,
            recordId,
            indexOldData,
            indexNewData,
            force: true,
          );
        }
      }
      return;
    }

    // WAL + write buffer path
    final BufferOperationType finalOperation = operationType;

    // Create BufferEntry
    final Map<String, dynamic> bufferedData = data;
    final updateOldValues =
        finalOperation == BufferOperationType.update ? oldValues : null;
    // Append WAL (if enabled) and get pointer
    final walPointer = await _dataStore.walManager.append({
      'op': finalOperation.index,
      'table': table.tableUid,
      'data': bufferedData,
      'ts': DateTime.now().toIso8601String(),
      if (currentTxId != null) 'txId': currentTxId,
      if (updateOldValues != null) 'oldValues': updateOldValues,
    });

    // Create BufferEntry with WAL pointer
    final entry = BufferEntry(
        data: bufferedData,
        operation: finalOperation,
        timestamp: DateTime.now(),
        transactionId: currentTxId,
        walPointer: walPointer,
        oldValues:
            finalOperation == BufferOperationType.update ? oldValues : null,
        schemaVersion: schemaVersion);

    // Enqueue into write buffer/queue (in-memory)
    await _dataStore.writeBufferManager.addRecord(
      table: table,
      recordId: recordId,
      entry: entry,
      uniqueKeys: uniqueKeyRefs ?? const <UniqueKeyRef>[],
    );

    // Update full index cache (Real-time population)
    // Skip index cache update during batch operations for better performance
    if (_dataStore.indexManager != null) {
      Map<String, dynamic>? indexOldData;
      Map<String, dynamic>? indexNewData;

      if (finalOperation == BufferOperationType.update) {
        indexOldData = oldValues;
        indexNewData = bufferedData;
      } else if (finalOperation == BufferOperationType.delete) {
        indexOldData = bufferedData;
      }

      if (indexOldData != null || indexNewData != null) {
        // Fire and forget, don't block main flow
        await _dataStore.indexManager!.updateIndexDataCache(
          table,
          recordId,
          indexOldData,
          indexNewData,
        );
      }
    }

    // Sync to TableRecordCache
    if (finalOperation == BufferOperationType.delete) {
      removeTableRecord(table, recordId);
    } else if (finalOperation == BufferOperationType.update) {
      cacheTableRecord(table, recordId, bufferedData, schema);
    }

    _markSpaceStatsDirty(table);
  }

  /// Unified internal batch processor for high-throughput writes.
  /// Handles Transactions, Memory-Mode, and Persistent WAL+Buffer paths.
  Future<({List<String> successRecordIds, List<String> failedRecordIds})>
      addBatchToBuffer({
    required TableContext table,
    required List<Map<String, dynamic>> records,
    required BufferOperationType operation,
    required TableSchema schema,
    required List<List<UniqueKeyRef>> uniqueKeyRefsList,
    Map<String, Map<String, dynamic>>? oldRecordsMap,
    String? transactionId,
    DateTime? timestamp,
    required String schemaVersion,
  }) async {
    if (records.isEmpty) {
      return (
        successRecordIds: const <String>[],
        failedRecordIds: const <String>[]
      );
    }

    final pkName = schema.primaryKey;
    final String? currentTxId =
        transactionId ?? TransactionContext.getCurrentTransactionId();
    final bool applyingCommit = TransactionContext.isApplyingCommit();
    final DateTime ts = timestamp ?? DateTime.now();
    final String tsIso = ts.toIso8601String();
    final successIds = <String>[];
    final failedIds = <String>[];

    // 1. Transaction Path: Defer operations until commit
    if (currentTxId != null && !applyingCommit) {
      final byTable = _txnDeferredOps.putIfAbsent(
          currentTxId, () => <String, Map<String, TxnDeferredOp>>{});
      final map =
          byTable.putIfAbsent(table.tableUid, () => <String, TxnDeferredOp>{});
      _trackTransactionBufferBatch(
        currentTxId,
        records,
        oldRecordsMap,
        pkName,
      );

      await EngineCpuChunk.forEachRange(
        length: records.length,
        kind: CpuChunkKind.medium,
        process: (start, end) {
          for (int i = start; i < end; i++) {
            final r = records[i];
            final recordId = r[pkName]?.toString();
            if (recordId == null || recordId.isEmpty) {
              // Cannot report failed key reliably here.
              continue;
            }

            final uniqueRefs = uniqueKeyRefsList[i];
            final oldR = oldRecordsMap != null ? oldRecordsMap[recordId] : null;

            try {
              map[recordId] = TxnDeferredOp(
                operation,
                Map<String, dynamic>.from(r),
                uniqueKeyRefs: uniqueRefs,
                oldValues: oldR,
              );

              // Register unique keys with WriteBufferManager for cross-txn conflict detection.
              if (uniqueRefs.isNotEmpty) {
                _dataStore.writeBufferManager.addTransactionUniqueKeys(
                  transactionId: currentTxId,
                  table: table,
                  recordId: recordId,
                  uniqueKeys: uniqueRefs,
                );
              }
              successIds.add(recordId);
            } catch (e) {
              Logger.warn(
                  'Txn deferred batch op failed: ${table.tableName} pk=$recordId',
                  rawError: e);
              failedIds.add(recordId);
            }
          }
        },
      );
      return (successRecordIds: successIds, failedRecordIds: failedIds);
    }

    // 2. Memory Mode Path: Direct cache writes (no WAL/IO)
    if (_dataStore.config.persistenceMode == PersistenceMode.memory) {
      _registerTableComparator(table, schema);

      await EngineCpuChunk.forEachRangeAsync(
        length: records.length,
        kind: CpuChunkKind.medium,
        process: (start, end) async {
          for (int i = start; i < end; i++) {
            final r = records[i];
            final recordId = r[pkName]?.toString();
            if (recordId == null || recordId.isEmpty) {
              continue;
            }
            try {
              final oldR =
                  oldRecordsMap != null ? oldRecordsMap[recordId] : null;

              if (operation == BufferOperationType.delete) {
                // Memory mode: Removal from primary cache
                removeTableRecord(table, recordId);

                // Per-table count cache applies to all tables (incl. system KV).
                final current = _tableRecordCounts[table.tableUid] ?? 0;
                if (current > 0) {
                  _tableRecordCounts[table.tableUid] = current - 1;
                }
                if (_contributesToSpaceStats(table) && current > 0) {
                  _deltaRecordCount--;
                  _needSaveStats = true;
                }

                // Memory mode: Index erasure (newData is null)
                if (_dataStore.indexManager != null) {
                  await _dataStore.indexManager!.updateIndexDataCache(
                      table, recordId, r, null,
                      overrideSchema: schema, force: true);
                }
              } else {
                if (operation == BufferOperationType.insert) {
                  _tableRecordCounts[table.tableUid] =
                      (_tableRecordCounts[table.tableUid] ?? 0) + 1;
                  if (_contributesToSpaceStats(table)) {
                    _deltaRecordCount++;
                    _needSaveStats = true;
                  }
                }
                // Memory mode: Update primary cache
                cacheTableRecord(table, recordId, r, schema, force: true);

                // Memory mode: Index update
                if (_dataStore.indexManager != null) {
                  await _dataStore.indexManager!.updateIndexDataCache(
                      table, recordId, oldR, r,
                      overrideSchema: schema, force: true);
                }
              }
              successIds.add(recordId);
            } catch (e) {
              Logger.warn(
                  'Memory batch op failed: ${table.tableName} pk=$recordId',
                  rawError: e);
              failedIds.add(recordId);
            }
          }
        },
      );

      return (successRecordIds: successIds, failedRecordIds: failedIds);
    }

    // 3. Persistent Path: WAL + Write Buffer
    final walEntries = <Map<String, dynamic>>[];
    final validBatchRecords = <Map<String, dynamic>>[];
    final validBatchRecordIds = <String>[];
    final validBatchUniqueKeys = <List<UniqueKeyRef>>[];
    final validBatchOldValues = <Map<String, dynamic>?>[];

    await EngineCpuChunk.forEachRange(
      length: records.length,
      kind: CpuChunkKind.medium,
      process: (start, end) {
        for (int i = start; i < end; i++) {
          final r = records[i];
          final recordId = r[pkName]?.toString();
          if (recordId == null || recordId.isEmpty) {
            continue;
          }

          final oldR = oldRecordsMap != null ? oldRecordsMap[recordId] : null;
          final walOldValues =
              operation == BufferOperationType.update ? oldR : null;

          // Build WAL envelope once; appendBatch mutates p/seq in place.
          final walEntry = <String, dynamic>{
            'op': operation.index,
            'table': table.tableUid,
            'ts': tsIso,
            'data': r,
          };
          if (currentTxId != null) {
            walEntry['txId'] = currentTxId;
          }
          if (walOldValues != null) {
            walEntry['oldValues'] = walOldValues;
          }
          walEntries.add(walEntry);

          validBatchRecords.add(r);
          validBatchRecordIds.add(recordId);
          validBatchUniqueKeys.add(uniqueKeyRefsList[i]);
          validBatchOldValues.add(walOldValues);
        }
      },
    );

    if (walEntries.isEmpty) {
      return (successRecordIds: successIds, failedRecordIds: failedIds);
    }

    late final List<WalPointer> pointers;
    try {
      pointers = await _dataStore.walManager.appendBatch(walEntries);
    } catch (e) {
      Logger.error('Persistent batch WAL append failed: ${table.tableName}',
          rawError: e);
      return (
        successRecordIds: const <String>[],
        failedRecordIds: records
            .map((r) => r[pkName]?.toString() ?? '')
            .where((id) => id.isNotEmpty)
            .toList()
      );
    }

    final recordIds = <String>[];
    final entries = <BufferEntry>[];
    final finalUniqueKeysList = <List<UniqueKeyRef>>[];

    await EngineCpuChunk.forEachRangeAsync(
      length: validBatchRecordIds.length,
      kind: CpuChunkKind.medium,
      process: (start, end) async {
        for (int i = start; i < end; i++) {
          final recordId = validBatchRecordIds[i];
          final r = validBatchRecords[i];
          final oldR = validBatchOldValues[i];

          entries.add(BufferEntry(
            data: r,
            operation: operation,
            timestamp: ts,
            transactionId: currentTxId,
            walPointer: pointers[i],
            oldValues: oldR,
            schemaVersion: schemaVersion,
          ));
          recordIds.add(recordId);
          if (operation != BufferOperationType.delete) {
            finalUniqueKeysList.add(validBatchUniqueKeys[i]);
          }

          if (operation == BufferOperationType.update) {
            cacheTableRecord(table, recordId, r, schema);
            await _dataStore.indexManager?.updateIndexDataCache(
              table,
              recordId,
              oldR,
              r,
              overrideSchema: schema,
            );
          } else if (operation == BufferOperationType.delete) {
            removeTableRecord(table, recordId);
            await _dataStore.indexManager?.updateIndexDataCache(
              table,
              recordId,
              r,
              null,
              overrideSchema: schema,
            );
          }
        }
      },
    );

    if (operation == BufferOperationType.insert) {
      await _dataStore.writeBufferManager.addInsertBatch(
          table: table,
          recordIds: recordIds,
          entries: entries,
          uniqueKeysList: finalUniqueKeysList);
    } else if (operation == BufferOperationType.update) {
      await _dataStore.writeBufferManager.addUpdateBatch(
          table: table,
          recordIds: recordIds,
          entries: entries,
          uniqueKeysList: finalUniqueKeysList);
    } else if (operation == BufferOperationType.delete) {
      await _dataStore.writeBufferManager
          .addDeleteBatch(table: table, recordIds: recordIds, entries: entries);
    }
    successIds.addAll(recordIds);
    _markSpaceStatsDirty(table);

    return (successRecordIds: successIds, failedRecordIds: failedIds);
  }

  /// Update the per-table record count cache based on the operation.
  ///
  /// Always maintains [_tableRecordCounts] (used by [getTableRecordCount] /
  /// `db.kv.count()`), including system tables. SpaceStats deltas only apply
  /// to user tables via [_contributesToSpaceStats].
  Future<void> updateTableRecordCount(
      TableContext table, BufferOperationType op) async {
    // Ensure loaded first so we start from a valid base
    await _ensureRecordCountLoaded(table);

    if (op == BufferOperationType.insert) {
      _tableRecordCounts[table.tableUid] =
          (_tableRecordCounts[table.tableUid] ?? 0) + 1;
      if (_contributesToSpaceStats(table)) {
        _deltaRecordCount++;
        _needSaveStats = true;
      }
    } else if (op == BufferOperationType.delete) {
      final current = _tableRecordCounts[table.tableUid] ?? 0;
      if (current > 0) {
        _tableRecordCounts[table.tableUid] = current - 1;
        if (_contributesToSpaceStats(table)) {
          _deltaRecordCount--;
          _needSaveStats = true;
        }
      }
    }
  }

  /// Batch update record count cache with a single await.
  ///
  /// This is optimized for large batch operations (e.g. batchInsert) to avoid
  /// 10k+ awaited calls to [updateTableRecordCount].
  Future<void> updateTableRecordCountDelta(
    TableContext table, {
    int insertDelta = 0,
    int deleteDelta = 0,
  }) async {
    final int delta = insertDelta - deleteDelta;
    if (delta == 0) return;

    await _ensureRecordCountLoaded(table);

    final current = _tableRecordCounts[table.tableUid] ?? 0;
    _tableRecordCounts[table.tableUid] = max(0, current + delta);
    if (_contributesToSpaceStats(table)) {
      _deltaRecordCount += delta;
      _needSaveStats = true;
    }
  }

  Future<List<Map<String, dynamic>>> _prepareDeleteBufferRecords({
    required TableContext table,
    required List<Map<String, dynamic>> records,
    required String primaryKey,
    required List<String> requiredFields,
  }) async {
    if (records.isEmpty) return const <Map<String, dynamic>>[];

    final dispatchPlan = ComputeBatchPlanner.planTaskExecution(
      itemCount: records.length,
      estimateAverageItemBytes: () =>
          ComputeBatchPlanner.estimateAverageItemBytes(
        records,
        estimateRecordSizeBytes,
      ),
    );
    final useIsolate = dispatchPlan.useIsolate;
    final actualTaskCount = dispatchPlan.actualTaskCount;

    final tasks =
        <ComputeTask<DeleteBatchPrepareRequest, DeleteBatchPrepareResult>>[];
    for (final range
        in ComputeBatchPlanner.splitRange(records.length, actualTaskCount)) {
      tasks.add(
        ComputeTask(
          function: prepareDeleteBatchChunk,
          message: DeleteBatchPrepareRequest(
            tableName: table.tableName,
            primaryKeyField: primaryKey,
            requiredFields: requiredFields,
            records: records.sublist(range.start, range.end),
          ),
        ),
      );
    }

    final results =
        await ComputeManager.computeBatch(tasks, enableIsolate: useIsolate);

    final trimmedRecords = <Map<String, dynamic>>[];
    final mergeYield = YieldController(
      'TableDataManager._prepareDeleteBufferRecords',
    );
    for (final result in results) {
      for (final record in result.trimmedRecords) {
        final y7 = mergeYield.maybeYield();
        if (y7 != null) await y7;
        trimmedRecords.add(record);
      }
    }
    return trimmedRecords;
  }

  /// Add records to delete buffer - for batch deleting
  Future<void> addToDeleteBuffer(
      TableContext table, List<Map<String, dynamic>> records,
      {required String schemaVersion}) async {
    if (records.isEmpty) return;

    final schema = table.schema;

    final primaryKey = schema.primaryKey;
    // For deletes, keep WAL payload minimal: pk + index/unique fields
    final Set<String> needFields = () {
      final s = <String>{primaryKey};
      // Collect all fields used in any index (auto-generated unique/fk or explicit)
      final allIndexes =
          _dataStore.tableMetaManager?.getAllIndexesFor(schema) ??
              <IndexSchema>[];
      for (final idx in allIndexes) {
        s.addAll(idx.fields);
      }
      return s;
    }();

    final trimmedRecords = await _prepareDeleteBufferRecords(
      table: table,
      records: records,
      primaryKey: primaryKey,
      requiredFields: needFields.toList(growable: false),
    );

    if (trimmedRecords.isNotEmpty) {
      await addBatchToBuffer(
        table: table,
        records: trimmedRecords,
        operation: BufferOperationType.delete,
        schema: schema,
        uniqueKeyRefsList:
            List.filled(trimmedRecords.length, const <UniqueKeyRef>[]),
        schemaVersion: schemaVersion,
      );
    }

    // Record data change, need to update statistics
    _markSpaceStatsDirty(table);
  }

  /// Recover a record from WAL/Journal to buffer.
  ///
  /// This ensures:
  /// 1. Record is added to WriteBufferManager (queue + stats).
  /// 2. Record is added to hot cache (force=true) to ensure immediate consistency.
  /// 3. MaxID is updated in memory to restore auto-increment sequence.
  Future<void> recoverRecordToBuffer(
    TableContext table,
    Map<String, dynamic> data,
    BufferOperationType operationType, {
    required BufferEntry entry,
    List<UniqueKeyRef>? uniqueKeyRefs,
    Map<String, dynamic>? oldValues,
    bool updateStats = true,
  }) async {
    final schema = table.schema;

    final primaryKey = schema.primaryKey;
    final recordId = data[primaryKey]?.toString();
    if (recordId == null) return;

    // 1. Add to WriteBufferManager (reconstructs queue state)
    // We bypass the standard addToBuffer/batchInsert path to inject the *exact*
    // original WAL entry (preserving timestamp, walPointer, etc.)
    await _dataStore.writeBufferManager.addRecord(
      table: table,
      recordId: recordId,
      entry: entry, // Use the recovered entry directly
      uniqueKeys: uniqueKeyRefs ?? const <UniqueKeyRef>[],
      updateStats: updateStats,
    );
  }

  /// get total record count
  int getTotalRecordCount() {
    return _effectiveRecordCount;
  }

  /// get total table-data size (bytes)
  int getTotalTableDataSizeBytes() {
    return _effectiveTableDataSizeBytes;
  }

  /// get total index-data size (bytes)
  int getTotalIndexDataSizeBytes() {
    return _effectiveIndexDataSizeBytes;
  }

  /// get total size (table + index, bytes)
  int getTotalSizeBytes() {
    return _effectiveTableDataSizeBytes + _effectiveIndexDataSizeBytes;
  }

  /// mark stats data need to be updated
  void markStatsDirty() {
    _needSaveStats = true;
  }

  /// table deleted
  Future<void> tableDeleted(TableContext table) async {
    try {
      if (!_contributesToSpaceStats(table)) return;

      final meta = await getTableDataMeta(table.tableUid);
      if (meta != null) {
        _deltaRecordCount -= meta.totalRecordCount;
        _deltaTableDataSizeBytes -= meta.totalSizeBytes;
      }
      final indexBytes = await sumTableIndexDataSizeBytes(table);
      if (indexBytes != 0) {
        _deltaIndexDataSizeBytes -= indexBytes;
      }

      _tableRecordCounts.remove(table.tableUid);
      _needSaveStats = true;
    } catch (e) {
      Logger.error('Failed to update table deleted stats', rawError: e);
    }
  }

  /// Ensure the record count for [table] is loaded into cache.
  /// Uses loading lock pattern to prevent thundering herd when many
  /// concurrent inserts happen for the same table.
  Future<void> _ensureRecordCountLoaded(TableContext table) async {
    // Fast path: already cached
    if (_tableRecordCounts.containsKey(table.tableUid)) return;

    // Check if another call is already loading this table
    final existing = _recordCountLoadingFutures[table.tableUid];
    if (existing != null) {
      await existing;
      return;
    }

    // Start loading and register the future
    final loadFuture = _doLoadRecordCount(table);
    _recordCountLoadingFutures[table.tableUid] = loadFuture;
    try {
      await loadFuture;
    } finally {
      _recordCountLoadingFutures.remove(table.tableUid);
    }
  }

  /// Internal helper to actually load record count from metadata.
  Future<void> _doLoadRecordCount(TableContext table) async {
    final meta = await getTableDataMeta(table.tableUid);
    _tableRecordCounts[table.tableUid] = meta?.totalRecordCount ?? 0;
  }

  /// get table record count by table name
  Future<int> getTableRecordCount(TableContext table) async {
    // Ensure cache is populated
    await _ensureRecordCountLoaded(table);

    int count = _tableRecordCounts[table.tableUid] ?? 0;

    // Transaction overlay: include deferred inserts/deletes (read-your-writes) for current tx.
    // Skip during applyCommit to avoid double counting when promotion already enters WAL/buffer.
    final String? txId = TransactionContext.getCurrentTransactionId();
    if (txId != null && !TransactionContext.isApplyingCommit()) {
      final defOps = _txnDeferredOps[txId]?[table.tableUid];
      if (defOps != null && defOps.isNotEmpty) {
        try {
          final schema = table.schema;
          final pkName = schema.primaryKey;
          if (pkName.isNotEmpty) {
            // Track unique primary keys to avoid double counting the same record.
            final inserted = <String>{};
            final yieldController =
                YieldController('TableDataManager.getTableRecordCount');

            // defOps is Map<String, TxnDeferredOp>
            // We just need to tally inserts - deletes
            // Since Map already deduplicates by PK for the txn, we just iterate values.
            final deleted = <String>{};

            for (final op in defOps.values) {
              final y8 = yieldController.maybeYield();
              if (y8 != null) await y8;
              if (op.type == BufferOperationType.insert) {
                final k = op.data[pkName]?.toString();
                if (k != null && k.isNotEmpty) inserted.add(k);
              } else if (op.type == BufferOperationType.delete) {
                final k = op.data[pkName]?.toString();
                if (k != null) {
                  // If we inserted it in this txn, remove it (net zero change for this key)
                  // If not inserted in this txn, it's a delete of an existing record (net -1)
                  if (!inserted.remove(k)) {
                    deleted.add(k);
                  }
                }
              }
            }

            count += inserted.length - deleted.length;
          }
        } catch (_) {}
      }
    }

    // The final count is the stored count, plus pending inserts, minus pending deletes,
    // plus current transaction's deferred delta. Clamp to >= 0 to avoid negative results.
    return max(0, count);
  }

  String _tableDataMetaLockResource(TableUid tableUid) =>
      'table_data_meta:${tableUid.value}';

  /// Read-modify-write under exclusive lock.
  ///
  /// Use for any metadata mutation path. [getTableDataMeta] remains lock-free for
  Future<TableDataMeta?> mutateTableDataMeta(
    TableContext table,
    FutureOr<TableDataMeta?> Function(TableDataMeta? current) mutator, {
    bool flush = true,
    bool persistToDisk = true,
    BatchContext? batchContext,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    final lockResource = _tableDataMetaLockResource(table.tableUid);
    final operationId = GlobalIdGenerator.generate('mutate_table_meta_');
    final lockMgr = _dataStore.lockManager;
    if (lockMgr == null) {
      final current = await getTableDataMeta(table.tableUid);
      final next = await mutator(current);
      if (next == null) return null;
      await updateTableDataMeta(
        table,
        next,
        flush: flush,
        persistToDisk: persistToDisk,
        batchContext: batchContext,
        acquireLock: false,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
      );
      return next;
    }

    final acquired =
        await lockMgr.acquireExclusiveLock(lockResource, operationId);
    if (!acquired) return null;
    try {
      final current = await getTableDataMeta(table.tableUid);
      final next = await mutator(current);
      if (next == null) return null;
      await updateTableDataMeta(
        table,
        next,
        flush: flush,
        persistToDisk: persistToDisk,
        batchContext: batchContext,
        acquireLock: false,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
      );
      return next;
    } finally {
      lockMgr.releaseExclusiveLock(lockResource, operationId);
    }
  }

  /// Get table data meta (cache first, disk on miss).
  Future<TableDataMeta?> getTableDataMeta(TableUid tableUid) async {
    // Table data meta cache fast path
    final cached = _tableDataMetaCache.get(tableUid);
    if (cached != null) return cached;

    // Check if another call is already loading this meta
    final existingFuture = _metaLoadingFutures[tableUid];
    if (existingFuture != null) {
      return existingFuture;
    }

    // Load from disk with future tracking
    final loadFuture = _doLoadTableDataMeta(tableUid);
    _metaLoadingFutures[tableUid] = loadFuture;

    try {
      return await loadFuture;
    } finally {
      // Clean up future after completion
      if (_metaLoadingFutures[tableUid] == loadFuture) {
        _metaLoadingFutures.remove(tableUid);
      }
    }
  }

  /// Internal method to perform the actual file load
  Future<TableDataMeta?> _doLoadTableDataMeta(TableUid tableUid) async {
    try {
      final meta =
          await _dataStore.treeMetaPageService.readTableGlobalMeta(tableUid);
      if (meta == null) {
        return null;
      }
      _tableDataMetaCache.put(tableUid, meta);
      return meta;
    } catch (e) {
      Logger.error('Failed to get table data meta', rawError: e);
      rethrow;
    }
  }

  /// Update table data meta
  ///
  /// When [persistToDisk] is false, only the in-memory cache is updated. Batch
  /// flush paths embed global meta into partition-0 page 0 and use this to
  /// publish the latest values without a second disk write.
  ///
  /// Prefer [mutateTableDataMeta] for read-modify-write. This method is for
  /// publishing a fully computed snapshot (e.g. batch flush cache publish).
  Future<void> updateTableDataMeta(TableContext table, TableDataMeta meta,
      {bool flush = true,
      bool persistToDisk = true,
      BatchContext? batchContext,
      bool acquireLock = false,
      Uint8List? encryptionKey,
      int? encryptionKeyId}) async {
    final tableUid = table.tableUid;
    final lockResource = _tableDataMetaLockResource(tableUid);
    final operationId = GlobalIdGenerator.generate('update_table_meta_');
    final lockMgr = _dataStore.lockManager;
    var lockHeld = false;
    if (acquireLock && lockMgr != null) {
      lockHeld = await lockMgr.acquireExclusiveLock(lockResource, operationId);
      if (!lockHeld) {
        throw DbException([
          GeneralStatus(
            type: ResultType.sysTimeoutLockAcquisition,
            message:
                'Timed out waiting for table data meta lock: ${table.tableName}',
            target: lockResource,
            operation: 'updateTableDataMeta',
          ),
        ]);
      }
    }

    try {
      final partitionsDir =
          await _dataStore.pathManager.getPartitionsDirPath(tableUid);
      await _ensureDirectoryExists(partitionsDir);

      _tableDataMetaCache.put(
        tableUid,
        meta,
        size: _estimateTableDataMetaSize(meta),
      );
      _lastModifiedTimes[tableUid] = DateTime.now();

      if (persistToDisk) {
        await _dataStore.treeMetaPageService.persistTableGlobalMeta(
          tableUid: tableUid,
          meta: meta,
          batchContext: batchContext,
          flush: flush,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
        );
      }
    } catch (e) {
      Logger.error('Failed to update table data meta', rawError: e);
      rethrow;
    } finally {
      if (lockHeld && lockMgr != null) {
        lockMgr.releaseExclusiveLock(lockResource, operationId);
      }
    }
  }

  /// Ensure directory exists
  Future<void> _ensureDirectoryExists(String path) async {
    await _dataStore.storage.ensureDirectoryExists(path);
  }

  /// Get id generator, create if not exists. Single instance per table under concurrency.
  Future<IdGenerator> _getIdGenerator(TableContext table) async {
    final cached = _idGenerators[table.tableUid];
    if (cached != null) return cached;

    final pending = _idGeneratorPending[table.tableUid];
    if (pending != null) return await pending;

    final future = _createIdGeneratorForTable(table);
    _idGeneratorPending[table.tableUid] = future;
    try {
      final generator = await future;
      _idGenerators[table.tableUid] = generator;
      return generator;
    } finally {
      _idGeneratorPending.remove(table.tableUid);
    }
  }

  /// Create and initialize id generator for a table (single creation per table under concurrency).
  Future<IdGenerator> _createIdGeneratorForTable(TableContext table) async {
    try {
      final schema = table.schema;

      final generator = IdGeneratorFactory.createGenerator(
        schema,
        _dataStore.config,
        centralClient: _centralClient,
      );

      if (generator is SequentialIdGenerator) {
        final currentId = _maxIds[table.tableUid];

        if (currentId != null) {
          try {
            if (currentId is String && _isNumericString(currentId)) {
              final intId = int.parse(currentId);
              if (intId > 0) generator.setCurrentId(intId);
            } else if (currentId is int && currentId > 0) {
              generator.setCurrentId(currentId);
            }
          } catch (e) {
            Logger.error(
                'Failed to set id generator current value, value=$currentId',
                rawError: e);
          }
        } else {
          final initialValue =
              schema.primaryKeyConfig.sequentialConfig?.initialValue ?? 1;
          generator.setCurrentId(initialValue - 1);
        }
        if (_idRanges.containsKey(table.tableUid)) {
          final rangeInfo = _idRanges[table.tableUid];
          if (rangeInfo != null &&
              rangeInfo.containsKey('current') &&
              rangeInfo.containsKey('max')) {
            try {
              final current = rangeInfo['current'];
              final max = rangeInfo['max'];
              int currentInt, maxInt;
              if (current is String && max is String) {
                currentInt = int.parse(current);
                maxInt = int.parse(max);
              } else {
                currentInt = current as int;
                maxInt = max as int;
              }
              generator.setIdRange(currentInt, maxInt);
            } catch (e) {
              Logger.error('Failed to set id generator range', rawError: e);
            }
          }
        }
      }

      return generator;
    } catch (e) {
      Logger.error('Failed to get id generator', rawError: e);
      const defaultConfig = SequentialIdConfig();
      final tableUid = table.tableUid;
      final defaultGenerator =
          SequentialIdGenerator(defaultConfig, tableUid: tableUid);
      _idGenerators[table.tableUid] = defaultGenerator;
      return defaultGenerator;
    }
  }

  /// save id range info
  Future<void> _saveIdRange(TableContext table) async {
    if (_dataStore.config.persistenceMode == PersistenceMode.memory) {
      return;
    }
    final generator = _idGenerators[table.tableUid];
    if (generator is SequentialIdGenerator && generator.isDistributed) {
      // get current max id value
      final currentMaxId = _maxIds[table.tableUid];

      if (currentMaxId == null) return;

      // all ids use string type
      final maxIdStr = currentMaxId.toString();

      // if max id is numeric string, use generator's current id for persistence
      if (_isNumericString(maxIdStr)) {
        try {
          final currentIdInt = generator.currentId;

          // save as string type
          _idRanges[table.tableUid] = {
            'current': currentIdInt.toString(),
            'max': maxIdStr,
          };
        } catch (e) {
          Logger.error(
              'Failed to save id range: cannot parse string id to integer',
              rawError: e);
        }
      } else {
        // non-numeric string id, save current value directly
        _idRanges[table.tableUid] = {
          'current': maxIdStr,
          'max': maxIdStr,
        };
      }
    }
  }

  /// update max id from table data meta
  /// Update max auto-increment ID from table partitions and buffer
  /// This method calculates the maximum ID from:
  /// 1. Partition metadata (fast path for ordered partitions: O(1), fallback: O(n))
  /// 2. Buffered inserts in memory (from WAL recovery)
  /// 3. Schema-defined initial value if table is empty
  ///
  /// [forceRecalculate] if true, forces recalculation even if cache matches
  Future<void> updateMaxIdFromTable(TableContext table,
      {bool forceRecalculate = false}) async {
    final lockKey = 'id_gen_${table.tableUid}';
    final operationId = GlobalIdGenerator.generate('update_max_id_');
    bool acquired = await (_dataStore.lockManager
            ?.acquireExclusiveLock(lockKey, operationId) ??
        Future.value(false));
    try {
      await _updateMaxIdFromTableInternal(table,
          forceRecalculate: forceRecalculate);
    } finally {
      if (acquired) {
        _dataStore.lockManager?.releaseExclusiveLock(lockKey, operationId);
      }
    }
  }

  /// Internal version of updateMaxIdFromTable that assumes id_gen_tableUid lock is already held
  Future<void> _updateMaxIdFromTableInternal(TableContext table,
      {bool forceRecalculate = false}) async {
    try {
      final schema = table.schema;
      // handle sequential primary key
      if (schema.primaryKeyConfig.type != PrimaryKeyType.sequential) {
        return;
      }

      // get max id from table data meta + buffered WAL (if any)
      TableDataMeta? fileMeta = await getTableDataMeta(table.tableUid);

      // Performance optimization: if maxId is already in memory and matches FileMeta cache,
      // skip recalculation (especially useful after recovery when maxId was already updated)
      // However, if forceRecalculate is true, skip this check to ensure we include partition data
      if (!forceRecalculate &&
          _maxIds.containsKey(table.tableUid) &&
          fileMeta?.maxAutoIncrementId != null) {
        final cachedMaxId = _maxIds[table.tableUid];
        final fileMetaMaxId = fileMeta!.maxAutoIncrementId;
        if (cachedMaxId == fileMetaMaxId) {
          // Cache is valid, no need to recalculate
          return;
        }
      }

      dynamic maxFromPartitions;
      final pkMatcher =
          ValueMatcher.getMatcher(schema.getPrimaryKeyMatcherType());

      // Fast path for empty tables: skip B+Tree reverse scan (can cost 100ms+
      // on cold storage) when metadata already proves there are no records.
      final bool tableEmptyOnDisk =
          fileMeta == null || fileMeta.totalRecordCount <= 0;

      if (!tableEmptyOnDisk) {
        // Prefer cached maxAutoIncrementId when present — avoids a leaf scan.
        // !tableEmptyOnDisk implies fileMeta != null && totalRecordCount > 0.
        final cachedMetaMax = fileMeta.maxAutoIncrementId;
        if (cachedMetaMax != null &&
            cachedMetaMax.isNotEmpty &&
            cachedMetaMax != '0') {
          maxFromPartitions = cachedMetaMax;
        } else {
          // v2+ global B+Tree: take max key from the global leaf tail.
          try {
            final last = await _dataStore.tableTreePartitionManager
                ?.scanRecordsByPrimaryKeyRange(
              table: table,
              startKeyInclusive: Uint8List(0),
              endKeyExclusive: Uint8List(0),
              reverse: true,
              limit: 1,
            );
            if (last != null && last.isNotEmpty) {
              maxFromPartitions = last.first[schema.primaryKey];
            }
          } catch (_) {}
        }
      } else if (fileMeta?.maxAutoIncrementId != null &&
          fileMeta!.maxAutoIncrementId!.isNotEmpty) {
        // Empty on disk but meta remembers the high-water mark (e.g. after clear
        // that preserves auto-inc, or WAL-recovered max).
        maxFromPartitions = fileMeta.maxAutoIncrementId;
      }

      // Also consider buffered inserts recovered from WAL (in-memory buffer)
      dynamic maxFromBuffer;
      try {
        maxFromBuffer = _dataStore.writeBufferManager
            .getMaxPrimaryKey(table, schema.primaryKey, pkMatcher);
      } catch (_) {}

      // Combine candidates: take the maximum of partition max, buffer max, and current memory value
      // This ensures we get the true global maximum, especially important after WAL recovery
      // where we may have updated memory with WAL max, but need to compare with partition and buffer
      dynamic finalMax = maxFromPartitions;
      if (maxFromBuffer != null) {
        if (finalMax == null || pkMatcher(maxFromBuffer, finalMax) > 0) {
          finalMax = maxFromBuffer;
        }
      }

      // Also compare with current memory value (which may include WAL recovery max)
      // This is important when forceRecalculate=true after WAL recovery
      final currentMemoryMax = _maxIds[table.tableUid];
      if (currentMemoryMax != null) {
        try {
          dynamic currentMaxValue;
          if (currentMemoryMax is String &&
              _isNumericString(currentMemoryMax)) {
            currentMaxValue =
                int.tryParse(currentMemoryMax) ?? currentMemoryMax;
          } else {
            currentMaxValue = currentMemoryMax;
          }
          if (finalMax == null || pkMatcher(currentMaxValue, finalMax) > 0) {
            finalMax = currentMaxValue;
          }
        } catch (_) {
          // If comparison fails, ignore current memory value
        }
      }

      if (finalMax != null) {
        _maxIds[table.tableUid] = finalMax.toString();
        _maxIdsDirty[table.tableUid] = true;

        // Save to FileMeta for caching (avoid recalculation on next initialization)
        await mutateTableDataMeta(table, (current) {
          if (current == null) return null;
          return current.copyWith(maxAutoIncrementId: finalMax.toString());
        });
        return;
      }

      // If table and buffer are empty, initialize maxAutoIncrementId to "0".
      const emptyMaxIdStr = '0';
      _maxIds[table.tableUid] = emptyMaxIdStr;
      _maxIdsDirty[table.tableUid] = true;
      await mutateTableDataMeta(table, (current) {
        if (current == null) return null;
        return current.copyWith(maxAutoIncrementId: emptyMaxIdStr);
      });
    } catch (e) {
      Logger.error('Failed to update max id for table ${table.tableName}',
          rawError: e);
    }
  }

  /// handle primary key conflict when updating max id
  /// Reuses updateMaxIdFromTable to get the accurate max ID, then adjusts based on conflict
  Future<void> handlePrimaryKeyConflict(
      TableContext table, dynamic conflictId) async {
    try {
      final schema = table.schema;

      // Ensure max ID is loaded and up-to-date by recalculating from partitions and buffer
      await updateMaxIdFromTable(table, forceRecalculate: true);

      // get current max id
      final currentMaxId = _maxIds[table.tableUid];
      if (currentMaxId == null) return;

      // use general compare method to compare id
      final pkMatcher =
          ValueMatcher.getMatcher(schema.getPrimaryKeyMatcherType());
      final compareResult = pkMatcher(conflictId, currentMaxId);

      // only update when conflict id is greater than or equal to current max id
      if (compareResult >= 0) {
        // Use conflictId as the base candidate, but ensure we're past the actual max
        // by taking the maximum of conflictId and currentMaxId
        dynamic maxCandidate = conflictId;
        try {
          // Compare with current max to ensure we jump past it
          if (pkMatcher(currentMaxId, conflictId) > 0) {
            // Current max is greater, use it as base
            maxCandidate = currentMaxId;
          }
        } catch (_) {}

        String? newMaxId;
        // Select different processing strategy based on id type, jumping past the maximum
        if (maxCandidate is int) {
          newMaxId = maxCandidate.toString();
        } else if (maxCandidate is String) {
          if (_isNumericString(maxCandidate)) {
            // If it is a pure numeric string, use the current maximum value directly
            newMaxId = maxCandidate;
          } else if (_isShortCodeFormat(maxCandidate)) {
            // If it is not a number but conforms to the short code format, still append one at the end according to the original strategy to keep the "skipping conflict segment" backward
            newMaxId =
                '$maxCandidate${String.fromCharCode(97 + (DateTime.now().millisecondsSinceEpoch % 26))}';
          } else {
            newMaxId =
                '$maxCandidate${String.fromCharCode(97 + (DateTime.now().millisecondsSinceEpoch % 26))}';
          }
        } else {
          newMaxId =
              '${maxCandidate.toString()}${String.fromCharCode(97 + (DateTime.now().millisecondsSinceEpoch % 26))}';
        }

        _maxIds[table.tableUid] = newMaxId;
        _maxIdsDirty[table.tableUid] = true;

        // Save to FileMeta instead of standalone file
        await mutateTableDataMeta(table, (fileMeta) {
          if (fileMeta == null) return null;
          return fileMeta.copyWith(maxAutoIncrementId: newMaxId);
        });

        Logger.warn(
          'Table ${table.tableName} has primary key conflict, update auto increment start: $newMaxId',
        );

        // update generator current id (only for numeric id)
        if (_idGenerators.containsKey(table.tableUid)) {
          final generator = _idGenerators[table.tableUid];
          if (generator is SequentialIdGenerator &&
              _isNumericString(newMaxId)) {
            try {
              final newIdInt = int.parse(newMaxId);
              generator.setCurrentId(newIdInt);
            } catch (e) {
              Logger.error('Failed to parse new id to integer: $newMaxId',
                  rawError: e);
            }
          }
        }
      } else {
        // if current id is greater than conflict id, no need to adjust
        Logger.debug(
          'Table ${table.tableName} has primary key conflict, but current max id $currentMaxId is greater than conflict id $conflictId, no need to adjust',
        );
      }
    } catch (e) {
      Logger.error('Failed to handle primary key conflict', rawError: e);
    }
  }

  /// Stream records from a table.
  /// - File mode: traverse global B+Tree leaf chain + overlay buffer/transactions.
  /// - Memory mode: traverse inmemory TreeCache logical range + overlay buffer/transactions.
  Stream<Map<String, dynamic>> streamRecords(TableContext table,
      {Uint8List? customKey, int? customKeyId}) async* {
    final schema = table.schema;
    final primaryKey = schema.primaryKey;
    final tableContext = table;
    final bool isMemoryMode =
        _dataStore.config.persistenceMode == PersistenceMode.memory;

    // Fast path for empty tables (no partitions yet): only merge buffer/txn overlay.
    if (!isMemoryMode) {
      final fileMeta = await getTableDataMeta(table.tableUid);
      if (fileMeta == null || fileMeta.btreeFirstLeaf.isNull) {
        final yieldController =
            YieldController('TableDataManager.streamRecords_empty');
        final overlay = await mergeConsistency(
          table,
          [],
        );
        for (final r in overlay) {
          final y9 = yieldController.maybeYield();
          if (y9 != null) await y9;
          if (!isDeletedRecord(r)) yield r;
        }
        return;
      }
    }

    final yieldController =
        YieldController('TableDataManager.streamRecords', checkInterval: 50);

    // Track keys we've already processed from base stream to avoid duplicate lookups
    final Set<String> processedKeys = <String>{};

    // Get current transaction ID for transaction overlay
    final String? currentTxId = TransactionContext.getCurrentTransactionId();

    // Register read view for consistent snapshot
    final viewId = _dataStore.readViewManager.registerReadView();
    try {
      // Helper: apply buffer/transaction overlay for a base record and return final visible record (or null).
      Map<String, dynamic>? applyOverlay(Map<String, dynamic> record) {
        final pk = record[primaryKey]?.toString();
        if (pk == null || pk.isEmpty) return null;

        processedKeys.add(pk);

        // Check buffer for updates/deletes (O(1) lookup)
        final bufferEntry =
            _dataStore.writeBufferManager.getBufferedRecordForRead(
          tableContext,
          pk,
        );
        if (bufferEntry != null) {
          if (bufferEntry.operation == BufferOperationType.delete) {
            return null;
          }
          if (!isDeletedRecord(bufferEntry.data)) {
            return bufferEntry.data;
          }
          return null;
        }

        // Check transaction for updates/deletes (O(1) lookup)
        if (currentTxId != null) {
          final defOps = _txnDeferredOps[currentTxId]?[table.tableUid];
          final txOp = defOps?[pk];
          if (txOp != null) {
            if (txOp.type == BufferOperationType.delete) {
              return null;
            }
            // TxnDeferredOp stores oldValues separately; data is shared by ref
            // (same as buffer read path). Legacy guard if _oldValues was embedded.
            final txRecord = _visibleTxnRecord(txOp.data);
            if (!isDeletedRecord(txRecord)) {
              return txRecord;
            }
            return null;
          }
        }

        if (!isDeletedRecord(record)) {
          return record;
        }
        return null;
      }

      if (!isMemoryMode) {
        // File mode: stream from global B+Tree leaf chain.
        final rangeManager = _dataStore.tableTreePartitionManager;
        if (rangeManager == null) {
          return;
        }
        await for (final record in rangeManager.streamRecordsByPrimaryKeyRange(
          table: table,
          startKeyInclusive: Uint8List(0),
          endKeyExclusive: Uint8List(0),
          reverse: false,
          limit: null,
          encryptionKey: customKey,
          encryptionKeyId: customKeyId,
        )) {
          final y10 = yieldController.maybeYield();
          if (y10 != null) await y10;
          final merged = applyOverlay(record);
          if (merged != null) {
            yield merged;
          }
        }
      } else {
        // Memory mode: use logical TreeCache range scan + StreamController to preserve streaming semantics.
        final pkMatcher =
            ValueMatcher.getMatcher(schema.getPrimaryKeyMatcherType());

        bool recordPredicate(Map<String, dynamic> r) {
          // For streamRecords we only need to skip tombstones here;
          // buffer/txn deletes are handled in overlay logic.
          return !isDeletedRecord(r);
        }

        final controller = StreamController<Map<String, dynamic>>();

        () async {
          try {
            await _forEachRecordByPrimaryKeyRangeLogical(
              table: table,
              schema: schema,
              primaryKey: primaryKey,
              pkMatcher: pkMatcher,
              reverse: false,
              limit: null,
              recordPredicate: recordPredicate,
              startKeyInclusive: Uint8List(0),
              endKeyExclusive: Uint8List(0),
              rangeMin: null,
              rangeMax: null,
              includeMin: true,
              includeMax: true,
              cursorPk: null,
              onRecord: (r) {
                final merged = applyOverlay(r);
                if (merged != null) {
                  controller.add(merged);
                }
                return true;
              },
            );
          } catch (e, stack) {
            controller.addError(e, stack);
          } finally {
            await controller.close();
          }
        }();

        await for (final record in controller.stream) {
          final y11 = yieldController.maybeYield();
          if (y11 != null) await y11;
          yield record;
        }
      }

      // After streaming base records, yield buffer/transaction inserts that weren't in base stream.
      final bufferInsertKeys = _dataStore.writeBufferManager
          .getBufferedInsertKeys(tableContext, reverse: false);

      final Set<String> txInsertKeys = <String>{};
      if (currentTxId != null) {
        final defOps = _txnDeferredOps[currentTxId]?[table.tableUid];
        if (defOps != null) {
          for (final op in defOps.values) {
            if (op.type != BufferOperationType.delete) {
              final pk = op.data[primaryKey]?.toString();
              if (pk != null && pk.isNotEmpty) {
                txInsertKeys.add(pk);
              }
            }
          }
        }
      }

      for (final key in bufferInsertKeys) {
        if (processedKeys.contains(key)) {
          continue;
        }

        final y12 = yieldController.maybeYield();
        if (y12 != null) await y12;

        bool shadowedByDelete = false;
        if (currentTxId != null) {
          final defOps = _txnDeferredOps[currentTxId]?[table.tableUid];
          final txOp = defOps?[key];
          if (txOp != null && txOp.type == BufferOperationType.delete) {
            shadowedByDelete = true;
          }
        }
        if (shadowedByDelete) continue;

        final entry = _dataStore.writeBufferManager.getBufferedRecordForRead(
          tableContext,
          key,
        );
        if (entry != null &&
            entry.operation != BufferOperationType.delete &&
            !isDeletedRecord(entry.data)) {
          yield entry.data;
        }
      }

      for (final key in txInsertKeys) {
        if (processedKeys.contains(key)) {
          continue;
        }

        final y13 = yieldController.maybeYield();
        if (y13 != null) await y13;

        final defOps = _txnDeferredOps[currentTxId]?[table.tableUid];
        final txOp = defOps?[key];
        if (txOp != null &&
            txOp.type != BufferOperationType.delete &&
            !isDeletedRecord(txOp.data)) {
          yield _visibleTxnRecord(txOp.data);
        }
      }
    } finally {
      _dataStore.readViewManager.releaseReadView(viewId);
    }
  }

  /// set central server client
  void setCentralServerClient(CentralServerClient client) {
    _centralClient = client;
  }

  /// check if string is pure numeric string
  bool _isNumericString(String? str) {
    if (str == null || str.isEmpty) return false;
    return RegExp(r'^\d+$').hasMatch(str);
  }

  /// check if string is shortCode format (mixed alphanumeric short code)
  bool _isShortCodeFormat(String? str) {
    if (str == null || str.isEmpty) return false;
    return RegExp(r'^[0-9A-Za-z]+$').hasMatch(str);
  }

  /// Rollback: remove placeholders and drop deferred ops.
  Future<void> applyTransactionRollback(String txId) async {
    _txnDeferredOps.remove(txId);
    _txnResourceEstimates.remove(txId);
  }

  String _tableLockResource(TableContext table) =>
      _dataStore.getScopedResourceKey('table_${table.tableUid}');

  Future<TableWriteLock> acquireTableWriteLock(
    TableContext table, {
    String operationPrefix = 'table_write_',
  }) async {
    final lockManager = _dataStore.lockManager;
    if (lockManager == null) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Cannot acquire table write lock after database shutdown: ${table.tableName}',
        ),
      ]);
    }

    final lockKey = _tableLockResource(table);
    final operationId = GlobalIdGenerator.generate(operationPrefix);

    final acquired = await lockManager.acquireExclusiveLock(
      lockKey,
      operationId,
    );
    if (!acquired) {
      throw DbException([
        GeneralStatus(
          type: ResultType.sysTimeoutLockAcquisition,
          message: 'Timed out waiting for table write lock: ${table.tableName}',
          target: lockKey,
          operation: 'acquireTableWriteLock',
        ),
      ]);
    }
    return TableWriteLock._(
      tableUid: table.tableUid,
      tableName: table.tableName.value,
      resource: lockKey,
      operationId: operationId,
    );
  }

  void releaseTableWriteLock(TableWriteLock lock) {
    if (lock._released) return;
    if (lock.tableUid.isEmpty) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.engError,
          message: 'Invalid table write lock: table identity is missing',
          parameterName: 'lock',
        ),
      ]);
    }
    _dataStore.lockManager?.releaseExclusiveLock(
      lock.resource,
      lock.operationId,
    );
    lock._released = true;
  }

  Future<void> withTableWriteLock(
    TableContext table,
    Future<void> Function(TableWriteLock lock) action, {
    TableWriteLock? tableLock,
    String operationPrefix = 'table_write_',
  }) async {
    if (tableLock != null) {
      // Borrowed from an outer withTableWriteLock scope to avoid same-table
      // re-entry deadlocks. It is validated here, not acquired or released.
      tableLock.validateBorrowedFor(
        table.tableUid,
        expectedTableName: table.tableName.value,
      );
      return action(tableLock);
    }

    if (_dataStore.lockManager == null) {
      Logger.debug(
        'Skip table write lock after database shutdown: ${table.tableName}',
      );
      return;
    }

    final lock = await acquireTableWriteLock(
      table,
      operationPrefix: operationPrefix,
    );
    try {
      return await action(lock);
    } finally {
      releaseTableWriteLock(lock);
    }
  }

  /// high performance table data cleanup, including physical files and memory cache
  Future<void> clearTable(TableContext table) async {
    // Admission flag: set before acquiring the table lock so pending flushes
    // that acquire the lock earlier than clearTable can still yield to clear.
    _tableFlushingFlags[table.tableUid] = true;
    _maxIdsDirty[table.tableUid] = false; // Proactively stop background flush
    try {
      await withTableWriteLock(
        table,
        (_) async {
          // First, update statistics by subtracting this table's counts
          try {
            if (_contributesToSpaceStats(table)) {
              final fileMeta = await getTableDataMeta(table.tableUid);
              if (fileMeta != null) {
                _deltaRecordCount -= fileMeta.totalRecordCount;
                _deltaTableDataSizeBytes -= fileMeta.totalSizeBytes;
              }
              final indexBytes = await sumTableIndexDataSizeBytes(table);
              if (indexBytes != 0) {
                _deltaIndexDataSizeBytes -= indexBytes;
              }
              _needSaveStats = true;
            }
          } catch (e) {
            Logger.warn(
                'Failed to update stats during clearTable for ${table.tableName}',
                rawError: e);
          }

          // Always zero per-table count cache (system KV included).
          _tableRecordCounts[table.tableUid] = 0;

          await _dataStore.writeBufferManager.clearTableByUid(table.tableUid);

          // 2. directly delete the entire partition directory
          bool deletedDir = false;
          try {
            final dataPath =
                await _dataStore.pathManager.getDataDirPath(table.tableUid);
            if (await _dataStore.storage.existsDirectory(dataPath)) {
              await _dataStore.storage.deleteDirectory(dataPath);
              // delete and recreate empty directory, ensure directory structure is complete
              await _dataStore.storage.ensureDirectoryExists(dataPath);
              Logger.debug(
                  'deleted entire partition directory for table ${table.tableName}');
              deletedDir = true;
            }
          } catch (e) {
            Logger.error(
                'delete table ${table.tableName} partition directory failed',
                rawError: e);
          }

          // 3. create empty table data meta
          final prevMeta = await getTableDataMeta(table.tableUid);
          final int newPartitionCount =
              deletedDir ? 1 : max(1, (prevMeta?.btreePartitionCount ?? 0) + 1);
          final tableUid = table.tableUid;
          final emptyMeta = TableDataMeta.createEmpty(
            tableUid: tableUid,
            partitionCount: newPartitionCount,
          );

          // 4. update table data meta (full replace under table write lock)
          await mutateTableDataMeta(table, (_) => emptyMeta);

          // 5. clean ID generator related resources
          _idGenerators.remove(table.tableUid);
          _idGeneratorPending.remove(table.tableUid);
          TimeBasedIdGenerator.handleTableDelete(table.tableUid);

          // 6. handle auto increment ID reset
          try {
            final schema = table.schema;
            if (schema.primaryKeyConfig.type == PrimaryKeyType.sequential) {
              // Reset maxId in FileMeta to "0"
              await mutateTableDataMeta(table, (fileMeta) {
                if (fileMeta == null) return null;
                return fileMeta.copyWith(maxAutoIncrementId: '0');
              });

              // update memory cache
              _maxIds[table.tableUid] = "0";
              _maxIdsDirty[table.tableUid] = false; // Already saved to FileMeta

              // clean ID generator resources
              _idRanges.remove(table.tableUid);
            }
          } catch (e) {
            Logger.error(
                'reset table ${table.tableName} auto increment ID failed',
                rawError: e);
          }

          // 7. clean other caches
          _tableDataMetaCache.remove(table.tableUid);
          _fileSizes.remove(table.tableUid);
          _lastModifiedTimes.remove(table.tableUid);
          _checkedOrderedRange.remove(table.tableUid);
        },
        operationPrefix: 'clear_table_',
      );
    } catch (e) {
      Logger.error('clear table ${table.tableName} failed', rawError: e);
      rethrow; // rethrow error to upper level
    } finally {
      // clear table flush flag
      _tableFlushingFlags.remove(table.tableUid);
    }
  }

  /// Rewrite records from source table to target table using batch processing
  /// This is optimized for table renaming operations, much faster than using stream approach
  Future<void> rewriteRecordsFromSourceTable({
    required String sourceTableName,
    required String targetTableName,
    required Future<List<Map<String, dynamic>>> Function(
      List<Map<String, dynamic>> records,
      int partitionNo,
    ) processFunction,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    // Acquire exclusive locks in deterministic order to avoid deadlocks
    final tablesToLock = [sourceTableName, targetTableName]..sort();

    // Store opId for each table: tableName -> opId
    final tableOpIds = <String, String>{};
    final acquiredKeys = <String, bool>{};
    final lockManager = _dataStore.lockManager;
    if (lockManager == null) {
      Logger.debug(
        'Skip rewriteRecordsFromSourceTable after database shutdown',
      );
      return;
    }

    try {
      for (final t in tablesToLock) {
        // Generate unique opId for each lock request to satisfy LockManager constraint
        final opId = GlobalIdGenerator.generate('rewrite_records_${t}_');
        tableOpIds[t] = opId;

        final lk = 'table_$t';
        final ok = await lockManager.acquireExclusiveLock(lk, opId);
        if (!ok) {
          Logger.warn('Failed to acquire lock for $t, abort rewrite');
          // release any previous locks
          for (final prev in tablesToLock) {
            if (prev == t) break;
            final plk = 'table_$prev';
            final prevOpId = tableOpIds[prev];
            if (acquiredKeys[plk] == true && prevOpId != null) {
              lockManager.releaseExclusiveLock(plk, prevOpId);
            }
          }
          return;
        }
        acquiredKeys['table_$t'] = true;
      }

      // Get source/target table contexts. Decode uses sourceTable.schema snapshot.
      final sourceTable = await _dataStore.getTableContext(sourceTableName);
      final targetTable = await _dataStore.getTableContext(targetTableName);

      // v2+ global B+Tree: stream all records and rewrite in bounded batches.
      final rangeManager = _dataStore.tableTreePartitionManager;
      const int batchSize = 1000;
      final batch = <Map<String, dynamic>>[];
      final yc = YieldController(
          'TableDataManager.rewriteRecordsFromSourceTable',
          checkInterval: 200);

      Future<void> flushBatch() async {
        if (batch.isEmpty) return;
        // Note: rewriteRecordsFromSourceTable uses streaming, not partition-based processing
        // Pass -1 as partitionNo to indicate not applicable
        final processed =
            await processFunction(List<Map<String, dynamic>>.from(batch), -1);
        batch.clear();
        if (processed.isEmpty) return;
        await rangeManager?.writeChanges(
          table: targetTable,
          inserts: processed,
          updates: const [],
          deletes: const [],
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
        );
      }

      // Decode with sourceTable.schema snapshot (accompanies on-disk layout).
      if (rangeManager == null) return;
      await for (final r in rangeManager.streamRecordsByPrimaryKeyRange(
        table: sourceTable,
        startKeyInclusive: Uint8List(0),
        endKeyExclusive: Uint8List(0),
        reverse: false,
        limit: null,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
      )) {
        final y14 = yc.maybeYield();
        if (y14 != null) await y14;
        batch.add(r);
        if (batch.length >= batchSize) {
          await flushBatch();
        }
      }
      await flushBatch();
      try {
        await _dataStore.storage.flushAll();
      } catch (_) {}
    } catch (e) {
      Logger.error('Failed to rewrite records from source table', rawError: e);
    } finally {
      // Release locks
      for (final t in tablesToLock) {
        final lk = 'table_$t';
        final opId = tableOpIds[t];
        if (acquiredKeys[lk] == true && opId != null) {
          lockManager.releaseExclusiveLock(lk, opId);
        }
      }
    }
  }

  /// Get current table data metadata cache size in bytes
  int getCurrentTableDataMetaCacheSize() {
    return _tableDataMetaCache.estimatedTotalSizeBytes;
  }

  /// Merges uncommitted data (WAL buffer and transaction overlays) into the results.
  /// [onlyMergeTransaction] indicates if the input [records] already contains all possible committed records
  /// for the query context (e.g. all point-lookup keys were found). In such cases, we can skip
  /// scanning buffers for NEW inserts.
  Future<List<Map<String, dynamic>>> mergeConsistency(
    TableContext table,
    List<Map<String, dynamic>> records, {
    ConditionRecordMatcher? matcher,
    bool Function(String)? keyPredicate,
    int? limit,
    List<String>? orderBy,
    bool Function(Map<String, dynamic>)? filter,
    bool reverse = false,
    bool onlyMergeTransaction = false,
    Iterable<String>? explicitInsertKeys,
    Iterable<String>? explicitTxInsertKeys,
  }) async {
    final schema = table.schema;
    final tableContext = table;
    final primaryKey = schema.primaryKey;
    final baseRecords = <String, Map<String, dynamic>>{};

    final String? currentTxId = TransactionContext.getCurrentTransactionId();
    final bool trackReadKeys = currentTxId != null &&
        TransactionContext.getCurrentIsolationLevel() ==
            TransactionIsolationLevel.serializable;

    // Convert input list to Map<PK, Record> for O(1) access
    final yieldController =
        YieldController('TableDataManager.mergeConsistency');
    for (final r in records) {
      final y15 = yieldController.maybeYield();
      if (y15 != null) await y15;
      final pk = r[primaryKey]?.toString();
      if (pk == null || pk.isEmpty) continue;
      baseRecords[pk] = r;
    }

    // Optimization: Calculate target count for early break
    final int targetCollectCount = (limit != null) ? limit : -1;
    // Track how many items we pulled from buffer (for reverse optimization logic)
    int addedFromBufferCount = 0;

    // Determine optimization strategy
    bool performEarlyBreak = false;
    if (limit != null && limit > 0) {
      performEarlyBreak = true;
    }

    bool hasReachedTarget() {
      if (!performEarlyBreak) return false;
      // If doing a reverse scan (for DESC sort), we treat buffer as "newer/better".
      // We must not stop until we have collected 'limit' items FROM THE BUFFER
      // (or buffer runs out), ignoring how many "old" disk items we have.
      if (reverse) {
        return addedFromBufferCount >= targetCollectCount;
      }
      return baseRecords.length >= targetCollectCount;
    }

    // Helper: Apply buffer entry if it's a NEW INSERT (Phase 2)
    void applyBufferInsert(String pk, BufferEntry be) {
      // If we already handled it as update, skip
      if (baseRecords.containsKey(pk)) return;

      if (be.operation != BufferOperationType.delete &&
          (matcher == null || matcher.matches(be.data))) {
        // It's a new record that matches.
        // Check valid limit
        if (!performEarlyBreak || !hasReachedTarget()) {
          baseRecords[pk] = be.data;
          addedFromBufferCount++;
        }
      }
    }

    // Share txn deferred maps by reference (oldValues live on TxnDeferredOp).
    // See [_visibleTxnRecord].
    if (!onlyMergeTransaction) {
      // --- PHASE 1: Efficient Update/Delete (Lookup from Disk Results) ---
      // Instead of scanning the whole buffer for updates, we scan the specific records we retrieved.
      // This is O(disk_records), avoiding O(buffer_size) scan for this part.

      // We iterate a snapshot of initial keys because baseRecords might change.
      final initialKeys = baseRecords.keys.toList(growable: false);
      for (final pk in initialKeys) {
        final be = _dataStore.writeBufferManager.getBufferedRecordForRead(
          tableContext,
          pk,
        );
        if (be != null) {
          if (be.operation == BufferOperationType.delete) {
            baseRecords.remove(pk);
          } else {
            baseRecords[pk] = be.data;
          }
        }
      }

      // handle insert buffer
      Iterable<String> keys;
      if (explicitInsertKeys != null) {
        keys = explicitInsertKeys;
      } else {
        final candidates =
            _dataStore.migrationManager?.getRuntimeReadTableCandidates(table) ??
                const <String>[];
        if (candidates.isEmpty) {
          keys = _dataStore.writeBufferManager
              .getBufferedInsertKeys(tableContext, reverse: reverse);
        } else {
          final allInsertKeys = <String>[];
          allInsertKeys.addAll(_dataStore.writeBufferManager
              .getBufferedInsertKeys(tableContext, reverse: reverse));
          keys = allInsertKeys;
        }
      }

      for (final key in keys) {
        final y16 = yieldController.maybeYield();
        if (y16 != null) await y16;
        if (performEarlyBreak && hasReachedTarget()) break;

        if (keyPredicate != null && !keyPredicate(key)) continue;

        final entry = _dataStore.writeBufferManager.getBufferedRecordForRead(
          tableContext,
          key,
        );
        if (entry == null) continue;

        final rec = entry.data;
        if (filter != null && !filter(rec)) continue;

        applyBufferInsert(key, entry);
      }
    }

    // 2.3 Transaction Deferred Ops (if any)
    if (currentTxId != null) {
      final defOps = _txnDeferredOps[currentTxId]?[table.tableUid];
      if (defOps != null && defOps.isNotEmpty) {
        // Phase 3.1: Efficient Update/Delete (Lookup from baseRecords)
        if (baseRecords.isNotEmpty) {
          final snapshotKeys = baseRecords.keys.toList(growable: false);
          for (final pk in snapshotKeys) {
            final op = defOps[pk];
            if (op != null) {
              if (op.type == BufferOperationType.delete) {
                baseRecords.remove(pk);
              } else {
                baseRecords[pk] = _visibleTxnRecord(op.data);
              }
            }
          }
        }

        // Phase 3.2: Collect New Inserts (Scan defOps)
        // We only need to scan for inserts if we haven't reached the target count.
        // This is a major optimization: if limit is met, we skip the O(M) scan entirely.
        if (!performEarlyBreak || !hasReachedTarget()) {
          // If explicit tx keys provided (optimized stream path), use them.
          // Otherwise iterate all deferred ops (heavy path).
          if (explicitTxInsertKeys != null) {
            for (final pk in explicitTxInsertKeys) {
              final y17 = yieldController.maybeYield();
              if (y17 != null) await y17;
              if (performEarlyBreak && hasReachedTarget()) break;

              final op = defOps[pk];
              if (op == null) continue;

              if (baseRecords.containsKey(pk)) continue;

              if (op.type != BufferOperationType.delete) {
                final visible = _visibleTxnRecord(op.data);
                if (matcher == null || matcher.matches(visible)) {
                  baseRecords[pk] = visible;
                }
              }
            }
          } else {
            // Iterate values (Iterable) is cheaper than converting to list
            for (final op in defOps.values) {
              final y18 = yieldController.maybeYield();
              if (y18 != null) await y18;
              // Check limit again strictly inside loop
              if (performEarlyBreak && hasReachedTarget()) break;

              final pk = op.data[primaryKey]?.toString();
              if (pk == null) continue;

              // If already in baseRecords, it was handled in Phase 3.1
              if (baseRecords.containsKey(pk)) continue;

              // New insert logic
              if (op.type != BufferOperationType.delete) {
                final visible = _visibleTxnRecord(op.data);
                if (matcher == null || matcher.matches(visible)) {
                  baseRecords[pk] = visible;
                }
              }
            }
          }
        }
      }
    }

    if (currentTxId != null) {
      // 3.2 Deferred heavy delete conditions
      try {
        final plans = _dataStore.transactionManager
                ?.getDeferredHeavyDeletes(currentTxId) ??
            const <HeavyDeletePlan>[];
        if (plans.isNotEmpty) {
          for (final plan in plans) {
            if (plan.tableUid != tableContext.tableUid) continue;
            final qc = QueryCondition.fromMap(plan.condition);
            final hdMatcher = ConditionRecordMatcher.prepare(
                qc, {table.tableUid: schema}, table.tableUid);

            final snapshotList = baseRecords.entries.toList(growable: false);
            for (final entry in snapshotList) {
              final y19 = yieldController.maybeYield();
              if (y19 != null) await y19;
              if (hdMatcher.matches(entry.value)) {
                baseRecords.remove(entry.key);
              }
            }
          }
        }
      } catch (_) {}

      // 3.3 Deferred heavy updates
      try {
        final plans = _dataStore.transactionManager
                ?.getDeferredHeavyUpdates(currentTxId) ??
            const <HeavyUpdatePlan>[];
        if (plans.isNotEmpty) {
          for (final plan in plans) {
            if (plan.tableUid != tableContext.tableUid) continue;
            // We need to apply updates to all matching records in baseRecords
            final qc = QueryCondition.fromMap(plan.condition);
            final hmMatcher = ConditionRecordMatcher.prepare(
                qc, {table.tableUid: schema}, table.tableUid);

            // Iterate keys first to avoid concurrent modification of baseRecords during update

            for (final k in baseRecords.keys) {
              final y20 = yieldController.maybeYield();
              if (y20 != null) await y20;
              if (hmMatcher.matches(baseRecords[k]!)) {
                baseRecords[k] = Map<String, dynamic>.from(baseRecords[k]!);
                baseRecords[k]!.addAll(plan.updateData);
              }
            }
          }
        }
      } catch (_) {}
    }

    // 4. Apply query matcher and (optionally) register read-set keys (SSI only)
    if (matcher == null && !trackReadKeys) {
      return baseRecords.values.toList();
    }

    final results = <Map<String, dynamic>>[];
    // Snapshot values to avoid concurrent modification if yielding
    final recordValues = baseRecords.values.toList(growable: false);
    if (matcher != null && !trackReadKeys && recordValues.length > 1000) {
      final matchResult = await ConditionBatchMatcher.matchRecordIndices(
        schema: schema,
        table: tableContext,
        condition: matcher.condition.build(),
        records: recordValues,
        estimateRecordBytes: estimateRecordSizeBytes,
      );
      for (final matchedIndex in matchResult.matchedIndices) {
        final y21 = yieldController.maybeYield();
        if (y21 != null) await y21;
        results.add(recordValues[matchedIndex]);
      }
      return results;
    }

    for (final r in recordValues) {
      final y22 = yieldController.maybeYield();
      if (y22 != null) await y22;
      if (matcher != null && !matcher.matches(r)) continue;
      results.add(r);
      if (trackReadKeys) {
        final k = r[primaryKey]?.toString();
        if (k != null && k.isNotEmpty) {
          TransactionContext.registerReadKey(table.tableUid, k);
        }
      }
    }
    return results;
  }

  /// Removes a record from any of the in-memory buffers.
  void removeRecordFromBuffer(TableContext table, String recordId) {
    _dataStore.writeBufferManager.removeRecord(table, recordId);
  }

  /// Removes all data and metadata for a table from the manager.
  Future<void> removeTable(TableContext table) async {
    // Clean up all in-memory buffers and caches
    // legacy buffers removed

    // Clear WAL-driven table-level write buffer and queue to prevent subsequent writes
    _dataStore.writeBufferManager.clearTableByUid(table.tableUid);

    // Clean up other caches
    _tableDataMetaCache.remove(table.tableUid);
    _fileSizes.remove(table.tableUid);
    _lastModifiedTimes.remove(table.tableUid);
    _tablePartitionSizes.remove(table.tableUid);
    _maxIds.remove(table.tableUid);
    _maxIdsDirty.remove(table.tableUid);
    _idGenerators.remove(table.tableUid);
    _idGeneratorPending.remove(table.tableUid);
    TimeBasedIdGenerator.handleTableDelete(table.tableUid);
    _idRanges.remove(table.tableUid);
    _checkedOrderedRange.remove(table.tableUid);
    _tableFlushingFlags.remove(table.tableUid);
  }

  /// Cleanup transactional in-memory state not tied to active transactions
  Future<void> cleanupTransactionalState(
      {required int nowMs,
      required int ttlMs,
      required Set<String> Function() getActiveTxIds}) async {
    try {
      final active = getActiveTxIds();
      // Build union of txIds from both maps, then remove active ones; single pass removals
      final inactive = <String>{
        ..._txnDeferredOps.keys,
      }..removeWhere((tx) => active.contains(tx));

      for (final tx in inactive) {
        _txnDeferredOps.remove(tx);
        _txnResourceEstimates.remove(tx);
      }
    } catch (e) {
      Logger.warn('cleanupTransactionalState failed', rawError: e);
    }
  }

  /// Remove specific transaction state (called by rollback/cleanup)
  Future<void> clearTransactionState(String transactionId) async {
    _txnDeferredOps.remove(transactionId);
    _txnResourceEstimates.remove(transactionId);
    // Also clear from WriteBufferManager unique key tracking
    await _dataStore.writeBufferManager
        .removeTransactionUniqueKeys(transactionId);
  }

  /// Check if there are deferred ops for a transaction
  bool hasDeferredOps(String transactionId) {
    return _txnDeferredOps.containsKey(transactionId);
  }

  /// Get deferred ops for transaction (internal/recovery use only)
  ///
  /// Returns an Iterable view to avoid expensive list copying.
  /// Caller must process immediately or aware that underlying map must not change.
  Map<String, Iterable<TxnDeferredOp>>? getDeferredOps(String transactionId) {
    final ops = _txnDeferredOps[transactionId];
    if (ops == null) return null;
    // Return defensive copy of the map structure, but use Iterable for values
    // to avoid O(N) list allocation.
    final result = <String, Iterable<TxnDeferredOp>>{};
    ops.forEach((tableName, pkMap) {
      result[tableName] = pkMap.values;
    });
    return result;
  }

  /// Reject a transaction only when memory pressure makes its retained data
  /// unsafe. Under normal memory conditions no transaction size cap is applied.
  void ensureTransactionWithinResourceLimits(String transactionId) {
    final rm = _dataStore.resourceManager;
    if (rm == null) return;
    final status = rm.memoryStatus;
    if (status == ResourceStatus.normal) return;

    final estimateCount =
        _txnResourceEstimates[transactionId]?.operationCount ?? 0;
    _checkTransactionLimits(transactionId, status, estimateCount);
  }

  /// Perform batch resource validation and tracking for transactions.
  /// This optimizes performance in batch write scenarios by scaling from O(M) down to O(1) database checks.
  void _trackTransactionBufferBatch(
    String transactionId,
    List<Map<String, dynamic>> records,
    Map<String, Map<String, dynamic>>? oldRecordsMap,
    String pkName,
  ) {
    final rm = _dataStore.resourceManager;
    if (rm == null) return;

    final status = rm.memoryStatus;

    // 1. Retrieve or initialize the resource estimate (performs only 1 Map lookup)
    final estimate = _txnResourceEstimates.putIfAbsent(
        transactionId, _TransactionResourceEstimate.new);

    // 2. Proactive validation under memory pressure
    if (status != ResourceStatus.normal) {
      final projectedCount = estimate.operationCount + records.length;
      _checkTransactionLimits(transactionId, status, projectedCount);
    }

    if (records.isEmpty) return;

    // 3. Increment operation count directly (using records.length without loops)
    estimate.operationCount += records.length;

    // 4. Sample data size: only active and compiled under warning stage to keep normal path zero-overhead
    if (status == ResourceStatus.warning &&
        estimate.sampleCount < _transactionSampleSize) {
      // Sample head records (up to 5)
      final int headCount = min(5, records.length);
      for (int i = 0; i < headCount; i++) {
        if (estimate.sampleCount >= _transactionSampleSize) break;
        final data = records[i];
        final rId = data[pkName]?.toString();
        final oldVal = oldRecordsMap != null ? oldRecordsMap[rId] : null;
        estimate.sampleBytes += estimateRecordSizeBytes(data) +
            (oldVal == null ? 0 : estimateRecordSizeBytes(oldVal));
        estimate.sampleCount++;
      }

      // Sample tail records (up to 5, if they don't overlap with head)
      if (records.length > 5 && estimate.sampleCount < _transactionSampleSize) {
        final int tailStart = max(5, records.length - 5);
        for (int i = tailStart; i < records.length; i++) {
          if (estimate.sampleCount >= _transactionSampleSize) break;
          final data = records[i];
          final rId = data[pkName]?.toString();
          final oldVal = oldRecordsMap != null ? oldRecordsMap[rId] : null;
          estimate.sampleBytes += estimateRecordSizeBytes(data) +
              (oldVal == null ? 0 : estimateRecordSizeBytes(oldVal));
          estimate.sampleCount++;
        }
      }
    }

    // 5. Post-aggregation limit verification (warning stage check)
    if (status == ResourceStatus.warning) {
      _checkTransactionLimits(transactionId, status, estimate.operationCount);
    }
  }

  /// Internal helper to evaluate memory resource safety limits.
  void _checkTransactionLimits(
      String transactionId, ResourceStatus status, int projectedCount) {
    if (status == ResourceStatus.critical) {
      throw DbException([
        TransactionOperationStatus(
          type: ResultType.sysResourceExhaustedMemory,
          message:
              'Transaction blocked: Insufficient system memory to execute transaction write operations. Please free up memory or retry later.',
          txId: transactionId,
        ),
      ]);
    }

    if (status == ResourceStatus.warning) {
      if (projectedCount > _transactionOperationWarningLimit) {
        throw DbException([
          TransactionOperationStatus(
            type: ResultType.sysTransactionLimitExceeded,
            message:
                'Transaction rejected because its buffered data is too large under current memory pressure. Split the work into smaller transactions and retry.',
            txId: transactionId,
          ),
        ]);
      }

      final estimate = _txnResourceEstimates[transactionId];
      if (estimate != null && estimate.sampleCount > 0) {
        final exceedsBytes = estimate.sampleBytes * projectedCount >
            _transactionBytesWarningLimit * estimate.sampleCount;

        if (exceedsBytes) {
          throw DbException([
            TransactionOperationStatus(
              type: ResultType.sysTransactionLimitExceeded,
              message:
                  'Transaction rejected because its buffered data is too large under current memory pressure. Split the work into smaller transactions and retry.',
              txId: transactionId,
            ),
          ]);
        }
      }
    }
  }

  /// Writes the given changes (inserts, updates, deletes) to the partition files of the specified table.
  ///
  /// This method merges inserted, updated, and deleted records according to their partitions and then writes them
  /// to the corresponding partition files. Optionally supports encryption via a custom key.
  ///
  /// [table]              - Table context for which changes should be written.
  /// [inserts]            - List of records to insert.
  /// [updates]            - List of records to update.
  /// [deletes]            - List of records to delete.
  /// [batchContext]       - Optional: The batch context for write batches.
  /// [concurrency]        - Optional: total number of concurrent processing tokens
  /// [encryptionKey]      - Optional: encrypt key
  /// [encryptionKeyId]    - Optional: encrypt key id
  /// [tableLock]          - Optional: existing table-level write lock.
  /// [recordCountInsertDelta]/[recordCountDeleteDelta] - Optional logical
  /// count deltas for direct writes that bypass WriteBufferManager statistics.
  /// [fieldStructureOverride] - Optional physical field layout override.
  /// [schemaOverride] - Optional schema override (primary-key extraction/encoding).
  Future<void> writeChanges({
    required TableContext table,
    List<Map<String, dynamic>> inserts = const [],
    List<Map<String, dynamic>> updates = const [],
    List<Map<String, dynamic>> deletes = const [],
    BatchContext? batchContext,
    int? concurrency,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    TableWriteLock? tableLock,
    int recordCountInsertDelta = 0,
    int recordCountDeleteDelta = 0,
    List<FieldStructure>? fieldStructureOverride,
    TableSchema? schemaOverride,
  }) async {
    final int recordCountDelta =
        recordCountInsertDelta - recordCountDeleteDelta;
    if (recordCountDelta != 0) {
      // Load before the physical write so applying the explicit delta below
      // does not accidentally double-count against freshly updated metadata.
      await _ensureRecordCountLoaded(table);
    }

    await withTableWriteLock(
      table,
      (lock) async {
        await _dataStore.tableTreePartitionManager?.writeChanges(
          table: table,
          inserts: inserts,
          updates: updates,
          deletes: deletes,
          batchContext: batchContext,
          concurrency: concurrency,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
          fieldStructureOverride: fieldStructureOverride,
          schemaOverride: schemaOverride,
        );
      },
      tableLock: tableLock,
      operationPrefix: 'write_changes_',
    );

    if (recordCountDelta != 0) {
      await updateTableRecordCountDelta(
        table,
        insertDelta: recordCountInsertDelta,
        deleteDelta: recordCountDeleteDelta,
      );
    }
  }

  /// Batch query with full consistency checking (Txn > Cache > Buffer > Disk).
  /// Batch query. Note: Returns results from Cache and Disk (Committed data).
  /// [isConsistent] in the result indicates if all requested keys were found in the committed state.
  Future<TableScanResult> queryRecordsBatch(
    TableContext table,
    List<dynamic> keys, {
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool readFromFileOnly = false,
    TableSchema? decodeSchema,
    List<FieldStructure>? decodeFieldStructureOverride,
  }) async {
    if (keys.isEmpty) return TableScanResult(records: []);

    final schema = decodeSchema ?? table.schema;

    final results = <Map<String, dynamic>>[];
    final missingKeys = <dynamic>[];
    final uniqueKeys = keys.toSet().toList();

    // 1. Try Cache
    if (!readFromFileOnly) {
      for (final key in uniqueKeys) {
        final pk = key.toString();
        final cached = _tableRecordCache.get([table.tableUid, pk]);
        if (cached != null) {
          results.add(cached);
        } else {
          missingKeys.add(key);
        }
      }
    } else {
      missingKeys.addAll(uniqueKeys);
    }

    // 2. Try Disk
    if (missingKeys.isNotEmpty) {
      final pkMatcher =
          ValueMatcher.getMatcher(schema.getPrimaryKeyMatcherType());
      if (_dataStore.tableTreePartitionManager == null) {
        return TableScanResult(records: []);
      }
      final diskResults =
          await _dataStore.tableTreePartitionManager?.queryRecordsBatch(
        table: table,
        primaryKey: schema.primaryKey,
        keyComparator: pkMatcher,
        keys: missingKeys,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        schemaOverride: schema,
        decodeFieldStructureOverride: decodeFieldStructureOverride,
        readFromFileOnly: readFromFileOnly,
      );
      if (diskResults == null) {
        return TableScanResult(records: []);
      }

      // Read-Through: Cache the results fetched from disk (Asynchronously)
      if (diskResults.isNotEmpty && !readFromFileOnly) {
        _asyncCacheDiskResults(
          table: table,
          diskResults: diskResults,
          schema: schema,
        );
      }
      results.addAll(diskResults);
    }

    return TableScanResult(
      records: results,
    );
  }

  Future<void> _forEachRecordByPrimaryKeyRangeLogical({
    required TableContext table,
    required TableSchema schema,
    required String primaryKey,
    required MatcherFunction pkMatcher,
    required bool reverse,
    required int? limit,
    required bool Function(Map<String, dynamic>) recordPredicate,
    required Uint8List startKeyInclusive,
    required Uint8List endKeyExclusive,
    dynamic rangeMin,
    dynamic rangeMax,
    bool includeMin = true,
    bool includeMax = true,
    String? cursorPk,
    bool decodeRecord = true,
    required bool Function(Map<String, dynamic>) onRecord,
    TableSchema? decodeSchema,
    List<FieldStructure>? decodeFieldStructureOverride,
    bool readFromFileOnly = false,
  }) async {
    final isMemoryMode =
        _dataStore.config.persistenceMode == PersistenceMode.memory;

    if (!isMemoryMode) {
      await _dataStore.tableTreePartitionManager
          ?.forEachRecordByPrimaryKeyRange(
        table: table,
        startKeyInclusive: startKeyInclusive,
        endKeyExclusive: endKeyExclusive,
        reverse: reverse,
        limit: limit,
        recordPredicate: recordPredicate,
        onRecord: (r) => onRecord(r),
        decodeRecord: decodeRecord,
        decodeSchema: decodeSchema,
        decodeFieldStructureOverride: decodeFieldStructureOverride,
        readFromFileOnly: readFromFileOnly,
      );
      return;
    }

    _registerTableComparator(table, schema);

    int yielded = 0;
    final int? hardLimit = limit;
    final String? cursor =
        cursorPk != null && cursorPk.isNotEmpty ? cursorPk : null;

    dynamic lowBoundPk = rangeMin;
    dynamic highBoundPk = rangeMax;

    if (cursor != null) {
      if (!reverse) {
        // ASC: start from max(rangeMin, cursor) after
        if (lowBoundPk == null) {
          lowBoundPk = cursor;
        } else if (pkMatcher(lowBoundPk, cursor) < 0) {
          lowBoundPk = cursor;
        }
      } else {
        // DESC: start from min(rangeMax, cursor) before
        if (highBoundPk == null) {
          highBoundPk = cursor;
        } else if (pkMatcher(highBoundPk, cursor) > 0) {
          highBoundPk = cursor;
        }
      }
    }

    // Calculate the physical start and end keys for TreeCache, only used to limit the B+Tree scan range
    late final List<dynamic> startKeyPath;
    List<dynamic>? endKeyPath;

    if (!reverse) {
      // ASC: start from lowBoundPk (if any) until highBoundPk (if any)
      if (lowBoundPk != null) {
        startKeyPath = [table.tableUid, lowBoundPk];
      } else {
        startKeyPath = [table.tableUid];
      }

      if (highBoundPk != null) {
        endKeyPath = [table.tableUid, highBoundPk];
      } else {
        endKeyPath = null;
      }
    } else {
      // DESC: start from rangeMin (if any, otherwise tableName prefix)
      // end at highBoundPk (the smaller value of rangeMax/cursor)
      if (lowBoundPk != null) {
        startKeyPath = [table.tableUid, lowBoundPk];
      } else {
        startKeyPath = [table.tableUid];
      }

      if (highBoundPk != null) {
        endKeyPath = [table.tableUid, highBoundPk];
      } else {
        endKeyPath = null;
      }
    }

    bool checkRange(dynamic pkNative) {
      if (rangeMin != null) {
        final c = pkMatcher(pkNative, rangeMin);
        if (c < 0 || (c == 0 && !includeMin)) return false;
      }
      if (rangeMax != null) {
        final c = pkMatcher(pkNative, rangeMax);
        if (c > 0 || (c == 0 && !includeMax)) return false;
      }
      if (cursor != null) {
        final cc = pkMatcher(pkNative, cursor);
        if (!reverse) {
          if (cc <= 0) return false;
        } else {
          if (cc >= 0) return false;
        }
      }
      return true;
    }

    await _tableRecordCache.scanRange(
      startKeyPath,
      endKeyPath,
      reverse: reverse,
      limit: null,
      onEntry: (path, value) {
        final rec = value;
        if (isDeletedRecord(rec)) return true;

        final dynamic pkNative = rec[primaryKey];
        if (pkNative == null) return true;

        if (!checkRange(pkNative)) return true;
        if (!recordPredicate(rec)) return true;

        if (!onRecord(rec)) {
          return false;
        }

        if (hardLimit != null) {
          yielded++;
          if (yielded >= hardLimit) {
            return false;
          }
        }
        return true;
      },
    );
  }

  Future<List<Map<String, dynamic>>> _scanRecordsByPrimaryKeyRangeLogical({
    required TableContext table,
    required TableSchema schema,
    required String primaryKey,
    required MatcherFunction pkMatcher,
    required bool reverse,
    required int? limit,
    required bool Function(Map<String, dynamic>) recordPredicate,
    required Uint8List startKeyInclusive,
    required Uint8List endKeyExclusive,
    dynamic rangeMin,
    dynamic rangeMax,
    bool includeMin = true,
    bool includeMax = true,
    String? cursorPk,
    bool decodeRecord = true,
    TableSchema? decodeSchema,
    List<FieldStructure>? decodeFieldStructureOverride,
    bool readFromFileOnly = false,
  }) async {
    final rangeMgr = _dataStore.tableTreePartitionManager;
    if (rangeMgr == null) {
      return [];
    }
    final isMemoryMode =
        _dataStore.config.persistenceMode == PersistenceMode.memory;

    if (!isMemoryMode) {
      return rangeMgr.scanRecordsByPrimaryKeyRange(
        table: table,
        startKeyInclusive: startKeyInclusive,
        endKeyExclusive: endKeyExclusive,
        reverse: reverse,
        limit: limit,
        recordPredicate: recordPredicate,
        decodeSchema: decodeSchema,
        decodeFieldStructureOverride: decodeFieldStructureOverride,
        readFromFileOnly: readFromFileOnly,
      );
    }

    _registerTableComparator(table, schema);

    final out = <Map<String, dynamic>>[];
    await _forEachRecordByPrimaryKeyRangeLogical(
      table: table,
      schema: schema,
      primaryKey: primaryKey,
      pkMatcher: pkMatcher,
      reverse: reverse,
      limit: limit,
      recordPredicate: recordPredicate,
      startKeyInclusive: startKeyInclusive,
      endKeyExclusive: endKeyExclusive,
      rangeMin: rangeMin,
      rangeMax: rangeMax,
      includeMin: includeMin,
      includeMax: includeMax,
      cursorPk: cursorPk,
      decodeRecord: decodeRecord,
      decodeSchema: decodeSchema,
      decodeFieldStructureOverride: decodeFieldStructureOverride,
      readFromFileOnly: readFromFileOnly,
      onRecord: (r) {
        out.add(r);
        return true;
      },
    );
    return out;
  }

  Future<TableScanResult> searchTableData(
    TableContext table,
    ConditionRecordMatcher? matcher, {
    int? limit,
    int? offset,
    List<String>? orderBy,
    String? startAfterPrimaryKey,
    bool Function(Map<String, dynamic>)? filter,
    bool onlyCount = false,
    List<QueryAggregation>? aggregations,
    List<String>? groupBy,
    bool readFromFileOnly = false,
    TableSchema? decodeSchema,
    List<FieldStructure>? decodeFieldStructureOverride,
  }) async {
    // Increment table access weight for caching optimization
    _dataStore.weightManager?.incrementAccess(
      WeightType.tableRecord,
      table.tableUid,
      spaceName: _dataStore.currentSpaceName,
    );
    final schema = decodeSchema ?? table.schema;
    final primaryKey = schema.primaryKey;
    final pkMatcher =
        ValueMatcher.getMatcher(schema.getPrimaryKeyMatcherType());

    final bufferMgr = _dataStore.writeBufferManager;
    final tableContext = table;

    bool recordMatches(Map<String, dynamic> r) {
      // Defensive: always treat deleted/tombstone as non-visible.
      if (isDeletedRecord(r)) return false;

      // Check Real-time WriteBuffer to filter out pending deletes.
      // This prevents "page gaps" where disk records are counted towards limit
      // but later removed during mergeConsistency.
      Map<String, dynamic> evalRecord = r;
      if (!readFromFileOnly) {
        final pk = r[primaryKey]?.toString();
        if (pk != null) {
          if (onlyCount) {
            // Skip if in buffer for onlyCount fast path to avoid double counting
            if (bufferMgr.getBufferedRecordForRead(tableContext, pk) != null) {
              return false;
            }
          } else {
            final be = bufferMgr.getBufferedRecordForRead(tableContext, pk);
            if (be != null) {
              if (be.operation == BufferOperationType.delete) {
                return false;
              }
              evalRecord = be.data;
            }
          }
        }
      }

      if (filter != null && !filter(evalRecord)) return false;
      if (matcher != null && !matcher.matches(evalRecord)) return false;
      return true;
    }

    // Assign to local val so that it satisfies function pointer constraints
    final bool Function(Map<String, dynamic>) recordPredicate = recordMatches;

    // Parse Sort Order first as it is needed by fast paths
    bool isPkOrder = true;
    bool reverse = false;
    List<String> sortFields = [];
    List<bool> sortDirections = [];

    if (orderBy != null && orderBy.isNotEmpty) {
      if (orderBy.length == 1) {
        String f = orderBy[0];
        bool isDesc = false;
        if (f.startsWith('-')) {
          f = f.substring(1);
          isDesc = true;
        } else if (f.toUpperCase().endsWith(' DESC')) {
          f = f.substring(0, f.length - 5).trim();
          isDesc = true;
        } else if (f.toUpperCase().endsWith(' ASC')) {
          f = f.substring(0, f.length - 4).trim();
        }
        if (f == primaryKey) {
          isPkOrder = true;
          reverse = isDesc;
        } else {
          isPkOrder = false;
          sortFields.add(f);
          sortDirections.add(!isDesc);
        }
      } else {
        isPkOrder = false;
        for (final raw in orderBy) {
          String f = raw;
          bool asc = true;
          if (f.startsWith('-')) {
            f = f.substring(1);
            asc = false;
          }
          sortFields.add(f);
          sortDirections.add(asc);
        }
      }
    }

    // Extract PK Equality/IN values from matcher
    dynamic pkEqValue;
    List<dynamic>? pkInValues;

    if (matcher != null) {
      // Try to optimize by primary key
      final pks = matcher.getPrimaryKeys(primaryKey);
      if (pks != null && pks.isNotEmpty) {
        if (pks.length == 1) {
          pkEqValue = pks.first;
        } else {
          pkInValues = pks.toList();
        }
      }
    }

    // Fast path: PK '=' / IN (batch point lookup).
    if (pkEqValue != null || pkInValues != null) {
      final keys =
          pkEqValue != null ? [pkEqValue] : pkInValues!.toSet().toList();
      if (keys.isEmpty) {
        return TableScanResult(records: [], count: onlyCount ? 0 : null);
      }

      final batchRes = await queryRecordsBatch(
        table,
        keys,
        readFromFileOnly: readFromFileOnly,
        decodeSchema: decodeSchema,
        decodeFieldStructureOverride: decodeFieldStructureOverride,
      );
      final recs = batchRes.records;

      if (onlyCount) {
        int filteredCount = 0;
        for (final r in recs) {
          if (recordMatches(r)) {
            filteredCount++;
          }
        }
        int finalCount = filteredCount;
        if (offset != null && offset > 0) {
          finalCount = max(0, finalCount - offset);
        }
        if (limit != null && finalCount > limit) {
          finalCount = limit;
        }
        return TableScanResult(
          records: const [],
          count: finalCount,
        );
      }

      final filtered = <Map<String, dynamic>>[];
      for (final r in recs) {
        if (recordMatches(r)) {
          filtered.add(r);
        }
      }

      // If caller expects PK ordering (default), we might need to stabilize ordering
      if (isPkOrder && filtered.length > 1) {
        filtered.sort((a, b) {
          final ka = a[primaryKey];
          final kb = b[primaryKey];
          final cmp = pkMatcher(ka, kb);
          return reverse ? -cmp : cmp;
        });
      }

      // Apply Offset/Limit in memory
      if (offset != null && offset > 0) {
        if (offset >= filtered.length) {
          return TableScanResult(records: const []);
        }
        filtered.removeRange(0, offset);
      }
      if (limit != null && filtered.length > limit) {
        filtered.removeRange(limit, filtered.length);
      }

      if (aggregations != null && aggregations.isNotEmpty) {
        return TableScanResult(
          records: const [],
          aggregateResult: await calculateAggregateResultBatch(
            filtered,
            aggregations,
            groupBy: groupBy,
          ),
        );
      }

      return TableScanResult(
        records: filtered,
      );
    }

    final bool isMemoryMode =
        _dataStore.config.persistenceMode == PersistenceMode.memory;

    TableDataMeta? fileMeta;
    if (!isMemoryMode) {
      fileMeta = await getTableDataMeta(table.tableUid);
      if (fileMeta == null || fileMeta.totalRecordCount <= 0) {
        return TableScanResult(
          records: const [],
          count: onlyCount ? 0 : null,
        );
      }
    }

    int effectiveOffset = offset ?? 0;
    if (effectiveOffset < 0) effectiveOffset = 0;
    int? effectiveLimit = limit;
    if (limit != null && limit <= 0) effectiveLimit = null;
    int needCount =
        (effectiveLimit == null) ? -1 : (effectiveOffset + effectiveLimit);

    Uint8List upperExclusiveAfterKey(Uint8List key) {
      // [Type=0xFF][Len=0] sentinel component appended to make an exclusive upper bound.
      final out = Uint8List(key.length + 1 + 4);
      out.setRange(0, key.length, key);
      out[key.length] = 0xFF;
      return out;
    }

    bool containsOr(Map<String, dynamic>? node) {
      if (node == null) return false;
      if (node.containsKey('OR')) return true;
      final andVal = node['AND'];
      if (andVal is List) {
        for (final c in andVal) {
          if (c is Map<String, dynamic> && containsOr(c)) return true;
        }
      }
      // Also detect nested OR in any child maps.
      for (final e in node.entries) {
        final v = e.value;
        if (v is Map<String, dynamic>) {
          if (containsOr(v)) return true;
        } else if (v is List) {
          for (final it in v) {
            if (it is Map<String, dynamic> && containsOr(it)) return true;
          }
        }
      }
      return false;
    }

    /// Collect primary key constraints from an AND-only condition tree.
    ///
    /// Returns a merged operator map like:
    /// - {'=': 10}
    /// - {'`>=`': 1, '`<=`': 9}
    /// - {'IN': [..]}
    /// - {'BETWEEN': {'start': 1, 'end': 9}}
    ///
    /// Returns null when no PK constraint exists.

    Map<String, dynamic>? collectPrimaryKeyConditionMap(
        Map<String, dynamic>? node) {
      if (node == null) return null;
      if (containsOr(node)) return null;
      final out = <String, dynamic>{};

      void visit(Map<String, dynamic> m) {
        final andVal = m['AND'];
        if (andVal is List) {
          for (final c in andVal) {
            if (c is Map<String, dynamic>) visit(c);
          }
          return;
        }
        if (m.containsKey(primaryKey)) {
          final v = m[primaryKey];
          if (v is Map) {
            for (final e in v.entries) {
              out[e.key.toString()] = e.value;
            }
          } else {
            out['='] = v;
          }
        }
      }

      visit(node);
      return out.isEmpty ? null : out;
    }

    // Extract primary key condition for partition pruning (only when there is NO OR in the tree).
    final where = matcher?.condition.build();
    final bool hasOr = containsOr(where);
    final Map<String, dynamic>? pkCond =
        hasOr ? null : collectPrimaryKeyConditionMap(where);

    dynamic rangeMin;
    dynamic rangeMax;
    bool includeMin = true;
    bool includeMax = true;
    bool pkCondIsIndexableRange = false;

    if (pkCond != null) {
      // Range operators.
      if (pkCond.containsKey('>')) {
        rangeMin = pkCond['>'];
        includeMin = false;
      } else if (pkCond.containsKey('>=')) {
        rangeMin = pkCond['>='];
        includeMin = true;
      }
      if (pkCond.containsKey('<')) {
        rangeMax = pkCond['<'];
        includeMax = false;
      } else if (pkCond.containsKey('<=')) {
        rangeMax = pkCond['<='];
        includeMax = true;
      }
      if (pkCond.containsKey('BETWEEN') && pkCond['BETWEEN'] is Map) {
        final between = pkCond['BETWEEN'] as Map;
        rangeMin = between['start'];
        rangeMax = between['end'];
        includeMin = true;
        includeMax = true;
      }
      pkCondIsIndexableRange = (rangeMin != null || rangeMax != null);
    }

    // Build PK byte-range for partition scans (empty bounds => full scan).
    Uint8List startKeyBytes = Uint8List(0);
    Uint8List endKeyBytes = Uint8List(0);
    if (pkCondIsIndexableRange) {
      if (rangeMin != null) {
        final b = schema.encodePrimaryKeyComponent(rangeMin.toString());
        startKeyBytes = includeMin ? b : upperExclusiveAfterKey(b);
      }
      if (rangeMax != null) {
        final b = schema.encodePrimaryKeyComponent(rangeMax.toString());
        endKeyBytes = includeMax ? upperExclusiveAfterKey(b) : b;
      }
    }

    // Cursor pagination (keyset) for PK-ordered scans.
    final cursorPk = (startAfterPrimaryKey ?? '').trim();
    if (cursorPk.isNotEmpty && isPkOrder) {
      // Cursor and offset are mutually exclusive; cursor takes precedence here.
      effectiveOffset = 0;
      needCount =
          (effectiveLimit == null) ? -1 : (effectiveOffset + effectiveLimit);

      final cursorKey = schema.encodePrimaryKeyComponent(cursorPk);
      if (!reverse) {
        // ASC: start after cursor => startKeyInclusive = cursorKeyExclusive
        final cursorExclusive = upperExclusiveAfterKey(cursorKey);
        if (startKeyBytes.isEmpty ||
            MemComparableKey.compare(startKeyBytes, cursorExclusive) < 0) {
          startKeyBytes = cursorExclusive;
        }
      } else {
        // DESC: continue with keys < cursor => endKeyExclusive = min(endKeyExclusive, cursorKey)
        if (endKeyBytes.isEmpty ||
            MemComparableKey.compare(endKeyBytes, cursorKey) > 0) {
          endKeyBytes = cursorKey;
        }
      }
    }

    // Empty range after applying cursor/range filters.
    if (endKeyBytes.isNotEmpty &&
        startKeyBytes.isNotEmpty &&
        MemComparableKey.compare(startKeyBytes, endKeyBytes) >= 0) {
      return TableScanResult(records: [], count: onlyCount ? 0 : null);
    }

    // PK-ordered scan: can stop early at offset+limit.
    if (isPkOrder) {
      if (onlyCount) {
        int totalCount = 0;
        await _forEachRecordByPrimaryKeyRangeLogical(
          table: table,
          schema: schema,
          primaryKey: primaryKey,
          pkMatcher: pkMatcher,
          reverse: reverse,
          limit: (needCount < 0) ? null : needCount,
          recordPredicate: recordPredicate,
          startKeyInclusive: startKeyBytes,
          endKeyExclusive: endKeyBytes,
          rangeMin: rangeMin,
          rangeMax: rangeMax,
          includeMin: includeMin,
          includeMax: includeMax,
          cursorPk: cursorPk.isNotEmpty ? cursorPk : null,
          decodeRecord: (filter != null ||
              (matcher != null && matcher.fields.any((f) => f != primaryKey))),
          decodeSchema: decodeSchema,
          decodeFieldStructureOverride: decodeFieldStructureOverride,
          readFromFileOnly: readFromFileOnly,
          onRecord: (r) {
            totalCount++;
            return true;
          },
        );
        int finalCount = totalCount;
        if (offset != null && offset > 0) {
          finalCount = max(0, finalCount - offset);
        }
        return TableScanResult(records: const [], count: finalCount);
      } else if (aggregations != null && aggregations.isNotEmpty) {
        final agg = QueryAggregator(aggregations, groupBy: groupBy);
        await _forEachRecordByPrimaryKeyRangeLogical(
          table: table,
          schema: schema,
          primaryKey: primaryKey,
          pkMatcher: pkMatcher,
          reverse: reverse,
          limit: (needCount < 0) ? null : needCount,
          recordPredicate: recordPredicate,
          startKeyInclusive: startKeyBytes,
          endKeyExclusive: endKeyBytes,
          rangeMin: rangeMin,
          rangeMax: rangeMax,
          includeMin: includeMin,
          includeMax: includeMax,
          cursorPk: cursorPk.isNotEmpty ? cursorPk : null,
          decodeSchema: decodeSchema,
          decodeFieldStructureOverride: decodeFieldStructureOverride,
          readFromFileOnly: readFromFileOnly,
          onRecord: (r) {
            agg.accumulate(r);
            return true;
          },
        );
        return TableScanResult(records: const [], aggregateResult: agg.result);
      } else {
        final out = await _scanRecordsByPrimaryKeyRangeLogical(
          table: table,
          schema: schema,
          primaryKey: primaryKey,
          pkMatcher: pkMatcher,
          reverse: reverse,
          limit: (needCount < 0) ? null : needCount,
          recordPredicate: recordPredicate,
          startKeyInclusive: startKeyBytes,
          endKeyExclusive: endKeyBytes,
          rangeMin: rangeMin,
          rangeMax: rangeMax,
          includeMin: includeMin,
          includeMax: includeMax,
          cursorPk: cursorPk.isNotEmpty ? cursorPk : null,
          decodeSchema: decodeSchema,
          decodeFieldStructureOverride: decodeFieldStructureOverride,
          readFromFileOnly: readFromFileOnly,
        );
        return TableScanResult(
          records: out,
        );
      }
    }

    // Non-PK orderBy: must scan all target partitions, then do in-memory topK sort (bounded by offset+limit).
    // Pre-build matcher functions for orderBy fields (critical for topK performance).
    final orderMatchers = <MatcherFunction>[];
    final schemas = <String, TableSchema>{table.tableUid: schema};
    for (int i = 0; i < sortFields.length; i++) {
      final f = sortFields[i];
      final s =
          ConditionRecordMatcher.getSchemaForField(f, schemas, table.tableUid);
      final fieldName = f.contains('.') ? f.split('.').last : f;
      orderMatchers.add(
        ValueMatcher.getMatcher(
            s?.getFieldMatcherType(fieldName) ?? MatcherType.unsupported),
      );
    }

    int compareRecords(Map<String, dynamic> a, Map<String, dynamic> b) {
      for (int i = 0; i < sortFields.length; i++) {
        final f = sortFields[i];
        final asc = sortDirections[i];
        final matcherFn = orderMatchers[i];
        final va = ConditionRecordMatcher.getFieldValue(a, f);
        final vb = ConditionRecordMatcher.getFieldValue(b, f);
        final c = matcherFn(va, vb);
        if (c != 0) return asc ? c : -c;
      }
      // Stable tie-breaker: primary key ASC.
      final ka = a[primaryKey];
      final kb = b[primaryKey];
      return pkMatcher(ka, kb);
    }

    final out = <Map<String, dynamic>>[];
    if (needCount <= 0) {
      // No limit provided: fall back to full collection (may be large).
      out.addAll(await _scanRecordsByPrimaryKeyRangeLogical(
        table: table,
        schema: schema,
        primaryKey: primaryKey,
        pkMatcher: pkMatcher,
        reverse: false,
        limit: null,
        recordPredicate: recordPredicate,
        startKeyInclusive: startKeyBytes,
        endKeyExclusive: endKeyBytes,
        rangeMin: rangeMin,
        rangeMax: rangeMax,
        includeMin: includeMin,
        includeMax: includeMax,
        cursorPk: cursorPk.isNotEmpty ? cursorPk : null,
        decodeSchema: decodeSchema,
        decodeFieldStructureOverride: decodeFieldStructureOverride,
        readFromFileOnly: readFromFileOnly,
      ));
      // Note: Sorting is handled by the upper layer (QueryExecutor._applySort),
      // so we skip sorting here to avoid redundant operations and improve performance.
      // Only need to handle reverse partition scanning based on sort direction.
      if (onlyCount) {
        int finalCount = out.length;
        if (offset != null && offset > 0) {
          finalCount = max(0, finalCount - offset);
        }
        return TableScanResult(
          records: const [],
          count: finalCount,
        );
      }
      if (aggregations != null && aggregations.isNotEmpty) {
        return TableScanResult(
          records: const [],
          aggregateResult: await calculateAggregateResultBatch(
            out,
            aggregations,
            groupBy: groupBy,
          ),
        );
      }
      return TableScanResult(
        records: out,
      );
    }

    // Maintain a bounded global topK heap of size <= needCount.
    // For performance, compute a local topK per partition in parallel, then merge.
    final globalTop =
        TopKHeap<Map<String, dynamic>>(k: needCount, compare: compareRecords);

    WorkloadLease? lease;
    try {
      lease = await _dataStore.workloadScheduler.tryAcquire(
        WorkloadType.query,
        requestedTokens:
            _dataStore.workloadScheduler.capacityTokens(WorkloadType.query),
        minTokens: 1,
        label: 'TableDataManager.searchTableData.topK',
      );
      final int queryConcurrency = (lease?.asConcurrency(0.3) ?? 1);

      final tasks = <Future<List<Map<String, dynamic>>> Function()>[];
      // New global B+Tree: build a single task scanning the global leaf chain.
      tasks.add(() async {
        final localTop = TopKHeap<Map<String, dynamic>>(
            k: needCount, compare: compareRecords);
        await _forEachRecordByPrimaryKeyRangeLogical(
          table: table,
          schema: schema,
          primaryKey: primaryKey,
          pkMatcher: pkMatcher,
          reverse: false,
          limit: null,
          recordPredicate: recordPredicate,
          startKeyInclusive: startKeyBytes,
          endKeyExclusive: endKeyBytes,
          rangeMin: rangeMin,
          rangeMax: rangeMax,
          includeMin: includeMin,
          includeMax: includeMax,
          cursorPk: cursorPk.isNotEmpty ? cursorPk : null,
          decodeSchema: decodeSchema,
          decodeFieldStructureOverride: decodeFieldStructureOverride,
          readFromFileOnly: readFromFileOnly,
          onRecord: (r) {
            localTop.offer(r);
            return true;
          },
        );
        return localTop.toSortedList();
      });

      if (tasks.isEmpty) {
        return TableScanResult(records: [], count: onlyCount ? 0 : null);
      }

      final effectiveConcurrency = min(queryConcurrency, tasks.length);

      // Fast timeout estimation: Base 60s + (TotalMaxBytes / 2MB/s / concurrency)
      // Since tasks.length is 1 for global leaf chain scan, we must use btreePartitionCount to estimate total bytes.
      final partitionCount = fileMeta?.btreePartitionCount ?? 1;
      final estTotalBytes =
          partitionCount * _dataStore.config.maxPartitionFileSize * 1.5;
      final timeoutSeconds =
          60 + (estTotalBytes / (2097152 * effectiveConcurrency)).ceil();

      final locals =
          await ParallelProcessor.execute<List<Map<String, dynamic>>>(
        tasks,
        concurrency: effectiveConcurrency,
        label: 'TableDataManager.searchTableData.topK',
        timeout: Duration(seconds: timeoutSeconds),
      );

      // Merge local topK candidates into global topK heap.
      final yieldControllerMerge =
          YieldController('TableDataManager.searchTableData.merge');
      for (final local in locals) {
        final list = local ?? const <Map<String, dynamic>>[];
        for (final r in list) {
          final y23 = yieldControllerMerge.maybeYield();
          if (y23 != null) await y23;
          globalTop.offer(r);
        }
      }
    } finally {
      lease?.release();
    }

    final sortedList = globalTop.toSortedList();
    if (onlyCount) {
      int finalCount = sortedList.length;
      if (offset != null && offset > 0) {
        finalCount = max(0, finalCount - offset);
      }
      return TableScanResult(
        records: const [],
        count: finalCount,
      );
    }
    if (aggregations != null && aggregations.isNotEmpty) {
      return TableScanResult(
        records: const [],
        aggregateResult: await calculateAggregateResultBatch(
          sortedList,
          aggregations,
          groupBy: groupBy,
        ),
      );
    }
    return TableScanResult(
      records: sortedList,
    );
  }

  dynamic calculateAggregateResult(
      List<Map<String, dynamic>> records, List<QueryAggregation> aggregations,
      {List<String>? groupBy}) {
    final agg = QueryAggregator(aggregations, groupBy: groupBy);
    for (final r in records) {
      agg.accumulate(r);
    }
    return agg.result;
  }

  Future<dynamic> calculateAggregateResultBatch(
    List<Map<String, dynamic>> records,
    List<QueryAggregation> aggregations, {
    List<String>? groupBy,
  }) async {
    if (records.isEmpty || aggregations.isEmpty) {
      return calculateAggregateResult(records, aggregations, groupBy: groupBy);
    }

    final dispatchPlan = ComputeBatchPlanner.planTaskExecution(
      itemCount: records.length,
      estimateAverageItemBytes: () =>
          ComputeBatchPlanner.estimateAverageItemBytes(
        records,
        estimateRecordSizeBytes,
      ),
    );
    final useIsolate = dispatchPlan.useIsolate;
    final actualTaskCount = dispatchPlan.actualTaskCount;

    if (!useIsolate && actualTaskCount <= 1) {
      return calculateAggregateResult(records, aggregations, groupBy: groupBy);
    }

    final tasks =
        <ComputeTask<QueryAggregateChunkRequest, QueryAggregationPartial>>[];
    for (final range
        in ComputeBatchPlanner.splitRange(records.length, actualTaskCount)) {
      tasks.add(
        ComputeTask(
          function: aggregateQueryChunk,
          message: QueryAggregateChunkRequest(
            records: records.sublist(range.start, range.end),
            aggregations: aggregations,
            groupBy: groupBy,
          ),
        ),
      );
    }

    final partials =
        await ComputeManager.computeBatch(tasks, enableIsolate: useIsolate);
    final aggregator = QueryAggregator(aggregations, groupBy: groupBy);
    final mergeYield = YieldController(
      'TableDataManager.calculateAggregateResultBatch.merge',
    );
    for (final partial in partials) {
      final y24 = mergeYield.maybeYield();
      if (y24 != null) await y24;
      aggregator.mergePartial(partial);
    }
    return aggregator.result;
  }
}

/// Check if a record is a deleted record (marked with _deleted_:true flag)
bool isDeletedRecord(Map<String, dynamic> record) {
  // Check for explicit deletion marker (preferred method)
  if (record['_deleted_'] == true) {
    return true;
  }

  // For backward compatibility: empty object is also considered a deleted record
  return record.isEmpty;
}

/// Visible view of a transactional deferred record.
///
/// [TxnDeferredOp.oldValues] is stored separately; [data] is shared by
/// reference (same contract as buffer reads). Only copy when a legacy
/// embedded `_oldValues` key is present.
Map<String, dynamic> _visibleTxnRecord(Map<String, dynamic> src) {
  if (!src.containsKey('_oldValues')) return src;
  final out = Map<String, dynamic>.from(src);
  out.remove('_oldValues');
  return out;
}

class TxSnapshot {
  final Map<String, List<Map<String, dynamic>>> inserts;
  final Map<String, List<Map<String, dynamic>>> updates;
  final Map<String, List<Map<String, dynamic>>> deletes;
  TxSnapshot({
    required this.inserts,
    required this.updates,
    required this.deletes,
  });
}

/// Deferred operation structure for transactions
class TxnDeferredOp {
  final BufferOperationType type;
  final Map<String, dynamic> data;
  final List<UniqueKeyRef>? uniqueKeyRefs;
  final Map<String, dynamic>? oldValues;

  const TxnDeferredOp(this.type, this.data,
      {this.uniqueKeyRefs, this.oldValues});
}

class _TransactionResourceEstimate {
  int operationCount = 0;
  int sampleBytes = 0;
  int sampleCount = 0;
}

enum PartitionStreamAction {
  continueScan,
  stopAfterBatch,
  stopAfterPartition,
}

final class PartitionPageBatch {
  final int partitionNo;
  final List<Map<String, dynamic>> records;
  final bool isEmptyPartition;

  const PartitionPageBatch({
    required this.partitionNo,
    required this.records,
    this.isEmptyPartition = false,
  });
}

final class TableWriteLock {
  final TableUid tableUid;
  final String tableName;
  final String resource;
  final String operationId;
  bool _released = false;

  TableWriteLock._({
    required this.tableUid,
    required this.tableName,
    required this.resource,
    required this.operationId,
  });

  bool get isReleased => _released;

  void markReleased() {
    _released = true;
  }

  void validateBorrowedFor(
    TableUid expectedTableUid, {
    String? expectedTableName,
  }) {
    if (_released) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'Table write lock already released: $tableName',
        ),
      ]);
    }
    if (tableUid != expectedTableUid) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Table write lock mismatch: expected ${expectedTableName ?? 'unknown'}, got $tableName',
        ),
      ]);
    }
  }
}
