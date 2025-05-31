/// Information about a space in the database
class SpaceInfo {
  /// Name of the space
  final String spaceName;

  /// Database version
  final int version;

  /// Number of user-created tables in this space
  final int tableCount;

  /// Total number of records across all tables in this space
  final int recordCount;

  /// Total data size in bytes
  final int dataSizeBytes;

  /// Last time statistics were updated
  final DateTime? lastStatisticsTime;

  /// User-created tables available in this space
  final List<String> tables;

  /// Create a new SpaceInfo instance
  const SpaceInfo({
    required this.spaceName,
    required this.version,
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
      'version': version,
      'tableCount': tableCount,
      'recordCount': recordCount,
      'dataSizeBytes': dataSizeBytes,
      'lastStatisticsTime': lastStatisticsTime?.toIso8601String(),
      'tables': tables,
    };
  }
}
