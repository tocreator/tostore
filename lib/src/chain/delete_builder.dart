import 'dart:async';

import '../Interface/chain_builder.dart';
import '../Interface/future_builder_mixin.dart';
import '../model/db_result.dart';

/// delete builder
class DeleteBuilder extends ChainBuilder<DeleteBuilder>
    with FutureBuilderMixin<DbResult> {
  Future<DbResult>? _future;
  // add flag to indicate whether to allow delete without condition
  bool _allowAll = false;

  DeleteBuilder(super.db, super.tableName);

  /// allow delete all records
  /// 
  /// this method explicitly indicates that the developer intentionally deletes all records in the table.
  /// if there is no query condition and this method is not called, the delete operation will be rejected to prevent accidental deletion.
  DeleteBuilder allowDeleteAll() {
    _allowAll = true;
    return this;
  }

  @override
  Future<DbResult> get future async {
    _future ??= $db.deleteInternal(
      $tableName,
      condition,
      orderBy: $orderBy,
      limit: $limit,
      offset: $offset,
      allowAll: _allowAll,
    );
    return _future!;
  }
}
