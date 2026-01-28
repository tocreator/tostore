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
  Future<void> initialize({
    String? dbPath,
    String? dbName,
    DataStoreConfig? config,
    bool reinitialize,
    bool noPersistOnClose,
  });

  /// query data
  QueryBuilder query(String tableName);

  /// stream query data
  StreamQueryBuilder streamQuery(String tableName);

  /// insert data, returns the operation result with primary key if successful
  Future<DbResult> insert(String tableName, Map<String, dynamic> data);

  /// upsert data
  UpsertBuilder upsert(String tableName, Map<String, dynamic> data);

  /// batch insert data, returns the operation result with successful and failed keys
  Future<DbResult> batchInsert(
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
  Future<bool> switchSpace({String spaceName = 'default'});

  /// close data store engine
  Future<void> close();

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

  /// Get unified status and diagnostics
  DbStatus get status;
}
