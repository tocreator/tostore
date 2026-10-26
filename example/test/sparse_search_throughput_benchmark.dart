import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:tostore/tostore.dart';

/// Sparse retrieval throughput benchmark (`IndexType.sparse` / [matchSparse]).
///
/// Non-zero (nnz) tiers — synthetic neural-sparse docs over a large vocab:
///   - light   nnz=16
///   - mid     nnz=64
///   - heavy   nnz=256
///   - dense   nnz=1024
///
/// Reports insert OPS, flush (seal/persist) latency, and search QPS (Top-K=10).
/// Database directory is reused across runs; only the deficit to [corpusSize]
/// is inserted, then [ToStore.flush] so sealed sparse pages are measured.
///
/// Usage:
///   dart run example/test/sparse_search_throughput_benchmark.dart
///
/// Optional env overrides:
///   TOSTORE_SPARSE_BENCH_CLEAR=1
///   TOSTORE_SPARSE_BENCH_CORPUS=10000
///   TOSTORE_SPARSE_BENCH_QUERIES=1000
///   TOSTORE_SPARSE_BENCH_WARMUP=1000
///   TOSTORE_SPARSE_BENCH_TIERS=light,mid
///   TOSTORE_SPARSE_BENCH_VOCAB=100000
void main() async {
  final dbDir = Directory(
    '${Directory.systemTemp.path}/tostore_bench_sparse_search',
  );

  final shouldClear =
      Platform.environment['TOSTORE_SPARSE_BENCH_CLEAR'] == '1' ||
          Platform.environment['TOSTORE_SPARSE_BENCH_CLEAR']?.toLowerCase() ==
              'true';
  if (shouldClear && dbDir.existsSync()) {
    stdout.writeln('Clearing existing benchmark database: ${dbDir.path}');
    dbDir.deleteSync(recursive: true);
  }

  final corpusSize =
      int.tryParse(Platform.environment['TOSTORE_SPARSE_BENCH_CORPUS'] ?? '') ??
          10000;
  final searchCount = int.tryParse(
          Platform.environment['TOSTORE_SPARSE_BENCH_QUERIES'] ?? '') ??
      1000;
  final warmupCount =
      int.tryParse(Platform.environment['TOSTORE_SPARSE_BENCH_WARMUP'] ?? '') ??
          1000;
  final vocabSize =
      int.tryParse(Platform.environment['TOSTORE_SPARSE_BENCH_VOCAB'] ?? '') ??
          100000;
  const topK = 10;
  const totalRounds = 3;
  const fieldName = 'features';
  const insertBatchSize = 500;

  const allTiers = <_SparseTier>[
    _SparseTier('light', 16),
    _SparseTier('mid', 64),
    _SparseTier('heavy', 256),
    _SparseTier('dense', 1024),
  ];
  final tierFilter = Platform.environment['TOSTORE_SPARSE_BENCH_TIERS'];
  final tiers = tierFilter == null || tierFilter.trim().isEmpty
      ? allTiers
      : [
          for (final name in tierFilter.split(','))
            ...allTiers.where((t) => t.name == name.trim()),
        ];
  if (tiers.isEmpty) {
    stderr.writeln('No tiers selected via TOSTORE_SPARSE_BENCH_TIERS');
    exit(1);
  }
  if (vocabSize < 1024) {
    stderr.writeln('TOSTORE_SPARSE_BENCH_VOCAB must be >= 1024');
    exit(1);
  }

  stdout.writeln(
      '================================================================');
  stdout.writeln(' ToStore Sparse Search Throughput Benchmark (matchSparse)');
  stdout.writeln(
      '================================================================');
  stdout.writeln('Database path:     ${dbDir.path}');
  stdout.writeln(
      'nnz tiers:         ${tiers.map((t) => '${t.name}=${t.nnz}').join(', ')}');
  stdout.writeln('Vocab size:        $vocabSize dims');
  stdout
      .writeln('Corpus target:     $corpusSize docs/table (reuse if present)');
  stdout.writeln('Top-K:             $topK');
  stdout.writeln('Warmup queries:    $warmupCount');
  stdout.writeln('Timed queries:     $searchCount x $totalRounds rounds');
  stdout.writeln(
      'Query mix:         70% short (1–4 dims), 30% medium (5–16 dims)');
  stdout.writeln(
      '================================================================\n');

  if (!dbDir.existsSync()) {
    dbDir.createSync(recursive: true);
  }

  final schemas = [
    for (final tier in tiers) _sparseSchema(tier.name, fieldName),
  ];

  try {
    final db = await ToStore.open(
      dbPath: dbDir.path,
      schemas: schemas,
    );

    final summaries = <_TierSummary>[];
    for (final tier in tiers) {
      summaries.add(
        await _runTier(
          db: db,
          tier: tier,
          fieldName: fieldName,
          corpusSize: corpusSize,
          searchCount: searchCount,
          warmupCount: warmupCount,
          topK: topK,
          totalRounds: totalRounds,
          insertBatchSize: insertBatchSize,
          vocabSize: vocabSize,
        ),
      );
    }

    stdout.writeln(
        '================================================================');
    stdout.writeln(' Combined Throughput Summary');
    stdout.writeln(
        '================================================================');
    stdout.writeln(
        ' ${_pad('tier', 8)} ${_pad('nnz', 6)} ${_pad('idxOPS', 10)} '
        '${_pad('flushMs', 10)} ${_pad('warmupQPS', 10)} ${_pad('avgQPS', 10)} '
        '${_pad('μs/q', 10)} ${_pad('avgHits', 8)}');
    for (final s in summaries) {
      stdout.writeln(' ${_pad(s.tierName, 8)} ${_pad('${s.nnz}', 6)} '
          '${_pad(s.insertOps?.toStringAsFixed(0) ?? '-', 10)} '
          '${_pad(s.flushMs?.toString() ?? '-', 10)} '
          '${_pad(s.warmupQps.toStringAsFixed(1), 10)} '
          '${_pad(s.avgQps.toStringAsFixed(1), 10)} '
          '${_pad(s.avgUsPerQuery.toStringAsFixed(1), 10)} '
          '${_pad(s.avgHits.toStringAsFixed(1), 8)}');
    }
    stdout.writeln(
        '================================================================\n');
    stdout.writeln(
        'Notes: higher nnz stresses posting fan-out and seal cost; larger');
    stdout.writeln(
        'VOCAB spreads dims (sparser postings). Raise CORPUS via env for');
    stdout.writeln('larger sealed-page runs. CLEAR=1 resets the DB dir.\n');

    await db.close();
    exit(0);
  } catch (e, st) {
    stderr.writeln('Benchmark Error: $e\n$st');
    exitCode = 1;
  }
}

String _pad(String s, int w) => s.padLeft(w);

String _tableName(String tier) => 'bench_sparse_$tier';

TableSchema _sparseSchema(String tier, String fieldName) {
  return TableSchema(
    name: _tableName(tier),
    primaryKeyConfig: const PrimaryKeyConfig(
      name: 'id',
      type: PrimaryKeyType.sequential,
    ),
    fields: [
      FieldSchema(name: fieldName, type: DataType.sparse, nullable: false),
      const FieldSchema(
        name: 'category',
        type: DataType.text,
        nullable: false,
        defaultValue: '',
      ),
    ],
    indexes: [
      IndexSchema(
        fields: [fieldName],
        type: IndexType.sparse,
        indexName: '${tier}_$fieldName',
      ),
    ],
  );
}

Future<_TierSummary> _runTier({
  required ToStore db,
  required _SparseTier tier,
  required String fieldName,
  required int corpusSize,
  required int searchCount,
  required int warmupCount,
  required int topK,
  required int totalRounds,
  required int insertBatchSize,
  required int vocabSize,
}) async {
  final tableName = _tableName(tier.name);

  stdout.writeln(
      '----------------------------------------------------------------');
  stdout.writeln(
      ' TIER: ${tier.name}  nnz=${tier.nnz}  table=$tableName  vocab=$vocabSize');
  stdout.writeln(
      '----------------------------------------------------------------');

  final existingCount = await db.query(tableName).count();
  stdout.writeln('Existing records:     $existingCount');

  double? insertOps;
  int? flushMs;
  if (existingCount < corpusSize) {
    final missing = corpusSize - existingCount;
    stdout
        .writeln('Inserting $missing docs (keep existing, no table clear)...');
    final rng = math.Random(2000 + tier.nnz + existingCount);
    stdout
        .writeln('Pre-generating $missing sparse vectors (nnz=${tier.nnz})...');
    var totalNnz = 0;
    final batches = <List<Map<String, dynamic>>>[];
    var generated = 0;
    while (generated < missing) {
      final chunk = math.min(insertBatchSize, missing - generated);
      final records = List<Map<String, dynamic>>.generate(chunk, (i) {
        final seq = existingCount + generated + i;
        final vec = _syntheticSparse(rng, tier.nnz, vocabSize, seq);
        totalNnz += vec.nnz;
        return {
          fieldName: vec,
          'category': 'cat_${seq % 32}',
        };
      });
      batches.add(records);
      generated += chunk;
    }

    final swInsert = Stopwatch()..start();
    var inserted = 0;
    for (final records in batches) {
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
      inserted += records.length;
      if (inserted == records.length ||
          inserted % (insertBatchSize * 5) == 0 ||
          inserted == missing) {
        stdout.writeln('  Inserted $inserted / $missing');
      }
    }
    swInsert.stop();
    insertOps = missing / (swInsert.elapsedMicroseconds / 1000000.0);
    final avgNnz = totalNnz / missing;
    stdout.writeln('Insert done: ${swInsert.elapsedMilliseconds} ms -> '
        '${insertOps.toStringAsFixed(0)} OPS '
        '(avg nnz ${avgNnz.toStringAsFixed(1)})');
    stdout.writeln('Flushing so sealed sparse pages are measured...');
    final swFlush = Stopwatch()..start();
    await db.flush();
    swFlush.stop();
    flushMs = swFlush.elapsedMilliseconds;
    stdout.writeln('Flush done: $flushMs ms');
  } else {
    stdout.writeln('Corpus already >= $corpusSize; skip insert (no clear).');
    stdout.writeln('Flushing before search (sealed pages)...');
    final swFlush = Stopwatch()..start();
    await db.flush();
    swFlush.stop();
    flushMs = swFlush.elapsedMilliseconds;
    stdout.writeln('Flush done: $flushMs ms');
  }

  final readyCount = await db.query(tableName).count();
  stdout.writeln('records after setup:  $readyCount\n');
  if (readyCount <= 0) {
    throw StateError('No records available for sparse search ($tableName).');
  }

  stdout.writeln('Building $searchCount SparseVectorData queries...');
  final queryRng = math.Random(20261026 + tier.nnz);
  final queries = List<SparseVectorData>.generate(
    searchCount,
    (_) => _syntheticQuery(queryRng, vocabSize),
  );

  Future<({int elapsedMs, double qps, double usPerQuery, double avgHits})>
      runSearches({
    required String label,
    required int count,
  }) async {
    stdout.writeln('$label ($count queries, topK=$topK)...');
    final sw = Stopwatch()..start();
    var totalHits = 0;
    for (var i = 0; i < count; i++) {
      final result = await db
          .query(tableName)
          .select(['id'])
          .matchSparse(fieldName, queries[i % queries.length])
          .limit(topK);
      if (result.type != ResultType.success) {
        throw StateError('matchSparse failed: ${result.message}');
      }
      totalHits += result.data.length;
    }
    sw.stop();
    final seconds = sw.elapsedMicroseconds / 1000000.0;
    final qps = seconds > 0 ? count / seconds : 0.0;
    final usPerQuery = sw.elapsedMicroseconds / count;
    final avgHits = count > 0 ? totalHits / count : 0.0;
    stdout.writeln('  ${sw.elapsedMilliseconds} ms -> '
        '${qps.toStringAsFixed(1)} QPS '
        '(${usPerQuery.toStringAsFixed(1)} μs/query, '
        'avgHits: ${avgHits.toStringAsFixed(1)}/$topK)');
    return (
      elapsedMs: sw.elapsedMilliseconds,
      qps: qps,
      usPerQuery: usPerQuery,
      avgHits: avgHits,
    );
  }

  final warmup = await runSearches(label: 'Warmup', count: warmupCount);
  stdout.writeln('');

  final roundQps = <double>[];
  final roundMs = <int>[];
  final roundUs = <double>[];
  final roundHits = <double>[];
  for (var r = 1; r <= totalRounds; r++) {
    final round = await runSearches(
      label: 'Round $r / $totalRounds',
      count: searchCount,
    );
    roundQps.add(round.qps);
    roundMs.add(round.elapsedMs);
    roundUs.add(round.usPerQuery);
    roundHits.add(round.avgHits);
  }

  final avgQps = roundQps.reduce((a, b) => a + b) / roundQps.length;
  final avgMs = roundMs.reduce((a, b) => a + b) / roundMs.length;
  final avgUs = roundUs.reduce((a, b) => a + b) / roundUs.length;
  final avgHits = roundHits.reduce((a, b) => a + b) / roundHits.length;

  stdout.writeln('');
  stdout.writeln(' [${tier.name}] summary');
  stdout.writeln('  Insert:   ${insertOps?.toStringAsFixed(0) ?? '-'} OPS');
  stdout.writeln('  Flush:    $flushMs ms');
  stdout.writeln('  Warmup:   ${warmup.elapsedMs.toString().padLeft(8)} ms  '
      '${warmup.qps.toStringAsFixed(1).padLeft(10)} QPS  '
      'avgHits: ${warmup.avgHits.toStringAsFixed(1)}/$topK');
  for (var i = 0; i < roundQps.length; i++) {
    stdout.writeln('  Round ${i + 1}: ${roundMs[i].toString().padLeft(8)} ms  '
        '${roundQps[i].toStringAsFixed(1).padLeft(10)} QPS  '
        'avgHits: ${roundHits[i].toStringAsFixed(1)}/$topK');
  }
  stdout.writeln('  Average:  ${avgMs.toStringAsFixed(0).padLeft(8)} ms  '
      '${avgQps.toStringAsFixed(1).padLeft(10)} QPS  '
      '${avgUs.toStringAsFixed(1)} μs/query  '
      'avgHits: ${avgHits.toStringAsFixed(1)}/$topK\n');

  return _TierSummary(
    tierName: tier.name,
    nnz: tier.nnz,
    insertOps: insertOps,
    flushMs: flushMs,
    warmupMs: warmup.elapsedMs,
    warmupQps: warmup.qps,
    roundMs: roundMs,
    roundQps: roundQps,
    avgMs: avgMs,
    avgQps: avgQps,
    avgUsPerQuery: avgUs,
    avgHits: avgHits,
  );
}

/// Zipf-like dim sampling over [1, vocabSize].
int _zipfDim(math.Random rng, int vocabSize) {
  final u = rng.nextDouble();
  return 1 + (math.pow(u, 3) * vocabSize).floor().clamp(0, vocabSize - 1);
}

SparseVectorData _syntheticSparse(
  math.Random rng,
  int nnz,
  int vocabSize,
  int seq,
) {
  final target = nnz.clamp(1, vocabSize);
  final map = <int, double>{};
  // Plant a rotating head-of-vocab dim so short queries keep some recall.
  map[1 + (seq % math.min(64, vocabSize))] = 0.9;
  while (map.length < target) {
    final dim = _zipfDim(rng, vocabSize);
    if (map.containsKey(dim)) continue;
    map[dim] = 0.05 + rng.nextDouble() * 0.95;
  }
  return SparseVectorData.fromMap(map);
}

/// 70% short (1–4 dims), 30% medium (5–16 dims); query weights in (0, 1].
SparseVectorData _syntheticQuery(math.Random rng, int vocabSize) {
  final short = rng.nextDouble() < 0.70;
  final dimCount = short ? 1 + rng.nextInt(4) : 5 + rng.nextInt(12);
  final indices = <int>[];
  while (indices.length < dimCount) {
    final dim = _zipfDim(rng, vocabSize);
    if (!indices.contains(dim)) indices.add(dim);
  }
  indices.sort();
  final idx = Uint32List.fromList(indices);
  final vals = Float32List(indices.length);
  for (var i = 0; i < vals.length; i++) {
    vals[i] = 0.2 + rng.nextDouble() * 0.8;
  }
  return SparseVectorData(idx, vals);
}

class _SparseTier {
  final String name;
  final int nnz;
  const _SparseTier(this.name, this.nnz);
}

class _TierSummary {
  final String tierName;
  final int nnz;
  final double? insertOps;
  final int? flushMs;
  final int warmupMs;
  final double warmupQps;
  final List<int> roundMs;
  final List<double> roundQps;
  final double avgMs;
  final double avgQps;
  final double avgUsPerQuery;
  final double avgHits;

  const _TierSummary({
    required this.tierName,
    required this.nnz,
    required this.insertOps,
    required this.flushMs,
    required this.warmupMs,
    required this.warmupQps,
    required this.roundMs,
    required this.roundQps,
    required this.avgMs,
    required this.avgQps,
    required this.avgUsPerQuery,
    required this.avgHits,
  });
}
