/// Controls what `db.flush` persists and how strongly
/// (ToStore instance method).
///
/// 控制 `db.flush` 刷盘范围与强度（ToStore 实例方法）。
enum FlushMode {
  /// Fastest. Persist recovery log to OS buffers only.
  /// Survives app interrupt / crash restart; power loss may lose data.
  ///
  /// 最快，保障基础恢复能力：恢复日志仅写入 OS 缓存。
  /// 防应用中断、崩溃重启可恢复；注意断电会丢失数据。
  recovery,

  /// Slightly slower. Persist recovery log to stable storage when supported.
  /// Aims to survive power loss so startup can recover all committed data.
  ///
  /// 稍微耗时：恢复日志写入物理文件，防断电故障，
  /// 断电后能够在启动时恢复全部数据。
  recoveryPowerSafe,

  /// Strongest and most expensive. Persist recovery log, table data, and
  /// indexes to stable storage (includes durable sync for safe checkpoints).
  ///
  /// 比较耗时：恢复日志及数据（表数据与索引）全量写入物理文件。
  fullPowerSafe,
}
