import 'dart:async';
import 'dart:math' as math;

/// A utility to prevent UI jank by yielding to the event loop periodically
/// based on elapsed time rather than iteration count.
///
/// This controller implements "smart yielding" logic that adapts to device
/// performance:
/// 1. **Adaptive Interval**: Dynamically adjusts the check interval based on
///    measured execution throughput.
/// 2. **Smoothing**: Uses a moving average (SMA-5) to prevent interval jitter.
/// 3. **Persistent Learning**: Learns and persists the optimal interval for
///    specific [topic]s, ensuring consistent performance across calls.
/// 4. **Low Latency**: Supports immediate yielding (min interval = 1) for
///    extremely heavy workloads.
///
/// Usage (required fast-path pattern -- do **not** wrap in an `async` helper):
/// ```dart
/// final yieldController = YieldController('batch_process');
/// for (final item in heavyList) {
///   // process item
///   final y = yieldController.maybeYield();
///   if (y != null) await y;
/// }
/// ```
///
/// Returning `Future?` (instead of an `async` method) avoids Future/microtask
/// overhead on the common path where no yield is needed. Always null-check
/// before `await`; discarding the Future silently skips the yield.
/// Global settings for YieldController
class YieldControllerSettings {
  /// Whether yielding is enabled in the current isolate.
  ///
  /// Static fields are isolate-local in Dart. The main isolate enables yielding
  /// during database initialization; compute worker isolates keep the default
  /// disabled state and skip yield checks naturally.
  bool enabled = false;

  /// Target time budget in milliseconds.
  /// Default is 8ms (optimized for 120fps UI).
  /// For backend servers, you can increase this to 50ms+ to reduce overhead.
  int targetBudgetMs = 8;
}

class YieldController {
  /// Global settings instance
  static final YieldControllerSettings globalSettings =
      YieldControllerSettings();

  /// The default time budget before yielding (in milliseconds).
  /// Target is 8ms, leaving buffer within a standard 16ms (60fps) or
  /// 8ms (120fps) frame.
  static const int defaultBudgetMs = 8;

  /// Absolute minimum check interval. Set to 1 to ensure that even single items
  /// exceeding the budget can trigger a yield immediately.
  static const int absoluteMinCheckInterval = 1;

  /// Maximum check interval cap to prevent unresponsiveness.
  static const int _maxCheckInterval = 10000;

  /// Number of samples used for the Simple Moving Average smoothing.
  static const int _smoothingSampleSize = 5;

  /// Static cache to store learned optimal intervals per topic.
  static final Map<String, int> _topicIntervals = {};

  final Stopwatch _stopwatch = Stopwatch();
  final int _budgetMs;
  final String _topic;
  final bool _enabled;

  /// Per-instance floor for adaptive interval (clamps learning / dual-pressure collapse).
  final int _minCheckInterval;

  /// The current dynamic check interval (number of iterations between time checks).
  int _currentCheckInterval;

  /// The number of iterations processed since the last time check.
  int _iterationsSinceCheck = 0;

  /// Ring buffer for smoothing the interval calculation.
  final List<int> _recentSamples = [];
  int _sampleIndex = 0;

  /// Creates a [YieldController] instance.
  ///
  /// [topic] - A **required** unique identifier for the workload. Used to persist
  ///           and retrieve learned optimization states for this specific task.
  /// [budgetMs] - The time budget in milliseconds before yielding (default: 6ms).
  /// [checkInterval] - Initial check interval used only if no learned history exists.
  /// [minCheckInterval] - Floor for adaptive interval. Use a higher value on
  ///   dual-pressure hot paths (batchInsert + flush) to avoid Future.delayed avalanche.
  YieldController(
    this._topic, {
    int? budgetMs,
    int checkInterval = 256,
    int minCheckInterval = absoluteMinCheckInterval,
  })  : _budgetMs = budgetMs ?? globalSettings.targetBudgetMs,
        _enabled = globalSettings.enabled,
        _minCheckInterval =
            math.max(absoluteMinCheckInterval, minCheckInterval),
        _currentCheckInterval = math.max(
          _topicIntervals[_topic] ?? checkInterval,
          math.max(absoluteMinCheckInterval, minCheckInterval),
        ) {
    if (!_enabled) {
      return;
    }
    // Initialize smoothing buffer with the starting interval estimate
    for (int i = 0; i < _smoothingSampleSize; i++) {
      _recentSamples.add(_currentCheckInterval);
    }
    _stopwatch.start();
  }

  /// Checks if the time budget has been exceeded and yields if necessary.
  ///
  /// Returns `null` if no yield is needed (fast path -- no Future / no await).
  /// Returns a `Future` only when yielding is actually required.
  ///
  /// **Required call pattern** (skipping the null-check drops the yield):
  /// ```dart
  /// final y = yieldController.maybeYield();
  /// if (y != null) await y;
  /// ```
  ///
  /// Optimized for hot loops:
  /// - Only checks `Stopwatch` every [_currentCheckInterval] iterations.
  /// - If budget is exceeded, yields to the event loop (`Future.delayed`).
  /// - Updates the adaptive interval based on throughput.
  Future<void>? maybeYield() {
    if (!_enabled) return null;

    _iterationsSinceCheck++;

    // Fast path: skip check if within current interval (NO async overhead)
    if (_iterationsSinceCheck < _currentCheckInterval) return null;

    // Slow path: check actual elapsed time
    final elapsed = _stopwatch.elapsedMilliseconds;

    if (elapsed >= _budgetMs) {
      // Budget exceeded: yield to allow UI updates
      // Recalculate adaptive interval based on this batch's throughput
      _updateAdaptiveInterval(elapsed);

      // Reset state for the next batch
      _stopwatch.reset();
      _iterationsSinceCheck = 0;

      return Future.delayed(Duration.zero);
    } else {
      // Budget not exceeded yet
      if (elapsed > 0) {
        // We have measurable data, update estimate but continue
        _updateAdaptiveInterval(elapsed);
        _iterationsSinceCheck = 0;
      } else {
        // Execution was too fast to measure (<1ms).
        // Exponentially back off the check interval to reduce overhead,
        // but do not record this as a valid sample.
        _currentCheckInterval =
            math.min(_currentCheckInterval * 2, _maxCheckInterval);
        _iterationsSinceCheck = 0;
      }
      return null;
    }
  }

  /// Updates the adaptive interval based on measured execution time.
  ///
  /// Uses a target safety factor (0.8) and a moving average implementation
  /// to calculate a stable, optimized check interval.
  void _updateAdaptiveInterval(int elapsedMs) {
    if (elapsedMs <= 0 || _iterationsSinceCheck <= 0) return;

    final timePerItem = elapsedMs / _iterationsSinceCheck;

    // Target 80% of budget to provide a safety margin
    int calculatedInterval = (_budgetMs * 0.8 / timePerItem).floor();

    // Clamp to valid range (instance floor prevents dual-pressure avalanche)
    if (calculatedInterval < _minCheckInterval) {
      calculatedInterval = _minCheckInterval;
    }
    if (calculatedInterval > _maxCheckInterval) {
      calculatedInterval = _maxCheckInterval;
    }

    // Update smoothing buffer
    _recentSamples[_sampleIndex] = calculatedInterval;
    _sampleIndex = (_sampleIndex + 1) % _smoothingSampleSize;

    // Calculate new smoothed interval (Simple Moving Average)
    int sum = 0;
    for (final s in _recentSamples) {
      sum += s;
    }
    final int smoothedInterval = math.max(
      _minCheckInterval,
      (sum / _smoothingSampleSize).round(),
    );

    _currentCheckInterval = smoothedInterval;

    // Persist learned interval for future instances (already floored)
    _topicIntervals[_topic] = smoothedInterval;
  }

  /// Resets the internal timer and counter state.
  ///
  /// Does **not** clear learned history or smoothing buffer.
  void reset() {
    if (!_enabled) return;
    _iterationsSinceCheck = 0;
    _stopwatch.reset();
  }
}
