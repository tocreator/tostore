import 'dart:async';
import 'dart:math';
import 'package:tostore/tostore.dart';
import 'main.dart';

/// A comprehensive testing suite for validating Tostore's core functionalities.
/// It covers basic CRUD, upsert, joins, multi-space, and various edge cases.
class DatabaseTester {
  final ToStore db;
  final LogService log;
  final Function(String) _updateLastOperation;
  final void Function(bool) setWarningSuppression;

  DatabaseTester(this.db, this.log, this._updateLastOperation,
      this.setWarningSuppression);

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
    log.add('--- Starting Database Integrity Tests ---', LogType.info);
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
      isTestPassed &= _expect('Join should return correct title',
          result.data.first['title'], 'Join Post');
      isTestPassed &= _expect('Join should return correct username',
          result.data.first['username'], 'join_user');
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

      // Test 1: Natural String Sort Comparison
      final userNamesAsc = (await db.query('users').orderByAsc('username'))
          .data
          .map((u) => u['username'])
          .toList();
      isTestPassed &= _expect('Natural sort order', userNamesAsc,
          ['user_1', 'user_2', 'user_3', 'user_10', 'user_20']);

      // Test 2: String Range Queries (with natural sort)
      final usersGreaterThan2 =
          (await db.query('users').where('username', '>', 'user_2')).length;
      isTestPassed &= _expect('Query "username > user_2"', usersGreaterThan2,
          3); // user_3, user_10, user_20

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
      Map<String, Map<String, int>> config) async {
    log.add('--- Testing: Configurable Concurrency Stress Test ---',
        LogType.debug);
    _updateLastOperation('Starting Configurable Concurrency Test...');
    bool isTestPassed = true;
    final stopwatch = Stopwatch()..start();

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
        required ({Future<DbResult> future, Map<String, dynamic> data}) Function(int i) insertGenerator,
        required Map<String, dynamic> updateData,
        String idField = 'id',
        String nameField = 'id',
      }) async {
        final updateCount = tableConfig['update'] ?? 0;
        final deleteCount = tableConfig['delete'] ?? 0;
        final baseCount = updateCount + deleteCount;

        _updateLastOperation('Preparing $baseCount base records for $tableName...');
        
        final baseItems = <Map<String, dynamic>>[];
        if (baseCount > 0) {
            final insertsToRun = <int, Map<String,dynamic>>{};
            final insertFutures = List.generate(baseCount, (i) {
                final gen = insertGenerator(i);
                insertsToRun[gen.future.hashCode] = gen.data;
                return gen.future;
            });
            
            // Batch execute the creation of base data to avoid UI jank
            const batchSize = 1000;
            for (int i = 0; i < insertFutures.length; i += batchSize) {
                final end = (i + batchSize > insertFutures.length) ? insertFutures.length : i + batchSize;
                _updateLastOperation('Preparing base for $tableName: ${i + 1}-$end of $baseCount');
                final batch = insertFutures.sublist(i, end);
                final results = await Future.wait(batch, eagerError: true);
                
                for (final r in results) {
                    if (r.isSuccess && r.successKeys.isNotEmpty) {
                        final originalData = insertsToRun[r.hashCode];
                        final Map<String, dynamic> newItem = {'id': r.successKeys.first};
                        if (originalData != null && originalData.containsKey(nameField)) {
                          newItem[nameField] = originalData[nameField];
                        }
                        baseItems.add(newItem);
                    }
                }
                await Future.delayed(Duration.zero); // Yield to the event loop
            }
            log.add('Created ${baseItems.length}/$baseCount base records for $tableName.', LogType.info);
        }


        if (baseItems.isEmpty && baseCount > 0) {
            _failTest('Failed to create base data for $tableName, cannot proceed with updates/deletes.');
        } else {
            final itemsToUpdate = baseItems.take(updateCount).toList();
            final itemsToDelete = baseItems.skip(updateCount).take(deleteCount).toList();

            // Add Updates
            for (final item in itemsToUpdate) {
                operations.add(db.update(tableName, updateData).where(idField, '=', item[idField]));
            }

            // Add Deletes
            for (final item in itemsToDelete) {
                operations.add(db.delete(tableName).where(idField, '=', item[idField]));
            }
        }
        
        // Add Reads
        final readCount = tableConfig['read'] ?? 0;
        if (baseItems.isNotEmpty) {
            for (var i = 0; i < readCount; i++) {
                final item = baseItems[random.nextInt(baseItems.length)];
                operations.add(db.query(tableName).where(idField, '=', item[idField]).first());
            }
        }

        // Add new Inserts
        final insertCount = tableConfig['insert'] ?? 0;
        for (var i = 0; i < insertCount; i++) {
            operations.add(insertGenerator(baseCount + i).future);
        }

        return baseItems;
      }
      
      // Stage 1: Prepare Users
      final baseUsers = await prepareAndGenerateOpsForTable(
        tableName: 'users',
        tableConfig: config['users']!,
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
        insertGenerator: (i) {
           final user = baseUsers[random.nextInt(baseUsers.length)];
           final post = basePosts[random.nextInt(basePosts.length)];
           final data = {'content': 'Comment $i', 'user_id': user['id'], 'post_id': post['id']};
           return (future: db.insert('comments', data), data: data);
        },
        updateData: {'content': 'updated comment content'},
      );

      // Stage 4: Execute all operations concurrently
      _updateLastOperation('Executing ${operations.length} mixed operations concurrently...');
      log.add('Executing ${operations.length} mixed operations concurrently...', LogType.info);
      operations.shuffle(random);

      const batchSize = 1000;
      for (int i = 0; i < operations.length; i += batchSize) {
        final end = (i + batchSize > operations.length) ? operations.length : i + batchSize;
        final batch = operations.sublist(i, end);
        _updateLastOperation('Running batch ${i ~/ batchSize + 1}/${(operations.length / batchSize).ceil()}...');
        await Future.wait(batch, eagerError: false);
        await Future.delayed(Duration.zero); // Yield to the event loop
      }

      stopwatch.stop();
     
      // Stage 5: Verification
      _updateLastOperation('Stage 5: Verifying results...');
      
      final userConfig = config['users']!;
      final postConfig = config['posts']!;
      final commentConfig = config['comments']!;

      int calculateExpectedCount(List<Map<String, dynamic>> baseItems, Map<String, int> config) {
        final updateCount = config['update'] ?? 0;
        final deleteCount = config['delete'] ?? 0;
        final insertCount = config['insert'] ?? 0;
        // The number of items that were actually scheduled for deletion.
        final actualDeletes = min(deleteCount, max(0, baseItems.length - updateCount));
        return baseItems.length + insertCount - actualDeletes;
      }

      final expectedUserCount = calculateExpectedCount(baseUsers, userConfig);
      final expectedPostCount = calculateExpectedCount(basePosts, postConfig);
      final expectedCommentCount = calculateExpectedCount(baseComments, commentConfig);

      isTestPassed &= _expect('Final user count should be correct', await db.query('users').count(), expectedUserCount);
      isTestPassed &= _expect('Final post count should be correct', await db.query('posts').count(), expectedPostCount);
      isTestPassed &= _expect('Final comment count should be correct', await db.query('comments').count(), expectedCommentCount);

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
      log.add('Concurrency test finished in ${stopwatch.elapsedMilliseconds}ms.', LogType.info);
    }
    _updateLastOperation(isTestPassed ? '✅ Concurrency Test Passed' : '❌ Concurrency Test Failed');
    return isTestPassed;
  }
}
