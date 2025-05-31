import '../handler/logger.dart';

/// Log level, each level represents showing logs of that level and higher
enum LogLevel {
  /// Show all logs (including debug, info, warn, error)
  debug,

  /// Show info, warn, error logs (does not show debug logs)
  info,

  /// Show warn, error logs (does not show debug, info logs)
  warn,

  /// Only show error logs (does not show debug, info, warn logs)
  error
}

/// global log config
class LogConfig {
  /// enable log
  static bool _enableLog = true;
  static get enableLog => _enableLog;

  /// Current log level, default shows all logs
  static LogLevel _logLevel = LogLevel.warn;
  static LogLevel get logLevel => _logLevel;

  /// log callback method, for custom log processing
  /// [message] log content
  /// [type] log callback type (warn/error)
  /// [label] log label
  static void Function(String message, LogType type, String label)?
      onLogHandler;

  /// Determine whether to show the log based on log type and configured log level
  static bool shouldLogType(LogType type) {
    if (!_enableLog) return false;

    switch (_logLevel) {
      case LogLevel.debug:
        return true;
      case LogLevel.info:
        return type != LogType.debug;
      case LogLevel.warn:
        return type == LogType.warn || type == LogType.error;
      case LogLevel.error:
        return type == LogType.error;
    }
  }

  /// configure log
  static void setConfig({
    bool? enableLog,
    LogLevel? logLevel,
    void Function(String message, LogType type, String label)? onLogHandler,
    String? publicLabel,
  }) {
    if (enableLog != null) {
      _enableLog = enableLog;
    }
    if (logLevel != null) {
      _logLevel = logLevel;
    }
    if (onLogHandler != null) {
      LogConfig.onLogHandler = onLogHandler;
    }
    if (publicLabel != null) {
      Logger.setConfig(label: publicLabel);
    }
  }
}
