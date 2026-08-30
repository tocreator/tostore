import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tostore/tostore.dart';

import 'testing/log_service.dart';

String _statusErrorMessage(
  Iterable<ResultStatus> statuses, {
  String fallback = 'Operation failed',
}) {
  final errors =
      statuses.where((s) => s.type != ResultType.success).map((s) => s.message);
  return errors.isEmpty ? fallback : errors.join('; ');
}

/// This example demonstrates the core features of ToStore using a user management system
/// with global settings. It shows how to:
/// - Create tables (both regular and global)
/// - Work with multi-space architecture
/// - Distributed example
/// - Handle global data
class ToStoreExample {
  late ToStore db;

  /// Get database path
  Future<String> getDbPath() async {
    if (kIsWeb) {
      return 'common';
    } else {
      try {
        // Resolve app documents directory via path_provider and inject into tostore
        final docDir = await getApplicationDocumentsDirectory();
        return p.join(docDir.path,
            'common'); // tostore: ^2.2.2 version default dbPath is getApplicationDocumentsDirectory()/common
      } catch (e) {
        return 'common';
      }
    }
  }

  /// Initialize database and create tables
  Future<void> initialize({String? dbPath}) async {
    final dbRoot = dbPath ?? await getDbPath();

    db = await ToStore.open(
      dbPath: dbRoot,
      dbName: 'tostore_example',
      config: DataStoreConfig(
        enableLog: true,
        logLevel: LogLevel.debug,
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
        const TableSchema(
          name: 'embeddings',
          primaryKeyConfig: PrimaryKeyConfig(
            name: 'id',
            type: PrimaryKeyType.sequential,
          ),
          fields: [
            FieldSchema(name: 'name', type: DataType.text, nullable: false),
            FieldSchema(
              name: 'embedding',
              type: DataType.vector,
              vectorConfig: VectorFieldConfig(
                dimensions: 512,
                precision: VectorPrecision.float32,
              ),
            ),
          ],
          indexes: [
            IndexSchema(
              fields: ['embedding'],
              type: IndexType.vector,
              vectorConfig: VectorIndexConfig(
                distanceMetric: VectorDistanceMetric.cosine,
                maxDegree: 64,
                efSearch: 64,
                constructionEf: 128,
              ),
            ),
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

    // Automatically store data, support batch upsert (uses pk or unique key from data)
    await db.upsert('users', {'username': 'John', 'email': 'john@example.com'});

    // Auto insert or update based on primary key
    await db.upsert('users', {
      'id': 1,
      'username': 'John',
      'email': 'john@example.com',
    });

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

  /// Example: Working with vector data and similarity search
  Future<void> vectorExamples() async {
    // Create table with vector field and NGH vector index
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
              dimensions: 128, // 128-dimensional embeddings
              precision: VectorPrecision.float32,
            ),
          ),
        ],
        indexes: [
          // NGH vector index with typed configuration
          IndexSchema(
            fields: ['embedding'],
            type: IndexType.vector,
            vectorConfig: VectorIndexConfig(
              distanceMetric: VectorDistanceMetric.cosine,
              maxDegree: 64, // Graph max neighbors (R)
              efSearch: 64, // Search expansion factor
              constructionEf: 128, // Construction expansion factor
            ),
          ),
        ],
      ),
    ]);

    // Create sample vector data
    final sampleVector1 =
        VectorData.fromList(List.generate(128, (i) => (i * 0.01)));
    final sampleVector2 =
        VectorData.fromList(List.generate(128, (i) => (i * 0.02 + 0.5)));

    // Store documents with vector embeddings
    await db.insert('embeddings', {
      'document_title': 'Introduction to vector databases',
      'embedding': sampleVector1,
    });

    await db.insert('embeddings', {
      'document_title': 'Machine Learning with embeddings',
      'embedding': sampleVector2,
    });

    // --- Vector similarity search (ANN via db.query chain) ---
    final queryVector =
        VectorData.fromList(List.generate(128, (i) => (i * 0.015)));

    final queryResult = await db
        .query('embeddings')
        .matchVector('embedding', queryVector)
        .limit(5);

    final retrieval = queryResult.retrieval;
    final sb = StringBuffer('--- Vector Search Top-5 Matches ---');
    for (int i = 0; i < queryResult.data.length; i++) {
      final doc = queryResult.data[i];
      final pk = doc['id'];
      final title = doc['document_title'] ?? '';
      final entry = (retrieval != null && i < retrieval.entries.length)
          ? retrieval.entries[i]
          : null;
      final score = entry?.score.toStringAsFixed(4) ?? 'N/A';
      final rawScore = entry?.rawScore;
      final dist = entry?.meta?['distance']?.toString() ??
          (rawScore != null ? rawScore.toStringAsFixed(4) : 'N/A');
      sb.writeln();
      sb.write(
          '  #${i + 1} pk=$pk, score=$score, distance=$dist, title="$title"');
    }
    logService.add(sb.toString());

    // --- Direct vector operations ---
    final result = await db.query('embeddings');
    final documents = result.data;
    List<VectorData> vectors = [];

    for (var doc in documents) {
      if (doc['embedding'] is List) {
        VectorData vector =
            VectorData.fromJson(doc['embedding'] as List<dynamic>);
        vectors.add(vector);

        logService.add(
            'document title: ${doc['document_title']}, vector dimensions: ${vector.dimensions}');
      }
    }

    if (vectors.length >= 2) {
      final vector1 = vectors[0];
      final vector2 = vectors[1];

      // Calculate cosine similarity
      final similarity = vector1.cosineSimilarity(vector2);
      logService.add('cosine similarity: $similarity');

      // Calculate euclidean distance
      final distance = vector1.euclideanDistance(vector2);
      logService.add('euclidean distance: $distance');
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
          centralServerUrl: 'https://127.0.0.1:8080',
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
    final result = await db
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

    final taskId = result.taskId;
    if (taskId != null) {
      // query migration task status
      final status = await db.queryMigrationTaskStatus(taskId);
      logService.add('migration progress: ${status?.progressPercentage}%');
    }
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

    final tagCondition = QueryCondition().whereContains('tags', 'recommend');

    // query condition nesting example - show infinite nesting ability
    final result = await db
        .query('users')
        .where('is_active', '=', true)
        .condition(QueryCondition() // query condition construction
                .whereEqual('type', 'app')
                .condition(idCondition) // nest again the defined conditions
            )
        .orCondition(tagCondition) // or satisfy tag conditions
        .limit(20);

    for (var user in result.data) {
      logService.add(
          'user: ${user['username']}, type: ${user['type']}, fans: ${user['fans']}, tags: ${user['tags']}');
    }

    // equivalent SQL:
    // SELECT * FROM users
    // WHERE is_active = true
    //   AND (type = 'app' OR id >= 1 OR fans >= 200)
    //   OR (tag contains 'recommend')
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

  final Random _sharedRandom = Random();

  /// Generates a single mock data record based on a table's schema.
  ///
  Map<String, dynamic> _generateRecord(
    TableSchema schema,
    int index, {
    Map<String, dynamic>? foreignKeyValues,
    Map<String, ForeignKeyMode>? foreignKeyModes,
    Map<String, List<dynamic>>? foreignKeyIdLists,
    Set<String>? foreignKeyFields,
    Random? random,
  }) {
    final record = <String, dynamic>{};
    final rng = random ?? _sharedRandom;

    // Build foreign key field set for fast lookup if not provided
    final fkFields = foreignKeyFields ??
        {
          for (final fk in schema.foreignKeys)
            if (fk.enabled) ...fk.fields
        };

    for (final field in schema.fields) {
      // We don't generate data for the primary key if it's auto-incrementing.
      // The database will handle it.
      if (field.name == schema.primaryKeyConfig.name) {
        continue;
      }

      // If the field is a foreign key field
      if (fkFields.contains(field.name)) {
        final mode = foreignKeyModes?[field.name] ?? ForeignKeyMode.fixed;
        final idList = foreignKeyIdLists?[field.name];

        if (mode == ForeignKeyMode.random &&
            idList != null &&
            idList.isNotEmpty) {
          // Random mode: select a random ID from the ID list
          record[field.name] = idList[rng.nextInt(idList.length)];
        } else if (foreignKeyValues != null &&
            foreignKeyValues.containsKey(field.name)) {
          // Fixed mode: use the provided fixed value
          record[field.name] = foreignKeyValues[field.name];
        } else {
          // If no foreign key value is provided, record a warning but continue (database will validate)
          logService.add(
              'Warning: Foreign key field "${field.name}" in table "${schema.name}" has no provided value.',
              LogLevel.warn);
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
        record[field.name] = rng.nextInt(100);
        continue;
      }

      // Generate data based on field type
      switch (field.type) {
        case DataType.text:
          record[field.name] = '${field.name}_$index';
          break;
        case DataType.bigInt:
        case DataType.integer:
          record[field.name] = rng.nextInt(10000);
          break;
        case DataType.double:
          record[field.name] = rng.nextDouble() * 1000;
          break;
        case DataType.boolean:
          record[field.name] = rng.nextBool();
          break;
        case DataType.datetime:
          break;
        case DataType.vector:
          // Generate 5-member semantic proximity chains along a dedicated 1D topic ray.
          // Guarantees every single record (M0..M4) always has 3-4 immediate neighbors
          // with cosine scores smoothly distributed across 0.96 -> 0.87 -> 0.76.
          if (field.vectorConfig != null) {
            final dims = field.vectorConfig!.dimensions;
            final groupId = (index - 1) ~/ 5;
            final memberId = (index - 1) % 5;
            final groupSeed = Random(groupId * 10007 + dims);

            // 1. Generate base cluster vector (unit normalized)
            final base = List<double>.generate(dims, (_) {
              final u1 = groupSeed.nextDouble().clamp(1e-10, 1.0);
              final u2 = groupSeed.nextDouble();
              return sqrt(-2.0 * log(u1)) * cos(2.0 * pi * u2);
            });
            final bNorm = sqrt(base.fold(0.0, (p, e) => p + e * e));
            if (bNorm > 0) {
              for (var i = 0; i < dims; i++) {
                base[i] /= bNorm;
              }
            }

            // 2. Generate orthogonal direction vector for this group
            final dir = List<double>.generate(dims, (_) {
              final u1 = groupSeed.nextDouble().clamp(1e-10, 1.0);
              final u2 = groupSeed.nextDouble();
              return sqrt(-2.0 * log(u1)) * cos(2.0 * pi * u2);
            });
            double bDotD = 0;
            for (var i = 0; i < dims; i++) {
              bDotD += base[i] * dir[i];
            }
            for (var i = 0; i < dims; i++) {
              dir[i] -= bDotD * base[i];
            }
            final dNorm = sqrt(dir.fold(0.0, (p, e) => p + e * e));
            if (dNorm > 0) {
              for (var i = 0; i < dims; i++) {
                dir[i] /= dNorm;
              }
            }

            // 3. Step parameter along the ray: t_k = (k - 2) * 0.28 (centered around M2)
            // Adjacent members have cos ≈ 0.96
            // 2-step neighbors have cos ≈ 0.87
            // 3-step neighbors have cos ≈ 0.77
            final double t = (memberId - 2) * 0.28;

            final values = List<double>.generate(dims, (d) {
              return base[d] + (dir[d] * t);
            });

            // Normalize to unit length for cosine similarity
            final norm = sqrt(values.fold(0.0, (p, e) => p + e * e));
            if (norm > 0) {
              for (var i = 0; i < dims; i++) {
                values[i] /= norm;
              }
            }
            record[field.name] = VectorData(values);
            if (record['document_title'] != null) {
              record['document_title'] =
                  '[Group $groupId:M$memberId] ${record['document_title']}';
            }
          }
          break;
        case DataType.blob:
        // Skip blob for mock data generation
        case DataType.array:
        // Skip array for mock data generation
        case DataType.json:
        // Skip json for mock data generation
        case DataType.dynamic:
          // Skip dynamic for mock data generation
          break;
      }
    }
    return record;
  }

  /// Adds a specified number of example records to a given table using batch inserts.
  /// Optimized for 1M+ ultra-large dataset insertions to avoid memory-IO dual pressure.
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
          LogLevel.error);
      return -1;
    }

    // Get a generation base for derived text fields (email, username, etc.).
    final baseIndex = await _resolveExampleBaseIndex(tableName, schema);

    final totalStopwatch = Stopwatch()..start();
    final dbStopwatch = Stopwatch();
    int processedCount = 0;

    // Optimized batch size (100,000 items) to maximize B-Tree page merge & split efficiency
    // while keeping Dart heap within safe boundaries (~30MB per batch).
    const int batchSize = 100000;

    // Cache foreign key fields once for the entire batch operation
    final fkFields = {
      for (final fk in schema.foreignKeys)
        if (fk.enabled) ...fk.fields
    };

    while (processedCount < count) {
      final currentBatchSize = min(batchSize, count - processedCount);
      final records = <Map<String, dynamic>>[];

      // 1. Generate data for current 100k chunk
      for (var i = 0; i < currentBatchSize; i++) {
        records.add(_generateRecord(
          schema,
          baseIndex + processedCount + i + 1,
          foreignKeyValues: foreignKeyValues,
          foreignKeyModes: foreignKeyModes,
          foreignKeyIdLists: foreignKeyIdLists,
          foreignKeyFields: fkFields,
          random: _sharedRandom,
        ));
      }

      // 2. Insert current chunk (measure pure database time)
      dbStopwatch.start();
      final result =
          await db.batchInsert(tableName, records, returnResultDetails: false);
      dbStopwatch.stop();

      // Free records immediately to let Dart GC reclaim memory before flush & next round
      records.clear();

      if (result.hasErrors) {
        logService.add(
            'Batch insert failed at offset $processedCount: ${_statusErrorMessage(result.statuses)}',
            LogLevel.error);
        return -1;
      }

      processedCount += currentBatchSize;

      // Yield to keep UI responsive
      await Future.delayed(Duration.zero);

      logService.add('Progress: $processedCount/$count records inserted...',
          LogLevel.info, true);
    }

    totalStopwatch.stop();
    final dbElapsed = dbStopwatch.elapsedMilliseconds;
    final totalElapsed = totalStopwatch.elapsedMilliseconds;

    logService.add('Batch insert $count records into "$tableName" completed. '
        'DB Time: ${dbElapsed}ms, Total Time: ${totalElapsed}ms');
    return dbElapsed;
  }

  /// Adds a specified number of example records to a given table one by one.
  Future<int> addExamplesOneByOne(
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
          LogLevel.error);
      return -1;
    }

    // This base is only used for generated field values, not for assigning
    // the primary key itself.
    final baseIndex = await _resolveExampleBaseIndex(tableName, schema);

    // Cache foreign key fields once for the entire generation
    final fkFields = {
      for (final fk in schema.foreignKeys)
        if (fk.enabled) ...fk.fields
    };

    // Pre-generate data to measure insert performance accurately (excluding data generation time)
    final records = <Map<String, dynamic>>[];
    for (var i = 0; i < count; i++) {
      records.add(_generateRecord(
        schema,
        baseIndex + i + 1,
        foreignKeyValues: foreignKeyValues,
        foreignKeyModes: foreignKeyModes,
        foreignKeyIdLists: foreignKeyIdLists,
        foreignKeyFields: fkFields,
        random: _sharedRandom,
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

      if (result.hasErrors) {
        return -1;
      }
      if (i % 200 == 0) {
        await Future.delayed(Duration.zero);
      }
    }
    stopwatch.stop();
    final elapsed = stopwatch.elapsedMilliseconds;
    logService.add(
        'Finished adding $count records to "$tableName" one-by-one. DB Time: ${elapsed}ms');
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
    logService.add('--- Expression Examples ---', LogLevel.info);

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

    logService.add('Expression examples completed', LogLevel.info);
  }

  /// Example: Transaction operations
  /// Demonstrates transaction commit, rollback, and atomic operations
  Future<void> transactionExamples() async {
    logService.add('--- Transaction Examples ---', LogLevel.info);

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

    if (!txResult1.hasErrors) {
      logService.add('Transaction committed: 2 users inserted', LogLevel.info);
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

    if (txResult2.hasErrors) {
      logService.add(
          'Transaction rolled back: ${_statusErrorMessage(txResult2.statuses, fallback: 'Transaction failed')}',
          LogLevel.info);
    }

    logService.add('Transaction examples completed', LogLevel.info);
  }

  // --- Vector Benchmarking ---

  /// Performs a benchmark of vector search operations.
  ///
  /// [tableName] The table to search in.
  /// [iterations] Number of searches to perform.
  /// [topK] Number of nearest neighbors to retrieve.
  ///
  /// Returns the average latency in milliseconds.
  Future<double> vectorSearchBenchmark(
      String tableName, int iterations, int topK) async {
    logService.add(
        'Starting Vector Search Benchmark: table="$tableName", iterations=$iterations, topK=$topK');

    final schema = await db.getTableSchema(tableName);
    if (schema == null) {
      logService.add('Benchmark failed: Schema for "$tableName" not found.',
          LogLevel.error);
      return -1;
    }

    final vectorField = schema.fields.firstWhere(
        (f) => f.type == DataType.vector,
        orElse: () => const FieldSchema(name: '', type: DataType.text));

    if (vectorField.name.isEmpty) {
      logService.add('Benchmark failed: No vector field found in "$tableName".',
          LogLevel.error);
      return -1;
    }

    final dims = vectorField.vectorConfig?.dimensions ?? 0;
    if (dims == 0) {
      logService.add(
          'Benchmark failed: Vector dimensions not configured for "${vectorField.name}".',
          LogLevel.error);
      return -1;
    }

    // Verify index existence
    final hasVectorIndex = schema.indexes.any((idx) =>
        idx.type == IndexType.vector && idx.fields.contains(vectorField.name));
    if (!hasVectorIndex) {
      logService.add(
          'Warning: No vector index found on "${vectorField.name}". Search will be slow.',
          LogLevel.warn);
    }

    final random = Random();
    final totalCount = await db.query(tableName).count();
    final isSequential =
        schema.primaryKeyConfig.type == PrimaryKeyType.sequential;

    final List<Map<String, dynamic>> sampleDocs;
    if (isSequential && totalCount > 50) {
      // O(log N) Random Primary Key Probing across the entire table range (e.g. 1 ~ 100,000)
      // Generates 25 randomly distributed PKs and fetches them concurrently with zero table scan.
      final pks = <int>{};
      final probeCount = min(totalCount, 25);
      while (pks.length < probeCount) {
        pks.add(random.nextInt(totalCount) + 1);
      }
      final probeResults = await Future.wait([
        for (final pk in pks)
          db
              .query(tableName)
              .where(schema.primaryKey, '=', pk.toString())
              .limit(1)
      ]);
      sampleDocs = [
        for (final res in probeResults)
          if (res.data.isNotEmpty) res.data.first
      ];
    } else {
      // Fallback: fast first-page read
      sampleDocs = (await db.query(tableName).limit(25)).data;
    }

    final List<(dynamic pk, VectorData vec)> anchorSamples = [];
    for (final doc in sampleDocs) {
      final rawVec = doc[vectorField.name];
      final pk = doc[schema.primaryKey] ?? doc['id'];
      if (rawVec is VectorData) {
        anchorSamples.add((pk, rawVec));
      } else if (rawVec is Float32List) {
        anchorSamples.add((pk, VectorData(rawVec)));
      } else if (rawVec is Iterable) {
        try {
          final list = [for (final dynamic n in rawVec) (n as num).toDouble()];
          if (list.length == dims) {
            anchorSamples.add((pk, VectorData.fromList(list)));
          }
        } catch (_) {}
      }
    }

    final totalStopwatch = Stopwatch()..start();
    final latenciesMs = <double>[];
    int exactTestCount = 0;
    int exactHitCount = 0;
    int semanticTestCount = 0;
    int semanticHitCount = 0;

    for (int i = 0; i < iterations; i++) {
      dynamic targetAnchorPk;
      VectorData queryVector;
      bool isExactTest = false;

      // 1. Generate query vector based on real in-table anchor records:
      // - 50% Exact 0-Noise Identity Probe (tests 100% target recall)
      // - 50% Semantic Proximity Probe (tests neighboring cluster recall)
      if (anchorSamples.isNotEmpty) {
        final anchor = anchorSamples[random.nextInt(anchorSamples.length)];
        targetAnchorPk = anchor.$1;
        final baseValues = anchor.$2.values;

        if (iterations == 1 || random.nextDouble() < 0.50) {
          isExactTest = true;
          exactTestCount++;
          queryVector = anchor.$2;
        } else {
          semanticTestCount++;
          // Extremely light semantic noise (1% noise) for realistic neighbor retrieval
          final perturbed = List<double>.generate(dims, (d) {
            final u1 = random.nextDouble().clamp(1e-10, 1.0);
            final u2 = random.nextDouble();
            final g = sqrt(-2.0 * log(u1)) * cos(2.0 * pi * u2);
            return (d < baseValues.length ? baseValues[d] : 0.0) + (g * 0.015);
          });
          final norm = sqrt(perturbed.fold(0.0, (p, e) => p + e * e));
          if (norm > 0) {
            for (var j = 0; j < dims; j++) {
              perturbed[j] /= norm;
            }
          }
          queryVector = VectorData(perturbed);
        }
      } else {
        final queryValues = List<double>.generate(dims, (_) {
          final u1 = random.nextDouble().clamp(1e-10, 1.0);
          final u2 = random.nextDouble();
          return sqrt(-2.0 * log(u1)) * cos(2.0 * pi * u2);
        });
        final norm = sqrt(queryValues.fold(0.0, (p, e) => p + e * e));
        if (norm > 0) {
          for (var j = 0; j < dims; j++) {
            queryValues[j] /= norm;
          }
        }
        queryVector = VectorData(queryValues);
      }

      // 2. Perform search via db.query chain with timing
      final querySw = Stopwatch()..start();
      final queryResult = await db
          .query(tableName)
          .matchVector(vectorField.name, queryVector)
          .limit(topK);
      querySw.stop();
      final queryElapsedMs = querySw.elapsedMicroseconds / 1000.0;
      latenciesMs.add(queryElapsedMs);

      final results = queryResult.data;

      // Track target hit statistics
      bool targetHitTop1 = false;
      bool targetHitTopK = false;
      if (targetAnchorPk != null && results.isNotEmpty) {
        final firstPk = results.first[schema.primaryKey] ?? results.first['id'];
        if (firstPk.toString() == targetAnchorPk.toString()) {
          targetHitTop1 = true;
        }
        for (final r in results) {
          final pk = r[schema.primaryKey] ?? r['id'];
          if (pk.toString() == targetAnchorPk.toString()) {
            targetHitTopK = true;
            break;
          }
        }
      }

      if (isExactTest) {
        if (targetHitTop1) exactHitCount++;
      } else if (targetAnchorPk != null) {
        if (targetHitTopK) semanticHitCount++;
      }

      // Periodically log progress for long tests
      if (iterations >= 100 &&
          (i + 1) % (iterations ~/ 5) == 0 &&
          (i + 1) < iterations) {
        final pct = ((i + 1) / iterations * 100).toStringAsFixed(0);
        logService.add(
            '⏳ Benchmark Progress: ${i + 1}/$iterations completed ($pct%)...',
            LogLevel.info);
      }

      // Small delay to allow UI refresh in very long loops
      if (i % 500 == 0) {
        await Future.delayed(Duration.zero);
      }
    }

    totalStopwatch.stop();
    final totalElapsed = totalStopwatch.elapsedMilliseconds;
    final avgLatency = totalElapsed / iterations;

    // 4. Print Single Consolidated Summary Report for the entire execution
    latenciesMs.sort();
    final p50 = latenciesMs[
        (iterations * 0.50).floor().clamp(0, latenciesMs.length - 1)];
    final p95 = latenciesMs[
        (iterations * 0.95).floor().clamp(0, latenciesMs.length - 1)];
    final p99 = latenciesMs[
        (iterations * 0.99).floor().clamp(0, latenciesMs.length - 1)];
    final qps = avgLatency > 0 ? (1000.0 / avgLatency) : 0.0;

    final exactHitRate =
        exactTestCount > 0 ? (exactHitCount / exactTestCount) : 1.0;
    final semanticHitRate =
        semanticTestCount > 0 ? (semanticHitCount / semanticTestCount) : 1.0;
    final overallHitCount = exactHitCount + semanticHitCount;
    final totalAnchorTests = exactTestCount + semanticTestCount;
    final overallHitRate =
        totalAnchorTests > 0 ? (overallHitCount / totalAnchorTests) : 1.0;

    final report = StringBuffer();
    report.writeln('');
    report.writeln('=' * 78);
    report.writeln(
        '        TOSTORE VECTOR SEARCH BENCHMARK SUMMARY ($iterations Iterations)       ');
    report.writeln('=' * 78);
    report.writeln(
        '  Target Table         : $tableName (${dims}D, Cosine Metric)');
    report.writeln('  Total Executed       : $iterations queries (Top-$topK)');
    report.writeln('  Total Time Elapsed   : $totalElapsed ms');
    report.writeln('-' * 78);
    report.writeln('  ACCURACY & RECALL METRICS:');
    report.writeln(
        '    Exact Identity Hit : ${(exactHitRate * 100).toStringAsFixed(1)}% ($exactHitCount/$exactTestCount) 🎯 [Top-1 Exact]');
    report.writeln(
        '    Semantic Recall    : ${(semanticHitRate * 100).toStringAsFixed(1)}% ($semanticHitCount/$semanticTestCount) 🎯 [Top-$topK Proximity]');
    report.writeln(
        '    Overall Target Hit : ${(overallHitRate * 100).toStringAsFixed(1)}% ($overallHitCount/$totalAnchorTests)');
    report.writeln('-' * 78);
    report.writeln('  LATENCY & THROUGHPUT:');
    report.writeln(
        '    Average Latency    : ${avgLatency.toStringAsFixed(2)} ms/query');
    report.writeln('    P50 Latency        : ${p50.toStringAsFixed(2)} ms');
    report.writeln('    P95 Latency        : ${p95.toStringAsFixed(2)} ms');
    report.writeln('    P99 Latency        : ${p99.toStringAsFixed(2)} ms');
    report.writeln(
        '    QPS Throughput     : ${qps.toStringAsFixed(1)} queries/sec');
    report.writeln('=' * 78);

    logService.add(report.toString().trimRight(), LogLevel.info);

    return avgLatency;
  }

  Future<int> _resolveExampleBaseIndex(
    String tableName,
    TableSchema schema,
  ) async {
    if (schema.primaryKeyConfig.type == PrimaryKeyType.sequential) {
      try {
        final lastResult = await db
            .query(tableName)
            .orderByDesc(schema.primaryKeyConfig.name)
            .select([schema.primaryKeyConfig.name]).limit(1);
        if (lastResult.data.isNotEmpty) {
          final lastId = lastResult.data.first[schema.primaryKeyConfig.name];
          if (lastId != null) {
            return int.tryParse(lastId.toString()) ?? 0;
          }
        }
      } catch (e) {
        logService.add(
            'Warning: Failed to query max ID for field value generation: $e',
            LogLevel.warn);
      }
      return 0;
    }

    // For non-sequential primary keys (e.g. timestampBased), the example data
    // generator must not restart text fields like username_1 on every call.
    // Use a time-based seed so repeated example inserts remain unique.
    return DateTime.now().microsecondsSinceEpoch;
  }
}

/// ForeignKeyMode: Foreign key ID allocation mode
enum ForeignKeyMode {
  fixed, // Fixed value
  random, // Random value
}
