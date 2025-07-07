import 'package:tostore/tostore.dart';

import 'service/log_service.dart';

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
      dbName: 'tostore_example',
      config: DataStoreConfig(
        enableLog: true,
        logLevel: LogLevel.debug,
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
            FieldSchema(name: 'last_login', type: DataType.datetime),
            FieldSchema(
                name: 'is_active', type: DataType.boolean, defaultValue: true),
            FieldSchema(name: 'age', type: DataType.integer),
            FieldSchema(name: 'tags', type: DataType.text),
            FieldSchema(name: 'type', type: DataType.text),
            FieldSchema(name: 'fans', type: DataType.integer, defaultValue: 10),
          ],
          indexes: [
            IndexSchema(fields: ['username'], unique: true),
            IndexSchema(fields: ['email'], unique: true),
            IndexSchema(fields: ['last_login'], unique: false),
            IndexSchema(fields: ['is_active']),
            IndexSchema(fields: ['type']),
          ],
        ),
        const TableSchema(
          name: 'posts',
          primaryKeyConfig: PrimaryKeyConfig(
            name: 'id',
          ),
          fields: [
            FieldSchema(name: 'title', type: DataType.text, nullable: false),
            FieldSchema(name: 'content', type: DataType.text),
            FieldSchema(
                name: 'user_id', type: DataType.integer, nullable: false),
            FieldSchema(name: 'created_at', type: DataType.datetime),
            FieldSchema(
                name: 'is_published',
                type: DataType.boolean,
                defaultValue: true),
          ],
          indexes: [
            IndexSchema(fields: ['user_id']),
            IndexSchema(fields: ['created_at']),
          ],
        ),
        const TableSchema(
          name: 'comments',
          primaryKeyConfig: PrimaryKeyConfig(
            name: 'id',
          ),
          fields: [
            FieldSchema(
                name: 'post_id', type: DataType.integer, nullable: false),
            FieldSchema(
                name: 'user_id', type: DataType.integer, nullable: false),
            FieldSchema(name: 'content', type: DataType.text, nullable: false),
            FieldSchema(name: 'created_at', type: DataType.datetime),
          ],
          indexes: [
            IndexSchema(fields: ['post_id']),
            IndexSchema(fields: ['user_id']),
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

  Future<int> addExamples() async {
    await db.clear('users');
    logService.add('Preparing 10,000 records for batch insert...');
    Stopwatch stopwatch = Stopwatch()..start();

    // batch insert, 1000 records per batch
    const int batchSize = 1000;
    const int totalRecords = 10000;

    for (int start = 0; start < totalRecords; start += batchSize) {
      final int end =
          (start + batchSize < totalRecords) ? start + batchSize : totalRecords;
      // prepare records for current batch
      final users = <Map<String, dynamic>>[];
      for (var i = start; i < end; i++) {
        users.add({
          'username': 'user_$i',
          'email': 'user_$i@example.com',
          'tags': '4f4h3fd4fi33JlIDN2lh3777',
          'is_active': i > 5,
        });
      }

      // batch insert current batch
      await db.batchInsert('users', users);

      // yield to event loop, keep UI responsive
      await Future.delayed(Duration.zero);
    }

    stopwatch.stop();
    final elapsed = stopwatch.elapsedMilliseconds;
    logService.add('insert time: ${elapsed}ms');

    final queryResult = await db.query('users').count();
    logService.add('query count: $queryResult');
    return elapsed;
  }

  Future<int> addExamplesOneByOne() async {
    await db.clear('users');
    logService.add('Starting to add 10,000 records one by one...');
    final stopwatch = Stopwatch()..start();
    for (var i = 0; i < 10000; i++) {
      await db.insert('users', {
        'username': 'user_$i',
        'email': 'user_$i@example.com',
        'tags': '4f4h3fd4fi33JlIDN2lh3777',
        'is_active': i > 5,
      });
      // Yield to the event loop to prevent UI freezing
      if (i % 100 == 0) {
        // Yield more sparingly to improve performance while keeping UI responsive
        await Future.delayed(Duration.zero);
      }
    }
    stopwatch.stop();
    final elapsed = stopwatch.elapsedMilliseconds;
    logService.add('Finished adding 10k records one-by-one in ${elapsed}ms');
    final queryResult = await db.query('users').count();
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
}
