import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../handler/common.dart';
import '../handler/platform_handler.dart';
import '../handler/logger.dart';
import 'migration_config.dart';

/// data store config
class DataStoreConfig {
  /// database path
  final String? dbPath;

  /// Whether to ignore fields not defined in the table schema when inserting/updating data.
  /// If true (default), unknown fields in DML input maps will be silently ignored.
  /// If false, a DbException containing InvalidArgumentStatus will be thrown.
  final bool ignoreUnknownFields;

  /// database name, used for quickly creating different database instances
  final String dbName;

  /// current space name
  final String spaceName;

  /// Persistence mode (file-backed vs pure in-memory).
  ///
  /// Note: Prefer switching mode via factory methods (e.g. `ToStore.open()` / `ToStore.memory()`)
  /// instead of setting this directly in user code.
  final PersistenceMode persistenceMode;

  /// Encryption configuration
  /// If null, will use default encryption settings
  final EncryptionConfig? encryptionConfig;

  /// migration config
  final MigrationConfig? migrationConfig;

  /// max partition file size based on platform
  /// Web: 64KB, Mobile: 256MB, Desktop: 512MB, Server: 1-4GB (dynamic).
  final int maxPartitionFileSize;

  /// Enable diagnostic logging (info/debug/warn/error).
  /// This controls application/engine diagnostic prints, not commit log/WAL.
  @Deprecated('Use ToStore.setLogConfig() instead')
  final bool enableLog;

  /// Diagnostic log level for application/engine logs (not commit log/WAL).
  @Deprecated('Use ToStore.setLogConfig() instead')
  final LogLevel logLevel;

  /// Maximum concurrency for CPU-bound tasks (isolates)
  final int maxConcurrency;

  /// Maximum concurrency for I/O-bound tasks (file processing)
  final int maxIoConcurrency;

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
  ///
  /// If null, the engine will derive a threshold from available memory at startup.
  final int? prewarmThresholdMB;

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

  /// Maximum number of open file handles to keep in the handle pool (native only).
  final int maxOpenFiles;

  /// Explicitly force server environment optimizations (throughput prioritized over UI responsiveness).
  final bool isServerEnvironment;

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

  /// Unified database-level TTL cleanup polling interval in milliseconds.
  ///
  /// To avoid excessive polling pressure, values lower than 5 minutes are clamped to 300000.
  final int ttlCleanupIntervalMs;

  /// The budgeted duration in milliseconds to yield execution for UI thread responsiveness during intensive tasks.
  /// Defaults to 8ms for client (UI) platforms, 50ms for server.
  final int yieldDurationMs;

  /// Private generative constructor for DataStoreConfig.
  DataStoreConfig._internal({
    required this.persistenceMode,
    this.dbPath,
    required this.dbName,
    required this.spaceName,
    required this.ignoreUnknownFields,
    this.encryptionConfig,
    this.migrationConfig,
    required this.maxPartitionFileSize,
    required this.enableLog,
    required this.logLevel,
    required this.maxConcurrency,
    required this.maxIoConcurrency,
    required this.distributedNodeConfig,
    this.cacheMemoryBudgetMB,
    this.enablePrewarmCache,
    this.prewarmThresholdMB,
    required this.maxLogPartitionFileSize,
    required this.logPartitionCycle,
    required this.enableJournal,
    required this.logWriteBatchSize,
    required this.writeBatchSize,
    required this.maxFlushLatencyMs,
    required this.maxOpenFiles,
    required this.recoveryFlushPolicy,
    required this.persistRecoveryOnCommit,
    required this.defaultTransactionIsolationLevel,
    required this.transactionTimeout,
    required this.enableTransactionCleanup,
    required this.transactionCleanupIntervalMs,
    required this.transactionMetaTtlMs,
    required this.ttlCleanupIntervalMs,
    required this.defaultQueryLimit,
    required this.maxQueryOffset,
    required this.yieldDurationMs,
    required this.isServerEnvironment,
  });

  /// Factory constructor for DataStoreConfig that handles default parameters
  /// and platform-specific environment resolutions.
  factory DataStoreConfig({
    PersistenceMode persistenceMode = PersistenceMode.file,
    String? dbPath,
    String dbName = 'default',
    String spaceName = 'default',
    bool ignoreUnknownFields = true,
    EncryptionConfig? encryptionConfig,
    MigrationConfig? migrationConfig = const MigrationConfig(),
    int? maxPartitionFileSize,
    bool enableLog = true,
    LogLevel logLevel = LogLevel.warn,
    int? maxConcurrency,
    int? maxIoConcurrency,
    DistributedNodeConfig? distributedNodeConfig,
    int? cacheMemoryBudgetMB,
    bool? enablePrewarmCache,
    int? prewarmThresholdMB,
    int? maxLogPartitionFileSize,
    int logPartitionCycle = 900000,
    bool? enableJournal,
    int? logWriteBatchSize,
    int? writeBatchSize,
    int? maxFlushLatencyMs,
    int? maxOpenFiles,
    RecoveryFlushPolicy? recoveryFlushPolicy,
    bool? persistRecoveryOnCommit,
    TransactionIsolationLevel? defaultTransactionIsolationLevel,
    Duration transactionTimeout = const Duration(minutes: 5),
    bool enableTransactionCleanup = true,
    int? transactionCleanupIntervalMs,
    int? transactionMetaTtlMs,
    int? ttlCleanupIntervalMs,
    int? defaultQueryLimit,
    int? maxQueryOffset,
    int? yieldDurationMs,
    bool? isServerEnvironment,
  }) {
    final resolvedServer =
        isServerEnvironment ?? PlatformHandler.isServerEnvironment;
    final resolvedMaxPartition =
        maxPartitionFileSize ?? _getDefaultMaxPartitionFileSize(resolvedServer);
    final resolvedMaxLogPartition = maxLogPartitionFileSize ??
        _getDefaultMaxLogPartitionFileSize(resolvedServer);
    final resolvedConcurrency = maxConcurrency ?? _getDefaultMaxConcurrent();

    return DataStoreConfig._internal(
      persistenceMode: persistenceMode,
      dbPath: dbPath,
      dbName: dbName,
      spaceName: spaceName,
      ignoreUnknownFields: ignoreUnknownFields,
      encryptionConfig: encryptionConfig,
      migrationConfig: migrationConfig,
      maxPartitionFileSize: resolvedMaxPartition,
      enableLog: enableLog,
      logLevel: logLevel,
      maxConcurrency: resolvedConcurrency,
      maxIoConcurrency: maxIoConcurrency ??
          _getDefaultMaxIoConcurrent(resolvedConcurrency, resolvedServer),
      distributedNodeConfig:
          distributedNodeConfig ?? const DistributedNodeConfig(),
      cacheMemoryBudgetMB: cacheMemoryBudgetMB,
      enablePrewarmCache: enablePrewarmCache,
      prewarmThresholdMB: prewarmThresholdMB,
      maxLogPartitionFileSize: resolvedMaxLogPartition,
      logPartitionCycle: logPartitionCycle,
      enableJournal: enableJournal ?? !PlatformHandler.isWeb,
      logWriteBatchSize:
          logWriteBatchSize ?? _getDefaultLogWriteBatchSize(resolvedServer),
      writeBatchSize: writeBatchSize ??
          _getWriteBatchSize(cacheMemoryBudgetMB, resolvedServer),
      maxFlushLatencyMs:
          maxFlushLatencyMs ?? _getDefaultMaxFlushLatencyMs(resolvedServer),
      maxOpenFiles: maxOpenFiles ?? _getDefaultMaxOpenHandles(resolvedServer),
      recoveryFlushPolicy:
          recoveryFlushPolicy ?? _getDefaultRecoveryFlushPolicy(),
      persistRecoveryOnCommit:
          persistRecoveryOnCommit ?? _getDefaultPersistRecoveryOnCommit(),
      defaultTransactionIsolationLevel: defaultTransactionIsolationLevel ??
          _getDefaultTransactionIsolationLevel(),
      transactionTimeout: transactionTimeout,
      enableTransactionCleanup: enableTransactionCleanup,
      transactionCleanupIntervalMs: transactionCleanupIntervalMs ?? 600000,
      transactionMetaTtlMs: transactionMetaTtlMs ?? 600000,
      ttlCleanupIntervalMs: max(ttlCleanupIntervalMs ?? 300000, 300000),
      defaultQueryLimit: defaultQueryLimit ?? 1000,
      maxQueryOffset: maxQueryOffset ?? 10000,
      yieldDurationMs:
          yieldDurationMs ?? _getDefaultYieldDurationMs(resolvedServer),
      isServerEnvironment: resolvedServer,
    );
  }

  /// Default yield duration based on platform constraint
  static int _getDefaultYieldDurationMs(bool isServer) {
    if (isServer) {
      return 50; // Server: prioritize throughput over latency
    }
    return 8; // Client: prioritize 120fps/60fps UI responsiveness
  }

  /// get default partition file size limit, based on platform
  static int _getDefaultMaxPartitionFileSize(bool isServer) {
    if (PlatformHandler.isWeb) {
      // Web must rewrite whole blobs; keep tiny.
      return 64 * 1024; // 64KB
    } else if (PlatformHandler.isMobile) {
      return 256 * 1024 * 1024; // 256MB
    } else if (isServer) {
      // Server: 1GB baseline (low-spec VPS/containers), scale to 4GB on
      // wider machines. Use real core count — not recommendedConcurrency
      // (which floors at 8 on servers and would oversize tiny boxes).
      final cores = PlatformHandler.processorCores;
      const int base = 1024 * 1024 * 1024; // 1GB
      const int maxSize = 4 * 1024 * 1024 * 1024; // 4GB
      // +192MB per core (up to 16) => +3GB max → 1-4GB range.
      final int scaled = base + (min(max(cores, 1), 16) * 192 * 1024 * 1024);
      return min(max(scaled, base), maxSize);
    } else {
      return 512 * 1024 * 1024; // Desktop: 512MB
    }
  }

  /// Default WAL/txn/redo log segment size — intentionally small and
  /// independent of data partition size.
  static int _getDefaultMaxLogPartitionFileSize(bool isServer) {
    if (PlatformHandler.isWeb) {
      return 64 * 1024; // 64KB
    } else if (isServer) {
      return 8 * 1024 * 1024; // 8MB
    } else {
      // Mobile + desktop
      return 4 * 1024 * 1024; // 4MB
    }
  }

  /// Default WAL/log write batch size for background persistence.
  /// Tuned separately from [writeBatchSize] which is for table data flush.
  static int _getDefaultLogWriteBatchSize(bool isServer) {
    if (PlatformHandler.isWeb) {
      return 1000;
    } else if (PlatformHandler.isMobile) {
      return 10000;
    } else if (isServer) {
      // Server: higher throughput
      return 100000;
    } else {
      // Desktop
      return 20000;
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

  /// get default max io concurrency, based on cpu concurrent and platform
  static int _getDefaultMaxIoConcurrent(int cpuConcurrent, bool isServer) {
    int baseIo;
    int minIo;
    int maxIo;

    if (isServer) {
      // Server: IO is highly parallelizable; clamp to avoid FD exhaustion
      baseIo = cpuConcurrent * 4;
      minIo = 32;
      maxIo = 256;
    } else if (PlatformHandler.isDesktop) {
      baseIo = cpuConcurrent * 3;
      minIo = 12;
      maxIo = 64;
    } else if (PlatformHandler.isMobile) {
      baseIo = cpuConcurrent * 3;
      minIo = 12;
      maxIo = 64;
    } else {
      // Web: keep low
      return 6;
    }

    return baseIo.clamp(minIo, maxIo);
  }

  static int _getDefaultMaxOpenHandles(bool isServer) {
    // Use fine-grained defaults tuned by specific platforms to avoid EMFILE (Too many open files)
    // or handle exhaustion, while maintaining optimal storage engine performance.
    if (PlatformHandler.isWeb) {
      return 64; // Web doesn't use standard OS file descriptors
    }

    if (PlatformHandler.isWindows) {
      // Windows OS handle limit is extremely high, but CRT default limit is 512.
      // 256 is safe and provides excellent concurrency.
      return 256;
    }

    if (PlatformHandler.isMacOS) {
      // macOS has a notoriously low default soft limit of 256 file descriptors per process.
      // Setting to 128 leaves a safe buffer for GUI assets, sockets, and standard I/O.
      return 128;
    }

    if (PlatformHandler.isLinux) {
      // Linux default soft limit is 1024.
      // Server environment gets 512 for higher concurrency, Desktop gets 256.
      return isServer ? 512 : 256;
    }

    if (PlatformHandler.isAndroid) {
      // Android default soft limit is typically 1024+. 128 is highly safe and performant.
      return 128;
    }

    if (PlatformHandler.isIOS) {
      // iOS has a strict file descriptor limit (often 256 soft limit), and shares resources
      // heavily with system frameworks. 64 is a safe default.
      return 64;
    }

    // Fallback default
    return 128;
  }

  static RecoveryFlushPolicy _getDefaultRecoveryFlushPolicy() {
    // Prefer adaptive across platforms
    return RecoveryFlushPolicy.adaptive;
  }

  static bool _getDefaultPersistRecoveryOnCommit() {
    if (PlatformHandler.isWeb) return false;
    return true; // native defaults to persisting WAL/journal/meta at commit
  }

  static int _getWriteBatchSize(int? cacheMemoryBudgetMB, bool isServer) {
    final int cores = PlatformHandler.processorCores;

    // Scale factor based on cores: more cores = more parallel flush capacity
    // For mobile, each core contributes 50k
    // For desktop/server, each core contributes 100k
    final int coreFactor =
        (PlatformHandler.isMobile || PlatformHandler.isWeb) ? 50000 : 100000;

    // Base batch size (e.g., 50k) + per-core bonus
    int targetBatchSize = 50000 + (cores * coreFactor);

    // Memory weighting: If user provides a large memory budget, scale up the batch size.
    // Heuristic: for every 1GB above 1GB, increase batch size by 50%
    if (cacheMemoryBudgetMB != null && cacheMemoryBudgetMB > 1024) {
      final double memoryMultiplier =
          1.0 + (cacheMemoryBudgetMB - 1024) / 1024.0;
      targetBatchSize = (targetBatchSize * memoryMultiplier).round();
    }

    if (PlatformHandler.isWeb) {
      // Web: very conservative due to browser main-thread and memory limits
      return (targetBatchSize / 10).round().clamp(1000, 10000);
    } else if (PlatformHandler.isMobile) {
      // Mobile: 100k - 200k
      return targetBatchSize.clamp(100000, 200000);
    } else if (isServer) {
      // Server: 200k - 1M (High throughput focus)
      return targetBatchSize.clamp(200000, 1000000);
    } else {
      // Desktop: 100k - 200k
      return targetBatchSize.clamp(100000, 200000);
    }
  }

  static int _getDefaultMaxFlushLatencyMs(bool isServer) {
    // Favor energy saving with bounded latency; mobile defaults a bit lower
    if (PlatformHandler.isMobile || PlatformHandler.isDesktop) {
      return 5000; // 5s on mobile/desktop
    }
    if (PlatformHandler.isWeb) {
      return 6000; // 6s on web to avoid long main-thread tasks
    }
    return 10000; // 10s on server
  }

  /// Default isolation level: prefer readCommitted for broad compatibility
  static TransactionIsolationLevel _getDefaultTransactionIsolationLevel() {
    return TransactionIsolationLevel.readCommitted;
  }

  /// from json create config
  factory DataStoreConfig.fromJson(Map<String, dynamic> json) {
    // Parse persistence mode (default: file)
    PersistenceMode parsedPersistenceMode = PersistenceMode.file;
    final pm = json['persistenceMode'];
    if (pm is String) {
      switch (pm.toLowerCase()) {
        case 'memory':
          parsedPersistenceMode = PersistenceMode.memory;
          break;
        case 'file':
        default:
          parsedPersistenceMode = PersistenceMode.file;
          break;
      }
    }

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
      persistenceMode: parsedPersistenceMode,
      dbPath: json['dbPath'] as String?,
      dbName: json['dbName'] as String? ?? 'default',
      spaceName: json['spaceName'] as String? ?? 'default',
      ignoreUnknownFields: json['ignoreUnknownFields'] as bool? ?? true,
      transactionTimeout:
          Duration(milliseconds: json['transactionTimeout'] as int? ?? 300000),
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
      enableJournal: json['enableJournal'] as bool? ?? !PlatformHandler.isWeb,
      logWriteBatchSize: json['logWriteBatchSize'] as int?,
      writeBatchSize: json['writeBatchSize'] as int?,
      maxFlushLatencyMs: json['maxFlushLatencyMs'] as int?,
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
      ttlCleanupIntervalMs: json['ttlCleanupIntervalMs'] as int?,
      defaultQueryLimit: (json['defaultQueryLimit'] is int)
          ? json['defaultQueryLimit'] as int
          : int.tryParse('${json['defaultQueryLimit']}'),
      maxQueryOffset: (json['maxQueryOffset'] is int)
          ? json['maxQueryOffset'] as int
          : int.tryParse('${json['maxQueryOffset']}'),
      yieldDurationMs: json['yieldDurationMs'] as int?,
      isServerEnvironment: json['isServerEnvironment'] as bool?,
    );
  }

  /// convert to json
  Map<String, dynamic> toJson() {
    return {
      'persistenceMode': persistenceMode.toString().split('.').last,
      'dbPath': dbPath,
      'dbName': dbName,
      'spaceName': spaceName,
      'ignoreUnknownFields': ignoreUnknownFields,
      'transactionTimeout': transactionTimeout.inMilliseconds,
      if (encryptionConfig != null)
        'encryptionConfig': encryptionConfig!.toJson(),
      'migrationConfig': migrationConfig?.toJson(),
      'maxPartitionFileSize': maxPartitionFileSize,
      'enableLog': enableLog,
      'logLevel': logLevel.toString().split('.').last,
      'maxConcurrency': maxConcurrency,
      'maxIoConcurrency': maxIoConcurrency,
      'distributedNodeConfig': distributedNodeConfig.toJson(),
      'cacheMemoryBudgetMB': cacheMemoryBudgetMB,
      'enablePrewarmCache': enablePrewarmCache,
      'prewarmThresholdMB': prewarmThresholdMB,
      'maxLogPartitionFileSize': maxLogPartitionFileSize,
      'logPartitionCycle': logPartitionCycle,
      'enableJournal': enableJournal,
      'logWriteBatchSize': logWriteBatchSize,
      'writeBatchSize': writeBatchSize,
      'maxFlushLatencyMs': maxFlushLatencyMs,
      'maxOpenFiles': maxOpenFiles,
      'recoveryFlushPolicy': recoveryFlushPolicy.toString().split('.').last,
      'persistRecoveryOnCommit': persistRecoveryOnCommit,
      'transactionIsolationLevel':
          defaultTransactionIsolationLevel.toString().split('.').last,
      'enableTransactionCleanup': enableTransactionCleanup,
      'transactionCleanupIntervalMs': transactionCleanupIntervalMs,
      'transactionMetaTtlMs': transactionMetaTtlMs,
      'ttlCleanupIntervalMs': ttlCleanupIntervalMs,
      'defaultQueryLimit': defaultQueryLimit,
      'maxQueryOffset': maxQueryOffset,
      'yieldDurationMs': yieldDurationMs,
      'isServerEnvironment': isServerEnvironment,
    };
  }

  /// create new config instance
  DataStoreConfig copyWith({
    PersistenceMode? persistenceMode,
    String? dbPath,
    String? dbName,
    String? spaceName,
    bool? ignoreUnknownFields,
    Duration? transactionTimeout,
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
    int? maxOpenFiles,
    RecoveryFlushPolicy? recoveryFlushPolicy,
    bool? persistRecoveryOnCommit,
    TransactionIsolationLevel? defaultTransactionIsolationLevel,
    bool? enableTransactionCleanup,
    int? transactionCleanupIntervalMs,
    int? transactionMetaTtlMs,
    int? ttlCleanupIntervalMs,
    int? defaultQueryLimit,
    int? maxQueryOffset,
    int? yieldDurationMs,
    bool? isServerEnvironment,
  }) {
    return DataStoreConfig(
      persistenceMode: persistenceMode ?? this.persistenceMode,
      dbPath: dbPath ?? this.dbPath,
      dbName: dbName ?? this.dbName,
      spaceName: spaceName ?? this.spaceName,
      ignoreUnknownFields: ignoreUnknownFields ?? this.ignoreUnknownFields,
      transactionTimeout: transactionTimeout ?? this.transactionTimeout,
      encryptionConfig: encryptionConfig ?? this.encryptionConfig,
      migrationConfig: migrationConfig ?? this.migrationConfig,
      maxPartitionFileSize: maxPartitionFileSize ?? this.maxPartitionFileSize,
      enableLog: enableLog ?? this.enableLog,
      logLevel: logLevel ?? this.logLevel,
      maxConcurrency: maxConcurrency ?? this.maxConcurrency,
      maxIoConcurrency: maxIoConcurrency ?? this.maxIoConcurrency,
      distributedNodeConfig:
          distributedNodeConfig ?? this.distributedNodeConfig,
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
      ttlCleanupIntervalMs:
          max(ttlCleanupIntervalMs ?? this.ttlCleanupIntervalMs, 300000),
      defaultQueryLimit: defaultQueryLimit ?? this.defaultQueryLimit,
      maxQueryOffset: maxQueryOffset ?? this.maxQueryOffset,
      yieldDurationMs: yieldDurationMs ?? this.yieldDurationMs,
      isServerEnvironment: isServerEnvironment ?? this.isServerEnvironment,
    );
  }
}

/// Persistence mode for the engine.
///
/// - [file]: Default durable mode backed by platform storage (files/web storage).
/// - [memory]: Pure in-memory mode. No file IO (including WAL/meta/config).
enum PersistenceMode {
  file,
  memory,
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
  /// No encryption (highest performance)
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

/// Encryption scope configuration
enum EncryptionScope {
  /// Default standard encryption, encrypts key data such as table data, index data, and log data.
  standard,

  /// Full encryption, encrypts the entire engine files completely.
  full,
}

extension EncryptionScopeExtension on EncryptionScope {
  /// Convert encryption scope to string for configuration
  String toConfigString() {
    switch (this) {
      case EncryptionScope.standard:
        return 'standard';
      case EncryptionScope.full:
        return 'full';
    }
  }

  /// Create encryption scope from configuration string
  static EncryptionScope fromConfigString(String? value) {
    if (value == null) return EncryptionScope.standard;
    switch (value.toLowerCase()) {
      case 'standard':
        return EncryptionScope.standard;
      case 'full':
        return EncryptionScope.full;
      default:
        return EncryptionScope.standard;
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

  /// Whether to encrypt vector index data (NGH graph pages, PQ codes, raw vectors).
  ///
  /// Defaults to `false` for maximum vector search performance.
  /// Vector embeddings are derived mathematical representations that are extremely
  /// difficult to reverse-engineer into original data. The original sensitive data
  /// is protected by table-level encryption.
  ///
  /// Set to `true` only when strict compliance requirements mandate full encryption
  /// of all stored data including derived embeddings. Enabling this will add
  /// encryption/decryption overhead to every vector index page read/write operation,
  /// which can significantly impact search latency.
  final bool encryptVectorIndex;

  /// The encryption scope configures how much of the database engine is encrypted.
  /// standard: Default standard encryption, encrypts key data such as table data, index data, and log data.
  /// full: Full encryption, encrypts the entire engine files completely.
  final EncryptionScope encryptionScope;

  const EncryptionConfig({
    this.encryptionType = EncryptionType.none,
    this.encodingKey,
    this.encryptionKey,
    this.deviceBinding = false,
    this.encryptVectorIndex = false,
    this.encryptionScope = EncryptionScope.standard,
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
      0,
      base64Str.length > 24 ? 24 : base64Str.length,
    );
  }

  /// Create from JSON
  factory EncryptionConfig.fromJson(Map<String, dynamic> json) {
    return EncryptionConfig(
      encryptionType: json['encryptionType'] != null
          ? EncryptionTypeExtension.fromConfigString(
              json['encryptionType'] as String,
            )
          : EncryptionType.xorObfuscation,
      encodingKey: json['encodingKey'] as String?,
      encryptionKey: json['encryptionKey'] as String?,
      deviceBinding: json['deviceBinding'] as bool? ??
          json['pathBinding'] as bool? ??
          false, // Backward compatibility
      encryptVectorIndex: json['encryptVectorIndex'] as bool? ?? false,
      encryptionScope: json['encryptionScope'] != null
          ? EncryptionScopeExtension.fromConfigString(
              json['encryptionScope'] as String?,
            )
          : EncryptionScope.standard,
    );
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'encryptionType': encryptionType.toConfigString(),
      if (encodingKey != null) 'encodingKey': encodingKey,
      if (encryptionKey != null) 'encryptionKey': encryptionKey,
      'deviceBinding': deviceBinding,
      'encryptVectorIndex': encryptVectorIndex,
      'encryptionScope': encryptionScope.toConfigString(),
    };
  }

  /// Create a copy with modified fields
  EncryptionConfig copyWith({
    EncryptionType? encryptionType,
    String? encodingKey,
    String? encryptionKey,
    bool? deviceBinding,
    bool? encryptVectorIndex,
    EncryptionScope? encryptionScope,
  }) {
    return EncryptionConfig(
      encryptionType: encryptionType ?? this.encryptionType,
      encodingKey: encodingKey ?? this.encodingKey,
      encryptionKey: encryptionKey ?? this.encryptionKey,
      deviceBinding: deviceBinding ?? this.deviceBinding,
      encryptVectorIndex: encryptVectorIndex ?? this.encryptVectorIndex,
      encryptionScope: encryptionScope ?? this.encryptionScope,
    );
  }

  @override
  String toString() {
    return 'EncryptionConfig('
        'encryptionType: $encryptionType, '
        'deviceBinding: $deviceBinding, '
        'encryptionScope: $encryptionScope)';
  }
}
