/// Information about cache and memory status
class MemoryInfo {
  /// Total memory budget (MB)
  final int totalThresholdMB;

  /// Current table data cache usage (Bytes)
  final int tableDataCacheUsage;

  /// Table data cache limit (Bytes)
  final int tableDataCacheLimit;

  /// Current index cache usage (Bytes)
  final int indexCacheUsage;

  /// Index cache limit (Bytes)
  final int indexCacheLimit;

  /// Current query cache usage (Bytes)
  final int queryCacheUsage;

  /// Query cache limit (Bytes)
  final int queryCacheLimit;

  /// Current schema cache usage (Bytes)
  final int schemaCacheUsage;

  /// Schema cache limit (Bytes)
  final int schemaCacheLimit;

  /// Current meta cache usage (Bytes)
  final int metaCacheUsage;

  /// Meta cache limit (Bytes)
  final int metaCacheLimit;

  /// Whether current system is in low memory mode
  final bool isLowMemoryMode;

  const MemoryInfo({
    required this.totalThresholdMB,
    required this.tableDataCacheUsage,
    required this.tableDataCacheLimit,
    required this.indexCacheUsage,
    required this.indexCacheLimit,
    required this.queryCacheUsage,
    required this.queryCacheLimit,
    required this.schemaCacheUsage,
    required this.schemaCacheLimit,
    required this.metaCacheUsage,
    required this.metaCacheLimit,
    required this.isLowMemoryMode,
  });

  /// Create a map representation of this object
  Map<String, dynamic> toJson() {
    return {
      'totalThresholdMB': totalThresholdMB,
      'tableDataCacheUsage': tableDataCacheUsage,
      'tableDataCacheLimit': tableDataCacheLimit,
      'indexCacheUsage': indexCacheUsage,
      'indexCacheLimit': indexCacheLimit,
      'queryCacheUsage': queryCacheUsage,
      'queryCacheLimit': queryCacheLimit,
      'schemaCacheUsage': schemaCacheUsage,
      'schemaCacheLimit': schemaCacheLimit,
      'metaCacheUsage': metaCacheUsage,
      'metaCacheLimit': metaCacheLimit,
      'isLowMemoryMode': isLowMemoryMode,
    };
  }
}
