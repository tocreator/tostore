/// Standardized information about a unique constraint violation.
class UniqueViolation {
  /// Name of the table where the violation occurred.
  final String tableName;

  /// List of fields that form the unique constraint.
  final List<String> fields;

  /// The actual value that caused the violation (human-readable, not internal key).
  final dynamic value;

  /// Internal index name (optional).
  final String? indexName;

  /// The primary key of the existing record that caused the violation (optional).
  /// This is useful for resolving record identities during upsert or batch updates.
  final String? existingPrimaryKey;

  UniqueViolation({
    required this.tableName,
    required this.fields,
    required this.value,
    this.indexName,
    this.existingPrimaryKey,
  });

  /// Returns a user-friendly message describing the violation,
  /// including the field names and the conflicting value.
  String get message {
    final bool hasFields = fields.isNotEmpty;
    final String fieldsStr = hasFields ? fields.join(', ') : '';

    // Optional fields segment, only shown when we know the fields that participate in the constraint
    final String fieldsSegment = hasFields ? " ($fieldsStr)" : '';

    String msg =
        "Unique constraint violation on '$tableName'$fieldsSegment with value: $value";
    if (existingPrimaryKey != null) {
      msg += " (Existing PK: $existingPrimaryKey)";
    }
    return msg;
  }

  @override
  String toString() => message;
}
