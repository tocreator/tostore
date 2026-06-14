import '../handler/platform_handler.dart';
import 'db_result.dart';
import 'query_result.dart';
import 'result_status.dart';
import 'result_type.dart';
import 'schema_update_result.dart';
import 'transaction_result.dart';

/// Database operation exception
/// Used to represent fatal developer mistakes or initialization-stage schema verification failures.
class DbException implements Exception {
  /// Grand list of diagnostic statuses
  final List<ResultStatus> statuses;

  /// Whether this exception instance has been logged by the Logger
  bool isLogged = false;

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

  /// Check if the result contains a developer error in debug mode, and throw a [DbException] if so.
  static void checkDeveloperError(dynamic result) {
    if (result == null) return;
    if (!PlatformHandler.isDebug) return;

    if (result is DbException) {
      final hasDev = result.statuses.any((s) => s.isDeveloperError);
      if (hasDev) {
        throw result;
      }
    } else if (result is DbResult) {
      if (result.hasErrors) {
        final hasDev = result.statuses.any((s) => s.isDeveloperError);
        if (hasDev) {
          throw DbException(result.statuses);
        }
      }
    } else if (result is QueryResult) {
      if (result.hasErrors && result.type.isDeveloperError) {
        throw DbException([
          GeneralStatus(
            type: result.type,
            message: result.message,
          )
        ]);
      }
    } else if (result is SchemaUpdateResult) {
      if (result.hasValidationErrors) {
        final hasDev = result.validationStatuses.any((s) => s.isDeveloperError);
        if (hasDev) {
          throw DbException(result.validationStatuses);
        }
      }
    } else if (result is TransactionResult) {
      if (result.hasErrors) {
        final hasDev = result.statuses.any((s) => s.isDeveloperError);
        if (hasDev) {
          throw DbException(result.statuses);
        }
      }
    }
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
