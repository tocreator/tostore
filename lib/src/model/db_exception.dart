import 'result_status.dart';

/// Database operation exception
/// Used to represent fatal developer mistakes or initialization-stage schema verification failures.
class DbException implements Exception {
  /// Grand list of diagnostic statuses
  final List<ResultStatus> statuses;

  DbException(this.statuses);

  /// Get combined human-readable message from all statuses
  String get message =>
      statuses.map((e) => '[${e.codeKey}] ${e.message}').join('\n');

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
