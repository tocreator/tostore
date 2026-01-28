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

  UniqueViolation({
    required this.tableName,
    required this.fields,
    required this.value,
    this.indexName,
  });

  /// Returns a user-friendly message describing the violation,
  /// including the field names and the conflicting value.
  String get message {
    final fieldsStr = fields.join(', ');
    return "Unique constraint violation on '$tableName' ($fieldsStr) with value: $value";
  }

  @override
  String toString() => message;
}
