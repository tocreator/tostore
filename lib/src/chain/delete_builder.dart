part of '../interface/chain_builder.dart';

/// delete builder
class DeleteBuilder extends ChainBuilder<DeleteBuilder>
    with FutureBuilderMixin<DbResult> {
  Future<DbResult>? _future;
  // add flag to indicate whether to allow delete without condition
  bool _allowAll = false;
  // Public API: large-scale must be opted in; also skips per-row result details
  bool _allowLargeScaleOperation = false;
  // Recovery durability override for this delete
  RecoveryDurability? _durability;

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

  /// Allows a large-scale data delete that would otherwise be rejected to prevent OOM.
  ///
  /// When the engine detects a large-scale data operation, it must be explicitly
  /// allowed via this method. The operation runs in background batches through the
  /// unified write scheduler and **blocks until completion** before returning.
  /// The result includes [DbResult.successCount] only -- success/failure primary
  /// keys and per-row status details are not returned.
  /// Not allowed inside a transaction (rejected via [DbResult] / rollback).
  /// If the process is interrupted unexpectedly, already-persisted changes are
  /// kept; the caller must retry to continue.
  ///
  /// 允许大规模数据删除（否则会因防 OOM 被拒绝）。
  /// 引擎判定为大规模数据操作时必须显式调用本方法。操作经统一写调度分批执行，
  /// **阻塞等待全部完成后才返回**；仅返回 [DbResult.successCount]，不返回成功/失败
  /// 主键列表与逐条状态。事务内不允许（拒绝并触发回滚）。
  /// 若执行期间意外中断，已落盘部分保留，需用户自行重试继续。
  DeleteBuilder allowLargeScaleOperation() {
    _allowLargeScaleOperation = true;
    _onChanged();
    return this;
  }

  /// Sets recovery-log durability for this delete operation.
  ///
  /// - [RecoveryDurability.async]: Enqueue only; brief crash loss until background drain to OS.
  /// - [RecoveryDurability.standard]: Sync recovery log to OS page cache (crash-safe, default).
  /// - [RecoveryDurability.durable]: Sync recovery log to physical media (power-safe).
  DeleteBuilder durability(RecoveryDurability durability) {
    _durability = durability;
    _onChanged();
    return this;
  }

  @override
  Future<DbResult> get future {
    if (_future != null) return _future!;
    final table = _db.getTableContextSync(_tableName);
    if (table != null) {
      final f = _db.deleteInternal(
        table,
        queryCondition,
        orderBy: _orderBy,
        limit: _limit,
        offset: _offset,
        allowAll: _allowAll,
        allowLargeScaleOperation: _allowLargeScaleOperation,
        returnResultDetails: !_allowLargeScaleOperation,
        durability: _durability,
      );
      return _future = f.then((result) {
        DbException.checkDeveloperError(result);
        return result;
      });
    }
    return _future = _executeFallback();
  }

  Future<DbResult> _executeFallback() async {
    final table = await _db.getTableContext(_tableName);
    final result = await _db.deleteInternal(
      table,
      queryCondition,
      orderBy: _orderBy,
      limit: _limit,
      offset: _offset,
      allowAll: _allowAll,
      allowLargeScaleOperation: _allowLargeScaleOperation,
      returnResultDetails: !_allowLargeScaleOperation,
      durability: _durability,
    );
    DbException.checkDeveloperError(result);
    return result;
  }
}
