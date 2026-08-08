import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../handler/common.dart';
import '../handler/logger.dart';
import '../handler/memcomparable.dart';
import '../handler/parallel_processor.dart';
import '../handler/value_matcher.dart';
import '../model/db_exception.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/data_block_entry.dart';
import '../model/data_store_config.dart';
import '../model/id_generator.dart';
import '../model/index_entry.dart';
import '../model/index_search.dart';
import '../model/meta_info.dart';
import '../model/parallel_journal_entry.dart';
import '../model/system_table.dart';
import '../model/table_schema.dart';
import '../model/table_context.dart';
import '../model/table_identity.dart';
import '../model/unique_violation.dart';
import '../query/query_condition.dart';
import 'compute/compute_batch_planner.dart';
import 'compute/index_delta_prepare_compute.dart';
import 'compute/unique_index_prepare_compute.dart';
import 'compute_manager.dart';
import 'data_store_impl.dart';
import 'io_concurrency_planner.dart';
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

  // Index Field Matchers: Map<"tableUid:indexUid", List<MatcherFunction>>
  // Stores ordered matchers for each indexed field to ensure correct TreeCache path comparison.
  final Map<String, List<MatcherFunction>> _indexFieldMatchers = {};

  // Index metadata cache using TreeCache
  late final TreeCache<IndexMeta> _indexMetaCache;

  // Loading futures to prevent thundering herd on concurrent meta loads
  final Map<String, Future<IndexMeta?>> _metaLoadingFutures = {};

  String _getMetaLoadingKey(TableUid tableUid, IndexUid indexUid) =>
      '$tableUid#$indexUid';

  /// Drop all in-memory state for one index (data cache, meta, matchers, page cache).
  void _invalidateIndexCache(TableContext table, IndexUid indexUid) {
    if (indexUid.isEmpty) return;
    _indexMetaCache.remove([table.tableUid, indexUid]);
    _indexDataCache.remove([table.tableUid, indexUid]);
    _indexFieldMatchers.remove('${table.tableUid}:$indexUid');
    _metaLoadingFutures.remove(_getMetaLoadingKey(table.tableUid, indexUid));
    _dataStore.indexTreePartitionManager
        ?.clearPageCacheForIndex(table, indexUid);
  }

  /// Invalidate cached [IndexMeta] after external partition-0 rewrite (redo replay).
  void invalidateIndexMetaCache(TableUid tableUid, IndexUid indexUid) {
    if (indexUid.isEmpty) return;
    _indexMetaCache.remove([tableUid, indexUid]);
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

  Future<List<PreparedUniqueIndexEntry>> _prepareUniqueIndexEntriesBatch({
    required TableSchema schema,
    required IndexSchema index,
    required List<Map<String, dynamic>> records,
    required List<List<String>?>? changedFieldsByRecord,
  }) async {
    if (records.isEmpty) {
      return const <PreparedUniqueIndexEntry>[];
    }

    // PERFORMANCE: unique-key encoding is lighter than isolate Map transfer.
    // Running on the current isolate avoids cloning every record for each
    // unique index during checkUniqueConstraintsBatch (batchInsert hot path).
    final result = await prepareUniqueIndexChunk(
      UniqueIndexPrepareRequest(
        schema: schema,
        index: index,
        records: records,
        changedFieldsByRecord: changedFieldsByRecord,
      ),
    );
    return result.entries;
  }

  IndexManager(this._dataStore) {
    final res = _dataStore.resourceManager;
    final int maxBytes = res?.getIndexCacheSize() ?? (50 * 1024 * 1024);
    final metaCacheSize =
        res?.getMetaCacheSize() ?? 100 * 1024 * 1024; // Default 100MB
    final indexMetaCacheSize =
        (metaCacheSize * 0.25).toInt(); // 25% of meta cache

    // Initialize index data cache
    _indexDataCache = TreeCache<dynamic>(
      sizeCalculator: _estimateIndexDataSize,
      maxByteThreshold: (maxBytes * 0.70).toInt(),
      minByteThreshold: 150 * 1024 * 1024,
      groupDepth: 2,
      comparatorFactory: _indexComparatorFactory,
      weightQueryCallback: _queryIndexDataWeight,
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
    _registerIndexComparator(table, indexUid, schema);
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

  /// Update full index cache based on record changes
  Future<void> updateIndexDataCache(TableContext table, String pk,
      Map<String, dynamic>? oldData, Map<String, dynamic>? newData,
      {TableSchema? overrideSchema, bool force = false}) async {
    try {
      final schema = overrideSchema ??
          await _dataStore.tableMetaManager?.getTableSchema(table.tableUid);
      if (schema == null) return;
      final indexes = <IndexSchema>[
        ...?_dataStore.tableMetaManager?.getAllIndexesFor(schema),
        ...getEngineManagedBtreeIndexes(table, schema),
      ];
      if (indexes.isEmpty) return;

      final bool isMemoryMode =
          _dataStore.config.persistenceMode == PersistenceMode.memory;
      // In memory mode, _indexDataCache is the committed index store, not an optional cache.
      // Always apply mutations so search/uniqueness never fall back to disk.
      final bool shouldWrite =
          force || _dataStore.isGlobalPrewarming || isMemoryMode;

      for (final index in indexes) {
        if (index.type == IndexType.vector) continue;
        final indexUid = _indexUidFromSchema(index);

        // Ensure comparator is registered
        _registerIndexComparator(table, indexUid, schema);

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
  Comparator<dynamic> _indexComparatorFactory(List<dynamic> path) {
    // Path structure: [table.tableUid, indexUid, field1, field2, ..., pk]
    if (path.length < 2) return TreeCache.compareNative;

    final tableUid = path.isNotEmpty ? path[0]?.toString() ?? '' : '';
    final indexUid = path.length > 1 ? path[1]?.toString() ?? '' : '';
    final matchers = _indexFieldMatchers['$tableUid:$indexUid'];

    if (matchers != null) {
      // path.length == 2: We are at [table.tableUid, indexUid], next element to compare is field1
      // path.length == 3: Next is field2, etc.
      final fieldIndex = path.length - 2;
      if (fieldIndex < matchers.length) {
        final matcher = matchers[fieldIndex];
        return (a, b) => matcher(a, b);
      }
    }

    // Default: compareNative (strings, numbers, etc. using standard Dart comparison)
    // This is used for tableUid, indexUid, and trailing PKs in non-unique indexes.
    return TreeCache.compareNative;
  }

  /// Register field comparators for a specific index to ensure TreeCache works correctly.
  void _registerIndexComparator(
      TableContext table, IndexUid indexUid, TableSchema schema) {
    final key = '${table.tableUid}:$indexUid';
    if (_indexFieldMatchers.containsKey(key)) return;

    final indexSchema = _findBtreeIndexSchema(schema, indexUid, table: table);

    if (indexSchema == null || indexSchema.fields.isEmpty) return;

    final matchers = <MatcherFunction>[];
    for (final field in indexSchema.fields) {
      final mt = schema.getFieldMatcherType(field);
      matchers.add(ValueMatcher.getMatcher(mt));
    }
    // Non-unique index key order is (fields..., pk). The trailing PK comparator
    // must match schema primary-key ordering or cursor paging can break.
    if (!indexSchema.unique) {
      matchers.add(ValueMatcher.getMatcher(schema.getPrimaryKeyMatcherType()));
    }
    _indexFieldMatchers[key] = matchers;
  }

  /// Memory-mode index scan based on [_indexDataCache].
  ///
  /// This reuses the historical "full cache scan" semantics to keep cursor paging
  /// consistent between forward/reverse scans, by applying start/end bounds using
  /// MemComparable encoded keys inside the scan callback (not via TreeCache seek).
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
    // OPTIMIZATION: Decode bounds to seek in TreeCache.
    List<dynamic>? rangeStart;
    List<dynamic>? rangeEnd;
    try {
      if (startKeyInclusive.isNotEmpty) {
        final decoded = MemComparableKey.decodeTuple(startKeyInclusive);
        rangeStart = [table.tableUid, indexUid, ...decoded];
      }
      if (endKeyExclusive.isNotEmpty) {
        final decoded = MemComparableKey.decodeTuple(endKeyExclusive);
        rangeEnd = [table.tableUid, indexUid, ...decoded];
      }
    } catch (_) {
      rangeStart = null;
      rangeEnd = null;
    }

    _registerIndexComparator(table, indexUid, schema);

    int scannedCount = 0;
    int addedCount = 0;

    final prefixKey = <dynamic>[table.tableUid, indexUid];
    final results = <String>[];
    final entries = <IndexSearchEntry>[];
    Uint8List? lastKey;

    // Safety check on bounds validity vs prefix.
    if (rangeStart != null &&
        (rangeStart.length < 2 ||
            rangeStart[0] != table.tableUid ||
            rangeStart[1] != indexUid)) {
      rangeStart = null;
    }
    if (rangeEnd != null &&
        (rangeEnd.length < 2 ||
            rangeEnd[0] != table.tableUid ||
            rangeEnd[1] != indexUid)) {
      rangeEnd = null;
    }

    // Resolve index schema for encoding key components (truncateText for non-unique).
    final indexSchema = _findBtreeIndexSchema(schema, indexUid, table: table) ??
        IndexSchema(indexName: '', fields: const []);
    final resolvedIndexSchema = indexSchema;
    final int fieldCount = resolvedIndexSchema.fields.length;
    final bool truncateText = !isUnique;

    await _indexDataCache.scanRange(
      rangeStart ?? prefixKey,
      rangeEnd,
      reverse: reverse,
      onEntry: (key, val) {
        if (key.length < 2 || key[0] != table.tableUid || key[1] != indexUid) {
          return false;
        }

        final keyValues =
            key.sublist(2); // index field native values + pk? (non-unique)

        // Safety: if schema mismatch, keep scanning but skip this entry.
        if (fieldCount <= 0 || keyValues.length < fieldCount) return true;

        // Always encode key for cursor paging (fields..., [pk]).
        final comps = <Uint8List>[];
        for (int i = 0; i < fieldCount; i++) {
          final c = schema.encodeFieldComponentToMemComparable(
            resolvedIndexSchema.fields[i],
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

        // Apply inclusive/exclusive bounds (same as old full-cache logic).
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

        if (pk != null && pk.isNotEmpty) {
          results.add(pk);
          entries.add(IndexSearchEntry(primaryKey: pk, keyBytes: encodedKey));
          addedCount++;
        }

        if (limit != null && addedCount >= limit) return false;
        return true;
      },
    );

    return IndexSearchResult(
      primaryKeys: results,
      entries: entries.isEmpty ? null : entries,
      lastKey: lastKey,
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
  }) async {
    final isMemoryMode =
        _dataStore.config.persistenceMode == PersistenceMode.memory;
    if (!isMemoryMode) {
      return _dataStore.indexTreePartitionManager?.searchByKeyRange(
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
    }

    // Memory mode: index data cache is the primary index store.
    // Use in-memory TreeCache scan to preserve cursor paging semantics.
    final schema =
        await _dataStore.tableMetaManager?.getTableSchema(table.tableUid);
    if (schema == null) return IndexSearchResult.tableScan();
    return _scanIndexDataCacheRange(
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
    await mutateIndexMeta(
      table,
      indexUid,
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
    final cached = _indexMetaCache.get([tableUid, indexUid]);
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

  /// Internal method to perform the actual file load
  Future<IndexMeta?> _doLoadIndexMeta(
      TableUid tableUid, IndexUid indexUid) async {
    try {
      final bool isMemoryMode =
          _dataStore.config.persistenceMode == PersistenceMode.memory;

      final meta = await _dataStore.treeMetaPageService.readIndexGlobalMeta(
        tableUid,
        indexUid,
      );
      if (meta != null) {
        _indexMetaCache.put([tableUid, indexUid], meta);
        return meta;
      }

      if (!isMemoryMode) {
        return null;
      }

      // In pure memory mode, index metadata files may never be created on disk.
      // Synthesize an in-memory IndexMeta from the consolidated index list
      // (includes implicit indexes like TTL / foreign keys).
      try {
        final tableContext =
            await _dataStore.tableMetaManager?.getTableContext(tableUid);
        if (tableContext == null) return null;

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
          _indexMetaCache.put([tableUid, indexUid], synthesized);
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
          tableUid: tableUid,
          indexUid: resolvedUid,
          meta: meta,
          batchContext: batchContext,
          flush: flush,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
        );
      }

      _indexMetaCache.put([tableUid, resolvedUid], meta);
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
  /// Deletes that root once (not per-index) and clears memory caches. Does
  /// **not** recreate empty [IndexMeta] - the next [writeChanges] synthesizes
  /// meta on demand.
  Future<void> clearIndexesForTable(TableContext table) async {
    try {
      _dataStore.vectorIndexManager?.clearCacheForTable(table.tableUid);
      _indexMetaCache.remove([table.tableUid]);
      _indexDataCache.remove([table.tableUid]);
      _indexFieldMatchers
          .removeWhere((key, _) => key.startsWith('${table.tableUid}:'));
      _metaLoadingFutures
          .removeWhere((key, _) => key.startsWith('${table.tableUid}#'));
      _dataStore.indexTreePartitionManager?.clearPageCacheForTable(table);

      final indexDir =
          await _dataStore.pathManager.getIndexDirPath(table.tableUid);
      if (await _dataStore.storage.existsDirectory(indexDir)) {
        await _dataStore.storage.deleteDirectory(indexDir);
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
        } else {
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
      UniqueViolation? checkInBuffer(_UniqueConstraint constraint,
          {bool transactionOnly = false}) {
        if (skipBufferCheck) return null;
        try {
          final compositeKey = constraint.canonicalKey;
          if (compositeKey != null) {
            final String? selfIdToIgnore =
                isUpdate ? primaryValue?.toString() : null;
            final String? conflictId;
            if (transactionOnly) {
              conflictId = writeBuf.hasUniqueKeyOwnedByOtherTransaction(
                table,
                constraint.indexUid,
                compositeKey,
                selfIdToIgnore,
                transactionId: currentTxId,
              );
            } else {
              conflictId = writeBuf.hasUniqueKeyOwnedByOther(
                table,
                constraint.indexUid,
                compositeKey,
                selfIdToIgnore,
                transactionId: currentTxId,
              );
            }
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

          _registerIndexComparator(table, c.indexUid, schema);
          final cacheKey = <dynamic>[table.tableUid, c.indexUid, ...vals];
          final existing = _indexDataCache.get(cacheKey);
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

      // 3. Execute disk checks using existsUniqueKeysBatch (fast BinaryFuseFilter + grouped I/O)
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
            final tableDataMeta = await _dataStore.tableDataManager
                .getTableDataMeta(table.tableUid);
            if (tableDataMeta == null || tableDataMeta.totalRecordCount <= 0) {
              // Verified empty table on disk; no persistent conflict possible.
              continue;
            }
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

          // Batch check existence using BinaryFuseFilter + grouped I/O
          final exists =
              await _dataStore.indexTreePartitionManager?.existsUniqueKeysBatch(
                    table: table,
                    indexUid: indexUid,
                    meta: meta,
                    uniqueKeys: keyBytes,
                  ) ??
                  <bool>[];

          final positiveKeyBytes = <Uint8List>[];
          final positiveConstraintIndices = <int>[];
          for (int j = 0; j < exists.length; j++) {
            if (!exists[j]) {
              continue;
            }
            final constraintIdx = constraintIndices[j];
            if (constraintIdx < 0 || constraintIdx >= indexConstraints.length) {
              continue;
            }
            positiveKeyBytes.add(keyBytes[j]);
            positiveConstraintIndices.add(constraintIdx);
          }

          if (positiveKeyBytes.isEmpty) {
            continue;
          }

          final existingPks = await _dataStore.indexTreePartitionManager
                  ?.lookupUniquePrimaryKeysBatch(
                table: table,
                indexUid: indexUid,
                meta: meta,
                uniqueKeys: positiveKeyBytes,
              ) ??
              <String>[];

          // Check results
          for (int j = 0; j < positiveConstraintIndices.length; j++) {
            final constraintIdx = positiveConstraintIndices[j];
            if (constraintIdx < 0 || constraintIdx >= indexConstraints.length) {
              continue;
            }
            final constraint = indexConstraints[constraintIdx];
            final existingPk = j < existingPks.length ? existingPks[j] : null;

            // Keep the fast existence probe, but only treat it as a conflict when
            // the resolved owner record is still logically visible.
            if (existingPk == null || existingPk.isEmpty) {
              Logger.warn(
                'Unique key exists but owner lookup returned null: '
                'table=${table.tableName} index=${_indexLogLabel(table, indexUid)} '
                'value=${constraint.value}',
              );
            } else {
              if (_isPrimaryKeyHiddenByDeleteOverlay(
                table,
                existingPk,
                transactionId: currentTxId,
              )) {
                continue;
              }

              if (isUpdate &&
                  selfStoreIndexStr != null &&
                  existingPk == selfStoreIndexStr) {
                continue;
              }
            }

            Logger.debug(
                "[Unique Constraint Violation] Table '${table.tableName}' Field(s) [${constraint.fields.join(', ')}] already contain value '${constraint.value}' (disk check)");
            return UniqueViolation(
              tableName: table.tableName,
              fields: constraint.fields,
              value: constraint.value,
              indexName: constraint.indexName,
              existingPrimaryKey: (existingPk != null && existingPk.isNotEmpty)
                  ? existingPk
                  : null,
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
  /// [records] The full merged records to check.
  /// [changedFieldsMap] Optional map of changed field sets keyed by primary key string.
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
      Map<String, Set<String>>? changedFieldsMap}) async {
    if (records.isEmpty) return const <UniqueViolation?>[];

    final yieldController =
        YieldController('IndexManager.checkUniqueConstraintsBatch');

    final schema = schemaOverride ??
        await _dataStore.tableMetaManager?.getTableSchema(table.tableUid);
    if (schema == null) {
      return List<UniqueViolation?>.filled(records.length, null,
          growable: false);
    }

    // Validation: If provided, changedFieldsMap must align by size (or be subset).
    if (changedFieldsMap != null && changedFieldsMap.length > records.length) {
      // Note: Map could be smaller if some records had no changes, but not larger.
      Logger.warn(
          'IndexManager.checkUniqueConstraintsBatch: changedFieldsMap size exceeds records length');
    }

    final bool isMemoryMode =
        _dataStore.config.persistenceMode == PersistenceMode.memory;

    final primaryKey = schema.primaryKey;
    final String? txId =
        transactionId ?? TransactionContext.getCurrentTransactionId();
    final writeBuf = _dataStore.writeBufferManager;
    final violations =
        List<UniqueViolation?>.filled(records.length, null, growable: false);
    List<List<String>?>? changedFieldsByRecord;
    if (isUpdate && changedFieldsMap != null) {
      changedFieldsByRecord =
          List<List<String>?>.filled(records.length, null, growable: false);
      final changedFieldsYield = YieldController(
        'IndexManager.checkUniqueConstraintsBatch.changedFields',
        checkInterval: 1024,
      );
      for (int i = 0; i < records.length; i++) {
        final y = changedFieldsYield.maybeYield();
        if (y != null) await y;
        final pk = records[i][primaryKey]?.toString();
        if (pk == null) {
          continue;
        }
        final changed = changedFieldsMap[pk];
        if (changed == null || changed.isEmpty) {
          continue;
        }
        changedFieldsByRecord[i] = changed.toList(growable: false);
      }
    }

    // 1) Primary key uniqueness (only for INSERTs with custom PKs).
    // 1) Primary key check (only if not an update of the same record)
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

          pkList.add(pk);
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

      if (pkList.isNotEmpty) {
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

    // 2) Unique indexes
    final uniqueIndexes =
        (_dataStore.tableMetaManager?.getUniqueIndexesFor(schema) ??
            const <IndexSchema>[]);
    if (uniqueIndexes.isEmpty) return violations;

    for (final idx in uniqueIndexes) {
      final indexUid = _indexUidFromSchema(idx);
      final indexLabel = IndexName(idx.actualIndexName);
      if (indexLabel.isEmpty) continue;
      final preparedEntries = await _prepareUniqueIndexEntriesBatch(
        schema: schema,
        index: idx,
        records: records,
        changedFieldsByRecord: changedFieldsByRecord,
      );

      // Skip this index entirely if no records have changes that impact it.
      bool hasPotentialCandidate = false;
      for (int i = 0; i < records.length; i++) {
        if (violations[i] != null) continue;
        if (preparedEntries[i].canonicalKey != null) {
          hasPotentialCandidate = true;
          break;
        }
      }
      if (!hasPotentialCandidate) continue;

      // Increment index weight for uniqueness check
      _dataStore.weightManager?.incrementAccess(
        WeightType.indexData,
        WeightManager.indexDataIdentifier(table.tableUid, indexUid),
        spaceName: _dataStore.currentSpaceName,
      );

      // 1. WriteBuffer check (uncommitted data) AND Intra-batch check
      final Map<dynamic, int> batchSeen = {};

      for (int i = 0; i < records.length; i++) {
        final y = yieldController.maybeYield();
        if (y != null) await y;
        if (violations[i] != null) continue;
        final canKey = preparedEntries[i].canonicalKey;
        if (canKey == null) continue;

        final r = records[i];
        final recordId = r[primaryKey]?.toString();

        // A) Intra-batch conflict check
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

        // B) WriteBuffer conflict check
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
          }
        }
      }

      // Memory mode: validate against committed in-memory index store and skip disk checks.
      if (isMemoryMode) {
        _registerIndexComparator(table, indexUid, schema);
        for (int i = 0; i < records.length; i++) {
          final y2 = yieldController.maybeYield();
          if (y2 != null) await y2;
          if (violations[i] != null) continue;
          final canKey = preparedEntries[i].canonicalKey;
          if (canKey == null) continue;

          final r = records[i];
          final recordId = r[primaryKey]?.toString();
          final vals = idx.fields.length == 1
              ? <dynamic>[canKey]
              : (canKey is List && canKey.length == idx.fields.length
                  ? List<dynamic>.from(canKey)
                  : null);
          if (vals == null) continue;

          final cacheKey = <dynamic>[table.tableUid, indexUid, ...vals];
          final existingPk = _indexDataCache.get(cacheKey);
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
        // Continue to next index (no disk path).
        continue;
      }

      // 2.2 Disk path using BinaryFuseFilter + grouped point lookups (existence-only).
      final meta = await getIndexMeta(table.tableUid, indexUid);
      if (meta == null || meta.isBuilding || meta.totalEntryCount <= 0) {
        // Fast path for brand new tables: if meta is missing or index is empty,
        // and the table data metadata also indicates 0 records, we can skip the heavy disk scan.
        final tableDataMeta =
            await _dataStore.tableDataManager.getTableDataMeta(table.tableUid);
        if (tableDataMeta == null || tableDataMeta.totalRecordCount <= 0) {
          // Verified empty table on disk; no persistent conflict possible.
          continue;
        }

        for (int i = 0; i < records.length; i++) {
          final y3 = yieldController.maybeYield();
          if (y3 != null) await y3;
          if (violations[i] != null) continue;
          final r = records[i];
          final recordId = r[primaryKey]?.toString();
          final canKey = preparedEntries[i].canonicalKey;
          if (canKey == null) continue;

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

      final recordIdxs = <int>[];
      final keyBytes = <Uint8List>[];

      for (int i = 0; i < records.length; i++) {
        final y4 = yieldController.maybeYield();
        if (y4 != null) await y4;
        if (violations[i] != null) continue;
        final encodedKeyBytes = preparedEntries[i].encodedKeyBytes;
        if (encodedKeyBytes == null) continue;

        keyBytes.add(encodedKeyBytes);
        recordIdxs.add(i);
      }

      if (keyBytes.isEmpty) continue;

      final exists =
          await _dataStore.indexTreePartitionManager?.existsUniqueKeysBatch(
                table: table,
                indexUid: indexUid,
                meta: meta,
                uniqueKeys: keyBytes,
              ) ??
              <bool>[];

      final List<int> positiveRecordIdxs = [];
      final List<Uint8List> positiveKeyBytes = [];
      for (int j = 0; j < exists.length; j++) {
        if (exists[j]) {
          positiveRecordIdxs.add(recordIdxs[j]);
          positiveKeyBytes.add(keyBytes[j]);
        }
      }

      if (positiveKeyBytes.isEmpty) continue;

      final existingPks = await _dataStore.indexTreePartitionManager
              ?.lookupUniquePrimaryKeysBatch(
            table: table,
            indexUid: indexUid,
            meta: meta,
            uniqueKeys: positiveKeyBytes,
          ) ??
          <String>[];

      for (int j = 0; j < positiveRecordIdxs.length; j++) {
        final i = positiveRecordIdxs[j];
        if (violations[i] != null) continue;

        final String? existingPk =
            j < existingPks.length ? existingPks[j] : null;

        if (existingPk != null && existingPk.isNotEmpty) {
          final recordId = records[i][primaryKey]?.toString();
          if (isUpdate && existingPk == recordId) continue;

          if (!_isPrimaryKeyHiddenByDeleteOverlay(
            table,
            existingPk,
            transactionId: txId,
          )) {
            final canKey = preparedEntries[i].canonicalKey;
            if (canKey == null) {
              continue;
            }
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

  /// One-time layout fix when opening a vector index with pre-uid on-disk paths.
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
    await _migrateLegacyMappingIndexDirectoriesIfNeeded(
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
        await _dataStore.pathManager.getIndexPath(table.tableUid, indexUid);
    final legacyPath = await _dataStore.pathManager
        .getIndexPath(table.tableUid, IndexUid(legacyLogicalName));
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

  /// Migrate vector nodeId->PK mapping B+Tree dirs from legacy logical names.
  Future<void> _migrateLegacyMappingIndexDirectoriesIfNeeded(
    TableContext table, {
    required IndexUid indexUid,
    required String legacyLogicalName,
  }) async {
    if (legacyLogicalName.isEmpty || legacyLogicalName == indexUid.value) {
      return;
    }

    for (final suffix in const ['__nid2pk', '__pk2nid']) {
      final stableUid = IndexUid('${indexUid.value}$suffix');
      final legacyUid = IndexUid('$legacyLogicalName$suffix');
      if (stableUid == legacyUid) continue;

      final stablePath =
          await _dataStore.pathManager.getIndexPath(table.tableUid, stableUid);
      final legacyPath =
          await _dataStore.pathManager.getIndexPath(table.tableUid, legacyUid);
      if (legacyPath == stablePath) continue;

      final legacyExists = await _dataStore.storage.existsDirectory(legacyPath);
      if (!legacyExists) continue;

      final stableExists = await _dataStore.storage.existsDirectory(stablePath);
      if (stableExists) {
        await _dataStore.storage.deleteDirectory(legacyPath);
      } else {
        await _dataStore.storage.moveDirectory(legacyPath, stablePath);
      }
    }
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
        if (ngh != null && ngh.totalSizeBytes != 0) {
          _dataStore.tableDataManager
              .applyIndexDataSizeDelta(table, -ngh.totalSizeBytes);
        }
      } else {
        final meta = await getIndexMeta(table.tableUid, resolved);
        if (meta != null && meta.totalSizeBytes != 0) {
          _dataStore.tableDataManager
              .applyIndexDataSizeDelta(table, -meta.totalSizeBytes);
        }
      }
    } catch (e) {
      Logger.warn(
          'Failed to adjust space index size for ${table.tableName}.${_indexLogLabel(table, resolved)}',
          rawError: e);
    }

    _invalidateIndexCache(table, resolved);

    try {
      final indexPath = await _dataStore.pathManager.getIndexPath(
        table.tableUid,
        resolved,
      );
      if (await _dataStore.storage.existsDirectory(indexPath)) {
        await _dataStore.storage.deleteDirectory(indexPath);
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
    // Snapshot inputs to allow yielding and avoid concurrent modification
    final insertsCopy = List<Map<String, dynamic>>.from(inserts);
    final updatesCopy = List<IndexRecordUpdate>.from(updates);
    final deletesCopy = List<Map<String, dynamic>>.from(deletes);
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
                inserts: insertsCopy,
                deletes: deletesCopy,
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

    // Budget for B+Tree indexes only.
    final bool hasExplicitBudget = (concurrency != null && concurrency > 0);
    final IndexWriteBudget? budget = hasExplicitBudget
        ? IoConcurrencyPlanner.planIndexWriteBudget(
            budgetTokens: concurrency,
            indexCount: btreeTargets.length,
            minPartitionTokensPerIndex:
                btreeTargets.any((i) => !i.unique) ? 2 : 1,
          )
        : null;

    final idxTasks = <Future<void> Function()>[];

    for (final idx in btreeTargets) {
      final indexUid = _indexUidFromSchema(idx);
      final indexName = idx.actualIndexName;
      // Skip indexes that are already fully flushed (used during recovery)
      if (skipIndexes != null && skipIndexes.contains(indexUid)) {
        continue;
      }
      idxTasks.add(() async {
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
          _indexMetaCache.put([tableUid, indexUid], meta);
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
          inserts: insertsCopy,
          deletes: deletesCopy,
          updates: updatesCopy,
        );

        if (deltas.isEmpty) {
          return;
        }
        await _dataStore.indexTreePartitionManager?.writeChanges(
          table: table,
          indexUid: indexUid,
          indexMeta: meta,
          deltas: deltas,
          batchContext: batchContext,
          // If caller provided a total token budget, we pass a per-index token cap.
          // Otherwise, let partition manager auto-acquire based on actual touched partitions.
          concurrency:
              hasExplicitBudget ? budget!.partitionTokensPerIndex : null,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
        );
      });
    }

    if (idxTasks.isEmpty) {
      if (vectorFuture != null) await vectorFuture;
      return;
    }

    // Execute B+Tree index tasks in parallel with the already-running vector future.
    final int idxLevelConcurrency =
        hasExplicitBudget ? min(idxTasks.length, budget!.indexConcurrency) : 1;

    // Dynamic timeout based on writeBatchSize AND maxPartitionFileSize.
    final int batchSize = _dataStore.config.writeBatchSize;
    final int maxFileSize = _dataStore.config.maxPartitionFileSize;
    final timeout = Duration(
        seconds: 30 + (batchSize / 50).ceil() + (maxFileSize ~/ (100 * 1024)));

    if (InternalConfig.showLoggerInternalLabel) {
      Logger.debug(
        'Index persistence: table=${table.tableName}, btreeIndexes=${idxTasks.length}, concurrency=$idxLevelConcurrency, timeout=$timeout',
      );
    }

    await ParallelProcessor.execute<void>(
      idxTasks,
      concurrency: idxLevelConcurrency,
      label: 'IndexManager.writeChanges',
      continueOnError: false,
      timeout: timeout,
    );

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
      // Ensure comparator is registered before cache access
      _registerIndexComparator(table, indexUid, schema);

      final meta = await getIndexMeta(table.tableUid, indexUid);
      if (meta == null) return IndexSearchResult.tableScan();
      var effectiveMeta = meta;
      final bool isMemoryMode =
          _dataStore.config.persistenceMode == PersistenceMode.memory;
      if (!isMemoryMode && effectiveMeta.isBuilding) {
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
        effectiveMeta = (await getIndexMeta(table.tableUid, indexUid)) ??
            effectiveMeta.copyWith(isBuilding: false);
      }
      // In memory mode, the primary index store is [_indexDataCache], so B+Tree
      // pointers/entry counts may be unset or stale. We still allow searching.
      if (!isMemoryMode &&
          (effectiveMeta.totalEntryCount <= 0 ||
              effectiveMeta.btreeFirstLeaf.isNull)) {
        final tableDataMeta =
            await _dataStore.tableDataManager.getTableDataMeta(
          table.tableUid,
        );
        final persistedTableRecords = tableDataMeta?.totalRecordCount ?? 0;
        if (persistedTableRecords > 0) {
          Logger.warn(
            'Index ${table.tableName}.'
            '${_indexLogLabel(table, indexUid, schema: schema)} '
            'appears empty while table has $persistedTableRecords persisted '
            'records; falling back to table scan (rebuild only via schema '
            'migration or key migration)',
          );
          return IndexSearchResult.tableScan();
        }
        return IndexSearchResult.empty();
      }

      Uint8List upperBoundExclusiveForPrefix(Uint8List prefix) {
        final out = Uint8List(prefix.length + 1 + 4);
        out.setRange(0, prefix.length, prefix);
        out[prefix.length] = 0xFF;
        return out;
      }

      final indexSchema = _findBtreeIndexSchema(schema, indexUid, table: table);
      if (indexSchema == null || indexSchema.fields.isEmpty) {
        return IndexSearchResult.tableScan();
      }
      final fields = indexSchema.fields;
      final bool isUnique = effectiveMeta.isUnique;
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
            final bufferId = _probeBufferForUniqueIndex(
              table,
              indexUid,
              last.value,
            );
            if (bufferId != null) {
              return IndexSearchResult(
                primaryKeys: [bufferId],
                entries: [
                  IndexSearchEntry(primaryKey: bufferId, keyBytes: prefix)
                ],
                indexWasUsed: true,
              );
            }
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
              final bufferId = _probeBufferForUniqueIndex(
                table,
                indexUid,
                item.$1,
              );
              if (bufferId != null) {
                out.add(bufferId);
                entriesOut.add(
                    IndexSearchEntry(primaryKey: bufferId, keyBytes: item.$2));
                if (remaining > 0) {
                  remaining--;
                  if (remaining <= 0) break;
                }
                continue;
              }
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
          final firstPercent = pattern.indexOf('%');
          final prefixEnd = (firstPercent > 0)
              ? firstPercent
              : (firstPercent == -1 && pattern.isNotEmpty ? pattern.length : 0);
          if (prefixEnd <= 0) {
            return IndexSearchResult.tableScan();
          }
          final fieldPrefix = pattern.substring(0, prefixEnd);

          String? incrementString(String s) {
            if (s.isEmpty) return null;
            final codeUnits = List<int>.from(s.codeUnits);
            for (int i = codeUnits.length - 1; i >= 0; i--) {
              if (codeUnits[i] < 0xFFFF) {
                codeUnits[i]++;
                return String.fromCharCodes(codeUnits);
              }
              codeUnits.removeLast();
            }
            return null;
          }

          final startPrefix = encodeCompositeValues(fieldPrefix);
          if (startPrefix == null) return IndexSearchResult.empty();

          final nextPrefix = incrementString(fieldPrefix);
          Uint8List endBound;
          if (nextPrefix != null) {
            final endPrefix = encodeCompositeValues(nextPrefix);
            if (endPrefix == null) return IndexSearchResult.empty();
            endBound = endPrefix;
          } else {
            final prefixUpper = encodePrefixUpperBound();
            if (prefixUpper == null) return IndexSearchResult.empty();
            endBound = prefixUpper;
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
            final val = _indexDataCache.get(compositePrefix);
            if (val == null) {
              // Memory mode must not fall back to disk; cache miss means "not found".
              return isMemoryMode ? IndexSearchResult.empty() : null;
            }
            if (val is String) {
              return IndexSearchResult(primaryKeys: [val]);
            }
            return IndexSearchResult.empty();
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
            // Sort PKs naturally (lexicographical for strings/encoded)
            pks.sort();
            if (reverse) {
              pks.sort((a, b) => b.compareTo(a));
            }

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
          // Memory mode: unique index must be served from _indexDataCache (already checked above).
          if (isMemoryMode) return IndexSearchResult.empty();

          final pk = await _lookupUniquePrimaryKeyLogical(
            table: table,
            indexUid: indexUid,
            meta: meta,
            uniqueKey: prefix,
          );
          if (pk == null) return IndexSearchResult.empty();
          if (_isPrimaryKeyHiddenByDeleteOverlay(table, pk)) {
            return IndexSearchResult.empty();
          }

          // Hotspot populate: Use Native Key (if not disabled)
          if (!(_dataStore.resourceManager?.isLowMemoryMode ?? false)) {
            _indexDataCache.put([table.tableUid, indexUid, ...nativeVal], pk);
          }

          return IndexSearchResult(primaryKeys: <String>[pk]);
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

        final validatedPks = <String>[];
        final validatedEntries =
            res.entries != null ? <IndexSearchEntry>[] : null;
        for (int i = 0; i < res.primaryKeys.length; i++) {
          final pk = res.primaryKeys[i];
          if (!_isPrimaryKeyHiddenByDeleteOverlay(table, pk)) {
            validatedPks.add(pk);
            if (validatedEntries != null) {
              validatedEntries.add(res.entries![i]);
            }
          }
        }

        if (limit == null && offset == null && !hasCursorKey) {
          // Hotspot populate (non-unique): cache one entry per visible PK.
          if (!(_dataStore.resourceManager?.isLowMemoryMode ?? false)) {
            final prefixKey = <dynamic>[table.tableUid, indexUid, ...nativeVal];
            final yc = YieldController('IndexManager.hotspotPopulateNonUnique');
            for (final pk in validatedPks) {
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

        return IndexSearchResult(
          primaryKeys: validatedPks,
          entries: validatedEntries,
          lastKey: res.lastKey,
          requiresTableScan: res.requiresTableScan,
          indexWasUsed: res.indexWasUsed,
        );
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
        return _searchIndexByKeyRangeLogical(
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

        return _searchIndexByKeyRangeLogical(
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

        final firstPercent = pattern.indexOf('%');
        final prefixEnd = (firstPercent > 0)
            ? firstPercent
            : (firstPercent == -1 && pattern.isNotEmpty ? pattern.length : 0);
        if (prefixEnd <= 0) {
          return IndexSearchResult.tableScan();
        }
        final prefix = pattern.substring(0, prefixEnd);

        String? incrementString(String s) {
          if (s.isEmpty) return null;
          final codeUnits = List<int>.from(s.codeUnits);
          for (int i = codeUnits.length - 1; i >= 0; i--) {
            if (codeUnits[i] < 0xFFFF) {
              codeUnits[i]++;
              return String.fromCharCodes(codeUnits);
            }
            codeUnits.removeLast();
          }
          return null;
        }

        // Single-field index: encode full key. Composite: encode first field only for range.
        Uint8List? startBytes = encodePrefix(prefix);
        Uint8List? endBytes;
        if (prefix.isNotEmpty) {
          final nextPrefix = incrementString(prefix);
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
            if (prefix.isNotEmpty) {
              final nextPrefix = incrementString(prefix);
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

              // Memory mode: serve unique lookup from _indexDataCache only (no disk fallback).
              if (isMemoryMode) {
                final compositeKey = <dynamic>[
                  table.tableUid,
                  indexUid,
                  ...nativeVal
                ];
                final pkValue = _indexDataCache.get(compositeKey);
                if (pkValue is String &&
                    pkValue.isNotEmpty &&
                    !_isPrimaryKeyHiddenByDeleteOverlay(table, pkValue)) {
                  out.add(pkValue);
                  entriesOut.add(
                      IndexSearchEntry(primaryKey: pkValue, keyBytes: prefix));
                } else if (pkValue is String && pkValue.isNotEmpty) {
                  _indexDataCache.remove(compositeKey);
                }
              } else {
                final pk = await _lookupUniquePrimaryKeyLogical(
                  table: table,
                  indexUid: indexUid,
                  meta: meta,
                  uniqueKey: prefix,
                );
                if (pk != null) {
                  if (!_isPrimaryKeyHiddenByDeleteOverlay(table, pk)) {
                    out.add(pk);
                    entriesOut.add(
                        IndexSearchEntry(primaryKey: pk, keyBytes: prefix));
                    if (!(_dataStore.resourceManager?.isLowMemoryMode ??
                        false)) {
                      final compositeKey = [
                        table.tableUid,
                        indexUid,
                        ...nativeVal
                      ];
                      _indexDataCache.put(compositeKey, pk);
                    }
                  }
                }
              }
            } else {
              // Range Scan
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

              // Hotspot populate: Populate cache if we did a full bucket scan (no cursor)
              if (!usedCache &&
                  !hasCursorKey &&
                  !(_dataStore.resourceManager?.isLowMemoryMode ?? false)) {
                final validatedPks = <String>[];
                final validatedEntries =
                    res.entries != null ? <IndexSearchEntry>[] : null;
                for (int i = 0; i < res.primaryKeys.length; i++) {
                  final pk = res.primaryKeys[i];
                  if (!_isPrimaryKeyHiddenByDeleteOverlay(table, pk)) {
                    validatedPks.add(pk);
                    if (validatedEntries != null) {
                      validatedEntries.add(res.entries![i]);
                    }
                  }
                }

                if (validatedPks.isNotEmpty) {
                  if (isUnique) {
                    _indexDataCache.put(
                        [table.tableUid, indexUid, ...nativeVal],
                        validatedPks.first);
                  } else {
                    final prefixKey = <dynamic>[
                      table.tableUid,
                      indexUid,
                      ...nativeVal
                    ];
                    final yc = YieldController(
                        'IndexManager.hotspotPopulateNonUniqueIn');
                    for (final pk in validatedPks) {
                      final y8 = yc.maybeYield();
                      if (y8 != null) await y8;
                      _indexDataCache.put(
                        <dynamic>[...prefixKey, pk],
                        true,
                        size: pk.length + 1,
                      );
                    }
                  }
                }
                out.addAll(validatedPks);
                if (validatedEntries != null) {
                  entriesOut.addAll(validatedEntries);
                }
              } else {
                // Filter logically deleted records for results consistency
                for (int i = 0; i < res.primaryKeys.length; i++) {
                  final pk = res.primaryKeys[i];
                  if (!_isPrimaryKeyHiddenByDeleteOverlay(table, pk)) {
                    out.add(pk);
                    if (res.entries != null) {
                      entriesOut.add(res.entries![i]);
                    }
                  }
                }
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
    _indexFieldMatchers.clear();
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
    _indexFieldMatchers.clear();
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
