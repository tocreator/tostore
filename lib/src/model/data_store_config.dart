import 'migration_config.dart';
import '../handler/platform_handler.dart';
import '../model/log_config.dart';
import 'dart:math';

/// data store config
class DataStoreConfig {
  /// database path
  final String? dbPath;

  /// database name, used for quickly creating different database instances
  final String dbName;

  /// current space name
  final String spaceName;

  /// compression level
  final int compressionLevel;

  /// transaction timeout
  final Duration transactionTimeout;

  /// enable monitoring
  final bool enableMonitoring;

  /// enable compression
  final bool enableCompression;

  /// enable auto repair
  final bool enableAutoRepair;

  /// enable content encoding
  final bool enableEncoding;

  /// enable encoding obfuscation
  final bool enableEncodingObfuscation;

  /// encoding key, used for encoding/decoding table data
  /// can be freely modified, old key-encoded data will be automatically migrated
  final String encodingKey;

  /// encryption key, used to encrypt the encodingKey and other critical information
  /// Note: After changing the encryption key, data encoded with the old key cannot be decoded. Please protect it carefully
  final String encryptionKey;

  /// migration config
  final MigrationConfig? migrationConfig;

  /// max entries (files or subdirectories) per directory (default 500)
  final int maxEntriesPerDir;

  /// max partition file size based on platform
  /// Web: 64KB, Mobile: 256KB, Desktop: 4MB, Server: 4-16MB (dynamic)
  final int maxPartitionFileSize;

  /// Enable logging
  final bool enableLog;

  /// Log level
  final LogLevel logLevel;

  /// Maximum concurrency
  final int maxConcurrent;

  /// Distributed node configuration
  final DistributedNodeConfig distributedNodeConfig;

  /// Maximum per batch processing
  final int maxBatchSize;

  /// Maximum number of tables to process per flush
  final int maxTablesPerFlush;

  /// Memory threshold in MB for all caches combined
  /// If null, system will automatically determine appropriate value based on available memory
  final int? memoryThresholdInMB;

  /// Whether to prewarm the cache, when is true, the cache will be prewarmed when the data store is initialized
  final bool? enablePrewarmCache;

  /// The threshold in megabytes for automatic cache prewarming when [enablePrewarmCache] is true.
  final int prewarmThresholdMB;

  DataStoreConfig({
    this.dbPath,
    this.dbName = 'default',
    this.spaceName = 'default',
    this.compressionLevel = 6,
    this.transactionTimeout = const Duration(minutes: 5),
    this.enableMonitoring = true,
    this.enableCompression = true,
    this.enableAutoRepair = true,
    this.enableEncoding = true,
    this.enableEncodingObfuscation = true,
    this.encodingKey = "E9n8C7o6D7I8n3gkEY",
    this.encryptionKey = "E9n8C7r6y7P8T3ioNkEy",
    this.migrationConfig = const MigrationConfig(),
    this.maxEntriesPerDir = 500,
    int? maxPartitionFileSize,
    this.enableLog = true,
    this.logLevel = LogLevel.warn,
    int? maxConcurrent,
    DistributedNodeConfig? distributedNodeConfig,
    int? maxBatchSize,
    int? maxTablesPerFlush,
    this.memoryThresholdInMB,
    this.enablePrewarmCache,
    int? prewarmThresholdMB,
  })  : maxPartitionFileSize =
            maxPartitionFileSize ?? _getDefaultMaxPartitionFileSize(),
        maxConcurrent = maxConcurrent ?? _getDefaultMaxConcurrent(),
        distributedNodeConfig =
            distributedNodeConfig ?? const DistributedNodeConfig(),
        maxBatchSize = maxBatchSize ?? _getDefaultBatchSize(),
        maxTablesPerFlush = maxTablesPerFlush ?? _getDefaultTablesPerFlush(),
        prewarmThresholdMB =
            prewarmThresholdMB ?? _getDefaultPrewarmThreshold();

  /// get default partition file size limit, based on platform
  static int _getDefaultMaxPartitionFileSize() {
    if (PlatformHandler.isWeb) {
      return 64 * 1024; // Web: 64KB - Browser memory constraints
    } else if (PlatformHandler.isMobile) {
      return 256 * 1024; // Mobile: 256KB - Balance performance and memory
    } else if (PlatformHandler.isServerEnvironment) {
      // Server environment: Dynamic sizing based on CPU cores and memory
      int cpuCount = PlatformHandler.recommendedConcurrency;

      // Base size 4MB + 1MB per CPU core, capped at 16MB
      // This optimizes for high-throughput server workloads
      int serverSize = (4 * 1024 * 1024) + (cpuCount * 1 * 1024 * 1024);
      return min(serverSize, 16 * 1024 * 1024); // Cap at 16MB
    } else {
      // Desktop platform: 4MB
      return 4 * 1024 * 1024;
    }
  }

  /// Parse log level from string
  static LogLevel _parseLogLevel(dynamic value) {
    if (value == null) return LogLevel.debug;

    if (value is String) {
      switch (value.toLowerCase()) {
        case 'debug':
          return LogLevel.debug;
        case 'info':
          return LogLevel.info;
        case 'warn':
          return LogLevel.warn;
        case 'error':
          return LogLevel.error;
      }
    } else if (value is int) {
      try {
        return LogLevel.values[value];
      } catch (_) {
        return LogLevel.debug;
      }
    }

    return LogLevel.debug;
  }

  /// Get default max concurrency
  static int _getDefaultMaxConcurrent() {
    if (PlatformHandler.isTestEnvironment) return 1;
    return PlatformHandler.recommendedConcurrency;
  }

  /// Get default batch size
  static int _getDefaultBatchSize() {
    if (PlatformHandler.isWeb) {
      return 500; // Web environment, avoid browser freezing
    } else if (PlatformHandler.isMobile) {
      return 1000; // Mobile devices, balance performance and memory usage
    } else if (PlatformHandler.isServerEnvironment) {
      // Simple formula based primarily on CPU count
      int cpuCount = PlatformHandler.recommendedConcurrency;

      // Base size 2000 + 500 per CPU core
      int batchSize = 2000 + (cpuCount * 500);

      // Cap at reasonable maximum
      return min(batchSize, 10000);
    } else {
      return 2000; // Desktop devices, leverage more powerful hardware
    }
  }

  /// Get default number of tables to process per flush
  static int _getDefaultTablesPerFlush() {
    // This now simply reflects the max concurrency, as the list of tables to process
    // acts as a buffer/queue for the concurrent processor.
    return _getDefaultMaxConcurrent();
  }

  static int _getDefaultPrewarmThreshold() {
    int cpuCount = PlatformHandler.recommendedConcurrency;
    if (PlatformHandler.isServerEnvironment) {
      // Servers have high-performance I/O, so we can be more aggressive.
      return 256 + (cpuCount * 25);
    }
    if (PlatformHandler.isDesktop) {
      // Desktops usually have fast SSDs.
      return 64 + (cpuCount * 15);
    }
    // Mobile devices have slower storage and more constrained memory.
    return 20 + (cpuCount * 10);
  }

  /// from json create config
  factory DataStoreConfig.fromJson(Map<String, dynamic> json) {
    return DataStoreConfig(
      dbPath: json['dbPath'] as String?,
      dbName: json['dbName'] as String? ?? 'default',
      spaceName: json['spaceName'] as String? ?? 'default',
      compressionLevel: json['compressionLevel'] as int? ?? 6,
      transactionTimeout:
          Duration(milliseconds: json['transactionTimeout'] as int? ?? 300000),
      enableMonitoring: json['enableMonitoring'] as bool? ?? true,
      enableCompression: json['enableCompression'] as bool? ?? true,
      enableAutoRepair: json['enableAutoRepair'] as bool? ?? true,
      enableEncoding: json['enableEncoding'] as bool? ?? false,
      enableEncodingObfuscation:
          json['enableEncodingObfuscation'] as bool? ?? true,
      encodingKey: json['encodingKey'] ?? "E9n8C7o6D7I8n3gkEY",
      encryptionKey: json['encryptionKey'] ?? "E9n8C7r6y7P8T3ioNkEy",
      migrationConfig: json['migrationConfig'] != null
          ? MigrationConfig.fromJson(
              json['migrationConfig'] as Map<String, dynamic>)
          : const MigrationConfig(),
      maxEntriesPerDir: json['maxEntriesPerDir'] as int? ?? 500,
      maxPartitionFileSize: json['maxPartitionFileSize'] as int?,
      enableLog: json['enableLog'] as bool? ?? true,
      logLevel: _parseLogLevel(json['logLevel']),
      maxConcurrent: json['maxConcurrent'] as int?,
      distributedNodeConfig: json['distributedNodeConfig'] != null
          ? DistributedNodeConfig.fromJson(
              json['distributedNodeConfig'] as Map<String, dynamic>)
          : const DistributedNodeConfig(),
      maxBatchSize: json['maxBatchSize'] as int?,
      maxTablesPerFlush: json['maxTablesPerFlush'] as int?,
      memoryThresholdInMB: json['memoryThresholdInMB'] as int?,
      enablePrewarmCache: json['enablePrewarmCache'] as bool?,
      prewarmThresholdMB: json['prewarmThresholdMB'] as int? ?? 10,
    );
  }

  /// convert to json
  Map<String, dynamic> toJson() {
    return {
      'dbPath': dbPath,
      'dbName': dbName,
      'spaceName': spaceName,
      'compressionLevel': compressionLevel,
      'transactionTimeout': transactionTimeout.inMilliseconds,
      'enableMonitoring': enableMonitoring,
      'enableCompression': enableCompression,
      'enableAutoRepair': enableAutoRepair,
      'enableEncoding': enableEncoding,
      'enableEncodingObfuscation': enableEncodingObfuscation,
      'encodingKey': encodingKey,
      'encryptionKey': encryptionKey,
      'migrationConfig': migrationConfig?.toJson(),
      'maxEntriesPerDir': maxEntriesPerDir,
      'maxPartitionFileSize': maxPartitionFileSize,
      'enableLog': enableLog,
      'logLevel': logLevel.toString().split('.').last,
      'maxConcurrent': maxConcurrent,
      'distributedNodeConfig': distributedNodeConfig.toJson(),
      'maxBatchSize': maxBatchSize,
      'maxTablesPerFlush': maxTablesPerFlush,
      'memoryThresholdInMB': memoryThresholdInMB,
      'enablePrewarmCache': enablePrewarmCache,
      'prewarmThresholdMB': prewarmThresholdMB,
    };
  }

  /// create new config instance
  DataStoreConfig copyWith({
    String? dbPath,
    String? dbName,
    String? spaceName,
    int? compressionLevel,
    Duration? transactionTimeout,
    bool? enableMonitoring,
    bool? enableCompression,
    bool? enableAutoRepair,
    bool? enableEncoding,
    bool? enableEncodingObfuscation,
    dynamic encodingKey,
    String? encryptionKey,
    MigrationConfig? migrationConfig,
    int? maxEntriesPerDir,
    int? maxPartitionFileSize,
    bool? enableLog,
    LogLevel? logLevel,
    int? maxConcurrent,
    DistributedNodeConfig? distributedNodeConfig,
    int? maxBatchSize,
    int? maxTablesPerFlush,
    int? memoryThresholdInMB,
    bool? enablePrewarmCache,
    int? prewarmThresholdMB,
  }) {
    return DataStoreConfig(
      dbPath: dbPath ?? this.dbPath,
      dbName: dbName ?? this.dbName,
      spaceName: spaceName ?? this.spaceName,
      compressionLevel: compressionLevel ?? this.compressionLevel,
      transactionTimeout: transactionTimeout ?? this.transactionTimeout,
      enableMonitoring: enableMonitoring ?? this.enableMonitoring,
      enableCompression: enableCompression ?? this.enableCompression,
      enableAutoRepair: enableAutoRepair ?? this.enableAutoRepair,
      enableEncoding: enableEncoding ?? this.enableEncoding,
      enableEncodingObfuscation:
          enableEncodingObfuscation ?? this.enableEncodingObfuscation,
      encodingKey: encodingKey ?? this.encodingKey,
      encryptionKey: encryptionKey ?? this.encryptionKey,
      migrationConfig: migrationConfig ?? this.migrationConfig,
      maxEntriesPerDir: maxEntriesPerDir ?? this.maxEntriesPerDir,
      maxPartitionFileSize: maxPartitionFileSize ?? this.maxPartitionFileSize,
      enableLog: enableLog ?? this.enableLog,
      logLevel: logLevel ?? this.logLevel,
      maxConcurrent: maxConcurrent ?? this.maxConcurrent,
      distributedNodeConfig:
          distributedNodeConfig ?? this.distributedNodeConfig,
      maxBatchSize: maxBatchSize ?? this.maxBatchSize,
      maxTablesPerFlush: maxTablesPerFlush ?? this.maxTablesPerFlush,
      memoryThresholdInMB: memoryThresholdInMB ?? this.memoryThresholdInMB,
      enablePrewarmCache: enablePrewarmCache ?? this.enablePrewarmCache,
      prewarmThresholdMB: prewarmThresholdMB ?? this.prewarmThresholdMB,
    );
  }
}

/// Distributed node configuration
class DistributedNodeConfig {
  /// Whether to enable distributed mode
  final bool enableDistributed;

  /// Cluster ID affiliation
  final int clusterId;

  /// Node ID
  final int nodeId;

  /// Central server URL
  final String? centralServerUrl;

  /// Node access token
  final String? accessToken;

  /// Whether to automatically fetch node information from central server
  final bool autoFetchNodeInfo;

  /// Central node communication timeout
  final Duration connectionTimeout;

  /// ID pre-allocation threshold percentage (async request for new batch when reaching this percentage)
  final double idFetchThreshold;

  const DistributedNodeConfig({
    this.enableDistributed = false,
    this.clusterId = 0,
    this.nodeId = 0,
    this.centralServerUrl,
    this.accessToken,
    this.autoFetchNodeInfo = true,
    this.connectionTimeout = const Duration(seconds: 30),
    this.idFetchThreshold = 0.7,
  });

  DistributedNodeConfig copyWith({
    bool? enableDistributed,
    int? clusterId,
    int? nodeId,
    String? centralServerUrl,
    String? accessToken,
    bool? autoFetchNodeInfo,
    Duration? connectionTimeout,
    double? idFetchThreshold,
  }) {
    return DistributedNodeConfig(
      enableDistributed: enableDistributed ?? this.enableDistributed,
      clusterId: clusterId ?? this.clusterId,
      nodeId: nodeId ?? this.nodeId,
      centralServerUrl: centralServerUrl ?? this.centralServerUrl,
      accessToken: accessToken ?? this.accessToken,
      autoFetchNodeInfo: autoFetchNodeInfo ?? this.autoFetchNodeInfo,
      connectionTimeout: connectionTimeout ?? this.connectionTimeout,
      idFetchThreshold: idFetchThreshold ?? this.idFetchThreshold,
    );
  }

  factory DistributedNodeConfig.fromJson(Map<String, dynamic> json) {
    return DistributedNodeConfig(
      enableDistributed: json['enableDistributed'] as bool? ?? false,
      clusterId: json['clusterId'] as int? ?? 0,
      nodeId: json['nodeId'] as int? ?? 0,
      centralServerUrl: json['centralServerUrl'] as String?,
      accessToken: json['accessToken'] as String?,
      autoFetchNodeInfo: json['autoFetchNodeInfo'] as bool? ?? true,
      connectionTimeout:
          Duration(milliseconds: json['connectionTimeoutMs'] as int? ?? 30000),
      idFetchThreshold: json['idFetchThreshold'] as double? ?? 0.7,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enableDistributed': enableDistributed,
      'clusterId': clusterId,
      'nodeId': nodeId,
      'centralServerUrl': centralServerUrl,
      'accessToken': accessToken,
      'autoFetchNodeInfo': autoFetchNodeInfo,
      'connectionTimeoutMs': connectionTimeout.inMilliseconds,
      'idFetchThreshold': idFetchThreshold,
    };
  }
}
