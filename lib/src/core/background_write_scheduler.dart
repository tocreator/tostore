import '../model/background_write_entry.dart';
import '../model/background_write_type.dart';
import '../model/cancellation_token.dart';

/// A background write scheduler that manages pending background write operations
/// (schema migrations, key migrations, large deletes, and large updates).
///
/// It coordinates entry queuing, merging priorities on matching primary keys,
/// and sequential polling for flushes.
class BackgroundWriteScheduler {
  // Table name -> PrimaryKey -> BackgroundWriteType -> BackgroundWriteEntry
  final Map<String, Map<String, Map<BackgroundWriteType, BackgroundWriteEntry>>>
      _queue = {};

  // Ordered queue for FIFO sequence maintenance
  final List<BackgroundWriteEntry> _orderedQueue = [];
  int _headIndex = 0;

  /// Check if the scheduler queue is empty.
  bool get isEmpty => _headIndex >= _orderedQueue.length;

  /// Get the current queue length, including active and placeholder entries.
  int get queueLength => _orderedQueue.length - _headIndex;

  /// Task id at the head of the FIFO queue (the only task polled until drained).
  String? get headTaskId => isEmpty ? null : _orderedQueue[_headIndex].taskId;

  /// Whether any not-yet-polled entry has the given [type].
  bool hasPendingEntriesOfType(BackgroundWriteType type) {
    for (var i = _headIndex; i < _orderedQueue.length; i++) {
      if (_orderedQueue[i].type == type) return true;
    }
    return false;
  }

  /// Wait if the scheduler is congested to prevent memory overflow.
  /// Congestion threshold is defined as: writeBatchSize * 2 - normalQueueLength.
  Future<void> waitIfCongested(int writeBatchSize, int normalQueueLength,
      {CancellationToken? cancellationToken}) async {
    final threshold = writeBatchSize * 2 - normalQueueLength;
    while (queueLength > threshold) {
      if (cancellationToken?.isCancelled == true) {
        return;
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  /// Add a background write entry to the scheduler.
  ///
  /// Merges or invalidates existing entries for the same table and primary key
  /// according to priority rules: keyMigration < schemaMigration < largeUpdate < largeDelete.
  void addEntry(BackgroundWriteEntry entry, String primaryKey) {
    final tableName = entry.tableName;
    final newType = entry.type;
    final newPriority = _getPriority(newType);

    final tableMap = _queue.putIfAbsent(tableName, () => {});
    final existingMap = tableMap[primaryKey];

    bool keepNew = true;

    if (existingMap != null) {
      // Create a copy of keys to avoid concurrent modification during iteration
      final existingTypes = List<BackgroundWriteType>.from(existingMap.keys);

      for (final oldType in existingTypes) {
        final oldEntry = existingMap[oldType]!;

        if (oldType == newType) {
          // Conflict of the same write type
          if (newType == BackgroundWriteType.largeUpdate ||
              newType == BackgroundWriteType.largeDelete) {
            if (entry.entry.timestamp.isAfter(oldEntry.entry.timestamp)) {
              oldEntry.isValid = false;
              existingMap.remove(oldType);
            } else {
              entry.isValid = false;
              keepNew = false;
            }
          } else {
            // For migrations, keep the one with the newer timestamp if duplicated
            if (entry.entry.timestamp.isAfter(oldEntry.entry.timestamp)) {
              oldEntry.isValid = false;
              existingMap.remove(oldType);
            } else {
              entry.isValid = false;
              keepNew = false;
            }
          }
        } else {
          // Conflict of different write types: evaluate priority
          final oldPriority = _getPriority(oldType);
          if (oldPriority > newPriority) {
            // Existing entry has higher priority, invalidate the new entry
            entry.isValid = false;
            keepNew = false;
          } else {
            // New entry has higher priority, invalidate and remove the old entry
            oldEntry.isValid = false;
            existingMap.remove(oldType);
          }
        }
      }

      if (keepNew) {
        existingMap[newType] = entry;
      }
    } else {
      tableMap[primaryKey] = {newType: entry};
    }

    _orderedQueue.add(entry);
  }

  /// Handle an online write (insert, update, delete) to prevent old background tasks
  /// from overwriting new online data.
  ///
  /// Marks all pending background entries for the same primary key as invalid.
  void handleOnlineWrite(String tableName, String primaryKey) {
    final tableMap = _queue[tableName];
    if (tableMap == null) return;

    final existingMap = tableMap[primaryKey];
    if (existingMap == null) return;

    for (final entry in existingMap.values) {
      entry.isValid = false;
    }
    // Remove all references from queue map since they are now invalid
    tableMap.remove(primaryKey);
    if (tableMap.isEmpty) {
      _queue.remove(tableName);
    }
  }

  /// Poll background write entries for the current active background task.
  ///
  /// Identifies the oldest taskId in the queue and pulls up to [limit] entries
  /// belonging to that task.
  List<BackgroundWriteEntry> pollBackgroundWriteEntries(int limit) {
    if (isEmpty || limit <= 0) {
      _resetQueueIfNeeded();
      return const [];
    }

    final activeTaskId = _orderedQueue[_headIndex].taskId;
    final List<BackgroundWriteEntry> result = [];
    int count = 0;

    while (_headIndex < _orderedQueue.length && count < limit) {
      final entry = _orderedQueue[_headIndex];
      if (entry.taskId != activeTaskId) {
        break; // Stop when encountering another task's entries
      }

      _headIndex++;
      result.add(entry);
      count++;

      // Clean up lookup maps to release memory using its primaryKey
      _removeFromLookup(entry.tableName, entry.primaryKey, entry.type);
    }

    _resetQueueIfNeeded();
    return result;
  }

  /// Remove entry from the queue lookup table.
  void _removeFromLookup(
      String tableName, String primaryKey, BackgroundWriteType type) {
    final tableMap = _queue[tableName];
    if (tableMap == null) return;

    final existingMap = tableMap[primaryKey];
    if (existingMap == null) return;

    existingMap.remove(type);
    if (existingMap.isEmpty) {
      tableMap.remove(primaryKey);
    }
    if (tableMap.isEmpty) {
      _queue.remove(tableName);
    }
  }

  /// Shrink the queue list periodically to reclaim memory.
  void _resetQueueIfNeeded() {
    if (_headIndex >= _orderedQueue.length) {
      _orderedQueue.clear();
      _headIndex = 0;
    } else if (_headIndex > 10000 && _headIndex > _orderedQueue.length ~/ 2) {
      _orderedQueue.removeRange(0, _headIndex);
      _headIndex = 0;
    }
  }

  /// Clear all pending background write entries of the given [type].
  ///
  /// This removes them from both lookup maps and the ordered queue.
  void clearEntriesOfType(BackgroundWriteType type) {
    // 1. Remove from _queue maps
    for (final tableMap in _queue.values) {
      for (final existingMap in tableMap.values) {
        final entry = existingMap.remove(type);
        if (entry != null) {
          entry.isValid = false;
        }
      }
    }
    // Clean up empty maps in _queue
    _queue.removeWhere((tableName, tableMap) {
      tableMap.removeWhere((pk, existingMap) => existingMap.isEmpty);
      return tableMap.isEmpty;
    });

    // 2. Remove from _orderedQueue
    if (_headIndex < _orderedQueue.length) {
      final List<BackgroundWriteEntry> remaining = [];
      for (var i = _headIndex; i < _orderedQueue.length; i++) {
        final entry = _orderedQueue[i];
        if (entry.type == type) {
          entry.isValid = false;
        } else {
          remaining.add(entry);
        }
      }
      // Re-populate orderedQueue for the pending segment
      _orderedQueue.length = _headIndex; // Keep already-polled prefix intact
      _orderedQueue.addAll(remaining);
    }
  }

  /// Clear all pending entries in the scheduler.
  void clearAll() {
    // 1. Mark entries in queue mapping as invalid and clear
    for (final tableMap in _queue.values) {
      for (final existingMap in tableMap.values) {
        for (final entry in existingMap.values) {
          entry.isValid = false;
        }
      }
    }
    _queue.clear();

    // 2. Mark entries in ordered queue as invalid and truncate pending segment
    if (_headIndex < _orderedQueue.length) {
      for (var i = _headIndex; i < _orderedQueue.length; i++) {
        _orderedQueue[i].isValid = false;
      }
      _orderedQueue.length = _headIndex; // Keep already-polled prefix intact
    }
  }

  /// Get priority for background write types.
  int _getPriority(BackgroundWriteType type) {
    switch (type) {
      case BackgroundWriteType.keyMigration:
        return 1;
      case BackgroundWriteType.schemaMigration:
        return 2;
      case BackgroundWriteType.largeUpdate:
        return 3;
      case BackgroundWriteType.largeDelete:
        return 4;
    }
  }
}
