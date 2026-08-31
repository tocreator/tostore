import 'dart:math';
import 'dart:typed_data';

// ============================================================================
// Scalar Quantization (SQ8) for High-Performance Inlined Vector Storage
// ============================================================================

/// Quantized 8-bit vector with per-vector min/max calibration.
final class Sq8VectorData {
  /// Quantized 8-bit elements. Length == dimensions.
  final Uint8List codes;

  /// Minimum value of raw elements: offset = v_min.
  final double offset;

  /// Scale factor: scale = (v_max - v_min) / 255.0.
  final double scale;

  /// Pre-computed squared L2 norm for fast exact/approximate L2 calculation.
  final double squaredNorm;

  const Sq8VectorData({
    required this.codes,
    required this.offset,
    required this.scale,
    required this.squaredNorm,
  });
}

/// High-performance pure Dart scalar quantizer with unrolled SIMD/table kernels.
abstract final class ScalarQuantizer {
  /// Quantize a single [Float32List] vector to SQ8.
  static Sq8VectorData quantize(Float32List vector) {
    final len = vector.length;
    if (len == 0) {
      return Sq8VectorData(
        codes: Uint8List(0),
        offset: 0,
        scale: 1,
        squaredNorm: 0,
      );
    }

    double vMin = vector[0];
    double vMax = vector[0];
    double sqNorm = 0;

    for (int i = 0; i < len; i++) {
      final v = vector[i];
      if (v < vMin) vMin = v;
      if (v > vMax) vMax = v;
      sqNorm += v * v;
    }

    final diff = vMax - vMin;
    final scale = diff == 0 ? 1.0 : diff / 255.0;
    final invScale = diff == 0 ? 0.0 : 255.0 / diff;
    final offset = vMin;

    final codes = Uint8List(len);
    for (int i = 0; i < len; i++) {
      final q = ((vector[i] - offset) * invScale + 0.5).toInt();
      codes[i] = q < 0 ? 0 : (q > 255 ? 255 : q);
    }

    return Sq8VectorData(
      codes: codes,
      offset: offset,
      scale: scale,
      squaredNorm: sqNorm,
    );
  }

  /// Batch quantize a list of vectors.
  static List<Sq8VectorData> quantizeBatch(List<Float32List> vectors) {
    final results = List<Sq8VectorData>.generate(
      vectors.length,
      (i) => quantize(vectors[i]),
      growable: false,
    );
    return results;
  }

  /// Dequantize an SQ8 vector back to full-precision Float32List.
  static Float32List dequantize(
    Uint8List codes,
    double offset,
    double scale,
  ) {
    final len = codes.length;
    final out = Float32List(len);
    for (int i = 0; i < len; i++) {
      out[i] = offset + codes[i] * scale;
    }
    return out;
  }

  /// Compute approximate inner product between [query] and an SQ8 vector.
  ///
  /// Mathematical reduction:
  ///   `<q, x>` = sum(q_i * (offset + scale * code_i))
  ///          = offset * sum(q_i) + scale * sum(q_i * code_i)
  ///
  /// [querySum] should be precomputed as `sum(query)` once per query.
  static double dotProduct({
    required Float32List query,
    required double querySum,
    required Uint8List codes,
    required double offset,
    required double scale,
  }) {
    final len = query.length;
    double codeDot = 0;

    // 4-way loop unrolling for maximum Dart VM instruction pipelining
    int i = 0;
    final unrollLen = len - 3;
    while (i < unrollLen) {
      codeDot += query[i] * codes[i] +
          query[i + 1] * codes[i + 1] +
          query[i + 2] * codes[i + 2] +
          query[i + 3] * codes[i + 3];
      i += 4;
    }
    while (i < len) {
      codeDot += query[i] * codes[i];
      i++;
    }

    return offset * querySum + scale * codeDot;
  }

  /// Compute approximate squared L2 distance between [query] and an SQ8 vector.
  ///
  /// Using identity: `||q - x||^2 = ||q||^2 + ||x||^2 - 2 * <q, x>`
  static double squaredL2Distance({
    required Float32List query,
    required double querySquaredNorm,
    required double querySum,
    required Uint8List codes,
    required double offset,
    required double scale,
    required double targetSquaredNorm,
  }) {
    final ip = dotProduct(
      query: query,
      querySum: querySum,
      codes: codes,
      offset: offset,
      scale: scale,
    );
    final dist = querySquaredNorm + targetSquaredNorm - 2.0 * ip;
    return dist < 0 ? 0.0 : dist;
  }

  /// Compute approximate cosine distance between normalized [query] and an SQ8 vector.
  ///
  /// Distance = `1.0 - ( <q, x> / ( ||q|| * ||x|| ) )`
  /// When query is unit-normalized: `distance = 1.0 - ( <q, x> / sqrt(||x||^2) )`
  static double cosineDistance({
    required Float32List query,
    required double querySum,
    required Uint8List codes,
    required double offset,
    required double scale,
    required double targetSquaredNorm,
  }) {
    final ip = dotProduct(
      query: query,
      querySum: querySum,
      codes: codes,
      offset: offset,
      scale: scale,
    );
    final targetNorm = targetSquaredNorm > 0 ? sqrt(targetSquaredNorm) : 1.0;
    final cosSim = ip / targetNorm;
    final dist = 1.0 - cosSim;
    return dist < 0 ? 0.0 : (dist > 2.0 ? 2.0 : dist);
  }

  /// Compute approximate cosine distance using precomputed inverse target norm `1.0 / sqrt(||x||^2)`.
  /// Eliminates repeated `sqrt()` operations in tight candidate scoring loops.
  static double cosineDistanceWithInvNorm({
    required Float32List query,
    required double querySum,
    required Uint8List codes,
    required double offset,
    required double scale,
    required double invNorm,
  }) {
    final ip = dotProduct(
      query: query,
      querySum: querySum,
      codes: codes,
      offset: offset,
      scale: scale,
    );
    final cosSim = ip * invNorm;
    final dist = 1.0 - cosSim;
    return dist < 0 ? 0.0 : (dist > 2.0 ? 2.0 : dist);
  }

  /// 16-way unrolled SQ8 cosine distance (hot path for 128/256/512-d).
  static double fastCosineDistance(
    Float32List query,
    double querySum,
    Uint8List codes,
    double offset,
    double scale,
    double invNorm,
  ) {
    final len = query.length;
    final codeDot = _sq8CodeDot(query, codes, len);
    final ip = offset * querySum + scale * codeDot;
    final cosSim = ip * invNorm;
    final dist = 1.0 - cosSim;
    return dist < 0 ? 0.0 : (dist > 2.0 ? 2.0 : dist);
  }

  /// Strided SQ8 cosine for coarse prefilter (relative ranking only).
  /// Samples every [stride]-th dim and scales the code-dot back by [stride].
  static double fastCosineDistanceStrided(
    Float32List query,
    double querySum,
    Uint8List codes,
    double offset,
    double scale,
    double invNorm, {
    int stride = 4,
  }) {
    final len = query.length;
    if (stride <= 1 || len <= stride * 8) {
      return fastCosineDistance(query, querySum, codes, offset, scale, invNorm);
    }
    double codeDot = 0;
    for (var i = 0; i < len; i += stride) {
      codeDot += query[i] * codes[i];
    }
    final ip = offset * querySum + scale * codeDot * stride;
    final cosSim = ip * invNorm;
    final dist = 1.0 - cosSim;
    return dist < 0 ? 0.0 : (dist > 2.0 ? 2.0 : dist);
  }

  /// Σ query[i]·codes[i] with 16-way unroll when [len] ≥ 16.
  static double _sq8CodeDot(Float32List query, Uint8List codes, int len) {
    double codeDot = 0;
    var i = 0;
    final unroll16 = len - 15;
    while (i < unroll16) {
      codeDot += query[i] * codes[i] +
          query[i + 1] * codes[i + 1] +
          query[i + 2] * codes[i + 2] +
          query[i + 3] * codes[i + 3] +
          query[i + 4] * codes[i + 4] +
          query[i + 5] * codes[i + 5] +
          query[i + 6] * codes[i + 6] +
          query[i + 7] * codes[i + 7] +
          query[i + 8] * codes[i + 8] +
          query[i + 9] * codes[i + 9] +
          query[i + 10] * codes[i + 10] +
          query[i + 11] * codes[i + 11] +
          query[i + 12] * codes[i + 12] +
          query[i + 13] * codes[i + 13] +
          query[i + 14] * codes[i + 14] +
          query[i + 15] * codes[i + 15];
      i += 16;
    }
    while (i < len) {
      codeDot += query[i] * codes[i];
      i++;
    }
    return codeDot;
  }

  /// Reconstruct SQ8 → float32 (utility / tests). Prefer scoring via SQ8 kernels.
  static Float32List reconstructSq8(
    Uint8List codes,
    double offset,
    double scale,
  ) {
    final len = codes.length;
    final out = Float32List(len);
    int i = 0;
    final unroll = len - 3;
    while (i < unroll) {
      out[i] = offset + scale * codes[i];
      out[i + 1] = offset + scale * codes[i + 1];
      out[i + 2] = offset + scale * codes[i + 2];
      out[i + 3] = offset + scale * codes[i + 3];
      i += 4;
    }
    while (i < len) {
      out[i] = offset + scale * codes[i];
      i++;
    }
    return out;
  }

  /// Float32x4List.view dot product for aligned float32 vectors (routing).
  static double dotProductF32(Float32List a, Float32List b) {
    final len = a.length;
    final n = len >> 2;
    if (n > 0 && (a.offsetInBytes & 15) == 0 && (b.offsetInBytes & 15) == 0) {
      final av = Float32x4List.view(a.buffer, a.offsetInBytes, n);
      final bv = Float32x4List.view(b.buffer, b.offsetInBytes, n);
      var acc = Float32x4.zero();
      for (var i = 0; i < n; i++) {
        acc += av[i] * bv[i];
      }
      double sum = acc.x + acc.y + acc.z + acc.w;
      for (var i = n << 2; i < len; i++) {
        sum += a[i] * b[i];
      }
      return sum;
    }

    double sum = 0;
    var i = 0;
    final unroll = len - 7;
    while (i < unroll) {
      sum += a[i] * b[i] +
          a[i + 1] * b[i + 1] +
          a[i + 2] * b[i + 2] +
          a[i + 3] * b[i + 3] +
          a[i + 4] * b[i + 4] +
          a[i + 5] * b[i + 5] +
          a[i + 6] * b[i + 6] +
          a[i + 7] * b[i + 7];
      i += 8;
    }
    while (i < len) {
      sum += a[i] * b[i];
      i++;
    }
    return sum;
  }

  /// Cosine distance against a pre-reconstructed float vector.
  static double fastCosineDistanceF32(
    Float32List query,
    Float32List target,
    double invNorm,
  ) {
    final ip = dotProductF32(query, target);
    final cosSim = ip * invNorm;
    final dist = 1.0 - cosSim;
    return dist < 0 ? 0.0 : (dist > 2.0 ? 2.0 : dist);
  }

  /// Negated inner-product distance against a pre-reconstructed float vector.
  static double fastDotProductF32(Float32List query, Float32List target) {
    return -dotProductF32(query, target);
  }

  /// Squared L2 against a pre-reconstructed float vector.
  static double fastSquaredL2DistanceF32(
    Float32List query,
    double querySquaredNorm,
    Float32List target,
    double targetSquaredNorm,
  ) {
    final ip = dotProductF32(query, target);
    final dist = querySquaredNorm + targetSquaredNorm - 2.0 * ip;
    return dist < 0 ? 0.0 : dist;
  }

  /// 8-way unrolled SQ8 squared L2 distance kernel.
  static double fastSquaredL2Distance(
    Float32List query,
    double querySquaredNorm,
    double querySum,
    Uint8List codes,
    double offset,
    double scale,
    double targetSquaredNorm,
  ) {
    final codeDot = _sq8CodeDot(query, codes, query.length);
    final ip = offset * querySum + scale * codeDot;
    final dist = querySquaredNorm + targetSquaredNorm - 2.0 * ip;
    return dist < 0 ? 0.0 : dist;
  }

  /// 16-way unrolled SQ8 inner-product distance kernel (returns negated IP).
  static double fastDotProduct(
    Float32List query,
    double querySum,
    Uint8List codes,
    double offset,
    double scale,
  ) {
    final codeDot = _sq8CodeDot(query, codes, query.length);
    return -(offset * querySum + scale * codeDot);
  }
}
