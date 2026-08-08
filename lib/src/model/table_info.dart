import 'table_schema.dart';

/// table info
class TableInfo {
  /// table name
  final String tableName;

  /// total record count
  final int totalRecordCount;

  /// table-data file size in bytes
  final int totalTableDataSizeBytes;

  /// index-data file size in bytes
  final int totalIndexDataSizeBytes;

  /// index count (number of indexes, not entry count)
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
    int totalRecordCount = 0,
    @Deprecated('Use totalRecordCount instead') int? totalRecords,
    int totalTableDataSizeBytes = 0,
    this.totalIndexDataSizeBytes = 0,
    @Deprecated('Use totalTableDataSizeBytes instead') int? fileSizeInBytes,
    required this.indexCount,
    required this.schema,
    required this.isGlobal,
    this.lastModified,
    this.createdAt,
  })  : totalRecordCount = totalRecords ?? totalRecordCount,
        totalTableDataSizeBytes = fileSizeInBytes ?? totalTableDataSizeBytes;

  /// Convenience: table data + index data.
  int get totalSizeBytes => totalTableDataSizeBytes + totalIndexDataSizeBytes;

  /// Deprecated: use [totalRecordCount].
  @Deprecated('Use totalRecordCount instead')
  int get totalRecords => totalRecordCount;

  /// Deprecated: previously table-data only; use [totalTableDataSizeBytes].
  @Deprecated('Use totalTableDataSizeBytes instead')
  int get fileSizeInBytes => totalTableDataSizeBytes;

  /// get formatted total size (table + index)
  String get formattedFileSize {
    final bytes = totalSizeBytes;
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(2)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// convert to json
  Map<String, dynamic> toJson() => {
        'tableName': tableName,
        'totalRecordCount': totalRecordCount,
        'totalTableDataSizeBytes': totalTableDataSizeBytes,
        'totalIndexDataSizeBytes': totalIndexDataSizeBytes,
        'totalSizeBytes': totalSizeBytes,
        // Legacy keys for older consumers.
        'totalRecords': totalRecordCount,
        'fileSizeInBytes': totalTableDataSizeBytes,
        'formattedFileSize': formattedFileSize,
        'indexCount': indexCount,
        'schema': schema.toJson(),
        'isGlobal': isGlobal,
        'lastModified': lastModified?.toIso8601String(),
        'createdAt': createdAt?.toIso8601String(),
      };
}
