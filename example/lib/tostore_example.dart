import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tostore/tostore.dart';

import 'testing/example_schemas.dart';
import 'testing/log_service.dart';
import 'testing/vector_recall.dart';

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
        encryptionConfig: const EncryptionConfig(
          encryptionType: EncryptionType.none,
        ),
      ),
      // suitable for table structure definition in frequent startup scenarios of
      // mobile applications, accurately identifying table structure changes,
      // automatically upgrading and migrating data
      schemas: ExampleSchemas.all,
    );
  }

  /// Example: Basic CRUD operations for users
  Future<void> userExamples() async {
    // Create: Insert a new user
    await db.insert(ExampleSchemas.users.name, {
      'username': 'john_doe',
      'email': 'john@example.com',
      'last_login': DateTime.now().toIso8601String(),
    });

    // Read: Query user using chain style
    await db
        .query(ExampleSchemas.users.name)
        .where('username', '=', 'john_doe');

    // Update: Modify user data
    await db.update(ExampleSchemas.users.name, {
      'last_login': DateTime.now().toIso8601String(),
    }).where('username', '=', 'john_doe');

    // Automatically store data, support batch upsert (uses pk or unique key from data)
    await db.upsert(ExampleSchemas.users.name,
        {'username': 'John', 'email': 'john@example.com'});

    // Auto insert or update based on primary key
    await db.upsert(ExampleSchemas.users.name, {
      'id': 1,
      'username': 'John',
      'email': 'john@example.com',
    });

    // Delete: Remove user
    await db
        .delete(ExampleSchemas.users.name)
        .where('username', '=', 'john_doe');

    // use stream query to handle large data
    db
        .streamQuery(ExampleSchemas.users.name)
        .where('email', 'like', '%@example.com')
        .listen((userData) {
      // handle each data as needed, avoid memory pressure
      logService.add('handle user: ${userData['username']}');
    });
  }

  /// Example: Working with global settings
  Future<void> settingsExamples() async {
    // Set global theme (accessible from any space)
    await db.insert(ExampleSchemas.settings.name, {
      'key': 'theme',
      'value': 'dark',
      'updated_at': DateTime.now().toIso8601String(),
    });

    // Alternative: Using setValue for simple key-value storage
    await db.setValue('language', 'en', isGlobal: true);

    // Read settings using different methods
    await db.query(ExampleSchemas.settings.name).where('key', '=', 'theme');

    await db.getValue('language', isGlobal: true);

    // Update setting with conflict resolution
    await db.update(ExampleSchemas.settings.name, {
      'value': 'light',
      'updated_at': DateTime.now().toIso8601String(),
    }).where('key', '=', 'theme');

    // Delete setting
    await db.delete(ExampleSchemas.settings.name).where('key', '=', 'theme');
  }

  /// Example: Multi-space feature for user data isolation
  Future<void> multiSpaceExamples() async {
    // Switch to user1's space
    await db.switchSpace(spaceName: 'user1');
    await db.insert(ExampleSchemas.users.name, {
      'username': 'user1',
      'email': 'user1@example.com',
      'last_login': DateTime.now().toIso8601String(),
    });

    // Switch to user2's space
    await db.switchSpace(spaceName: 'user2');
    await db.insert(ExampleSchemas.users.name, {
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
        .query(ExampleSchemas.users.name)
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
    await db.query(ExampleSchemas.users.name).count();

    // Batch operations
    await db.batchInsert(ExampleSchemas.users.name, [
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

  /// Example: Working with vector data and similarity search.
  ///
  /// Uses the 128-d harness table. Do not retarget this at embeddings_512 —
  /// a mismatched width would fail insert or silently poison the mid-D corpus.
  Future<void> vectorExamples() async {
    final tableName = ExampleSchemas.embeddings128.name;
    final dims = ExampleSchemas.vectorDimLow;

    final v1Data = Float64List(dims);
    final v2Data = Float64List(dims);
    for (int i = 0; i < dims; i++) {
      v1Data[i] = i * 0.01;
      v2Data[i] = i * 0.02 + 0.5;
    }
    final sampleVector1 = VectorData(v1Data);
    final sampleVector2 = VectorData(v2Data);

    await db.insert(tableName, {
      'name': 'Introduction to vector databases',
      'embedding': sampleVector1,
    });

    await db.insert(tableName, {
      'name': 'Machine Learning with embeddings',
      'embedding': sampleVector2,
    });

    final qData = Float64List(dims);
    for (int i = 0; i < dims; i++) {
      qData[i] = i * 0.015;
    }
    final queryVector = VectorData(qData);

    final queryResult = await db
        .query(tableName)
        .matchVector('embedding', queryVector)
        .limit(5);

    final retrieval = queryResult.retrieval;
    final sb = StringBuffer('--- Vector Search Top-5 Matches ---');
    for (int i = 0; i < queryResult.data.length; i++) {
      final doc = queryResult.data[i];
      final pk = doc['id'];
      final title = doc['name'] ?? '';
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
    final result = await db.query(tableName);
    final documents = result.data;
    List<VectorData> vectors = [];

    for (var doc in documents) {
      if (doc['embedding'] is List) {
        VectorData vector =
            VectorData.fromJson(doc['embedding'] as List<dynamic>);
        vectors.add(vector);

        logService.add(
            'document name: ${doc['name']}, vector dimensions: ${vector.dimensions}');
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
      ),
    );

    // create tables
    await db.createTables(
      [
        TableSchema(
            name: ExampleSchemas.users.name,
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
        .updateSchema(ExampleSchemas.users.name)
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
    await db.insert(ExampleSchemas.users.name, {
      'username': 'active_user',
      'email': 'active@example.com',
      'is_active': true,
      'age': 25,
      'type': 'app',
      'fans': 300,
      'tags': 'recommend,hot,featured',
      'last_login': DateTime.now().toIso8601String(),
    });

    await db.insert(ExampleSchemas.users.name, {
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
        .query(ExampleSchemas.users.name)
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
    await db.clear(ExampleSchemas.users.name);
    await db.clear(ExampleSchemas.posts.name);
    await db.clear(ExampleSchemas.comments.name);
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
    await db.insert(ExampleSchemas.users.name, {
      'username': 'blogger',
      'email': 'blogger@example.com',
      'is_active': true,
    });

    // insert post
    await db.insert(ExampleSchemas.posts.name, {
      'title': 'how to use join to query',
      'content': 'this is a post about join...',
      'user_id': 1,
      'created_at': DateTime.now().toIso8601String(),
    });

    // insert comment
    await db.insert(ExampleSchemas.comments.name, {
      'post_id': 1,
      'user_id': 1,
      'content': 'this is my own post comment',
      'created_at': DateTime.now().toIso8601String(),
    });

    // multi-table join query - post, author and comment
    final postsWithComments = await db
        .query(ExampleSchemas.posts.name)
        .select([
          '${ExampleSchemas.posts.name}.id as post_id',
          '${ExampleSchemas.posts.name}.title',
          '${ExampleSchemas.users.name}.username as author',
          '${ExampleSchemas.comments.name}.content as comment',
          '${ExampleSchemas.comments.name}.created_at as comment_time'
        ])
        .join(ExampleSchemas.users.name, '${ExampleSchemas.posts.name}.user_id',
            '=', '${ExampleSchemas.users.name}.id')
        .join(
            ExampleSchemas.comments.name,
            '${ExampleSchemas.posts.name}.user_id',
            '=',
            '${ExampleSchemas.comments.name}.user_id')
        .where('${ExampleSchemas.posts.name}.is_published', '=', true)
        .orderByDesc('${ExampleSchemas.comments.name}.created_at');

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
          // Width comes from the selected table schema (128 / 512 / 1536),
          // not a hardcoded 512-d default.
          if (field.vectorConfig != null) {
            final dims = field.vectorConfig!.dimensions;
            record[field.name] = ExampleVectorCorpus.memberVector(
              index: index,
              dimensions: dims,
            );
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

    if (record.values.any((v) => v is VectorData)) {
      final label = ExampleVectorCorpus.recordLabel(index);
      for (final field in schema.fields) {
        if (ExampleVectorCorpus.stampFields.contains(field.name) &&
            field.type == DataType.text) {
          record[field.name] = label;
        }
      }
    }
    return record;
  }

  void _logVectorGenerationWidth(TableSchema schema) {
    for (final field in schema.fields) {
      if (field.type != DataType.vector) continue;
      final dims = field.vectorConfig?.dimensions ?? 0;
      if (dims > 0) {
        logService.add(
          'Generating ${dims}D vectors for table "${schema.name}".',
          LogLevel.info,
        );
      } else {
        logService.add(
          'Table "${schema.name}" field "${field.name}" has no vector dimensions.',
          LogLevel.error,
        );
      }
      return;
    }
  }

  /// Lets the example UI paint a frame during mock-data generation.
  ///
  /// [Future.delayed] only hits the timer queue and can resume before the
  /// next frame, so a large generate loop still looks like the engine froze.
  Future<void> _yieldUiFrame() {
    return SchedulerBinding.instance.endOfFrame;
  }

  /// Builds mock rows in short slices so the UI can keep painting.
  Future<List<Map<String, dynamic>>> _generateRecordsChunked({
    required TableSchema schema,
    required int firstIndex,
    required int count,
    required int alreadyDone,
    required int total,
    required Set<String> foreignKeyFields,
    Map<String, dynamic>? foreignKeyValues,
    Map<String, ForeignKeyMode>? foreignKeyModes,
    Map<String, List<dynamic>>? foreignKeyIdLists,
    void Function(String status)? onStatus,
  }) async {
    final records = <Map<String, dynamic>>[];
    final slice = Stopwatch()..start();
    for (var i = 0; i < count; i++) {
      records.add(_generateRecord(
        schema,
        firstIndex + i,
        foreignKeyValues: foreignKeyValues,
        foreignKeyModes: foreignKeyModes,
        foreignKeyIdLists: foreignKeyIdLists,
        foreignKeyFields: foreignKeyFields,
        random: _sharedRandom,
      ));
      final done = alreadyDone + i + 1;
      if (slice.elapsedMilliseconds >= 8 || i == count - 1) {
        onStatus?.call('Generating test data $done/$total...');
        await _yieldUiFrame();
        slice.reset();
      }
    }
    return records;
  }

  /// Adds a specified number of example records to a given table using batch inserts.
  /// Optimized for 1M+ ultra-large dataset insertions to avoid memory-IO dual pressure.
  Future<int> addExamples(
    String tableName,
    int count, {
    Map<String, dynamic>? foreignKeyValues,
    Map<String, ForeignKeyMode>? foreignKeyModes,
    Map<String, List<dynamic>>? foreignKeyIdLists,
    void Function(String status)? onStatus,
  }) async {
    final schema = await db.getTableSchema(tableName);
    if (schema == null) {
      logService.add(
          'Cannot add examples: Schema for table "$tableName" not found.',
          LogLevel.error);
      return -1;
    }
    _logVectorGenerationWidth(schema);

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

      // 1. Generate data for current 100k chunk, yielding so the UI stays live.
      final records = await _generateRecordsChunked(
        schema: schema,
        firstIndex: baseIndex + processedCount + 1,
        count: currentBatchSize,
        alreadyDone: processedCount,
        total: count,
        foreignKeyFields: fkFields,
        foreignKeyValues: foreignKeyValues,
        foreignKeyModes: foreignKeyModes,
        foreignKeyIdLists: foreignKeyIdLists,
        onStatus: onStatus,
      );

      // Paint "inserting" before the engine call so generation time is not
      // mistaken for database time.
      onStatus?.call(
          'Inserting ${processedCount + currentBatchSize}/$count records...');
      await _yieldUiFrame();

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
    void Function(String status)? onStatus,
  }) async {
    final schema = await db.getTableSchema(tableName);
    if (schema == null) {
      logService.add(
          'Cannot add examples: Schema for table "$tableName" not found.',
          LogLevel.error);
      return -1;
    }
    _logVectorGenerationWidth(schema);

    // This base is only used for generated field values, not for assigning
    // the primary key itself.
    final baseIndex = await _resolveExampleBaseIndex(tableName, schema);

    // Cache foreign key fields once for the entire generation
    final fkFields = {
      for (final fk in schema.foreignKeys)
        if (fk.enabled) ...fk.fields
    };

    // Pre-generate data to measure insert performance accurately (excluding data generation time)
    final records = await _generateRecordsChunked(
      schema: schema,
      firstIndex: baseIndex + 1,
      count: count,
      alreadyDone: 0,
      total: count,
      foreignKeyFields: fkFields,
      foreignKeyValues: foreignKeyValues,
      foreignKeyModes: foreignKeyModes,
      foreignKeyIdLists: foreignKeyIdLists,
      onStatus: onStatus,
    );
    logService.add('Data generation complete. Starting insertion...');
    onStatus?.call('Inserting $count records one by one...');
    await _yieldUiFrame();

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
    final deleteResult =
        await db.delete(ExampleSchemas.users.name).where('id', '>', '5');
    stopwatch.stop();
    final elapsed = stopwatch.elapsedMilliseconds;
    logService.add('delete : ${deleteResult.toJson()}');
    logService.add('delete time: ${elapsed}ms');
    return elapsed;
  }

  Future<int> queryExamples() async {
    Stopwatch stopwatch = Stopwatch()..start();
    final queryResult = await db
        .query(ExampleSchemas.users.name)
        .where('id', '<', '6')
        .limit(8);
    stopwatch.stop();
    final elapsed = stopwatch.elapsedMilliseconds;

    logService.add('query time: ${elapsed}ms');
    logService
        .add('query result: ${queryResult.length} ${queryResult.toJson()}');
    final queryCount = await db.query(ExampleSchemas.users.name).count();
    logService.add('query count: $queryCount');
    return elapsed;
  }

  /// Example: Expression operations for atomic field updates
  /// Demonstrates using Expr for atomic calculations without race conditions
  Future<void> expressionExamples() async {
    logService.add('--- Expression Examples ---', LogLevel.info);

    // Example 1: Simple increment using expression
    await db.insert(ExampleSchemas.users.name, {
      'username': 'expr_user1',
      'email': 'expr1@example.com',
      'age': 25,
      'fans': 100,
    });

    // Increment fans by 50 atomically
    await db.update(ExampleSchemas.users.name, {
      'fans': Expr.field('fans') + Expr.value(50),
    }).where('username', '=', 'expr_user1');

    // Example 2: Complex calculation with multiple fields
    await db.insert(ExampleSchemas.users.name, {
      'username': 'expr_user2',
      'email': 'expr2@example.com',
      'age': 30,
      'fans': 200,
    });

    // Calculate total: fans + (age * 2)
    await db.update(ExampleSchemas.users.name, {
      'fans': Expr.field('fans') + (Expr.field('age') * Expr.value(2)),
    }).where('username', '=', 'expr_user2');

    // Example 3: Multi-level parentheses for complex calculations
    await db.insert(ExampleSchemas.users.name, {
      'username': 'expr_user3',
      'email': 'expr3@example.com',
      'age': 35,
      'fans': 300,
    });

    // Complex calculation: ((fans + age) * 0.8) - 10
    await db.update(ExampleSchemas.users.name, {
      'fans': ((Expr.field('fans') + Expr.field('age')) * Expr.value(0.8)) -
          Expr.value(10),
    }).where('username', '=', 'expr_user3');

    // Example 4: Using chain builder syntax sugar
    await db.insert(ExampleSchemas.users.name, {
      'username': 'expr_user4',
      'email': 'expr4@example.com',
      'age': 40,
      'fans': 400,
    });

    // Chain builder methods (syntax sugar for expressions)
    await db
        .update(ExampleSchemas.users.name, {})
        .increment('fans', 100) // fans = fans + 100
        .multiply('age', 1.1) // age = age * 1.1
        .setServerTimestamp('last_login') // last_login = now()
        .where('username', '=', 'expr_user4');

    // Example 5: Using min/max functions
    await db.update(ExampleSchemas.users.name, {
      'fans': Expr.min(Expr.field('fans'), Expr.value(500)),
    }).where('username', '=', 'expr_user4');

    // Example 6: Expression in Map literal (direct usage)
    await db.update(ExampleSchemas.users.name, {
      'fans': Expr.field('fans') * Expr.field('age') / Expr.value(10),
      'last_login': Expr.now(),
    }).where('username', '=', 'expr_user4');

    // Example 7: Complex business logic calculation
    // Calculate final price: (price * quantity + tax) * (1 - discount)
    await db.insert(ExampleSchemas.posts.name, {
      'title': 'Product A',
      'user_id': 1,
      'content': 'Product description',
    });

    // If posts table had price, quantity, tax, discount fields:
    // await db.update(ExampleSchemas.posts.name, {
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
      await db.insert(ExampleSchemas.users.name, {
        'username': 'tx_user1',
        'email': 'tx1@example.com',
        'age': 25,
        'fans': 100,
      });
      await db.insert(ExampleSchemas.users.name, {
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
      await db.insert(ExampleSchemas.users.name, {
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

  /// Vector search latency and Recall@K versus known nearest neighbors.
  ///
  /// [searchDepth] `>= 1` (null = engine default 50).
  /// Set [verbose] false to suppress per-run logs (used by depth sweeps).
  Future<VectorSearchBenchmarkResult?> vectorSearchBenchmark(
    String tableName,
    int iterations,
    int topK, {
    int? searchDepth,
    bool verbose = true,
    bool runIdentityDiagnostic = true,
  }) async {
    final depth = VectorRecallHarness.normalizeDepth(searchDepth);
    if (verbose) {
      logService.add('Starting Vector Search Benchmark: table="$tableName", '
          'iterations=$iterations, topK=$topK, searchDepth=$depth');
    }

    final schema = await db.getTableSchema(tableName);
    if (schema == null) {
      logService.add('Benchmark failed: Schema for "$tableName" not found.',
          LogLevel.error);
      return null;
    }

    FieldSchema? vectorField;
    for (final field in schema.fields) {
      if (field.type == DataType.vector) {
        vectorField = field;
        break;
      }
    }
    if (vectorField == null || vectorField.name.isEmpty) {
      logService.add('Benchmark failed: No vector field found in "$tableName".',
          LogLevel.error);
      return null;
    }

    final vectorFieldName = vectorField.name;
    final dims = vectorField.vectorConfig?.dimensions ?? 0;
    if (dims == 0) {
      logService.add(
          'Benchmark failed: Vector dimensions not configured for "$vectorFieldName".',
          LogLevel.error);
      return null;
    }

    final hasVectorIndex = schema.indexes.any((idx) =>
        idx.type == IndexType.vector && idx.fields.contains(vectorFieldName));
    if (!hasVectorIndex && verbose) {
      logService.add(
          'Warning: No vector index found on "$vectorFieldName". Search will be slow.',
          LogLevel.warn);
    }

    Future<void> yieldUi() => Future<void>.delayed(Duration.zero);

    final recall = await VectorRecallHarness.evaluate(
      db: db,
      tableName: tableName,
      topK: topK,
      searchDepth: depth,
      requestedQueries: max(1, iterations),
      runIdentityDiagnostic: runIdentityDiagnostic,
      yieldUi: yieldUi,
      onLog: verbose ? (msg) => logService.add(msg, LogLevel.info) : null,
    );
    if (recall == null) {
      return null;
    }

    final latenciesMs = List<double>.from(recall.annLatenciesMs);
    final extra = max(0, iterations - recall.queryCount);
    if (extra > 0 && recall.queryVectors.isNotEmpty) {
      if (verbose) {
        logService.add('Running $extra additional searches for latency...');
      }
      final random = Random();
      for (var i = 0; i < extra; i++) {
        final queryVector = (recall.canScoreRecall && recall.completeGroups > 0)
            ? ExampleVectorCorpus.groupQuery(
                random.nextInt(recall.completeGroups),
                recall.dimensions,
              )
            : recall.queryVectors[i % recall.queryVectors.length];
        final querySw = Stopwatch()..start();
        await db.vectorSearch(
          tableName,
          fieldName: vectorFieldName,
          queryVector: queryVector,
          topK: topK,
          searchDepth: depth,
        );
        querySw.stop();
        latenciesMs.add(querySw.elapsedMicroseconds / 1000.0);

        if (verbose &&
            iterations >= 100 &&
            (recall.queryCount + i + 1) % (iterations ~/ 5) == 0 &&
            (recall.queryCount + i + 1) < iterations) {
          final done = recall.queryCount + i + 1;
          final pct = (done / iterations * 100).toStringAsFixed(0);
          logService.add(
              '⏳ Benchmark Progress: $done/$iterations completed ($pct%)...',
              LogLevel.info);
        }
        if (i > 0 && i % 50 == 0) {
          await yieldUi();
        }
      }
    }

    final result = VectorSearchBenchmarkResult.fromLatencies(
      recall: recall,
      latenciesMs: latenciesMs,
    );

    if (verbose) {
      _logVectorSearchBenchmarkSummary(
        iterations: iterations,
        topK: topK,
        depth: depth,
        result: result,
      );
    }

    return result;
  }

  /// Runs [vectorSearchDepthSweepPoints] at the current corpus size and logs
  /// one compact table of recall and latency versus searchDepth.
  Future<void> vectorSearchDepthSweep(
    String tableName, {
    int iterations = 100,
    int topK = 10,
    List<int>? depths,
    void Function(int completed, int total)? onProgress,
  }) async {
    final sweepDepths = depths ?? vectorSearchDepthSweepPoints;
    if (sweepDepths.isEmpty) {
      logService.add(
          'Depth sweep skipped: no depths configured.', LogLevel.warn);
      return;
    }

    final rows = <VectorSearchBenchmarkResult>[];
    for (var i = 0; i < sweepDepths.length; i++) {
      final depth = VectorRecallHarness.normalizeDepth(sweepDepths[i]);
      onProgress?.call(i, sweepDepths.length);

      final row = await vectorSearchBenchmark(
        tableName,
        iterations,
        topK,
        searchDepth: depth,
        verbose: false,
        runIdentityDiagnostic: true,
      );
      if (row != null) {
        rows.add(row);
      } else {
        logService.add(
          'Depth sweep stopped at depth=$depth (benchmark failed).',
          LogLevel.error,
        );
        break;
      }

      onProgress?.call(i + 1, sweepDepths.length);
      await Future<void>.delayed(Duration.zero);
    }

    if (rows.isEmpty) {
      logService.add('Depth sweep produced no results.', LogLevel.error);
      return;
    }

    logService.add(
      formatVectorDepthSweepSummary(
        tableName: tableName,
        topK: topK,
        iterations: iterations,
        rows: rows,
      ),
      LogLevel.info,
    );
  }

  void _logVectorSearchBenchmarkSummary({
    required int iterations,
    required int topK,
    required int depth,
    required VectorSearchBenchmarkResult result,
  }) {
    final recall = result.recall;
    final latenciesMs = List<double>.from(recall.annLatenciesMs);
    final totalSearchMs =
        latenciesMs.isEmpty ? 0.0 : latenciesMs.reduce((a, b) => a + b);

    final recallPct = (recall.recallAtK * 100).toStringAsFixed(1);
    final identityPct = recall.identityAt1 == null
        ? 'n/a'
        : '${(recall.identityAt1! * 100).toStringAsFixed(1)}% '
            '(${recall.identityHits}/${recall.identityProbes})';

    if (iterations < 50 && recall.canScoreRecall) {
      logService.add(
          'Note: Recall@K is noisy below ~50 queries. Use 100–1000 iterations '
          'for a stable Recall@K estimate.',
          LogLevel.debug);
    }

    final report = StringBuffer();
    report.writeln('');
    report.writeln('=' * 78);
    report.writeln(
        '        TOSTORE VECTOR SEARCH BENCHMARK SUMMARY ($iterations Iterations)       ');
    report.writeln('=' * 78);
    report.writeln(
        '  Target Table         : ${recall.tableName} (${recall.dimensions}D, ${recall.metricLabel})');
    report.writeln('  Corpus               : ${recall.corpusSize} vectors'
        '${recall.canScoreRecall ? '' : ' (latency only)'}');
    report.writeln(
        '  Total Executed       : ${result.totalSearches} searches (Top-$topK)');
    report.writeln(
        '  Total Search Time    : ${totalSearchMs.toStringAsFixed(2)} ms');
    if (recall.gtElapsedMs > 0) {
      report.writeln('  Setup Time           : ${recall.gtElapsedMs} ms');
    }
    report.writeln('-' * 78);
    if (recall.canScoreRecall) {
      report.writeln('  RECALL@K:');
      report.writeln('    searchDepth        : $depth');
      report.writeln(
          '    ${'Recall@${recall.topK}'.padRight(19)}: $recallPct% (${recall.neighborHits}/${recall.neighborPossible})');
      report.writeln('    Queries            : ${recall.queryCount}'
          '${recall.queryCount < iterations ? ' for Recall@K; $iterations timed' : ''}');
    } else {
      report.writeln('  RECALL@K:');
      report.writeln('    searchDepth        : $depth');
      report.writeln(
          '    Status             : Skipped (insert example vector rows to measure Recall@K)');
    }
    report.writeln('-' * 78);
    report.writeln('  CHECKS:');
    if (recall.canScoreRecall) {
      report.writeln(
          '    Top-1 Hit Rate     : ${(recall.top1HitRate * 100).toStringAsFixed(1)}%  (true nearest is first)');
    }
    report.writeln(
        '    Self-Recall        : $identityPct  (stored vector returns itself first)');
    report.writeln('-' * 78);
    report.writeln('  LATENCY & THROUGHPUT:');
    report.writeln(
        '    Average Latency    : ${result.avgLatencyMs.toStringAsFixed(2)} ms/query');
    report.writeln(
        '    P50 Latency        : ${result.p50LatencyMs.toStringAsFixed(2)} ms');
    report.writeln(
        '    P95 Latency        : ${result.p95LatencyMs.toStringAsFixed(2)} ms');
    report.writeln(
        '    P99 Latency        : ${result.p99LatencyMs.toStringAsFixed(2)} ms');
    report.writeln(
        '    QPS Throughput     : ${result.qps.toStringAsFixed(1)} queries/sec');
    report.writeln('=' * 78);

    logService.add(report.toString().trimRight(), LogLevel.info);
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
