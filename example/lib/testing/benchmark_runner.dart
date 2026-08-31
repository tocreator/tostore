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
    BenchmarkOperation.vectorBatchInsert,
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
    BenchmarkOperation.vectorSearch,
    BenchmarkOperation.vectorHybridSearch,
    BenchmarkOperation.vectorRecallCheck,
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
    await db.clear(BenchmarkSchemas.simple.name);
    await db.clear(BenchmarkSchemas.indexed.name);
    await db.clear(BenchmarkSchemas.vector.name);

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
      if (config.tier == BenchmarkTier.vector ||
          config.tier == BenchmarkTier.all) {
        tiersToRun.add(BenchmarkTier.vector);
      }

      for (final currentTier in tiersToRun) {
        final tierName = switch (currentTier) {
          BenchmarkTier.simple => 'Simple',
          BenchmarkTier.indexed => 'Indexed',
          BenchmarkTier.vector => 'Vector',
          BenchmarkTier.all => 'All',
        };
        final tableName = switch (currentTier) {
          BenchmarkTier.simple => BenchmarkSchemas.simple.name,
          BenchmarkTier.indexed => BenchmarkSchemas.indexed.name,
          BenchmarkTier.vector => BenchmarkSchemas.vector.name,
          BenchmarkTier.all => BenchmarkSchemas.simple.name,
        };

        // Sort operations by optimal execution order:
        // Ingestion -> Updates -> Queries (against full table) -> Deletions (destructive last)
        final sortedOps =
            config.operations.where((op) => op.appliesTo(currentTier)).toList()
              ..sort((a, b) {
                final aIdx = _executionOrder.indexOf(a);
                final bIdx = _executionOrder.indexOf(b);
                return aIdx.compareTo(bIdx);
              });

        bool flushedBeforeQueries = false;

        for (final op in sortedOps) {
          // If transitioning from Mutation phase to Query phase,
          // flush all queued writes to disk once so queries execute on a settled pipeline.
          final isQueryOp = op == BenchmarkOperation.pointReadHot ||
              op == BenchmarkOperation.pointReadRandom ||
              op == BenchmarkOperation.indexedSeekHot ||
              op == BenchmarkOperation.indexedSeekRandom ||
              op == BenchmarkOperation.rangeScanHot ||
              op == BenchmarkOperation.rangeScanRandom ||
              op == BenchmarkOperation.paginationHot ||
              op == BenchmarkOperation.paginationRandom ||
              op == BenchmarkOperation.count ||
              op == BenchmarkOperation.vectorSearch ||
              op == BenchmarkOperation.vectorHybridSearch ||
              op == BenchmarkOperation.vectorRecallCheck;

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
            final highlight = metric.compactHighlight ??
                '${metric.opsPerSec.toStringAsFixed(0)} ops/s | ${metric.avgLatencyUs.toStringAsFixed(2)} μs/op';
            log.add(
              '⚡ [$tierName] ${metric.name}: ${metric.compactHighlight != null ? highlight : '${metric.avgMilliseconds.toStringAsFixed(2)} ms ($highlight)'}${metric.qualityNote != null ? ' · ${metric.qualityNote}' : ''}',
              LogLevel.info,
            );
          }

          // Yield to allow UI frame updates
          await Future.delayed(const Duration(milliseconds: 10));
        }
      }

      // Sort metrics by display order (tier then enum order)
      allMetrics.sort((a, b) {
        if (a.tierName != b.tierName) {
          const order = ['Simple', 'Indexed', 'Vector'];
          final aIdx = order.indexOf(a.tierName);
          final bIdx = order.indexOf(b.tierName);
          return aIdx.compareTo(bIdx);
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
      await db.clear(BenchmarkSchemas.simple.name);
      await db.clear(BenchmarkSchemas.indexed.name);
      await db.clear(BenchmarkSchemas.vector.name);
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
    final vectorWarmupData =
        _generateRecords(BenchmarkTier.vector, warmupCount);

    // Batch insert and query warmup
    await db.batchInsert(
      BenchmarkSchemas.simple.name,
      simpleWarmupData,
      allowPartialErrors: false,
      returnResultDetails: false,
    );
    await db.batchInsert(
      BenchmarkSchemas.indexed.name,
      indexedWarmupData,
      allowPartialErrors: false,
      returnResultDetails: false,
    );
    await db.batchInsert(
      BenchmarkSchemas.vector.name,
      vectorWarmupData,
      allowPartialErrors: false,
      returnResultDetails: false,
    );

    await db.query(BenchmarkSchemas.simple.name);
    await db.query(BenchmarkSchemas.indexed.name).where('age', '>=', 25);
    db.query(BenchmarkSchemas.simple.name).where('id', '=', 1).peekFirst();
    db
        .query(BenchmarkSchemas.indexed.name)
        .where('name', '=', 'warmup_1')
        .peekFirst();
    db.query(BenchmarkSchemas.simple.name).limit(10).peek();
    db.query(BenchmarkSchemas.simple.name).limit(20).peek();

    final warmupVec = vectorWarmupData.first['embedding'] as VectorData;
    // Warm both paths: standalone ANN (PK-only) and hybrid chain (full rows).
    await db.vectorSearch(
      BenchmarkSchemas.vector.name,
      fieldName: 'embedding',
      queryVector: warmupVec,
      topK: BenchmarkSchemas.vectorTopK,
    );
    await db
        .query(BenchmarkSchemas.vector.name)
        .where('category', '=', 0)
        .matchVector('embedding', warmupVec)
        .limit(BenchmarkSchemas.vectorTopK);

    await db.clear(BenchmarkSchemas.simple.name);
    await db.clear(BenchmarkSchemas.indexed.name);
    await db.clear(BenchmarkSchemas.vector.name);
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
    String? qualityNote;
    String? compactHighlight;

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

      case BenchmarkOperation.vectorBatchInsert:
        if (tier != BenchmarkTier.vector) return null;
        // Cap ingest scale so NGH construction stays practical on edge devices.
        effectiveCount = math.min(scale, 10000);
        final vectorInsertRounds = <List<Map<String, dynamic>>>[
          for (var round = 1; round <= iterations; round++)
            _generateRecords(tier, effectiveCount,
                seedOffset: round * effectiveCount),
        ];
        for (var round = 1; round <= iterations; round++) {
          _updateLastOperation(
              'Running [$tierName] Vector Batch Insert ($round/$iterations)...');
          await db.clear(tableName);

          final sw = Stopwatch()..start();
          await db.batchInsert(
            tableName,
            vectorInsertRounds[round - 1],
            allowPartialErrors: false,
            returnResultDetails: false,
          );
          sw.stop();
          roundMicroseconds.add(sw.elapsedMicroseconds);
          await Future.delayed(const Duration(milliseconds: 5));
        }
        break;

      case BenchmarkOperation.vectorSearch:
        if (tier != BenchmarkTier.vector) return null;
        final datasetScale = math.min(scale, 10000);
        await _ensureDurableDataset(tableName, tier, datasetScale);
        // Query sample count: enough for stable QPS without multi-minute stalls.
        effectiveCount = math.min(datasetScale, 1000);
        final random = math.Random(4242);

        for (var round = 1; round <= iterations; round++) {
          _updateLastOperation(
              'Running [$tierName] Vector ANN Search ($round/$iterations)...');
          final querySeeds = List.generate(
            effectiveCount,
            (_) => random.nextInt(datasetScale),
          );

          // Pure ANN: PK + score only — aligns with mainstream vector-DB latency.
          final sw = Stopwatch()..start();
          for (final seed in querySeeds) {
            await db.vectorSearch(
              tableName,
              fieldName: 'embedding',
              queryVector: _unitVector(seed),
              topK: BenchmarkSchemas.vectorTopK,
            );
          }
          sw.stop();
          roundMicroseconds.add(sw.elapsedMicroseconds);
          await Future.delayed(const Duration(milliseconds: 5));
        }
        break;

      case BenchmarkOperation.vectorHybridSearch:
        if (tier != BenchmarkTier.vector) return null;
        final hybridScale = math.min(scale, 10000);
        await _ensureDurableDataset(tableName, tier, hybridScale);
        effectiveCount = math.min(hybridScale, 1000);
        final random = math.Random(5252);

        for (var round = 1; round <= iterations; round++) {
          _updateLastOperation(
              'Running [$tierName] Vector Hybrid Search ($round/$iterations)...');
          final querySeeds = List.generate(
            effectiveCount,
            (_) => random.nextInt(hybridScale),
          );

          final sw = Stopwatch()..start();
          for (final seed in querySeeds) {
            final category = seed % 16;
            await db
                .query(tableName)
                .where('category', '=', category)
                .matchVector('embedding', _unitVector(seed))
                .limit(BenchmarkSchemas.vectorTopK);
          }
          sw.stop();
          roundMicroseconds.add(sw.elapsedMicroseconds);
          await Future.delayed(const Duration(milliseconds: 5));
        }
        break;

      case BenchmarkOperation.vectorRecallCheck:
        if (tier != BenchmarkTier.vector) return null;
        final corpusScale = math.min(scale, 10000);
        await _ensureDurableDataset(tableName, tier, corpusScale);
        // Count = probe sample size (not corpus size).
        effectiveCount = math.min(
          BenchmarkSchemas.vectorRecallProbes,
          corpusScale,
        );
        final topK = BenchmarkSchemas.vectorTopK;
        final midK = math.min(5, topK);
        final random = math.Random(6262);
        var hitAt1 = 0;
        var hitAtMid = 0;
        var hitAtK = 0;
        var probes = 0;

        for (var round = 1; round <= iterations; round++) {
          _updateLastOperation(
              'Running [$tierName] Vector Recall Check ($round/$iterations)...');
          final querySeeds = List.generate(
            effectiveCount,
            (_) => random.nextInt(corpusScale),
          );

          final sw = Stopwatch()..start();
          for (final seed in querySeeds) {
            // Sequential PK: slot i inserted as id = i + 1 with embedding seed i.
            final targetId = (seed + 1).toString();
            final hits = await db.vectorSearch(
              tableName,
              fieldName: 'embedding',
              queryVector: _unitVector(seed),
              topK: topK,
            );
            probes++;
            var rank = -1;
            for (var i = 0; i < hits.length; i++) {
              if (hits[i].primaryKey == targetId) {
                rank = i + 1;
                break;
              }
            }
            if (rank < 0) continue;
            if (rank <= 1) hitAt1++;
            if (rank <= midK) hitAtMid++;
            if (rank <= topK) hitAtK++;
          }
          sw.stop();
          roundMicroseconds.add(sw.elapsedMicroseconds);
          await Future.delayed(const Duration(milliseconds: 5));
        }

        final recall1 = probes == 0 ? 0.0 : (hitAt1 * 100.0 / probes);
        final recallMid = probes == 0 ? 0.0 : (hitAtMid * 100.0 / probes);
        final recallK = probes == 0 ? 0.0 : (hitAtK * 100.0 / probes);
        // Percentages only in the table cell — no ops/s mixed in.
        compactHighlight =
            '${recall1.toStringAsFixed(0)}% / ${recallMid.toStringAsFixed(0)}% / ${recallK.toStringAsFixed(0)}%';
        qualityNote =
            'Exact@1=${recall1.toStringAsFixed(1)}%; Exact@$midK=${recallMid.toStringAsFixed(1)}%; Exact@$topK=${recallK.toStringAsFixed(1)}%; probes=$probes; corpus=$corpusScale';
        break;
    }

    return BenchmarkMetric(
      name: op.label,
      tierName: tierName,
      recordCount: effectiveCount,
      roundElapsedMicroseconds: roundMicroseconds,
      qualityNote: qualityNote,
      compactHighlight: compactHighlight,
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
    switch (tier) {
      case BenchmarkTier.simple:
        return List.generate(count, (i) {
          final idx = seedOffset + i;
          return {
            'text_val': 'benchmark_payload_item_$idx',
            'num_val': idx,
          };
        });
      case BenchmarkTier.indexed:
        return List.generate(count, (i) {
          final idx = seedOffset + i;
          return {
            'name': 'user_$idx',
            'age': 18 + (idx % 60),
            'created_at': DateTime.now().toIso8601String(),
          };
        });
      case BenchmarkTier.vector:
        return List.generate(count, (i) {
          final idx = seedOffset + i;
          return {
            'label': 'vec_$idx',
            // Slot-stable embedding seed so ANN queries can recreate vectors
            // after clear/reload without depending on insert round offsets.
            'category': i % 16,
            'embedding': _unitVector(i),
          };
        });
      case BenchmarkTier.all:
        return _generateRecords(BenchmarkTier.simple, count,
            seedOffset: seedOffset);
    }
  }

  /// Deterministic unit vector for reproducible ANN queries (matches insert seeds).
  VectorData _unitVector(int seed) {
    final dims = BenchmarkSchemas.vectorDimensions;
    final rng = math.Random(seed);
    final values = List<double>.generate(dims, (_) {
      final u1 = rng.nextDouble().clamp(1e-10, 1.0);
      final u2 = rng.nextDouble();
      return math.sqrt(-2.0 * math.log(u1)) * math.cos(2.0 * math.pi * u2);
    });
    var normSq = 0.0;
    for (final v in values) {
      normSq += v * v;
    }
    final norm = math.sqrt(normSq);
    if (norm > 0) {
      for (var i = 0; i < dims; i++) {
        values[i] /= norm;
      }
    }
    return VectorData(values);
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
    }
    return List.generate(count, (i) {
      return {
        'id': i + 1,
        'name': 'user_${i}_v$round',
        'age': 20 + ((i + round) % 55),
      };
    });
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
    }
    return List.generate(count, (i) {
      final isExisting = i < half;
      final targetId = isExisting ? (i + 1) : (count + (round * count) + i + 1);
      return {
        'id': targetId,
        'name': isExisting ? 'user_${i}_upd$round' : 'user_new_${round}_$i',
        'age': 21 + (i % 50),
        'created_at': DateTime.now().toIso8601String(),
      };
    });
  }
}
