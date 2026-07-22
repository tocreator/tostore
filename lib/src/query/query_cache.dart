import '../model/query_aggregation.dart';
import '../model/join_clause.dart';
import '../model/table_identity.dart';
import 'query_condition.dart';

/// query cache key
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
