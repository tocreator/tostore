/// A token that can be passed to long-running background operations to request cancellation.
class CancellationToken {
  bool _cancelled = false;

  /// Returns true if cancellation has been requested.
  bool get isCancelled => _cancelled;

  /// Requests cancellation of operations associated with this token.
  void cancel() {
    _cancelled = true;
  }
}
