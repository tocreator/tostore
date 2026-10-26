import 'dart:io';
import 'dart:math' as math;

import 'package:tostore/tostore.dart';

/// Text retrieval throughput benchmark (`IndexType.text` / [matchText]).
///
/// Document-length tiers:
///   - title     ~80 B   — short titles / keys
///   - passage   ~512 B  — mid-length paragraphs (~80–100 tokens)
///   - paragraph ~2 KiB  — section-sized bodies
///   - article   ~8 KiB  — short full-article bodies
///
/// Reports indexing OPS (when growing corpus) and search QPS (Top-K=10, OR).
/// Database directory is reused across runs; only the deficit to [corpusSize]
/// is inserted, then [ToStore.flush] so sealed text pages are measured.
///
/// Usage:
///   dart run example/test/text_search_throughput_benchmark.dart
///
/// Optional env overrides:
///   TOSTORE_TEXT_BENCH_CLEAR=1
///   TOSTORE_TEXT_BENCH_CORPUS=10000
///   TOSTORE_TEXT_BENCH_QUERIES=1000
///   TOSTORE_TEXT_BENCH_WARMUP=1000
///   TOSTORE_TEXT_BENCH_TIERS=title,passage
void main() async {
  final dbDir = Directory(
    '${Directory.systemTemp.path}/tostore_bench_text_search',
  );

  final shouldClear = Platform.environment['TOSTORE_TEXT_BENCH_CLEAR'] == '1' ||
      Platform.environment['TOSTORE_TEXT_BENCH_CLEAR']?.toLowerCase() == 'true';
  if (shouldClear && dbDir.existsSync()) {
    stdout.writeln('Clearing existing benchmark database: ${dbDir.path}');
    dbDir.deleteSync(recursive: true);
  }

  final corpusSize =
      int.tryParse(Platform.environment['TOSTORE_TEXT_BENCH_CORPUS'] ?? '') ??
          10000;
  final searchCount =
      int.tryParse(Platform.environment['TOSTORE_TEXT_BENCH_QUERIES'] ?? '') ??
          1000;
  final warmupCount =
      int.tryParse(Platform.environment['TOSTORE_TEXT_BENCH_WARMUP'] ?? '') ??
          1000;
  const topK = 10;
  const totalRounds = 3;
  const fieldName = 'content';
  const insertBatchSize = 500;

  // Length targets in UTF-8 bytes (synthetic English from a Zipf lexicon).
  // Optional: TOSTORE_TEXT_BENCH_TIERS=title,passage
  const allTiers = <_DocTier>[
    _DocTier('title', 80),
    _DocTier('passage', 512),
    _DocTier('paragraph', 2048),
    _DocTier('article', 8192),
  ];
  final tierFilter = Platform.environment['TOSTORE_TEXT_BENCH_TIERS'];
  final tiers = tierFilter == null || tierFilter.trim().isEmpty
      ? allTiers
      : [
          for (final name in tierFilter.split(','))
            ...allTiers.where((t) => t.name == name.trim()),
        ];
  if (tiers.isEmpty) {
    stderr.writeln('No tiers selected via TOSTORE_TEXT_BENCH_TIERS');
    exit(1);
  }

  stdout.writeln(
      '================================================================');
  stdout.writeln(' ToStore Text Search Throughput Benchmark (matchText)');
  stdout.writeln(
      '================================================================');
  stdout.writeln('Database path:     ${dbDir.path}');
  stdout.writeln(
      'Doc tiers:         ${tiers.map((t) => '${t.name}~${t.targetBytes}B').join(', ')}');
  stdout
      .writeln('Corpus target:     $corpusSize docs/table (reuse if present)');
  stdout.writeln('Top-K:             $topK');
  stdout.writeln('Match operator:    TextMatchOperator.or');
  stdout.writeln('Warmup queries:    $warmupCount');
  stdout.writeln('Timed queries:     $searchCount x $totalRounds rounds');
  stdout.writeln(
      'Query mix:         70% short (1–3 terms), 30% medium (4–8 terms)');
  stdout.writeln(
      'Lexicon:           $_lexiconSize terms (Zipf-sampled; avoids dense OR)');
  stdout.writeln(
      '================================================================\n');

  if (!dbDir.existsSync()) {
    dbDir.createSync(recursive: true);
  }

  final schemas = [
    for (final tier in tiers) _textSchema(tier.name, fieldName),
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
        ),
      );
    }

    stdout.writeln(
        '================================================================');
    stdout.writeln(' Combined Throughput Summary');
    stdout.writeln(
        '================================================================');
    stdout.writeln(
        ' ${_pad('tier', 12)} ${_pad('docB', 6)} ${_pad('idxOPS', 10)} '
        '${_pad('warmupQPS', 10)} ${_pad('avgQPS', 10)} ${_pad('μs/q', 10)} '
        '${_pad('avgHits', 8)}');
    for (final s in summaries) {
      stdout.writeln(' ${_pad(s.tierName, 12)} ${_pad('${s.targetBytes}', 6)} '
          '${_pad(s.insertOps?.toStringAsFixed(0) ?? '-', 10)} '
          '${_pad(s.warmupQps.toStringAsFixed(1), 10)} '
          '${_pad(s.avgQps.toStringAsFixed(1), 10)} '
          '${_pad(s.avgUsPerQuery.toStringAsFixed(1), 10)} '
          '${_pad(s.avgHits.toStringAsFixed(1), 8)}');
    }
    stdout.writeln(
        '================================================================\n');
    stdout
        .writeln('Notes: short docs favor posting locality; long docs stress');
    stdout
        .writeln('tokenization and posting-list fan-out. Raise CORPUS via env');
    stdout.writeln('for larger sealed-page runs.\n');

    await db.close();
    exit(0);
  } catch (e, st) {
    stderr.writeln('Benchmark Error: $e\n$st');
    exitCode = 1;
  }
}

String _pad(String s, int w) => s.padLeft(w);

String _tableName(String tier) => 'bench_text_$tier';

TableSchema _textSchema(String tier, String fieldName) {
  return TableSchema(
    name: _tableName(tier),
    primaryKeyConfig: const PrimaryKeyConfig(
      name: 'id',
      type: PrimaryKeyType.sequential,
    ),
    fields: [
      FieldSchema(name: fieldName, type: DataType.text, nullable: false),
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
        type: IndexType.text,
        indexName: '${tier}_$fieldName',
      ),
    ],
  );
}

Future<_TierSummary> _runTier({
  required ToStore db,
  required _DocTier tier,
  required String fieldName,
  required int corpusSize,
  required int searchCount,
  required int warmupCount,
  required int topK,
  required int totalRounds,
  required int insertBatchSize,
}) async {
  final tableName = _tableName(tier.name);

  stdout.writeln(
      '----------------------------------------------------------------');
  stdout.writeln(
      ' TIER: ${tier.name}  target≈${tier.targetBytes}B  table=$tableName');
  stdout.writeln(
      '----------------------------------------------------------------');

  final existingCount = await db.query(tableName).count();
  stdout.writeln('Existing records:     $existingCount');

  double? insertOps;
  if (existingCount < corpusSize) {
    final missing = corpusSize - existingCount;
    stdout
        .writeln('Inserting $missing docs (keep existing, no table clear)...');
    final rng = math.Random(1000 + tier.targetBytes + existingCount);
    stdout.writeln('Pre-generating $missing documents...');
    var totalBytes = 0;
    final batches = <List<Map<String, dynamic>>>[];
    var generated = 0;
    while (generated < missing) {
      final chunk = math.min(insertBatchSize, missing - generated);
      final records = List<Map<String, dynamic>>.generate(chunk, (i) {
        final seq = existingCount + generated + i;
        final body = _syntheticDoc(rng, tier.targetBytes, seq);
        totalBytes += body.length;
        return {
          fieldName: body,
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
    final avgDocB = totalBytes / missing;
    stdout.writeln('Insert done: ${swInsert.elapsedMilliseconds} ms -> '
        '${insertOps.toStringAsFixed(0)} OPS '
        '(avg doc ${avgDocB.toStringAsFixed(0)} B)');
    stdout.writeln('Flushing so sealed text pages are measured...');
    final swFlush = Stopwatch()..start();
    await db.flush();
    swFlush.stop();
    stdout.writeln('Flush done: ${swFlush.elapsedMilliseconds} ms');
  } else {
    stdout.writeln('Corpus already >= $corpusSize; skip insert (no clear).');
    stdout.writeln('Flushing before search (sealed pages)...');
    final swFlush = Stopwatch()..start();
    await db.flush();
    swFlush.stop();
    stdout.writeln('Flush done: ${swFlush.elapsedMilliseconds} ms');
  }

  final readyCount = await db.query(tableName).count();
  stdout.writeln('records after setup:  $readyCount\n');
  if (readyCount <= 0) {
    throw StateError('No records available for text search ($tableName).');
  }

  stdout.writeln('Building $searchCount TextQuery payloads...');
  final queryRng = math.Random(20261014 + tier.targetBytes);
  final queries = List<TextQuery>.generate(
    searchCount,
    (_) => _syntheticQuery(queryRng),
  );

  Future<({int elapsedMs, double qps, double usPerQuery, double avgHits})>
      runSearches({
    required String label,
    required int count,
  }) async {
    stdout.writeln('$label ($count queries, topK=$topK, OR)...');
    final sw = Stopwatch()..start();
    var totalHits = 0;
    for (var i = 0; i < count; i++) {
      final result = await db
          .query(tableName)
          .select(['id'])
          .matchText(
            fieldName,
            queries[i % queries.length],
            operator: TextMatchOperator.or,
          )
          .limit(topK);
      if (result.type != ResultType.success) {
        throw StateError('matchText failed: ${result.message}');
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
    targetBytes: tier.targetBytes,
    insertOps: insertOps,
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

/// Large synthetic vocabulary with Zipf-like term sampling.
///
/// A tiny bag-of-words lexicon makes long documents hit almost every term
/// (near-dense postings) and makes OR Top-K look artificially slow.
const _lexiconSize = 50000;
final List<String> _lexicon = List<String>.generate(
  _lexiconSize,
  (i) => 'w$i',
  growable: false,
);

/// Skew toward head of lexicon (common terms), approximating Zipf.
int _zipfIndex(math.Random rng) {
  final u = rng.nextDouble();
  // u^3 keeps most mass on low ranks while still covering the long tail.
  return (math.pow(u, 3) * _lexiconSize).floor().clamp(0, _lexiconSize - 1);
}

String _syntheticDoc(math.Random rng, int targetBytes, int seq) {
  final buf = StringBuffer('doc_$seq ');
  while (buf.length < targetBytes) {
    if (buf.length > 12 && rng.nextDouble() < 0.12) {
      buf.write('. ');
    }
    final word = _lexicon[_zipfIndex(rng)];
    if (buf.length + word.length + 1 > targetBytes &&
        buf.length >= targetBytes * 0.9) {
      break;
    }
    buf.write(word);
    buf.write(' ');
  }
  return buf.toString();
}

/// 70% short keyword queries, 30% medium multi-term (web-search-like mix).
TextQuery _syntheticQuery(math.Random rng) {
  final short = rng.nextDouble() < 0.70;
  final termCount = short ? 1 + rng.nextInt(3) : 4 + rng.nextInt(5);
  final terms = <String>[];
  while (terms.length < termCount) {
    final term = _lexicon[_zipfIndex(rng)];
    if (!terms.contains(term)) terms.add(term);
  }
  // Pre-tokenized Latin tokens (already lower-case); engine does not resegment.
  return TextQuery.terms(terms);
}

class _DocTier {
  final String name;
  final int targetBytes;
  const _DocTier(this.name, this.targetBytes);
}

class _TierSummary {
  final String tierName;
  final int targetBytes;
  final double? insertOps;
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
    required this.targetBytes,
    required this.insertOps,
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
