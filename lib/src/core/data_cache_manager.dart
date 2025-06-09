import 'dart:math';
import '../model/cache.dart';
import 'data_store_impl.dart';
import '../handler/logger.dart';
import '../model/table_schema.dart';
import '../statistic/table_statistics.dart';
import '../query/query_cache.dart';
import '../query/query_condition.dart';
import 'crontab_manager.dart';
import 'dart:convert';

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

    _cronJobsRegistered = true;
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
        _queryCache.evictStaleEntries();
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
    DateTime? lastCacheCleanupTime,
  }) async {
    try {
      final spaceConfig = await _dataStore.getSpaceConfig();
      if (spaceConfig == null) return;

      final newConfig = spaceConfig.copyWith(
        lastCacheWeightProcessTime: lastCacheWeightProcessTime,
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

      // Notify index manager to save cache
      final indexManager = _dataStore.indexManager;
      bool indexSaved = false;
      if (indexManager != null) {
        indexSaved = await indexManager.saveBeforeAppExit();

        // Index manager has saved index changes, return directly
        if (indexSaved) {
          return true;
        }
      }

      return hasChanges;
    } catch (e) {
      Logger.error('Failed to persist all caches: $e',
          label: 'DataCacheManager.persistAllCaches');
      return false;
    }
  }

  /// Cache query results
  ///
  /// Cache query results optimization strategy:
  /// 1. Store complete query results in _queryCache (including all fields and records)
  /// 2. Store only query metadata and primary key values in _tableDependencies (through _QueryInfo)
  void cacheQuery(
    QueryCacheKey key,
    List<Map<String, dynamic>> results,
    Set<String> tables, {
    Duration? expiryDuration,
  }) async {
    try {
      final cacheKey = key.toString();
      final schema = await _dataStore.getTableSchema(tables.first);
      if (schema == null) {
        Logger.error('Table ${tables.first} does not exist',
            label: 'DataCacheManager.cacheQuery');
        return;
      }

      // Query results are stored only once in _queryCache
      _queryCache.put(
        cacheKey,
        results,
        tables.first,
        schema.primaryKey,
        expiryDuration: expiryDuration,
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

        // Create _QueryInfo object, pass in query results but only extract primary key values
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

  /// Invalidate specific query by cache key
  /// Returns the number of entries removed (0 or 1)
  int invalidateQuery(String tableName, String cacheKey) {
    try {
      // directly access the dependency cache of the specific table
      final tableDependency = _tableDependencies[tableName];
      if (tableDependency == null) return 0;

      // remove specific query cache
      if (tableDependency.containsKey(cacheKey)) {
        tableDependency.remove(cacheKey);

        // check if the table dependency is empty
        if (tableDependency.isEmpty) {
          _tableDependencies.remove(tableName);
        }

        // remove the query cache
        return _queryCache.invalidateQuery(cacheKey);
      }
      return 0;
    } catch (e) {
      Logger.error('Failed to invalidate query: $e',
          label: 'DataCacheManager.invalidateQuery');
      return 0;
    }
  }

  /// used to quickly clear the query cache corresponding to a specific primary key
  Future<void> invalidateRecordByPrimaryKey(
      String tableName, dynamic primaryKeyValue) async {
    try {
      // get the table structure to get the primary key field name
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) return;
      final primaryKeyField = schema.primaryKey;

      // build the primary key equal query condition
      final condition =
          QueryCondition().where(primaryKeyField, '=', primaryKeyValue);
      final cacheKey = QueryCacheKey(
        tableName: tableName,
        condition: condition,
      ).toString();

      // directly try to clear this specific cache
      _queryCache.invalidateQuery(cacheKey);

      // remove from table dependency
      _tableDependencies[tableName]?.remove(cacheKey);
    } catch (e) {
      Logger.error('Failed to invalidate record by primary key: $e',
          label: 'DataCacheManager.invalidateRecordByPrimaryKey');
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
        // Get the record to be deleted (for later condition matching)
        final recordToRemove = tableCache.getRecord(pkString)?.record;
        // Remove record from cache, but don't affect full table cache status
        tableCache.recordsMap.remove(pkString);

        // If the record is not in the cache, we cannot perform precise condition matching
        // In this case, we only clean up those queries that are full table caches
        if (recordToRemove == null) {
          _cleanupFullTableQueriesOnly(tableName);
          return;
        }

        // If there is a record, we can perform more precise condition matching
        await _cleanupRelatedQueries(
            tableName, primaryKeyValue, recordToRemove);
      } else {
        // If the table cache does not exist, only clean up full table cache queries
        _cleanupFullTableQueriesOnly(tableName);
      }
    } catch (e) {
      Logger.error('Invalidate record cache failed: $e',
          label: 'QueryCacheManager.invalidateRecord');
    }
  }

  /// Only clean up full table cache queries
  void _cleanupFullTableQueriesOnly(String tableName) {
    final tableDependency = _tableDependencies[tableName];
    if (tableDependency == null) return;

    // List of keys to clean up
    final keysToRemove = <String>[];

    // Check each query, only clean up full table cache queries
    for (var entry in tableDependency.entries) {
      final queryInfo = entry.value;

      // skip user-managed caches, these caches need to be manually invalidated by the user
      try {
        final cacheKeyStr = entry.key;
        final cacheKeyMap = jsonDecode(cacheKeyStr) as Map<String, dynamic>;
        final isUserManaged = cacheKeyMap['isUserManaged'] == true;

        if (isUserManaged) {
          continue; // skip user-managed caches
        }
      } catch (e) {
        // parse error, conservative handling, assume it is system cache
      }

      if (queryInfo.isFullTableCache) {
        keysToRemove.add(entry.key);
      }
    }

    // Remove related query cache
    for (var key in keysToRemove) {
      _queryCache.invalidate(key);
      tableDependency.remove(key);
    }

    // If there are no related queries, clean up dependencies
    if (tableDependency.isEmpty) {
      _tableDependencies.remove(tableName);
    }
  }

  /// Clean up queries related to specific records
  Future<void> _cleanupRelatedQueries(String tableName, dynamic primaryKeyValue,
      Map<String, dynamic> recordData) async {
    final tableQueries = _tableDependencies[tableName];
    if (tableQueries == null) return;

    // first clean up the primary key equal cache (direct fast path)
    try {
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema != null) {
        await invalidateRecordByPrimaryKey(tableName, primaryKeyValue);
      }
    } catch (e) {
      // ignore error, continue with general cleanup process
    }

    // List of keys to clean up
    final keysToRemove = <String>[];

    // Check each query
    for (var entry in tableQueries.entries) {
      final queryInfo = entry.value;

      // skip user-managed caches, these caches need to be manually invalidated by the user
      try {
        final cacheKeyStr = entry.key;
        final cacheKeyMap = jsonDecode(cacheKeyStr) as Map<String, dynamic>;
        final isUserManaged = cacheKeyMap['isUserManaged'] == true;

        if (isUserManaged) {
          continue; // skip user-managed caches
        }
      } catch (e) {
        // parse error, conservative handling, assume it is system cache
      }

      // If it is a full table cache or record matches the condition, invalidate the cache
      if (queryInfo.isFullTableCache ||
          queryInfo.queryKey.condition.matches(recordData)) {
        keysToRemove.add(entry.key);
      }
    }

    // Remove related cache
    for (var key in keysToRemove) {
      _queryCache.invalidate(key);
      tableQueries.remove(key);
    }

    // If there are no related queries, clean up dependencies
    if (tableQueries.isEmpty) {
      _tableDependencies.remove(tableName);
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

      // Collect the data of the records to be deleted, for subsequent condition matching
      List<Map<String, dynamic>> recordsToRemove = [];

      // Handle specific record invalidation
      if (tableCache != null) {
        // Collect the data of the records to be deleted, for subsequent condition matching
        for (var pkValue in primaryKeyValues) {
          final pkString = pkValue.toString();
          final recordCache = tableCache.getRecord(pkString);
          if (recordCache != null) {
            recordsToRemove.add(recordCache.record);
          }
        }

        // Remove records with specified primary key values from cache
        for (var pkValue in primaryKeyValues) {
          final pkString = pkValue.toString();
          tableCache.recordsMap.remove(pkString);
        }
      }

      // Determine whether to use exact matching or conservative cleanup strategy
      final bool useExactMatching =
          tableCache != null && recordsToRemove.isNotEmpty;

      if (useExactMatching) {
        // If there are record data, we can perform precise condition matching
        await _cleanupRelatedQueriesForMultipleRecords(
            tableName, recordsToRemove);
      } else {
        // If there is no record data or the table cache does not exist, use conservative strategy to clean up all related queries
        _cleanupFullTableQueriesOnly(tableName);

        // For any query containing primary key values, also need to clean up
        _cleanupQueriesContainingPrimaryKeys(tableName, primaryKeyValues);
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

  /// Clean up queries containing specified primary key values
  void _cleanupQueriesContainingPrimaryKeys(
      String tableName, Set<dynamic> primaryKeyValues) {
    final tableDependency = _tableDependencies[tableName];
    if (tableDependency == null) return;

    // List of keys to clean up
    final keysToRemove = <String>[];

    // Check each query
    for (var entry in tableDependency.entries) {
      final queryInfo = entry.value;

      // skip user-managed caches, these caches need to be manually invalidated by the user
      try {
        final cacheKeyStr = entry.key;
        final cacheKeyMap = jsonDecode(cacheKeyStr) as Map<String, dynamic>;
        final isUserManaged = cacheKeyMap['isUserManaged'] == true;

        if (isUserManaged) {
          continue; // skip user-managed caches
        }
      } catch (e) {
        // parse error, conservative handling, assume it is system cache
      }

      // If any record's primary key is in primaryKeyValues, clean up the query
      // Now check the intersection of the primary key set directly, instead of traversing the complete record
      if (queryInfo.resultKeys.any((key) => primaryKeyValues.contains(key))) {
        keysToRemove.add(entry.key);
      }
    }

    // Remove related query cache
    for (var key in keysToRemove) {
      _queryCache.invalidate(key);
      tableDependency.remove(key);
    }

    // If there are no related queries, clean up dependencies
    if (tableDependency.isEmpty) {
      _tableDependencies.remove(tableName);
    }
  }

  /// Clean up related query cache for multiple records
  Future<void> _cleanupRelatedQueriesForMultipleRecords(
      String tableName, List<Map<String, dynamic>> records) async {
    final tableQueries = _tableDependencies[tableName];
    if (tableQueries == null) return;

    // List of keys to clean up
    final keysToRemove = <String>[];

    // Extract all record primary key values
    final recordPrimaryKeys = <String>{};
    final schema = await _dataStore.getTableSchema(tableName);
    if (schema != null) {
      final primaryKeyField = schema.primaryKey;
      for (final record in records) {
        final pkValue = record[primaryKeyField]?.toString();
        if (pkValue != null && pkValue.isNotEmpty) {
          recordPrimaryKeys.add(pkValue);
        }
      }
    }

    // check each query
    for (var entry in tableQueries.entries) {
      final queryInfo = entry.value;

      // skip user-managed caches, these caches need to be manually invalidated by the user
      try {
        final cacheKeyStr = entry.key;
        final cacheKeyMap = jsonDecode(cacheKeyStr) as Map<String, dynamic>;
        final isUserManaged = cacheKeyMap['isUserManaged'] == true;

        if (isUserManaged) {
          continue; // skip user-managed caches
        }
      } catch (e) {
        // parse error, conservative handling, assume it is system cache
      }

      // 1. If it is a full table cache, clean up directly
      if (queryInfo.isFullTableCache) {
        keysToRemove.add(entry.key);
        continue;
      }

      // 2. Check primary key intersection first - if the primary keys of these records intersect with the primary keys of the query results, clean up the cache
      if (recordPrimaryKeys.isNotEmpty &&
          queryInfo.resultKeys.any((key) => recordPrimaryKeys.contains(key))) {
        keysToRemove.add(entry.key);
        continue;
      }

      // 3. If there is no primary key intersection, check if there is a record that satisfies the query condition
      for (final recordData in records) {
        if (queryInfo.queryKey.condition.matches(recordData)) {
          keysToRemove.add(entry.key);
          break; // As long as one record matches, clean up the query
        }
      }
    }

    // Remove related query cache
    for (var key in keysToRemove) {
      _queryCache.invalidate(key);
      tableQueries.remove(key);
    }

    // If there are no related queries, clean up dependencies
    if (tableQueries.isEmpty) {
      _tableDependencies.remove(tableName);
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
    try {
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
    } catch (e) {
      Logger.error('Cache entire table failed: $e',
          label: 'DataCacheManager.cacheEntireTable');
    }
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

  /// Set full table cache flag
  Future<void> setFullTableCache(
      String tableName, bool isFullTableCache) async {
    final cache = tableCaches[tableName];
    if (cache == null) {
      // Create new table cache
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) return;
      final primaryKeyField = schema.primaryKey;
      final now = DateTime.now();
      final tableCache = TableCache(
        tableName: tableName,
        primaryKeyField: primaryKeyField,
        isFullTableCache: isFullTableCache,
        cacheTime: now,
        lastAccessed: now,
      );
      tableCaches[tableName] = tableCache;
      return;
    }
    cache.isFullTableCache = isFullTableCache;
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

  /// Get records by multiple primary keys
  List<Map<String, dynamic>> getRecordsByPrimaryKeys(
      String tableName, List<String> pkValues) {
    final cache = tableCaches[tableName];
    if (cache == null) return [];

    final results = <Map<String, dynamic>>[];
    for (final pkValue in pkValues) {
      final record = cache.getRecord(pkValue);
      if (record != null) {
        results.add(record.record);
      }
    }
    return results;
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
  Future<void> invalidateCache(String tableName,
      {bool isFullTableCache = false}) async {
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

      if (!isFullTableCache) {
        final recordCount =
            await _dataStore.tableDataManager.getTableRecordCount(tableName);
        isFullTableCache = recordCount == 0;
      }

      // Create a new empty table cache and mark as full table cache
      final newTableCache = TableCache(
        tableName: tableName,
        primaryKeyField: primaryKeyField,
        isFullTableCache: isFullTableCache, // Mark as full table cache
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

  /// Get list of all full table cache names
  List<String> getAllFullTableCaches() {
    return tableCaches.entries
        .where((entry) => entry.value.isFullTableCache)
        .map((entry) => entry.key)
        .toList();
  }
}

/// Query info, contains query conditions, primary key field name and only primary key values of results
class _QueryInfo {
  final QueryCacheKey queryKey; // Query conditions
  final String primaryKeyField; // Primary key field name
  final Set<String>
      resultKeys; // Only store primary key values of query results, not complete record content
  final bool isFullTableCache; // Whether it is a full table cache

  _QueryInfo({
    required this.queryKey,
    required this.primaryKeyField,
    required List<Map<String, dynamic>> results,
    this.isFullTableCache = false,
  }) : resultKeys = results
            .map((record) => record[primaryKeyField]?.toString() ?? '')
            .where((key) => key.isNotEmpty)
            .toSet();
}
