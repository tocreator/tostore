import 'dart:async';

import '../core/data_store_impl.dart';
import '../core/workload_scheduler.dart';
import '../core/yield_controller.dart';
import '../handler/logger.dart';
import '../interface/future_builder_mixin.dart';
import '../model/db_exception.dart';
import '../model/db_result.dart';
import '../model/expr.dart';
import '../model/join_clause.dart';
import '../model/query_aggregation.dart';
import '../model/query_result.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/table_identity.dart';
import '../model/table_schema.dart';
import '../query/query_cache.dart';
import '../query/query_condition.dart';
import '../query/query_executor.dart';

part '../chain/delete_builder.dart';
part '../chain/query_builder.dart';
part '../chain/update_builder.dart';

/// Integer bitmask flags for query clauses to enable O(1) point query detection.
abstract final class QueryClauseMask {
  static const int joins = 1 << 0;
  static const int aggregations = 1 << 1;
  static const int groupBy = 1 << 2;
  static const int offset = 1 << 3;
  static const int cursor = 1 << 4;
  static const int selectedFields = 1 << 5;
  static const int distinct = 1 << 6;
  static const int having = 1 << 7;
  static const int orderBy = 1 << 8;
  static const int onlyCount = 1 << 9;
}

/// chain builder base class
abstract class ChainBuilder<SELF extends ChainBuilder<SELF>> {
  final DataStoreImpl _db;
  final String _tableName;
  QueryCondition? _condition;

  int _conditionCount = 0;
  String? _fastSingleEqField;
  dynamic _fastSingleEqVal;
  String? _singleOp;

  int _clauseFlags = 0;
  int get clauseFlags => _clauseFlags;

  List<String>? _orderBy;
  int? _limit;
  int? _offset;
  String? _cursor;

  ChainBuilder(this._db, this._tableName);

  /// get actual builder instance
  SELF get _self => this as SELF;

  /// hook called when query parameters change (e.g. limit, offset, orderBy, cursor)
  void _onChanged() {}

  void _ensureConditionTree() {
    if (_condition != null) return;
    _condition = QueryCondition();
    if (_fastSingleEqField != null) {
      _condition!
          .where(_fastSingleEqField!, _singleOp ?? '=', _fastSingleEqVal);
      _fastSingleEqField = null;
      _fastSingleEqVal = null;
      _singleOp = null;
    }
  }

  /// Fast check if this query condition is a single equality condition:
  ({String field, dynamic value})? extractSingleEquality() {
    if (_conditionCount == 1 &&
        _fastSingleEqField != null &&
        (_singleOp == null || _singleOp == '=' || _singleOp == '==')) {
      return (field: _fastSingleEqField!, value: _fastSingleEqVal);
    }
    if (_condition != null) {
      return _condition!.extractSingleEquality();
    }
    return null;
  }

  /// set order by (asc)
  SELF orderByAsc(String field) {
    _orderBy = _orderBy ?? [];
    _orderBy!.add(field);
    _clauseFlags |= QueryClauseMask.orderBy;
    _onChanged();
    return _self;
  }

  /// set order by (desc)
  SELF orderByDesc(String field) {
    _orderBy = _orderBy ?? [];
    _orderBy!.add('-$field');
    _clauseFlags |= QueryClauseMask.orderBy;
    _onChanged();
    return _self;
  }

  /// set limit
  SELF limit(int value) {
    _limit = value;
    _onChanged();
    return _self;
  }

  /// set offset
  SELF offset(int value) {
    _offset = value;
    _cursor = null;
    if (value > 0) {
      _clauseFlags |= QueryClauseMask.offset;
    } else {
      _clauseFlags &= ~QueryClauseMask.offset;
    }
    _clauseFlags &= ~QueryClauseMask.cursor;
    _onChanged();
    return _self;
  }

  /// set cursor
  SELF cursor(String? value) {
    _cursor = value;
    if (value != null && value.isNotEmpty) {
      _offset = null;
      _clauseFlags |= QueryClauseMask.cursor;
      _clauseFlags &= ~QueryClauseMask.offset;
    } else {
      _clauseFlags &= ~QueryClauseMask.cursor;
    }
    _onChanged();
    return _self;
  }

  /// base where condition
  SELF where(String field, String operator, dynamic value) {
    _conditionCount++;
    if (_conditionCount == 1 &&
        _condition == null &&
        (operator == '=' || operator == '==')) {
      _fastSingleEqField = field;
      _fastSingleEqVal = value;
      _singleOp = '=';
      return _self;
    }
    _ensureConditionTree();
    _condition!.where(field, operator, value);
    _onChanged();
    return _self;
  }

  /// whereIn condition
  SELF whereIn(String field, List values) {
    _conditionCount++;
    _ensureConditionTree();
    _condition!.where(field, 'IN', values);
    _onChanged();
    return _self;
  }

  /// whereBetween condition
  SELF whereBetween(String field, dynamic start, dynamic end) {
    _conditionCount++;
    _ensureConditionTree();
    _condition!.where(field, 'BETWEEN', [start, end]);
    _onChanged();
    return _self;
  }

  /// whereNull condition
  SELF whereNull(String field) {
    _conditionCount++;
    _ensureConditionTree();
    _condition!.where(field, 'IS', null);
    _onChanged();
    return _self;
  }

  /// whereNotNull condition
  SELF whereNotNull(String field) {
    _conditionCount++;
    _ensureConditionTree();
    _condition!.where(field, 'IS NOT', null);
    _onChanged();
    return _self;
  }

  /// OR condition
  SELF or() {
    _ensureConditionTree();
    _condition!.or();
    _onChanged();
    return _self;
  }

  /// Add a predefined condition to this query with AND logic
  SELF condition(QueryCondition condition) {
    _ensureConditionTree();
    _condition!.condition(condition);

    condition.$internalApplySettings(
        () => _orderBy,
        (orderBy) => _orderBy = orderBy,
        (v) => limit(v),
        (v) => offset(v),
        (v) => cursor(v));

    _onChanged();
    return _self;
  }

  /// orCondition condition - adds OR logic
  SELF orCondition(QueryCondition condition) {
    _ensureConditionTree();
    _condition!.orCondition(condition);

    condition.$internalApplySettings(
        () => _orderBy,
        (orderBy) => _orderBy = orderBy,
        (v) => limit(v),
        (v) => offset(v),
        (v) => cursor(v));

    _onChanged();
    return _self;
  }

  /// orWhere condition - adds OR logic
  SELF orWhere(String field, String operator, dynamic value) {
    _ensureConditionTree();
    _condition!.or().where(field, operator, value);
    _onChanged();
    return _self;
  }

  /// whereNotIn condition
  SELF whereNotIn(String field, List values) {
    _ensureConditionTree();
    _condition!.where(field, 'NOT IN', values);
    _onChanged();
    return _self;
  }

  /// whereLike condition
  SELF whereLike(String field, String pattern) {
    _ensureConditionTree();
    _condition!.where(field, 'LIKE', pattern);
    _onChanged();
    return _self;
  }

  /// whereNotLike condition
  SELF whereNotLike(String field, String pattern) {
    _ensureConditionTree();
    _condition!.where(field, 'NOT LIKE', pattern);
    _onChanged();
    return _self;
  }

  /// whereEqual condition
  SELF whereEqual(String field, dynamic value) {
    return where(field, '=', value);
  }

  /// whereNotEqual condition
  SELF whereNotEqual(String field, dynamic value) {
    _ensureConditionTree();
    _condition!.whereNotEqual(field, value);
    _onChanged();
    return _self;
  }

  /// whereGreaterThan condition
  SELF whereGreaterThan(String field, dynamic value) {
    _ensureConditionTree();
    _condition!.whereGreaterThan(field, value);
    _onChanged();
    return _self;
  }

  /// whereGreaterThanOrEqualTo condition
  SELF whereGreaterThanOrEqualTo(String field, dynamic value) {
    _ensureConditionTree();
    _condition!.whereGreaterThanOrEqualTo(field, value);
    _onChanged();
    return _self;
  }

  /// whereLessThan condition
  SELF whereLessThan(String field, dynamic value) {
    _ensureConditionTree();
    _condition!.whereLessThan(field, value);
    _onChanged();
    return _self;
  }

  /// whereLessThanOrEqualTo condition
  SELF whereLessThanOrEqualTo(String field, dynamic value) {
    _ensureConditionTree();
    _condition!.whereLessThanOrEqualTo(field, value);
    _onChanged();
    return _self;
  }

  /// whereContains condition
  SELF whereContains(String field, String value) {
    _ensureConditionTree();
    _condition!.whereContains(field, value);
    _onChanged();
    return _self;
  }

  /// whereNotContains condition
  SELF whereNotContains(String field, String value) {
    _ensureConditionTree();
    _condition!.whereNotContains(field, value);
    _onChanged();
    return _self;
  }

  /// whereStartsWith condition
  SELF whereStartsWith(String field, String prefix) {
    _ensureConditionTree();
    _condition!.whereStartsWith(field, prefix);
    _onChanged();
    return _self;
  }

  /// whereEndsWith condition
  SELF whereEndsWith(String field, String suffix) {
    _ensureConditionTree();
    _condition!.whereEndsWith(field, suffix);
    _onChanged();
    return _self;
  }

  /// whereContainsAny condition
  SELF whereContainsAny(String field, List values) {
    _ensureConditionTree();
    _condition!.whereContainsAny(field, values);
    _onChanged();
    return _self;
  }

  /// whereEmpty condition - matches null or empty string
  SELF whereEmpty(String field) {
    _ensureConditionTree();
    _condition!.whereEmpty(field);
    _onChanged();
    return _self;
  }

  /// whereNotEmpty condition - matches non-null and non-empty string
  SELF whereNotEmpty(String field) {
    _ensureConditionTree();
    _condition!.whereNotEmpty(field);
    _onChanged();
    return _self;
  }

  /// whereTrue condition - matches true
  SELF whereTrue(String field) {
    _ensureConditionTree();
    _condition!.whereTrue(field);
    _onChanged();
    return _self;
  }

  /// whereFalse condition - matches false
  SELF whereFalse(String field) {
    _ensureConditionTree();
    _condition!.whereFalse(field);
    _onChanged();
    return _self;
  }

  /// get condition builder
  QueryCondition get queryCondition {
    _ensureConditionTree();
    return _condition!;
  }
}
