import 'dart:io';

import 'package:tostore/tostore.dart';

/// Benchmark for ToStore batchInsert throughput.
///
/// Runs the same multi-durability suite against:
///   - Tier 1: simple primary-key table (peak engine throughput)
///   - Tier 2: indexed table (unique + secondary index maintenance)
///
/// Schema layouts match BenchmarkSchemas.simple / BenchmarkSchemas.indexed.
///
/// Usage:
///   dart run example/test/batch_insert_benchmark.dart
void main() async {
  // Fixed path so a crashed/killed run does not leave orphaned multi-GB dirs;
  // wipe before each run so leftovers from a prior abort are always cleared.
  final tempDir = Directory(
    '${Directory.systemTemp.path}/tostore_bench_batch_insert',
  );
  if (tempDir.existsSync()) {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (e) {
      stderr.writeln(
        'Warning: failed to clear previous bench dir ${tempDir.path}: $e',
      );
    }
  }

  const testDurabilities = [
    RecoveryDurability.async,
    RecoveryDurability.standard,
  ];
  const int warmupSize = 10000;
  const int batchSize = 100000;
  const int batches = 5;

  final schemaTiers =
      <({String label, bool indexed, TableSchema Function(String name) build})>[
    (
      label: 'simple (PK only)',
      indexed: false,
      build: (name) => TableSchema(
            name: name,
            primaryKeyConfig: const PrimaryKeyConfig(
              name: 'id',
              type: PrimaryKeyType.sequential,
            ),
            fields: const [
              FieldSchema(
                  name: 'text_val', type: DataType.text, nullable: false),
              FieldSchema(
                  name: 'num_val', type: DataType.integer, nullable: false),
            ],
            indexes: const [],
          ),
    ),
    (
      label: 'indexed (unique + secondary)',
      indexed: true,
      build: (name) => TableSchema(
            name: name,
            primaryKeyConfig: const PrimaryKeyConfig(
              name: 'id',
              type: PrimaryKeyType.sequential,
            ),
            fields: const [
              FieldSchema(name: 'name', type: DataType.text, nullable: false),
              FieldSchema(name: 'age', type: DataType.integer, nullable: false),
              FieldSchema(
                name: 'created_at',
                type: DataType.datetime,
                defaultValueType: DefaultValueType.currentTimestamp,
              ),
            ],
            indexes: const [
              IndexSchema(fields: ['name'], unique: true),
              IndexSchema(fields: ['age']),
            ],
          ),
    ),
  ];

  stdout.writeln(
      '================================================================');
  stdout.writeln(
      ' ToStore batchInsert Multi-Schema / Multi-Durability Benchmark');
  stdout.writeln(
      '================================================================');
  stdout.writeln('Database path:  ${tempDir.path}');
  stdout.writeln(
      'JIT warmup:     $warmupSize inserts per schema, once at startup');
  stdout.writeln('Records/round:  $batchSize');
  stdout
      .writeln('Rounds/mode:    $batches (isolated: clear before each round)');
  stdout
      .writeln('Schema tiers:   ${schemaTiers.map((e) => e.label).join(', ')}');
  stdout.writeln(
      'Modes tested:   ${testDurabilities.map((e) => e.name).join(', ')}');
  stdout.writeln(
      '----------------------------------------------------------------\n');

  // Nested map: schemaLabel -> durability -> warm avg OPS
  final avgOpsMap = <String, Map<RecoveryDurability, double>>{};

  final allSchemas = [
    for (final tier in schemaTiers)
      for (final durability in testDurabilities)
        tier.build(_tableName(indexed: tier.indexed, durability: durability)),
  ];

  try {
    final db = await ToStore.open(
      dbPath: tempDir.path,
      schemas: allSchemas,
    );

    // Suite-level JIT warmup (once).
    stdout.writeln(
        'JIT warmup (once at startup): $warmupSize inserts per schema, then clear...');
    var warmupOk = true;
    for (final tier in schemaTiers) {
      final tableName = _tableName(
        indexed: tier.indexed,
        durability: testDurabilities.first,
      );
      final warmupRes = await db.batchInsert(
        tableName,
        _generateRecords(
          indexed: tier.indexed,
          batchSize: warmupSize,
          batchIndex: 1,
          durability: testDurabilities.first,
        ),
        allowPartialErrors: false,
        returnResultDetails: false,
        durability: testDurabilities.first,
      );
      await db.clear(tableName);
      warmupOk = warmupOk && !warmupRes.hasErrors;
    }

    for (final tier in schemaTiers) {
      avgOpsMap[tier.label] = {};
      stdout.writeln(
          '################################################################');
      stdout.writeln(' SCHEMA TIER: ${tier.label}');
      stdout.writeln(
          '################################################################\n');

      for (final durability in testDurabilities) {
        final tableName =
            _tableName(indexed: tier.indexed, durability: durability);

        stdout.writeln(
            '>>> [${tier.label}] Durability: ${durability.name.toUpperCase()} <<<');

        final roundRecords = [
          for (int b = 1; b <= batches; b++)
            _generateRecords(
              indexed: tier.indexed,
              batchSize: batchSize,
              batchIndex: b,
              durability: durability,
            ),
        ];

        int warmTotalElapsedMs = 0;
        int warmBatchCount = 0;

        for (int b = 1; b <= batches; b++) {
          // Fixture reset: empty table + drain in-flight flush for this table.
          await db.clear(tableName);

          final sw = Stopwatch()..start();
          final res = await db.batchInsert(
            tableName,
            roundRecords[b - 1],
            allowPartialErrors: false,
            returnResultDetails: false,
            durability: durability,
          );
          sw.stop();

          final elapsedMs = sw.elapsedMilliseconds;
          final ops = (batchSize / (sw.elapsedMicroseconds / 1000000))
              .toStringAsFixed(0);
          final isCold = b == 1 ? ' (Cold Start)' : '';

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
          avgOpsMap[tier.label]![durability] = avgWarmOps;
        }

        // Verify last round, then wipe so leftover rows/flush do not overlap
        stdout.writeln('  Verifying sample data integrity:');
        final sampleFirst = await db.query(tableName).where('id', '=', '1');
        stdout.writeln('  First record: ${sampleFirst.data.firstOrNull}');
        final sampleLast =
            await db.query(tableName).where('id', '=', '$batchSize');
        stdout.writeln('  Last record:  ${sampleLast.data.firstOrNull}');
        await db.clear(tableName);
        stdout.writeln(
            '----------------------------------------------------------------\n');
      }
    }

    // Print summary comparison
    stdout.writeln(
        '================================================================');
    stdout.writeln(' Throughput Summary (Warm Rounds 2-$batches Average)');
    stdout.writeln(
        '================================================================');
    for (final tier in schemaTiers) {
      final tierMap = avgOpsMap[tier.label] ?? {};
      final stdOps = tierMap[RecoveryDurability.standard] ?? 0;
      stdout.writeln('\n  [${tier.label}]');
      for (final durability in testDurabilities) {
        final ops = tierMap[durability] ?? 0;
        final ratio = stdOps > 0 ? (ops / stdOps).toStringAsFixed(2) : '1.00';
        stdout.writeln(
            '    ${durability.name.padRight(10)}: ${ops.toStringAsFixed(0).padLeft(8)} OPS  (${ratio}x vs standard)');
      }
    }

    // Cross-schema comparison at standard durability
    final simpleStd =
        avgOpsMap[schemaTiers[0].label]?[RecoveryDurability.standard] ?? 0;
    final indexedStd =
        avgOpsMap[schemaTiers[1].label]?[RecoveryDurability.standard] ?? 0;
    if (simpleStd > 0 && indexedStd > 0) {
      stdout.writeln('\n  [Cross-schema @ standard]');
      stdout.writeln(
          '    indexed / simple ratio: ${(indexedStd / simpleStd).toStringAsFixed(2)}x');
    }
    stdout.writeln(
        '================================================================\n');

    await db.close(flush: false);
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

String _tableName({
  required bool indexed,
  required RecoveryDurability durability,
}) {
  final prefix = indexed ? 'benchmark_indexed' : 'benchmark_simple';
  return '${prefix}_${durability.name}';
}

/// Build batch payloads matching the schema tier field layout.
List<Map<String, dynamic>> _generateRecords({
  required bool indexed,
  required int batchSize,
  required int batchIndex,
  required RecoveryDurability durability,
}) {
  final offset = batchSize * (batchIndex - 1);

  return List.generate(batchSize, (i) {
    final seq = offset + i;
    if (indexed) {
      // Unique `name` index requires globally unique values across batches.
      return {
        'name': 'bench_${durability.name}_${batchIndex}_$i',
        'age': seq % 100,
      };
    }
    return {
      'text_val': 'benchmark_payload_${durability.name}_${batchIndex}_$i',
      'num_val': seq,
    };
  });
}
