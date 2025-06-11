import 'migration_config.dart';
import '../handler/platform_handler.dart';
import '../model/log_config.dart';
import 'dart:math';

/// data store config
class DataStoreConfig {
  /// database path
  final String? dbPath;

  /// current space name
  final String spaceName;

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

  /// max table cache file size
  final int maxTableCacheFileSize;

  /// max query cache size
  final int maxQueryCacheSize;

  /// max record cache size
  final int maxRecordCacheSize;

  /// max index cache size
  final int maxIndexCacheSize;

  /// migration config
  final MigrationConfig? migrationConfig;

  /// max entries (files or subdirectories) per directory (default 500)
  final int maxEntriesPerDir;

  /// max partition file size based on platform
  /// Web: 64KB, Mobile: 256KB, Desktop: 4MB
  final int maxPartitionFileSize;

  /// Table schema cache size limit
  final int maxSchemaCacheSize;

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

  /// Enable query caching
  /// null: automatic (enabled on web/mobile/desktop, disabled on server)
  /// true: force enable query cache
  /// false: force disable query cache
  final bool? enableQueryCache;

  /// Maximum query cache expiry time
  /// null: no expiry (cache entries remain until manually cleared or evicted)
  /// other: duration after which cache entries are considered stale
  final Duration? queryCacheExpiryTime;

  DataStoreConfig({
    this.dbPath,
    this.spaceName = 'default',
    this.compressionLevel = 6,
    this.transactionTimeout = const Duration(minutes: 5),
    this.bTreeOrder = 200,
    this.enableMonitoring = true,
    this.enableCompression = true,
    this.enableAutoRepair = true,
    this.enableEncoding = true,
    this.enableEncodingObfuscation = true,
    this.encodingKey = "E9n8C7o6D7I8n3gkEY",
    this.encryptionKey = "E9n8C7r6y7P8T3ioNkEy",
    int? maxTableCacheFileSize,
    int? maxQueryCacheSize,
    int? maxRecordCacheSize,
    int? maxIndexCacheSize,
    this.migrationConfig = const MigrationConfig(),
    this.maxEntriesPerDir = 500,
    int? maxPartitionFileSize,
    int? maxSchemaCacheSize,
    this.enableLog = true,
    this.logLevel = LogLevel.warn,
    int? maxConcurrent,
    DistributedNodeConfig? distributedNodeConfig,
    int? maxBatchSize,
    int? maxTablesPerFlush,
    bool? enableQueryCache,
    this.queryCacheExpiryTime,
  })  : maxPartitionFileSize =
            maxPartitionFileSize ?? _getDefaultMaxPartitionFileSize(),
        maxTableCacheFileSize =
            maxTableCacheFileSize ?? CacheSettings.maxTableCacheFileSize,
        maxQueryCacheSize = maxQueryCacheSize ?? _getDefaultPlatformCacheSize(),
        maxRecordCacheSize =
            maxRecordCacheSize ?? _getDefaultPlatformCacheSize(),
        maxIndexCacheSize = maxIndexCacheSize ?? _getDefaultPlatformCacheSize(),
        maxSchemaCacheSize = maxSchemaCacheSize ?? _getDefaultSchemaCacheSize(),
        maxConcurrent = maxConcurrent ?? _getDefaultMaxConcurrent(),
        distributedNodeConfig =
            distributedNodeConfig ?? const DistributedNodeConfig(),
        maxBatchSize = maxBatchSize ?? _getDefaultBatchSize(),
        maxTablesPerFlush = maxTablesPerFlush ?? _getDefaultTablesPerFlush(),
        enableQueryCache = enableQueryCache ?? _getDefaultQueryCacheEnabled() {
    // Initialize async memory detection and cache optimization
    CacheSettings.startMemoryOptimization();
  }

  /// get default platform cache size
  static int _getDefaultPlatformCacheSize() {
    if (PlatformHandler.isWeb) {
      return 5000; // Web platform
    } else if (PlatformHandler.isMobile) {
      return 10000; // Mobile devices
    } else {
      return 100000; // Desktop devices
    }
  }

  /// Determine if query cache should be enabled by default
  static bool _getDefaultQueryCacheEnabled() {
    // default enabled on web/mobile/desktop, disabled on server environment
    return !PlatformHandler.isServerEnvironment;
  }

  /// Determine if query cache should be enabled by default based on platform
  /// Returns true for client platforms, false for server platforms
  bool get shouldEnableQueryCache =>
      enableQueryCache ?? _getDefaultQueryCacheEnabled();

  /// get default schema cache size
  static int _getDefaultSchemaCacheSize() {
    if (PlatformHandler.isWeb) {
      return 1000; // Web platform
    } else if (PlatformHandler.isMobile) {
      return 2000; // Mobile devices
    } else {
      return 50000; // Desktop devices
    }
  }

  /// get default partition file size limit, based on platform
  static int _getDefaultMaxPartitionFileSize() {
    if (PlatformHandler.isWeb) {
      return 64 * 1024; // Web: 64KB
    } else if (PlatformHandler.isMobile) {
      return 256 * 1024; // mobile platform: 256KB
    } else {
      return 4 * 1024 * 1024; // desktop platform: 4MB
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
    } else {
      return 1500; // Desktop devices, leverage more powerful hardware
    }
  }

  /// Get default number of tables to process per flush
  static int _getDefaultTablesPerFlush() {
    if (PlatformHandler.isWeb) {
      return 2; // Web environment, limit concurrency
    } else if (PlatformHandler.isMobile) {
      return 5; // Mobile devices, moderate concurrency
    } else {
      return 8; // Desktop devices, fully utilize multi-core processors
    }
  }

  /// from json create config
  factory DataStoreConfig.fromJson(Map<String, dynamic> json) {
    return DataStoreConfig(
      dbPath: json['dbPath'] as String,
      spaceName: json['spaceName'] as String? ?? 'default',
      compressionLevel: json['compressionLevel'] as int? ?? 6,
      transactionTimeout:
          Duration(milliseconds: json['transactionTimeout'] as int? ?? 300000),
      bTreeOrder: json['bTreeOrder'] as int? ?? 200,
      enableMonitoring: json['enableMonitoring'] as bool? ?? true,
      enableCompression: json['enableCompression'] as bool? ?? true,
      enableAutoRepair: json['enableAutoRepair'] as bool? ?? true,
      enableEncoding: json['enableEncoding'] as bool? ?? false,
      enableEncodingObfuscation:
          json['enableEncodingObfuscation'] as bool? ?? true,
      encodingKey: json['encodingKey'] ?? "E9n8C7o6D7I8n3gkEY",
      maxTableCacheFileSize:
          json['maxTableCacheFileSize'] as int? ?? 10 * 1024 * 1024,
      maxQueryCacheSize: json['maxQueryCacheSize'] as int? ?? 5000,
      maxRecordCacheSize: json['maxRecordCacheSize'] as int? ?? 10000,
      maxIndexCacheSize: json['maxIndexCacheSize'] as int? ?? 10000,
      encryptionKey: json['encryptionKey'] ?? "E9n8C7r6y7P8T3ioNkEy",
      migrationConfig: json['migrationConfig'] != null
          ? MigrationConfig.fromJson(
              json['migrationConfig'] as Map<String, dynamic>)
          : const MigrationConfig(),
      maxEntriesPerDir: json['maxEntriesPerDir'] as int? ?? 500,
      maxPartitionFileSize: json['maxPartitionFileSize'] as int?,
      maxSchemaCacheSize: json['maxSchemaCacheSize'] as int?,
      enableLog: json['enableLog'] as bool? ?? true,
      logLevel: _parseLogLevel(json['logLevel']),
      maxConcurrent: json['maxConcurrent'] as int?,
      distributedNodeConfig: json['distributedNodeConfig'] != null
          ? DistributedNodeConfig.fromJson(
              json['distributedNodeConfig'] as Map<String, dynamic>)
          : const DistributedNodeConfig(),
      maxBatchSize: json['maxBatchSize'] as int?,
      maxTablesPerFlush: json['maxTablesPerFlush'] as int?,
      enableQueryCache: json['enableQueryCache'] as bool?,
      queryCacheExpiryTime: json['queryCacheExpiryTime'] != null
          ? Duration(milliseconds: json['queryCacheExpiryTime'] as int)
          : null,
    );
  }

  /// convert to json
  Map<String, dynamic> toJson() {
    return {
      'dbPath': dbPath,
      'spaceName': spaceName,
      'compressionLevel': compressionLevel,
      'transactionTimeout': transactionTimeout.inMilliseconds,
      'bTreeOrder': bTreeOrder,
      'enableMonitoring': enableMonitoring,
      'enableCompression': enableCompression,
      'enableAutoRepair': enableAutoRepair,
      'enableEncoding': enableEncoding,
      'enableEncodingObfuscation': enableEncodingObfuscation,
      'encodingKey': encodingKey,
      'maxTableCacheSize': maxTableCacheFileSize,
      'maxQueryCacheSize': maxQueryCacheSize,
      'maxRecordCacheSize': maxRecordCacheSize,
      'maxCacheSize': maxIndexCacheSize,
      'encryptionKey': encryptionKey,
      'migrationConfig': migrationConfig?.toJson(),
      'maxEntriesPerDir': maxEntriesPerDir,
      'maxPartitionFileSize': maxPartitionFileSize,
      'maxSchemaCacheSize': maxSchemaCacheSize,
      'enableLog': enableLog,
      'logLevel': logLevel.toString().split('.').last,
      'maxConcurrent': maxConcurrent,
      'distributedNodeConfig': distributedNodeConfig.toJson(),
      'maxBatchSize': maxBatchSize,
      'maxTablesPerFlush': maxTablesPerFlush,
      'enableQueryCache': enableQueryCache,
      'queryCacheExpiryTime': queryCacheExpiryTime?.inMilliseconds,
    };
  }

  /// create new config instance
  DataStoreConfig copyWith({
    String? dbPath,
    String? spaceName,
    int? compressionLevel,
    Duration? transactionTimeout,
    int? bTreeOrder,
    bool? enableMonitoring,
    bool? enableCompression,
    bool? enableAutoRepair,
    bool? enableEncoding,
    bool? enableEncodingObfuscation,
    dynamic encodingKey,
    int? maxTableCacheFileSize,
    int? maxQueryCacheSize,
    int? maxRecordCacheSize,
    int? maxIndexCacheSize,
    String? encryptionKey,
    MigrationConfig? migrationConfig,
    int? maxEntriesPerDir,
    int? maxPartitionFileSize,
    int? maxSchemaCacheSize,
    bool? enableLog,
    LogLevel? logLevel,
    int? maxConcurrent,
    DistributedNodeConfig? distributedNodeConfig,
    int? maxBatchSize,
    int? maxTablesPerFlush,
    bool? enableQueryCache,
    Duration? queryCacheExpiryTime,
  }) {
    return DataStoreConfig(
      dbPath: dbPath ?? this.dbPath,
      spaceName: spaceName ?? this.spaceName,
      compressionLevel: compressionLevel ?? this.compressionLevel,
      transactionTimeout: transactionTimeout ?? this.transactionTimeout,
      bTreeOrder: bTreeOrder ?? this.bTreeOrder,
      enableMonitoring: enableMonitoring ?? this.enableMonitoring,
      enableCompression: enableCompression ?? this.enableCompression,
      enableAutoRepair: enableAutoRepair ?? this.enableAutoRepair,
      enableEncoding: enableEncoding ?? this.enableEncoding,
      enableEncodingObfuscation:
          enableEncodingObfuscation ?? this.enableEncodingObfuscation,
      encodingKey: encodingKey ?? this.encodingKey,
      maxTableCacheFileSize:
          maxTableCacheFileSize ?? this.maxTableCacheFileSize,
      maxQueryCacheSize: maxQueryCacheSize ?? this.maxQueryCacheSize,
      maxRecordCacheSize: maxRecordCacheSize ?? this.maxRecordCacheSize,
      maxIndexCacheSize: maxIndexCacheSize ?? this.maxIndexCacheSize,
      encryptionKey: encryptionKey ?? this.encryptionKey,
      migrationConfig: migrationConfig ?? this.migrationConfig,
      maxEntriesPerDir: maxEntriesPerDir ?? this.maxEntriesPerDir,
      maxPartitionFileSize: maxPartitionFileSize ?? this.maxPartitionFileSize,
      maxSchemaCacheSize: maxSchemaCacheSize ?? this.maxSchemaCacheSize,
      enableLog: enableLog ?? this.enableLog,
      logLevel: logLevel ?? this.logLevel,
      maxConcurrent: maxConcurrent ?? this.maxConcurrent,
      distributedNodeConfig:
          distributedNodeConfig ?? this.distributedNodeConfig,
      maxBatchSize: maxBatchSize ?? this.maxBatchSize,
      maxTablesPerFlush: maxTablesPerFlush ?? this.maxTablesPerFlush,
      enableQueryCache: enableQueryCache ?? this.enableQueryCache,
      queryCacheExpiryTime: queryCacheExpiryTime ?? this.queryCacheExpiryTime,
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

/// Cache settings manager (Singleton)
class CacheSettings {
  static final CacheSettings _instance = CacheSettings._internal();
  factory CacheSettings() => _instance;
  CacheSettings._internal();

  // Optimized cache values
  int _optimizedTableCacheSize = 0;
  bool _optimizationInProgress = false;

  // Get current table cache size
  int get tableCacheSize => _optimizedTableCacheSize > 0
      ? _optimizedTableCacheSize
      : _getDefaultMaxTableCacheFileSize();

  // Static access point
  static int get maxTableCacheFileSize => CacheSettings().tableCacheSize;

  /// Get default table file cache size (static method)
  static int _getDefaultMaxTableCacheFileSize() {
    if (PlatformHandler.isWeb) {
      // Fixed smaller cache for Web environment
      return 2 * 1024 * 1024; // 2MB
    } else if (PlatformHandler.isMobile) {
      // Medium configuration for mobile devices
      return 10 * 1024 * 1024; // 10MB
    } else if (PlatformHandler.isServerEnvironment) {
      // Larger default cache for server environment
      return 500 * 1024 * 1024; // 500MB
    } else {
      // Higher configuration for desktop devices
      return 100 * 1024 * 1024; // 100MB
    }
  }

  /// Start memory detection and cache optimization
  static void startMemoryOptimization() {
    final instance = CacheSettings();
    if (instance._optimizationInProgress) return;

    instance._optimizationInProgress = true;

    PlatformHandler.getSystemMemoryMB().then((memoryMB) {
      int newCacheSize;

      if (PlatformHandler.isWeb) {
        newCacheSize = 2 * 1024 * 1024; // Fixed 2MB for Web
      } else if (PlatformHandler.isMobile) {
        // Adjust based on available memory for mobile devices
        if (memoryMB < 1024) {
          newCacheSize = 5 * 1024 * 1024; // <1GB memory: 5MB cache
        } else if (memoryMB < 2048) {
          newCacheSize = 10 * 1024 * 1024; // 1-2GB memory: 10MB cache
        } else if (memoryMB < 4096) {
          newCacheSize = 20 * 1024 * 1024; // 2-4GB memory: 20MB cache
        } else {
          newCacheSize = 30 * 1024 * 1024; // >4GB memory: 30MB cache
        }
      } else if (PlatformHandler.isServerEnvironment) {
        // Server environment - use larger proportion of available memory for cache
        final memoryGB = memoryMB / 1024.0;

        // Server memory tiering strategy (50-70% of total memory)
        if (memoryGB < 8) {
          // Small server (<8GB): 50% memory for cache, max 1GB
          newCacheSize = min((memoryMB * 0.5).toInt(), 1024) * 1024 * 1024;
        } else if (memoryGB < 16) {
          // Medium server (8-16GB): max 2GB cache
          newCacheSize = min((memoryMB * 0.55).toInt(), 2048) * 1024 * 1024;
        } else if (memoryGB < 32) {
          // Large server (16-32GB): max 5GB cache
          newCacheSize = min((memoryMB * 0.6).toInt(), 5120) * 1024 * 1024;
        } else if (memoryGB < 64) {
          // Extra large server (32-64GB): max 10GB cache
          newCacheSize = min((memoryMB * 0.65).toInt(), 10240) * 1024 * 1024;
        } else {
          // Enterprise server (>64GB): max 20GB cache
          newCacheSize = min((memoryMB * 0.7).toInt(), 20480) * 1024 * 1024;
        }
      } else {
        // Adjust based on available memory for desktop devices
        if (memoryMB < 2048) {
          newCacheSize = 20 * 1024 * 1024; // <2GB memory: 20MB cache
        } else if (memoryMB < 4096) {
          newCacheSize = 50 * 1024 * 1024; // 2-4GB memory: 50MB cache
        } else if (memoryMB < 8192) {
          newCacheSize = 100 * 1024 * 1024; // 4-8GB memory: 100MB cache
        } else if (memoryMB < 16384) {
          newCacheSize = 200 * 1024 * 1024; // 8-16GB memory: 200MB cache
        } else {
          newCacheSize = 300 * 1024 * 1024; // >16GB memory: 300MB cache
        }
      }

      // Update cache configuration
      instance._optimizedTableCacheSize = newCacheSize;
      instance._optimizationInProgress = false;
    }).catchError((e) {
      // Don't change default value on error
      instance._optimizationInProgress = false;
    });
  }
}
