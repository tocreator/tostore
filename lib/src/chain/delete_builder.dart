import 'dart:async';

import 'chain_builder.dart';
import 'future_builder_mixin.dart';

/// 删除构建器
class DeleteBuilder extends ChainBuilder<DeleteBuilder>
    with FutureBuilderMixin<bool> {
  Future<bool>? _future;

  DeleteBuilder(super.db, super.tableName);

  @override
  Future<bool> get future {
    _future ??= $db.deleteInternal(
      $tableName,
      condition,
    );
    return _future!;
  }
}
