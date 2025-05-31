import 'package:flutter/foundation.dart';

import '../core/data_store_impl.dart';
import '../query/query_condition.dart';
import '../handler/logger.dart';

// List of valid operators for validation
const List<String> _validOperators = [
  '=',
  '!=',
  '<>',
  '>',
  '>=',
  '<',
  '<=',
  'IN',
  'NOT IN',
  'BETWEEN',
  'LIKE',
  'IS',
  'IS NOT'
];

/// chain builder base class
abstract class ChainBuilder<SELF extends ChainBuilder<SELF>> {
  final DataStoreImpl _db;
  final String _tableName;
  final QueryCondition _condition = QueryCondition();

  // Track operators that have already been warned about
  static final Set<String> _warnedInvalidOperators = {};

  List<String>? _orderBy;
  int? _limit;
  int? _offset;

  ChainBuilder(this._db, this._tableName);

  /// get actual builder instance
  SELF get _self => this as SELF;

  /// set order by (asc)
  SELF orderByAsc(String field) {
    _orderBy = _orderBy ?? [];
    _orderBy!.add(field);
    return _self;
  }

  /// set order by (desc)
  SELF orderByDesc(String field) {
    _orderBy = _orderBy ?? [];
    _orderBy!.add('-$field');
    return _self;
  }

  /// set limit
  SELF limit(int value) {
    _limit = value;
    return _self;
  }

  /// set offset
  SELF offset(int value) {
    _offset = value;
    return _self;
  }

  /// base where condition
  SELF where(String field, String operator, dynamic value) {
    // Validate the operator before passing to the query condition
    if (!_validOperators.contains(operator.toUpperCase())) {
      // Only warn about each invalid operator once
      if (!_warnedInvalidOperators.contains(operator)) {
        Logger.error(
            'Invalid operator: "$operator". Valid operators are: ${_validOperators.join(', ')}',
            label: 'ChainBuilder.where');
        _warnedInvalidOperators.add(operator);
      }
      // Use equals as a safe fallback
      operator = '=';
    }
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

  /// get condition builder
  QueryCondition get condition => _condition;

  @protected
  DataStoreImpl get $db => _db;

  @protected
  String get $tableName => _tableName;

  @protected
  List<String>? get $orderBy => _orderBy;

  @protected
  int? get $limit => _limit;

  @protected
  int? get $offset => _offset;
}
