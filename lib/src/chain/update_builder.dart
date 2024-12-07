import 'dart:async';

import 'chain_builder.dart';
import 'future_builder_mixin.dart';

/// 更新构建器
class UpdateBuilder extends ChainBuilder<UpdateBuilder>
    with FutureBuilderMixin<bool> {
  final Map<String, dynamic> _data;
  Future<bool>? _future;

  UpdateBuilder(super.db, super.tableName, this._data);

  @override
  Future<bool> get future {
    _future ??= $db.updateInternal(
      $tableName,
      _data,
      condition,
    );
    return _future!;
  }
}
