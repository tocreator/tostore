import 'dart:async';

import '../Interface/chain_builder.dart';
import '../Interface/future_builder_mixin.dart';
import '../model/db_result.dart';

/// update builder
class UpdateBuilder extends ChainBuilder<UpdateBuilder>
    with FutureBuilderMixin<DbResult> {
  final Map<String, dynamic> _data;
  Future<DbResult>? _future;
  // add flag to indicate whether to allow update without condition
  bool _allowAll = false;
  // add flag to indicate whether to continue on partial errors
  bool _continueOnPartialErrors = false;

  UpdateBuilder(super.db, super.tableName, this._data);

  /// allow update all records
  /// 
  /// this method explicitly indicates that the developer intentionally updates all records in the table.
  /// if there is no query condition and this method is not called, the update operation will be rejected to prevent accidental update.
  UpdateBuilder allowUpdateAll() {
    _allowAll = true;
    return this;
  }
  
  /// allow partial errors
  ///
  /// this method explicitly indicates that the operation should continue when some records fail.
  /// by default, the operation will stop and return an error if any record fails.
  UpdateBuilder allowPartialErrors() {
    _continueOnPartialErrors = true;
    return this;
  }

  @override
  Future<DbResult> get future async {
    _future ??= $db.updateInternal(
      $tableName,
      _data,
      condition,
      orderBy: $orderBy,
      limit: $limit,
      offset: $offset,
      allowAll: _allowAll,
      continueOnPartialErrors: _continueOnPartialErrors,
    );
    return _future!;
  }
}
