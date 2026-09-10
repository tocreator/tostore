import 'dart:io';
import 'package:tostore/tostore.dart';

/// Comprehensive CRUD Throughput Benchmark for ToStore.
/// Evaluates Batch (100,000 records) and Single (10,000 records) throughput
/// across Insert, Update, and Delete operations for 3 rounds under RecoveryDurability.standard.
///
/// Usage:
///   dart run example/test/crud_throughput_benchmark.dart
void main() async {
  final tempDir = Directory(
    '${Directory.systemTemp.path}/tostore_crud_bench_${DateTime.now().millisecondsSinceEpoch}',
  );

  const durability = RecoveryDurability.standard;
  const int batchScale = 100000;
  const int singleScale = 10000;
  const int totalRounds = 3;

  stdout.writeln(
      '================================================================');
  stdout.writeln(' ToStore Full CRUD Throughput Benchmark');
  stdout.writeln(
      '================================================================');
  stdout.writeln('Database path:     ${tempDir.path}');
  stdout.writeln('Durability:        $durability');
  stdout.writeln('Rounds:            $totalRounds');
  stdout.writeln('Batch scale:       $batchScale records/op');
  stdout.writeln('Single scale:      $singleScale records/op');
  stdout.writeln(
      '================================================================\n');

  // Metrics tracker
  final batchInsertMs = <int>[];
  final batchUpdateMs = <int>[];
  final batchDeleteMs = <int>[];

  final singleInsertMs = <int>[];
  final singleUpdateMs = <int>[];
  final singleDeleteMs = <int>[];

  try {
    final db = await ToStore.open(dbPath: tempDir.path);

    // Common Schema factory
    TableSchema createSchema(String name) => TableSchema(
          name: name,
          primaryKeyConfig: const PrimaryKeyConfig(
            name: 'id',
            type: PrimaryKeyType.sequential,
          ),
          fields: const [
            FieldSchema(name: 'text_val', type: DataType.text, nullable: false),
            FieldSchema(
                name: 'num_val', type: DataType.integer, nullable: false),
          ],
          indexes: const [],
        );

    final batchSchema = createSchema('bench_batch_crud');
    final singleSchema = createSchema('bench_single_crud');

    await db.createTable(batchSchema);
    await db.createTable(singleSchema);

    // =========================================================================
    // PART 1: Batch CRUD Operations (100,000 records)
    // =========================================================================
    stdout.writeln(
        '----------------------------------------------------------------');
    stdout.writeln(' PART 1: Batch CRUD Operations ($batchScale records)');
    stdout.writeln(
        '----------------------------------------------------------------');

    for (int r = 1; r <= totalRounds; r++) {
      stdout.writeln('>>> [Batch] Round $r / $totalRounds <<<');

      // 1. Batch Insert
      final insertRecords = List.generate(
        batchScale,
        (i) => {
          'text_val': 'batch_init_val_r${r}_$i',
          'num_val': i,
        },
      );
      final swInsert = Stopwatch()..start();
      final insRes = await db.batchInsert(
        batchSchema.name,
        insertRecords,
        allowPartialErrors: false,
        returnResultDetails: false,
        durability: durability,
      );
      swInsert.stop();
      final insMs = swInsert.elapsedMilliseconds;
      final insOps = (batchScale / (swInsert.elapsedMicroseconds / 1000000))
          .toStringAsFixed(0);
      batchInsertMs.add(insMs);
      stdout.writeln(
          '  [Batch Insert] $insMs ms -> ${insOps.padLeft(7)} OPS (success: ${!insRes.hasErrors})');

      // 2. Batch Update
      // ToStore batchUpdate updates records matching primary key `id`
      // Sequential PK starts from 1 + (r - 1) * batchScale
      final startId = (r - 1) * batchScale + 1;
      final updateRecords = List.generate(
        batchScale,
        (i) => {
          'id': startId + i,
          'text_val': 'batch_updated_val_r${r}_$i',
          'num_val': i + 1000000,
        },
      );
      final swUpdate = Stopwatch()..start();
      final upRes = await db.batchUpdate(
        batchSchema.name,
        updateRecords,
        allowPartialErrors: false,
        returnResultDetails: false,
        durability: durability,
      );
      swUpdate.stop();
      final upMs = swUpdate.elapsedMilliseconds;
      final upOps = (batchScale / (swUpdate.elapsedMicroseconds / 1000000))
          .toStringAsFixed(0);
      batchUpdateMs.add(upMs);
      stdout.writeln(
          '  [Batch Update] $upMs ms -> ${upOps.padLeft(7)} OPS (success: ${!upRes.hasErrors})');

      // 3. Batch Delete
      final swDelete = Stopwatch()..start();
      final delRes = await db
          .delete(batchSchema.name)
          .where('id', '>=', startId)
          .where('id', '<=', startId + batchScale - 1)
          .allowLargeScaleOperation()
          .durability(durability);
      swDelete.stop();
      final delMs = swDelete.elapsedMilliseconds;
      final delOps = (batchScale / (swDelete.elapsedMicroseconds / 1000000))
          .toStringAsFixed(0);
      batchDeleteMs.add(delMs);
      stdout.writeln(
          '  [Batch Delete] $delMs ms -> ${delOps.padLeft(7)} OPS (deleted: ${delRes.successCount})\n');
    }

    // =========================================================================
    // PART 2: Single Record CRUD Operations (10,000 records)
    // =========================================================================
    stdout.writeln(
        '----------------------------------------------------------------');
    stdout.writeln(
        ' PART 2: Single Record CRUD Operations ($singleScale records)');
    stdout.writeln(
        '----------------------------------------------------------------');

    for (int r = 1; r <= totalRounds; r++) {
      stdout.writeln('>>> [Single] Round $r / $totalRounds <<<');

      final startId = (r - 1) * singleScale + 1;

      // 1. Single Insert
      final swInsert = Stopwatch()..start();
      for (int i = 0; i < singleScale; i++) {
        await db.insert(
          singleSchema.name,
          {
            'text_val': 'single_val_r${r}_$i',
            'num_val': i,
          },
          durability: durability,
        );
      }
      swInsert.stop();
      final insMs = swInsert.elapsedMilliseconds;
      final insOps = (singleScale / (swInsert.elapsedMicroseconds / 1000000))
          .toStringAsFixed(0);
      singleInsertMs.add(insMs);
      stdout.writeln(
          '  [Single Insert] ${insMs.toString().padLeft(4)} ms -> ${insOps.padLeft(6)} OPS (avg: ${(swInsert.elapsedMicroseconds / singleScale).toStringAsFixed(1)} μs/op)');

      // 2. Single Update
      final swUpdate = Stopwatch()..start();
      for (int i = 0; i < singleScale; i++) {
        final id = startId + i;
        await db
            .update(singleSchema.name, {
              'text_val': 'single_up_r${r}_$i',
              'num_val': i + 500000,
            })
            .where('id', '=', id)
            .durability(durability);
      }
      swUpdate.stop();
      final upMs = swUpdate.elapsedMilliseconds;
      final upOps = (singleScale / (swUpdate.elapsedMicroseconds / 1000000))
          .toStringAsFixed(0);
      singleUpdateMs.add(upMs);
      stdout.writeln(
          '  [Single Update] ${upMs.toString().padLeft(4)} ms -> ${upOps.padLeft(6)} OPS (avg: ${(swUpdate.elapsedMicroseconds / singleScale).toStringAsFixed(1)} μs/op)');

      // 3. Single Delete
      final swDelete = Stopwatch()..start();
      for (int i = 0; i < singleScale; i++) {
        final id = startId + i;
        await db
            .delete(singleSchema.name)
            .where('id', '=', id)
            .durability(durability);
      }
      swDelete.stop();
      final delMs = swDelete.elapsedMilliseconds;
      final delOps = (singleScale / (swDelete.elapsedMicroseconds / 1000000))
          .toStringAsFixed(0);
      singleDeleteMs.add(delMs);
      stdout.writeln(
          '  [Single Delete] ${delMs.toString().padLeft(4)} ms -> ${delOps.padLeft(6)} OPS (avg: ${(swDelete.elapsedMicroseconds / singleScale).toStringAsFixed(1)} μs/op)\n');
    }

    // =========================================================================
    // Summary Comparison Matrix
    // =========================================================================
    double calcAvgOps(List<int> msList, int scale) {
      final totalMs = msList.reduce((a, b) => a + b);
      return (msList.length * scale) / (totalMs / 1000.0);
    }

    final avgBatchIns = calcAvgOps(batchInsertMs, batchScale);
    final avgBatchUp = calcAvgOps(batchUpdateMs, batchScale);
    final avgBatchDel = calcAvgOps(batchDeleteMs, batchScale);

    final avgSingleIns = calcAvgOps(singleInsertMs, singleScale);
    final avgSingleUp = calcAvgOps(singleUpdateMs, singleScale);
    final avgSingleDel = calcAvgOps(singleDeleteMs, singleScale);

    stdout.writeln(
        '================================================================');
    stdout.writeln(
        ' CRUD Throughput Summary Matrix ($totalRounds Rounds Average)');
    stdout.writeln(
        '================================================================');
    stdout.writeln(
        ' Operation | Batch OPS (100k) | Single OPS (10k) | Batch Speedup');
    stdout.writeln(
        '-----------+------------------+------------------+--------------');
    stdout.writeln(
        ' Insert    | ${avgBatchIns.toStringAsFixed(0).padLeft(16)} | ${avgSingleIns.toStringAsFixed(0).padLeft(16)} | ${(avgBatchIns / avgSingleIns).toStringAsFixed(1).padLeft(10)}x');
    stdout.writeln(
        ' Update    | ${avgBatchUp.toStringAsFixed(0).padLeft(16)} | ${avgSingleUp.toStringAsFixed(0).padLeft(16)} | ${(avgBatchUp / avgSingleUp).toStringAsFixed(1).padLeft(10)}x');
    stdout.writeln(
        ' Delete    | ${avgBatchDel.toStringAsFixed(0).padLeft(16)} | ${avgSingleDel.toStringAsFixed(0).padLeft(16)} | ${(avgBatchDel / avgSingleDel).toStringAsFixed(1).padLeft(10)}x');
    stdout.writeln(
        '================================================================\n');

    await db.close();
  } catch (e, st) {
    stderr.writeln('Benchmark Error: $e\n$st');
  } finally {
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
    exit(0);
  }
}
