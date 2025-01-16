import 'migration_config.dart';

/// data store config
class DataStoreConfig {
  /// database path
  final String dbPath;

  /// current base name
  final String baseName;

  /// compression level
  final int compressionLevel;

  /// transaction timeout
  final Duration transactionTimeout;

  /// B-tree order
  final int bTreeOrder;

  /// enable monitoring
  final bool enableMonitoring;

  /// enable compression
  final bool enableCompression;

  /// enable auto repair
  final bool enableAutoRepair;

  /// max table cache size (default 10MB), unit: byte
  final int maxTableCacheSize;

  /// max table cache count (default 50 tables)
  final int maxTableCacheCount;

  /// max query cache size (default 5000 queries)
  final int maxQueryCacheSize;

  /// max record cache size (default 10000 records)
  final int maxRecordCacheSize;

  /// max cache size
  final int maxCacheSize;

  /// enable encryption
  final bool enableEncryption;

  /// encryption key
  final String? encryptionKey;

  /// migration config
  final MigrationConfig? migrationConfig;

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
    this.maxCacheSize = 10000,
    this.enableEncryption = false,
    this.encryptionKey,
    this.migrationConfig = const MigrationConfig(),
  });

  /// get table path
  String getTablePath(String tableName, bool isGlobal) {
    if (isGlobal) {
      return '$dbPath/global/$tableName';
    }
    return '$dbPath/bases/$baseName/$tableName';
  }

  /// get base path
  String getBasePath() {
    return '$dbPath/bases/$baseName';
  }

  /// get global path
  String getGlobalPath() {
    return '$dbPath/global';
  }

  /// get backup path
  String getBackupPath() {
    return '$dbPath/backups';
  }

  /// get log path
  String getLogPath() {
    return '$dbPath/logs';
  }

  /// get index path
  String getIndexPath(String tableName, String indexName, bool isGlobal) {
    return '${getTablePath(tableName, isGlobal)}.$indexName.idx';
  }

  /// get stats path
  String getStatsPath(String tableName, bool isGlobal) {
    return '${getTablePath(tableName, isGlobal)}.stats';
  }

  /// get transaction log path
  String getTransactionLogPath(String tableName, bool isGlobal) {
    return '${getTablePath(tableName, isGlobal)}.transaction.log';
  }

  /// get checksum path
  String getChecksumPath(String tableName, bool isGlobal) {
    return '${getTablePath(tableName, isGlobal)}.checksum';
  }

  /// get schema path
  String getSchemaPath(String tableName, bool isGlobal) {
    return '${getTablePath(tableName, isGlobal)}.schema';
  }

  /// get data path
  String getDataPath(String tableName, bool isGlobal) {
    return '${getTablePath(tableName, isGlobal)}.dat';
  }

  /// get auto increment id path
  String getAutoIncrementPath(String tableName, bool isGlobal) {
    return '${getTablePath(tableName, isGlobal)}.maxid';
  }

  /// create config from json
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
      maxCacheSize: json['maxCacheSize'] as int? ?? 10000,
      enableEncryption: json['enableEncryption'] as bool? ?? false,
      encryptionKey: json['encryptionKey'] as String?,
      migrationConfig: json['migrationConfig'] != null
          ? MigrationConfig.fromJson(
              json['migrationConfig'] as Map<String, dynamic>)
          : const MigrationConfig(),
    );
  }

  /// convert to json
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
      'maxCacheSize': maxCacheSize,
      'enableEncryption': enableEncryption,
      'encryptionKey': encryptionKey,
      'migrationConfig': migrationConfig?.toJson(),
    };
  }

  /// create new config instance
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
    int? maxCacheSize,
    bool? enableEncryption,
    String? encryptionKey,
    MigrationConfig? migrationConfig,
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
      maxCacheSize: maxCacheSize ?? this.maxCacheSize,
      enableEncryption: enableEncryption ?? this.enableEncryption,
      encryptionKey: encryptionKey ?? this.encryptionKey,
      migrationConfig: migrationConfig ?? this.migrationConfig,
    );
  }
}
