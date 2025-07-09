import '../handler/logger.dart';
import '../core/data_store_impl.dart';
import '../model/table_schema.dart';
import '../model/join_clause.dart';
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
    List<String>? orderBy, {
    List<JoinClause>? joins,
  }) async {
    try {
      // First check if there is a full table cache and no join queries
      if (joins == null || joins.isEmpty) {
        // Only consider cache query under the following conditions:
        // 1. Table is fully cached
        // 2. Table file has not been modified (cache is valid)
        if (await _dataStore.dataCacheManager.isTableFullyCached(tableName)) {
          final cacheTime =
              _dataStore.dataCacheManager.getTableCacheTime(tableName);
          final isModified = cacheTime != null &&
              _dataStore.tableDataManager.isFileModified(tableName, cacheTime);

          if (cacheTime != null && !isModified) {
            // Create cache query plan, may need to add filter and sort operations later
            final operations = <QueryOperation>[];

            // Add cache query operation
            operations.add(QueryOperation(
              type: QueryOperationType.cacheQuery,
              value: tableName,
            ));

            // If there are query conditions, add filter operation
            if (where != null && where.isNotEmpty) {
              operations.add(QueryOperation(
                type: QueryOperationType.filter,
                value: where,
              ));
            }

            // If sorting is needed, add sort operation
            if (orderBy != null && orderBy.isNotEmpty) {
              operations.add(QueryOperation(
                type: QueryOperationType.sort,
                value: orderBy,
              ));
            }

            return QueryPlan(operations);
          }
        }
      }

      // If there are join queries, use specific join query plan
      if (joins != null && joins.isNotEmpty) {
        return _createJoinQueryPlan(tableName, where, orderBy, joins);
      }

      // if there is no query condition, directly return full table scan plan
      if (where == null || where.isEmpty) {
        return _createTableScanPlan(tableName, where, orderBy);
      }

      // get table schema
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
        return _createTableScanPlan(tableName, where, orderBy);
      }

      // For primary key queries, decide between a direct primary key scan (for ordered tables)
      // or an index scan on the primary key index (for non-ordered tables).
      if (where.containsKey(schema.primaryKey)) {
        final fileMeta =
            await _dataStore.tableDataManager.getTableFileMeta(tableName);

        // If the table data is physically ordered by the primary key, a primaryKeyScan is most efficient
        // as it can directly seek to the right data partition(s).
        if (fileMeta?.isOrdered == true) {
          return QueryPlan([
            QueryOperation(
              type: QueryOperationType.primaryKeyScan,
              // Pass the specific primary key condition to the executor.
              value: {schema.primaryKey: where[schema.primaryKey]},
            ),
          ]);
        } else {
          // If the table data is not ordered, we must use the primary key's B+Tree index,
          // which is always ordered, to find the record pointers efficiently.
          return QueryPlan([
            QueryOperation(
              type: QueryOperationType.indexScan,
              indexName: 'pk_$tableName',
              value: where,
            ),
          ]);
        }
      }

      // try to use other indexes
      IndexSchema? bestIndex;
      int longestMatch = 0;

      for (var index in schema.indexes) {
        int currentMatch = 0;
        for (var field in index.fields) {
          if (where.containsKey(field)) {
            currentMatch++;
          } else {
            break; // Break as soon as a field in the index is not in the where clause
          }
        }

        if (currentMatch > longestMatch) {
          longestMatch = currentMatch;
          bestIndex = index;
        }
      }

      // If a suitable index is found, use index scan
      if (bestIndex != null) {
        return QueryPlan([
          QueryOperation(
            type: QueryOperationType.indexScan,
            indexName: bestIndex.actualIndexName,
            value: where,
          ),
        ]);
      }

      // if there is no available index, use full table scan
      return _createTableScanPlan(tableName, where, orderBy);
    } catch (e) {
      Logger.error('query optimization failed: $e', label: 'QueryOptimizer');
      // use full table scan when error occurs
      return _createTableScanPlan(tableName, where, orderBy);
    }
  }

  /// create query plan for joins
  QueryPlan _createJoinQueryPlan(
    String tableName,
    Map<String, dynamic>? where,
    List<String>? orderBy,
    List<JoinClause> joins,
  ) {
    final operations = <QueryOperation>[];

    // Add main table scan operation
    operations.add(QueryOperation(
      type: QueryOperationType.tableScan,
      value: tableName,
    ));

    // Add each JOIN operation
    for (var join in joins) {
      operations.add(QueryOperation(
        type: QueryOperationType.join,
        value: {
          'type': join.type.toString().split('.').last,
          'table': join.table,
          'firstKey': join.firstKey,
          'operator': join.operator,
          'secondKey': join.secondKey,
        },
      ));
    }

    // Add filter operation
    if (where != null && where.isNotEmpty) {
      operations.add(QueryOperation(
        type: QueryOperationType.filter,
        value: where,
      ));
    }

    // Add sort operation
    if (orderBy != null && orderBy.isNotEmpty) {
      operations.add(QueryOperation(
        type: QueryOperationType.sort,
        value: orderBy,
      ));
    }

    return QueryPlan(operations);
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
