import '../handler/logger.dart';

/// 全局日志配置
class LogConfig {
  /// 是否启用日志
  static bool enableLog = true;

  /// 日志回调方法，用于自定义日志处理
  /// [message] 日志内容
  /// [type] 日志回调类型(warn/error)
  /// [label] 日志标签
  static void Function(String message, LogType type, String label)?
      onLogHandler;

  /// 配置日志
  static void setConfig({
    bool? enableLog,
    void Function(String message, LogType type, String label)? onLogHandler,
  }) {
    if (enableLog != null) {
      LogConfig.enableLog = enableLog;
    }
    if (onLogHandler != null) {
      LogConfig.onLogHandler = onLogHandler;
    }
  }
}
