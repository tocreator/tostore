import 'dart:io';
import 'dart:math' as math;

import 'package:tostore/tostore.dart';

/// Vector search throughput benchmark (128-d and 768-d, Top-K 10, default
/// searchDepth).
///
/// Reuses a fixed database directory across runs. Existing rows are kept;
/// only the deficit to [corpusSize] is inserted. After any insert, [ToStore.flush]
/// runs so ANN search can see durable index pages.
///
/// Usage:
///   dart run example/test/vector_search_throughput_benchmark.dart
void main() async {
  final dbDir = Directory(
    '${Directory.systemTemp.path}/tostore_bench_vector_search_768',
  );

  const corpusSize = 10000;
  const searchCount = 10000;
  const warmupCount = 10000;
  const topK = 10;
  const totalRounds = 3;
  const fieldName = 'embedding';
  const insertBatchSize = 1000;
  const dimensionsToRun = [128, 768];

  stdout.writeln(
      '================================================================');
  stdout.writeln(' ToStore Vector Search Throughput Benchmark');
  stdout.writeln(
      '================================================================');
  stdout.writeln('Database path:     ${dbDir.path}');
  stdout.writeln(
      'Dimensions:        ${dimensionsToRun.map((d) => '${d}D').join(', ')}');
  stdout.writeln(
      'Corpus target:     $corpusSize vectors/table (reuse if present)');
  stdout.writeln('Top-K:             $topK');
  stdout.writeln(
      'Search depth:      default (${VectorIndexConfig.defaultSearchDepth})');
  stdout.writeln('Warmup queries:    $warmupCount');
  stdout.writeln('Timed queries:     $searchCount x $totalRounds rounds');
  stdout.writeln(
      '================================================================\n');

  if (!dbDir.existsSync()) {
    dbDir.createSync(recursive: true);
  }

  final schemas = [
    for (final dims in dimensionsToRun) _vectorSchema(dims, fieldName),
  ];

  try {
    final db = await ToStore.open(
      dbPath: dbDir.path,
      schemas: schemas,
    );

    final summaries = <_DimSummary>[];
    for (final dims in dimensionsToRun) {
      summaries.add(
        await _runDimension(
          db: db,
          dimensions: dims,
          fieldName: fieldName,
          corpusSize: corpusSize,
          searchCount: searchCount,
          warmupCount: warmupCount,
          topK: topK,
          totalRounds: totalRounds,
          insertBatchSize: insertBatchSize,
        ),
      );
    }

    stdout.writeln(
        '================================================================');
    stdout.writeln(' Combined Throughput Summary');
    stdout.writeln(
        '================================================================');
    for (final s in summaries) {
      stdout.writeln(' [${s.dimensions}D]');
      stdout.writeln('   Warmup:   ${s.warmupMs.toString().padLeft(8)} ms  '
          '${s.warmupQps.toStringAsFixed(1).padLeft(10)} QPS');
      for (var i = 0; i < s.roundQps.length; i++) {
        stdout.writeln(
            '   Round ${i + 1}: ${s.roundMs[i].toString().padLeft(8)} ms  '
            '${s.roundQps[i].toStringAsFixed(1).padLeft(10)} QPS');
      }
      stdout
          .writeln('   Average:  ${s.avgMs.toStringAsFixed(0).padLeft(8)} ms  '
              '${s.avgQps.toStringAsFixed(1).padLeft(10)} QPS');
    }
    stdout.writeln(
        '================================================================\n');

    await db.close();
  } catch (e, st) {
    stderr.writeln('Benchmark Error: $e\n$st');
    exitCode = 1;
  }
}

String _tableName(int dimensions) => 'bench_vector_$dimensions';

TableSchema _vectorSchema(int dimensions, String fieldName) {
  return TableSchema(
    name: _tableName(dimensions),
    primaryKeyConfig: const PrimaryKeyConfig(
      name: 'id',
      type: PrimaryKeyType.sequential,
    ),
    fields: [
      const FieldSchema(name: 'name', type: DataType.text, nullable: false),
      FieldSchema(
        name: fieldName,
        type: DataType.vector,
        nullable: false,
        vectorConfig: VectorFieldConfig(dimensions: dimensions),
      ),
    ],
    indexes: [
      IndexSchema(
        fields: [fieldName],
        type: IndexType.vector,
        vectorConfig: const VectorIndexConfig(
          indexType: VectorIndexType.ngh,
          distanceMetric: VectorDistanceMetric.cosine,
        ),
      ),
    ],
  );
}

Future<_DimSummary> _runDimension({
  required ToStore db,
  required int dimensions,
  required String fieldName,
  required int corpusSize,
  required int searchCount,
  required int warmupCount,
  required int topK,
  required int totalRounds,
  required int insertBatchSize,
}) async {
  final tableName = _tableName(dimensions);

  stdout.writeln(
      '----------------------------------------------------------------');
  stdout.writeln(' DIMENSION: ${dimensions}D  table=$tableName');
  stdout.writeln(
      '----------------------------------------------------------------');

  final existingCount = await db.query(tableName).count();
  stdout.writeln('Existing rows:     $existingCount');

  if (existingCount < corpusSize) {
    final missing = corpusSize - existingCount;
    stdout.writeln(
        'Inserting $missing vectors (keep existing, no table clear)...');
    final rng = math.Random(existingCount + 1);
    final swInsert = Stopwatch()..start();
    var inserted = 0;
    while (inserted < missing) {
      final chunk = math.min(insertBatchSize, missing - inserted);
      final records = List<Map<String, dynamic>>.generate(chunk, (i) {
        final seq = existingCount + inserted + i;
        return {
          'name': 'vec_$seq',
          'embedding': _unitVector(rng, dimensions),
        };
      });
      final res = await db.batchInsert(
        tableName,
        records,
        allowPartialErrors: false,
        returnResultDetails: false,
      );
      if (res.hasErrors) {
        throw StateError(
          'batchInsert failed at offset $inserted: ${res.message}',
        );
      }
      inserted += chunk;
      stdout.writeln('  Inserted $inserted / $missing');
    }
    swInsert.stop();
    final insertOps = missing / (swInsert.elapsedMicroseconds / 1000000.0);
    stdout.writeln('Insert done: ${swInsert.elapsedMilliseconds} ms -> '
        '${insertOps.toStringAsFixed(0)} OPS');
    stdout.writeln('Flushing so vector index is searchable...');
    await db.flush();
  } else {
    stdout.writeln('Corpus already >= $corpusSize; skip insert (no clear).');
    stdout.writeln('Flushing before search (durable pages)...');
    await db.flush();
  }

  final readyCount = await db.query(tableName).count();
  stdout.writeln('Rows after setup:  $readyCount\n');
  if (readyCount <= 0) {
    throw StateError('No rows available for vector search ($tableName).');
  }

  stdout.writeln('Building $searchCount query vectors (${dimensions}D)...');
  final queryRng = math.Random(20261004 + dimensions);
  final queryVectors = List<VectorData>.generate(
    searchCount,
    (_) => _unitVector(queryRng, dimensions),
  );

  Future<({int elapsedMs, double qps})> runSearches({
    required String label,
    required int count,
  }) async {
    stdout.writeln('$label ($count queries, topK=$topK)...');
    final sw = Stopwatch()..start();
    for (var i = 0; i < count; i++) {
      await db.vectorSearch(
        tableName,
        fieldName: fieldName,
        queryVector: queryVectors[i % queryVectors.length],
        topK: topK,
      );
    }
    sw.stop();
    final seconds = sw.elapsedMicroseconds / 1000000.0;
    final qps = seconds > 0 ? count / seconds : 0.0;
    stdout.writeln('  ${sw.elapsedMilliseconds} ms -> '
        '${qps.toStringAsFixed(1)} QPS '
        '(${(sw.elapsedMicroseconds / count).toStringAsFixed(1)} μs/query)');
    return (elapsedMs: sw.elapsedMilliseconds, qps: qps);
  }

  final warmup = await runSearches(label: 'Warmup', count: warmupCount);
  stdout.writeln('');

  final roundQps = <double>[];
  final roundMs = <int>[];
  for (var r = 1; r <= totalRounds; r++) {
    final round = await runSearches(
      label: 'Round $r / $totalRounds',
      count: searchCount,
    );
    roundQps.add(round.qps);
    roundMs.add(round.elapsedMs);
  }

  final avgQps = roundQps.reduce((a, b) => a + b) / roundQps.length;
  final avgMs = roundMs.reduce((a, b) => a + b) / roundMs.length;

  stdout.writeln('');
  stdout.writeln(' [${dimensions}D] summary');
  stdout.writeln('  Warmup:   ${warmup.elapsedMs.toString().padLeft(8)} ms  '
      '${warmup.qps.toStringAsFixed(1).padLeft(10)} QPS');
  for (var i = 0; i < roundQps.length; i++) {
    stdout.writeln('  Round ${i + 1}: ${roundMs[i].toString().padLeft(8)} ms  '
        '${roundQps[i].toStringAsFixed(1).padLeft(10)} QPS');
  }
  stdout.writeln('  Average:  ${avgMs.toStringAsFixed(0).padLeft(8)} ms  '
      '${avgQps.toStringAsFixed(1).padLeft(10)} QPS\n');

  return _DimSummary(
    dimensions: dimensions,
    warmupMs: warmup.elapsedMs,
    warmupQps: warmup.qps,
    roundMs: roundMs,
    roundQps: roundQps,
    avgMs: avgMs,
    avgQps: avgQps,
  );
}

class _DimSummary {
  final int dimensions;
  final int warmupMs;
  final double warmupQps;
  final List<int> roundMs;
  final List<double> roundQps;
  final double avgMs;
  final double avgQps;

  const _DimSummary({
    required this.dimensions,
    required this.warmupMs,
    required this.warmupQps,
    required this.roundMs,
    required this.roundQps,
    required this.avgMs,
    required this.avgQps,
  });
}

VectorData _unitVector(math.Random rng, int dimensions) {
  final values = List<double>.generate(
    dimensions,
    (_) => rng.nextDouble() * 2 - 1,
  );
  var sumSq = 0.0;
  for (final v in values) {
    sumSq += v * v;
  }
  final norm = math.sqrt(sumSq);
  if (norm > 0) {
    for (var i = 0; i < values.length; i++) {
      values[i] /= norm;
    }
  }
  return VectorData(values);
}
