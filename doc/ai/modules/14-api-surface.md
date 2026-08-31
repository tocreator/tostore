---
id: tostore-ai-14-api-surface
title: Public API Surface
audience: coding-agent
source_apis:
  - package:tostore/tostore.dart
version: 3.x
status: complete
---

# Public API Surface

## Purpose

Exhaustive checklist of symbols agents may use from `package:tostore/tostore.dart`. If a symbol is missing here, treat it as undocumented and verify in source before use.

Import:

```dart
import 'package:tostore/tostore.dart';
```

## ToStore

### Static / factory

| Symbol | Status | Notes |
| :--- | :--- | :--- |
| `ToStore.open` | documented in Lifecycle | Preferred |
| `ToStore.memory` | documented in Lifecycle | Preferred |
| `ToStore(...)` | deprecated | MUST NOT in new code |
| `ToStore.setLogConfig` | Admin | Global logger |

### Instance — schema / tables

| Symbol | Returns |
| :--- | :--- |
| `createTable(TableSchema)` | `Future<DbResult>` |
| `createTables(List<TableSchema>)` | `Future<DbResult>` |
| `dropTable(String)` | `Future<DbResult>` |
| `clear(String)` | `Future<DbResult>` |
| `tableExists(String)` | `Future<bool>` |
| `getTableSchema(String)` | `Future<TableSchema?>` |
| `getTableNames({bool? isGlobal})` | `Future<List<String>>` |
| `getTableInfo(String)` | `Future<TableInfo?>` |
| `updateSchema(String)` | `SchemaBuilder` |
| `queryMigrationTaskStatus(String)` | `Future<MigrationStatus?>` |

### Instance — data

| Symbol | Returns |
| :--- | :--- |
| `insert(String, Map)` | `Future<DbResult>` |
| `upsert(String, Map)` | `Future<DbResult>` |
| `query(String)` | `QueryBuilder` |
| `streamQuery(String)` | `StreamQueryBuilder` |
| `update(String, [Map])` | `UpdateBuilder` |
| `delete(String)` | `DeleteBuilder` |
| `batchInsert(String, List, {allowPartialErrors, returnResultDetails})` | `Future<DbResult>` |
| `batchUpsert(...)` | `Future<DbResult>` |
| `batchUpdate(...)` | `Future<DbResult>` |
| `vectorSearch(String, {fieldName, queryVector, topK, searchDepth, distanceThreshold})` | `Future<List<VectorSearchResult>>` |

### Instance — KV

| Symbol | Returns |
| :--- | :--- |
| `setValue(String, dynamic, {ttl, expiresAt, isGlobal})` | `Future<DbResult>` |
| `getValue(String, {isGlobal})` | `Future<dynamic>` |
| `removeValue(String, {isGlobal})` | `Future<DbResult>` |
| `watchValue<T>(String, {isGlobal, defaultValue, distinct})` | `Stream<T?>` |
| `watchValues(Iterable, {isGlobal, distinct})` | `Stream<Map<String, dynamic>>` |
| `kv` | `KvStore` |

### Instance — space / admin / tx

| Symbol | Returns |
| :--- | :--- |
| `switchSpace({spaceName, keepActive})` | `Future<bool>` |
| `listSpaces()` | `Future<List<String>>` |
| `deleteSpace(String)` | `Future<DbResult>` |
| `getSpaceInfo({useCache})` | `Future<SpaceInfo>` |
| `currentSpaceName` | `String?` |
| `backup({compress, scope})` | `Future<String>` |
| `restore(String, {deleteAfterRestore, cleanupBeforeRestore})` | `Future<bool>` |
| `transaction<T>(action, {rollbackOnError, persistRecoveryOnCommit, isolation})` | `Future<TransactionResult>` |
| `rotateEncryptionKey({oldKey, required newKey})` | `Future<DbResult>` |
| `flush({flushStorage})` | `Future<void>` |
| `close({keepActiveSpace})` | `Future<void>` |
| `deleteDatabase({dbPath, dbName})` | `Future<void>` |
| `getVersion()` / `setVersion(int)` | version bookkeeping |
| `config` | `DataStoreConfig` |
| `instancePath` | `String?` |
| `status` | `DbStatus` |
| `initialize(...)` | deprecated |

## Chain builders (not all re-exported as types; obtained via ToStore)

| Type | Entry | Key methods (see topic modules) |
| :--- | :--- | :--- |
| `QueryBuilder` | `query` | select, join*, agg, peek*, watch, cache, matchVector, … |
| `UpdateBuilder` | `update` | set*, compute, allow*, inherits ChainBuilder where* |
| `DeleteBuilder` | `delete` | allowDeleteAll, allowLargeScaleOperation, where* |
| `StreamQueryBuilder` | `streamQuery` | where*, select, stream/listen |
| `SchemaBuilder` | `updateSchema` | add/remove/rename/modify field/index/FK/TTL/PK |
| `KvQueryBuilder` | `kv.query` | prefix, orderBy*, limit, offset, cursor, peek |

### ChainBuilder predicate surface

`orderByAsc`, `orderByDesc`, `limit`, `offset`, `cursor`, `where`, `whereIn`, `whereNotIn`, `whereBetween`, `whereNull`, `whereNotNull`, `whereLike`, `whereNotLike`, `whereEqual`, `whereNotEqual`, `whereGreaterThan`, `whereGreaterThanOrEqualTo`, `whereLessThan`, `whereLessThanOrEqualTo`, `whereContains`, `whereNotContains`, `whereStartsWith`, `whereEndsWith`, `whereContainsAny`, `whereEmpty`, `whereNotEmpty`, `whereTrue`, `whereFalse`, `or`, `orWhere`, `condition`, `orCondition`, `queryCondition`.

## Package exports (from `lib/tostore.dart`)

Agents MAY import these via `package:tostore/tostore.dart`:

| Export path | Public symbols (non-exhaustive nested; expand in topic modules) |
| :--- | :--- |
| `kv_query_builder.dart` | `KvQueryBuilder` |
| `chain_builder.dart` | `ChainBuilder` |
| `logger.dart` | `LogLevel`, `LogRecord`, `LogConfig`, `LogType` |
| `to_crypto.dart` | `ToCrypto`, `ToCryptoType` |
| `status_provider.dart` | `DbStatus` |
| `backup_scope.dart` | `BackupScope` |
| `config_info.dart` | `ConfigInfo` |
| `data_store_config.dart` | `DataStoreConfig`, `PersistenceMode`, `DistributedNodeConfig`, `TransactionIsolationLevel`, `RecoveryFlushPolicy`, `EncryptionType`, `EncryptionScope`, `EncryptionConfig` |
| `db_exception.dart` | `DbException`, `DbClosedException` |
| `db_result.dart` | `DbResult` |
| `db_startup_stage.dart` | `DbStartupStage`, `StartupProgressCallback` |
| `expr.dart` | `Expr`, `ExprNode`, operators/nodes |
| `memory_info.dart` | `MemoryInfo` |
| `migration_config.dart` | `MigrationConfig` |
| `migration_task.dart` | `MigrationTask`, `MigrationStatus`, `MigrationType`, `FieldSchemaUpdate`, `MigrationOperation`, … |
| `migration_write_mode.dart` | `MigrationWriteMode` |
| `query_aggregation.dart` | `QueryAggregationType`, `QueryAggregation`, `Agg`, … |
| `query_result.dart` | `QueryResult`, `VectorSearchResult`, `RetrievalChannel`, `RetrievalFusionMethod`, `RetrievalEntry`, `RetrievalContext` |
| `result_status.dart` | `ResultStatus`, `SuccessStatus`, `ConstraintStatus`, `SchemaValidationStatus`, `InvalidArgumentStatus`, `TransactionOperationStatus`, `GeneralStatus` |
| `result_type.dart` | `ResultType` |
| `schema_update_result.dart` | `SchemaUpdateResult` |
| `space_info.dart` | `SpaceInfo` |
| `table_info.dart` | `TableInfo` |
| `table_schema.dart` | `TableSchema`, `FieldSchema`, `IndexSchema`, `TableTtlConfig`, `DataType`, `IndexType`, `DefaultValueType`, `PrimaryKeyType`, `SequentialIdConfig`, `PrimaryKeyConfig`, `VectorData`, `VectorFieldConfig`, `VectorPrecision`, `VectorIndexType`, `VectorDistanceMetric`, `VectorIndexConfig`, `ForeignKeyCascadeAction`, `ForeignKeySchema`, … |
| `transaction_result.dart` | `TransactionResult`, `TransactionStatus`, `TransactionErrorType`, `TransactionError` |
| `query_condition.dart` | `QueryCondition` |

## KvStore methods (via `db.kv`)

`query`, `set`, `setMany`, `get`, `peekGet`, `getString`, `getInt`, `getBool`, `getMap`, list getter, `getKeys`, `exists`, `peekExists`, `remove`, `removeKeys`, `getTtl`, `setTtl`, `setIncrement`, `watchValues`, `clear`, `count`.

Builders obtained from `ToStore` (`QueryBuilder`, `UpdateBuilder`, `DeleteBuilder`, `StreamQueryBuilder`, `SchemaBuilder`) are detailed in the corresponding topic modules; this inventory lists entry points and exported types.
