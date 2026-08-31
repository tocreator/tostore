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

  static const TableSchema embeddings = TableSchema(
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
        ),
      ),
    ],
    indexes: [
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

  static List<TableSchema> get all => [
        users,
        posts,
        comments,
        settings,
        embeddings,
      ];
}
