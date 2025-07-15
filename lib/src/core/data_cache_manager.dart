import 'dart:math';
import '../model/cache.dart';
import 'data_store_impl.dart';
import '../handler/logger.dart';
import '../model/table_schema.dart';
import '../model/table_statistics.dart';
import '../query/query_cache.dart';
import 'crontab_manager.dart';
import 'memory_manager.dart';
import 'dart:async';
import '../handler/value_matcher.dart';

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

  // Incremental cache total size (bytes)
  int _totalRecordCacheSize = 0;
  int _totalSchemaCacheSize = 0;

  // Stats cache
  final Map<String, TableStatistics> _statsCache = {};

  // Periodic task registration flag
  bool _cronJobsRegistered = false;

  // Space switching status flag
  bool _isSwitchingSpace = false;

  DataCacheManager(this._dataStore)
      : _queryCache = QueryCache(
          maxSizeBytes: _dataStore.memoryManager?.getQueryCacheSize() ??
              5000000, // Default to 5MB
        ) {
    // Register periodic tasks
    _registerCronJobs();

    // Register memory callbacks
    _registerMemoryCallbacks();

    // Initialize to 0, then recalculate before first use
    _totalSchemaCacheSize = 0;
    _totalRecordCacheSize = 0;
  }

  /// Register memory callbacks
  void _registerMemoryCallbacks() {
    final memoryManager = _dataStore.memoryManager;
    if (memoryManager != null) {
      // Register cache eviction callbacks
      memoryManager.registerCacheEvictionCallback(CacheType.query, () {
        _evictQueryCache(0.3); // Evict 30% of query cache
      });

      memoryManager.registerCacheEvictionCallback(CacheType.schema, () {
        _evictSchemaCache(0.3); // Evict 30% of schema cache
      });

      memoryManager.registerCacheEvictionCallback(CacheType.record, () {
        _evictLowPriorityRecords(); // Evict low priority records
      });
    }
  }

  /// Estimate schema size (in bytes)
  int _estimateSchemaSize(TableSchema schema) {
    // Base schema size
    int size = 100;

    // Field contribution
    size += schema.fields.length * 50; // Each field is about 50 bytes

    // Index contribution
    size += schema.indexes.length * 30; // Each index is about 30 bytes

    // Other properties contribution
    size += schema.name.length * 2; // Table name
    size += 50; // Primary key configuration, etc.

    return size;
  }

  /// Evict query cache
  Future<void> _evictQueryCache(double ratio) async {
    if (ratio <= 0 || ratio > 1) return;

    try {
      final toRemoveCount = (_queryCache.size * ratio).ceil();
      if (toRemoveCount <= 0) return;

      await _queryCache.evictByCount(toRemoveCount);

      Logger.info(
          'Evicted $toRemoveCount query cache entries due to memory pressure',
          label: 'DataCacheManager._evictQueryCache');
    } catch (e) {
      Logger.error('Failed to evict query cache: $e',
          label: 'DataCacheManager._evictQueryCache');
    }
  }

  /// Evict schema cache
  void _evictSchemaCache(double ratio) {
    if (ratio <= 0 || ratio > 1) return;
    if (_schemaCache.isEmpty) return;

    try {
      final toRemoveCount = (_schemaCache.length * ratio).ceil();
      if (toRemoveCount <= 0) return;

      // Only evict non-global table caches
      final nonGlobalTables = _schemaCache.entries
          .where((entry) => entry.value.isGlobal != true)
          .toList();

      if (nonGlobalTables.isEmpty) return;

      // Remove specified number of table caches
      final actualRemoveCount = min(toRemoveCount, nonGlobalTables.length);
      for (int i = 0; i < actualRemoveCount; i++) {
        final tableName = nonGlobalTables[i].key;
        final schema = _schemaCache[tableName];
        if (schema != null) {
          // Subtract the size of the removed schema
          _totalSchemaCacheSize -= _estimateSchemaSize(schema);
        }
        _schemaCache.remove(tableName);
      }

      Logger.info(
          'Evicted $actualRemoveCount schema cache entries due to memory pressure',
          label: 'DataCacheManager._evictSchemaCache');
    } catch (e) {
      Logger.error('Failed to evict schema cache: $e',
          label: 'DataCacheManager._evictSchemaCache');
    }
  }

  /// Register periodic tasks
  void _registerCronJobs() {
    if (_cronJobsRegistered) return;

    // Register 1-hour periodic task for cleaning expired cache
    CrontabManager.addCallback(ExecuteInterval.hour1, _cleanupExpiredCache);

    _cronJobsRegistered = true;
  }

  /// Clean up expired cache
  Future<void> _cleanupExpiredCache() async {
    // Check if space switching is in progress
    if (_isSwitchingSpace) {
      return;
    }

    try {
      // Get schema cache size limit using memory manager
      final schemaCacheMaxSize =
          _dataStore.memoryManager?.getSchemaCacheSize() ?? 10000;

      // Use stored incremental cache size instead of recalculating
      final currentSchemaSize = _totalSchemaCacheSize;

      // Check if schema cache exceeds limit (using 90% as threshold)
      if (currentSchemaSize > schemaCacheMaxSize * 0.9) {
        // Calculate the ratio to be cleaned up
        final removeRatio =
            1.0 - (schemaCacheMaxSize * 0.7 / currentSchemaSize);
        final removeCount = (removeRatio * _schemaCache.length).ceil();

        // Create list of non-global tables
        final nonGlobalTables = _schemaCache.entries
            .where((entry) => entry.value.isGlobal != true)
            .toList();

        // If there are non-global tables, clean them up
        if (nonGlobalTables.isNotEmpty) {
          // Clean up the maximum number of calculated entries
          final toRemove = min(nonGlobalTables.length, removeCount);

          for (int i = 0; i < toRemove; i++) {
            final tableName = nonGlobalTables[i].key;
            final schema = _schemaCache[tableName];
            if (schema != null) {
              // Subtract the size of the schema being removed
              _totalSchemaCacheSize -= _estimateSchemaSize(schema);
            }
            _schemaCache.remove(tableName);
          }

          Logger.debug('Cleaned up $toRemove table structure caches',
              label: 'DataCacheManager._cleanupExpiredCache');
        }
      }

      // Clean up query cache
      final queryCacheMaxSize =
          _dataStore.memoryManager?.getQueryCacheSize() ?? 10000;
      // Use the actual query cache total size tracker
      final currentQueryCacheSize = _queryCache.totalCacheSize;

      if (currentQueryCacheSize > queryCacheMaxSize * 0.9) {
        await _queryCache.evictStaleEntries();
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
  Future<void> cacheQuery(
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
      await _queryCache.put(
        cacheKey,
        results,
        tables.first,
        schema.primaryKey,
        expiryDuration: expiryDuration,
      );

      // Record the dependency between queries and tables
      for (var table in tables.toList()) {
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
  /// Returns true if the operation completes without error, false otherwise.
  Future<bool> invalidateQuery(String tableName, String cacheKey) async {
    try {
      // Attempt to invalidate the query from the primary cache.
      // We don't need the return value here because "not found" is a success case.
      await _queryCache.invalidateQuery(cacheKey);

      // If the table dependency exists, also clean it up
      final tableDependency = _tableDependencies[tableName];
      if (tableDependency != null) {
        // Remove from table dependency
        if (tableDependency.containsKey(cacheKey)) {
          tableDependency.remove(cacheKey);
          // If the table dependency is empty, clean up the entire table dependency
          if (tableDependency.isEmpty) {
            _tableDependencies.remove(tableName);
          }
        }
      }

      return true;
    } catch (e) {
      Logger.error('Failed to invalidate query: $e',
          label: 'DataCacheManager.invalidateQuery');
      return false;
    }
  }

  /// Add record to cache
  void addCachedRecord(String tableName, Map<String, dynamic> record) {
    final cache = tableCaches[tableName];
    if (cache == null) return;

    // Record the cache size before adding
    final beforeSize = cache.totalCacheSize;

    cache.addOrUpdateRecord(record);

    // Update the total cache size
    _totalRecordCacheSize += (cache.totalCacheSize - beforeSize);
  }

  /// Update record in cache (without changing order)
  void updateCachedRecord(String tableName, Map<String, dynamic> record) {
    final cache = tableCaches[tableName];
    if (cache == null) return;

    // Record the size before updating
    final beforeSize = cache.totalCacheSize;

    cache.updateRecord(record);

    // Update the total cache size
    _totalRecordCacheSize += (cache.totalCacheSize - beforeSize);
  }

  /// Update record data in query cache
  Future<void> updateQueryCacheForRecord(String tableName,
      dynamic primaryKeyValue, Map<String, dynamic> updatedRecord) async {
    try {
      final tableDependency = _tableDependencies[tableName];
      if (tableDependency != null) {
        final pkString = primaryKeyValue.toString();
        int processedCount = 0;

        final schema = await _dataStore.getTableSchema(tableName);
        if (schema == null) {
          Logger.error('Table schema not found for table $tableName',
              label: 'DataCacheManager.updateQueryCacheForRecord');
          return;
        }

        for (var cacheKeyStr in tableDependency.keys.toList()) {
          final queryInfo = tableDependency[cacheKeyStr];
          if (queryInfo == null) continue;

          // Check if this query result contains the record
          if (queryInfo.isFullTableCache ||
              queryInfo.resultKeys.contains(pkString)) {
            // Get query cache
            final cachedResults = _queryCache.get(cacheKeyStr);
            if (cachedResults != null) {
              // Update the record in the query result, rather than deleting the entire query cache
              bool found = false;
              for (int i = 0; i < cachedResults.length; i++) {
                if (cachedResults[i][queryInfo.primaryKeyField]?.toString() ==
                    pkString) {
                  // Update the record content, keep the position in the result set
                  cachedResults[i] = Map<String, dynamic>.from(updatedRecord);
                  found = true;
                  break;
                }
                if (i % 50 == 0) {
                  await Future.delayed(Duration.zero);
                }
              }

              // If it is a full table cache but the record is not found, it may need to be added to the result
              if (!found && queryInfo.isFullTableCache) {
                // Check if the updated record matches the query condition

                final matcher = queryInfo.queryKey.condition.isEmpty
                    ? null
                    : ConditionRecordMatcher.prepare(
                        queryInfo.queryKey.condition,
                        {tableName: schema},
                        tableName);
                if (matcher?.matches(updatedRecord) ?? true) {
                  cachedResults.add(Map<String, dynamic>.from(updatedRecord));
                  // Remember to update the resultKeys collection
                  queryInfo.resultKeys.add(pkString);
                }
              }
            }
          }
          processedCount++;
          if (processedCount % 50 == 0) {
            await Future.delayed(Duration.zero);
          }
        }
      }
    } catch (e) {
      Logger.error('Failed to update query cache for record: $e',
          label: 'DataCacheManager.updateQueryCacheForRecord');
    }
  }

  /// Remove table cache for primary key
  void removeTableCacheForPrimaryKey(String tableName, String primaryKeyValue) {
    final cache = tableCaches[tableName];
    if (cache == null) return;
    final removed = cache.recordsMap.remove(primaryKeyValue);
    if (removed != null) {
      cache.removeRecordAndUpdateStats(removed);
    }
  }

  /// Invalidate multiple records from the cache for a specific table.
  /// [primaryKeyValues] is a list of primary key values to invalidate.
  /// [records] contains the data of the records being invalidated
  Future<void> invalidateRecords(
    String tableName,
    List<String> primaryKeyValues,
    List<Map<String, dynamic>> records,
  ) async {
    try {
      // Invalidate records from the TableCache
      final tableCache = tableCaches[tableName];
      if (tableCache != null) {
        // Now, remove the records from the cache.
        for (var i = 0; i < primaryKeyValues.length; i++) {
          final pkValue = primaryKeyValues[i];
          final removed = tableCache.recordsMap.remove(pkValue);
          if (removed != null) {
            tableCache.removeRecordAndUpdateStats(removed);
          }
          if (i % 50 == 0) {
            await Future.delayed(Duration.zero);
          }
        }
      }
    } catch (e) {
      Logger.error(
        'Failed to invalidate records: $e',
        label: 'DataCacheManager.invalidateRecords',
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

    // Reset cache size statistics
    _totalRecordCacheSize = 0;
    _totalSchemaCacheSize = 0;

    Logger.debug('Clear all cache', label: 'QueryCacheManager.clear');
  }

  /// Cache entire table
  Future<void> cacheEntireTable(
    String tableName,
    String primaryKeyField,
    List<Map<String, dynamic>> records, {
    bool isFullTableCache = true,
  }) async {
    try {
      // Check if the number of records is too large, if so, don't cache the full table
      bool needCacheFullTableCache = isFullTableCache;

      // Get memory manager
      final memoryManager = _dataStore.memoryManager;
      final recordCacheSize = memoryManager?.getRecordCacheSize() ?? 10000;

      // Use the standardized estimation method to get the byte size of the new records.
      final estimatedNewRecordsSize = TableCache.estimateRecordsSize(records);

      if (isFullTableCache && estimatedNewRecordsSize > recordCacheSize) {
        // The table is too large to be considered a "full table cache" against the total limit.
        needCacheFullTableCache = false;
      }

      if (isFullTableCache && !needCacheFullTableCache) {
        Logger.warn(
          'Table $tableName with estimated size ${estimatedNewRecordsSize / 1024}KB exceeds the record cache limit of ${recordCacheSize / 1024}KB. It will not be marked as a full table cache.',
          label: 'DataCacheManager.cacheEntireTable',
        );
      }

      // Check if adding the new records would exceed the allocated cache size.
      if (_totalRecordCacheSize + estimatedNewRecordsSize > recordCacheSize) {
        // Execute cache eviction policy if the limit is exceeded.
        _evictLowPriorityRecords();
      }

      // Get current time as cache time
      final now = DateTime.now();

      // --- Refactored Cache Update Logic ---

      // 1. Get the cache size of the table *before* any modifications.
      final oldCacheSize = tableCaches[tableName]?.totalCacheSize ?? 0;

      // 2. Get or create the TableCache instance.
      final tableCache = tableCaches.putIfAbsent(tableName, () {
        return TableCache(
          tableName: tableName,
          primaryKeyField: primaryKeyField,
        );
      });

      // If this is a full cache replacement, clear out the old records first.
      // This correctly resets the table's internal size before adding new records.
      if (needCacheFullTableCache) {
        tableCache.clearRecords();
      }

      // 3. Update cache metadata and add new records. `addRecords` will correctly
      //    update the internal `totalCacheSize` of the tableCache instance.
      tableCache.cacheTime = now;
      tableCache.lastAccessed = now;
      if (records.isNotEmpty) {
        await tableCache.addRecords(records,
            cacheType: RecordCacheType.runtime);
      }

      // **CRITICAL**: Set the full table cache flag only AFTER all records have been added.
      // This prevents a race condition where a query might see a partially populated "full" cache.
      tableCache.isFullTableCache = needCacheFullTableCache;

      // 4. Atomically update the global cache size.
      // The change is simply the difference between the new and old size of the table's cache.
      final newCacheSize = tableCache.totalCacheSize;
      _totalRecordCacheSize += (newCacheSize - oldCacheSize);
    } catch (e) {
      Logger.error('Cache entire table failed: $e',
          label: 'DataCacheManager.cacheEntireTable');
    }
  }

  /// Evict low priority records by evicting whole tables based on LRU.
  Future<void> _evictLowPriorityRecords() async {
    try {
      if (tableCaches.isEmpty) return;
      final memoryManager = _dataStore.memoryManager;
      if (memoryManager == null) return;

      final cacheLimit = memoryManager.getRecordCacheSize();
      final targetCacheSize = (cacheLimit * 0.7).toInt();

      if (_totalRecordCacheSize <= targetCacheSize) {
        return;
      }

      int bytesToEvict = _totalRecordCacheSize - targetCacheSize;
      int bytesEvicted = 0;

      // 1. Get all table caches as candidates for eviction.
      // This sort is on the list of tables, which is usually small.
      // So, a synchronous sort is acceptable here.
      final evictableTables = tableCaches.values.toList()
        ..sort((a, b) => a.lastAccessed.compareTo(b.lastAccessed));

      final tablesToRemove = <String>[];
      int processedCount = 0;

      // 2. Identify which entire tables to evict.
      for (final tableCache in evictableTables) {
        if (bytesEvicted >= bytesToEvict) break;

        bytesEvicted += tableCache.totalCacheSize;
        tablesToRemove.add(tableCache.tableName);

        // Yield to the event loop to prevent UI jank if there are many tables.
        processedCount++;
        if (processedCount % 20 == 0) {
          await Future.delayed(Duration.zero);
        }
      }

      // 3. Perform the actual removal.
      for (final tableName in tablesToRemove) {
        final removedCache = tableCaches.remove(tableName);
        if (removedCache != null) {
          _totalRecordCacheSize -= removedCache.totalCacheSize;
        }
        // Yield again during removal if the list is very large.
        processedCount++;
        if (processedCount % 20 == 0) {
          await Future.delayed(Duration.zero);
        }
      }

      if (bytesEvicted > 0) {
        Logger.debug(
            'Cache eviction: evicted ${tablesToRemove.length} entire tables (${(bytesEvicted / 1024).toStringAsFixed(2)} KB) to free up memory.',
            label: 'DataCacheManager._evictLowPriorityRecords');
      }
    } catch (e) {
      Logger.error('Failed to evict low priority records: $e',
          label: 'DataCacheManager._evictLowPriorityRecords');
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

  /// Cache schema
  void cacheSchema(String tableName, TableSchema schema) {
    // If the schema for this table already exists, subtract its size first
    if (_schemaCache.containsKey(tableName)) {
      _totalSchemaCacheSize -= _estimateSchemaSize(_schemaCache[tableName]!);
    }

    // Cache the new schema and add its size
    _schemaCache[tableName] = schema;
    _totalSchemaCacheSize += _estimateSchemaSize(schema);
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
      tableCaches.removeWhere((tableName, cache) {
        final schema = _schemaCache[tableName];
        final isNonGlobal = schema?.isGlobal != true;
        if (isNonGlobal) {
          // Subtract the size of the table cache to be removed
          _totalRecordCacheSize -= cache.totalCacheSize;
        }
        return isNonGlobal;
      });

      // 3. Clear related dependencies
      _tableDependencies.removeWhere((tableName, _) {
        final schema = _schemaCache[tableName];
        return schema?.isGlobal != true;
      });

      // 4. Clear non-global table structure cache
      _schemaCache.removeWhere((tableName, schema) {
        final isNonGlobal = schema.isGlobal != true;
        if (isNonGlobal) {
          // Subtract the size of the schema cache to be removed
          _totalSchemaCacheSize -= _estimateSchemaSize(schema);
        }
        return isNonGlobal;
      });

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
  Future<List<Map<String, dynamic>>> getRecordsByPrimaryKeys(
      String tableName, List<String> pkValues) async {
    final cache = tableCaches[tableName];
    if (cache == null) return [];

    final results = <Map<String, dynamic>>[];
    int processedCount = 0;
    for (final pkValue in pkValues) {
      final record = cache.getRecord(pkValue);
      if (record != null) {
        results.add(record.record);
      }
      processedCount++;
      if (processedCount % 50 == 0) {
        await Future.delayed(Duration.zero);
      }
    }
    return results;
  }

  /// Query records by field value
  Future<List<Map<String, dynamic>>> queryRecordsByField(
    String tableName,
    String fieldName,
    dynamic fieldValue,
  ) async {
    final cache = tableCaches[tableName];
    if (cache == null) return [];

    final result = <Map<String, dynamic>>[];
    int processedCount = 0;
    final tableSchema = await _dataStore.getTableSchema(tableName);
    if (tableSchema == null) return [];
    final matcher =
        ValueMatcher.getMatcher(tableSchema.getFieldMatcherType(fieldName));

    // Convert the query value to the correct type before matching.
    FieldSchema? fieldSchema;
    if (fieldName == tableSchema.primaryKey) {
      fieldSchema = FieldSchema(
          name: fieldName,
          type: tableSchema.primaryKeyConfig.getDefaultDataType());
    } else {
      try {
        fieldSchema = tableSchema.fields.firstWhere((f) => f.name == fieldName);
      } catch (_) {
        // Field not found, proceed without conversion.
      }
    }
    final convertedValue = fieldSchema?.convertValue(fieldValue) ?? fieldValue;

    // Use the efficient key-collection pattern
    for (final key in cache.recordsMap.keys.toList()) {
      final recordCache = cache.recordsMap[key];
      if (recordCache == null) continue;
      final record = recordCache.record;
      if (matcher(record[fieldName], convertedValue) == 0) {
        result.add(Map<String, dynamic>.from(record));
        recordCache.recordAccess();
      }
      processedCount++;
      if (processedCount % 500 == 0) {
        // Yield to event loop to avoid blocking UI
        await Future.delayed(Duration.zero);
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
      // Get and subtract the old cache size
      final oldCache = tableCaches[tableName];
      if (oldCache != null) {
        _totalRecordCacheSize -= oldCache.totalCacheSize;
      }

      // 1. Clear table dependency cache
      _tableDependencies.remove(tableName);

      // 2. Clear all related queries cache in general cache
      final keysToRemove = <String>[];
      int processedCount = 0;
      // Use the efficient key-collection pattern to iterate
      final keys = _queryCache.cache.keys.toList();
      for (final key in keys) {
        final entryValue = _queryCache.cache[key];
        // The entry could have been removed by another process in the await gap.
        if (entryValue == null) continue;
        if (entryValue.tableName == tableName) {
          keysToRemove.add(key);
        }
        processedCount++;
        if (processedCount % 50 == 0) {
          // Yield to event loop to avoid blocking UI
          await Future.delayed(Duration.zero);
        }
      }

      processedCount = 0;
      for (var key in keysToRemove) {
        _queryCache.invalidate(key);
        processedCount++;
        if (processedCount % 50 == 0) {
          await Future.delayed(Duration.zero);
        }
      }

      // 3. Clear schema cache
      if (_schemaCache.containsKey(tableName)) {
        _totalSchemaCacheSize -= _estimateSchemaSize(_schemaCache[tableName]!);
        _schemaCache.remove(tableName);
      }

      // 4. Clear stats cache
      _statsCache.remove(tableName);

      // 5. Reset table cache and mark as full table cache
      // Get table's primary key field name
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
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

  /// Get current record cache size in bytes
  int getCurrentRecordCacheSize() {
    return _totalRecordCacheSize;
  }

  /// Get current query cache size in bytes
  int getCurrentQueryCacheSize() {
    return _queryCache.totalCacheSize;
  }

  /// Get current schema cache size in bytes
  int getCurrentSchemaCacheSize() {
    return _totalSchemaCacheSize;
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

  /// Determines whether a given query result should be cached based on a unified set of rules.
  Future<bool> shouldCacheQuery({
    required List<Map<String, dynamic>> results,
  }) async {
    // Check result size to avoid caching excessively large results
    final queryCacheSizeLimit =
        _dataStore.memoryManager?.getQueryCacheSize() ?? 10000;
    final currentCacheSize = _queryCache.totalCacheSize;
    final estimatedResultSize = TableCache.estimateRecordsSize(results);

    // Rule 1: The new item should fit without causing immediate eviction
    if ((currentCacheSize + estimatedResultSize) > queryCacheSizeLimit) {
      return false;
    }

    // Rule 2: A single query result should not occupy more than 25% of the total query cache.
    final singleQuerySizeThreshold = (queryCacheSizeLimit * 0.25).toInt();
    if (estimatedResultSize >= singleQuerySizeThreshold) {
      return false;
    }

    return true;
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
