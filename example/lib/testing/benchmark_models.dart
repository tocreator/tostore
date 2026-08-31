import 'dart:math' as math;

import 'benchmark_schemas.dart';

/// Defines the complexity tier of benchmark tables.
enum BenchmarkTier {
  /// Simple table with single primary key and basic scalar fields (no secondary indexes).
  /// Measures peak engine throughput and serialization performance.
  simple('Simple (Pure PK)', 'Pure PK, no secondary indexes'),

  /// Indexed table with unique and range query indexes.
  /// Measures index maintenance overhead and indexed query acceleration.
  indexed('Indexed', 'PK + 1 unique + 1 secondary index'),

  /// Vector table with NGH index (128-d float32, cosine).
  /// Measures embedding ingest, pure ANN (PK-only), and hybrid retrieval.
  vector('Vector (NGH 128-d)', 'PK + 128-d embedding + NGH cosine index'),

  /// Run across all tiers.
  all('All Tiers', 'Compare Simple, Indexed, and Vector tiers');

  final String label;
  final String description;
  const BenchmarkTier(this.label, this.description);
}

/// Defines specific database operations evaluated during benchmarks.
enum BenchmarkOperation {
  // Data Mutation Operations (Writes, Updates, Deletions)
  batchInsert('Batch Insert', 'Bulk insert records in a single batch'),
  singleInsert('Single Insert', 'Sequential single-record inserts'),
  batchUpdate('Batch Update', 'Bulk update existing records by primary key'),
  singleUpdate(
      'Single Update', 'Sequential single-record updates by primary key'),
  batchUpsert('Batch Upsert', 'Bulk upsert records with conflict resolution'),
  batchDelete('Batch Delete',
      'Bulk delete records by range condition with large scale execution'),
  singleDelete(
      'Single Delete', 'Sequential single-record deletes by primary key'),

  // Data Query & Scan Operations (Reads, Seeks, Scans, Pagination)
  pointReadHot('PK Read (Hot Cache)',
      'Synchronous in-memory hot point lookup by primary key (peekFirst)'),
  pointReadRandom('PK Read (Random)',
      'Random uniform lookup by primary key across full table'),
  indexedSeekHot('Indexed Seek (Hot Cache)',
      'Synchronous in-memory hot point lookup by secondary unique index (peekFirst)'),
  indexedSeekRandom('Indexed Seek (Random)',
      'Random uniform lookup by secondary unique index across full table'),
  rangeScanHot('Range Scan (Hot Cache)',
      'Synchronous in-memory hot range scan with limit 10 (peek)'),
  rangeScanRandom('Range Scan (Random)',
      'Random start range query with ordering and limit 10'),
  paginationHot('Pagination (Hot Cache)',
      'Synchronous in-memory hot page read with limit 20 (peek)'),
  paginationRandom(
      'Pagination (Random)', 'Random cursor-based page query with limit 20'),

  // Metadata & Aggregation Operations
  count('Count Verification', 'Fast metadata / index tree record count'),

  // Vector Operations (Vector tier only)
  vectorBatchInsert('Vector Batch Insert',
      'Bulk insert 128-d embeddings with NGH index maintenance'),
  vectorSearch('Vector ANN Search',
      'Pure ANN via db.vectorSearch (primary key + score only)'),
  vectorHybridSearch('Vector Hybrid Search',
      'Structured filter AND matchVector (full table rows on query chain)'),
  vectorRecallCheck('Vector Recall Check',
      'Sampled exact-match recall@1 / recall@K via db.vectorSearch');

  final String label;
  final String description;
  const BenchmarkOperation(this.label, this.description);

  bool get isVectorOperation =>
      this == BenchmarkOperation.vectorBatchInsert ||
      this == BenchmarkOperation.vectorSearch ||
      this == BenchmarkOperation.vectorHybridSearch ||
      this == BenchmarkOperation.vectorRecallCheck;

  bool get isIndexedSeekOperation =>
      this == BenchmarkOperation.indexedSeekHot ||
      this == BenchmarkOperation.indexedSeekRandom;

  /// Whether this op is meaningful for the selected [tier].
  bool appliesTo(BenchmarkTier tier) {
    if (isVectorOperation) {
      return tier == BenchmarkTier.vector || tier == BenchmarkTier.all;
    }
    if (tier == BenchmarkTier.vector) {
      return false;
    }
    if (isIndexedSeekOperation) {
      return tier == BenchmarkTier.indexed || tier == BenchmarkTier.all;
    }
    return true;
  }

  /// Default ops when configuring a fresh Simple / Indexed suite.
  static const Set<BenchmarkOperation> defaultScalarOps = {
    BenchmarkOperation.batchInsert,
    BenchmarkOperation.singleInsert,
    BenchmarkOperation.batchUpdate,
    BenchmarkOperation.singleUpdate,
    BenchmarkOperation.batchUpsert,
    BenchmarkOperation.batchDelete,
    BenchmarkOperation.singleDelete,
    BenchmarkOperation.pointReadHot,
    BenchmarkOperation.pointReadRandom,
    BenchmarkOperation.indexedSeekHot,
    BenchmarkOperation.indexedSeekRandom,
    BenchmarkOperation.rangeScanHot,
    BenchmarkOperation.rangeScanRandom,
    BenchmarkOperation.paginationHot,
    BenchmarkOperation.paginationRandom,
    BenchmarkOperation.count,
  };

  /// Default ops when configuring a Vector-only suite.
  static const Set<BenchmarkOperation> defaultVectorOps = {
    BenchmarkOperation.vectorBatchInsert,
    BenchmarkOperation.vectorSearch,
    BenchmarkOperation.vectorHybridSearch,
    BenchmarkOperation.vectorRecallCheck,
  };
}

/// Configuration payload for running a benchmark suite.
class BenchmarkConfig {
  final BenchmarkTier tier;
  final int scale;
  final int iterations;
  final Set<BenchmarkOperation> operations;

  const BenchmarkConfig({
    this.tier = BenchmarkTier.simple,
    this.scale = 10000,
    this.iterations = 3,
    this.operations = BenchmarkOperation.defaultScalarOps,
  });

  BenchmarkConfig copyWith({
    BenchmarkTier? tier,
    int? scale,
    int? iterations,
    Set<BenchmarkOperation>? operations,
  }) {
    return BenchmarkConfig(
      tier: tier ?? this.tier,
      scale: scale ?? this.scale,
      iterations: iterations ?? this.iterations,
      operations: operations ?? this.operations,
    );
  }
}

/// Stores statistical metrics for a single benchmark operation.
class BenchmarkMetric {
  final String name;
  final String tierName;
  final int recordCount;
  final List<int> roundElapsedMicroseconds;

  /// Full quality detail for Markdown notes / tooltips (may be long).
  final String? qualityNote;

  /// Short label for the results table Highlight column (keeps layout stable).
  final String? compactHighlight;

  BenchmarkMetric({
    required this.name,
    required this.tierName,
    required this.recordCount,
    required this.roundElapsedMicroseconds,
    this.qualityNote,
    this.compactHighlight,
  });

  int get avgMicroseconds {
    if (roundElapsedMicroseconds.isEmpty) return 0;
    final sum = roundElapsedMicroseconds.reduce((a, b) => a + b);
    return (sum / roundElapsedMicroseconds.length).round();
  }

  double get avgMilliseconds => avgMicroseconds / 1000.0;

  int get minMicroseconds => roundElapsedMicroseconds.isEmpty
      ? 0
      : roundElapsedMicroseconds.reduce(math.min);

  int get maxMicroseconds => roundElapsedMicroseconds.isEmpty
      ? 0
      : roundElapsedMicroseconds.reduce(math.max);

  double get opsPerSec {
    if (avgMicroseconds == 0 || recordCount == 0) return 0.0;
    final seconds = avgMicroseconds / 1000000.0;
    return recordCount / seconds;
  }

  double get avgLatencyUs {
    if (recordCount == 0) return 0.0;
    return avgMicroseconds / recordCount;
  }

  /// Compact cell text: short quality label when present, else throughput.
  String get highlightLabel =>
      compactHighlight ?? '${opsPerSec.toStringAsFixed(0)} ops/s';
}

/// Aggregated report summary containing all executed metrics.
class BenchmarkSummary {
  final BenchmarkConfig config;
  final List<BenchmarkMetric> metrics;
  final DateTime timestamp;

  BenchmarkSummary({
    required this.config,
    required this.metrics,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// Formats the benchmark results as a clean Markdown table.
  String toMarkdownTable() {
    final buffer = StringBuffer();
    buffer.writeln('### ToStore Benchmark Results');
    buffer.writeln(
        '- **Scale**: ${config.scale} records | **Iterations**: ${config.iterations} rounds | **Date**: ${timestamp.toIso8601String().split('T').first}');
    if (config.tier == BenchmarkTier.vector ||
        config.tier == BenchmarkTier.all) {
      buffer.writeln(
          '- **Vector**: ${BenchmarkSchemas.vectorDimensions}d float32, cosine NGH, topK=${BenchmarkSchemas.vectorTopK}');
      buffer.writeln(
          '- **ANN / Recall**: `db.vectorSearch` (PK + score only); **Hybrid**: `matchVector` (full rows)');
    }
    buffer.writeln();
    buffer.writeln(
        '| Model | Operation | Count | Avg Time | Result | Avg Latency | Min / Max |');
    buffer.writeln('| :--- | :--- | :---: | :---: | :---: | :---: | :---: |');

    for (final m in metrics) {
      final isQuality = m.compactHighlight != null;
      final avgTimeStr =
          isQuality ? '—' : '${m.avgMilliseconds.toStringAsFixed(2)} ms';
      final highlightStr = '**${m.highlightLabel}**';
      final latencyStr =
          isQuality ? '—' : '${m.avgLatencyUs.toStringAsFixed(2)} μs/op';
      final minMaxStr = isQuality
          ? '—'
          : '${(m.minMicroseconds / 1000.0).toStringAsFixed(1)} / ${(m.maxMicroseconds / 1000.0).toStringAsFixed(1)} ms';

      buffer.writeln(
          '| ${m.tierName} | ${m.name} | ${m.recordCount} | $avgTimeStr | $highlightStr | $latencyStr | $minMaxStr |');
    }

    final qualityRows = metrics
        .where((m) => m.qualityNote != null && m.qualityNote!.isNotEmpty);
    if (qualityRows.isNotEmpty) {
      buffer.writeln();
      buffer.writeln(
          '**Quality notes** (Result = Exact@1 / Exact@5 / Exact@K %; Count = probe sample size):');
      for (final m in qualityRows) {
        buffer.writeln('- **${m.name}**: ${m.qualityNote}');
      }
    }

    return buffer.toString();
  }
}
