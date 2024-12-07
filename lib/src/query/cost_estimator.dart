import '../statistics/table_statistics.dart';
import 'query_plan.dart';

/// 查询代价估算器
class CostEstimator {
  final TableStatistics _statistics;

  // 代价权重
  static const double _indexSeekCost = 1.0;
  static const double _indexScanCost = 2.0;
  static const double _tableScanCost = 10.0;
  static const double _sortCost = 5.0;
  static const double _filterCost = 3.0;

  CostEstimator(this._statistics);

  /// 估算查询计划代价
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
      }
    }

    return totalCost;
  }

  /// 估算索引扫描代价
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
        // 范围查询
        cost += _indexScanCost * (outputRows / fieldStats.distinctValues);
        outputRows = (outputRows * 0.3).ceil(); // 估计范围查询返回30%的行
      } else {
        // 精确查询
        cost += _indexSeekCost;
        outputRows = (outputRows / fieldStats.distinctValues).ceil();
      }
    }

    return CostEstimate(cost, outputRows);
  }

  /// 估算过滤代价
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
        // 复杂条件
        outputRows = (outputRows * 0.5).ceil(); // 估过滤掉50%的行
      } else {
        // 简单相等条件
        outputRows = (outputRows / fieldStats.distinctValues).ceil();
      }
    }

    return CostEstimate(cost, outputRows);
  }

  /// 估算排序代价
  double _estimateSortCost(int rows) {
    if (rows <= 1) return 0;
    // 使用 O(n log n) 复杂度估算排序代价
    return _sortCost * rows * _log2(rows);
  }

  /// 计算以2为底的对数
  double _log2(int n) {
    // 使用换底公式: log2(n) = ln(n) / ln(2)
    return _ln(n) / 0.693147180559945; // ln(2) ≈ 0.693147180559945
  }

  /// 计算自然对数
  double _ln(int n) {
    // 使用泰勒级数计算自然对数
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

  /// 估算基数（返回行数）
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
        // 范围条件
        cardinality = (cardinality * 0.3).ceil();
      } else {
        // 相等条件
        cardinality = (cardinality / fieldStats.distinctValues).ceil();
      }
    }

    return cardinality;
  }
}

/// 代价估算结果
class CostEstimate {
  final double cost;
  final int rows;

  CostEstimate(this.cost, this.rows);
}
