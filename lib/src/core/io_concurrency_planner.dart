import 'dart:math';

/// A small helper to plan hierarchical I/O parallelism under a fixed token budget.
///
/// Design goals:
/// - Never exceed the total token budget.
/// - Prefer partition-level parallelism (especially for non-unique indexes) to avoid
///   long tail latency when a batch touches many partitions.
/// - Keep planning pure and cheap (no IO, no schema access).
final class IoConcurrencyPlanner {
  static int _clampInt(int v, int minV, int maxV) {
    if (v < minV) return minV;
    if (v > maxV) return maxV;
    return v;
  }

  /// Plan table-level parallelism for a flush batch.
  ///
  /// [minTokensPerTable] is a safety lower bound to keep some budget for inner
  /// layers (e.g. table data + indexes running together).
  ///
  /// Returns a concurrency in [1, tableCount].
  static int planTableConcurrency({
    required int capacityTokens,
    required int tableCount,
    int minTokensPerTable = 2,
  }) {
    if (tableCount <= 0) return 1;
    final cap = max(1, capacityTokens);
    final minPerTable = _clampInt(minTokensPerTable, 1, cap);

    // Upper bound to keep at least [minTokensPerTable] per active table.
    final maxByMinShare = max(1, cap ~/ minPerTable);

    // Balanced nested-parallelism heuristic.
    final maxBySqrt = max(1, sqrt(cap).floor());

    final planned = min(tableCount, min(maxByMinShare, maxBySqrt));
    return _clampInt(planned, 1, tableCount);
  }

  /// Split a per-table token budget between table-data and index writes.
  ///
  /// Weighting:
  /// - Table-data weight is 1
  /// - Index weight is [indexCount] (each record impacts indexes roughly O(indexCount))
  ///
  /// If [perTableTokens] < 2 and indexes exist, planner will mark [runInParallel]=false
  /// and still return both sides as 1 so caller can run them sequentially without
  /// losing the "budget intent".
  static ({int tableDataTokens, int indexTokens, bool runInParallel})
      splitPerTableBudget({
    required int perTableTokens,
    required int indexCount,
  }) {
    final b = max(1, perTableTokens);
    if (indexCount <= 0) {
      return (tableDataTokens: b, indexTokens: 0, runInParallel: true);
    }

    // With only 1 token, table data and index writes cannot truly run in parallel.
    // We expose the intent (1,1) but require caller to serialize.
    if (b == 1) {
      return (tableDataTokens: 1, indexTokens: 1, runInParallel: false);
    }

    final dataW = 1;
    final indexW = max(1, indexCount);
    final totalW = dataW + indexW;

    int data = (b * dataW / totalW).floor();
    if (data < 1) data = 1;
    if (data >= b) data = b - 1;
    final idx = max(1, b - data);
    return (tableDataTokens: data, indexTokens: idx, runInParallel: true);
  }

  /// Plan index-level (multiple indexes) and partition-level (multiple partitions) parallelism.
  ///
  /// Returns:
  /// - [indexConcurrency]: number of indexes to run in parallel
  /// - [partitionTokensPerIndex]: per-index token request cap used by partition writers
  ///
  /// Guarantees:
  /// - indexConcurrency >= 1
  /// - partitionTokensPerIndex >= 1
  /// - indexConcurrency * partitionTokensPerIndex <= budgetTokens
  static IndexWriteBudget planIndexWriteBudget({
    required int budgetTokens,
    required int indexCount,
    int minPartitionTokensPerIndex = 1,
  }) {
    final b = max(1, budgetTokens);
    final n = max(1, indexCount);
    final minPerIndex = _clampInt(minPartitionTokensPerIndex, 1, b);

    // Ensure each concurrently-running index can have >= minPerIndex tokens.
    final maxIdxByMin = max(1, b ~/ minPerIndex);

    // Balanced heuristic: start from sqrt(b) but don't exceed constraints.
    final bySqrt = max(1, sqrt(b).floor());
    final idxConc = _clampInt(min(n, min(bySqrt, maxIdxByMin)), 1, n);

    final perIndex = max(minPerIndex, b ~/ idxConc);
    return IndexWriteBudget(
      indexConcurrency: idxConc,
      partitionTokensPerIndex: perIndex,
    );
  }
}

final class IndexWriteBudget {
  final int indexConcurrency;
  final int partitionTokensPerIndex;
  const IndexWriteBudget({
    required this.indexConcurrency,
    required this.partitionTokensPerIndex,
  });
}
