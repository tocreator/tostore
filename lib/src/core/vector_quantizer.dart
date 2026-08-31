import 'dart:math';
import 'dart:typed_data';

import '../model/db_exception.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';

// ============================================================================
// Product Quantization (PQ) for NGH Vector Index
//
// PQ divides a D-dimensional vector into M sub-vectors of D/M dimensions each.
// Each sub-vector is independently quantised to K centroids (K=256, 1 byte).
// This gives 32x compression (float32->uint8) while enabling fast Asymmetric
// Distance Computation (ADC) during search.
// ============================================================================

/// Trained PQ codebook: M sub-spaces x K centroids x (D/M) dimensions.
///
/// Layout: centroids[m * K * subDim + k * subDim + d] = float32
/// where m in [0,M), k in [0,K), d in [0,subDim).
class PqCodebook {
  /// Number of sub-spaces (M).
  final int subspaces;

  /// Number of centroids per sub-space (K), typically 256.
  final int centroids;

  /// Dimensions per sub-space (D / M).
  final int subDimensions;

  /// Flat centroid data: M x K x subDim float32 values.
  final Float32List data;

  PqCodebook({
    required this.subspaces,
    required this.centroids,
    required this.subDimensions,
    required this.data,
  });

  /// Total vector dimensions: M x subDim.
  int get dimensions => subspaces * subDimensions;

  /// Get centroid vector for sub-space [m], centroid [k].
  /// Uses sublist instead of view to avoid alignment issues on web.
  Float32List getCentroid(int m, int k) {
    final offset = (m * centroids + k) * subDimensions;
    return data.sublist(offset, offset + subDimensions);
  }

  /// Set centroid vector for sub-space [m], centroid [k].
  void setCentroid(int m, int k, Float32List centroid) {
    final offset = (m * centroids + k) * subDimensions;
    data.setRange(offset, offset + subDimensions, centroid);
  }
}

/// PQ quantizer: training, encoding, and Asymmetric Distance Computation.
class VectorQuantizer {
  final PqCodebook codebook;

  VectorQuantizer(this.codebook);

  /// Empty fallback quantizer for NGH or non-trained state.
  static VectorQuantizer empty() => VectorQuantizer(
        PqCodebook(
          subspaces: 1,
          centroids: 1,
          subDimensions: 1,
          data: Float32List(1),
        ),
      );

  int get subspaces => codebook.subspaces;
  int get subDimensions => codebook.subDimensions;
  int get centroids => codebook.centroids;

  /// Total vector dimensions: M x subDim.
  int get dimensions => codebook.dimensions;

  // =====================================================================
  // Training -- K-means per sub-space
  // =====================================================================

  /// Train a PQ codebook from sample vectors.
  ///
  /// Runs K-means independently on each sub-space. Should be executed in an
  /// isolate for large sample sets via [ComputeManager].
  ///
  /// [samples]    -- training vectors (each must be [dimensions]-dimensional).
  /// [dimensions] -- total vector dimensions D.
  /// [subspaces]  -- number of sub-spaces M. Must evenly divide D.
  /// [numCentroids] -- centroids per sub-space K (default 256).
  /// [iterations] -- K-means iterations (default 20).
  static Future<PqCodebook> train({
    required List<Float32List> samples,
    required int dimensions,
    required int subspaces,
    int numCentroids = 256,
    int iterations = 10, // Reduced from 20
  }) async {
    if (samples.isEmpty) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.engError,
          message: 'Training requires at least one sample vector',
          parameterName: 'samples',
          passedValue: 0,
        )
      ]);
    }
    if (dimensions % subspaces != 0) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.engError,
          message:
              'Dimensions ($dimensions) must be divisible by subspaces ($subspaces)',
          parameterName: 'subspaces',
          passedValue: subspaces,
        )
      ]);
    }
    final subDim = dimensions ~/ subspaces;
    final k = min(numCentroids, samples.length);
    final data = Float32List(subspaces * k * subDim);
    final rng = Random(42);

    // Flatten data for better memory locality (n * subDim)
    final n = samples.length;
    final flatData = Float32List(n * dimensions);
    for (int i = 0; i < n; i++) {
      flatData.setRange(i * dimensions, (i + 1) * dimensions, samples[i]);
    }

    // Use SIMD optimization if dimensions allow (multiple of 4 floats / 128 bits)
    final useSimd = (subDim % 4 == 0);

    if (useSimd) {
      // ---------------------------------------------------------
      // SIMD Path
      // ---------------------------------------------------------
      for (int m = 0; m < subspaces; m++) {
        final subStart = m * subDim;

        // Extract sub-vectors from flatData to a contiguous block
        final subData = Float32List(n * subDim);
        for (int i = 0; i < n; i++) {
          for (int d = 0; d < subDim; d++) {
            subData[i * subDim + d] = flatData[i * dimensions + subStart + d];
          }
        }
        final flatSimd = Float32x4List.view(subData.buffer);

        // Centroids
        final centers = Float32List(k * subDim);
        final firstIdx = rng.nextInt(n);
        for (int d = 0; d < subDim; d++) {
          centers[d] = subData[firstIdx * subDim + d];
        }

        var centersSimd = Float32x4List.view(centers.buffer);

        // K-means++ Init
        if (k > 1) {
          final minDists = Float64List(n);
          for (int i = 0; i < n; i++) {
            minDists[i] = double.infinity;
          }

          for (int c = 1; c < k; c++) {
            final prevCOff = (c - 1) * (subDim ~/ 4);
            double totalDist = 0;
            for (int i = 0; i < n; i++) {
              final iOff = i * (subDim ~/ 4);
              double dist = 0;
              for (int sd = 0; sd < subDim ~/ 4; sd++) {
                final diff = flatSimd[iOff + sd] - centersSimd[prevCOff + sd];
                final mag = diff * diff;
                dist += mag.x + mag.y + mag.z + mag.w;
              }
              if (dist < minDists[i]) minDists[i] = dist;
              totalDist += minDists[i];
            }

            int selected = n - 1;
            if (totalDist > 0) {
              double threshold = rng.nextDouble() * totalDist;
              for (int i = 0; i < n; i++) {
                threshold -= minDists[i];
                if (threshold <= 0) {
                  selected = i;
                  break;
                }
              }
            }
            final srcOff = selected * subDim;
            final dstOff = c * subDim;
            for (int d = 0; d < subDim; d++) {
              centers[dstOff + d] = subData[srcOff + d];
            }
          }
        }

        // Iterations
        final assignments = Int32List(n);
        final counts = Int32List(k);
        final sums = Float32List(k * subDim);

        for (int iter = 0; iter < iterations; iter++) {
          centersSimd = Float32x4List.view(centers.buffer);

          for (int i = 0; i < n; i++) {
            int bestIdx = 0;
            double bestDist = double.infinity;
            final iOff = i * (subDim ~/ 4);

            for (int c = 0; c < k; c++) {
              double dist = 0;
              final cOff = c * (subDim ~/ 4);
              for (int sd = 0; sd < subDim ~/ 4; sd++) {
                final diff = flatSimd[iOff + sd] - centersSimd[cOff + sd];
                final mag = diff * diff;
                dist += mag.x + mag.y + mag.z + mag.w;
              }
              if (dist < bestDist) {
                bestDist = dist;
                bestIdx = c;
              }
            }
            assignments[i] = bestIdx;
          }

          sums.fillRange(0, sums.length, 0);
          counts.fillRange(0, counts.length, 0);

          for (int i = 0; i < n; i++) {
            final c = assignments[i];
            counts[c]++;
            final iOff = i * subDim;
            final cOff = c * subDim;
            for (int d = 0; d < subDim; d++) {
              sums[cOff + d] += subData[iOff + d];
            }
          }

          bool changed = false;
          for (int c = 0; c < k; c++) {
            if (counts[c] == 0) continue;
            final cOff = c * subDim;
            final inv = 1.0 / counts[c];
            for (int d = 0; d < subDim; d++) {
              final newVal = sums[cOff + d] * inv;
              if ((centers[cOff + d] - newVal).abs() > 1e-6) changed = true;
              centers[cOff + d] = newVal;
            }
          }
          if (!changed) break;
        }
        data.setRange(m * k * subDim, (m + 1) * k * subDim, centers);
      }
    } else {
      // ---------------------------------------------------------
      // Fallback Path
      // ---------------------------------------------------------
      for (int m = 0; m < subspaces; m++) {
        final subStart = m * subDim;
        final subData = Float32List(n * subDim);
        for (int i = 0; i < n; i++) {
          for (int d = 0; d < subDim; d++) {
            subData[i * subDim + d] = flatData[i * dimensions + subStart + d];
          }
        }

        final centers = Float32List(k * subDim);
        final firstIdx = rng.nextInt(n);
        for (int d = 0; d < subDim; d++) {
          centers[d] = subData[firstIdx * subDim + d];
        }

        if (k > 1) {
          final minDists = Float64List(n);
          for (int i = 0; i < n; i++) {
            minDists[i] = double.infinity;
          }

          for (int c = 1; c < k; c++) {
            final prevOff = (c - 1) * subDim;
            double totalDist = 0;
            for (int i = 0; i < n; i++) {
              final iOff = i * subDim;
              double dist = 0;
              for (int d = 0; d < subDim; d++) {
                final diff = subData[iOff + d] - centers[prevOff + d];
                dist += diff * diff;
              }
              if (dist < minDists[i]) minDists[i] = dist;
              totalDist += minDists[i];
            }
            int selected = n - 1;
            if (totalDist > 0) {
              double threshold = rng.nextDouble() * totalDist;
              for (int i = 0; i < n; i++) {
                threshold -= minDists[i];
                if (threshold <= 0) {
                  selected = i;
                  break;
                }
              }
            }
            final srcOff = selected * subDim;
            final dstOff = c * subDim;
            for (int d = 0; d < subDim; d++) {
              centers[dstOff + d] = subData[srcOff + d];
            }
          }
        }

        final assignments = Int32List(n);
        final counts = Int32List(k);
        final sums = Float32List(k * subDim);

        for (int iter = 0; iter < iterations; iter++) {
          for (int i = 0; i < n; i++) {
            int bestIdx = 0;
            double bestDist = double.infinity;
            final iOff = i * subDim;
            for (int c = 0; c < k; c++) {
              double dist = 0;
              final cOff = c * subDim;
              for (int d = 0; d < subDim; d++) {
                final diff = subData[iOff + d] - centers[cOff + d];
                dist += diff * diff;
              }
              if (dist < bestDist) {
                bestDist = dist;
                bestIdx = c;
              }
            }
            assignments[i] = bestIdx;
          }

          sums.fillRange(0, sums.length, 0);
          counts.fillRange(0, counts.length, 0);

          for (int i = 0; i < n; i++) {
            final c = assignments[i];
            counts[c]++;
            final iOff = i * subDim;
            final cOff = c * subDim;
            for (int d = 0; d < subDim; d++) {
              sums[cOff + d] += subData[iOff + d];
            }
          }

          bool changed = false;
          for (int c = 0; c < k; c++) {
            if (counts[c] == 0) continue;
            final cOff = c * subDim;
            final inv = 1.0 / counts[c];
            for (int d = 0; d < subDim; d++) {
              final newVal = sums[cOff + d] * inv;
              if ((centers[cOff + d] - newVal).abs() > 1e-6) changed = true;
              centers[cOff + d] = newVal;
            }
          }
          if (!changed) break;
        }
        data.setRange(m * k * subDim, (m + 1) * k * subDim, centers);
      }
    }

    return PqCodebook(
      subspaces: subspaces,
      centroids: k,
      subDimensions: subDim,
      data: data,
    );
  }

  // =====================================================================
  // Encoding -- Vector -> PQ Code
  // =====================================================================

  /// Encode a single vector to its PQ code (M bytes).
  Uint8List encode(Float32List vector) {
    final code = Uint8List(subspaces);
    for (int m = 0; m < subspaces; m++) {
      final subStart = m * subDimensions;
      final subVec =
          Float32List.sublistView(vector, subStart, subStart + subDimensions);
      code[m] = _nearestCentroid(
              subVec, codebook.data, centroids, subDimensions,
              centroidOffset: m * centroids * subDimensions)
          .toUnsigned(8);
    }
    return code;
  }

  /// Batch-encode multiple vectors. Suitable for isolate offload.
  List<Uint8List> encodeBatch(List<Float32List> vectors) {
    return List.generate(vectors.length, (i) => encode(vectors[i]),
        growable: false);
  }

  // =====================================================================
  // Asymmetric Distance Computation (ADC)
  // =====================================================================

  /// Pre-compute the distance lookup table for a query vector.
  ///
  /// Returns a float32 table of shape [M x K] where
  /// table[m * K + k] = L2^2(query_sub_m, centroid[m][k]).
  ///
  /// This is computed ONCE per query, then reused for all candidate comparisons.
  Float32List buildDistanceTable(Float32List query) {
    final table = Float32List(subspaces * centroids);
    for (int m = 0; m < subspaces; m++) {
      final subStart = m * subDimensions;
      final qSub =
          Float32List.sublistView(query, subStart, subStart + subDimensions);
      final tableOff = m * centroids;
      final cbOff = m * centroids * subDimensions;

      for (int k = 0; k < centroids; k++) {
        double dist = 0;
        final cOff = cbOff + k * subDimensions;
        for (int d = 0; d < subDimensions; d++) {
          final diff = qSub[d] - codebook.data[cOff + d];
          dist += diff * diff;
        }
        table[tableOff + k] = dist;
      }
    }
    return table;
  }

  /// Compute approximate L2^2 distance using pre-computed distance table.
  ///
  /// This is the hot inner loop during beam search -- must be as fast as possible.
  /// Cost: M additions + M table lookups. Uses incremental offset to eliminate
  /// the per-subspace multiplication (`m * centroids`).
  double adcDistance(Float32List distTable, Uint8List pqCode) {
    double dist = 0;
    int tableOff = 0;
    for (int m = 0; m < subspaces; m++) {
      dist += distTable[tableOff + pqCode[m]];
      tableOff += centroids;
    }
    return dist;
  }

  /// Compute ADC distance for inner-product metric.
  /// The distance table should contain negative inner products.
  double adcDistanceIP(Float32List distTable, Uint8List pqCode) {
    return adcDistance(distTable, pqCode);
  }

  /// Build distance table for inner-product metric (negated for min-heap).
  Float32List buildDistanceTableIP(Float32List query) {
    final table = Float32List(subspaces * centroids);
    for (int m = 0; m < subspaces; m++) {
      final subStart = m * subDimensions;
      final qSub =
          Float32List.sublistView(query, subStart, subStart + subDimensions);
      final tableOff = m * centroids;
      final cbOff = m * centroids * subDimensions;

      for (int k = 0; k < centroids; k++) {
        double ip = 0;
        final cOff = cbOff + k * subDimensions;
        for (int d = 0; d < subDimensions; d++) {
          ip += qSub[d] * codebook.data[cOff + d];
        }
        table[tableOff + k] = -ip; // negate so min-heap works
      }
    }
    return table;
  }

  /// Build distance table for cosine metric.
  /// Assumes vectors are pre-normalised; falls back to L2 distance which
  /// is monotonically equivalent to cosine for unit vectors.
  Float32List buildDistanceTableCosine(Float32List query) {
    // For normalised vectors: L2^2 = 2 - 2*cos(theta), so ranking is equivalent.
    return buildDistanceTable(query);
  }

  /// Find the nearest centroid index for a sub-vector.
  static int _nearestCentroid(
    Float32List subVec,
    Float32List allCentroids,
    int k,
    int subDim, {
    int centroidOffset = 0,
  }) {
    int bestIdx = 0;
    double bestDist = double.infinity;
    for (int c = 0; c < k; c++) {
      double dist = 0;
      final cOff = centroidOffset + c * subDim;
      for (int d = 0; d < subDim; d++) {
        final diff = subVec[d] - allCentroids[cOff + d];
        dist += diff * diff;
      }
      if (dist < bestDist) {
        bestDist = dist;
        bestIdx = c;
      }
    }
    return bestIdx;
  }
}

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
