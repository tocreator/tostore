import 'buffer_entry.dart';
import 'store_index.dart';

/// Index entry model, used to store index key and record pointer
/// Supports new format (key|StoreIndex) and old format (key:StoreIndex)
class IndexEntry {
  /// Index key (can be single value or composite value)
  final dynamic indexKey;

  /// Record pointer, pointing to the actual record in storage
  final StoreIndex recordPointer;

  /// Create index entry
  const IndexEntry({
    required this.indexKey,
    required this.recordPointer,
  });

  /// Create index entry from string (compatible with new and old formats)
  static IndexEntry? fromString(String value) {
    // New format: use | to separate index key and StoreIndex
    if (value.contains('|')) {
      final parts = value.split('|');
      if (parts.length != 2) return null;

      final key = _parseKey(parts[0]);
      final storeIndex = StoreIndex.fromString(parts[1]);

      if (storeIndex == null) return null;

      return IndexEntry(
        indexKey: key,
        recordPointer: storeIndex,
      );
    }
    // Old format: the part after the last : is StoreIndex
    else {
      // Try parsing from the end, find the StoreIndex part
      final parts = value.split(':');
      if (parts.length < 2) return null;

      // Try different combinations to parse StoreIndex
      StoreIndex? storeIndex;
      String keyPart = '';

      // Try parsing StoreIndex from the least 2 parts
      for (int i = parts.length - 2; i >= 0; i--) {
        final storeIndexStr = parts.sublist(i).join(':');
        storeIndex = StoreIndex.fromString(storeIndexStr);

        if (storeIndex != null) {
          // Successfully parsed to StoreIndex, the previous part is the index key
          keyPart = parts.sublist(0, i).join(':');
          break;
        }
      }

      if (storeIndex == null) return null;

      final key = _parseKey(keyPart);
      return IndexEntry(
        indexKey: key,
        recordPointer: storeIndex,
      );
    }
  }

  /// Try parsing index key (maybe number, boolean, or string)
  static dynamic _parseKey(String keyStr) {
    // Try parsing as number
    if (keyStr == 'null') return null;

    // Try parsing as integer
    try {
      return int.parse(keyStr);
    } catch (_) {}

    // Try parsing as double
    try {
      return double.parse(keyStr);
    } catch (_) {}

    // Try parsing as boolean
    if (keyStr.toLowerCase() == 'true') return true;
    if (keyStr.toLowerCase() == 'false') return false;

    // Default as string
    return keyStr;
  }

  /// Convert to string (using new format)
  @override
  String toString() {
    return '${indexKey.toString()}|${recordPointer.toString()}';
  }

  /// Convert to string (using old format) for compatibility with old versions
  String toStringOldFormat() {
    return '${indexKey.toString()}:${recordPointer.toString()}';
  }

  /// Get the string representation of the index key
  String getKeyString() {
    return indexKey.toString();
  }

  /// Get the string representation of the record pointer
  String getRecordPointerString() {
    return recordPointer.toString();
  }

  /// Create index entry from composite fields
  static IndexEntry fromCompositeFields(
    List<dynamic> fieldValues,
    StoreIndex recordPointer,
  ) {
    // Convert field values to string and join with :
    final compositeKey = fieldValues.map((v) => v.toString()).join(':');

    return IndexEntry(
      indexKey: compositeKey,
      recordPointer: recordPointer,
    );
  }

  /// Extract composite field values from index entry
  List<String> extractCompositeFields() {
    if (indexKey is String) {
      return (indexKey as String).split(':');
    }
    // If not a composite key, return a list with a single element
    return [indexKey.toString()];
  }

  /// Used to compare two index entries for equality
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! IndexEntry) return false;

    return indexKey.toString() == other.indexKey.toString() &&
        recordPointer.toString() == other.recordPointer.toString();
  }

  @override
  int get hashCode => Object.hash(
        indexKey.toString(),
        recordPointer.toString(),
      );
}

/// Index buffer entry model
/// Used to store index entries in the buffer, including operation type and timestamp
class IndexBufferEntry {
  /// Index entry
  final IndexEntry indexEntry;

  /// Operation type (insert, delete, etc.)
  final BufferOperationType operation;

  /// Entry creation timestamp
  final DateTime timestamp;

  /// Constructor
  const IndexBufferEntry({
    required this.indexEntry,
    required this.operation,
    required this.timestamp,
  });

  /// Create insert operation index buffer entry
  factory IndexBufferEntry.forInsert({
    required dynamic indexKey,
    required StoreIndex recordPointer,
    DateTime? timestamp,
  }) {
    return IndexBufferEntry(
      indexEntry: IndexEntry(
        indexKey: indexKey,
        recordPointer: recordPointer,
      ),
      operation: BufferOperationType.insert,
      timestamp: timestamp ?? DateTime.now(),
    );
  }

  /// Create delete operation index buffer entry
  factory IndexBufferEntry.forDelete({
    required dynamic indexKey,
    required StoreIndex recordPointer,
    DateTime? timestamp,
  }) {
    return IndexBufferEntry(
      indexEntry: IndexEntry(
        indexKey: indexKey,
        recordPointer: recordPointer,
      ),
      operation: BufferOperationType.delete,
      timestamp: timestamp ?? DateTime.now(),
    );
  }

  /// Create index buffer entry from composite field values
  factory IndexBufferEntry.fromCompositeFields({
    required List<dynamic> fieldValues,
    required StoreIndex recordPointer,
    required BufferOperationType operation,
    DateTime? timestamp,
  }) {
    return IndexBufferEntry(
      indexEntry: IndexEntry.fromCompositeFields(fieldValues, recordPointer),
      operation: operation,
      timestamp: timestamp ?? DateTime.now(),
    );
  }

  /// Get the unique key for this entry (used for buffer storage)
  String getUniqueKey() {
    return createUniqueKey(indexEntry.indexKey, indexEntry.recordPointer);
  }

  /// Create a unique key from index key and record pointer
  /// This is a static utility method to standardize key generation
  static String createUniqueKey(dynamic indexKey, dynamic recordPointer) {
    return '$indexKey|$recordPointer';
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'indexKey': indexEntry.indexKey is String ||
              indexEntry.indexKey is num ||
              indexEntry.indexKey is bool
          ? indexEntry.indexKey
          : indexEntry.indexKey.toString(),
      'recordPointer': indexEntry.recordPointer.toString(),
      'operation': operation.toString().split('.').last,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  /// Create from JSON
  factory IndexBufferEntry.fromJson(Map<String, dynamic> json) {
    final recordPointer =
        StoreIndex.fromString(json['recordPointer'] as String);
    if (recordPointer == null) {
      throw const FormatException('Invalid record pointer format');
    }

    return IndexBufferEntry(
      indexEntry: IndexEntry(
        indexKey: json['indexKey'],
        recordPointer: recordPointer,
      ),
      operation: _parseOperationType(json['operation'] as String),
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }

  /// Parse operation type
  static BufferOperationType _parseOperationType(String value) {
    final lowerValue = value.toLowerCase();

    if (lowerValue == 'update') {
      return BufferOperationType.update;
    } else if (lowerValue == 'delete') {
      return BufferOperationType.delete;
    } else if (lowerValue == 'rewrite') {
      return BufferOperationType.rewrite;
    }

    return BufferOperationType.insert;
  }
}
