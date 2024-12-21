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
import '../statistic/statistics_collector.dart';
import 'transaction_manager.dart';

/// Core storage engine implementation
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

  bool get isInitialized => _isInitialized;

  /// Create instance with configuration
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

  /// Start initialization process
  void _startInitialize(String? dbPath, DataStoreConfig? config) {
    if (_initializing || _isInitialized) {
      return;
    }

    _initCompleter = Completer<void>();

    initialize(dbPath: dbPath, config: config).then((_) {
      if (!_initCompleter.isCompleted) {
        _initCompleter.complete();
      }
    }).catchError((e) {
      if (!_initCompleter.isCompleted) {
        _initCompleter.completeError(e);
      }
      _initializing = false;
    });
  }

  /// Get database version
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

  /// Set database version
  Future<void> setVersion(int version) async {
    final versionFile = File('${config.dbPath}/version');
    await versionFile.writeAsString(version.toString());
  }

  /// Ensure initialization is complete
  Future<void> _ensureInitialized() async {
    if (!_isInitialized && !_initCompleter.isCompleted) {
      await _initCompleter.future;
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

  // Cache for unique values
  final Map<String, Map<String, Set<dynamic>>> _uniqueValuesCache = {};

  FileManager? _fileManager;
  FileManager get fileManager {
    if (_fileManager == null) {
      throw StateError('FileManager not initialized');
    }
    return _fileManager!;
  }

  /// Get current base space name
  String get currentBaseSpaceName => _currentSpaceName;

  /// Get current configuration
  DataStoreConfig get config {
    if (_config == null) {
      throw StateError('DataStore not initialized');
    }
    return _config!;
  }

  /// Get database path
  Future<String> getDatabasePath({String? dbPath}) async {
    if (_config != null && isInitialized) {
      return _config!.dbPath;
    } else if (dbPath != null) {
      return "$dbPath/db";
    }
    final appPath = await getPathApp();
    return "$appPath/db";
  }

  /// Get table path
  Future<String> getTablePath(String tableName) async {
    final schema = await getTableSchema(tableName);
    return config.getTablePath(tableName, schema.isGlobal);
  }

  /// Get table path (sync version)
  String getTablePathSync(String tableName, {bool isGlobal = false}) {
    final schema = _queryExecutor?.queryCacheManager.getSchema(tableName);
    return config.getTablePath(tableName, schema?.isGlobal ?? isGlobal);
  }

  /// Initialize storage engine
  Future<bool> initialize({String? dbPath, DataStoreConfig? config}) async {
    if (_initializing && !_initCompleter.isCompleted) {
      await _initCompleter.future;
      return true;
    }

    if (_isInitialized && dbPath == _config?.dbPath && config == _config) {
      return true;
    }

    _initializing = true;

    try {
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

      _queryOptimizer = QueryOptimizer(this);
      _queryExecutor = QueryExecutor(this, _indexManager!);

      await _recoveryIncompleteTransactions();
      await _loadDataToCache();

      _baseInitialized = true;
      await _startSetupAndUpgrade();

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
      Logger.error('Database initialization failed: $e',
          label: 'DataStore.initialize');
      rethrow;
    } finally {
      _initializing = false;
    }
  }

  /// Setup tables and handle upgrades
  Future<void> _startSetupAndUpgrade() async {
    try {
      await _onConfigure?.call(this);
      final oldVersion = await getVersion();

      if (oldVersion == 0 || _isSwitchingSpace) {
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
        await _onUpgrade?.call(this, oldVersion, _version);
        await setVersion(_version);
      } else if (oldVersion > _version) {
        await _onDowngrade?.call(this, oldVersion, _version);
        await setVersion(_version);
      }

      await _onOpen?.call(this);
    } catch (e) {
      Logger.error('Database setup or upgrade failed: $e',
          label: 'DataStore._startSetupAndUpgrade');
    }
  }

  /// close database
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

      Logger.info('The database instance has been closed: $_instanceKey',
          label: 'DataStoreImpl.close');
    } catch (e) {
      Logger.error('Database shutdown failed: $e', label: 'DataStore.close');
      rethrow;
    }
  }

  /// create table
  Future<void> createTable(
    String tableName,
    TableSchema schema,
  ) async {
    if (!_baseInitialized) {
      await _ensureInitialized();
    }

    try {
      // 1. check global path and base path
      final globalSchemaFile = File(config.getSchemaPath(tableName, true));
      final baseSchemaFile = File(config.getSchemaPath(tableName, false));

      if (await globalSchemaFile.exists()) {
        Logger.warn('Table $tableName already exists in global space',
            label: 'DataStore.createTable');
        return;
      }
      if (await baseSchemaFile.exists()) {
        Logger.warn('Table $tableName already exists in base space',
            label: 'DataStore.createTable');
        return;
      }

      // 2. create target directory
      final isGlobal = schema.isGlobal;
      final targetPath =
          isGlobal ? config.getGlobalPath() : config.getBasePath();
      final targetDir = Directory(targetPath);
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }

      // 3. get target table path
      final dataFile = File(config.getDataPath(tableName, schema.isGlobal));
      final schemaFile = File(config.getSchemaPath(tableName, schema.isGlobal));

      await _concurrencyManager!.acquireWriteLock(tableName);
      try {
        // 4. validate table structure
        _validateSchema(schema);

        // 5. create new table file
        await dataFile.create(recursive: true);
        await schemaFile.writeAsString(jsonEncode(schema));

        // 6. create primary key index
        await _indexManager?.createPrimaryIndex(tableName, schema.primaryKey);

        // 7. create other indexes
        for (var index in schema.indexes) {
          await _indexManager?.createIndex(tableName, index);
        }

        Logger.info('Table $tableName created successfully');
      } finally {
        await _concurrencyManager!.releaseWriteLock(tableName);
      }

      // 8. cache new created table structure
      _queryExecutor?.queryCacheManager.cacheSchema(tableName, schema);
    } catch (e) {
      Logger.error('Create table failed: $e', label: 'DataStore.createTable');
      rethrow;
    }
  }

  /// insert data complete process
  Future<bool> insert(String tableName, Map<String, dynamic> data) async {
    // need to be fully initialized
    if (!_isInitialized) {
      await _ensureInitialized();
    }

    // 1. transaction and lock
    final transaction = await _transactionManager!.beginTransaction();
    await _concurrencyManager!.acquireWriteLock(tableName);

    try {
      // 2. data validation
      final schema = await getTableSchema(tableName);
      final validData = await _validateAndProcessData(schema, data, tableName);
      if (validData == null) {
        return false;
      }

      // 3. unique check
      if (!await _checkUniqueConstraints(tableName, validData)) {
        return false;
      }

      // 4. update cache
      _queryExecutor?.queryCacheManager.addCachedRecord(tableName, validData);

      // 5. add to write queue (insert operation)
      fileManager.addToWriteQueue(tableName, validData, isUpdate: false);

      // 6. commit transaction
      await _transactionManager!.commit(transaction);
      return true;
    } catch (e) {
      Logger.error('Insert failed: $e', label: 'DataStore.insert');
      await _rollbackTransaction(transaction, tableName, data);
      return false;
    } finally {
      await _concurrencyManager!.releaseWriteLock(tableName);
    }
  }

  /// rollback transaction
  Future<void> _rollbackTransaction(
    Transaction? transaction,
    String tableName,
    Map<String, dynamic> data,
  ) async {
    try {
      // 1. rollback transaction
      await _transactionManager!.rollback(transaction);

      // 2. remove from cache
      final schema = await getTableSchema(tableName);
      final primaryKeyField = schema.primaryKey;
      final primaryKeyValue = data[primaryKeyField];

      _queryExecutor?.queryCacheManager.removeCachedRecord(
        tableName,
        primaryKeyValue.toString(),
      );

      // 3. remove from write queue
      final queue = fileManager.writeQueue[tableName];
      if (queue != null) {
        queue.removeWhere(
            (record) => record[primaryKeyField] == primaryKeyValue);
      }

      // 4. remove last record from file (if written)
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
            Logger.error('Failed to parse last record: $e',
                label: 'DataStore._rollbackTransaction');
          }
        }
      }

      // 5. rollback indexes
      await _indexManager?.deleteFromIndexes(tableName, data);

      Logger.info('Transaction rollback successfully');
    } catch (e) {
      Logger.error('Transaction rollback failed: $e',
          label: 'DataStore._rollbackTransaction');
      _queryExecutor?.queryCacheManager.invalidateCache(tableName);
      rethrow;
    }
  }

  /// validate and process data
  Future<Map<String, dynamic>?> _validateAndProcessData(
    TableSchema schema,
    Map<String, dynamic> data,
    String tableName,
  ) async {
    try {
      final result = Map<String, dynamic>.from(data);
      final primaryKey = schema.primaryKey;

      // 1. handle auto increment primary key
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

      // 2. fill default value and null value
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

        // check non-null constraint
        if (!field.nullable && value == null) {
          Logger.warn('Warning: field ${field.name} cannot be null');
          return null;
        }

        // check data type
        if (value != null && !_isValidDataType(value, field.type)) {
          Logger.warn(
              'Warning: value type of field ${field.name} is incorrect');
          return null;
        }

        // check max length
        if (value != null && field.maxLength != null) {
          if (value is String && value.length > field.maxLength!) {
            Logger.warn('Warning: field ${field.name} exceeds max length');
            return null;
          }
        }
      }

      return result;
    } catch (e) {
      Logger.error('Data validation failed: $e',
          label: 'DataStore-_validateAndProcessData');
      return null;
    }
  }

  /// get type default value
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

  /// check data type is valid
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

  /// query data by map
  Future<List<Map<String, dynamic>>> queryByMap(
    String tableName, {
    Map<String, dynamic>? where,
    List<String>? orderBy,
    int? limit,
    int? offset,
  }) async {
    await _ensureInitialized();

    try {
      // convert map condition to QueryCondition
      final condition = _convertMapToCondition(where);

      // build query plan
      final queryPlan = await _queryOptimizer?.optimize(
        tableName,
        where ?? {},
        orderBy,
      );

      if (queryPlan == null) {
        throw StateError('Query optimizer not initialized');
      }

      // execute query by QueryExecutor
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
      Logger.error('Query failed: $e', label: 'DataStore.queryByMap');
      rethrow;
    }
  }

  /// convert map condition to QueryCondition
  QueryCondition _convertMapToCondition(Map<String, dynamic>? where) {
    if (where == null || where.isEmpty) {
      return QueryCondition();
    }

    final condition = QueryCondition();

    // handle OR condition
    if (where.containsKey('OR')) {
      final orGroups = where['OR'] as List<Map<String, dynamic>>;
      for (var group in orGroups) {
        // add first group condition
        for (var entry in group.entries) {
          _addCondition(condition, entry.key, entry.value);
        }
        // use OR for subsequent groups
        if (group != orGroups.last) {
          condition.or();
        }
      }
    } else {
      // handle normal AND condition
      for (var entry in where.entries) {
        _addCondition(condition, entry.key, entry.value);
      }
    }

    return condition;
  }

  /// add single condition
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
            Logger.warn('IN/NOT IN operator needs List type value',
                label: 'DataStore._addCondition');
            return;
          }
          condition.where(field, operator, compareValue);
          break;

        case 'BETWEEN':
          if (compareValue is! Map ||
              !compareValue.containsKey('start') ||
              !compareValue.containsKey('end')) {
            Logger.warn('BETWEEN operator needs Map with start and end',
                label: 'DataStore._addCondition');
            return;
          }
          condition.where(
              field, 'BETWEEN', [compareValue['start'], compareValue['end']]);
          break;

        case 'LIKE':
        case 'NOT LIKE':
          if (compareValue is! String) {
            Logger.warn('LIKE/NOT LIKE operator needs String type value',
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
          // handle other operators (>, <, >=, <=, !=)
          condition.where(field, operator, compareValue);
          break;
      }
    } else {
      // simple equal condition
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
    // implement loading incomplete transactions from transaction log
    return [];
  }

  /// validate table structure
  void _validateSchema(TableSchema schema) {
    // check primary key
    if (schema.primaryKey.isEmpty) {
      throw ArgumentError('Primary key cannot be empty');
    }

    // check field definition
    if (schema.fields.isEmpty) {
      throw ArgumentError('Table must have at least one field');
    }

    // check primary key field is exist
    if (!schema.fields.any((col) => col.name == schema.primaryKey)) {
      throw ArgumentError('Primary key field not found in fields');
    }

    // check field name is unique
    final fieldNames = schema.fields.map((col) => col.name).toSet();
    if (fieldNames.length != schema.fields.length) {
      throw ArgumentError('Field names must be unique');
    }

    // check index field is exist
    for (var index in schema.indexes) {
      for (var field in index.fields) {
        if (!fieldNames.contains(field)) {
          throw ArgumentError('Index field $field not found in table fields');
        }
      }
    }
  }

  /// calculate checksum
  String _calculateChecksum(Uint8List data) {
    final compressor = DataCompressor();
    return compressor.calculateChecksum(data).toString();
  }

  /// rollback transaction
  Future<void> rollback(Transaction transaction) async {
    await _transactionManager!.rollback(transaction);
  }

  /// apply transaction changes
  Future<void> _applyChanges(Transaction transaction) async {
    await _transactionManager!.commit(transaction);
  }

  /// verify data integrity
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

  /// repair data
  Future<void> _repairData(String tableName) async {
    // use auto repair to repair data
    final autoRepair = AutoRepair(
      this,
      _indexManager!,
      BackupManager(this),
    );
    await autoRepair.repairTableStructure(tableName);
  }

  /// backup data and return backup path
  Future<String> backup() async {
    try {
      // 1. flush all pending data
      await fileManager.flushWriteQueue();

      // 2. create backup manager
      final backupManager = BackupManager(this);

      // 3. create backup
      final backupPath = await backupManager.createBackup();
      Logger.info('Backup created successfully: $backupPath');
      return backupPath;
    } catch (e) {
      Logger.error('Create backup failed: $e', label: 'DataStore-backup');
      rethrow;
    }
  }

  /// restore from backup
  Future<bool> restore(String backupPath) async {
    try {
      // 1. create backup manager
      final backupManager = BackupManager(this);

      // 2. load backup data
      final backupData = await backupManager.loadBackup(backupPath);

      // 3. get actual data part
      final data = backupData['data'] as Map<String, dynamic>;
      if (data.isEmpty) {
        Logger.error('Backup data is empty', label: 'DataStore-restore');
        return false;
      }

      // 4. clean existing data
      final dbDir = Directory(_config!.getBasePath());
      if (await dbDir.exists()) {
        await dbDir.delete(recursive: true);
      }
      await dbDir.create();

      // 5. restore each table data
      for (var entry in data.entries) {
        final tableName = entry.key;
        final tableData = entry.value as Map<String, dynamic>;

        // restore schema
        final schema =
            TableSchema.fromJson(tableData['schema'] as Map<String, dynamic>);
        await createTable(tableName, schema);

        // restore data
        final records =
            (tableData['data'] as List).cast<Map<String, dynamic>>();

        // write data to file
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

      Logger.info('Restore from backup successfully');
      return true;
    } catch (e) {
      Logger.error('Restore from backup failed: $e',
          label: 'DataStore-restore');
      return false;
    }
  }

  /// update statistics
  Future<void> updateStatistics(String tableName) async {
    await _statisticsCollector!.collectTableStatistics(tableName);
  }

  /// get query plan
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

  /// validate and process update data
  Future<Map<String, dynamic>?> _validateAndProcessUpdateData(
    TableSchema schema,
    Map<String, dynamic> data,
    String tableName,
  ) async {
    try {
      final result = Map<String, dynamic>.from(data);

      // remove primary key field (if exists)
      result.remove(schema.primaryKey);

      // check data type
      for (var entry in result.entries) {
        final field = schema.fields.firstWhere(
          (col) => col.name == entry.key,
          orElse: () => throw StateError('Unknown field ${entry.key}'),
        );

        if (entry.value != null && !_isValidDataType(entry.value, field.type)) {
          Logger.warn('Warning: value type of field ${entry.key} is incorrect');
          return null;
        }
      }

      return result;
    } catch (e) {
      Logger.error('Update data validation failed: $e',
          label: 'DataStore-_validateAndProcessUpdateData');
      return null;
    }
  }

  /// update record
  Future<bool> updateInternal(
    String tableName,
    Map<String, dynamic> data,
    QueryCondition condition, {
    List<String>? orderBy,
    int? limit,
    int? offset,
  }) async {
    await _ensureInitialized();
    final transaction = await _transactionManager!.beginTransaction();
    await _concurrencyManager!.acquireWriteLock(tableName);

    try {
      // validate data
      final schema = await getTableSchema(tableName);
      final validData =
          await _validateAndProcessUpdateData(schema, data, tableName);
      if (validData == null || validData.isEmpty) {
        return false;
      }

      // find matching records
      final records = await _executeQuery(tableName, condition,
          orderBy: orderBy, limit: limit, offset: offset);
      if (records.isEmpty) {
        return false;
      }

      // check unique constraints
      for (var record in records) {
        // merge update data
        final updatedRecord = Map<String, dynamic>.from(record)
          ..addAll(validData);

        // check unique constraints of fields
        for (var field in schema.fields) {
          if (field.unique && validData.containsKey(field.name)) {
            final value = validData[field.name];
            // find if other records are using this value
            final existing = await _executeQuery(
                tableName,
                QueryCondition()
                  ..where(field.name, '=', value)
                  ..where(schema.primaryKey, '!=', record[schema.primaryKey]));
            if (existing.isNotEmpty) {
              Logger.warn(
                  'Warning: value $value of field ${field.name} already exists');
              return false;
            }
          }
        }

        // check unique constraints of indexes
        for (var index in schema.indexes.where((idx) => idx.unique)) {
          // if update involves index fields
          if (index.fields.any((col) => validData.containsKey(col))) {
            final indexValues = Map<String, dynamic>.from(record);
            indexValues.addAll(validData);

            // build query condition for unique index
            final condition = QueryCondition();
            for (var col in index.fields) {
              condition.where(col, '=', indexValues[col]);
            }
            condition.where(schema.primaryKey, '!=',
                record[schema.primaryKey]); // exclude current record

            final existing = await _executeQuery(tableName, condition);
            if (existing.isNotEmpty) {
              Logger.warn(
                  'Warning: value ${record[schema.primaryKey]} of unique index ${index.actualIndexName} already exists');
              return false;
            }
          }
        }

        // update cache and write queue, index
        _queryExecutor?.queryCacheManager.removeCachedRecord(
            tableName, record[schema.primaryKey].toString());
        _queryExecutor?.queryCacheManager
            .addCachedRecord(tableName, updatedRecord);

        // update write queue
        fileManager.addToWriteQueue(tableName, updatedRecord, isUpdate: true);
      }

      // commit transaction
      await _transactionManager!.commit(transaction);

      // invalidate related query cache of affected records
      final affectedPrimaryKeys =
          records.map((r) => r[schema.primaryKey]).toSet();
      await _queryExecutor?.invalidateRecords(tableName, affectedPrimaryKeys);

      return true;
    } catch (e) {
      Logger.error('Update failed: $e', label: 'DataStore-update');
      await _transactionManager!.rollback(transaction);
      rethrow;
    } finally {
      await _concurrencyManager!.releaseWriteLock(tableName);
    }
  }

  /// clear table
  Future<void> clear(String tableName) async {
    final transaction = await _transactionManager!.beginTransaction();
    await _concurrencyManager!.acquireWriteLock(tableName);
    try {
      // clear file
      final tablePath = getTablePath(tableName);
      final dataFile = File('$tablePath.dat');
      if (await dataFile.exists()) {
        await dataFile.writeAsString('');
      }

      // clear record cache
      _queryExecutor?.queryCacheManager.invalidateCache(tableName);

      // clear write queue
      fileManager.writeQueue.remove(tableName);

      // reset index
      await _indexManager?.resetIndexes(tableName);

      // clear unique value cache
      _uniqueValuesCache.remove(tableName);

      // clear statistics
      _statisticsCollector?.invalidateCache(tableName);

      await _transactionManager!.commit(transaction);
    } catch (e) {
      Logger.info('Clear table failed: $e', label: 'DataStore-clear');
      await _transactionManager!.rollback(transaction);
      rethrow;
    } finally {
      await _concurrencyManager!.releaseWriteLock(tableName);
    }
  }

  /// delete record
  Future<bool> deleteInternal(
    String tableName,
    QueryCondition condition, {
    List<String>? orderBy,
    int? limit,
    int? offset,
  }) async {
    final transaction = await _transactionManager!.beginTransaction();
    await _concurrencyManager!.acquireWriteLock(tableName);

    try {
      // find records to delete
      final recordsToDelete = await _executeQuery(tableName, condition,
          orderBy: orderBy, limit: limit, offset: offset);

      if (recordsToDelete.isEmpty) {
        return true;
      }

      final schema = await getTableSchema(tableName);
      final primaryKey = schema.primaryKey;
      final queue = fileManager.writeQueue[tableName];

      for (var record in recordsToDelete) {
        // remove from record cache
        _queryExecutor?.queryCacheManager
            .removeCachedRecord(tableName, record[primaryKey].toString());

        // invalidate related query cache
        _queryExecutor?.invalidateRecord(tableName, record[primaryKey]);

        queue?.removeWhere(
            (r) => r[schema.primaryKey] == record[schema.primaryKey]);

        await _indexManager!.deleteFromIndexes(tableName, record);
      }

      // delete from file
      final dataFile = File('${getTablePath(tableName)}.dat');
      if (await dataFile.exists()) {
        final lines = await dataFile.readAsLines();
        final remainingLines = lines.where((line) {
          if (line.trim().isEmpty) return true;
          final record = jsonDecode(line) as Map<String, dynamic>;
          // use primary key to determine if it needs to be deleted
          return !recordsToDelete
              .any((r) => r[schema.primaryKey] == record[schema.primaryKey]);
        }).toList();

        await dataFile.writeAsString('${remainingLines.join('\n')}\n');
      }

      // update statistics
      await _statisticsCollector?.collectTableStatistics(tableName);

      await _transactionManager!.commit(transaction);
    } catch (e) {
      Logger.info('Delete failed: $e', label: 'DataStore-delete');
      await _transactionManager!.rollback(transaction);
      // clear cache, ensure data consistency
      return false;
    } finally {
      await _concurrencyManager!.releaseWriteLock(tableName);
    }

    return true;
  }

  /// drop table
  Future<void> dropTable(String tableName) async {
    try {
      await _concurrencyManager!.acquireWriteLock(tableName);

      // delete data file
      final tablePath = getTablePath(tableName);
      final dataFile = File('$tablePath.dat');
      if (await dataFile.exists()) {
        await dataFile.delete();
      }

      // delete schema file
      final schemaFile = File('$tablePath.schema');
      if (await schemaFile.exists()) {
        await schemaFile.delete();

        // delete index file
        final schema = await getTableSchema(tableName);
        for (var index in schema.indexes) {
          final indexFile = File(
              '${_config!.getTablePath(tableName, schema.isGlobal)}_${index.actualIndexName}.idx');
          if (await indexFile.exists()) {
            await indexFile.delete();
          }
        }
      }

      // clear all related caches
      _queryExecutor?.queryCacheManager.invalidateCache(tableName);
      _queryExecutor?.invalidateCache(tableName);
      _statisticsCollector?.invalidateCache(tableName);
    } catch (e) {
      Logger.error('Drop table failed: $e', label: 'DataStore-dropTable');
      rethrow;
    } finally {
      await _concurrencyManager!.releaseWriteLock(tableName);
    }
  }

  /// get table schema
  Future<TableSchema> getTableSchema(String tableName) async {
    // 1. get from cache first
    final cachedSchema = _queryExecutor?.queryCacheManager.getSchema(tableName);
    if (cachedSchema != null) {
      return cachedSchema;
    }

    // 2. load from file
    // try to get schema file from global space first, if not exist, then get from base space
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

      // 3. cache and return
      _queryExecutor?.queryCacheManager.cacheSchema(tableName, schema);
      return schema;
    } catch (e) {
      Logger.error('Load table schema failed: $e',
          label: 'DataStore.getTableSchema');
      rethrow;
    }
  }

  /// verify data integrity
  Future<bool> verifyIntegrity(String tableName) async {
    return _verifyDataIntegrity(tableName);
  }

  /// repair data
  Future<void> repair(String tableName) async {
    await _repairData(tableName);
  }

  /// batch insert data
  Future<bool> batchInsert(
      String tableName, List<Map<String, dynamic>> records) async {
    await _ensureInitialized();

    try {
      await _concurrencyManager!.acquireWriteLock(tableName);

      // 1. get table schema and validate data
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

      // 2. check unique constraints and filter duplicate data
      final uniqueRecords = <Map<String, dynamic>>[];
      for (var record in validRecords) {
        if (await _checkUniqueConstraints(tableName, record)) {
          uniqueRecords.add(record);
        } else {
          Logger.warn('Skip duplicate data: $record',
              label: 'DataStore-batchInsert');
        }
      }

      if (uniqueRecords.isEmpty) {
        Logger.warn('All data are duplicates, batch insert canceled',
            label: 'DataStore-batchInsert');
        return false;
      }

      // 3. get data in write queue (if any)
      final pendingData = fileManager.writeQueue[tableName] ?? [];
      fileManager.writeQueue.remove(tableName); // clear queue

      // 4. merge all data to write
      final allData = [...pendingData, ...uniqueRecords];

      // 5. write to file, cache and index
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

      // 6. async update information
      _updateStatisticsAsync(tableName);

      // 7. async log transaction
      _logTransactionAsync('batchInsert', tableName, {
        'count': allData.length,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });

      return true;
    } catch (e) {
      Logger.error('Batch insert failed: $e', label: 'DataStore-batchInsert');
      return false;
    } finally {
      await _concurrencyManager!.releaseWriteLock(tableName);
    }
  }

  /// async update statistics
  void _updateStatisticsAsync(String tableName) {
    Future(() async {
      try {
        await _statisticsCollector?.collectTableStatistics(tableName);
      } catch (e) {
        Logger.error('Async update statistics failed: $e',
            label: 'DataStore-batchInsert');
      }
    });
  }

  /// async log transaction
  void _logTransactionAsync(String operation, String tableName, dynamic data) {
    Future(() async {
      try {
        await _transactionManager?.logOperation(operation, tableName, data);
      } catch (e) {
        Logger.error('Async log transaction failed: $e',
            label: 'DataStore-batchInsert');
      }
    });
  }

  /// synchronized lock wrapper method
  Future<T> synchronized<T>(Object lock, Future<T> Function() callback) async {
    try {
      await _concurrencyManager?.acquireWriteLock('global');
      return await callback();
    } finally {
      await _concurrencyManager?.releaseWriteLock('global');
    }
  }

  /// load data to cache
  Future<void> _loadDataToCache() async {
    try {
      // 1. load data from base space
      final baseDir = Directory(_config!.getBasePath());
      if (await baseDir.exists()) {
        await _loadPathData(baseDir);
      }

      // 2. load data from global space
      final globalDir = Directory(_config!.getGlobalPath());
      if (await globalDir.exists()) {
        await _loadPathData(globalDir);
      }
    } catch (e) {
      Logger.error('Load data to cache failed: $e',
          label: 'DataStore._loadDataToCache');
    }
  }

  /// load data from specified path
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

        // get file size
        final fileSize = await file.length();

        // only cache small files
        if (fileSize <= _config!.maxTableCacheSize) {
          // use public constant
          final records = await _loadAllRecords(file);
          await _queryExecutor?.queryCacheManager.cacheEntireTable(
            tableName,
            records,
            schema.primaryKey,
          );
        } else {
          await _loadRecentRecords(file, tableName, schema);
          Logger.info(
              'Table $tableName file $fileSize exceeds size limit, cache partial data',
              label: 'DataStore._loadPathData');
        }
      } catch (e) {
        Logger.error('Load table data failed: ${file.path}, error: $e',
            label: 'DataStore._loadPathData');
        continue; // continue loading other tables
      }
    }
  }

  /// load recent records
  Future<void> _loadRecentRecords(
    File file,
    String tableName,
    TableSchema schema,
  ) async {
    final lines = await file.readAsLines();
    final recentLines =
        lines.reversed.take(1000); // only load recent 1000 records

    for (var line in recentLines) {
      if (line.trim().isEmpty) continue;
      final data = jsonDecode(line) as Map<String, dynamic>;
      _queryExecutor?.queryCacheManager.addCachedRecord(tableName, data);
    }

    Logger.info(
        'Table $tableName partially loaded to cache (recent 1000 records)');
  }

  /// load all records
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

  /// extract file name from path
  String _getFileName(String path) {
    final normalizedPath = path.replaceAll('\\', '/');
    final parts = normalizedPath.split('/');
    return parts.last.replaceAll('.dat', '');
  }

  /// check unique constraints
  Future<bool> _checkUniqueConstraints(
      String tableName, Map<String, dynamic> data) async {
    final schema = await getTableSchema(tableName);
    final primaryKey = schema.primaryKey;
    final primaryValue = data[primaryKey];

    // 1. check unique constraints of fields
    for (var field in schema.fields) {
      if (field.unique && field.name != primaryKey) {
        // exclude primary key field
        final value = data[field.name];
        if (value != null) {
          // check if value of unique field already exists
          if (!_uniqueValuesCache.containsKey(tableName)) {
            _uniqueValuesCache[tableName] = {};
          }
          if (!_uniqueValuesCache[tableName]!.containsKey(field.name)) {
            _uniqueValuesCache[tableName]![field.name] = <dynamic>{};

            // initialize cache
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

        // check if value already exists
        if (_uniqueValuesCache[tableName]![field.name]!.contains(value)) {
          Logger.warn(
              'Warning: value $value of field ${field.name} already exists');
          return false;
        }
      }
    }

    // 2. check unique constraints of indexes
    if (!_uniqueValuesCache.containsKey(tableName)) {
      _uniqueValuesCache[tableName] = {
        primaryKey: <dynamic>{},
      };

      // initialize unique index collections
      for (var index in schema.indexes.where((idx) => idx.unique)) {
        _uniqueValuesCache[tableName]![index.fields.first] = <dynamic>{};
      }

      // load all data to cache at once
      final dataFile = File(config.getDataPath(tableName, schema.isGlobal));
      if (await dataFile.exists()) {
        final lines = await dataFile.readAsLines();
        for (var line in lines) {
          if (line.trim().isEmpty) continue;
          final record = jsonDecode(line) as Map<String, dynamic>;

          // collect primary key and unique index values
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

    // 3. check primary key
    if (_uniqueValuesCache[tableName]![primaryKey]!.contains(primaryValue)) {
      Logger.warn('Warning: primary key duplicate: $primaryValue');
      return false;
    }

    // 4. check unique indexes
    for (var index in schema.indexes.where((idx) => idx.unique)) {
      final fieldName = index.fields.first;
      final value = data[fieldName];
      if (value != null &&
          _uniqueValuesCache[tableName]![fieldName]!.contains(value)) {
        Logger.warn(
            'Warning: value $value of unique index ${index.actualIndexName} already exists');
        return false;
      }
    }

    // 5. check values in write queue
    final pendingData = fileManager.writeQueue[tableName] ?? [];
    for (var record in pendingData) {
      // check primary key
      if (record[primaryKey] == primaryValue) {
        Logger.warn(
            'Warning: primary key duplicate in write queue: $primaryValue');
        return false;
      }

      // check unique fields
      for (var field in schema.fields) {
        if (field.unique && field.name != primaryKey) {
          final value = data[field.name];
          if (value != null && record[field.name] == value) {
            Logger.warn(
                'Warning: value $value of field ${field.name} already exists in write queue');
            return false;
          }
        }
      }

      // check unique indexes
      for (var index in schema.indexes.where((idx) => idx.unique)) {
        final fieldName = index.fields.first;
        final value = data[fieldName];
        if (value != null && record[fieldName] == value) {
          Logger.warn(
              'Warning: unique index duplicate in write queue: $fieldName = $value');
          return false;
        }
      }
    }

    // 6. if pass all checks, update cache
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

  /// query by id
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
      Logger.error('Query by id failed: $e', label: 'DataStore.queryById');
      rethrow;
    }
  }

  /// query by field
  Future<List<Map<String, dynamic>>> queryBy(
    String tableName,
    String field,
    dynamic value,
  ) async {
    try {
      final condition = QueryCondition()..where(field, '=', value);

      return await _executeQuery(tableName, condition);
    } catch (e) {
      Logger.error('Query by field failed: $e', label: 'DataStore.queryBy');
      rethrow;
    }
  }

  /// SQL query (convert SQL conditions to QueryCondition)
  Future<List<Map<String, dynamic>>> queryBySql(
    String tableName, {
    String? where,
    List<dynamic>? whereArgs,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    try {
      // parse SQL conditions to QueryCondition
      QueryCondition? condition;
      if (where != null) {
        condition = _parseSqlWhereClause(where, whereArgs);
      }

      // parse order by
      List<String>? orderByList;
      if (orderBy != null) {
        orderByList = orderBy.split(',').map((e) => e.trim()).toList();
      }

      // execute query
      return await _executeQuery(
        tableName,
        condition ?? QueryCondition(),
        orderBy: orderByList,
        limit: limit,
        offset: offset,
      );
    } catch (e) {
      Logger.error('SQL query failed: $e', label: 'DataStore.queryBySql');
      rethrow;
    }
  }

  /// Execute query
  Future<List<Map<String, dynamic>>> _executeQuery(
    String tableName,
    QueryCondition condition, {
    List<String>? orderBy,
    int? limit,
    int? offset,
  }) async {
    // build query plan
    final queryPlan = await _queryOptimizer?.optimize(
      tableName,
      condition.build(),
      orderBy,
    );

    if (queryPlan == null) {
      throw StateError('Query optimizer not initialized');
    }

    // execute query using QueryExecutor
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

  /// Parse SQL where clause to QueryCondition
  QueryCondition _parseSqlWhereClause(String where, List<dynamic>? whereArgs) {
    final condition = QueryCondition();
    if (where.isEmpty) return condition;

    // Replace operators
    where = where.replaceAll('||', 'OR').replaceAll('&&', 'AND');

    // Split by OR
    final orGroups = where.split(RegExp(r'\s+OR\s+', caseSensitive: false));
    var argIndex = 0;

    for (var group in orGroups) {
      // Parse AND conditions in each OR group
      final conditions =
          group.trim().split(RegExp(r'\s+AND\s+', caseSensitive: false));

      for (var condStr in conditions) {
        _parseSingleCondition(condition, condStr.trim(), whereArgs, argIndex);
        argIndex += _countPlaceholders(condStr);
      }

      if (group != orGroups.last) {
        condition.or();
      }
    }

    return condition;
  }

  /// Parse single SQL condition
  void _parseSingleCondition(
    QueryCondition condition,
    String condStr,
    List<dynamic>? whereArgs,
    int startArgIndex,
  ) {
    String? operator;
    for (var op in ['>=', '<=', '!=', '=', '>', '<', 'LIKE', 'IS NOT', 'IS']) {
      if (RegExp('\\s+$op\\s+', caseSensitive: false).hasMatch(condStr)) {
        operator = op.toUpperCase();
        break;
      }
    }

    if (operator == null) return;

    final parts =
        condStr.split(RegExp('\\s+$operator\\s+', caseSensitive: false));
    if (parts.length != 2) return;

    final field = parts[0].trim();
    String valueStr = parts[1].trim();

    // handle value
    dynamic value;
    if (valueStr == '?' &&
        whereArgs != null &&
        startArgIndex < whereArgs.length) {
      // handle parameter placeholder
      value = whereArgs[startArgIndex];
    } else if ((valueStr.startsWith("'") && valueStr.endsWith("'")) ||
        (valueStr.startsWith('"') && valueStr.endsWith('"'))) {
      // handle string value
      value = valueStr.substring(1, valueStr.length - 1);
    } else if (valueStr.toLowerCase() == 'null') {
      // handle NULL value
      value = null;
    } else {
      // try to parse to number
      value = num.tryParse(valueStr) ?? valueStr;
    }

    // add condition
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

  /// Count placeholders
  int _countPlaceholders(String condition) {
    return '?'.allMatches(condition).length;
  }

  /// Switch base space
  Future<bool> switchBaseSpace({String spaceName = 'default'}) async {
    await _ensureInitialized();

    if (_currentSpaceName == spaceName) {
      return true;
    }

    final oldSpaceName = _currentSpaceName;
    _currentSpaceName = spaceName;

    try {
      // Update configuration
      if (_config != null) {
        _config = _config!.copyWith(baseName: _currentSpaceName);
      }

      // Clear caches
      _queryExecutor?.queryCacheManager.onBasePathChanged();
      fileManager.writeQueue.clear();
      _uniqueValuesCache.clear();

      _isSwitchingSpace = true;

      // Reinitialize database
      _isInitialized = false;
      _baseInitialized = false;
      await initialize(dbPath: _config?.dbPath, config: _config);

      // Notify space change
      _notifyBasePathChanged(BasePathChangedEvent(oldSpaceName, spaceName));

      Logger.info('Base space switched: $oldSpaceName -> $spaceName');

      // Clear non-global indexes
      _indexManager?.onBasePathChanged();

      return true;
    } catch (e) {
      // Rollback on failure
      _currentSpaceName = oldSpaceName;
      if (_config != null) {
        _config = _config!.copyWith(baseName: oldSpaceName);
      }
      Logger.error('Space switch failed: $e',
          label: 'DataStore.switchBaseSpace');
      return false;
    } finally {
      _isSwitchingSpace = false;
    }
  }

  /// Notify base path change event
  void _notifyBasePathChanged(BasePathChangedEvent event) {
    _indexManager?.onBasePathChanged();
    _statisticsCollector?.onBasePathChanged(event);
  }

  /// Delete database
  Future<void> deleteDatabase({String? dbPath}) async {
    try {
      final dbDirPath = await getDatabasePath(dbPath: dbPath);
      await close();

      final dbDir = Directory(dbDirPath);
      if (await dbDir.exists()) {
        await dbDir.delete(recursive: true);
        Logger.info('Database deleted: $dbDirPath');
      }

      _indexManager?.onBasePathChanged();
      _queryExecutor?.queryCacheManager.clear();
      _maxIds.clear();
      _maxIdsDirty.clear();
      _uniqueValuesCache.clear();

      _instances.remove(_instanceKey);
    } catch (e) {
      Logger.error('Delete database failed: $e',
          label: 'DataStore.deleteDatabase');
      rethrow;
    }
  }

  /// Add auto-increment ID to write queue
  final Map<String, int> _maxIds = {};
  final Map<String, bool> _maxIdsDirty = {}; // mark if need to write

  /// Update max ID value (only in memory)
  void _updateMaxIdInMemory(String tableName, int id) {
    final currentMaxId = _maxIds[tableName] ?? 0;
    if (id > currentMaxId) {
      _maxIds[tableName] = id;
      _maxIdsDirty[tableName] = true; // mark if need to write
    }
  }

  /// Get next auto-increment ID
  Future<int> _getNextId(String tableName) async {
    final schema = await getTableSchema(tableName);
    if (!_maxIds.containsKey(tableName)) {
      // Load from file on first access
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
    _maxIdsDirty[tableName] = true;

    return nextId;
  }

  /// Flush max IDs to disk
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
          _maxIdsDirty[tableName] = false;
        }
      } catch (e) {
        Logger.error('Write auto-increment ID failed: $e',
            label: 'DataStore-_flushMaxIds');
      }
    }
  }

  /// Key-value store table name
  static const String _kvStoreName = 'kv_store'; // base space key-value store
  static const String _globalKvStoreName =
      'global_kv_store'; // global key-value store

  /// Set key-value pair
  Future<bool> setValue(String key, dynamic value,
      {bool isGlobal = false}) async {
    await _ensureInitialized();

    final tableName = isGlobal ? _globalKvStoreName : _kvStoreName;

    // build data
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
        // build update condition
        final condition = QueryCondition()..where('key', '=', key);
        return await updateInternal(
          tableName,
          data,
          condition,
        );
      }
    } catch (e) {
      Logger.error('Set key-value pair failed: $e',
          label: 'DataStore.setValue');
      return false;
    }
  }

  /// Get key-value pair
  Future<dynamic> getValue(String key, {bool isGlobal = false}) async {
    await _ensureInitialized();

    final tableName = isGlobal ? _globalKvStoreName : _kvStoreName;
    final result = await _executeQuery(
        tableName, QueryCondition()..where('key', '=', key));
    if (result.isEmpty) return null;

    try {
      return jsonDecode(result.first['value']);
    } catch (e) {
      Logger.error('Parse key-value failed: $e', label: 'DataStore.getValue');
      return null;
    }
  }

  /// Remove key-value pair
  Future<bool> removeValue(String key, {bool isGlobal = false}) async {
    await _ensureInitialized();

    final tableName = isGlobal ? _globalKvStoreName : _kvStoreName;
    // build delete condition
    final condition = QueryCondition()..where('key', '=', key);
    await deleteInternal(tableName, condition);
    return true;
  }

  /// Get query optimizer
  QueryOptimizer? getQueryOptimizer() => _queryOptimizer;

  /// Get query executor
  QueryExecutor? getQueryExecutor() => _queryExecutor;

  ConcurrencyManager? get concurrencyManager => _concurrencyManager;
  IndexManager? get indexManager => _indexManager;

  /// Flush auto-increment ID to file
  Future<void> flushMaxIds() async {
    await _flushMaxIds();
  }

  /// Get cache stats
  Map<String, int> getCacheStats() {
    return fileManager.writeQueue
        .map((key, value) => MapEntry(key, value.length));
  }

  /// Get table info
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

  /// Get table record count
  Future<int> _getRecordCount(String tableName) async {
    final schema = await getTableSchema(tableName);
    final dataFile = File(config.getDataPath(tableName, schema.isGlobal));
    if (!await dataFile.exists()) return 0;

    final allRecords = <String, bool>{};

    // 1. Read records from file
    final lines = await dataFile.readAsLines();
    for (var line in lines) {
      if (line.trim().isEmpty) continue;
      final data = jsonDecode(line) as Map<String, dynamic>;
      final primaryKeyValue = data[schema.primaryKey].toString();
      allRecords[primaryKeyValue] = true;
    }

    // 2. Merge records in pending write queue
    final pendingRecords = fileManager.writeQueue[tableName] ?? [];
    for (var record in pendingRecords) {
      final primaryKeyValue = record[schema.primaryKey].toString();
      allRecords[primaryKeyValue] = true;
    }

    return allRecords.length;
  }

  /// Check if it is a global table
  Future<bool> isGlobalTable(String tableName) async {
    final schema = await getTableSchema(tableName);
    return schema.isGlobal;
  }
}
