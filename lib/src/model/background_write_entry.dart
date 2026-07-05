import 'buffer_entry.dart';
import 'background_write_type.dart';
import 'migration_write_mode.dart';
import 'table_identity.dart';

/// Entry representing a background write operation scheduled for flushing.
class BackgroundWriteEntry {
  /// The operation ID or migration task ID this entry belongs to.
  final String taskId;

  /// The stable table unique identifier.
  final TableUid tableUid;

  /// The record primary key.
  final String primaryKey;

  /// The background write type.
  final BackgroundWriteType type;

  /// The background write mode.
  final MigrationWriteMode mode;

  /// The wrapped data entry containing mutation details.
  final BufferEntry entry;

  /// Specific index uids to build or update. If null and mode includes index write,
  /// all indexes of the table will be processed by default.
  final List<IndexUid>? specificIndexUids;

  /// The current batch start cursor (for safe persisted checkpoint recovery).
  final String? currentCursor;

  /// The current batch end cursor (for in-memory active intention check).
  final String? nextCursor;

  /// Flag indicating if the entry is valid. If merged by a higher-priority task,
  /// this is set to false.
  bool isValid;

  BackgroundWriteEntry({
    required this.taskId,
    required this.tableUid,
    required this.primaryKey,
    required this.type,
    required this.mode,
    required this.entry,
    this.specificIndexUids,
    this.currentCursor,
    this.nextCursor,
    this.isValid = true,
  });

  BackgroundWriteEntry copyWith({
    String? taskId,
    TableUid? tableUid,
    String? primaryKey,
    BackgroundWriteType? type,
    MigrationWriteMode? mode,
    BufferEntry? entry,
    List<IndexUid>? specificIndexUids,
    String? currentCursor,
    String? nextCursor,
    bool? isValid,
  }) {
    return BackgroundWriteEntry(
      taskId: taskId ?? this.taskId,
      tableUid: tableUid ?? this.tableUid,
      primaryKey: primaryKey ?? this.primaryKey,
      type: type ?? this.type,
      mode: mode ?? this.mode,
      entry: entry ?? this.entry,
      specificIndexUids: specificIndexUids ?? this.specificIndexUids,
      currentCursor: currentCursor ?? this.currentCursor,
      nextCursor: nextCursor ?? this.nextCursor,
      isValid: isValid ?? this.isValid,
    );
  }
}
