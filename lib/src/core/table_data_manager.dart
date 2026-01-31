import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import '../handler/logger.dart';
import '../handler/memcomparable.dart';
import '../handler/value_matcher.dart';
import '../handler/topk_heap.dart';
import '../query/query_executor.dart';
import 'workload_scheduler.dart';
import '../model/buffer_entry.dart';

import '../model/data_store_config.dart';
import '../model/table_schema.dart';
import '../query/query_condition.dart';
import 'data_store_impl.dart';
import '../model/meta_info.dart';
import 'crontab_manager.dart';
import '../model/id_generator.dart';
import '../model/system_table.dart';
import 'tree_cache.dart';
import '../handler/parallel_processor.dart';
import 'transaction_context.dart';
import '../model/transaction_models.dart';
import 'write_buffer_manager.dart';
import '../model/parallel_journal_entry.dart';
import 'yield_controller.dart';
import 'weight_manager.dart';

/// table data manager - schedule data read/write, backup, index update, etc.
class TableDataManager {
  final DataStoreImpl _dataStore;

  // Table refresh status flags
  final Map<String, bool> _tableFlushingFlags = {};

  /// Check if a table is currently being cleared/flushed
  bool isTableBeingCleared(String tableName) {
    return _tableFlushingFlags.containsKey(tableName);
  }

  // List of tables currently being processed, for concurrency control
  final Set<String> _processingTables = {};

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

  /// Map of table names to futures that are currently loading table metadata
  final Map<String, Future<TableMeta?>> _metaLoadingFutures = {};

  // Table meta cache for table file metadata (TableMeta).
  late final TreeCache<TableMeta> _tableMetaCache;

  // -------------------- Table record cache --------------------
  // Composite key format: [tableName, pk]
  late final TreeCache<Map<String, dynamic>> _tableRecordCache;

  // -------------------- Transactional structures --------------------
  // Per-transaction deferred ops (insert/update/delete) not written until commit
  // txId -> tableName -> pk -> TxnDeferredOp
  final Map<String, Map<String, Map<String, TxnDeferredOp>>> _txnDeferredOps =
      {};

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

  // Total table count tracking
  int _totalTableCount = 0;

  // Total record count tracking for all tables
  int _totalRecordCount = 0;

  // Total data file size (bytes) tracking for all tables
  int _totalDataSizeBytes = 0;

  // Flag indicating if statistics need to be saved
  bool _needSaveStats = false;

  // Throttling state for lightweight meta persistence
  DateTime _lastStatsPersistTime = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastMaxIdFlushTime = DateTime.fromMillisecondsSinceEpoch(0);

  // --- End: Intelligent Polling Methods ---

  // Comparator registry for table primary keys
  final Map<String, Comparator<dynamic>> _pkComparators = {};

  /// Factory to provide comparators for TreeCache based on path (Table Record Cache)
  Comparator<dynamic> _tableRecordComparatorFactory(List<dynamic> path) {
    if (path.isNotEmpty) {
      final tableName = path[0] as String;
      return _pkComparators[tableName] ?? TreeCache.compareNative;
    }
    return TreeCache.compareNative;
  }

  /// Register a comparator for a table's primary key
  void _registerTableComparator(String tableName, TableSchema schema) {
    if (_pkComparators.containsKey(tableName)) return;

    // Use ValueMatcher to get the correct comparator for the PK type
    final pdType = schema.getPrimaryKeyMatcherType();
    _pkComparators[tableName] = ValueMatcher.getMatcher(pdType);
  }

  TableDataManager(this._dataStore) {
    // Initialize table record cache (table data quota).
    final mem = _dataStore.memoryManager;
    // Initialize table metadata cache (meta quota slice).
    final int metaQuota = mem?.getMetaCacheSize() ?? (64 * 1024 * 1024);
    // Meta quota is shared by multiple caches (index meta, footers, etc.).
    // Allocate a conservative slice for table metadata.
    final int tableMetaMax = max(1, (metaQuota * 0.25).toInt());
    _tableMetaCache = TreeCache<TableMeta>(
      sizeCalculator: _estimateTableMetaSize,
      maxByteThreshold: tableMetaMax,
      minByteThreshold: 50 * 1024 * 1024,
      debugLabel: 'TableMetaCache',
    );

    final int tableQuota =
        mem?.getTableDataCacheSize() ?? (128 * 1024 * 1024); // Default 128MB
    // Reserve a portion for range-partition caches (blocks + sparse index).
    final int maxBytes = max(1, (tableQuota * 0.55).toInt());
    _tableRecordCache = TreeCache<Map<String, dynamic>>(
      sizeCalculator: _estimateRecordSizeBytes,
      maxByteThreshold: maxBytes,
      minByteThreshold: 50 * 1024 * 1024,
      comparatorFactory: _tableRecordComparatorFactory,
      weightQueryCallback: _queryTableRecordWeight,
      debugLabel: 'TableRecordCache',
    );

    // Initialize auto-increment ID generator and set periodic check task
    CrontabManager.addCallback(
        ExecuteInterval.seconds3, TimeBasedIdGenerator.periodicPoolCheck);

    // Load statistics
    _loadStatisticsFromConfig();

    CrontabManager.addCallback(
        ExecuteInterval.hour24, _updateTableStatisticsIfNeeded);
    // Use delayed execution
    Future.delayed(const Duration(seconds: 10), () {
      _updateTableStatisticsIfNeeded();
    });
  }

  // -------------------- Table record cache APIs --------------------
  /// Get a cached record by [pk] if present.
  /// Returns a defensive copy to avoid external mutation of cached value.
  Map<String, dynamic>? getCachedTableRecord(String tableName, String pk) {
    return _tableRecordCache.get([tableName, pk]);
  }

  /// Check if a record exists in the table record cache (O(1) fast check).
  /// Note: This returns true even for tombstones (deleted records) if they are in the cache.
  bool hasTableRecord(String tableName, String pk) {
    return _tableRecordCache.containsKey([tableName, pk]);
  }

  /// Check if a record exists in the table record cache and is NOT a tombstone.
  ///
  /// This is safer than [hasTableRecord] for uniqueness/existence checks.
  /// Uses TreeCache.peek() to avoid polluting access stats during hot validation loops.
  bool hasLiveTableRecord(String tableName, String pk) {
    final rec = _tableRecordCache.get([tableName, pk], updateStats: false);
    return rec != null && !isDeletedRecord(rec);
  }

  /// Cache a single table record
  void cacheTableRecord(String tableName, String pk,
      Map<String, dynamic> record, TableSchema schema,
      {bool force = false}) {
    if (_tableRecordCache.maxByteThreshold <= 0) {
      return;
    }

    if (isDeletedRecord(record)) {
      _tableRecordCache.remove([tableName, pk]);
      return;
    }

    // [Cache Optimization] Use Fast O(1) checks
    final bool alreadyInCache = _tableRecordCache.containsKey([tableName, pk]);

    if (alreadyInCache || force || _dataStore.isGlobalPrewarming) {
      // Lazy registration of comparator
      _registerTableComparator(tableName, schema);

      _tableRecordCache.put(
        [tableName, pk],
        record,
        size: _estimateRecordSizeBytes(record),
      );
    }
  }

  /// Cache (or update) multiple table records
  ///
  /// [isInsertOperation] should be true for internal batch insert paths.
  void cacheTableRecordsBatch(
    String tableName,
    List<Map<String, dynamic>> records, {
    required String primaryKey,
    required TableSchema schema,
    bool isInsertOperation = false,
    bool force = false,
  }) {
    if (records.isEmpty) return;
    if (_tableRecordCache.maxByteThreshold <= 0) {
      return;
    }

    // [Optimization] We only update if it's already there or forced
    final doNotCache = !_dataStore.isGlobalPrewarming && !force;
    if (isInsertOperation && doNotCache) {
      return;
    }

    // Lazy registration of comparator
    _registerTableComparator(tableName, schema);

    for (final r in records) {
      final pk = r[primaryKey]?.toString();
      if (pk == null || pk.isEmpty) continue;
      if (isDeletedRecord(r)) continue;

      final key = [tableName, pk];

      // If not forced/prewarming, we only update if it's already there
      if (doNotCache) {
        if (!_tableRecordCache.containsKey(key)) continue;
      }

      final value = r;
      final size = _estimateRecordSizeBytes(value);
      _tableRecordCache.put(key, value, size: size);
    }
  }

  /// Remove a cached table record (if present).
  void removeTableRecord(String tableName, String pk) {
    _tableRecordCache.remove([tableName, pk]);
  }

  /// Remove multiple cached table records.
  Future<void> removeTableRecords(String tableName, List<String> pks) async {
    if (pks.isEmpty) return;
    final yieldController =
        YieldController('TableDataManager.removeTableRecords');
    for (final pk in pks) {
      await yieldController.maybeYield();
      _tableRecordCache.remove([tableName, pk]);
    }
  }

  /// Remove all cached records of a table (used for drop/clear/space switching).
  Future<void> clearTableRecordsForTable(String tableName) async {
    _tableRecordCache.remove([tableName]);

    // Also remove from record count cache
    _tableRecordCounts.remove(tableName);
  }

  /// Remove record count cache for a table.
  void removeRecordCountCache(String tableName) {
    _tableRecordCounts.remove(tableName);
  }

  /// Remove record count cache for all tables.
  void removeRecordCountCacheAll() {
    _tableRecordCounts.clear();
  }

  /// Evict a ratio of table record cache entries under memory pressure.
  Future<void> evictTableRecordCache({double ratio = 0.3}) async {
    await _tableRecordCache.cleanup(removeRatio: ratio);
  }

  /// Clear all table record cache entries.
  Future<void> clearAllTableRecordCache() async {
    _tableRecordCache.clear();
  }

  /// Clear all table record cache entries synchronously (used on shutdown).
  void clearAllTableRecordCacheSync() {
    _tableRecordCache.clear();
  }

  /// Current table record cache size in bytes.
  int getCurrentTableRecordCacheSize() {
    return _tableRecordCache.estimatedTotalSizeBytes;
  }

  /// Estimate table metadata size (bytes)
  int _estimateTableMetaSize(TableMeta meta) {
    // v2+ meta is small and fixed-shape (no partition lists).
    // Keep a conservative estimate to guide cache sizing.
    return 160 + meta.name.length * 2;
  }

  /// Query weight for table record cache entry
  /// Path format: [tableName, pk]
  /// Weight object is the tableName
  Future<int?> _queryTableRecordWeight(List<dynamic> path) async {
    if (path.isEmpty) return null;
    final tableName = path[0]?.toString();
    if (tableName == null || tableName.isEmpty) return null;

    try {
      final weightManager = _dataStore.weightManager;
      if (weightManager == null) return null;

      return await weightManager.getWeight(
        WeightType.tableRecord,
        tableName,
      );
    } catch (e) {
      Logger.warn(
        'Failed to query table record weight for $tableName: $e',
        label: 'TableDataManager._queryTableRecordWeight',
      );
      return null;
    }
  }

  // -------------------- Record size estimation (TableRecordCache) --------------------
  int _estimateRecordSizeBytes(Map<String, dynamic> record) {
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

  /// Persist runtime metadata (statistics and max IDs) with throttling.
  /// When [force] is true, persist immediately if anything is dirty.
  Future<void> persistRuntimeMetaIfNeeded({bool force = false}) async {
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

      // Save statistics if needed
      if (_needSaveStats) {
        final bool due = force ||
            now.difference(_lastStatsPersistTime).inMilliseconds >=
                minIntervalMs;
        if (due) {
          await _saveStatisticsToConfig();
          _lastStatsPersistTime = DateTime.now();
        }
      }
    } catch (e) {
      Logger.warn('persistRuntimeMetaIfNeeded failed: $e',
          label: 'TableDataManager');
    }
  }

  /// Evict a ratio of table metadata cache entries under memory pressure.
  Future<void> evictTableMetaCache({double ratio = 0.3}) async {
    try {
      await _tableMetaCache.cleanup(removeRatio: ratio);
    } catch (e) {
      Logger.warn('Evict table meta cache failed: $e',
          label: 'TableDataManager.evictTableMetaCache');
    }
  }

  /// Clear all table metadata cache entries (yielding).
  Future<void> clearTableMetaCache() async {
    _tableMetaCache.clear();
  }

  /// Clear all table metadata cache entries synchronously (used on shutdown).
  void clearTableMetaCacheSync() {
    _tableMetaCache.clear();
  }

  /// Invalidate cached table metadata for a single table (best-effort).
  void invalidateTableMetaCacheForTable(String tableName) {
    _tableMetaCache.remove(tableName);
  }

  /// Load statistics from configuration
  Future<void> _loadStatisticsFromConfig() async {
    try {
      final config = await _dataStore.getSpaceConfig();
      if (config != null) {
        _totalTableCount = config.totalTableCount;
        _totalRecordCount = config.totalRecordCount;
        _totalDataSizeBytes = config.totalDataSizeBytes;
      }
    } catch (e) {
      Logger.error('Failed to load table statistics: $e',
          label: 'TableDataManager._loadStatisticsFromConfig');
    }
  }

  /// Update statistics if needed (full scan once per day)
  Future<void> _updateTableStatisticsIfNeeded() async {
    try {
      final config = await _dataStore.getSpaceConfig();
      if (config != null && config.needUpdateStatistics()) {
        await recalculateAllStatistics();
      }
    } catch (e) {
      Logger.error('Failed to check for updated statistics: $e',
          label: 'TableDataManager._updateTableStatisticsIfNeeded');
    }
  }

  /// Calculate statistics for all tables
  /// Only counts user tables, excluding system tables
  Future<void> recalculateAllStatistics() async {
    try {
      // Get all table metadata (only user tables, excluding system tables)
      final schemaManager = _dataStore.schemaManager;
      if (schemaManager == null) return;

      final tableNames =
          await schemaManager.listAllTables(onlyUserTables: true);

      int tableCount = tableNames.length;
      int totalRecords = 0;
      int totalSize = 0;

      // Use ParallelProcessor to fetch table metadata concurrently (maintenance read)
      final statsLease = await _dataStore.workloadScheduler.tryAcquire(
        WorkloadType.maintenance,
        requestedTokens: _dataStore.workloadScheduler
            .capacityTokens(WorkloadType.maintenance),
        minTokens: 1,
        label: 'TableDataManager.recalculateAllStatistics',
      );
      final int statsConc = (statsLease?.asConcurrency(0.3) ?? 1);
      final metaList = await ParallelProcessor.execute<TableMeta?>(
        tableNames.map((tableName) {
          return () => getTableMeta(tableName);
        }).toList(),
        concurrency: statsConc,
        label: 'TableDataManager._calculateTableStatistics',
      );
      statsLease?.release();

      // Iterate through the results to calculate statistics
      final yieldController =
          YieldController('TableDataManager.recalculateAllStatistics');
      for (final meta in metaList) {
        await yieldController.maybeYield(); // Added yield to outer loop
        if (meta != null) {
          // Accumulate record count
          totalRecords += meta.totalRecords;

          // Total file size is maintained in v2+ table meta.
          totalSize += meta.totalSizeInBytes;
        }
      }

      // Update statistics
      _totalTableCount = tableCount;
      _totalRecordCount = totalRecords;
      _totalDataSizeBytes = totalSize;

      // Save to configuration
      await _saveStatisticsToConfig();

      Logger.debug(
          'Table statistics calculation completed: table count=$tableCount, record count=$totalRecords, data size=${totalSize / 1024 / 1024}MB',
          label: 'TableDataManager._calculateTableStatistics');
    } catch (e) {
      Logger.error('Failed to calculate table statistics: $e',
          label: 'TableDataManager._calculateTableStatistics');
    }
  }

  /// Get current max ID in memory for a table
  dynamic getMaxIdInMemory(String tableName) {
    return _maxIds[tableName];
  }

  /// Save statistics to configuration
  Future<void> _saveStatisticsToConfig() async {
    try {
      final config = await _dataStore.getSpaceConfig();
      if (config != null) {
        final updatedConfig = config.copyWith(
            totalTableCount: _totalTableCount,
            totalRecordCount: _totalRecordCount,
            totalDataSizeBytes: _totalDataSizeBytes,
            lastStatisticsTime: DateTime.now());

        await _dataStore.saveSpaceConfigToFile(updatedConfig);
        _needSaveStats = false;
      }
    } catch (e) {
      Logger.error('Failed to save table statistics: $e',
          label: 'TableDataManager._saveStatisticsToConfig');
    }
  }

  /// Update max ID value (only in memory)
  /// [updateFileMeta] if true, also updates FileMeta.maxAutoIncrementId to keep cache consistent
  Future<void> updateMaxIdInMemory(String tableName, dynamic id,
      {bool updateFileMeta = false}) async {
    try {
      // Ensure id is in string format
      String idStr = id.toString();

      // Check if it's a numeric string
      if (!_isNumericString(idStr)) {
        return;
      }

      final currentMaxId = _maxIds[tableName];
      bool shouldUpdate = false;

      if (currentMaxId == null) {
        // First set max ID
        _maxIds[tableName] = idStr;
        _maxIdsDirty[tableName] = true;
        shouldUpdate = true;
      } else {
        // Ensure currentMaxId is also a string
        String currentMaxIdStr = currentMaxId.toString();

        // Compare current value with max value
        final matcher = ValueMatcher.getMatcher(MatcherType.pkNumericString);
        if (matcher(idStr, currentMaxIdStr) > 0) {
          _maxIds[tableName] = idStr;
          _maxIdsDirty[tableName] = true;
          shouldUpdate = true;
        }
      }

      // If updateFileMeta is true and we updated the maxId, also update FileMeta
      // This ensures cache consistency and prevents unnecessary recalculations
      if (updateFileMeta && shouldUpdate) {
        try {
          final fileMeta = await getTableMeta(tableName);
          if (fileMeta != null) {
            final updatedMeta = fileMeta.copyWith(maxAutoIncrementId: idStr);
            await updateTableMeta(tableName, updatedMeta);
          }
        } catch (e) {
          Logger.error('Failed to update FileMeta maxAutoIncrementId: $e',
              label: 'TableDataManager.updateMaxIdInMemory');
        }
      }
    } catch (e) {
      Logger.error('Failed to update max ID: $e, tableName=$tableName, id=$id',
          label: 'TableDataManager.updateMaxIdInMemory');
    }
  }

  /// Get next auto-increment ID
  Future<String> getNextId(String tableName) async {
    try {
      // Get table schema
      final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
      if (schema == null) {
        Logger.error('Table schema is null, cannot get next id',
            label: 'TableDataManager.getNextId');
        return '';
      }
      // Check if initialization of auto-increment ID is needed for the table (lazy loading)
      if (schema.primaryKeyConfig.type == PrimaryKeyType.sequential &&
          !_maxIds.containsKey(tableName)) {
        // Load auto-increment ID value only when first used (lock is already held)
        await _updateMaxIdFromTableInternal(tableName);
      }

      // Get ID generator
      final generator = await _getIdGenerator(tableName);

      // Use ID pool optimization - batch generation method is implemented internally
      final ids = await generator.getId(1);
      if (ids.isEmpty) {
        throw Exception('Failed to generate ID, returned empty list');
      }

      // If it's a sequential increment type, update max ID value
      if (schema.primaryKeyConfig.type == PrimaryKeyType.sequential) {
        await updateMaxIdInMemory(tableName, ids.first);
      }

      // Save ID range (if needed)
      await _saveIdRange(tableName);

      return ids.first;
    } catch (e) {
      Logger.error('Failed to get next ID: $e',
          label: 'TableDataManager.getNextId');
      return '';
    }
  }

  /// Get batch of IDs (used for optimizing bulk insert scenarios)
  Future<List<String>> getBatchIds(String tableName, int count) async {
    try {
      if (count <= 0) return [];

      // Get table schema
      final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
      if (schema == null) {
        return [];
      }
      // Check if initialization of auto-increment ID is needed for the table (lazy loading)
      if (schema.primaryKeyConfig.type == PrimaryKeyType.sequential &&
          !_maxIds.containsKey(tableName)) {
        // Load auto-increment ID value only when first used (lock is already held)
        await _updateMaxIdFromTableInternal(tableName);
      }

      // Get ID generator
      final generator = await _getIdGenerator(tableName);

      // Get IDs directly in batch
      final ids = await generator.getId(count);

      // If it's a sequential increment type, update max ID value
      if (schema.primaryKeyConfig.type == PrimaryKeyType.sequential &&
          ids.isNotEmpty) {
        await updateMaxIdInMemory(tableName, ids.last);
      }

      // Save ID range (if needed)
      await _saveIdRange(tableName);

      return ids;
    } catch (e) {
      Logger.error('Failed to get batch of IDs: $e',
          label: 'TableDataManager.getBatchIds');
      return [];
    }
  }

  /// Remove scheduled task when instance is closed
  Future<void> dispose({bool persistChanges = true}) async {
    CrontabManager.removeCallback(
        ExecuteInterval.seconds3, TimeBasedIdGenerator.periodicPoolCheck);

    try {
      if (persistChanges) {
        // Persist runtime metadata (max IDs, statistics) one last time.
        await persistRuntimeMetaIfNeeded(force: true);
      }

      // Clear table record cache.
      clearAllTableRecordCacheSync();
      // cleanup file size information
      clearFileSizes();

      // cleanup table meta cache
      clearTableMetaCacheSync();

      _maxIdsDirty.clear();

      // Save ID range information for all tables
      final idGenKeys = List<String>.from(_idGenerators.keys);
      final yieldController = YieldController('TableDataManager.dispose');
      for (final tableName in idGenKeys) {
        await yieldController.maybeYield();
        await _saveIdRange(tableName);
      }

      // Cleanup ID generator resources
      _idGenerators.clear();
      _idGeneratorPending.clear();
      _idRanges.clear();
      _checkedOrderedRange.clear();
      _maxIds.clear();

      // Ensure processing flags are cleared
      _processingTables.clear();
    } catch (e) {
      Logger.error('Failed to dispose TableDataManager: $e',
          label: 'TableDataManager.dispose');
    } finally {}
  }

  /// Flush max IDs to disk
  Future<void> flushMaxIds() async {
    try {
      if (_maxIdsDirty.isEmpty) return;
      final yieldController = YieldController('TableDataManager.flushMaxIds');
      for (final entry in _maxIdsDirty.entries.toList()) {
        await yieldController.maybeYield();
        if (!entry.value) continue; // Skip unchanged

        final tableName = entry.key;
        final maxId = _maxIds[tableName];
        if (maxId == null) continue;

        // Save to FileMeta
        final fileMeta = await getTableMeta(tableName);
        if (fileMeta != null) {
          final updatedMeta = fileMeta.copyWith(maxAutoIncrementId: maxId);
          await updateTableMeta(tableName, updatedMeta);
        }

        _maxIdsDirty[tableName] = false;
      }
    } catch (e) {
      Logger.error('Failed to flush max IDs: $e',
          label: 'TableDataManager.flushMaxIds');
    }
  }

  /// Get partition size limit for a table
  int _getPartitionSizeLimit(String tableName) {
    // If table has specific partition size configuration, use it
    if (_tablePartitionSizes.containsKey(tableName)) {
      final configuredSize = _tablePartitionSizes[tableName]!;

      // Ensure configured partition size doesn't exceed system maximum
      final systemMax = _dataStore.config.maxPartitionFileSize;
      if (configuredSize > systemMax) {
        Logger.warn(
          'Table $tableName configured partition size ${configuredSize ~/ 1024}KB exceeds system limit ${systemMax ~/ 1024}KB, will use system limit',
          label: 'TableDataManager._getPartitionSizeLimit',
        );
        return systemMax;
      }

      // Ensure partition size has a reasonable minimum value
      const minSize = 10 * 1024; // 10KB
      if (configuredSize < minSize) {
        Logger.warn(
          'Table $tableName configured partition size ${configuredSize ~/ 1024}KB is too small, will use minimum value ${minSize ~/ 1024}KB',
          label: 'TableDataManager._getPartitionSizeLimit',
        );
        return minSize;
      }

      return configuredSize;
    }

    // Otherwise return default value from DataStoreConfig
    return _dataStore.config.maxPartitionFileSize;
  }

  /// Set partition size limit for a table
  void setTablePartitionSize(String tableName, int sizeInBytes) {
    if (sizeInBytes <= 0) {
      Logger.warn(
        'Attempted to set partition size for table $tableName to $sizeInBytes, invalid value, will use default',
        label: 'TableDataManager.setTablePartitionSize',
      );
      _tablePartitionSizes
          .remove(tableName); // Remove invalid config, use default
      return;
    }

    _tablePartitionSizes[tableName] = sizeInBytes;

    // Log configuration change
    Logger.debug(
      'Set partition size for table $tableName to ${sizeInBytes ~/ 1024}KB',
      label: 'TableDataManager.setTablePartitionSize',
    );
  }

  /// Get partition size limit for a table (public method)
  int getTablePartitionSize(String tableName) {
    return _getPartitionSizeLimit(tableName);
  }

  /// Add record to buffer
  Future<void> addToBuffer(
    String tableName,
    Map<String, dynamic> data,
    BufferOperationType operationType, {
    List<UniqueKeyRef>? uniqueKeyRefs,
    Map<String, dynamic>? oldValues,
    String? transactionId,
  }) async {
    final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
    if (schema == null) {
      Logger.error('Table schema is null, cannot add to buffer',
          label: 'TableDataManager.addToBuffer');
      return;
    }
    final primaryKey = schema.primaryKey;
    final recordId = data[primaryKey]?.toString();
    if (recordId == null) {
      Logger.error(
        'Record in table $tableName does not have a primary key value, cannot add to buffer',
        label: 'TableDataManager.addToBuffer',
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
          byTable.putIfAbsent(tableName, () => <String, TxnDeferredOp>{});

      final rec = Map<String, dynamic>.from(data);

      // Handle insert-then-update in same transaction: merge operations correctly.
      final existingOp = map[recordId];
      Map<String, dynamic>? mergedOldValues = oldValues;
      BufferOperationType finalOpType = operationType;
      Map<String, dynamic> finalData = rec;

      if (existingOp != null) {
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
        }
        // For other combinations, use the latest operation.
      }

      // We already checked recordId is not null above
      map[recordId] = TxnDeferredOp(
        finalOpType,
        finalData,
        uniqueKeyRefs: uniqueKeyRefs,
        oldValues: mergedOldValues,
      );

      // Register unique keys with WriteBufferManager for conflict detection
      if (uniqueKeyRefs != null && uniqueKeyRefs.isNotEmpty) {
        final pkVal = rec[schema.primaryKey]?.toString();
        if (pkVal != null) {
          _dataStore.writeBufferManager.addTransactionUniqueKeys(
            transactionId: currentTxId,
            tableName: tableName,
            recordId: pkVal,
            uniqueKeys: uniqueKeyRefs,
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
      'table': tableName,
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
            finalOperation == BufferOperationType.update ? oldValues : null);

    // Enqueue into write buffer/queue (in-memory)
    await _dataStore.writeBufferManager.addRecord(
      tableName: tableName,
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
          tableName,
          recordId,
          indexOldData,
          indexNewData,
        );
      }
    }

    // Sync to TableRecordCache
    if (finalOperation == BufferOperationType.delete) {
      removeTableRecord(tableName, recordId);
    } else if (finalOperation == BufferOperationType.update) {
      cacheTableRecord(tableName, recordId, bufferedData, schema);
    }

    // Statistics
    _needSaveStats = true;
  }

  /// High-performance batch insert into WAL + write buffer.
  ///
  /// This is the core hot path used by `DataStoreImpl.batchInsert`.
  /// It avoids per-record schema lookups, per-record record-count awaits, and per-record cache puts.
  ///
  /// Returns per-record success/failure recordIds (primary keys as strings).
  Future<({List<String> successRecordIds, List<String> failedRecordIds})>
      addInsertBatchToBuffer(
    String tableName,
    List<Map<String, dynamic>> records, {
    required TableSchema schema,
    required List<List<UniqueKeyRef>> uniqueKeyRefsList,
    DateTime? timestamp,
  }) async {
    if (records.isEmpty) {
      return (
        successRecordIds: const <String>[],
        failedRecordIds: const <String>[],
      );
    }

    if (records.length != uniqueKeyRefsList.length) {
      throw ArgumentError(
          'records and uniqueKeyRefsList length mismatch: ${records.length} vs ${uniqueKeyRefsList.length}');
    }

    final pkName = schema.primaryKey;

    // Transaction-aware interception (consistent with addToBuffer()).
    final String? currentTxId = TransactionContext.getCurrentTransactionId();
    final bool applyingCommit = TransactionContext.isApplyingCommit();

    if (currentTxId != null && !applyingCommit) {
      final byTable = _txnDeferredOps.putIfAbsent(
          currentTxId, () => <String, Map<String, TxnDeferredOp>>{});
      final map =
          byTable.putIfAbsent(tableName, () => <String, TxnDeferredOp>{});

      final success = <String>[];
      final failed = <String>[];

      final yieldController =
          YieldController('TableDataManager.addInsertBatchToBuffer.tx');

      for (int i = 0; i < records.length; i++) {
        await yieldController.maybeYield();
        final r = records[i];
        final recordId = r[pkName]?.toString();
        if (recordId == null || recordId.isEmpty) {
          // Cannot report failed key reliably here.
          continue;
        }

        try {
          final rec = Map<String, dynamic>.from(r);
          final uniqueRefs = uniqueKeyRefsList[i];
          map[recordId] = TxnDeferredOp(
            BufferOperationType.insert,
            rec,
            uniqueKeyRefs: uniqueRefs,
          );

          // Register unique keys with WriteBufferManager for cross-txn conflict detection.
          if (uniqueRefs.isNotEmpty) {
            _dataStore.writeBufferManager.addTransactionUniqueKeys(
              transactionId: currentTxId,
              tableName: tableName,
              recordId: recordId,
              uniqueKeys: uniqueRefs,
            );
          }

          success.add(recordId);
        } catch (e) {
          Logger.warn(
            'Failed to register txn deferred insert for $tableName pk=$recordId: $e',
            label: 'TableDataManager.addInsertBatchToBuffer.tx',
          );
          failed.add(recordId);
        }
      }

      return (successRecordIds: success, failedRecordIds: failed);
    }

    // WAL + write buffer path (non-transactional or applying commit)
    final DateTime ts = timestamp ?? DateTime.now();
    final String tsIso = ts.toIso8601String();

    final successIds = <String>[];
    final failedIds = <String>[];

    // Prepare arrays for single buffer enqueue pass
    final recordIds = <String>[];
    final entries = <BufferEntry>[];
    final uniqueKeysList = <List<UniqueKeyRef>>[];
    final recordsForCache = <Map<String, dynamic>>[];

    final yieldController =
        YieldController('TableDataManager.addInsertBatchToBuffer');

    // Reuse a single WAL entry map to avoid 10k+ map allocations.
    // Safe because WalManager.append() defensively copies the map.
    final baseWalEntry = <String, dynamic>{
      'op': BufferOperationType.insert.index,
      'table': tableName,
      'ts': tsIso,
      if (currentTxId != null) 'txId': currentTxId,
    };

    for (int i = 0; i < records.length; i++) {
      await yieldController.maybeYield();
      final r = records[i];
      final recordId = r[pkName]?.toString();
      if (recordId == null || recordId.isEmpty) {
        continue;
      }

      try {
        baseWalEntry['data'] = r;
        final walPointer = await _dataStore.walManager.append(baseWalEntry);

        entries.add(BufferEntry(
          data: r,
          operation: BufferOperationType.insert,
          timestamp: ts,
          transactionId: currentTxId,
          walPointer: walPointer,
          oldValues: null,
        ));
        recordIds.add(recordId);
        uniqueKeysList.add(uniqueKeyRefsList[i]);
        recordsForCache.add(r);
      } catch (e) {
        Logger.warn(
          'Batch insert WAL append failed: table=$tableName pk=$recordId error=$e',
          label: 'TableDataManager.addInsertBatchToBuffer',
        );
        failedIds.add(recordId);
      }
    }

    if (recordIds.isNotEmpty) {
      await _dataStore.writeBufferManager.addInsertBatch(
        tableName: tableName,
        recordIds: recordIds,
        entries: entries,
        uniqueKeysList: uniqueKeysList,
      );
      successIds.addAll(recordIds);
      _needSaveStats = true;
    }

    return (successRecordIds: successIds, failedRecordIds: failedIds);
  }

  /// Update the record count cache based on the operation.
  Future<void> updateTableRecordCount(
      String tableName, BufferOperationType op) async {
    // Ensure loaded first so we start from a valid base
    await _ensureRecordCountLoaded(tableName);

    if (op == BufferOperationType.insert) {
      _tableRecordCounts[tableName] = (_tableRecordCounts[tableName] ?? 0) + 1;
      _totalRecordCount++;
      _needSaveStats = true;
    } else if (op == BufferOperationType.delete) {
      final current = _tableRecordCounts[tableName] ?? 0;
      if (current > 0) {
        _tableRecordCounts[tableName] = current - 1;
        _totalRecordCount = max(0, _totalRecordCount - 1);
        _needSaveStats = true;
      }
    }
  }

  /// Batch update record count cache with a single await.
  ///
  /// This is optimized for large batch operations (e.g. batchInsert) to avoid
  /// 10k+ awaited calls to [updateTableRecordCount].
  Future<void> updateTableRecordCountDelta(
    String tableName, {
    int insertDelta = 0,
    int deleteDelta = 0,
  }) async {
    final int delta = insertDelta - deleteDelta;
    if (delta == 0) return;

    await _ensureRecordCountLoaded(tableName);

    final current = _tableRecordCounts[tableName] ?? 0;
    _tableRecordCounts[tableName] = max(0, current + delta);
    _totalRecordCount = max(0, _totalRecordCount + delta);
    _needSaveStats = true;
  }

  /// Add records to delete buffer - for batch deleting
  Future<void> addToDeleteBuffer(
      String tableName, List<Map<String, dynamic>> records) async {
    if (records.isEmpty) return;

    final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
    if (schema == null) {
      Logger.error('Table schema is null, cannot add to delete buffer',
          label: 'TableDataManager.addToDeleteBuffer');
      return;
    }

    final primaryKey = schema.primaryKey;
    // For deletes, keep WAL payload minimal: pk + index/unique fields
    final Set<String> needFields = () {
      final s = <String>{primaryKey};
      // Collect all fields used in any index (auto-generated unique/fk or explicit)
      for (final idx in schema.getAllIndexes()) {
        s.addAll(idx.fields);
      }
      return s;
    }();

    final yieldController =
        YieldController('TableDataManager.addToDeleteBuffer');
    for (final record in records) {
      await yieldController.maybeYield();
      final recordId = record[primaryKey]?.toString();
      if (recordId == null) {
        Logger.warn(
          'Record in table $tableName does not have a primary key value, skipping',
          label: 'TableDataManager.addToDeleteBuffer',
        );
        continue;
      }

      // Trim record to required fields to reduce WAL footprint.
      final trimmed = <String, dynamic>{};
      for (final k in needFields) {
        if (record.containsKey(k)) {
          trimmed[k] = record[k];
        }
      }

      await addToBuffer(
        tableName,
        trimmed,
        BufferOperationType.delete,
      );
    }

    // Record data change, need to update statistics
    _needSaveStats = true;
  }

  /// Recover a record from WAL/Journal to buffer.
  ///
  /// This ensures:
  /// 1. Record is added to WriteBufferManager (queue + stats).
  /// 2. Record is added to hot cache (force=true) to ensure immediate consistency.
  /// 3. MaxID is updated in memory to restore auto-increment sequence.
  Future<void> recoverRecordToBuffer(
    String tableName,
    Map<String, dynamic> data,
    BufferOperationType operationType, {
    required BufferEntry entry,
    List<UniqueKeyRef>? uniqueKeyRefs,
    Map<String, dynamic>? oldValues,
    bool updateStats = true,
  }) async {
    final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
    if (schema == null) return;

    final primaryKey = schema.primaryKey;
    final recordId = data[primaryKey]?.toString();
    if (recordId == null) return;

    // 1. Add to WriteBufferManager (reconstructs queue state)
    // We bypass the standard addToBuffer/batchInsert path to inject the *exact*
    // original WAL entry (preserving timestamp, walPointer, etc.)
    await _dataStore.writeBufferManager.addRecord(
      tableName: tableName,
      recordId: recordId,
      entry: entry, // Use the recovered entry directly
      uniqueKeys: uniqueKeyRefs ?? const <UniqueKeyRef>[],
      updateStats: updateStats,
    );
  }

  /// get total table count
  int getTotalTableCount() {
    return _totalTableCount;
  }

  /// get total record count
  int getTotalRecordCount() {
    return _totalRecordCount;
  }

  /// get total data size (bytes)
  int getTotalDataSizeBytes() {
    return _totalDataSizeBytes;
  }

  /// mark stats data need to be updated
  void markStatsDirty() {
    _needSaveStats = true;
  }

  /// table created, update stats
  /// Only counts user tables, excluding system tables
  void tableCreated(String tableName) {
    // Only count user tables, exclude system tables
    if (!SystemTable.isSystemTable(tableName)) {
      _totalTableCount++;
      markStatsDirty();
    }
  }

  /// table deleted, update stats
  /// Only counts user tables, excluding system tables
  Future<void> tableDeleted(String tableName) async {
    try {
      // Only update stats for user tables, exclude system tables
      if (!SystemTable.isSystemTable(tableName)) {
        // get current table stats
        final meta = await getTableMeta(tableName);
        if (meta != null) {
          // update total record count and total size
          _totalRecordCount = max(0, _totalRecordCount - meta.totalRecords);
          _totalDataSizeBytes =
              max(0, _totalDataSizeBytes - meta.totalSizeInBytes);
        }

        // update table count
        _totalTableCount = max(0, _totalTableCount - 1);

        // Remove record count cache
        _tableRecordCounts.remove(tableName);

        markStatsDirty();
      }
    } catch (e) {
      Logger.error('Failed to update table deleted stats: $e',
          label: 'TableDataManager.tableDeleted');
    }
  }

  /// Ensure the record count for [tableName] is loaded into cache.
  /// Uses loading lock pattern to prevent thundering herd when many
  /// concurrent inserts happen for the same table.
  Future<void> _ensureRecordCountLoaded(String tableName) async {
    // Fast path: already cached
    if (_tableRecordCounts.containsKey(tableName)) return;

    // Check if another call is already loading this table
    final existing = _recordCountLoadingFutures[tableName];
    if (existing != null) {
      await existing;
      return;
    }

    // Start loading and register the future
    final loadFuture = _doLoadRecordCount(tableName);
    _recordCountLoadingFutures[tableName] = loadFuture;
    try {
      await loadFuture;
    } finally {
      _recordCountLoadingFutures.remove(tableName);
    }
  }

  /// Internal helper to actually load record count from metadata.
  Future<void> _doLoadRecordCount(String tableName) async {
    final meta = await getTableMeta(tableName);
    _tableRecordCounts[tableName] = meta?.totalRecords ?? 0;
  }

  /// get table record count by table name
  Future<int> getTableRecordCount(String tableName) async {
    // Ensure cache is populated
    await _ensureRecordCountLoaded(tableName);

    int count = _tableRecordCounts[tableName] ?? 0;

    // Transaction overlay: include deferred inserts/deletes (read-your-writes) for current tx.
    // Skip during applyCommit to avoid double counting when promotion already enters WAL/buffer.
    final String? txId = TransactionContext.getCurrentTransactionId();
    if (txId != null && !TransactionContext.isApplyingCommit()) {
      final defOps = _txnDeferredOps[txId]?[tableName];
      if (defOps != null && defOps.isNotEmpty) {
        try {
          final schema =
              await _dataStore.schemaManager?.getTableSchema(tableName);
          final pkName = schema?.primaryKey;
          if (pkName != null && pkName.isNotEmpty) {
            // Track unique primary keys to avoid double counting the same record.
            final inserted = <String>{};
            final yieldController =
                YieldController('TableDataManager.getTableRecordCount');

            // defOps is Map<String, TxnDeferredOp>
            // We just need to tally inserts - deletes
            // Since Map already deduplicates by PK for the txn, we just iterate values.
            final deleted = <String>{};

            for (final op in defOps.values) {
              await yieldController.maybeYield();
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

  /// get table file size
  Future<int> getTableFileSize(String tableName) async {
    if (!_fileSizes.containsKey(tableName)) {
      final meta = await getTableMeta(tableName);
      return meta?.totalSizeInBytes ?? 0;
    }
    return _fileSizes[tableName] ?? 0;
  }

  /// update table file size and modified time
  Future<void> updateFileSize(String tableName, int size) async {
    _fileSizes[tableName] = size;
    _lastModifiedTimes[tableName] = DateTime.now();
  }

  /// check if file is modified
  bool isFileModified(String tableName, DateTime lastReadTime) {
    final lastModified = _lastModifiedTimes[tableName];
    return lastModified == null || lastModified.isAfter(lastReadTime);
  }

  /// get file last modified time
  DateTime? getLastModifiedTime(String tableName) {
    return _lastModifiedTimes[tableName];
  }

  /// cleanup table size information
  void clearFileSizes() {
    _fileSizes.clear();
    _lastModifiedTimes.clear();
  }

  /// Get table meta information
  Future<TableMeta?> getTableMeta(String tableName) async {
    // Table meta cache fast path
    final cached = _tableMetaCache.get(tableName);
    if (cached != null) return cached;

    // Check if another call is already loading this meta
    final existingFuture = _metaLoadingFutures[tableName];
    if (existingFuture != null) {
      return existingFuture;
    }

    // Load from disk with future tracking
    final loadFuture = _doLoadTableMeta(tableName);
    _metaLoadingFutures[tableName] = loadFuture;

    try {
      return await loadFuture;
    } finally {
      // Clean up future after completion
      if (_metaLoadingFutures[tableName] == loadFuture) {
        _metaLoadingFutures.remove(tableName);
      }
    }
  }

  /// Internal method to perform the actual file load
  Future<TableMeta?> _doLoadTableMeta(String tableName) async {
    try {
      final mainFilePath =
          await _dataStore.pathManager.getDataMetaPath(tableName);
      if (!await _dataStore.storage.existsFile(mainFilePath)) {
        return null;
      }
      try {
        final decodedString =
            await _dataStore.storage.readAsString(mainFilePath);
        if (decodedString == null) {
          Logger.error("Failed to decode file meta: $mainFilePath",
              label: 'TableDataManager.getTableMeta');
          return null;
        }

        // parse JSON
        Map<String, dynamic> jsonData;
        try {
          jsonData = jsonDecode(decodedString) as Map<String, dynamic>;
        } catch (e) {
          Logger.error(
              "Failed to parse JSON meta: $e\ncontent: ${decodedString.substring(0, min(100, decodedString.length))}...",
              label: 'TableDataManager.getTableMeta');
          return null;
        }

        final meta = TableMeta.fromJson(jsonData);
        // Cache update
        _tableMetaCache.put(tableName, meta);
        return meta;
      } catch (e) {
        Logger.error('Failed to parse table meta: $e',
            label: 'TableDataManager.getTableMeta');
        return null; // Return null on parse error
      }
    } catch (e) {
      Logger.error('Failed to get table meta: $e',
          label: 'TableDataManager.getTableMeta');
      rethrow;
    }
  }

  /// Update table meta
  Future<void> updateTableMeta(String tableName, TableMeta meta,
      {bool flush = true}) async {
    final mainFilePath =
        await _dataStore.pathManager.getDataMetaPath(tableName);

    // Create directory if not exists
    final partitionsDir =
        await _dataStore.pathManager.getPartitionsDirPath(tableName);
    await _ensureDirectoryExists(partitionsDir);

    try {
      // Update meta cache in memory first so subsequent reads see latest value.
      _tableMetaCache.put(
        tableName,
        meta,
        size: _estimateTableMetaSize(meta),
      );
      _lastModifiedTimes[tableName] = DateTime.now();

      // then write to file
      await _dataStore.storage
          .writeAsString(mainFilePath, jsonEncode(meta.toJson()), flush: flush);
    } catch (e) {
      Logger.error('Failed to update table meta: $e',
          label: 'TableDataManager.updateTableMeta');
      // Re-throw to handle at higher level
      rethrow;
    }

    // update file size
    updateFileSize(tableName, meta.totalSizeInBytes);
  }

  /// Ensure directory exists
  Future<void> _ensureDirectoryExists(String path) async {
    await _dataStore.storage.ensureDirectoryExists(path);
  }

  /// Get id generator, create if not exists. Single instance per table under concurrency.
  Future<IdGenerator> _getIdGenerator(String tableName) async {
    final cached = _idGenerators[tableName];
    if (cached != null) return cached;

    final pending = _idGeneratorPending[tableName];
    if (pending != null) return await pending;

    final future = _createIdGeneratorForTable(tableName);
    _idGeneratorPending[tableName] = future;
    try {
      final generator = await future;
      _idGenerators[tableName] = generator;
      return generator;
    } finally {
      _idGeneratorPending.remove(tableName);
    }
  }

  /// Create and initialize id generator for a table (single creation per table under concurrency).
  Future<IdGenerator> _createIdGeneratorForTable(String tableName) async {
    try {
      final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
      if (schema == null) {
        throw Exception('Table schema is null, cannot get batch ids');
      }

      final generator = IdGeneratorFactory.createGenerator(
        schema,
        _dataStore.config,
        centralClient: _centralClient,
      );

      if (generator is SequentialIdGenerator) {
        final currentId = _maxIds[tableName];

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
                'Failed to set id generator current value: $e, value=$currentId',
                label: 'TableDataManager._createIdGeneratorForTable');
          }
        } else {
          final initialValue =
              schema.primaryKeyConfig.sequentialConfig?.initialValue ?? 1;
          generator.setCurrentId(initialValue - 1);
        }
        if (_idRanges.containsKey(tableName)) {
          final rangeInfo = _idRanges[tableName];
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
              Logger.error('Failed to set id generator range: $e',
                  label: 'TableDataManager._createIdGeneratorForTable');
            }
          }
        }
      }

      return generator;
    } catch (e) {
      Logger.error(
        'Failed to get id generator: $e',
        label: 'TableDataManager._createIdGeneratorForTable',
      );
      const defaultConfig = SequentialIdConfig();
      final defaultGenerator =
          SequentialIdGenerator(defaultConfig, tableName: tableName);
      _idGenerators[tableName] = defaultGenerator;
      return defaultGenerator;
    }
  }

  /// save id range info
  Future<void> _saveIdRange(String tableName) async {
    final generator = _idGenerators[tableName];
    if (generator is SequentialIdGenerator && generator.isDistributed) {
      // get current max id value
      final currentMaxId = _maxIds[tableName];

      if (currentMaxId == null) return;

      // all ids use string type
      final maxIdStr = currentMaxId.toString();

      // if max id is numeric string, use generator's current id for persistence
      if (_isNumericString(maxIdStr)) {
        try {
          final currentIdInt = generator.currentId;

          // save as string type
          _idRanges[tableName] = {
            'current': currentIdInt.toString(),
            'max': maxIdStr,
          };
        } catch (e) {
          Logger.error(
              'Failed to save id range: cannot parse string id to integer: $e',
              label: 'TableDataManager._saveIdRange');
        }
      } else {
        // non-numeric string id, save current value directly
        _idRanges[tableName] = {
          'current': maxIdStr,
          'max': maxIdStr,
        };
      }
    }
  }

  /// update max id from table meta
  /// Update max auto-increment ID from table partitions and buffer
  /// This method calculates the maximum ID from:
  /// 1. Partition metadata (fast path for ordered partitions: O(1), fallback: O(n))
  /// 2. Buffered inserts in memory (from WAL recovery)
  /// 3. Schema-defined initial value if table is empty
  ///
  /// [forceRecalculate] if true, forces recalculation even if cache matches
  Future<void> updateMaxIdFromTable(String tableName,
      {bool forceRecalculate = false}) async {
    final lockKey = 'id_gen_$tableName';
    final operationId = GlobalIdGenerator.generate('update_max_id_');
    bool acquired = await (_dataStore.lockManager
            ?.acquireExclusiveLock(lockKey, operationId) ??
        Future.value(false));
    try {
      await _updateMaxIdFromTableInternal(tableName,
          forceRecalculate: forceRecalculate);
    } finally {
      if (acquired) {
        _dataStore.lockManager?.releaseExclusiveLock(lockKey, operationId);
      }
    }
  }

  /// Internal version of updateMaxIdFromTable that assumes id_gen_$tableName lock is already held
  Future<void> _updateMaxIdFromTableInternal(String tableName,
      {bool forceRecalculate = false}) async {
    try {
      final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
      if (schema == null) {
        Logger.error('Table schema is null, cannot update max id',
            label: 'TableDataManager.updateMaxIdFromTable');
        return;
      }
      // handle sequential primary key
      if (schema.primaryKeyConfig.type != PrimaryKeyType.sequential) {
        return;
      }

      // get max id from table meta + buffered WAL (if any)
      TableMeta? fileMeta = await getTableMeta(tableName);

      // Performance optimization: if maxId is already in memory and matches FileMeta cache,
      // skip recalculation (especially useful after recovery when maxId was already updated)
      // However, if forceRecalculate is true, skip this check to ensure we include partition data
      if (!forceRecalculate &&
          _maxIds.containsKey(tableName) &&
          fileMeta?.maxAutoIncrementId != null) {
        final cachedMaxId = _maxIds[tableName];
        final fileMetaMaxId = fileMeta!.maxAutoIncrementId;
        if (cachedMaxId == fileMetaMaxId) {
          // Cache is valid, no need to recalculate
          return;
        }
      }

      dynamic maxFromPartitions;
      final pkMatcher =
          ValueMatcher.getMatcher(schema.getPrimaryKeyMatcherType());

      // v2+ global B+Tree: take max key from the global leaf tail (O(logN)+O(1) IO).
      if (fileMeta != null) {
        try {
          final last = await _dataStore.tableTreePartitionManager
              .scanRecordsByPrimaryKeyRange(
            tableName: tableName,
            startKeyInclusive: Uint8List(0),
            endKeyExclusive: Uint8List(0),
            reverse: true,
            limit: 1,
          );
          if (last.isNotEmpty) {
            maxFromPartitions = last.first[schema.primaryKey];
          }
        } catch (_) {}
      }

      // Also consider buffered inserts recovered from WAL (in-memory buffer)
      dynamic maxFromBuffer;
      try {
        maxFromBuffer = _dataStore.writeBufferManager
            .getMaxPrimaryKey(tableName, schema.primaryKey, pkMatcher);
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
      final currentMemoryMax = _maxIds[tableName];
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
        _maxIds[tableName] = finalMax.toString();
        _maxIdsDirty[tableName] = true;

        // Save to FileMeta for caching (avoid recalculation on next initialization)
        if (fileMeta != null) {
          fileMeta = fileMeta.copyWith(maxAutoIncrementId: finalMax.toString());
          await updateTableMeta(tableName, fileMeta);
        }
        return;
      }

      // If table and buffer are empty, initialize maxAutoIncrementId to "0".
      const emptyMaxIdStr = '0';
      _maxIds[tableName] = emptyMaxIdStr;
      _maxIdsDirty[tableName] = true;
      if (fileMeta != null) {
        fileMeta = fileMeta.copyWith(maxAutoIncrementId: emptyMaxIdStr);
        await updateTableMeta(tableName, fileMeta);
      }
    } catch (e) {
      Logger.error(
        'Failed to update max id for table $tableName: $e',
        label: 'TableDataManager.updateMaxIdFromTable',
      );
    }
  }

  /// handle primary key conflict when updating max id
  /// Reuses updateMaxIdFromTable to get the accurate max ID, then adjusts based on conflict
  Future<void> handlePrimaryKeyConflict(
      String tableName, dynamic conflictId) async {
    try {
      final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
      if (schema == null) return;

      // Ensure max ID is loaded and up-to-date by recalculating from partitions and buffer
      await updateMaxIdFromTable(tableName, forceRecalculate: true);

      // get current max id
      final currentMaxId = _maxIds[tableName];
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

        _maxIds[tableName] = newMaxId;
        _maxIdsDirty[tableName] = true;

        // Save to FileMeta instead of standalone file
        final fileMeta = await getTableMeta(tableName);
        if (fileMeta != null) {
          final updatedMeta = fileMeta.copyWith(maxAutoIncrementId: newMaxId);
          await updateTableMeta(tableName, updatedMeta);
        }

        Logger.warn(
          'Table $tableName has primary key conflict, update auto increment start: $newMaxId',
          label: 'TableDataManager.handlePrimaryKeyConflict',
        );

        // update generator current id (only for numeric id)
        if (_idGenerators.containsKey(tableName)) {
          final generator = _idGenerators[tableName];
          if (generator is SequentialIdGenerator &&
              _isNumericString(newMaxId)) {
            try {
              final newIdInt = int.parse(newMaxId);
              generator.setCurrentId(newIdInt);
            } catch (e) {
              Logger.error('Failed to parse new id to integer: $newMaxId',
                  label: 'TableDataManager.handlePrimaryKeyConflict');
            }
          }
        }
      } else {
        // if current id is greater than conflict id, no need to adjust
        Logger.debug(
          'Table $tableName has primary key conflict, but current max id $currentMaxId is greater than conflict id $conflictId, no need to adjust',
          label: 'TableDataManager.handlePrimaryKeyConflict',
        );
      }
    } catch (e) {
      Logger.error(
        'Failed to handle primary key conflict: $e',
        label: 'TableDataManager.handlePrimaryKeyConflict',
      );
    }
  }

  /// Stream records from a table using global B+Tree leaf chain traversal.
  /// This method efficiently streams all records while overlaying buffer and transaction data.
  Stream<Map<String, dynamic>> streamRecords(String tableName,
      {Uint8List? customKey, int? customKeyId}) async* {
    final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
    if (schema == null) {
      Logger.error('Failed to get schema for $tableName',
          label: 'TableDataManager.streamRecords');
      return;
    }
    final primaryKey = schema.primaryKey;

    final fileMeta = await getTableMeta(tableName);
    if (fileMeta == null || fileMeta.btreeFirstLeaf.isNull) {
      // Empty table or no B+Tree: only yield buffer/transaction data
      final yieldController =
          YieldController('TableDataManager.streamRecords_empty');
      final overlay = await mergeConsistency(
        tableName,
        [],
      );
      for (final r in overlay) {
        await yieldController.maybeYield();
        if (!isDeletedRecord(r)) yield r;
      }
      return;
    }

    final rangeManager = _dataStore.tableTreePartitionManager;
    final yieldController =
        YieldController('TableDataManager.streamRecords', checkInterval: 50);

    // Track keys we've already processed from file stream to avoid duplicate lookups
    final Set<String> processedKeys = <String>{};

    // Get current transaction ID for transaction overlay
    final String? currentTxId = TransactionContext.getCurrentTransactionId();

    // Register read view for consistent snapshot
    final viewId = _dataStore.readViewManager.registerReadView();
    try {
      // Stream from global B+Tree leaf chain
      await for (final record in rangeManager.streamRecordsByPrimaryKeyRange(
        tableName: tableName,
        startKeyInclusive: Uint8List(0), // Start from beginning
        endKeyExclusive: Uint8List(0), // No end limit
        reverse: false,
        limit: null,
        encryptionKey: customKey,
        encryptionKeyId: customKeyId,
      )) {
        await yieldController.maybeYield();

        final pk = record[primaryKey]?.toString();
        if (pk == null || pk.isEmpty) continue;

        // Mark this key as processed from file
        processedKeys.add(pk);

        // Check buffer for updates/deletes (O(1) lookup)
        final bufferEntry =
            _dataStore.writeBufferManager.getBufferedRecord(tableName, pk);
        if (bufferEntry != null) {
          if (bufferEntry.operation == BufferOperationType.delete) {
            // Deleted in buffer, skip
            continue;
          }
          // Updated in buffer, use buffer version
          if (!isDeletedRecord(bufferEntry.data)) {
            yield bufferEntry.data;
          }
          continue;
        }

        // Check transaction for updates/deletes (O(1) lookup)
        if (currentTxId != null) {
          final defOps = _txnDeferredOps[currentTxId]?[tableName];
          final txOp = defOps?[pk];
          if (txOp != null) {
            if (txOp.type == BufferOperationType.delete) {
              // Deleted in transaction, skip
              continue;
            }
            // Updated in transaction, use transaction version
            final txRecord = Map<String, dynamic>.from(txOp.data);
            txRecord.remove('_oldValues');
            if (!isDeletedRecord(txRecord)) {
              yield txRecord;
            }
            continue;
          }
        }

        // No buffer/transaction overlay, yield file record
        if (!isDeletedRecord(record)) {
          yield record;
        }
      }

      // After streaming file records, yield buffer/transaction inserts that weren't in file
      // Collect all buffer insert keys
      final bufferInsertKeys = _dataStore.writeBufferManager
          .getBufferedInsertKeys(tableName, reverse: false);

      // Process transaction inserts
      final Set<String> txInsertKeys = <String>{};
      if (currentTxId != null) {
        final defOps = _txnDeferredOps[currentTxId]?[tableName];
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

      // Yield buffer inserts that weren't processed from file
      for (final key in bufferInsertKeys) {
        if (processedKeys.contains(key)) {
          continue; // Already processed from file
        }

        await yieldController.maybeYield();

        // Check if shadowed by transaction DELETE
        bool shadowedByDelete = false;
        if (currentTxId != null) {
          final defOps = _txnDeferredOps[currentTxId]?[tableName];
          final txOp = defOps?[key];
          if (txOp != null && txOp.type == BufferOperationType.delete) {
            shadowedByDelete = true;
          }
        }
        if (shadowedByDelete) continue;

        final entry =
            _dataStore.writeBufferManager.getBufferedRecord(tableName, key);
        if (entry != null &&
            entry.operation != BufferOperationType.delete &&
            !isDeletedRecord(entry.data)) {
          yield entry.data;
        }
      }

      // Yield transaction inserts that weren't processed from file or buffer
      for (final key in txInsertKeys) {
        if (processedKeys.contains(key)) {
          continue; // Already processed from file
        }

        await yieldController.maybeYield();

        final defOps = _txnDeferredOps[currentTxId]?[tableName];
        final txOp = defOps?[key];
        if (txOp != null &&
            txOp.type != BufferOperationType.delete &&
            !isDeletedRecord(txOp.data)) {
          final txRecord = Map<String, dynamic>.from(txOp.data);
          txRecord.remove('_oldValues');
          yield txRecord;
        }
      }
    } finally {
      _dataStore.readViewManager.releaseReadView(viewId);
    }
  }

  /// Process table partitions with multiple operations at once
  /// Note: This method is used to directly modify partition data, if you need to read data while ensuring partition order, please use ParallelProcessor.execute
  ///
  /// [decodeSchema] - Optional schema to use for decoding records from partition files.
  /// If provided, uses this schema instead of current table schema.
  /// This is critical for migration scenarios where old data must be decoded
  /// using the old schema before applying schema changes.
  Future<void> processTablePartitions({
    required String tableName,
    TableSchema? decodeSchema,
    required Future<List<Map<String, dynamic>>> Function(
      List<Map<String, dynamic>> records,
      int partitionNo,
      ParallelController controller,
    ) processFunction,
    bool onlyRead =
        false, // if true, only read records from partitions, do not write records
    int? maxConcurrent,
    Uint8List? customKey,
    int? customKeyId,
    int?
        startPartitionNo, // Specify the start partition number (0-based) for processing
    List<int>?
        targetPartitionNos, // Optional: specific partition numbers to process
    ParallelController? controller,
    bool skipMaintenanceGlobalLock = false,
    String? largeDeleteOpId,
    String? largeUpdateOpId,
    Future<void> Function(int partitionNo)? onPartitionFlushed,
  }) async {
    // Serialize writes with table-level exclusive lock to avoid concurrent flush/writeRecords.
    // Read-only tasks are allowed to run concurrently (no exclusive locks).
    final lockKey = 'table_$tableName';
    final operationId = GlobalIdGenerator.generate('process_partitions_');
    bool lockAcquired = false;

    // Acquire global maintenance lock ONLY for write operations to keep journal batches consistent,
    // unless explicitly skipped (for large delete parallelization).
    final maintenanceLockKey = 'maintenance_process_partitions';
    final maintenanceOpId = GlobalIdGenerator.generate('maint_lock_');
    bool maintenanceLockAcquired = false;
    if (!onlyRead &&
        !skipMaintenanceGlobalLock &&
        _dataStore.lockManager != null) {
      maintenanceLockAcquired = await _dataStore.lockManager!
          .acquireExclusiveLock(maintenanceLockKey, maintenanceOpId);
      if (!maintenanceLockAcquired) {
        Logger.warn(
            'Another maintenance task is running, skipping processTablePartitions for $tableName',
            label: 'TableDataManager.processTablePartitions');
        return;
      }
    }

    try {
      // Acquire per-table exclusive lock ONLY for write operations.
      if (!onlyRead) {
        if (_dataStore.lockManager != null) {
          lockAcquired = await _dataStore.lockManager!
              .acquireExclusiveLock(lockKey, operationId);
          if (!lockAcquired) {
            Logger.warn(
                'Failed to acquire exclusive lock for processTablePartitions: $tableName',
                label: 'TableDataManager.processTablePartitions');
            return;
          }
          _processingTables.add(tableName);
        } else {
          if (_processingTables.contains(tableName)) {
            Logger.debug(
                'Table $tableName is being processed by another operation, skipping processTablePartitions',
                label: 'TableDataManager.processTablePartitions');
            return;
          }
          _processingTables.add(tableName);
        }
      }

      final meta = await getTableMeta(tableName);
      if (meta == null) return;

      final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
      if (schema == null) return;
      final primaryKey = schema.primaryKey;

      // partitions are physical shards: [0 .. btreePartitionCount-1]
      final int partitionCount = meta.btreePartitionCount;
      final List<int> allNos =
          List<int>.generate(partitionCount, (i) => i, growable: false);

      List<int> partitionNosToProcess;
      if (targetPartitionNos != null && targetPartitionNos.isNotEmpty) {
        // Use specified partition numbers, filtered to valid range
        partitionNosToProcess = targetPartitionNos
            .where((n) => n >= 0 && n < partitionCount)
            .toList(growable: false)
          ..sort();
      } else if (startPartitionNo != null && startPartitionNo >= 0) {
        // Start from specified partition number
        partitionNosToProcess =
            allNos.where((n) => n >= startPartitionNo).toList(growable: false);
      } else {
        // Process all partitions
        partitionNosToProcess = allNos;
      }

      final effectiveController = controller ?? ParallelController();
      final rangeManager = _dataStore.tableTreePartitionManager;
      final journaling = _dataStore.config.enableJournal && !onlyRead;
      final scheduler = _dataStore.workloadScheduler;

      // Helper: compute delta (inserts/updates/deletes) from records vs processed.
      void computeDelta(
        List<Map<String, dynamic>> records,
        List<Map<String, dynamic>> processed,
        List<Map<String, dynamic>> outInserts,
        List<Map<String, dynamic>> outUpdates,
        List<Map<String, dynamic>> outDeletes,
      ) {
        final originalByPk = <String, Map<String, dynamic>>{};
        for (final r in records) {
          final pk = r[primaryKey]?.toString();
          if (pk == null || pk.isEmpty) continue;
          originalByPk[pk] = r;
        }
        final processedPks = <String>{};
        for (final r in processed) {
          final pk = r[primaryKey]?.toString();
          if (pk == null || pk.isEmpty) continue;
          processedPks.add(pk);
          if (originalByPk.containsKey(pk)) {
            outUpdates.add(r);
          } else {
            outInserts.add(r);
          }
        }
        for (final e in originalByPk.entries) {
          if (!processedPks.contains(e.key)) outDeletes.add(e.value);
        }
      }

      if (onlyRead) {
        // Read-only: parallel load + process, no writeChanges, no journal batch.
        final capacity = scheduler.capacityTokens(WorkloadType.maintenance);
        var concurrency = max(1, min(capacity, partitionNosToProcess.length));
        if (maxConcurrent != null && maxConcurrent > 0) {
          concurrency = min(concurrency, maxConcurrent);
        }
        final tasks = <Future<void> Function()>[];
        for (final pNo in partitionNosToProcess) {
          tasks.add(() async {
            if (effectiveController.isStopped) return;
            final records = await rangeManager.loadPartitionDataByNo(
              tableName: tableName,
              partitionNo: pNo,
              encryptionKey: customKey,
              encryptionKeyId: customKeyId,
              decodeSchema: decodeSchema,
            );
            await processFunction(records, pNo, effectiveController);
          });
        }
        WorkloadLease? lease;
        try {
          lease = await scheduler.acquire(
            WorkloadType.maintenance,
            requestedTokens: concurrency,
            minTokens: 1,
            label: 'processTablePartitions.$tableName.readOnly',
          );
          await ParallelProcessor.execute<void>(
            tasks,
            concurrency: lease.asConcurrency(1),
            controller: effectiveController,
            label: 'processTablePartitions.$tableName',
            continueOnError: false,
          );
        } finally {
          lease?.release();
        }
        return;
      }

      // Write path: process in chunks; each chunk = one maintenance batch so
      // page redo is deleted and metadata advanced after each chunk.
      final yc = YieldController('TableDataManager.processTablePartitions',
          checkInterval: 100);
      for (int chunkStart = 0;
          chunkStart < partitionNosToProcess.length &&
              !effectiveController.isStopped;
          chunkStart += 3) {
        await yc.maybeYield();
        final chunkEnd = min(chunkStart + 3, partitionNosToProcess.length);
        final chunkPartitions =
            partitionNosToProcess.sublist(chunkStart, chunkEnd);

        BatchContext? batchContext;
        if (journaling) {
          batchContext = await _dataStore.parallelJournalManager
              .beginMaintenanceBatch(table: tableName);
        }

        final capacity = scheduler.capacityTokens(WorkloadType.maintenance);
        var concurrency = max(1, min(capacity, chunkPartitions.length));
        if (maxConcurrent != null && maxConcurrent > 0) {
          concurrency = min(concurrency, maxConcurrent);
        }
        final tasks = <Future<
                (
                  int,
                  List<Map<String, dynamic>>,
                  List<Map<String, dynamic>>,
                  List<Map<String, dynamic>>
                )?>
            Function()>[];
        for (final pNo in chunkPartitions) {
          tasks.add(() async {
            if (effectiveController.isStopped) return null;
            final records = await rangeManager.loadPartitionDataByNo(
              tableName: tableName,
              partitionNo: pNo,
              encryptionKey: customKey,
              encryptionKeyId: customKeyId,
              decodeSchema: decodeSchema,
            );
            final processed =
                await processFunction(records, pNo, effectiveController);
            if (effectiveController.isStopped) return null;
            final inserts = <Map<String, dynamic>>[];
            final updates = <Map<String, dynamic>>[];
            final deletes = <Map<String, dynamic>>[];
            computeDelta(records, processed, inserts, updates, deletes);
            if (inserts.isEmpty && updates.isEmpty && deletes.isEmpty) {
              return null;
            }
            return (pNo, inserts, updates, deletes);
          });
        }

        List<
            (
              int,
              List<Map<String, dynamic>>,
              List<Map<String, dynamic>>,
              List<Map<String, dynamic>>
            )?> results;
        WorkloadLease? lease;
        try {
          lease = await scheduler.acquire(
            WorkloadType.maintenance,
            requestedTokens: concurrency,
            minTokens: 1,
            label: 'processTablePartitions.$tableName',
          );
          results = await ParallelProcessor.execute<
              (
                int,
                List<Map<String, dynamic>>,
                List<Map<String, dynamic>>,
                List<Map<String, dynamic>>
              )?>(
            tasks,
            concurrency: lease.asConcurrency(1),
            controller: effectiveController,
            label: 'processTablePartitions.$tableName',
            continueOnError: false,
          );
        } finally {
          lease?.release();
        }

        for (var i = 0; i < chunkPartitions.length; i++) {
          final r = results[i];
          if (r == null) continue;
          final (pNo, inserts, updates, deletes) = r;
          await rangeManager.writeChanges(
            tableName: tableName,
            inserts: inserts,
            updates: updates,
            deletes: deletes,
            batchContext: batchContext,
            encryptionKey: customKey,
            encryptionKeyId: customKeyId,
          );
          await onPartitionFlushed?.call(pNo);
        }

        if (journaling && batchContext != null) {
          // Complete this chunk only: delete this chunk's page redo log now (not whole table).
          await _dataStore.parallelJournalManager
              .completeMaintenanceBatch(batchContext: batchContext);
          await persistRuntimeMetaIfNeeded();
        }
      }
    } finally {
      // Only clean up locks/flags if we actually acquired them (write operations).
      if (!onlyRead) {
        _processingTables.remove(tableName);
        if (lockAcquired && _dataStore.lockManager != null) {
          _dataStore.lockManager!.releaseExclusiveLock(lockKey, operationId);
        }
        if (maintenanceLockAcquired && _dataStore.lockManager != null) {
          _dataStore.lockManager!
              .releaseExclusiveLock(maintenanceLockKey, maintenanceOpId);
        }
      }
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
  }

  /// high performance table data cleanup, including physical files and memory cache
  Future<void> clearTable(String tableName) async {
    // Mark that table is being flushed to prevent other operations from interfering
    _tableFlushingFlags[tableName] = true;
    // lock this table to ensure data consistency
    final lockKey = 'table_$tableName';
    final operationId = GlobalIdGenerator.generate('clear_table_');
    bool acquired = await _dataStore.lockManager!
        .acquireExclusiveLock(lockKey, operationId);
    if (!acquired) {
      Logger.warn('Failed to acquire exclusive lock for clearTable: $tableName',
          label: 'TableDataManager.clearTable');
      return;
    }
    try {
      // First, update statistics by subtracting this table's counts
      try {
        final fileMeta = await getTableMeta(tableName);
        if (fileMeta != null) {
          // Subtract this table's records and size from the totals
          _totalRecordCount = max(0, _totalRecordCount - fileMeta.totalRecords);
          _totalDataSizeBytes =
              max(0, _totalDataSizeBytes - fileMeta.totalSizeInBytes);

          // Mark statistics as needing to be saved
          _needSaveStats = true;
        }
      } catch (e) {
        Logger.warn('Failed to update stats during clearTable for $tableName',
            label: 'TableDataManager.clearTable');
      }

      await _dataStore.writeBufferManager.clearTable(tableName);

      // 2. directly delete the entire partition directory
      bool deletedDir = false;
      try {
        final dataPath = await _dataStore.pathManager.getDataDirPath(tableName);
        if (await _dataStore.storage.existsDirectory(dataPath)) {
          await _dataStore.storage.deleteDirectory(dataPath);
          // delete and recreate empty directory, ensure directory structure is complete
          await _dataStore.storage.ensureDirectoryExists(dataPath);
          Logger.debug(
              'deleted entire partition directory for table $tableName',
              label: 'TableDataManager.clearTable');
          deletedDir = true;
        }
      } catch (e) {
        Logger.error('delete table $tableName partition directory failed: $e',
            label: 'TableDataManager.clearTable');
      }

      // 3. create empty table meta
      final prevMeta = await getTableMeta(tableName);
      final int pageSize = prevMeta?.btreePageSize ?? TableMeta.defaultPageSize;
      // If we failed to delete the directory, avoid reusing old partition files:
      // bump partition count so new writes allocate a fresh partitionNo.
      final int newPartitionCount =
          deletedDir ? 1 : max(1, (prevMeta?.btreePartitionCount ?? 0) + 1);
      final emptyMeta = TableMeta.createEmpty(
        name: tableName,
        pageSize: pageSize,
        partitionCount: newPartitionCount,
      );

      // 4. update table meta
      await updateTableMeta(tableName, emptyMeta);

      // 5. clean ID generator related resources
      _idGenerators.remove(tableName);
      _idGeneratorPending.remove(tableName);

      // 6. handle auto increment ID reset
      try {
        final schema =
            await _dataStore.schemaManager?.getTableSchema(tableName);
        if (schema == null) {
          return;
        }
        if (schema.primaryKeyConfig.type == PrimaryKeyType.sequential) {
          // Reset maxId in FileMeta to "0"
          final fileMeta = await getTableMeta(tableName);
          if (fileMeta != null) {
            final updatedMeta = fileMeta.copyWith(maxAutoIncrementId: "0");
            await updateTableMeta(tableName, updatedMeta);
          }

          // update memory cache
          _maxIds[tableName] = "0";
          _maxIdsDirty[tableName] = false; // Already saved to FileMeta

          // clean ID generator resources
          _idRanges.remove(tableName);
        }
      } catch (e) {
        Logger.error('reset table $tableName auto increment ID failed: $e',
            label: 'TableDataManager.clearTable');
      }

      // 7. clean other caches
      _tableMetaCache.remove(tableName);
      _fileSizes.remove(tableName);
      _lastModifiedTimes.remove(tableName);
      _checkedOrderedRange.remove(tableName);
    } catch (e) {
      Logger.error('clear table $tableName failed: $e',
          label: 'TableDataManager.clearTable');
      rethrow; // rethrow error to upper level
    } finally {
      // clear table flush flag
      _tableFlushingFlags.remove(tableName);
      if (acquired) {
        _dataStore.lockManager!.releaseExclusiveLock(lockKey, operationId);
      }
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

    try {
      if (_dataStore.lockManager != null) {
        for (final t in tablesToLock) {
          // Generate unique opId for each lock request to satisfy LockManager constraint
          final opId = GlobalIdGenerator.generate('rewrite_records_${t}_');
          tableOpIds[t] = opId;

          final lk = 'table_$t';
          final ok =
              await _dataStore.lockManager!.acquireExclusiveLock(lk, opId);
          if (!ok) {
            Logger.warn('Failed to acquire lock for $t, abort rewrite',
                label: 'TableDataManager.rewriteRecordsFromSourceTable');
            // release any previous locks
            for (final prev in tablesToLock) {
              if (prev == t) break;
              final plk = 'table_$prev';
              final prevOpId = tableOpIds[prev];
              if (acquiredKeys[plk] == true && prevOpId != null) {
                _dataStore.lockManager!.releaseExclusiveLock(plk, prevOpId);
              }
            }
            return;
          }
          acquiredKeys['table_$t'] = true;
          _processingTables.add(t);
        }
      } else {
        for (final t in tablesToLock) {
          if (_processingTables.contains(t)) {
            Logger.debug('Table $t is being processed, abort rewrite',
                label: 'TableDataManager.rewriteRecordsFromSourceTable');
            // rollback adds
            for (final prev in tablesToLock) {
              if (prev == t) break;
              _processingTables.remove(prev);
            }
            return;
          }
          _processingTables.add(t);
        }
      }

      // Get source table schema for decoding old data
      // In migration scenarios, this should be the OLD schema before changes
      final sourceSchema =
          await _dataStore.schemaManager?.getTableSchema(sourceTableName);
      if (sourceSchema == null) {
        return;
      }

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
        await rangeManager.writeChanges(
          tableName: targetTableName,
          inserts: processed,
          updates: const [],
          deletes: const [],
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
        );
      }

      // Use sourceSchema to decode old data correctly during migration
      // This ensures old data is decoded using the old schema structure
      await for (final r in rangeManager.streamRecordsByPrimaryKeyRange(
        tableName: sourceTableName,
        startKeyInclusive: Uint8List(0),
        endKeyExclusive: Uint8List(0),
        reverse: false,
        limit: null,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        decodeSchema:
            sourceSchema, // Use old schema for decoding during migration
      )) {
        await yc.maybeYield();
        batch.add(r);
        if (batch.length >= batchSize) {
          await flushBatch();
        }
      }
      await flushBatch();
      try {
        await _dataStore.storage.flushAll();
      } catch (_) {}
    } catch (e, stack) {
      Logger.error(
        'Failed to rewrite records from source table: $e\n$stack',
        label: 'TableDataManager.rewriteRecordsFromSourceTable',
      );
    } finally {
      // Release locks and processing flags
      for (final t in tablesToLock) {
        _processingTables.remove(t);
        final lk = 'table_$t';
        final opId = tableOpIds[t];
        if (_dataStore.lockManager != null &&
            (acquiredKeys[lk] == true) &&
            opId != null) {
          _dataStore.lockManager!.releaseExclusiveLock(lk, opId);
        }
      }
    }
  }

  /// Get current table metadata cache size in bytes
  int getCurrentTableMetaCacheSize() {
    return _tableMetaCache.estimatedTotalSizeBytes;
  }

  /// Merges uncommitted data (WAL buffer and transaction overlays) into the results.
  /// [onlyMergeTransaction] indicates if the input [records] already contains all possible committed records
  /// for the query context (e.g. all point-lookup keys were found). In such cases, we can skip
  /// scanning buffers for NEW inserts.
  Future<List<Map<String, dynamic>>> mergeConsistency(
    String tableName,
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
    final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
    if (schema == null) return records;

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
      await yieldController.maybeYield();
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

    // Defensive copy for transactional deferred records
    Map<String, dynamic> visibleTxnRecord(Map<String, dynamic> src) {
      final out = Map<String, dynamic>.from(src);
      out.remove('_oldValues');
      return out;
    }

    if (!onlyMergeTransaction) {
      // --- PHASE 1: Efficient Update/Delete (Lookup from Disk Results) ---
      // Instead of scanning the whole buffer for updates, we scan the specific records we retrieved.
      // This is O(disk_records), avoiding O(buffer_size) scan for this part.

      // We iterate a snapshot of initial keys because baseRecords might change.
      final initialKeys = baseRecords.keys.toList(growable: false);
      for (final pk in initialKeys) {
        final be =
            _dataStore.writeBufferManager.getBufferedRecord(tableName, pk);
        if (be != null) {
          if (be.operation == BufferOperationType.delete) {
            baseRecords.remove(pk);
          } else {
            baseRecords[pk] = be.data;
          }
        }
      }

      // handle insert buffer
      final keys = explicitInsertKeys ??
          _dataStore.writeBufferManager
              .getBufferedInsertKeys(tableName, reverse: reverse);

      for (final key in keys) {
        await yieldController.maybeYield();
        if (performEarlyBreak && hasReachedTarget()) break;

        if (keyPredicate != null && !keyPredicate(key)) continue;

        final entry =
            _dataStore.writeBufferManager.getBufferedRecord(tableName, key);
        if (entry == null) continue;

        final rec = entry.data;
        if (filter != null && !filter(rec)) continue;

        applyBufferInsert(key, entry);
      }
    }

    // 2.3 Transaction Deferred Ops (if any)
    if (currentTxId != null) {
      final defOps = _txnDeferredOps[currentTxId]?[tableName];
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
                baseRecords[pk] = visibleTxnRecord(op.data);
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
              await yieldController.maybeYield();
              if (performEarlyBreak && hasReachedTarget()) break;

              final op = defOps[pk];
              if (op == null) continue;

              if (baseRecords.containsKey(pk)) continue;

              if (op.type != BufferOperationType.delete &&
                  (matcher == null ||
                      matcher.matches(visibleTxnRecord(op.data)))) {
                baseRecords[pk] = visibleTxnRecord(op.data);
              }
            }
          } else {
            // Iterate values (Iterable) is cheaper than converting to list
            for (final op in defOps.values) {
              await yieldController.maybeYield();
              // Check limit again strictly inside loop
              if (performEarlyBreak && hasReachedTarget()) break;

              final pk = op.data[primaryKey]?.toString();
              if (pk == null) continue;

              // If already in baseRecords, it was handled in Phase 3.1
              if (baseRecords.containsKey(pk)) continue;

              // New insert logic
              if (op.type != BufferOperationType.delete &&
                  (matcher == null ||
                      matcher.matches(visibleTxnRecord(op.data)))) {
                baseRecords[pk] = visibleTxnRecord(op.data);
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
            if (plan.tableName != tableName) continue;
            final qc = QueryCondition.fromMap(plan.condition);
            final hdMatcher = ConditionRecordMatcher.prepare(
                qc, {tableName: schema}, tableName);

            final snapshotList = baseRecords.entries.toList(growable: false);
            for (final entry in snapshotList) {
              await yieldController.maybeYield();
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
            if (plan.tableName != tableName) continue;
            // We need to apply updates to all matching records in baseRecords
            final qc = QueryCondition.fromMap(plan.condition);
            final hmMatcher = ConditionRecordMatcher.prepare(
                qc, {tableName: schema}, tableName);

            // Iterate keys first to avoid concurrent modification of baseRecords during update

            for (final k in baseRecords.keys) {
              await yieldController.maybeYield();
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
    for (final r in recordValues) {
      await yieldController.maybeYield();
      if (matcher != null && !matcher.matches(r)) continue;
      results.add(r);
      if (trackReadKeys) {
        final k = r[primaryKey]?.toString();
        if (k != null && k.isNotEmpty) {
          TransactionContext.registerReadKey(tableName, k);
        }
      }
    }
    return results;
  }

  /// Removes a record from any of the in-memory buffers.
  void removeRecordFromBuffer(String tableName, String recordId) {
    _dataStore.writeBufferManager.removeRecord(tableName, recordId);
  }

  /// Removes all data and metadata for a table from the manager.
  Future<void> removeTable(String tableName) async {
    // Clean up all in-memory buffers and caches
    // legacy buffers removed

    // Clear WAL-driven table-level write buffer and queue to prevent subsequent writes
    _dataStore.writeBufferManager.clearTable(tableName);

    // Clean up other caches
    _tableMetaCache.remove(tableName);
    _fileSizes.remove(tableName);
    _lastModifiedTimes.remove(tableName);
    _tablePartitionSizes.remove(tableName);
    _maxIds.remove(tableName);
    _maxIdsDirty.remove(tableName);
    _idGenerators.remove(tableName);
    _idGeneratorPending.remove(tableName);
    _idRanges.remove(tableName);
    _checkedOrderedRange.remove(tableName);
    _processingTables.remove(tableName);
    _tableFlushingFlags.remove(tableName);
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
      }
    } catch (e) {
      Logger.warn('cleanupTransactionalState failed: $e',
          label: 'TableDataManager');
    }
  }

  /// Remove specific transaction state (called by rollback/cleanup)
  Future<void> clearTransactionState(String transactionId) async {
    _txnDeferredOps.remove(transactionId);
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

  /// Writes the given changes (inserts, updates, deletes) to the partition files of the specified table.
  ///
  /// This method merges inserted, updated, and deleted records according to their partitions and then writes them
  /// to the corresponding partition files. Optionally supports encryption via a custom key.
  ///
  /// [tableName]          - Name of the table for which changes should be written.
  /// [inserts]            - List of records to insert.
  /// [updates]            - List of records to update.
  /// [deletes]            - List of records to delete.
  /// [batchContext]       - Optional: The batch context for write batches.
  /// [concurrency]        - Optional: total number of concurrent processing tokens
  /// [encryptionKey]      - Optional: encrypt key
  /// [encryptionKeyId]    - Optional: encrypt key id
  Future<void> writeChanges({
    required String tableName,
    List<Map<String, dynamic>> inserts = const [],
    List<Map<String, dynamic>> updates = const [],
    List<Map<String, dynamic>> deletes = const [],
    BatchContext? batchContext,
    int? concurrency,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    await _dataStore.tableTreePartitionManager.writeChanges(
      tableName: tableName,
      inserts: inserts,
      updates: updates,
      deletes: deletes,
      batchContext: batchContext,
      concurrency: concurrency,
      encryptionKey: encryptionKey,
      encryptionKeyId: encryptionKeyId,
    );
  }

  /// Batch query with full consistency checking (Txn > Cache > Buffer > Disk).
  /// Batch query. Note: Returns results from Cache and Disk (Committed data).
  /// [isConsistent] in the result indicates if all requested keys were found in the committed state.
  Future<TableScanResult> queryRecordsBatch(
    String tableName,
    List<dynamic> keys, {
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    if (keys.isEmpty) return TableScanResult(records: []);

    final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
    if (schema == null) return TableScanResult(records: []);

    final results = <Map<String, dynamic>>[];
    final missingKeys = <dynamic>[];
    final uniqueKeys = keys.toSet().toList();

    // 1. Try Cache
    for (final key in uniqueKeys) {
      final pk = key.toString();
      final cached = _tableRecordCache.get([tableName, pk]);
      if (cached != null) {
        results.add(cached);
      } else {
        missingKeys.add(key);
      }
    }

    // 2. Try Disk
    if (missingKeys.isNotEmpty) {
      final pkMatcher =
          ValueMatcher.getMatcher(schema.getPrimaryKeyMatcherType());
      final diskResults =
          await _dataStore.tableTreePartitionManager.queryRecordsBatch(
        tableName: tableName,
        primaryKey: schema.primaryKey,
        keyComparator: pkMatcher,
        keys: missingKeys,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
      );

      // Read-Through: Cache the results fetched from disk
      if (diskResults.isNotEmpty) {
        cacheTableRecordsBatch(
          tableName,
          diskResults,
          primaryKey: schema.primaryKey,
          schema: schema,
          force: true,
        );
      }
      results.addAll(diskResults);
    }

    return TableScanResult(
      records: results,
    );
  }

  Future<TableScanResult> searchTableData(
    String tableName,
    ConditionRecordMatcher? matcher, {
    int? limit,
    int? offset,
    List<String>? orderBy,
    String? startAfterPrimaryKey,
    bool Function(Map<String, dynamic>)? filter,
  }) async {
    // Increment table access weight for caching optimization
    _dataStore.weightManager?.incrementAccess(
      WeightType.tableRecord,
      tableName,
      spaceName: _dataStore.currentSpaceName,
    );
    final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
    if (schema == null) {
      return TableScanResult(records: const []);
    }
    final primaryKey = schema.primaryKey;
    final pkMatcher =
        ValueMatcher.getMatcher(schema.getPrimaryKeyMatcherType());

    final bufferMgr = _dataStore.writeBufferManager;

    bool recordMatches(Map<String, dynamic> r) {
      // Defensive: always treat deleted/tombstone as non-visible.
      if (isDeletedRecord(r)) return false;

      // Check Real-time WriteBuffer to filter out pending deletes.
      // This prevents "page gaps" where disk records are counted towards limit
      // but later removed during mergeConsistency.
      final pk = r[primaryKey]?.toString();
      if (pk != null) {
        final be = bufferMgr.getBufferedRecord(tableName, pk);
        if (be != null && be.operation == BufferOperationType.delete) {
          return false;
        }
      }

      if (filter != null && !filter(r)) return false;
      if (matcher != null && !matcher.matches(r)) return false;
      return true;
    }

    // Always apply recordMatches to ensure WriteBuffer deletions are filtered out
    // during the scan (preserving the limit), even if matcher/filter are null.
    // ignore: unnecessary_nullable_for_final_variable_declarations
    final bool Function(Map<String, dynamic>)? recordPredicate = recordMatches;

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
        return TableScanResult(records: []);
      }

      final batchRes = await queryRecordsBatch(tableName, keys);
      final recs = batchRes.records;

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

      return TableScanResult(
        records: filtered,
      );
    }

    final fileMeta = await getTableMeta(tableName);
    if (fileMeta == null || fileMeta.totalRecords <= 0) {
      return TableScanResult(records: const []);
    }

    final rangeMgr = _dataStore.tableTreePartitionManager;

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
      return TableScanResult(records: []);
    }

    // PK-ordered scan: can stop early at offset+limit.
    if (isPkOrder) {
      // New global B+Tree: PK range scan should NOT be partition-loop driven.
      // Delegate to the partition manager to scan the global leaf chain once.
      final out = await rangeMgr.scanRecordsByPrimaryKeyRange(
        tableName: tableName,
        startKeyInclusive: startKeyBytes,
        endKeyExclusive: endKeyBytes,
        reverse: reverse,
        limit: (needCount < 0) ? null : needCount,
        recordPredicate: recordPredicate,
      );
      return TableScanResult(records: out);
    }

    // Non-PK orderBy: must scan all target partitions, then do in-memory topK sort (bounded by offset+limit).
    // Pre-build matcher functions for orderBy fields (critical for topK performance).
    final orderMatchers = <MatcherFunction>[];
    final schemas = <String, TableSchema>{tableName: schema};
    for (int i = 0; i < sortFields.length; i++) {
      final f = sortFields[i];
      final s = ConditionRecordMatcher.getSchemaForField(f, schemas, tableName);
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
      out.addAll(await rangeMgr.scanRecordsByPrimaryKeyRange(
        tableName: tableName,
        startKeyInclusive: startKeyBytes,
        endKeyExclusive: endKeyBytes,
        reverse: false,
        limit: null,
        recordPredicate: recordPredicate,
      ));
      // Note: Sorting is handled by the upper layer (QueryExecutor._applySort),
      // so we skip sorting here to avoid redundant operations and improve performance.
      // Only need to handle reverse partition scanning based on sort direction.
      return TableScanResult(records: out);
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
        await rangeMgr.forEachRecordByPrimaryKeyRange(
          tableName: tableName,
          startKeyInclusive: startKeyBytes,
          endKeyExclusive: endKeyBytes,
          reverse: false,
          limit: null,
          recordPredicate: recordPredicate,
          onRecord: (r) {
            localTop.offer(r);
            return true;
          },
        );
        return localTop.toSortedList();
      });

      if (tasks.isEmpty) {
        return TableScanResult(records: []);
      }

      final effectiveConcurrency = min(queryConcurrency, tasks.length);

      // Fast timeout estimation: Base 60s + (TotalMaxBytes / 2MB/s / concurrency)
      // Assumes maxPartitionFileSize * 1.5 per task (main + incremental buffer).
      final estTotalBytes =
          tasks.length * _dataStore.config.maxPartitionFileSize * 1.5;
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
          await yieldControllerMerge.maybeYield();
          globalTop.offer(r);
        }
      }
    } finally {
      lease?.release();
    }

    return TableScanResult(records: globalTop.toSortedList());
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
