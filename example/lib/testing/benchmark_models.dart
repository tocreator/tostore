import 'dart:math' as math;

/// Defines the complexity tier of benchmark tables.
enum BenchmarkTier {
  /// Simple table with single primary key and basic scalar fields (no secondary indexes).
  /// Measures peak engine throughput and serialization performance.
  simple('Simple (Pure PK)', 'Pure PK, no secondary indexes'),

  /// Indexed table with unique and range query indexes.
  /// Measures index maintenance overhead and indexed query acceleration.
  indexed('Indexed', 'PK + 1 unique + 2 secondary indexes'),

  /// Run across all tiers.
  all('All Tiers', 'Compare both Simple and Indexed tiers');

  final String label;
  final String description;
  const BenchmarkTier(this.label, this.description);
}

/// Defines specific database operations evaluated during benchmarks.
enum BenchmarkOperation {
  batchInsert('Batch Insert', 'Bulk insert records in a single batch'),
  singleInsert('Single Insert', 'Sequential single-record inserts'),
  pointReadRandom('PK Read (Random)',
      'Random uniform lookup by primary key across full table'),
  pointReadHot('PK Read (Hot Cache)',
      'Repeated lookups hitting in-memory TreeCache / ReadView'),
  indexedSeek('Indexed Seek', 'Unique index point lookup (where name = ?)'),
  rangeScan('Range Scan (Random)',
      'Random start range query with ordering and limit'),
  fullScan('Full Scan', 'Read and deserialize full table dataset'),
  batchUpdate('Batch Update', 'Bulk update existing records by primary key'),
  batchUpsert('Batch Upsert', 'Bulk upsert records with conflicts'),
  batchDelete('Batch Delete', 'Bulk delete records by primary key'),
  count('Count Verification', 'Fast metadata / index tree record count');

  final String label;
  final String description;
  const BenchmarkOperation(this.label, this.description);
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
    this.operations = const {
      BenchmarkOperation.batchInsert,
      BenchmarkOperation.pointReadRandom,
      BenchmarkOperation.pointReadHot,
      BenchmarkOperation.indexedSeek,
      BenchmarkOperation.rangeScan,
      BenchmarkOperation.fullScan,
      BenchmarkOperation.batchUpdate,
      BenchmarkOperation.batchUpsert,
      BenchmarkOperation.batchDelete,
      BenchmarkOperation.count,
    },
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

  BenchmarkMetric({
    required this.name,
    required this.tierName,
    required this.recordCount,
    required this.roundElapsedMicroseconds,
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
    buffer.writeln();
    buffer.writeln(
        '| Model | Operation | Scale | Avg Time | Throughput | Avg Latency | Min / Max |');
    buffer.writeln('| :--- | :--- | :---: | :---: | :---: | :---: | :---: |');

    for (final m in metrics) {
      final avgTimeStr = '${m.avgMilliseconds.toStringAsFixed(2)} ms';
      final throughputStr = '${m.opsPerSec.toStringAsFixed(0)} ops/s';
      final latencyStr = '${m.avgLatencyUs.toStringAsFixed(2)} μs/op';
      final minMaxStr =
          '${(m.minMicroseconds / 1000.0).toStringAsFixed(1)} / ${(m.maxMicroseconds / 1000.0).toStringAsFixed(1)} ms';

      buffer.writeln(
          '| ${m.tierName} | ${m.name} | ${m.recordCount} | $avgTimeStr | **$throughputStr** | $latencyStr | $minMaxStr |');
    }

    return buffer.toString();
  }
}
