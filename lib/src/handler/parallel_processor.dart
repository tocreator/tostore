import 'dart:async';
import 'dart:math';

import 'logger.dart';

/// A controller to manage and stop parallel tasks.
///
/// Use this to prematurely stop all tasks submitted to [ParallelProcessor].
class ParallelController {
  bool _isStopped = false;

  /// Returns `true` if [stop] has been called.
  bool get isStopped => _isStopped;

  /// Stops all ongoing and pending tasks associated with this controller.
  ///
  /// Already completed tasks will still have their results. Pending tasks will
  /// not be started. The `execute` method will return promptly.
  void stop() {
    _isStopped = true;
  }
}

/// A utility for running non-CPU-intensive tasks in parallel with fine-grained control.
///
/// This processor is designed for I/O-bound operations (like file reads/writes)
/// where using `Isolate`s would be unnecessary overhead. It provides controlled
/// concurrency to maximize throughput without blocking the UI, and ensures that
/// results are returned in the original order.
class ParallelProcessor {
  static int _concurrency = 4;
  static Duration? _timeout;
  static bool _continueOnError = true;

  /// A special constant to be used in the `timeout` parameter of [execute]
  /// to explicitly disable the timeout for a specific call.
  static const Duration noTimeout = Duration(microseconds: -1);

  /// Configures the default settings for the processor.
  ///
  /// This is useful for setting up application-wide defaults at startup.
  static void setConfig({
    int? concurrency,
    Duration? timeout,
    bool? continueOnError,
  }) {
    if (concurrency != null) _concurrency = concurrency;
    _timeout = timeout; // Allow setting timeout back to null
    if (continueOnError != null) _continueOnError = continueOnError;
  }

  /// Executes a list of asynchronous tasks in parallel.
  ///
  /// - [tasks]: A list of functions, where each function returns a `Future`.
  /// - [controller]: An optional controller to stop the execution prematurely.
  /// - [concurrency], [timeout], [continueOnError]: Optional parameters to
  ///   override the global default settings for this execution only.
  /// - [timeout]: An optional [Duration] after which an individual task will time out.
  /// - [continueOnError]: If `true` (the default), execution continues even if some tasks
  ///   fail. If `false`, the first error will cause the entire execution to fail.
  ///
  /// Returns a `Future` that completes with a list of results in the original order.
  static Future<List<T?>> execute<T>(
    List<Future<T> Function()> tasks, {
    String? label,
    ParallelController? controller,
    int? concurrency,
    Duration? timeout,
    bool? continueOnError,
  }) async {
    final effectiveLabel = label != null ? ".$label" : "";
    final effectiveConcurrency = max(1, concurrency ?? _concurrency);
    final effectiveContinueOnError = continueOnError ?? _continueOnError;

    // New timeout logic to handle explicit disabling
    final Duration? effectiveTimeout;
    if (timeout == noTimeout) {
      effectiveTimeout = null; // Explicitly disable timeout for this call
    } else {
      effectiveTimeout = timeout ?? _timeout; // Use override or global default
    }

    if (tasks.isEmpty) {
      return [];
    }

    final effectiveController = controller ?? ParallelController();
    if (effectiveController.isStopped) {
      return List<T?>.filled(tasks.length, null);
    }

    final completers = List.generate(tasks.length, (_) => Completer<T?>());
    final taskIndices = StreamController<int>();
    int tasksStarted = 0;
    int tasksCompleted = 0;
    int running = 0;

    void scheduleNext() {
      if (effectiveController.isStopped) {
        if (!taskIndices.isClosed) {
          taskIndices.close();
        }
        // Ensure any remaining completers are resolved.
        for (var i = 0; i < completers.length; i++) {
          if (!completers[i].isCompleted) {
            completers[i].complete(null);
          }
        }
        return;
      }

      if (tasksStarted < tasks.length && running < effectiveConcurrency) {
        taskIndices.add(tasksStarted);
        tasksStarted++;
      }
    }

    taskIndices.stream.listen((index) async {
      running++;

      try {
        if (effectiveController.isStopped) {
          throw 'stopped';
        }

        var future = tasks[index]();
        if (effectiveTimeout != null) {
          future = future.timeout(effectiveTimeout, onTimeout: () {
            throw TimeoutException(
                'Task timed out after $effectiveTimeout', effectiveTimeout);
          });
        }

        final result = await future;

        // A task that completes successfully should always return its result.
        // The `stop()` call is a signal for the processor to prevent starting
        // new tasks, but it shouldn't invalidate the work of the task that
        // has already successfully completed (especially the one that triggered the stop).
        if (!completers[index].isCompleted) {
          completers[index].complete(result);
        }
      } catch (e, s) {
        if (e != 'stopped') {
          Logger.error(
            '$effectiveLabel Parallel task at index $index failed: $e\n$s',
            label: "ParallelProcessor$effectiveLabel",
          );
        }

        if (!effectiveContinueOnError) {
          effectiveController.stop();
          if (!completers[index].isCompleted) {
            completers[index].completeError(e, s);
          }
          // The Future.wait below will now fail, and others will be cleaned up.
        } else {
          if (!completers[index].isCompleted) {
            completers[index].complete(null);
          }
        }
      } finally {
        running--;
        tasksCompleted++;

        // All tasks are either done or cancelled, clean up.
        if (tasksCompleted == tasks.length) {
          if (!taskIndices.isClosed) {
            taskIndices.close();
          }
        } else {
          // Schedule the next task.
          scheduleNext();
        }
      }
    });

    for (int i = 0; i < effectiveConcurrency && i < tasks.length; i++) {
      scheduleNext();
    }

    try {
      return await Future.wait(completers.map((c) => c.future));
    } catch (e) {
      // This path is taken only when continueOnError is false.
      // At this point, controller is cancelled and other tasks are completing with null.
      // We rethrow the original error.
      rethrow;
    }
  }
}
