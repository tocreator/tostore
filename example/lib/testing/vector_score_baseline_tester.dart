import 'dart:math';
import 'dart:typed_data';

import 'package:tostore/tostore.dart';

/// Target physical-cosine checkpoints (`1%`..`99%` plus `100%` self-match).
///
/// Probes are synthesized so true cosine to the anchor equals the target.
/// On high-D tables (`>= [kScoreCosineFidelityMinDim]`) the public `score`
/// must track that cosine within [kMaxBaselineDeviationPctPoints].
const List<double> kRelevanceBaselineTargets = <double>[
  0.01,
  0.10,
  0.20,
  0.30,
  0.40,
  0.50,
  0.60,
  0.70,
  0.80,
  0.90,
  0.99,
  1.00,
];

/// Max allowed `|meanScore - plantedCos| * 100` on high-D fidelity tables
/// (10 pct points => 0.10 on the `[0.0, 1.0]` score scale).
const double kMaxBaselineDeviationPctPoints = 10.0;

/// Dimensions at/above which published relevance bands and Gate A FPR are
/// hard requirements. Below this, `|score - cos|` still tracks (identity
/// mapping) but OOD inflation is advisory only.
const int kScoreCosineFidelityMinDim = 128;

/// Published RAG / usable-relevance floor used by band contracts on `score`.
const double kRagScoreFloor = 0.40;

/// Evaluation outcome of one relevance checkpoint on the live table.
enum RelevanceCheckpointStatus {
  /// Anchor recalled; mean score within [kMaxBaselineDeviationPctPoints].
  pass,

  /// Outranked by closer live records, or wide-angle probe missed ANN beam.
  dense,

  /// Score outside budget, or high-confidence (`>= 0.70`) recall failed.
  fail,
}

/// Per-checkpoint diagnostic result for one target normalized relevance level.
class RelevanceLevelCheckResult {
  final int dimensions;
  final double expectedScore;
  final double meanScore;
  final double minScore;
  final double maxScore;
  final double meanRawScore;
  final double maxRawScoreError;
  final int recalledCount;
  final int pairedRecalledCount;
  final int outrankedCount;
  final int annMissCount;
  final int totalProbes;
  final double? outrankedFloorScore;

  const RelevanceLevelCheckResult({
    required this.dimensions,
    required this.expectedScore,
    required this.meanScore,
    required this.minScore,
    required this.maxScore,
    required this.meanRawScore,
    required this.maxRawScoreError,
    required this.recalledCount,
    required this.pairedRecalledCount,
    required this.outrankedCount,
    required this.annMissCount,
    required this.totalProbes,
    this.outrankedFloorScore,
  });

  /// Whether this dimension enforces `|score - plantedCos|` fidelity.
  bool get enforcesScoreCosineFidelity =>
      dimensions >= kScoreCosineFidelityMinDim;

  double get allowedDeviationPctPoints => kMaxBaselineDeviationPctPoints;

  /// Signed deviation in percentage points (`(meanScore - expectedScore) * 100`).
  double get signedDiffPctPoints =>
      recalledCount > 0 ? (meanScore - expectedScore) * 100.0 : 0.0;

  /// Absolute deviation in percentage points.
  double get absDiffPctPoints => signedDiffPctPoints.abs();

  /// Probes where the target anchor was NOT outranked by `topK` closer records.
  int get eligibleProbes => max(0, totalProbes - outrankedCount);

  RelevanceCheckpointStatus get status {
    if (totalProbes <= 0) return RelevanceCheckpointStatus.fail;
    if (recalledCount == 0) {
      // Wide-angle probes (< 0.70) sit 45..82 deg from cluster centroids where
      // approximate beam search naturally stays in closer leaves; high-confidence
      // probes (>= 0.70) may only miss if genuinely outranked by topK records.
      if (outrankedCount == totalProbes || expectedScore < 0.70) {
        return RelevanceCheckpointStatus.dense;
      }
      return RelevanceCheckpointStatus.fail;
    }
    if (expectedScore >= 0.70 &&
        eligibleProbes >= 4 &&
        recalledCount * 2 < eligibleProbes) {
      return RelevanceCheckpointStatus.fail;
    }
    // Below the published band surface: score still tracks cosine (identity),
    // but absolute fidelity is diagnostic-only (Gate A is advisory there).
    if (!enforcesScoreCosineFidelity) {
      return RelevanceCheckpointStatus.pass;
    }
    // Sparse recall soft-pass only below the RAG floor. At/above 0.40 the
    // published anti-hallucination bands need hard |score-cos| fidelity.
    if (expectedScore < kRagScoreFloor &&
        expectedScore < 1.0 &&
        pairedRecalledCount == 0 &&
        recalledCount <= 2 &&
        absDiffPctPoints > allowedDeviationPctPoints) {
      return RelevanceCheckpointStatus.dense;
    }
    return absDiffPctPoints <= allowedDeviationPctPoints
        ? RelevanceCheckpointStatus.pass
        : RelevanceCheckpointStatus.fail;
  }

  bool get passed => status != RelevanceCheckpointStatus.fail;
}

/// Adversarial out-of-distribution (OOD) anti-hallucination gate summary.
class OodNoiseAuditSummary {
  final int queryCount;
  final double p50Top1Score;
  final double p95Top1Score;
  final double maxTop1Score;
  final int countGe30;
  final int falseInflationsGe40;
  final bool geomSaturated;
  final double theoreticalPackingCosine;

  const OodNoiseAuditSummary({
    required this.queryCount,
    required this.p50Top1Score,
    required this.p95Top1Score,
    required this.maxTop1Score,
    required this.countGe30,
    required this.falseInflationsGe40,
    required this.geomSaturated,
    required this.theoreticalPackingCosine,
  });

  /// Unrelated Top-1 must not clear the RAG band. Geometric saturation is
  /// diagnostic only and must never auto-PASS away true false inflation.
  bool get passed => falseInflationsGe40 == 0;
}

/// Black-box physical perturbation & non-unit scale-invariance gate summary.
class PhysicalPerturbationAuditSummary {
  final int positiveChecks;
  final int positiveFailures;
  final int positiveMisses;
  final int orthogonalChecks;
  final int orthogonalLeaksGe10;
  final int scaleChecks;
  final int scaleViolations;
  final double maxScaleDriftPctPoints;
  final double maxPositiveAbsError;

  /// Plants below [kRagScoreFloor] that reported score >= floor
  final int ragCrossInflations;

  /// Plants above [kRagScoreFloor] that reported score < floor
  final int ragCrossDeflations;

  const PhysicalPerturbationAuditSummary({
    required this.positiveChecks,
    required this.positiveFailures,
    required this.positiveMisses,
    required this.orthogonalChecks,
    required this.orthogonalLeaksGe10,
    required this.scaleChecks,
    required this.scaleViolations,
    required this.maxScaleDriftPctPoints,
    required this.maxPositiveAbsError,
    this.ragCrossInflations = 0,
    this.ragCrossDeflations = 0,
  });

  bool get passed =>
      positiveChecks > 0 &&
      positiveFailures == 0 &&
      orthogonalLeaksGe10 == 0 &&
      scaleViolations == 0 &&
      ragCrossInflations == 0 &&
      ragCrossDeflations == 0;
}

/// Read-only hybrid fusion invariant summary (Gate C lite).
class HybridFusionAuditSummary {
  final bool dominantFloorPassed;
  final bool dualNoisePassed;
  final bool corroborationPassed;
  final double? dominantFloorScore;
  final double? dualNoiseMaxScore;
  final String detail;

  const HybridFusionAuditSummary({
    required this.dominantFloorPassed,
    required this.dualNoisePassed,
    required this.corroborationPassed,
    this.dominantFloorScore,
    this.dualNoiseMaxScore,
    this.detail = '',
  });

  bool get passed =>
      dominantFloorPassed && dualNoisePassed && corroborationPassed;
}

/// Complete read-only report for live-table relevance baseline verification.
class VectorBaselineTestReport {
  final String tableName;
  final int dimensions;
  final VectorDistanceMetric metric;
  final int liveCorpusSize;
  final int sampledAnchors;
  final int searchDepth;
  final int probeTopK;
  final OodNoiseAuditSummary oodAudit;
  final PhysicalPerturbationAuditSummary physicalAudit;
  final List<RelevanceLevelCheckResult> levelResults;
  final int liveRankInversions;
  final int liveCutoffChecks;
  final int liveCutoffViolations;
  final bool? hybridCheckPassed;
  final HybridFusionAuditSummary? hybridAudit;
  final double elapsedMs;

  const VectorBaselineTestReport({
    required this.tableName,
    required this.dimensions,
    required this.metric,
    required this.liveCorpusSize,
    required this.sampledAnchors,
    required this.searchDepth,
    required this.probeTopK,
    required this.oodAudit,
    required this.physicalAudit,
    required this.levelResults,
    required this.liveRankInversions,
    required this.liveCutoffChecks,
    required this.liveCutoffViolations,
    required this.hybridCheckPassed,
    this.hybridAudit,
    required this.elapsedMs,
  });

  bool get hasRecalledCheckpoints =>
      levelResults.any((r) => r.recalledCount > 0);

  double get checkpointBudgetPctPoints => kMaxBaselineDeviationPctPoints;

  bool get allPassed {
    final oodRequired = dimensions >= kScoreCosineFidelityMinDim;
    return (!oodRequired || oodAudit.passed) &&
        physicalAudit.passed &&
        hasRecalledCheckpoints &&
        levelResults.every((r) => r.passed) &&
        liveRankInversions == 0 &&
        liveCutoffViolations == 0 &&
        (hybridCheckPassed ?? true) &&
        (hybridAudit?.passed ?? true);
  }

  double get worstAnchorDiffPctPoints {
    var worst = 0.0;
    for (final r in levelResults) {
      if (r.status == RelevanceCheckpointStatus.pass &&
          r.absDiffPctPoints > worst) {
        worst = r.absDiffPctPoints;
      }
    }
    return worst;
  }

  String formatSummary() {
    final metricLabel = switch (metric) {
      VectorDistanceMetric.cosine => 'Cosine',
      VectorDistanceMetric.l2 => 'L2',
      VectorDistanceMetric.innerProduct => 'InnerProduct',
    };
    final fidelityEnforced = dimensions >= kScoreCosineFidelityMinDim;
    final scoreDevNote = fidelityEnforced
        ? 'limit <= ${checkpointBudgetPctPoints.toStringAsFixed(0)}%'
        : 'D<128 diagnostic (bands recommended for D>=128)';
    final sb = StringBuffer()
      ..writeln(
        '[Relevance Baseline] ${allPassed ? "PASS" : "FAIL"} | '
        'table=$tableName (${dimensions}D $metricLabel, rows=$liveCorpusSize, read-only) | '
        'anchors=$sampledAnchors, depth=$searchDepth, topK=$probeTopK | '
        'maxScoreDev=${worstAnchorDiffPctPoints.toStringAsFixed(2)}% '
        '($scoreDevNote) | '
        '${elapsedMs.toStringAsFixed(1)} ms',
      );

    // Gate 1: Adversarial OOD Anti-Hallucination Audit
    final oodHard = fidelityEnforced;
    final oodLabel = !oodHard
        ? (oodAudit.passed ? 'PASS (advisory)' : 'FAIL (advisory; D<128)')
        : (oodAudit.passed ? 'PASS' : 'FAIL');
    final oodGeomNote = oodAudit.geomSaturated
        ? ', geom_saturated(packingCos=${oodAudit.theoreticalPackingCosine.toStringAsFixed(4)}; diagnostic only)'
        : '';
    sb.writeln(
      '[Gate A: OOD Noise Anti-Hallucination] $oodLabel | '
      'queries=${oodAudit.queryCount}, '
      'top1_p50=${oodAudit.p50Top1Score.toStringAsFixed(4)}, '
      'top1_p95=${oodAudit.p95Top1Score.toStringAsFixed(4)}, '
      'top1_max=${oodAudit.maxTop1Score.toStringAsFixed(4)}, '
      '>=0.30=${oodAudit.countGe30}/${oodAudit.queryCount}, '
      'false_inflation(>=0.40)=${oodAudit.falseInflationsGe40}'
      '$oodGeomNote',
    );

    // Gate 2: Physical Perturbation & Scale-Invariance Audit
    final fidelityMode =
        fidelityEnforced ? '|score-cos|<=0.10' : 'self/order/near-dup (D<128)';
    sb.writeln(
      '[Gate B: Physical Positive & Scale Gate] '
      '${physicalAudit.passed ? "PASS" : "FAIL"} | '
      'mode=$fidelityMode | '
      'positives=${physicalAudit.positiveChecks - physicalAudit.positiveFailures}/${physicalAudit.positiveChecks} '
      '(plant cos=0.40/0.70, '
      'miss=${physicalAudit.positiveMisses}, '
      'max|Δ|=${(physicalAudit.maxPositiveAbsError * 100).toStringAsFixed(2)}pct_pt) | '
      'rag_cross(inf=${physicalAudit.ragCrossInflations}, '
      'def=${physicalAudit.ragCrossDeflations}) | '
      'ortho_rejected=${physicalAudit.orthogonalChecks - physicalAudit.orthogonalLeaksGe10}/${physicalAudit.orthogonalChecks}, '
      'scale_0.25x_vs_4x=${physicalAudit.scaleChecks - physicalAudit.scaleViolations}/${physicalAudit.scaleChecks} '
      '(maxDrift=${physicalAudit.maxScaleDriftPctPoints.toStringAsFixed(4)}%)',
    );

    if (hybridAudit != null) {
      final h = hybridAudit!;
      sb.writeln(
        '[Gate C: Hybrid Fusion Invariants] '
        '${h.passed ? "PASS" : "FAIL"} | '
        'dominant_floor=${h.dominantFloorPassed}'
        '${h.dominantFloorScore == null ? "" : "(score=${h.dominantFloorScore!.toStringAsFixed(4)})"}, '
        'dual_noise=${h.dualNoisePassed}'
        '${h.dualNoiseMaxScore == null ? "" : "(max=${h.dualNoiseMaxScore!.toStringAsFixed(4)})"}, '
        'corroboration=${h.corroborationPassed}'
        '${h.detail.isEmpty ? "" : " | ${h.detail}"}',
      );
    }

    // Diagnostic Table: 1%..100% SQ8 Quantization & Transparent Recall Report
    sb.writeln(
      'target | mean_score | diff(pct_pt) |   min..max_score  | '
      'mean_raw  | hits/probes | recall_detail / status',
    );

    for (final r in levelResults) {
      final targetCol =
          '${(r.expectedScore * 100).toStringAsFixed(0)}%'.padLeft(6);
      final recallCol = '${r.recalledCount}/${r.totalProbes}'.padLeft(11);
      final missDetail = (r.outrankedCount > 0 || r.annMissCount > 0)
          ? ' [outranked=${r.outrankedCount}, ann_miss=${r.annMissCount}]'
          : '';
      if (r.recalledCount == 0) {
        final floorText = r.outrankedFloorScore != null
            ? 'outranked(>=${(r.outrankedFloorScore! * 100).toStringAsFixed(1)}%)'
            : 'wide-angle';
        final st =
            r.status == RelevanceCheckpointStatus.dense ? 'DENSE' : 'FAIL';
        sb.writeln(
          '$targetCol |        n/a |          n/a |               n/a | '
          '      n/a | $recallCol | $st [$floorText]$missDetail',
        );
        continue;
      }
      final meanCol = r.meanScore.toStringAsFixed(5).padLeft(10);
      final sign = r.signedDiffPctPoints >= 0 ? '+' : '';
      final diffCol =
          '$sign${r.signedDiffPctPoints.toStringAsFixed(4)}%'.padLeft(12);
      final rangeCol =
          '${r.minScore.toStringAsFixed(4)}..${r.maxScore.toStringAsFixed(4)}'
              .padLeft(17);
      final rawCol = r.meanRawScore.toStringAsFixed(4).padLeft(9);
      final statusLabel = switch (r.status) {
        RelevanceCheckpointStatus.pass => 'PASS',
        RelevanceCheckpointStatus.dense => 'DENSE',
        RelevanceCheckpointStatus.fail => 'FAIL',
      };
      sb.writeln(
        '$targetCol | $meanCol | $diffCol | $rangeCol | '
        '$rawCol | $recallCol | $statusLabel$missDetail',
      );
    }

    sb.writeln(
      'Contract & cutoff gate: '
      'order_inversions=$liveRankInversions, '
      'minScore_cutoffs=$liveCutoffChecks (violations=$liveCutoffViolations)'
      '${hybridCheckPassed == null ? "" : ", hybrid_fusion=${hybridCheckPassed! ? "PASS" : "FAIL"}"}'
      '${hybridAudit == null ? "" : ", gate_c=${hybridAudit!.passed ? "PASS" : "FAIL"}"}',
    );
    return sb.toString().trimRight();
  }
}

class _AnchorSample {
  final String pk;
  final Float64List vector;
  const _AnchorSample(this.pk, this.vector);
}

class _UnresolvedProbe {
  final int levelIndex;
  final Float64List query;
  final String boundaryPk;
  final bool fullTopKReturned;
  const _UnresolvedProbe({
    required this.levelIndex,
    required this.query,
    required this.boundaryPk,
    required this.fullTopKReturned,
  });
}

class _OodWitness {
  final Float64List query;
  final String? topPk;
  final double reportedScore;
  const _OodWitness({
    required this.query,
    required this.topPk,
    required this.reportedScore,
  });
}

/// Read-only adversarial & SQ8 relevance baseline verifier.
///
/// Keeps existing table data 100% untouched. Black-box checks only:
/// - **Gate A**: Random OOD probes; unrelated Top-1 must not clear
///   [kRagScoreFloor] (hard for `D >= [kScoreCosineFidelityMinDim]`,
///   advisory below).
/// - **Gate B**: Plants at physical cos `0.40` / `0.70` with
///   `|score - cos| <= 0.10` when `D >= [kScoreCosineFidelityMinDim]`,
///   plus RAG cross-threshold plants at `0.30` / `0.50`.
///   Below that: self≈1, near-dup / order checks (packing-dense tables).
/// - **Gate C lite**: Hybrid fusion invariants when a text index exists
///   (dominant floor, dual-noise anti-hallucination, bounded corroboration).
/// - **Diagnostic table**: Plants at physical cosine = target; fidelity
///   budget hard for `D >= 128`, diagnostic below.
class VectorScoreBaselineTester {
  VectorScoreBaselineTester._();

  /// High-D fidelity plant anchors (physical cosine ≈ score under identity).
  static const double _gateBRagCos = 0.40;
  static const double _gateBHighConfCos = 0.70;

  static int _adaptiveAnchorCount(int dimensions) {
    if (dimensions <= 128) return 8;
    if (dimensions <= 1536) return 6;
    if (dimensions <= 8192) return 4;
    return 2;
  }

  /// Executes the read-only adversarial + SQ8 baseline test on [tableName].
  static Future<VectorBaselineTestReport?> run({
    required ToStore db,
    required String tableName,
    int searchDepth = 50,
    int topK = 10,
    void Function(int completedSteps, int totalSteps)? onProgress,
    void Function(String message)? onLog,
  }) async {
    final sw = Stopwatch()..start();
    var lastYieldMs = 0;
    Future<void> maybeYield() async {
      final now = sw.elapsedMilliseconds;
      if (now - lastYieldMs >= 8) {
        await Future<void>.delayed(Duration.zero);
        lastYieldMs = sw.elapsedMilliseconds;
      }
    }

    final schema = await db.getTableSchema(tableName);
    if (schema == null) {
      onLog?.call(
        'Relevance baseline failed: schema for "$tableName" was not found.',
      );
      return null;
    }

    String? resolvedVectorField;
    int resolvedDimensions = 0;
    for (final f in schema.fields) {
      if (f.type == DataType.vector && f.vectorConfig != null) {
        resolvedVectorField = f.name;
        resolvedDimensions = f.vectorConfig!.dimensions;
        break;
      }
    }
    if (resolvedVectorField == null || resolvedDimensions <= 0) {
      onLog?.call(
        'Relevance baseline failed: table "$tableName" has no vector field.',
      );
      return null;
    }
    final String vectorField = resolvedVectorField;
    final int dimensions = resolvedDimensions;

    VectorDistanceMetric resolvedMetric = VectorDistanceMetric.cosine;
    final textFields = <String>[];
    for (final idx in schema.indexes) {
      if (idx.type == IndexType.vector &&
          idx.fields.contains(vectorField) &&
          idx.vectorConfig != null) {
        resolvedMetric = idx.vectorConfig!.distanceMetric;
      } else if (idx.type == IndexType.text && idx.fields.isNotEmpty) {
        textFields.add(idx.fields.first);
      }
    }
    final VectorDistanceMetric metric = resolvedMetric;

    final pkField = schema.primaryKeyConfig.name;
    final liveCount = await db.query(tableName).count();
    if (liveCount <= 0) {
      onLog?.call(
        'Relevance baseline skipped: table "$tableName" is empty. '
        'Insert vector records first.',
      );
      return null;
    }

    final effectiveDepth = max(1, searchDepth);
    final wideAngleDepth = max(effectiveDepth, 85);
    final probeTopK = min(liveCount, max(topK, 20));
    final wantAnchors = min(liveCount, _adaptiveAnchorCount(dimensions));
    final poolTarget = dimensions > 8192
        ? min(liveCount, wantAnchors * 2)
        : min(liveCount, max(wantAnchors * 3, 24));

    final vectorCache = <String, Float64List>{};
    final pool = await _sampleLivePool(
      db: db,
      tableName: tableName,
      pkField: pkField,
      vectorField: vectorField,
      dimensions: dimensions,
      liveCount: liveCount,
      targetPoolSize: poolTarget,
    );
    if (pool.isEmpty) {
      onLog?.call(
        'Relevance baseline skipped: no non-null valid vectors found in "$tableName".',
      );
      return null;
    }

    final norms = <double>[];
    for (final item in pool) {
      vectorCache[item.pk] = item.vector;
      final n = _norm(item.vector);
      if (n > 1e-12) norms.add(n);
      await maybeYield();
    }
    norms.sort();
    final double medianNorm = norms.isEmpty ? 1.0 : norms[norms.length >> 1];

    final anchors =
        pool.length <= wantAnchors ? pool : pool.sublist(0, wantAnchors);

    // Estimate empirical mean direction of sampled corpus.
    final unitPool = <Float64List>[];
    final meanDir = Float64List(dimensions);
    for (final item in pool) {
      final n = _norm(item.vector);
      if (n <= 1e-12) continue;
      final u = _scale(item.vector, 1.0 / n);
      unitPool.add(u);
      for (int d = 0; d < dimensions; d++) {
        meanDir[d] += u[d];
      }
      await maybeYield();
    }
    final meanNorm = _norm(meanDir);
    final Float64List? unitMean =
        meanNorm > 1e-9 ? _scale(meanDir, 1.0 / meanNorm) : null;

    final totalSteps = anchors.length + 2;
    var doneSteps = 0;
    onProgress?.call(doneSteps, totalSteps);

    final rng = Random(20261031 ^ (dimensions * 131) ^ liveCount);
    final missingPks = <String>{};
    int orderInversions = 0;

    void checkOrdering(List<RetrievalEntry> entries) {
      for (int h = 1; h < entries.length; h++) {
        if (metric == VectorDistanceMetric.cosine) {
          if (entries[h].score > entries[h - 1].score + 1e-6) {
            orderInversions++;
          }
        } else {
          final prevDist =
              (entries[h - 1].meta?['distance'] as num?)?.toDouble();
          final curDist = (entries[h].meta?['distance'] as num?)?.toDouble();
          if (prevDist != null &&
              curDist != null &&
              curDist + 1e-5 < prevDist) {
            orderInversions++;
          }
        }
      }
    }

    // =========================================================================
    // Gate A: Adversarial Out-of-Distribution (OOD) Anti-Hallucination Audit
    // =========================================================================
    final int oodTargetCount = dimensions > 8192 ? 12 : 24;
    final oodQueries = <Float64List>[];
    const normMultipliers = <double>[1.0, 0.25, 4.0];

    if (dimensions >= 2) {
      final int isoCount = unitMean != null && dimensions >= 16
          ? (oodTargetCount * 2) ~/ 3
          : oodTargetCount;
      for (int i = 0; i < isoCount; i++) {
        final u = _randomGaussianUnit(dimensions, rng);
        final scaleFactor =
            medianNorm * normMultipliers[i % normMultipliers.length];
        oodQueries.add(_scale(u, scaleFactor));
      }
      while (oodQueries.length < oodTargetCount && unitMean != null) {
        // Simulate unrelated text sharing a mild 0.14 anisotropic background cone.
        final g = _randomGaussianUnit(dimensions, rng);
        final proj = _dot(g, unitMean);
        final ortho = Float64List(dimensions);
        for (int d = 0; d < dimensions; d++) {
          ortho[d] = g[d] - proj * unitMean[d];
        }
        final on = _norm(ortho);
        if (on <= 1e-12) continue;
        const cone = 0.14;
        final perp = sqrt(1.0 - cone * cone);
        final q = Float64List(dimensions);
        final mult = medianNorm *
            normMultipliers[oodQueries.length % normMultipliers.length];
        for (int d = 0; d < dimensions; d++) {
          q[d] = mult * (cone * unitMean[d] + perp * (ortho[d] / on));
        }
        oodQueries.add(q);
      }
      if (metric == VectorDistanceMetric.l2) {
        // Explicit 8x large-norm & 0.005x tiny-norm OOD distractors:
        // asymmetric ||q||-only L2 formulas falsely score 8x orthogonal queries > 0.45!
        for (int i = 0; i < 4; i++) {
          final u = _randomGaussianUnit(dimensions, rng);
          oodQueries.add(
            _scale(u, medianNorm * (i.isEven ? 8.0 : 0.005)),
          );
        }
      }
    } else if (metric == VectorDistanceMetric.l2) {
      oodQueries.add(Float64List.fromList(<double>[0.0]));
    }

    final oodWitnesses = <_OodWitness>[];
    for (final q in oodQueries) {
      final qr = await db
          .query(tableName)
          .select([pkField])
          .matchVector(
            vectorField,
            VectorData(q),
            searchDepth: wideAngleDepth,
          )
          .limit(min(5, probeTopK));
      final entries = qr.retrieval?.entries ?? const <RetrievalEntry>[];
      checkOrdering(entries);
      final topPk =
          qr.data.isNotEmpty ? qr.data.first[pkField]?.toString() : null;
      final topScore = entries.isNotEmpty ? entries.first.score : 0.0;
      oodWitnesses.add(_OodWitness(
        query: q,
        topPk: topPk,
        reportedScore: topScore,
      ));
      if (topPk != null && !vectorCache.containsKey(topPk)) {
        missingPks.add(topPk);
      }
      await maybeYield();
    }

    // =========================================================================
    // Gate B: Black-Box Physical Perturbation & Non-Unit Scale-Invariance Gate
    // =========================================================================
    int positiveChecks = 0;
    int positiveFailures = 0;
    int positiveMisses = 0;
    int orthogonalChecks = 0;
    int orthogonalLeaksGe10 = 0;
    int scaleChecks = 0;
    int scaleViolations = 0;
    int ragCrossInflations = 0;
    int ragCrossDeflations = 0;
    double maxScaleDriftPct = 0.0;
    double maxPositiveAbsError = 0.0;
    final fidelityAbs = kMaxBaselineDeviationPctPoints / 100.0;
    final enforceCosineFidelity = dimensions >= kScoreCosineFidelityMinDim;
    // Cross-threshold plants around the published RAG floor.
    const belowRagCos = 0.30;
    const aboveRagCos = 0.50;

    final gateAnchors = anchors.length <= 4 ? anchors : anchors.sublist(0, 4);
    for (final sample in gateAnchors) {
      final a = sample.vector;
      final aNorm = _norm(a);
      if (aNorm <= 1e-12) continue;
      final unitA = _scale(a, 1.0 / aNorm);
      final ortho = dimensions >= 2
          ? _buildClusterAwareOrthogonalUnit(
              unitAnchor: unitA,
              localNeighbors: const <Float64List>[],
              unitMean: unitMean,
              unitPool: unitPool,
              rng: rng,
            )
          : null;

      Future<double?> scoreOfAnchor(
        Float64List qVec, {
        int? customDepth,
      }) async {
        final qr = await db
            .query(tableName)
            .select([pkField])
            .matchVector(
              vectorField,
              VectorData(qVec),
              searchDepth: customDepth ?? effectiveDepth,
            )
            .limit(probeTopK);
        final entries = qr.retrieval?.entries ?? const <RetrievalEntry>[];
        checkOrdering(entries);
        final n = min(qr.data.length, entries.length);
        for (int i = 0; i < n; i++) {
          if (qr.data[i][pkField]?.toString() == sample.pk) {
            return entries[i].score;
          }
        }
        return null;
      }

      if (dimensions >= 2 && ortho != null) {
        // 1) Near-orthogonal probe: when Top-1 is truly near-orthogonal
        //    (cos <= 0.08), reported score must stay in the weak-noise band (< 0.10).
        final qOrtho = _scale(ortho, aNorm);
        final orthoQr = await db
            .query(tableName)
            .select([pkField])
            .matchVector(
              vectorField,
              VectorData(qOrtho),
              searchDepth: wideAngleDepth,
            )
            .limit(min(5, probeTopK));
        final orthoEntries =
            orthoQr.retrieval?.entries ?? const <RetrievalEntry>[];
        checkOrdering(orthoEntries);
        if (orthoQr.data.isNotEmpty && orthoEntries.isNotEmpty) {
          final topOrthoPk = orthoQr.data.first[pkField]?.toString();
          if (topOrthoPk != null) {
            var topVec = vectorCache[topOrthoPk];
            if (topVec == null) {
              final fetched = await _fetchVectorsByPk(
                db: db,
                tableName: tableName,
                pkField: pkField,
                vectorField: vectorField,
                dimensions: dimensions,
                pks: <String>[topOrthoPk],
              );
              vectorCache.addAll(fetched);
              topVec = vectorCache[topOrthoPk];
            }
            if (topVec != null) {
              final tn = _norm(topVec);
              final cos = tn > 1e-12
                  ? (_dot(qOrtho, topVec) / (aNorm * tn)).clamp(-1.0, 1.0)
                  : 0.0;
              // Only judge orthogonal rejection when Top-1 is genuinely near-orthogonal.
              if (cos <= 0.08) {
                orthogonalChecks++;
                if (orthoEntries.first.score >= 0.10) {
                  orthogonalLeaksGe10++;
                }
              }
            }
          }
        }

        // 2) Exact-cosine plants (orthogonal complement).
        Float64List buildAtCos(double c, double norm) {
          final perp = sqrt(max(0.0, 1.0 - c * c));
          final out = Float64List(dimensions);
          for (int d = 0; d < dimensions; d++) {
            out[d] = norm * (c * unitA[d] + perp * ortho[d]);
          }
          return out;
        }

        if (enforceCosineFidelity) {
          void judgeHighD(double? score, double plantedCos) {
            positiveChecks++;
            if (score == null) {
              positiveMisses++;
              positiveFailures++;
              return;
            }
            final absErr = (score - plantedCos).abs();
            if (absErr > maxPositiveAbsError) maxPositiveAbsError = absErr;
            if (absErr > fidelityAbs) positiveFailures++;
          }

          final qRag = buildAtCos(_gateBRagCos, aNorm);
          final sRag = await scoreOfAnchor(qRag, customDepth: wideAngleDepth);
          judgeHighD(sRag, _gateBRagCos);

          final qHigh = buildAtCos(_gateBHighConfCos, aNorm);
          final sHigh = await scoreOfAnchor(qHigh);
          judgeHighD(sHigh, _gateBHighConfCos);

          // Cross-threshold: true cos below RAG must not clear the floor
          // (虚高 → hallucination); true cos above RAG must not fall under
          // (虚低 → false discard).
          final qBelow = buildAtCos(belowRagCos, aNorm);
          final sBelow =
              await scoreOfAnchor(qBelow, customDepth: wideAngleDepth);
          judgeHighD(sBelow, belowRagCos);
          if (sBelow != null && sBelow >= kRagScoreFloor - 1e-9) {
            ragCrossInflations++;
          }

          final qAbove = buildAtCos(aboveRagCos, aNorm);
          final sAbove =
              await scoreOfAnchor(qAbove, customDepth: wideAngleDepth);
          judgeHighD(sAbove, aboveRagCos);
          if (sAbove != null && sAbove < kRagScoreFloor - 1e-9) {
            ragCrossDeflations++;
          }

          if (sRag != null && sHigh != null && sHigh + 1e-9 < sRag) {
            positiveFailures++;
          }
        } else {
          // D<128: packing-dense — self + near-dup / order (not band GT).
          const nearDupCos = 0.995;
          const midCos = 0.85;
          const weakCos = 0.20;

          positiveChecks++;
          final sSelf = await scoreOfAnchor(Float64List.fromList(a));
          if (sSelf == null) {
            positiveMisses++;
            positiveFailures++;
          } else {
            final selfErr = (sSelf - 1.0).abs();
            if (selfErr > maxPositiveAbsError) maxPositiveAbsError = selfErr;
            if (sSelf < 1.0 - fidelityAbs) positiveFailures++;
          }

          final qNear = buildAtCos(nearDupCos, aNorm);
          final qMid = buildAtCos(midCos, aNorm);
          final qWeak = buildAtCos(weakCos, aNorm);
          final sNear = await scoreOfAnchor(qNear);
          final sMid = await scoreOfAnchor(qMid, customDepth: wideAngleDepth);
          final sWeak = await scoreOfAnchor(qWeak, customDepth: wideAngleDepth);

          positiveChecks++;
          if (sNear == null) {
            positiveMisses++;
            positiveFailures++;
          } else {
            final nearErr = (sNear - nearDupCos).abs();
            if (nearErr > maxPositiveAbsError) {
              maxPositiveAbsError = nearErr;
            }
            if (sNear < kRagScoreFloor - 1e-9) positiveFailures++;
          }

          if (sMid != null) {
            positiveChecks++;
            final midErr = (sMid - midCos).abs();
            if (midErr > maxPositiveAbsError) maxPositiveAbsError = midErr;
            if (sNear != null && sNear + 1e-9 < sMid) positiveFailures++;
          }
          if (sWeak != null) {
            positiveChecks++;
            final weakErr = (sWeak - weakCos).abs();
            if (weakErr > maxPositiveAbsError) {
              maxPositiveAbsError = weakErr;
            }
            if (sNear != null && sNear + 1e-9 < sWeak) positiveFailures++;
            if (sMid != null && sMid + 1e-9 < sWeak) positiveFailures++;
          }
        }

        // 3) Scale & reciprocal symmetry gate.
        if (metric == VectorDistanceMetric.cosine ||
            metric == VectorDistanceMetric.innerProduct) {
          final scaleCos = enforceCosineFidelity ? _gateBHighConfCos : 0.995;
          final qSmall = buildAtCos(scaleCos, aNorm * 0.25);
          final qLarge = buildAtCos(scaleCos, aNorm * 4.0);
          final sSmall = await scoreOfAnchor(qSmall);
          final sLarge = await scoreOfAnchor(qLarge);
          scaleChecks++;
          if (sSmall == null || sLarge == null) {
            scaleViolations++;
          } else {
            final driftPct = (sSmall - sLarge).abs() * 100.0;
            if (driftPct > maxScaleDriftPct) maxScaleDriftPct = driftPct;
            final offContract = enforceCosineFidelity
                ? ((sSmall - scaleCos).abs() > fidelityAbs ||
                    (sLarge - scaleCos).abs() > fidelityAbs)
                : (sSmall < kRagScoreFloor - 1e-9 ||
                    sLarge < kRagScoreFloor - 1e-9);
            if (driftPct > 0.50 || offContract) {
              scaleViolations++;
            }
          }
        } else {
          final sHalf = await scoreOfAnchor(_scale(a, 0.5));
          final sDouble = await scoreOfAnchor(_scale(a, 2.0));
          scaleChecks++;
          if (sHalf == null || sDouble == null) {
            scaleViolations++;
          } else {
            final driftPct = (sHalf - sDouble).abs() * 100.0;
            if (driftPct > maxScaleDriftPct) maxScaleDriftPct = driftPct;
            const plantedL2 = 0.80;
            final offContract = enforceCosineFidelity
                ? ((sHalf - plantedL2).abs() > fidelityAbs ||
                    (sDouble - plantedL2).abs() > fidelityAbs)
                : (sHalf < kRagScoreFloor - 1e-9 ||
                    sDouble < kRagScoreFloor - 1e-9);
            if (driftPct > 0.50 || offContract) {
              scaleViolations++;
            }
          }
        }
      }
      await maybeYield();
    }

    doneSteps++;
    onProgress?.call(doneSteps, totalSteps);

    // =========================================================================
    // Diagnostic Table: 1%..100% SQ8 Quantization & Transparent Recall Audit
    // =========================================================================
    final levelCount = kRelevanceBaselineTargets.length;
    final pairSumScore = Float64List(levelCount);
    final pairSumRaw = Float64List(levelCount);
    final pairedRecalled = List<int>.filled(levelCount, 0);

    final allSumScore = Float64List(levelCount);
    final allSumRaw = Float64List(levelCount);
    final minScore = Float64List(levelCount)..fillRange(0, levelCount, 2.0);
    final maxScore = Float64List(levelCount)..fillRange(0, levelCount, -1.0);
    final maxRawErr = Float64List(levelCount);
    final recalled = List<int>.filled(levelCount, 0);
    final probes = List<int>.filled(levelCount, 0);
    final unresolvedProbes = <_UnresolvedProbe>[];

    for (int a = 0; a < anchors.length; a++) {
      final anchorSample = anchors[a];
      final anchor = anchorSample.vector;
      final anchorNorm = _norm(anchor);
      if (anchorNorm <= 1e-12) {
        doneSteps++;
        onProgress?.call(doneSteps, totalSteps);
        continue;
      }
      final unitAnchor = _scale(anchor, 1.0 / anchorNorm);

      final localNeighbors = <Float64List>[];
      if (dimensions >= 3 && liveCount > 1) {
        final localK = min(liveCount, min(16, dimensions - 1));
        final nearHits = await db.vectorSearch(
          tableName,
          fieldName: vectorField,
          queryVector: VectorData(anchor),
          topK: localK,
          searchDepth: effectiveDepth,
        );
        final uncachedNearPks = <String>[];
        for (final h in nearHits) {
          if (h.primaryKey == anchorSample.pk) continue;
          if (!vectorCache.containsKey(h.primaryKey)) {
            uncachedNearPks.add(h.primaryKey);
          }
        }
        if (uncachedNearPks.isNotEmpty) {
          final fetched = await _fetchVectorsByPk(
            db: db,
            tableName: tableName,
            pkField: pkField,
            vectorField: vectorField,
            dimensions: dimensions,
            pks: uncachedNearPks,
          );
          vectorCache.addAll(fetched);
        }
        for (final h in nearHits) {
          if (h.primaryKey == anchorSample.pk) continue;
          final nv = vectorCache[h.primaryKey];
          if (nv == null) continue;
          final nNorm = _norm(nv);
          if (nNorm <= 1e-12) continue;
          final unitNv = _scale(nv, 1.0 / nNorm);
          if (_dot(unitAnchor, unitNv) > 0.25) {
            localNeighbors.add(unitNv);
          }
        }
      }

      final ortho = dimensions >= 2
          ? _buildClusterAwareOrthogonalUnit(
              unitAnchor: unitAnchor,
              localNeighbors: localNeighbors,
              unitMean: unitMean,
              unitPool: unitPool,
              rng: rng,
            )
          : null;

      for (int li = 0; li < levelCount; li++) {
        final target = kRelevanceBaselineTargets[li];
        // Plant at physical cosine == target (no calibrator inverse).
        final queryPairs = _synthesizeQueriesForTarget(
          anchor: anchor,
          unitAnchor: unitAnchor,
          anchorNorm: anchorNorm,
          ortho: ortho,
          targetScore: target,
          sTarget: target,
        );

        final pairScores = <double>[];
        final pairRaws = <double>[];
        final int queryDepth = target < 0.70 ? wideAngleDepth : effectiveDepth;

        for (final qValues in queryPairs) {
          probes[li]++;
          final qr = await db
              .query(tableName)
              .select([pkField])
              .matchVector(
                vectorField,
                VectorData(qValues),
                searchDepth: queryDepth,
              )
              .limit(probeTopK);

          final entries = qr.retrieval?.entries ?? const <RetrievalEntry>[];
          final rows = qr.data;
          final count = min(rows.length, entries.length);
          checkOrdering(entries);

          int anchorHitIdx = -1;
          for (int h = 0; h < count; h++) {
            if (rows[h][pkField]?.toString() == anchorSample.pk) {
              anchorHitIdx = h;
              break;
            }
          }

          if (anchorHitIdx >= 0) {
            recalled[li]++;
            final entry = entries[anchorHitIdx];
            final sc = entry.score;
            final raw = entry.rawScore ?? 0.0;
            allSumScore[li] += sc;
            allSumRaw[li] += raw;
            if (sc < minScore[li]) minScore[li] = sc;
            if (sc > maxScore[li]) maxScore[li] = sc;
            pairScores.add(sc);
            pairRaws.add(raw);

            final trueRaw = _computePhysicalRaw(qValues, anchor, metric);
            final rawErr = (raw - trueRaw).abs();
            if (rawErr > maxRawErr[li]) maxRawErr[li] = rawErr;
          } else if (count > 0) {
            // Inspect the k-th (last) returned slot — the anchor is genuinely
            // outranked out of topK ONLY if the k-th item beats the anchor!
            final boundaryPk = rows[count - 1][pkField]?.toString();
            if (boundaryPk != null) {
              unresolvedProbes.add(_UnresolvedProbe(
                levelIndex: li,
                query: qValues,
                boundaryPk: boundaryPk,
                fullTopKReturned: count >= probeTopK,
              ));
              if (!vectorCache.containsKey(boundaryPk)) {
                missingPks.add(boundaryPk);
              }
            }
          } else {
            unresolvedProbes.add(_UnresolvedProbe(
              levelIndex: li,
              query: qValues,
              boundaryPk: '',
              fullTopKReturned: false,
            ));
          }
          await maybeYield();
        }

        if (queryPairs.length == 2 && pairScores.length == 2) {
          pairedRecalled[li] += 2;
          pairSumScore[li] += pairScores[0] + pairScores[1];
          pairSumRaw[li] += pairRaws[0] + pairRaws[1];
        } else if (queryPairs.length == 1 && pairScores.length == 1) {
          pairedRecalled[li] += 1;
          pairSumScore[li] += pairScores[0];
          pairSumRaw[li] += pairRaws[0];
        }
      }

      doneSteps++;
      onProgress?.call(doneSteps, totalSteps);
      await Future<void>.delayed(Duration.zero);
      lastYieldMs = sw.elapsedMilliseconds;
    }

    // Batch-fetch all uncached OOD / boundary vectors in a single query.
    if (missingPks.isNotEmpty) {
      final fetched = await _fetchVectorsByPk(
        db: db,
        tableName: tableName,
        pkField: pkField,
        vectorField: vectorField,
        dimensions: dimensions,
        pks: missingPks.toList(),
      );
      vectorCache.addAll(fetched);
    }

    // Evaluate Gate A OOD witnesses.
    final double packingCos = dimensions < 2
        ? 1.0
        : sqrt(
            1.0 -
                exp(
                  -2.0 * log(max(2, liveCount).toDouble()) / (dimensions - 1),
                ),
          );
    final bool geomSaturated =
        dimensions < 2 || (dimensions <= 12 && packingCos >= 0.968);

    final oodScores = <double>[];
    int oodGe30 = 0;
    int oodFalseInflations = 0;
    for (final w in oodWitnesses) {
      oodScores.add(w.reportedScore);
      if (w.reportedScore >= 0.30) oodGe30++;
      if (w.reportedScore >= 0.40) {
        // Verify it was not an improbable true positive collision in low-D.
        final stored = w.topPk != null ? vectorCache[w.topPk!] : null;
        if (stored == null) {
          oodFalseInflations++;
        } else {
          final qn = _norm(w.query);
          final xn = _norm(stored);
          final double cos = (qn > 1e-12 && xn > 1e-12)
              ? (_dot(w.query, stored) / (qn * xn)).clamp(-1.0, 1.0)
              : 0.0;
          // If an unrelated random probe scored >= 0.40 without truly pointing
          // almost identically at a stored record, flag false inflation.
          if (cos < 0.985) {
            oodFalseInflations++;
          }
        }
      }
    }
    oodScores.sort();
    double percentile(List<double> sorted, double p) {
      if (sorted.isEmpty) return 0.0;
      final idx = ((sorted.length - 1) * p).round().clamp(0, sorted.length - 1);
      return sorted[idx];
    }

    final oodAudit = OodNoiseAuditSummary(
      queryCount: oodScores.length,
      p50Top1Score: percentile(oodScores, 0.50),
      p95Top1Score: percentile(oodScores, 0.95),
      maxTop1Score: oodScores.isEmpty ? 0.0 : oodScores.last,
      countGe30: oodGe30,
      falseInflationsGe40: oodFalseInflations,
      geomSaturated: geomSaturated,
      theoreticalPackingCosine: packingCos,
    );

    final physicalAudit = PhysicalPerturbationAuditSummary(
      positiveChecks: positiveChecks,
      positiveFailures: positiveFailures,
      positiveMisses: positiveMisses,
      orthogonalChecks: orthogonalChecks,
      orthogonalLeaksGe10: orthogonalLeaksGe10,
      scaleChecks: scaleChecks,
      scaleViolations: scaleViolations,
      maxScaleDriftPctPoints: maxScaleDriftPct,
      maxPositiveAbsError: maxPositiveAbsError,
      ragCrossInflations: ragCrossInflations,
      ragCrossDeflations: ragCrossDeflations,
    );

    // Classify unresolved checkpoint probes into genuine Outranked vs ANN-Miss.
    final outranked = List<int>.filled(levelCount, 0);
    final annMissed = List<int>.filled(levelCount, 0);
    final outrankedFloor = List<double?>.filled(levelCount, null);
    for (final u in unresolvedProbes) {
      if (!u.fullTopKReturned || u.boundaryPk.isEmpty) {
        annMissed[u.levelIndex]++;
        continue;
      }
      final bv = vectorCache[u.boundaryPk];
      if (bv == null) {
        annMissed[u.levelIndex]++;
        continue;
      }
      final bool beatsTarget = _candidateBeatsTarget(
        query: u.query,
        candidate: bv,
        targetScore: kRelevanceBaselineTargets[u.levelIndex],
        metric: metric,
      );
      if (beatsTarget) {
        outranked[u.levelIndex]++;
        final bScore = _diagScoreOfPair(u.query, bv, metric);
        final curFloor = outrankedFloor[u.levelIndex];
        if (curFloor == null || bScore < curFloor) {
          outrankedFloor[u.levelIndex] = bScore;
        }
      } else {
        annMissed[u.levelIndex]++;
      }
    }

    // Verify live minScore cutoff filtering & optional hybrid fusion.
    int liveCutoffChecks = 0;
    int liveCutoffViolations = 0;
    bool? hybridPassed;
    HybridFusionAuditSummary? hybridAudit;

    final refAnchor = anchors.first.vector;
    final refNorm = _norm(refAnchor);
    final unitRef = refNorm > 0 ? _scale(refAnchor, 1.0 / refNorm) : refAnchor;
    final refOrtho = dimensions >= 2
        ? _buildClusterAwareOrthogonalUnit(
            unitAnchor: unitRef,
            localNeighbors: const <Float64List>[],
            unitMean: unitMean,
            unitPool: unitPool,
            rng: rng,
          )
        : null;

    const cutoffTargets = <double>[0.20, 0.35, 0.60, 0.80];
    const cutoffs = <double>[0.30, 0.40, 0.70, 0.85];
    for (int i = 0; i < cutoffs.length; i++) {
      final qs = _synthesizeQueriesForTarget(
        anchor: refAnchor,
        unitAnchor: unitRef,
        anchorNorm: refNorm > 0 ? refNorm : 1.0,
        ortho: refOrtho,
        targetScore: cutoffTargets[i],
        sTarget: cutoffTargets[i],
      );
      liveCutoffChecks++;
      final filtered = await db
          .query(tableName)
          .select([pkField])
          .matchVector(
            vectorField,
            VectorData(qs.first),
            searchDepth: effectiveDepth,
            minScore: cutoffs[i],
          )
          .limit(probeTopK);
      for (final e in filtered.retrieval?.entries ?? const <RetrievalEntry>[]) {
        if (e.score + 1e-9 < cutoffs[i]) {
          liveCutoffViolations++;
        }
      }
    }

    if (textFields.isNotEmpty) {
      // -----------------------------------------------------------------
      // Gate C lite (read-only): fusion invariants on the live table.
      // Full planted dual-channel matrix lives in database_tester.
      // -----------------------------------------------------------------
      const nonsense = 'zzzznonexistenttoken9999';
      final textField = textFields.first;
      final anchorPk = anchors.first.pk;

      // C1 — Dominant floor: nonsense text must not dilute vector self-match.
      final hybDom = await db
          .query(tableName)
          .select([pkField])
          .matchText(
            textField,
            TextQuery.text(nonsense),
            minScore: kRagScoreFloor,
          )
          .matchVector(
            vectorField,
            VectorData(refAnchor),
            searchDepth: effectiveDepth,
            minScore: kRagScoreFloor,
          )
          .fusionMethod(RetrievalFusionMethod.weightedScore)
          .limit(min(10, probeTopK));
      final domEntries = hybDom.retrieval?.entries ?? const <RetrievalEntry>[];
      final anchorSurvived =
          hybDom.data.any((r) => r[pkField]?.toString() == anchorPk);
      double? domScore;
      for (int i = 0; i < min(hybDom.data.length, domEntries.length); i++) {
        if (hybDom.data[i][pkField]?.toString() == anchorPk) {
          domScore = domEntries[i].score;
          break;
        }
      }
      final scoresInRange = domEntries.every(
        (e) => e.score >= 0.0 && e.score <= 1.0,
      );
      // Exact self-match under dominant floor must remain ~1.0 (not < 1.0).
      final dominantFloorPassed = !hybDom.hasErrors &&
          anchorSurvived &&
          scoresInRange &&
          domScore != null &&
          domScore >= 1.0 - fidelityAbs;

      // C2 — Dual-noise anti-hallucination: nonsense text + near-orthogonal
      // vector must not clear the RAG floor unless the hit is a true near-dup.
      var dualNoisePassed = true;
      double? dualNoiseMax;
      if (refOrtho != null && dimensions >= 2) {
        final qOrtho = _scale(refOrtho, refNorm > 0 ? refNorm : 1.0);
        final hybNoise = await db
            .query(tableName)
            .select([pkField])
            .matchText(
              textField,
              TextQuery.text(nonsense),
              minScore: kRagScoreFloor,
            )
            .matchVector(
              vectorField,
              VectorData(qOrtho),
              searchDepth: wideAngleDepth,
              minScore: kRagScoreFloor,
            )
            .fusionMethod(RetrievalFusionMethod.weightedScore)
            .limit(min(10, probeTopK));
        final noiseEntries =
            hybNoise.retrieval?.entries ?? const <RetrievalEntry>[];
        if (hybNoise.hasErrors) {
          dualNoisePassed = false;
        }
        for (int i = 0;
            i < min(hybNoise.data.length, noiseEntries.length);
            i++) {
          final sc = noiseEntries[i].score;
          if (dualNoiseMax == null || sc > dualNoiseMax) dualNoiseMax = sc;
          if (sc + 1e-9 < kRagScoreFloor) {
            dualNoisePassed = false;
            continue;
          }
          final pk = hybNoise.data[i][pkField]?.toString();
          if (pk == null) {
            dualNoisePassed = false;
            continue;
          }
          var stored = vectorCache[pk];
          if (stored == null) {
            final fetched = await _fetchVectorsByPk(
              db: db,
              tableName: tableName,
              pkField: pkField,
              vectorField: vectorField,
              dimensions: dimensions,
              pks: <String>[pk],
            );
            vectorCache.addAll(fetched);
            stored = vectorCache[pk];
          }
          if (stored == null) {
            dualNoisePassed = false;
            continue;
          }
          final qn = _norm(qOrtho);
          final xn = _norm(stored);
          final cos = (qn > 1e-12 && xn > 1e-12)
              ? (_dot(qOrtho, stored) / (qn * xn)).clamp(-1.0, 1.0)
              : 0.0;
          // Clearing RAG without near-duplicate geometry ⇒ false inflation.
          if (cos < 0.985) {
            dualNoisePassed = false;
          }
        }
      }

      // C3 — Bounded corroboration (when anchor text is available):
      // S_dom <= S_fused <= S_dom + (1 - S_dom) * 0.35.
      var corroborationPassed = true;
      var corrDetail = '';
      final textSelect = <String>{pkField, textField}.toList();
      final anchorRow = await db
          .query(tableName)
          .select(textSelect)
          .whereEqual(pkField, int.tryParse(anchorPk) ?? anchorPk)
          .limit(1);
      final rawText = anchorRow.data.isNotEmpty
          ? anchorRow.data.first[textField]?.toString()
          : null;
      final token = _distinctiveTextToken(rawText);
      if (token != null) {
        final vecOnly = await db
            .query(tableName)
            .select([pkField])
            .matchVector(
              vectorField,
              VectorData(refAnchor),
              searchDepth: effectiveDepth,
            )
            .limit(min(10, probeTopK));
        final textOnly = await db
            .query(tableName)
            .select([pkField])
            .matchText(textField, TextQuery.text(token))
            .limit(min(10, probeTopK));
        final fusedBoth = await db
            .query(tableName)
            .select([pkField])
            .matchText(textField, TextQuery.text(token))
            .matchVector(
              vectorField,
              VectorData(refAnchor),
              searchDepth: effectiveDepth,
            )
            .fusionMethod(RetrievalFusionMethod.weightedScore)
            .limit(min(10, probeTopK));

        double? scoreOf(QueryResult qr) {
          final entries = qr.retrieval?.entries ?? const <RetrievalEntry>[];
          for (int i = 0; i < min(qr.data.length, entries.length); i++) {
            if (qr.data[i][pkField]?.toString() == anchorPk) {
              return entries[i].score;
            }
          }
          return null;
        }

        final sv = scoreOf(vecOnly);
        final st = scoreOf(textOnly);
        final sf = scoreOf(fusedBoth);
        if (sv == null || st == null || sf == null) {
          // Live row may lack searchable tokens — advisory skip.
          corrDetail = 'skipped(no_anchor_channel_hit)';
        } else {
          final sDom = max(sv, st);
          final upper = sDom + (1.0 - sDom) * 0.35;
          final floorOk = sf + 1e-6 >= sDom;
          final capOk = sf <= upper + 1e-6;
          final rangeOk = sf >= 0.0 && sf <= 1.0;
          corroborationPassed = floorOk && capOk && rangeOk;
          corrDetail =
              'sv=${sv.toStringAsFixed(3)} st=${st.toStringAsFixed(3)} '
              'sf=${sf.toStringAsFixed(3)} '
              'bound=[${sDom.toStringAsFixed(3)}..${upper.toStringAsFixed(3)}]';
        }
      } else {
        corrDetail = 'skipped(no_text_token)';
      }

      hybridAudit = HybridFusionAuditSummary(
        dominantFloorPassed: dominantFloorPassed,
        dualNoisePassed: dualNoisePassed,
        corroborationPassed: corroborationPassed,
        dominantFloorScore: domScore,
        dualNoiseMaxScore: dualNoiseMax,
        detail: corrDetail,
      );
      hybridPassed = hybridAudit.passed;
    }

    doneSteps++;
    onProgress?.call(doneSteps, totalSteps);

    final levelResults = <RelevanceLevelCheckResult>[];
    for (int li = 0; li < levelCount; li++) {
      final nAll = recalled[li];
      final nPair = pairedRecalled[li];
      final usePairMean = nPair > 0;
      final meanSc = usePairMean
          ? pairSumScore[li] / nPair
          : (nAll > 0 ? allSumScore[li] / nAll : 0.0);
      final meanRw = usePairMean
          ? pairSumRaw[li] / nPair
          : (nAll > 0 ? allSumRaw[li] / nAll : 0.0);

      levelResults.add(RelevanceLevelCheckResult(
        dimensions: dimensions,
        expectedScore: kRelevanceBaselineTargets[li],
        meanScore: meanSc,
        minScore: nAll > 0 ? minScore[li] : 0.0,
        maxScore: nAll > 0 ? maxScore[li] : 0.0,
        meanRawScore: meanRw,
        maxRawScoreError: maxRawErr[li],
        recalledCount: nAll,
        pairedRecalledCount: nPair,
        outrankedCount: outranked[li],
        annMissCount: annMissed[li],
        totalProbes: probes[li],
        outrankedFloorScore: outrankedFloor[li],
      ));
    }

    sw.stop();
    return VectorBaselineTestReport(
      tableName: tableName,
      dimensions: dimensions,
      metric: metric,
      liveCorpusSize: liveCount,
      sampledAnchors: anchors.length,
      searchDepth: effectiveDepth,
      probeTopK: probeTopK,
      oodAudit: oodAudit,
      physicalAudit: physicalAudit,
      levelResults: levelResults,
      liveRankInversions: orderInversions,
      liveCutoffChecks: liveCutoffChecks,
      liveCutoffViolations: liveCutoffViolations,
      hybridCheckPassed: hybridPassed,
      hybridAudit: hybridAudit,
      elapsedMs: sw.elapsedMicroseconds / 1000.0,
    );
  }

  /// Picks a distinctive token from live text for corroboration probes.
  static String? _distinctiveTextToken(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    // Prefer Latin tokens length >= 4; fall back to CJK bigram.
    final latin = RegExp(r"[A-Za-z][A-Za-z0-9_-]{3,}")
        .allMatches(trimmed)
        .map((m) => m.group(0)!)
        .where((t) => t.toLowerCase() != 'this' && t.toLowerCase() != 'that')
        .toList();
    if (latin.isNotEmpty) {
      latin.sort((a, b) => b.length.compareTo(a.length));
      return latin.first;
    }
    final runes = trimmed.runes.toList();
    for (int i = 0; i < runes.length - 1; i++) {
      final a = runes[i];
      final b = runes[i + 1];
      final isCjk =
          (a >= 0x4E00 && a <= 0x9FFF) || (a >= 0x3400 && a <= 0x4DBF);
      final isCjk2 =
          (b >= 0x4E00 && b <= 0x9FFF) || (b >= 0x3400 && b <= 0x4DBF);
      if (isCjk && isCjk2) {
        return String.fromCharCodes(<int>[a, b]);
      }
    }
    return null;
  }

  static bool _candidateBeatsTarget({
    required Float64List query,
    required Float64List candidate,
    required double targetScore,
    required VectorDistanceMetric metric,
  }) {
    // Physical threshold equals planted cosine target (no calibrator inverse).
    final sTarget = targetScore;
    final qSq = _dot(query, query);
    final cSq = _dot(candidate, candidate);
    final dot = _dot(query, candidate);
    switch (metric) {
      case VectorDistanceMetric.cosine:
        final denom = sqrt(qSq * cSq);
        final cos = denom > 0 ? dot / denom : -1.0;
        return cos >= sTarget - 0.004;
      case VectorDistanceMetric.innerProduct:
        return dot >= sTarget * qSq - 0.004 * qSq;
      case VectorDistanceMetric.l2:
        final d2 = max(0.0, qSq + cSq - 2.0 * dot);
        final targetD2 = max(0.0, 2.0 * qSq * (1.0 - sTarget));
        return d2 <= targetD2 + 0.008 * qSq;
    }
  }

  static double _diagScoreOfPair(
    Float64List q,
    Float64List x,
    VectorDistanceMetric metric,
  ) {
    final qSq = _dot(q, q);
    final xSq = _dot(x, x);
    if (qSq <= 0 || xSq <= 0) return 0.0;
    final dot = _dot(q, x);
    final double sEff;
    if (metric == VectorDistanceMetric.l2) {
      final d2 = max(0.0, qSq + xSq - 2.0 * dot);
      sEff = (1.0 - d2 / (qSq + xSq)).clamp(-1.0, 1.0);
    } else {
      sEff = (dot / sqrt(qSq * xSq)).clamp(-1.0, 1.0);
    }
    if (sEff <= 0.0) return 0.0;
    if (sEff >= 1.0 - 1e-4) return 1.0;
    return sEff;
  }

  static Float64List _randomGaussianUnit(int dims, Random rng) {
    final out = Float64List(dims);
    double sq = 0.0;
    for (int d = 0; d < dims; d++) {
      final u1 = max(1e-12, rng.nextDouble());
      final u2 = rng.nextDouble();
      final z = sqrt(-2.0 * log(u1)) * cos(2.0 * pi * u2);
      out[d] = z;
      sq += z * z;
    }
    final inv = sq > 0 ? 1.0 / sqrt(sq) : 1.0;
    for (int d = 0; d < dims; d++) {
      out[d] *= inv;
    }
    return out;
  }

  /// Samples existing vectors in `O(M log N)` via PK boundary point lookups.
  static Future<List<_AnchorSample>> _sampleLivePool({
    required ToStore db,
    required String tableName,
    required String pkField,
    required String vectorField,
    required int dimensions,
    required int liveCount,
    required int targetPoolSize,
  }) async {
    final out = <_AnchorSample>[];
    final seenPks = <String>{};

    void collectRows(List<Map<String, dynamic>> rows) {
      for (final row in rows) {
        final pk = row[pkField]?.toString();
        if (pk == null || seenPks.contains(pk)) continue;
        final v = _extractDoubles(row[vectorField], dimensions);
        if (v != null && _norm(v) > 1e-9) {
          seenPks.add(pk);
          out.add(_AnchorSample(pk, v));
          if (out.length >= targetPoolSize) break;
        }
      }
    }

    if (liveCount <= 64) {
      final rows =
          await db.query(tableName).select([pkField, vectorField]).limit(64);
      final shuffled = List<Map<String, dynamic>>.from(rows.data)
        ..shuffle(Random(42));
      collectRows(shuffled);
      return out;
    }

    final first = await db
        .query(tableName)
        .select([pkField])
        .orderByAsc(pkField)
        .limit(1);
    final last = await db
        .query(tableName)
        .select([pkField])
        .orderByDesc(pkField)
        .limit(1);
    final minPkStr =
        first.data.isNotEmpty ? first.data.first[pkField]?.toString() : null;
    final maxPkStr =
        last.data.isNotEmpty ? last.data.first[pkField]?.toString() : null;
    final minId = minPkStr != null ? int.tryParse(minPkStr) : null;
    final maxId = maxPkStr != null ? int.tryParse(maxPkStr) : null;

    if (minId != null && maxId != null && maxId >= minId) {
      final rng = Random(20261031 ^ liveCount);
      final span = maxId - minId + 1;
      final probeIds = <dynamic>{};
      final maxProbes = min(span, targetPoolSize * 3);
      var guard = 0;
      while (probeIds.length < maxProbes && guard < maxProbes * 5) {
        probeIds.add(minId + rng.nextInt(span));
        guard++;
      }
      final pointRows = await db
          .query(tableName)
          .select([pkField, vectorField])
          .whereIn(pkField, probeIds.toList())
          .limit(maxProbes);
      final shuffled = List<Map<String, dynamic>>.from(pointRows.data)
        ..shuffle(rng);
      collectRows(shuffled);
    }

    if (out.length < targetPoolSize) {
      final need = targetPoolSize - out.length;
      final headRows = await db
          .query(tableName)
          .select([pkField, vectorField])
          .orderByAsc(pkField)
          .limit(need);
      collectRows(headRows.data);
    }
    if (out.length < targetPoolSize) {
      final need = targetPoolSize - out.length;
      final tailRows = await db
          .query(tableName)
          .select([pkField, vectorField])
          .orderByDesc(pkField)
          .limit(need);
      collectRows(tailRows.data);
    }
    return out;
  }

  static Future<Map<String, Float64List>> _fetchVectorsByPk({
    required ToStore db,
    required String tableName,
    required String pkField,
    required String vectorField,
    required int dimensions,
    required List<String> pks,
  }) async {
    final out = <String, Float64List>{};
    if (pks.isEmpty) return out;

    final typedKeys = <dynamic>[
      for (final pk in pks) int.tryParse(pk) ?? pk,
    ];
    final qr = await db
        .query(tableName)
        .select([pkField, vectorField])
        .whereIn(pkField, typedKeys)
        .limit(pks.length);
    for (final row in qr.data) {
      final pk = row[pkField]?.toString();
      if (pk == null) continue;
      final v = _extractDoubles(row[vectorField], dimensions);
      if (v != null) {
        out[pk] = v;
      }
    }
    return out;
  }

  static Float64List _buildClusterAwareOrthogonalUnit({
    required Float64List unitAnchor,
    required List<Float64List> localNeighbors,
    required Float64List? unitMean,
    required List<Float64List> unitPool,
    required Random rng,
  }) {
    final dims = unitAnchor.length;
    final basis = <Float64List>[unitAnchor];
    final maxBasis = max(1, dims - 1);

    void tryAddBasis(Float64List candidate) {
      if (basis.length >= maxBasis) return;
      final proj = Float64List.fromList(candidate);
      for (int pass = 0; pass < 2; pass++) {
        for (final b in basis) {
          final dot = _dot(proj, b);
          for (int d = 0; d < dims; d++) {
            proj[d] -= dot * b[d];
          }
        }
      }
      final n = _norm(proj);
      if (n > 1e-5) {
        basis.add(_scale(proj, 1.0 / n));
      }
    }

    for (final nb in localNeighbors) {
      if (basis.length >= max(1, dims - 2)) break;
      tryAddBasis(nb);
    }
    if (unitMean != null && basis.length < max(1, dims - 2)) {
      tryAddBasis(unitMean);
    }

    Float64List? bestCandidate;
    double bestWorstAbsDot = double.infinity;
    final candidateTrials = dims <= 256 ? 12 : 4;

    for (int t = 0; t < candidateTrials; t++) {
      final cand = Float64List(dims);
      for (int d = 0; d < dims; d++) {
        cand[d] = (rng.nextDouble() - 0.5) + (rng.nextDouble() - 0.5);
      }
      for (int pass = 0; pass < 2; pass++) {
        for (final b in basis) {
          final dot = _dot(cand, b);
          for (int d = 0; d < dims; d++) {
            cand[d] -= dot * b[d];
          }
        }
      }
      final n = _norm(cand);
      if (n <= 1e-12) continue;
      final unitCand = _scale(cand, 1.0 / n);

      if (unitPool.isEmpty || candidateTrials == 1) {
        return unitCand;
      }
      double worstAbs = 0.0;
      for (final p in unitPool) {
        final anchorDot = _dot(p, unitAnchor);
        if (anchorDot > 0.92) continue;
        final absD = _dot(unitCand, p).abs();
        if (absD > worstAbs) worstAbs = absD;
      }
      if (worstAbs < bestWorstAbsDot) {
        bestWorstAbsDot = worstAbs;
        bestCandidate = unitCand;
      }
    }

    if (bestCandidate != null) return bestCandidate;

    final fallback = Float64List(dims);
    final int pick = unitAnchor[0].abs() < 0.9 ? 0 : 1;
    for (int d = 0; d < dims; d++) {
      fallback[d] = (d == pick ? 1.0 : 0.0) - unitAnchor[pick] * unitAnchor[d];
    }
    final fn = _norm(fallback);
    return fn > 0 ? _scale(fallback, 1.0 / fn) : fallback;
  }

  static List<Float64List> _synthesizeQueriesForTarget({
    required Float64List anchor,
    required Float64List unitAnchor,
    required double anchorNorm,
    required Float64List? ortho,
    required double targetScore,
    required double sTarget,
  }) {
    final dims = anchor.length;
    if (targetScore >= 1.0) {
      return <Float64List>[Float64List.fromList(anchor)];
    }

    if (dims >= 2 && ortho != null) {
      final double clampedS = sTarget.clamp(-1.0, 1.0);
      final double perp = sqrt(max(0.0, 1.0 - clampedS * clampedS));
      final qPlus = Float64List(dims);
      final qMinus = Float64List(dims);
      for (int d = 0; d < dims; d++) {
        final base = anchorNorm * clampedS * unitAnchor[d];
        final delta = anchorNorm * perp * ortho[d];
        qPlus[d] = base + delta;
        qMinus[d] = base - delta;
      }
      return <Float64List>[qPlus, qMinus];
    }

    // 1D symmetric L2 fallback: sEff = 2*q*a / (q^2 + a^2) == sTarget.
    final q = Float64List(1);
    final s = sTarget.clamp(-0.9999, 0.9999);
    if (s.abs() < 1e-9) {
      q[0] = 0.0;
    } else {
      final disc = sqrt(max(0.0, 1.0 - s * s));
      final ratio = (1.0 - disc) / s;
      q[0] = anchor[0] * ratio;
    }
    return <Float64List>[q];
  }

  static Float64List? _extractDoubles(Object? raw, int expectedDims) {
    if (raw is VectorData) {
      if (raw.dimensions != expectedDims) return null;
      return Float64List.fromList(raw.values);
    }
    if (raw is List && raw.length == expectedDims) {
      final out = Float64List(expectedDims);
      for (int i = 0; i < expectedDims; i++) {
        final v = raw[i];
        if (v is! num) return null;
        out[i] = v.toDouble();
      }
      return out;
    }
    return null;
  }

  static double _dot(Float64List a, Float64List b) {
    double s = 0.0;
    for (int i = 0; i < a.length; i++) {
      s += a[i] * b[i];
    }
    return s;
  }

  static double _norm(Float64List v) {
    double s = 0.0;
    for (int i = 0; i < v.length; i++) {
      s += v[i] * v[i];
    }
    return sqrt(s);
  }

  static Float64List _scale(Float64List v, double factor) {
    final out = Float64List(v.length);
    for (int i = 0; i < v.length; i++) {
      out[i] = v[i] * factor;
    }
    return out;
  }

  static double _computePhysicalRaw(
    Float64List q,
    Float64List x,
    VectorDistanceMetric metric,
  ) {
    double dot = 0.0;
    double qSq = 0.0;
    double xSq = 0.0;
    double d2 = 0.0;
    for (int i = 0; i < q.length; i++) {
      final qi = q[i];
      final xi = x[i];
      dot += qi * xi;
      qSq += qi * qi;
      xSq += xi * xi;
      final diff = qi - xi;
      d2 += diff * diff;
    }
    switch (metric) {
      case VectorDistanceMetric.cosine:
        final denom = sqrt(qSq * xSq);
        return denom > 0 ? (dot / denom).clamp(-1.0, 1.0) : 0.0;
      case VectorDistanceMetric.innerProduct:
        return dot;
      case VectorDistanceMetric.l2:
        return sqrt(d2);
    }
  }
}
