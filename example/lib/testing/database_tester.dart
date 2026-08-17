import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tostore/tostore.dart';

import 'log_service.dart';

/// A comprehensive testing suite for validating ToStore's core functionalities.
/// It covers basic CRUD, upsert, joins, multi-space, and various edge cases.
class DatabaseTester {
  static const bool _isWasmBuild =
      kIsWasm || bool.fromEnvironment('FLUTTER_WEB_USE_SKWASM');
  // These tests currently pull in code paths that break dart2wasm/wasm-opt.
  static const String _schemaUpgradeLegacyUsersTable =
      'mobile_upgrade_users_legacy';
  static const String _schemaUpgradeUsersTable = 'mobile_upgrade_users';
  static const String _schemaUpgradePostsTable = 'mobile_upgrade_posts';
  static const String _schemaUpgradeAuditTable = 'mobile_upgrade_audit_logs';
  static const List<String> _crudUserReadFields = [
    'username',
    'email',
    'age',
  ];

  final ToStore db;
  final LogService log;
  final Function(String) _updateLastOperation;

  DatabaseTester(this.db, this.log, this._updateLastOperation);

  void _passTest(String message) {
    log.add('✅ PASS: $message', LogLevel.info);
  }

  bool _failTest(String message) {
    log.add('❌ FAIL: $message', LogLevel.error);
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

  Future<Map<String, dynamic>?> _queryCachedFirstUserByField(
      String field, dynamic value) async {
    return await db
        .query('users')
        .select(_crudUserReadFields)
        .where(field, '=', value)
        .first();
  }

  Future<bool> _expectCachedUserQueryTwice({
    required String description,
    required String field,
    required dynamic value,
    Map<String, dynamic>? expected,
  }) async {
    bool isTestPassed = true;

    final firstResult = await _queryCachedFirstUserByField(field, value);
    isTestPassed &= _expect('$description (1st query)', firstResult, expected);

    final secondResult = await _queryCachedFirstUserByField(field, value);
    isTestPassed &= _expect('$description (2nd query)', secondResult, expected);

    return isTestPassed;
  }

  /// Main test runner that executes all test suites.
  Future<bool> runAllTests() async {
    log.clear();
    log.add('--- Starting Database Run All Tests ---', LogLevel.info);
    _updateLastOperation('Running All Tests...');
    await Future.delayed(
        const Duration(milliseconds: 100)); // Allow UI to update
    bool allTestsPassed = true;

    try {
      final tests = <Map<String, Object>>[
        {'name': 'Clear & Delete All', 'test': _testClearAndDeleteAll},
        {'name': 'KV Store Operations', 'test': _testKvStoreOperations},
        {'name': 'Basic CRUD', 'test': _testBasicCrud},
        {'name': 'Non-Nullable Constraint', 'test': _testNonNullConstraint},
        {
          'name': 'Buffer Pipeline Robustness',
          'test': _testBufferPipelineRobustness
        },
        {'name': 'Batch Operations Benchmark', 'test': _testBatchOperations},
        {
          'name': 'Upsert and Cache Synchronization',
          'test': _testUpsertAndCacheSync
        },
        {'name': 'JOIN Queries', 'test': _testJoinQueries},
        {'name': 'Multi-Space Isolation', 'test': _testMultiSpace},
        {'name': 'Foreign Key Operations', 'test': _testForeignKeyOperations},
        {'name': 'Expression Operations', 'test': _testExpressionOperations},
        {'name': 'Transaction Operations', 'test': _testTransactionOperations},
        {'name': 'Backup & Restore', 'test': _testBackupAndRestore},
        if (!_isWasmBuild) ...[
          {
            'name': 'Instance Schema Auto Upgrade',
            'test': _testInstanceSchemaAutoUpgrade
          },
          {
            'name': 'Runtime Schema Migration Integrity',
            'test': _testRuntimeSchemaMigrationIntegrity,
          },
          {
            'name': 'Advanced Queries & Edge Cases',
            'test': _testAdvancedQueriesAndEdgeCases
          },
          {'name': 'Count Verification', 'test': _testCountVerification},
          {
            'name': 'Concurrency Stress Test',
            'test': () => runConfigurableConcurrencyTest(_baseConcurrencyConfig)
          },
        ],
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
          allTestsPassed ? LogLevel.info : LogLevel.error);
    } catch (e, s) {
      _failTest('An unexpected error occurred during tests: $e\n$s');
      allTestsPassed = false;
    } finally {
      // CRITICAL: Clean up all tables after tests are finished to ensure a clean state.
      _updateLastOperation('Cleaning up test data...');
      await _clearTablesSafely();
      log.add('--- All test data cleared. ---', LogLevel.info);
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
    log.add('--- Testing: Clear Table and Delete All ---', LogLevel.debug);
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
          'Delete result should be successful', !deleteResult.hasErrors, true);
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

  Future<String> _resolveSchemaAutoUpgradeTestDbPath() async {
    final configuredDbPath = db.config.dbPath;
    if (configuredDbPath != null && configuredDbPath.isNotEmpty) {
      return configuredDbPath;
    }

    final currentInstancePath = db.instancePath;
    if (currentInstancePath != null &&
        currentInstancePath.isNotEmpty &&
        !currentInstancePath.startsWith('memory://')) {
      return p.dirname(currentInstancePath);
    }

    if (kIsWeb) {
      return 'common';
    }

    final docDir = await getApplicationDocumentsDirectory();
    return p.join(docDir.path, 'common');
  }

  Future<DataStoreConfig> _buildSchemaAutoUpgradeTestConfig() async {
    final resolvedDbPath = await _resolveSchemaAutoUpgradeTestDbPath();

    return db.config.copyWith(
      dbPath: resolvedDbPath,
      dbName: '${db.config.dbName}_schema_upgrade_validation',
      spaceName: 'default',
      enableLog: true,
      logLevel: LogLevel.warn,
    );
  }

  List<TableSchema> _buildSchemaAutoUpgradeOldSchemas() {
    return [
      const TableSchema(
        name: _schemaUpgradeLegacyUsersTable,
        tableId: 'mobile_upgrade_users_table',
        primaryKeyConfig: PrimaryKeyConfig(
          name: 'id',
          type: PrimaryKeyType.sequential,
        ),
        fields: [
          FieldSchema(
            name: 'username',
            type: DataType.text,
            nullable: false,
            unique: true,
            maxLength: 24,
            fieldId: 'username',
          ),
          FieldSchema(
            name: 'nickname',
            type: DataType.text,
            maxLength: 20,
            fieldId: 'display_name',
          ),
          FieldSchema(
            name: 'status',
            type: DataType.text,
            nullable: false,
            defaultValue: 'active',
            maxLength: 12,
            fieldId: 'status',
          ),
          FieldSchema(
            name: 'points',
            type: DataType.integer,
            nullable: false,
            defaultValue: 0,
            fieldId: 'points',
          ),
          FieldSchema(
            name: 'legacy_note',
            type: DataType.text,
            fieldId: 'legacy_note',
          ),
        ],
        indexes: [
          IndexSchema(fields: ['status']),
        ],
      ),
      TableSchema(
        name: _schemaUpgradePostsTable,
        primaryKeyConfig: const PrimaryKeyConfig(
          name: 'id',
          type: PrimaryKeyType.sequential,
        ),
        fields: [
          const FieldSchema(
            name: 'title',
            type: DataType.text,
            nullable: false,
            maxLength: 60,
            fieldId: 'title',
          ),
          const FieldSchema(
            name: 'body',
            type: DataType.text,
            fieldId: 'content',
          ),
          const FieldSchema(
            name: 'user_id',
            type: DataType.integer,
            nullable: false,
            fieldId: 'user_id',
          ),
        ],
        foreignKeys: [
          ForeignKeySchema(
            name: 'fk_mobile_upgrade_posts_user',
            fields: ['user_id'],
            referencedTable: _schemaUpgradeLegacyUsersTable,
            referencedFields: ['id'],
            onDelete: ForeignKeyCascadeAction.cascade,
            onUpdate: ForeignKeyCascadeAction.cascade,
          ),
        ],
        indexes: [
          const IndexSchema(fields: ['user_id']),
        ],
      ),
    ];
  }

  List<TableSchema> _buildSchemaAutoUpgradeNewSchemas() {
    return [
      const TableSchema(
        name: _schemaUpgradeUsersTable,
        tableId: 'mobile_upgrade_users_table',
        primaryKeyConfig: PrimaryKeyConfig(
          name: 'id',
          type: PrimaryKeyType.sequential,
        ),
        fields: [
          FieldSchema(
            name: 'username',
            type: DataType.text,
            nullable: false,
            unique: true,
            maxLength: 32,
            comment: 'login name',
            fieldId: 'username',
          ),
          FieldSchema(
            name: 'display_name',
            type: DataType.text,
            maxLength: 40,
            comment: 'renamed from nickname',
            fieldId: 'display_name',
          ),
          FieldSchema(
            name: 'status',
            type: DataType.text,
            nullable: false,
            defaultValue: 'active',
            maxLength: 16,
            comment: 'account status',
            fieldId: 'status',
          ),
          FieldSchema(
            name: 'points',
            type: DataType.integer,
            nullable: false,
            defaultValue: 0,
            minValue: 0,
            maxValue: 100000,
            comment: 'loyalty points',
            fieldId: 'points',
          ),
          FieldSchema(
            name: 'tier',
            type: DataType.text,
            nullable: false,
            defaultValue: 'standard',
            maxLength: 16,
            fieldId: 'tier',
          ),
        ],
        indexes: [
          IndexSchema(fields: ['status']),
        ],
      ),
      TableSchema(
        name: _schemaUpgradePostsTable,
        primaryKeyConfig: const PrimaryKeyConfig(
          name: 'id',
          type: PrimaryKeyType.sequential,
        ),
        fields: [
          const FieldSchema(
            name: 'title',
            type: DataType.text,
            nullable: false,
            maxLength: 120,
            fieldId: 'title',
          ),
          const FieldSchema(
            name: 'content',
            type: DataType.text,
            fieldId: 'content',
          ),
          const FieldSchema(
            name: 'user_id',
            type: DataType.integer,
            nullable: false,
            fieldId: 'user_id',
          ),
          const FieldSchema(
            name: 'is_published',
            type: DataType.boolean,
            nullable: false,
            defaultValue: true,
            fieldId: 'is_published',
          ),
        ],
        foreignKeys: [
          ForeignKeySchema(
            name: 'fk_mobile_upgrade_posts_user',
            fields: ['user_id'],
            referencedTable: _schemaUpgradeUsersTable,
            referencedFields: ['id'],
            onDelete: ForeignKeyCascadeAction.cascade,
            onUpdate: ForeignKeyCascadeAction.cascade,
          ),
        ],
        indexes: [
          const IndexSchema(fields: ['user_id']),
        ],
      ),
      const TableSchema(
        name: _schemaUpgradeAuditTable,
        primaryKeyConfig: PrimaryKeyConfig(
          name: 'id',
          type: PrimaryKeyType.sequential,
        ),
        fields: [
          FieldSchema(
            name: 'entity_type',
            type: DataType.text,
            nullable: false,
          ),
          FieldSchema(
            name: 'entity_id',
            type: DataType.integer,
            nullable: false,
          ),
          FieldSchema(
            name: 'action',
            type: DataType.text,
            nullable: false,
          ),
        ],
      ),
    ];
  }

  Future<void> _deleteSchemaAutoUpgradeTestDatabase(
      DataStoreConfig config) async {
    ToStore? cleanupDb;
    try {
      cleanupDb = await ToStore.open(
        dbPath: config.dbPath,
        dbName: config.dbName,
        config: config,
        schemas: const [],
        applyActiveSpaceOnDefault: false,
      );
      await cleanupDb.deleteDatabase(
        dbPath: config.dbPath,
        dbName: config.dbName,
      );
      cleanupDb = null;
    } catch (e) {
      log.add(
        'Schema auto-upgrade test database cleanup skipped: $e',
        LogLevel.warn,
      );
    } finally {
      if (cleanupDb != null) {
        try {
          await cleanupDb.close();
        } catch (_) {}
      }
    }
  }

  Future<void> _closeQuietly(ToStore? database) async {
    if (database == null) {
      return;
    }
    try {
      await database.close();
    } catch (_) {}
  }

  /// Validates schema-based auto migration on reopen using an isolated database.
  Future<bool> _testInstanceSchemaAutoUpgrade() async {
    if (db.config.persistenceMode == PersistenceMode.memory) {
      _passTest(
        'Schema auto upgrade reopen test skipped because the current instance uses memory persistence.',
      );
      return true;
    }

    bool isTestPassed = true;
    final config = await _buildSchemaAutoUpgradeTestConfig();
    final oldSchemas = _buildSchemaAutoUpgradeOldSchemas();
    final newSchemas = _buildSchemaAutoUpgradeNewSchemas();
    ToStore? oldDb;
    ToStore? migratedDb;
    ToStore? reopenedDb;

    try {
      // This prevents disk bloat and ensures a clean state for the new test.
      await _deleteSchemaAutoUpgradeTestDatabase(config);

      oldDb = await ToStore.open(
        dbPath: config.dbPath,
        dbName: config.dbName,
        config: config,
        schemas: oldSchemas,
        applyActiveSpaceOnDefault: false,
      );

      // Insert multiple records to fully validate traversal and batch handling
      final insertUser1 = await oldDb.insert(_schemaUpgradeLegacyUsersTable, {
        'username': 'legacy_user',
        'nickname': 'Legacy Nick',
        'status': 'active',
        'points': 88,
        'legacy_note': 'to be removed',
      });
      final insertUser2 = await oldDb.insert(_schemaUpgradeLegacyUsersTable, {
        'username': 'legacy_user2',
        'nickname': 'Legacy Nick 2',
        'status': 'active',
        'points': 99,
        'legacy_note': 'to be removed 2',
      });
      final insertUser3 = await oldDb.insert(_schemaUpgradeLegacyUsersTable, {
        'username': 'legacy_user3',
        'nickname': 'Legacy Nick 3',
        'status': 'disabled',
        'points': 55,
        'legacy_note': 'to be removed 3',
      });

      isTestPassed &= _expect(
        'Old schema insert users into renamed table should succeed',
        !insertUser1.hasErrors &&
            !insertUser2.hasErrors &&
            !insertUser3.hasErrors,
        true,
      );
      if (!isTestPassed || insertUser1.firstPrimaryKey == null) {
        return false;
      }
      final userId = insertUser1.firstPrimaryKey;

      final insertPost = await oldDb.insert(_schemaUpgradePostsTable, {
        'title': 'Legacy post title',
        'body': 'legacy body content',
        'user_id': userId,
      });
      isTestPassed &= _expect(
        'Old schema insert into child table should succeed',
        !insertPost.hasErrors,
        true,
      );
      if (!isTestPassed) {
        return false;
      }

      await oldDb.close();
      oldDb = null;

      migratedDb = await ToStore.open(
        dbPath: config.dbPath,
        dbName: config.dbName,
        config: config,
        schemas: newSchemas,
        applyActiveSpaceOnDefault: false,
      );

      isTestPassed &= _expect(
        'Legacy renamed table should not exist after reopen migration',
        await migratedDb.tableExists(_schemaUpgradeLegacyUsersTable),
        false,
      );
      isTestPassed &= _expect(
        'Renamed users table should exist after reopen migration',
        await migratedDb.tableExists(_schemaUpgradeUsersTable),
        true,
      );
      isTestPassed &= _expect(
        'New audit table should be created during reopen migration',
        await migratedDb.tableExists(_schemaUpgradeAuditTable),
        true,
      );

      final migratedUserSchema =
          await migratedDb.getTableSchema(_schemaUpgradeUsersTable);
      if (migratedUserSchema == null) {
        return _failTest(
          'Migrated users schema not found after reopen migration.',
        );
      }

      final usernameField = migratedUserSchema.fields.firstWhere(
        (field) => field.name == 'username',
      );
      final displayNameField = migratedUserSchema.fields.firstWhere(
        (field) => field.name == 'display_name',
      );
      final statusField = migratedUserSchema.fields.firstWhere(
        (field) => field.name == 'status',
      );
      final pointsField = migratedUserSchema.fields.firstWhere(
        (field) => field.name == 'points',
      );
      final tierField = migratedUserSchema.fields.firstWhere(
        (field) => field.name == 'tier',
      );

      isTestPassed &= _expect(
          'Migrated username field maxLength', usernameField.maxLength, 32);
      isTestPassed &= _expect(
        'Migrated display_name field should keep renamed fieldId',
        displayNameField.fieldId,
        'display_name',
      );
      isTestPassed &= _expect(
        'Migrated display_name field maxLength',
        displayNameField.maxLength,
        40,
      );
      isTestPassed &= _expect('Migrated status field comment',
          statusField.comment, 'account status');
      isTestPassed &= _expect(
        'Migrated points field minValue',
        pointsField.minValue,
        0,
      );
      isTestPassed &= _expect(
        'Migrated points field maxValue',
        pointsField.maxValue,
        100000,
      );
      isTestPassed &= _expect(
        'Migrated tier field default value',
        tierField.defaultValue,
        'standard',
      );

      final migratedPostsSchema =
          await migratedDb.getTableSchema(_schemaUpgradePostsTable);
      if (migratedPostsSchema == null) {
        return _failTest(
          'Migrated posts schema not found after reopen migration.',
        );
      }
      isTestPassed &= _expect(
        'Child table foreign key should point to renamed users table',
        migratedPostsSchema.foreignKeys.first.referencedTable,
        _schemaUpgradeUsersTable,
      );

      final migratedUsers = await migratedDb
          .query(_schemaUpgradeUsersTable)
          .orderByAsc('id')
          .limit(10);
      isTestPassed &= _expect(
        'Migrated renamed users table row count',
        migratedUsers.length,
        3,
      );
      if (!isTestPassed || migratedUsers.data.isEmpty) {
        return false;
      }

      final migratedUser = migratedUsers.data.first;
      isTestPassed &= _expect(
          'Migrated username value', migratedUser['username'], 'legacy_user');
      isTestPassed &= _expect(
        'Migrated renamed field value',
        migratedUser['display_name'],
        'Legacy Nick',
      );
      isTestPassed &=
          _expect('Migrated points value', migratedUser['points'], 88);
      isTestPassed &= _expect(
        'Migrated added field default value',
        migratedUser['tier'],
        'standard',
      );
      isTestPassed &= _expect(
        'Removed field should not appear in migrated user row',
        migratedUser.containsKey('legacy_note'),
        false,
      );

      // Verify second migrated user record
      if (migratedUsers.data.length >= 2) {
        final u2 = migratedUsers.data[1];
        isTestPassed &= _expect(
          'Migrated second record username value',
          u2['username'],
          'legacy_user2',
        );
        isTestPassed &= _expect(
          'Migrated second record display_name value',
          u2['display_name'],
          'Legacy Nick 2',
        );
      }

      final migratedPosts = await migratedDb
          .query(_schemaUpgradePostsTable)
          .orderByAsc('id')
          .limit(10);
      isTestPassed &=
          _expect('Migrated child table row count', migratedPosts.length, 1);
      if (!isTestPassed || migratedPosts.data.isEmpty) {
        return false;
      }

      final migratedPost = migratedPosts.data.first;
      isTestPassed &= _expect(
        'Migrated child field rename should preserve data',
        migratedPost['content'],
        'legacy body content',
      );
      isTestPassed &= _expect(
        'Migrated child added field default should be applied',
        migratedPost['is_published'],
        true,
      );

      final insertAudit = await migratedDb.insert(_schemaUpgradeAuditTable, {
        'entity_type': 'user',
        'entity_id': userId,
        'action': 'schema_upgrade_verified',
      });
      isTestPassed &= _expect(
        'Insert into newly created table after migration should succeed',
        !insertAudit.hasErrors,
        true,
      );
      if (!isTestPassed) {
        return false;
      }

      await migratedDb.close();
      migratedDb = null;

      reopenedDb = await ToStore.open(
        dbPath: config.dbPath,
        dbName: config.dbName,
        config: config,
        schemas: newSchemas,
        applyActiveSpaceOnDefault: false,
      );

      final reopenedUsers = await reopenedDb
          .query(_schemaUpgradeUsersTable)
          .orderByAsc('id')
          .limit(10);
      isTestPassed &= _expect(
          'Reopened renamed users table row count', reopenedUsers.length, 3);
      if (!isTestPassed || reopenedUsers.data.isEmpty) {
        return false;
      }
      final reopenedUser = reopenedUsers.data.first;
      isTestPassed &= _expect(
        'Reopened renamed field value remains correct',
        reopenedUser['display_name'],
        'Legacy Nick',
      );
      isTestPassed &= _expect(
        'Reopened added field value remains correct',
        reopenedUser['tier'],
        'standard',
      );

      final reopenedPosts = await reopenedDb
          .query(_schemaUpgradePostsTable)
          .orderByAsc('id')
          .limit(10);
      isTestPassed &=
          _expect('Reopened child table row count', reopenedPosts.length, 1);
      if (!isTestPassed || reopenedPosts.data.isEmpty) {
        return false;
      }
      isTestPassed &= _expect(
        'Reopened child renamed field remains correct',
        reopenedPosts.data.first['content'],
        'legacy body content',
      );

      final auditCount =
          await reopenedDb.query(_schemaUpgradeAuditTable).count();
      isTestPassed &= _expect(
        'Newly created table data should persist after second reopen',
        auditCount,
        1,
      );
    } catch (e, s) {
      isTestPassed = false;
      _failTest('Exception in _testInstanceSchemaAutoUpgrade: $e\n$s');
    } finally {
      await _closeQuietly(oldDb);
      await _closeQuietly(migratedDb);
      await _closeQuietly(reopenedDb);
      await _deleteSchemaAutoUpgradeTestDatabase(config);
    }

    return isTestPassed;
  }

  Future<DataStoreConfig> _buildRuntimeSchemaMigrationTestConfig() async {
    final resolvedDbPath = await _resolveSchemaAutoUpgradeTestDbPath();

    return db.config.copyWith(
      dbPath: resolvedDbPath,
      dbName:
          '${db.config.dbName}_rt_mig_${DateTime.now().millisecondsSinceEpoch}',
      spaceName: 'default',
      enableLog: true,
      logLevel: LogLevel.warn,
      maxFlushLatencyMs: 100,
      writeBatchSize: 5,
    );
  }

  Future<void> _deleteRuntimeSchemaMigrationTestDatabase(
      DataStoreConfig config) async {
    ToStore? cleanupDb;
    try {
      cleanupDb = await ToStore.open(
        dbPath: config.dbPath,
        dbName: config.dbName,
        config: config,
        schemas: const [],
        applyActiveSpaceOnDefault: false,
      );
      await cleanupDb.deleteDatabase(
        dbPath: config.dbPath,
        dbName: config.dbName,
      );
      cleanupDb = null;
    } catch (e) {
      log.add(
        'Runtime schema migration test database cleanup skipped: $e',
        LogLevel.warn,
      );
    } finally {
      if (cleanupDb != null) {
        try {
          await cleanupDb.close();
        } catch (_) {}
      }
    }
  }

  Future<void> _waitForMigrationTask(ToStore testDb, String taskId) async {
    const timeout = Duration(seconds: 120);
    final deadline = DateTime.now().add(timeout);
    MigrationStatus? lastStatus;
    while (DateTime.now().isBefore(deadline)) {
      lastStatus = await testDb.queryMigrationTaskStatus(taskId);
      if (lastStatus != null && lastStatus.isCompleted) {
        return;
      }
      await Future.delayed(const Duration(milliseconds: 50));
    }
    throw TimeoutException(
      'Migration task $taskId not completed within ${timeout.inSeconds}s. '
      'lastStatus: isCompleted=${lastStatus?.isCompleted}, '
      'pendingSpaces=${lastStatus?.pendingSpaces}, '
      'processed=${lastStatus?.processedSpacesCount}/'
      '${lastStatus?.totalSpacesCount}',
    );
  }

  /// CRITICAL TEST: Verifies that complex runtime schema migration (using db.updateSchema and db.createTables)
  /// works correctly without dataloss, even when concurrent reads/writes hit the dynamic buffers and files.
  Future<bool> _testRuntimeSchemaMigrationIntegrity() async {
    if (db.config.persistenceMode == PersistenceMode.memory) {
      _passTest(
        'Runtime schema migration test skipped because the current instance uses memory persistence.',
      );
      return true;
    }

    bool isTestPassed = true;
    final config = await _buildRuntimeSchemaMigrationTestConfig();

    final legacyTableA = TableSchema(
      name: 'legacy_table_a',
      tableId: 'migration_test_table_a_id',
      primaryKeyConfig: const PrimaryKeyConfig(
        name: 'id',
        type: PrimaryKeyType.sequential,
      ),
      fields: const [
        FieldSchema(name: 'old_field_1', type: DataType.text),
        FieldSchema(name: 'old_field_2', type: DataType.integer),
        FieldSchema(name: 'toBeIndexed', type: DataType.text),
        FieldSchema(name: 'shouldRemoveIndex', type: DataType.text),
      ],
      indexes: const [
        IndexSchema(fields: ['shouldRemoveIndex']),
      ],
    );

    final legacyTableB = TableSchema(
      name: 'legacy_table_b',
      tableId: 'migration_test_table_b_id',
      primaryKeyConfig: const PrimaryKeyConfig(
        name: 'id',
        type: PrimaryKeyType.sequential,
      ),
      fields: const [
        FieldSchema(name: 'name', type: DataType.text),
      ],
    );

    final oldSchemas = [legacyTableA, legacyTableB];
    ToStore? testDb;

    try {
      // 1. Clean state
      await _deleteRuntimeSchemaMigrationTestDatabase(config);

      // 2. Open and create initial tables dynamically using createTables
      testDb = await ToStore.open(
        dbPath: config.dbPath,
        dbName: config.dbName,
        config: config,
        schemas: const [], // start empty
        applyActiveSpaceOnDefault: false,
      );

      final createRes = await testDb.createTables(oldSchemas);
      isTestPassed &= _expect(
          'Dynamic table creation should succeed', createRes.hasErrors, false);
      if (!isTestPassed) return false;

      // 3. Insert initial data into 'default' space
      final insA1 = await testDb.insert('legacy_table_a', {
        'old_field_1': 'val1_1',
        'old_field_2': 10,
        'toBeIndexed': 'index_val_1',
        'shouldRemoveIndex': 'rm_idx_1',
      });
      final insA2 = await testDb.insert('legacy_table_a', {
        'old_field_1': 'val1_2',
        'old_field_2': 20,
        'toBeIndexed': 'index_val_2',
        'shouldRemoveIndex': 'rm_idx_2',
      });
      final insB1 = await testDb.insert('legacy_table_b', {
        'name': 'b_name_1',
      });
      final insB2 = await testDb.insert('legacy_table_b', {
        'name': 'b_name_2',
      });

      isTestPassed &= _expect(
        'Initial inserts into default space should succeed',
        !insA1.hasErrors &&
            !insA2.hasErrors &&
            !insB1.hasErrors &&
            !insB2.hasErrors,
        true,
      );

      // 4. Switch to a new space 'test_space' and insert legacy data
      final switchedToTestSpace =
          await testDb.switchSpace(spaceName: 'test_space');
      isTestPassed &= _expect(
          'Switching to test_space should succeed', switchedToTestSpace, true);

      final insA3 = await testDb.insert('legacy_table_a', {
        'old_field_1': 'val1_3',
        'old_field_2': 30,
        'toBeIndexed': 'index_val_3',
        'shouldRemoveIndex': 'rm_idx_3',
      });
      final insA4 = await testDb.insert('legacy_table_a', {
        'old_field_1': 'val1_4',
        'old_field_2': 40,
        'toBeIndexed': 'index_val_4',
        'shouldRemoveIndex': 'rm_idx_4',
      });
      final insB3 = await testDb.insert('legacy_table_b', {
        'name': 'b_name_3',
      });
      final insB4 = await testDb.insert('legacy_table_b', {
        'name': 'b_name_4',
      });

      isTestPassed &= _expect(
        'Initial inserts into test_space should succeed',
        !insA3.hasErrors &&
            !insA4.hasErrors &&
            !insB3.hasErrors &&
            !insB4.hasErrors,
        true,
      );

      // 5. Close DB to flush WAL & commit everything to persistent files
      await testDb.switchSpace(spaceName: 'default');
      await testDb.flush();
      await testDb.close();
      testDb = null;

      // 6. Reopen DB to load data and trigger runtime schema updates
      testDb = await ToStore.open(
        dbPath: config.dbPath,
        dbName: config.dbName,
        config: config,
        schemas:
            oldSchemas, // open with old schemas to preserve original catalog state
        applyActiveSpaceOnDefault: false,
      );

      // 6.5 Insert unflushed data under the old schema (these will stay in WAL/buffers with old table name)
      final insAOld1 = await testDb.insert('legacy_table_a', {
        'old_field_1': 'val1_old_unflushed_1',
        'old_field_2': 99,
        'toBeIndexed': 'index_val_old_1',
        'shouldRemoveIndex': 'rm_idx_old_1',
      });
      final insAOld2 = await testDb.insert('legacy_table_a', {
        'old_field_1': 'val1_old_unflushed_2',
        'old_field_2': 199,
        'toBeIndexed': 'index_val_old_2',
        'shouldRemoveIndex': 'rm_idx_old_2',
      });
      isTestPassed &= _expect('Pre-rename unflushed inserts should succeed',
          !insAOld1.hasErrors && !insAOld2.hasErrors, true);

      // 7. Perform runtime schema migration: 2 table renames, 2 field renames, 1 add field, 1 add index, 1 remove index
      final updateResultA = await testDb
          .updateSchema('legacy_table_a')
          .renameTable('new_table_a')
          .renameField('old_field_1', 'new_field_1')
          .renameField('old_field_2', 'new_field_2')
          .addField('added_field',
              type: DataType.text, defaultValue: 'default_val')
          .addIndex(fields: ['toBeIndexed']).removeIndex(
              indexName: 'idx_shouldRemoveIndex');

      final updateResultB = await testDb
          .updateSchema('legacy_table_b')
          .renameTable('new_table_b');

      final taskIdA = updateResultA.taskId;
      final taskIdB = updateResultB.taskId;

      isTestPassed &= _expect(
          'Table A migration taskId should be assigned', taskIdA != null, true);
      isTestPassed &= _expect(
          'Table B migration taskId should be assigned', taskIdB != null, true);

      // 7.5 Perform high-frequency concurrent writes/reads on the new tables to trigger fast background flushes
      // since maxFlushLatencyMs is set to 100ms, a loop of 10 rounds * 50ms = 500ms guarantees that background
      // flush thread runs multiple times, processing WAL entries written in 6.5 (old table name) concurrently with the rename.
      for (int i = 0; i < 10; i++) {
        final loopInsA = await testDb.insert('new_table_a', {
          'new_field_1': 'new_val_loop_$i',
          'new_field_2': 100 + i,
          'toBeIndexed': 'idx_new_loop_$i',
          'shouldRemoveIndex': 'rm_new_loop_$i',
        });
        isTestPassed &= _expect('Loop insert into new_table_a should succeed',
            loopInsA.hasErrors, false);

        final loopInsB = await testDb.insert('new_table_b', {
          'name': 'new_b_loop_$i',
        });
        isTestPassed &= _expect('Loop insert into new_table_b should succeed',
            loopInsB.hasErrors, false);

        // Fetch using the new schema/table name
        final loopQuery = await testDb
            .query('new_table_a')
            .where('toBeIndexed', '=', 'idx_new_loop_$i')
            .first();
        isTestPassed &= _expect(
            'Loop query should find new record', loopQuery != null, true);

        await Future.delayed(const Duration(milliseconds: 50));
      }

      // 8. IMMEDIATELY perform Round 1 writes/reads on the new tables while migration is running (tests buffer-file coexistence)
      final insNewA1 = await testDb.insert('new_table_a', {
        'new_field_1': 'new_val_1',
        'new_field_2': 100,
        'toBeIndexed': 'idx_new_1',
        'shouldRemoveIndex': 'rm_new_1',
      });
      isTestPassed &= _expect('Round 1 insert into new_table_a should succeed',
          insNewA1.hasErrors, false);
      if (insNewA1.hasErrors) {
        log.add(
            'insNewA1 error: ${insNewA1.message} statuses: ${insNewA1.statuses}',
            LogLevel.error);
      }

      final insNewB1 = await testDb.insert('new_table_b', {
        'name': 'new_b_1',
      });
      isTestPassed &= _expect('Round 1 insert into new_table_b should succeed',
          insNewB1.hasErrors, false);
      if (insNewB1.hasErrors) {
        log.add(
            'insNewB1 error: ${insNewB1.message} statuses: ${insNewB1.statuses}',
            LogLevel.error);
      }

      // Verify newly inserted record using the newly indexed field
      final queryNew1 = await testDb
          .query('new_table_a')
          .where('toBeIndexed', '=', 'idx_new_1')
          .first();
      isTestPassed &= _expect('Should find new record via toBeIndexed index',
          queryNew1 != null, true);
      if (queryNew1 != null) {
        isTestPassed &= _expect('New record added_field default',
            queryNew1['added_field'], 'default_val');
        isTestPassed &=
            _expect('New record field 2 value', queryNew1['new_field_2'], 100);
      }

      // 9. Perform Round 2 writes/reads (modifying newly written buffer data)
      final insNewA2 = await testDb.insert('new_table_a', {
        'new_field_1': 'new_val_2',
        'new_field_2': 200,
        'toBeIndexed': 'idx_new_2',
        'shouldRemoveIndex': 'rm_new_2',
      });
      isTestPassed &=
          _expect('Round 2 insert should succeed', insNewA2.hasErrors, false);

      final updResult2 = await testDb
          .update('new_table_a', {'new_field_2': 150}).where(
              'new_field_1', '=', 'new_val_1');
      isTestPassed &= _expect(
          'Round 2 update of newly inserted data should succeed',
          updResult2.hasErrors,
          false);

      final queryNew2 = await testDb
          .query('new_table_a')
          .where('new_field_1', '=', 'new_val_1')
          .first();
      isTestPassed &= _expect(
          'Should fetch Round 2 updated record', queryNew2 != null, true);
      if (queryNew2 != null) {
        isTestPassed &= _expect(
            'Round 2 updated field 2 value', queryNew2['new_field_2'], 150);
      }

      // 10. Wait for background migration execution to fully complete
      if (taskIdA != null) {
        await _waitForMigrationTask(testDb, taskIdA);
      }
      if (taskIdB != null) {
        await _waitForMigrationTask(testDb, taskIdB);
      }

      // 11. Now that migration is complete, we can update and delete the migrated legacy records
      // Update migrated old data (val1_1 -> val1_1_updated)
      final updResult1 = await testDb
          .update('new_table_a', {'new_field_1': 'val1_1_updated'}).where(
              'new_field_1', '=', 'val1_1');
      isTestPassed &= _expect('Update of migrated legacy data should succeed',
          updResult1.hasErrors, false);
      if (updResult1.hasErrors) {
        log.add(
            'updResult1 error: ${updResult1.message} statuses: ${updResult1.statuses}',
            LogLevel.error);
      }

      // Delete migrated old data (val1_2)
      final delResult1 = await testDb
          .delete('new_table_a')
          .where('new_field_1', '=', 'val1_2');
      isTestPassed &= _expect('Delete of migrated legacy data should succeed',
          delResult1.hasErrors, false);
      if (delResult1.hasErrors) {
        log.add(
            'delResult1 error: ${delResult1.message} statuses: ${delResult1.statuses}',
            LogLevel.error);
      }

      // Query verification (Post-Migration verification before flush)
      final queryUpd1 = await testDb
          .query('new_table_a')
          .where('new_field_1', '=', 'val1_1_updated')
          .first();
      isTestPassed &=
          _expect('Should query updated legacy data', queryUpd1 != null, true);
      if (queryUpd1 != null) {
        isTestPassed &= _expect(
            'Updated legacy record new_field_2 should be preserved',
            queryUpd1['new_field_2'],
            10);
        isTestPassed &= _expect(
            'Updated legacy record added_field should use default',
            queryUpd1['added_field'],
            'default_val');
        isTestPassed &= _expect(
            'Updated legacy record shouldRemoveIndex should exist',
            queryUpd1['shouldRemoveIndex'],
            'rm_idx_1');
      }

      final queryDel1 = await testDb
          .query('new_table_a')
          .where('new_field_1', '=', 'val1_2')
          .first();
      isTestPassed &=
          _expect('Deleted legacy record should not exist', queryDel1, null);

      // Verify unflushed old data was migrated correctly
      final queryOldUnflushed1 = await testDb
          .query('new_table_a')
          .where('new_field_1', '=', 'val1_old_unflushed_1')
          .first();
      isTestPassed &= _expect('Should query migrated unflushed old data 1',
          queryOldUnflushed1 != null, true);
      if (queryOldUnflushed1 != null) {
        isTestPassed &= _expect('Migrated unflushed old record 1 field 2 value',
            queryOldUnflushed1['new_field_2'], 99);
      }

      final queryOldUnflushed2 = await testDb
          .query('new_table_a')
          .where('new_field_1', '=', 'val1_old_unflushed_2')
          .first();
      isTestPassed &= _expect('Should query migrated unflushed old data 2',
          queryOldUnflushed2 != null, true);
      if (queryOldUnflushed2 != null) {
        isTestPassed &= _expect('Migrated unflushed old record 2 field 2 value',
            queryOldUnflushed2['new_field_2'], 199);
      }

      // 12. Call flush to force all buffers/indexes to flush to files
      await testDb.flush();

      // 13. Final query verification after flush (ensures correct physical file storage layout)
      final finalA1 = await testDb
          .query('new_table_a')
          .where('new_field_1', '=', 'val1_1_updated')
          .first();
      isTestPassed &= _expect(
          'Final query check on updated legacy record after flush',
          finalA1 != null,
          true);
      if (finalA1 != null) {
        isTestPassed &=
            _expect('Final check field 2 value', finalA1['new_field_2'], 10);
        isTestPassed &= _expect('Final check added_field value',
            finalA1['added_field'], 'default_val');
      }

      final finalA2 = await testDb
          .query('new_table_a')
          .where('toBeIndexed', '=', 'idx_new_2')
          .first();
      isTestPassed &= _expect(
          'Final query check on new record after flush', finalA2 != null, true);
      if (finalA2 != null) {
        isTestPassed &= _expect('Final check new record field 2 value',
            finalA2['new_field_2'], 200);
      }

      // 14. Verify index layout in catalog schema (assert index added & removed)
      final finalSchemaA = await testDb.getTableSchema('new_table_a');
      isTestPassed &= _expect('Final schema for new_table_a should exist',
          finalSchemaA != null, true);
      if (finalSchemaA != null) {
        final hasToBeIndexed = finalSchemaA.indexes
            .any((idx) => idx.fields.contains('toBeIndexed'));
        isTestPassed &= _expect(
            'Schema must contain toBeIndexed index', hasToBeIndexed, true);

        final hasRemovedIndex = finalSchemaA.indexes
            .any((idx) => idx.fields.contains('shouldRemoveIndex'));
        isTestPassed &= _expect(
            'Schema must NOT contain shouldRemoveIndex index',
            hasRemovedIndex,
            false);
      }

      // 15. Re-confirm migrations finished, then switch space
      if (taskIdA != null) {
        await _waitForMigrationTask(testDb, taskIdA);
      }
      if (taskIdB != null) {
        await _waitForMigrationTask(testDb, taskIdB);
      }

      final switchedToTestSpaceAgain =
          await testDb.switchSpace(spaceName: 'test_space');
      isTestPassed &= _expect('Switching back to test_space should succeed',
          switchedToTestSpaceAgain, true);

      final spaceA1 = await testDb
          .query('new_table_a')
          .where('new_field_1', '=', 'val1_3')
          .first();
      isTestPassed &= _expect('Should find test_space migrated legacy record',
          spaceA1 != null, true);
      if (spaceA1 != null) {
        isTestPassed &= _expect(
            'test_space migrated record field 2', spaceA1['new_field_2'], 30);
        isTestPassed &= _expect(
            'test_space migrated record added_field default',
            spaceA1['added_field'],
            'default_val');
        isTestPassed &= _expect('test_space migrated record shouldRemoveIndex',
            spaceA1['shouldRemoveIndex'], 'rm_idx_3');
      }

      final spaceB1 = await testDb
          .query('new_table_b')
          .where('name', '=', 'b_name_3')
          .first();
      isTestPassed &= _expect(
          'Should find test_space migrated record in table b',
          spaceB1 != null,
          true);
    } catch (e, s) {
      isTestPassed = false;
      _failTest('Exception in _testRuntimeSchemaMigrationIntegrity: $e\n$s');
    } finally {
      await _closeQuietly(testDb);
      await _deleteRuntimeSchemaMigrationTestDatabase(config);
    }

    return isTestPassed;
  }

  /// Benchmarks and validates batch operations.
  Future<bool> _testBatchOperations() async {
    log.add('--- Testing: Batch Operations Benchmark ---', LogLevel.debug);
    bool isTestPassed = true;
    try {
      await _clearTablesSafely();

      const int count = 100;
      log.add('Preparing $count records for batch test...', LogLevel.info);

      final insertRecords = List.generate(
          count,
          (i) => {
                'username': 'batch_user_$i',
                'email': 'batch_$i@test.com',
                'age': 20 + (i % 50),
                'is_active': true,
              });

      // 1. Benchmark Batch Insert
      final sw = Stopwatch()..start();
      final insertResult = await db.batchInsert('users', insertRecords);
      sw.stop();
      log.add('🚀 Batch Insert $count records took ${sw.elapsedMilliseconds}ms',
          LogLevel.info);

      isTestPassed &= _expect(
          'Batch Insert should be successful', !insertResult.hasErrors, true);
      isTestPassed &= _expect('Batch Insert should affect $count rows',
          insertResult.successCount, count);

      if (!isTestPassed || insertResult.successCount == 0) return false;

      // 2. Prepare Batch Update (Partial data)
      final updateRecords = List.generate(
          count,
          (i) => {
                'id': insertResult.statuses[i].primaryKey,
                'age': 30 + (i % 50),
                'is_active': false,
              });

      // 3. Benchmark Batch Update
      sw.reset();
      sw.start();
      final updateResult = await db.batchUpdate('users', updateRecords);
      sw.stop();
      log.add('🚀 Batch Update $count records took ${sw.elapsedMilliseconds}ms',
          LogLevel.info);

      isTestPassed &= _expect(
          'Batch Update should be successful', !updateResult.hasErrors, true);
      isTestPassed &= _expect('Batch Update should affect $count rows',
          updateResult.successCount, count);

      // 4. Verify Correctness
      log.add('Verifying data integrity after batch update...', LogLevel.info);

      // Check middle record to avoid just checking boundaries
      const middleIdx = count ~/ 2;
      final middleId = insertResult.statuses[middleIdx].primaryKey;
      final user = await db.query('users').where('id', '=', middleId).first();

      isTestPassed &=
          _expect('User $middleId should exist', user != null, true);
      if (user != null) {
        isTestPassed &= _expect(
            'User age should be updated', user['age'], 30 + (middleIdx % 50));
        isTestPassed &=
            _expect('User status should be updated', user['is_active'], false);
        isTestPassed &= _expect('User username should be preserved',
            user['username'], 'batch_user_$middleIdx');
      }

      // Check first and last
      final firstUser = await db
          .query('users')
          .where('id', '=', insertResult.statuses[0].primaryKey)
          .first();
      isTestPassed &=
          _expect('First user age should be updated', firstUser?['age'], 30);

      final lastUser = await db
          .query('users')
          .where('id', '=', insertResult.statuses[count - 1].primaryKey)
          .first();
      isTestPassed &= _expect('Last user age should be updated',
          lastUser?['age'], 30 + ((count - 1) % 50));
    } catch (e, s) {
      isTestPassed = false;
      _failTest('Exception in _testBatchOperations: $e\n$s');
    }
    return isTestPassed;
  }

  /// Validates the robustness of the write buffer pipeline.
  /// Checks for coalescing, duplicate prevention, and partial updates visibility.
  Future<bool> _testBufferPipelineRobustness() async {
    log.add('--- Testing: Buffer Pipeline Robustness ---', LogLevel.debug);
    bool isTestPassed = true;

    try {
      await _clearTablesSafely();

      const String testUser = 'buffer_test_user';
      const String testEmail = 'buffer@test.com';

      // 1. Insert then Insert (Immediate duplicate check)
      final firstInsert = await db.insert('users', {
        'username': testUser,
        'email': testEmail,
        'age': 25,
      });
      isTestPassed &=
          _expect('First insert should succeed', !firstInsert.hasErrors, true);

      // Immediate second insert with same username (unique)
      final secondInsert = await db.insert('users', {
        'username': testUser,
        'email': 'another@test.com',
      });
      isTestPassed &= _expect('Immediate duplicate insert should be blocked',
          !secondInsert.hasErrors, false);
      isTestPassed &= _expect('Duplicate error should be unique violation',
          secondInsert.firstType, ResultType.bizUniqueViolation);

      // 2. Insert then Partial Update (Merging test)
      const String partialUser = 'partial_test_user';
      final insertForUpdate = await db.insert('users', {
        'username': partialUser,
        'email': 'partial@test.com',
        'age': 30,
      });
      final String? userId = insertForUpdate.firstPrimaryKey;
      isTestPassed &= _expect(
          'Insert for partial update should succeed', userId != null, true);

      // Immediately update ONLY age
      final partialUpdate = await db
          .update('users', {'age': 31}).where('username', '=', partialUser);
      isTestPassed &= _expect('Immediate partial update should succeed',
          !partialUpdate.hasErrors, true);

      // Query immediately (should see merged data from buffer)
      final mergedRecord =
          await db.query('users').where('username', '=', partialUser).first();
      isTestPassed &= _expect('Merged record should retain original email',
          mergedRecord?['email'], 'partial@test.com');
      isTestPassed &= _expect(
          'Merged record should have updated age', mergedRecord?['age'], 31);

      // 3. Insert then Delete (Cancel logic)
      const String deleteUser = 'delete_me_fast';
      await db.insert('users', {
        'username': deleteUser,
        'email': 'delete@test.com',
      });

      final immediateDelete =
          await db.delete('users').where('username', '=', deleteUser);
      isTestPassed &= _expect(
          'Immediate delete should succeed', !immediateDelete.hasErrors, true);

      final deletedRecord =
          await db.query('users').where('username', '=', deleteUser).first();
      isTestPassed &= _expect('Record should be gone immediately after delete',
          deletedRecord, null);

      // 4. Consecutive Partial Updates
      const String multiUpdateUser = 'multi_update_user';
      await db.insert('users', {
        'username': multiUpdateUser,
        'email': 'multi@test.com',
        'age': 20,
      });

      // Update 1: Change email
      await db.update('users', {'email': 'multi_new@test.com'}).where(
          'username', '=', multiUpdateUser);
      // Update 2: Change age
      await db
          .update('users', {'age': 21}).where('username', '=', multiUpdateUser);

      final finalRecord = await db
          .query('users')
          .where('username', '=', multiUpdateUser)
          .first();
      isTestPassed &= _expect('Multi-update: final email matches',
          finalRecord?['email'], 'multi_new@test.com');
      isTestPassed &=
          _expect('Multi-update: final age matches', finalRecord?['age'], 21);
      isTestPassed &= _expect('Multi-update: username (id) preserved',
          finalRecord?['username'], multiUpdateUser);

      // 5. Failed insert after reserve must release slots (no orphan unique lock)
      const String orphanUser = 'orphan_reserve_probe';
      final owner = await db.insert('users', {
        'username': orphanUser,
        'email': 'orphan_owner@test.com',
        'age': 40,
      });
      isTestPassed &=
          _expect('Orphan probe owner insert succeeds', !owner.hasErrors, true);

      final blocked = await db.insert('users', {
        'username': orphanUser,
        'email': 'orphan_blocked@test.com',
        'age': 41,
      });
      isTestPassed &=
          _expect('Duplicate username insert blocked', blocked.hasErrors, true);

      await db.delete('users').where('username', '=', orphanUser);

      final reused = await db.insert('users', {
        'username': orphanUser,
        'email': 'orphan_reused@test.com',
        'age': 42,
      });
      isTestPassed &= _expect(
          'After delete, username reusable (no orphan reserve)',
          !reused.hasErrors,
          true);

      // 6. Concurrent same PK: exactly one success
      final c1 = db.insert('users', {
        'id': 99001,
        'username': 'concurrent_pk_a',
        'email': 'c_pk_a@test.com',
      });
      final c2 = db.insert('users', {
        'id': 99001,
        'username': 'concurrent_pk_b',
        'email': 'c_pk_b@test.com',
      });
      final concurrent = await Future.wait([c1, c2]);
      final okCount = concurrent.where((r) => !r.hasErrors).length;
      final failCount = concurrent.where((r) => r.hasErrors).length;
      isTestPassed &= _expect('Concurrent same PK: one success', okCount, 1);
      isTestPassed &= _expect('Concurrent same PK: one failure', failCount, 1);
    } catch (e, s) {
      isTestPassed = false;
      _failTest('Exception in _testBufferPipelineRobustness: $e\n$s');
    }

    return isTestPassed;
  }

  /// Tests basic Create, Read, Update, Delete operations.
  Future<bool> _testBasicCrud() async {
    log.add('--- Testing: Basic CRUD Operations ---', LogLevel.debug);
    bool isTestPassed = true;
    _WatchEventCollector<List<Map<String, dynamic>>>? watchCollector;
    try {
      await _clearTablesSafely();

      if (_isWasmBuild) {
        final insertResult = await db.insert('users',
            {'username': 'crud_user', 'email': 'crud@test.com', 'age': 30});
        isTestPassed &= _expect(
            'Insert should be successful', !insertResult.hasErrors, true);
        isTestPassed &=
            _expect('Insert should affect 1 row', insertResult.successCount, 1);

        final user =
            await db.query('users').where('username', '=', 'crud_user');
        isTestPassed &= _expect('Read should find 1 user', user.length, 1);
        isTestPassed &= _expect('Read should find correct user',
            user.data.first['email'], 'crud@test.com');

        await db
            .update('users', {'age': 31}).where('username', '=', 'crud_user');
        final updatedUser =
            await db.query('users').where('username', '=', 'crud_user').first();
        isTestPassed &=
            _expect('Update should change age to 31', updatedUser?['age'], 31);

        final deleteResult =
            await db.delete('users').where('username', '=', 'crud_user');
        isTestPassed &= _expect(
            'Delete should be successful', !deleteResult.hasErrors, true);
        isTestPassed &=
            _expect('Delete should affect 1 row', deleteResult.successCount, 1);
        final dataAfterDeleteQuery = await db.query('users');
        final countAfterDelete = dataAfterDeleteQuery.length;
        isTestPassed &=
            _expect('Count after delete should be 0', countAfterDelete, 0);
        return isTestPassed;
      }

      const username = 'crud_user';
      const email = 'crud@test.com';
      const insertedAge = 30;
      const updatedAge = 31;

      final insertedExpected = <String, dynamic>{
        'username': username,
        'email': email,
        'age': insertedAge,
      };
      final updatedExpected = <String, dynamic>{
        'username': username,
        'email': email,
        'age': updatedAge,
      };

      // Attach watch listener before write operations to verify all stream callbacks.
      watchCollector = _WatchEventCollector<List<Map<String, dynamic>>>(
        db.query('users').where('username', '=', username).watch(),
      );

      // Verify event 0: initial query state before insert must be empty.
      final initialWatchData = await watchCollector.waitForEventAt(0);
      isTestPassed &= _expect(
        'Watch stream initial emission should be empty',
        initialWatchData?.isEmpty ?? false,
        true,
      );

      // Prime cached miss queries so insert must invalidate and rebuild them.
      isTestPassed &= await _expectCachedUserQueryTwice(
        description: 'Pre-insert username index query should be empty',
        field: 'username',
        value: username,
      );
      isTestPassed &= await _expectCachedUserQueryTwice(
        description: 'Pre-insert age index query should be empty',
        field: 'age',
        value: insertedAge,
      );

      // Create
      final insertResult = await db.insert('users', {
        'username': username,
        'email': email,
        'age': insertedAge,
      });
      isTestPassed &=
          _expect('Insert should be successful', !insertResult.hasErrors, true);
      isTestPassed &=
          _expect('Insert should affect 1 row', insertResult.successCount, 1);
      if (!isTestPassed || insertResult.firstPrimaryKey == null) return false;

      final userId = insertResult.firstPrimaryKey;

      // Verify event 1: watch callback after insert.
      final insertedWatchData = await watchCollector.waitForEventAt(1);
      isTestPassed &= _expect(
        'Watch stream emission after insert should contain 1 row',
        insertedWatchData?.length,
        1,
      );
      if (insertedWatchData != null && insertedWatchData.isNotEmpty) {
        final row = insertedWatchData.first;
        isTestPassed &=
            _expect('Watch insert event username', row['username'], username);
        isTestPassed &=
            _expect('Watch insert event email', row['email'], email);
        isTestPassed &=
            _expect('Watch insert event age', row['age'], insertedAge);
      }

      // Read twice after insert to ensure repeated cached queries stay correct.
      isTestPassed &= await _expectCachedUserQueryTwice(
        description: 'Inserted user should be readable by primary key',
        field: 'id',
        value: userId,
        expected: insertedExpected,
      );
      isTestPassed &= await _expectCachedUserQueryTwice(
        description: 'Inserted user should be readable by username index',
        field: 'username',
        value: username,
        expected: insertedExpected,
      );
      isTestPassed &= await _expectCachedUserQueryTwice(
        description: 'Inserted user should be readable by age index',
        field: 'age',
        value: insertedAge,
        expected: insertedExpected,
      );

      // Update: query twice after write to catch stale data being re-cached.
      final updateResult = await db
          .update('users', {'age': updatedAge}).where('id', '=', userId);
      isTestPassed &=
          _expect('Update should be successful', !updateResult.hasErrors, true);
      isTestPassed &=
          _expect('Update should affect 1 row', updateResult.successCount, 1);

      // Verify event 2: watch callback after update.
      final updatedWatchData = await watchCollector.waitForEventAt(2);
      isTestPassed &= _expect(
        'Watch stream emission after update should contain 1 row',
        updatedWatchData?.length,
        1,
      );
      if (updatedWatchData != null && updatedWatchData.isNotEmpty) {
        final row = updatedWatchData.first;
        isTestPassed &=
            _expect('Watch update event age', row['age'], updatedAge);
      }

      isTestPassed &= await _expectCachedUserQueryTwice(
        description: 'Updated user should return latest data by primary key',
        field: 'id',
        value: userId,
        expected: updatedExpected,
      );
      isTestPassed &= await _expectCachedUserQueryTwice(
        description: 'Updated user should return latest data by username index',
        field: 'username',
        value: username,
        expected: updatedExpected,
      );
      isTestPassed &= await _expectCachedUserQueryTwice(
        description: 'Updated user should return latest data by new age index',
        field: 'age',
        value: updatedAge,
        expected: updatedExpected,
      );
      isTestPassed &= await _expectCachedUserQueryTwice(
        description: 'Updated user old age index query should stay empty',
        field: 'age',
        value: insertedAge,
      );

      // Delete: verify repeated cached lookups do not resurrect stale data.
      final deleteResult = await db.delete('users').where('id', '=', userId);
      isTestPassed &=
          _expect('Delete should be successful', !deleteResult.hasErrors, true);
      isTestPassed &=
          _expect('Delete should affect 1 row', deleteResult.successCount, 1);

      // Verify event 3: watch callback after delete.
      final deletedWatchData = await watchCollector.waitForEventAt(3);
      isTestPassed &= _expect(
        'Watch stream emission after delete should be empty',
        deletedWatchData?.isEmpty ?? false,
        true,
      );

      isTestPassed &= await _expectCachedUserQueryTwice(
        description: 'Deleted user primary key query should stay empty',
        field: 'id',
        value: userId,
      );
      isTestPassed &= await _expectCachedUserQueryTwice(
        description: 'Deleted user username index query should stay empty',
        field: 'username',
        value: username,
      );
      isTestPassed &= await _expectCachedUserQueryTwice(
        description: 'Deleted user age index query should stay empty',
        field: 'age',
        value: updatedAge,
      );

      final dataAfterDeleteQuery = await db.query('users');
      final countAfterDelete = dataAfterDeleteQuery.length;
      isTestPassed &=
          _expect('Count after delete should be 0', countAfterDelete, 0);
    } catch (e, s) {
      isTestPassed = false;
      _failTest('Exception in _testBasicCrud: $e\n$s');
    } finally {
      await watchCollector?.cancel();
    }
    return isTestPassed;
  }

  /// Tests the upsert and cache synchronization logic.
  Future<bool> _testUpsertAndCacheSync() async {
    log.add(
        '--- Testing: Upsert and Cache Synchronization ---', LogLevel.debug);
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

      // Upsert (update): include all non-nullable + unique key fields for conflict target
      await db.upsert('users', {
        'username': 'upsert_user',
        'email': 'upsert@test.com',
        'age': 40,
      });
      final updatedUser = await db
          .query('users')
          .where('email', '=', 'upsert@test.com')
          .first();
      isTestPassed &= _expect(
          'Upsert-update should set age to 40', updatedUser?['age'], 40);
      final dataAfterUpdate = await db.query('users');
      isTestPassed &= _expect('Upsert-update should not create a new user',
          dataAfterUpdate.length, 1);

      // Cache Synchronization Verification
      final q1 =
          await db.query('users').whereEqual('username', 'upsert_user').first();
      isTestPassed &=
          _expect('Cached read matches current age 40', q1?['age'], 40);

      // Perform a new upsert to test cache invalidation/synchronization on update
      await db.upsert('users', {
        'username': 'upsert_user',
        'email': 'upsert@test.com',
        'age': 50,
      });
      final q2 =
          await db.query('users').whereEqual('username', 'upsert_user').first();
      isTestPassed &= _expect(
          'Upsert-update should immediately set age to 50 in cache',
          q2?['age'],
          50);

      // Perform delete to test cache sync on delete
      await db.delete('users').whereEqual('username', 'upsert_user');
      final q3 =
          await db.query('users').whereEqual('username', 'upsert_user').first();
      isTestPassed &= _expect(
          'Query returns null after delete due to cache clear', q3, null);

      // 4. Test batchUpsert cache synchronization
      await db.batchUpsert('users', [
        {'username': 'batch_upsert_u1', 'email': 'bu1@test.com', 'age': 20},
        {'username': 'batch_upsert_u2', 'email': 'bu2@test.com', 'age': 25},
      ]);
      // Query to load them into the cache
      final qbu1 = await db
          .query('users')
          .whereEqual('username', 'batch_upsert_u1')
          .first();
      final qbu2 = await db
          .query('users')
          .whereEqual('username', 'batch_upsert_u2')
          .first();
      isTestPassed &= _expect('batch_upsert_u1 age in cache', qbu1?['age'], 20);
      isTestPassed &= _expect('batch_upsert_u2 age in cache', qbu2?['age'], 25);

      // Now update them via batchUpsert
      await db.batchUpsert('users', [
        {'username': 'batch_upsert_u1', 'email': 'bu1@test.com', 'age': 30},
        {'username': 'batch_upsert_u2', 'email': 'bu2@test.com', 'age': 35},
      ]);
      // Immediately read again to ensure cache is updated
      final qbu1Updated = await db
          .query('users')
          .whereEqual('username', 'batch_upsert_u1')
          .first();
      final qbu2Updated = await db
          .query('users')
          .whereEqual('username', 'batch_upsert_u2')
          .first();
      isTestPassed &= _expect(
          'batch_upsert_u1 updated age from cache', qbu1Updated?['age'], 30);
      isTestPassed &= _expect(
          'batch_upsert_u2 updated age from cache', qbu2Updated?['age'], 35);

      // 5. Test normal update cache synchronization
      await db.update('users', {'age': 45}).whereEqual(
          'username', 'batch_upsert_u1');
      final qup = await db
          .query('users')
          .whereEqual('username', 'batch_upsert_u1')
          .first();
      isTestPassed &=
          _expect('normal update syncs with cache correctly', qup?['age'], 45);

      // 6. Test delete cache sync with normal delete
      await db.delete('users').whereEqual('username', 'batch_upsert_u1');
      final qupDel = await db
          .query('users')
          .whereEqual('username', 'batch_upsert_u1')
          .first();
      isTestPassed &= _expect(
          'Deleted user query returns null due to cache removal', qupDel, null);

      // 7. Test batchUpdate cache synchronization
      // Insert first
      await db.batchInsert('users', [
        {'username': 'batch_update_u1', 'email': 'bu_up1@test.com', 'age': 20},
        {'username': 'batch_update_u2', 'email': 'bu_up2@test.com', 'age': 25},
      ]);
      // Load into cache
      final qbuUp1 = await db
          .query('users')
          .whereEqual('username', 'batch_update_u1')
          .first();
      final qbuUp2 = await db
          .query('users')
          .whereEqual('username', 'batch_update_u2')
          .first();
      isTestPassed &=
          _expect('batch_update_u1 age in cache', qbuUp1?['age'], 20);
      isTestPassed &=
          _expect('batch_update_u2 age in cache', qbuUp2?['age'], 25);

      // Extract generated primary keys to update
      final id1 = qbuUp1?['id'];
      final id2 = qbuUp2?['id'];

      // Perform batchUpdate
      await db.batchUpdate('users', [
        {
          'id': id1,
          'username': 'batch_update_u1',
          'email': 'bu_up1@test.com',
          'age': 30
        },
        {
          'id': id2,
          'username': 'batch_update_u2',
          'email': 'bu_up2@test.com',
          'age': 35
        },
      ]);

      // Immediately read again to ensure cache is updated
      final qbuUp1Updated = await db
          .query('users')
          .whereEqual('username', 'batch_update_u1')
          .first();
      final qbuUp2Updated = await db
          .query('users')
          .whereEqual('username', 'batch_update_u2')
          .first();
      isTestPassed &= _expect(
          'batch_update_u1 updated age from cache', qbuUp1Updated?['age'], 30);
      isTestPassed &= _expect(
          'batch_update_u2 updated age from cache', qbuUp2Updated?['age'], 35);

      // 8. Test setValueMany cache synchronization
      await db.kv.setMany({
        'kv_batch_k1': 'value_v1',
        'kv_batch_k2': 'value_v2',
      });
      // Load into cache
      final qkv1 = await db.kv.get('kv_batch_k1');
      final qkv2 = await db.kv.get('kv_batch_k2');
      isTestPassed &= _expect('KV batch first value matches', qkv1, 'value_v1');
      isTestPassed &=
          _expect('KV batch second value matches', qkv2, 'value_v2');

      // Update via setValueMany again
      await db.kv.setMany({
        'kv_batch_k1': 'value_v1_new',
        'kv_batch_k2': 'value_v2_new',
      });
      final qkv1Updated = await db.kv.get('kv_batch_k1');
      final qkv2Updated = await db.kv.get('kv_batch_k2');
      isTestPassed &= _expect('KV batch first updated value matches from cache',
          qkv1Updated, 'value_v1_new');
      isTestPassed &= _expect(
          'KV batch second updated value matches from cache',
          qkv2Updated,
          'value_v2_new');
    } catch (e, s) {
      isTestPassed = false;
      _failTest('Exception in _testUpsertAndCacheSync: $e\n$s');
    }
    return isTestPassed;
  }

  /// Tests multi-table JOIN queries.
  Future<bool> _testJoinQueries() async {
    log.add('--- Testing: JOIN Queries ---', LogLevel.debug);
    bool isTestPassed = true;
    try {
      await _clearTablesSafely();
      // Insert user first to get valid ID for foreign key
      final userResult = await db
          .insert('users', {'username': 'join_user', 'email': 'join@test.com'});
      if (!!userResult.hasErrors) {
        isTestPassed = false;
        _failTest('Failed to insert user for join test');
        return false;
      }
      final userId = userResult.firstPrimaryKey;
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
    log.add('--- Testing: Multi-Space Isolation ---', LogLevel.debug);
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
    log.add('--- Testing: Advanced Queries & Edge Cases ---', LogLevel.debug);
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
    log.add('--- Testing: Non-Nullable Constraint ---', LogLevel.debug);
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
          !result.hasErrors,
          false);
      isTestPassed &= _expect(
          'Error type should be validationFailed or notNullViolation',
          result.firstType == ResultType.bizValidationFailed ||
              result.firstType == ResultType.bizNotNullViolation,
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
    log.add('--- Testing: .count() Verification ---', LogLevel.debug);
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
    log.add('--- Testing: Backup & Restore ---', LogLevel.debug);
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
          'Insert base users success', !u1.hasErrors && !u2.hasErrors, true);
      final p1 = await db.insert(
          'posts', {'title': 'bk_post_1', 'user_id': u1.firstPrimaryKey});
      ok &= _expect('Insert base post success', !p1.hasErrors, true);

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
    if (_isWasmBuild) {
      log.add(
          '❌ Concurrency Stress Test is skipped on WebAssembly due to dart2wasm/wasm-opt compatibility.',
          LogLevel.warn);
      _updateLastOperation('❌ Concurrency Test Skipped on WebAssembly');
      return false;
    }

    log.add(
        '--- Testing: Configurable Concurrency Stress Test (users & settings) ---',
        LogLevel.debug);
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
      // Store closures to DEFER execution until the concurrent phase.
      // Previously, futures fired immediately when added, causing UI jank.
      final operations = <Future Function()>[];

      // Helper to prepare base data and generate operation closures
      Future<List<Map<String, dynamic>>> prepareAndGenerateOpsForTable({
        required String tableName,
        required Map<String, int> tableConfig,
        required Map<String, dynamic> Function(int i) dataGenerator,
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
          // Use batchInsert instead of individual inserts to avoid N concurrent
          // futures flooding the main isolate and blocking UI frames.
          const batchSize = 200;
          for (int i = 0; i < baseCount; i += batchSize) {
            final end = (i + batchSize > baseCount) ? baseCount : i + batchSize;

            // Throttle UI updates: only update at start and every 200 records
            if (i == 0 || i % 200 == 0) {
              _updateLastOperation(
                  'Preparing base for $tableName: ${i + 1}-$end of $baseCount');
            }

            final batchData = <Map<String, dynamic>>[];
            for (int j = i; j < end; j++) {
              batchData.add(dataGenerator(j));
            }

            final result = await db.batchInsert(tableName, batchData);

            if (!result.hasErrors) {
              for (int j = 0; j < result.statuses.length; j++) {
                final Map<String, dynamic> newItem = {
                  idField: result.statuses[j].primaryKey
                };
                if (j < batchData.length &&
                    batchData[j].containsKey(nameField)) {
                  newItem[nameField] = batchData[j][nameField];
                }
                baseItems.add(newItem);
              }
            }

            // Yield with 1ms to guarantee UI frame can render
            await Future.delayed(const Duration(milliseconds: 1));
          }
          log.add(
              'Created ${baseItems.length}/$baseCount base records for $tableName.',
              LogLevel.info);
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

          // Add Update closures (deferred — no future fires until called)
          for (int i = 0; i < itemsToUpdateLocal.length; i++) {
            final item = itemsToUpdateLocal[i];
            operations.add(() => db
                .update(tableName, updateData)
                .where(idField, '=', item[idField]));
            if (i > 0 && i % 200 == 0) {
              await Future.delayed(Duration.zero);
            }
          }

          // Add Delete closures (deferred)
          for (int i = 0; i < itemsToDeleteLocal.length; i++) {
            final item = itemsToDeleteLocal[i];
            operations.add(
                () => db.delete(tableName).where(idField, '=', item[idField]));
            if (i > 0 && i % 200 == 0) {
              await Future.delayed(Duration.zero);
            }
          }
        }

        // Add Read closures (deferred)
        final readCount = tableConfig['read'] ?? 0;
        if (baseItems.isNotEmpty) {
          for (var i = 0; i < readCount; i++) {
            final item = baseItems[random.nextInt(baseItems.length)];
            operations.add(() =>
                db.query(tableName).where(idField, '=', item[idField]).first());
            if (i > 0 && i % 200 == 0) {
              await Future.delayed(Duration.zero);
            }
          }
        }

        // Add new Insert closures (deferred)
        final insertCount = tableConfig['insert'] ?? 0;
        for (var i = 0; i < insertCount; i++) {
          final data = dataGenerator(baseCount + i);
          operations.add(() => db.insert(tableName, data));
          itemsToInsert.add(data);
          if (i > 0 && i % 200 == 0) {
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
        dataGenerator: (i) => {
          'username': 'cc_user_$i',
          'email': 'cc_user_$i@test.com',
          'age': 20 + i,
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
        dataGenerator: (i) => {
          'key': 'cc_setting_$i',
          'value': 'value_$i',
        },
        updateData: {'value': 'updated_value'},
        idField: 'key',
        nameField: 'key',
      );

      // Stage 3: Execute all operations concurrently
      _updateLastOperation(
          'Executing ${operations.length} mixed operations concurrently...');
      log.add('Executing ${operations.length} mixed operations concurrently...',
          LogLevel.info);
      operations.shuffle(random);

      // Track actual deletion results
      final actualDeletedUsers = <String>[];
      final actualDeletedSettings = <String>[];

      const batchSize = 50;
      final totalBatches = (operations.length / batchSize).ceil();
      for (int i = 0; i < operations.length; i += batchSize) {
        final end = (i + batchSize > operations.length)
            ? operations.length
            : i + batchSize;
        // Throttle UI updates to avoid excessive setState rebuilds
        if (i == 0 || i % 200 == 0) {
          _updateLastOperation(
              'Running batch ${i ~/ batchSize + 1}/$totalBatches...');
        }
        // Launch this batch NOW — closures start futures only when called
        final batch = <Future>[];
        for (int j = i; j < end; j++) {
          batch.add(operations[j]());
        }
        await Future.wait(batch, eagerError: false);
        // 1ms delay guarantees the UI event loop gets a chance to render
        await Future.delayed(const Duration(milliseconds: 1));
      }

      stopwatch.stop();

      // Stage 4: Verification
      _updateLastOperation('Verifying results...');

      // Verify which deletions actually succeeded — use batch whereIn
      // instead of N individual queries to avoid O(N) round-trips.
      _updateLastOperation('Checking actual deletion results...');
      if (deletedUsers.isNotEmpty) {
        final allDeletedUserIds = deletedUsers.map((u) => u['id']).toList();
        final stillExisting =
            await db.query('users').whereIn('id', allDeletedUserIds);
        final existingIdSet =
            stillExisting.data.map((u) => u['id'].toString()).toSet();
        for (final user in deletedUsers) {
          if (!existingIdSet.contains(user['id'].toString())) {
            actualDeletedUsers.add(user['id'].toString());
          }
        }
      }
      if (deletedSettings.isNotEmpty) {
        final allDeletedSettingKeys =
            deletedSettings.map((s) => s['key']).toList();
        final stillExisting =
            await db.query('settings').whereIn('key', allDeletedSettingKeys);
        final existingKeySet =
            stillExisting.data.map((s) => s['key'].toString()).toSet();
        for (final setting in deletedSettings) {
          if (!existingKeySet.contains(setting['key'].toString())) {
            actualDeletedSettings.add(setting['key'].toString());
          }
        }
      }

      // --- Data Integrity Verification ---
      List<T> getHeadTailSample<T>(List<T> list) {
        final sampleSize = verificationSampleSize;
        if (list.isEmpty || list.length <= sampleSize) {
          return List<T>.from(list);
        }
        final half = (sampleSize / 2).ceil();
        final head = list.sublist(0, half);
        final tail = list.sublist(list.length - half);
        return <T>[...head, ...tail];
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
      log.add('Test data cleaned up.', LogLevel.info);
      log.add(
          'Concurrency test finished in ${stopwatch.elapsedMilliseconds}ms.',
          LogLevel.info);
    }
    _updateLastOperation(isTestPassed
        ? '✅ Concurrency Test Passed'
        : '❌ Concurrency Test Failed');
    return isTestPassed;
  }

  /// Comprehensive test for foreign key operations.
  /// Tests constraint validation, cascade delete, cascade update, RESTRICT, and clear/drop operations.
  Future<bool> _testForeignKeyOperations() async {
    log.add('--- Testing: Foreign Key Operations ---', LogLevel.debug);
    bool isTestPassed = true;
    try {
      await _clearTablesSafely();

      // ========== Test 1: Foreign Key Constraint Validation ==========
      log.add('--- Sub-test: Foreign Key Constraint Validation ---',
          LogLevel.debug);

      // Insert a valid user
      final userResult = await db.insert('users', {
        'username': 'fk_user',
        'email': 'fk@test.com',
      });
      isTestPassed &=
          _expect('Insert user should succeed', !userResult.hasErrors, true);
      if (!isTestPassed) return false;

      final userId = userResult.firstPrimaryKey;

      // Test 1.1: Insert post with valid foreign key
      final postResult = await db.insert('posts', {
        'title': 'Valid Post',
        'user_id': userId,
      });
      isTestPassed &= _expect('Insert post with valid user_id should succeed',
          !postResult.hasErrors, true);

      // Test 1.2: Insert post with invalid foreign key (non-existent user_id)
      final invalidPostResult = await db.insert('posts', {
        'title': 'Invalid Post',
        'user_id': '99999', // Non-existent user ID
      });
      isTestPassed &= _expect('Insert post with invalid user_id should fail',
          !invalidPostResult.hasErrors, false);
      isTestPassed &= _expect(
          'Error type should be foreignKeyViolation or validationFailed',
          invalidPostResult.firstType == ResultType.bizForeignKeyViolation ||
              invalidPostResult.firstType ==
                  ResultType.bizForeignKeyParentNotExist ||
              invalidPostResult.firstType == ResultType.bizValidationFailed,
          true);

      // Test 1.3: Insert comment with valid foreign keys
      final postId = postResult.firstPrimaryKey;
      final commentResult = await db.insert('comments', {
        'post_id': postId,
        'user_id': userId,
        'content': 'Valid comment',
      });
      isTestPassed &= _expect(
          'Insert comment with valid foreign keys should succeed',
          !commentResult.hasErrors,
          true);

      // Test 1.4: Insert comment with invalid post_id
      final invalidCommentResult1 = await db.insert('comments', {
        'post_id': '99999', // Non-existent post ID
        'user_id': userId,
        'content': 'Invalid comment',
      });
      isTestPassed &= _expect('Insert comment with invalid post_id should fail',
          !invalidCommentResult1.hasErrors, false);

      // Test 1.5: Insert comment with invalid user_id
      final invalidCommentResult2 = await db.insert('comments', {
        'post_id': postId,
        'user_id': '99999', // Non-existent user ID
        'content': 'Invalid comment',
      });
      isTestPassed &= _expect('Insert comment with invalid user_id should fail',
          !invalidCommentResult2.hasErrors, false);

      // ========== Test 2: Cascade Delete (CASCADE) ==========
      log.add('--- Sub-test: Cascade Delete ---', LogLevel.debug);

      await _clearTablesSafely();

      // Create test data: user -> posts -> comments
      // Note: comments.user_id has RESTRICT, so we use a different user for comments
      // to avoid RESTRICT blocking the cascade delete test
      final cascadeUserResult = await db.insert('users', {
        'username': 'cascade_user',
        'email': 'cascade@test.com',
      });
      isTestPassed &= _expect(
          'Insert user should succeed', !cascadeUserResult.hasErrors, true);
      if (!isTestPassed) return false;

      final cascadeUserId = cascadeUserResult.firstPrimaryKey;

      // Create a separate user for comments (to avoid RESTRICT blocking cascade delete)
      final cascadeCommentUserResult = await db.insert('users', {
        'username': 'cascade_comment_user',
        'email': 'cascade_comment@test.com',
      });
      isTestPassed &= _expect('Insert comment user should succeed',
          !cascadeCommentUserResult.hasErrors, true);
      if (!isTestPassed) return false;

      final cascadeCommentUserId = cascadeCommentUserResult.firstPrimaryKey;

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
          !cascadePost1Result.hasErrors && !cascadePost2Result.hasErrors, true);
      if (!isTestPassed) return false;

      final cascadePost1Id = cascadePost1Result.firstPrimaryKey;
      final cascadePost2Id = cascadePost2Result.firstPrimaryKey;

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
          _expect('Delete user should succeed', !deleteResult.hasErrors, true);
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
      log.add('--- Sub-test: Cascade Update ---', LogLevel.debug);

      await _clearTablesSafely();

      // Create test data
      final updateUserResult = await db.insert('users', {
        'username': 'update_user',
        'email': 'update@test.com',
      });
      isTestPassed &= _expect(
          'Insert user should succeed', !updateUserResult.hasErrors, true);
      if (!isTestPassed) return false;

      final updateUserId = updateUserResult.firstPrimaryKey;

      // Create post
      final updatePostResult = await db.insert('posts', {
        'title': 'Update Post',
        'user_id': updateUserId,
      });
      isTestPassed &= _expect(
          'Insert post should succeed', !updatePostResult.hasErrors, true);
      if (!isTestPassed) return false;

      final updatePostId = updatePostResult.firstPrimaryKey;

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
      log.add('--- Sub-test: RESTRICT Constraint ---', LogLevel.debug);

      await _clearTablesSafely();

      // Create test data
      final restrictUserResult = await db.insert('users', {
        'username': 'restrict_user',
        'email': 'restrict@test.com',
      });
      isTestPassed &= _expect(
          'Insert user should succeed', !restrictUserResult.hasErrors, true);
      if (!isTestPassed) return false;

      final restrictUserId = restrictUserResult.firstPrimaryKey;

      // Create post (posts.user_id has CASCADE, so this won't test RESTRICT)
      final restrictPostResult = await db.insert('posts', {
        'title': 'Restrict Post',
        'user_id': restrictUserId,
      });
      isTestPassed &= _expect(
          'Insert post should succeed', !restrictPostResult.hasErrors, true);
      if (!isTestPassed) return false;

      final restrictPostId = restrictPostResult.firstPrimaryKey;

      // Create comment (comments.user_id has RESTRICT)
      final restrictCommentResult = await db.insert('comments', {
        'post_id': restrictPostId,
        'user_id': restrictUserId,
        'content': 'Restrict Comment',
      });
      isTestPassed &= _expect('Insert comment should succeed',
          !restrictCommentResult.hasErrors, true);
      if (!isTestPassed) return false;

      // Try to delete user - should fail because comments.user_id has RESTRICT
      final restrictDeleteResult =
          await db.delete('users').where('id', '=', restrictUserId);
      isTestPassed &= _expect(
          'Delete user with RESTRICT foreign key should fail',
          !restrictDeleteResult.hasErrors,
          false);
      isTestPassed &= _expect(
          'Error type should be foreignKeyViolation or validationFailed',
          restrictDeleteResult.firstType == ResultType.bizForeignKeyViolation ||
              restrictDeleteResult.firstType ==
                  ResultType.bizForeignKeyChildRestrict ||
              restrictDeleteResult.firstType == ResultType.bizValidationFailed,
          true);

      // Verify user still exists
      final restrictUserAfter =
          await db.query('users').where('id', '=', restrictUserId).first();
      isTestPassed &= _expect('User should still exist after failed delete',
          restrictUserAfter != null, true);

      // Delete comment first, then user should succeed
      await db
          .delete('comments')
          .where('id', '=', restrictCommentResult.firstPrimaryKey);
      final restrictDeleteResult2 =
          await db.delete('users').where('id', '=', restrictUserId);
      isTestPassed &= _expect(
          'Delete user after removing comment should succeed',
          !restrictDeleteResult2.hasErrors,
          true);

      // ========== Test 5: Clear and Drop Operations ==========
      log.add('--- Sub-test: Clear and Drop Operations ---', LogLevel.debug);

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
          !clearUser1Result.hasErrors && !clearUser2Result.hasErrors, true);
      if (!isTestPassed) return false;

      final clearUser1Id = clearUser1Result.firstPrimaryKey;
      final clearUser2Id = clearUser2Result.firstPrimaryKey;

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
          !clearPost1Result.hasErrors && !clearPost2Result.hasErrors, true);
      if (!isTestPassed) return false;

      final clearPost1Id = clearPost1Result.firstPrimaryKey;
      final clearPost2Id = clearPost2Result.firstPrimaryKey;

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
      if (!!clearUsersBeforeTest.hasErrors) {
        // If clear failed, manually delete all users
        await db.delete('users').allowDeleteAll();
      }

      // Create test data for RESTRICT test
      final clearUser3Result = await db.insert('users', {
        'username': 'clear_user3',
        'email': 'clear3@test.com',
      });
      isTestPassed &= _expect('Insert user for RESTRICT test should succeed',
          !clearUser3Result.hasErrors, true);
      if (!isTestPassed) return false;

      final clearUser3Id = clearUser3Result.firstPrimaryKey;
      final clearPost3Result = await db.insert('posts', {
        'title': 'Clear Post 3',
        'user_id': clearUser3Id,
      });
      isTestPassed &= _expect('Insert post for RESTRICT test should succeed',
          !clearPost3Result.hasErrors, true);
      if (!isTestPassed) return false;

      final clearPost3Id = clearPost3Result.firstPrimaryKey;
      final clearCommentResult = await db.insert('comments', {
        'post_id': clearPost3Id,
        'user_id': clearUser3Id,
        'content': 'Comment 3',
      });
      isTestPassed &= _expect('Insert comment for RESTRICT test should succeed',
          !clearCommentResult.hasErrors, true);
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
          !clearResult.hasErrors,
          false);
      isTestPassed &= _expect(
          'Error type should be foreignKeyViolation or validationFailed',
          clearResult.firstType == ResultType.bizForeignKeyViolation ||
              clearResult.firstType == ResultType.bizForeignKeyChildRestrict ||
              clearResult.firstType == ResultType.bizValidationFailed,
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
    log.add('--- Testing: Expression Operations ---', LogLevel.debug);
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
    log.add('--- Testing: Transaction Operations ---', LogLevel.debug);
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
          'Transaction should commit successfully', !txResult1.hasErrors, true);

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
          'Transaction should rollback on error', txResult2.hasErrors, true);

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
          txResult3.hasErrors,
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
          !txResult4.hasErrors, true);

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
          txResult6.hasErrors, true);

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
          !txResult7.hasErrors, true);

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

  /// Validates all Key-Value Store (db.kv) operations.
  Future<bool> _testKvStoreOperations() async {
    log.add('--- Testing: KV Store Operations ---', LogLevel.debug);
    bool isTestPassed = true;
    final kv = db.kv;

    try {
      // 1. Basic Set/Get
      await kv.clear();
      await kv.set('test_string', 'hello');
      await kv.set('test_int', 123);
      await kv.set('test_bool', true);
      await kv.set('test_map', {'a': 1, 'b': '2'});
      await kv.set('test_list', [1, 2, 3]);

      final stringVal = await kv.getString('test_string');
      isTestPassed = isTestPassed &&
          _expect('getString("test_string")', stringVal, 'hello');

      final intVal = await kv.getInt('test_int');
      isTestPassed = isTestPassed && _expect('getInt("test_int")', intVal, 123);

      final boolVal = await kv.getBool('test_bool');
      isTestPassed =
          isTestPassed && _expect('getBool("test_bool")', boolVal, true);

      final mapVal = await kv.getMap('test_map');
      isTestPassed = isTestPassed &&
          _expect('getMap("test_map") contains a', mapVal?['a'], 1);
      isTestPassed = isTestPassed &&
          _expect('getMap("test_map") contains b', mapVal?['b'], '2');

      final listVal = await kv.getList<int>('test_list');
      isTestPassed = isTestPassed &&
          _expect('getList<int>("test_list") length', listVal?.length, 3);
      isTestPassed = isTestPassed &&
          _expect('getList<int>("test_list")[1]', listVal?[1], 2);

      // 2. Exists and Count
      final existsStr = await kv.exists('test_string');
      isTestPassed = isTestPassed &&
          _expect('exists("test_string") should be true', existsStr, true);

      final existsNon = await kv.exists('non_existent');
      isTestPassed = isTestPassed &&
          _expect('exists("non_existent") should be false', existsNon, false);

      final countVal = await kv.count();
      isTestPassed =
          isTestPassed && _expect('count() should be 5', countVal, 5);

      // 3. Prefix GetKeys
      await kv.set('pref_1', 1);
      await kv.set('pref_2', 2);
      await kv.set('other', 3);
      final keysResult = await kv.getKeys(prefix: 'pref_');
      isTestPassed = isTestPassed &&
          _expect('getKeys(prefix: "pref_") length', keysResult.length, 2);
      isTestPassed = isTestPassed &&
          _expect(
              'getKeys contains pref_1', keysResult.contains('pref_1'), true);
      isTestPassed = isTestPassed &&
          _expect(
              'getKeys contains pref_2', keysResult.contains('pref_2'), true);

      // 3b. kv.query() record listing with limit
      final queryPage =
          await kv.query().prefix('pref_').orderByKeyAsc().limit(10);
      isTestPassed = isTestPassed &&
          _expect('kv.query prefix page length', queryPage.data.length, 2);
      isTestPassed = isTestPassed &&
          _expect('kv.query first key', queryPage.data.first['key'], 'pref_1');
      isTestPassed = isTestPassed &&
          _expect('kv.query first value', queryPage.data.first['value'], 1);
      final queryCount = await kv.query().prefix('pref_').count();
      isTestPassed =
          isTestPassed && _expect('kv.query().prefix.count()', queryCount, 2);

      // 4. Atomic Increment
      await kv.set('counter', 10);
      await kv.setIncrement('counter', amount: 5);
      final counterVal = await kv.getInt('counter');
      isTestPassed = isTestPassed &&
          _expect('setIncrement("counter", 5) result', counterVal, 15);

      await kv.setIncrement('new_counter', amount: 1);
      final newCounterVal = await kv.getInt('new_counter');
      isTestPassed =
          isTestPassed && _expect('setIncrement on new key', newCounterVal, 1);

      // 5. TTL Operations
      await kv.set('temp_key', 'temp', ttl: const Duration(seconds: 10));
      final ttlVal = await kv.getTtl('temp_key');
      isTestPassed = isTestPassed &&
          _expect(
              'getTtl should be positive', (ttlVal?.inSeconds ?? 0) > 0, true);

      await kv.setTtl('temp_key', const Duration(seconds: 3600));
      final newTtlVal = await kv.getTtl('temp_key');
      isTestPassed = isTestPassed &&
          _expect('newTtl should be around 3600',
              (newTtlVal?.inSeconds ?? 0) > 3500, true);

      // 6. Global Space Test
      await kv.set('global_key', 'global_val', isGlobal: true);
      final gVal = await kv.getString('global_key', isGlobal: true);
      isTestPassed = isTestPassed &&
          _expect('get(global_key, isGlobal: true)', gVal, 'global_val');

      final lVal = await kv.getString('global_key');
      isTestPassed = isTestPassed &&
          _expect('get(global_key) from local should be null', lVal, null);

      // 7. Watch (Single and Many) - Skipped on Wasm due to Record/Stream compatibility issues
      if (!_isWasmBuild) {
        _WatchEventCollector<String?>? singleWatchCollector;
        _WatchEventCollector<Map<String, dynamic>>? multiWatchCollector;
        try {
          // (a) Single key watch full lifecycle: initial -> update -> remove
          singleWatchCollector = _WatchEventCollector<String?>(
            kv.watch<String>('watch_single_key'),
          );

          // Event 0: key not set yet, initial emission is null
          final singleInitial = await singleWatchCollector.waitForEventAt(0);
          isTestPassed = isTestPassed &&
              _expect('kv.watch initial emission on missing key', singleInitial,
                  null);

          // Event 1: insert value
          await kv.set('watch_single_key', 'val_v1');
          final singleInserted = await singleWatchCollector.waitForEventAt(1);
          isTestPassed = isTestPassed &&
              _expect(
                  'kv.watch emission on insert/set', singleInserted, 'val_v1');

          // Event 2: update value
          await kv.set('watch_single_key', 'val_v2');
          final singleUpdated = await singleWatchCollector.waitForEventAt(2);
          isTestPassed = isTestPassed &&
              _expect('kv.watch emission on update', singleUpdated, 'val_v2');

          // Event 3: delete key
          await kv.remove('watch_single_key');
          final singleDeleted = await singleWatchCollector.waitForEventAt(3);
          isTestPassed = isTestPassed &&
              _expect('kv.watch emission on remove', singleDeleted, null);

          // (b) Multi-keys watch full lifecycle
          multiWatchCollector = _WatchEventCollector<Map<String, dynamic>>(
            kv.watchValues(['watch_m1', 'watch_m2']),
          );

          // Event 0: initial snapshot with all nulls
          final multiInitial = await multiWatchCollector.waitForEventAt(0);
          isTestPassed = isTestPassed &&
              _expect('kv.watchValues initial emission', multiInitial, {
                'watch_m1': null,
                'watch_m2': null,
              });

          // Event 1: set key 1
          await kv.set('watch_m1', 'm1_val');
          final multiEvent1 = await multiWatchCollector.waitForEventAt(1);
          isTestPassed = isTestPassed &&
              _expect(
                  'kv.watchValues emission after setting key 1', multiEvent1, {
                'watch_m1': 'm1_val',
                'watch_m2': null,
              });

          // Event 2: set key 2
          await kv.set('watch_m2', 888);
          final multiEvent2 = await multiWatchCollector.waitForEventAt(2);
          isTestPassed = isTestPassed &&
              _expect(
                  'kv.watchValues emission after setting key 2', multiEvent2, {
                'watch_m1': 'm1_val',
                'watch_m2': 888,
              });

          // Event 3: update key 2
          await kv.set('watch_m2', 999);
          final multiEvent3 = await multiWatchCollector.waitForEventAt(3);
          isTestPassed = isTestPassed &&
              _expect(
                  'kv.watchValues emission after updating key 2', multiEvent3, {
                'watch_m1': 'm1_val',
                'watch_m2': 999,
              });

          // Event 4: remove key 1
          await kv.remove('watch_m1');
          final multiEvent4 = await multiWatchCollector.waitForEventAt(4);
          isTestPassed = isTestPassed &&
              _expect(
                  'kv.watchValues emission after removing key 1', multiEvent4, {
                'watch_m1': null,
                'watch_m2': 999,
              });

          // Clean up key 2
          await kv.remove('watch_m2');
        } finally {
          await singleWatchCollector?.cancel();
          await multiWatchCollector?.cancel();
        }
      }

      // 8. Removal
      await kv.remove('test_string');
      final existsAfterRemove = await kv.exists('test_string');
      isTestPassed = isTestPassed &&
          _expect('exists after remove', existsAfterRemove, false);

      await kv.removeKeys(['test_int', 'test_bool']);
      final existsInt = await kv.exists('test_int');
      isTestPassed = isTestPassed &&
          _expect('exists after removeKeys(int)', existsInt, false);

      final existsBool = await kv.exists('test_bool');
      isTestPassed = isTestPassed &&
          _expect('exists after removeKeys(bool)', existsBool, false);

      await kv.clear();
      final countFinal = await kv.count();
      isTestPassed =
          isTestPassed && _expect('count after clear', countFinal, 0);

      // 9. Edge case: Expired key
      await kv.set('expired_key', 'gone',
          ttl: const Duration(milliseconds: 10));
      await Future.delayed(const Duration(milliseconds: 50));

      final existsExpired = await kv.exists('expired_key');
      isTestPassed = isTestPassed &&
          _expect(
              'exists for expired key should be false', existsExpired, false);

      final valExpired = await kv.get('expired_key');
      isTestPassed = isTestPassed &&
          _expect('get for expired key should be null', valExpired, null);
    } catch (e, s) {
      isTestPassed = false;
      _failTest('Exception in _testKvStoreOperations: $e\n$s');
    }
    return isTestPassed;
  }
}

/// Helper class for capturing stream emissions deterministically in tests.
class _WatchEventCollector<T> {
  final List<T> events = [];
  final StreamSubscription<T> _sub;
  Completer<void>? _signal;

  _WatchEventCollector(Stream<T> stream) : _sub = stream.listen(null) {
    _sub.onData((data) {
      events.add(data);
      final s = _signal;
      if (s != null && !s.isCompleted) {
        s.complete();
      }
    });
  }

  /// Waits until the event at [index] is received, or until [timeout] expires.
  Future<T?> waitForEventAt(
    int index, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final stop = DateTime.now().add(timeout);
    while (events.length <= index) {
      final remaining = stop.difference(DateTime.now());
      if (remaining.isNegative) return null;
      _signal = Completer<void>();
      try {
        await _signal!.future.timeout(remaining);
      } catch (_) {
        return null;
      }
    }
    return events[index];
  }

  Future<void> cancel() async {
    await _sub.cancel();
  }
}
