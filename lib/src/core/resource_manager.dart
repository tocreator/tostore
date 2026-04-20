import 'dart:async';
import 'dart:math';

import '../handler/logger.dart';
import '../handler/platform_handler.dart';
import '../model/data_store_config.dart';
import '../model/memory_info.dart';
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

  /// Initialization flag
  bool _initialized = false;

  /// Last measured total cache usage across all types (bytes)
  int _lastMeasuredTotalUsageBytes = 0;

  /// Data store reference
  DataStoreImpl? _dataStore;

  /// Cache eviction callback function by type
  final Map<MemoryQuotaType, Function()?> _cacheEvictionCallbacks = {
    MemoryQuotaType.tableData: null,
    MemoryQuotaType.queryResult: null,
    MemoryQuotaType.indexData: null,
    MemoryQuotaType.schema: null,
    MemoryQuotaType.meta: null,
  };

  /// Flag to prevent re-entrant cache cleanup
  bool _isCleaning = false;

  /// Initialize resource manager
  Future<void> initialize(
      DataStoreConfig config, DataStoreImpl dataStore) async {
    if (_initialized) return;

    // Store data store reference for accessing cache managers
    _dataStore = dataStore;

    // Set memory threshold
    await _configureMemoryThreshold(config);

    // Calculate cache sizes
    _calculateCacheSizes();

    // Register resource monitoring task
    _registerResourceMonitor();

    _initialized = true;
  }

  /// Configure memory threshold
  Future<void> _configureMemoryThreshold(DataStoreConfig config) async {
    try {
      // Get available system memory and total memory
      int availableMemoryMB =
          await PlatformHandler.getAvailableSystemMemoryMB();
      int systemMemoryMB = await PlatformHandler.getSystemMemoryMB();

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
      Logger.error('Failed to configure memory threshold: $e',
          label: 'ResourceManager._configureMemoryThreshold');
      // Set default threshold
      _memoryThresholdInMB = _getDefaultMemoryThreshold();
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

  /// Register resource monitoring periodic task
  void _registerResourceMonitor() {
    // Use CrontabManager to register resource monitoring task
    // Default to 30 seconds to reduce overhead; during high pressure,
    // the system can trigger immediate checks reactively.
    CrontabManager.addCallback(ExecuteInterval.seconds30, _checkResourceUsage);
  }

  // Throttle immediate checks to avoid storming the resource manager
  DateTime _lastImmediateCheckTime = DateTime.fromMillisecondsSinceEpoch(0);

  /// Trigger an immediate resource check (bypassing the timer).
  ///
  /// Useful when large operations finish and system pressure might have changed.
  /// This call is throttled to at most once per 2 seconds.
  Future<void> triggerImmediateCheck() async {
    final now = DateTime.now();
    if (now.difference(_lastImmediateCheckTime).inMilliseconds < 2000) {
      return;
    }
    _lastImmediateCheckTime = now;
    await _checkResourceUsage();
  }

  /// Check resource usage (Memory and Disk) and trigger cleanup if needed
  Future<void> _checkResourceUsage() async {
    try {
      await _updateResourceStatus();

      // Update last measured total usage and trigger cleanup if warning or higher
      final info = await getMemoryInfo();
      if (_status != ResourceStatus.normal) {
        _triggerCacheEviction(info: info);
      }

      // Notify data store to update cached pressure status
      _dataStore?.updatePressureStatus();
    } catch (e) {
      Logger.error('Failed to check resource usage: $e',
          label: 'ResourceManager._checkResourceUsage');
    }
  }

  /// Update internal resource status based on current metrics
  Future<void> _updateResourceStatus() async {
    final availableMemoryMB =
        await PlatformHandler.getAvailableSystemMemoryMB();
    final systemMemoryMB = await PlatformHandler.getSystemMemoryMB();
    final availableDiskMB = await _getAvailableDiskSpace();

    // Determine memory status
    ResourceStatus memoryStatus = ResourceStatus.normal;
    if (availableMemoryMB < systemMemoryMB * 0.02 || availableMemoryMB < 32) {
      memoryStatus = ResourceStatus.critical;
    } else if (availableMemoryMB < systemMemoryMB * 0.1) {
      memoryStatus = ResourceStatus.warning;
    }

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
        Logger.error(
            'CRITICAL RESOURCE SHORTAGE! Write operations will be blocked. Memory: $availableMemoryMB/$systemMemoryMB MB, Disk: $availableDiskMB MB',
            label: 'ResourceManager._updateResourceStatus');
      } else if (newStatus == ResourceStatus.warning) {
        Logger.warn(
            'Low resources detected! Triggering cache eviction. Memory: $availableMemoryMB/$systemMemoryMB MB, Disk: $availableDiskMB MB',
            label: 'ResourceManager._updateResourceStatus');
      } else {
        Logger.info('Resources recovered to normal levels.',
            label: 'ResourceManager._updateResourceStatus');
      }
      _status = newStatus;
    }
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
      Logger.warn('Failed to get disk space: $e', label: 'ResourceManager');
      return 10240.0;
    }
  }

  /// Trigger cache cleanup
  void _triggerCacheEviction({MemoryInfo? info}) {
    if (_isCleaning) {
      return;
    }

    final now = DateTime.now();

    // Ensure at least 30 seconds interval between two cleanups to avoid frequent cleanup
    if (now.difference(_lastCacheClearTime).inSeconds < 30) {
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

        // Clean up cache in order of priority, from low priority to high priority
        await _evictCacheAndCheck(MemoryQuotaType.tableData);
        if (_status == ResourceStatus.normal) return;

        await _evictCacheAndCheck(MemoryQuotaType.queryResult);
        if (_status == ResourceStatus.normal) return;

        await _evictCacheAndCheck(MemoryQuotaType.indexData);
      } catch (e) {
        Logger.error('An error occurred during cache eviction process: $e',
            label: 'ResourceManager._triggerCacheEviction');
      } finally {
        _isCleaning = false;
      }
    });
  }

  /// Evict a specific cache type and then refresh the resource status.
  Future<void> _evictCacheAndCheck(MemoryQuotaType cacheType) async {
    await _evictCacheByType(cacheType);

    // Refresh status after eviction without re-triggering eviction process
    await _updateResourceStatus();
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
            'Cache eviction for ${cacheType.name}: freed ${freedMB.toStringAsFixed(2)}MB (${((beforeSize - afterSize) * 100 / beforeSize).toStringAsFixed(1)}%)',
            label: 'ResourceManager._evictCacheByType');
      }
    } catch (e) {
      Logger.error('Error in cache eviction callback for ${cacheType.name}: $e',
          label: 'ResourceManager._evictCacheByType');
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
                  ?.getCurrentIndexDataCacheSize() ??
              0;
        case MemoryQuotaType.schema:
          return _dataStore!.cacheManager.getCurrentSchemaCacheSize();
        case MemoryQuotaType.meta:
          // Meta cache = Table Meta + Index Meta (Data excluded)
          final tableMetaSize =
              _dataStore!.tableDataManager.getCurrentTableMetaCacheSize();
          final indexMetaSize =
              await _dataStore!.indexManager?.getCurrentIndexMetaCacheSize() ??
                  0;
          return tableMetaSize + indexMetaSize;
      }
    } catch (e) {
      Logger.error('Failed to get current cache size for ${cacheType.name}: $e',
          label: 'ResourceManager._getCurrentCacheSizeByType');
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

  /// Get memory threshold (MB)
  int getMemoryThresholdMB() => _memoryThresholdInMB;

  /// Get current resource status
  ResourceStatus get status => _status;

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
    final queryUsage =
        await _getCurrentCacheSizeByType(MemoryQuotaType.queryResult);
    final schemaUsage =
        await _getCurrentCacheSizeByType(MemoryQuotaType.schema);
    final metaUsage = await _getCurrentCacheSizeByType(MemoryQuotaType.meta);

    final totalUsage =
        tableDataUsage + indexUsage + queryUsage + schemaUsage + metaUsage;

    final info = MemoryInfo(
      totalThresholdMB: _memoryThresholdInMB,
      tableDataCacheUsage: tableDataUsage,
      tableDataCacheLimit: _tableDataCacheSize,
      indexCacheUsage: indexUsage,
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
    if (PlatformHandler.isServerEnvironment) {
      return 512 * 1024 * 1024; // 512MB for high-throughput servers
    } else if (PlatformHandler.isDesktop) {
      return 256 * 1024 * 1024; // 256MB for desktops
    } else if (PlatformHandler.isWeb) {
      return 64 * 1024 * 1024; // 64MB (more restricted environments)
    } else {
      return 128 * 1024 * 1024; // 128MB for modern mobile devices
    }
  }

  /// Clean up all resources
  void dispose() {
    // No need to explicitly cancel callbacks in CrontabManager, it will be automatically cleaned up with database closure
    _cacheEvictionCallbacks.updateAll((key, value) => null);
    _dataStore = null;
    _initialized = false;
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

  /// Table structure cache (clean up last)
  schema,

  /// Table data and index all meta cache
  meta,
}
