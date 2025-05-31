import 'file_info.dart';

/// The initialization configuration model
class SpaceConfig {
  /// current encryption key info
  final EncryptionKeyInfo current;

  /// previous encryption key info (if any)
  final EncryptionKeyInfo? previous;

  /// data version
  final int version;

  /// last index weight process time
  final DateTime? lastIndexWeightProcessTime;

  /// Table directory mapping - Records the directory index where each table is located
  /// Key format is "spaceName:tableName"
  final Map<String, TableDirectoryInfo> tableDirectoryMap;

  /// Directory usage - Records how many tables each directory contains
  /// Key format is "spaceName:dirIndex"
  final Map<String, int> directoryUsageMap;

  /// Whether to enable startup cache
  final bool enableStartupCache;

  /// Total number of tables
  final int totalTableCount;

  /// Total number of records across all tables
  final int totalRecordCount;

  /// Total data file size of all tables (bytes)
  final int totalDataSizeBytes;

  /// Last statistics update time
  final DateTime? lastStatisticsTime;

  SpaceConfig({
    required this.current,
    this.previous,
    required this.version,
    this.lastIndexWeightProcessTime,
    Map<String, TableDirectoryInfo>? tableDirectoryMap,
    Map<String, int>? directoryUsageMap,
    this.enableStartupCache = false,
    this.totalTableCount = 0,
    this.totalRecordCount = 0,
    this.totalDataSizeBytes = 0,
    this.lastStatisticsTime,
  })  : tableDirectoryMap = tableDirectoryMap ?? {},
        directoryUsageMap = directoryUsageMap ?? {};

  factory SpaceConfig.fromJson(Map<String, dynamic> json) {
    return SpaceConfig(
        current:
            EncryptionKeyInfo.fromJson(json['current'] as Map<String, dynamic>),
        previous: json['previous'] != null
            ? EncryptionKeyInfo.fromJson(
                json['previous'] as Map<String, dynamic>)
            : null,
        version: json['version'] as int? ?? 0,
        lastIndexWeightProcessTime: json['lastIndexWeightProcessTime'] != null
            ? DateTime.parse(json['lastIndexWeightProcessTime'] as String)
            : null,
        tableDirectoryMap: json.containsKey('tableDirectoryMap')
            ? (json['tableDirectoryMap'] as Map<String, dynamic>).map(
                (key, value) => MapEntry(
                  key,
                  TableDirectoryInfo.fromJson(value as Map<String, dynamic>),
                ),
              )
            : {},
        directoryUsageMap: json.containsKey('directoryUsageMap')
            ? (json['directoryUsageMap'] as Map<String, dynamic>).map(
                (key, value) => MapEntry(key, value as int),
              )
            : {},
        enableStartupCache: json['enableStartupCache'] as bool? ?? false,
        totalTableCount: json['totalTableCount'] as int? ?? 0,
        totalRecordCount: json['totalRecordCount'] as int? ?? 0,
        totalDataSizeBytes: json['totalDataSizeBytes'] as int? ?? 0,
        lastStatisticsTime: json['lastStatisticsTime'] != null
            ? DateTime.parse(json['lastStatisticsTime'] as String)
            : null);
  }

  Map<String, dynamic> toJson() {
    return {
      'current': current.toJson(),
      'previous': previous?.toJson(),
      'version': version,
      'lastIndexWeightProcessTime':
          lastIndexWeightProcessTime?.toIso8601String(),
      'tableDirectoryMap':
          tableDirectoryMap.map((key, value) => MapEntry(key, value.toJson())),
      'directoryUsageMap': directoryUsageMap,
      'enableStartupCache': enableStartupCache,
      'totalTableCount': totalTableCount,
      'totalRecordCount': totalRecordCount,
      'totalDataSizeBytes': totalDataSizeBytes,
      'lastStatisticsTime': lastStatisticsTime?.toIso8601String(),
    };
  }

  /// creator new config
  SpaceConfig copyWith({
    EncryptionKeyInfo? current,
    EncryptionKeyInfo? previous,
    int? version,
    DateTime? lastIndexWeightProcessTime,
    DateTime? lastCacheWeightProcessTime,
    DateTime? lastStartupCacheTime,
    DateTime? lastCacheCleanupTime,
    Map<String, TableDirectoryInfo>? tableDirectoryMap,
    Map<String, int>? directoryUsageMap,
    bool? enableStartupCache,
    int? totalTableCount,
    int? totalRecordCount,
    int? totalDataSizeBytes,
    DateTime? lastStatisticsTime,
  }) {
    return SpaceConfig(
      current: current ?? this.current,
      previous: previous ?? this.previous,
      version: version ?? this.version,
      lastIndexWeightProcessTime:
          lastIndexWeightProcessTime ?? this.lastIndexWeightProcessTime,
      tableDirectoryMap: tableDirectoryMap ?? this.tableDirectoryMap,
      directoryUsageMap: directoryUsageMap ?? this.directoryUsageMap,
      enableStartupCache: enableStartupCache ?? this.enableStartupCache,
      totalTableCount: totalTableCount ?? this.totalTableCount,
      totalRecordCount: totalRecordCount ?? this.totalRecordCount,
      totalDataSizeBytes: totalDataSizeBytes ?? this.totalDataSizeBytes,
      lastStatisticsTime: lastStatisticsTime ?? this.lastStatisticsTime,
    );
  }

  /// Get all available keys (sorted by priority: current key first)
  List<EncryptionKeyInfo> getAllKeys() {
    return [
      current,
      if (previous != null) previous!,
    ]..removeWhere((key) => key.key.isEmpty);
  }

  /// Get specific key by keyId
  EncryptionKeyInfo? getKeyById(int keyId) {
    if (current.keyId == keyId) return current;
    if (previous?.keyId == keyId) return previous;
    return null;
  }

  /// Check if statistics need to be updated
  bool needUpdateStatistics() {
    if (lastStatisticsTime == null) return true;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final lastDay = DateTime(lastStatisticsTime!.year,
        lastStatisticsTime!.month, lastStatisticsTime!.day);

    // Update needed if last statistics was not today
    return lastDay.isBefore(today);
  }
}

/// The encryption key information model
class EncryptionKeyInfo {
  /// The encrypted key in base64 format
  final String key;

  /// The key identifier
  final int keyId;

  const EncryptionKeyInfo({
    required this.key,
    required this.keyId,
  });

  factory EncryptionKeyInfo.fromJson(Map<String, dynamic> json) {
    return EncryptionKeyInfo(
      key: json['key'] as String? ?? '',
      keyId: json['keyId'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'key': key,
      'keyId': keyId,
    };
  }
}
