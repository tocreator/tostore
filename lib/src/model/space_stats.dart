/// Per-space aggregate counters persisted in InternalKv (`stats.space.v1`).
///
class SpaceStats {
  /// Cached user-table count (may lag live schema inventory).
  final int totalTableCount;

  /// Total records across user tables in this space.
  final int totalRecordCount;

  /// Total table-data file size of user tables (bytes).
  final int totalTableDataSizeBytes;

  /// Total index-data file size of user tables (bytes).
  final int totalIndexDataSizeBytes;

  /// Last full-reconcile time; null means never reconciled.
  final DateTime? lastStatisticsTime;

  const SpaceStats({
    this.totalTableCount = 0,
    this.totalRecordCount = 0,
    this.totalTableDataSizeBytes = 0,
    this.totalIndexDataSizeBytes = 0,
    this.lastStatisticsTime,
  });

  /// Convenience: table data + index data.
  int get totalSizeBytes => totalTableDataSizeBytes + totalIndexDataSizeBytes;

  static const SpaceStats empty = SpaceStats();

  /// InternalKv key (space-local, [isGlobal] = false).
  static const String kvKey = 'stats.space.v1';

  SpaceStats copyWith({
    int? totalTableCount,
    int? totalRecordCount,
    int? totalTableDataSizeBytes,
    int? totalIndexDataSizeBytes,
    DateTime? lastStatisticsTime,
    bool clearLastStatisticsTime = false,
  }) {
    return SpaceStats(
      totalTableCount: totalTableCount ?? this.totalTableCount,
      totalRecordCount: totalRecordCount ?? this.totalRecordCount,
      totalTableDataSizeBytes:
          totalTableDataSizeBytes ?? this.totalTableDataSizeBytes,
      totalIndexDataSizeBytes:
          totalIndexDataSizeBytes ?? this.totalIndexDataSizeBytes,
      lastStatisticsTime: clearLastStatisticsTime
          ? null
          : (lastStatisticsTime ?? this.lastStatisticsTime),
    );
  }
}
