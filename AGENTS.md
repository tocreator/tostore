# AGENTS.md — ToStore

Instructions for coding agents working in this repository or generating ToStore client code.

## Package

- ToStore — distributed data engine (tables, KV, vectors, spaces, encryption, transactions).
- Import: `package:tostore/tostore.dart`
- Human tutorials: `README.md`
- **AI programming corpus (complete):** `llms-full.txt` (generated from `doc/ai/modules/`)
- Discovery index: `llms.txt`

## Hard rules (binding)

1. MUST open with `ToStore.open(...)` or `ToStore.memory(...)`. MUST NOT use deprecated `ToStore(...)` / `initialize` in new code.
2. On Android/iOS MUST pass a persistent `dbPath`.
3. MUST handle `DbResult` / `QueryResult` / `TransactionResult` for business outcomes; do not assume constraint errors always throw.
4. MUST NOT access system tables via public CRUD/query APIs.
5. Unconditional update/delete MUST use `.allowUpdateAll()` / `.allowDeleteAll()`.
6. Large-scale update/delete MUST use `.allowLargeScaleOperation()` and MUST NOT run inside a transaction.
7. `ttl` and `expiresAt` MUST NOT be combined on one KV set.
8. Do not invent APIs — check `llms-full.txt` or `doc/ai/modules/14-api-surface.md`.

## Where to read more

| Need | File |
| :--- | :--- |
| Full AI spec (single file) | `llms-full.txt` |
| Module sources (hand-edit only) | `doc/ai/modules/` |
| ResultStatus deep dive | `doc/result_status_specification.md` |

## AI docs maintenance

- Hand-edit **only** `doc/ai/modules/*.md`.
- **MUST NOT** hand-edit generated `llms-full.txt`.
- After module changes, regenerate:

```bash
dart run doc/ai/scripts/build_llms_full.dart
dart run doc/ai/scripts/build_llms_full.dart --check
```

## Repo contribution notes

- Engine internals: prefer stable `tableUid` over `tableName` for structure; use `tableName` only for user-facing logs/errors/results.
- Prefer `TableContext` when available for `tableUid`, `tableName`, `isGlobal`, `dataDirIndex`, schema snapshot.
- Throw engine `DbException` model internally — not ad-hoc Dart exceptions for engine paths.
- Do not run `database_full_test.dart` unless the user explicitly asks.
