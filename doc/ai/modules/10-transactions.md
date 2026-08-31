---
id: tostore-ai-10-transactions
title: Transactions
audience: coding-agent
source_apis:
  - ToStore.transaction
  - TransactionResult
  - TransactionIsolationLevel
version: 3.x
status: complete
---

# Transactions

## Purpose

Multi-operation atomicity: all commit or all roll back; crash recovery for unfinished work.

## API

```dart
Future<TransactionResult> transaction<T>(
  FutureOr<T> Function() action, {
  bool rollbackOnError = true,
  bool? persistRecoveryOnCommit, // null → DataStoreConfig default
  TransactionIsolationLevel? isolation, // null → config default
});
```

| Isolation | Meaning |
| :--- | :--- |
| `readCommitted` | Readers see committed data |
| `serializable` | SSI (Serializable Snapshot Isolation) |

Default timeout / cleanup: see `DataStoreConfig.transactionTimeout`, `enableTransactionCleanup`, etc.

## TransactionResult

| Member | Meaning |
| :--- | :--- |
| `txId` | Transaction id |
| `hasErrors` | **Primary outcome check** |
| `statuses` | Diagnostics |
| `startedAt` / `finishedAt` | Timing |
| `logFlushed` | Whether recovery log flushed |

```dart
final txResult = await db.transaction(() async {
  await db.insert('users', {
    'username': 'john',
    'email': 'john@example.com',
    'fans': 100,
  });
  await db.update('users', {
    'fans': Expr.field('fans') + Expr.value(50),
  }).where('username', '=', 'john');
});

if (!txResult.hasErrors) {
  // committed
} else {
  for (final s in txResult.statuses) {
    if (s.type != ResultType.success) {
      // s.codeKey, s.message
    }
  }
}

await db.transaction(() async {
  await db.insert('users', {...});
  throw Exception('business error'); // rollback when rollbackOnError: true
}, rollbackOnError: true);
```

## Hard rules

1. MUST check `!txResult.hasErrors` after `transaction`.
2. MUST NOT use `.allowLargeScaleOperation()` update/delete inside a transaction (rejected; rollback).
3. Ordinary constraint failures inside tx appear on `TransactionResult.statuses` when rolled back / failed — still inspect result.
4. Prefer `Expr` for atomic multi-field updates inside the same tx.
