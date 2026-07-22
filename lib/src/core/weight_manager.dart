import 'dart:async';

import '../handler/logger.dart';
import '../handler/weight_snapshot_codec.dart';
import '../model/system_table.dart';
import '../model/table_context.dart';
import '../model/table_identity.dart';
import '../model/weight_data.dart';
import 'crontab_manager.dart';
import 'data_store_impl.dart';
import 'yield_controller.dart';

export '../model/weight_data.dart';

/// Weight manager
/// Responsible for managing the weights of table records and index data, supporting weight decay, query, etc.
///
/// Persistence: space-local internal KV key [WeightSnapshotCodec.internalKvKey]
/// (`isGlobal: false`), field-tag binary payload (no JSON).
class WeightManager {
  final DataStoreImpl _dataStore;

  /// Table record weights keyed by stable [TableUid].
  final Map<TableUid, WeightData> _tableRecordWeights = {};

  /// Index data weights keyed by [indexDataIdentifier] (`tableUid:indexUid`).
  final Map<String, WeightData> _indexDataWeights = {};

  /// High weight table records (default threshold 70% or higher).
  final Set<TableUid> _highWeightTableRecords = {};

  /// High weight index entries (default threshold 70% or higher).
  final Set<String> _highWeightIndexData = {};

  /// Load lock, avoid high concurrency duplicate read
  Completer<void>? _loadingLock;

  /// Whether initialized
  bool _initialized = false;

  /// Last decay time
  int _lastDecayTime = 0;

  /// Whether weight data has changed since last save
  bool _dirty = false;

  /// Monotonic mutation counter. Save captures this with the snapshot and only
  /// clears [_dirty] when it is unchanged (no concurrent mutation after capture).
  int _dirtySeq = 0;

  /// Last successful KV persist time (ms epoch). Used for 1h dirty guarantee.
  int _lastSuccessfulSaveMs = 0;

  /// >0 while WeightManager reads/writes its own KV blob.
  /// Hot path: callers only do a cheap `!= 0` check; detailed skip runs rarely.
  int _weightMetaIoDepth = 0;

  /// Cached space-local internal KV tableUid.value (and index key prefix).
  String? _spaceInternalKvUidValue;
  String? _spaceInternalKvIndexPrefix;

  /// Lock for saving weights
  Future<void>? _saveLock;

  WeightManager(this._dataStore) {
    CrontabManager.addCallback(ExecuteInterval.hour24, _performDecay);
    CrontabManager.addCallback(ExecuteInterval.seconds30, _periodicSave);
    CrontabManager.addCallback(ExecuteInterval.hour1, _hourlyGuaranteeSave);
  }

  /// Dispose weight manager and deregister crontab callbacks
  void dispose() {
    CrontabManager.removeCallback(ExecuteInterval.hour24, _performDecay);
    CrontabManager.removeCallback(ExecuteInterval.seconds30, _periodicSave);
    CrontabManager.removeCallback(ExecuteInterval.hour1, _hourlyGuaranteeSave);
  }

  Future<T> _withWeightMetaIo<T>(Future<T> Function() action) async {
    await _ensureSpaceInternalKvTableUidCached();
    _weightMetaIoDepth++;
    try {
      return await action();
    } finally {
      _weightMetaIoDepth--;
    }
  }

  Future<void> _ensureSpaceInternalKvTableUidCached() async {
    if (_spaceInternalKvUidValue != null) return;
    final schema = await _dataStore.tableMetaManager?.getTableSchemaByName(
      TableName(SystemTable.getInternalKeyValueName(false)),
    );
    final uid = schema?.tableUid.value;
    if (uid == null || uid.isEmpty) return;
    _spaceInternalKvUidValue = uid;
    _spaceInternalKvIndexPrefix = '$uid:';
  }

  /// Cold path only (caller already verified [_weightMetaIoDepth] != 0).
  bool _shouldSkipAccessStat(WeightType type, String identifier) {
    final uid = _spaceInternalKvUidValue;
    // Fail-safe: uid unknown → suppress all (preserves self-loop protection).
    if (uid == null) return true;
    if (type == WeightType.tableRecord) return identifier == uid;
    return identifier.startsWith(_spaceInternalKvIndexPrefix!);
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

  /// Apply a snapshot into memory (e.g. after async V3 legacy import).
  void applySnapshot(WeightSnapshot snapshot, {bool markDirty = false}) {
    _tableRecordWeights
      ..clear()
      ..addAll(snapshot.tableRecord);
    _indexDataWeights
      ..clear()
      ..addAll(snapshot.indexData);
    _lastDecayTime = snapshot.lastDecayTime;
    if (!snapshot.indexDataKeyFormatIsUid) {
      // Best-effort in-memory legacy key migrate; persist on next save.
      unawaited(_migrateLegacyIndexDataKeys().then((_) {
        _onMutation();
      }));
    }
    _rebuildHighWeightCache();
    if (markDirty) {
      _onMutation();
    } else {
      // Authoritative replace (e.g. just written to KV) — drop stale dirty.
      _dirty = false;
      _dirtySeq++;
    }
  }

  /// Load weight data from space-local internal KV
  Future<void> _loadWeights({String? spaceName}) async {
    if (_loadingLock != null) {
      await _loadingLock!.future;
      return;
    }

    final completer = Completer<void>();
    _loadingLock = completer;

    try {
      final bytes = await _withWeightMetaIo(() async {
        return await _dataStore.internalKv.get(
          WeightSnapshotCodec.internalKvKey,
          isGlobal: false,
        );
      });

      if (bytes == null || bytes.isEmpty) {
        await _initializeWeights(spaceName: spaceName);
        completer.complete();
        return;
      }

      final snapshot = WeightSnapshotCodec.decode(bytes);
      _tableRecordWeights
        ..clear()
        ..addAll(snapshot.tableRecord);
      _indexDataWeights
        ..clear()
        ..addAll(snapshot.indexData);
      _lastDecayTime = snapshot.lastDecayTime;

      if (!snapshot.indexDataKeyFormatIsUid) {
        await _migrateLegacyIndexDataKeys(spaceName: spaceName);
        _onMutation();
        await saveWeights(spaceName: spaceName, force: true);
      }

      _rebuildHighWeightCache();
      completer.complete();
    } catch (e) {
      completer.completeError(e);
      Logger.error('Failed to load weights from internal KV', rawError: e);
      await _initializeWeights(spaceName: spaceName);
    } finally {
      if (identical(_loadingLock, completer)) {
        _loadingLock = null;
      }
    }
  }

  /// Initialize weight data
  Future<void> _initializeWeights({String? spaceName}) async {
    try {
      final yieldController = YieldController(
          'WeightManager._initializeWeights',
          checkInterval: 100);

      final allTables = await _dataStore.getTableNames();

      for (final tableName in allTables) {
        await yieldController.maybeYield();

        final isSystemTable = SystemTable.isSystemTable(tableName);

        final existsInSpace =
            await _dataStore.tableExistsInCurrentSpace(tableName);
        if (!existsInSpace) continue;

        final schema = await _dataStore.tableMetaManager
            ?.getTableSchemaByName(TableName(tableName));
        if (schema == null) continue;

        final tableKey = schema.tableUid;
        if (!_tableRecordWeights.containsKey(tableKey)) {
          int initialWeight = 0;
          if (isSystemTable) {
            initialWeight = 10;
          }
          if (schema.isGlobal) {
            initialWeight += 10;
          }

          _tableRecordWeights[tableKey] = WeightData(
            weight: initialWeight,
            accessCount: 0,
            lastUpdateTime: DateTime.now().millisecondsSinceEpoch,
          );
        }

        final indexes = _dataStore.tableMetaManager?.getBtreeIndexesFor(schema);
        if (indexes == null) continue;
        for (final index in indexes) {
          await yieldController.maybeYield();
          final indexKey = _getIndexDataKey(schema.tableUid, index.indexUid);
          if (!_indexDataWeights.containsKey(indexKey)) {
            int initialWeight = 0;
            if (isSystemTable) {
              initialWeight = 10;
            }
            if (schema.isGlobal) {
              initialWeight += 10;
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
    _dirtySeq++;
    CrontabManager.notifyActivity();
  }

  /// Periodic save callback for CrontabManager
  void _periodicSave() {
    if (_dirty) {
      saveWeights(force: false);
    }
  }

  /// If dirty for a long time under continuous write pressure, force persist.
  void _hourlyGuaranteeSave() {
    if (!_dirty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    const hourMs = 60 * 60 * 1000;
    if (_lastSuccessfulSaveMs > 0 && now - _lastSuccessfulSaveMs < hourMs) {
      return;
    }
    saveWeights(force: true);
  }

  /// Whether the write buffer is idle enough to absorb a weight KV upsert.
  bool _isWriteBufferIdleEnough() {
    final batch = _dataStore.config.writeBatchSize;
    if (batch <= 0) return true;
    final threshold = (batch * 0.1).ceil();
    return _dataStore.writeBufferManager.queueLength <= threshold;
  }

  /// Save weight snapshot to space-local internal KV.
  Future<void> saveWeights({String? spaceName, bool force = false}) async {
    if (!force && !_dirty) return;
    if (!force && !_isWriteBufferIdleEnough()) {
      // Keep dirty; retry on next 30s tick or hourly guarantee.
      return;
    }

    if (_saveLock != null) {
      await _saveLock;
    }

    // Prior saver may have cleared dirty / drained the buffer.
    if (!force && !_dirty) return;
    if (!force && !_isWriteBufferIdleEnough()) return;

    final completer = Completer<void>();
    _saveLock = completer.future;

    try {
      final seqAtCapture = _dirtySeq;
      final snapshot = WeightSnapshot(
        tableRecord: Map<TableUid, WeightData>.from(_tableRecordWeights),
        indexData: Map<String, WeightData>.from(_indexDataWeights),
        lastDecayTime: _lastDecayTime,
        indexDataKeyFormatIsUid: true,
      );
      final bytes = WeightSnapshotCodec.encode(snapshot);

      await _withWeightMetaIo(() async {
        await _dataStore.internalKv.set(
          WeightSnapshotCodec.internalKvKey,
          bytes,
          isGlobal: false,
        );
      });

      // Concurrent mutation after capture → keep dirty for a follow-up save.
      if (_dirtySeq == seqAtCapture) {
        _dirty = false;
        _lastSuccessfulSaveMs = DateTime.now().millisecondsSinceEpoch;
      }
    } catch (e) {
      Logger.error('Failed to save weights to internal KV', rawError: e);
      // Keep _dirty so a later tick/hourly guarantee retries.
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
    _dirtySeq++; // invalidate in-flight save's dirty-clear
  }

  /// Increment access count
  Future<void> incrementAccess(
    WeightType type,
    String identifier, {
    String? spaceName,
  }) async {
    if (_weightMetaIoDepth != 0 && _shouldSkipAccessStat(type, identifier)) {
      return;
    }

    if (_initialized) {
      if (type == WeightType.tableRecord ||
          (type == WeightType.indexData && _indexDataWeights.isNotEmpty)) {
        _syncIncrementAccess(type, identifier, spaceName: spaceName);
        return;
      }
    }

    // Fallback to async loading if not fully initialized or cache is empty
    await _ensureWeightsLoaded(spaceName: spaceName);
    if (_weightMetaIoDepth != 0 && _shouldSkipAccessStat(type, identifier)) {
      return;
    }
    _syncIncrementAccess(type, identifier, spaceName: spaceName);
  }

  /// Internal synchronous increment (assumes weights are loaded).
  /// Caller must already apply meta-IO skip when needed.
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

    final weight = await getWeight(type, identifier, spaceName: spaceName);
    return weight >= (100 * threshold).round();
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

      final keysToProcess = _indexDataWeights.keys.toList(growable: false);
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
      _onMutation();
    }
  }

  /// Clear weight data (for testing or reset)
  Future<void> clear({String? spaceName}) async {
    clearMemory();
    _dirty = false;
    _lastDecayTime = 0;

    try {
      await _withWeightMetaIo(() async {
        await _dataStore.internalKv.remove(
          WeightSnapshotCodec.internalKvKey,
          isGlobal: false,
        );
      });
    } catch (e) {
      Logger.warn('Failed to remove weight KV key', rawError: e);
    }
  }
}
