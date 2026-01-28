import '../model/table_statistics.dart';
import 'query_plan.dart';

/// query cost estimator
class CostEstimator {
  final TableStatistics _statistics;

  // cost weight
  static const double _indexSeekCost = 1.0;
  static const double _indexScanCost = 2.0;
  static const double _tableScanCost = 10.0;

  CostEstimator(this._statistics);

  /// estimate query plan cost
  double estimateCost(QueryPlan plan) {
    double totalCost = 0.0;
    int estimatedRows = _statistics.totalRows;

    final operation = plan.operation;
    switch (operation.type) {
      case QueryOperationType.indexScan:
        final v = operation.value;
        final where = (v is Map<String, dynamic>)
            ? (v['where'] as Map<String, dynamic>?)
            : null;
        if (where == null) {
          totalCost += _indexScanCost;
          break;
        }
        final indexCost = _estimateIndexScanCost(
          where,
          estimatedRows,
        );
        totalCost += indexCost.cost;
        estimatedRows = indexCost.rows;
        break;

      case QueryOperationType.tableScan:
        totalCost += _tableScanCost * estimatedRows;
        break;

      case QueryOperationType.union:
        final v = operation.value;
        final children =
            (v is Map<String, dynamic>) ? (v['children'] as List?) : null;
        if (children == null || children.isEmpty) {
          totalCost += _tableScanCost * estimatedRows;
          break;
        }
        for (final c in children) {
          if (c is QueryPlan) {
            totalCost += estimateCost(c);
          } else if (c is QueryOperation) {
            totalCost += estimateCost(QueryPlan(c));
          } else {
            totalCost += _tableScanCost * estimatedRows;
          }
        }
        break;
    }

    return totalCost;
  }

  /// estimate index scan cost
  CostEstimate _estimateIndexScanCost(
    Map<String, dynamic> conditions,
    int inputRows,
  ) {
    var cost = 0.0;
    var outputRows = inputRows;

    for (var entry in conditions.entries) {
      final fieldStats = _statistics.fieldStats[entry.key];
      if (fieldStats == null) continue;

      if (entry.value is Map) {
        // range query
        cost += _indexScanCost * (outputRows / fieldStats.distinctValues);
        outputRows = (outputRows * 0.3)
            .ceil(); // estimate range query returns 30% of rows
      } else {
        // exact query
        cost += _indexSeekCost;
        outputRows = (outputRows / fieldStats.distinctValues).ceil();
      }
    }

    return CostEstimate(cost, outputRows);
  }

  /// estimate cardinality (return row count)
  int estimateCardinality(
    String tableName,
    Map<String, dynamic>? where,
  ) {
    if (where == null || where.isEmpty) {
      return _statistics.totalRows;
    }

    var cardinality = _statistics.totalRows;

    for (var entry in where.entries) {
      final fieldStats = _statistics.fieldStats[entry.key];
      if (fieldStats == null) continue;

      if (entry.value is Map) {
        // range condition
        cardinality = (cardinality * 0.3).ceil();
      } else {
        // equal condition
        cardinality = (cardinality / fieldStats.distinctValues).ceil();
      }
    }

    return cardinality;
  }
}

/// cost estimate result
class CostEstimate {
  final double cost;
  final int rows;

  CostEstimate(this.cost, this.rows);
}
