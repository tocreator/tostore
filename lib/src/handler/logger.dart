import 'dart:developer';

import '../model/log_config.dart';
import 'common.dart';
import 'platform_handler.dart';

// log type enum
enum LogType { info, debug, warn, error }

/// log record, output to console, debug, info, warn, error, etc.
/// can customize label, for quick search, set warn, error callback, for tracking and troubleshooting.
/// search tips: search "logger" to view all types of logs, search log-error to view all errors
class Logger {
  /// common label, for quick search
  static String _commonLabel = InternalConfig.publicLabel;
  static String get commonLabel => _commonLabel;

  /// log handler callback
  static void Function(String message, LogType type, String label)?
      _onLogHandler;

  static dynamic _isolateLogSendPort;

  /// config interface
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
      _onLogHandler = onLogHandler;
    }
    if (label != null) {
      _commonLabel = label;
    }
  }

  /// Configure worker isolates to forward logs back to the main isolate.
  static void setIsolateLogForwarder(dynamic sendPort) {
    _isolateLogSendPort = sendPort;
  }

  /// print info log
  static void info(Object? message, {String? label}) {
    if (!LogConfig.shouldLogType(LogType.info)) {
      return;
    }

    final forwardToMain = _isForwardingWorkerLogsToMain;
    final text = toStringWithAll(message);
    label = label == null || !InternalConfig.showLoggerInternalLabel
        ? "log-info"
        : "log-info  $label";
    if (forwardToMain && _forwardToMainIsolate(text, LogType.info, label)) {
      return;
    }
    _log(text, label: label);
    _handler(text, LogType.info, label);
  }

  /// print debug log
  static void debug(Object? message, {String? label}) {
    if (!LogConfig.shouldLogType(LogType.debug)) {
      return;
    }

    final forwardToMain = _isForwardingWorkerLogsToMain;
    final text = toStringWithAll(message);
    label = label == null || !InternalConfig.showLoggerInternalLabel
        ? "log-debug"
        : "log-debug  $label";
    if (forwardToMain && _forwardToMainIsolate(text, LogType.debug, label)) {
      return;
    }
    _log(text, label: label);
    _handler(text, LogType.debug, label);
  }

  /// print warn log
  static void warn(Object? message, {String? label}) {
    if (!LogConfig.shouldLogType(LogType.warn)) {
      return;
    }

    final forwardToMain = _isForwardingWorkerLogsToMain;
    final text = toStringWithAll(message);
    label = label == null || !InternalConfig.showLoggerInternalLabel
        ? "log-warn"
        : "log-warn  $label";
    if (forwardToMain && _forwardToMainIsolate(text, LogType.warn, label)) {
      return;
    }
    _log(text, label: _consoleLabel(LogType.warn, label));
    _handler(text, LogType.warn, label);
  }

  /// print error log, label can define the method name
  static void error(Object? message, {String? label}) {
    if (!LogConfig.shouldLogType(LogType.error)) {
      return;
    }

    final forwardToMain = _isForwardingWorkerLogsToMain;
    final text = toStringWithAll(message);
    label = label == null || !InternalConfig.showLoggerInternalLabel
        ? "log-error"
        : "log-error  $label";
    if (forwardToMain && _forwardToMainIsolate(text, LogType.error, label)) {
      return;
    }
    _log(text, label: _consoleLabel(LogType.error, label));
    _handler(text, LogType.error, label);
  }

  /// Replays a worker-isolate log on the main isolate.
  static void logFromIsolate(String message, LogType type, String label) {
    if (!LogConfig.shouldLogType(type)) {
      return;
    }

    _log(message, label: _consoleLabel(type, label));
    _handler(message, type, label);
  }

  // Static fields are isolate-local. The main isolate never sets this port;
  // compute workers set it from their entry point so their logs can be replayed
  // by the main isolate without recursively forwarding main-isolate logs.
  static bool get _isForwardingWorkerLogsToMain => _isolateLogSendPort != null;

  static bool _forwardToMainIsolate(
    String message,
    LogType type,
    String label,
  ) {
    final sendPort = _isolateLogSendPort;
    if (sendPort == null) return false;

    sendPort.send(<String, Object?>{
      'type': 'log',
      'level': type.index,
      'message': message,
      'label': label,
    });
    return true;
  }

  static String _consoleLabel(LogType type, String label) {
    switch (type) {
      case LogType.warn:
        return "\u{1F4A1}  $label";
      case LogType.error:
        return "\u{1F534}  $label";
      case LogType.info:
      case LogType.debug:
        return label;
    }
  }

  /// unified log handler
  static void _handler(String message, LogType type, String label) {
    if (LogConfig.enableLog) {
      if (_onLogHandler != null) {
        _onLogHandler!(message, type, label);
      } else if (LogConfig.onLogHandler != null) {
        setConfig(onLogHandler: LogConfig.onLogHandler);
        _onLogHandler!(message, type, label);
      }
    }
  }

  /// internal log handler
  static void _log(Object? message, {String label = "log-info"}) {
    if (PlatformHandler.isDebug && LogConfig.enableLog) {
      String startDash =
          "--------------------    $label    --------------------";
      String endDash = '-' * (startDash.length);
      if (message is DateTime) {
        message = message.toIso8601String();
      }
      log(
        "\n$startDash\n$message\n$endDash\n",
        name: _commonLabel,
      );
    }
  }
}
