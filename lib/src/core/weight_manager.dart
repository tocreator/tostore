import 'dart:async';
import 'dart:convert';
import '../handler/logger.dart';
import '../model/system_table.dart';
import 'data_store_impl.dart';
import 'crontab_manager.dart';
import 'yield_controller.dart';
import 'path_manager.dart';

/// Weight type enum
enum WeightType {
  /// Table record weight
  tableRecord,

  /// Index data weight
  indexData,
}

/// Weight data model
class WeightData {
  /// Weight value (0-100)
  final int weight;

  /// Access count
  final int accessCount;

  /// Last update time
  final int lastUpdateTime;

  /// Whether to never decay
  final bool neverDecay;

  /// Custom weight (if set, use this value instead of calculated value)
  final int? customWeight;

  WeightData({
    this.weight = 0,
    this.accessCount = 0,
    required this.lastUpdateTime,
    this.neverDecay = false,
    this.customWeight,
  });

  Map<String, dynamic> toJson() => {
        'weight': weight,
        'accessCount': accessCount,
        'lastUpdateTime': lastUpdateTime,
        'neverDecay': neverDecay,
        'customWeight': customWeight,
      };

  factory WeightData.fromJson(Map<String, dynamic> json) => WeightData(
        weight: json['weight'] as int? ?? 0,
        accessCount: json['accessCount'] as int? ?? 0,
        lastUpdateTime: json['lastUpdateTime'] as int? ?? 0,
        neverDecay: json['neverDecay'] as bool? ?? false,
        customWeight: json['customWeight'] as int?,
      );

  WeightData copyWith({
    int? weight,
    int? accessCount,
    int? lastUpdateTime,
    bool? neverDecay,
    int? customWeight,
  }) =>
      WeightData(
        weight: weight ?? this.weight,
        accessCount: accessCount ?? this.accessCount,
        lastUpdateTime: lastUpdateTime ?? this.lastUpdateTime,
        neverDecay: neverDecay ?? this.neverDecay,
        customWeight: customWeight ?? this.customWeight,
      );
}

/// Weight manager
/// Responsible for managing the weights of table records and index data, supporting weight decay, query, etc.
class WeightManager {
  final DataStoreImpl _dataStore;
  final PathManager _pathManager;

  /// Weight data cache
  /// Structure: WeightType -> identifier -> WeightData
  final Map<WeightType, Map<String, WeightData>> _weightCache = {
    WeightType.tableRecord: {},
    WeightType.indexData: {},
  };

  /// High weight cache (default 70% or higher)
  ///
  /// Structure: `WeightType -> Set<identifier>`
  final Map<WeightType, Set<String>> _highWeightCache = {
    WeightType.tableRecord: {},
    WeightType.indexData: {},
  };

  /// File load lock, avoid high concurrency duplicate read
  final Map<String, Completer<void>> _loadingLocks = {};

  /// Whether initialized
  bool _initialized = false;

  /// Last decay time
  int _lastDecayTime = 0;

  /// Whether weight data has changed since last save
  bool _dirty = false;

  /// Lock for saving weights to file
  Future<void>? _saveLock;

  WeightManager(this._dataStore) : _pathManager = _dataStore.pathManager {
    // Register 24-hour decay callback
    CrontabManager.addCallback(ExecuteInterval.hour24, _performDecay);
    // Register 10-second periodic save
    CrontabManager.addCallback(ExecuteInterval.seconds10, _periodicSave);
  }

  /// Dispose weight manager and deregister crontab callbacks
  void dispose() {
    CrontabManager.removeCallback(ExecuteInterval.hour24, _performDecay);
    CrontabManager.removeCallback(ExecuteInterval.seconds10, _periodicSave);
  }

  /// Get weight file path
  String _getWeightFilePath({String? spaceName}) {
    return _pathManager.getWeightFilePath(spaceName: spaceName);
  }

  /// Initialize weight manager
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      await _loadWeights();
      _initialized = true;
    } catch (e, stack) {
      Logger.error(
        'Failed to initialize WeightManager: $e\n$stack',
        label: 'WeightManager',
      );
      rethrow;
    }
  }

  /// Load weight data (lazy loading, with concurrency control)
  Future<void> _loadWeights({String? spaceName}) async {
    final filePath = _getWeightFilePath(spaceName: spaceName);
    final lockKey = filePath;

    // Check if loading is in progress
    if (_loadingLocks.containsKey(lockKey)) {
      // Wait for other threads to load complete
      await _loadingLocks[lockKey]!.future;
      return;
    }

    // Create load lock
    final completer = Completer<void>();
    _loadingLocks[lockKey] = completer;

    try {
      // Check if file exists
      if (!await _dataStore.storage.existsFile(filePath)) {
        // File does not exist, initialize weight data
        await _initializeWeights(spaceName: spaceName);
        completer.complete();
        return;
      }

      // Read file
      final content = await _dataStore.storage.readAsString(filePath);
      if (content == null || content.isEmpty) {
        await _initializeWeights(spaceName: spaceName);
        completer.complete();
        return;
      }

      // Parse JSON
      final json = jsonDecode(content) as Map<String, dynamic>;

      // Load table record weights
      if (json['tableRecord'] is Map) {
        final tableRecordWeights = json['tableRecord'] as Map<String, dynamic>;
        for (final entry in tableRecordWeights.entries) {
          _weightCache[WeightType.tableRecord]![entry.key] =
              WeightData.fromJson(entry.value as Map<String, dynamic>);
        }
      }

      // Load index data weights
      if (json['indexData'] is Map) {
        final indexDataWeights = json['indexData'] as Map<String, dynamic>;
        for (final entry in indexDataWeights.entries) {
          _weightCache[WeightType.indexData]![entry.key] =
              WeightData.fromJson(entry.value as Map<String, dynamic>);
        }
      }

      // Load last decay time
      _lastDecayTime = json['lastDecayTime'] as int? ?? 0;

      // Rebuild high weight cache
      _rebuildHighWeightCache();

      completer.complete();
    } catch (e, stack) {
      completer.completeError(e);
      Logger.error(
        'Failed to load weights from file: $filePath, error: $e\n$stack',
        label: 'WeightManager',
      );
      // If loading fails, initialize weight data
      await _initializeWeights(spaceName: spaceName);
    } finally {
      _loadingLocks.remove(lockKey);
    }
  }

  /// Initialize weight data
  Future<void> _initializeWeights({String? spaceName}) async {
    try {
      final yieldController = YieldController(
          'WeightManager._initializeWeights',
          checkInterval: 100);

      // Get all tables
      final allTables = await _dataStore.getTableNames();
      final systemTables = <String>{};

      for (final tableName in allTables) {
        await yieldController.maybeYield();

        // Check if it is a system table
        final isSystemTable = SystemTable.isSystemTable(tableName);
        if (isSystemTable) {
          systemTables.add(tableName);
        }

        // Check if the table exists in the current space
        final existsInSpace =
            await _dataStore.tableExistsInCurrentSpace(tableName);
        if (!existsInSpace) continue;

        // Get table schema
        final schema =
            await _dataStore.schemaManager?.getTableSchema(tableName);
        if (schema == null) continue;

        // Initialize table record weights
        final tableKey = _getTableRecordKey(tableName);
        if (!_weightCache[WeightType.tableRecord]!.containsKey(tableKey)) {
          int initialWeight = 0;
          if (isSystemTable) {
            initialWeight = 10; // System table initial weight 10
          }
          if (schema.isGlobal) {
            initialWeight += 10; // Global table extra 10
          }

          _weightCache[WeightType.tableRecord]![tableKey] = WeightData(
            weight: initialWeight,
            accessCount: 0,
            lastUpdateTime: DateTime.now().millisecondsSinceEpoch,
          );
        }

        // Initialize index weights
        final indexes = schema.getAllIndexes();
        for (final index in indexes) {
          await yieldController.maybeYield();
          final indexKey = _getIndexDataKey(tableName, index.actualIndexName);
          if (!_weightCache[WeightType.indexData]!.containsKey(indexKey)) {
            int initialWeight = 0;
            if (isSystemTable) {
              initialWeight = 10; // System table index initial weight 10
            }
            if (schema.isGlobal) {
              initialWeight += 10; // Global table index extra 10
            }

            _weightCache[WeightType.indexData]![indexKey] = WeightData(
              weight: initialWeight,
              accessCount: 0,
              lastUpdateTime: DateTime.now().millisecondsSinceEpoch,
            );
          }
        }
      }

      // Save weight data
      await _saveWeights(spaceName: spaceName);
      _rebuildHighWeightCache();
    } catch (e, stack) {
      Logger.error(
        'Failed to initialize weights: $e\n$stack',
        label: 'WeightManager',
      );
      rethrow;
    }
  }

  /// Handle data mutation
  void _onMutation() {
    _dirty = true;
    CrontabManager.notifyActivity();
  }

  /// Periodic save callback for CrontabManager
  void _periodicSave() {
    if (_dirty) {
      saveWeights(force: false);
    }
  }

  /// Save weight data to file (with lock)
  Future<void> saveWeights({String? spaceName, bool force = false}) async {
    if (!force && !_dirty) return;

    // Wait for previous lock if any
    if (_saveLock != null) {
      await _saveLock;
    }

    final completer = Completer<void>();
    _saveLock = completer.future;

    try {
      _dirty = false;

      final filePath = _getWeightFilePath(spaceName: spaceName);
      final json = {
        'tableRecord': {
          for (final entry in _weightCache[WeightType.tableRecord]!.entries)
            entry.key: entry.value.toJson(),
        },
        'indexData': {
          for (final entry in _weightCache[WeightType.indexData]!.entries)
            entry.key: entry.value.toJson(),
        },
        'lastDecayTime': _lastDecayTime,
      };

      await _dataStore.storage.writeAsString(
        filePath,
        jsonEncode(json),
        flush: true,
      );
    } catch (e, stack) {
      Logger.error(
        'Failed to save weights to file: $e\n$stack',
        label: 'WeightManager',
      );
      // Do not throw exception, avoid affecting main process
    } finally {
      completer.complete();
      if (identical(_saveLock, completer.future)) {
        _saveLock = null;
      }
    }
  }

  /// Alias for backward compatibility if any, but better use saveWeights
  Future<void> _saveWeights({String? spaceName}) =>
      saveWeights(spaceName: spaceName, force: true);

  /// Clear memory cache only (standardized for CacheManager)
  void clearMemory() {
    _weightCache[WeightType.tableRecord]!.clear();
    _weightCache[WeightType.indexData]!.clear();
    _highWeightCache[WeightType.tableRecord]!.clear();
    _highWeightCache[WeightType.indexData]!.clear();
    _dirty = false;
  }

  /// Increment access count
  Future<void> incrementAccess(
    WeightType type,
    String identifier, {
    String? spaceName,
  }) async {
    // High-concurrency optimization: check initialized status synchronously first
    if (_initialized) {
      final cache = _weightCache[type]!;
      // If weights for this type are already loaded (common case), handle synchronously
      if (cache.isNotEmpty || type == WeightType.tableRecord) {
        _syncIncrementAccess(type, identifier, spaceName: spaceName);
        return;
      }
    }

    // Fallback to async loading if not fully initialized or cache is empty
    await _ensureWeightsLoaded(spaceName: spaceName);
    _syncIncrementAccess(type, identifier, spaceName: spaceName);
  }

  /// Internal synchronous increment (assumes weights are loaded)
  void _syncIncrementAccess(WeightType type, String identifier,
      {String? spaceName}) {
    final cache = _weightCache[type]!;
    final now = DateTime.now().millisecondsSinceEpoch;

    if (cache.containsKey(identifier)) {
      // Update existing weight data
      final existing = cache[identifier]!;
      cache[identifier] = existing.copyWith(
        accessCount: existing.accessCount + 1,
        lastUpdateTime: now,
      );
    } else {
      // Create new weight data
      cache[identifier] = WeightData(
        weight: 0,
        accessCount: 1,
        lastUpdateTime: now,
        neverDecay: false,
      );
    }

    // Mark as dirty and notify activity
    _onMutation();
  }

  /// Get weight value
  Future<int> getWeight(
    WeightType type,
    String identifier, {
    String? spaceName,
  }) async {
    await _ensureWeightsLoaded(spaceName: spaceName);
    final data = _weightCache[type]![identifier];
    if (data == null) return 0;
    return data.customWeight ?? data.weight;
  }

  /// Get access count
  Future<int> getAccessCount(
    WeightType type,
    String identifier, {
    String? spaceName,
  }) async {
    await _ensureWeightsLoaded(spaceName: spaceName);
    final data = _weightCache[type]![identifier];
    if (data == null) return 0;
    return data.accessCount;
  }

  /// Set custom weight
  Future<void> setCustomWeight(
    WeightType type,
    String identifier,
    int? weight, {
    bool neverDecay = false,
    String? spaceName,
  }) async {
    await _ensureWeightsLoaded(spaceName: spaceName);

    final cache = _weightCache[type]!;
    final now = DateTime.now().millisecondsSinceEpoch;

    if (cache.containsKey(identifier)) {
      final existing = cache[identifier]!;
      cache[identifier] = existing.copyWith(
        customWeight: weight,
        neverDecay: neverDecay,
        lastUpdateTime: now,
      );
    } else {
      cache[identifier] = WeightData(
        weight: weight ?? 0,
        accessCount: 0,
        lastUpdateTime: now,
        neverDecay: neverDecay,
        customWeight: weight,
      );
    }

    // Update high weight cache
    _updateHighWeightCache(type, identifier);

    // Mark as dirty and notify activity
    _onMutation();
  }

  /// Check if it is high weight
  Future<bool> isHighWeight(
    WeightType type,
    String identifier, {
    double threshold = 0.7,
    String? spaceName,
  }) async {
    await _ensureWeightsLoaded(spaceName: spaceName);

    // Use cache for quick query
    if (threshold == 0.7) {
      // Default threshold, use cache
      return _highWeightCache[type]!.contains(identifier);
    }

    // Custom threshold, need to calculate
    final weight = await getWeight(type, identifier, spaceName: spaceName);
    final maxWeight = 100;
    return weight >= (maxWeight * threshold).round();
  }

  /// Get table record identifier
  String _getTableRecordKey(String tableName) => tableName;

  /// Get index data identifier
  String _getIndexDataKey(String tableName, String indexName) =>
      '$tableName:$indexName';

  /// Ensure weights are loaded
  Future<void> _ensureWeightsLoaded({String? spaceName}) async {
    if (!_initialized) {
      await initialize();
    }
    // If cache is empty, try to load
    if (_weightCache[WeightType.tableRecord]!.isEmpty &&
        _weightCache[WeightType.indexData]!.isEmpty) {
      await _loadWeights(spaceName: spaceName);
    }
  }

  /// Rebuild high weight cache
  void _rebuildHighWeightCache() {
    _highWeightCache[WeightType.tableRecord]!.clear();
    _highWeightCache[WeightType.indexData]!.clear();

    for (final type in WeightType.values) {
      final cache = _weightCache[type]!;
      for (final entry in cache.entries) {
        _updateHighWeightCache(type, entry.key);
      }
    }
  }

  /// Update high weight cache
  void _updateHighWeightCache(WeightType type, String identifier) {
    final data = _weightCache[type]![identifier];
    if (data == null) {
      _highWeightCache[type]!.remove(identifier);
      return;
    }

    final weight = data.customWeight ?? data.weight;
    final threshold = (100 * 0.7).round(); // 70%
    if (weight >= threshold) {
      _highWeightCache[type]!.add(identifier);
    } else {
      _highWeightCache[type]!.remove(identifier);
    }
  }

  /// Perform weight decay
  Future<void> _performDecay() async {
    try {
      final yieldController =
          YieldController('WeightManager._performDecay', checkInterval: 50);

      final now = DateTime.now().millisecondsSinceEpoch;

      // Process each type separately
      for (final type in WeightType.values) {
        await yieldController.maybeYield();

        final cache = _weightCache[type]!;
        if (cache.isEmpty) continue;

        // Collect weight data that needs to be decayed (excluding never decaying)
        final candidates = <String, WeightData>{};
        for (final entry in cache.entries) {
          if (!entry.value.neverDecay && entry.value.accessCount > 0) {
            candidates[entry.key] = entry.value;
          }
        }

        if (candidates.isEmpty) continue;

        // Sort by access count
        final sorted = candidates.entries.toList()
          ..sort((a, b) => b.value.accessCount.compareTo(a.value.accessCount));

        // Calculate 50% boundary
        final totalCount = sorted.length;
        final top50Count = (totalCount * 0.5).ceil();
        final top50 = sorted.take(top50Count).toList();
        final bottom50 = sorted.skip(top50Count).toList();

        // Process前50%
        if (top50.isNotEmpty) {
          final maxAccessCount = top50.first.value.accessCount;
          if (maxAccessCount > 0) {
            for (final entry in top50) {
              await yieldController.maybeYield();

              final data = entry.value;
              // Calculate score (0-100)
              final score = (data.accessCount * 100 / maxAccessCount).round();
              // Increase weight (10% of old weight cumulative value)
              final weightIncrease = (data.weight * 0.1).round();
              final newWeight =
                  (data.weight + weightIncrease + score).clamp(0, 100);

              cache[entry.key] = data.copyWith(
                weight: newWeight,
                accessCount: 0, // Reset access count
                lastUpdateTime: now,
              );

              _updateHighWeightCache(type, entry.key);
            }
          }
        }

        // Process last 50% (deduction)
        if (bottom50.isNotEmpty) {
          final maxAccessCount = top50.isNotEmpty
              ? top50.first.value.accessCount
              : bottom50.first.value.accessCount;
          if (maxAccessCount > 0) {
            for (final entry in bottom50) {
              await yieldController.maybeYield();

              final data = entry.value;
              // Calculate score (relative to highest access count)
              final score = (data.accessCount * 100 / maxAccessCount).round();
              // Decrease weight (10% of old weight cumulative value)
              final weightDecrease = (data.weight * 0.1).round();
              final newWeight =
                  (data.weight - weightDecrease - score).clamp(0, 100);

              cache[entry.key] = data.copyWith(
                weight: newWeight,
                accessCount: 0, // Reset access count
                lastUpdateTime: now,
              );

              _updateHighWeightCache(type, entry.key);
            }
          }
        }
      }

      // Update last decay time
      _lastDecayTime = now;

      // Mark as dirty and notify activity
      _onMutation();
    } catch (e, stack) {
      Logger.error(
        'Failed to perform weight decay: $e\n$stack',
        label: 'WeightManager',
      );
    }
  }

  /// Get sorted identifier list by weight
  Future<List<String>> getSortedIdentifiers(
    WeightType type, {
    bool descending = true,
    String? spaceName,
  }) async {
    await _ensureWeightsLoaded(spaceName: spaceName);

    final cache = _weightCache[type]!;
    final entries = cache.entries.toList();

    entries.sort((a, b) {
      final weightA = a.value.customWeight ?? a.value.weight;
      final weightB = b.value.customWeight ?? b.value.weight;
      return descending
          ? weightB.compareTo(weightA)
          : weightA.compareTo(weightB);
    });

    return entries.map((e) => e.key).toList();
  }

  /// Clear weight data (for testing or reset)
  Future<void> clear({String? spaceName}) async {
    clearMemory();
    _dirty = false;
    _lastDecayTime = 0;

    final filePath = _getWeightFilePath(spaceName: spaceName);
    if (await _dataStore.storage.existsFile(filePath)) {
      await _dataStore.storage.deleteFile(filePath);
    }
  }
}
