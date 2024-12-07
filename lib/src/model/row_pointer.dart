/// 行位置信息
class RowPointer {
  final int offset; // 文件中的行偏移量
  final int length; // 记录的长度
  final int version; // 记录版本号，用于处理更新
  final String checksum; // 记录校验和，用于验证完整性

  const RowPointer({
    required this.offset,
    required this.length,
    this.version = 1,
    String? checksum,
  }) : checksum = checksum ?? '';

  /// 从字符串创建
  factory RowPointer.fromString(String value) {
    final parts = value.split(':');
    return RowPointer(
      offset: int.parse(parts[0]),
      length: int.parse(parts[1]),
      version: parts.length > 2 ? int.parse(parts[2]) : 1,
      checksum: parts.length > 3 ? parts[3] : '',
    );
  }

  /// 转换为字符串
  @override
  String toString() => '$offset:$length:$version:$checksum';

  /// 计算校验和
  static String calculateChecksum(String content) {
    return content.hashCode.toString();
  }

  /// 创建新的行位置信息
  static Future<RowPointer> create(
    String content,
    int offset, {
    int version = 1,
  }) async {
    return RowPointer(
      offset: offset,
      length: content.length,
      version: version,
      checksum: calculateChecksum(content),
    );
  }

  /// 验证记录完整性
  bool verifyContent(String content) {
    return checksum.isEmpty || checksum == calculateChecksum(content);
  }

  /// 创建新版本
  RowPointer newVersion() {
    return RowPointer(
      offset: offset,
      length: length,
      version: version + 1,
      checksum: checksum,
    );
  }
}
