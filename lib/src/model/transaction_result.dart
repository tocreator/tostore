import 'result_status.dart';
import 'result_type.dart';

/// Transaction-level result (public API)
///
/// returns the transaction execution details and statuses
class TransactionResult {
  final String txId; // transaction id
  final List<ResultStatus> statuses; // transaction status results
  final DateTime startedAt; // transaction started at
  final DateTime finishedAt; // transaction finished at
  final bool logFlushed; // whether the log is flushed
  final bool hasErrors;

  TransactionResult({
    required this.txId,
    required this.statuses,
    required this.startedAt,
    required this.finishedAt,
    bool? hasErrors,
    this.logFlushed = false,
  }) : hasErrors =
            hasErrors ?? statuses.any((s) => s.type != ResultType.success);

  @Deprecated('Use hasErrors instead to properly check transaction outcome')
  bool get isSuccess => !hasErrors;

  @Deprecated('Use hasErrors instead to properly check transaction outcome')
  bool get isFailed => hasErrors;

  factory TransactionResult.success({
    required String txId,
    required DateTime startedAt,
    required DateTime finishedAt,
    bool logFlushed = false,
  }) {
    return TransactionResult(
      txId: txId,
      statuses: const [],
      startedAt: startedAt,
      finishedAt: finishedAt,
      hasErrors: false,
      logFlushed: logFlushed,
    );
  }

  factory TransactionResult.failed({
    required String txId,
    required DateTime startedAt,
    required DateTime finishedAt,
    required List<ResultStatus> statuses,
  }) {
    return TransactionResult(
      txId: txId,
      statuses: statuses,
      startedAt: startedAt,
      finishedAt: finishedAt,
      hasErrors: true,
      logFlushed: false,
    );
  }

  @Deprecated('Use statuses instead to inspect results')
  TransactionStatus get status =>
      !hasErrors ? TransactionStatus.success : TransactionStatus.failed;

  @Deprecated('Use statuses instead for detailed diagnostics')
  TransactionError? get error {
    if (!hasErrors) return null;
    if (statuses.isEmpty) return null;
    final firstErr = statuses.firstWhere((s) => s.type != ResultType.success,
        orElse: () => statuses.first);

    TransactionErrorType errType = TransactionErrorType.unknown;
    final type = firstErr.type;
    if (type.isConstraintError) {
      errType = TransactionErrorType.integrityViolation;
    } else if (type == ResultType.sysTimeout ||
        type == ResultType.sysTimeoutLockAcquisition) {
      errType = TransactionErrorType.timeout;
    } else if (type == ResultType.sysIoGeneric ||
        type == ResultType.sysIoFileRead ||
        type == ResultType.sysIoFileWrite) {
      errType = TransactionErrorType.io;
    } else if (type == ResultType.sysTransactionConflict) {
      errType = TransactionErrorType.conflict;
    } else if (type == ResultType.sysTransactionAborted) {
      errType = TransactionErrorType.userAbort;
    } else {
      errType = TransactionErrorType.operationError;
    }

    return TransactionError(
      type: errType,
      message: firstErr.message,
    );
  }

  /// Convert TransactionResult to a Map (for serialization)
  Map<String, dynamic> toJson() {
    return {
      'txId': txId,
      'startedAt': startedAt.toIso8601String(),
      'finishedAt': finishedAt.toIso8601String(),
      'logFlushed': logFlushed,
      'statuses': statuses.map((e) => e.toJson()).toList(),
      'hasErrors': hasErrors,
    };
  }

  /// Create a TransactionResult from a Map (for deserialization)
  static TransactionResult fromJson(Map<String, dynamic> json) {
    final statusList = (json['statuses'] as List? ?? [])
        .map((e) => ResultStatus.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();

    return TransactionResult(
      txId: json['txId'] as String? ?? '',
      statuses: statusList,
      startedAt: DateTime.parse(
          json['startedAt'] as String? ?? DateTime.now().toIso8601String()),
      finishedAt: DateTime.parse(
          json['finishedAt'] as String? ?? DateTime.now().toIso8601String()),
      hasErrors: json['hasErrors'] as bool?,
      logFlushed: json['logFlushed'] == true,
    );
  }
}

@Deprecated('Use statuses instead')
enum TransactionStatus {
  success,
  failed,
}

@Deprecated('Use ResultType instead')
enum TransactionErrorType {
  operationError,
  integrityViolation,
  timeout,
  io,
  conflict,
  userAbort,
  unknown;

  bool get isError => this != success && this != success; // placeholder helper
  static const success = null; // dummy constant
}

@Deprecated('Use ResultStatus instead')
class TransactionError {
  final TransactionErrorType type;
  final String message;
  final Object? cause;
  final String? stackTrace;

  const TransactionError({
    required this.type,
    required this.message,
    this.cause,
    this.stackTrace,
  });
}
