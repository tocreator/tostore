/// Per-space aggregate counters persisted in InternalKv (`stats.space.v1`).
///
/// Average entry sizes are intentionally not persisted: [TableDataManager]
/// refreshes memory-cached averages on the SpaceStats persist cadence.
class SpaceStats {
  /// Total records across user tables in this space.
  final int totalRecordCount;

  /// Total table-data file size of user tables (bytes).
  final int totalTableDataSizeBytes;

  /// Total index-data file size of user tables (bytes).
  final int totalIndexDataSizeBytes;

  /// Total index entries across user tables (B+Tree entries + NGH vectors).
  final int totalIndexEntryCount;

  /// Last full-reconcile time; null means never reconciled.
  final DateTime? lastStatisticsTime;

  const SpaceStats({
    this.totalRecordCount = 0,
    this.totalTableDataSizeBytes = 0,
    this.totalIndexDataSizeBytes = 0,
    this.totalIndexEntryCount = 0,
    this.lastStatisticsTime,
  });

  /// Convenience: table data + index data.
  int get totalSizeBytes => totalTableDataSizeBytes + totalIndexDataSizeBytes;

  static const SpaceStats empty = SpaceStats();

  /// InternalKv key (space-local, [isGlobal] = false).
  static const String kvKey = 'stats.space.v1';

  SpaceStats copyWith({
    int? totalRecordCount,
    int? totalTableDataSizeBytes,
    int? totalIndexDataSizeBytes,
    int? totalIndexEntryCount,
    DateTime? lastStatisticsTime,
    bool clearLastStatisticsTime = false,
  }) {
    return SpaceStats(
      totalRecordCount: totalRecordCount ?? this.totalRecordCount,
      totalTableDataSizeBytes:
          totalTableDataSizeBytes ?? this.totalTableDataSizeBytes,
      totalIndexDataSizeBytes:
          totalIndexDataSizeBytes ?? this.totalIndexDataSizeBytes,
      totalIndexEntryCount: totalIndexEntryCount ?? this.totalIndexEntryCount,
      lastStatisticsTime: clearLastStatisticsTime
          ? null
          : (lastStatisticsTime ?? this.lastStatisticsTime),
    );
  }
}
