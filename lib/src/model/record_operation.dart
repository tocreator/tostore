/// write buffer entry model
class WriteBufferEntry {
  final Map<String, dynamic> data;
  final RecordOperationType operation;
  final DateTime timestamp;

  WriteBufferEntry({
    required this.data,
    required this.operation,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() {
    return {
      'data': data,
      'operation': operation.toString().split('.').last,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  factory WriteBufferEntry.fromJson(Map<String, dynamic> json) {
    return WriteBufferEntry(
      data: json['data'] as Map<String, dynamic>,
      operation: _parseOperationType(json['operation'] as String),
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }

  static RecordOperationType _parseOperationType(String value) {
    final lowerValue = value.toLowerCase();

    // only create explicit branches for non-insert cases
    if (lowerValue == 'update') {
      return RecordOperationType.update;
    } else if (lowerValue == 'delete') {
      return RecordOperationType.delete;
    } else if (lowerValue == 'rewrite') {
      return RecordOperationType.rewrite;
    }

    // all other cases
    return RecordOperationType.insert;
  }
}

/// record operation type enum
enum RecordOperationType {
  insert, // insert new record
  update, // update record
  delete, // delete record
  rewrite, // rewrite whole table or partition
}
