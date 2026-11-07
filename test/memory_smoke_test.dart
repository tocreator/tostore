import 'package:test/test.dart';
import 'package:tostore/tostore.dart';

void main() {
  test('memory database inserts, updates, deletes, and stores a key', () async {
    final db = await ToStore.memory(
      dbName: 'ci_smoke',
      schemas: const [
        TableSchema(
          name: 'users',
          primaryKeyConfig: PrimaryKeyConfig(
            name: 'id',
            type: PrimaryKeyType.sequential,
          ),
          fields: [
            FieldSchema(
              name: 'username',
              type: DataType.text,
              nullable: false,
            ),
            FieldSchema(name: 'age', type: DataType.integer),
          ],
        ),
      ],
    );

    try {
      final inserted = await db.insert('users', {
        'username': 'ada',
        'age': 36,
      });
      expect(inserted.hasErrors, isFalse, reason: inserted.message);

      final found = await db.query('users').where('username', '=', 'ada');
      expect(found.hasErrors, isFalse, reason: found.message);
      expect(found.data, hasLength(1));
      expect(found.data.first['username'], 'ada');
      expect(found.data.first['age'], 36);

      final updated =
          await db.update('users', {'age': 37}).where('username', '=', 'ada');
      expect(updated.hasErrors, isFalse, reason: updated.message);
      final afterUpdate = await db.query('users').where('username', '=', 'ada');
      expect(afterUpdate.data.single['age'], 37);

      final deleted = await db.delete('users').where('username', '=', 'ada');
      expect(deleted.hasErrors, isFalse, reason: deleted.message);
      final afterDelete = await db.query('users').where('username', '=', 'ada');
      expect(afterDelete.hasErrors, isFalse, reason: afterDelete.message);
      expect(afterDelete.data, isEmpty);

      final saved = await db.setValue('session', 'ok');
      expect(saved.hasErrors, isFalse, reason: saved.message);
      expect(await db.getValue('session'), 'ok');
    } finally {
      await db.close();
    }
  });
}
