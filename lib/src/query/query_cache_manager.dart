import '../core/data_store_impl.dart';
import '../handler/logger.dart';
import '../model/table_schema.dart';
import '../statistics/table_statistics.dart';
import 'query_cache.dart';
import 'query_condition.dart';

/// 统一的查询缓存管理器
class QueryCacheManager {
  final QueryCache _cache;
  // 记录表与查询的依赖关系,Map<表名, Map<查询ID, 查询信息>>
  final Map<String, Map<String, _QueryInfo>> _tableDependencies = {};
  final DataStoreImpl _dataStore;

  // 添加全表缓存
  final Map<String, TableCache> tableCaches = {};

  // 添加 Schema 缓存
  final Map<String, TableSchema> _schemaCache = {};

  // 添加统计信息缓存
  final Map<String, TableStatistics> _statsCache = {};

  QueryCacheManager(this._dataStore)
      : _cache = QueryCache(
          maxSize: _dataStore.config.maxQueryCacheSize,
        );

  /// 缓存查询结果
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

  /// 获取缓存的查询结果
  List<Map<String, dynamic>>? getQuery(QueryCacheKey key) {
    final results = _cache.get(key.toString());
    return results;
  }

  /// 检查记录是否匹配查询条件
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

  /// 获取记录完整数据
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
      Logger.error('获取记录失败: $e',
          label: 'QueryCacheManager._getRecordByPrimaryKey');
      return null;
    }
  }

  /// 使单条记录相关的缓存失效
  Future<void> invalidateRecord(
      String tableName, dynamic primaryKeyValue) async {
    try {
      final tableQueries = _tableDependencies[tableName];
      if (tableQueries == null) return;

      // 找出需要更新的查询
      for (var entry in tableQueries.entries) {
        final queryInfo = entry.value;

        // 如果是全表缓存或者匹配查询条件，则使缓存失效
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

      // 如果表没有相关查询了，清理依赖关系
      if (tableQueries.isEmpty) {
        _tableDependencies.remove(tableName);
      }
    } catch (e) {
      Logger.error('使记录缓存失效失败: $e',
          label: 'QueryCacheManager.invalidateRecord');
    }
  }

  /// 使多条记录相关的缓存失效
  Future<void> invalidateRecords(
    String tableName,
    Set<dynamic> primaryKeyValues,
  ) async {
    try {
      // 如果 primaryKeyValues 为空，清除该表所有相关的查询缓存
      if (primaryKeyValues.isEmpty) {
        // 清除表依赖关系中的缓存
        _tableDependencies.remove(tableName);

        // 清除通用缓存中该表的所有查询
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

      // 1. 处理查询缓存
      final keysToRemove = <String>[];

      // 1.1 处理表依赖关系中的缓存
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

      // 1.2 处理通用缓存
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

      // 2. 移除缓存
      for (var key in keysToRemove) {
        _cache.invalidate(key);
        tableDeps?.remove(key);
      }

      // 3. 如果表没有相关查询了，清理依赖关系
      if (tableDeps?.isEmpty ?? false) {
        _tableDependencies.remove(tableName);
      }
    } catch (e) {
      Logger.error(
        '使多条记录缓存失效失败: $e\n'
        'tableName: $tableName\n'
        'primaryKeyValues: $primaryKeyValues',
        label: 'QueryCacheManager.invalidateRecords',
      );
    }
  }

  /// 清除所有缓存
  void clear() {
    _cache.clear();
    _tableDependencies.clear();
    Logger.debug('清除所有缓存', label: 'QueryCacheManager.clear');
  }

  /// 缓存表的所有记录
  Future<void> cacheEntireTable(String tableName,
      List<Map<String, dynamic>> records, String primaryKeyField,
      {bool isFullTableCache = true}) async {
    // 检查文件大小是否允许全表缓存
    if (!_dataStore.fileManager.allowFullTableCache(
      tableName,
      _dataStore.config.maxTableCacheSize,
    )) {
      isFullTableCache = false;
    }

    // 检查表缓存数量限制
    if (tableCaches.length >= _dataStore.config.maxTableCacheCount) {
      // 移除最旧的表缓存
      final oldest = tableCaches.entries.reduce(
          (a, b) => a.value.lastUpdated.isBefore(b.value.lastUpdated) ? a : b);
      tableCaches.remove(oldest.key);
    }

    // 获取当前时间作为缓存时间
    final now = DateTime.now();

    tableCaches[tableName] = TableCache(
      records: records,
      primaryKeyField: primaryKeyField,
      lastUpdated: now,
      cacheTime: now,
      isFullTableCache: isFullTableCache,
    );
  }

  /// 检查表是否已完全缓存
  bool isTableFullyCached(String tableName) {
    final cache = tableCaches[tableName];
    return cache?.isFullTableCache ?? false;
  }

  /// 从缓存获取表的所有记录
  List<Map<String, dynamic>>? getEntireTable(String tableName) {
    final cache = tableCaches[tableName];
    if (cache == null) return null;

    return List<Map<String, dynamic>>.from(cache.records);
  }

  /// 更新缓存中的记录
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

  /// 添加记录到缓存
  void addCachedRecord(String tableName, Map<String, dynamic> record) {
    final cache = tableCaches[tableName];
    if (cache == null) return;

    cache.records.add(record);
    cache.lastUpdated = DateTime.now();
  }

  /// 从缓存删除记录
  void removeCachedRecord(String tableName, String id) {
    final cache = tableCaches[tableName];
    if (cache == null) return;

    cache.records.removeWhere((r) => r[cache.primaryKeyField].toString() == id);
    cache.lastUpdated = DateTime.now();
  }

  /// 缓存表结构
  void cacheSchema(String tableName, TableSchema schema) {
    _schemaCache[tableName] = schema;
  }

  /// 获取缓存的表结构
  TableSchema? getSchema(String tableName) {
    return _schemaCache[tableName];
  }

  /// 缓存统计信息
  void cacheStatistics(String tableName, TableStatistics stats) {
    _statsCache[tableName] = stats;
  }

  /// 获取缓存的统计信息
  TableStatistics? getStatistics(String tableName) {
    return _statsCache[tableName];
  }

  /// 获取缓存统计信息
  Map<String, int> getCacheStats() {
    return {
      'tableCaches': tableCaches.length,
      'queryCaches': _cache.size,
      'schemaCache': _schemaCache.length,
      'statsCache': _statsCache.length,
    };
  }

  /// 处理基础空间变更
  void onBasePathChanged() {
    // 清除所有非全局表的缓存
    tableCaches.removeWhere((tableName, _) => !tableName.startsWith('global_'));
    _tableDependencies
        .removeWhere((tableName, _) => !tableName.startsWith('global_'));
    _schemaCache
        .removeWhere((tableName, _) => !tableName.startsWith('global_'));
    _statsCache.removeWhere((tableName, _) => !tableName.startsWith('global_'));

    // 清除查询缓存
    _cache.clear();
  }

  /// 根据主键获取记录
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

  /// 根据字段值查询记录
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

  /// 清除表的所有缓存
  Future<void> invalidateCache(String tableName) async {
    try {
      // 1. 清除表依赖关系中的缓存
      _tableDependencies.remove(tableName);

      // 2. 清除通用缓存中该表的所有查询
      final keysToRemove = <String>[];
      _cache.cache.forEach((key, queryCache) {
        if (queryCache.tableName == tableName) {
          keysToRemove.add(key);
        }
      });

      for (var key in keysToRemove) {
        _cache.invalidate(key);
      }

      // 3. 清除 Schema 缓存
      _schemaCache.remove(tableName);

      // 4. 清除统计信息缓存
      _statsCache.remove(tableName);

      // 5. 重置表缓存(保留结构但清空数据)
      final cache = tableCaches[tableName];
      if (cache != null) {
        cache.records.clear();
        cache.lastUpdated = DateTime.now();
      }
    } catch (e) {
      Logger.error(
        '清除表缓存失败: $e\n'
        'tableName: $tableName',
        label: 'QueryCacheManager.invalidateCache',
      );
    }
  }

  // 获取表缓存时间
  DateTime? getTableCacheTime(String tableName) {
    return tableCaches[tableName]?.cacheTime;
  }

  // 获取表缓存数量
  int getTableCacheCount(String tableName) {
    return tableCaches[tableName]?.records.length ?? 0;
  }

  /// 获取查询缓存数量
  int getCacheCountAll() {
    return _cache.size;
  }

  /// 获取表缓存数量
  int getTableCacheCountAll() {
    return tableCaches.values
        .fold(0, (sum, cache) => sum + (cache.records.length));
  }
}

/// 查询信息，包含查询条件、主键字段名和结果集
class _QueryInfo {
  final QueryCacheKey queryKey; // 查询条件
  final String primaryKeyField; // 主键字段名
  final List<Map<String, dynamic>> results; // 查询结果集
  final bool isFullTableCache; // 是否是全表缓存

  _QueryInfo({
    required this.queryKey,
    required this.primaryKeyField,
    required this.results,
    this.isFullTableCache = false,
  });
}

/// 表缓存
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
