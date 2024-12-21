import 'dart:async';

import 'chain_builder.dart';
import 'future_builder_mixin.dart';

/// delete builder
class DeleteBuilder extends ChainBuilder<DeleteBuilder>
    with FutureBuilderMixin<bool> {
  Future<bool>? _future;

  DeleteBuilder(super.db, super.tableName);

  @override
  Future<bool> get future {
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
