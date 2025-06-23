import 'dart:async';
import 'dart:math';

import '../handler/logger.dart';
import '../handler/platform_handler.dart';
import '../model/data_store_config.dart';
import 'crontab_manager.dart';

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
  static const double _indexCacheRatio = 0.30;  // Index cache 30%
  static const double _queryCacheRatio = 0.20;  // Query cache 20% 
  static const double _schemaCacheRatio = 0.05; // Schema cache 5%
  static const double _metaCacheRatio = 0.05;   // Meta cache 5%
  
  /// Size thresholds for various caches (in bytes)
  int _recordCacheSize = 0;
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
  
  /// Cache eviction callback function
  final Map<String, Function()> _cacheEvictionCallbacks = {};
  
  /// Initialize memory manager
  Future<void> initialize(DataStoreConfig config) async {
    if (_initialized) return;
    
    // Set memory threshold
    await _configureMemoryThreshold(config);
    
    // Calculate cache sizes
    _calculateCacheSizes();
    
    // Register memory monitoring task
    _registerMemoryMonitor();
    
    _initialized = true;
    
    Logger.info('MemoryManager initialized with threshold: $_memoryThresholdInMB MB', 
        label: 'MemoryManager.initialize');
  }

  /// Configure memory threshold
  Future<void> _configureMemoryThreshold(DataStoreConfig config) async {
    try {
      // Get available system memory and total memory
      int availableMemoryMB = await PlatformHandler.getAvailableSystemMemoryMB();
      int systemMemoryMB = await PlatformHandler.getSystemMemoryMB();
      
      // Get the smaller value between available memory and total memory as the base value
      int baseMemoryMB = availableMemoryMB < systemMemoryMB * 0.8 
          ? availableMemoryMB 
          : (systemMemoryMB * 0.8).toInt();
      
      if (config.memoryThresholdInMB != null && config.memoryThresholdInMB! > 0) {
        // Use user-configured memory threshold, but ensure it doesn't exceed available memory
        _memoryThresholdInMB = min(config.memoryThresholdInMB!, baseMemoryMB);
      } else {
        // Default to 75% of available memory
        _memoryThresholdInMB = (baseMemoryMB * 0.75).toInt();
      }
      
      // Ensure memory threshold is not less than minimum value
      _memoryThresholdInMB = max(_memoryThresholdInMB, _getMinimumMemoryThreshold());
      
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
      _checkMemoryUsage
    );
  }
  
  /// Check memory usage
  Future<void> _checkMemoryUsage() async {
    try {
      final availableMemoryMB = await PlatformHandler.getAvailableSystemMemoryMB();
      final systemMemoryMB = await PlatformHandler.getSystemMemoryMB();
      
      // When available memory is less than 10% of system memory, trigger cache cleanup
      if (availableMemoryMB < systemMemoryMB * 0.1) {
        if (!_isLowMemoryMode) {
          Logger.warn('Low memory detected! Available: $availableMemoryMB MB, System: $systemMemoryMB MB',
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
  
  /// Trigger cache cleanup
  void _triggerCacheEviction() {
    final now = DateTime.now();
    
    // Ensure at least 30 seconds interval between two cleanups to avoid frequent cleanup
    if (now.difference(_lastCacheClearTime).inSeconds < 30) {
      return;
    }
    
    _lastCacheClearTime = now;
    
    // Call all registered cache eviction callbacks
    _cacheEvictionCallbacks.forEach((name, callback) {
      try {
        callback();
      } catch (e) {
        Logger.error('Error in cache eviction callback $name: $e',
            label: 'MemoryManager._triggerCacheEviction');
      }
    });
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
    _metaCacheSize = (totalThresholdBytes * _metaCacheRatio).toInt();
  }
  
  /// Register cache eviction callback
  void registerCacheEvictionCallback(String name, Function() callback) {
    _cacheEvictionCallbacks[name] = callback;
  }
  
  /// Unregister cache eviction callback
  void unregisterCacheEvictionCallback(String name) {
    _cacheEvictionCallbacks.remove(name);
  }
  
  /// Get record cache size limit
  int getRecordCacheSize() => _recordCacheSize;
  
  /// Get index cache size limit
  int getIndexCacheSize() => _indexCacheSize;
  
  /// Get query cache size limit
  int getQueryCacheSize() => _queryCacheSize;
  
  /// Get schema cache size limit
  int getSchemaCacheSize() => _schemaCacheSize;
  
  /// Get meta cache size limit
  int getMetaCacheSize() => _metaCacheSize;
  
  /// Get memory threshold (MB)
  int getMemoryThresholdMB() => _memoryThresholdInMB;
  
  /// Get current low memory mode status
  bool isLowMemoryMode() => _isLowMemoryMode;
  
  /// Clean up all resources
  void dispose() {
    // No need to explicitly cancel callbacks in CrontabManager, it will be automatically cleaned up with database closure
    _cacheEvictionCallbacks.clear();
    _initialized = false;
  }
} 