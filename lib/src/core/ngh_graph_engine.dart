import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../handler/memcomparable.dart';
import '../model/ngh_index_meta.dart';
import '../model/table_context.dart';
import '../model/table_identity.dart';
import '../model/table_schema.dart';
import 'ngh_page.dart';
import 'ngh_partition_manager.dart';
import 'ngh_pk_map.dart';
import 'vector_quantizer.dart';
import 'yield_controller.dart';

// ============================================================================
// NGH Graph Engine
//
// Responsibilities:
//   1. In-memory light-weight navigating centroid graph (microsecond synchronous routing)
//   2. High-speed inverted cluster search via inlined SQ8 vector slots (0 random secondary I/O)
//   3. Streaming incremental insert with angle-aware multi-assignment
//   4. Hub governance: softCap (~1.75× fair share) + batch-end 2-means posting rewrite
//   5. Tombstone deletion and compaction
//
// Scale lock (identity recall + tens of billions):
//   - Insert and search share one router: exact among top-level lists
//     (coarses ∪ orphan leaves), then exact among that node's children.
//     Never stride-sample a flat K, never probe only coarses while leftover
//     flat leaves still hold data.
//   - Format cap for top-level ids is 16384. Insert assignment is
//     O(topLevel × D) per vector, so the *L0 routing* cap is 256. Further
//     growth nests coarse→mid→leaf (fanout ≤256 per level) instead of
//     scanning thousands of centroids, and instead of skipping splits once
//     a parent is full (that left giant leaves and search avalanches).
//   - Leaf posting size is hard-capped (~4k–64 pages). Three levels at
//     256×256×256×~4k ≈ 68B before a children-dir / fourth level.
//   - nprobe is on L0 count. Each probed coarse expands an exact child-
//     nprobe recursively down to leaves (always includes the nearest child).
//   - searchDepth is a 1..100 recall-intent knob (90%–100%). Values above
//     100 clamp to 100 — they do not buy extra probes. Leaf count is
//     max(staircase, ~√nlist) under a depth-scaled interactive ceiling
//     (d1=4, d50=16, d80=32, d100=48 leaves) so 5M still reaches ~95%
//     intent at depth 100 without a 10B scoring avalanche.
//   - Engine v4 never rewrites nav_graph.ngh. New writes are paged nav/pdir
//     only. Posting slot layout (including inlined PK) stays frozen; pdir is
//     the page-list authority. Packed i32 `next` may be -1 at huge partition
//     counts — that is not a posting rewrite trigger.
// ============================================================================

/// A search result with node ID, primary key, and distance.
class NghSearchResult {
  final int nodeId;

  /// Approximate or exact distance (L2, Cosine, or negated IP).
  double distance;

  /// The primary key of the record this vector belongs to.
  final String? primaryKey;

  NghSearchResult({
    required this.nodeId,
    required this.distance,
    this.primaryKey,
  });
}

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

/// NGH Graph Engine -- core vector search and dynamic graph engine.
class NghGraphEngine {
  final NghPartitionManager _partitionManager;

  /// Absolute L0 nprobe ceiling (depth=100 still latency-bounded).
  static const int _hardNprobeCap = 256;

  /// Typical IVF leaf occupancy used for slot-budget estimates.
  static const int _typicalLeafSlots = 4096;

  /// Interactive leaf ceiling at searchDepth=100 (~196k SQ8 scores).
  ///
  /// True-kNN 95% at 5–10M is bought here, not by raising the public knob
  /// past 100. 10B still cannot brute-force 95%; this cap keeps latency in
  /// the tens-to-low-hundreds of ms class at D=512.
  static const int _maxInteractiveLeaves = 48;

  /// Reference width for dimension-aware latency ceilings (128-d → full scale).
  static const int _nprobeScaleRefDims = 128;

  /// Map [searchDepth] (1..100) → target recall intent in [0.901, 1.0].
  ///
  /// Hard contract: depth only spans 90%–100% recall intent.
  /// depth 50 → 95% (production baseline), depth 80 → 98%, depth 100 → 100%.
  /// Values above 100 are clamped; 200/300 is not a higher-recall mode.
  static double targetRecallFromDepth(int searchDepth) {
    final depth = searchDepth.clamp(1, 100);
    return 0.90 + depth / 1000.0;
  }

  /// Imbalance = max(entryCount) / avg(entryCount); 1.0 = perfectly even.
  static double _centroidImbalance(List<NghNavCentroidNode> centroids) {
    if (centroids.isEmpty) return 1.0;
    var sum = 0;
    var maxEntry = 0;
    var n = 0;
    for (final c in centroids) {
      if (c.isCoarse) continue;
      final e = c.entryCount < 0 ? 0 : c.entryCount;
      sum += e;
      n++;
      if (e > maxEntry) maxEntry = e;
    }
    if (n <= 0) return 1.0;
    final avg = sum / n;
    if (avg <= 0) return 1.0;
    return maxEntry / avg;
  }

  /// Fraction of [nlist] used only for hierarchical child-nprobe.
  ///
  /// Parent nprobe is sqrt-scaled in [_resolveNprobePlan] (min-cost for intent).
  /// This curve stays well below the old ~7% @ depth 50, which over-probed.
  static double _nlistCoverageForIntensity(double t) {
    final x = t.clamp(0.0, 1.0);
    // t=0 → 0.3%, t=0.5 → ~2.0%, t=1 → ~5.5%.
    return 0.003 + 0.052 * pow(x, 1.20);
  }

  /// Map recall intent → minimum-cost nprobe / scoring plan.
  ///
  /// L0 nprobe stays √(L0) (L0 ≤ 256). Leaf count is max(depth staircase,
  /// ~√nLeaves) so 5M+/10M still differentiate 50 vs 100, capped by
  /// [_maxLeavesForDepth] (d100 = 48 leaves, ~196k SQ8) — not by raising
  /// searchDepth to 200/300.
  _NprobePlan _resolveNprobePlan({
    required int nCentroids,
    required int nLeaves,
    required int dimensions,
    required int totalVectors,
    required double imbalance,
    int? searchDepth,
  }) {
    final depth =
        (searchDepth ?? VectorIndexConfig.defaultSearchDepth).clamp(1, 100);
    final targetRecall = targetRecallFromDepth(depth);
    final nlist = max(1, nCentroids);
    if (nlist <= 1) {
      return _NprobePlan(
        depth: depth,
        targetRecall: targetRecall,
        maxCandidates: max(1, totalVectors),
        nprobe: 1,
        nlist: nlist,
        imbalance: imbalance,
      );
    }

    final t = depth / 100.0;
    final sqrtK = sqrt(nlist);
    const n1 = 1;
    final n50 = max(3, min(16, (0.42 * sqrtK).round()));
    final n100 = max(n50 + 4, min(_hardNprobeCap, (1.05 * sqrtK).round()));
    var nprobe = t <= 0.5
        ? max(n1, (n1 + (n50 - n1) * (t / 0.5)).round())
        : (n50 + (n100 - n50) * ((t - 0.5) / 0.5)).round();

    if (imbalance > 2.5 && t >= 0.40) {
      final boost = min(1.20, 1.0 + (imbalance - 2.5) * 0.05 * t);
      nprobe = min(n100, (nprobe * boost).round());
    }

    final dimScale =
        sqrt(_nprobeScaleRefDims / max(_nprobeScaleRefDims, dimensions));
    final dimCeil = max(
      n1,
      ((n1 + (n100 - n1) * t) * max(0.70, dimScale)).round(),
    );
    nprobe = min(nlist, min(nprobe, dimCeil));

    final leafKeep = _minKeepLeaves(t, nLeaves: nLeaves);
    final slotCap = _slotCapForDepth(t);
    var maxCandidates = (_typicalLeafSlots * leafKeep * 1.15).round();
    maxCandidates = maxCandidates.clamp(_typicalLeafSlots, slotCap);
    maxCandidates = min(maxCandidates, max(1, totalVectors));
    if (imbalance > 3.0 && t >= 0.45) {
      final imbScale = min(1.15, 1.0 + (imbalance - 3.0) * 0.04);
      maxCandidates =
          (maxCandidates * imbScale).round().clamp(_typicalLeafSlots, slotCap);
    }
    if (nLeaves > 0) {
      maxCandidates = min(maxCandidates, nLeaves * _typicalLeafSlots);
    }

    return _NprobePlan(
      depth: depth,
      targetRecall: targetRecall,
      maxCandidates: maxCandidates,
      nprobe: nprobe,
      nlist: nlist,
      imbalance: imbalance,
    );
  }

  /// Interactive leaf ceiling: depth 1→4, 50→16, 80→32, 100→48.
  static int _maxLeavesForDepth(double t) {
    final x = t.clamp(0.0, 1.0);
    if (x <= 0.50) {
      return max(4, (4 + 12 * (x / 0.50)).round());
    }
    if (x <= 0.80) {
      return max(16, (16 + 16 * ((x - 0.50) / 0.30)).round());
    }
    return max(
      32,
      min(_maxInteractiveLeaves, (32 + 16 * ((x - 0.80) / 0.20)).round()),
    );
  }

  static int _slotCapForDepth(double t) =>
      (_typicalLeafSlots * _maxLeavesForDepth(t) * 1.15).round();

  /// Depth staircase is the latency floor. IVF recall at large nlist needs
  /// ~√nlist extra leaves; never exceed [_maxLeavesForDepth].
  static int _minKeepLeaves(double t, {int nLeaves = 0}) {
    final x = t.clamp(0.0, 1.0);
    final stair = x <= 0.50
        ? max(1, (1 + 3 * (x / 0.50)).round())
        : (4 + 8 * ((x - 0.50) / 0.50)).round();
    final cap = _maxLeavesForDepth(x);
    if (nLeaves <= 0) return min(stair, cap);
    if (nLeaves <= stair) return min(nLeaves, cap);

    final sqrtN = sqrt(nLeaves.toDouble());
    final want50 = max(stair, (0.45 * sqrtN).round());
    final want100 = max(stair, (1.25 * sqrtN).round());
    final want = x <= 0.50
        ? (stair + (want50 - stair) * (x / 0.50)).round()
        : (want50 + (want100 - want50) * ((x - 0.50) / 0.50)).round();
    return min(nLeaves, max(stair, min(want, cap)));
  }

  /// In-memory cached navigating centroid graph per index.
  /// Key: tableUid/indexUid
  final Map<String, NghNavGraphPage> _navGraphCache = {};

  /// Per-centroid compact SQ8 cache. Key: `tableUid/indexUid/centroidId`.
  final LinkedHashMap<String, List<_NghCompactSlot>> _inMemoryClusterCache =
      LinkedHashMap<String, List<_NghCompactSlot>>();

  /// Estimated resident bytes of [_inMemoryClusterCache].
  int _clusterCacheBytes = 0;

  /// Soft ceiling for cluster compact cache; enforced after load/prewarm.
  ///
  /// Default is a floor only. [configureClusterCacheBudget] is synced from
  /// [ResourceManager] index quota once that manager finishes initializing
  /// (VectorIndexManager is constructed earlier, when the quota is still 0).
  int _clusterCacheMaxBytes = 32 * 1024 * 1024;

  final Map<String, Future<void>> _clusterLoadInflight = {};

  late final NghPkMapEngine _pkMap =
      NghPkMapEngine(_partitionManager, _partitionManager.engineConfig);

  NghGraphEngine(this._partitionManager);

  /// Format / page-directory cap for top-level IVF ids.
  static const int _maxTargetK = 16384;

  /// L0 IVF lists (roots: coarses ∪ orphan leaves). Exact-scanned on insert.
  /// Nested coarses are children, not L0 — otherwise K grows past 256 and
  /// 10k-flush assignment returns to minutes at 10M+.
  static const int _maxTopLevelRouting = 256;

  /// Coarse→mid→leaf hops. 256^3 × ~4k ≈ 68B; deeper would need childrenDir.
  static const int _maxIvfDepth = 2;

  /// Hard cap on live vectors in one leaf. Fair-share softCap must not exceed
  /// this or 10B corpora collapse into ~610k-slot lists (search I/O avalanche).
  static int _leafEntryCap(int slotsPerPage) =>
      max(4096, 64 * max(1, slotsPerPage));

  int get _pageSize => _partitionManager.configuredPageSize;

  /// Current estimated cluster-cache footprint in bytes.
  int get clusterCacheBytes => _clusterCacheBytes;

  /// Current compact-cache ceiling in bytes.
  int get clusterCacheMaxBytes => _clusterCacheMaxBytes;

  /// Configure cluster-cache ceiling (typically a share of the index budget).
  void configureClusterCacheBudget(int maxBytes) {
    _clusterCacheMaxBytes = max(4 * 1024 * 1024, maxBytes);
    _enforceClusterCacheBudget();
  }

  int _liveCompactCount(List<_NghCompactSlot> slots) {
    var n = 0;
    for (final slot in slots) {
      if (slot.flags & 0x01 == 0) n++;
    }
    return n;
  }

  int _estimateCompactIndexBytes(
    List<NghNavCentroidNode> centroids,
    int dimensions,
  ) {
    var bytes = 64;
    for (final c in centroids) {
      if (c.isCoarse) continue;
      bytes += max(1, c.entryCount) * (24 + dimensions);
    }
    return bytes;
  }

  List<_NghCompactSlot> _compactNewSlots(
    List<NghPostingSlot> slots,
    int pageNo,
  ) {
    return [
      for (final slot in slots) _compactFromPostingSlot(slot, pageNo),
    ];
  }

  /// Keep the search compact cache coherent after insert.
  ///
  /// Never publish a *partial* batch as the whole cluster (that made search
  /// skip disk and recall collapse to the last flush). Do keep:
  /// 1. brand-new / batch-complete clusters
  /// 2. append onto a cache that already held the pre-batch cluster
  /// Returns true only when the corpus still fits the budget **and** some
  /// leaves are missing (cold process / first fill). Already-warm small
  /// indexes must not trigger a post-flush prewarm on every persist.
  bool _refreshCompactCacheAfterInsert({
    required String cacheKey,
    required List<NghNavCentroidNode> centroids,
    required Map<int, List<NghPostingSlot>> clusterSlots,
    required Set<int> rewrittenIds,
    required Set<int> newCentroidIds,
    required int dimensions,
  }) {
    final fits = _estimateCompactIndexBytes(centroids, dimensions) <=
        _clusterCacheMaxBytes;
    final protect = <String>{
      for (final cId in rewrittenIds) _centroidCacheKey(cacheKey, cId),
    };

    for (final cId in clusterSlots.keys) {
      if (rewrittenIds.contains(cId)) {
        protect.add(_centroidCacheKey(cacheKey, cId));
        continue;
      }
      if (cId < 0 || cId >= centroids.length) {
        _removeCentroidSlots(cacheKey, cId);
        continue;
      }
      final newSlots = clusterSlots[cId]!;
      final centroid = centroids[cId];
      final packedRef =
          centroid.tailPostingPageNo > 0 ? centroid.tailPostingPageNo : 1;
      final ck = _centroidCacheKey(cacheKey, cId);
      final cached = _inMemoryClusterCache[ck];
      final liveCached = cached == null ? 0 : _liveCompactCount(cached);
      final newCount = newSlots.length;

      if (newCentroidIds.contains(cId) || centroid.entryCount == newCount) {
        _putCentroidSlots(
          cacheKey,
          cId,
          _compactNewSlots(newSlots, packedRef),
        );
        protect.add(ck);
        continue;
      }

      if (cached != null &&
          newCount > 0 &&
          liveCached + newCount >= centroid.entryCount) {
        final merged = List<_NghCompactSlot>.from(cached)
          ..addAll(_compactNewSlots(newSlots, packedRef));
        _putCentroidSlots(cacheKey, cId, merged);
        protect.add(ck);
        continue;
      }

      // Incomplete and not cached: drop so search cannot treat a stump as
      // the whole list. Small indexes reload after persist.
      _removeCentroidSlots(cacheKey, cId);
    }

    _enforceClusterCacheBudget(protectKeys: protect);
    if (!fits) return false;
    for (final c in centroids) {
      if (c.isCoarse || c.entryCount <= 0) continue;
      if (!_inMemoryClusterCache
          .containsKey(_centroidCacheKey(cacheKey, c.centroidId))) {
        return true;
      }
    }
    return false;
  }

  String _cacheKey(TableUid tableUid, IndexUid indexUid) =>
      '${tableUid.value}/${indexUid.value}';

  int _estimateSlotBytes(_NghCompactSlot slot) =>
      24 + slot.primaryKeyBytes.length + slot.sq8Codes.length;

  _NghCompactSlot _compactFromPostingSlot(NghPostingSlot slot, int pageNo) {
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

  int _estimateSlotListBytes(List<_NghCompactSlot> slots) {
    var bytes = 16;
    for (final slot in slots) {
      bytes += _estimateSlotBytes(slot);
    }
    return bytes;
  }

  String _centroidCacheKey(String indexKey, int centroidId) =>
      '$indexKey/$centroidId';

  bool _clusterCacheIsFresh(
    List<_NghCompactSlot> cached,
    NghNavCentroidNode centroid,
  ) {
    if (centroid.entryCount <= 0) return true;
    var live = 0;
    for (final slot in cached) {
      if (slot.flags & 0x01 == 0) live++;
    }
    final minLive = min(centroid.entryCount, (centroid.entryCount * 3) ~/ 4);
    return live >= minLive;
  }

  void _touchCentroidCacheKey(String key) {
    final list = _inMemoryClusterCache.remove(key);
    if (list != null) {
      _inMemoryClusterCache[key] = list;
    }
  }

  void _putCentroidSlots(
      String indexKey, int centroidId, List<_NghCompactSlot> slots) {
    final key = _centroidCacheKey(indexKey, centroidId);
    final old = _inMemoryClusterCache.remove(key);
    if (old != null) {
      _clusterCacheBytes =
          max(0, _clusterCacheBytes - _estimateSlotListBytes(old));
    }
    _inMemoryClusterCache[key] = slots;
    _clusterCacheBytes += _estimateSlotListBytes(slots);
  }

  void _removeCentroidSlots(String indexKey, int centroidId) {
    final key = _centroidCacheKey(indexKey, centroidId);
    final old = _inMemoryClusterCache.remove(key);
    if (old != null) {
      _clusterCacheBytes =
          max(0, _clusterCacheBytes - _estimateSlotListBytes(old));
    }
  }

  /// Evict oldest centroid lists until under [targetBytes].
  void _enforceClusterCacheBudget(
      {Set<String>? protectKeys, int? targetBytes}) {
    final limit = targetBytes ?? _clusterCacheMaxBytes;
    if (_clusterCacheBytes <= limit) return;

    final keys = _inMemoryClusterCache.keys.toList(growable: false);
    for (final key in keys) {
      if (_clusterCacheBytes <= limit) break;
      if (protectKeys != null && protectKeys.contains(key)) continue;
      final removed = _inMemoryClusterCache.remove(key);
      if (removed == null) continue;
      _clusterCacheBytes =
          max(0, _clusterCacheBytes - _estimateSlotListBytes(removed));
    }

    if (_clusterCacheBytes > limit && protectKeys != null) {
      for (final key in protectKeys) {
        if (_clusterCacheBytes <= limit) break;
        final removed = _inMemoryClusterCache.remove(key);
        if (removed == null) continue;
        _clusterCacheBytes =
            max(0, _clusterCacheBytes - _estimateSlotListBytes(removed));
      }
    }
  }

  /// Evict a ratio of cluster compact caches (oldest centroids first).
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
        _clusterCacheBytes =
            max(0, _clusterCacheBytes - _estimateSlotListBytes(removed));
      }
    }
    _navGraphCache.removeWhere((k, _) => k.startsWith(prefix));
  }

  /// Clear cluster cache for a specific index.
  void clearCacheForIndex(TableUid tableUid, IndexUid indexUid) {
    final prefix = '${_cacheKey(tableUid, indexUid)}/';
    final toRemove = <String>[
      for (final k in _inMemoryClusterCache.keys)
        if (k.startsWith(prefix) || k == _cacheKey(tableUid, indexUid)) k,
    ];
    for (final k in toRemove) {
      final removed = _inMemoryClusterCache.remove(k);
      if (removed != null) {
        _clusterCacheBytes =
            max(0, _clusterCacheBytes - _estimateSlotListBytes(removed));
      }
    }
    _navGraphCache.remove(_cacheKey(tableUid, indexUid));
  }

  /// Clear all cluster caches.
  void clearCache() {
    _inMemoryClusterCache.clear();
    _navGraphCache.clear();
    _clusterCacheBytes = 0;
  }

  void _ingestLoadedPagesIntoClusterMap({
    required Map<int, List<_NghCompactSlot>> clusterMap,
    required List<({int packedRef, NghPostingPage page})> loaded,
    required Set<int> expectedCentroidIds,
    Map<int, int>? packedOwner,
  }) {
    for (final item in loaded) {
      final owner = packedOwner?[item.packedRef] ?? item.page.centroidId;
      final cList = clusterMap.putIfAbsent(owner, () => []);
      for (final slot in item.page.slots) {
        final compact = _compactFromPostingSlot(slot, item.packedRef);
        cList.add(compact);
      }
    }
    for (final cId in expectedCentroidIds) {
      clusterMap.putIfAbsent(cId, () => <_NghCompactSlot>[]);
    }
  }

  void _ingestIdPagesIntoClusterMap({
    required Map<int, List<_NghCompactSlot>> clusterMap,
    required List<({NghPageId id, NghPostingPage page})> loaded,
    required Set<int> expectedCentroidIds,
    Map<int, int>? pageOwnerByCacheKey,
  }) {
    for (final item in loaded) {
      final owner =
          pageOwnerByCacheKey?[item.id.cacheKey] ?? item.page.centroidId;
      final cList = clusterMap.putIfAbsent(owner, () => []);
      final packed = item.id.tryPack() ?? item.id.cacheKey;
      for (final slot in item.page.slots) {
        cList.add(_compactFromPostingSlot(slot, packed));
      }
    }
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
    final pageIdsToRead = <NghPageId>[];
    final chainHeads = <int>[];
    final expected = <int>{};
    final protect = <String>{};
    final pageOwnerByCacheKey = <int, int>{};
    final packedOwner = <int, int>{};

    for (final cId in probeCentroids) {
      if (cId < 0 || cId >= navGraph.centroids.length) continue;
      final ck = _centroidCacheKey(cacheKey, cId);
      protect.add(ck);
      final cached = _inMemoryClusterCache[ck];
      if (cached != null &&
          _clusterCacheIsFresh(cached, navGraph.centroids[cId])) {
        clusterMap[cId] = cached;
        _touchCentroidCacheKey(ck);
        continue;
      }
      if (cached != null) _removeCentroidSlots(cacheKey, cId);
      if (clusterMap.containsKey(cId)) continue;
      expected.add(cId);
      final c = navGraph.centroids[cId];
      if (c.postingPages.isEmpty && !c.postingDirRoot.isNone) {
        await _partitionManager.hydratePostingDirs(table, indexUid, [c]);
      }
      if (c.postingPages.isNotEmpty) {
        for (final pid in c.postingPages) {
          pageIdsToRead.add(pid);
          pageOwnerByCacheKey[pid.cacheKey] = cId;
        }
      } else if (c.postingPageNos.isNotEmpty) {
        for (final p in c.postingPageNos) {
          if (p > 0) {
            final pid = NghPageId.fromPacked(p);
            pageIdsToRead.add(pid);
            pageOwnerByCacheKey[pid.cacheKey] = cId;
          }
        }
      } else if (c.headPostingPageNo > 0) {
        chainHeads.add(c.headPostingPageNo);
        packedOwner[c.headPostingPageNo] = cId;
      } else {
        clusterMap[cId] = <_NghCompactSlot>[];
      }
    }

    Future<void> load() async {
      if (pageIdsToRead.isNotEmpty) {
        final unique = <int, NghPageId>{};
        for (final id in pageIdsToRead) {
          unique[id.cacheKey] = id;
        }
        final loaded = await _partitionManager.readPostingPagesByIds(
          table,
          indexUid,
          meta,
          unique.values.toList(growable: false),
          populatePageCache: false,
        );
        _ingestIdPagesIntoClusterMap(
          clusterMap: clusterMap,
          loaded: loaded,
          expectedCentroidIds: expected,
          pageOwnerByCacheKey: pageOwnerByCacheKey,
        );
      }
      if (chainHeads.isNotEmpty) {
        final chains = await _partitionManager.readPostingClustersBatch(
          table,
          indexUid,
          meta,
          chainHeads,
        );
        for (final chain in chains) {
          final headOwner =
              chain.isEmpty ? null : packedOwner[chain.first.packedRef];
          _ingestLoadedPagesIntoClusterMap(
            clusterMap: clusterMap,
            loaded: chain,
            expectedCentroidIds: expected,
            packedOwner: headOwner == null
                ? packedOwner
                : {
                    for (final item in chain) item.packedRef: headOwner,
                  },
          );
        }
      }
      for (final cId in expected) {
        final slots = clusterMap.putIfAbsent(cId, () => <_NghCompactSlot>[]);
        _putCentroidSlots(cacheKey, cId, slots);
      }
      _enforceClusterCacheBudget(protectKeys: protect);
    }

    final inflightKey = '$cacheKey/load/${probeCentroids.join(',')}';
    final existing = _clusterLoadInflight[inflightKey];
    if (existing != null) {
      await existing;
      for (final cId in probeCentroids) {
        final cached = _inMemoryClusterCache[_centroidCacheKey(cacheKey, cId)];
        if (cached != null) clusterMap[cId] = cached;
      }
      return;
    }
    final future = load();
    _clusterLoadInflight[inflightKey] = future;
    try {
      await future;
    } finally {
      _clusterLoadInflight.remove(inflightKey);
    }
  }

  /// Startup/runtime prewarm: load posting clusters into compact cache.
  ///
  /// Stops once [maxBytes] would be exceeded (OOM guard). Hot clusters
  /// (highest entryCount) are loaded first. Returns bytes added.
  ///
  /// Loads in small cluster/page batches and yields to the event loop between
  /// batches so [shouldAbort] (close / switchSpace) can stop promptly — same
  /// cooperative pattern as table/index row prewarm.
  Future<int> prewarmClusters({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required int maxBytes,
    bool Function()? shouldAbort,
  }) async {
    bool aborted() => shouldAbort?.call() ?? false;
    if (maxBytes <= 0 || meta.totalVectors <= 0 || aborted()) return 0;

    final key = _cacheKey(table.tableUid, indexUid);
    final beforeBytes = _clusterCacheBytes;
    final navGraph = await _getOrLoadNavGraph(table, indexUid, meta);
    if (navGraph == null || navGraph.centroids.isEmpty || aborted()) return 0;

    final centroids = navGraph.centroids;
    final order = List<int>.generate(centroids.length, (i) => i);

    // When the whole compact index fits the budget, load every cluster so
    // arbitrary query vectors never pay disk I/O on probed-centroid misses.
    var totalEst = 64;
    for (final c in centroids) {
      if (c.isCoarse) continue;
      totalEst += max(1, c.entryCount) * (24 + meta.dimensions);
    }
    final loadAll = totalEst <= maxBytes;
    if (!loadAll) {
      order.sort(
          (a, b) => centroids[b].entryCount.compareTo(centroids[a].entryCount));
    }

    // Cluster batches + small page chunks keep close/switchSpace responsive
    // under large vector counts (hundreds of thousands).
    const clustersPerBatch = 16;
    const pageChunkSize = 16;
    final yieldController =
        YieldController('NghGraphEngine.prewarmClusters', checkInterval: 1);
    var planned = 0;
    var budgetExhausted = false;
    final protect = <String>{};

    for (var batchStart = 0;
        batchStart < order.length && !budgetExhausted;
        batchStart += clustersPerBatch) {
      if (aborted()) break;
      if (_clusterCacheBytes - beforeBytes >= maxBytes) break;

      final pageIds = <NghPageId>[];
      final chainHeads = <int>[];
      final expected = <int>{};
      final batchMap = <int, List<_NghCompactSlot>>{};
      final pageOwnerByCacheKey = <int, int>{};
      final packedOwner = <int, int>{};
      final batchEnd = min(batchStart + clustersPerBatch, order.length);

      for (var i = batchStart; i < batchEnd; i++) {
        final cId = order[i];
        final ck = _centroidCacheKey(key, cId);
        if (_inMemoryClusterCache.containsKey(ck)) {
          protect.add(ck);
          continue;
        }
        final c = centroids[cId];
        if (c.isCoarse) continue;
        if (!loadAll) {
          final est = max(1, c.entryCount) * (24 + meta.dimensions);
          if (planned + est > maxBytes) {
            budgetExhausted = true;
            break;
          }
          planned += est;
        }

        expected.add(cId);
        protect.add(ck);
        if (c.postingPages.isEmpty && !c.postingDirRoot.isNone) {
          await _partitionManager.hydratePostingDirs(table, indexUid, [c]);
        }
        if (c.postingPages.isNotEmpty) {
          for (final pid in c.postingPages) {
            pageIds.add(pid);
            pageOwnerByCacheKey[pid.cacheKey] = cId;
          }
        } else if (c.postingPageNos.isNotEmpty) {
          for (final p in c.postingPageNos) {
            if (p > 0) {
              final pid = NghPageId.fromPacked(p);
              pageIds.add(pid);
              pageOwnerByCacheKey[pid.cacheKey] = cId;
            }
          }
        } else if (c.headPostingPageNo > 0) {
          chainHeads.add(c.headPostingPageNo);
          packedOwner[c.headPostingPageNo] = cId;
        } else {
          _putCentroidSlots(key, cId, const []);
        }
      }

      for (var i = 0; i < pageIds.length; i += pageChunkSize) {
        if (aborted() || _clusterCacheBytes - beforeBytes >= maxBytes) {
          budgetExhausted = _clusterCacheBytes - beforeBytes >= maxBytes;
          break;
        }
        final chunk = pageIds.sublist(
          i,
          min(i + pageChunkSize, pageIds.length),
        );
        final loaded = await _partitionManager.readPostingPagesByIds(
          table,
          indexUid,
          meta,
          chunk,
          populatePageCache: false,
        );
        if (aborted()) break;
        _ingestIdPagesIntoClusterMap(
          clusterMap: batchMap,
          loaded: loaded,
          expectedCentroidIds: const {},
          pageOwnerByCacheKey: pageOwnerByCacheKey,
        );
        await Future<void>.delayed(Duration.zero);
      }

      if (aborted()) break;

      if (chainHeads.isNotEmpty &&
          _clusterCacheBytes - beforeBytes < maxBytes) {
        for (final head in chainHeads) {
          if (aborted() || _clusterCacheBytes - beforeBytes >= maxBytes) {
            break;
          }
          final chain = await _partitionManager.readPostingCluster(
            table,
            indexUid,
            meta,
            head,
          );
          if (aborted()) break;
          _ingestLoadedPagesIntoClusterMap(
            clusterMap: batchMap,
            loaded: chain,
            expectedCentroidIds: const {},
            packedOwner: {
              if (packedOwner[head] != null)
                for (final item in chain) item.packedRef: packedOwner[head]!,
            },
          );
          await Future<void>.delayed(Duration.zero);
        }
      }

      if (aborted()) break;

      for (final cId in expected) {
        final slots = batchMap.putIfAbsent(cId, () => <_NghCompactSlot>[]);
        _putCentroidSlots(key, cId, slots);
      }

      final y = yieldController.maybeYield();
      if (y != null) await y;
    }

    // Partial warm on abort is fine; still cap for coherent resident state.
    if (_clusterCacheBytes > _clusterCacheMaxBytes) {
      _enforceClusterCacheBudget(protectKeys: protect);
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

  /// Top-level IVF routing nodes: coarses plus orphan (unsplit) leaves.
  ///
  /// Mixed graphs must keep leftover flat leaves in the same exact scan as
  /// coarses. Routing only among coarses is what made identity recall collapse
  /// to ~nprobe/K once the first hub was promoted.
  List<int> _topLevelRoutingIds(List<NghNavCentroidNode> centroids) {
    final n = centroids.length;
    if (n == 0) return <int>[];
    var hasCoarse = false;
    final isChild = Uint8List(n);
    for (int i = 0; i < n; i++) {
      final c = centroids[i];
      if (!c.isCoarse) continue;
      hasCoarse = true;
      for (final ch in c.childIds) {
        if (ch >= 0 && ch < n) isChild[ch] = 1;
      }
    }
    if (!hasCoarse) {
      return List<int>.generate(n, (i) => i);
    }
    // Roots only: L0 coarses and leftover orphan leaves. Nested coarses are
    // children — listing every coarse here blew past the 256 insert scan.
    final ids = <int>[];
    for (int i = 0; i < n; i++) {
      if (isChild[i] == 0) ids.add(i);
    }
    return ids.isEmpty ? List<int>.generate(n, (i) => i) : ids;
  }

  int _leafNprobeForChildren(int childCount, double t) {
    if (childCount <= 1) return max(0, childCount);
    final cov = _nlistCoverageForIntensity(t);
    var n = max(1, (cov * childCount).ceil());
    // Mid-depth floor of 4 spent budget inside the first coarses, then
    // score-budget clamp dropped everything to 1 list at 500k+. Keep 1
    // child until depth 50 so extra parent nprobe buys more Voronoi cells.
    final floor = t < 0.50
        ? 1
        : (t < 0.70
            ? min(2, childCount)
            : (t < 0.85 ? min(4, childCount) : min(8, childCount)));
    n = max(n, floor);
    return min(childCount, min(n, _maxInteractiveLeaves));
  }

  /// Exact partial selection among [routing] (same recall as a full sort).
  List<int> _selectExactNearestIds({
    required Float32List vec,
    required List<NghNavCentroidNode> centroids,
    required List<int> routing,
    required VectorDistanceMetric metric,
    required int nprobe,
  }) {
    if (routing.isEmpty) return const [];
    final want = min(routing.length, max(1, nprobe));
    if (want >= routing.length) {
      return List<int>.from(routing, growable: false);
    }

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

    for (final i in routing) {
      if (i < 0 || i >= centroids.length) continue;
      final d = _exactDistance(vec, centroids[i].vector, metric);
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

  /// Centroid-major exact top-2 among [ids] for [vectors] `[from, n)`.
  ///
  /// Same nearest/second as a per-vector scan; keeps one centroid in cache
  /// while streaming a tile of queries (insert of 10k at K=256 is seconds,
  /// not a query-major scan of thousands of 512-d centroids).
  void _accumulateTop2AgainstIds({
    required List<Float32List> vectors,
    required List<NghNavCentroidNode> centroids,
    required List<int> ids,
    required VectorDistanceMetric metric,
    required Int32List bestId,
    required Float64List bestD,
    required Int32List secondId,
    required Float64List secondD,
    required int from,
  }) {
    final n = vectors.length;
    if (from >= n || ids.isEmpty) return;
    for (final cid in ids) {
      if (cid < 0 || cid >= centroids.length) continue;
      _accumulateTop2AgainstCentroid(
        vectors: vectors,
        centroid: centroids[cid].vector,
        centroidId: cid,
        metric: metric,
        bestId: bestId,
        bestD: bestD,
        secondId: secondId,
        secondD: secondD,
        from: from,
      );
    }
  }

  void _accumulateTop2AgainstCentroid({
    required List<Float32List> vectors,
    required Float32List centroid,
    required int centroidId,
    required VectorDistanceMetric metric,
    required Int32List bestId,
    required Float64List bestD,
    required Int32List secondId,
    required Float64List secondD,
    required int from,
  }) {
    const tile = 32;
    final n = vectors.length;
    if (from >= n) return;
    for (int t = from; t < n; t += tile) {
      final end = min(n, t + tile);
      for (int i = t; i < end; i++) {
        final d = _exactDistance(vectors[i], centroid, metric);
        if (d < bestD[i]) {
          secondD[i] = bestD[i];
          secondId[i] = bestId[i];
          bestD[i] = d;
          bestId[i] = centroidId;
        } else if (d < secondD[i]) {
          secondD[i] = d;
          secondId[i] = centroidId;
        }
      }
    }
  }

  List<Float32List> _kMeansSample(List<Float32List> vectors, int maxSamples) {
    final n = vectors.length;
    if (n <= maxSamples) return vectors;
    return [
      for (int s = 0; s < maxSamples; s++) vectors[(s * n) ~/ maxSamples],
    ];
  }

  /// Select nearest **top-level** lists by exact distance (partial selection).
  ///
  /// Do **not** truncate by entryCount budget here — giant nearest clusters
  /// would consume the budget and drop the drifted home cluster (exact-identity
  /// misses). Cost control belongs in nprobe planning + SQ8/two-pass scoring.
  List<int> _selectProbeCentroids({
    required Float32List searchQuery,
    required NghNavGraphPage navGraph,
    required VectorDistanceMetric metric,
    required int nprobe,
    List<int>? routingIds,
  }) {
    final routing = routingIds ?? _topLevelRoutingIds(navGraph.centroids);
    return _selectExactNearestIds(
      vec: searchQuery,
      centroids: navGraph.centroids,
      routing: routing,
      metric: metric,
      nprobe: nprobe,
    );
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

    final alwaysKeep = min(probes.length, max(1, minKeep));
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

  /// Replace coarse probes with an exact child-nprobe (multi-level IVF).
  ///
  /// One hop is not enough once hubs nest (parent-full → mid-coarse). Recurse
  /// to leaves; each hop keeps the nearest child so identity routing matches
  /// insert. Expanding *all* children of nprobe coarses would still avalanche.
  List<int> _expandCoarseChildren({
    required List<int> probes,
    required NghNavGraphPage navGraph,
    required Float32List query,
    required VectorDistanceMetric metric,
    required int Function(int childCount) leafNprobeOf,
  }) {
    final n = navGraph.centroids.length;
    var current = probes;
    for (var hop = 0; hop < _maxIvfDepth + 1; hop++) {
      var sawCoarse = false;
      final out = <int>[];
      final seen = <int>{};
      for (final id in current) {
        if (id < 0 || id >= n) continue;
        final c = navGraph.centroids[id];
        if (c.isCoarse && c.childIds.isNotEmpty) {
          sawCoarse = true;
          final children = <int>[
            for (final ch in c.childIds)
              if (ch >= 0 && ch < n) ch,
          ];
          if (children.isEmpty) continue;
          final picked = _selectExactNearestIds(
            vec: query,
            centroids: navGraph.centroids,
            routing: children,
            metric: metric,
            nprobe: leafNprobeOf(children.length),
          );
          for (final ch in picked) {
            if (seen.add(ch)) out.add(ch);
          }
        } else if (seen.add(id)) {
          out.add(id);
        }
      }
      if (!sawCoarse) return out.isNotEmpty ? out : current;
      current = out;
      if (current.isEmpty) break;
    }
    return current;
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
    final clusterMap = <int, List<_NghCompactSlot>>{};

    NghNavGraphPage? navGraph = await _getOrLoadNavGraph(table, indexUid, meta);
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
    final routingIds = _topLevelRoutingIds(navGraph.centroids);
    var nLeaves = 0;
    for (final c in navGraph.centroids) {
      if (c.isLeaf) nLeaves++;
    }
    final plan = _resolveNprobePlan(
      nCentroids:
          routingIds.isNotEmpty ? routingIds.length : navGraph.centroids.length,
      nLeaves: max(1, nLeaves),
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
      routingIds: routingIds,
    );

    final depthT = plan.depth / 100.0;
    final int maxNeighborExtra;
    if (depthT < 0.20) {
      maxNeighborExtra = 0;
    } else if (depthT < 0.50) {
      maxNeighborExtra = 1;
    } else if (depthT < 0.70) {
      maxNeighborExtra = min(3, max(1, (plan.nprobe * 0.20).round()));
    } else {
      maxNeighborExtra =
          min(8, max(2, (plan.nprobe * (0.12 + 0.12 * depthT)).round()));
    }
    var probeCentroids = maxNeighborExtra <= 0
        ? primaryProbes
        : _expandProbeWithNeighbors(
            seeds: primaryProbes,
            navGraph: navGraph,
            maxExtra: maxNeighborExtra,
          );
    probeCentroids = _expandCoarseChildren(
      probes: probeCentroids,
      navGraph: navGraph,
      query: searchQuery,
      metric: meta.distanceMetric,
      leafNprobeOf: (childCount) => _leafNprobeForChildren(childCount, depthT),
    );

    final avgCluster = max(
      1,
      (meta.totalVectors /
              max(1, nLeaves > 0 ? nLeaves : navGraph.centroids.length))
          .round(),
    );
    final slotCap = _slotCapForDepth(depthT);
    final trimBudget = (plan.maxCandidates * (0.92 + 0.25 * depthT))
        .round()
        .clamp(plan.maxCandidates, slotCap);
    final minKeep = min(
      probeCentroids.length,
      _minKeepLeaves(depthT, nLeaves: nLeaves),
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

    // Depth-scaled floor at every depth — not only ≥80. At 500k one leaf
    // already ≈ scoreBudget, so a 0/1 floor collapses 1..79 to a single list.
    final minProbeFloor = min(rankedProbes.length, minKeep);
    if (minProbeFloor > 1 && probeCentroids.length < minProbeFloor) {
      probeCentroids = _topUpProbesToMinCount(
        ranked: rankedProbes,
        current: probeCentroids,
        minCount: minProbeFloor,
        navGraph: navGraph,
        softCandidateBudget: trimBudget,
        depthT: depthT,
      );
    }

    final scoreBudget = (plan.maxCandidates * (1.05 + 0.20 * depthT))
        .round()
        .clamp(plan.maxCandidates, slotCap);
    probeCentroids = _clampProbesToScoreBudget(
      ranked: rankedProbes,
      current: probeCentroids,
      navGraph: navGraph,
      scoreBudget: scoreBudget,
      minProbes: minKeep,
    );

    var needsLoad = false;
    for (final cId in probeCentroids) {
      if (cId < 0 || cId >= navGraph.centroids.length) {
        needsLoad = true;
        continue;
      }
      final ck = _centroidCacheKey(key, cId);
      final cached = _inMemoryClusterCache[ck];
      if (cached != null &&
          _clusterCacheIsFresh(cached, navGraph.centroids[cId])) {
        clusterMap[cId] = cached;
        _touchCentroidCacheKey(ck);
      } else {
        if (cached != null) _removeCentroidSlots(key, cId);
        needsLoad = true;
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
    final pending = pendingDeletePks;
    return [
      for (final r in rawResults)
        if (pending == null ||
            r.primaryKeyBytes == null ||
            !pending.contains(utf8.decode(r.primaryKeyBytes!)))
          NghSearchResult(
            nodeId: r.nodeId,
            distance: r.distance,
            primaryKey: r.primaryKeyBytes != null
                ? utf8.decode(r.primaryKeyBytes!)
                : null,
          )
    ];
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

    // Skip the strided pass when we would rescore nearly everyone anyway.
    if (keep >= (candidateCount * 0.88).ceil()) {
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

  int _appendSlotsUntilFull(
    NghPostingPage page,
    List<NghPostingSlot> src,
    int from,
  ) {
    var i = from;
    while (i < src.length) {
      page.slots.add(src[i]);
      if (!_partitionManager.postingPayloadFits(page.estimatePayloadSize())) {
        page.slots.removeLast();
        break;
      }
      i++;
    }
    return i;
  }

  // =====================================================================
  // Insertion -- Streaming Incremental Assignment with Dynamic Split
  // =====================================================================

  /// Insert a batch of vectors into the NGH index.
  Future<NghInsertResult> insertBatch({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required List<Float32List> vectors,
    required List<String> primaryKeys,
    int? yieldBudgetMs,
  }) async {
    if (vectors.isEmpty) {
      return NghInsertResult(
        meta: meta,
        dirtyPostingPages: const {},
        insertedCount: 0,
      );
    }

    final dirtyPosting = <NghPagePtr, NghPostingPage>{};
    final localPostingCache = <int, NghPostingPage>{};
    var currentMeta = meta;

    // Load or initialize navigating centroid graph
    var navGraph = await _getOrLoadNavGraph(table, indexUid, currentMeta);
    final centroids = <NghNavCentroidNode>[
      if (navGraph != null) ...navGraph.centroids,
    ];

    final isCosineMetric =
        currentMeta.distanceMetric == VectorDistanceMetric.cosine;

    // Step 1: Batch Normalized SQ8 Quantization (pure Dart synchronous)
    final normalizedVectors = isCosineMetric
        ? List<Float32List>.generate(
            vectors.length, (i) => _normalizeFloat32(vectors[i]),
            growable: false)
        : vectors;
    final sq8List = ScalarQuantizer.quantizeBatch(normalizedVectors);

    final maxSlotsPerPage = NghPageSizer.estimatePostingSlotsPerPage(
      _pageSize,
      currentMeta.dimensions,
    );

    final clusterSlots = <int, List<NghPostingSlot>>{};
    final newCentroids = <NghNavCentroidNode>[];
    final newDirPages = <int, List<NghPageId>>{};
    final startedEmpty = centroids.isEmpty;

    // Metric-aware distance spawn threshold (far from all centroids).
    final double splitDistThreshold = isCosineMetric
        ? 0.32
        : (currentMeta.distanceMetric == VectorDistanceMetric.innerProduct
            ? -0.68
            : 0.65);

    // Dynamic centroids: leaf K capped; format supports two-level IVF beyond this.
    final int projectedN = currentMeta.totalVectors + vectors.length;
    final int targetK = min(
      _maxTargetK,
      max(48, (sqrt(projectedN) * 2.25).round()),
    );

    // Cold start: k-means on the first batch (do NOT pre-seed centroid 0 —
    // that previously made this block unreachable and produced hub clusters).
    if (centroids.isEmpty) {
      final initialK = min(targetK, max(16, min(vectors.length, 64)));
      // Full-batch k-means++ on 10k×512×64 is several seconds; 1024 seeds
      // give the same IVF skeleton and the insert loop still assigns all rows.
      final kmPool = _kMeansSample(normalizedVectors, 1024);
      final seeds = _kMeansInit(
        samples: kmPool,
        k: max(1, min(initialK, kmPool.length)),
        metric: currentMeta.distanceMetric,
        iterations: 5,
      );

      for (int c = 0; c < seeds.length; c++) {
        final node = NghNavCentroidNode(
          centroidId: c,
          vector: seeds[c],
          headPostingPageNo: -1,
          tailPostingPageNo: -1,
          postingPageNos: [],
          entryCount: 0,
          neighbors: [],
        );
        centroids.add(node);
        newCentroids.add(node);
      }
    }

    // Step 2: Assign with distance spawn only. Oversized hubs are fixed at
    // batch end via 2-means posting rewrite (spawn-without-move cannot lower
    // max/avg imbalance).
    final clusterVectors = <int, List<Float32List>>{};
    final topLevelIds = List<int>.from(_topLevelRoutingIds(centroids));
    var leafK = 0;
    var hasCoarse = false;
    for (final c in centroids) {
      if (c.isLeaf) leafK++;
      if (c.isCoarse) hasCoarse = true;
    }
    final maxChildren = NghPageSizer.maxNavInlineChildren(
      _pageSize,
      currentMeta.dimensions,
    );
    final leafCap = _leafEntryCap(maxSlotsPerPage);
    final routingCap = min(_maxTopLevelRouting, min(targetK, _maxTargetK));
    final assignMetric = currentMeta.distanceMetric;

    int softCapForK(int k) {
      final kk = max(1, k);
      final fair = max(96, (1.75 * projectedN / kk).round());
      return min(fair, leafCap);
    }

    void attachSpawnedLeaf(NghNavCentroidNode node, {required int parentId}) {
      if (parentId < 0 || parentId >= centroids.length) return;
      final parent = centroids[parentId];
      if (!parent.isCoarse) return;
      if (parent.childIds.length >= maxChildren) return;
      if (!parent.childIds.contains(node.centroidId)) {
        parent.childIds.add(node.centroidId);
      }
      node.parentId = parentId;
      node.level = NghNavCentroidNode.levelLeaf;
    }

    final nAssign = vectors.length;
    final bestId = Int32List(nAssign);
    final secondId = Int32List(nAssign);
    final bestD = Float64List(nAssign);
    final secondD = Float64List(nAssign);
    for (int i = 0; i < nAssign; i++) {
      bestId[i] = -1;
      secondId[i] = -1;
      bestD[i] = double.infinity;
      secondD[i] = double.infinity;
    }
    // Centroid-major exact top-2 (same nearest as per-vector scan, L1-friendly).
    _accumulateTop2AgainstIds(
      vectors: normalizedVectors,
      centroids: centroids,
      ids: topLevelIds,
      metric: assignMetric,
      bestId: bestId,
      bestD: bestD,
      secondId: secondId,
      secondD: secondD,
      from: 0,
    );

    for (int i = 0; i < nAssign; i++) {
      final vec = normalizedVectors[i];
      final pk = primaryKeys[i];
      final sq8 = sq8List[i];
      final nodeId = currentMeta.nextNodeId + i;

      final slot = NghPostingSlot(
        nodeId: nodeId,
        flags: 0,
        primaryKey: pk,
        sq8Codes: sq8.codes,
        offset: sq8.offset,
        scale: sq8.scale,
        squaredNorm: sq8.squaredNorm,
      );

      final rawBest = bestId[i];
      final rawSecond = secondId[i];
      final bestDist = bestD[i];
      final secondDist = secondD[i];
      final bestCId = hasCoarse
          ? _resolveLeafCentroid(rawBest, centroids, vec, assignMetric)
          : (rawBest < 0 ? 0 : rawBest);
      var secondCId = rawSecond < 0
          ? -1
          : (hasCoarse
              ? _resolveLeafCentroid(rawSecond, centroids, vec, assignMetric)
              : rawSecond);
      if (secondCId == bestCId) secondCId = -1;

      final canGrowTop = topLevelIds.length < routingCap;
      final softCap = softCapForK(max(1, leafK));

      // Distance spawn for far points only (new tiny centroid).
      if (canGrowTop && bestDist > splitDistThreshold) {
        final newCentroidId = centroids.length;
        final parentId = bestCId;
        final newNode = NghNavCentroidNode(
          centroidId: newCentroidId,
          vector: Float32List.fromList(vec),
          headPostingPageNo: -1,
          tailPostingPageNo: -1,
          postingPageNos: [],
          entryCount: 1,
          neighbors: [parentId],
        );
        centroids.add(newNode);
        newCentroids.add(newNode);
        topLevelIds.add(newCentroidId);
        leafK++;
        clusterSlots[newCentroidId] = [slot];
        clusterVectors[newCentroidId] = [vec];
        _accumulateTop2AgainstCentroid(
          vectors: normalizedVectors,
          centroid: newNode.vector,
          centroidId: newCentroidId,
          metric: assignMetric,
          bestId: bestId,
          bestD: bestD,
          secondId: secondId,
          secondD: secondD,
          from: i + 1,
        );
      } else if (bestCId < 0 || bestCId >= centroids.length) {
        continue;
      } else if (bestDist > splitDistThreshold) {
        final parentId = bestCId >= 0 && bestCId < centroids.length
            ? centroids[bestCId].parentId
            : -1;
        final canGrowUnderParent = parentId >= 0 &&
            parentId < centroids.length &&
            centroids[parentId].isCoarse &&
            centroids[parentId].childIds.length < maxChildren;
        if (canGrowUnderParent) {
          final newCentroidId = centroids.length;
          final newNode = NghNavCentroidNode(
            centroidId: newCentroidId,
            vector: Float32List.fromList(vec),
            headPostingPageNo: -1,
            tailPostingPageNo: -1,
            postingPageNos: [],
            entryCount: 1,
            neighbors: [bestCId],
            parentId: parentId,
            level: NghNavCentroidNode.levelLeaf,
          );
          centroids.add(newNode);
          newCentroids.add(newNode);
          attachSpawnedLeaf(newNode, parentId: parentId);
          leafK++;
          clusterSlots[newCentroidId] = [slot];
          clusterVectors[newCentroidId] = [vec];
        } else {
          (clusterSlots[bestCId] ??= []).add(slot);
          (clusterVectors[bestCId] ??= []).add(vec);
          centroids[bestCId].entryCount += 1;
          if (secondCId >= 0 &&
              secondCId < centroids.length &&
              (secondDist - bestDist) < 0.035 &&
              centroids[secondCId].entryCount < softCap) {
            (clusterSlots[secondCId] ??= []).add(slot);
            (clusterVectors[secondCId] ??= []).add(vec);
            centroids[secondCId].entryCount += 1;
          }
        }
      } else {
        // Primary assignment to the best centroid
        (clusterSlots[bestCId] ??= []).add(slot);
        (clusterVectors[bestCId] ??= []).add(vec);
        centroids[bestCId].entryCount += 1;

        // Boundary multi-assignment — skip already-large secondaries so we
        // do not inflate hubs that the batch-end splitter must then cut.
        if (secondCId >= 0 &&
            secondCId < centroids.length &&
            (secondDist - bestDist) < 0.035 &&
            centroids[secondCId].entryCount < softCap) {
          (clusterSlots[secondCId] ??= []).add(slot);
          (clusterVectors[secondCId] ??= []).add(vec);
          centroids[secondCId].entryCount += 1;
        }
      }
    }

    // Prefetch cluster tails so we fill existing posting pages (avoids a new
    // 16KB page per batch when the tail was evicted from cache).
    final tailRefs = <int>{};
    for (final cId in clusterSlots.keys) {
      final ref = centroids[cId].tailPostingPageNo;
      if (ref > 0) tailRefs.add(ref);
    }
    for (final ref in tailRefs) {
      if (localPostingCache.containsKey(ref)) continue;
      final ptr = NghPagePtr.fromPacked(NghDataCategory.posting, ref);
      if (dirtyPosting.containsKey(ptr)) {
        localPostingCache[ref] = dirtyPosting[ptr]!;
        continue;
      }
      final loaded = await _partitionManager.readPostingPage(
        table,
        indexUid,
        currentMeta,
        ptr.partitionNo,
        ptr.pageNo,
      );
      if (loaded != null) localPostingCache[ref] = loaded;
    }

    // Step 3: Batch allocate chained pages (grow if PK packing needs extra).
    int totalNewPagesNeeded = 0;
    for (final entry in clusterSlots.entries) {
      final cId = entry.key;
      final newSlots = entry.value;
      final centroid = centroids[cId];
      final tailRef = centroid.tailPostingPageNo;
      int existingAvailable = 0;
      if (tailRef > 0) {
        final tailPtr = NghPagePtr.fromPacked(NghDataCategory.posting, tailRef);
        final tailPage = localPostingCache[tailRef] ??
            dirtyPosting[tailPtr] ??
            _partitionManager.getCachedPostingPage(
                table.tableUid, indexUid, tailPtr.partitionNo, tailPtr.pageNo);
        if (tailPage != null) {
          existingAvailable = max(0, maxSlotsPerPage - tailPage.slots.length);
        }
      }
      final remaining = newSlots.length - existingAvailable;
      if (remaining > 0) {
        totalNewPagesNeeded +=
            (remaining + maxSlotsPerPage - 1) ~/ maxSlotsPerPage;
      }
    }

    final allocBatch = _partitionManager.allocatePagesBatchSync(
      NghDataCategory.posting,
      currentMeta,
      totalNewPagesNeeded,
    );
    currentMeta = allocBatch.$2;
    final allocatedPages = List<NghPagePtr>.from(allocBatch.$1);
    var allocatedIdx = 0;

    NghPagePtr takePostingPage() {
      if (allocatedIdx >= allocatedPages.length) {
        final extra = _partitionManager.allocatePagesBatchSync(
          NghDataCategory.posting,
          currentMeta,
          1,
        );
        currentMeta = extra.$2;
        allocatedPages.addAll(extra.$1);
      }
      return allocatedPages[allocatedIdx++];
    }

    // Step 4: Assemble posting pages in memory
    for (final entry in clusterSlots.entries) {
      final cId = entry.key;
      final newSlots = entry.value;
      final centroid = centroids[cId];

      int tailRef = centroid.tailPostingPageNo;
      NghPostingPage? tailPage;
      NghPagePtr? tailPtr;
      if (tailRef > 0) {
        tailPtr = NghPagePtr.fromPacked(NghDataCategory.posting, tailRef);
        tailPage = localPostingCache[tailRef] ??
            dirtyPosting[tailPtr] ??
            _partitionManager.getCachedPostingPage(
                table.tableUid, indexUid, tailPtr.partitionNo, tailPtr.pageNo);
      }

      int slotIndex = 0;
      if (tailPage != null && tailPtr != null) {
        slotIndex = _appendSlotsUntilFull(tailPage, newSlots, slotIndex);
        dirtyPosting[tailPtr] = tailPage;
        localPostingCache[tailRef] = tailPage;
      }

      while (slotIndex < newSlots.length) {
        final newPtr = takePostingPage();
        final newPacked = newPtr.packedRef;

        final newPage = NghPostingPage(
          centroidId: cId,
          nextPostingPageNo: -1,
          dimensions: currentMeta.dimensions,
          slots: <NghPostingSlot>[],
        );
        slotIndex = _appendSlotsUntilFull(newPage, newSlots, slotIndex);
        if (newPage.slots.isEmpty && slotIndex < newSlots.length) {
          newPage.slots.add(newSlots[slotIndex++]);
        }

        if (tailPage != null && tailPtr != null) {
          tailPage.nextPostingPageNo = newPacked;
          dirtyPosting[tailPtr] = tailPage;
          localPostingCache[tailRef] = tailPage;
        } else if (centroid.headPostingPageNo <= 0) {
          centroid.headPostingPageNo = newPacked;
        }

        centroid.addPostingPage(newPtr.pageId);
        (newDirPages[cId] ??= []).add(newPtr.pageId);
        centroid.tailPostingPageNo = newPacked;
        if (centroid.headPostingPageNo <= 0) {
          centroid.headPostingPageNo = newPacked;
        }

        dirtyPosting[newPtr] = newPage;
        localPostingCache[newPacked] = newPage;

        tailPage = newPage;
        tailPtr = newPtr;
        tailRef = newPacked;
      }
    }

    // Step 4.5: Weighted Running Average for Centroid Vectors (0 dequantize overhead)
    final dims = currentMeta.dimensions;
    for (final entry in clusterVectors.entries) {
      final cId = entry.key;
      final vecs = entry.value;
      if (vecs.isEmpty || cId >= centroids.length) continue;

      final centroid = centroids[cId];
      final oldCount = centroid.entryCount - vecs.length;

      final batchSum = Float32List(dims);
      for (final v in vecs) {
        for (int d = 0; d < dims; d++) {
          batchSum[d] += v[d];
        }
      }

      // Smooth conservative update: dampens centroid drift by blending at most 5% momentum
      final updatedVec = Float32List(dims);
      if (oldCount <= 0) {
        final inv = 1.0 / vecs.length;
        for (int d = 0; d < dims; d++) {
          updatedVec[d] = batchSum[d] * inv;
        }
      } else {
        final invBatch = 1.0 / vecs.length;
        for (int d = 0; d < dims; d++) {
          final batchMean = batchSum[d] * invBatch;
          updatedVec[d] = centroid.vector[d] * 0.95 + batchMean * 0.05;
        }
      }

      centroid.vector.setAll(
          0, isCosineMetric ? _normalizeFloat32(updatedVec) : updatedVec);
    }

    // Step 5: High-speed local neighborhood inheritance for new centroids (0 full-scan sort)
    for (final newCentroid in newCentroids) {
      final parentId =
          newCentroid.neighbors.isNotEmpty ? newCentroid.neighbors.first : 0;
      if (parentId >= 0 && parentId < centroids.length) {
        final parentNode = centroids[parentId];
        if (!parentNode.neighbors.contains(newCentroid.centroidId) &&
            parentNode.neighbors.length < 16) {
          parentNode.neighbors.add(newCentroid.centroidId);
        }
        for (final nId in parentNode.neighbors) {
          if (nId < centroids.length && nId != newCentroid.centroidId) {
            if (!newCentroid.neighbors.contains(nId) &&
                newCentroid.neighbors.length < 16) {
              newCentroid.neighbors.add(nId);
            }
          }
        }
      }
    }

    // Step 5.5: 2-means rewrite of oversized hubs so max/avg imbalance drops.
    // Overflow-spawn-without-move cannot do this; searchDepth controllability
    // depends on hubs not dominating candidate volume.
    // Cap splits per 10k flush. Raise only when a leaf already exceeded the
    // hard cap (parent-full skip used to leave 10k+ slot giants).
    var overLeafCap = false;
    for (final c in centroids) {
      if (c.isLeaf && c.entryCount > leafCap) {
        overLeafCap = true;
        break;
      }
    }
    final maxSplitsThisBatch = min(
      overLeafCap ? 12 : 4,
      max(1, (vectors.length / 2500).ceil()),
    );
    final splitBatch = await _rebalanceOversizedHubs(
      table: table,
      indexUid: indexUid,
      meta: currentMeta,
      centroids: centroids,
      dirtyPosting: dirtyPosting,
      localPostingCache: localPostingCache,
      maxSlotsPerPage: maxSlotsPerPage,
      metric: currentMeta.distanceMetric,
      isCosine: isCosineMetric,
      softCapForK: softCapForK,
      maxSplits: maxSplitsThisBatch,
      yieldBudgetMs: yieldBudgetMs,
    );
    currentMeta = splitBatch.meta;

    currentMeta = currentMeta.copyWith(
      nextNodeId: currentMeta.nextNodeId + vectors.length,
    );

    // Step 6: Persist paged nav/pdir/pkmap sidecars (or migrate legacy blob).
    final cacheKey = _cacheKey(table.tableUid, indexUid);
    final navGraphPage = NghNavGraphPage(
      dimensions: currentMeta.dimensions,
      centroids: centroids,
    );
    _navGraphCache[cacheKey] = navGraphPage;

    final rewrittenIds = splitBatch.rewrittenCentroidIds;
    for (final cId in rewrittenIds) {
      _removeCentroidSlots(cacheKey, cId);
      final slots = splitBatch.slotsByCentroid[cId];
      if (slots == null || slots.isEmpty) continue;
      final packedRef = centroids[cId].tailPostingPageNo;
      final cList = <_NghCompactSlot>[
        for (final slot in slots)
          _compactFromPostingSlot(slot, packedRef > 0 ? packedRef : 1),
      ];
      _putCentroidSlots(cacheKey, cId, cList);
    }
    final needsCompactGapFill = _refreshCompactCacheAfterInsert(
      cacheKey: cacheKey,
      centroids: centroids,
      clusterSlots: clusterSlots,
      rewrittenIds: rewrittenIds,
      newCentroidIds: {for (final c in newCentroids) c.centroidId},
      dimensions: currentMeta.dimensions,
    );

    return _finishInsertSidecars(
      table: table,
      indexUid: indexUid,
      meta: currentMeta,
      centroids: centroids,
      dirtyPosting: dirtyPosting,
      insertedCount: vectors.length,
      insertedPks: primaryKeys,
      rewrittenIds: rewrittenIds,
      newDirPages: newDirPages,
      startedEmpty: startedEmpty,
      touchedCentroidIds: {
        ...clusterSlots.keys,
        ...rewrittenIds,
      },
      navGraphPage: navGraphPage,
      needsCompactGapFill: needsCompactGapFill,
    );
  }

  int _resolveLeafCentroid(
    int id,
    List<NghNavCentroidNode> centroids,
    Float32List vec,
    VectorDistanceMetric metric,
  ) {
    var cur = id;
    for (var hop = 0; hop < _maxIvfDepth + 2; hop++) {
      if (cur < 0 || cur >= centroids.length) return 0;
      final node = centroids[cur];
      if (!node.isCoarse) return cur;
      final children = node.childIds.isNotEmpty
          ? node.childIds
          : [
              for (int i = 0; i < centroids.length; i++)
                if (centroids[i].parentId == cur) i,
            ];
      if (children.isEmpty) return cur;
      var best = cur;
      var bestD = double.infinity;
      var found = false;
      for (final ch in children) {
        if (ch < 0 || ch >= centroids.length) continue;
        found = true;
        final d = _exactDistance(vec, centroids[ch].vector, metric);
        if (d < bestD) {
          bestD = d;
          best = ch;
        }
      }
      if (!found || best == cur) return cur;
      cur = best;
    }
    return cur < 0 || cur >= centroids.length ? 0 : cur;
  }

  int _nodeIvfDepth(List<NghNavCentroidNode> centroids, int id) {
    var d = 0;
    var cur = id;
    final seen = <int>{};
    while (cur >= 0 && cur < centroids.length && seen.add(cur)) {
      final p = centroids[cur].parentId;
      if (p < 0 || p >= centroids.length || !centroids[p].isCoarse) break;
      d++;
      cur = p;
    }
    return d;
  }

  /// Split a full coarse's children with 2-means on child vectors (no posting
  /// I/O). Returns the new coarse id, or -1 if L0/parent fanout is exhausted.
  int _splitCoarseFanout({
    required List<NghNavCentroidNode> centroids,
    required int coarseId,
    required int maxChildren,
    required VectorDistanceMetric metric,
    required bool isCosine,
    required int topLevelCount,
  }) {
    if (coarseId < 0 || coarseId >= centroids.length) return -1;
    final coarse = centroids[coarseId];
    if (!coarse.isCoarse) return -1;
    final childIds = <int>[
      for (final id in coarse.childIds)
        if (id >= 0 && id < centroids.length) id,
    ];
    if (childIds.length < 4) return -1;

    final gp0 = coarse.parentId;
    var isL0 = gp0 < 0 || gp0 >= centroids.length || !centroids[gp0].isCoarse;
    if (isL0) {
      if (topLevelCount >= _maxTopLevelRouting) return -1;
    } else if (centroids[gp0].childIds.length >= maxChildren) {
      final splitGp = _splitCoarseFanout(
        centroids: centroids,
        coarseId: gp0,
        maxChildren: maxChildren,
        metric: metric,
        isCosine: isCosine,
        topLevelCount: topLevelCount,
      );
      if (splitGp < 0) return -1;
    }

    final gp = coarse.parentId;
    isL0 = gp < 0 || gp >= centroids.length || !centroids[gp].isCoarse;

    final samples = [for (final id in childIds) centroids[id].vector];
    final means = _kMeansInit(
      samples: samples,
      k: 2,
      metric: metric,
      iterations: 4,
    );
    if (means.length < 2) return -1;
    final meanA = means[0];
    final meanB = means[1];
    final a = <int>[];
    final b = <int>[];
    for (final id in childIds) {
      final dA = _exactDistance(centroids[id].vector, meanA, metric);
      final dB = _exactDistance(centroids[id].vector, meanB, metric);
      if (dA <= dB) {
        a.add(id);
      } else {
        b.add(id);
      }
    }
    if (a.length < 2 || b.length < 2) return -1;

    final newId = centroids.length;
    final parentForNew = isL0 ? -1 : gp;
    if (!isL0 &&
        parentForNew >= 0 &&
        parentForNew < centroids.length &&
        centroids[parentForNew].childIds.length >= maxChildren) {
      return -1;
    }
    final newNode = NghNavCentroidNode(
      centroidId: newId,
      vector: Float32List.fromList(isCosine ? _normalizeFloat32(meanB) : meanB),
      level: NghNavCentroidNode.levelCoarse,
      parentId: parentForNew,
      childIds: b,
      neighbors: [coarseId],
    );
    centroids.add(newNode);
    for (final id in b) {
      centroids[id].parentId = newId;
    }
    coarse.childIds
      ..clear()
      ..addAll(a);
    final centerA = isCosine ? _normalizeFloat32(meanA) : meanA;
    if (coarse.vector.length == centerA.length) {
      coarse.vector.setAll(0, centerA);
    }
    if (!coarse.neighbors.contains(newId) &&
        coarse.neighbors.length < NghPageSizer.maxNavNeighbors) {
      coarse.neighbors.add(newId);
    }
    if (!isL0 && parentForNew >= 0 && parentForNew < centroids.length) {
      final gpn = centroids[parentForNew];
      if (!gpn.childIds.contains(newId)) {
        gpn.childIds.add(newId);
      }
    }
    return newId;
  }

  Uint8List _pkMapKey(String pk) => MemComparableKey.encodeTextLex(pk);

  Future<NghInsertResult> _finishInsertSidecars({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required List<NghNavCentroidNode> centroids,
    required Map<NghPagePtr, NghPostingPage> dirtyPosting,
    required int insertedCount,
    required List<String> insertedPks,
    required Set<int> rewrittenIds,
    required Map<int, List<NghPageId>> newDirPages,
    required bool startedEmpty,
    required Set<int> touchedCentroidIds,
    required NghNavGraphPage navGraphPage,
    bool needsCompactGapFill = false,
  }) async {
    var currentMeta = meta;
    final dirtyNav = <NghPagePtr, NghNavCentroidPage>{};
    final dirtyPdir = <NghPagePtr, NghPostingDirPage>{};
    var deleteLegacy = false;

    if (!currentMeta.isPagedLayout) {
      final migrated = await _partitionManager.migrateLegacyNavGraph(
        table: table,
        indexUid: indexUid,
        meta: currentMeta,
        blob: navGraphPage,
      );
      currentMeta = migrated.meta;
      dirtyNav.addAll(migrated.nav);
      dirtyPdir.addAll(migrated.pdir);
      deleteLegacy = true;
      for (final c in centroids) {
        c.postingDirDirty = false;
      }
    } else {
      for (final c in centroids) {
        if (!c.postingDirDirty || c.isCoarse) continue;
        if (rewrittenIds.contains(c.centroidId) || c.postingDirRoot.isNone) {
          currentMeta = await _partitionManager.rewritePostingDir(
            table: table,
            indexUid: indexUid,
            meta: currentMeta,
            centroid: c,
            dirtyPdir: dirtyPdir,
          );
        } else {
          currentMeta = await _partitionManager.appendPostingDir(
            table: table,
            indexUid: indexUid,
            meta: currentMeta,
            centroid: c,
            newPages: newDirPages[c.centroidId] ?? const [],
            dirtyPdir: dirtyPdir,
          );
        }
      }
      final dirtyIds = <int>{
        ...touchedCentroidIds,
        ...rewrittenIds,
        ...newDirPages.keys,
        if (startedEmpty)
          for (int i = 0; i < centroids.length; i++) i,
      };
      for (final id in [...dirtyIds]) {
        if (id < 0 || id >= centroids.length) continue;
        dirtyIds.addAll(centroids[id].neighbors);
      }
      dirtyNav.addAll(_partitionManager.buildDirtyNavPages(
        meta: currentMeta,
        centroids: centroids,
        dirtyCentroidIds: dirtyIds.isEmpty
            ? {for (int i = 0; i < centroids.length; i++) i}
            : dirtyIds,
        diskRecordsPerPage: navGraphPage.navPackPerPage,
        rewriteAll: startedEmpty,
      ));
      navGraphPage.navPackPerPage = NghPageSizer.navCentroidsPerPage(
        _pageSize,
        currentMeta.dimensions,
      );
      currentMeta = _partitionManager.ensureNavCoverage(
        currentMeta,
        centroids.length,
      );
    }

    final pkBatch = NghPkMapBatch(meta: currentMeta);
    final insertSet = HashSet<String>.from(insertedPks);
    final collected = <String, List<NghPkLocator>>{};
    for (final e in dirtyPosting.entries) {
      final page = e.value;
      final ptr = e.key;
      final rewritten = rewrittenIds.contains(page.centroidId);
      for (int i = 0; i < page.slots.length; i++) {
        final slot = page.slots[i];
        if (slot.isDeleted) continue;
        final pk = slot.primaryKey;
        if (pk.isEmpty) continue;
        if (!insertSet.contains(pk) && !rewritten) continue;
        (collected[pk] ??= []).add(NghPkLocator(
          centroidId: page.centroidId,
          partitionNo: ptr.partitionNo,
          pageNo: ptr.pageNo,
          slotIndex: i,
        ));
      }
    }
    final pkEntries = <NghPkMapWrite>[];
    for (final e in collected.entries) {
      var locs = e.value;
      if (locs.length > 2) locs = locs.sublist(0, 2);
      pkEntries.add(NghPkMapWrite(
        key: _pkMapKey(e.key),
        locators: locs,
        mergeRewritten: rewrittenIds.isNotEmpty && !insertSet.contains(e.key),
      ));
    }
    pkEntries.sort((a, b) => MemComparableKey.compare(a.key, b.key));
    await _pkMap.upsertSorted(
      table: table,
      indexUid: indexUid,
      batch: pkBatch,
      entries: pkEntries,
      rewrittenIds: rewrittenIds,
    );

    currentMeta = pkBatch.meta.copyWith(centroidCount: centroids.length);

    return NghInsertResult(
      meta: currentMeta,
      dirtyPostingPages: dirtyPosting,
      dirtyNavPages: dirtyNav,
      dirtyPdirPages: dirtyPdir,
      dirtyPkmapPages: pkBatch.dirty,
      deleteLegacyNavGraph: deleteLegacy,
      insertedCount: insertedCount,
      needsCompactGapFill: needsCompactGapFill,
    );
  }

  /// Batch-end hub governance: 2-means split + posting rewrite for oversized
  /// clusters so [imbalance] stays near the softCap ratio (~2× fair share).
  Future<_HubSplitBatchResult> _rebalanceOversizedHubs({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required List<NghNavCentroidNode> centroids,
    required Map<NghPagePtr, NghPostingPage> dirtyPosting,
    required Map<int, NghPostingPage> localPostingCache,
    required int maxSlotsPerPage,
    required VectorDistanceMetric metric,
    required bool isCosine,
    required int Function(int k) softCapForK,
    required int maxSplits,
    int? yieldBudgetMs,
  }) async {
    final rewritten = <int>{};
    final slotsByCentroid = <int, List<NghPostingSlot>>{};
    var currentMeta = meta;
    if (centroids.length < 2 || maxSplits <= 0) {
      return _HubSplitBatchResult(
        meta: currentMeta,
        rewrittenCentroidIds: rewritten,
        slotsByCentroid: slotsByCentroid,
      );
    }

    final yc = YieldController(
      'NghGraphEngine._rebalanceOversizedHubs',
      checkInterval: 1,
      budgetMs: yieldBudgetMs,
    );

    var splitsDone = 0;
    final skippedHubs = <int>{};
    final maxChildren = NghPageSizer.maxNavInlineChildren(
      _pageSize,
      meta.dimensions,
    );
    var topLevelCount = _topLevelRoutingIds(centroids).length;
    final leafCap = _leafEntryCap(maxSlotsPerPage);
    while (splitsDone < maxSplits) {
      final y = yc.maybeYield();
      if (y != null) await y;

      var leafK = 0;
      for (final c in centroids) {
        if (c.isLeaf) leafK++;
      }
      final softCap = softCapForK(max(1, leafK));
      final splitCap = min(leafCap, max(softCap * 2, 512));

      int hubId = -1;
      var hubCount = 0;
      for (int i = 0; i < centroids.length; i++) {
        if (skippedHubs.contains(i) || centroids[i].isCoarse) continue;
        final e = centroids[i].entryCount;
        if (e > hubCount && e > splitCap) {
          hubCount = e;
          hubId = i;
        }
      }
      if (hubId < 0) break;

      final hub = centroids[hubId];
      final parentId = hub.parentId;
      final parentFull = parentId >= 0 &&
          parentId < centroids.length &&
          centroids[parentId].isCoarse &&
          centroids[parentId].childIds.length >= maxChildren;
      final isOrphanTop = parentId < 0 ||
          parentId >= centroids.length ||
          !centroids[parentId].isCoarse;
      final hubDepth = _nodeIvfDepth(centroids, hubId);
      var makeCoarse = false;
      if (parentFull) {
        if (hubDepth >= _maxIvfDepth) {
          final before = centroids.length;
          final newCoarseId = _splitCoarseFanout(
            centroids: centroids,
            coarseId: parentId,
            maxChildren: maxChildren,
            metric: metric,
            isCosine: isCosine,
            topLevelCount: topLevelCount,
          );
          if (newCoarseId < 0) {
            skippedHubs.add(hubId);
            continue;
          }
          rewritten.add(parentId);
          for (int i = before; i < centroids.length; i++) {
            rewritten.add(i);
            if (centroids[i].parentId < 0) topLevelCount++;
          }
          makeCoarse = false;
        } else {
          makeCoarse = true;
        }
      } else {
        makeCoarse = isOrphanTop && topLevelCount >= _maxTopLevelRouting;
      }

      final split = await _splitHubByTwoMeans(
        table: table,
        indexUid: indexUid,
        meta: currentMeta,
        centroids: centroids,
        hubId: hubId,
        dirtyPosting: dirtyPosting,
        localPostingCache: localPostingCache,
        maxSlotsPerPage: maxSlotsPerPage,
        metric: metric,
        isCosine: isCosine,
        makeCoarseParent: makeCoarse,
        maxChildren: maxChildren,
      );
      if (split == null) {
        skippedHubs.add(hubId);
        continue;
      }
      currentMeta = split.meta;
      rewritten.add(hubId);
      rewritten.add(split.newCentroidId);
      if (split.extraCentroidId != null) {
        rewritten.add(split.extraCentroidId!);
        slotsByCentroid[split.newCentroidId] = split.slotsA;
        slotsByCentroid[split.extraCentroidId!] = split.slotsB;
      } else {
        slotsByCentroid[hubId] = split.slotsA;
        slotsByCentroid[split.newCentroidId] = split.slotsB;
      }
      if (!makeCoarse && isOrphanTop) topLevelCount++;
      splitsDone++;
    }

    return _HubSplitBatchResult(
      meta: currentMeta,
      rewrittenCentroidIds: rewritten,
      slotsByCentroid: slotsByCentroid,
    );
  }

  /// Load live slots for [hubId], run 2-means, rewrite posting chains onto
  /// reused + newly allocated pages. Returns null if split is not worthwhile.
  Future<_HubSplitResult?> _splitHubByTwoMeans({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required List<NghNavCentroidNode> centroids,
    required int hubId,
    required Map<NghPagePtr, NghPostingPage> dirtyPosting,
    required Map<int, NghPostingPage> localPostingCache,
    required int maxSlotsPerPage,
    required VectorDistanceMetric metric,
    required bool isCosine,
    bool makeCoarseParent = false,
    int maxChildren = 256,
  }) async {
    if (hubId < 0 || hubId >= centroids.length) return null;
    final hub = centroids[hubId];
    if (hub.entryCount < 64) return null;
    // Runaway leaf (parent-full skip leftover): do not dequantize hundreds of
    // thousands of slots on the insert path. Fanout split must run first.
    if (hub.entryCount > max(16384, maxSlotsPerPage * 256)) return null;

    final liveSlots = await _loadLiveCentroidSlots(
      table: table,
      indexUid: indexUid,
      meta: meta,
      centroid: hub,
      dirtyPosting: dirtyPosting,
      localPostingCache: localPostingCache,
    );
    if (liveSlots.length < 64) return null;

    final dims = meta.dimensions;
    const maxSamples = 1024;
    final sampleStride = max(1, liveSlots.length ~/ maxSamples);
    final samples = <Float32List>[];
    for (int i = 0; i < liveSlots.length; i += sampleStride) {
      var vec = ScalarQuantizer.dequantize(
        liveSlots[i].sq8Codes,
        liveSlots[i].offset,
        liveSlots[i].scale,
      );
      if (isCosine) vec = _normalizeFloat32(vec);
      samples.add(vec);
      if (samples.length >= maxSamples) break;
    }
    if (samples.length < 2) return null;

    final means = _kMeansInit(
      samples: samples,
      k: 2,
      metric: metric,
      iterations: 3,
    );
    if (means.length < 2) return null;
    final meanA = means[0];
    final meanB = means[1];

    final slotsA = <NghPostingSlot>[];
    final slotsB = <NghPostingSlot>[];
    final sumA = Float32List(dims);
    final sumB = Float32List(dims);
    for (int i = 0; i < liveSlots.length; i++) {
      var vec = ScalarQuantizer.dequantize(
        liveSlots[i].sq8Codes,
        liveSlots[i].offset,
        liveSlots[i].scale,
      );
      if (isCosine) vec = _normalizeFloat32(vec);
      final dA = _exactDistance(vec, meanA, metric);
      final dB = _exactDistance(vec, meanB, metric);
      final clone = _clonePostingSlot(liveSlots[i]);
      if (dA <= dB) {
        slotsA.add(clone);
        for (int d = 0; d < dims; d++) {
          sumA[d] += vec[d];
        }
      } else {
        slotsB.add(clone);
        for (int d = 0; d < dims; d++) {
          sumB[d] += vec[d];
        }
      }
    }

    // Reject degenerate splits (would not reduce hub pressure).
    final minSide = min(slotsA.length, slotsB.length);
    final maxSide = max(slotsA.length, slotsB.length);
    if (minSide < 32 || minSide * 5 < maxSide) {
      return null;
    }

    Float32List centerOf(Float32List sum, int n) {
      final out = Float32List(dims);
      final inv = 1.0 / n;
      for (int d = 0; d < dims; d++) {
        out[d] = sum[d] * inv;
      }
      return isCosine ? _normalizeFloat32(out) : out;
    }

    final centerA = centerOf(sumA, slotsA.length);
    final centerB = centerOf(sumB, slotsB.length);

    final pagesNeeded =
        (slotsA.length + maxSlotsPerPage - 1) ~/ maxSlotsPerPage +
            (slotsB.length + maxSlotsPerPage - 1) ~/ maxSlotsPerPage;
    final oldRefs = <int>[
      for (final p in hub.postingPages)
        if (p.tryPack() != null) p.tryPack()!,
    ];
    if (oldRefs.isEmpty) oldRefs.addAll(hub.postingPageNos);
    final reused = <int>[];
    for (final ref in oldRefs) {
      if (ref > 0) reused.add(ref);
    }
    final needAlloc = max(0, pagesNeeded - reused.length);
    var currentMeta = meta;
    final allocated = <NghPagePtr>[];
    if (needAlloc > 0) {
      final (pages, metaAfter) = _partitionManager.allocatePagesBatchSync(
        NghDataCategory.posting,
        currentMeta,
        needAlloc,
      );
      currentMeta = metaAfter;
      allocated.addAll(pages);
    }

    final pagePool = <NghPagePtr>[
      for (final ref in reused)
        NghPagePtr.fromPacked(NghDataCategory.posting, ref),
      ...allocated,
    ];
    var poolIdx = 0;

    (int head, int tail, List<int> refs) writeChain(
      int centroidId,
      List<NghPostingSlot> slots,
    ) {
      if (slots.isEmpty) return (-1, -1, <int>[]);
      var head = -1;
      var tail = -1;
      final refs = <int>[];
      var offset = 0;
      NghPostingPage? prevPage;
      NghPagePtr? prevPtr;
      while (offset < slots.length) {
        final take = min(maxSlotsPerPage, slots.length - offset);
        final chunk = slots.sublist(offset, offset + take);
        offset += take;
        final ptr = pagePool[poolIdx++];
        final packed = ptr.packedRef;
        final page = NghPostingPage(
          centroidId: centroidId,
          nextPostingPageNo: -1,
          dimensions: dims,
          slots: chunk,
        );
        if (prevPage != null && prevPtr != null) {
          prevPage.nextPostingPageNo = packed;
          dirtyPosting[prevPtr] = prevPage;
          localPostingCache[prevPtr.packedRef] = prevPage;
        }
        dirtyPosting[ptr] = page;
        localPostingCache[packed] = page;
        if (head <= 0) head = packed;
        tail = packed;
        refs.add(packed);
        prevPage = page;
        prevPtr = ptr;
      }
      return (head, tail, refs);
    }

    final newCentroidId = centroids.length;
    final chainAId = makeCoarseParent ? newCentroidId : hubId;
    final chainBId = makeCoarseParent ? newCentroidId + 1 : newCentroidId;
    final chainA = writeChain(chainAId, slotsA);
    final chainB = writeChain(chainBId, slotsB);

    // Drop unused old pages from the hub's chain (left unreferenced; content
    // overwritten when pool reused). Clear any leftover pool pages.
    while (poolIdx < pagePool.length) {
      final ptr = pagePool[poolIdx++];
      final empty = NghPostingPage(
        centroidId: hubId,
        nextPostingPageNo: -1,
        dimensions: dims,
        slots: <NghPostingSlot>[],
      );
      dirtyPosting[ptr] = empty;
      localPostingCache[ptr.packedRef] = empty;
    }

    hub.vector.setAll(0, centerA);
    if (makeCoarseParent) {
      final leafAId = newCentroidId;
      final leafBId = newCentroidId + 1;
      hub.level = NghNavCentroidNode.levelCoarse;
      hub.entryCount = 0;
      hub.headPostingPageNo = -1;
      hub.tailPostingPageNo = -1;
      hub.replacePostingPages(const []);
      hub.postingDirRoot = NghPageId.none;
      hub.postingDirTail = NghPageId.none;
      hub.childIds
        ..clear()
        ..add(leafAId)
        ..add(leafBId);
      final leafA = NghNavCentroidNode(
        centroidId: leafAId,
        vector: Float32List.fromList(centerA),
        headPostingPageNo: chainA.$1,
        tailPostingPageNo: chainA.$2,
        postingPageNos: List<int>.from(chainA.$3),
        entryCount: slotsA.length,
        neighbors: [hubId],
        parentId: hubId,
        level: NghNavCentroidNode.levelLeaf,
        postingDirDirty: true,
      );
      final leafB = NghNavCentroidNode(
        centroidId: leafBId,
        vector: Float32List.fromList(centerB),
        headPostingPageNo: chainB.$1,
        tailPostingPageNo: chainB.$2,
        postingPageNos: List<int>.from(chainB.$3),
        entryCount: slotsB.length,
        neighbors: [hubId],
        parentId: hubId,
        level: NghNavCentroidNode.levelLeaf,
        postingDirDirty: true,
      );
      centroids.add(leafA);
      centroids.add(leafB);
      return _HubSplitResult(
        meta: currentMeta,
        newCentroidId: leafAId,
        extraCentroidId: leafBId,
        slotsA: slotsA,
        slotsB: slotsB,
      );
    }

    hub.entryCount = slotsA.length;
    hub.headPostingPageNo = chainA.$1;
    hub.tailPostingPageNo = chainA.$2;
    hub.replacePostingPages([
      for (final p in chainA.$3)
        if (p > 0) NghPageId.fromPacked(p),
    ]);

    final newNode = NghNavCentroidNode(
      centroidId: newCentroidId,
      vector: Float32List.fromList(centerB),
      headPostingPageNo: chainB.$1,
      tailPostingPageNo: chainB.$2,
      postingPageNos: List<int>.from(chainB.$3),
      entryCount: slotsB.length,
      neighbors: [hubId],
      parentId: hub.parentId,
      postingDirDirty: true,
    );
    centroids.add(newNode);
    if (hub.parentId >= 0 && hub.parentId < centroids.length) {
      final parent = centroids[hub.parentId];
      if (parent.isCoarse &&
          parent.childIds.length < maxChildren &&
          !parent.childIds.contains(newCentroidId)) {
        parent.childIds.add(newCentroidId);
      }
    }

    if (!hub.neighbors.contains(newCentroidId) && hub.neighbors.length < 16) {
      hub.neighbors.add(newCentroidId);
    }
    for (final nId in hub.neighbors) {
      if (nId == newCentroidId || nId >= centroids.length) continue;
      if (!newNode.neighbors.contains(nId) && newNode.neighbors.length < 16) {
        newNode.neighbors.add(nId);
      }
      final peer = centroids[nId];
      if (!peer.neighbors.contains(newCentroidId) &&
          peer.neighbors.length < 16) {
        peer.neighbors.add(newCentroidId);
      }
    }

    return _HubSplitResult(
      meta: currentMeta,
      newCentroidId: newCentroidId,
      slotsA: slotsA,
      slotsB: slotsB,
    );
  }

  Future<List<NghPostingSlot>> _loadLiveCentroidSlots({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required NghNavCentroidNode centroid,
    required Map<NghPagePtr, NghPostingPage> dirtyPosting,
    required Map<int, NghPostingPage> localPostingCache,
  }) async {
    if (centroid.postingPages.isEmpty && !centroid.postingDirRoot.isNone) {
      await _partitionManager.hydratePostingDirs(table, indexUid, [centroid]);
    }
    final live = <NghPostingSlot>[];
    final ids = centroid.postingPages.isNotEmpty
        ? List<NghPageId>.from(centroid.postingPages)
        : [
            for (final packed in centroid.postingPageNos)
              if (packed > 0) NghPageId.fromPacked(packed),
            if (centroid.postingPages.isEmpty &&
                centroid.headPostingPageNo > 0 &&
                centroid.postingPageNos.isEmpty)
              NghPageId.fromPacked(centroid.headPostingPageNo),
          ];
    if (ids.isEmpty) return live;

    final missing = <NghPageId>[];
    for (final id in ids) {
      if (id.isNone) continue;
      final packed = id.tryPack();
      if (packed != null && packed > 0) {
        final local = localPostingCache[packed];
        if (local != null) {
          for (final s in local.slots) {
            if (!s.isDeleted) live.add(s);
          }
          continue;
        }
      }
      final ptr = NghPagePtr.fromPageId(NghDataCategory.posting, id);
      final dirty = dirtyPosting[ptr];
      if (dirty != null) {
        if (packed != null && packed > 0) localPostingCache[packed] = dirty;
        for (final s in dirty.slots) {
          if (!s.isDeleted) live.add(s);
        }
        continue;
      }
      missing.add(id);
    }

    if (missing.isNotEmpty) {
      final loaded = await _partitionManager.readPostingPagesByIds(
        table,
        indexUid,
        meta,
        missing,
      );
      for (final item in loaded) {
        final ptr = NghPagePtr.fromPageId(NghDataCategory.posting, item.id);
        dirtyPosting.putIfAbsent(ptr, () => item.page);
        final packed = item.id.tryPack();
        if (packed != null && packed > 0) {
          localPostingCache[packed] = item.page;
        }
        for (final s in item.page.slots) {
          if (!s.isDeleted) live.add(s);
        }
      }
    }
    return live;
  }

  NghPostingSlot _clonePostingSlot(NghPostingSlot s) {
    final pkBytes = s.primaryKeyBytes;
    return NghPostingSlot(
      nodeId: s.nodeId,
      flags: s.flags,
      primaryKey: pkBytes == null ? s.primaryKey : null,
      primaryKeyBytes: pkBytes != null ? Uint8List.fromList(pkBytes) : null,
      sq8Codes: Uint8List.fromList(s.sq8Codes),
      offset: s.offset,
      scale: s.scale,
      squaredNorm: s.squaredNorm,
    );
  }

  // =====================================================================
  // Deletion -- Tombstone in Posting Pages
  // =====================================================================

  /// Mark posting slots deleted via PK locator (never a full-cluster scan).
  Future<NghDeleteResult> deleteBatch({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required List<String> primaryKeys,
  }) async {
    if (primaryKeys.isEmpty) {
      return NghDeleteResult(meta: meta, deletedCount: 0);
    }

    final navGraph = await _getOrLoadNavGraph(table, indexUid, meta);
    var currentMeta = meta;
    final dirtyPosting = <NghPagePtr, NghPostingPage>{};
    final dirtyNavIds = <int>{};
    final pkBatch = NghPkMapBatch(meta: currentMeta);
    final unresolved = <String>[];
    final cacheKey = _cacheKey(table.tableUid, indexUid);
    var deleted = 0;

    Future<NghPostingPage?> loadPage(NghPkLocator loc) async {
      final ptr =
          NghPagePtr(NghDataCategory.posting, loc.partitionNo, loc.pageNo);
      final existing = dirtyPosting[ptr];
      if (existing != null) return existing;
      return _partitionManager.readPostingPage(
        table,
        indexUid,
        currentMeta,
        loc.partitionNo,
        loc.pageNo,
      );
    }

    for (final pk in primaryKeys) {
      if (pk.isEmpty) continue;
      var locs = const <NghPkLocator>[];
      if (!pkBatch.meta.pkmapRootIsNull) {
        locs = await _pkMap.lookup(
          table: table,
          indexUid: indexUid,
          batch: pkBatch,
          key: _pkMapKey(pk),
        );
      }
      if (locs.isEmpty) {
        if (!currentMeta.hasPkLocator) unresolved.add(pk);
        continue;
      }
      for (final loc in locs) {
        final page = await loadPage(loc);
        if (page == null) continue;
        var hit = false;
        if (loc.slotIndex >= 0 && loc.slotIndex < page.slots.length) {
          final slot = page.slots[loc.slotIndex];
          if (!slot.isDeleted && slot.primaryKey == pk) {
            slot.flags |= 0x01;
            hit = true;
          }
        }
        if (!hit) {
          for (final slot in page.slots) {
            if (!slot.isDeleted && slot.primaryKey == pk) {
              slot.flags |= 0x01;
              hit = true;
              break;
            }
          }
        }
        if (!hit) continue;
        deleted++;
        dirtyPosting[NghPagePtr(
            NghDataCategory.posting, loc.partitionNo, loc.pageNo)] = page;
        if (navGraph != null &&
            loc.centroidId >= 0 &&
            loc.centroidId < navGraph.centroids.length) {
          final c = navGraph.centroids[loc.centroidId];
          c.entryCount = max(0, c.entryCount - 1);
          dirtyNavIds.add(loc.centroidId);
        }
        final ck = _centroidCacheKey(cacheKey, loc.centroidId);
        final cached = _inMemoryClusterCache[ck];
        if (cached != null) {
          for (final slot in cached) {
            if (utf8.decode(slot.primaryKeyBytes) == pk) {
              slot.flags |= 0x01;
            }
          }
        }
      }
      await _pkMap.remove(
        table: table,
        indexUid: indexUid,
        batch: pkBatch,
        key: _pkMapKey(pk),
      );
    }

    currentMeta = pkBatch.meta;
    var dirtyNav = <NghPagePtr, NghNavCentroidPage>{};
    var dirtyPdir = <NghPagePtr, NghPostingDirPage>{};
    var deleteLegacy = false;
    if (navGraph != null && deleted > 0 && !currentMeta.isPagedLayout) {
      final migrated = await _partitionManager.migrateLegacyNavGraph(
        table: table,
        indexUid: indexUid,
        meta: currentMeta,
        blob: navGraph,
      );
      currentMeta = migrated.meta;
      dirtyNav = migrated.nav;
      dirtyPdir = migrated.pdir;
      deleteLegacy = true;
    } else if (navGraph != null &&
        dirtyNavIds.isNotEmpty &&
        currentMeta.isPagedLayout) {
      dirtyNav = _partitionManager.buildDirtyNavPages(
        meta: currentMeta,
        centroids: navGraph.centroids,
        dirtyCentroidIds: dirtyNavIds,
        diskRecordsPerPage: navGraph.navPackPerPage,
      );
      navGraph.navPackPerPage = NghPageSizer.navCentroidsPerPage(
        _pageSize,
        currentMeta.dimensions,
      );
    }
    if (navGraph != null) {
      _navGraphCache[cacheKey] = navGraph;
    }

    return NghDeleteResult(
      meta: currentMeta,
      dirtyPostingPages: dirtyPosting,
      dirtyNavPages: dirtyNav,
      dirtyPdirPages: dirtyPdir,
      dirtyPkmapPages: pkBatch.dirty,
      deleteLegacyNavGraph: deleteLegacy,
      deletedCount: deleted,
      unresolvedPks: unresolved,
    );
  }

  // =====================================================================
  // Synchronous Navigating Graph Routing & Soft-Margin Assignment
  // =====================================================================

  /// Prefetch and cache the full paged nav graph (requires [meta] page counts).
  Future<void> prefetchNavGraph(
    TableContext table,
    IndexUid indexUid, {
    NghIndexMeta? meta,
  }) async {
    final key = _cacheKey(table.tableUid, indexUid);
    final cached = _navGraphCache[key];
    if (cached != null &&
        (meta == null ||
            meta.centroidCount <= 0 ||
            cached.centroids.length >= meta.centroidCount)) {
      return;
    }
    try {
      final loaded = await _partitionManager.readNavGraph(
        table,
        indexUid,
        meta: meta,
      );
      if (loaded == null || loaded.centroids.isEmpty) return;
      if (cached != null && cached.centroids.length > loaded.centroids.length) {
        return;
      }
      _navGraphCache[key] = loaded;
    } catch (_) {}
  }

  Future<NghNavGraphPage?> _getOrLoadNavGraph(
    TableContext table,
    IndexUid indexUid,
    NghIndexMeta meta,
  ) async {
    final key = _cacheKey(table.tableUid, indexUid);
    final cached = _navGraphCache[key];
    if (cached != null &&
        (meta.centroidCount <= 0 ||
            cached.centroids.length >= meta.centroidCount)) {
      return cached;
    }

    final loaded =
        await _partitionManager.readNavGraph(table, indexUid, meta: meta);
    if (loaded != null && loaded.centroids.isNotEmpty) {
      if (cached != null && cached.centroids.length > loaded.centroids.length) {
        return cached;
      }
      _navGraphCache[key] = loaded;
      return loaded;
    }
    return cached;
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

  /// Fast synchronous Mini-Batch K-Means initialization on sample vectors (0 I/O, <8ms).
  List<Float32List> _kMeansInit({
    required List<Float32List> samples,
    required int k,
    required VectorDistanceMetric metric,
    int iterations = 5,
  }) {
    final seeds = _kMeansPlusPlusInit(samples: samples, k: k, metric: metric);
    if (seeds.length <= 1 || samples.length <= seeds.length) return seeds;

    final n = samples.length;
    final numCentroids = seeds.length;
    final dims = samples[0].length;
    final isCosine = metric == VectorDistanceMetric.cosine;

    final centroids = List<Float32List>.generate(
      numCentroids,
      (i) => Float32List.fromList(seeds[i]),
      growable: false,
    );

    final clusterSums = List<Float32List>.generate(
      numCentroids,
      (_) => Float32List(dims),
      growable: false,
    );
    final clusterCounts = Int32List(numCentroids);

    for (int iter = 0; iter < iterations; iter++) {
      for (int c = 0; c < numCentroids; c++) {
        clusterSums[c].fillRange(0, dims, 0.0);
        clusterCounts[c] = 0;
      }

      for (int i = 0; i < n; i++) {
        final sample = samples[i];
        int bestC = 0;
        double bestDist = double.infinity;

        for (int c = 0; c < numCentroids; c++) {
          final d = _exactDistance(sample, centroids[c], metric);
          if (d < bestDist) {
            bestDist = d;
            bestC = c;
          }
        }

        clusterCounts[bestC]++;
        final sum = clusterSums[bestC];
        for (int d = 0; d < dims; d++) {
          sum[d] += sample[d];
        }
      }

      for (int c = 0; c < numCentroids; c++) {
        if (clusterCounts[c] == 0) continue;
        final inv = 1.0 / clusterCounts[c];
        final sum = clusterSums[c];
        final center = centroids[c];
        for (int d = 0; d < dims; d++) {
          center[d] = sum[d] * inv;
        }
        if (isCosine) {
          final norm = _normalizeFloat32(center);
          center.setAll(0, norm);
        }
      }
    }

    return centroids;
  }

  /// Fast synchronous K-Means++ initialization on sample vectors (0 I/O, <3ms).
  List<Float32List> _kMeansPlusPlusInit({
    required List<Float32List> samples,
    required int k,
    required VectorDistanceMetric metric,
  }) {
    final n = samples.length;
    if (n == 0 || k <= 0) return const [];
    final actualK = min(k, n);
    final centroids = <Float32List>[Float32List.fromList(samples[0])];
    if (actualK == 1) return centroids;

    final minDists = Float64List(n);
    for (int i = 0; i < n; i++) {
      minDists[i] = double.infinity;
    }

    final rng = Random(42);

    for (int c = 1; c < actualK; c++) {
      final prevCentroid = centroids.last;
      double totalDist = 0;
      for (int i = 0; i < n; i++) {
        final d = _exactDistance(samples[i], prevCentroid, metric);
        if (d < minDists[i]) {
          minDists[i] = d;
        }
        totalDist += minDists[i];
      }

      int selectedIdx = n - 1;
      if (totalDist > 0) {
        double threshold = rng.nextDouble() * totalDist;
        for (int i = 0; i < n; i++) {
          threshold -= minDists[i];
          if (threshold <= 0) {
            selectedIdx = i;
            break;
          }
        }
      }
      centroids.add(Float32List.fromList(samples[selectedIdx]));
    }

    return centroids;
  }

  /// Rewrite posting pages whose tombstone ratio is high; free empty pages.
  Future<NghCompactResult> compactTombstones({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    int maxVisitedPages = 100,
  }) async {
    final navGraph = await _getOrLoadNavGraph(table, indexUid, meta);
    if (navGraph == null || navGraph.centroids.isEmpty) {
      return NghCompactResult(meta: meta, compactedCount: 0);
    }

    var currentMeta = meta;
    final dirtyPosting = <NghPagePtr, NghPostingPage>{};
    final dirtyPdir = <NghPagePtr, NghPostingDirPage>{};
    final freed = <NghPagePtr>[];
    final dirtyNavIds = <int>{};
    final pkBatch = NghPkMapBatch(meta: currentMeta);
    var compacted = 0;
    var visited = 0;
    const minGarbageRatio = 0.35;

    for (final c in navGraph.centroids) {
      if (visited >= maxVisitedPages) break;
      if (c.isCoarse || c.postingPages.isEmpty) continue;
      final livePages = <NghPageId>[];
      var dirChanged = false;
      for (final pid in c.postingPages) {
        if (visited >= maxVisitedPages) {
          livePages.add(pid);
          continue;
        }
        visited++;
        final ptr = NghPagePtr.fromPageId(NghDataCategory.posting, pid);
        final page = dirtyPosting[ptr] ??
            await _partitionManager.readPostingPage(
              table,
              indexUid,
              currentMeta,
              pid.partitionNo,
              pid.pageNo,
            );
        if (page == null) {
          livePages.add(pid);
          continue;
        }
        final dead = page.slots.where((s) => s.isDeleted).length;
        if (page.slots.isEmpty || dead / page.slots.length < minGarbageRatio) {
          livePages.add(pid);
          continue;
        }
        final live = [
          for (final s in page.slots)
            if (!s.isDeleted) s
        ];
        compacted += page.slots.length - live.length;
        if (live.isEmpty) {
          freed.add(ptr);
          dirChanged = true;
          continue;
        }
        dirtyPosting[ptr] = NghPostingPage(
          centroidId: page.centroidId,
          nextPostingPageNo: page.nextPostingPageNo,
          dimensions: page.dimensions,
          slots: live,
        );
        livePages.add(pid);
        for (int i = 0; i < live.length; i++) {
          final pk = live[i].primaryKey;
          if (pk.isEmpty) continue;
          final old = await _pkMap.lookup(
            table: table,
            indexUid: indexUid,
            batch: pkBatch,
            key: _pkMapKey(pk),
          );
          final updated = <NghPkLocator>[];
          var replaced = false;
          for (final l in old) {
            if (l.partitionNo == pid.partitionNo && l.pageNo == pid.pageNo) {
              updated.add(NghPkLocator(
                centroidId: l.centroidId,
                partitionNo: l.partitionNo,
                pageNo: l.pageNo,
                slotIndex: i,
              ));
              replaced = true;
            } else {
              updated.add(l);
            }
          }
          if (!replaced) {
            updated.add(NghPkLocator(
              centroidId: c.centroidId,
              partitionNo: pid.partitionNo,
              pageNo: pid.pageNo,
              slotIndex: i,
            ));
          }
          await _pkMap.upsert(
            table: table,
            indexUid: indexUid,
            batch: pkBatch,
            key: _pkMapKey(pk),
            locators: updated.length > 2 ? updated.sublist(0, 2) : updated,
          );
        }
      }
      if (dirChanged) {
        c.replacePostingPages(livePages);
        currentMeta = await _partitionManager.rewritePostingDir(
          table: table,
          indexUid: indexUid,
          meta: currentMeta,
          centroid: c,
          dirtyPdir: dirtyPdir,
        );
        dirtyNavIds.add(c.centroidId);
      }
    }

    currentMeta =
        pkBatch.meta.copyWith(centroidCount: navGraph.centroids.length);
    final dirtyNav = currentMeta.isPagedLayout
        ? _partitionManager.buildDirtyNavPages(
            meta: currentMeta,
            centroids: navGraph.centroids,
            dirtyCentroidIds: dirtyNavIds,
            diskRecordsPerPage: navGraph.navPackPerPage,
          )
        : <NghPagePtr, NghNavCentroidPage>{};
    if (currentMeta.isPagedLayout) {
      navGraph.navPackPerPage = NghPageSizer.navCentroidsPerPage(
        _pageSize,
        currentMeta.dimensions,
      );
    }

    return NghCompactResult(
      meta: currentMeta,
      dirtyPostingPages: dirtyPosting,
      dirtyNavPages: dirtyNav,
      dirtyPdirPages: dirtyPdir,
      dirtyPkmapPages: pkBatch.dirty,
      freePostingPages: freed,
      compactedCount: compacted,
    );
  }

  /// Scan posting pages to fill the PK locator tree. Tombstones pending-delete
  /// PKs as they are encountered. Never falls back to a full delete scan.
  Future<NghInsertResult> backfillPkLocator({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required Set<String> pendingDeletePks,
    int maxPages = 64,
  }) async {
    if (meta.hasPkLocator) {
      return NghInsertResult(meta: meta, insertedCount: 0);
    }

    var currentMeta = meta;
    final pkBatch = NghPkMapBatch(meta: currentMeta);
    final dirtyPosting = <NghPagePtr, NghPostingPage>{};
    var part = currentMeta.pkBackfillPartition;
    var page = currentMeta.pkBackfillPage < NghIndexMeta.firstDataPageNo
        ? NghIndexMeta.firstDataPageNo
        : currentMeta.pkBackfillPage;
    var visited = 0;
    var tombstoned = 0;
    final partLimit = max(1, currentMeta.postingPartitionCount);

    while (visited < maxPages && part < partLimit) {
      final pageCount = await _partitionManager.postingFilePageCount(
        table,
        indexUid,
        part,
      );
      if (pageCount <= NghIndexMeta.firstDataPageNo) {
        part++;
        page = NghIndexMeta.firstDataPageNo;
        continue;
      }
      while (page < pageCount && visited < maxPages) {
        visited++;
        final loaded = await _partitionManager.readPostingPage(
          table,
          indexUid,
          currentMeta,
          part,
          page,
        );
        final pgNo = page;
        page++;
        if (loaded == null) continue;
        var modified = false;
        for (int i = 0; i < loaded.slots.length; i++) {
          final slot = loaded.slots[i];
          final pk = slot.primaryKey;
          if (pk.isEmpty) continue;
          if (pendingDeletePks.contains(pk)) {
            if (!slot.isDeleted) {
              slot.flags |= 0x01;
              modified = true;
              tombstoned++;
            }
            continue;
          }
          if (slot.isDeleted) continue;
          final old = await _pkMap.lookup(
            table: table,
            indexUid: indexUid,
            batch: pkBatch,
            key: _pkMapKey(pk),
          );
          final loc = NghPkLocator(
            centroidId: loaded.centroidId,
            partitionNo: part,
            pageNo: pgNo,
            slotIndex: i,
          );
          final merged = <NghPkLocator>[
            for (final l in old)
              if (!(l.partitionNo == part && l.pageNo == pgNo)) l,
            loc,
          ];
          await _pkMap.upsert(
            table: table,
            indexUid: indexUid,
            batch: pkBatch,
            key: _pkMapKey(pk),
            locators: merged.length > 2 ? merged.sublist(0, 2) : merged,
          );
        }
        if (modified) {
          dirtyPosting[NghPagePtr(NghDataCategory.posting, part, pgNo)] =
              loaded;
        }
      }
      if (page >= pageCount) {
        part++;
        page = NghIndexMeta.firstDataPageNo;
      }
    }

    final done = part >= partLimit;
    currentMeta = pkBatch.meta.copyWith(
      pkBackfillPartition: part,
      pkBackfillPage: page,
      hasPkLocator: done ? true : currentMeta.hasPkLocator,
    );

    return NghInsertResult(
      meta: currentMeta,
      dirtyPostingPages: dirtyPosting,
      dirtyPkmapPages: pkBatch.dirty,
      insertedCount: 0,
      tombstonedCount: tombstoned,
    );
  }
}

/// Outcome of one batch-end hub rebalance pass.
class _HubSplitBatchResult {
  final NghIndexMeta meta;
  final Set<int> rewrittenCentroidIds;
  final Map<int, List<NghPostingSlot>> slotsByCentroid;

  _HubSplitBatchResult({
    required this.meta,
    required this.rewrittenCentroidIds,
    required this.slotsByCentroid,
  });
}

/// Outcome of a single hub 2-means split.
class _HubSplitResult {
  final NghIndexMeta meta;
  final int newCentroidId;
  final int? extraCentroidId;
  final List<NghPostingSlot> slotsA;
  final List<NghPostingSlot> slotsB;

  _HubSplitResult({
    required this.meta,
    required this.newCentroidId,
    this.extraCentroidId,
    required this.slotsA,
    required this.slotsB,
  });
}

// ============================================================================
// Result Types
// ============================================================================

/// Result of a batch insertion operation.
class NghInsertResult {
  final NghIndexMeta meta;
  final Map<NghPagePtr, NghPostingPage> dirtyPostingPages;
  final Map<NghPagePtr, NghNavCentroidPage> dirtyNavPages;
  final Map<NghPagePtr, NghPostingDirPage> dirtyPdirPages;
  final Map<NghPagePtr, NghPkMapDirtyPage> dirtyPkmapPages;
  final bool deleteLegacyNavGraph;
  final int insertedCount;
  final int tombstonedCount;

  /// True when this flush should load *missing* compact clusters after persist.
  ///
  /// Not "index fits budget" — that would re-prewarm every small-corpus flush.
  final bool needsCompactGapFill;

  NghInsertResult({
    required this.meta,
    this.dirtyPostingPages = const {},
    this.dirtyNavPages = const {},
    this.dirtyPdirPages = const {},
    this.dirtyPkmapPages = const {},
    this.deleteLegacyNavGraph = false,
    required this.insertedCount,
    this.tombstonedCount = 0,
    this.needsCompactGapFill = false,
  });
}

/// Result of a batch deletion operation.
class NghDeleteResult {
  final NghIndexMeta meta;
  final Map<NghPagePtr, NghPostingPage> dirtyPostingPages;
  final Map<NghPagePtr, NghNavCentroidPage> dirtyNavPages;
  final Map<NghPagePtr, NghPostingDirPage> dirtyPdirPages;
  final Map<NghPagePtr, NghPkMapDirtyPage> dirtyPkmapPages;
  final bool deleteLegacyNavGraph;
  final int deletedCount;
  final List<String> unresolvedPks;

  NghDeleteResult({
    required this.meta,
    this.dirtyPostingPages = const {},
    this.dirtyNavPages = const {},
    this.dirtyPdirPages = const {},
    this.dirtyPkmapPages = const {},
    this.deleteLegacyNavGraph = false,
    required this.deletedCount,
    this.unresolvedPks = const [],
  });
}

/// Result of a background tombstone compaction.
class NghCompactResult {
  final NghIndexMeta meta;
  final Map<NghPagePtr, NghPostingPage> dirtyPostingPages;
  final Map<NghPagePtr, NghNavCentroidPage> dirtyNavPages;
  final Map<NghPagePtr, NghPostingDirPage> dirtyPdirPages;
  final Map<NghPagePtr, NghPkMapDirtyPage> dirtyPkmapPages;
  final List<NghPagePtr> freePostingPages;
  final int compactedCount;

  NghCompactResult({
    required this.meta,
    this.dirtyPostingPages = const {},
    this.dirtyNavPages = const {},
    this.dirtyPdirPages = const {},
    this.dirtyPkmapPages = const {},
    this.freePostingPages = const [],
    required this.compactedCount,
  });
}

// ============================================================================
// Fixed-Size Binary Heap -- Zero-GC Search Primitive
// ============================================================================

/// Max-heap of slots by distance for coarse ANN prefilter.
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
