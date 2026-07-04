import 'table_identity.dart';

/// Type of data change
enum ChangeType {
  insert,
  update,
  delete,
  clear,
}

/// Event payload for data changes
class ChangeEvent {
  final ChangeType type;
  final TableUid tableUid;
  final Map<String, dynamic>? record; // The new record (null for delete)
  final Map<String, dynamic>? oldRecord; // The old record (null for insert)

  ChangeEvent({
    required this.type,
    required this.tableUid,
    this.record,
    this.oldRecord,
  });

  @override
  String toString() {
    return 'ChangeEvent(type: $type, tableUid: $tableUid, record: $record, oldRecord: $oldRecord)';
  }
}
