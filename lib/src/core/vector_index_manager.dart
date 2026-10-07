import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../handler/common.dart';
import '../handler/logger.dart';
import '../handler/platform_handler.dart';
import '../model/index_entry.dart';
import '../model/ngh_index_meta.dart';
import '../model/parallel_journal_entry.dart';
import '../model/query_result.dart';
import '../model/table_context.dart';
import '../model/table_identity.dart';
import '../model/table_schema.dart';
import 'data_store_impl.dart';
import 'ngh_graph_engine.dart';
import 'ngh_page.dart';
import 'ngh_partition_manager.dart';
import 'resource_manager.dart';
import 'vector_cache.dart';
import 'vector_quantizer.dart';
import 'workload_scheduler.dart';
import 'yield_controller.dart';
import '../upgrades/legacy_ngh/legacy_ngh_io.dart';
import '../upgrades/legacy_ngh/legacy_ngh_search.dart';

/// Manages all NGH vector indexes for the data store.
class VectorIndexManager {
  final DataStoreImpl _dataStore;

  late final NghPartitionManager _partitionManager;
  late final NghGraphEngine _graphEngine;
  NghGraphEngine get graphEngine => _graphEngine;
  late final LegacyNghIo _legacyIo;
  late final LegacyNghSearch _legacySearch;
  late final VectorCache _vectorCache;

  /// In-flight meta loads -- prevents parallel readers from each hitting disk.
  /// Key: "$tableUid/$indexUid", value: the single in-progress Future.
  final Map<String, Future<NghIndexMeta?>> _metaLoadingFutures = {};

  /// Pending-delete PK sets while PK locator backfill is incomplete.
  final Map<String, Set<String>> _pendingDeleteCache = {};

  /// Hot field → vector indexUid resolution cache.
  /// Key: "$tableUid/$fieldName"
  final Map<String, IndexUid?> _fieldIndexUidCache = {};

  /// Last applied budgets; skip reconfigure when ResourceManager re-syncs
  /// with unchanged thresholds.
  int? _lastSyncedIndexBudget;
  int? _lastSyncedVectorBudget;
  int? _lastSyncedNavBudget;
  int? _lastSyncedLeafBudget;

  VectorIndexManager(this._dataStore) {
    _partitionManager = NghPartitionManager(_dataStore);
    _graphEngine = NghGraphEngine(_partitionManager);
    _legacyIo = LegacyNghIo(_dataStore);
    _legacySearch = LegacyNghSearch(_legacyIo);
    _vectorCache = VectorCache();
    syncVectorSearchCacheBudget();
  }

  int _resolveIndexCacheBudget() {
    final sized = _dataStore.resourceManager?.getIndexCacheSize() ?? 0;
    if (sized > 0) return sized;
    return 128 * 1024 * 1024;
  }

  /// SQ8 search-hot leaf cache budget.
  ///
  /// Anchors to [vectorCacheBudgetRatio] (default 50%) of the total memory
  /// threshold. Floor 64MB matches the former configure-side lift so engine
  /// apply can take the resolved value as-is.
  int _resolveVectorLeafCacheBudget() {
    final totalBudgetMB = _dataStore.resourceManager?.memoryThresholdInMB ?? 0;
    final resolvedMB = totalBudgetMB > 0
        ? totalBudgetMB
        : (_dataStore.config.cacheMemoryBudgetMB ?? 1024);
    final ratio =
        (_dataStore.config.vectorCacheBudgetRatio ?? 0.50).clamp(0.10, 0.85);
    final targetBytes = (resolvedMB * 1024 * 1024 * ratio).round();
    return max(64 * 1024 * 1024, targetBytes);
  }

  /// Resolve navigating centroid graph cache budget from [vectorBudget].
  ///
  /// Legacy flat nav_graph may stay fully resident under this budget.
  /// Paged Centroid B+Tree keeps only L0 roots always-hot; L1 internal pages
  /// share this budget via an LRU page cache so billion-scale indexes do not
  /// OOM from full-chain residency.
  /// Platform floor: 32MB mobile / 128MB desktop; absolute floor 64MB.
  /// Dynamically expands to ~15% of the vector cache budget.
  int _resolveNavGraphCacheBudget(int vectorBudget) {
    final platformFloor =
        PlatformHandler.isMobile ? 32 * 1024 * 1024 : 128 * 1024 * 1024;
    final targetBytes = (vectorBudget * 0.15).round();
    return max(64 * 1024 * 1024, max(platformFloor, targetBytes));
  }

  /// Re-apply cache ceilings after ResourceManager computes real quotas.
  ///
  /// Vector ANN must not inherit only `indexCache * 30%` — that thrashs the
  /// leaf I/O layer after a few tens of thousands of inserts. Leaf I/O fill
  /// and search-hot leaves share the dedicated vector budget from
  /// [vectorCacheBudgetRatio].
  void syncVectorSearchCacheBudget() {
    final indexBudget = _resolveIndexCacheBudget();
    final vectorBudget = _resolveVectorLeafCacheBudget();
    final navBudget = _resolveNavGraphCacheBudget(vectorBudget);
    // Leaf I/O fill layer: max(index*30%, vector*45%) so paged search survives
    // large insert bursts without immediate TreeCache eviction.
    final leafBudget = max(
      (indexBudget * 0.30).round(),
      (vectorBudget * 0.45).round(),
    );
    if (_lastSyncedIndexBudget == indexBudget &&
        _lastSyncedVectorBudget == vectorBudget &&
        _lastSyncedNavBudget == navBudget &&
        _lastSyncedLeafBudget == leafBudget) {
      return;
    }
    _lastSyncedIndexBudget = indexBudget;
    _lastSyncedVectorBudget = vectorBudget;
    _lastSyncedNavBudget = navBudget;
    _lastSyncedLeafBudget = leafBudget;

    _graphEngine.configureVectorSearchCacheBudget(vectorBudget);
    _graphEngine.configureNavGraphCacheBudget(navBudget);
    _legacySearch.configureClusterCacheBudget(vectorBudget);
    _partitionManager.syncCacheBudget(
      indexBudget: indexBudget,
      vectorLeafBudget: leafBudget,
    );
  }

  IndexUid? _resolveVectorIndexUid(TableContext table, String fieldName) {
    final cacheKey = '${table.tableUid.value}/$fieldName';
    if (_fieldIndexUidCache.containsKey(cacheKey)) {
      return _fieldIndexUidCache[cacheKey];
    }
    final vectorIndexes =
        _dataStore.tableMetaManager?.getVectorIndexesFor(table.schema) ??
            const <IndexSchema>[];
    IndexUid? resolved;
    for (final idx in vectorIndexes) {
      if (idx.fields.contains(fieldName)) {
        resolved = idx.indexUid;
        break;
      }
    }
    _fieldIndexUidCache[cacheKey] = resolved;
    return resolved;
  }

  ({List<Float32List> vectors, List<String> primaryKeys})
      _prepareInsertVectorsBatch({
    required List<Map<String, dynamic>> records,
    required String fieldName,
    required String primaryKeyField,
    required int dimensions,
  }) {
    if (records.isEmpty) {
      return (vectors: const <Float32List>[], primaryKeys: const <String>[]);
    }

    final vectors = <Float32List>[];
    final primaryKeys = <String>[];

    for (int i = 0; i < records.length; i++) {
      final record = records[i];
      final rawVec = record[fieldName];
      final pk = record[primaryKeyField]?.toString();
      if (rawVec == null || pk == null) continue;

      final Float32List f32;
      if (rawVec is VectorData) {
        f32 = _toFloat32(rawVec.values, dimensions);
      } else if (rawVec is Float32List) {
        f32 = rawVec.length == dimensions
            ? rawVec
            : _toFloat32(rawVec, dimensions);
      } else if (rawVec is List) {
        f32 = _toFloat32(rawVec, dimensions);
      } else {
        continue;
      }

      vectors.add(f32);
      primaryKeys.add(pk);
    }

    return (vectors: vectors, primaryKeys: primaryKeys);
  }

  // =====================================================================
  // Write Changes -- Called by ParallelJournalManager during flush
  // =====================================================================

  /// Apply vector index changes for a table during the flush pipeline.
  ///
  /// Extracts vector fields from records, encodes them, inserts into the
  /// NGH graph, and flushes dirty pages to disk -- all batched.
  Future<void> writeChanges({
    required TableContext table,
    List<Map<String, dynamic>> inserts = const [],
    List<IndexRecordUpdate> updates = const [],
    List<Map<String, dynamic>> deletes = const [],
    BatchContext? batchContext,
    int? concurrency,
    TableSchema? schemaOverride,
    List<IndexSchema>? targetIndexesOverride,
  }) async {
    final schema = schemaOverride ??
        await _dataStore.tableMetaManager?.getTableSchema(table.tableUid);
    if (schema == null) return;

    final vectorIndexes = List<IndexSchema>.from(
      targetIndexesOverride?.where((index) => index.type == IndexType.vector) ??
          (_dataStore.tableMetaManager?.getVectorIndexesFor(schema) ??
              const <IndexSchema>[]),
    );
    if (vectorIndexes.isEmpty) return;
    final pkName = schema.primaryKey;

    final yc = YieldController(
      'VectorIndexManager.writeChanges',
      checkInterval: 30,
      budgetMs: 50,
    );

    for (final idx in vectorIndexes) {
      final y4 = yc.maybeYield();
      if (y4 != null) await y4;
      final indexLogName = idx.actualIndexName;
      final sw = Stopwatch()..start();
      var graphDeleteMs = 0;
      var graphInsertMs = 0;
      var persistMs = 0;
      var promoteMs = 0;
      var persistMetaMs = 0;
      var pkBackfillMs = 0;
      var batchDeletes = 0;
      var batchInserts = 0;
      var dirtyLeaves = 0;
      var dirtyNav = 0;
      var dirtyPkmap = 0;
      final indexUid = idx.indexUid;
      final fieldName = idx.fields.first; // vector index is single-field
      FieldSchema? fieldSchema;
      try {
        fieldSchema = schema.fields.firstWhere((f) => f.name == fieldName);
      } catch (_) {
        continue;
      }

      var meta =
          await _getOrCreateMeta(table, indexUid, fieldName, fieldSchema, idx);

      final insertRecords = <Map<String, dynamic>>[...inserts];
      final deleteRecords = <Map<String, dynamic>>[...deletes];
      for (final update in updates) {
        final changed = update.changedFields;
        final fieldChanged = changed == null ||
            changed.contains(fieldName) ||
            changed.contains(pkName);
        if (!fieldChanged) continue;
        final oldRow = <String, dynamic>{
          ...?update.oldValues,
          pkName: update.primaryKey,
        };
        deleteRecords.add(oldRow);
        insertRecords.add({
          ...?update.oldValues,
          ...update.newValues,
          pkName: update.primaryKey,
        });
      }

      if (deleteRecords.isNotEmpty) {
        final deletePks = <String>[];
        for (final row in deleteRecords) {
          final pk = row[pkName]?.toString();
          if (pk != null && pk.isNotEmpty) deletePks.add(pk);
        }
        if (deletePks.isNotEmpty) {
          batchDeletes = deletePks.length;
          Future<void> flushDelete() async {
            var liveMeta = _vectorCache.getMeta(table, indexUid) ?? meta;
            final phase = Stopwatch()..start();
            final result = await _graphEngine.deleteBatch(
              table: table,
              indexUid: indexUid,
              meta: liveMeta,
              primaryKeys: deletePks,
            );
            graphDeleteMs += phase.elapsedMilliseconds;
            dirtyLeaves += result.dirtyLeafPages.length;
            dirtyNav += result.dirtyNavPages.length +
                result.dirtyNavBTreePages.length +
                (result.dirtyNavRootPage != null ? 1 : 0);
            dirtyPkmap += result.dirtyPkmapPages.length;
            meta = result.meta;
            if (result.unresolvedPks.isNotEmpty) {
              await _mergePendingDeletes(table, indexUid, result.unresolvedPks);
            }
            phase.reset();
            phase.start();
            meta = await _partitionManager.writeChanges(
              table: table,
              indexUid: indexUid,
              meta: meta,
              dirtyLeafPages: result.dirtyLeafPages,
              dirtyNavPages: result.dirtyNavPages,
              dirtyNavBTreePages: result.dirtyNavBTreePages,
              dirtyNavRootPage: result.dirtyNavRootPage,
              dirtyPkmapPages: result.dirtyPkmapPages,
              deleteLegacyNavGraph: result.deleteLegacyNavGraph,
              vectorsDelta: -result.deletedCount,
              deletedDelta: result.deletedCount,
              batchContext: batchContext,
              concurrency: concurrency,
            );
            persistMs += phase.elapsedMilliseconds;
          }

          await flushDelete();
        }
      }

      if (insertRecords.isNotEmpty) {
        final preparedVectors = _prepareInsertVectorsBatch(
          records: insertRecords,
          fieldName: fieldName,
          primaryKeyField: pkName,
          dimensions: meta.dimensions,
        );
        final vectors = preparedVectors.vectors;
        final pks = preparedVectors.primaryKeys;

        if (vectors.isNotEmpty) {
          batchInserts = vectors.length;
          Future<void> flushInsert() async {
            var liveMeta = _vectorCache.getMeta(table, indexUid) ?? meta;
            final phase = Stopwatch()..start();
            final insertResult = await _graphEngine.insertBatch(
              table: table,
              indexUid: indexUid,
              meta: liveMeta,
              vectors: vectors,
              primaryKeys: pks,
              yieldBudgetMs: 100,
            );
            graphInsertMs += phase.elapsedMilliseconds;
            dirtyLeaves += insertResult.dirtyLeafPages.length;
            dirtyNav += insertResult.dirtyNavPages.length +
                insertResult.dirtyNavBTreePages.length +
                (insertResult.dirtyNavRootPage != null ? 1 : 0);
            dirtyPkmap += insertResult.dirtyPkmapPages.length;
            meta = insertResult.meta;
            phase.reset();
            phase.start();
            meta = await _partitionManager.writeChanges(
              table: table,
              indexUid: indexUid,
              meta: meta,
              dirtyLeafPages: insertResult.dirtyLeafPages,
              dirtyNavPages: insertResult.dirtyNavPages,
              dirtyNavBTreePages: insertResult.dirtyNavBTreePages,
              dirtyNavRootPage: insertResult.dirtyNavRootPage,
              dirtyPkmapPages: insertResult.dirtyPkmapPages,
              deleteLegacyNavGraph: insertResult.deleteLegacyNavGraph,
              vectorsDelta: insertResult.insertedCount,
              concurrency: concurrency,
              batchContext: batchContext,
            );
            persistMs += phase.elapsedMilliseconds;
            await _removePendingDeletes(table, indexUid, pks);
            if (!_dataStore.shouldAbortBackgroundScan &&
                (insertResult.dirtyLeafPages.isNotEmpty ||
                    insertResult.dirtyNavBTreePages.isNotEmpty ||
                    insertResult.touchedNavPages.isNotEmpty)) {
              phase.reset();
              phase.start();
              await _graphEngine.promotePagedLeavesAfterInsert(
                table: table,
                indexUid: indexUid,
                meta: meta,
                dirtyLeafPages: insertResult.dirtyLeafPages,
                dirtyNavBTreePages: insertResult.dirtyNavBTreePages,
                touchedNavPages: insertResult.touchedNavPages,
                shouldAbort: () => _dataStore.shouldAbortBackgroundScan,
              );
              promoteMs += phase.elapsedMilliseconds;
            }
          }

          await flushInsert();
        }
      }

      if (!meta.hasPkLocator) {
        final phase = Stopwatch()..start();
        meta = await _runPkBackfill(
          table,
          indexUid,
          meta,
          batchContext: batchContext,
        );
        pkBackfillMs += phase.elapsedMilliseconds;
      }

      final persistMetaPhase = Stopwatch()..start();
      await _persistMeta(table, indexUid, meta, batchContext: batchContext);
      persistMetaMs += persistMetaPhase.elapsedMilliseconds;
      _vectorCache.putMeta(table, indexUid, meta);

      if (InternalConfig.showLoggerInternalLabel &&
          (batchInserts > 0 ||
              batchDeletes > 0 ||
              persistMs > 0 ||
              pkBackfillMs > 0)) {
        final now = DateTime.now();
        final at =
            '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${now.millisecond.toString().padLeft(3, '0')}';
        Logger.debug(
            'Vector persistence: table=${table.tableName}, index=$indexLogName, partitions=${meta.leafPartitionCount}, batchInserts=$batchInserts, batchDeletes=$batchDeletes, dirtyPages=leaves=$dirtyLeaves/nav=$dirtyNav/pkmap=$dirtyPkmap, totalVectors=${meta.totalVectors}, totalSize=${(meta.totalSizeBytes / 1024 / 1024).toStringAsFixed(2)}MB, concurrency=${concurrency ?? 1}, graphDelete=${graphDeleteMs}ms, graphInsert=${graphInsertMs}ms, persist=${persistMs}ms, promote=${promoteMs}ms, pkBackfill=${pkBackfillMs}ms, persistMeta=${persistMetaMs}ms, cost=${sw.elapsedMilliseconds}ms, at: $at');
      }
    }
  }

  // =====================================================================
  // Memory mode -- cache-only apply (no writeChanges / no disk)
  // =====================================================================

  /// Apply vector mutations directly into search-resident caches.
  ///
  /// Pure memory mode never runs the flush pipeline, so [writeChanges] never
  /// lands pages/meta. Callers must gate with
  /// [TableMetaManager.hasVectorIndexes] before entering this branch.
  Future<void> applyMemoryChanges({
    required TableContext table,
    List<Map<String, dynamic>> inserts = const [],
    List<IndexRecordUpdate> updates = const [],
    List<Map<String, dynamic>> deletes = const [],
    TableSchema? schemaOverride,
  }) async {
    if (inserts.isEmpty && updates.isEmpty && deletes.isEmpty) return;

    final schema = schemaOverride ?? table.schema;
    final vectorIndexes =
        _dataStore.tableMetaManager?.getVectorIndexesFor(schema) ??
            const <IndexSchema>[];
    if (vectorIndexes.isEmpty) return;

    final pkName = schema.primaryKey;

    for (final idx in vectorIndexes) {
      final indexUid = idx.indexUid;
      final fieldName = idx.fields.first;
      FieldSchema? fieldSchema;
      try {
        fieldSchema = schema.fields.firstWhere((f) => f.name == fieldName);
      } catch (_) {
        continue;
      }

      var meta =
          _getOrCreateMetaSync(table, indexUid, fieldName, fieldSchema, idx);

      final insertRecords = <Map<String, dynamic>>[...inserts];
      final deleteRecords = <Map<String, dynamic>>[...deletes];
      for (final update in updates) {
        final changed = update.changedFields;
        final fieldChanged = changed == null ||
            changed.contains(fieldName) ||
            changed.contains(pkName);
        if (!fieldChanged) continue;
        final oldRow = <String, dynamic>{
          ...?update.oldValues,
          pkName: update.primaryKey,
        };
        deleteRecords.add(oldRow);
        insertRecords.add({
          ...?update.oldValues,
          ...update.newValues,
          pkName: update.primaryKey,
        });
      }

      if (deleteRecords.isNotEmpty) {
        final deletePks = <String>[];
        for (final row in deleteRecords) {
          final pk = row[pkName]?.toString();
          if (pk != null && pk.isNotEmpty) deletePks.add(pk);
        }
        if (deletePks.isNotEmpty) {
          var liveMeta = _vectorCache.getMeta(table, indexUid) ?? meta;
          final result = await _graphEngine.deleteBatch(
            table: table,
            indexUid: indexUid,
            meta: liveMeta,
            primaryKeys: deletePks,
          );
          meta = result.meta;
          if (result.unresolvedPks.isNotEmpty) {
            _mergePendingDeletesMemory(
              table.tableUid,
              indexUid,
              result.unresolvedPks,
            );
          }
          meta = _partitionManager.applyDirtyPagesToCache(
            table: table,
            indexUid: indexUid,
            meta: meta,
            dirtyLeafPages: result.dirtyLeafPages,
            dirtyNavPages: result.dirtyNavPages,
            dirtyPkmapPages: result.dirtyPkmapPages,
            vectorsDelta: -result.deletedCount,
            deletedDelta: result.deletedCount,
          );
          if (result.dirtyLeafPages.isNotEmpty ||
              result.dirtyNavBTreePages.isNotEmpty) {
            _graphEngine.promotePagedLeavesAfterInsertSync(
              table: table,
              indexUid: indexUid,
              meta: meta,
              dirtyLeafPages: result.dirtyLeafPages,
              dirtyNavBTreePages: result.dirtyNavBTreePages,
            );
          }
          _vectorCache.putMeta(table, indexUid, meta);
        }
      }

      if (insertRecords.isNotEmpty) {
        final prepared = _prepareInsertVectorsBatch(
          records: insertRecords,
          fieldName: fieldName,
          primaryKeyField: pkName,
          dimensions: meta.dimensions,
        );
        if (prepared.vectors.isNotEmpty) {
          var liveMeta = _vectorCache.getMeta(table, indexUid) ?? meta;
          final insertResult = await _graphEngine.insertBatch(
            table: table,
            indexUid: indexUid,
            meta: liveMeta,
            vectors: prepared.vectors,
            primaryKeys: prepared.primaryKeys,
            yieldBudgetMs: 100,
          );
          meta = insertResult.meta;
          meta = _partitionManager.applyDirtyPagesToCache(
            table: table,
            indexUid: indexUid,
            meta: meta,
            dirtyLeafPages: insertResult.dirtyLeafPages,
            dirtyNavPages: insertResult.dirtyNavPages,
            dirtyPkmapPages: insertResult.dirtyPkmapPages,
            vectorsDelta: insertResult.insertedCount,
          );
          if (insertResult.dirtyLeafPages.isNotEmpty ||
              insertResult.dirtyNavBTreePages.isNotEmpty ||
              insertResult.touchedNavPages.isNotEmpty) {
            _graphEngine.promotePagedLeavesAfterInsertSync(
              table: table,
              indexUid: indexUid,
              meta: meta,
              dirtyLeafPages: insertResult.dirtyLeafPages,
              dirtyNavBTreePages: insertResult.dirtyNavBTreePages,
              touchedNavPages: insertResult.touchedNavPages,
            );
          }
          _removePendingDeletesMemory(
            table.tableUid,
            indexUid,
            prepared.primaryKeys,
          );
          _vectorCache.putMeta(table, indexUid, meta);
        }
      }
    }
  }

  /// Cache-only meta create for pure memory mode (never touches disk).
  NghIndexMeta _getOrCreateMetaSync(
    TableContext table,
    IndexUid indexUid,
    String fieldName,
    FieldSchema fieldSchema,
    IndexSchema idx,
  ) {
    var meta = _vectorCache.getMeta(table, indexUid);
    if (meta != null) {
      final sized = _withPageSizes(meta);
      if (!identical(sized, meta)) {
        _vectorCache.putMeta(table, indexUid, sized);
      }
      return sized;
    }

    final dims = fieldSchema.vectorConfig?.dimensions ?? 128;
    final vc = idx.vectorConfig;
    meta = _withPageSizes(NghIndexMeta.createEmpty(
      indexUid: indexUid,
      tableUid: table.tableUid,
      dimensions: dims,
      distanceMetric: vc?.distanceMetric ?? VectorDistanceMetric.cosine,
    ));
    _vectorCache.putMeta(table, indexUid, meta);
    return meta;
  }

  void _mergePendingDeletesMemory(
    TableUid tableUid,
    IndexUid indexUid,
    List<String> extra,
  ) {
    if (extra.isEmpty) return;
    final cacheKey = _pendingKey(tableUid, indexUid);
    final current = _pendingDeleteCache.putIfAbsent(cacheKey, () => <String>{});
    current.addAll(extra);
  }

  void _removePendingDeletesMemory(
    TableUid tableUid,
    IndexUid indexUid,
    List<String> pks,
  ) {
    if (pks.isEmpty) return;
    final cacheKey = _pendingKey(tableUid, indexUid);
    final current = _pendingDeleteCache[cacheKey];
    if (current == null || current.isEmpty) return;
    for (final pk in pks) {
      current.remove(pk);
    }
  }

  // =====================================================================
  // vectorSearch -- Public Search API
  // =====================================================================

  /// Perform approximate nearest neighbor search on a vector field.
  ///
  /// Returns the top-[topK] most similar records, sorted by similarity.
  Future<List<VectorSearchResult>> vectorSearch({
    required TableContext table,
    required String fieldName,
    required VectorData queryVector,
    int topK = 10,
    int? searchDepth,
    double? distanceThreshold,
  }) {
    final indexUid = _resolveVectorIndexUid(table, fieldName);
    if (indexUid == null) {
      return Future<List<VectorSearchResult>>.value(const []);
    }

    var meta = _vectorCache.getMeta(table, indexUid);
    if (meta == null) {
      return _vectorSearchCold(
        table: table,
        fieldName: fieldName,
        indexUid: indexUid,
        queryVector: queryVector,
        topK: topK,
        searchDepth: searchDepth,
        distanceThreshold: distanceThreshold,
      );
    }
    if (meta.isBuilding) {
      return _vectorSearchLegacy(
        table: table,
        indexUid: indexUid,
        queryVector: queryVector,
        topK: topK,
        searchDepth: searchDepth,
        distanceThreshold: distanceThreshold,
      );
    }
    if (meta.totalVectors == 0) {
      return Future<List<VectorSearchResult>>.value(const []);
    }
    if (!_graphEngine.isNavGraphCached(table, indexUid, meta: meta)) {
      return _vectorSearchCold(
        table: table,
        fieldName: fieldName,
        indexUid: indexUid,
        queryVector: queryVector,
        topK: topK,
        searchDepth: searchDepth,
        distanceThreshold: distanceThreshold,
      );
    }

    final queryF32 = _queryAsFloat32(queryVector, meta.dimensions);
    // Let the engine normalize into scratch (no alloc here).

    Set<String>? pending;
    if (!meta.hasPkLocator) {
      final cacheKey = _pendingKey(table.tableUid, indexUid);
      pending = _pendingDeleteCache[cacheKey];
      if (pending == null) {
        // Do not force cold forever: pending load is only needed for deletes.
        // Empty set keeps searchHotSync; cold path can hydrate deletes later.
        pending = const <String>{};
        _pendingDeleteCache[cacheKey] = pending;
      }
    }

    // Sync hot path: one Future.value after mapping (no .then microtask chain).
    final hot = _graphEngine.searchHotSync(
      table: table,
      indexUid: indexUid,
      meta: meta,
      query: queryF32,
      topK: topK,
      searchDepth: searchDepth,
      distanceThreshold: distanceThreshold,
      queryAlreadyNormalized: false,
      pendingDeletePks: pending,
    );
    if (hot != null) {
      if (hot.isEmpty) {
        return Future<List<VectorSearchResult>>.value(const []);
      }
      final metric = meta.distanceMetric;
      final entries = <VectorSearchResult>[];
      for (final r in hot) {
        final pk = r.primaryKey;
        if (pk == null || pk.isEmpty) continue;
        entries.add(VectorSearchResult(
          primaryKey: pk,
          distance: r.distance,
          score: _distanceToScore(r.distance, metric),
        ));
      }
      return Future<List<VectorSearchResult>>.value(entries);
    }

    return _vectorSearchCold(
      table: table,
      fieldName: fieldName,
      indexUid: indexUid,
      queryVector: queryVector,
      topK: topK,
      searchDepth: searchDepth,
      distanceThreshold: distanceThreshold,
    );
  }

  Future<List<VectorSearchResult>> _vectorSearchCold({
    required TableContext table,
    required String fieldName,
    required IndexUid indexUid,
    required VectorData queryVector,
    required int topK,
    int? searchDepth,
    double? distanceThreshold,
  }) async {
    var meta = _vectorCache.getMeta(table, indexUid);
    meta ??= await _loadMeta(table, indexUid);
    if (meta == null || meta.isBuilding) {
      return _vectorSearchLegacy(
        table: table,
        indexUid: indexUid,
        queryVector: queryVector,
        topK: topK,
        searchDepth: searchDepth,
        distanceThreshold: distanceThreshold,
      );
    }
    if (meta.totalVectors == 0) {
      return const [];
    }
    if (!_graphEngine.isNavGraphCached(table, indexUid, meta: meta)) {
      await _graphEngine.prefetchNavGraph(table, indexUid, meta: meta);
    }

    final queryF32 = _queryAsFloat32(queryVector, meta.dimensions);

    final pending =
        meta.hasPkLocator ? null : await _loadPendingDeletes(table, indexUid);
    final results = await _graphEngine.search(
      table: table,
      indexUid: indexUid,
      meta: meta,
      query: queryF32,
      topK: topK,
      searchDepth: searchDepth,
      distanceThreshold: distanceThreshold,
      queryAlreadyNormalized: false,
      pendingDeletePks: pending,
    );
    if (results.isEmpty) {
      return const [];
    }

    final entries = <VectorSearchResult>[];
    for (final r in results) {
      final pk = r.primaryKey;
      if (pk == null || pk.isEmpty) continue;
      entries.add(VectorSearchResult(
        primaryKey: pk,
        distance: r.distance,
        score: _distanceToScore(r.distance, meta.distanceMetric),
      ));
    }
    return entries;
  }

  Future<List<VectorSearchResult>> _vectorSearchLegacy({
    required TableContext table,
    required IndexUid indexUid,
    required VectorData queryVector,
    required int topK,
    int? searchDepth,
    double? distanceThreshold,
  }) async {
    if (!await _legacyIo.hasOldIndex(table, indexUid)) {
      return const [];
    }
    final meta = await _legacyIo.readMeta(table, indexUid);
    if (meta == null || meta.totalVectors <= 0) {
      return const [];
    }
    final queryF32 = _queryAsFloat32(queryVector, meta.dimensions);
    final results = await _legacySearch.search(
      table: table,
      indexUid: indexUid,
      meta: meta,
      query: queryF32,
      topK: topK,
      searchDepth: searchDepth,
      distanceThreshold: distanceThreshold,
    );
    if (results.isEmpty) return const [];
    final entries = <VectorSearchResult>[];
    for (final r in results) {
      final pk = r.primaryKey;
      if (pk == null || pk.isEmpty) continue;
      entries.add(VectorSearchResult(
        primaryKey: pk,
        distance: r.distance,
        score: _distanceToScore(r.distance, meta.distanceMetric),
      ));
    }
    return entries;
  }

  /// Prewarm vector index meta, nav, and leaves into search-hot caches.
  ///
  /// **Open / explicit prewarm only** (Phase 2 of DataStore cache prewarm).
  /// Always runs on open (including large spaces that skip row/index warm).
  /// Default ceiling is the dedicated vector compact budget from
  /// [vectorCacheBudgetRatio]; optional [maxBytes] can only shrink it.
  /// Never invoked from writeChanges — flush only promotes dirty pages of
  /// that batch. Returns approximate bytes added to the leaf hot cache.
  Future<int> prewarmVectorIndex(
    TableContext table,
    IndexUid indexUid, {
    int? maxBytes,
  }) async {
    try {
      if (_dataStore.shouldAbortBackgroundScan) return 0;

      final meta = await _loadMeta(table, indexUid);
      if (_dataStore.shouldAbortBackgroundScan) return 0;
      if (meta == null || meta.isBuilding) {
        if (!await _legacyIo.hasOldIndex(table, indexUid)) return 0;
        final oldMeta = await _legacyIo.readMeta(table, indexUid);
        if (oldMeta == null || oldMeta.totalVectors <= 0) return 0;
        await _legacySearch.prefetchNavGraph(table, indexUid);
        final defaultBudget = _defaultPrewarmBudget();
        final budget =
            maxBytes != null ? min(maxBytes, defaultBudget) : defaultBudget;
        if (budget <= 0) return 0;
        return await _legacySearch.prewarmClusters(
          table: table,
          indexUid: indexUid,
          meta: oldMeta,
          maxBytes: budget,
        );
      }
      if (meta.totalVectors <= 0) {
        return 0;
      }
      await _graphEngine.prefetchNavGraph(table, indexUid, meta: meta);

      // Dedicated vector ceiling (vectorCacheBudgetRatio); caller maxBytes
      // may only tighten — never expand past the search-hot leaf budget.
      final defaultBudget = _defaultPrewarmBudget();
      final budget =
          maxBytes != null ? min(maxBytes, defaultBudget) : defaultBudget;
      if (budget <= 0) return 0;

      final added = await _graphEngine.prewarmLeaves(
        table: table,
        indexUid: indexUid,
        meta: meta,
        maxBytes: budget,
        shouldAbort: () => _dataStore.shouldAbortBackgroundScan,
      );

      if (_dataStore.shouldAbortBackgroundScan) return added;

      // JIT-compile scoring kernels and prime nav routing on this isolate.
      await _graphEngine.warmSearchPath(
        table: table,
        indexUid: indexUid,
        meta: meta,
      );

      return added;
    } catch (e) {
      Logger.warn(
        'Vector index prewarm failed for index "$indexUid" in table "${table.tableName}"',
        rawError: e,
      );
      return 0;
    }
  }

  /// Prewarm vector indexes for a given table context.
  Future<int> prewarmVectorIndexByContext(
    TableContext table, {
    String? fieldName,
    int? maxBytes,
  }) async {
    final schema = await _dataStore.tableMetaManager
        ?.getTableSchemaByName(TableName(table.tableName));
    if (schema == null) return 0;
    final vectorIndexes = _dataStore.tableMetaManager
        ?.getVectorIndexesFor(schema)
        .where((idx) => fieldName == null || idx.fields.contains(fieldName))
        .toList(growable: false);
    if (vectorIndexes == null || vectorIndexes.isEmpty) return 0;

    var totalLoaded = 0;
    for (final vIdx in vectorIndexes) {
      if (_dataStore.shouldAbortBackgroundScan) break;
      totalLoaded += await prewarmVectorIndex(
        table,
        vIdx.indexUid,
        maxBytes: maxBytes,
      );
    }
    return totalLoaded;
  }

  int _defaultPrewarmBudget() {
    final leafBudget = _resolveVectorLeafCacheBudget();
    final used = _graphEngine.btreeLeafCacheBytes;
    return max(0, leafBudget - used);
  }

  NghIndexMeta _withPageSizes(NghIndexMeta meta) =>
      NghPageSizer.ensureIndexPageSizes(
        meta,
        _dataStore.configuredPageSize,
      );

  // =====================================================================
  // Meta Persistence
  // =====================================================================

  /// Public read of NGH index meta (coalesced disk load).
  Future<NghIndexMeta?> getNghIndexMeta(
          TableContext table, IndexUid indexUid) =>
      _loadMeta(table, indexUid);

  /// Rebuild a leaf page image from an NGPK structure+PK redo payload.
  ///
  /// Loads live vectors from the table by primary key (file-backed),
  /// re-quantizes to SQ8, and returns a full TPG2 page suitable for partition
  /// write. Returns null when the payload is not NGPK or meta/schema is missing.
  Future<Uint8List?> materializeLeafPkRedoPage({
    required TableContext table,
    required IndexUid indexUid,
    required Uint8List pkRedoPayload,
  }) async {
    final decoded = NghLeafPage.tryDecodePkStructureRedoPayload(pkRedoPayload);
    if (decoded == null) return null;

    final meta = await _loadMeta(table, indexUid);
    if (meta == null) return null;
    final schema =
        await _dataStore.tableMetaManager?.getTableSchema(table.tableUid);
    if (schema == null) return null;

    final vectorIndexes =
        _dataStore.tableMetaManager?.getVectorIndexesFor(schema) ??
            const <IndexSchema>[];
    String? fieldName;
    for (final idx in vectorIndexes) {
      final uid = _resolveVectorIndexUid(table, idx.fields.first);
      if (uid == indexUid) {
        fieldName = idx.fields.first;
        break;
      }
    }
    fieldName ??=
        vectorIndexes.isNotEmpty ? vectorIndexes.first.fields.first : null;
    if (fieldName == null) return null;

    final pkName = schema.primaryKey;
    final dims = decoded.dimensions;
    final slots = <NghLeafSlot>[];
    final emptyCodes = Uint8List(dims);

    for (final s in decoded.slots) {
      final pk = utf8.decode(s.pkBytes, allowMalformed: true);
      if ((s.flags & NghLeafSlot.flagDeleted) != 0) {
        slots.add(NghLeafSlot(
          nodeId: s.nodeId,
          flags: s.flags,
          primaryKeyBytes: Uint8List.fromList(s.pkBytes),
          sq8Codes: emptyCodes,
          offset: 0,
          scale: 1,
          squaredNorm: 0,
        ));
        continue;
      }

      final rec = await _dataStore.tableDataManager.getRecordByPrimaryKey(
        table,
        pk,
        readFromFileOnly: true,
        decodeSchema: schema,
      );
      Float32List? f32;
      if (rec != null) {
        final prepared = _prepareInsertVectorsBatch(
          records: [rec],
          fieldName: fieldName,
          primaryKeyField: pkName,
          dimensions: dims,
        );
        if (prepared.vectors.isNotEmpty) {
          f32 = prepared.vectors.first;
        }
      }
      if (f32 == null) {
        Logger.warn(
          'NGH PK-redo missing table vector for pk="$pk" '
          '(table=${table.tableUid}, index=$indexUid); slot kept empty',
        );
        slots.add(NghLeafSlot(
          nodeId: s.nodeId,
          flags: s.flags,
          primaryKeyBytes: Uint8List.fromList(s.pkBytes),
          sq8Codes: emptyCodes,
          offset: 0,
          scale: 1,
          squaredNorm: 0,
        ));
        continue;
      }

      final sq8 = ScalarQuantizer.quantize(f32);
      slots.add(NghLeafSlot(
        nodeId: s.nodeId,
        flags: s.flags,
        primaryKeyBytes: Uint8List.fromList(s.pkBytes),
        sq8Codes: sq8.codes,
        offset: sq8.offset,
        scale: sq8.scale,
        squaredNorm: sq8.squaredNorm,
      ));
    }

    final page = NghLeafPage(
      centroidId: decoded.centroidId,
      nextLeafPage: decoded.nextLeafPage,
      dimensions: dims,
      slots: slots,
    );
    page.ensureLow48Ready();
    final pageSize = _partitionManager.pageSizeFor(
      NghDataCategory.leaf,
      meta,
    );
    final encrypt =
        _dataStore.config.encryptionConfig?.shouldEncryptVectorIndex ?? false;
    return _partitionManager.buildLeafPageBytes(
      page: page,
      pageSize: pageSize,
      encrypt: encrypt,
    );
  }

  /// Load meta from disk with coalesce: concurrent callers share a single I/O.
  Future<NghIndexMeta?> _loadMeta(TableContext table, IndexUid indexUid) {
    final loadKey = '${table.tableUid}/$indexUid';
    final existing = _metaLoadingFutures[loadKey];
    if (existing != null) return existing;

    final future = _doLoadMeta(table, indexUid).whenComplete(() {
      _metaLoadingFutures.remove(loadKey);
    });
    _metaLoadingFutures[loadKey] = future;
    return future;
  }

  Future<NghIndexMeta?> _doLoadMeta(
      TableContext table, IndexUid indexUid) async {
    try {
      final diskLoad = await _readNghMetaFromDisk(table, indexUid);
      if (diskLoad == null) return null;

      final reconciled = _reconcileLoadedNghMeta(diskLoad, indexUid);
      // Recovery replay holds partition file locks / torn page0; a side-effect
      // persist here can nest page-redo writes into the same startup path.
      if (reconciled != diskLoad &&
          !_dataStore.parallelJournalManager.isInRecoveryMode) {
        _persistMeta(table, indexUid, reconciled);
      }
      _vectorCache.putMeta(table, indexUid, reconciled);
      return reconciled;
    } catch (e) {
      Logger.warn('Failed to load NGH meta for $indexUid', rawError: e);
      return null;
    }
  }

  Future<NghIndexMeta?> _readNghMetaFromDisk(
      TableContext table, IndexUid pathKey) async {
    return _dataStore.treeMetaPageService.readNghGlobalMeta(
      table,
      pathKey,
    );
  }

  /// Align in-memory meta with stable [pathKey].
  NghIndexMeta _reconcileLoadedNghMeta(NghIndexMeta meta, IndexUid pathKey) {
    var next = _withPageSizes(meta);
    if (pathKey.isNotEmpty && next.indexUid != pathKey) {
      next = next.copyWith(indexUid: pathKey);
    }
    return next;
  }

  Future<bool> _persistMeta(
    TableContext table,
    IndexUid indexUid,
    NghIndexMeta meta, {
    BatchContext? batchContext,
  }) async {
    try {
      await _dataStore.treeMetaPageService.persistNghGlobalMeta(
        table: table,
        indexUid: indexUid,
        meta: meta,
        batchContext: batchContext,
        flush: false,
      );
      return true;
    } catch (e) {
      Logger.error('Failed to persist NGH meta', rawError: e);
      return false;
    }
  }

  Future<NghIndexMeta> _getOrCreateMeta(
    TableContext table,
    IndexUid indexUid,
    String fieldName,
    FieldSchema fieldSchema,
    IndexSchema idx,
  ) async {
    // Check cache
    var meta = _vectorCache.getMeta(table, indexUid);
    if (meta != null) {
      final sized = _withPageSizes(meta);
      if (!identical(sized, meta)) {
        _vectorCache.putMeta(table, indexUid, sized);
      }
      return sized;
    }

    // Try load from disk
    meta = await _loadMeta(table, indexUid);
    if (meta != null) {
      _vectorCache.putMeta(table, indexUid, meta);
      return meta;
    }

    // Create new
    final dims = fieldSchema.vectorConfig?.dimensions ?? 128;
    final vc = idx.vectorConfig;

    meta = _withPageSizes(NghIndexMeta.createEmpty(
      indexUid: indexUid,
      tableUid: table.tableUid,
      dimensions: dims,
      distanceMetric: vc?.distanceMetric ?? VectorDistanceMetric.cosine,
    ));

    _vectorCache.putMeta(table, indexUid, meta);
    return meta;
  }

  // =====================================================================
  // Migration Lifecycle (beginIndexBuild / endIndexBuild)
  // =====================================================================

  /// Deletes all physical vector index files on disk and clears in-memory caches.
  Future<void> deletePhysicalIndexArtifacts(
    TableContext table,
    IndexUid indexUid,
  ) async {
    _vectorCache.clearForIndex(table.tableUid, indexUid);
    _legacySearch.clearCacheForIndex(table.tableUid, indexUid);
    await _legacyIo.deleteOldIndex(table, indexUid);
    await _partitionManager.deletePhysicalIndexArtifacts(table, indexUid);
  }

  /// Begins vector index build during migration (sets isBuilding = true).
  Future<void> beginIndexBuild(
    TableContext table,
    IndexSchema indexSchema,
  ) async {
    final indexUid = indexSchema.indexUid;
    if (indexUid.isEmpty) return;

    _vectorCache.clearForIndex(table.tableUid, indexUid);
    _graphEngine.clearCacheForIndex(table.tableUid, indexUid);
    await _partitionManager.deleteLiveNghRoot(table, indexUid);

    int dims = 128;
    if (indexSchema.fields.isNotEmpty) {
      final fieldName = indexSchema.fields.first;
      final fieldSchema = table.schema.fields
          .cast<FieldSchema?>()
          .firstWhere((f) => f?.name == fieldName, orElse: () => null);
      if (fieldSchema?.vectorConfig != null) {
        dims = fieldSchema!.vectorConfig!.dimensions;
      }
    }
    final metric =
        indexSchema.vectorConfig?.distanceMetric ?? VectorDistanceMetric.cosine;

    final initialMeta = _withPageSizes(NghIndexMeta.createEmpty(
      indexUid: indexUid,
      tableUid: table.tableUid,
      dimensions: dims,
      distanceMetric: metric,
      isBuilding: true,
    ));

    await _persistMeta(table, indexUid, initialMeta);
    _vectorCache.putMeta(table, indexUid, initialMeta);
  }

  /// Ends vector index build after migration finishes (sets isBuilding = false).
  Future<void> endIndexBuild(
    TableContext table,
    IndexUid indexUid,
  ) async {
    if (indexUid.isEmpty) return;
    var meta = _vectorCache.getMeta(table, indexUid);
    meta ??= await _loadMeta(table, indexUid);
    if (meta == null) return;

    if (meta.isBuilding) {
      final updated = meta.copyWith(isBuilding: false);
      if (!await _persistMeta(table, indexUid, updated)) {
        return;
      }
      _vectorCache.putMeta(table, indexUid, updated);
    }
    await _legacyIo.deleteOldIndex(table, indexUid);
    _legacySearch.clearCacheForIndex(table.tableUid, indexUid);
  }

  // =====================================================================
  // Background Maintenance
  // =====================================================================

  /// Run background tombstone compaction for all vector indexes in a table.
  ///
  /// Repairs graph edges around deleted nodes and reclaims tombstone slots.
  /// Should be called periodically by the compaction manager, using
  /// [WorkloadType.maintenance] tokens.
  Future<void> compactTombstones(TableContext table,
      {int maxVisitedPages = 100}) async {
    final vectorIndexes =
        _dataStore.tableMetaManager?.getVectorIndexesFor(table.schema);
    if (vectorIndexes == null || vectorIndexes.isEmpty) return;

    final yc = YieldController(
      'VectorIndexManager.compactTombstones',
      checkInterval: 20,
      budgetMs: 40,
    );
    for (final idx in vectorIndexes) {
      final y9 = yc.maybeYield();
      if (y9 != null) await y9;
      final indexUid = idx.indexUid;
      var meta = _vectorCache.getMeta(table, indexUid);
      meta ??= await _loadMeta(table, indexUid);
      if (meta == null || meta.isBuilding) continue;

      // Skip if deletion ratio is low (< 10%)
      if (meta.totalVectors == 0 ||
          meta.deletedCount / meta.totalVectors < 0.1) {
        continue;
      }

      final result = await _graphEngine.compactTombstones(
        table: table,
        indexUid: indexUid,
        meta: meta,
        maxVisitedPages: maxVisitedPages,
      );

      if (result.dirtyLeafPages.isNotEmpty ||
          result.dirtyNavPages.isNotEmpty ||
          result.dirtyPkmapPages.isNotEmpty ||
          result.freeLeafPages.isNotEmpty) {
        final compactedMeta = result.meta;
        await _dataStore.parallelJournalManager.runWithPageRedoBatch(
          table: table,
          action: (ctx, {required bool ownedBatch}) async {
            final next = await _partitionManager.writeChanges(
              table: table,
              indexUid: indexUid,
              meta: compactedMeta,
              dirtyLeafPages: result.dirtyLeafPages,
              dirtyNavPages: result.dirtyNavPages,
              dirtyPkmapPages: result.dirtyPkmapPages,
              freeLeafPages: result.freeLeafPages,
              deletedDelta: -result.compactedCount,
              batchContext: ctx,
            );
            await _persistMeta(table, indexUid, next, batchContext: ctx);
            _vectorCache.putMeta(table, indexUid, next);
          },
        );
      }
    }
  }

  // =====================================================================
  // Cache Management
  // =====================================================================

  /// Total estimated cache size (bytes).
  int getCurrentCacheSize() {
    return _vectorCache.estimatedSizeBytes +
        _partitionManager.getCurrentPageCacheSize() +
        _graphEngine.btreeLeafCacheBytes +
        _graphEngine.navGraphCacheBytes +
        _legacySearch.clusterCacheBytes;
  }

  /// Evict caches under memory pressure.
  ///
  /// I/O-fill / meta layers always LRU-trim. Search-hot SQ8 leaves also
  /// trim when still LOW after structured eviction. Nav internals (Mid-1/2
  /// share that cache) wait for CRITICAL or an over-budget nav working set.
  Future<void> evictCache({double ratio = 0.3, bool force = false}) async {
    await _vectorCache.evict(ratio: ratio);
    await _partitionManager.evictPageCache(ratio: ratio);

    final status = _dataStore.resourceManager?.status;
    final stillLow = status != null && status != ResourceStatus.normal;
    final isCritical = status == ResourceStatus.critical;
    final legacyBytes = _legacySearch.clusterCacheBytes;
    final legacyMax = _legacySearch.clusterCacheMaxBytes;
    if (force || isCritical || stillLow || legacyBytes > legacyMax) {
      _legacySearch.evictClusterCache(ratio: ratio);
    }
    final leafBytes = _graphEngine.btreeLeafCacheBytes;
    final leafMax = _graphEngine.btreeLeafCacheMaxBytes;
    if (force || isCritical || stillLow || leafBytes > leafMax) {
      await _graphEngine.evictHotSearchCaches(ratio: ratio);
    }
    final navBytes =
        _graphEngine.navInternalCacheBytes + _graphEngine.navGraphCacheBytes;
    final navMax = _graphEngine.navInternalCacheMaxBytes +
        _graphEngine.navGraphCacheMaxBytes;
    if (force || isCritical || navBytes > navMax) {
      await _graphEngine.evictNavWorkingSet(ratio: ratio);
    }
  }

  /// Clear all caches for a table.
  void clearCacheForTable(TableUid tableUid) {
    final prefix = '${tableUid.value}/';
    _fieldIndexUidCache.removeWhere((k, _) => k.startsWith(prefix));
    _pendingDeleteCache.removeWhere((k, _) => k.startsWith(prefix));
    _metaLoadingFutures.removeWhere((k, _) => k.startsWith(prefix));
    _vectorCache.clearForTable(tableUid);
    _partitionManager.clearPageCacheForTable(tableUid);
    _graphEngine.clearCacheForTable(tableUid);
    _legacySearch.clearCacheForTable(tableUid);
  }

  /// Clear all caches for a specific index.
  void clearCacheForIndex(TableUid tableUid, IndexUid indexUid) {
    final key = _pendingKey(tableUid, indexUid);
    _pendingDeleteCache.remove(key);
    final metaPrefix = '${tableUid.value}/';
    _metaLoadingFutures.removeWhere(
      (k, _) =>
          k == key || (k.startsWith(metaPrefix) && k.contains(indexUid.value)),
    );
    _fieldIndexUidCache.removeWhere(
      (k, v) => k.startsWith(metaPrefix) && v == indexUid,
    );
    _vectorCache.clearForIndex(tableUid, indexUid);
    _partitionManager.clearFullyCachedForIndex(tableUid, indexUid);
    _partitionManager.clearPageCacheForIndex(tableUid, indexUid);
    _graphEngine.clearCacheForIndex(tableUid, indexUid);
    _legacySearch.clearCacheForIndex(tableUid, indexUid);
  }

  /// Clear all caches.
  Future<void> dispose() async {
    // Wait for all ongoing metadata loading
    if (_metaLoadingFutures.isNotEmpty) {
      try {
        await Future.wait(_metaLoadingFutures.values);
      } catch (_) {}
    }
    await _partitionManager.dispose();
    _metaLoadingFutures.clear();
    _fieldIndexUidCache.clear();
    _vectorCache.clear();
    _partitionManager.clearPageCacheSync();
    _graphEngine.clearCache();
    _legacySearch.clearCache();
    _pendingDeleteCache.clear();
  }

  /// Re-encrypt NGH TPG2 pages for key migration (nav/pkmap/leaf).
  Future<void> rewriteEncryptedPages(
    TableContext table,
    IndexUid indexUid,
  ) async {
    final meta = _vectorCache.getMeta(table, indexUid) ??
        await _loadMeta(table, indexUid);
    if (meta == null) return;
    await _partitionManager.rewriteEncryptedPages(table, indexUid, meta);
  }

  // =====================================================================
  // Private Helpers
  // =====================================================================

  String _pendingKey(TableUid tableUid, IndexUid indexUid) =>
      '${tableUid.value}/${indexUid.value}';

  String _pendingPath(TableContext table, IndexUid indexUid) =>
      _dataStore.pathManager.getNghPendingDeletePathByContext(table, indexUid);

  Future<Set<String>> _loadPendingDeletes(
    TableContext table,
    IndexUid indexUid,
  ) async {
    final cacheKey = _pendingKey(table.tableUid, indexUid);
    final cached = _pendingDeleteCache[cacheKey];
    if (cached != null) return cached;
    final path = _pendingPath(table, indexUid);
    try {
      if (!await _dataStore.storage.existsFile(path)) {
        final empty = <String>{};
        _pendingDeleteCache[cacheKey] = empty;
        return empty;
      }
      final bytes = await _dataStore.storage.readAsBytes(path);
      final set = _decodePendingDeletes(bytes);
      _pendingDeleteCache[cacheKey] = set;
      return set;
    } catch (_) {
      final empty = <String>{};
      _pendingDeleteCache[cacheKey] = empty;
      return empty;
    }
  }

  Future<void> _persistPendingDeletes(
    TableContext table,
    IndexUid indexUid,
    Set<String> pks,
  ) async {
    final cacheKey = _pendingKey(table.tableUid, indexUid);
    _pendingDeleteCache[cacheKey] = pks;
    final path = _pendingPath(table, indexUid);
    if (pks.isEmpty) {
      try {
        if (await _dataStore.storage.existsFile(path)) {
          await _dataStore.storage.deleteFile(path);
        }
      } catch (_) {}
      return;
    }
    await _dataStore.storage.ensureDirectoryExists(p.dirname(path));
    await _dataStore.storage.writeAsBytes(path, _encodePendingDeletes(pks));
  }

  Future<void> _mergePendingDeletes(
    TableContext table,
    IndexUid indexUid,
    List<String> extra,
  ) async {
    if (extra.isEmpty) return;
    final current = await _loadPendingDeletes(table, indexUid);
    current.addAll(extra);
    await _persistPendingDeletes(table, indexUid, current);
  }

  Future<void> _removePendingDeletes(
    TableContext table,
    IndexUid indexUid,
    List<String> pks,
  ) async {
    if (pks.isEmpty) return;
    final current = await _loadPendingDeletes(table, indexUid);
    if (current.isEmpty) return;
    var changed = false;
    for (final pk in pks) {
      if (current.remove(pk)) changed = true;
    }
    if (changed) {
      await _persistPendingDeletes(table, indexUid, current);
    }
  }

  Uint8List _encodePendingDeletes(Set<String> pks) {
    final encoded = [for (final pk in pks) utf8.encode(pk)];
    var total = 4;
    for (final e in encoded) {
      total += 4 + e.length;
    }
    final out = Uint8List(total);
    final bd = ByteData.sublistView(out);
    bd.setUint32(0, encoded.length, Endian.little);
    var off = 4;
    for (final e in encoded) {
      bd.setUint32(off, e.length, Endian.little);
      off += 4;
      out.setRange(off, off + e.length, e);
      off += e.length;
    }
    return out;
  }

  Set<String> _decodePendingDeletes(Uint8List bytes) {
    if (bytes.length < 4) return <String>{};
    final bd = ByteData.sublistView(bytes);
    final n = bd.getUint32(0, Endian.little);
    var off = 4;
    final out = <String>{};
    for (int i = 0; i < n; i++) {
      if (off + 4 > bytes.length) break;
      final len = bd.getUint32(off, Endian.little);
      off += 4;
      if (len < 0 || off + len > bytes.length) break;
      out.add(utf8.decode(bytes.sublist(off, off + len)));
      off += len;
    }
    return out;
  }

  Future<NghIndexMeta> _runPkBackfill(
    TableContext table,
    IndexUid indexUid,
    NghIndexMeta meta, {
    BatchContext? batchContext,
  }) async {
    final pending = await _loadPendingDeletes(table, indexUid);
    final result = await _graphEngine.backfillPkLocator(
      table: table,
      indexUid: indexUid,
      meta: meta,
      pendingDeletePks: pending,
    );
    var next = result.meta;
    if (result.dirtyLeafPages.isNotEmpty ||
        result.dirtyPkmapPages.isNotEmpty ||
        result.dirtyNavBTreePages.isNotEmpty ||
        result.dirtyNavRootPage != null) {
      next = await _partitionManager.writeChanges(
        table: table,
        indexUid: indexUid,
        meta: next,
        dirtyLeafPages: result.dirtyLeafPages,
        dirtyPkmapPages: result.dirtyPkmapPages,
        dirtyNavBTreePages: result.dirtyNavBTreePages,
        dirtyNavRootPage: result.dirtyNavRootPage,
        vectorsDelta: -result.tombstonedCount,
        deletedDelta: result.tombstonedCount,
        batchContext: batchContext,
      );
    }
    if (next.hasPkLocator) {
      await _persistPendingDeletes(table, indexUid, <String>{});
    }
    return next;
  }

  Float32List _queryAsFloat32(VectorData queryVector, int dimensions) {
    final rawValues = queryVector.values;
    if (rawValues is Float32List && rawValues.length == dimensions) {
      return rawValues;
    }
    return _toFloat32(rawValues, dimensions);
  }

  /// Convert double list to Float32List, ensuring correct dimensions.
  Float32List _toFloat32(List<dynamic> values, int dimensions) {
    final f32 = Float32List(dimensions);
    final len = min(values.length, dimensions);
    for (int i = 0; i < len; i++) {
      final v = values[i];
      if (v is num) {
        f32[i] = v.toDouble();
      }
    }
    return f32;
  }

  /// Convert distance to similarity score in [0, 1].
  double _distanceToScore(double distance, VectorDistanceMetric metric) {
    switch (metric) {
      case VectorDistanceMetric.l2:
        // L2 distance -> score: 1 / (1 + distance)
        return 1.0 / (1.0 + distance);
      case VectorDistanceMetric.innerProduct:
        // Inner product was negated for min-heap; negate back and sigmoid
        return 1.0 / (1.0 + exp(-(-distance)));
      case VectorDistanceMetric.cosine:
        // Cosine distance = 1 - similarity -> score = 1 - distance
        return (1.0 - distance).clamp(0.0, 1.0);
    }
  }
}
