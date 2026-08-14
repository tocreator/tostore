import 'dart:developer';

import '../model/db_exception.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import 'common.dart';
import 'platform_handler.dart';

/// Log level, each level represents showing logs of that level and higher
enum LogLevel {
  /// Show all logs (including debug, info, warn, error, critical)
  debug,

  /// Show info, warn, error, critical logs (does not show debug logs)
  info,

  /// Show warn, error, critical logs (does not show debug, info logs)
  warn,

  /// Show error, critical logs (does not show debug, info, warn logs)
  error,

  /// Only show critical logs (does not show debug, info, warn, error logs)
  critical
}

/// log record, output to console, debug, info, warn, error, etc.
/// search tips: search "logger" to view all types of logs, search log-error to view all errors
class Logger {
  /// public label, for quick search
  static String _publicLabel = InternalConfig.publicLabel;

  static dynamic _isolateLogSendPort;

  // --- Core State Variables ---
  static bool _enableLog = true;
  static bool get enableLog => _enableLog;

  static LogLevel _logLevel = LogLevel.warn;
  static LogLevel get logLevel => _logLevel;

  /// Global log callback.
  static void Function(LogRecord log)? onLog;

  /// Legacy log callback.
  static void Function(String message, LogType type, String label)?
      _oldOnLogHandler;

  // --- Core Control Methods ---
  static void setLogConfig({
    bool? enableLog,
    LogLevel? logLevel,
    void Function(LogRecord log)? onLog,
    String? logLabel,
  }) {
    if (enableLog != null) {
      _enableLog = enableLog;
    }
    if (logLevel != null) {
      _logLevel = logLevel;
    }
    if (onLog != null) {
      Logger.onLog = onLog;
    }
    if (logLabel != null) {
      _publicLabel = logLabel;
    }
  }

  static void setLogLevel(LogLevel level) {
    _logLevel = level;
  }

  static void setEnableLog(bool enable) {
    _enableLog = enable;
  }

  static bool shouldLog(LogLevel level) {
    if (!_enableLog) return false;
    return level.index >= _logLevel.index;
  }

  // --- Static Pre-calculated Constants for High Performance ---
  static final Map<LogLevel, String> _startDashes = {
    LogLevel.debug: "--------------------    log-debug    --------------------",
    LogLevel.info: "--------------------    log-info    --------------------",
    LogLevel.warn: "--------------------    log-warn    --------------------",
    LogLevel.error: "--------------------    log-error    --------------------",
    LogLevel.critical:
        "--------------------    log-critical    --------------------",
  };

  static final Map<LogLevel, String> _endDashes = {
    LogLevel.debug: "---------------------------------------------------------",
    LogLevel.info: "--------------------------------------------------------",
    LogLevel.warn: "--------------------------------------------------------",
    LogLevel.error: "---------------------------------------------------------",
    LogLevel.critical:
        "------------------------------------------------------------",
  };

  static final Map<LogLevel, String> _emojis = {
    LogLevel.warn: "\u{1F4A1}", // [i]
    LogLevel.error: "\u{1F534}", // [!]
    LogLevel.critical: "\u{1F525}", // [!!]
  };

  static final Map<LogLevel, String> _consoleLabels = {
    LogLevel.debug: "log-debug",
    LogLevel.info: "log-info",
    LogLevel.warn: "\u{1F4A1}  log-warn",
    LogLevel.error: "\u{1F534}  log-error",
    LogLevel.critical: "\u{1F525}  log-critical",
  };

  /// A sendable snapshot used to initialize compute worker isolates.
  static Map<String, Object?> snapshotForIsolate() {
    return <String, Object?>{
      'enableLog': _enableLog,
      'logLevel': _logLevel.index,
      'publicLabel': _publicLabel,
    };
  }

  /// Apply a log configuration snapshot inside a compute worker isolate.
  static void applyIsolateSnapshot(Map<dynamic, dynamic>? snapshot) {
    if (snapshot == null) return;
    final enableLog = snapshot['enableLog'];
    final logLevelIndex = snapshot['logLevel'];
    final publicLabel = snapshot['publicLabel'];

    Logger.setLogConfig(
      enableLog: enableLog is bool ? enableLog : null,
      logLevel: (logLevelIndex is int &&
              logLevelIndex >= 0 &&
              logLevelIndex < LogLevel.values.length)
          ? LogLevel.values[logLevelIndex]
          : null,
      logLabel: publicLabel is String ? publicLabel : null,
    );
  }

  /// config interface
  @Deprecated('Use ToStore.setLogConfig() instead')
  static void setConfig({
    /// log handler callback
    Function(
      String message, // log content
      LogType type, // default warn, error callback type
      String label, // log label, like method name
    )? onLogHandler,

    /// set common label, for quick search
    String? label,
  }) {
    if (onLogHandler != null) {
      _oldOnLogHandler = onLogHandler;
    }
    if (label != null) {
      _publicLabel = label;
    }
  }

  /// Configure worker isolates to forward logs back to the main isolate.
  static void setIsolateLogForwarder(dynamic sendPort) {
    _isolateLogSendPort = sendPort;
  }

  /// print info log
  static void info(Object? message, {Object? rawError}) {
    _logGeneric(LogLevel.info, message, rawError: rawError);
  }

  /// print debug log
  static void debug(Object? message, {Object? rawError}) {
    _logGeneric(LogLevel.debug, message, rawError: rawError);
  }

  /// print warn log
  static void warn(Object? message, {Object? rawError}) {
    _logGeneric(LogLevel.warn, message, rawError: rawError);
  }

  /// print error log
  static void error(Object? message, {Object? rawError}) {
    _logGeneric(LogLevel.error, message, rawError: rawError);
  }

  /// print critical log
  static void critical(Object? message, {Object? rawError}) {
    _logGeneric(LogLevel.critical, message, rawError: rawError);
  }

  /// Helper to log a generic level of event
  static void _logGeneric(LogLevel level, Object? message, {Object? rawError}) {
    if (!Logger.shouldLog(level)) {
      return;
    }

    // Resolve structural status from rawError or message
    ResultStatus? status;
    if (rawError != null) {
      if (rawError is ResultStatus) {
        status = rawError;
      } else if (rawError is DbException) {
        status = rawError.statuses.isNotEmpty ? rawError.statuses.first : null;
      } else {
        status = GeneralStatus(
          type: ResultType.engError,
          message: rawError.toString(),
        );
      }
    } else {
      // Fallback check: if message itself is a ResultStatus or DbException
      if (message is ResultStatus) {
        status = message;
      } else if (message is DbException) {
        status = message.statuses.isNotEmpty ? message.statuses.first : null;
      }
    }

    // Intelligent duplicate prevention and filter check: skip if already logged
    if (rawError is DbException) {
      if (rawError.isLogged) {
        return; // Already logged by Logger, skip silently
      }
      rawError.isLogged =
          true; // First time recorded by the Logger, mark it as logged
    }

    if (status != null && status.isBusinessError && level != LogLevel.debug) {
      return;
    }

    // Auto-wrap empty status for error and critical levels
    if (status == null &&
        (level == LogLevel.error || level == LogLevel.critical)) {
      final msgStr = message != null ? toStringWithAll(message) : '';
      status = GeneralStatus(
        type: ResultType.engError,
        message: msgStr.isNotEmpty
            ? msgStr
            : (level == LogLevel.critical
                ? 'Critical system error'
                : 'Database error'),
      );
    }

    // Directly use status.message as the final log message if available,
    // ignoring fallback message to prevent duplicate processing.
    final String text;
    if (message != null && status != null) {
      final ctx = message is String ? message : toStringWithAll(message);
      final detail = status.message;
      if (ctx == detail || message is ResultStatus || message is DbException) {
        text = ctx;
      } else {
        text = detail.isNotEmpty ? '$ctx: $detail' : ctx;
      }
    } else if (status != null) {
      text = status.message;
    } else if (message is String) {
      text = message;
    } else if (message != null) {
      text = toStringWithAll(message);
    } else {
      text = '';
    }

    // Both fields empty -> skip logging
    if (text.isEmpty && status == null) {
      return;
    }

    final forwardToMain = _isForwardingWorkerLogsToMain;

    if (forwardToMain && _forwardToMainIsolate(text, level, status)) {
      return;
    }

    _log(text, level: level, status: status);
    _handler(text, level, status);
  }

  /// Replays a worker-isolate log on the main isolate.
  static void logFromIsolate(
      String message, LogLevel level, ResultStatus? status) {
    if (!Logger.shouldLog(level)) {
      return;
    }

    _log(message, level: level, status: status);
    _handler(message, level, status);
  }

  // Static fields are isolate-local. The main isolate never sets this port;
  // compute workers set it from their entry point so their logs can be replayed
  // by the main isolate without recursively forwarding main-isolate logs.
  static bool get _isForwardingWorkerLogsToMain => _isolateLogSendPort != null;

  static bool _forwardToMainIsolate(
    String message,
    LogLevel level,
    ResultStatus? status,
  ) {
    final sendPort = _isolateLogSendPort;
    if (sendPort == null) return false;

    sendPort.send(<String, Object?>{
      'type': 'log',
      'level': level.index,
      'message': message,
      'status': status?.toJson(),
    });
    return true;
  }

  static String _consoleLabel(LogLevel level) => _consoleLabels[level] ?? '';

  /// unified log handler
  static void _handler(String message, LogLevel level, ResultStatus? status) {
    if (Logger.enableLog) {
      if (Logger.onLog != null) {
        final record = LogRecord(
          level: level,
          message: message,
          timestamp: DateTime.now(),
          status: status,
        );
        Logger.onLog!(record);
      } else if (Logger._oldOnLogHandler != null) {
        // Backward compatibility for old onLogHandler callback
        final oldHandler = Logger._oldOnLogHandler;
        if (oldHandler != null) {
          LogType oldType;
          switch (level) {
            case LogLevel.debug:
              oldType = LogType.debug;
              break;
            case LogLevel.info:
              oldType = LogType.info;
              break;
            case LogLevel.warn:
              oldType = LogType.warn;
              break;
            case LogLevel.error:
            case LogLevel.critical:
              oldType = LogType.error;
              break;
          }
          oldHandler(message, oldType, _consoleLabel(level));
        }
      }
    }
  }

  /// internal log handler
  static void _log(String message,
      {required LogLevel level, ResultStatus? status}) {
    if (PlatformHandler.isDebug && Logger.enableLog) {
      final startDash = _startDashes[level] ?? '';
      final endDash = _endDashes[level] ?? '';

      String logContent = message;
      if (status != null) {
        logContent = '[${status.code}] [${status.codeKey}]  $logContent';
      }

      final emoji = _emojis[level];
      if (emoji != null) {
        logContent = '$emoji  $logContent';
      }

      log(
        "\n$startDash\n$logContent\n$endDash\n",
        name: _publicLabel,
      );
    }
  }
}

/// A standard log record containing details of a logged event
class LogRecord {
  final LogLevel level;
  final String? _message;
  final DateTime timestamp;
  final ResultStatus? status;

  LogRecord({
    required this.level,
    String? message,
    required this.timestamp,
    this.status,
  }) : _message = message;

  String get message => _message ?? status?.message ?? '';
}

/// global log config
@Deprecated('Use Logger or ToStore.setLogConfig() instead')
class LogConfig {
  /// Configure log settings
  @Deprecated('Use ToStore.setLogConfig() instead')
  static void setConfig({
    bool? enableLog,
    LogLevel? logLevel,
    void Function(String message, LogType type, String label)? onLogHandler,
    String? publicLabel,
  }) {
    Logger.setLogConfig(
      enableLog: enableLog,
      logLevel: logLevel,
      logLabel: publicLabel,
    );
    if (onLogHandler != null) {
      Logger._oldOnLogHandler = onLogHandler;
    }
  }
}

// log type enum
@Deprecated('Use LogLevel instead')
enum LogType { info, debug, warn, error, critical }
