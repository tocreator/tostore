import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import '../backup/backup_manager.dart';
import '../handler/common.dart';
import '../handler/logger.dart';
import '../model/business_error.dart';
import '../model/migration_config.dart';
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
import 'migration_manager.dart';
import '../integrity/integrity_checker.dart';

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
  final List<TableSchema> _schemas;

  bool _baseInitialized = false;
  bool _isSwitchingSpace = false;

  bool get isInitialized => _isInitialized;

  /// Platform-specific path separator
  static final String separator = Platform.isWindows ? '\\' : '/';

  /// Join path components
  String joinPath(List<String> components) {
    return components.join(separator);
  }

  /// Get file name without extension
  String getFileNameWithoutExtension(String path) {
    final name = path.split(separator).last;
    final dotIndex = name.lastIndexOf('.');
    return dotIndex == -1 ? name : name.substring(0, dotIndex);
  }

  /// Get directory name
  String getDirName(String path) {
    final parts = path.split(separator);
    parts.removeLast();
    return parts.join(separator);
  }

  /// Get base name
  String getBaseName(String path) {
    return path.split(separator).last;
  }

  /// Get extension
  String getExtension(String path) {
    final name = getBaseName(path);
    final dotIndex = name.lastIndexOf('.');
    return dotIndex == -1 ? '' : name.substring(dotIndex);
  }

  /// Normalize path
  String normalizePath(String path) {
    final parts = path.split(RegExp(r'[/\\]'));
    final normalized = <String>[];

    for (var part in parts) {
      if (part == '.' || part.isEmpty) continue;
      if (part == '..') {
        if (normalized.isNotEmpty) normalized.removeLast();
        continue;
      }
      normalized.add(part);
    }

    return normalized.join(separator);
  }

  /// Create instance with configuration
  factory DataStoreImpl({
    String? dbPath,
    DataStoreConfig? config,
    int version = 1,
    List<TableSchema> schemas = const [],
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
        schemas,
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
    this._schemas,
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
      final versionFile = File(pathJoin(config.dbPath, 'version'));
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
    final versionFile = File(pathJoin(config.dbPath, 'version'));
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
  MigrationManager? _migrationManager;
  IntegrityChecker? _integrityChecker;

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
      return pathJoin(dbPath, 'db');
    }
    final appPath = await getPathApp();
    return pathJoin(appPath, 'db');
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
      _migrationManager = MigrationManager(this);
      _integrityChecker = IntegrityChecker(this);

      await Directory(dbPath).create(recursive: true);

      _queryOptimizer = QueryOptimizer(this);
      _queryExecutor = QueryExecutor(this, _indexManager!);

      await _recoveryIncompleteTransactions();

      _baseInitialized = true;
      await _startSetupAndUpgrade();

      await _loadDataToCache();

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
        // Create system tables
        await createTable(
          const TableSchema(
            name: _kvStoreName,
            primaryKey: 'key',
            autoIncrement: false,
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
          const TableSchema(
            name: _globalKvStoreName,
            primaryKey: 'key',
            autoIncrement: false,
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

        // Create user tables
        if (_schemas.isNotEmpty) {
          for (var schema in _schemas) {
            await createTable(schema);
          }
        }

        await _onCreate?.call(this);

        if (_version > 0) {
          await setVersion(_version);
        }
      } else if (oldVersion < _version) {
        if (_schemas.isNotEmpty) {
          // Get existing tables
          final existingTables = await getTableNames();

          // Remove tables that are no longer in schemas
          final newTableNames = _schemas.map((s) => s.name).toSet();
          for (var tableName in existingTables) {
            // Skip system tables
            if (tableName == _kvStoreName || tableName == _globalKvStoreName) {
              continue;
            }

            if (!newTableNames.contains(tableName)) {
              Logger.info(
                'Dropping removed table: $tableName',
                label: 'DataStoreImpl._startSetupAndUpgrade',
              );
              await dropTable(tableName);
            }
          }
          await autoMigrate(
            oldVersion: oldVersion,
            newVersion: _version,
            schemas: _schemas,
          );
        } else if (_onUpgrade != null) {
          await _onUpgrade.call(this, oldVersion, _version);
        }
        await setVersion(_version);
      } else if (oldVersion > _version) {
        await _onDowngrade?.call(this, oldVersion, _version);
        await setVersion(_version);
      }

      await _onOpen?.call(this);
    } catch (e, stack) {
      Logger.error(
        'Database setup/upgrade failed: $e\n$stack',
        label: 'DataStoreImpl._startSetupAndUpgrade',
      );
      rethrow;
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
      _integrityChecker = null;

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

  /// Create a single table
  Future<void> createTable(TableSchema schema) async {
    if (!_baseInitialized) {
      await _ensureInitialized();
    }

    try {
      var schemaValid = schema;
      // table name cannot be empty
      if (schema.name.isEmpty) {
        throw const BusinessError(
          'Table name cannot be empty',
          type: BusinessErrorType.schemaError,
        );
      }

      // table name must start with letter and contain only letters, numbers and underscore
      final tableNameRegex = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*$');
      if (!tableNameRegex.hasMatch(schema.name)) {
        throw BusinessError(
          'Invalid table name: ${schema.name}, table name must start with letter and contain only letters, numbers and underscore',
          type: BusinessErrorType.schemaError,
        );
      }

      // check if table already exists
      final globalSchemaFile = File(config.getSchemaPath(schema.name, true));
      final baseSchemaFile = File(config.getSchemaPath(schema.name, false));

      if (await globalSchemaFile.exists()) {
        Logger.warn('Table ${schema.name} already exists in global space',
            label: 'DataStore.createTable');
        return;
      }
      if (await baseSchemaFile.exists()) {
        Logger.warn('Table ${schema.name} already exists in base space',
            label: 'DataStore.createTable');
        return;
      }

      // create target directory
      final targetPath =
          schema.isGlobal ? config.getGlobalPath() : config.getBasePath();
      final targetDir = Directory(targetPath);
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }

      // get schema file path
      final schemaFile = schema.isGlobal ? globalSchemaFile : baseSchemaFile;

      await _concurrencyManager!.acquireWriteLock(schema.name);
      try {
        final primaryField =
            schema.fields.firstWhere((f) => f.name == schema.primaryKey);

        // auto increment only supports integer primary key
        if (schema.autoIncrement && primaryField.type != DataType.integer) {
          Logger.warn(
            'Auto increment is disabled for table ${schema.name}, auto increment only supports integer primary key, auto increment is set to false',
            label: 'DataStore.createTable',
          );
          schemaValid = schema.copyWith(autoIncrement: false);
        }

        // validate table structure
        await _validateSchema(schemaValid);

        // write schema file
        await schemaFile.writeAsString(jsonEncode(schemaValid));

        // create primary key index
        await _indexManager?.createPrimaryIndex(schema.name, schema.primaryKey);

        // create other indexes
        for (var index in schema.indexes) {
          await _indexManager?.createIndex(schema.name, index);
        }

        // if auto increment, initialize id file
        if (schemaValid.autoIncrement) {
          final maxIdFile =
              File(config.getAutoIncrementPath(schema.name, schema.isGlobal));
          await maxIdFile.writeAsString('0');
        }

        Logger.info(
          'Table ${schema.name} created successfully${schema.isGlobal ? ' (global)' : ' (base)'}',
          label: 'DataStore.createTable',
        );

        // cache schema
        _queryExecutor?.queryCacheManager.cacheSchema(schema.name, schemaValid);
      } catch (e) {
        // cleanup schema file if creation failed
        if (await schemaFile.exists()) {
          await schemaFile.delete();
        }
        Logger.error('Create table failed: $e', label: 'DataStore.createTable');
        rethrow;
      } finally {
        await _concurrencyManager!.releaseWriteLock(schema.name);
      }
    } catch (e) {
      Logger.error('Create table failed: $e', label: 'DataStore.createTable');
      rethrow;
    }
  }

  /// Create multiple tables
  Future<void> createTables(List<TableSchema> schemas) async {
    for (var schema in schemas) {
      await createTable(schema);
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
      final allRecords = await fileManager.readRecords(tableName);
      if (allRecords.isNotEmpty) {
        try {
          final records = allRecords.values.toList();
          final lastRecord = records.last;
          if (lastRecord[primaryKeyField] == primaryKeyValue) {
            records.removeLast();
            await fileManager.writeRecords(
              tableName: tableName,
              records: records,
              isSchemaChanged: false,
            );
          }
        } catch (e) {
          Logger.error('Failed to rollback last record: $e',
              label: 'DataStore._rollbackTransaction');
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
      final primaryKey = schema.primaryKey;
      var result = <String, dynamic>{};

      // get primary key field
      final primaryField =
          schema.fields.firstWhere((f) => f.name == primaryKey);

      // 1. handle primary key
      if (!data.containsKey(primaryKey) || data[primaryKey] == null) {
        // auto increment only supports integer primary key
        if (schema.autoIncrement && primaryField.type != DataType.integer) {
          throw const BusinessError(
            'Auto increment only supports integer primary key',
            type: BusinessErrorType.schemaError,
          );
        }

        if (schema.autoIncrement) {
          final nextId = await _getNextId(tableName);
          result[primaryKey] = nextId;
        } else {
          throw const BusinessError(
            'Primary key value cannot be null',
            type: BusinessErrorType.invalidData,
          );
        }
      } else {
        final providedId = data[primaryKey];

        // check primary key type
        if (primaryField.type == DataType.text && providedId is! String) {
          throw const BusinessError(
            'Primary key must be text type',
            type: BusinessErrorType.typeError,
          );
        } else if (primaryField.type == DataType.integer &&
            providedId is! int) {
          throw const BusinessError(
            'Primary key must be integer type',
            type: BusinessErrorType.typeError,
          );
        }

        // only integer type primary key can auto increment
        if (providedId is int && schema.autoIncrement) {
          _updateMaxIdInMemory(tableName, providedId);
        }
        result[primaryKey] = providedId;
      }

      // 2. fill default value and null value
      for (var field in schema.fields) {
        if (field.name == primaryKey) {
          continue;
        }

        if (!data.containsKey(field.name)) {
          if (field.defaultValue != null) {
            final convertedDefault =
                _convertValue(field.defaultValue, field.type);
            if (convertedDefault == null) {
              Logger.warn(
                'Invalid default value for field ${field.name}',
                label: 'DataStore._validateAndProcessData',
              );
              return null;
            }
            result[field.name] = convertedDefault;
          } else if (!field.nullable) {
            Logger.warn(
              'Field ${field.name} cannot be null and has no default value',
              label: 'DataStore._validateAndProcessData',
            );
            return null;
          } else {
            result[field.name] = null;
          }
        } else {
          final value = data[field.name];

          // check non-null constraint
          if (!field.nullable && value == null) {
            Logger.warn(
              'Field ${field.name} cannot be null',
              label: 'DataStore._validateAndProcessData',
            );
            return null;
          }

          // if value is not null, try to convert type
          if (value != null) {
            if (_isValidDataType(value, field.type)) {
              result[field.name] = value; // type match, use directly
            } else {
              try {
                // try to convert type
                final convertedValue = _convertValue(value, field.type);
                if (convertedValue == null) {
                  Logger.warn(
                    'Failed to convert value for field ${field.name}: $value to ${field.type}',
                    label: 'DataStore._validateAndProcessData',
                  );
                  return null;
                }
                result[field.name] = convertedValue;
              } catch (e) {
                Logger.warn(
                  'Failed to convert value for field ${field.name}: $value to ${field.type}: $e',
                  label: 'DataStore._validateAndProcessData',
                );
                return null;
              }
            }
          } else {
            result[field.name] = null;
          }
        }

        // check max length
        if (result[field.name] != null && field.maxLength != null) {
          if (result[field.name] is String &&
              (result[field.name] as String).length > field.maxLength!) {
            Logger.warn('Warning: field ${field.name} exceeds max length');
            result[field.name] =
                (result[field.name] as String).substring(0, field.maxLength!);
          }
        }
      }

      return _prepareDataForStorage(result);
    } catch (e) {
      Logger.error('Data validation failed: $e',
          label: 'DataStore-_validateAndProcessData');
      return null;
    }
  }

  /// Convert data for storage
  Map<String, dynamic> _prepareDataForStorage(Map<String, dynamic> data) {
    return data.map((key, value) {
      if (value is DateTime) {
        return MapEntry(key, value.toIso8601String());
      }
      return MapEntry(key, value);
    });
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
      case DataType.blob:
        return Uint8List(0);
      case DataType.boolean:
        return false;
      case DataType.datetime:
        return DateTime.now().toIso8601String();
      case DataType.array:
        return [];
    }
  }

  /// Check if value matches data type
  bool _isValidDataType(dynamic value, DataType type) {
    if (value == null) return true;
    switch (type) {
      case DataType.integer:
        return value is int; // only allow int type
      case DataType.double:
        return value is double ||
            value is int; // allow int to be converted to double
      case DataType.text:
        return value is String; // only allow string type
      case DataType.blob:
        return value is Uint8List; // only allow binary data
      case DataType.boolean:
        return value is bool; // only allow boolean type
      case DataType.datetime:
        if (value is String) {
          try {
            DateTime.parse(value);
            return true;
          } catch (_) {
            return false;
          }
        }
        return false; // DateTime对象不是有效的存储格式
      case DataType.array:
        return value is List; // only allow list type
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

  /// Validate schema
  Future<bool> _validateSchema(TableSchema schema) async {
    try {
      // get primary key field
      final primaryField = schema.fields.firstWhere(
        (f) => f.name == schema.primaryKey,
        orElse: () => throw const BusinessError(
          'Primary key field not found in fields',
          type: BusinessErrorType.schemaError,
        ),
      );

      // validate auto increment setting
      if (schema.autoIncrement && primaryField.type != DataType.integer) {
        throw const BusinessError(
          'Auto increment only supports integer primary key',
          type: BusinessErrorType.schemaError,
        );
      }

      // validate primary key cannot be null
      if (primaryField.nullable) {
        throw const BusinessError(
          'Primary key field cannot be nullable',
          type: BusinessErrorType.schemaError,
        );
      }

      // validate field name uniqueness
      final fieldNames = schema.fields.map((f) => f.name).toList();
      if (fieldNames.toSet().length != fieldNames.length) {
        throw const BusinessError(
          'Duplicate field names found',
          type: BusinessErrorType.schemaError,
        );
      }

      // validate index fields exist
      for (var index in schema.indexes) {
        for (var field in index.fields) {
          if (!schema.fields.any((f) => f.name == field)) {
            throw BusinessError(
              'Index field $field not found in table fields',
              type: BusinessErrorType.schemaError,
            );
          }
        }
      }

      // validate field name format
      final fieldNameRegex = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*$');
      for (var field in schema.fields) {
        if (!fieldNameRegex.hasMatch(field.name)) {
          throw BusinessError(
            'Invalid field name: ${field.name}',
            type: BusinessErrorType.schemaError,
          );
        }
      }

      return true;
    } catch (e) {
      Logger.error('Schema validation failed: $e',
          label: 'DataStore._validateSchema');
      rethrow;
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
    final schema = await getTableSchema(tableName);
    final dataFile = File(config.getDataPath(tableName, schema.isGlobal));
    final checksumFile =
        File(config.getChecksumPath(tableName, schema.isGlobal));

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
        final schemaJson = tableData['schema'] as Map<String, dynamic>;
        if (!schemaJson.containsKey('name')) {
          schemaJson['name'] = tableName;
        }
        final schema = TableSchema.fromJson(schemaJson);
        await createTable(schema);

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
      var result = <String, dynamic>{};
      final primaryKey = schema.primaryKey;

      // Process each field
      for (var field in schema.fields) {
        // Skip primary key
        if (field.name == primaryKey) {
          continue;
        }

        // Skip if field not in update data
        if (!data.containsKey(field.name)) {
          continue;
        }

        final value = data[field.name];

        // Check non-null constraint
        if (!field.nullable && value == null) {
          Logger.warn(
            'Field ${field.name} cannot be null',
            label: 'DataStore._validateAndProcessUpdateData',
          );
          return null;
        }

        // If value is not null, validate and convert type
        if (value != null) {
          if (_isValidDataType(value, field.type)) {
            result[field.name] = value;
          } else {
            try {
              final convertedValue = _convertValue(value, field.type);
              if (convertedValue == null) {
                Logger.warn(
                  'Failed to convert value for field ${field.name}: $value to ${field.type}',
                  label: 'DataStore._validateAndProcessUpdateData',
                );
                return null;
              }
              result[field.name] = convertedValue;
            } catch (e) {
              Logger.warn(
                'Failed to convert value for field ${field.name}: $value to ${field.type}: $e',
                label: 'DataStore._validateAndProcessUpdateData',
              );
              return null;
            }
          }
        } else {
          result[field.name] = null;
        }

        // Check max length constraint
        if (result[field.name] != null && field.maxLength != null) {
          if (result[field.name] is String &&
              (result[field.name] as String).length > field.maxLength!) {
            Logger.warn('Warning: field ${field.name} exceeds max length');
            result[field.name] =
                (result[field.name] as String).substring(0, field.maxLength!);
          }
        }
      }

      return _prepareDataForStorage(result);
    } catch (e) {
      Logger.error('Update data validation failed: $e',
          label: 'DataStore._validateAndProcessUpdateData');
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
      final schema = await getTableSchema(tableName);
      final dataFile = File(config.getDataPath(tableName, schema.isGlobal));
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

      // Read all records and filter out deleted ones
      final allRecords = await fileManager.readRecords(tableName);
      final remainingRecords = allRecords.values.where((record) {
        return !recordsToDelete
            .any((r) => r[schema.primaryKey] == record[schema.primaryKey]);
      }).toList();

      // Write remaining records using fileManager
      await fileManager.writeRecords(
        tableName: tableName,
        records: remainingRecords,
        isSchemaChanged: false,
      );

      // update statistics
      await _statisticsCollector?.collectTableStatistics(tableName);

      await _transactionManager!.commit(transaction);
      return true;
    } catch (e) {
      Logger.info('Delete failed: $e', label: 'DataStore-delete');
      await _transactionManager!.rollback(transaction);
      // clear cache, ensure data consistency
      return false;
    } finally {
      await _concurrencyManager!.releaseWriteLock(tableName);
    }
  }

  /// drop table
  Future<void> dropTable(String tableName) async {
    try {
      await _concurrencyManager!.acquireWriteLock(tableName);
      final schema = await getTableSchema(tableName);

      // delete data file
      final dataFile = File(config.getDataPath(tableName, schema.isGlobal));
      if (await dataFile.exists()) {
        await dataFile.delete();
      }

      // delete schema file
      final schemaFile = File(config.getSchemaPath(tableName, schema.isGlobal));
      if (await schemaFile.exists()) {
        await schemaFile.delete();

        // delete index files
        for (var index in schema.indexes) {
          final indexFile = File(config.getIndexPath(
            tableName,
            index.actualIndexName,
            schema.isGlobal,
          ));
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

  /// Get table schema
  Future<TableSchema> getTableSchema(String tableName) async {
    try {
      // 1. Try to get from cache first
      final cachedSchema =
          _queryExecutor?.queryCacheManager.getSchema(tableName);
      if (cachedSchema != null) {
        return cachedSchema;
      }

      // 2. Load schema from file
      final globalSchemaFile = File(config.getSchemaPath(tableName, true));
      final baseSchemaFile = File(config.getSchemaPath(tableName, false));

      TableSchema? schema;
      bool isGlobal = false;

      if (await globalSchemaFile.exists()) {
        final schemaJson = await globalSchemaFile.readAsString();
        final schemaMap = jsonDecode(schemaJson) as Map<String, dynamic>;
        // if name is not in json, add schemaPath
        if (!schemaMap.containsKey('name')) {
          schemaMap['_schemaPath'] = config.getSchemaPath(tableName, true);
        }
        schema = TableSchema.fromJson(schemaMap);
        isGlobal = true;
      } else if (await baseSchemaFile.exists()) {
        final schemaJson = await baseSchemaFile.readAsString();
        final schemaMap = jsonDecode(schemaJson) as Map<String, dynamic>;
        // if name is not in json, add schemaPath
        if (!schemaMap.containsKey('name')) {
          schemaMap['_schemaPath'] = config.getSchemaPath(tableName, false);
        }
        schema = TableSchema.fromJson(schemaMap);
      }

      // Validate schema name matches table name
      if (schema?.name != tableName) {
        Logger.error(
          'Schema name (${schema?.name}) does not match table name ($tableName)',
          label: "DataStoreImpl.getTableSchema",
        );
      }

      if (schema != null) {
        // 3. Check and adjust auto increment setting for text primary key
        final primaryField =
            schema.fields.firstWhere((f) => f.name == schema?.primaryKey);
        if (schema.autoIncrement && primaryField.type != DataType.integer) {
          Logger.warn(
            'Auto increment was disabled for table ${schema.name}, auto increment only supports integer primary key, auto increment is set to false',
            label: 'DataStore.getTableSchema',
          );

          // Create adjusted schema
          final adjustedSchema = schema.copyWith(autoIncrement: false);

          // Update schema file
          final schemaFile = isGlobal ? globalSchemaFile : baseSchemaFile;
          await schemaFile.writeAsString(jsonEncode(adjustedSchema));

          // Update cache
          _queryExecutor?.queryCacheManager
              .cacheSchema(tableName, adjustedSchema);

          return adjustedSchema;
        }

        // Cache and return original schema
        _queryExecutor?.queryCacheManager.cacheSchema(tableName, schema);
        return schema;
      }

      // Return empty schema if not found
      return TableSchema(
        name: tableName,
        primaryKey: '',
        fields: const [],
      );
    } catch (e) {
      Logger.error(
        'Failed to get table schema: $e',
        label: 'DataStore.getTableSchema',
      );
      return TableSchema(
        name: tableName,
        fields: [],
        indexes: [],
        primaryKey: '',
        isGlobal: false,
      );
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
    final parts = path.split(Platform.pathSeparator);
    final fileName = parts.last;
    return fileName.replaceAll('.dat', '');
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
          if (record[primaryKey] != null) {
            _uniqueValuesCache[tableName]![primaryKey]!.add(record[primaryKey]);
          }
          for (var index in schema.indexes.where((idx) => idx.unique)) {
            final fieldName = index.fields.first;
            if (record[fieldName] != null) {
              _uniqueValuesCache[tableName]![fieldName]!.add(record[fieldName]);
            }
          }
        }
      }
    }
    // initialize primary key cache
    _uniqueValuesCache[tableName]![primaryKey] ??= <dynamic>{};
    // 3. check primary key
    if (_uniqueValuesCache[tableName]![primaryKey]!.contains(primaryValue)) {
      Logger.warn('Warning: primary key duplicate: $primaryValue');
      return false;
    }
    // 4. check unique indexes
    for (var index in schema.indexes.where((idx) => idx.unique)) {
      final fieldName = index.fields.first;
      final value = data[fieldName];
      _uniqueValuesCache[tableName]![fieldName] ??= <dynamic>{};
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
    _uniqueValuesCache[tableName]![primaryKey] ??= <dynamic>{};
    _uniqueValuesCache[tableName]![primaryKey]!.add(primaryValue);
    for (var field in schema.fields) {
      if (field.unique && field.name != primaryKey) {
        final value = data[field.name];
        if (value != null) {
          _uniqueValuesCache[tableName]![field.name] ??= <dynamic>{};
          _uniqueValuesCache[tableName]![field.name]!.add(value);
        }
      }
    }
    for (var index in schema.indexes.where((idx) => idx.unique)) {
      final fieldName = index.fields.first;
      final value = data[fieldName];
      if (value != null) {
        _uniqueValuesCache[tableName]![fieldName] ??= <dynamic>{};
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

    final currentId = _maxIds[tableName] ?? 0;
    final nextId = currentId + 1;
    _maxIds[tableName] = nextId;
    _maxIdsDirty[tableName] = true;

    return nextId;
  }

  /// Flush max IDs to disk
  Future<void> _flushMaxIds() async {
    try {
      for (var entry in _maxIdsDirty.entries) {
        if (!entry.value) continue;

        final tableName = entry.key;
        final maxId = _maxIds[tableName] ?? 0;
        final schema = await getTableSchema(tableName);
        final maxIdPath =
            config.getAutoIncrementPath(tableName, schema.isGlobal);

        await File(maxIdPath).writeAsString(maxId.toString());
        _maxIdsDirty[tableName] = false;
      }
    } catch (e) {
      Logger.error(
        'Failed to flush max IDs: $e',
        label: 'DataStoreImpl._flushMaxIds',
      );
    }
  }

  /// Key-value store table name
  static const String _kvStoreName = 'kv_store';
  static const String _globalKvStoreName = 'global_kv_store';

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

  /// Add field to table
  Future<void> addField(
    String tableName,
    FieldSchema field,
    Transaction? txn,
  ) async {
    final schema = await getTableSchema(tableName);

    // Check if field already exists
    if (schema.fields.any((f) => f.name == field.name)) {
      Logger.warn(
        'Field ${field.name} already exists in table $tableName',
        label: "DataStore.addField",
      );
      return;
    }

    // Add field to schema
    final newFields = [...schema.fields, field];
    final newSchema = schema.copyWith(fields: newFields);

    // Update schema file
    await updateTableSchema(tableName, newSchema);
  }

  /// Drop field from table
  Future<void> removeField(
    String tableName,
    String fieldName,
    Transaction? txn,
  ) async {
    final schema = await getTableSchema(tableName);

    // Check if field exists
    if (!schema.fields.any((f) => f.name == fieldName)) {
      Logger.warn(
        'Field $fieldName not found in table $tableName',
        label: "DataStore.removeField",
      );
      return;
    }

    // Remove field from schema
    final newFields = schema.fields.where((f) => f.name != fieldName).toList();
    final newSchema = schema.copyWith(fields: newFields);

    // Update schema file
    await updateTableSchema(tableName, newSchema);
  }

  /// Rename field
  Future<void> renameField(
    String tableName,
    String oldName,
    String newName,
    Transaction? txn,
  ) async {
    try {
      final schema = await getTableSchema(tableName);

      // Update schema
      final fields = List<FieldSchema>.from(schema.fields);
      final oldFieldIndex = fields.indexWhere((f) => f.name == oldName);
      if (oldFieldIndex == -1) {
        Logger.warn(
          'Field $oldName not found in table $tableName',
          label: "DataStore.renameField",
        );
        return;
      }
      fields[oldFieldIndex] = fields[oldFieldIndex].copyWith(name: newName);

      final newSchema = schema.copyWith(fields: fields);
      await updateTableSchema(tableName, newSchema);
    } catch (e) {
      Logger.error(
        'Failed to rename field: $e',
        label: 'DataStoreImpl.renameField',
      );
      rethrow;
    }
  }

  /// Modify field
  Future<void> modifyField(
    String tableName,
    String fieldName,
    FieldSchema newField,
    Transaction? txn,
  ) async {
    try {
      final schema = await getTableSchema(tableName);

      // Check if field exists
      final oldField = schema.fields.firstWhere(
        (f) => f.name == fieldName,
        orElse: () {
          Logger.warn(
            'Field $fieldName not found in table $tableName',
            label: "DataStore.modifyField",
          );
          return FieldSchema(name: fieldName, type: DataType.text);
        },
      );

      newField = oldField.copyWith(
        type: newField.type != DataType.text ? newField.type : null,
        nullable: newField.nullable != true ? newField.nullable : null,
        defaultValue: newField.defaultValue,
        unique: newField.unique != false ? newField.unique : null,
        comment: newField.comment,
      );

      // Update schema
      final fields = List<FieldSchema>.from(schema.fields);
      final fieldIndex = fields.indexWhere((f) => f.name == fieldName);
      fields[fieldIndex] = newField;

      final newSchema = schema.copyWith(fields: fields);
      await updateTableSchema(tableName, newSchema);
    } catch (e) {
      Logger.error(
        'Failed to modify field: $e',
        label: 'DataStoreImpl.modifyField',
      );
      rethrow;
    }
  }

  /// Add index to table
  Future<void> addIndex(
    String tableName,
    IndexSchema index,
    Transaction? txn,
  ) async {
    try {
      final schema = await getTableSchema(tableName);

      // Check if index already exists
      if (schema.indexes.any((i) => i.indexName == index.indexName)) {
        Logger.warn(
          'Index ${index.indexName} already exists in table $tableName',
          label: "DataStore.addIndex",
        );
        return;
      }

      // Add index to schema
      final newIndexes = [...schema.indexes, index];
      final newSchema = schema.copyWith(indexes: newIndexes);

      // Create index file and build index
      await _indexManager?.createIndex(tableName, index);
      await _buildIndex(tableName, index);

      // Update schema file
      await updateTableSchema(tableName, newSchema);
      // Invalidate caches
      _invalidateTableCaches(tableName);
    } catch (e) {
      Logger.error(
        'Failed to add index: $e',
        label: 'DataStoreImpl.addIndex',
      );
      rethrow;
    }
  }

  /// Drop index from table
  Future<void> removeIndex(
    String tableName,
    String indexName,
    Transaction? txn,
  ) async {
    try {
      final schema = await getTableSchema(tableName);

      // Check if index exists
      if (!schema.indexes.any((i) => i.indexName == indexName)) {
        Logger.warn(
          'Index $indexName not found in table $tableName',
          label: "DataStore.removeIndex",
        );
        return;
      }

      // Remove index from schema
      final newIndexes =
          schema.indexes.where((i) => i.indexName != indexName).toList();
      final newSchema = schema.copyWith(indexes: newIndexes);

      // Remove index file
      await _removeIndexFile(tableName, indexName);

      // Update schema file
      await updateTableSchema(tableName, newSchema);
      // Invalidate caches
      _invalidateTableCaches(tableName);
    } catch (e) {
      Logger.error(
        'Failed to remove index: $e',
        label: 'DataStoreImpl.removeIndex',
      );
      rethrow;
    }
  }

  /// Update table schema
  Future<void> updateTableSchema(
    String tableName,
    TableSchema schema,
  ) async {
    try {
      final schemaPath = config.getSchemaPath(tableName, schema.isGlobal);
      final schemaFile = File(schemaPath);

      await schemaFile.writeAsString(jsonEncode(schema.toJson()));

      // Update cache
      _queryExecutor?.queryCacheManager.cacheSchema(tableName, schema);
    } catch (e) {
      Logger.error(
        'Failed to update schema: $e',
        label: 'DataStoreImpl._updateTableSchema',
      );
      rethrow;
    }
  }

  /// Rename table
  Future<void> renameTable(
    String oldName,
    String newName,
    Transaction? txn,
  ) async {
    try {
      // Get original schema first to preserve isGlobal setting
      final schema = await getTableSchema(oldName);
      final isGlobal = schema.isGlobal;

      // Check if new name is available
      if (await _tableExists(newName)) {
        Logger.warn(
          'Table $newName already exists',
          label: "DataStore.renameTable",
        );
        return;
      }

      // Update schema name first
      final newSchema = schema.copyWith(name: newName);
      await updateTableSchema(newName, newSchema);

      // Rename all table files
      await _renameTableFiles(oldName, newName, isGlobal);

      // Remove old schema
      await _removeTableSchema(oldName);

      // Update caches
      _invalidateTableCaches(oldName);
      _queryExecutor?.queryCacheManager.cacheSchema(newName, newSchema);
    } catch (e) {
      Logger.error(
        'Failed to rename table: $e',
        label: 'DataStoreImpl.renameTable',
      );
      rethrow;
    }
  }

  Future<void> _removeTableSchema(String tableName) async {
    final schema = await getTableSchema(tableName);
    final schemaPath = config.getSchemaPath(tableName, schema.isGlobal);
    final schemaFile = File(schemaPath);
    if (await schemaFile.exists()) {
      await schemaFile.delete();
    }
    _invalidateTableCaches(tableName);
  }

  /// Build index for table
  Future<void> _buildIndex(
    String tableName,
    IndexSchema index,
  ) async {
    try {
      final schema = await getTableSchema(tableName);
      final records = await queryByMap(tableName);

      // Build index entries
      for (var record in records) {
        final values = <dynamic>[];
        for (var field in index.fields) {
          values.add(record[field]);
        }

        final value = values.length == 1 ? values.first : values;
        await _indexManager?.addIndexEntry(
          tableName,
          index.actualIndexName,
          value,
          record[schema.primaryKey].toString(),
        );
      }
    } catch (e) {
      Logger.error(
        'Failed to build index: $e',
        label: 'DataStoreImpl._buildIndex',
      );
      rethrow;
    }
  }

  Future<void> _removeIndexFile(
    String tableName,
    String indexName,
  ) async {
    try {
      final schema = await getTableSchema(tableName);
      final indexPath = config.getIndexPath(
        tableName,
        indexName,
        schema.isGlobal,
      );
      final indexFile = File(indexPath);

      if (await indexFile.exists()) {
        await indexFile.delete();
      }

      // Invalidate index cache
      _indexManager?.invalidateCache(tableName, indexName);
    } catch (e) {
      Logger.error(
        'Failed to remove index file: $e',
        label: 'DataStoreImpl._removeIndexFile',
      );
      rethrow;
    }
  }

  /// Rename table files
  Future<void> _renameTableFiles(
    String oldName,
    String newName,
    bool isGlobal,
  ) async {
    try {
      // Rename data file
      final oldDataPath = config.getDataPath(oldName, isGlobal);
      final newDataPath = config.getDataPath(newName, isGlobal);
      if (await File(oldDataPath).exists()) {
        await File(oldDataPath).rename(newDataPath);
      }

      // Rename index files
      final schema = await getTableSchema(newName);
      for (var index in schema.indexes) {
        final indexName = index.actualIndexName;
        final oldIndexPath = config.getIndexPath(oldName, indexName, isGlobal);
        final newIndexPath = config.getIndexPath(newName, indexName, isGlobal);
        if (await File(oldIndexPath).exists()) {
          await File(oldIndexPath).rename(newIndexPath);
        }
      }

      // Rename auto-increment file
      if (schema.autoIncrement) {
        final oldAutoIncrementPath =
            config.getAutoIncrementPath(oldName, isGlobal);
        final newAutoIncrementPath =
            config.getAutoIncrementPath(newName, isGlobal);
        if (await File(oldAutoIncrementPath).exists()) {
          await File(oldAutoIncrementPath).rename(newAutoIncrementPath);
        }
      }
    } catch (e) {
      Logger.error(
        'Failed to rename table files: $e',
        label: 'DataStoreImpl._renameTableFiles',
      );
      rethrow;
    }
  }

  /// Auto migrate database to new version
  Future<void> autoMigrate({
    required int oldVersion,
    required int newVersion,
    required List<TableSchema> schemas,
    MigrationConfig? config,
  }) async {
    try {
      final migrationConfig = config ?? const MigrationConfig();

      // Backup if configured
      if (migrationConfig.backupBeforeMigrate) {
        await backup();
      }

      // Validate schemas and adjust auto increment for text primary keys
      var adjustedSchemas = <TableSchema>[];
      for (var schema in schemas) {
        var schemaValid = schema;
        final primaryField =
            schema.fields.firstWhere((f) => f.name == schema.primaryKey);

        // auto increment only supports integer primary key
        if (schema.autoIncrement && primaryField.type != DataType.integer) {
          Logger.warn(
            'Auto increment is disabled for table ${schema.name}, auto increment only supports integer primary key,auto increment is set to false',
            label: 'DataStore.autoMigrate',
          );
          schemaValid = schema.copyWith(autoIncrement: false);
        }

        await _validateSchema(schemaValid);
        adjustedSchemas.add(schemaValid);
      }

      // Execute migration in transaction
      await transaction((txn) async {
        await _migrationManager?.migrate(
          oldVersion,
          newVersion,
          adjustedSchemas,
          batchSize: migrationConfig.batchSize,
        );
        await setVersion(newVersion);
      });

      // Validate after migration if configured
      if (migrationConfig.validateAfterMigrate) {
        final isValid =
            await _validateMigration(adjustedSchemas); // use adjusted schemas
        if (!isValid && migrationConfig.strictMode) {
          throw const BusinessError(
            'Migration validation failed',
            type: BusinessErrorType.migrationError,
          );
        }
      }

      Logger.info(
        'Auto migration completed successfully',
        label: 'DataStoreImpl.autoMigrate',
      );
    } catch (e, stack) {
      Logger.error(
        'Auto migration failed: $e\n$stack',
        label: 'DataStoreImpl.autoMigrate',
      );
      rethrow;
    }
  }

  /// Validate migration result
  Future<bool> _validateMigration(List<TableSchema> schemas) async {
    try {
      if (_integrityChecker == null) {
        Logger.error(
          'IntegrityChecker not initialized',
          label: 'DataStoreImpl._validateMigration',
        );
        return false;
      }

      for (var schema in schemas) {
        if (!await _integrityChecker!.validateTableStructure(
          schema.name,
          schema,
          config,
        )) {
          return false;
        }
        if (!await _integrityChecker!.validateTableData(
          schema.name,
          schema,
          config,
        )) {
          return false;
        }
      }
      return true;
    } catch (e) {
      Logger.error(
        'Migration validation failed: $e',
        label: 'DataStoreImpl._validateMigration',
      );
      return false;
    }
  }

  /// Get table names
  Future<List<String>> getTableNames() async {
    try {
      final tables = <String>{};

      // Check global space
      final globalDir = Directory(config.getGlobalPath());
      if (await globalDir.exists()) {
        await for (var entity in globalDir.list()) {
          if (entity is File && entity.path.endsWith('.schema')) {
            try {
              final schemaJson = await entity.readAsString();
              final json = jsonDecode(schemaJson) as Map<String, dynamic>;
              // if name is not in json, add schemaPath
              if (!json.containsKey('name')) {
                json['_schemaPath'] = entity.path;
              }
              final schema = TableSchema.fromJson(json);
              tables.add(schema.name);
            } catch (e) {
              Logger.warn(
                'Failed to read schema file: ${entity.path}, error: $e',
                label: 'DataStoreImpl.getTableNames',
              );
            }
          }
        }
      }

      // Check base space
      final baseDir = Directory(config.getBasePath());
      if (await baseDir.exists()) {
        await for (var entity in baseDir.list()) {
          if (entity is File && entity.path.endsWith('.schema')) {
            try {
              final schemaJson = await entity.readAsString();
              final json = jsonDecode(schemaJson) as Map<String, dynamic>;
              // if name is not in json, add schemaPath
              if (!json.containsKey('name')) {
                json['_schemaPath'] = entity.path;
              }
              final schema = TableSchema.fromJson(json);
              tables.add(schema.name);
            } catch (e) {
              Logger.warn(
                'Failed to read schema file: ${entity.path}, error: $e',
                label: 'DataStoreImpl.getTableNames',
              );
            }
          }
        }
      }

      return tables.toList();
    } catch (e) {
      Logger.error(
        'Failed to get table names: $e',
        label: 'DataStoreImpl.getTableNames',
      );
      rethrow;
    }
  }

  /// Run operations in transaction
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action) async {
    final txn = await _transactionManager!.beginTransaction();
    try {
      final result = await action(txn);
      await _transactionManager?.commit(txn);
      return result;
    } catch (e) {
      await _transactionManager?.rollback(txn);
      rethrow;
    }
  }

  /// Check if table exists
  Future<bool> _tableExists(String tableName) async {
    try {
      final globalSchemaFile = File(config.getSchemaPath(tableName, true));
      final baseSchemaFile = File(config.getSchemaPath(tableName, false));

      if (await globalSchemaFile.exists() || await baseSchemaFile.exists()) {
        try {
          await getTableSchema(tableName);
          return true;
        } catch (e) {
          Logger.warn(
            'Schema file exists but invalid for table: $tableName',
            label: 'DataStoreImpl._tableExists',
          );
          return false;
        }
      }

      return false;
    } catch (e) {
      Logger.error(
        'Failed to check table existence: $e',
        label: 'DataStoreImpl._tableExists',
      );
      return false;
    }
  }

  /// Add field to existing records
  Future<void> addFieldToRecords(
    String tableName,
    FieldSchema field, {
    int batchSize = 1000,
  }) async {
    final txn = await _transactionManager!.beginTransaction();
    try {
      final records = await fileManager.readRecords(tableName);
      if (records.isEmpty) return;

      // add new field
      for (var record in records.values) {
        if (!record.containsKey(field.name)) {
          record[field.name] =
              field.defaultValue ?? _getTypeDefaultValue(field.type);
        }
      }

      // write converted records
      await fileManager.writeRecords(
        tableName: tableName,
        records: records.values.toList(),
        isSchemaChanged: true,
      );

      await _transactionManager!.commit(txn);
    } catch (e) {
      await _transactionManager!.rollback(txn);
      Logger.error(
        'Failed to add field to records: $e',
        label: 'DataStoreImpl.addFieldToRecords',
      );
      rethrow;
    }
  }

  /// Remove field from records
  Future<void> removeFieldFromRecords(
    String tableName,
    String fieldName, {
    int batchSize = 1000,
  }) async {
    final txn = await _transactionManager!.beginTransaction();
    try {
      final records = await fileManager.readRecords(tableName);
      if (records.isEmpty) return;

      // remove field
      for (var record in records.values) {
        record.remove(fieldName);
      }

      // write converted records
      await fileManager.writeRecords(
        tableName: tableName,
        records: records.values.toList(),
        isSchemaChanged: true,
      );

      await _transactionManager!.commit(txn);
    } catch (e) {
      await _transactionManager!.rollback(txn);
      rethrow;
    }
  }

  /// Rename field in records
  Future<void> renameFieldInRecords(
    String tableName,
    String oldName,
    String newName, {
    int batchSize = 1000,
  }) async {
    final txn = await _transactionManager!.beginTransaction();
    try {
      final records = await fileManager.readRecords(tableName);
      if (records.isEmpty) return;

      // rename field
      for (var record in records.values) {
        if (record.containsKey(oldName)) {
          record[newName] = record[oldName];
          record.remove(oldName);
        }
      }

      // write converted records
      await fileManager.writeRecords(
        tableName: tableName,
        records: records.values.toList(),
        isSchemaChanged: true,
      );

      await _transactionManager!.commit(txn);
    } catch (e) {
      await _transactionManager!.rollback(txn);
      Logger.error(
        'Failed to rename field in records: $e',
        label: 'DataStoreImpl.renameFieldInRecords',
      );
    }
  }

  /// Convert value between data types
  dynamic _convertValue(dynamic value, DataType type) {
    if (value == null) return null;

    switch (type) {
      case DataType.integer:
        return _toInteger(value);
      case DataType.double:
        return _toReal(value);
      case DataType.text:
        return _toString(value);
      case DataType.blob:
        return _toBlob(value);
      case DataType.boolean:
        return _toBoolean(value);
      case DataType.datetime:
        return _toDateTimeString(value);
      case DataType.array:
        return _toArray(value);
    }
  }

  int? _toInteger(dynamic value) {
    if (value is int) return value;
    if (value is double) return value.round();
    if (value is String) return int.tryParse(value);
    if (value is bool) return value ? 1 : 0;
    if (value is DateTime) return value.millisecondsSinceEpoch;
    return null;
  }

  double? _toReal(dynamic value) {
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is String) return double.tryParse(value);
    if (value is bool) return value ? 1.0 : 0.0;
    if (value is DateTime) return value.millisecondsSinceEpoch.toDouble();
    return null;
  }

  String? _toString(dynamic value) {
    if (value is String) return value;
    if (value is DateTime) {
      try {
        return value.toIso8601String();
      } catch (e) {
        Logger.warn(
          'Failed to convert DateTime to string: $value',
          label: 'DataStore._toString',
        );
        return null;
      }
    }
    return value?.toString();
  }

  Uint8List? _toBlob(dynamic value) {
    if (value is Uint8List) return value;
    if (value is String) return Uint8List.fromList(utf8.encode(value));
    if (value is List<int>) return Uint8List.fromList(value);
    return null;
  }

  bool? _toBoolean(dynamic value) {
    if (value is bool) return value;
    if (value is int) return value != 0;
    if (value is double) return value != 0.0;
    if (value is String) {
      final lower = value.toLowerCase();
      return lower == 'true' || lower == '1' || lower == 'yes';
    }
    return null;
  }

  /// DateTime convert to ISO8601 string
  String? _toDateTimeString(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value.toIso8601String();
    if (value is String) {
      try {
        return DateTime.parse(value).toIso8601String();
      } catch (e) {
        Logger.warn(
          'Failed to parse DateTime from string: $value',
          label: 'DataStore._toDateTimeString',
        );
        return null;
      }
    }
    if (value is int) {
      try {
        return DateTime.fromMillisecondsSinceEpoch(value).toIso8601String();
      } catch (e) {
        Logger.warn(
          'Failed to convert timestamp to DateTime: $value',
          label: 'DataStore._toDateTimeString',
        );
        return null;
      }
    }
    return null;
  }

  /// Array convert to List
  List? _toArray(dynamic value) {
    if (value is List) return value;
    if (value is String) {
      try {
        return jsonDecode(value) as List?;
      } catch (_) {
        return [value];
      }
    }
    return value == null ? null : [value];
  }

  /// Invalidate all caches for table
  void _invalidateTableCaches(String tableName) {
    _queryExecutor?.queryCacheManager.invalidateCache(tableName);
    _queryExecutor?.invalidateCache(tableName);
    _statisticsCollector?.invalidateCache(tableName);
    _uniqueValuesCache.remove(tableName);
  }

  /// Migrate field data when field attributes change
  Future<void> migrateFieldData(
    String tableName,
    FieldSchema oldField,
    FieldSchema newField,
    Transaction txn, {
    int batchSize = 1000,
  }) async {
    try {
      // Skip if only metadata changed (comment, etc)
      if (oldField.type == newField.type &&
          oldField.nullable == newField.nullable &&
          oldField.defaultValue == newField.defaultValue &&
          oldField.unique == newField.unique &&
          oldField.name == newField.name) {
        return;
      }

      final schema = await getTableSchema(tableName);
      final records = await fileManager.readRecords(tableName);
      if (records.isEmpty) return;

      // 1. Handle type conversion
      if (oldField.type != newField.type) {
        for (var record in records.values) {
          if (record.containsKey(oldField.name)) {
            try {
              // Convert and store in new field
              record[newField.name] = _convertValue(
                record[oldField.name],
                newField.type,
              );
              // Remove old field if names are different
              if (oldField.name != newField.name) {
                record.remove(oldField.name);
              }
            } catch (e) {
              // if conversion fails, use default value
              record[newField.name] =
                  newField.defaultValue ?? _getTypeDefaultValue(newField.type);
              Logger.warn(
                'Failed to convert field value: ${record[oldField.name]} from ${oldField.type} to ${newField.type}, using default value',
                label: 'DataStoreImpl.migrateFieldData',
              );
            }
          }
        }
      }

      // 2. Handle nullability change
      if (!oldField.nullable && newField.nullable) {
        // Field became nullable - no action needed
      } else if (oldField.nullable && !newField.nullable) {
        // Set default value for null fields
        for (var record in records.values) {
          if (record[newField.name] == null) {
            record[newField.name] =
                newField.defaultValue ?? _getTypeDefaultValue(newField.type);
          }
        }
      }

      // 3. Handle default value change
      if (oldField.defaultValue != newField.defaultValue) {
        for (var record in records.values) {
          if (record[newField.name] == oldField.defaultValue) {
            record[newField.name] = newField.defaultValue;
          }
        }
      }

      // 4. Handle unique constraint change
      if (oldField.unique != newField.unique) {
        if (newField.unique) {
          // Check uniqueness
          final values = <dynamic>{};
          for (var record in records.values) {
            final value = record[oldField.name];
            if (values.contains(value)) {
              Logger.warn(
                'Duplicate value found for field ${oldField.name}: $value',
                label: 'DataStoreImpl.migrateFieldData',
              );
            }
            values.add(value);
          }
        }

        // 4.2 Handle indexes
        // Remove old field index if exists
        final oldIndex = schema.indexes.firstWhere(
          (i) => i.fields.length == 1 && i.fields.first == oldField.name,
          orElse: () => const IndexSchema(fields: []),
        );
        if (oldIndex.indexName != null) {
          await removeIndex(tableName, oldIndex.indexName!, txn);
        }

        // Add new index if needed
        if (newField.unique) {
          final newIndex = IndexSchema(
            indexName: '${newField.name}_idx',
            fields: [newField.name],
            unique: true,
          );
          await addIndex(tableName, newIndex, txn);
        }
      }

      // 5. check max length
      if (oldField.maxLength != null) {
        for (var record in records.values) {
          if (record[oldField.name] != null &&
              record[oldField.name] is String &&
              record[oldField.name].length > oldField.maxLength!) {
            Logger.warn('Warning: field ${oldField.name} exceeds max length');
            record[oldField.name] =
                record[oldField.name].substring(0, oldField.maxLength!);
          }
        }
      }

      // 6. Write converted records
      await fileManager.writeRecords(
        tableName: tableName,
        records: records.values.toList(),
        isSchemaChanged: true,
      );
    } catch (e) {
      Logger.error(
        'Failed to migrate field data: $e',
        label: 'DataStoreImpl.migrateFieldData',
      );
      rethrow;
    }
  }

  /// Get row pointer for given primary key value
  Future<RowPointer?> getRowPointer(
    String tableName,
    dynamic primaryKeyValue,
  ) async {
    try {
      final schema = await getTableSchema(tableName);
      final dataPath = config.getDataPath(tableName, schema.isGlobal);
      final dataFile = File(dataPath);

      if (!await dataFile.exists()) {
        return null;
      }

      // 1. Check pending writes in queue
      final pendingData = fileManager.writeQueue[tableName] ?? [];
      for (var record in pendingData) {
        if (record[schema.primaryKey] == primaryKeyValue) {
          final encoded = jsonEncode(record);
          return RowPointer.create(encoded, 0); // Use temporary offset
        }
      }

      // 2. Read from file
      var offset = 0;
      final lines = await dataFile.readAsLines();

      for (var line in lines) {
        if (line.trim().isEmpty) {
          offset += line.length + 1;
          continue;
        }

        try {
          final record = jsonDecode(line) as Map<String, dynamic>;
          if (record[schema.primaryKey] == primaryKeyValue) {
            return RowPointer.create(line, offset);
          }
        } catch (e) {
          Logger.warn(
            'Invalid JSON at offset $offset: $e',
            label: 'DataStoreImpl.getRowPointer',
          );
        }

        offset += line.length + 1;
      }

      return null;
    } catch (e) {
      Logger.error(
        'Failed to get row pointer: $e',
        label: 'DataStoreImpl.getRowPointer',
      );
      return null;
    }
  }

  /// Get record data by row pointer
  Future<Map<String, dynamic>?> getRecordByPointer(
    String tableName,
    RowPointer pointer,
  ) async {
    try {
      final dataPath = config.getDataPath(
          tableName, (await getTableSchema(tableName)).isGlobal);
      final file = File(dataPath);

      if (!await file.exists()) return null;

      final raf = await file.open(mode: FileMode.read);
      try {
        await raf.setPosition(pointer.offset);
        final bytes = await raf.read(pointer.length);
        final line = utf8.decode(bytes);

        if (pointer.verifyContent(line.trim())) {
          return jsonDecode(line.trim()) as Map<String, dynamic>;
        }
        return null;
      } finally {
        await raf.close();
      }
    } catch (e) {
      Logger.error(
        'Failed to get record by pointer: $e',
        label: 'DataStoreImpl.getRecordByPointer',
      );
      return null;
    }
  }

  /// Modify index
  Future<void> modifyIndex(
    String tableName,
    String oldIndexName,
    IndexSchema newIndex,
    Transaction? txn,
  ) async {
    try {
      // 1. Drop old index
      await removeIndex(tableName, oldIndexName, txn);

      // 2. Create new index
      await addIndex(tableName, newIndex, txn);
    } catch (e) {
      Logger.error(
        'Failed to modify index: $e',
        label: 'DataStoreImpl.modifyIndex',
      );
      rethrow;
    }
  }

  /// Set auto increment setting for a table
  Future<void> setAutoIncrement(String tableName, bool enabled) async {
    if (!_baseInitialized) {
      await _ensureInitialized();
    }

    try {
      // 1. get table schema
      final schema = await getTableSchema(tableName);
      if (schema.fields.isEmpty) {
        throw BusinessError(
          'Table $tableName not found',
          type: BusinessErrorType.schemaError,
        );
      }

      // 2. validate primary key type
      final primaryField =
          schema.fields.firstWhere((f) => f.name == schema.primaryKey);
      if (enabled && primaryField.type != DataType.integer) {
        throw const BusinessError(
          'Auto increment only supports integer primary key',
          type: BusinessErrorType.schemaError,
        );
      }

      // 3. if setting is unchanged, return
      if (schema.autoIncrement == enabled) {
        return;
      }

      // 4. create new schema
      final newSchema = schema.copyWith(autoIncrement: enabled);

      // 5. get schema file
      final schemaFile = File(config.getSchemaPath(tableName, schema.isGlobal));

      await _concurrencyManager!.acquireWriteLock(tableName);
      try {
        // 6. update schema file
        await schemaFile.writeAsString(jsonEncode(newSchema));

        // 7. if auto increment is enabled, create auto increment id file
        if (enabled) {
          final maxIdFile =
              File(config.getAutoIncrementPath(tableName, schema.isGlobal));
          if (!await maxIdFile.exists()) {
            await maxIdFile.writeAsString('0');
          }
        }

        // 8. update cache
        _queryExecutor?.queryCacheManager.cacheSchema(tableName, newSchema);

        Logger.info(
          'Auto increment ${enabled ? 'enabled' : 'disabled'} for table $tableName',
          label: 'DataStore.setAutoIncrement',
        );
      } catch (e) {
        Logger.error(
          'Failed to update auto increment setting: $e',
          label: 'DataStore.setAutoIncrement',
        );
        rethrow;
      } finally {
        await _concurrencyManager!.releaseWriteLock(tableName);
      }
    } catch (e) {
      Logger.error(
        'Set auto increment failed: $e',
        label: 'DataStore.setAutoIncrement',
      );
      rethrow;
    }
  }
}
