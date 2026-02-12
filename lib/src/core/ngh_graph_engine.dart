import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import '../handler/parallel_processor.dart';
import '../model/ngh_index_meta.dart';
import '../model/table_schema.dart';
import 'ngh_page.dart';
import 'ngh_partition_manager.dart';
import 'vector_quantizer.dart';
import 'workload_scheduler.dart';
import 'yield_controller.dart';

// ============================================================================
// NGH Graph Engine — Vamana Graph Construction & Beam Search
//
// Responsibilities:
//   1. Greedy search with ADC pre-filtering (beam search)
//   2. Robust Prune for diverse neighbor selection
//   3. Incremental insertion (no rebuild needed)
//   4. Tombstone-based deletion
//   5. Full-vector re-ranking for final result quality
// ============================================================================

/// A search result with node ID and distance.
class NghSearchResult {
  final int nodeId;

  /// Approximate distance (from ADC or exact, depending on phase).
  double distance;

  /// The primary key of the record this vector belongs to.
  final String? primaryKey;

  NghSearchResult({
    required this.nodeId,
    required this.distance,
    this.primaryKey,
  });
}

/// Entry in the search priority queue.
class _SearchCandidate implements Comparable<_SearchCandidate> {
  final int nodeId;
  final double distance;

  _SearchCandidate(this.nodeId, this.distance);

  @override
  int compareTo(_SearchCandidate other) => distance.compareTo(other.distance);
}

/// NGH Graph Engine — core graph construction and search algorithms.
class NghGraphEngine {
  final NghPartitionManager _partitionManager;

  NghGraphEngine(this._partitionManager);

  // =====================================================================
  // Search — Beam Search with ADC + Full-Vector Re-ranking
  // =====================================================================

  /// Perform ANN search: beam search using PQ ADC, then re-rank with full vectors.
  ///
  /// Returns top-[topK] results sorted by distance (ascending for L2/cosine,
  /// ascending-of-negated for inner-product).
  Future<List<NghSearchResult>> search({
    required String tableName,
    required String indexName,
    required NghIndexMeta meta,
    required VectorQuantizer quantizer,
    required Float32List query,
    required int topK,
    int? efSearch,
    double? distanceThreshold,
    WorkloadLease? workloadLease,
  }) async {
    if (meta.totalVectors == 0 || meta.medoidNodeId < 0) return const [];

    final efRaw = efSearch ?? meta.efSearch;
    // When topK is small, use a smaller ef to reduce beam steps and I/O without hurting recall for top‑K.
    final ef = min(efRaw, max(topK * 5, 32));
    final yc = YieldController('NghGraphEngine.search', checkInterval: 100);

    // Phase 1: Build ADC distance table (once per query)
    final Float32List distTable;
    switch (meta.distanceMetric) {
      case VectorDistanceMetric.innerProduct:
        distTable = quantizer.buildDistanceTableIP(query);
        break;
      case VectorDistanceMetric.cosine:
        distTable = quantizer.buildDistanceTableCosine(query);
        break;
      default:
        distTable = quantizer.buildDistanceTable(query);
    }

    // Phase 2: Beam search through graph using ADC distances (parallel PQ reads when lease present)
    final candidates = await _beamSearch(
      tableName: tableName,
      indexName: indexName,
      meta: meta,
      quantizer: quantizer,
      distTable: distTable,
      entryNodeId: meta.medoidNodeId,
      ef: ef,
      yc: yc,
      workloadLease: workloadLease,
    );

    if (candidates.isEmpty) return const [];

    // Phase 3: Re-rank top candidates with full vectors (parallel raw-vector page reads when lease present).
    // For small topK, cap rerank pool to reduce raw-vector I/O (topK*2 + margin is enough for recall).
    final rerankCount = min(candidates.length, max(topK * 2, 20));
    final toRerank = candidates.sublist(0, rerankCount);
    final nodeIds = [for (final c in toRerank) c.nodeId];
    final rawVectors = await _loadRawVectorsBatch(
        tableName, indexName, meta, nodeIds,
        workloadLease: workloadLease);

    final results = <NghSearchResult>[];
    for (int i = 0; i < toRerank.length; i++) {
      final rawVec = rawVectors[i];
      if (rawVec == null) continue;
      final exactDist = _exactDistance(query, rawVec, meta.distanceMetric);
      if (distanceThreshold != null && exactDist > distanceThreshold) continue;
      results.add(
          NghSearchResult(nodeId: toRerank[i].nodeId, distance: exactDist));
    }

    // Sort by distance and take topK
    results.sort((a, b) => a.distance.compareTo(b.distance));
    return results.length <= topK ? results : results.sublist(0, topK);
  }

  /// Core beam search using ADC distances on PQ codes.
  ///
  /// Optimised for 10^9-scale search with:
  ///   - Fixed-size binary heaps (zero GC pressure, O(log ef) push/pop)
  ///   - Sparse visited set (HashSet capped by search scope, not data size)
  ///   - Batch graph-page reads: neighbors on the same page share one I/O
  ///   - Batch PQ-code reads: neighbours on the same PQ page share one I/O
  ///   - Deletion check piggybacked on the already-loaded graph page
  Future<List<_SearchCandidate>> _beamSearch({
    required String tableName,
    required String indexName,
    required NghIndexMeta meta,
    required VectorQuantizer quantizer,
    required Float32List distTable,
    required int entryNodeId,
    required int ef,
    required YieldController yc,
    WorkloadLease? workloadLease,
  }) async {
    //  Visited set: bounded so we don't run unbounded in degenerate graphs.
    final visited = HashSet<int>();
    //  Safety cap only: allow up to 2× totalVectors so recall stays high (95%+); just prevent runaway (e.g. 10× N).
    //  In a well-built graph we early-terminate long before this; cap is not hit and recall is unchanged.
    final int maxVisited =
        min(ef * meta.maxDegree * 3, meta.totalVectors * 2 + 256);

    //  Fixed-size min-heap for candidates (explore queue).
    final int heapCap = ef * 4;
    final _FixedHeap candidateHeap = _FixedHeap(heapCap);

    //  Fixed-size max-heap for results (worst-first for eviction).
    final _FixedHeap resultHeap = _FixedHeap(ef, maxHeap: true);

    //  Load entry point
    final entryCode =
        await _loadPqCode(tableName, indexName, meta, entryNodeId);
    if (entryCode == null) return const [];
    final entryDist = quantizer.adcDistance(distTable, entryCode);

    visited.add(entryNodeId);
    candidateHeap.push(entryNodeId, entryDist);
    resultHeap.push(entryNodeId, entryDist);

    //  Graph page cache local to this search (avoids cross-search pollution)
    final graphPageLocal = <int, NghGraphPage>{};

    int steps = 0;
    while (candidateHeap.isNotEmpty) {
      if (steps++ % 16 == 0) await yc.maybeYield();

      //  Safety: stop if traversal grows beyond 2×N (degenerate graph); normal search exits earlier.
      if (visited.length >= maxVisited) break;

      final currentId = candidateHeap.popId();
      final currentDist = candidateHeap.lastPoppedDist;

      // Early termination when next candidate is worse than worst in result heap
      if (resultHeap.isFull && currentDist > resultHeap.peekDist) break;

      //  Load graph page (reused for all neighbours on this page)
      final gPartition = meta.graphPartitionForNode(currentId);
      final gPage = meta.graphLocalPageForNode(currentId);
      final gSlot = meta.graphSlotForNode(currentId);
      final gKey = gPartition << 20 | gPage;
      var graphPage = graphPageLocal[gKey];
      graphPage ??= await _partitionManager.readGraphPage(
          tableName, indexName, meta, gPartition, gPage,
          localCache: graphPageLocal);
      graphPageLocal[gKey] = graphPage;

      if (gSlot >= graphPage.slots.length) continue;
      final node = graphPage.slots[gSlot];
      if (node.isDeleted || node.actualDegree == 0) continue;

      //  Group neighbours by PQ-code page for batch loading
      // Key: "$pqPartition:$pqPage", Value: list of (neighborId, pqSlot)
      final pqPageGroups = <int, List<(int, int)>>{};
      for (int i = 0; i < node.actualDegree; i++) {
        final nId = node.neighbors[i];
        if (visited.contains(nId)) continue;
        visited.add(nId);

        // Piggyback deletion check: if neighbour is on the SAME graph page,
        // we already have the page loaded — zero extra I/O.
        final nPartition = meta.graphPartitionForNode(nId);
        final nPage = meta.graphLocalPageForNode(nId);
        final nSlot = meta.graphSlotForNode(nId);
        if (nPartition == gPartition && nPage == gPage) {
          if (nSlot < graphPage.slots.length &&
              graphPage.slots[nSlot].isDeleted) {
            continue;
          }
        }
        // For neighbours on OTHER graph pages, skip the per-neighbor I/O
        // for deletion check — rare false positives (deleted nodes) just get
        // a bad distance and naturally fall out of the result heap.

        final pqP = meta.pqPartitionForNode(nId);
        final pqPg = meta.pqLocalPageForNode(nId);
        final pqSlot = meta.pqSlotForNode(nId);
        pqPageGroups.putIfAbsent(pqP << 20 | pqPg, () => []).add((nId, pqSlot));
      }

      //  Batch PQ code reads: parallel when lease allows, else serial
      final pqEntries = pqPageGroups.entries.toList();
      final int pqConcurrency = (workloadLease != null && pqEntries.length > 1)
          ? workloadLease.asConcurrency(0.3)
          : 1;
      if (pqConcurrency > 1) {
        final pqTasks = [
          for (final pgEntry in pqEntries)
            () => _partitionManager.readPqCodePage(tableName, indexName, meta,
                pgEntry.key >> 20, pgEntry.key & 0xFFFFF),
        ];
        final pqPages = await ParallelProcessor.execute<NghPqCodePage>(pqTasks,
            concurrency: min(pqConcurrency, pqTasks.length),
            label: 'NghGraphEngine._beamSearch.pq');
        for (int i = 0; i < pqEntries.length; i++) {
          final pqPage = pqPages[i];
          if (pqPage == null) continue;
          for (final (nId, pqSlot) in pqEntries[i].value) {
            if (pqSlot >= pqPage.vectorCount) continue;
            final code = pqPage.getCode(pqSlot);
            final dist = quantizer.adcDistance(distTable, code);
            if (!resultHeap.isFull || dist < resultHeap.peekDist) {
              candidateHeap.push(nId, dist);
              resultHeap.push(nId, dist);
            }
          }
        }
      } else {
        for (final pgEntry in pqEntries) {
          final pqPartition = pgEntry.key >> 20;
          final pqPageNo = pgEntry.key & 0xFFFFF;
          final pqPage = await _partitionManager.readPqCodePage(
              tableName, indexName, meta, pqPartition, pqPageNo);
          for (final (nId, pqSlot) in pgEntry.value) {
            if (pqSlot >= pqPage.vectorCount) continue;
            final code = pqPage.getCode(pqSlot);
            final dist = quantizer.adcDistance(distTable, code);
            if (!resultHeap.isFull || dist < resultHeap.peekDist) {
              candidateHeap.push(nId, dist);
              resultHeap.push(nId, dist);
            }
          }
        }
      }
    }

    //  Extract sorted results from the max-heap
    return resultHeap.drainSorted();
  }

  // =====================================================================
  // Insertion — Incremental Vamana Insert
  // =====================================================================

  /// Insert a batch of vectors into the graph.
  ///
  /// Returns the dirty pages that need to be flushed, and the updated meta.
  Future<NghInsertResult> insertBatch({
    required String tableName,
    required String indexName,
    required NghIndexMeta meta,
    required VectorQuantizer quantizer,
    required List<Float32List> vectors,
    required List<Uint8List> pqCodes,
    int? yieldBudgetMs,
  }) async {
    final dirtyGraph = <NghPagePtr, NghGraphPage>{};
    final dirtyPq = <NghPagePtr, NghPqCodePage>{};
    final dirtyRaw = <NghPagePtr, NghRawVectorPage>{};
    final localGraphCache = <int, NghGraphPage>{};
    final localPqCache = <int, NghPqCodePage>{};
    final localRawCache = <int, NghRawVectorPage>{};

    final yc = YieldController('NghGraphEngine.insertBatch',
        checkInterval: 50, budgetMs: yieldBudgetMs);
    var currentMeta = meta;

    for (int i = 0; i < vectors.length; i++) {
      await yc.maybeYield();
      final vector = vectors[i];
      final pqCode = pqCodes[i];
      final nodeId = currentMeta.nextNodeId;
      currentMeta = currentMeta.copyWith(nextNodeId: nodeId + 1);

      // 1. Write PQ code
      currentMeta = await _writePqCode(tableName, indexName, currentMeta,
          nodeId, pqCode, dirtyPq, localPqCache);

      // 2. Write raw vector
      currentMeta = await _writeRawVector(tableName, indexName, currentMeta,
          nodeId, vector, dirtyRaw, localRawCache);

      // 3. Find neighbors via greedy search
      List<int> neighborIds;
      final existingCount = currentMeta.totalVectors + i;
      if (existingCount == 0) {
        // First vector: no neighbors, becomes medoid
        neighborIds = [];
        currentMeta = currentMeta.copyWith(medoidNodeId: nodeId);
      } else if (existingCount < 4 || currentMeta.medoidNodeId < 0) {
        // Very small graph (< 4 nodes): connect to all existing nodes directly
        // instead of running beam search which has no meaningful graph to traverse.
        neighborIds = List.generate(
          existingCount.clamp(0, currentMeta.maxDegree),
          (j) => (nodeId - existingCount) + j,
        );
        // Set medoid to the very first node if not set
        if (currentMeta.medoidNodeId < 0) {
          currentMeta = currentMeta.copyWith(medoidNodeId: 0);
        }
      } else {
        neighborIds = await _greedySearchForInsert(
          tableName,
          indexName,
          currentMeta,
          quantizer,
          vector,
          pqCode,
          localGraphCache,
          localPqCache,
          yieldBudgetMs: yieldBudgetMs,
        );
        // Robust Prune: select diverse subset when candidates exceed max degree
        if (neighborIds.length > currentMeta.maxDegree) {
          neighborIds = await _robustPrune(
            tableName,
            indexName,
            currentMeta,
            quantizer,
            nodeId,
            neighborIds,
            localPqCache,
          );
        }
      }

      // 4. Write new node's graph slot
      currentMeta = await _writeGraphNode(tableName, indexName, currentMeta,
          nodeId, neighborIds, dirtyGraph, localGraphCache);

      // 5. Add reverse edges (bidirectional)
      for (final neighborId in neighborIds) {
        await yc.maybeYield();
        currentMeta = await _addReverseEdge(
          tableName,
          indexName,
          currentMeta,
          quantizer,
          neighborId,
          nodeId,
          dirtyGraph,
          localGraphCache,
          localPqCache,
        );
      }
    }

    return NghInsertResult(
      meta: currentMeta,
      dirtyGraphPages: dirtyGraph,
      dirtyPqCodePages: dirtyPq,
      dirtyRawVectorPages: dirtyRaw,
      insertedCount: vectors.length,
    );
  }

  // =====================================================================
  // Deletion — Tombstone Marking
  // =====================================================================

  /// Mark nodes as deleted (tombstone). Actual cleanup is deferred to maintenance.
  Future<NghDeleteResult> deleteBatch({
    required String tableName,
    required String indexName,
    required NghIndexMeta meta,
    required List<int> nodeIds,
  }) async {
    final dirtyGraph = <NghPagePtr, NghGraphPage>{};
    final localCache = <int, NghGraphPage>{};
    final yc = YieldController('NghGraphEngine.deleteBatch', checkInterval: 50);

    for (final nodeId in nodeIds) {
      await yc.maybeYield();
      final partitionNo = meta.graphPartitionForNode(nodeId);
      final pageNo = meta.graphLocalPageForNode(nodeId);
      final slot = meta.graphSlotForNode(nodeId);
      final cacheKey = partitionNo << 20 | pageNo;

      var page = localCache[cacheKey];
      page ??= await _partitionManager.readGraphPage(
          tableName, indexName, meta, partitionNo, pageNo,
          localCache: localCache);

      if (slot < page.slots.length) {
        page.slots[slot].flags |= NghNodeFlags.deleted;
        localCache[cacheKey] = page;
        dirtyGraph[NghPagePtr(NghDataCategory.graph, partitionNo, pageNo)] =
            page;
      }
    }

    return NghDeleteResult(
      dirtyGraphPages: dirtyGraph,
      deletedCount: nodeIds.length,
    );
  }

  // =====================================================================
  // Robust Prune — Diverse Neighbor Selection
  // =====================================================================

  /// Select up to R diverse neighbors from candidates using α-rule.
  Future<List<int>> _robustPrune(
    String tableName,
    String indexName,
    NghIndexMeta meta,
    VectorQuantizer quantizer,
    int nodeId,
    List<int> candidates,
    Map<int, NghPqCodePage> localPqCache,
  ) async {
    final r = meta.maxDegree;
    final alpha = meta.pruneAlpha;

    // Load PQ code for the node being pruned
    final nodeCode = await _loadPqCode(tableName, indexName, meta, nodeId,
        localCache: localPqCache);
    if (nodeCode == null) return candidates.take(r).toList();

    // Build distance table from node's PQ code (approximate)
    // For pruning, we use pairwise PQ distances between candidates
    // Load all candidate PQ codes
    // Batch-load PQ codes grouped by page for reduced I/O
    final candidateCodes = <int, Uint8List>{};
    final pqPageGroups = <int, List<(int, int)>>{};
    for (final cId in candidates) {
      final pqP = meta.pqPartitionForNode(cId);
      final pqPg = meta.pqLocalPageForNode(cId);
      final pqSlot = meta.pqSlotForNode(cId);
      pqPageGroups.putIfAbsent(pqP << 20 | pqPg, () => []).add((cId, pqSlot));
    }
    for (final pgEntry in pqPageGroups.entries) {
      final pqPage = await _partitionManager.readPqCodePage(
          tableName, indexName, meta, pgEntry.key >> 20, pgEntry.key & 0xFFFFF,
          localCache: localPqCache);
      for (final (cId, pqSlot) in pgEntry.value) {
        if (pqSlot < pqPage.vectorCount) {
          candidateCodes[cId] = pqPage.getCode(pqSlot);
        }
      }
    }

    // Sort candidates by distance to node
    final sortedCandidates =
        candidates.where((c) => candidateCodes.containsKey(c)).toList();
    // Use a simple PQ code distance approximation for sorting
    sortedCandidates.sort((a, b) {
      final distA = _pqCodeDistance(nodeCode, candidateCodes[a]!);
      final distB = _pqCodeDistance(nodeCode, candidateCodes[b]!);
      return distA.compareTo(distB);
    });

    // Greedy selection with diversity
    final result = <int>[];
    for (final cId in sortedCandidates) {
      if (result.length >= r) break;
      final cCode = candidateCodes[cId]!;
      final distToNode = _pqCodeDistance(nodeCode, cCode);

      bool covered = false;
      for (final rId in result) {
        final rCode = candidateCodes[rId]!;
        final distCR = _pqCodeDistance(cCode, rCode);
        if (alpha * distCR < distToNode) {
          covered = true;
          break;
        }
      }
      if (!covered) result.add(cId);
    }

    return result;
  }

  /// Simple Hamming-like PQ code distance (for pruning, not search).
  double _pqCodeDistance(Uint8List a, Uint8List b) {
    double dist = 0;
    for (int i = 0; i < a.length; i++) {
      final diff = (a[i] - b[i]).toDouble();
      dist += diff * diff;
    }
    return dist;
  }

  // =====================================================================
  // Private Page Access Helpers
  // =====================================================================

  Future<Uint8List?> _loadPqCode(
    String tableName,
    String indexName,
    NghIndexMeta meta,
    int nodeId, {
    Map<int, NghPqCodePage>? localCache,
  }) async {
    final partitionNo = meta.pqPartitionForNode(nodeId);
    final pageNo = meta.pqLocalPageForNode(nodeId);
    final slot = meta.pqSlotForNode(nodeId);

    final page = await _partitionManager.readPqCodePage(
        tableName, indexName, meta, partitionNo, pageNo,
        localCache: localCache);
    if (slot >= page.vectorCount) return null;
    return page.getCode(slot);
  }

  /// Batch load raw vectors for [nodeIds], grouped by page to minimize I/O.
  /// When [workloadLease] is set, reads unique pages in parallel via [ParallelProcessor].
  /// Returns list in same order as [nodeIds]; null where vector unavailable.
  Future<List<Float32List?>> _loadRawVectorsBatch(
    String tableName,
    String indexName,
    NghIndexMeta meta,
    List<int> nodeIds, {
    WorkloadLease? workloadLease,
  }) async {
    if (nodeIds.isEmpty) return const [];
    final result = List<Float32List?>.filled(nodeIds.length, null);
    final pageKeyToIndices =
        <int, List<(int, int)>>{}; // pageKey -> [(nodeIds index, slot)]
    for (int i = 0; i < nodeIds.length; i++) {
      final nodeId = nodeIds[i];
      final partitionNo = meta.rawVectorPartitionForNode(nodeId);
      final pageNo = meta.rawVectorLocalPageForNode(nodeId);
      final slot = meta.rawVectorSlotForNode(nodeId);
      final key = partitionNo << 20 | pageNo;
      pageKeyToIndices.putIfAbsent(key, () => []).add((i, slot));
    }
    final entries = pageKeyToIndices.entries.toList();
    final int concurrency = (workloadLease != null && entries.length > 1)
        ? workloadLease.asConcurrency(0.3)
        : 1;
    if (concurrency > 1) {
      final tasks = [
        for (final entry in entries)
          () => _partitionManager.readRawVectorPage(
              tableName, indexName, meta, entry.key >> 20, entry.key & 0xFFFFF),
      ];
      final pages = await ParallelProcessor.execute<NghRawVectorPage>(tasks,
          concurrency: min(concurrency, tasks.length),
          label: 'NghGraphEngine._loadRawVectorsBatch');
      for (int i = 0; i < entries.length; i++) {
        final page = pages[i];
        if (page == null) continue;
        for (final (idx, slot) in entries[i].value) {
          if (slot < page.vectorCount) {
            result[idx] = page.getVectorAsFloat32(slot);
          }
        }
      }
    } else {
      for (final entry in entries) {
        final partitionNo = entry.key >> 20;
        final pageNo = entry.key & 0xFFFFF;
        final page = await _partitionManager.readRawVectorPage(
            tableName, indexName, meta, partitionNo, pageNo);
        for (final (idx, slot) in entry.value) {
          if (slot < page.vectorCount) {
            result[idx] = page.getVectorAsFloat32(slot);
          }
        }
      }
    }
    return result;
  }

  Future<Uint32List?> _loadNeighbors(
    String tableName,
    String indexName,
    NghIndexMeta meta,
    int nodeId, {
    Map<int, NghGraphPage>? localCache,
  }) async {
    final partitionNo = meta.graphPartitionForNode(nodeId);
    final pageNo = meta.graphLocalPageForNode(nodeId);
    final slot = meta.graphSlotForNode(nodeId);

    final page = await _partitionManager.readGraphPage(
        tableName, indexName, meta, partitionNo, pageNo,
        localCache: localCache);
    if (slot >= page.slots.length) return null;
    final node = page.slots[slot];
    if (node.isDeleted) return null;
    // Return only valid neighbors (sublist for web-safe access)
    return node.neighbors.sublist(0, node.actualDegree);
  }

  Future<bool> _isNodeDeleted(
    String tableName,
    String indexName,
    NghIndexMeta meta,
    int nodeId, {
    Map<int, NghGraphPage>? localCache,
  }) async {
    final partitionNo = meta.graphPartitionForNode(nodeId);
    final pageNo = meta.graphLocalPageForNode(nodeId);
    final slot = meta.graphSlotForNode(nodeId);

    final page = await _partitionManager.readGraphPage(
        tableName, indexName, meta, partitionNo, pageNo,
        localCache: localCache);
    if (slot >= page.slots.length) return true;
    return page.slots[slot].isDeleted;
  }

  // =====================================================================
  // Private Write Helpers
  // =====================================================================

  Future<NghIndexMeta> _writePqCode(
    String tableName,
    String indexName,
    NghIndexMeta meta,
    int nodeId,
    Uint8List pqCode,
    Map<NghPagePtr, NghPqCodePage> dirtyPages,
    Map<int, NghPqCodePage> localCache,
  ) async {
    final partitionNo = meta.pqPartitionForNode(nodeId);
    final pageNo = meta.pqLocalPageForNode(nodeId);
    final slot = meta.pqSlotForNode(nodeId);
    final cacheKey = partitionNo << 20 | pageNo;

    // Ensure page exists, allocate if needed
    if (pageNo >= meta.pqCodeNextPageNo &&
        partitionNo == meta.pqCodePartitionCount - 1) {
      // Need to advance next page
      meta = meta.copyWith(pqCodeNextPageNo: pageNo + 1);
    }

    var page = localCache[cacheKey];
    page ??= await _partitionManager.readPqCodePage(
        tableName, indexName, meta, partitionNo, pageNo,
        localCache: localCache);

    page.setCode(slot, pqCode);
    localCache[cacheKey] = page;
    dirtyPages[NghPagePtr(NghDataCategory.pqCode, partitionNo, pageNo)] = page;
    return meta;
  }

  Future<NghIndexMeta> _writeRawVector(
    String tableName,
    String indexName,
    NghIndexMeta meta,
    int nodeId,
    Float32List vector,
    Map<NghPagePtr, NghRawVectorPage> dirtyPages,
    Map<int, NghRawVectorPage> localCache,
  ) async {
    final partitionNo = meta.rawVectorPartitionForNode(nodeId);
    final pageNo = meta.rawVectorLocalPageForNode(nodeId);
    final slot = meta.rawVectorSlotForNode(nodeId);
    final cacheKey = partitionNo << 20 | pageNo;

    if (pageNo >= meta.rawVectorNextPageNo &&
        partitionNo == meta.rawVectorPartitionCount - 1) {
      meta = meta.copyWith(rawVectorNextPageNo: pageNo + 1);
    }

    var page = localCache[cacheKey];
    page ??= await _partitionManager.readRawVectorPage(
        tableName, indexName, meta, partitionNo, pageNo,
        localCache: localCache);

    page.setVectorFromFloat32(slot, vector);
    localCache[cacheKey] = page;
    dirtyPages[NghPagePtr(NghDataCategory.rawVector, partitionNo, pageNo)] =
        page;
    return meta;
  }

  Future<NghIndexMeta> _writeGraphNode(
    String tableName,
    String indexName,
    NghIndexMeta meta,
    int nodeId,
    List<int> neighborIds,
    Map<NghPagePtr, NghGraphPage> dirtyPages,
    Map<int, NghGraphPage> localCache,
  ) async {
    final partitionNo = meta.graphPartitionForNode(nodeId);
    final pageNo = meta.graphLocalPageForNode(nodeId);
    final slot = meta.graphSlotForNode(nodeId);
    final cacheKey = partitionNo << 20 | pageNo;

    if (pageNo >= meta.graphNextPageNo &&
        partitionNo == meta.graphPartitionCount - 1) {
      meta = meta.copyWith(graphNextPageNo: pageNo + 1);
    }

    var page = localCache[cacheKey];
    page ??= await _partitionManager.readGraphPage(
        tableName, indexName, meta, partitionNo, pageNo,
        localCache: localCache);

    if (slot < page.slots.length) {
      final node = page.slots[slot];
      node.flags = 0; // clear any flags
      node.actualDegree = min(neighborIds.length, meta.maxDegree);
      for (int j = 0; j < node.actualDegree; j++) {
        node.neighbors[j] = neighborIds[j];
      }
    }

    localCache[cacheKey] = page;
    dirtyPages[NghPagePtr(NghDataCategory.graph, partitionNo, pageNo)] = page;
    return meta;
  }

  /// Add reverse edge: neighborId → nodeId.
  /// If neighbor is already at max degree, apply Robust Prune.
  Future<NghIndexMeta> _addReverseEdge(
    String tableName,
    String indexName,
    NghIndexMeta meta,
    VectorQuantizer quantizer,
    int neighborId,
    int nodeId,
    Map<NghPagePtr, NghGraphPage> dirtyPages,
    Map<int, NghGraphPage> localCache,
    Map<int, NghPqCodePage> localPqCache,
  ) async {
    final partitionNo = meta.graphPartitionForNode(neighborId);
    final pageNo = meta.graphLocalPageForNode(neighborId);
    final slot = meta.graphSlotForNode(neighborId);
    final cacheKey = partitionNo << 20 | pageNo;

    var page = localCache[cacheKey];
    page ??= await _partitionManager.readGraphPage(
        tableName, indexName, meta, partitionNo, pageNo,
        localCache: localCache);

    if (slot >= page.slots.length) return meta;
    final node = page.slots[slot];
    if (node.isDeleted) return meta;

    // Check if already connected
    for (int j = 0; j < node.actualDegree; j++) {
      if (node.neighbors[j] == nodeId) return meta; // already connected
    }

    if (node.actualDegree < meta.maxDegree) {
      // Room available: just add
      node.neighbors[node.actualDegree] = nodeId;
      node.actualDegree++;
    } else {
      // At max degree: collect current neighbors + new, then prune
      final currentNeighbors = <int>[];
      for (int j = 0; j < node.actualDegree; j++) {
        currentNeighbors.add(node.neighbors[j]);
      }
      currentNeighbors.add(nodeId);

      final pruned = await _robustPrune(
        tableName,
        indexName,
        meta,
        quantizer,
        neighborId,
        currentNeighbors,
        localPqCache,
      );

      node.actualDegree = min(pruned.length, meta.maxDegree);
      for (int j = 0; j < node.actualDegree; j++) {
        node.neighbors[j] = pruned[j];
      }
    }

    localCache[cacheKey] = page;
    dirtyPages[NghPagePtr(NghDataCategory.graph, partitionNo, pageNo)] = page;
    return meta;
  }

  /// Greedy search for insertion: find ef_construction nearest neighbors.
  ///
  /// Uses the same optimised heap + batch I/O as [_beamSearch].
  Future<List<int>> _greedySearchForInsert(
    String tableName,
    String indexName,
    NghIndexMeta meta,
    VectorQuantizer quantizer,
    Float32List vector,
    Uint8List pqCode,
    Map<int, NghGraphPage> localGraphCache,
    Map<int, NghPqCodePage> localPqCache, {
    int? yieldBudgetMs,
  }) async {
    final ef = meta.constructionEf;
    final distTable = quantizer.buildDistanceTable(vector);
    final yc = YieldController('NghGraphEngine.greedyInsert',
        checkInterval: 100, budgetMs: yieldBudgetMs);

    if (meta.medoidNodeId < 0) return const [];
    final entryCode = await _loadPqCode(
        tableName, indexName, meta, meta.medoidNodeId,
        localCache: localPqCache);
    if (entryCode == null) return [meta.medoidNodeId];
    final entryDist = quantizer.adcDistance(distTable, entryCode);

    final visited = HashSet<int>();
    final candidateHeap = _FixedHeap(ef * 4);
    final resultHeap = _FixedHeap(ef, maxHeap: true);

    visited.add(meta.medoidNodeId);
    candidateHeap.push(meta.medoidNodeId, entryDist);
    resultHeap.push(meta.medoidNodeId, entryDist);

    int steps = 0;
    while (candidateHeap.isNotEmpty) {
      if (steps++ % 16 == 0) await yc.maybeYield();

      final currentId = candidateHeap.popId();
      final currentDist = candidateHeap.lastPoppedDist;
      if (resultHeap.isFull && currentDist > resultHeap.peekDist) break;

      final neighbors = await _loadNeighbors(
          tableName, indexName, meta, currentId,
          localCache: localGraphCache);
      if (neighbors == null) continue;

      // Batch PQ reads: group by PQ page
      final pqGroups = <int, List<(int, int)>>{};
      for (int i = 0; i < neighbors.length; i++) {
        final nId = neighbors[i];
        if (visited.contains(nId)) continue;
        visited.add(nId);
        final pqP = meta.pqPartitionForNode(nId);
        final pqPg = meta.pqLocalPageForNode(nId);
        final pqSlot = meta.pqSlotForNode(nId);
        pqGroups.putIfAbsent(pqP << 20 | pqPg, () => []).add((nId, pqSlot));
      }

      for (final pgEntry in pqGroups.entries) {
        final pqPage = await _partitionManager.readPqCodePage(tableName,
            indexName, meta, pgEntry.key >> 20, pgEntry.key & 0xFFFFF,
            localCache: localPqCache);

        for (final (nId, pqSlot) in pgEntry.value) {
          if (pqSlot >= pqPage.vectorCount) continue;
          final code = pqPage.getCode(pqSlot);
          final dist = quantizer.adcDistance(distTable, code);
          if (!resultHeap.isFull || dist < resultHeap.peekDist) {
            candidateHeap.push(nId, dist);
            resultHeap.push(nId, dist);
          }
        }
      }
    }

    return resultHeap.drainSorted().map((c) => c.nodeId).toList();
  }

  // =====================================================================
  // Exact Distance Computation (for re-ranking)
  // =====================================================================

  double _exactDistance(
      Float32List a, Float32List b, VectorDistanceMetric metric) {
    switch (metric) {
      case VectorDistanceMetric.l2:
        return _l2Distance(a, b);
      case VectorDistanceMetric.innerProduct:
        return -_innerProduct(a, b); // negate: higher IP = more similar
      case VectorDistanceMetric.cosine:
        return 1.0 - _cosineSimlarity(a, b);
    }
  }

  double _l2Distance(Float32List a, Float32List b) {
    double sum = 0;
    for (int i = 0; i < a.length; i++) {
      final diff = a[i] - b[i];
      sum += diff * diff;
    }
    return sqrt(sum);
  }

  double _innerProduct(Float32List a, Float32List b) {
    double sum = 0;
    for (int i = 0; i < a.length; i++) {
      sum += a[i] * b[i];
    }
    return sum;
  }

  double _cosineSimlarity(Float32List a, Float32List b) {
    double dot = 0, magA = 0, magB = 0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      magA += a[i] * a[i];
      magB += b[i] * b[i];
    }
    final denom = sqrt(magA) * sqrt(magB);
    return denom > 0 ? dot / denom : 0;
  }

  // =====================================================================
  // Background Maintenance — Tombstone Compaction
  // =====================================================================

  /// Compact tombstoned nodes by repairing neighbor connections.
  ///
  /// Scans graph pages, finds deleted nodes, and for each live node that
  /// references a deleted neighbor, replaces that edge with an alternative
  /// from the deleted node's own neighbors (transitive reconnection).
  ///
  /// [maxVisitedPages] caps the amount of work per invocation.
  /// Returns dirty graph pages and count of compacted tombstones.
  Future<NghCompactResult> compactTombstones({
    required String tableName,
    required String indexName,
    required NghIndexMeta meta,
    int maxVisitedPages = 100,
  }) async {
    final dirtyGraph = <NghPagePtr, NghGraphPage>{};
    final localCache = <int, NghGraphPage>{};
    final yc = YieldController('NghGraphEngine.compact', checkInterval: 20);

    int compactedCount = 0;
    int pagesVisited = 0;

    // Scan graph pages sequentially
    for (int pNo = 0; pNo < meta.graphPartitionCount; pNo++) {
      final maxPageNo = (pNo == meta.graphPartitionCount - 1)
          ? meta.graphNextPageNo
          : meta.graphPagesPerPartition + NghIndexMeta.firstDataPageNo;

      for (int pgNo = NghIndexMeta.firstDataPageNo; pgNo < maxPageNo; pgNo++) {
        if (pagesVisited >= maxVisitedPages) {
          return NghCompactResult(
              dirtyGraphPages: dirtyGraph, compactedCount: compactedCount);
        }
        pagesVisited++;
        await yc.maybeYield();

        final cacheKey = pNo << 20 | pgNo;
        var page = localCache[cacheKey];
        page ??= await _partitionManager.readGraphPage(
            tableName, indexName, meta, pNo, pgNo,
            localCache: localCache);
        bool pageDirty = false;

        for (int s = 0; s < page.slots.length; s++) {
          final node = page.slots[s];
          if (node.isDeleted || node.actualDegree == 0) continue;

          // Check each neighbor: if it's deleted, try to replace it
          bool nodeDirty = false;
          for (int n = 0; n < node.actualDegree; n++) {
            await yc.maybeYield();
            final neighborId = node.neighbors[n];
            final isDeleted = await _isNodeDeleted(
                tableName, indexName, meta, neighborId,
                localCache: localCache);
            if (!isDeleted) continue;

            // Load the deleted neighbor's own neighbors for reconnection
            final deletedNeighbors = await _loadNeighbors(
                tableName, indexName, meta, neighborId,
                localCache: localCache);

            // Find a replacement: first non-deleted, non-self, non-duplicate neighbor
            int replacement = -1;
            if (deletedNeighbors != null) {
              for (int dn = 0; dn < deletedNeighbors.length; dn++) {
                final candidate = deletedNeighbors[dn];
                if (candidate == neighborId) continue;
                // Check not already in our neighbor list
                bool duplicate = false;
                for (int k = 0; k < node.actualDegree; k++) {
                  if (node.neighbors[k] == candidate) {
                    duplicate = true;
                    break;
                  }
                }
                if (duplicate) continue;
                final candDeleted = await _isNodeDeleted(
                    tableName, indexName, meta, candidate,
                    localCache: localCache);
                if (!candDeleted) {
                  replacement = candidate;
                  break;
                }
              }
            }

            if (replacement >= 0) {
              node.neighbors[n] = replacement;
              nodeDirty = true;
            } else {
              // No valid replacement: remove this edge (shift left)
              for (int k = n; k < node.actualDegree - 1; k++) {
                node.neighbors[k] = node.neighbors[k + 1];
              }
              node.actualDegree--;
              n--; // re-check this position
              nodeDirty = true;
            }
          }
          if (nodeDirty) pageDirty = true;
        }

        // Count deleted slots on this page and mark them as compacted
        for (int s = 0; s < page.slots.length; s++) {
          if (page.slots[s].isDeleted && page.slots[s].actualDegree > 0) {
            page.slots[s].actualDegree =
                0; // clear edges for compacted tombstone
            page.slots[s].flags |= NghNodeFlags.updated;
            pageDirty = true;
            compactedCount++;
          }
        }

        if (pageDirty) {
          localCache[cacheKey] = page;
          dirtyGraph[NghPagePtr(NghDataCategory.graph, pNo, pgNo)] = page;
        }
      }
    }

    return NghCompactResult(
        dirtyGraphPages: dirtyGraph, compactedCount: compactedCount);
  }
}

// ============================================================================
// Result Types
// ============================================================================

/// Result of a batch insertion operation.
class NghInsertResult {
  final NghIndexMeta meta;
  final Map<NghPagePtr, NghGraphPage> dirtyGraphPages;
  final Map<NghPagePtr, NghPqCodePage> dirtyPqCodePages;
  final Map<NghPagePtr, NghRawVectorPage> dirtyRawVectorPages;
  final int insertedCount;

  NghInsertResult({
    required this.meta,
    required this.dirtyGraphPages,
    required this.dirtyPqCodePages,
    required this.dirtyRawVectorPages,
    required this.insertedCount,
  });
}

/// Result of a batch deletion operation.
class NghDeleteResult {
  final Map<NghPagePtr, NghGraphPage> dirtyGraphPages;
  final int deletedCount;

  NghDeleteResult({
    required this.dirtyGraphPages,
    required this.deletedCount,
  });
}

/// Result of a background tombstone compaction.
class NghCompactResult {
  final Map<NghPagePtr, NghGraphPage> dirtyGraphPages;
  final int compactedCount;

  NghCompactResult({
    required this.dirtyGraphPages,
    required this.compactedCount,
  });
}

// ============================================================================
// Fixed-Size Binary Heap — Zero-GC Search Primitive
// ============================================================================

/// A fixed-capacity binary heap storing (nodeId, distance) pairs.
///
/// Avoids GC-triggering allocations during the beam-search hot loop.
/// - [maxHeap] = false → min-heap (for candidate exploration queue).
/// - [maxHeap] = true  → max-heap (for result eviction, worst-first).
///
/// All operations are O(log capacity) with zero object allocation.
class _FixedHeap {
  final int capacity;
  final bool maxHeap;

  late final Int32List _ids;
  late final Float64List _dists;
  int _size = 0;

  /// Distance of the last element removed by [popId].
  double lastPoppedDist = 0;

  _FixedHeap(this.capacity, {this.maxHeap = false}) {
    _ids = Int32List(capacity + 1); // +1 for swap space
    _dists = Float64List(capacity + 1);
  }

  bool get isNotEmpty => _size > 0;
  bool get isFull => _size >= capacity;

  /// Peek at the top distance without removing.
  double get peekDist => _size > 0 ? _dists[0] : double.infinity;

  /// Push a new entry. If at capacity for a max-heap, evicts the worst (top).
  void push(int nodeId, double dist) {
    if (_size < capacity) {
      _ids[_size] = nodeId;
      _dists[_size] = dist;
      _size++;
      _siftUp(_size - 1);
    } else if (maxHeap && dist < _dists[0]) {
      // Replace worst (root) with better candidate
      _ids[0] = nodeId;
      _dists[0] = dist;
      _siftDown(0);
    }
  }

  /// Pop the root element's nodeId. Sets [lastPoppedDist].
  int popId() {
    final id = _ids[0];
    lastPoppedDist = _dists[0];
    _size--;
    if (_size > 0) {
      _ids[0] = _ids[_size];
      _dists[0] = _dists[_size];
      _siftDown(0);
    }
    return id;
  }

  /// Drain all entries sorted by distance ascending.
  List<_SearchCandidate> drainSorted() {
    final list = <_SearchCandidate>[];
    for (int i = 0; i < _size; i++) {
      list.add(_SearchCandidate(_ids[i], _dists[i]));
    }
    list.sort((a, b) => a.distance.compareTo(b.distance));
    return list;
  }

  bool _less(int i, int j) =>
      maxHeap ? _dists[i] > _dists[j] : _dists[i] < _dists[j];

  void _swap(int i, int j) {
    final tmpId = _ids[i];
    final tmpD = _dists[i];
    _ids[i] = _ids[j];
    _dists[i] = _dists[j];
    _ids[j] = tmpId;
    _dists[j] = tmpD;
  }

  void _siftUp(int i) {
    while (i > 0) {
      final parent = (i - 1) >> 1;
      if (_less(i, parent)) {
        _swap(i, parent);
        i = parent;
      } else {
        break;
      }
    }
  }

  void _siftDown(int i) {
    while (true) {
      int best = i;
      final left = 2 * i + 1;
      final right = 2 * i + 2;
      if (left < _size && _less(left, best)) best = left;
      if (right < _size && _less(right, best)) best = right;
      if (best == i) break;
      _swap(i, best);
      i = best;
    }
  }
}
