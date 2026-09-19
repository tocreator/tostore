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
  /// 8-way unrolled for maximum pipeline efficiency on Dart VM.
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
    double dot0 = 0;
    double dot1 = 0;
    var i = 0;
    final step8 = stride * 8;
    final unrollLen = len - step8 + 1;
    final s1 = stride;
    final s2 = stride * 2;
    final s3 = stride * 3;
    final s4 = stride * 4;
    final s5 = stride * 5;
    final s6 = stride * 6;
    final s7 = stride * 7;
    while (i < unrollLen) {
      dot0 += query[i] * codes[i] +
          query[i + s1] * codes[i + s1] +
          query[i + s2] * codes[i + s2] +
          query[i + s3] * codes[i + s3];
      dot1 += query[i + s4] * codes[i + s4] +
          query[i + s5] * codes[i + s5] +
          query[i + s6] * codes[i + s6] +
          query[i + s7] * codes[i + s7];
      i += step8;
    }
    while (i < len) {
      dot0 += query[i] * codes[i];
      i += stride;
    }
    final codeDot = dot0 + dot1;
    final ip = offset * querySum + scale * codeDot * stride;
    final cosSim = ip * invNorm;
    final dist = 1.0 - cosSim;
    return dist < 0 ? 0.0 : (dist > 2.0 ? 2.0 : dist);
  }

  /// Strided SQ8 inner-product distance kernel (returns negated IP).
  static double fastDotProductStrided(
    Float32List query,
    double querySum,
    Uint8List codes,
    double offset,
    double scale, {
    int stride = 4,
  }) {
    final len = query.length;
    if (stride <= 1 || len <= stride * 8) {
      return fastDotProduct(query, querySum, codes, offset, scale);
    }
    double dot0 = 0;
    double dot1 = 0;
    var i = 0;
    final step8 = stride * 8;
    final unrollLen = len - step8 + 1;
    final s1 = stride;
    final s2 = stride * 2;
    final s3 = stride * 3;
    final s4 = stride * 4;
    final s5 = stride * 5;
    final s6 = stride * 6;
    final s7 = stride * 7;
    while (i < unrollLen) {
      dot0 += query[i] * codes[i] +
          query[i + s1] * codes[i + s1] +
          query[i + s2] * codes[i + s2] +
          query[i + s3] * codes[i + s3];
      dot1 += query[i + s4] * codes[i + s4] +
          query[i + s5] * codes[i + s5] +
          query[i + s6] * codes[i + s6] +
          query[i + s7] * codes[i + s7];
      i += step8;
    }
    while (i < len) {
      dot0 += query[i] * codes[i];
      i += stride;
    }
    final codeDot = dot0 + dot1;
    return -(offset * querySum + scale * codeDot * stride);
  }

  /// Strided SQ8 squared L2 distance kernel.
  static double fastSquaredL2DistanceStrided(
    Float32List query,
    double querySquaredNorm,
    double querySum,
    Uint8List codes,
    double offset,
    double scale,
    double targetSquaredNorm, {
    int stride = 4,
  }) {
    final len = query.length;
    if (stride <= 1 || len <= stride * 8) {
      return fastSquaredL2Distance(
        query,
        querySquaredNorm,
        querySum,
        codes,
        offset,
        scale,
        targetSquaredNorm,
      );
    }
    double dot0 = 0.0;
    double dot1 = 0.0;
    var i = 0;
    final step8 = stride * 8;
    final unrollLen = len - step8 + 1;
    final s1 = stride;
    final s2 = stride * 2;
    final s3 = stride * 3;
    final s4 = stride * 4;
    final s5 = stride * 5;
    final s6 = stride * 6;
    final s7 = stride * 7;
    while (i < unrollLen) {
      dot0 += query[i] * codes[i] +
          query[i + s2] * codes[i + s2] +
          query[i + s4] * codes[i + s4] +
          query[i + s6] * codes[i + s6];
      dot1 += query[i + s1] * codes[i + s1] +
          query[i + s3] * codes[i + s3] +
          query[i + s5] * codes[i + s5] +
          query[i + s7] * codes[i + s7];
      i += step8;
    }
    while (i < len) {
      dot0 += query[i] * codes[i];
      i += stride;
    }
    final codeDot = dot0 + dot1;
    final ip = offset * querySum + scale * codeDot * stride;
    final dist = querySquaredNorm + targetSquaredNorm - 2.0 * ip;
    return dist < 0 ? 0.0 : dist;
  }

  /// Σ query[i]·codes[i] with 16-way unroll and 4 independent accumulators to break FADD pipeline stalls.
  static double _sq8CodeDot(Float32List query, Uint8List codes, int len) {
    double acc0 = 0.0;
    double acc1 = 0.0;
    double acc2 = 0.0;
    double acc3 = 0.0;
    var i = 0;
    final unroll16 = len - 15;
    while (i < unroll16) {
      acc0 += query[i] * codes[i] +
          query[i + 1] * codes[i + 1] +
          query[i + 2] * codes[i + 2] +
          query[i + 3] * codes[i + 3];
      acc1 += query[i + 4] * codes[i + 4] +
          query[i + 5] * codes[i + 5] +
          query[i + 6] * codes[i + 6] +
          query[i + 7] * codes[i + 7];
      acc2 += query[i + 8] * codes[i + 8] +
          query[i + 9] * codes[i + 9] +
          query[i + 10] * codes[i + 10] +
          query[i + 11] * codes[i + 11];
      acc3 += query[i + 12] * codes[i + 12] +
          query[i + 13] * codes[i + 13] +
          query[i + 14] * codes[i + 14] +
          query[i + 15] * codes[i + 15];
      i += 16;
    }
    while (i < len) {
      acc0 += query[i] * codes[i];
      i++;
    }
    return (acc0 + acc1) + (acc2 + acc3);
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

  /// Zero-allocation 4-way unrolled SIMD dot product using pre-viewed Float32x4 buffers.
  /// [n4] is the number of Float32x4 elements (i.e. dimensions >> 2).
  ///
  /// Uses 4 independent Float32x4 accumulators to completely hide FADD latency on superscalar CPUs.
  static double dotProductF32Simd(Float32x4List qv, Float32x4List cv, int n4) {
    var acc0 = Float32x4.zero();
    var acc1 = Float32x4.zero();
    var acc2 = Float32x4.zero();
    var acc3 = Float32x4.zero();
    var i = 0;
    final unroll4 = n4 - 3;
    while (i < unroll4) {
      acc0 += qv[i] * cv[i];
      acc1 += qv[i + 1] * cv[i + 1];
      acc2 += qv[i + 2] * cv[i + 2];
      acc3 += qv[i + 3] * cv[i + 3];
      i += 4;
    }
    while (i < n4) {
      acc0 += qv[i] * cv[i];
      i++;
    }
    final acc = (acc0 + acc1) + (acc2 + acc3);
    return acc.x + acc.y + acc.z + acc.w;
  }

  /// Float32 dot product with SIMD alignment detection and 4-way independent accumulators.
  static double dotProductF32(Float32List a, Float32List b) {
    final len = a.length;
    final n = len >> 2;
    if (n > 0 && (a.offsetInBytes & 15) == 0 && (b.offsetInBytes & 15) == 0) {
      final av = Float32x4List.view(a.buffer, a.offsetInBytes, n);
      final bv = Float32x4List.view(b.buffer, b.offsetInBytes, n);
      double sum = dotProductF32Simd(av, bv, n);
      for (var i = n << 2; i < len; i++) {
        sum += a[i] * b[i];
      }
      return sum;
    }

    double s0 = 0;
    double s1 = 0;
    double s2 = 0;
    double s3 = 0;
    var i = 0;
    final unroll = len - 7;
    while (i < unroll) {
      s0 += a[i] * b[i] + a[i + 1] * b[i + 1];
      s1 += a[i + 2] * b[i + 2] + a[i + 3] * b[i + 3];
      s2 += a[i + 4] * b[i + 4] + a[i + 5] * b[i + 5];
      s3 += a[i + 6] * b[i + 6] + a[i + 7] * b[i + 7];
      i += 8;
    }
    while (i < len) {
      s0 += a[i] * b[i];
      i++;
    }
    return (s0 + s1) + (s2 + s3);
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
