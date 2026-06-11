import 'result_status.dart';
import 'result_type.dart';

/// Database operation exception
/// Used to represent fatal developer mistakes or initialization-stage schema verification failures.
class DbException implements Exception {
  /// Grand list of diagnostic statuses
  final List<ResultStatus> statuses;

  DbException(this.statuses);

  /// Get combined human-readable message from all statuses
  String get message =>
      statuses.map((e) => '[${e.codeKey}] ${e.message}').join('\n');

  /// Wrap any exception into a [DbException].
  ///
  /// - If [e] is already a [DbException], it is returned as-is (100% preserving detailed statuses).
  /// - If [e] is any other exception type, it is wrapped in a [DbException] with a fallback [GeneralStatus].
  static DbException wrap(
    dynamic e, {
    ResultType fallbackType = ResultType.engError,
    String fallbackMessage = 'Database operation failed',
  }) {
    if (e is DbException) {
      return e;
    }
    return DbException([
      GeneralStatus(
        type: fallbackType,
        message: '$fallbackMessage: $e',
      ),
    ]);
  }

  /// Force wrap any exception into a new [DbException] with the specified [forceType].
  ///
  /// - If [e] is a [DbException], all of its diagnostic statuses are flattened and appended
  ///   after the new forced [GeneralStatus] to preserve the causal chain.
  /// - Otherwise, [e] is appended as a nested [GeneralStatus] representing the original cause.
  static DbException forceWrap(
    dynamic e, {
    required ResultType forceType,
    required String message,
  }) {
    final parentStatus = GeneralStatus(
      type: forceType,
      message: message,
    );
    if (e is DbException) {
      return DbException([parentStatus, ...e.statuses]);
    }
    return DbException([
      parentStatus,
      GeneralStatus(
        type: ResultType.engError,
        message: 'Original cause: $e',
      ),
    ]);
  }

  @override
  String toString() {
    final buf = StringBuffer();
    buf.write('🛑 DbException:');
    for (final status in statuses) {
      buf.write(
          '\n   - [Index ${status.index}] [${status.codeKey}] (Code ${status.code}): ${status.message}');
      if (status is ConstraintStatus) {
        buf.write(
            '\n     Table: ${status.tableName}, Fields: ${status.fields}, Conflicting: ${status.conflictingKeys}');
      } else if (status is SchemaValidationStatus) {
        buf.write(
            '\n     Table: ${status.tableName}, Field: ${status.field}, WrongValue: ${status.wrongValue}');
      } else if (status is InvalidArgumentStatus) {
        buf.write(
            '\n     Parameter: ${status.parameterName}, PassedValue: ${status.passedValue}');
      } else if (status is TransactionOperationStatus) {
        buf.write('\n     TxId: ${status.txId}');
      }
    }
    return buf.toString();
  }
}
