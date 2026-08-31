---
id: tostore-ai-05-query-chain
title: Query Chain
audience: coding-agent
source_apis:
  - ToStore.query
  - QueryBuilder
  - ChainBuilder
  - QueryCondition
  - QueryAggregation
  - Agg
version: 3.x
status: complete
---

# Query Chain

## Purpose

Build structured queries with predicates, projection, JOIN, aggregation, pagination, cache, peek, and hybrid vector match on one chain.

## Entry

```dart
QueryBuilder query(String tableName);
```

- `await builder` / `.future` → `QueryResult<Map<String, dynamic>>`
- Also: `first()`, `count()`, `exists()`, `sum`/`avg`/`min`/`max`, `peek*`, `watch()`

**SHOULD** always set `limit` for list queries. If omitted, engine default is **1000** (`DataStoreConfig.defaultQueryLimit`).

## ChainBuilder predicates

### Generic

| Method | Notes |
| :--- | :--- |
| `where(field, op, value)` | See operators table |
| `whereIn` / `whereNotIn` | List membership |
| `whereBetween(field, start, end)` | Range |
| `whereNull` / `whereNotNull` | Null checks |
| `whereLike` / `whereNotLike` | Pattern (`%`, `_`) |
| `or()` | Switch to OR for following clause |
| `orWhere(...)` | OR single condition |
| `condition(QueryCondition)` / `orCondition(...)` | Nest complex trees |
| `orderByAsc` / `orderByDesc` | Sort |
| `limit(n)` / `offset(n)` / `cursor(token?)` | Page; `cursor` ↔ `offset` mutually exclusive |

### Semantic helpers (preferred)

`whereEqual`, `whereNotEqual`, `whereGreaterThan`, `whereGreaterThanOrEqualTo`, `whereLessThan`, `whereLessThanOrEqualTo`, `whereContains`, `whereNotContains`, `whereStartsWith`, `whereEndsWith`, `whereContainsAny`, `whereEmpty`, `whereNotEmpty`, `whereTrue`, `whereFalse`.

### Operators for `where(field, op, value)` (case-insensitive)

| Op | Index friendliness |
| :--- | :--- |
| `=` | Seek — recommended |
| `!=` `<>` | Often full scan — caution |
| `>` `>=` `<` `<=` | Index scan — recommended |
| `IN` | Seek — recommended |
| `NOT IN` | Caution |
| `BETWEEN` | Index scan — recommended |
| `LIKE` / `NOT LIKE` | Caution (prefix `John%` better than `%John`) |
| `IS` / `IS NOT` (null) | Prefer `whereNull` / `whereNotNull` |

## QueryBuilder features

| Method | Purpose |
| :--- | :--- |
| `select(fields)` | Projection |
| `selectAgg` / `groupBy` / `having(QueryCondition)` | Aggregation |
| `distinct([fields])` | Distinct |
| `join` / `leftJoin` / `rightJoin` | Relational joins |
| `joinWithForeignKey` / `joinReferencedTable` / `joinReferencingTable` | FK-aware joins |
| `matchVector` / `orMatchVector` | Hybrid vector (see Vector module) |
| `useQueryCache([Duration?])` / `noQueryCache()` / `clearQueryCache()` | Result cache |
| `first` / `count` / `exists` | Convenience |
| `sum` / `avg` / `min` / `max` | Single-field aggregates |
| `clone()` | Copy builder |
| `watch()` | Reactive full-result stream (see Streaming module) |

## QueryResult pagination

| Field / API | Use |
| :--- | :--- |
| `data` | Rows |
| `hasMore` / `hasPrev` | Page flags |
| `next()` / `prev()` | **Preferred** in-process paging |
| `nextCursorToken` / `prevCursorToken` | Cross-process / network only |
| `.cursor(token)` on next query | Stateless token seek |
| `hasErrors` / `type` / `message` | Status |
| `retrieval` | Hybrid/vector diagnostics |
| `peekNext()` / `peekPrev()` | Sync page turn if cached |

### Offset vs cursor

| Mode | When |
| :--- | :--- |
| `offset` + `limit` | Small data, exact page jump |
| `limit` + `next()`/`prev()` (cursor) | Large data, infinite scroll — **recommended** |

Deep `offset` degrades linearly. Respect `DataStoreConfig.maxQueryOffset`.

```dart
final page1 = await db.query('users').orderByDesc('id').limit(20);
if (page1.hasMore) {
  final page2 = await page1.next();
}
```

## Memory peek (sync, cache-only)

On miss: empty/`null` immediately — **no** sync disk I/O.

| Method | Returns |
| :--- | :--- |
| `peekFirst()` | `Map?` |
| `peek()` | `QueryResult` (may be empty) |
| `peekExists()` | `bool` |
| `peekCount()` | `int` |

```dart
final q = db.query('users').whereEqual('id', userId);
final user = q.peekFirst() ?? await q.first();
```

## QueryCondition

Build nested AND/OR trees for complex logic; attach via `.condition(...)` / `.orCondition(...)` / `.having(...)`.

## Query cache

```dart
await db.query('users').whereEqual('id', 1).useQueryCache();
await db.query('users').whereEqual('id', 1).useQueryCache(Duration(minutes: 5));
await db.query('users').noQueryCache();
await db.query('users').clearQueryCache();
```

## Aggregation sketch

```dart
final result = await db.query('orders')
  .selectAgg([Agg.sum('amount'), Agg.count()])
  .groupBy(['status'])
  .having(QueryCondition()..where('amount_sum', '>', 1000));
```

(Exact `Agg` / `QueryAggregation` constructors: see exported `query_aggregation.dart` — prefer README Aggregation section patterns when filling app code.)

## Common mistakes

- ❌ Unbounded queries without `limit`
- ❌ Deep `offset` on huge tables
- ❌ Inventing SQL strings
- ❌ Assuming `peek` hits disk
