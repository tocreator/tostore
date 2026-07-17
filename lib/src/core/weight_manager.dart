import 'dart:async';
import 'dart:convert';
import '../handler/logger.dart';
import '../model/system_table.dart';
import '../model/table_context.dart';
import 'data_store_impl.dart';
import 'crontab_manager.dart';
import 'yield_controller.dart';
import 'path_manager.dart';
import '../model/table_identity.dart';

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

  /// Table record weights keyed by stable [TableUid].
  final Map<TableUid, WeightData> _tableRecordWeights = {};

  /// Index data weights keyed by [indexDataIdentifier] (`tableUid:indexUid`).
  final Map<String, WeightData> _indexDataWeights = {};

  /// High weight table records (default threshold 70% or higher).
  final Set<TableUid> _highWeightTableRecords = {};

  /// High weight index entries (default threshold 70% or higher).
  final Set<String> _highWeightIndexData = {};

  /// File load lock, avoid high concurrency duplicate read
  final Map<String, Completer<void>> _loadingLocks = {};

  /// Whether initialized
  bool _initialized = false;

  /// Last decay time
  int _lastDecayTime = 0;

  /// Whether weight data has changed since last save
  bool _dirty = false;

  static const _indexDataKeyFormatField = 'indexDataKeyFormat';
  static const _indexUidKeyFormatValue = 'indexUid';

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
    } catch (e) {
      Logger.error('Failed to initialize WeightManager', rawError: e);
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
          _tableRecordWeights[TableUid(entry.key)] =
              WeightData.fromJson(entry.value as Map<String, dynamic>);
        }
      }

      // Load index data weights
      if (json['indexData'] is Map) {
        final indexDataWeights = json['indexData'] as Map<String, dynamic>;
        for (final entry in indexDataWeights.entries) {
          _indexDataWeights[entry.key] =
              WeightData.fromJson(entry.value as Map<String, dynamic>);
        }
      }

      // Load last decay time
      _lastDecayTime = json['lastDecayTime'] as int? ?? 0;

      final indexDataKeyFormatIndexUid =
          json[_indexDataKeyFormatField] == _indexUidKeyFormatValue;
      if (!indexDataKeyFormatIndexUid) {
        await _migrateLegacyIndexDataKeys(spaceName: spaceName);
        // Persist format marker once; avoids re-scanning on every future boot.
        _onMutation();
        await saveWeights(spaceName: spaceName, force: true);
      }

      // Rebuild high weight cache
      _rebuildHighWeightCache();

      completer.complete();
    } catch (e) {
      completer.completeError(e);
      Logger.error('Failed to load weights from file: $filePath', rawError: e);
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
        final schema = await _dataStore.tableMetaManager
            ?.getTableSchemaByName(TableName(tableName));
        if (schema == null) continue;

        // Initialize table record weights
        final tableKey = schema.tableUid;
        if (!_tableRecordWeights.containsKey(tableKey)) {
          int initialWeight = 0;
          if (isSystemTable) {
            initialWeight = 10; // System table initial weight 10
          }
          if (schema.isGlobal) {
            initialWeight += 10; // Global table extra 10
          }

          _tableRecordWeights[tableKey] = WeightData(
            weight: initialWeight,
            accessCount: 0,
            lastUpdateTime: DateTime.now().millisecondsSinceEpoch,
          );
        }

        // Initialize B+Tree index weights (vector index weights are separate).
        final indexes = _dataStore.tableMetaManager?.getBtreeIndexesFor(schema);
        if (indexes == null) return;
        for (final index in indexes) {
          await yieldController.maybeYield();
          final indexKey = _getIndexDataKey(schema.tableUid, index.indexUid);
          if (!_indexDataWeights.containsKey(indexKey)) {
            int initialWeight = 0;
            if (isSystemTable) {
              initialWeight = 10; // System table index initial weight 10
            }
            if (schema.isGlobal) {
              initialWeight += 10; // Global table index extra 10
            }

            _indexDataWeights[indexKey] = WeightData(
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
    } catch (e) {
      Logger.error('Failed to initialize weights', rawError: e);
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
          for (final entry in _tableRecordWeights.entries)
            entry.key.value: entry.value.toJson(),
        },
        'indexData': {
          for (final entry in _indexDataWeights.entries)
            entry.key: entry.value.toJson(),
        },
        'lastDecayTime': _lastDecayTime,
        _indexDataKeyFormatField: _indexUidKeyFormatValue,
      };

      await _dataStore.storage.writeAsString(
        filePath,
        jsonEncode(json),
        flush: true,
      );
    } catch (e) {
      Logger.error('Failed to save weights to file', rawError: e);
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
    _tableRecordWeights.clear();
    _indexDataWeights.clear();
    _highWeightTableRecords.clear();
    _highWeightIndexData.clear();
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
      if (type == WeightType.tableRecord ||
          (type == WeightType.indexData && _indexDataWeights.isNotEmpty)) {
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
    final now = DateTime.now().millisecondsSinceEpoch;

    if (type == WeightType.tableRecord) {
      final key = TableUid(identifier);
      final existing = _tableRecordWeights[key];
      if (existing != null) {
        _tableRecordWeights[key] = existing.copyWith(
          accessCount: existing.accessCount + 1,
          lastUpdateTime: now,
        );
      } else {
        _tableRecordWeights[key] = WeightData(
          weight: 0,
          accessCount: 1,
          lastUpdateTime: now,
          neverDecay: false,
        );
      }
    } else {
      final existing = _indexDataWeights[identifier];
      if (existing != null) {
        _indexDataWeights[identifier] = existing.copyWith(
          accessCount: existing.accessCount + 1,
          lastUpdateTime: now,
        );
      } else {
        _indexDataWeights[identifier] = WeightData(
          weight: 0,
          accessCount: 1,
          lastUpdateTime: now,
          neverDecay: false,
        );
      }
    }

    _onMutation();
  }

  /// Get weight value
  Future<int> getWeight(
    WeightType type,
    String identifier, {
    String? spaceName,
  }) async {
    await _ensureWeightsLoaded(spaceName: spaceName);
    final data = type == WeightType.tableRecord
        ? _tableRecordWeights[TableUid(identifier)]
        : _indexDataWeights[identifier];
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
    final data = type == WeightType.tableRecord
        ? _tableRecordWeights[TableUid(identifier)]
        : _indexDataWeights[identifier];
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

    final now = DateTime.now().millisecondsSinceEpoch;

    if (type == WeightType.tableRecord) {
      final key = TableUid(identifier);
      final existing = _tableRecordWeights[key];
      if (existing != null) {
        _tableRecordWeights[key] = existing.copyWith(
          customWeight: weight,
          neverDecay: neverDecay,
          lastUpdateTime: now,
        );
      } else {
        _tableRecordWeights[key] = WeightData(
          weight: weight ?? 0,
          accessCount: 0,
          lastUpdateTime: now,
          neverDecay: neverDecay,
          customWeight: weight,
        );
      }
      _updateHighWeightCache(type, key);
    } else {
      final existing = _indexDataWeights[identifier];
      if (existing != null) {
        _indexDataWeights[identifier] = existing.copyWith(
          customWeight: weight,
          neverDecay: neverDecay,
          lastUpdateTime: now,
        );
      } else {
        _indexDataWeights[identifier] = WeightData(
          weight: weight ?? 0,
          accessCount: 0,
          lastUpdateTime: now,
          neverDecay: neverDecay,
          customWeight: weight,
        );
      }
      _updateHighWeightCache(type, identifier);
    }

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
      return type == WeightType.tableRecord
          ? _highWeightTableRecords.contains(TableUid(identifier))
          : _highWeightIndexData.contains(identifier);
    }

    // Custom threshold, need to calculate
    final weight = await getWeight(type, identifier, spaceName: spaceName);
    final maxWeight = 100;
    return weight >= (maxWeight * threshold).round();
  }

  /// Index weight cache key: [tableUid]:[indexUid].
  static String indexDataIdentifier(TableUid tableUid, IndexUid indexUid) =>
      '$tableUid:${indexUid.value}';

  /// Get index data identifier
  String _getIndexDataKey(TableUid tableUid, IndexUid indexUid) =>
      indexDataIdentifier(tableUid, indexUid);

  /// Merge weight from [fromKey] into [toKey] (used for legacy key migration).
  void _mergeIndexWeightKey(String fromKey, String toKey) {
    if (fromKey == toKey) return;
    final from = _indexDataWeights.remove(fromKey);
    if (from == null) return;

    final existing = _indexDataWeights[toKey];
    if (existing == null) {
      _indexDataWeights[toKey] = from;
      return;
    }

    _indexDataWeights[toKey] = WeightData(
      weight: from.weight > existing.weight ? from.weight : existing.weight,
      accessCount: from.accessCount + existing.accessCount,
      lastUpdateTime: from.lastUpdateTime > existing.lastUpdateTime
          ? from.lastUpdateTime
          : existing.lastUpdateTime,
      neverDecay: from.neverDecay || existing.neverDecay,
      customWeight: from.customWeight ?? existing.customWeight,
    );
  }

  /// Migrate a legacy index weight key (actualIndexName suffix) to [indexUid].
  bool _migrateLegacyIndexKey(
    TableUid tableUid,
    String legacySuffix,
    IndexUid indexUid,
  ) {
    if (legacySuffix.isEmpty || indexUid.isEmpty) return false;
    final legacyKey = '$tableUid:$legacySuffix';
    final uidKey = _getIndexDataKey(tableUid, indexUid);
    if (legacyKey == uidKey) return false;
    if (!_indexDataWeights.containsKey(legacyKey)) {
      return false;
    }
    _mergeIndexWeightKey(legacyKey, uidKey);
    return true;
  }

  /// In-memory check: any indexData key whose suffix is not a stable [IndexUid].
  bool _hasLegacyIndexDataKeysInCache() {
    for (final key in _indexDataWeights.keys) {
      final colon = key.indexOf(':');
      if (colon <= 0 || colon >= key.length - 1) continue;
      if (!IndexUid(key.substring(colon + 1)).looksLikeStableUid) {
        return true;
      }
    }
    return false;
  }

  /// Migrate on-disk / in-memory index weight keys from legacy names to [IndexUid].
  ///
  /// Caller persists [indexDataKeyFormat] after this returns; do not save here.
  Future<void> _migrateLegacyIndexDataKeys({String? spaceName}) async {
    if (!_hasLegacyIndexDataKeysInCache()) return;

    final schemaMgr = _dataStore.tableMetaManager;
    if (schemaMgr == null) return;

    final yieldController = YieldController(
      'WeightManager._migrateLegacyIndexDataKeys',
      checkInterval: 100,
    );

    try {
      final allTables = await _dataStore.getTableNames();
      for (final tableName in allTables) {
        await yieldController.maybeYield();

        final existsInSpace =
            await _dataStore.tableExistsInCurrentSpace(tableName);
        if (!existsInSpace) continue;

        final schema =
            await schemaMgr.getTableSchemaByName(TableName(tableName));
        if (schema == null) continue;

        final tableUid = schema.tableUid;
        final indexes = schemaMgr.getBtreeIndexesFor(schema);
        for (final index in indexes) {
          await yieldController.maybeYield();
          if (index.indexUid.isEmpty) continue;

          final legacyNames = <String>{
            index.actualIndexName,
            if (index.indexName != null && index.indexName!.isNotEmpty)
              index.indexName!,
          };
          for (final legacy in legacyNames) {
            _migrateLegacyIndexKey(tableUid, legacy, index.indexUid);
          }
        }
      }

      // Sweep orphan keys whose suffix is not a stable uid.
      final indexCache = _indexDataWeights;
      final keysToProcess = indexCache.keys.toList(growable: false);
      for (final key in keysToProcess) {
        await yieldController.maybeYield();
        final colon = key.indexOf(':');
        if (colon <= 0 || colon >= key.length - 1) continue;

        final tableUid = TableUid(key.substring(0, colon));
        final suffix = key.substring(colon + 1);
        if (IndexUid(suffix).looksLikeStableUid) continue;

        final schema = await schemaMgr.getTableSchema(tableUid);
        if (schema == null) continue;

        final indexUid = schemaMgr.resolveIndexUidFromField(schema, suffix);
        if (!indexUid.looksLikeStableUid || indexUid.value == suffix) {
          continue;
        }
        _migrateLegacyIndexKey(tableUid, suffix, indexUid);
      }
    } catch (e) {
      Logger.warn('Failed to migrate legacy index weight keys', rawError: e);
    }
  }

  /// Ensure weights are loaded
  Future<void> _ensureWeightsLoaded({String? spaceName}) async {
    if (!_initialized) {
      await initialize();
    }
    if (_tableRecordWeights.isEmpty && _indexDataWeights.isEmpty) {
      await _loadWeights(spaceName: spaceName);
    }
  }

  /// Rebuild high weight cache
  void _rebuildHighWeightCache() {
    _highWeightTableRecords.clear();
    _highWeightIndexData.clear();

    for (final entry in _tableRecordWeights.entries) {
      _updateHighWeightCache(WeightType.tableRecord, entry.key);
    }
    for (final entry in _indexDataWeights.entries) {
      _updateHighWeightCache(WeightType.indexData, entry.key);
    }
  }

  /// Update high weight cache
  void _updateHighWeightCache(WeightType type, Object identifier) {
    if (type == WeightType.tableRecord) {
      final key = identifier as TableUid;
      final data = _tableRecordWeights[key];
      if (data == null) {
        _highWeightTableRecords.remove(key);
        return;
      }
      final weight = data.customWeight ?? data.weight;
      final threshold = (100 * 0.7).round();
      if (weight >= threshold) {
        _highWeightTableRecords.add(key);
      } else {
        _highWeightTableRecords.remove(key);
      }
      return;
    }

    final key = identifier as String;
    final data = _indexDataWeights[key];
    if (data == null) {
      _highWeightIndexData.remove(key);
      return;
    }

    final weight = data.customWeight ?? data.weight;
    final threshold = (100 * 0.7).round();
    if (weight >= threshold) {
      _highWeightIndexData.add(key);
    } else {
      _highWeightIndexData.remove(key);
    }
  }

  /// Decay weights for one cache bucket.
  Future<void> _decayWeightCache<K>(
    WeightType type,
    Map<K, WeightData> cache,
    int now,
    YieldController yieldController,
  ) async {
    if (cache.isEmpty) return;

    final candidates = <K, WeightData>{};
    for (final entry in cache.entries) {
      await yieldController.maybeYield();
      if (!entry.value.neverDecay && entry.value.accessCount > 0) {
        candidates[entry.key] = entry.value;
      }
    }
    if (candidates.isEmpty) return;

    final sorted = candidates.entries.toList()
      ..sort((a, b) => b.value.accessCount.compareTo(a.value.accessCount));

    final totalCount = sorted.length;
    final top50Count = (totalCount * 0.5).ceil();
    final top50 = sorted.take(top50Count).toList();
    final bottom50 = sorted.skip(top50Count).toList();

    if (top50.isNotEmpty) {
      final maxAccessCount = top50.first.value.accessCount;
      if (maxAccessCount > 0) {
        for (final entry in top50) {
          await yieldController.maybeYield();

          final data = entry.value;
          final score = (data.accessCount * 100 / maxAccessCount).round();
          final weightIncrease = (data.weight * 0.1).round();
          final newWeight =
              (data.weight + weightIncrease + score).clamp(0, 100);

          cache[entry.key] = data.copyWith(
            weight: newWeight,
            accessCount: 0,
            lastUpdateTime: now,
          );
          _updateHighWeightCache(type, entry.key as Object);
        }
      }
    }

    if (bottom50.isNotEmpty) {
      final maxAccessCount = top50.isNotEmpty
          ? top50.first.value.accessCount
          : bottom50.first.value.accessCount;
      if (maxAccessCount > 0) {
        for (final entry in bottom50) {
          await yieldController.maybeYield();

          final data = entry.value;
          final score = (data.accessCount * 100 / maxAccessCount).round();
          final weightDecrease = (data.weight * 0.1).round();
          final newWeight =
              (data.weight - weightDecrease - score).clamp(0, 100);

          cache[entry.key] = data.copyWith(
            weight: newWeight,
            accessCount: 0,
            lastUpdateTime: now,
          );
          _updateHighWeightCache(type, entry.key as Object);
        }
      }
    }
  }

  /// Perform weight decay
  Future<void> _performDecay() async {
    try {
      final yieldController =
          YieldController('WeightManager._performDecay', checkInterval: 50);

      final now = DateTime.now().millisecondsSinceEpoch;

      // Process each type separately
      await _decayWeightCache(
        WeightType.tableRecord,
        _tableRecordWeights,
        now,
        yieldController,
      );
      await _decayWeightCache(
        WeightType.indexData,
        _indexDataWeights,
        now,
        yieldController,
      );

      // Update last decay time
      _lastDecayTime = now;

      // Mark as dirty and notify activity
      _onMutation();
    } catch (e) {
      Logger.error('Failed to perform weight decay', rawError: e);
    }
  }

  /// Get sorted identifier list by weight
  Future<List<String>> getSortedIdentifiers(
    WeightType type, {
    bool descending = true,
    String? spaceName,
  }) async {
    await _ensureWeightsLoaded(spaceName: spaceName);

    final entries = type == WeightType.tableRecord
        ? _tableRecordWeights.entries
            .map((e) => MapEntry<String, WeightData>(e.key.value, e.value))
            .toList()
        : _indexDataWeights.entries.toList();

    entries.sort((a, b) {
      final weightA = a.value.customWeight ?? a.value.weight;
      final weightB = b.value.customWeight ?? b.value.weight;
      return descending
          ? weightB.compareTo(weightA)
          : weightA.compareTo(weightB);
    });

    return entries.map((e) => e.key).toList();
  }

  /// Clear weights for a specific table
  void clearWeightsForTable(TableContext table) {
    final tableUid = table.tableUid;
    bool changed = false;

    // 1. Remove table record weight
    if (_tableRecordWeights.containsKey(tableUid)) {
      _tableRecordWeights.remove(tableUid);
      changed = true;
    }

    // 2. Remove index weights
    final prefix = '$tableUid:';
    final keysToRemove =
        _indexDataWeights.keys.where((k) => k.startsWith(prefix)).toList();
    for (final key in keysToRemove) {
      _indexDataWeights.remove(key);
      changed = true;
    }

    if (changed) {
      _rebuildHighWeightCache();
      _dirty = true;
    }
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
