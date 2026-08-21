import 'package:tostore/tostore.dart';

/// Schemas definition for dedicated benchmark tables.
class BenchmarkSchemas {
  static const String simpleTable = 'benchmark_simple';
  static const String indexedTable = 'benchmark_indexed';

  /// Pure PK table (Tier 1) - measures peak engine throughput.
  static const TableSchema simple = TableSchema(
    name: simpleTable,
    primaryKeyConfig: PrimaryKeyConfig(
      name: 'id',
      type: PrimaryKeyType.sequential,
    ),
    fields: [
      FieldSchema(name: 'text_val', type: DataType.text, nullable: false),
      FieldSchema(name: 'num_val', type: DataType.integer, nullable: false),
    ],
    indexes: [],
  );

  /// Indexed table (Tier 2) - measures index maintenance and search acceleration.
  static const TableSchema indexed = TableSchema(
    name: indexedTable,
    primaryKeyConfig: PrimaryKeyConfig(
      name: 'id',
      type: PrimaryKeyType.sequential,
    ),
    fields: [
      FieldSchema(name: 'name', type: DataType.text, nullable: false),
      FieldSchema(name: 'age', type: DataType.integer, nullable: false),
      FieldSchema(name: 'score', type: DataType.double, nullable: false),
      FieldSchema(
        name: 'created_at',
        type: DataType.datetime,
        defaultValueType: DefaultValueType.currentTimestamp,
      ),
    ],
    indexes: [
      IndexSchema(fields: ['name'], unique: true),
      IndexSchema(fields: ['age']),
      IndexSchema(fields: ['score']),
    ],
  );

  /// All benchmark schemas.
  static const List<TableSchema> all = [simple, indexed];

  /// Ensures that all required benchmark tables exist in the database.
  static Future<void> ensureTables(ToStore db) async {
    for (final schema in all) {
      final exists = await db.tableExists(schema.name);
      if (!exists) {
        await db.createTable(schema);
      }
    }
  }
}
