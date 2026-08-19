/// Pressure state of write buffer and background flush queue.
enum FlushPressureState {
  /// Absolutely idle: totalPending == 0. No flush scheduled / can sleep.
  idle,

  /// Normal: 0 < totalPending <= busyThreshold.
  /// Pure-sync fast-path enqueue, yield to client batch operations.
  normal,

  /// Busy: totalPending > busyThreshold.
  /// Flush is congested; new data operations suspend and wait for flush release.
  busy,
}
