import '../handler/logger.dart';

/// global log config
class LogConfig {
  /// enable log
  static bool _enableLog = true;
  static get enableLog => _enableLog;

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
    String? publicLabel,
  }) {
    if (enableLog != null) {
      _enableLog = enableLog;
    }
    if (onLogHandler != null) {
      onLogHandler = onLogHandler;
    }
    if (publicLabel != null) {
      Logger.setConfig(label: publicLabel);
    }
  }
}
