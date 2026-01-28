import 'wal_pointer.dart';

/// Represents an entry in the memory buffer.
class BufferEntry {
  final BufferOperationType operation;
  final Map<String, dynamic> data;
  final DateTime timestamp;

  /// The WAL pointer associated with this entry.
  /// Used for strict versioning to prevent lost updates during flush.
  final WalPointer? walPointer;

  /// Optional transaction id owning this entry (uncommitted). Null means non-transactional/committed entry
  final String? transactionId;

  /// Optional: old values for updated/deleted record (indexed by field name).
  /// Used for unique/index maintenance without
  final Map<String, dynamic>? oldValues;

  BufferEntry(
      {required this.operation,
      required this.data,
      required this.timestamp,
      this.walPointer,
      this.transactionId,
      this.oldValues});

  BufferEntry copyWith({
    Map<String, dynamic>? data,
    BufferOperationType? operation,
    DateTime? timestamp,
    WalPointer? walPointer,
    String? transactionId,
    Map<String, dynamic>? oldValues,
  }) {
    return BufferEntry(
      data: data ?? this.data,
      operation: operation ?? this.operation,
      timestamp: timestamp ?? this.timestamp,
      walPointer: walPointer ?? this.walPointer,
      transactionId: transactionId ?? this.transactionId,
      oldValues: oldValues ?? this.oldValues,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'operation': operation.index,
      'data': data,
      'timestamp': timestamp.toIso8601String(),
      if (walPointer != null) 'walPointer': walPointer!.toJson(),
      if (transactionId != null) 'transactionId': transactionId,
      if (oldValues != null) 'oldValues': oldValues,
    };
  }

  factory BufferEntry.fromJson(Map<String, dynamic> json) {
    return BufferEntry(
      operation: BufferOperationType.values[json['operation']],
      data: json['data'],
      timestamp: DateTime.parse(json['timestamp'] as String),
      walPointer: json['walPointer'] != null
          ? WalPointer.fromJson(json['walPointer'])
          : null,
      transactionId: json.containsKey('transactionId')
          ? json['transactionId'] as String?
          : null,
      oldValues: json.containsKey('oldValues')
          ? (json['oldValues'] as Map?)?.cast<String, dynamic>()
          : null,
    );
  }
}

enum BufferOperationType {
  insert, // insert operation
  update, // update operation
  delete, // delete operation
  rewrite, // rewrite operation, used for data migration or repair
}
