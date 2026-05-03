import 'package:flutter_test/flutter_test.dart';
import 'package:tostore_example/tostore_example.dart';
import 'package:tostore_example/testing/database_tester.dart';
import 'package:tostore_example/testing/log_service.dart';

void main() {
  test('Run comprehensive database tests', () async {
    final example = ToStoreExample();

    // Provide a real-world path directly to avoid platform channels/MissingPluginException
    await example.initialize(dbPath: './test_full_db');

    final databaseTester = DatabaseTester(example.db, logService, (op) {
      // ignore: avoid_print
      print('Database status: $op');
    });

    final success = await databaseTester.runAllTests();
    expect(success, isTrue);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('Benchmark batchInsert performance with 10k and 100k records', () async {
    final example = ToStoreExample();
    await example.initialize(dbPath: './test_benchmark_db');

    // Clear the table before benchmark
    await example.db.clear('users');

    // Generate 10k mock data
    final data10k = List.generate(
        10000,
        (i) => {
              'username': 'bench_10k_$i',
              'email': 'bench_10k_$i@example.com',
              'is_active': true,
              'age': 20 + (i % 50),
            });

    final sw10k = Stopwatch()..start();
    await example.db.batchInsert('users', data10k);
    sw10k.stop();
    // ignore: avoid_print
    print('✅ batchInsert 10,000 records took: ${sw10k.elapsedMilliseconds} ms');

    // Clear the table before 100k benchmark
    await example.db.clear('users');

    // Generate 100k mock data
    final data100k = List.generate(
        100000,
        (i) => {
              'username': 'bench_100k_$i',
              'email': 'bench_100k_$i@example.com',
              'is_active': false,
              'age': 20 + (i % 50),
            });

    final sw100k = Stopwatch()..start();
    await example.db.batchInsert('users', data100k);
    sw100k.stop();
    // ignore: avoid_print
    print(
        '✅ batchInsert 100,000 records took: ${sw100k.elapsedMilliseconds} ms');

    expect(sw10k.elapsedMilliseconds, greaterThan(0));
    expect(sw100k.elapsedMilliseconds, greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 10)));
}
