---
id: tostore-ai-12-config-security
title: Configuration and Security
audience: coding-agent
source_apis:
  - DataStoreConfig
  - EncryptionConfig
  - DistributedNodeConfig
  - ToCrypto
  - ToStore.rotateEncryptionKey
version: 3.x
status: complete
---

# Configuration and Security

## Purpose

Tune engine behavior; encrypt at rest; rotate keys correctly; optional value-level crypto.

## DataStoreConfig

**SHOULD** leave most fields automatic — engine senses platform/memory/IO. Tune only when needed.

```dart
factory DataStoreConfig({
  PersistenceMode persistenceMode = PersistenceMode.file, // file | memory
  String? dbPath,
  String dbName = 'default',
  String spaceName = 'default',
  bool ignoreUnknownFields = true,
  EncryptionConfig? encryptionConfig,
  MigrationConfig? migrationConfig = const MigrationConfig(),
  int? maxPartitionFileSize,
  bool enableLog = true,
  LogLevel logLevel = LogLevel.warn,
  int? maxConcurrency,
  int? maxIoConcurrency,
  DistributedNodeConfig? distributedNodeConfig,
  int? cacheMemoryBudgetMB,
  bool? enablePrewarmCache,
  int? prewarmThresholdMB,
  // journal / batch / flush / open files...
  bool? enableJournal,
  bool? persistRecoveryOnCommit,
  RecoveryFlushPolicy? recoveryFlushPolicy,
  TransactionIsolationLevel? defaultTransactionIsolationLevel,
  Duration transactionTimeout = const Duration(minutes: 5),
  // ... cleanup TTLs ...
  int? ttlCleanupIntervalMs, // effective min 60000
  int? defaultQueryLimit,    // default 1000
  int? maxQueryOffset,       // default 10000
  int? yieldDurationMs,      // client ~8ms, server ~50ms
  bool? isServerEnvironment,
});
```

### High-value knobs

| Param | Default (typical) | Notes |
| :--- | :--- | :--- |
| `yieldDurationMs` | 8 (client) / 50 (server) | UI smoothness vs throughput |
| `defaultQueryLimit` | 1000 | Applied when query omits `limit` |
| `maxQueryOffset` | 10000 | Deep offset rejected beyond this |
| `enableJournal` | true (non-web) | Crash recovery |
| `persistRecoveryOnCommit` | true | Strong durability; false = faster, tiny crash risk |
| `ttlCleanupIntervalMs` | ≥60000 | Background TTL scan |
| `cacheMemoryBudgetMB` | auto | LRU budget |
| `maxConcurrency` | auto | Vector/crypto workers |
| `isServerEnvironment` | auto-detected | Changes partition/concurrency defaults |

`PersistenceMode.memory` is forced by `ToStore.memory()`.

## Encryption (at rest)

```dart
EncryptionConfig({
  EncryptionType encryptionType, // none | xorObfuscation | chacha20Poly1305 | aes256Gcm
  String? encodingKey,   // data key — change → background rewrite
  String? encryptionKey, // master key protecting encodingKey — rotate online
  EncryptionScope encryptionScope, // standard | full
  bool encryptVectorIndex,
});
```

| Key | Role | How to change | Rewrites table data? |
| :--- | :--- | :--- | :--- |
| `encodingKey` | Encrypts table/index/log payloads | New value + `open` again | **Yes** (slow, automatic migrate) |
| `encryptionKey` | Protects `encodingKey` | `rotateEncryptionKey` | **No** (fast) |

MUST NOT hardcode production secrets; prefer OS Keychain/Keystore and pass into config.

```dart
Future<DbResult> rotateEncryptionKey({
  String? oldKey, // null if previously unset (engine default)
  required String newKey,
});
```

On success, pass the new `encryptionKey` on next `open`. Fails if wrong `oldKey` or encoding migration in progress.

## ToCrypto (value-level, no db required)

Application encodes/decodes sensitive fields before write / after read. Output Base64.

```dart
ToCrypto.encode(plaintext, {
  required Object key, // String or Uint8List; non-32-byte → SHA-256 derive
  ToCryptoType type = ToCryptoType.chacha20Poly1305, // or aes256Gcm
  Uint8List? aad, // MUST match on decode
});
ToCrypto.decode(cipherBase64, {required Object key, Uint8List? aad});
```

Use when only a few fields need protection (lower cost than full DB encryption).

## DistributedNodeConfig

For distributed primary-key / node identity (clusterId, nodeId, centralServerUrl, accessToken, autoFetchNodeInfo, thresholds). Pair with `PrimaryKeyType.timestampBased` / `datePrefixed` / `shortCode` for multi-node id generation. See README Distributed Architecture for topology narrative; agents MUST set node identity correctly before relying on distributed PK uniqueness.

## Rules

1. Do not confuse `encodingKey` vs `encryptionKey`.
2. Prefer defaults unless profiling shows need.
3. Client: keep `yieldDurationMs` low (~8); server: often ~50.
4. `ToCrypto` is orthogonal to `EncryptionConfig` — both MAY be used together.
