import 'dart:async';
import 'dart:math';

import '../handler/logger.dart';
import '../handler/platform_handler.dart';
import '../model/data_store_config.dart';
import '../model/db_exception.dart';
import '../model/flush_pressure_state.dart';
import '../model/memory_info.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import 'crontab_manager.dart';
import 'data_store_impl.dart';

/// Resource status representing the health of system resources (Memory and Disk)
enum ResourceStatus {
  /// Resources are healthy
  normal,

  /// Resources are low, triggers cache cleanup
  warning,

  /// Resources are critically low, triggers write blocking to prevent data loss
  critical,
}

/// Resource manager responsible for dynamically monitoring system memory and disk space
class ResourceManager {
  /// Singleton implementation
  static final ResourceManager _instance = ResourceManager._internal();
  factory ResourceManager() => _instance;
  ResourceManager._internal();

  /// Memory configuration threshold, default is 75% of available system memory
  int _memoryThresholdInMB = 0;

  /// Configured memory threshold in megabytes
  int get memoryThresholdInMB => _memoryThresholdInMB;

  /// Allocation ratios for various caches
  static const double _tableDataCacheRatio = 0.45; // Table data cache 45%
  static const double _indexCacheRatio = 0.30; // Index cache 30%
  static const double _queryCacheRatio = 0.10; // Query cache 10%
  static const double _metaCacheRatio =
      0.10; // Table data and index all meta cache 10%
  static const double _schemaCacheRatio = 0.05; // Schema cache 5%

  /// Size thresholds for various caches (in bytes)
  int _tableDataCacheSize = 0;
  int _indexCacheSize = 0;
  int _queryCacheSize = 0;
  int _schemaCacheSize = 0;
  int _metaCacheSize = 0;

  /// Last cache clear time
  DateTime _lastCacheClearTime = DateTime.now();

  /// Current resource status
  ResourceStatus _status = ResourceStatus.normal;

  /// Current memory status, kept separate from the combined memory/disk status.
  ResourceStatus _memoryStatus = ResourceStatus.normal;

  /// Initialization flag
  bool _initialized = false;

  /// Single-flight handle for [initialize] (startup prefetch / concurrent).
  Future<void>? _initFuture;

  /// Last measured total cache usage across all types (bytes)
  int _lastMeasuredTotalUsageBytes = 0;

  /// Data store reference
  DataStoreImpl? _dataStore;

  /// Cache eviction callback function by type
  final Map<MemoryQuotaType, Function()?> _cacheEvictionCallbacks = {
    MemoryQuotaType.tableData: null,
    MemoryQuotaType.queryResult: null,
    MemoryQuotaType.indexData: null,
    MemoryQuotaType.vectorIndex: null,
    MemoryQuotaType.schema: null,
    MemoryQuotaType.meta: null,
  };

  /// Flag to prevent re-entrant cache cleanup
  bool _isCleaning = false;

  /// Initialize resource manager
  Future<void> initialize(
      DataStoreConfig config, DataStoreImpl dataStore) async {
    if (_initialized) return;
    final inFlight = _initFuture;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    final loadOp = _doInitialize(config, dataStore);
    _initFuture = loadOp;
    try {
      await loadOp;
    } finally {
      if (identical(_initFuture, loadOp)) {
        _initFuture = null;
      }
    }
  }

  /// Await in-flight [initialize] if any; no-op when already initialized or
  /// never started (callers already use sync fallbacks for unset quotas).
  Future<void> ensureInitialized() async {
    if (_initialized) return;
    final inFlight = _initFuture;
    if (inFlight != null) {
      await inFlight;
    }
  }

  Future<void> _doInitialize(
      DataStoreConfig config, DataStoreImpl dataStore) async {
    if (_initialized) return;

    // Store data store reference for accessing cache managers
    _dataStore = dataStore;

    // Set memory threshold
    await _configureMemoryThreshold(config);

    // Calculate cache sizes
    _calculateCacheSizes();

    // Establish an actual resource state before accepting operations instead
    // of waiting for the first periodic monitor tick.
    try {
      await _updateResourceStatus();
    } catch (e) {
      Logger.warn('Initial resource status check failed', rawError: e);
    }

    // Register resource monitoring task
    _registerResourceMonitor();

    _initialized = true;
  }

  /// Total physical system memory in MB (cached on initialization).
  int _systemMemoryMB = 0;
  int get systemMemoryMB => _systemMemoryMB;

  /// Cached warning memory threshold in MB.
  int _warningMemoryThresholdMB = 256;
  int get warningMemoryThresholdMB => _warningMemoryThresholdMB;

  /// Cached critical memory threshold in MB.
  int _criticalMemoryThresholdMB = 32;
  int get criticalMemoryThresholdMB => _criticalMemoryThresholdMB;

  /// Cached recovery hysteresis margin in MB.
  int _recoveryMarginMB = 64;
  int get recoveryMarginMB => _recoveryMarginMB;

  /// Configure memory threshold
  Future<void> _configureMemoryThreshold(DataStoreConfig config) async {
    try {
      // Get available system memory and total memory
      int availableMemoryMB =
          await PlatformHandler.getAvailableSystemMemoryMB();
      int systemMemoryMB = await PlatformHandler.getSystemMemoryMB();
      _systemMemoryMB = systemMemoryMB;
      _warningMemoryThresholdMB =
          calculateWarningMemoryThresholdMB(systemMemoryMB);
      _criticalMemoryThresholdMB =
          calculateCriticalMemoryThresholdMB(systemMemoryMB);
      _recoveryMarginMB = max(64, (systemMemoryMB * 0.03).toInt());

      // Get the smaller value between available memory and total memory as the base value
      int baseMemoryMB = availableMemoryMB < systemMemoryMB * 0.7
          ? availableMemoryMB
          : (systemMemoryMB * 0.7).toInt();

      if (config.cacheMemoryBudgetMB != null &&
          config.cacheMemoryBudgetMB! > 0) {
        // Use user-configured memory threshold, but ensure it doesn't exceed available memory
        _memoryThresholdInMB = min(config.cacheMemoryBudgetMB!, baseMemoryMB);
      } else {
        // Default to 75% of available memory
        _memoryThresholdInMB = (baseMemoryMB * 0.75).toInt();
      }

      // Ensure memory threshold is not less than minimum value
      _memoryThresholdInMB =
          max(_memoryThresholdInMB, _getMinimumMemoryThreshold());
    } catch (e) {
      Logger.error('Failed to configure memory threshold', rawError: e);
      // Set default threshold
      _memoryThresholdInMB = _getDefaultMemoryThreshold();
      _systemMemoryMB = _getDefaultMemoryThreshold() * 2;
      _warningMemoryThresholdMB =
          calculateWarningMemoryThresholdMB(_systemMemoryMB);
      _criticalMemoryThresholdMB =
          calculateCriticalMemoryThresholdMB(_systemMemoryMB);
      _recoveryMarginMB = 64;
    }
  }

  /// Get minimum memory threshold
  int _getMinimumMemoryThreshold() {
    if (PlatformHandler.isWeb) {
      return 64; // Web environment minimum 64MB
    } else if (PlatformHandler.isMobile) {
      return 128; // Mobile device minimum 128MB
    } else {
      return 256; // Desktop and server environment minimum 256MB
    }
  }

  /// Get default memory threshold
  int _getDefaultMemoryThreshold() {
    if (PlatformHandler.isWeb) {
      return 128; // Web default 128MB
    } else if (PlatformHandler.isMobile) {
      return 512; // Mobile device default 512MB
    } else if (PlatformHandler.isServerEnvironment) {
      return 2048; // Server default 2GB
    } else {
      return 1024; // Desktop default 1GB
    }
  }

  /// Current interval used for periodic resource monitoring
  ExecuteInterval _currentMonitorInterval = ExecuteInterval.seconds30;

  /// Consecutive sample count showing normal memory levels before downgrading to 30s
  int _normalRecoveryCount = 0;

  /// Whether the database is currently experiencing active disk flush pressure
  bool get _isFlushBusy =>
      _dataStore?.parallelJournalManager.pressureState ==
      FlushPressureState.busy;

  /// Current recommended cache eviction ratio based on status severity
  double get currentEvictionRatio =>
      getEvictionRatio(MemoryQuotaType.tableData);

  /// Get specialized eviction ratio based on cache quota type and flush pressure.
  ///
  /// Protects flush working-set (B+ tree pages) from over-eviction while
  /// aggressively pruning non-essential caches (query results, row record caches)
  /// under active flush pressure.
  double getEvictionRatio(MemoryQuotaType type) {
    if (_status == ResourceStatus.critical) {
      switch (type) {
        case MemoryQuotaType.queryResult:
          return 1.0; // Evict all query caches in emergency
        case MemoryQuotaType.tableData:
          return 0.50; // Prune half of table data cache
        case MemoryQuotaType.indexData:
          return 0.35; // Preserve index B+tree pages for flush recovery
        case MemoryQuotaType.vectorIndex:
          return 0.50;
        case MemoryQuotaType.schema:
        case MemoryQuotaType.meta:
          return 0.0;
      }
    }

    if (_status == ResourceStatus.warning) {
      if (_isFlushBusy) {
        switch (type) {
          case MemoryQuotaType.queryResult:
            return 0.85; // Clean 85% of query caches to release non-flush memory
          case MemoryQuotaType.tableData:
            return 0.40; // Prune record maps, protect B+tree page cache
          case MemoryQuotaType.indexData:
            return 0.25; // Strictly protect index B+tree pages needed for flushing
          case MemoryQuotaType.vectorIndex:
            return 0.30;
          case MemoryQuotaType.schema:
          case MemoryQuotaType.meta:
            return 0.0;
        }
      }
      return 0.30; // Standard warning ratio
    }

    return 0.20; // Normal baseline
  }

  /// Specialized eviction ratio for hot record cache (heap Map objects)
  double getRecordCacheEvictionRatio() {
    if (_status == ResourceStatus.critical) return 0.60;
    if (_status == ResourceStatus.warning) {
      return _isFlushBusy ? 0.50 : 0.35;
    }
    return 0.20;
  }

  /// Specialized eviction ratio for B+Tree page caches (disk IO protection)
  double getPageCacheEvictionRatio() {
    if (_status == ResourceStatus.critical)
      return 0.35; // Never wipe B+tree pages
    if (_status == ResourceStatus.warning) {
      return _isFlushBusy ? 0.20 : 0.25; // Protect pages during active flush
    }
    return 0.15;
  }

  /// Current eviction cooldown duration in seconds based on severity and flush pressure
  int get _currentEvictionCooldownSeconds {
    switch (_status) {
      case ResourceStatus.critical:
        return 2;
      case ResourceStatus.warning:
        return _isFlushBusy ? 1 : 5;
      case ResourceStatus.normal:
        return 10;
    }
  }

  /// Calculate dynamic warning threshold in MB based on total system memory.
  /// Uses 15% of total system memory as baseline, capped at 2048 MB (sufficient
  /// safety buffer for 1M-record batch flush) and floored at 64 MB.
  static int calculateWarningMemoryThresholdMB(int systemMemoryMB) {
    if (systemMemoryMB <= 0) return 64;
    final ratioMB = (systemMemoryMB * 0.15).toInt();
    return ratioMB.clamp(64, 2048);
  }

  /// Calculate dynamic critical threshold in MB based on total system memory.
  /// Uses 3.5% of total system memory as baseline, capped at 512 MB and floored
  /// at 32 MB for emergency write blocking.
  static int calculateCriticalMemoryThresholdMB(int systemMemoryMB) {
    if (systemMemoryMB <= 0) return 32;
    final ratioMB = (systemMemoryMB * 0.035).toInt();
    return ratioMB.clamp(32, 512);
  }

  /// Register resource monitoring periodic task
  void _registerResourceMonitor() {
    _currentMonitorInterval = ExecuteInterval.seconds30;
    _normalRecoveryCount = 0;
    CrontabManager.addCallback(_currentMonitorInterval, _checkResourceUsage);
  }

  /// Adapt monitor interval dynamically based on resource status
  void _adjustMonitorInterval(ResourceStatus status) {
    if (status != ResourceStatus.normal) {
      _normalRecoveryCount = 0;
      if (_currentMonitorInterval != ExecuteInterval.seconds3) {
        CrontabManager.removeCallback(
            _currentMonitorInterval, _checkResourceUsage);
        _currentMonitorInterval = ExecuteInterval.seconds3;
        CrontabManager.addCallback(
            _currentMonitorInterval, _checkResourceUsage);
        Logger.debug(
            'ResourceManager: monitor interval accelerated to 3s (status: ${status.name})');
      }
    } else {
      _normalRecoveryCount++;
      if (_normalRecoveryCount >= 2 &&
          _currentMonitorInterval != ExecuteInterval.seconds30) {
        CrontabManager.removeCallback(
            _currentMonitorInterval, _checkResourceUsage);
        _currentMonitorInterval = ExecuteInterval.seconds30;
        CrontabManager.addCallback(
            _currentMonitorInterval, _checkResourceUsage);
        Logger.debug(
            'ResourceManager: monitor interval restored to 30s after recovery');
      }
    }
  }

  // Throttle immediate checks to avoid storming the resource manager
  DateTime _lastImmediateCheckTime = DateTime.fromMillisecondsSinceEpoch(0);

  /// Trigger an immediate resource check (bypassing the timer).
  ///
  /// Useful when large operations finish and system pressure might have changed.
  Future<void> triggerImmediateCheck() async {
    final now = DateTime.now();
    final int throttleMs = _isFlushBusy ? 500 : 2000;
    if (now.difference(_lastImmediateCheckTime).inMilliseconds < throttleMs) {
      return;
    }
    _lastImmediateCheckTime = now;
    await _checkResourceUsage();
  }

  /// Check resource usage (Memory and Disk) and trigger cleanup if needed
  Future<void> _checkResourceUsage() async {
    try {
      await _updateResourceStatus(forceRefresh: true);

      // Update last measured total usage and trigger cleanup if warning or higher
      final info = await getMemoryInfo();
      if (_status != ResourceStatus.normal) {
        _triggerCacheEviction(info: info);
      }

      // Notify data store to update cached pressure status
      _dataStore?.updatePressureStatus();
    } catch (e) {
      Logger.error('Failed to check resource usage', rawError: e);
    }
  }

  /// Update internal resource status based on current metrics
  Future<void> _updateResourceStatus({bool forceRefresh = false}) async {
    final availableMemoryMB = await PlatformHandler.getAvailableSystemMemoryMB(
        forceRefresh: forceRefresh);
    final availableDiskMB = await _getAvailableDiskSpace();

    _refreshEffectivePrewarmThresholdMB(availableMemoryMB);

    final totalSysMB = _systemMemoryMB > 0 ? _systemMemoryMB : 1024;

    // Determine memory status with precalculated thresholds and hysteresis
    ResourceStatus memoryStatus = ResourceStatus.normal;
    if (availableMemoryMB < _criticalMemoryThresholdMB) {
      memoryStatus = ResourceStatus.critical;
    } else if (availableMemoryMB < _warningMemoryThresholdMB) {
      memoryStatus = ResourceStatus.warning;
    } else if (_memoryStatus != ResourceStatus.normal) {
      // Hysteresis: require margin above warning threshold before exiting warning
      if (availableMemoryMB < _warningMemoryThresholdMB + _recoveryMarginMB) {
        memoryStatus = _memoryStatus; // Stay in warning until clear recovery
      }
    }
    _memoryStatus = memoryStatus;

    // Determine disk status
    ResourceStatus diskStatus = ResourceStatus.normal;
    if (availableDiskMB < 20) {
      diskStatus = ResourceStatus.critical;
    } else if (availableDiskMB < 100) {
      diskStatus = ResourceStatus.warning;
    }

    // Combined status (take the most severe)
    final newStatus =
        ResourceStatus.values[max(memoryStatus.index, diskStatus.index)];

    if (newStatus != _status) {
      if (newStatus == ResourceStatus.critical) {
        final ResultType type = (diskStatus == ResourceStatus.critical &&
                memoryStatus == ResourceStatus.critical)
            ? ResultType.sysResourceExhausted
            : (diskStatus == ResourceStatus.critical
                ? ResultType.sysIoDiskFull
                : ResultType.sysResourceExhaustedMemory);

        Logger.critical(
            'CRITICAL RESOURCE SHORTAGE! Write operations will be blocked. Memory: $availableMemoryMB/$totalSysMB MB, Disk: $availableDiskMB MB',
            rawError: GeneralStatus(
              type: type,
              message:
                  'CRITICAL RESOURCE SHORTAGE! Write operations will be blocked. Memory: $availableMemoryMB/$totalSysMB MB, Disk: $availableDiskMB MB',
            ));
      } else if (newStatus == ResourceStatus.warning) {
        Logger.debug(
          'Low resources detected! Triggering cache eviction. Memory: $availableMemoryMB/$totalSysMB MB, Disk: $availableDiskMB MB',
        );
      } else {
        Logger.debug(
          'Resources recovered to normal levels. Memory: $availableMemoryMB/$totalSysMB MB, Disk: $availableDiskMB MB',
        );
      }
      _status = newStatus;
    }

    // Adapt monitor interval dynamically based on resource status
    _adjustMonitorInterval(_status);
  }

  /// Get current available disk space for the database path
  Future<double> _getAvailableDiskSpace() async {
    if (_dataStore == null || _dataStore!.instancePath == null) {
      return 10240.0; // 10GB safe default
    }
    try {
      final int mb =
          await PlatformHandler.getDiskFreeSpaceMB(_dataStore!.instancePath!);
      return mb.toDouble();
    } catch (e) {
      Logger.warn('Failed to get disk space', rawError: e);
      return 10240.0;
    }
  }

  /// Trigger cache cleanup
  void _triggerCacheEviction({MemoryInfo? info}) {
    if (_isCleaning) {
      return;
    }

    final now = DateTime.now();

    // Ensure interval between two cleanups to avoid frequent cleanup
    if (now.difference(_lastCacheClearTime).inSeconds <
        _currentEvictionCooldownSeconds) {
      return;
    }

    _isCleaning = true;
    _lastCacheClearTime = now;

    // Run the entire eviction process asynchronously.
    Future(() async {
      try {
        // Efficiently check total cache usage first
        final currentInfo = info ?? await getMemoryInfo();
        final totalUsage = currentInfo.totalUsageBytes;

        if (totalUsage < _getMinTotalCacheToEvict()) {
          return;
        }

        // Structured caches first. Vector ANN is last among data caches so a
        // brief LOW during a large insert can recover after table/index flush
        // without dropping search-hot leaves.
        await _evictCacheAndCheck(MemoryQuotaType.tableData);
        if (_status == ResourceStatus.normal) return;

        await _evictCacheAndCheck(MemoryQuotaType.queryResult);
        if (_status == ResourceStatus.normal) return;

        await _evictCacheAndCheck(MemoryQuotaType.indexData);
        if (_status == ResourceStatus.normal) return;

        await _evictCacheAndCheck(MemoryQuotaType.vectorIndex);
      } catch (e) {
        if (e is DbClosedException) return;
        Logger.error('An error occurred during cache eviction process',
            rawError: e);
      } finally {
        _isCleaning = false;
      }
    });
  }

  /// Evict a specific cache type and then refresh the resource status.
  Future<void> _evictCacheAndCheck(MemoryQuotaType cacheType) async {
    await _evictCacheByType(cacheType);

    // Refresh status after eviction with fresh system readings
    await _updateResourceStatus(forceRefresh: true);
  }

  /// Execute specific type cache cleanup
  Future<void> _evictCacheByType(MemoryQuotaType cacheType) async {
    final callback = _cacheEvictionCallbacks[cacheType];
    if (callback == null) return;

    try {
      // Measure cache size before eviction for relevant cache types
      int beforeSize = await _getCurrentCacheSizeByType(cacheType);

      // Guard check: skip if cache size is below minimum threshold
      final minThreshold = _getMinEvictThreshold(cacheType);
      if (beforeSize < minThreshold) {
        return;
      }

      // Execute eviction callback, which might be async
      final result = callback();
      if (result is Future) {
        await result;
      }

      // Measure cache size after eviction to verify the cleanup effect
      int afterSize = await _getCurrentCacheSizeByType(cacheType);

      // Log cleanup effect
      if (beforeSize > 0 && afterSize < beforeSize) {
        int freedBytes = beforeSize - afterSize;
        double freedMB = freedBytes / (1024 * 1024);
        Logger.debug(
            'Cache eviction for ${cacheType.name}: freed ${freedMB.toStringAsFixed(2)}MB (${((beforeSize - afterSize) * 100 / beforeSize).toStringAsFixed(1)}%)');
      }
    } catch (e) {
      if (e is DbClosedException) return;
      Logger.error('Error in cache eviction callback for ${cacheType.name}',
          rawError: e);
    }
  }

  /// Get current cache size by type using appropriate cache manager methods
  Future<int> _getCurrentCacheSizeByType(MemoryQuotaType cacheType) async {
    if (_dataStore == null) return 0;

    try {
      switch (cacheType) {
        case MemoryQuotaType.tableData:
          return _dataStore!.cacheManager.getCurrentTableDataCacheSize();
        case MemoryQuotaType.queryResult:
          return _dataStore!.cacheManager.getCurrentQueryCacheSize();
        case MemoryQuotaType.indexData:
          return await _dataStore!.indexManager
                  ?.getCurrentBtreeIndexDataCacheSize() ??
              0;
        case MemoryQuotaType.vectorIndex:
          return _dataStore!.vectorIndexManager?.getCurrentCacheSize() ?? 0;
        case MemoryQuotaType.schema:
          return _dataStore!.cacheManager.getCurrentSchemaCacheSize();
        case MemoryQuotaType.meta:
          // Meta cache = Table Data Meta + Index Meta (Data excluded)
          final tableDataMetaSize =
              _dataStore!.tableDataManager.getCurrentTableDataMetaCacheSize();
          final indexMetaSize =
              await _dataStore!.indexManager?.getCurrentIndexMetaCacheSize() ??
                  0;
          return tableDataMetaSize + indexMetaSize;
      }
    } catch (e) {
      if (e is DbClosedException || _dataStore?.isBaseInitialized != true) {
        return 0;
      }
      Logger.warn('Failed to get current cache size for ${cacheType.name}',
          rawError: e);
      return 0;
    }
  }

  /// Calculate cache sizes
  void _calculateCacheSizes() {
    // Convert MB to bytes
    int totalThresholdBytes = _memoryThresholdInMB * 1024 * 1024;

    // Allocate cache sizes based on predefined ratios
    _tableDataCacheSize = (totalThresholdBytes * _tableDataCacheRatio).toInt();
    _indexCacheSize = (totalThresholdBytes * _indexCacheRatio).toInt();
    _queryCacheSize = (totalThresholdBytes * _queryCacheRatio).toInt();
    _schemaCacheSize = (totalThresholdBytes * _schemaCacheRatio).toInt();
    _metaCacheSize = (totalThresholdBytes * _metaCacheRatio).toInt();
    _dataStore?.vectorIndexManager?.syncVectorSearchCacheBudget();
  }

  /// Register cache eviction callback
  void registerCacheEvictionCallback(
      MemoryQuotaType cacheType, Function() callback) {
    _cacheEvictionCallbacks[cacheType] = callback;
  }

  /// Unregister cache eviction callback
  void unregisterCacheEvictionCallback(MemoryQuotaType cacheType) {
    _cacheEvictionCallbacks[cacheType] = null;
  }

  /// Get table data cache size limit
  int getTableDataCacheSize() => _tableDataCacheSize;

  /// Get record cache size limit
  int getRecordCacheSize() => (_tableDataCacheSize * 0.7).toInt();

  /// Get index cache size limit
  int getIndexCacheSize() => _indexCacheSize;

  /// Get query cache size limit
  int getQueryCacheSize() => _queryCacheSize;

  /// Get schema cache size limit
  int getSchemaCacheSize() => _schemaCacheSize;

  /// Get table data and index all meta cache size limit
  int getMetaCacheSize() => _metaCacheSize;

  int? _effectivePrewarmThresholdMB;

  /// Initialize or refresh the shared effective prewarm threshold (MB).
  ///
  /// Startup cache prewarm and runtime query prewarm use the same dynamic
  /// threshold. Resource polling refreshes it from available memory later.
  Future<int> initializeEffectivePrewarmThresholdMB() async {
    final availableMemoryMB =
        await PlatformHandler.getAvailableSystemMemoryMB();
    _refreshEffectivePrewarmThresholdMB(availableMemoryMB);
    return _effectivePrewarmThresholdMB!;
  }

  /// Get the latest effective runtime prewarm threshold (MB).
  int getEffectivePrewarmThresholdMB() {
    return _effectivePrewarmThresholdMB ?? _getMinimumPrewarmThresholdMB();
  }

  void _refreshEffectivePrewarmThresholdMB(int availableMemoryMB) {
    try {
      final minimum = _getMinimumPrewarmThresholdMB();
      final memoryBased = max(
        (availableMemoryMB * 0.3).floor(),
        minimum,
      );

      final configured = _dataStore?.config.prewarmThresholdMB;
      if (configured != null && configured > 0) {
        _effectivePrewarmThresholdMB = max(1, min(configured, memoryBased));
      } else {
        _effectivePrewarmThresholdMB = memoryBased;
      }
    } catch (_) {
      _effectivePrewarmThresholdMB = _getMinimumPrewarmThresholdMB();
    }
  }

  static int _getMinimumPrewarmThresholdMB() {
    if (PlatformHandler.isWeb) return 32;
    if (PlatformHandler.isMobile) return 32;
    if (PlatformHandler.isServerEnvironment) return 256;
    return 128;
  }

  /// Get current resource status
  ResourceStatus get status => _status;

  /// Get current memory status without conflating it with disk pressure.
  ResourceStatus get memoryStatus => _memoryStatus;

  /// Whether write operations should be blocked
  bool get isWriteBlocked => _status == ResourceStatus.critical;

  /// Whether resources are low (warning or critical), triggers cache cleanup
  bool get isLowMemoryMode => _status != ResourceStatus.normal;

  /// Get last measured total cache usage in MB
  int get lastMeasuredTotalUsageMB =>
      _lastMeasuredTotalUsageBytes ~/ (1024 * 1024);

  /// Get current memory and cache usage information
  Future<MemoryInfo> getMemoryInfo() async {
    final tableDataUsage =
        await _getCurrentCacheSizeByType(MemoryQuotaType.tableData);
    final indexUsage =
        await _getCurrentCacheSizeByType(MemoryQuotaType.indexData);
    final vectorUsage =
        await _getCurrentCacheSizeByType(MemoryQuotaType.vectorIndex);
    final queryUsage =
        await _getCurrentCacheSizeByType(MemoryQuotaType.queryResult);
    final schemaUsage =
        await _getCurrentCacheSizeByType(MemoryQuotaType.schema);
    final metaUsage = await _getCurrentCacheSizeByType(MemoryQuotaType.meta);

    final totalUsage = tableDataUsage +
        indexUsage +
        vectorUsage +
        queryUsage +
        schemaUsage +
        metaUsage;

    final info = MemoryInfo(
      totalThresholdMB: _memoryThresholdInMB,
      tableDataCacheUsage: tableDataUsage,
      tableDataCacheLimit: _tableDataCacheSize,
      indexCacheUsage: indexUsage + vectorUsage,
      indexCacheLimit: _indexCacheSize,
      queryCacheUsage: queryUsage,
      queryCacheLimit: _queryCacheSize,
      schemaCacheUsage: schemaUsage,
      schemaCacheLimit: _schemaCacheSize,
      metaCacheUsage: metaUsage,
      metaCacheLimit: _metaCacheSize,
      isLowMemoryMode: _status != ResourceStatus.normal,
      totalUsageBytes: totalUsage,
    );

    // Sync last measured total usage whenever info is gathered
    _lastMeasuredTotalUsageBytes = totalUsage;

    return info;
  }

  /// Get baseline protection threshold for specific cache type
  int _getMinEvictThreshold(MemoryQuotaType type) {
    final total = _getMinTotalCacheToEvict();
    switch (type) {
      case MemoryQuotaType.tableData:
        return (total * 0.5).toInt(); // 50% of protection budget
      case MemoryQuotaType.indexData:
        return (total * 0.25).toInt(); // 25%
      case MemoryQuotaType.vectorIndex:
        return (total * 0.25).toInt(); // 25%
      case MemoryQuotaType.queryResult:
        return (total * 0.125).toInt(); // 12.5%
      case MemoryQuotaType.schema:
        return (total * 0.0625).toInt(); // 6.25%
      case MemoryQuotaType.meta:
        return (total * 0.0625).toInt(); // 6.25%
    }
  }

  /// Get global minimum total cache size to trigger any eviction based on platform
  int _getMinTotalCacheToEvict() {
    int baselineBytes;
    if (PlatformHandler.isServerEnvironment) {
      baselineBytes = 512 * 1024 * 1024; // 512MB for high-throughput servers
    } else if (PlatformHandler.isDesktop) {
      baselineBytes = 256 * 1024 * 1024; // 256MB for desktops
    } else if (PlatformHandler.isWeb) {
      baselineBytes = 64 * 1024 * 1024; // 64MB (more restricted environments)
    } else {
      baselineBytes = 128 * 1024 * 1024; // 128MB for modern mobile devices
    }

    // Baseline protection must never exceed 50% of configured total cache budget
    if (_memoryThresholdInMB > 0) {
      final maxAllowedBaseline =
          (_memoryThresholdInMB * 1024 * 1024 * 0.5).toInt();
      baselineBytes = min(baselineBytes, maxAllowedBaseline);
    }
    return max(baselineBytes, 16 * 1024 * 1024);
  }

  /// Clean up all resources
  void dispose() {
    // Deregister periodic monitor callback from CrontabManager
    CrontabManager.removeCallback(_currentMonitorInterval, _checkResourceUsage);
    _currentMonitorInterval = ExecuteInterval.seconds30;
    _normalRecoveryCount = 0;

    _cacheEvictionCallbacks.updateAll((key, value) => null);
    _dataStore = null;
    _effectivePrewarmThresholdMB = null;
    _status = ResourceStatus.normal;
    _memoryStatus = ResourceStatus.normal;
    _systemMemoryMB = 0;
    _warningMemoryThresholdMB = 256;
    _criticalMemoryThresholdMB = 32;
    _recoveryMarginMB = 64;
    _initialized = false;
    _initFuture = null;
  }
}

/// Memory quota allocation type (MemoryQuotaType), sorted by allocation priority
enum MemoryQuotaType {
  /// Table data cache (clean up first)
  tableData,

  /// Query result cache
  queryResult,

  /// Index data cache
  indexData,

  /// Vector / NGH ANN caches (after structured table+index still LOW)
  vectorIndex,

  /// Table structure cache (clean up last)
  schema,

  /// Table data and index all meta cache
  meta,
}
