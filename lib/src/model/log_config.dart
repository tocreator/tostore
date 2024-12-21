import '../handler/logger.dart';

/// global log config
class LogConfig {
  /// enable log
  static bool enableLog = true;

  /// log callback method, for custom log processing
  /// [message] log content
  /// [type] log callback type (warn/error)
  /// [label] log label
  static void Function(String message, LogType type, String label)?
      onLogHandler;

  /// configure log
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
