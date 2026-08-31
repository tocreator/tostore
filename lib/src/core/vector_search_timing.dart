import '../handler/logger.dart';

/// Optional per-request phase recorder for vector search diagnostics.
///
/// Enable with [traceEnabled] = true (e.g. example benchmark) to emit a breakdown
/// of ANN routing/scoring vs record hydration vs assembly.
class VectorSearchPhaseRecorder {
  /// When true, phases are recorded and [logSummary] emits via [Logger.info].
  static bool traceEnabled = false;

  final Map<String, int> _micros = {};
  final Map<String, dynamic> _diagnostics = {};
  Stopwatch? _phaseSw;
  String? _activePhase;

  /// Run a synchronous phase and accumulate elapsed microseconds.
  T phase<T>(String name, T Function() fn) {
    if (!traceEnabled) return fn();
    _begin(name);
    try {
      return fn();
    } finally {
      _end();
    }
  }

  /// Run an async phase and accumulate elapsed microseconds.
  Future<T> phaseAsync<T>(String name, Future<T> Function() fn) async {
    if (!traceEnabled) return fn();
    _begin(name);
    try {
      return await fn();
    } finally {
      _end();
    }
  }

  /// Add pre-measured microseconds for [name] (accumulates on repeat).
  void addMicros(String name, int micros) {
    if (!traceEnabled || micros <= 0) return;
    _micros[name] = (_micros[name] ?? 0) + micros;
  }

  void _begin(String name) {
    _activePhase = name;
    _phaseSw = Stopwatch()..start();
  }

  void _end() {
    final sw = _phaseSw;
    final name = _activePhase;
    _phaseSw = null;
    _activePhase = null;
    if (sw == null || name == null) return;
    sw.stop();
    addMicros(name, sw.elapsedMicroseconds);
  }

  int get totalMicros => _micros.values.fold<int>(0, (sum, v) => sum + v);

  Map<String, double> toMsMap() {
    return {
      for (final e in _micros.entries) e.key: e.value / 1000.0,
    };
  }

  /// Human-readable single-line summary sorted by descending cost.
  String formatSummary() {
    if (_micros.isEmpty) return 'total=0.00ms (no phases recorded)';
    final totalMs = totalMicros / 1000.0;
    final sorted = _micros.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final parts = [
      for (final e in sorted)
        '${e.key}=${(e.value / 1000.0).toStringAsFixed(2)}ms',
    ];
    return 'total=${totalMs.toStringAsFixed(2)}ms | ${parts.join(' | ')}';
  }

  void logSummary({String? tag}) {
    if (!traceEnabled || _micros.isEmpty) return;
    final prefix = tag != null ? '[$tag] ' : '';
    Logger.info('${prefix}VectorSearchTiming ${formatSummary()}');
  }

  /// Attach non-timing context (nprobe, candidate count, cache miss, etc.).
  void setDiagnostic(String key, dynamic value) {
    if (!traceEnabled) return;
    _diagnostics[key] = value;
  }

  Map<String, dynamic> toMeta() {
    if (_micros.isEmpty && _diagnostics.isEmpty) return const {};
    return {
      if (_micros.isNotEmpty) 'phaseTimingMs': toMsMap(),
      if (_micros.isNotEmpty) 'phaseTimingSummary': formatSummary(),
      if (_micros.isNotEmpty) 'phaseTimingTotalMs': totalMicros / 1000.0,
      if (_diagnostics.isNotEmpty)
        'phaseDiagnostics': Map<String, dynamic>.from(_diagnostics),
    };
  }
}
