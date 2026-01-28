import 'table_schema.dart';

/// table info
class TableInfo {
  /// table name
  final String tableName;

  /// total record count
  final int totalRecords;

  /// file size in bytes
  final int fileSizeInBytes;

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
    required this.totalRecords,
    required this.fileSizeInBytes,
    required this.indexCount,
    required this.schema,
    required this.isGlobal,
    this.lastModified,
    this.createdAt,
  });

  /// get formatted file size
  String get formattedFileSize {
    if (fileSizeInBytes < 1024) return '$fileSizeInBytes B';
    if (fileSizeInBytes < 1024 * 1024) {
      return '${(fileSizeInBytes / 1024).toStringAsFixed(2)} KB';
    }
    if (fileSizeInBytes < 1024 * 1024 * 1024) {
      return '${(fileSizeInBytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(fileSizeInBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// convert to json
  Map<String, dynamic> toJson() => {
        'tableName': tableName,
        'totalRecords': totalRecords,
        'fileSizeInBytes': fileSizeInBytes,
        'formattedFileSize': formattedFileSize,
        'indexCount': indexCount,
        'schema': schema.toJson(),
        'isGlobal': isGlobal,
        'lastModified': lastModified?.toIso8601String(),
        'createdAt': createdAt?.toIso8601String(),
      };
}
