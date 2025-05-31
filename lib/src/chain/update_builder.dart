import 'dart:async';

import '../Interface/chain_builder.dart';
import '../Interface/future_builder_mixin.dart';
import '../model/db_result.dart';

/// update builder
class UpdateBuilder extends ChainBuilder<UpdateBuilder>
    with FutureBuilderMixin<DbResult> {
  final Map<String, dynamic> _data;
  Future<DbResult>? _future;

  UpdateBuilder(super.db, super.tableName, this._data);

  @override
  Future<DbResult> get future async {
    _future ??= $db.updateInternal(
      $tableName,
      _data,
      condition,
      orderBy: $orderBy,
      limit: $limit,
      offset: $offset,
    );
    return _future!;
  }
}
