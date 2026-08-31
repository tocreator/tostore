---
id: tostore-ai-11-admin-backup
title: Administration, Backup, and Diagnostics
audience: coding-agent
source_apis:
  - ToStore.backup
  - ToStore.restore
  - ToStore.flush
  - ToStore.status
  - ToStore.setLogConfig
  - BackupScope
  - DbStatus
version: 3.x
status: complete
---

# Administration, Backup, and Diagnostics

## Table / space / instance ops

(Also covered in Schema / Spaces modules — admin checklist.)

| Area | APIs |
| :--- | :--- |
| Tables | `createTable`, `getTableSchema`, `getTableNames`, `getTableInfo`, `clear`, `dropTable` |
| Spaces | `currentSpaceName`, `listSpaces`, `getSpaceInfo`, `deleteSpace` |
| Instance | `config`, `instancePath`, `getVersion`/`setVersion` (app bookkeeping only) |
| Maintenance | `flush({flushStorage = true})`, `deleteDatabase({dbPath, dbName})` |

## Backup & restore

```dart
Future<String> backup({
  bool compress = true,
  BackupScope scope = BackupScope.currentSpaceWithGlobal,
});

Future<bool> restore(
  String backupPath, {
  bool deleteAfterRestore = false,
  bool cleanupBeforeRestore = true,
});
```

| `BackupScope` | Contents |
| :--- | :--- |
| `database` | Entire instance (all spaces + globals) |
| `currentSpace` | Current space only (no globals) |
| `currentSpaceWithGlobal` | Current space + related globals (default; single-user migrate) |

- Prefer `cleanupBeforeRestore: true` to avoid mixed logical state.
- `deleteAfterRestore: true` removes backup file after success.

```dart
final path = await db.backup(
  compress: true,
  scope: BackupScope.currentSpaceWithGlobal,
);
final ok = await db.restore(path,
  cleanupBeforeRestore: true,
  deleteAfterRestore: true,
);
```

## Diagnostics: `db.status`

```dart
abstract class DbStatus {
  Future<MemoryInfo> memory();
  Future<SpaceInfo> space({bool useCache = true});
  Future<TableInfo?> table(String tableName);
  Future<ConfigInfo> config();
  Future<MigrationStatus?> migration(String taskId);
}
```

```dart
final mem = await db.status.memory();
final cfg = await db.status.config();
final mig = await db.status.migration(taskId);
```

## Logging

```dart
static void setLogConfig({
  void Function(LogRecord log)? onLog,
  String? logLabel,
  LogLevel? logLevel,
  bool enableLog = true,
});
```

- Call **before** `open` to capture init/migration logs.
- `LogLevel.error` — localized errors; `critical` — disaster-level (disk full, OOM, severe migration) → SHOULD alert ops.
- `LogRecord`: `level`, `message`, `timestamp`, optional `status` (`ResultStatus`).

```dart
ToStore.setLogConfig(
  enableLog: true,
  logLevel: LogLevel.warn,
  logLabel: 'my_app_db',
  onLog: (log) { /* forward warn/error/critical */ },
);
```

## Rules

1. `getVersion`/`setVersion` are **not** engine migration drivers.
2. `deleteDatabase` / `dropTable` are irreversible — confirm intent.
3. Prefer `status.*` for Agent/ops dashboards over scraping logs alone.
