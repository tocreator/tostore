import 'cost_estimator.dart';

/// query plan
class QueryPlan {
  final List<QueryOperation> operations;

  QueryPlan(this.operations);

  @override
  String toString() {
    return 'QueryPlan(operations: ${operations.map((op) => op.toString()).join(', ')})';
  }

  /// estimate execution cost
  double estimateCost(CostEstimator estimator) {
    return estimator.estimateCost(this);
  }

  /// add operation
  void addOperation(QueryOperation operation) {
    operations.add(operation);
  }

  /// get estimated number of rows
  int estimatedRows(CostEstimator estimator) {
    return estimator.estimateCardinality(
      operations.first.value as String,
      _extractWhereConditions(),
    );
  }

  /// extract query conditions
  Map<String, dynamic>? _extractWhereConditions() {
    for (var operation in operations) {
      if (operation.type == QueryOperationType.filter) {
        return operation.value as Map<String, dynamic>;
      }
    }
    return null;
  }

  /// get query plan description
  String explain() {
    final buffer = StringBuffer();
    for (var i = 0; i < operations.length; i++) {
      buffer.writeln('${i + 1}. ${_explainOperation(operations[i])}');
    }
    return buffer.toString();
  }

  /// explain query operation
  String _explainOperation(QueryOperation operation) {
    switch (operation.type) {
      case QueryOperationType.tableScan:
        return 'TABLE SCAN on ${operation.value}';
      case QueryOperationType.indexScan:
        return 'INDEX SCAN using ${operation.indexName} with conditions: ${operation.value}';
      case QueryOperationType.filter:
        return 'FILTER by ${operation.value}';
      case QueryOperationType.sort:
        return 'SORT by ${operation.value}';
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
  tableScan,
  indexScan,
  filter,
  sort,
}
