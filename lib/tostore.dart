library tostore;

export 'src/model/table_schema.dart';
export 'src/model/business_error.dart';
export 'src/model/data_store_config.dart';
export 'src/model/table_info.dart';
export 'src/model/log_config.dart';

import 'src/chain/delete_builder.dart';
import 'src/chain/update_builder.dart';
import 'src/chain/upsert_builder.dart';
import 'src/core/data_store_interface.dart';
import 'src/model/data_store_config.dart';
import 'src/core/data_store_impl.dart';
import 'src/model/table_info.dart';
import 'src/model/table_schema.dart';
import 'src/query/query_builder.dart';

/// High-performance storage engine built specifically for mobile applications.
/// Features:
/// - Chain operations, SQL-style and Map-style queries
/// - Multi-space architecture with global data tables
/// - Perfect for user switching scenarios
/// - Single instance covers most use cases
/// - Supports multiple instances with isolated resources
/// - Each instance has independent file storage, cache, index, and transactions
///
/// 专为移动应用打造的高性能数据存储引擎
/// 特性：
/// - 支持链式操作、SQL风格和Map风格查询
/// - 多空间架构设计，支持全局数据表
/// - 完美适配用户切换场景
/// - 单例足以覆盖常见使用场景
/// - 支持多实例，资源完全隔离
/// - 每个实例拥有独立的文件存储、缓存、索引和事务
class ToStore implements DataStoreInterface {
  /// Create independent instances with different database paths
  /// [dbPath] Database path (optional, excluding filename)
  /// [config] Database configuration
  /// [version] Database version number
  /// [onConfigure] Callback when configuring database
  /// [onCreate] Callback when database is first created
  /// [onUpgrade] Callback when database is upgraded
  /// [onDowngrade] Callback when database is downgraded
  /// [onOpen] Callback when database is opened
  ///
  /// 以数据库路径的不同创建独立的实例
  /// [dbPath] 数据库路径，可选，不含文件名
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

  /// Initialize database
  /// Ensure database is fully initialized before any operations
  ///
  /// 初始化数据库
  /// 确保数据库初始化完成并就绪后再执行其他操作
  @override
  Future<void> initialize({String? dbPath, DataStoreConfig? config}) async {
    await _impl.initialize(dbPath: dbPath, config: config);
  }

  /// Create table with schema
  /// [tableName] Table name
  /// [schema] Table schema definition
  /// Example:
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
  ///
  /// 创建数据表
  /// [tableName] 表名
  /// [schema] 表结构定义
  /// 全局表数据共享，其他表在切换空间后数据隔离
  @override
  Future<void> createTable(String tableName, TableSchema schema) async {
    return await _impl.createTable(tableName, schema);
  }

  /// Insert data into table
  /// [tableName] Table name
  /// [data] Data to insert
  ///
  /// 插入数据
  /// [tableName] 表名
  /// [data] 要插入的数据
  @override
  Future<bool> insert(String tableName, Map<String, dynamic> data) async {
    return await _impl.insert(tableName, data);
  }

  /// Query builder for chain-style operations
  /// Example:
  /// ```dart
  /// await db.query('table_name')
  ///         .where('id', '=', 1)
  ///         .or()
  ///         .where('name', '!=', 'marley');
  /// ```
  ///
  /// 查询构建器，支持链式操作
  @override
  QueryBuilder query(String tableName) {
    return QueryBuilder(_impl, tableName);
  }

  /// auto upsert data, if exists, update, if not, insert
  /// [tableName] Table name
  /// [data] Data to upsert
  ///
  /// Example:
  /// ```dart
  /// // Using where condition
  /// await db.upsert('users', {'name': 'John'})
  ///   .where('email', '=', 'john@example.com')
  ///   .execute();
  ///
  /// // Using primary key in data
  /// await db.upsert('users', {
  ///   'id': 1,
  ///   'name': 'John'
  /// }).execute();
  /// ```
  ///
  /// 自动存储数据，存在则更新，不存在则插入
  /// [tableName] 表名
  /// [data] 要插入或更新的数据
  @override
  UpsertBuilder upsert(String tableName, Map<String, dynamic> data) {
    return UpsertBuilder(_impl, tableName, data);
  }

  /// Switch base space for scenarios like user switching
  /// Data isolation between spaces, global tables unaffected
  /// [spaceName] Space name, default is 'default'
  ///
  /// 切换基础空间，用于用户切换等场景
  /// 不同空间数据隔离，全局表数据不受影响
  /// [spaceName] 空间名称，默认为'default'
  @override
  Future<bool> switchBaseSpace({String spaceName = 'default'}) {
    return _impl.switchBaseSpace(spaceName: spaceName);
  }

  /// Update data in table
  /// [tableName] Table name
  /// [data] Data to update
  /// Example:
  /// ```dart
  /// await db.update('users', {'name': 'new_name'})
  ///         .where('id', '=', 1);
  /// ```
  ///
  /// 更新数据
  /// [tableName] 表名
  /// [data] 要更新的数据
  @override
  UpdateBuilder update(String tableName, Map<String, dynamic> data) {
    return UpdateBuilder(_impl, tableName, data);
  }

  /// Batch insert multiple records
  /// [tableName] Table name
  /// [dataList] List of records to insert
  ///
  /// 批量插入数据
  /// [tableName] 表名
  /// [dataList] 要插入的数据列表
  @override
  Future<bool> batchInsert(
      String tableName, List<Map<String, dynamic>> dataList) async {
    return await _impl.batchInsert(tableName, dataList);
  }

  /// Set key-value pair
  /// [key] Key
  /// [value] Value
  /// [isGlobal] Whether it's global key-value pair, default false
  ///
  /// 设置键值对
  /// [key] 键
  /// [value] 值
  /// [isGlobal] 是否为全局键值对，默认false
  @override
  Future<bool> setValue(String key, dynamic value,
      {bool isGlobal = false}) async {
    return await _impl.setValue(key, value, isGlobal: isGlobal);
  }

  /// Get key-value pair
  /// [key] Key
  /// [isGlobal] Whether it's global key-value pair, default false
  ///
  /// 获取键值对
  /// [key] 键
  /// [isGlobal] 是否为全局键值对，默认false
  @override
  Future<dynamic> getValue(String key, {bool isGlobal = false}) async {
    return await _impl.getValue(key, isGlobal: isGlobal);
  }

  /// Delete key-value pair
  /// [key] Key
  /// [isGlobal] Whether it's global key-value pair, default false
  ///
  /// 删除键值对
  /// [key] 键
  /// [isGlobal] 是否为全局键值对，默认false
  @override
  Future<bool> removeValue(String key, {bool isGlobal = false}) async {
    return await _impl.removeValue(key, isGlobal: isGlobal);
  }

  /// Create database backup
  /// Returns backup file path
  ///
  /// 备份数据库
  /// 返回备份文件路径
  @override
  Future<String> backup() async {
    return await _impl.backup();
  }

  /// Restore database from backup
  /// [backupPath] Backup file path
  ///
  /// 从备份恢复数据库
  /// [backupPath] 备份文件路径
  @override
  Future<bool> restore(String backupPath) async {
    return await _impl.restore(backupPath);
  }

  /// Delete data from table
  /// chain operations
  ///
  /// 删除数据
  /// 链式操作
  @override
  DeleteBuilder delete(String tableName) {
    return DeleteBuilder(_impl, tableName);
  }

  /// Drop table
  /// [tableName] Table name
  ///
  /// 删除表
  /// [tableName] 表名
  @override
  Future<void> dropTable(String tableName) async {
    return await _impl.dropTable(tableName);
  }

  /// Clear all data in table
  /// [tableName] Table name
  ///
  /// 清空表数据
  /// [tableName] 表名
  @override
  Future<void> clear(String tableName) async {
    return await _impl.clear(tableName);
  }

  /// Get table schema
  /// [tableName] Table name
  ///
  /// 获取表结构
  /// [tableName] 表名
  @override
  Future<TableSchema> getTableSchema(String tableName) async {
    return await _impl.getTableSchema(tableName);
  }

  /// Get table information including:
  /// - Record count
  /// - Cache count
  /// - File size
  /// - Index count
  /// - Schema
  /// - Last modified time
  /// - Created time
  /// - Global flag
  ///
  /// 获取表信息，包括：
  /// - 记录数量
  /// - 缓存数量
  /// - 文件大小
  /// - 索引数量
  /// - 表结构
  /// - 最后修改时间
  /// - 创建时间
  /// - 是否全局表
  @override
  Future<TableInfo> getTableInfo(String tableName) async {
    return await _impl.getTableInfo(tableName);
  }

  /// Get database configuration
  ///
  /// 获取数据库配置
  @override
  DataStoreConfig get config => _impl.config;

  /// Get current base space name
  ///
  /// 获取当前基础空间名称
  @override
  String? get currentBaseSpaceName => _impl.currentBaseSpaceName;

  /// Get current database version number
  ///
  /// 获取当前数据库版本号
  @override
  Future<int> getVersion() async {
    return await _impl.getVersion();
  }

  /// Set database version number
  /// [version] New version number to set
  ///
  /// 设置数据库版本号
  /// [version] 要设置的新版本号
  @override
  Future<void> setVersion(int version) async {
    return await _impl.setVersion(version);
  }

  /// Query using Map style
  /// [tableName] Table name
  /// [where] Query conditions in Map format
  /// [orderBy] Sort fields
  /// [limit] Maximum number of records
  /// [offset] Number of records to skip
  ///
  /// Map方式查询
  /// [tableName] 表名
  /// [where] Map格式的查询条件
  /// [orderBy] 排序字段
  /// [limit] 最大记录数
  /// [offset] 跳过的记录数
  @override
  Future<List<Map<String, dynamic>>> queryByMap(String tableName,
      {Map<String, dynamic>? where,
      List<String>? orderBy,
      int? limit,
      int? offset}) async {
    return await _impl.queryByMap(tableName,
        where: where, orderBy: orderBy, limit: limit, offset: offset);
  }

  /// Query using SQL style
  /// [tableName] Table name
  /// [where] SQL WHERE clause
  /// [whereArgs] Arguments for WHERE clause
  /// [orderBy] Sort expression
  /// [limit] Maximum number of records
  /// [offset] Number of records to skip
  ///
  /// SQL方式查询
  /// [tableName] 表名
  /// [where] SQL WHERE子句
  /// [whereArgs] WHERE子句的参数
  /// [orderBy] 排序表达式
  /// [limit] 最大记录数
  /// [offset] 跳过的记录数
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

  /// Close database and clean up resources
  /// Removes current instance from instance pool
  ///
  /// 关闭数据库并清理资源
  /// 从实例池中移除当前实例
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

  /// Delete database
  /// [dbPath] Optional database path to delete
  /// Removes current instance from instance pool
  ///
  /// 删除数据库
  /// [dbPath] 可选的要删除的数据库路径
  /// 从实例池中移除当前实例
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
