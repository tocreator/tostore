import 'dart:async';
import '../chain/chain_builder.dart';
import '../chain/future_builder_mixin.dart';

/// query builder
class QueryBuilder extends ChainBuilder<QueryBuilder>
    with FutureBuilderMixin<List<Map<String, dynamic>>> {
  Future<List<Map<String, dynamic>>>? _future;

  QueryBuilder(super.db, super.tableName);

  void _invalidateFuture() {
    _future = null;
  }

  /// get first record
  Future<Map<String, dynamic>?> first() async {
    limit(1);
    _invalidateFuture();
    final results = await this;
    return results.isEmpty ? null : results.first;
  }

  /// get record count
  Future<int> count() async {
    final results = await this;
    return results.length;
  }

  @override
  Future<List<Map<String, dynamic>>> get future {
    _future ??= _executeQuery();
    return _future!;
  }

  /// execute query
  Future<List<Map<String, dynamic>>> _executeQuery() async {
    // build query plan
    final queryPlan = await $db.getQueryOptimizer()?.optimize(
          $tableName,
          condition.build(),
          $orderBy,
        );

    if (queryPlan == null) {
      throw StateError('Query optimizer not initialized');
    }
    // directly use QueryExecutor to execute query
    final results = await $db.getQueryExecutor()?.execute(
              queryPlan,
              $tableName,
              condition: condition,
              orderBy: $orderBy,
              limit: $limit,
              offset: $offset,
            ) ??
        [];
    return results;
  }
}
