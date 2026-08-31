---
id: tostore-ai-02-lifecycle
title: Lifecycle
audience: coding-agent
source_apis:
  - ToStore.open
  - ToStore.memory
  - ToStore.close
  - ToStore.deleteDatabase
  - ToStore.flush
  - ToStore.getVersion
  - ToStore.setVersion
version: 3.x
status: complete
---

# Lifecycle

## Purpose

Create, initialize, observe startup, flush, close, and destroy ToStore instances.

## Preferred constructors

### `ToStore.open`

**Signature (conceptual):**

```dart
static Future<ToStore> open({
  String? dbPath,
  String? dbName,
  DataStoreConfig? config,
  List<TableSchema> schemas = const [],
  StartupProgressCallback? onStartupProgress,
  Future<void> Function(ToStore db)? onConfigure,
  Future<void> Function(ToStore db)? onCreate,
  Future<void> Function(ToStore db)? onOpen,
  bool reinitialize = false,
  bool noPersistOnClose = false,
  bool applyActiveSpaceOnDefault = true,
})
```

- **MUST** use this for persistent databases.
- Multi-instance: different `dbPath` and/or `dbName` → different instances.
- `dbPath` / `dbName` arguments override the same fields on `config`.
- `schemas`: initial/declarative schemas for automatic migration (typical mobile apps).
- `applyActiveSpaceOnDefault`: when true, opening space `default` may restore last active space.
- `reinitialize`: force close-then-open; pair with `noPersistOnClose` when skipping buffer flush on close.

### `ToStore.memory`

```dart
static Future<ToStore> memory({
  String? dbName,
  DataStoreConfig? config,
  List<TableSchema> schemas = const [],
  Future<void> Function(ToStore db)? onConfigure,
  Future<void> Function(ToStore db)? onCreate,
  Future<void> Function(ToStore db)? onOpen,
  bool reinitialize = false,
})
```

- No WAL / recovery / meta persistence; data lives in memory.
- Engine forces `PersistenceMode.memory`, disables journal, etc.
- Use for tests, ephemeral session stores, fast in-process caches.

### Deprecated (MUST NOT in new code)

- `factory ToStore({...})`
- `Future<void> initialize({...})`

## Instance properties / methods

| API | Returns | Notes |
| :--- | :--- | :--- |
| `config` | `DataStoreConfig` | Live config |
| `currentSpaceName` | `String?` | Active space |
| `instancePath` | `String?` | Final storage directory |
| `getVersion()` | `Future<int>` | User-defined only |
| `setVersion(int)` | `Future<void>` | User-defined only |
| `flush({bool flushStorage = true})` | `Future<void>` | Persist pending writes |
| `close({bool keepActiveSpace = true})` | `Future<void>` | Releases instance from pool; `keepActiveSpace: false` clears active space (e.g. logout) |
| `deleteDatabase({dbPath, dbName})` | `Future<void>` | Deletes DB files; removes instance from pool |

## Startup progress

```dart
typedef StartupProgressCallback = void Function(
  double progress, // 0.0–1.0
  DbStartupStage stage,
);
```

See enum `DbStartupStage` in package exports.

## Canonical example

```dart
import 'package:tostore/tostore.dart';

Future<ToStore> openAppDb(String path) {
  return ToStore.open(
    dbPath: path,
    dbName: 'app',
    schemas: const [/* TableSchema... */],
    onStartupProgress: (p, stage) {
      // optional UI / Agent progress
    },
  );
}
```

## Mobile vs server (summary)

- **Mobile/desktop apps:** often pass `schemas` at `open`; use path_provider (or equivalent) on mobile.
- **Server/Agent:** may create tables dynamically; tune `DataStoreConfig` (`isServerEnvironment`, concurrency, partition sizes). Details in **Config & Security**.
