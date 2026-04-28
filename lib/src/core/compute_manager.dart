import 'dart:async';

import '../Interface/compute_provider.dart' as compute_impl;
import '../handler/logger.dart';
import '../handler/platform_handler.dart';

/// A single batch task that keeps the input message and the executor together.
class ComputeTask<Q, R> {
  final FutureOr<R> Function(Q) function;
  final Q message;

  const ComputeTask({required this.function, required this.message});
}

/// A compute manager to control whether to use isolate.
///
/// Provides a unified entry point for running computational tasks, with the ability
/// to dynamically enable or disable the use of isolates.
class ComputeManager {
  /// Execute a single task.
  ///
  /// - [Q]: The type of the message to be passed to the function.
  /// - [R]: The type of the result.
  /// - [task]: The task model that bundles function and message together.
  /// - [useIsolate]: Whether to use an isolate or run in the current isolate. Defaults to true.
  /// - [fallbackToMainThread]: Whether to fallback to main thread if isolate execution fails. Defaults to true.
  static Future<R> run<Q, R>(
    ComputeTask<Q, R> task, {
    bool useIsolate = true,
    bool fallbackToMainThread = true,
  }) async {
    if (!useIsolate) {
      //  run directly in main thread
      return task.function(task.message);
    }

    try {
      // try to run in isolate
      return await compute_impl.compute(task.function, task.message);
    } catch (isolateError, stack) {
      if (fallbackToMainThread) {
        Logger.error(
          'Isolate execution failed, fallback to main thread: $isolateError\n$stack',
          label: 'ComputeManager.run',
        );
        return task.function(task.message);
      }
      rethrow;
    }
  }

  /// Clamp the caller-estimated maximum splittable task count by the
  /// available worker count.
  ///
  /// IMPORTANT:
  /// - [maxTaskCount] must be the maximum splittable task count.
  /// - It must NOT be the size of one large task.
  /// - A practical rule is to estimate [maxTaskCount] so that each split task
  ///   is expected to cost at least about 30ms of compute time, which is
  ///   usually enough to amortize isolate overhead.
  ///
  /// Example:
  /// - If 20_000 records can be split into 40 useful tasks (~500 records per
  ///   task), pass `40`, not `1`.
  /// - Then [clampTaskCount] will cap `40` by the worker count and return the
  ///   actual dispatch task count.
  static int clampTaskCount(int maxTaskCount) {
    if (maxTaskCount <= 0) return 1;
    final concurrency = PlatformHandler.recommendedConcurrency;
    if (concurrency <= 0) return maxTaskCount;
    return maxTaskCount > concurrency ? concurrency : maxTaskCount;
  }

  /// Execute a list of pre-split batch tasks.
  ///
  /// Callers should split the workload into appropriately sized tasks first,
  /// then optionally use [clampTaskCount] to cap the final task count before
  /// invoking this method. This method focuses on dispatching the prepared
  /// tasks:
  /// - when [enableIsolate] is true, tasks are scheduled concurrently through
  ///   the compute backend
  /// - when [enableIsolate] is false, tasks are executed sequentially on the
  ///   current isolate to avoid overlapping compute work on the UI thread
  static Future<List<R>> computeBatch<Q, R>(
    List<ComputeTask<Q, R>> tasks, {
    bool enableIsolate = true,
    bool fallbackToMainThread = true,
  }) async {
    if (tasks.isEmpty) return <R>[];

    if (!enableIsolate) {
      final results = <R>[];
      for (final task in tasks) {
        results.add(
          await run<Q, R>(
            task,
            useIsolate: false,
            fallbackToMainThread: fallbackToMainThread,
          ),
        );
      }
      return results;
    }

    final futures = tasks.map(
      (task) => run<Q, R>(
        task,
        useIsolate: true,
        fallbackToMainThread: fallbackToMainThread,
      ),
    );
    return Future.wait(futures);
  }

  /// Pre-warms the compute workers (isolates) to reduce the latency of the first `run` call.
  /// This is useful to call during application startup.
  static Future<void> prewarm() async {
    // On native platforms, this will initialize the isolate pool.
    // On web, this is a no-op.
    try {
      await compute_impl.prewarm();
    } catch (e) {
      Logger.warn(
        'Compute worker pre-warming not available on this platform.',
        label: 'ComputeManager.prewarm',
      );
    }
  }
}
