import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:tostore/tostore.dart';

/// A simple class to hold log data along with its type.
class LogEntry {
  final String message;
  final LogType type;
  final DateTime timestamp;

  LogEntry(
      {required this.message, required this.type, required this.timestamp});
}

/// A simple service to manage and notify about logs.
class LogService {
  final ValueNotifier<List<LogEntry>> _logs = ValueNotifier([]);
  ValueNotifier<List<LogEntry>> get logs => _logs;

  void add(String message,
      [LogType type = LogType.info, bool fromCallback = false]) {
    // To avoid UI freezing with a large number of logs, we keep a reasonable limit.
    const maxLogs = 200;
    final now = DateTime.now();
    final timestampString =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    final newLogs = List<LogEntry>.from(_logs.value);
    newLogs.add(LogEntry(
        message: '[$timestampString] $message', type: type, timestamp: now));
    if (newLogs.length > maxLogs) {
      newLogs.removeRange(0, newLogs.length - maxLogs);
    }
    _logs.value = newLogs;

    // Only print to the developer console if the log is NOT from the internal callback.
    if (!fromCallback) {
      developer.log(message);
    }
  }

  void clear() {
    _logs.value = [];
  }
}

final logService = LogService();
