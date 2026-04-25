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

  /// Clamp the maximum number of splittable tasks to the available worker count.
  ///
  /// Callers should first estimate a reasonable split count for the workload,
  /// then use this method to cap that count by the current isolate pool size.
  /// The goal is to keep each batch large enough to justify isolate overhead,
  /// but this method does not impose any execution time target.
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
  static Future<List<R>> computeBatch<Q, R>(
    List<ComputeTask<Q, R>> tasks, {
    bool enableIsolate = true,
    bool fallbackToMainThread = true,
  }) async {
    if (tasks.isEmpty) return <R>[];

    final futures = tasks.map(
      (task) => run<Q, R>(
        task,
        useIsolate: enableIsolate,
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
