/// Information about a space in the database
class SpaceInfo {
  /// Name of the space
  final String spaceName;

  /// Total number of records across all tables in this space
  final int totalRecordCount;

  /// Total table-data size in bytes
  final int totalTableDataSizeBytes;

  /// Total index-data size in bytes
  final int totalIndexDataSizeBytes;

  /// Last time statistics were updated
  final DateTime? lastStatisticsTime;

  /// Create a new SpaceInfo instance
  const SpaceInfo({
    required this.spaceName,
    int totalRecordCount = 0,
    @Deprecated('Use totalRecordCount instead') int? recordCount,
    int totalTableDataSizeBytes = 0,
    this.totalIndexDataSizeBytes = 0,
    @Deprecated('Use totalTableDataSizeBytes or totalSizeBytes instead')
    int? dataSizeBytes,
    this.lastStatisticsTime,
  })  : totalRecordCount = recordCount ?? totalRecordCount,
        totalTableDataSizeBytes = dataSizeBytes ?? totalTableDataSizeBytes;

  /// Convenience: table data + index data.
  int get totalSizeBytes => totalTableDataSizeBytes + totalIndexDataSizeBytes;

  /// Deprecated: use [totalRecordCount].
  @Deprecated('Use totalRecordCount instead')
  int get recordCount => totalRecordCount;

  /// Deprecated: previously table-data only; use [totalTableDataSizeBytes]
  /// or [totalSizeBytes] for the combined total.
  @Deprecated('Use totalTableDataSizeBytes or totalSizeBytes instead')
  int get dataSizeBytes => totalTableDataSizeBytes;

  /// Create a map representation of this object
  Map<String, dynamic> toJson() {
    return {
      'spaceName': spaceName,
      'totalRecordCount': totalRecordCount,
      'totalTableDataSizeBytes': totalTableDataSizeBytes,
      'totalIndexDataSizeBytes': totalIndexDataSizeBytes,
      'totalSizeBytes': totalSizeBytes,
      // Legacy keys for older consumers.
      'recordCount': totalRecordCount,
      'dataSizeBytes': totalTableDataSizeBytes,
      'lastStatisticsTime': lastStatisticsTime?.toIso8601String(),
    };
  }
}
