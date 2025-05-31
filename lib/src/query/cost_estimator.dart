import '../statistic/table_statistics.dart';
import 'query_plan.dart';

/// query cost estimator
class CostEstimator {
  final TableStatistics _statistics;

  // cost weight
  static const double _indexSeekCost = 1.0;
  static const double _indexScanCost = 2.0;
  static const double _tableScanCost = 10.0;
  static const double _sortCost = 5.0;
  static const double _filterCost = 3.0;
  static const double _joinCost = 15.0; // JOIN cost weight
  static const double _cacheScanCost = 0.5; // cache query cost weight, lowest

  CostEstimator(this._statistics);

  /// estimate query plan cost
  double estimateCost(QueryPlan plan) {
    double totalCost = 0.0;
    int estimatedRows = _statistics.totalRows;

    for (var operation in plan.operations) {
      switch (operation.type) {
        case QueryOperationType.indexScan:
          final indexCost = _estimateIndexScanCost(
            operation.value as Map<String, dynamic>,
            estimatedRows,
          );
          totalCost += indexCost.cost;
          estimatedRows = indexCost.rows;
          break;

        case QueryOperationType.tableScan:
          totalCost += _tableScanCost * estimatedRows;
          break;

        case QueryOperationType.cacheQuery:
          totalCost += _cacheScanCost * estimatedRows;
          break;

        case QueryOperationType.filter:
          final filterCost = _estimateFilterCost(
            operation.value as Map<String, dynamic>,
            estimatedRows,
          );
          totalCost += filterCost.cost;
          estimatedRows = filterCost.rows;
          break;

        case QueryOperationType.sort:
          totalCost += _estimateSortCost(estimatedRows);
          break;

        case QueryOperationType.join:
          final joinCost = _estimateJoinCost(estimatedRows);
          totalCost += joinCost.cost;
          estimatedRows = joinCost.rows;
          break;
      }
    }

    return totalCost;
  }

  /// estimate join cost - estimate the cost of the join operation
  CostEstimate _estimateJoinCost(int inputRows) {
    // assume the join operation will produce twice the number of input rows (conservative estimate)
    final outputRows = inputRows * 2;
    // the cost of JOIN is proportional to the input rows, and there is an additional merge cost
    final cost = _joinCost * inputRows;

    return CostEstimate(cost, outputRows);
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

  /// estimate filter cost
  CostEstimate _estimateFilterCost(
    Map<String, dynamic> conditions,
    int inputRows,
  ) {
    var cost = 0.0;
    var outputRows = inputRows;

    for (var entry in conditions.entries) {
      final fieldStats = _statistics.fieldStats[entry.key];
      if (fieldStats == null) continue;

      cost += _filterCost * inputRows;

      if (entry.value is Map) {
        // complex condition
        outputRows =
            (outputRows * 0.5).ceil(); // estimate filter out 50% of rows
      } else {
        // simple equal condition
        outputRows = (outputRows / fieldStats.distinctValues).ceil();
      }
    }

    return CostEstimate(cost, outputRows);
  }

  /// estimate sort cost
  double _estimateSortCost(int rows) {
    if (rows <= 1) return 0;
    // use O(n log n) complexity to estimate sort cost
    return _sortCost * rows * _log2(rows);
  }

  /// calculate logarithm base 2
  double _log2(int n) {
    // use change of base formula: log2(n) = ln(n) / ln(2)
    return _ln(n) / 0.693147180559945; // ln(2) ≈ 0.693147180559945
  }

  /// calculate natural logarithm
  double _ln(int n) {
    // use taylor series to calculate natural logarithm
    double x = (n - 1) / (n + 1);
    double result = 0;
    double term = x;
    int k = 1;

    while (term.abs() > 1e-10 && k < 100) {
      result += term / k;
      term *= x * x * (2 * k - 1) / (2 * k + 1);
      k++;
    }

    return 2 * result;
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
