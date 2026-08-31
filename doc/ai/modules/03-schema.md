---
id: tostore-ai-03-schema
title: Schema Definition and Evolution
audience: coding-agent
source_apis:
  - TableSchema
  - FieldSchema
  - IndexSchema
  - PrimaryKeyConfig
  - SchemaBuilder
  - ToStore.updateSchema
  - ToStore.createTable
  - ToStore.createTables
version: 3.x
status: complete
---

# Schema Definition and Evolution

## Purpose

Declare table structure once; the engine validates, indexes, migrates, and evolves schemas online.

## TableSchema

```dart
const TableSchema({
  required String name,
  required PrimaryKeyConfig primaryKeyConfig,
  required List<FieldSchema> fields,
  List<IndexSchema> indexes = const [],
  List<ForeignKeySchema> foreignKeys = const [],
  bool isGlobal = false,
  String? tableId,
  TableTtlConfig? ttlConfig,
});
```

| Field | Rules |
| :--- | :--- |
| `name` | Required table name |
| `tableId` | Optional stable id. Used mainly on **mobile/desktop** when schemas are passed to `open`: the engine matches `tableId` across versions to detect **table renames** automatically. **Server/Agent** apps that create/rename tables via runtime APIs usually omit it. |
| `primaryKeyConfig` | Required; see PrimaryKeyConfig |
| `fields` | Non-PK columns |
| `indexes` | Explicit / composite / vector indexes |
| `foreignKeys` | Optional; see Spaces / TTL / FK module |
| `isGlobal` | `true` = shared across spaces; data not space-isolated |
| `ttlConfig` | `null` = TTL off; see TTL module |

**MUST NOT** use the reserved prefix `_system_` for business table/field names (engine-reserved). Business may use `system_` without the leading underscore.

## PrimaryKeyConfig

```dart
const PrimaryKeyConfig({
  String name = 'id',
  PrimaryKeyType type = PrimaryKeyType.sequential,
  SequentialIdConfig? sequentialConfig,
  bool? isOrdered,
  String? fromFieldId, // promote-to-PK: source fieldId when renaming in declarative schemas
});
```

All primary key values are stored as **text (`String`)**.

| `PrimaryKeyType` | Behavior |
| :--- | :--- |
| `none` | Caller MUST supply PK on insert |
| `sequential` | Human-friendly increment; use `SequentialIdConfig` |
| `timestampBased` | Recommended for distributed |
| `datePrefixed` | Date-readable distributed ids |
| `shortCode` | Compact Base62-style ids |

```dart
const SequentialIdConfig({
  int initialValue = 1,
  int increment = 1,
  bool useRandomIncrement = false,
});
```

## FieldSchema

```dart
const FieldSchema({
  required String name,
  required DataType type,
  bool nullable = true,
  dynamic defaultValue,
  bool unique = false,
  bool createIndex = false,
  int? maxLength,
  int? minLength,
  num? minValue,
  num? maxValue,
  String? comment,
  String? fieldId,
  VectorFieldConfig? vectorConfig, // when type == DataType.vector
  DefaultValueType defaultValueType = DefaultValueType.none,
});
```

### DataType → Dart

| DataType | Dart | Notes |
| :--- | :--- | :--- |
| `integer` | `int` | |
| `bigInt` | `BigInt` / `String` | Prefer when > 18 digits |
| `double` | `double` | |
| `text` | `String` | |
| `blob` | `Uint8List` | |
| `boolean` | `bool` | |
| `datetime` | `DateTime` / `String` | Stored ISO8601 |
| `array` | `List` | |
| `json` | `Map<String, dynamic>` | |
| `vector` | `VectorData` / `List<num>` | Needs `vectorConfig` |
| `dynamic` | arbitrary Dart | No forced conversion |

### Constraints (engine-enforced)

- `nullable: false` — non-null
- `minLength` / `maxLength` — text
- `minValue` / `maxValue` — numeric
- `defaultValue` — static default
- `defaultValueType: currentTimestamp` — dynamic timestamp default
- `unique: true` — unique + auto single-field unique index
- `createIndex: true` — auto single-field normal index
- `fieldId` — optional stable field id for **declarative** rename detection (same mobile/`open(schemas:)` path as `tableId`). Server/Agent runtime `updateSchema` renames do not need it.

Composite / named / vector indexes: declare in `indexes` (`IndexSchema`).

## IndexSchema

```dart
IndexSchema({
  String? indexName,
  required List<String> fields,
  bool unique = false,
  IndexType type = IndexType.btree, // btree | vector
  // vector indexes also use VectorIndexConfig (see Vector module)
});
```

PK-only indexes are redundant (table already partitioned by PK) and SHOULD NOT be declared.

## Creation APIs

```dart
Future<DbResult> createTable(TableSchema schema);
Future<DbResult> createTables(List<TableSchema> schemas);
```

Check `!result.hasErrors`. Batch create may succeed partially — inspect `successCount` / `failedCount` / `statuses`.

### Integration choice

| Context | Pattern |
| :--- | :--- |
| Mobile / Desktop | Pass `schemas:` into `ToStore.open(...)` |
| Server / Agent | `await db.createTables(appSchemas)` at runtime |

## Schema evolution

Engine detects add/remove/rename of tables/fields, attribute and index changes, then migrates data online.

- **Declarative:** change `schemas` passed to `open` — applied on startup.
- **Runtime:** `updateSchema(tableName)` chain.

Reads/writes stay available during migration (business-transparent).

### SchemaBuilder

```dart
SchemaBuilder updateSchema(String tableName);
// await the builder → SchemaUpdateResult
```

| Method | Purpose |
| :--- | :--- |
| `addField(name, type, {…FieldSchema props})` | Add column |
| `removeField(name)` | Drop column |
| `renameField(old, new)` | Rename |
| `modifyField(name, updater)` | Change field attributes |
| `addIndex({…})` / `removeIndex({indexName, fields})` | Indexes |
| `renameTable(newName)` | Rename table |
| `setPrimaryKeyConfig(PrimaryKeyConfig)` | Change PK config |
| `promoteFieldToPrimaryKey({sourceFieldName, targetPrimaryKeyName?})` | Promote unique non-null field to PK |
| `setTtlConfig` / `disableTtl` | Table TTL |
| `addForeignKey` / `removeForeignKey` / `modifyForeignKey` | FKs |
| `allowAfterDataMigration()` | Allow ops that require post-data migration |

```dart
final result = await db.updateSchema('users')
  .addField('age', DataType.integer)
  .renameField('name', 'full_name');
final taskId = result.taskId;
if (taskId != null) {
  final status = await db.queryMigrationTaskStatus(taskId);
}
```

### Promote field to primary key

Target field MUST be **unique and non-null**.

- **Declarative `open(schemas:)`:** target PK MUST use `PrimaryKeyType.none`. For rename, set `fromFieldId` on `PrimaryKeyConfig` to source `fieldId`.
- **Runtime:** `promoteFieldToPrimaryKey(sourceFieldName: …, targetPrimaryKeyName: …)` — omit target to keep source name.
- MUST NOT combine promote with `setPrimaryKeyConfig` in the same change set.

## Introspection

| API | Returns |
| :--- | :--- |
| `tableExists(name)` | schema exists (not “has rows”) |
| `getTableSchema(name)` | `TableSchema?` |
| `getTableNames({isGlobal})` | filter global / non-global / all |
| `getTableInfo(name)` | counts, sizes, schema meta |

Non-global **schemas** are shared across spaces; only **data** is space-isolated.

## Canonical example

```dart
const userSchema = TableSchema(
  name: 'users',
  tableId: 'users',
  primaryKeyConfig: PrimaryKeyConfig(
    name: 'id',
    type: PrimaryKeyType.timestampBased,
  ),
  fields: [
    FieldSchema(
      name: 'username',
      type: DataType.text,
      nullable: false,
      unique: true,
      minLength: 3,
      maxLength: 32,
      fieldId: 'username',
    ),
    FieldSchema(
      name: 'created_at',
      type: DataType.datetime,
      nullable: false,
      defaultValueType: DefaultValueType.currentTimestamp,
      createIndex: true,
    ),
  ],
  isGlobal: false,
);
```
