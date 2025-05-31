import 'dart:developer';

import 'package:flutter/foundation.dart';

import 'common.dart';
import '../model/log_config.dart';

// log type enum
enum LogType { info, debug, warn, error }

/// log record, output to console, debug, info, warn, error, etc.
/// can customize label, for quick search, set warn, error callback, for tracking and troubleshooting.
/// search tips: search "logger" to view all types of logs, search log-error to view all errors
class Logger {
  /// common label, for quick search
  static String _commonLabel = InternalConfig.publicLabel;

  /// log handler callback
  static void Function(String message, LogType type, String label)?
      _onLogHandler;

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

  /// print info log
  static void info(Object? message, {String? label}) {
    if (!LogConfig.shouldLogType(LogType.info)) {
      return;
    }

    final text = toStringWithAll(message);
    label = label == null || !InternalConfig.showLoggerInternalLabel
        ? "log-info"
        : "log-info  $label";
    _log(text, label: label);
  }

  /// print debug log
  static void debug(Object? message, {String? label}) {
    if (!LogConfig.shouldLogType(LogType.debug)) {
      return;
    }

    final text = toStringWithAll(message);
    label = label == null || !InternalConfig.showLoggerInternalLabel
        ? "log-debug"
        : "log-debug  $label";
    _log(text, label: label);
  }

  /// print warn log
  static void warn(Object? message, {String? label}) {
    if (!LogConfig.shouldLogType(LogType.warn)) {
      return;
    }

    final text = toStringWithAll(message);
    label = label == null || !InternalConfig.showLoggerInternalLabel
        ? "log-warn"
        : "log-warn  $label";
    _log(text, label: "[!] $label");
    _handler(text, LogType.warn, label);
  }

  /// print error log, label can define the method name
  static void error(Object? message, {String? label}) {
    if (!LogConfig.shouldLogType(LogType.error)) {
      return;
    }

    final text = toStringWithAll(message);
    label = label == null || !InternalConfig.showLoggerInternalLabel
        ? "log-error"
        : "log-error  $label";
    _log(text, label: "[X] $label");
    _handler(text, LogType.error, label);
  }

  /// unified log handler
  static void _handler(String message, LogType type, String label) {
    if (!kDebugMode && LogConfig.enableLog) {
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
    if (kDebugMode && LogConfig.enableLog) {
      String startDash = "${'-' * 20}    $label    ${'-' * 18}>>";
      String endDash = "${'-' * (startDash.length - 2)}<<";
      if (startDash.length > 130) {
        startDash = "${'-' * 40}>>\n    $label\n";
        endDash = "${'-' * 40}<<";
      }
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
