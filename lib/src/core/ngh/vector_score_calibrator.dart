import 'dart:math';

import '../../model/table_schema.dart';

/// Per-query score mapping parameters.
///
/// Hot path is identity: public [score] tracks effective physical similarity.
/// Physical `rawScore` / `distance` are never rewritten by this object.
final class VectorScoreCalibration {
  /// Shared no-op calibration (`score` equals positive `s_eff`).
  static const VectorScoreCalibration identity = VectorScoreCalibration._(
    isIdentity: true,
    f: 0.0,
    g: 0.0,
    hiSlope: 1.0,
    loSlope: 1.0,
  );

  final bool isIdentity;

  /// Unused when [isIdentity] (kept for API stability).
  final double f;

  /// Unused when [isIdentity].
  final double g;

  /// Unused when [isIdentity].
  final double hiSlope;

  /// Unused when [isIdentity].
  final double loSlope;

  const VectorScoreCalibration._({
    required this.isIdentity,
    required this.f,
    required this.g,
    required this.hiSlope,
    required this.loSlope,
  });
}

/// Maps vector metrics into public `distance` / `rawScore` / `score`.
///
/// For every dimension and corpus size, [score] tracks effective physical
/// similarity (`cosine` / symmetric L2 / directional inner-product):
/// exact self-match → `1.0`, non-positive → `0.0`, otherwise `score == s_eff`
/// for `s_eff > 0`. ANN order is unchanged.
abstract final class VectorScoreCalibrator {
  /// Self-match cosine error epsilon.
  static const double selfMatchEpsilon = 1e-4;

  /// Builds calibration for one query (always identity).
  static VectorScoreCalibration forQuery(
    int dimensions,
    int corpusSize, {
    double? mu,
    double? dEff,
  }) {
    return VectorScoreCalibration.identity;
  }

  /// Maps effective physical similarity into `[0, 1]`.
  @pragma('vm:prefer-inline')
  static double calibrateEffectiveSimilarity(
    double effectiveSimilarity,
    VectorScoreCalibration calibration, {
    bool isExactSelf = false,
  }) {
    if (isExactSelf || effectiveSimilarity >= 1.0 - selfMatchEpsilon) {
      return 1.0;
    }
    if (effectiveSimilarity <= 0.0) {
      return 0.0;
    }
    // Identity path only.
    return effectiveSimilarity;
  }

  /// Inverse of [calibrateEffectiveSimilarity].
  @pragma('vm:prefer-inline')
  static double inverseEffectiveSimilarity(
    double targetScore,
    VectorScoreCalibration calibration,
  ) {
    if (targetScore >= 1.0) return 1.0;
    if (targetScore <= 0.0) return 0.0;
    return targetScore;
  }

  /// Evaluates cosine similarity into distance, rawScore, and score.
  @pragma('vm:prefer-inline')
  static ({double distance, double rawScore, double score}) fromCosine({
    required double cosineSimilarity,
    VectorScoreCalibration calibration = VectorScoreCalibration.identity,
    bool validNorms = true,
  }) {
    if (!validNorms) {
      return (distance: 1.0, rawScore: 0.0, score: 0.0);
    }
    final double rawCos = cosineSimilarity.clamp(-1.0, 1.0);
    final double dist = (1.0 - rawCos).clamp(0.0, 2.0);
    final bool isSelf = rawCos >= 1.0 - selfMatchEpsilon;
    final double score = calibrateEffectiveSimilarity(
      rawCos,
      calibration,
      isExactSelf: isSelf,
    );
    return (distance: dist, rawScore: rawCos, score: score);
  }

  /// Evaluates squared L2 into distance, rawScore, and score.
  @pragma('vm:prefer-inline')
  static ({double distance, double rawScore, double score}) fromSquaredL2({
    required double squaredDistance,
    required double querySquaredNorm,
    required double candidateSquaredNorm,
    VectorScoreCalibration calibration = VectorScoreCalibration.identity,
  }) {
    final double normSum = querySquaredNorm + candidateSquaredNorm;
    if (normSum <= 0.0) {
      return (distance: 0.0, rawScore: 0.0, score: 1.0);
    }
    final double d2 = squaredDistance < 0.0 ? 0.0 : squaredDistance;
    final double rawDist = sqrt(d2);
    final double sEff = (1.0 - d2 / normSum).clamp(-1.0, 1.0);
    final bool isSelf = d2 <= 0.0 || d2 <= selfMatchEpsilon * normSum;
    final double score = calibrateEffectiveSimilarity(
      sEff,
      calibration,
      isExactSelf: isSelf,
    );
    return (distance: d2, rawScore: rawDist, score: score);
  }

  /// Evaluates inner product into distance, rawScore, and score.
  @pragma('vm:prefer-inline')
  static ({double distance, double rawScore, double score}) fromInnerProduct({
    required double innerProduct,
    required double querySquaredNorm,
    required double candidateSquaredNorm,
    VectorScoreCalibration calibration = VectorScoreCalibration.identity,
  }) {
    final double dist = -innerProduct;
    final double qSq = querySquaredNorm;
    final double cSq = candidateSquaredNorm;
    if (qSq <= 0.0 || cSq <= 0.0) {
      return (distance: dist, rawScore: innerProduct, score: 0.0);
    }
    final double denom = sqrt(qSq * cSq);
    final double rawCos = denom > 0.0 ? innerProduct / denom : 0.0;
    final double cosSim = rawCos > 1.0 ? 1.0 : (rawCos < -1.0 ? -1.0 : rawCos);
    final double normSum = qSq + cSq;
    final double d2 = normSum - 2.0 * innerProduct;
    final bool isSelf = (1.0 - cosSim) <= selfMatchEpsilon &&
        (d2 <= 0.0 || d2 <= selfMatchEpsilon * normSum);
    final double score = calibrateEffectiveSimilarity(
      cosSim,
      calibration,
      isExactSelf: isSelf,
    );
    return (distance: dist, rawScore: innerProduct, score: score);
  }

  /// Unified evaluation from raw inner product and squared norms.
  @pragma('vm:prefer-inline')
  static ({double distance, double rawScore, double score}) evaluate({
    required VectorDistanceMetric metric,
    required double innerProduct,
    required double querySquaredNorm,
    required double candidateSquaredNorm,
    VectorScoreCalibration calibration = VectorScoreCalibration.identity,
  }) {
    switch (metric) {
      case VectorDistanceMetric.cosine:
        final double denomSq = querySquaredNorm * candidateSquaredNorm;
        if (denomSq <= 0.0) {
          return (distance: 1.0, rawScore: 0.0, score: 0.0);
        }
        return fromCosine(
          cosineSimilarity: innerProduct / sqrt(denomSq),
          calibration: calibration,
          validNorms: true,
        );
      case VectorDistanceMetric.innerProduct:
        return fromInnerProduct(
          innerProduct: innerProduct,
          querySquaredNorm: querySquaredNorm,
          candidateSquaredNorm: candidateSquaredNorm,
          calibration: calibration,
        );
      case VectorDistanceMetric.l2:
        final double d2 =
            querySquaredNorm + candidateSquaredNorm - 2.0 * innerProduct;
        return fromSquaredL2(
          squaredDistance: d2,
          querySquaredNorm: querySquaredNorm,
          candidateSquaredNorm: candidateSquaredNorm,
          calibration: calibration,
        );
    }
  }
}
