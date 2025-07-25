import 'dart:async';

import '../Interface/compute_provider.dart' as compute_impl;
import '../handler/logger.dart';

/// A compute manager to control whether to use isolate.
///
/// Provides a unified entry point for running computational tasks, with the ability
/// to dynamically enable or disable the use of isolates.
class ComputeManager {
  /// - [Q]: The type of the message to be passed to the function.
  /// - [R]: The type of the result.
  /// - [function]: The function to execute. It must be a top-level function or a static method
  ///   to be executed in an isolate.
  /// - [message]: The argument to pass to the function.
  /// - [useIsolate]: Whether to use an isolate or run in the current isolate. Defaults to true.
  /// - [fallbackToMainThread]: Whether to fallback to main thread if isolate execution fails. Defaults to true.
  static Future<R> run<Q, R>(
    FutureOr<R> Function(Q) function,
    Q message, {
    bool useIsolate = true,
    bool fallbackToMainThread = true,
  }) async {
    if (!useIsolate) {
      //  run directly in main thread
      return function(message);
    }

    try {
      // try to run in isolate
      return await compute_impl.compute(function, message);
    } catch (isolateError, stack) {
      if (fallbackToMainThread) {
        // record error and fallback to main thread
        Logger.error(
            'Isolate execution failed, fallback to main thread: $isolateError\n$stack',
            label: 'ComputeManager.run');
        return function(message);
      } else {
        // rethrow exception
        rethrow;
      }
    }
  }

  /// Pre-warms the compute workers (isolates) to reduce the latency of the first `run` call.
  /// This is useful to call during application startup.
  static Future<void> prewarm() async {
    // On native platforms, this will initialize the isolate pool.
    // On web, this is a no-op.
    try {
      await compute_impl.prewarm();
    } catch (e) {
      Logger.warn('Compute worker pre-warming not available on this platform.',
          label: 'ComputeManager.prewarm');
    }
  }
}
