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

/// query executor
class QueryExecutor {
  final DataStoreImpl _dataStore;
  final IndexManager _indexManager;
  final QueryCacheManager queryCacheManager;

  QueryExecutor(
    this._dataStore,
    this._indexManager,
  ) : queryCacheManager = QueryCacheManager(_dataStore);

  /// execute query
  Future<List<Map<String, dynamic>>> execute(
    QueryPlan plan,
    String tableName, {
    QueryCondition? condition,
    List<String>? orderBy,
    int? limit,
    int? offset,
  }) async {
    try {
      // 1. try to use cache
      final cache = queryCacheManager.getEntireTable(tableName);
      if (cache != null) {
        // check cache type and query condition
        final isFullCache = queryCacheManager.isTableFullyCached(tableName);
        final isSpecificQuery =
            condition != null && await _isSpecificQuery(tableName, condition);

        // decide whether to use cache
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

      // 2. check query cache
      final queryResult = queryCacheManager.getQuery(cacheKey);
      if (queryResult != null) {
        // get table schema to get primary key field
        final schema = await _dataStore.getTableSchema(tableName);
        final primaryKey = schema.primaryKey;

        // convert cache result to Map to update
        final resultMap = <String, Map<String, dynamic>>{};
        for (var record in queryResult) {
          resultMap[record[primaryKey].toString()] =
              Map<String, dynamic>.from(record);
        }

        // check data in write queue
        final pendingData = _dataStore.fileManager.writeQueue[tableName] ?? [];
        final conditions = condition?.build();

        for (var record in pendingData) {
          final recordId = record[primaryKey].toString();
          if (conditions == null || _matchConditions(record, conditions)) {
            // update or add record
            resultMap[recordId] = Map<String, dynamic>.from(record);
          }
        }

        // convert back to list
        final updatedResults = resultMap.values.toList();
        // apply sort and pagination
        if (orderBy != null) {
          _applySort(updatedResults, orderBy);
        }
        final finalResults = _paginateResults(updatedResults, limit, offset);

        return finalResults;
      }

      // 3. execute actual query
      final results = await _executeQueryPlan(plan, tableName);
      // 4. apply query condition
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

      // 5. paginate and cache results
      final paginatedResults =
          _paginateResults(processedResults, limit, offset);
      if (paginatedResults.isNotEmpty) {
        queryCacheManager.cacheQuery(cacheKey, paginatedResults, {tableName});
      }

      return paginatedResults;
    } catch (e, stackTrace) {
      Logger.error('query execution failed: $e',
          label: 'QueryExecutor.execute');
      Logger.debug('stack trace: $stackTrace');
      rethrow;
    }
  }

  /// execute query plan
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

  /// perform table scan
  Future<List<Map<String, dynamic>>> _performTableScan(String tableName) async {
    final tablePath = await _dataStore.getTablePath(tableName);
    final dataFile = File('$tablePath.dat');

    // get table schema to get primary key field
    final schema = await _dataStore.getTableSchema(tableName);
    final primaryKey = schema.primaryKey;

    // 1. check if there is full table cache
    if (queryCacheManager.isTableFullyCached(tableName)) {
      // check if file is modified
      final cache = queryCacheManager.getEntireTable(tableName);
      if (cache != null) {
        final cacheTime = queryCacheManager.getTableCacheTime(tableName);
        if (cacheTime != null &&
            !_dataStore.fileManager.isFileModified(tableName, cacheTime)) {
          return cache;
        }
      }
    }

    // 2. read file content
    final resultMap = <String, Map<String, dynamic>>{};
    if (await dataFile.exists()) {
      // get file size
      final fileSize = await dataFile.length();
      await _dataStore.fileManager.updateFileSize(tableName, fileSize);

      // if file size is within limit, read and cache
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
            Logger.error('parse record failed: $e',
                label: 'QueryExecutor._performTableScan');
            continue;
          }
        }

        // cache entire table
        await queryCacheManager.cacheEntireTable(
          tableName,
          resultMap.values.toList(),
          primaryKey,
        );
      } else {
        Logger.debug('table too large, skip cache: $tableName',
            label: 'QueryExecutor._performTableScan');
      }
    }

    // 3. merge data in write queue
    final pendingData = _dataStore.fileManager.writeQueue[tableName] ?? [];
    for (var record in pendingData) {
      resultMap[record[primaryKey].toString()] =
          Map<String, dynamic>.from(record);
    }

    return resultMap.values.toList();
  }

  /// perform index scan
  Future<List<Map<String, dynamic>>> _performIndexScan(
    String tableName,
    String indexName,
    Map<String, dynamic> conditions,
  ) async {
    try {
      var schema = await _dataStore.getTableSchema(tableName);
      final index = _indexManager.getIndex(indexName);
      if (index == null) return _performTableScan(tableName);

      // 1. get search value
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

      // 2. use index to search
      final indexResults = await index.search(searchValue);
      if (indexResults.isEmpty) return _performTableScan(tableName);

      // 3. get full record
      final results = <Map<String, dynamic>>[];

      if (indexName.startsWith('pk_')) {
        // primary key index directly return row pointer
        for (var pointer in indexResults) {
          if (pointer is RowPointer) {
            final record = await _getRecordByPointer(tableName, pointer);
            if (record != null) {
              results.add(record);
            }
          }
        }
      } else {
        // secondary index return primary key value, need to search primary key index first
        final pkIndex = _indexManager.getIndex('pk_$tableName');
        if (pkIndex == null) return _performTableScan(tableName);
        for (var primaryKeyValue in indexResults) {
          // get row pointer by primary key index
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
      Logger.error('index scan failed: $e',
          label: 'QueryExecutor-_performIndexScan');
      return _performTableScan(tableName);
    }
  }

  /// match record whether satisfies conditions
  bool _matchConditions(
      Map<String, dynamic> record, Map<String, dynamic> conditions) {
    // handle OR condition
    if (conditions.containsKey('OR')) {
      final orConditions = conditions['OR'] as List;
      // first handle non-OR conditions
      final baseConditions = Map<String, dynamic>.from(conditions)
        ..remove('OR');
      if (baseConditions.isNotEmpty &&
          !_matchBasicConditions(record, baseConditions)) {
        return false;
      }
      // then handle OR conditions
      return orConditions.any((condition) =>
          _matchConditions(record, condition as Map<String, dynamic>));
    }

    // handle AND conditions
    if (conditions.containsKey('AND')) {
      final andConditions = conditions['AND'] as List;
      return andConditions.every((condition) =>
          _matchConditions(record, condition as Map<String, dynamic>));
    }

    return _matchBasicConditions(record, conditions);
  }

  /// match basic conditions (not AND/OR)
  bool _matchBasicConditions(
      Map<String, dynamic> record, Map<String, dynamic> conditions) {
    for (var entry in conditions.entries) {
      final field = entry.key;
      final value = entry.value;

      if (value is Map) {
        // handle operator conditions
        for (var op in value.entries) {
          if (!_matchOperator(record[field], op.key, op.value)) {
            return false;
          }
        }
      } else {
        // simple equal condition
        if (record[field] != value) {
          return false;
        }
      }
    }
    return true;
  }

  /// match single operator condition
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

  /// safe value comparison
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

  /// apply sort
  void _applySort(List<Map<String, dynamic>> data, List<String> orderBy) {
    try {
      data.sort((a, b) {
        for (var field in orderBy) {
          final desc = field.startsWith('-');
          final fieldName = desc ? field.substring(1) : field;

          // get field value
          final valueA = a[fieldName];
          final valueB = b[fieldName];

          // handle null value
          if (valueA == null && valueB == null) continue;
          if (valueA == null) return desc ? -1 : 1;
          if (valueB == null) return desc ? 1 : -1;

          // compare value
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
      Logger.error('sort failed: $e', label: "QueryExecutor-_applySort");
      throw StateError('Error applying sort: ${e.toString()}');
    }
  }

  /// paginate results
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

  /// invalidate single record related cache
  Future<void> invalidateRecord(
      String tableName, dynamic primaryKeyValue) async {
    queryCacheManager.removeCachedRecord(tableName, primaryKeyValue.toString());
  }

  /// invalidate multiple records related cache
  Future<void> invalidateRecords(
      String tableName, Set<dynamic> primaryKeyValues) async {
    await queryCacheManager.invalidateRecords(tableName, primaryKeyValues);
  }

  /// invalidate all cache of a table
  Future<void> invalidateCache(String tableName) async {
    await queryCacheManager.invalidateRecords(tableName, {});
  }

  /// get record by row pointer
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

    // 2. read from file
    final file = File('${_dataStore.getTablePath(tableName)}.dat');
    if (!await file.exists()) return null;
    try {
      final raf = await file.open(mode: FileMode.read);
      try {
        await raf.setPosition(pointer.offset);
        final bytes = await raf.read(pointer.length);

        final line = utf8.decode(bytes);
        final record = jsonDecode(line.trim()) as Map<String, dynamic>;
        // verify record integrity
        if (pointer.verifyContent(line.trim())) {
          return record;
        }
        return null;
      } finally {
        await raf.close();
      }
    } catch (e) {
      Logger.error('read record failed: $e',
          label: 'QueryExecutor._getRecordByPointer');
      return null;
    }
  }

  /// check if it is a specific query (like query by primary key or index field)
  Future<bool> _isSpecificQuery(
    String tableName,
    QueryCondition condition,
  ) async {
    try {
      // get table schema
      final schema = await _dataStore.getTableSchema(tableName);
      final conditions = condition.build();

      // 1. check if it is primary key query
      if (conditions.containsKey(schema.primaryKey)) {
        final pkCondition = conditions[schema.primaryKey];
        // primary key exact match or IN query are considered specific queries
        if (pkCondition is Map) {
          final operator = pkCondition.keys.first;
          return operator == '=' || operator == 'IN';
        }
        // direct value comparison
        return true;
      }

      // 2. check if index field exact query is used
      for (var index in schema.indexes) {
        // only consider single field index exact query
        if (index.fields.length == 1) {
          final fieldName = index.fields.first;
          if (conditions.containsKey(fieldName)) {
            final fieldCondition = conditions[fieldName];
            if (fieldCondition is Map) {
              final operator = fieldCondition.keys.first;
              // index field exact match or IN query
              return operator == '=' || operator == 'IN';
            }
            // direct value comparison
            return true;
          }
        }
      }

      // 3. check if it is unique field exact query
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

      // other cases are not considered specific queries
      return false;
    } catch (e) {
      Logger.error('check specific query failed: $e',
          label: 'QueryExecutor._isSpecificQuery');
      return false;
    }
  }
}

/// query range
class QueryRange {
  final dynamic start;
  final dynamic end;

  QueryRange(this.start, this.end);
}
