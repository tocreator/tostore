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


/// Represents a condition for a single index search.
/// This provides a type-safe way to define index queries instead of using raw maps.
class IndexCondition {
  /// The comparison operator (e.g., '=', '>', '<').
  final String operator;

  /// The value to compare against. For range queries, this is the start value.
  final dynamic value;

  /// The end value for range queries (e.g., 'between'). Null for other queries.
  final dynamic endValue;

  /// Private constructor. Use the factory methods to create instances.
  IndexCondition._(this.operator, this.value, {this.endValue});

  /// Creates an equality condition ('=').
  factory IndexCondition.equals(dynamic value) {
    return IndexCondition._('=', value);
  }

  /// Creates a 'greater than' condition ('>').
  factory IndexCondition.greaterThan(dynamic value) {
    return IndexCondition._('>', value);
  }

  /// Creates a 'greater than or equal to' condition ('>=').
  factory IndexCondition.greaterThanOrEqual(dynamic value) {
    return IndexCondition._('>=', value);
  }

  /// Creates a 'less than' condition ('<').
  factory IndexCondition.lessThan(dynamic value) {
    return IndexCondition._('<', value);
  }

  /// Creates a 'less than or equal to' condition ('<=').
  factory IndexCondition.lessThanOrEqual(dynamic value) {
    return IndexCondition._('<=', value);
  }

  /// Creates a 'between' condition.
  factory IndexCondition.between(dynamic startValue, dynamic endValue) {
    return IndexCondition._('between', startValue, endValue: endValue);
  }

  /// Creates a 'like' condition.
  factory IndexCondition.like(String pattern) {
    return IndexCondition._('like', pattern);
  }

  /// Creates a condition from a map, for backward compatibility or flexibility.
  /// It's recommended to use the specific factory constructors for new code.
  factory IndexCondition.fromMap(Map<String, dynamic> map) {
    if (map.isEmpty) {
      throw ArgumentError('Condition map cannot be empty.');
    }
    final op = map.keys.first;
    final value = map.values.first;

    if (op == 'between') {
      if (value is List && value.length == 2) {
        return IndexCondition._(op, value[0], endValue: value[1]);
      } else {
        throw ArgumentError(
            'For "between" operator, value must be a List of two elements.');
      }
    }
    return IndexCondition._(op, value);
  }
}
