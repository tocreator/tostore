library tostore;

export 'src/model/table_schema.dart';
export 'src/model/business_error.dart';
export 'src/model/data_store_config.dart';
export 'src/model/table_info.dart';
export 'src/model/log_config.dart';
export 'src/model/space_info.dart';
export 'src/model/db_result.dart';
export 'src/model/migration_task.dart';
export 'src/model/result_code.dart';

import 'src/chain/delete_builder.dart';
import 'src/chain/update_builder.dart';
import 'src/chain/upsert_builder.dart';
import 'src/Interface/data_store_interface.dart';
import 'src/model/data_store_config.dart';
import 'src/core/data_store_impl.dart';
import 'src/model/db_result.dart';
import 'src/model/migration_task.dart';
import 'src/model/table_info.dart';
import 'src/model/table_schema.dart';
import 'src/model/space_info.dart';
import 'src/chain/query_builder.dart';
import 'src/chain/schema_builder.dart';
import 'src/chain/stream_query_builder.dart';

/// High-performance storage engine built specifically for mobile applications.
/// Features:
/// - Chain operations
/// - Multi-space architecture with global data tables
/// - Perfect for user switching scenarios
/// - Single instance covers most use cases
/// - Supports multiple instances with isolated resources
/// - Each instance has independent file storage, cache, index, and transactions
///
/// 专为移动应用打造的高性能数据存储引擎
/// 特性：
/// - 支持链式操作
/// - 多空间架构设计，支持全局共享数据表
/// - 完美适配用户切换场景
/// - 单例足以覆盖常见使用场景
/// - 支持多实例，资源完全隔离
/// - 每个实例拥有独立的文件存储、缓存、索引和事务
class ToStore implements DataStoreInterface {
  /// Create independent instances with different database paths
  /// [dbPath] Database path (optional, excluding filename)
  /// [dbName] Database name for quickly creating different database instances (will be stored in db/dbName/)
  /// [config] Database configuration
  /// [schemas] Database table schemas, Designed for mobile application scenarios, auto upgrade
  /// [onConfigure] Callback when configuring database
  /// [onCreate] Callback when database is first created
  /// [onOpen] Callback when database is opened
  ///
  /// 以数据库路径的不同创建独立的实例
  /// [dbPath] 数据库路径，可选，不含文件名
  /// [dbName] 数据库名称，用于快速创建不同的数据库实例（将存储在 db/dbName/ 下）
  /// [config] 数据库配置
  /// [schemas] 数据库表结构定义，适用移动应用场景，自动化升级
  /// [onConfigure] 数据库配置时的回调
  /// [onCreate] 数据库首次创建时的回调
  /// [onOpen] 数据库打开时的回调
  factory ToStore({
    String? dbPath,
    String? dbName,
    DataStoreConfig? config,
    List<TableSchema> schemas = const [],
    Future<void> Function(ToStore db)? onConfigure,
    Future<void> Function(ToStore db)? onCreate,
    Future<void> Function(ToStore db)? onOpen,
  }) {
    String instanceKey = '$dbPath-${dbName ?? 'default'}';

    if (!_instances.containsKey(instanceKey)) {
      final impl = DataStoreImpl(
        dbPath: dbPath,
        dbName: dbName,
        config: config,
        schemas: schemas,
        onConfigure: onConfigure != null
            ? (db) => onConfigure(ToStore._fromImpl(db))
            : null,
        onCreate:
            onCreate != null ? (db) => onCreate(ToStore._fromImpl(db)) : null,
        onOpen: onOpen != null ? (db) => onOpen(ToStore._fromImpl(db)) : null,
      );
      _instances[instanceKey] = ToStore._internal(impl);
    }
    return _instances[instanceKey]!;
  }

  /// Initialize database
  /// Ensure database is fully initialized before any operations
  ///
  /// 初始化数据库
  /// 确保数据库初始化完成并就绪后再执行其他操作
  @override
  Future<void> initialize({String? dbPath, String? dbName, DataStoreConfig? config}) async {
    await _impl.initialize(dbPath: dbPath, dbName: dbName, config: config);
  }

  /// Create table with schema
  /// [schema] Table schema definition
  /// Example:
  /// ```dart
  /// await db.createTable(
  ///  TableSchema(
  ///   name: 'table_name',
  ///   primaryKeyConfig: PrimaryKeyConfig(
  ///     name: 'userId',
  ///     type: PrimaryKeyType.timestampBased,
  ///   ),
  ///   fields: [
  ///     FieldSchema(
  ///       name: 'userName',
  ///       type: DataType.text,
  ///       nullable: false,
  ///       unique: true,
  ///     ),
  ///   ],
  ///   indexes: [
  ///     IndexSchema(
  ///       fields: ['userName'],
  ///     ),
  ///   ],
  /// ));
  /// ```
  ///
  /// 创建数据表
  /// [schema] 表结构定义
  /// 全局表数据共享，其他表在切换空间后数据隔离
  @override
  Future<void> createTable(TableSchema schema) async {
    return await _impl.createTable(schema);
  }

  /// Create multiple tables
  /// [schemas] List of table schemas
  ///
  /// 创建多个表
  /// [schemas] 表结构定义列表
  ///
  /// Example:
  /// ```dart
  /// await db.createTables([
  ///   TableSchema(
  ///     name: 'table_name',
  ///     primaryKeyConfig: PrimaryKeyConfig(
  ///       name: 'userId',
  ///       type: PrimaryKeyType.timestampBased,
  ///     ),
  ///     fields: [
  ///       FieldSchema(
  ///         name: 'userName',
  ///         type: DataType.text,
  ///         nullable: false,
  ///         unique: true,
  ///       ),
  ///     ],
  ///   ),
  ///   TableSchema(...),
  /// ]);
  /// ```
  @override
  Future<void> createTables(List<TableSchema> schemas) async {
    return await _impl.createTables(schemas);
  }

  /// Insert data into table
  /// [tableName] Table name
  /// [data] Data to insert
  /// Returns the operation result with primary key if successful
  ///
  /// 插入数据
  /// [tableName] 表名
  /// [data] 要插入的数据
  /// 返回操作结果，包含主键信息
  @override
  Future<DbResult> insert(String tableName, Map<String, dynamic> data) async {
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

  /// Stream query data for a table, supports filtering
  ///
  /// Example:
  /// ```dart
  /// // Use directly as a Stream with listen
  /// db.streamQuery('users')
  ///   .where('age', '>', 18)
  ///   .select(['name', 'email'])
  ///   .listen((user) {
  ///     print(user);
  ///   });
  ///
  /// // Or with async for loop
  /// await for (final user in db.streamQuery('users').where('id', '=', 123).stream) {
  ///   print(user);
  /// }
  /// ```
  /// 流式查询，支持链式操作条件过滤
  @override
  StreamQueryBuilder streamQuery(String tableName) {
    return StreamQueryBuilder(_impl, tableName);
  }

  /// auto upsert data, if exists, update, if not, insert
  /// [tableName] Table name
  /// [data] Data to upsert
  ///
  /// Example:
  /// ```dart
  /// // Using where condition
  /// await db.upsert('users', {'name': 'John'})
  ///   .where('email', '=', 'john@example.com');
  ///
  /// // Using primary key in data
  /// await db.upsert('users', {
  ///   'id': 1,
  ///   'name': 'John'
  /// });
  /// ```
  ///
  /// 自动存储数据，存在则更新，不存在则插入
  /// [tableName] 表名
  /// [data] 要插入或更新的数据
  @override
  UpsertBuilder upsert(String tableName, Map<String, dynamic> data) {
    return UpsertBuilder(_impl, tableName, data);
  }

  /// Switch space for scenarios like user switching
  /// Data isolation between spaces, global tables unaffected
  /// [spaceName] Space name, default is 'default'
  ///
  /// 切换空间，用于用户切换等场景
  /// 不同空间数据隔离，全局表数据不受影响
  /// [spaceName] 空间名称，默认为'default'
  @override
  Future<bool> switchSpace({String spaceName = 'default'}) {
    return _impl.switchSpace(spaceName: spaceName);
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
  /// Returns the operation result with successful and failed keys
  ///
  /// 批量插入数据
  /// [tableName] 表名
  /// [dataList] 要插入的数据列表
  /// 返回操作结果，包含成功和失败的主键信息
  @override
  Future<DbResult> batchInsert(
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
  /// [compress] Whether to compress the backup into a zip file, default is true
  /// Returns backup file path
  ///
  /// 备份数据库
  /// [compress] 是否压缩备份为 zip 文件，默认为 true
  /// 返回备份文件路径
  @override
  Future<String> backup({bool compress = true}) async {
    return await _impl.backup(compress: compress);
  }

  /// Restore database from backup
  /// [backupPath] Backup file path
  /// [deleteAfterRestore] Whether to delete the backup file after restore, default is false
  ///
  /// 从备份恢复数据库
  /// [backupPath] 备份文件路径
  /// [deleteAfterRestore] 是否在恢复后删除备份文件，默认为 false
  @override
  Future<bool> restore(String backupPath,
      {bool deleteAfterRestore = false}) async {
    return await _impl.restore(backupPath,
        deleteAfterRestore: deleteAfterRestore);
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
  Future<TableSchema?> getTableSchema(String tableName) async {
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
  Future<TableInfo?> getTableInfo(String tableName) async {
    return await _impl.getTableInfo(tableName);
  }

  /// Get database configuration
  ///
  /// 获取数据库配置
  @override
  DataStoreConfig get config => _impl.config;

  /// Get current space name
  ///
  /// 获取当前空间名称
  @override
  String? get currentSpaceName => _impl.currentSpaceName;

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
  /// [dbName] Optional database name to delete
  /// Removes current instance from instance pool
  ///
  /// 删除数据库
  /// [dbPath] 可选的要删除的数据库路径
  /// [dbName] 可选的要删除的数据库名称
  /// 从实例池中移除当前实例
  @override
  Future<void> deleteDatabase({String? dbPath, String? dbName}) async {
    await _impl.deleteDatabase(dbPath: dbPath, dbName: dbName);

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

  /// Update table schema, supports chain operations
  /// [tableName] Table name
  ///
  /// Example:
  /// ```dart
  /// final taskId = await db.updateSchema('users')
  ///   .addField('age', DataType.integer)
  ///   .removeField('old_field')
  ///   .renameField('name', 'full_name')
  ///   .modifyField('email', (field) => field.unique());
  /// ```
  ///
  /// 更新表结构，支持链式操作
  /// [tableName] 表名
  @override
  SchemaBuilder updateSchema(String tableName) {
    return SchemaBuilder(_impl, tableName);
  }

  /// 查询迁移任务状态
  /// [taskId] 任务ID，可从updateSchema()方法中直接获取
  /// 返回任务的详细状态，如果任务不存在则返回null
  ///
  /// Example:
  /// ```dart
  /// // 先执行更新操作获取任务ID
  /// final taskId = await db.updateSchema('users')
  ///   .renameField('nickname', 'displayName');
  ///
  /// // 查询任务状态
  /// final status = await db.queryMigrationTaskStatus(taskId);
  /// print('Migration progress: ${status?.progressPercentage}%');
  /// ```
  @override
  Future<MigrationStatus?> queryMigrationTaskStatus(String taskId) async {
    if (_impl.migrationManager == null) {
      return null;
    }
    return _impl.migrationManager!.queryTaskStatus(taskId);
  }

  /// Get information about the current space
  /// Returns detailed information about the current working space
  ///
  /// 获取当前空间的信息
  /// 返回当前工作空间的详细信息
  @override
  Future<SpaceInfo> getSpaceInfo() async {
    return await _impl.getSpaceInfo();
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
