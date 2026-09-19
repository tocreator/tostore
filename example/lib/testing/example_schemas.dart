import 'package:tostore/tostore.dart';

/// Demo / in-app test harness table schemas (not the quickstart templates).
///
/// Use [TableSchema.name] (e.g. [users].name) at call sites so renaming a
/// table only requires changing the schema definition.
class ExampleSchemas {
  ExampleSchemas._();

  static const TableSchema users = TableSchema(
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
      FieldSchema(name: 'type', type: DataType.text, defaultValue: 'user'),
      FieldSchema(name: 'fans', type: DataType.integer, defaultValue: 10),
    ],
    indexes: [
      IndexSchema(fields: ['username'], unique: true),
      IndexSchema(fields: ['email'], unique: true),
      IndexSchema(fields: ['last_login'], unique: false),
      IndexSchema(fields: ['age']),
    ],
  );

  // ForeignKeySchema is not const; keep posts/comments as final.
  static final TableSchema posts = TableSchema(
    name: 'posts',
    primaryKeyConfig: const PrimaryKeyConfig(
      name: 'id',
    ),
    fields: const [
      FieldSchema(name: 'title', type: DataType.text, nullable: false),
      FieldSchema(name: 'content', type: DataType.text),
      FieldSchema(name: 'user_id', type: DataType.integer, nullable: false),
      FieldSchema(
          name: 'created_at',
          type: DataType.datetime,
          defaultValueType: DefaultValueType.currentTimestamp),
      FieldSchema(
          name: 'is_published', type: DataType.boolean, defaultValue: true),
    ],
    foreignKeys: [
      ForeignKeySchema(
        name: 'fk_posts_user',
        fields: const ['user_id'],
        referencedTable: users.name,
        referencedFields: const ['id'],
        onDelete: ForeignKeyCascadeAction.cascade,
        onUpdate: ForeignKeyCascadeAction.cascade,
      ),
    ],
    indexes: const [
      IndexSchema(fields: ['user_id']),
      IndexSchema(fields: ['created_at']),
    ],
  );

  static final TableSchema comments = TableSchema(
    name: 'comments',
    primaryKeyConfig: const PrimaryKeyConfig(
      name: 'id',
    ),
    fields: const [
      FieldSchema(name: 'post_id', type: DataType.integer, nullable: false),
      FieldSchema(name: 'user_id', type: DataType.integer, nullable: false),
      FieldSchema(name: 'content', type: DataType.text, nullable: false),
      FieldSchema(
          name: 'created_at',
          type: DataType.datetime,
          defaultValueType: DefaultValueType.currentTimestamp),
    ],
    foreignKeys: [
      ForeignKeySchema(
        name: 'fk_comments_post',
        fields: const ['post_id'],
        referencedTable: posts.name,
        referencedFields: const ['id'],
        onDelete: ForeignKeyCascadeAction.cascade,
        onUpdate: ForeignKeyCascadeAction.cascade,
      ),
      ForeignKeySchema(
        name: 'fk_comments_user',
        fields: const ['user_id'],
        referencedTable: users.name,
        referencedFields: const ['id'],
        onDelete: ForeignKeyCascadeAction.restrict,
        onUpdate: ForeignKeyCascadeAction.cascade,
      ),
    ],
    indexes: const [
      IndexSchema(fields: ['post_id']),
      IndexSchema(fields: ['user_id']),
    ],
  );

  static const TableSchema settings = TableSchema(
    name: 'settings',
    primaryKeyConfig: PrimaryKeyConfig(),
    isGlobal: true,
    fields: [
      FieldSchema(
          name: 'key', type: DataType.text, nullable: false, unique: true),
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
  );

  /// Interactive example tables. Fill and sweep one table at a time —
  /// do not bulk-load every width together.
  ///
  /// 128 / 512 / 1536: searchDepth alignment.
  /// 4096 / 8192 / 16384 / 65535: high-D insert + flush packing.
  static const int vectorDimLow = 128;
  static const int vectorDimMid = 512;
  static const int vectorDimHigh = 1536;
  static const int vectorDim4096 = 4096;
  static const int vectorDim8192 = 8192;
  static const int vectorDim16384 = 16384;
  static const int vectorDim65535 = 65535;

  /// 128-d (small encoders). Use to catch low-D over-probe / cheap-recall bias.
  static final TableSchema embeddings128 = _cosineNghEmbeddings(
    name: 'embeddings_128',
    dimensions: vectorDimLow,
  );

  /// 512-d default. searchDepth probe budget is calibrated on this table.
  static final TableSchema embeddings512 = _cosineNghEmbeddings(
    name: 'embeddings_512',
    dimensions: vectorDimMid,
  );

  /// 1536-d (large encoders). Use to catch high-D under-probe / concentration.
  static final TableSchema embeddings1536 = _cosineNghEmbeddings(
    name: 'embeddings_1536',
    dimensions: vectorDimHigh,
  );

  static final TableSchema embeddings4096 = _cosineNghEmbeddings(
    name: 'embeddings_4096',
    dimensions: vectorDim4096,
  );

  static final TableSchema embeddings8192 = _cosineNghEmbeddings(
    name: 'embeddings_8192',
    dimensions: vectorDim8192,
  );

  static final TableSchema embeddings16384 = _cosineNghEmbeddings(
    name: 'embeddings_16384',
    dimensions: vectorDim16384,
  );

  static final TableSchema embeddings65535 = _cosineNghEmbeddings(
    name: 'embeddings_65535',
    dimensions: vectorDim65535,
  );

  static List<TableSchema> get vectorTables => [
        embeddings128,
        embeddings512,
        embeddings1536,
        embeddings4096,
        embeddings8192,
        embeddings16384,
        embeddings65535,
      ];

  static TableSchema _cosineNghEmbeddings({
    required String name,
    required int dimensions,
  }) {
    return TableSchema(
      name: name,
      primaryKeyConfig: const PrimaryKeyConfig(
        name: 'id',
        type: PrimaryKeyType.sequential,
      ),
      fields: [
        const FieldSchema(name: 'name', type: DataType.text, nullable: false),
        FieldSchema(
          name: 'embedding',
          type: DataType.vector,
          vectorConfig: VectorFieldConfig(
            dimensions: dimensions,
          ),
        ),
      ],
      indexes: const [
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
  }

  static List<TableSchema> get all => [
        users,
        posts,
        comments,
        settings,
        ...vectorTables,
      ];
}
