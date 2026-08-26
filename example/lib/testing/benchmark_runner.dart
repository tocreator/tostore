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

  /// Optimal execution order to ensure queries run against full datasets and destructive deletes run last.
  static const List<BenchmarkOperation> _executionOrder = [
    // 1. Ingestion & Writes
    BenchmarkOperation.batchInsert,
    BenchmarkOperation.singleInsert,
    // 2. Updates & Upserts
    BenchmarkOperation.batchUpdate,
    BenchmarkOperation.singleUpdate,
    BenchmarkOperation.batchUpsert,
    // 3. Queries & Scans (Non-destructive: runs against populated dataset)
    BenchmarkOperation.pointReadHot,
    BenchmarkOperation.pointReadRandom,
    BenchmarkOperation.indexedSeekHot,
    BenchmarkOperation.indexedSeekRandom,
    BenchmarkOperation.rangeScanHot,
    BenchmarkOperation.rangeScanRandom,
    BenchmarkOperation.paginationHot,
    BenchmarkOperation.paginationRandom,
    BenchmarkOperation.count,
    // 4. Deletions (Destructive operations executed last)
    BenchmarkOperation.batchDelete,
    BenchmarkOperation.singleDelete,
  ];

  BenchmarkRunner(this.db, this.log, this._updateLastOperation);

  /// Executes the full benchmark suite according to the provided [config].
  Future<BenchmarkSummary> runBenchmark(BenchmarkConfig config) async {
    log.add(
      '🚀 Starting Benchmark Suite [Scale: ${config.scale}, Tier: ${config.tier.label}, Iterations: ${config.iterations}]',
      LogLevel.info,
    );

    // 1. Ensure benchmark tables exist and are clean before starting
    await BenchmarkSchemas.ensureTables(db);
    await db.clear(BenchmarkSchemas.simpleTable);
    await db.clear(BenchmarkSchemas.indexedTable);

    try {
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

        // Sort operations by optimal execution order:
        // Ingestion -> Updates -> Queries (against full table) -> Deletions (destructive last)
        final sortedOps = config.operations.toList()
          ..sort((a, b) {
            final aIdx = _executionOrder.indexOf(a);
            final bIdx = _executionOrder.indexOf(b);
            return aIdx.compareTo(bIdx);
          });

        bool flushedBeforeQueries = false;

        for (final op in sortedOps) {
          // Skip indexedSeek on simple tier (has no secondary unique index)
          if (currentTier == BenchmarkTier.simple &&
              (op == BenchmarkOperation.indexedSeekHot ||
                  op == BenchmarkOperation.indexedSeekRandom)) {
            continue;
          }

          // If transitioning from Mutation phase (Insert/Update/Upsert) to Query phase (Read/Seek/Scan/Pagination),
          // flush all queued writes to disk once so queries execute on a settled, quiescent disk pipeline.
          final isQueryOp = op == BenchmarkOperation.pointReadHot ||
              op == BenchmarkOperation.pointReadRandom ||
              op == BenchmarkOperation.indexedSeekHot ||
              op == BenchmarkOperation.indexedSeekRandom ||
              op == BenchmarkOperation.rangeScanHot ||
              op == BenchmarkOperation.rangeScanRandom ||
              op == BenchmarkOperation.paginationHot ||
              op == BenchmarkOperation.paginationRandom ||
              op == BenchmarkOperation.count;

          if (isQueryOp && !flushedBeforeQueries) {
            flushedBeforeQueries = true;
            _updateLastOperation(
                'Flushing write pipeline to disk before queries...');
            await db.flush();
            await Future.delayed(const Duration(milliseconds: 15));
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

      // Sort metrics by display order (Insert -> Update -> Delete -> Read -> Count)
      allMetrics.sort((a, b) {
        if (a.tierName != b.tierName) {
          if (a.tierName == 'Simple') return -1;
          if (b.tierName == 'Simple') return 1;
        }
        final aOpIndex =
            BenchmarkOperation.values.indexWhere((op) => op.label == a.name);
        final bOpIndex =
            BenchmarkOperation.values.indexWhere((op) => op.label == b.name);
        return aOpIndex.compareTo(bOpIndex);
      });

      final summary = BenchmarkSummary(config: config, metrics: allMetrics);

      // Log the formatted markdown report
      log.add('\n${summary.toMarkdownTable()}', LogLevel.info);
      _updateLastOperation('✅ Benchmark completed successfully');

      return summary;
    } finally {
      // Clean up benchmark tables to avoid occupying memory/disk
      await db.clear(BenchmarkSchemas.simpleTable);
      await db.clear(BenchmarkSchemas.indexedTable);
    }
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
    db.query(BenchmarkSchemas.simpleTable).where('id', '=', 1).peekFirst();
    db
        .query(BenchmarkSchemas.indexedTable)
        .where('name', '=', 'warmup_1')
        .peekFirst();
    db.query(BenchmarkSchemas.simpleTable).limit(10).peek();
    db.query(BenchmarkSchemas.simpleTable).limit(20).peek();

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
        final batchInsertRounds = <List<Map<String, dynamic>>>[
          for (var round = 1; round <= iterations; round++)
            _generateRecords(tier, scale, seedOffset: round * scale),
        ];
        for (var round = 1; round <= iterations; round++) {
          _updateLastOperation(
              'Running [$tierName] Batch Insert ($round/$iterations)...');
          await db.clear(tableName);

          final sw = Stopwatch()..start();
          await db.batchInsert(
            tableName,
            batchInsertRounds[round - 1],
            allowPartialErrors: false,
            returnResultDetails: false,
          );
          sw.stop();
          roundMicroseconds.add(sw.elapsedMicroseconds);
          await Future.delayed(const Duration(milliseconds: 5));
        }
        break;

      case BenchmarkOperation.singleInsert:
        // Cap single-row insert scale to keep wall-clock reasonable.
        effectiveCount = math.min(scale, 10000);
        final singleInsertRounds = <List<Map<String, dynamic>>>[
          for (var round = 1; round <= iterations; round++)
            _generateRecords(tier, effectiveCount,
                seedOffset: round * effectiveCount),
        ];
        for (var round = 1; round <= iterations; round++) {
          _updateLastOperation(
              'Running [$tierName] Single Insert ($round/$iterations)...');
          await db.clear(tableName);

          final records = singleInsertRounds[round - 1];
          final sw = Stopwatch()..start();
          for (final record in records) {
            await db.insert(tableName, record);
          }
          sw.stop();
          roundMicroseconds.add(sw.elapsedMicroseconds);
          await Future.delayed(const Duration(milliseconds: 5));
        }
        break;

      case BenchmarkOperation.batchUpdate:
        effectiveCount = scale;
        // Pre-generate all rounds before touching the write buffer, then insert
        // once and update immediately so the pending queue keeps growing.
        final batchUpdateRounds = <List<Map<String, dynamic>>>[
          for (var round = 1; round <= iterations; round++)
            _generateUpdateRecords(tier, scale, round),
        ];
        final batchUpdateBase = _generateRecords(tier, scale);
        await _loadBufferDataset(tableName, batchUpdateBase);

        for (var round = 1; round <= iterations; round++) {
          _updateLastOperation(
              'Running [$tierName] Batch Update ($round/$iterations)...');

          final sw = Stopwatch()..start();
          await db.batchUpdate(
            tableName,
            batchUpdateRounds[round - 1],
            allowPartialErrors: false,
            returnResultDetails: false,
          );
          sw.stop();
          roundMicroseconds.add(sw.elapsedMicroseconds);
          await Future.delayed(const Duration(milliseconds: 5));
        }
        break;

      case BenchmarkOperation.singleUpdate:
        effectiveCount = math.min(scale, 10000);
        final singleUpdateRounds = <List<Map<String, dynamic>>>[
          for (var round = 1; round <= iterations; round++)
            _generateUpdateRecords(tier, effectiveCount, round),
        ];
        final singleUpdateBase = _generateRecords(tier, effectiveCount);
        await _loadBufferDataset(tableName, singleUpdateBase);

        for (var round = 1; round <= iterations; round++) {
          _updateLastOperation(
              'Running [$tierName] Single Update ($round/$iterations)...');
          final updateRecords = singleUpdateRounds[round - 1];

          final sw = Stopwatch()..start();
          for (final record in updateRecords) {
            final id = record['id'];
            await db.update(tableName, record).where('id', '=', id);
          }
          sw.stop();
          roundMicroseconds.add(sw.elapsedMicroseconds);
          await Future.delayed(const Duration(milliseconds: 5));
        }
        break;

      case BenchmarkOperation.batchUpsert:
        effectiveCount = scale;
        // 50% update existing IDs, 50% insert new IDs with explicit PKs
        final batchUpsertRounds = <List<Map<String, dynamic>>>[
          for (var round = 1; round <= iterations; round++)
            _generateUpsertRecords(tier, scale, round),
        ];
        final batchUpsertBase = _generateRecords(tier, scale);
        await _loadBufferDataset(tableName, batchUpsertBase);

        for (var round = 1; round <= iterations; round++) {
          _updateLastOperation(
              'Running [$tierName] Batch Upsert ($round/$iterations)...');

          final sw = Stopwatch()..start();
          await db.batchUpsert(
            tableName,
            batchUpsertRounds[round - 1],
            allowPartialErrors: false,
            returnResultDetails: false,
          );
          sw.stop();
          roundMicroseconds.add(sw.elapsedMicroseconds);
          await Future.delayed(const Duration(milliseconds: 5));
        }
        break;

      case BenchmarkOperation.batchDelete:
        effectiveCount = scale;
        // Independent buffer-hot rounds: shared base payload, insert then delete
        // with no idle gap (avoids 1s pending-queue settle → disk delete).
        final batchDeleteBase = _generateRecords(tier, scale);
        for (var round = 1; round <= iterations; round++) {
          _updateLastOperation(
              'Running [$tierName] Batch Delete ($round/$iterations)...');
          await _loadBufferDataset(tableName, batchDeleteBase);

          final sw = Stopwatch()..start();
          await db
              .delete(tableName)
              .where('id', '<=', scale)
              .allowLargeScaleOperation();
          sw.stop();
          roundMicroseconds.add(sw.elapsedMicroseconds);
          await Future.delayed(const Duration(milliseconds: 5));
        }
        break;

      case BenchmarkOperation.singleDelete:
        effectiveCount = math.min(scale, 10000);
        final singleDeleteBase = _generateRecords(tier, effectiveCount);
        for (var round = 1; round <= iterations; round++) {
          _updateLastOperation(
              'Running [$tierName] Single Delete ($round/$iterations)...');
          await _loadBufferDataset(tableName, singleDeleteBase);

          final sw = Stopwatch()..start();
          for (var id = 1; id <= effectiveCount; id++) {
            await db.delete(tableName).where('id', '=', id);
          }
          sw.stop();
          roundMicroseconds.add(sw.elapsedMicroseconds);
          await Future.delayed(const Duration(milliseconds: 5));
        }
        break;

      case BenchmarkOperation.pointReadHot:
        // Query phase already flushed once; ensure durable row count for seeks.
        await _ensureDurableDataset(tableName, tier, scale);
        effectiveCount = scale;

        // Pre-warm the single hot primary key into memory cache
        db.query(tableName).where('id', '=', 1).peekFirst();

        for (var round = 1; round <= iterations; round++) {
          _updateLastOperation(
              'Running [$tierName] PK Read (Hot Cache) ($round/$iterations)...');

          final sw = Stopwatch()..start();
          for (var i = 0; i < effectiveCount; i++) {
            db.query(tableName).where('id', '=', 1).peekFirst();
          }
          sw.stop();
          roundMicroseconds.add(sw.elapsedMicroseconds);
          await Future.delayed(const Duration(milliseconds: 5));
        }
        break;

      case BenchmarkOperation.pointReadRandom:
        await _ensureDurableDataset(tableName, tier, scale);
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

      case BenchmarkOperation.indexedSeekHot:
        if (tier != BenchmarkTier.indexed) return null;
        await _ensureDurableDataset(tableName, tier, scale);
        effectiveCount = scale;

        // Pre-warm unique index hot lookup
        db.query(tableName).where('name', '=', 'user_0').peekFirst();

        for (var round = 1; round <= iterations; round++) {
          _updateLastOperation(
              'Running [$tierName] Indexed Seek (Hot Cache) ($round/$iterations)...');

          final sw = Stopwatch()..start();
          for (var i = 0; i < effectiveCount; i++) {
            db.query(tableName).where('name', '=', 'user_0').peekFirst();
          }
          sw.stop();
          roundMicroseconds.add(sw.elapsedMicroseconds);
          await Future.delayed(const Duration(milliseconds: 5));
        }
        break;

      case BenchmarkOperation.indexedSeekRandom:
        if (tier != BenchmarkTier.indexed) return null;
        await _ensureDurableDataset(tableName, tier, scale);
        effectiveCount = scale;
        final random = math.Random(1337);

        for (var round = 1; round <= iterations; round++) {
          _updateLastOperation(
              'Running [$tierName] Indexed Seek (Random) ($round/$iterations)...');
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

      case BenchmarkOperation.rangeScanHot:
        await _ensureDurableDataset(tableName, tier, scale);
        effectiveCount = scale;

        // Pre-warm the fixed range into memory cache
        if (tier == BenchmarkTier.simple) {
          db.query(tableName).where('id', '>=', 1).limit(10).peek();
        } else {
          db
              .query(tableName)
              .where('age', '>=', 20)
              .orderByAsc('age')
              .limit(10)
              .peek();
        }

        for (var round = 1; round <= iterations; round++) {
          _updateLastOperation(
              'Running [$tierName] Range Scan (Hot Cache) ($round/$iterations)...');

          final sw = Stopwatch()..start();
          for (var i = 0; i < effectiveCount; i++) {
            if (tier == BenchmarkTier.simple) {
              db.query(tableName).where('id', '>=', 1).limit(10).peek();
            } else {
              db
                  .query(tableName)
                  .where('age', '>=', 20)
                  .orderByAsc('age')
                  .limit(10)
                  .peek();
            }
          }
          sw.stop();
          roundMicroseconds.add(sw.elapsedMicroseconds);
          await Future.delayed(const Duration(milliseconds: 5));
        }
        break;

      case BenchmarkOperation.rangeScanRandom:
        await _ensureDurableDataset(tableName, tier, scale);
        // Standardized query sample count up to 10,000 queries for statistically solid metrics without long stalls
        effectiveCount = math.min(scale, 10000);
        final random = math.Random(777);

        for (var round = 1; round <= iterations; round++) {
          _updateLastOperation(
              'Running [$tierName] Range Scan (Random) ($round/$iterations)...');

          // Pre-generate random start keys before timing to evaluate pure database performance
          final startPoints = tier == BenchmarkTier.simple
              ? List.generate(
                  effectiveCount,
                  (_) => random.nextInt(math.max(1, scale - 10)) + 1,
                )
              : List.generate(
                  effectiveCount,
                  (_) => 18 + random.nextInt(45),
                );

          final sw = Stopwatch()..start();
          for (var i = 0; i < effectiveCount; i++) {
            final startVal = startPoints[i];
            if (tier == BenchmarkTier.simple) {
              await db.query(tableName).where('id', '>=', startVal).limit(10);
            } else {
              await db
                  .query(tableName)
                  .where('age', '>=', startVal)
                  .orderByAsc('age')
                  .limit(10);
            }
          }
          sw.stop();
          roundMicroseconds.add(sw.elapsedMicroseconds);
          await Future.delayed(const Duration(milliseconds: 5));
        }
        break;

      case BenchmarkOperation.paginationHot:
        await _ensureDurableDataset(tableName, tier, scale);
        effectiveCount = scale;

        // Pre-warm hot page into memory cache
        db.query(tableName).limit(20).peek();

        for (var round = 1; round <= iterations; round++) {
          _updateLastOperation(
              'Running [$tierName] Pagination (Hot Cache) ($round/$iterations)...');

          final sw = Stopwatch()..start();
          for (var i = 0; i < effectiveCount; i++) {
            db.query(tableName).limit(20).peek();
          }
          sw.stop();
          roundMicroseconds.add(sw.elapsedMicroseconds);
          await Future.delayed(const Duration(milliseconds: 5));
        }
        break;

      case BenchmarkOperation.paginationRandom:
        await _ensureDurableDataset(tableName, tier, scale);
        // Standardized query sample count up to 10,000 queries for statistically solid metrics without long stalls
        effectiveCount = math.min(scale, 10000);
        final random = math.Random(999);

        for (var round = 1; round <= iterations; round++) {
          _updateLastOperation(
              'Running [$tierName] Pagination (Random) ($round/$iterations)...');

          // Keyset / Cursor-based pagination avoids O(N) offset scanning degradation
          final startCursors = List.generate(
            effectiveCount,
            (_) => random.nextInt(math.max(1, scale - 20)),
          );

          final sw = Stopwatch()..start();
          for (var i = 0; i < effectiveCount; i++) {
            await db
                .query(tableName)
                .where('id', '>', startCursors[i])
                .limit(20);
          }
          sw.stop();
          roundMicroseconds.add(sw.elapsedMicroseconds);
          await Future.delayed(const Duration(milliseconds: 5));
        }
        break;

      case BenchmarkOperation.count:
        await _ensureDurableDataset(tableName, tier, scale);
        effectiveCount = scale;

        for (var round = 1; round <= iterations; round++) {
          _updateLastOperation(
              'Running [$tierName] Count ($round/$iterations)...');

          final sw = Stopwatch()..start();
          for (var i = 0; i < effectiveCount; i++) {
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

  /// Loads [records] into the write buffer only (no flush).
  ///
  /// Used by update/upsert/delete setup so timed mutations stay on the
  /// pending-queue hot path. Callers must pre-build [records] and invoke the
  /// timed mutation immediately afterward to avoid a >1s idle settle flush.
  Future<void> _loadBufferDataset(
    String tableName,
    List<Map<String, dynamic>> records,
  ) async {
    await db.clear(tableName);
    await db.batchInsert(
      tableName,
      records,
      allowPartialErrors: false,
      returnResultDetails: false,
    );
  }

  /// Ensures the table has at least [scale] rows for query benches.
  ///
  /// Repopulates only when short; flushes that refill so reads hit a settled
  /// disk pipeline. Prefer the suite-level flush before the query phase when
  /// mutation left enough rows already.
  Future<void> _ensureDurableDataset(
    String tableName,
    BenchmarkTier tier,
    int scale,
  ) async {
    final currentCount = await db.query(tableName).count();
    if (currentCount >= scale) return;

    final records = _generateRecords(tier, scale);
    await _loadBufferDataset(tableName, records);
    await db.flush();
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
          'created_at': DateTime.now().toIso8601String(),
        };
      });
    }
  }
}
