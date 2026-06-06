import 'result_type.dart';
import 'result_status.dart';

/// Database operation result model
/// Used to represent the result of database operations (insert, update, delete, createTable, dropTable, etc.)
class DbResult {
  /// Grand list of diagnostic statuses
  final List<ResultStatus> statuses;

  /// Whether the operation has any failures
  final bool hasFailed;

  /// Optional arbitrary data payload (e.g. for returning modified rows or records)
  final dynamic data;

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

  /// Total number of successful items
  final int successCount;

  /// Total number of failed items
  final int failedCount;

  /// Constructor
  DbResult({
    required this.statuses,
    this.successKeys = const [],
    this.failedKeys = const [],
    int? successCount,
    int? failedCount,
    bool? hasFailed,
    this.data,
  })  : successCount = successCount ?? successKeys.length,
        failedCount = failedCount ?? failedKeys.length,
        hasFailed = hasFailed ??
            ((failedCount ?? failedKeys.length) > 0 ||
                statuses.any((s) => s.type != ResultType.success));

  /// Get total number of items processed
  int get totalCount => successCount + failedCount;

  /// Combined human-readable message from statuses.
  ///
  /// Optimized to return the single message directly in O(1) for single-item operations,
  /// and caps the concatenation to a maximum of 3 items for batch operations to prevent memory/CPU overhead.
  String get message {
    if (statuses.isEmpty) return 'Operation successful';
    if (statuses.length == 1) return statuses.first.message;

    final buffer = StringBuffer();
    final limit = statuses.length > 3 ? 3 : statuses.length;
    for (int i = 0; i < limit; i++) {
      if (i > 0) buffer.write('; ');
      buffer.write(statuses[i].message);
    }
    if (statuses.length > 3) {
      buffer.write('; ... and ${statuses.length - 3} more');
    }
    return buffer.toString();
  }

  /// The primary or first diagnostic type of the operation.
  ///
  /// - For single-item operations, it returns the exact operation result type in O(1).
  /// - For batch operations, if any items fail ([hasFailed] is true), it returns the first
  ///   encountered error type (or [ResultType.dbError] if details are missing) instead of success.
  ResultType get firstType {
    if (statuses.isEmpty) {
      return hasFailed ? ResultType.dbError : ResultType.success;
    }
    if (statuses.length == 1) return statuses.first.type;

    if (hasFailed) {
      for (final s in statuses) {
        if (s.type != ResultType.success) {
          return s.type;
        }
      }
      return ResultType.dbError;
    }
    return ResultType.success;
  }

  /// Grand status type of the operation.
  ///
  /// Deprecated: Use [firstType] to clarify that it only represents the first status type
  /// in batch operations, or use `!hasFailed` to check for general success.
  @Deprecated('Use firstType or !hasFailed instead')
  ResultType get type => firstType;

  /// The first status in [statuses], or null if empty.
  /// Extremely useful for single-item operations to avoid parsing the [statuses] list.
  ResultStatus? get firstStatus => statuses.isNotEmpty ? statuses.first : null;

  /// Whether the operation is successful.
  ///
  /// Migration: use `!hasFailed` instead to properly handle partial success scenarios.
  @Deprecated(
      'Use !hasFailed instead to properly handle partial success scenarios')
  bool get isSuccess => !hasFailed;

  /// Create a success result
  static DbResult success({
    String? successKey,
    List<String>? successKeys,
    String message = 'Operation successful',
    dynamic data,
  }) {
    final keys = successKey != null ? [successKey] : successKeys ?? [];
    return DbResult(
      statuses: [
        for (int i = 0; i < keys.length; i++)
          SuccessStatus(
            message: message,
            index: i,
            primaryKey: keys[i],
          )
      ],
      successKeys: keys,
      successCount: keys.length,
      failedCount: 0,
      hasFailed: false,
      data: data,
    );
  }

  /// Create an error result
  static DbResult error({
    required ResultType type,
    required String message,
    List<String> failedKeys = const [],
    List<ResultStatus>? statuses,
  }) {
    final effectiveStatuses = statuses ??
        [
          if (failedKeys.isEmpty)
            GeneralStatus(type: type, message: message)
          else
            for (int i = 0; i < failedKeys.length; i++)
              GeneralStatus(
                type: type,
                message: '$message (Key: ${failedKeys[i]})',
                index: i,
                primaryKey: failedKeys[i],
              )
        ];
    return DbResult(
      statuses: effectiveStatuses,
      failedKeys: failedKeys,
      successCount: 0,
      failedCount:
          failedKeys.isNotEmpty ? failedKeys.length : effectiveStatuses.length,
      hasFailed: true,
    );
  }

  /// Create a batch operation result
  static DbResult batch({
    List<ResultStatus>? statuses,
    List<String> successKeys = const [],
    List<String> failedKeys = const [],
    int? successCount,
    int? failedCount,
    bool? hasFailed,
    String? message,
    dynamic data,
  }) {
    final effectiveStatuses = statuses ??
        [
          for (int i = 0; i < successKeys.length; i++)
            SuccessStatus(
              message: message ?? 'Item successful',
              index: i,
              primaryKey: successKeys[i],
            ),
          for (int i = 0; i < failedKeys.length; i++)
            GeneralStatus(
              type: ResultType.dbError,
              message: message ?? 'Item failed',
              index: successKeys.length + i,
              primaryKey: failedKeys[i],
            ),
        ];
    return DbResult(
      statuses: effectiveStatuses,
      successKeys: successKeys,
      failedKeys: failedKeys,
      successCount: successCount ?? successKeys.length,
      failedCount: failedCount ?? failedKeys.length,
      hasFailed: hasFailed,
      data: data,
    );
  }

  /// Convert DbResult to a Map (for serialization)
  Map<String, dynamic> toJson() {
    return {
      'hasFailed': hasFailed,
      'successCount': successCount,
      'failedCount': failedCount,
      if (data != null) 'data': data,
      'statuses': statuses.map((e) => e.toJson()).toList(),
    };
  }

  /// Create a DbResult from a Map (for deserialization)
  static DbResult fromJson(Map<String, dynamic> json) {
    final statusList = (json['statuses'] as List? ?? [])
        .map((e) => ResultStatus.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();

    final data = json['data'];

    final successKeys = <String>[];
    final failedKeys = <String>[];

    for (final status in statusList) {
      final key = status.primaryKey;
      if (key != null) {
        if (status.type == ResultType.success) {
          successKeys.add(key);
        } else {
          failedKeys.add(key);
        }
      }
    }

    final successCount = json['successCount'] as int? ?? successKeys.length;
    final failedCount = json['failedCount'] as int? ?? failedKeys.length;
    final hasFailed = json['hasFailed'] as bool?;

    return DbResult(
      statuses: statusList,
      successKeys: successKeys,
      failedKeys: failedKeys,
      successCount: successCount,
      failedCount: failedCount,
      hasFailed: hasFailed,
      data: data,
    );
  }

  /// Override toString for easy debugging
  @override
  String toString() {
    final buffer = StringBuffer();
    buffer.write(
        'DbResult{hasFailed: $hasFailed, successCount: $successCount, failedCount: $failedCount');
    if (hasFailed && statuses.isNotEmpty) {
      final errorStatuses =
          statuses.where((s) => s.type != ResultType.success).toList();
      if (errorStatuses.isNotEmpty) {
        buffer.write(', errors: [');
        final showCount = errorStatuses.length > 3 ? 3 : errorStatuses.length;
        for (int i = 0; i < showCount; i++) {
          final err = errorStatuses[i];
          if (i > 0) buffer.write(', ');
          buffer.write('${err.type.name}: ${err.message}');
        }
        if (errorStatuses.length > 3) {
          buffer.write(', ... and ${errorStatuses.length - 3} more errors');
        }
        buffer.write(']');
      }
    }
    buffer.write(', statusesCount: ${statuses.length}}');
    return buffer.toString();
  }
}
