---
id: tostore-ai-04-crud-bulk
title: CRUD and Bulk Operations
audience: coding-agent
source_apis:
  - ToStore.insert
  - ToStore.upsert
  - ToStore.update
  - ToStore.delete
  - ToStore.batchInsert
  - ToStore.batchUpsert
  - ToStore.batchUpdate
  - UpdateBuilder
  - DeleteBuilder
  - Expr
version: 3.x
status: complete
---

# CRUD and Bulk Operations

## Purpose

Write paths for single-row, builder-conditioned, and bulk operations; atomic field expressions via `Expr`.

## Single-row writes

```dart
Future<DbResult> insert(String tableName, Map<String, dynamic> data);
Future<DbResult> upsert(String tableName, Map<String, dynamic> data);
```

- `insert`: new row; on success read `firstPrimaryKey`.
- `upsert`: update if PK/unique match, else insert.
- MUST check `!result.hasErrors` (or inspect `statuses`). Constraint failures return results; they do not always throw.

```dart
final r = await db.insert('users', {'username': 'john', 'email': 'a@b.c'});
if (r.hasErrors) {
  // r.firstType.codeKey, r.message, r.statuses
} else {
  final pk = r.firstPrimaryKey;
}
```

## UpdateBuilder

```dart
UpdateBuilder update(String tableName, [Map<String, dynamic> data = const {}]);
```

Awaiting the builder (or `.future`) executes.

| Method | Purpose |
| :--- | :--- |
| `where` / ChainBuilder predicates | Filter (inherited) |
| `set(Map)` / `setField(name, value)` | Assign values (value MAY be `ExprNode`) |
| `increment` / `decrement` / `multiply` / `divide` | Numeric sugar → Expr |
| `min` / `max` / `clamp` | Bound field |
| `setServerTimestamp(field)` | Server time |
| `compute(field, ExprNode)` | Explicit expression |
| `allowUpdateAll()` | REQUIRED if no condition |
| `allowPartialErrors()` | Continue on per-row failures |
| `allowLargeScaleOperation()` | Large update; blocks until done; returns `successCount` only; **MUST NOT** inside transaction |

Without a condition and without `allowUpdateAll()`, update is rejected (safety).

```dart
await db.update('users', {'status': 'inactive'})
  .where('last_login', '<', expired);
await db.update('users', {'status': 'inactive'}).allowUpdateAll();
```

## DeleteBuilder

```dart
DeleteBuilder delete(String tableName);
```

| Method | Purpose |
| :--- | :--- |
| `where` / predicates | Filter |
| `allowDeleteAll()` | REQUIRED if no condition |
| `allowLargeScaleOperation()` | Same large-op rules as update |

## Destructive table ops

```dart
Future<DbResult> dropTable(String tableName);
Future<DbResult> clear(String tableName); // delete all rows, keep schema
```

System tables MUST NOT be targeted (engine throws developer error).

## Bulk APIs

```dart
Future<DbResult> batchInsert(
  String tableName, List<Map<String, dynamic>> dataList, {
  bool allowPartialErrors = true,
  bool returnResultDetails = true,
});
Future<DbResult> batchUpsert(...); // same options
Future<DbResult> batchUpdate(...); // same options
```

| API | Requirements | Behavior |
| :--- | :--- | :--- |
| `batchInsert` | All non-null fields | Insert only; highest throughput |
| `batchUpsert` | All non-null fields **and** unique-index fields; table MUST have unique constraints | Insert or update by unique match |
| `batchUpdate` | Each row MUST include PK (or unique identity) + fields to change | Partial update; non-null fields not all required |

- `allowPartialErrors: true` (default): one bad row does not abort the batch.
- `returnResultDetails: false`: skip success/failure key collection — better perf / less memory.

## Atomic expressions (`Expr`)

Structured AST only — MUST NOT inject raw expression strings.

### Builders

| API | Meaning |
| :--- | :--- |
| `Expr.field(name)` | Current row field |
| `Expr.value(num)` | Constant |
| `Expr.now()` | Server timestamp |
| `Expr.min` / `max` / `round` / `floor` / `ceil` / `abs` | Functions |
| `Expr.isUpdate()` / `Expr.isInsert()` | Upsert branch predicates |
| `Expr.ifElse(cond, then, else)` | Conditional |
| `Expr.when(cond, value, {otherwise})` | Single-branch conditional |
| Operators on `ExprNode` | `+ - * / %` and unary `-` |

### Usage

```dart
// Map form (insert/update/upsert payload)
await db.update('orders', {
  'total': Expr.field('price') * Expr.field('quantity'),
  'balance': Expr.field('balance') + Expr.value(100),
  'updatedAt': Expr.now(),
}).where('id', '=', orderId);

// Chain form
await db.update('orders')
  .increment('balance', 100)
  .compute('total', Expr.field('price') * Expr.field('quantity'))
  .where('id', '=', orderId);

// Upsert insert-vs-update semantics
await db.upsert('counters', {
  'id': 'views',
  'count': Expr.when(
    Expr.isUpdate(),
    Expr.field('count') + Expr.value(1),
    otherwise: 1,
  ),
});
```

Expressions evaluate atomically from current field values at update time.

## Common mistakes

- ❌ Unconditional update/delete without allow*
- ❌ `allowLargeScaleOperation` inside `transaction`
- ❌ `batchUpsert` without unique constraints / missing non-null fields
