import '../chain/delete_builder.dart';
import '../chain/schema_builder.dart';
import '../chain/update_builder.dart';
import '../chain/upsert_builder.dart';
import '../model/data_store_config.dart';
import '../model/table_info.dart';
import '../model/table_schema.dart';
import '../query/query_builder.dart';

/// Data store engine interface
abstract class DataStoreInterface {
  /// Initialize data store engine
  Future<void> initialize({
    String? dbPath,
    DataStoreConfig? config,
  });

  /// query data
  QueryBuilder query(String tableName);

  /// insert data
  Future<bool> insert(String tableName, Map<String, dynamic> data);

  /// upsert data
  UpsertBuilder upsert(String tableName, Map<String, dynamic> data);

  /// batch insert data
  Future<bool> batchInsert(
      String tableName, List<Map<String, dynamic>> records);

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

  /// update table schema
  SchemaBuilder updateSchema(String tableName);

  /// drop table
  Future<void> dropTable(String tableName);

  /// clear table
  Future<void> clear(String tableName);

  /// get table schema
  Future<TableSchema> getTableSchema(String tableName);

  /// get table info
  Future<TableInfo> getTableInfo(String tableName);

  /// switch base space
  Future<bool> switchBaseSpace({String spaceName = 'default'});

  /// close data store engine
  Future<void> close();

  /// backup database
  Future<String> backup();

  /// restore database
  Future<void> restore(String backupPath);

  /// query by map
  Future<List<Map<String, dynamic>>> queryByMap(
    String tableName, {
    Map<String, dynamic>? where,
    List<String>? orderBy,
    int? limit,
    int? offset,
  });

  /// query by sql
  Future<List<Map<String, dynamic>>> queryBySql(
    String tableName, {
    String? where,
    List<dynamic>? whereArgs,
    String? orderBy,
    int? limit,
    int? offset,
  });

  /// get current config
  DataStoreConfig get config;

  /// get current base space name
  String? get currentBaseSpaceName;

  /// get database version
  Future<int> getVersion();

  /// set database version
  Future<void> setVersion(int version);

  /// delete database
  Future<void> deleteDatabase({String? dbPath});
}
