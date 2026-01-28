import 'dart:async';
import 'dart:math';

import '../handler/logger.dart';
import '../handler/platform_handler.dart';

import '../model/data_store_config.dart';
import '../model/memory_info.dart';
import 'crontab_manager.dart';
import 'data_store_impl.dart';

/// Memory manager responsible for dynamically allocating and monitoring cache usage based on available system memory
class MemoryManager {
  /// Singleton implementation
  static final MemoryManager _instance = MemoryManager._internal();
  factory MemoryManager() => _instance;
  MemoryManager._internal();

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

  /// Low memory mode flag
  bool _isLowMemoryMode = false;

  /// Initialization flag
  bool _initialized = false;

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

  /// Initialize memory manager
  Future<void> initialize(
      DataStoreConfig config, DataStoreImpl dataStore) async {
    if (_initialized) return;

    // Store data store reference for accessing cache managers
    _dataStore = dataStore;

    // Set memory threshold
    await _configureMemoryThreshold(config);

    // Calculate cache sizes
    _calculateCacheSizes();

    // Register memory monitoring task
    _registerMemoryMonitor();

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
          label: 'MemoryManager._configureMemoryThreshold');
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

  /// Register memory monitoring periodic task
  void _registerMemoryMonitor() {
    // Use CrontabManager to register memory monitoring task
    CrontabManager.addCallback(
        ExecuteInterval.seconds10, // 10 seconds interval
        _checkMemoryUsage);
  }

  /// Check memory usage
  Future<void> _checkMemoryUsage() async {
    try {
      final availableMemoryMB =
          await PlatformHandler.getAvailableSystemMemoryMB();
      final systemMemoryMB = await PlatformHandler.getSystemMemoryMB();

      // When available memory is less than 10% of system memory, trigger cache cleanup
      if (availableMemoryMB < systemMemoryMB * 0.1) {
        if (!_isLowMemoryMode) {
          Logger.warn(
              'Low memory detected! Available: $availableMemoryMB MB, System: $systemMemoryMB MB',
              label: 'MemoryManager._checkMemoryUsage');
          _isLowMemoryMode = true;
        }
        _triggerCacheEviction();
      } else if (_isLowMemoryMode && availableMemoryMB > systemMemoryMB * 0.2) {
        // When available memory is greater than 20% of system memory, exit low memory mode;
        _isLowMemoryMode = false;
      }
    } catch (e) {
      Logger.error('Failed to check memory usage: $e',
          label: 'MemoryManager._checkMemoryUsage');
    }
  }

  /// Check memory usage immediately (without cache delay)
  Future<bool> _checkMemoryUsageImmediate() async {
    try {
      // Force refresh to bypass platform caching
      final availableMemoryMB =
          await PlatformHandler.getAvailableSystemMemoryMB(forceRefresh: true);
      final systemMemoryMB = await PlatformHandler.getSystemMemoryMB();

      // Update low memory mode status
      if (availableMemoryMB < systemMemoryMB * 0.1) {
        _isLowMemoryMode = true;
        return false; // Memory still insufficient
      } else if (availableMemoryMB > systemMemoryMB * 0.2) {
        // Available memory is now sufficient, exit low memory mode
        _isLowMemoryMode = false;
        return true; // Memory is now sufficient
      }

      // If memory is in between thresholds, keep current mode
      return !_isLowMemoryMode;
    } catch (e) {
      Logger.error('Failed to check immediate memory usage: $e',
          label: 'MemoryManager._checkMemoryUsageImmediate');
      return false; // Default to assume memory is still insufficient
    }
  }

  /// Trigger cache cleanup
  void _triggerCacheEviction() {
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
        // Clean up cache in order of priority, from low priority to high priority
        await _evictCacheAndCheck(MemoryQuotaType.tableData);
        if (!_isLowMemoryMode) return;

        await _evictCacheAndCheck(MemoryQuotaType.queryResult);
        if (!_isLowMemoryMode) return;

        await _evictCacheAndCheck(MemoryQuotaType.indexData);
      } catch (e) {
        Logger.error('An error occurred during cache eviction process: $e',
            label: 'MemoryManager._triggerCacheEviction');
      } finally {
        _isCleaning = false;
      }
    });
  }

  /// Evict a specific cache type and then check the memory status.
  Future<void> _evictCacheAndCheck(MemoryQuotaType cacheType) async {
    await _evictCacheByType(cacheType);
    final isMemorySufficient = await _checkMemoryUsageImmediate();
    if (isMemorySufficient) {
      _isLowMemoryMode = false;
    }
  }

  /// Execute specific type cache cleanup
  Future<void> _evictCacheByType(MemoryQuotaType cacheType) async {
    final callback = _cacheEvictionCallbacks[cacheType];
    if (callback == null) return;

    try {
      // Measure cache size before eviction for relevant cache types
      int beforeSize = await _getCurrentCacheSizeByType(cacheType);

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
            label: 'MemoryManager._evictCacheByType');
      }
    } catch (e) {
      Logger.error('Error in cache eviction callback for ${cacheType.name}: $e',
          label: 'MemoryManager._evictCacheByType');
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
          label: 'MemoryManager._getCurrentCacheSizeByType');
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

  /// Get current low memory mode status
  bool get isLowMemoryMode => _isLowMemoryMode;

  /// Get current memory and cache usage information
  Future<MemoryInfo> getMemoryInfo() async {
    return MemoryInfo(
      totalThresholdMB: _memoryThresholdInMB,
      tableDataCacheUsage:
          await _getCurrentCacheSizeByType(MemoryQuotaType.tableData),
      tableDataCacheLimit: _tableDataCacheSize,
      indexCacheUsage:
          await _getCurrentCacheSizeByType(MemoryQuotaType.indexData),
      indexCacheLimit: _indexCacheSize,
      queryCacheUsage:
          await _getCurrentCacheSizeByType(MemoryQuotaType.queryResult),
      queryCacheLimit: _queryCacheSize,
      schemaCacheUsage:
          await _getCurrentCacheSizeByType(MemoryQuotaType.schema),
      schemaCacheLimit: _schemaCacheSize,
      metaCacheUsage: await _getCurrentCacheSizeByType(MemoryQuotaType.meta),
      metaCacheLimit: _metaCacheSize,
      isLowMemoryMode: _isLowMemoryMode,
    );
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
