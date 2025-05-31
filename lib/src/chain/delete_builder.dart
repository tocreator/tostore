import 'dart:async';

import '../Interface/chain_builder.dart';
import '../Interface/future_builder_mixin.dart';
import '../model/db_result.dart';

/// delete builder
class DeleteBuilder extends ChainBuilder<DeleteBuilder>
    with FutureBuilderMixin<DbResult> {
  Future<DbResult>? _future;

  DeleteBuilder(super.db, super.tableName);

  @override
  Future<DbResult> get future async {
    _future ??= $db.deleteInternal(
      $tableName,
      condition,
      orderBy: $orderBy,
      limit: $limit,
      offset: $offset,
    );
    return _future!;
  }
}
