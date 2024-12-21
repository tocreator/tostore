import 'package:flutter/material.dart';
import 'package:tostore/tostore.dart';

/// This example demonstrates the core features of Tostore using a user management system
/// with global settings. It shows how to:
/// - Create tables (both regular and global)
/// - Perform CRUD operations
/// - Use different query styles
/// - Work with multi-space architecture
/// - Handle global data
class TostoreExample {
  late ToStore db;

  /// Initialize database and create tables
  Future<void> initialize() async {
    db = ToStore(
      version: 1,
      onCreate: (db) async {
        // Create users table
        await db.createTable(
          'users',
          const TableSchema(
            primaryKey: 'id',
            fields: [
              FieldSchema(name: 'id', type: DataType.integer, nullable: false),
              FieldSchema(
                  name: 'username', type: DataType.text, nullable: false),
              FieldSchema(name: 'email', type: DataType.text, nullable: false),
              FieldSchema(name: 'last_login', type: DataType.datetime),
            ],
            indexes: [
              IndexSchema(fields: ['username'], unique: true),
              IndexSchema(fields: ['email'], unique: true),
            ],
          ),
        );

        // Create settings table (global table, shared across all spaces)
        await db.createTable(
          'settings',
          const TableSchema(
            primaryKey: 'key',
            isGlobal: true,
            fields: [
              FieldSchema(name: 'key', type: DataType.text, nullable: false),
              FieldSchema(name: 'value', type: DataType.text),
              FieldSchema(name: 'updated_at', type: DataType.datetime),
            ],
          ),
        );
      },
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

    // Delete: Remove user
    await db.delete('users').where('username', '=', 'john_doe');

    // Read: Query using SQL style
    await db.queryBySql(
      'users',
      where: 'email = ?',
      whereArgs: ['john@example.com'],
    );

    // Read: Query using Map style
    await db.queryByMap(
      'users',
      where: {'username': 'john_doe'},
    );
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
    await db.switchBaseSpace(spaceName: 'user1');
    await db.insert('users', {
      'username': 'user1',
      'email': 'user1@example.com',
      'last_login': DateTime.now().toIso8601String(),
    });

    // Switch to user2's space
    await db.switchBaseSpace(spaceName: 'user2');
    await db.insert('users', {
      'username': 'user2',
      'email': 'user2@example.com',
      'last_login': DateTime.now().toIso8601String(),
    });

    // Global settings remain accessible in any space
    await db.getValue('theme', isGlobal: true);
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