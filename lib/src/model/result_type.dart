/// Database operation result status type
/// 0 represents complete success
/// Class Code represents the first 2 digits of the 5-digit code
enum ResultType {
  /// Operation successful
  success(0, 'SUCCESS', 'Operation successful'),

  /// Invalid argument - format error
  invalidArgumentFormat(
      40001, 'INVALID_ARGUMENT_FORMAT', 'Argument format error'),

  /// Invalid argument - type mismatch
  invalidArgumentType(40002, 'INVALID_ARGUMENT_TYPE', 'Argument type mismatch'),

  /// Cursor pagination conflict / unsupported
  invalidCursorPagination(40201, 'INVALID_CURSOR_PAGINATION',
      'Cursor pagination and offset are mutually exclusive'),

  /// Cursor does not match target table
  invalidCursorTable(
      40202, 'INVALID_CURSOR_TABLE', 'Cursor does not match target table'),

  /// Mismatched cursor query signature hash
  invalidCursorSignature(
      40203, 'INVALID_CURSOR_SIGNATURE', 'Mismatched cursor signature'),

  /// Cursor orderBy fields or direction mismatch
  invalidCursorOrderBy(40204, 'INVALID_CURSOR_ORDERBY',
      'Cursor orderBy configuration invalid or mismatched'),

  /// Cursor token mode mismatch
  invalidCursorMode(40205, 'INVALID_CURSOR_MODE', 'Cursor token mode mismatch'),

  /// Invalid cursor payload
  invalidCursorPayload(
      40206, 'INVALID_CURSOR_PAYLOAD', 'Invalid cursor payload'),

  /// Query select/selectAgg field type invalid
  invalidQuerySelectField(40301, 'INVALID_QUERY_SELECT_FIELD',
      'Query select field must be String or QueryAggregation'),

  /// Auto foreign key join cannot resolve relationship
  invalidQueryForeignKeyJoin(40302, 'INVALID_QUERY_FOREIGN_KEY_JOIN',
      'No foreign key relationship for auto join'),

  /// Query field alias format invalid
  invalidQueryFieldAlias(
      40303, 'INVALID_QUERY_FIELD_ALIAS', 'Query field alias format invalid'),

  /// Read permission denied
  permissionDeniedRead(
      41001, 'PERMISSION_DENIED_READ', 'Read permission denied'),

  /// Write permission denied
  permissionDeniedWrite(
      41002, 'PERMISSION_DENIED_WRITE', 'Write permission denied'),

  /// Not null constraint violation
  notNullViolation(
      42001, 'VALIDATION_FAILED_NOT_NULL', 'Not null constraint violation'),

  /// Type cast failed
  validationFailedTypeCast(
      42002, 'VALIDATION_FAILED_TYPE_CAST', 'Type cast failed'),

  /// Data validation failed (generic)
  validationFailed(42000, 'VALIDATION_FAILED', 'Data validation failed'),

  /// Invalid table schema definition
  invalidSchema(43000, 'INVALID_SCHEMA', 'Invalid table schema definition'),

  /// Table name validation failed
  invalidSchemaTableName(
      43001, 'INVALID_SCHEMA_TABLE_NAME', 'Table name validation failed'),

  /// Field name validation failed
  invalidSchemaFieldName(
      43002, 'INVALID_SCHEMA_FIELD_NAME', 'Field name validation failed'),

  /// Primary key validation failed
  invalidSchemaPrimaryKey(
      43003, 'INVALID_SCHEMA_PRIMARY_KEY', 'Primary key validation failed'),

  /// Index count validation failed
  invalidSchemaIndexLimit(
      43004, 'INVALID_SCHEMA_INDEX_LIMIT', 'Index count validation failed'),

  /// Table already exists
  tableExists(43005, 'INVALID_SCHEMA_TABLE_EXISTS', 'Table already exists'),

  /// Field already exists
  fieldExists(43006, 'INVALID_SCHEMA_FIELD_EXISTS', 'Field already exists'),

  /// Index already exists
  indexExists(43007, 'INVALID_SCHEMA_INDEX_EXISTS', 'Index already exists'),

  /// Foreign key definition invalid
  invalidSchemaForeignKey(
      43008, 'INVALID_SCHEMA_FOREIGN_KEY', 'Foreign key definition invalid'),

  /// Global/Space-specific boundary mismatch
  invalidSchemaSpaceMismatch(43009, 'INVALID_SCHEMA_SPACE_MISMATCH',
      'Global/Space-specific boundary mismatch'),

  /// Migration for table requires data modification and was not explicitly allowed
  migrationNotAllowedWithData(43010, 'MIGRATION_NOT_ALLOWED_WITH_DATA',
      'Migration requires data modification and was not explicitly allowed'),

  /// Unsupported or high-risk data type change for field
  migrationUnsafeTypeConversion(43011, 'MIGRATION_UNSAFE_TYPE_CONVERSION',
      'Unsupported data type change for field'),

  /// Batch migration execution failed
  migrationBatchExecutionFailed(43012, 'MIGRATION_BATCH_EXECUTION_FAILED',
      'Batch migration execution failed'),

  /// Cannot add non-nullable field without a default value to non-empty table
  migrationCannotAddNonNullField(43013, 'MIGRATION_CANNOT_ADD_NON_NULL_FIELD',
      'Cannot add non-nullable field without a default value'),

  /// Changing field from nullable to non-nullable is not allowed on non-empty table
  migrationNullableToNonNullNotAllowed(
      43014,
      'MIGRATION_NULLABLE_TO_NON_NULL_NOT_ALLOWED',
      'Changing field from nullable to non-nullable is not allowed'),

  /// Changing field from non-unique to unique is not allowed on non-empty table
  migrationUniqueTighteningNotAllowed(
      43015,
      'MIGRATION_UNIQUE_TIGHTENING_NOT_ALLOWED',
      'Changing field from non-unique to unique is not allowed'),

  /// TTL configuration validation failed
  invalidSchemaTtlConfig(43016, 'INVALID_SCHEMA_TTL_CONFIG',
      'TTL configuration validation failed'),

  /// Duplicate field name in table schema
  invalidSchemaDuplicateFieldName(43017, 'INVALID_SCHEMA_DUPLICATE_FIELD_NAME',
      'Duplicate field name in table schema'),

  /// Index references non-existent field
  invalidSchemaIndexField(43018, 'INVALID_SCHEMA_INDEX_FIELD',
      'Index references non-existent field'),

  /// Table not found
  notFoundTable(44001, 'NOT_FOUND_TABLE', 'Table not found'),

  /// Resource does not exist / Record not found
  notFound(44002, 'NOT_FOUND_RECORD', 'Resource does not exist'),

  /// Index not found
  notFoundIndex(44003, 'NOT_FOUND_INDEX', 'Index not found'),

  /// Primary key conflict
  primaryKeyViolation(
      45001, 'CONSTRAINT_VIOLATION_PRIMARY_KEY', 'Primary key conflict'),

  /// Unique constraint violation
  uniqueViolation(
      45002, 'CONSTRAINT_VIOLATION_UNIQUE', 'Unique constraint violation'),

  /// Foreign key constraint violation
  foreignKeyViolation(45003, 'CONSTRAINT_VIOLATION_FOREIGN_KEY',
      'Foreign key constraint violation'),

  /// Check constraint violation
  constraintViolationCheck(
      45004, 'CONSTRAINT_VIOLATION_CHECK', 'Check constraint violation'),

  /// Referenced parent key does not exist
  foreignKeyParentNotExist(
      45005,
      'CONSTRAINT_VIOLATION_FOREIGN_KEY_PARENT_NOT_EXIST',
      'Referenced parent key does not exist'),

  /// Delete or update restricted by child records
  foreignKeyChildRestrict(
      45006,
      'CONSTRAINT_VIOLATION_FOREIGN_KEY_CHILD_RESTRICT',
      'Delete or update restricted by child records'),

  /// Incomplete composite foreign key values
  foreignKeyCompositeMismatch(
      45007,
      'CONSTRAINT_VIOLATION_FOREIGN_KEY_COMPOSITE_MISMATCH',
      'Incomplete composite foreign key values'),

  /// Foreign key type mismatch
  foreignKeyTypeMismatch(
      45008,
      'CONSTRAINT_VIOLATION_FOREIGN_KEY_TYPE_MISMATCH',
      'Foreign key type mismatch'),

  /// Transaction aborted
  transactionErrorAborted(
      50001, 'TRANSACTION_ERROR_ABORTED', 'Transaction aborted'),

  /// Transaction conflict
  transactionErrorConflict(
      50002, 'TRANSACTION_ERROR_CONFLICT', 'Transaction conflict'),

  /// Lock acquisition timeout
  timeoutLockAcquisition(
      51001, 'TIMEOUT_LOCK_ACQUISITION', 'Lock acquisition timeout'),

  /// Query execution timeout / Operation timeout
  timeout(51000, 'TIMEOUT', 'Operation timeout'),

  /// Memory resource exhausted
  resourceExhaustedMemory(
      52001, 'RESOURCE_EXHAUSTED_MEMORY', 'Memory resource exhausted'),

  /// Large-scale operation requires details bypass to prevent OOM
  largeScaleOperationRequiredBypass(
      52002,
      'LARGE_SCALE_OPERATION_REQUIRED_BYPASS',
      'Large-scale operation requires skipping result details to prevent OOM'),

  /// Disk space exhausted / System resources exhausted (Generic)
  resourceExhausted(52000, 'RESOURCE_EXHAUSTED', 'System resources exhausted'),

  /// File read error
  ioErrorFileRead(53001, 'IO_ERROR_FILE_READ', 'File read error'),

  /// File write error
  ioErrorFileWrite(53002, 'IO_ERROR_FILE_WRITE', 'File write error'),

  /// System IO error (Generic)
  ioError(53000, 'IO_ERROR', 'System IO error'),

  /// Engine version incompatible
  dbErrorEngineIncompatible(
      54001, 'DB_ERROR_ENGINE_INCOMPATIBLE', 'Engine version incompatible'),

  /// Database corruption
  dbErrorCorruption(54002, 'DB_ERROR_CORRUPTION', 'Database corruption'),

  /// Database error (Generic)
  dbError(54000, 'DB_ERROR', 'Database error'),

  /// Unknown system error
  unknown(99001, 'UNKNOWN_ERROR', 'Unknown error');

  /// Status code value
  final int code;

  /// Semantic state identifier key
  final String codeKey;

  /// Default status description
  final String message;

  /// Constructor
  const ResultType(this.code, this.codeKey, this.message);

  /// Get the corresponding enum from the status code value
  static ResultType fromCode(int code) {
    for (final val in ResultType.values) {
      if (val.code == code) {
        return val;
      }
    }
    return ResultType.unknown;
  }

  /// Get the corresponding enum from the code key
  static ResultType fromCodeKey(String codeKey) {
    for (final val in ResultType.values) {
      if (val.codeKey == codeKey) {
        return val;
      }
    }
    return ResultType.unknown;
  }

  /// Determine if it is a constraint error
  bool get isConstraintError =>
      (code >= 45000 && code < 46000) || this == ResultType.notNullViolation;
}
