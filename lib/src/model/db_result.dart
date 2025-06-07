import 'result_code.dart';

/// Database operation result model
/// Used to represent the result of database operations (insert, update, delete, etc.)
class DbResult {
  /// Result status code
  final ResultCode code;

  /// Result message
  final String message;

  /// List of successfully processed record keys
  final List<String> successKeys;

  /// List of failed record keys
  final List<String> failedKeys;

  /// Constructor
  DbResult({
    required this.code,
    required this.message,
    this.successKeys = const [],
    this.failedKeys = const [],
  });

  /// Whether the operation is successful
  bool get isSuccess => code == ResultCode.success;

  /// Create a success result
  static DbResult success({
    String? successKey,
    List<String>? successKeys,
    String message = 'Operation successful',
  }) {
    final keys = successKey != null ? [successKey] : successKeys ?? [];
    return DbResult(
      code: ResultCode.success,
      message: message,
      successKeys: keys,
      failedKeys: const [],
    );
  }

  /// Create an error result
  static DbResult error({
    required ResultCode code,
    required String message,
    List<String> failedKeys = const [],
  }) {
    return DbResult(
      code: code,
      message: message,
      failedKeys: failedKeys,
      successKeys: const [],
    );
  }

  /// Create a batch operation result
  static DbResult batch({
    required List<String> successKeys,
    List<String> failedKeys = const [],
    String? message,
  }) {
    final bool hasSuccess = successKeys.isNotEmpty;
    final bool hasFailed = failedKeys.isNotEmpty;
    
    // Determine the result code based on success and failure counts
    final ResultCode resultCode;
    
    if (!hasFailed && hasSuccess) {
      resultCode = ResultCode.success;
    } else if (hasSuccess && hasFailed) {
      resultCode = ResultCode.partialSuccess;
    } else {
      //  All failed
      resultCode = ResultCode.unknown;
    }
                                 
    return DbResult(
      code: resultCode,
      message: message ?? _getBatchMessage(successKeys.length, failedKeys.length),
      successKeys: successKeys,
      failedKeys: failedKeys,
    );
  }

  /// Get total number of records processed
  int get totalCount => successKeys.length + failedKeys.length;

  /// Get number of successful records
  int get successCount => successKeys.length;

  /// Get number of failed records
  int get failedCount => failedKeys.length;

  /// Whether it is a data constraint error
  bool get isConstraintError => code.isConstraintError;

  /// Whether it is a resource not found error
  bool get isNotFound => code == ResultCode.notFound;

  /// Whether it is a unique constraint violation
  bool get isUniqueViolation => code == ResultCode.uniqueViolation;

  /// Whether it is a primary key violation
  bool get isPrimaryKeyViolation => code == ResultCode.primaryKeyViolation;

  /// Whether the operation succeeded but no records were affected
  bool get isEmptySuccess => isSuccess && successKeys.isEmpty;

  /// Convert DbResult to a Map (for serialization)
  Map<String, dynamic> toJson() {
    return {
      'code': code.index,
      'message': message,
      'successKeys': successKeys,
      'failedKeys': failedKeys,
    };
  }
  
  /// Create a DbResult from a Map (for deserialization)
  static DbResult fromJson(Map<String, dynamic> json) {
    // Get the code as an index into ResultCode enum
    final codeIndex = json['code'] as int;
    final resultCode = ResultCode.values[codeIndex];
    
    // Extract message
    final message = json['message'] as String;
    
    // Extract success and failed keys
    final successKeys = _extractStringList(json['successKeys']);
    final failedKeys = _extractStringList(json['failedKeys']);
    
    return DbResult(
      code: resultCode,
      message: message,
      successKeys: successKeys,
      failedKeys: failedKeys,
    );
  }
  
  /// Helper method to extract a List<String> from JSON
  static List<String> _extractStringList(dynamic value) {
    if (value == null) {
      return const [];
    }
    
    if (value is List) {
      return value.map((item) => item.toString()).toList();
    }
    
    return const [];
  }
  
  /// Override toString for easy debugging
  @override
  String toString() {
    return 'DbResult{code: $code, message: $message, successCount: $successCount, failedCount: $failedCount}';
  }

  /// Get the default message of batch operation
  static String _getBatchMessage(int successCount, int failedCount) {
    if (failedCount == 0) {
      return 'All operations successful, total $successCount records';
    } else if (successCount == 0) {
      return 'All operations failed, total $failedCount records';
    } else {
      return 'Some operations successful, $successCount successful, $failedCount failed';
    }
  }
}
