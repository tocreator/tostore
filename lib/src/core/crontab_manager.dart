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

  // Idle stop timer (one-shot)
  Timer? _idleTimer;

  // Idle timeout duration (default 30s)
  Duration _idleTimeout = const Duration(seconds: 30);

  // Last external activity timestamp
  DateTime _lastActivityAt = DateTime.now();

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

    // If manager is not started yet, start it automatically (only when there are tasks)
    if (!_instance._isStarted) {
      start();
    } else if (needOptimize) {
      // If already started and a new group becomes active, re-optimize
      _instance._optimizeCheckInterval();
      _restartTimer();
    }
    // Treat registration as activity
    _instance._onActivity();
  }

  /// Remove a callback function
  static void removeCallback(ExecuteInterval interval, Function() callback) {
    _instance._groups[interval]!.callbacks.remove(callback);

    if (!_instance._isStarted) return;

    // If no callbacks remain at all, stop the manager to save energy
    if (!_instance._hasAnyCallbacks()) {
      stop();
      return;
    }

    // Otherwise re-optimize check interval since global composition changed
    _instance._optimizeCheckInterval();
    _restartTimer();
  }

  /// Optimize check interval
  void _optimizeCheckInterval() {
    // Check if there are active short intervals
    bool hasShortInterval =
        _groups[ExecuteInterval.seconds3]!.callbacks.isNotEmpty ||
            _groups[ExecuteInterval.seconds10]!.callbacks.isNotEmpty;

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
      _instance._scheduleIdleStop();
    }
  }

  /// Start scheduled execution
  static void start() {
    // If already started, ignore
    if (_instance._isStarted) return;

    // If there are no callbacks, do not start (energy saving)
    if (!_instance._hasAnyCallbacks()) return;

    // Cancel any existing timer
    _instance._timer?.cancel();

    // Calculate optimal check interval
    _instance._optimizeCheckInterval();

    // Create main timer
    _instance._timer = Timer.periodic(
        _instance._checkInterval, (_) => _instance._processIntervals());

    _instance._isStarted = true;
    _instance._scheduleIdleStop();
  }

  /// Whether there is at least one active callback across all groups
  bool _hasAnyCallbacks() {
    for (var group in _groups.values) {
      if (group.callbacks.isNotEmpty) return true;
    }
    return false;
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
    _instance._idleTimer?.cancel();
    _instance._idleTimer = null;
  }

  /// Release resources
  static void dispose() {
    stop();
    for (var group in _instance._groups.values) {
      group.callbacks.clear();
    }
  }

  /// External activity signal: keeps scheduler alive and restarts if paused
  static void notifyActivity() {
    try {
      _instance._onActivity();
    } catch (_) {}
  }

  /// Optionally customize idle timeout
  static void setIdleTimeout(Duration timeout) {
    _instance._idleTimeout = timeout;
    if (_instance._isStarted) {
      _instance._scheduleIdleStop();
    }
  }

  // Internal: record activity and ensure timer is running
  void _onActivity() {
    _lastActivityAt = DateTime.now();
    if (!_isStarted) {
      if (_hasAnyCallbacks()) {
        CrontabManager.start();
      }
      return;
    }
    _scheduleIdleStop();
  }

  // Internal: schedule idle stop
  void _scheduleIdleStop() {
    if (_idleTimer != null) {
      return; // already scheduled; keep single timer to reduce churn
    }
    void arm(Duration d) {
      _idleTimer = Timer(d, () {
        _idleTimer = null;
        final now = DateTime.now();
        final elapsed = now.difference(_lastActivityAt);
        if (elapsed >= _idleTimeout) {
          if (_hasAnyCallbacks()) {
            // Pause main timer; callbacks remain registered
            _timer?.cancel();
            _timer = null;
            _isStarted = false;
            return;
          }
        }
        // Not idle long enough; schedule remaining time
        final remaining = _idleTimeout - elapsed;
        final safe = remaining.inMilliseconds <= 0
            ? const Duration(milliseconds: 50)
            : remaining;
        arm(safe);
      });
    }

    arm(_idleTimeout);
  }

  /// Get string representation of interval
  static String _intervalToString(ExecuteInterval interval) {
    switch (interval) {
      case ExecuteInterval.seconds3:
        return '3 seconds';
      case ExecuteInterval.seconds10:
        return '10 seconds';
      case ExecuteInterval.minutes1:
        return '1 minute';
      case ExecuteInterval.minutes5:
        return '5 minutes';
      case ExecuteInterval.hour1:
        return '1 hour';
      case ExecuteInterval.hour24:
        return '24 hours';
    }
  }
}

/// Predefined execution intervals
enum ExecuteInterval {
  /// 3-second interval
  seconds3(Duration(seconds: 3)),

  /// 10-second interval
  seconds10(Duration(seconds: 10)),

  /// 1-minute interval
  minutes1(Duration(minutes: 1)),

  /// 5-minute interval
  minutes5(Duration(minutes: 5)),

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
        final result = callback();
        // If callback returns a Future, schedule it asynchronously to avoid blocking
        // This is important for async callbacks like weight decay that should not block the timer
        if (result is Future) {
          result.catchError((e) {
            Logger.error('Error executing async callback: $e',
                label: 'CrontabManager');
          });
        }
      } catch (e) {
        Logger.error('Error executing callback: $e', label: 'CrontabManager');
      }
    }
  }
}
