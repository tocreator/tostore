import 'buffer_entry.dart';
import 'background_write_type.dart';
import 'background_write_mode.dart';

/// Entry representing a background write operation scheduled for flushing.
class BackgroundWriteEntry {
  /// The operation ID or migration task ID this entry belongs to.
  final String taskId;

  /// The physical table name.
  final String tableName;

  /// The record primary key.
  final String primaryKey;

  /// The background write type.
  final BackgroundWriteType type;

  /// The background write mode.
  final BackgroundWriteMode mode;

  /// The wrapped data entry containing mutation details.
  final BufferEntry entry;

  /// Specific index names to build or update. If null and mode includes index write,
  /// all indexes of the table will be processed by default.
  final List<String>? specificIndexes;

  /// The current batch start cursor (for safe persisted checkpoint recovery).
  final String? currentCursor;

  /// The current batch end cursor (for in-memory active intention check).
  final String? nextCursor;

  /// Flag indicating if the entry is valid. If merged by a higher-priority task,
  /// this is set to false.
  bool isValid;

  BackgroundWriteEntry({
    required this.taskId,
    required this.tableName,
    required this.primaryKey,
    required this.type,
    required this.mode,
    required this.entry,
    this.specificIndexes,
    this.currentCursor,
    this.nextCursor,
    this.isValid = true,
  });

  BackgroundWriteEntry copyWith({
    String? taskId,
    String? tableName,
    String? primaryKey,
    BackgroundWriteType? type,
    BackgroundWriteMode? mode,
    BufferEntry? entry,
    List<String>? specificIndexes,
    String? currentCursor,
    String? nextCursor,
    bool? isValid,
  }) {
    return BackgroundWriteEntry(
      taskId: taskId ?? this.taskId,
      tableName: tableName ?? this.tableName,
      primaryKey: primaryKey ?? this.primaryKey,
      type: type ?? this.type,
      mode: mode ?? this.mode,
      entry: entry ?? this.entry,
      specificIndexes: specificIndexes ?? this.specificIndexes,
      currentCursor: currentCursor ?? this.currentCursor,
      nextCursor: nextCursor ?? this.nextCursor,
      isValid: isValid ?? this.isValid,
    );
  }
}
