import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:tostore/tostore.dart';

/// This example demonstrates the core features of Tostore using a user management system
/// with global settings. It shows how to:
/// - Create tables (both regular and global)
/// - Work with multi-space architecture
/// - Distributed example
/// - Handle global data
class TostoreExample {
  late ToStore db;

  /// Initialize database and create tables
  Future<void> initialize() async {
    db = ToStore(
      schemas: [
        // suitable for table structure definition in frequent startup scenarios of mobile applications, accurately identifying table structure changes, automatically upgrading and migrating data
        const TableSchema(
          name: 'users',
          primaryKeyConfig: PrimaryKeyConfig(
            name: 'id',
          ),
          fields: [
            FieldSchema(name: 'username', type: DataType.text, nullable: false),
            FieldSchema(name: 'email', type: DataType.text, nullable: false),
            FieldSchema(name: 'last_login', type: DataType.datetime),
          ],
          indexes: [
            IndexSchema(fields: ['username'], unique: true),
            IndexSchema(fields: ['email'], unique: true),
            IndexSchema(fields: ['last_login'], unique: false),
          ],
        ),
        const TableSchema(
          name: 'settings',
          primaryKeyConfig: PrimaryKeyConfig(),
          isGlobal: true,
          fields: [
            FieldSchema(
                name: 'key',
                type: DataType.text,
                nullable: false,
                unique: true),
            FieldSchema(name: 'value', type: DataType.text),
            FieldSchema(name: 'updated_at', type: DataType.datetime),
          ],
          indexes: [
            IndexSchema(fields: ['key'], unique: true),
            IndexSchema(fields: ['updated_at'], unique: false),
          ],
        ),
      ],
    );
    await db.initialize();
  }

  /// Example: Basic CRUD operations for users
  Future<void> userExamples() async {
    // Create: Insert a new user
    await db.insert('users', {
      'username': 'john_doe',
      'email': 'john@example.com',
      'last_login': DateTime.now().toIso8601String(),
    });

    // Read: Query user using chain style
    await db.query('users').where('username', '=', 'john_doe');

    // Update: Modify user data
    await db.update('users', {
      'last_login': DateTime.now().toIso8601String(),
    }).where('username', '=', 'john_doe');

    // Automatically store data,Support batch upsert
    await db.upsert('users', {'name': 'John'}).where(
        'email', '=', 'john@example.com');

    // Auto insert or update based on primary key
    await db.upsert(
        'users', {'id': 1, 'name': 'John', 'email': 'john@example.com'});

    // Delete: Remove user
    await db.delete('users').where('username', '=', 'john_doe');

    // use stream query to handle large data
    db
        .streamQuery('users')
        .where('email', 'like', '%@example.com')
        .listen((userData) {
      // handle each data as needed, avoid memory pressure
      log('handle user: ${userData['username']}');
    });
  }

  /// Example: Working with global settings
  Future<void> settingsExamples() async {
    // Set global theme (accessible from any space)
    await db.insert('settings', {
      'key': 'theme',
      'value': 'dark',
      'updated_at': DateTime.now().toIso8601String(),
    });

    // Alternative: Using setValue for simple key-value storage
    await db.setValue('language', 'en', isGlobal: true);

    // Read settings using different methods
    await db.query('settings').where('key', '=', 'theme');

    await db.getValue('language', isGlobal: true);

    // Update setting with conflict resolution
    await db.update('settings', {
      'value': 'light',
      'updated_at': DateTime.now().toIso8601String(),
    }).where('key', '=', 'theme');

    // Delete setting
    await db.delete('settings').where('key', '=', 'theme');
  }

  /// Example: Multi-space feature for user data isolation
  Future<void> multiSpaceExamples() async {
    // Switch to user1's space
    await db.switchSpace(spaceName: 'user1');
    await db.insert('users', {
      'username': 'user1',
      'email': 'user1@example.com',
      'last_login': DateTime.now().toIso8601String(),
    });

    // Switch to user2's space
    await db.switchSpace(spaceName: 'user2');
    await db.insert('users', {
      'username': 'user2',
      'email': 'user2@example.com',
      'last_login': DateTime.now().toIso8601String(),
    });

    // Global settings remain accessible in any space
    await db.getValue('theme', isGlobal: true);

    // get current space info
    final spaceInfo = await db.getSpaceInfo();
    log("${spaceInfo.toJson()}");
  }

  /// Example: Advanced queries
  Future<void> advancedQueryExamples() async {
    // Complex conditions
    await db
        .query('users')
        .where(
            'last_login',
            '>',
            DateTime.now()
                .subtract(
                  const Duration(days: 7),
                )
                .toIso8601String())
        .or()
        .where('email', 'LIKE', '%@example.com')
        .orderByDesc('last_login')
        .limit(10);

    // Count users
    await db.query('users').count();

    // Batch operations
    await db.batchInsert('users', [
      {
        'username': 'user3',
        'email': 'user3@example.com',
        'last_login': DateTime.now().toIso8601String(),
      },
      {
        'username': 'user4',
        'email': 'user4@example.com',
        'last_login': DateTime.now().toIso8601String(),
      },
    ]);
  }

  /// Example: Backup and restore
  Future<void> backupExample() async {
    // Create backup
    final backupPath = await db.backup();

    // Restore from backup
    await db.restore(backupPath);
  }

  /// backend server or distributed example
  Future<void> distributedExample() async {
    // create database instance
    final db = ToStore(
      config: DataStoreConfig(
          enableEncoding: true, // enable security encoding for table data
          encodingKey: 'YouEncodingKey', // encoding key, can be adjusted
          encryptionKey:
              'YouEncryptionKey', // encryption key, note: adjusting this key will make it impossible to decode old data
          distributedNodeConfig: const DistributedNodeConfig(
            enableDistributed: true, // enable distributed mode
            clusterId: 1, // configure cluster id
            centralServerUrl: 'http://127.0.0.1:8080',
            accessToken: 'b7628a4f9b4d269b98649129',
          )),
    );

    // create tables
    await db.createTables([
      const TableSchema(
          name: 'users',
          primaryKeyConfig: PrimaryKeyConfig(
            name: 'id',
            type: PrimaryKeyType.sequential, // sequential key type
            sequentialConfig: SequentialIdConfig(
              initialValue: 10000, // initial value
              increment: 50, // increment
              useRandomIncrement:
                  true, // use random increment, avoid exposing business volume
            ),
          ),
          // field and index definition ...
          fields: []),
      const TableSchema(
          name: 'vector',
          primaryKeyConfig: PrimaryKeyConfig(
            name: 'vector_id',
            type: PrimaryKeyType.timestampBased, // timestamp based key type
          ),
          // field and index definition ...
          fields: [
            FieldSchema(
              name: 'vector_data',
              type: DataType.blob, // vector data
            ),
          ]),
      // other tables ...
    ]);

    // update table structure
    final taskId = await db
        .updateSchema('users')
        .renameTable('newTableName') // rename table
        .modifyField('username',
            minLength: 5,
            maxLength: 20,
            unique: true) // modify field attributes
        .renameField('oldName', 'newName') // rename field
        .removeField('fieldName') // remove field
        .addField('name', type: DataType.text) // add field
        .removeIndex(fields: ['age']) // remove index
        .setPrimaryKeyConfig(// set primary key config
            const PrimaryKeyConfig(type: PrimaryKeyType.shortCode));

    // query migration task status
    final status = await db.queryMigrationTaskStatus(taskId);
    log('migration progress: ${status?.progressPercentage}%');
  }
}

/// Simple UI to run examples
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final example = TostoreExample();
  await example.initialize();

  // Run examples
  await example.userExamples();
  await example.settingsExamples();
  await example.multiSpaceExamples();
  await example.advancedQueryExamples();
  await example.backupExample();

  runApp(const MaterialApp(
    home: Scaffold(
      body: Center(
        child: Text('Check console for example outputs'),
      ),
    ),
  ));
}
