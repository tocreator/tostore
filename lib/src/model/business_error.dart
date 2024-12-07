/// 业务错误类型
enum BusinessErrorType {
  // 开发时错误
  schemaError, // 表结构错误
  fieldError, // 字段错误
  typeError, // 类型错误

  // 运行时错误
  duplicateKey, // 主键重复
  duplicateValue, // 唯一值重复
  notFound, // 记录不存在
  invalidData, // 数据无效
}

/// 业务错误
class BusinessError implements Exception {
  final String message;
  final BusinessErrorType type;
  final dynamic data;

  const BusinessError(
    this.message, {
    required this.type,
    this.data,
  });

  /// 是否为开发时错误
  bool get isDevelopmentError =>
      type == BusinessErrorType.schemaError ||
      type == BusinessErrorType.fieldError ||
      type == BusinessErrorType.typeError;

  @override
  String toString() => message;
}
