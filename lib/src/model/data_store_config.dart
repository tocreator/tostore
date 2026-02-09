import 'dart:convert';
import 'dart:typed_data';

import '../handler/common.dart';
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

  /// enable monitoring
  final bool enableMonitoring;

  /// enable compression
  final bool enableCompression;

  /// enable auto repair
  final bool enableAutoRepair;

  /// Encryption configuration
  /// If null, will use default encryption settings
  final EncryptionConfig? encryptionConfig;

  /// migration config
  final MigrationConfig? migrationConfig;

  /// max partition file size based on platform
  /// Web: 64KB, Mobile: 4MB, Desktop: 16MB, Server: 256-1024MB (dynamic)
  final int maxPartitionFileSize;

  /// Enable diagnostic logging (info/debug/warn/error).
  /// This controls application/engine diagnostic prints, not commit log/WAL.
  final bool enableLog;

  /// Diagnostic log level for application/engine logs (not commit log/WAL).
  final LogLevel logLevel;

  /// Maximum concurrency for CPU-bound tasks (isolates)
  final int maxConcurrency;

  /// Maximum concurrency for I/O-bound tasks (file processing)
  final int maxIoConcurrency;

  /// Maximum number of concurrent table partition maintenances (e.g., processTablePartitions)
  final int maxConcurrentPartitionMaintenances;

  /// Default query limit when the caller does not explicitly specify `limit`.
  ///
  /// - Set to a positive number (recommended) to avoid unbounded result sets that
  ///   can cause memory pressure in large-scale tables.
  /// - Set to 0 (or negative) to keep legacy behavior (no default limit).
  final int defaultQueryLimit;

  /// Hard cap for query `offset` to prevent pathological pagination that may
  /// cause excessive IO and memory pressure.
  ///
  /// - Set to a positive number to enforce a max offset.
  /// - Set to 0 (or negative) to disable the check.
  final int maxQueryOffset;

  /// Distributed node configuration
  final DistributedNodeConfig distributedNodeConfig;

  /// Memory threshold in MB for all caches combined
  /// If null, system will automatically determine appropriate value based on available memory
  final int? cacheMemoryBudgetMB;

  /// Whether to prewarm the cache, when is true, the cache will be prewarmed when the data store is initialized
  final bool? enablePrewarmCache;

  /// The threshold in megabytes for automatic cache prewarming when [enablePrewarmCache] is true.
  final int prewarmThresholdMB;

  /// Log segment file size in bytes.
  /// Defaults to a fraction of the main data partition size.
  final int maxLogPartitionFileSize;

  /// WAL/log write batch size for background log persistence.
  /// Controls how many log entries are written to the log file per batch.
  /// This is independent of [writeBatchSize] which controls table data flush batching.
  final int logWriteBatchSize;

  /// The cycle length for log partition indices before they wrap around.
  /// Defaults to 900,000. after the cycle, the log partition index will be reset to 0.
  final int logPartitionCycle;

  /// Enable/disable WAL (write-ahead logging) file persistence.
  final bool enableJournal;

  /// Write batch size for WAL-driven parallel flush processing.
  final int writeBatchSize;

  /// Max latency before forcing a flush (milliseconds).
  final int maxFlushLatencyMs;

  /// A/B parallel journal file size threshold (bytes) before rotation.
  final int parallelJournalMaxFileSize;

  /// Maximum number of open file handles to keep in the handle pool (native only).
  final int maxOpenFiles;

  /// Background flush policy for recovery artifacts (WAL/journal/meta) only.
  final RecoveryFlushPolicy recoveryFlushPolicy;

  /// Whether to persist recovery artifacts (WAL/journal/meta) at commit/batch boundaries.
  /// Set true to ensure durability on commit; false to rely on background flush only.
  final bool persistRecoveryOnCommit;

  /// Default transaction isolation level for this instance
  /// readCommitted: readers only see committed data
  /// serializable: Serializable Snapshot Isolation (SSI)
  final TransactionIsolationLevel defaultTransactionIsolationLevel;

  /// transaction timeout
  final Duration transactionTimeout;

  /// Whether to enable periodic transaction metadata cleanup
  final bool enableTransactionCleanup;

  /// Interval between transaction cleanups in milliseconds
  final int transactionCleanupIntervalMs;

  /// Time-to-live for transaction metadata in milliseconds
  final int transactionMetaTtlMs;

  /// The budgeted duration in milliseconds to yield execution for UI thread responsiveness during intensive tasks.
  /// Defaults to 8ms for client (UI) platforms, 50ms for server.
  final int yieldDurationMs;

  DataStoreConfig({
    this.dbPath,
    this.dbName = 'default',
    this.spaceName = 'default',
    this.compressionLevel = 6,
    this.enableMonitoring = true,
    this.enableCompression = true,
    this.enableAutoRepair = true,
    this.encryptionConfig,
    this.migrationConfig = const MigrationConfig(),
    int? maxPartitionFileSize,
    this.enableLog = true,
    this.logLevel = LogLevel.warn,
    int? maxConcurrency,
    int? maxIoConcurrency,
    DistributedNodeConfig? distributedNodeConfig,
    this.cacheMemoryBudgetMB,
    this.enablePrewarmCache,
    int? prewarmThresholdMB,
    int? maxLogPartitionFileSize,
    this.logPartitionCycle = 900000,
    bool? enableJournal,
    int? logWriteBatchSize,
    int? writeBatchSize,
    int? maxFlushLatencyMs,
    int? parallelJournalMaxFileSize,
    int? maxOpenFiles,
    RecoveryFlushPolicy? recoveryFlushPolicy,
    bool? persistRecoveryOnCommit,
    TransactionIsolationLevel? defaultTransactionIsolationLevel,
    this.transactionTimeout = const Duration(minutes: 5),
    this.enableTransactionCleanup = true,
    int? transactionCleanupIntervalMs,
    int? transactionMetaTtlMs,
    int? maxConcurrentPartitionMaintenances,
    int? defaultQueryLimit,
    int? maxQueryOffset,
    int? yieldDurationMs,
  })  : maxPartitionFileSize =
            maxPartitionFileSize ?? _getDefaultMaxPartitionFileSize(),
        maxLogPartitionFileSize =
            maxLogPartitionFileSize ?? _getDefaultMaxPartitionFileSize(),
        enableJournal = enableJournal ?? !PlatformHandler.isWeb,
        logWriteBatchSize = logWriteBatchSize ?? _getDefaultLogWriteBatchSize(),
        writeBatchSize = writeBatchSize ?? _getDefaultWriteBatchSize(),
        maxFlushLatencyMs = maxFlushLatencyMs ?? _getDefaultMaxFlushLatencyMs(),
        parallelJournalMaxFileSize = parallelJournalMaxFileSize ??
            _getDefaultParallelJournalMaxFileSize(),
        maxConcurrency = maxConcurrency ?? _getDefaultMaxConcurrent(),
        maxIoConcurrency = maxIoConcurrency ??
            _getDefaultMaxIoConcurrent(
                maxConcurrency ?? _getDefaultMaxConcurrent(),
                maxPartitionFileSize ?? _getDefaultMaxPartitionFileSize()),
        maxConcurrentPartitionMaintenances =
            maxConcurrentPartitionMaintenances ??
                _getDefaultMaxConcurrentPartitionMaintenances(),
        defaultQueryLimit = defaultQueryLimit ?? 1000,
        maxQueryOffset = maxQueryOffset ?? 10000,
        distributedNodeConfig =
            distributedNodeConfig ?? const DistributedNodeConfig(),
        prewarmThresholdMB =
            prewarmThresholdMB ?? _getDefaultPrewarmThreshold(),
        maxOpenFiles = maxOpenFiles ?? _getDefaultMaxOpenHandles(),
        recoveryFlushPolicy =
            recoveryFlushPolicy ?? _getDefaultRecoveryFlushPolicy(),
        persistRecoveryOnCommit =
            persistRecoveryOnCommit ?? _getDefaultPersistRecoveryOnCommit(),
        defaultTransactionIsolationLevel = defaultTransactionIsolationLevel ??
            _getDefaultTransactionIsolationLevel(),
        transactionCleanupIntervalMs = transactionCleanupIntervalMs ?? 600000,
        transactionMetaTtlMs = transactionMetaTtlMs ?? 600000,
        yieldDurationMs = yieldDurationMs ?? _getDefaultYieldDurationMs();

  /// Default yield duration based on platform constraint
  static int _getDefaultYieldDurationMs() {
    if (PlatformHandler.isServerEnvironment) {
      return 50; // Server: prioritize throughput over latency
    }
    return 8; // Client: prioritize 120fps/60fps UI responsiveness
  }

  /// get default partition file size limit, based on platform
  static int _getDefaultMaxPartitionFileSize() {
    if (PlatformHandler.isWeb) {
      return 64 * 1024; // Web: 64KB - Browser memory constraints
    } else if (PlatformHandler.isMobile) {
      return 4 * 1024 * 1024; // Mobile: 4MB
    } else if (PlatformHandler.isServerEnvironment) {
      // Server: prefer larger partitions to curb partition explosion while
      // keeping sparse-index guided reads efficient. Scale with recommended
      // concurrency, bounded to avoid excessive per-partition IO/caching cost.
      final cores = PlatformHandler.recommendedConcurrency;
      const int base = 256 * 1024 * 1024; // 256MB baseline
      // Add 32MB per usable core, up to 16 cores (caps growth to 512MB add-on).
      final int scaled = base + (min(cores, 16) * 32 * 1024 * 1024);
      // Clamp between 256MB and 1024MB.
      return min(max(scaled, base), 1024 * 1024 * 1024);
    } else {
      // Desktop platform: 16MB
      return 16 * 1024 * 1024;
    }
  }

  /// Default WAL/log write batch size for background persistence.
  /// Tuned separately from [writeBatchSize] which is for table data flush.
  static int _getDefaultLogWriteBatchSize() {
    if (PlatformHandler.isWeb) {
      return 1000;
    } else if (PlatformHandler.isMobile) {
      return 2000;
    } else if (PlatformHandler.isServerEnvironment) {
      // Server: higher throughput
      return 10000;
    } else {
      // Desktop
      return 5000;
    }
  }

  /// Parse log level from string
  static LogLevel _parseLogLevel(dynamic value) {
    if (value == null) return LogLevel.warn;

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
        return LogLevel.warn;
      }
    }

    return LogLevel.warn;
  }

  /// Get default max concurrency
  static int _getDefaultMaxConcurrent() {
    return PlatformHandler.recommendedConcurrency;
  }

  /// Get default max IO concurrency
  ///
  /// Takes into account:
  /// - CPU cores (base concurrency)
  /// - Partition file size (larger partitions need more memory/CPU per task
  ///   for sparse-index parsing and block encoding/decoding)
  static int _getDefaultMaxIoConcurrent(
      int cpuConcurrent, int partitionFileSize) {
    // Calculate base I/O concurrency from CPU cores
    int baseIo;
    int minIo;
    int maxIo;

    if (PlatformHandler.isServerEnvironment) {
      // Server: IO is highly parallelizable, use 4x CPU cores
      // But clamp to reasonable limits to avoid FD exhaustion
      baseIo = cpuConcurrent * 4;
      minIo = 32;
      maxIo = 256;
    } else if (PlatformHandler.isDesktop) {
      // Desktop: 2x CPU cores
      baseIo = cpuConcurrent * 3;
      minIo = 12;
      maxIo = 64;
    } else if (PlatformHandler.isMobile) {
      // Mobile: 2x CPU cores, but bounded
      baseIo = cpuConcurrent * 3;
      minIo = 12;
      maxIo = 64;
    } else {
      // Web: keep low regardless of partition size
      return 6;
    }

    // Scale down concurrency for large partition files
    // Large partitions require more memory for:
    // - Sparse index structures (grows with partition size)
    // - Block buffer allocation during encode/decode
    // - Binary fuse filter construction
    //
    // Thresholds (platform-specific):
    // - Below threshold: use full baseIo
    // - Above threshold: scale down proportionally
    // - At 2x threshold: use ~50% of baseIo
    final int threshold = _getLargePartitionThreshold();
    if (partitionFileSize > threshold) {
      // Linear scale-down: at 2x threshold, use 50% of base concurrency
      // ratio goes from 0.0 (at threshold) to 1.0 (at 2x threshold)
      final double ratio =
          ((partitionFileSize - threshold) / threshold).clamp(0.0, 1.0);
      // scaleFactor goes from 1.0 to 0.5 as ratio goes from 0.0 to 1.0
      final double scaleFactor = 1.0 - (ratio * 0.5);
      baseIo = (baseIo * scaleFactor).floor();
    }

    return baseIo.clamp(minIo, maxIo);
  }

  /// Threshold for considering a partition file "large" for concurrency scaling.
  /// Beyond this size, I/O concurrency is reduced to prevent memory pressure
  /// from heavier sparse-index parsing and block encoding/decoding.
  static int _getLargePartitionThreshold() {
    if (PlatformHandler.isWeb) {
      return 64 * 1024; // 64KB - web has tight memory constraints
    } else if (PlatformHandler.isMobile) {
      return 4 * 1024 * 1024; // 4MB - mobile has moderate constraints
    } else if (PlatformHandler.isServerEnvironment) {
      return 128 * 1024 * 1024; // 128MB - server can handle large partitions
    } else {
      return 8 * 1024 * 1024; // 8MB - desktop balanced
    }
  }

  /// Get default max concurrent processTablePartitions tasks
  static int _getDefaultMaxConcurrentPartitionMaintenances() {
    if (PlatformHandler.isWeb || PlatformHandler.isMobile) {
      return 3;
    }
    final rc = PlatformHandler.recommendedConcurrency;
    final half = (rc / 2).floor();
    if (PlatformHandler.isServerEnvironment) {
      return half.clamp(1, 10);
    }
    // Desktop
    return half.clamp(1, 5);
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

  static int _getDefaultMaxOpenHandles() {
    // Use a conservative default tuned by platform
    if (PlatformHandler.isServerEnvironment) return 512;
    if (PlatformHandler.isDesktop) return 256;
    if (PlatformHandler.isMobile) return 128;
    return 64; // Web/others minimal (not used on web)
  }

  static RecoveryFlushPolicy _getDefaultRecoveryFlushPolicy() {
    // Prefer adaptive across platforms
    return RecoveryFlushPolicy.adaptive;
  }

  static bool _getDefaultPersistRecoveryOnCommit() {
    if (PlatformHandler.isWeb) return false;
    return true; // native defaults to persisting WAL/journal/meta at commit
  }

  static int _getDefaultWriteBatchSize() {
    final int concurrency = PlatformHandler.recommendedConcurrency;
    final int partitionSize = _getDefaultMaxPartitionFileSize();

    // Heuristic: target enough items to saturate available concurrency
    // while keeping each partition's contribution balanced.
    // Assume average record size is ~512 bytes for mobile/web, ~1KB elsewhere.
    final int avgRecordSize =
        (PlatformHandler.isMobile || PlatformHandler.isWeb) ? 512 : 1024;

    // Items needed to fill one partition
    final int itemsPerPartition = (partitionSize / avgRecordSize).ceil();

    // We want enough data to potentially touch at least 'concurrency' partitions
    // to maximize parallel flush throughput.
    // Factor of 1.5 to 2.0 provides buffer for uneven distribution.
    final int targetBatchSize = (itemsPerPartition * concurrency * 1.5).ceil();

    if (PlatformHandler.isWeb) {
      return targetBatchSize.clamp(1000, 5000);
    } else if (PlatformHandler.isMobile) {
      return targetBatchSize.clamp(100000, 200000);
    } else if (PlatformHandler.isServerEnvironment) {
      return targetBatchSize.clamp(100000, 500000);
    } else {
      // Desktop
      return targetBatchSize.clamp(20000, 100000);
    }
  }

  static int _getDefaultMaxFlushLatencyMs() {
    // Favor energy saving with bounded latency; mobile defaults a bit lower
    if (PlatformHandler.isMobile || PlatformHandler.isDesktop) {
      return 5000; // 5s on mobile/desktop
    }
    if (PlatformHandler.isWeb) {
      return 6000; // 6s on web to avoid long main-thread tasks
    }
    return 10000; // 10s on server
  }

  static int _getDefaultParallelJournalMaxFileSize() {
    // Platform-tuned defaults, independent of data partition size
    if (PlatformHandler.isWeb) {
      return 512 * 1024; // 512KB
    } else if (PlatformHandler.isMobile) {
      return 4 * 1024 * 1024; // 4MB
    } else if (PlatformHandler.isServerEnvironment) {
      return 16 * 1024 * 1024; // 16MB
    } else {
      return 8 * 1024 * 1024; // Desktop: 8MB
    }
  }

  /// Default isolation level: prefer readCommitted for broad compatibility
  static TransactionIsolationLevel _getDefaultTransactionIsolationLevel() {
    return TransactionIsolationLevel.readCommitted;
  }

  /// from json create config
  factory DataStoreConfig.fromJson(Map<String, dynamic> json) {
    // Parse isolation level
    TransactionIsolationLevel? parsedIsolation;
    final isoVal = json['transactionIsolationLevel'];
    if (isoVal is String) {
      switch (isoVal.toLowerCase()) {
        case 'readcommitted':
        case 'read_committed':
          parsedIsolation = TransactionIsolationLevel.readCommitted;
          break;
        case 'serializable':
          parsedIsolation = TransactionIsolationLevel.serializable;
          break;
      }
    } else if (isoVal is int) {
      try {
        parsedIsolation = TransactionIsolationLevel.values[isoVal];
      } catch (_) {}
    }

    // Parse recovery flush policy
    RecoveryFlushPolicy? parsedRecoveryFlushPolicy;
    final dynPolicy = json['recoveryFlushPolicy'];
    if (dynPolicy is String) {
      switch (dynPolicy.toLowerCase()) {
        case 'off':
          parsedRecoveryFlushPolicy = RecoveryFlushPolicy.off;
          break;
        case 'low':
          parsedRecoveryFlushPolicy = RecoveryFlushPolicy.low;
          break;
        case 'medium':
          parsedRecoveryFlushPolicy = RecoveryFlushPolicy.medium;
          break;
        case 'high':
          parsedRecoveryFlushPolicy = RecoveryFlushPolicy.high;
          break;
        case 'adaptive':
          parsedRecoveryFlushPolicy = RecoveryFlushPolicy.adaptive;
          break;
      }
    }

    // Parse encryption config if present
    EncryptionConfig? parsedEncryptionConfig;
    if (json['encryptionConfig'] != null) {
      parsedEncryptionConfig = EncryptionConfig.fromJson(
          json['encryptionConfig'] as Map<String, dynamic>);
    } else if (json['encryptionType'] != null ||
        json['encodingKey'] != null ||
        json['encryptionKey'] != null) {
      // Convert old format to EncryptionConfig for backward compatibility
      final encryptionType = json['encryptionType'] != null
          ? EncryptionTypeExtension.fromConfigString(
              json['encryptionType'] as String)
          : (json['enableEncoding'] as bool? ?? false)
              ? (json['enableEncodingObfuscation'] as bool? ?? false)
                  ? EncryptionType.xorObfuscation
                  : EncryptionType.none
              : EncryptionType.xorObfuscation;
      parsedEncryptionConfig = EncryptionConfig(
        encryptionType: encryptionType,
        encodingKey: json['encodingKey'] as String?,
        encryptionKey: json['encryptionKey'] as String?,
        deviceBinding: false,
      );
    }

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
      encryptionConfig: parsedEncryptionConfig,
      migrationConfig: json['migrationConfig'] != null
          ? MigrationConfig.fromJson(
              json['migrationConfig'] as Map<String, dynamic>)
          : const MigrationConfig(),
      maxPartitionFileSize: json['maxPartitionFileSize'] as int?,
      enableLog: json['enableLog'] as bool? ?? true,
      logLevel: _parseLogLevel(json['logLevel']),
      maxConcurrency: json['maxConcurrency'] as int?,
      maxIoConcurrency: json['maxIoConcurrency'] as int?,
      distributedNodeConfig: json['distributedNodeConfig'] != null
          ? DistributedNodeConfig.fromJson(
              json['distributedNodeConfig'] as Map<String, dynamic>)
          : const DistributedNodeConfig(),
      cacheMemoryBudgetMB: json['cacheMemoryBudgetMB'] as int?,
      enablePrewarmCache: json['enablePrewarmCache'] as bool?,
      prewarmThresholdMB: json['prewarmThresholdMB'] as int?,
      maxLogPartitionFileSize: json['maxLogPartitionFileSize'] as int?,
      logPartitionCycle: json['logPartitionCycle'] as int? ?? 900000,
      enableJournal: json['enableJournal'] as bool? ?? true,
      logWriteBatchSize: json['logWriteBatchSize'] as int?,
      writeBatchSize: json['writeBatchSize'] as int?,
      maxFlushLatencyMs: json['maxFlushLatencyMs'] as int?,
      parallelJournalMaxFileSize: json['parallelJournalMaxFileSize'] as int?,
      maxOpenFiles: json['maxOpenFiles'] as int?,
      recoveryFlushPolicy:
          parsedRecoveryFlushPolicy ?? _getDefaultRecoveryFlushPolicy(),
      persistRecoveryOnCommit: json['persistRecoveryOnCommit'] as bool? ??
          _getDefaultPersistRecoveryOnCommit(),
      defaultTransactionIsolationLevel:
          parsedIsolation ?? _getDefaultTransactionIsolationLevel(),
      enableTransactionCleanup:
          json['enableTransactionCleanup'] as bool? ?? true,
      transactionCleanupIntervalMs:
          json['transactionCleanupIntervalMs'] as int?,
      transactionMetaTtlMs: json['transactionMetaTtlMs'] as int?,
      maxConcurrentPartitionMaintenances:
          json['maxConcurrentPartitionMaintenances'] as int?,
      defaultQueryLimit: (json['defaultQueryLimit'] is int)
          ? json['defaultQueryLimit'] as int
          : int.tryParse('${json['defaultQueryLimit']}'),
      maxQueryOffset: (json['maxQueryOffset'] is int)
          ? json['maxQueryOffset'] as int
          : int.tryParse('${json['maxQueryOffset']}'),
      yieldDurationMs: json['yieldDurationMs'] as int?,
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
      if (encryptionConfig != null)
        'encryptionConfig': encryptionConfig!.toJson(),
      'migrationConfig': migrationConfig?.toJson(),
      'maxPartitionFileSize': maxPartitionFileSize,
      'enableLog': enableLog,
      'logLevel': logLevel.toString().split('.').last,
      'maxConcurrency': maxConcurrency,
      'maxIoConcurrency': maxIoConcurrency,
      'distributedNodeConfig': distributedNodeConfig.toJson(),
      'maxConcurrentPartitionMaintenances': maxConcurrentPartitionMaintenances,
      'cacheMemoryBudgetMB': cacheMemoryBudgetMB,
      'enablePrewarmCache': enablePrewarmCache,
      'prewarmThresholdMB': prewarmThresholdMB,
      'maxLogPartitionFileSize': maxLogPartitionFileSize,
      'logPartitionCycle': logPartitionCycle,
      'enableJournal': enableJournal,
      'logWriteBatchSize': logWriteBatchSize,
      'writeBatchSize': writeBatchSize,
      'maxFlushLatencyMs': maxFlushLatencyMs,
      'parallelJournalMaxFileSize': parallelJournalMaxFileSize,
      'maxOpenFiles': maxOpenFiles,
      'recoveryFlushPolicy': recoveryFlushPolicy.toString().split('.').last,
      'persistRecoveryOnCommit': persistRecoveryOnCommit,
      'transactionIsolationLevel':
          defaultTransactionIsolationLevel.toString().split('.').last,
      'enableTransactionCleanup': enableTransactionCleanup,
      'transactionCleanupIntervalMs': transactionCleanupIntervalMs,
      'transactionMetaTtlMs': transactionMetaTtlMs,
      'defaultQueryLimit': defaultQueryLimit,
      'maxQueryOffset': maxQueryOffset,
      'yieldDurationMs': yieldDurationMs,
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
    EncryptionConfig? encryptionConfig,
    MigrationConfig? migrationConfig,
    int? maxPartitionFileSize,
    bool? enableLog,
    LogLevel? logLevel,
    int? maxConcurrency,
    int? maxIoConcurrency,
    DistributedNodeConfig? distributedNodeConfig,
    int? cacheMemoryBudgetMB,
    bool? enablePrewarmCache,
    int? prewarmThresholdMB,
    int? maxLogPartitionFileSize,
    int? logPartitionCycle,
    bool? enableJournal,
    int? logWriteBatchSize,
    int? writeBatchSize,
    int? maxFlushLatencyMs,
    int? parallelJournalMaxFileSize,
    int? maxOpenFiles,
    RecoveryFlushPolicy? recoveryFlushPolicy,
    bool? persistRecoveryOnCommit,
    TransactionIsolationLevel? defaultTransactionIsolationLevel,
    bool? enableTransactionCleanup,
    int? transactionCleanupIntervalMs,
    int? transactionMetaTtlMs,
    int? maxConcurrentPartitionMaintenances,
    int? defaultQueryLimit,
    int? maxQueryOffset,
    int? yieldDurationMs,
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
      encryptionConfig: encryptionConfig ?? this.encryptionConfig,
      migrationConfig: migrationConfig ?? this.migrationConfig,
      maxPartitionFileSize: maxPartitionFileSize ?? this.maxPartitionFileSize,
      enableLog: enableLog ?? this.enableLog,
      logLevel: logLevel ?? this.logLevel,
      maxConcurrency: maxConcurrency ?? this.maxConcurrency,
      maxIoConcurrency: maxIoConcurrency ?? this.maxIoConcurrency,
      distributedNodeConfig:
          distributedNodeConfig ?? this.distributedNodeConfig,
      maxConcurrentPartitionMaintenances: maxConcurrentPartitionMaintenances ??
          this.maxConcurrentPartitionMaintenances,
      cacheMemoryBudgetMB: cacheMemoryBudgetMB ?? this.cacheMemoryBudgetMB,
      enablePrewarmCache: enablePrewarmCache ?? this.enablePrewarmCache,
      prewarmThresholdMB: prewarmThresholdMB ?? this.prewarmThresholdMB,
      maxLogPartitionFileSize:
          maxLogPartitionFileSize ?? this.maxLogPartitionFileSize,
      logPartitionCycle: logPartitionCycle ?? this.logPartitionCycle,
      enableJournal: enableJournal ?? this.enableJournal,
      logWriteBatchSize: logWriteBatchSize ?? this.logWriteBatchSize,
      writeBatchSize: writeBatchSize ?? this.writeBatchSize,
      maxFlushLatencyMs: maxFlushLatencyMs ?? this.maxFlushLatencyMs,
      parallelJournalMaxFileSize:
          parallelJournalMaxFileSize ?? this.parallelJournalMaxFileSize,
      maxOpenFiles: maxOpenFiles ?? this.maxOpenFiles,
      recoveryFlushPolicy: recoveryFlushPolicy ?? this.recoveryFlushPolicy,
      persistRecoveryOnCommit:
          persistRecoveryOnCommit ?? this.persistRecoveryOnCommit,
      defaultTransactionIsolationLevel: defaultTransactionIsolationLevel ??
          this.defaultTransactionIsolationLevel,
      enableTransactionCleanup:
          enableTransactionCleanup ?? this.enableTransactionCleanup,
      transactionCleanupIntervalMs:
          transactionCleanupIntervalMs ?? this.transactionCleanupIntervalMs,
      transactionMetaTtlMs: transactionMetaTtlMs ?? this.transactionMetaTtlMs,
      defaultQueryLimit: defaultQueryLimit ?? this.defaultQueryLimit,
      maxQueryOffset: maxQueryOffset ?? this.maxQueryOffset,
      yieldDurationMs: yieldDurationMs ?? this.yieldDurationMs,
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

/// Transaction isolation levels
enum TransactionIsolationLevel {
  /// Read committed: readers only see committed data
  readCommitted,

  /// Serializable (SSI): Serializable Snapshot Isolation
  serializable,
}

/// Background flush policy for recovery artifacts (WAL/journal/meta)
enum RecoveryFlushPolicy {
  /// Disable periodic background flush (manual or on-close only)
  off,

  /// Low frequency, optimized for energy saving
  low,

  /// Balanced default frequency
  medium,

  /// High frequency, optimized for durability/latency
  high,

  /// Adaptive: auto-adjust based on recent write activity
  adaptive,
}

/// Encryption type enumeration for data encoding and encryption
enum EncryptionType {
  /// No encryption, only compression (highest performance)
  none,

  /// XOR obfuscation (lightweight, fast, provides basic privacy protection)
  /// Recommended for most use cases to balance security and performance
  xorObfuscation,

  /// ChaCha20-Poly1305 AEAD encryption (pure Dart implementation)
  /// Faster than AES-GCM in pure Dart, compatible with mainstream libraries
  chacha20Poly1305,

  /// AES-256-GCM AEAD encryption (pure Dart implementation)
  /// Industry standard, slower than ChaCha20-Poly1305 in pure Dart
  aes256Gcm,
}

extension EncryptionTypeExtension on EncryptionType {
  /// Convert encryption type to integer for storage
  int toInt() {
    switch (this) {
      case EncryptionType.none:
        return 0;
      case EncryptionType.xorObfuscation:
        return 1;
      case EncryptionType.chacha20Poly1305:
        return 2;
      case EncryptionType.aes256Gcm:
        return 3;
    }
  }

  /// Convert encryption type to string for configuration
  String toConfigString() {
    switch (this) {
      case EncryptionType.none:
        return 'none';
      case EncryptionType.xorObfuscation:
        return 'xor';
      case EncryptionType.chacha20Poly1305:
        return 'chacha20';
      case EncryptionType.aes256Gcm:
        return 'aes256';
    }
  }

  /// Create encryption type from integer
  static EncryptionType fromInt(int value) {
    switch (value) {
      case 0:
        return EncryptionType.none;
      case 1:
        return EncryptionType.xorObfuscation;
      case 2:
        return EncryptionType.chacha20Poly1305;
      case 3:
        return EncryptionType.aes256Gcm;
      default:
        return EncryptionType.xorObfuscation; // Default fallback
    }
  }

  /// Create encryption type from configuration string
  static EncryptionType fromConfigString(String value) {
    switch (value.toLowerCase()) {
      case 'none':
        return EncryptionType.none;
      case 'xor':
      case 'xor_obfuscation':
        return EncryptionType.xorObfuscation;
      case 'chacha20':
      case 'chacha20_poly1305':
      case 'chacha20-poly1305':
        return EncryptionType.chacha20Poly1305;
      case 'aes256':
      case 'aes_256_gcm':
      case 'aes-256-gcm':
        return EncryptionType.aes256Gcm;
      default:
        return EncryptionType.xorObfuscation; // Default fallback
    }
  }
}

/// Encryption configuration for data store
/// Supports device binding (path-based) for enhanced security
class EncryptionConfig {
  /// Encryption type for data encoding
  /// Used for encrypting table data, log files, index data, and other critical privacy data
  final EncryptionType encryptionType;

  /// Encoding key for encoding/decoding data
  /// Used for encrypting table data, log files (WAL), index data, and other critical privacy data
  /// If null, will be auto-generated based on device binding or default key
  final String? encodingKey;

  /// Encryption key for encrypting the encodingKey and other critical information
  /// Used to protect the encodingKey and other sensitive metadata
  /// If null, will be auto-generated based on device binding or default key
  final String? encryptionKey;

  /// Device binding (path-based binding)
  /// When enabled, keys will be derived from database path, making data encrypted on one device
  /// unable to be decrypted on another device or after path changes
  ///
  /// Implementation: Uses database path binding internally
  ///
  /// Suitable scenarios:
  /// - Mobile apps (Android/iOS) where database paths are relatively stable
  /// - Single-device applications where data should not be portable
  ///
  /// Warning: Do NOT use in scenarios where database path may change:
  /// - Application data migration between devices
  /// - System updates that may change app storage paths
  /// - Factory reset or app reinstallation
  /// - Custom ROM or ROOT modifications
  ///
  /// If database path changes, encrypted data will become undecryptable.
  /// For portable data scenarios, leave this as false and provide explicit keys.
  final bool deviceBinding;

  const EncryptionConfig({
    this.encryptionType = EncryptionType.xorObfuscation,
    this.encodingKey,
    this.encryptionKey,
    this.deviceBinding = false,
  });

  /// Generate encoding key based on configuration
  /// Returns the encoding key for encrypting table data, logs, indexes, and other critical data
  String generateEncodingKey(String? dbPath) {
    if (encodingKey != null && encodingKey!.isNotEmpty) {
      return encodingKey!;
    }

    if (deviceBinding && dbPath != null && dbPath.isNotEmpty) {
      return _deriveKeyFromPath(dbPath, 'encoding');
    }

    return generateDeviceId('encoding_v1', deviceBinding ? 1 : 0);
  }

  /// Generate encryption key based on configuration
  /// Returns the encryption key for protecting the encodingKey and other sensitive metadata
  String generateEncryptionKey(String? dbPath) {
    if (encryptionKey != null && encryptionKey!.isNotEmpty) {
      return encryptionKey!;
    }

    if (deviceBinding && dbPath != null && dbPath.isNotEmpty) {
      return _deriveKeyFromPath(dbPath, 'encryption');
    }

    return generateDeviceId('encryption_v1', deviceBinding ? 1 : 0);
  }

  /// Derive key from database path
  String _deriveKeyFromPath(String dbPath, String purpose) {
    // Normalize path to handle different path separators
    final normalizedPath = dbPath.replaceAll(RegExp(r'[/\\]+'), '/');

    // Combine path and purpose
    final combined = 'path:$normalizedPath|purpose:$purpose';

    // Derive key from combined string
    return _deriveKeyFromString(combined);
  }

  /// Derive a deterministic key from a string
  /// Uses a simple but effective key derivation function
  String _deriveKeyFromString(String input) {
    // Use UTF-8 encoding
    final inputBytes = utf8.encode(input);

    // Create a 32-byte key using deterministic key derivation
    final keyBytes = Uint8List(32);
    int hash = 0;

    for (int i = 0; i < inputBytes.length; i++) {
      hash = ((hash << 5) - hash) + inputBytes[i];
      hash = hash & hash; // Convert to 32-bit integer
    }

    // Fill key bytes with deterministic values based on input
    for (int i = 0; i < 32; i++) {
      final index = (i * 7 + hash) % inputBytes.length;
      keyBytes[i] = (inputBytes[index] ^ (i * 13 + 41) ^ hash) & 0xFF;
      hash = ((hash << 3) - hash) + keyBytes[i];
    }

    // Convert to base64 string
    final base64Str = base64Encode(keyBytes);
    // Take first 24 characters for key (similar length to default keys)
    return base64Str.substring(
        0, base64Str.length > 24 ? 24 : base64Str.length);
  }

  /// Create from JSON
  factory EncryptionConfig.fromJson(Map<String, dynamic> json) {
    return EncryptionConfig(
      encryptionType: json['encryptionType'] != null
          ? EncryptionTypeExtension.fromConfigString(
              json['encryptionType'] as String)
          : EncryptionType.xorObfuscation,
      encodingKey: json['encodingKey'] as String?,
      encryptionKey: json['encryptionKey'] as String?,
      deviceBinding: json['deviceBinding'] as bool? ??
          json['pathBinding'] as bool? ??
          false, // Backward compatibility
    );
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'encryptionType': encryptionType.toConfigString(),
      if (encodingKey != null) 'encodingKey': encodingKey,
      if (encryptionKey != null) 'encryptionKey': encryptionKey,
      'deviceBinding': deviceBinding,
    };
  }

  /// Create a copy with modified fields
  EncryptionConfig copyWith({
    EncryptionType? encryptionType,
    String? encodingKey,
    String? encryptionKey,
    bool? deviceBinding,
  }) {
    return EncryptionConfig(
      encryptionType: encryptionType ?? this.encryptionType,
      encodingKey: encodingKey ?? this.encodingKey,
      encryptionKey: encryptionKey ?? this.encryptionKey,
      deviceBinding: deviceBinding ?? this.deviceBinding,
    );
  }

  @override
  String toString() {
    return 'EncryptionConfig('
        'encryptionType: $encryptionType, '
        'deviceBinding: $deviceBinding)';
  }
}
