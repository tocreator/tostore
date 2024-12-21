/// business error type
enum BusinessErrorType {
  // development error
  schemaError, // schema error
  fieldError, // field error
  typeError, // type error

  // runtime error
  duplicateKey, // duplicate key
  duplicateValue, // duplicate value
  notFound, // not found
  invalidData, // invalid data
}

/// business error
class BusinessError implements Exception {
  final String message;
  final BusinessErrorType type;
  final dynamic data;

  const BusinessError(
    this.message, {
    required this.type,
    this.data,
  });

  /// whether it is a development error
  bool get isDevelopmentError =>
      type == BusinessErrorType.schemaError ||
      type == BusinessErrorType.fieldError ||
      type == BusinessErrorType.typeError;

  @override
  String toString() => message;
}
