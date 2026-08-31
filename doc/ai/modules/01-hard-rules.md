---
id: tostore-ai-01-hard-rules
title: Hard Rules
audience: coding-agent
version: 3.x
status: complete
---

# Hard Rules

RFC 2119 keywords apply.

## Lifecycle

1. Agents MUST open databases with `ToStore.open(...)` or `ToStore.memory(...)`.
2. Agents MUST NOT use the deprecated `ToStore(...)` factory or `initialize(...)` in new code.
3. Agents MUST await `open` / `memory` before any data operation.
4. On Android/iOS, agents MUST supply a persistent `dbPath` (e.g. app documents directory). Desktop/server MAY omit `dbPath`.

## Results and errors

5. Agents MUST check `DbResult` / `QueryResult` / `TransactionResult` via `hasErrors` and `statuses` (or `type` on query results). Do not assume thrown exceptions for constraint failures.
6. Developer misuse MAY throw `DbException` in debug; production may return status objects. Prefer status helpers (`isBusinessError`, `isDeveloperError`, …) over manual code ranges.
7. Agents MUST NOT catch and ignore `DbException` without handling; surface `message` / `codeKey` to the user or ops layer.

## Tables and safety

8. Agents MUST NOT read/write/drop/clear/query system tables via public ToStore APIs (engine rejects with developer error).
9. Unconditional `update` / `delete` MUST use `.allowUpdateAll()` / `.allowDeleteAll()` deliberately.
10. Large-scale `update` / `delete` that would risk OOM MUST use `.allowLargeScaleOperation()`; MUST NOT use it inside a transaction.
11. After large-scale ops, agents SHOULD only rely on `DbResult.successCount` (no per-row key details).

## KV

12. `ttl` and `expiresAt` MUST NOT be passed together on the same set operation.
13. Cross-space shared keys MUST set `isGlobal: true`.

## Schema and keys

14. Schema evolution SHOULD use declarative schemas and/or `updateSchema` chain; avoid inventing manual file migrations.
15. `getVersion` / `setVersion` are user bookkeeping only; they MUST NOT be treated as engine migration drivers.
16. `EncryptionConfig.encryptionKey` rotation uses `rotateEncryptionKey`. Data re-encryption uses `encodingKey` change (engine migrates). Agents MUST NOT confuse the two.

## Performance (application code)

17. Agents SHOULD prefer indexed predicates, cursors/pagination, and `batch*` APIs for large writes.
18. Agents SHOULD avoid loading unbounded result sets; use `limit` / `cursor` / streaming.
19. For UI, prefer `watch` / `watchValue` over polling.

## Documentation discipline

20. When unsure of an API, agents MUST consult **API Surface** / the relevant module rather than inventing methods.
