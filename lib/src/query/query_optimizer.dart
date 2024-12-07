import '../handler/logger.dart';
import '../core/data_store_impl.dart';
import 'query_plan.dart';

/// 查询优化器
class QueryOptimizer {
  final DataStoreImpl _dataStore;

  QueryOptimizer(
    this._dataStore,
  );

  /// 优化查询计划
  Future<QueryPlan> optimize(
    String tableName,
    Map<String, dynamic>? where,
    List<String>? orderBy,
  ) async {
    try {
      // 如果没有查询条件，直接返回全表扫描计划
      if (where == null || where.isEmpty) {
        return _createTableScanPlan(tableName, where, orderBy);
      }

      // 获取表结构
      final schema = await _dataStore.getTableSchema(tableName);

      // 首先尝试使用主键索引
      if (where.containsKey(schema.primaryKey)) {
        return QueryPlan([
          QueryOperation(
            type: QueryOperationType.indexScan,
            indexName: 'pk_$tableName',
            value: where,
          ),
        ]);
      }

      // 尝试使用其他索引
      for (var index in schema.indexes) {
        // 检查是否所有索引字段都在查询条件中
        if (index.fields.every((col) => where.containsKey(col))) {
          return QueryPlan([
            QueryOperation(
              type: QueryOperationType.indexScan,
              indexName: index.actualIndexName,
              value: where,
            ),
          ]);
        }
      }

      // 如果没有可用的索引，使用全表扫描
      return _createTableScanPlan(tableName, where, orderBy);
    } catch (e) {
      Logger.error('查询优化失败: $e', label: 'QueryOptimizer');
      // 出错时使用全表扫描
      return _createTableScanPlan(tableName, where, orderBy);
    }
  }

  /// 创建全表扫描查询计划
  QueryPlan _createTableScanPlan(
    String tableName,
    Map<String, dynamic>? where,
    List<String>? orderBy,
  ) {
    final operations = <QueryOperation>[];

    // 添加全表扫描操作
    operations.add(QueryOperation(
      type: QueryOperationType.tableScan,
      value: tableName,
    ));

    // 如果有查询条件，添加过滤操作
    if (where != null && where.isNotEmpty) {
      operations.add(QueryOperation(
        type: QueryOperationType.filter,
        value: where,
      ));
    }

    // 如果需要排序，添加排序操作
    if (orderBy != null && orderBy.isNotEmpty) {
      operations.add(QueryOperation(
        type: QueryOperationType.sort,
        value: orderBy,
      ));
    }

    return QueryPlan(operations);
  }
}
