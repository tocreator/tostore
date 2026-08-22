import '../model/query_aggregation.dart';
import '../model/join_clause.dart';
import '../model/table_identity.dart';
import '../handler/value_matcher.dart';
import 'query_condition.dart';
import 'query_plan.dart';

/// Query result cache entry for Result Cache.
final class QueryResultCacheEntry {
  final List<Map<String, dynamic>> records;
  final String? nextCursor;
  final String? prevCursor;
  final bool hasMore;
  final bool hasPrev;
  final int? totalRecordCount;
  final int? count;
  final dynamic aggregateResult;
  final DateTime createdAt;
  final Duration? expiry;
  final int sizeBytes;

  QueryResultCacheEntry({
    required this.records,
    this.nextCursor,
    this.prevCursor,
    this.hasMore = false,
    this.hasPrev = false,
    this.totalRecordCount,
    this.count,
    this.aggregateResult,
    required this.createdAt,
    required this.expiry,
    required this.sizeBytes,
  });

  bool isExpired() {
    final e = expiry;
    if (e == null) return false;
    return DateTime.now().difference(createdAt) >= e;
  }
}

/// Execution route type for Plan Cache.
enum PlanRouteType {
  primaryKeyPoint,
  uniqueIndexPoint,
  indexRangeScan,
  tableScan,
  unionScan,
}

/// Compiled execution plan stored in Plan Cache.
///
/// Holds the pre-computed physical access route, selected index,
/// sorting strategy, and pre-compiled predicate evaluator.
///
/// Plan Cache is completely data-independent (DML does not invalidate it).
/// It is invalidated only when table schema or index structure changes.
class CompiledExecutionPlan {
  final PlanRouteType routeType;
  final TableUid tableUid;
  final String? singleEqualityField;
  final IndexUid? indexUid;
  final List<String> naturalOrderBy;
  final bool needPostSort;
  final QueryPlan? rawPlan;
  final dynamic cursorMode;
  final ConditionRecordMatcher? precompiledMatcher;

  const CompiledExecutionPlan({
    required this.routeType,
    required this.tableUid,
    this.singleEqualityField,
    this.indexUid,
    this.naturalOrderBy = const <String>[],
    this.needPostSort = false,
    this.rawPlan,
    this.cursorMode,
    this.precompiledMatcher,
  });
}

/// Helper to build parameter-agnostic shape strings from condition nodes.
abstract final class ConditionShapeBuilder {
  static String buildShape(ConditionNode node) {
    if (node.type == NodeType.leaf) {
      if (node.condition.isEmpty) return '';
      final entry = node.condition.entries.first;
      final k = entry.key;
      final v = entry.value;
      if (v is Map) {
        final op = v.keys.first.toString();
        return '$k:$op';
      }
      return '$k:=';
    }
    final childShapes = <String>[];
    for (final c in node.children) {
      final s = buildShape(c);
      if (s.isNotEmpty) childShapes.add(s);
    }
    if (childShapes.isEmpty) return '';
    childShapes.sort();
    final prefix = node.type == NodeType.or ? 'OR' : 'AND';
    return '$prefix(${childShapes.join(',')})';
  }
}

/// Query shape key for Plan Cache.
///
/// Represents the structure of a query without concrete literal parameters.
/// Queries with identical shape share the same compiled execution plan.
class QueryShapeKey {
  final TableUid tableUid;
  final String conditionShape;
  final String orderByShape;
  final bool hasLimit;
  final bool hasOffset;
  final bool hasCursor;
  final bool onlyCount;
  final String joinsShape;
  final String aggsShape;
  final String groupByShape;

  String? _cachedIdentity;
  int? _cachedHash;

  QueryShapeKey({
    required this.tableUid,
    required this.conditionShape,
    required this.orderByShape,
    required this.hasLimit,
    required this.hasOffset,
    required this.hasCursor,
    required this.onlyCount,
    required this.joinsShape,
    required this.aggsShape,
    required this.groupByShape,
  });

  factory QueryShapeKey.fromQuery({
    required TableUid tableUid,
    QueryCondition? condition,
    List<String>? orderBy,
    int? limit,
    int? offset,
    String? cursor,
    bool onlyCount = false,
    List<JoinClause>? joins,
    List<QueryAggregation>? aggregations,
    List<String>? groupBy,
  }) {
    final condShape = condition != null && !condition.isEmpty
        ? ConditionShapeBuilder.buildShape(condition.rootNode)
        : '';
    final orderShape =
        (orderBy != null && orderBy.isNotEmpty) ? orderBy.join(',') : '';
    final joinShape = (joins != null && joins.isNotEmpty)
        ? joins
            .map((j) =>
                '${j.type.name}:${j.table}:${j.firstKey}${j.operator}${j.secondKey}')
            .join('|')
        : '';
    final aggShape = (aggregations != null && aggregations.isNotEmpty)
        ? aggregations.map((a) => '${a.type.name}:${a.field}').join('|')
        : '';
    final grpShape =
        (groupBy != null && groupBy.isNotEmpty) ? groupBy.join(',') : '';

    return QueryShapeKey(
      tableUid: tableUid,
      conditionShape: condShape,
      orderByShape: orderShape,
      hasLimit: limit != null && limit > 0,
      hasOffset: offset != null && offset > 0,
      hasCursor: cursor != null && cursor.isNotEmpty,
      onlyCount: onlyCount,
      joinsShape: joinShape,
      aggsShape: aggShape,
      groupByShape: grpShape,
    );
  }

  String _identity() {
    if (_cachedIdentity != null) return _cachedIdentity!;
    return _cachedIdentity =
        '${tableUid.value}#$conditionShape#$orderByShape#$hasLimit#$hasOffset#$hasCursor#$onlyCount#$joinsShape#$aggsShape#$groupByShape';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is QueryShapeKey && _identity() == other._identity();
  }

  @override
  int get hashCode => _cachedHash ??= _identity().hashCode;

  @override
  String toString() => _identity();
}

/// Query cache key for Result Cache.
class QueryCacheKey {
  final TableUid tableUid;
  final QueryCondition condition;
  final List<String>? orderBy;
  final int? limit;
  final int? offset;
  final String? cursor;
  final List<JoinClause>? joins;
  final List<QueryAggregation>? aggregations;
  final List<String>? groupBy;
  final bool onlyCount;

  /// Cached identity string / hash.
  String? _cachedString;
  int? _cachedHash;

  QueryCacheKey({
    required this.tableUid,
    required this.condition,
    this.orderBy,
    this.limit,
    this.offset,
    this.cursor,
    this.joins,
    this.aggregations,
    this.groupBy,
    this.onlyCount = false,
  });

  @override
  String toString() => _identity();

  String _identity() {
    final cached = _cachedString;
    if (cached != null) return cached;

    final b = StringBuffer();
    _writeTagged(b, 't', tableUid.value);
    _writeDyn(b, 'c', condition.build());
    if (orderBy != null && orderBy!.isNotEmpty) {
      _writeStringList(b, 'o', orderBy!);
    }
    if (limit != null) {
      _writeTagged(b, 'l', limit!.toString());
    }
    if (offset != null) {
      _writeTagged(b, 'f', offset!.toString());
    }
    if (cursor != null && cursor!.isNotEmpty) {
      _writeTagged(b, 'r', cursor!);
    }
    if (onlyCount) {
      _writeTagged(b, 'k', '1');
    }
    if (aggregations != null && aggregations!.isNotEmpty) {
      b.write('a');
      b.write(aggregations!.length);
      b.write(';');
      for (final a in aggregations!) {
        _writeTagged(b, 'T', a.type.name);
        _writeTagged(b, 'F', a.field);
        if (a.alias != null) _writeTagged(b, 'A', a.alias!);
        b.write('|');
      }
    }
    if (groupBy != null && groupBy!.isNotEmpty) {
      _writeStringList(b, 'g', groupBy!);
    }
    if (joins != null && joins!.isNotEmpty) {
      b.write('j');
      b.write(joins!.length);
      b.write(';');
      for (final j in joins!) {
        _writeTagged(b, 'J', j.type.name);
        _writeTagged(b, 'U', j.table);
        _writeTagged(b, '1', j.firstKey);
        _writeTagged(b, 'P', j.operator);
        _writeTagged(b, '2', j.secondKey);
        b.write('|');
      }
    }

    return _cachedString = b.toString();
  }

  static void _writeTagged(StringBuffer b, String tag, String value) {
    b.write(tag);
    b.write(value.length);
    b.write(':');
    b.write(value);
    b.write(';');
  }

  static void _writeStringList(
      StringBuffer b, String tag, List<String> values) {
    b.write(tag);
    b.write(values.length);
    b.write(';');
    for (final v in values) {
      b.write(v.length);
      b.write(':');
      b.write(v);
      b.write(',');
    }
  }

  /// Deterministic encoding for [QueryCondition.build] maps / nested values.
  static void _writeDyn(StringBuffer b, String tag, dynamic value) {
    b.write(tag);
    _writeDynValue(b, value);
    b.write(';');
  }

  static void _writeDynValue(StringBuffer b, dynamic value) {
    if (value == null) {
      b.write('n');
      return;
    }
    if (value is bool) {
      b.write(value ? 't' : 'f');
      return;
    }
    if (value is int) {
      b.write('i');
      b.write(value);
      return;
    }
    if (value is double) {
      b.write('d');
      b.write(value);
      return;
    }
    if (value is String) {
      b.write('s');
      b.write(value.length);
      b.write(':');
      b.write(value);
      return;
    }
    if (value is List) {
      b.write('L');
      b.write(value.length);
      b.write('{');
      for (final e in value) {
        _writeDynValue(b, e);
        b.write(',');
      }
      b.write('}');
      return;
    }
    if (value is Map) {
      final keys = value.keys.map((k) => k.toString()).toList()..sort();
      b.write('M');
      b.write(keys.length);
      b.write('{');
      for (final k in keys) {
        b.write(k.length);
        b.write(':');
        b.write(k);
        b.write('=');
        _writeDynValue(b, value[k]);
        b.write(',');
      }
      b.write('}');
      return;
    }
    // Fallback: length-prefixed toString (rare non-JSON-friendly values).
    final s = value.toString();
    b.write('x');
    b.write(s.length);
    b.write(':');
    b.write(s);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is QueryCacheKey && _identity() == other._identity();
  }

  @override
  int get hashCode {
    final cached = _cachedHash;
    if (cached != null) return cached;
    return _cachedHash = _identity().hashCode;
  }
}
