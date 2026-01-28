/// Transaction status (public API)
///
/// success: transaction is committed and completed successfully
/// failed: transaction is rolled back or failed
enum TransactionStatus {
  success,
  failed,
}

/// Transaction error type (public API)
///
/// Only contains error types that can be reliably identified in actual operation, otherwise it is unknown.
enum TransactionErrorType {
  operationError,
  integrityViolation,
  timeout,
  io,
  conflict,
  userAbort,
  unknown,
}

/// Transaction error (public API)
///
/// Provides transaction-level error summary, without the details of each operation.
class TransactionError {
  final TransactionErrorType type; // transaction error type
  final String message; // transaction error message
  final Object? cause; // transaction error cause
  final String? stackTrace; // transaction error stack trace

  const TransactionError({
    required this.type,
    required this.message,
    this.cause,
    this.stackTrace,
  });
}

/// Transaction-level result (public API)
///
/// returns the transaction result and error summary
class TransactionResult {
  final String txId; // transaction id
  final TransactionStatus status; // transaction status
  final TransactionError? error; // transaction error
  final DateTime startedAt; // transaction started at
  final DateTime finishedAt; // transaction finished at
  final bool logFlushed; // whether the log is flushed

  const TransactionResult({
    required this.txId,
    required this.status,
    required this.startedAt,
    required this.finishedAt,
    this.error,
    this.logFlushed = false,
  });

  bool get isSuccess => status == TransactionStatus.success;
  bool get isFailed => status == TransactionStatus.failed;

  factory TransactionResult.success({
    required String txId,
    required DateTime startedAt,
    required DateTime finishedAt,
    bool logFlushed = false,
  }) {
    return TransactionResult(
      txId: txId,
      status: TransactionStatus.success,
      startedAt: startedAt,
      finishedAt: finishedAt,
      logFlushed: logFlushed,
    );
  }

  factory TransactionResult.failed({
    required String txId,
    required DateTime startedAt,
    required DateTime finishedAt,
    required TransactionError error,
  }) {
    return TransactionResult(
      txId: txId,
      status: TransactionStatus.failed,
      startedAt: startedAt,
      finishedAt: finishedAt,
      error: error,
      logFlushed: false,
    );
  }
}
