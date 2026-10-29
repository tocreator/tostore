import 'dart:math';

/// Monotonic prewarm byte ledger: charges only increase; eviction never refunds.
///
/// Startup warm must stop once the planned budget is consumed. Measuring live
/// cache residency after ResourceManager / TreeCache eviction would free room
/// and keep loading colder pages — that thrash is exactly what this blocks.
final class PrewarmBudgetLedger {
  PrewarmBudgetLedger({
    required int capBytes,
    int initialCommittedBytes = 0,
  })  : capBytes = max(0, capBytes),
        committedBytes = max(0, initialCommittedBytes);

  /// Hard ceiling for this warm session (bytes).
  final int capBytes;

  /// Bytes already charged this session (never decreases).
  int committedBytes;

  bool _stopped = false;

  /// True once [tryCharge] failed or [stop] was called.
  bool get isExhausted =>
      _stopped || (capBytes > 0 && committedBytes >= capBytes);

  int get remainingBytes => max(0, capBytes - committedBytes);

  /// Charge [estimatedBytes] if they fit. On failure, latches exhausted.
  ///
  /// Zero/negative estimates are free no-ops (still succeed unless already
  /// exhausted). Oversized first items do not load — caller should skip.
  bool tryCharge(int estimatedBytes) {
    if (isExhausted) return false;
    if (estimatedBytes <= 0) return true;
    if (committedBytes + estimatedBytes > capBytes) {
      _stopped = true;
      return false;
    }
    committedBytes += estimatedBytes;
    return true;
  }

  /// Latch stop without charging (e.g. navOnly decided mid-pass).
  void stop() {
    _stopped = true;
  }
}

/// Corpus larger than this multiple of the warm budget → payload warm is
/// not worth the I/O (navigation / metadata only).
const double prewarmPayloadWorthlessRatio = 1.5;

/// Whether bulk payload warm is expected to lose to eviction / cold working set.
bool isPrewarmPayloadWorthless({
  required int dataBytes,
  required int budgetBytes,
  double ratio = prewarmPayloadWorthlessRatio,
}) {
  if (budgetBytes <= 0) return dataBytes > 0;
  return dataBytes > budgetBytes * ratio;
}
