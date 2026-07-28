/// Information about a space in the database
class SpaceInfo {
  /// Name of the space
  final String spaceName;

  /// Number of tables in the schema inventory
  final int tableCount;

  /// Total number of records across all tables in this space
  final int recordCount;

  /// Total data size in bytes
  final int dataSizeBytes;

  /// Last time statistics were updated
  final DateTime? lastStatisticsTime;

  /// Tables in the schema inventory
  final List<String> tables;

  /// Create a new SpaceInfo instance
  const SpaceInfo({
    required this.spaceName,
    this.tableCount = 0,
    this.recordCount = 0,
    this.dataSizeBytes = 0,
    this.lastStatisticsTime,
    this.tables = const [],
  });

  /// Create a map representation of this object
  Map<String, dynamic> toJson() {
    return {
      'spaceName': spaceName,
      'tableCount': tableCount,
      'recordCount': recordCount,
      'dataSizeBytes': dataSizeBytes,
      'lastStatisticsTime': lastStatisticsTime?.toIso8601String(),
      'tables': tables,
    };
  }
}
