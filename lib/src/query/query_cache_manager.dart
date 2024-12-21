import '../core/data_store_impl.dart';
import '../handler/logger.dart';
import '../model/table_schema.dart';
import '../statistic/table_statistics.dart';
import 'query_cache.dart';
import 'query_condition.dart';

/// unified query cache manager
class QueryCacheManager {
  final QueryCache _cache;
  // 记录表与查询的依赖关系,Map<表名, Map<查询ID, 查询信息>>
  final Map<String, Map<String, _QueryInfo>> _tableDependencies = {};
  final DataStoreImpl _dataStore;

  // add full table cache
  final Map<String, TableCache> tableCaches = {};

  // add schema cache
  final Map<String, TableSchema> _schemaCache = {};

  // add stats cache
  final Map<String, TableStatistics> _statsCache = {};

  QueryCacheManager(this._dataStore)
      : _cache = QueryCache(
          maxSize: _dataStore.config.maxQueryCacheSize,
        );

  /// cache query results
  void cacheQuery(
    QueryCacheKey key,
    List<Map<String, dynamic>> results,
    Set<String> tables,
  ) async {
    try {
      final cacheKey = key.toString();
      final schema = await _dataStore.getTableSchema(tables.first);
      _cache.put(
        cacheKey,
        results,
        tables.first,
        schema.primaryKey,
      );

      // 记录查询与表的依赖关系
      for (var table in tables) {
        final schema = await _dataStore.getTableSchema(table);
        final primaryKey = schema.primaryKey;

        // 判断是否是全表查询
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
      Logger.error('缓存查询结果失败: $e', label: 'QueryCacheManager.cacheQuery');
    }
  }

  /// get cached query results
  List<Map<String, dynamic>>? getQuery(QueryCacheKey key) {
    final results = _cache.get(key.toString());
    return results;
  }

  /// check if record matches query conditions
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
      Logger.error('检查记录匹配失败: $e',
          label: 'QueryCacheManager._recordMatchesConditions');
      return true;
    }
  }

  /// get record full data
  Future<Map<String, dynamic>?> _getRecordByPrimaryKey(
    String tableName,
    String primaryKeyField,
    dynamic primaryKeyValue,
  ) async {
    try {
      final results = await _dataStore.queryByMap(
        tableName,
        where: {primaryKeyField: primaryKeyValue},
        limit: 1,
      );
      return results.isEmpty ? null : results.first;
    } catch (e) {
      Logger.error('get record by primary key failed: $e',
          label: 'QueryCacheManager._getRecordByPrimaryKey');
      return null;
    }
  }

  /// invalidate record related cache
  Future<void> invalidateRecord(
      String tableName, dynamic primaryKeyValue) async {
    try {
      final tableQueries = _tableDependencies[tableName];
      if (tableQueries == null) return;

      // query cache
      for (var entry in tableQueries.entries) {
        final queryInfo = entry.value;

        // if it is full table cache or matches query conditions, invalidate cache
        if (queryInfo.isFullTableCache ||
            await _recordMatchesConditions(
              tableName,
              primaryKeyValue,
              queryInfo.queryKey.condition,
              queryInfo.primaryKeyField,
            )) {
          _cache.invalidate(entry.key);
          tableQueries.remove(entry.key);
        }
      }

      // if table has no related queries, clean dependency
      if (tableQueries.isEmpty) {
        _tableDependencies.remove(tableName);
      }
    } catch (e) {
      Logger.error('invalidate record cache failed: $e',
          label: 'QueryCacheManager.invalidateRecord');
    }
  }

  /// invalidate records related cache
  Future<void> invalidateRecords(
    String tableName,
    Set<dynamic> primaryKeyValues,
  ) async {
    try {
      // if primaryKeyValues is empty, clear all related queries cache
      if (primaryKeyValues.isEmpty) {
        // clear table dependency cache
        _tableDependencies.remove(tableName);

        // clear all related queries cache in general cache
        final keysToRemove = <String>[];
        _cache.cache.forEach((key, queryCache) {
          if (queryCache.tableName == tableName) {
            keysToRemove.add(key);
          }
        });

        for (var key in keysToRemove) {
          _cache.invalidate(key);
        }
        return;
      }

      // 1. handle query cache
      final keysToRemove = <String>[];

      // 1.1 handle table dependency cache
      final tableDeps = _tableDependencies[tableName];
      if (tableDeps != null) {
        for (var entry in tableDeps.entries) {
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

      // 1.2 handle general cache
      _cache.cache.forEach((key, queryCache) {
        if (queryCache.tableName == tableName) {
          if (queryCache.results.any((record) {
            final recordId = record[queryCache.primaryKeyField]?.toString();
            return recordId != null && primaryKeyValues.contains(recordId);
          })) {
            keysToRemove.add(key);
          }
        }
      });

      // 2. remove cache
      for (var key in keysToRemove) {
        _cache.invalidate(key);
        tableDeps?.remove(key);
      }

      // 3. if table has no related queries, clean dependency
      if (tableDeps?.isEmpty ?? false) {
        _tableDependencies.remove(tableName);
      }
    } catch (e) {
      Logger.error(
        'invalidate records cache failed: $e\n'
        'tableName: $tableName\n'
        'primaryKeyValues: $primaryKeyValues',
        label: 'QueryCacheManager.invalidateRecords',
      );
    }
  }

  /// clear all cache
  void clear() {
    _cache.clear();
    _tableDependencies.clear();
    Logger.debug('clear all cache', label: 'QueryCacheManager.clear');
  }

  /// cache all records of a table
  Future<void> cacheEntireTable(String tableName,
      List<Map<String, dynamic>> records, String primaryKeyField,
      {bool isFullTableCache = true}) async {
    // check if file size allows full table cache
    if (!_dataStore.fileManager.allowFullTableCache(
      tableName,
      _dataStore.config.maxTableCacheSize,
    )) {
      isFullTableCache = false;
    }

    // check table cache count limit
    if (tableCaches.length >= _dataStore.config.maxTableCacheCount) {
      // remove oldest table cache
      final oldest = tableCaches.entries.reduce(
          (a, b) => a.value.lastUpdated.isBefore(b.value.lastUpdated) ? a : b);
      tableCaches.remove(oldest.key);
    }

    // get current time as cache time
    final now = DateTime.now();

    tableCaches[tableName] = TableCache(
      records: records,
      primaryKeyField: primaryKeyField,
      lastUpdated: now,
      cacheTime: now,
      isFullTableCache: isFullTableCache,
    );
  }

  /// check if table is fully cached
  bool isTableFullyCached(String tableName) {
    final cache = tableCaches[tableName];
    return cache?.isFullTableCache ?? false;
  }

  /// get all records of a table from cache
  List<Map<String, dynamic>>? getEntireTable(String tableName) {
    final cache = tableCaches[tableName];
    if (cache == null) return null;

    return List<Map<String, dynamic>>.from(cache.records);
  }

  /// update cached record
  void updateCachedRecord(
    String tableName,
    String id,
    Map<String, dynamic> newData,
  ) {
    final cache = tableCaches[tableName];
    if (cache == null) return;

    final index = cache.records
        .indexWhere((r) => r[cache.primaryKeyField].toString() == id);

    if (index >= 0) {
      cache.records[index] = newData;
      cache.lastUpdated = DateTime.now();
    }
  }

  /// add record to cache
  void addCachedRecord(String tableName, Map<String, dynamic> record) {
    final cache = tableCaches[tableName];
    if (cache == null) return;

    cache.records.add(record);
    cache.lastUpdated = DateTime.now();
  }

  /// remove record from cache
  void removeCachedRecord(String tableName, String id) {
    final cache = tableCaches[tableName];
    if (cache == null) return;

    cache.records.removeWhere((r) => r[cache.primaryKeyField].toString() == id);
    cache.lastUpdated = DateTime.now();
  }

  /// cache table schema
  void cacheSchema(String tableName, TableSchema schema) {
    _schemaCache[tableName] = schema;
  }

  /// get cached table schema
  TableSchema? getSchema(String tableName) {
    return _schemaCache[tableName];
  }

  ///   cache table statistics
  void cacheStatistics(String tableName, TableStatistics stats) {
    _statsCache[tableName] = stats;
  }

  /// get cached statistics
  TableStatistics? getStatistics(String tableName) {
    return _statsCache[tableName];
  }

  /// get cached statistics
  Map<String, int> getCacheStats() {
    return {
      'tableCaches': tableCaches.length,
      'queryCaches': _cache.size,
      'schemaCache': _schemaCache.length,
      'statsCache': _statsCache.length,
    };
  }

  /// handle base path changed
  void onBasePathChanged() {
    // clear all non-global table caches
    tableCaches.removeWhere((tableName, _) => !tableName.startsWith('global_'));
    _tableDependencies
        .removeWhere((tableName, _) => !tableName.startsWith('global_'));
    _schemaCache
        .removeWhere((tableName, _) => !tableName.startsWith('global_'));
    _statsCache.removeWhere((tableName, _) => !tableName.startsWith('global_'));

    // clear query cache
    _cache.clear();
  }

  /// get record by primary key
  Map<String, dynamic>? getRecordByPrimaryKey(
      String tableName, dynamic primaryKeyValue) {
    final cache = tableCaches[tableName];
    if (cache == null) return null;

    return cache.records.firstWhere(
      (record) =>
          record[cache.primaryKeyField].toString() ==
          primaryKeyValue.toString(),
      orElse: () => <String, dynamic>{},
    );
  }

  /// query records by field value
  List<Map<String, dynamic>> queryRecordsByField(
    String tableName,
    String fieldName,
    dynamic fieldValue,
  ) {
    final cache = tableCaches[tableName];
    if (cache == null) return [];

    return cache.records
        .where((record) => record[fieldName] == fieldValue)
        .toList();
  }

  /// invalidate all cache of a table
  Future<void> invalidateCache(String tableName) async {
    try {
      // 1. clear table dependency cache
      _tableDependencies.remove(tableName);

      // 2. clear all related queries cache in general cache
      final keysToRemove = <String>[];
      _cache.cache.forEach((key, queryCache) {
        if (queryCache.tableName == tableName) {
          keysToRemove.add(key);
        }
      });

      for (var key in keysToRemove) {
        _cache.invalidate(key);
      }

      // 3. clear schema cache
      _schemaCache.remove(tableName);

      // 4. clear stats cache
      _statsCache.remove(tableName);

      // 5. reset table cache (keep structure but clear data)
      final cache = tableCaches[tableName];
      if (cache != null) {
        cache.records.clear();
        cache.lastUpdated = DateTime.now();
      }
    } catch (e) {
      Logger.error(
        'clear table cache failed: $e\n'
        'tableName: $tableName',
        label: 'QueryCacheManager.invalidateCache',
      );
    }
  }

  /// get table cache time
  DateTime? getTableCacheTime(String tableName) {
    return tableCaches[tableName]?.cacheTime;
  }

  /// get table cache count
  int getTableCacheCount(String tableName) {
    return tableCaches[tableName]?.records.length ?? 0;
  }

  /// get query cache count
  int getCacheCountAll() {
    return _cache.size;
  }

  /// get table cache count
  int getTableCacheCountAll() {
    return tableCaches.values
        .fold(0, (sum, cache) => sum + (cache.records.length));
  }
}

/// query info, contains query conditions, primary key field name and result set
class _QueryInfo {
  final QueryCacheKey queryKey; // query conditions
  final String primaryKeyField; // primary key field name
  final List<Map<String, dynamic>> results; // query result set
  final bool isFullTableCache; // whether it is full table cache

  _QueryInfo({
    required this.queryKey,
    required this.primaryKeyField,
    required this.results,
    this.isFullTableCache = false,
  });
}

/// table cache
class TableCache {
  final List<Map<String, dynamic>> records;
  final String primaryKeyField;
  DateTime lastUpdated;
  final DateTime cacheTime;
  final bool isFullTableCache;

  TableCache({
    required this.records,
    required this.primaryKeyField,
    required this.lastUpdated,
    DateTime? cacheTime,
    this.isFullTableCache = true,
  }) : cacheTime = cacheTime ?? DateTime.now();
}
