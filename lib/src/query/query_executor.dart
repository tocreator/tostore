import 'dart:convert';
import 'dart:io';

import '../handler/logger.dart';
import '../core/data_store_impl.dart';
import '../core/index_manager.dart';
import '../model/row_pointer.dart';
import 'query_cache.dart';
import 'query_cache_manager.dart';
import 'query_condition.dart';
import 'query_plan.dart';

/// 查询执行器
class QueryExecutor {
  final DataStoreImpl _dataStore;
  final IndexManager _indexManager;
  final QueryCacheManager queryCacheManager;

  QueryExecutor(
    this._dataStore,
    this._indexManager,
  ) : queryCacheManager = QueryCacheManager(_dataStore);

  /// 执行查询
  Future<List<Map<String, dynamic>>> execute(
    QueryPlan plan,
    String tableName, {
    QueryCondition? condition,
    List<String>? orderBy,
    int? limit,
    int? offset,
  }) async {
    try {
      // 1. 尝试使用缓存
      final cache = queryCacheManager.getEntireTable(tableName);
      if (cache != null) {
        // 检查缓存类型和查询条件
        final isFullCache = queryCacheManager.isTableFullyCached(tableName);
        final isSpecificQuery =
            condition != null && await _isSpecificQuery(tableName, condition);

        // 决定是否使用缓存
        if (isFullCache || isSpecificQuery) {
          var results = cache;
          if (condition != null) {
            final conditions = condition.build();
            results = results
                .where((record) => _matchConditions(record, conditions))
                .toList();
          }

          if (orderBy != null) {
            _applySort(results, orderBy);
          }
          return _paginateResults(results, limit, offset);
        }
      }

      final cacheKey = QueryCacheKey(
        tableName: tableName,
        condition: condition ?? QueryCondition(),
        orderBy: orderBy,
        limit: limit,
        offset: offset,
      );

      // 2. 检查查询缓存
      final queryResult = queryCacheManager.getQuery(cacheKey);
      if (queryResult != null) {
        // 获取表结构以获取主键字段
        final schema = await _dataStore.getTableSchema(tableName);
        final primaryKey = schema.primaryKey;

        // 将缓存结果转换为 Map 以便更新
        final resultMap = <String, Map<String, dynamic>>{};
        for (var record in queryResult) {
          resultMap[record[primaryKey].toString()] =
              Map<String, dynamic>.from(record);
        }

        // 检查待写入队列中的数据
        final pendingData = _dataStore.fileManager.writeQueue[tableName] ?? [];
        final conditions = condition?.build();

        for (var record in pendingData) {
          final recordId = record[primaryKey].toString();
          if (conditions == null || _matchConditions(record, conditions)) {
            // 更新或添加记录
            resultMap[recordId] = Map<String, dynamic>.from(record);
          }
        }

        // 转换回列表
        final updatedResults = resultMap.values.toList();
        // 应用排序和分页
        if (orderBy != null) {
          _applySort(updatedResults, orderBy);
        }
        final finalResults = _paginateResults(updatedResults, limit, offset);

        return finalResults;
      }

      // 3. 执行实际查询
      final results = await _executeQueryPlan(plan, tableName);
      // 4. 应用查询条件
      var processedResults = results;
      if (condition != null) {
        final conditions = condition.build();
        processedResults = processedResults
            .where((record) => _matchConditions(record, conditions))
            .toList();
      }
      if (orderBy != null) {
        _applySort(processedResults, orderBy);
      }

      // 5. 分页并缓存结果
      final paginatedResults =
          _paginateResults(processedResults, limit, offset);
      if (paginatedResults.isNotEmpty) {
        queryCacheManager.cacheQuery(cacheKey, paginatedResults, {tableName});
      }

      return paginatedResults;
    } catch (e, stackTrace) {
      Logger.error('查询执行失败: $e', label: 'QueryExecutor.execute');
      Logger.debug('堆栈跟踪: $stackTrace');
      rethrow;
    }
  }

  /// 执行查询计划
  Future<List<Map<String, dynamic>>> _executeQueryPlan(
    QueryPlan plan,
    String tableName,
  ) async {
    List<Map<String, dynamic>> results = [];
    for (var operation in plan.operations) {
      switch (operation.type) {
        case QueryOperationType.tableScan:
          results = await _performTableScan(tableName);
          break;
        case QueryOperationType.indexScan:
          results = await _performIndexScan(
            tableName,
            operation.indexName!,
            operation.value as Map<String, dynamic>,
          );
          break;
        case QueryOperationType.filter:
          final conditions = operation.value as Map<String, dynamic>;
          results = results
              .where((record) => _matchConditions(record, conditions))
              .toList();
          break;
        case QueryOperationType.sort:
          _applySort(results, operation.value as List<String>);
          break;
      }
    }

    return results;
  }

  /// 执行表扫描
  Future<List<Map<String, dynamic>>> _performTableScan(String tableName) async {
    final tablePath = await _dataStore.getTablePath(tableName);
    final dataFile = File('$tablePath.dat');

    // 获取表结构以获取主键字段
    final schema = await _dataStore.getTableSchema(tableName);
    final primaryKey = schema.primaryKey;

    // 1. 检查是否有全表缓存
    if (queryCacheManager.isTableFullyCached(tableName)) {
      // 检查文件是否被修改过
      final cache = queryCacheManager.getEntireTable(tableName);
      if (cache != null) {
        final cacheTime = queryCacheManager.getTableCacheTime(tableName);
        if (cacheTime != null &&
            !_dataStore.fileManager.isFileModified(tableName, cacheTime)) {
          return cache;
        }
      }
    }

    // 2. 读取文件内容
    final resultMap = <String, Map<String, dynamic>>{};
    if (await dataFile.exists()) {
      // 获取文件大小
      final fileSize = await dataFile.length();
      await _dataStore.fileManager.updateFileSize(tableName, fileSize);

      // 如果文件大小在限制范围内，读取并缓存
      if (_dataStore.fileManager.allowFullTableCache(
        tableName,
        _dataStore.config.maxTableCacheSize,
      )) {
        final lines = await dataFile.readAsLines();
        for (var line in lines) {
          try {
            if (line.trim().isEmpty) continue;
            final data = jsonDecode(line) as Map<String, dynamic>;
            resultMap[data[primaryKey].toString()] = data;
          } catch (e) {
            Logger.error('解析记录失败: $e',
                label: 'QueryExecutor._performTableScan');
            continue;
          }
        }

        // 缓存整个表
        await queryCacheManager.cacheEntireTable(
          tableName,
          resultMap.values.toList(),
          primaryKey,
        );
      } else {
        Logger.debug('表太大，跳过缓存: $tableName',
            label: 'QueryExecutor._performTableScan');
      }
    }

    // 3. 合并待写入队列中的数据
    final pendingData = _dataStore.fileManager.writeQueue[tableName] ?? [];
    for (var record in pendingData) {
      resultMap[record[primaryKey].toString()] =
          Map<String, dynamic>.from(record);
    }

    return resultMap.values.toList();
  }

  /// 执行索引扫描
  Future<List<Map<String, dynamic>>> _performIndexScan(
    String tableName,
    String indexName,
    Map<String, dynamic> conditions,
  ) async {
    try {
      var schema = await _dataStore.getTableSchema(tableName);
      final index = _indexManager.getIndex(indexName);
      if (index == null) return _performTableScan(tableName);

      // 1. 获取查询值
      dynamic searchValue;
      if (indexName.startsWith('pk_')) {
        searchValue = conditions[schema.primaryKey];
      } else {
        final indexSchema = schema.indexes.firstWhere(
          (idx) => idx.actualIndexName == indexName,
        );
        searchValue = conditions[indexSchema.fields.first];
      }
      if (searchValue == null) return _performTableScan(tableName);

      // 2. 使用索引查询
      final indexResults = await index.search(searchValue);
      if (indexResults.isEmpty) return _performTableScan(tableName);

      // 3. 获取完整记录
      final results = <Map<String, dynamic>>[];

      if (indexName.startsWith('pk_')) {
        // 主键索引直接返回行指针
        for (var pointer in indexResults) {
          if (pointer is RowPointer) {
            final record = await _getRecordByPointer(tableName, pointer);
            if (record != null) {
              results.add(record);
            }
          }
        }
      } else {
        // 二级索引返回主键值，需要先查主键索引
        final pkIndex = _indexManager.getIndex('pk_$tableName');
        if (pkIndex == null) return _performTableScan(tableName);
        for (var primaryKeyValue in indexResults) {
          // 通过主键索引获取行指针
          final pointers = await pkIndex.search(primaryKeyValue);
          if (pointers.isNotEmpty && pointers.first is RowPointer) {
            final record = await _getRecordByPointer(
              tableName,
              pointers.first as RowPointer,
            );
            if (record != null) {
              results.add(record);
            }
          }
        }
      }

      return results;
    } catch (e) {
      Logger.error('索引扫描失败: $e', label: 'QueryExecutor-_performIndexScan');
      return _performTableScan(tableName);
    }
  }

  /// 匹配记录是否满足条件
  bool _matchConditions(
      Map<String, dynamic> record, Map<String, dynamic> conditions) {
    // 处理 OR 条件
    if (conditions.containsKey('OR')) {
      final orConditions = conditions['OR'] as List;
      // 先处理非 OR 条件
      final baseConditions = Map<String, dynamic>.from(conditions)
        ..remove('OR');
      if (baseConditions.isNotEmpty &&
          !_matchBasicConditions(record, baseConditions)) {
        return false;
      }
      // 再处理 OR 条件
      return orConditions.any((condition) =>
          _matchConditions(record, condition as Map<String, dynamic>));
    }

    // 处理 AND 条件
    if (conditions.containsKey('AND')) {
      final andConditions = conditions['AND'] as List;
      return andConditions.every((condition) =>
          _matchConditions(record, condition as Map<String, dynamic>));
    }

    return _matchBasicConditions(record, conditions);
  }

  /// 匹配基本条件（非 AND/OR）
  bool _matchBasicConditions(
      Map<String, dynamic> record, Map<String, dynamic> conditions) {
    for (var entry in conditions.entries) {
      final field = entry.key;
      final value = entry.value;

      if (value is Map) {
        // 处理操作符条件
        for (var op in value.entries) {
          if (!_matchOperator(record[field], op.key, op.value)) {
            return false;
          }
        }
      } else {
        // 简单相等条件
        if (record[field] != value) {
          return false;
        }
      }
    }
    return true;
  }

  /// 匹配单个操作符条件
  bool _matchOperator(
      dynamic fieldValue, String operator, dynamic compareValue) {
    switch (operator.toUpperCase()) {
      case '=':
        return fieldValue == compareValue;
      case '!=':
      case '<>':
        return fieldValue != compareValue;
      case '>':
        return fieldValue != null &&
            _compareValues(fieldValue, compareValue) > 0;
      case '>=':
        return fieldValue != null &&
            _compareValues(fieldValue, compareValue) >= 0;
      case '<':
        return fieldValue != null &&
            _compareValues(fieldValue, compareValue) < 0;
      case '<=':
        return fieldValue != null &&
            _compareValues(fieldValue, compareValue) <= 0;
      case 'IN':
        if (compareValue is! List) return false;
        return fieldValue != null && compareValue.contains(fieldValue);
      case 'NOT IN':
        if (compareValue is! List) return false;
        return fieldValue != null && !compareValue.contains(fieldValue);
      case 'BETWEEN':
        if (compareValue is! Map ||
            !compareValue.containsKey('start') ||
            !compareValue.containsKey('end')) {
          return false;
        }
        return fieldValue != null &&
            _compareValues(fieldValue, compareValue['start']) >= 0 &&
            _compareValues(fieldValue, compareValue['end']) <= 0;
      case 'LIKE':
        if (fieldValue == null || compareValue is! String) return false;
        final pattern = compareValue
            .replaceAll('%', '.*')
            .replaceAll('_', '.')
            .replaceAll('\\', '\\\\');
        return RegExp('^$pattern\$', caseSensitive: false)
            .hasMatch(fieldValue.toString());
      case 'IS':
        return fieldValue == null;
      case 'IS NOT':
        return fieldValue != null;
      default:
        Logger.warn('未知的操作符: $operator', label: 'QueryExecutor._matchOperator');
        return false;
    }
  }

  /// 安全的值比较
  int _compareValues(dynamic a, dynamic b) {
    if (a == null || b == null) return 0;

    if (a is num && b is num) {
      return a.compareTo(b);
    }
    if (a is String && b is String) {
      return a.compareTo(b);
    }
    if (a is DateTime && b is DateTime) {
      return a.compareTo(b);
    }
    if (a is bool && b is bool) {
      return a == b ? 0 : (a ? 1 : -1);
    }

    return a.toString().compareTo(b.toString());
  }

  /// 应用排序
  void _applySort(List<Map<String, dynamic>> data, List<String> orderBy) {
    try {
      data.sort((a, b) {
        for (var field in orderBy) {
          final desc = field.startsWith('-');
          final fieldName = desc ? field.substring(1) : field;

          // 获取字段值
          final valueA = a[fieldName];
          final valueB = b[fieldName];

          // 处理空值
          if (valueA == null && valueB == null) continue;
          if (valueA == null) return desc ? -1 : 1;
          if (valueB == null) return desc ? 1 : -1;

          // 比较值
          int compareResult;
          if (valueA is num && valueB is num) {
            compareResult = valueA.compareTo(valueB);
          } else {
            compareResult = valueA.toString().compareTo(valueB.toString());
          }

          if (compareResult != 0) {
            return desc ? -compareResult : compareResult;
          }
        }
        return 0;
      });
    } catch (e) {
      Logger.error('排序失败: $e', label: "QueryExecutor-_applySort");
      throw StateError('Error applying sort: ${e.toString()}');
    }
  }

  /// 分页结果
  List<Map<String, dynamic>> _paginateResults(
    List<Map<String, dynamic>> results,
    int? limit,
    int? offset,
  ) {
    if (offset != null) {
      results = results.skip(offset).toList();
    }
    if (limit != null) {
      results = results.take(limit).toList();
    }
    return results;
  }

  /// 使单条记录的相关缓存失效
  Future<void> invalidateRecord(
      String tableName, dynamic primaryKeyValue) async {
    queryCacheManager.removeCachedRecord(tableName, primaryKeyValue.toString());
  }

  /// 使多条记录的相关缓存失效
  Future<void> invalidateRecords(
      String tableName, Set<dynamic> primaryKeyValues) async {
    await queryCacheManager.invalidateRecords(tableName, primaryKeyValues);
  }

  /// 清除表的所有缓存
  Future<void> invalidateCache(String tableName) async {
    await queryCacheManager.invalidateRecords(tableName, {});
  }

  /// 通过行指针获取记录
  Future<Map<String, dynamic>?> _getRecordByPointer(
    String tableName,
    RowPointer pointer,
  ) async {
    // 1. 先检查写入队列
    final pendingData = _dataStore.fileManager.writeQueue[tableName] ?? [];
    for (var record in pendingData) {
      // 检查是否是同一条记录(通过校验和比较)
      final encoded = jsonEncode(record);
      if (pointer.verifyContent(encoded)) {
        return record;
      }
    }

    // 2. 从文件读取
    final file = File('${_dataStore.getTablePath(tableName)}.dat');
    if (!await file.exists()) return null;
    try {
      final raf = await file.open(mode: FileMode.read);
      try {
        await raf.setPosition(pointer.offset);
        final bytes = await raf.read(pointer.length);

        final line = utf8.decode(bytes);
        final record = jsonDecode(line.trim()) as Map<String, dynamic>;
        // 验证记录完整性
        if (pointer.verifyContent(line.trim())) {
          return record;
        }
        return null;
      } finally {
        await raf.close();
      }
    } catch (e) {
      Logger.error('读取记录失败: $e', label: 'QueryExecutor._getRecordByPointer');
      return null;
    }
  }

  /// 判断是否为针对性查询（比如按主键或索引字段查询）
  Future<bool> _isSpecificQuery(
    String tableName,
    QueryCondition condition,
  ) async {
    try {
      // 获取表结构
      final schema = await _dataStore.getTableSchema(tableName);
      final conditions = condition.build();

      // 1. 检查是否是主键查询
      if (conditions.containsKey(schema.primaryKey)) {
        final pkCondition = conditions[schema.primaryKey];
        // 主键的精确匹配或 IN 查询都认为是针对性查询
        if (pkCondition is Map) {
          final operator = pkCondition.keys.first;
          return operator == '=' || operator == 'IN';
        }
        // 直接值比较
        return true;
      }

      // 2. 检查是否使用了索引字段的精确查询
      for (var index in schema.indexes) {
        // 只考虑单字段索引的精确查询
        if (index.fields.length == 1) {
          final fieldName = index.fields.first;
          if (conditions.containsKey(fieldName)) {
            final fieldCondition = conditions[fieldName];
            if (fieldCondition is Map) {
              final operator = fieldCondition.keys.first;
              // 索引字段的精确匹配或 IN 查询
              return operator == '=' || operator == 'IN';
            }
            // 直接值比较
            return true;
          }
        }
      }

      // 3. 检查是否是唯一字段的精确查询
      for (var field in schema.fields) {
        if (field.unique && conditions.containsKey(field.name)) {
          final fieldCondition = conditions[field.name];
          if (fieldCondition is Map) {
            final operator = fieldCondition.keys.first;
            return operator == '=' || operator == 'IN';
          }
          return true;
        }
      }

      // 其他情况都不认为是针对性查询
      return false;
    } catch (e) {
      Logger.error('判断针对性查询失败: $e', label: 'QueryExecutor._isSpecificQuery');
      return false;
    }
  }
}

/// 查询范围
class QueryRange {
  final dynamic start;
  final dynamic end;

  QueryRange(this.start, this.end);
}
