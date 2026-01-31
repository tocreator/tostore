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
  static bool get enableLog => _enableLog;

  /// Current log level, default shows all logs
  static LogLevel _logLevel = LogLevel.warn;
  static LogLevel get logLevel => _logLevel;

  /// Log callback method, for custom log processing
  ///
  /// Parameters:
  /// - `message`: The log content message
  /// - `type`: The log type (debug, info, warn, error)
  /// - `label`: The log category label
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

  /// Configure log settings
  ///
  /// Parameters:
  /// - `enableLog`: Whether to enable logging
  /// - `logLevel`: The minimum log level to display
  /// - `onLogHandler`: Custom log handler function
  /// - `publicLabel`: Default label for logs
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
