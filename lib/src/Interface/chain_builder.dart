import 'dart:async';

import '../core/data_store_impl.dart';
import '../model/table_schema.dart';
import '../query/query_condition.dart';
import '../Interface/future_builder_mixin.dart';
import '../model/db_result.dart';
import '../model/expr.dart';
import '../model/result_type.dart';
import '../model/join_clause.dart';
import '../model/query_result.dart';
import '../query/query_cache.dart';
import '../query/query_executor.dart';

part '../chain/delete_builder.dart';
part '../chain/update_builder.dart';
part '../chain/upsert_builder.dart';
part '../chain/query_builder.dart';

/// chain builder base class
abstract class ChainBuilder<SELF extends ChainBuilder<SELF>> {
  final DataStoreImpl _db;
  final String _tableName;
  final QueryCondition _condition = QueryCondition();

  List<String>? _orderBy;
  int? _limit;
  int? _offset;
  String? _cursor;

  ChainBuilder(this._db, this._tableName);

  /// get actual builder instance
  SELF get _self => this as SELF;

  /// hook called when query parameters change (e.g. limit, offset, orderBy, cursor)
  void _onChanged() {}

  /// set order by (asc)
  SELF orderByAsc(String field) {
    _orderBy = _orderBy ?? [];
    _orderBy!.add(field);
    _onChanged();
    return _self;
  }

  /// set order by (desc)
  SELF orderByDesc(String field) {
    _orderBy = _orderBy ?? [];
    _orderBy!.add('-$field');
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
    if (value > 0) {
      _cursor = null;
    }
    _onChanged();
    return _self;
  }

  /// set cursor
  SELF cursor(String? value) {
    _cursor = value;
    if (value != null && value.isNotEmpty) {
      _offset = null;
    }
    _onChanged();
    return _self;
  }

  /// base where condition
  SELF where(String field, String operator, dynamic value) {
    _condition.where(field, operator, value);
    _onChanged();
    return _self;
  }

  /// whereIn condition
  SELF whereIn(String field, List values) {
    _condition.where(field, 'IN', values);
    _onChanged();
    return _self;
  }

  /// whereBetween condition
  SELF whereBetween(String field, dynamic start, dynamic end) {
    _condition.where(field, 'BETWEEN', [start, end]);
    _onChanged();
    return _self;
  }

  /// whereNull condition
  SELF whereNull(String field) {
    _condition.where(field, 'IS', null);
    _onChanged();
    return _self;
  }

  /// whereNotNull condition
  SELF whereNotNull(String field) {
    _condition.where(field, 'IS NOT', null);
    _onChanged();
    return _self;
  }

  /// OR condition
  SELF or() {
    _condition.or();
    _onChanged();
    return _self;
  }

  /// Add a predefined condition to this query with AND logic
  SELF condition(QueryCondition condition) {
    _condition.condition(condition);

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
    _condition.orCondition(condition);

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
    _condition.or().where(field, operator, value);
    _onChanged();
    return _self;
  }

  /// whereNotIn condition
  SELF whereNotIn(String field, List values) {
    _condition.where(field, 'NOT IN', values);
    _onChanged();
    return _self;
  }

  /// whereLike condition
  SELF whereLike(String field, String pattern) {
    _condition.where(field, 'LIKE', pattern);
    _onChanged();
    return _self;
  }

  /// whereNotLike condition
  SELF whereNotLike(String field, String pattern) {
    _condition.where(field, 'NOT LIKE', pattern);
    _onChanged();
    return _self;
  }

  /// whereEqual condition
  SELF whereEqual(String field, dynamic value) {
    _condition.whereEqual(field, value);
    _onChanged();
    return _self;
  }

  /// whereNotEqual condition
  SELF whereNotEqual(String field, dynamic value) {
    _condition.whereNotEqual(field, value);
    _onChanged();
    return _self;
  }

  /// whereGreaterThan condition
  SELF whereGreaterThan(String field, dynamic value) {
    _condition.whereGreaterThan(field, value);
    _onChanged();
    return _self;
  }

  /// whereGreaterThanOrEqualTo condition
  SELF whereGreaterThanOrEqualTo(String field, dynamic value) {
    _condition.whereGreaterThanOrEqualTo(field, value);
    _onChanged();
    return _self;
  }

  /// whereLessThan condition
  SELF whereLessThan(String field, dynamic value) {
    _condition.whereLessThan(field, value);
    _onChanged();
    return _self;
  }

  /// whereLessThanOrEqualTo condition
  SELF whereLessThanOrEqualTo(String field, dynamic value) {
    _condition.whereLessThanOrEqualTo(field, value);
    _onChanged();
    return _self;
  }

  /// whereContains condition
  SELF whereContains(String field, String value) {
    _condition.whereContains(field, value);
    _onChanged();
    return _self;
  }

  /// whereNotContains condition
  SELF whereNotContains(String field, String value) {
    _condition.whereNotContains(field, value);
    _onChanged();
    return _self;
  }

  /// Add a custom condition using a user-provided function
  SELF whereCustom(bool Function(Map<String, dynamic>) record) {
    _condition.whereCustom(record);
    _onChanged();
    return _self;
  }

  /// Add a custom condition using a user-provided function with OR logic
  SELF orWhereCustom(bool Function(Map<String, dynamic>) record) {
    _condition.orWhereCustom(record);
    _onChanged();
    return _self;
  }

  /// get condition builder
  QueryCondition get queryCondition => _condition;
}
