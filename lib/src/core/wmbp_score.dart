import 'dart:math' as math;

/// Doc-side q8 quantization and query-time exact additive scores.
///
/// Stored impact is a doc-side component in `1..255`. Collection statistics
/// are applied only while compiling a query, so prune bounds and heap scores
/// share one integer channel.
abstract final class WmbpScore {
  /// Maps a positive raw weight into doc-side q8. Non-positive yields 0.
  ///
  /// Contract for sparse / weighted-term storage: weights are expected in
  /// `(0, 1]`. Values `>= 1.0` saturate at 255. Callers with model activations
  /// outside that band (e.g. raw SPLADE logits) must normalize or saturate
  /// before upsert — this API does not invent a per-model scale.
  static int quantizePositive(num value) {
    if (value <= 0) return 0;
    final double v = value.toDouble();
    if (v >= 1.0) return 255;
    final int q = (v * 255.0).round();
    if (q < 1) return 1;
    if (q > 255) return 255;
    return q;
  }

  static final List<int> _tfTable = List<int>.generate(64, (tf) {
    if (tf <= 0) return 0;
    final double sat = tf / (tf + 1.2);
    var q = (sat * 255.0).round();
    if (q < 1) q = 1;
    if (q > 255) q = 255;
    return q;
  }, growable: false);

  /// Saturating term frequency mapped into doc-side q8.
  @pragma('vm:prefer-inline')
  static int quantizeTermFrequency(int tf) {
    if (tf <= 0) return 0;
    if (tf < 64) return _tfTable[tf];
    final double sat = tf / (tf + 1.2);
    var q = (sat * 255.0).round();
    if (q > 255) q = 255;
    return q;
  }

  /// Query-time collection weight in milli-units. Zero df yields 0.
  static int idfMilli(int df, int activeDocs) {
    if (df <= 0 || activeDocs <= 0) return 0;
    final double v = math.log((activeDocs + 1) / (df + 0.5));
    if (v <= 0) return 1;
    final int m = (v * 1000.0).ceil();
    return m < 1 ? 1 : m;
  }

  /// Scales a query weight into milli-units. Non-positive yields 0.
  static int weightMilli(num weight) {
    if (weight <= 0) return 0;
    return (weight.toDouble() * 1000.0).round();
  }

  /// Solo CJK unigram query weight scale (`1/5`).
  ///
  /// Applied only while compiling [TextQuery.text] — the posting scan is
  /// unchanged. Targets public relevance near `0.30..0.40` for a rare
  /// single-character hit (vs ~0.71 for one strong exact word/bigram).
  static const int cjkUnigramQueryWeightNum = 1;
  static const int cjkUnigramQueryWeightDen = 5;

  /// CJK unigram scale when the same query also has a CJK bigram (`1/10`).
  ///
  /// Keeps unigrams as weak OR supplements so long Chinese queries do not
  /// drown bigram signal.
  static const int cjkUnigramWithBigramQueryWeightNum = 1;
  static const int cjkUnigramWithBigramQueryWeightDen = 10;

  /// Query-compile scale for CJK unigrams. Non-unigram [milli] is unchanged.
  /// Positive input never collapses to 0 (term stays searchable).
  static int applyCjkUnigramQueryScale(
    int milli, {
    required bool isCjkUnigram,
    required bool queryHasCjkBigram,
  }) {
    if (!isCjkUnigram || milli <= 0) return milli;
    final int scaled = queryHasCjkBigram
        ? (milli * cjkUnigramWithBigramQueryWeightNum) ~/
            cjkUnigramWithBigramQueryWeightDen
        : (milli * cjkUnigramQueryWeightNum) ~/ cjkUnigramQueryWeightDen;
    return scaled < 1 ? 1 : scaled;
  }

  /// Exact additive contribution of one impact. Linear in q8, so it is safe
  /// as both the heap score and the prune upper bound.
  @pragma('vm:prefer-inline')
  static int contrib(int unitMilli, int q8) {
    if (q8 <= 0 || unitMilli <= 0) return 0;
    return unitMilli * q8;
  }

  /// Public text [rawScore] scale: idfMilli × weightMilli × q8 / this.
  ///
  /// Typical short queries land near `0..30`; long multi-term queries may
  /// exceed `100`. There is no hard cap.
  static const double textRawScoreScale = 1000.0 * 1000.0 * 255.0;

  /// Public raw of one query-weight 1 feature stored at full q8 (255).
  ///
  /// Matches the text anchor `raw ≈ 5` (one strong exact term → score ~0.71),
  /// so a saturated sparse feature and a strong text term share the cosine
  /// discard band. Sparse has no collection IDF; extra features add raw.
  static const double sparseFullFeatureRaw = 5.0;

  /// Public sparse [rawScore] scale: weightMilli × q8 / this.
  static const double sparseRawScoreScale =
      1000.0 * 255.0 / sparseFullFeatureRaw;

  /// Continuous text relevance for API results (`higher` = more relevant).
  static double textRawScore(int rawUnits) => rawUnits / textRawScoreScale;

  /// Continuous sparse relevance for API results (`higher` = more relevant).
  static double sparseRawScore(int rawUnits) => rawUnits / sparseRawScoreScale;

  /// Pivot for mapping a continuous raw score into `[0, 1)`.
  ///
  /// `raw / (raw + pivot)` is an absolute relevance on the same discard band
  /// as cosine similarity and normalized inner product:
  /// - raw ≈ 1 (weak / common) → about 0.33
  /// - raw ≈ 5 (one strong exact text term) → about 0.71
  /// - raw ≈ 30 (several strong terms) → about 0.94
  ///
  /// The best hit in a result is not forced to 1.
  static const double relevancePivot = 2.0;

  /// Absolute relevance in `[0, 1)` from a text or sparse [rawScore].
  static double relevanceFromRaw(double rawScore) {
    if (rawScore <= 0) return 0;
    return rawScore / (rawScore + relevancePivot);
  }

  /// Smallest q8 whose contribution can reach [needUnits] (`>=`).
  static int minimumQ8(int unitMilli, int needUnits) {
    if (needUnits <= 0) return 1;
    if (unitMilli <= 0) return 256;
    final int q = (needUnits + unitMilli - 1) ~/ unitMilli;
    if (q < 1) return 1;
    return q;
  }
}
