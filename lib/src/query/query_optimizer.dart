import '../handler/logger.dart';
import '../core/data_store_impl.dart';
import 'query_plan.dart';

/// query optimizer
class QueryOptimizer {
  final DataStoreImpl _dataStore;

  QueryOptimizer(
    this._dataStore,
  );

  /// optimize query plan
  Future<QueryPlan> optimize(
    String tableName,
    Map<String, dynamic>? where,
    List<String>? orderBy,
  ) async {
    try {
      // if there is no query condition, directly return full table scan plan
      if (where == null || where.isEmpty) {
        return _createTableScanPlan(tableName, where, orderBy);
      }

      // get table schema
      final schema = await _dataStore.getTableSchema(tableName);

      // first try to use primary key index
      if (where.containsKey(schema.primaryKey)) {
        return QueryPlan([
          QueryOperation(
            type: QueryOperationType.indexScan,
            indexName: 'pk_$tableName',
            value: where,
          ),
        ]);
      }

      // try to use other indexes
      for (var index in schema.indexes) {
        // check if all index fields are in query condition
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

      // if there is no available index, use full table scan
      return _createTableScanPlan(tableName, where, orderBy);
    } catch (e) {
      Logger.error('query optimization failed: $e', label: 'QueryOptimizer');
      // use full table scan when error occurs
      return _createTableScanPlan(tableName, where, orderBy);
    }
  }

  /// create full table scan query plan
  QueryPlan _createTableScanPlan(
    String tableName,
    Map<String, dynamic>? where,
    List<String>? orderBy,
  ) {
    final operations = <QueryOperation>[];

    // add full table scan operation
    operations.add(QueryOperation(
      type: QueryOperationType.tableScan,
      value: tableName,
    ));

    // if there is query condition, add filter operation
    if (where != null && where.isNotEmpty) {
      operations.add(QueryOperation(
        type: QueryOperationType.filter,
        value: where,
      ));
    }

    // if need sort, add sort operation
    if (orderBy != null && orderBy.isNotEmpty) {
      operations.add(QueryOperation(
        type: QueryOperationType.sort,
        value: orderBy,
      ));
    }

    return QueryPlan(operations);
  }
}
