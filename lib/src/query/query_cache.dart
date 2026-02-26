import 'dart:convert';
import '../model/query_aggregation.dart';
import '../model/join_clause.dart';
import 'query_condition.dart';

/// query cache key
class QueryCacheKey {
  final String tableName;
  final QueryCondition condition;
  final List<String>? orderBy;
  final int? limit;
  final int? offset;
  final String? cursor;
  final List<JoinClause>? joins;
  final List<QueryAggregation>? aggregations;
  final List<String>? groupBy;

  /// Cache the result of toString to avoid repeated calculation
  String? _cachedString;

  QueryCacheKey({
    required this.tableName,
    required this.condition,
    this.orderBy,
    this.limit,
    this.offset,
    this.cursor,
    this.joins,
    this.aggregations,
    this.groupBy,
  });

  @override
  String toString() {
    // Use cached results to avoid repeated calculations
    if (_cachedString != null) {
      return _cachedString!;
    }

    try {
      // Uniformly generate cache keys for easier comparison and lookup
      final Map<String, dynamic> keyData = {
        'tableName': tableName,
        'condition': condition.build(),
      };

      // Only add non-empty values to reduce complexity
      if (orderBy != null && orderBy!.isNotEmpty) keyData['orderBy'] = orderBy;
      if (limit != null) keyData['limit'] = limit;
      if (offset != null) keyData['offset'] = offset;
      if (cursor != null && cursor!.isNotEmpty) keyData['cursor'] = cursor;
      if (aggregations != null && aggregations!.isNotEmpty) {
        keyData['aggregations'] = aggregations!
            .map((a) =>
                {'type': a.type.toString(), 'field': a.field, 'alias': a.alias})
            .toList();
      }
      if (groupBy != null && groupBy!.isNotEmpty) {
        keyData['groupBy'] = groupBy;
      }

      if (joins != null && joins!.isNotEmpty) {
        keyData['joins'] = joins!
            .map((j) => {
                  'type': j.type.toString().split('.').last,
                  'table': j.table,
                  'firstKey': j.firstKey,
                  'operator': j.operator,
                  'secondKey': j.secondKey,
                })
            .toList();
      }

      // Use JSON to generate cache keys to ensure consistency
      _cachedString = jsonEncode(keyData);
      return _cachedString!;
    } catch (e) {
      // Final fallback option, ensure cache key can always be generated
      final fallbackKey =
          '$tableName-${condition.build()}-${DateTime.now().millisecondsSinceEpoch}';
      return fallbackKey;
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    // Use toString for comparison to ensure consistency
    // Because the toString() method already contains all key properties
    if (other is QueryCacheKey) {
      return toString() == other.toString();
    }
    return false;
  }

  @override
  int get hashCode {
    // Use consistent JSON structure to calculate hash values, ensure equivalent objects have the same hash
    final Map<String, dynamic> keyData = {
      'tableName': tableName,
      'condition': condition.build().toString(),
    };

    if (orderBy != null && orderBy!.isNotEmpty) keyData['orderBy'] = orderBy;
    if (limit != null) keyData['limit'] = limit;
    if (offset != null) keyData['offset'] = offset;
    if (cursor != null && cursor!.isNotEmpty) keyData['cursor'] = cursor;
    if (aggregations != null && aggregations!.isNotEmpty) {
      keyData['aggregations'] = aggregations!
          .map((a) =>
              {'type': a.type.toString(), 'field': a.field, 'alias': a.alias})
          .toList();
    }
    if (groupBy != null && groupBy!.isNotEmpty) {
      keyData['groupBy'] = groupBy;
    }

    if (joins != null && joins!.isNotEmpty) {
      keyData['joins'] = joins!
          .map((j) => {
                'type': j.type.toString(),
                'table': j.table,
                'firstKey': j.firstKey,
                'operator': j.operator,
                'secondKey': j.secondKey,
              })
          .toList();
    }

    return keyData.toString().hashCode;
  }
}
