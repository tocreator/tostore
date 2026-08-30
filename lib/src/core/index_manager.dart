import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../handler/logger.dart';
import '../handler/memcomparable.dart';
import '../handler/value_matcher.dart';
import '../model/buffer_entry.dart';
import '../model/data_block_entry.dart';
import '../model/data_store_config.dart';
import '../model/db_exception.dart';
import '../model/id_generator.dart';
import '../model/index_entry.dart';
import '../model/index_search.dart';
import '../model/meta_info.dart';
import '../model/parallel_journal_entry.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/system_table.dart';
import '../model/table_context.dart';
import '../model/table_identity.dart';
import '../model/table_schema.dart';
import '../model/unique_violation.dart';
import '../query/query_condition.dart';
import 'compute/compute_batch_planner.dart';
import 'compute/index_delta_prepare_compute.dart';
import 'compute_manager.dart';
import 'data_store_impl.dart';
import 'key_migration_runner.dart';
import 'table_data_manager.dart';
import 'transaction_context.dart';
import 'tree_cache.dart';
import 'weight_manager.dart';
import 'yield_controller.dart';

/// Index Manager
/// Responsible for index creation, update, deletion, and query operations
class IndexManager {
  final DataStoreImpl _dataStore;

  // Index Cache
  // - unique:     Key: [tableUid, indexUid, ...indexFields]      Value: PK (String)
  // - non-unique: Key: [tableUid, indexUid, ...indexFields, pk]  Value: true (bool marker)
  //
  // This avoids the old "bucket Set<PK>" read/modify/write amplification for non-unique indexes.
  late final TreeCache<dynamic> _indexDataCache;

  // Index metadata cache using TreeCache
  late final TreeCache<IndexMeta> _indexMetaCache;

  // Loading futures to prevent thundering herd on concurrent meta loads
  final Map<String, Future<IndexMeta?>> _metaLoadingFutures = {};

  String _getMetaLoadingKey(TableUid tableUid, IndexUid indexUid) =>
      '$tableUid#$indexUid';

  /// Drop all in-memory state for one index (data cache, meta, matchers, page cache).
  void _invalidateIndexCache(TableContext table, IndexUid indexUid) {
    if (indexUid.isEmpty) return;
    _indexMetaCache.removePoint2(table.tableUid, indexUid);
    _indexDataCache.remove([table.tableUid, indexUid]);
    _metaLoadingFutures.remove(_getMetaLoadingKey(table.tableUid, indexUid));
    _dataStore.indexTreePartitionManager
        ?.clearPageCacheForIndex(table, indexUid);
  }

  /// Invalidate cached [IndexMeta] after external partition-0 rewrite (redo replay).
  void invalidateIndexMetaCache(TableUid tableUid, IndexUid indexUid) {
    if (indexUid.isEmpty) return;
    _indexMetaCache.removePoint2(tableUid, indexUid);
    _metaLoadingFutures.remove(_getMetaLoadingKey(tableUid, indexUid));
  }

  /// Resolve [uidOrName] to an [IndexUid].
  ///
  /// 1. Treat as [IndexUid] and do O(1) schema lookup by uid.
  /// 2. Only when that miss (empty): treat as legacy indexName / alias.
  IndexUid _resolveIndexUid(
    TableContext table,
    String uidOrName, {
    TableSchema? schema,
  }) {
    if (uidOrName.isEmpty) return IndexUid.empty;
    final asUid = IndexUid(uidOrName);
    final s = schema ?? table.schema;
    final schemaMgr = _dataStore.tableMetaManager;
    if (schemaMgr != null && schemaMgr.findIndexSchemaByUid(s, asUid) != null) {
      return asUid;
    }

    final fromName = _resolveIndexUidFromIndexName(table, uidOrName, schema: s);
    if (fromName.isNotEmpty) return fromName;
    // Keep raw token so pre-migration on-disk paths keyed by name still resolve.
    return asUid;
  }

  /// Compat-only: map a legacy logical indexName / field alias to stable uid.
  ///
  /// Invoked only after an IndexUid lookup returned empty.
  IndexUid _resolveIndexUidFromIndexName(
    TableContext table,
    String indexName, {
    TableSchema? schema,
  }) {
    if (indexName.isEmpty) return IndexUid.empty;
    if (_isInternalKvExpiryIndexField(table, indexName)) {
      return SystemTable.keyValueExpiryIndexUid;
    }
    final schemaMgr = _dataStore.tableMetaManager;
    if (schemaMgr == null) return IndexUid.empty;
    final s = schema ?? table.schema;
    final byName = schemaMgr.findIndexSchemaByField(s, indexName);
    if (byName != null && byName.indexUid.isNotEmpty) {
      return byName.indexUid;
    }
    return IndexUid.empty;
  }

  IndexUid _indexUidFromSchema(IndexSchema index) => index.indexUid;

  String _indexLogLabel(TableContext table, IndexUid indexUid,
      {TableSchema? schema}) {
    final s = schema ?? table.schema;
    final idx = _findBtreeIndexSchema(s, indexUid, table: table);
    return idx?.actualIndexName ?? 'index';
  }

  /// Lookup of B+Tree [IndexSchema] by [IndexUid].
  ///
  /// 1. O(1) by uid (plus engine-managed uid equality).
  /// 2. Only when empty: treat [indexUid.value] as indexName / alias.
  IndexSchema? _findBtreeIndexSchema(
    TableSchema schema,
    IndexUid indexUid, {
    TableContext? table,
  }) {
    if (indexUid.isEmpty) return null;
    final schemaMgr = _dataStore.tableMetaManager;
    if (schemaMgr == null) return null;

    final byUid = schemaMgr.findIndexSchemaByUid(schema, indexUid);
    if (byUid != null) return byUid;

    if (table != null) {
      for (final i in getEngineManagedBtreeIndexes(table, schema)) {
        if (_indexUidFromSchema(i) == indexUid) return i;
      }
    }

    // Miss as IndexUid -> compat as indexName.
    return schemaMgr.findIndexSchemaByField(schema, indexUid.value);
  }

  String _indexLockKey(TableUid tableUid, IndexUid indexUid) =>
      'index:$tableUid:$indexUid';

  int _estimateIndexDeltaRecordBytes(
    Map<String, dynamic> record,
    List<String> fields,
  ) {
    return _dataStore.tableDataManager.estimateRecordSizeBytes(record) +
        (fields.length * 64) +
        96;
  }

  int _estimateIndexDeltaUpdateBytes(
    IndexRecordUpdate update,
    List<String> fields,
  ) {
    var size = _dataStore.tableDataManager.estimateRecordSizeBytes(
          update.newValues,
        ) +
        (fields.length * 96) +
        128;

    final oldValues = update.oldValues;
    if (oldValues != null) {
      size += _dataStore.tableDataManager.estimateRecordSizeBytes(oldValues);
    }
    final changedFields = update.changedFields;
    if (changedFields != null) {
      size += changedFields.length * 24;
    }
    return size;
  }

  int _estimateIndexDeltaAverageItemBytes({
    required List<Map<String, dynamic>> inserts,
    required List<Map<String, dynamic>> deletes,
    required List<IndexRecordUpdate> updates,
    required List<String> fields,
  }) {
    final totalCount = inserts.length + deletes.length + updates.length;
    if (totalCount <= 0) return 0;

    int weightedBytes = 0;
    if (inserts.isNotEmpty) {
      weightedBytes += ComputeBatchPlanner.estimateAverageItemBytes(
            inserts,
            (record) => _estimateIndexDeltaRecordBytes(record, fields),
          ) *
          inserts.length;
    }
    if (deletes.isNotEmpty) {
      weightedBytes += ComputeBatchPlanner.estimateAverageItemBytes(
            deletes,
            (record) => _estimateIndexDeltaRecordBytes(record, fields),
          ) *
          deletes.length;
    }
    if (updates.isNotEmpty) {
      weightedBytes += ComputeBatchPlanner.estimateAverageItemBytes(
            updates,
            (update) => _estimateIndexDeltaUpdateBytes(update, fields),
          ) *
          updates.length;
    }

    return max(1, (weightedBytes / totalCount).ceil());
  }

  Future<List<DataBlockEntry>> _prepareIndexWriteDeltasBatch({
    required TableSchema schema,
    required TableContext table,
    required String indexName,
    required String primaryKeyField,
    required List<String> fields,
    required bool isUnique,
    required bool isInternalKvExpiryIndex,
    required bool isInternalTtlIndex,
    required String? batchIngestIso,
    required List<Map<String, dynamic>> inserts,
    required List<Map<String, dynamic>> deletes,
    required List<IndexRecordUpdate> updates,
  }) async {
    final totalItemCount = inserts.length + deletes.length + updates.length;
    if (totalItemCount <= 0) return const <DataBlockEntry>[];

    final dispatchPlan = ComputeBatchPlanner.planTaskExecution(
      itemCount: totalItemCount,
      minUsefulTaskItems: 256,
      estimateAverageItemBytes: () => _estimateIndexDeltaAverageItemBytes(
        inserts: inserts,
        deletes: deletes,
        updates: updates,
        fields: fields,
      ),
    );
    final useIsolate = dispatchPlan.useIsolate;
    final actualTaskCount = dispatchPlan.actualTaskCount;

    final tasks =
        <ComputeTask<IndexDeltaPrepareRequest, IndexDeltaPrepareResult>>[];
    void addRecordTasks(
      List<Map<String, dynamic>> records,
      IndexDeltaOperationKind operationKind,
    ) {
      for (final range
          in ComputeBatchPlanner.splitRange(records.length, actualTaskCount)) {
        tasks.add(
          ComputeTask(
            function: prepareIndexDeltaChunk,
            message: IndexDeltaPrepareRequest(
              schema: schema,
              tableName: table.tableName,
              indexName: IndexName(indexName),
              primaryKeyField: primaryKeyField,
              fields: fields,
              isUnique: isUnique,
              isInternalKvExpiryIndex: isInternalKvExpiryIndex,
              isInternalTtlIndex: isInternalTtlIndex,
              batchIngestIso: batchIngestIso,
              operationKind: operationKind,
              records: records.sublist(range.start, range.end),
              updates: const <IndexRecordUpdate>[],
            ),
          ),
        );
      }
    }

    void addUpdateTasks(List<IndexRecordUpdate> updateItems) {
      for (final range in ComputeBatchPlanner.splitRange(
          updateItems.length, actualTaskCount)) {
        tasks.add(
          ComputeTask(
            function: prepareIndexDeltaChunk,
            message: IndexDeltaPrepareRequest(
              schema: schema,
              tableName: table.tableName,
              indexName: IndexName(indexName),
              primaryKeyField: primaryKeyField,
              fields: fields,
              isUnique: isUnique,
              isInternalKvExpiryIndex: isInternalKvExpiryIndex,
              isInternalTtlIndex: isInternalTtlIndex,
              batchIngestIso: batchIngestIso,
              operationKind: IndexDeltaOperationKind.update,
              records: const <Map<String, dynamic>>[],
              updates: updateItems.sublist(range.start, range.end),
            ),
          ),
        );
      }
    }

    if (inserts.isNotEmpty) {
      addRecordTasks(inserts, IndexDeltaOperationKind.insert);
    }
    if (deletes.isNotEmpty) {
      addRecordTasks(deletes, IndexDeltaOperationKind.delete);
    }
    if (updates.isNotEmpty) {
      addUpdateTasks(updates);
    }

    if (tasks.isEmpty) return const <DataBlockEntry>[];

    final results =
        await ComputeManager.computeBatch(tasks, enableIsolate: useIsolate);

    final deltas = <DataBlockEntry>[];
    final mergeYield =
        YieldController('IndexManager._prepareIndexWriteDeltasBatch');
    for (final result in results) {
      for (final delta in result.deltas) {
        final y1 = mergeYield.maybeYield();
        if (y1 != null) await y1;
        deltas.add(delta);
      }
    }
    return deltas;
  }

  /// Pure synchronous memcomparable encoding for a canonical unique key.
  Uint8List? _encodeUniqueIndexKeyBytesPure(
    TableSchema schema,
    IndexSchema index,
    dynamic canonicalKey,
  ) {
    if (canonicalKey == null) return null;
    final components = <Uint8List>[];
    for (int fieldIndex = 0; fieldIndex < index.fields.length; fieldIndex++) {
      final fieldName = index.fields[fieldIndex];
      final dynamic fieldValue;
      if (index.fields.length == 1) {
        fieldValue = canonicalKey;
      } else if (canonicalKey is List &&
          canonicalKey.length == index.fields.length) {
        fieldValue = canonicalKey[fieldIndex];
      } else {
        return null;
      }

      final component = schema.encodeFieldComponentToMemComparable(
        fieldName,
        fieldValue,
        truncateText: false,
      );
      if (component == null) return null;
      components.add(component);
    }
    return components.isNotEmpty
        ? MemComparableKey.encodeTuple(components)
        : null;
  }

  IndexManager(this._dataStore) {
    final res = _dataStore.resourceManager;
    final int maxBytes = res?.getIndexCacheSize() ?? (50 * 1024 * 1024);
    final metaCacheSize =
        res?.getMetaCacheSize() ?? 100 * 1024 * 1024; // Default 100MB
    final indexMetaCacheSize =
        (metaCacheSize * 0.25).toInt(); // 25% of meta cache

    final bool isMemoryMode =
        _dataStore.config.persistenceMode == PersistenceMode.memory;
    // Initialize index data cache
    _indexDataCache = TreeCache<dynamic>(
      sizeCalculator: _indexDataCacheSizeBytes,
      maxByteThreshold: isMemoryMode ? 1 : (maxBytes * 0.70).toInt(),
      minByteThreshold: isMemoryMode ? 1 : 150 * 1024 * 1024,
      groupDepth: 2,
      comparatorFactory: _indexComparatorFactory,
      weightQueryCallback: isMemoryMode ? null : _queryIndexDataWeight,
      evictionMode:
          isMemoryMode ? TreeCacheEvictionMode.none : TreeCacheEvictionMode.lru,
      debugLabel: 'IndexDataCache',
    );

    _indexMetaCache = TreeCache<IndexMeta>(
      sizeCalculator: _estimateIndexMetaSize,
      maxByteThreshold: indexMetaCacheSize,
      minByteThreshold: 50 * 1024 * 1024,
      debugLabel: 'IndexMetaCache',
    );
  }

  /// Query weight for index data cache entry
  /// Path format: [tableUid, indexUid, ...indexFields]
  /// Weight object is tableUid:indexUid
  Future<int?> _queryIndexDataWeight(List<dynamic> path) async {
    if (path.length < 2) return null;
    final tableUid = path[0]?.toString();
    final indexUid = path[1]?.toString();
    if (tableUid == null ||
        tableUid.isEmpty ||
        indexUid == null ||
        indexUid.isEmpty) {
      return null;
    }

    try {
      final weightManager = _dataStore.weightManager;
      if (weightManager == null) return null;

      final indexKey = WeightManager.indexDataIdentifier(
        TableUid(tableUid),
        IndexUid(indexUid),
      );
      return await weightManager.getWeight(
        WeightType.indexData,
        indexKey,
      );
    } catch (e) {
      final logTable = (await _dataStore.tableMetaManager
                  ?.resolveTableNameFromField(tableUid))
              ?.value ??
          'unknown';
      Logger.warn('Failed to query index data weight for $logTable:$indexUid',
          rawError: e);
      return null;
    }
  }

  /// Estimate size of index data cache entries
  int _estimateIndexDataSize(dynamic value) {
    if (value is String) return value.length; // Unique index PK
    if (value is bool) return 1; // Non-unique marker (PK is in key)
    return 8; // Fallback
  }

  /// Prefer SpaceStats disk average; fallback to lightweight estimate.
  int _indexDataCacheSizeBytes(dynamic value) {
    final avg = _dataStore.tableDataManager.averageIndexEntrySizeBytes;
    if (avg != null && avg > 0) return avg;
    return _estimateIndexDataSize(value);
  }

  int _estimateIndexMetaSize(IndexMeta meta) {
    return 220 + meta.indexUid.length * 2 + meta.tableUid.length * 2;
  }

  List<IndexSchema> getEngineManagedBtreeIndexes(
    TableContext table,
    TableSchema schema,
  ) {
    if (!SystemTable.isKeyValueTable(table.tableName)) {
      return const <IndexSchema>[];
    }

    return <IndexSchema>[
      IndexSchema(
        indexName: SystemTable.keyValueExpiryIndexName,
        fields: <String>[SystemTable.keyValueExpiresAtField],
        unique: false,
      ).copyWith(indexUid: SystemTable.keyValueExpiryIndexUid),
    ];
  }

  String get _internalKvExpiryActualIndexName => const IndexSchema(
        indexName: SystemTable.keyValueExpiryIndexName,
        fields: <String>[SystemTable.keyValueExpiresAtField],
        unique: false,
      ).actualIndexName;

  bool _isInternalKvExpiryIndexField(TableContext table, String field) {
    return SystemTable.isKeyValueTable(table.tableName) &&
        (field == SystemTable.keyValueExpiryIndexUid ||
            field == 'i_sys_kv_expiry' || // legacy semantic uid
            field == _internalKvExpiryActualIndexName ||
            field == SystemTable.keyValueExpiryIndexName);
  }

  bool _isInternalKvExpiryIndex(TableContext table, IndexUid indexUid) {
    if (!SystemTable.isKeyValueTable(table.tableName)) return false;
    return indexUid == SystemTable.keyValueExpiryIndexUid ||
        indexUid.value == 'i_sys_kv_expiry'; // legacy semantic uid
  }

  Uint8List? _encodeInternalKvExpiryIndexKey(
    TableSchema schema,
    dynamic expiresAt,
    String pkValue,
  ) {
    final expiresAtComp = schema.encodeFieldComponentToMemComparable(
      SystemTable.keyValueExpiresAtField,
      expiresAt,
      truncateText: false,
    );
    if (expiresAtComp == null) return null;
    return MemComparableKey.encodeTuple(<Uint8List>[
      expiresAtComp,
      schema.encodePrimaryKeyComponent(pkValue),
    ]);
  }

  Future<Uint8List?> encodeInternalKvExpiryIndexKey(
    TableContext table, {
    required dynamic expiresAt,
    required String primaryKey,
  }) async {
    if (!SystemTable.isKeyValueTable(table.tableName)) {
      return null;
    }
    final schema =
        await _dataStore.tableMetaManager?.getTableSchema(table.tableUid);
    if (schema == null) return null;
    return _encodeInternalKvExpiryIndexKey(schema, expiresAt, primaryKey);
  }

  Future<IndexSearchResult> searchInternalKvExpiryIndexUpTo(
    TableContext table,
    DateTime upTo, {
    int? limit,
  }) async {
    if (!SystemTable.isKeyValueTable(table.tableName)) {
      return IndexSearchResult.empty();
    }

    final schema =
        await _dataStore.tableMetaManager?.getTableSchema(table.tableUid);
    if (schema == null) {
      return IndexSearchResult.empty();
    }

    final indexUid = SystemTable.keyValueExpiryIndexUid;
    final cutoffIso = upTo.toIso8601String();

    if (_dataStore.config.persistenceMode == PersistenceMode.memory) {
      final primaryKeys = <String>[];
      final entries = <IndexSearchEntry>[];

      await _indexDataCache.scanRange(
        <dynamic>[table.tableUid, indexUid],
        null,
        onEntry: (key, _) {
          if (key.length < 4 ||
              key[0] != table.tableUid ||
              key[1] != indexUid) {
            return false;
          }

          final expiresAt = key[2];
          final pk = key.last?.toString();
          if (expiresAt == null || pk == null || pk.isEmpty) {
            return true;
          }

          final expiresAtText = expiresAt.toString();
          if (expiresAtText.compareTo(cutoffIso) > 0) {
            return false;
          }

          final keyBytes =
              _encodeInternalKvExpiryIndexKey(schema, expiresAtText, pk);
          if (keyBytes == null) {
            return true;
          }

          primaryKeys.add(pk);
          entries.add(IndexSearchEntry(primaryKey: pk, keyBytes: keyBytes));
          return limit == null || primaryKeys.length < limit;
        },
      );

      return IndexSearchResult(
        primaryKeys: primaryKeys,
        entries: entries.isEmpty ? null : entries,
        lastKey: entries.isEmpty ? null : entries.last.keyBytes,
      );
    }

    final meta = await getIndexMeta(table.tableUid, indexUid);
    if (meta == null) {
      return IndexSearchResult.empty();
    }

    final cutoffComp = schema.encodeFieldComponentToMemComparable(
      SystemTable.keyValueExpiresAtField,
      cutoffIso,
      truncateText: false,
    );
    if (cutoffComp == null) {
      return IndexSearchResult.empty();
    }

    final prefix = MemComparableKey.encodeTuple(<Uint8List>[cutoffComp]);
    final endExclusive = Uint8List(prefix.length + 5);
    endExclusive.setRange(0, prefix.length, prefix);
    endExclusive[prefix.length] = 0xFF;
    final result = await _dataStore.indexTreePartitionManager?.searchByKeyRange(
      table: table,
      indexUid: indexUid,
      meta: meta,
      startKeyInclusive: Uint8List(0),
      endKeyExclusive: endExclusive,
      limit: limit,
    );
    return result ?? IndexSearchResult.empty();
  }

  Future<void> removeInternalKvExpiryIndexEntryByRawKey(
    TableContext table,
    Uint8List keyBytes,
  ) async {
    if (!_isInternalKvExpiryIndex(table, SystemTable.keyValueExpiryIndexUid) ||
        keyBytes.isEmpty) {
      return;
    }

    try {
      try {
        final decoded = MemComparableKey.decodeTuple(keyBytes);
        _indexDataCache.remove(
          <dynamic>[
            table.tableUid,
            SystemTable.keyValueExpiryIndexUid,
            ...decoded,
          ],
        );
      } catch (_) {}

      if (_dataStore.config.persistenceMode == PersistenceMode.memory) {
        return;
      }

      final meta = await getIndexMeta(
        table.tableUid,
        SystemTable.keyValueExpiryIndexUid,
      );
      if (meta == null) {
        return;
      }

      await _dataStore.indexTreePartitionManager?.writeChanges(
        table: table,
        indexUid: SystemTable.keyValueExpiryIndexUid,
        indexMeta: meta,
        deltas: <DataBlockEntry>[
          DataBlockEntry(keyBytes, Uint8List.fromList(const <int>[1])),
        ],
      );
    } catch (e) {
      Logger.warn(
          'Failed to remove internal KV expiry index entry for ${table.tableName}',
          rawError: e);
    }
  }

  /// Evict index metadata cache
  Future<void> evictIndexMetaCache(double ratio) async {
    if (ratio <= 0 || ratio > 1) return;
    try {
      await _indexMetaCache.cleanup(removeRatio: ratio);
      Logger.info(
        'Evicted ${(ratio * 100).toStringAsFixed(0)}% index meta cache due to memory pressure',
      );
    } catch (e) {
      Logger.error('Failed to evict index meta cache', rawError: e);
    }
  }

  /// Synchronously update full index cache based on record changes.
  /// Zero-await, pure in-memory operation.
  void updateIndexDataCacheSync(TableContext table, String pk,
      Map<String, dynamic>? oldData, Map<String, dynamic>? newData,
      {TableSchema? overrideSchema, bool force = false}) {
    try {
      final bool isMemoryMode =
          _dataStore.config.persistenceMode == PersistenceMode.memory;
      final bool shouldWrite =
          force || _dataStore.isGlobalPrewarming || isMemoryMode;

      // Fast path: if not in memory mode and cache is empty, no-op immediately
      if (!shouldWrite && _indexDataCache.isEmpty) {
        return;
      }

      final schema = overrideSchema ?? table.schema;
      final indexes = <IndexSchema>[
        ...?_dataStore.tableMetaManager?.getAllIndexesFor(schema),
        ...getEngineManagedBtreeIndexes(table, schema),
      ];
      if (indexes.isEmpty) return;

      for (final index in indexes) {
        if (index.type == IndexType.vector) continue;
        final indexUid = _indexUidFromSchema(index);

        // Remove old
        if (oldData != null) {
          final fields = <dynamic>[];
          bool success = true;
          for (final f in index.fields) {
            // Check existence first
            if (!oldData.containsKey(f)) {
              success = false;
              break;
            }
            // Use raw value
            fields.add(oldData[f]);
          }

          if (success) {
            final compositeKey = <dynamic>[
              table.tableUid,
              indexUid,
              ...fields,
            ]; // Raw Native Keys

            final dynamic removeKey =
                index.unique ? compositeKey : <dynamic>[...compositeKey, pk];
            if (shouldWrite || _indexDataCache.containsKey(removeKey)) {
              _indexDataCache.remove(removeKey);
            }
          }
        }

        // Add new
        if (newData != null) {
          final fields = <dynamic>[];
          bool success = true;
          for (final f in index.fields) {
            final v = newData[f];
            if (v == null) {
              success = false;
              break;
            }
            fields.add(v);
          }

          if (success) {
            final compositeKey = <dynamic>[table.tableUid, indexUid, ...fields];

            if (index.unique) {
              // Unique: key is index fields; value is PK.
              if (shouldWrite || _indexDataCache.containsKey(compositeKey)) {
                _indexDataCache.put(compositeKey, pk);
              }
            } else {
              // Non-unique: key includes PK; value is a bool marker.
              final fullKey = <dynamic>[...compositeKey, pk];
              if (shouldWrite || _indexDataCache.containsKey(fullKey)) {
                _indexDataCache.put(fullKey, true, size: pk.length + 1);
              }
            }
          }
        }
      }
    } catch (e) {
      Logger.warn('Failed to update index cache', rawError: e);
    }
  }

  /// Factory to provide comparators for TreeCache based on path
  Comparator<dynamic> _indexComparatorFactory(
    List<dynamic> path, {
    int suffixIndex = 0,
  }) {
    // Path structure: [table.tableUid, indexUid, field1, field2, ..., pk]
    if (path.length < 2) return TreeCache.compareNative;

    final tableUid = path.isNotEmpty ? path[0]?.toString() ?? '' : '';
    final indexUid = path.length > 1 ? path[1]?.toString() ?? '' : '';
    final matchers = _dataStore.tableMetaManager
        ?.resolveTreeMatcherEntry(TableUid(tableUid))
        ?.indexMatchersByUid[indexUid];

    if (matchers != null) {
      // path.length == 2: group [tableUid, indexUid]; suffixIndex 0 = field1,
      // suffixIndex fields.length = trailing pk (non-unique).
      final fieldIndex = (path.length - 2) + suffixIndex;
      if (fieldIndex >= 0 && fieldIndex < matchers.length) {
        return matchers[fieldIndex];
      }
    }

    // Default: compareNative for unknown paths.
    return TreeCache.compareNative;
  }

  /// Map a MemComparable index bound to a native TreeCache seek key.
  ///
  /// Exclusive prefix ends are stored as `prefix || 0xFF`. Decoding produces a
  /// trailing [Uint8List] that sorted as MAX under [TreeCache.compareNative]
  /// (type rank). Typed PK matchers compare via `toString()` (`"[]"`), so
  /// longer sequential PKs appear after the bound and the scan stops early
  /// (often after the first short PK). Replace that artifact with `'\uffff'`,
  /// the MAX sentinel understood by PK matchers.
  List<dynamic> _nativeTreeCacheSeekKey(
    List<dynamic> groupPrefix,
    Uint8List bound,
  ) {
    final decoded = MemComparableKey.decodeTuple(bound);
    if (decoded.isNotEmpty && decoded.last is Uint8List) {
      return <dynamic>[
        ...groupPrefix,
        ...decoded.sublist(0, decoded.length - 1),
        '\uffff',
      ];
    }
    return <dynamic>[...groupPrefix, ...decoded];
  }

  static bool _isDiskIndexFileUsable(IndexMeta meta) =>
      meta.totalEntryCount > 0 && !meta.btreeFirstLeaf.isNull;

  static Uint8List _upperBoundExclusiveForPrefix(Uint8List prefix) {
    final out = Uint8List(prefix.length + 1 + 4);
    out.setRange(0, prefix.length, prefix);
    out[prefix.length] = 0xFF;
    return out;
  }

  /// Shared TreeCache index-range scan for memory / pending / txn sources.
  ///
  /// Bounds are enforced with MemComparable-encoded keys inside [onEntry]
  /// (same semantics as the historical full-cache scan).
  ///
  /// Delete visibility is NOT applied here: pending/txn index trees already
  /// drop keys on delete. File/memory [base] hits are filtered in
  /// [_mergePendingTxnIndexKeys].
  Future<({List<IndexSearchEntry> entries, Uint8List? lastKey})>
      _scanTreeCacheIndexRange({
    required TreeCache<dynamic> cache,
    required List<dynamic> groupPrefix,
    required TableContext table,
    required IndexUid indexUid,
    required TableSchema schema,
    required Uint8List startKeyInclusive,
    required Uint8List endKeyExclusive,
    required bool reverse,
    required bool isUnique,
    int? limit,
    int? offset,
  }) async {
    List<dynamic>? rangeStart;
    List<dynamic>? rangeEnd;
    try {
      if (startKeyInclusive.isNotEmpty) {
        rangeStart = _nativeTreeCacheSeekKey(groupPrefix, startKeyInclusive);
      }
      if (endKeyExclusive.isNotEmpty) {
        rangeEnd = _nativeTreeCacheSeekKey(groupPrefix, endKeyExclusive);
      }
    } catch (_) {
      rangeStart = null;
      rangeEnd = null;
    }

    bool seekMatchesPrefix(List<dynamic>? seek) {
      if (seek == null) return true;
      if (seek.length < groupPrefix.length) return false;
      for (int i = 0; i < groupPrefix.length; i++) {
        if (seek[i] != groupPrefix[i]) return false;
      }
      return true;
    }

    if (!seekMatchesPrefix(rangeStart)) rangeStart = null;
    if (!seekMatchesPrefix(rangeEnd)) rangeEnd = null;

    final indexSchema = _findBtreeIndexSchema(schema, indexUid, table: table) ??
        IndexSchema(indexName: '', fields: const []);
    final fieldCount = indexSchema.fields.length;
    final truncateText = !isUnique;
    final need = limit ?? (1 << 30);

    final out = <IndexSearchEntry>[];
    var scannedCount = 0;
    Uint8List? lastKey;

    await cache.scanRange(
      rangeStart ?? groupPrefix,
      rangeEnd,
      reverse: reverse,
      onEntry: (key, val) {
        if (key.length < groupPrefix.length) return false;
        for (int i = 0; i < groupPrefix.length; i++) {
          if (key[i] != groupPrefix[i]) return false;
        }

        final keyValues = key.sublist(groupPrefix.length);
        if (fieldCount <= 0 || keyValues.length < fieldCount) return true;

        final comps = <Uint8List>[];
        for (int i = 0; i < fieldCount; i++) {
          final c = schema.encodeFieldComponentToMemComparable(
            indexSchema.fields[i],
            keyValues[i],
            truncateText: truncateText,
          );
          if (c == null) return true;
          comps.add(c);
        }
        if (!isUnique) {
          final pkRaw = keyValues.isNotEmpty ? keyValues.last : null;
          if (pkRaw != null) {
            comps.add(schema.encodePrimaryKeyComponent(pkRaw.toString()));
          }
        }
        if (comps.isEmpty) return true;
        final encodedKey = MemComparableKey.encodeTuple(comps);

        if (startKeyInclusive.isNotEmpty) {
          if (MemComparableKey.compare(encodedKey, startKeyInclusive) < 0) {
            return reverse ? false : true;
          }
        }
        if (endKeyExclusive.isNotEmpty) {
          if (MemComparableKey.compare(encodedKey, endKeyExclusive) >= 0) {
            return reverse ? true : false;
          }
        }

        lastKey = encodedKey;
        scannedCount++;
        if (offset != null && scannedCount <= offset) return true;

        String? pk;
        if (isUnique) {
          pk = val is String ? val : val?.toString();
        } else {
          pk = key.isNotEmpty ? key.last?.toString() : null;
        }
        if (pk == null || pk.isEmpty) return true;

        out.add(IndexSearchEntry(primaryKey: pk, keyBytes: encodedKey));
        return out.length < need;
      },
    );

    return (entries: out, lastKey: lastKey);
  }

  /// Memory-mode index scan based on [_indexDataCache].
  Future<IndexSearchResult> _scanIndexDataCacheRange({
    required TableContext table,
    required IndexUid indexUid,
    required Uint8List startKeyInclusive,
    required Uint8List endKeyExclusive,
    required bool reverse,
    required bool isUnique,
    int? limit,
    int? offset,
    required TableSchema schema,
  }) async {
    final scanned = await _scanTreeCacheIndexRange(
      cache: _indexDataCache,
      groupPrefix: <dynamic>[table.tableUid, indexUid],
      table: table,
      indexUid: indexUid,
      schema: schema,
      startKeyInclusive: startKeyInclusive,
      endKeyExclusive: endKeyExclusive,
      reverse: reverse,
      isUnique: isUnique,
      limit: limit,
      offset: offset,
    );
    return IndexSearchResult(
      primaryKeys: [for (final e in scanned.entries) e.primaryKey],
      entries: scanned.entries.isEmpty ? null : scanned.entries,
      lastKey: scanned.lastKey,
    );
  }

  Future<IndexSearchResult> _searchIndexByKeyRangeLogical({
    required TableContext table,
    required IndexUid indexUid,
    required IndexMeta meta,
    required Uint8List startKeyInclusive,
    required Uint8List endKeyExclusive,
    required bool reverse,
    int? limit,
    int? offset,
    bool readFromFileOnly = false,
    bool skipFileSource = false,
  }) async {
    final isMemoryMode =
        _dataStore.config.persistenceMode == PersistenceMode.memory;
    final IndexSearchResult base;
    if (skipFileSource && !isMemoryMode) {
      base = IndexSearchResult.empty();
    } else if (!isMemoryMode) {
      // Missing/empty disk meta means skip the file source only -- pending/txn
      // trees are still fused below.
      if (_isDiskIndexFileUsable(meta)) {
        base = await _dataStore.indexTreePartitionManager?.searchByKeyRange(
              table: table,
              indexUid: indexUid,
              meta: meta,
              startKeyInclusive: startKeyInclusive,
              endKeyExclusive: endKeyExclusive,
              reverse: reverse,
              limit: limit,
              offset: offset,
              readFromFileOnly: readFromFileOnly,
            ) ??
            IndexSearchResult.empty();
      } else {
        base = IndexSearchResult.empty();
      }
    } else {
      // Memory mode: index data cache is the primary index store.
      final schema =
          await _dataStore.tableMetaManager?.getTableSchema(table.tableUid);
      if (schema == null) return IndexSearchResult.tableScan();
      base = await _scanIndexDataCacheRange(
        table: table,
        indexUid: indexUid,
        startKeyInclusive: startKeyInclusive,
        endKeyExclusive: endKeyExclusive,
        reverse: reverse,
        isUnique: meta.isUnique,
        limit: limit,
        offset: offset,
        schema: schema,
      );
    }

    if (readFromFileOnly) return base;

    final schema =
        await _dataStore.tableMetaManager?.getTableSchema(table.tableUid);
    if (schema == null) return base;

    // Fuse pending (+ current txn) index TreeCaches with the same seek/limit
    // semantics as the memory index path -- never walk the index group from head
    // on every page.
    return _mergePendingTxnIndexKeys(
      table: table,
      indexUid: indexUid,
      meta: meta,
      schema: schema,
      base: base,
      reverse: reverse,
      limit: limit,
      offset: offset,
      startKeyInclusive: startKeyInclusive,
      endKeyExclusive: endKeyExclusive,
    );
  }

  /// Range-fuse pending/txn index trees with a file/memory [base] page.
  ///
  /// Delete overlay applies only to [base] (file/memory) hits: pending/txn
  /// index trees already remove keys on delete.
  Future<IndexSearchResult> _mergePendingTxnIndexKeys({
    required TableContext table,
    required IndexUid indexUid,
    required IndexMeta meta,
    required TableSchema schema,
    required IndexSearchResult base,
    required bool reverse,
    int? limit,
    int? offset,
    required Uint8List startKeyInclusive,
    required Uint8List endKeyExclusive,
  }) async {
    final trees = _dataStore.writeBufferManager.bufferTrees;
    final isUnique = meta.isUnique;
    final need = limit ?? (1 << 30);
    // Offset only when file base was empty (pending-only page). When base
    // already applied offset, pending scan must not skip again.
    final int? pendingOffset = base.isEmpty ? offset : null;

    Future<List<IndexSearchEntry>> scanBufferIndex(
      TreeCache<dynamic> cache,
      List<dynamic> groupPrefix,
    ) async {
      final scanned = await _scanTreeCacheIndexRange(
        cache: cache,
        groupPrefix: groupPrefix,
        table: table,
        indexUid: indexUid,
        schema: schema,
        startKeyInclusive: startKeyInclusive,
        endKeyExclusive: endKeyExclusive,
        reverse: reverse,
        isUnique: isUnique,
        limit: need,
        offset: pendingOffset,
      );
      return scanned.entries;
    }

    final pendingEntries = await scanBufferIndex(
      trees.pendingIndexCache,
      <dynamic>[table.tableUid, indexUid],
    );

    List<IndexSearchEntry> txnEntries = const [];
    final txId = TransactionContext.getCurrentTransactionId();
    if (txId != null && !TransactionContext.isApplyingCommit()) {
      txnEntries = await scanBufferIndex(
        trees.txnIndexCache,
        <dynamic>[txId, table.tableUid, indexUid],
      );
    }

    List<IndexSearchEntry> rawBaseEntries;
    if (base.entries != null && base.entries!.isNotEmpty) {
      rawBaseEntries = base.entries!;
    } else if (base.primaryKeys.isEmpty) {
      rawBaseEntries = const [];
    } else {
      // File path without keyBytes: keep relative order, merge as lowest priority.
      rawBaseEntries = [
        for (final pk in base.primaryKeys)
          IndexSearchEntry(primaryKey: pk, keyBytes: Uint8List(0)),
      ];
    }

    // File/memory hits: drop deletes and index keys invalidated by updates.
    final baseEntries = <IndexSearchEntry>[
      for (final e in rawBaseEntries)
        if (!_isFileIndexHitStaleUnderOverlay(
          table: table,
          meta: meta,
          schema: schema,
          pk: e.primaryKey,
          fileKeyBytes: e.keyBytes,
          startKeyInclusive: startKeyInclusive,
          endKeyExclusive: endKeyExclusive,
        ))
          e,
    ];

    if (pendingEntries.isEmpty && txnEntries.isEmpty) {
      if (baseEntries.length == rawBaseEntries.length) return base;
      return IndexSearchResult(
        primaryKeys: [for (final e in baseEntries) e.primaryKey],
        entries: baseEntries.isEmpty ? null : baseEntries,
        lastKey: baseEntries.isEmpty ? base.lastKey : baseEntries.last.keyBytes,
        requiresTableScan: base.requiresTableScan,
        indexWasUsed: base.indexWasUsed,
      );
    }

    final merged = _kWayMergeIndexEntries(
      sources: [txnEntries, pendingEntries, baseEntries],
      reverse: reverse,
      limit: need,
    );

    return IndexSearchResult(
      primaryKeys: [for (final e in merged) e.primaryKey],
      entries: merged,
      lastKey: merged.isEmpty ? base.lastKey : merged.last.keyBytes,
      requiresTableScan: base.requiresTableScan,
      indexWasUsed: base.indexWasUsed,
    );
  }

  /// When the disk index file source is unusable, decide empty / tableScan /
  /// or `null` to fall through and fuse pending/txn trees.
  ///
  /// Call only after [isBuilding] heal, and only when
  /// `!_isDiskIndexFileUsable(meta)`.
  ///
  /// Under parallel table+index flush, table meta may already show persisted
  /// rows while index meta is still empty; pending/txn overlays remain until
  /// cleanupAfterBatch, so prefer fuse over tableScan in that window.
  Future<IndexSearchResult?> _gateUnusableDiskIndexSearch({
    required TableContext table,
    required IndexUid indexUid,
    required TableSchema schema,
    required bool readFromFileOnly,
    required bool metaWasMissing,
  }) async {
    if (readFromFileOnly) {
      return IndexSearchResult.empty();
    }

    final hasPending =
        _dataStore.writeBufferManager.hasPendingWritesForUid(table.tableUid);
    final txId = TransactionContext.getCurrentTransactionId();
    final hasTxn = txId != null &&
        !TransactionContext.isApplyingCommit() &&
        _dataStore.tableDataManager.hasDeferredOps(txId);

    // Buffer/txn can still serve lookups while disk index meta catches up.
    if (hasPending || hasTxn) {
      return null;
    }

    final tableDataMeta =
        await _dataStore.tableDataManager.getTableDataMeta(table.tableUid);
    final persistedTableRecords = tableDataMeta?.totalRecordCount ?? 0;
    if (persistedTableRecords > 0) {
      // True inconsistency: persisted rows, empty index, no live overlay.
      if (!metaWasMissing) {
        Logger.warn(
          'Index ${table.tableName}.'
          '${_indexLogLabel(table, indexUid, schema: schema)} '
          'appears empty while table has $persistedTableRecords persisted '
          'records; falling back to table scan (rebuild only via schema '
          'migration or key migration)',
        );
      }
      return IndexSearchResult.tableScan();
    }

    if (metaWasMissing) {
      return IndexSearchResult.empty();
    }
    // Empty disk index + no persisted rows: fall through so pending/txn fuse
    // can serve unflushed inserts ("insert then query before flush").
    return null;
  }

  /// Synchronous peek at in-memory [IndexMeta] (never loads from disk).
  IndexMeta? peekIndexMeta(TableUid tableUid, IndexUid indexUid) {
    return _indexMetaCache.getPoint2(tableUid, indexUid);
  }

  /// Fast synchronous single unique key lookup to primary key string.
  ///
  /// Tier order: writeBuffer > hot index cache > B+Tree page cache.
  /// Never hits disk/IO; returns null when no in-memory tier has the mapping.
  String? lookupUniquePrimaryKeySync(
    TableContext table,
    IndexUid indexUid,
    dynamic value,
  ) {
    final schema = table.schema;
    if (schema.name.isEmpty || indexUid.isEmpty) return null;

    final bufferId = _probeBufferForUniqueIndex(table, indexUid, value);
    if (bufferId != null) {
      return bufferId;
    }

    final pkValue = _indexDataCache.getPoint3(table.tableUid, indexUid, value);
    if (pkValue is String && pkValue.isNotEmpty) {
      if (!_isPrimaryKeyHiddenByDeleteOverlay(table, pkValue)) {
        return pkValue;
      }
    }

    // Tier 2: B+Tree page cache (internal + leaf pages resident after flush)
    final indexSchema = _findBtreeIndexSchema(schema, indexUid, table: table);
    if (indexSchema == null || indexSchema.fields.isEmpty) return null;
    final encoded = schema.encodeFieldComponentToMemComparable(
      indexSchema.fields.first,
      value,
      truncateText: false,
    );
    if (encoded == null) return null;
    final tupleBytes = MemComparableKey.encodeTuple([encoded]);
    final pagePk = _dataStore.indexTreePartitionManager
        ?.lookupUniquePrimaryKeyFromPageCacheSync(
      table: table,
      indexUid: indexUid,
      uniqueKey: tupleBytes,
    );
    if (pagePk != null &&
        pagePk.isNotEmpty &&
        !_isPrimaryKeyHiddenByDeleteOverlay(table, pagePk)) {
      return pagePk;
    }
    return null;
  }

  /// Fast single unique key lookup to primary key string.
  /// Encodes value and delegates directly to _searchUniquePointLogical, returning matched PK.
  Future<String?> lookupUniquePrimaryKey(
    TableContext table,
    IndexUid indexUid,
    dynamic value, {
    bool readFromFileOnly = false,
  }) async {
    final schema = table.schema.name.isNotEmpty
        ? table.schema
        : await _dataStore.tableMetaManager?.getTableSchema(table.tableUid);
    if (schema == null || indexUid.isEmpty) return null;

    // 0. Probe writeBuffer & Hotspot Cache FIRST (bypasses getIndexMeta async IO on cache hit)
    if (!readFromFileOnly) {
      final bufferId = _probeBufferForUniqueIndex(table, indexUid, value);
      if (bufferId != null) {
        return bufferId;
      }

      final pkValue =
          _indexDataCache.getPoint3(table.tableUid, indexUid, value);
      if (pkValue is String && pkValue.isNotEmpty) {
        if (!_isPrimaryKeyHiddenByDeleteOverlay(table, pkValue)) {
          return pkValue;
        }
      }
    }

    final indexSchema = _findBtreeIndexSchema(schema, indexUid, table: table);
    if (indexSchema == null || indexSchema.fields.isEmpty) return null;

    final fieldName = indexSchema.fields.first;
    final encoded = schema.encodeFieldComponentToMemComparable(
      fieldName,
      value,
      truncateText: false,
    );
    if (encoded == null) return null;

    final tupleBytes = MemComparableKey.encodeTuple([encoded]);

    var meta = await getIndexMeta(table.tableUid, indexUid);
    meta ??= IndexMeta.createEmpty(
      indexUid: indexUid,
      tableUid: table.tableUid,
      isUnique: true,
    );

    final res = await _searchUniquePointLogical(
      table: table,
      indexUid: indexUid,
      meta: meta,
      schema: schema,
      encodedPrefix: tupleBytes,
      probeKey: value,
      nativeVal: [value],
      readFromFileOnly: readFromFileOnly,
    );

    if (res.primaryKeys.isNotEmpty) {
      return res.primaryKeys.first;
    }
    return null;
  }

  /// Unique point lookup: buffer probe → file point → pending/txn fuse only.
  ///
  /// After a file miss, does not re-scan the file source.
  Future<IndexSearchResult> _searchUniquePointLogical({
    required TableContext table,
    required IndexUid indexUid,
    required IndexMeta meta,
    required TableSchema schema,
    required Uint8List encodedPrefix,
    required dynamic probeKey,
    required List<dynamic> nativeVal,
    bool reverse = false,
    bool readFromFileOnly = false,
    bool populateHotspot = true,
  }) async {
    if (!readFromFileOnly) {
      final bufferId = _probeBufferForUniqueIndex(table, indexUid, probeKey);
      if (bufferId != null) {
        return IndexSearchResult(
          primaryKeys: <String>[bufferId],
          entries: [
            IndexSearchEntry(primaryKey: bufferId, keyBytes: encodedPrefix),
          ],
          indexWasUsed: true,
        );
      }
    }

    // 1. Hotspot / Memory Cache probe
    if (!readFromFileOnly) {
      final dynamic pkValue;
      if (nativeVal.length == 1) {
        pkValue = _indexDataCache.getPoint3(
            table.tableUid, indexUid, nativeVal.first);
      } else {
        final compositeKey = <dynamic>[table.tableUid, indexUid, ...nativeVal];
        pkValue = _indexDataCache.get(compositeKey);
      }
      if (pkValue is String && pkValue.isNotEmpty) {
        return IndexSearchResult(
          primaryKeys: <String>[pkValue],
          entries: [
            IndexSearchEntry(primaryKey: pkValue, keyBytes: encodedPrefix),
          ],
        );
      }
    }

    if (_dataStore.config.persistenceMode == PersistenceMode.memory) {
      return IndexSearchResult.empty();
    }

    if (_isDiskIndexFileUsable(meta)) {
      final pk = await _lookupUniquePrimaryKeyLogical(
        table: table,
        indexUid: indexUid,
        meta: meta,
        uniqueKey: encodedPrefix,
      );
      if (pk != null) {
        // File hit may be covered by delete, or an update that moved the key.
        if (_isFileIndexHitStaleUnderOverlay(
          table: table,
          meta: meta,
          schema: schema,
          pk: pk,
          fileKeyBytes: encodedPrefix,
          startKeyInclusive: encodedPrefix,
          endKeyExclusive: _upperBoundExclusiveForPrefix(encodedPrefix),
        )) {
          // Stale file owner: still try pending/txn fuse below.
        } else {
          // Never poison hotspot from file-only reads (no pending fuse context).
          // Populate off the query path (same pattern as row-cache disk warm).
          if (populateHotspot &&
              !readFromFileOnly &&
              !(_dataStore.resourceManager?.isLowMemoryMode ?? false)) {
            final cacheKey = <dynamic>[table.tableUid, indexUid, ...nativeVal];
            final tableCtx = table;
            final pkForCache = pk;
            scheduleMicrotask(() {
              final bufferEntry =
                  _dataStore.writeBufferManager.getBufferedRecordForRead(
                tableCtx,
                pkForCache,
              );
              if (bufferEntry == null) {
                _indexDataCache.put(cacheKey, pkForCache);
              }
            });
          }
          return IndexSearchResult(
            primaryKeys: <String>[pk],
            entries: [
              IndexSearchEntry(primaryKey: pk, keyBytes: encodedPrefix),
            ],
          );
        }
      }
    }

    if (readFromFileOnly) return IndexSearchResult.empty();

    // File already checked (or unusable): fuse pending/txn only.
    return _searchIndexByKeyRangeLogical(
      table: table,
      indexUid: indexUid,
      meta: meta,
      startKeyInclusive: encodedPrefix,
      endKeyExclusive: _upperBoundExclusiveForPrefix(encodedPrefix),
      reverse: reverse,
      limit: 1,
      offset: null,
      readFromFileOnly: false,
      skipFileSource: true,
    );
  }

  /// K-way merge of index entries by MemComparable keyBytes.
  /// Source order = priority on equal key (txn > pending > base).
  List<IndexSearchEntry> _kWayMergeIndexEntries({
    required List<List<IndexSearchEntry>> sources,
    required bool reverse,
    required int limit,
  }) {
    final idxs = List<int>.filled(sources.length, 0);
    final out = <IndexSearchEntry>[];
    final seenPk = <String>{};

    while (out.length < limit) {
      int bestSrc = -1;
      Uint8List? bestKey;
      for (int s = 0; s < sources.length; s++) {
        final list = sources[s];
        var i = idxs[s];
        while (i < list.length && seenPk.contains(list[i].primaryKey)) {
          i++;
          idxs[s] = i;
        }
        if (i >= list.length) continue;
        final key = list[i].keyBytes;
        if (bestSrc < 0) {
          bestSrc = s;
          bestKey = key;
          continue;
        }
        // Empty keyBytes (file without entries) sorts as "always after" real keys
        // when comparing -- treat as equal-priority append order via source index.
        int c;
        if (key.isEmpty && bestKey!.isEmpty) {
          c = 0;
        } else if (key.isEmpty) {
          c = 1;
        } else if (bestKey!.isEmpty) {
          c = -1;
        } else {
          c = MemComparableKey.compare(key, bestKey);
        }
        final better = reverse ? c > 0 : c < 0;
        if (better || (c == 0 && s < bestSrc)) {
          bestSrc = s;
          bestKey = key;
        }
      }
      if (bestSrc < 0) break;
      final entry = sources[bestSrc][idxs[bestSrc]];
      idxs[bestSrc]++;
      if (!seenPk.add(entry.primaryKey)) continue;
      out.add(entry);
    }
    return out;
  }

  Future<String?> _lookupUniquePrimaryKeyLogical({
    required TableContext table,
    required IndexUid indexUid,
    required IndexMeta meta,
    required Uint8List uniqueKey,
  }) async {
    final bool isMemoryMode =
        _dataStore.config.persistenceMode == PersistenceMode.memory;
    if (isMemoryMode) return null;
    return _dataStore.indexTreePartitionManager?.lookupUniquePrimaryKey(
      table: table,
      indexUid: indexUid,
      meta: meta,
      uniqueKey: uniqueKey,
    );
  }

  bool _isPrimaryKeyHiddenByDeleteOverlay(
    TableContext table,
    String? primaryKey, {
    String? transactionId,
  }) {
    if (primaryKey == null || primaryKey.isEmpty) return false;
    return _dataStore.tableDataManager.isRecordHiddenByDeleteOverlay(
      table,
      primaryKey,
      transactionId: transactionId,
    );
  }

  String? _effectiveOverlayTransactionId(String? transactionId) {
    final txId = transactionId ?? TransactionContext.getCurrentTransactionId();
    if (txId == null || TransactionContext.isApplyingCommit()) return null;
    return txId;
  }

  /// Whether a file/memory index hit is stale under pending/txn overlay.
  ///
  /// - delete → stale
  /// - update/insert → re-encode live index key; stale when it no longer matches
  ///   [fileKeyBytes] (or, when file key is empty, no longer falls in the query
  ///   range)
  /// - no overlay → not stale
  bool _isFileIndexHitStaleUnderOverlay({
    required TableContext table,
    required IndexMeta meta,
    required TableSchema schema,
    required String pk,
    required Uint8List fileKeyBytes,
    required Uint8List startKeyInclusive,
    required Uint8List endKeyExclusive,
    String? transactionId,
  }) {
    final overlay = _dataStore.writeBufferManager.bufferTrees.getVisibleRecord(
      table,
      pk,
      transactionId: _effectiveOverlayTransactionId(transactionId),
    );
    if (overlay == null) return false;
    if (overlay.operation == BufferOperationType.delete) return true;

    final liveKey = encodeIndexKeyFromRecord(
      schema: schema,
      meta: meta,
      record: overlay.data,
      pkValue: pk,
      table: table,
    );
    if (liveKey == null) return true;

    if (fileKeyBytes.isNotEmpty) {
      return MemComparableKey.compare(liveKey, fileKeyBytes) != 0;
    }
    if (startKeyInclusive.isNotEmpty &&
        MemComparableKey.compare(liveKey, startKeyInclusive) < 0) {
      return true;
    }
    if (endKeyExclusive.isNotEmpty &&
        MemComparableKey.compare(liveKey, endKeyExclusive) >= 0) {
      return true;
    }
    return false;
  }

  /// Disk unique-index owner [existingPk] still owns [uniqueKeyBytes] after overlay.
  ///
  /// Used by uniqueness checks: delete or key-changing update clears ownership.
  bool _uniqueDiskOwnerStillOwnsKey({
    required TableContext table,
    required IndexMeta meta,
    required TableSchema schema,
    required String existingPk,
    required Uint8List uniqueKeyBytes,
    String? transactionId,
  }) {
    final overlay = _dataStore.writeBufferManager.bufferTrees.getVisibleRecord(
      table,
      existingPk,
      transactionId: _effectiveOverlayTransactionId(transactionId),
    );
    if (overlay == null) return true;
    if (overlay.operation == BufferOperationType.delete) return false;

    final liveKey = encodeIndexKeyFromRecord(
      schema: schema,
      meta: meta,
      record: overlay.data,
      pkValue: existingPk,
      table: table,
    );
    if (liveKey == null) return false;
    return MemComparableKey.compare(liveKey, uniqueKeyBytes) == 0;
  }

  /// Whether an authoritative source currently owns a full index rebuild.
  ///
  /// Only [MigrationManager] (schema index rebuild) may set `isBuilding = true`.
  /// Key migration uses sync overwrite and does not take isBuilding ownership;
  /// [KeyMigrationRunner.isTableMigrating] still blocks clearing/query invent.
  /// Query / write paths must never invent isBuilding.
  bool isIndexBuildOwned(TableContext table, IndexUid indexUid) {
    final migrationMgr = _dataStore.migrationManager;
    if (migrationMgr != null &&
        table.tableUid.isNotEmpty &&
        migrationMgr.hasPendingIndexBuild(table.tableUid, indexUid)) {
      return true;
    }
    return KeyMigrationRunner.isTableMigrating(table);
  }

  /// Authority-only: begin a full index rebuild (delete artifacts + isBuilding).
  ///
  /// Callers: schema migration / key migration. Empty tables should not call
  /// this - leave meta absent; [writeChanges] synthesizes empty meta on demand.
  Future<void> beginIndexBuild(
    TableContext table,
    IndexSchema indexSchema,
  ) async {
    final indexUid = _indexUidFromSchema(indexSchema);
    if (indexUid.isEmpty) return;

    if (indexSchema.type == IndexType.vector) {
      await _dataStore.vectorIndexManager?.beginIndexBuild(table, indexSchema);
      return;
    }

    await deletePhysicalIndexArtifacts(table, indexUid);
    await updateIndexMeta(
      table: table,
      indexUid: indexUid,
      updatedMeta: IndexMeta.createEmpty(
        indexUid: indexUid,
        tableUid: table.tableUid,
        isUnique: indexSchema.unique,
        isBuilding: true,
      ),
    );
  }

  /// Authority-only: clear isBuilding after a owned rebuild completes or is aborted.
  Future<void> endIndexBuild(TableContext table, IndexUid indexUid) async {
    if (indexUid.isEmpty) return;
    final resolved = _resolveIndexUid(table, indexUid.value);
    final idxSchema = _dataStore.tableMetaManager
        ?.findIndexSchemaByUid(table.schema, resolved);
    if (idxSchema?.type == IndexType.vector) {
      await _dataStore.vectorIndexManager?.endIndexBuild(table, resolved);
      return;
    }

    await mutateIndexMeta(
      table,
      resolved,
      (current) {
        if (current == null || !current.isBuilding) return null;
        return current.copyWith(isBuilding: false);
      },
    );
  }

  /// Get index metadata by [indexUid].
  ///
  /// 1. Load by IndexUid only (cache / disk) - O(1) hot path.
  /// 2. Only when that returns empty: treat the token as indexName, resolve a
  ///    different uid, and load once more (legacy compat).
  Future<IndexMeta?> getIndexMeta(
    TableUid tableUid,
    IndexUid indexUid,
  ) async {
    if (indexUid.isEmpty) return null;

    final direct = await _loadIndexMetaCached(tableUid, indexUid);
    if (direct != null) return direct;

    final table = await _dataStore.tableMetaManager?.getTableContext(tableUid);
    if (table == null) return null;
    final resolved = _resolveIndexUidFromIndexName(table, indexUid.value);
    // Same uid -> the IndexUid path already missed; do not retry.
    if (resolved.isEmpty || resolved == indexUid) return null;
    return _loadIndexMetaCached(tableUid, resolved);
  }

  /// Cache-aware load by exact [indexUid] key (no legacy alias retry).
  Future<IndexMeta?> _loadIndexMetaCached(
    TableUid tableUid,
    IndexUid indexUid,
  ) async {
    final cached = _indexMetaCache.getPoint2(tableUid, indexUid);
    if (cached != null) {
      return cached;
    }

    final loadingKey = _getMetaLoadingKey(tableUid, indexUid);
    final existingFuture = _metaLoadingFutures[loadingKey];
    if (existingFuture != null) {
      return existingFuture;
    }

    final loadFuture = _doLoadIndexMeta(tableUid, indexUid);
    _metaLoadingFutures[loadingKey] = loadFuture;

    try {
      return await loadFuture;
    } finally {
      if (_metaLoadingFutures[loadingKey] == loadFuture) {
        _metaLoadingFutures.remove(loadingKey);
      }
    }
  }

  String _indexMetaLockResource(TableUid tableUid, IndexUid indexUid) =>
      'index_meta:$tableUid:${indexUid.value}';

  /// Read-modify-write under exclusive lock (see [mutateTableDataMeta]).
  ///
  /// Under the meta lock the index meta cache is authoritative; disk is only
  /// read on cache miss via [getIndexMeta].
  Future<IndexMeta?> mutateIndexMeta(
    TableContext table,
    IndexUid indexUid,
    FutureOr<IndexMeta?> Function(IndexMeta? current) mutator, {
    bool flush = true,
    bool persistToDisk = true,
    BatchContext? batchContext,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    final tableUid = table.tableUid;
    final lockResource = _indexMetaLockResource(tableUid, indexUid);
    final operationId = GlobalIdGenerator.generate('mutate_index_meta_');
    final lockMgr = _dataStore.lockManager;
    if (lockMgr == null) {
      final current = await getIndexMeta(tableUid, indexUid);
      final next = await mutator(current);
      if (next == null) return null;
      return _updateIndexMetaCore(
        table: table,
        indexUid: indexUid,
        meta: next,
        flush: flush,
        persistToDisk: persistToDisk,
        batchContext: batchContext,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
      );
    }

    final acquired =
        await lockMgr.acquireExclusiveLock(lockResource, operationId);
    if (!acquired) return null;
    try {
      final current = await getIndexMeta(tableUid, indexUid);
      final next = await mutator(current);
      if (next == null) return null;
      return _updateIndexMetaCore(
        table: table,
        indexUid: indexUid,
        meta: next,
        flush: flush,
        persistToDisk: persistToDisk,
        batchContext: batchContext,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
      );
    } finally {
      lockMgr.releaseExclusiveLock(lockResource, operationId);
    }
  }

  /// Layout [TableContext] for index meta page-0 IO (same bootstrap rule as table data).
  Future<TableContext?> _resolveTableContextForIndexMeta(
      TableUid tableUid) async {
    final mgr = _dataStore.tableMetaManager;
    if (mgr == null) return null;
    if (tableUid == SystemTable.tableMetaTableUid) {
      return mgr.bootstrapTableMetaContext();
    }
    final sync = mgr.getTableContextSync(tableUid);
    if (sync != null) return sync;
    return mgr.getTableContext(tableUid);
  }

  /// Internal method to perform the actual file load
  Future<IndexMeta?> _doLoadIndexMeta(
      TableUid tableUid, IndexUid indexUid) async {
    try {
      final bool isMemoryMode =
          _dataStore.config.persistenceMode == PersistenceMode.memory;

      final tableContext = await _resolveTableContextForIndexMeta(tableUid);
      if (tableContext == null) {
        return null;
      }

      final meta = await _dataStore.treeMetaPageService.readIndexGlobalMeta(
        tableContext,
        indexUid,
      );
      if (meta != null) {
        _indexMetaCache.putPoint2(tableUid, indexUid, meta);
        return meta;
      }

      if (!isMemoryMode) {
        return null;
      }

      // In pure memory mode, index metadata files may never be created on disk.
      // Synthesize an in-memory IndexMeta from the consolidated index list
      // (includes implicit indexes like TTL / foreign keys).
      try {
        final schema = tableContext.schema;
        final allIndexes = <IndexSchema>[
          ...?_dataStore.tableMetaManager?.getAllIndexesFor(schema),
          ...getEngineManagedBtreeIndexes(tableContext, schema),
        ];
        final idx = allIndexes.firstWhere(
          (i) => i.indexUid == indexUid || i.actualIndexName == indexUid,
          orElse: () => IndexSchema(indexName: '', fields: const []),
        );
        if (idx.fields.isNotEmpty) {
          final synthesized = IndexMeta.createEmpty(
            indexUid: indexUid,
            tableUid: tableUid,
            isUnique: idx.unique,
            isBuilding: false,
          );
          _indexMetaCache.putPoint2(tableUid, indexUid, synthesized);
          return synthesized;
        }
      } catch (_) {
        // Fallback: no meta available; let caller decide (usually tableScan).
      }
      return null;
    } catch (e) {
      Logger.error('Failed to get index metadata', rawError: e);
      return null;
    }
  }

  /// Unified index metadata update method
  /// @param tableName Table name
  /// @param indexName Index name
  /// @param updatedMeta Updated metadata
  /// @param acquireLock Whether to acquire lock (default is true)
  /// @param flush Whether to immediately flush to disk (default is true)
  /// @return Updated index metadata
  Future<IndexMeta?> updateIndexMeta({
    required TableContext table,
    required IndexUid indexUid,
    IndexMeta? updatedMeta,
    bool acquireLock = true,
    bool flush = true,
    bool persistToDisk = true,
    BatchContext? batchContext,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    final meta = updatedMeta;
    if (meta == null) return null;

    if (acquireLock) {
      return mutateIndexMeta(
        table,
        indexUid,
        (_) => meta,
        flush: flush,
        persistToDisk: persistToDisk,
        batchContext: batchContext,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
      );
    }

    return _updateIndexMetaCore(
      table: table,
      indexUid: indexUid,
      meta: meta,
      flush: flush,
      persistToDisk: persistToDisk,
      batchContext: batchContext,
      encryptionKey: encryptionKey,
      encryptionKeyId: encryptionKeyId,
    );
  }

  Future<IndexMeta?> _updateIndexMetaCore({
    required TableContext table,
    required IndexUid indexUid,
    required IndexMeta meta,
    bool flush = true,
    bool persistToDisk = true,
    BatchContext? batchContext,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    final tableUid = table.tableUid;
    final resolvedUid = meta.indexUid.isNotEmpty ? meta.indexUid : indexUid;

    try {
      if (persistToDisk) {
        await _dataStore.treeMetaPageService.persistIndexGlobalMeta(
          table: table,
          indexUid: resolvedUid,
          meta: meta,
          batchContext: batchContext,
          flush: flush,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
        );
      }

      _indexMetaCache.putPoint2(tableUid, resolvedUid, meta);
      return meta;
    } catch (e) {
      Logger.error('Failed to update index metadata', rawError: e);
      return null;
    }
  }

  /// Wipe all on-disk indexes for [table] after [DataStoreImpl.clear].
  ///
  /// [TableDataManager.clearTable] only removes the data partition directory;
  /// indexes live under `{table}/index/` and must be cleared separately.
  /// Deletes that root once (not per-index) and clears memory caches, then
  /// pre-seeds empty [IndexMeta] in memory (no disk write) so post-clear
  /// [getIndexMeta] / unique checks do not repeatedly [existsFile]-probe
  /// missing partition-0 paths. [writeChanges] still persists meta on first flush.
  Future<void> clearIndexesForTable(TableContext table) async {
    try {
      _dataStore.vectorIndexManager?.clearCacheForTable(table.tableUid);
      _indexMetaCache.remove([table.tableUid]);
      _indexDataCache.remove([table.tableUid]);
      _metaLoadingFutures
          .removeWhere((key, _) => key.startsWith('${table.tableUid}#'));
      _dataStore.indexTreePartitionManager?.clearPageCacheForTable(table);

      final indexDir = _dataStore.pathManager.getIndexDirPathByContext(table);
      if (await _dataStore.storage.existsDirectory(indexDir)) {
        await _dataStore.storage.deleteDirectory(indexDir);
      }

      // Pre-seed empty IndexMeta so subsequent unique/index lookups do not
      // existsFile-probe missing partition-0 files after clear.
      final schema = table.schema;
      final allIndexes = <IndexSchema>[
        ...?_dataStore.tableMetaManager?.getAllIndexesFor(schema),
        ...getEngineManagedBtreeIndexes(table, schema),
      ];
      for (final index in allIndexes) {
        final indexUid = _indexUidFromSchema(index);
        if (indexUid.isEmpty) continue;
        _indexMetaCache.putPoint2(
          table.tableUid,
          indexUid,
          IndexMeta.createEmpty(
            indexUid: indexUid,
            tableUid: table.tableUid,
            isUnique: index.unique,
            isBuilding: false,
          ),
        );
      }

      Logger.debug('Cleared index directory for table ${table.tableName}');
    } catch (e) {
      Logger.error(
        'Failed to clear indexes for ${table.tableName}',
        rawError: e,
      );
      rethrow;
    }
  }

  /// Check unique constraints
  /// Returns UniqueViolation if a conflict is found, null otherwise
  Future<UniqueViolation?> checkUniqueConstraints(
      TableContext table, Map<String, dynamic> data,
      {bool isUpdate = false,
      String? txId,
      TableSchema? schemaOverride,
      bool skipBufferCheck = false}) async {
    try {
      final schema = schemaOverride ??
          await _dataStore.tableMetaManager?.getTableSchema(table.tableUid);
      if (schema == null) {
        return null;
      }

      final primaryKey = schema.primaryKey;
      final primaryValue = data[primaryKey];

      final bool isMemoryMode =
          _dataStore.config.persistenceMode == PersistenceMode.memory;

      // Prepare write buffer overlay for fast-path uniqueness in current batch
      final writeBuf = _dataStore.writeBufferManager;
      final String? currentTxId =
          txId ?? TransactionContext.getCurrentTransactionId();

      dynamic valueForFields(List<String> fields) {
        if (fields.isEmpty) return null;
        if (fields.length == 1) return data[fields.first];
        final values = <dynamic>[];
        for (final f in fields) {
          final v = data[f];
          if (v == null) return null;
          values.add(v);
        }
        return values;
      }

      // Empty committed table: skip ALL disk unique I/O (PK + indexes).
      // Buffer reservation already covers unflushed conflicts. Hoisted before
      // existsPrimaryKey so first-install / pre-flush inserts do not repeatedly
      // existsFile-probe a missing partition-0 meta file.
      var skipDiskUniqueChecks = false;
      if (!isMemoryMode) {
        final tableDataMeta =
            await _dataStore.tableDataManager.getTableDataMeta(table.tableUid);
        skipDiskUniqueChecks =
            tableDataMeta == null || tableDataMeta.totalRecordCount <= 0;
      }

      // Online insert after tryReserveUniques uses skipBufferCheck=true.
      // With no committed rows there is nothing left to validate here.
      if (skipDiskUniqueChecks && skipBufferCheck && !isMemoryMode) {
        return null;
      }

      // 1. Consolidate all unique constraints to check.
      final constraints = <_UniqueConstraint>[];

      // Primary key uniqueness (only for inserts).
      // New architecture: no standalone pk index; validate via table range partition directly.
      if (!isUpdate && primaryValue != null) {
        final pkStr = primaryValue.toString();
        // 0) Fast-path: check pending in-memory reservations (buffer overlay)
        if (!skipBufferCheck) {
          try {
            final conflictId = writeBuf.hasUniqueKeyOwnedByOther(
              table,
              IndexUid('pk'),
              primaryValue,
              isUpdate ? pkStr : null,
              transactionId: currentTxId,
            );
            if (conflictId != null) {
              Logger.debug(
                "[Unique Constraint Violation] Table '${table.tableName}' Field(s) [$primaryKey] already contain value '$primaryValue'",
              );
              return UniqueViolation(
                tableName: table.tableName,
                fields: [primaryKey],
                value: primaryValue,
                indexName: IndexName('pk'),
                existingPrimaryKey: conflictId,
              );
            }
          } catch (_) {}
        }

        if (isMemoryMode) {
          // Memory mode: table TreeCache is the committed store.
          if (_dataStore.tableDataManager.hasLiveTableRecord(table, pkStr)) {
            return UniqueViolation(
              tableName: table.tableName,
              fields: [primaryKey],
              value: primaryValue,
              indexName: IndexName('pk'),
            );
          }
        } else if (!skipDiskUniqueChecks) {
          // 1) Persisted check: use tree-partitioned table data.
          try {
            final exists = await _dataStore.tableTreePartitionManager
                ?.existsPrimaryKey(table, pkStr);
            if (exists == true &&
                !_isPrimaryKeyHiddenByDeleteOverlay(
                  table,
                  pkStr,
                  transactionId: currentTxId,
                )) {
              Logger.debug(
                "[Unique Constraint Violation] Table '${table.tableName}' Field(s) [$primaryKey] already contain value '$primaryValue'",
              );
              return UniqueViolation(
                tableName: table.tableName,
                fields: [primaryKey],
                value: primaryValue,
                indexName: IndexName('pk'),
              );
            }
          } catch (e) {
            Logger.debug('Primary key unique check failed for pk=$pkStr',
                rawError: e);
            // Still treat as violation for safety, but with error info
            return UniqueViolation(
              tableName: table.tableName,
              fields: [primaryKey],
              value: primaryValue,
              indexName: IndexName('pk'),
            );
          }
        }
      }

      // Add all unique indexes from schema (single and composite)
      final allIndexes = _dataStore.tableMetaManager?.getAllIndexesFor(schema);
      if (allIndexes == null) return null;
      for (final index in allIndexes) {
        if (!index.unique) continue;
        final v = valueForFields(index.fields);
        if (v == null) continue;

        // Increment index weight for uniqueness check
        _dataStore.weightManager?.incrementAccess(
          WeightType.indexData,
          WeightManager.indexDataIdentifier(
            table.tableUid,
            _indexUidFromSchema(index),
          ),
          spaceName: _dataStore.currentSpaceName,
        );

        constraints.add(_UniqueConstraint(
          fields: index.fields,
          value: v,
          indexUid: _indexUidFromSchema(index),
          indexName: IndexName(index.actualIndexName),
          canonicalKey: schema.createCanonicalIndexKey(index.fields, data),
        ));
      }

      if (constraints.isEmpty) {
        return null;
      }

      String? selfStoreIndexStr;
      if (isUpdate && primaryValue != null) {
        selfStoreIndexStr = primaryValue.toString();
      }

      // Helper to check buffer for conflicts
      UniqueViolation? checkInBuffer(_UniqueConstraint constraint) {
        if (skipBufferCheck) return null;
        try {
          final compositeKey = constraint.canonicalKey;
          if (compositeKey != null) {
            final String? selfIdToIgnore =
                isUpdate ? primaryValue?.toString() : null;
            final conflictId = writeBuf.hasUniqueKeyOwnedByOther(
              table,
              constraint.indexUid,
              compositeKey,
              selfIdToIgnore,
              transactionId: currentTxId,
            );
            if (conflictId != null) {
              Logger.debug(
                  "[Unique Constraint Violation] Table '${table.tableName}' Field(s) [${constraint.fields.join(', ')}] already contain value '${constraint.value}' (buffer/reservation)");
              return UniqueViolation(
                tableName: table.tableName,
                fields: constraint.fields,
                value: constraint.value,
                indexName: constraint.indexName,
                existingPrimaryKey: conflictId,
              );
            }
          }
        } catch (_) {}
        return null;
      }

      // 2. Separate checks into fast-path (in-memory/buffer) and slow-path (disk/index).
      final constraintsToCheckOnDisk = <_UniqueConstraint>[];

      for (final constraint in constraints) {
        // Fast-path: check pending in-memory unique keys first
        final violation = checkInBuffer(constraint);
        if (violation != null) return violation;

        // If passed fast path, queue for disk check
        constraintsToCheckOnDisk.add(constraint);
      }

      if (constraintsToCheckOnDisk.isEmpty) return null;

      // Memory mode: validate against the committed in-memory index store and avoid any disk channel.
      if (isMemoryMode) {
        for (final c in constraintsToCheckOnDisk) {
          // Build native composite key: [table.tableUid, indexName, ...fieldValues]
          final dynamic v = c.value;
          final List<dynamic>? vals = (c.fields.length == 1)
              ? <dynamic>[v]
              : (v is List && v.length == c.fields.length ? v : null);
          if (vals == null) continue;

          final existing = vals.length == 1
              ? _indexDataCache.getPoint3(
                  table.tableUid, c.indexUid, vals.first)
              : _indexDataCache
                  .get(<dynamic>[table.tableUid, c.indexUid, ...vals]);
          if (existing is String && existing.isNotEmpty) {
            // Update: same record reusing its own unique value is OK.
            if (isUpdate &&
                selfStoreIndexStr != null &&
                existing == selfStoreIndexStr) {
              continue;
            }
            return UniqueViolation(
              tableName: table.tableName,
              fields: c.fields,
              value: c.value,
              indexName: c.indexName,
              existingPrimaryKey: existing,
            );
          }
        }
        return null;
      }

      // Empty on-disk table: buffer/reservation already checked; no index I/O.
      if (skipDiskUniqueChecks) {
        return null;
      }

      // 3. Execute disk checks using grouped B+Tree point lookups
      try {
        // Group constraints by stable index uid for batch processing
        final constraintsByIndex = <IndexUid, List<_UniqueConstraint>>{};
        for (final constraint in constraintsToCheckOnDisk) {
          constraintsByIndex
              .putIfAbsent(constraint.indexUid, () => [])
              .add(constraint);
        }

        // Check each index group
        for (final entry in constraintsByIndex.entries) {
          final indexUid = entry.key;
          final indexConstraints = entry.value;
          if (indexConstraints.isEmpty) continue;

          // Get index metadata
          final meta = await getIndexMeta(table.tableUid, indexUid);
          if (meta == null || meta.isBuilding || meta.totalEntryCount <= 0) {
            for (final constraint in indexConstraints) {
              final existingPk = await _findExistingPrimaryKeyByConstraint(
                table: table,
                schema: schema,
                fields: constraint.fields,
                value: constraint.value,
                excludePrimaryKey: selfStoreIndexStr,
              );
              if (existingPk != null) {
                return UniqueViolation(
                  tableName: table.tableName,
                  fields: constraint.fields,
                  value: constraint.value,
                  indexName: constraint.indexName,
                  existingPrimaryKey: existingPk,
                );
              }
            }
            continue;
          }

          // Encode all constraint values to MemComparable keys
          final keyBytes = <Uint8List>[];
          final constraintIndices = <int>[];
          for (int i = 0; i < indexConstraints.length; i++) {
            final constraint = indexConstraints[i];
            final comps = <Uint8List>[];
            bool ok = true;
            for (final f in constraint.fields) {
              final v = constraint.value;
              dynamic fieldVal;
              if (constraint.fields.length == 1) {
                fieldVal = v;
              } else if (v is List && v.length == constraint.fields.length) {
                fieldVal = v[constraint.fields.indexOf(f)];
              } else {
                ok = false;
                break;
              }
              final c = schema.encodeFieldComponentToMemComparable(
                f,
                fieldVal,
                truncateText: false,
              );
              if (c == null) {
                ok = false;
                break;
              }
              comps.add(c);
            }
            if (ok && comps.isNotEmpty) {
              keyBytes.add(MemComparableKey.encodeTuple(comps));
              constraintIndices.add(i);
            }
          }

          if (keyBytes.isEmpty) continue;

          // Single-pass disk lookup (existence + owner PK); avoids duplicate
          // B+Tree descent from existsUniqueKeysBatch + lookupUniquePrimaryKeysBatch.
          final existingPks = await _dataStore.indexTreePartitionManager
                  ?.lookupUniquePrimaryKeysBatch(
                table: table,
                indexUid: indexUid,
                meta: meta,
                uniqueKeys: keyBytes,
              ) ??
              <String?>[];

          // Check results
          for (int j = 0; j < constraintIndices.length; j++) {
            final constraintIdx = constraintIndices[j];
            if (constraintIdx < 0 || constraintIdx >= indexConstraints.length) {
              continue;
            }
            final constraint = indexConstraints[constraintIdx];
            final existingPk = j < existingPks.length ? existingPks[j] : null;

            if (existingPk == null || existingPk.isEmpty) {
              continue;
            }

            if (!_uniqueDiskOwnerStillOwnsKey(
              table: table,
              meta: meta,
              schema: schema,
              existingPk: existingPk,
              uniqueKeyBytes: keyBytes[j],
              transactionId: currentTxId,
            )) {
              continue;
            }

            if (isUpdate &&
                selfStoreIndexStr != null &&
                existingPk == selfStoreIndexStr) {
              continue;
            }

            Logger.debug(
                "[Unique Constraint Violation] Table '${table.tableName}' Field(s) [${constraint.fields.join(', ')}] already contain value '${constraint.value}' (disk check)");
            return UniqueViolation(
              tableName: table.tableName,
              fields: constraint.fields,
              value: constraint.value,
              indexName: constraint.indexName,
              existingPrimaryKey: existingPk,
            );
          }
        }
      } catch (e) {
        Logger.error('Batch unique constraint disk check failed', rawError: e);
        rethrow;
      }

      return null; // No violations found
    } catch (e) {
      Logger.error('Failed to check unique constraints', rawError: e);
      return UniqueViolation(
        tableName: table.tableName,
        fields: const [],
        value: null,
      );
    }
  }

  /// Batch unique check for INSERTs or UPDATEs.
  ///
  /// - For INSERT: Validates primary key and all unique indexes.
  /// - For UPDATE: Validates unique indexes ONLY if the indexed fields have changed.
  ///
  /// Check unique constraints across a batch of records.
  ///
  /// [records] The full merged records to check.
  /// [targetUniqueIndexes] Optional list of unique indexes to specifically check (e.g. only modified indexes during update).
  /// [changedFieldsList] Optional list of changed field sets directly aligned with [records] by index.
  /// If [isUpdate] is true, only indexes whose fields overlap with changed fields are checked.
  ///
  /// Returns a list aligned with [records], where each entry is either null (no violation)
  /// or a [UniqueViolation] describing the first detected conflict for that record.
  Future<List<UniqueViolation?>> checkUniqueConstraintsBatch(
      TableContext table, List<Map<String, dynamic>> records,
      {bool isUpdate = false,
      String? transactionId,
      TableSchema? schemaOverride,
      bool resolveInPlace = false,
      bool skipBufferCheck = false,

      /// When true, skip primary-key existence probes (safe for auto-generated
      /// sequential/timestamp PKs already reserved in the write buffer).
      bool skipPrimaryKeyCheck = false,
      List<IndexSchema>? targetUniqueIndexes,
      List<Set<String>?>? changedFieldsList}) async {
    if (records.isEmpty) return const <UniqueViolation?>[];

    final yieldController =
        YieldController('IndexManager.checkUniqueConstraintsBatch');

    final schema = schemaOverride ??
        await _dataStore.tableMetaManager?.getTableSchema(table.tableUid);
    if (schema == null) {
      return List<UniqueViolation?>.filled(records.length, null,
          growable: false);
    }

    final bool isMemoryMode =
        _dataStore.config.persistenceMode == PersistenceMode.memory;

    final primaryKey = schema.primaryKey;
    final String? txId =
        transactionId ?? TransactionContext.getCurrentTransactionId();
    final writeBuf = _dataStore.writeBufferManager;
    final violations =
        List<UniqueViolation?>.filled(records.length, null, growable: false);

    // 1) Primary key uniqueness (only for INSERTs with custom PKs).
    // Empty committed table: skip disk PK probes (buffer/intra-batch still run).
    var skipDiskUniqueChecks = false;
    if (!isMemoryMode) {
      final tableDataMeta =
          await _dataStore.tableDataManager.getTableDataMeta(table.tableUid);
      skipDiskUniqueChecks =
          tableDataMeta == null || tableDataMeta.totalRecordCount <= 0;
    }

    // Fast-path: check if minimum sequential PK strictly exceeds physical disk max key
    var bypassDiskPkCheck = skipDiskUniqueChecks;
    if (!bypassDiskPkCheck &&
        !isMemoryMode &&
        schema.primaryKeyConfig.type == PrimaryKeyType.sequential &&
        records.isNotEmpty) {
      try {
        final firstPkVal = records.first[primaryKey];
        if (firstPkVal != null) {
          final firstPkBytes =
              schema.encodePrimaryKeyComponent(firstPkVal.toString());
          final maxDiskKeyBytes = await _dataStore.tableTreePartitionManager
              ?.getPhysicalMaxPrimaryKeyBytes(table);
          if (maxDiskKeyBytes != null &&
              maxDiskKeyBytes.isNotEmpty &&
              MemComparableKey.compare(firstPkBytes, maxDiskKeyBytes) > 0) {
            bypassDiskPkCheck = true;
          }
        }
      } catch (_) {}
    }

    if (!isUpdate && !skipPrimaryKeyCheck) {
      final pkList = <String>[];
      final pkSeen = <String>{};

      for (int i = 0; i < records.length; i++) {
        final r = records[i];
        final y = yieldController.maybeYield();
        if (y != null) await y;
        final pkValue = r[primaryKey];
        if (pkValue != null) {
          final pk = pkValue.toString();
          if (pk.isEmpty) continue;

          // A) Intra-batch PK conflict
          if (pkSeen.contains(pk)) {
            violations[i] = UniqueViolation(
              tableName: table.tableName,
              fields: [primaryKey],
              value: pk,
              indexName: IndexName('pk'),
              existingPrimaryKey: pk,
            );
            if (resolveInPlace) {
              records[i][primaryKey] = pkValue;
            }
            continue;
          }
          pkSeen.add(pk);

          if (!bypassDiskPkCheck) {
            pkList.add(pk);
          }

          // B) WriteBuffer PK conflict
          if (!skipBufferCheck) {
            // Use raw pkValue for buffer check to ensure type matching (e.g. int vs String)
            final conflictId = writeBuf.hasUniqueKeyOwnedByOther(
              table,
              IndexUid('pk'),
              pkValue,
              isUpdate ? pk : null,
              transactionId: txId,
            );
            if (conflictId != null) {
              violations[i] = UniqueViolation(
                tableName: table.tableName,
                fields: [primaryKey],
                value: pk,
                indexName: IndexName('pk'),
                existingPrimaryKey: conflictId,
              );
              if (resolveInPlace) {
                records[i][primaryKey] = pkValue;
              }
            }
          }
        }
      }

      if (pkList.isNotEmpty && !bypassDiskPkCheck) {
        final Set<String> existing;
        if (isMemoryMode) {
          final set = <String>{};
          for (final pk in pkList) {
            final y = yieldController.maybeYield();
            if (y != null) await y;
            if (_dataStore.tableDataManager.hasLiveTableRecord(table, pk)) {
              set.add(pk);
            }
          }
          existing = set;
        } else {
          existing = await _dataStore.tableTreePartitionManager
                  ?.existingPrimaryKeysBatch(table, pkList) ??
              <String>{};
        }

        if (existing.isNotEmpty) {
          for (int i = 0; i < records.length; i++) {
            final y = yieldController.maybeYield();
            if (y != null) await y;
            if (violations[i] != null) continue;
            final pk = records[i][primaryKey]?.toString();
            if (pk == null || pk.isEmpty) continue;
            if (existing.contains(pk) &&
                !_isPrimaryKeyHiddenByDeleteOverlay(
                  table,
                  pk,
                  transactionId: txId,
                )) {
              violations[i] = UniqueViolation(
                tableName: table.tableName,
                fields: [primaryKey],
                value: pk,
                indexName: IndexName('pk'),
                existingPrimaryKey: pk,
              );
              if (resolveInPlace) {
                records[i][primaryKey] = pk;
              }
            }
          }
        }
      }
    }

    // 2) Unique indexes: only check targetUniqueIndexes if specified, otherwise all unique indexes.
    final uniqueIndexes = targetUniqueIndexes ??
        (_dataStore.tableMetaManager?.getUniqueIndexesFor(schema) ??
            const <IndexSchema>[]);
    if (uniqueIndexes.isEmpty) return violations;

    for (final idx in uniqueIndexes) {
      final indexUid = _indexUidFromSchema(idx);
      final indexLabel = IndexName(idx.actualIndexName);
      if (indexLabel.isEmpty) continue;

      final Map<dynamic, int> batchSeen = {};
      final List<Uint8List> keyBytesToLookup = [];
      final List<int> recordIdxsToLookup = [];
      final List<dynamic> canKeysToLookup = [];

      // Single-Pass Fused Pipeline per index
      for (int i = 0; i < records.length; i++) {
        final y = yieldController.maybeYield();
        if (y != null) await y;
        if (violations[i] != null) continue;

        // 1. If update, check if this index's fields changed in record i
        if (isUpdate &&
            changedFieldsList != null &&
            i < changedFieldsList.length) {
          final changed = changedFieldsList[i];
          if (changed != null && !idx.fields.any(changed.contains)) {
            continue; // Field not modified, skip checking this index for this record
          }
        }

        // 2. Pure synchronous canonical key extraction
        final r = records[i];
        final canKey = schema.createCanonicalIndexKey(idx.fields, r);
        if (canKey == null) continue;

        final recordId = r[primaryKey]?.toString();

        // 3. Intra-batch conflict check
        if (batchSeen.containsKey(canKey)) {
          final existingPk =
              records[batchSeen[canKey]!][primaryKey]?.toString();
          violations[i] = UniqueViolation(
            tableName: table.tableName,
            fields: idx.fields,
            value: canKey,
            indexName: indexLabel,
            existingPrimaryKey: existingPk,
          );
          if (resolveInPlace && existingPk != null) {
            records[i][primaryKey] = existingPk;
          }
          continue;
        }
        batchSeen[canKey] = i;

        // 4. WriteBuffer conflict check
        if (!skipBufferCheck) {
          final conflictId = writeBuf.hasUniqueKeyOwnedByOther(
            table,
            indexUid,
            canKey,
            isUpdate ? recordId : null,
            transactionId: txId,
          );
          if (conflictId != null) {
            violations[i] = UniqueViolation(
              tableName: table.tableName,
              fields: idx.fields,
              value: canKey,
              indexName: indexLabel,
              existingPrimaryKey: conflictId,
            );
            if (resolveInPlace) {
              records[i][primaryKey] = conflictId;
            }
            continue;
          }
        }

        // 5. Memory mode check
        if (isMemoryMode) {
          final vals = idx.fields.length == 1
              ? <dynamic>[canKey]
              : (canKey is List && canKey.length == idx.fields.length
                  ? List<dynamic>.from(canKey)
                  : null);
          if (vals != null) {
            final existingPk = vals.length == 1
                ? _indexDataCache.getPoint3(
                    table.tableUid, indexUid, vals.first)
                : _indexDataCache
                    .get(<dynamic>[table.tableUid, indexUid, ...vals]);
            if (existingPk is String &&
                existingPk.isNotEmpty &&
                existingPk != recordId) {
              violations[i] = UniqueViolation(
                tableName: table.tableName,
                fields: idx.fields,
                value: (idx.fields.length == 1) ? vals.first : vals,
                indexName: indexLabel,
                existingPrimaryKey: existingPk,
              );
              if (resolveInPlace) {
                records[i][primaryKey] = existingPk;
              }
            }
          }
          continue;
        }

        // 6. Disk path: Pure synchronous byte encoding for candidate
        if (!skipDiskUniqueChecks) {
          final encodedBytes =
              _encodeUniqueIndexKeyBytesPure(schema, idx, canKey);
          if (encodedBytes != null) {
            keyBytesToLookup.add(encodedBytes);
            recordIdxsToLookup.add(i);
            canKeysToLookup.add(canKey);
          }
        }
      }

      if (isMemoryMode || skipDiskUniqueChecks || keyBytesToLookup.isEmpty) {
        continue;
      }

      // Increment index weight for disk uniqueness check
      _dataStore.weightManager?.incrementAccess(
        WeightType.indexData,
        WeightManager.indexDataIdentifier(table.tableUid, indexUid),
        spaceName: _dataStore.currentSpaceName,
      );

      final meta = await getIndexMeta(table.tableUid, indexUid);
      if (meta == null || meta.isBuilding || meta.totalEntryCount <= 0) {
        for (int j = 0; j < recordIdxsToLookup.length; j++) {
          final i = recordIdxsToLookup[j];
          final y3 = yieldController.maybeYield();
          if (y3 != null) await y3;
          if (violations[i] != null) continue;
          final r = records[i];
          final recordId = r[primaryKey]?.toString();
          final canKey = canKeysToLookup[j];

          final existingPk = await _findExistingPrimaryKeyByConstraint(
            table: table,
            schema: schema,
            fields: idx.fields,
            value: canKey,
            excludePrimaryKey: recordId,
          );
          if (existingPk != null) {
            violations[i] = UniqueViolation(
              tableName: table.tableName,
              fields: idx.fields,
              value: canKey,
              indexName: indexLabel,
              existingPrimaryKey: existingPk,
            );
            if (resolveInPlace) {
              records[i][primaryKey] = existingPk;
            }
          }
        }
        continue;
      }

      final existingPks = await _dataStore.indexTreePartitionManager
              ?.lookupUniquePrimaryKeysBatch(
            table: table,
            indexUid: indexUid,
            meta: meta,
            uniqueKeys: keyBytesToLookup,
          ) ??
          <String?>[];

      for (int j = 0; j < recordIdxsToLookup.length; j++) {
        final i = recordIdxsToLookup[j];
        if (violations[i] != null) continue;

        final String? existingPk =
            j < existingPks.length ? existingPks[j] : null;

        if (existingPk == null || existingPk.isEmpty) continue;

        final recordId = records[i][primaryKey]?.toString();
        if (isUpdate && existingPk == recordId) continue;

        if (_uniqueDiskOwnerStillOwnsKey(
          table: table,
          meta: meta,
          schema: schema,
          existingPk: existingPk,
          uniqueKeyBytes: keyBytesToLookup[j],
          transactionId: txId,
        )) {
          final canKey = canKeysToLookup[j];
          violations[i] = UniqueViolation(
            tableName: table.tableName,
            fields: idx.fields,
            value: canKey,
            indexName: indexLabel,
            existingPrimaryKey: existingPk,
          );
          if (resolveInPlace) {
            records[i][primaryKey] = existingPk;
          }
        }
      }
    }

    return violations;
  }

  Future<String?> _findExistingPrimaryKeyByConstraint({
    required TableContext table,
    required TableSchema schema,
    required List<String> fields,
    required dynamic value,
    String? excludePrimaryKey,
  }) async {
    final condition = QueryCondition();
    if (fields.length == 1) {
      condition.where(fields.first, '=', value);
    } else if (value is List && value.length == fields.length) {
      for (int i = 0; i < fields.length; i++) {
        condition.where(fields[i], '=', value[i]);
      }
    } else {
      return null;
    }

    final records = (await _dataStore.queryExecutor.execute(
      table,
      condition: condition,
      limit: 2,
    ))
        .records;
    for (final record in records) {
      final pk = record[schema.primaryKey]?.toString();
      if (pk == null || pk.isEmpty) {
        continue;
      }
      if (excludePrimaryKey != null && pk == excludePrimaryKey) {
        continue;
      }
      return pk;
    }
    return null;
  }

  /// Remove index from table (schema + physical artifacts).
  ///
  /// Prefer [indexUid] for engine-internal calls. [indexName] and [fields]
  /// remain for logical-name / field-list matching.
  Future<void> removeIndex(
    TableContext table, {
    IndexUid? indexUid,
    IndexName? indexName,
    List<String>? fields,
  }) async {
    try {
      if ((indexUid == null || indexUid.isEmpty) &&
          (indexName == null || indexName.isEmpty) &&
          (fields == null || fields.isEmpty)) {
        throw DbException([
          InvalidArgumentStatus(
            type: ResultType.devInvalidArgumentMissing,
            message:
                'indexUid, index name, or field list is required for removeIndex',
            parameterName: 'indexUid/indexName/fields',
            passedValue:
                'indexUid=$indexUid, indexName=$indexName, fields=$fields',
          ),
        ]);
      }

      final schemaMgr = _dataStore.tableMetaManager;
      final schema = await schemaMgr?.getTableSchema(table.tableUid);
      if (schema == null) {
        Logger.warn(
            'table ${table.tableName} does not exist, cannot remove index');
        return;
      }

      final allIndexes = schemaMgr?.getAllIndexesFor(schema);
      if (allIndexes == null) return;

      IndexSchema? targetIndex;

      // 1. match by stable uid
      if (indexUid != null && indexUid.isNotEmpty) {
        targetIndex = schemaMgr?.findIndexSchemaByUid(schema, indexUid);
      }

      // 2. match by logical / physical name
      if (targetIndex == null && indexName != null && indexName.isNotEmpty) {
        final name = indexName.value;
        for (var index in allIndexes) {
          if (index.indexName == name || index.actualIndexName == name) {
            targetIndex = index;
            break;
          }
        }

        if (targetIndex == null) {
          final autoGenPattern = RegExp(r'^' + table.tableName + r'_\w+');
          if (autoGenPattern.hasMatch(name)) {
            for (var index in allIndexes) {
              if (index.actualIndexName == name) {
                targetIndex = index;
                break;
              }
            }
          }
        }
      }

      // 3. match by fields list
      if (targetIndex == null && fields != null && fields.isNotEmpty) {
        for (var index in allIndexes) {
          if (_areFieldListsEqual(index.fields, fields)) {
            targetIndex = index;
            break;
          }
        }
      }

      String? actualName;
      if (targetIndex != null) {
        actualName = targetIndex.actualIndexName;
      } else if (indexName != null && indexName.isNotEmpty) {
        actualName = indexName.value;
      } else if (indexUid != null && indexUid.isNotEmpty) {
        actualName = indexUid.value;
      } else {
        return;
      }

      final resolvedIndexUid =
          targetIndex != null && targetIndex.indexUid.isNotEmpty
              ? targetIndex.indexUid
              : (indexUid != null && indexUid.isNotEmpty
                  ? indexUid
                  : _resolveIndexUid(table, actualName, schema: schema));
      if (resolvedIndexUid.isEmpty) return;

      final lockMgr = _dataStore.lockManager;
      final indexLockKey = _indexLockKey(table.tableUid, resolvedIndexUid);
      final indexLockOpId = GlobalIdGenerator.generate('remove_index_');
      bool indexLocked = false;

      try {
        if (lockMgr != null) {
          indexLocked = await lockMgr.acquireExclusiveLock(
            indexLockKey,
            indexLockOpId,
          );
          if (!indexLocked) {
            throw DbException([
              GeneralStatus(
                type: ResultType.sysTimeoutLockAcquisition,
                message:
                    'Failed to acquire lock for removing index ${table.tableName}.$actualName',
              ),
            ]);
          }
        }

        await deletePhysicalIndexArtifacts(table, resolvedIndexUid);

        // if target index is found, remove it from table schema
        if (targetIndex != null) {
          final newIndexes =
              schema.indexes.where((i) => i != targetIndex).toList();
          final newSchema = schema.copyWith(indexes: newIndexes);

          // update table schema
          await schemaMgr!.updateTableMeta(
            table.tableUid,
            schema: newSchema,
          );
        }
      } finally {
        if (indexLocked && lockMgr != null) {
          lockMgr.releaseExclusiveLock(indexLockKey, indexLockOpId);
        }
      }
    } catch (e) {
      Logger.error('Failed to remove index', rawError: e);
      rethrow;
    }
  }

  /// Delete index files/metadata without changing table schema.
  ///
  /// Migration schema cutover already persisted the target schema. During the
  /// async physical reconciliation phase we may still need to delete stale
  /// index artifacts, but must not remove indexes from that target schema.
  Future<void> deleteIndexArtifactsForMigration(
    TableContext table, {
    required IndexUid indexUid,
  }) async {
    final lockMgr = _dataStore.lockManager;
    final indexLockKey = _indexLockKey(table.tableUid, indexUid);
    final indexLockOpId = GlobalIdGenerator.generate('delete_index_artifacts_');
    var indexLocked = false;

    try {
      if (lockMgr != null) {
        indexLocked = await lockMgr.acquireExclusiveLock(
          indexLockKey,
          indexLockOpId,
        );
        if (!indexLocked) {
          throw DbException([
            GeneralStatus(
              type: ResultType.sysTimeoutLockAcquisition,
              message:
                  'Failed to acquire lock for deleting index artifacts ${table.tableName}.${_indexLogLabel(table, indexUid)}',
            ),
          ]);
        }
      }

      await deletePhysicalIndexArtifacts(table, indexUid);
    } catch (e) {
      Logger.error('Failed to delete index artifacts for migration',
          rawError: e);
      rethrow;
    } finally {
      if (indexLocked && lockMgr != null) {
        lockMgr.releaseExclusiveLock(indexLockKey, indexLockOpId);
      }
    }
  }

  /// Reconcile physical artifacts after a logical index rename.
  ///
  /// [IndexUid] and B+Tree [IndexMeta] are unchanged; schema cutover already
  /// updated logical names via [MigrationType.renameIndex]. This method only
  /// moves pre-uid on-disk directories (keyed by [legacyLogicalName]) once.
  Future<void> reconcileIndexAfterLogicalRename(
    TableContext table, {
    required IndexUid indexUid,
    required String legacyLogicalName,
  }) async {
    if (indexUid.isEmpty) return;

    final lockMgr = _dataStore.lockManager;
    final lockOpId = GlobalIdGenerator.generate('reconcile_index_');
    final lockKey = _indexLockKey(table.tableUid, indexUid);
    var indexLocked = false;

    try {
      if (lockMgr != null) {
        indexLocked = await lockMgr.acquireExclusiveLock(lockKey, lockOpId);
        if (!indexLocked) {
          throw DbException([
            GeneralStatus(
              type: ResultType.sysTimeoutLockAcquisition,
              message:
                  'Failed to acquire lock for index reconciliation ${table.tableName}.${_indexLogLabel(table, indexUid)}',
            ),
          ]);
        }
      }

      await _dataStore.flush();
      _invalidateIndexCache(table, indexUid);
      _dataStore.vectorIndexManager
          ?.clearCacheForIndex(table.tableUid, indexUid);

      await ensureStableIndexLayoutOnLoad(
        table,
        indexUid: indexUid,
        legacyLogicalName: legacyLogicalName,
      );
    } catch (e) {
      Logger.error('Failed to reconcile index after logical rename',
          rawError: e);
      rethrow;
    } finally {
      if (indexLocked && lockMgr != null) {
        lockMgr.releaseExclusiveLock(lockKey, lockOpId);
      }
    }
  }

  /// One-time layout fix when opening an index with pre-uid on-disk paths.
  Future<void> ensureStableIndexLayoutOnLoad(
    TableContext table, {
    required IndexUid indexUid,
    required String legacyLogicalName,
  }) async {
    if (indexUid.isEmpty || legacyLogicalName.isEmpty) return;
    await _migrateLegacyIndexDirectoryIfNeeded(
      table,
      indexUid: indexUid,
      legacyLogicalName: legacyLogicalName,
    );
  }

  /// One-time migration: move index tree from pre-uid logical path to [indexUid].
  Future<void> _migrateLegacyIndexDirectoryIfNeeded(
    TableContext table, {
    required IndexUid indexUid,
    required String legacyLogicalName,
  }) async {
    if (legacyLogicalName.isEmpty || legacyLogicalName == indexUid.value) {
      return;
    }

    final stablePath =
        _dataStore.pathManager.getIndexPathByContext(table, indexUid);
    final legacyPath = _dataStore.pathManager
        .getIndexPathByContext(table, IndexUid(legacyLogicalName));
    if (legacyPath == stablePath) return;

    final legacyExists = await _dataStore.storage.existsDirectory(legacyPath);
    if (!legacyExists) return;

    final stableExists = await _dataStore.storage.existsDirectory(stablePath);
    if (stableExists) {
      // Stable layout already present; drop orphaned legacy tree.
      await _dataStore.storage.deleteDirectory(legacyPath);
      return;
    }

    await _dataStore.storage.moveDirectory(legacyPath, stablePath);
  }

  /// Compare two field lists with order preserved.
  bool _areFieldListsEqual(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Public wrapper to delete physical index files and clear cache.
  Future<void> deletePhysicalIndexArtifacts(
    TableContext table,
    IndexUid indexUid,
  ) async {
    if (indexUid.isEmpty) return;
    final resolved = _resolveIndexUid(table, indexUid.value);

    // Subtract from SpaceStats before deleting artifacts (O(1) via cached meta).
    try {
      final indexSchema = _dataStore.tableMetaManager
          ?.findIndexSchemaByUid(table.schema, resolved);
      if (indexSchema?.type == IndexType.vector) {
        final ngh = await _dataStore.vectorIndexManager
            ?.getNghIndexMeta(table, resolved);
        if (ngh != null) {
          _dataStore.tableDataManager.applyIndexOccupancyDelta(
            table,
            sizeDelta: -ngh.totalSizeBytes,
            entryDelta: -ngh.totalVectors,
          );
        }
      } else {
        final meta = await getIndexMeta(table.tableUid, resolved);
        if (meta != null) {
          _dataStore.tableDataManager.applyIndexOccupancyDelta(
            table,
            sizeDelta: -meta.totalSizeBytes,
            entryDelta: -meta.totalEntryCount,
          );
        }
      }
    } catch (e) {
      Logger.warn(
          'Failed to adjust space index size for ${table.tableName}.${_indexLogLabel(table, resolved)}',
          rawError: e);
    }

    _invalidateIndexCache(table, resolved);

    try {
      final indexSchema = _dataStore.tableMetaManager
          ?.findIndexSchemaByUid(table.schema, resolved);
      if (indexSchema?.type == IndexType.vector) {
        await _dataStore.vectorIndexManager
            ?.deletePhysicalIndexArtifacts(table, resolved);
      } else {
        final indexPath = _dataStore.pathManager.getIndexPathByContext(
          table,
          resolved,
        );
        if (await _dataStore.storage.existsDirectory(indexPath)) {
          await _dataStore.storage.deleteDirectory(indexPath);
        }
      }
    } catch (e) {
      Logger.warn(
          'Failed to clean index artifacts for ${table.tableName}.${_indexLogLabel(table, resolved)}',
          rawError: e);
    }
  }

  /// Helper to encode index key from record.
  ///
  /// B+Tree keys remain memcomparable field tuples - [indexUid] selects which
  /// index tree to write, not what goes into [MemComparableKey.encodeTuple].
  Uint8List? encodeIndexKeyFromRecord({
    required TableSchema schema,
    required IndexMeta meta,
    required Map<String, dynamic> record,
    required String pkValue,
    TableContext? table,
  }) {
    final indexSchema = table != null
        ? _findBtreeIndexSchema(schema, meta.indexUid, table: table)
        : _dataStore.tableMetaManager
            ?.findIndexSchemaByUid(schema, meta.indexUid);
    if (indexSchema == null || indexSchema.fields.isEmpty) return null;
    final fields = indexSchema.fields;
    final isUnique = meta.isUnique;
    final truncateText = !isUnique;
    final comps = <Uint8List>[];
    for (final f in fields) {
      final v = record[f];
      final c = schema.encodeFieldComponentToMemComparable(
        f,
        v,
        truncateText: truncateText,
      );
      if (c == null) return null;
      comps.add(c);
    }
    if (!isUnique) {
      comps.add(schema.encodePrimaryKeyComponent(pkValue));
    }
    return MemComparableKey.encodeTuple(comps);
  }

  /// Write index changes (inserts, updates, deletes) to index partition files
  ///
  /// [skipIndexes] - Optional set of index uids to skip processing.
  /// Used during recovery to skip indexes that have already been fully flushed.
  Future<void> writeChanges({
    required TableContext table,
    List<Map<String, dynamic>> inserts = const [],
    List<IndexRecordUpdate> updates = const [],
    List<Map<String, dynamic>> deletes = const [],
    BatchContext? batchContext,
    int? concurrency,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    Set<IndexUid>? skipIndexes,
    TableSchema? schemaOverride,
    List<IndexSchema>? targetIndexesOverride,
  }) async {
    final schema = schemaOverride ??
        await _dataStore.tableMetaManager?.getTableSchema(table.tableUid);
    if (schema == null) return;
    final pkName = schema.primaryKey;

    // Build index targets: explicit indexes + auto-unique single-field + foreign keys (excluding PK).
    final targets = List<IndexSchema>.from(
      targetIndexesOverride ??
          <IndexSchema>[
            ...?_dataStore.tableMetaManager?.getAllIndexesFor(schema),
            ...getEngineManagedBtreeIndexes(table, schema),
          ],
    );

    // Skip redundant PK-only indexes (table data is already range-partitioned by PK).
    targets
        .removeWhere((i) => i.fields.length == 1 && i.fields.first == pkName);
    if (targets.isEmpty) return;

    // Single pass: split vector vs B+Tree indexes, count B+Tree for budget.
    final vectorTargets = <IndexSchema>[];
    final btreeTargets = <IndexSchema>[];
    for (final idx in targets) {
      if (idx.type == IndexType.vector) {
        vectorTargets.add(idx);
      } else {
        btreeTargets.add(idx);
      }
    }

    final Future<void>? vectorFuture =
        vectorTargets.isNotEmpty && _dataStore.vectorIndexManager != null
            ? _dataStore.vectorIndexManager!.writeChanges(
                table: table,
                inserts: inserts,
                deletes: deletes,
                batchContext: batchContext,
                concurrency: concurrency,
                schemaOverride: schema,
                targetIndexesOverride: vectorTargets,
              )
            : null;

    if (btreeTargets.isEmpty) {
      if (vectorFuture != null) await vectorFuture;
      return;
    }

    final yieldController =
        YieldController('IndexManager.writeChanges.indexes', checkInterval: 1);

    for (final idx in btreeTargets) {
      final yIdx = yieldController.maybeYield();
      if (yIdx != null) await yIdx;

      final indexUid = _indexUidFromSchema(idx);
      final indexName = idx.actualIndexName;
      // Skip indexes that are already fully flushed (used during recovery)
      if (skipIndexes != null && skipIndexes.contains(indexUid)) {
        continue;
      }

      final tableUid = table.tableUid;
      var meta = await getIndexMeta(table.tableUid, indexUid);
      // If index metadata doesn't exist, create it in memory only (avoid extra IO)
      if (meta == null) {
        meta = IndexMeta.createEmpty(
          indexUid: indexUid,
          tableUid: tableUid,
          isUnique: idx.unique,
          isBuilding: false,
        );
        // Only cache in memory, don't write to file yet to avoid extra IO
        _indexMetaCache.putPoint2(tableUid, indexUid, meta);
      }

      final bool isUnique = meta.isUnique;
      final fields = idx.fields;

      // Internal TTL virtual index: single-field index on `_system_ingest_ts_ms`
      // when table-level TTL uses the internal ingest-time source (sourceField == null/empty).
      // Internal TTL index is only written on INSERT; UPDATE/DELETE skips it.
      final bool usesInternalTtlSource = schema.ttlConfig != null &&
          (schema.ttlConfig!.sourceField == null ||
              schema.ttlConfig!.sourceField!.isEmpty);
      final bool isInternalTtlIndex = usesInternalTtlSource &&
          fields.length == 1 &&
          fields.first == TableSchema.internalTtlIngestTsMsField;
      final bool isInternalKvExpiryIndex =
          _isInternalKvExpiryIndex(table, indexUid);

      // Per-index, per-batch ingest timestamp for internal TTL index INSERTs.
      final String? batchIngestIso =
          isInternalTtlIndex ? DateTime.now().toIso8601String() : null;
      final deltas = await _prepareIndexWriteDeltasBatch(
        schema: schema,
        table: table,
        indexName: indexName,
        primaryKeyField: pkName,
        fields: fields,
        isUnique: isUnique,
        isInternalKvExpiryIndex: isInternalKvExpiryIndex,
        isInternalTtlIndex: isInternalTtlIndex,
        batchIngestIso: batchIngestIso,
        inserts: inserts,
        deletes: deletes,
        updates: updates,
      );

      if (deltas.isEmpty) {
        continue;
      }
      await _dataStore.indexTreePartitionManager?.writeChanges(
        table: table,
        indexUid: indexUid,
        indexMeta: meta,
        deltas: deltas,
        batchContext: batchContext,
        concurrency: concurrency,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
      );
    }

    // Await vector index write that was dispatched in parallel with B+Tree tasks.
    if (vectorFuture != null) await vectorFuture;
  }

  /// Probe the WriteBuffer for a specific unique key.
  /// Returns the record ID if found, null otherwise.
  String? _probeBufferForUniqueIndex(
    TableContext table,
    IndexUid indexUid,
    dynamic compositeKey,
  ) {
    final writeBuf = _dataStore.writeBufferManager;
    final currentTxId = TransactionContext.getCurrentTransactionId();

    // The buffer manager keeps a specialized index for unique keys
    // to prevent intra-batch conflicts. We can leverage it for fast lookups.
    return writeBuf.hasUniqueKeyOwnedByOther(
      table,
      indexUid,
      compositeKey,
      null, // Passing null as selfRecordId to find ANY owner
      transactionId: currentTxId,
    );
  }

  /// Searches an index using a structured condition, with optimizations for performance and memory.
  ///
  /// This method intelligently decides whether to load an entire index into memory
  /// or search it partition by partition based on the index size and query type.
  /// It supports equality and range queries with an optional limit to control result size.
  ///
  /// @param tableName The name of the table.
  /// @param indexUid Stable index uid to search.
  /// @param condition The structured IndexCondition for the search.
  /// @param limit An optional limit on the number of records to return.
  /// @param offset An optional offset to skip the first N records.
  /// @param startAfterKey Optional: keyset cursor (exclusive) for the index key bytes.
  /// @param reverse When true, scan in descending index-key order.
  /// @param orderBy An optional list of fields to order by.
  /// @param bypassCache When true, skip in-memory index caches (safer for large-range scans).
  /// @return An IndexSearchResult containing the pointers to matching records.
  Future<IndexSearchResult> searchIndex(
    TableContext table,
    IndexUid indexUid,
    IndexCondition condition, {
    int? limit,
    int? offset,
    Uint8List? startAfterKey,
    bool reverse = false,
    List<String>? orderBy,
    bool readFromFileOnly = false,
  }) async {
    final schema = table.schema.name.isNotEmpty
        ? table.schema
        : await _dataStore.tableMetaManager?.getTableSchema(table.tableUid);
    if (schema == null) return IndexSearchResult.tableScan();
    if (indexUid.isEmpty) return IndexSearchResult.tableScan();

    // Increment index access weight for caching optimization
    if (!readFromFileOnly) {
      _dataStore.weightManager?.incrementAccess(
        WeightType.indexData,
        WeightManager.indexDataIdentifier(table.tableUid, indexUid),
        spaceName: _dataStore.currentSpaceName,
      );
    }
    try {
      final indexSchema = _findBtreeIndexSchema(schema, indexUid, table: table);
      if (indexSchema == null || indexSchema.fields.isEmpty) {
        return IndexSearchResult.tableScan();
      }

      var meta = await getIndexMeta(table.tableUid, indexUid);
      final bool isMemoryMode =
          _dataStore.config.persistenceMode == PersistenceMode.memory;
      final bool metaWasMissing = meta == null;

      // Disk index meta missing: use an empty shell so pending/txn fuse can run.
      // Gate (empty / tableScan / fall-through) runs after isBuilding heal.
      meta ??= IndexMeta.createEmpty(
        indexUid: indexUid,
        tableUid: table.tableUid,
        isUnique: indexSchema.unique,
      );

      if (!isMemoryMode && meta.isBuilding) {
        if (isIndexBuildOwned(table, indexUid)) {
          return IndexSearchResult.tableScan();
        }
        // Heal sticky isBuilding left by crashed non-authority writers.
        Logger.warn(
          'Clearing orphan isBuilding for ${table.tableName}.'
          '${_indexLogLabel(table, indexUid, schema: schema)} '
          '(no schema/key migration owns this rebuild)',
        );
        await endIndexBuild(table, indexUid);
        meta = (await getIndexMeta(table.tableUid, indexUid)) ??
            meta.copyWith(isBuilding: false);
      }
      // In memory mode, the primary index store is [_indexDataCache], so B+Tree
      // pointers/entry counts may be unset or stale. We still allow searching.
      if (!isMemoryMode && !_isDiskIndexFileUsable(meta)) {
        final gated = await _gateUnusableDiskIndexSearch(
          table: table,
          indexUid: indexUid,
          schema: schema,
          readFromFileOnly: readFromFileOnly,
          metaWasMissing: metaWasMissing,
        );
        if (gated != null) return gated;
      }

      Uint8List upperBoundExclusiveForPrefix(Uint8List prefix) =>
          _upperBoundExclusiveForPrefix(prefix);

      final fields = indexSchema.fields;
      final bool isUnique = meta.isUnique;
      final bool truncateText = !isUnique;

      List<dynamic>? normalizeValues(dynamic v, int n) {
        if (n <= 0) return const [];
        if (v is List && v.length == n) return v;
        if (n == 1) return <dynamic>[v];
        return null;
      }

      Uint8List? encodeLeadingValues(List<dynamic> vals) {
        final comps = <Uint8List>[];
        for (int i = 0; i < vals.length; i++) {
          final c = schema.encodeFieldComponentToMemComparable(
            fields[i],
            vals[i],
            truncateText: truncateText,
          );
          if (c == null) return null;
          comps.add(c);
        }
        return MemComparableKey.encodeTuple(comps);
      }

      Uint8List? encodePrefix(dynamic raw) {
        final vals = normalizeValues(raw, fields.length);
        if (vals == null) return null;
        return encodeLeadingValues(vals);
      }

      // Cursor Logic
      final bool hasCursorKey =
          startAfterKey != null && startAfterKey.isNotEmpty;

      // Local helper for nextKey (exclusive -> inclusive switch)
      Uint8List nextKey(Uint8List key) {
        final out = Uint8List(key.length + 1);
        out.setAll(0, key);
        out[key.length] = 0;
        return out;
      }

      final int? effectiveOffset = hasCursorKey ? null : offset;

      // Helper to apply cursor lower bound (Forward scan start)
      Uint8List applyCursorStart(Uint8List originalStart) {
        if (!hasCursorKey) return originalStart;
        if (reverse) return originalStart; // Reverse uses cursor as end bound

        // We want strictly AFTER cursor.
        // startInclusive = nextKey(cursor).
        // If cursor >= originalStart, we need to bump originalStart to cursor+1.
        final cursorNext = nextKey(startAfterKey);
        if (originalStart.isEmpty ||
            MemComparableKey.compare(cursorNext, originalStart) > 0) {
          return cursorNext;
        }
        return originalStart;
      }

      // Helper to apply cursor upper bound (Reverse scan end)
      Uint8List applyCursorEnd(Uint8List originalEnd) {
        if (!hasCursorKey) return originalEnd;
        if (!reverse) return originalEnd; // Forward uses cursor as start bound

        // Reverse scan: scan < limit.
        // We want strictly BEFORE cursor.
        // Limit (exclusive) = cursor.
        if (originalEnd.isEmpty ||
            MemComparableKey.compare(startAfterKey, originalEnd) < 0) {
          return startAfterKey;
        }
        return originalEnd;
      }

      final opUpper = condition.operator.toUpperCase();

      if (opUpper == 'COMPOSITE') {
        final components = condition.components;
        if (components == null || components.isEmpty) {
          return IndexSearchResult.tableScan();
        }
        if (components.length > fields.length) {
          return IndexSearchResult.tableScan();
        }

        for (int i = 0; i < components.length; i++) {
          if (components[i].field != fields[i]) {
            return IndexSearchResult.tableScan();
          }
        }

        final prefixValues = <dynamic>[];
        for (int i = 0; i < components.length - 1; i++) {
          final componentOp = components[i].operator.toUpperCase();
          if (componentOp != '=') {
            return IndexSearchResult.tableScan();
          }
          prefixValues.add(components[i].value);
        }

        Uint8List? encodePrefixValues(List<dynamic> values) {
          if (values.isEmpty) return Uint8List(0);
          return encodeLeadingValues(values);
        }

        Uint8List? encodeCompositeValues(dynamic tailValue) {
          final values = <dynamic>[...prefixValues, tailValue];
          return encodeLeadingValues(values);
        }

        Uint8List? encodePrefixUpperBound() {
          if (prefixValues.isEmpty) return Uint8List(0);
          final prefixBytes = encodePrefixValues(prefixValues);
          if (prefixBytes == null) return null;
          return upperBoundExclusiveForPrefix(prefixBytes);
        }

        final last = components.last;
        final lastOp = last.operator.toUpperCase();

        if (lastOp == '=') {
          final prefix = encodeCompositeValues(last.value);
          if (prefix == null) return IndexSearchResult.empty();
          final start = applyCursorStart(prefix);
          final end = applyCursorEnd(upperBoundExclusiveForPrefix(prefix));

          if (end.isNotEmpty && MemComparableKey.compare(start, end) >= 0) {
            return IndexSearchResult.empty();
          }

          if (meta.isUnique) {
            if (hasCursorKey) {
              // Unique point + cursor: at most one key; cursor means already past it.
              return IndexSearchResult.empty();
            }
            final probeKey = prefixValues.isEmpty
                ? last.value
                : <dynamic>[...prefixValues, last.value];
            final nativeVal = <dynamic>[...prefixValues, last.value];
            return await _searchUniquePointLogical(
              table: table,
              indexUid: indexUid,
              meta: meta,
              schema: schema,
              encodedPrefix: prefix,
              probeKey: probeKey,
              nativeVal: nativeVal,
              reverse: reverse,
              readFromFileOnly: readFromFileOnly,
            );
          }

          return await _searchIndexByKeyRangeLogical(
            table: table,
            indexUid: indexUid,
            meta: meta,
            startKeyInclusive: start,
            endKeyExclusive: end,
            reverse: reverse,
            limit: limit,
            offset: effectiveOffset,
            readFromFileOnly: readFromFileOnly,
          );
        }

        if (lastOp == 'IN' && last.value is List) {
          final items = <(dynamic, Uint8List)>[];
          for (final value in (last.value as List)) {
            final prefix = encodeCompositeValues(value);
            if (prefix != null) {
              items.add((value, prefix));
            }
          }
          items.sort((a, b) {
            final cmp = MemComparableKey.compare(a.$2, b.$2);
            return reverse ? -cmp : cmp;
          });
          if (items.isNotEmpty) {
            final deduped = <(dynamic, Uint8List)>[];
            for (int i = 0; i < items.length; i++) {
              if (i == 0 ||
                  MemComparableKey.compare(items[i].$2, items[i - 1].$2) != 0) {
                deduped.add(items[i]);
              }
            }
            items
              ..clear()
              ..addAll(deduped);
          }

          final out = <String>[];
          final entriesOut = <IndexSearchEntry>[];
          final int need = (limit == null) ? -1 : max(0, limit);
          int remaining = need;
          final yieldController = YieldController('index_search_composite_in');

          for (final item in items) {
            final y5 = yieldController.maybeYield();
            if (y5 != null) await y5;
            if (remaining == 0) break;

            if (meta.isUnique) {
              final start = applyCursorStart(item.$2);
              final end = applyCursorEnd(upperBoundExclusiveForPrefix(item.$2));
              if (end.isNotEmpty && MemComparableKey.compare(start, end) >= 0) {
                continue;
              }
              if (MemComparableKey.compare(start, item.$2) > 0) continue;

              final probeKey = prefixValues.isEmpty
                  ? item.$1
                  : <dynamic>[...prefixValues, item.$1];
              final nativeVal = <dynamic>[...prefixValues, item.$1];
              final point = await _searchUniquePointLogical(
                table: table,
                indexUid: indexUid,
                meta: meta,
                schema: schema,
                encodedPrefix: item.$2,
                probeKey: probeKey,
                nativeVal: nativeVal,
                reverse: reverse,
                readFromFileOnly: readFromFileOnly,
              );
              if (point.primaryKeys.isNotEmpty) {
                out.addAll(point.primaryKeys);
                if (point.entries != null) {
                  entriesOut.addAll(point.entries!);
                } else {
                  for (final pk in point.primaryKeys) {
                    entriesOut.add(
                        IndexSearchEntry(primaryKey: pk, keyBytes: item.$2));
                  }
                }
                if (remaining > 0) {
                  remaining -= point.primaryKeys.length;
                  if (remaining <= 0) break;
                }
              }
              continue;
            }

            final start = applyCursorStart(item.$2);
            final end = applyCursorEnd(upperBoundExclusiveForPrefix(item.$2));
            if (end.isNotEmpty && MemComparableKey.compare(start, end) >= 0) {
              continue;
            }

            final res = await _searchIndexByKeyRangeLogical(
              table: table,
              indexUid: indexUid,
              meta: meta,
              startKeyInclusive: start,
              endKeyExclusive: end,
              reverse: reverse,
              limit: remaining > 0 ? remaining : null,
              offset: null,
              readFromFileOnly: readFromFileOnly,
            );
            out.addAll(res.primaryKeys);
            if (res.entries != null) {
              entriesOut.addAll(res.entries!);
            }

            if (remaining > 0) {
              remaining -= res.primaryKeys.length;
              if (remaining <= 0) break;
            }
          }

          List<String> finalPks = out;
          List<IndexSearchEntry>? finalEntries =
              entriesOut.isEmpty ? null : entriesOut;

          if (effectiveOffset != null && effectiveOffset > 0) {
            if (effectiveOffset >= finalPks.length) {
              return IndexSearchResult.empty();
            }
            finalPks = finalPks.sublist(effectiveOffset);
            if (finalEntries != null) {
              finalEntries = finalEntries.sublist(effectiveOffset);
            }
          }
          if (limit != null && finalPks.length > limit) {
            finalPks = finalPks.sublist(0, limit);
            if (finalEntries != null) {
              finalEntries = finalEntries.sublist(0, limit);
            }
          }

          return finalPks.isEmpty
              ? IndexSearchResult.empty()
              : IndexSearchResult(
                  primaryKeys: finalPks,
                  entries: finalEntries,
                );
        }

        if (lastOp == 'BETWEEN') {
          final startPrefix = encodeCompositeValues(last.value);
          final endPrefix = encodeCompositeValues(last.endValue);
          if (startPrefix == null || endPrefix == null) {
            return IndexSearchResult.empty();
          }
          final start = applyCursorStart(startPrefix);
          final end = applyCursorEnd(upperBoundExclusiveForPrefix(endPrefix));

          if (end.isNotEmpty && MemComparableKey.compare(start, end) >= 0) {
            return IndexSearchResult.empty();
          }

          return await _searchIndexByKeyRangeLogical(
            table: table,
            indexUid: indexUid,
            meta: meta,
            startKeyInclusive: start,
            endKeyExclusive: end,
            reverse: reverse,
            limit: limit,
            offset: effectiveOffset,
            readFromFileOnly: readFromFileOnly,
          );
        }

        if (lastOp == '>' ||
            lastOp == '>=' ||
            lastOp == '<' ||
            lastOp == '<=') {
          final pivot = encodeCompositeValues(last.value);
          if (pivot == null) return IndexSearchResult.empty();

          final prefixStart = encodePrefixValues(prefixValues);
          final prefixEnd = encodePrefixUpperBound();
          if (prefixValues.isNotEmpty &&
              (prefixStart == null || prefixEnd == null)) {
            return IndexSearchResult.empty();
          }

          Uint8List startBound;
          Uint8List endBound;
          final isLower = lastOp == '>' || lastOp == '>=';
          if (isLower) {
            startBound =
                lastOp == '>' ? upperBoundExclusiveForPrefix(pivot) : pivot;
            endBound = prefixEnd ?? Uint8List(0);
          } else {
            startBound = prefixStart ?? Uint8List(0);
            endBound =
                lastOp == '<=' ? upperBoundExclusiveForPrefix(pivot) : pivot;
          }

          final start = applyCursorStart(startBound);
          final end = applyCursorEnd(endBound);
          if (end.isNotEmpty && MemComparableKey.compare(start, end) >= 0) {
            return IndexSearchResult.empty();
          }

          return await _searchIndexByKeyRangeLogical(
            table: table,
            indexUid: indexUid,
            meta: meta,
            startKeyInclusive: start,
            endKeyExclusive: end,
            reverse: reverse,
            limit: limit,
            offset: effectiveOffset,
            readFromFileOnly: readFromFileOnly,
          );
        }

        if (lastOp == 'LIKE' && last.value is String) {
          final pattern = last.value as String;
          final parsed = ValueMatcher.parseOptimizablePrefixLike(pattern);
          if (parsed == null ||
              (!parsed.isExact && parsed.literalPrefix.isEmpty)) {
            return IndexSearchResult.tableScan();
          }
          final fieldPrefix = parsed.literalPrefix;

          final startPrefix = encodeCompositeValues(fieldPrefix);
          if (startPrefix == null) return IndexSearchResult.empty();

          Uint8List endBound;
          if (parsed.isExact) {
            endBound = upperBoundExclusiveForPrefix(startPrefix);
          } else {
            final nextPrefix = ValueMatcher.incrementUtf16Prefix(fieldPrefix);
            if (nextPrefix != null) {
              final endPrefix = encodeCompositeValues(nextPrefix);
              if (endPrefix == null) return IndexSearchResult.empty();
              endBound = endPrefix;
            } else {
              final prefixUpper = encodePrefixUpperBound();
              if (prefixUpper == null) return IndexSearchResult.empty();
              endBound = prefixUpper;
            }
          }

          final start = applyCursorStart(startPrefix);
          final end = applyCursorEnd(endBound);
          if (end.isNotEmpty && MemComparableKey.compare(start, end) >= 0) {
            return IndexSearchResult.empty();
          }

          return await _searchIndexByKeyRangeLogical(
            table: table,
            indexUid: indexUid,
            meta: meta,
            startKeyInclusive: start,
            endKeyExclusive: end,
            reverse: reverse,
            limit: limit,
            offset: effectiveOffset,
            readFromFileOnly: readFromFileOnly,
          );
        }

        return IndexSearchResult.tableScan();
      }

      // Cache Check Helper
      // Returns null if cache not available or not applicable
      // Returns IndexSearchResult if cache used (empty or populated)
      Future<IndexSearchResult?> checkCache(
          dynamic prefix, dynamic start, dynamic end) async {
        // Equality/Point Lookup
        if (prefix != null && start == null && end == null) {
          if (hasCursorKey && isUnique) {
            return IndexSearchResult.empty();
          }

          final List<dynamic> comps = prefix is List ? prefix : [prefix];
          final compositePrefix = <dynamic>[table.tableUid, indexUid, ...comps];

          if (isUnique) {
            final probeKey = comps.length == 1 ? comps.first : comps;

            // Pending/txn unique ownership wins over hotspot.
            if (!readFromFileOnly) {
              final bufferId =
                  _probeBufferForUniqueIndex(table, indexUid, probeKey);
              if (bufferId != null) {
                return IndexSearchResult(primaryKeys: [bufferId]);
              }
            }

            final val = _indexDataCache.get(compositePrefix);
            if (val == null) {
              // Memory mode must not fall back to disk; cache miss means "not found".
              return isMemoryMode ? IndexSearchResult.empty() : null;
            }
            if (val is! String || val.isEmpty) {
              return IndexSearchResult.empty();
            }
            // Hotspot is write-path maintained for already-cached keys; unique
            // ownership probe above covers pending insert/update/delete.
            return IndexSearchResult(primaryKeys: [val]);
          }
        }

        return null;
      }

      // Equality
      if (opUpper == '=') {
        final List<dynamic>? nativeVal =
            normalizeValues(condition.value, fields.length);
        if (nativeVal == null) return IndexSearchResult.empty();

        // Check Cache with Native Key
        // Equality Cache Optimization:
        final cacheResult = await checkCache(nativeVal, null, null);

        if (cacheResult != null) {
          if (!hasCursorKey) {
            return cacheResult;
          }
          // Cache Hit with Cursor: Filter in-memory
          if (isUnique) {
            // Unique index result is a single PK.
          } else {
            final List<String> cachedPks = cacheResult.primaryKeys;

            final List<String> pks = List.of(cachedPks);
            // Sort by typed primary-key order (length-first for sequential PKs),
            // matching on-disk / TreeCache non-unique leaf order -- not String.compareTo.
            final pkMatcher =
                ValueMatcher.getMatcher(schema.getPrimaryKeyMatcherType());
            pks.sort((a, b) {
              final c = pkMatcher(a, b);
              return reverse ? -c : c;
            });

            final out = <String>[];
            final localPrefix = encodePrefix(condition.value);

            if (localPrefix != null) {
              for (final pk in pks) {
                final encodedRecordKey = schema.encodePrimaryKeyComponent(pk);
                final fullKey =
                    Uint8List(localPrefix.length + encodedRecordKey.length);
                fullKey.setAll(0, localPrefix);
                fullKey.setAll(localPrefix.length, encodedRecordKey);

                // Comparison
                bool include = false;
                if (reverse) {
                  // strictly BEFORE cursor
                  if (MemComparableKey.compare(fullKey, startAfterKey) < 0) {
                    include = true;
                  }
                } else {
                  // strictly AFTER cursor
                  if (MemComparableKey.compare(fullKey, startAfterKey) > 0) {
                    include = true;
                  }
                }
                if (include) out.add(pk);
              }
              return IndexSearchResult(primaryKeys: out);
            }
          }
        }
        final prefix = encodePrefix(condition.value);
        if (prefix == null) return IndexSearchResult.empty();

        if (isUnique) {
          if (hasCursorKey) return IndexSearchResult.empty();
          // Unique yields at most one row; offset>0 means skip it.
          if (effectiveOffset != null && effectiveOffset > 0) {
            return IndexSearchResult.empty();
          }

          return await _searchUniquePointLogical(
            table: table,
            indexUid: indexUid,
            meta: meta,
            schema: schema,
            encodedPrefix: prefix,
            probeKey: nativeVal.length == 1 ? nativeVal.first : nativeVal,
            nativeVal: nativeVal,
            reverse: reverse,
            readFromFileOnly: readFromFileOnly,
          );
        }

        final end = upperBoundExclusiveForPrefix(prefix);
        final start = applyCursorStart(prefix);
        final endEffective = applyCursorEnd(end);

        if (endEffective.isNotEmpty &&
            MemComparableKey.compare(start, endEffective) >= 0) {
          return IndexSearchResult.empty();
        }
        final res = await _searchIndexByKeyRangeLogical(
          table: table,
          indexUid: indexUid,
          meta: meta,
          startKeyInclusive: start,
          endKeyExclusive: endEffective,
          reverse: reverse,
          limit: limit,
          offset: effectiveOffset,
          readFromFileOnly: readFromFileOnly,
        );

        if (limit == null &&
            offset == null &&
            !hasCursorKey &&
            !readFromFileOnly) {
          // Hotspot populate (non-unique): fused visible PKs only.
          if (!(_dataStore.resourceManager?.isLowMemoryMode ?? false)) {
            final prefixKey = <dynamic>[table.tableUid, indexUid, ...nativeVal];
            final yc = YieldController('IndexManager.hotspotPopulateNonUnique');
            for (final pk in res.primaryKeys) {
              final y6 = yc.maybeYield();
              if (y6 != null) await y6;
              _indexDataCache.put(
                <dynamic>[...prefixKey, pk],
                true,
                size: pk.length + 1,
              );
            }
          }
        }

        return res;
      }

      // BETWEEN (inclusive).
      if (opUpper == 'BETWEEN') {
        final startPrefix = encodePrefix(condition.value);
        final endPrefix = encodePrefix(condition.endValue);
        if (startPrefix == null || endPrefix == null) {
          return IndexSearchResult.empty();
        }
        final endExclusive = upperBoundExclusiveForPrefix(endPrefix);
        final start = applyCursorStart(startPrefix);
        final endEffective = applyCursorEnd(endExclusive);

        if (endEffective.isNotEmpty &&
            MemComparableKey.compare(start, endEffective) >= 0) {
          return IndexSearchResult.empty();
        }
        return await _searchIndexByKeyRangeLogical(
          table: table,
          indexUid: indexUid,
          meta: meta,
          startKeyInclusive: start,
          endKeyExclusive: endEffective,
          reverse: reverse,
          limit: limit,
          offset: effectiveOffset,
          readFromFileOnly: readFromFileOnly,
        );
      }

      // Range comparisons
      if (opUpper == '>' ||
          opUpper == '>=' ||
          opUpper == '<' ||
          opUpper == '<=') {
        // Similar to BETWEEN, skip native cache for complex open ranges for now.
        // Focus on removing explicit MemComparableKey usages.
        final prefix = encodePrefix(condition.value);
        if (prefix == null) return IndexSearchResult.empty();

        Uint8List startBound, endBound;
        bool isLower = (opUpper == '>' || opUpper == '>=');

        if (isLower) {
          startBound =
              (opUpper == '>') ? upperBoundExclusiveForPrefix(prefix) : prefix;
          endBound = Uint8List(0);
        } else {
          startBound = Uint8List(0);
          endBound =
              (opUpper == '<=') ? upperBoundExclusiveForPrefix(prefix) : prefix;
        }

        // Apply cursors
        final start = applyCursorStart(startBound);
        final endEffective = applyCursorEnd(endBound);

        if (endEffective.isNotEmpty &&
            MemComparableKey.compare(start, endEffective) >= 0) {
          return IndexSearchResult.empty();
        }

        return await _searchIndexByKeyRangeLogical(
          table: table,
          indexUid: indexUid,
          meta: meta,
          startKeyInclusive: start,
          endKeyExclusive: endEffective,
          reverse: reverse,
          limit: limit,
          offset: effectiveOffset,
          readFromFileOnly: readFromFileOnly,
        );
      }

      // Full Index Scan (SCAN)
      if (opUpper == 'SCAN') {
        final start = applyCursorStart(Uint8List(0));
        final end = applyCursorEnd(Uint8List(0));

        if (end.isNotEmpty && MemComparableKey.compare(start, end) >= 0) {
          return IndexSearchResult.empty();
        }

        return await _searchIndexByKeyRangeLogical(
          table: table,
          indexUid: indexUid,
          meta: meta,
          startKeyInclusive: start,
          endKeyExclusive: end,
          reverse: reverse,
          limit: limit,
          offset: effectiveOffset,
          readFromFileOnly: readFromFileOnly,
        );
      }

      // Prefix LIKE: use index range scan [prefix, nextPrefix) so only matching keys are read (same cost as equality).
      if (opUpper == 'LIKE' && condition.value is String) {
        final pattern = condition.value as String;
        final parsed = ValueMatcher.parseOptimizablePrefixLike(pattern);
        if (parsed == null ||
            (!parsed.isExact && parsed.literalPrefix.isEmpty)) {
          return IndexSearchResult.tableScan();
        }
        final prefix = parsed.literalPrefix;

        // Single-field index: encode full key. Composite: encode first field only for range.
        Uint8List? startBytes = encodePrefix(prefix);
        Uint8List? endBytes;
        if (parsed.isExact) {
          if (startBytes != null) {
            endBytes = upperBoundExclusiveForPrefix(startBytes);
          }
        } else if (prefix.isNotEmpty) {
          final nextPrefix = ValueMatcher.incrementUtf16Prefix(prefix);
          if (nextPrefix != null) {
            endBytes = encodePrefix(nextPrefix);
          }
        }

        // Composite index: encodePrefix(prefix) returns null (needs n components). Use first field only.
        if (startBytes == null && fields.isNotEmpty) {
          final c0 = schema.encodeFieldComponentToMemComparable(
            fields[0],
            prefix,
            truncateText: truncateText,
          );
          if (c0 != null) {
            startBytes = MemComparableKey.encodeTuple([c0]);
            if (parsed.isExact) {
              endBytes = upperBoundExclusiveForPrefix(startBytes);
            } else if (prefix.isNotEmpty) {
              final nextPrefix = ValueMatcher.incrementUtf16Prefix(prefix);
              if (nextPrefix != null) {
                final c0End = schema.encodeFieldComponentToMemComparable(
                  fields[0],
                  nextPrefix,
                  truncateText: truncateText,
                );
                if (c0End != null) {
                  endBytes = MemComparableKey.encodeTuple([c0End]);
                }
              }
            }
          }
        }

        if (startBytes != null) {
          final start = applyCursorStart(startBytes);
          final end = applyCursorEnd(endBytes ?? Uint8List(0));

          if (end.isNotEmpty && MemComparableKey.compare(start, end) >= 0) {
            return IndexSearchResult.empty();
          }

          return await _searchIndexByKeyRangeLogical(
            table: table,
            indexUid: indexUid,
            meta: meta,
            startKeyInclusive: start,
            endKeyExclusive: end,
            reverse: reverse,
            limit: limit,
            offset: effectiveOffset,
            readFromFileOnly: readFromFileOnly,
          );
        }
        return IndexSearchResult.tableScan();
      }

      if (opUpper == 'IN' && condition.value is List) {
        // Prepare (value, nativeVal, prefix) triplets
        final items = <(dynamic, List<dynamic>, Uint8List)>[];
        for (final v in (condition.value as List)) {
          final nativeVal = normalizeValues(v, fields.length);
          if (nativeVal != null) {
            final prefix = encodeLeadingValues(nativeVal);
            if (prefix != null) {
              items.add((v, nativeVal, prefix));
            }
          }
        }

        // Sort based on index order (forward or reverse)
        // This ensures meaningful cursor traversal across the IN-list buckets.
        items.sort((a, b) {
          final cmp = MemComparableKey.compare(a.$3, b.$3);
          return reverse ? -cmp : cmp;
        });

        // Unique values only (consecutive)
        if (items.isNotEmpty) {
          final uniqueItems = <(dynamic, List<dynamic>, Uint8List)>[];
          for (int i = 0; i < items.length; i++) {
            if (i == 0 ||
                MemComparableKey.compare(items[i].$3, items[i - 1].$3) != 0) {
              uniqueItems.add(items[i]);
            }
          }
          items.clear();
          items.addAll(uniqueItems);
        }

        final out = <String>[];
        final entriesOut = <IndexSearchEntry>[];
        final int need = (limit == null) ? -1 : max(0, limit);
        int remaining = need;
        final yieldController = YieldController('index_search_in');

        for (final item in items) {
          final nativeVal = item.$2;
          final prefix = item.$3;

          final y7 = yieldController.maybeYield();
          if (y7 != null) await y7;
          if (remaining == 0) break;

          final endBound = upperBoundExclusiveForPrefix(prefix);
          final start = applyCursorStart(prefix);
          final end = applyCursorEnd(endBound);

          // If range is invalid (fully behind cursor), skip
          if (end.isNotEmpty && MemComparableKey.compare(start, end) >= 0) {
            continue;
          }

          bool usedCache = false;

          // Try Cache with Native Key (ONLY if full bucket scan is requested)
          // i.e., start == prefix AND end == endBound (no cursor slicing in this bucket)
          if (MemComparableKey.compare(start, prefix) == 0 &&
              MemComparableKey.compare(end, endBound) == 0) {
            final cacheRes = await checkCache(nativeVal, null, null);
            if (cacheRes != null) {
              out.addAll(cacheRes.primaryKeys);
              usedCache = true;
            }
          }

          if (!usedCache) {
            if (isUnique) {
              // For unique index, if cursor > prefix, 'start' will be > 'prefix', so we skip.
              if (MemComparableKey.compare(start, prefix) > 0) continue;

              final point = await _searchUniquePointLogical(
                table: table,
                indexUid: indexUid,
                meta: meta,
                schema: schema,
                encodedPrefix: prefix,
                probeKey: nativeVal.length == 1 ? nativeVal.first : nativeVal,
                nativeVal: nativeVal,
                reverse: reverse,
                readFromFileOnly: readFromFileOnly,
              );
              if (point.primaryKeys.isNotEmpty) {
                final pk = point.primaryKeys.first;
                out.add(pk);
                if (point.entries != null && point.entries!.isNotEmpty) {
                  entriesOut.add(point.entries!.first);
                } else {
                  entriesOut
                      .add(IndexSearchEntry(primaryKey: pk, keyBytes: prefix));
                }
                if (remaining > 0) remaining--;
              }
            } else {
              // Range Scan -- fuses file + pending/txn unless readFromFileOnly.
              final res = await _searchIndexByKeyRangeLogical(
                table: table,
                indexUid: indexUid,
                meta: meta,
                startKeyInclusive: start,
                endKeyExclusive: end,
                reverse: reverse,
                limit: remaining > 0 ? remaining : null,
                offset: null, // Offset is handled globally for IN
                readFromFileOnly: readFromFileOnly,
              );

              // Hotspot: only full-bucket fused results. Never cache file-only
              // (skips pending merge) or limit-truncated pages -- both poison
              // later cache hits with incomplete/stale PKs.
              if (!readFromFileOnly &&
                  !hasCursorKey &&
                  need < 0 &&
                  !(_dataStore.resourceManager?.isLowMemoryMode ?? false) &&
                  res.primaryKeys.isNotEmpty) {
                final prefixKey = <dynamic>[
                  table.tableUid,
                  indexUid,
                  ...nativeVal
                ];
                final yc =
                    YieldController('IndexManager.hotspotPopulateNonUniqueIn');
                for (final pk in res.primaryKeys) {
                  final y8 = yc.maybeYield();
                  if (y8 != null) await y8;
                  _indexDataCache.put(
                    <dynamic>[...prefixKey, pk],
                    true,
                    size: pk.length + 1,
                  );
                }
              }

              out.addAll(res.primaryKeys);
              if (res.entries != null) {
                entriesOut.addAll(res.entries!);
              }

              if (remaining > 0) {
                remaining -= res.primaryKeys.length;
                if (remaining <= 0) break;
              }
            }
          }

          if (remaining > 0) {
            remaining = max(0, need - out.length);
          }
        }

        // Final Filter
        List<String> finalPks = out;
        List<IndexSearchEntry>? finalEntries =
            entriesOut.isEmpty ? null : entriesOut;

        if (effectiveOffset != null && effectiveOffset > 0) {
          if (effectiveOffset >= finalPks.length) {
            return IndexSearchResult.empty();
          }
          finalPks = finalPks.sublist(effectiveOffset);
          if (finalEntries != null) {
            finalEntries = finalEntries.sublist(effectiveOffset);
          }
        }
        if (limit != null && finalPks.length > limit) {
          finalPks = finalPks.sublist(0, limit);
          if (finalEntries != null) {
            finalEntries = finalEntries.sublist(0, limit);
          }
        }

        if (finalPks.isEmpty) return IndexSearchResult.empty();
        return IndexSearchResult(
          primaryKeys: finalPks,
          entries: finalEntries,
        );
      }

      // LIKE / != / others: fallback to table scan for correctness.
      return IndexSearchResult.tableScan();
    } catch (e) {
      Logger.error('searchIndex failed', rawError: e);
      return IndexSearchResult.tableScan();
    }
  }

  /// Get current index data cache size in bytes (Data Partition + Range Partition Data + B+Tree pages)
  Future<int> getCurrentIndexDataCacheSize() async {
    // Include both data cache and page cache (B+Tree pages)
    final dataCacheSize = _indexDataCache.estimatedTotalSizeBytes;
    final pageCacheSize =
        _dataStore.indexTreePartitionManager?.getCurrentPageCacheSize() ?? 0;
    return dataCacheSize + pageCacheSize;
  }

  /// Get current index metadata cache size in bytes (Schema/Directories)
  Future<int> getCurrentIndexMetaCacheSize() async {
    return _indexMetaCache.estimatedTotalSizeBytes;
  }

  /// Get TOTAL index cache size (Data + Meta)
  Future<int> getCurrentIndexCacheSize() async {
    return (await getCurrentIndexMetaCacheSize()) +
        (await getCurrentIndexDataCacheSize());
  }

  /// Remove full index cache for a specific table
  Future<void> removeFullIndexCacheForTable(TableContext table) async {
    _indexDataCache.remove([table.tableUid]);
  }

  /// Remove index meta cache for table
  Future<void> removeIndexMetaCacheForTable(TableContext table) async {
    if (table.tableUid.isEmpty) return;

    // Remove from TreeCache using hierarchical prefix
    _indexMetaCache.remove([table.tableUid]);
  }

  /// Clear all cache
  Future<void> clearAllCache() async {
    _indexDataCache.clear();
    _indexMetaCache.clear();
    _metaLoadingFutures.clear();
  }

  /// Dispose resources and wait for pending tasks to complete.
  Future<void> dispose() async {
    // 1. Wait for any in-flight metadata loading futures.
    final futures = <Future<dynamic>>[
      ..._metaLoadingFutures.values,
    ];

    if (futures.isNotEmpty) {
      try {
        await Future.wait(futures).timeout(const Duration(seconds: 5));
      } catch (e) {
        if (!_dataStore.isInitialized) {
          Logger.info(
              'Index pending futures cancelled during database shutdown');
        } else {
          Logger.warn(
              'Some index-related async tasks failed or timed out during shutdown',
              rawError: e);
        }
      }
    }

    // 2. Clear caches to release memory
    _indexDataCache.clear();
    _indexMetaCache.clear();
    _metaLoadingFutures.clear();
  }
}

class _UniqueConstraint {
  final List<String> fields;
  final dynamic value;
  final IndexUid indexUid;
  final IndexName indexName;
  // fast-path canonical key for write buffer check (raw value or List)
  final dynamic canonicalKey;

  _UniqueConstraint({
    required this.fields,
    required this.value,
    required this.indexUid,
    required this.indexName,
    this.canonicalKey,
  });
}
