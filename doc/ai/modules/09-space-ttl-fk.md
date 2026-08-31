---
id: tostore-ai-09-space-ttl-fk
title: Spaces, Table TTL, and Foreign Keys
audience: coding-agent
source_apis:
  - ToStore.switchSpace
  - ToStore.listSpaces
  - ToStore.deleteSpace
  - ToStore.getSpaceInfo
  - TableTtlConfig
  - ForeignKeySchema
  - ForeignKeyCascadeAction
version: 3.x
status: complete
---

# Spaces, Table TTL, and Foreign Keys

## Spaces

Isolate tenant/user data; global tables stay shared.

| API | Notes |
| :--- | :--- |
| `switchSpace({spaceName = 'default', keepActive = true})` | Switch active space; `keepActive` persists for next launch |
| `listSpaces()` | Sorted; always includes `default` |
| `deleteSpace(name)` | MUST NOT delete `default` or current space |
| `getSpaceInfo({useCache = true})` | Aggregates for **current** space |
| `currentSpaceName` | Getter |

### Global vs local

| | Schema | Data |
| :--- | :--- | :--- |
| `isGlobal: false` (default) | Shared across spaces | **Isolated per space** |
| `isGlobal: true` | Shared | Shared across spaces |

KV: use `isGlobal: true` for cross-space keys (login state, theme).

### Login / logout

```dart
await db.switchSpace(spaceName: 'user_$id', keepActive: true);
// logout
await db.close(keepActiveSpace: false);
// optional: ToStore.open(..., applyActiveSpaceOnDefault: false) to stay on default
```

## Table-level TTL

Background cleanup of expired rows (logs, events, telemetry).

```dart
TableTtlConfig({
  required int ttlMs, // MUST be > 0
  String? sourceField, // null → internal _system_ingest_ts_ms
});
```

If `sourceField` is set, that field MUST be:

1. `DataType.datetime`
2. `nullable: false`
3. `defaultValueType: DefaultValueType.currentTimestamp`

```dart
ttlConfig: TableTtlConfig(
  ttlMs: 7 * 24 * 60 * 60 * 1000,
  // sourceField: 'created_at', // optional
),
```

Runtime: `updateSchema(t).setTtlConfig(...)` / `.disableTtl()`.

Polling interval: `DataStoreConfig.ttlCleanupIntervalMs` (min 60000 ms).

## Foreign keys

```dart
ForeignKeySchema({
  String? name,
  required List<String> fields,
  required String referencedTable,
  required List<String> referencedFields,
  ForeignKeyCascadeAction onDelete = ForeignKeyCascadeAction.restrict,
  ForeignKeyCascadeAction onUpdate = ForeignKeyCascadeAction.restrict,
  bool autoCreateIndex = true,
  bool enabled = true,
  String? comment,
});
```

`fields.length` MUST equal `referencedFields.length`.

| Cascade | Behavior |
| :--- | :--- |
| `restrict` | Block parent delete/update if children exist (default) |
| `cascade` | Propagate delete/update to children |
| `setNull` | Child FK → null (field MUST be nullable) |
| `setDefault` | Child FK → default (field MUST have default) |
| `noAction` | Similar to restrict; check may defer to tx end |

FK joins (preferred over hand-written ON):

- `joinReferencedTable(parent)` — join parent referenced by current table
- `joinReferencingTable(child)` — join children that reference current table
- also `joinWithForeignKey`

```dart
await db.query('posts')
  .joinReferencedTable('users')
  .select(['posts.title', 'users.username'])
  .limit(20);
```
