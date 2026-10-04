import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../core/ngh_graph_engine.dart';
import '../../core/ngh_page.dart';
import '../../core/vector_quantizer.dart';
import '../../core/yield_controller.dart';
import '../../model/ngh_index_meta.dart';
import '../../model/table_context.dart';
import '../../model/table_identity.dart';
import '../../model/table_schema.dart';
import 'legacy_ngh_io.dart';

// Isolated engine-v3 vector search used only while a v4 leaf-nav rebuild
// is in progress. Reads `ngh_old/` with its own caches. Not on the live
// hierarchical-nav hot path.

/// Entry in candidate priority queue.
class _SearchCandidate implements Comparable<_SearchCandidate> {
  final int nodeId;
  final double distance;
  final Uint8List? primaryKeyBytes;

  _SearchCandidate(this.nodeId, this.distance, [this.primaryKeyBytes]);

  @override
  int compareTo(_SearchCandidate other) => distance.compareTo(other.distance);
}

/// In-memory compact vector slot for hot ANN search.
///
/// Keeps SQ8 codes (1 byte/dim) so many clusters stay resident. Scoring uses
/// SIMD kernels; math is identical to the scalar SQ8 path (recall unchanged).
class _NghCompactSlot {
  final int nodeId;
  int flags; // 0x01: deleted
  /// UTF-8 primary key bytes (decoded only for top-K emit / delete).
  final Uint8List primaryKeyBytes;
  final Uint8List sq8Codes;
  final double offset;
  final double scale;
  final double squaredNorm;
  final double invNorm;
  final int pageNo;

  _NghCompactSlot({
    required this.nodeId,
    required this.flags,
    required this.primaryKeyBytes,
    required this.sq8Codes,
    required this.offset,
    required this.scale,
    required this.squaredNorm,
    double? invNorm,
    required this.pageNo,
  }) : invNorm = invNorm ?? (squaredNorm > 0 ? 1.0 / sqrt(squaredNorm) : 1.0);
}

/// Resolved probe plan for one ANN query (recall-intent → cost budget).
class _NprobePlan {
  final int depth;
  final double targetRecall;
  final int maxCandidates;
  final int nprobe;
  final int nlist;
  final double imbalance;

  const _NprobePlan({
    required this.depth,
    required this.targetRecall,
    required this.maxCandidates,
    required this.nprobe,
    required this.nlist,
    required this.imbalance,
  });
}

class LegacyNghSearch {
  final LegacyNghIo _io;

  /// Absolute nprobe ceiling (depth=100 still latency-bounded).
  static const int _hardNprobeCap = 256;

  /// Reference width for dimension-aware latency ceilings (128-d → full scale).
  static const int _nprobeScaleRefDims = 128;

  /// Map [searchDepth] (1..100) → target recall intent in [0.901, 1.0].
  ///
  /// Hard contract: depth only spans 90%–100% recall intent.
  /// depth 50 → 95% (production baseline), depth 80 → 98%, depth 100 → 100%.
  static double targetRecallFromDepth(int searchDepth) {
    final depth = searchDepth.clamp(1, 100);
    return 0.90 + depth / 1000.0;
  }

  /// Imbalance = max(entryCount) / avg(entryCount); 1.0 = perfectly even.
  static double _centroidImbalance(List<NghNavCentroidNode> centroids) {
    if (centroids.isEmpty) return 1.0;
    var sum = 0;
    var maxEntry = 0;
    for (final c in centroids) {
      final e = c.entryCount < 0 ? 0 : c.entryCount;
      sum += e;
      if (e > maxEntry) maxEntry = e;
    }
    final avg = sum / centroids.length;
    if (avg <= 0) return 1.0;
    return maxEntry / avg;
  }

  /// Fraction of [nlist] to probe for intensity [t] = depth/100 in `[0, 1]`.
  ///
  /// Must stay cheap at low depth (depth 5 must not behave like depth 50).
  /// depth≈50 (t=0.5) targets ~7% nlist before floors; higher depths rise faster.
  static double _nlistCoverageForIntensity(double t) {
    final x = t.clamp(0.0, 1.0);
    // t=0 → 1.5%, t=0.05 → ~1.8%, t=0.5 → ~7.2%, t=0.8 → ~14%, t=1 → 22%.
    return 0.015 + 0.205 * pow(x, 1.35);
  }

  /// Map recall intent + corpus shape → nprobe plan.
  ///
  /// Release contract: on balanced indexes, higher [searchDepth] must raise
  /// both probe intent and scoring budget so wall clock and recall move
  /// together through ~100k → 10M (interactive ceilings still apply).
  _NprobePlan _resolveNprobePlan({
    required int nCentroids,
    required int dimensions,
    required int totalVectors,
    required double imbalance,
    int? searchDepth,
  }) {
    final depth =
        (searchDepth ?? VectorIndexConfig.defaultSearchDepth).clamp(1, 100);
    final targetRecall = targetRecallFromDepth(depth);
    if (nCentroids <= 1) {
      return _NprobePlan(
        depth: depth,
        targetRecall: targetRecall,
        maxCandidates: max(1, totalVectors),
        nprobe: 1,
        nlist: max(1, nCentroids),
        imbalance: imbalance,
      );
    }

    // t = depth/100 ≡ (targetRecall-0.90)/0.10
    final t = depth / 100.0;
    final coverage = _nlistCoverageForIntensity(t);
    var nprobe = max(1, (coverage * nCentroids).ceil());

    final sqrtN = sqrt(nCentroids);
    // Depth-proportional floors (NOT stuck near the 95% floor at low depth).
    final floorLo = max(2, min(8, (0.35 * sqrtN).round())); // ~depth 1
    final floor95 = max(16, min(72, (1.35 * sqrtN).round())); // ~depth 50
    final floor100 =
        max(floor95, min(_hardNprobeCap, (0.28 * nCentroids).round()));
    final nFloor = t <= 0.5
        ? (floorLo + (floor95 - floorLo) * (t / 0.5)).round()
        : (floor95 + (floor100 - floor95) * ((t - 0.5) / 0.5)).round();
    nprobe = max(nprobe, max(1, nFloor));

    // Imbalance boost only above mid depth (low depth stays latency-first).
    if (imbalance > 2.5 && t >= 0.35) {
      final boost = min(1.25, 1.0 + (imbalance - 2.5) * 0.06 * t);
      nprobe = (nprobe * boost).round();
    }

    // Hard latency ceilings (dim/corpus). Depth-aware corpus ceil so depth=80
    // can still out-probe depth=50 at 1M–10M.
    final dimCeil = max(
      48,
      (_hardNprobeCap *
              sqrt(_nprobeScaleRefDims / max(_nprobeScaleRefDims, dimensions)))
          .round(),
    );
    final int corpusBase;
    if (totalVectors <= 100000) {
      corpusBase = nCentroids;
    } else if (totalVectors <= 1000000) {
      corpusBase = min(nCentroids, 192);
    } else if (totalVectors <= 10000000) {
      corpusBase = min(nCentroids, 160);
    } else {
      corpusBase = min(nCentroids, 128);
    }
    final corpusCeil = min(
      nCentroids,
      max(floorLo + 4, (corpusBase * (0.55 + 0.55 * t)).round()),
    );
    final hardCeil =
        min(nCentroids, min(_hardNprobeCap, min(dimCeil, corpusCeil)));

    // Depth-scaled ceiling: depth 5 → ~14 probes max on 512-d, depth 50 → ~mid.
    final depthCeil = max(
      floorLo + 1,
      (floorLo + t * (hardCeil - floorLo)).round(),
    );
    nprobe = min(nprobe, min(hardCeil, depthCeil));

    // Scoring budget: depth-scaled; dim soft-dampen; log growth cap for large N.
    final budgetBase = 2800.0 + 28000.0 * pow(t, 1.20);
    final dimScale =
        pow(_nprobeScaleRefDims / max(_nprobeScaleRefDims, dimensions), 0.40)
            .toDouble();
    final nScale = 1.0 +
        0.05 *
            min(4.0, log(max(1000.0, totalVectors.toDouble()) / 1000.0) / ln10);
    final budgetLo = (1800 + 5500 * t).round();
    final budgetHi = (9000 + 38000 * t).round().clamp(9000, 48000);
    var maxCandidates =
        (budgetBase * dimScale * nScale).round().clamp(budgetLo, budgetHi);

    // Skewed lists: light inflate only above mid depth.
    if (imbalance > 3.0 && t >= 0.45) {
      final imbScale = min(1.25, 1.0 + (imbalance - 3.0) * 0.05);
      maxCandidates = (maxCandidates * imbScale).round().clamp(budgetLo, 48000);
    }

    return _NprobePlan(
      depth: depth,
      targetRecall: targetRecall,
      maxCandidates: maxCandidates,
      nprobe: nprobe,
      nlist: nCentroids,
      imbalance: imbalance,
    );
  }

  /// In-memory cached navigating centroid graph per index.
  /// Key: tableUid/indexUid
  final Map<String, NghNavGraphPage> _navGraphCache = {};

  /// In-memory compact vector cache partitioned by centroidId for hot search.
  /// LinkedHashMap preserves insertion order for FIFO eviction under pressure.
  /// Key: tableUid/indexUid -> `Map<int centroidId, List<_NghCompactSlot>>`
  final LinkedHashMap<String, Map<int, List<_NghCompactSlot>>>
      _inMemoryClusterCache =
      LinkedHashMap<String, Map<int, List<_NghCompactSlot>>>();

  /// Estimated resident bytes of [_inMemoryClusterCache] (SQ8 + PK + overhead).
  int _clusterCacheBytes = 0;

  /// Soft ceiling for cluster compact cache; enforced after load/prewarm.
  int _clusterCacheMaxBytes = 64 * 1024 * 1024;

  /// Most-recently-used cluster-cache key (avoid O(n) LinkedHashMap.keys.last).
  String? _clusterCacheMruKey;

  LegacyNghSearch(this._io);

  /// Current estimated cluster-cache footprint in bytes.
  int get clusterCacheBytes => _clusterCacheBytes;

  int get clusterCacheMaxBytes => _clusterCacheMaxBytes;

  /// Configure cluster-cache ceiling (typically a share of the index budget).
  void configureClusterCacheBudget(int maxBytes) {
    _clusterCacheMaxBytes = max(4 * 1024 * 1024, maxBytes);
    _enforceClusterCacheBudget();
  }

  String _cacheKey(TableUid tableUid, IndexUid indexUid) =>
      '${tableUid.value}/${indexUid.value}';

  int _estimateSlotBytes(_NghCompactSlot slot) =>
      24 + slot.primaryKeyBytes.length + slot.sq8Codes.length;

  _NghCompactSlot _compactFromPostingSlot(NghLeafSlot slot, int pageNo) {
    return _NghCompactSlot(
      nodeId: slot.nodeId,
      flags: slot.flags,
      primaryKeyBytes: slot.primaryKeyBytes ?? slot.primaryKeyUtf8,
      sq8Codes: slot.sq8Codes,
      offset: slot.offset,
      scale: slot.scale,
      squaredNorm: slot.squaredNorm,
      pageNo: pageNo,
    );
  }

  int _estimateClusterMapBytes(Map<int, List<_NghCompactSlot>> clusterMap) {
    var bytes = 64;
    for (final slots in clusterMap.values) {
      bytes += 16;
      for (final slot in slots) {
        bytes += _estimateSlotBytes(slot);
      }
    }
    return bytes;
  }

  void _touchClusterCacheKey(String key) {
    // Already MRU: skip LinkedHashMap remove/reinsert churn on every search.
    if (_clusterCacheMruKey == key) return;
    final map = _inMemoryClusterCache.remove(key);
    if (map != null) {
      _inMemoryClusterCache[key] = map;
      _clusterCacheMruKey = key;
    }
  }

  /// Evict oldest index cluster maps until under [targetBytes].
  void _enforceClusterCacheBudget({String? protectKey, int? targetBytes}) {
    final limit = targetBytes ?? _clusterCacheMaxBytes;
    if (_clusterCacheBytes <= limit) return;

    final keys = _inMemoryClusterCache.keys.toList(growable: false);
    for (final key in keys) {
      if (_clusterCacheBytes <= limit) break;
      if (protectKey != null && key == protectKey) continue;
      final removed = _inMemoryClusterCache.remove(key);
      if (removed == null) continue;
      if (_clusterCacheMruKey == key) _clusterCacheMruKey = null;
      _clusterCacheBytes =
          max(0, _clusterCacheBytes - _estimateClusterMapBytes(removed));
    }

    // Still over budget: evict protected key last (OOM safety > hot hit rate).
    if (_clusterCacheBytes > limit &&
        protectKey != null &&
        _inMemoryClusterCache.containsKey(protectKey)) {
      final removed = _inMemoryClusterCache.remove(protectKey);
      if (removed != null) {
        if (_clusterCacheMruKey == protectKey) _clusterCacheMruKey = null;
        _clusterCacheBytes =
            max(0, _clusterCacheBytes - _estimateClusterMapBytes(removed));
      }
    }
  }

  /// Evict a ratio of cluster compact caches (oldest indexes first).
  void evictClusterCache({double ratio = 0.3}) {
    if (_inMemoryClusterCache.isEmpty || ratio <= 0) return;
    final target = max(
      0,
      (_clusterCacheBytes * (1.0 - ratio.clamp(0.0, 1.0))).floor(),
    );
    _enforceClusterCacheBudget(targetBytes: target);
  }

  /// Clear cluster cache for a specific table.
  void clearCacheForTable(TableUid tableUid) {
    final prefix = '${tableUid.value}/';
    final toRemove = <String>[
      for (final k in _inMemoryClusterCache.keys)
        if (k.startsWith(prefix)) k,
    ];
    for (final k in toRemove) {
      final removed = _inMemoryClusterCache.remove(k);
      if (removed != null) {
        if (_clusterCacheMruKey == k) _clusterCacheMruKey = null;
        _clusterCacheBytes =
            max(0, _clusterCacheBytes - _estimateClusterMapBytes(removed));
      }
    }
    _navGraphCache.removeWhere((k, _) => k.startsWith(prefix));
  }

  /// Clear cluster cache for a specific index.
  void clearCacheForIndex(TableUid tableUid, IndexUid indexUid) {
    final key = _cacheKey(tableUid, indexUid);
    final removed = _inMemoryClusterCache.remove(key);
    if (removed != null) {
      if (_clusterCacheMruKey == key) _clusterCacheMruKey = null;
      _clusterCacheBytes =
          max(0, _clusterCacheBytes - _estimateClusterMapBytes(removed));
    }
    _navGraphCache.remove(key);
  }

  /// Clear all cluster caches.
  void clearCache() {
    _inMemoryClusterCache.clear();
    _navGraphCache.clear();
    _clusterCacheBytes = 0;
    _clusterCacheMruKey = null;
  }

  void _ingestLoadedPagesIntoClusterMap({
    required Map<int, List<_NghCompactSlot>> clusterMap,
    required List<({int packedRef, NghLeafPage page})> loaded,
    required Set<int> expectedCentroidIds,
  }) {
    for (final item in loaded) {
      final cList = clusterMap.putIfAbsent(item.page.centroidId, () => []);
      for (final slot in item.page.slots) {
        final compact = _compactFromPostingSlot(slot, item.packedRef);
        cList.add(compact);
        _clusterCacheBytes += _estimateSlotBytes(compact);
      }
    }
    // Mark requested centroids present even if empty (avoid repeat I/O).
    for (final cId in expectedCentroidIds) {
      clusterMap.putIfAbsent(cId, () => <_NghCompactSlot>[]);
    }
  }

  /// Ensure only the probed candidate clusters are loaded into memory cache.
  Future<void> _ensureProbedClustersLoaded({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required NghNavGraphPage navGraph,
    required List<int> probeCentroids,
    required Map<int, List<_NghCompactSlot>> clusterMap,
    required String cacheKey,
  }) async {
    final packedRefsToRead = <int>[];
    final chainHeads = <int>[];
    final expected = <int>{};

    for (final cId in probeCentroids) {
      if (clusterMap.containsKey(cId)) continue;
      if (cId < 0 || cId >= navGraph.centroids.length) continue;
      expected.add(cId);
      final c = navGraph.centroids[cId];
      if (c.leafPageNos.isNotEmpty) {
        packedRefsToRead.addAll(c.leafPageNos);
      } else if (c.headLeafPageNo > 0) {
        chainHeads.add(c.headLeafPageNo);
      } else {
        clusterMap[cId] = <_NghCompactSlot>[];
      }
    }

    if (packedRefsToRead.isNotEmpty) {
      final uniqueRefs = packedRefsToRead.toSet().toList(growable: false);
      final loaded = await _io.readPostingPagesBatch(
        table,
        indexUid,
        meta,
        uniqueRefs,
        populatePageCache: false,
      );
      _ingestLoadedPagesIntoClusterMap(
        clusterMap: clusterMap,
        loaded: loaded,
        expectedCentroidIds: expected,
      );
    }

    if (chainHeads.isNotEmpty) {
      final chains = await _io.readPostingClustersBatch(
        table,
        indexUid,
        meta,
        chainHeads,
      );
      for (final chain in chains) {
        _ingestLoadedPagesIntoClusterMap(
          clusterMap: clusterMap,
          loaded: chain,
          expectedCentroidIds: expected,
        );
      }
    }

    _touchClusterCacheKey(cacheKey);
    _enforceClusterCacheBudget(protectKey: cacheKey);
  }

  /// Startup/runtime prewarm: load posting clusters into compact cache.
  ///
  /// Stops once [maxBytes] would be exceeded (OOM guard). Hot clusters
  /// (highest entryCount) are loaded first. Returns bytes added.
  Future<int> prewarmClusters({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required int maxBytes,
  }) async {
    if (maxBytes <= 0 || meta.totalVectors <= 0) return 0;

    final key = _cacheKey(table.tableUid, indexUid);
    final beforeBytes = _clusterCacheBytes;
    final navGraph = await _getOrLoadNavGraph(table, indexUid, meta);
    if (navGraph == null || navGraph.centroids.isEmpty) return 0;

    final clusterMap = _inMemoryClusterCache.putIfAbsent(key, () => {});
    final centroids = navGraph.centroids;
    final order = List<int>.generate(centroids.length, (i) => i);

    // When the whole compact index fits the budget, load every cluster so
    // arbitrary query vectors never pay disk I/O on probed-centroid misses.
    var totalEst = 64;
    for (final c in centroids) {
      totalEst += max(1, c.entryCount) * (24 + meta.dimensions);
    }
    final loadAll = totalEst <= maxBytes;
    if (!loadAll) {
      order.sort(
          (a, b) => centroids[b].entryCount.compareTo(centroids[a].entryCount));
    }

    final packedBatch = <int>[];
    final chainHeads = <int>[];
    final expected = <int>{};
    var planned = 0;

    for (final cId in order) {
      if (clusterMap.containsKey(cId)) continue;
      final c = centroids[cId];
      if (!loadAll) {
        final est = max(1, c.entryCount) * (24 + meta.dimensions);
        if (planned + est > maxBytes) break;
        planned += est;
      }

      expected.add(cId);
      if (c.leafPageNos.isNotEmpty) {
        packedBatch.addAll(c.leafPageNos);
      } else if (c.headLeafPageNo > 0) {
        chainHeads.add(c.headLeafPageNo);
      } else {
        clusterMap[cId] = <_NghCompactSlot>[];
      }
    }

    // Chunked batch reads so we can stop early if decode blew past budget.
    const chunkSize = 64;
    for (var i = 0; i < packedBatch.length; i += chunkSize) {
      if (_clusterCacheBytes - beforeBytes >= maxBytes) break;
      final chunk = packedBatch.sublist(
        i,
        min(i + chunkSize, packedBatch.length),
      );
      final loaded = await _io.readPostingPagesBatch(
        table,
        indexUid,
        meta,
        chunk,
        populatePageCache: false,
      );
      _ingestLoadedPagesIntoClusterMap(
        clusterMap: clusterMap,
        loaded: loaded,
        expectedCentroidIds: const {},
      );
    }

    if (chainHeads.isNotEmpty && _clusterCacheBytes - beforeBytes < maxBytes) {
      for (final head in chainHeads) {
        if (_clusterCacheBytes - beforeBytes >= maxBytes) break;
        final chain = await _io.readPostingCluster(
          table,
          indexUid,
          meta,
          head,
        );
        _ingestLoadedPagesIntoClusterMap(
          clusterMap: clusterMap,
          loaded: chain,
          expectedCentroidIds: const {},
        );
      }
    }

    for (final cId in expected) {
      clusterMap.putIfAbsent(cId, () => <_NghCompactSlot>[]);
    }

    _touchClusterCacheKey(key);
    // Cap this index's contribution; do not evict the index we just warmed.
    if (_clusterCacheBytes > _clusterCacheMaxBytes) {
      _enforceClusterCacheBudget(protectKey: key);
    }
    return max(0, _clusterCacheBytes - beforeBytes);
  }

  /// Compile hot ANN loops and populate routing/cluster caches after prewarm.
  Future<void> warmSearchPath({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
  }) async {
    if (meta.totalVectors <= 0 || meta.dimensions <= 0) return;
    final dims = meta.dimensions;
    final q = Float32List(dims);
    final inv = 1.0 / sqrt(dims);
    for (var i = 0; i < dims; i++) {
      q[i] = inv;
    }
    await search(
      table: table,
      indexUid: indexUid,
      meta: meta,
      query: q,
      topK: 10,
      queryAlreadyNormalized:
          meta.distanceMetric == VectorDistanceMetric.cosine,
    );
  }

  // =====================================================================
  // Search -- centroid-routed filter + candidate ranking
  // =====================================================================

  /// Select nearest centroids by exact distance (partial selection).
  ///
  /// Exact routing is required for recall: hierarchical/neighbor beams can miss
  /// the true home cluster (especially under multi-assignment).
  ///
  /// Do **not** truncate by entryCount budget here — giant nearest clusters
  /// would consume the budget and drop the drifted home cluster (exact-identity
  /// misses). Cost control belongs in nprobe planning + SQ8/two-pass scoring.
  List<int> _selectProbeCentroids({
    required Float32List searchQuery,
    required NghNavGraphPage navGraph,
    required VectorDistanceMetric metric,
    required int nprobe,
  }) {
    final centroids = navGraph.centroids;
    final nCentroids = centroids.length;
    final want = min(nCentroids, max(1, nprobe));
    if (want >= nCentroids) {
      return List<int>.generate(nCentroids, (i) => i, growable: false);
    }

    // Max-heap of size want (worst of the best). Same recall as full sort.
    final ids = Int32List(want);
    final dists = Float64List(want);
    var size = 0;

    void siftUp(int idx) {
      var child = idx;
      while (child > 0) {
        final parent = (child - 1) >> 1;
        if (dists[child] <= dists[parent]) break;
        final td = dists[child];
        dists[child] = dists[parent];
        dists[parent] = td;
        final ti = ids[child];
        ids[child] = ids[parent];
        ids[parent] = ti;
        child = parent;
      }
    }

    void siftDown(int idx) {
      var parent = idx;
      while (true) {
        var best = parent;
        final left = (parent << 1) + 1;
        final right = left + 1;
        if (left < size && dists[left] > dists[best]) best = left;
        if (right < size && dists[right] > dists[best]) best = right;
        if (best == parent) break;
        final td = dists[parent];
        dists[parent] = dists[best];
        dists[best] = td;
        final ti = ids[parent];
        ids[parent] = ids[best];
        ids[best] = ti;
        parent = best;
      }
    }

    for (int i = 0; i < nCentroids; i++) {
      final d = _exactDistance(searchQuery, centroids[i].vector, metric);
      if (size < want) {
        ids[size] = i;
        dists[size] = d;
        siftUp(size);
        size++;
      } else if (d < dists[0]) {
        ids[0] = i;
        dists[0] = d;
        siftDown(0);
      }
    }

    final pairs = List<(int, double)>.generate(
      size,
      (i) => (ids[i], dists[i]),
      growable: false,
    );
    pairs.sort((a, b) => a.$2.compareTo(b.$2));
    return [for (final p in pairs) p.$1];
  }

  /// Pack probes under [maxCandidates] while maximizing cluster diversity.
  ///
  /// Nearest giants alone burn the budget and collapse Exact Identity. Soft-fill
  /// a locality seed, then prefer non-giant / smaller clusters to raise nprobe
  /// at the same candidate cost (critical for depth≈30 on 100k–1M).
  List<int> _trimProbesToCandidateBudget({
    required List<int> probes,
    required NghNavGraphPage navGraph,
    required int maxCandidates,
    required int avgCluster,
    required int minKeep,
    required int targetProbes,
  }) {
    if (probes.isEmpty || maxCandidates <= 0) return probes;
    final centroids = navGraph.centroids;
    final n = centroids.length;

    int entryOf(int id) {
      if (id < 0 || id >= n) return 0;
      final e = centroids[id].entryCount;
      return e < 0 ? 0 : e;
    }

    var total = 0;
    for (final id in probes) {
      total += entryOf(id);
    }
    if (total <= maxCandidates) return probes;

    final alwaysKeep = min(probes.length, max(4, min(minKeep, 12)));
    final giantThresh = max(avgCluster * 2.2, maxCandidates ~/ 14);
    final target = min(probes.length, max(alwaysKeep, targetProbes));
    final seedBudget = max(
      entryOf(probes.first),
      (maxCandidates * 0.42).round(),
    );

    final out = <int>[];
    final seen = <int>{};
    var acc = 0;

    void tryAdd(int id) {
      if (!seen.add(id)) return;
      out.add(id);
      acc += entryOf(id);
    }

    // Pass 1: nearest locality seed — stop early so giants don't own the budget.
    for (var i = 0; i < alwaysKeep && i < probes.length; i++) {
      if (acc >= seedBudget && out.length >= 4) break;
      tryAdd(probes[i]);
    }

    // Pass 2: non-giant clusters, nearest-first (diversity under budget).
    for (var i = 0; i < probes.length; i++) {
      if (out.length >= target && acc >= maxCandidates) break;
      final id = probes[i];
      if (seen.contains(id)) continue;
      final e = entryOf(id);
      if (e > giantThresh) continue;
      if (acc + e > maxCandidates) continue;
      tryAdd(id);
    }

    // Pass 3: remaining (incl. giants) that still fit — prefer smaller first.
    if (acc < maxCandidates && out.length < target) {
      final rest = <(int, int)>[];
      for (final id in probes) {
        if (seen.contains(id)) continue;
        rest.add((id, entryOf(id)));
      }
      rest.sort((a, b) {
        final bySize = a.$2.compareTo(b.$2);
        if (bySize != 0) return bySize;
        return 0;
      });
      for (final (id, e) in rest) {
        if (acc + e > maxCandidates) continue;
        tryAdd(id);
        if (out.length >= target || acc >= maxCandidates) break;
      }
    }

    // Preserve original nearest-first order for scoring locality.
    final order = <int, int>{
      for (var i = 0; i < probes.length; i++) probes[i]: i,
    };
    out.sort((a, b) => (order[a] ?? 0).compareTo(order[b] ?? 0));
    return out.isEmpty ? probes.sublist(0, 1) : out;
  }

  /// Re-add nearest probes until [minCount].
  ///
  /// Prefer clusters that still fit under [softCandidateBudget]; if the recall
  /// floor is still unmet, allow a limited overshoot (high depth) so Exact
  /// Identity does not cliff while keeping depth=30 from ballooning.
  List<int> _topUpProbesToMinCount({
    required List<int> ranked,
    required List<int> current,
    required int minCount,
    required NghNavGraphPage navGraph,
    required int softCandidateBudget,
    required double depthT,
  }) {
    if (current.length >= minCount || ranked.isEmpty) return current;
    final centroids = navGraph.centroids;
    final n = centroids.length;

    int entryOf(int id) {
      if (id < 0 || id >= n) return 0;
      final e = centroids[id].entryCount;
      return e < 0 ? 0 : e;
    }

    final seen = current.toSet();
    final out = List<int>.from(current);
    var acc = 0;
    for (final id in out) {
      acc += entryOf(id);
    }

    final overshoot =
        (softCandidateBudget * (1.10 + 0.25 * depthT.clamp(0.0, 1.0))).round();

    // Pass 1: fit under soft budget.
    for (final id in ranked) {
      if (out.length >= minCount) break;
      if (seen.contains(id)) continue;
      final e = entryOf(id);
      if (acc + e > softCandidateBudget && out.length >= (minCount ~/ 2)) {
        continue;
      }
      seen.add(id);
      out.add(id);
      acc += e;
    }
    // Pass 2: recall floor — limited overshoot.
    for (final id in ranked) {
      if (out.length >= minCount) break;
      if (seen.contains(id)) continue;
      final e = entryOf(id);
      if (acc + e > overshoot && out.length >= minCount - 2) continue;
      seen.add(id);
      out.add(id);
      acc += e;
    }

    final order = <int, int>{
      for (var i = 0; i < ranked.length; i++) ranked[i]: i,
    };
    out.sort((a, b) => (order[a] ?? 0).compareTo(order[b] ?? 0));
    return out;
  }

  /// Drop farthest probes until cumulative entryCount ≤ [scoreBudget], but
  /// never below [minProbes] (recall floor).
  List<int> _clampProbesToScoreBudget({
    required List<int> ranked,
    required List<int> current,
    required NghNavGraphPage navGraph,
    required int scoreBudget,
    required int minProbes,
  }) {
    if (current.isEmpty || scoreBudget <= 0) return current;
    final centroids = navGraph.centroids;
    final n = centroids.length;

    int entryOf(int id) {
      if (id < 0 || id >= n) return 0;
      final e = centroids[id].entryCount;
      return e < 0 ? 0 : e;
    }

    var acc = 0;
    for (final id in current) {
      acc += entryOf(id);
    }
    if (acc <= scoreBudget) return current;

    final order = <int, int>{
      for (var i = 0; i < ranked.length; i++) ranked[i]: i,
    };
    final sorted = List<int>.from(current)
      ..sort((a, b) => (order[a] ?? 0).compareTo(order[b] ?? 0));

    final keepFloor = min(sorted.length, max(1, minProbes));
    while (sorted.length > keepFloor && acc > scoreBudget) {
      final dropped = sorted.removeLast();
      acc -= entryOf(dropped);
    }
    return sorted;
  }

  /// Add navigating-graph neighbors of the nearest seed centroids.
  ///
  /// After online splits, a vector's home posting list may no longer sit under
  /// the geometrically nearest centroid; neighbor links recover many of those
  /// misses at low extra cost vs raising raw nprobe alone.
  List<int> _expandProbeWithNeighbors({
    required List<int> seeds,
    required NghNavGraphPage navGraph,
    required int maxExtra,
  }) {
    if (seeds.isEmpty || maxExtra <= 0) return seeds;
    final centroids = navGraph.centroids;
    final n = centroids.length;
    final seen = <int>{};
    final out = <int>[];
    for (final id in seeds) {
      if (id < 0 || id >= n) continue;
      if (seen.add(id)) out.add(id);
    }
    final target = out.length + maxExtra;
    final seedLimit = min(out.length, max(4, out.length ~/ 3));
    for (var i = 0; i < seedLimit && out.length < target; i++) {
      for (final nId in centroids[out[i]].neighbors) {
        if (nId < 0 || nId >= n) continue;
        if (seen.add(nId)) {
          out.add(nId);
          if (out.length >= target) return out;
        }
      }
    }
    return out;
  }

  /// Perform ANN search on the NGH index.
  ///
  /// Steps:
  ///   1. Exact centroid routing on in-memory navigating graph
  ///   2. On-demand load only probed clusters (prewarmed: 0 I/O)
  ///   3. SQ8 distance scoring across all slots in probed clusters
  ///   4. Global Top-K extraction via fixed heap
  Future<List<NghSearchResult>> search({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required Float32List query,
    required int topK,
    int? searchDepth,
    double? distanceThreshold,
    bool queryAlreadyNormalized = false,
    Set<String>? pendingDeletePks,
  }) async {
    if (meta.totalVectors == 0) return const [];

    final key = _cacheKey(table.tableUid, indexUid);
    final clusterMap = _inMemoryClusterCache.putIfAbsent(key, () => {});

    NghNavGraphPage? navGraph = _navGraphCache[key];
    navGraph ??= await _getOrLoadNavGraph(table, indexUid, meta);
    if (navGraph == null || navGraph.centroids.isEmpty) {
      return const [];
    }

    Float32List searchQuery = query;
    if (meta.distanceMetric == VectorDistanceMetric.cosine &&
        !queryAlreadyNormalized) {
      searchQuery = _normalizeFloat32(query);
    }

    final prep = _prepQueryStats(searchQuery);
    final querySum = prep.$1;
    final querySqNorm = prep.$2;

    final imbalance = _centroidImbalance(navGraph.centroids);
    final plan = _resolveNprobePlan(
      nCentroids: navGraph.centroids.length,
      dimensions: meta.dimensions,
      totalVectors: meta.totalVectors,
      imbalance: imbalance,
      searchDepth: searchDepth,
    );

    final primaryProbes = _selectProbeCentroids(
      searchQuery: searchQuery,
      navGraph: navGraph,
      metric: meta.distanceMetric,
      nprobe: plan.nprobe,
    );

    final depthT = plan.depth / 100.0;
    final int maxNeighborExtra;
    if (depthT < 0.30) {
      maxNeighborExtra = 0;
    } else if (depthT < 0.55) {
      maxNeighborExtra = min(12, max(0, (plan.nprobe * 0.14).round()));
    } else {
      maxNeighborExtra =
          min(24, max(0, (plan.nprobe * (0.10 + 0.22 * depthT)).round()));
    }
    var probeCentroids = maxNeighborExtra <= 0
        ? primaryProbes
        : _expandProbeWithNeighbors(
            seeds: primaryProbes,
            navGraph: navGraph,
            maxExtra: maxNeighborExtra,
          );

    final avgCluster = max(
      1,
      (meta.totalVectors / max(1, navGraph.centroids.length)).round(),
    );
    final trimBudget = (plan.maxCandidates * (0.92 + 0.55 * depthT))
        .round()
        .clamp(plan.maxCandidates, 56000);
    final minKeep = min(
      probeCentroids.length,
      max(8, min(24, trimBudget ~/ max(avgCluster * 3, 1))),
    );
    final targetProbes = min(
      probeCentroids.length,
      max(minKeep, min(plan.nprobe, trimBudget ~/ max(avgCluster, 1))),
    );
    final rankedProbes = probeCentroids;
    probeCentroids = _trimProbesToCandidateBudget(
      probes: rankedProbes,
      navGraph: navGraph,
      maxCandidates: trimBudget,
      avgCluster: avgCluster,
      minKeep: minKeep,
      targetProbes: targetProbes,
    );

    final int minProbeFloor;
    if (plan.depth >= 70) {
      minProbeFloor = min(
        rankedProbes.length,
        max(
          48,
          max((0.72 * plan.nprobe).round(), (0.05 * plan.nlist).ceil()),
        ),
      );
    } else if (plan.depth >= 50) {
      minProbeFloor = min(
        rankedProbes.length,
        max(
          40,
          max((0.72 * plan.nprobe).round(), (0.045 * plan.nlist).ceil()),
        ),
      );
    } else if (plan.depth >= 25) {
      minProbeFloor = min(
        rankedProbes.length,
        max(
          28,
          max((0.82 * plan.nprobe).round(), (0.032 * plan.nlist).ceil()),
        ),
      );
    } else {
      minProbeFloor = 0;
    }
    if (minProbeFloor > 0 && probeCentroids.length < minProbeFloor) {
      probeCentroids = _topUpProbesToMinCount(
        ranked: rankedProbes,
        current: probeCentroids,
        minCount: minProbeFloor,
        navGraph: navGraph,
        softCandidateBudget: trimBudget,
        depthT: depthT,
      );
    }

    final scoreBudget = (plan.maxCandidates * (1.05 + 0.30 * depthT))
        .round()
        .clamp(plan.maxCandidates, 56000);
    probeCentroids = _clampProbesToScoreBudget(
      ranked: rankedProbes,
      current: probeCentroids,
      navGraph: navGraph,
      scoreBudget: scoreBudget,
      minProbes: minProbeFloor > 0 ? minProbeFloor : 1,
    );

    var needsLoad = false;
    for (final cId in probeCentroids) {
      if (!clusterMap.containsKey(cId)) {
        needsLoad = true;
        break;
      }
    }
    if (needsLoad) {
      await _ensureProbedClustersLoaded(
        table: table,
        indexUid: indexUid,
        meta: meta,
        navGraph: navGraph,
        probeCentroids: probeCentroids,
        clusterMap: clusterMap,
        cacheKey: key,
      );
    } else {
      _touchClusterCacheKey(key);
    }

    var slotEstimate = 0;
    for (final cId in probeCentroids) {
      slotEstimate += clusterMap[cId]?.length ?? 0;
    }

    final resultHeap = _FixedHeap(max(1, topK), maxHeap: true);
    final isCosine = meta.distanceMetric == VectorDistanceMetric.cosine;
    final isIP = meta.distanceMetric == VectorDistanceMetric.innerProduct;

    final useTwoPass = isCosine &&
        plan.depth < 45 &&
        meta.dimensions >= 256 &&
        slotEstimate > max(12000, (plan.maxCandidates * 1.25).round()) &&
        topK <= 64 &&
        distanceThreshold == null;

    final shouldYield = !useTwoPass && (topK > 128 || slotEstimate > 24000);

    void runScoreSync() {
      if (useTwoPass) {
        _scoreCosineTwoPass(
          probeCentroids: probeCentroids,
          clusterMap: clusterMap,
          searchQuery: searchQuery,
          querySum: querySum,
          topK: topK,
          resultHeap: resultHeap,
          searchDepth: plan.depth,
        );
        return;
      }
      if (isCosine) {
        for (final cId in probeCentroids) {
          final slots = clusterMap[cId];
          if (slots == null || slots.isEmpty) continue;
          final sCount = slots.length;
          for (int i = 0; i < sCount; i++) {
            final slot = slots[i];
            if (slot.flags & 0x01 != 0) continue;
            final dist = ScalarQuantizer.fastCosineDistance(
              searchQuery,
              querySum,
              slot.sq8Codes,
              slot.offset,
              slot.scale,
              slot.invNorm,
            );
            if (distanceThreshold != null && dist > distanceThreshold) continue;
            if (!resultHeap.isFull || dist < resultHeap.peekDist) {
              resultHeap.pushWithPk(slot.nodeId, dist, slot.primaryKeyBytes);
            }
          }
        }
      } else {
        for (final cId in probeCentroids) {
          final slots = clusterMap[cId];
          if (slots == null || slots.isEmpty) continue;
          final sCount = slots.length;
          for (int i = 0; i < sCount; i++) {
            _scoreSlotIntoHeap(
              slots[i],
              searchQuery: searchQuery,
              querySum: querySum,
              querySqNorm: querySqNorm,
              isCosine: isCosine,
              isIP: isIP,
              distanceThreshold: distanceThreshold,
              resultHeap: resultHeap,
            );
          }
        }
      }
    }

    if (shouldYield) {
      final yc = YieldController(
        'NghGraphEngine.search.score',
        checkInterval: 1024,
        budgetMs: 12,
        minCheckInterval: 256,
      );
      for (final cId in probeCentroids) {
        final slots = clusterMap[cId];
        if (slots == null || slots.isEmpty) continue;
        final sCount = slots.length;
        for (int i = 0; i < sCount; i++) {
          final y = yc.maybeYield();
          if (y != null) await y;
          _scoreSlotIntoHeap(
            slots[i],
            searchQuery: searchQuery,
            querySum: querySum,
            querySqNorm: querySqNorm,
            isCosine: isCosine,
            isIP: isIP,
            distanceThreshold: distanceThreshold,
            resultHeap: resultHeap,
          );
        }
      }
    } else {
      runScoreSync();
    }

    final rawResults = resultHeap.drainSortedWithPk();
    final out = <NghSearchResult>[];
    for (final r in rawResults) {
      final pk =
          r.primaryKeyBytes != null ? utf8.decode(r.primaryKeyBytes!) : null;
      if (pk != null &&
          pendingDeletePks != null &&
          pendingDeletePks.contains(pk)) {
        continue;
      }
      out.add(NghSearchResult(
        nodeId: r.nodeId,
        distance: r.distance,
        primaryKey: pk,
      ));
    }
    return out;
  }

  (double, double) _prepQueryStats(Float32List searchQuery) {
    double querySum = 0;
    double querySqNorm = 0;
    final qLen = searchQuery.length;
    final qN = qLen >> 2;
    if (qN > 0 && (searchQuery.offsetInBytes & 15) == 0) {
      final qv =
          Float32x4List.view(searchQuery.buffer, searchQuery.offsetInBytes, qN);
      var sumAcc = Float32x4.zero();
      var sqAcc = Float32x4.zero();
      for (var i = 0; i < qN; i++) {
        final v = qv[i];
        sumAcc += v;
        sqAcc += v * v;
      }
      querySum = sumAcc.x + sumAcc.y + sumAcc.z + sumAcc.w;
      querySqNorm = sqAcc.x + sqAcc.y + sqAcc.z + sqAcc.w;
      for (var i = qN << 2; i < qLen; i++) {
        final qVal = searchQuery[i];
        querySum += qVal;
        querySqNorm += qVal * qVal;
      }
    } else {
      for (int d = 0; d < qLen; d++) {
        final qVal = searchQuery[d];
        querySum += qVal;
        querySqNorm += qVal * qVal;
      }
    }
    return (querySum, querySqNorm);
  }

  /// Coarse strided filter + full SQ8 rescore for high-dim ANN.
  ///
  /// Keep fraction scales with [searchDepth]: low depth = aggressive filter
  /// (fast); high depth = larger keep (recall). Avoids depth=5 full-scanning
  /// tens of thousands of candidates.
  void _scoreCosineTwoPass({
    required List<int> probeCentroids,
    required Map<int, List<_NghCompactSlot>> clusterMap,
    required Float32List searchQuery,
    required double querySum,
    required int topK,
    required _FixedHeap resultHeap,
    required int searchDepth,
  }) {
    var candidateCount = 0;
    for (final cId in probeCentroids) {
      candidateCount += clusterMap[cId]?.length ?? 0;
    }
    final t = (searchDepth.clamp(1, 100)) / 100.0;
    // High keep at mid/high depth: depth50 ≈ 55%+, avoids Exact-Identity drops.
    final keepFrac = 0.20 + 0.50 * t;
    final keepMin = max(topK * 48, (2048 + 10000 * t).round());
    final keep = min(
      max(1, candidateCount),
      max(keepMin, (candidateCount * keepFrac).ceil()),
    );

    // Only skip coarse when keep would retain almost everything.
    if (keep >= (candidateCount * 0.9).ceil() && candidateCount <= 2500) {
      for (final cId in probeCentroids) {
        final slots = clusterMap[cId];
        if (slots == null || slots.isEmpty) continue;
        final sCount = slots.length;
        for (int i = 0; i < sCount; i++) {
          final slot = slots[i];
          if (slot.flags & 0x01 != 0) continue;
          final dist = ScalarQuantizer.fastCosineDistance(
            searchQuery,
            querySum,
            slot.sq8Codes,
            slot.offset,
            slot.scale,
            slot.invNorm,
          );
          if (!resultHeap.isFull || dist < resultHeap.peekDist) {
            resultHeap.pushWithPk(slot.nodeId, dist, slot.primaryKeyBytes);
          }
        }
      }
      return;
    }

    final coarse = _SlotHeap(keep);
    // Low depth: coarser stride (faster); mid+ : stride 2 (safer recall).
    final stride = t < 0.35 ? 4 : 2;

    void runCoarse() {
      for (final cId in probeCentroids) {
        final slots = clusterMap[cId];
        if (slots == null || slots.isEmpty) continue;
        final sCount = slots.length;
        for (int i = 0; i < sCount; i++) {
          final slot = slots[i];
          if (slot.flags & 0x01 != 0) continue;
          final dist = ScalarQuantizer.fastCosineDistanceStrided(
            searchQuery,
            querySum,
            slot.sq8Codes,
            slot.offset,
            slot.scale,
            slot.invNorm,
            stride: stride,
          );
          coarse.offer(slot, dist);
        }
      }
    }

    late final List<_NghCompactSlot> survivors;
    void runFine() {
      survivors = coarse.slotsInHeap();
      for (final slot in survivors) {
        final dist = ScalarQuantizer.fastCosineDistance(
          searchQuery,
          querySum,
          slot.sq8Codes,
          slot.offset,
          slot.scale,
          slot.invNorm,
        );
        if (!resultHeap.isFull || dist < resultHeap.peekDist) {
          resultHeap.pushWithPk(slot.nodeId, dist, slot.primaryKeyBytes);
        }
      }
    }

    runCoarse();
    runFine();
  }

  /// Score one compact slot into the result heap (hot path, no allocations).
  void _scoreSlotIntoHeap(
    _NghCompactSlot slot, {
    required Float32List searchQuery,
    required double querySum,
    required double querySqNorm,
    required bool isCosine,
    required bool isIP,
    required double? distanceThreshold,
    required _FixedHeap resultHeap,
  }) {
    if (slot.flags & 0x01 != 0) return; // marked deleted

    late final double dist;
    if (isCosine) {
      dist = ScalarQuantizer.fastCosineDistance(
        searchQuery,
        querySum,
        slot.sq8Codes,
        slot.offset,
        slot.scale,
        slot.invNorm,
      );
    } else if (isIP) {
      dist = ScalarQuantizer.fastDotProduct(
        searchQuery,
        querySum,
        slot.sq8Codes,
        slot.offset,
        slot.scale,
      );
    } else {
      dist = ScalarQuantizer.fastSquaredL2Distance(
        searchQuery,
        querySqNorm,
        querySum,
        slot.sq8Codes,
        slot.offset,
        slot.scale,
        slot.squaredNorm,
      );
    }

    if (distanceThreshold != null && dist > distanceThreshold) return;

    if (!resultHeap.isFull || dist < resultHeap.peekDist) {
      resultHeap.pushWithPk(slot.nodeId, dist, slot.primaryKeyBytes);
    }
  }

  Future<void> prefetchNavGraph(TableContext table, IndexUid indexUid) async {
    final key = _cacheKey(table.tableUid, indexUid);
    if (_navGraphCache.containsKey(key)) return;
    try {
      final loaded = await _io.readNavGraph(table, indexUid);
      if (loaded != null) {
        _navGraphCache[key] = loaded;
      }
    } catch (_) {}
  }

  Future<NghNavGraphPage?> _getOrLoadNavGraph(
    TableContext table,
    IndexUid indexUid,
    NghIndexMeta meta,
  ) async {
    final key = _cacheKey(table.tableUid, indexUid);
    final cached = _navGraphCache[key];
    if (cached != null) return cached;

    final loaded = await _io.readNavGraph(table, indexUid);
    if (loaded != null) {
      _navGraphCache[key] = loaded;
      return loaded;
    }
    return null;
  }

  // =====================================================================
  // Exact Distance Computation
  // =====================================================================

  double _exactDistance(
      Float32List a, Float32List b, VectorDistanceMetric metric) {
    switch (metric) {
      case VectorDistanceMetric.l2:
        return _l2Distance(a, b);
      case VectorDistanceMetric.innerProduct:
        return -_innerProduct(a, b);
      case VectorDistanceMetric.cosine:
        return 1.0 - _innerProduct(a, b).clamp(-1.0, 1.0);
    }
  }

  double _l2Distance(Float32List a, Float32List b) {
    // Prefer true SIMD loads via Float32x4List.view when buffers are aligned.
    final len = a.length;
    final n = len >> 2;
    if (n > 0 && (a.offsetInBytes & 15) == 0 && (b.offsetInBytes & 15) == 0) {
      final av = Float32x4List.view(a.buffer, a.offsetInBytes, n);
      final bv = Float32x4List.view(b.buffer, b.offsetInBytes, n);
      var acc = Float32x4.zero();
      for (var i = 0; i < n; i++) {
        final d = av[i] - bv[i];
        acc += d * d;
      }
      double sum = acc.x + acc.y + acc.z + acc.w;
      for (var i = n << 2; i < len; i++) {
        final diff = a[i] - b[i];
        sum += diff * diff;
      }
      return sum;
    }

    double sum = 0;
    var i = 0;
    final unroll = len - 7;
    while (i < unroll) {
      final d0 = a[i] - b[i];
      final d1 = a[i + 1] - b[i + 1];
      final d2 = a[i + 2] - b[i + 2];
      final d3 = a[i + 3] - b[i + 3];
      final d4 = a[i + 4] - b[i + 4];
      final d5 = a[i + 5] - b[i + 5];
      final d6 = a[i + 6] - b[i + 6];
      final d7 = a[i + 7] - b[i + 7];
      sum += d0 * d0 +
          d1 * d1 +
          d2 * d2 +
          d3 * d3 +
          d4 * d4 +
          d5 * d5 +
          d6 * d6 +
          d7 * d7;
      i += 8;
    }
    while (i < len) {
      final diff = a[i] - b[i];
      sum += diff * diff;
      i++;
    }
    return sum;
  }

  double _innerProduct(Float32List a, Float32List b) {
    return ScalarQuantizer.dotProductF32(a, b);
  }

  Float32List _normalizeFloat32(Float32List v) {
    final len = v.length;
    double norm = 0;
    final n = len >> 2;
    if (n > 0 && (v.offsetInBytes & 15) == 0) {
      final vv = Float32x4List.view(v.buffer, v.offsetInBytes, n);
      var acc = Float32x4.zero();
      for (var i = 0; i < n; i++) {
        final x = vv[i];
        acc += x * x;
      }
      norm = acc.x + acc.y + acc.z + acc.w;
      for (var i = n << 2; i < len; i++) {
        norm += v[i] * v[i];
      }
    } else {
      for (int i = 0; i < len; i++) {
        norm += v[i] * v[i];
      }
    }
    if (norm == 0) return v;
    final inv = 1.0 / sqrt(norm);
    final out = Float32List(len);
    if (n > 0 && (v.offsetInBytes & 15) == 0) {
      final vv = Float32x4List.view(v.buffer, v.offsetInBytes, n);
      final ov = Float32x4List.view(out.buffer, out.offsetInBytes, n);
      final scale = Float32x4.splat(inv);
      for (var i = 0; i < n; i++) {
        ov[i] = vv[i] * scale;
      }
      for (var i = n << 2; i < len; i++) {
        out[i] = v[i] * inv;
      }
    } else {
      for (int i = 0; i < len; i++) {
        out[i] = v[i] * inv;
      }
    }
    return out;
  }
}

class _SlotHeap {
  final int capacity;
  late final List<_NghCompactSlot?> _slots;
  late final Float64List _dists;
  int _size = 0;

  _SlotHeap(this.capacity) {
    _slots = List<_NghCompactSlot?>.filled(capacity, null);
    _dists = Float64List(capacity);
  }

  void offer(_NghCompactSlot slot, double dist) {
    if (_size < capacity) {
      final i = _size;
      _slots[i] = slot;
      _dists[i] = dist;
      _size = i + 1;
      _siftUp(i);
    } else if (dist < _dists[0]) {
      _slots[0] = slot;
      _dists[0] = dist;
      _siftDown(0);
    }
  }

  List<_NghCompactSlot> slotsInHeap() {
    final out = <_NghCompactSlot>[];
    for (var i = 0; i < _size; i++) {
      final s = _slots[i];
      if (s != null) out.add(s);
    }
    return out;
  }

  void _siftUp(int idx) {
    var child = idx;
    while (child > 0) {
      final parent = (child - 1) >> 1;
      if (_dists[child] <= _dists[parent]) break;
      _swap(child, parent);
      child = parent;
    }
  }

  void _siftDown(int idx) {
    var parent = idx;
    while (true) {
      var best = parent;
      final left = (parent << 1) + 1;
      final right = left + 1;
      if (left < _size && _dists[left] > _dists[best]) best = left;
      if (right < _size && _dists[right] > _dists[best]) best = right;
      if (best == parent) break;
      _swap(parent, best);
      parent = best;
    }
  }

  void _swap(int a, int b) {
    final ts = _slots[a];
    final td = _dists[a];
    _slots[a] = _slots[b];
    _dists[a] = _dists[b];
    _slots[b] = ts;
    _dists[b] = td;
  }
}

class _FixedHeap {
  final int capacity;
  final bool maxHeap;

  late final Int32List _ids;
  late final Float64List _dists;
  late final List<Uint8List?> _pks;
  int _size = 0;

  _FixedHeap(this.capacity, {this.maxHeap = false}) {
    _ids = Int32List(capacity);
    _dists = Float64List(capacity);
    _pks = List<Uint8List?>.filled(capacity, null);
  }

  bool get isEmpty => _size == 0;
  bool get isNotEmpty => _size > 0;
  bool get isFull => _size >= capacity;
  int get length => _size;
  double get peekDist => _size > 0 ? _dists[0] : double.infinity;

  void pushWithPk(int id, double dist, Uint8List? pkBytes) {
    if (_size < capacity) {
      final i = _size;
      _ids[i] = id;
      _dists[i] = dist;
      _pks[i] = pkBytes;
      _size = i + 1;
      _siftUp(i);
    } else if ((maxHeap && dist < _dists[0]) ||
        (!maxHeap && dist > _dists[0])) {
      _ids[0] = id;
      _dists[0] = dist;
      _pks[0] = pkBytes;
      _siftDown(0);
    }
  }

  List<_SearchCandidate> drainSortedWithPk() {
    if (_size == 0) return const [];
    final result = <_SearchCandidate>[];
    while (_size > 0) {
      final id = _ids[0];
      final dist = _dists[0];
      final pk = _pks[0];
      _size--;
      if (_size > 0) {
        _ids[0] = _ids[_size];
        _dists[0] = _dists[_size];
        _pks[0] = _pks[_size];
        _siftDown(0);
      }
      result.add(_SearchCandidate(id, dist, pk));
    }
    if (maxHeap) {
      // In-place reverse (worst-first → best-first); avoids second list alloc.
      for (var i = 0, j = result.length - 1; i < j; i++, j--) {
        final tmp = result[i];
        result[i] = result[j];
        result[j] = tmp;
      }
    }
    return result;
  }

  void _siftUp(int idx) {
    int child = idx;
    while (child > 0) {
      final parent = (child - 1) >> 1;
      if (_compare(child, parent)) {
        _swap(child, parent);
        child = parent;
      } else {
        break;
      }
    }
  }

  void _siftDown(int idx) {
    int parent = idx;
    while (true) {
      int best = parent;
      final left = (parent << 1) + 1;
      final right = left + 1;

      if (left < _size && _compare(left, best)) best = left;
      if (right < _size && _compare(right, best)) best = right;

      if (best != parent) {
        _swap(parent, best);
        parent = best;
      } else {
        break;
      }
    }
  }

  bool _compare(int a, int b) {
    return maxHeap ? _dists[a] > _dists[b] : _dists[a] < _dists[b];
  }

  void _swap(int a, int b) {
    final tempId = _ids[a];
    final tempDist = _dists[a];
    final tempPk = _pks[a];

    _ids[a] = _ids[b];
    _dists[a] = _dists[b];
    _pks[a] = _pks[b];

    _ids[b] = tempId;
    _dists[b] = tempDist;
    _pks[b] = tempPk;
  }
}
