/// ToStore is a high-performance distributed data storage engine that builds intelligent data networks
/// using multi-partition parallel mechanisms and interconnected topologies.
///
/// Key features:
/// - Precise table structure change detection and automatic migration
/// - Encryption protection and multi-space architecture
/// - Isolate parallel processing to fully utilize multi-core performance
/// - Cross-platform support from mobile edge devices to cloud servers
/// - Multiple distributed primary key algorithms and horizontal node expansion
///
/// ToStore provides a distributed data foundation for immersive virtual-real fusion,
/// multimodal interaction, 3D spatial features, generative AI, and semantic vector space modeling.
library;

import 'dart:async';

import 'src/Interface/chain_builder.dart';
import 'src/Interface/data_store_interface.dart';
import 'src/Interface/status_provider.dart';

import 'src/chain/schema_builder.dart';
import 'src/chain/stream_query_builder.dart';
import 'src/core/data_store_impl.dart';
import 'src/Interface/kv_store.dart';
import 'src/handler/logger.dart';
import 'src/model/backup_scope.dart';

import 'src/model/data_store_config.dart';
import 'src/model/db_result.dart';
import 'src/model/migration_task.dart';
import 'src/model/query_result.dart';
import 'src/model/space_info.dart';
import 'src/model/system_table.dart';
import 'src/model/table_info.dart';
import 'src/model/table_schema.dart';
import 'src/model/transaction_result.dart';

export 'src/Interface/status_provider.dart';
export 'src/handler/logger.dart' show LogType;
export 'src/handler/to_crypto.dart';
export 'src/model/backup_scope.dart';
export 'src/model/business_error.dart';
export 'src/model/config_info.dart';
export 'src/model/data_store_config.dart';
export 'src/model/db_result.dart';
export 'src/model/expr.dart';
export 'src/model/log_config.dart';
export 'src/model/memory_info.dart';
export 'src/model/migration_config.dart';
export 'src/model/migration_task.dart';
export 'src/model/query_aggregation.dart';
export 'src/model/query_result.dart';
export 'src/model/result_type.dart';
export 'src/model/space_info.dart';
export 'src/model/table_info.dart';
export 'src/model/table_schema.dart';
export 'src/model/transaction_result.dart';
export 'src/query/query_condition.dart';

/// High-performance storage engine
/// Features:
/// - Chain operations
/// - Multi-space architecture with global data tables
/// - Supports multiple instances with isolated resources
/// - Each instance has independent file storage, cache, index, and transactions
///
/// 高性能数据存储引擎
/// 特性：
/// - 支持链式操作
/// - 多空间架构设计，支持全局共享数据表
/// - 支持多实例，资源完全隔离
/// - 每个实例拥有独立的文件存储、缓存、索引和事务
class ToStore implements DataStoreInterface {
  /// Create independent instances with different database paths
  /// [dbPath] Database root path. On Android/iOS: REQUIRED — provide a persistent app
  /// directory (e.g., using path_provider's getApplicationDocumentsDirectory()).
  /// On desktop/server: optional — if omitted, a standard OS application data
  /// directory will be used.
  /// [dbName] Database name for quickly creating different database instances (will be stored in dbPath/dbName/)
  /// [config] Database configuration
  /// [schemas] Database table schemas, Designed for mobile application scenarios, auto upgrade
  /// [onConfigure] Callback when configuring database
  /// [onCreate] Callback when database is first created
  /// [onOpen] Callback when database is opened
  ///
  /// 以数据库路径的不同创建独立的实例
  /// [dbPath] 数据库的根路径。移动端(Android/iOS)必须手动填写，推荐使用 path_provider
  /// 的 getApplicationDocumentsDirectory() 作为持久化目录；桌面/服务器平台可缺省，未提供时
  /// 将自动解析到系统应用数据目录。
  /// [dbName] 数据库名称，用于在dbPath下创建独立的数据库实例目录（如 'dbPath/dbName/'）。默认为 'default'。
  /// [config] 数据库配置。dbPath和dbName参数会覆盖此配置中的同名值。
  /// [schemas] 数据库表结构定义，适用移动应用场景，自动化升级
  /// [onConfigure] 数据库配置时的回调
  /// [onCreate] 数据库首次创建时的回调
  /// [onOpen] 数据库打开时的回调
  @Deprecated('Use ToStore.open() instead')
  factory ToStore({
    String? dbPath,
    String? dbName,
    DataStoreConfig? config,
    List<TableSchema> schemas = const [],
    Future<void> Function(ToStore db)? onConfigure,
    Future<void> Function(ToStore db)? onCreate,
    Future<void> Function(ToStore db)? onOpen,
  }) {
    final effectiveDbPath = dbPath ?? config?.dbPath ?? 'default';
    final effectiveDbName = dbName ?? config?.dbName ?? 'default';
    String instanceKey = '$effectiveDbPath-$effectiveDbName';

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

  /// Open a database instance (Single-step initialization).
  ///
  /// This is the preferred way to obtain an initialized ToStore instance.
  /// For multi-instance scenarios, different [dbName] or [dbPath] will return different instances.
  ///
  /// [dbPath] Database root path.
  /// [dbName] Database name (instances are stored in dbPath/dbName/).
  /// [config] Database configuration.
  /// [schemas] Initial table schemas for automatic migration.
  /// [onConfigure] Callback invoked when the database is being configured.
  /// [onCreate] Callback invoked when the database is first created.
  /// [onOpen] Callback invoked when the database is successfully opened.
  /// [reinitialize] If true, forces a re-initialization (close then open).
  /// [noPersistOnClose] If true, skips flushing the buffer during close (used with reinitialize).
  /// [applyActiveSpaceOnDefault] If true, uses the last active space when opening the 'default' space.
  ///
  /// 打开数据库实例（一步初始化）。
  ///
  /// 获取或创建实例并完成初始化的首选方式。
  /// 在多实例场景下，不同的 [dbName] 或 [dbPath] 会返回不同的实例。
  ///
  /// [dbPath] 数据库根路径。
  /// [dbName] 数据库名称（实例存储在 dbPath/dbName/ 目录下）。
  /// [config] 数据库配置。
  /// [schemas] 初始表结构定义，用于自动化迁移。
  /// [onConfigure] 数据库配置时的回调。
  /// [onCreate] 数据库首次创建时的回调。
  /// [onOpen] 数据库打开成功后的回调。
  /// [reinitialize] 为 true 时强制重新初始化（先关闭后打开）。
  /// [noPersistOnClose] 为 true 时关闭时不落盘缓冲数据（与 reinitialize 配合使用）。
  /// [applyActiveSpaceOnDefault] 为 true 时，打开 'default' 空间将自动切换到上次活跃的空间。
  static Future<ToStore> open({
    String? dbPath,
    String? dbName,
    DataStoreConfig? config,
    List<TableSchema> schemas = const [],
    Future<void> Function(ToStore db)? onConfigure,
    Future<void> Function(ToStore db)? onCreate,
    Future<void> Function(ToStore db)? onOpen,
    bool reinitialize = false,
    bool noPersistOnClose = false,
    bool applyActiveSpaceOnDefault = true,
  }) async {
    // ignore: deprecated_member_use_from_same_package
    final db = ToStore(
      dbPath: dbPath,
      dbName: dbName,
      config: config,
      schemas: schemas,
      onConfigure: onConfigure,
      onCreate: onCreate,
      onOpen: onOpen,
    );
    // ignore: deprecated_member_use_from_same_package
    await db.initialize(
      dbPath: dbPath,
      dbName: dbName,
      config: config,
      reinitialize: reinitialize,
      noPersistOnClose: noPersistOnClose,
      applyActiveSpaceOnDefault: applyActiveSpaceOnDefault,
    );
    return db;
  }

  /// Open a pure in-memory database instance (no file IO).
  ///
  /// - No WAL, no recovery, no meta/config persistence.
  /// - All data lives in memory (TreeCache-based).
  ///
  /// Use this for testing, ephemeral session stores, or ultra-fast in-process caches.
  static Future<ToStore> memory({
    String? dbName,
    DataStoreConfig? config,
    List<TableSchema> schemas = const [],
    Future<void> Function(ToStore db)? onConfigure,
    Future<void> Function(ToStore db)? onCreate,
    Future<void> Function(ToStore db)? onOpen,
    bool reinitialize = false,
  }) async {
    final base = config ?? DataStoreConfig();
    final effectiveName = dbName ?? base.dbName;

    // Force memory-mode invariants.
    final memConfig = base.copyWith(
      persistenceMode: PersistenceMode.memory,
      dbPath: '__memory__',
      dbName: effectiveName,
      enableJournal: false,
      persistRecoveryOnCommit: false,
      recoveryFlushPolicy: RecoveryFlushPolicy.off,
    );

    // ignore: deprecated_member_use_from_same_package
    final db = ToStore(
      dbPath: '__memory__',
      dbName: effectiveName,
      config: memConfig,
      schemas: schemas,
      onConfigure: onConfigure,
      onCreate: onCreate,
      onOpen: onOpen,
    );

    // ignore: deprecated_member_use_from_same_package
    await db.initialize(
      dbPath: '__memory__',
      dbName: effectiveName,
      config: memConfig,
      reinitialize: reinitialize,
      noPersistOnClose: true,
      applyActiveSpaceOnDefault: false,
    );
    return db;
  }

  /// Initialize database
  /// Ensure the engine is fully initialized before any operations.
  ///
  /// Parameters:
  /// - [dbPath]: Optional root path. If provided, overrides `config.dbPath`.
  /// - [dbName]: Optional database name. If provided, overrides `config.dbName`.
  /// - [config]: Database configuration. When `dbPath`/`dbName` are provided, they take precedence
  ///   over the corresponding fields in this config.
  /// - [reinitialize]: When true, force a re-open of the database (close then open).
  /// - [noPersistOnClose]: Used together with `reinitialize`. When true, do NOT persist pending
  ///
  /// Examples:
  /// ```dart
  /// final db = await ToStore.open(
  ///   dbName: 'my_db',
  ///   schemas: [UserSchema],
  /// );
  /// ```
  ///
  /// 初始化数据库
  /// 在任何操作前确保引擎已就绪。
  ///
  /// 参数说明：
  /// - dbPath：可选数据库根路径；传入时优先级高于 `config.dbPath`。
  /// - dbName：可选数据库名称；传入时优先级高于 `config.dbName`。
  /// - config：数据库配置；当同时传入 dbPath/dbName 时，以参数值覆盖配置中的同名字段。
  /// - reinitialize：为 true 时强制重新初始化（先关闭后打开）。
  /// - noPersistOnClose：与 reinitialize 配合；为 true 时关闭阶段不落盘缓冲数据，直接清理缓存
  ///
  /// Examples:
  /// ```dart
  /// await db.initialize(reinitialize: true); // 持久化缓冲并重启
  /// ```
  @override
  @Deprecated('Use ToStore.open() instead')
  Future<void> initialize(
      {String? dbPath,
      String? dbName,
      DataStoreConfig? config,
      bool reinitialize = false,
      bool noPersistOnClose = false,
      bool applyActiveSpaceOnDefault = true}) async {
    await _impl.initialize(
      dbPath: dbPath,
      dbName: dbName,
      config: config,
      reinitialize: reinitialize,
      noPersistOnClose: noPersistOnClose,
      applyActiveSpaceOnDefault: applyActiveSpaceOnDefault,
    );
  }

  /// Create a database table with the provided schema.
  ///
  /// [schema] The table schema definition.
  /// Returns a [DbResult] indicating success or failure.
  ///
  /// Example:
  /// ```dart
  /// final result = await db.createTable(
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
  ///       fields: `['userName']`,
  ///     ),
  ///   ],
  /// ));
  /// if (!result.isSuccess) {
  ///   print('Failed to create table: ${result.message}');
  /// }
  /// ```
  ///
  /// 创建数据表。
  ///
  /// [schema] 表结构定义。
  /// 返回 [DbResult] 表示操作成功或失败。
  @override
  Future<DbResult> createTable(TableSchema schema) async {
    return await _impl.createTable(schema);
  }

  /// Create multiple tables
  /// [schemas] List of table schemas
  /// Returns [DbResult] to allow graceful error handling for business logic errors
  ///
  /// 创建多个表
  /// [schemas] 表结构定义列表
  /// 返回 [DbResult] 方便处理业务逻辑错误
  ///
  /// Example:
  /// ```dart
  /// final result = await db.createTables([
  ///   TableSchema(...),
  ///   TableSchema(...),
  /// ]);
  /// if (result.isPartialSuccess) {
  ///   print('Some tables created: ${result.successKeys}');
  ///   print('Failed: ${result.failedKeys}');
  /// }
  /// ```
  @override
  Future<DbResult> createTables(List<TableSchema> schemas) async {
    return await _impl.createTables(schemas);
  }

  /// Insert a record into a table.
  ///
  /// [tableName] The name of the table.
  /// [data] The map of fields and values to insert.
  /// Returns a [DbResult] containing the primary key of the inserted record.
  ///
  /// 插入单条数据。
  ///
  /// [tableName] 表名。
  /// [data] 要插入的数据（键值对）。
  /// 返回操作结果 [DbResult]，成功时包含主键信息。
  @override
  Future<DbResult> insert(String tableName, Map<String, dynamic> data) async {
    _checkSystemTableAccess(
        tableName, 'cannot be accessed manually', 'ToStore.insert');

    return await _impl.insert(tableName, data);
  }

  /// Get a query builder for chain-style operations.
  ///
  /// [tableName] The name of the table to query.
  /// Returns a [QueryBuilder] to build and execute the query.
  ///
  /// Example:
  /// ```dart
  /// await db.query('table_name')
  ///         .where('id', '=', 1);
  /// ```
  ///
  /// 查询构建器，支持链式操作。
  ///
  /// [tableName] 表名。
  /// 返回 [QueryBuilder] 用于构建和执行查询。
  @override
  QueryBuilder query(String tableName) {
    _checkSystemTableAccess(
        tableName, 'cannot be queried manually', 'ToStore.query');

    return QueryBuilder(_impl, tableName);
  }

  /// Get a stream query builder for reactive data updates.
  ///
  /// [tableName] The name of the table to watch.
  /// Returns a [StreamQueryBuilder] to build and listen to data changes.
  ///
  /// Example:
  /// ```dart
  /// // Use directly as a Stream with listen
  /// db.streamQuery('users')
  ///   .where('age', '>', 18)
  ///   .select(`['name', 'email']`)
  ///   .listen((user) {
  ///     print(user);
  ///   });
  ///
  /// // Or with async for loop
  /// await for (final user in db.streamQuery('users').where('id', '=', 123).stream) {
  ///   print(user);
  /// }
  /// ```
  /// 流式查询构建器，支持响应式数据更新。
  ///
  /// [tableName] 表名。
  /// 返回 [StreamQueryBuilder] 用于构建和监听数据变化。
  @override
  StreamQueryBuilder streamQuery(String tableName) {
    _checkSystemTableAccess(
        tableName, 'cannot be watched manually', 'ToStore.streamQuery');

    return StreamQueryBuilder(_impl, tableName);
  }

  /// Upsert a record: updates if it exists, otherwise inserts.
  ///
  /// Existing rows are located via primary key or unique indexes.
  ///
  /// [tableName] The name of the table.
  /// [data] The data map to insert or update.
  /// Returns a [DbResult] indicating success or failure.
  ///
  /// Example:
  /// ```dart
  /// await db.upsert('users', {'id': 1, 'username': 'john', 'email': 'john@example.com'});
  /// await db.upsert('users', {'username': 'john', 'email': 'john@example.com'});
  /// ```
  ///
  /// 自动存储数据：如果记录存在（基于主键或唯一索引）则更新，否则插入。
  ///
  /// [tableName] 表名。
  /// [data] 要插入或更新的数据。
  /// 返回 [DbResult] 表示操作成功或失败。
  @override
  Future<DbResult> upsert(String tableName, Map<String, dynamic> data) {
    _checkSystemTableAccess(
        tableName, 'cannot be modified manually', 'ToStore.upsert');

    return _impl.upsert(tableName, data);
  }

  /// Perform an approximate nearest neighbor (ANN) vector similarity search.
  ///
  /// [tableName] The name of the table.
  /// [fieldName] The name of the vector field.
  /// [queryVector] The target vector to search for.
  /// [topK] Number of most similar results to return.
  /// [efSearch] Search width for NGH (HNSW-style) algorithm (higher is more accurate but slower).
  /// [distanceThreshold] Maximum distance for results to be included.
  /// Returns a list of [VectorSearchResult] sorted by similarity.
  ///
  /// Example:
  /// ```dart
  /// final results = await db.vectorSearch(
  ///   'articles',
  ///   fieldName: 'embedding',
  ///   queryVector: VectorData([0.1, 0.2, ...]),
  ///   topK: 10,
  /// );
  /// for (final r in results) {
  ///   print('pk=${r.primaryKey}, score=${r.score}');
  /// }
  /// ```
  ///
  /// 向量相似度搜索（ANN 搜索）。
  ///
  /// [tableName] 表名。
  /// [fieldName] 向量字段名称。
  /// [queryVector] 查询目标向量。
  /// [topK] 返回最相似的结果数量。
  /// [efSearch] NGH 算法的搜索宽度（值越大越精确，但速度越慢）。
  /// [distanceThreshold] 距离阈值，超过此值的记录将被过滤。
  /// 返回按相似度排序的 [VectorSearchResult] 列表。
  Future<List<VectorSearchResult>> vectorSearch(
    String tableName, {
    required String fieldName,
    required VectorData queryVector,
    int topK = 10,
    int? efSearch,
    double? distanceThreshold,
  }) {
    _checkSystemTableAccess(
        tableName, 'cannot be searched manually', 'ToStore.vectorSearch');
    return _impl.vectorSearch(
      tableName,
      fieldName: fieldName,
      queryVector: queryVector,
      topK: topK,
      efSearch: efSearch,
      distanceThreshold: distanceThreshold,
    );
  }

  /// Switch to a different data space.
  ///
  /// Data is isolated between spaces, except for global tables.
  ///
  /// [spaceName] The name of the space to switch to (default is 'default').
  /// [keepActive] If true, saves this space as the active space for the next session.
  /// Returns true if the switch was successful.
  ///
  /// 切换到不同的数据空间。
  ///
  /// 不同空间的数据是相互隔离的，但全局表不受影响。
  ///
  /// [spaceName] 要切换的空间名称（默认为 'default'）。
  /// [keepActive] 为 true 时，将该空间记为活跃空间，下次启动时可自动切换。
  /// 返回 true 表示切换成功。
  @override
  Future<bool> switchSpace(
      {String spaceName = 'default', bool keepActive = true}) {
    return _impl.switchSpace(spaceName: spaceName, keepActive: keepActive);
  }

  /// Get an update builder to modify records.
  ///
  /// [tableName] The name of the table.
  /// [data] Initial fields and values to update.
  /// Returns an [UpdateBuilder] to specify conditions and execute the update.
  ///
  /// Example:
  /// ```dart
  /// // Update with condition
  /// await db.update('users', {'name': 'new_name'})
  ///         .where('id', '=', 1);
  ///
  /// // Update all records, if there is no condition, the update operation will be rejected to prevent accidental update.
  /// await db.update('users', {'status': 'inactive'})
  ///         .allowUpdateAll();
  ///
  /// // Continue even if some records fail
  /// await db.update('users', {'email': 'unique@example.com'})
  ///         .where('status', '=', 'inactive')
  ///         .allowPartialErrors();
  /// ```
  ///
  /// 获取更新构建器，用于修改记录。
  ///
  /// [tableName] 表名。
  /// [data] 初始更新字段和值。
  /// 返回 [UpdateBuilder] 用于指定条件并执行更新。
  @override
  UpdateBuilder update(String tableName,
      [Map<String, dynamic> data = const {}]) {
    _checkSystemTableAccess(
        tableName, 'cannot be updated manually', 'ToStore.update');

    return UpdateBuilder(_impl, tableName, data);
  }

  /// Batch insert multiple records.
  ///
  /// [tableName] Table name.
  /// [dataList] List of records to insert.
  /// [allowPartialErrors] Whether to continue when some records fail to insert (defaults to true).
  ///
  /// Returns the operation result with successful and failed keys.
  ///
  /// 批量插入多条记录。
  ///
  /// [tableName] 表名。
  /// [dataList] 要插入的数据列表。
  /// [allowPartialErrors] 当部分记录插入失败时是否继续处理其他记录（默认为 true）。
  ///
  /// 返回包含成功和失败主键信息的操作结果。
  @override
  Future<DbResult> batchInsert(
      String tableName, List<Map<String, dynamic>> dataList,
      {bool allowPartialErrors = true}) async {
    _checkSystemTableAccess(
        tableName, 'cannot be batchInserted manually', 'ToStore.batchInsert');

    return await _impl.batchInsert(
      tableName,
      dataList,
      allowPartialErrors: allowPartialErrors,
    );
  }

  /// Batch upsert multiple records based on unique constraints.
  ///
  /// - Each record must contain all non-nullable (nullable=false) fields except the primary key,
  ///   as well as all fields that participate in unique indexes.
  /// - For each record, existing rows are located using unique indexes; if found, the row is updated,
  ///   otherwise a new row is inserted.
  /// - When the table has no unique constraints, this operation is not supported and will return an error.
  /// [tableName] Table name.
  /// [dataList] List of records to upsert.
  /// [allowPartialErrors] When false, the operation fails immediately if any record fails. Defaults to true.
  ///
  ///  ///
  /// Example:
  /// ```dart
  /// // Insert multiple records and continue even if some fail (default behavior)
  /// final result = await db.batchInsert('users', [
  ///   {'name': 'John', 'email': 'john@example.com'},
  ///   {'name': 'Jane', 'email': 'jane@example.com'}
  /// ]);
  ///
  /// // Check results
  /// print('Successful: ${result.successCount}, Failed: ${result.failedCount}');
  ///
  /// // Stop on first error
  /// final strictResult = await db.batchInsert('users', records,
  ///   allowPartialErrors: false);
  /// ```
  ///
  /// 批量 UPSERT 数据（基于唯一约束判断插入或更新）。
  ///
  /// - 每条记录必须包含除主键外的所有非空（nullable=false）字段，以及参与唯一索引的所有字段。
  /// - 对于每条记录，系统会通过唯一索引定位现有行；如果找到则更新，否则插入新行。
  /// - 当表没有定义唯一约束时，不支持此操作并会返回错误。
  ///
  /// [tableName] 表名。
  /// [dataList] 记录列表。
  /// [allowPartialErrors] 当部分记录失败时是否继续处理其他记录（默认为 true）。
  @override
  Future<DbResult> batchUpsert(
      String tableName, List<Map<String, dynamic>> dataList,
      {bool allowPartialErrors = true}) async {
    _checkSystemTableAccess(
        tableName, 'cannot be batchUpserted manually', 'ToStore.batchUpsert');

    return await _impl.batchUpsert(
      tableName,
      dataList,
      allowPartialErrors: allowPartialErrors,
    );
  }

  /// Batch update multiple records based on primary key.
  ///
  /// - Each record must contain the primary key.
  /// - Only the fields provided in the record will be updated (partial update).
  /// [tableName] Table name.
  /// [dataList] List of records to update.
  /// [allowPartialErrors] When false, the operation fails immediately if any record fails. Defaults to true.
  ///
  /// Example:
  /// ```dart
  /// final result = await db.batchUpdate('users', [
  ///   {'id': 1, 'name': 'John'},
  ///   {'id': 2, 'age': 30}
  /// ]);
  /// ```
  ///
  /// 批量更新数据（基于主键判断）。
  ///
  /// - 每条记录必须包含主键。
  /// - 仅更新记录中提供的字段（增量更新/局部更新）。
  ///
  /// [tableName] 表名。
  /// [dataList] 记录列表。
  /// [allowPartialErrors] 当部分记录失败时是否继续处理其他记录（默认为 true）。
  @override
  Future<DbResult> batchUpdate(
      String tableName, List<Map<String, dynamic>> dataList,
      {bool allowPartialErrors = true}) async {
    _checkSystemTableAccess(
        tableName, 'cannot be batchUpdated manually', 'ToStore.batchUpdate');

    return await _impl.batchUpdate(
      tableName,
      dataList,
      allowPartialErrors: allowPartialErrors,
    );
  }

  /// Set a key-value pair in the KV store.
  ///
  /// [key] The unique identifier for the value.
  /// [value] The data to store.
  /// [ttl] Relative expiration duration (mutually exclusive with [expiresAt]).
  /// [expiresAt] Absolute expiration time (mutually exclusive with [ttl]).
  /// [isGlobal] If true, the value is shared across all spaces.
  /// Returns a [DbResult] indicating success or failure.
  ///
  /// 在 KV 存储中设置键值对。
  ///
  /// [key] 键。
  /// [value] 值。
  /// [ttl] 相对过期时间（与 [expiresAt] 互斥）。
  /// [expiresAt] 绝对过期时间（与 [ttl] 互斥）。
  /// [isGlobal] 为 true 时，该键值对在所有空间共享。
  /// 返回 [DbResult] 表示操作成功或失败。
  @override
  Future<DbResult> setValue(
    String key,
    dynamic value, {
    Duration? ttl,
    DateTime? expiresAt,
    bool isGlobal = false,
  }) async {
    return await _impl.setValue(
      key,
      value,
      ttl: ttl,
      expiresAt: expiresAt,
      isGlobal: isGlobal,
    );
  }

  /// Get a value from the KV store.
  ///
  /// [key] The unique identifier for the value.
  /// [isGlobal] If true, looks up the value in the global space.
  /// Returns the stored value, or null if it does not exist or has expired.
  ///
  /// 从 KV 存储中获取值。
  ///
  /// [key] 键。
  /// [isGlobal] 为 true 时，从全局空间查找。
  /// 返回存储的值；如果不存在或已过期，则返回 null。
  @override
  Future<dynamic> getValue(String key, {bool isGlobal = false}) async {
    return await _impl.getValue(key, isGlobal: isGlobal);
  }

  /// Watch a key-value pair for changes.
  ///
  /// Emits the current value immediately upon subscription.
  ///
  /// [key] The unique identifier for the value.
  /// [isGlobal] If true, watches the value in the global space.
  /// [defaultValue] The value to emit if the key does not exist.
  /// [distinct] If true, suppresses consecutive identical values.
  /// Returns a [Stream] of the value.
  ///
  /// 监听键值对的变化。
  ///
  /// 订阅时会立即发出当前值。
  ///
  /// [key] 键。
  /// [isGlobal] 为 true 时，监听全局空间的值。
  /// [defaultValue] 当键不存在时使用的默认值。
  /// [distinct] 为 true 时，抑制连续重复的值。
  /// 返回该值的 [Stream]。
  @override
  Stream<T?> watchValue<T>(String key,
      {bool isGlobal = false, T? defaultValue, bool distinct = true}) {
    return _impl.watchValue<T>(
      key,
      isGlobal: isGlobal,
      defaultValue: defaultValue,
      distinct: distinct,
    );
  }

  /// Watch multiple key-value pairs for changes.
  ///
  /// [keys] The list of keys to watch.
  /// [isGlobal] If true, watches the values in the global space.
  /// [distinct] If true, suppresses emissions if the snapshot has not changed.
  /// Returns a [Stream] of the snapshot map.
  ///
  /// 监听多个键值对的变化。
  ///
  /// 订阅时会立即发出包含所有键值的快照 Map。
  ///
  /// [keys] 要监听的键列表。
  /// [isGlobal] 为 true 时，监听全局空间的值。
  /// [distinct] 为 true 时，如果快照未发生变化则抑制发射。
  /// 返回快照 Map 的 [Stream]。
  @override
  Stream<Map<String, dynamic>> watchValues(Iterable<String> keys,
      {bool isGlobal = false, bool distinct = true}) {
    return _impl.watchValues(
      keys,
      isGlobal: isGlobal,
      distinct: distinct,
    );
  }

  /// Delete key-value pair
  /// [key] Key
  /// [isGlobal] Whether it's global key-value pair, default false
  ///
  /// 删除键值对
  /// [key] 键
  /// [isGlobal] 是否为全局键值对，默认false
  @override
  Future<DbResult> removeValue(String key, {bool isGlobal = false}) async {
    return await _impl.removeValue(key, isGlobal: isGlobal);
  }

  /// Create a backup of the database.
  ///
  /// [compress] If true, compresses the backup into a ZIP file.
  /// [scope] The scope of the backup (e.g., current space, global data).
  /// Returns the file path of the created backup.
  ///
  /// 创建数据库备份。
  ///
  /// [compress] 为 true 时，将备份压缩为 ZIP 文件。
  /// [scope] 备份范围（如：当前空间、全局数据等）。
  /// 返回生成的备份文件路径。
  @override
  Future<String> backup(
      {bool compress = true,
      BackupScope scope = BackupScope.currentSpaceWithGlobal}) async {
    return await _impl.backup(compress: compress, scope: scope);
  }

  /// Restore database from backup
  /// [backupPath] Backup file path
  /// [deleteAfterRestore] Whether to delete the backup file after restore, default is false
  /// [cleanupBeforeRestore] Whether to cleanup the related data before restore, default is true
  ///
  /// 从备份恢复数据库
  /// [backupPath] 备份文件路径
  /// [deleteAfterRestore] 是否在恢复后删除备份文件，默认为 false
  /// [cleanupBeforeRestore] 是否在恢复前清空相关数据，默认为 true
  @override
  Future<bool> restore(String backupPath,
      {bool deleteAfterRestore = false,
      bool cleanupBeforeRestore = true}) async {
    return await _impl.restore(backupPath,
        deleteAfterRestore: deleteAfterRestore,
        cleanupBeforeRestore: cleanupBeforeRestore);
  }

  /// Run a transaction scope
  /// [action] Transaction action
  /// [rollbackOnError] Rolls back on error if true.
  /// [persistRecoveryOnCommit] Overrides the default recovery mechanism for this transaction.
  /// [isolation] Overrides the default isolation level for this transaction.
  ///
  /// 运行一个事务范围
  /// [action] 事务操作
  /// [rollbackOnError] 如果为 true，则在发生错误时回滚。
  /// [persistRecoveryOnCommit] 为本次事务恢复机制是否持久化，如果为null则使用配置的默认值。
  /// [isolation] 为本次事务指定隔离级别，如果为null则使用配置的默认值。
  ///
  /// Example:
  /// ```dart
  /// await db.transaction(() async {
  ///   await db.insert('users', {'name': 'John'});
  /// });
  /// ```
  @override
  Future<TransactionResult> transaction<T>(FutureOr<T> Function() action,
      {bool rollbackOnError = true,
      bool? persistRecoveryOnCommit,
      TransactionIsolationLevel? isolation}) {
    return _impl.transaction<T>(action,
        rollbackOnError: rollbackOnError,
        persistRecoveryOnCommit: persistRecoveryOnCommit,
        isolation: isolation);
  }

  /// Get a delete builder to remove records.
  ///
  /// [tableName] The name of the table.
  /// Returns a [DeleteBuilder] to specify conditions and execute deletion.
  ///
  /// Example:
  /// ```dart
  /// await db.delete('users')
  ///         .where('id', '=', 1);
  ///
  /// // To continue on partial errors:
  /// await db.delete('users')
  ///         .where('id', '>', 100)
  ///         .allowPartialErrors();
  /// ```
  ///
  /// 获取删除构建器，用于删除记录。
  ///
  /// [tableName] 表名。
  /// 返回 [DeleteBuilder] 用于指定条件并执行删除。
  @override
  DeleteBuilder delete(String tableName) {
    _checkSystemTableAccess(
        tableName, 'cannot be deleted from manually', 'ToStore.delete');

    return DeleteBuilder(_impl, tableName);
  }

  /// Drop table
  /// [tableName] Table name
  /// Returns [DbResult] to allow graceful error handling for business logic errors
  ///
  /// 删除表
  /// [tableName] 表名
  /// 返回 [DbResult] 方便处理业务逻辑错误
  @override
  Future<DbResult> dropTable(String tableName) async {
    _checkSystemTableAccess(
        tableName, 'cannot be dropped manually', 'ToStore.dropTable');

    return await _impl.dropTable(tableName);
  }

  /// Clear all data in a table.
  ///
  /// [tableName] The name of the table to clear.
  /// Returns a [DbResult] indicating success or failure.
  ///
  /// 清空表数据。
  ///
  /// [tableName] 表名。
  /// 返回 [DbResult] 表示操作成功或失败。
  @override
  Future<DbResult> clear(String tableName) async {
    _checkSystemTableAccess(
        tableName, 'cannot be cleared manually', 'ToStore.clear');

    return await _impl.clear(tableName);
  }

  /// Check if a table has been defined in the current database (space‑agnostic).
  ///
  /// This method only checks whether the table structure exists and can be used,
  /// not whether the table contains any rows.
  ///
  /// [tableName] The name of the table to check.
  /// Returns true if the table structure exists.
  ///
  /// 检查当前数据库中是否已经存在指定表的结构定义（与 Space 无关），仅代表该表可以被使用，
  /// 不代表表中是否已有数据。
  ///
  /// [tableName] 要检查的表名。
  /// 如果表结构存在则返回 true。
  @override
  Future<bool> tableExists(String tableName) async {
    return await _impl.tableExists(tableName);
  }

  /// Get table schema
  /// [tableName] Table name
  /// Returns the [TableSchema] if found, otherwise null.
  ///
  /// 获取表结构
  /// [tableName] 表名
  /// 返回表结构 [TableSchema]，若未找到则返回 null。
  @override
  Future<TableSchema?> getTableSchema(String tableName) async {
    return await _impl.schemaManager?.getTableSchema(tableName);
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
  /// [tableName] The name of the table to retrieve info for.
  /// Returns [TableInfo] containing metadata, or null if not found.
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
  ///
  /// [tableName] 要获取信息的表名。
  /// 返回包含元数据的 [TableInfo]，若未找到则返回 null。
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
  /// Only used for user-defined maintenance, not involved in any database internal logic.
  ///
  /// 获取当前数据库版本号
  /// 仅由用户自定义维护，不参与数据库内部任何逻辑。
  @override
  Future<int> getVersion() async {
    return await _impl.getVersion();
  }

  /// Get the final storage path of the database instance.
  ///
  /// 获取数据库实例最终存储目录的完整路径。
  String? get instancePath => _impl.instancePath;

  /// Set database version number
  /// Only used for user-defined maintenance, not involved in any database internal logic.
  /// [version] New version number to set
  ///
  /// 设置数据库版本号
  /// 仅由用户自定义维护，不参与数据库内部任何逻辑。
  /// [version] 要设置的新版本号
  @override
  Future<void> setVersion(int version) async {
    return await _impl.setVersion(version);
  }

  /// Flush pending writes to disk.
  /// [flushStorage] When true (default), also flush underlying storage buffers.
  ///
  /// 将待落盘的数据刷入磁盘。
  /// [flushStorage] 为 true（默认）时，同时刷新底层存储缓冲区。
  @override
  Future<void> flush({bool flushStorage = true}) async {
    await _impl.flush(flushStorage: flushStorage);
  }

  /// Close database and clean up resources
  /// [keepActiveSpace] When false, clears active space so next launch uses default (e.g. logout). Default true.
  ///
  /// Removes current instance from instance pool
  /// 关闭数据库并清理资源
  /// [keepActiveSpace] 为 false 时清除活跃空间（如退出登录），下次启动将使用 default 空间
  @override
  Future<void> close({bool keepActiveSpace = true}) async {
    await _impl.close(keepActiveSpace: keepActiveSpace);
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
    _checkSystemTableAccess(tableName, 'its schema cannot be modified manually',
        'ToStore.updateSchema');
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
  /// [useCache] Whether to use cached data. Defaults to true. Set to false to get the latest data.
  ///
  /// 获取当前空间的信息
  /// 返回当前工作空间的详细信息
  /// [useCache] 是否使用缓存数据，默认为true。设置为false可获取最新数据。
  @override
  Future<SpaceInfo> getSpaceInfo({bool useCache = true}) async {
    return await _impl.getSpaceInfo(useCache: useCache);
  }

  /// Delete a space
  /// [spaceName] Space name to delete
  /// Cannot delete the default space or the currently active space
  /// Returns [DbResult] to allow graceful error handling for business logic errors
  ///
  /// 删除空间
  /// [spaceName] 要删除的空间名称
  /// 不能删除默认空间或当前活动空间
  /// 返回 [DbResult] 方便处理业务逻辑错误
  @override
  Future<DbResult> deleteSpace(String spaceName) async {
    return await _impl.deleteSpace(spaceName);
  }

  /// List all space names (e.g. for multi-account switch or admin).
  /// Returns sorted list; at least contains 'default'.
  ///
  /// 列出所有空间名称（如多账号切换、管理端）
  /// 返回有序列表，至少包含 'default'
  @override
  Future<List<String>> listSpaces() async {
    return await _impl.listSpaces();
  }

  /// Get unified status and diagnostics
  /// Returns a [DbStatus] object containing memory, space, table, config, and migration status information
  ///
  /// 获取统一的状态和诊断信息
  /// 返回一个 [DbStatus] 对象，包含内存、空间、表、配置和迁移状态信息
  @override
  DbStatus get status => _impl.status;

  /// Key-value storage namespace
  @override
  KvStore get kv => _impl.kv;

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

  /// Check system table access and throw exception if denied
  void _checkSystemTableAccess(String tableName, String action, String label) {
    if (SystemTable.isKnownSystemTable(tableName)) {
      final msg = 'Table $tableName is a system table and $action.';
      Logger.error(msg, label: label);
      throw ArgumentError(msg);
    }
  }
}
