import 'dart:async';
import '../Interface/chain_builder.dart';
import '../chain/schema_builder.dart';
import '../chain/stream_query_builder.dart';
import '../model/data_store_config.dart';
import '../model/db_result.dart';
import '../model/migration_task.dart';
import '../model/transaction_result.dart';
import '../model/space_info.dart';
import '../model/table_info.dart';
import '../model/table_schema.dart';
import '../model/backup_scope.dart';
import 'status_provider.dart';

/// Data store engine interface
abstract class DataStoreInterface {
  /// Initialize data store engine
  /// [reinitialize] when true, force reinitialize (close then reopen)
  /// [noPersistOnClose] when reinitializing, do not persist pending buffers; only clear caches/flush handles
  /// [applyActiveSpaceOnDefault] when true (default), if config spaceName is default, use stored activeSpace so first open lands in last used space
  Future<void> initialize({
    String? dbPath,
    String? dbName,
    DataStoreConfig? config,
    bool reinitialize = false,
    bool noPersistOnClose = false,
    bool applyActiveSpaceOnDefault = false,
  });

  /// query data
  QueryBuilder query(String tableName);

  /// stream query data
  StreamQueryBuilder streamQuery(String tableName);

  /// insert data, returns the operation result with primary key if successful
  Future<DbResult> insert(String tableName, Map<String, dynamic> data);

  /// upsert data; conflict target from primary key or unique index in data
  Future<DbResult> upsert(String tableName, Map<String, dynamic> data);

  /// batch insert data, returns the operation result with successful and failed keys
  Future<DbResult> batchInsert(
      String tableName, List<Map<String, dynamic>> records,
      {bool allowPartialErrors = true});

  /// batch upsert data based on unique constraints.
  Future<DbResult> batchUpsert(
      String tableName, List<Map<String, dynamic>> records,
      {bool allowPartialErrors = true});

  /// update data
  UpdateBuilder update(String tableName,
      [Map<String, dynamic> data = const {}]);

  /// delete data
  DeleteBuilder delete(String tableName);

  /// set key-value pair
  Future<DbResult> setValue(String key, dynamic value, {bool isGlobal = false});

  /// get key-value pair
  Future<dynamic> getValue(String key, {bool isGlobal = false});

  /// remove key-value pair
  Future<DbResult> removeValue(String key, {bool isGlobal = false});

  /// create table
  Future<DbResult> createTable(TableSchema schema);

  /// create multiple tables
  Future<DbResult> createTables(List<TableSchema> schemas);

  /// update table schema
  SchemaBuilder updateSchema(String tableName);

  /// drop table
  Future<DbResult> dropTable(String tableName);

  /// clear table
  Future<DbResult> clear(String tableName);

  /// get table schema
  Future<TableSchema?> getTableSchema(String tableName);

  /// get table info
  Future<TableInfo?> getTableInfo(String tableName);

  /// switch space
  ///
  /// [keepActive] When true, saves this space as last active for next launch.
  Future<bool> switchSpace(
      {String spaceName = 'default', bool keepActive = true});

  /// flush data
  Future<void> flush({bool flushStorage = true});

  /// close data store engine
  /// [keepActiveSpace] when false, clears active space so next launch uses default (e.g. logout). Default true.
  Future<void> close({bool keepActiveSpace = true});

  /// backup database
  Future<String> backup(
      {bool compress = true,
      BackupScope scope = BackupScope.currentSpaceWithGlobal});

  /// restore database
  Future<bool> restore(String backupPath,
      {bool deleteAfterRestore = false, bool cleanupBeforeRestore = true});

  /// Run a transaction
  Future<TransactionResult> transaction<T>(
    FutureOr<T> Function() action, {
    bool rollbackOnError = true,
    bool? persistRecoveryOnCommit,
    TransactionIsolationLevel? isolation,
  });

  /// get current config
  DataStoreConfig get config;

  /// get current space name
  String? get currentSpaceName;

  /// get database version
  Future<int> getVersion();

  /// set database version
  Future<void> setVersion(int version);

  /// Query migration task status
  Future<MigrationStatus?> queryMigrationTaskStatus(String taskId);

  /// delete database
  Future<void> deleteDatabase({String? dbPath, String? dbName});

  /// Get information about the current space
  Future<SpaceInfo> getSpaceInfo({bool useCache = true});

  /// Delete a space
  Future<DbResult> deleteSpace(String spaceName);

  /// List all space names (e.g. for multi-account switch or admin).
  /// Returns sorted list; at least contains 'default'.
  Future<List<String>> listSpaces();

  /// Get unified status and diagnostics
  DbStatus get status;
}
