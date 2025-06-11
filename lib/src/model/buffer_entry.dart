/// buffer entry model
class BufferEntry {
  final Map<String, dynamic> data;
  final BufferOperationType operation;
  final DateTime timestamp;

  BufferEntry({
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

  factory BufferEntry.fromJson(Map<String, dynamic> json) {
    return BufferEntry(
      data: json['data'] as Map<String, dynamic>,
      operation: _parseOperationType(json['operation'] as String),
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }

  static BufferOperationType _parseOperationType(String value) {
    final lowerValue = value.toLowerCase();

    // only create explicit branches for non-insert cases
    if (lowerValue == 'update') {
      return BufferOperationType.update;
    } else if (lowerValue == 'delete') {
      return BufferOperationType.delete;
    } else if (lowerValue == 'rewrite') {
      return BufferOperationType.rewrite;
    }

    // all other cases
    return BufferOperationType.insert;
  }
}

/// Buffer operation type
enum BufferOperationType {
  insert, // insert operation
  update, // update operation
  delete, // delete operation
  rewrite, // rewrite operation
}
