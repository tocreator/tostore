import 'dart:math';
import 'dart:typed_data';

import '../handler/logger.dart';
import '../model/ngh_index_meta.dart';
import '../model/parallel_journal_entry.dart';
import '../model/query_result.dart';
import '../model/table_context.dart';
import '../model/table_identity.dart';
import '../model/table_schema.dart';
import 'data_store_impl.dart';
import 'ngh_graph_engine.dart';
import 'ngh_partition_manager.dart';
import 'vector_cache.dart';
import 'vector_quantizer.dart';
import 'workload_scheduler.dart';
import 'yield_controller.dart';

/// Manages all NGH vector indexes for the data store.
class VectorIndexManager {
  final DataStoreImpl _dataStore;

  late final NghPartitionManager _partitionManager;
  late final NghGraphEngine _graphEngine;
  late final VectorCache _vectorCache;

  /// In-flight meta loads -- prevents parallel readers from each hitting disk.
  /// Key: "$tableUid/$indexUid", value: the single in-progress Future.
  final Map<String, Future<NghIndexMeta?>> _metaLoadingFutures = {};

  VectorIndexManager(this._dataStore) {
    _partitionManager = NghPartitionManager(_dataStore);
    _graphEngine = NghGraphEngine(_partitionManager);
    _vectorCache = VectorCache();
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

      // Load or create meta
      var meta =
          await _getOrCreateMeta(table, indexUid, fieldName, fieldSchema, idx);

      // NGH uses online ScalarQuantizer (SQ8) requiring zero training
      final quantizer = VectorQuantizer.empty();

      // -- Process inserts --
      if (inserts.isNotEmpty) {
        final preparedVectors = await _prepareInsertVectorsBatch(
          records: inserts,
          fieldName: fieldName,
          primaryKeyField: pkName,
          dimensions: meta.dimensions,
        );
        final vectors = preparedVectors.vectors;
        final pks = preparedVectors.primaryKeys;

        if (vectors.isNotEmpty) {
          // NGH Stream insert: online SQ8 quantization + dynamic single-bucket split
          final insertResult = await _graphEngine.insertBatch(
            table: table,
            indexUid: indexUid,
            meta: meta,
            quantizer: quantizer,
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
            navGraphPage: insertResult.navGraphPage,
            vectorsDelta: insertResult.insertedCount,
            concurrency: concurrency,
          );

          // Persist updated meta
          await _persistMeta(table, indexUid, meta);
        }
      }

      // -- Process deletes --
      if (deletes.isNotEmpty) {
        final deletePks = <String>[];
        final delYc = YieldController(
          'VectorIndexManager.writeChanges.deletes',
          checkInterval: 20,
          budgetMs: 30,
        );
        for (var di = 0; di < deletes.length; di++) {
          final y5 = delYc.maybeYield();
          if (y5 != null) await y5;
          final pk = deletes[di][pkName]?.toString();
          if (pk != null && pk.isNotEmpty) {
            deletePks.add(pk);
          }
        }

        if (deletePks.isNotEmpty) {
          final result = await _graphEngine.deleteBatch(
            table: table,
            indexUid: indexUid,
            meta: meta,
            primaryKeys: deletePks,
          );

          meta = await _partitionManager.writeChanges(
            table: table,
            indexUid: indexUid,
            meta: meta,
            dirtyPostingPages: result.dirtyPostingPages,
            deletedDelta: result.deletedCount,
            batchContext: batchContext,
            concurrency: concurrency,
          );
        }
      }

      // Persist updated meta
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
    int? efSearch,
    double? distanceThreshold,
  }) async {
    // Find the vector index for this field
    final schema =
        await _dataStore.tableMetaManager?.getTableSchema(table.tableUid);
    if (schema == null) return const [];

    final vectorIndexes =
        _dataStore.tableMetaManager?.getVectorIndexesFor(schema) ??
            const <IndexSchema>[];
    IndexSchema? targetIdx;
    for (final idx in vectorIndexes) {
      if (idx.fields.contains(fieldName)) {
        targetIdx = idx;
        break;
      }
    }
    if (targetIdx == null) return const [];

    final indexUid = targetIdx.indexUid;

    // Load meta (concurrently prefetch navGraph on cold start)
    var meta = _vectorCache.getMeta(table, indexUid);
    if (meta == null) {
      final navPrefetch = _graphEngine.prefetchNavGraph(table, indexUid);
      meta = await _loadMeta(table, indexUid);
      await navPrefetch;
    }
    if (meta == null || meta.isBuilding || meta.totalVectors == 0) {
      return const [];
    }

    // NGH engine uses direct inlined SQ8 scoring (0 external quantizer codebook read)
    final quantizer = VectorQuantizer.empty();

    // Prepare query vector
    final queryF32 = _toFloat32(queryVector.values, meta.dimensions);

    // Normalise for cosine metric
    Float32List searchQuery = queryF32;
    if (meta.distanceMetric == VectorDistanceMetric.cosine) {
      searchQuery = _normalizeFloat32(queryF32);
    }

    final results = await _graphEngine.search(
      table: table,
      indexUid: indexUid,
      meta: meta,
      quantizer: quantizer,
      query: searchQuery,
      topK: topK,
      efSearch: efSearch,
      distanceThreshold: distanceThreshold,
    );
    if (results.isEmpty) {
      return const [];
    }

    // PK is inlined in posting slots (0 secondary I/O).
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

  /// Prewarm vector index metadata and navigating centroid graph into memory cache.
  Future<void> prewarmVectorIndex(
    TableContext table,
    IndexUid indexUid,
  ) async {
    try {
      final navPrefetch = _graphEngine.prefetchNavGraph(table, indexUid);
      final meta = await _loadMeta(table, indexUid);
      if (meta != null && !meta.isBuilding && meta.totalVectors > 0) {
        await navPrefetch;
      }
    } catch (e) {
      Logger.warn(
        'Vector index prewarm failed for index "$indexUid" in table "${table.tableName}"',
        rawError: e,
      );
    }
  }

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
    if (pathKey.isNotEmpty && meta.indexUid != pathKey) {
      return meta.copyWith(indexUid: pathKey);
    }
    return meta;
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
    if (meta != null) return meta;

    // Try load from disk
    meta = await _loadMeta(table, indexUid);
    if (meta != null) {
      _vectorCache.putMeta(table, indexUid, meta);
      return meta;
    }

    // Create new
    final dims = fieldSchema.vectorConfig?.dimensions ?? 128;
    final vc = idx.vectorConfig;

    meta = NghIndexMeta.createEmpty(
      indexUid: indexUid,
      tableUid: table.tableUid,
      dimensions: dims,
      distanceMetric: vc?.distanceMetric ?? VectorDistanceMetric.cosine,
      precision: fieldSchema.vectorConfig?.precision ?? VectorPrecision.float32,
      maxDegree: vc?.maxDegree ?? 64,
      efSearch: vc?.efSearch ?? 64,
      constructionEf: vc?.constructionEf ?? 128,
      pruneAlpha: vc?.pruneAlpha ?? 1.2,
    );

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

    final initialMeta = NghIndexMeta.createEmpty(
      indexUid: indexUid,
      tableUid: table.tableUid,
      dimensions: dims,
      distanceMetric: metric,
      isBuilding: true,
    );

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

      if (result.dirtyPostingPages.isNotEmpty) {
        meta = await _partitionManager.writeChanges(
          table: table,
          indexUid: indexUid,
          meta: meta,
          dirtyPostingPages: result.dirtyPostingPages,
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
        _partitionManager.getCurrentPageCacheSize();
  }

  /// Evict caches under memory pressure.
  Future<void> evictCache({double ratio = 0.3}) async {
    await _vectorCache.evict(ratio: ratio);
    await _partitionManager.evictPageCache(ratio: ratio);
  }

  /// Clear all caches for a table.
  void clearCacheForTable(TableUid tableUid) {
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
    _vectorCache.clear();
    _partitionManager.clearPageCacheSync();
    _graphEngine.clearCache();
  }

  // =====================================================================
  // Private Helpers
  // =====================================================================

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

  /// Normalise a float32 vector to unit length.
  Float32List _normalizeFloat32(Float32List v) {
    double mag = 0;
    for (int i = 0; i < v.length; i++) {
      mag += v[i] * v[i];
    }
    mag = sqrt(mag);
    if (mag == 0) return v;
    final result = Float32List(v.length);
    final inv = 1.0 / mag;
    for (int i = 0; i < v.length; i++) {
      result[i] = v[i] * inv;
    }
    return result;
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
