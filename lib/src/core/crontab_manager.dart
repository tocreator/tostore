import 'dart:async';
import '../handler/logger.dart';

/// Usage example:
/// CrontabManager.addCallback(ExecuteInterval.seconds15, () {
///   Logger.log('Executing the callback that runs every 15 seconds');
/// })

/// Efficient global scheduled execution manager
/// Uses absolute time-based dynamic cycle management to optimize energy consumption
class CrontabManager {
  static final CrontabManager _instance = CrontabManager._();

  // Interval execution groups
  final Map<ExecuteInterval, _IntervalGroup> _groups = {};

  // Main timer
  Timer? _timer;

  // Dynamically calculated optimal check interval
  Duration _checkInterval = const Duration(seconds: 3);

  // Whether already started
  bool _isStarted = false;

  CrontabManager._() {
    // Initialize all interval groups
    for (var interval in ExecuteInterval.values) {
      _groups[interval] = _IntervalGroup(interval);
    }
  }

  /// Add a callback function for periodic execution
  static void addCallback(ExecuteInterval interval, Function() callback) {
    // Add callback
    _instance._groups[interval]!.callbacks.add(callback);

    // Check if optimization of check interval is needed
    bool needOptimize = _instance._groups[interval]!.callbacks.length == 1;

    // If manager is not started yet, start it automatically
    if (!_instance._isStarted) {
      start();
    }
    // If already started and optimization is needed, re-optimize check interval
    else if (needOptimize) {
      _instance._optimizeCheckInterval();
      _restartTimer();
    }
  }

  /// Remove a callback function
  static void removeCallback(ExecuteInterval interval, Function() callback) {
    _instance._groups[interval]!.callbacks.remove(callback);

    // Check if optimization of check interval is needed
    bool needOptimize = _instance._groups[interval]!.callbacks.isEmpty;

    // If optimization is needed and already started, re-optimize check interval
    if (needOptimize && _instance._isStarted) {
      _instance._optimizeCheckInterval();
      _restartTimer();
    }
  }

  /// Optimize check interval
  void _optimizeCheckInterval() {
    // Check if there are tasks with 1-second interval
    if (_groups[ExecuteInterval.seconds1]!.callbacks.isNotEmpty) {
      _checkInterval = const Duration(seconds: 1);
      return;
    }

    // Check if there are active short intervals
    bool hasShortInterval =
        _groups[ExecuteInterval.seconds3]!.callbacks.isNotEmpty ||
            _groups[ExecuteInterval.seconds15]!.callbacks.isNotEmpty;

    // If there are only long-interval tasks, use longer check interval for efficiency
    if (!hasShortInterval) {
      if (_groups[ExecuteInterval.hour1]!.callbacks.isNotEmpty) {
        _checkInterval = const Duration(minutes: 1); // Check once per minute
      } else if (_groups[ExecuteInterval.hour24]!.callbacks.isNotEmpty) {
        _checkInterval =
            const Duration(minutes: 5); // Check once every 5 minutes
      } else {
        // No tasks, use longer interval to reduce resource consumption
        _checkInterval = const Duration(minutes: 1);
      }
    } else {
      // There are short-interval tasks, use appropriate short check interval
      if (_groups[ExecuteInterval.seconds3]!.callbacks.isNotEmpty) {
        _checkInterval = const Duration(seconds: 3);
      } else {
        _checkInterval = const Duration(
            seconds:
                5); // For 15-second intervals, 5-second checks are sufficient
      }
    }
  }

  /// Restart timer
  static void _restartTimer() {
    if (_instance._isStarted) {
      _instance._timer?.cancel();
      _instance._timer = Timer.periodic(
          _instance._checkInterval, (_) => _instance._processIntervals());
    }
  }

  /// Start scheduled execution
  static void start() {
    // If already started, ignore
    if (_instance._isStarted) return;

    // Cancel any existing timer
    _instance._timer?.cancel();

    // Calculate optimal check interval
    _instance._optimizeCheckInterval();

    // Create main timer
    _instance._timer = Timer.periodic(
        _instance._checkInterval, (_) => _instance._processIntervals());

    _instance._isStarted = true;
  }

  /// Process all intervals
  void _processIntervals() {
    final now = DateTime.now();
    bool anyExecuted = false;

    // Check and execute due intervals
    for (var group in _groups.values) {
      if (group.callbacks.isEmpty) continue; // Skip intervals with no callbacks

      if (group.shouldExecute(now)) {
        // Execute callbacks
        group.executeCallbacks();
        group.updateNextExecutionTime();
        anyExecuted = true;
      }
    }

    // If no intervals executed and check interval is less than 1 minute, consider optimization
    if (!anyExecuted &&
        _checkInterval.inMinutes < 1 &&
        DateTime.now().second % 30 == 0) {
      _optimizeCheckInterval();
      // If check interval changed after optimization, restart timer
      if (_checkInterval.inSeconds > 3) {
        _timer?.cancel();
        _timer = Timer.periodic(_checkInterval, (_) => _processIntervals());
      }
    }
  }

  /// Get the count of all registered callbacks
  static Map<String, int> getCallbackCounts() {
    final result = <String, int>{};
    for (var entry in _instance._groups.entries) {
      result[_intervalToString(entry.key)] = entry.value.callbacks.length;
    }
    return result;
  }

  /// Stop scheduled execution
  static void stop() {
    _instance._timer?.cancel();
    _instance._timer = null;
    _instance._isStarted = false;
  }

  /// Release resources
  static void dispose() {
    stop();
    for (var group in _instance._groups.values) {
      group.callbacks.clear();
    }
  }

  /// Get string representation of interval
  static String _intervalToString(ExecuteInterval interval) {
    switch (interval) {
      case ExecuteInterval.seconds1:
        return '1 second';
      case ExecuteInterval.seconds3:
        return '3 seconds';
      case ExecuteInterval.seconds15:
        return '15 seconds';
      case ExecuteInterval.hour1:
        return '1 hour';
      case ExecuteInterval.hour24:
        return '24 hours';
    }
  }
}

/// Predefined execution intervals
enum ExecuteInterval {
  /// 1-second interval
  seconds1(Duration(seconds: 1)),

  /// 3-second interval
  seconds3(Duration(seconds: 3)),

  /// 15-second interval
  seconds15(Duration(seconds: 15)),

  /// 1-hour interval
  hour1(Duration(hours: 1)),

  /// 24-hour interval
  hour24(Duration(hours: 24));

  /// Interval duration
  final Duration duration;
  const ExecuteInterval(this.duration);
}

/// Callback management for interval execution
class _IntervalGroup {
  final ExecuteInterval interval;
  final List<Function()> callbacks = [];
  DateTime nextExecutionTime = DateTime.now();

  _IntervalGroup(this.interval) {
    // Initialize next execution time
    nextExecutionTime = DateTime.now().add(interval.duration);
  }

  /// Update next execution time
  void updateNextExecutionTime() {
    nextExecutionTime = DateTime.now().add(interval.duration);
  }

  /// Check if execution should occur
  bool shouldExecute(DateTime now) {
    return now.isAfter(nextExecutionTime);
  }

  /// Execute all callbacks
  void executeCallbacks() {
    final callbacksCopy = List<Function()>.from(callbacks);
    for (var callback in callbacksCopy) {
      try {
        callback();
      } catch (e) {
        Logger.error('Error executing callback: $e', label: 'CrontabManager');
      }
    }
  }
}
