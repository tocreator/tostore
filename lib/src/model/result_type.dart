/// Database operation result status type
/// 0 represents complete success
/// Class Code represents the first 2 digits of the 5-digit code
enum ResultType {
  /// Operation successful
  success(0, 'SUCCESS', 'Operation successful'),

  // "BIZ_" - Business Error (10-19)
  bizValidationFailed(10000, 'BIZ_VALIDATION_FAILED', 'Data validation failed'),
  bizNotNullViolation(
      10001, 'BIZ_NOT_NULL_VIOLATION', 'Not null constraint violation'),
  bizTypeCastFailed(10002, 'BIZ_VALIDATION_TYPE_CAST', 'Type cast failed'),
  bizPrimaryKeyViolation(
      11001, 'BIZ_CONSTRAINT_PRIMARY_KEY', 'Primary key conflict'),
  bizUniqueViolation(
      11002, 'BIZ_CONSTRAINT_UNIQUE', 'Unique constraint violation'),
  bizForeignKeyViolation(
      11003, 'BIZ_CONSTRAINT_FOREIGN_KEY', 'Foreign key constraint violation'),
  bizCheckViolation(
      11004, 'BIZ_CONSTRAINT_CHECK', 'Check constraint violation'),
  bizForeignKeyParentNotExist(
      11005,
      'BIZ_CONSTRAINT_FOREIGN_KEY_PARENT_NOT_EXIST',
      'Referenced parent key does not exist'),
  bizForeignKeyChildRestrict(11006, 'BIZ_CONSTRAINT_FOREIGN_KEY_CHILD_RESTRICT',
      'Delete or update restricted by child records'),
  bizForeignKeyCompositeMismatch(
      11007,
      'BIZ_CONSTRAINT_FOREIGN_KEY_COMPOSITE_MISMATCH',
      'Incomplete composite foreign key values'),
  bizForeignKeyTypeMismatch(11008, 'BIZ_CONSTRAINT_FOREIGN_KEY_TYPE_MISMATCH',
      'Foreign key type mismatch'),
  bizValueExceedsMaxLength(
      11009, 'BIZ_CONSTRAINT_MAX_LENGTH', 'Value exceeds max length'),
  bizValueLessThanMinLength(
      11010, 'BIZ_CONSTRAINT_MIN_LENGTH', 'Value is less than min length'),
  bizValueLessThanMinValue(
      11011, 'BIZ_CONSTRAINT_MIN_VALUE', 'Value is less than min value'),
  bizValueExceedsMaxValue(
      11012, 'BIZ_CONSTRAINT_MAX_VALUE', 'Value exceeds max value'),
  bizRecordNotFound(12002, 'BIZ_NOT_FOUND_RECORD', 'Resource does not exist'),

  // "DEV_" - Developer Error (20-49)
  devInvalidArgumentFormat(
      20001, 'DEV_INVALID_ARGUMENT_FORMAT', 'Argument format error'),
  devInvalidArgumentType(
      20002, 'DEV_INVALID_ARGUMENT_TYPE', 'Argument type mismatch'),
  devInvalidArgumentMissing(
      20003, 'DEV_INVALID_ARGUMENT_MISSING', 'Required argument is missing'),
  devInvalidPrimaryKeyFormat(
      20005, 'DEV_INVALID_PRIMARY_KEY_FORMAT', 'Invalid primary key format'),
  devIndexOutOfBounds(
      20007, 'DEV_INDEX_OUT_OF_BOUNDS', 'Index or range is out of bounds'),
  devUnsupportedOperation(20008, 'DEV_UNSUPPORTED_OPERATION',
      'Operation is not supported in the current context'),
  devVectorDimensionMismatch(
      20010, 'DEV_VECTOR_DIMENSION_MISMATCH', 'Vector dimensions mismatch'),
  devIndexFieldMissing(20011, 'DEV_INDEX_FIELD_MISSING',
      'Required index field is missing in record'),
  devInvalidCursorPagination(20201, 'DEV_INVALID_CURSOR_PAGINATION',
      'Cursor pagination and offset are mutually exclusive'),
  devInvalidCursorTable(
      20202, 'DEV_INVALID_CURSOR_TABLE', 'Cursor does not match target table'),
  devInvalidCursorSignature(
      20203, 'DEV_INVALID_CURSOR_SIGNATURE', 'Mismatched cursor signature'),
  devInvalidCursorOrderBy(20204, 'DEV_INVALID_CURSOR_ORDERBY',
      'Cursor orderBy configuration invalid or mismatched'),
  devInvalidCursorMode(
      20205, 'DEV_INVALID_CURSOR_MODE', 'Cursor token mode mismatch'),
  devInvalidCursorPayload(
      20206, 'DEV_INVALID_CURSOR_PAYLOAD', 'Invalid cursor payload'),
  devInvalidQuerySelectField(20301, 'DEV_INVALID_QUERY_SELECT_FIELD',
      'Query select field must be String or QueryAggregation'),
  devInvalidQueryForeignKeyJoin(20302, 'DEV_INVALID_QUERY_FOREIGN_KEY_JOIN',
      'No foreign key relationship for auto join'),
  devInvalidQueryFieldAlias(20303, 'DEV_INVALID_QUERY_FIELD_ALIAS',
      'Query field alias format invalid'),
  devInvalidExpression(20304, 'DEV_INVALID_EXPRESSION',
      'Invalid expression configuration or execution'),
  devTableNotFound(22001, 'DEV_NOT_FOUND_TABLE', 'Table not found'),
  devIndexNotFound(22003, 'DEV_NOT_FOUND_INDEX', 'Index not found'),
  devSpaceNotFound(22004, 'DEV_NOT_FOUND_SPACE', 'Space not found'),
  devFieldNotFound(22005, 'DEV_NOT_FOUND_FIELD', 'Field not found'),
  devLargeScaleOperationBypassRequired(
      23001,
      'DEV_LARGE_SCALE_OPERATION_REQUIRED_BYPASS',
      'Large-scale operation requires skipping result details to prevent OOM'),
  devEngineIncompatible(
      24001, 'DEV_ENGINE_INCOMPATIBLE', 'Engine version incompatible',
      isCritical: true),
  devInvalidSchema(
      30000, 'DEV_INVALID_SCHEMA', 'Invalid table schema definition'),
  devInvalidSchemaTableName(
      30001, 'DEV_INVALID_SCHEMA_TABLE_NAME', 'Table name validation failed'),
  devInvalidSchemaFieldName(
      30002, 'DEV_INVALID_SCHEMA_FIELD_NAME', 'Field name validation failed'),
  devInvalidSchemaPrimaryKey(
      30003, 'DEV_INVALID_SCHEMA_PRIMARY_KEY', 'Primary key validation failed'),
  devInvalidSchemaIndexLimit(
      30004, 'DEV_INVALID_SCHEMA_INDEX_LIMIT', 'Index count validation failed'),
  devSchemaTableExists(
      30005, 'DEV_SCHEMA_TABLE_EXISTS', 'Table already exists'),
  devSchemaFieldExists(
      30006, 'DEV_SCHEMA_FIELD_EXISTS', 'Field already exists'),
  devSchemaIndexExists(
      30007, 'DEV_SCHEMA_INDEX_EXISTS', 'Index already exists'),
  devInvalidSchemaForeignKey(30008, 'DEV_INVALID_SCHEMA_FOREIGN_KEY',
      'Foreign key definition invalid'),
  devInvalidSchemaSpaceMismatch(30009, 'DEV_INVALID_SCHEMA_SPACE_MISMATCH',
      'Global/Space-specific boundary mismatch'),
  devMigrationNotAllowedWithData(30010, 'DEV_MIGRATION_NOT_ALLOWED_WITH_DATA',
      'Migration requires data modification and was not explicitly allowed'),
  devMigrationUnsafeTypeConversion(
      30011,
      'DEV_MIGRATION_UNSAFE_TYPE_CONVERSION',
      'Unsupported data type change for field'),
  devMigrationCannotAddNonNullField(
      30013,
      'DEV_MIGRATION_CANNOT_ADD_NON_NULL_FIELD',
      'Cannot add non-nullable field without a default value'),
  devMigrationNullableToNonNullNotAllowed(
      30014,
      'DEV_MIGRATION_NULLABLE_TO_NON_NULL_NOT_ALLOWED',
      'Changing field from nullable to non-nullable is not allowed'),
  devMigrationUniqueTighteningNotAllowed(
      30015,
      'DEV_MIGRATION_UNIQUE_TIGHTENING_NOT_ALLOWED',
      'Changing field from non-unique to unique is not allowed'),
  devInvalidSchemaTtlConfig(30016, 'DEV_INVALID_SCHEMA_TTL_CONFIG',
      'TTL configuration validation failed'),
  devInvalidSchemaDuplicateFieldName(
      30017,
      'DEV_INVALID_SCHEMA_DUPLICATE_FIELD_NAME',
      'Duplicate field name in table schema'),
  devInvalidSchemaIndexField(30018, 'DEV_INVALID_SCHEMA_INDEX_FIELD',
      'Index references non-existent field'),

  // "SYS_" - System Error (50-79)
  sysTransactionAborted(
      50001, 'SYS_TRANSACTION_ABORTED', 'Transaction aborted'),
  sysTransactionConflict(
      50002, 'SYS_TRANSACTION_CONFLICT', 'Transaction conflict'),
  sysTransactionLimitExceeded(50003, 'SYS_TRANSACTION_LIMIT_EXCEEDED',
      'Transaction exceeds the safe in-memory limit'),
  sysMigrationBatchExecutionFailed(
      50004,
      'SYS_MIGRATION_BATCH_EXECUTION_FAILED',
      'Batch migration execution failed',
      isCritical: true),
  sysTimeoutLockAcquisition(
      51001, 'SYS_TIMEOUT_LOCK_ACQUISITION', 'Lock acquisition timeout'),
  sysTimeout(51002, 'SYS_TIMEOUT', 'Operation timeout'),
  sysDbClosed(51003, 'SYS_DB_CLOSED', 'Database is closed'),
  sysResourceExhaustedMemory(
      52001, 'SYS_RESOURCE_EXHAUSTED_MEMORY', 'Memory resource exhausted',
      isCritical: true),
  sysResourceExhausted(
      52002, 'SYS_RESOURCE_EXHAUSTED', 'System resources exhausted',
      isCritical: true),
  sysIoNotFound(
      53001, 'SYS_IO_NOT_FOUND', 'Physical file or path does not exist'),
  sysIoPermissionDenied(
      53002, 'SYS_IO_PERMISSION_DENIED', 'Permission denied for file access'),
  sysIoDiskFull(
      53003, 'SYS_IO_DISK_FULL', 'Disk full or storage quota exceeded',
      isCritical: true),
  sysIoFileLocked(53004, 'SYS_IO_FILE_LOCKED',
      'File is locked or in use by another process'),
  sysIoDeviceFault(
      53005, 'SYS_IO_DEVICE_FAULT', 'Storage device or media fault',
      isCritical: true),
  sysIoWebStorageUnavailable(53006, 'SYS_IO_WEB_STORAGE_UNAVAILABLE',
      'Web IndexedDB or storage is unavailable'),
  sysBackupCorrupted(53007, 'SYS_BACKUP_CORRUPTED',
      'Backup package is corrupted or missing metadata'),
  sysIoDataCorrupted(53008, 'SYS_IO_DATA_CORRUPTED',
      'Database data file is corrupted or checksum failed',
      isCritical: true),
  sysInvalidDataFormat(53009, 'SYS_INVALID_DATA_FORMAT',
      'Data stream formatting or parsing failed'),
  sysIoGeneric(53099, 'SYS_IO_GENERIC', 'Generic system IO error'),

  // "ENG_" - Engine Error (99)
  engError(99001, 'ENG_ERROR', 'Engine error');

  /// Status code value
  final int code;

  /// Semantic state identifier key
  final String codeKey;

  /// Default status description
  final String message;

  /// Whether the error is a critical system error requiring manual intervention
  final bool isCritical;

  /// Constructor
  const ResultType(this.code, this.codeKey, this.message,
      {this.isCritical = false});

  /// Get the corresponding enum from the status code value
  static ResultType fromCode(int code) {
    for (final val in ResultType.values) {
      if (val.code == code) {
        return val;
      }
    }
    return ResultType.engError;
  }

  /// Get the corresponding enum from the code key
  static ResultType fromCodeKey(String codeKey) {
    for (final val in ResultType.values) {
      if (val.codeKey == codeKey) {
        return val;
      }
    }
    return ResultType.engError;
  }

  /// Determine if it is a constraint error
  bool get isConstraintError =>
      code == 10001 || (code >= 11000 && code < 12000);

  /// Whether the error belongs to Business Error (10-19)
  bool get isBusinessError => code >= 10000 && code < 20000;

  /// Whether the error belongs to Developer Error (20-49)
  bool get isDeveloperError => code >= 20000 && code < 50000;

  /// Whether the error belongs to System Error (50-79)
  bool get isSystemError => code >= 50000 && code < 80000;

  /// Whether the error belongs to Engine Error (99)
  bool get isEngineError => code >= 99000 && code < 100000;

  /// Whether the error is a critical system error requiring manual intervention
  /// (e.g., out of memory, disk full, critical migration failures)
  bool get isCriticalError => isCritical;
}
