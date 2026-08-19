import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../handler/binary_schema_codec.dart';
import '../handler/logger.dart';
import '../handler/memcomparable.dart';
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
import '../model/wal_pointer.dart';
import '../query/query_executor.dart';
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
  // Txn deferred ops live in WriteBufferManager.bufferTrees (txn TreeCaches).
  // This set is an O(1) presence index for:
  // - hasDeferredOps / getDeferredOps early-out
  // - query merge / count overlays (skip txn scan when current tx has no ops)
  // - selective TTL cleanup of *inactive* txIds (must not wipe active txns)
  // Bulk teardown (dispose) should clear txn TreeCaches as a whole -- do not
  // iterate this set for prefix-removes.
  final Set<String> _txnIdsWithOps = <String>{};

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
  // SpaceStats (InternalKv `stats.space.v1`) -- owned entirely here.
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
  int _baselineIndexEntryCount = 0;
  int _deltaRecordCount = 0;
  int _deltaTableDataSizeBytes = 0;
  int _deltaIndexDataSizeBytes = 0;
  int _deltaIndexEntryCount = 0;
  DateTime? _lastStatisticsTime;
  bool _spaceStatsHydrated = false;
  Future<void>? _spaceStatsHydrateFuture;

  /// Space-wide averages: refreshed on SpaceStats hydrate / persist only.
  int? _cachedAvgTableRecordSizeBytes;
  int? _cachedAvgIndexEntrySizeBytes;

  /// Last flush averages: O(1) overwrite when a flush reports net growth.
  /// Prefer these over space-wide for resolve paths (recent shape wins).
  int? _lastFlushAvgTableRecordSizeBytes;
  int? _lastFlushAvgIndexEntrySizeBytes;

  /// Upgrade: old KV lacked [SpaceStats.totalIndexEntryCount] while index bytes
  /// were already tracked -- force one full reconcile to seed the denominator.
  bool _indexEntryBaselinePending = false;

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
  Comparator<dynamic> _tableRecordComparatorFactory(
    List<dynamic> path, {
    int suffixIndex = 0,
  }) {
    if (suffixIndex > 0) return TreeCache.compareNative;
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

    final bool isMemoryMode =
        _dataStore.config.persistenceMode == PersistenceMode.memory;
    final int tableQuota =
        mem?.getTableDataCacheSize() ?? (128 * 1024 * 1024); // Default 128MB
    // Reserve a portion for range-partition caches (blocks + sparse index).
    final int maxBytes = max(1, (tableQuota * 0.55).toInt());
    // Memory mode: TableRecordCache is the primary row store (no disk tier).
    // Disable quota eviction to avoid silent data loss under memory pressure.
    _tableRecordCache = TreeCache<Map<String, dynamic>>(
      sizeCalculator: resolveRecordSizeBytes,
      maxByteThreshold: isMemoryMode ? 1 : maxBytes,
      minByteThreshold: isMemoryMode ? 1 : 50 * 1024 * 1024,
      comparatorFactory: _tableRecordComparatorFactory,
      weightQueryCallback: isMemoryMode ? null : _queryTableRecordWeight,
      evictionMode:
          isMemoryMode ? TreeCacheEvictionMode.none : TreeCacheEvictionMode.lru,
      debugLabel: 'TableRecordCache',
    );

    // Initialize auto-increment ID generator and set periodic check task
    CrontabManager.addCallback(
        ExecuteInterval.seconds3, TimeBasedIdGenerator.periodicPoolCheck);
    // SpaceStats -> InternalKv off the journal/close hot path (best-effort).
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
  /// the result in place -- treat it as read-only or copy before writing.
  Map<String, dynamic>? getCachedTableRecord(TableContext table, String pk) {
    return _tableRecordCache.get([table.tableUid, pk]);
  }

  /// Check if a record exists in the table record cache (O(1) fast check).
  /// Note: This returns true even for tombstones (deleted records) if they are in the cache.
  bool hasTableRecord(TableContext table, String pk) {
    return _tableRecordCache.containsKey([table.tableUid, pk]);
  }

  /// Check if a record exists in the table record cache.
  ///
  /// Deletes live in the write buffer as [BufferOperationType.delete], not as
  /// cached tombstone rows -- presence here means a live cached row.
  bool hasLiveTableRecord(TableContext table, String pk) {
    return _tableRecordCache.containsKey([table.tableUid, pk]);
  }

  /// Returns true when the record is hidden by a pending/txn **delete** overlay,
  /// even if the physical row still exists on disk (pre-flush).
  ///
  /// Only for PK-existence / delete visibility. Index key validity under
  /// updates belongs in IndexManager (`_isFileIndexHitStaleUnderOverlay` /
  /// `_uniqueDiskOwnerStillOwnsKey`), not here.
  bool isRecordHiddenByDeleteOverlay(TableContext table, String pk,
      {String? transactionId}) {
    final tableUid = table.tableUid;
    final currentTxId =
        transactionId ?? TransactionContext.getCurrentTransactionId();

    if (currentTxId != null) {
      final txOp = _dataStore.writeBufferManager.bufferTrees
          .getTxnRecord(currentTxId, tableUid, pk);
      if (txOp != null) {
        return txOp.operation == BufferOperationType.delete;
      }
    }

    final bufferEntry =
        _dataStore.writeBufferManager.getBufferedRecord(table, pk);
    if (bufferEntry == null) {
      return false;
    }

    return bufferEntry.operation == BufferOperationType.delete;
  }

  /// Cache a single table record
  void cacheTableRecord(TableContext table, String pk,
      Map<String, dynamic> record, TableSchema schema,
      {bool force = false}) {
    final tableUid = table.tableUid;
    if (_tableRecordCache.maxByteThreshold <= 0) {
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
        size: resolveRecordSizeBytes(record),
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

      final key = [tableUid, pk];

      // If not forced/prewarming, we only update if it's already there
      if (doNotCache) {
        if (!_tableRecordCache.containsKey(key)) continue;
      }

      final value = r;
      _tableRecordCache.put(key, value, size: resolveRecordSizeBytes(value));
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

        // Only cache if the record is NOT superseded by a live write-buffer entry.
        // Caching disk rows while pending insert/update exists pollutes the
        // read-through cache with stale values under concurrent flush.
        final bufferEntry =
            _dataStore.writeBufferManager.getBufferedRecordForRead(
          table,
          pk,
        );
        if (bufferEntry != null) {
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
    if (_dataStore.config.persistenceMode == PersistenceMode.memory) {
      return;
    }
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
  int get _effectiveIndexEntryCount =>
      max(0, _baselineIndexEntryCount + _deltaIndexEntryCount);

  /// Resolved table-record average (O(1)): last flush, else space-wide.
  int? get averageTableRecordSizeBytes =>
      _lastFlushAvgTableRecordSizeBytes ?? _cachedAvgTableRecordSizeBytes;

  /// Resolved index-entry average (O(1)): last flush, else space-wide.
  int? get averageIndexEntrySizeBytes =>
      _lastFlushAvgIndexEntrySizeBytes ?? _cachedAvgIndexEntrySizeBytes;

  /// Approximate bytes of all index entries attributable to one record.
  ///
  /// Uses space-wide `totalIndexDataSizeBytes / totalRecordCount` when warm.
  int? get estimateIndexBytesPerRecord {
    final rc = _effectiveRecordCount;
    if (rc <= 0) return null;
    final bytes = _effectiveIndexDataSizeBytes;
    if (bytes <= 0) return null;
    return bytes ~/ rc;
  }

  SpaceStats _spaceStatsSnapshot() => SpaceStats(
        totalRecordCount: _effectiveRecordCount,
        totalTableDataSizeBytes: _effectiveTableDataSizeBytes,
        totalIndexDataSizeBytes: _effectiveIndexDataSizeBytes,
        totalIndexEntryCount: _effectiveIndexEntryCount,
        lastStatisticsTime: _lastStatisticsTime,
      );

  /// Refresh memory-cached averages from effective counters.
  ///
  /// Call sites are intentionally narrow:
  /// - KV hydrate (cold start, before first dirty persist)
  /// - [_persistSpaceStatsToKv] (30s cadence / recalculate persist)
  void _refreshCachedAveragesFromEffective() {
    final rc = _effectiveRecordCount;
    _cachedAvgTableRecordSizeBytes =
        rc <= 0 ? null : _effectiveTableDataSizeBytes ~/ rc;
    final iec = _effectiveIndexEntryCount;
    _cachedAvgIndexEntrySizeBytes =
        iec <= 0 ? null : _effectiveIndexDataSizeBytes ~/ iec;
  }

  /// Prefer last-flush / space-wide average (O(1)); else per-record estimate.
  ///
  /// Used by TreeCache quota and isolate-dispatch heuristics. Disk average is
  /// not exact Dart-heap size -- acceptable for scheduling / eviction only.
  int resolveRecordSizeBytes(Map<String, dynamic> record) {
    final avg = averageTableRecordSizeBytes;
    if (avg != null && avg > 0) return avg;
    return estimateRecordSizeBytes(record);
  }

  /// O(1) resolved average when warm; otherwise sample [records].
  int estimateAverageRecordBytesForBatch(
    List<Map<String, dynamic>> records,
  ) {
    final avg = averageTableRecordSizeBytes;
    if (avg != null && avg > 0) return avg;
    return ComputeBatchPlanner.estimateAverageItemBytes(
      records,
      estimateRecordSizeBytes,
    );
  }

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
  /// close/switchSpace never blocks on InternalKv -> tableMeta.
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
  /// Only runs while the engine is fully open -- never during close/re-init.
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
        _baselineIndexEntryCount = stats.totalIndexEntryCount;
        _lastStatisticsTime = stats.lastStatisticsTime;
        _spaceStatsHydrated = true;
        if (stats.totalIndexEntryCount == 0 &&
            stats.totalIndexDataSizeBytes > 0) {
          _indexEntryBaselinePending = true;
        }
        _refreshCachedAveragesFromEffective();
      }
    } on DbClosedException {
      _spaceStatsHydrateFuture = null;
    } catch (e) {
      _spaceStatsHydrateFuture = null;
      if (_isSpaceStatsWorkAborted || e is DbClosedException) {
        // close / switchSpace race -- silent.
      } else {
        Logger.warn('Failed to hydrate space stats from InternalKv',
            rawError: e);
        if (_dataStore.isInitialized && !_dataStore.isClosing) {
          // Empty baseline; averages stay null until first persist refresh.
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
      _indexEntryBaselinePending = false;
      return;
    }

    // One-shot: KV from before totalIndexEntryCount existed.
    if (_indexEntryBaselinePending) {
      await recalculateAllStatistics();
      _indexEntryBaselinePending = false;
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
    _baselineIndexEntryCount = _effectiveIndexEntryCount;
    _deltaRecordCount = 0;
    _deltaTableDataSizeBytes = 0;
    _deltaIndexDataSizeBytes = 0;
    _deltaIndexEntryCount = 0;
  }

  /// Space aggregate stats cover user tables only -- never system/internal KV.
  /// Prefer [TableSchema.isSystemTable] (O(1)); name-set lookup is unnecessary
  /// on the per-record hot path when contexts carry a correct schema flag.
  bool _contributesToSpaceStats(TableContext table) =>
      !table.schema.isSystemTable;

  void _markSpaceStatsDirty(TableContext table) {
    if (!_contributesToSpaceStats(table)) return;
    _needSaveStats = true;
  }

  /// O(1) table-data flush occupancy: SpaceStats size delta + last-flush avg.
  ///
  /// Last-flush average updates only on net growth
  /// ([recordDelta] > 0 and [sizeDelta] > 0).
  void applyTableOccupancyDelta(
    TableContext table, {
    int sizeDelta = 0,
    int recordDelta = 0,
  }) {
    if (!_contributesToSpaceStats(table)) return;
    if (sizeDelta == 0 && recordDelta == 0) return;
    if (sizeDelta != 0) {
      _deltaTableDataSizeBytes += sizeDelta;
      _needSaveStats = true;
    }
    if (recordDelta > 0 && sizeDelta > 0) {
      final sampleAvg = sizeDelta ~/ recordDelta;
      _lastFlushAvgTableRecordSizeBytes = sampleAvg;
      _dataStore.parallelJournalManager.recordFlushRecordSizeSample(sampleAvg);
    }
  }

  /// O(1) incremental adjust for persisted index occupancy
  /// (file size bytes + B+Tree `totalEntryCount` / NGH `totalVectors`).
  ///
  /// Also refreshes last-flush index-entry average on net growth.
  void applyIndexOccupancyDelta(
    TableContext table, {
    int sizeDelta = 0,
    int entryDelta = 0,
  }) {
    if (!_contributesToSpaceStats(table)) return;
    if (sizeDelta == 0 && entryDelta == 0) return;
    if (sizeDelta != 0) _deltaIndexDataSizeBytes += sizeDelta;
    if (entryDelta != 0) _deltaIndexEntryCount += entryDelta;
    if (entryDelta > 0 && sizeDelta > 0) {
      _lastFlushAvgIndexEntrySizeBytes = sizeDelta ~/ entryDelta;
    }
    _needSaveStats = true;
  }

  /// Sum index file sizes for one table (B+Tree + vector/NGH).
  Future<int> sumTableIndexDataSizeBytes(TableContext table) async {
    final totals = await _sumTableIndexOccupancy(table);
    return totals.sizeBytes;
  }

  /// Sum index entry counts for one table (B+Tree entries + NGH vectors).
  Future<int> sumTableIndexEntryCount(TableContext table) async {
    final totals = await _sumTableIndexOccupancy(table);
    return totals.entryCount;
  }

  Future<({int sizeBytes, int entryCount})> _sumTableIndexOccupancy(
      TableContext table) async {
    final indexManager = _dataStore.indexManager;
    final schemaMgr = _dataStore.tableMetaManager;
    if (indexManager == null || schemaMgr == null) {
      return (sizeBytes: 0, entryCount: 0);
    }

    var sizeBytes = 0;
    var entryCount = 0;
    final yieldController = YieldController(
        'TableDataManager._sumTableIndexOccupancy',
        checkInterval: 2);
    for (final index in schemaMgr.getBtreeIndexesFor(table.schema)) {
      final meta =
          await indexManager.getIndexMeta(table.tableUid, index.indexUid);
      if (meta != null) {
        sizeBytes += meta.totalSizeBytes;
        entryCount += meta.totalEntryCount;
      }
      final y = yieldController.maybeYield();
      if (y != null) await y;
    }
    final vectorMgr = _dataStore.vectorIndexManager;
    if (vectorMgr != null) {
      for (final index in schemaMgr.getVectorIndexesFor(table.schema)) {
        final ngh = await vectorMgr.getNghIndexMeta(table, index.indexUid);
        if (ngh != null) {
          sizeBytes += ngh.totalSizeBytes;
          entryCount += ngh.totalVectors;
        }
        final y = yieldController.maybeYield();
        if (y != null) await y;
      }
    }
    return (sizeBytes: sizeBytes, entryCount: entryCount);
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
      int totalIndexEntryCount = 0;

      final yieldController =
          YieldController('TableDataManager.recalculateAllStatistics');
      for (final name in tableNames) {
        if (_isSpaceStatsWorkAborted) break;
        final y2 = yieldController.maybeYield();
        if (y2 != null) await y2;

        final uid = await tableMetaManager.getUidByName(TableName(name));
        if (_isSpaceStatsWorkAborted || uid == null) continue;
        final ctx = await tableMetaManager.getTableContext(uid);
        if (ctx == null) continue;
        final meta = await getTableDataMeta(ctx.tableUid);
        final indexOcc = await _sumTableIndexOccupancy(ctx);
        if (meta != null) {
          totalRecordCount += meta.totalRecordCount;
          totalTableDataSize += meta.totalSizeBytes;
        }
        totalIndexDataSize += indexOcc.sizeBytes;
        totalIndexEntryCount += indexOcc.entryCount;
      }

      if (_isSpaceStatsWorkAborted) return;

      _baselineRecordCount = totalRecordCount;
      _baselineTableDataSizeBytes = totalTableDataSize;
      _baselineIndexDataSizeBytes = totalIndexDataSize;
      _baselineIndexEntryCount = totalIndexEntryCount;
      _deltaRecordCount = 0;
      _deltaTableDataSizeBytes = 0;
      _deltaIndexDataSizeBytes = 0;
      _deltaIndexEntryCount = 0;
      _spaceStatsHydrated = true;
      // Stamp only on full reconcile (index baseline included, may be 0).
      _lastStatisticsTime = DateTime.now();

      // Averages refresh inside persist (single owner) -- do not refresh here.
      await _persistSpaceStatsToKv();

      Logger.debug(
          'Table statistics calculation completed: record count=$totalRecordCount, table data=${totalTableDataSize / 1024 / 1024}MB, index data=${totalIndexDataSize / 1024 / 1024}MB, index entries=$totalIndexEntryCount');
    } on DbClosedException {
      // close / switchSpace race -- best-effort, no log.
    } catch (e) {
      if (_isSpaceStatsWorkAborted || e is DbClosedException) return;
      Logger.error('Failed to calculate table statistics', rawError: e);
    }
  }

  Future<void> _persistSpaceStatsToKv() async {
    if (!_canPersistSpaceStatsKv) {
      return;
    }
    if (_persistingSpaceStats) return;
    _persistingSpaceStats = true;
    try {
      await ensureSpaceStatsHydrated();
      if (!_canPersistSpaceStatsKv) return;
      // Refresh averages on the persist cadence (also for memory mode).
      _refreshCachedAveragesFromEffective();
      if (_dataStore.config.persistenceMode == PersistenceMode.memory) {
        _foldSpaceStatsDeltaIntoBaseline();
        _needSaveStats = false;
        return;
      }
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
      // Shutdown race -- stats are best-effort.
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
        // SpaceStats intentionally skipped -- close/switchSpace must not block
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
      _dataStore.writeBufferManager.clearAllTransactionBuffers();
      _txnIdsWithOps.clear();
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
      _baselineIndexEntryCount = 0;
      _deltaRecordCount = 0;
      _deltaTableDataSizeBytes = 0;
      _deltaIndexDataSizeBytes = 0;
      _deltaIndexEntryCount = 0;
      _cachedAvgTableRecordSizeBytes = null;
      _cachedAvgIndexEntrySizeBytes = null;
      _lastFlushAvgTableRecordSizeBytes = null;
      _lastFlushAvgIndexEntrySizeBytes = null;
      _indexEntryBaselinePending = false;
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
      final finalData = Map<String, dynamic>.from(data);
      final entry = BufferEntry(
        data: finalData,
        operation: operationType,
        timestamp: DateTime.now(),
        walPointer: null,
        transactionId: currentTxId,
        oldValues: oldValues,
        schemaVersion: schemaVersion,
      );

      // PK overlay + txn index trees (merge/cancel handled inside applyRecord).
      // Unique reservation is expected at call sites before addToBuffer.
      _dataStore.writeBufferManager.applyTxnRecord(
        transactionId: currentTxId,
        table: table,
        recordId: recordId,
        entry: entry,
      );

      _trackTransactionBufferBatch(
        currentTxId,
        [finalData],
        oldValues != null ? {recordId: oldValues} : null,
        primaryKey,
      );
      _txnIdsWithOps.add(currentTxId);
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

    // 1. Transaction Path: Defer operations into txn TreeCaches until commit
    if (currentTxId != null && !applyingCommit) {
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

            final oldR = oldRecordsMap != null ? oldRecordsMap[recordId] : null;

            try {
              final entry = BufferEntry(
                data: Map<String, dynamic>.from(r),
                operation: operation,
                timestamp: ts,
                walPointer: null,
                transactionId: currentTxId,
                oldValues: oldR,
                schemaVersion: schemaVersion,
              );
              // Unique reservation is expected at call sites before addBatchToBuffer.
              _dataStore.writeBufferManager.applyTxnRecord(
                transactionId: currentTxId,
                table: table,
                recordId: recordId,
                entry: entry,
              );
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
      if (successIds.isNotEmpty) {
        _txnIdsWithOps.add(currentTxId);
      }
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
              // Drop reserve bookkeeping; unique leaves stay as memory locks.
              _dataStore.writeBufferManager.commitReservedUniques(
                table: table,
                recordId: recordId,
                transactionId: currentTxId,
              );
              successIds.add(recordId);
            } catch (e) {
              Logger.warn(
                  'Memory batch op failed: ${table.tableName} pk=$recordId',
                  rawError: e);
              _dataStore.writeBufferManager.releaseReservedUniques(
                table: table,
                recordId: recordId,
                transactionId: currentTxId,
              );
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

    // Persistent / applying-commit: never write txn trees here.
    // Commit apply must land in pending (tx overlays are cleared after commit).
    final String? bufferTxId = applyingCommit ? null : currentTxId;

    final recordIds = <String>[];
    final entries = <BufferEntry>[];

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
            transactionId: bufferTxId,
            walPointer: pointers[i],
            oldValues: oldR,
            schemaVersion: schemaVersion,
          ));
          recordIds.add(recordId);

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
        installAllIndexes: applyingCommit,
      );
    } else if (operation == BufferOperationType.update) {
      await _dataStore.writeBufferManager.addUpdateBatch(
        table: table,
        recordIds: recordIds,
        entries: entries,
        installAllIndexes: applyingCommit,
      );
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
          estimateAverageRecordBytesForBatch(records),
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

  /// get total index entry count (B+Tree entries + NGH vectors)
  int getTotalIndexEntryCount() {
    return _effectiveIndexEntryCount;
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
      final indexOcc = await _sumTableIndexOccupancy(table);
      if (indexOcc.sizeBytes != 0) {
        _deltaIndexDataSizeBytes -= indexOcc.sizeBytes;
      }
      if (indexOcc.entryCount != 0) {
        _deltaIndexEntryCount -= indexOcc.entryCount;
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
    if (txId != null &&
        !TransactionContext.isApplyingCommit() &&
        _txnIdsWithOps.contains(txId)) {
      try {
        var inserted = 0;
        var deleted = 0;
        await _dataStore.writeBufferManager.bufferTrees.forEachTxnRecord(
          txId,
          table,
          onEntry: (pk, entry) {
            if (entry.operation == BufferOperationType.insert) {
              inserted++;
            } else if (entry.operation == BufferOperationType.delete) {
              deleted++;
            }
            return true;
          },
        );
        count += inserted - deleted;
      } catch (_) {}
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

  /// Seed an empty in-memory [TableDataMeta] without touching disk.
  ///
  /// Call after [DataStoreImpl.createTable] so the first insert never pays a
  /// partition-0 existsFile miss. First flush still persists via
  /// [updateTableDataMeta] / writeChanges.
  void seedEmptyTableDataMeta(
    TableContext table, {
    int partitionCount = 1,
  }) {
    final empty = TableDataMeta.createEmpty(
      tableUid: table.tableUid,
      partitionCount: partitionCount,
    );
    _tableDataMetaCache.put(
      table.tableUid,
      empty,
      size: _estimateTableDataMetaSize(empty),
    );
  }

  /// Internal method to perform the actual file load
  Future<TableDataMeta?> _doLoadTableDataMeta(TableUid tableUid) async {
    try {
      final meta =
          await _dataStore.treeMetaPageService.readTableGlobalMeta(tableUid);
      if (meta != null) {
        _tableDataMetaCache.put(tableUid, meta);
        return meta;
      }

      // Disk miss: publish empty meta into the positive cache (same pattern as
      // IndexMeta memory-mode synthesize / clearIndexesForTable pre-seed).
      final raced = _tableDataMetaCache.get(tableUid);
      if (raced != null) return raced;
      final empty = TableDataMeta.createEmpty(tableUid: tableUid);
      _tableDataMetaCache.put(
        tableUid,
        empty,
        size: _estimateTableDataMetaSize(empty),
      );
      return empty;
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
        // Prefer cached maxAutoIncrementId when present -- avoids a leaf scan.
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
        maxFromBuffer = await _dataStore.writeBufferManager
            .getMaxPrimaryKey(table, schema.primaryKey);
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

    // Empty disk does not mean empty result: pending/txn may still have rows.
    bool diskEmpty = false;
    if (!isMemoryMode) {
      final fileMeta = await getTableDataMeta(table.tableUid);
      diskEmpty = fileMeta == null || fileMeta.btreeFirstLeaf.isNull;
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

        // Txn overlay wins over pending buffer (read-your-writes).
        if (currentTxId != null) {
          final txOp = _dataStore.writeBufferManager.bufferTrees
              .getTxnRecord(currentTxId, table.tableUid, pk);
          if (txOp != null) {
            if (txOp.operation == BufferOperationType.delete) {
              return null;
            }
            // BufferEntry.oldValues is separate; data is shared by ref.
            // Legacy guard if _oldValues was embedded in data.
            return _visibleTxnRecord(txOp.data);
          }
        }

        // Check pending buffer for updates/deletes (O(1) lookup)
        final bufferEntry =
            _dataStore.writeBufferManager.getBufferedRecordForRead(
          tableContext,
          pk,
        );
        if (bufferEntry != null) {
          if (bufferEntry.operation == BufferOperationType.delete) {
            return null;
          }
          return bufferEntry.data;
        }

        return record;
      }

      // Skip file stream when disk is empty; pending/txn inserts still emit below.
      if (!diskEmpty || isMemoryMode) {
        if (!isMemoryMode) {
          // File mode: stream from global B+Tree leaf chain.
          final rangeManager = _dataStore.tableTreePartitionManager;
          if (rangeManager != null) {
            await for (final record
                in rangeManager.streamRecordsByPrimaryKeyRange(
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
          }
        } else {
          // Memory mode: use logical TreeCache range scan + StreamController.
          final pkMatcher =
              ValueMatcher.getMatcher(schema.getPrimaryKeyMatcherType());

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
      }

      // After streaming base records, yield pending/txn inserts not already seen.
      // Single PK-ordered TreeCache scan (no intermediate key-list + re-get).
      final trees = _dataStore.writeBufferManager.bufferTrees;
      final pendingExtra = <Map<String, dynamic>>[];
      await trees.forEachPendingRecord(
        tableContext,
        onEntry: (pk, entry) {
          if (processedKeys.contains(pk)) return true;
          if (entry.operation == BufferOperationType.delete) {
            return true;
          }
          if (currentTxId != null) {
            final txOp = trees.getTxnRecord(currentTxId, table.tableUid, pk);
            if (txOp != null && txOp.operation == BufferOperationType.delete) {
              return true;
            }
          }
          pendingExtra.add(entry.data);
          return true;
        },
      );
      for (final row in pendingExtra) {
        final y12 = yieldController.maybeYield();
        if (y12 != null) await y12;
        yield row;
      }

      if (currentTxId != null && _txnIdsWithOps.contains(currentTxId)) {
        final txnExtra = <Map<String, dynamic>>[];
        await trees.forEachTxnRecord(
          currentTxId,
          table,
          onEntry: (pk, entry) {
            if (processedKeys.contains(pk)) return true;
            if (entry.operation == BufferOperationType.delete) {
              return true;
            }
            txnExtra.add(_visibleTxnRecord(entry.data));
            return true;
          },
        );
        for (final row in txnExtra) {
          final y13 = yieldController.maybeYield();
          if (y13 != null) await y13;
          yield row;
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

  /// Rollback: drop txn TreeCache ops and resource estimates.
  Future<void> applyTransactionRollback(String txId) async {
    _txnIdsWithOps.remove(txId);
    _txnResourceEstimates.remove(txId);
    _dataStore.writeBufferManager.clearTransactionBuffers(txId);
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
              final indexOcc = await _sumTableIndexOccupancy(table);
              if (indexOcc.sizeBytes != 0) {
                _deltaIndexDataSizeBytes -= indexOcc.sizeBytes;
              }
              if (indexOcc.entryCount != 0) {
                _deltaIndexEntryCount -= indexOcc.entryCount;
              }
              _needSaveStats = true;
            }
          } catch (e) {
            Logger.warn(
                'Failed to update stats during clearTable for ${table.tableName}',
                rawError: e);
          }

          // Always zero per-table count cache (system KV included).
          await clearTableRecordsForTable(table);
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

          // 7. clean other caches (keep empty TableDataMeta in cache so the
          // next insert does not re-probe disk for a known-empty table).
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

  /// Removes a record from any of the in-memory buffers.
  void removeRecordFromBuffer(TableContext table, String recordId) {
    _dataStore.writeBufferManager.removeRecord(table, recordId);
  }

  /// Removes all data and metadata for a table from the manager.
  Future<void> removeTable(TableContext table) async {
    await clearTableRecordsForTable(table);

    // Clear WAL-driven table-level write buffer and queue to prevent subsequent writes
    await _dataStore.writeBufferManager.clearTableByUid(table.tableUid);

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
      final inactive = <String>{
        ..._txnIdsWithOps,
        ..._txnResourceEstimates.keys,
      }..removeWhere((tx) => active.contains(tx));

      for (final tx in inactive) {
        _txnIdsWithOps.remove(tx);
        _txnResourceEstimates.remove(tx);
        _dataStore.writeBufferManager.clearTransactionBuffers(tx);
      }
    } catch (e) {
      Logger.warn('cleanupTransactionalState failed', rawError: e);
    }
  }

  /// Remove specific transaction state (called by rollback/cleanup)
  Future<void> clearTransactionState(String transactionId) async {
    _txnIdsWithOps.remove(transactionId);
    _txnResourceEstimates.remove(transactionId);
    _dataStore.writeBufferManager.clearTransactionBuffers(transactionId);
  }

  /// Check if there are deferred ops for a transaction
  bool hasDeferredOps(String transactionId) {
    return _txnIdsWithOps.contains(transactionId);
  }

  /// Get deferred ops for transaction (internal/recovery use only).
  ///
  /// Keys are tableUid strings; values are BufferEntry lists from txn TreeCaches.
  Future<Map<String, List<BufferEntry>>?> getDeferredOps(
      String transactionId) async {
    if (!_txnIdsWithOps.contains(transactionId)) return null;
    final collected = await _dataStore.writeBufferManager.bufferTrees
        .collectTxnOps(transactionId);
    if (collected.isEmpty) return null;
    final result = <String, List<BufferEntry>>{};
    for (final entry in collected.entries) {
      result[entry.key] = entry.value.values.toList(growable: false);
    }
    return result;
  }

  /// Merge pending + current-txn TreeCache overlays into [base] query results.
  ///
  /// Visibility: txn > pending > file. Deletes hide lower layers.
  ///
  /// When [pkOrdered] and [limit] are set (normal PK pagination), this uses
  /// TreeCache [scanRange] with early-stop -- O(limit) not O(pending size).
  Future<List<Map<String, dynamic>>> mergeBufferAndTxnConsistency(
    TableContext table,
    List<Map<String, dynamic>> base, {
    bool Function(Map<String, dynamic>)? matcher,
    bool Function(Map<String, dynamic>)? filter,
    int? limit,
    bool reverse = false,
    bool pkOrdered = true,
    dynamic afterPrimaryKey,
  }) async {
    if (pkOrdered && limit != null && limit > 0) {
      return _mergePkOrderedPage(
        table,
        base,
        matcher: matcher,
        filter: filter,
        limit: limit,
        reverse: reverse,
        afterPrimaryKey: afterPrimaryKey,
      );
    }

    // Non-PK / unbounded: point-overlay the base page only (O(|base|)).
    // Do NOT full-scan pending trees -- that destroys latency at scale.
    return _pointOverlayBaseRows(
      table,
      base,
      matcher: matcher,
      filter: filter,
      limit: limit,
      reverse: reverse,
    );
  }

  /// PK-ordered page merge: point-overlay [base] + ranged pending/txn scans.
  ///
  /// Uses TreeCache [scanRange] seek (`startPk`) + early-stop -- never full-walks
  /// the pending tree for a limit=N page.
  Future<List<Map<String, dynamic>>> _mergePkOrderedPage(
    TableContext table,
    List<Map<String, dynamic>> base, {
    bool Function(Map<String, dynamic>)? matcher,
    bool Function(Map<String, dynamic>)? filter,
    required int limit,
    required bool reverse,
    dynamic afterPrimaryKey,
  }) async {
    final schema = table.schema;
    final pkName = schema.primaryKey;
    final pkMatcher =
        ValueMatcher.getMatcher(schema.getPrimaryKeyMatcherType());
    final trees = _dataStore.writeBufferManager.bufferTrees;
    final txId = TransactionContext.getCurrentTransactionId();
    final applyingCommit = TransactionContext.isApplyingCommit();
    final useTxn =
        txId != null && !applyingCommit && _txnIdsWithOps.contains(txId);

    bool acceptPredicates(Map<String, dynamic> row) {
      if (matcher != null && !matcher(row)) return false;
      // Cursor is applied via scan seek ([afterPrimaryKey]), not by filtering
      // from the tree head -- that was the O(n) regression.
      if (filter != null && !filter(row)) return false;
      return true;
    }

    // 1) Point-overlay base rows (O(|base|) gets).
    final baseRows = <Map<String, dynamic>>[];
    for (final row in base) {
      final pk = row[pkName]?.toString();
      if (pk == null || pk.isEmpty) continue;

      Map<String, dynamic>? visible;
      if (useTxn) {
        final tx = trees.getTxnRecord(txId, table.tableUid, pk);
        if (tx != null) {
          if (tx.operation == BufferOperationType.delete) {
            continue;
          }
          visible = _visibleTxnRecord(tx.data);
        }
      }
      if (visible == null) {
        final pending = trees.getPendingRecord(table.tableUid, pk);
        if (pending != null) {
          if (pending.operation == BufferOperationType.delete) {
            continue;
          }
          visible = pending.data;
        } else {
          visible = row;
        }
      }
      if (!acceptPredicates(visible)) continue;
      final pkVal = visible[pkName];
      if (afterPrimaryKey != null && pkVal != null) {
        final c = pkMatcher(pkVal, afterPrimaryKey);
        if (reverse ? c >= 0 : c <= 0) continue;
      }
      baseRows.add(visible);
    }

    if (baseRows.length > 1) {
      baseRows.sort((a, b) {
        final c = pkMatcher(a[pkName], b[pkName]);
        return reverse ? -c : c;
      });
    }

    // 2) Ranged scan: seek to cursor, early-stop after [limit] visible rows.
    //    ASC: startPk=cursor (LowerBound), end=null
    //    DESC: startPk=null, endPk=cursor (LastLE) -- never walk from group max.
    Future<List<Map<String, dynamic>>> scanBufferSource({
      required Future<void> Function({
        dynamic startPk,
        dynamic endPk,
        bool reverse,
        int? limit,
        required bool Function(String pk, BufferEntry entry) onEntry,
      }) forEach,
    }) async {
      final out = <Map<String, dynamic>>[];
      var skipCursorKey = afterPrimaryKey != null;
      // Oversample slightly so deletes/tombstones skipped mid-scan still fill
      // the page; hard stop is still onEntry returning false.
      final scanCap = limit * 4 + 8;
      await forEach(
        startPk: reverse ? null : afterPrimaryKey,
        endPk: reverse ? afterPrimaryKey : null,
        reverse: reverse,
        limit: scanCap,
        onEntry: (pk, entry) {
          if (skipCursorKey) {
            final c = pkMatcher(entry.data[pkName] ?? pk, afterPrimaryKey);
            if (c == 0) {
              skipCursorKey = false;
              return true;
            }
            skipCursorKey = false;
          }
          if (entry.operation == BufferOperationType.delete) {
            return true;
          }
          final row = _visibleTxnRecord(entry.data);
          if (!acceptPredicates(row)) return true;
          out.add(row);
          return out.length < limit;
        },
      );
      return out;
    }

    final pendingRows = await scanBufferSource(
      forEach: ({startPk, endPk, reverse = false, limit, required onEntry}) {
        return trees.forEachPendingRecord(
          table,
          startPk: startPk,
          endPk: endPk,
          reverse: reverse,
          limit: limit,
          onEntry: onEntry,
        );
      },
    );

    List<Map<String, dynamic>> txnRows = const [];
    if (useTxn) {
      txnRows = await scanBufferSource(
        forEach: ({startPk, endPk, reverse = false, limit, required onEntry}) {
          return trees.forEachTxnRecord(
            txId,
            table,
            startPk: startPk,
            endPk: endPk,
            reverse: reverse,
            limit: limit,
            onEntry: onEntry,
          );
        },
      );
    }

    // Fast path: no file base and single buffer source.
    if (baseRows.isEmpty && txnRows.isEmpty) {
      if (pendingRows.length > limit) {
        return pendingRows.sublist(0, limit);
      }
      return pendingRows;
    }
    if (baseRows.isEmpty && pendingRows.isEmpty) {
      if (txnRows.length > limit) return txnRows.sublist(0, limit);
      return txnRows;
    }

    // 3) K-way merge by PK (txn > pending > base on equal key).
    return _kWayMergeByPk(
      sources: [txnRows, pendingRows, baseRows],
      pkName: pkName,
      pkMatcher: pkMatcher,
      reverse: reverse,
      limit: limit,
    );
  }

  List<Map<String, dynamic>> _kWayMergeByPk({
    required List<List<Map<String, dynamic>>> sources,
    required String pkName,
    required MatcherFunction pkMatcher,
    required bool reverse,
    required int limit,
  }) {
    final idxs = List<int>.filled(sources.length, 0);
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};

    while (out.length < limit) {
      int bestSrc = -1;
      dynamic bestPk;
      for (int s = 0; s < sources.length; s++) {
        final list = sources[s];
        var i = idxs[s];
        // Skip exhausted / already-emitted keys in this source.
        while (i < list.length) {
          final pk = list[i][pkName]?.toString();
          if (pk == null || seen.contains(pk)) {
            i++;
            idxs[s] = i;
            continue;
          }
          break;
        }
        idxs[s] = i;
        if (i >= list.length) continue;
        final pkVal = list[i][pkName];
        if (bestSrc < 0) {
          bestSrc = s;
          bestPk = pkVal;
          continue;
        }
        final c = pkMatcher(pkVal, bestPk);
        final better = reverse ? c > 0 : c < 0;
        // On equal PK, lower source index wins (txn=0 > pending=1 > base=2).
        if (better || (c == 0 && s < bestSrc)) {
          bestSrc = s;
          bestPk = pkVal;
        }
      }
      if (bestSrc < 0) break;
      final row = sources[bestSrc][idxs[bestSrc]];
      final pk = row[pkName]?.toString();
      if (pk != null) seen.add(pk);
      idxs[bestSrc]++;
      // Advance other sources past the same PK (dedupe).
      for (int s = 0; s < sources.length; s++) {
        if (s == bestSrc) continue;
        final list = sources[s];
        var i = idxs[s];
        if (i < list.length && list[i][pkName]?.toString() == pk) {
          idxs[s] = i + 1;
        }
      }
      out.add(row);
    }
    return out;
  }

  /// Point-get overlay for each base row only -- O(|base|).
  Future<List<Map<String, dynamic>>> _pointOverlayBaseRows(
    TableContext table,
    List<Map<String, dynamic>> base, {
    bool Function(Map<String, dynamic>)? matcher,
    bool Function(Map<String, dynamic>)? filter,
    int? limit,
    bool reverse = false,
  }) async {
    final schema = table.schema;
    final pkName = schema.primaryKey;
    final trees = _dataStore.writeBufferManager.bufferTrees;
    final txId = TransactionContext.getCurrentTransactionId();
    final applyingCommit = TransactionContext.isApplyingCommit();
    final useTxn =
        txId != null && !applyingCommit && _txnIdsWithOps.contains(txId);
    final pkMatcher =
        ValueMatcher.getMatcher(schema.getPrimaryKeyMatcherType());

    final out = <Map<String, dynamic>>[];
    for (final row in base) {
      final pk = row[pkName]?.toString();
      if (pk == null || pk.isEmpty) continue;

      Map<String, dynamic>? visible;
      if (useTxn) {
        final tx = trees.getTxnRecord(txId, table.tableUid, pk);
        if (tx != null) {
          if (tx.operation == BufferOperationType.delete) {
            continue;
          }
          visible = _visibleTxnRecord(tx.data);
        }
      }
      if (visible == null) {
        final pending = trees.getPendingRecord(table.tableUid, pk);
        if (pending != null) {
          if (pending.operation == BufferOperationType.delete) {
            continue;
          }
          visible = pending.data;
        } else {
          visible = row;
        }
      }
      if (matcher != null && !matcher(visible)) continue;
      if (filter != null && !filter(visible)) continue;
      out.add(visible);
      if (limit != null && out.length >= limit) break;
    }

    if (reverse && out.length > 1) {
      out.sort((a, b) {
        final c = pkMatcher(a[pkName], b[pkName]);
        return -c;
      });
    }
    return out;
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

  /// Resolves a single record from live memory tiers: Txn > WriteBuffer > _tableRecordCache.
  ///
  /// Returns:
  /// - `(found: true, record: data)`: Found live record in memory.
  /// - `(found: true, record: null)`: Found tombstone/delete in memory (record does not exist).
  /// - `(found: false, record: null)`: Not present in memory (must query disk/storage).
  ({bool found, Map<String, dynamic>? record}) _resolveRecordFromMemory(
    TableContext table,
    String pk, {
    bool readFromFileOnly = false,
  }) {
    if (readFromFileOnly) return (found: false, record: null);

    // 0. Pending / Txn Check (ACID consistency)
    final trees = _dataStore.writeBufferManager.bufferTrees;
    final txId = TransactionContext.getCurrentTransactionId();
    final useTxn = txId != null &&
        !TransactionContext.isApplyingCommit() &&
        _txnIdsWithOps.contains(txId);

    BufferEntry? entry;
    var fromTxn = false;
    if (useTxn) {
      final tx = trees.getTxnRecord(txId, table.tableUid, pk);
      if (tx != null) {
        entry = tx;
        fromTxn = true;
      }
    }
    entry ??= _dataStore.writeBufferManager.getBufferedRecordForRead(table, pk);
    if (entry != null) {
      if (entry.operation == BufferOperationType.delete) {
        return (found: true, record: null);
      }
      return (
        found: true,
        record: fromTxn ? _visibleTxnRecord(entry.data) : entry.data,
      );
    }

    // 1. Hotspot / Row Cache Check
    final cached = _tableRecordCache.get([table.tableUid, pk]);
    if (cached != null) {
      return (found: true, record: cached);
    }

    return (found: false, record: null);
  }

  /// Fast single primary key point lookup.
  /// Checks memory tier (Txn > WriteBuffer > _tableRecordCache) with zero collection overhead,
  /// and falls back to disk only on cache miss.
  Future<Map<String, dynamic>?> getRecordByPrimaryKey(
    TableContext table,
    dynamic key, {
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool readFromFileOnly = false,
    TableSchema? decodeSchema,
    List<FieldStructure>? decodeFieldStructureOverride,
  }) async {
    if (key == null) return null;
    final pk = key.toString();
    if (pk.isEmpty) return null;

    final mem = _resolveRecordFromMemory(
      table,
      pk,
      readFromFileOnly: readFromFileOnly,
    );
    if (mem.found) {
      return mem.record;
    }

    // Fall back to disk
    final batchRes = await queryRecordsBatch(
      table,
      [key],
      encryptionKey: encryptionKey,
      encryptionKeyId: encryptionKeyId,
      readFromFileOnly: readFromFileOnly,
      decodeSchema: decodeSchema,
      decodeFieldStructureOverride: decodeFieldStructureOverride,
    );
    if (batchRes.records.isNotEmpty) {
      return batchRes.records.first;
    }
    return null;
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
    final pkName = schema.primaryKey;

    final results = <Map<String, dynamic>>[];
    final stillMissing = <dynamic>[];
    final uniqueKeys = keys.toSet().toList();

    // 0. Resolve from memory tiers (Txn > WriteBuffer > _tableRecordCache)
    for (final key in uniqueKeys) {
      final pk = key.toString();
      final mem = _resolveRecordFromMemory(
        table,
        pk,
        readFromFileOnly: readFromFileOnly,
      );
      if (mem.found) {
        if (mem.record != null) {
          results.add(mem.record!);
        }
      } else {
        stillMissing.add(key);
      }
    }

    // 2. Try Disk
    if (stillMissing.isNotEmpty) {
      final pkMatcher =
          ValueMatcher.getMatcher(schema.getPrimaryKeyMatcherType());
      if (_dataStore.tableTreePartitionManager == null) {
        return TableScanResult(records: results);
      }
      final diskResults =
          await _dataStore.tableTreePartitionManager?.queryRecordsBatch(
        table: table,
        primaryKey: pkName,
        keyComparator: pkMatcher,
        keys: stillMissing,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        schemaOverride: schema,
        decodeFieldStructureOverride: decodeFieldStructureOverride,
        readFromFileOnly: readFromFileOnly,
      );
      if (diskResults == null) {
        return TableScanResult(records: results);
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
    required Uint8List startKeyInclusive,
    required Uint8List endKeyExclusive,
    dynamic rangeMin,
    dynamic rangeMax,
    bool includeMin = true,
    bool includeMax = true,
    String? cursorPk,
    bool decodeRecord = true,

    /// Applied after overlay, before [onRecord]. Skip row when false.
    bool Function(Map<String, dynamic>)? acceptRow,
    required bool Function(Map<String, dynamic>) onRecord,
    TableSchema? decodeSchema,
    List<FieldStructure>? decodeFieldStructureOverride,
    bool readFromFileOnly = false,
  }) async {
    final isMemoryMode =
        _dataStore.config.persistenceMode == PersistenceMode.memory;
    final trees = _dataStore.writeBufferManager.bufferTrees;
    final txId = TransactionContext.getCurrentTransactionId();
    final applyingCommit = TransactionContext.isApplyingCommit();
    final useTxn = !readFromFileOnly &&
        txId != null &&
        !applyingCommit &&
        _txnIdsWithOps.contains(txId);
    final hasPending = !readFromFileOnly &&
        _dataStore.writeBufferManager.hasPendingWritesForUid(table.tableUid);
    final needBufferFuse = hasPending || useTxn;

    bool deliver(Map<String, dynamic> row) {
      if (acceptRow != null && !acceptRow(row)) return true;
      return onRecord(row);
    }

    final String? cursor =
        cursorPk != null && cursorPk.isNotEmpty ? cursorPk : null;

    dynamic lowBoundPk = rangeMin;
    dynamic highBoundPk = rangeMax;
    if (cursor != null) {
      if (!reverse) {
        if (lowBoundPk == null) {
          lowBoundPk = cursor;
        } else if (pkMatcher(lowBoundPk, cursor) < 0) {
          lowBoundPk = cursor;
        }
      } else {
        if (highBoundPk == null) {
          highBoundPk = cursor;
        } else if (pkMatcher(highBoundPk, cursor) > 0) {
          highBoundPk = cursor;
        }
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

    Map<String, dynamic>? resolveOverlay(Map<String, dynamic> row) {
      final pk = row[primaryKey]?.toString();
      if (pk == null || pk.isEmpty) return null;
      if (useTxn) {
        final tx = trees.getTxnRecord(txId, table.tableUid, pk);
        if (tx != null) {
          if (tx.operation == BufferOperationType.delete) {
            return null;
          }
          return _visibleTxnRecord(tx.data);
        }
      }
      if (hasPending) {
        final pending = trees.getPendingRecord(table.tableUid, pk);
        if (pending != null) {
          if (pending.operation == BufferOperationType.delete) {
            return null;
          }
          return pending.data;
        }
      }
      return row;
    }

    Future<void> forEachBase({
      required bool Function(Map<String, dynamic>) onBase,
      int? baseLimit,
      required bool fileOnly,
    }) async {
      if (!isMemoryMode) {
        await _dataStore.tableTreePartitionManager
            ?.forEachRecordByPrimaryKeyRange(
          table: table,
          startKeyInclusive: startKeyInclusive,
          endKeyExclusive: endKeyExclusive,
          reverse: reverse,
          limit: baseLimit,
          onRecord: onBase,
          decodeRecord: decodeRecord,
          decodeSchema: decodeSchema,
          decodeFieldStructureOverride: decodeFieldStructureOverride,
          readFromFileOnly: fileOnly,
        );
        return;
      }

      _registerTableComparator(table, schema);
      late final List<dynamic> startKeyPath;
      List<dynamic>? endKeyPath;
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

      var yielded = 0;
      await _tableRecordCache.scanRange(
        startKeyPath,
        endKeyPath,
        reverse: reverse,
        limit: null,
        onEntry: (path, value) {
          final rec = value;
          final dynamic pkNative = rec[primaryKey];
          if (pkNative == null) return true;
          if (!checkRange(pkNative)) return true;
          if (!onBase(rec)) return false;
          if (baseLimit != null) {
            yielded++;
            if (yielded >= baseLimit) return false;
          }
          return true;
        },
      );
    }

    // File/memory only -- no pending/txn fusion.
    if (!needBufferFuse) {
      await forEachBase(
        onBase: deliver,
        baseLimit: limit,
        fileOnly: readFromFileOnly,
      );
      return;
    }

    // Limited PK page: same seek+scanCap fuse as [_mergePkOrderedPage].
    // Never preload the whole pending group (that was the 600--1000ms PK path).
    if (limit != null && limit > 0) {
      final scanCap = limit * 4 + 8;
      final base = <Map<String, dynamic>>[];
      await forEachBase(
        onBase: (r) {
          base.add(r);
          return base.length < scanCap;
        },
        baseLimit: scanCap,
        fileOnly: true,
      );
      final merged = await _mergePkOrderedPage(
        table,
        base,
        matcher: (row) {
          final pkNative = row[primaryKey];
          if (pkNative == null || !checkRange(pkNative)) return false;
          // Sole filter point for this path -- do not re-run via deliver().
          return acceptRow == null || acceptRow(row);
        },
        limit: limit,
        reverse: reverse,
        afterPrimaryKey: cursor,
      );
      for (final r in merged) {
        if (!onRecord(r)) break;
      }
      return;
    }

    // Unbounded scan: range-seek pending/txn (not whole table group), then
    // stream-merge with file. Stop buffer walk once past the far range bound.
    Future<List<Map<String, dynamic>>> scanBufferSource({
      required Future<void> Function({
        dynamic startPk,
        dynamic endPk,
        bool reverse,
        int? limit,
        required bool Function(String pk, BufferEntry entry) onEntry,
      }) forEach,
    }) async {
      final out = <Map<String, dynamic>>[];
      var skipCursorKey = cursor != null;
      await forEach(
        startPk: reverse ? null : lowBoundPk,
        endPk: reverse ? highBoundPk : highBoundPk,
        reverse: reverse,
        limit: null,
        onEntry: (pk, entry) {
          if (skipCursorKey) {
            final c = pkMatcher(entry.data[primaryKey] ?? pk, cursor);
            if (c == 0) {
              skipCursorKey = false;
              return true;
            }
            skipCursorKey = false;
          }
          if (entry.operation == BufferOperationType.delete) {
            return true;
          }
          final row = _visibleTxnRecord(entry.data);
          final pkNative = row[primaryKey];
          if (pkNative == null) return true;
          if (!checkRange(pkNative)) {
            if (reverse &&
                rangeMin != null &&
                pkMatcher(pkNative, rangeMin) < 0) {
              return false;
            }
            if (!reverse &&
                rangeMax != null &&
                pkMatcher(pkNative, rangeMax) > 0) {
              return false;
            }
            return true;
          }
          out.add(row);
          return true;
        },
      );
      return out;
    }

    final pendingRows = hasPending
        ? await scanBufferSource(
            forEach: (
                {startPk, endPk, reverse = false, limit, required onEntry}) {
              return trees.forEachPendingRecord(
                table,
                startPk: startPk,
                endPk: endPk,
                reverse: reverse,
                limit: limit,
                onEntry: onEntry,
              );
            },
          )
        : const <Map<String, dynamic>>[];

    final txnRows = useTxn
        ? await scanBufferSource(
            forEach: (
                {startPk, endPk, reverse = false, limit, required onEntry}) {
              return trees.forEachTxnRecord(
                txId,
                table,
                startPk: startPk,
                endPk: endPk,
                reverse: reverse,
                limit: limit,
                onEntry: onEntry,
              );
            },
          )
        : const <Map<String, dynamic>>[];

    if (pendingRows.isEmpty && txnRows.isEmpty) {
      await forEachBase(
        onBase: (r) {
          final visible = resolveOverlay(r);
          if (visible == null) return true;
          return deliver(visible);
        },
        baseLimit: limit,
        fileOnly: true,
      );
      return;
    }

    var ti = 0;
    var pi = 0;
    final seen = <String>{};
    var continueScan = true;

    bool emit(Map<String, dynamic> row) {
      final pk = row[primaryKey]?.toString();
      if (pk == null || pk.isEmpty || !seen.add(pk)) return true;
      return deliver(row);
    }

    bool flushBuffersBefore(dynamic filePk) {
      while (continueScan) {
        final t = ti < txnRows.length ? txnRows[ti] : null;
        final p = pi < pendingRows.length ? pendingRows[pi] : null;
        if (t == null && p == null) return true;

        Map<String, dynamic>? best;
        var bestSrc = -1;
        if (t != null) {
          best = t;
          bestSrc = 0;
        }
        if (p != null) {
          if (best == null) {
            best = p;
            bestSrc = 1;
          } else {
            final c = pkMatcher(p[primaryKey], best[primaryKey]);
            final better = reverse ? c > 0 : c < 0;
            if (better) {
              best = p;
              bestSrc = 1;
            }
          }
        }

        if (filePk != null) {
          final c = pkMatcher(best![primaryKey], filePk);
          final isBefore = reverse ? c > 0 : c < 0;
          if (!isBefore) {
            if (c == 0) {
              if (bestSrc == 0) {
                ti++;
              } else {
                pi++;
              }
              if (!emit(best)) {
                continueScan = false;
                return false;
              }
              continue;
            }
            return true;
          }
        }

        if (bestSrc == 0) {
          ti++;
        } else {
          pi++;
        }
        if (!emit(best!)) {
          continueScan = false;
          return false;
        }
      }
      return false;
    }

    await forEachBase(
      onBase: (r) {
        if (!continueScan) return false;
        final pkVal = r[primaryKey];
        if (pkVal == null) return true;
        if (!flushBuffersBefore(pkVal)) return false;
        final pkStr = pkVal.toString();
        if (seen.contains(pkStr)) return true;
        final visible = resolveOverlay(r);
        if (visible == null) return true;
        if (!emit(visible)) {
          continueScan = false;
          return false;
        }
        return true;
      },
      baseLimit: null,
      fileOnly: true,
    );

    if (continueScan) {
      flushBuffersBefore(null);
    }
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

    // Row predicate for residual conditions (after overlay). Applied at most
    // once per visible row via acceptRow / PK-point paths.
    bool rowMatches(Map<String, dynamic> r) {
      if (filter != null && !filter(r)) return false;
      if (matcher != null && !matcher.matches(r)) return false;
      return true;
    }

    // Decode non-PK columns only when residual filter/matcher needs them.
    final bool needsFullDecode = filter != null ||
        (matcher != null && matcher.fields.any((f) => f != primaryKey));
    // needsPostFilter is decided after PK range pushdown (below).

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
          if (rowMatches(r)) {
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
        if (rowMatches(r)) {
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
      // Do NOT early-return on empty disk: pending/txn TreeCaches may still
      // hold visible inserts that must be merged into the scan result.
      if (fileMeta == null || fileMeta.totalRecordCount <= 0) {
        final hasPending = _dataStore.writeBufferManager
            .hasPendingWritesForUid(table.tableUid);
        final txId = TransactionContext.getCurrentTransactionId();
        final hasTxn = txId != null && _txnIdsWithOps.contains(txId);
        if (!hasPending && !hasTxn) {
          return TableScanResult(
            records: const [],
            count: onlyCount ? 0 : null,
          );
        }
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

    // True when a PK LIKE was rewritten into an exact covering range
    // (simple prefix `lit%` or exact `lit`, escape-aware).
    bool pkLikeFullyCoveredByRange = false;

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

      // Prefix / exact LIKE on PK -> byte-range (same idea as index prefix LIKE).
      // Escape-aware: whereStartsWith emits \% \_ so keys with '_' stay literal.
      final likePat = pkCond['LIKE'] ?? pkCond['like'];
      if (likePat is String) {
        final parsed = ValueMatcher.parseOptimizablePrefixLike(likePat);
        if (parsed != null &&
            (parsed.isExact || parsed.literalPrefix.isNotEmpty)) {
          final lit = parsed.literalPrefix;
          // Intersect with any existing range bounds using string compare via
          // the PK matcher (native values).
          void tightenMin(dynamic cand, {required bool inclusive}) {
            if (rangeMin == null) {
              rangeMin = cand;
              includeMin = inclusive;
              return;
            }
            final c = pkMatcher(cand, rangeMin);
            if (c > 0) {
              rangeMin = cand;
              includeMin = inclusive;
            } else if (c == 0) {
              includeMin = includeMin && inclusive;
            }
          }

          void tightenMax(dynamic cand, {required bool inclusive}) {
            if (rangeMax == null) {
              rangeMax = cand;
              includeMax = inclusive;
              return;
            }
            final c = pkMatcher(cand, rangeMax);
            if (c < 0) {
              rangeMax = cand;
              includeMax = inclusive;
            } else if (c == 0) {
              includeMax = includeMax && inclusive;
            }
          }

          if (parsed.isExact) {
            tightenMin(lit, inclusive: true);
            tightenMax(lit, inclusive: true);
            pkLikeFullyCoveredByRange = true;
          } else {
            tightenMin(lit, inclusive: true);
            final next = ValueMatcher.incrementUtf16Prefix(lit);
            if (next != null) {
              tightenMax(next, inclusive: false);
              pkLikeFullyCoveredByRange = true;
            } else {
              // Cannot form exclusive upper bound; keep >= lit and post-filter.
              pkLikeFullyCoveredByRange = false;
            }
          }
        }
      }

      pkCondIsIndexableRange = (rangeMin != null || rangeMax != null);
    }

    // Skip rematch only when every matcher predicate was pushed into the PK
    // byte-range / checkRange bounds. IN/!=/OR/non-PK/non-prefix LIKE still
    // need rowMatches. (Do NOT use "PK-only fields" alone.)
    bool matcherFullyCoveredByPkRangePushdown() {
      if (matcher == null) return true;
      if (hasOr) return false;
      if (matcher.fields.any((f) => f != primaryKey)) return false;
      if (pkCond == null || !pkCondIsIndexableRange) return false;
      const coveredOps = {'>', '>=', '<', '<=', 'BETWEEN', 'LIKE'};
      for (final op in pkCond.keys) {
        final up = op.toUpperCase();
        if (!coveredOps.contains(up)) return false;
        if (up == 'LIKE' && !pkLikeFullyCoveredByRange) return false;
      }
      return true;
    }

    final bool needsPostFilter = filter != null ||
        (matcher != null && !matcherFullyCoveredByPkRangePushdown());

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
      // acceptRow filters after overlay; storage limit only when every in-range
      // row is accepted (otherwise stop via onRecord after enough matches).
      final int? scanLimit =
          needsPostFilter ? null : ((needCount < 0) ? null : needCount);
      final acceptRow = needsPostFilter ? rowMatches : null;

      if (onlyCount) {
        int totalCount = 0;
        await _forEachRecordByPrimaryKeyRangeLogical(
          table: table,
          schema: schema,
          primaryKey: primaryKey,
          pkMatcher: pkMatcher,
          reverse: reverse,
          limit: scanLimit,
          startKeyInclusive: startKeyBytes,
          endKeyExclusive: endKeyBytes,
          rangeMin: rangeMin,
          rangeMax: rangeMax,
          includeMin: includeMin,
          includeMax: includeMax,
          cursorPk: cursorPk.isNotEmpty ? cursorPk : null,
          decodeRecord: needsFullDecode,
          decodeSchema: decodeSchema,
          decodeFieldStructureOverride: decodeFieldStructureOverride,
          readFromFileOnly: readFromFileOnly,
          acceptRow: acceptRow,
          onRecord: (r) {
            totalCount++;
            if (needCount >= 0 && totalCount >= needCount) return false;
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
        var accepted = 0;
        await _forEachRecordByPrimaryKeyRangeLogical(
          table: table,
          schema: schema,
          primaryKey: primaryKey,
          pkMatcher: pkMatcher,
          reverse: reverse,
          limit: scanLimit,
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
          acceptRow: acceptRow,
          onRecord: (r) {
            agg.accumulate(r);
            accepted++;
            if (needCount >= 0 && accepted >= needCount) return false;
            return true;
          },
        );
        return TableScanResult(records: const [], aggregateResult: agg.result);
      } else {
        final out = <Map<String, dynamic>>[];
        await _forEachRecordByPrimaryKeyRangeLogical(
          table: table,
          schema: schema,
          primaryKey: primaryKey,
          pkMatcher: pkMatcher,
          reverse: reverse,
          limit: scanLimit,
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
          acceptRow: acceptRow,
          onRecord: (r) {
            out.add(r);
            if (needCount >= 0 && out.length >= needCount) return false;
            return true;
          },
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
      await _forEachRecordByPrimaryKeyRangeLogical(
        table: table,
        schema: schema,
        primaryKey: primaryKey,
        pkMatcher: pkMatcher,
        reverse: false,
        limit: null,
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
        acceptRow: needsPostFilter ? rowMatches : null,
        onRecord: (r) {
          out.add(r);
          return true;
        },
      );
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
    final globalTop =
        TopKHeap<Map<String, dynamic>>(k: needCount, compare: compareRecords);

    await _forEachRecordByPrimaryKeyRangeLogical(
      table: table,
      schema: schema,
      primaryKey: primaryKey,
      pkMatcher: pkMatcher,
      reverse: false,
      limit: null,
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
      acceptRow: needsPostFilter ? rowMatches : null,
      onRecord: (r) {
        globalTop.offer(r);
        return true;
      },
    );

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
          estimateAverageRecordBytesForBatch(records),
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

/// Visible view of a transactional deferred record.
///
/// [BufferEntry.oldValues] is stored separately; [data] is shared by
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
