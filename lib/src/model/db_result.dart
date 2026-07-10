import 'result_status.dart';
import 'result_type.dart';

/// Database operation result model
/// Used to represent the result of database operations (insert, update, delete, createTable, dropTable, etc.)
class DbResult {
  /// Grand list of diagnostic statuses
  final List<ResultStatus> statuses;

  /// Whether the operation has any failures
  final bool hasErrors;

  /// Total number of successful items
  final int successCount;

  /// Total number of failed items
  final int failedCount;

  /// Constructor
  DbResult({
    required this.statuses,
    int? successCount,
    int? failedCount,
    bool? hasErrors,
    List<String>? successKeys,
    List<String>? failedKeys,
  })  : successCount =
            successCount ?? successKeys?.length ?? _countSuccess(statuses),
        failedCount =
            failedCount ?? failedKeys?.length ?? _countFailed(statuses),
        hasErrors = hasErrors ??
            ((failedCount ?? failedKeys?.length ?? 0) > 0 ||
                statuses.any((s) => s.type != ResultType.success));

  static int _countSuccess(List<ResultStatus> list) =>
      list.isEmpty ? 0 : list.where((s) => s.type == ResultType.success).length;

  static int _countFailed(List<ResultStatus> list) =>
      list.isEmpty ? 0 : list.where((s) => s.type != ResultType.success).length;

  /// List of successfully processed item primary keys.
  ///
  /// Deprecated: Use [statuses] instead for comprehensive diagnostics and exact order-matching,
  /// or use [firstPrimaryKey] instead for single-item operations.
  @Deprecated('Use statuses or firstPrimaryKey instead')
  List<String> get successKeys {
    if (statuses.isEmpty) return const [];
    return statuses
        .where((s) => s.type == ResultType.success && s.primaryKey != null)
        .map((s) => s.primaryKey!)
        .toList();
  }

  /// List of failed item primary keys.
  ///
  /// Deprecated: Use [statuses] instead for comprehensive diagnostics and exact order-matching,
  @Deprecated('Use statuses or firstPrimaryKey instead')
  List<String> get failedKeys {
    if (statuses.isEmpty) return const [];
    return statuses
        .where((s) => s.type != ResultType.success && s.primaryKey != null)
        .map((s) => s.primaryKey!)
        .toList();
  }

  /// The primary key of the first status in [statuses], or null if empty.
  /// Extremely convenient for single-item operations (e.g. insert, update, delete) to avoid parsing the list.
  String? get firstPrimaryKey =>
      statuses.isNotEmpty ? statuses.first.primaryKey : null;

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
  /// - For batch operations, if any items fail ([hasErrors] is true), it returns the first
  ///   encountered error type (or [ResultType.dbError] if details are missing) instead of success.
  ResultType get firstType {
    if (statuses.isEmpty) {
      return hasErrors ? ResultType.engError : ResultType.success;
    }
    if (statuses.length == 1) return statuses.first.type;

    if (hasErrors) {
      for (final s in statuses) {
        if (s.type != ResultType.success) {
          return s.type;
        }
      }
      return ResultType.engError;
    }
    return ResultType.success;
  }

  /// Grand status type of the operation.
  ///
  /// Deprecated: Use [firstType] to clarify that it only represents the first status type
  /// in batch operations, or use `!hasErrors` to check for general success.
  @Deprecated('Use firstType or !hasErrors instead')
  ResultType get type => firstType;

  /// The first status in [statuses], or null if empty.
  /// Extremely useful for single-item operations to avoid parsing the [statuses] list.
  ResultStatus? get firstStatus => statuses.isNotEmpty ? statuses.first : null;

  /// Whether the operation is successful.
  ///
  /// Migration: use `!hasErrors` instead to properly handle partial success scenarios.
  @Deprecated(
      'Use !hasErrors instead to properly handle partial success scenarios')
  bool get isSuccess => !hasErrors;

  /// Create a success result
  static DbResult success({
    String? successKey,
    List<String>? successKeys,
    String message = 'Operation successful',
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
      hasErrors: false,
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
      hasErrors: true,
    );
  }

  /// Create a batch operation result
  static DbResult batch({
    List<ResultStatus>? statuses,
    List<String> successKeys = const [],
    List<String> failedKeys = const [],
    int? successCount,
    int? failedCount,
    bool? hasErrors,
    String? message,
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
              type: ResultType.engError,
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
      hasErrors: hasErrors,
    );
  }

  /// Convert DbResult to a Map (for serialization)
  Map<String, dynamic> toJson() {
    return {
      'hasErrors': hasErrors,
      'successCount': successCount,
      'failedCount': failedCount,
      'statuses': statuses.map((e) => e.toJson()).toList(),
    };
  }

  /// Create a DbResult from a Map (for deserialization)
  static DbResult fromJson(Map<String, dynamic> json) {
    final statusList = (json['statuses'] as List? ?? [])
        .map((e) => ResultStatus.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();

    final successCount = json['successCount'] as int? ?? 0;
    final failedCount = json['failedCount'] as int? ?? 0;
    final hasErrors = json['hasErrors'] as bool?;

    return DbResult(
      statuses: statusList,
      successCount: successCount,
      failedCount: failedCount,
      hasErrors: hasErrors,
    );
  }

  /// Override toString for easy debugging
  @override
  String toString() {
    final buffer = StringBuffer();
    buffer.write(
        'DbResult{hasErrors: $hasErrors, successCount: $successCount, failedCount: $failedCount');
    if (hasErrors && statuses.isNotEmpty) {
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
