import '../chain/delete_builder.dart';
import '../chain/update_builder.dart';
import '../model/data_store_config.dart';
import '../model/table_info.dart';
import '../model/table_schema.dart';
import '../query/query_builder.dart';

/// 数据存储引擎接口
abstract class DataStoreInterface {
  /// 初始化数据存储引擎
  Future<void> initialize({
    String? dbPath,
    DataStoreConfig? config,
  });

  /// 查询数据
  QueryBuilder query(String tableName);

  /// 插入数据
  Future<bool> insert(String tableName, Map<String, dynamic> data);

  /// 批量插入数据
  Future<bool> batchInsert(
      String tableName, List<Map<String, dynamic>> records);

  /// 更新数据
  UpdateBuilder update(String tableName, Map<String, dynamic> data);

  /// 删除数据
  DeleteBuilder delete(String tableName);

  /// 设置键值对
  Future<bool> setValue(String key, dynamic value, {bool isGlobal = false});

  /// 获取键值对
  Future<dynamic> getValue(String key, {bool isGlobal = false});

  /// 删除键值对
  Future<bool> removeValue(String key, {bool isGlobal = false});

  /// 创建表
  Future<void> createTable(String tableName, TableSchema schema);

  /// 删除表
  Future<void> dropTable(String tableName);

  /// 清空表
  Future<void> clear(String tableName);

  /// 获取表结构
  Future<TableSchema> getTableSchema(String tableName);

  /// 获取表信息
  Future<TableInfo> getTableInfo(String tableName);

  /// 切换基础空间
  Future<bool> switchBaseSpace({String spaceName = 'default'});

  /// 关闭数据存储引擎
  Future<void> close();

  /// 备份数据库
  Future<String> backup();

  /// 还原数据库
  Future<void> restore(String backupPath);

  /// Map方式查询
  Future<List<Map<String, dynamic>>> queryByMap(
    String tableName, {
    Map<String, dynamic>? where,
    List<String>? orderBy,
    int? limit,
    int? offset,
  });

  /// SQL风格的查询
  Future<List<Map<String, dynamic>>> queryBySql(
    String tableName, {
    String? where,
    List<dynamic>? whereArgs,
    String? orderBy,
    int? limit,
    int? offset,
  });

  /// 获取当前配置
  DataStoreConfig get config;

  /// 获取当前基础空间名
  String? get currentBaseSpaceName;

  /// 获取数据库版本号
  Future<int> getVersion();

  /// 设置数据库版本号
  Future<void> setVersion(int version);

  /// 删除数据库
  Future<void> deleteDatabase({String? dbPath});
}
