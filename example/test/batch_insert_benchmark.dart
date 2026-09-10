import 'dart:io';
import 'package:tostore/tostore.dart';

/// Benchmark for ToStore batchInsert throughput.
///
/// Usage:
///   dart run example/test/batch_insert_benchmark.dart
void main() async {
  final tempDir = Directory(
    '${Directory.systemTemp.path}/tostore_bench_user_${DateTime.now().millisecondsSinceEpoch}',
  );

  const testDurabilities = [
    RecoveryDurability.standard,
    RecoveryDurability.async,
  ];
  const int batchSize = 100000;
  const int batches = 5;

  stdout.writeln(
      '================================================================');
  stdout.writeln(' ToStore batchInsert Multi-Durability Benchmark');
  stdout.writeln(
      '================================================================');
  stdout.writeln('Database path:  ${tempDir.path}');
  stdout.writeln('Records/batch:  $batchSize');
  stdout.writeln(
      'Batches/mode:   $batches (${batchSize * batches} records per mode)');
  stdout.writeln(
      'Modes tested:   ${testDurabilities.map((e) => e.name).join(', ')}');
  stdout.writeln(
      '----------------------------------------------------------------\n');

  final avgOpsMap = <RecoveryDurability, double>{};

  try {
    final db = await ToStore.open(dbPath: tempDir.path);

    for (final durability in testDurabilities) {
      final tableName = 'benchmark_${durability.name}';
      final schema = TableSchema(
        name: tableName,
        primaryKeyConfig: const PrimaryKeyConfig(
          name: 'id',
          type: PrimaryKeyType.sequential,
        ),
        fields: const [
          FieldSchema(name: 'text_val', type: DataType.text, nullable: false),
          FieldSchema(name: 'num_val', type: DataType.integer, nullable: false),
        ],
        indexes: const [],
      );
      await db.createTable(schema);

      stdout.writeln(
          '>>> Testing Durability: ${durability.name.toUpperCase()} <<<');

      int warmTotalElapsedMs = 0;
      int warmBatchCount = 0;

      for (int b = 1; b <= batches; b++) {
        // Generate clean payload per batch
        final records = List.generate(
            batchSize,
            (i) => {
                  'text_val': 'benchmark_payload_${durability.name}_${b}_$i',
                  'num_val': i + batchSize * (b - 1),
                });

        final sw = Stopwatch()..start();
        final res = await db.batchInsert(
          schema.name,
          records,
          allowPartialErrors: false,
          returnResultDetails: false,
          durability: durability,
        );
        sw.stop();

        final elapsedMs = sw.elapsedMilliseconds;
        final ops =
            (batchSize / (sw.elapsedMicroseconds / 1000000)).toStringAsFixed(0);
        final isCold = b == 1 ? ' (Cold Start + JIT)' : '';

        stdout.writeln(
            '  Batch $b$isCold: ${elapsedMs.toString().padLeft(4)} ms -> ${ops.padLeft(7)} OPS (success: ${!res.hasErrors})');

        if (b > 1) {
          warmTotalElapsedMs += elapsedMs;
          warmBatchCount++;
        }
      }

      if (warmBatchCount > 0) {
        final avgWarmOps =
            (warmBatchCount * batchSize) / (warmTotalElapsedMs / 1000.0);
        avgOpsMap[durability] = avgWarmOps;
      }

      // Verify sample data integrity for this table
      stdout.writeln('  Verifying sample data integrity:');
      final sampleFirst = await db.query(schema.name).where('id', '=', '1');
      stdout.writeln('  First record: ${sampleFirst.data.firstOrNull}');
      final sampleLast = await db
          .query(schema.name)
          .where('id', '=', '${batchSize * batches}');
      stdout.writeln('  Last record:  ${sampleLast.data.firstOrNull}');
      stdout.writeln(
          '----------------------------------------------------------------\n');
    }

    // Print summary comparison
    stdout.writeln(
        '================================================================');
    stdout.writeln(
        ' Throughput Summary Comparison (Warm Batches 2-$batches Average)');
    stdout.writeln(
        '================================================================');
    final stdOps = avgOpsMap[RecoveryDurability.standard] ?? 0;
    for (final entry in avgOpsMap.entries) {
      final ratio =
          stdOps > 0 ? (entry.value / stdOps).toStringAsFixed(2) : '1.00';
      stdout.writeln(
          '  ${entry.key.name.padRight(10)}: ${entry.value.toStringAsFixed(0).padLeft(8)} OPS  (${ratio}x vs standard)');
    }
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
