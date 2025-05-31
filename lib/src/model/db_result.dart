import 'result_code.dart';

/// database operation result model
/// used to represent the result of database insert, update, delete, etc.
class DbResult {
  /// whether the operation is successful
  final bool success;

  /// result status code
  final ResultCode code;

  /// result message
  final String message;

  /// list of primary keys of the records operated (primary keys of successful operations)
  final List<String> primaryKeys;

  /// list of primary keys of the records operated (primary keys of failed operations)
  final List<String> failedKeys;

  /// create database operation result
  DbResult({
    required this.success,
    this.code = ResultCode.success,
    this.message = '',
    this.primaryKeys = const [],
    this.failedKeys = const [],
  });

  /// get single primary key (suitable for single record operation)
  String? get primaryKey => primaryKeys.isNotEmpty ? primaryKeys.first : null;

  /// get total number of records processed
  int get totalCount => primaryKeys.length + failedKeys.length;

  /// get success rate
  double get successRate =>
      totalCount > 0 ? primaryKeys.length / totalCount : 0.0;

  /// whether it is a data constraint error
  bool get isConstraintError => code.isConstraintError;

  /// whether it is a resource not found error
  bool get isNotFound => code == ResultCode.notFound;

  /// whether it is a unique constraint violation
  bool get isUniqueViolation => code == ResultCode.uniqueViolation;

  /// whether it is a primary key violation
  bool get isPrimaryKeyViolation => code == ResultCode.primaryKeyViolation;

  /// get the value of the status code
  int get codeValue => code.code;

  /// create success result
  /// [primaryKey] single primary key value (optional)
  /// [primaryKeys] list of multiple primary key values (optional, mutually exclusive with primaryKey)
  /// [message] custom message (optional)
  /// [code] custom status code (default is success)
  factory DbResult.success({
    String? primaryKey,
    List<String>? primaryKeys,
    String message = '',
    ResultCode code = ResultCode.success,
  }) {
    return DbResult(
      success: true,
      primaryKeys: primaryKey != null ? [primaryKey] : (primaryKeys ?? []),
      code: code,
      message: message.isNotEmpty ? message : code.message,
    );
  }

  /// create error result
  /// [code] error status code
  /// [message] error message
  /// [primaryKeys] list of related primary keys (optional)
  /// [failedKeys] list of failed primary keys (optional)
  factory DbResult.error({
    required ResultCode code,
    String? message,
    List<String> primaryKeys = const [],
    List<String> failedKeys = const [],
  }) {
    return DbResult(
      success: false,
      primaryKeys: primaryKeys,
      failedKeys: failedKeys,
      code: code,
      message: message ?? code.message,
    );
  }

  /// create constraint violation result
  /// [constraintType] constraint type (unique constraint, primary key constraint, etc.)
  /// [message] error message (optional)
  /// [conflictValue] conflict value (optional)
  factory DbResult.constraintViolation({
    required ResultCode constraintType,
    String? message,
    String? conflictValue,
  }) {
    return DbResult(
      success: false,
      code: constraintType,
      message: message ?? constraintType.message,
      failedKeys: conflictValue != null ? [conflictValue] : [],
    );
  }

  /// create batch operation result
  /// [successKeys] list of successful primary keys
  /// [failedKeys] list of failed primary keys
  /// [message] custom message (optional)
  factory DbResult.batch({
    required List<String> successKeys,
    List<String> failedKeys = const [],
    String? message,
  }) {
    final bool isAllSuccess = failedKeys.isEmpty && successKeys.isNotEmpty;
    final bool isAllFailed = successKeys.isEmpty && failedKeys.isNotEmpty;

    ResultCode code;
    if (isAllSuccess) {
      code = ResultCode.success;
    } else if (isAllFailed) {
      code = ResultCode.dbError;
    } else {
      // partial success, partial failure
      code = ResultCode.partialSuccess;
    }

    return DbResult(
      success: successKeys.isNotEmpty,
      primaryKeys: successKeys,
      failedKeys: failedKeys,
      code: code,
      message:
          message ?? _getBatchMessage(successKeys.length, failedKeys.length),
    );
  }

  /// get the default message of batch operation
  static String _getBatchMessage(int successCount, int failedCount) {
    if (failedCount == 0) {
      return 'All operations successful, total $successCount records';
    } else if (successCount == 0) {
      return 'All operations failed, total $failedCount records';
    } else {
      return 'Some operations successful, $successCount successful, $failedCount failed';
    }
  }

  /// method for serialization
  Map<String, dynamic> toJson() {
    return {
      'success': success,
      'code': code.code,
      'message': message,
      'primaryKeys': primaryKeys,
      'failedKeys': failedKeys,
    };
  }

  /// create instance from JSON
  factory DbResult.fromJson(Map<String, dynamic> json) {
    return DbResult(
      success: json['success'] as bool,
      code: ResultCode.fromCode(json['code'] as int),
      message: json['message'] as String,
      primaryKeys: List<String>.from(json['primaryKeys'] ?? []),
      failedKeys: List<String>.from(json['failedKeys'] ?? []),
    );
  }
}
