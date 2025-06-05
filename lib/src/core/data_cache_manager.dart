import 'dart:math';
import '../model/cache.dart';
import 'data_store_impl.dart';
import '../handler/logger.dart';
import '../model/table_schema.dart';
import '../statistic/table_statistics.dart';
import '../query/query_cache.dart';
import '../query/query_condition.dart';
import '../model/structure_cache.dart';
import 'crontab_manager.dart';

/// Data cache manager
class DataCacheManager {
  // Query cache, Query condition cache
  final QueryCache _queryCache;
  // Record the dependency between tables and queries, Map<table name, Map<query ID, query information>>
  final Map<String, Map<String, _QueryInfo>> _tableDependencies = {};
  final DataStoreImpl _dataStore;

  // Table data cache
  final Map<String, TableCache> tableCaches = {};

  // Schema cache
  final Map<String, TableSchema> _schemaCache = {};

  // Stats cache
  final Map<String, TableStatistics> _statsCache = {};

  // Periodic task registration flag
  bool _cronJobsRegistered = false;

  // Space switching status flag
  bool _isSwitchingSpace = false;

  DataCacheManager(this._dataStore)
      : _queryCache = QueryCache(
          maxSize: _dataStore.config.maxQueryCacheSize,
        ) {
    // Register periodic tasks
    _registerCronJobs();
  }

  /// Register periodic tasks
  void _registerCronJobs() {
    if (_cronJobsRegistered) return;

    // Register 1-hour periodic task for cleaning expired cache
    CrontabManager.addCallback(ExecuteInterval.hour1, _cleanupExpiredCache);

    // Trigger startup phase cache collection
    Future.delayed(
        Duration(
            milliseconds: _dataStore.config.startupCacheCollectionDurationMs),
        () async {
      _dataStore.indexManager?.endStartupCacheCollection();
    });

    _cronJobsRegistered = true;
  }

  /// Load startup cache (load both global and current space cache simultaneously)
  Future<void> loadStartupCache() async {
    try {
      // Load global and space startup cache in parallel
      await Future.wait([
        _tryLoadCacheFile(
            _dataStore.pathManager.getGlobalStartupCacheFilePath(),
            isGlobal: true),
        _tryLoadCacheFile(_dataStore.pathManager.getStartupCacheFilePath(),
            isGlobal: false),
      ]);
    } catch (e) {
      Logger.error('Failed to load startup cache: $e',
          label: 'DataCacheManager.loadStartupCache');
    }
  }

  /// Try to load cache file
  Future<void> _tryLoadCacheFile(String filePath,
      {bool isGlobal = false}) async {
    try {
      // Check if file exists
      if (!await _dataStore.storage.existsFile(filePath)) {
        return;
      }

      // Read cache file
      final jsonData = await _dataStore.storage.readAsString(filePath);
      if (jsonData == null || jsonData.isEmpty) return;

      // Parse cache data
      final cache = StructureCache.fromJson(jsonData);

      // Restore index cache
      if (cache.indices.isNotEmpty) {
        await _dataStore.indexManager?.loadIndexCache(cache.indices);
      }
    } catch (e) {
      Logger.error('Failed to load cache file: $filePath, $e',
          label: 'DataCacheManager._tryLoadCacheFile');
    }
  }

  /// Provide unified interface for saving cache
  Future<void> saveStructureCache({
    required Map<String, Map<String, dynamic>> indexCache,
    required CacheType cacheType,
  }) async {
    try {
      // Separate global tables and space tables
      final globalIndexCache = <String, Map<String, dynamic>>{};
      final spaceIndexCache = <String, Map<String, dynamic>>{};

      // Separate index cache
      for (final entry in indexCache.entries) {
        final key = entry.key;
        final parts = key.split(':');
        if (parts.length != 2) continue;

        final tableName = parts[0];
        final schema = await _dataStore.getTableSchema(tableName);
        if (schema == null) {
          Logger.error('Table $tableName does not exist',
              label: 'DataCacheManager.saveStructureCache');
          continue;
        }
        if (schema.isGlobal == true) {
          globalIndexCache[key] = entry.value;
        } else {
          spaceIndexCache[key] = entry.value;
        }
      }

      // Save global table cache
      if (globalIndexCache.isNotEmpty) {
        await _saveCacheToFile(globalIndexCache, cacheType, isGlobal: true);
      }

      // Save space table cache
      if (spaceIndexCache.isNotEmpty) {
        await _saveCacheToFile(spaceIndexCache, cacheType, isGlobal: false);
      }
    } catch (e) {
      Logger.error('Failed to save cache: $e',
          label: 'DataCacheManager.saveStructureCache');
    }
  }

  /// Save cache to file
  Future<void> _saveCacheToFile(
      Map<String, Map<String, dynamic>> indices, CacheType cacheType,
      {bool isGlobal = false}) async {
    try {
      if (cacheType == CacheType.startup) {
        // Create cache object
        final cache = StructureCache.startup(
          indices: indices,
          createTime: DateTime.now(),
        );

        // Determine save path
        String path;
        if (isGlobal) {
          // Global cache
          path = _dataStore.pathManager.getGlobalStartupCacheFilePath();

          // Ensure directory exists
          await _dataStore.storage.ensureDirectoryExists(
              _dataStore.pathManager.getGlobalStartupCachePath());
        } else {
          // Space cache
          path = _dataStore.pathManager.getStartupCacheFilePath();

          // Ensure directory exists
          await _dataStore.storage.ensureDirectoryExists(
              _dataStore.pathManager.getStartupCachePath());
        }

        // Write to file
        await _dataStore.storage.writeAsString(path, cache.toJson());
      }
    } catch (e) {
      Logger.error('Failed to save cache file: $e',
          label: 'DataCacheManager._saveCacheToFile');
    }
  }

  /// Clean up expired cache
  void _cleanupExpiredCache() {
    // Check if space switching is in progress
    if (_isSwitchingSpace) {
      return;
    }

    try {
      // Check if table structure cache size exceeds limit
      if (_schemaCache.length > _dataStore.config.maxSchemaCacheSize) {
        // Calculate number to delete
        final removeCount =
            _schemaCache.length - _dataStore.config.maxSchemaCacheSize;

        // Create list of non-global tables
        final nonGlobalTables = _schemaCache.entries
            .where((entry) => entry.value.isGlobal != true)
            .toList();

        // If there are non-global tables, delete them
        if (nonGlobalTables.isNotEmpty) {
          // Delete at most the calculated number
          final toRemove = nonGlobalTables.length < removeCount
              ? nonGlobalTables.length
              : removeCount;

          for (int i = 0; i < toRemove; i++) {
            final tableName = nonGlobalTables[i].key;
            _schemaCache.remove(tableName);
          }

          Logger.debug('Cleaned up $toRemove table structure caches',
              label: 'DataCacheManager._cleanupExpiredCache');
        }
      }

      // Clean up query cache
      if (_queryCache.size > _dataStore.config.maxQueryCacheSize) {
        // Calculate number to delete
        final removeCount =
            _queryCache.size - _dataStore.config.maxQueryCacheSize;

        // Sort query cache entries by last access time (oldest first)
        final queryCacheEntries = _queryCache.cache.entries.toList();
        queryCacheEntries
            .sort((a, b) => a.value.timestamp.compareTo(b.value.timestamp));

        // Delete oldest query caches
        for (int i = 0; i < removeCount && i < queryCacheEntries.length; i++) {
          _queryCache.invalidate(queryCacheEntries[i].key);
        }

        Logger.debug('Cleaned up $removeCount expired query caches',
            label: 'DataCacheManager._cleanupExpiredCache');
      }

      // Update initialization configuration
      _updateSpaceConfig(lastCacheCleanupTime: DateTime.now());
    } catch (e) {
      Logger.error('Failed to clean up expired cache: $e',
          label: 'DataCacheManager._cleanupExpiredCache');
    }
  }

  /// Update initialization configuration
  Future<void> _updateSpaceConfig({
    DateTime? lastCacheWeightProcessTime,
    DateTime? lastStartupCacheTime,
    DateTime? lastCacheCleanupTime,
  }) async {
    try {
      final spaceConfig = await _dataStore.getSpaceConfig();
      if (spaceConfig == null) return;

      final newConfig = spaceConfig.copyWith(
        lastCacheWeightProcessTime: lastCacheWeightProcessTime,
        lastStartupCacheTime: lastStartupCacheTime,
        lastCacheCleanupTime: lastCacheCleanupTime,
      );

      await _dataStore.saveSpaceConfigToFile(newConfig);
    } catch (e) {
      Logger.error('Failed to update initialization configuration: $e',
          label: 'DataCacheManager._updateSpaceConfig');
    }
  }

  /// Called before application exit, ensures all caches are persisted
  Future<bool> persistAllCaches() async {
    try {
      bool hasChanges = false;

      // 1. Notify index manager to save cache
      final indexManager = _dataStore.indexManager;
      bool indexSaved = false;
      if (indexManager != null) {
        indexSaved = await indexManager.saveBeforeAppExit();

        // Index manager has saved index changes, return directly
        if (indexSaved) {
          return true;
        }
      }

      // 2. Only check and save separately when index manager has no changes
      // Get index cache data
      Map<String, Map<String, dynamic>> startupIndexCache = {};

      if (indexManager != null) {
        startupIndexCache = await indexManager.getStartupIndexCache();
      }

      // If there is startup index cache, trigger save
      if (startupIndexCache.isNotEmpty) {
        await saveStructureCache(
          indexCache: startupIndexCache,
          cacheType: CacheType.startup,
        );
        hasChanges = true;
      }

      return hasChanges;
    } catch (e) {
      Logger.error('Failed to persist all caches: $e',
          label: 'DataCacheManager.persistAllCaches');
      return false;
    }
  }

  /// Cache query results
  void cacheQuery(
    QueryCacheKey key,
    List<Map<String, dynamic>> results,
    Set<String> tables,
  ) async {
    try {
      final cacheKey = key.toString();
      final schema = await _dataStore.getTableSchema(tables.first);
      if (schema == null) {
        Logger.error('Table ${tables.first} does not exist',
            label: 'DataCacheManager.cacheQuery');
        return;
      }
      _queryCache.put(
        cacheKey,
        results,
        tables.first,
        schema.primaryKey,
      );

      // Record the dependency between queries and tables
      for (var table in tables) {
        final schema = await _dataStore.getTableSchema(table);
        if (schema == null) {
          Logger.error('Table $table does not exist',
              label: 'DataCacheManager.cacheQuery');
          continue;
        }
        final primaryKey = schema.primaryKey;

        // Determine if it is a full table query
        final isFullTableQuery = key.condition.build().isEmpty;

        _tableDependencies.putIfAbsent(table, () => {}).putIfAbsent(
            cacheKey,
            () => _QueryInfo(
                  queryKey: key,
                  primaryKeyField: primaryKey,
                  results: results,
                  isFullTableCache: isFullTableQuery,
                ));
      }
    } catch (e) {
      Logger.error('Cache query results failed: $e',
          label: 'QueryCacheManager.cacheQuery');
    }
  }

  /// Get cached query results
  List<Map<String, dynamic>>? getQuery(QueryCacheKey key) {
    final results = _queryCache.get(key.toString());
    return results;
  }

  /// Check if record matches query conditions
  Future<bool> _recordMatchesConditions(
    String tableName,
    dynamic primaryKeyValue,
    QueryCondition condition,
    String primaryKeyField,
  ) async {
    try {
      final record = await _getRecordByPrimaryKey(
        tableName,
        primaryKeyField,
        primaryKeyValue,
      );
      if (record == null) return false;

      return condition.matches(record);
    } catch (e) {
      Logger.error('Check record matches conditions failed: $e',
          label: 'QueryCacheManager._recordMatchesConditions');
      return true;
    }
  }

  /// Get record full data
  Future<Map<String, dynamic>?> _getRecordByPrimaryKey(
    String tableName,
    String primaryKeyField,
    dynamic primaryKeyValue,
  ) async {
    try {
      final results = await _dataStore.executeQuery(
        tableName,
        QueryCondition()..where(primaryKeyField, '=', primaryKeyValue),
        limit: 1,
      );
      return results.isEmpty ? null : results.first;
    } catch (e) {
      Logger.error('Get record by primary key failed: $e',
          label: 'QueryCacheManager._getRecordByPrimaryKey');
      return null;
    }
  }

  /// Invalidate record related cache
  Future<void> invalidateRecord(
      String tableName, dynamic primaryKeyValue) async {
    try {
      // Get table cache
      final tableCache = tableCaches[tableName];
      if (tableCache != null) {
        final pkString = primaryKeyValue.toString();
        // Remove record from cache, but don't affect full table cache status (because cache changes are synchronized with file)
        tableCache.recordsMap.remove(pkString);
      }

      final tableQueries = _tableDependencies[tableName];
      if (tableQueries == null) return;

      // Query cache
      for (var entry in tableQueries.entries) {
        final queryInfo = entry.value;

        // If it is full table cache or matches query conditions, invalidate cache
        if (queryInfo.isFullTableCache ||
            await _recordMatchesConditions(
              tableName,
              primaryKeyValue,
              queryInfo.queryKey.condition,
              queryInfo.primaryKeyField,
            )) {
          _queryCache.invalidate(entry.key);
          tableQueries.remove(entry.key);
        }
      }

      // If table has no related queries, clean dependency
      if (tableQueries.isEmpty) {
        _tableDependencies.remove(tableName);
      }
    } catch (e) {
      Logger.error('Invalidate record cache failed: $e',
          label: 'QueryCacheManager.invalidateRecord');
    }
  }

  /// Invalidate records related cache
  Future<void> invalidateRecords(
    String tableName,
    Set<dynamic> primaryKeyValues,
  ) async {
    try {
      // Check if table cache exists
      final tableCache = tableCaches[tableName];

      // If primaryKeyValues is empty, clear all related queries cache
      if (primaryKeyValues.isEmpty) {
        // Clear table dependency cache
        _tableDependencies.remove(tableName);

        // Clear all related queries cache in general cache
        final keysToRemove = <String>[];
        _queryCache.cache.forEach((key, queryCache) {
          if (queryCache.tableName == tableName) {
            keysToRemove.add(key);
          }
        });

        for (var key in keysToRemove) {
          _queryCache.invalidate(key);
        }

        // Clear table cache
        tableCaches.remove(tableName);

        return;
      }

      // Handle specific record invalidation
      if (tableCache != null) {
        // Remove records with specified primary key values from cache, without affecting full table cache status
        for (var pkValue in primaryKeyValues) {
          final pkString = pkValue.toString();
          tableCache.recordsMap.remove(pkString);
        }
      }

      // 1. Handle query cache
      final keysToRemove = <String>[];

      // 1.1 Handle table dependency cache
      final tableDependency = _tableDependencies[tableName];
      if (tableDependency != null) {
        for (var entry in tableDependency.entries) {
          final queryInfo = entry.value;
          if (queryInfo.isFullTableCache ||
              queryInfo.results.any((record) {
                final recordId = record[queryInfo.primaryKeyField]?.toString();
                return recordId != null && primaryKeyValues.contains(recordId);
              })) {
            keysToRemove.add(entry.key);
          }
        }
      }

      // 1.2 Handle general cache
      _queryCache.cache.forEach((key, queryCache) {
        if (queryCache.tableName == tableName) {
          if (queryCache.results.any((record) {
            final recordId = record[queryCache.primaryKeyField]?.toString();
            return recordId != null && primaryKeyValues.contains(recordId);
          })) {
            keysToRemove.add(key);
          }
        }
      });

      // 2. Remove cache
      for (var key in keysToRemove) {
        _queryCache.invalidate(key);
        tableDependency?.remove(key);
      }

      // 3. If table has no related queries, clean dependency
      if (tableDependency?.isEmpty ?? false) {
        _tableDependencies.remove(tableName);
      }
    } catch (e) {
      Logger.error(
        'Invalidate records cache failed: $e\n'
        'tableName: $tableName\n'
        'primaryKeyValues: $primaryKeyValues',
        label: 'QueryCacheManager.invalidateRecords',
      );
    }
  }

  /// Clear all cache
  void clear() {
    _queryCache.clear();
    _tableDependencies.clear();
    tableCaches.clear();
    _schemaCache.clear();
    _statsCache.clear();
    Logger.debug('Clear all cache', label: 'QueryCacheManager.clear');
  }

  /// Cache all records of a table
  Future<void> cacheEntireTable(String tableName,
      List<Map<String, dynamic>> records, String primaryKeyField,
      {bool isFullTableCache = true}) async {
    // Check parameter validity
    if (tableName.isEmpty || primaryKeyField.isEmpty) {
      return;
    }

    // Check if table file size limit allows caching
    final needCacheFullTableCache =
        await _dataStore.tableDataManager.allowFullTableCache(tableName);

    // If full table cache is requested but restricted, log a warning
    if (isFullTableCache && !needCacheFullTableCache) {
      Logger.warn(
        'Table $tableName record count(${records.length}) exceeds full table cache limit(${_dataStore.config.maxRecordCacheSize})',
        label: 'DataCacheManager.cacheEntireTable',
      );
    }

    // Check table record cache size, perform cache eviction policy
    if (getTableCacheCountAll() + records.length >
        _dataStore.config.maxRecordCacheSize) {
      // Execute cache eviction policy
      _evictLowPriorityRecords();
    }

    // Get current time as cache time
    final now = DateTime.now();

    // Check if cache for this table already exists
    TableCache tableCache;
    if (tableCaches.containsKey(tableName)) {
      // Update existing cache
      tableCache = tableCaches[tableName]!;
      tableCache.isFullTableCache = needCacheFullTableCache;
      tableCache.cacheTime = now;
      tableCache.lastAccessed = now;

      // Clear existing records (avoid mixed data causing inconsistency)
      if (needCacheFullTableCache) {
        tableCaches.remove(tableName);
        tableCache = TableCache(
          tableName: tableName,
          primaryKeyField: primaryKeyField,
          isFullTableCache: needCacheFullTableCache,
          cacheTime: now,
          lastAccessed: now,
        );
      }
    } else {
      // Create new table cache
      tableCache = TableCache(
        tableName: tableName,
        primaryKeyField: primaryKeyField,
        isFullTableCache: needCacheFullTableCache,
        cacheTime: now,
        lastAccessed: now,
      );
    }

    // Set records
    if (records.isNotEmpty) {
      // Determine cache type
      const cacheType = CacheType.runtime;

      // Add records in batch
      tableCache.addRecords(records, cacheType: cacheType);
    }

    // Store table cache
    tableCaches[tableName] = tableCache;
  }

  /// Evict low priority records
  void _evictLowPriorityRecords() {
    int totalEvictionCount = (_dataStore.config.maxRecordCacheSize * 0.3)
        .round(); // Clear 30% of records
    int evictedCount = 0;

    // First apply time decay to all table caches
    _applyTimeDecayToAllCaches();

    // Sort tables by cache size from largest to smallest
    final sortedTables = tableCaches.entries.toList()
      ..sort((a, b) => b.value.recordCount.compareTo(a.value.recordCount));

    // Start evicting from tables with most records
    for (var entry in sortedTables) {
      if (evictedCount >= totalEvictionCount) break;

      final tableName = entry.key;
      final tableCache = entry.value;
      final toEvict = min(
          (tableCache.recordCount * 0.3)
              .round(), // Evict at most 30% from each table
          totalEvictionCount - evictedCount);

      if (toEvict <= 0) continue;

      // Record whether it was full table cache before eviction
      final wasFullTableCache = tableCache.isFullTableCache;

      // Perform eviction
      final result = tableCache.evictLowPriorityRecords(toEvict,
          preserveStartupRecords: true // Preserve startup cache records
          );

      evictedCount += result['count'] as int;

      // If records were actually evicted and it was previously full table cache, update full table cache flag
      if ((result['count'] as int) > 0 && wasFullTableCache) {
        tableCache.isFullTableCache = false;
        Logger.debug(
          'Table $tableName removed ${result['count']} records due to cache eviction, no longer full table cache',
          label: 'DataCacheManager._evictLowPriorityRecords',
        );
      }
    }

    if (evictedCount > 0) {
      Logger.debug('Cache eviction completed: evicted $evictedCount records',
          label: 'DataCacheManager._evictLowPriorityRecords');
    }
  }

  /// Apply time decay to all table caches
  void _applyTimeDecayToAllCaches() {
    for (var tableCache in tableCaches.values) {
      tableCache.applyTimeDecay();
    }
  }

  /// Check if table is fully cached
  Future<bool> isTableFullyCached(String tableName) async {
    final cache = tableCaches[tableName];
    if (cache == null) {
      // If total record count from metadata is empty, it's considered full table cache
      final meta =
          await _dataStore.tableDataManager.getTableFileMeta(tableName);

      return meta?.totalRecords == 0;
    }
    return cache.isFullTableCache;
  }

  /// Get all records of a table from cache
  List<Map<String, dynamic>>? getEntireTable(String tableName) {
    final cache = tableCaches[tableName];
    if (cache == null) return null;

    cache.recordAccess();

    return cache.records;
  }

  /// Add record to cache
  void addCachedRecord(String tableName, Map<String, dynamic> record) {
    final cache = tableCaches[tableName];
    if (cache == null) return;

    cache.addOrUpdateRecord(record);
  }

  /// Remove record from cache
  void removeCachedRecord(String tableName, String id) {
    final cache = tableCaches[tableName];
    if (cache == null) return;

    cache.recordsMap.remove(id);
  }

  /// Cache schema
  void cacheSchema(String tableName, TableSchema schema) {
    _schemaCache[tableName] = schema;
  }

  /// Get cached table schema
  TableSchema? getSchema(String tableName) {
    return _schemaCache[tableName];
  }

  /// Cache table statistics
  void cacheStatistics(String tableName, TableStatistics stats) {
    _statsCache[tableName] = stats;
  }

  /// Get cached statistics
  TableStatistics? getStatistics(String tableName) {
    return _statsCache[tableName];
  }

  /// Get cached statistics
  Map<String, int> getCacheStats() {
    return {
      'tableCaches': tableCaches.length,
      'queryCaches': _queryCache.size,
      'schemaCache': _schemaCache.length,
      'statsCache': _statsCache.length,
    };
  }

  /// Handle base path change
  Future<void> onBasePathChanged() async {
    _isSwitchingSpace = true;
    try {
      Logger.debug(
          'Base path change started, preparing to save current space cache',
          label: 'DataCacheManager.onBasePathChanged');

      // 1. First save current space's table structure and index cache
      await persistAllCaches();

      // 2. Clear all non-global table caches
      tableCaches.removeWhere((tableName, _) {
        final schema = _schemaCache[tableName];
        return schema?.isGlobal != true;
      });

      // 3. Clear related dependencies
      _tableDependencies.removeWhere((tableName, _) {
        final schema = _schemaCache[tableName];
        return schema?.isGlobal != true;
      });

      // 4. Clear non-global table structure cache
      _schemaCache.removeWhere((tableName, schema) => schema.isGlobal != true);

      // 5. Clear statistics cache
      _statsCache.removeWhere((tableName, _) {
        final schema = _schemaCache[tableName];
        return schema?.isGlobal != true;
      });

      // 6. Clear query cache
      _queryCache.clear();

      Logger.debug('Base path change completed, non-global table cache cleared',
          label: 'DataCacheManager.onBasePathChanged');
    } catch (e) {
      Logger.error('Base path change handling failed: $e',
          label: 'DataCacheManager.onBasePathChanged');
      rethrow;
    } finally {
      _isSwitchingSpace = false;
    }
  }

  /// Get record by primary key
  Map<String, dynamic>? getRecordByPrimaryKey(
      String tableName, dynamic primaryKeyValue) {
    final cache = tableCaches[tableName];
    if (cache == null) return null;

    final pkValueStr = primaryKeyValue.toString();
    final recordCache = cache.getRecord(pkValueStr);
    return recordCache?.record;
  }

  /// Query records by field value
  List<Map<String, dynamic>> queryRecordsByField(
    String tableName,
    String fieldName,
    dynamic fieldValue,
  ) {
    final cache = tableCaches[tableName];
    if (cache == null) return [];

    final result = <Map<String, dynamic>>[];

    for (final recordCache in cache.recordsMap.values) {
      final record = recordCache.record;
      if (record[fieldName] == fieldValue) {
        result.add(Map<String, dynamic>.from(record));
        recordCache.recordAccess();
      }
    }

    if (result.isNotEmpty) {
      cache.recordAccess();
    }

    return result;
  }

  /// Invalidate all cache of a table
  Future<void> invalidateCache(String tableName) async {
    try {
      // 1. Clear table dependency cache
      _tableDependencies.remove(tableName);

      // 2. Clear all related queries cache in general cache
      final keysToRemove = <String>[];
      _queryCache.cache.forEach((key, queryCache) {
        if (queryCache.tableName == tableName) {
          keysToRemove.add(key);
        }
      });

      for (var key in keysToRemove) {
        _queryCache.invalidate(key);
      }

      // 3. Clear schema cache
      _schemaCache.remove(tableName);

      // 4. Clear stats cache
      _statsCache.remove(tableName);

      // 5. Reset table cache and mark as full table cache
      // Get table's primary key field name
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
        Logger.error('Table $tableName does not exist',
            label: 'DataCacheManager.invalidateCache');
        return;
      }
      final primaryKeyField = schema.primaryKey;

      // Create a new empty table cache and mark as full table cache
      final newTableCache = TableCache(
        tableName: tableName,
        primaryKeyField: primaryKeyField,
        isFullTableCache: true, // Mark as full table cache
        cacheTime: DateTime.now(),
        lastAccessed: DateTime.now(),
      );

      // Replace old cache
      tableCaches[tableName] = newTableCache;
    } catch (e) {
      Logger.error(
        'Clear table cache failed: $e\n'
        'tableName: $tableName',
        label: 'QueryCacheManager.invalidateCache',
      );
    }
  }

  /// Get table cache time
  DateTime? getTableCacheTime(String tableName) {
    return tableCaches[tableName]?.cacheTime;
  }

  /// Record table cache access
  void recordTableAccess(String tableName) {
    final cache = tableCaches[tableName];
    if (cache != null) {
      cache.recordAccess();
    }
  }

  /// Get table cache count
  int getTableCacheCount(String tableName) {
    return tableCaches[tableName]?.recordCount ?? 0;
  }

  /// Get query cache count
  int getQueryCacheCountAll() {
    return _queryCache.size;
  }

  /// Get table cache count
  int getTableCacheCountAll() {
    return tableCaches.values
        .fold(0, (sum, cache) => sum + (cache.recordCount));
  }

  /// Get list of all table cache names
  List<String> getAllTableCacheNames() {
    return tableCaches.keys.toList();
  }
}

/// Query info, contains query conditions, primary key field name and result set
class _QueryInfo {
  final QueryCacheKey queryKey; // Query conditions
  final String primaryKeyField; // Primary key field name
  final List<Map<String, dynamic>> results; // Query result set
  final bool isFullTableCache; // Whether it is full table cache

  _QueryInfo({
    required this.queryKey,
    required this.primaryKeyField,
    required this.results,
    this.isFullTableCache = false,
  });
}
