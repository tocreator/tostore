---
id: tostore-ai-06-stream-reactive
title: Streaming and Reactive Queries
audience: coding-agent
source_apis:
  - ToStore.streamQuery
  - StreamQueryBuilder
  - QueryBuilder.watch
  - ToStore.watchValue
  - ToStore.watchValues
version: 3.x
status: complete
---

# Streaming and Reactive Queries

## Purpose

Process large result sets without loading everything at once, and push live updates to UI / Agents without polling.

## Choose the right API

| Need | API |
| :--- | :--- |
| Stream rows as read (large scan) | `streamQuery` |
| Re-run query when matching table data changes | `query(...).watch()` |
| Watch one/many KV keys | `watchValue` / `watchValues` or `db.kv.watch` |

## StreamQueryBuilder

```dart
StreamQueryBuilder streamQuery(String tableName);
```

| Method | Notes |
| :--- | :--- |
| `select(List<String> fields)` | Projection |
| `where` / `whereIn` / `whereBetween` / `whereNull` / `whereNotNull` / `or` | Filters |
| `stream` / `asStream` / `execute` | `Stream<Map<String, dynamic>>` of **rows** |
| `listen(...)` | Convenience subscription |

```dart
db.streamQuery('users').where('age', '>', 18).listen((row) {
  // one record at a time
});

await for (final row in db.streamQuery('users').whereEqual('id', id).stream) {
  // ...
}
```

## QueryBuilder.watch

```dart
Stream<List<Map<String, dynamic>>> watch();
```

- Emits the **full current result list** whenever matching data changes.
- Built-in debounce to avoid query storms.
- Works with Flutter `StreamBuilder`.

```dart
db.query('users').whereEqual('is_online', true).watch().listen((users) {
  // users is List<Map>
});

StreamBuilder<List<Map<String, dynamic>>>(
  stream: db.query('messages').orderByDesc('id').limit(50).watch(),
  builder: (context, snapshot) { /* ... */ },
);
```

## KV reactive

```dart
Stream<T?> watchValue<T>(String key, {
  bool isGlobal = false,
  T? defaultValue,
  bool distinct = true,
});
Stream<Map<String, dynamic>> watchValues(Iterable<String> keys, {
  bool isGlobal = false,
  bool distinct = true,
});
```

- Emits **current value/snapshot on subscribe**.
- `db.kv.watch<T>` / `db.kv.watchValues` are equivalents under the KV namespace.

```dart
db.watchValue('current_user', isGlobal: true).listen((v) { /* UI */ });
db.kv.watch<int>('unread_count').listen((c) { /* ... */ });
```

## Rules

1. Prefer `watch` / `watchValue` over polling for UI sync.
2. Always `limit` reactive list queries when possible.
3. Cancel subscriptions when widgets dispose.
4. `streamQuery` = per-row stream; `watch` = full result refresh stream — do not confuse them.
