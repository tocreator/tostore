import '../chain/delete_builder.dart';
import '../chain/schema_builder.dart';
import '../chain/stream_query_builder.dart';
import '../chain/update_builder.dart';
import '../chain/upsert_builder.dart';
import '../model/data_store_config.dart';
import '../model/db_result.dart';
import '../model/migration_task.dart';
import '../model/space_info.dart';
import '../model/table_info.dart';
import '../model/table_schema.dart';
import '../chain/query_builder.dart';

/// Data store engine interface
abstract class DataStoreInterface {
  /// Initialize data store engine
  Future<void> initialize({
    String? dbPath,
    String? dbName,
    DataStoreConfig? config,
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
      String tableName, List<Map<String, dynamic>> records, {bool allowPartialErrors = true});

  /// update data
  UpdateBuilder update(String tableName, Map<String, dynamic> data);

  /// delete data
  DeleteBuilder delete(String tableName);

  /// set key-value pair
  Future<bool> setValue(String key, dynamic value, {bool isGlobal = false});

  /// get key-value pair
  Future<dynamic> getValue(String key, {bool isGlobal = false});

  /// remove key-value pair
  Future<bool> removeValue(String key, {bool isGlobal = false});

  /// create table
  Future<void> createTable(TableSchema schema);

  /// create multiple tables
  Future<void> createTables(List<TableSchema> schemas);

  /// update table schema
  SchemaBuilder updateSchema(String tableName);

  /// drop table
  Future<void> dropTable(String tableName);

  /// clear table
  Future<void> clear(String tableName);

  /// get table schema
  Future<TableSchema?> getTableSchema(String tableName);

  /// get table info
  Future<TableInfo?> getTableInfo(String tableName);

  /// switch space
  Future<bool> switchSpace({String spaceName = 'default'});

  /// close data store engine
  Future<void> close();

  /// backup database
  Future<String> backup({bool compress = true});

  /// restore database
  Future<bool> restore(String backupPath, {bool deleteAfterRestore = false});

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
  Future<SpaceInfo> getSpaceInfo();
}
