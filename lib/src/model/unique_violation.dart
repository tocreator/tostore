import 'result_type.dart';
import 'table_identity.dart';

/// Standardized information about a unique constraint violation.
class UniqueViolation {
  /// Name of the table where the violation occurred.
  final String tableName;

  /// List of fields that form the unique constraint.
  final List<String> fields;

  /// The actual value that caused the violation (human-readable, not internal key).
  final dynamic value;

  /// User-visible index name (optional, e.g. `uniq_email` or `pk`).
  final IndexName? indexName;

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

  /// Whether this violation is on the primary-key index (`pk`).
  bool get isPrimaryKeyConflict => indexName == 'pk';

  /// [ResultType] to surface on [DbResult] / [ConstraintStatus].
  ResultType get constraintResultType => isPrimaryKeyConflict
      ? ResultType.bizPrimaryKeyViolation
      : ResultType.bizUniqueViolation;

  /// Returns a user-friendly message describing the violation,
  /// including the field names and the conflicting value.
  String get message {
    final bool hasFields = fields.isNotEmpty;
    final String fieldsStr = hasFields ? fields.join(', ') : '';

    // Optional fields segment, only shown when we know the fields that participate in the constraint
    final String fieldsSegment = hasFields ? " ($fieldsStr)" : '';

    if (isPrimaryKeyConflict) {
      String msg =
          "Primary key conflict on '$tableName'$fieldsSegment with value: $value";
      if (existingPrimaryKey != null) {
        msg += " (Existing PK: $existingPrimaryKey)";
      }
      return msg;
    }

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
