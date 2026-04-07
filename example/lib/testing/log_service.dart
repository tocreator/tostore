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
    // Increased the limit to 500. ListView.builder in Flutter handles 500 entries efficiently.
    const maxLogs = 500;
    const pruneTo =
        350; // Prune back to 70% when limit reached (removes 150 entries)

    final now = DateTime.now();
    final timestampString =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';

    final entry = LogEntry(
        message: '[$timestampString] $message', type: type, timestamp: now);

    final currentLogs = _logs.value;

    if (currentLogs.length >= maxLogs) {
      // Smart Pruning: Prioritize removing older debug/info logs while keeping errors/warnings.
      final logsToKeep = <LogEntry>[];
      final toRemoveCount = (currentLogs.length + 1) - pruneTo;
      int removed = 0;

      for (int i = 0; i < currentLogs.length; i++) {
        final e = currentLogs[i];
        // In the older half of logs, skip debug/info entries until we reach prune target.
        if (removed < toRemoveCount &&
            (e.type == LogType.debug || e.type == LogType.info)) {
          removed++;
          continue;
        }
        logsToKeep.add(e);
      }

      // If we haven't removed enough (due to high volume of errors/warnings),
      // forced removal from the oldest entries to stay within bounds.
      while (logsToKeep.length >= pruneTo) {
        logsToKeep.removeAt(0);
      }

      logsToKeep.add(entry);
      _logs.value = logsToKeep;
    } else {
      // Standard addition
      _logs.value = [...currentLogs, entry];
    }

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
