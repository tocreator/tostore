/// Per-space aggregate counters persisted in InternalKv (`stats.space.v1`).
///
class SpaceStats {
  /// Cached user-table count (may lag live schema inventory).
  final int totalTableCount;

  /// Total records across user tables in this space.
  final int totalRecordCount;

  /// Total data file size of user tables (bytes).
  final int totalDataSizeBytes;

  /// Last full-reconcile time; null means never reconciled.
  final DateTime? lastStatisticsTime;

  const SpaceStats({
    this.totalTableCount = 0,
    this.totalRecordCount = 0,
    this.totalDataSizeBytes = 0,
    this.lastStatisticsTime,
  });

  static const SpaceStats empty = SpaceStats();

  /// InternalKv key (space-local, [isGlobal] = false).
  static const String kvKey = 'stats.space.v1';

  SpaceStats copyWith({
    int? totalTableCount,
    int? totalRecordCount,
    int? totalDataSizeBytes,
    DateTime? lastStatisticsTime,
    bool clearLastStatisticsTime = false,
  }) {
    return SpaceStats(
      totalTableCount: totalTableCount ?? this.totalTableCount,
      totalRecordCount: totalRecordCount ?? this.totalRecordCount,
      totalDataSizeBytes: totalDataSizeBytes ?? this.totalDataSizeBytes,
      lastStatisticsTime: clearLastStatisticsTime
          ? null
          : (lastStatisticsTime ?? this.lastStatisticsTime),
    );
  }
}
