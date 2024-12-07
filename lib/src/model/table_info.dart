import 'table_schema.dart';

/// 表信息
class TableInfo {
  /// 表名
  final String tableName;

  /// 记录总数
  final int recordCount;

  /// 缓存记录数量
  final int cacheCount;

  /// 文件大小(字节)
  final int fileSize;

  /// 索引数量
  final int indexCount;

  /// 表结构
  final TableSchema schema;

  /// 最后修改时间
  final DateTime? lastModified;

  /// 创建时间
  final DateTime? createdAt;

  /// 是否为全局表
  final bool isGlobal;

  const TableInfo({
    required this.tableName,
    required this.recordCount,
    required this.cacheCount,
    required this.fileSize,
    required this.indexCount,
    required this.schema,
    required this.isGlobal,
    this.lastModified,
    this.createdAt,
  });

  /// 获取格式化的文件大小
  String get formattedFileSize {
    if (fileSize < 1024) return '$fileSize B';
    if (fileSize < 1024 * 1024) {
      return '${(fileSize / 1024).toStringAsFixed(2)} KB';
    }
    if (fileSize < 1024 * 1024 * 1024) {
      return '${(fileSize / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(fileSize / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// 转换为JSON
  Map<String, dynamic> toJson() => {
        'tableName': tableName,
        'recordCount': recordCount,
        'cacheCount': cacheCount,
        'fileSize': fileSize,
        'formattedFileSize': formattedFileSize,
        'indexCount': indexCount,
        'schema': schema.toJson(),
        'isGlobal': isGlobal,
        'lastModified': lastModified?.toIso8601String(),
        'createdAt': createdAt?.toIso8601String(),
      };
}
