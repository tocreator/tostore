import 'result_type.dart';

/// query result class
class QueryResult<T> {
  /// Whether the operation has any failures
  bool get hasErrors => type != ResultType.success;

  /// Whether the operation is successful
  /// Deprecated: Use type == ResultType.success or check failures.
  @Deprecated('Use type == ResultType.success instead')
  bool get isSuccess => type == ResultType.success;

  /// query result data
  final List<T> data;

  /// Retrieval and fusion scoring context, populated during vector/hybrid search.
  final RetrievalContext? retrieval;

  /// operation status type
  final ResultType type;

  /// operation message
  final String message;

  /// Cursor/keyset pagination: opaque token for the previous page.
  ///
  /// Prefer [prev] for in-process pagination. Use this token when transferring
  /// pagination state across processes or over the network.
  final String? prevCursorToken;

  /// Cursor/keyset pagination: opaque token for the next page.
  ///
  /// Prefer [next] for in-process pagination. Use this token when transferring
  /// pagination state across processes or over the network.
  /// Non-null only when cursor pagination is used and there are more results.
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

  /// Query execution time in milliseconds.
  final int? executionTimeMs;

  /// Callback executors to fetch the next or previous page seamlessly.
  /// These can automatically handle both cursor-based and offset-based pagination.
  final Future<QueryResult<T>> Function()? _nextPageExecutor;
  final Future<QueryResult<T>> Function()? _prevPageExecutor;

  /// Pure synchronous in-memory callback executors to fetch the next or previous page seamlessly.
  final QueryResult<T> Function()? _peekNextPageExecutor;
  final QueryResult<T> Function()? _peekPrevPageExecutor;

  QueryResult({
    required this.type,
    required this.data,
    this.retrieval,
    this.message = '',
    this.prevCursorToken,
    this.nextCursorToken,
    this.hasMore = false,
    this.hasPrev = false,
    this.executionTimeMs,
    Future<QueryResult<T>> Function()? nextPageExecutor,
    Future<QueryResult<T>> Function()? prevPageExecutor,
    QueryResult<T> Function()? peekNextPageExecutor,
    QueryResult<T> Function()? peekPrevPageExecutor,
  })  : _nextPageExecutor = nextPageExecutor,
        _prevPageExecutor = prevPageExecutor,
        _peekNextPageExecutor = peekNextPageExecutor,
        _peekPrevPageExecutor = peekPrevPageExecutor;

  /// Seamlessly fetch the next page.
  /// Automatically handles both cursor-based and offset-based pagination.
  /// Returns an empty QueryResult with code success if there are no more results,
  /// or a QueryResult with code error if pagination cannot be performed.
  Future<QueryResult<T>> next() async {
    final exec = _nextPageExecutor;
    if (!hasMore || exec == null) {
      return QueryResult.success(
        data: const [],
        retrieval: null,
        hasMore: false,
        hasPrev: hasPrev,
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
        retrieval: null,
        hasMore: hasMore,
        hasPrev: false,
        message: exec == null
            ? 'Pagination executor not initialized (e.g. deserialized from JSON).'
            : 'No previous results available.',
      );
    }
    return exec();
  }

  /// Synchronously fetch the next page from pure memory tier without async overhead.
  /// Automatically handles both cursor-based and offset-based pagination.
  QueryResult<T> peekNext() {
    final exec = _peekNextPageExecutor;
    if (!hasMore || exec == null) {
      return QueryResult.success(
        data: const [],
        retrieval: null,
        hasMore: false,
        hasPrev: hasPrev,
        message: exec == null
            ? 'Synchronous pagination executor not initialized.'
            : 'No more results available in memory.',
      );
    }
    return exec();
  }

  /// Synchronously fetch the previous page from pure memory tier without async overhead.
  /// Automatically handles both cursor-based and offset-based pagination.
  QueryResult<T> peekPrev() {
    final exec = _peekPrevPageExecutor;
    if (!hasPrev || exec == null) {
      return QueryResult.success(
        data: const [],
        retrieval: null,
        hasMore: hasMore,
        hasPrev: false,
        message: exec == null
            ? 'Synchronous pagination executor not initialized.'
            : 'No previous results available in memory.',
      );
    }
    return exec();
  }

  /// create a success result
  factory QueryResult.success({
    required List<T> data,
    RetrievalContext? retrieval,
    String message = '',
    String? prevCursor,
    String? nextCursor,
    String? prevCursorToken,
    String? nextCursorToken,
    bool hasMore = false,
    bool hasPrev = false,
    int? executionTimeMs,
    Future<QueryResult<T>> Function()? nextPageExecutor,
    Future<QueryResult<T>> Function()? prevPageExecutor,
    QueryResult<T> Function()? peekNextPageExecutor,
    QueryResult<T> Function()? peekPrevPageExecutor,
  }) {
    return QueryResult(
      data: data,
      retrieval: retrieval,
      type: ResultType.success,
      message: message.isNotEmpty ? message : ResultType.success.message,
      prevCursorToken: prevCursorToken ?? prevCursor,
      nextCursorToken: nextCursorToken ?? nextCursor,
      hasMore: hasMore,
      hasPrev: hasPrev,
      executionTimeMs: executionTimeMs,
      nextPageExecutor: nextPageExecutor,
      prevPageExecutor: prevPageExecutor,
      peekNextPageExecutor: peekNextPageExecutor,
      peekPrevPageExecutor: peekPrevPageExecutor,
    );
  }

  /// create an error result
  factory QueryResult.error({
    ResultType type = ResultType.engError,
    String message = '',
  }) {
    return QueryResult(
      data: [],
      retrieval: null,
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
    return 'QueryResult{code: ${type.code} (${type.codeKey}), message: $message, data: $data, retrieval: $retrieval, prevCursorToken: $prevCursorToken, nextCursorToken: $nextCursorToken, hasMore: $hasMore, hasPrev: $hasPrev, executionTimeMs: $executionTimeMs}';
  }

  /// for serialization
  Map<String, dynamic> toJson() {
    return {
      'code': type.code,
      'codeKey': type.codeKey,
      'message': message,
      'data': data is List<Map<String, dynamic>>
          ? data
          : null, // only serialize data when T is Map<String, dynamic>
      if (retrieval != null) 'retrieval': retrieval!.toJson(),
      if (prevCursorToken != null) 'prevCursor': prevCursorToken,
      if (nextCursorToken != null) 'nextCursor': nextCursorToken,
      'hasMore': hasMore,
      'hasPrev': hasPrev,
      if (executionTimeMs != null) 'executionTimeMs': executionTimeMs,
    };
  }

  /// create an instance from json
  static QueryResult<Map<String, dynamic>> fromJson(Map<String, dynamic> json) {
    final codeKey = json['codeKey'] as String?;
    final retrievalJson = json['retrieval'] as Map<String, dynamic>?;
    return QueryResult<Map<String, dynamic>>(
      type: codeKey != null
          ? ResultType.fromCodeKey(codeKey)
          : ResultType.fromCode(json['code'] as int? ?? 99001),
      message: json['message'] as String? ?? '',
      data: (json['data'] as List?)
              ?.map((e) => Map<String, dynamic>.from(e as Map))
              .toList() ??
          [],
      retrieval: retrievalJson != null
          ? RetrievalContext.fromJson(retrievalJson)
          : null,
      prevCursorToken: json['prevCursor'] as String?,
      nextCursorToken: json['nextCursor'] as String?,
      hasMore: json['hasMore'] == true,
      hasPrev: json['hasPrev'] == true,
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

/// Represents the retrieval channel / modality for candidate recall.
enum RetrievalChannel {
  /// Dense vector similarity search (NGH / HNSW / DiskANN etc.)
  vector,

  /// Lexical / Fulltext search (BM25 / Inverted Index / Token Match)
  text,

  /// Neural sparse retrieval (SPLADE / learned sparse representation)
  sparse,

  /// Knowledge graph / graph traversal retrieval
  graph,

  /// Structured / relational SQL-like filter (B+Tree, primary key, table scan)
  structured,

  /// Multi-channel hybrid fused result
  hybrid,
}

/// Strategy used to combine multi-channel retrieval results into a unified score.
enum RetrievalFusionMethod {
  /// Reciprocal Rank Fusion: score = sum(weight_i / (k + rank_i))
  rrf,

  /// Weighted normalized score linear combination: score = sum(weight_i * normalized_score_i)
  weightedScore,

  /// Pure single channel (no fusion needed)
  single,
}

/// Detailed retrieval context entry for a single result row.
class RetrievalEntry {
  /// Unified normalized fusion score in [0.0, 1.0] (higher = more relevant).
  final double score;

  /// The channel/modality that produced or primarily contributed to this match.
  final RetrievalChannel channel;

  /// Raw metric/score before fusion/normalization (e.g. raw cosine similarity, L2 distance, BM25 score).
  final double? rawScore;

  /// Optional extended channel metadata (e.g. distanceMetric, channelScores, matchedTerms).
  final Map<String, dynamic>? meta;

  const RetrievalEntry({
    required this.score,
    required this.channel,
    this.rawScore,
    this.meta,
  });

  Map<String, dynamic> toJson() => {
        'score': score,
        'channel': channel.name,
        if (rawScore != null) 'rawScore': rawScore,
        if (meta != null && meta!.isNotEmpty) 'meta': meta,
      };

  factory RetrievalEntry.fromJson(Map<String, dynamic> json) {
    return RetrievalEntry(
      score: (json['score'] as num?)?.toDouble() ?? 0.0,
      channel: RetrievalChannel.values.firstWhere(
        (c) => c.name == json['channel'],
        orElse: () => RetrievalChannel.vector,
      ),
      rawScore: (json['rawScore'] as num?)?.toDouble(),
      meta: json['meta'] as Map<String, dynamic>?,
    );
  }

  @override
  String toString() =>
      'RetrievalEntry(score: ${score.toStringAsFixed(4)}, channel: ${channel.name}, rawScore: $rawScore, meta: $meta)';
}

/// Retrieval context associated with a [QueryResult], providing scores and fusion diagnostics.
class RetrievalContext {
  /// Entries corresponding 1:1 to each row in [QueryResult.data].
  final List<RetrievalEntry> entries;

  /// The fusion strategy applied if multiple channels were queried.
  final RetrievalFusionMethod fusionMethod;

  /// Overall diagnostics / execution metrics (e.g. total candidates per channel, fusion latency).
  final Map<String, dynamic>? meta;

  const RetrievalContext({
    required this.entries,
    this.fusionMethod = RetrievalFusionMethod.single,
    this.meta,
  });

  Map<String, dynamic> toJson() => {
        'entries': entries.map((e) => e.toJson()).toList(),
        'fusionMethod': fusionMethod.name,
        if (meta != null && meta!.isNotEmpty) 'meta': meta,
      };

  factory RetrievalContext.fromJson(Map<String, dynamic> json) {
    final rawEntries = json['entries'] as List?;
    return RetrievalContext(
      entries: rawEntries != null
          ? rawEntries
              .map((e) =>
                  RetrievalEntry.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList()
          : const [],
      fusionMethod: RetrievalFusionMethod.values.firstWhere(
        (m) => m.name == json['fusionMethod'],
        orElse: () => RetrievalFusionMethod.single,
      ),
      meta: json['meta'] as Map<String, dynamic>?,
    );
  }
}
