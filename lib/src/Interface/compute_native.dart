import 'dart:async';
import 'dart:isolate';
import 'dart:collection';
import '../handler/platform_handler.dart';

class _IsolateTask<R> {
  final Completer<R> completer = Completer<R>();
  final Function function;
  final dynamic message;
  final Stopwatch? timer; // for performance monitoring

  _IsolateTask(this.function, this.message, {this.timer});
}

/// Isolate pool manager, keeping a fixed number of isolates to reduce the overhead of creation and destruction
class _IsolatePool {
  static final _IsolatePool _instance = _IsolatePool._internal();
  factory _IsolatePool() => _instance;
  _IsolatePool._internal();

  // Use the platform handler to get the optimal pool size based on device capabilities
  final int _maxPoolSize = PlatformHandler.recommendedConcurrency;
  final Map<int, Isolate> _isolates = {};
  final Map<int, SendPort> _sendPorts = {};
  final Queue<_IsolateTask> _globalTaskQueue = Queue<_IsolateTask>();
  final Map<int, _IsolateTask?> _activeTasks = {};
  final Map<int, bool> _isIdle = {};
  int _nextIsolateId = 0;
  final Map<int, int> _taskCount =
      {}; // track the number of tasks processed by each isolate
  final Map<int, double> _avgTaskTime =
      {}; // track the average task execution time for each isolate
  bool _isInitialized = false;
  Completer<void>? _initCompleter;

  /// initialize the isolate pool
  Future<void> _ensureInitialized() async {
    if (_isInitialized) return;
    if (_initCompleter != null) {
      return _initCompleter!.future;
    }

    _initCompleter = Completer<void>();

    try {
      final timer = Stopwatch()..start();

      // Create the first isolate to be ready quickly.
      if (_maxPoolSize > 0) {
        await _createIsolate(0);
      }

      _isInitialized = true;

      // Lazily create the rest of the isolates in the background without waiting.
      _createRemainingIsolatesInBackground();

      timer.stop();
      _initCompleter!.complete();
    } catch (e, st) {
      _initCompleter!.completeError(e, st);
      // On failure, allow re-initialization.
      _initCompleter = null;
      _isInitialized = false;
    }
  }

  /// Create remaining isolates in the background to avoid blocking startup.
  void _createRemainingIsolatesInBackground() {
    // Start from the second isolate.
    for (int i = 1; i < _maxPoolSize; i++) {
      // Create remaining isolates concurrently without an artificial delay
      // to handle initial task bursts more effectively.
      (() async {
        if (!_isolates.containsKey(i)) {
          await _createIsolate(i);
          _dispatchTask(); // Try to give the new isolate work immediately.
        }
      })();
    }
  }

  /// create a new isolate
  Future<void> _createIsolate(int id) async {
    final receivePort = ReceivePort();
    final completer = Completer<SendPort>();

    // create an isolate and wait for it to send back a SendPort
    _isolates[id] = await Isolate.spawn(
      _isolateEntryPoint,
      receivePort.sendPort,
      debugName: 'isolate-worker-$id',
      errorsAreFatal: false,
    );

    _isIdle[id] = true;
    _taskCount[id] = 0;
    _avgTaskTime[id] = 0.0;

    // listen for messages from the isolate
    receivePort.listen((message) {
      if (message is SendPort) {
        // receive the SendPort of the worker
        _sendPorts[id] = message;
        completer.complete(message);
      } else if (message is Map) {
        // handle the task result
        _handleTaskResult(id, message);
      }
    });

    await completer.future;
  }

  /// handle the task result from the isolate
  void _handleTaskResult(int isolateId, Map result) {
    final task = _activeTasks.remove(isolateId);
    if (task == null) return;

    // update performance statistics
    if (task.timer != null) {
      final taskTime = task.timer!.elapsedMilliseconds.toDouble();
      _updateTaskStats(isolateId, taskTime);
    }

    // Check for error from isolate
    if (result.containsKey('error')) {
      task.completer.completeError(result['error'], result['stackTrace']);
    } else {
      task.completer.complete(result['result']);
    }

    _isIdle[isolateId] = true;
    _dispatchTask(); // Isolate is free, try to process next task from global queue.
  }

  /// update task statistics
  void _updateTaskStats(int isolateId, double taskTime) {
    final currentCount = _taskCount[isolateId]!;
    final currentAvg = _avgTaskTime[isolateId]!;

    // use a sliding average to calculate the average task time
    if (currentCount == 0) {
      _avgTaskTime[isolateId] = taskTime;
    } else {
      // give the latest time a higher weight, faster adaptation
      _avgTaskTime[isolateId] = (currentAvg * 0.7) + (taskTime * 0.3);
    }

    _taskCount[isolateId] = currentCount + 1;
  }

  /// Finds an idle isolate and dispatches a task from the global queue to it.
  void _dispatchTask() {
    if (_globalTaskQueue.isNotEmpty) {
      final idleIsolateId = _findIdleIsolate();
      if (idleIsolateId != null) {
        final task = _globalTaskQueue.removeFirst();
        _activeTasks[idleIsolateId] = task;
        _isIdle[idleIsolateId] = false;
        // start the timer
        if (task.timer != null) {
          task.timer!.start();
        }

        // send a new task to the isolate
        _sendPorts[idleIsolateId]!.send({
          'function': task.function,
          'message': task.message,
          'taskId': _taskCount[idleIsolateId], // add task ID for debugging
        });
      }
    }
  }

  /// execute a task, select the optimal isolate based on performance data
  Future<R> execute<Q, R>(FutureOr<R> Function(Q) function, Q message) async {
    // Always wait for pool initialization before dispatching.
    // The first call pays ~100ms for isolate startup, but avoids running
    // CPU-heavy tasks (e.g. PQ training) on the main thread where async
    // yield contention can inflate 2s of compute to 300s.
    await _ensureInitialized();

    // timer for performance analysis
    final timer = Stopwatch();

    // create a task and add it to the queue
    final task = _IsolateTask<R>(function, message, timer: timer);
    _globalTaskQueue.add(task);
    _dispatchTask(); // Try to dispatch immediately.

    return task.completer.future;
  }

  /// Finds an idle isolate using a round-robin strategy to ensure fair distribution.
  int? _findIdleIsolate() {
    // Check all available isolates, starting from the next one in the rotation.
    for (int i = 0; i < _maxPoolSize; i++) {
      final int isolateId = (_nextIsolateId + i) % _maxPoolSize;

      // We can only use isolates that are fully initialized (have a sendPort).
      if (_sendPorts.containsKey(isolateId) && _isIdle[isolateId] == true) {
        // Found an idle isolate. Update the starting point for the next search.
        _nextIsolateId = (isolateId + 1) % _maxPoolSize;
        return isolateId;
      }
    }
    return null;
  }

  /// Close all isolates
  void dispose() {
    for (final isolate in _isolates.values) {
      isolate.kill(priority: Isolate.immediate);
    }
    _isolates.clear();
    _sendPorts.clear();
    _globalTaskQueue.clear();
    _activeTasks.clear();
    _isIdle.clear();
    _taskCount.clear();
    _avgTaskTime.clear();
    _isInitialized = false;
    _initCompleter = null;
    _nextIsolateId = 0;
  }
}

/// isolate worker entry point
void _isolateEntryPoint(SendPort mainSendPort) {
  final receivePort = ReceivePort();

  // send the SendPort of this isolate back to the main isolate
  mainSendPort.send(receivePort.sendPort);

  // listen for tasks from the main isolate
  receivePort.listen((message) async {
    if (message is Map) {
      final function = message['function'];
      final taskMessage = message['message'];

      try {
        // execute the function with minimal overhead
        final result = await function(taskMessage);
        mainSendPort.send({'result': result});
      } catch (e, stack) {
        // pass error and stack trace back to the main isolate
        mainSendPort.send({'error': e, 'stackTrace': stack});
      }
    }
  });
}

// Global isolate pool instance
final _isolatePool = _IsolatePool();

/// Runs a function in an isolate from the pool and returns the result.
/// This is useful for CPU-intensive tasks that could block the main UI thread.
///
/// The [function] must be a top-level function or a static method.
/// The [message] is the argument passed to the [function].
Future<R> compute<Q, R>(FutureOr<R> Function(Q) function, Q message) async {
  return _isolatePool.execute<Q, R>(function, message);
}

/// Pre-warms the isolate pool to reduce latency on the first compute call.
Future<void> prewarm() async {
  // this will initialize and kick off the pre-warming of all isolates in the pool
  await _isolatePool._ensureInitialized();
}
