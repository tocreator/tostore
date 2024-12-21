import 'table_schema.dart';

/// table info
class TableInfo {
  /// table name
  final String tableName;

  /// record count
  final int recordCount;

  /// cache record count
  final int cacheCount;

  /// file size (byte)
  final int fileSize;

  /// index count
  final int indexCount;

  /// table schema
  final TableSchema schema;

  /// last modified time
  final DateTime? lastModified;

  /// created time
  final DateTime? createdAt;

  /// is global table
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

  /// get formatted file size
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

  /// convert to json
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
