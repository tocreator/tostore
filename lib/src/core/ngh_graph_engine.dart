import 'dart:collection';
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
//   - nprobe is on L0 count. Each probed coarse expands toward leaves with
//     insert-path child picks (nearest parent first; no cross-parent leaf
//     centroid trim — that cut Recall@10 ~3–20pp at the same list count).
//     Scoring count is wantLeaves (log10(N) + √(nLeaves/256) fine scale),
//     hard-capped for interactive latency (~12 / 20 / 36 at depth 1 / 50 / 100).
//   - searchDepth anchors: 1→91%, 50→95%, 98→98% (±5 / ±3 / ±5 pp). No hard
//     max — depth>100 continues the same average Δlists/Δdepth (and recall
//   - Engine v4 never rewrites nav_graph.ngh. New writes are paged Centroid
//     B+Tree and posting partitions only. Posting slot layout stays frozen.
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

/// In-memory compact cluster slot container with precomputed size and entry count.
final class _NghClusterSlots {
  final List<_NghCompactSlot> slots;
  final int byteSize;
  int entryCount;

  _NghClusterSlots({
    required this.slots,
    required this.byteSize,
    required this.entryCount,
  });

  /// O(1) 3-point sampled estimation of cluster bytes (first, mid, last slots).
  /// Avoids expensive O(N) looping over thousands of slots per cluster.
  static int estimateBytes(List<_NghCompactSlot> slots) {
    final n = slots.length;
    if (n == 0) return 16;
    if (n <= 3) {
      var sum = 16;
      for (final s in slots) {
        sum += 72 + s.primaryKeyBytes.length + s.sq8Codes.length;
      }
      return sum;
    }
    final s0 = slots.first;
    final s1 = slots[n >> 1];
    final s2 = slots.last;
    final dim = s0.sq8Codes.length;
    final avgPkLen = (s0.primaryKeyBytes.length +
            s1.primaryKeyBytes.length +
            s2.primaryKeyBytes.length) ~/
        3;
    final perSlot = 72 + dim + avgPkLen;
    return 16 + n * perSlot;
  }
}

// ----------------------------------------------------------------------------
// Candidate Min-Heap for Zero Heap GC
// ----------------------------------------------------------------------------
final class CandidateMinHeapIP {
  final Int32List ids;
  final Float64List scores;
  int size = 0;
  final int capacity;
  double minScore = -1e9;

  CandidateMinHeapIP(this.capacity)
      : ids = Int32List(capacity + 1),
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
  final List<NghPostingSlot?> slots;
  final Float64List scores;
  int size = 0;
  int capacity;
  final int maxCapacity;
  double minScore = -1e9;

  SlotCandidateHeap(this.maxCapacity)
      : capacity = maxCapacity,
        slots = List<NghPostingSlot?>.filled(maxCapacity + 1, null),
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
  void push(NghPostingSlot slot, double score) {
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

// In-Memory Centroid B+Tree State (Level 0 Root + Level 1 Internal Branch Pages)
//
// Search-hot posting leaves live in [NghGraphEngine._btreeLeafCache] (TreeCache
// + ResourceManager vector budget). This state only holds routing + scratch.
final class CentroidBTreeState {
  final int numRootCentroids;
  final Float32List rootCentroids48Flat;
  final Float32x4List rootCentroids48Simd;
  final Map<int, List<({NghPageId pageId, NghNavBTreePage page})>>
      internalChains;

  /// Dense parallel of [internalChains] — O(1) L0/L1 lookup (no Map hash).
  late final List<List<({NghPageId pageId, NghNavBTreePage page})>?>
      chainsByRoot;

  NghPageId rootPageId;
  int nextCentroidId;

  // Pre-allocated scratchpads for Zero Heap GC search
  final Float32List scratchQLow = Float32List(48);
  late final Float32x4List scratchQLowSimd =
      Float32x4List.sublistView(scratchQLow);
  final Float32List scratchQFull;

  final SlotCandidateHeap slotHeap = SlotCandidateHeap(2048);
  final BranchMinHeap branchHeap = BranchMinHeap(256);
  final CandidateMinHeapIP heap = CandidateMinHeapIP(10);

  final Float64List rootScores = Float64List(256);
  final Int32List rootIndices = Int32List(256);
  final Int32List probedRoots = Int32List(256);
  final List<CentroidBranchEntry?> pickedLeaves =
      List<CentroidBranchEntry?>.filled(1024, null);

  /// Resolved hot posting pages for [pickedLeaves] (avoids TreeCache re-lookup).
  final List<NghPostingPage?> pickedLeafPages =
      List<NghPostingPage?>.filled(1024, null);

  /// Reused Top-K heap (avoids per-query _FixedHeap alloc).
  _FixedHeap? _resultHeap;

  // Fast single-cycle direct indexing visited tag (1M nodes capacity, 4MB pre-allocated)
  final Int32List visitedTag = Int32List(1048576);
  int currentStamp = 0;

  @pragma('vm:prefer-inline')
  void nextQueryStamp() {
    currentStamp++;
    if (currentStamp >= 2147483640) {
      visitedTag.fillRange(0, visitedTag.length, 0);
      currentStamp = 1;
    }
  }

  @pragma('vm:prefer-inline')
  bool isVisited(int nodeId) {
    if (nodeId < visitedTag.length) {
      if (visitedTag[nodeId] == currentStamp) return true;
      visitedTag[nodeId] = currentStamp;
      return false;
    }
    return false;
  }

  /// Write [chain] into both the Map (mutation/compat) and dense [chainsByRoot].
  @pragma('vm:prefer-inline')
  void putRootChain(
    int rootId,
    List<({NghPageId pageId, NghNavBTreePage page})> chain,
  ) {
    internalChains[rootId] = chain;
    if (rootId >= 0 && rootId < chainsByRoot.length) {
      chainsByRoot[rootId] = chain;
    }
  }

  /// Rebuild dense root→chain after bulk Map updates (nav load / rebuild).
  void syncChainsByRoot() {
    for (int i = 0; i < chainsByRoot.length; i++) {
      chainsByRoot[i] = null;
    }
    for (final e in internalChains.entries) {
      final id = e.key;
      if (id >= 0 && id < chainsByRoot.length) {
        chainsByRoot[id] = e.value;
      }
    }
  }

  CentroidBTreeState({
    required this.numRootCentroids,
    required this.rootPageId,
    required int dimensions,
    this.nextCentroidId = 1,
  })  : rootCentroids48Flat = Float32List(numRootCentroids * 48),
        rootCentroids48Simd = Float32x4List(numRootCentroids * 12),
        internalChains = {},
        chainsByRoot =
            List<List<({NghPageId pageId, NghNavBTreePage page})>?>.filled(
          numRootCentroids,
          null,
        ),
        scratchQFull = Float32List(dimensions);
}

/// Resolved probe plan for one ANN query (recall-intent → cost budget).
class _NprobePlan {
  final int depth;
  final double targetRecall;
  final int maxCandidates;
  final int nprobe;
  final int wantLeaves;
  final int nlist;
  final double imbalance;

  const _NprobePlan({
    required this.depth,
    required this.targetRecall,
    required this.maxCandidates,
    required this.nprobe,
    required this.wantLeaves,
    required this.nlist,
    required this.imbalance,
  });
}

/// NGH Graph Engine -- core vector search and dynamic graph engine.
class NghGraphEngine {
  final NghPartitionManager _partitionManager;

  /// Absolute L0 nprobe ceiling (routing only; scoring uses [wantLeaves]).
  static const int _hardNprobeCap = 256;

  /// Typical leaf occupancy used for slot-budget estimates.
  static const int _typicalLeafSlots = 4096;

  /// Interactive scoring cap at depth 100 (keeps p95 interactive on 1M–10M).
  static const int _maxInteractiveLeaves = 44;

  /// Map [searchDepth] → target recall intent.
  ///
  /// Anchors (no hard max):
  /// depth 1 → 91.0% (±5pp)
  /// depth 50 → 95.0% (±3pp strict production baseline)
  /// depth 98 → 98.0% (±5pp)
  /// depth 100 → ~99.0%
  /// depth >100 continues the 50→100 intent slope (~5pp per 50 depth)
  /// until 100%, then stays saturated — probe budget still rises so large
  /// corpora can catch the same knob feel.
  static double targetRecallFromDepth(int searchDepth) {
    if (searchDepth <= 1) return 0.91;
    if (searchDepth <= 50) {
      return 0.91 + (0.95 - 0.91) * ((searchDepth - 1) / 49.0);
    }
    if (searchDepth <= 98) {
      return 0.95 + (0.98 - 0.95) * ((searchDepth - 50) / 48.0);
    }
    if (searchDepth <= 100) {
      // 98 → 98%, 100 → 99%: short tip so depth 100 is distinctly above 98.
      return 0.98 + (0.99 - 0.98) * ((searchDepth - 98) / 2.0);
    }
    // Same increment as 50→100 (~4pp / 50 depth), not the shallower 1→100 mean.
    const ppPerDepth = (0.99 - 0.95) / 50.0;
    return min(1.0, 0.99 + ppPerDepth * (searchDepth - 100));
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

  /// Map recall intent → minimum-cost nprobe / scoring plan.
  ///
  /// [wantLeaves] is the number of posting lists scored (latency). L0 nprobe
  /// stays only slightly above that so expand can follow insert-path children.
  /// When leaves nest under L0 (`nLeaves > nL0`), add a small routing / score
  /// bump — measured 1.7M depth50 sat ~79% at 14 lists; ~18–20 lists close
  /// the remaining gap toward the 95%±3 baseline without the 200ms path.
  _NprobePlan _resolveNprobePlan({
    required int nCentroids,
    required int nLeaves,
    required int nCoarse,
    required int totalVectors,
    required double imbalance,
    int? searchDepth,
  }) {
    final rawDepth = searchDepth ?? VectorIndexConfig.defaultSearchDepth;
    final depth = max(1, rawDepth);
    final targetRecall = targetRecallFromDepth(depth);
    final nlist = max(1, nCentroids);
    var wantLeaves = _wantLeavesForDepth(
      searchDepth: depth,
      nLeaves: max(1, nLeaves),
      totalVectors: totalVectors,
    );
    if (imbalance > 3.0 && depth >= 45) {
      wantLeaves = min(
        max(1, nLeaves),
        wantLeaves + 1,
      );
    }

    if (nlist <= 1 && nLeaves <= 1) {
      return _NprobePlan(
        depth: depth,
        targetRecall: targetRecall,
        maxCandidates: max(1, totalVectors),
        nprobe: 1,
        wantLeaves: 1,
        nlist: nlist,
        imbalance: imbalance,
      );
    }

    // Nesting cliff: postings hide under coarses (typical past ~1M).
    // 1.7M measured: 14 lists ~79%, ~23 lists ~85%; push ~28–30 toward 95%±3.
    final cliff = nLeaves > nlist;
    if (cliff) {
      wantLeaves = min(
        max(1, nLeaves),
        max(
          wantLeaves,
          (wantLeaves * 1.45).round(),
        ),
      );
    }

    final routingExtra = nLeaves < 96
        ? 0
        : (cliff ? (depth < 50 ? 4 : 8) : (depth < 50 ? 1 : 2));
    final nprobe = min(nlist, min(_hardNprobeCap, wantLeaves + routingExtra));

    final avgCluster = nLeaves > 0
        ? max(64, (totalVectors / nLeaves).round())
        : _typicalLeafSlots;
    final slotCap = _slotCapForDepth(
      depth,
      nLeaves: nLeaves,
      totalVectors: totalVectors,
    );
    var maxCandidates = (_typicalLeafSlots * wantLeaves * 1.10).round();
    maxCandidates = min(maxCandidates, slotCap);
    maxCandidates = min(maxCandidates, max(1, totalVectors));
    if (nLeaves > 0) {
      maxCandidates = min(maxCandidates, nLeaves * max(avgCluster, 1));
    }

    return _NprobePlan(
      depth: depth,
      targetRecall: targetRecall,
      maxCandidates: maxCandidates,
      nprobe: nprobe,
      wantLeaves: wantLeaves,
      nlist: nlist,
      imbalance: imbalance,
    );
  }

  /// Interactive scoring cap: depth 1→14, 50→28, 100→44 typical lists.
  /// Depth >100 drops the interactive ceiling — [_wantLeavesForDepth] owns
  /// the rate (same average Δlists/Δdepth as the delivered 1→100 band);
  /// hard stop is leaf inventory.
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
      // Probe budget past 100 is owned by wantLeaves slope; inventory only.
      return nLeaves > 0 ? nLeaves : cap100;
    }
    return nLeaves > 0 ? min(nLeaves, cap) : cap;
  }

  static int _slotCapForDepth(
    int searchDepth, {
    required int nLeaves,
    required int totalVectors,
  }) =>
      (_typicalLeafSlots *
              _maxLeavesForDepth(
                searchDepth,
                nLeaves: nLeaves,
                totalVectors: totalVectors,
              ) *
              1.10)
          .round();

  /// Min-cost posting lists — calibrated routing points (insert-path children):
  ///   50k:  2 lists ~95%; 250k: 2–3 lists; 1M: 4 / 6 / 11 ~87 / 92 / 94%.
  ///   Finer tessellation (nLeaves > 256) multiplies by √(nLeaves/256).
  /// Anchors: depth 1 / 50 / 98 / 100 → n1 / n50 / n98 / n100.
  /// Depth >100 continues the average Δlists/Δdepth of the delivered 1→100
  /// band so each extra depth buys at least as much budget as before.
  static int _wantLeavesForDepth({
    required int searchDepth,
    required int nLeaves,
    required int totalVectors,
  }) {
    final nl = max(1, nLeaves);
    if (nl <= 1) return 1;

    final logN = log(max(1000, totalVectors).toDouble()) / ln10;
    var n1 = min(8, max(2, (2.0 + 8.0 * max(0.0, logN - 5.50)).round()));
    var n50 = min(
      16,
      max(
        n1,
        (2.0 +
                (logN >= 5.38 ? 1.0 : 0.0) +
                (logN >= 5.55 ? 1.0 : 0.0) +
                14.0 * max(0.0, logN - 5.50))
            .round(),
      ),
    );
    // Depth ≤100 is gated by [_maxLeavesForDepth] (interactive). Keep the
    // depth-100 anchor uncapped here so depth>100 can extrapolate on large
    // nested corpora instead of freezing at the interactive leaf count.
    var n100 = max(
      n50 + 4,
      (n50 + 4.0 + 38.0 * max(0.0, logN - 5.50)).round(),
    );

    // 1M @ ~256 lists is the measured 4 / 6 / 11 point. Finer tessellation
    // (past L0 capacity / nesting) multiplies those counts by √(nLeaves/256).
    // 1.7M depth50: aim ~28–30 scored lists after cliff boost (~12ms class).
    const refLeaves = 256.0;
    final fine = sqrt(nl / refLeaves);
    if (fine > 1.05) {
      n1 = max(n1, min(16, (8.0 * fine).round()));
      n50 = max(n50, min(28, (16.0 * fine).round()));
      n100 = max(n100, (22.0 * fine).round());
    }

    final n98 = max(n50 + 1, n50 + ((n100 - n50) * 48 / 50.0).round());
    final cap = _maxLeavesForDepth(
      searchDepth,
      nLeaves: nl,
      totalVectors: totalVectors,
    );

    // Delivered endpoint of the base band (after interactive clamp).
    final at100 = min(nl, min(_maxInteractiveLeaves, max(n1, n100)));

    final double raw;
    if (searchDepth <= 1) {
      raw = n1.toDouble();
    } else if (searchDepth <= 50) {
      // Convex: depth 20 stays near n1 (avoid early overshoot).
      final u = (searchDepth - 1) / 49.0;
      raw = n1 + (n50 - n1) * (u * u);
    } else if (searchDepth <= 98) {
      final v = (searchDepth - 50) / 48.0;
      raw = n50 + (n98 - n50) * v;
    } else if (searchDepth <= 100) {
      final w = (searchDepth - 98) / 2.0;
      raw = n98 + (n100 - n98) * w;
    } else {
      // Same Δlists as 50→100 (~5pp intent / 50 depth), not 1→100 average.
      final at50 = min(
        nl,
        min(
          _maxLeavesForDepth(50, nLeaves: nl, totalVectors: totalVectors),
          max(n1, n50),
        ),
      );
      const floorSlope = (_maxInteractiveLeaves - 28) / 50.0;
      final deliveredSlope = (at100 - at50) / 50.0;
      final slope = at100 < nl
          ? max(deliveredSlope, floorSlope)
          : max(0.0, deliveredSlope);
      raw = at100 + slope * (searchDepth - 100);
    }
    return min(nl, min(cap, max(n1, raw.round())));
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
    minByteThreshold: max(16 * 1024 * 1024, _navGraphCacheMaxBytes ~/ 2),
    debugLabel: 'NghNavGraphCache',
  );

  /// Inflight futures for navigating centroid graph loading.
  final Map<String, Future<NghNavGraphPage?>> _navGraphInflight = {};

  /// Soft ceiling for cluster compact cache; enforced after load/prewarm.
  int _clusterCacheMaxBytes = 32 * 1024 * 1024;

  /// Per-centroid compact SQ8 cache. Key: `[tableUid.value, indexUid.value, centroidId]`.
  late final TreeCache<_NghClusterSlots> _clusterCache =
      TreeCache<_NghClusterSlots>(
    groupDepth: 2,
    sizeCalculator: (cluster) => cluster.byteSize,
    evictionMode: TreeCacheEvictionMode.lru,
    maxByteThreshold: _clusterCacheMaxBytes,
    minByteThreshold: max(4 * 1024 * 1024, _clusterCacheMaxBytes ~/ 2),
    debugLabel: 'NghClusterCache',
  );

  /// Soft ceiling for Centroid B+Tree search-hot posting leaves.
  /// Synced from ResourceManager via [configureBTreeLeafCacheBudget].
  int _btreeLeafCacheMaxBytes = 32 * 1024 * 1024;

  /// Paged ANN leaf working set. Key: `[tableUid, indexUid, partitionNo, pageNo]`.
  ///
  /// Budgeted by the same vector quota as the legacy compact cluster cache so
  /// insert thrash cannot silently shrink the hot set below startup prewarm.
  late final TreeCache<NghPostingPage> _btreeLeafCache =
      TreeCache<NghPostingPage>(
    groupDepth: 2,
    sizeCalculator: (page) => page.estimateResidentBytes(),
    evictionMode: TreeCacheEvictionMode.lru,
    maxByteThreshold: _btreeLeafCacheMaxBytes,
    minByteThreshold: max(16 * 1024 * 1024, _btreeLeafCacheMaxBytes ~/ 2),
    debugLabel: 'NghBTreeLeafCache',
  );

  final Map<String, Future<void>> _clusterLoadInflight = {};

  late final NghPkMapEngine _pkMap =
      NghPkMapEngine(_partitionManager, _partitionManager.engineConfig);

  /// Centroid B+Tree in-memory states (L0 root centroids + L1 internal branch pages).
  /// Key: `tableUid.value:indexUid.value`.
  final Map<String, CentroidBTreeState> _btreeStates = {};

  NghGraphEngine(this._partitionManager);

  /// Format / page-directory cap for top-level centroid ids.
  static const int _maxTargetK = 16384;

  /// L0 routing lists (roots: coarses ∪ orphan leaves). Exact-scanned on insert.
  /// Nested coarses are children, not L0 — otherwise K grows past 256 and
  /// 10k-flush assignment returns to minutes at 10M+.
  static const int _maxTopLevelRouting = 256;

  /// Coarse→mid→leaf hops. 256^3 × ~4k ≈ 68B; deeper would need childrenDir.
  static const int _maxTreeDepth = 2;

  /// Hard cap on live vectors in one leaf. Fair-share softCap must not exceed
  /// this or 10B corpora collapse into ~610k-slot lists (search I/O avalanche).
  static int _leafEntryCap(int slotsPerPage) =>
      max(4096, 64 * max(1, slotsPerPage));

  int _postingPageSize(NghIndexMeta meta) =>
      _partitionManager.pageSizeFor(NghDataCategory.posting, meta);

  int _navPageSize(NghIndexMeta meta) =>
      _partitionManager.pageSizeFor(NghDataCategory.nav, meta);

  /// Current estimated nav-graph cache footprint in bytes.
  int get navGraphCacheBytes => _navGraphCache.estimatedTotalSizeBytes;

  TreeCache<NghNavGraphPage> get navGraphCache => _navGraphCache;

  /// Current nav-graph cache ceiling in bytes.
  int get navGraphCacheMaxBytes => _navGraphCacheMaxBytes;

  /// Configure nav-graph cache ceiling (adaptive based on memory budget).
  void configureNavGraphCacheBudget(int maxBytes) {
    _navGraphCacheMaxBytes = max(64 * 1024 * 1024, maxBytes);
    _navGraphCache.updateByteThreshold(
      max: _navGraphCacheMaxBytes,
      min: max(32 * 1024 * 1024, _navGraphCacheMaxBytes ~/ 2),
    );
  }

  /// Current estimated cluster-cache footprint in bytes.
  int get clusterCacheBytes => _clusterCache.estimatedTotalSizeBytes;

  /// Current compact-cache ceiling in bytes.
  int get clusterCacheMaxBytes => _clusterCacheMaxBytes;

  /// Resident Centroid B+Tree posting-leaf cache bytes (all indexes).
  int get btreeLeafCacheBytes => _btreeLeafCache.estimatedTotalSizeBytes;

  /// Current B+Tree leaf-cache ceiling in bytes.
  int get btreeLeafCacheMaxBytes => _btreeLeafCacheMaxBytes;

  /// Configure cluster-cache ceiling (vector quota from ResourceManager).
  void configureClusterCacheBudget(int maxBytes) {
    _clusterCacheMaxBytes = max(64 * 1024 * 1024, maxBytes);
    _clusterCache.updateByteThreshold(
      max: _clusterCacheMaxBytes,
      min: max(32 * 1024 * 1024, _clusterCacheMaxBytes ~/ 2),
    );
  }

  /// Configure paged ANN leaf-cache ceiling (same vector quota family).
  void configureBTreeLeafCacheBudget(int maxBytes) {
    _btreeLeafCacheMaxBytes = max(64 * 1024 * 1024, maxBytes);
    _btreeLeafCache.updateByteThreshold(
      max: _btreeLeafCacheMaxBytes,
      min: max(32 * 1024 * 1024, _btreeLeafCacheMaxBytes ~/ 2),
    );
  }

  NghPostingPage? _btreeLeafGet(
    TableUid tableUid,
    IndexUid indexUid,
    NghPageId id, {
    bool touch = true,
  }) {
    if (id.isNone) return null;
    return _btreeLeafCache.getPoint4(
      tableUid.value,
      indexUid.value,
      id.partitionNo,
      id.pageNo,
      touch: touch,
    );
  }

  void _btreeLeafPut(
    TableUid tableUid,
    IndexUid indexUid,
    NghPageId id,
    NghPostingPage page,
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
  }

  void _btreeLeafClearForIndex(TableUid tableUid, IndexUid indexUid) {
    _btreeLeafCache.remove([tableUid.value, indexUid.value]);
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
  bool _refreshCompactCacheAfterInsert({
    required TableUid tableUid,
    required IndexUid indexUid,
    required List<NghNavCentroidNode> centroids,
    required Map<int, List<NghPostingSlot>> clusterSlots,
    required Set<int> rewrittenIds,
    required Set<int> newCentroidIds,
    required int dimensions,
  }) {
    var hasIncompleteOrMissing = false;

    for (final cId in clusterSlots.keys) {
      if (rewrittenIds.contains(cId)) {
        continue;
      }
      if (cId < 0 || cId >= centroids.length) {
        _removeCentroidSlots(tableUid, indexUid, cId);
        continue;
      }
      final newSlots = clusterSlots[cId]!;
      final centroid = centroids[cId];
      final packedRef =
          centroid.tailPostingPageNo > 0 ? centroid.tailPostingPageNo : 1;
      final cached = _clusterCache.getPoint3(
        tableUid.value,
        indexUid.value,
        cId,
        touch: false,
      );
      final liveCached = cached == null ? 0 : cached.entryCount;
      final newCount = newSlots.length;

      if (newCentroidIds.contains(cId) || centroid.entryCount == newCount) {
        _putCentroidSlots(
          tableUid: tableUid,
          indexUid: indexUid,
          centroidId: cId,
          slots: _compactNewSlots(newSlots, packedRef),
          entryCount: centroid.entryCount,
        );
        continue;
      }

      if (cached != null &&
          newCount > 0 &&
          liveCached + newCount >= centroid.entryCount) {
        final compactNew = _compactNewSlots(newSlots, packedRef);
        List<_NghCompactSlot> targetSlots;
        try {
          cached.slots.addAll(compactNew);
          targetSlots = cached.slots;
        } catch (_) {
          targetSlots = List<_NghCompactSlot>.of(cached.slots)
            ..addAll(compactNew);
        }
        _putCentroidSlots(
          tableUid: tableUid,
          indexUid: indexUid,
          centroidId: cId,
          slots: targetSlots,
          entryCount: centroid.entryCount,
        );
        continue;
      }

      // Incomplete or not cached: drop partial/stale slots and flag for gap-fill.
      _removeCentroidSlots(tableUid, indexUid, cId);
      hasIncompleteOrMissing = true;
    }

    // Allow gap-fill whenever cluster cache budget has remaining space.
    // Do NOT gate on [fits] (which falsely refused gap-fill once corpus exceeds ~60k).
    final hasBudget =
        _clusterCache.estimatedTotalSizeBytes < _clusterCacheMaxBytes;
    if (!hasBudget) return false;
    return hasIncompleteOrMissing;
  }

  String _cacheKey(TableUid tableUid, IndexUid indexUid) =>
      '${tableUid.value}/${indexUid.value}';

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

  /// O(1) cache freshness check comparing live entry counts.
  ///
  /// [slots.length] must cover [entryCount] (tombstones may make it larger).
  /// A short list with a matching entryCount is an incomplete load that would
  /// otherwise stay "fresh" and skip posting I/O forever.
  bool _clusterCacheIsFresh(
    _NghClusterSlots cached,
    NghNavCentroidNode centroid,
  ) {
    if (centroid.entryCount <= 0) return true;
    return cached.entryCount == centroid.entryCount &&
        cached.slots.length >= centroid.entryCount;
  }

  void _putCentroidSlots({
    required TableUid tableUid,
    required IndexUid indexUid,
    required int centroidId,
    required List<_NghCompactSlot> slots,
    int? entryCount,
  }) {
    final bytes = _NghClusterSlots.estimateBytes(slots);
    final cluster = _NghClusterSlots(
      slots: slots,
      byteSize: bytes,
      entryCount: entryCount ?? slots.length,
    );
    _clusterCache.putPoint3(
      tableUid.value,
      indexUid.value,
      centroidId,
      cluster,
      size: bytes,
    );
  }

  void _removeCentroidSlots(
    TableUid tableUid,
    IndexUid indexUid,
    int centroidId,
  ) {
    _clusterCache.removePoint3(tableUid.value, indexUid.value, centroidId);
  }

  /// Evict a ratio of cluster compact caches (oldest centroids first via TreeCache).
  Future<void> evictClusterCache({double ratio = 0.3}) async {
    await _clusterCache.cleanup(removeRatio: ratio);
  }

  /// Evict a ratio of paged ANN leaf caches.
  Future<void> evictBTreeLeafCache({double ratio = 0.3}) async {
    await _btreeLeafCache.cleanup(removeRatio: ratio);
  }

  /// Clear cluster cache for a specific table.
  void clearCacheForTable(TableUid tableUid) {
    _clusterCache.remove([tableUid.value]);
    _navGraphCache.remove([tableUid.value]);
    _btreeLeafCache.remove([tableUid.value]);
    final prefix = '${tableUid.value}/';
    _navGraphInflight.removeWhere((k, _) => k.startsWith(prefix));
    _clusterLoadInflight.removeWhere((k, _) => k.startsWith(prefix));
    _btreeStates.removeWhere((k, _) => k.startsWith(prefix));
  }

  /// Clear cluster cache for a specific index.
  void clearCacheForIndex(TableUid tableUid, IndexUid indexUid) {
    _clusterCache.remove([tableUid.value, indexUid.value]);
    _navGraphCache.remove([tableUid.value, indexUid.value]);
    _btreeLeafClearForIndex(tableUid, indexUid);
    final key = _cacheKey(tableUid, indexUid);
    _navGraphInflight.remove(key);
    _clusterLoadInflight.remove(key);
    _btreeStates.remove(key);
  }

  /// Clear all cluster caches.
  void clearCache() {
    _clusterCache.clear();
    _navGraphCache.clear();
    _btreeLeafCache.clear();
    _navGraphInflight.clear();
    _clusterLoadInflight.clear();
    _btreeStates.clear();
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
    final pageOwnerByCacheKey = <int, int>{};
    final packedOwner = <int, int>{};

    for (final cId in probeCentroids) {
      if (cId < 0 || cId >= navGraph.centroids.length) continue;
      final cached = _clusterCache.getPoint3(
        table.tableUid.value,
        indexUid.value,
        cId,
        touch: true,
      );
      if (cached != null &&
          _clusterCacheIsFresh(cached, navGraph.centroids[cId])) {
        clusterMap[cId] = cached.slots;
        continue;
      }
      if (cached != null) {
        _removeCentroidSlots(table.tableUid, indexUid, cId);
      }
      if (clusterMap.containsKey(cId)) continue;
      expected.add(cId);
    }

    for (final cId in expected) {
      final c = navGraph.centroids[cId];
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
        _putCentroidSlots(
          tableUid: table.tableUid,
          indexUid: indexUid,
          centroidId: cId,
          slots: slots,
          entryCount: navGraph.centroids[cId].entryCount,
        );
      }
    }

    final inflightKey = '$cacheKey/load/${probeCentroids.join(',')}';
    final existing = _clusterLoadInflight[inflightKey];
    if (existing != null) {
      await existing;
      for (final cId in probeCentroids) {
        final cached = _clusterCache.getPoint3(
          table.tableUid.value,
          indexUid.value,
          cId,
          touch: true,
        );
        if (cached != null) clusterMap[cId] = cached.slots;
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

    // Paged Centroid B+Tree search uses leafCache, not the legacy compact
    // cluster cache. Warm posting leaves + low48 so the first query is hot.
    if (meta.layoutVersion >= NghIndexMeta.layoutPaged) {
      return _prewarmBTreeLeaves(
        table: table,
        indexUid: indexUid,
        meta: meta,
        maxBytes: maxBytes,
        shouldAbort: shouldAbort,
      );
    }

    final beforeBytes = clusterCacheBytes;
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

    for (var batchStart = 0;
        batchStart < order.length && !budgetExhausted;
        batchStart += clustersPerBatch) {
      if (aborted()) break;
      if (clusterCacheBytes - beforeBytes >= maxBytes) break;

      final pageIds = <NghPageId>[];
      final chainHeads = <int>[];
      final expected = <int>{};
      final batchMap = <int, List<_NghCompactSlot>>{};
      final pageOwnerByCacheKey = <int, int>{};
      final packedOwner = <int, int>{};
      final batchEnd = min(batchStart + clustersPerBatch, order.length);

      for (var i = batchStart; i < batchEnd; i++) {
        final cId = order[i];
        if (_clusterCache.containsPoint3(
            table.tableUid.value, indexUid.value, cId)) {
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
      }

      for (final cId in expected) {
        final c = centroids[cId];
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
          _putCentroidSlots(
            tableUid: table.tableUid,
            indexUid: indexUid,
            centroidId: cId,
            slots: const [],
            entryCount: 0,
          );
        }
      }

      for (var i = 0; i < pageIds.length; i += pageChunkSize) {
        if (aborted() || clusterCacheBytes - beforeBytes >= maxBytes) {
          budgetExhausted = clusterCacheBytes - beforeBytes >= maxBytes;
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

      if (chainHeads.isNotEmpty && clusterCacheBytes - beforeBytes < maxBytes) {
        for (final head in chainHeads) {
          if (aborted() || clusterCacheBytes - beforeBytes >= maxBytes) {
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
        _putCentroidSlots(
          tableUid: table.tableUid,
          indexUid: indexUid,
          centroidId: cId,
          slots: slots,
          entryCount: centroids[cId].entryCount,
        );
      }

      final y = yieldController.maybeYield();
      if (y != null) await y;
    }

    // Partial warm on abort is fine; still cap for coherent resident state.
    if (_clusterCache.estimatedTotalSizeBytes > _clusterCacheMaxBytes) {
      await _clusterCache.cleanup(removeRatio: 0.15);
    }
    return max(0, clusterCacheBytes - beforeBytes);
  }

  /// Incrementally promote flush-dirty posting leaves into the search-hot cache.
  ///
  /// True incremental (per flush, not per corpus):
  /// - Only [dirtyPostingPages] are reshaped and upserted into [_btreeLeafCache].
  /// - Untouched leaves and live Centroid B+Tree state are kept as-is.
  /// - Matching posting I/O-fill entries for those dirty pages are dropped
  ///   (point removes) — no index-wide cache clear / disk rebuild.
  /// Synchronous leaf-cache promote for memory mode (no disk, no JIT warmup).
  void promotePagedLeavesAfterInsertSync({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required Map<NghPagePtr, NghPostingPage> dirtyPostingPages,
  }) {
    if (meta.layoutVersion < NghIndexMeta.layoutPaged) return;
    if (_btreeStates[_cacheKey(table.tableUid, indexUid)] == null) return;
    if (dirtyPostingPages.isEmpty) return;

    final tableUid = table.tableUid;
    for (final e in dirtyPostingPages.entries) {
      final ptr = e.key;
      if (ptr.category != NghDataCategory.posting) continue;
      if (ptr.isNull || ptr.pageNo <= 0) continue;

      final shaped =
          NghPostingPage.tryDecodePayload(e.value.encodePayload()) ?? e.value;
      final pageId = NghPageId(ptr.partitionNo, ptr.pageNo);
      _btreeLeafPut(tableUid, indexUid, pageId, shaped);
      _partitionManager.evictPostingPage(
        tableUid,
        indexUid,
        ptr.partitionNo,
        ptr.pageNo,
      );
    }
  }

  Future<void> promotePagedLeavesAfterInsert({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required Map<NghPagePtr, NghPostingPage> dirtyPostingPages,
    bool Function()? shouldAbort,
  }) async {
    if (meta.layoutVersion < NghIndexMeta.layoutPaged) return;
    if (_btreeStates[_cacheKey(table.tableUid, indexUid)] == null) return;
    if (dirtyPostingPages.isEmpty) return;

    final beforeLeafBytes = _btreeLeafCache.estimatedTotalSizeBytes;
    final tableUid = table.tableUid;
    for (final e in dirtyPostingPages.entries) {
      if (shouldAbort?.call() ?? false) return;
      final ptr = e.key;
      if (ptr.category != NghDataCategory.posting) continue;
      if (ptr.isNull || ptr.pageNo <= 0) continue;

      // In-memory wire reshape → search-fast slot/PK/low48 (same as prewarm).
      final shaped =
          NghPostingPage.tryDecodePayload(e.value.encodePayload()) ?? e.value;
      final pageId = NghPageId(ptr.partitionNo, ptr.pageNo);
      _btreeLeafPut(tableUid, indexUid, pageId, shaped);
      // Drop duplicate residency in posting I/O fill for this page only.
      _partitionManager.evictPostingPage(
        tableUid,
        indexUid,
        ptr.partitionNo,
        ptr.pageNo,
      );
    }

    if (_btreeLeafCache.estimatedTotalSizeBytes > _btreeLeafCacheMaxBytes) {
      await _btreeLeafCache.cleanup(removeRatio: 0.15);
    }

    // JIT warm only when this flush created the first resident leaves.
    if (beforeLeafBytes <= 0 && !(shouldAbort?.call() ?? false)) {
      await warmSearchPath(table: table, indexUid: indexUid, meta: meta);
    }
  }

  /// Diagnostic: how many posting leaves are inventored vs resident in leaf cache.
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
    for (final chain in state.internalChains.values) {
      for (final it in chain) {
        for (final e in it.page.entries) {
          final id = e.leafPageId;
          if (id.isNone || !seen.add(id.cacheKey)) continue;
          inventored++;
          if (_btreeLeafGet(tableUid, indexUid, id, touch: false) != null) {
            cached++;
          }
        }
      }
    }
    return (
      inventored: inventored,
      cached: cached,
      leafCacheBytes: _btreeLeafCache.estimatedTotalSizeBytes,
      leafCacheMaxBytes: _btreeLeafCacheMaxBytes,
    );
  }

  /// Prefetch posting leaves into [_btreeLeafCache] under [maxBytes].
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

    final beforeBytes = _btreeLeafCache.estimatedTotalSizeBytes;
    final candidates = <({NghPageId id, int slots})>[];
    final seen = <int>{};
    for (final chain in state.internalChains.values) {
      for (final it in chain) {
        for (final e in it.page.entries) {
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
      }
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

  /// Batch-load missing posting leaves into [_btreeLeafCache] and materialize low48.
  /// Hot path returns a completed future without scheduling when all pages are resident.
  Future<void> _hydrateBTreeLeaves({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required Iterable<NghPageId> leafIds,
    Map<NghPageId, NghPostingPage>? insertScratch,
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
    Map<NghPageId, NghPostingPage>? insertScratch,
  }) async {
    // Keep search-hot leaves in [_btreeLeafCache] only — do not also park them
    // in the posting I/O fill cache (double residency → GC / quota thrash).
    final loaded = await _partitionManager.readPostingPagesByIds(
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

  /// Compile hot ANN loops and populate routing/cluster caches after prewarm.
  Future<void> warmSearchPath({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
  }) async {
    if (meta.totalVectors <= 0 || meta.dimensions <= 0) return;
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
  // Search -- centroid-routed filter + candidate ranking
  // =====================================================================

  /// Top-level centroid routing nodes: coarses plus orphan (unsplit) leaves.
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

  /// Exact partial selection among [routing] (same recall as a full sort).
  List<int> _selectExactNearestIds({
    required Float32List vec,
    required List<NghNavCentroidNode> centroids,
    required List<int> routing,
    required VectorDistanceMetric metric,
    required int nprobe,
    Float32x4List? vecSimd,
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

    final canFastSimd = vecSimd != null &&
        (metric == VectorDistanceMetric.cosine ||
            metric == VectorDistanceMetric.innerProduct);
    final n4 = vecSimd?.length ?? 0;

    for (final i in routing) {
      if (i < 0 || i >= centroids.length) continue;
      final cNode = centroids[i];
      final double d;
      final cSimd = canFastSimd ? cNode.getSimdVector() : null;
      if (cSimd != null && cSimd.length == n4) {
        final ip = ScalarQuantizer.dotProductF32Simd(vecSimd!, cSimd, n4);
        d = metric == VectorDistanceMetric.cosine
            ? 1.0 - ip.clamp(-1.0, 1.0)
            : -ip;
      } else {
        d = _exactDistance(vec, cNode.vector, metric);
      }
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
    Float32x4List? querySimd,
  }) {
    final routing = routingIds ?? _topLevelRoutingIds(navGraph.centroids);
    return _selectExactNearestIds(
      vec: searchQuery,
      centroids: navGraph.centroids,
      routing: routing,
      metric: metric,
      nprobe: nprobe,
      vecSimd: querySimd,
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

    final countCap = min(probes.length, max(1, targetProbes));
    // Nearest-first count cap. Small clusters used to pass the slot check
    // and score the whole routing pool (50k/250k stuck at 100% / 98.8%).
    final limited =
        countCap < probes.length ? probes.sublist(0, countCap) : probes;

    var total = 0;
    for (final id in limited) {
      total += entryOf(id);
    }
    if (total <= maxCandidates) return limited;

    final alwaysKeep = min(limited.length, max(1, minKeep));
    final giantThresh = max(avgCluster * 2.2, maxCandidates ~/ 14);
    final target = min(limited.length, max(alwaysKeep, targetProbes));

    final out = <int>[];
    final seen = <int>{};
    var acc = 0;

    void tryAdd(int id) {
      if (!seen.add(id)) return;
      out.add(id);
      acc += entryOf(id);
    }

    // Pass 1: Core nearest preservation.
    // Unconditionally keep the top nearest clusters (up to alwaysKeep).
    // The closest centroids are geometrically guaranteed to contain true nearest
    // neighbors; dropping them because of cluster size severely degrades recall.
    for (var i = 0; i < alwaysKeep && i < limited.length; i++) {
      tryAdd(limited[i]);
    }

    // Pass 2: Marginal non-giant clusters, nearest-first (diversity under budget).
    for (var i = alwaysKeep; i < limited.length; i++) {
      if (out.length >= target && acc >= maxCandidates) break;
      final id = limited[i];
      if (seen.contains(id)) continue;
      final e = entryOf(id);
      if (e > giantThresh && acc + e > maxCandidates) continue;
      if (acc + e > maxCandidates && out.length >= target) continue;
      tryAdd(id);
    }

    // Pass 3: Remaining marginal clusters that still fit — prefer smaller first.
    if (acc < maxCandidates && out.length < target) {
      final rest = <(int, int)>[];
      for (var i = alwaysKeep; i < limited.length; i++) {
        final id = limited[i];
        if (seen.contains(id)) continue;
        rest.add((id, entryOf(id)));
      }
      rest.sort((a, b) {
        final bySize = a.$2.compareTo(b.$2);
        if (bySize != 0) return bySize;
        return 0;
      });
      for (final (id, e) in rest) {
        if (acc + e > maxCandidates && out.length >= target) continue;
        tryAdd(id);
        if (out.length >= target || acc >= maxCandidates) break;
      }
    }

    // Preserve original nearest-first order for scoring locality.
    final order = <int, int>{
      for (var i = 0; i < limited.length; i++) limited[i]: i,
    };
    out.sort((a, b) => (order[a] ?? 0).compareTo(order[b] ?? 0));
    return out.isEmpty ? limited.sublist(0, 1) : out;
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
        (softCandidateBudget * (1.20 + 0.20 * depthT.clamp(0.0, 1.0))).round();

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

  /// Replace coarse probes with an exact child-nprobe (multi-level hierarchical routing).
  ///
  /// One hop is not enough once hubs nest (parent-full → mid-coarse). Recurse
  /// to leaves; each hop keeps the nearest child so identity routing matches
  /// insert. Expanding *all* children of nprobe coarses would still avalanche.
  ///
  /// Do **not** globally re-rank children across parents. A leaf of parent 2
  /// can sit closer to the query than the home leaf of parent 1; insert still
  /// wrote the vector under parent 1. Cross-parent trim dropped 1M self_rc
  /// and Recall@10 several points at the same list count — and was the gap
  /// vs the ~95%@11ms 1.7M sweep.
  List<int> _expandCoarseChildren({
    required List<int> probes,
    required NghNavGraphPage navGraph,
    required Float32List query,
    required VectorDistanceMetric metric,
    required int wantLeaves,
    Float32x4List? querySimd,
  }) {
    final n = navGraph.centroids.length;
    var current = probes;
    for (var hop = 0; hop < _maxTreeDepth + 1; hop++) {
      var sawCoarse = false;
      final out = <int>[];
      final seen = <int>{};
      var firstCoarse = true;
      var coarseRank = 0;
      var leafBudget = max(1, wantLeaves);
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
          final take = _leafNprobeForChildren(
            children.length,
            wantLeaves: wantLeaves,
            nearestParent: firstCoarse,
            parentRank: coarseRank++,
          );
          firstCoarse = false;
          if (take <= 0 || leafBudget <= 0) continue;
          final picked = _selectExactNearestIds(
            vec: query,
            centroids: navGraph.centroids,
            routing: children,
            metric: metric,
            nprobe: min(take, leafBudget),
            vecSimd: querySimd,
          );
          for (final ch in picked) {
            if (seen.add(ch)) {
              out.add(ch);
              leafBudget--;
            }
          }
        } else if (seen.add(id)) {
          out.add(id);
          leafBudget--;
        }
      }
      if (!sawCoarse) return out.isNotEmpty ? out : current;
      current = out;
      if (current.isEmpty) break;
    }
    return current;
  }

  /// How many children to take under one coarse (insert-path, nearest parent first).
  int _leafNprobeForChildren(
    int childCount, {
    required int wantLeaves,
    required bool nearestParent,
    int parentRank = 0,
  }) {
    if (childCount <= 1) return max(0, childCount);
    if (nearestParent) {
      return min(childCount, min(12, max(4, (wantLeaves * 2 + 1) ~/ 3)));
    }
    if (wantLeaves >= 28 && parentRank < 8) {
      return min(childCount, 4);
    }
    if (wantLeaves >= 20 && parentRank < 8) {
      return min(childCount, 3);
    }
    if (wantLeaves >= 14 && parentRank < 8) {
      return min(childCount, 3);
    }
    if (wantLeaves >= 10 && parentRank < 10) {
      return min(childCount, 2);
    }
    if (wantLeaves >= 18 && parentRank < 14) {
      return min(childCount, 2);
    }
    return min(childCount, 1);
  }

  // ============================================================================
  // Centroid B+Tree (Zero-LSM Hierarchical Navigation Engine)
  // ============================================================================

  static Float32List _extractLow48(Float32List full) {
    final low = Float32List(48);
    _extractLow48Into(full, low);
    return low;
  }

  /// Write normalized low-48 into [out] (no allocation — search hot path).
  @pragma('vm:prefer-inline')
  static void _extractLow48Into(Float32List full, Float32List out) {
    final limit = min(48, full.length);
    if (limit == 48 &&
        (full.offsetInBytes & 15) == 0 &&
        (out.offsetInBytes & 15) == 0) {
      final src = Float32x4List.view(full.buffer, full.offsetInBytes, 12);
      final dst = Float32x4List.view(out.buffer, out.offsetInBytes, 12);
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
    for (int d = 0; d < limit; d++) {
      out[d] = full[d];
      norm += full[d] * full[d];
    }
    for (int d = limit; d < 48; d++) {
      out[d] = 0.0;
    }
    norm = sqrt(norm);
    if (norm > 0) {
      final inv = 1.0 / norm;
      for (int d = 0; d < limit; d++) {
        out[d] *= inv;
      }
    }
  }

  static Float32List _computeMean48(List<NghPostingSlot> slots) {
    final mean = Float32List(48);
    final count = slots.length;
    if (count == 0) return mean;
    for (final s in slots) {
      final low = s.getLow48D(48);
      for (int d = 0; d < 48; d++) {
        mean[d] += low[d];
      }
    }
    double norm = 0.0;
    for (int d = 0; d < 48; d++) {
      mean[d] /= count;
      norm += mean[d] * mean[d];
    }
    norm = sqrt(norm);
    if (norm > 0) {
      for (int d = 0; d < 48; d++) {
        mean[d] /= norm;
      }
    }
    return mean;
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

    final state = CentroidBTreeState(
      numRootCentroids: rootPage.roots.length,
      rootPageId: const NghPageId(0, 1),
      dimensions: meta.dimensions,
    );

    int maxCentroidId = rootPage.roots.length;
    for (int i = 0; i < rootPage.roots.length; i++) {
      final r = rootPage.roots[i];
      final c = r.centroid48D;
      for (int d = 0; d < 48; d++) {
        state.rootCentroids48Flat[i * 48 + d] = c[d];
      }
      var currPageId = r.firstInternalPage;
      final chain = <({NghPageId pageId, NghNavBTreePage page})>[];
      while (currPageId != NghPageId.none) {
        final internalPage = await _partitionManager.readNavBTreePage(
          table,
          indexUid,
          currPageId,
          meta: meta,
        );
        if (internalPage == null) break;
        for (final entry in internalPage.entries) {
          if (entry.centroidId > maxCentroidId) {
            maxCentroidId = entry.centroidId;
          }
        }
        chain.add((pageId: currPageId, page: internalPage));
        currPageId = internalPage.nextInternalPage;
      }
      if (chain.isEmpty) {
        chain.add((
          pageId: r.firstInternalPage,
          page: NghNavBTreePage(
            rootCentroidId: r.rootId,
            entries: [],
          ),
        ));
      }
      state.putRootChain(r.rootId, chain);
    }
    state.nextCentroidId = maxCentroidId;

    final view = Float32x4List.sublistView(state.rootCentroids48Flat);
    for (int i = 0; i < state.rootCentroids48Simd.length; i++) {
      state.rootCentroids48Simd[i] = view[i];
    }

    _btreeStates[key] = state;
    return state;
  }

  /// Map [searchDepth], corpus size and [topK] to Centroid B+Tree probe plan.
  ///
  /// LOCKED contract (user tuning must stay valid across engine releases):
  /// - No hard max on [searchDepth]. Depth is recall-intent, not absolute cost.
  /// - Anchors: 1→~91%, 50→~95%, 98→~98%, 100→~99% (best-effort).
  /// - depth>100 uses the 50→100 Δbudget (not the shallower 1→100 mean).
  static ({int wantRoots, int wantLeaves, int candSlots})
      _resolveCentroidBTreeProbePlan({
    required int totalVectors,
    required int topK,
    required int dimensions,
    int postingPageSize = 16384,
    int? searchDepth,
  }) {
    final rawDepth = searchDepth ?? VectorIndexConfig.defaultSearchDepth;
    final depth = max(1, rawDepth);

    // Auto N-scale (holds recall intent; does not change depth→slope).
    final logN = log(max(1000, totalVectors).toDouble()) / ln10;
    final scaleLeaves = max(0.0, (logN - 5.0) * 3.0).round();
    final scaleRoots = max(0.0, (logN - 6.0) * 2.0).round();
    final scaleSlots = max(0.0, (logN - 5.0) * 10.0).round();

    const leaf1 = 7.0;
    const leaf50 = 12.0;
    const leaf100 = 20.0;
    const root50 = 6.0;
    const root100 = 10.0;
    const tipLeaves100 = 8; // applied at depth ≥100
    const tipRoots100 = 4;
    const tipSlots100 = 16;
    // 50→100 *delivered* slope (includes depth-100 tip). +50 depth after
    // 100 must buy the same extra probes as 50→100, or 150/600 feel flat.
    const leafSlope50 = (leaf100 + tipLeaves100 - leaf50) / 50.0; // 0.32
    const rootSlope50 = (root100 + tipRoots100 - root50) / 50.0; // 0.16
    const slotSlope50 = (68.0 + tipSlots100 - 36.0) / 50.0; // 0.96

    // 1. Leaf pages probed (cheap 48-D page scan)
    final int baseLeaves;
    if (depth <= 1) {
      baseLeaves = leaf1.round();
    } else if (depth <= 50) {
      baseLeaves = (leaf1 + (leaf50 - leaf1) * ((depth - 1) / 49.0)).round();
    } else if (depth <= 100) {
      baseLeaves =
          (leaf50 + (leaf100 - leaf50) * ((depth - 50) / 50.0)).round();
    } else {
      baseLeaves = (leaf100 + leafSlope50 * (depth - 100)).round();
    }
    var leaves = max(1, baseLeaves + scaleLeaves);

    // 2. Root centroids probed (cheap 48-D; inventory-capped at search time)
    final int baseRoots;
    if (depth <= 30) {
      baseRoots = 4;
    } else if (depth <= 70) {
      baseRoots = 6;
    } else if (depth <= 100) {
      baseRoots = (8.0 + 2.0 * ((depth - 70) / 30.0)).round();
    } else {
      baseRoots = (root100 + rootSlope50 * (depth - 100)).round();
    }
    var roots = max(1, baseRoots + scaleRoots);

    // 3. SQ8 candidate slots (full-D — keep tight; dominates 768D+ latency)
    final s1 = max(topK * 2, 20);
    final s50 = max(topK * 3 + 6, 36);
    final s100 = max(topK * 6 + 4, 68);
    final int baseCandSlots;
    if (depth <= 1) {
      baseCandSlots = s1;
    } else if (depth <= 50) {
      baseCandSlots = (s1 + (s50 - s1) * ((depth - 1) / 49.0)).round();
    } else if (depth <= 100) {
      baseCandSlots = (s50 + (s100 - s50) * ((depth - 50) / 50.0)).round();
    } else {
      baseCandSlots = (s100 + slotSlope50 * (depth - 100)).round();
    }
    var slots = max(topK, baseCandSlots + scaleSlots);

    // Depth ≥99 only: lift 100 toward ~99% on 768D small corpora without
    // moving ≤98. Extra SQ8 matters — 48-D heap otherwise saturates and
    // +leaves after 100 barely moves Recall@10.
    if (depth >= 99) {
      final tip = min(2, depth - 98); // 1 @99, 2 @100+
      roots += tip * 2; // +2 / +4
      leaves += tip * 4; // +4 / +8
      slots += tip * 8; // +8 / +16
    }

    // Mild density nudge only. Insert soft-caps leaf occupancy at ~32
    // ([NghPageSizer.searchCalibMaxSlotsPerPage]) so 128D no longer packs
    // ~99 slots/page. Residual dens>1.25 (32/20) trims leaves lightly and
    // buys cheap SQ8 — no heavy N^0.6 leaf inflation (that made 128D slower
    // and still short of 768D recall).
    const refSlotsPerPage = 20.0;
    final slotsPerPage = NghPageSizer.estimatePostingSlotsPerPage(
      max(4096, postingPageSize),
      max(1, dimensions),
    ).toDouble();
    if (slotsPerPage > refSlotsPerPage * 1.25) {
      final dens = slotsPerPage / refSlotsPerPage;
      leaves = max(1, (leaves / dens).round());
      // Floor so depth anchors still have multi-leaf routing.
      final minLeaves =
          depth <= 1 ? 3 : (depth <= 50 ? 5 : (depth <= 98 ? 8 : 12));
      leaves = max(minLeaves, leaves);
      slots = max(slots, (slots * min(1.8, 0.95 + 0.2 * dens)).round());
      if (dens >= 1.5 && depth >= 50) {
        roots = min(256, roots + 1);
      }
    }

    // Soft safety caps only — must not stall the depth>100 escape hatch early.
    // Runtime still clamps roots to validRoots / leaves to hydrated inventory.
    return (
      wantRoots: min(256, roots),
      wantLeaves: min(1024, leaves),
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
    final hot = _searchCentroidBTreeTryHot(
      table: table,
      indexUid: indexUid,
      meta: meta,
      state: state,
      query: query,
      topK: topK,
      searchDepth: searchDepth,
      distanceThreshold: distanceThreshold,
      queryAlreadyNormalized: queryAlreadyNormalized,
      pendingDeletePks: pendingDeletePks,
      allowHydrate: true,
    );
    if (hot.sync != null) {
      return Future<List<NghSearchResult>>.value(hot.sync!);
    }
    return hot.async!;
  }

  /// Shared Centroid B+Tree probe. When [allowHydrate] is false and leaves are
  /// missing, returns sync=null / async=null (caller treats as cold miss).
  ({List<NghSearchResult>? sync, Future<List<NghSearchResult>>? async})
      _searchCentroidBTreeTryHot({
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
    bool allowHydrate = false,
  }) {
    final isCosine = meta.distanceMetric == VectorDistanceMetric.cosine;
    final isIP = meta.distanceMetric == VectorDistanceMetric.innerProduct;

    Float32List searchQuery = query;
    if (isCosine && !queryAlreadyNormalized) {
      // Normalize into scratch — avoid per-query Float32List alloc.
      _normalizeFloat32Into(query, state.scratchQFull);
      searchQuery = state.scratchQFull;
    }

    _extractLow48Into(searchQuery, state.scratchQLow);
    final qLowSimd = state.scratchQLowSimd;
    // SIMD sum of query (matches tool/test_centroid_btree_engine.dart).
    double qFullSum;
    final dim = meta.dimensions;
    final qFullAligned = (searchQuery.offsetInBytes & 15) == 0;
    if (qFullAligned && dim >= 16) {
      final n4 = dim >> 2;
      final qSimd =
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

    state.nextQueryStamp();

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
      postingPageSize: _postingPageSize(meta),
      searchDepth: searchDepth,
    );

    // 1. Level 0: score every root (test-tool hot path). Empty roots are
    // cheap to score and skipped at L1 — avoid Map + nested emptiness scans.
    final numRoots = state.numRootCentroids;
    final wantRoots = plan.wantRoots;
    final rootSimd = state.rootCentroids48Simd;
    final chainsByRoot = state.chainsByRoot;
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
      if (rootsToProbe > 0) state.probedRoots[0] = r0;
      if (rootsToProbe > 1) state.probedRoots[1] = r1;
      if (rootsToProbe > 2) state.probedRoots[2] = r2;
      if (rootsToProbe > 3) state.probedRoots[3] = r3;
      if (rootsToProbe > 4) state.probedRoots[4] = r4;
      if (rootsToProbe > 5) state.probedRoots[5] = r5;
    } else {
      final maxTrack = min(numRoots, state.rootScores.length);
      for (int i = 0; i < maxTrack; i++) {
        state.rootScores[i] = innerProduct48Reg(
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
        state.rootIndices[i] = i;
      }
      final validRoots = maxTrack;
      rootsToProbe = min(wantRoots, validRoots);
      for (int i = 0; i < rootsToProbe; i++) {
        var bestIdx = i;
        var bestScore = state.rootScores[i];
        for (int j = i + 1; j < validRoots; j++) {
          if (state.rootScores[j] > bestScore) {
            bestScore = state.rootScores[j];
            bestIdx = j;
          }
        }
        if (bestIdx != i) {
          final ts = state.rootScores[i];
          state.rootScores[i] = state.rootScores[bestIdx];
          state.rootScores[bestIdx] = ts;
          final ti = state.rootIndices[i];
          state.rootIndices[i] = state.rootIndices[bestIdx];
          state.rootIndices[bestIdx] = ti;
        }
        state.probedRoots[i] = state.rootIndices[i];
      }
    }

    // 2. Level 1: Streaming min-heap branch selection (dense chain lookup)
    final maxLeavesToRead = min(plan.wantLeaves, state.pickedLeaves.length);
    state.branchHeap.reset(maxLeavesToRead);
    for (int r = 0; r < rootsToProbe; r++) {
      final rootId = state.probedRoots[r];
      final chain = (rootId >= 0 && rootId < chainsByRoot.length)
          ? chainsByRoot[rootId]
          : null;
      if (chain == null || chain.isEmpty) continue;
      for (int c = 0; c < chain.length; c++) {
        final entries = chain[c].page.entries;
        for (int e = 0; e < entries.length; e++) {
          final entry = entries[e];
          final score = innerProduct48Reg(
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
            entry.centroid48DSimd,
            0,
          );
          if (state.branchHeap.size >= maxLeavesToRead &&
              score <= state.branchHeap.minScore) {
            continue;
          }
          state.branchHeap.push(entry, score);
        }
      }
    }

    final leavesToPick = state.branchHeap.size;
    var allCached = true;
    for (int i = 0; i < leavesToPick; i++) {
      final entry = state.branchHeap.entries[i + 1]!;
      state.pickedLeaves[i] = entry;
      final page = _btreeLeafGet(
        table.tableUid,
        indexUid,
        entry.leafPageId,
        touch: false,
      );
      state.pickedLeafPages[i] = page;
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
        state: state,
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
      for (int l = 0; l < leavesToPick; l++) state.pickedLeaves[l]!.leafPageId,
    ];
    await _hydrateBTreeLeaves(
      table: table,
      indexUid: indexUid,
      meta: meta,
      leafIds: pickIds,
    );
    for (int i = 0; i < leavesToPick; i++) {
      state.pickedLeafPages[i] = _btreeLeafGet(
        table.tableUid,
        indexUid,
        state.pickedLeaves[i]!.leafPageId,
        touch: false,
      );
    }
    return _rankCentroidBTreeLeaves(
      state: state,
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
    required CentroidBTreeState state,
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
    state.slotHeap.reset(planCandSlots);
    final stampCheck = state.visitedTag;
    final stamp = state.currentStamp;
    for (int l = 0; l < leavesToPick; l++) {
      final leafPage = state.pickedLeafPages[l];
      if (leafPage == null) continue;

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
          if (state.slotHeap.size >= state.slotHeap.capacity &&
              s48 <= state.slotHeap.minScore) {
            continue;
          }
          state.slotHeap.push(slot, s48);
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
        if (state.slotHeap.size >= state.slotHeap.capacity &&
            s48 <= state.slotHeap.minScore) {
          continue;
        }
        state.slotHeap.push(slot, s48);
      }
    }

    final q = searchQuery;
    final dim = dimensions;
    var resultHeap = state._resultHeap;
    if (resultHeap == null || resultHeap.capacity < topK) {
      resultHeap = _FixedHeap(topK, maxHeap: true);
      state._resultHeap = resultHeap;
    } else {
      resultHeap.clear();
    }

    final hasPending = pendingDeletePks != null;
    final hasThreshold = distanceThreshold != null;
    final threshold = distanceThreshold ?? 0.0;

    for (int i = 1; i <= state.slotHeap.size; i++) {
      final slot = state.slotHeap.slots[i]!;
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
  /// into the modern Centroid B+Tree layout.
  ///
  /// Takes the existing centroid nodes from [blob], clusters their 48-D projections
  /// into up to 64 root centroids via in-memory k-means (taking < 5ms for thousands of
  /// centroids), links each existing centroid into its nearest root internal page chain
  /// preserving all physical posting page associations, writes out [dirtyNavRootPage]
  /// and [dirtyNavBTreePages], and updates [meta] with modern B+Tree pointers.
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

    // 2. K-means clustering over centroids to produce up to 64 root seeds
    const targetRoots = 64;
    final numRoots = min(targetRoots, max(1, centroids.length));
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

    // 4. Calculate total entries per root (expanding multiple posting pages if any)
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
        final cPages = c.postingPages.isNotEmpty
            ? c.postingPages
            : (c.postingPageNos.isNotEmpty
                ? c.postingPageNos
                    .map(NghPageId.fromPacked)
                    .toList(growable: false)
                : (c.headPostingPageNo >= 0
                    ? [NghPageId.fromPacked(c.headPostingPageNo)]
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

    // 5. Calculate internal pages needed per root
    final pagesNeededPerRoot = List<int>.generate(numRoots, (r) {
      final count = rootEntries[r].length;
      return max(
          1,
          (count + NghNavBTreePage.maxEntriesPerPage - 1) ~/
              NghNavBTreePage.maxEntriesPerPage);
    });
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
      dimensions: dims,
    );

    int navPageCursor = 1;

    for (int r = 0; r < numRoots; r++) {
      final entries = rootEntries[r];
      final pagesCount = pagesNeededPerRoot[r];
      final rootPagePtrs =
          navPages.sublist(navPageCursor, navPageCursor + pagesCount);
      navPageCursor += pagesCount;

      final firstInternalPtr = rootPagePtrs.first;
      final firstInternalPageId =
          NghPageId(firstInternalPtr.partitionNo, firstInternalPtr.pageNo);

      rootsList.add((
        rootId: r,
        firstInternalPage: firstInternalPageId,
        centroid48D: rootSeeds[r],
      ));

      final internalChain = <({NghPageId pageId, NghNavBTreePage page})>[];

      for (int pIdx = 0; pIdx < pagesCount; pIdx++) {
        final pagePtr = rootPagePtrs[pIdx];
        final pageId = NghPageId(pagePtr.partitionNo, pagePtr.pageNo);
        final nextPageId = (pIdx + 1 < pagesCount)
            ? NghPageId(rootPagePtrs[pIdx + 1].partitionNo,
                rootPagePtrs[pIdx + 1].pageNo)
            : NghPageId.none;

        final startIdx = pIdx * NghNavBTreePage.maxEntriesPerPage;
        final endIdx =
            min(startIdx + NghNavBTreePage.maxEntriesPerPage, entries.length);
        final pageEntries = entries.sublist(startIdx, endIdx);

        final btreePage = NghNavBTreePage(
          rootCentroidId: r,
          nextInternalPage: nextPageId,
          entries: pageEntries,
        );
        dirtyNavBTreePages[pagePtr] = btreePage;
        internalChain.add((pageId: pageId, page: btreePage));
      }

      state.putRootChain(r, internalChain);

      final c48 = rootSeeds[r];
      for (int d = 0; d < 48; d++) {
        state.rootCentroids48Flat[r * 48 + d] = c48[d];
      }
    }

    state.nextCentroidId = maxCentroidId;

    final view = Float32x4List.sublistView(state.rootCentroids48Flat);
    for (int i = 0; i < state.rootCentroids48Simd.length; i++) {
      state.rootCentroids48Simd[i] = view[i];
    }

    _btreeStates[_cacheKey(table.tableUid, indexUid)] = state;

    final rootPage = NghNavRootPage(
      lowDim: 48,
      fullDim: dims,
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
        dirtyPostingPages: const {},
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

    final dirtyPostingPages = <NghPagePtr, NghPostingPage>{};
    final dirtyNavBTreePages = <NghPagePtr, NghNavBTreePage>{};
    ({NghPagePtr ptr, NghNavRootPage page})? dirtyNavRootPage;
    // Mutation-local leaves (not TreeCache) so mid-insert puts cannot evict
    // pages still being written. Flushed into posting TreeCache; search hot
    // set is promoted via [promotePagedLeavesAfterInsert].
    final insertLeaves = <NghPageId, NghPostingPage>{};

    var state = _btreeStates[_cacheKey(table.tableUid, indexUid)];
    state ??= await _getOrLoadBTreeState(table, indexUid, currentMeta);
    if (state == null) {
      // Cold-start training 64 Root Centroids (48-D)
      const targetRoots = 64;
      final numRoots = min(targetRoots, max(1, vectors.length));
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
          entries: [],
        );
        dirtyNavBTreePages[internalPtr] = internalPage;
      }

      final rootPage = NghNavRootPage(
        lowDim: 48,
        fullDim: currentMeta.dimensions,
        roots: rootsList,
      );
      dirtyNavRootPage = (ptr: rootPtr, page: rootPage);

      state = CentroidBTreeState(
        numRootCentroids: numRoots,
        rootPageId: rootPageId,
        dimensions: currentMeta.dimensions,
      );
      for (int r = 0; r < numRoots; r++) {
        final c = rootsList[r].centroid48D;
        for (int d = 0; d < 48; d++) {
          state.rootCentroids48Flat[r * 48 + d] = c[d];
        }
        final intPtr = navPages[1 + r];
        final intPageId = NghPageId(intPtr.partitionNo, intPtr.pageNo);
        state.putRootChain(r, [
          (pageId: intPageId, page: dirtyNavBTreePages[intPtr]!),
        ]);
      }
      final view = Float32x4List.sublistView(state.rootCentroids48Flat);
      for (int i = 0; i < state.rootCentroids48Simd.length; i++) {
        state.rootCentroids48Simd[i] = view[i];
      }
      _btreeStates[_cacheKey(table.tableUid, indexUid)] = state;
    }

    final postingPageSize = _postingPageSize(currentMeta);
    final maxSlotsPerPage = NghPageSizer.estimatePostingSlotsPerPage(
      postingPageSize,
      currentMeta.dimensions,
    );

    void insertSlotIntoLeaf(
      int rootId,
      CentroidBranchEntry branchEntry,
      ({NghPageId pageId, NghNavBTreePage page}) ownerInternal,
      NghPostingSlot newSlot,
    ) {
      final leafPageId = branchEntry.leafPageId;
      final ptr = NghPagePtr(
          NghDataCategory.posting, leafPageId.partitionNo, leafPageId.pageNo);
      var leafPage = dirtyPostingPages[ptr] ??
          insertLeaves[leafPageId] ??
          _btreeLeafGet(table.tableUid, indexUid, leafPageId, touch: false);
      leafPage ??= NghPostingPage(
        centroidId: branchEntry.centroidId,
        dimensions: currentMeta.dimensions,
        slots: [],
      );
      insertLeaves[leafPageId] = leafPage;

      final currentPayload = leafPage.estimatePayloadSize();
      final newSlotBytes = 19 +
          (newSlot.primaryKeyBytes?.length ?? newSlot.primaryKeyUtf8.length) +
          currentMeta.dimensions;
      final fitsInPhysicalPage =
          (20 + currentPayload + newSlotBytes) <= (postingPageSize - 64);

      if (leafPage.slots.length < maxSlotsPerPage && fitsInPhysicalPage) {
        leafPage.slots.add(newSlot);
        branchEntry.leafSlotCount = leafPage.slots.length;
        branchEntry.centroid48D = _computeMean48(leafPage.slots);
        branchEntry.centroid48DSimd =
            Float32x4List.sublistView(branchEntry.centroid48D);

        final ptr = NghPagePtr(
            NghDataCategory.posting, leafPageId.partitionNo, leafPageId.pageNo);
        dirtyPostingPages[ptr] = leafPage;
        final ownerPtr = NghPagePtr(NghDataCategory.nav,
            ownerInternal.pageId.partitionNo, ownerInternal.pageId.pageNo);
        dirtyNavBTreePages[ownerPtr] = ownerInternal.page;
      } else {
        // 50/50 Balanced Geometric Hyperplane Split
        leafPage.slots.add(newSlot);

        final seedASimd =
            leafPage.slots[0].getLow48DSimd(currentMeta.dimensions);
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

        final groupA = <NghPostingSlot>[];
        final groupB = <NghPostingSlot>[];
        final mid = leafPage.slots.length ~/ 2;
        for (int i = 0; i < mid; i++) {
          groupA.add(leafPage.slots[projIndices[i]]);
        }
        for (int i = mid; i < leafPage.slots.length; i++) {
          groupB.add(leafPage.slots[projIndices[i]]);
        }

        leafPage.slots.clear();
        leafPage.slots.addAll(groupA);
        branchEntry.leafSlotCount = groupA.length;
        branchEntry.centroid48D = _computeMean48(groupA);
        branchEntry.centroid48DSimd =
            Float32x4List.sublistView(branchEntry.centroid48D);

        final ptrA = NghPagePtr(
            NghDataCategory.posting, leafPageId.partitionNo, leafPageId.pageNo);
        dirtyPostingPages[ptrA] = leafPage;
        final ownerPtr = NghPagePtr(NghDataCategory.nav,
            ownerInternal.pageId.partitionNo, ownerInternal.pageId.pageNo);
        dirtyNavBTreePages[ownerPtr] = ownerInternal.page;

        final (newPostingPtrs, nextPostingMeta) =
            _partitionManager.allocatePagesBatchSync(
          NghDataCategory.posting,
          currentMeta,
          1,
        );
        currentMeta = nextPostingMeta;
        final newLeafPtr = newPostingPtrs.first;
        final newLeafPageId =
            NghPageId(newLeafPtr.partitionNo, newLeafPtr.pageNo);

        final nextCentroidId = ++state!.nextCentroidId;
        final newPostingPage = NghPostingPage(
          centroidId: nextCentroidId,
          dimensions: currentMeta.dimensions,
          slots: groupB,
        );
        insertLeaves[newLeafPageId] = newPostingPage;
        dirtyPostingPages[newLeafPtr] = newPostingPage;

        final newCentroid48 = _computeMean48(groupB);
        final newBranchEntry = CentroidBranchEntry(
          centroidId: nextCentroidId,
          leafPageId: newLeafPageId,
          leafSlotCount: groupB.length,
          centroid48D: newCentroid48,
        );

        final chain = state.internalChains[rootId]!;
        final lastPageItem = chain.last;
        if (lastPageItem.page.entries.length <
            NghNavBTreePage.maxEntriesPerPage) {
          lastPageItem.page.entries.add(newBranchEntry);
          dirtyNavBTreePages[NghPagePtr(
              NghDataCategory.nav,
              lastPageItem.pageId.partitionNo,
              lastPageItem.pageId.pageNo)] = lastPageItem.page;
        } else {
          final (navPtrs, nextNavMeta) =
              _partitionManager.allocatePagesBatchSync(
            NghDataCategory.nav,
            currentMeta,
            1,
          );
          currentMeta = nextNavMeta;
          final newNavPtr = navPtrs.first;
          final newNavPageId =
              NghPageId(newNavPtr.partitionNo, newNavPtr.pageNo);

          lastPageItem.page.nextInternalPage = newNavPageId;
          dirtyNavBTreePages[NghPagePtr(
              NghDataCategory.nav,
              lastPageItem.pageId.partitionNo,
              lastPageItem.pageId.pageNo)] = lastPageItem.page;

          final newInternalPage = NghNavBTreePage(
            rootCentroidId: rootId,
            nextInternalPage: NghPageId.none,
            entries: [newBranchEntry],
          );
          chain.add((pageId: newNavPageId, page: newInternalPage));
          dirtyNavBTreePages[newNavPtr] = newInternalPage;
        }
      }
    }

    void insertIntoRoot(
      int rootId,
      NghPostingSlot newSlot,
      Float32x4List qLowSimd,
    ) {
      var chain = state!.internalChains[rootId];
      if (chain == null || chain.isEmpty) {
        final (pPtrs, pMeta) = _partitionManager.allocatePagesBatchSync(
          NghDataCategory.nav,
          currentMeta,
          1,
        );
        currentMeta = pMeta;
        final pPtr = pPtrs.first;
        final pId = NghPageId(pPtr.partitionNo, pPtr.pageNo);
        final emptyP = NghNavBTreePage(rootCentroidId: rootId, entries: []);
        chain = [(pageId: pId, page: emptyP)];
        state.putRootChain(rootId, chain);
        dirtyNavBTreePages[pPtr] = emptyP;
      }

      bool allEmpty = true;
      for (final it in chain) {
        if (it.page.entries.isNotEmpty) {
          allEmpty = false;
          break;
        }
      }

      if (allEmpty) {
        final (ptrs, nextM) = _partitionManager.allocatePagesBatchSync(
          NghDataCategory.posting,
          currentMeta,
          1,
        );
        currentMeta = nextM;
        final leafPtr = ptrs.first;
        final leafPageId = NghPageId(leafPtr.partitionNo, leafPtr.pageNo);

        final nextCentroidId = ++state.nextCentroidId;
        final postingPage = NghPostingPage(
          centroidId: nextCentroidId,
          dimensions: currentMeta.dimensions,
          slots: [newSlot],
        );
        insertLeaves[leafPageId] = postingPage;
        dirtyPostingPages[leafPtr] = postingPage;

        final newCentroid48 = Float32List.fromList(newSlot.low48D!);
        final firstItem = chain.first;
        firstItem.page.entries.add(CentroidBranchEntry(
          centroidId: nextCentroidId,
          leafPageId: leafPageId,
          leafSlotCount: 1,
          centroid48D: newCentroid48,
        ));
        dirtyNavBTreePages[NghPagePtr(
            NghDataCategory.nav,
            firstItem.pageId.partitionNo,
            firstItem.pageId.pageNo)] = firstItem.page;
        return;
      }

      CentroidBranchEntry? bestEntry;
      ({NghPageId pageId, NghNavBTreePage page})? bestOwner;
      double maxBranchScore = -1e9;
      for (final it in chain) {
        final p = it.page;
        for (int i = 0; i < p.entries.length; i++) {
          final entry = p.entries[i];
          final s = innerProduct48(qLowSimd, entry.centroid48DSimd, 0);
          if (s > maxBranchScore) {
            maxBranchScore = s;
            bestEntry = entry;
            bestOwner = it;
          }
        }
      }

      insertSlotIntoLeaf(rootId, bestEntry!, bestOwner!, newSlot);
    }

    // Pre-warm / batch-hydrate cold leaf posting pages from disk
    final neededLeafIds = <NghPageId>{};
    for (int i = 0; i < vectors.length; i++) {
      final fullVec = normalizedVectors[i];
      final lowVec = _extractLow48(fullVec);
      state.scratchQLow.setRange(0, 48, lowVec);
      final qLowSimd = state.scratchQLowSimd;

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

      void probeChain(int rootId) {
        final chain = state!.internalChains[rootId];
        if (chain == null || chain.isEmpty) return;
        CentroidBranchEntry? bestEntry;
        double maxScore = -1e9;
        for (final it in chain) {
          for (final entry in it.page.entries) {
            final s = innerProduct48(qLowSimd, entry.centroid48DSimd, 0);
            if (s > maxScore) {
              maxScore = s;
              bestEntry = entry;
            }
          }
        }
        if (bestEntry != null) {
          neededLeafIds.add(bestEntry.leafPageId);
        }
      }

      probeChain(bestRoot0);
      if (maxScore1 >= maxScore0 * 0.94) {
        probeChain(bestRoot1);
      }
    }

    await _hydrateBTreeLeaves(
      table: table,
      indexUid: indexUid,
      meta: currentMeta,
      leafIds: neededLeafIds,
      insertScratch: insertLeaves,
    );

    // Globally unique nodeIds across flushes
    final baseNodeId = currentMeta.nextNodeId;
    for (int i = 0; i < vectors.length; i++) {
      final fullVec = normalizedVectors[i];
      final pk = primaryKeys[i];
      final lowVec = _extractLow48(fullVec);

      state.scratchQLow.setRange(0, 48, lowVec);
      final qLowSimd = state.scratchQLowSimd;

      final sq8 = ScalarQuantizer.quantize(fullVec);
      final pkBytes = Uint8List.fromList(utf8.encode(pk));
      final newSlot = NghPostingSlot(
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

      insertIntoRoot(bestRoot0, newSlot, qLowSimd);
      if (maxScore1 >= maxScore0 * 0.94) {
        insertIntoRoot(bestRoot1, newSlot, qLowSimd);
      }
    }

    // Populate exact PK Map locators
    final pkBatch = NghPkMapBatch(meta: currentMeta);
    final pkLocators = <String, List<NghPkLocator>>{};
    for (final entry in dirtyPostingPages.entries) {
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
      var locs = e.value;
      if (locs.length > 2) locs = locs.sublist(0, 2);
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
      dirtyPostingPages: dirtyPostingPages,
      dirtyNavBTreePages: dirtyNavBTreePages,
      dirtyNavRootPage: dirtyNavRootPage,
      dirtyPkmapPages: pkBatch.dirty,
      insertedCount: vectors.length,
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
    if (meta.layoutVersion < NghIndexMeta.layoutPaged) return null;
    final cached = _btreeStates[_cacheKey(table.tableUid, indexUid)];
    if (cached == null || cached.numRootCentroids <= 0) return null;
    return _searchCentroidBTreeTryHot(
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
      allowHydrate: false,
    ).sync;
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
  }) {
    if (meta.totalVectors == 0) {
      return Future<List<NghSearchResult>>.value(const []);
    }

    if (meta.layoutVersion >= NghIndexMeta.layoutPaged) {
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

    return _searchLegacyIvf(
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

  Future<List<NghSearchResult>> _searchLegacyIvf({
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
    final key = _cacheKey(table.tableUid, indexUid);
    final clusterMap = <int, List<_NghCompactSlot>>{};

    final cachedNav = _navGraphCache.getPoint2(
      table.tableUid.value,
      indexUid.value,
      touch: true,
    );
    final NghNavGraphPage? navGraph = (cachedNav != null &&
            (meta.centroidCount <= 0 ||
                cachedNav.centroids.length >= meta.centroidCount))
        ? cachedNav
        : await _getOrLoadNavGraph(table, indexUid, meta);
    if (navGraph == null || navGraph.centroids.isEmpty) {
      return const [];
    }

    Float32List searchQuery = query;
    if (meta.distanceMetric == VectorDistanceMetric.cosine &&
        !queryAlreadyNormalized) {
      searchQuery = _normalizeFloat32(query);
    }

    final bool canSimd =
        (searchQuery.offsetInBytes & 15) == 0 && (searchQuery.length & 3) == 0;
    final Float32x4List? querySimd = canSimd
        ? Float32x4List.view(
            searchQuery.buffer,
            searchQuery.offsetInBytes,
            searchQuery.length >> 2,
          )
        : null;

    final prep = _prepQueryStats(searchQuery);
    final querySum = prep.$1;
    final querySqNorm = prep.$2;

    final imbalance =
        navGraph.cachedImbalance ??= _centroidImbalance(navGraph.centroids);
    final routingIds = navGraph.cachedTopLevelRoutingIds ??=
        _topLevelRoutingIds(navGraph.centroids);
    int nLeaves = navGraph.cachedNLeaves ?? 0;
    if (navGraph.cachedNLeaves == null) {
      nLeaves = 0;
      for (final c in navGraph.centroids) {
        if (c.isLeaf) nLeaves++;
      }
      navGraph.cachedNLeaves = nLeaves;
    }
    var nCoarse = 0;
    for (final c in navGraph.centroids) {
      if (c.isCoarse) nCoarse++;
    }
    final plan = _resolveNprobePlan(
      nCentroids:
          routingIds.isNotEmpty ? routingIds.length : navGraph.centroids.length,
      nLeaves: max(1, nLeaves),
      nCoarse: nCoarse,
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
      querySimd: querySimd,
    );

    final depthT = min(1.0, plan.depth / 100.0);
    // Graph hops recover split-drift identity; more than 1–2 just rescore
    // the same hubs (1M depth 90–100: +30ms for +0.3pp). Nesting cliff
    // allows one extra hop — home often sits on a neighbor of the top L0.
    final cliff = nLeaves > routingIds.length;
    final maxNeighborExtra = (nLeaves < 96 || depthT < 0.35)
        ? 0
        : (cliff ? (depthT < 0.80 ? 2 : 3) : (depthT < 0.80 ? 1 : 2));
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
      wantLeaves: plan.wantLeaves,
      querySimd: querySimd,
    );

    final avgCluster = max(
      1,
      (meta.totalVectors /
              max(1, nLeaves > 0 ? nLeaves : navGraph.centroids.length))
          .round(),
    );
    final slotCap = _slotCapForDepth(
      plan.depth,
      nLeaves: nLeaves,
      totalVectors: meta.totalVectors,
    );
    final trimBudget = min(slotCap, plan.maxCandidates);
    // wantLeaves is a hard scoring floor. Using minKeep=2 here let clamp
    // drop every depth back to the same 1–2 hubs (1M frozen at 61%).
    final minKeep = min(probeCentroids.length, max(2, plan.wantLeaves));
    final targetProbes = minKeep;
    final rankedProbes = probeCentroids;
    probeCentroids = _trimProbesToCandidateBudget(
      probes: rankedProbes,
      navGraph: navGraph,
      maxCandidates: trimBudget,
      avgCluster: avgCluster,
      minKeep: minKeep,
      targetProbes: targetProbes,
    );

    final minProbeFloor = min(rankedProbes.length, targetProbes);
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

    final scoreBudget = min(slotCap, (plan.maxCandidates * 1.15).round());
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
      final cached = _clusterCache.getPoint3(
        table.tableUid.value,
        indexUid.value,
        cId,
        touch: true,
      );
      if (cached != null &&
          _clusterCacheIsFresh(cached, navGraph.centroids[cId])) {
        clusterMap[cId] = cached.slots;
      } else {
        if (cached != null) {
          _removeCentroidSlots(table.tableUid, indexUid, cId);
        }
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

    final resultHeap = _FixedHeap(max(1, topK), maxHeap: true);
    final isCosine = meta.distanceMetric == VectorDistanceMetric.cosine;
    final isIP = meta.distanceMetric == VectorDistanceMetric.innerProduct;

    void scoreClusterFull(int cId) {
      final slots = clusterMap[cId];
      if (slots == null || slots.isEmpty) return;
      final sCount = slots.length;
      if (isCosine) {
        for (var i = 0; i < sCount; i++) {
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
      } else if (isIP) {
        for (var i = 0; i < sCount; i++) {
          final slot = slots[i];
          if (slot.flags & 0x01 != 0) continue;
          final dist = ScalarQuantizer.fastDotProduct(
            searchQuery,
            querySum,
            slot.sq8Codes,
            slot.offset,
            slot.scale,
          );
          if (distanceThreshold != null && dist > distanceThreshold) continue;
          if (!resultHeap.isFull || dist < resultHeap.peekDist) {
            resultHeap.pushWithPk(slot.nodeId, dist, slot.primaryKeyBytes);
          }
        }
      } else {
        for (var i = 0; i < sCount; i++) {
          final slot = slots[i];
          if (slot.flags & 0x01 != 0) continue;
          final dist = ScalarQuantizer.fastSquaredL2Distance(
            searchQuery,
            querySqNorm,
            querySum,
            slot.sq8Codes,
            slot.offset,
            slot.scale,
            slot.squaredNorm,
          );
          if (distanceThreshold != null && dist > distanceThreshold) continue;
          if (!resultHeap.isFull || dist < resultHeap.peekDist) {
            resultHeap.pushWithPk(slot.nodeId, dist, slot.primaryKeyBytes);
          }
        }
      }
    }

    // Full SQ8 precision scoring for all selected clusters.
    // probeCentroids is ordered nearest-first, allowing resultHeap to quickly
    // tighten its peekDist threshold and skip distant vectors with minimal cost.
    final yc = YieldController(
      'NghGraphEngine.search.score',
      checkInterval: 1,
      budgetMs: 16,
    );

    for (var c = 0; c < probeCentroids.length; c++) {
      final cId = probeCentroids[c];
      scoreClusterFull(cId);

      final y = yc.maybeYield();
      if (y != null) await y;
    }

    final rawResults = resultHeap.drainSortedWithPk();
    final pending = pendingDeletePks;
    final results = [
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

    return results;
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

  int _appendSlotsUntilFull(
    NghPostingPage page,
    List<NghPostingSlot> src,
    int from, {
    required int pageSize,
  }) {
    var i = from;
    while (i < src.length) {
      page.slots.add(src[i]);
      if (!_partitionManager.postingPayloadFits(
        page.estimatePayloadSize(),
        pageSize: pageSize,
      )) {
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

    if (meta.layoutVersion >= NghIndexMeta.layoutPaged) {
      return _insertBatchCentroidBTree(
        table: table,
        indexUid: indexUid,
        meta: meta,
        vectors: vectors,
        primaryKeys: primaryKeys,
        yieldBudgetMs: yieldBudgetMs,
      );
    }

    final dirtyPosting = <NghPagePtr, NghPostingPage>{};
    final localPostingCache = <int, NghPostingPage>{};
    var currentMeta = NghPageSizer.ensureIndexPageSizes(
      meta,
      _partitionManager.configuredPageSize,
    );
    final postingPageSize = _postingPageSize(currentMeta);
    final navPageSize = _navPageSize(currentMeta);

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
      postingPageSize,
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

    // Dynamic centroids: leaf K capped; format supports two-level hierarchical centroids beyond this.
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
      // give the same centroid skeleton and the insert loop still assigns all rows.
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
      navPageSize,
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
      // L0 distances (vs coarses ∪ orphan leaves) — used only for top-level
      // orphan spawn while the routing skeleton can still grow.
      final l0BestDist = bestD[i];
      final l0SecondDist = secondD[i];
      final bestCId = hasCoarse
          ? _resolveLeafCentroid(rawBest, centroids, vec, assignMetric)
          : (rawBest < 0 ? 0 : rawBest);
      var secondCId = rawSecond < 0
          ? -1
          : (hasCoarse
              ? _resolveLeafCentroid(rawSecond, centroids, vec, assignMetric)
              : rawSecond);
      if (secondCId == bestCId) secondCId = -1;

      // Spawn / multi-assign farness must use the *resolved leaf*, not the
      // covering coarse — otherwise points near a coarse but far from every
      // leaf skip spawn and inflate hubs (recall cliff past ~1M).
      var bestDist = l0BestDist;
      var secondDist = l0SecondDist;
      if (hasCoarse) {
        if (bestCId >= 0 && bestCId < centroids.length) {
          bestDist =
              _exactDistance(vec, centroids[bestCId].vector, assignMetric);
        }
        if (secondCId >= 0 && secondCId < centroids.length) {
          secondDist =
              _exactDistance(vec, centroids[secondCId].vector, assignMetric);
        }
      }

      final canGrowTop = topLevelIds.length < routingCap;
      final softCap = softCapForK(max(1, leafK));

      // Dynamic adaptive distance spawn threshold:
      // When current centroids are far below targetK, smoothly scale down the threshold
      // so the centroid skeleton reaches the target density without starving small/mid corpora.
      final currentTopK = topLevelIds.length;
      final kRatio = currentTopK / max(1, targetK);
      final double effectiveSplitThreshold = currentTopK < targetK
          ? (isCosineMetric
              ? max(0.12, splitDistThreshold * sqrt(kRatio))
              : (currentMeta.distanceMetric == VectorDistanceMetric.innerProduct
                  ? min(-0.40, splitDistThreshold * sqrt(kRatio))
                  : max(0.25, splitDistThreshold * sqrt(kRatio))))
          : splitDistThreshold;

      // Distance spawn for far points only (new tiny centroid at L0).
      // Use L0 distance so growth follows the same exact router as search.
      if (canGrowTop && l0BestDist > effectiveSplitThreshold) {
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
        slotIndex = _appendSlotsUntilFull(
          tailPage,
          newSlots,
          slotIndex,
          pageSize: postingPageSize,
        );
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
        slotIndex = _appendSlotsUntilFull(
          newPage,
          newSlots,
          slotIndex,
          pageSize: postingPageSize,
        );
        if (newPage.slots.isEmpty && slotIndex < newSlots.length) {
          throw DbException([
            GeneralStatus(
              type: ResultType.engError,
              message:
                  'NGH posting slot does not fit in a $postingPageSize-byte page '
                  '(dimensions=${currentMeta.dimensions}, '
                  'pkBytes=${newSlots[slotIndex].primaryKeyUtf8.length}).',
            )
          ]);
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

    // Step 6: Persist paged nav/pkmap partitions (or migrate legacy blob).
    final navGraphPage = NghNavGraphPage(
      dimensions: currentMeta.dimensions,
      centroids: centroids,
    );
    _navGraphCache.putPoint2(
      table.tableUid.value,
      indexUid.value,
      navGraphPage,
    );

    final rewrittenIds = splitBatch.rewrittenCentroidIds;
    for (final cId in rewrittenIds) {
      _removeCentroidSlots(table.tableUid, indexUid, cId);
      final slots = splitBatch.slotsByCentroid[cId];
      if (slots == null || slots.isEmpty) continue;
      final packedRef = centroids[cId].tailPostingPageNo;
      final cList = <_NghCompactSlot>[
        for (final slot in slots)
          _compactFromPostingSlot(slot, packedRef > 0 ? packedRef : 1),
      ];
      _putCentroidSlots(
        tableUid: table.tableUid,
        indexUid: indexUid,
        centroidId: cId,
        slots: cList,
        entryCount: centroids[cId].entryCount,
      );
    }
    final needsCompactGapFill = _refreshCompactCacheAfterInsert(
      tableUid: table.tableUid,
      indexUid: indexUid,
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
    for (var hop = 0; hop < _maxTreeDepth + 2; hop++) {
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

  int _nodeTreeDepth(List<NghNavCentroidNode> centroids, int id) {
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
      deleteLegacy = true;
      for (final c in centroids) {
        c.postingDirDirty = false;
      }
    } else {
      for (final c in centroids) {
        c.postingDirDirty = false;
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
        _navPageSize(currentMeta),
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
      _navPageSize(meta),
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
      final hubDepth = _nodeTreeDepth(centroids, hubId);
      var makeCoarse = false;
      if (parentFull) {
        if (hubDepth >= _maxTreeDepth) {
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

    var currentMeta = NghPageSizer.ensureIndexPageSizes(
      meta,
      _partitionManager.configuredPageSize,
    );
    final dirtyPosting = <NghPagePtr, NghPostingPage>{};
    final dirtyNavIds = <int>{};
    final pkBatch = NghPkMapBatch(meta: currentMeta);
    final unresolved = <String>[];
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

    final NghNavGraphPage? navGraph = currentMeta.isPagedLayout
        ? null
        : await _getOrLoadNavGraph(table, indexUid, meta);

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
        final cached = _clusterCache.getPoint3(
          table.tableUid.value,
          indexUid.value,
          loc.centroidId,
          touch: false,
        );
        if (cached != null) {
          var cachedHit = false;
          for (final slot in cached.slots) {
            if (utf8.decode(slot.primaryKeyBytes) == pk) {
              slot.flags |= 0x01;
              cachedHit = true;
            }
          }
          if (cachedHit) {
            cached.entryCount = max(0, cached.entryCount - 1);
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
        _navPageSize(currentMeta),
        currentMeta.dimensions,
      );
    }
    if (navGraph != null) {
      _navGraphCache.putPoint2(
        table.tableUid.value,
        indexUid.value,
        navGraph,
      );
    }

    return NghDeleteResult(
      meta: currentMeta,
      dirtyPostingPages: dirtyPosting,
      dirtyNavPages: dirtyNav,
      dirtyPkmapPages: pkBatch.dirty,
      deleteLegacyNavGraph: deleteLegacy,
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
    if (meta != null && meta.layoutVersion >= NghIndexMeta.layoutPaged) {
      final key = _cacheKey(table.tableUid, indexUid);
      final btree = _btreeStates[key];
      return btree != null && btree.numRootCentroids > 0;
    }
    final cached = _navGraphCache.getPoint2(
      table.tableUid.value,
      indexUid.value,
      touch: false,
    );
    if (cached == null || cached.centroids.isEmpty) return false;
    if (meta == null || meta.centroidCount <= 0) return true;
    return cached.centroids.length >= meta.centroidCount;
  }

  /// Prefetch and cache the full paged nav graph (requires [meta] page counts).
  Future<void> prefetchNavGraph(
    TableContext table,
    IndexUid indexUid, {
    NghIndexMeta? meta,
  }) async {
    if (isNavGraphCached(table, indexUid, meta: meta)) return;
    if (meta != null && meta.layoutVersion >= NghIndexMeta.layoutPaged) {
      await _getOrLoadBTreeState(table, indexUid, meta);
      return;
    }
    await _getOrLoadNavGraph(table, indexUid, meta);
  }

  Future<NghNavGraphPage?> _getOrLoadNavGraph(
    TableContext table,
    IndexUid indexUid, [
    NghIndexMeta? meta,
  ]) async {
    final tVal = table.tableUid.value;
    final iVal = indexUid.value;
    final cached = _navGraphCache.getPoint2(tVal, iVal, touch: true);
    if (cached != null &&
        (meta == null ||
            meta.centroidCount <= 0 ||
            cached.centroids.length >= meta.centroidCount)) {
      return cached;
    }

    final key = _cacheKey(table.tableUid, indexUid);
    final existing = _navGraphInflight[key];
    if (existing != null) {
      return await existing;
    }

    final future = _partitionManager.readNavGraph(table, indexUid, meta: meta);
    _navGraphInflight[key] = future;
    try {
      final loaded = await future;
      if (loaded != null && loaded.centroids.isNotEmpty) {
        _restoreCentroidUnits(loaded, meta);
        final current = _navGraphCache.getPoint2(tVal, iVal, touch: false);
        if (current == null ||
            loaded.centroids.length >= current.centroids.length) {
          _navGraphCache.putPoint2(tVal, iVal, loaded);
        }
        return _navGraphCache.getPoint2(tVal, iVal, touch: true) ?? loaded;
      }
      return _navGraphCache.getPoint2(tVal, iVal, touch: true);
    } finally {
      _navGraphInflight.remove(key);
    }
  }

  /// SQ8 round-trip leaves cosine centroids slightly off the unit sphere.
  void _restoreCentroidUnits(NghNavGraphPage page, NghIndexMeta? meta) {
    if (meta?.distanceMetric != VectorDistanceMetric.cosine) return;
    for (final c in page.centroids) {
      final n = _normalizeFloat32(c.vector);
      if (!identical(n, c.vector) && n.length == c.vector.length) {
        c.vector.setAll(0, n);
      }
    }
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

    var currentMeta = NghPageSizer.ensureIndexPageSizes(
      meta,
      _partitionManager.configuredPageSize,
    );
    final dirtyPosting = <NghPagePtr, NghPostingPage>{};
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
        _navPageSize(currentMeta),
        currentMeta.dimensions,
      );
    }

    return NghCompactResult(
      meta: currentMeta,
      dirtyPostingPages: dirtyPosting,
      dirtyNavPages: dirtyNav,
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
  final Map<NghPagePtr, NghPkMapDirtyPage> dirtyPkmapPages;
  final Map<NghPagePtr, NghNavBTreePage> dirtyNavBTreePages;
  final ({NghPagePtr ptr, NghNavRootPage page})? dirtyNavRootPage;
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
    this.dirtyPkmapPages = const {},
    this.dirtyNavBTreePages = const {},
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
  final Map<NghPagePtr, NghPostingPage> dirtyPostingPages;
  final Map<NghPagePtr, NghNavCentroidPage> dirtyNavPages;
  final Map<NghPagePtr, NghPkMapDirtyPage> dirtyPkmapPages;
  final Map<NghPagePtr, NghNavBTreePage> dirtyNavBTreePages;
  final ({NghPagePtr ptr, NghNavRootPage page})? dirtyNavRootPage;
  final bool deleteLegacyNavGraph;
  final int deletedCount;
  final List<String> unresolvedPks;

  NghDeleteResult({
    required this.meta,
    this.dirtyPostingPages = const {},
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
  final Map<NghPagePtr, NghPostingPage> dirtyPostingPages;
  final Map<NghPagePtr, NghNavCentroidPage> dirtyNavPages;
  final Map<NghPagePtr, NghPkMapDirtyPage> dirtyPkmapPages;
  final List<NghPagePtr> freePostingPages;
  final int compactedCount;

  NghCompactResult({
    required this.meta,
    this.dirtyPostingPages = const {},
    this.dirtyNavPages = const {},
    this.dirtyPkmapPages = const {},
    this.freePostingPages = const [],
    required this.compactedCount,
  });
}

// ============================================================================
// Fixed-Size Binary Heap -- Zero-GC Search Primitive
// ============================================================================

class _FixedHeap {
  final int capacity;
  final bool maxHeap;

  late final Int32List _ids;
  late final Float64List _dists;
  late final List<Uint8List?> _pks;
  late final List<String?> _pkStrings;
  int _size = 0;

  _FixedHeap(this.capacity, {this.maxHeap = false}) {
    _ids = Int32List(capacity);
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
