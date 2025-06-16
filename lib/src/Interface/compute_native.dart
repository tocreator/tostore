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
  final Map<int, Queue<_IsolateTask>> _taskQueues = {};
  final Map<int, bool> _isIdle = {};
  final Map<int, int> _taskCount =
      {}; // track the number of tasks processed by each isolate
  final Map<int, double> _avgTaskTime =
      {}; // track the average task execution time for each isolate
  bool _isInitialized = false;
  bool _isPrewarmed = false;

  /// initialize the isolate pool
  Future<void> _ensureInitialized() async {
    if (!_isInitialized) {
      // pre-create the isolate pool
      final futures = <Future>[];
      for (int i = 0; i < _maxPoolSize; i++) {
        futures.add(_createIsolate(i));
        _taskCount[i] = 0;
        _avgTaskTime[i] = 0;
      }

      // wait for all isolates to be initialized
      await Future.wait(futures);
      _isInitialized = true;

      // pre-warm the isolate pool
      if (!_isPrewarmed) {
        await _prewarmIsolates();
      }
    }
  }

  /// pre-warm all isolates to reduce the initial latency
  Future<void> _prewarmIsolates() async {
    if (_isPrewarmed) return;

    // a simple warmup function
    Future<int> warmupFunc(int x) async {
      // perform some simple calculations to ensure the isolate is fully initialized
      int result = 0;
      for (int i = 0; i < 100; i++) {
        result += i;
      }
      return result;
    }

    // send a warmup task to each isolate
    final futures = <Future>[];
    for (int i = 0; i < _maxPoolSize; i++) {
      futures.add(execute(warmupFunc, 1));
    }

    // wait for all warmup tasks to complete
    await Future.wait(futures);
    _isPrewarmed = true;
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

    _taskQueues[id] = Queue<_IsolateTask>();
    _isIdle[id] = true;

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
    if (_taskQueues[isolateId]!.isNotEmpty) {
      final task = _taskQueues[isolateId]!.removeFirst();

      // update performance statistics
      if (task.timer != null) {
        final taskTime = task.timer!.elapsedMilliseconds.toDouble();
        _updateTaskStats(isolateId, taskTime);
      }

      if (result.containsKey('error')) {
        task.completer.completeError(result['error'], result['stackTrace']);
      } else {
        task.completer.complete(result['result']);
      }

      // reduce unnecessary microtask queue pressure
      Future.microtask(() {
        _processNextTask(isolateId);
      });
    }
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

  /// process the next task in the queue
  void _processNextTask(int isolateId) {
    if (_taskQueues[isolateId]!.isNotEmpty) {
      final nextTask = _taskQueues[isolateId]!.first;
      _isIdle[isolateId] = false;

      // start the timer
      if (nextTask.timer != null) {
        nextTask.timer!.start();
      }

      // send a new task to the isolate
      _sendPorts[isolateId]!.send({
        'function': nextTask.function,
        'message': nextTask.message,
        'taskId': _taskCount[isolateId], // add task ID for debugging
      });
    } else {
      _isIdle[isolateId] = true;
    }
  }

  /// execute a task, select the optimal isolate based on performance data
  Future<R> execute<Q, R>(FutureOr<R> Function(Q) function, Q message) async {
    await _ensureInitialized();

    // find the optimal isolate instance
    int targetId = _findOptimalIsolate();

    // timer for performance analysis
    final timer = Stopwatch();

    // create a task and add it to the queue
    final task = _IsolateTask<R>(function, message, timer: timer);
    _taskQueues[targetId]!.add(task);

    // if the isolate is idle, process the task immediately
    if (_isIdle[targetId]!) {
      _processNextTask(targetId);
    }

    return task.completer.future;
  }

  /// find the optimal isolate instance, considering queue length and historical task processing time
  int _findOptimalIsolate() {
    // if there is only one isolate, return immediately
    if (_maxPoolSize == 1) return 0;

    double minScore = double.infinity;
    int targetId = 0;

    // consider queue length and average task processing time
    for (int id = 0; id < _maxPoolSize; id++) {
      final queueLength = _taskQueues[id]!.length;
      final avgTime = _avgTaskTime[id]!;

      // use weighted scoring based on queue length and average execution time
      // the weighting factor can be adjusted based on the application
      double score = (queueLength * 1.5) + (avgTime / 50.0);

      if (score < minScore) {
        minScore = score;
        targetId = id;
      }
    }

    return targetId;
  }

  /// Close all isolates
  void dispose() {
    for (final isolate in _isolates.values) {
      isolate.kill(priority: Isolate.immediate);
    }
    _isolates.clear();
    _sendPorts.clear();
    _taskQueues.clear();
    _isIdle.clear();
    _taskCount.clear();
    _avgTaskTime.clear();
    _isInitialized = false;
    _isPrewarmed = false;
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
