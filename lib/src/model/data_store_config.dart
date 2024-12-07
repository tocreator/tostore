/// 数据存储配置
class DataStoreConfig {
  /// 数据库路径
  final String dbPath;

  /// 当前基础空间名称
  final String baseName;

  /// 压缩级别
  final int compressionLevel;

  /// 事务超时时间
  final Duration transactionTimeout;

  /// B树阶数
  final int bTreeOrder;

  /// 是否启用监控
  final bool enableMonitoring;

  /// 是否启用压缩
  final bool enableCompression;

  /// 是否启用自动修复
  final bool enableAutoRepair;

  /// 全表缓存的文件大小限制(默认10MB)，单位：字节
  final int maxTableCacheSize;

  /// 全表缓存的表数量限制(默认50个表)
  final int maxTableCacheCount;

  /// 查询缓存的数量限制(默认5000条查询)
  final int maxQueryCacheSize;

  /// 记录缓存的数量限制(默认10000条记录)
  final int maxRecordCacheSize;

  const DataStoreConfig({
    required this.dbPath,
    this.baseName = 'default',
    this.compressionLevel = 6,
    this.transactionTimeout = const Duration(minutes: 5),
    this.bTreeOrder = 100,
    this.enableMonitoring = true,
    this.enableCompression = true,
    this.enableAutoRepair = true,
    this.maxTableCacheSize = 10 * 1024 * 1024, // 10MB
    this.maxTableCacheCount = 50,
    this.maxQueryCacheSize = 5000,
    this.maxRecordCacheSize = 10000,
  });

  /// 获取表路径
  String getTablePath(String tableName, bool isGlobal) {
    if (isGlobal) {
      return '$dbPath/global/$tableName';
    }
    return '$dbPath/bases/$baseName/$tableName';
  }

  /// 获取基础空间路径
  String getBasePath() {
    return '$dbPath/bases/$baseName';
  }

  /// 获取全局空间路径
  String getGlobalPath() {
    return '$dbPath/global';
  }

  /// 获取备份路径
  String getBackupPath() {
    return '$dbPath/backups';
  }

  /// 获取日志路径
  String getLogPath() {
    return '$dbPath/logs';
  }

  /// 获取索引路径
  String getIndexPath(String tableName, String indexName, bool isGlobal) {
    return '${getTablePath(tableName, isGlobal)}.$indexName.idx';
  }

  /// 获取统计信息路径
  String getStatsPath(String tableName, bool isGlobal) {
    return '${getTablePath(tableName, isGlobal)}.stats';
  }

  /// 获取事务日志路径
  String getTransactionLogPath(String tableName, bool isGlobal) {
    return '${getTablePath(tableName, isGlobal)}.transaction.log';
  }

  /// 获取校验和文件路径
  String getChecksumPath(String tableName, bool isGlobal) {
    return '${getTablePath(tableName, isGlobal)}.checksum';
  }

  /// 获取数据模型文件路径
  String getSchemaPath(String tableName, bool isGlobal) {
    return '${getTablePath(tableName, isGlobal)}.schema';
  }

  /// 获取数据文件路径
  String getDataPath(String tableName, bool isGlobal) {
    return '${getTablePath(tableName, isGlobal)}.dat';
  }

  /// 获取自增ID文件路径
  String getAutoIncrementPath(String tableName, bool isGlobal) {
    return '${getTablePath(tableName, isGlobal)}.maxid';
  }

  /// 从JSON创建配置
  factory DataStoreConfig.fromJson(Map<String, dynamic> json) {
    return DataStoreConfig(
      dbPath: json['dbPath'] as String,
      baseName: json['baseName'] as String? ?? 'default',
      compressionLevel: json['compressionLevel'] as int? ?? 6,
      transactionTimeout: Duration(
          milliseconds: json['transactionTimeoutMs'] as int? ?? 300000),
      bTreeOrder: json['bTreeOrder'] as int? ?? 100,
      enableMonitoring: json['enableMonitoring'] as bool? ?? true,
      enableCompression: json['enableCompression'] as bool? ?? true,
      enableAutoRepair: json['enableAutoRepair'] as bool? ?? true,
      maxTableCacheSize: json['maxTableCacheSize'] as int? ?? 10 * 1024 * 1024,
      maxTableCacheCount: json['maxTableCacheCount'] as int? ?? 50,
      maxQueryCacheSize: json['maxQueryCacheSize'] as int? ?? 5000,
      maxRecordCacheSize: json['maxRecordCacheSize'] as int? ?? 10000,
    );
  }

  /// 转换为JSON
  Map<String, dynamic> toJson() {
    return {
      'dbPath': dbPath,
      'baseName': baseName,
      'compressionLevel': compressionLevel,
      'transactionTimeoutMs': transactionTimeout.inMilliseconds,
      'bTreeOrder': bTreeOrder,
      'enableMonitoring': enableMonitoring,
      'enableCompression': enableCompression,
      'enableAutoRepair': enableAutoRepair,
      'maxTableCacheSize': maxTableCacheSize,
      'maxTableCacheCount': maxTableCacheCount,
      'maxQueryCacheSize': maxQueryCacheSize,
      'maxRecordCacheSize': maxRecordCacheSize,
    };
  }

  /// 创建新的配置实例
  DataStoreConfig copyWith({
    String? dbPath,
    String? baseName,
    int? cacheSize,
    int? compressionLevel,
    Duration? transactionTimeout,
    int? bTreeOrder,
    bool? enableMonitoring,
    bool? enableCompression,
    bool? enableAutoRepair,
    int? maxTableCacheSize,
    int? maxTableCacheCount,
    int? maxQueryCacheSize,
    int? maxRecordCacheSize,
  }) {
    return DataStoreConfig(
      dbPath: dbPath ?? this.dbPath,
      baseName: baseName ?? this.baseName,
      compressionLevel: compressionLevel ?? this.compressionLevel,
      transactionTimeout: transactionTimeout ?? this.transactionTimeout,
      bTreeOrder: bTreeOrder ?? this.bTreeOrder,
      enableMonitoring: enableMonitoring ?? this.enableMonitoring,
      enableCompression: enableCompression ?? this.enableCompression,
      enableAutoRepair: enableAutoRepair ?? this.enableAutoRepair,
      maxTableCacheSize: maxTableCacheSize ?? this.maxTableCacheSize,
      maxTableCacheCount: maxTableCacheCount ?? this.maxTableCacheCount,
      maxQueryCacheSize: maxQueryCacheSize ?? this.maxQueryCacheSize,
      maxRecordCacheSize: maxRecordCacheSize ?? this.maxRecordCacheSize,
    );
  }
}
