---
id: tostore-ai-09-space-ttl-fk
title: Spaces, Table TTL, Capacity Eviction, and Foreign Keys
audience: coding-agent
source_apis:
  - ToStore.switchSpace
  - ToStore.listSpaces
  - ToStore.deleteSpace
  - ToStore.getSpaceInfo
  - TableTtlConfig
  - CapacityConfig
  - CapacityEvictionPolicy
  - TableCapacityConfig
  - ForeignKeySchema
  - ForeignKeyCascadeAction
version: 3.x
status: complete
---

# Spaces, Table TTL, Capacity Eviction, and Foreign Keys

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

Background cleanup of expired records (logs, events, telemetry).

```dart
TableTtlConfig({
  required int ttlMs, // MUST be > 0
  String? sourceField,
});
```

### `sourceField` rules

| Situation | `sourceField` |
| :--- | :--- |
| **New table** with TTL | **MUST** set |
| **Existing table** enabling TTL for the first time | **MUST** set |
| **Online grandfather**: table already persisted TTL with omitted `sourceField` (virtual `_system_ingest_ts_ms` index) | MAY keep omitting (no forced multi-million-row rebuild) |

When set, `sourceField` MUST be:

1. `DataType.datetime`
2. `nullable: false`
3. `defaultValueType: DefaultValueType.currentTimestamp`

```dart
ttlConfig: TableTtlConfig(
  ttlMs: 7 * 24 * 60 * 60 * 1000,
  sourceField: 'created_at', // required for new tables / newly enabling TTL
),
```

Prefer an explicit field so deletes clear the TTL index via normal encode/decode. The virtual ingest index is INSERT-only and relies on search-result tombstones — kept only for online compatibility.

Runtime: `updateSchema(t).setTtlConfig(...)` / `.disableTtl()`.

Polling interval: `DataStoreConfig.ttlCleanupIntervalMs` (min 60000 ms).

## Table-level capacity eviction (FIFO / LRU)

Limit how many records (or how much storage) a table may keep. Independent of TTL: time expiry and capacity eviction MAY be enabled together.

```dart
CapacityConfig({
  int? maxEntries, // max record count
  int? maxBytes,   // approximate max storage size (bytes)
  CapacityEvictionPolicy policy = CapacityEvictionPolicy.fifo,
  double evictRatio = 0.30, // fraction to free when over limit (0.05–0.50)
  String? sourceField, // see policy rules below
});
typedef TableCapacityConfig = CapacityConfig;
```

MUST set at least one of `maxEntries` / `maxBytes` to a value `> 0`.

| Policy | Behavior |
| :--- | :--- |
| `fifo` (primary key type ≠ `none`) | Evict by primary key ascending. MUST NOT set `sourceField`. |
| `fifo` + `PrimaryKeyType.none` | MUST set `sourceField`: insert-time `DataType.datetime`, non-null, `DefaultValueType.currentTimestamp`. Do not update that field after insert. |
| `lru` | MUST set `sourceField` (same datetime rules). Update it when a record should count as recently used. |

`sourceField` is required **only** for `lru`, or for `fifo` when the table uses `PrimaryKeyType.none`.

Capacity does **not** use the virtual `_system_ingest_ts_ms` index (TTL-only grandfather path when `sourceField` was historically omitted). Deletes go through the normal write path so index entries are removed from record values.

When over the limit, background cleanup frees about `evictRatio` of capacity (default 30%) across cycles so writes stay smooth.

```dart
capacityConfig: CapacityConfig(
  maxEntries: 10000,
  policy: CapacityEvictionPolicy.lru,
  sourceField: 'last_active_at',
),
```

Runtime: `updateSchema(t).setCapacityConfig(...)` / `.disableCapacity()`.

KV capacity (`DataStoreConfig.kvCapacityConfig` / `globalKvCapacityConfig`) uses the same `CapacityConfig` shape but MUST NOT set `sourceField` — the engine manages KV ordering.

Do not confuse with `cacheMemoryBudgetMB` — that tunes engine memory cache, not table record limits.

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
