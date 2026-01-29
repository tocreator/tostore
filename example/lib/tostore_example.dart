import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tostore/tostore.dart';
import 'package:path/path.dart' as p;
import 'dart:math';

import 'testing/log_service.dart';

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
    String dbRoot;
    if (kIsWeb) {
      dbRoot = 'common';
    } else {
      try {
        // Resolve app documents directory via path_provider and inject into tostore
        final docDir = await getApplicationDocumentsDirectory();
        dbRoot = p.join(docDir.path,
            'common'); // tostore: ^2.2.2 version default dbPath is getApplicationDocumentsDirectory()/common
      } catch (e) {
        dbRoot = 'common';
      }
    }

    db = await ToStore.open(
      dbPath: dbRoot,
      dbName: 'tostore_example',
      config: DataStoreConfig(
        enableLog: true,
        logLevel: LogLevel.debug,
        enableJournal: true,
        encryptionConfig: const EncryptionConfig(
          encryptionType: EncryptionType.none,
        ),
      ),
      schemas: [
        // suitable for table structure definition in frequent startup scenarios of mobile applications, accurately identifying table structure changes, automatically upgrading and migrating data
        const TableSchema(
          name: 'users',
          primaryKeyConfig:
              PrimaryKeyConfig(name: 'id', type: PrimaryKeyType.sequential),
          fields: [
            FieldSchema(name: 'username', type: DataType.text, nullable: false),
            FieldSchema(name: 'email', type: DataType.text, nullable: false),
            FieldSchema(
                name: 'last_login',
                type: DataType.datetime,
                defaultValueType: DefaultValueType.currentTimestamp),
            FieldSchema(
                name: 'is_active', type: DataType.boolean, defaultValue: true),
            FieldSchema(name: 'age', type: DataType.integer, defaultValue: 18),
            FieldSchema(name: 'tags', type: DataType.text),
            FieldSchema(
                name: 'type', type: DataType.text, defaultValue: 'user'),
            FieldSchema(name: 'fans', type: DataType.integer, defaultValue: 10),
          ],
          indexes: [
            IndexSchema(fields: ['username'], unique: true),
            IndexSchema(fields: ['email'], unique: true),
            IndexSchema(fields: ['last_login'], unique: false),
            IndexSchema(fields: ['age']),
          ],
        ),
        TableSchema(
          name: 'posts',
          primaryKeyConfig: const PrimaryKeyConfig(
            name: 'id',
          ),
          fields: [
            const FieldSchema(
                name: 'title', type: DataType.text, nullable: false),
            const FieldSchema(name: 'content', type: DataType.text),
            const FieldSchema(
                name: 'user_id', type: DataType.integer, nullable: false),
            const FieldSchema(
                name: 'created_at',
                type: DataType.datetime,
                defaultValueType: DefaultValueType.currentTimestamp),
            const FieldSchema(
                name: 'is_published',
                type: DataType.boolean,
                defaultValue: true),
          ],
          foreignKeys: [
            ForeignKeySchema(
              name: 'fk_posts_user',
              fields: ['user_id'],
              referencedTable: 'users',
              referencedFields: ['id'],
              onDelete: ForeignKeyCascadeAction.cascade,
              onUpdate: ForeignKeyCascadeAction.cascade,
            ),
          ],
          indexes: [
            const IndexSchema(fields: ['user_id']),
            const IndexSchema(fields: ['created_at']),
          ],
        ),
        TableSchema(
          name: 'comments',
          primaryKeyConfig: const PrimaryKeyConfig(
            name: 'id',
          ),
          fields: [
            const FieldSchema(
                name: 'post_id', type: DataType.integer, nullable: false),
            const FieldSchema(
                name: 'user_id', type: DataType.integer, nullable: false),
            const FieldSchema(
                name: 'content', type: DataType.text, nullable: false),
            const FieldSchema(
                name: 'created_at',
                type: DataType.datetime,
                defaultValueType: DefaultValueType.currentTimestamp),
          ],
          foreignKeys: [
            ForeignKeySchema(
              name: 'fk_comments_post',
              fields: ['post_id'],
              referencedTable: 'posts',
              referencedFields: ['id'],
              onDelete: ForeignKeyCascadeAction.cascade,
              onUpdate: ForeignKeyCascadeAction.cascade,
            ),
            ForeignKeySchema(
              name: 'fk_comments_user',
              fields: ['user_id'],
              referencedTable: 'users',
              referencedFields: ['id'],
              onDelete: ForeignKeyCascadeAction.restrict,
              onUpdate: ForeignKeyCascadeAction.cascade,
            ),
          ],
          indexes: [
            const IndexSchema(fields: ['post_id']),
            const IndexSchema(fields: ['user_id']),
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
            FieldSchema(
                name: 'updated_at',
                type: DataType.datetime,
                defaultValueType: DefaultValueType.currentTimestamp),
          ],
          indexes: [
            IndexSchema(fields: ['key'], unique: true),
            IndexSchema(fields: ['updated_at'], unique: false),
          ],
        ),
      ],
    );
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
      logService.add('handle user: ${userData['username']}');
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
    logService.add("${spaceInfo.toJson()}");
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
    final backupPath = await db.backup(compress: false);
    logService.add('Backup created at: $backupPath');

    // Restore from backup
    await db.restore(backupPath, deleteAfterRestore: true);
  }

  /// Example: Working with vector data
  Future<void> vectorExamples() async {
    // create table structure
    await db.createTables([
      const TableSchema(
        name: 'embeddings',
        primaryKeyConfig: PrimaryKeyConfig(
          name: 'id',
          type: PrimaryKeyType.timestampBased,
        ),
        fields: [
          FieldSchema(
            name: 'document_title',
            type: DataType.text,
            nullable: false,
          ),
          FieldSchema(
            name: 'embedding',
            type: DataType.vector,
            vectorConfig: VectorFieldConfig(
              dimensions: 1536, // 1536 dimensions
              precision: VectorPrecision.float64, // 64-bit precision
            ),
          ),
        ],
        indexes: [
          IndexSchema(
            fields: ['embedding'],
            type: IndexType.vector,
            vectorConfig: VectorIndexConfig(
              indexType:
                  VectorIndexType.hnsw, // HNSW for fast approximate search
              distanceMetric: VectorDistanceMetric.cosine, // Cosine similarity
              parameters: {
                'M': 16, // Max number of connections per layer
                'efConstruction': 200, // Controls index quality
                'efSearch': 100, // Controls search accuracy/speed trade-off
              },
            ),
          ),
        ],
      ),
    ]);

    // create vector data
    final sampleVector1 = VectorData.fromList([0.1, 0.2, 0.3, 0.4]);
    final sampleVector2 = VectorData.fromList([0.5, 0.6, 0.7, 0.8]);

    // store documents with vector embeddings
    await db.insert('embeddings', {
      'document_title': 'Introduction to vector databases',
      'embedding': sampleVector1,
    });

    await db.insert('embeddings', {
      'document_title': 'Machine Learning with embeddings',
      'embedding': sampleVector2,
    });

    // query stored vector data
    final result = await db.query('embeddings');
    final documents = result.data;
    List<VectorData> vectors = [];

    for (var doc in documents) {
      if (doc['embedding'] is List) {
        VectorData vector =
            VectorData.fromJson(doc['embedding'] as List<dynamic>);
        vectors.add(vector);
        doc['embedding'] = vector;

        logService.add(
            'document title: ${doc['document_title']}, vector dimensions: ${vector.dimensions}');
      }
    }

    // at least two vectors can be compared
    if (vectors.length >= 2) {
      final vector1 = vectors[0];
      final vector2 = vectors[1];

      logService.add('vector1: ${vector1.toString()}');
      logService.add('vector2: ${vector2.toString()}');

      // calculate vector similarity
      final similarity = vector1.cosineSimilarity(vector2);
      logService.add('vector similarity: $similarity');

      // calculate euclidean distance
      final distance = vector1.euclideanDistance(vector2);
      logService.add('vector distance: $distance');
    } else {
      logService.add('not enough vector data for comparison');
    }
  }

  /// backend server or distributed example
  Future<void> distributedExample() async {
    // create database instance
    final db = await ToStore.open(
      config: DataStoreConfig(
        encryptionConfig: const EncryptionConfig(
          encryptionType: EncryptionType
              .chacha20Poly1305, // enable security encoding for data
          encodingKey: 'YouEncodingKey', // encoding key, can be adjusted
          encryptionKey:
              'YouEncryptionKey', // encryption key, note: adjusting this key will make it impossible to decode old data
        ),
        distributedNodeConfig: const DistributedNodeConfig(
          enableDistributed: true, // enable distributed mode
          clusterId: 1, // configure cluster id
          centralServerUrl: 'http://127.0.0.1:8080',
          accessToken: 'b7628a4f9b4d269b98649129',
        ),
        enableLog: true, // enable log
        logLevel: LogLevel.warn, // log level
      ),
    );

    // create tables
    await db.createTables(
      [
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
      ],
      // other tables ...
    );

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
    logService.add('migration progress: ${status?.progressPercentage}%');
  }

  /// Example: Complex nested queries with predefined conditions
  Future<void> complexQueryExamples() async {
    // prepare some test data
    await db.insert('users', {
      'username': 'active_user',
      'email': 'active@example.com',
      'is_active': true,
      'age': 25,
      'type': 'app',
      'fans': 300,
      'tags': 'recommend,hot,featured',
      'last_login': DateTime.now().toIso8601String(),
    });

    await db.insert('users', {
      'username': 'inactive_user',
      'email': 'inactive@example.com',
      'is_active': false,
      'age': 30,
      'type': 'web',
      'fans': 150,
      'tags': 'normal,newbie',
      'last_login':
          DateTime.now().subtract(const Duration(days: 30)).toIso8601String(),
    });

    // complex query condition nesting - pre-defined query condition module
    final recentLoginCondition = QueryCondition().where('fans', '>=', 200);

    final idCondition = QueryCondition()
        .where('id', '>=', 1)
        .orCondition(// orCondition is equivalent to OR condition combination
            recentLoginCondition);

    // custom condition function - flexible handling of any complex logic
    final customCondition = QueryCondition().whereCustom((record) {
      // for example: check if the tag contains 'recommend'
      return record['tags'] != null &&
          record['tags'].toString().contains('recommend');
    });

    // query condition nesting example - show infinite nesting ability
    final result = await db
        .query('users')
        .where('is_active', '=', true)
        .condition(QueryCondition() // query condition construction
                .whereEqual('type', 'app')
                .condition(idCondition) // nest again the defined conditions
            )
        .orCondition(customCondition) // or satisfy custom complex conditions
        .limit(20);

    for (var user in result.data) {
      logService.add(
          'user: ${user['username']}, type: ${user['type']}, fans: ${user['fans']}, tags: ${user['tags']}');
    }

    // equivalent SQL:
    // SELECT * FROM users
    // WHERE is_active = true
    //   AND (type = 'app' OR id >= 1 OR fans >= 200)
    //   OR ([custom condition: tag contains 'recommend'])
    // LIMIT 20
  }

  Future<int> clearExamples() async {
    final stopwatch = Stopwatch()..start();
    await db.clear('users');
    await db.clear('posts');
    await db.clear('comments');
    stopwatch.stop();
    final elapsed = stopwatch.elapsedMilliseconds;
    logService
        .add('Table "users", "posts" and "comments" cleared in ${elapsed}ms');
    return elapsed;
  }

  /// Example: Join queries with table relationships
  Future<void> joinQueryExamples() async {
    // prepare test data
    // insert user
    await db.insert('users', {
      'username': 'blogger',
      'email': 'blogger@example.com',
      'is_active': true,
    });

    // insert post
    await db.insert('posts', {
      'title': 'how to use join to query',
      'content': 'this is a post about join...',
      'user_id': 1,
      'created_at': DateTime.now().toIso8601String(),
    });

    // insert comment
    await db.insert('comments', {
      'post_id': 1,
      'user_id': 1,
      'content': 'this is my own post comment',
      'created_at': DateTime.now().toIso8601String(),
    });

    // multi-table join query - post, author and comment
    final postsWithComments = await db
        .query('posts')
        .select([
          'posts.id as post_id',
          'posts.title',
          'users.username as author',
          'comments.content as comment',
          'comments.created_at as comment_time'
        ])
        .join('users', 'posts.user_id', '=', 'users.id')
        .join('comments', 'posts.user_id', '=', 'comments.user_id')
        .where('posts.is_published', '=', true)
        .orderByDesc('comments.created_at');

    for (var item in postsWithComments.data) {
      logService.add(
          'post: ${item['title']}, author: ${item['author']}, comment: ${item['comment']}');
    }
  }

  /// Generates a single mock data record based on a table's schema.
  ///
  Map<String, dynamic> _generateRecord(
    TableSchema schema,
    int index, {
    Map<String, dynamic>? foreignKeyValues,
    Map<String, ForeignKeyMode>? foreignKeyModes,
    Map<String, List<dynamic>>? foreignKeyIdLists,
  }) {
    final record = <String, dynamic>{};
    final random = Random();

    // Build foreign key field set for fast lookup
    final foreignKeyFields = <String>{};
    for (final fk in schema.foreignKeys) {
      if (fk.enabled) {
        foreignKeyFields.addAll(fk.fields);
      }
    }

    for (final field in schema.fields) {
      // We don't generate data for the primary key if it's auto-incrementing.
      // The database will handle it.
      if (field.name == schema.primaryKeyConfig.name) {
        continue;
      }

      // If the field is a foreign key field
      if (foreignKeyFields.contains(field.name)) {
        final mode = foreignKeyModes?[field.name] ?? ForeignKeyMode.fixed;
        final idList = foreignKeyIdLists?[field.name];

        if (mode == ForeignKeyMode.random &&
            idList != null &&
            idList.isNotEmpty) {
          // Random mode: select a random ID from the ID list
          record[field.name] = idList[random.nextInt(idList.length)];
        } else if (foreignKeyValues != null &&
            foreignKeyValues.containsKey(field.name)) {
          // Fixed mode: use the provided fixed value
          record[field.name] = foreignKeyValues[field.name];
        } else {
          // If no foreign key value is provided, record a warning but continue (database will validate)
          logService.add(
              'Warning: Foreign key field "${field.name}" in table "${schema.name}" has no provided value.',
              LogType.warn);
        }
        continue;
      }

      // If the field is a foreign key and has a provided foreign key value, use the provided value (compatible with old logic)
      if (foreignKeyValues != null &&
          foreignKeyValues.containsKey(field.name)) {
        record[field.name] = foreignKeyValues[field.name];
        continue;
      }

      // Generate data based on field name patterns for more realistic mock data
      if (field.name.contains('email')) {
        record[field.name] = 'user_$index@example.com';
        continue;
      }
      if (field.name.contains('name') || field.name.contains('title')) {
        record[field.name] = '${field.name}_$index';
        continue;
      }
      if (field.name.contains('content') ||
          field.name.contains('description')) {
        record[field.name] =
            'This is the content for ${schema.name} record $index';
        continue;
      }
      if (field.name.contains('age')) {
        record[field.name] = random.nextInt(100);
        continue;
      }

      // Generate data based on field type
      switch (field.type) {
        case DataType.text:
          record[field.name] = '${field.name}_$index';
          break;
        case DataType.bigInt:
        case DataType.integer:
          record[field.name] = random.nextInt(10000);
          break;
        case DataType.double:
          record[field.name] = random.nextDouble() * 1000;
          break;
        case DataType.boolean:
          record[field.name] = random.nextBool();
          break;
        case DataType.datetime:
          break;
        case DataType.vector:
        // Skip vector for now as it requires specific dimensions
        case DataType.blob:
        // Skip blob for mock data generation
        case DataType.array:
        // Skip array for mock data generation
        case DataType.json:
          // Skip json for mock data generation
          break;
      }
    }
    return record;
  }

  /// Adds a specified number of example records to a given table using batch inserts.
  Future<int> addExamples(
    String tableName,
    int count, {
    Map<String, dynamic>? foreignKeyValues,
    Map<String, ForeignKeyMode>? foreignKeyModes,
    Map<String, List<dynamic>>? foreignKeyIdLists,
  }) async {
    final schema = await db.getTableSchema(tableName);
    if (schema == null) {
      logService.add(
          'Cannot add examples: Schema for table "$tableName" not found.',
          LogType.error);
      return -1;
    }

    // Get current max ID to ensure field values (email, username, etc.)
    // have sequential numbers matching the primary key IDs
    // Note: This is only used for generating field values, NOT for setting primary key
    // Primary key will be auto-generated by the database system
    int baseIndex = 0;
    if (schema.primaryKeyConfig.type == PrimaryKeyType.sequential) {
      try {
        final lastResult = await db
            .query(tableName)
            .orderByDesc(schema.primaryKeyConfig.name)
            .select([schema.primaryKeyConfig.name]).limit(1);
        if (lastResult.data.isNotEmpty) {
          final lastId = lastResult.data.first[schema.primaryKeyConfig.name];
          if (lastId != null) {
            baseIndex = int.tryParse(lastId.toString()) ?? 0;
          }
        }
      } catch (e) {
        // If query fails, start from 0 (will use initial value from schema)
        logService.add(
            'Warning: Failed to query max ID for field value generation: $e',
            LogType.warn);
      }
    }

    // Prepare all records at once to avoid multiple batch splits
    // This improves performance by reducing the number of batchInsert calls
    final records = <Map<String, dynamic>>[];
    for (var i = 0; i < count; i++) {
      // Use baseIndex + i + 1 to generate field values that match primary key IDs
      // Primary key will be auto-generated by the database system
      records.add(_generateRecord(
        schema,
        baseIndex + i + 1,
        foreignKeyValues: foreignKeyValues,
        foreignKeyModes: foreignKeyModes,
        foreignKeyIdLists: foreignKeyIdLists,
      ));
      // Yield periodically to keep UI responsive during large data construction
      if (i > 0 && i % 1000 == 0) {
        await Future.delayed(Duration.zero);
      }
    }

    final stopwatch = Stopwatch()..start();

    // Single batch insert call with all records
    // The batchInsert method will handle internal batching if needed for memory efficiency
    final result = await db.batchInsert(tableName, records);
    if (!result.isSuccess) {
      logService.add('Batch insert failed: ${result.message}', LogType.error);
      return -1; // Indicate failure
    }

    stopwatch.stop();
    final elapsed = stopwatch.elapsedMilliseconds;
    logService.add(
        'Batch insert $count records into "$tableName" time: ${elapsed}ms');

    final queryResult = await db.query(tableName).count();
    logService.add('query current table "$tableName" count: $queryResult');
    return elapsed;
  }

  /// Adds a specified number of example records to a given table one by one.
  Future<int> addExamplesOneByOne(
    String tableName,
    int count, {
    Map<String, dynamic>? foreignKeyValues,
    Map<String, ForeignKeyMode>? foreignKeyModes,
    Map<String, List<dynamic>>? foreignKeyIdLists,
  }) async {
    logService
        .add('Starting to add $count records to "$tableName" one by one...');
    final schema = await db.getTableSchema(tableName);
    if (schema == null) {
      logService.add(
          'Cannot add examples: Schema for table "$tableName" not found.',
          LogType.error);
      return -1;
    }

    // Get current max ID to ensure field values (email, username, etc.)
    // have sequential numbers matching the primary key IDs
    // Note: This is only used for generating field values, NOT for setting primary key
    // Primary key will be auto-generated by the database system
    // For one-by-one insertion, we query max ID before each insert to keep values in sync
    int baseIndex = 0;
    if (schema.primaryKeyConfig.type == PrimaryKeyType.sequential) {
      try {
        final lastResult = await db
            .query(tableName)
            .orderByDesc(schema.primaryKeyConfig.name)
            .select([schema.primaryKeyConfig.name]).limit(1);
        if (lastResult.data.isNotEmpty) {
          final lastId = lastResult.data.first[schema.primaryKeyConfig.name];
          if (lastId != null) {
            baseIndex = int.tryParse(lastId.toString()) ?? 0;
          }
        }
      } catch (e) {
        // If query fails, start from 0 (will use initial value from schema)
        logService.add(
            'Warning: Failed to query max ID for field value generation: $e',
            LogType.warn);
      }
    }

    // Pre-generate data to measure insert performance accurately (excluding data generation time)
    logService.add('Generating $count records for one-by-one insertion...');
    final records = <Map<String, dynamic>>[];
    for (var i = 0; i < count; i++) {
      records.add(_generateRecord(
        schema,
        baseIndex + i + 1,
        foreignKeyValues: foreignKeyValues,
        foreignKeyModes: foreignKeyModes,
        foreignKeyIdLists: foreignKeyIdLists,
      ));
      // Yield periodically during generation to keep UI responsive
      if (i > 0 && i % 1000 == 0) {
        await Future.delayed(Duration.zero);
      }
    }
    logService.add('Data generation complete. Starting insertion...');

    final stopwatch = Stopwatch()..start();

    for (var i = 0; i < count; i++) {
      final result = await db.insert(
        tableName,
        records[i],
      );

      if (!result.isSuccess) {
        return -1;
      }
      if (i % 200 == 0) {
        await Future.delayed(Duration.zero);
      }
    }
    stopwatch.stop();
    final elapsed = stopwatch.elapsedMilliseconds;
    logService.add(
        'Finished adding $count records to "$tableName" one-by-one in ${elapsed}ms');
    final queryResult = await db.query(tableName).count();
    logService.add('query count: $queryResult');
    return elapsed;
  }

  Future<int> deleteExamples() async {
    final stopwatch = Stopwatch()..start();
    final deleteResult = await db.delete('users').where('id', '>', '5');
    stopwatch.stop();
    final elapsed = stopwatch.elapsedMilliseconds;
    logService.add('delete : ${deleteResult.toJson()}');
    logService.add('delete time: ${elapsed}ms');
    return elapsed;
  }

  Future<int> queryExamples() async {
    Stopwatch stopwatch = Stopwatch()..start();
    final queryResult = await db.query('users').where('id', '<', '6').limit(8);
    stopwatch.stop();
    final elapsed = stopwatch.elapsedMilliseconds;

    logService.add('query time: ${elapsed}ms');
    logService
        .add('query result: ${queryResult.length} ${queryResult.toJson()}');
    final queryCount = await db.query('users').count();
    logService.add('query count: $queryCount');
    return elapsed;
  }

  /// Example: Expression operations for atomic field updates
  /// Demonstrates using Expr for atomic calculations without race conditions
  Future<void> expressionExamples() async {
    logService.add('--- Expression Examples ---', LogType.info);

    // Example 1: Simple increment using expression
    await db.insert('users', {
      'username': 'expr_user1',
      'email': 'expr1@example.com',
      'age': 25,
      'fans': 100,
    });

    // Increment fans by 50 atomically
    await db.update('users', {
      'fans': Expr.field('fans') + Expr.value(50),
    }).where('username', '=', 'expr_user1');

    // Example 2: Complex calculation with multiple fields
    await db.insert('users', {
      'username': 'expr_user2',
      'email': 'expr2@example.com',
      'age': 30,
      'fans': 200,
    });

    // Calculate total: fans + (age * 2)
    await db.update('users', {
      'fans': Expr.field('fans') + (Expr.field('age') * Expr.value(2)),
    }).where('username', '=', 'expr_user2');

    // Example 3: Multi-level parentheses for complex calculations
    await db.insert('users', {
      'username': 'expr_user3',
      'email': 'expr3@example.com',
      'age': 35,
      'fans': 300,
    });

    // Complex calculation: ((fans + age) * 0.8) - 10
    await db.update('users', {
      'fans': ((Expr.field('fans') + Expr.field('age')) * Expr.value(0.8)) -
          Expr.value(10),
    }).where('username', '=', 'expr_user3');

    // Example 4: Using chain builder syntax sugar
    await db.insert('users', {
      'username': 'expr_user4',
      'email': 'expr4@example.com',
      'age': 40,
      'fans': 400,
    });

    // Chain builder methods (syntax sugar for expressions)
    await db
        .update('users', {})
        .increment('fans', 100) // fans = fans + 100
        .multiply('age', 1.1) // age = age * 1.1
        .setServerTimestamp('last_login') // last_login = now()
        .where('username', '=', 'expr_user4');

    // Example 5: Using min/max functions
    await db.update('users', {
      'fans': Expr.min(Expr.field('fans'), Expr.value(500)),
    }).where('username', '=', 'expr_user4');

    // Example 6: Expression in Map literal (direct usage)
    await db.update('users', {
      'fans': Expr.field('fans') * Expr.field('age') / Expr.value(10),
      'last_login': Expr.now(),
    }).where('username', '=', 'expr_user4');

    // Example 7: Complex business logic calculation
    // Calculate final price: (price * quantity + tax) * (1 - discount)
    await db.insert('posts', {
      'title': 'Product A',
      'user_id': 1,
      'content': 'Product description',
    });

    // If posts table had price, quantity, tax, discount fields:
    // await db.update('posts', {
    //   'final_price': ((Expr.field('price') * Expr.field('quantity') + Expr.field('tax')) *
    //                  (Expr.value(1) - Expr.field('discount'))),
    // }).where('title', '=', 'Product A');

    logService.add('Expression examples completed', LogType.info);
  }

  /// Example: Transaction operations
  /// Demonstrates transaction commit, rollback, and atomic operations
  Future<void> transactionExamples() async {
    logService.add('--- Transaction Examples ---', LogType.info);

    // Example 1: Basic transaction with commit
    // All operations in the transaction are atomic - either all succeed or all fail
    final txResult1 = await db.transaction(() async {
      await db.insert('users', {
        'username': 'tx_user1',
        'email': 'tx1@example.com',
        'age': 25,
        'fans': 100,
      });
      await db.insert('users', {
        'username': 'tx_user2',
        'email': 'tx2@example.com',
        'age': 30,
        'fans': 200,
      });
    });

    if (txResult1.isSuccess) {
      logService.add('Transaction committed: 2 users inserted', LogType.info);
    }

    // Example 2: Transaction with rollback on error
    // If an error occurs, all changes are automatically rolled back
    final txResult2 = await db.transaction(() async {
      await db.insert('users', {
        'username': 'tx_user3',
        'email': 'tx3@example.com',
        'age': 35,
      });
      throw Exception('Simulated business error');
    }, rollbackOnError: true);

    if (txResult2.isFailed) {
      logService.add(
          'Transaction rolled back: ${txResult2.error?.message}', LogType.info);
    }

    logService.add('Transaction examples completed', LogType.info);
  }
}

/// ForeignKeyMode: Foreign key ID allocation mode
enum ForeignKeyMode {
  fixed, // Fixed value
  random, // Random value
}
