import 'result_type.dart';

/// query result class
class QueryResult<T> {
  /// Whether the operation is successful
  bool get isSuccess => type == ResultType.success;

  /// query result data
  final List<T> data;

  /// operation status type
  final ResultType type;

  /// operation message
  final String message;

  /// Cursor/keyset pagination: opaque token for the previous page.
  final String? prevCursor;

  /// Cursor/keyset pagination: opaque token for the next page.
  /// - Non-null only when cursor pagination is used and there are more results.
  final String? nextCursor;

  /// Whether there are more results beyond the current page.
  ///
  /// This works even when cursor pagination is not supported (e.g. join/non-indexed orderBy),
  /// as the engine will fetch one extra record to detect more pages.
  final bool hasMore;

  /// Whether there are results before the current page.
  ///
  /// For offset pagination, this is `true` when offset > 0.
  /// For cursor pagination, this is derived from cursor presence and scan direction.
  final bool hasPrev;

  /// Estimated total number of records in the entire table (buffer-aware).
  final int? tableTotalCount;

  /// Query execution time in milliseconds.
  final int? executionTimeMs;

  QueryResult({
    required this.type,
    required this.data,
    this.message = '',
    this.prevCursor,
    this.nextCursor,
    this.hasMore = false,
    this.hasPrev = false,
    this.tableTotalCount,
    this.executionTimeMs,
  });

  /// Get the status code value
  int get code => type.code;

  /// create a success result
  factory QueryResult.success({
    required List<T> data,
    String message = '',
    String? prevCursor,
    String? nextCursor,
    bool hasMore = false,
    bool hasPrev = false,
    int? tableTotalCount,
    int? executionTimeMs,
  }) {
    return QueryResult(
      data: data,
      type: ResultType.success,
      message: message.isNotEmpty ? message : ResultType.success.message,
      prevCursor: prevCursor,
      nextCursor: nextCursor,
      hasMore: hasMore,
      hasPrev: hasPrev,
      tableTotalCount: tableTotalCount,
      executionTimeMs: executionTimeMs,
    );
  }

  /// create an error result
  factory QueryResult.error({
    ResultType type = ResultType.unknown,
    String message = '',
  }) {
    return QueryResult(
      data: [],
      type: type,
      message: message.isNotEmpty ? message : type.message,
    );
  }

  /// get the length of data
  int get length => data.length;

  /// whether there is data
  bool get isEmpty => data.isEmpty;

  /// whether there is data
  bool get isNotEmpty => data.isNotEmpty;

  /// Override toString for easy debugging
  @override
  String toString() {
    return 'QueryResult{code: $code, message: $message, data: $data, prevCursor: $prevCursor, nextCursor: $nextCursor, hasMore: $hasMore, hasPrev: $hasPrev, tableTotalCount: $tableTotalCount}';
  }

  /// for serialization
  Map<String, dynamic> toJson() {
    return {
      'code': type.code,
      'message': message,
      'data': data is List<Map<String, dynamic>>
          ? data
          : null, // only serialize data when T is Map<String, dynamic>
      if (prevCursor != null) 'prevCursor': prevCursor,
      if (nextCursor != null) 'nextCursor': nextCursor,
      'hasMore': hasMore,
      'hasPrev': hasPrev,
      if (tableTotalCount != null) 'tableTotalCount': tableTotalCount,
      if (executionTimeMs != null) 'executionTimeMs': executionTimeMs,
    };
  }

  /// create an instance from json
  static QueryResult<Map<String, dynamic>> fromJson(Map<String, dynamic> json) {
    return QueryResult<Map<String, dynamic>>(
      type: ResultType.fromCode(json['code'] as int),
      message: json['message'] as String? ?? '',
      data: (json['data'] as List?)
              ?.map((e) => Map<String, dynamic>.from(e as Map<String, dynamic>))
              .toList() ??
          [],
      prevCursor: json['prevCursor'] as String?,
      nextCursor: json['nextCursor'] as String?,
      hasMore: json['hasMore'] == true,
      hasPrev: json['hasPrev'] == true,
      tableTotalCount: json['tableTotalCount'] as int?,
      executionTimeMs: json['executionTimeMs'] as int?,
    );
  }
}
