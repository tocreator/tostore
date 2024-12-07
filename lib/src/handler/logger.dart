import 'dart:developer';

import 'package:flutter/foundation.dart';

import 'common.dart';
import '../model/log_config.dart';

// 日志类型枚举
enum LogType { info, debug, warn, error }

/// 日志记录，调试、信息、警告、错误等类型输出控制台，可自定义标签，以快速检索，设置警告、错误接口回调，方便追踪及排查问题。
/// 检索技巧：搜索"logger"查看所有类型日志，搜索log-error，查看所有错误
class Logger {
  /// 通用标签，方便定位所有日志
  static String _commonLabel = 'logger';

  /// 日志处理回调函数
  static void Function(String message, LogType type, String label)?
      _onLogHandler;

  /// 配置接口
  static void setConfig({
    /// 日志处理回调函数
    Function(
      String message, // 日志内容
      LogType type, // 默认警告、错误回调类型
      String label, // 日志标签，比如发生错误的方法名
    )? onLogHandler,

    /// 设置通用标签，方便定位所有日志
    String? label,
  }) {
    if (onLogHandler != null) {
      _onLogHandler = onLogHandler;
    }
    if (label != null) {
      _commonLabel = label;
    }
  }

  /// 打印信息日志
  static void info(Object? message, {String? label}) {
    final text = toStringWithAll(message);
    label = label == null ? "log-info" : "log-info  $label";
    _log(text, label: label);
  }

  /// 打印调试日志
  static void debug(Object? message, {String? label}) {
    final text = toStringWithAll(message);
    label = label == null ? "log-debug" : "log-debug  $label";
    _log(text, label: label);
  }

  /// 打印警告日志
  static void warn(Object? message, {String? label}) {
    final text = toStringWithAll(message);
    label = label == null ? "log-warn" : "log-warn  $label";
    _log(text, label: "💡  $label");
    _handler(text, LogType.warn, label);
  }

  /// 打印错误日志,label可定义发生错误的方法名
  static void error(Object? message, {String? label}) {
    final text = toStringWithAll(message);
    label = label == null ? "log-error" : "log-error  $label";
    _log(text, label: "🔴  $label");
    _handler(text, LogType.error, label);
  }

  /// 统一处理日志回调
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

  /// 内部日志处理方法
  static void _log(Object? message, {String label = "log-info"}) {
    if (kDebugMode) {
      final displayLabel = InternalConfig.showLoggerInternalLabel
          ? label
          : InternalConfig.publicLabel;
      String startDash = "${'-' * 20}    $displayLabel    ${'-' * 18}>>";
      String endDash = "${'-' * (startDash.length - 2)}<<";
      if (startDash.length > 130) {
        startDash = "${'-' * 40}>>\n    $displayLabel\n";
        endDash = "${'-' * 40}<<";
      }
      log(
        "\n$startDash\n$message\n$endDash\n",
        name: _commonLabel,
      );
    }
  }
}
