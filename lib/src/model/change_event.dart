/// Type of data change
enum ChangeType {
  insert,
  update,
  delete,
}

/// Event payload for data changes
class ChangeEvent {
  final ChangeType type;
  final String tableName;
  final Map<String, dynamic>? record; // The new record (null for delete)
  final Map<String, dynamic>? oldRecord; // The old record (null for insert)

  ChangeEvent({
    required this.type,
    required this.tableName,
    this.record,
    this.oldRecord,
  });

  @override
  String toString() {
    return 'ChangeEvent(type: $type, table: $tableName, record: $record, oldRecord: $oldRecord)';
  }
}
