---
id: tostore-ai-15-anti-patterns
title: Anti-Patterns
audience: coding-agent
version: 3.x
status: complete
---

# Anti-Patterns

Common mistakes when generating ToStore client code. Prefer the ✅ form.

## Lifecycle

- ❌ `final db = ToStore(...); await db.initialize();`
- ✅ `final db = await ToStore.open(...);` or `ToStore.memory(...)`

- ❌ Omitting `dbPath` on Android/iOS
- ✅ Persistent app directory via path_provider (or equivalent)

## Errors

- ❌ Assuming unique-constraint failure always throws
- ✅ Inspect `DbResult` / statuses; use `codeKey` / helpers

- ❌ Swallowing `DbException` with empty catch
- ✅ Log `message` / statuses; fail closed for critical errors

## Writes

- ❌ `await db.update('t', data);` with no where and no allow flag
- ✅ `.where(...)` or explicit `.allowUpdateAll()`

- ❌ Large delete/update without `.allowLargeScaleOperation()`
- ✅ Use the allow flag; do not use inside `transaction`

- ❌ `batchUpsert` on tables without unique constraints
- ✅ Ensure unique indexes / PK strategy supports upsert

## KV

- ❌ Passing both `ttl` and `expiresAt`
- ✅ Pass exactly one expiration mechanism (or neither)

- ❌ Expecting space-local key to be visible after `switchSpace` without `isGlobal: true`
- ✅ Use `isGlobal: true` for cross-space values (e.g. login state)

## Queries

- ❌ Unbounded `await db.query('huge_table');` on large tables
- ✅ `limit` / `cursor` / stream / aggregations

- ❌ Using high `offset` for deep pagination
- ✅ Prefer `cursor` pagination; respect `maxQueryOffset`

- ❌ Inventing SQL strings or unsupported ORM methods
- ✅ Use chain builders and documented operators only

## Security

- ❌ Calling `rotateEncryptionKey` expecting table ciphertext rewrite
- ✅ Use `encodingKey` change for data key migration; `encryptionKey` for master key rotation API

## Schema

- ❌ Treating `setVersion` as the migration engine
- ✅ Declarative schemas / `updateSchema`; version is user bookkeeping only

- ❌ Manually querying system tables
- ✅ Use public status / info / KV / user table APIs only
