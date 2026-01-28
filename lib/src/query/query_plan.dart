import 'cost_estimator.dart';

/// query plan
class QueryPlan {
  final QueryOperation operation;

  /// The natural scan order produced by this plan (unprefixed field names).
  ///
  /// This is used by the executor when the caller does not specify an explicit
  /// `orderBy`, so that index scans default to index-key order (enabling index-key
  /// cursors) instead of blindly defaulting to primary-key order.
  final List<String> naturalOrderBy;

  QueryPlan(
    this.operation, {
    List<String>? naturalOrderBy,
  }) : naturalOrderBy = naturalOrderBy ?? const <String>[];

  @override
  String toString() {
    return 'QueryPlan(operation: ${operation.toString()}, naturalOrderBy: $naturalOrderBy)';
  }

  /// estimate execution cost
  double estimateCost(CostEstimator estimator) {
    return estimator.estimateCost(this);
  }

  /// get estimated number of rows
  int estimatedRows(CostEstimator estimator) {
    final v = operation.value;
    if (v is Map<String, dynamic>) {
      final tableName = (v['table'] as String?) ?? '';
      final where = v['where'] as Map<String, dynamic>?;
      return estimator.estimateCardinality(tableName, where);
    }
    return estimator.estimateCardinality('', null);
  }

  /// get query plan description
  String explain() {
    return _explainOperation(operation);
  }

  /// explain query operation
  String _explainOperation(QueryOperation operation) {
    switch (operation.type) {
      case QueryOperationType.tableScan:
        final v = operation.value;
        final table = (v is Map<String, dynamic>) ? (v['table'] ?? '') : '';
        final where = (v is Map<String, dynamic>) ? v['where'] : null;
        return where == null
            ? 'TABLE SCAN on $table'
            : 'TABLE SCAN on $table where: $where';
      case QueryOperationType.indexScan:
        final v = operation.value;
        final where = (v is Map<String, dynamic>) ? v['where'] : null;
        return 'INDEX SCAN using ${operation.indexName} with conditions: $where';
      case QueryOperationType.union:
        final v = operation.value;
        final table = (v is Map<String, dynamic>) ? (v['table'] ?? '') : '';
        final children =
            (v is Map<String, dynamic>) ? (v['children'] as List?) : null;
        if (children == null || children.isEmpty) {
          return 'UNION on $table (empty)';
        }
        final buff = StringBuffer();
        buff.writeln('UNION on $table (');
        for (final c in children) {
          if (c is QueryPlan) {
            buff.writeln('  - ${c.explain()}');
          } else {
            buff.writeln('  - $c');
          }
        }
        buff.write(')');
        return buff.toString();
    }
  }
}

/// query operation
class QueryOperation {
  final QueryOperationType type;
  final String? indexName;
  final dynamic value;

  QueryOperation({
    required this.type,
    this.indexName,
    this.value,
  });

  @override
  String toString() {
    final parts = [type.toString().split('.').last];
    if (indexName != null) {
      parts.add('index: $indexName');
    }
    if (value != null) {
      parts.add('value: $value');
    }
    return 'Operation(${parts.join(', ')})';
  }
}

/// query operation type
enum QueryOperationType {
  tableScan, // scan all records in the table
  indexScan, // use index to locate partition file
  union, // union results from multiple sub-plans (OR / DNF)
}
