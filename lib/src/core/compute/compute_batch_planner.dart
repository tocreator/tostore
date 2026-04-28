import 'dart:math';

import '../../handler/platform_handler.dart';
import '../compute_manager.dart';

/// Range descriptor for splitting a batch into balanced sub-tasks.
class ComputeTaskRange {
  final int start;
  final int end;

  const ComputeTaskRange({
    required this.start,
    required this.end,
  });

  int get length => end - start;
}

/// Execution plan for a pure-compute batch.
class ComputeBatchDispatchPlan {
  final int itemCount;
  final int averageItemBytes;
  final bool sampledAverageItemBytes;
  final bool useIsolate;
  final int dispatchTaskCount;
  final int actualTaskCount;

  const ComputeBatchDispatchPlan({
    required this.itemCount,
    required this.averageItemBytes,
    required this.sampledAverageItemBytes,
    required this.useIsolate,
    required this.dispatchTaskCount,
    required this.actualTaskCount,
  });
}

/// Shared planner for large pure-compute batches.
///
/// Goals:
/// - Keep small inputs on the main isolate naturally.
/// - Keep a single prepare batch within a bounded memory envelope.
/// - Split large pure-compute work into balanced tasks sized above isolate overhead.
class ComputeBatchPlanner {
  static const int minBatchBytes = 10 * 1024 * 1024;
  static const int maxBatchBytes = 100 * 1024 * 1024;
  static const double memoryBudgetRatio = 0.10;

  /// Minimum useful task size in items.
  ///
  /// Meaning:
  /// - If a batch reaches this size, it is usually worth offloading to an
  ///   isolate even when the final dispatch count is only 1.
  /// - It is also the default unit used to estimate the maximum splittable
  ///   task count before clamping by worker count.
  static const int minUsefulTaskItems = 500;

  /// Secondary byte-based fast path guard for cases where item count is low
  /// but each item is large.
  static const int minIsolateBytes = 256 * 1024;

  /// Estimate average item bytes by sampling the first and last two items.
  static int estimateAverageItemBytes<T>(
    List<T> items,
    int Function(T item) estimateItemBytes,
  ) {
    if (items.isEmpty) return 0;

    final sampledIndices = <int>{
      0,
      if (items.length > 1) 1,
      if (items.length > 2) items.length - 2,
      if (items.length > 3) items.length - 1,
    };

    int total = 0;
    int count = 0;
    for (final index in sampledIndices) {
      total += max(1, estimateItemBytes(items[index]));
      count++;
    }

    return count == 0 ? 0 : max(1, (total / count).ceil());
  }

  /// Build an execution plan with a very cheap small-data fast path.
  ///
  /// Default behavior:
  /// - If [itemCount] is below [minUsefulTaskItems], return a direct
  ///   main-thread single-task plan immediately.
  /// - Only when the item count is large enough do we sample average item
  ///   bytes and decide isolate usage / task splitting.
  ///
  /// This keeps call sites from paying repeated size-estimation overhead for
  /// obviously tiny workloads that should stay on the main thread.
  static ComputeBatchDispatchPlan planTaskExecution({
    required int itemCount,
    required int Function() estimateAverageItemBytes,
    int minUsefulTaskItems = ComputeBatchPlanner.minUsefulTaskItems,
  }) {
    final safeItemCount = max(0, itemCount);
    final safeMinUsefulTaskItems = max(1, minUsefulTaskItems);

    if (safeItemCount <= 0) {
      return const ComputeBatchDispatchPlan(
        itemCount: 0,
        averageItemBytes: 0,
        sampledAverageItemBytes: false,
        useIsolate: false,
        dispatchTaskCount: 1,
        actualTaskCount: 1,
      );
    }

    if (safeItemCount < safeMinUsefulTaskItems) {
      return ComputeBatchDispatchPlan(
        itemCount: safeItemCount,
        averageItemBytes: 0,
        sampledAverageItemBytes: false,
        useIsolate: false,
        dispatchTaskCount: 1,
        actualTaskCount: 1,
      );
    }

    final averageItemBytes = max(0, estimateAverageItemBytes());
    final useIsolate = shouldUseIsolate(
      itemCount: safeItemCount,
      averageItemBytes: averageItemBytes,
      minUsefulTaskItems: safeMinUsefulTaskItems,
    );
    final dispatchTaskCount = useIsolate
        ? estimateDispatchTaskCount(
            maxSplittableTaskCount: estimateMaxSplittableTaskCount(
              itemCount: safeItemCount,
              minUsefulTaskItems: safeMinUsefulTaskItems,
            ),
          )
        : 1;

    return ComputeBatchDispatchPlan(
      itemCount: safeItemCount,
      averageItemBytes: averageItemBytes,
      sampledAverageItemBytes: true,
      useIsolate: useIsolate,
      dispatchTaskCount: dispatchTaskCount,
      actualTaskCount: useIsolate ? dispatchTaskCount : 1,
    );
  }

  /// Estimate a memory-aware outer batch size for large compute preparation.
  static Future<int> estimateAdaptiveBatchItemCount({
    required int totalItemCount,
    required int averageItemBytes,
    int? maxBatchItemCount,
  }) async {
    final safeTotalItemCount = max(0, totalItemCount);
    if (safeTotalItemCount <= 0) return 0;

    final safeAverageItemBytes = max(0, averageItemBytes);
    final safeMaxBatchItemCount =
        maxBatchItemCount != null && maxBatchItemCount > 0
            ? maxBatchItemCount
            : null;
    if (safeAverageItemBytes <= 0) {
      return _clampBatchItemCount(
        totalItemCount: safeTotalItemCount,
        batchItemCount: 1024,
        maxBatchItemCount: safeMaxBatchItemCount,
      );
    }

    // Small batches that already fit within the minimum memory budget do not
    // need an extra available-memory lookup.
    final effectiveAverageItemBytes = max(
      safeAverageItemBytes * 3,
      safeAverageItemBytes + 256,
    );
    if (safeTotalItemCount * effectiveAverageItemBytes <= minBatchBytes) {
      return _clampBatchItemCount(
        totalItemCount: safeTotalItemCount,
        batchItemCount: safeTotalItemCount,
        maxBatchItemCount: safeMaxBatchItemCount,
      );
    }

    final memoryMB = await PlatformHandler.getAvailableSystemMemoryMB();
    final availableBytes = max(1, memoryMB) * 1024 * 1024;

    int targetBatchBytes = (availableBytes * memoryBudgetRatio).floor();
    targetBatchBytes = targetBatchBytes.clamp(minBatchBytes, maxBatchBytes);

    // Prepare phase temporarily holds both input records and prepared results.
    // Keep a conservative multiplier here so the memory-aware batch size better
    // reflects the actual resident footprint instead of just raw input bytes.
    final batchItemCount =
        max(1, targetBatchBytes ~/ effectiveAverageItemBytes);
    return _clampBatchItemCount(
      totalItemCount: safeTotalItemCount,
      batchItemCount: batchItemCount,
      maxBatchItemCount: safeMaxBatchItemCount,
    );
  }

  /// Estimate the maximum number of tasks the current workload can be split into.
  ///
  /// This returns the *upper bound* before worker-count clamping.
  static int estimateMaxSplittableTaskCount({
    required int itemCount,
    int minUsefulTaskItems = ComputeBatchPlanner.minUsefulTaskItems,
  }) {
    final safeItemCount = max(0, itemCount);
    final safeMinUsefulTaskItems = max(1, minUsefulTaskItems);
    if (safeItemCount <= 0) return 1;
    return max(1, safeItemCount ~/ safeMinUsefulTaskItems);
  }

  /// Whether the workload is large enough to justify isolate offloading.
  static bool shouldUseIsolate({
    required int itemCount,
    required int averageItemBytes,
    int minUsefulTaskItems = ComputeBatchPlanner.minUsefulTaskItems,
    int minIsolateBytes = ComputeBatchPlanner.minIsolateBytes,
  }) {
    final safeItemCount = max(0, itemCount);
    final safeAverageItemBytes = max(0, averageItemBytes);
    final estimatedTotalBytes = safeItemCount * safeAverageItemBytes;
    final safeMinUsefulTaskItems = max(1, minUsefulTaskItems);
    final safeMinIsolateBytes = max(1, minIsolateBytes);

    return safeItemCount >= safeMinUsefulTaskItems ||
        estimatedTotalBytes >= safeMinIsolateBytes;
  }

  /// Clamp the maximum splittable task count to the actual dispatch count.
  static int estimateDispatchTaskCount({
    required int maxSplittableTaskCount,
  }) {
    final safeMaxSplittableTaskCount = max(1, maxSplittableTaskCount);
    return max(
      1,
      ComputeManager.clampTaskCount(safeMaxSplittableTaskCount),
    );
  }

  /// Split [totalCount] into [dispatchTaskCount] balanced contiguous ranges.
  static List<ComputeTaskRange> splitRange(
    int totalCount,
    int dispatchTaskCount,
  ) {
    if (totalCount <= 0) return const <ComputeTaskRange>[];

    final safeTaskCount = max(1, min(dispatchTaskCount, totalCount));
    final baseSize = totalCount ~/ safeTaskCount;
    final remainder = totalCount % safeTaskCount;

    final ranges = <ComputeTaskRange>[];
    int offset = 0;
    for (int i = 0; i < safeTaskCount; i++) {
      final length = baseSize + (i < remainder ? 1 : 0);
      final end = offset + length;
      ranges.add(ComputeTaskRange(start: offset, end: end));
      offset = end;
    }
    return ranges;
  }

  static int _clampBatchItemCount({
    required int totalItemCount,
    required int batchItemCount,
    int? maxBatchItemCount,
  }) {
    var safeBatchItemCount = max(1, batchItemCount);
    if (maxBatchItemCount != null && maxBatchItemCount > 0) {
      safeBatchItemCount = min(safeBatchItemCount, maxBatchItemCount);
    }
    return min(totalItemCount, safeBatchItemCount);
  }
}
