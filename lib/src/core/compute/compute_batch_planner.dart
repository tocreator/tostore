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

  /// Estimate a memory-aware outer batch size for large compute preparation.
  static Future<int> estimateAdaptiveBatchItemCount({
    required int totalItemCount,
    required int averageItemBytes,
    int? maxBatchItemCount,
  }) async {
    if (totalItemCount <= 0) return 0;
    if (averageItemBytes <= 0) return min(totalItemCount, 1024);

    final memoryMB = await PlatformHandler.getAvailableSystemMemoryMB();
    final availableBytes = max(1, memoryMB) * 1024 * 1024;

    int targetBatchBytes = (availableBytes * memoryBudgetRatio).floor();
    targetBatchBytes = targetBatchBytes.clamp(minBatchBytes, maxBatchBytes);

    // Prepare phase temporarily holds both input records and prepared results.
    // Keep a conservative multiplier here so the memory-aware batch size better
    // reflects the actual resident footprint instead of just raw input bytes.
    final effectiveAverageItemBytes =
        max(averageItemBytes * 3, averageItemBytes + 256);
    int batchItemCount = max(1, targetBatchBytes ~/ effectiveAverageItemBytes);
    if (maxBatchItemCount != null && maxBatchItemCount > 0) {
      batchItemCount = min(batchItemCount, maxBatchItemCount);
    }
    return min(totalItemCount, batchItemCount);
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
  }) {
    final safeItemCount = max(0, itemCount);
    final safeAverageItemBytes = max(0, averageItemBytes);
    final estimatedTotalBytes = safeItemCount * safeAverageItemBytes;

    return safeItemCount >= minUsefulTaskItems ||
        estimatedTotalBytes >= minIsolateBytes;
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
}
