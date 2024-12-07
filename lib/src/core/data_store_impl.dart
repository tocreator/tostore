import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../backup/backup_manager.dart';
import '../handler/common.dart';
import '../handler/logger.dart';
import '../model/table_schema.dart';
import 'data_compressor.dart';
import 'concurrency_manager.dart';
import '../model/data_store_config.dart';
import '../model/base_path_changed_event.dart';
import 'file_manager.dart';
import 'index_manager.dart';
import '../integrity/auto_repair.dart';
import '../model/row_pointer.dart';
import '../model/table_info.dart';
import '../query/query_condition.dart';
import '../query/query_executor.dart';
import '../query/query_optimizer.dart';
import '../statistics/statistics_collector.dart';
import 'transaction_manager.dart';

/// 数据存储引擎
class DataStoreImpl {
  static final Map<String, DataStoreImpl> _instances = {};
  Completer<void> _initCompleter = Completer<void>();
  bool _isInitialized = false;
  bool _initializing = false;
  final String _instanceKey;
  final int _version;
  final Future<void> Function(DataStoreImpl db)? _onConfigure;
  final Future<void> Function(DataStoreImpl db)? _onCreate;
  final Future<void> Function(DataStoreImpl db, int oldVersion, int newVersion)?
      _onUpgrade;
  final Future<void> Function(DataStoreImpl db, int oldVersion, int newVersion)?
      _onDowngrade;
  final Future<void> Function(DataStoreImpl db)? _onOpen;

  bool _baseInitialized = false;

  bool _isSwitchingSpace = false;

  /// 检查是否已初始化
  bool get isInitialized => _isInitialized;

  /// 工厂构造函数,支持多实例
  factory DataStoreImpl({
    String? dbPath,
    DataStoreConfig? config,
    int version = 1,
    Future<void> Function(DataStoreImpl db)? onConfigure,
    Future<void> Function(DataStoreImpl db)? onCreate,
    Future<void> Function(DataStoreImpl db, int oldVersion, int newVersion)?
        onUpgrade,
    Future<void> Function(DataStoreImpl db, int oldVersion, int newVersion)?
        onDowngrade,
    Future<void> Function(DataStoreImpl db)? onOpen,
  }) {
    final key = dbPath ?? 'default';
    if (!_instances.containsKey(key)) {
      final instance = DataStoreImpl._internal(
        key,
        version,
        onConfigure,
        onCreate,
        onUpgrade,
        onDowngrade,
        onOpen,
      );
      _instances[key] = instance;
      instance._startInitialize(dbPath, config);
    }
    return _instances[key]!;
  }

  DataStoreImpl._internal(
    this._instanceKey,
    this._version,
    this._onConfigure,
    this._onCreate,
    this._onUpgrade,
    this._onDowngrade,
    this._onOpen,
  );

  /// 开始初始化
  void _startInitialize(String? dbPath, DataStoreConfig? config) {
    if (_initializing || _isInitialized) {
      return;
    }

    // 创建新的 Completer
    _initCompleter = Completer<void>();

    // 开始初始化流程
    initialize(dbPath: dbPath, config: config).then((_) {
      // 初始化完成后完成 Completer
      if (!_initCompleter.isCompleted) {
        _initCompleter.complete();
      }
    }).catchError((e) {
      // 初始化失败时完成 Completer 的错误
      if (!_initCompleter.isCompleted) {
        _initCompleter.completeError(e);
      }
      _initializing = false;
    });
  }

  /// 获取数据库的版本号
  Future<int> getVersion() async {
    try {
      final versionFile = File('${config.dbPath}/version');
      if (!await versionFile.exists()) {
        return 0;
      }
      return int.parse(await versionFile.readAsString());
    } catch (e) {
      return 0;
    }
  }

  /// 设置数据库版本号
  Future<void> setVersion(int version) async {
    final versionFile = File('${config.dbPath}/version');
    await versionFile.writeAsString(version.toString());
  }

  /// 确保初始化完成
  Future<void> _ensureInitialized() async {
    if (!_isInitialized) {
      if (!_initCompleter.isCompleted) {
        await _initCompleter.future;
      }
    }
  }

  String _currentSpaceName = 'default';
  DataStoreConfig? _config;

  TransactionManager? _transactionManager;
  IndexManager? _indexManager;
  ConcurrencyManager? _concurrencyManager;
  QueryOptimizer? _queryOptimizer;
  QueryExecutor? _queryExecutor;
  StatisticsCollector? _statisticsCollector;

  // 添加唯一值缓存
  final Map<String, Map<String, Set<dynamic>>> _uniqueValuesCache = {};

  FileManager? _fileManager;
  FileManager get fileManager {
    if (_fileManager == null) {
      throw StateError('FileManager not initialized');
    }
    return _fileManager!;
  }

  /// 获取当前基础空间名
  String get currentBaseSpaceName => _currentSpaceName;

  /// 获取当前配置
  DataStoreConfig get config {
    if (_config == null) {
      throw StateError('DataStore not initialized');
    }
    return _config!;
  }

  /// 获取数据库路径
  Future<String> getDatabasePath({String? dbPath}) async {
    if (_config != null && isInitialized) {
      return _config!.dbPath;
    } else if (dbPath != null) {
      return "$dbPath/db";
    }
    final appPath = await getPathApp();
    return "$appPath/db";
  }

  /// 获取表路径
  Future<String> getTablePath(String tableName) async {
    final schema = await getTableSchema(tableName);

    return config.getTablePath(tableName, schema.isGlobal);
  }

  /// 获取表路径(同步版本)
  String getTablePathSync(String tableName, {bool isGlobal = false}) {
    // 只能从缓存获取
    final schema = _queryExecutor?.queryCacheManager.getSchema(tableName);
    return config.getTablePath(tableName, schema?.isGlobal ?? isGlobal);
  }

  /// 初始化数据存储引擎
  Future<bool> initialize({String? dbPath, DataStoreConfig? config}) async {
    // 如果已经在初始化中,等待初始化完成
    if (_initializing && !_initCompleter.isCompleted) {
      await _initCompleter.future;
      return true;
    }

    // 如果已经初始化完成且参数相同,直接返回
    if (_isInitialized && dbPath == _config?.dbPath && config == _config) {
      return true;
    }

    _initializing = true;

    try {
      // 如果已初始化,先关闭现有实例
      if (_config != null) {
        await close();
      }

      dbPath = await getDatabasePath(dbPath: dbPath);

      _config = config ?? DataStoreConfig(dbPath: dbPath);
      _concurrencyManager = ConcurrencyManager();
      _transactionManager = TransactionManager(this);
      _indexManager = IndexManager(this);
      _statisticsCollector = StatisticsCollector(this);
      _fileManager = FileManager(this);
      _fileManager?.startTimer();

      await Directory(dbPath).create(recursive: true);

      _queryOptimizer = QueryOptimizer(
        this,
      );
      _queryExecutor = QueryExecutor(
        this,
        _indexManager!,
      );

      // 恢复未完成的事务
      await _recoveryIncompleteTransactions();

      await _loadDataToCache();

      // 标记基础初始化完成
      _baseInitialized = true;

      // 执行表创建和升级
      await _startSetupAndUpgrade();

      // 标记完全初始化完成
      _isInitialized = true;
      if (!_initCompleter.isCompleted) {
        _initCompleter.complete();
      }

      return true;
    } catch (e) {
      _isInitialized = false;
      if (!_initCompleter.isCompleted) {
        _initCompleter.completeError(e);
      }
      Logger.error('数据库初始化失败: $e', label: 'DataStore.initialize');
      rethrow;
    } finally {
      _initializing = false;
    }
  }

  /// 开始创建表及升级
  Future<void> _startSetupAndUpgrade() async {
    try {
      // 配置数据库
      await _onConfigure?.call(this);

      final oldVersion = await getVersion();

      // 首次创建或切换基础空间时创建表
      if (oldVersion == 0 || _isSwitchingSpace) {
        // 创建基础空间键值表
        await createTable(
          _kvStoreName,
          const TableSchema(
            primaryKey: 'key',
            fields: [
              FieldSchema(name: 'key', type: DataType.text, nullable: false),
              FieldSchema(name: 'value', type: DataType.text),
              FieldSchema(name: 'updated_at', type: DataType.datetime),
            ],
            indexes: [
              IndexSchema(fields: ['updated_at']),
            ],
          ),
        );

        // 创建全局键值表
        await createTable(
          _globalKvStoreName,
          const TableSchema(
            primaryKey: 'key',
            isGlobal: true,
            fields: [
              FieldSchema(name: 'key', type: DataType.text, nullable: false),
              FieldSchema(name: 'value', type: DataType.text),
              FieldSchema(name: 'updated_at', type: DataType.datetime),
            ],
            indexes: [
              IndexSchema(fields: ['updated_at']),
            ],
          ),
        );

        await _onCreate?.call(this);

        if (oldVersion == 0) {
          await setVersion(_version);
        }
      } else if (oldVersion < _version) {
        // 需要升级
        await _onUpgrade?.call(this, oldVersion, _version);
        await setVersion(_version);
      } else if (oldVersion > _version) {
        // 需要降级
        await _onDowngrade?.call(this, oldVersion, _version);
        await setVersion(_version);
      }

      // 数据库打开完成
      await _onOpen?.call(this);
    } catch (e) {
      Logger.error('数据库设置或升级失败: $e', label: 'DataStore._startSetupAndUpgrade');
    }
  }

  /// 关闭数据库
  Future<void> close() async {
    try {
      await _fileManager?.dispose();

      if (_maxIdsDirty.values.any((isDirty) => isDirty)) {
        await _flushMaxIds();
      }

      await _indexManager?.flushIndexes();
      _indexManager?.dispose();

      _queryExecutor?.queryCacheManager.clear();

      await _transactionManager?.commit(null);

      _transactionManager = null;
      _indexManager = null;
      _concurrencyManager = null;
      _queryOptimizer = null;
      _queryExecutor = null;
      _statisticsCollector = null;
      _config = null;

      _maxIds.clear();
      _maxIdsDirty.clear();

      _isInitialized = false;
      _initializing = false;
      _initCompleter = Completer<void>();

      _instances.remove(_instanceKey);

      _fileManager = null;

      Logger.info('数据库实例已关闭: $_instanceKey', label: 'DataStoreImpl.close');
    } catch (e) {
      Logger.error('数据库关闭失败: $e', label: 'DataStore.close');
      rethrow;
    }
  }

  /// 创建表
  Future<void> createTable(
    String tableName,
    TableSchema schema,
  ) async {
    if (!_baseInitialized) {
      await _ensureInitialized();
    }

    try {
      // 1. 检查全局路径和基础路径
      final globalPath = config.getTablePath(tableName, true);
      final basePath = config.getTablePath(tableName, false);
      final globalSchemaFile = File('$globalPath.schema');
      final baseSchemaFile = File('$basePath.schema');

      if (await globalSchemaFile.exists()) {
        Logger.warn('表 $tableName 在全局空间已存在', label: 'DataStore.createTable');
        return;
      }
      if (await baseSchemaFile.exists()) {
        Logger.warn('表 $tableName 在基础空间已存在', label: 'DataStore.createTable');
        return;
      }

      // 2. 创建目标目录
      final isGlobal = schema.isGlobal;
      final targetPath =
          isGlobal ? config.getGlobalPath() : config.getBasePath();
      final targetDir = Directory(targetPath);
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }

      // 3. 获取目标表路径
      final dataFile = File('$targetPath.dat');
      final schemaFile = File('$targetPath.schema');

      await _concurrencyManager!.acquireWriteLock(tableName);
      try {
        // 4. 验证表结构
        _validateSchema(schema);

        // 5. 创建新的表文件
        await dataFile.create(recursive: true);
        await schemaFile.writeAsString(jsonEncode(schema));

        // 6. 创建主键索引
        await _indexManager?.createPrimaryIndex(tableName, schema.primaryKey);

        // 7. 创建其他索引
        for (var index in schema.indexes) {
          await _indexManager?.createIndex(tableName, index);
        }

        Logger.info('表 $tableName 创建成功');
      } finally {
        await _concurrencyManager!.releaseWriteLock(tableName);
      }

      // 8. 缓存新创建的表结构
      _queryExecutor?.queryCacheManager.cacheSchema(tableName, schema);
    } catch (e) {
      Logger.error('创建表失败: $e', label: 'DataStore.createTable');
      rethrow;
    }
  }

  /// 插入数据的完整流程
  Future<bool> insert(String tableName, Map<String, dynamic> data) async {
    // 需要完全初始化
    if (!_isInitialized) {
      await _ensureInitialized();
    }

    // 1. 事务和锁
    final transaction = await _transactionManager!.beginTransaction();
    await _concurrencyManager!.acquireWriteLock(tableName);

    try {
      // 2. 数据验证
      final schema = await getTableSchema(tableName);
      final validData = await _validateAndProcessData(schema, data, tableName);
      if (validData == null) {
        return false;
      }

      // 3. 唯一性检查
      if (!await _checkUniqueConstraints(tableName, validData)) {
        return false;
      }

      // 4. 更新缓存
      _queryExecutor?.queryCacheManager.addCachedRecord(tableName, validData);

      // 5. 添加到写入队列(插入操作)
      fileManager.addToWriteQueue(tableName, validData, isUpdate: false);

      // 6. 提交事务
      await _transactionManager!.commit(transaction);
      return true;
    } catch (e) {
      Logger.error('插入失败: $e', label: 'DataStore.insert');
      await _rollbackTransaction(transaction, tableName, data);
      return false;
    } finally {
      await _concurrencyManager!.releaseWriteLock(tableName);
    }
  }

  /// 事务回滚
  Future<void> _rollbackTransaction(
    Transaction? transaction,
    String tableName,
    Map<String, dynamic> data,
  ) async {
    try {
      // 1. 回滚事务
      await _transactionManager!.rollback(transaction);

      // 2. 从缓存中删除
      final schema = await getTableSchema(tableName);
      final primaryKeyField = schema.primaryKey;
      final primaryKeyValue = data[primaryKeyField];

      _queryExecutor?.queryCacheManager.removeCachedRecord(
        tableName,
        primaryKeyValue.toString(),
      );

      // 3. 从写入队列中删除
      final queue = fileManager.writeQueue[tableName];
      if (queue != null) {
        queue.removeWhere(
            (record) => record[primaryKeyField] == primaryKeyValue);
      }

      // 4. 从文件中删除最后一条记录（如果已写入）
      final dataFile = File(config.getDataPath(tableName, schema.isGlobal));
      if (await dataFile.exists()) {
        final lines = await dataFile.readAsLines();
        if (lines.isNotEmpty) {
          final lastLine = lines.last;
          try {
            final lastRecord = jsonDecode(lastLine) as Map<String, dynamic>;
            if (lastRecord[primaryKeyField] == primaryKeyValue) {
              lines.removeLast();
              await dataFile.writeAsString('${lines.join('\n')}\n');
            }
          } catch (e) {
            Logger.error('解析最后一条记录失败: $e',
                label: 'DataStore._rollbackTransaction');
          }
        }
      }

      // 5. 回滚索引
      await _indexManager?.deleteFromIndexes(tableName, data);

      Logger.info('事务回滚成功');
    } catch (e) {
      Logger.error('事务回滚失败: $e', label: 'DataStore._rollbackTransaction');
      _queryExecutor?.queryCacheManager.invalidateCache(tableName);
      rethrow;
    }
  }

  /// 验证和处理数据
  Future<Map<String, dynamic>?> _validateAndProcessData(
    TableSchema schema,
    Map<String, dynamic> data,
    String tableName,
  ) async {
    try {
      final result = Map<String, dynamic>.from(data);
      final primaryKey = schema.primaryKey;

      // 1. 处理自增主键
      if (!result.containsKey(primaryKey) || result[primaryKey] == null) {
        if (schema.autoIncrement) {
          result[primaryKey] = await _getNextId(tableName);
        }
      } else {
        final providedId = result[primaryKey];
        if (providedId is int && schema.autoIncrement) {
          _updateMaxIdInMemory(tableName, providedId);
        }
      }

      // 2. 填充默认值和空值
      for (var field in schema.fields) {
        if (!result.containsKey(field.name)) {
          if (field.defaultValue != null) {
            result[field.name] = field.defaultValue;
          } else if (!field.nullable) {
            result[field.name] = _getTypeDefaultValue(field.type);
          } else {
            result[field.name] = null;
          }
        }

        final value = result[field.name];

        // 检查非空约束
        if (!field.nullable && value == null) {
          Logger.warn('警告: 字段 ${field.name} 不能为空');
          return null;
        }

        // 检查数据类型
        if (value != null && !_isValidDataType(value, field.type)) {
          Logger.warn('警告: 字段 ${field.name} 的值类型不正确');
          return null;
        }

        // 检查最大长度
        if (value != null && field.maxLength != null) {
          if (value is String && value.length > field.maxLength!) {
            Logger.warn('警告: 字段 ${field.name} 超出最大长度');
            return null;
          }
        }
      }

      return result;
    } catch (e) {
      Logger.error('数据验证失败: $e', label: 'DataStore-_validateAndProcessData');
      return null;
    }
  }

  /// 获取类型默认值
  dynamic _getTypeDefaultValue(DataType type) {
    switch (type) {
      case DataType.integer:
        return 0;
      case DataType.double:
        return 0.0;
      case DataType.text:
        return '';
      case DataType.boolean:
        return false;
      case DataType.datetime:
        return DateTime.now();
      case DataType.blob:
        return Uint8List(0);
    }
  }

  /// 检数据类型是否有效
  bool _isValidDataType(dynamic value, DataType type) {
    if (value == null) return true;
    switch (type) {
      case DataType.integer:
        return value is int || (value is String && int.tryParse(value) != null);
      case DataType.double:
        return value is double ||
            value is int ||
            (value is String && double.tryParse(value) != null);
      case DataType.text:
        return value is String;
      case DataType.blob:
        return value is List<int>;
      case DataType.boolean:
        return value is bool ||
            (value is String &&
                (value.toLowerCase() == 'true' ||
                    value.toLowerCase() == 'false'));
      case DataType.datetime:
        return value is DateTime ||
            (value is String && DateTime.tryParse(value) != null);
    }
  }

  /// Map方式查询数据
  Future<List<Map<String, dynamic>>> queryByMap(
    String tableName, {
    Map<String, dynamic>? where,
    List<String>? orderBy,
    int? limit,
    int? offset,
  }) async {
    await _ensureInitialized();

    try {
      // 将 Map 条件转换为 QueryCondition
      final condition = _convertMapToCondition(where);

      // 构建查询计划
      final queryPlan = await _queryOptimizer?.optimize(
        tableName,
        where ?? {},
        orderBy,
      );

      if (queryPlan == null) {
        throw StateError('Query optimizer not initialized');
      }

      // 使用 QueryExecutor 执行查询
      final results = await _queryExecutor?.execute(
            queryPlan,
            tableName,
            condition: condition,
            orderBy: orderBy,
            limit: limit,
            offset: offset,
          ) ??
          [];

      return results;
    } catch (e) {
      Logger.error('查询失败: $e', label: 'DataStore.queryByMap');
      rethrow;
    }
  }

  /// 将 Map 条件转换为 QueryCondition
  QueryCondition _convertMapToCondition(Map<String, dynamic>? where) {
    if (where == null || where.isEmpty) {
      return QueryCondition();
    }

    final condition = QueryCondition();

    // 处理 OR 条件
    if (where.containsKey('OR')) {
      final orGroups = where['OR'] as List<Map<String, dynamic>>;
      for (var group in orGroups) {
        // 添加第一组条件
        for (var entry in group.entries) {
          _addCondition(condition, entry.key, entry.value);
        }
        // 后续组使用 OR
        if (group != orGroups.last) {
          condition.or();
        }
      }
    } else {
      // 处理普通 AND 条件
      for (var entry in where.entries) {
        _addCondition(condition, entry.key, entry.value);
      }
    }

    return condition;
  }

  /// 添加单个条件
  void _addCondition(QueryCondition condition, String field, dynamic value) {
    if (value == null) {
      condition.where(field, 'IS', null);
      return;
    }

    if (value is Map) {
      final operator = value.keys.first.toString().toUpperCase();
      final compareValue = value.values.first;

      switch (operator) {
        case 'IN':
        case 'NOT IN':
          if (compareValue is! List) {
            Logger.warn('IN/NOT IN 操作符需要 List 类型的值',
                label: 'DataStore._addCondition');
            return;
          }
          condition.where(field, operator, compareValue);
          break;

        case 'BETWEEN':
          if (compareValue is! Map ||
              !compareValue.containsKey('start') ||
              !compareValue.containsKey('end')) {
            Logger.warn('BETWEEN 操作符需要包含 start 和 end 的 Map',
                label: 'DataStore._addCondition');
            return;
          }
          condition.where(
              field, 'BETWEEN', [compareValue['start'], compareValue['end']]);
          break;

        case 'LIKE':
        case 'NOT LIKE':
          if (compareValue is! String) {
            Logger.warn('LIKE/NOT LIKE 操作符需要字符串类型的值',
                label: 'DataStore._addCondition');
            return;
          }
          condition.where(field, operator, compareValue);
          break;

        case 'IS':
        case 'IS NOT':
          condition.where(field, operator, null);
          break;

        default:
          // 处理其他操作符 (>, <, >=, <=, !=)
          condition.where(field, operator, compareValue);
          break;
      }
    } else {
      // 简单相等条件
      condition.where(field, '=', value);
    }
  }

  Future<void> _recoveryIncompleteTransactions() async {
    final transactions = await _loadIncompleteTransactions();
    for (final transaction in transactions) {
      if (transaction.isExpired) {
        await rollback(transaction);
      } else {
        await _applyChanges(transaction);
      }
    }
  }

  Future<List<Transaction>> _loadIncompleteTransactions() async {
    // 实现从事务日志加载未完成的事务
    return [];
  }

  /// 验证表结构
  void _validateSchema(TableSchema schema) {
    // 检查主键
    if (schema.primaryKey.isEmpty) {
      throw ArgumentError('Primary key cannot be empty');
    }

    // 检查字段定义
    if (schema.fields.isEmpty) {
      throw ArgumentError('Table must have at least one field');
    }

    // 检查主键字段是否存在
    if (!schema.fields.any((col) => col.name == schema.primaryKey)) {
      throw ArgumentError('Primary key field not found in fields');
    }

    // 检查字段名是否唯一
    final fieldNames = schema.fields.map((col) => col.name).toSet();
    if (fieldNames.length != schema.fields.length) {
      throw ArgumentError('Field names must be unique');
    }

    // 检查索引字段是否存在
    for (var index in schema.indexes) {
      for (var field in index.fields) {
        if (!fieldNames.contains(field)) {
          throw ArgumentError('Index field $field not found in table fields');
        }
      }
    }
  }

  /// 计算校验和
  String _calculateChecksum(Uint8List data) {
    final compressor = DataCompressor();
    return compressor.calculateChecksum(data).toString();
  }

  /// 回滚事务
  Future<void> rollback(Transaction transaction) async {
    await _transactionManager!.rollback(transaction);
  }

  /// 应用事务变更
  Future<void> _applyChanges(Transaction transaction) async {
    await _transactionManager!.commit(transaction);
  }

  /// 验证数据完整性
  Future<bool> _verifyDataIntegrity(String tableName) async {
    final tablePath = getTablePath(tableName);
    final dataFile = File('$tablePath.dat');
    final checksumFile = File('$tablePath.checksum');

    if (!await dataFile.exists() || !await checksumFile.exists()) {
      return false;
    }

    final data = await dataFile.readAsBytes();
    final storedChecksum = await checksumFile.readAsString();
    final actualChecksum = _calculateChecksum(data);

    return storedChecksum.trim() == actualChecksum;
  }

  /// 修复数据
  Future<void> _repairData(String tableName) async {
    // 使用自动修复器修复数据
    final autoRepair = AutoRepair(
      this,
      _indexManager!,
      BackupManager(this),
    );
    await autoRepair.repairTableStructure(tableName);
  }

  /// 备份数据返回备份路径
  Future<String> backup() async {
    try {
      // 1. 先刷新所有待写入的数据
      await fileManager.flushWriteQueue();

      // 2. 创建备份管理器
      final backupManager = BackupManager(this);

      // 3. 创建备份
      final backupPath = await backupManager.createBackup();
      Logger.info('备份创建成功: $backupPath');
      return backupPath;
    } catch (e) {
      Logger.error('创建备份失败: $e', label: 'DataStore-backup');
      rethrow;
    }
  }

  /// 从备份恢复
  Future<bool> restore(String backupPath) async {
    try {
      // 1. 创建备份管理器
      final backupManager = BackupManager(this);

      // 2. 加载备份数据
      final backupData = await backupManager.loadBackup(backupPath);

      // 3. 获取实际的数据部分
      final data = backupData['data'] as Map<String, dynamic>;
      if (data.isEmpty) {
        Logger.error('备份数据为空', label: 'DataStore-restore');
        return false;
      }

      // 4. 清理现有数据
      final dbDir = Directory(_config!.getBasePath());
      if (await dbDir.exists()) {
        await dbDir.delete(recursive: true);
      }
      await dbDir.create();

      // 5. 恢复每个表的数据
      for (var entry in data.entries) {
        final tableName = entry.key;
        final tableData = entry.value as Map<String, dynamic>;

        // 恢复schema
        final schema =
            TableSchema.fromJson(tableData['schema'] as Map<String, dynamic>);
        await createTable(tableName, schema);

        // 恢复数据
        final records =
            (tableData['data'] as List).cast<Map<String, dynamic>>();

        // 写入数据文件
        final dataFile = File(_config!.getDataPath(tableName, schema.isGlobal));
        final sink = dataFile.openWrite(mode: FileMode.append);
        await _indexManager?.resetIndexes(tableName);
        var startOffset = await dataFile.length();
        try {
          for (var record in records) {
            sink.writeln(jsonEncode(record));
            _queryExecutor?.queryCacheManager
                .addCachedRecord(tableName, record);
            final encoded = jsonEncode(record);
            startOffset += encoded.length + 1;
            final pointer = await RowPointer.create(
              encoded,
              startOffset,
            );
            await _indexManager?.updateIndexes(tableName, record, pointer);
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
      }

      Logger.info('从备份恢复成功');
      return true;
    } catch (e) {
      Logger.error('从备份恢复失败: $e', label: 'DataStore-restore');
      return false;
    }
  }

  /// 更新统计信息
  Future<void> updateStatistics(String tableName) async {
    await _statisticsCollector!.collectTableStatistics(tableName);
  }

  /// 获取查询计划
  Future<String> explainQuery(
    String tableName, {
    Map<String, dynamic>? where,
    List<String>? orderBy,
  }) async {
    final queryPlan = await _queryOptimizer!.optimize(
      tableName,
      where,
      orderBy,
    );
    return queryPlan.explain();
  }

  /// 验证和处理更新数据
  Future<Map<String, dynamic>?> _validateAndProcessUpdateData(
    TableSchema schema,
    Map<String, dynamic> data,
    String tableName,
  ) async {
    try {
      final result = Map<String, dynamic>.from(data);

      // 移除主键字段(如果存在)
      result.remove(schema.primaryKey);

      // 检查数据类型
      for (var entry in result.entries) {
        final field = schema.fields.firstWhere(
          (col) => col.name == entry.key,
          orElse: () => throw StateError('未知字段 ${entry.key}'),
        );

        if (entry.value != null && !_isValidDataType(entry.value, field.type)) {
          Logger.warn('警告: 字段 ${entry.key} 的值类型不正确');
          return null;
        }
      }

      return result;
    } catch (e) {
      Logger.error('更新数据验证失败: $e',
          label: 'DataStore-_validateAndProcessUpdateData');
      return null;
    }
  }

  /// 更新记录
  Future<bool> updateInternal(
    String tableName,
    Map<String, dynamic> data,
    QueryCondition condition,
  ) async {
    await _ensureInitialized();
    final transaction = await _transactionManager!.beginTransaction();
    await _concurrencyManager!.acquireWriteLock(tableName);

    try {
      // 验证数据
      final schema = await getTableSchema(tableName);
      final validData =
          await _validateAndProcessUpdateData(schema, data, tableName);
      if (validData == null || validData.isEmpty) {
        return false;
      }

      // 查找匹配的记录
      final records = await _executeQuery(tableName, condition);
      if (records.isEmpty) {
        return false;
      }

      // 检查唯一性约束
      for (var record in records) {
        // 合并更新数据
        final updatedRecord = Map<String, dynamic>.from(record)
          ..addAll(validData);

        // 检查字段的唯一性约束
        for (var field in schema.fields) {
          if (field.unique && validData.containsKey(field.name)) {
            final value = validData[field.name];
            // 查找是否有其他记录已经使用了这个值
            final existing = await _executeQuery(
                tableName,
                QueryCondition()
                  ..where(field.name, '=', value)
                  ..where(schema.primaryKey, '!=', record[schema.primaryKey]));
            if (existing.isNotEmpty) {
              Logger.warn('警告: 字段 ${field.name} 的值 $value 已存在');
              return false;
            }
          }
        }

        // 检查索引的唯一性约束
        for (var index in schema.indexes.where((idx) => idx.unique)) {
          // 如果更新涉及索引字段
          if (index.fields.any((col) => validData.containsKey(col))) {
            final indexValues = Map<String, dynamic>.from(record);
            indexValues.addAll(validData);

            // 构建唯一索引的查询条件
            final condition = QueryCondition();
            for (var col in index.fields) {
              condition.where(col, '=', indexValues[col]);
            }
            condition.where(
                schema.primaryKey, '!=', record[schema.primaryKey]); // 排除当前记录

            final existing = await _executeQuery(tableName, condition);
            if (existing.isNotEmpty) {
              Logger.warn(
                  '警告: 唯一索引 ${index.actualIndexName} 的值 ${record[schema.primaryKey]} 已存在');
              return false;
            }
          }
        }

        // 更新缓存和写入队列、索引
        _queryExecutor?.queryCacheManager.removeCachedRecord(
            tableName, record[schema.primaryKey].toString());
        _queryExecutor?.queryCacheManager
            .addCachedRecord(tableName, updatedRecord);

        // 更新写入队列
        fileManager.addToWriteQueue(tableName, updatedRecord, isUpdate: true);
      }

      // 提交事务
      await _transactionManager!.commit(transaction);

      // 使受影响记录的相关查询缓存失效
      final affectedPrimaryKeys =
          records.map((r) => r[schema.primaryKey]).toSet();
      await _queryExecutor?.invalidateRecords(tableName, affectedPrimaryKeys);

      return true;
    } catch (e) {
      Logger.error('更新失败: $e', label: 'DataStore-update');
      await _transactionManager!.rollback(transaction);
      rethrow;
    } finally {
      await _concurrencyManager!.releaseWriteLock(tableName);
    }
  }

  /// 清空表
  Future<void> clear(String tableName) async {
    final transaction = await _transactionManager!.beginTransaction();
    await _concurrencyManager!.acquireWriteLock(tableName);
    try {
      // 清空文件
      final tablePath = getTablePath(tableName);
      final dataFile = File('$tablePath.dat');
      if (await dataFile.exists()) {
        await dataFile.writeAsString('');
      }

      // 清空记录缓存
      _queryExecutor?.queryCacheManager.invalidateCache(tableName);

      // 清空写入队列
      fileManager.writeQueue.remove(tableName);

      // 重置索引
      await _indexManager?.resetIndexes(tableName);

      // 清理唯一值缓存
      _uniqueValuesCache.remove(tableName);

      // 清理统计信息
      _statisticsCollector?.invalidateCache(tableName);

      await _transactionManager!.commit(transaction);
    } catch (e) {
      Logger.info('清空表失败: $e', label: 'DataStore-clear');
      await _transactionManager!.rollback(transaction);
      rethrow;
    } finally {
      await _concurrencyManager!.releaseWriteLock(tableName);
    }
  }

  /// 删除记录
  Future<bool> deleteInternal(
    String tableName,
    QueryCondition condition,
  ) async {
    final transaction = await _transactionManager!.beginTransaction();
    await _concurrencyManager!.acquireWriteLock(tableName);

    try {
      // 先找出要删除的记录
      final recordsToDelete = await _executeQuery(tableName, condition);

      if (recordsToDelete.isEmpty) {
        return true;
      }

      final schema = await getTableSchema(tableName);
      final primaryKey = schema.primaryKey;
      final queue = fileManager.writeQueue[tableName];

      for (var record in recordsToDelete) {
        // 从记录缓存中移除
        _queryExecutor?.queryCacheManager
            .removeCachedRecord(tableName, record[primaryKey].toString());

        // 使相关查询缓存失效
        _queryExecutor?.invalidateRecord(tableName, record[primaryKey]);

        queue?.removeWhere(
            (r) => r[schema.primaryKey] == record[schema.primaryKey]);

        await _indexManager!.deleteFromIndexes(tableName, record);
      }

      // 从文件中删除
      final dataFile = File('${getTablePath(tableName)}.dat');
      if (await dataFile.exists()) {
        final lines = await dataFile.readAsLines();
        final remainingLines = lines.where((line) {
          if (line.trim().isEmpty) return true;
          final record = jsonDecode(line) as Map<String, dynamic>;
          // 使用主键来判断是否需要删除
          return !recordsToDelete
              .any((r) => r[schema.primaryKey] == record[schema.primaryKey]);
        }).toList();

        await dataFile.writeAsString('${remainingLines.join('\n')}\n');
      }

      // 更新统计信息
      await _statisticsCollector?.collectTableStatistics(tableName);

      await _transactionManager!.commit(transaction);
    } catch (e) {
      Logger.info('删除失败: $e', label: 'DataStore-delete');
      await _transactionManager!.rollback(transaction);
      // 清理缓存，确保数据一致性
      return false;
    } finally {
      await _concurrencyManager!.releaseWriteLock(tableName);
    }

    return true;
  }

  /// 删除表
  Future<void> dropTable(String tableName) async {
    try {
      await _concurrencyManager!.acquireWriteLock(tableName);

      // 删除数据文件
      final tablePath = getTablePath(tableName);
      final dataFile = File('$tablePath.dat');
      if (await dataFile.exists()) {
        await dataFile.delete();
      }

      // 删除模式文件
      final schemaFile = File('$tablePath.schema');
      if (await schemaFile.exists()) {
        await schemaFile.delete();

        // 删除索引文件
        final schema = await getTableSchema(tableName);
        for (var index in schema.indexes) {
          final indexFile = File(
              '${_config!.getTablePath(tableName, schema.isGlobal)}_${index.actualIndexName}.idx');
          if (await indexFile.exists()) {
            await indexFile.delete();
          }
        }
      }

      // 清理所有相关缓存
      _queryExecutor?.queryCacheManager.invalidateCache(tableName);
      _queryExecutor?.invalidateCache(tableName);
      _statisticsCollector?.invalidateCache(tableName);
    } catch (e) {
      Logger.error('删除表失败: $e', label: 'DataStore-dropTable');
      rethrow;
    } finally {
      await _concurrencyManager!.releaseWriteLock(tableName);
    }
  }

  /// 获取表结构
  Future<TableSchema> getTableSchema(String tableName) async {
    // 1. 先从缓存获取
    final cachedSchema = _queryExecutor?.queryCacheManager.getSchema(tableName);
    if (cachedSchema != null) {
      return cachedSchema;
    }

    // 2. 从文件加载
    // 先尝试从全局空间获取数据结构文件是否存在，如果不存在则从基础空间获取
    var schemaPath = config.getSchemaPath(tableName, true);
    var schemaFile = File(schemaPath);
    if (!await schemaFile.exists()) {
      schemaPath = config.getSchemaPath(tableName, false);
      schemaFile = File(schemaPath);
      if (!await schemaFile.exists()) {
        throw StateError('Table schema not found: $tableName');
      }
    }

    try {
      final schemaJson = await schemaFile.readAsString();
      final schema = TableSchema.fromJson(jsonDecode(schemaJson));

      // 3. 缓存并返回
      _queryExecutor?.queryCacheManager.cacheSchema(tableName, schema);
      return schema;
    } catch (e) {
      Logger.error('加载表结构失败: $e', label: 'DataStore.getTableSchema');
      rethrow;
    }
  }

  /// 验证数据完整性
  Future<bool> verifyIntegrity(String tableName) async {
    return _verifyDataIntegrity(tableName);
  }

  /// 修复数据
  Future<void> repair(String tableName) async {
    await _repairData(tableName);
  }

  /// 批量插入数据
  Future<bool> batchInsert(
      String tableName, List<Map<String, dynamic>> records) async {
    await _ensureInitialized();

    try {
      await _concurrencyManager!.acquireWriteLock(tableName);

      // 1. 获取表结构和验证数据
      final schema = await getTableSchema(tableName);
      final validRecords = <Map<String, dynamic>>[];

      for (var record in records) {
        final validData =
            await _validateAndProcessData(schema, record, tableName);
        if (validData != null) {
          validRecords.add(validData);
        }
      }

      if (validRecords.isEmpty) {
        return false;
      }

      // 2. 检查唯一性约束并过滤重复数据
      final uniqueRecords = <Map<String, dynamic>>[];
      for (var record in validRecords) {
        if (await _checkUniqueConstraints(tableName, record)) {
          uniqueRecords.add(record);
        } else {
          Logger.warn('跳过重复数据: $record', label: 'DataStore-batchInsert');
        }
      }

      if (uniqueRecords.isEmpty) {
        Logger.warn('所有数据都重复,批量插入取消', label: 'DataStore-batchInsert');
        return false;
      }

      // 3. 获取待写入队列中的数据(如果有)
      final pendingData = fileManager.writeQueue[tableName] ?? [];
      fileManager.writeQueue.remove(tableName); // 清空队列

      // 4. 合并所有要写入的数据
      final allData = [...pendingData, ...uniqueRecords];

      // 5. 写入文件、缓存和索引
      final dataFile = File(config.getDataPath(tableName, schema.isGlobal));
      final sink = dataFile.openWrite(mode: FileMode.append);
      try {
        for (var data in allData) {
          sink.writeln(jsonEncode(data));
          _queryExecutor?.queryCacheManager.addCachedRecord(tableName, data);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      // 6. 异步更新信息
      _updateStatisticsAsync(tableName);

      // 7. 异步记录事务日志
      _logTransactionAsync('batchInsert', tableName, {
        'count': allData.length,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });

      return true;
    } catch (e) {
      Logger.error('批量插入失败: $e', label: 'DataStore-batchInsert');
      return false;
    } finally {
      await _concurrencyManager!.releaseWriteLock(tableName);
    }
  }

  /// 异步更新统计信息
  void _updateStatisticsAsync(String tableName) {
    Future(() async {
      try {
        await _statisticsCollector?.collectTableStatistics(tableName);
      } catch (e) {
        Logger.error('异步更新统计信息失败: $e', label: 'DataStore-batchInsert');
      }
    });
  }

  /// 异步记录事务日志
  void _logTransactionAsync(String operation, String tableName, dynamic data) {
    Future(() async {
      try {
        await _transactionManager?.logOperation(operation, tableName, data);
      } catch (e) {
        Logger.error('异步记录事务日志失败: $e', label: 'DataStore-batchInsert');
      }
    });
  }

  /// 同步锁包装方法
  Future<T> synchronized<T>(Object lock, Future<T> Function() callback) async {
    try {
      await _concurrencyManager?.acquireWriteLock('global');
      return await callback();
    } finally {
      await _concurrencyManager?.releaseWriteLock('global');
    }
  }

  /// 加载数据到缓存
  Future<void> _loadDataToCache() async {
    try {
      // 1. 加载基础空间数据
      final baseDir = Directory(_config!.getBasePath());
      if (await baseDir.exists()) {
        await _loadPathData(baseDir);
      }

      // 2. 加载全局空间数据
      final globalDir = Directory(_config!.getGlobalPath());
      if (await globalDir.exists()) {
        await _loadPathData(globalDir);
      }
    } catch (e) {
      Logger.error('加载数据到缓存失败: $e', label: 'DataStore._loadDataToCache');
    }
  }

  /// 加载指定路径下的数据
  Future<void> _loadPathData(Directory dir) async {
    final files = await dir
        .list()
        .where((f) => f.path.endsWith('.dat'))
        .map((f) => File(f.path))
        .toList();

    for (var file in files) {
      try {
        final tableName = _getFileName(file.path);
        final schema = await getTableSchema(tableName);

        // 获取文件大小
        final fileSize = await file.length();

        // 只缓存小文件
        if (fileSize <= _config!.maxTableCacheSize) {
          // 使用公开的常量
          final records = await _loadAllRecords(file);
          await _queryExecutor?.queryCacheManager.cacheEntireTable(
            tableName,
            records,
            schema.primaryKey,
          );

          Logger.info('表 $tableName 已完整加载到缓存');
        } else {
          await _loadRecentRecords(file, tableName, schema);
          Logger.info('表 $tableName 文件 $fileSize 超过大小限制，缓存部分数据',
              label: 'DataStore._loadPathData');
        }
      } catch (e) {
        Logger.error('加载表数据失败: ${file.path}, 错误: $e',
            label: 'DataStore._loadPathData');
        continue; // 继续加载其他表
      }
    }
  }

  /// 加载最近的记录
  Future<void> _loadRecentRecords(
    File file,
    String tableName,
    TableSchema schema,
  ) async {
    final lines = await file.readAsLines();
    final recentLines = lines.reversed.take(1000); // 只加载最近1000条记录

    for (var line in recentLines) {
      if (line.trim().isEmpty) continue;
      final data = jsonDecode(line) as Map<String, dynamic>;
      _queryExecutor?.queryCacheManager.addCachedRecord(tableName, data);
    }

    Logger.info('表 $tableName 部分加载到缓存 (最近1000条记录)');
  }

  /// 加载所有记录
  Future<List<Map<String, dynamic>>> _loadAllRecords(File file) async {
    final results = <Map<String, dynamic>>[];
    final lines = await file.readAsLines();

    for (var line in lines) {
      if (line.trim().isEmpty) continue;
      final data = jsonDecode(line) as Map<String, dynamic>;
      results.add(Map<String, dynamic>.from(data));
    }

    return results;
  }

  /// 从路径中提取文件名
  String _getFileName(String path) {
    final normalizedPath = path.replaceAll('\\', '/');
    final parts = normalizedPath.split('/');
    return parts.last.replaceAll('.dat', '');
  }

  /// 检查唯一性约束
  Future<bool> _checkUniqueConstraints(
      String tableName, Map<String, dynamic> data) async {
    final schema = await getTableSchema(tableName);
    final primaryKey = schema.primaryKey;
    final primaryValue = data[primaryKey];

    // 1. 检查字段的唯一性约束
    for (var field in schema.fields) {
      if (field.unique && field.name != primaryKey) {
        // 排除主键字段
        final value = data[field.name];
        if (value != null) {
          // 检查唯一字段的值是否已存在
          if (!_uniqueValuesCache.containsKey(tableName)) {
            _uniqueValuesCache[tableName] = {};
          }
          if (!_uniqueValuesCache[tableName]!.containsKey(field.name)) {
            _uniqueValuesCache[tableName]![field.name] = <dynamic>{};

            // 初始化缓存
            final dataFile =
                File(config.getDataPath(tableName, schema.isGlobal));
            if (await dataFile.exists()) {
              final lines = await dataFile.readAsLines();
              for (var line in lines) {
                if (line.trim().isEmpty) continue;
                final record = jsonDecode(line) as Map<String, dynamic>;
                if (record[field.name] != null) {
                  _uniqueValuesCache[tableName]![field.name]!
                      .add(record[field.name]);
                }
              }
            }
          }
        }

        // 检查值是否已存在
        if (_uniqueValuesCache[tableName]![field.name]!.contains(value)) {
          Logger.warn('警告: 字段 ${field.name} 的值 $value 已存在');
          return false;
        }
      }
    }

    // 2. 检查索引的唯一性约束
    if (!_uniqueValuesCache.containsKey(tableName)) {
      _uniqueValuesCache[tableName] = {
        primaryKey: <dynamic>{},
      };

      // 初始化唯一索引的集合
      for (var index in schema.indexes.where((idx) => idx.unique)) {
        _uniqueValuesCache[tableName]![index.fields.first] = <dynamic>{};
      }

      // 一次性加载所有数据到缓存
      final dataFile = File(config.getDataPath(tableName, schema.isGlobal));
      if (await dataFile.exists()) {
        final lines = await dataFile.readAsLines();
        for (var line in lines) {
          if (line.trim().isEmpty) continue;
          final record = jsonDecode(line) as Map<String, dynamic>;

          // 收集主键和唯一索引的值
          _uniqueValuesCache[tableName]![primaryKey]!.add(record[primaryKey]);
          for (var index in schema.indexes.where((idx) => idx.unique)) {
            final fieldName = index.fields.first;
            if (record[fieldName] != null) {
              _uniqueValuesCache[tableName]![fieldName]!.add(record[fieldName]);
            }
          }
        }
      }
    }

    // 3. 检查主键
    if (_uniqueValuesCache[tableName]![primaryKey]!.contains(primaryValue)) {
      Logger.warn('警告: 主键重复: $primaryValue');
      return false;
    }

    // 4. 检查唯一索引
    for (var index in schema.indexes.where((idx) => idx.unique)) {
      final fieldName = index.fields.first;
      final value = data[fieldName];
      if (value != null &&
          _uniqueValuesCache[tableName]![fieldName]!.contains(value)) {
        Logger.warn('警告: 唯一索引 ${index.actualIndexName} 的值 $value 已存在');
        return false;
      }
    }

    // 5. 检查写入队列中的值
    final pendingData = fileManager.writeQueue[tableName] ?? [];
    for (var record in pendingData) {
      // 检查主键
      if (record[primaryKey] == primaryValue) {
        Logger.warn('警告: 主键在写入队列中重复: $primaryValue');
        return false;
      }

      // 检查唯一字段
      for (var field in schema.fields) {
        if (field.unique && field.name != primaryKey) {
          final value = data[field.name];
          if (value != null && record[field.name] == value) {
            Logger.warn('警告: 字段 ${field.name} 的值在写入队列中重复: $value');
            return false;
          }
        }
      }

      // 检查唯一索引
      for (var index in schema.indexes.where((idx) => idx.unique)) {
        final fieldName = index.fields.first;
        final value = data[fieldName];
        if (value != null && record[fieldName] == value) {
          Logger.warn('警告: 唯一索引在写入队列中重复: $fieldName = $value');
          return false;
        }
      }
    }

    // 6. 如果通过所有检查，更新缓存
    _uniqueValuesCache[tableName]![primaryKey]!.add(primaryValue);
    for (var field in schema.fields) {
      if (field.unique && field.name != primaryKey) {
        final value = data[field.name];
        if (value != null) {
          _uniqueValuesCache[tableName]![field.name]!.add(value);
        }
      }
    }
    for (var index in schema.indexes.where((idx) => idx.unique)) {
      final fieldName = index.fields.first;
      final value = data[fieldName];
      if (value != null) {
        _uniqueValuesCache[tableName]![fieldName]!.add(value);
      }
    }

    return true;
  }

  /// 按ID查询
  Future<Map<String, dynamic>?> queryById(String tableName, dynamic id) async {
    try {
      final schema = await getTableSchema(tableName);
      final condition = QueryCondition()..where(schema.primaryKey, '=', id);

      final results = await _executeQuery(
        tableName,
        condition,
        limit: 1,
      );
      return results.isEmpty ? null : results.first;
    } catch (e) {
      Logger.error('按ID查询失败: $e', label: 'DataStore.queryById');
      rethrow;
    }
  }

  /// 按字段查询
  Future<List<Map<String, dynamic>>> queryBy(
    String tableName,
    String field,
    dynamic value,
  ) async {
    try {
      final condition = QueryCondition()..where(field, '=', value);

      return await _executeQuery(tableName, condition);
    } catch (e) {
      Logger.error('字段查询失败: $e', label: 'DataStore.queryBy');
      rethrow;
    }
  }

  /// SQL 方式查询（将 SQL 条件转换为 QueryCondition）
  Future<List<Map<String, dynamic>>> queryBySql(
    String tableName, {
    String? where,
    List<dynamic>? whereArgs,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    try {
      // 解析 SQL 条件为 QueryCondition
      QueryCondition? condition;
      if (where != null) {
        condition = _parseSqlWhereClause(where, whereArgs);
      }

      // 解析排序
      List<String>? orderByList;
      if (orderBy != null) {
        orderByList = orderBy.split(',').map((e) => e.trim()).toList();
      }

      // 执行查询
      return await _executeQuery(
        tableName,
        condition ?? QueryCondition(),
        orderBy: orderByList,
        limit: limit,
        offset: offset,
      );
    } catch (e) {
      Logger.error('SQL查询失败: $e', label: 'DataStore.queryBySql');
      rethrow;
    }
  }

  /// 执行查询
  Future<List<Map<String, dynamic>>> _executeQuery(
    String tableName,
    QueryCondition condition, {
    List<String>? orderBy,
    int? limit,
    int? offset,
  }) async {
    // 构建查询计划
    final queryPlan = await _queryOptimizer?.optimize(
      tableName,
      condition.build(),
      orderBy,
    );

    if (queryPlan == null) {
      throw StateError('Query optimizer not initialized');
    }

    // 使用 QueryExecutor 执行查询
    return await _queryExecutor?.execute(
          queryPlan,
          tableName,
          condition: condition,
          orderBy: orderBy,
          limit: limit,
          offset: offset,
        ) ??
        [];
  }

  /// 解析 SQL where 子句为 QueryCondition
  QueryCondition _parseSqlWhereClause(String where, List<dynamic>? whereArgs) {
    final condition = QueryCondition();
    if (where.isEmpty) return condition;

    // 将 || 替换为 OR，将 && 替换为 AND
    where = where.replaceAll('||', 'OR').replaceAll('&&', 'AND');

    // 按 OR 分割
    final orGroups = where.split(RegExp(r'\s+OR\s+', caseSensitive: false));
    var argIndex = 0;

    for (var group in orGroups) {
      // 解析每个 OR 组中的 AND 条件
      final conditions =
          group.trim().split(RegExp(r'\s+AND\s+', caseSensitive: false));

      for (var condStr in conditions) {
        _parseSingleCondition(condition, condStr.trim(), whereArgs, argIndex);
        argIndex += _countPlaceholders(condStr);
      }

      // 如果不是最后一个组，添加 OR
      if (group != orGroups.last) {
        condition.or();
      }
    }

    return condition;
  }

  /// 解析单个条件(by sql)
  void _parseSingleCondition(
    QueryCondition condition,
    String condStr,
    List<dynamic>? whereArgs,
    int startArgIndex,
  ) {
    // 解析操作符
    String? operator;
    for (var op in ['>=', '<=', '!=', '=', '>', '<', 'LIKE', 'IS NOT', 'IS']) {
      if (RegExp('\\s+$op\\s+', caseSensitive: false).hasMatch(condStr)) {
        operator = op.toUpperCase();
        break;
      }
    }

    if (operator == null) return;

    // 分割字段名和值
    final parts =
        condStr.split(RegExp('\\s+$operator\\s+', caseSensitive: false));
    if (parts.length != 2) return;

    final field = parts[0].trim();
    String valueStr = parts[1].trim();

    // 处理值
    dynamic value;
    if (valueStr == '?' &&
        whereArgs != null &&
        startArgIndex < whereArgs.length) {
      // 处理参数占位符
      value = whereArgs[startArgIndex];
    } else if ((valueStr.startsWith("'") && valueStr.endsWith("'")) ||
        (valueStr.startsWith('"') && valueStr.endsWith('"'))) {
      // 处理字符串值
      value = valueStr.substring(1, valueStr.length - 1);
    } else if (valueStr.toLowerCase() == 'null') {
      // 处理 NULL 值
      value = null;
    } else {
      // 尝试解析为数字
      value = num.tryParse(valueStr) ?? valueStr;
    }

    // 添加条件
    switch (operator) {
      case '=':
        condition.where(field, '=', value);
        break;
      case '!=':
      case '<>':
        condition.where(field, '!=', value);
        break;
      case '>':
        condition.where(field, '>', value);
        break;
      case '>=':
        condition.where(field, '>=', value);
        break;
      case '<':
        condition.where(field, '<', value);
        break;
      case '<=':
        condition.where(field, '<=', value);
        break;
      case 'LIKE':
        condition.where(field, 'LIKE', value);
        break;
      case 'IS':
        condition.where(field, 'IS', null);
        break;
      case 'IS NOT':
        condition.where(field, 'IS NOT', null);
        break;
    }
  }

  /// 计算占位符数量
  int _countPlaceholders(String condition) {
    return '?'.allMatches(condition).length;
  }

  /// 切换基础空间
  Future<bool> switchBaseSpace({String spaceName = 'default'}) async {
    await _ensureInitialized();

    if (_currentSpaceName == spaceName) {
      return true;
    }

    final oldSpaceName = _currentSpaceName;
    _currentSpaceName = spaceName;

    try {
      // 更新配置
      if (_config != null) {
        _config = _config!.copyWith(baseName: _currentSpaceName);
      }

      // 清理缓存和队列
      _queryExecutor?.queryCacheManager.onBasePathChanged();
      fileManager.writeQueue.clear();
      _uniqueValuesCache.clear();

      // 设置切换标记
      _isSwitchingSpace = true;

      // 重新初始化数据库
      _isInitialized = false;
      _baseInitialized = false;
      await initialize(dbPath: _config?.dbPath, config: _config);

      // 触发基础空间变更事件
      _notifyBasePathChanged(BasePathChangedEvent(oldSpaceName, spaceName));

      Logger.info('基础空间已切换: $oldSpaceName -> $spaceName');

      // 清理非全局表的索引
      _indexManager?.onBasePathChanged();

      return true;
    } catch (e) {
      // 回滚
      _currentSpaceName = oldSpaceName;
      if (_config != null) {
        _config = _config!.copyWith(baseName: oldSpaceName);
      }
      Logger.error('切换基础空间失败: $e', label: 'DataStore.switchBaseSpace');
      return false;
    } finally {
      // 重置切换标记
      _isSwitchingSpace = false;
    }
  }

  /// 通知基础空间变更
  void _notifyBasePathChanged(BasePathChangedEvent event) {
    _indexManager?.onBasePathChanged();
    _statisticsCollector?.onBasePathChanged(event);
  }

  /// 删除数据库
  Future<void> deleteDatabase({String? dbPath}) async {
    try {
      final dbDirPath = await getDatabasePath(dbPath: dbPath);
      // 1. 先关闭数据库
      await close();

      // 2. 删除数据库目录
      final dbDir = Directory(dbDirPath);
      if (await dbDir.exists()) {
        await dbDir.delete(recursive: true);
        Logger.info('数据库已删除: $dbDirPath');
      }

      // 3. 清理所有管理器状态
      _indexManager?.onBasePathChanged(); // 清理索引缓存
      _queryExecutor?.queryCacheManager.clear(); // 清理查询缓存
      _maxIds.clear(); // 清理自增ID缓存
      _maxIdsDirty.clear();
      _uniqueValuesCache.clear(); // 清理唯一值缓存

      // 4. 从实例映射中移除
      _instances.remove(_instanceKey);
    } catch (e) {
      Logger.error('删除数据库失败: $e', label: 'DataStore.deleteDatabase');
      rethrow;
    }
  }

  // 添加自增ID写入队列
  final Map<String, int> _maxIds = {};
  final Map<String, bool> _maxIdsDirty = {}; // 标记是否需要写入

  /// 更新最大ID值(只在内存中更新)
  void _updateMaxIdInMemory(String tableName, int id) {
    final currentMaxId = _maxIds[tableName] ?? 0;
    if (id > currentMaxId) {
      _maxIds[tableName] = id;
      _maxIdsDirty[tableName] = true; // 标记需要写入
    }
  }

  /// 获取下一个自增ID
  Future<int> _getNextId(String tableName) async {
    final schema = await getTableSchema(tableName);
    // 先从内存获取
    if (!_maxIds.containsKey(tableName)) {
      // 首次访问,从文件加载
      final maxIdFile =
          File(config.getAutoIncrementPath(tableName, schema.isGlobal));
      if (await maxIdFile.exists()) {
        final content = await maxIdFile.readAsString();
        _maxIds[tableName] = int.parse(content);
      } else {
        _maxIds[tableName] = 0;
      }
    }

    final nextId = (_maxIds[tableName] ?? 0) + 1;
    _maxIds[tableName] = nextId;
    _maxIdsDirty[tableName] = true; // 标记需要写入

    return nextId;
  }

  /// 刷新自增ID到文件
  Future<void> _flushMaxIds() async {
    final dirtyTables = _maxIdsDirty.entries
        .where((entry) => entry.value)
        .map((entry) => entry.key)
        .toList();

    if (dirtyTables.isEmpty) return;

    for (var tableName in dirtyTables) {
      try {
        final schema = await getTableSchema(tableName);
        final maxId = _maxIds[tableName];
        if (maxId != null) {
          final maxIdFile =
              File(config.getAutoIncrementPath(tableName, schema.isGlobal));
          await maxIdFile.writeAsString(maxId.toString());
          _maxIdsDirty[tableName] = false; // 清除写入标记
        }
      } catch (e) {
        Logger.error('写入自增ID失败: $e', label: 'DataStore-_flushMaxIds');
      }
    }
  }

  /// 键值对存储表名
  static const String _kvStoreName = 'kv_store'; // 基础空间下的键值存储
  static const String _globalKvStoreName = 'global_kv_store'; // 全局键值存储

  /// 设置键值对
  Future<bool> setValue(String key, dynamic value,
      {bool isGlobal = false}) async {
    await _ensureInitialized();

    final tableName = isGlobal ? _globalKvStoreName : _kvStoreName;

    // 构造数据
    final data = {
      'key': key,
      'value': jsonEncode(value),
      'updated_at': DateTime.now().toIso8601String(),
    };

    try {
      final existing = await _executeQuery(
          tableName, QueryCondition()..where('key', '=', key));

      if (existing.isEmpty) {
        return await insert(tableName, data);
      } else {
        // 创建更新条件
        final condition = QueryCondition()..where('key', '=', key);
        return await updateInternal(
          tableName,
          data,
          condition,
        );
      }
    } catch (e) {
      Logger.error('设置键值对失败: $e', label: 'DataStore.setValue');
      return false;
    }
  }

  /// 获取键值
  Future<dynamic> getValue(String key, {bool isGlobal = false}) async {
    await _ensureInitialized();

    final tableName = isGlobal ? _globalKvStoreName : _kvStoreName;
    final result = await _executeQuery(
        tableName, QueryCondition()..where('key', '=', key));
    if (result.isEmpty) return null;

    try {
      return jsonDecode(result.first['value']);
    } catch (e) {
      Logger.error('解析键值失败: $e', label: 'DataStore.getValue');
      return null;
    }
  }

  /// 删除键值
  Future<bool> removeValue(String key, {bool isGlobal = false}) async {
    await _ensureInitialized();

    final tableName = isGlobal ? _globalKvStoreName : _kvStoreName;
    // 创建删除条件
    final condition = QueryCondition()..where('key', '=', key);
    await deleteInternal(tableName, condition);
    return true;
  }

  /// 获取查询优化器
  QueryOptimizer? getQueryOptimizer() => _queryOptimizer;

  /// 获取查询执行器
  QueryExecutor? getQueryExecutor() => _queryExecutor;

  ConcurrencyManager? get concurrencyManager => _concurrencyManager;
  IndexManager? get indexManager => _indexManager;

  /// 刷新自增ID到文件
  Future<void> flushMaxIds() async {
    await _flushMaxIds();
  }

  /// 获取缓存统计信息
  Map<String, int> getCacheStats() {
    return fileManager.writeQueue
        .map((key, value) => MapEntry(key, value.length));
  }

  /// 获取表信息
  Future<TableInfo> getTableInfo(String tableName) async {
    final schema = await getTableSchema(tableName);
    final dataFile = File(config.getDataPath(tableName, schema.isGlobal));

    DateTime? createdAt;
    if (await dataFile.exists()) {
      final stat = await dataFile.stat();
      createdAt = stat.changed;
    }

    return TableInfo(
      tableName: tableName,
      recordCount: await _getRecordCount(tableName),
      cacheCount:
          _queryExecutor?.queryCacheManager.getTableCacheCount(tableName) ?? 0,
      fileSize: fileManager.getFileSize(tableName),
      indexCount: schema.indexes.length,
      schema: schema,
      isGlobal: await isGlobalTable(tableName),
      lastModified: fileManager.getLastModifiedTime(tableName),
      createdAt: createdAt,
    );
  }

  /// 获取表记录数量
  Future<int> _getRecordCount(String tableName) async {
    final schema = await getTableSchema(tableName);
    final dataFile = File(config.getDataPath(tableName, schema.isGlobal));
    if (!await dataFile.exists()) return 0;

    final allRecords = <String, bool>{};

    // 1. 读取文件中的记录
    final lines = await dataFile.readAsLines();
    for (var line in lines) {
      if (line.trim().isEmpty) continue;
      final data = jsonDecode(line) as Map<String, dynamic>;
      final primaryKeyValue = data[schema.primaryKey].toString();
      allRecords[primaryKeyValue] = true;
    }

    // 2. 合并待写入队列中的记录
    final pendingRecords = fileManager.writeQueue[tableName] ?? [];
    for (var record in pendingRecords) {
      final primaryKeyValue = record[schema.primaryKey].toString();
      allRecords[primaryKeyValue] = true;
    }

    return allRecords.length;
  }

  /// 判断是否为全局表
  Future<bool> isGlobalTable(String tableName) async {
    final schema = await getTableSchema(tableName);
    return schema.isGlobal;
  }
}
