import 'dart:convert';

import 'query_condition.dart';

/// query cache
class QueryCache {
  final int _maxSize;
  final Map<String, CachedQuery> _cache = {};
  Map<String, CachedQuery> get cache => _cache;

  QueryCache({
    int maxSize = 5000,
    Duration maxAge = const Duration(minutes: 10),
  }) : _maxSize = maxSize;

  /// get cache size
  int get size => _cache.length;

  /// get cached query results
  List<Map<String, dynamic>>? get(String key) {
    final cached = _cache[key];
    if (cached == null) return null;

    return cached.results;
  }

  /// cache query results
  void put(String key, List<Map<String, dynamic>> results, String tableName,
      String primaryKeyField) {
    if (_cache.length >= _maxSize) {
      // remove oldest cache
      final oldest = _cache.entries.reduce(
          (a, b) => a.value.timestamp.isBefore(b.value.timestamp) ? a : b);
      _cache.remove(oldest.key);
    }

    _cache[key] = CachedQuery(
      results: results,
      timestamp: DateTime.now(),
      tableName: tableName,
      primaryKeyField: primaryKeyField,
    );
  }

  /// invalidate cache
  void invalidate(String key) {
    _cache.remove(key);
  }

  /// clear all cache
  void clear() {
    _cache.clear();
  }
}

/// cached query
class CachedQuery {
  final List<Map<String, dynamic>> results;
  final DateTime timestamp;
  final String tableName;
  final String primaryKeyField;

  CachedQuery({
    required this.results,
    required this.timestamp,
    required this.tableName,
    required this.primaryKeyField,
  });
}

/// query cache key
class QueryCacheKey {
  final String tableName;
  final QueryCondition condition;
  final List<String>? orderBy;
  final int? limit;
  final int? offset;

  QueryCacheKey({
    required this.tableName,
    required this.condition,
    this.orderBy,
    this.limit,
    this.offset,
  });

  @override
  String toString() {
    return jsonEncode({
      'tableName': tableName,
      'condition': condition.build(),
      'orderBy': orderBy,
      'limit': limit,
      'offset': offset,
    });
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is QueryCacheKey &&
        other.tableName == tableName &&
        _conditionEquals(other.condition, condition) &&
        _listEquals(other.orderBy, orderBy) &&
        other.limit == limit &&
        other.offset == offset;
  }

  @override
  int get hashCode {
    return Object.hash(
      tableName,
      condition.build().toString(),
      orderBy?.join(','),
      limit,
      offset,
    );
  }

  bool _conditionEquals(QueryCondition a, QueryCondition b) {
    return a.build().toString() == b.build().toString();
  }

  bool _listEquals(List? a, List? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
