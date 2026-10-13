import 'dart:math';
import 'dart:typed_data';

import 'package:tostore/tostore.dart';

/// Example embeddings with known nearest neighbors for Recall@K demos.
///
/// Consecutive [groupSize] rows share one local neighborhood. Query vectors
/// are not stored in the table.
///
/// Ultra-low-D (≤6): [usesIslandFillerLayout] — a fixed set of scorable
/// "island" groups sit in a northern cap; extra rows are southern fillers that
/// cannot enter island Top-K. Recall@K stays planted (no full-table GT) at any N.
class ExampleVectorCorpus {
  ExampleVectorCorpus._();

  /// Neighbors per group. Covers industry-standard Recall@10 with headroom.
  static const int groupSize = 16;

  /// Island+filler layout for dimensions at or below this value.
  static const int islandFillerMaxDimensions = 6;

  /// Pull island centers toward +e₀ / fillers toward −e₀ (unit-sphere cap).
  static const double _capPolePull = 0.55;

  /// Max cosine between distinct island centers (members stay below planted K).
  static const double _maxIslandCenterCosine = 0.90;

  /// Ray spacing at the 128-d calibration point (and all D≥128).
  static const double referenceRayStep = 0.16;

  /// Dimension used to calibrate [referenceRayStep].
  static const int referenceDimensions = 128;

  /// Design corpus size for the high-D random-center safety check.
  static const int designCorpusN = 10000000;

  /// Extra cosine gap required before a high-D (≥128) neighbor counts for Recall@K.
  static const double gtCosineMargin = 0.04;

  /// How many result ranks count as a top-1 / self hit.
  ///
  /// Below 48-d, neighbors in a group can be very close; a small window
  /// avoids treating near-ties as hard failures.
  static int rankWindowForDimensions(int dimensions) {
    final d = dimensions.clamp(1, 65535);
    if (d >= 48) return 1;
    if (d >= 32) return 2;
    return 3;
  }

  static bool pkInRankWindow(
    List<String> annPks,
    String pk, {
    required int window,
  }) {
    final n = min(window, annPks.length);
    for (var i = 0; i < n; i++) {
      if (annPks[i] == pk) return true;
    }
    return false;
  }

  /// Legacy alias — prefer [rayStepFor].
  static const double rayStep = referenceRayStep;

  /// Legacy alias — prefer [queryTFor].
  static const double queryT = -0.04;

  static const String labelPrefix = 'nghgt:';

  static const Set<String> stampFields = {
    'name',
    'label',
    'document_title',
    'title',
  };

  static int groupIdForIndex(int index) => (index - 1) ~/ groupSize;

  static int memberIdForIndex(int index) => (index - 1) % groupSize;

  /// Whether this dimension uses fixed islands + background fillers.
  static bool usesIslandFillerLayout(int dimensions) =>
      dimensions >= 1 && dimensions <= islandFillerMaxDimensions;

  /// Fixed count of scorable neighborhood groups (independent of corpus N).
  ///
  /// Kept small enough that greedy northern-cap packing keeps island–island
  /// cosine well below planted Top-10 (~0.998).
  static int scorableIslandCount(int dimensions) {
    final d = dimensions.clamp(1, islandFillerMaxDimensions);
    // 2D circle capacity is tiny once ray members are included.
    if (d <= 2) return 6;
    if (d <= 4) return 24;
    return 48; // 5–6D
  }

  /// Groups that may be used for planted Recall@K / island queries.
  static int scorableGroupCount({
    required int dimensions,
    required int corpusSize,
  }) {
    final total = max(0, corpusSize ~/ groupSize);
    if (!usesIslandFillerLayout(dimensions)) return total;
    return min(total, scorableIslandCount(dimensions));
  }

  /// Complete groups available for scoring after an optional non-zero start.
  static int scorableCompleteGroups({
    required int dimensions,
    required int startGroup,
    required int rawCompleteGroups,
  }) {
    if (!usesIslandFillerLayout(dimensions)) return rawCompleteGroups;
    final lim = scorableIslandCount(dimensions);
    if (startGroup >= lim || rawCompleteGroups <= 0) return 0;
    return min(rawCompleteGroups, lim - startGroup);
  }

  static bool isFillerGroup(int groupId, int dimensions) =>
      usesIslandFillerLayout(dimensions) &&
      groupId >= scorableIslandCount(dimensions);

  /// Spacing between neighbors in a group. Lower dimensions use a slightly
  /// smaller step so each group's Top-K stays closer than other groups.
  static double rayStepFor(int dimensions) {
    final d = dimensions.clamp(1, 65535);
    if (d >= referenceDimensions) return referenceRayStep;
    final step = referenceRayStep * sqrt(d / referenceDimensions);
    // Island layout: keep rays tight — fillers are capped away in the south.
    if (usesIslandFillerLayout(d)) {
      // Tighter than mid-D: island members must beat adjacent-island rays.
      return min(step, d <= 2 ? 0.008 : 0.012);
    }
    if (d <= 8) return min(step, 0.020);
    return step.clamp(0.08, referenceRayStep);
  }

  /// Query offset on the group ray (`-rayStep/4`, same ratio as legacy).
  static double queryTFor(int dimensions) => -rayStepFor(dimensions) / 4.0;

  static double memberT(int memberId, [int dimensions = referenceDimensions]) =>
      (memberId - (groupSize - 1) / 2.0) * rayStepFor(dimensions);

  /// Cosine between query and member on the unit-sphere ray model.
  static double plantedCosine(int memberId, int dimensions) {
    final t = memberT(memberId, dimensions);
    final q = queryTFor(dimensions);
    return (1.0 + q * t) / (sqrt(1.0 + q * q) * sqrt(1.0 + t * t));
  }

  /// Approx max cosine among [corpusSize] random unit vectors in [dimensions].
  ///
  /// Uses N(0, 1/d) tail quantile Φ^{-1}(1-1/N)/√d — good mid/high-D gate.
  /// Near 1.0 the Gaussian model is crude; callers still treat D≲16 multi-100k
  /// as packing-only when [maxReliableRecallK] returns 0.
  static double approxRandomMaxCosine(int dimensions, int corpusSize) {
    final d = max(1, dimensions);
    final n = max(2, corpusSize);
    final z = _invNormApprox(1.0 - 1.0 / n);
    return min(0.9995, z / sqrt(d.toDouble()));
  }

  /// Largest K that the example generator can still score fairly.
  ///
  /// Uses a foreign-center cosine floor: planted neighbors must stay clearly
  /// closer than typical nearest other-group centers (low-D packing) or the
  /// random-sphere envelope (D≥128). Returns 0 when even Top-1 is ambiguous.
  static int maxReliableRecallK({
    required int dimensions,
    required int corpusSize,
    int wantK = 10,
  }) {
    final limit = min(wantK, groupSize);
    // Island+filler: scorable neighborhoods stay unambiguous at any N.
    if (usesIslandFillerLayout(dimensions)) {
      if (scorableGroupCount(
            dimensions: dimensions,
            corpusSize: corpusSize,
          ) <=
          0) {
        return 0;
      }
      return limit;
    }
    final groups = max(1, corpusSize ~/ groupSize);
    final foreign = dimensions < referenceDimensions
        ? approxNearestForeignCenterCosine(dimensions, groups)
        : approxRandomMaxCosine(dimensions, corpusSize);
    final double gap;
    if (dimensions < referenceDimensions) {
      // 1 - cos(center, outermost member) on the unit-sphere ray model.
      final tOuter = (groupSize - 1) / 2.0 * rayStepFor(dimensions);
      final shell = 1.0 - 1.0 / sqrt(1.0 + tOuter * tOuter);
      gap = max(
        shell + 0.002,
        max(0.002, min(gtCosineMargin, (1.0 - foreign) * 0.75)),
      );
    } else {
      gap = gtCosineMargin;
    }
    // Do not early-out on foreign+gap≥1 — floor is clamped below; let the
    // planted loop decide (avoids 4D@70k→n/a while Top-3 is still fair).
    if (foreign >= 0.9999) return 0;
    final floor = min(0.9998, foreign + gap);
    final members = neighborMemberIds(dimensions);
    var k = 0;
    for (var i = 0; i < limit; i++) {
      if (plantedCosine(members[i], dimensions) <= floor) break;
      k = i + 1;
    }
    return k;
  }

  /// Typical nearest-other-group center cosine for the separated packing.
  ///
  static double approxNearestForeignCenterCosine(int dimensions, int groups) {
    final d = max(1, dimensions);
    final g = max(1, groups);
    if (g <= 1) return -1.0;
    if (d == 2) {
      // Weyl/golden circle ≈ uniform; nearest gap ~ 2π/G.
      return cos(2 * pi / g);
    }
    final probes = min(48, g);
    final catalog = min(g, 4096);
    var sum = 0.0;
    for (var p = 0; p < probes; p++) {
      final gid = (p * 9973) % g;
      final center = _separatedCenter(gid, d);
      var best = -2.0;
      final stride = max(1, g ~/ catalog);
      for (var h = 0; h < catalog; h++) {
        final other = (gid + 1 + h * stride) % g;
        if (other == gid) continue;
        final o = _separatedCenter(other, d);
        var dot = 0.0;
        for (var i = 0; i < d; i++) {
          dot += center[i] * o[i];
        }
        if (dot > best) best = dot;
      }
      sum += best;
    }
    return sum / probes;
  }

  /// Beasley-Springer-Moro inverse normal CDF (for GT envelope only).
  static double _invNormApprox(double p) {
    const a = <double>[
      -3.969683028665376e+01,
      2.209460984245205e+02,
      -2.759285104469687e+02,
      1.383577518672690e+02,
      -3.066479806614716e+01,
      2.506628277459239e+00,
    ];
    const b = <double>[
      -5.447609879822406e+01,
      1.615858368580409e+02,
      -1.556989798598866e+02,
      6.680131188771972e+01,
      -1.328068155288572e+01,
    ];
    const c = <double>[
      -7.784894002430293e-03,
      -3.223964580411365e-01,
      -2.400758277161838e+00,
      -2.549732539343734e+00,
      4.374664141464968e+00,
      2.938163982698783e+00,
    ];
    const dCoef = <double>[
      7.784695709041462e-03,
      3.224671290700398e-01,
      2.445134137142996e+00,
      3.754408661907416e+00,
    ];
    const plow = 0.02425;
    final phigh = 1.0 - plow;
    if (p <= 0) return -8.0;
    if (p >= 1) return 8.0;
    if (p < plow) {
      final q = sqrt(-2.0 * log(p));
      return (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q +
              c[5]) /
          ((((dCoef[0] * q + dCoef[1]) * q + dCoef[2]) * q + dCoef[3]) * q +
              1.0);
    }
    if (p > phigh) {
      final q = sqrt(-2.0 * log(1.0 - p));
      return -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q +
              c[5]) /
          ((((dCoef[0] * q + dCoef[1]) * q + dCoef[2]) * q + dCoef[3]) * q +
              1.0);
    }
    final q = p - 0.5;
    final r = q * q;
    return (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r +
            a[5]) *
        q /
        (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1.0);
  }

  static String recordLabel(int index) {
    final g = groupIdForIndex(index);
    final m = memberIdForIndex(index);
    return '$labelPrefix'
        'g${g.toString().padLeft(8, '0')}:'
        'm${m.toString().padLeft(2, '0')}';
  }

  static bool isExampleLabel(String? value) => indexFromLabel(value) != null;

  /// 1-based generation index stamped in [recordLabel], or null.
  ///
  /// Batch-insert rounds and appends do not always start at index 1.
  /// Recall@K uses this stamp instead of assuming the minimum primary key
  /// is generation index 1.
  static int? indexFromLabel(String? value) {
    if (value == null || !value.startsWith(labelPrefix)) return null;
    final body = value.substring(labelPrefix.length);
    final sep = body.indexOf(':m');
    if (sep < 2 || !body.startsWith('g')) return null;
    final groupId = int.tryParse(body.substring(1, sep));
    final memberId = int.tryParse(body.substring(sep + 2));
    if (groupId == null || memberId == null) return null;
    if (groupId < 0 || memberId < 0 || memberId >= groupSize) return null;
    return groupId * groupSize + memberId + 1;
  }

  static String? labelFieldName(TableSchema schema) {
    for (final name in stampFields) {
      for (final field in schema.fields) {
        if (field.name == name && field.type == DataType.text) {
          return field.name;
        }
      }
    }
    return null;
  }

  /// Member ids nearest to the query first (unique nearest neighbor at member 7).
  /// Sorted by true ray-cosine (not |t−q|); ranks 13–14 can differ from |t−q|.
  static List<int> neighborMemberIds([int dimensions = referenceDimensions]) {
    final ids = List<int>.generate(groupSize, (m) => m);
    ids.sort((a, b) {
      final c =
          plantedCosine(b, dimensions).compareTo(plantedCosine(a, dimensions));
      if (c != 0) return c;
      return a.compareTo(b);
    });
    return ids;
  }

  static VectorData memberVector({
    required int index,
    required int dimensions,
  }) {
    final groupId = groupIdForIndex(index);
    if (isFillerGroup(groupId, dimensions)) {
      return VectorData(_fillerVector(index, dimensions));
    }
    final memberId = memberIdForIndex(index);
    final (center, dir) = _cachedFrame(groupId, dimensions);
    final t = memberT(memberId, dimensions);
    final values = List<double>.generate(
      dimensions,
      (d) => center[d] + t * dir[d],
    );
    _normalizeInPlace(values);
    return VectorData(values);
  }

  /// Query for [groupId]: off-center on the group ray (not stored).
  ///
  /// For island layouts, prefer [groupId] &lt; [scorableIslandCount]; filler
  /// group ids still produce a deterministic vector but are not Recall GT.
  static VectorData groupQuery(int groupId, int dimensions) {
    if (isFillerGroup(groupId, dimensions)) {
      // Deterministic probe near the filler dump (throughput only).
      return VectorData(_fillerVector(
        groupId * groupSize + 1,
        dimensions,
      ));
    }
    final (center, dir) = _cachedFrame(groupId, dimensions);
    final q = queryTFor(dimensions);
    final values = List<double>.generate(
      dimensions,
      (d) => center[d] + q * dir[d],
    );
    _normalizeInPlace(values);
    return VectorData(values);
  }

  /// Sequential dense PKs.
  ///
  /// Generation index `i` (1-based) maps to `minPk + i - originIndex`.
  /// [originIndex] is the generation index stored on the minimum primary key.
  static String pkForMember({
    required int minPk,
    required int groupId,
    required int memberId,
    int originIndex = 1,
  }) {
    final index = groupId * groupSize + memberId + 1;
    return (minPk + index - originIndex).toString();
  }

  static List<String> expectedPks({
    required int minPk,
    required int groupId,
    required int k,
    int originIndex = 1,
    int dimensions = referenceDimensions,
  }) {
    final members = neighborMemberIds(dimensions);
    final n = min(k, members.length);
    return [
      for (var i = 0; i < n; i++)
        pkForMember(
          minPk: minPk,
          groupId: groupId,
          memberId: members[i],
          originIndex: originIndex,
        ),
    ];
  }

  /// Last orthonormal frame. Sequential inserts reuse one frame per group
  /// (16 members), so bulk generation does not redo the Gaussian basis.
  static int? _cachedFrameGroup;
  static int? _cachedFrameDims;
  static List<double>? _cachedCenter;
  static List<double>? _cachedDir;

  static (List<double>, List<double>) _cachedFrame(
    int groupId,
    int dimensions,
  ) {
    final center = _cachedCenter;
    final dir = _cachedDir;
    if (center != null &&
        dir != null &&
        _cachedFrameGroup == groupId &&
        _cachedFrameDims == dimensions) {
      return (center, dir);
    }
    final frame = _frame(groupId, dimensions);
    _cachedFrameGroup = groupId;
    _cachedFrameDims = dimensions;
    _cachedCenter = frame.$1;
    _cachedDir = frame.$2;
    return frame;
  }

  static (List<double>, List<double>) _frame(int groupId, int dimensions) {
    final rng = Random(groupId * 10007 + dimensions);
    final center = dimensions < referenceDimensions
        ? _separatedCenter(groupId, dimensions)
        : _gaussianCenter(rng, dimensions);
    final dir = _gaussian(rng, dimensions);
    var dot = 0.0;
    for (var i = 0; i < dimensions; i++) {
      dot += center[i] * dir[i];
    }
    for (var i = 0; i < dimensions; i++) {
      dir[i] -= dot * center[i];
    }
    var nSq = 0.0;
    for (final x in dir) {
      nSq += x * x;
    }
    if (nSq < 1e-12) {
      for (var i = 0; i < dimensions; i++) {
        dir[i] = i == 0 ? 1.0 : 0.0;
      }
      var d2 = 0.0;
      for (var i = 0; i < dimensions; i++) {
        d2 += center[i] * dir[i];
      }
      for (var i = 0; i < dimensions; i++) {
        dir[i] -= d2 * center[i];
      }
      nSq = 0.0;
      for (final x in dir) {
        nSq += x * x;
      }
    }
    if (nSq < 1e-12) {
      // Still no tangent (e.g. D=1): leave a unit fallback without /0 → NaN.
      for (var i = 0; i < dimensions; i++) {
        dir[i] = i == 0 ? 1.0 : 0.0;
      }
      return (center, dir);
    }
    final n = sqrt(nSq);
    for (var i = 0; i < dimensions; i++) {
      dir[i] /= n;
    }
    return (center, dir);
  }

  static List<double> _gaussianCenter(Random rng, int dimensions) {
    final center = _gaussian(rng, dimensions);
    _normalizeInPlace(center);
    return center;
  }

  /// Spread-out neighborhood centers below 128-d so demo groups do not overlap.
  ///
  /// D≤6: northern-cap islands ([_islandCenter]). D=7–8: full-sphere Weyl.
  /// From 16-d: one main axis plus a little side noise.
  static List<double> _separatedCenter(int groupId, int dimensions) {
    final d = max(1, dimensions);
    if (usesIslandFillerLayout(d)) {
      return _islandCenter(groupId, d);
    }
    if (d <= 8) {
      return _weylSphereCenter(groupId, d);
    }
    final out = List<double>.filled(d, 0.0);
    final axis = groupId % d;
    final sub = groupId ~/ d;
    out[axis] = 1.0;
    final alpha = d < 16 ? 1.15 : 0.75;
    final noiseRng = Random(sub * 99991 + d * 17 + axis);
    final noise = _gaussian(noiseRng, d);
    noise[axis] = 0.0;
    var nSq = 0.0;
    for (final x in noise) {
      nSq += x * x;
    }
    if (nSq > 1e-12) {
      final inv = 1.0 / sqrt(nSq);
      for (var i = 0; i < d; i++) {
        out[i] += alpha * noise[i] * inv;
      }
    } else {
      out[(axis + 1) % d] += alpha;
    }
    _normalizeInPlace(out);
    return out;
  }

  static final Map<int, List<List<double>>> _islandCentersByDim = {};

  /// Scorable island center in the northern cap (+e₀), greedily separated.
  static List<double> _islandCenter(int groupId, int d) {
    final all = _islandCentersCached(d);
    return List<double>.from(all[groupId % all.length]);
  }

  static List<List<double>> _islandCentersCached(int d) {
    final cached = _islandCentersByDim[d];
    if (cached != null) return cached;
    final want = scorableIslandCount(d);
    final chosen = <List<double>>[];
    if (d == 2) {
      // Even arc — keep half-width small so adjacent centers stay ≪ planted K.
      const alpha = 0.50; // rad; south arc remains for fillers
      for (var g = 0; g < want; g++) {
        final t = want <= 1 ? 0.0 : (g / (want - 1)) * 2 * alpha - alpha;
        chosen.add([cos(t), sin(t)]);
      }
    } else {
      var cand = 0;
      while (chosen.length < want && cand < want * 400) {
        final v = _northCapCandidate(cand, d);
        cand++;
        var ok = true;
        for (final c in chosen) {
          var s = 0.0;
          for (var i = 0; i < d; i++) {
            s += v[i] * c[i];
          }
          if (s > _maxIslandCenterCosine) {
            ok = false;
            break;
          }
        }
        if (ok) chosen.add(v);
      }
      // Pad if the cap could not fit [want] (should not happen at current S).
      while (chosen.length < want) {
        chosen.add(_northCapCandidate(chosen.length + 9000, d));
      }
    }
    _islandCentersByDim[d] = chosen;
    return chosen;
  }

  static List<double> _northCapCandidate(int seed, int d) {
    final v = _weylSphereCenter(seed, d);
    if (v[0] < 0) {
      for (var i = 0; i < d; i++) {
        v[i] = -v[i];
      }
    }
    v[0] += _capPolePull;
    _normalizeInPlace(v);
    return v;
  }

  /// Background filler: southern cap (−e₀), O(D) — no scan over islands.
  static List<double> _fillerVector(int index, int dimensions) {
    final d = max(1, dimensions);
    final v = _weylSphereCenter(index + 7919, d);
    if (v[0] > 0) {
      for (var i = 0; i < d; i++) {
        v[i] = -v[i];
      }
    }
    v[0] -= _capPolePull;
    final rng = Random(index * 100003 + d * 17);
    final noise = _gaussian(rng, d);
    const jitter = 0.06;
    for (var i = 0; i < d; i++) {
      v[i] += jitter * noise[i];
    }
    _normalizeInPlace(v);
    return v;
  }

  /// Deterministic well-spaced unit vector for ultra-low-D demo groups.
  static List<double> _weylSphereCenter(int groupId, int d) {
    final out = List<double>.filled(d, 0.0);
    if (d == 2) {
      // Golden-angle circle — optimal packing on S^1.
      final theta = 2 * pi * _weylUnit(groupId, 0);
      out[0] = cos(theta);
      out[1] = sin(theta);
      return out;
    }
    // Weyl → inverse-normal coordinates, then project to S^{d-1}.
    for (var i = 0; i < d; i++) {
      out[i] = _invNormApprox(_weylUnit(groupId, i).clamp(1e-6, 1.0 - 1e-6));
    }
    _normalizeInPlace(out);
    return out;
  }

  /// Irrational Weyl sequence in [0, 1). Distinct alphas per axis.
  static double _weylUnit(int groupId, int axis) {
    // Plastic/golden-family irrationals; axis offset avoids diagonal collapse.
    const alphas = <double>[
      0.618033988749895,
      0.414213562373095,
      0.732050807568877,
      0.236067977499790,
      0.645751311064591,
      0.316624790355400,
      0.872983091405302,
      0.123105625617661,
    ];
    final a = alphas[axis % alphas.length];
    final u = (groupId + 1) * a;
    return u - u.floorToDouble();
  }

  static List<double> _gaussian(Random rng, int dimensions) {
    return List<double>.generate(dimensions, (_) {
      final u1 = rng.nextDouble().clamp(1e-10, 1.0);
      final u2 = rng.nextDouble();
      return sqrt(-2.0 * log(u1)) * cos(2.0 * pi * u2);
    });
  }

  static void _normalizeInPlace(List<double> values) {
    var nSq = 0.0;
    for (final v in values) {
      nSq += v * v;
    }
    final n = sqrt(nSq);
    if (n <= 0) return;
    for (var i = 0; i < values.length; i++) {
      values[i] /= n;
    }
  }
}

/// Recall@K harness for the example vector tables.
class VectorRecallHarness {
  VectorRecallHarness._();

  static int normalizeDepth(int? searchDepth) {
    final raw = searchDepth ?? VectorIndexConfig.defaultSearchDepth;
    return raw < 1 ? VectorIndexConfig.defaultSearchDepth : raw;
  }

  /// Short suite-table cell with measured Recall@K.
  static String suiteHighlight({
    required bool canScore,
    required double recallFraction,
    required int searchDepth,
  }) {
    if (!canScore) return 'n/a';
    return '${(recallFraction * 100).toStringAsFixed(0)}% @ $searchDepth';
  }

  static const int maxRecallQueries = 200;
  static const int maxIdentityProbes = 32;

  static int resolveQueryCount({
    required int requested,
    required int completeGroups,
  }) {
    if (requested <= 0 || completeGroups <= 0) return 0;
    return min(requested, min(maxRecallQueries, completeGroups));
  }

  /// Fraction of the K known neighbors that appear in the search result.
  static double overlapRecall({
    required List<String> annPks,
    required Set<String> gtPks,
    required int k,
  }) {
    if (k <= 0) return 0;
    var hits = 0;
    final n = min(k, annPks.length);
    for (var i = 0; i < n; i++) {
      if (gtPks.contains(annPks[i])) hits++;
    }
    return hits / k;
  }

  /// Score Recall@K at [searchDepth], then measure ANN latency.
  static Future<VectorRecallReport?> evaluate({
    required ToStore db,
    required String tableName,
    required int topK,
    required int searchDepth,
    required int requestedQueries,
    int querySeedOffset = 0,
    bool runIdentityDiagnostic = true,
    Future<void> Function()? yieldUi,
    void Function(String message)? onLog,
  }) async {
    final schema = await db.getTableSchema(tableName);
    if (schema == null) {
      onLog?.call('Recall failed: schema for "$tableName" not found.');
      return null;
    }

    FieldSchema? vectorField;
    for (final field in schema.fields) {
      if (field.type == DataType.vector) {
        vectorField = field;
        break;
      }
    }
    if (vectorField == null || vectorField.name.isEmpty) {
      onLog?.call('Recall failed: no vector field in "$tableName".');
      return null;
    }

    final dims = vectorField.vectorConfig?.dimensions ?? 0;
    if (dims <= 0) {
      onLog?.call(
          'Recall failed: vector dimensions not configured for "${vectorField.name}".');
      return null;
    }

    IndexSchema? vectorIndex;
    for (final idx in schema.indexes) {
      if (idx.type == IndexType.vector &&
          idx.fields.contains(vectorField.name)) {
        vectorIndex = idx;
        break;
      }
    }
    if (vectorIndex == null) {
      onLog?.call(
        'Warning: no vector index on "${vectorField.name}". '
        'Search will be slower and Recall@K will be low.',
      );
    }
    final metric = vectorIndex?.vectorConfig?.distanceMetric ??
        VectorDistanceMetric.cosine;

    final pkName = schema.primaryKeyConfig.name;
    final setupSw = Stopwatch()..start();
    final corpusSize = await db.query(tableName).count();
    if (corpusSize <= 0) {
      onLog?.call('Recall failed: table "$tableName" is empty.');
      return null;
    }

    final depth = normalizeDepth(searchDepth);
    final isSequentialPk =
        schema.primaryKeyConfig.type == PrimaryKeyType.sequential;

    int? minPk;
    int? maxPk;
    bool hasPkHoles = false;
    if (isSequentialPk) {
      final minRes = await db
          .query(tableName)
          .orderByAsc(pkName)
          .select([pkName]).limit(1);
      final maxRes = await db
          .query(tableName)
          .orderByDesc(pkName)
          .select([pkName]).limit(1);
      minPk = int.tryParse(
          (minRes.data.isEmpty ? null : minRes.data.first[pkName])
                  ?.toString() ??
              '');
      maxPk = int.tryParse(
          (maxRes.data.isEmpty ? null : maxRes.data.first[pkName])
                  ?.toString() ??
              '');
      if (minPk != null && maxPk != null && (maxPk - minPk + 1) != corpusSize) {
        hasPkHoles = true;
      }
    }

    // Stamped example rows (nghgt:g########:m##). The minimum PK is not
    // required to be generation index 1: vector batch-insert rounds use a
    // seed offset, and clear() restarts sequential ids at 1. Generation
    // index i maps to minPk + (i - originIndex). A mismatched end stamp
    // means the span is not one contiguous example corpus.
    int? originIndex;
    final labelField = ExampleVectorCorpus.labelFieldName(schema);
    if (isSequentialPk &&
        minPk != null &&
        maxPk != null &&
        labelField != null) {
      final probe = await db
          .query(tableName)
          .where(pkName, '=', minPk.toString())
          .select([labelField]).limit(1);
      final label =
          probe.data.isEmpty ? null : probe.data.first[labelField]?.toString();
      originIndex = ExampleVectorCorpus.indexFromLabel(label);
      if (originIndex != null && !hasPkHoles) {
        final endProbe = await db
            .query(tableName)
            .where(pkName, '=', maxPk.toString())
            .select([labelField]).limit(1);
        final endLabel = endProbe.data.isEmpty
            ? null
            : endProbe.data.first[labelField]?.toString();
        if (endLabel !=
            ExampleVectorCorpus.recordLabel(originIndex + corpusSize - 1)) {
          originIndex = null;
        }
      }
      // Holes plus a partial first group make PK ranges ambiguous.
      if (originIndex != null &&
          hasPkHoles &&
          ExampleVectorCorpus.memberIdForIndex(originIndex) != 0) {
        originIndex = null;
      }
    }

    if (originIndex == null) {
      onLog?.call(
        'Notice: "$tableName" does not have example vector data for Recall@K. '
        'Measuring latency and Self-Recall only.',
      );
      return _latencyFallback(
        db: db,
        tableName: tableName,
        pkName: pkName,
        vectorFieldName: vectorField.name,
        dims: dims,
        metric: metric,
        topK: topK,
        depth: depth,
        requestedQueries: requestedQueries,
        corpusSize: corpusSize,
        isSequentialPk: isSequentialPk,
        minPk: minPk,
        maxPk: maxPk,
        setupSw: setupSw,
        querySeedOffset: querySeedOffset,
        runIdentityDiagnostic: runIdentityDiagnostic,
        yieldUi: yieldUi,
        onLog: onLog,
      );
    }

    final originPk = minPk!;
    final stampedOrigin = originIndex;
    final originMember = ExampleVectorCorpus.memberIdForIndex(stampedOrigin);
    final lastIndex = hasPkHoles ? null : stampedOrigin + corpusSize - 1;
    final firstComplete = originMember == 0
        ? stampedOrigin
        : stampedOrigin + (ExampleVectorCorpus.groupSize - originMember);
    final lastComplete = lastIndex == null
        ? null
        : (lastIndex % ExampleVectorCorpus.groupSize == 0
            ? lastIndex
            : lastIndex - (lastIndex % ExampleVectorCorpus.groupSize));
    final rawCompleteGroupCount = hasPkHoles
        ? min(
            corpusSize ~/ ExampleVectorCorpus.groupSize,
            (maxPk! - originPk + 1) ~/ ExampleVectorCorpus.groupSize,
          )
        : (lastComplete == null || lastComplete < firstComplete
            ? 0
            : (lastComplete - firstComplete + 1) ~/
                ExampleVectorCorpus.groupSize);
    final startGroup = ExampleVectorCorpus.groupIdForIndex(firstComplete);
    final completeGroupCount = ExampleVectorCorpus.scorableCompleteGroups(
      dimensions: dims,
      startGroup: startGroup,
      rawCompleteGroups: rawCompleteGroupCount,
    );
    if (completeGroupCount <= 0) {
      onLog?.call(
        'Recall failed: need at least ${ExampleVectorCorpus.groupSize} vectors '
        'to measure Recall@K.',
      );
      return null;
    }

    if (hasPkHoles) {
      onLog?.call(
        'Notice: some rows are missing from this table. '
        'Checking remaining data before scoring Recall@K...',
      );
    }

    if (ExampleVectorCorpus.usesIslandFillerLayout(dims) &&
        rawCompleteGroupCount > completeGroupCount) {
      onLog?.call(
        'Notice: ${dims}D island layout — scoring $completeGroupCount '
        'planted islands; '
        '${rawCompleteGroupCount - completeGroupCount} filler groups '
        'are background only (Recall@K stays planted at any N).',
      );
    }

    final reliableK = ExampleVectorCorpus.maxReliableRecallK(
      dimensions: dims,
      corpusSize: corpusSize,
      wantK: min(topK, ExampleVectorCorpus.groupSize),
    );
    if (reliableK <= 0) {
      onLog?.call(
        'Notice: Recall@K scoring is skipped for ${dims}D @ N=$corpusSize — '
        'example groups are not distinct enough at this size. '
        'Measuring latency and Self-Recall only. '
        'Clear and re-insert this table if you generated it with an older example.',
      );
      return _latencyFallback(
        db: db,
        tableName: tableName,
        pkName: pkName,
        vectorFieldName: vectorField.name,
        dims: dims,
        metric: metric,
        topK: topK,
        depth: depth,
        requestedQueries: requestedQueries,
        corpusSize: corpusSize,
        isSequentialPk: isSequentialPk,
        minPk: minPk,
        maxPk: maxPk,
        setupSw: setupSw,
        querySeedOffset: querySeedOffset,
        runIdentityDiagnostic: runIdentityDiagnostic,
        yieldUi: yieldUi,
        onLog: onLog,
      );
    }
    final recallK = reliableK;
    if (recallK < topK) {
      onLog?.call(
        'Notice: scoring Recall@$recallK (not @$topK) — at ${dims}D / N=$corpusSize '
        'only the first $recallK known neighbors stay unambiguous.',
      );
    }
    final queryCount = resolveQueryCount(
      requested: requestedQueries,
      completeGroups: completeGroupCount,
    );
    if (queryCount <= 0 || recallK <= 0) {
      onLog?.call('Recall failed: nothing to evaluate.');
      return null;
    }

    final rng = Random(6262 + querySeedOffset);
    final groupIds = <int>{};
    int attempts = 0;
    final maxAttempts = queryCount * 5;

    while (groupIds.length < queryCount && attempts < maxAttempts) {
      attempts++;
      final candidateGroup = startGroup + rng.nextInt(completeGroupCount);
      if (groupIds.contains(candidateGroup)) continue;

      if (hasPkHoles) {
        // Light check to ensure the sampled group has all 16 members.
        final groupStartPk = int.parse(ExampleVectorCorpus.pkForMember(
          minPk: originPk,
          groupId: candidateGroup,
          memberId: 0,
          originIndex: stampedOrigin,
        ));
        final groupEndPk = groupStartPk + ExampleVectorCorpus.groupSize - 1;
        final memberCount = await db
            .query(tableName)
            .where(pkName, '>=', groupStartPk.toString())
            .where(pkName, '<=', groupEndPk.toString())
            .count();
        if (memberCount != ExampleVectorCorpus.groupSize) {
          continue; // Skip damaged group
        }
      }
      groupIds.add(candidateGroup);
    }

    final groups = groupIds.toList(growable: false);
    if (groups.isEmpty) {
      onLog?.call(
        'Notice: not enough matching data remains to score Recall@K. '
        'Measuring latency and Self-Recall only.',
      );
      return _latencyFallback(
        db: db,
        tableName: tableName,
        pkName: pkName,
        vectorFieldName: vectorField.name,
        dims: dims,
        metric: metric,
        topK: topK,
        depth: depth,
        requestedQueries: requestedQueries,
        corpusSize: corpusSize,
        isSequentialPk: isSequentialPk,
        minPk: minPk,
        maxPk: maxPk,
        setupSw: setupSw,
        querySeedOffset: querySeedOffset,
        runIdentityDiagnostic: runIdentityDiagnostic,
        yieldUi: yieldUi,
        onLog: onLog,
      );
    }

    final queries = [
      for (final g in groups) ExampleVectorCorpus.groupQuery(g, dims),
    ];
    setupSw.stop();

    final rankWindow = ExampleVectorCorpus.rankWindowForDimensions(dims);
    onLog?.call(
      'Scoring Recall@$recallK on ${groups.length} queries '
      '($corpusSize vectors, ${dims}D ${metric.name}'
      '${rankWindow > 1 ? ', top1/self window=top$rankWindow' : ''})...',
    );

    final annLatenciesMs = <double>[];
    var neighborHits = 0;
    var top1Hits = 0;
    final perQueryRecall = <double>[];
    final searchTopK = max(topK, rankWindow);

    for (var i = 0; i < groups.length; i++) {
      final querySw = Stopwatch()..start();
      final results = await db.vectorSearch(
        tableName,
        fieldName: vectorField.name,
        queryVector: queries[i],
        topK: searchTopK,
        searchDepth: depth,
      );
      querySw.stop();
      annLatenciesMs.add(querySw.elapsedMicroseconds / 1000.0);

      final annPks = [for (final r in results) r.primaryKey];
      final gtPks = ExampleVectorCorpus.expectedPks(
        minPk: originPk,
        groupId: groups[i],
        k: recallK,
        originIndex: stampedOrigin,
        dimensions: dims,
      );
      final gtSet = gtPks.toSet();
      var hits = 0;
      final nAnn = min(topK, annPks.length);
      for (var r = 0; r < nAnn; r++) {
        if (gtSet.contains(annPks[r])) hits++;
      }
      neighborHits += hits;
      perQueryRecall.add(
        overlapRecall(annPks: annPks, gtPks: gtSet, k: recallK),
      );

      if (gtPks.isNotEmpty &&
          ExampleVectorCorpus.pkInRankWindow(
            annPks,
            gtPks.first,
            window: rankWindow,
          )) {
        top1Hits++;
      }

      if (groups.length >= 20 &&
          (i + 1) % max(1, groups.length ~/ 5) == 0 &&
          (i + 1) < groups.length) {
        onLog?.call('⏳ Recall@K: ${i + 1}/${groups.length}...');
        await yieldUi?.call();
      }
    }

    var identityHits = 0;
    var identityProbes = 0;
    final identityLatenciesMs = <double>[];
    if (runIdentityDiagnostic) {
      identityProbes = min(
        maxIdentityProbes,
        groups.length * ExampleVectorCorpus.groupSize,
      );
      onLog?.call(
        'Self-Recall: checking $identityProbes stored vectors'
        '${rankWindow > 1 ? ' (hit if PK in top$rankWindow)' : ''}...',
      );
      final idRng = Random(4242 + querySeedOffset);
      for (var i = 0; i < identityProbes; i++) {
        late final int groupId;
        late final int memberId;
        if (hasPkHoles) {
          groupId = groups[idRng.nextInt(groups.length)];
          memberId = idRng.nextInt(ExampleVectorCorpus.groupSize);
        } else {
          final index = stampedOrigin + idRng.nextInt(corpusSize);
          groupId = ExampleVectorCorpus.groupIdForIndex(index);
          memberId = ExampleVectorCorpus.memberIdForIndex(index);
        }
        final vec = ExampleVectorCorpus.memberVector(
          index: groupId * ExampleVectorCorpus.groupSize + memberId + 1,
          dimensions: dims,
        );
        final pk = ExampleVectorCorpus.pkForMember(
          minPk: originPk,
          groupId: groupId,
          memberId: memberId,
          originIndex: stampedOrigin,
        );
        final querySw = Stopwatch()..start();
        final results = await db.vectorSearch(
          tableName,
          fieldName: vectorField.name,
          queryVector: vec,
          topK: max(rankWindow, topK),
          searchDepth: depth,
        );
        querySw.stop();
        identityLatenciesMs.add(querySw.elapsedMicroseconds / 1000.0);
        final annPks = [for (final r in results) r.primaryKey];
        if (ExampleVectorCorpus.pkInRankWindow(
          annPks,
          pk,
          window: rankWindow,
        )) {
          identityHits++;
        }
      }
    }

    final evalQueryCount = groups.length;
    final recallAtK = evalQueryCount == 0
        ? 0.0
        : perQueryRecall.reduce((a, b) => a + b) / evalQueryCount;

    return VectorRecallReport(
      tableName: tableName,
      corpusSize: corpusSize,
      dimensions: dims,
      metric: metric,
      topK: recallK,
      requestedTopK: topK,
      searchDepth: depth,
      queryCount: evalQueryCount,
      requestedQueries: requestedQueries,
      recallAtK: recallAtK,
      top1HitRate: evalQueryCount == 0 ? 0.0 : top1Hits / evalQueryCount,
      neighborHits: neighborHits,
      neighborPossible: evalQueryCount * recallK,
      identityAt1: identityProbes == 0 ? null : identityHits / identityProbes,
      identityProbes: identityProbes,
      identityHits: identityHits,
      annLatenciesMs: annLatenciesMs,
      identityLatenciesMs: identityLatenciesMs,
      gtElapsedMs: setupSw.elapsedMilliseconds,
      queryVectors: queries,
      canScoreRecall: true,
      completeGroups: completeGroupCount,
    );
  }

  static VectorData? _vectorFromRaw(dynamic raw) {
    if (raw is VectorData) return raw;
    if (raw is Float32List) return VectorData(raw);
    if (raw is Float64List) {
      return VectorData(List<double>.from(raw, growable: false));
    }
    if (raw is Iterable) {
      final list = <double>[];
      for (final n in raw) {
        if (n is! num) return null;
        list.add(n.toDouble());
      }
      return VectorData(list);
    }
    return null;
  }

  static Future<VectorRecallReport> _latencyFallback({
    required ToStore db,
    required String tableName,
    required String pkName,
    required String vectorFieldName,
    required int dims,
    required VectorDistanceMetric metric,
    required int topK,
    required int depth,
    required int requestedQueries,
    required int corpusSize,
    required bool isSequentialPk,
    required int? minPk,
    required int? maxPk,
    required Stopwatch setupSw,
    required int querySeedOffset,
    required bool runIdentityDiagnostic,
    required Future<void> Function()? yieldUi,
    required void Function(String message)? onLog,
  }) async {
    final want = min(requestedQueries, maxRecallQueries);
    final rng = Random(querySeedOffset + 101);
    final sampleDocs = <Map<String, dynamic>>[];

    if (isSequentialPk && minPk != null && maxPk != null && maxPk >= minPk) {
      final span = maxPk - minPk + 1;
      var tries = 0;
      while (sampleDocs.length < want && tries < want * 8) {
        tries++;
        final pk = minPk + rng.nextInt(span);
        final res = await db
            .query(tableName)
            .where(pkName, '=', pk.toString())
            .select([pkName, vectorFieldName]).limit(1);
        if (res.data.isNotEmpty) {
          sampleDocs.add(res.data.first);
        }
      }
    } else {
      sampleDocs.addAll((await db
              .query(tableName)
              .select([pkName, vectorFieldName]).limit(want))
          .data);
    }

    final sampleQueries = <VectorData>[];
    for (final doc in sampleDocs) {
      final v = _vectorFromRaw(doc[vectorFieldName]);
      if (v != null) sampleQueries.add(v);
    }
    while (sampleQueries.length < want) {
      final g = List<double>.generate(dims, (_) {
        final u1 = rng.nextDouble().clamp(1e-10, 1.0);
        final u2 = rng.nextDouble();
        return sqrt(-2.0 * log(u1)) * cos(2.0 * pi * u2);
      });
      var nSq = 0.0;
      for (final x in g) {
        nSq += x * x;
      }
      final n = sqrt(nSq);
      if (n > 0) {
        for (var j = 0; j < dims; j++) {
          g[j] /= n;
        }
      }
      sampleQueries.add(VectorData(g));
    }

    setupSw.stop();
    final annLatenciesMs = <double>[];
    for (var i = 0; i < sampleQueries.length; i++) {
      final querySw = Stopwatch()..start();
      await db.vectorSearch(
        tableName,
        fieldName: vectorFieldName,
        queryVector: sampleQueries[i],
        topK: topK,
        searchDepth: depth,
      );
      querySw.stop();
      annLatenciesMs.add(querySw.elapsedMicroseconds / 1000.0);
      if (want >= 20 && (i + 1) % max(1, want ~/ 5) == 0 && (i + 1) < want) {
        onLog?.call('⏳ Vector searches: ${i + 1}/$want...');
        await yieldUi?.call();
      }
    }

    var identityHits = 0;
    var identityProbes = 0;
    final identityLatenciesMs = <double>[];
    if (runIdentityDiagnostic && sampleDocs.isNotEmpty) {
      final rankWindow = ExampleVectorCorpus.rankWindowForDimensions(dims);
      identityProbes = min(maxIdentityProbes, sampleDocs.length);
      for (var i = 0; i < identityProbes; i++) {
        final doc = sampleDocs[i];
        final pk = doc[pkName]?.toString();
        final v = _vectorFromRaw(doc[vectorFieldName]);
        if (v == null || pk == null) continue;
        final querySw = Stopwatch()..start();
        final results = await db.vectorSearch(
          tableName,
          fieldName: vectorFieldName,
          queryVector: v,
          topK: max(rankWindow, topK),
          searchDepth: depth,
        );
        querySw.stop();
        identityLatenciesMs.add(querySw.elapsedMicroseconds / 1000.0);
        final annPks = [for (final r in results) r.primaryKey];
        if (ExampleVectorCorpus.pkInRankWindow(
          annPks,
          pk,
          window: rankWindow,
        )) {
          identityHits++;
        }
      }
    }

    return VectorRecallReport(
      tableName: tableName,
      corpusSize: corpusSize,
      dimensions: dims,
      metric: metric,
      topK: topK,
      requestedTopK: topK,
      searchDepth: depth,
      queryCount: sampleQueries.length,
      requestedQueries: requestedQueries,
      recallAtK: 0.0,
      top1HitRate: 0.0,
      neighborHits: 0,
      neighborPossible: 0,
      identityAt1: identityProbes == 0 ? null : identityHits / identityProbes,
      identityProbes: identityProbes,
      identityHits: identityHits,
      annLatenciesMs: annLatenciesMs,
      identityLatenciesMs: identityLatenciesMs,
      gtElapsedMs: setupSw.elapsedMilliseconds,
      queryVectors: sampleQueries,
      canScoreRecall: false,
      completeGroups: 0,
    );
  }
}

class VectorRecallReport {
  final String tableName;
  final int corpusSize;
  final int dimensions;
  final VectorDistanceMetric metric;
  final int topK;
  final int requestedTopK;
  final int searchDepth;
  final int queryCount;
  final int requestedQueries;
  final double recallAtK;
  final double top1HitRate;
  final int neighborHits;
  final int neighborPossible;
  final double? identityAt1;
  final int identityProbes;
  final int identityHits;
  final List<double> annLatenciesMs;
  final List<double> identityLatenciesMs;
  final int gtElapsedMs;
  final List<VectorData> queryVectors;
  final bool canScoreRecall;
  final int completeGroups;

  const VectorRecallReport({
    required this.tableName,
    required this.corpusSize,
    required this.dimensions,
    required this.metric,
    required this.topK,
    required this.requestedTopK,
    required this.searchDepth,
    required this.queryCount,
    required this.requestedQueries,
    required this.recallAtK,
    required this.top1HitRate,
    required this.neighborHits,
    required this.neighborPossible,
    required this.identityAt1,
    required this.identityProbes,
    required this.identityHits,
    required this.annLatenciesMs,
    required this.identityLatenciesMs,
    required this.gtElapsedMs,
    required this.queryVectors,
    this.canScoreRecall = true,
    this.completeGroups = 0,
  });

  String get metricLabel => switch (metric) {
        VectorDistanceMetric.cosine => 'Cosine',
        VectorDistanceMetric.l2 => 'L2',
        VectorDistanceMetric.innerProduct => 'InnerProduct',
      };

  /// Operating-point status for suite tables. Not a recall ceiling.
  String get compactHighlight => VectorRecallHarness.suiteHighlight(
        canScore: canScoreRecall,
        recallFraction: recallAtK,
        searchDepth: searchDepth,
      );

  String get operatingPointNote {
    final where = searchDepth == VectorIndexConfig.defaultSearchDepth
        ? 'default searchDepth=$searchDepth'
        : 'searchDepth=$searchDepth';
    return '$where. Larger searchDepth typically raises recall and latency.';
  }

  String get qualityNote {
    final self = identityAt1 == null
        ? 'Self-Recall=n/a'
        : 'Self-Recall=${(identityAt1! * 100).toStringAsFixed(1)}% '
            '($identityHits/$identityProbes)';
    if (!canScoreRecall) {
      return '$operatingPointNote '
          'Recall@$topK=n/a (example vector data required); $self; queries=$queryCount; corpus=$corpusSize';
    }
    return '$operatingPointNote '
        'Recall@$topK=${(recallAtK * 100).toStringAsFixed(1)}% '
        '($neighborHits/$neighborPossible); '
        'Top-1 Hit Rate=${(top1HitRate * 100).toStringAsFixed(1)}%; '
        '$self; queries=$queryCount; corpus=$corpusSize';
  }
}

/// Standard [searchDepth] points for recall-vs-latency sweeps.
const List<int> vectorSearchDepthSweepPoints = [
  1,
  10,
  20,
  30,
  40,
  50,
  60,
  70,
  80,
  90,
  100,
];

/// Latency stats plus the underlying [VectorRecallReport].
class VectorSearchBenchmarkResult {
  final VectorRecallReport recall;
  final double avgLatencyMs;
  final double p50LatencyMs;
  final double p95LatencyMs;
  final double p99LatencyMs;
  final double qps;
  final int totalSearches;

  const VectorSearchBenchmarkResult({
    required this.recall,
    required this.avgLatencyMs,
    required this.p50LatencyMs,
    required this.p95LatencyMs,
    required this.p99LatencyMs,
    required this.qps,
    required this.totalSearches,
  });

  static VectorSearchBenchmarkResult fromLatencies({
    required VectorRecallReport recall,
    required List<double> latenciesMs,
    double? wallClockQps,
  }) {
    final sorted = List<double>.from(latenciesMs)..sort();
    final lastIdx = sorted.isEmpty ? 0 : sorted.length - 1;
    final avg =
        sorted.isEmpty ? 0.0 : sorted.reduce((a, b) => a + b) / sorted.length;
    final p50 = sorted.isEmpty
        ? 0.0
        : sorted[(sorted.length * 0.50).floor().clamp(0, lastIdx)];
    final p95 = sorted.isEmpty
        ? 0.0
        : sorted[(sorted.length * 0.95).floor().clamp(0, lastIdx)];
    final p99 = sorted.isEmpty
        ? 0.0
        : sorted[(sorted.length * 0.99).floor().clamp(0, lastIdx)];
    return VectorSearchBenchmarkResult(
      recall: recall,
      avgLatencyMs: avg,
      p50LatencyMs: p50,
      p95LatencyMs: p95,
      p99LatencyMs: p99,
      // Prefer batch wall-clock QPS (matches benchmark_runner). Fallback to
      // 1000/avg when only per-query samples are available.
      qps: wallClockQps ?? (avg > 0 ? 1000.0 / avg : 0.0),
      totalSearches: sorted.length,
    );
  }

  String _pct(double value) => '${(value * 100).toStringAsFixed(1)}%';

  String sweepTableRow() {
    final recallCol =
        recall.canScoreRecall ? _pct(recall.recallAtK).padLeft(7) : '    n/a';
    final top1Col = recall.canScoreRecall
        ? _pct(recall.top1HitRate).padLeft(8)
        : '     n/a';
    final selfCol = recall.identityAt1 == null
        ? '    n/a'
        : _pct(recall.identityAt1!).padLeft(7);
    return '${recall.searchDepth.toString().padLeft(11)} | '
        '$recallCol | '
        '$top1Col | '
        '$selfCol | '
        '${avgLatencyMs.toStringAsFixed(2).padLeft(6)} | '
        '${p95LatencyMs.toStringAsFixed(2).padLeft(6)} | '
        '${qps.toStringAsFixed(0).padLeft(4)}';
  }
}

/// One compact log block for a multi-depth recall sweep (easy to copy).
String formatVectorDepthSweepSummary({
  required String tableName,
  required int topK,
  required int iterations,
  required List<VectorSearchBenchmarkResult> rows,
  bool diverseThroughput = false,
}) {
  if (rows.isEmpty) {
    return '[Vector Depth Sweep] No results.';
  }

  final first = rows.first.recall;
  final canScore = rows.any((r) => r.recall.canScoreRecall);
  final depths = rows.map((r) => r.recall.searchDepth).join(',');
  // Scored K can be below the requested topK when groups get crowded.
  final scoredK =
      rows.map((r) => r.recall.topK).fold<int>(topK, (a, b) => min(a, b));

  final header = StringBuffer()
    ..writeln('[Vector Depth Sweep] table=$tableName '
        '${first.dimensions}D ${first.metricLabel}, '
        'corpus=${first.corpusSize}, topK=$topK'
        '${scoredK != topK ? ' (scored@$scoredK)' : ''}, '
        'queries=$iterations, '
        'throughput=${diverseThroughput ? 'diverse' : 'hot'}')
    ..writeln('depths=$depths'
        '${canScore ? '' : ' (Recall@K n/a — example neighbors not distinct at this size)'}')
    ..writeln(
        'searchDepth | recall@$scoredK | top1_hit | self_rc | avg_ms | p95_ms | qps');

  for (final row in rows) {
    header.writeln(row.sweepTableRow());
  }

  return header.toString().trimRight();
}
