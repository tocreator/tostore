import 'dart:math';
import 'dart:typed_data';

import '../../model/ngh_index_meta.dart';
import 'vector_score_calibrator.dart';

/// Background null-floor parameter estimation via pairwise moment matching.
///
/// Pure math + in-memory sampling helpers. I/O / leaf reads live in
/// [VectorIndexManager].
abstract final class NghNullFloorEstimator {
  /// Bump when fit semantics change (invalidates persisted stats).
  static const int algorithmVersion = 1;

  static const int minLiveVectors = 2048;

  /// Max multiply-adds budget (~64M).
  static const int maxMultiplyAdds = 64000000;

  /// Target pair count for moment matching.
  static const int targetPairCount = 32768;

  static const double _selfMatchEpsilon =
      VectorScoreCalibrator.selfMatchEpsilon;

  static const double _muMaxCap = 0.85;

  /// Whether [meta] should run empirical estimation.
  ///
  /// Always false: public vector `score` is identity (no null-floor remap),
  /// so background estimation is not scheduled.
  static bool shouldEstimate(NghIndexMeta meta) => false;

  /// Sample pool size capped by multiply-add budget.
  static int sampleSize(int dimensions) {
    final d = dimensions < 1 ? 1 : dimensions;
    final byBudget = maxMultiplyAdds ~/ (64 * d);
    final m = byBudget < 16384 ? byBudget : 16384;
    return m < 64 ? 64 : m;
  }

  /// Deterministic seed from index identity and corpus size.
  static int seedFor(String indexUid, int totalVectors) {
    return indexUid.hashCode ^ totalVectors;
  }

  /// Fit `(mu, D_eff)` from unit-normalized sample rows.
  ///
  /// Returns null when too few valid pairs remain after near-duplicate exclusion.
  static ({double mu, double dEff})? fitMomentMatching({
    required List<Float32List> unitSamples,
    required int dimensions,
    required Random rng,
    int pairCount = targetPairCount,
  }) {
    final m = unitSamples.length;
    if (m < 8 || dimensions < 2) return null;

    final int pairs = pairCount < 256 ? 256 : pairCount;
    double sum = 0.0;
    double sumSq = 0.0;
    int used = 0;

    for (int i = 0; i < pairs; i++) {
      final int a = rng.nextInt(m);
      var b = rng.nextInt(m);
      if (b == a) {
        b = (b + 1) % m;
      }
      final double cos = _dot(unitSamples[a], unitSamples[b], dimensions);
      if (cos >= 1.0 - _selfMatchEpsilon) {
        continue;
      }
      sum += cos;
      sumSq += cos * cos;
      used++;
    }
    if (used < 64) return null;

    final double muHat = sum / used;
    final double varHat = (sumSq / used) - muHat * muHat;
    final double varClamped = varHat < 1e-12 ? 1e-12 : varHat;

    final double mu =
        muHat < 0.0 ? 0.0 : (muHat > _muMaxCap ? _muMaxCap : muHat);
    final double oneMinus = 1.0 - mu;
    var dEff = (oneMinus * oneMinus) / varClamped;
    if (dEff < 2.0) dEff = 2.0;
    if (dEff > dimensions.toDouble()) dEff = dimensions.toDouble();

    return (mu: mu, dEff: dEff);
  }

  /// L2-normalize [v] into a new [Float32List] (or null if near-zero).
  static Float32List? toUnit(Float32List v) {
    double n2 = 0.0;
    for (int i = 0; i < v.length; i++) {
      n2 += v[i] * v[i];
    }
    if (n2 <= 1e-30) return null;
    final inv = 1.0 / sqrt(n2);
    final out = Float32List(v.length);
    for (int i = 0; i < v.length; i++) {
      out[i] = v[i] * inv;
    }
    return out;
  }

  /// Column-shuffle Top-1 median (unit-test / sanity helper only).
  ///
  /// Probes are L2-normalized after shuffle. Not used for primary fitting.
  static double columnShuffleTop1Median({
    required List<Float32List> unitSamples,
    required int dimensions,
    required Random rng,
    int probeCount = 64,
  }) {
    final m = unitSamples.length;
    if (m < 2 || dimensions < 1 || probeCount < 1) return 0.0;

    final tops = <double>[];
    final probe = Float32List(dimensions);
    for (int p = 0; p < probeCount; p++) {
      for (int d = 0; d < dimensions; d++) {
        probe[d] = unitSamples[rng.nextInt(m)][d];
      }
      final unit = toUnit(probe);
      if (unit == null) continue;
      double best = -1.0;
      for (int i = 0; i < m; i++) {
        final c = _dot(unit, unitSamples[i], dimensions);
        if (c >= 1.0 - _selfMatchEpsilon) continue;
        if (c > best) best = c;
      }
      if (best >= 0.0) tops.add(best);
    }
    if (tops.isEmpty) return 0.0;
    tops.sort();
    return tops[tops.length >> 1];
  }

  static double _dot(Float32List a, Float32List b, int d) {
    final n = d < a.length
        ? (d < b.length ? d : b.length)
        : (a.length < b.length ? a.length : b.length);
    double s = 0.0;
    for (int i = 0; i < n; i++) {
      s += a[i] * b[i];
    }
    return s;
  }
}
