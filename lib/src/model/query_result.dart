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
  final String? prevCursorToken;

  /// Cursor/keyset pagination: opaque token for the next page.
  /// - Non-null only when cursor pagination is used and there are more results.
  final String? nextCursorToken;

  /// Legacy getter for backward compatibility.
  @Deprecated('Use nextCursorToken instead')
  String? get nextCursor => nextCursorToken;

  /// Legacy getter for backward compatibility.
  @Deprecated('Use prevCursorToken instead')
  String? get prevCursor => prevCursorToken;

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

  /// Callback executors to fetch the next or previous page seamlessly.
  /// These can automatically handle both cursor-based and offset-based pagination.
  final Future<QueryResult<T>> Function()? _nextPageExecutor;
  final Future<QueryResult<T>> Function()? _prevPageExecutor;

  QueryResult({
    required this.type,
    required this.data,
    this.message = '',
    this.prevCursorToken,
    this.nextCursorToken,
    this.hasMore = false,
    this.hasPrev = false,
    this.tableTotalCount,
    this.executionTimeMs,
    Future<QueryResult<T>> Function()? nextPageExecutor,
    Future<QueryResult<T>> Function()? prevPageExecutor,
  })  : _nextPageExecutor = nextPageExecutor,
        _prevPageExecutor = prevPageExecutor;

  /// Get the status code value
  int get code => type.code;

  /// Seamlessly fetch the next page.
  /// Automatically handles both cursor-based and offset-based pagination.
  /// Returns an empty QueryResult with code success if there are no more results,
  /// or a QueryResult with code error if pagination cannot be performed.
  Future<QueryResult<T>> next() async {
    final exec = _nextPageExecutor;
    if (!hasMore || exec == null) {
      return QueryResult.success(
        data: const [],
        hasMore: false,
        hasPrev: hasPrev,
        tableTotalCount: tableTotalCount,
        message: exec == null
            ? 'Pagination executor not initialized (e.g. deserialized from JSON).'
            : 'No more results available.',
      );
    }
    return exec();
  }

  /// Seamlessly fetch the previous page.
  /// Automatically handles both cursor-based and offset-based pagination.
  /// Returns an empty QueryResult with code success if there are no previous results
  /// or if pagination cannot be performed.
  Future<QueryResult<T>> prev() async {
    final exec = _prevPageExecutor;
    if (!hasPrev || exec == null) {
      return QueryResult.success(
        data: const [],
        hasMore: hasMore,
        hasPrev: false,
        tableTotalCount: tableTotalCount,
        message: exec == null
            ? 'Pagination executor not initialized (e.g. deserialized from JSON).'
            : 'No previous results available.',
      );
    }
    return exec();
  }

  /// create a success result
  factory QueryResult.success({
    required List<T> data,
    String message = '',
    String? prevCursor,
    String? nextCursor,
    String? prevCursorToken,
    String? nextCursorToken,
    bool hasMore = false,
    bool hasPrev = false,
    int? tableTotalCount,
    int? executionTimeMs,
    Future<QueryResult<T>> Function()? nextPageExecutor,
    Future<QueryResult<T>> Function()? prevPageExecutor,
  }) {
    return QueryResult(
      data: data,
      type: ResultType.success,
      message: message.isNotEmpty ? message : ResultType.success.message,
      prevCursorToken: prevCursorToken ?? prevCursor,
      nextCursorToken: nextCursorToken ?? nextCursor,
      hasMore: hasMore,
      hasPrev: hasPrev,
      tableTotalCount: tableTotalCount,
      executionTimeMs: executionTimeMs,
      nextPageExecutor: nextPageExecutor,
      prevPageExecutor: prevPageExecutor,
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
    return 'QueryResult{code: $code, message: $message, data: $data, prevCursorToken: $prevCursorToken, nextCursorToken: $nextCursorToken, hasMore: $hasMore, hasPrev: $hasPrev, tableTotalCount: $tableTotalCount}';
  }

  /// for serialization
  Map<String, dynamic> toJson() {
    return {
      'code': type.code,
      'message': message,
      'data': data is List<Map<String, dynamic>>
          ? data
          : null, // only serialize data when T is Map<String, dynamic>
      if (prevCursorToken != null) 'prevCursor': prevCursorToken,
      if (nextCursorToken != null) 'nextCursor': nextCursorToken,
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
              ?.map((e) => Map<String, dynamic>.from(e as Map))
              .toList() ??
          [],
      prevCursorToken: json['prevCursor'] as String?,
      nextCursorToken: json['nextCursor'] as String?,
      hasMore: json['hasMore'] == true,
      hasPrev: json['hasPrev'] == true,
      tableTotalCount: json['tableTotalCount'] as int?,
      executionTimeMs: json['executionTimeMs'] as int?,
    );
  }
}

/// Result of a vector similarity search, returned to the user.
class VectorSearchResult {
  /// Primary key of the matching record.
  final String primaryKey;

  /// Distance from the query vector (lower = more similar for L2/cosine).
  final double distance;

  /// Similarity score normalised to [0, 1] (higher = more similar).
  final double score;

  VectorSearchResult({
    required this.primaryKey,
    required this.distance,
    required this.score,
  });

  Map<String, dynamic> toJson() => {
        'primaryKey': primaryKey,
        'distance': distance,
        'score': score,
      };
}
