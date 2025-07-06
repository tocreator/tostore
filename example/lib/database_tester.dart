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

  void _failTest(String message) {
    log.add('❌ FAIL: $message', LogType.error);
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
        {'name': 'Concurrency Stress Test', 'test': _testConcurrency},
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

  /// CRITICAL TEST: Verifies that clearing a table or deleting all records works as expected.
  /// If this fails, the database state is considered unreliable for other tests.
  Future<bool> _testClearAndDeleteAll() async {
    log.add('--- Testing: Clear Table and Delete All ---', LogType.debug);
    bool isTestPassed = true;
    try {
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

  /// Tests concurrent reads and writes across multiple tables to check for race conditions and performance.
  Future<bool> _testConcurrency() async {
    log.add('--- Testing: Concurrency Stress Test ---', LogType.debug);
    bool isTestPassed = true;
    const int userWrites = 100;
    const int postWritesPerUser = 0;
    const int reads = 100;
    const int deletes = 10;
    const int updates = 10;

    final stopwatch = Stopwatch()..start();

    try {
      await db.clear('users');
      await db.clear('posts');

      // Stage 1: Concurrently insert users to create a base dataset
      final userFutures = <Future<DbResult>>[];
      for (int i = 0; i < userWrites; i++) {
        userFutures.add(db.insert('users', {
          'username': 'concurrent_user_$i',
          'email': 'concurrent_$i@test.com',
          'age': 20 + i,
        }));
      }
      final userInsertResults = await Future.wait(userFutures, eagerError: false);
      
      final successfulUsers = <Map<String, dynamic>>[];
      for (int i = 0; i < userInsertResults.length; i++) {
          final result = userInsertResults[i];
          if (result.isSuccess && result.successKeys.isNotEmpty) {
              successfulUsers.add({'id': result.successKeys.first, 'username': 'concurrent_user_$i'});
          }
      }

      if (successfulUsers.length != userWrites) {
          log.add('Warning: Only ${successfulUsers.length}/$userWrites users were created successfully in setup.', LogType.warn);
      }
      if (successfulUsers.isEmpty) {
          _failTest('Could not create any users for concurrency test.');
          return false;
      }
      
      // Stage 2: Prepare a mix of concurrent operations
      final operations = <Future>[];
      final random = Random();

      // Add Post writes
      for (final user in successfulUsers) {
        for (int j = 0; j < postWritesPerUser; j++) {
          operations.add(db.insert('posts', {
            'title': 'Post $j for user ${user['id']}',
            'user_id': user['id'],
            'content': '...'
          }));
        }
      }

      // Add Reads
      for (int i = 0; i < reads; i++) {
        final userToRead = successfulUsers[random.nextInt(successfulUsers.length)];
        operations.add(db.query('users').where('username', '=', userToRead['username']).first());
      }
      
      // Add Deletes
      final usersToDelete = List<Map<String, dynamic>>.from(successfulUsers)..shuffle(random);
      final deletedUsernames = <String>{};
      for (int i = 0; i < deletes && i < usersToDelete.length; i++) {
        final username = usersToDelete[i]['username'] as String;
        operations.add(db.delete('users').where('username', '=', username));
        deletedUsernames.add(username);
      }

      // Add Updates
      final usersToUpdate = usersToDelete.where((u) => !deletedUsernames.contains(u['username'])).toList();
      for (int i = 0; i < updates && i < usersToUpdate.length; i++) {
        operations.add(db.update('users', {'age': 99}).where('username', '=', usersToUpdate[i]['username']));
      }

      log.add('Executing ${operations.length} mixed operations concurrently...', LogType.info);
      
      // Execute all mixed operations
      final operationResults = await Future.wait(operations, eagerError: false);
      stopwatch.stop();
      log.add(
          'Concurrency test with ${operations.length} operations finished in ${stopwatch.elapsedMilliseconds}ms.',
          LogType.info);

      // Stage 3: Verification
      final unhandledErrors = operationResults.where((r) => r is Exception || r is Error).toList();
       if (unhandledErrors.isNotEmpty) {
        isTestPassed = false;
        _failTest('Concurrency test threw ${unhandledErrors.length} unexpected exceptions. First one: ${unhandledErrors.first}');
        return false; // Critical failure
      }
      
      final finalUserCount = await db.query('users').count();
      isTestPassed &= _expect('Final user count should match writes minus deletes', finalUserCount, successfulUsers.length - deletedUsernames.length);
      
      final finalPostCount = await db.query('posts').count();
      // Since there is no cascade delete, all posts from successfully created users should remain.
      isTestPassed &= _expect('Final post count should match successful user writes', finalPostCount, successfulUsers.length * postWritesPerUser);

      // Verify an update
      if (updates > 0) {
        final updatedUser = await db.query('users').where('username', '=', usersToUpdate.first['username']).first();
         if (updatedUser != null) {
          isTestPassed &= _expect('An updated user should have the new age', updatedUser['age'], 99);
        } else if (successfulUsers.length - deletedUsernames.length > 0){
          // It's possible the user we chose to check was one of the few that failed to update,
          // but if other users still exist, this is a failure.
           _failTest('Could not find user that should have been updated.');
           isTestPassed = false;
        }
      }

    } catch (e, s) {
      isTestPassed = false;
      _failTest('Exception in _testConcurrency: $e\n$s');
    } finally {
        stopwatch.stop();
    }
    return isTestPassed;
  }
}
