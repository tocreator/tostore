import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

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
import 'workload_scheduler.dart';
import 'yield_controller.dart';

/// Manages all NGH vector indexes for the data store.
class VectorIndexManager {
  final DataStoreImpl _dataStore;

  late final NghPartitionManager _partitionManager;
  late final NghGraphEngine _graphEngine;
  NghGraphEngine get graphEngine => _graphEngine;
  late final VectorCache _vectorCache;

  /// In-flight meta loads -- prevents parallel readers from each hitting disk.
  /// Key: "$tableUid/$indexUid", value: the single in-progress Future.
  final Map<String, Future<NghIndexMeta?>> _metaLoadingFutures = {};

  /// Pending-delete PK sets while PK locator backfill is incomplete.
  final Map<String, Set<String>> _pendingDeleteCache = {};

  /// Hot field → vector indexUid resolution cache.
  /// Key: "$tableUid/$fieldName"
  final Map<String, IndexUid?> _fieldIndexUidCache = {};

  VectorIndexManager(this._dataStore) {
    _partitionManager = NghPartitionManager(_dataStore);
    _graphEngine = NghGraphEngine(_partitionManager);
    _vectorCache = VectorCache();
    syncClusterCacheBudget();
  }

  int _resolveIndexCacheBudget() {
    final sized = _dataStore.resourceManager?.getIndexCacheSize() ?? 0;
    if (sized > 0) return sized;
    return 128 * 1024 * 1024;
  }

  /// Compact SQ8 search cache budget.
  ///
  /// Lazily anchors to [vectorCacheBudgetRatio] (default 50%) of the total memory threshold.
  /// This allocation is zero-cost when no vector queries occur, but prevents disk I/O
  /// thrashing under large corpora (e.g. 1M 512D vectors) by keeping posting clusters in memory.
  int _resolveCompactVectorClusterBudget() {
    final totalBudgetMB = _dataStore.resourceManager?.memoryThresholdInMB ?? 0;
    final resolvedMB = totalBudgetMB > 0
        ? totalBudgetMB
        : (_dataStore.config.cacheMemoryBudgetMB ?? 1024);
    final ratio =
        (_dataStore.config.vectorCacheBudgetRatio ?? 0.50).clamp(0.10, 0.85);
    final targetBytes = (resolvedMB * 1024 * 1024 * ratio).round();
    return max(32 * 1024 * 1024, targetBytes);
  }

  /// Resolve navigating centroid graph cache budget.
  ///
  /// Nav graph is the entry routing backbone. Keeping it 100% in RAM prevents
  /// disk I/O jitter during centroid navigation across millions/billions of vectors.
  /// Minimum floor: 32MB on mobile, 128MB on desktop/server.
  /// Dynamically expands to ~15% of the total vector cache budget.
  int _resolveNavGraphCacheBudget() {
    final clusterBudget = _resolveCompactVectorClusterBudget();
    final floor =
        PlatformHandler.isMobile ? 32 * 1024 * 1024 : 128 * 1024 * 1024;
    final targetBytes = (clusterBudget * 0.15).round();
    return max(floor, targetBytes);
  }

  /// Re-apply cache ceilings after ResourceManager computes real quotas.
  ///
  /// Vector ANN must not inherit only `indexCache * 30%` — that thrashs the
  /// posting I/O layer after a few tens of thousands of inserts. Leaf + posting
  /// share the dedicated vector compact budget from [vectorCacheBudgetRatio].
  void syncClusterCacheBudget() {
    final indexBudget = _resolveIndexCacheBudget();
    final vectorBudget = _resolveCompactVectorClusterBudget();
    _graphEngine.configureClusterCacheBudget(vectorBudget);
    _graphEngine.configureBTreeLeafCacheBudget(vectorBudget);
    _graphEngine.configureNavGraphCacheBudget(_resolveNavGraphCacheBudget());
    // Posting fill layer: max(index*30%, vector*45%) so paged search survives
    // large insert bursts without immediate TreeCache eviction.
    final postingBudget = max(
      (indexBudget * 0.30).round(),
      (vectorBudget * 0.45).round(),
    );
    _partitionManager.syncCacheBudget(
      indexBudget: indexBudget,
      vectorPostingBudget: postingBudget,
    );
  }

  /// Serializes layout-1 → paged nav migrate with the first flush that
  /// still sees a legacy blob (background catch-up vs insert).
  final Map<String, Future<void>> _navLayoutLocks = {};

  Future<T> _withNavLayoutLock<T>(
    TableUid tableUid,
    IndexUid indexUid,
    Future<T> Function() body,
  ) async {
    final key = '${tableUid.value}/${indexUid.value}';
    final prev = _navLayoutLocks[key];
    final gate = Completer<void>();
    _navLayoutLocks[key] = gate.future;
    if (prev != null) {
      await prev;
    }
    try {
      return await body();
    } finally {
      gate.complete();
      if (identical(_navLayoutLocks[key], gate.future)) {
        _navLayoutLocks.remove(key);
      }
    }
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

  Future<({List<Float32List> vectors, List<String> primaryKeys})>
      _prepareInsertVectorsBatch({
    required List<Map<String, dynamic>> records,
    required String fieldName,
    required String primaryKeyField,
    required int dimensions,
  }) async {
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
          Future<void> flushDelete() async {
            var liveMeta = _vectorCache.getMeta(table, indexUid) ?? meta;
            final result = await _graphEngine.deleteBatch(
              table: table,
              indexUid: indexUid,
              meta: liveMeta,
              primaryKeys: deletePks,
            );
            meta = result.meta;
            if (result.unresolvedPks.isNotEmpty) {
              await _mergePendingDeletes(table, indexUid, result.unresolvedPks);
            }
            meta = await _partitionManager.writeChanges(
              table: table,
              indexUid: indexUid,
              meta: meta,
              dirtyPostingPages: result.dirtyPostingPages,
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
          }

          if (!meta.isPagedLayout) {
            await migrateLegacyNavIfNeeded(table, indexUid);
            meta = _vectorCache.getMeta(table, indexUid) ??
                await _loadMeta(table, indexUid) ??
                meta;
          }
          await flushDelete();
        }
      }

      if (insertRecords.isNotEmpty) {
        final preparedVectors = await _prepareInsertVectorsBatch(
          records: insertRecords,
          fieldName: fieldName,
          primaryKeyField: pkName,
          dimensions: meta.dimensions,
        );
        final vectors = preparedVectors.vectors;
        final pks = preparedVectors.primaryKeys;

        if (vectors.isNotEmpty) {
          Future<void> flushInsert() async {
            var liveMeta = _vectorCache.getMeta(table, indexUid) ?? meta;
            final insertResult = await _graphEngine.insertBatch(
              table: table,
              indexUid: indexUid,
              meta: liveMeta,
              vectors: vectors,
              primaryKeys: pks,
              yieldBudgetMs: 100,
            );
            meta = insertResult.meta;
            meta = await _partitionManager.writeChanges(
              table: table,
              indexUid: indexUid,
              meta: meta,
              dirtyPostingPages: insertResult.dirtyPostingPages,
              dirtyNavPages: insertResult.dirtyNavPages,
              dirtyNavBTreePages: insertResult.dirtyNavBTreePages,
              dirtyNavRootPage: insertResult.dirtyNavRootPage,
              dirtyPkmapPages: insertResult.dirtyPkmapPages,
              deleteLegacyNavGraph: insertResult.deleteLegacyNavGraph,
              vectorsDelta: insertResult.insertedCount,
              concurrency: concurrency,
              batchContext: batchContext,
            );
            await _removePendingDeletes(table, indexUid, pks);
            // Insert leaves an unbounded leafCache (all dirty pages). Rebuild to
            // the same budgeted hot set as restart prewarm — otherwise post-insert
            // QPS stays ~2× slower from GC / working-set bloat even on repeat queries.
            if (meta.layoutVersion >= NghIndexMeta.layoutPaged) {
              if (!_dataStore.shouldAbortBackgroundScan) {
                await _graphEngine.rebuildPagedLeafCacheAfterInsert(
                  table: table,
                  indexUid: indexUid,
                  meta: meta,
                  shouldAbort: () => _dataStore.shouldAbortBackgroundScan,
                );
              }
            } else if (insertResult.needsCompactGapFill) {
              final remain = max(
                0,
                _graphEngine.clusterCacheMaxBytes -
                    _graphEngine.clusterCacheBytes,
              );
              if (remain > 0 && !_dataStore.shouldAbortBackgroundScan) {
                await _graphEngine.prewarmClusters(
                  table: table,
                  indexUid: indexUid,
                  meta: meta,
                  maxBytes: remain,
                  shouldAbort: () => _dataStore.shouldAbortBackgroundScan,
                );
              }
            }
          }

          if (!meta.isPagedLayout) {
            await migrateLegacyNavIfNeeded(table, indexUid);
            meta = _vectorCache.getMeta(table, indexUid) ??
                await _loadMeta(table, indexUid) ??
                meta;
          }
          await flushInsert();
        }
      }

      if (!meta.hasPkLocator) {
        meta = await _runPkBackfill(table, indexUid, meta);
      }

      await _persistMeta(table, indexUid, meta);
      _vectorCache.putMeta(table, indexUid, meta);
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
    if (meta == null || meta.isBuilding || meta.totalVectors == 0) {
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
    if (!meta.isPagedLayout) {
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

    final rawValues = queryVector.values;
    final Float32List queryF32;
    if (rawValues is Float32List && rawValues.length == meta.dimensions) {
      queryF32 = rawValues;
    } else {
      queryF32 = _toFloat32(rawValues, meta.dimensions);
    }
    // Let the engine normalize into scratch (no alloc here).

    Set<String>? pending;
    if (!meta.hasPkLocator) {
      final cacheKey = _pendingKey(table.tableUid, indexUid);
      pending = _pendingDeleteCache[cacheKey];
      if (pending == null) {
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
      final entries = <VectorSearchResult>[];
      for (final r in hot) {
        final pk = r.primaryKey;
        if (pk == null || pk.isEmpty) continue;
        entries.add(VectorSearchResult(
          primaryKey: pk,
          distance: r.distance,
          score: _distanceToScore(r.distance, meta.distanceMetric),
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
    if (meta == null || meta.isBuilding || meta.totalVectors == 0) {
      return const [];
    }
    if (!meta.isPagedLayout) {
      await migrateLegacyNavIfNeeded(table, indexUid);
      meta = _vectorCache.getMeta(table, indexUid) ??
          await _loadMeta(table, indexUid) ??
          meta;
    }
    if (!_graphEngine.isNavGraphCached(table, indexUid, meta: meta)) {
      await _graphEngine.prefetchNavGraph(table, indexUid, meta: meta);
    }

    final rawValues = queryVector.values;
    final Float32List queryF32;
    if (rawValues is Float32List && rawValues.length == meta.dimensions) {
      queryF32 = rawValues;
    } else {
      queryF32 = _toFloat32(rawValues, meta.dimensions);
    }

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

  /// Prewarm vector index meta, nav graph, and posting clusters into cache.
  ///
  /// Respects [maxBytes] (and the global cluster-cache ceiling) to avoid OOM.
  /// Loads clusters in cooperative batches so close / switchSpace can abort
  /// promptly (mirrors table/index row prewarm).
  /// Returns approximate bytes added to the cluster compact cache.
  Future<int> prewarmVectorIndex(
    TableContext table,
    IndexUid indexUid, {
    int? maxBytes,
  }) async {
    try {
      if (_dataStore.shouldAbortBackgroundScan) return 0;

      final meta = await _loadMeta(table, indexUid);
      if (_dataStore.shouldAbortBackgroundScan) return 0;
      if (meta == null || meta.isBuilding || meta.totalVectors <= 0) {
        return 0;
      }
      await _graphEngine.prefetchNavGraph(table, indexUid, meta: meta);

      final defaultBudget = _defaultPrewarmBudget();
      final budget =
          maxBytes != null ? min(maxBytes, defaultBudget) : defaultBudget;
      if (budget <= 0) return 0;

      final added = await _graphEngine.prewarmClusters(
        table: table,
        indexUid: indexUid,
        meta: meta,
        maxBytes: budget,
        shouldAbort: () => _dataStore.shouldAbortBackgroundScan,
      );

      if (_dataStore.shouldAbortBackgroundScan) return added;

      // JIT-compile scoring kernels and prime cluster routing on this isolate.
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

  /// Convert legacy single-file `nav_graph.ngh` or unrooted paged nav to modern Centroid B+Tree.
  ///
  /// No-op when [NghIndexMeta.isPagedLayout] and [NghIndexMeta.navBTreeRootPtr] is valid.
  /// Does not rewrite posting slots.
  Future<void> migrateLegacyNavIfNeeded(
    TableContext table,
    IndexUid indexUid,
  ) async {
    await _withNavLayoutLock(table.tableUid, indexUid, () async {
      var meta = await _loadMeta(table, indexUid);
      if (meta == null) return;
      meta = _withPageSizes(meta);
      if (meta.isPagedLayout) {
        await _partitionManager.deleteLegacyNavBlobIfExists(table, indexUid);
        return;
      }

      // 1. Try reading legacy monolithic nav_graph.ngh
      var blob =
          await _partitionManager.readLegacyNavGraphBlob(table, indexUid);

      // 2. If blob is gone, try reading unrooted paged nav centroids from p0.ngh
      blob ??= await _partitionManager.readPagedNavGraph(table, indexUid, meta);

      if (blob != null && blob.centroids.isNotEmpty) {
        final migrated = await _graphEngine.migrateLegacyNavToBTree(
          table: table,
          indexUid: indexUid,
          meta: meta,
          blob: blob,
        );
        meta = await _partitionManager.writeChanges(
          table: table,
          indexUid: indexUid,
          meta: migrated.meta,
          dirtyNavBTreePages: migrated.dirtyNavBTreePages,
          dirtyNavRootPage: migrated.dirtyNavRootPage,
          deleteLegacyNavGraph: true,
        );
        await _persistMeta(table, indexUid, meta);
        _vectorCache.putMeta(table, indexUid, meta);
        return;
      }

      // If no nav centroids can be read at all, mark as paged to prevent repeated checks
      if (!meta.isPagedLayout) {
        meta = meta.copyWith(layoutVersion: NghIndexMeta.layoutPaged);
        await _persistMeta(table, indexUid, meta);
        _vectorCache.putMeta(table, indexUid, meta);
      }
    });
  }

  int _defaultPrewarmBudget() {
    final clusterBudget = _resolveCompactVectorClusterBudget();
    final used = _graphEngine.clusterCacheBytes;
    return max(0, clusterBudget - used);
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
      if (reconciled != diskLoad) {
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

  Future<void> _persistMeta(
      TableContext table, IndexUid indexUid, NghIndexMeta meta) async {
    try {
      await _dataStore.treeMetaPageService.persistNghGlobalMeta(
        table: table,
        indexUid: indexUid,
        meta: meta,
        flush: false,
      );
    } catch (e) {
      Logger.error('Failed to persist NGH meta', rawError: e);
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
    await _partitionManager.deletePhysicalIndexArtifacts(table, indexUid);
  }

  /// Begins vector index build during migration (sets isBuilding = true).
  Future<void> beginIndexBuild(
    TableContext table,
    IndexSchema indexSchema,
  ) async {
    final indexUid = indexSchema.indexUid;
    if (indexUid.isEmpty) return;

    await deletePhysicalIndexArtifacts(table, indexUid);

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
    if (meta == null || !meta.isBuilding) return;

    final updated = meta.copyWith(isBuilding: false);
    await _persistMeta(table, indexUid, updated);
    _vectorCache.putMeta(table, indexUid, updated);
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
      if (meta == null) continue;
      if (!meta.isPagedLayout) {
        await migrateLegacyNavIfNeeded(table, indexUid);
        meta = _vectorCache.getMeta(table, indexUid) ??
            await _loadMeta(table, indexUid);
        if (meta == null || !meta.isPagedLayout) continue;
      } else {
        await _partitionManager.deleteLegacyNavBlobIfExists(table, indexUid);
      }

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

      if (result.dirtyPostingPages.isNotEmpty ||
          result.dirtyNavPages.isNotEmpty ||
          result.dirtyPkmapPages.isNotEmpty ||
          result.freePostingPages.isNotEmpty) {
        meta = result.meta;
        meta = await _partitionManager.writeChanges(
          table: table,
          indexUid: indexUid,
          meta: meta,
          dirtyPostingPages: result.dirtyPostingPages,
          dirtyNavPages: result.dirtyNavPages,
          dirtyPkmapPages: result.dirtyPkmapPages,
          freePostingPages: result.freePostingPages,
          deletedDelta: -result.compactedCount,
        );
        await _persistMeta(table, indexUid, meta);
        _vectorCache.putMeta(table, indexUid, meta);
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
        _graphEngine.clusterCacheBytes +
        _graphEngine.btreeLeafCacheBytes +
        _graphEngine.navGraphCacheBytes;
  }

  /// Evict caches under memory pressure.
  Future<void> evictCache({double ratio = 0.3, bool force = false}) async {
    await _vectorCache.evict(ratio: ratio);
    await _partitionManager.evictPageCache(ratio: ratio);

    // Protect dedicated vector hot caches: only evict when over their own
    // ResourceManager-synced ceilings, or under critical memory pressure.
    final isCritical =
        _dataStore.resourceManager?.status == ResourceStatus.critical;
    final clusterBytes = _graphEngine.clusterCacheBytes;
    final clusterMax = _graphEngine.clusterCacheMaxBytes;
    if (force || isCritical || clusterBytes > clusterMax) {
      await _graphEngine.evictClusterCache(ratio: ratio);
    }
    final leafBytes = _graphEngine.btreeLeafCacheBytes;
    final leafMax = _graphEngine.btreeLeafCacheMaxBytes;
    if (force || isCritical || leafBytes > leafMax) {
      await _graphEngine.evictBTreeLeafCache(ratio: ratio);
    }
  }

  /// Clear all caches for a table.
  void clearCacheForTable(TableUid tableUid) {
    final prefix = '${tableUid.value}/';
    _fieldIndexUidCache.removeWhere((k, _) => k.startsWith(prefix));
    _vectorCache.clearForTable(tableUid);
    _partitionManager.clearPageCacheForTable(tableUid);
    _graphEngine.clearCacheForTable(tableUid);
  }

  /// Clear all caches for a specific index.
  void clearCacheForIndex(TableUid tableUid, IndexUid indexUid) {
    _vectorCache.clearForIndex(tableUid, indexUid);
    _partitionManager.clearFullyCachedForIndex(tableUid, indexUid);
    _partitionManager.clearPageCacheForIndex(tableUid, indexUid);
    _graphEngine.clearCacheForIndex(tableUid, indexUid);
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
    _pendingDeleteCache.clear();
  }

  /// Re-encrypt NGH TPG2 pages for key migration (nav/pkmap/posting).
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
    NghIndexMeta meta,
  ) async {
    final pending = await _loadPendingDeletes(table, indexUid);
    final result = await _graphEngine.backfillPkLocator(
      table: table,
      indexUid: indexUid,
      meta: meta,
      pendingDeletePks: pending,
    );
    var next = result.meta;
    if (result.dirtyPostingPages.isNotEmpty ||
        result.dirtyPkmapPages.isNotEmpty) {
      next = await _partitionManager.writeChanges(
        table: table,
        indexUid: indexUid,
        meta: next,
        dirtyPostingPages: result.dirtyPostingPages,
        dirtyPkmapPages: result.dirtyPkmapPages,
        vectorsDelta: -result.tombstonedCount,
        deletedDelta: result.tombstonedCount,
      );
    }
    if (next.hasPkLocator) {
      await _persistPendingDeletes(table, indexUid, <String>{});
    }
    return next;
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
