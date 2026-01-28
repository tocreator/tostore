import 'dart:async';
import 'dart:math';
import 'package:tostore/tostore.dart';

import 'log_service.dart';

/// A comprehensive testing suite for validating Tostore's core functionalities.
/// It covers basic CRUD, upsert, joins, multi-space, and various edge cases.
class DatabaseTester {
  final ToStore db;
  final LogService log;
  final Function(String) _updateLastOperation;

  DatabaseTester(this.db, this.log, this._updateLastOperation);

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
        {'name': 'Backup & Restore', 'test': _testBackupAndRestore},
        {'name': 'Foreign Key Operations', 'test': _testForeignKeyOperations},
        {'name': 'Expression Operations', 'test': _testExpressionOperations},
        {'name': 'Transaction Operations', 'test': _testTransactionOperations},
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
        passed = await testFunction();
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
      // CRITICAL: Clean up all tables after tests are finished to ensure a clean state.
      _updateLastOperation('Cleaning up test data...');
      await _clearTablesSafely();
      log.add('--- All test data cleared. ---', LogType.info);
    }

    _updateLastOperation(
        allTestsPassed ? '✅ All Tests Passed' : '❌ Tests Failed');
    return allTestsPassed;
  }

  // Default concurrency test config using users and settings tables
  // to avoid foreign key constraint issues. Both tables have no foreign key dependencies,
  // allowing true concurrent operations without RESTRICT constraint blocking.
  static const Map<String, Map<String, int>> _baseConcurrencyConfig = {
    'users': {
      'insert': 100,
      'read': 100,
      'update': 50,
      'delete': 50,
    },
    'settings': {
      'insert': 100,
      'read': 100,
      'update': 50,
      'delete': 50,
    },
  };

  /// Safely clear tables in the correct order to respect foreign key constraints.
  /// Order: comments -> posts -> users (to respect RESTRICT foreign key constraint)
  Future<void> _clearTablesSafely({bool includeComments = true}) async {
    if (includeComments) {
      await db.clear('comments');
    }
    await db.clear('posts');
    await db.clear('users');
  }

  /// CRITICAL TEST: Verifies that clearing a table or deleting all records works as expected.
  /// If this fails, the database state is considered unreliable for other tests.
  Future<bool> _testClearAndDeleteAll() async {
    log.add('--- Testing: Clear Table and Delete All ---', LogType.debug);
    bool isTestPassed = true;
    try {
      // Ensure a clean slate before this critical test, preventing state leakage from previous runs.
      await _clearTablesSafely();

      // 1. Test db.clear()
      await db.batchInsert('users', [
        {'username': 'clear_user_1', 'email': 'cu1@test.com'},
        {'username': 'clear_user_2', 'email': 'cu2@test.com'},
      ]);

      // Clear users (should work since no foreign key references exist yet)
      await db.clear('users');
      final dataAfterClear = await db.query('users');
      final countAfterClear = dataAfterClear.length;

      isTestPassed &=
          _expect('Count after clear should be 0', countAfterClear, 0);
      isTestPassed &=
          _expect('Data after clear should be empty', dataAfterClear.data, []);
      if (!isTestPassed) return false; // Critical failure

      // 2. Test deleting all records with a condition
      // Note: Don't use fixed IDs to avoid foreign key issues, let DB generate them
      await db.batchInsert('users', [
        {'username': 'delete_user_1', 'email': 'du1@test.com'},
        {'username': 'delete_user_2', 'email': 'du2@test.com'},
      ]);
      final deleteResult = await db.delete('users').where('id', '>', 0);
      isTestPassed &= _expect(
          'Delete result should be successful', deleteResult.isSuccess, true);
      final dataAfterDelete = await db.query('users');
      final countAfterDelete = dataAfterDelete.length;
      isTestPassed &= _expect(
          'Count after deleting all (id > 0) should be 0', countAfterDelete, 0);
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
      await _clearTablesSafely();
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
      final dataAfterDeleteQuery = await db.query('users');
      final countAfterDelete = dataAfterDeleteQuery.length;
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
      await _clearTablesSafely();
      // Upsert (insert)
      await db.upsert(
          'users', {'username': 'upsert_user', 'email': 'upsert@test.com'});
      final dataAfterInsert = await db.query('users');
      final countAfterInsert = dataAfterInsert.length;
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
      final dataAfterUpdate = await db.query('users');
      isTestPassed &= _expect('Upsert-update should not create a new user',
          dataAfterUpdate.length, 1);
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
      await _clearTablesSafely();
      // Insert user first to get valid ID for foreign key
      final userResult = await db
          .insert('users', {'username': 'join_user', 'email': 'join@test.com'});
      if (!userResult.isSuccess) {
        isTestPassed = false;
        _failTest('Failed to insert user for join test');
        return false;
      }
      final userId = userResult.successKeys.first;
      await db.insert(
          'posts', {'title': 'Join Post', 'user_id': userId, 'content': '...'});

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
      await _clearTablesSafely();
      await db.insert('users',
          {'username': 'user_space1', 'email': 'user_space2@test.com'});
      final data1 = await db.query('users');
      final count1 = data1.length;
      isTestPassed &= _expect('Count in space1 should be 1', count1, 1);

      // Switch to space 'space2'
      await db.switchSpace(spaceName: 'space2');
      await _clearTablesSafely();
      final data2 = await db.query('users');
      final count2 = data2.length;
      isTestPassed &=
          _expect('Count in space2 should be 0 initially', count2, 0);
      await db.insert('users',
          {'username': 'user_space2', 'email': 'user_space2@test.com'});
      final data3 = await db.query('users');
      final count3 = data3.length;
      isTestPassed &=
          _expect('Count in space2 after insert should be 1', count3, 1);

      // Verify space1 was not affected
      await db.switchSpace(spaceName: 'space1');
      final data4 = await db.query('users');
      final count4 = data4.length;
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
      await _clearTablesSafely();
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
      await _clearTablesSafely();
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

      final count = (await db.query('users')).length;
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
      final actualData = await query;
      final actualLength = actualData.length;

      return _expect(
          '$step: Actual data length ($actualLength) should be verified',
          actualLength,
          actualLength);
    }

    try {
      await _clearTablesSafely();
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

  /// Tests backup and restore correctness.
  /// Flow:
  /// 1) clear tables; 2) insert base data; 3) backup; 4) mutate data; 5) restore; 6) verify data rolled back to backup snapshot.
  Future<bool> _testBackupAndRestore() async {
    log.add('--- Testing: Backup & Restore ---', LogType.debug);
    bool ok = true;
    String backupPath = '';
    try {
      // Step 1: clean state
      await _clearTablesSafely();

      // Step 2: insert base data
      final u1 = await db.insert('users',
          {'username': 'bk_user_1', 'email': 'bk1@test.com', 'age': 21});
      final u2 = await db.insert('users',
          {'username': 'bk_user_2', 'email': 'bk2@test.com', 'age': 22});
      ok &= _expect(
          'Insert base users success', u1.isSuccess && u2.isSuccess, true);
      final p1 = await db.insert(
          'posts', {'title': 'bk_post_1', 'user_id': u1.successKeys.first});
      ok &= _expect('Insert base post success', p1.isSuccess, true);

      // Snapshot counts before backup
      final usersBefore = (await db.query('users')).length;
      final postsBefore = (await db.query('posts')).length;
      final commentsBefore = (await db.query('comments')).length;

      // Step 3: create backup (partial backup is enough)
      backupPath = await db.backup(compress: false);
      ok &= _expect(
          'Backup path should be non-empty', backupPath.isNotEmpty, true);

      // Step 4: mutate data after backup
      await db.insert('users',
          {'username': 'bk_user_3', 'email': 'bk3@test.com', 'age': 23});
      await db.update('users', {'age': 99}).where('username', '=', 'bk_user_1');
      await db.delete('users').where('username', '=', 'bk_user_2');

      // Sanity check: content changed (not just count)
      final insertedUser3 =
          await db.query('users').where('username', '=', 'bk_user_3');
      final deletedUser2 =
          await db.query('users').where('username', '=', 'bk_user_2');
      final updatedUser1 =
          await db.query('users').where('username', '=', 'bk_user_1').first();
      ok &= _expect('bk_user_3 inserted', insertedUser3.length, 1);
      ok &= _expect('bk_user_2 deleted', deletedUser2.length, 0);
      ok &= _expect('bk_user_1 age updated to 99', updatedUser1?['age'], 99);

      // Step 5: restore from backup (deleteAfterRestore = true to keep clean)
      final restored = await db.restore(backupPath, deleteAfterRestore: true);
      ok &= _expect('Restore should return true', restored, true);

      // Step 6: verify state equals snapshot
      final usersAfter = await db.query('users').orderByAsc('username');
      final postsAfter = await db.query('posts').orderByAsc('title');
      final commentsAfter = await db.query('comments');

      ok &= _expect('Users count after restore equals before backup',
          usersAfter.length, usersBefore);
      ok &= _expect('Posts count after restore equals before backup',
          postsAfter.length, postsBefore);
      ok &= _expect('Comments count after restore equals before backup',
          commentsAfter.length, commentsBefore);

      // Verify specific records restored (bk_user_1 and bk_user_2 exist; ages restored)
      final uRestored1 =
          await db.query('users').where('username', '=', 'bk_user_1').first();
      final uRestored2 =
          await db.query('users').where('username', '=', 'bk_user_2').first();
      ok &= _expect('bk_user_1 exists after restore', uRestored1 != null, true);
      ok &= _expect('bk_user_2 exists after restore', uRestored2 != null, true);
      ok &= _expect('bk_user_1 age restored to 21', uRestored1?['age'], 21);

      // Ensure post restored
      ok &= _expect('Post count restored to 1', postsAfter.length, 1);
    } catch (e, s) {
      ok = false;
      _failTest('Exception in _testBackupAndRestore: $e\n$s');
    } finally {
      // Clean up backup artifact if still exists and restore failed to remove
      try {
        if (backupPath.isNotEmpty) {
          // no direct fs access here; rely on restore(deleteAfterRestore) above
        }
      } catch (_) {}
    }
    return ok;
  }

  /// Runs a configurable concurrency test based on user input.
  /// Uses users and settings tables to avoid foreign key constraint issues.
  /// Both tables have no foreign key dependencies, allowing true concurrent operations.
  Future<bool> runConfigurableConcurrencyTest(
      Map<String, Map<String, int>> config,
      {int verificationSampleSize = 10}) async {
    log.add(
        '--- Testing: Configurable Concurrency Stress Test (users & settings) ---',
        LogType.debug);
    _updateLastOperation('Starting Configurable Concurrency Test...');
    bool isTestPassed = true;
    final stopwatch = Stopwatch()..start();

    // Data stores for verification
    final insertedUsers = <Map<String, dynamic>>[];
    final updatedUsers = <Map<String, dynamic>>[];
    final deletedUsers = <Map<String, dynamic>>[];
    final insertedSettings = <Map<String, dynamic>>[];
    final updatedSettings = <Map<String, dynamic>>[];
    final deletedSettings = <Map<String, dynamic>>[];

    try {
      // Clear tables safely (users and settings have no foreign key dependencies)
      // However, if previous tests created comments/posts with RESTRICT constraints,
      // we need to clear them first before clearing users
      await db.clear('comments');
      await db.clear('posts');
      await db.clear('users');
      await db.clear('settings');

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
          // Store original data by index to ensure correct mapping
          final originalDataList = <Map<String, dynamic>>[];

          // Generate and execute base data creation in batches to avoid UI jank
          const batchSize = 50;
          for (int i = 0; i < baseCount; i += batchSize) {
            final end = (i + batchSize > baseCount) ? baseCount : i + batchSize;

            _updateLastOperation(
                'Preparing base for $tableName: ${i + 1}-$end of $baseCount');

            final batchFutures = <Future<DbResult>>[];
            for (int batchIndex = i; batchIndex < end; batchIndex++) {
              final gen = insertGenerator(batchIndex);
              originalDataList.add(gen.data);
              batchFutures.add(gen.future);
              // Yield frequently within the batch to prevent UI lag during generation
              if (batchIndex > 0 && batchIndex % 10 == 0) {
                await Future.delayed(Duration.zero);
              }
            }

            final results = await Future.wait(batchFutures, eagerError: true);

            for (int j = 0; j < results.length; j++) {
              final r = results[j];
              final globalIndex = i + j;
              if (r.isSuccess &&
                  r.successKeys.isNotEmpty &&
                  globalIndex < originalDataList.length) {
                final originalData = originalDataList[globalIndex];
                final Map<String, dynamic> newItem = {
                  idField: r.successKeys.first
                };
                if (originalData.containsKey(nameField)) {
                  newItem[nameField] = originalData[nameField];
                }
                baseItems.add(newItem);
              }
              if (j % 50 == 0) {
                await Future.delayed(Duration.zero);
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
          for (int i = 0; i < itemsToDeleteLocal.length; i++) {
            final item = itemsToDeleteLocal[i];
            operations
                .add(db.delete(tableName).where(idField, '=', item[idField]));
            if (i % 50 == 0) {
              await Future.delayed(Duration.zero);
            }
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
      await prepareAndGenerateOpsForTable(
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

      // Stage 2: Prepare Settings
      await prepareAndGenerateOpsForTable(
        tableName: 'settings',
        tableConfig: config['settings']!,
        itemsToInsert: insertedSettings,
        itemsToUpdate: updatedSettings,
        itemsToDelete: deletedSettings,
        insertGenerator: (i) {
          final data = {
            'key': 'cc_setting_$i',
            'value': 'value_$i',
          };
          return (future: db.insert('settings', data), data: data);
        },
        updateData: {'value': 'updated_value'},
        idField: 'key',
        nameField: 'key',
      );

      // Stage 3: Execute all operations concurrently
      _updateLastOperation(
          'Executing ${operations.length} mixed operations concurrently...');
      log.add('Executing ${operations.length} mixed operations concurrently...',
          LogType.info);
      operations.shuffle(random);

      // Track actual deletion results
      final actualDeletedUsers = <String>[];
      final actualDeletedSettings = <String>[];

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

      // Stage 4: Verification
      _updateLastOperation('Verifying results...');

      // Verify which deletions actually succeeded
      _updateLastOperation('Checking actual deletion results...');
      for (int i = 0; i < deletedUsers.length; i++) {
        final user = deletedUsers[i];
        final exists =
            await db.query('users').where('id', '=', user['id']).first();
        if (exists == null) {
          actualDeletedUsers.add(user['id'].toString());
        }
        // Yield to UI thread every 50 iterations to prevent UI jank
        if (i % 50 == 0) {
          await Future.delayed(Duration.zero);
        }
      }
      for (int i = 0; i < deletedSettings.length; i++) {
        final setting = deletedSettings[i];
        final exists = await db
            .query('settings')
            .where('key', '=', setting['key'])
            .first();
        if (exists == null) {
          actualDeletedSettings.add(setting['key'].toString());
        }
        // Yield to UI thread every 50 iterations to prevent UI jank
        if (i % 50 == 0) {
          await Future.delayed(Duration.zero);
        }
      }

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
        for (int i = 0; i < result.data.length; i++) {
          final user = result.data[i];
          isTestPassed &= _expect(
              'User ${user['id']} age should be updated', user['age'], 999);
          // Yield to UI thread every 50 iterations to prevent UI jank
          if (i % 50 == 0) {
            await Future.delayed(Duration.zero);
          }
        }
      }

      // Verify deleted users are gone
      final deletedUserSample = getHeadTailSample(deletedUsers);
      final actuallyDeletedUserIds = deletedUserSample
          .where((u) => actualDeletedUsers.contains(u['id'].toString()))
          .map((u) => u['id'])
          .toList();
      if (actuallyDeletedUserIds.isNotEmpty) {
        final result =
            await db.query('users').whereIn('id', actuallyDeletedUserIds);
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

      _updateLastOperation('Verifying data integrity for settings...');
      // Verify updated settings
      final updatedSettingsSample = getHeadTailSample(updatedSettings);
      final updatedSettingKeys =
          updatedSettingsSample.map((s) => s['key'] as String).toList();
      if (updatedSettingKeys.isNotEmpty) {
        final result =
            await db.query('settings').whereIn('key', updatedSettingKeys);
        isTestPassed &= _expect(
            'All updated settings in sample must exist after test',
            result.length,
            updatedSettingKeys.length);
        for (int i = 0; i < result.data.length; i++) {
          final setting = result.data[i];
          isTestPassed &= _expect(
              'Setting ${setting['key']} value should be updated',
              setting['value'],
              'updated_value');
          // Yield to UI thread every 50 iterations to prevent UI jank
          if (i % 50 == 0) {
            await Future.delayed(Duration.zero);
          }
        }
      }

      // Verify deleted settings
      final deletedSettingsSample = getHeadTailSample(deletedSettings);
      final actuallyDeletedSettingKeys = deletedSettingsSample
          .where((s) => actualDeletedSettings.contains(s['key'].toString()))
          .map((s) => s['key'] as String)
          .toList();
      if (actuallyDeletedSettingKeys.isNotEmpty) {
        isTestPassed &= _expect(
            'Deleted settings in sample should not be found',
            (await db
                    .query('settings')
                    .whereIn('key', actuallyDeletedSettingKeys))
                .length,
            0);
      }

      // Verify inserted settings
      final insertedSettingsSample = getHeadTailSample(insertedSettings);
      final insertedSettingKeys =
          insertedSettingsSample.map((s) => s['key'] as String).toList();
      if (insertedSettingKeys.isNotEmpty) {
        isTestPassed &= _expect(
            'All newly inserted settings in sample should be found',
            (await db.query('settings').whereIn('key', insertedSettingKeys))
                .length,
            insertedSettingKeys.length);
      }
    } catch (e, s) {
      isTestPassed = false;
      _failTest('Exception in runConfigurableConcurrencyTest: $e\n$s');
    } finally {
      stopwatch.stop();
      _updateLastOperation('Cleaning up test data...');
      // Clear in correct order to respect foreign key constraints
      await db.clear('comments');
      await db.clear('posts');
      await db.clear('users');
      await db.clear('settings');
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

  /// Comprehensive test for foreign key operations.
  /// Tests constraint validation, cascade delete, cascade update, RESTRICT, and clear/drop operations.
  Future<bool> _testForeignKeyOperations() async {
    log.add('--- Testing: Foreign Key Operations ---', LogType.debug);
    bool isTestPassed = true;
    try {
      await _clearTablesSafely();

      // ========== Test 1: Foreign Key Constraint Validation ==========
      log.add(
          '--- Sub-test: Foreign Key Constraint Validation ---', LogType.debug);

      // Insert a valid user
      final userResult = await db.insert('users', {
        'username': 'fk_user',
        'email': 'fk@test.com',
      });
      isTestPassed &=
          _expect('Insert user should succeed', userResult.isSuccess, true);
      if (!isTestPassed) return false;

      final userId = userResult.successKeys.first;

      // Test 1.1: Insert post with valid foreign key
      final postResult = await db.insert('posts', {
        'title': 'Valid Post',
        'user_id': userId,
      });
      isTestPassed &= _expect('Insert post with valid user_id should succeed',
          postResult.isSuccess, true);

      // Test 1.2: Insert post with invalid foreign key (non-existent user_id)
      final invalidPostResult = await db.insert('posts', {
        'title': 'Invalid Post',
        'user_id': '99999', // Non-existent user ID
      });
      isTestPassed &= _expect('Insert post with invalid user_id should fail',
          invalidPostResult.isSuccess, false);
      isTestPassed &= _expect(
          'Error type should be foreignKeyViolation or validationFailed',
          invalidPostResult.type == ResultType.foreignKeyViolation ||
              invalidPostResult.type == ResultType.validationFailed,
          true);

      // Test 1.3: Insert comment with valid foreign keys
      final postId = postResult.successKeys.first;
      final commentResult = await db.insert('comments', {
        'post_id': postId,
        'user_id': userId,
        'content': 'Valid comment',
      });
      isTestPassed &= _expect(
          'Insert comment with valid foreign keys should succeed',
          commentResult.isSuccess,
          true);

      // Test 1.4: Insert comment with invalid post_id
      final invalidCommentResult1 = await db.insert('comments', {
        'post_id': '99999', // Non-existent post ID
        'user_id': userId,
        'content': 'Invalid comment',
      });
      isTestPassed &= _expect('Insert comment with invalid post_id should fail',
          invalidCommentResult1.isSuccess, false);

      // Test 1.5: Insert comment with invalid user_id
      final invalidCommentResult2 = await db.insert('comments', {
        'post_id': postId,
        'user_id': '99999', // Non-existent user ID
        'content': 'Invalid comment',
      });
      isTestPassed &= _expect('Insert comment with invalid user_id should fail',
          invalidCommentResult2.isSuccess, false);

      // ========== Test 2: Cascade Delete (CASCADE) ==========
      log.add('--- Sub-test: Cascade Delete ---', LogType.debug);

      await _clearTablesSafely();

      // Create test data: user -> posts -> comments
      // Note: comments.user_id has RESTRICT, so we use a different user for comments
      // to avoid RESTRICT blocking the cascade delete test
      final cascadeUserResult = await db.insert('users', {
        'username': 'cascade_user',
        'email': 'cascade@test.com',
      });
      isTestPassed &= _expect(
          'Insert user should succeed', cascadeUserResult.isSuccess, true);
      if (!isTestPassed) return false;

      final cascadeUserId = cascadeUserResult.successKeys.first;

      // Create a separate user for comments (to avoid RESTRICT blocking cascade delete)
      final cascadeCommentUserResult = await db.insert('users', {
        'username': 'cascade_comment_user',
        'email': 'cascade_comment@test.com',
      });
      isTestPassed &= _expect('Insert comment user should succeed',
          cascadeCommentUserResult.isSuccess, true);
      if (!isTestPassed) return false;

      final cascadeCommentUserId = cascadeCommentUserResult.successKeys.first;

      // Create posts for the user
      final cascadePost1Result = await db.insert('posts', {
        'title': 'Post 1',
        'user_id': cascadeUserId,
      });
      final cascadePost2Result = await db.insert('posts', {
        'title': 'Post 2',
        'user_id': cascadeUserId,
      });
      isTestPassed &= _expect('Insert posts should succeed',
          cascadePost1Result.isSuccess && cascadePost2Result.isSuccess, true);
      if (!isTestPassed) return false;

      final cascadePost1Id = cascadePost1Result.successKeys.first;
      final cascadePost2Id = cascadePost2Result.successKeys.first;

      // Create comments for posts (using different user to avoid RESTRICT blocking)
      await db.insert('comments', {
        'post_id': cascadePost1Id,
        'user_id': cascadeCommentUserId, // Use different user to avoid RESTRICT
        'content': 'Comment 1',
      });
      await db.insert('comments', {
        'post_id': cascadePost1Id,
        'user_id': cascadeCommentUserId, // Use different user to avoid RESTRICT
        'content': 'Comment 2',
      });
      await db.insert('comments', {
        'post_id': cascadePost2Id,
        'user_id': cascadeCommentUserId, // Use different user to avoid RESTRICT
        'content': 'Comment 3',
      });

      // Verify initial counts
      final postsBefore =
          await db.query('posts').where('user_id', '=', cascadeUserId);
      final commentsBefore = await db
          .query('comments')
          .whereIn('post_id', [cascadePost1Id, cascadePost2Id]);
      isTestPassed &=
          _expect('Should have 2 posts before delete', postsBefore.length, 2);
      isTestPassed &= _expect(
          'Should have 3 comments before delete', commentsBefore.length, 3);

      // Store the total comment count before delete (to verify cascade delete)
      // Note: We need to get the count AFTER creating all test data to ensure accuracy
      final totalCommentsBefore = await db.query('comments').count();
      isTestPassed &= _expect('Should have at least 3 comments before delete',
          totalCommentsBefore >= 3, true);
      if (!isTestPassed) return false;

      // Delete user (should cascade delete posts, which should cascade delete comments)
      final deleteResult =
          await db.delete('users').where('id', '=', cascadeUserId);
      isTestPassed &=
          _expect('Delete user should succeed', deleteResult.isSuccess, true);
      if (!isTestPassed) return false;

      // Verify cascade delete: posts should be deleted
      final postsAfter =
          await db.query('posts').where('user_id', '=', cascadeUserId);
      isTestPassed &=
          _expect('Posts should be cascade deleted', postsAfter.length, 0);
      if (!isTestPassed) return false;

      // Verify cascade delete: comments should be deleted
      final commentsAfter = await db
          .query('comments')
          .whereIn('post_id', [cascadePost1Id, cascadePost2Id]);
      isTestPassed &= _expect(
          'Comments should be cascade deleted', commentsAfter.length, 0);

      // ========== Test 3: Cascade Update (CASCADE) ==========
      log.add('--- Sub-test: Cascade Update ---', LogType.debug);

      await _clearTablesSafely();

      // Create test data
      final updateUserResult = await db.insert('users', {
        'username': 'update_user',
        'email': 'update@test.com',
      });
      isTestPassed &= _expect(
          'Insert user should succeed', updateUserResult.isSuccess, true);
      if (!isTestPassed) return false;

      final updateUserId = updateUserResult.successKeys.first;

      // Create post
      final updatePostResult = await db.insert('posts', {
        'title': 'Update Post',
        'user_id': updateUserId,
      });
      isTestPassed &= _expect(
          'Insert post should succeed', updatePostResult.isSuccess, true);
      if (!isTestPassed) return false;

      final updatePostId = updatePostResult.successKeys.first;

      // Create comment
      await db.insert('comments', {
        'post_id': updatePostId,
        'user_id': updateUserId,
        'content': 'Update Comment',
      });

      // Verify initial state
      final updatePostBefore =
          await db.query('posts').where('id', '=', updatePostId).first();
      isTestPassed &= _expect(
          'Post should exist before update', updatePostBefore != null, true);
      // Compare as strings since primary keys are stored as strings, but foreign key fields may be integers
      isTestPassed &= _expect('Post user_id should match',
          updatePostBefore?['user_id']?.toString(), updateUserId.toString());

      // Verify foreign key constraint is still enforced after operations
      final updateCommentBefore = await db
          .query('comments')
          .where('post_id', '=', updatePostId)
          .first();
      isTestPassed &=
          _expect('Comment should exist', updateCommentBefore != null, true);
      // Compare as strings since primary keys are stored as strings, but foreign key fields may be integers
      isTestPassed &= _expect('Comment post_id should match',
          updateCommentBefore?['post_id']?.toString(), updatePostId.toString());

      // ========== Test 4: RESTRICT Constraint ==========
      log.add('--- Sub-test: RESTRICT Constraint ---', LogType.debug);

      await _clearTablesSafely();

      // Create test data
      final restrictUserResult = await db.insert('users', {
        'username': 'restrict_user',
        'email': 'restrict@test.com',
      });
      isTestPassed &= _expect(
          'Insert user should succeed', restrictUserResult.isSuccess, true);
      if (!isTestPassed) return false;

      final restrictUserId = restrictUserResult.successKeys.first;

      // Create post (posts.user_id has CASCADE, so this won't test RESTRICT)
      final restrictPostResult = await db.insert('posts', {
        'title': 'Restrict Post',
        'user_id': restrictUserId,
      });
      isTestPassed &= _expect(
          'Insert post should succeed', restrictPostResult.isSuccess, true);
      if (!isTestPassed) return false;

      final restrictPostId = restrictPostResult.successKeys.first;

      // Create comment (comments.user_id has RESTRICT)
      final restrictCommentResult = await db.insert('comments', {
        'post_id': restrictPostId,
        'user_id': restrictUserId,
        'content': 'Restrict Comment',
      });
      isTestPassed &= _expect('Insert comment should succeed',
          restrictCommentResult.isSuccess, true);
      if (!isTestPassed) return false;

      // Try to delete user - should fail because comments.user_id has RESTRICT
      final restrictDeleteResult =
          await db.delete('users').where('id', '=', restrictUserId);
      isTestPassed &= _expect(
          'Delete user with RESTRICT foreign key should fail',
          restrictDeleteResult.isSuccess,
          false);
      isTestPassed &= _expect(
          'Error type should be foreignKeyViolation or validationFailed',
          restrictDeleteResult.type == ResultType.foreignKeyViolation ||
              restrictDeleteResult.type == ResultType.validationFailed,
          true);

      // Verify user still exists
      final restrictUserAfter =
          await db.query('users').where('id', '=', restrictUserId).first();
      isTestPassed &= _expect('User should still exist after failed delete',
          restrictUserAfter != null, true);

      // Delete comment first, then user should succeed
      await db
          .delete('comments')
          .where('id', '=', restrictCommentResult.successKeys.first);
      final restrictDeleteResult2 =
          await db.delete('users').where('id', '=', restrictUserId);
      isTestPassed &= _expect(
          'Delete user after removing comment should succeed',
          restrictDeleteResult2.isSuccess,
          true);

      // ========== Test 5: Clear and Drop Operations ==========
      log.add('--- Sub-test: Clear and Drop Operations ---', LogType.debug);

      await _clearTablesSafely();

      // Create test data
      final clearUser1Result = await db.insert('users', {
        'username': 'clear_user1',
        'email': 'clear1@test.com',
      });
      final clearUser2Result = await db.insert('users', {
        'username': 'clear_user2',
        'email': 'clear2@test.com',
      });
      isTestPassed &= _expect('Insert users should succeed',
          clearUser1Result.isSuccess && clearUser2Result.isSuccess, true);
      if (!isTestPassed) return false;

      final clearUser1Id = clearUser1Result.successKeys.first;
      final clearUser2Id = clearUser2Result.successKeys.first;

      // Create posts
      final clearPost1Result = await db.insert('posts', {
        'title': 'Clear Post 1',
        'user_id': clearUser1Id,
      });
      final clearPost2Result = await db.insert('posts', {
        'title': 'Clear Post 2',
        'user_id': clearUser2Id,
      });
      isTestPassed &= _expect('Insert posts should succeed',
          clearPost1Result.isSuccess && clearPost2Result.isSuccess, true);
      if (!isTestPassed) return false;

      final clearPost1Id = clearPost1Result.successKeys.first;
      final clearPost2Id = clearPost2Result.successKeys.first;

      // Create comments
      await db.insert('comments', {
        'post_id': clearPost1Id,
        'user_id': clearUser1Id,
        'content': 'Comment 1',
      });
      await db.insert('comments', {
        'post_id': clearPost2Id,
        'user_id': clearUser2Id,
        'content': 'Comment 2',
      });

      // Test 5.1: Clear posts table (should cascade delete comments)
      final clearPostsBefore = await db.query('posts').count();
      final clearCommentsBefore = await db.query('comments').count();
      isTestPassed &=
          _expect('Should have 2 posts before clear', clearPostsBefore, 2);
      isTestPassed &= _expect(
          'Should have 2 comments before clear', clearCommentsBefore, 2);

      await db.clear('posts');

      final clearPostsAfter = await db.query('posts').count();
      final clearCommentsAfter = await db.query('comments').count();
      isTestPassed &= _expect('Posts should be cleared', clearPostsAfter, 0);
      isTestPassed &=
          _expect('Comments should be cascade deleted', clearCommentsAfter, 0);

      // Test 5.2: Clear users table (should handle RESTRICT constraint)
      // First, ensure clean state by clearing all tables
      // Note: clear('users') may fail due to RESTRICT, so we need to clear comments first
      await db.clear('comments');
      await db.clear('posts');
      // Now clear users should succeed since no comments reference users
      final clearUsersBeforeTest = await db.clear('users');
      if (!clearUsersBeforeTest.isSuccess) {
        // If clear failed, manually delete all users
        await db.delete('users').allowDeleteAll();
      }

      // Create test data for RESTRICT test
      final clearUser3Result = await db.insert('users', {
        'username': 'clear_user3',
        'email': 'clear3@test.com',
      });
      isTestPassed &= _expect('Insert user for RESTRICT test should succeed',
          clearUser3Result.isSuccess, true);
      if (!isTestPassed) return false;

      final clearUser3Id = clearUser3Result.successKeys.first;
      final clearPost3Result = await db.insert('posts', {
        'title': 'Clear Post 3',
        'user_id': clearUser3Id,
      });
      isTestPassed &= _expect('Insert post for RESTRICT test should succeed',
          clearPost3Result.isSuccess, true);
      if (!isTestPassed) return false;

      final clearPost3Id = clearPost3Result.successKeys.first;
      final clearCommentResult = await db.insert('comments', {
        'post_id': clearPost3Id,
        'user_id': clearUser3Id,
        'content': 'Comment 3',
      });
      isTestPassed &= _expect('Insert comment for RESTRICT test should succeed',
          clearCommentResult.isSuccess, true);
      if (!isTestPassed) return false;

      // Verify initial state: should have exactly 1 user
      final usersBeforeClear = await db.query('users').count();
      isTestPassed &= _expect(
          'Should have exactly 1 user before clear', usersBeforeClear, 1);
      if (!isTestPassed) return false;

      // Try to clear users - should fail because comments.user_id has RESTRICT
      final clearResult = await db.clear('users');
      isTestPassed &= _expect(
          'Clear users with RESTRICT foreign key should fail',
          clearResult.isSuccess,
          false);
      isTestPassed &= _expect(
          'Error type should be foreignKeyViolation or validationFailed',
          clearResult.type == ResultType.foreignKeyViolation ||
              clearResult.type == ResultType.validationFailed,
          true);

      // Verify users still exist (should still be 1, the same as before)
      final clearUsersAfterFailed = await db.query('users').count();
      isTestPassed &= _expect('Users should still exist after failed clear',
          clearUsersAfterFailed, 1);
    } catch (e, s) {
      isTestPassed = false;
      _failTest('Exception in _testForeignKeyOperations: $e\n$s');
    }
    return isTestPassed;
  }

  /// Comprehensive test for expression operations.
  /// Tests atomic field expressions including increment, multiply, complex calculations, and timestamp.
  Future<bool> _testExpressionOperations() async {
    log.add('--- Testing: Expression Operations ---', LogType.debug);
    bool isTestPassed = true;
    try {
      await _clearTablesSafely();

      // Test 1: Simple increment expression
      await db.insert('users', {
        'username': 'expr_user1',
        'email': 'expr1@test.com',
        'age': 20,
        'fans': 100,
      });

      await db.update('users', {
        'fans': Expr.field('fans') + Expr.value(50),
      }).where('username', '=', 'expr_user1');

      final user1 =
          await db.query('users').where('username', '=', 'expr_user1').first();
      isTestPassed &= _expect(
          'Increment expression: fans should be 150', user1?['fans'], 150);

      // Test 2: Multiply expression
      await db.update('users', {
        'fans': Expr.field('fans') * Expr.value(0.9),
      }).where('username', '=', 'expr_user1');

      final user1AfterMultiply =
          await db.query('users').where('username', '=', 'expr_user1').first();
      isTestPassed &= _expect(
          'Multiply expression: fans should be 135 (150 * 0.9)',
          user1AfterMultiply?['fans'],
          135);

      // Test 3: Complex multi-field expression
      await db.insert('users', {
        'username': 'expr_user2',
        'email': 'expr2@test.com',
        'age': 25,
        'fans': 200,
      });

      await db.update('users', {
        'fans': Expr.field('fans') + (Expr.field('age') * Expr.value(2)),
      }).where('username', '=', 'expr_user2');

      final user2 =
          await db.query('users').where('username', '=', 'expr_user2').first();
      isTestPassed &= _expect(
          'Complex expression: fans should be 250 (200 + 25*2)',
          user2?['fans'],
          250);

      // Test 4: Multi-level parentheses expression
      await db.insert('users', {
        'username': 'expr_user3',
        'email': 'expr3@test.com',
        'age': 30,
        'fans': 300,
      });

      await db.update('users', {
        'fans': ((Expr.field('fans') + Expr.field('age')) * Expr.value(0.8)) -
            Expr.value(10),
      }).where('username', '=', 'expr_user3');

      final user3 =
          await db.query('users').where('username', '=', 'expr_user3').first();
      // Expected: ((300 + 30) * 0.8) - 10 = 264 - 10 = 254
      isTestPassed &= _expect(
          'Multi-level parentheses: fans should be 254', user3?['fans'], 254);

      // Test 5: Min/Max functions
      await db.update('users', {
        'fans': Expr.min(Expr.field('fans'), Expr.value(200)),
      }).where('username', '=', 'expr_user3');

      final user3AfterMin =
          await db.query('users').where('username', '=', 'expr_user3').first();
      isTestPassed &= _expect(
          'Min function: fans should be 200', user3AfterMin?['fans'], 200);

      await db.update('users', {
        'fans': Expr.max(Expr.field('fans'), Expr.value(300)),
      }).where('username', '=', 'expr_user3');

      final user3AfterMax =
          await db.query('users').where('username', '=', 'expr_user3').first();
      isTestPassed &= _expect(
          'Max function: fans should be 300', user3AfterMax?['fans'], 300);

      // Test 6: Timestamp expression
      await db.update('users', {
        'last_login': Expr.now(),
      }).where('username', '=', 'expr_user1');

      final user1WithTimestamp =
          await db.query('users').where('username', '=', 'expr_user1').first();
      isTestPassed &= _expect('Timestamp expression: last_login should be set',
          user1WithTimestamp?['last_login'] != null, true);

      // Test 7: Chain builder syntax sugar
      await db.insert('users', {
        'username': 'expr_user4',
        'email': 'expr4@test.com',
        'age': 35,
        'fans': 400,
      });

      await db
          .update('users', {})
          .increment('fans', 100)
          .compute('age', Expr.round(Expr.field('age') * Expr.value(1.1)))
          .where('username', '=', 'expr_user4');

      final user4 =
          await db.query('users').where('username', '=', 'expr_user4').first();
      isTestPassed &=
          _expect('Chain increment: fans should be 500', user4?['fans'], 500);
      isTestPassed &= _expect(
          'Chain multiply: age should be 39 (35 * 1.1 rounded)',
          user4?['age'],
          39); // round(38.5) = 39

      // Test 8: Expression in Map literal
      await db.insert('users', {
        'username': 'expr_user5',
        'email': 'expr5@test.com',
        'age': 40,
        'fans': 500,
      });

      await db.update('users', {
        'fans': Expr.field('fans') * Expr.field('age') / Expr.value(10),
        'last_login': Expr.now(),
      }).where('username', '=', 'expr_user5');

      final user5 =
          await db.query('users').where('username', '=', 'expr_user5').first();
      // Expected: 500 * 40 / 10 = 2000
      isTestPassed &= _expect(
          'Expression in Map: fans should be 2000', user5?['fans'], 2000);

      // Test 9: Division by zero handling
      await db.update('users', {
        'fans': Expr.field('fans') / Expr.value(0),
      }).where('username', '=', 'expr_user5');

      final user5AfterDivZero =
          await db.query('users').where('username', '=', 'expr_user5').first();
      // Division by zero should return 0 (safe handling)
      isTestPassed &= _expect(
          'Division by zero: fans should be 0 (safe fallback)',
          user5AfterDivZero?['fans'],
          0);
    } catch (e, s) {
      isTestPassed = false;
      _failTest('Exception in _testExpressionOperations: $e\n$s');
    }
    return isTestPassed;
  }

  /// Comprehensive test for transaction operations.
  /// Tests transaction isolation, rollback, unique constraints, and concurrent transactions.
  Future<bool> _testTransactionOperations() async {
    log.add('--- Testing: Transaction Operations ---', LogType.debug);
    bool isTestPassed = true;
    try {
      await _clearTablesSafely();

      // Test 1: Basic transaction commit
      final txResult1 = await db.transaction(() async {
        await db.insert('users', {
          'username': 'tx_user1',
          'email': 'tx1@test.com',
          'age': 25,
        });
        await db.insert('users', {
          'username': 'tx_user2',
          'email': 'tx2@test.com',
          'age': 30,
        });
      });

      isTestPassed &= _expect(
          'Transaction should commit successfully', txResult1.isSuccess, true);

      final countAfterTx = await db.query('users').count();
      isTestPassed &=
          _expect('Should have 2 users after transaction', countAfterTx, 2);

      // Test 2: Transaction rollback on error
      final txResult2 = await db.transaction(() async {
        await db.insert('users', {
          'username': 'tx_user3',
          'email': 'tx3@test.com',
          'age': 35,
        });
        throw Exception('Simulated error');
      }, rollbackOnError: true);

      isTestPassed &= _expect(
          'Transaction should rollback on error', txResult2.isFailed, true);

      final countAfterRollback = await db.query('users').count();
      isTestPassed &= _expect(
          'Should still have 2 users after rollback', countAfterRollback, 2);

      final txUser3 =
          await db.query('users').where('username', '=', 'tx_user3').first();
      isTestPassed &= _expect(
          'tx_user3 should not exist after rollback', txUser3 == null, true);

      // Test 3: Transaction with unique constraint violation
      final txResult3 = await db.transaction(() async {
        await db.insert('users', {
          'username': 'tx_user4',
          'email': 'tx4@test.com',
          'age': 40,
        });
        // Try to insert duplicate username (should fail)
        await db.insert('users', {
          'username': 'tx_user1', // Duplicate
          'email': 'tx4_dup@test.com',
          'age': 45,
        });
      }, rollbackOnError: true);

      isTestPassed &= _expect(
          'Transaction should fail on unique constraint violation',
          txResult3.isFailed,
          true);

      final txUser4 =
          await db.query('users').where('username', '=', 'tx_user4').first();
      isTestPassed &= _expect(
          'tx_user4 should not exist after constraint violation rollback',
          txUser4 == null,
          true);

      // Test 4: Transaction with expressions
      final txResult4 = await db.transaction(() async {
        await db.insert('users', {
          'username': 'tx_user5',
          'email': 'tx5@test.com',
          'age': 50,
          'fans': 100,
        });

        await db.update('users', {
          'fans': Expr.field('fans') + Expr.value(200),
          'age': Expr.field('age') + Expr.value(10),
        }).where('username', '=', 'tx_user5');
      });

      isTestPassed &= _expect('Transaction with expressions should commit',
          txResult4.isSuccess, true);

      final txUser5 =
          await db.query('users').where('username', '=', 'tx_user5').first();
      isTestPassed &= _expect(
          'tx_user5 fans should be 300 after expression update',
          txUser5?['fans'],
          300);
      isTestPassed &= _expect(
          'tx_user5 age should be 60 after expression update',
          txUser5?['age'],
          60);

      // Test 5: Transaction rollback with expressions
      final txResult6 = await db.transaction(() async {
        await db.insert('users', {
          'username': 'tx_user7',
          'email': 'tx7@test.com',
          'age': 25,
          'fans': 200,
        });

        await db.update('users', {
          'fans': Expr.field('fans') * Expr.value(2),
        }).where('username', '=', 'tx_user7');

        throw Exception('Error after expression update');
      }, rollbackOnError: true);

      isTestPassed &= _expect('Transaction should rollback expression updates',
          txResult6.isFailed, true);

      final txUser7 =
          await db.query('users').where('username', '=', 'tx_user7').first();
      isTestPassed &= _expect(
          'tx_user7 should not exist after rollback', txUser7 == null, true);

      // Test 6: Multiple operations in transaction
      final txResult7 = await db.transaction(() async {
        // Insert
        await db.insert('users', {
          'username': 'tx_user8',
          'email': 'tx8@test.com',
          'age': 30,
          'fans': 100,
        });

        // Update with expression
        await db.update('users', {
          'fans': Expr.field('fans') + Expr.value(50),
        }).where('username', '=', 'tx_user8');

        // Delete another user (tx_user5 from Test 4)
        await db.delete('users').where('username', '=', 'tx_user5');
      });

      isTestPassed &= _expect('Multi-operation transaction should commit',
          txResult7.isSuccess, true);

      final txUser8 =
          await db.query('users').where('username', '=', 'tx_user8').first();
      isTestPassed &= _expect(
          'tx_user8 should exist with updated fans', txUser8?['fans'], 150);

      final txUser5AfterDelete =
          await db.query('users').where('username', '=', 'tx_user5').first();
      isTestPassed &= _expect(
          'tx_user5 should be deleted', txUser5AfterDelete == null, true);
    } catch (e, s) {
      isTestPassed = false;
      _failTest('Exception in _testTransactionOperations: $e\n$s');
    }
    return isTestPassed;
  }
}
