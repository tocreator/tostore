part of '../Interface/chain_builder.dart';

/// delete builder
class DeleteBuilder extends ChainBuilder<DeleteBuilder>
    with FutureBuilderMixin<DbResult> {
  Future<DbResult>? _future;
  // add flag to indicate whether to allow delete without condition
  bool _allowAll = false;
  // add flag to indicate whether to skip result details
  bool _skipResultDetails = false;

  DeleteBuilder(super.db, super.tableName);

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

  /// Skips collecting success/failure primary key lists and status details in the returned result.
  /// Use this when performing large-scale range-based deletes (e.g. `.where('id', '>', 5)`)
  /// to improve performance and avoid memory overhead.
  /// When skipped, only [DbResult.successCount] and [DbResult.failedCount] are available.
  ///
  /// 跳过收集成功/失败的主键列表和状态详情。
  /// 适用于大范围范围查询的批量删除场景（如 `.where('id', '>', 5)`），
  /// 能够显著提升性能并避免内存开销。
  /// 跳过后仅 [DbResult.successCount] 和 [DbResult.failedCount] 可用。
  DeleteBuilder skipResultDetails() {
    _skipResultDetails = true;
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
      returnResultDetails: !_skipResultDetails,
    );
    final result = await _future!;
    DbException.checkDeveloperError(result);
    return result;
  }
}
