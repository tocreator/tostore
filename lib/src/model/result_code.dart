/// Database operation result status code
/// 0 represents complete success
/// Positive numbers represent partial success or special success status
/// -1 represents unknown error
/// -2 ~ -30 represent common business errors
/// -90 ~ -99 represent system errors
enum ResultCode {
  /// Operation successful
  success(0, 'Operation successful'),

  /// Partially successful operation
  partialSuccess(1, 'Partially successful'),

  /// Unknown error
  unknown(-1, 'Unknown error'),

  // Data constraint errors (-2 ~ -10)
  /// Unique constraint violation
  uniqueViolation(-2, 'Unique constraint violation'),

  /// Primary key conflict
  primaryKeyViolation(-3, 'Primary key conflict'),

  /// Foreign key constraint violation
  foreignKeyViolation(-4, 'Foreign key constraint violation'),

  /// Not null constraint violation
  notNullViolation(-5, 'Not null constraint violation'),

  /// Data validation failed
  validationFailed(-6, 'Data validation failed'),

  // Resource errors (-11 ~ -20)
  /// Resource does not exist
  notFound(-11, 'Resource does not exist'),

  /// Table already exists
  tableExists(-12, 'Table already exists'),

  /// Field already exists
  fieldExists(-13, 'Field already exists'),

  /// Index already exists
  indexExists(-14, 'Index already exists'),

  // System errors (-90 ~ -99)
  /// System error
  ioError(-90, 'System error'),

  /// Database error
  dbError(-91, 'Database error'),

  /// Operation timeout
  timeout(-92, 'Operation timeout');

  /// Status code value
  final int code;

  /// Status code description
  final String message;

  /// Constructor
  const ResultCode(this.code, this.message);

  /// Get the corresponding enum from the status code value
  static ResultCode fromCode(int code) {
    return ResultCode.values.firstWhere(
      (e) => e.code == code,
      orElse: () => ResultCode.unknown,
    );
  }

  /// Determine if it is a successful status code
  bool get isSuccess => this == ResultCode.success;

  /// Determine if it is a partially successful operation
  bool get isPartialSuccess => this == ResultCode.partialSuccess;

  /// Determine if it is an error status (negative number)
  bool get isError => code < 0;

  /// Determine if it is a constraint error
  bool get isConstraintError =>
      this == uniqueViolation ||
      this == primaryKeyViolation ||
      this == foreignKeyViolation ||
      this == notNullViolation;

  /// Determine if it is a system or database error
  bool get isSystemError => code <= -90;
}
