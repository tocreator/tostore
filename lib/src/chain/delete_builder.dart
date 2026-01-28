part of '../Interface/chain_builder.dart';

/// delete builder
class DeleteBuilder extends ChainBuilder<DeleteBuilder>
    with FutureBuilderMixin<DbResult> {
  Future<DbResult>? _future;
  // add flag to indicate whether to allow delete without condition
  bool _allowAll = false;

  DeleteBuilder(DataStoreImpl db, String tableName) : super(db, tableName);

  @override
  void _onChanged() {
    _future = null;
  }

  /// allow delete all records
  ///
  /// this method explicitly indicates that the developer intentionally deletes all records in the table.
  /// if there is no query condition and this method is not called, the delete operation will be rejected to prevent accidental deletion.
  DeleteBuilder allowDeleteAll() {
    _allowAll = true;
    _onChanged();
    return this;
  }

  @override
  Future<DbResult> get future async {
    _future ??= _db.deleteInternal(
      _tableName,
      queryCondition,
      orderBy: _orderBy,
      limit: _limit,
      offset: _offset,
      allowAll: _allowAll,
    );
    return _future!;
  }
}
