import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../handler/logger.dart';
import '../handler/memcomparable.dart';
import '../model/data_block_entry.dart';
import '../model/meta_info.dart';
import '../model/ngh_index_meta.dart';
import '../model/query_result.dart';
import '../model/table_schema.dart';
import '../model/parallel_journal_entry.dart';
import 'compute_manager.dart';
import 'compute_tasks.dart';
import 'data_store_impl.dart';
import 'ngh_graph_engine.dart';
import 'ngh_page.dart';
import 'ngh_partition_manager.dart';
import 'vector_cache.dart';
import 'vector_quantizer.dart';
import 'yield_controller.dart';
import 'workload_scheduler.dart';

/// Manages all NGH vector indexes for the data store.
class VectorIndexManager {
  final DataStoreImpl _dataStore;

  late final NghPartitionManager _partitionManager;
  late final NghGraphEngine _graphEngine;
  late final VectorCache _vectorCache;

  /// In-flight meta loads — prevents parallel readers from each hitting disk.
  /// Key: "$tableName/$indexName", value: the single in-progress Future.
  final Map<String, Future<NghIndexMeta?>> _metaLoadingFutures = {};

  VectorIndexManager(this._dataStore) {
    _partitionManager = NghPartitionManager(_dataStore);
    _graphEngine = NghGraphEngine(_partitionManager);
    _vectorCache = VectorCache();
  }

  // =====================================================================
  // Write Changes — Called by ParallelJournalManager during flush
  // =====================================================================

  /// Apply vector index changes for a table during the flush pipeline.
  ///
  /// Extracts vector fields from records, encodes them, inserts into the
  /// NGH graph, and flushes dirty pages to disk — all batched.
  Future<void> writeChanges({
    required String tableName,
    List<Map<String, dynamic>> inserts = const [],
    List<Map<String, dynamic>> deletes = const [],
    BatchContext? batchContext,
    int? concurrency,
  }) async {
    final vectorIndexes =
        await _dataStore.schemaManager?.getVectorIndexesForTable(tableName);
    if (vectorIndexes == null || vectorIndexes.isEmpty) return;

    final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
    if (schema == null) return;
    final pkName = schema.primaryKey;

    final yc = YieldController(
      'VectorIndexManager.writeChanges',
      checkInterval: 30,
      budgetMs: 50,
    );

    for (final idx in vectorIndexes) {
      await yc.maybeYield();
      final indexName = idx.actualIndexName;
      final fieldName = idx.fields.first; // vector index is single-field
      FieldSchema? fieldSchema;
      try {
        fieldSchema = schema.fields.firstWhere((f) => f.name == fieldName);
      } catch (_) {
        continue;
      }

      // Load or create meta
      var meta = await _getOrCreateMeta(
          tableName, indexName, fieldName, fieldSchema, idx);

      // Load or train quantizer
      var quantizer = await _getOrTrainQuantizer(
          tableName, indexName, meta, inserts, fieldName);
      if (quantizer == null) continue; // not enough data yet

      // Ensure mapping B+Tree metas are initialised
      meta = _ensureMappingMetas(meta, tableName);

      // ── Process inserts ──
      if (inserts.isNotEmpty) {
        final vectors = <Float32List>[];
        final pks = <String>[];

        for (final record in inserts) {
          await yc.maybeYield();
          final vectorData = _extractVector(record, fieldName);
          if (vectorData == null) continue;
          final pk = record[pkName]?.toString();
          if (pk == null || pk.isEmpty) continue;

          final f32 = _toFloat32(vectorData, meta.dimensions);
          vectors.add(f32);
          pks.add(pk);
        }

        if (vectors.isNotEmpty) {
          final startNodeId = meta.nextNodeId;

          // Isolate: PQ encode only (no file I/O). Graph insert + flush on main.
          final quantizeResult = await ComputeManager.run(
            quantizeVectorsForNghTask,
            QuantizeVectorsForNghArgs(
              pqSubspaces: quantizer.codebook.subspaces,
              pqCentroids: quantizer.codebook.centroids,
              pqSubDimensions: quantizer.codebook.subDimensions,
              pqData: quantizer.codebook.data,
              vectors: vectors,
            ),
            useIsolate: true,
          );
          final pqCodes = quantizeResult.pqCodes;

          // Main isolate: graph insert + flush (all NGH file read/write here)
          final insertResult = await _graphEngine.insertBatch(
            tableName: tableName,
            indexName: indexName,
            meta: meta,
            quantizer: quantizer,
            vectors: vectors,
            pqCodes: pqCodes,
            yieldBudgetMs: 100,
          );
          meta = insertResult.meta;
          meta = await _partitionManager.writeChanges(
            tableName: tableName,
            indexName: indexName,
            meta: meta,
            dirtyGraphPages: insertResult.dirtyGraphPages,
            dirtyPqCodePages: insertResult.dirtyPqCodePages,
            dirtyRawVectorPages: insertResult.dirtyRawVectorPages,
            vectorsDelta: insertResult.insertedCount,
            concurrency: concurrency,
          );

          // Write nodeId ↔ PK dual B+Tree mappings (persistent, not in memory)
          meta = await _writeMappings(
            tableName: tableName,
            meta: meta,
            startNodeId: startNodeId,
            pks: pks,
            isDelete: false,
            batchContext: batchContext,
            concurrency: concurrency,
          );

          // Persist updated meta
          await _persistMeta(tableName, indexName, meta);
        }
      }

      // ── Process deletes ──
      if (deletes.isNotEmpty) {
        final nodeIdsToDelete = <int>[];
        final deletePks = <String>[];

        // Reverse lookup: PK → nodeId via B+Tree (disk, no memory map)
        final delYc = YieldController(
          'VectorIndexManager.writeChanges.deletes',
          checkInterval: 20,
          budgetMs: 30,
        );
        for (var di = 0; di < deletes.length; di++) {
          await delYc.maybeYield();
          final record = deletes[di];
          final pk = record[pkName]?.toString();
          if (pk == null) continue;
          final nodeId = await _lookupNodeIdByPk(tableName, meta, pk);
          if (nodeId != null) {
            nodeIdsToDelete.add(nodeId);
            deletePks.add(pk);
          }
        }

        if (nodeIdsToDelete.isNotEmpty) {
          final result = await _graphEngine.deleteBatch(
            tableName: tableName,
            indexName: indexName,
            meta: meta,
            nodeIds: nodeIdsToDelete,
          );

          // Remove mappings from both B+Trees
          meta = await _writeMappings(
            tableName: tableName,
            meta: meta,
            startNodeId: -1,
            pks: deletePks,
            isDelete: true,
            deleteNodeIds: nodeIdsToDelete,
            batchContext: batchContext,
            concurrency: concurrency,
          );

          meta = await _partitionManager.writeChanges(
            tableName: tableName,
            indexName: indexName,
            meta: meta,
            dirtyGraphPages: result.dirtyGraphPages,
            dirtyPqCodePages: const {},
            dirtyRawVectorPages: const {},
            deletedDelta: result.deletedCount,
            batchContext: batchContext,
            concurrency: concurrency,
          );
        }
      }

      // Persist updated meta
      await _persistMeta(tableName, indexName, meta);
      _vectorCache.putMeta(tableName, indexName, meta);
    }
  }

  // =====================================================================
  // vectorSearch — Public Search API
  // =====================================================================

  /// Perform approximate nearest neighbor search on a vector field.
  ///
  /// Returns the top-[topK] most similar records, sorted by similarity.
  Future<List<VectorSearchResult>> vectorSearch({
    required String tableName,
    required String fieldName,
    required VectorData queryVector,
    int topK = 10,
    int? efSearch,
    double? distanceThreshold,
  }) async {
    // Find the vector index for this field
    final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
    if (schema == null) return const [];

    final vectorIndexes =
        _dataStore.schemaManager?.getVectorIndexesFor(schema) ??
            const <IndexSchema>[];
    IndexSchema? targetIdx;
    for (final idx in vectorIndexes) {
      if (idx.fields.contains(fieldName)) {
        targetIdx = idx;
        break;
      }
    }
    if (targetIdx == null) return const [];

    final indexName = targetIdx.actualIndexName;

    // Load meta
    var meta = _vectorCache.getMeta(tableName, indexName);
    meta ??= await _loadMeta(tableName, indexName);
    if (meta == null || meta.totalVectors == 0) return const [];

    // Load quantizer
    final quantizer = await _getQuantizer(tableName, indexName, meta);
    if (quantizer == null) return const [];

    // Lazy full-cache preload in background (maintenance); does not block query
    _partitionManager.preloadForVectorSearch(tableName, indexName, meta);

    // Prepare query vector
    final queryF32 = _toFloat32(queryVector.values, meta.dimensions);

    // Normalise for cosine metric
    Float32List searchQuery = queryF32;
    if (meta.distanceMetric == VectorDistanceMetric.cosine) {
      searchQuery = _normalizeFloat32(queryF32);
    }

    // Acquire query workload lease for parallel I/O (flush has priority; query shares capacity).
    WorkloadLease? lease;
    try {
      lease = await _dataStore.workloadScheduler.acquire(
        WorkloadType.query,
        requestedTokens:
            _dataStore.workloadScheduler.capacityTokens(WorkloadType.query),
        minTokens: 1,
        label: 'VectorIndexManager.vectorSearch',
      );
    } catch (_) {
      lease = null;
    }

    List<NghSearchResult> results;
    try {
      results = await _graphEngine.search(
        tableName: tableName,
        indexName: indexName,
        meta: meta,
        quantizer: quantizer,
        query: searchQuery,
        topK: topK,
        efSearch: efSearch,
        distanceThreshold: distanceThreshold,
        workloadLease: lease,
      );
    } finally {
      lease?.release();
    }

    // Map nodeId → PK via persistent B+Tree (batch lookup to reduce leaf reads).
    if (results.isEmpty) return const [];
    // Sort by nodeId to exploit B+Tree leaf locality for batch lookup.
    final sortedByNode = List<NghSearchResult>.from(results)
      ..sort((a, b) => a.nodeId.compareTo(b.nodeId));
    final keys = [for (final r in sortedByNode) _encodeNodeIdKey(r.nodeId)];
    final nid2pk = meta.nodeIdToPkMeta;
    final pks = (nid2pk == null || nid2pk.btreeFirstLeaf.isNull)
        ? List<String?>.filled(sortedByNode.length, null, growable: false)
        : await _dataStore.indexTreePartitionManager
            .lookupUniquePrimaryKeysBatch(
            tableName: tableName,
            indexName: meta.nid2pkIndexName,
            meta: nid2pk,
            uniqueKeys: keys,
          );
    final entries = <VectorSearchResult>[];
    final searchYc = YieldController(
      'VectorIndexManager.vectorSearch.lookupPk',
      checkInterval: 25,
      budgetMs: 40,
    );
    for (int i = 0; i < sortedByNode.length; i++) {
      await searchYc.maybeYield();
      final pk = pks[i];
      if (pk == null) continue;
      entries.add(VectorSearchResult(
        primaryKey: pk,
        distance: sortedByNode[i].distance,
        score: _distanceToScore(sortedByNode[i].distance, meta.distanceMetric),
      ));
    }
    // Re-sort by distance for final output
    entries.sort((a, b) => a.distance.compareTo(b.distance));
    return entries;
  }

  // =====================================================================
  // Meta Persistence
  // =====================================================================

  /// Load meta from disk with coalesce: concurrent callers share a single I/O.
  Future<NghIndexMeta?> _loadMeta(String tableName, String indexName) {
    final loadKey = '$tableName/$indexName';
    final existing = _metaLoadingFutures[loadKey];
    if (existing != null) return existing;

    final future = _doLoadMeta(tableName, indexName).whenComplete(() {
      _metaLoadingFutures.remove(loadKey);
    });
    _metaLoadingFutures[loadKey] = future;
    return future;
  }

  Future<NghIndexMeta?> _doLoadMeta(String tableName, String indexName) async {
    try {
      final path =
          await _dataStore.pathManager.getNghMetaPath(tableName, indexName);
      final content = await _dataStore.storage.readAsString(path);
      if (content == null || content.isEmpty) return null;
      final json = jsonDecode(content) as Map<String, dynamic>;
      final meta = NghIndexMeta.fromJson(json);
      _vectorCache.putMeta(tableName, indexName, meta);
      return meta;
    } catch (_) {
      return null;
    }
  }

  Future<void> _persistMeta(
      String tableName, String indexName, NghIndexMeta meta) async {
    try {
      final path =
          await _dataStore.pathManager.getNghMetaPath(tableName, indexName);
      final content = jsonEncode(meta.toJson());
      await _dataStore.storage.writeAsString(path, content, flush: false);
    } catch (e) {
      Logger.error('Failed to persist NGH meta: $e',
          label: 'VectorIndexManager');
    }
  }

  Future<NghIndexMeta> _getOrCreateMeta(
    String tableName,
    String indexName,
    String fieldName,
    FieldSchema fieldSchema,
    IndexSchema idx,
  ) async {
    // Check cache
    var meta = _vectorCache.getMeta(tableName, indexName);
    if (meta != null) return meta;

    // Try load from disk
    meta = await _loadMeta(tableName, indexName);
    if (meta != null) {
      _vectorCache.putMeta(tableName, indexName, meta);
      return meta;
    }

    // Create new
    final dims = fieldSchema.vectorConfig?.dimensions ?? 128;
    final vc = idx.vectorConfig;

    meta = NghIndexMeta.createEmpty(
      name: indexName,
      tableName: tableName,
      fieldName: fieldName,
      dimensions: dims,
      distanceMetric: vc?.distanceMetric ?? VectorDistanceMetric.cosine,
      precision: fieldSchema.vectorConfig?.precision ?? VectorPrecision.float32,
      maxDegree: vc?.maxDegree ?? 64,
      efSearch: vc?.efSearch ?? 64,
      constructionEf: vc?.constructionEf ?? 128,
      pruneAlpha: vc?.pruneAlpha ?? 1.2,
      pqSubspaces: vc?.pqSubspaces ?? NghIndexMeta.autoPqSubspaces(dims),
      maxPartitionFileSize: _dataStore.config.maxPartitionFileSize,
    );

    _vectorCache.putMeta(tableName, indexName, meta);
    return meta;
  }

  // =====================================================================
  // Quantizer Management
  // =====================================================================

  Future<VectorQuantizer?> _getQuantizer(
      String tableName, String indexName, NghIndexMeta meta) async {
    // Check codebook cache
    var pqCodebook = _vectorCache.getCodebook(tableName, indexName);

    if (pqCodebook == null) {
      // Load from disk
      final cbPage = await _partitionManager.readCodebook(
          tableName, indexName, meta.nghPageSize);
      if (cbPage == null) return null;

      pqCodebook = PqCodebook(
        subspaces: cbPage.subspaceCount,
        centroids: cbPage.centroidsPerSubspace,
        subDimensions: cbPage.subspaceDimensions,
        data: cbPage.centroids,
      );
      _vectorCache.putCodebook(tableName, indexName, pqCodebook);
    }

    final quantizer = VectorQuantizer(pqCodebook);
    // Consistency check: ensure loaded quantizer matches current meta
    if (quantizer.subspaces == meta.pqSubspaces &&
        quantizer.dimensions == meta.dimensions) {
      return quantizer;
    }

    Logger.warn(
        'Existing quantizer mismatch for $indexName: '
        'loaded(${quantizer.dimensions}d, ${quantizer.subspaces}m) != '
        'meta(${meta.dimensions}d, ${meta.pqSubspaces}m). '
        'Retraining might be required.',
        label: 'VectorIndexManager');

    return null;
  }

  Future<VectorQuantizer?> _getOrTrainQuantizer(
    String tableName,
    String indexName,
    NghIndexMeta meta,
    List<Map<String, dynamic>> inserts,
    String fieldName,
  ) async {
    // Try cached/loaded first (returns null on mismatch)
    final existing = await _getQuantizer(tableName, indexName, meta);
    if (existing != null) {
      return existing;
    }

    // Need to train — collect sample vectors from inserts
    final samples = <Float32List>[];
    final trainYc = YieldController(
      'VectorIndexManager._getOrTrainQuantizer.samples',
      checkInterval: 50,
      budgetMs: 30,
    );
    for (var si = 0; si < inserts.length && samples.length < 2500; si++) {
      await trainYc.maybeYield();
      final record = inserts[si];
      final vec = _extractVector(record, fieldName);
      if (vec == null) continue;
      samples.add(_toFloat32(vec, meta.dimensions));
    }

    if (samples.isEmpty) return null;

    // Train codebook
    final PqCodebook codebook;
    if (samples.length >= 100) {
      // Flatten data for isolate transfer
      final n = samples.length;
      final dim = meta.dimensions;
      final flatSamples = Float32List(n * dim);
      final flatYc = YieldController(
        'VectorIndexManager._getOrTrainQuantizer.flat',
        checkInterval: 200,
        budgetMs: 20,
      );
      for (int i = 0; i < n; i++) {
        await flatYc.maybeYield();
        flatSamples.setRange(i * dim, (i + 1) * dim, samples[i]);
      }
      // Acquire flush workload lease (flush has priority in scheduler)
      WorkloadLease? lease;
      try {
        lease = await _dataStore.workloadScheduler.acquire(
          WorkloadType.flush,
          label: 'VectorIndexManager.PQ.train',
        );
      } catch (e) {
        // Fallback if scheduler not available or error
        Logger.warn('Failed to acquire workload lease, proceeding without: $e',
            label: 'VectorIndexManager');
      }

      try {
        final subspaces = meta.pqSubspaces;
        final subDim = dim ~/ subspaces;
        final k = min(256, n);
        final futures = <Future<PqSubspaceResult>>[];

        final subYc = YieldController(
          'VectorIndexManager._getOrTrainQuantizer.subSamples',
          checkInterval: 100,
          budgetMs: 15,
        );
        for (int m = 0; m < subspaces; m++) {
          await subYc.maybeYield();
          // Extract the specific column (sub-vectors) for this subspace
          final subSamples = Float32List(n * subDim);
          final subStart = m * subDim;
          for (int i = 0; i < n; i++) {
            final srcOff = i * dim + subStart;
            final dstOff = i * subDim;
            for (int d = 0; d < subDim; d++) {
              subSamples[dstOff + d] = flatSamples[srcOff + d];
            }
          }

          futures
              .add(ComputeManager.run<PqTrainSubspaceRequest, PqSubspaceResult>(
            trainPqSubspace,
            PqTrainSubspaceRequest(
              subSamples: subSamples,
              n: n,
              subDim: subDim,
              k: k,
              iterations: 10,
              subspaceIndex: m,
            ),
          ));
        }

        final results = await Future.wait(futures);

        final fullData = Float32List(subspaces * k * subDim);
        for (final res in results) {
          final m = res.subspaceIndex;
          // Copy centroids: [m * k * subDim ... ]
          final centerSrc = res.centroids;
          final centerDstOff = m * k * subDim;
          for (int i = 0; i < centerSrc.length; i++) {
            fullData[centerDstOff + i] = centerSrc[i];
          }
        }

        codebook = PqCodebook(
          subspaces: subspaces,
          centroids: k,
          subDimensions: subDim,
          data: fullData,
        );
      } finally {
        lease?.release();
      }
    } else {
      codebook = await VectorQuantizer.train(
        samples: samples,
        dimensions: meta.dimensions,
        subspaces: meta.pqSubspaces,
        numCentroids: min(256, samples.length),
        iterations: 10,
      );
    }

    // Persist codebook
    final subDim = meta.dimensions ~/ meta.pqSubspaces;
    final cbPage = NghCodebookPage(
      subspaceStart: 0,
      subspaceCount: codebook.subspaces,
      centroidsPerSubspace: codebook.centroids,
      subspaceDimensions: subDim,
      centroids: codebook.data,
    );
    await _partitionManager.writeCodebook(
        tableName, indexName, cbPage, meta.nghPageSize);

    _vectorCache.putCodebook(tableName, indexName, codebook);
    return VectorQuantizer(codebook);
  }

  // =====================================================================
  // Background Maintenance
  // =====================================================================

  /// Run background tombstone compaction for all vector indexes in a table.
  ///
  /// Repairs graph edges around deleted nodes and reclaims tombstone slots.
  /// Should be called periodically by the compaction manager, using
  /// [WorkloadType.maintenance] tokens.
  Future<void> compactTombstones(String tableName,
      {int maxVisitedPages = 100}) async {
    final vectorIndexes =
        await _dataStore.schemaManager?.getVectorIndexesForTable(tableName);
    if (vectorIndexes == null || vectorIndexes.isEmpty) return;

    final yc = YieldController(
      'VectorIndexManager.compactTombstones',
      checkInterval: 20,
      budgetMs: 40,
    );
    for (final idx in vectorIndexes) {
      await yc.maybeYield();
      final indexName = idx.actualIndexName;
      var meta = _vectorCache.getMeta(tableName, indexName);
      meta ??= await _loadMeta(tableName, indexName);
      if (meta == null) continue;

      // Skip if deletion ratio is low (< 10%)
      if (meta.totalVectors == 0 ||
          meta.deletedCount / meta.totalVectors < 0.1) {
        continue;
      }

      final result = await _graphEngine.compactTombstones(
        tableName: tableName,
        indexName: indexName,
        meta: meta,
        maxVisitedPages: maxVisitedPages,
      );

      if (result.dirtyGraphPages.isNotEmpty) {
        meta = await _partitionManager.writeChanges(
          tableName: tableName,
          indexName: indexName,
          meta: meta,
          dirtyGraphPages: result.dirtyGraphPages,
          dirtyPqCodePages: const {},
          dirtyRawVectorPages: const {},
          deletedDelta: -result.compactedCount,
        );
        await _persistMeta(tableName, indexName, meta);
        _vectorCache.putMeta(tableName, indexName, meta);
      }
    }
  }

  /// Reorder graph nodes by BFS traversal from medoid for access locality.
  ///
  /// Nodes visited in the same search neighbourhood are placed on the same
  /// or adjacent pages, dramatically improving disk I/O during beam search.
  /// This is a heavyweight maintenance operation — run it infrequently
  /// (e.g. after large bulk imports) using [WorkloadType.maintenance] tokens.
  ///
  /// Returns `true` if reordering was performed.
  Future<bool> reorderByLocality(String tableName, String indexName) async {
    var meta = _vectorCache.getMeta(tableName, indexName);
    meta ??= await _loadMeta(tableName, indexName);
    if (meta == null || meta.totalVectors < 2 || meta.medoidNodeId < 0) {
      return false;
    }

    // Phase 1: BFS from medoid to determine visit order.
    // Uses Uint8List bitmap (128MB for 10^9 nodes) instead of List<bool> (1GB).
    final totalNodes = meta.nextNodeId;
    final bitmapBytes = (totalNodes + 7) >> 3;
    final visitedBits = Uint8List(bitmapBytes);

    void markVisited(int id) {
      visitedBits[id >> 3] |= (1 << (id & 7));
    }

    bool isVisited(int id) {
      return (visitedBits[id >> 3] & (1 << (id & 7))) != 0;
    }

    final bfsOrder = <int>[];
    // Use ListQueue for O(1) dequeue instead of List.removeAt(0) which is O(n).
    final queue = ListQueue<int>();
    queue.add(meta.medoidNodeId);
    markVisited(meta.medoidNodeId);
    final yc = YieldController('VectorIndexManager.reorder', checkInterval: 50);

    while (queue.isNotEmpty) {
      await yc.maybeYield();
      final current = queue.removeFirst();
      bfsOrder.add(current);

      final neighbors =
          await _loadNeighborsForReorder(tableName, indexName, meta, current);
      if (neighbors == null) continue;
      for (int i = 0; i < neighbors.length; i++) {
        final nId = neighbors[i];
        if (nId < totalNodes && !isVisited(nId)) {
          markVisited(nId);
          queue.add(nId);
        }
      }
    }

    // Add any unvisited nodes (disconnected components)
    for (int i = 0; i < totalNodes; i++) {
      if (i > 0 && i % 50000 == 0) await yc.maybeYield();
      if (!isVisited(i)) bfsOrder.add(i);
    }

    // Phase 2: Build old→new ID mapping (Int32List: 4GB for 10^9 nodes)
    final oldToNew = Int32List(totalNodes);
    for (int i = 0; i < totalNodes; i++) {
      if (i > 0 && i % 50000 == 0) await yc.maybeYield();
      oldToNew[i] = -1;
    }
    for (int newId = 0; newId < bfsOrder.length; newId++) {
      if (newId > 0 && newId % 50000 == 0) await yc.maybeYield();
      oldToNew[bfsOrder[newId]] = newId;
    }

    // Phase 3: Rebuild all pages with new IDs
    final dirtyGraph = <NghPagePtr, NghGraphPage>{};
    final dirtyPq = <NghPagePtr, NghPqCodePage>{};
    final dirtyRaw = <NghPagePtr, NghRawVectorPage>{};
    final localGraphCache = <int, NghGraphPage>{};
    final localPqCache = <int, NghPqCodePage>{};
    final localRawCache = <int, NghRawVectorPage>{};

    for (int newId = 0; newId < bfsOrder.length; newId++) {
      await yc.maybeYield();
      final oldId = bfsOrder[newId];

      // Read old graph node
      final oldPartition = meta.graphPartitionForNode(oldId);
      final oldPage = meta.graphLocalPageForNode(oldId);
      final oldSlot = meta.graphSlotForNode(oldId);
      final oldGraphPage = await _partitionManager.readGraphPage(
          tableName, indexName, meta, oldPartition, oldPage,
          localCache: localGraphCache);

      final node = oldSlot < oldGraphPage.slots.length
          ? oldGraphPage.slots[oldSlot]
          : null;
      if (node == null || node.isDeleted) continue;

      // Remap neighbor IDs
      final remappedNeighbors = Uint32List(meta.maxDegree);
      int degree = 0;
      for (int j = 0; j < node.actualDegree; j++) {
        final nOldId = node.neighbors[j];
        if (nOldId < totalNodes && oldToNew[nOldId] >= 0) {
          remappedNeighbors[degree++] = oldToNew[nOldId];
        }
      }

      // Write to new position
      final newPartition = meta.graphPartitionForNode(newId);
      final newPage = meta.graphLocalPageForNode(newId);
      final newSlot = meta.graphSlotForNode(newId);
      final newGraphPageKey = newPartition << 20 | newPage;

      var targetPage = localGraphCache[newGraphPageKey];
      targetPage ??= NghGraphPage.empty(
          maxDegree: meta.maxDegree, slotCount: meta.nodesPerGraphPage);

      if (newSlot < targetPage.slots.length) {
        targetPage.slots[newSlot].flags = node.flags;
        targetPage.slots[newSlot].actualDegree = degree;
        targetPage.slots[newSlot].neighbors.setAll(0, remappedNeighbors);
      }
      localGraphCache[newGraphPageKey] = targetPage;
      dirtyGraph[NghPagePtr(NghDataCategory.graph, newPartition, newPage)] =
          targetPage;

      // Copy PQ code: old slot → new slot
      final oldPqPartition = meta.pqPartitionForNode(oldId);
      final oldPqPage = meta.pqLocalPageForNode(oldId);
      final oldPqSlot = meta.pqSlotForNode(oldId);
      final oldPqCodePage = await _partitionManager.readPqCodePage(
          tableName, indexName, meta, oldPqPartition, oldPqPage,
          localCache: localPqCache);
      final pqCode = oldPqCodePage.getCode(oldPqSlot);

      final newPqPartition = meta.pqPartitionForNode(newId);
      final newPqPage = meta.pqLocalPageForNode(newId);
      final newPqSlot = meta.pqSlotForNode(newId);
      final newPqKey = newPqPartition << 20 | newPqPage;
      var targetPq = localPqCache[newPqKey];
      targetPq ??= NghPqCodePage.empty(
          pqSubspaces: meta.pqSubspaces, capacity: meta.vectorsPerPqPage);
      targetPq.setCode(newPqSlot, pqCode);
      localPqCache[newPqKey] = targetPq;
      dirtyPq[NghPagePtr(NghDataCategory.pqCode, newPqPartition, newPqPage)] =
          targetPq;

      // Copy raw vector: old slot → new slot
      final oldRawPartition = meta.rawVectorPartitionForNode(oldId);
      final oldRawPage = meta.rawVectorLocalPageForNode(oldId);
      final oldRawSlot = meta.rawVectorSlotForNode(oldId);
      final oldRawVecPage = await _partitionManager.readRawVectorPage(
          tableName, indexName, meta, oldRawPartition, oldRawPage);
      final rawVec = oldRawVecPage.getVectorAsFloat32(oldRawSlot);

      final newRawPartition = meta.rawVectorPartitionForNode(newId);
      final newRawPage = meta.rawVectorLocalPageForNode(newId);
      final newRawSlot = meta.rawVectorSlotForNode(newId);
      final newRawKey = newRawPartition << 20 | newRawPage;

      var targetRaw = localRawCache[newRawKey];
      targetRaw ??= NghRawVectorPage.empty(
          dimensions: meta.dimensions,
          precisionIndex: meta.precision.index,
          capacity: meta.vectorsPerRawPage);

      targetRaw.setVectorFromFloat32(newRawSlot, rawVec);
      localRawCache[newRawKey] = targetRaw;
      dirtyRaw[NghPagePtr(
          NghDataCategory.rawVector, newRawPartition, newRawPage)] = targetRaw;
    }

    // Phase 4: Flush and update meta
    final newMedoid = oldToNew[meta.medoidNodeId];
    meta = meta.copyWith(
      medoidNodeId: newMedoid >= 0 ? newMedoid : 0,
      nextNodeId: bfsOrder.length,
      deletedCount: 0, // compacted all tombstones during reorder
    );

    meta = await _partitionManager.writeChanges(
      tableName: tableName,
      indexName: indexName,
      meta: meta,
      dirtyGraphPages: dirtyGraph,
      dirtyPqCodePages: dirtyPq,
      dirtyRawVectorPages: dirtyRaw,
    );

    // Phase 5: Rebuild nodeId ↔ PK mapping with new IDs
    // Requires reading old mappings and writing new ones
    meta = _ensureMappingMetas(meta, tableName);
    final nid2pkDeltas = <DataBlockEntry>[];
    final pk2nidDeltas = <DataBlockEntry>[];

    for (int newId = 0; newId < bfsOrder.length; newId++) {
      await yc.maybeYield();
      final oldId = bfsOrder[newId];
      if (oldToNew[oldId] < 0) continue;

      // Read old PK
      final pk = await _lookupPkByNodeId(tableName, meta, oldId);
      if (pk == null) continue;

      // Delete old mappings
      nid2pkDeltas.add(
          DataBlockEntry(_encodeNodeIdKey(oldId), Uint8List.fromList([1])));
      pk2nidDeltas.add(DataBlockEntry(
          Uint8List.fromList(utf8.encode(pk)), Uint8List.fromList([1])));

      // Insert new mappings
      nid2pkDeltas
          .add(DataBlockEntry(_encodeNodeIdKey(newId), _encodeUniqueValue(pk)));
      pk2nidDeltas.add(DataBlockEntry(Uint8List.fromList(utf8.encode(pk)),
          _encodeUniqueValue(newId.toString())));
    }

    if (nid2pkDeltas.isNotEmpty) {
      await _dataStore.indexTreePartitionManager.writeChanges(
        tableName: tableName,
        indexName: meta.nid2pkIndexName,
        indexMeta: meta.nodeIdToPkMeta!,
        deltas: nid2pkDeltas,
      );
      await _dataStore.indexTreePartitionManager.writeChanges(
        tableName: tableName,
        indexName: meta.pk2nidIndexName,
        indexMeta: meta.pkToNodeIdMeta!,
        deltas: pk2nidDeltas,
      );
    }

    await _persistMeta(tableName, indexName, meta);
    _vectorCache.putMeta(tableName, indexName, meta);
    _partitionManager.clearFullyCachedForIndex(tableName, indexName);
    _partitionManager.clearPageCacheForIndex(tableName, indexName);
    return true;
  }

  /// Helper: load neighbors for reorder (bypasses deletion check).
  Future<Uint32List?> _loadNeighborsForReorder(
      String tableName, String indexName, NghIndexMeta meta, int nodeId) async {
    final partitionNo = meta.graphPartitionForNode(nodeId);
    final pageNo = meta.graphLocalPageForNode(nodeId);
    final slot = meta.graphSlotForNode(nodeId);
    final page = await _partitionManager.readGraphPage(
        tableName, indexName, meta, partitionNo, pageNo);
    if (slot >= page.slots.length) return null;
    final node = page.slots[slot];
    if (node.isDeleted || node.actualDegree == 0) return null;
    return node.neighbors.sublist(0, node.actualDegree);
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
  void clearCacheForTable(String tableName) {
    _vectorCache.clearForTable(tableName);
    _partitionManager.clearPageCacheForTable(tableName);
  }

  /// Clear all caches.
  void clearAllCaches() {
    _vectorCache.clear();
    _partitionManager.clearPageCacheSync();
  }

  // =====================================================================
  // nodeId ↔ PK Persistent B+Tree Mapping
  // =====================================================================

  /// Ensure mapping B+Tree IndexMeta objects exist in [meta].
  NghIndexMeta _ensureMappingMetas(NghIndexMeta meta, String tableName) {
    bool changed = false;
    IndexMeta? nid2pk = meta.nodeIdToPkMeta;
    IndexMeta? pk2nid = meta.pkToNodeIdMeta;

    if (nid2pk == null) {
      nid2pk = IndexMeta.createEmpty(
        name: meta.nid2pkIndexName,
        tableName: tableName,
        fields: const ['__nodeId'],
        isUnique: true,
      );
      changed = true;
    }
    if (pk2nid == null) {
      pk2nid = IndexMeta.createEmpty(
        name: meta.pk2nidIndexName,
        tableName: tableName,
        fields: const ['__pk'],
        isUnique: true,
      );
      changed = true;
    }
    if (changed) {
      meta = meta.copyWith(nodeIdToPkMeta: nid2pk, pkToNodeIdMeta: pk2nid);
    }
    return meta;
  }

  /// Batch-write nodeId ↔ PK mappings to dual B+Trees.
  ///
  /// For inserts: [startNodeId] is the first allocated nodeId, [pks] aligned.
  /// For deletes: [deleteNodeIds] and [pks] aligned; [startNodeId] is ignored.
  Future<NghIndexMeta> _writeMappings({
    required String tableName,
    required NghIndexMeta meta,
    required int startNodeId,
    required List<String> pks,
    required bool isDelete,
    List<int>? deleteNodeIds,
    BatchContext? batchContext,
    int? concurrency,
  }) async {
    if (pks.isEmpty) return meta;

    final nid2pkDeltas = <DataBlockEntry>[];
    final pk2nidDeltas = <DataBlockEntry>[];
    final mapYc = YieldController(
      'VectorIndexManager._writeMappings',
      checkInterval: 100,
      budgetMs: 30,
    );

    for (int i = 0; i < pks.length; i++) {
      await mapYc.maybeYield();
      final nodeId = isDelete ? deleteNodeIds![i] : startNodeId + i;
      final pk = pks[i];
      final nodeIdKey = _encodeNodeIdKey(nodeId);
      final pkKey = MemComparableKey.encodeTextLex(pk);

      if (isDelete) {
        // Tombstone marker: [1]
        final deleteVal = Uint8List.fromList([1]);
        nid2pkDeltas.add(DataBlockEntry(nodeIdKey, deleteVal));
        pk2nidDeltas.add(DataBlockEntry(pkKey, deleteVal));
      } else {
        // Insert value: [0][utf8(value)] — compatible with lookupUniquePrimaryKey
        nid2pkDeltas.add(DataBlockEntry(nodeIdKey, _encodeUniqueValue(pk)));
        pk2nidDeltas
            .add(DataBlockEntry(pkKey, _encodeUniqueValue(nodeId.toString())));
      }
    }

    // Write both mappings in parallel — no data dependency between them.
    var nid2pkMeta = meta.nodeIdToPkMeta!;
    var pk2nidMeta = meta.pkToNodeIdMeta!;

    await Future.wait([
      _dataStore.indexTreePartitionManager.writeChanges(
        tableName: tableName,
        indexName: meta.nid2pkIndexName,
        indexMeta: nid2pkMeta,
        deltas: nid2pkDeltas,
        batchContext: batchContext,
        concurrency: concurrency,
      ),
      _dataStore.indexTreePartitionManager.writeChanges(
        tableName: tableName,
        indexName: meta.pk2nidIndexName,
        indexMeta: pk2nidMeta,
        deltas: pk2nidDeltas,
        batchContext: batchContext,
        concurrency: concurrency,
      ),
    ]);

    // Re-read the updated metas in parallel
    final metaResults = await Future.wait([
      _dataStore.indexManager?.getIndexMeta(tableName, meta.nid2pkIndexName) ??
          Future.value(nid2pkMeta),
      _dataStore.indexManager?.getIndexMeta(tableName, meta.pk2nidIndexName) ??
          Future.value(pk2nidMeta),
    ]);
    nid2pkMeta = metaResults[0] ?? nid2pkMeta;
    pk2nidMeta = metaResults[1] ?? pk2nidMeta;

    return meta.copyWith(
        nodeIdToPkMeta: nid2pkMeta, pkToNodeIdMeta: pk2nidMeta);
  }

  Future<String?> _lookupPkByNodeId(
      String tableName, NghIndexMeta meta, int nodeId) async {
    final nid2pk = meta.nodeIdToPkMeta;
    if (nid2pk == null || nid2pk.btreeFirstLeaf.isNull) return null;
    final pk =
        await _dataStore.indexTreePartitionManager.lookupUniquePrimaryKey(
      tableName: tableName,
      indexName: meta.nid2pkIndexName,
      meta: nid2pk,
      uniqueKey: _encodeNodeIdKey(nodeId),
    );
    return pk;
  }

  /// Look up nodeId by PK via the reverse B+Tree (disk, with LRU page cache).
  Future<int?> _lookupNodeIdByPk(
      String tableName, NghIndexMeta meta, String pk) async {
    final pk2nid = meta.pkToNodeIdMeta;
    if (pk2nid == null || pk2nid.btreeFirstLeaf.isNull) return null;
    final result =
        await _dataStore.indexTreePartitionManager.lookupUniquePrimaryKey(
      tableName: tableName,
      indexName: meta.pk2nidIndexName,
      meta: pk2nid,
      uniqueKey: MemComparableKey.encodeTextLex(pk),
    );
    if (result == null) return null;
    return int.tryParse(result);
  }

  /// Encode nodeId as 4-byte big-endian (naturally memcomparable for unsigned).
  Uint8List _encodeNodeIdKey(int nodeId) {
    return MemComparableKey.encodeInt64(nodeId);
  }

  /// Encode a unique-index value: [0x00][utf8(value)].
  /// Compatible with [IndexTreePartitionManager.lookupUniquePrimaryKey].
  Uint8List _encodeUniqueValue(String value) {
    final encoded = utf8.encode(value);
    final result = Uint8List(1 + encoded.length);
    result[0] = 0; // exists marker
    result.setRange(1, result.length, encoded);
    return result;
  }

  // =====================================================================
  // Private Helpers
  // =====================================================================

  /// Extract vector data from a record's field value.
  List<double>? _extractVector(Map<String, dynamic> record, String fieldName) {
    final value = record[fieldName];
    if (value == null) return null;
    if (value is VectorData) return value.values;
    if (value is List<double>) return value;
    if (value is List<num>) {
      return value.map((v) => v.toDouble()).toList(growable: false);
    }
    return null;
  }

  /// Convert double list to Float32List, ensuring correct dimensions.
  Float32List _toFloat32(List<double> values, int dimensions) {
    final f32 = Float32List(dimensions);
    final len = min(values.length, dimensions);
    for (int i = 0; i < len; i++) {
      f32[i] = values[i];
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
        // L2 distance → score: 1 / (1 + distance)
        return 1.0 / (1.0 + distance);
      case VectorDistanceMetric.innerProduct:
        // Inner product was negated for min-heap; negate back and sigmoid
        return 1.0 / (1.0 + exp(-(-distance)));
      case VectorDistanceMetric.cosine:
        // Cosine distance = 1 - similarity → score = 1 - distance
        return (1.0 - distance).clamp(0.0, 1.0);
    }
  }
}
