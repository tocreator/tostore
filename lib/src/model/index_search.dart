/// Represents the result of a search operation on an index.
///
library;

import 'dart:typed_data';

class IndexSearchResult {
  /// Primary keys that match the index condition.
  final List<String> primaryKeys;

  /// The last scanned index key (raw bytes) returned by the underlying range scan.
  ///
  /// This can be used as a keyset cursor (`startAfterKey`) to continue scanning
  /// the same index range without re-reading already scanned entries.
  ///
  /// - For UNIQUE indexes, this is the encoded tuple of index fields.
  /// - For NON-UNIQUE indexes, this is the encoded tuple of index fields + primary key.
  ///
  /// Note: This key represents the last *scanned* entry in the index order, not
  /// necessarily the last returned record after applying higher-level predicates.
  final Uint8List? lastKey;

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
    required this.primaryKeys,
    this.lastKey,
    this.requiresTableScan = false,
    this.indexWasUsed = true,
  });

  /// A factory for creating a result that mandates a table scan.
  /// This is used when an index is not available or its use is inconclusive.
  factory IndexSearchResult.tableScan() {
    return IndexSearchResult(
      primaryKeys: const [],
      lastKey: null,
      requiresTableScan: true,
      indexWasUsed: false,
    );
  }

  /// A factory for creating an empty result when an index was used but no
  /// matching records were found.
  factory IndexSearchResult.empty() {
    return IndexSearchResult(
      primaryKeys: const [],
      lastKey: null,
      requiresTableScan: false,
      indexWasUsed: true,
    );
  }

  /// Returns true if no pointers were found across any partitions.
  bool get isEmpty => primaryKeys.isEmpty;
}

/// Represents a condition for a single index search.
/// This provides a type-safe way to define index queries instead of using raw maps.
class IndexCondition {
  /// The comparison operator (e.g., `=`, `>`, `<`).
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

  /// Creates a 'less than' condition (`<`).
  factory IndexCondition.lessThan(dynamic value) {
    return IndexCondition._('<', value);
  }

  /// Creates a 'less than or equal to' condition (`<=`).
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
    final opRaw = map.keys.first;
    final value = map.values.first;
    final opUpper = opRaw.toString().toUpperCase();

    if (opUpper == 'BETWEEN') {
      if (value is List && value.length == 2) {
        return IndexCondition._(opUpper, value[0], endValue: value[1]);
      }
      if (value is Map) {
        return IndexCondition._(opUpper, value['start'],
            endValue: value['end']);
      }
      throw ArgumentError(
          'For "BETWEEN" operator, value must be a List of two elements or a Map {start,end}.');
    }

    return IndexCondition._(opUpper, value);
  }
}
