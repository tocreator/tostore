import 'dart:async';
import 'dart:math';
import 'package:tostore/tostore.dart';
import 'service/log_service.dart';

/// A comprehensive testing suite for validating Tostore's core functionalities.
/// It covers basic CRUD, upsert, joins, multi-space, and various edge cases.
class DatabaseTester {
  final ToStore db;
  final LogService log;
  final Function(String) _updateLastOperation;
  final void Function(bool) setWarningSuppression;

  DatabaseTester(
      this.db, this.log, this._updateLastOperation, this.setWarningSuppression);

  void _passTest(String message) {
    log.add('✅ PASS: $message', LogType.info);
  }

  bool _failTest(String message) {
    log.add('❌ FAIL: $message', LogType.error);
    return false;
  }

  /// Performs a deep comparison of two objects.
  bool _deepEquals(dynamic a, dynamic b) {
    if (a == b) return true;

    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (int i = 0; i < a.length; i++) {
        if (!_deepEquals(a[i], b[i])) return false;
      }
      return true;
    }

    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final key in a.keys) {
        if (!b.containsKey(key) || !_deepEquals(a[key], b[key])) {
          return false;
        }
      }
      return true;
    }

    return false;
  }

  /// Universal assertion helper.
  /// Returns true if the assertion passes, false otherwise.
  bool _expect(String description, dynamic actual, dynamic expected) {
    if (_deepEquals(actual, expected)) {
      _passTest('$description: Expected and received value [$expected].');
      return true;
    } else {
      _failTest('$description: Expected [$expected], but received [$actual].');
      return false;
    }
  }

  /// Main test runner that executes all test suites.
  Future<bool> runAllTests() async {
    log.clear();
    log.add('--- Starting Database Run All Tests ---', LogType.info);
    _updateLastOperation('Running All Tests...');
    await Future.delayed(
        const Duration(milliseconds: 100)); // Allow UI to update
    bool allTestsPassed = true;

    try {
      final tests = <Map<String, Object>>[
        {'name': 'Clear & Delete All', 'test': _testClearAndDeleteAll},
        {'name': 'Basic CRUD', 'test': _testBasicCrud},
        {'name': 'Non-Nullable Constraint', 'test': _testNonNullConstraint},
        {'name': 'Upsert Logic', 'test': _testUpsert},
        {'name': 'JOIN Queries', 'test': _testJoinQueries},
        {'name': 'Multi-Space Isolation', 'test': _testMultiSpace},
        {
          'name': 'Advanced Queries & Edge Cases',
          'test': _testAdvancedQueriesAndEdgeCases
        },
        {'name': 'Count Verification', 'test': _testCountVerification},
        {
          'name': 'Concurrency Stress Test',
          'test': () => runConfigurableConcurrencyTest(_baseConcurrencyConfig)
        },
      ];

      for (var i = 0; i < tests.length; i++) {
        final test = tests[i];
        final testName = test['name'] as String;
        final testFunction = test['test'] as Future<bool> Function();

        _updateLastOperation(
            'Running Test ${i + 1}/${tests.length}: $testName...');
        bool passed;
        // Precisely control warning suppression only for the non-nullable test.
        if (testName == 'Non-Nullable Constraint') {
          setWarningSuppression(true);
          try {
            passed = await testFunction();
          } finally {
            setWarningSuppression(false);
          }
        } else {
          passed = await testFunction();
        }
        allTestsPassed &= passed;

        if (!passed && testName == 'Clear & Delete All') {
          _failTest(
              'CRITICAL: Clear/Delete test failed. Halting further tests as the database state is unreliable.');
          _updateLastOperation('❌ CRITICAL TEST FAILED');
          return false;
        }
      }

      log.add(
          allTestsPassed
              ? '✅ --- All tests passed successfully! ---'
              : '❌ --- Some tests FAILED! Please review the logs. ---',
          allTestsPassed ? LogType.info : LogType.error);
    } catch (e, s) {
      _failTest('An unexpected error occurred during tests: $e\n$s');
      allTestsPassed = false;
    } finally {
      // Ensure suppression is always turned off even if the test loop fails.
      setWarningSuppression(false);
      // CRITICAL: Clean up all tables after tests are finished to ensure a clean state.
      _updateLastOperation('Cleaning up test data...');
      await db.clear('users');
      await db.clear('posts');
      await db.clear('comments');
      log.add('--- All test data cleared. ---', LogType.info);
    }

    _updateLastOperation(
        allTestsPassed ? '✅ All Tests Passed' : '❌ Tests Failed');
    return allTestsPassed;
  }

  static const Map<String, Map<String, int>> _baseConcurrencyConfig = {
    'users': {
      'insert': 100,
      'read': 100,
      'update': 50,
      'delete': 50,
    },
    'posts': {
      'insert': 100,
      'read': 100,
      'update': 50,
      'delete': 50,
    },
    'comments': {
      'insert': 200,
      'read': 100,
      'update': 50,
      'delete': 50,
    },
  };

  /// CRITICAL TEST: Verifies that clearing a table or deleting all records works as expected.
  /// If this fails, the database state is considered unreliable for other tests.
  Future<bool> _testClearAndDeleteAll() async {
    log.add('--- Testing: Clear Table and Delete All ---', LogType.debug);
    bool isTestPassed = true;
    try {
      // Ensure a clean slate before this critical test, preventing state leakage from previous runs.
      await db.clear('users');
      await db.clear('posts');
      await db.clear('comments');

      // 1. Test db.clear()
      await db.batchInsert('users', [
        {'username': 'clear_user_1', 'email': 'cu1@test.com'},
        {'username': 'clear_user_2', 'email': 'cu2@test.com'},
      ]);

      await db.clear('users');
      final countAfterClear = await db.query('users').count();
      isTestPassed &=
          _expect('Count after clear should be 0', countAfterClear, 0);
      final dataAfterClear = await db.query('users');
      isTestPassed &=
          _expect('Data after clear should be empty', dataAfterClear.data, []);
      if (!isTestPassed) return false; // Critical failure

      // 2. Test deleting all records with a condition
      await db.batchInsert('users', [
        {'id': 1001, 'username': 'delete_user_1', 'email': 'du1@test.com'},
        {'id': 1002, 'username': 'delete_user_2', 'email': 'du2@test.com'},
      ]);
      await db.delete('users').where('id', '>', 0);
      final countAfterDelete = await db.query('users').count();
      isTestPassed &= _expect(
          'Count after deleting all (id > 0) should be 0', countAfterDelete, 0);
      final dataAfterDelete = await db.query('users');
      isTestPassed &= _expect(
          'Data after deleting all (id > 0) should be empty',
          dataAfterDelete.data, []);
      if (!isTestPassed) return false; // Critical failure
    } catch (e, s) {
      isTestPassed = false;
      _failTest('Exception in _testClearAndDeleteAll: $e\n$s');
    }
    return isTestPassed;
  }

  /// Tests basic Create, Read, Update, Delete operations.
  Future<bool> _testBasicCrud() async {
    log.add('--- Testing: Basic CRUD Operations ---', LogType.debug);
    bool isTestPassed = true;
    try {
      await db.clear('users');
      // Create
      final insertResult = await db.insert('users',
          {'username': 'crud_user', 'email': 'crud@test.com', 'age': 30});
      isTestPassed &=
          _expect('Insert should be successful', insertResult.isSuccess, true);
      isTestPassed &=
          _expect('Insert should affect 1 row', insertResult.successCount, 1);

      // Read
      final user = await db.query('users').where('username', '=', 'crud_user');
      isTestPassed &= _expect('Read should find 1 user', user.length, 1);
      isTestPassed &= _expect('Read should find correct user',
          user.data.first['email'], 'crud@test.com');

      // Update
      await db.update('users', {'age': 31}).where('username', '=', 'crud_user');
      final updatedUser =
          await db.query('users').where('username', '=', 'crud_user').first();
      isTestPassed &=
          _expect('Update should change age to 31', updatedUser?['age'], 31);

      // Delete
      final deleteResult =
          await db.delete('users').where('username', '=', 'crud_user');
      isTestPassed &=
          _expect('Delete should be successful', deleteResult.isSuccess, true);
      isTestPassed &=
          _expect('Delete should affect 1 row', deleteResult.successCount, 1);
      final countAfterDelete = await db.query('users').count();
      isTestPassed &=
          _expect('Count after delete should be 0', countAfterDelete, 0);
    } catch (e, s) {
      isTestPassed = false;
      _failTest('Exception in _testBasicCrud: $e\n$s');
    }
    return isTestPassed;
  }

  /// Tests the upsert logic.
  Future<bool> _testUpsert() async {
    log.add('--- Testing: Upsert Logic ---', LogType.debug);
    bool isTestPassed = true;
    try {
      await db.clear('users');
      // Upsert (insert)
      await db.upsert(
          'users', {'username': 'upsert_user', 'email': 'upsert@test.com'});
      final countAfterInsert = await db.query('users').count();
      isTestPassed &=
          _expect('Upsert-insert should result in 1 user', countAfterInsert, 1);

      // Upsert (update)
      await db
          .upsert('users', {'age': 40}).where('email', '=', 'upsert@test.com');
      final updatedUser = await db
          .query('users')
          .where('email', '=', 'upsert@test.com')
          .first();
      isTestPassed &= _expect(
          'Upsert-update should set age to 40', updatedUser?['age'], 40);
      isTestPassed &= _expect('Upsert-update should not create a new user',
          await db.query('users').count(), 1);
    } catch (e, s) {
      isTestPassed = false;
      _failTest('Exception in _testUpsert: $e\n$s');
    }
    return isTestPassed;
  }

  /// Tests multi-table JOIN queries.
  Future<bool> _testJoinQueries() async {
    log.add('--- Testing: JOIN Queries ---', LogType.debug);
    bool isTestPassed = true;
    try {
      await db.clear('users');
      await db.clear('posts');
      await db.insert('users',
          {'id': 1, 'username': 'join_user', 'email': 'join@test.com'});
      await db.insert(
          'posts', {'title': 'Join Post', 'user_id': 1, 'content': '...'});

      final result = await db
          .query('posts')
          .select(['posts.title', 'users.username']).join(
              'users', 'posts.user_id', '=', 'users.id');

      isTestPassed &=
          _expect('Join should return 1 result', result.data.length, 1);
      if (result.data.isNotEmpty) {
        isTestPassed &= _expect('Join should return correct title',
            result.data.first['title'], 'Join Post');
        isTestPassed &= _expect('Join should return correct username',
            result.data.first['username'], 'join_user');
      }
    } catch (e, s) {
      isTestPassed = false;
      _failTest('Exception in _testJoinQueries: $e\n$s');
    }
    return isTestPassed;
  }

  /// Tests multi-space data isolation.
  Future<bool> _testMultiSpace() async {
    log.add('--- Testing: Multi-Space Isolation ---', LogType.debug);
    bool isTestPassed = true;
    final originalSpace = (await db.getSpaceInfo()).spaceName;

    try {
      // Setup in space 'space1'
      await db.switchSpace(spaceName: 'space1');
      await db.clear('users');
      await db.insert('users',
          {'username': 'user_space1', 'email': 'user_space2@test.com'});
      final count1 = await db.query('users').count();
      isTestPassed &= _expect('Count in space1 should be 1', count1, 1);

      // Switch to space 'space2'
      await db.switchSpace(spaceName: 'space2');
      await db.clear('users');
      final count2 = await db.query('users').count();
      isTestPassed &=
          _expect('Count in space2 should be 0 initially', count2, 0);
      await db.insert('users',
          {'username': 'user_space2', 'email': 'user_space2@test.com'});
      final count3 = await db.query('users').count();
      isTestPassed &=
          _expect('Count in space2 after insert should be 1', count3, 1);

      // Verify space1 was not affected
      await db.switchSpace(spaceName: 'space1');
      final count4 = await db.query('users').count();
      isTestPassed &= _expect('Count in space1 should still be 1', count4, 1);

      final space1Result =
          await db.query('users').whereEqual('username', 'user_space1');
      isTestPassed &= _expect(
          'Space1 query username = user_space1 result should be 1',
          space1Result.length,
          1);
    } catch (e, s) {
      isTestPassed = false;
      _failTest('Exception in _testMultiSpace: $e\n$s');
    } finally {
      // Cleanup: switch back to the original space
      await db.switchSpace(spaceName: originalSpace);
    }
    return isTestPassed;
  }

  /// Tests advanced queries, including string sorting, LIKE, numeric comparisons, etc.
  Future<bool> _testAdvancedQueriesAndEdgeCases() async {
    log.add('--- Testing: Advanced Queries & Edge Cases ---', LogType.debug);
    bool isTestPassed = true;
    try {
      await db.clear('users');
      await db.batchInsert('users', [
        {
          'id': 1,
          'username': 'user_1',
          'age': 10,
          'email': 'a@a.com',
          'fans': 100
        },
        {
          'id': 2,
          'username': 'user_2',
          'age': 20,
          'email': 'b@b.com',
          'fans': 200
        },
        {
          'id': 10,
          'username': 'user_10',
          'age': 30,
          'email': 'c@c.com',
          'fans': 300
        },
        {
          'id': 20,
          'username': 'user_20',
          'age': 40,
          'email': 'd@d.com',
          'fans': 400
        },
        {
          'id': 3,
          'username': 'user_3',
          'age': 50,
          'email': 'e@e.com',
          'fans': 500
        },
      ]);

      // Test 1: Primary Key Sort Comparison
      // Test 1a: Ascending sort
      final userIdsAsc = (await db.query('users').orderByAsc('id'))
          .data
          .map((u) => u['id'])
          .toList();

      isTestPassed &= _expect('Primary key ascending sort order', userIdsAsc,
          ['1', '2', '3', '10', '20']);

      // Test 1b: Descending sort
      final userIdsDesc = (await db.query('users').orderByDesc('id'))
          .data
          .map((u) => u['id'])
          .toList();
      isTestPassed &= _expect('Primary key descending sort order', userIdsDesc,
          ['20', '10', '3', '2', '1']);

      // Test 2: Primary Key Range Queries
      final usersIdGreaterThan2 =
          (await db.query('users').where('id', '>', 2)).length;
      isTestPassed &=
          _expect('Query "id > 2"', usersIdGreaterThan2, 3); // ids 3, 10, 20

      // Test 3: Quoted vs. Unquoted Numeric Queries
      isTestPassed &= _expect('Query age = 20 (numeric)',
          (await db.query('users').where('age', '=', 20)).length, 1);
      isTestPassed &= _expect('Query age = "20" (string)',
          (await db.query('users').where('age', '=', '20')).length, 1);
      isTestPassed &= _expect('Query age > 40 (numeric)',
          (await db.query('users').where('age', '>', 40)).length, 1);
      isTestPassed &= _expect('Query age > "40" (string)',
          (await db.query('users').where('age', '>', '40')).length, 1);

      // Test 4: LIKE Queries
      isTestPassed &= _expect(
          'LIKE "user_1%"',
          (await db.query('users').where('username', 'like', 'user_1%')).length,
          2);
      isTestPassed &= _expect(
          'LIKE "%@a.com"',
          (await db.query('users').where('email', 'like', '%@a.com')).length,
          1);
      isTestPassed &= _expect(
          'LIKE "%user%"',
          (await db.query('users').where('username', 'like', '%user%')).length,
          5);

      // Test 5: Non-indexed Field Query
      isTestPassed &= _expect('Non-indexed query fans >= 400',
          (await db.query('users').where('fans', '>=', 400)).length, 2);

      // Test 6: Primary Key Range Query
      isTestPassed &= _expect('PK range id > 10',
          (await db.query('users').where('id', '>', 10)).length, 1); // id 20
      isTestPassed &= _expect(
          'PK range id >= 10',
          (await db.query('users').where('id', '>=', 10)).length,
          2); // id 10, 20
    } catch (e, s) {
      isTestPassed = false;
      _failTest('Exception in _testAdvancedQueriesAndEdgeCases: $e\n$s');
    }
    return isTestPassed;
  }

  /// Tests that non-nullable fields correctly reject null values.
  Future<bool> _testNonNullConstraint() async {
    log.add('--- Testing: Non-Nullable Constraint ---', LogType.debug);
    bool isTestPassed = true;
    try {
      await db.clear('users');
      // The 'email' field is non-nullable. This insert should fail.
      final result = await db.insert('users', {
        'username': 'non_null_test',
        'email': null, // Explicitly setting a non-nullable field to null
      });

      isTestPassed &= _expect(
          'Insert with null for non-nullable field should fail',
          result.isSuccess,
          false);
      isTestPassed &= _expect(
          'Error type should be validationFailed or notNullViolation',
          result.type == ResultType.validationFailed ||
              result.type == ResultType.notNullViolation,
          true);

      final count = await db.query('users').count();
      isTestPassed &=
          _expect('Table should be empty after failed insert', count, 0);
    } catch (e, s) {
      isTestPassed = false;
      _failTest('Exception in _testNonNullConstraint: $e\n$s');
    }
    return isTestPassed;
  }

  /// Verifies that .count() returns a value consistent with the actual number of records.
  Future<bool> _testCountVerification() async {
    log.add('--- Testing: .count() Verification ---', LogType.debug);
    bool isTestPassed = true;

    Future<bool> verify(String step) async {
      final query = db.query('users').where('age', '>', 25);
      final countResult = await query.count();
      final actualLength = (await query).length;
      return _expect(
          '$step: Count ($countResult) should match actual length ($actualLength)',
          countResult,
          actualLength);
    }

    try {
      await db.clear('users');
      final records = List.generate(
          20,
          (i) => {
                'username': 'count_user_$i',
                'email': 'count_user_$i@example.com',
                'age': 18 + i, // Ages 18 to 37
              });
      await db.batchInsert('users', records);

      // Initial state: age > 25 means ages 26..37 (12 records)
      isTestPassed &= await verify('Initial insert');
      if (!isTestPassed) return false;

      // Delete some records that match the condition
      // Delete ages > 30 (31..37 -> 7 records)
      await db.delete('users').where('age', '>', 30);

      // After delete: age > 25 means ages 26..30 (5 records)
      isTestPassed &= await verify('After deleting some matching records');
      if (!isTestPassed) return false;

      // Delete some records that DO NOT match the condition
      // Delete age < 22 (18..21 -> 4 records)
      await db.delete('users').where('age', '<', 22);

      // After delete: age > 25 should still be 5 records
      isTestPassed &= await verify('After deleting non-matching records');
      if (!isTestPassed) return false;
    } catch (e, s) {
      isTestPassed = false;
      _failTest('Exception in _testCountVerification: $e\n$s');
    }
    return isTestPassed;
  }

  /// Runs a configurable concurrency test based on user input.
  Future<bool> runConfigurableConcurrencyTest(
      Map<String, Map<String, int>> config,
      {int verificationSampleSize = 10}) async {
    log.add(
        '--- Testing: Configurable Concurrency Stress Test ---', LogType.debug);
    _updateLastOperation('Starting Configurable Concurrency Test...');
    bool isTestPassed = true;
    final stopwatch = Stopwatch()..start();

    // Data stores for verification
    final insertedUsers = <Map<String, dynamic>>[];
    final updatedUsers = <Map<String, dynamic>>[];
    final deletedUsers = <Map<String, dynamic>>[];
    final insertedPosts = <Map<String, dynamic>>[];
    final updatedPosts = <Map<String, dynamic>>[];
    final deletedPosts = <Map<String, dynamic>>[];
    final insertedComments = <Map<String, dynamic>>[];
    final updatedComments = <Map<String, dynamic>>[];
    final deletedComments = <Map<String, dynamic>>[];

    try {
      await db.clear('users');
      await db.clear('posts');
      await db.clear('comments');
      final random = Random();
      final operations = <Future>[];

      // Helper to prepare base data and generate operations
      Future<List<Map<String, dynamic>>> prepareAndGenerateOpsForTable({
        required String tableName,
        required Map<String, int> tableConfig,
        required ({Future<DbResult> future, Map<String, dynamic> data})
                Function(int i)
            insertGenerator,
        required Map<String, dynamic> updateData,
        required List<Map<String, dynamic>> itemsToInsert,
        required List<Map<String, dynamic>> itemsToUpdate,
        required List<Map<String, dynamic>> itemsToDelete,
        String idField = 'id',
        String nameField = 'id',
      }) async {
        final updateCount = tableConfig['update'] ?? 0;
        final deleteCount = tableConfig['delete'] ?? 0;
        final baseCount = updateCount + deleteCount;

        _updateLastOperation(
            'Preparing $baseCount base records for $tableName...');

        final baseItems = <Map<String, dynamic>>[];
        if (baseCount > 0) {
          final insertsToRun = <int, Map<String, dynamic>>{};
          final insertFutures = List.generate(baseCount, (i) {
            final gen = insertGenerator(i);
            insertsToRun[gen.future.hashCode] = gen.data;
            return gen.future;
          });

          // Batch execute the creation of base data to avoid UI jank
          const batchSize = 50;
          for (int i = 0; i < insertFutures.length; i += batchSize) {
            final end = (i + batchSize > insertFutures.length)
                ? insertFutures.length
                : i + batchSize;
            _updateLastOperation(
                'Preparing base for $tableName: ${i + 1}-$end of $baseCount');
            final batch = insertFutures.sublist(i, end);
            final results = await Future.wait(batch, eagerError: true);

            for (final r in results) {
              if (r.isSuccess && r.successKeys.isNotEmpty) {
                final originalData = insertsToRun[r.hashCode];
                final Map<String, dynamic> newItem = {
                  'id': r.successKeys.first
                };
                if (originalData != null &&
                    originalData.containsKey(nameField)) {
                  newItem[nameField] = originalData[nameField];
                }
                baseItems.add(newItem);
              }
            }
            await Future.delayed(Duration.zero); // Yield to the event loop
          }
          log.add(
              'Created ${baseItems.length}/$baseCount base records for $tableName.',
              LogType.info);
        }

        if (baseItems.isEmpty && baseCount > 0) {
          _failTest(
              'Failed to create base data for $tableName, cannot proceed with updates/deletes.');
        } else {
          final itemsToUpdateLocal = baseItems.take(updateCount).toList();
          itemsToUpdate.addAll(itemsToUpdateLocal);

          final itemsToDeleteLocal =
              baseItems.skip(updateCount).take(deleteCount).toList();
          itemsToDelete.addAll(itemsToDeleteLocal);

          // Add Updates
          for (var i = 0; i < itemsToUpdateLocal.length; i++) {
            final item = itemsToUpdateLocal[i];
            operations.add(db
                .update(tableName, updateData)
                .where(idField, '=', item[idField]));
            if (i % 50 == 0) {
              await Future.delayed(Duration.zero);
            }
          }

          // Add Deletes
          for (final item in itemsToDeleteLocal) {
            operations
                .add(db.delete(tableName).where(idField, '=', item[idField]));
          }
        }

        // Add Reads
        final readCount = tableConfig['read'] ?? 0;
        if (baseItems.isNotEmpty) {
          for (var i = 0; i < readCount; i++) {
            final item = baseItems[random.nextInt(baseItems.length)];
            operations.add(
                db.query(tableName).where(idField, '=', item[idField]).first());
            if (i % 50 == 0) {
              await Future.delayed(Duration.zero);
            }
          }
        }

        // Add new Inserts
        final insertCount = tableConfig['insert'] ?? 0;
        for (var i = 0; i < insertCount; i++) {
          final gen = insertGenerator(baseCount + i);
          operations.add(gen.future);
          itemsToInsert.add(gen.data);
          if (i % 50 == 0) {
            await Future.delayed(Duration.zero);
          }
        }

        return baseItems;
      }

      // Stage 1: Prepare Users
      final baseUsers = await prepareAndGenerateOpsForTable(
        tableName: 'users',
        tableConfig: config['users']!,
        itemsToInsert: insertedUsers,
        itemsToUpdate: updatedUsers,
        itemsToDelete: deletedUsers,
        insertGenerator: (i) {
          final data = {
            'username': 'cc_user_$i',
            'email': 'cc_user_$i@test.com',
            'age': 20 + i,
          };
          return (future: db.insert('users', data), data: data);
        },
        updateData: {'age': 999},
        nameField: 'username',
      );

      // Stage 2: Prepare Posts
      final basePosts = await prepareAndGenerateOpsForTable(
        tableName: 'posts',
        tableConfig: config['posts']!,
        itemsToInsert: insertedPosts,
        itemsToUpdate: updatedPosts,
        itemsToDelete: deletedPosts,
        insertGenerator: (i) {
          final user = baseUsers[random.nextInt(baseUsers.length)];
          final data = {'title': 'Post $i', 'user_id': user['id']};
          return (future: db.insert('posts', data), data: data);
        },
        updateData: {'content': 'updated post content'},
      );

      // Stage 3: Prepare Comments
      final baseComments = await prepareAndGenerateOpsForTable(
        tableName: 'comments',
        tableConfig: config['comments']!,
        itemsToInsert: insertedComments,
        itemsToUpdate: updatedComments,
        itemsToDelete: deletedComments,
        insertGenerator: (i) {
          final user = baseUsers[random.nextInt(baseUsers.length)];
          final post = basePosts[random.nextInt(basePosts.length)];
          final data = {
            'content': 'Comment $i',
            'user_id': user['id'],
            'post_id': post['id']
          };
          return (future: db.insert('comments', data), data: data);
        },
        updateData: {'content': 'updated comment content'},
      );

      // Stage 4: Execute all operations concurrently
      _updateLastOperation(
          'Executing ${operations.length} mixed operations concurrently...');
      log.add('Executing ${operations.length} mixed operations concurrently...',
          LogType.info);
      operations.shuffle(random);

      const batchSize = 100;
      for (int i = 0; i < operations.length; i += batchSize) {
        final end = (i + batchSize > operations.length)
            ? operations.length
            : i + batchSize;
        final batch = operations.sublist(i, end);
        _updateLastOperation(
            'Running batch ${i ~/ batchSize + 1}/${(operations.length / batchSize).ceil()}...');
        await Future.wait(batch, eagerError: false);
        await Future.delayed(Duration.zero); // Yield to the event loop
      }

      stopwatch.stop();

      // Stage 5: Verification
      _updateLastOperation('Stage 5: Verifying results...');

      final userConfig = config['users']!;
      final postConfig = config['posts']!;
      final commentConfig = config['comments']!;

      int calculateExpectedCount(
          List<Map<String, dynamic>> baseItems, Map<String, int> config) {
        final updateCount = config['update'] ?? 0;
        final deleteCount = config['delete'] ?? 0;
        final insertCount = config['insert'] ?? 0;
        // The number of items that were actually scheduled for deletion.
        final actualDeletes =
            min(deleteCount, max(0, baseItems.length - updateCount));
        return baseItems.length + insertCount - actualDeletes;
      }

      final expectedUserCount = calculateExpectedCount(baseUsers, userConfig);
      final expectedPostCount = calculateExpectedCount(basePosts, postConfig);
      final expectedCommentCount =
          calculateExpectedCount(baseComments, commentConfig);

      // --- Data Integrity Verification ---
      List<T> getHeadTailSample<T>(List<T> list) {
        final sampleSize = verificationSampleSize;
        if (list.isEmpty || list.length <= sampleSize) {
          return list;
        }
        final half = (sampleSize / 2).ceil();
        final head = list.sublist(0, half);
        final tail = list.sublist(list.length - half);
        return {...head, ...tail}.toList();
      }

      _updateLastOperation('Verifying data integrity for users...');
      // Verify updated users still exist and have the correct data.
      final updatedUserSample = getHeadTailSample(updatedUsers);
      final updatedUserIds = updatedUserSample.map((u) => u['id']).toList();
      if (updatedUserIds.isNotEmpty) {
        final result = await db.query('users').whereIn('id', updatedUserIds);
        isTestPassed &= _expect(
            'All updated users in sample must exist after test',
            result.length,
            updatedUserIds.length);
        for (final user in result.data) {
          isTestPassed &= _expect('User ${user['id']} age should be updated',
              user['age'], 999);
        }
      }

      // Verify deleted users are gone.
      final deletedUserSample = getHeadTailSample(deletedUsers);
      final deletedUserIds = deletedUserSample.map((u) => u['id']).toList();
      if (deletedUserIds.isNotEmpty) {
        final result = await db.query('users').whereIn('id', deletedUserIds);
        isTestPassed &= _expect(
            'Deleted users in sample should not be found', result.length, 0);
      }

      // Verify newly inserted users exist.
      final insertedUserSample = getHeadTailSample(insertedUsers);
      final insertedUsernames =
          insertedUserSample.map((u) => u['username'] as String).toList();
      if (insertedUsernames.isNotEmpty) {
        final result =
            await db.query('users').whereIn('username', insertedUsernames);
        isTestPassed &= _expect(
            'All newly inserted users in sample should be found',
            result.length,
            insertedUsernames.length);
      }

      _updateLastOperation('Verifying data integrity for posts...');
      // Verify updated posts
      final updatedPostSample = getHeadTailSample(updatedPosts);
      final updatedPostIds = updatedPostSample.map((p) => p['id']).toList();
      if (updatedPostIds.isNotEmpty) {
        final result = await db.query('posts').whereIn('id', updatedPostIds);
        isTestPassed &= _expect(
            'All updated posts in sample must exist after test',
            result.length,
            updatedPostIds.length);
        for (final post in result.data) {
          isTestPassed &= _expect('Post ${post['id']} content should be updated',
              post['content'], 'updated post content');
        }
      }

      // Verify deleted posts
      final deletedPostSample = getHeadTailSample(deletedPosts);
      final deletedPostIds = deletedPostSample.map((p) => p['id']).toList();
      if (deletedPostIds.isNotEmpty) {
        isTestPassed &= _expect(
            'Deleted posts in sample should not be found',
            (await db.query('posts').whereIn('id', deletedPostIds)).length,
            0);
      }

      // Verify inserted posts
      final insertedPostSample = getHeadTailSample(insertedPosts);
      final insertedPostTitles =
          insertedPostSample.map((p) => p['title'] as String).toList();
      if (insertedPostTitles.isNotEmpty) {
        isTestPassed &= _expect(
            'All newly inserted posts in sample should be found',
            (await db.query('posts').whereIn('title', insertedPostTitles))
                .length,
            insertedPostTitles.length);
      }

      _updateLastOperation('Verifying data integrity for comments...');
      // Verify updated comments
      final updatedCommentSample = getHeadTailSample(updatedComments);
      final updatedCommentIds = updatedCommentSample.map((c) => c['id']).toList();
      if (updatedCommentIds.isNotEmpty) {
        final result =
            await db.query('comments').whereIn('id', updatedCommentIds);
        isTestPassed &= _expect(
            'All updated comments in sample must exist after test',
            result.length,
            updatedCommentIds.length);
        for (final comment in result.data) {
          isTestPassed &= _expect(
              'Comment ${comment['id']} content should be updated',
              comment['content'],
              'updated comment content');
        }
      }

      // Verify deleted comments
      final deletedCommentSample = getHeadTailSample(deletedComments);
      final deletedCommentIds = deletedCommentSample.map((c) => c['id']).toList();
      if (deletedCommentIds.isNotEmpty) {
        isTestPassed &= _expect(
            'Deleted comments in sample should not be found',
            (await db.query('comments').whereIn('id', deletedCommentIds))
                .length,
            0);
      }

      // Verify inserted comments
      final insertedCommentSample = getHeadTailSample(insertedComments);
      final insertedCommentContents =
          insertedCommentSample.map((c) => c['content'] as String).toList();
      if (insertedCommentContents.isNotEmpty) {
        isTestPassed &= _expect(
            'All newly inserted comments in sample should be found',
            (await db
                    .query('comments')
                    .whereIn('content', insertedCommentContents))
                .length,
            insertedCommentContents.length);
      }

      // --- Final Count Verification ---
      _updateLastOperation('Verifying final record counts...');
      isTestPassed &= _expect('Final user count should be correct',
          await db.query('users').count(), expectedUserCount);
      isTestPassed &= _expect('Final post count should be correct',
          await db.query('posts').count(), expectedPostCount);
      isTestPassed &= _expect('Final comment count should be correct',
          await db.query('comments').count(), expectedCommentCount);
    } catch (e, s) {
      isTestPassed = false;
      _failTest('Exception in runConfigurableConcurrencyTest: $e\n$s');
    } finally {
      stopwatch.stop();
      _updateLastOperation('Cleaning up test data...');
      await db.clear('users');
      await db.clear('posts');
      await db.clear('comments');
      log.add('Test data cleaned up.', LogType.info);
      log.add(
          'Concurrency test finished in ${stopwatch.elapsedMilliseconds}ms.',
          LogType.info);
    }
    _updateLastOperation(isTestPassed
        ? '✅ Concurrency Test Passed'
        : '❌ Concurrency Test Failed');
    return isTestPassed;
  }
}
