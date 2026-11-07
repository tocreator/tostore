import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tostore/tostore.dart';

/// Package-level foundational coverage for CI / Flutter Favorite quality signals.
///
/// [ToStore.open] is the primary path (structured tables, indexes, spaces, tx).
/// [ToStore.memory] is a short representative smoke only.
void main() {
  group('ToStore.memory smoke', () {
    late ToStore db;

    setUp(() async {
      db = await ToStore.memory(
        dbName: 'mem_smoke_${_suffix()}',
        schemas: [_usersSchema()],
      );
    });

    tearDown(() async {
      await db.close();
    });

    test('CRUD + KV round-trip', () async {
      final insert = await db.insert('users', {
        'username': 'mem_user',
        'email': 'mem@example.com',
        'age': 21,
      });
      expect(insert.hasErrors, isFalse);

      final found = await db.query('users').whereEqual('username', 'mem_user');
      expect(found.data, hasLength(1));
      expect(found.data.first['email'], 'mem@example.com');

      final kvSet = await db.kv.set('greeting', 'hello');
      expect(kvSet.hasErrors, isFalse);
      expect(await db.kv.get('greeting'), 'hello');
    });
  });

  group('ToStore.open feature coverage', () {
    late Directory tempDir;
    late ToStore db;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('tostore_feature_');
      db = await ToStore.open(
        dbPath: tempDir.path,
        dbName: 'feature_${_suffix()}',
        schemas: [
          _usersSchema(),
          _hybridSchema(),
        ],
      );
    });

    tearDown(() async {
      await db.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('structured table insert / query / update / delete', () async {
      final insert = await db.insert('users', {
        'username': 'alice',
        'email': 'alice@example.com',
        'age': 30,
      });
      expect(insert.hasErrors, isFalse);
      final pk = insert.firstPrimaryKey;
      expect(pk, isNotNull);

      final byName = await db.query('users').whereEqual('username', 'alice');
      expect(byName.data, hasLength(1));
      expect(byName.data.first['age'], 30);

      final update = await db.update('users', {'age': 31}).whereEqual('id', pk);
      expect(update.hasErrors, isFalse);

      final afterUpdate = await db.query('users').whereEqual('id', pk).first();
      expect(afterUpdate?['age'], 31);

      final delete = await db.delete('users').whereEqual('id', pk);
      expect(delete.hasErrors, isFalse);
      expect(delete.successCount, 1);
      // Prefer query materialization over count() for immediate post-delete checks.
      expect((await db.query('users')).data, isEmpty);
    });

    test('text index matchText', () async {
      final a = await db.insert('docs', {
        'headline': 'Doc A',
        'content':
            'distributed database storage engine architecture with inverted index',
        'category': 'tech',
        'year': 2024,
      });
      final b = await db.insert('docs', {
        'headline': 'Doc B',
        'content': 'cooking recipes with fresh vegetables and olive oil',
        'category': 'food',
        'year': 2023,
      });
      expect(a.hasErrors, isFalse);
      expect(b.hasErrors, isFalse);

      // Text indexes are searchable before flush.
      final hits = await db
          .query('docs')
          .select(['id'])
          .matchText('content', TextQuery.text('database architecture'))
          .limit(5);

      expect(hits.type, ResultType.success);
      expect(hits.data, isNotEmpty);
      expect(
        hits.data.map((r) => r['id']?.toString()),
        contains(a.firstPrimaryKey),
      );
      expect(
        hits.data.map((r) => r['id']?.toString()),
        isNot(contains(b.firstPrimaryKey)),
      );
      expect(hits.retrieval?.entries.length, hits.data.length);
    });

    test('neural sparse index matchSparse', () async {
      final a = await db.insert('docs', {
        'headline': 'Sparse A',
        'content': 'alpha document',
        'category': 'tech',
        'year': 2024,
        'features':
            SparseVectorData.fromMap({10: 0.95, 500: 0.45, 120000: 0.88}),
      });
      final b = await db.insert('docs', {
        'headline': 'Sparse B',
        'content': 'beta document',
        'category': 'tech',
        'year': 2024,
        'features':
            SparseVectorData.fromMap({10: 0.20, 777: 0.99, 120000: 0.31}),
      });
      expect(a.hasErrors, isFalse);
      expect(b.hasErrors, isFalse);

      final hits = await db
          .query('docs')
          .select(['id'])
          .matchSparse(
            'features',
            SparseVectorData.fromMap({777: 1.0}),
          )
          .limit(5);

      expect(hits.type, ResultType.success);
      expect(hits.data, isNotEmpty);
      expect(hits.data.first['id']?.toString(), b.firstPrimaryKey);
    });

    test('vector index matchVector after flush', () async {
      const dims = _vectorDims;
      final exact = _axisVector(dims, 0);
      final other = _axisVector(dims, 1);

      final a = await db.insert('docs', {
        'headline': 'Vec A',
        'content': 'vector document alpha',
        'category': 'tech',
        'year': 2024,
        'embedding': exact,
      });
      final b = await db.insert('docs', {
        'headline': 'Vec B',
        'content': 'vector document beta',
        'category': 'tech',
        'year': 2024,
        'embedding': other,
      });
      expect(a.hasErrors, isFalse);
      expect(b.hasErrors, isFalse);

      // Dense vector ANN builds on flush, not the write path.
      await db.flush();

      final hits = await db
          .query('docs')
          .select(['id'])
          .matchVector('embedding', exact, searchDepth: 50)
          .limit(5);

      expect(hits.type, ResultType.success);
      expect(hits.data, isNotEmpty);
      expect(hits.data.first['id']?.toString(), a.firstPrimaryKey);
      expect(hits.retrieval?.entries.first.score, closeTo(1.0, 1e-6));
    });

    test('transaction commit and rollback', () async {
      final commit = await db.transaction(() async {
        await db.insert('users', {
          'username': 'tx_ok',
          'email': 'tx_ok@example.com',
          'age': 25,
        });
      });
      expect(commit.hasErrors, isFalse);
      expect(
        (await db.query('users').whereEqual('username', 'tx_ok')).data,
        hasLength(1),
      );

      final rollback = await db.transaction(() async {
        await db.insert('users', {
          'username': 'tx_fail',
          'email': 'tx_fail@example.com',
          'age': 26,
        });
        throw StateError('simulated failure');
      }, rollbackOnError: true);
      expect(rollback.hasErrors, isTrue);
      expect(
        (await db.query('users').whereEqual('username', 'tx_fail')).data,
        isEmpty,
      );
    });

    test('space switch isolates table and KV data', () async {
      await db.switchSpace(spaceName: 'space_a');
      await db.insert('users', {
        'username': 'user_a',
        'email': 'a@example.com',
        'age': 20,
      });
      await db.kv.set('note', 'in_a');

      await db.switchSpace(spaceName: 'space_b');
      expect((await db.query('users')).data, isEmpty);
      expect(await db.kv.get('note'), isNull);

      await db.insert('users', {
        'username': 'user_b',
        'email': 'b@example.com',
        'age': 22,
      });
      await db.kv.set('note', 'in_b');

      await db.switchSpace(spaceName: 'space_a');
      final inA = await db.query('users').whereEqual('username', 'user_a');
      expect(inA.data, hasLength(1));
      expect(await db.kv.get('note'), 'in_a');

      // Global KV is shared across spaces.
      await db.kv.set('shared', 'yes', isGlobal: true);
      await db.switchSpace(spaceName: 'space_b');
      expect(await db.kv.get('shared', isGlobal: true), 'yes');
      expect(await db.kv.get('note'), 'in_b');
    });

    test('reopen persisted open database', () async {
      final dbName = 'persist_${_suffix()}';
      final persistPath = p.join(tempDir.path, 'persist_root');

      var local = await ToStore.open(
        dbPath: persistPath,
        dbName: dbName,
        schemas: [_usersSchema()],
      );
      final insert = await local.insert('users', {
        'username': 'persisted',
        'email': 'p@example.com',
        'age': 40,
      });
      expect(insert.hasErrors, isFalse);
      await local.close();

      local = await ToStore.open(
        dbPath: persistPath,
        dbName: dbName,
        schemas: [_usersSchema()],
      );
      addTearDown(() async {
        await local.close();
      });

      final found =
          await local.query('users').whereEqual('username', 'persisted');
      expect(found.data, hasLength(1));
      expect(found.data.first['email'], 'p@example.com');
    });
  });
}

const int _vectorDims = 16;

TableSchema _usersSchema() => const TableSchema(
      name: 'users',
      primaryKeyConfig: PrimaryKeyConfig(
        name: 'id',
        type: PrimaryKeyType.sequential,
      ),
      fields: [
        FieldSchema(name: 'username', type: DataType.text, nullable: false),
        FieldSchema(name: 'email', type: DataType.text, nullable: false),
        FieldSchema(name: 'age', type: DataType.integer, defaultValue: 18),
      ],
      indexes: [
        IndexSchema(fields: ['username'], unique: true),
        IndexSchema(fields: ['email'], unique: true),
      ],
    );

TableSchema _hybridSchema() => TableSchema(
      name: 'docs',
      primaryKeyConfig: const PrimaryKeyConfig(
        name: 'id',
        type: PrimaryKeyType.sequential,
      ),
      fields: [
        const FieldSchema(
            name: 'headline', type: DataType.text, nullable: false),
        const FieldSchema(
            name: 'content', type: DataType.text, nullable: false),
        const FieldSchema(
            name: 'category', type: DataType.text, nullable: false),
        const FieldSchema(
            name: 'year', type: DataType.integer, nullable: false),
        const FieldSchema(
            name: 'features', type: DataType.sparse, nullable: true),
        FieldSchema(
          name: 'embedding',
          type: DataType.vector,
          nullable: true,
          vectorConfig: VectorFieldConfig(dimensions: _vectorDims),
        ),
      ],
      indexes: const [
        IndexSchema(fields: ['category']),
        IndexSchema(fields: ['content'], type: IndexType.text),
        IndexSchema(fields: ['features'], type: IndexType.sparse),
        IndexSchema(
          fields: ['embedding'],
          type: IndexType.vector,
          vectorConfig: VectorIndexConfig(
            indexType: VectorIndexType.ngh,
            distanceMetric: VectorDistanceMetric.cosine,
          ),
        ),
      ],
    );

VectorData _axisVector(int dims, int axis) {
  final values = List<double>.filled(dims, 0.0);
  values[axis % dims] = 1.0;
  return VectorData.fromList(values);
}

String _suffix() {
  final now = DateTime.now().microsecondsSinceEpoch;
  final rand = Random().nextInt(1 << 20);
  return '${now}_$rand';
}
