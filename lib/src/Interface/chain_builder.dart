import 'package:flutter/foundation.dart';

import '../core/data_store_impl.dart';
import '../query/query_condition.dart';

/// chain builder base class
abstract class ChainBuilder<SELF extends ChainBuilder<SELF>> {
  final DataStoreImpl _db;
  final String _tableName;
  final QueryCondition _condition = QueryCondition();

  ChainBuilder(this._db, this._tableName);

  /// get actual builder instance
  SELF get _self => this as SELF;

  /// set order by (asc)
  SELF orderByAsc(String field) {
    _condition.orderByAsc(field);
    return _self;
  }

  /// set order by (desc)
  SELF orderByDesc(String field) {
    _condition.orderByDesc(field);
    return _self;
  }

  /// set limit
  SELF limit(int value) {
    _condition.setLimit(value);
    return _self;
  }

  /// set offset
  SELF offset(int value) {
    _condition.setOffset(value);
    return _self;
  }

  /// base where condition
  SELF where(String field, String operator, dynamic value) {
    _condition.where(field, operator, value);
    return _self;
  }

  /// whereIn condition
  SELF whereIn(String field, List values) {
    _condition.where(field, 'IN', values);
    return _self;
  }

  /// whereBetween condition
  SELF whereBetween(String field, dynamic start, dynamic end) {
    _condition.where(field, 'BETWEEN', [start, end]);
    return _self;
  }

  /// whereNull condition
  SELF whereNull(String field) {
    _condition.where(field, 'IS', null);
    return _self;
  }

  /// whereNotNull condition
  SELF whereNotNull(String field) {
    _condition.where(field, 'IS NOT', null);
    return _self;
  }

  /// OR condition
  SELF or() {
    _condition.or();
    return _self;
  }

  /// Add a predefined condition to this query with AND logic
  SELF condition(QueryCondition condition) {
    _condition.condition(condition);
    return _self;
  }

  /// orCondition condition - adds OR logic
  SELF orCondition(QueryCondition condition) {
    _condition.orCondition(condition);
    return _self;
  }

  /// orWhere condition - adds OR logic
  SELF orWhere(String field, String operator, dynamic value) {
    _condition.or().where(field, operator, value);
    return _self;
  }

  /// whereNotIn condition
  SELF whereNotIn(String field, List values) {
    _condition.where(field, 'NOT IN', values);
    return _self;
  }

  /// whereLike condition
  SELF whereLike(String field, String pattern) {
    _condition.where(field, 'LIKE', pattern);
    return _self;
  }

  /// whereNotLike condition
  SELF whereNotLike(String field, String pattern) {
    _condition.where(field, 'NOT LIKE', pattern);
    return _self;
  }

  /// whereEqual condition
  SELF whereEqual(String field, dynamic value) {
    _condition.whereEqual(field, value);
    return _self;
  }

  /// whereNotEqual condition
  SELF whereNotEqual(String field, dynamic value) {
    _condition.whereNotEqual(field, value);
    return _self;
  }

  /// whereContains condition
  SELF whereContains(String field, String value) {
    _condition.whereContains(field, value);
    return _self;
  }

  /// whereNotContains condition
  SELF whereNotContains(String field, String value) {
    _condition.whereNotContains(field, value);
    return _self;
  }

  /// Add a custom condition using a user-provided function
  /// Example:
  /// whereCustom((record) => record['is_active'] == true)
  SELF whereCustom(bool Function(Map<String, dynamic>) record) {
    _condition.whereCustom(record);
    return _self;
  }

  /// Add a custom condition using a user-provided function with OR logic
  /// Example:
  /// orWhereCustom((record) => record['is_active'] == true)
  SELF orWhereCustom(bool Function(Map<String, dynamic>) record) {
    _condition.orWhereCustom(record);
    return _self;
  }

  /// get condition builder
  QueryCondition get queryCondition => _condition;

  @protected
  DataStoreImpl get $db => _db;

  @protected
  String get $tableName => _tableName;

  @protected
  List<String>? get $orderBy => _condition.orderBy;

  @protected
  int? get $limit => _condition.limit;

  @protected
  int? get $offset => _condition.offset;
}
