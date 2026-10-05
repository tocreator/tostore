import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../handler/memcomparable.dart';
import '../model/db_exception.dart';
import '../model/ngh_index_meta.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/table_context.dart';
import '../model/table_identity.dart';
import '../model/table_schema.dart';
import 'ngh_page.dart';
import 'ngh_partition_manager.dart';
import 'ngh_pk_map.dart';
import 'tree_cache.dart';
import 'vector_quantizer.dart';
import 'yield_controller.dart';

// ============================================================================
// NGH Graph Engine
//
// Responsibilities:
//   1. L0-resident + budgeted L1 Centroid B+Tree routing (microsecond hot path
//      when probed L1/leaves are cached; never full L1 inventory residency)
//   2. High-speed physical-leaf search via inlined SQ8 vector slots (0 random secondary I/O)
//   3. Streaming incremental insert with angle-aware multi-assignment
//   4. Hub governance: softCap (~1.75× fair share) + batch-end 2-means leaf rewrite
//   5. Tombstone deletion and compaction
//
// Scale lock (identity recall + tens of billions):
//   - Insert and search share one router: exact among L0 roots (page-fit,
//     typically ≤79 on 16KB / ≤256 hard cap), then exact among children of
//     ONE nav page per hop (fanout ≤64).
//   - Nav growth is SPLIT + mid promotion + optional L0 far-spawn /
//     heavy-root-split. One page = one tree node. Never rewrite leaves to
//     fix routing.
//   - Probe cost is O(L0 + hops×64×beam + wantLeaves×slots) — independent of N.
//     wantLeaves: ~14 / 28 / 44 at depth 1 / 50 / 100; depth>100 continues the
//     same 50→100 Δlists/Δdepth up to abs ≤256 (escape hatch). NEVER auto-raise
//     scored leaves with N — that is the recall↔throughput cliff at 1e7+.
//   - searchDepth has no hard max. Anchors: 1→91% (±5), 50→95% (±3 strict),
//     100→98% (±5; 99% is not the interactive ceiling — too expensive).
//     depth>100 keeps buying recall budget at the 50→100 rate until abs cap.
//   - Engine never rewrites online monolithic nav_graph.ngh in place. New writes
//     are paged Centroid nav tree + leaf partitions; migrate is one-shot from
//     the production big-file layout. Leaf slot layout stays frozen.
//   - Nav page wire version stays 2
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

// ----------------------------------------------------------------------------
// Candidate Min-Heap for Zero Heap GC
// ----------------------------------------------------------------------------
final class CandidateMinHeapIP {
  /// Node ids as Dart [int] — must not truncate wide leaf nodeIds.
  final List<int> ids;
  final Float64List scores;
  int size = 0;
  final int capacity;
  double minScore = -1e9;

  CandidateMinHeapIP(this.capacity)
      : ids = List<int>.filled(capacity + 1, 0),
        scores = Float64List(capacity + 1);

  @pragma('vm:prefer-inline')
  void clear() {
    size = 0;
    minScore = -1e9;
  }

  @pragma('vm:prefer-inline')
  void push(int id, double score) {
    if (size >= capacity) {
      if (score <= scores[1]) return;
      var i = 1;
      var child = 2;
      while (child <= size) {
        if (child < size && scores[child + 1] < scores[child]) {
          child++;
        }
        if (score <= scores[child]) break;
        ids[i] = ids[child];
        scores[i] = scores[child];
        i = child;
        child = i << 1;
      }
      ids[i] = id;
      scores[i] = score;
      minScore = scores[1];
      return;
    }

    size++;
    var i = size;
    var parent = i >> 1;
    while (i > 1 && scores[parent] > score) {
      ids[i] = ids[parent];
      scores[i] = scores[parent];
      i = parent;
      parent = i >> 1;
    }
    ids[i] = id;
    scores[i] = score;
    if (size == capacity) {
      minScore = scores[1];
    }
  }
}

// Streaming Slot Heap for Level 2A Pruning
final class SlotCandidateHeap {
  final List<NghLeafSlot?> slots;
  final Float64List scores;
  int size = 0;
  int capacity;
  final int maxCapacity;
  double minScore = -1e9;

  SlotCandidateHeap(this.maxCapacity)
      : capacity = maxCapacity,
        slots = List<NghLeafSlot?>.filled(maxCapacity + 1, null),
        scores = Float64List(maxCapacity + 1);

  @pragma('vm:prefer-inline')
  void reset(int limit) {
    capacity = limit.clamp(1, maxCapacity);
    size = 0;
    minScore = -1e9;
  }

  @pragma('vm:prefer-inline')
  void clear() {
    size = 0;
    minScore = -1e9;
  }

  @pragma('vm:prefer-inline')
  void push(NghLeafSlot slot, double score) {
    if (size >= capacity) {
      if (score <= scores[1]) return;
      var i = 1;
      var child = 2;
      while (child <= size) {
        if (child < size && scores[child + 1] < scores[child]) {
          child++;
        }
        if (score <= scores[child]) break;
        slots[i] = slots[child];
        scores[i] = scores[child];
        i = child;
        child = i << 1;
      }
      slots[i] = slot;
      scores[i] = score;
      minScore = scores[1];
      return;
    }

    size++;
    var i = size;
    var parent = i >> 1;
    while (i > 1 && scores[parent] > score) {
      slots[i] = slots[parent];
      scores[i] = scores[parent];
      i = parent;
      parent = i >> 1;
    }
    slots[i] = slot;
    scores[i] = score;
    if (size == capacity) {
      minScore = scores[1];
    }
  }
}

// Streaming Branch Heap for Level 1 Pruning
final class BranchMinHeap {
  final List<CentroidBranchEntry?> entries;
  final Float64List scores;
  int size = 0;
  int capacity;
  final int maxCapacity;
  double minScore = -1e9;

  BranchMinHeap(this.maxCapacity)
      : capacity = maxCapacity,
        entries = List<CentroidBranchEntry?>.filled(maxCapacity + 1, null),
        scores = Float64List(maxCapacity + 1);

  @pragma('vm:prefer-inline')
  void reset(int limit) {
    capacity = limit.clamp(1, maxCapacity);
    size = 0;
    minScore = -1e9;
  }

  @pragma('vm:prefer-inline')
  void clear() {
    size = 0;
    minScore = -1e9;
  }

  @pragma('vm:prefer-inline')
  void push(CentroidBranchEntry entry, double score) {
    if (size >= capacity) {
      if (score <= scores[1]) return;
      var i = 1;
      var child = 2;
      while (child <= size) {
        if (child < size && scores[child + 1] < scores[child]) {
          child++;
        }
        if (score <= scores[child]) break;
        entries[i] = entries[child];
        scores[i] = scores[child];
        i = child;
        child = i << 1;
      }
      entries[i] = entry;
      scores[i] = score;
      minScore = scores[1];
      return;
    }

    size++;
    var i = size;
    var parent = i >> 1;
    while (i > 1 && scores[parent] > score) {
      entries[i] = entries[parent];
      scores[i] = scores[parent];
      i = parent;
      parent = i >> 1;
    }
    entries[i] = entry;
    scores[i] = score;
    if (size == capacity) {
      minScore = scores[1];
    }
  }
}

// In-Memory Centroid B+Tree State (L0 roots only — L1 pages are TreeCache'd)
//
// Search-hot leaves live in [NghGraphEngine._btreeLeafCache] (TreeCache
// + ResourceManager vector budget). L1 internal nav pages live in
// [NghGraphEngine._navInternalCache] under the nav-graph budget. This state
// only holds always-resident L0 routing — never the full L1 inventory and
// never per-query scratch (see [_CentroidSearchScratch] pool).
//
// L0 is growable up to [maxRootCapacity] via far-spawn / heavy-root-split.
// Growing L0 must NOT widen search wantLeaves — only cheap 48-D routing.
final class CentroidBTreeState {
  /// Hard cap — matches insert/search L0 exact-scan ceiling.
  static const int maxRootCapacity = 256;

  /// Live L0 count (dense rootId == index in 0 .. numRootCentroids-1).
  int numRootCentroids;

  /// Wire-safe grow ceiling for the root table page (≤ [maxRootCapacity]).
  /// Derived from nav page size so encode never overflows a single page.
  int maxRoots;

  /// Capacity-[maxRootCapacity] flat 48-D roots; SIMD is a view of this buffer.
  final Float32List rootCentroids48Flat;
  late final Float32x4List rootCentroids48Simd;

  /// Always-resident L1 subtree heads (one page id per L0 root). Child nav
  /// pages load on demand into [_navInternalCache].
  final List<NghPageId> firstInternalByRoot;

  NghPageId rootPageId;
  int nextCentroidId;

  /// Set when open recovered [nextCentroidId] from a full L1 walk (legacy root
  /// pages with field==0). Cleared after the next root-table rewrite so the
  /// value is persisted without requiring a leaf split.
  bool rootTableNeedsPersist;

  bool get canGrowRoot => numRootCentroids < maxRoots;

  @pragma('vm:prefer-inline')
  void setFirstInternal(int rootId, NghPageId pageId) {
    if (rootId >= 0 && rootId < numRootCentroids) {
      firstInternalByRoot[rootId] = pageId;
      rootTableNeedsPersist = true;
    }
  }

  /// Load-from-disk / migrate pack — does not mark the root table dirty.
  @pragma('vm:prefer-inline')
  void loadFirstInternal(int rootId, NghPageId pageId) {
    if (rootId >= 0 && rootId < numRootCentroids) {
      firstInternalByRoot[rootId] = pageId;
    }
  }

  @pragma('vm:prefer-inline')
  void setRootCentroid48(int rootId, Float32List centroid48D) {
    if (rootId < 0 || rootId >= numRootCentroids) return;
    final off = rootId * 48;
    for (int d = 0; d < 48; d++) {
      rootCentroids48Flat[off + d] = centroid48D[d];
    }
    rootTableNeedsPersist = true;
  }

  /// Append a new L0 root. Returns new rootId, or -1 if at capacity.
  int appendRoot({
    required Float32List centroid48D,
    required NghPageId firstInternal,
  }) {
    if (!canGrowRoot) return -1;
    final rootId = numRootCentroids;
    final off = rootId * 48;
    for (int d = 0; d < 48; d++) {
      rootCentroids48Flat[off + d] = centroid48D[d];
    }
    firstInternalByRoot[rootId] = firstInternal;
    numRootCentroids = rootId + 1;
    rootTableNeedsPersist = true;
    return rootId;
  }

  CentroidBTreeState({
    required int numRootCentroids,
    required this.rootPageId,
    this.nextCentroidId = 1,
    this.rootTableNeedsPersist = false,
    int? maxRoots,
  })  : numRootCentroids = numRootCentroids.clamp(0, maxRootCapacity),
        maxRoots = (maxRoots ?? maxRootCapacity).clamp(1, maxRootCapacity),
        rootCentroids48Flat = Float32List(maxRootCapacity * 48),
        firstInternalByRoot = List<NghPageId>.filled(
          maxRootCapacity,
          NghPageId.none,
        ) {
    rootCentroids48Simd = Float32x4List.sublistView(rootCentroids48Flat);
    if (this.numRootCentroids > this.maxRoots) {
      this.numRootCentroids = this.maxRoots;
    }
  }
}

/// Per-query ANN scratch — rented from [NghGraphEngine] pool for the duration
/// of one search (sync or async). Enables safe multi-user concurrency without
/// allocating one resident object per historical query.
final class _CentroidSearchScratch {
  final int dimensions;

  final Float32List scratchQLow = Float32List(48);
  late final Float32x4List scratchQLowSimd =
      Float32x4List.sublistView(scratchQLow);
  final Float32List scratchQFull;
  late final Float32x4List scratchQFullSimd;

  final SlotCandidateHeap slotHeap = SlotCandidateHeap(2048);
  final BranchMinHeap branchHeap = BranchMinHeap(256);

  final Float64List rootScores = Float64List(256);
  final Int32List rootIndices = Int32List(256);
  final Int32List probedRoots = Int32List(256);
  final List<CentroidBranchEntry?> pickedLeaves =
      List<CentroidBranchEntry?>.filled(1024, null);

  /// Resolved hot leaf pages for [pickedLeaves] (avoids TreeCache re-lookup).
  final List<NghLeafPage?> pickedLeafPages =
      List<NghLeafPage?>.filled(1024, null);

  /// Reused Top-K heap (avoids per-query _FixedHeap alloc).
  _FixedHeap? resultHeap;

  // Fast single-cycle visited tag (1M nodes, 4MB — pooled/reused).
  final Int32List visitedTag = Int32List(1048576);
  int currentStamp = 0;

  _CentroidSearchScratch({required this.dimensions})
      : scratchQFull = Float32List(dimensions) {
    scratchQFullSimd = Float32x4List.view(
      scratchQFull.buffer,
      0,
      max(0, dimensions >> 2),
    );
  }

  @pragma('vm:prefer-inline')
  void nextQueryStamp() {
    currentStamp++;
    if (currentStamp >= 2147483640) {
      visitedTag.fillRange(0, visitedTag.length, 0);
      currentStamp = 1;
    }
  }
}

/// NGH Graph Engine -- core vector search and dynamic graph engine.
class NghGraphEngine {
  final NghPartitionManager _partitionManager;

  /// Typical leaf occupancy used for slot-budget estimates.
  static const int _typicalLeafSlots = 4096;

  /// Interactive scoring cap at depth 100 (keeps p95 interactive on 1M–10M).
  static const int _maxInteractiveLeaves = 44;

  /// Map [searchDepth] → target recall intent.
  ///
  /// Anchors (no hard max):
  /// depth 1 → 91.0% (±5pp)
  /// depth 50 → 95.0% (±3pp strict production baseline)
  /// depth 100 → 98.0% (±5pp; 99% is not the interactive ceiling)
  /// depth >100 continues the 50→100 intent slope until 100%, then stays
  /// saturated — probe budget still rises so large corpora can catch the
  /// same knob feel.
  static double targetRecallFromDepth(int searchDepth) {
    if (searchDepth <= 1) return 0.91;
    if (searchDepth <= 50) {
      return 0.91 + (0.95 - 0.91) * ((searchDepth - 1) / 49.0);
    }
    if (searchDepth <= 100) {
      return 0.95 + (0.98 - 0.95) * ((searchDepth - 50) / 50.0);
    }
    const ppPerDepth = (0.98 - 0.95) / 50.0;
    return min(1.0, 0.98 + ppPerDepth * (searchDepth - 100));
  }

  /// Interactive scoring cap: depth 1→14, 50→28, 100→44 typical lists.
  /// Depth >100 continues the same 50→100 Δlists/Δdepth so users can keep
  /// tuning recall when depth=100 is not enough — absolute-capped only to
  /// forbid inventory-wide brute force (never the old soft 1024 flood).
  static const int _absScoredLeafCap = 256;

  static int _maxLeavesForDepth(
    int searchDepth, {
    required int nLeaves,
    required int totalVectors,
  }) {
    const cap1 = 14;
    const cap50 = 28;
    const cap100 = _maxInteractiveLeaves;
    final depth = max(1, searchDepth);
    final int cap;
    if (depth <= 1) {
      cap = cap1;
    } else if (depth <= 50) {
      final x = depth / 100.0;
      cap = (cap1 + (cap50 - cap1) * (x / 0.50)).round();
    } else if (depth <= 100) {
      final x = depth / 100.0;
      cap = (cap50 + (cap100 - cap50) * ((x - 0.50) / 0.50)).round();
    } else {
      // Escape hatch: depth 150/200/… keeps buying lists at the 50→100 rate
      // until [_absScoredLeafCap]. searchDepth has no hard max.

      // Same delivered slope as depth 50→100 (incl. interactive endpoint).
      const slopePerDepth = (cap100 - cap50) / 50.0; // 0.32
      cap = min(
        _absScoredLeafCap,
        (cap100 + slopePerDepth * (depth - 100)).round(),
      );
    }
    return nLeaves > 0 ? min(nLeaves, cap) : cap;
  }

  /// Soft ceiling for navigating centroid graph cache.
  int _navGraphCacheMaxBytes = 32 * 1024 * 1024;

  /// In-memory cached navigating centroid graph per index.
  /// Key: `[tableUid.value, indexUid.value]`.
  late final TreeCache<NghNavGraphPage> _navGraphCache =
      TreeCache<NghNavGraphPage>(
    groupDepth: 2,
    sizeCalculator: (page) =>
        64 + page.centroids.length * (128 + page.dimensions * 4),
    evictionMode: TreeCacheEvictionMode.lru,
    maxByteThreshold: _navGraphCacheMaxBytes,
    minByteThreshold: _navGraphCacheMaxBytes ~/ 2,
    debugLabel: 'NghNavGraphCache',
  );

  /// Soft ceiling for Centroid B+Tree L1 internal nav pages (paged layout).
  /// Shares the nav-graph budget family from ResourceManager.
  int _navInternalCacheMaxBytes = 32 * 1024 * 1024;

  /// Budgeted L1 internal branch pages. Key: `[tableUid, indexUid, part, page]`.
  ///
  /// L0 roots stay in [CentroidBTreeState]; L1 inventory is NOT fully resident.
  late final TreeCache<NghNavBTreePage> _navInternalCache =
      TreeCache<NghNavBTreePage>(
    groupDepth: 2,
    sizeCalculator: (page) => page.estimateResidentBytes(),
    evictionMode: TreeCacheEvictionMode.lru,
    maxByteThreshold: _navInternalCacheMaxBytes,
    minByteThreshold: _navInternalCacheMaxBytes ~/ 2,
    debugLabel: 'NghNavInternalCache',
  );

  /// Inflight futures for navigating centroid graph loading.
  final Map<String, Future<NghNavGraphPage?>> _navGraphInflight = {};

  /// Soft ceiling for Nav B+Tree search-hot leaves.
  /// Synced from ResourceManager via [configureVectorSearchCacheBudget].
  int _btreeLeafCacheMaxBytes = 32 * 1024 * 1024;

  /// Paged ANN leaf working set. Key: `[tableUid, indexUid, partitionNo, pageNo]`.
  ///
  /// Budgeted by the same vector quota as the dedicated vector leaf quota so
  /// insert thrash cannot silently shrink the hot set below startup prewarm.
  late final TreeCache<NghLeafPage> _btreeLeafCache = TreeCache<NghLeafPage>(
    groupDepth: 2,
    sizeCalculator: (page) => page.estimateResidentBytes(),
    evictionMode: TreeCacheEvictionMode.lru,
    maxByteThreshold: _btreeLeafCacheMaxBytes,
    minByteThreshold: _btreeLeafCacheMaxBytes ~/ 2,
    debugLabel: 'NghBTreeLeafCache',
  );

  late final NghPkMapEngine _pkMap =
      NghPkMapEngine(_partitionManager, _partitionManager.engineConfig);

  /// Centroid B+Tree in-memory states (L0 roots + firstInternal heads).
  /// Key: `tableUid.value:indexUid.value`.
  final Map<String, CentroidBTreeState> _btreeStates = {};

  /// Indexes whose hot ANN loops have been JIT-compiled on this engine instance.
  /// Key: `tableUid.value/indexUid.value`.
  final Set<String> _warmedSearchIndexes = {};

  /// Per-dimension pool of [_CentroidSearchScratch] for concurrent ANN.
  /// Cap bounds peak memory ≈ concurrent_searches × scratch_size, not QPS.
  final Map<int, List<_CentroidSearchScratch>> _searchScratchPools = {};
  static const int _searchScratchPoolMaxPerDim = 64;

  _CentroidSearchScratch _acquireSearchScratch(int dimensions) {
    final pool = _searchScratchPools.putIfAbsent(dimensions, () => []);
    if (pool.isNotEmpty) return pool.removeLast();
    return _CentroidSearchScratch(dimensions: dimensions);
  }

  void _releaseSearchScratch(_CentroidSearchScratch scratch) {
    final pool = _searchScratchPools.putIfAbsent(scratch.dimensions, () => []);
    if (pool.length < _searchScratchPoolMaxPerDim) {
      pool.add(scratch);
    }
  }

  NghGraphEngine(this._partitionManager);

  /// Steady-state L0 target after bootstrap (precise routing, cheap exact scan).
  /// Multi-million corpora need denser L0 than 64 — push toward page-fit so
  /// interactive wantRoots covers a finer partition (rebuild required).
  static const int _targetL0Roots = 96;

  /// L0 / mid / leaf boundary multi-assign ratio (48-D IP).
  /// 0.94 was too tight at 768D/3M: true neighbors often sit just outside
  /// the primary cell and were never dual-homed → depth100 plateau ~93%.
  static const double _boundaryDualRatio = 0.88;

  /// Below this corpus size L0 may still be sparse; grow via far-spawn/split.
  /// Crossing it does NOT freeze L0 — Steady still allows growth to
  /// [CentroidBTreeState.maxRootCapacity] / page-fit without rewriting leaves.
  static const int _bootstrapMinVectors = 4096;

  /// 48-D IP below which a point is "far" from all L0 (spawn candidate).
  /// Aggressive while under [_targetL0Roots]; past target still grows toward
  /// [maxRoots] (page-fit) so distribution drift can open new cells — never
  /// freezes at the target for the rest of the corpus lifetime.
  static double _l0FarSpawnThreshold(int numRoots, {required int maxRoots}) {
    if (numRoots <= 0) return 1.0;
    final cap = max(1, maxRoots);
    if (numRoots >= cap) return 0.0;
    if (numRoots < _targetL0Roots) {
      final kRatio = numRoots / _targetL0Roots;
      return 0.55 - 0.18 * kRatio; // ~0.55 → ~0.37
    }
    // 64 → page-fit: keep a soft far-spawn door (0.40 → ~0.30).
    // Uses target as the knee even when target > 64.
    final t = (numRoots - _targetL0Roots) / max(1, cap - _targetL0Roots);
    return 0.40 - 0.10 * t.clamp(0.0, 1.0);
  }

  /// Initial L0 count for cold-start / migrate pack — never overfit tiny N to 64.
  static int _initialL0RootCount(int sampleCount) {
    if (sampleCount <= 0) return 1;
    if (sampleCount >= _bootstrapMinVectors) {
      return min(_targetL0Roots, sampleCount);
    }
    final sparse = max(1, (sqrt(sampleCount.toDouble()) * 2.0).round());
    return min(_targetL0Roots, min(sampleCount, sparse));
  }

  /// Max L0 roots that fit in one nav root-table page (header + 204B/root).
  static int _maxL0RootsForNavPageSize(int navPageSize) {
    // BTree page header (~20) + CNRT header (16) + encrypt margin.
    final usable = max(204, navPageSize - 96);
    final fit = usable ~/ 204;
    return min(CentroidBTreeState.maxRootCapacity, max(1, fit));
  }

  int _leafPageSize(NghIndexMeta meta) =>
      _partitionManager.pageSizeFor(NghDataCategory.leaf, meta);

  int _navPageSize(NghIndexMeta meta) =>
      _partitionManager.pageSizeFor(NghDataCategory.nav, meta);

  /// Current estimated nav-graph cache footprint in bytes.
  int get navGraphCacheBytes => _navGraphCache.estimatedTotalSizeBytes;

  TreeCache<NghNavGraphPage> get navGraphCache => _navGraphCache;

  /// Current nav-graph cache ceiling in bytes.
  int get navGraphCacheMaxBytes => _navGraphCacheMaxBytes;

  /// Apply a resolved byte ceiling: max as-is, min = max ~/ 2.
  ///
  /// Floors are resolved by [VectorIndexManager] before calling configure.
  /// No-ops when [currentMax] already matches so repeated sync is cheap.
  void _applyCacheBudget<T>(
    TreeCache<T> cache,
    int maxBytes, {
    required int currentMax,
    required void Function(int) setMax,
  }) {
    final maxB = max(1, maxBytes);
    if (currentMax == maxB) return;
    setMax(maxB);
    cache.updateByteThreshold(max: maxB, min: max(1, maxB ~/ 2));
  }

  /// Configure nav-graph cache ceiling (adaptive based on memory budget).
  ///
  /// Also applies to paged Centroid B+Tree L1 internal pages
  /// ([_navInternalCache]) — L0 roots remain always-resident and tiny.
  /// [maxBytes] must already include any platform / ratio floors.
  void configureNavGraphCacheBudget(int maxBytes) {
    _applyCacheBudget(
      _navGraphCache,
      maxBytes,
      currentMax: _navGraphCacheMaxBytes,
      setMax: (v) => _navGraphCacheMaxBytes = v,
    );
    _applyCacheBudget(
      _navInternalCache,
      maxBytes,
      currentMax: _navInternalCacheMaxBytes,
      setMax: (v) => _navInternalCacheMaxBytes = v,
    );
  }

  /// Resident Centroid B+Tree L1 internal-page cache bytes (all indexes).
  int get navInternalCacheBytes => _navInternalCache.estimatedTotalSizeBytes;

  /// Current L1 internal-page cache ceiling in bytes.
  int get navInternalCacheMaxBytes => _navInternalCacheMaxBytes;

  /// Resident search-hot leaf cache bytes (all indexes).
  int get btreeLeafCacheBytes => _btreeLeafCache.estimatedTotalSizeBytes;

  /// Current search-hot leaf-cache ceiling in bytes.
  int get btreeLeafCacheMaxBytes => _btreeLeafCacheMaxBytes;

  /// Configure search-hot leaf cache ceiling (vector quota).
  ///
  /// [maxBytes] must already include the 64MB floor from the resolver.
  void configureVectorSearchCacheBudget(int maxBytes) {
    _applyCacheBudget(
      _btreeLeafCache,
      maxBytes,
      currentMax: _btreeLeafCacheMaxBytes,
      setMax: (v) => _btreeLeafCacheMaxBytes = v,
    );
  }

  /// Search-hot leaf cache. Steady-state residency is here only —
  /// [_partitionManager] leaf I/O fill is short-lived and must be evicted
  /// when a page is pinned hot (see [_btreeLeafPut]).
  NghLeafPage? _btreeLeafGet(
    TableUid tableUid,
    IndexUid indexUid,
    NghPageId id, {
    bool touch = true,
  }) {
    if (id.isNone) return null;
    final hot = _btreeLeafCache.getPoint4(
      tableUid.value,
      indexUid.value,
      id.partitionNo,
      id.pageNo,
      touch: touch,
    );
    if (hot != null) return hot;
    // Rare: page still only in I/O fill (e.g. mid-flush). Adopt into hot and
    // drop the I/O twin so we never keep long-lived dual residency.
    final io = _partitionManager.getCachedLeafPage(
      tableUid,
      indexUid,
      id.partitionNo,
      id.pageNo,
    );
    if (io == null) return null;
    _btreeLeafPut(tableUid, indexUid, id, io);
    return io;
  }

  void _btreeLeafPut(
    TableUid tableUid,
    IndexUid indexUid,
    NghPageId id,
    NghLeafPage page,
  ) {
    if (id.isNone) return;
    page.ensureLow48Ready();
    _btreeLeafCache.putPoint4(
      tableUid.value,
      indexUid.value,
      id.partitionNo,
      id.pageNo,
      page,
      size: page.estimateResidentBytes(),
    );
    // Hard rule: search-hot wins — never leave the same page in I/O fill.
    _partitionManager.evictLeafPage(
      tableUid,
      indexUid,
      id.partitionNo,
      id.pageNo,
    );
  }

  void _btreeLeafClearForIndex(TableUid tableUid, IndexUid indexUid) {
    _btreeLeafCache.remove([tableUid.value, indexUid.value]);
  }

  NghNavBTreePage? _navInternalGet(
    TableUid tableUid,
    IndexUid indexUid,
    NghPageId id, {
    bool touch = true,
  }) {
    if (id.isNone) return null;
    return _navInternalCache.getPoint4(
      tableUid.value,
      indexUid.value,
      id.partitionNo,
      id.pageNo,
      touch: touch,
    );
  }

  void _navInternalPut(
    TableUid tableUid,
    IndexUid indexUid,
    NghPageId id,
    NghNavBTreePage page,
  ) {
    if (id.isNone) return;
    _navInternalCache.putPoint4(
      tableUid.value,
      indexUid.value,
      id.partitionNo,
      id.pageNo,
      page,
      size: page.estimateResidentBytes(),
    );
  }

  /// Resolve an L1 page: dirty overlay → TreeCache → null (caller hydrates).
  @pragma('vm:prefer-inline')
  NghNavBTreePage? _resolveNavInternalPage({
    required TableUid tableUid,
    required IndexUid indexUid,
    required NghPageId id,
    Map<NghPagePtr, NghNavBTreePage>? dirtyOverlay,
    bool touch = true,
  }) {
    if (id.isNone) return null;
    if (dirtyOverlay != null) {
      final dirty = dirtyOverlay[NghPagePtr(
        NghDataCategory.nav,
        id.partitionNo,
        id.pageNo,
      )];
      if (dirty != null) return dirty;
    }
    return _navInternalGet(tableUid, indexUid, id, touch: touch);
  }

  /// Beam from recall-intent [searchDepth], with a log10(N) floor for mid trees.
  ///
  /// depth≤1 → 2; ≤50 → 3; ≤100 → 4; then +1 per 50 depth.
  /// N floor (knees 4.2 / 5.0 / 5.5) so mid hops at 30k–4M are not starved.
  /// Depth-scaled cap: 5 / 6 / 8 at depth 1 / 50 / 100 so large-N does not
  /// saturate every depth at 8 (searchDepth would collapse). Floor 2.
  static int _navBeamWidth({
    required int searchDepth,
    required int wantLeaves,
    required int totalVectors,
  }) {
    final depth = max(1, searchDepth);
    final int fromDepth;
    if (depth <= 1) {
      fromDepth = 2;
    } else if (depth <= 50) {
      fromDepth = 3;
    } else if (depth <= 100) {
      fromDepth = 4;
    } else {
      fromDepth = 4 + ((depth - 100) ~/ 50);
    }
    final logN = log(max(1000, totalVectors).toDouble()) / ln10;
    final nFloor = 2 +
        max(0.0, (logN - 4.2) * 2.0).round() +
        max(0.0, (logN - 5.0) * 1.5).round() +
        max(0.0, (logN - 5.5) * 2.0).round();
    final int depthCap;
    if (depth <= 1) {
      depthCap = 5;
    } else if (depth <= 50) {
      depthCap = 6;
    } else {
      depthCap = 8;
    }
    final fromLeaves = max(2, wantLeaves ~/ 3);
    final target = max(fromDepth, max(nFloor, fromLeaves));
    return max(2, min(depthCap, target));
  }

  void _forEachScoredNavEntry({
    required NghNavBTreePage page,
    required Float32x4 q0,
    required Float32x4 q1,
    required Float32x4 q2,
    required Float32x4 q3,
    required Float32x4 q4,
    required Float32x4 q5,
    required Float32x4 q6,
    required Float32x4 q7,
    required Float32x4 q8,
    required Float32x4 q9,
    required Float32x4 q10,
    required Float32x4 q11,
    required void Function(CentroidBranchEntry entry, double score) fn,
  }) {
    page.ensureSearch48Ready();
    final packed = page.search48Simd!;
    final entries = page.entries;
    final n = entries.length;
    for (int i = 0; i < n; i++) {
      fn(
        entries[i],
        innerProduct48Reg(
          q0,
          q1,
          q2,
          q3,
          q4,
          q5,
          q6,
          q7,
          q8,
          q9,
          q10,
          q11,
          packed,
          i * 12,
        ),
      );
    }
  }

  ({int bestIdx, double bestScore, int secondIdx, double secondScore})
      _top2NavChildren(NghNavBTreePage page, Float32x4List qLowSimd) {
    page.ensureSearch48Ready();
    final packed = page.search48Simd!;
    final n = page.entries.length;
    var bestIdx = 0;
    var secondIdx = -1;
    var bestScore = -1e9;
    var secondScore = -1e9;
    for (int i = 0; i < n; i++) {
      final s = innerProduct48(qLowSimd, packed, i * 12);
      if (s > bestScore) {
        secondScore = bestScore;
        secondIdx = bestIdx;
        bestScore = s;
        bestIdx = i;
      } else if (s > secondScore) {
        secondScore = s;
        secondIdx = i;
      }
    }
    return (
      bestIdx: bestIdx,
      bestScore: bestScore,
      secondIdx: secondIdx,
      secondScore: secondScore,
    );
  }

  void _bubbleNavSummaryUp({
    required int rootId,
    required NghPageId childId,
    required NghNavBTreePage childPage,
    required List<({NghPageId pageId, NghNavBTreePage page, int childIdx})>
        path,
    required void Function(NghPageId id, NghNavBTreePage page) mark,
  }) {
    if (path.isEmpty) return;
    var cId = childId;
    var cPage = childPage;
    for (var i = path.length - 1; i >= 0; i--) {
      final parent = path[i];
      if (parent.childIdx < 0 ||
          parent.childIdx >= parent.page.entries.length) {
        break;
      }
      parent.page.entries[parent.childIdx] = _summaryEntryForChild(
        childPageId: cId,
        childPage: cPage,
        fallbackCentroidId: rootId,
      );
      mark(parent.pageId, parent.page);
      cId = parent.pageId;
      cPage = parent.page;
    }
  }

  /// Score leaf candidates under one L0 root with bounded hop descent.
  ///
  /// Each hop scores ≤[NghNavBTreePage.maxEntriesPerPage] children of ONE page,
  /// then beams to top-[beam] mids. Cost is O(hops×64×beam), not O(N).
  /// Returns false if any required nav page is missing from cache/dirty.
  /// Corrupt trees that never reach leaf-level throw (never rewrite mid flags).
  bool _scoreNavSubtreeCached({
    required TableUid tableUid,
    required IndexUid indexUid,
    required CentroidBTreeState state,
    required int rootId,
    required Float32x4 q0,
    required Float32x4 q1,
    required Float32x4 q2,
    required Float32x4 q3,
    required Float32x4 q4,
    required Float32x4 q5,
    required Float32x4 q6,
    required Float32x4 q7,
    required Float32x4 q8,
    required Float32x4 q9,
    required Float32x4 q10,
    required Float32x4 q11,
    required int maxLeavesToRead,
    required int beamWidth,
    required BranchMinHeap leafHeap,
    Map<NghPagePtr, NghNavBTreePage>? dirtyOverlay,
  }) {
    if (rootId < 0 || rootId >= state.firstInternalByRoot.length) return true;
    final head = state.firstInternalByRoot[rootId];
    if (head.isNone) return true;

    NghNavBTreePage? pageOf(NghPageId id) => _resolveNavInternalPage(
          tableUid: tableUid,
          indexUid: indexUid,
          id: id,
          dirtyOverlay: dirtyOverlay,
          touch: true,
        );

    void pushLeaf(CentroidBranchEntry entry, double score) {
      if (leafHeap.size >= maxLeavesToRead && score <= leafHeap.minScore) {
        return;
      }
      leafHeap.push(entry, score);
    }

    var frontier = <NghPageId>[head];
    var hop = 0;
    while (frontier.isNotEmpty) {
      if (++hop > NghNavBTreePage.maxTreeHops) {
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message:
                'NGH nav descent exceeded maxTreeHops=${NghNavBTreePage.maxTreeHops} '
                '(root=$rootId). Refusing to treat a mid page as a leaf.',
          )
        ]);
      }
      final midScored = <({NghPageId child, double score})>[];
      var sawMid = false;
      for (final pageId in frontier) {
        final page = pageOf(pageId);
        if (page == null) return false;
        if (page.isLeafLevel) {
          _forEachScoredNavEntry(
            page: page,
            q0: q0,
            q1: q1,
            q2: q2,
            q3: q3,
            q4: q4,
            q5: q5,
            q6: q6,
            q7: q7,
            q8: q8,
            q9: q9,
            q10: q10,
            q11: q11,
            fn: pushLeaf,
          );
        } else {
          sawMid = true;
          _forEachScoredNavEntry(
            page: page,
            q0: q0,
            q1: q1,
            q2: q2,
            q3: q3,
            q4: q4,
            q5: q5,
            q6: q6,
            q7: q7,
            q8: q8,
            q9: q9,
            q10: q10,
            q11: q11,
            fn: (e, s) {
              if (e.childPageId.isNone) return;
              midScored.add((child: e.childPageId, score: s));
            },
          );
        }
      }
      if (!sawMid) return true;
      midScored.sort((a, b) => b.score.compareTo(a.score));
      final take = min(beamWidth, midScored.length);
      frontier = [
        for (int i = 0; i < take; i++) midScored[i].child,
      ];
    }
    return true;
  }

  /// Cold-path nav descent: score with [q], load missing pages, beam globally.
  ///
  /// Unreadable pages skip that branch (other roots continue). Never hydrates
  /// a prefix then scores a different subset.
  Future<void> _scoreNavSubtreeAsync({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required CentroidBTreeState state,
    required int rootId,
    required Float32x4 q0,
    required Float32x4 q1,
    required Float32x4 q2,
    required Float32x4 q3,
    required Float32x4 q4,
    required Float32x4 q5,
    required Float32x4 q6,
    required Float32x4 q7,
    required Float32x4 q8,
    required Float32x4 q9,
    required Float32x4 q10,
    required Float32x4 q11,
    required int maxLeavesToRead,
    required int beamWidth,
    required BranchMinHeap leafHeap,
  }) async {
    if (rootId < 0 || rootId >= state.firstInternalByRoot.length) return;
    final head = state.firstInternalByRoot[rootId];
    if (head.isNone) return;

    Future<NghNavBTreePage?> pageOf(NghPageId id) async {
      final cached = _resolveNavInternalPage(
        tableUid: table.tableUid,
        indexUid: indexUid,
        id: id,
        touch: true,
      );
      if (cached != null) return cached;
      final loaded = await _partitionManager.readNavBTreePage(
        table,
        indexUid,
        id,
        meta: meta,
      );
      if (loaded == null) return null;
      _navInternalPut(table.tableUid, indexUid, id, loaded);
      return loaded;
    }

    void pushLeaf(CentroidBranchEntry entry, double score) {
      if (leafHeap.size >= maxLeavesToRead && score <= leafHeap.minScore) {
        return;
      }
      leafHeap.push(entry, score);
    }

    var frontier = <NghPageId>[head];
    var hop = 0;
    while (frontier.isNotEmpty) {
      if (++hop > NghNavBTreePage.maxTreeHops) {
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message:
                'NGH nav descent exceeded maxTreeHops=${NghNavBTreePage.maxTreeHops} '
                '(root=$rootId). Refusing to treat a mid page as a leaf.',
          )
        ]);
      }
      final midScored = <({NghPageId child, double score})>[];
      var sawMid = false;
      for (final pageId in frontier) {
        final page = await pageOf(pageId);
        if (page == null) continue;
        if (page.isLeafLevel) {
          _forEachScoredNavEntry(
            page: page,
            q0: q0,
            q1: q1,
            q2: q2,
            q3: q3,
            q4: q4,
            q5: q5,
            q6: q6,
            q7: q7,
            q8: q8,
            q9: q9,
            q10: q10,
            q11: q11,
            fn: pushLeaf,
          );
        } else {
          sawMid = true;
          _forEachScoredNavEntry(
            page: page,
            q0: q0,
            q1: q1,
            q2: q2,
            q3: q3,
            q4: q4,
            q5: q5,
            q6: q6,
            q7: q7,
            q8: q8,
            q9: q9,
            q10: q10,
            q11: q11,
            fn: (e, s) {
              if (e.childPageId.isNone) return;
              midScored.add((child: e.childPageId, score: s));
            },
          );
        }
      }
      if (!sawMid) return;
      midScored.sort((a, b) => b.score.compareTo(a.score));
      final take = min(beamWidth, midScored.length);
      frontier = [
        for (int i = 0; i < take; i++) midScored[i].child,
      ];
    }
  }

  /// Prefetch nav pages under [rootIds] for warmup (no query vector).
  /// Heuristic first-N children per mid; search must not use this for recall.
  Future<void> _hydrateNavDescentForRoots({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required CentroidBTreeState state,
    required Iterable<int> rootIds,
    int beamWidth = 4,
    bool Function()? shouldAbort,
    int? maxNavBytes,
  }) async {
    final prefetchCap = max(1, beamWidth * 2);
    bool aborted() => shouldAbort?.call() ?? false;
    bool overNavBudget() =>
        maxNavBytes != null &&
        _navInternalCache.estimatedTotalSizeBytes >= maxNavBytes;

    for (final rootId in rootIds) {
      if (aborted() || overNavBudget()) return;
      if (rootId < 0 || rootId >= state.firstInternalByRoot.length) continue;
      var frontier = <NghPageId>[state.firstInternalByRoot[rootId]];
      var hop = 0;
      while (frontier.isNotEmpty) {
        if (aborted() || overNavBudget()) return;
        if (++hop > NghNavBTreePage.maxTreeHops) {
          throw DbException([
            GeneralStatus(
              type: ResultType.engError,
              message:
                  'NGH nav hydrate exceeded maxTreeHops=${NghNavBTreePage.maxTreeHops} '
                  '(root=$rootId).',
            )
          ]);
        }
        final next = <NghPageId>[];
        for (final pageId in frontier) {
          if (aborted() || overNavBudget()) return;
          if (pageId.isNone) continue;
          var page = _navInternalGet(table.tableUid, indexUid, pageId);
          if (page == null) {
            page = await _partitionManager.readNavBTreePage(
              table,
              indexUid,
              pageId,
              meta: meta,
            );
            if (page == null) continue;
            _navInternalPut(table.tableUid, indexUid, pageId, page);
          }
          if (page.isLeafLevel) continue;
          var n = 0;
          for (final e in page.entries) {
            if (e.childPageId.isNone) continue;
            next.add(e.childPageId);
            if (++n >= prefetchCap) break;
          }
        }
        if (next.isEmpty) break;
        frontier = next.length > prefetchCap
            ? next.take(prefetchCap).toList(growable: false)
            : next;
      }
    }
  }

  /// Load one root's nav subtree head into [_navInternalCache].
  Future<List<({NghPageId pageId, NghNavBTreePage page})>> _loadRootHeadPage({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required CentroidBTreeState state,
    required int rootId,
    Map<NghPagePtr, NghNavBTreePage>? dirtyOverlay,
    bool strict = true,
  }) async {
    final out = <({NghPageId pageId, NghNavBTreePage page})>[];
    if (rootId < 0 || rootId >= state.firstInternalByRoot.length) return out;
    final curr = state.firstInternalByRoot[rootId];
    if (curr.isNone) return out;
    var page = _resolveNavInternalPage(
      tableUid: table.tableUid,
      indexUid: indexUid,
      id: curr,
      dirtyOverlay: dirtyOverlay,
      touch: true,
    );
    if (page == null) {
      page = await _partitionManager.readNavBTreePage(
        table,
        indexUid,
        curr,
        meta: meta,
      );
      if (page == null) {
        if (strict) {
          throw DbException([
            GeneralStatus(
              type: ResultType.engError,
              message: 'NGH nav head page missing (root=$rootId, page=$curr).',
            )
          ]);
        }
        return out;
      }
      _navInternalPut(table.tableUid, indexUid, curr, page);
    }
    out.add((pageId: curr, page: page));
    return out;
  }

  /// Startup/open nav sample for leaf ranking — beam-capped, never full tree.
  Future<void> _hydrateNavChainsForRoots({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required CentroidBTreeState state,
    required Iterable<int> rootIds,
    bool Function()? shouldAbort,
  }) =>
      _hydrateNavDescentForRoots(
        table: table,
        indexUid: indexUid,
        meta: meta,
        state: state,
        rootIds: rootIds,
        beamWidth: 8,
        shouldAbort: shouldAbort,
        maxNavBytes: _navInternalCacheMaxBytes,
      );

  /// Pages needed for a nav subtree holding [leafEntryCount] leaf entries.
  /// Always ≥1 (empty root still gets one leaf-level page).
  static int _navTreePagesNeeded(int leafEntryCount) {
    final fanout = NghNavBTreePage.maxEntriesPerPage;
    var level =
        leafEntryCount <= 0 ? 1 : (leafEntryCount + fanout - 1) ~/ fanout;
    var total = level;
    while (level > 1) {
      level = (level + fanout - 1) ~/ fanout;
      total += level;
    }
    return total;
  }

  Float32List _mean48BranchEntries(List<CentroidBranchEntry> entries) {
    final out = Float32List(48);
    if (entries.isEmpty) return out;
    var wSum = 0;
    for (final e in entries) {
      final w = max(1, e.childWeight);
      wSum += w;
      final c = e.centroid48D;
      for (int d = 0; d < 48; d++) {
        out[d] += c[d] * w;
      }
    }
    final inv = 1.0 / wSum;
    for (int d = 0; d < 48; d++) {
      out[d] *= inv;
    }
    return out;
  }

  int _branchEntriesWeight(List<CentroidBranchEntry> entries) {
    var w = 0;
    for (final e in entries) {
      w += max(1, e.childWeight);
    }
    return w;
  }

  /// Far-pair / projection 50-50 split (same spirit as leaf split).
  (List<CentroidBranchEntry>, List<CentroidBranchEntry>)
      _splitBranchEntriesBalanced(
    List<CentroidBranchEntry> entries,
  ) {
    if (entries.length <= 1) {
      return (List<CentroidBranchEntry>.from(entries), <CentroidBranchEntry>[]);
    }
    final seedA = entries[0].centroid48DSimd;
    var bestB = 1;
    var minSim = 1e9;
    for (int i = 1; i < entries.length; i++) {
      final sim = innerProduct48(seedA, entries[i].centroid48DSimd, 0);
      if (sim < minSim) {
        minSim = sim;
        bestB = i;
      }
    }
    final seedB = entries[bestB].centroid48DSimd;
    final scores = Float64List(entries.length);
    final indices = Int32List(entries.length);
    for (int i = 0; i < entries.length; i++) {
      final s = entries[i].centroid48DSimd;
      scores[i] = innerProduct48(seedA, s, 0) - innerProduct48(seedB, s, 0);
      indices[i] = i;
    }
    for (int i = 0; i < entries.length; i++) {
      var maxIdx = i;
      for (int j = i + 1; j < entries.length; j++) {
        if (scores[j] > scores[maxIdx]) maxIdx = j;
      }
      final ts = scores[i];
      scores[i] = scores[maxIdx];
      scores[maxIdx] = ts;
      final ti = indices[i];
      indices[i] = indices[maxIdx];
      indices[maxIdx] = ti;
    }
    final mid = entries.length ~/ 2;
    final left = <CentroidBranchEntry>[];
    final right = <CentroidBranchEntry>[];
    for (int i = 0; i < mid; i++) {
      left.add(entries[indices[i]]);
    }
    for (int i = mid; i < entries.length; i++) {
      right.add(entries[indices[i]]);
    }
    if (left.isEmpty && right.isNotEmpty) {
      left.add(right.removeLast());
    }
    return (left, right);
  }

  CentroidBranchEntry _summaryEntryForChild({
    required NghPageId childPageId,
    required NghNavBTreePage childPage,
    required int fallbackCentroidId,
  }) {
    final mean = _mean48BranchEntries(childPage.entries);
    return CentroidBranchEntry(
      centroidId: childPage.entries.isEmpty
          ? fallbackCentroidId
          : childPage.entries.first.centroidId,
      leafPageId: childPageId,
      leafSlotCount: _branchEntriesWeight(childPage.entries),
      centroid48D: mean,
    );
  }

  /// Pack leaf branch entries into a mid/leaf nav subtree.
  /// [pageIds] length must be [_navTreePagesNeeded(leafEntries.length)].
  NghPageId _writeNavSubtree({
    required int rootId,
    required List<CentroidBranchEntry> leafEntries,
    required List<NghPageId> pageIds,
    required void Function(NghPageId id, NghNavBTreePage page) write,
  }) {
    final fanout = NghNavBTreePage.maxEntriesPerPage;
    var cursor = 0;
    NghPageId take() {
      if (cursor >= pageIds.length) {
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message:
                'NGH nav pack underflow (root=$rootId, need>${pageIds.length})',
          )
        ]);
      }
      return pageIds[cursor++];
    }

    var level = <({NghPageId id, NghNavBTreePage page})>[];
    if (leafEntries.isEmpty) {
      final id = take();
      final page = NghNavBTreePage(rootCentroidId: rootId, entries: []);
      write(id, page);
      return id;
    }
    for (var i = 0; i < leafEntries.length; i += fanout) {
      final chunk = leafEntries.sublist(
        i,
        min(i + fanout, leafEntries.length),
      );
      final id = take();
      final page = NghNavBTreePage(
        rootCentroidId: rootId,
        flags: NghNavBTreePage.flagLeafLevel,
        entries: chunk,
      );
      write(id, page);
      level.add((id: id, page: page));
    }

    while (level.length > 1) {
      final next = <({NghPageId id, NghNavBTreePage page})>[];
      for (var i = 0; i < level.length; i += fanout) {
        final children = level.sublist(i, min(i + fanout, level.length));
        final midEntries = <CentroidBranchEntry>[
          for (final ch in children)
            _summaryEntryForChild(
              childPageId: ch.id,
              childPage: ch.page,
              fallbackCentroidId: rootId,
            ),
        ];
        final id = take();
        final page = NghNavBTreePage(
          rootCentroidId: rootId,
          flags: 0, // mid-level
          entries: midEntries,
        );
        write(id, page);
        next.add((id: id, page: page));
      }
      level = next;
    }
    return level.first.id;
  }

  String _cacheKey(TableUid tableUid, IndexUid indexUid) =>
      '${tableUid.value}/${indexUid.value}';

  /// LRU-trim search-hot SQ8 leaves only.
  ///
  /// L0 (~48KB) lives in [CentroidBTreeState] and is never stored here.
  /// Mid-1/Mid-2 nav pages share [_navInternalCache] with deeper hops — do
  /// not LRU that cache on ordinary LOW (see [evictNavWorkingSet]).
  Future<void> evictHotSearchCaches({double ratio = 0.3}) async {
    await _btreeLeafCache.cleanup(removeRatio: ratio);
  }

  /// LRU-trim nav working set (deeper mid / leaf-nav, plus legacy graph blob).
  ///
  /// Call only under CRITICAL or when the nav budget is already exceeded.
  /// Hot Mid-1/Mid-2 pages stay if they were touched recently (every descent).
  Future<void> evictNavWorkingSet({double ratio = 0.3}) async {
    await _navInternalCache.cleanup(removeRatio: ratio);
    await _navGraphCache.cleanup(removeRatio: ratio);
  }

  /// Evict a ratio of paged ANN leaf caches.
  Future<void> evictBTreeLeafCache({double ratio = 0.3}) async {
    await _btreeLeafCache.cleanup(removeRatio: ratio);
  }

  /// Clear nav/leaf caches for a specific table.
  void clearCacheForTable(TableUid tableUid) {
    _navGraphCache.remove([tableUid.value]);
    _btreeLeafCache.remove([tableUid.value]);
    _navInternalCache.remove([tableUid.value]);
    final prefix = '${tableUid.value}/';
    _navGraphInflight.removeWhere((k, _) => k.startsWith(prefix));
    _btreeStates.removeWhere((k, _) => k.startsWith(prefix));
    _warmedSearchIndexes.removeWhere((k) => k.startsWith(prefix));
  }

  /// Clear nav/leaf caches for a specific index.
  void clearCacheForIndex(TableUid tableUid, IndexUid indexUid) {
    _navGraphCache.remove([tableUid.value, indexUid.value]);
    _btreeLeafClearForIndex(tableUid, indexUid);
    _navInternalCache.remove([tableUid.value, indexUid.value]);
    final key = _cacheKey(tableUid, indexUid);
    _navGraphInflight.remove(key);
    _btreeStates.remove(key);
    _warmedSearchIndexes.remove(key);
  }

  /// Clear all nav/leaf caches.
  void clearCache() {
    _navGraphCache.clear();
    _btreeLeafCache.clear();
    _navInternalCache.clear();
    _navGraphInflight.clear();
    _btreeStates.clear();
    _searchScratchPools.clear();
    _warmedSearchIndexes.clear();
  }

  /// Startup/runtime prewarm: load leaves into the search-hot cache.
  ///
  /// **Open / explicit prewarm only** — must not run on every writeChanges.
  /// Stops once [maxBytes] would be exceeded (OOM guard). Hot leaves
  /// first. Returns bytes added.
  ///
  /// Loads in small batches and yields so [shouldAbort] (close / switchSpace)
  /// can stop promptly — same cooperative pattern as table/index row prewarm.
  Future<int> prewarmLeaves({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required int maxBytes,
    bool Function()? shouldAbort,
  }) async {
    bool aborted() => shouldAbort?.call() ?? false;
    if (maxBytes <= 0 || meta.totalVectors <= 0 || aborted()) return 0;
    return _prewarmBTreeLeaves(
      table: table,
      indexUid: indexUid,
      meta: meta,
      maxBytes: maxBytes,
      shouldAbort: shouldAbort,
    );
  }

  /// Promote flush-dirty leaves into the search-hot cache.
  ///
  void promotePagedLeavesAfterInsertSync({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required Map<NghPagePtr, NghLeafPage> dirtyLeafPages,
    Map<NghPagePtr, NghNavBTreePage> dirtyNavBTreePages = const {},
    Map<NghPageId, NghNavBTreePage> touchedNavPages = const {},
  }) {
    if (_btreeStates[_cacheKey(table.tableUid, indexUid)] == null) return;
    if (dirtyLeafPages.isEmpty &&
        dirtyNavBTreePages.isEmpty &&
        touchedNavPages.isEmpty) {
      return;
    }

    final tableUid = table.tableUid;
    for (final e in touchedNavPages.entries) {
      final id = e.key;
      if (id.isNone || id.pageNo <= 0) continue;
      _navInternalPut(tableUid, indexUid, id, e.value);
    }
    for (final e in dirtyNavBTreePages.entries) {
      final ptr = e.key;
      if (ptr.isNull || ptr.pageNo <= 0) continue;
      // Same search-resident shape as disk prewarm (compact wire decode).
      final shaped =
          NghNavBTreePage.tryDecodePayload(e.value.encodePayload()) ?? e.value;
      _navInternalPut(
        tableUid,
        indexUid,
        NghPageId(ptr.partitionNo, ptr.pageNo),
        shaped,
      );
    }
    for (final e in dirtyLeafPages.entries) {
      final ptr = e.key;
      if (ptr.category != NghDataCategory.leaf) continue;
      if (ptr.isNull || ptr.pageNo <= 0) continue;

      // Wire round-trip → same layout as open+prewarm (compact slots/SQ8/low48).
      // Insert-mutated growable pages stay fragmented and can be ~2× slower on
      // the SQ8 hot loop even when TreeCache hits and low48 is already warm.
      final shaped =
          NghLeafPage.tryDecodePayload(e.value.encodePayload()) ?? e.value;
      final pageId = NghPageId(ptr.partitionNo, ptr.pageNo);
      _btreeLeafPut(tableUid, indexUid, pageId, shaped);
    }
  }

  /// Async flush promote: dirty-batch pin (+ optional cheap JIT after bulk flush).
  Future<void> promotePagedLeavesAfterInsert({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required Map<NghPagePtr, NghLeafPage> dirtyLeafPages,
    Map<NghPagePtr, NghNavBTreePage> dirtyNavBTreePages = const {},
    Map<NghPageId, NghNavBTreePage> touchedNavPages = const {},
    bool Function()? shouldAbort,
  }) async {
    if (_btreeStates[_cacheKey(table.tableUid, indexUid)] == null) return;
    if (dirtyLeafPages.isEmpty &&
        dirtyNavBTreePages.isEmpty &&
        touchedNavPages.isEmpty) {
      return;
    }

    final tableUid = table.tableUid;
    for (final e in touchedNavPages.entries) {
      if (shouldAbort?.call() ?? false) return;
      final id = e.key;
      if (id.isNone || id.pageNo <= 0) continue;
      _navInternalPut(tableUid, indexUid, id, e.value);
    }
    for (final e in dirtyNavBTreePages.entries) {
      if (shouldAbort?.call() ?? false) return;
      final ptr = e.key;
      if (ptr.isNull || ptr.pageNo <= 0) continue;
      final shaped =
          NghNavBTreePage.tryDecodePayload(e.value.encodePayload()) ?? e.value;
      _navInternalPut(
        tableUid,
        indexUid,
        NghPageId(ptr.partitionNo, ptr.pageNo),
        shaped,
      );
    }
    for (final e in dirtyLeafPages.entries) {
      if (shouldAbort?.call() ?? false) return;
      final ptr = e.key;
      if (ptr.category != NghDataCategory.leaf) continue;
      if (ptr.isNull || ptr.pageNo <= 0) continue;

      final shaped =
          NghLeafPage.tryDecodePayload(e.value.encodePayload()) ?? e.value;
      final pageId = NghPageId(ptr.partitionNo, ptr.pageNo);
      _btreeLeafPut(tableUid, indexUid, pageId, shaped);
    }

    final key = _cacheKey(tableUid, indexUid);
    final needWarm = !_warmedSearchIndexes.contains(key);
    if ((needWarm || dirtyLeafPages.length >= 64) &&
        !(shouldAbort?.call() ?? false)) {
      _warmedSearchIndexes.add(key);
      await warmSearchPath(table: table, indexUid: indexUid, meta: meta);
    }
  }

  /// Diagnostic: how many leaves are inventored vs resident in leaf cache.
  ({int inventored, int cached, int leafCacheBytes, int leafCacheMaxBytes})
      btreeLeafCacheCoverage(TableUid tableUid, IndexUid indexUid) {
    final state = _btreeStates[_cacheKey(tableUid, indexUid)];
    if (state == null) {
      return (
        inventored: 0,
        cached: 0,
        leafCacheBytes: _btreeLeafCache.estimatedTotalSizeBytes,
        leafCacheMaxBytes: _btreeLeafCacheMaxBytes,
      );
    }
    final seen = <int>{};
    var inventored = 0;
    var cached = 0;
    // Coverage only counts leaves inventored via currently resident L1 pages.
    void walk(NghNavBTreePage page, int depth) {
      if (depth > NghNavBTreePage.maxTreeHops) return;
      if (page.isLeafLevel) {
        for (final e in page.entries) {
          final id = e.leafPageId;
          if (id.isNone || !seen.add(id.cacheKey)) continue;
          inventored++;
          if (_btreeLeafGet(tableUid, indexUid, id, touch: false) != null) {
            cached++;
          }
        }
        return;
      }
      for (final e in page.entries) {
        if (e.childPageId.isNone) continue;
        final child =
            _navInternalGet(tableUid, indexUid, e.childPageId, touch: false);
        if (child != null) walk(child, depth + 1);
      }
    }

    for (int rootId = 0; rootId < state.numRootCentroids; rootId++) {
      final head = state.firstInternalByRoot[rootId];
      if (head.isNone) continue;
      final page = _navInternalGet(tableUid, indexUid, head, touch: false);
      if (page != null) walk(page, 0);
    }
    return (
      inventored: inventored,
      cached: cached,
      leafCacheBytes: _btreeLeafCache.estimatedTotalSizeBytes,
      leafCacheMaxBytes: _btreeLeafCacheMaxBytes,
    );
  }

  /// Prefetch leaves into [_btreeLeafCache] under [maxBytes].
  ///
  /// Hottest leaves (highest [CentroidBranchEntry.leafSlotCount]) first so
  /// typical ANN probes hit memory on the first query after open/insert.
  Future<int> _prewarmBTreeLeaves({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required int maxBytes,
    bool Function()? shouldAbort,
  }) async {
    bool aborted() => shouldAbort?.call() ?? false;
    if (maxBytes <= 0 || aborted()) return 0;

    final state = await _getOrLoadBTreeState(table, indexUid, meta);
    if (state == null || aborted()) return 0;

    // Budget-load L1 pages so leaf candidates can be ranked.
    await _hydrateNavChainsForRoots(
      table: table,
      indexUid: indexUid,
      meta: meta,
      state: state,
      rootIds: Iterable<int>.generate(state.numRootCentroids),
      shouldAbort: shouldAbort,
    );
    if (aborted()) return 0;

    final beforeBytes = _btreeLeafCache.estimatedTotalSizeBytes;
    final candidates = <({NghPageId id, int slots})>[];
    final seen = <int>{};

    void collectFromNavPage(NghNavBTreePage page, int depth) {
      if (depth > NghNavBTreePage.maxTreeHops) return;
      if (page.isLeafLevel) {
        for (final e in page.entries) {
          final id = e.leafPageId;
          if (id.isNone) continue;
          if (!seen.add(id.cacheKey)) continue;
          final cached = _btreeLeafGet(table.tableUid, indexUid, id);
          if (cached != null) {
            cached.ensureLow48Ready();
            continue;
          }
          candidates.add((id: id, slots: max(1, e.leafSlotCount)));
        }
        return;
      }
      for (final e in page.entries) {
        if (e.childPageId.isNone) continue;
        final child = _navInternalGet(
          table.tableUid,
          indexUid,
          e.childPageId,
          touch: false,
        );
        if (child != null) collectFromNavPage(child, depth + 1);
      }
    }

    for (int rootId = 0; rootId < state.numRootCentroids; rootId++) {
      final head = state.firstInternalByRoot[rootId];
      if (head.isNone) continue;
      final page = _navInternalGet(
        table.tableUid,
        indexUid,
        head,
        touch: false,
      );
      if (page != null) collectFromNavPage(page, 0);
    }
    if (candidates.isEmpty) {
      return max(0, _btreeLeafCache.estimatedTotalSizeBytes - beforeBytes);
    }

    candidates.sort((a, b) => b.slots.compareTo(a.slots));

    final bytesPerSlot = 24 + meta.dimensions + 192;
    var planned = 0;
    final toLoad = <NghPageId>[];
    final room = max(0, maxBytes - _btreeLeafCache.estimatedTotalSizeBytes);
    for (final c in candidates) {
      if (aborted()) break;
      final est = c.slots * bytesPerSlot;
      if (planned + est > room && toLoad.isNotEmpty) break;
      if (est > room && toLoad.isEmpty) {
        toLoad.add(c.id);
        break;
      }
      if (planned + est > room) break;
      planned += est;
      toLoad.add(c.id);
    }

    const batchSize = 32;
    final yieldController =
        YieldController('NghGraphEngine.prewarmBTreeLeaves', checkInterval: 1);
    for (var i = 0; i < toLoad.length && !aborted(); i += batchSize) {
      final y = yieldController.maybeYield();
      if (y != null) await y;
      if (aborted()) break;
      if (_btreeLeafCache.estimatedTotalSizeBytes >= maxBytes) break;
      final chunk = toLoad.sublist(i, min(i + batchSize, toLoad.length));
      await _hydrateBTreeLeaves(
        table: table,
        indexUid: indexUid,
        meta: meta,
        leafIds: chunk,
      );
    }

    return max(0, _btreeLeafCache.estimatedTotalSizeBytes - beforeBytes);
  }

  /// Batch-load missing leaves into [_btreeLeafCache] and materialize low48.
  /// Hot path returns a completed future without scheduling when all pages are resident.
  Future<void> _hydrateBTreeLeaves({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required Iterable<NghPageId> leafIds,
    Map<NghPageId, NghLeafPage>? insertScratch,
  }) {
    final missing = <NghPageId>[];
    for (final id in leafIds) {
      if (id.isNone) continue;
      final scratch = insertScratch?[id];
      if (scratch != null) {
        scratch.ensureLow48Ready();
        continue;
      }
      final cached = _btreeLeafGet(table.tableUid, indexUid, id);
      if (cached != null) {
        // Already in TreeCache — low48 materialised on put/prewarm.
        continue;
      }
      missing.add(id);
    }
    if (missing.isEmpty) return Future<void>.value();

    return _hydrateBTreeLeavesIO(
      table: table,
      indexUid: indexUid,
      meta: meta,
      missing: missing,
      insertScratch: insertScratch,
    );
  }

  Future<void> _hydrateBTreeLeavesIO({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required List<NghPageId> missing,
    Map<NghPageId, NghLeafPage>? insertScratch,
  }) async {
    // Keep search-hot leaves in [_btreeLeafCache] only — do not also park them
    // in the leaf I/O fill cache (double residency → GC / quota thrash).
    final loaded = await _partitionManager.readLeafPagesByIds(
      table,
      indexUid,
      meta,
      missing,
      populatePageCache: false,
    );
    for (final item in loaded) {
      if (insertScratch != null) {
        item.page.ensureLow48Ready();
        insertScratch.putIfAbsent(item.id, () => item.page);
      } else {
        _btreeLeafPut(table.tableUid, indexUid, item.id, item.page);
      }
    }
  }

  /// Compile hot ANN loops and populate routing/leaf caches after prewarm.
  Future<void> warmSearchPath({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
  }) async {
    if (meta.totalVectors <= 0 || meta.dimensions <= 0) return;
    _warmedSearchIndexes.add(_cacheKey(table.tableUid, indexUid));
    final dims = meta.dimensions;
    final q = Float32List(dims);
    // A few distinct unit probes so Tier-2 JIT sees the real ranking loops
    // (matches tool/test_centroid_btree_engine warmup intent, but cheap).
    const probes = 8;
    for (var p = 0; p < probes; p++) {
      final inv = 1.0 / sqrt(dims.toDouble());
      final phase = (p * 17) % dims;
      for (var i = 0; i < dims; i++) {
        q[i] = ((i + phase) % 3 == 0) ? inv : -inv * 0.5;
      }
      // Renormalize for cosine.
      if (meta.distanceMetric == VectorDistanceMetric.cosine) {
        var nSq = 0.0;
        for (var i = 0; i < dims; i++) {
          nSq += q[i] * q[i];
        }
        final n = sqrt(nSq);
        if (n > 0) {
          final s = 1.0 / n;
          for (var i = 0; i < dims; i++) {
            q[i] *= s;
          }
        }
      }
      await search(
        table: table,
        indexUid: indexUid,
        meta: meta,
        query: q,
        topK: 10,
        searchDepth: 1,
        queryAlreadyNormalized:
            meta.distanceMetric == VectorDistanceMetric.cosine,
      );
    }
  }

  // =====================================================================
  // Centroid B+Tree (Zero-LSM Hierarchical Navigation Engine)
  // ============================================================================

  /// Fold any-D vector into a fixed 48-D routing sketch (L2-normalized).
  ///
  /// For D≤48 this is the vector itself (zero-pad). For D>48 every coordinate
  /// contributes via `d % 48` bins — same path for 128…65535, no per-D branch
  /// tables. The old "first 48 dims only" prefix destroyed high-D recall
  /// (top1 stayed high, R@10 collapsed) because most signal lives past dim 48.
  static Float32List _extractLow48(Float32List full) {
    final low = Float32List(48);
    _extractLow48Into(full, low);
    return low;
  }

  /// Write normalized 48-D routing sketch into [out] (no allocation).
  /// Pass resident [fullSimd]/[outSimd] to avoid per-query typed-data views.
  @pragma('vm:prefer-inline')
  static void _extractLow48Into(
    Float32List full,
    Float32List out, {
    Float32x4List? fullSimd,
    Float32x4List? outSimd,
  }) {
    final n = full.length;
    if (n <= 48) {
      // Identity sketch — same as legacy for D≤48.
      if (n == 48 &&
          fullSimd != null &&
          outSimd != null &&
          fullSimd.length >= 12 &&
          outSimd.length >= 12) {
        final src = fullSimd;
        final dst = outSimd;
        var sum0 = Float32x4.zero();
        var sum1 = Float32x4.zero();
        var sum2 = Float32x4.zero();
        for (int i = 0; i < 12; i += 3) {
          final a = src[i];
          final b = src[i + 1];
          final c = src[i + 2];
          dst[i] = a;
          dst[i + 1] = b;
          dst[i + 2] = c;
          sum0 += a * a;
          sum1 += b * b;
          sum2 += c * c;
        }
        final sum = (sum0 + sum1) + sum2;
        final normSq = sum.x + sum.y + sum.z + sum.w;
        if (normSq > 0) {
          final inv = Float32x4.splat(1.0 / sqrt(normSq));
          for (int i = 0; i < 12; i++) {
            dst[i] = dst[i] * inv;
          }
        }
        return;
      }
      double norm = 0.0;
      for (int d = 0; d < n; d++) {
        out[d] = full[d];
        norm += full[d] * full[d];
      }
      for (int d = n; d < 48; d++) {
        out[d] = 0.0;
      }
      if (norm > 0) {
        final inv = 1.0 / sqrt(norm);
        for (int d = 0; d < n; d++) {
          out[d] *= inv;
        }
      }
      return;
    }

    // D>48: fold all coordinates into 48 bins (dim-agnostic).
    // Chunked add avoids per-element modulo — hot on every 128–768D query.
    // Independent bins: SIMD += is bit-identical to scalar += per bin.
    for (int i = 0; i < 48; i++) {
      out[i] = 0.0;
    }
    final fullChunks = n - (n % 48);
    var d = 0;
    final src = fullSimd;
    final dst = outSimd;
    if (fullChunks >= 48 &&
        src != null &&
        dst != null &&
        src.length >= (fullChunks >> 2) &&
        dst.length >= 12) {
      var a0 = Float32x4.zero();
      var a1 = Float32x4.zero();
      var a2 = Float32x4.zero();
      var a3 = Float32x4.zero();
      var a4 = Float32x4.zero();
      var a5 = Float32x4.zero();
      var a6 = Float32x4.zero();
      var a7 = Float32x4.zero();
      var a8 = Float32x4.zero();
      var a9 = Float32x4.zero();
      var a10 = Float32x4.zero();
      var a11 = Float32x4.zero();
      while (d < fullChunks) {
        final base = d >> 2;
        a0 += src[base];
        a1 += src[base + 1];
        a2 += src[base + 2];
        a3 += src[base + 3];
        a4 += src[base + 4];
        a5 += src[base + 5];
        a6 += src[base + 6];
        a7 += src[base + 7];
        a8 += src[base + 8];
        a9 += src[base + 9];
        a10 += src[base + 10];
        a11 += src[base + 11];
        d += 48;
      }
      dst[0] = a0;
      dst[1] = a1;
      dst[2] = a2;
      dst[3] = a3;
      dst[4] = a4;
      dst[5] = a5;
      dst[6] = a6;
      dst[7] = a7;
      dst[8] = a8;
      dst[9] = a9;
      dst[10] = a10;
      dst[11] = a11;
    } else {
      while (d < fullChunks) {
        for (int i = 0; i < 48; i++) {
          out[i] += full[d + i];
        }
        d += 48;
      }
    }
    while (d < n) {
      out[d - fullChunks] += full[d];
      d++;
    }
    double norm = 0.0;
    for (int i = 0; i < 48; i++) {
      norm += out[i] * out[i];
    }
    if (norm > 0) {
      final inv = 1.0 / sqrt(norm);
      for (int i = 0; i < 48; i++) {
        out[i] *= inv;
      }
    }
  }

  List<Float32List> _kMeansInit48({
    required List<Float32List> samples,
    required int k,
    int iterations = 6,
  }) {
    final rand = Random(42);
    final n = samples.length;
    final centers = <Float32List>[];
    for (int i = 0; i < k; i++) {
      centers.add(Float32List.fromList(samples[rand.nextInt(n)]));
    }

    for (int iter = 0; iter < iterations; iter++) {
      final counts = Int32List(k);
      final sums = List.generate(k, (_) => Float32List(48));
      for (int i = 0; i < n; i++) {
        final s = samples[i];
        final sSimd = Float32x4List.sublistView(s);
        int bestC = 0;
        double maxSim = -1e9;
        for (int c = 0; c < k; c++) {
          final cSimd = Float32x4List.sublistView(centers[c]);
          final sim = innerProduct48(sSimd, cSimd, 0);
          if (sim > maxSim) {
            maxSim = sim;
            bestC = c;
          }
        }
        counts[bestC]++;
        for (int d = 0; d < 48; d++) {
          sums[bestC][d] += s[d];
        }
      }

      for (int c = 0; c < k; c++) {
        if (counts[c] == 0) continue;
        double norm = 0.0;
        for (int d = 0; d < 48; d++) {
          sums[c][d] /= counts[c];
          norm += sums[c][d] * sums[c][d];
        }
        norm = sqrt(norm);
        if (norm > 0) {
          for (int d = 0; d < 48; d++) {
            centers[c][d] = sums[c][d] / norm;
          }
        }
      }
    }
    return centers;
  }

  Future<CentroidBTreeState?> _getOrLoadBTreeState(
    TableContext table,
    IndexUid indexUid,
    NghIndexMeta meta,
  ) {
    final key = _cacheKey(table.tableUid, indexUid);
    final cached = _btreeStates[key];
    if (cached != null) return Future<CentroidBTreeState?>.value(cached);
    return _loadBTreeState(table, indexUid, meta, key);
  }

  Future<CentroidBTreeState?> _loadBTreeState(
    TableContext table,
    IndexUid indexUid,
    NghIndexMeta meta,
    String key,
  ) async {
    final rootPage = await _partitionManager.readNavRootPage(
      table,
      indexUid,
      meta: meta,
      partitionNo: 0,
      pageNo: 1,
    );
    if (rootPage == null || rootPage.roots.isEmpty) {
      return null;
    }

    var nextCentroidId = max(rootPage.nextCentroidId, rootPage.roots.length);
    var rootTableNeedsPersist = false;
    // Indexes written before nextCentroidId persistence leave the field at 0.
    // One-time walk recovers the high-water id so leaf splits cannot collide.
    if (rootPage.nextCentroidId <= 0 && meta.totalVectors > 0) {
      var recoveryIncomplete = false;
      for (final r in rootPage.roots) {
        // BFS under one L0 root (mid children until leaf-level).
        final queue = <NghPageId>[r.firstInternalPage];
        final seen = <int>{};
        var hops = 0;
        while (queue.isNotEmpty) {
          final curr = queue.removeAt(0);
          if (curr.isNone || !seen.add(curr.cacheKey)) continue;
          if (++hops > 4096) {
            recoveryIncomplete = true;
            break;
          }
          final page = await _partitionManager.readNavBTreePage(
            table,
            indexUid,
            curr,
            meta: meta,
          );
          if (page == null) {
            recoveryIncomplete = true;
            continue;
          }
          for (final e in page.entries) {
            if (e.centroidId > nextCentroidId) nextCentroidId = e.centroidId;
            if (!page.isLeafLevel && !e.childPageId.isNone) {
              queue.add(e.childPageId);
            }
          }
          // Do not pin recovered pages here — open must stay L0-resident.
        }
      }
      // Persist on next mutation so cold starts do not re-walk every launch.
      rootTableNeedsPersist = true;
      // Hole mid-chain: ids past the hole were not observed. Jump far ahead
      // of the observed max to avoid colliding with unreadable tail entries.
      if (recoveryIncomplete) {
        nextCentroidId = max(nextCentroidId + 1, nextCentroidId | 0x100000);
      }
    }

    final pageFit = _maxL0RootsForNavPageSize(_navPageSize(meta));
    final state = CentroidBTreeState(
      numRootCentroids: rootPage.roots.length,
      rootPageId: const NghPageId(0, 1),
      nextCentroidId: nextCentroidId,
      rootTableNeedsPersist: rootTableNeedsPersist,
      // Never shrink an already-persisted root table; only cap further growth.
      maxRoots: min(
        CentroidBTreeState.maxRootCapacity,
        max(pageFit, rootPage.roots.length),
      ),
    );

    for (int i = 0; i < rootPage.roots.length; i++) {
      final r = rootPage.roots[i];
      final c = r.centroid48D;
      final rootId = r.rootId;
      if (rootId < 0 || rootId >= state.numRootCentroids) continue;
      for (int d = 0; d < 48; d++) {
        state.rootCentroids48Flat[rootId * 48 + d] = c[d];
      }
      // L0-only open: record chain head; L1 pages load on probe into TreeCache.
      state.loadFirstInternal(rootId, r.firstInternalPage);
    }

    _btreeStates[key] = state;
    return state;
  }

  /// Map [searchDepth], corpus size and [topK] to Centroid B+Tree probe plan.
  ///
  /// LOCKED scale contract (tens of billions — do not weaken for recall patches):
  /// - Depth is recall-*intent*. Depth has **no hard max**: 1→100 is the primary
  ///   band; depth>100 continues the same 50→100 Δbudget/Δdepth so a user who
  ///   is short of recall at depth=100 can keep tuning (escape hatch).
  /// - Anchors: 1→~91% (±5), 50→~95% (±3), 100→~98% (±5) inside the
  ///   interactive leaf band. Hold large-N recall by precise L0/mid routing;
  ///   never by auto-growing wantLeaves with N (throughput cliff at 1e7+).
  /// - depth≤100: wantLeaves hard-capped by interactive band (~14 / 28 / 44).
  /// - depth>100: continues that slope up to [_absScoredLeafCap] (256) — never
  ///   inventory-wide / 1024 brute force.
  /// - Mild continuous log10(N) hedge (knee ~16k) only inside those caps —
  ///   ~+0 @10k (QPS), ~+1 @30k, ~+4 @1M. Not a per-N special case.
  static ({int wantRoots, int wantLeaves, int candSlots})
      _resolveCentroidBTreeProbePlan({
    required int totalVectors,
    required int topK,
    required int dimensions,
    int leafPageSize = 16384,

    /// Live leaf page count when known (`leafNextPageNo - first`).
    /// Prefer this over N/spp — underfull + dual-home pages exceed packing.
    int leafPageCount = 0,
    int? searchDepth,
  }) {
    final rawDepth = searchDepth ?? VectorIndexConfig.defaultSearchDepth;
    final depth = max(1, rawDepth);

    // Post-rebuild: 10k stays lean (logN knees inactive). Mid-N (50k–1M)
    // was below 91/95 anchors because dens-trim + late largeN hedge.
    // Continuous log10(N) only — no discrete N switches.
    final logN = log(max(1000, totalVectors).toDouble()) / ln10;
    final midN = max(0.0, logN - 5.3); // 0 @≤200k; ~0.7 @1M
    final largeN = max(0.0, logN - 5.5); // 0 @≤300k; ~0.5 @1M
    final scaleLeaves = max(0.0, (logN - 4.2) * 1.5).round() +
        max(0.0, (logN - 5.0) * 1.2).round() +
        (midN * 2.0).round() +
        (largeN * 2.0).round(); // 50k:~1; 1M:~3+1+1+1=6
    final scaleRoots = max(0.0, (logN - 4.2) * 1.5).round() +
        max(0.0, (logN - 4.7) * 1.5).round() +
        max(0.0, (logN - 5.5) * 2.5).round() +
        (largeN * 2.0).round();
    final scaleSlots = max(0.0, (logN - 4.2) * 2.5).round() +
        max(0.0, (logN - 5.0) * 1.5).round() +
        (midN * 2.0).round();

    // Lean low-depth bases (≤50k calibrated). Mid/high N uses scale* above.
    const leaf1 = 5.0;
    const leaf50 = 10.0;
    const leaf100 = 18.0;
    const root50 = 6.0;
    const root100 = 10.0;
    const tipLeaves100 = 7; // hold ~98% @depth100
    const tipRoots100 = 3;
    const tipSlots100 = 6;
    const leafSlope50 = (leaf100 + tipLeaves100 - leaf50) / 50.0; // 0.30
    const rootSlope50 = (root100 + tipRoots100 - root50) / 50.0; // 0.14
    const slotSlope50 = (34.0 + tipSlots100 - 18.0) / 50.0; // 0.44

    // 1. Leaf pages probed (cheap 48-D page scan → then SQ8 score those leaves)
    final int baseLeaves;
    if (depth <= 1) {
      baseLeaves = leaf1.round();
    } else if (depth <= 50) {
      baseLeaves = (leaf1 + (leaf50 - leaf1) * ((depth - 1) / 49.0)).round();
    } else if (depth <= 100) {
      baseLeaves =
          (leaf50 + (leaf100 - leaf50) * ((depth - 50) / 50.0)).round();
    } else {
      // CRITICAL: continue from interactive depth-100 ceiling (44), not bare
      // leaf100 (20). Otherwise depth 101 regresses vs depth 100 and the
      // escape hatch is useless when recall is already short at 100.
      baseLeaves =
          (_maxInteractiveLeaves + leafSlope50 * (depth - 100)).round();
    }
    var leaves = max(1,
        baseLeaves + (depth <= 1 ? (scaleLeaves * 0.7).round() : scaleLeaves));

    // 2. Root centroids probed (cheap 48-D; inventory-capped at search time)
    final int baseRoots;
    if (depth <= 30) {
      baseRoots = 4;
    } else if (depth <= 70) {
      baseRoots = 5 + (largeN * 2.0).round(); // +1 @1M mid band
    } else if (depth <= 100) {
      baseRoots =
          (7.0 + 2.0 * ((depth - 70) / 30.0)).round() + (largeN * 2.0).round();
    } else {
      final at100Roots = root100 + tipRoots100; // 13
      baseRoots = (at100Roots + rootSlope50 * (depth - 100)).round();
    }
    var roots = max(
        1, baseRoots + (depth <= 1 ? (scaleRoots * 0.75).round() : scaleRoots));

    //   Two-step bake ≈ original×0.5 kept R@10 at depth 1/50/98 identical to the
    //   pre-cut baseline on that corpus while roughly doubling QPS. Leaf/root
    //   cuts were weaker and more recall-sensitive — left alone.
    final s1 = max(topK * 2, 10);
    final s50 = max(topK * 2 + 2, 18);
    final s100 = max(topK * 3 + 4, 34);
    final int baseCandSlots;
    if (depth <= 1) {
      baseCandSlots = s1;
    } else if (depth <= 50) {
      baseCandSlots = (s1 + (s50 - s1) * ((depth - 1) / 49.0)).round();
    } else if (depth <= 100) {
      baseCandSlots = (s50 + (s100 - s50) * ((depth - 50) / 50.0)).round();
    } else {
      baseCandSlots =
          (s100 + tipSlots100 + slotSlope50 * (depth - 100)).round();
    }
    var slots = max(topK, baseCandSlots + scaleSlots);

    // Depth 80–98: mild ramp. ≥200k gets a light high-depth leaf tip so 1M
    // depth100 returns toward ~98% without ≤50k cost.
    // Depth 99–100: tip. Depth >100: tip folded into continue-from-ceiling.
    if (depth >= 80 && depth < 99) {
      final ramp = depth - 79; // 1@80 … 19@98
      leaves += 1 + ramp ~/ 7; // +1@80 … +3@98
      slots += 1 + ramp ~/ 4;
      if (depth >= 90) roots += 1;
      if (depth >= 90) {
        final bridge =
            max(0.0, (logN - 5.0) * 5.0).round() + (largeN * 4.0).round();
        leaves += bridge;
        slots += bridge * 2;
      }
    } else if (depth >= 99 && depth <= 100) {
      final tip = min(2, depth - 98); // 1 @99, 2 @100
      roots += tip * 2;
      leaves += tip * 3;
      slots += tip * 6;
      final bridge =
          max(0.0, (logN - 5.0) * 5.0).round() + (largeN * 4.0).round();
      leaves += bridge;
      slots += bridge * 2;
    }

    // Mid-band (≥40): 50-anchor valley was 100k–1M because largeN is 0
    // until ~300k. Start a light continuous boost at ~50k (4.7).
    if (depth >= 40 && depth <= 70) {
      final midBoost =
          max(0.0, (logN - 4.7) * 3.5).round() + (largeN * 4.0).round();
      leaves += midBoost;
      slots += midBoost * 2;
    }

    // Density compensation vs the ~20-slot 768D calibration leaf:
    // - dens>1.25 (low-D packed): trim leaf *count* only. Do not inflate
    //   candSlots/roots — denser pages already fill the heap.
    // - slotsPerPage<8 (high-D sparse): raise leaf count for candidate volume.
    // - Inventory: real leaf pages ∪ dual-home floor (never ceil(N/spp)=1).
    // No ≤50k qpsLean on depth≤70 — that cut 128D/~10k recall far below
    // anchors whether the tree was one-shot or incremental.
    const refSlotsPerPage = 20.0;
    final slotsPerPage = NghPageSizer.estimateLeafSlotsPerPage(
      max(4096, leafPageSize),
      max(1, dimensions),
    ).toDouble();
    final dens = slotsPerPage / refSlotsPerPage;
    final spp = max(1.0, slotsPerPage);
    final packedLeaves = max(1, (totalVectors / spp).ceil());
    // Never let a stale/low leafNextPageNo (or packed N/spp=1) pin
    // wantLeaves at 1 — dual-home + underfull pages exceed packing, and
    // `leafPageCount > 0` must not *replace* that floor.
    final dualHomeFloor =
        min(_absScoredLeafCap, min(totalVectors, packedLeaves * 3 + 2));
    final inventoryLeaves = max(
      1,
      max(
        packedLeaves,
        max(leafPageCount, dualHomeFloor),
      ),
    );

    final tinyCover = (1.0 -
            max(0.0,
                (log(max(16, totalVectors).toDouble()) / ln10 - 1.2) / 1.6))
        .clamp(0.0, 1.0);
    if (dens > 1.25) {
      leaves = max(1, (leaves / dens).round());
      // nBump follows depth so 1M+ does not pin depth1 near the depth100
      // floor (searchDepth would collapse). 10k nBump=0 unchanged.
      final nBump = max(0.0, (logN - 4.2) * 2.0).round() +
          max(0.0, (logN - 5.0) * 2.0).round();
      final nBumpScaled = depth <= 1
          ? (nBump * 0.55).round()
          : depth <= 50
              ? (nBump * 0.65).round()
              : nBump;
      final d1Min = logN >= 4.8 ? 4 : 3;
      final minLeaves =
          (depth <= 1 ? d1Min : (depth <= 50 ? 5 : (depth <= 98 ? 8 : 12))) +
              nBumpScaled;
      leaves = max(minLeaves, leaves);
      slots = max(topK, (slots / (0.95 + 0.15 * dens)).round());
    } else if (slotsPerPage < 8) {
      // Target the same candidate *count* as 768D at this depth, not leaf×20
      // blindly when spp=1 (that forced wantLeaves→100–256 and full-D SQ8
      // on nearly the whole tiny corpus).
      final targetCand = max(topK * 24, (leaves * refSlotsPerPage).round());
      final needLeaves = max(leaves, (targetCand / spp).ceil());
      leaves = min(needLeaves, inventoryLeaves);
      slots = max(slots, min(2048, leaves * spp.round() + topK));
    }

    // HARD CAPS — interactive band. Sparse pages may raise the cap enough to
    // hit targetCand, but never above inventory or abs scored-leaf cap.
    final leafCap = _maxLeavesForDepth(
      depth,
      nLeaves: 1 << 20,
      totalVectors: totalVectors,
    );
    final sparseFactor = slotsPerPage < 8
        ? min(8.0, refSlotsPerPage / spp) // was uncapped 20 → depth1 hit 256
        : 1.0;
    final capRelief = depth >= 80
        ? max(0.0, (logN - 5.0) * 4.0).round() + (largeN * 4.0).round()
        : depth >= 40
            ? (largeN * 2.0).round()
            : 0;
    final effectiveCap = min(
      _absScoredLeafCap,
      min(inventoryLeaves, (leafCap * sparseFactor).round() + capRelief),
    );
    leaves = min(leaves, effectiveCap);
    // High-depth large-N: add after dens-trim so depth100 can sit ~2–3pp
    // above depth50. Depth1 does not get this.
    if (depth >= 90) {
      final highN =
          max(0.0, (logN - 5.0) * 5.0).round() + (largeN * 4.0).round();
      leaves = min(effectiveCap, leaves + highN);
    }
    if (tinyCover > 0) {
      final coverLeaves = max(
        1,
        min(inventoryLeaves, (inventoryLeaves * tinyCover).ceil()),
      );
      leaves = max(leaves, min(effectiveCap, coverLeaves));
      roots = max(roots, min(256, (4 + 28 * tinyCover).round()));
      slots = max(slots, min(totalVectors, (totalVectors * tinyCover).ceil()));
    }
    slots = min(slots, leaves * _typicalLeafSlots);

    return (
      wantRoots: min(256, roots),
      wantLeaves: leaves,
      candSlots: min(2048, slots),
    );
  }

  Future<List<NghSearchResult>> _searchCentroidBTree({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required CentroidBTreeState state,
    required Float32List query,
    required int topK,
    int? searchDepth,
    double? distanceThreshold,
    bool queryAlreadyNormalized = false,
    Set<String>? pendingDeletePks,
  }) {
    final scratch = _acquireSearchScratch(meta.dimensions);
    try {
      final hot = _searchCentroidBTreeTryHot(
        table: table,
        indexUid: indexUid,
        meta: meta,
        state: state,
        scratch: scratch,
        query: query,
        topK: topK,
        searchDepth: searchDepth,
        distanceThreshold: distanceThreshold,
        queryAlreadyNormalized: queryAlreadyNormalized,
        pendingDeletePks: pendingDeletePks,
        allowHydrate: true,
      );
      if (hot.sync != null) {
        final out = hot.sync!;
        _releaseSearchScratch(scratch);
        return Future<List<NghSearchResult>>.value(out);
      }
      final fut = hot.async;
      if (fut == null) {
        _releaseSearchScratch(scratch);
        return Future<List<NghSearchResult>>.value(const []);
      }
      // Keep scratch rented until async hydrate/rank finishes.
      return fut.whenComplete(() => _releaseSearchScratch(scratch));
    } catch (_) {
      _releaseSearchScratch(scratch);
      rethrow;
    }
  }

  /// Shared Centroid B+Tree probe. When [allowHydrate] is false and leaves are
  /// missing, returns sync=null / async=null (caller treats as cold miss).
  /// L1 cache misses hydrate into a query-local pin — never hard-throw for
  /// eviction/thrash (mobile kill + memory pressure must stay recoverable).
  /// [scratch] is rented for this query only (safe under concurrent search).
  ({List<NghSearchResult>? sync, Future<List<NghSearchResult>>? async})
      _searchCentroidBTreeTryHot({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required CentroidBTreeState state,
    required _CentroidSearchScratch scratch,
    required Float32List query,
    required int topK,
    int? searchDepth,
    double? distanceThreshold,
    bool queryAlreadyNormalized = false,
    Set<String>? pendingDeletePks,
    bool allowHydrate = false,
  }) {
    final isCosine = meta.distanceMetric == VectorDistanceMetric.cosine;
    final isIP = meta.distanceMetric == VectorDistanceMetric.innerProduct;

    Float32List searchQuery = query;
    if (isCosine && !queryAlreadyNormalized) {
      // Normalize into scratch — avoid per-query Float32List alloc.
      _normalizeFloat32Into(query, scratch.scratchQFull);
      searchQuery = scratch.scratchQFull;
    }

    final searchQuerySimd = identical(searchQuery, scratch.scratchQFull)
        ? scratch.scratchQFullSimd
        : ((searchQuery.offsetInBytes & 15) == 0 && searchQuery.length >= 4
            ? Float32x4List.view(
                searchQuery.buffer,
                searchQuery.offsetInBytes,
                searchQuery.length >> 2,
              )
            : null);

    _extractLow48Into(
      searchQuery,
      scratch.scratchQLow,
      fullSimd: searchQuerySimd,
      outSimd: scratch.scratchQLowSimd,
    );
    final qLowSimd = scratch.scratchQLowSimd;
    // SIMD sum of query (matches tool/test_centroid_btree_engine.dart).
    double qFullSum;
    final dim = meta.dimensions;
    final qFullAligned = (searchQuery.offsetInBytes & 15) == 0;
    if (dim >= 16 && (searchQuerySimd != null || qFullAligned)) {
      final n4 = dim >> 2;
      final qSimd = searchQuerySimd ??
          Float32x4List.view(searchQuery.buffer, searchQuery.offsetInBytes, n4);
      var sum0 = Float32x4.zero();
      var sum1 = Float32x4.zero();
      var sum2 = Float32x4.zero();
      var sum3 = Float32x4.zero();
      int i = 0;
      final unroll = n4 - 3;
      while (i < unroll) {
        sum0 += qSimd[i];
        sum1 += qSimd[i + 1];
        sum2 += qSimd[i + 2];
        sum3 += qSimd[i + 3];
        i += 4;
      }
      while (i < n4) {
        sum0 += qSimd[i];
        i++;
      }
      final sumAll = (sum0 + sum1) + (sum2 + sum3);
      qFullSum = sumAll.x + sumAll.y + sumAll.z + sumAll.w;
      for (int d = n4 << 2; d < dim; d++) {
        qFullSum += searchQuery[d];
      }
    } else {
      qFullSum = 0.0;
      int qd = 0;
      final unroll16Sum = dim - 15;
      while (qd < unroll16Sum) {
        qFullSum += (searchQuery[qd] + searchQuery[qd + 1]) +
            (searchQuery[qd + 2] + searchQuery[qd + 3]) +
            (searchQuery[qd + 4] + searchQuery[qd + 5]) +
            (searchQuery[qd + 6] + searchQuery[qd + 7]) +
            (searchQuery[qd + 8] + searchQuery[qd + 9]) +
            (searchQuery[qd + 10] + searchQuery[qd + 11]) +
            (searchQuery[qd + 12] + searchQuery[qd + 13]) +
            (searchQuery[qd + 14] + searchQuery[qd + 15]);
        qd += 16;
      }
      while (qd < dim) {
        qFullSum += searchQuery[qd];
        qd++;
      }
    }

    scratch.nextQueryStamp();

    final q0 = qLowSimd[0];
    final q1 = qLowSimd[1];
    final q2 = qLowSimd[2];
    final q3 = qLowSimd[3];
    final q4 = qLowSimd[4];
    final q5 = qLowSimd[5];
    final q6 = qLowSimd[6];
    final q7 = qLowSimd[7];
    final q8 = qLowSimd[8];
    final q9 = qLowSimd[9];
    final q10 = qLowSimd[10];
    final q11 = qLowSimd[11];

    final plan = _resolveCentroidBTreeProbePlan(
      totalVectors: meta.totalVectors,
      topK: topK,
      dimensions: meta.dimensions,
      leafPageSize: _leafPageSize(meta),
      leafPageCount: max(
            0,
            meta.leafNextPageNo - NghIndexMeta.firstDataPageNo,
          ) +
          max(0, meta.leafPartitionCount - 1),
      searchDepth: searchDepth,
    );

    // 1. Level 0: score every root (test-tool hot path). Empty roots are
    // cheap to score and skipped at L1 — avoid Map + nested emptiness scans.
    final numRoots = state.numRootCentroids;
    final wantRoots = plan.wantRoots;
    final rootSimd = state.rootCentroids48Simd;
    int rootsToProbe = 0;

    if (wantRoots <= 6) {
      // Register-track top-R (R≤6 covers depth≤70 default plan).
      int r0 = 0, r1 = 0, r2 = 0, r3 = 0, r4 = 0, r5 = 0;
      double s0 = -1e9, s1 = -1e9, s2 = -1e9, s3 = -1e9, s4 = -1e9, s5 = -1e9;
      for (int i = 0; i < numRoots; i++) {
        final s = innerProduct48Reg(
          q0,
          q1,
          q2,
          q3,
          q4,
          q5,
          q6,
          q7,
          q8,
          q9,
          q10,
          q11,
          rootSimd,
          i * 12,
        );
        if (s > s0) {
          s5 = s4;
          r5 = r4;
          s4 = s3;
          r4 = r3;
          s3 = s2;
          r3 = r2;
          s2 = s1;
          r2 = r1;
          s1 = s0;
          r1 = r0;
          s0 = s;
          r0 = i;
        } else if (s > s1) {
          s5 = s4;
          r5 = r4;
          s4 = s3;
          r4 = r3;
          s3 = s2;
          r3 = r2;
          s2 = s1;
          r2 = r1;
          s1 = s;
          r1 = i;
        } else if (s > s2) {
          s5 = s4;
          r5 = r4;
          s4 = s3;
          r4 = r3;
          s3 = s2;
          r3 = r2;
          s2 = s;
          r2 = i;
        } else if (s > s3) {
          s5 = s4;
          r5 = r4;
          s4 = s3;
          r4 = r3;
          s3 = s;
          r3 = i;
        } else if (s > s4) {
          s5 = s4;
          r5 = r4;
          s4 = s;
          r4 = i;
        } else if (s > s5) {
          s5 = s;
          r5 = i;
        }
      }
      rootsToProbe = min(wantRoots, numRoots);
      if (rootsToProbe > 0) scratch.probedRoots[0] = r0;
      if (rootsToProbe > 1) scratch.probedRoots[1] = r1;
      if (rootsToProbe > 2) scratch.probedRoots[2] = r2;
      if (rootsToProbe > 3) scratch.probedRoots[3] = r3;
      if (rootsToProbe > 4) scratch.probedRoots[4] = r4;
      if (rootsToProbe > 5) scratch.probedRoots[5] = r5;
    } else {
      final maxTrack = min(numRoots, scratch.rootScores.length);
      for (int i = 0; i < maxTrack; i++) {
        scratch.rootScores[i] = innerProduct48Reg(
          q0,
          q1,
          q2,
          q3,
          q4,
          q5,
          q6,
          q7,
          q8,
          q9,
          q10,
          q11,
          rootSimd,
          i * 12,
        );
        scratch.rootIndices[i] = i;
      }
      final validRoots = maxTrack;
      rootsToProbe = min(wantRoots, validRoots);
      for (int i = 0; i < rootsToProbe; i++) {
        var bestIdx = i;
        var bestScore = scratch.rootScores[i];
        for (int j = i + 1; j < validRoots; j++) {
          if (scratch.rootScores[j] > bestScore) {
            bestScore = scratch.rootScores[j];
            bestIdx = j;
          }
        }
        if (bestIdx != i) {
          final ts = scratch.rootScores[i];
          scratch.rootScores[i] = scratch.rootScores[bestIdx];
          scratch.rootScores[bestIdx] = ts;
          final ti = scratch.rootIndices[i];
          scratch.rootIndices[i] = scratch.rootIndices[bestIdx];
          scratch.rootIndices[bestIdx] = ti;
        }
        scratch.probedRoots[i] = scratch.rootIndices[i];
      }
    }

    // Beam follows searchDepth with a logN floor; depth-scaled cap 5/6/8.
    final maxLeavesToRead = min(plan.wantLeaves, scratch.pickedLeaves.length);
    final int beamWidth = _navBeamWidth(
      searchDepth: max(1, searchDepth ?? VectorIndexConfig.defaultSearchDepth),
      wantLeaves: plan.wantLeaves,
      totalVectors: meta.totalVectors,
    );
    scratch.branchHeap.reset(maxLeavesToRead);
    var l1AllCached = true;
    for (int r = 0; r < rootsToProbe; r++) {
      final rootId = scratch.probedRoots[r];
      final ok = _scoreNavSubtreeCached(
        tableUid: table.tableUid,
        indexUid: indexUid,
        state: state,
        rootId: rootId,
        q0: q0,
        q1: q1,
        q2: q2,
        q3: q3,
        q4: q4,
        q5: q5,
        q6: q6,
        q7: q7,
        q8: q8,
        q9: q9,
        q10: q10,
        q11: q11,
        maxLeavesToRead: maxLeavesToRead,
        beamWidth: beamWidth,
        leafHeap: scratch.branchHeap,
      );
      if (!ok) l1AllCached = false;
    }

    if (!l1AllCached) {
      if (!allowHydrate) {
        return (sync: null, async: null);
      }
      final probeRootIds = <int>[
        for (int r = 0; r < rootsToProbe; r++) scratch.probedRoots[r],
      ];
      final maxLeaves = maxLeavesToRead;
      final planCandSlots = plan.candSlots;
      final beam = beamWidth;
      return (
        sync: null,
        async: () async {
          scratch.branchHeap.reset(maxLeaves);
          for (final rootId in probeRootIds) {
            await _scoreNavSubtreeAsync(
              table: table,
              indexUid: indexUid,
              meta: meta,
              state: state,
              rootId: rootId,
              q0: q0,
              q1: q1,
              q2: q2,
              q3: q3,
              q4: q4,
              q5: q5,
              q6: q6,
              q7: q7,
              q8: q8,
              q9: q9,
              q10: q10,
              q11: q11,
              maxLeavesToRead: maxLeaves,
              beamWidth: beam,
              leafHeap: scratch.branchHeap,
            );
          }

          final leavesToPick = scratch.branchHeap.size;
          for (int i = 0; i < leavesToPick; i++) {
            scratch.pickedLeaves[i] = scratch.branchHeap.entries[i + 1];
            scratch.rootScores[i] = scratch.branchHeap.scores[i + 1];
          }
          if (leavesToPick > 2) {
            for (int i = 1; i < leavesToPick; i++) {
              final entry = scratch.pickedLeaves[i];
              final score = scratch.rootScores[i];
              var j = i - 1;
              while (j >= 0 && scratch.rootScores[j] < score) {
                scratch.pickedLeaves[j + 1] = scratch.pickedLeaves[j];
                scratch.rootScores[j + 1] = scratch.rootScores[j];
                j--;
              }
              scratch.pickedLeaves[j + 1] = entry;
              scratch.rootScores[j + 1] = score;
            }
          }

          return _searchCentroidBTreeHydrateAndRank(
            table: table,
            indexUid: indexUid,
            meta: meta,
            state: state,
            scratch: scratch,
            searchQuery: searchQuery,
            topK: topK,
            leavesToPick: leavesToPick,
            planCandSlots: planCandSlots,
            qFullSum: qFullSum,
            q0: q0,
            q1: q1,
            q2: q2,
            q3: q3,
            q4: q4,
            q5: q5,
            q6: q6,
            q7: q7,
            q8: q8,
            q9: q9,
            q10: q10,
            q11: q11,
            isCosine: isCosine,
            isIP: isIP,
            distanceThreshold: distanceThreshold,
            pendingDeletePks: pendingDeletePks,
          );
        }(),
      );
    }

    final leavesToPick = scratch.branchHeap.size;
    // Best-first leaf order: same final slotHeap membership, but fills the
    // candSlots heap with stronger 48-D hits first so later leaves prune
    // harder (lower avg 48-D work, recall unchanged). Skip sort when ≤2.
    for (int i = 0; i < leavesToPick; i++) {
      scratch.pickedLeaves[i] = scratch.branchHeap.entries[i + 1];
      scratch.rootScores[i] = scratch.branchHeap.scores[i + 1];
    }
    if (leavesToPick > 2) {
      for (int i = 1; i < leavesToPick; i++) {
        final entry = scratch.pickedLeaves[i];
        final score = scratch.rootScores[i];
        var j = i - 1;
        while (j >= 0 && scratch.rootScores[j] < score) {
          scratch.pickedLeaves[j + 1] = scratch.pickedLeaves[j];
          scratch.rootScores[j + 1] = scratch.rootScores[j];
          j--;
        }
        scratch.pickedLeaves[j + 1] = entry;
        scratch.rootScores[j + 1] = score;
      }
    }
    var allCached = true;
    for (int i = 0; i < leavesToPick; i++) {
      final entry = scratch.pickedLeaves[i]!;
      final page = _btreeLeafGet(
        table.tableUid,
        indexUid,
        entry.leafPageId,
        touch: false,
      );
      scratch.pickedLeafPages[i] = page;
      if (page == null) allCached = false;
    }

    if (!allCached) {
      if (!allowHydrate) {
        return (sync: null, async: null);
      }
      return (
        sync: null,
        async: _searchCentroidBTreeHydrateAndRank(
          table: table,
          indexUid: indexUid,
          meta: meta,
          state: state,
          scratch: scratch,
          searchQuery: searchQuery,
          topK: topK,
          leavesToPick: leavesToPick,
          planCandSlots: plan.candSlots,
          qFullSum: qFullSum,
          q0: q0,
          q1: q1,
          q2: q2,
          q3: q3,
          q4: q4,
          q5: q5,
          q6: q6,
          q7: q7,
          q8: q8,
          q9: q9,
          q10: q10,
          q11: q11,
          isCosine: isCosine,
          isIP: isIP,
          distanceThreshold: distanceThreshold,
          pendingDeletePks: pendingDeletePks,
        ),
      );
    }

    return (
      sync: _rankCentroidBTreeLeaves(
        scratch: scratch,
        searchQuery: searchQuery,
        topK: topK,
        leavesToPick: leavesToPick,
        planCandSlots: plan.candSlots,
        qFullSum: qFullSum,
        q0: q0,
        q1: q1,
        q2: q2,
        q3: q3,
        q4: q4,
        q5: q5,
        q6: q6,
        q7: q7,
        q8: q8,
        q9: q9,
        q10: q10,
        q11: q11,
        dimensions: dim,
        isCosine: isCosine,
        isIP: isIP,
        distanceThreshold: distanceThreshold,
        pendingDeletePks: pendingDeletePks,
      ),
      async: null,
    );
  }

  Future<List<NghSearchResult>> _searchCentroidBTreeHydrateAndRank({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required CentroidBTreeState state,
    required _CentroidSearchScratch scratch,
    required Float32List searchQuery,
    required int topK,
    required int leavesToPick,
    required int planCandSlots,
    required double qFullSum,
    required Float32x4 q0,
    required Float32x4 q1,
    required Float32x4 q2,
    required Float32x4 q3,
    required Float32x4 q4,
    required Float32x4 q5,
    required Float32x4 q6,
    required Float32x4 q7,
    required Float32x4 q8,
    required Float32x4 q9,
    required Float32x4 q10,
    required Float32x4 q11,
    required bool isCosine,
    required bool isIP,
    double? distanceThreshold,
    Set<String>? pendingDeletePks,
  }) async {
    final pickIds = <NghPageId>[
      for (int l = 0; l < leavesToPick; l++)
        scratch.pickedLeaves[l]!.leafPageId,
    ];
    await _hydrateBTreeLeaves(
      table: table,
      indexUid: indexUid,
      meta: meta,
      leafIds: pickIds,
    );
    for (int i = 0; i < leavesToPick; i++) {
      scratch.pickedLeafPages[i] = _btreeLeafGet(
        table.tableUid,
        indexUid,
        scratch.pickedLeaves[i]!.leafPageId,
        touch: false,
      );
    }
    return _rankCentroidBTreeLeaves(
      scratch: scratch,
      searchQuery: searchQuery,
      topK: topK,
      leavesToPick: leavesToPick,
      planCandSlots: planCandSlots,
      qFullSum: qFullSum,
      q0: q0,
      q1: q1,
      q2: q2,
      q3: q3,
      q4: q4,
      q5: q5,
      q6: q6,
      q7: q7,
      q8: q8,
      q9: q9,
      q10: q10,
      q11: q11,
      dimensions: meta.dimensions,
      isCosine: isCosine,
      isIP: isIP,
      distanceThreshold: distanceThreshold,
      pendingDeletePks: pendingDeletePks,
    );
  }

  List<NghSearchResult> _rankCentroidBTreeLeaves({
    required _CentroidSearchScratch scratch,
    required Float32List searchQuery,
    required int topK,
    required int leavesToPick,
    required int planCandSlots,
    required double qFullSum,
    required Float32x4 q0,
    required Float32x4 q1,
    required Float32x4 q2,
    required Float32x4 q3,
    required Float32x4 q4,
    required Float32x4 q5,
    required Float32x4 q6,
    required Float32x4 q7,
    required Float32x4 q8,
    required Float32x4 q9,
    required Float32x4 q10,
    required Float32x4 q11,
    required int dimensions,
    required bool isCosine,
    required bool isIP,
    double? distanceThreshold,
    Set<String>? pendingDeletePks,
  }) {
    scratch.slotHeap.reset(planCandSlots);
    final stampCheck = scratch.visitedTag;
    final stamp = scratch.currentStamp;
    final heap = scratch.slotHeap;
    final heapCap = heap.capacity;
    for (int l = 0; l < leavesToPick; l++) {
      final leafPage = scratch.pickedLeafPages[l];
      if (leafPage == null) continue;

      if (leafPage.searchLow48Simd == null) {
        leafPage.ensureLow48Ready();
      }
      final packed = leafPage.searchLow48Simd;
      final liveSlots = leafPage.searchLiveSlots;
      if (packed != null && liveSlots != null) {
        final n = liveSlots.length;
        var i = 0;
        final n2 = n - 1;
        while (i < n2) {
          final slot0 = liveSlots[i];
          final slot1 = liveSlots[i + 1];
          final id0 = slot0.nodeId;
          final id1 = slot1.nodeId;
          var skip0 = (slot0.flags & 0x01) != 0;
          var skip1 = (slot1.flags & 0x01) != 0;
          if (!skip0 && id0 < stampCheck.length) {
            if (stampCheck[id0] == stamp) {
              skip0 = true;
            } else {
              stampCheck[id0] = stamp;
            }
          }
          if (!skip1 && id1 < stampCheck.length) {
            if (stampCheck[id1] == stamp) {
              skip1 = true;
            } else {
              stampCheck[id1] = stamp;
            }
          }
          if (!skip0) {
            final s48 = innerProduct48Reg(
              q0,
              q1,
              q2,
              q3,
              q4,
              q5,
              q6,
              q7,
              q8,
              q9,
              q10,
              q11,
              packed,
              i * 12,
            );
            if (!(heap.size >= heapCap && s48 <= heap.minScore)) {
              heap.push(slot0, s48);
            }
          }
          if (!skip1) {
            final s48 = innerProduct48Reg(
              q0,
              q1,
              q2,
              q3,
              q4,
              q5,
              q6,
              q7,
              q8,
              q9,
              q10,
              q11,
              packed,
              (i + 1) * 12,
            );
            if (!(heap.size >= heapCap && s48 <= heap.minScore)) {
              heap.push(slot1, s48);
            }
          }
          i += 2;
        }
        if (i < n) {
          final slot = liveSlots[i];
          final nodeId = slot.nodeId;
          var skip = (slot.flags & 0x01) != 0;
          if (!skip && nodeId < stampCheck.length) {
            if (stampCheck[nodeId] == stamp) {
              skip = true;
            } else {
              stampCheck[nodeId] = stamp;
            }
          }
          if (!skip) {
            final s48 = innerProduct48Reg(
              q0,
              q1,
              q2,
              q3,
              q4,
              q5,
              q6,
              q7,
              q8,
              q9,
              q10,
              q11,
              packed,
              i * 12,
            );
            if (!(heap.size >= heapCap && s48 <= heap.minScore)) {
              heap.push(slot, s48);
            }
          }
        }
        continue;
      }

      final slots = leafPage.slots;
      for (int i = 0; i < slots.length; i++) {
        final slot = slots[i];
        if ((slot.flags & 0x01) != 0) continue;
        final nodeId = slot.nodeId;
        if (nodeId < stampCheck.length) {
          if (stampCheck[nodeId] == stamp) continue;
          stampCheck[nodeId] = stamp;
        }

        // Pages in leaf cache call ensureLow48Ready — prefer direct SIMD.
        final sSimd = slot.low48DSimd;
        if (sSimd == null) {
          final built = slot.getLow48DSimd(dimensions);
          final s48 = innerProduct48Reg(
            q0,
            q1,
            q2,
            q3,
            q4,
            q5,
            q6,
            q7,
            q8,
            q9,
            q10,
            q11,
            built,
            0,
          );
          if (heap.size >= heapCap && s48 <= heap.minScore) {
            continue;
          }
          heap.push(slot, s48);
          continue;
        }
        final s48 = innerProduct48Reg(
          q0,
          q1,
          q2,
          q3,
          q4,
          q5,
          q6,
          q7,
          q8,
          q9,
          q10,
          q11,
          sSimd,
          0,
        );
        if (heap.size >= heapCap && s48 <= heap.minScore) {
          continue;
        }
        heap.push(slot, s48);
      }
    }

    final q = searchQuery;
    final dim = dimensions;
    var resultHeap = scratch.resultHeap;
    if (resultHeap == null || resultHeap.capacity < topK) {
      resultHeap = _FixedHeap(topK, maxHeap: true);
      scratch.resultHeap = resultHeap;
    } else {
      resultHeap.clear();
    }

    final hasPending = pendingDeletePks != null;
    final hasThreshold = distanceThreshold != null;
    final threshold = distanceThreshold ?? 0.0;

    for (int i = 1; i <= scratch.slotHeap.size; i++) {
      final slot = scratch.slotHeap.slots[i]!;
      if ((slot.flags & NghLeafSlot.flagDeleted) != 0) continue;
      if (hasPending && pendingDeletePks.contains(slot.primaryKey)) {
        continue;
      }

      final codes = slot.sq8Codes;
      double dot0 = 0.0;
      double dot1 = 0.0;
      int d = 0;
      final unroll16 = dim - 15;
      while (d < unroll16) {
        dot0 += q[d] * codes[d] +
            q[d + 2] * codes[d + 2] +
            q[d + 4] * codes[d + 4] +
            q[d + 6] * codes[d + 6] +
            q[d + 8] * codes[d + 8] +
            q[d + 10] * codes[d + 10] +
            q[d + 12] * codes[d + 12] +
            q[d + 14] * codes[d + 14];
        dot1 += q[d + 1] * codes[d + 1] +
            q[d + 3] * codes[d + 3] +
            q[d + 5] * codes[d + 5] +
            q[d + 7] * codes[d + 7] +
            q[d + 9] * codes[d + 9] +
            q[d + 11] * codes[d + 11] +
            q[d + 13] * codes[d + 13] +
            q[d + 15] * codes[d + 15];
        d += 16;
      }
      while (d < dim) {
        dot0 += q[d] * codes[d];
        d++;
      }

      final ip = slot.offset * qFullSum + slot.scale * (dot0 + dot1);
      final double dist;
      if (isCosine) {
        // Cosine inserts store unit vectors → squaredNorm ≈ 1; skip sqrt.
        final sn = slot.squaredNorm;
        final cosSim = (sn > 0.99 && sn < 1.01) ? ip : ip / sqrt(sn);
        dist = cosSim >= 1.0 ? 0.0 : (cosSim <= 0.0 ? 1.0 : 1.0 - cosSim);
      } else if (isIP) {
        dist = -ip;
      } else {
        dist = max(0.0, 1.0 + slot.squaredNorm - 2.0 * ip);
      }

      if (hasThreshold && dist > threshold) continue;
      // Prefer resident String PK (insert path) — avoid utf8.decode on emit.
      resultHeap.pushWithPk(
        slot.nodeId,
        dist,
        slot.primaryKeyBytes ?? slot.primaryKeyUtf8,
        slot.cachedPrimaryKey,
      );
    }

    return resultHeap.drainSortedToSearchResults();
  }

  /// Migrate legacy single-file `nav_graph.ngh` (or unpaged centroids) directly
  /// into the paged Centroid nav tree (fanout-bounded mid/leaf).
  ///
  /// Groups existing centroid 48-D projections into up to 64 L0 roots, packs
  /// each root's leaf entries into a SPLIT/mid nav subtree (no sibling
  /// chains), preserves physical leaf page associations, and writes
  /// [dirtyNavRootPage] / [dirtyNavBTreePages].
  Future<
      ({
        NghIndexMeta meta,
        Map<NghPagePtr, NghNavBTreePage> dirtyNavBTreePages,
        ({NghPagePtr ptr, NghNavRootPage page}) dirtyNavRootPage,
      })> migrateLegacyNavToBTree({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required NghNavGraphPage blob,
  }) async {
    final dims = blob.dimensions;
    final centroids = blob.centroids;
    var currentMeta = meta;

    final dirtyNavBTreePages = <NghPagePtr, NghNavBTreePage>{};

    if (centroids.isEmpty) {
      final (rootPages, metaAfterAlloc) =
          _partitionManager.allocatePagesBatchSync(
        NghDataCategory.nav,
        currentMeta,
        1,
      );
      currentMeta = metaAfterAlloc;
      final rootPtr = rootPages.first;
      final emptyRootPage = NghNavRootPage(
        lowDim: 48,
        fullDim: dims,
        roots: const [],
      );
      currentMeta = currentMeta.copyWith(
        layoutVersion: NghIndexMeta.layoutPaged,
        centroidCount: 0,
      );
      return (
        meta: currentMeta,
        dirtyNavBTreePages: dirtyNavBTreePages,
        dirtyNavRootPage: (ptr: rootPtr, page: emptyRootPage),
      );
    }

    final isCosine = currentMeta.distanceMetric == VectorDistanceMetric.cosine;

    // 1. Extract normalized 48-D projections of existing centroids
    final low48List = List<Float32List>.generate(
      centroids.length,
      (i) {
        final v = centroids[i].vector;
        return _extractLow48(isCosine ? _normalizeFloat32(v) : v);
      },
      growable: false,
    );

    // 2. K-means clustering over centroids — sparse when legacy K is tiny.
    // L0 stays growable after migrate up to the root-page wire fit.
    final maxRoots = _maxL0RootsForNavPageSize(_navPageSize(currentMeta));
    final numRoots = min(maxRoots, _initialL0RootCount(centroids.length));
    final rootSeeds = _kMeansInit48(
      samples: low48List,
      k: numRoots,
      iterations: 6,
    );

    // 3. Assign each legacy centroid to its nearest root centroid
    final rootMembers = List<List<int>>.generate(numRoots, (_) => <int>[]);
    final rootSeedsSimd = List<Float32x4List>.generate(
      numRoots,
      (r) => Float32x4List.sublistView(rootSeeds[r]),
      growable: false,
    );

    for (int i = 0; i < centroids.length; i++) {
      final sSimd = Float32x4List.sublistView(low48List[i]);
      int bestRoot = 0;
      double maxSim = -1e9;
      for (int r = 0; r < numRoots; r++) {
        final sim = innerProduct48(sSimd, rootSeedsSimd[r], 0);
        if (sim > maxSim) {
          maxSim = sim;
          bestRoot = r;
        }
      }
      rootMembers[bestRoot].add(i);
    }

    // 4. Calculate total entries per root (expanding multiple leaf pages if any)
    final rootEntries = List<List<CentroidBranchEntry>>.generate(
      numRoots,
      (_) => <CentroidBranchEntry>[],
    );
    int maxCentroidId = 0;

    for (int r = 0; r < numRoots; r++) {
      for (final cIdx in rootMembers[r]) {
        final c = centroids[cIdx];
        if (c.centroidId > maxCentroidId) {
          maxCentroidId = c.centroidId;
        }
        final cPages = c.leafPages.isNotEmpty
            ? c.leafPages
            : (c.leafPageNos.isNotEmpty
                ? c.leafPageNos
                    .map(NghPageId.fromPacked)
                    .toList(growable: false)
                : (c.headLeafPageNo >= 0
                    ? [NghPageId.fromPacked(c.headLeafPageNo)]
                    : const <NghPageId>[]));

        if (cPages.isEmpty) {
          rootEntries[r].add(CentroidBranchEntry(
            centroidId: c.centroidId,
            leafPageId: NghPageId.none,
            leafSlotCount: c.entryCount,
            centroid48D: low48List[cIdx],
          ));
        } else {
          final countPerLeaf = max(1, c.entryCount ~/ cPages.length);
          for (final leafPageId in cPages) {
            rootEntries[r].add(CentroidBranchEntry(
              centroidId: c.centroidId,
              leafPageId: leafPageId,
              leafSlotCount: countPerLeaf,
              centroid48D: low48List[cIdx],
            ));
          }
        }
      }
    }

    // 5. Nav tree page counts per root (leaf pages + mid promotions)
    final pagesNeededPerRoot = List<int>.generate(
      numRoots,
      (r) => _navTreePagesNeeded(rootEntries[r].length),
    );
    final totalInternalPages =
        pagesNeededPerRoot.fold<int>(0, (sum, p) => sum + p);

    // 6. Batch allocate nav pages: 1 root page + totalInternalPages
    final (navPages, metaAfterAlloc) = _partitionManager.allocatePagesBatchSync(
      NghDataCategory.nav,
      currentMeta,
      1 + totalInternalPages,
    );
    currentMeta = metaAfterAlloc;

    final rootPtr = navPages[0];
    final rootPageId = NghPageId(rootPtr.partitionNo, rootPtr.pageNo);

    final rootsList = <({
      int rootId,
      NghPageId firstInternalPage,
      Float32List centroid48D,
    })>[];

    final state = CentroidBTreeState(
      numRootCentroids: numRoots,
      rootPageId: rootPageId,
      nextCentroidId: max(maxCentroidId, numRoots),
      maxRoots: maxRoots,
    );

    int navPageCursor = 1;

    for (int r = 0; r < numRoots; r++) {
      final entries = rootEntries[r];
      final pagesCount = pagesNeededPerRoot[r];
      final rootPagePtrs =
          navPages.sublist(navPageCursor, navPageCursor + pagesCount);
      navPageCursor += pagesCount;

      final pageIds = <NghPageId>[
        for (final p in rootPagePtrs) NghPageId(p.partitionNo, p.pageNo),
      ];

      final firstInternalPageId = _writeNavSubtree(
        rootId: r,
        leafEntries: entries,
        pageIds: pageIds,
        write: (id, page) {
          final ptr = NghPagePtr(
            NghDataCategory.nav,
            id.partitionNo,
            id.pageNo,
          );
          dirtyNavBTreePages[ptr] = page;
          _navInternalPut(table.tableUid, indexUid, id, page);
        },
      );

      rootsList.add((
        rootId: r,
        firstInternalPage: firstInternalPageId,
        centroid48D: rootSeeds[r],
      ));
      state.loadFirstInternal(r, firstInternalPageId);

      final c48 = rootSeeds[r];
      for (int d = 0; d < 48; d++) {
        state.rootCentroids48Flat[r * 48 + d] = c48[d];
      }
    }

    _btreeStates[_cacheKey(table.tableUid, indexUid)] = state;

    final rootPage = NghNavRootPage(
      lowDim: 48,
      fullDim: dims,
      nextCentroidId: state.nextCentroidId,
      roots: rootsList,
    );
    final dirtyNavRootPage = (ptr: rootPtr, page: rootPage);

    currentMeta = currentMeta.copyWith(
      layoutVersion: NghIndexMeta.layoutPaged,
      centroidCount: centroids.length,
    );

    return (
      meta: currentMeta,
      dirtyNavBTreePages: dirtyNavBTreePages,
      dirtyNavRootPage: dirtyNavRootPage,
    );
  }

  Future<NghInsertResult> _insertBatchCentroidBTree({
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
        dirtyLeafPages: const {},
        insertedCount: 0,
      );
    }

    var currentMeta = NghPageSizer.ensureIndexPageSizes(
      meta,
      _partitionManager.configuredPageSize,
    );
    final isCosine = currentMeta.distanceMetric == VectorDistanceMetric.cosine;

    final normalizedVectors = isCosine
        ? List<Float32List>.generate(
            vectors.length,
            (i) => _normalizeFloat32(vectors[i]),
            growable: false,
          )
        : vectors;

    final dirtyLeafPages = <NghPagePtr, NghLeafPage>{};
    final dirtyNavBTreePages = <NghPagePtr, NghNavBTreePage>{};
    ({NghPagePtr ptr, NghNavRootPage page})? dirtyNavRootPage;
    // Mutation-local leaves (not TreeCache) so mid-insert puts cannot evict
    // pages still being written. Flushed into leaf TreeCache; search hot
    // set is promoted via [promotePagedLeavesAfterInsert].
    final insertLeaves = <NghPageId, NghLeafPage>{};
    // Mutation-local nav pages for probed roots (tree, not inventory).
    final insertNavPages = <NghPageId, NghNavBTreePage>{};
    final insertNavRootsReady = <int>{};

    var state = _btreeStates[_cacheKey(table.tableUid, indexUid)];
    state ??= await _getOrLoadBTreeState(table, indexUid, currentMeta);
    if (state == null) {
      // Cold-start L0: sparse skeleton on tiny batches; full target once
      // sample-rich. L0 remains growable (far-spawn / heavy-root-split) up to
      // the root-table page fit — never permanently frozen here.
      final maxRoots = _maxL0RootsForNavPageSize(_navPageSize(currentMeta));
      final numRoots = min(maxRoots, _initialL0RootCount(vectors.length));
      final low48List = List<Float32List>.generate(
        normalizedVectors.length,
        (i) => _extractLow48(normalizedVectors[i]),
      );
      final rootSeeds = _kMeansInit48(
        samples: low48List,
        k: numRoots,
        iterations: 6,
      );

      final (navPages, metaWithNav) = _partitionManager.allocatePagesBatchSync(
        NghDataCategory.nav,
        currentMeta,
        1 + numRoots,
      );
      currentMeta = metaWithNav;

      final rootPtr = navPages[0];
      final rootPageId = NghPageId(rootPtr.partitionNo, rootPtr.pageNo);

      final rootsList = <({
        int rootId,
        NghPageId firstInternalPage,
        Float32List centroid48D
      })>[];
      for (int r = 0; r < numRoots; r++) {
        final internalPtr = navPages[1 + r];
        final internalPageId =
            NghPageId(internalPtr.partitionNo, internalPtr.pageNo);
        final c48 = rootSeeds[r];
        rootsList.add((
          rootId: r,
          firstInternalPage: internalPageId,
          centroid48D: c48,
        ));
        final internalPage = NghNavBTreePage(
          rootCentroidId: r,
          flags: NghNavBTreePage.flagLeafLevel,
          entries: [],
        );
        dirtyNavBTreePages[internalPtr] = internalPage;
        insertNavPages[internalPageId] = internalPage;
        insertNavRootsReady.add(r);
        _navInternalPut(table.tableUid, indexUid, internalPageId, internalPage);
      }

      state = CentroidBTreeState(
        numRootCentroids: numRoots,
        rootPageId: rootPageId,
        nextCentroidId: numRoots,
        maxRoots: maxRoots,
      );
      for (int r = 0; r < numRoots; r++) {
        final c = rootsList[r].centroid48D;
        for (int d = 0; d < 48; d++) {
          state.rootCentroids48Flat[r * 48 + d] = c[d];
        }
        state.loadFirstInternal(r, rootsList[r].firstInternalPage);
      }
      _btreeStates[_cacheKey(table.tableUid, indexUid)] = state;

      dirtyNavRootPage = (
        ptr: rootPtr,
        page: NghNavRootPage(
          lowDim: 48,
          fullDim: currentMeta.dimensions,
          nextCentroidId: state.nextCentroidId,
          roots: rootsList,
        ),
      );
    }

    final initialNextCentroidId = state.nextCentroidId;

    // Insert-local 48-D scratch (not search pool — batch owns it for the flush).
    final insertQLow = Float32List(48);
    final insertQLowSimd = Float32x4List.sublistView(insertQLow);

    void markInsertNav(NghPageId id, NghNavBTreePage page) {
      page.invalidateSearch48Pack();
      insertNavPages[id] = page;
      dirtyNavBTreePages[NghPagePtr(
        NghDataCategory.nav,
        id.partitionNo,
        id.pageNo,
      )] = page;
    }

    /// Refresh mid summaries from [child] up through [path] to the L0 head.
    ///
    /// Without this, ordinary (non-split) inserts update leaf centroids but
    /// leave parent mid entries stale. As the tree deepens past ~1e5–1e6,
    /// search beam prunes on obsolete mid scores → recall cliff with the
    /// same wantLeaves budget. Cost is O(hops×entries×48) on insert only.
    void bubbleSummaryUp({
      required int rootId,
      required NghPageId childId,
      required NghNavBTreePage childPage,
      required List<({NghPageId pageId, NghNavBTreePage page, int childIdx})>
          path,
    }) {
      _bubbleNavSummaryUp(
        rootId: rootId,
        childId: childId,
        childPage: childPage,
        path: path,
        mark: markInsertNav,
      );
    }

    NghNavBTreePage? resolveInsertNav(NghPageId id) {
      final local = insertNavPages[id];
      if (local != null) return local;
      return _resolveNavInternalPage(
        tableUid: table.tableUid,
        indexUid: indexUid,
        id: id,
        dirtyOverlay: dirtyNavBTreePages,
        touch: true,
      );
    }

    Future<NghNavBTreePage> loadInsertNav(NghPageId id) async {
      final hit = resolveInsertNav(id);
      if (hit != null) return hit;
      final page = await _partitionManager.readNavBTreePage(
        table,
        indexUid,
        id,
        meta: currentMeta,
      );
      if (page == null) {
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message: 'NGH insert missing nav page $id',
          )
        ]);
      }
      insertNavPages[id] = page;
      _navInternalPut(table.tableUid, indexUid, id, page);
      return page;
    }

    Future<void> ensureInsertRootNav(int rootId) async {
      if (insertNavRootsReady.contains(rootId)) return;
      final head = await _loadRootHeadPage(
        table: table,
        indexUid: indexUid,
        meta: currentMeta,
        state: state!,
        rootId: rootId,
        dirtyOverlay: dirtyNavBTreePages,
      );
      for (final c in head) {
        insertNavPages[c.pageId] = c.page;
        _navInternalPut(table.tableUid, indexUid, c.pageId, c.page);
      }
      insertNavRootsReady.add(rootId);
    }

    final leafPageSize = _leafPageSize(currentMeta);
    final maxSlotsPerPage = NghPageSizer.estimateLeafSlotsPerPage(
      leafPageSize,
      currentMeta.dimensions,
    );

    void promoteBranchEntryUp({
      required int rootId,
      required CentroidBranchEntry newEntry,
      required List<({NghPageId pageId, NghNavBTreePage page, int childIdx})>
          path,
      required NghPageId splitChildId,
      required NghNavBTreePage splitChildPage,
    }) {
      // Refresh the path child's summary after the split.
      if (path.isNotEmpty) {
        final parent = path.last;
        parent.page.entries[parent.childIdx] = _summaryEntryForChild(
          childPageId: splitChildId,
          childPage: splitChildPage,
          fallbackCentroidId: rootId,
        );
        markInsertNav(parent.pageId, parent.page);
      }

      if (path.isEmpty) {
        // Split child was firstInternal — create a new mid root.
        final (midPtrs, midMeta) = _partitionManager.allocatePagesBatchSync(
          NghDataCategory.nav,
          currentMeta,
          1,
        );
        currentMeta = midMeta;
        final midPtr = midPtrs.first;
        final midId = NghPageId(midPtr.partitionNo, midPtr.pageNo);
        final left = _summaryEntryForChild(
          childPageId: splitChildId,
          childPage: splitChildPage,
          fallbackCentroidId: rootId,
        );
        final midPage = NghNavBTreePage(
          rootCentroidId: rootId,
          flags: 0,
          entries: [left, newEntry],
        );
        markInsertNav(midId, midPage);
        state!.setFirstInternal(rootId, midId);
        return;
      }

      final parent = path.last;
      if (parent.page.entries.length < NghNavBTreePage.maxEntriesPerPage) {
        parent.page.entries.add(newEntry);
        markInsertNav(parent.pageId, parent.page);
        // Parent gained a child / left summary changed — ancestors must track.
        bubbleSummaryUp(
          rootId: rootId,
          childId: parent.pageId,
          childPage: parent.page,
          path: path.sublist(0, path.length - 1),
        );
        return;
      }

      // Parent mid full → split parent and promote further.
      final all = List<CentroidBranchEntry>.from(parent.page.entries)
        ..add(newEntry);
      final (leftEntries, rightEntries) = _splitBranchEntriesBalanced(all);
      parent.page.entries
        ..clear()
        ..addAll(leftEntries);
      parent.page.isLeafLevel = false;
      markInsertNav(parent.pageId, parent.page);

      final (rightPtrs, rightMeta) = _partitionManager.allocatePagesBatchSync(
        NghDataCategory.nav,
        currentMeta,
        1,
      );
      currentMeta = rightMeta;
      final rightPtr = rightPtrs.first;
      final rightId = NghPageId(rightPtr.partitionNo, rightPtr.pageNo);
      final rightPage = NghNavBTreePage(
        rootCentroidId: rootId,
        flags: 0,
        entries: rightEntries,
      );
      markInsertNav(rightId, rightPage);

      final rightSummary = _summaryEntryForChild(
        childPageId: rightId,
        childPage: rightPage,
        fallbackCentroidId: rootId,
      );
      final parentPath = path.sublist(0, path.length - 1);
      promoteBranchEntryUp(
        rootId: rootId,
        newEntry: rightSummary,
        path: parentPath,
        splitChildId: parent.pageId,
        splitChildPage: parent.page,
      );
    }

    void appendLeafLevelEntry({
      required int rootId,
      required NghPageId ownerId,
      required NghNavBTreePage ownerPage,
      required CentroidBranchEntry newBranchEntry,
      required List<({NghPageId pageId, NghNavBTreePage page, int childIdx})>
          path,
    }) {
      if (!ownerPage.isLeafLevel) {
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message: 'NGH appendLeafLevelEntry expected leaf-level nav page '
                '(root=$rootId page=$ownerId)',
          )
        ]);
      }
      if (ownerPage.entries.length < NghNavBTreePage.maxEntriesPerPage) {
        ownerPage.entries.add(newBranchEntry);
        markInsertNav(ownerId, ownerPage);
        bubbleSummaryUp(
          rootId: rootId,
          childId: ownerId,
          childPage: ownerPage,
          path: path,
        );
        return;
      }

      final all = List<CentroidBranchEntry>.from(ownerPage.entries)
        ..add(newBranchEntry);
      final (leftEntries, rightEntries) = _splitBranchEntriesBalanced(all);
      ownerPage.entries
        ..clear()
        ..addAll(leftEntries);
      ownerPage.isLeafLevel = true;
      markInsertNav(ownerId, ownerPage);

      final (rightPtrs, rightMeta) = _partitionManager.allocatePagesBatchSync(
        NghDataCategory.nav,
        currentMeta,
        1,
      );
      currentMeta = rightMeta;
      final rightPtr = rightPtrs.first;
      final rightId = NghPageId(rightPtr.partitionNo, rightPtr.pageNo);
      final rightPage = NghNavBTreePage(
        rootCentroidId: rootId,
        flags: NghNavBTreePage.flagLeafLevel,
        entries: rightEntries,
      );
      markInsertNav(rightId, rightPage);

      final rightSummary = _summaryEntryForChild(
        childPageId: rightId,
        childPage: rightPage,
        fallbackCentroidId: rootId,
      );
      promoteBranchEntryUp(
        rootId: rootId,
        newEntry: rightSummary,
        path: path,
        splitChildId: ownerId,
        splitChildPage: ownerPage,
      );
    }

    void applySlotToLeaf(
      int rootId,
      CentroidBranchEntry branchEntry,
      ({NghPageId pageId, NghNavBTreePage page}) ownerInternal,
      List<({NghPageId pageId, NghNavBTreePage page, int childIdx})> path,
      NghLeafSlot newSlot,
      NghPagePtr ptr,
      NghLeafPage leafPage,
    ) {
      final currentPayload = leafPage.estimatePayloadSize();
      final pkLen =
          newSlot.primaryKeyBytes?.length ?? newSlot.primaryKeyUtf8.length;
      final pageWide = leafPage.needsWideNodeIds ||
          newSlot.nodeId > NghLeafPage.maxCompactNodeId;
      final newSlotBytes =
          NghLeafPage.slotFixedHeaderBytes(wideNodeIds: pageWide) +
              pkLen +
              currentMeta.dimensions;
      final upgradeCost = leafPage.wideUpgradeCostBytes(newSlot.nodeId);
      final fitsInPhysicalPage =
          (20 + currentPayload + upgradeCost + newSlotBytes) <=
              (leafPageSize - 64);

      if (leafPage.slots.length < maxSlotsPerPage && fitsInPhysicalPage) {
        leafPage.addSlot(newSlot);
        branchEntry.leafSlotCount = leafPage.slots.length;
        branchEntry.centroid48D = leafPage.normalizedMean48();
        branchEntry.centroid48DSimd =
            Float32x4List.sublistView(branchEntry.centroid48D);

        dirtyLeafPages[ptr] = leafPage;
        markInsertNav(ownerInternal.pageId, ownerInternal.page);
        // Keep ancestor mid centroids coherent with the drifted leaf mean.
        bubbleSummaryUp(
          rootId: rootId,
          childId: ownerInternal.pageId,
          childPage: ownerInternal.page,
          path: path,
        );
        return;
      }

      // 50/50 Balanced Geometric Hyperplane Split
      leafPage.addSlot(newSlot);

      final seedASimd = leafPage.slots[0].getLow48DSimd(currentMeta.dimensions);
      int bestBIdx = 1;
      double minSimToA = 1e9;
      for (int i = 1; i < leafPage.slots.length; i++) {
        final sSimd = leafPage.slots[i].getLow48DSimd(currentMeta.dimensions);
        final sim = innerProduct48(seedASimd, sSimd, 0);
        if (sim < minSimToA) {
          minSimToA = sim;
          bestBIdx = i;
        }
      }
      final seedBSimd =
          leafPage.slots[bestBIdx].getLow48DSimd(currentMeta.dimensions);

      final projScores = Float64List(leafPage.slots.length);
      final projIndices = Int32List(leafPage.slots.length);
      for (int i = 0; i < leafPage.slots.length; i++) {
        final slot = leafPage.slots[i];
        final sSimd = slot.getLow48DSimd(currentMeta.dimensions);
        final simA = innerProduct48(seedASimd, sSimd, 0);
        final simB = innerProduct48(seedBSimd, sSimd, 0);
        projScores[i] = simA - simB;
        projIndices[i] = i;
      }

      for (int i = 0; i < leafPage.slots.length; i++) {
        int maxIdx = i;
        for (int j = i + 1; j < leafPage.slots.length; j++) {
          if (projScores[j] > projScores[maxIdx]) maxIdx = j;
        }
        final ts = projScores[i];
        projScores[i] = projScores[maxIdx];
        projScores[maxIdx] = ts;
        final ti = projIndices[i];
        projIndices[i] = projIndices[maxIdx];
        projIndices[maxIdx] = ti;
      }

      final groupA = <NghLeafSlot>[];
      final groupB = <NghLeafSlot>[];
      final mid = leafPage.slots.length ~/ 2;
      for (int i = 0; i < mid; i++) {
        groupA.add(leafPage.slots[projIndices[i]]);
      }
      for (int i = mid; i < leafPage.slots.length; i++) {
        groupB.add(leafPage.slots[projIndices[i]]);
      }

      leafPage.replaceSlots(groupA);
      branchEntry.leafSlotCount = groupA.length;
      branchEntry.centroid48D = leafPage.normalizedMean48();
      branchEntry.centroid48DSimd =
          Float32x4List.sublistView(branchEntry.centroid48D);

      dirtyLeafPages[ptr] = leafPage;
      markInsertNav(ownerInternal.pageId, ownerInternal.page);

      final (newLeafPtrs, nextLeafMeta) =
          _partitionManager.allocatePagesBatchSync(
        NghDataCategory.leaf,
        currentMeta,
        1,
      );
      currentMeta = nextLeafMeta;
      final newLeafPtr = newLeafPtrs.first;
      final newLeafPageId =
          NghPageId(newLeafPtr.partitionNo, newLeafPtr.pageNo);

      final nextCentroidId = ++state!.nextCentroidId;
      final splitLeafPage = NghLeafPage(
        centroidId: nextCentroidId,
        dimensions: currentMeta.dimensions,
        slots: <NghLeafSlot>[],
      )..replaceSlots(groupB);
      insertLeaves[newLeafPageId] = splitLeafPage;
      dirtyLeafPages[newLeafPtr] = splitLeafPage;

      final newCentroid48 = splitLeafPage.normalizedMean48();
      final newBranchEntry = CentroidBranchEntry(
        centroidId: nextCentroidId,
        leafPageId: newLeafPageId,
        leafSlotCount: groupB.length,
        centroid48D: newCentroid48,
      );

      appendLeafLevelEntry(
        rootId: rootId,
        ownerId: ownerInternal.pageId,
        ownerPage: ownerInternal.page,
        newBranchEntry: newBranchEntry,
        path: path,
      );
    }

    /// Resolve/allocate leaf and apply [newSlot]. Returns false if the leaf
    /// page is not in memory (caller must async-load).
    bool insertSlotIntoLeafSync(
      int rootId,
      CentroidBranchEntry branchEntry,
      ({NghPageId pageId, NghNavBTreePage page}) ownerInternal,
      List<({NghPageId pageId, NghNavBTreePage page, int childIdx})> path,
      NghLeafSlot newSlot,
    ) {
      var leafPageId = branchEntry.leafPageId;
      if (leafPageId.isNone) {
        final (leafPtrs, leafMeta) = _partitionManager.allocatePagesBatchSync(
          NghDataCategory.leaf,
          currentMeta,
          1,
        );
        currentMeta = leafMeta;
        final leafPtr = leafPtrs.first;
        leafPageId = NghPageId(leafPtr.partitionNo, leafPtr.pageNo);
        branchEntry.leafPageId = leafPageId;
        final leafPage = NghLeafPage.empty(
          centroidId: branchEntry.centroidId,
          dimensions: currentMeta.dimensions,
        );
        insertLeaves[leafPageId] = leafPage;
        dirtyLeafPages[leafPtr] = leafPage;
      }
      final ptr = NghPagePtr(
          NghDataCategory.leaf, leafPageId.partitionNo, leafPageId.pageNo);
      final leafPage = dirtyLeafPages[ptr] ??
          insertLeaves[leafPageId] ??
          _btreeLeafGet(table.tableUid, indexUid, leafPageId, touch: false);
      if (leafPage == null) return false;
      insertLeaves[leafPageId] = leafPage;
      applySlotToLeaf(
        rootId,
        branchEntry,
        ownerInternal,
        path,
        newSlot,
        ptr,
        leafPage,
      );
      return true;
    }

    Future<void> insertSlotIntoLeaf(
      int rootId,
      CentroidBranchEntry branchEntry,
      ({NghPageId pageId, NghNavBTreePage page}) ownerInternal,
      List<({NghPageId pageId, NghNavBTreePage page, int childIdx})> path,
      NghLeafSlot newSlot,
    ) async {
      if (insertSlotIntoLeafSync(
        rootId,
        branchEntry,
        ownerInternal,
        path,
        newSlot,
      )) {
        return;
      }
      var leafPageId = branchEntry.leafPageId;
      final ptr = NghPagePtr(
          NghDataCategory.leaf, leafPageId.partitionNo, leafPageId.pageNo);
      var leafPage = await _partitionManager.readLeafPage(
        table,
        indexUid,
        currentMeta,
        leafPageId.partitionNo,
        leafPageId.pageNo,
      );
      if (leafPage == null) {
        throw DbException([
          GeneralStatus(
            type: ResultType.sysIoDataCorrupted,
            message:
                'NGH leaf p${leafPageId.partitionNo} pg${leafPageId.pageNo} '
                'for "$indexUid" missing during insert; refusing empty overwrite.',
          ),
        ]);
      }
      leafPage.ensureLow48Ready();
      insertLeaves[leafPageId] = leafPage;
      applySlotToLeaf(
        rootId,
        branchEntry,
        ownerInternal,
        path,
        newSlot,
        ptr,
        leafPage,
      );
    }

    /// In-memory insert after batch pin/hydrate. Returns false if any nav/leaf
    /// page still needs disk I/O (caller falls back to [insertIntoRoot]).
    bool insertIntoRootSync(
      int rootId,
      NghLeafSlot newSlot,
      Float32x4List qLowSimd,
    ) {
      if (!insertNavRootsReady.contains(rootId)) return false;

      var headId = state!.firstInternalByRoot[rootId];
      if (headId.isNone) {
        final (pPtrs, pMeta) = _partitionManager.allocatePagesBatchSync(
          NghDataCategory.nav,
          currentMeta,
          1,
        );
        currentMeta = pMeta;
        final pPtr = pPtrs.first;
        headId = NghPageId(pPtr.partitionNo, pPtr.pageNo);
        final emptyP = NghNavBTreePage(
          rootCentroidId: rootId,
          flags: NghNavBTreePage.flagLeafLevel,
          entries: [],
        );
        markInsertNav(headId, emptyP);
        state.setFirstInternal(rootId, headId);
      }

      var curId = headId;
      final head = resolveInsertNav(curId);
      if (head == null) return false;
      var cur = head;
      final path = <({NghPageId pageId, NghNavBTreePage page, int childIdx})>[];

      var hop = 0;
      // Last mid hop may dual-fork into a near-second child (write-path beam).
      NghPageId? dualMidChildId;
      List<({NghPageId pageId, NghNavBTreePage page, int childIdx})>?
          dualMidPath;
      while (!cur.isLeafLevel) {
        if (++hop > NghNavBTreePage.maxTreeHops) {
          throw DbException([
            GeneralStatus(
              type: ResultType.engError,
              message:
                  'NGH insert descent exceeded maxTreeHops=${NghNavBTreePage.maxTreeHops} '
                  '(root=$rootId). Refusing to rewrite a mid page as a leaf.',
            )
          ]);
        }
        if (cur.entries.isEmpty) {
          throw DbException([
            GeneralStatus(
              type: ResultType.engError,
              message:
                  'NGH insert mid nav page has no children (root=$rootId, page=$curId).',
            )
          ]);
        }
        final top = _top2NavChildren(cur, qLowSimd);
        final bestIdx = top.bestIdx;
        final secondIdx = top.secondIdx;
        final bestScore = top.bestScore;
        final secondScore = top.secondScore;
        // Remember near-second mid child at this hop; overwritten each hop so
        // only the last mid (parent of leaf-level) dual-forks.
        dualMidChildId = null;
        dualMidPath = null;
        if (secondIdx >= 0 && secondScore >= bestScore * _boundaryDualRatio) {
          final altId = cur.entries[secondIdx].childPageId;
          if (!altId.isNone) {
            dualMidChildId = altId;
            dualMidPath = [
              ...path,
              (pageId: curId, page: cur, childIdx: secondIdx),
            ];
          }
        }
        final childId = cur.entries[bestIdx].childPageId;
        if (childId.isNone) {
          throw DbException([
            GeneralStatus(
              type: ResultType.engError,
              message:
                  'NGH insert mid entry has no child page (root=$rootId, page=$curId).',
            )
          ]);
        }
        path.add((pageId: curId, page: cur, childIdx: bestIdx));
        curId = childId;
        final next = resolveInsertNav(curId);
        if (next == null) return false;
        cur = next;
      }

      if (cur.entries.isEmpty) {
        final (leafPtrs, leafMeta) = _partitionManager.allocatePagesBatchSync(
          NghDataCategory.leaf,
          currentMeta,
          1,
        );
        currentMeta = leafMeta;
        final leafPtr = leafPtrs.first;
        final leafId = NghPageId(leafPtr.partitionNo, leafPtr.pageNo);
        final leafCentroidId = ++state.nextCentroidId;
        final leafPage = NghLeafPage(
          centroidId: leafCentroidId,
          dimensions: currentMeta.dimensions,
          slots: <NghLeafSlot>[],
        )..addSlot(newSlot);
        insertLeaves[leafId] = leafPage;
        dirtyLeafPages[leafPtr] = leafPage;

        final entry = CentroidBranchEntry(
          centroidId: leafCentroidId,
          leafPageId: leafId,
          leafSlotCount: 1,
          centroid48D: leafPage.normalizedMean48(),
        );
        cur.entries.add(entry);
        markInsertNav(curId, cur);
        bubbleSummaryUp(
          rootId: rootId,
          childId: curId,
          childPage: cur,
          path: path,
        );
        return true;
      }

      CentroidBranchEntry? bestEntry;
      CentroidBranchEntry? secondEntry;
      var bestScore = -1e9;
      var secondScore = -1e9;
      final leafTop = _top2NavChildren(cur, qLowSimd);
      if (cur.entries.isNotEmpty) {
        bestEntry = cur.entries[leafTop.bestIdx];
        bestScore = leafTop.bestScore;
        if (leafTop.secondIdx >= 0) {
          secondEntry = cur.entries[leafTop.secondIdx];
          secondScore = leafTop.secondScore;
        }
      }

      final owner = (pageId: curId, page: cur);
      if (!insertSlotIntoLeafSync(
        rootId,
        bestEntry!,
        owner,
        path,
        newSlot,
      )) {
        return false;
      }
      // Leaf-level dual-home under the same nav page (boundary vectors).
      if (secondEntry != null &&
          !identical(secondEntry, bestEntry) &&
          secondScore >= bestScore * _boundaryDualRatio) {
        insertSlotIntoLeafSync(
          rootId,
          secondEntry,
          owner,
          path,
          newSlot,
        );
      }
      // Mid dual-fork: also plant under the near-second mid child.
      final midAltId = dualMidChildId;
      final midAltPath = dualMidPath;
      if (midAltId != null && midAltPath != null) {
        final alt = resolveInsertNav(midAltId);
        if (alt != null && alt.isLeafLevel && alt.entries.isNotEmpty) {
          final altTop = _top2NavChildren(alt, qLowSimd);
          final altBest = alt.entries[altTop.bestIdx];
          insertSlotIntoLeafSync(
            rootId,
            altBest,
            (pageId: midAltId, page: alt),
            midAltPath,
            newSlot,
          );
        }
      }
      return true;
    }

    Future<void> insertIntoRoot(
      int rootId,
      NghLeafSlot newSlot,
      Float32x4List qLowSimd,
    ) async {
      if (insertIntoRootSync(rootId, newSlot, qLowSimd)) return;

      await ensureInsertRootNav(rootId);

      var headId = state!.firstInternalByRoot[rootId];
      if (headId.isNone) {
        final (pPtrs, pMeta) = _partitionManager.allocatePagesBatchSync(
          NghDataCategory.nav,
          currentMeta,
          1,
        );
        currentMeta = pMeta;
        final pPtr = pPtrs.first;
        headId = NghPageId(pPtr.partitionNo, pPtr.pageNo);
        final emptyP = NghNavBTreePage(
          rootCentroidId: rootId,
          flags: NghNavBTreePage.flagLeafLevel,
          entries: [],
        );
        markInsertNav(headId, emptyP);
        state.setFirstInternal(rootId, headId);
      }

      var curId = headId;
      NghNavBTreePage cur =
          resolveInsertNav(curId) ?? await loadInsertNav(curId);
      final path = <({NghPageId pageId, NghNavBTreePage page, int childIdx})>[];

      var hop = 0;
      NghPageId? dualMidChildId;
      List<({NghPageId pageId, NghNavBTreePage page, int childIdx})>?
          dualMidPath;
      while (!cur.isLeafLevel) {
        if (++hop > NghNavBTreePage.maxTreeHops) {
          throw DbException([
            GeneralStatus(
              type: ResultType.engError,
              message:
                  'NGH insert descent exceeded maxTreeHops=${NghNavBTreePage.maxTreeHops} '
                  '(root=$rootId). Refusing to rewrite a mid page as a leaf.',
            )
          ]);
        }
        if (cur.entries.isEmpty) {
          throw DbException([
            GeneralStatus(
              type: ResultType.engError,
              message:
                  'NGH insert mid nav page has no children (root=$rootId, page=$curId).',
            )
          ]);
        }
        final top = _top2NavChildren(cur, qLowSimd);
        final bestIdx = top.bestIdx;
        final secondIdx = top.secondIdx;
        final bestScore = top.bestScore;
        final secondScore = top.secondScore;
        dualMidChildId = null;
        dualMidPath = null;
        if (secondIdx >= 0 && secondScore >= bestScore * _boundaryDualRatio) {
          final altId = cur.entries[secondIdx].childPageId;
          if (!altId.isNone) {
            dualMidChildId = altId;
            dualMidPath = [
              ...path,
              (pageId: curId, page: cur, childIdx: secondIdx),
            ];
          }
        }
        final childId = cur.entries[bestIdx].childPageId;
        if (childId.isNone) {
          throw DbException([
            GeneralStatus(
              type: ResultType.engError,
              message:
                  'NGH insert mid entry has no child page (root=$rootId, page=$curId).',
            )
          ]);
        }
        path.add((pageId: curId, page: cur, childIdx: bestIdx));
        curId = childId;
        final next = resolveInsertNav(curId);
        cur = next ?? await loadInsertNav(curId);
      }

      if (cur.entries.isEmpty) {
        final (leafPtrs, leafMeta) = _partitionManager.allocatePagesBatchSync(
          NghDataCategory.leaf,
          currentMeta,
          1,
        );
        currentMeta = leafMeta;
        final leafPtr = leafPtrs.first;
        final leafId = NghPageId(leafPtr.partitionNo, leafPtr.pageNo);
        final leafCentroidId = ++state!.nextCentroidId;
        final leafPage = NghLeafPage(
          centroidId: leafCentroidId,
          dimensions: currentMeta.dimensions,
          slots: <NghLeafSlot>[],
        )..addSlot(newSlot);
        insertLeaves[leafId] = leafPage;
        dirtyLeafPages[leafPtr] = leafPage;

        final entry = CentroidBranchEntry(
          centroidId: leafCentroidId,
          leafPageId: leafId,
          leafSlotCount: 1,
          centroid48D: leafPage.normalizedMean48(),
        );
        cur.entries.add(entry);
        markInsertNav(curId, cur);
        bubbleSummaryUp(
          rootId: rootId,
          childId: curId,
          childPage: cur,
          path: path,
        );
        return;
      }

      CentroidBranchEntry? bestEntry;
      CentroidBranchEntry? secondEntry;
      var bestScore = -1e9;
      var secondScore = -1e9;
      final leafTop = _top2NavChildren(cur, qLowSimd);
      if (cur.entries.isNotEmpty) {
        bestEntry = cur.entries[leafTop.bestIdx];
        bestScore = leafTop.bestScore;
        if (leafTop.secondIdx >= 0) {
          secondEntry = cur.entries[leafTop.secondIdx];
          secondScore = leafTop.secondScore;
        }
      }

      final owner = (pageId: curId, page: cur);
      await insertSlotIntoLeaf(
        rootId,
        bestEntry!,
        owner,
        path,
        newSlot,
      );
      if (secondEntry != null &&
          !identical(secondEntry, bestEntry) &&
          secondScore >= bestScore * _boundaryDualRatio) {
        await insertSlotIntoLeaf(
          rootId,
          secondEntry,
          owner,
          path,
          newSlot,
        );
      }
      final midAltId = dualMidChildId;
      final midAltPath = dualMidPath;
      if (midAltId != null && midAltPath != null) {
        final alt = resolveInsertNav(midAltId) ?? await loadInsertNav(midAltId);
        if (alt.isLeafLevel && alt.entries.isNotEmpty) {
          final altTop = _top2NavChildren(alt, qLowSimd);
          await insertSlotIntoLeaf(
            rootId,
            alt.entries[altTop.bestIdx],
            (pageId: midAltId, page: alt),
            midAltPath,
            newSlot,
          );
        }
      }
    }

    NghPageId? peekBestLeafSync(int rootId, Float32x4List qLowSimd) {
      var curId = state!.firstInternalByRoot[rootId];
      if (curId.isNone) return null;
      final head = resolveInsertNav(curId);
      if (head == null) return null;
      var cur = head;
      var hop = 0;
      while (!cur.isLeafLevel) {
        if (++hop > NghNavBTreePage.maxTreeHops || cur.entries.isEmpty) {
          return null;
        }
        final bestIdx = _top2NavChildren(cur, qLowSimd).bestIdx;
        final childId = cur.entries[bestIdx].childPageId;
        if (childId.isNone) return null;
        curId = childId;
        final next = resolveInsertNav(curId);
        if (next == null) return null;
        cur = next;
      }
      if (cur.entries.isEmpty) return null;
      final best = cur.entries[_top2NavChildren(cur, qLowSimd).bestIdx];
      return best.leafPageId;
    }

    Float32List normalize48InPlace(Float32List v) {
      var nSq = 0.0;
      for (int d = 0; d < 48; d++) {
        nSq += v[d] * v[d];
      }
      if (nSq > 1e-12) {
        final inv = 1.0 / sqrt(nSq);
        for (int d = 0; d < 48; d++) {
          v[d] *= inv;
        }
      }
      return v;
    }

    void refreshRootCentroidFromHead(int rootId) {
      if (rootId < 0 || rootId >= state!.numRootCentroids) return;
      final headId = state.firstInternalByRoot[rootId];
      if (headId.isNone) return;
      final page = resolveInsertNav(headId);
      if (page == null || page.entries.isEmpty) return;
      state.setRootCentroid48(
        rootId,
        normalize48InPlace(_mean48BranchEntries(page.entries)),
      );
    }

    /// Far from all L0 → new root + empty leaf-level head (no leaf rewrite).
    int? spawnFarL0Root(Float32List low48) {
      if (!state!.canGrowRoot) return null;
      final (navPtrs, navMeta) = _partitionManager.allocatePagesBatchSync(
        NghDataCategory.nav,
        currentMeta,
        1,
      );
      currentMeta = navMeta;
      final ptr = navPtrs.first;
      final pageId = NghPageId(ptr.partitionNo, ptr.pageNo);
      final seed = normalize48InPlace(Float32List.fromList(low48));
      final newRootId = state.numRootCentroids;
      final page = NghNavBTreePage(
        rootCentroidId: newRootId,
        flags: NghNavBTreePage.flagLeafLevel,
        entries: [],
      );
      final assigned = state.appendRoot(
        centroid48D: seed,
        firstInternal: pageId,
      );
      if (assigned < 0) return null;
      markInsertNav(pageId, page);
      insertNavRootsReady.add(assigned);
      return assigned;
    }

    /// Split heaviest L0 firstInternal into two L0 roots (local nav only).
    /// Returns true when a split was applied.
    bool tryHeavyRootSplitOnce() {
      if (!state!.canGrowRoot || state.numRootCentroids <= 0) return false;
      var bestRoot = -1;
      var bestWeight = 0;
      var secondWeight = 0;
      var weightSum = 0;
      var weighedRoots = 0;
      NghNavBTreePage? bestPage;
      NghPageId? bestPageId;
      for (int r = 0; r < state.numRootCentroids; r++) {
        final hid = state.firstInternalByRoot[r];
        if (hid.isNone) continue;
        final page = resolveInsertNav(hid);
        if (page == null || page.entries.length < 2) continue;
        final w = _branchEntriesWeight(page.entries);
        weightSum += w;
        weighedRoots++;
        if (w > bestWeight) {
          secondWeight = bestWeight;
          bestWeight = w;
          bestRoot = r;
          bestPage = page;
          bestPageId = hid;
        } else if (w > secondWeight) {
          secondWeight = w;
        }
      }
      if (bestRoot < 0 || bestPage == null || bestPageId == null) return false;

      final projectedN = currentMeta.totalVectors + vectors.length;
      final fair = max(1, projectedN ~/ max(1, state.numRootCentroids));
      final avgW = weighedRoots > 0 ? max(1, weightSum ~/ weighedRoots) : fair;
      // Split earlier so L0 stays balanced through multi-M growth (rebuild).
      final heavyThresh = max(512, min(fair, avgW) * 115 ~/ 100); // ~1.15×
      final peerHot = secondWeight > 0 && bestWeight >= secondWeight * 3 ~/ 2;
      if (bestWeight < heavyThresh && !peerHot) return false;

      final (left, right) = _splitBranchEntriesBalanced(
        List<CentroidBranchEntry>.from(bestPage.entries),
      );
      if (left.isEmpty || right.isEmpty) return false;

      final wasLeaf = bestPage.isLeafLevel;
      bestPage.entries
        ..clear()
        ..addAll(left);
      bestPage.isLeafLevel = wasLeaf;
      markInsertNav(bestPageId, bestPage);
      state.setRootCentroid48(
        bestRoot,
        normalize48InPlace(_mean48BranchEntries(left)),
      );

      final (rightPtrs, rightMeta) = _partitionManager.allocatePagesBatchSync(
        NghDataCategory.nav,
        currentMeta,
        1,
      );
      currentMeta = rightMeta;
      final rightPtr = rightPtrs.first;
      final rightId = NghPageId(rightPtr.partitionNo, rightPtr.pageNo);
      final newRootId = state.numRootCentroids;
      final rightMean = normalize48InPlace(_mean48BranchEntries(right));
      final rightPage = NghNavBTreePage(
        rootCentroidId: newRootId,
        flags: wasLeaf ? NghNavBTreePage.flagLeafLevel : 0,
        entries: right,
      );
      final assigned = state.appendRoot(
        centroid48D: rightMean,
        firstInternal: rightId,
      );
      if (assigned < 0) return false;
      markInsertNav(rightId, rightPage);
      insertNavRootsReady.add(assigned);
      return true;
    }

    void tryHeavyRootSplit() {
      // Grow L0 toward target/page-fit: more splits while under-target.
      final budget = !state!.canGrowRoot
          ? 0
          : (state.numRootCentroids < _targetL0Roots ? 4 : 3);
      for (int i = 0; i < budget; i++) {
        if (!tryHeavyRootSplitOnce()) break;
      }
    }

    /// Tiny cold-start (1 / 100 rows) leaves L0 far below the sample-rich
    /// target. Far-spawn + heavy-split alone never catch a subsequent 10k
    /// flush (depth1–70 recall cliff, self_rc dips). Seed empty L0 heads from
    /// this batch once — O(sample×k), no leaf rewrite.
    void expandUndersizedL0FromBatch() {
      if (!state!.canGrowRoot || vectors.isEmpty) return;
      final projectedN = currentMeta.totalVectors + vectors.length;
      final want = min(state.maxRoots, _initialL0RootCount(projectedN));
      var need = want - state.numRootCentroids;
      if (need <= 0) return;
      // Skip micro flushes that cannot justify k-means; wait for a real batch
      // or until projected corpus crosses bootstrap.
      if (vectors.length < 64 && projectedN < _bootstrapMinVectors) return;

      final sampleCap = min(2048, vectors.length);
      final step = max(1, vectors.length ~/ sampleCap);
      final samples = <Float32List>[];
      for (var i = 0;
          i < vectors.length && samples.length < sampleCap;
          i += step) {
        samples.add(_extractLow48(normalizedVectors[i]));
      }
      if (samples.isEmpty) return;
      need = min(
          need, min(samples.length, state.maxRoots - state.numRootCentroids));
      if (need <= 0) return;
      final seeds = _kMeansInit48(
        samples: samples,
        k: need,
        iterations: samples.length >= 256 ? 4 : 3,
      );
      for (final seed in seeds) {
        if (!state.canGrowRoot) break;
        spawnFarL0Root(seed);
      }
    }

    expandUndersizedL0FromBatch();

    // Pin L0 heads for roots this batch is likely to touch (L0 scores).
    final pinRoots = <int>{};
    for (int i = 0; i < vectors.length; i++) {
      final fullVec = normalizedVectors[i];
      final lowVec = _extractLow48(fullVec);
      insertQLow.setRange(0, 48, lowVec);
      final qLowSimd = insertQLowSimd;
      int bestRoot0 = 0, bestRoot1 = 0;
      double maxScore0 = -1e9, maxScore1 = -1e9;
      for (int r = 0; r < state.numRootCentroids; r++) {
        final s = innerProduct48(qLowSimd, state.rootCentroids48Simd, r * 12);
        if (s > maxScore0) {
          maxScore1 = maxScore0;
          bestRoot1 = bestRoot0;
          maxScore0 = s;
          bestRoot0 = r;
        } else if (s > maxScore1) {
          maxScore1 = s;
          bestRoot1 = r;
        }
      }
      pinRoots.add(bestRoot0);
      if (maxScore1 >= maxScore0 * _boundaryDualRatio) pinRoots.add(bestRoot1);
    }
    for (final rootId in pinRoots) {
      await ensureInsertRootNav(rootId);
    }

    final neededLeafIds = <NghPageId>{};
    for (int i = 0; i < vectors.length; i++) {
      final fullVec = normalizedVectors[i];
      final lowVec = _extractLow48(fullVec);
      insertQLow.setRange(0, 48, lowVec);
      final qLowSimd = insertQLowSimd;
      int bestRoot0 = 0, bestRoot1 = 0;
      double maxScore0 = -1e9, maxScore1 = -1e9;
      for (int r = 0; r < state.numRootCentroids; r++) {
        final s = innerProduct48(qLowSimd, state.rootCentroids48Simd, r * 12);
        if (s > maxScore0) {
          maxScore1 = maxScore0;
          bestRoot1 = bestRoot0;
          maxScore0 = s;
          bestRoot0 = r;
        } else if (s > maxScore1) {
          maxScore1 = s;
          bestRoot1 = r;
        }
      }
      final leaf0 = peekBestLeafSync(bestRoot0, qLowSimd);
      if (leaf0 != null && !leaf0.isNone) neededLeafIds.add(leaf0);
      if (maxScore1 >= maxScore0 * _boundaryDualRatio) {
        final leaf1 = peekBestLeafSync(bestRoot1, qLowSimd);
        if (leaf1 != null && !leaf1.isNone) neededLeafIds.add(leaf1);
      }
    }
    if (neededLeafIds.isNotEmpty) {
      await _hydrateBTreeLeaves(
        table: table,
        indexUid: indexUid,
        meta: currentMeta,
        leafIds: neededLeafIds,
        insertScratch: insertLeaves,
      );
    }

    // Globally unique nodeIds across flushes
    final baseNodeId = currentMeta.nextNodeId;
    for (int i = 0; i < vectors.length; i++) {
      final fullVec = normalizedVectors[i];
      final pk = primaryKeys[i];
      final lowVec = _extractLow48(fullVec);

      insertQLow.setRange(0, 48, lowVec);
      final qLowSimd = insertQLowSimd;

      final sq8 = ScalarQuantizer.quantize(fullVec);
      final pkBytes = Uint8List.fromList(utf8.encode(pk));
      final newSlot = NghLeafSlot(
        nodeId: baseNodeId + i,
        primaryKey: pk,
        primaryKeyBytes: pkBytes,
        sq8Codes: sq8.codes,
        offset: sq8.offset,
        scale: sq8.scale,
        squaredNorm: sq8.squaredNorm,
        low48D: lowVec,
      );

      int bestRoot0 = 0, bestRoot1 = 0;
      double maxScore0 = -1e9, maxScore1 = -1e9;
      for (int r = 0; r < state.numRootCentroids; r++) {
        final s = innerProduct48(qLowSimd, state.rootCentroids48Simd, r * 12);
        if (s > maxScore0) {
          maxScore1 = maxScore0;
          bestRoot1 = bestRoot0;
          maxScore0 = s;
          bestRoot0 = r;
        } else if (s > maxScore1) {
          maxScore1 = s;
          bestRoot1 = r;
        }
      }

      // Far from every L0 → spawn a precise new root (keeps wantLeaves fixed).
      final farThresh = _l0FarSpawnThreshold(
        state.numRootCentroids,
        maxRoots: state.maxRoots,
      );
      if (state.canGrowRoot && maxScore0 < farThresh) {
        final spawned = spawnFarL0Root(lowVec);
        if (spawned != null) {
          if (!insertIntoRootSync(spawned, newSlot, qLowSimd)) {
            await insertIntoRoot(spawned, newSlot, qLowSimd);
          }
          continue;
        }
      }

      if (!insertIntoRootSync(bestRoot0, newSlot, qLowSimd)) {
        await insertIntoRoot(bestRoot0, newSlot, qLowSimd);
      }
      // Boundary dual-assign — ratio calibrated for 768D multi-M (was 0.94).
      if (maxScore1 >= maxScore0 * _boundaryDualRatio) {
        if (!insertIntoRootSync(bestRoot1, newSlot, qLowSimd)) {
          await insertIntoRoot(bestRoot1, newSlot, qLowSimd);
        }
      }
    }

    // Refresh every resident L0 head so cold k-means seeds drift toward live
    // subtree mass without leaf rewrite / extra I/O.
    for (int r = 0; r < state.numRootCentroids; r++) {
      refreshRootCentroidFromHead(r);
    }
    // At most two heavy-root splits per batch (O(1) nav pages).
    tryHeavyRootSplit();

    // Persist root table when nextCentroidId advanced, cold-start dirtied it,
    // or open recovered a legacy nextCentroidId that still needs a disk write.
    if (state.nextCentroidId != initialNextCentroidId ||
        dirtyNavRootPage != null ||
        state.rootTableNeedsPersist) {
      state.rootTableNeedsPersist = false;
      final rootsList = <({
        int rootId,
        NghPageId firstInternalPage,
        Float32List centroid48D
      })>[];
      for (int r = 0; r < state.numRootCentroids; r++) {
        final c48 = Float32List(48);
        for (int d = 0; d < 48; d++) {
          c48[d] = state.rootCentroids48Flat[r * 48 + d];
        }
        rootsList.add((
          rootId: r,
          firstInternalPage: state.firstInternalByRoot[r],
          centroid48D: c48,
        ));
      }
      final rootPtr = dirtyNavRootPage?.ptr ??
          NghPagePtr(
            NghDataCategory.nav,
            state.rootPageId.partitionNo,
            state.rootPageId.pageNo,
          );
      dirtyNavRootPage = (
        ptr: rootPtr,
        page: NghNavRootPage(
          lowDim: 48,
          fullDim: currentMeta.dimensions,
          nextCentroidId: state.nextCentroidId,
          roots: rootsList,
        ),
      );
    }

    // Promote all touched L1 pages (descent paths + dirty) into the budgeted search-hot nav cache.
    for (final e in insertNavPages.entries) {
      if (e.key.isNone || e.key.pageNo <= 0) continue;
      _navInternalPut(
        table.tableUid,
        indexUid,
        e.key,
        e.value,
      );
    }
    for (final e in dirtyNavBTreePages.entries) {
      final ptr = e.key;
      _navInternalPut(
        table.tableUid,
        indexUid,
        NghPageId(ptr.partitionNo, ptr.pageNo),
        e.value,
      );
    }
    // Search scores [_btreeLeafCache] only. Pin dirty leaves now; [_btreeLeafPut]
    // evicts any leaf I/O twin (steady-state: no dual residency).
    for (final e in dirtyLeafPages.entries) {
      final ptr = e.key;
      if (ptr.category != NghDataCategory.leaf) continue;
      if (ptr.isNull || ptr.pageNo <= 0) continue;
      _btreeLeafPut(
        table.tableUid,
        indexUid,
        NghPageId(ptr.partitionNo, ptr.pageNo),
        e.value,
      );
    }

    // Populate exact PK Map locators
    final pkBatch = NghPkMapBatch(meta: currentMeta);
    final pkLocators = <String, List<NghPkLocator>>{};
    for (final entry in dirtyLeafPages.entries) {
      final ptr = entry.key;
      final page = entry.value;
      // Keep insert-hot pages searchable without a cold low48 rebuild.
      page.ensureLow48Ready();
      for (int s = 0; s < page.slots.length; s++) {
        final slot = page.slots[s];
        if (slot.isDeleted) continue;
        pkLocators.putIfAbsent(slot.primaryKey, () => []).add(
              NghPkLocator(
                centroidId: page.centroidId,
                partitionNo: ptr.partitionNo,
                pageNo: ptr.pageNo,
                slotIndex: s,
              ),
            );
      }
    }

    final pkEntries = <NghPkMapWrite>[];
    for (final e in pkLocators.entries) {
      final old = pkBatch.meta.pkmapRootIsNull
          ? const <NghPkLocator>[]
          : await _pkMap.lookup(
              table: table,
              indexUid: indexUid,
              batch: pkBatch,
              key: _pkMapKey(e.key),
            );
      final merged = <NghPkLocator>[
        for (final l in old)
          if (!dirtyLeafPages.containsKey(NghPagePtr(
            NghDataCategory.leaf,
            l.partitionNo,
            l.pageNo,
          )))
            l,
        ...e.value,
      ];
      var locs = merged;
      if (locs.length > NghPkLocator.maxLocatorsPerPk) {
        locs = locs.sublist(0, NghPkLocator.maxLocatorsPerPk);
      }
      pkEntries.add(NghPkMapWrite(
        key: _pkMapKey(e.key),
        locators: locs,
      ));
    }
    pkEntries.sort((a, b) => MemComparableKey.compare(a.key, b.key));
    await _pkMap.upsertSorted(
      table: table,
      indexUid: indexUid,
      batch: pkBatch,
      entries: pkEntries,
      rewrittenIds: const {},
    );
    currentMeta = pkBatch.meta.copyWith(
      centroidCount: state.numRootCentroids,
      nextNodeId: baseNodeId + vectors.length,
    );

    return NghInsertResult(
      meta: currentMeta,
      dirtyLeafPages: dirtyLeafPages,
      dirtyNavBTreePages: dirtyNavBTreePages,
      dirtyNavRootPage: dirtyNavRootPage,
      dirtyPkmapPages: pkBatch.dirty,
      insertedCount: vectors.length,
      touchedNavPages: insertNavPages,
    );
  }

  /// Synchronous ANN when btree state + probed leaves are already resident.
  /// Returns null when I/O / cold load is required (caller should [search]).
  List<NghSearchResult>? searchHotSync({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required Float32List query,
    required int topK,
    int? searchDepth,
    double? distanceThreshold,
    bool queryAlreadyNormalized = false,
    Set<String>? pendingDeletePks,
  }) {
    if (meta.totalVectors == 0) return const [];
    final cached = _btreeStates[_cacheKey(table.tableUid, indexUid)];
    if (cached == null || cached.numRootCentroids <= 0) return null;
    final scratch = _acquireSearchScratch(meta.dimensions);
    try {
      return _searchCentroidBTreeTryHot(
        table: table,
        indexUid: indexUid,
        meta: meta,
        state: cached,
        scratch: scratch,
        query: query,
        topK: topK,
        searchDepth: searchDepth,
        distanceThreshold: distanceThreshold,
        queryAlreadyNormalized: queryAlreadyNormalized,
        pendingDeletePks: pendingDeletePks,
        allowHydrate: false,
      ).sync;
    } finally {
      _releaseSearchScratch(scratch);
    }
  }

  /// Perform ANN search on the NGH index.
  ///
  /// Steps:
  ///   1. Exact centroid routing on in-memory navigating graph
  ///   2. On-demand load only probed leaves (prewarmed: 0 I/O)
  ///   3. SQ8 distance scoring across all slots in probed leaves
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
  }) {
    if (meta.totalVectors == 0) {
      return Future<List<NghSearchResult>>.value(const []);
    }

    final key = _cacheKey(table.tableUid, indexUid);
    final cached = _btreeStates[key];
    if (cached != null && cached.numRootCentroids > 0) {
      return _searchCentroidBTree(
        table: table,
        indexUid: indexUid,
        meta: meta,
        state: cached,
        query: query,
        topK: topK,
        searchDepth: searchDepth,
        distanceThreshold: distanceThreshold,
        queryAlreadyNormalized: queryAlreadyNormalized,
        pendingDeletePks: pendingDeletePks,
      );
    }
    return _searchCentroidBTreeLoad(
      table: table,
      indexUid: indexUid,
      meta: meta,
      query: query,
      topK: topK,
      searchDepth: searchDepth,
      distanceThreshold: distanceThreshold,
      queryAlreadyNormalized: queryAlreadyNormalized,
      pendingDeletePks: pendingDeletePks,
    );
  }

  Future<List<NghSearchResult>> _searchCentroidBTreeLoad({
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
    final btreeState = await _getOrLoadBTreeState(table, indexUid, meta);
    if (btreeState == null || btreeState.numRootCentroids <= 0) {
      return const [];
    }
    return _searchCentroidBTree(
      table: table,
      indexUid: indexUid,
      meta: meta,
      state: btreeState,
      query: query,
      topK: topK,
      searchDepth: searchDepth,
      distanceThreshold: distanceThreshold,
      queryAlreadyNormalized: queryAlreadyNormalized,
      pendingDeletePks: pendingDeletePks,
    );
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
        dirtyLeafPages: const {},
        insertedCount: 0,
      );
    }

    return _insertBatchCentroidBTree(
      table: table,
      indexUid: indexUid,
      meta: meta,
      vectors: vectors,
      primaryKeys: primaryKeys,
      yieldBudgetMs: yieldBudgetMs,
    );
  }

  Uint8List _pkMapKey(String pk) => MemComparableKey.encodeTextLex(pk);

  Float32List _normalize48Mean(Float32List v) {
    var nSq = 0.0;
    for (int d = 0; d < 48; d++) {
      nSq += v[d] * v[d];
    }
    if (nSq <= 1e-12) return v;
    final inv = 1.0 / sqrt(nSq);
    for (int d = 0; d < 48; d++) {
      v[d] *= inv;
    }
    return v;
  }

  ({NghPagePtr ptr, NghNavRootPage page}) _encodeNavRootPage(
    CentroidBTreeState state,
    int dimensions,
  ) {
    final rootsList = <({
      int rootId,
      NghPageId firstInternalPage,
      Float32List centroid48D
    })>[];
    for (int r = 0; r < state.numRootCentroids; r++) {
      final c48 = Float32List(48);
      for (int d = 0; d < 48; d++) {
        c48[d] = state.rootCentroids48Flat[r * 48 + d];
      }
      rootsList.add((
        rootId: r,
        firstInternalPage: state.firstInternalByRoot[r],
        centroid48D: c48,
      ));
    }
    return (
      ptr: NghPagePtr(
        NghDataCategory.nav,
        state.rootPageId.partitionNo,
        state.rootPageId.pageNo,
      ),
      page: NghNavRootPage(
        lowDim: 48,
        fullDim: dimensions,
        nextCentroidId: state.nextCentroidId,
        roots: rootsList,
      ),
    );
  }

  Future<
      ({
        int rootId,
        NghPageId navId,
        NghNavBTreePage navPage,
        int entryIdx,
        List<({NghPageId pageId, NghNavBTreePage page, int childIdx})> path,
      })?> _locateLeafNavEntry({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required CentroidBTreeState state,
    required NghPageId leafId,
    required Float32x4List leafMeanSimd,
    required Map<NghPagePtr, NghNavBTreePage> dirtyNav,
  }) async {
    Future<NghNavBTreePage?> load(NghPageId id, {bool touch = true}) async {
      if (id.isNone) return null;
      final hit = _resolveNavInternalPage(
        tableUid: table.tableUid,
        indexUid: indexUid,
        id: id,
        dirtyOverlay: dirtyNav,
        touch: touch,
      );
      if (hit != null) return hit;
      final loaded = await _partitionManager.readNavBTreePage(
        table,
        indexUid,
        id,
        meta: meta,
      );
      if (loaded == null) return null;
      _navInternalPut(table.tableUid, indexUid, id, loaded);
      return loaded;
    }

    ({
      int rootId,
      NghPageId navId,
      NghNavBTreePage navPage,
      int entryIdx,
      List<({NghPageId pageId, NghNavBTreePage page, int childIdx})> path,
    })? scanLeafLevel(
      int rootId,
      NghPageId id,
      NghNavBTreePage page,
      List<({NghPageId pageId, NghNavBTreePage page, int childIdx})> path,
    ) {
      final key = leafId.cacheKey;
      for (int i = 0; i < page.entries.length; i++) {
        if (page.entries[i].childPageId.cacheKey == key) {
          return (
            rootId: rootId,
            navId: id,
            navPage: page,
            entryIdx: i,
            path: path,
          );
        }
      }
      return null;
    }

    ({
      int rootId,
      NghPageId navId,
      NghNavBTreePage navPage,
      int entryIdx,
      List<({NghPageId pageId, NghNavBTreePage page, int childIdx})> path,
    })? walkCached(
      int rootId,
      NghPageId id,
      List<({NghPageId pageId, NghNavBTreePage page, int childIdx})> path,
      int hop,
    ) {
      if (hop > NghNavBTreePage.maxTreeHops) return null;
      final page = _resolveNavInternalPage(
        tableUid: table.tableUid,
        indexUid: indexUid,
        id: id,
        dirtyOverlay: dirtyNav,
        touch: false,
      );
      if (page == null) return null;
      if (page.isLeafLevel) {
        return scanLeafLevel(rootId, id, page, path);
      }
      for (int i = 0; i < page.entries.length; i++) {
        final child = page.entries[i].childPageId;
        if (child.isNone) continue;
        final hit = walkCached(
          rootId,
          child,
          [...path, (pageId: id, page: page, childIdx: i)],
          hop + 1,
        );
        if (hit != null) return hit;
      }
      return null;
    }

    for (int r = 0; r < state.numRootCentroids; r++) {
      final head = state.firstInternalByRoot[r];
      if (head.isNone) continue;
      final hit = walkCached(
        r,
        head,
        <({NghPageId pageId, NghNavBTreePage page, int childIdx})>[],
        0,
      );
      if (hit != null) return hit;
    }

    final nRoots = state.numRootCentroids;
    final order = List<int>.generate(nRoots, (i) => i);
    final scores = Float64List(nRoots);
    for (int r = 0; r < nRoots; r++) {
      scores[r] = innerProduct48(
        leafMeanSimd,
        state.rootCentroids48Simd,
        r * 12,
      );
    }
    order.sort((a, b) => scores[b].compareTo(scores[a]));

    for (final rootId in order) {
      var curId = state.firstInternalByRoot[rootId];
      if (curId.isNone) continue;
      final first = await load(curId);
      if (first == null) continue;
      var cur = first;
      final path = <({NghPageId pageId, NghNavBTreePage page, int childIdx})>[];
      var hop = 0;
      var missed = false;
      while (!cur.isLeafLevel) {
        if (++hop > NghNavBTreePage.maxTreeHops || cur.entries.isEmpty) {
          missed = true;
          break;
        }
        final bestIdx = _top2NavChildren(cur, leafMeanSimd).bestIdx;
        final childId = cur.entries[bestIdx].childPageId;
        if (childId.isNone) {
          missed = true;
          break;
        }
        path.add((pageId: curId, page: cur, childIdx: bestIdx));
        curId = childId;
        final next = await load(curId);
        if (next == null) {
          missed = true;
          break;
        }
        cur = next;
      }
      if (missed) continue;
      final direct = scanLeafLevel(rootId, curId, cur, path);
      if (direct != null) return direct;
      if (path.isEmpty) continue;
      final parent = path.last;
      for (int i = 0; i < parent.page.entries.length; i++) {
        if (i == parent.childIdx) continue;
        final sibId = parent.page.entries[i].childPageId;
        if (sibId.isNone) continue;
        final sib = await load(sibId);
        if (sib == null || !sib.isLeafLevel) continue;
        final sibPath = [
          ...path.sublist(0, path.length - 1),
          (pageId: parent.pageId, page: parent.page, childIdx: i),
        ];
        final sibHit = scanLeafLevel(rootId, sibId, sib, sibPath);
        if (sibHit != null) return sibHit;
      }
    }
    return null;
  }

  Future<
      ({
        Map<NghPagePtr, NghNavBTreePage> dirtyNav,
        ({NghPagePtr ptr, NghNavRootPage page})? dirtyRoot,
      })> _refreshNavAfterLeafDeletes({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required Map<NghPagePtr, NghLeafPage> dirtyLeaves,
  }) async {
    final dirtyNav = <NghPagePtr, NghNavBTreePage>{};
    if (dirtyLeaves.isEmpty) {
      return (dirtyNav: dirtyNav, dirtyRoot: null);
    }
    final state = await _getOrLoadBTreeState(table, indexUid, meta);
    if (state == null || state.numRootCentroids <= 0) {
      return (dirtyNav: dirtyNav, dirtyRoot: null);
    }

    void mark(NghPageId id, NghNavBTreePage page) {
      page.invalidateSearch48Pack();
      dirtyNav[NghPagePtr(
        NghDataCategory.nav,
        id.partitionNo,
        id.pageNo,
      )] = page;
      _navInternalPut(table.tableUid, indexUid, id, page);
    }

    final touchedRoots = <int>{};
    for (final e in dirtyLeaves.entries) {
      final ptr = e.key;
      if (ptr.category != NghDataCategory.leaf) continue;
      final leaf = e.value;
      final leafId = NghPageId(ptr.partitionNo, ptr.pageNo);
      final mean = leaf.normalizedMean48();
      final meanSimd = Float32x4List.sublistView(mean);
      final loc = await _locateLeafNavEntry(
        table: table,
        indexUid: indexUid,
        meta: meta,
        state: state,
        leafId: leafId,
        leafMeanSimd: meanSimd,
        dirtyNav: dirtyNav,
      );
      if (loc == null) continue;
      final entry = loc.navPage.entries[loc.entryIdx];
      entry.centroid48D = mean;
      entry.centroid48DSimd = Float32x4List.sublistView(mean);
      entry.childWeight = leaf.liveSlotCount;
      mark(loc.navId, loc.navPage);
      _bubbleNavSummaryUp(
        rootId: loc.rootId,
        childId: loc.navId,
        childPage: loc.navPage,
        path: loc.path,
        mark: mark,
      );
      touchedRoots.add(loc.rootId);
    }

    for (final r in touchedRoots) {
      if (r < 0 || r >= state.numRootCentroids) continue;
      final headId = state.firstInternalByRoot[r];
      if (headId.isNone) continue;
      final page = _resolveNavInternalPage(
        tableUid: table.tableUid,
        indexUid: indexUid,
        id: headId,
        dirtyOverlay: dirtyNav,
        touch: true,
      );
      if (page == null || page.entries.isEmpty) continue;
      state.setRootCentroid48(
        r,
        _normalize48Mean(_mean48BranchEntries(page.entries)),
      );
    }

    ({NghPagePtr ptr, NghNavRootPage page})? dirtyRoot;
    if (state.rootTableNeedsPersist) {
      state.rootTableNeedsPersist = false;
      dirtyRoot = _encodeNavRootPage(state, meta.dimensions);
    }
    return (dirtyNav: dirtyNav, dirtyRoot: dirtyRoot);
  }

  // =====================================================================
  // Deletion -- Tombstone in Leaf Pages
  // =====================================================================

  /// Mark leaf slots deleted via PK locator (never a full-leaf scan).
  Future<NghDeleteResult> deleteBatch({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required List<String> primaryKeys,
  }) async {
    if (primaryKeys.isEmpty) {
      return NghDeleteResult(meta: meta, deletedCount: 0);
    }

    var currentMeta = NghPageSizer.ensureIndexPageSizes(
      meta,
      _partitionManager.configuredPageSize,
    );
    final dirtyLeaves = <NghPagePtr, NghLeafPage>{};
    final pkBatch = NghPkMapBatch(meta: currentMeta);
    final unresolved = <String>[];
    var deleted = 0;

    Future<NghLeafPage?> loadPage(NghPkLocator loc) async {
      final ptr = NghPagePtr(NghDataCategory.leaf, loc.partitionNo, loc.pageNo);
      final existing = dirtyLeaves[ptr];
      if (existing != null) return existing;
      final pageId = NghPageId(loc.partitionNo, loc.pageNo);
      // Tombstone the search-hot instance so L2A pack is dropped in place.
      final hot = _btreeLeafGet(
        table.tableUid,
        indexUid,
        pageId,
        touch: false,
      );
      if (hot != null) return hot;
      return _partitionManager.readLeafPage(
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
      var pkHit = false;
      for (final loc in locs) {
        final page = await loadPage(loc);
        if (page == null) continue;
        var hit = false;
        for (final slot in page.slots) {
          if (!slot.isDeleted && slot.primaryKey == pk) {
            page.markSlotDeleted(slot);
            hit = true;
          }
        }
        if (!hit) continue;
        pkHit = true;
        dirtyLeaves[
                NghPagePtr(NghDataCategory.leaf, loc.partitionNo, loc.pageNo)] =
            page;
        _btreeLeafPut(
          table.tableUid,
          indexUid,
          NghPageId(loc.partitionNo, loc.pageNo),
          page,
        );
      }
      if (pkHit) deleted++;
      await _pkMap.remove(
        table: table,
        indexUid: indexUid,
        batch: pkBatch,
        key: _pkMapKey(pk),
      );
    }

    currentMeta = pkBatch.meta;

    final navRefresh = await _refreshNavAfterLeafDeletes(
      table: table,
      indexUid: indexUid,
      meta: currentMeta,
      dirtyLeaves: dirtyLeaves,
    );

    return NghDeleteResult(
      meta: currentMeta,
      dirtyLeafPages: dirtyLeaves,
      dirtyPkmapPages: pkBatch.dirty,
      dirtyNavBTreePages: navRefresh.dirtyNav,
      dirtyNavRootPage: navRefresh.dirtyRoot,
      deletedCount: deleted,
      unresolvedPks: unresolved,
    );
  }

  // =====================================================================
  // Synchronous Navigating Graph Routing & Soft-Margin Assignment
  // =====================================================================

  /// Fast synchronous check if navigating centroid graph is resident in memory.
  bool isNavGraphCached(
    TableContext table,
    IndexUid indexUid, {
    NghIndexMeta? meta,
  }) {
    final key = _cacheKey(table.tableUid, indexUid);
    final btree = _btreeStates[key];
    return btree != null && btree.numRootCentroids > 0;
  }

  /// Prefetch and cache the full paged nav graph (requires [meta] page counts).
  Future<void> prefetchNavGraph(
    TableContext table,
    IndexUid indexUid, {
    NghIndexMeta? meta,
  }) async {
    if (isNavGraphCached(table, indexUid, meta: meta)) return;
    if (meta == null) return;
    await _getOrLoadBTreeState(table, indexUid, meta);
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
    _scaleFloat32Into(v, out, inv);
    return out;
  }

  /// Normalize [v] into preallocated [out] (search hot path — no alloc).
  void _normalizeFloat32Into(Float32List v, Float32List out) {
    final len = min(v.length, out.length);
    double norm = 0;
    for (int i = 0; i < len; i++) {
      norm += v[i] * v[i];
    }
    if (norm == 0) {
      for (int i = 0; i < len; i++) {
        out[i] = v[i];
      }
      return;
    }
    _scaleFloat32Into(v, out, 1.0 / sqrt(norm));
  }

  @pragma('vm:prefer-inline')
  void _scaleFloat32Into(Float32List v, Float32List out, double inv) {
    final len = min(v.length, out.length);
    final n = len >> 2;
    if (n > 0 && (v.offsetInBytes & 15) == 0 && (out.offsetInBytes & 15) == 0) {
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
  }

  /// Rewrite physical leaves whose tombstone ratio is high.
  Future<NghCompactResult> compactTombstones({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    int maxVisitedPages = 100,
  }) async {
    final state = await _getOrLoadBTreeState(table, indexUid, meta);
    if (state == null || state.numRootCentroids <= 0) {
      return NghCompactResult(meta: meta, compactedCount: 0);
    }
    await _hydrateNavChainsForRoots(
      table: table,
      indexUid: indexUid,
      meta: meta,
      state: state,
      rootIds: Iterable<int>.generate(state.numRootCentroids),
    );

    final leafIds = <NghPageId>[];
    final seen = <int>{};
    void collect(NghNavBTreePage page, int depth) {
      if (depth > NghNavBTreePage.maxTreeHops) return;
      if (page.isLeafLevel) {
        for (final e in page.entries) {
          final id = e.leafPageId;
          if (id.isNone || !seen.add(id.cacheKey)) continue;
          leafIds.add(id);
        }
        return;
      }
      for (final e in page.entries) {
        if (e.childPageId.isNone) continue;
        final child = _navInternalGet(
          table.tableUid,
          indexUid,
          e.childPageId,
          touch: false,
        );
        if (child != null) collect(child, depth + 1);
      }
    }

    for (int rootId = 0; rootId < state.numRootCentroids; rootId++) {
      final head = state.firstInternalByRoot[rootId];
      if (head.isNone) continue;
      final page = _navInternalGet(
        table.tableUid,
        indexUid,
        head,
        touch: false,
      );
      if (page != null) collect(page, 0);
    }

    var currentMeta = NghPageSizer.ensureIndexPageSizes(
      meta,
      _partitionManager.configuredPageSize,
    );
    final dirtyLeaves = <NghPagePtr, NghLeafPage>{};
    final pkBatch = NghPkMapBatch(meta: currentMeta);
    var compacted = 0;
    var visited = 0;
    const minGarbageRatio = 0.35;

    for (final pid in leafIds) {
      if (visited >= maxVisitedPages) break;
      visited++;
      final ptr = NghPagePtr.fromPageId(NghDataCategory.leaf, pid);
      final page = dirtyLeaves[ptr] ??
          _btreeLeafGet(
            table.tableUid,
            indexUid,
            pid,
            touch: false,
          ) ??
          await _partitionManager.readLeafPage(
            table,
            indexUid,
            currentMeta,
            pid.partitionNo,
            pid.pageNo,
          );
      if (page == null) continue;
      final dead = page.slots.where((s) => s.isDeleted).length;
      if (page.slots.isEmpty || dead / page.slots.length < minGarbageRatio) {
        continue;
      }
      final live = [
        for (final s in page.slots)
          if (!s.isDeleted) s
      ];
      compacted += page.slots.length - live.length;
      final compactedPage = NghLeafPage(
        centroidId: page.centroidId,
        nextLeafPage: page.nextLeafPage,
        dimensions: page.dimensions,
        slots: live,
      );
      dirtyLeaves[ptr] = compactedPage;
      _btreeLeafPut(table.tableUid, indexUid, pid, compactedPage);
      if (live.isEmpty) continue;
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
            centroidId: page.centroidId,
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
          locators: updated.length > NghPkLocator.maxLocatorsPerPk
              ? updated.sublist(0, NghPkLocator.maxLocatorsPerPk)
              : updated,
        );
      }
    }

    return NghCompactResult(
      meta: pkBatch.meta,
      dirtyLeafPages: dirtyLeaves,
      dirtyPkmapPages: pkBatch.dirty,
      compactedCount: compacted,
    );
  }

  /// Scan leaf pages to fill the PK locator tree. Tombstones pending-delete
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
    final dirtyLeaves = <NghPagePtr, NghLeafPage>{};
    var part = currentMeta.pkBackfillPartition;
    var page = currentMeta.pkBackfillPage < NghIndexMeta.firstDataPageNo
        ? NghIndexMeta.firstDataPageNo
        : currentMeta.pkBackfillPage;
    var visited = 0;
    var tombstoned = 0;
    final partLimit = max(1, currentMeta.leafPartitionCount);

    while (visited < maxPages && part < partLimit) {
      final pageCount = await _partitionManager.leafFilePageCount(
        table,
        indexUid,
        currentMeta,
        part,
      );
      if (pageCount <= NghIndexMeta.firstDataPageNo) {
        part++;
        page = NghIndexMeta.firstDataPageNo;
        continue;
      }
      while (page < pageCount && visited < maxPages) {
        visited++;
        final pageId = NghPageId(part, page);
        final ptr = NghPagePtr(NghDataCategory.leaf, part, page);
        final loaded = dirtyLeaves[ptr] ??
            _btreeLeafGet(
              table.tableUid,
              indexUid,
              pageId,
              touch: false,
            ) ??
            await _partitionManager.readLeafPage(
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
              loaded.markSlotDeleted(slot);
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
            locators: merged.length > NghPkLocator.maxLocatorsPerPk
                ? merged.sublist(0, NghPkLocator.maxLocatorsPerPk)
                : merged,
          );
        }
        if (modified) {
          dirtyLeaves[NghPagePtr(NghDataCategory.leaf, part, pgNo)] = loaded;
          _btreeLeafPut(
            table.tableUid,
            indexUid,
            NghPageId(part, pgNo),
            loaded,
          );
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

    final navRefresh = await _refreshNavAfterLeafDeletes(
      table: table,
      indexUid: indexUid,
      meta: currentMeta,
      dirtyLeaves: dirtyLeaves,
    );

    return NghInsertResult(
      meta: currentMeta,
      dirtyLeafPages: dirtyLeaves,
      dirtyPkmapPages: pkBatch.dirty,
      dirtyNavBTreePages: navRefresh.dirtyNav,
      dirtyNavRootPage: navRefresh.dirtyRoot,
      insertedCount: 0,
      tombstonedCount: tombstoned,
    );
  }
}

// Result Types
// ============================================================================

/// Result of a batch insertion operation.
class NghInsertResult {
  final NghIndexMeta meta;
  final Map<NghPagePtr, NghLeafPage> dirtyLeafPages;
  final Map<NghPagePtr, NghNavCentroidPage> dirtyNavPages;
  final Map<NghPagePtr, NghPkMapDirtyPage> dirtyPkmapPages;
  final Map<NghPagePtr, NghNavBTreePage> dirtyNavBTreePages;
  final Map<NghPageId, NghNavBTreePage> touchedNavPages;
  final ({NghPagePtr ptr, NghNavRootPage page})? dirtyNavRootPage;
  final bool deleteLegacyNavGraph;
  final int insertedCount;
  final int tombstonedCount;

  /// True when this flush should load *missing* search-hot leaves after persist.
  ///
  /// Not "index fits budget" — that would re-prewarm every small-corpus flush.
  final bool needsCompactGapFill;

  NghInsertResult({
    required this.meta,
    this.dirtyLeafPages = const {},
    this.dirtyNavPages = const {},
    this.dirtyPkmapPages = const {},
    this.dirtyNavBTreePages = const {},
    this.touchedNavPages = const {},
    this.dirtyNavRootPage,
    this.deleteLegacyNavGraph = false,
    required this.insertedCount,
    this.tombstonedCount = 0,
    this.needsCompactGapFill = false,
  });
}

/// Result of a batch deletion operation.
class NghDeleteResult {
  final NghIndexMeta meta;
  final Map<NghPagePtr, NghLeafPage> dirtyLeafPages;
  final Map<NghPagePtr, NghNavCentroidPage> dirtyNavPages;
  final Map<NghPagePtr, NghPkMapDirtyPage> dirtyPkmapPages;
  final Map<NghPagePtr, NghNavBTreePage> dirtyNavBTreePages;
  final ({NghPagePtr ptr, NghNavRootPage page})? dirtyNavRootPage;
  final bool deleteLegacyNavGraph;
  final int deletedCount;
  final List<String> unresolvedPks;

  NghDeleteResult({
    required this.meta,
    this.dirtyLeafPages = const {},
    this.dirtyNavPages = const {},
    this.dirtyPkmapPages = const {},
    this.dirtyNavBTreePages = const {},
    this.dirtyNavRootPage,
    this.deleteLegacyNavGraph = false,
    required this.deletedCount,
    this.unresolvedPks = const [],
  });
}

/// Result of a background tombstone compaction.
class NghCompactResult {
  final NghIndexMeta meta;
  final Map<NghPagePtr, NghLeafPage> dirtyLeafPages;
  final Map<NghPagePtr, NghNavCentroidPage> dirtyNavPages;
  final Map<NghPagePtr, NghPkMapDirtyPage> dirtyPkmapPages;
  final List<NghPagePtr> freeLeafPages;
  final int compactedCount;

  NghCompactResult({
    required this.meta,
    this.dirtyLeafPages = const {},
    this.dirtyNavPages = const {},
    this.dirtyPkmapPages = const {},
    this.freeLeafPages = const [],
    required this.compactedCount,
  });
}

// ============================================================================
// Fixed-Size Binary Heap -- Zero-GC Search Primitive
// ============================================================================

class _FixedHeap {
  final int capacity;
  final bool maxHeap;

  /// Node ids as Dart [int] (not [Int32List]) so wide leaf nodeId (>2^32) survives.
  late final List<int> _ids;
  late final Float64List _dists;
  late final List<Uint8List?> _pks;
  late final List<String?> _pkStrings;
  int _size = 0;

  _FixedHeap(this.capacity, {this.maxHeap = false}) {
    _ids = List<int>.filled(capacity, 0);
    _dists = Float64List(capacity);
    _pks = List<Uint8List?>.filled(capacity, null);
    _pkStrings = List<String?>.filled(capacity, null);
  }

  bool get isEmpty => _size == 0;
  bool get isNotEmpty => _size > 0;
  bool get isFull => _size >= capacity;
  int get length => _size;
  double get peekDist => _size > 0 ? _dists[0] : double.infinity;

  @pragma('vm:prefer-inline')
  void clear() {
    _size = 0;
  }

  void pushWithPk(int id, double dist, Uint8List? pkBytes, [String? pkString]) {
    if (_size < capacity) {
      final i = _size;
      _ids[i] = id;
      _dists[i] = dist;
      _pks[i] = pkBytes;
      _pkStrings[i] = pkString;
      _size = i + 1;
      _siftUp(i);
    } else if ((maxHeap && dist < _dists[0]) ||
        (!maxHeap && dist > _dists[0])) {
      _ids[0] = id;
      _dists[0] = dist;
      _pks[0] = pkBytes;
      _pkStrings[0] = pkString;
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
        _pkStrings[0] = _pkStrings[_size];
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

  /// Drain as [NghSearchResult] (one list; prefer cached String PK over utf8).
  List<NghSearchResult> drainSortedToSearchResults() {
    if (_size == 0) return const [];
    final out = <NghSearchResult>[];
    while (_size > 0) {
      final id = _ids[0];
      final dist = _dists[0];
      final pkStr = _pkStrings[0];
      final pkBytes = _pks[0];
      _size--;
      if (_size > 0) {
        _ids[0] = _ids[_size];
        _dists[0] = _dists[_size];
        _pks[0] = _pks[_size];
        _pkStrings[0] = _pkStrings[_size];
        _siftDown(0);
      }
      out.add(NghSearchResult(
        nodeId: id,
        distance: dist,
        primaryKey: pkStr ?? (pkBytes != null ? utf8.decode(pkBytes) : null),
      ));
    }
    if (maxHeap && out.length > 1) {
      for (var i = 0, j = out.length - 1; i < j; i++, j--) {
        final tmp = out[i];
        out[i] = out[j];
        out[j] = tmp;
      }
    }
    return out;
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
    final tempPkStr = _pkStrings[a];

    _ids[a] = _ids[b];
    _dists[a] = _dists[b];
    _pks[a] = _pks[b];
    _pkStrings[a] = _pkStrings[b];

    _ids[b] = tempId;
    _dists[b] = tempDist;
    _pks[b] = tempPk;
    _pkStrings[b] = tempPkStr;
  }
}
