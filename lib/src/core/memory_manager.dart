import 'dart:async';
import 'dart:math';

import '../handler/logger.dart';
import '../handler/platform_handler.dart';
import '../model/data_store_config.dart';
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
  static const double _recordCacheRatio = 0.40; // Record cache 40%
  static const double _indexCacheRatio = 0.30; // Index cache 30%
  static const double _queryCacheRatio = 0.15; // Query cache 15%
  static const double _schemaCacheRatio = 0.05; // Schema cache 5%
  static const double _tableMetaCacheRatio = 0.05; // Table meta cache 5%
  static const double _indexMetaCacheRatio = 0.05; // Index meta cache 5%

  /// Size thresholds for various caches (in bytes)
  int _recordCacheSize = 0;
  int _indexCacheSize = 0;
  int _queryCacheSize = 0;
  int _schemaCacheSize = 0;
  int _tableMetaCacheSize = 0;
  int _indexMetaCacheSize = 0;

  /// Last cache clear time
  DateTime _lastCacheClearTime = DateTime.now();

  /// Low memory mode flag
  bool _isLowMemoryMode = false;

  /// Initialization flag
  bool _initialized = false;

  /// Data store reference
  DataStoreImpl? _dataStore;

  /// Cache eviction callback function by type
  final Map<CacheType, Function()?> _cacheEvictionCallbacks = {
    CacheType.record: null,
    CacheType.query: null,
    CacheType.indexData: null,
    CacheType.schema: null,
    CacheType.tableMeta: null,
    CacheType.indexMeta: null,
  };

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

    Logger.info(
        'MemoryManager initialized with threshold: $_memoryThresholdInMB MB',
        label: 'MemoryManager.initialize');
  }

  /// Configure memory threshold
  Future<void> _configureMemoryThreshold(DataStoreConfig config) async {
    try {
      // Get available system memory and total memory
      int availableMemoryMB =
          await PlatformHandler.getAvailableSystemMemoryMB();
      int systemMemoryMB = await PlatformHandler.getSystemMemoryMB();

      // Get the smaller value between available memory and total memory as the base value
      int baseMemoryMB = availableMemoryMB < systemMemoryMB * 0.8
          ? availableMemoryMB
          : (systemMemoryMB * 0.8).toInt();

      if (config.memoryThresholdInMB != null &&
          config.memoryThresholdInMB! > 0) {
        // Use user-configured memory threshold, but ensure it doesn't exceed available memory
        _memoryThresholdInMB = min(config.memoryThresholdInMB!, baseMemoryMB);
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
    final now = DateTime.now();

    // Ensure at least 30 seconds interval between two cleanups to avoid frequent cleanup
    if (now.difference(_lastCacheClearTime).inSeconds < 30) {
      return;
    }

    _lastCacheClearTime = now;

    // Clean up cache in order of priority, from low priority to high priority
    _evictCacheByType(CacheType.record);
    _checkCacheEvictionResult();
    if (!_isLowMemoryMode) return;

    _evictCacheByType(CacheType.query);
    _checkCacheEvictionResult();
    if (!_isLowMemoryMode) return;

    _evictCacheByType(CacheType.indexData);
    _checkCacheEvictionResult();
    if (!_isLowMemoryMode) return;

    _evictCacheByType(CacheType.indexMeta);
    _checkCacheEvictionResult();

    // If memory is still insufficient, clean up important metadata caches
    _evictCacheByType(CacheType.schema);
    _checkCacheEvictionResult();
    if (!_isLowMemoryMode) return;

    _evictCacheByType(CacheType.tableMeta);
    _checkCacheEvictionResult();
    if (!_isLowMemoryMode) return;
  }

  /// Check cache eviction result after each cache type cleanup
  void _checkCacheEvictionResult() {
    // Schedule immediate memory check to determine if we can exit low memory mode
    _checkMemoryUsageImmediate().then((isMemorySufficient) {
      if (isMemorySufficient) {
        _isLowMemoryMode = false;
      }
    });
  }

  /// Execute specific type cache cleanup
  void _evictCacheByType(CacheType cacheType) {
    final callback = _cacheEvictionCallbacks[cacheType];
    if (callback == null) return;

    try {
      // Measure cache size before eviction for relevant cache types
      int beforeSize = _getCurrentCacheSizeByType(cacheType);

      // Execute eviction callback
      callback();

      // Measure cache size after eviction to verify the cleanup effect
      int afterSize = _getCurrentCacheSizeByType(cacheType);

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
  int _getCurrentCacheSizeByType(CacheType cacheType) {
    if (_dataStore == null) return 0;

    try {
      switch (cacheType) {
        case CacheType.record:
          return _dataStore!.dataCacheManager.getCurrentRecordCacheSize();
        case CacheType.query:
          return _dataStore!.dataCacheManager.getCurrentQueryCacheSize();
        case CacheType.indexData:
          return _dataStore!.indexManager?.getCurrentIndexCacheSize() ?? 0;
        case CacheType.schema:
          return _dataStore!.dataCacheManager.getCurrentSchemaCacheSize();
        case CacheType.tableMeta:
          return _dataStore!.tableDataManager.getCurrentTableMetaCacheSize();
        case CacheType.indexMeta:
          return _dataStore!.indexManager?.getCurrentIndexMetaCacheSize() ?? 0;
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
    _recordCacheSize = (totalThresholdBytes * _recordCacheRatio).toInt();
    _indexCacheSize = (totalThresholdBytes * _indexCacheRatio).toInt();
    _queryCacheSize = (totalThresholdBytes * _queryCacheRatio).toInt();
    _schemaCacheSize = (totalThresholdBytes * _schemaCacheRatio).toInt();
    _tableMetaCacheSize = (totalThresholdBytes * _tableMetaCacheRatio).toInt();
    _indexMetaCacheSize = (totalThresholdBytes * _indexMetaCacheRatio).toInt();
  }

  /// Register cache eviction callback
  void registerCacheEvictionCallback(CacheType cacheType, Function() callback) {
    _cacheEvictionCallbacks[cacheType] = callback;
  }

  /// Unregister cache eviction callback
  void unregisterCacheEvictionCallback(CacheType cacheType) {
    _cacheEvictionCallbacks[cacheType] = null;
  }

  /// Get record cache size limit
  int getRecordCacheSize() => _recordCacheSize;

  /// Get index cache size limit
  int getIndexCacheSize() => _indexCacheSize;

  /// Get query cache size limit
  int getQueryCacheSize() => _queryCacheSize;

  /// Get schema cache size limit
  int getSchemaCacheSize() => _schemaCacheSize;

  /// Get table metadata cache size limit
  int getTableMetaCacheSize() => _tableMetaCacheSize;

  /// Get index metadata cache size limit
  int getIndexMetaCacheSize() => _indexMetaCacheSize;

  /// Get memory threshold (MB)
  int getMemoryThresholdMB() => _memoryThresholdInMB;

  /// Get current low memory mode status
  bool isLowMemoryMode() => _isLowMemoryMode;

  /// Clean up all resources
  void dispose() {
    // No need to explicitly cancel callbacks in CrontabManager, it will be automatically cleaned up with database closure
    _cacheEvictionCallbacks.updateAll((key, value) => null);
    _dataStore = null;
    _initialized = false;
  }
}

/// Cache type enumeration, sorted by importance
enum CacheType {
  /// Record cache (clean up first)
  record,

  /// Query result cache
  query,

  /// Index cache
  indexData,

  /// Table structure cache (clean up last)
  schema,

  /// Table metadata cache
  tableMeta,

  /// Index metadata cache
  indexMeta,
}
