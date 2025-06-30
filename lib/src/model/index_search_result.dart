/// Represents the result of a search operation on an index.
///
/// This class encapsulates the pointers to records found, grouped by the
/// partition they reside in. It also provides crucial metadata for the query
/// executor, such as whether a fallback to a full table scan is necessary.
class IndexSearchResult {
  /// A map where the key is the partition ID and the value is a list of
  /// record pointers (as strings) found in that partition.
  /// This structure avoids extra traversals by pre-grouping results by partition,
  /// allowing for efficient, batched data retrieval.
  final Map<int, List<String>> pointersByPartition;

  /// A flag indicating whether the query executor should fall back to a full
  /// table scan. This is `true` if the index could not be used conclusively
  /// (e.g., it doesn't exist or an error occurred), ensuring data correctness
  /// at the cost of performance.
  final bool requiresTableScan;

  /// A flag indicating whether an index was successfully used to produce this result.
  /// This helps the query executor distinguish between a definitive "no results found"
  /// (when `indexWasUsed` is true and `pointersByPartition` is empty) and a situation
  /// where the index was not available (`indexWasUsed` is false).
  final bool indexWasUsed;

  /// Creates an instance of an index search result.
  IndexSearchResult({
    required this.pointersByPartition,
    this.requiresTableScan = false,
    this.indexWasUsed = true,
  });

  /// A factory for creating a result that mandates a table scan.
  /// This is used when an index is not available or its use is inconclusive.
  factory IndexSearchResult.tableScan() {
    return IndexSearchResult(
      pointersByPartition: {},
      requiresTableScan: true,
      indexWasUsed: false,
    );
  }

  /// A factory for creating an empty result when an index was used but no
  /// matching records were found.
  factory IndexSearchResult.empty() {
    return IndexSearchResult(
      pointersByPartition: {},
      requiresTableScan: false,
      indexWasUsed: true,
    );
  }

  /// Returns true if no pointers were found across any partitions.
  bool get isEmpty => pointersByPartition.values.every((list) => list.isEmpty);
} 