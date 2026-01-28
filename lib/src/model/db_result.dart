import 'result_type.dart';

/// Database operation result model
/// Used to represent the result of database operations (insert, update, delete, createTable, dropTable, etc.)
class DbResult {
  /// Result status type
  final ResultType type;

  /// Result message
  final String message;

  /// List of successfully processed items
  ///
  /// The content depends on the operation type:
  /// - For insert/update/delete operations: contains primary key values of successfully processed records
  /// - For createTables/dropTable operations: contains table names that were successfully processed
  /// - For other operations: contains operation-specific identifiers
  final List<String> successKeys;

  /// List of failed items
  ///
  /// The content depends on the operation type:
  /// - For insert/update/delete operations: contains primary key values of failed records
  /// - For createTables/dropTable operations: contains table names that failed to process
  /// - For other operations: contains operation-specific identifiers
  final List<String> failedKeys;

  /// Constructor
  DbResult({
    required this.type,
    required this.message,
    this.successKeys = const [],
    this.failedKeys = const [],
  });

  /// Get the status code value
  int get code => type.code;

  /// Whether the operation is successful
  bool get isSuccess => type == ResultType.success;

  /// Whether the operation is partially successful
  /// (some items succeeded, some failed - typically used in batch operations)
  bool get isPartialSuccess => type == ResultType.partialSuccess;

  /// Create a success result
  static DbResult success({
    String? successKey,
    List<String>? successKeys,
    String message = 'Operation successful',
  }) {
    final keys = successKey != null ? [successKey] : successKeys ?? [];
    return DbResult(
      type: ResultType.success,
      message: message,
      successKeys: keys,
      failedKeys: const [],
    );
  }

  /// Create an error result
  static DbResult error({
    required ResultType type,
    required String message,
    List<String> failedKeys = const [],
  }) {
    return DbResult(
      type: type,
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

    // Determine the result type based on success and failure counts
    final ResultType resultType;

    if (!hasFailed && hasSuccess) {
      resultType = ResultType.success;
    } else if (hasSuccess && hasFailed) {
      resultType = ResultType.partialSuccess;
    } else {
      //  All failed
      resultType = ResultType.unknown;
    }

    return DbResult(
      type: resultType,
      message:
          message ?? _getBatchMessage(successKeys.length, failedKeys.length),
      successKeys: successKeys,
      failedKeys: failedKeys,
    );
  }

  /// Get total number of items processed
  /// (records for insert/update/delete, tables for createTables/dropTable, etc.)
  int get totalCount => successKeys.length + failedKeys.length;

  /// Get number of successful items
  /// (records for insert/update/delete, tables for createTables/dropTable, etc.)
  int get successCount => successKeys.length;

  /// Get number of failed items
  /// (records for insert/update/delete, tables for createTables/dropTable, etc.)
  int get failedCount => failedKeys.length;

  /// Whether it is a resource not found error
  bool get isNotFound => type == ResultType.notFound;

  /// Whether the operation succeeded but no items were affected
  /// (no records for insert/update/delete, no tables for createTables/dropTable, etc.)
  bool get isEmptySuccess => isSuccess && successKeys.isEmpty;

  /// Convert DbResult to a Map (for serialization)
  Map<String, dynamic> toJson() {
    return {
      'code': type.code,
      'message': message,
      'successKeys': successKeys,
      'failedKeys': failedKeys,
    };
  }

  /// Create a DbResult from a Map (for deserialization)
  static DbResult fromJson(Map<String, dynamic> json) {
    // Get the numeric code and convert to ResultType
    final int codeValue = json['code'] as int;
    final resultType = ResultType.fromCode(codeValue);

    // Extract message
    final message = json['message'] as String;

    // Extract success and failed keys
    final successKeys = _extractStringList(json['successKeys']);
    final failedKeys = _extractStringList(json['failedKeys']);

    return DbResult(
      type: resultType,
      message: message,
      successKeys: successKeys,
      failedKeys: failedKeys,
    );
  }

  /// Helper method to extract a List from JSON
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
      return 'All operations successful, total $successCount items';
    } else if (successCount == 0) {
      return 'All operations failed, total $failedCount items';
    } else {
      return 'Some operations successful, $successCount successful, $failedCount failed';
    }
  }
}
