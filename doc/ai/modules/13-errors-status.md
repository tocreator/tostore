---
id: tostore-ai-13-errors-status
title: Results, Status Codes, and Exceptions
audience: coding-agent
source_apis:
  - DbResult
  - QueryResult
  - SchemaUpdateResult
  - TransactionResult
  - ResultStatus
  - ResultType
  - DbException
version: 3.x
status: complete
---

# Results, Status Codes, and Exceptions

## Purpose

Interpret every ToStore outcome via the unified `ResultStatus` model — whether returned on a result object or thrown on `DbException`.

## Two channels

| Channel | When | Agent rule |
| :--- | :--- | :--- |
| **Result-based** (`DbResult` / `QueryResult` / `TransactionResult` / `SchemaUpdateResult`) | Daily CRUD, query, tx, runtime schema | Business/constraint/invalid-arg → **MUST NOT** expect throw; inspect result |
| **Exception-based** (`DbException`) | Fatal / developer / critical (e.g. bad schemas on open, engine mismatch, severe migration) | Catch `on DbException`; inspect `e.statuses` |

Both channels share the same `code` / `codeKey` / `ResultType` system.

## DbResult (writes / DDL)

| Member | Meaning |
| :--- | :--- |
| `hasErrors` | Any failure (including partial batch failure) — **primary success check** |
| `successCount` / `failedCount` / `totalCount` | Counts |
| `statuses` | Ordered `ResultStatus` list (1:1 with batch items when details enabled) |
| `firstPrimaryKey` | Convenience for single insert |
| `firstStatus` / `firstType` | First / primary diagnostic |
| `message` | Human summary (batched messages capped) |

Partial batch outcome: `hasErrors && successCount > 0` (inspect `statuses` per row).

```dart
final result = await db.insert('users', data);
if (result.hasErrors) {
  print('[${result.firstType.codeKey}] ${result.message}');
} else {
  print(result.firstPrimaryKey);
}
```

```dart
final batch = await db.batchInsert('users', rows);
if (batch.hasErrors) {
  for (final s in batch.statuses) {
    if (s is ConstraintStatus) { /* fields, tableName, … */ }
    else if (s is InvalidArgumentStatus) { /* parameterName, passedValue */ }
    else if (s.type != ResultType.success) { /* codeKey / message */ }
  }
}
```

## QueryResult

| Member | Meaning |
| :--- | :--- |
| `type` / `hasErrors` | Overall status (`hasErrors` ⇔ `type != success`) |
| `data` | Rows |
| `message` | Detail |
| `retrieval` | Vector/hybrid context |
| Pagination | `hasMore`/`hasPrev`, `next`/`prev`, cursor tokens (see Query module) |

Success check: `!hasErrors` or `type == ResultType.success`.

## ResultStatus

Common serialized fields: `index`, `code`, `codeKey`, `message`.

### Class codes (routing)

| Range | Prefix | Category | Handling |
| :--- | :--- | :--- | :--- |
| `0` | SUCCESS | Success | Proceed |
| `10000–19999` | `BIZ_` | Business / constraint | Return in result; usually no throw |
| `20000–49999` | `DEV_` | Developer error | Debug may throw `DbException`; production often in result |
| `50000–79999` | `SYS_` | System | May throw when execution blocked |
| `99000–99999` | `ENG_` | Engine | Severe cases may throw |

### In-memory helpers (MUST prefer over manual ranges)

On `ResultStatus` / `ResultType`:

- `isBusinessError` / `isConstraintError`
- `isDeveloperError`
- `isSystemError`
- `isEngineError`
- `isCriticalError` — ops intervention (disk full, OOM, severe corruption, …)

### Concrete subclasses

| Type | Typical codes |
| :--- | :--- |
| `SuccessStatus` | `0` |
| `ConstraintStatus` | `10000–19999` |
| `SchemaValidationStatus` | `30000–39999` |
| `InvalidArgumentStatus` | selected `20xxx` / `22004` |
| `TransactionOperationStatus` | `50001` / `50002` |
| `GeneralStatus` | fallback |

## DbException

```dart
try {
  final db = await ToStore.open(schemas: appSchemas);
} on DbException catch (e) {
  for (final status in e.statuses) {
    if (status is SchemaValidationStatus) {
      // tableName, field, wrongValue
    }
  }
}
```

Also: `DbClosedException`. Write APIs call `DbException.checkDeveloperError(result)` so some developer errors surface as throws in debug.

## Full code tables

Authoritative leaf codes and JSON field maps: `doc/result_status_specification.md` (also linked from `llms.txt`).

## Agent checklist

1. After write: `if (result.hasErrors)` — do not assume throw.
2. Prefer `status.codeKey` / helpers over magic numbers.
3. On open/migrate failures: catch `DbException`.
4. Critical / `LogLevel.critical`: alert ops (see Admin module `setLogConfig`).
