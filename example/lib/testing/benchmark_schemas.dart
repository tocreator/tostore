import 'package:tostore/tostore.dart';

/// Schemas definition for dedicated benchmark tables.
class BenchmarkSchemas {
  /// Embedding width for the vector tier (throughput-friendly, docs-aligned).
  static const int vectorDimensions = 128;

  /// Top-K used by pure ANN (vectorSearch) and hybrid search benches.
  static const int vectorTopK = 10;

  /// Probe count for sampled exact-match recall check (Count column).
  static const int vectorRecallProbes = 100;

  /// Pure PK table (Tier 1) - measures peak engine throughput.
  static const TableSchema simple = TableSchema(
    name: 'benchmark_simple',
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
    name: 'benchmark_indexed',
    primaryKeyConfig: PrimaryKeyConfig(
      name: 'id',
      type: PrimaryKeyType.sequential,
    ),
    fields: [
      FieldSchema(name: 'name', type: DataType.text, nullable: false),
      FieldSchema(name: 'age', type: DataType.integer, nullable: false),
      FieldSchema(
        name: 'created_at',
        type: DataType.datetime,
        defaultValueType: DefaultValueType.currentTimestamp,
      ),
    ],
    indexes: [
      IndexSchema(fields: ['name'], unique: true),
      IndexSchema(fields: ['age']),
    ],
  );

  /// Vector table (Tier 3) - NGH ANN insert / search throughput.
  static const TableSchema vector = TableSchema(
    name: 'benchmark_vector',
    primaryKeyConfig: PrimaryKeyConfig(
      name: 'id',
      type: PrimaryKeyType.sequential,
    ),
    fields: [
      FieldSchema(name: 'label', type: DataType.text, nullable: false),
      FieldSchema(name: 'category', type: DataType.integer, nullable: false),
      FieldSchema(
        name: 'embedding',
        type: DataType.vector,
        nullable: false,
        vectorConfig: VectorFieldConfig(
          dimensions: vectorDimensions,
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
        ),
      ),
    ],
  );

  /// All benchmark schemas.
  static const List<TableSchema> all = [simple, indexed, vector];

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
