import 'package:flutter/foundation.dart';

import '../core/data_store_impl.dart';
import '../query/query_condition.dart';

/// 链式构建器基类
abstract class ChainBuilder<SELF extends ChainBuilder<SELF>> {
  final DataStoreImpl _db;
  final String _tableName;
  final QueryCondition _condition = QueryCondition();

  ChainBuilder(this._db, this._tableName);

  /// 获取实际的构建器实例
  SELF get _self => this as SELF;

  /// 基础 where 条件
  SELF where(String field, String operator, dynamic value) {
    _condition.where(field, operator, value);
    return _self;
  }

  /// whereIn 条件
  SELF whereIn(String field, List values) {
    _condition.where(field, 'IN', values);
    return _self;
  }

  /// whereBetween 条件
  SELF whereBetween(String field, dynamic start, dynamic end) {
    _condition.where(field, 'BETWEEN', [start, end]);
    return _self;
  }

  /// whereNull 条件
  SELF whereNull(String field) {
    _condition.where(field, 'IS', null);
    return _self;
  }

  /// whereNotNull 条件
  SELF whereNotNull(String field) {
    _condition.where(field, 'IS NOT', null);
    return _self;
  }

  /// OR 条件
  SELF or() {
    _condition.or();
    return _self;
  }

  /// 获取条件构造器
  QueryCondition get condition => _condition;

  @protected
  DataStoreImpl get $db => _db;

  @protected
  String get $tableName => _tableName;
}
