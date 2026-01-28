import '../query/query_condition.dart';

/// Represents a subscription to a specific query
class QuerySubscription {
  final String id;
  final QueryCondition condition;
  final Function(dynamic) callback; // Callback to notify

  QuerySubscription({
    required this.id,
    required this.condition,
    required this.callback,
  });
}

/// Inverted Index for efficient query matching
///
/// Instead of iterating through every query to see if a record matches,
/// we index queries by the fields they care about.
class QueryIndex {
  // Map<FieldName, Map<Value, List<Subscription>>>
  // Used for equality checks: field == value
  final Map<String, Map<dynamic, List<QuerySubscription>>> _equalityIndex = {};

  // Map<FieldName, List<Subscription>>
  // Used for range, like, and other complex checks where we can't hash the value
  final Map<String, List<QuerySubscription>> _complexIndex = {};

  // Queries with no conditions (watch all)
  final List<QuerySubscription> _globalSubscriptions = [];

  void add(QuerySubscription subscription) {
    final conditionMap = subscription.condition.build();

    if (conditionMap.isEmpty) {
      _globalSubscriptions.add(subscription);
      return;
    }

    if (!_tryIndex(conditionMap, subscription)) {
      _globalSubscriptions.add(subscription);
    }
  }

  bool _tryIndex(Map<String, dynamic> map, QuerySubscription sub) {
    if (map.containsKey('AND')) {
      // For AND, we only need to index ONE of the children.
      // We prefer equality.
      final children = map['AND'] as List;

      // Try to find equality in children
      for (var child in children) {
        if (_tryIndexEquality(child as Map<String, dynamic>, sub)) return true;
      }

      // If no equality, try complex
      for (var child in children) {
        if (_tryIndexComplex(child as Map<String, dynamic>, sub)) return true;
      }

      // If we can't index any child (e.g. all are custom or nested weirdly), fail
      return false;
    }

    if (map.containsKey('OR')) {
      // For OR, we must index ALL children.
      // If any child fails to index, we fail the whole OR (fallback to global).
      final children = map['OR'] as List;
      for (var child in children) {
        if (!_tryIndex(child as Map<String, dynamic>, sub)) return false;
      }
      return true;
    }

    // Leaf
    if (_tryIndexEquality(map, sub)) return true;
    if (_tryIndexComplex(map, sub)) return true;

    return false;
  }

  bool _tryIndexEquality(Map<String, dynamic> map, QuerySubscription sub) {
    // Check if map is {field: {'=': val}}
    if (map.length != 1) return false;
    final key = map.keys.first;
    if (key == 'AND' || key == 'OR') return false;

    final value = map[key];
    if (value is Map && value.containsKey('=')) {
      _addToEqualityIndex(key, value['='], sub);
      return true;
    }
    return false;
  }

  bool _tryIndexComplex(Map<String, dynamic> map, QuerySubscription sub) {
    if (map.length != 1) return false;
    final key = map.keys.first;
    if (key == 'AND' || key == 'OR') return false;

    // It's a field condition
    _addToComplexIndex(key, sub);
    return true;
  }

  void remove(QuerySubscription subscription) {
    // Remove from all indexes. Since we don't track where we put it, we have to search.
    // Optimization: Store the index location in the subscription or a separate map.
    // For now, brute force remove is acceptable as unsubscription is less frequent than matching.

    _globalSubscriptions.remove(subscription);

    for (var fieldMap in _equalityIndex.values) {
      for (var list in fieldMap.values) {
        list.remove(subscription);
      }
    }

    for (var list in _complexIndex.values) {
      list.remove(subscription);
    }
  }

  /// Find all subscriptions that *might* match this record.
  /// Returns a Set to avoid duplicates.
  Set<QuerySubscription> getCandidates(Map<String, dynamic> record) {
    final candidates = <QuerySubscription>{};

    // 1. Always include global subscriptions
    candidates.addAll(_globalSubscriptions);

    // 2. Check equality index for each field in the record
    record.forEach((field, value) {
      if (_equalityIndex.containsKey(field)) {
        final valueMap = _equalityIndex[field]!;
        if (valueMap.containsKey(value)) {
          candidates.addAll(valueMap[value]!);
        }
      }

      // 3. Check complex index for this field
      if (_complexIndex.containsKey(field)) {
        candidates.addAll(_complexIndex[field]!);
      }
    });

    return candidates;
  }

  void _addToEqualityIndex(String field, dynamic value, QuerySubscription sub) {
    if (!_equalityIndex.containsKey(field)) {
      _equalityIndex[field] = {};
    }
    if (!_equalityIndex[field]!.containsKey(value)) {
      _equalityIndex[field]![value] = [];
    }
    _equalityIndex[field]![value]!.add(sub);
  }

  void _addToComplexIndex(String field, QuerySubscription sub) {
    if (!_complexIndex.containsKey(field)) {
      _complexIndex[field] = [];
    }
    _complexIndex[field]!.add(sub);
  }
}
