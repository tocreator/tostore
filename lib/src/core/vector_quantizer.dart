import 'dart:math';
import 'dart:typed_data';

// ============================================================================
// Product Quantization (PQ) for NGH Vector Index
//
// PQ divides a D-dimensional vector into M sub-vectors of D/M dimensions each.
// Each sub-vector is independently quantised to K centroids (K=256, 1 byte).
// This gives 32× compression (float32→uint8) while enabling fast Asymmetric
// Distance Computation (ADC) during search.
// ============================================================================

/// Trained PQ codebook: M sub-spaces × K centroids × (D/M) dimensions.
///
/// Layout: centroids[m * K * subDim + k * subDim + d] = float32
/// where m ∈ [0,M), k ∈ [0,K), d ∈ [0,subDim).
class PqCodebook {
  /// Number of sub-spaces (M).
  final int subspaces;

  /// Number of centroids per sub-space (K), typically 256.
  final int centroids;

  /// Dimensions per sub-space (D / M).
  final int subDimensions;

  /// Flat centroid data: M × K × subDim float32 values.
  final Float32List data;

  PqCodebook({
    required this.subspaces,
    required this.centroids,
    required this.subDimensions,
    required this.data,
  });

  /// Total vector dimensions: M × subDim.
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

  int get subspaces => codebook.subspaces;
  int get subDimensions => codebook.subDimensions;
  int get centroids => codebook.centroids;

  /// Total vector dimensions: M × subDim.
  int get dimensions => codebook.dimensions;

  // =====================================================================
  // Training — K-means per sub-space
  // =====================================================================

  /// Train a PQ codebook from sample vectors.
  ///
  /// Runs K-means independently on each sub-space. Should be executed in an
  /// isolate for large sample sets via [ComputeManager].
  ///
  /// [samples]    — training vectors (each must be [dimensions]-dimensional).
  /// [dimensions] — total vector dimensions D.
  /// [subspaces]  — number of sub-spaces M. Must evenly divide D.
  /// [numCentroids] — centroids per sub-space K (default 256).
  /// [iterations] — K-means iterations (default 20).
  static Future<PqCodebook> train({
    required List<Float32List> samples,
    required int dimensions,
    required int subspaces,
    int numCentroids = 256,
    int iterations = 10, // Reduced from 20
  }) async {
    if (samples.isEmpty) {
      throw ArgumentError('Training requires at least one sample vector');
    }
    if (dimensions % subspaces != 0) {
      throw ArgumentError(
          'Dimensions ($dimensions) must be divisible by subspaces ($subspaces)');
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
  // Encoding — Vector → PQ Code
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
  /// Returns a float32 table of shape [M × K] where
  /// table[m * K + k] = L2²(query_sub_m, centroid[m][k]).
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

  /// Compute approximate L2² distance using pre-computed distance table.
  ///
  /// This is the hot inner loop during beam search — must be as fast as possible.
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
    // For normalised vectors: L2² = 2 - 2·cos(θ), so ranking is equivalent.
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
