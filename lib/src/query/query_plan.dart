import 'cost_estimator.dart';

/// 查询计划
class QueryPlan {
  final List<QueryOperation> operations;

  QueryPlan(this.operations);

  @override
  String toString() {
    return 'QueryPlan(operations: ${operations.map((op) => op.toString()).join(', ')})';
  }

  /// 估算执行成本
  double estimateCost(CostEstimator estimator) {
    return estimator.estimateCost(this);
  }

  /// 添加操作
  void addOperation(QueryOperation operation) {
    operations.add(operation);
  }

  /// 获取预计返回行数
  int estimatedRows(CostEstimator estimator) {
    return estimator.estimateCardinality(
      operations.first.value as String,
      _extractWhereConditions(),
    );
  }

  /// 提取查询条件
  Map<String, dynamic>? _extractWhereConditions() {
    for (var operation in operations) {
      if (operation.type == QueryOperationType.filter) {
        return operation.value as Map<String, dynamic>;
      }
    }
    return null;
  }

  /// 获取查询计划描述
  String explain() {
    final buffer = StringBuffer();
    for (var i = 0; i < operations.length; i++) {
      buffer.writeln('${i + 1}. ${_explainOperation(operations[i])}');
    }
    return buffer.toString();
  }

  /// 解释查询操作
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

/// 查询操作
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

/// 查询操作类型
enum QueryOperationType {
  tableScan,
  indexScan,
  filter,
  sort,
}
