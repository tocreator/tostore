library tostore;

export 'src/model/table_schema.dart';
export 'src/model/business_error.dart';
export 'src/model/data_store_config.dart';
export 'src/model/table_info.dart';
export 'src/model/log_config.dart';

import 'src/chain/delete_builder.dart';
import 'src/chain/update_builder.dart';
import 'src/core/data_store_interface.dart';
import 'src/model/data_store_config.dart';
import 'src/core/data_store_impl.dart';
import 'src/model/table_info.dart';
import 'src/model/table_schema.dart';
import 'src/query/query_builder.dart';

/// 数据存储，支持链式操作、Sql风格查询、Map风格查询，自由切换基础空间、全局数据表，适应用户切换等，单例足以覆盖常见使用场景
/// 支持多实例，资源隔离，每个实例独立文件存储、缓存、索引、事务等
class ToStore implements DataStoreInterface {
  /// 以数据库路径的不同创建独立的实例
  /// [dbPath] 数据库路径，可选
  /// [config] 数据库配置
  /// [version] 数据库版本号
  /// [onConfigure] 数据库配置时的回调
  /// [onCreate] 数据库首次创建时的回调
  /// [onUpgrade] 数据库升级时的回调
  /// [onDowngrade] 数据库降级时的回调
  /// [onOpen] 数据库打开时的回调
  factory ToStore({
    String? dbPath,
    DataStoreConfig? config,
    int version = 1,
    Future<void> Function(ToStore db)? onConfigure,
    Future<void> Function(ToStore db)? onCreate,
    Future<void> Function(ToStore db, int oldVersion, int newVersion)?
        onUpgrade,
    Future<void> Function(ToStore db, int oldVersion, int newVersion)?
        onDowngrade,
    Future<void> Function(ToStore db)? onOpen,
  }) {
    final key = dbPath ?? 'default';
    if (!_instances.containsKey(key)) {
      final impl = DataStoreImpl(
        dbPath: dbPath,
        config: config,
        version: version,
        onConfigure: onConfigure != null
            ? (db) => onConfigure(ToStore._fromImpl(db))
            : null,
        onCreate:
            onCreate != null ? (db) => onCreate(ToStore._fromImpl(db)) : null,
        onUpgrade: onUpgrade != null
            ? (db, oldVersion, newVersion) =>
                onUpgrade(ToStore._fromImpl(db), oldVersion, newVersion)
            : null,
        onDowngrade: onDowngrade != null
            ? (db, oldVersion, newVersion) =>
                onDowngrade(ToStore._fromImpl(db), oldVersion, newVersion)
            : null,
        onOpen: onOpen != null ? (db) => onOpen(ToStore._fromImpl(db)) : null,
      );
      _instances[key] = ToStore._internal(impl);
    }
    return _instances[key]!;
  }

  /// 初始化数据库
  @override
  Future<void> initialize({String? dbPath, DataStoreConfig? config}) async {
    await _impl.initialize(dbPath: dbPath, config: config);
  }

  /// 创建表
  /// [tableName] 表名
  /// [schema] 表结构
  /// 示例：
  /// ```dart
  /// await db.createTable(
  /// 'table_name',
  ///  TableSchema(
  ///   primaryKey: 'userId',
  ///   fields: [
  ///     FieldSchema(
  ///       name: 'userId',
  ///       type: DataType.integer,
  ///       nullable: false,
  ///     ),
  ///     FieldSchema(
  ///       name: 'userName',
  ///       type: DataType.text,
  ///       nullable: false,
  ///     ),
  ///   ],
  ///   indexes: [
  ///     IndexSchema(
  ///       fields: ['userName'],
  ///       unique: true,
  ///     ),
  ///   ],
  /// ));
  /// ```
  /// 全局表数据共享，其他表在切换基础空间后，数据独立，比如用户切换场景
  @override
  Future<void> createTable(String tableName, TableSchema schema) async {
    return await _impl.createTable(tableName, schema);
  }

  /// 插入数据
  /// [tableName] 表名
  /// [data] 数据
  @override
  Future<bool> insert(String tableName, Map<String, dynamic> data) async {
    return await _impl.insert(tableName, data);
  }

  /// 查询
  ///
  /// 链式操作
  /// 示例：
  /// ```dart
  /// await db.query('table_name')
  ///         .where('id', '=', 1)
  ///         .or()
  ///         .where('name', '!=', 'marley');
  /// ```
  @override
  QueryBuilder query(String tableName) {
    return QueryBuilder(_impl, tableName);
  }

  /// 切换基础空间，用于切换用户等场景，资源隔离，数据独立，全局表数据不受影响
  /// [spaceName] 基础空间名称，默认'default'
  @override
  Future<bool> switchBaseSpace({String spaceName = 'default'}) {
    return _impl.switchBaseSpace(spaceName: spaceName);
  }

  /// 更新数据
  /// [tableName] 表名
  /// [data] 数据
  @override
  UpdateBuilder update(String tableName, Map<String, dynamic> data) {
    return UpdateBuilder(_impl, tableName, data);
  }

  /// 批量插入数据
  /// [tableName] 表名
  /// [dataList] 数据列表
  @override
  Future<bool> batchInsert(
      String tableName, List<Map<String, dynamic>> dataList) async {
    return await _impl.batchInsert(tableName, dataList);
  }

  /// 设置键值对
  /// [key] 键
  /// [value] 值
  /// [isGlobal] 是否为全局键值对，默认false
  @override
  Future<bool> setValue(String key, dynamic value,
      {bool isGlobal = false}) async {
    return await _impl.setValue(key, value, isGlobal: isGlobal);
  }

  /// 获取键值对
  /// [key] 键
  /// [isGlobal] 是否为全局键值对，默认false
  @override
  Future<dynamic> getValue(String key, {bool isGlobal = false}) async {
    return await _impl.getValue(key, isGlobal: isGlobal);
  }

  /// 删除键值对
  /// [key] 键
  /// [isGlobal] 是否为全局键值对，默认false
  @override
  Future<bool> removeValue(String key, {bool isGlobal = false}) async {
    return await _impl.removeValue(key, isGlobal: isGlobal);
  }

  /// 备份数据库
  @override
  Future<String> backup() async {
    return await _impl.backup();
  }

  /// 恢复数据库
  @override
  Future<bool> restore(String backupPath) async {
    return await _impl.restore(backupPath);
  }

  /// 删除数据
  @override
  DeleteBuilder delete(String tableName) {
    return DeleteBuilder(_impl, tableName);
  }

  /// 删除表
  @override
  Future<void> dropTable(String tableName) async {
    return await _impl.dropTable(tableName);
  }

  /// 清空表
  @override
  Future<void> clear(String tableName) async {
    return await _impl.clear(tableName);
  }

  /// 获取表结构
  @override
  Future<TableSchema> getTableSchema(String tableName) async {
    return await _impl.getTableSchema(tableName);
  }

  /// 获取表信息
  /// [tableName] 表名
  /// [recordCount] 记录数
  /// [cacheCount] 缓存数
  /// [fileSize] 文件大小
  /// [indexCount] 索引数
  /// [schema] 表结构
  /// [lastModified] 最后修改时间
  /// [createdAt] 创建时间
  /// [isGlobal] 是否为全局表
  @override
  Future<TableInfo> getTableInfo(String tableName) async {
    return await _impl.getTableInfo(tableName);
  }

  /// 获取配置
  @override
  DataStoreConfig get config => _impl.config;

  /// 获取当前基础空间名称
  @override
  String? get currentBaseSpaceName => _impl.currentBaseSpaceName;

  /// 获取数据库版本号
  @override
  Future<int> getVersion() async {
    return await _impl.getVersion();
  }

  /// 设置数据库版本号
  @override
  Future<void> setVersion(int version) async {
    return await _impl.setVersion(version);
  }

  /// Map方式查询
  @override
  Future<List<Map<String, dynamic>>> queryByMap(String tableName,
      {Map<String, dynamic>? where,
      List<String>? orderBy,
      int? limit,
      int? offset}) async {
    return await _impl.queryByMap(tableName,
        where: where, orderBy: orderBy, limit: limit, offset: offset);
  }

  /// Sql方式查询
  @override
  Future<List<Map<String, dynamic>>> queryBySql(
    String tableName, {
    String? where,
    List<dynamic>? whereArgs,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    return await _impl.queryBySql(
      tableName,
      where: where,
      whereArgs: whereArgs,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    );
  }

  /// 关闭数据库
  @override
  Future<void> close() async {
    await _impl.close();
    String? instanceKey;
    _instances.forEach((key, value) {
      if (value == this) {
        instanceKey = key;
      }
    });
    if (instanceKey != null) {
      _instances.remove(instanceKey);
    }
  }

  /// 删除数据库
  @override
  Future<void> deleteDatabase({String? dbPath}) async {
    await _impl.deleteDatabase(dbPath: dbPath);

    String? instanceKey;
    _instances.forEach((key, value) {
      if (value == this) {
        instanceKey = key;
      }
    });
    if (instanceKey != null) {
      _instances.remove(instanceKey);
    }
  }

  /// @nodoc
  static final Map<String, ToStore> _instances = {};

  /// @nodoc
  final DataStoreImpl _impl;

  /// @nodoc
  ToStore._internal(this._impl);

  /// @nodoc
  static ToStore _fromImpl(DataStoreImpl impl) {
    return ToStore._internal(impl);
  }
}
