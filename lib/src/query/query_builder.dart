import 'dart:async';
import '../chain/chain_builder.dart';
import '../chain/future_builder_mixin.dart';

/// 查询构建器
class QueryBuilder extends ChainBuilder<QueryBuilder>
    with FutureBuilderMixin<List<Map<String, dynamic>>> {
  List<String>? _orderBy;
  int? _limit;
  int? _offset;
  Future<List<Map<String, dynamic>>>? _future;

  QueryBuilder(super.db, super.tableName);

  void _invalidateFuture() {
    _future = null;
  }

  /// 设置排序(升序)
  QueryBuilder orderByAsc(String field) {
    _orderBy = _orderBy ?? [];
    _orderBy!.add(field);
    _invalidateFuture();
    return this;
  }

  /// 设置排序(降序)
  QueryBuilder orderByDesc(String field) {
    _orderBy = _orderBy ?? [];
    _orderBy!.add('-$field');
    _invalidateFuture();
    return this;
  }

  /// 设置限制
  QueryBuilder limit(int value) {
    _limit = value;
    _invalidateFuture();
    return this;
  }

  /// 设置偏移
  QueryBuilder offset(int value) {
    _offset = value;
    _invalidateFuture();
    return this;
  }

  /// 查询第一条
  Future<Map<String, dynamic>?> first() async {
    _limit = 1;
    _invalidateFuture();
    final results = await this;
    return results.isEmpty ? null : results.first;
  }

  /// 查询数量
  Future<int> count() async {
    final results = await this;
    return results.length;
  }

  @override
  Future<List<Map<String, dynamic>>> get future {
    _future ??= _executeQuery();
    return _future!;
  }

  /// 执行查询
  Future<List<Map<String, dynamic>>> _executeQuery() async {
    // 构建查询计划
    final queryPlan = await $db.getQueryOptimizer()?.optimize(
          $tableName,
          condition.build(),
          _orderBy,
        );

    if (queryPlan == null) {
      throw StateError('Query optimizer not initialized');
    }
    // 直接使用 QueryExecutor 执行查询
    final results = await $db.getQueryExecutor()?.execute(
              queryPlan,
              $tableName,
              condition: condition,
              orderBy: _orderBy,
              limit: _limit,
              offset: _offset,
            ) ??
        [];
    return results;
  }
}
