import 'dart:async';
import 'dart:math' as math;

import 'package:tostore/tostore.dart';

import 'benchmark_models.dart';
import 'benchmark_schemas.dart';
import 'log_service.dart';

/// Runner that executes standardized benchmarks, collects metrics,
/// and outputs detailed performance reports.
class BenchmarkRunner {
  final ToStore db;
  final LogService log;
  final Function(String) _updateLastOperation;

  BenchmarkRunner(this.db, this.log, this._updateLastOperation);

  /// Executes the full benchmark suite according to the provided [config].
  Future<BenchmarkSummary> runBenchmark(BenchmarkConfig config) async {
    log.add(
      '🚀 Starting Benchmark Suite [Scale: ${config.scale}, Tier: ${config.tier.label}, Iterations: ${config.iterations}]',
      LogLevel.info,
    );

    // 1. Ensure benchmark tables exist
    await BenchmarkSchemas.ensureTables(db);

    // 2. Warm-up phase (JIT & VM cache priming)
    _updateLastOperation('Priming Dart VM & Memory (Warm-up)...');
    await _performWarmup();

    final List<BenchmarkMetric> allMetrics = [];

    // Determine target tiers
    final tiersToRun = <BenchmarkTier>[];
    if (config.tier == BenchmarkTier.simple ||
        config.tier == BenchmarkTier.all) {
      tiersToRun.add(BenchmarkTier.simple);
    }
    if (config.tier == BenchmarkTier.indexed ||
        config.tier == BenchmarkTier.all) {
      tiersToRun.add(BenchmarkTier.indexed);
    }

    for (final currentTier in tiersToRun) {
      final tierName =
          currentTier == BenchmarkTier.simple ? 'Simple' : 'Indexed';
      final tableName = currentTier == BenchmarkTier.simple
          ? BenchmarkSchemas.simpleTable
          : BenchmarkSchemas.indexedTable;

      log.add('--- Running Tier: $tierName Benchmark ---', LogLevel.info);

      for (final op in config.operations) {
        // Skip indexedSeek on simple tier (has no secondary unique index)
        if (currentTier == BenchmarkTier.simple &&
            op == BenchmarkOperation.indexedSeek) {
          continue;
        }

        final metric = await _runOperation(
          op: op,
          tier: currentTier,
          tierName: tierName,
          tableName: tableName,
          config: config,
        );

        if (metric != null) {
          allMetrics.add(metric);
          log.add(
            '⚡ [$tierName] ${metric.name}: ${metric.avgMilliseconds.toStringAsFixed(2)} ms (${metric.opsPerSec.toStringAsFixed(0)} ops/s | ${metric.avgLatencyUs.toStringAsFixed(2)} μs/op)',
            LogLevel.info,
          );
        }

        // Yield to allow UI frame updates
        await Future.delayed(const Duration(milliseconds: 10));
      }
    }

    // Clean up benchmark tables to avoid occupying memory/disk
    await db.clear(BenchmarkSchemas.simpleTable);
    await db.clear(BenchmarkSchemas.indexedTable);

    final summary = BenchmarkSummary(config: config, metrics: allMetrics);

    // Log the formatted markdown report
    log.add('\n${summary.toMarkdownTable()}', LogLevel.info);
    _updateLastOperation('✅ Benchmark completed successfully');

    return summary;
  }

  /// Primes JIT compiler and memory allocations with small datasets.
  Future<void> _performWarmup() async {
    const warmupCount = 100;
    final simpleWarmupData = List.generate(
      warmupCount,
      (i) => {'text_val': 'warmup_$i', 'num_val': i},
    );
    final indexedWarmupData = List.generate(
      warmupCount,
      (i) => {
        'name': 'warmup_$i',
        'age': 20 + (i % 50),
        'score': i * 1.0,
        'created_at': DateTime.now().toIso8601String(),
      },
    );

    // Batch insert and query warmup
    await db.batchInsert(
      BenchmarkSchemas.simpleTable,
      simpleWarmupData,
      allowPartialErrors: false,
      returnResultDetails: false,
    );
    await db.batchInsert(
      BenchmarkSchemas.indexedTable,
      indexedWarmupData,
      allowPartialErrors: false,
      returnResultDetails: false,
    );

    await db.query(BenchmarkSchemas.simpleTable);
    await db.query(BenchmarkSchemas.indexedTable).where('age', '>=', 25);

    await db.clear(BenchmarkSchemas.simpleTable);
    await db.clear(BenchmarkSchemas.indexedTable);
  }

  /// Runs an individual benchmark operation across multiple iterations.
  Future<BenchmarkMetric?> _runOperation({
    required BenchmarkOperation op,
    required BenchmarkTier tier,
    required String tierName,
    required String tableName,
    required BenchmarkConfig config,
  }) async {
    final scale = config.scale;
    final iterations = config.iterations;
    final List<int> roundMicroseconds = [];
    int effectiveCount = scale;

    _updateLastOperation('Running [$tierName] ${op.label} (0/$iterations)...');

    switch (op) {
      case BenchmarkOperation.batchInsert:
        for (var round = 1; round <= iterations; round++) {
          _updateLastOperation(
              'Running [$tierName] Batch Insert ($round/$iterations)...');
          await db.clear(tableName);

          final records =
              _generateRecords(tier, scale, seedOffset: round * scale);

          final sw = Stopwatch()..start();
          await db.batchInsert(
            tableName,
            records,
            allowPartialErrors: false,
            returnResultDetails: false,
          );
          sw.stop();
          roundMicroseconds.add(sw.elapsedMicroseconds);
          await Future.delayed(const Duration(milliseconds: 5));
        }
        break;

      case BenchmarkOperation.singleInsert:
        // Set single-insert test scale up to 10,000 records
        effectiveCount = math.min(scale, 10000);
        for (var round = 1; round <= iterations; round++) {
          _updateLastOperation(
              'Running [$tierName] Single Insert ($round/$iterations)...');
          await db.clear(tableName);

          final records = _generateRecords(tier, effectiveCount,
              seedOffset: round * effectiveCount);

          final sw = Stopwatch()..start();
          for (final record in records) {
            await db.insert(tableName, record);
          }
          sw.stop();
          roundMicroseconds.add(sw.elapsedMicroseconds);
          await Future.delayed(const Duration(milliseconds: 5));
        }
        break;

      case BenchmarkOperation.pointReadRandom:
        // Ensure dataset is populated
        await _ensureTablePopulated(tableName, tier, scale);
        effectiveCount = scale;
        final random = math.Random(42);

        for (var round = 1; round <= iterations; round++) {
          _updateLastOperation(
              'Running [$tierName] PK Read (Random) ($round/$iterations)...');
          final queryIds =
              List.generate(effectiveCount, (_) => random.nextInt(scale) + 1);

          final sw = Stopwatch()..start();
          for (final id in queryIds) {
            await db.query(tableName).where('id', '=', id).first();
          }
          sw.stop();
          roundMicroseconds.add(sw.elapsedMicroseconds);
          await Future.delayed(const Duration(milliseconds: 5));
        }
        break;

      case BenchmarkOperation.pointReadHot:
        // Ensure dataset is populated
        await _ensureTablePopulated(tableName, tier, scale);
        effectiveCount = scale;

        // Pre-warm the single hot primary key into TreeCache / ReadView
        await db.query(tableName).where('id', '=', 1).first();

        for (var round = 1; round <= iterations; round++) {
          _updateLastOperation(
              'Running [$tierName] PK Read (Hot Cache) ($round/$iterations)...');

          final sw = Stopwatch()..start();
          for (var i = 0; i < effectiveCount; i++) {
            await db.query(tableName).where('id', '=', 1).first();
          }
          sw.stop();
          roundMicroseconds.add(sw.elapsedMicroseconds);
          await Future.delayed(const Duration(milliseconds: 5));
        }
        break;

      case BenchmarkOperation.indexedSeek:
        if (tier != BenchmarkTier.indexed) return null;
        await _ensureTablePopulated(tableName, tier, scale);
        effectiveCount = scale;
        final random = math.Random(1337);

        for (var round = 1; round <= iterations; round++) {
          _updateLastOperation(
              'Running [$tierName] Indexed Seek ($round/$iterations)...');
          final queryNames = List.generate(
              effectiveCount, (_) => 'user_${random.nextInt(scale)}');

          final sw = Stopwatch()..start();
          for (final name in queryNames) {
            await db.query(tableName).where('name', '=', name).first();
          }
          sw.stop();
          roundMicroseconds.add(sw.elapsedMicroseconds);
          await Future.delayed(const Duration(milliseconds: 5));
        }
        break;

      case BenchmarkOperation.rangeScan:
        await _ensureTablePopulated(tableName, tier, scale);
        // Dynamic query rounds scaling with Dataset Scale (e.g. 500 for 1k, 2000 for 10k, 10000 for 100k)
        final queryRounds = math.max(500, math.min(scale ~/ 10, 10000));
        effectiveCount = queryRounds;
        final random = math.Random(777);

        for (var round = 1; round <= iterations; round++) {
          _updateLastOperation(
              'Running [$tierName] Range Scan ($round/$iterations)...');

          // Pre-generate random start keys before timing to evaluate pure database performance
          final startPoints = tier == BenchmarkTier.simple
              ? List.generate(
                  queryRounds,
                  (_) => random.nextInt(math.max(1, scale - 50)) + 1,
                )
              : List.generate(
                  queryRounds,
                  (_) => 18 + random.nextInt(45),
                );

          final sw = Stopwatch()..start();
          for (var i = 0; i < queryRounds; i++) {
            final startVal = startPoints[i];
            if (tier == BenchmarkTier.simple) {
              await db.query(tableName).where('id', '>=', startVal).limit(50);
            } else {
              await db
                  .query(tableName)
                  .where('age', '>=', startVal)
                  .orderByAsc('score')
                  .limit(50);
            }
          }
          sw.stop();
          roundMicroseconds.add(sw.elapsedMicroseconds);
          await Future.delayed(const Duration(milliseconds: 5));
        }
        break;

      case BenchmarkOperation.fullScan:
        await _ensureTablePopulated(tableName, tier, scale);

        for (var round = 1; round <= iterations; round++) {
          _updateLastOperation(
              'Running [$tierName] Full Scan ($round/$iterations)...');

          final sw = Stopwatch()..start();
          // Explicitly query all `scale` records to ensure complete deserialization
          await db.query(tableName).limit(scale);
          sw.stop();
          roundMicroseconds.add(sw.elapsedMicroseconds);
          await Future.delayed(const Duration(milliseconds: 5));
        }
        break;

      case BenchmarkOperation.batchUpdate:
        await _ensureTablePopulated(tableName, tier, scale);

        for (var round = 1; round <= iterations; round++) {
          _updateLastOperation(
              'Running [$tierName] Batch Update ($round/$iterations)...');
          final updateRecords = _generateUpdateRecords(tier, scale, round);

          final sw = Stopwatch()..start();
          await db.batchUpdate(
            tableName,
            updateRecords,
            allowPartialErrors: false,
            returnResultDetails: false,
          );
          sw.stop();
          roundMicroseconds.add(sw.elapsedMicroseconds);
          await Future.delayed(const Duration(milliseconds: 5));
        }
        break;

      case BenchmarkOperation.batchUpsert:
        await _ensureTablePopulated(tableName, tier, scale);

        for (var round = 1; round <= iterations; round++) {
          _updateLastOperation(
              'Running [$tierName] Batch Upsert ($round/$iterations)...');
          // 50% update existing IDs, 50% insert new IDs with explicit PKs
          final upsertRecords = _generateUpsertRecords(tier, scale, round);

          final sw = Stopwatch()..start();
          await db.batchUpsert(
            tableName,
            upsertRecords,
            allowPartialErrors: false,
            returnResultDetails: false,
          );
          sw.stop();
          roundMicroseconds.add(sw.elapsedMicroseconds);
          await Future.delayed(const Duration(milliseconds: 5));
        }
        break;

      case BenchmarkOperation.batchDelete:
        for (var round = 1; round <= iterations; round++) {
          _updateLastOperation(
              'Running [$tierName] Batch Delete ($round/$iterations)...');
          await _ensureTablePopulated(tableName, tier, scale);

          final sw = Stopwatch()..start();
          await db.delete(tableName).allowDeleteAll();
          sw.stop();
          roundMicroseconds.add(sw.elapsedMicroseconds);
          await Future.delayed(const Duration(milliseconds: 5));
        }
        break;

      case BenchmarkOperation.count:
        await _ensureTablePopulated(tableName, tier, scale);
        final countQueries = math.min(scale, 10000);
        effectiveCount = countQueries;

        for (var round = 1; round <= iterations; round++) {
          _updateLastOperation(
              'Running [$tierName] Count ($round/$iterations)...');

          final sw = Stopwatch()..start();
          for (var i = 0; i < countQueries; i++) {
            await db.query(tableName).count();
          }
          sw.stop();
          roundMicroseconds.add(sw.elapsedMicroseconds);
          await Future.delayed(const Duration(milliseconds: 5));
        }
        break;
    }

    return BenchmarkMetric(
      name: op.label,
      tierName: tierName,
      recordCount: effectiveCount,
      roundElapsedMicroseconds: roundMicroseconds,
    );
  }

  /// Ensures that the table has at least [scale] records.
  Future<void> _ensureTablePopulated(
      String tableName, BenchmarkTier tier, int scale) async {
    final currentCount = await db.query(tableName).count();
    if (currentCount < scale) {
      await db.clear(tableName);
      final records = _generateRecords(tier, scale);
      await db.batchInsert(
        tableName,
        records,
        allowPartialErrors: false,
        returnResultDetails: false,
      );
    }
  }

  /// Generates synthetic records for insertion.
  List<Map<String, dynamic>> _generateRecords(
    BenchmarkTier tier,
    int count, {
    int seedOffset = 0,
  }) {
    if (tier == BenchmarkTier.simple) {
      return List.generate(count, (i) {
        final idx = seedOffset + i;
        return {
          'text_val': 'benchmark_payload_item_$idx',
          'num_val': idx,
        };
      });
    } else {
      return List.generate(count, (i) {
        final idx = seedOffset + i;
        return {
          'name': 'user_$idx',
          'age': 18 + (idx % 60),
          'score': (idx * 1.25) % 100.0,
          'created_at': DateTime.now().toIso8601String(),
        };
      });
    }
  }

  /// Generates synthetic update records targeting existing primary keys.
  List<Map<String, dynamic>> _generateUpdateRecords(
    BenchmarkTier tier,
    int count,
    int round,
  ) {
    if (tier == BenchmarkTier.simple) {
      return List.generate(count, (i) {
        return {
          'id': i + 1,
          'text_val': 'updated_payload_${round}_$i',
          'num_val': (i + round) * 10,
        };
      });
    } else {
      return List.generate(count, (i) {
        return {
          'id': i + 1,
          'name': 'user_${i}_v$round',
          'age': 20 + ((i + round) % 55),
          'score': 90.0 + (round % 10),
        };
      });
    }
  }

  /// Generates synthetic records for upsert testing (50% updates, 50% inserts).
  List<Map<String, dynamic>> _generateUpsertRecords(
    BenchmarkTier tier,
    int count,
    int round,
  ) {
    final half = count ~/ 2;
    if (tier == BenchmarkTier.simple) {
      return List.generate(count, (i) {
        final isExisting = i < half;
        final targetId =
            isExisting ? (i + 1) : (count + (round * count) + i + 1);
        return {
          'id': targetId,
          'text_val': isExisting
              ? 'upsert_updated_${round}_$i'
              : 'upsert_new_${round}_$i',
          'num_val': i + (round * 100),
        };
      });
    } else {
      return List.generate(count, (i) {
        final isExisting = i < half;
        final targetId =
            isExisting ? (i + 1) : (count + (round * count) + i + 1);
        return {
          'id': targetId,
          'name': isExisting ? 'user_${i}_upd$round' : 'user_new_${round}_$i',
          'age': 21 + (i % 50),
          'score': 75.5,
          'created_at': DateTime.now().toIso8601String(),
        };
      });
    }
  }
}
