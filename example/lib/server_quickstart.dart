import 'dart:developer';

import 'package:tostore/tostore.dart';

/// Server Quick Start Example
/// Demonstrates how to integrate and use Tostore in server-side applications
/// with distributed database capabilities and enterprise features
///

/// Call this function directly to run the full example
Future<void> serverMain() async {
  // Configure log callback to capture all database logs
  LogConfig.setConfig(
    enableLog: true,
    logLevel: LogLevel.debug,
    onLogHandler: (String message, LogType type, String label) {
      log(message,
          name: label); // Replace with the actual logging logic of your project
    },
  );

  try {
    // Initialize database
    await ServerDatabaseManager.initialize();
    log('✅ Database initialized successfully');

    // Initialize table schemas (in real project, this would come from frontend UI)
    await ServerSchemaManager.instance.initializeTables();
    log('✅ Table schemas initialized');

    // Run CRUD examples
    await ServerCRUDExamples.runExamples();
    log('✅ CRUD examples completed');

    // Run schema update examples
    await ServerSchemaManager.instance.runSchemaUpdateExamples();
    log('✅ Schema update examples completed');
  } catch (e) {
    log('❌ Error in server example: $e');
  } finally {
    // Clean up
    await ServerDatabaseManager.dispose();
  }
}

/// Server Database Configuration
/// Centralizes all database-related configurations for server environments
class ServerDatabaseConfig {
  static const String dbName = 'server_example';
  static const String encodingKey = 'ServerEncodingKey';
  static const String encryptionKey = 'ServerEncryptionKey';
  static const String centralServerUrl = 'http://127.0.0.1:8080';
  static const String accessToken = 'b7628a4f9b4d269b98649129';

  /// Get database configuration
  static DataStoreConfig get config => DataStoreConfig(
        enableLog: true,
        logLevel: LogLevel.warn,
        // Enable encoding and encryption
        encryptionConfig: const EncryptionConfig(
          encryptionType: EncryptionType.chacha20Poly1305,
          encodingKey: encodingKey,
          encryptionKey: encryptionKey,
        ),
        // Distributed mode configuration
        distributedNodeConfig: const DistributedNodeConfig(
          enableDistributed: true,
          clusterId: 1,
          centralServerUrl: centralServerUrl,
          accessToken: accessToken,
        ),
      );
}

/// Server Database Manager
/// Responsible for database initialization and lifecycle management in server environments
class ServerDatabaseManager {
  static ToStore? _db;
  static bool _isInitialized = false;

  /// Get database instance
  static ToStore get db {
    final instance = _db;
    if (instance == null) {
      throw StateError(
          'ServerDatabaseManager.initialize() must be called before use');
    }
    return instance;
  }

  /// Initialize the database
  static Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      _db = await ToStore.open(
        dbName: ServerDatabaseConfig.dbName,
        config: ServerDatabaseConfig.config,
      );
      _isInitialized = true;
    } catch (e) {
      log('Database initialization failed: $e');
      rethrow;
    }
  }

  /// Close the database connection
  static Future<void> dispose() async {
    if (_isInitialized && _db != null) {
      await _db!.close();
      _isInitialized = false;
      _db = null;
      log('🔒 Database connection closed');
    }
  }

  /// Check database status
  static bool get isInitialized => _isInitialized;
}

/// Server Schema Manager
///
/// ⚠️ Note: This class is only for demonstration purposes!
/// In a real project, the table structure should be generated from JSON through the frontend UI and then passed to the database instance.
/// Please replace this class with the frontend UI's table structure management logic.
class ServerSchemaManager {
  static ServerSchemaManager? _instance;
  late ToStore _db;

  ServerSchemaManager._();

  static ServerSchemaManager get instance {
    _instance ??= ServerSchemaManager._();
    return _instance!;
  }

  /// Initialize table schemas
  /// In real project, this would receive JSON from frontend UI
  Future<void> initializeTables() async {
    _db = ServerDatabaseManager.db;

    // Example: Create tables from JSON schema (simulating frontend UI data)
    final tableSchemas = _getExampleTableSchemas();

    for (final schemaJson in tableSchemas) {
      // Parse JSON to TableSchema
      final schema = TableSchema.fromJson(schemaJson);

      // Create table
      await _db.createTable(schema);
      log('📋 Created table: ${schema.name}');
    }
  }

  /// Get example table schemas (simulating frontend UI JSON data)
  /// In real project, this would come from frontend UI operations
  List<Map<String, dynamic>> _getExampleTableSchemas() {
    return [
      // Users table schema
      {
        'name': 'users',
        'primaryKeyConfig': {
          'name': 'id',
          'type': 'sequential',
          'sequentialConfig': {
            'initialValue': 10000000,
            'increment': 12333,
            'useRandomIncrement': true,
          }
        },
        'fields': [
          {
            'name': 'username',
            'type': 'text',
            'nullable': false,
            'unique': true,
            'maxLength': 50,
          },
          {
            'name': 'email',
            'type': 'text',
            'nullable': false,
            'unique': true,
            'maxLength': 100,
          },
          {
            'name': 'status',
            'type': 'text',
            'nullable': false,
            'defaultValue': 'active',
          },
          {
            'name': 'created_at',
            'type': 'datetime',
            'nullable': false,
            'defaultValueType': 'currentTimestamp',
          },
          {
            'name': 'updated_at',
            'type': 'datetime',
            'nullable': false,
            'defaultValueType': 'currentTimestamp',
          },
        ],
        'indexes': [
          {
            'fields': ['username'],
            'unique': true,
          },
          {
            'fields': ['email'],
            'unique': true,
          },
          {
            'fields': ['status'],
            'unique': false,
          },
        ],
        'isGlobal': false,
      },

      // Products table schema
      {
        'name': 'products',
        'primaryKeyConfig': {
          'name': 'id',
          'type': 'timestampBased',
        },
        'fields': [
          {
            'name': 'name',
            'type': 'text',
            'nullable': false,
            'maxLength': 200,
          },
          {
            'name': 'description',
            'type': 'text',
            'nullable': true,
          },
          {
            'name': 'price',
            'type': 'double',
            'nullable': false,
            'minValue': 0.0,
          },
          {
            'name': 'category',
            'type': 'text',
            'nullable': false,
          },
          {
            'name': 'stock',
            'type': 'integer',
            'nullable': false,
            'defaultValue': 0,
            'minValue': 0,
          },
          {
            'name': 'created_at',
            'type': 'datetime',
            'nullable': false,
            'defaultValueType': 'currentTimestamp',
          },
        ],
        'indexes': [
          {
            'fields': ['name'],
            'unique': false,
          },
          {
            'fields': ['category'],
            'unique': false,
          },
          {
            'fields': ['price'],
            'unique': false,
          },
        ],
        'isGlobal': false,
      },

      // Global settings table
      {
        'name': 'settings',
        'primaryKeyConfig': {
          'name': 'id',
          'type': 'none',
        },
        'fields': [
          {
            'name': 'key',
            'type': 'text',
            'nullable': false,
            'unique': true,
            'maxLength': 100,
          },
          {
            'name': 'value',
            'type': 'text',
            'nullable': true,
          },
          {
            'name': 'updated_at',
            'type': 'datetime',
            'nullable': false,
            'defaultValueType': 'currentTimestamp',
          },
        ],
        'indexes': [
          {
            'fields': ['key'],
            'unique': true,
          },
        ],
        'isGlobal': true,
      },
    ];
  }

  /// Run schema update examples
  Future<void> runSchemaUpdateExamples() async {
    log('🔄 Running schema update examples...');

    // Example 1: Add new field to users table
    final taskId1 = await _db
        .updateSchema('users')
        .addField('phone', type: DataType.text)
        .addField('avatar_url', type: DataType.text)
        .addIndex(fields: ['phone'], unique: true);

    log('📝 Schema update task 1 created: $taskId1');

    // Example 2: Modify existing field
    final taskId2 = await _db
        .updateSchema('products')
        .modifyField('name', maxLength: 300)
        .addField('tags', type: DataType.array)
        .addField('metadata', type: DataType.json);

    log('📝 Schema update task 2 created: $taskId2');

    // Example 3: Rename field and table
    final taskId3 = await _db
        .updateSchema('products')
        .renameField('description', 'product_description')
        .renameTable('inventory_items');

    log('📝 Schema update task 3 created: $taskId3');

    // Check migration status
    await _checkMigrationStatus([taskId1, taskId2, taskId3]);
  }

  /// Check migration task status
  Future<void> _checkMigrationStatus(List<String> taskIds) async {
    for (final taskId in taskIds) {
      final status = await _db.queryMigrationTaskStatus(taskId);
      if (status != null) {
        log('📊 Migration task $taskId: ${status.progressPercentage}% complete');
      }
    }
  }
}

/// Server CRUD Examples
/// Demonstrates basic database operations in server environments
class ServerCRUDExamples {
  static late ToStore _db;

  /// Run all CRUD examples
  static Future<void> runExamples() async {
    _db = ServerDatabaseManager.db;

    log('🔄 Running CRUD examples...');

    await _userExamples();
    await _productExamples();
    await _settingsExamples();
    await _batchOperations();
    await _queryExamples();
  }

  /// User table CRUD examples
  static Future<void> _userExamples() async {
    log('👥 User CRUD examples...');

    // Create users
    final user1 = await _db.insert('users', {
      'username': 'john_doe',
      'email': 'john@example.com',
      'status': 'active',
    });
    log('✅ Created user: ${user1.successKeys}');

    final user2 = await _db.insert('users', {
      'username': 'jane_smith',
      'email': 'jane@example.com',
      'status': 'active',
    });
    log('✅ Created user: ${user2.successKeys}');

    // Query users
    final activeUsers = await _db
        .query('users')
        .where('status', '=', 'active')
        .orderByDesc('created_at');
    log('📋 Active users: ${activeUsers.length}');

    // Update user
    await _db.update('users', {
      'status': 'inactive',
      'updated_at': DateTime.now().toIso8601String(),
    }).where('username', '=', 'john_doe');

    // Delete user
    await _db.delete('users').where('username', '=', 'jane_smith');
  }

  /// Product table CRUD examples
  static Future<void> _productExamples() async {
    log('📦 Product CRUD examples...');

    // Create products
    final products = [
      {
        'name': 'Laptop Pro',
        'description': 'High-performance laptop',
        'price': 1299.99,
        'category': 'electronics',
        'stock': 50,
      },
      {
        'name': 'Wireless Mouse',
        'description': 'Ergonomic wireless mouse',
        'price': 29.99,
        'category': 'accessories',
        'stock': 100,
      },
      {
        'name': 'Coffee Mug',
        'description': 'Ceramic coffee mug',
        'price': 12.99,
        'category': 'kitchen',
        'stock': 200,
      },
    ];

    for (final product in products) {
      final result = await _db.insert('products', product);
      log('✅ Created product: ${result.successKeys}');
    }

    // Query products by category
    final electronics = await _db
        .query('products')
        .where('category', '=', 'electronics')
        .orderByDesc('price');
    log('📋 Electronics products: ${electronics.length}');

    // Update product price
    await _db.update('products', {
      'price': 1199.99,
    }).where('name', '=', 'Laptop Pro');

    // Upsert product (insert or update)
    await _db.upsert('products', {
      'name': 'Laptop Pro',
      'price': 1099.99,
      'stock': 45,
    }).where('name', '=', 'Laptop Pro');
  }

  /// Global settings examples
  static Future<void> _settingsExamples() async {
    log('⚙️ Settings examples...');

    // Set global settings
    await _db.setValue('server_version', '1.0.0', isGlobal: true);
    await _db.setValue('maintenance_mode', 'false', isGlobal: true);
    await _db.setValue('max_file_size', '10MB', isGlobal: true);

    // Get global settings
    final version = await _db.getValue('server_version', isGlobal: true);
    final maintenanceMode =
        await _db.getValue('maintenance_mode', isGlobal: true);

    log('📋 Server version: $version');
    log('📋 Maintenance mode: $maintenanceMode');

    // Update setting
    await _db.setValue('maintenance_mode', 'true', isGlobal: true);
    log('✅ Updated maintenance mode');
  }

  /// Batch operations examples
  static Future<void> _batchOperations() async {
    log('📦 Batch operations examples...');

    // Batch insert users
    final users = List.generate(
        10,
        (index) => {
              'username': 'batch_user_$index',
              'email': 'batch$index@example.com',
              'status': 'active',
            });

    final batchResult = await _db.batchInsert('users', users);
    log('✅ Batch inserted ${batchResult.successCount} users');

    // Batch update
    await _db.update('users', {
      'status': 'verified',
    }).where('username', 'like', 'batch_user_%');
    log('✅ Batch updated users');
  }

  /// Advanced query examples
  static Future<void> _queryExamples() async {
    log('🔍 Advanced query examples...');

    // Complex query with conditions
    final expensiveProducts = await _db
        .query('products')
        .where('price', '>', 100.0)
        .or()
        .where('stock', '>', 0)
        .orderByDesc('price')
        .limit(10);

    log('📋 Expensive products: ${expensiveProducts.length}');

    // Count query
    final totalProducts = await _db.query('products').count();
    log('📊 Total products: $totalProducts');

    // Search with LIKE
    final searchResults = await _db
        .query('products')
        .where('name', 'like', '%laptop%')
        .or()
        .where('description', 'like', '%laptop%');

    log('🔍 Search results: ${searchResults.length}');
  }
}
