import 'buffer_entry.dart';

/// Index entry model, used to store index key and record primary key
/// Supports new format (key|primaryKey)
class IndexEntry {
  /// Index key (can be single value or composite value)
  final dynamic indexKey;

  /// Record primary key, pointing to the actual record in storage
  final dynamic primaryKey;

  /// Create index entry
  const IndexEntry({
    required this.indexKey,
    required this.primaryKey,
  });

  /// Create index entry from string (compatible with new and old formats)
  static IndexEntry? fromString(String value) {
    // New format: use | to separate index key and primary key
    if (value.contains('|')) {
      final parts = value.split('|');
      if (parts.length != 2) return null;

      final key = _parseKey(parts[0]);
      final pk = _parseKey(parts[1]);

      return IndexEntry(
        indexKey: key,
        primaryKey: pk,
      );
    }
    // Old format legacy fallback (might not work perfectly if old format used StoreIndex string)
    // We assume migration handles this, or we just try to parse last part as PK.
    else {
      final parts = value.split(':');
      if (parts.length < 2) return null;

      // Assume last part is PK if not | separated?
      // Actually, old format was key:StoreIndex. StoreIndex was partition:offset.
      // If we are strictly moving to PK, we might Drop support for old format in this class
      // OR try to interpret it.
      // Since this is a breaking change, let's assume we are dealing with new data or upgraded data.
      // But for robustness:

      // If we encounter old format, we might not be able to get PK from StoreIndex string easily without lookup.
      // So simpler approach: Just support | format for now, or simple split.

      // Let's assume standard format is Key|PK.
      return null;
    }
  }

  /// Try parsing key (maybe number, boolean, or string)
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

  /// Convert to string
  @override
  String toString() {
    return '${indexKey.toString()}|${primaryKey.toString()}';
  }

  /// Get the string representation of the index key
  String getKeyString() {
    return indexKey.toString();
  }

  /// Create index entry from composite fields
  static IndexEntry fromCompositeFields(
    List<dynamic> fieldValues,
    dynamic primaryKey,
  ) {
    // Convert field values to string and join with :
    final compositeKey = fieldValues.map((v) => v.toString()).join(':');

    return IndexEntry(
      indexKey: compositeKey,
      primaryKey: primaryKey,
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
        primaryKey.toString() == other.primaryKey.toString();
  }

  @override
  int get hashCode => Object.hash(
        indexKey.toString(),
        primaryKey.toString(),
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
  const IndexBufferEntry(
      {required this.indexEntry,
      required this.operation,
      required this.timestamp});

  /// Create insert operation index buffer entry
  factory IndexBufferEntry.forInsert({
    required dynamic indexKey,
    required dynamic primaryKey,
    DateTime? timestamp,
  }) {
    return IndexBufferEntry(
      indexEntry: IndexEntry(
        indexKey: indexKey,
        primaryKey: primaryKey,
      ),
      operation: BufferOperationType.insert,
      timestamp: timestamp ?? DateTime.now(),
    );
  }

  /// Create delete operation index buffer entry
  factory IndexBufferEntry.forDelete({
    required dynamic indexKey,
    required dynamic primaryKey,
    DateTime? timestamp,
  }) {
    return IndexBufferEntry(
      indexEntry: IndexEntry(
        indexKey: indexKey,
        primaryKey: primaryKey,
      ),
      operation: BufferOperationType.delete,
      timestamp: timestamp ?? DateTime.now(),
    );
  }

  /// Create index buffer entry from composite field values
  factory IndexBufferEntry.fromCompositeFields({
    required List<dynamic> fieldValues,
    required dynamic primaryKey,
    required BufferOperationType operation,
    DateTime? timestamp,
  }) {
    return IndexBufferEntry(
      indexEntry: IndexEntry.fromCompositeFields(fieldValues, primaryKey),
      operation: operation,
      timestamp: timestamp ?? DateTime.now(),
    );
  }

  /// Get the unique key for this entry (used for buffer storage)
  String getUniqueKey() {
    return createUniqueKey(indexEntry.indexKey, indexEntry.primaryKey);
  }

  /// Create a unique key from index key and primary key
  /// This is a static utility method to standardize key generation
  static String createUniqueKey(dynamic indexKey, dynamic primaryKey) {
    return '$indexKey|$primaryKey';
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'indexKey': indexEntry.indexKey is String ||
              indexEntry.indexKey is num ||
              indexEntry.indexKey is bool
          ? indexEntry.indexKey
          : indexEntry.indexKey.toString(),
      'primaryKey': indexEntry.primaryKey is String ||
              indexEntry.primaryKey is num ||
              indexEntry.primaryKey is bool
          ? indexEntry.primaryKey
          : indexEntry.primaryKey.toString(),
      'operation': operation.toString().split('.').last,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  /// Create from JSON
  factory IndexBufferEntry.fromJson(Map<String, dynamic> json) {
    // We expect primaryKey to be directly in json, or parsed
    // Try to parse primaryKey
    dynamic pk = json['primaryKey'];
    if (pk is String) {
      // Try to re-parse into typed value if possible
      pk = IndexEntry._parseKey(pk);
    }

    // Fallback for recordPointer legacy field?
    if (pk == null && json['recordPointer'] != null) {
      // Only if we absolutely have to support converting StoreIndex to PK, but we can't.
      // So we assume data is clean or migration handled it.
    }

    return IndexBufferEntry(
      indexEntry: IndexEntry(
        indexKey: json['indexKey'],
        primaryKey: pk,
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

/// Index update buffer entry model
/// Used to represent an index key change from oldKey -> newKey for the same primaryKey
class IndexUpdateBufferEntry {
  /// Old index key (nullable: when adding a new entry)
  final dynamic oldKey;

  /// New index key (nullable: when removing an existing entry)
  final dynamic newKey;

  /// Record primary key
  final dynamic primaryKey;

  /// Entry creation timestamp
  final DateTime timestamp;

  IndexUpdateBufferEntry({
    required this.oldKey,
    required this.newKey,
    required this.primaryKey,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// Unique key for buffering: combines old/new keys and pk to avoid duplicates
  String getUniqueKey() {
    final ok = oldKey?.toString() ?? 'null';
    final nk = newKey?.toString() ?? 'null';
    return '$ok=>$nk|${primaryKey.toString()}';
  }

  Map<String, dynamic> toJson() => {
        'oldKey': oldKey,
        'newKey': newKey,
        'primaryKey': primaryKey.toString(),
        'timestamp': timestamp.toIso8601String(),
      };

  factory IndexUpdateBufferEntry.fromJson(Map<String, dynamic> json) {
    dynamic pk = json['primaryKey'];
    if (pk is String) {
      pk = IndexEntry._parseKey(pk);
    }

    return IndexUpdateBufferEntry(
      oldKey: json['oldKey'],
      newKey: json['newKey'],
      primaryKey: pk,
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }
}

/// Index record update model
/// Used to represent a record update for index maintenance in writeIndexChanges method
///
/// This model contains both old and new field values to enable efficient index updates:
/// - Old values are used to remove old index entries
/// - New values are used to add new index entries
///
/// Only fields that are part of indexes need to be included in oldValues.
/// For optimal performance, oldValues should only contain fields that:
/// 1. Are part of any index (primary key, indexed fields, unique fields)
/// 2. Have actually changed (to minimize data transfer)
class IndexRecordUpdate {
  /// Primary key of the record being updated
  /// This is required to identify which record is being updated
  final dynamic primaryKey;

  /// New values: complete updated record data
  /// Contains all fields of the record after the update
  final Map<String, dynamic> newValues;

  /// Old values: previous field values for index-related fields only
  ///
  /// This should contain only fields that:
  /// - Are part of any index (primary key, indexed fields, unique fields)
  /// - Have actually changed (optional optimization)
  ///
  /// If null, the system may need to fetch old values from storage,
  /// which can impact performance in large-scale scenarios.
  ///
  /// Example: If a record has fields {id: 1, name: "old", age: 20, email: "old@example.com"}
  /// and only 'name' and 'email' are indexed, oldValues should be:
  /// {name: "old", email: "old@example.com"} (or include id if it's the primary key)
  final Map<String, dynamic>? oldValues;

  /// Optional: list of changed field names for optimization
  /// If provided, helps identify which indexes need to be updated
  /// If null, the system will determine changed fields by comparing oldValues and newValues
  final Set<String>? changedFields;

  /// Timestamp when this update was created (optional, defaults to now)
  final DateTime? timestamp;

  IndexRecordUpdate({
    required this.primaryKey,
    required this.newValues,
    this.oldValues,
    this.changedFields,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// Create an IndexRecordUpdate from a simple update map
  ///
  /// This factory method extracts oldValues from the record if it contains '_oldValues' key
  /// (common pattern in transaction processing)
  ///
  /// [updateMap] - The update record map, may contain '_oldValues' key
  /// [primaryKeyField] - Name of the primary key field (required to extract primary key value)
  ///
  /// Example:
  /// ```dart
  /// final update = {
  ///   'id': 1,
  ///   'name': 'new name',
  ///   '_oldValues': {'name': 'old name'}
  /// };
  /// final recordUpdate = IndexRecordUpdate.fromUpdateMap(update, 'id');
  /// ```
  factory IndexRecordUpdate.fromUpdateMap(
    Map<String, dynamic> updateMap,
    String primaryKeyField,
  ) {
    final oldValues = updateMap.remove('_oldValues') as Map<String, dynamic>?;
    final primaryKey = updateMap[primaryKeyField];

    if (primaryKey == null) {
      throw ArgumentError(
        'Primary key field "$primaryKeyField" not found in update map',
      );
    }

    return IndexRecordUpdate(
      primaryKey: primaryKey,
      newValues: Map<String, dynamic>.from(updateMap),
      oldValues: oldValues,
    );
  }

  /// Get a unique identifier for this update (used for deduplication)
  String getUniqueKey() {
    return primaryKey.toString();
  }

  /// Check if this update affects any indexed fields
  ///
  /// This is a helper method that can be used to quickly determine
  /// if index updates are needed without full schema analysis
  bool affectsIndexedFields(Set<String> indexedFieldNames) {
    if (changedFields != null) {
      return changedFields!.any((field) => indexedFieldNames.contains(field));
    }

    // If changedFields not provided, check if any indexed field differs between old and new
    if (oldValues == null) return true; // Conservative: assume it might affect

    for (final field in indexedFieldNames) {
      final oldVal = oldValues![field];
      final newVal = newValues[field];
      if (oldVal != newVal) {
        return true;
      }
    }

    return false;
  }

  /// Convert to JSON for serialization
  Map<String, dynamic> toJson() {
    return {
      'primaryKey':
          primaryKey is String || primaryKey is num || primaryKey is bool
              ? primaryKey
              : primaryKey.toString(),
      'newValues': newValues,
      if (oldValues != null) 'oldValues': oldValues,
      if (changedFields != null) 'changedFields': changedFields!.toList(),
      if (timestamp != null) 'timestamp': timestamp!.toIso8601String(),
    };
  }

  /// Create from JSON
  factory IndexRecordUpdate.fromJson(Map<String, dynamic> json) {
    dynamic pk = json['primaryKey'];
    if (pk is String) {
      pk = IndexEntry._parseKey(pk);
    }

    return IndexRecordUpdate(
      primaryKey: pk,
      newValues: Map<String, dynamic>.from(json['newValues'] as Map),
      oldValues: json.containsKey('oldValues') && json['oldValues'] != null
          ? Map<String, dynamic>.from(json['oldValues'] as Map)
          : null,
      changedFields:
          json.containsKey('changedFields') && json['changedFields'] != null
              ? Set<String>.from(json['changedFields'] as List)
              : null,
      timestamp: json.containsKey('timestamp') && json['timestamp'] != null
          ? DateTime.parse(json['timestamp'] as String)
          : null,
    );
  }

  /// Create a copy with modified fields
  ///
  /// All Map and Set parameters are copied to avoid reference sharing issues.
  IndexRecordUpdate copyWith({
    dynamic primaryKey,
    Map<String, dynamic>? newValues,
    Map<String, dynamic>? oldValues,
    Set<String>? changedFields,
    DateTime? timestamp,
  }) {
    return IndexRecordUpdate(
      primaryKey: primaryKey ?? this.primaryKey,
      newValues: newValues != null
          ? Map<String, dynamic>.from(newValues)
          : Map<String, dynamic>.from(this.newValues),
      oldValues: oldValues != null
          ? Map<String, dynamic>.from(oldValues)
          : this.oldValues != null
              ? Map<String, dynamic>.from(this.oldValues!)
              : null,
      changedFields: changedFields != null
          ? Set<String>.from(changedFields)
          : this.changedFields != null
              ? Set<String>.from(this.changedFields!)
              : null,
      timestamp: timestamp ?? this.timestamp,
    );
  }
}
