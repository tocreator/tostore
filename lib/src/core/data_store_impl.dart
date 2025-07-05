import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'lock_manager.dart';
import 'backup_manager.dart';
import '../handler/chacha20_poly1305.dart';
import '../handler/common.dart';
import '../handler/logger.dart';
import '../handler/value_comparator.dart';
import '../model/business_error.dart';
import '../model/db_result.dart';
import '../model/file_info.dart';
import '../model/global_config.dart';
import '../model/migration_config.dart';
import '../model/migration_task.dart';
import '../model/result_type.dart';
import '../model/system_table.dart';
import '../model/table_schema.dart';
import 'data_cache_manager.dart';
import 'data_compressor.dart';
import '../model/data_store_config.dart';
import 'memory_manager.dart';
import 'table_data_manager.dart';
import 'index_manager.dart';
import '../model/table_info.dart';
import '../query/query_condition.dart';
import '../query/query_executor.dart';
import '../query/query_optimizer.dart';
import 'transaction_manager.dart';
import 'migration_manager.dart';
import 'integrity_checker.dart';
import 'storage_adapter.dart';
import 'key_manager.dart';
import '../model/space_config.dart';
import 'schema_manager.dart';
import 'path_manager.dart';
import 'crontab_manager.dart';
import '../model/log_config.dart';
import 'old_structure_migration_handler.dart';
import 'directory_manager.dart';
import '../model/space_info.dart';
import '../handler/parallel_processor.dart';

/// Core storage engine implementation
class DataStoreImpl {
  static final Map<String, DataStoreImpl> _instances = {};
  Completer<void> _initCompleter = Completer<void>();
  bool _isInitialized = false;
  bool _initializing = false;
  final String _instanceKey;
  final Future<void> Function(DataStoreImpl db)? _onConfigure;
  final Future<void> Function(DataStoreImpl db)? _onCreate;
  final Future<void> Function(DataStoreImpl db)? _onOpen;
  final List<TableSchema> _schemas;

  bool _baseInitialized = false;

  bool get isInitialized => _isInitialized;
  final bool isMigrationInstance;

  // Global configuration cache
  static GlobalConfig? _globalConfigCache;

  String _currentSpaceName = 'default';
  DataStoreConfig? _config;

  TransactionManager? _transactionManager;
  IndexManager? _indexManager;
  QueryOptimizer? _queryOptimizer;
  QueryExecutor? _queryExecutor;
  late DataCacheManager dataCacheManager;
  MigrationManager? migrationManager;
  IntegrityChecker? _integrityChecker;
  KeyManager? _keyManager;
  late StorageAdapter storage;
  SpaceConfig? _spaceConfigCache;
  SchemaManager? schemaManager;
  PathManager? _pathManager;
  DirectoryManager? directoryManager;
  LockManager? lockManager;

  MemoryManager? _memoryManager;

  PathManager get pathManager {
    if (_pathManager == null) {
      throw StateError('PathManager not initialized');
    }
    return _pathManager!;
  }

  TableDataManager? _tableDataManager;
  TableDataManager get tableDataManager {
    if (_tableDataManager == null) {
      throw StateError('TableDataManager not initialized');
    }
    return _tableDataManager!;
  }

  /// Get current space name
  String get currentSpaceName => _currentSpaceName;

  /// Get query optimizer
  QueryOptimizer? getQueryOptimizer() => _queryOptimizer;

  /// Get query executor
  QueryExecutor? getQueryExecutor() => _queryExecutor;

  IndexManager? get indexManager => _indexManager;

  /// Get memory manager
  MemoryManager? get memoryManager => _memoryManager;

  /// Get current configuration
  DataStoreConfig get config {
    if (_config == null) {
      throw StateError('DataStore not initialized');
    }
    return _config!;
  }

  /// Create instance with configuration
  factory DataStoreImpl({
    String? dbPath,
    String? dbName,
    DataStoreConfig? config,
    List<TableSchema> schemas = const [],
    Future<void> Function(DataStoreImpl db)? onConfigure,
    Future<void> Function(DataStoreImpl db)? onCreate,
    Future<void> Function(DataStoreImpl db)? onOpen,
    isMigrationInstance = false,
  }) {
    final key = dbPath ?? 'default';
    if (!_instances.containsKey(key) && !isMigrationInstance) {
      final instance = DataStoreImpl._internal(
        key,
        schemas,
        onConfigure,
        onCreate,
        onOpen,
        isMigrationInstance,
      );
      _instances[key] = instance;
      instance._startInitialize(dbPath, dbName, config);
    }
    // If it's a migration instance, always create a new instance, don't use existing instances
    if (isMigrationInstance) {
      final instance = DataStoreImpl._internal(
        '$key-migration-${DateTime.now().millisecondsSinceEpoch}',
        schemas,
        onConfigure,
        onCreate,
        onOpen,
        isMigrationInstance,
      );
      if (config != null) {
        instance._currentSpaceName = config.spaceName;
      }
      instance._startInitialize(dbPath, dbName, config);
      return instance;
    }
    return _instances[key]!;
  }

  DataStoreImpl._internal(
    this._instanceKey,
    this._schemas,
    this._onConfigure,
    this._onCreate,
    this._onOpen,
    this.isMigrationInstance,
  );

  /// Start initialization process
  void _startInitialize(
      String? dbPath, String? dbName, DataStoreConfig? config) {
    if (_initializing || _isInitialized) {
      return;
    }

    _initCompleter = Completer<void>();

    initialize(dbPath: dbPath, dbName: dbName, config: config).then((_) {
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

  // Helper method to load the space configuration from the space_config.json file and update the cache
  Future<SpaceConfig?> getSpaceConfig({bool nowGetFromFile = false}) async {
    if (!nowGetFromFile && _spaceConfigCache != null) {
      return _spaceConfigCache;
    }

    final spaceFilePath = pathManager.getSpaceConfigPath(_currentSpaceName);

    try {
      final content = await storage.readAsString(spaceFilePath) ?? "";
      if (content.isEmpty) return null;

      _spaceConfigCache =
          SpaceConfig.fromJson(jsonDecode(content) as Map<String, dynamic>);
      return _spaceConfigCache;
    } catch (e) {
      Logger.error('Failed to parse init config: $e');
      return null;
    }
  }

  /// Save space config to file
  Future<void> saveSpaceConfigToFile(SpaceConfig config) async {
    try {
      final spaceFilePath = pathManager.getSpaceConfigPath(_currentSpaceName);

      final content = jsonEncode(config.toJson());
      await storage.writeAsString(spaceFilePath, content);
      _spaceConfigCache = config;
    } catch (e) {
      Logger.error('Failed to save space config: $e', label: 'spaceConfig');
    }
  }

  /// Get database version
  Future<int> getVersion() async {
    if (_spaceConfigCache != null) return _spaceConfigCache!.version;
    final loadedConfig = await getSpaceConfig();
    return loadedConfig?.version ?? 0;
  }

  /// Set database version
  Future<void> setVersion(int newVersion) async {
    // Load existing config if not already cached
    SpaceConfig? currentConfig = _spaceConfigCache ?? await getSpaceConfig();
    if (currentConfig != null) {
      await saveSpaceConfigToFile(currentConfig.copyWith(version: newVersion));
    } else {
      final encryptedBytes = ChaCha20Poly1305.encrypt(
          plaintext: config.encodingKey,
          key: ChaCha20Poly1305.generateKeyFromString(config.encryptionKey));
      final encryptedBase64 = base64.encode(encryptedBytes);
      final newConfig = SpaceConfig(
          current: EncryptionKeyInfo(key: encryptedBase64, keyId: 1),
          previous: null,
          version: newVersion);
      await saveSpaceConfigToFile(newConfig);
    }
  }

  /// Ensure initialization is complete
  Future<void> ensureInitialized() async {
    if (!_isInitialized && !_initCompleter.isCompleted) {
      await _initCompleter.future;
    }
  }

  /// Get database path
  Future<String> getDatabasePath({String? dbPath, String? dbName}) async {
    final baseDir = pathJoin('db', dbName ?? 'default');
    String? rootPath;

    if (dbPath != null) {
      rootPath = dbPath;
    } else if (_config != null) {
      rootPath = _config?.dbPath;
    }

    if (rootPath != null) {
      if (rootPath.startsWith(baseDir) || rootPath.endsWith(baseDir)) {
        return rootPath;
      }
      return pathJoin(rootPath, baseDir);
    }

    if (kIsWeb) {
      return baseDir;
    }

    // Other platforms: app path/baseDir
    final appPath = await getPathApp();
    return pathJoin(appPath, baseDir);
  }

  /// Initialize storage engine
  Future<bool> initialize(
      {String? dbPath, String? dbName, DataStoreConfig? config}) async {
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

      // First, set up the configuration so that logging is enabled immediately.
      // This ensures that any errors during path resolution are also captured.
      _config = config ?? DataStoreConfig();

      // Apply log configuration as early as possible.
      LogConfig.setConfig(
        enableLog: _config!.enableLog,
        logLevel: _config!.logLevel,
      );

      dbPath = await getDatabasePath(dbPath: dbPath, dbName: dbName);

      // Now, update the config with the final path.
      _config = _config!.copyWith(dbPath: dbPath);

      // Configure the global parallel processor with sensible defaults
      ParallelProcessor.setConfig(
        concurrency: _config!.maxConcurrent,
        // Calculate a dynamic timeout based on max partition size.
        // Formula: 5 seconds base + 1 second per 128KB.
        timeout: Duration(
            seconds:
                10 + (_config!.maxPartitionFileSize / (128 * 1024)).ceil()),
      );

      // Ensure _currentSpaceName is synchronized with config.spaceName
      _currentSpaceName = _config!.spaceName;

      storage = StorageAdapter(_config!);
      lockManager = LockManager();

      schemaManager = SchemaManager(this);
      _pathManager = PathManager(this);

      // Initialize memory manager
      _memoryManager = MemoryManager();

      await Future.wait([
        getGlobalConfig(),
        getSpaceConfig(),
        _memoryManager!.initialize(_config!, this),
      ]);

      // Initialize key components sequentially to avoid race conditions during the first run.
      _keyManager = KeyManager(this);
      await _keyManager!.initialize();

      directoryManager = DirectoryManager(this);
      _transactionManager = TransactionManager(this);
      _indexManager = IndexManager(this);
      _tableDataManager = TableDataManager(this);
      migrationManager = MigrationManager(this);
      _integrityChecker = IntegrityChecker(this);
      _queryOptimizer = QueryOptimizer(this);
      _queryExecutor = QueryExecutor(this, _indexManager!);
      dataCacheManager = DataCacheManager(this);

      _baseInitialized = true;

      if (!isMigrationInstance) {
        // Execute old structure migration if needed
        await _migrateOldStructureIfNeeded();

        // Initialize migration manager, restore unfinished migration tasks
        await migrationManager?.initialize();

        await _startSetupAndUpgrade();
      }

      _isInitialized = true;
      if (!_initCompleter.isCompleted) {
        _initCompleter.complete();
      }

      if (!isMigrationInstance) {
        // load data to cache
        _loadTableRecordToCache();

        CrontabManager.start();

        // Database open callback
        await _onOpen?.call(this);
      }

      return true;
    } catch (e, stack) {
      _isInitialized = false;
      if (!_initCompleter.isCompleted) {
        _initCompleter.completeError(e);
      }
      Logger.error('Database initialization failed: $e\n$stack',
          label: 'DataStore.initialize');
      return false;
    } finally {
      _initializing = false;
    }
  }

  /// Setup tables and handle upgrades
  Future<void> _startSetupAndUpgrade() async {
    try {
      await _onConfigure?.call(this);

      // Check if global configuration has migration tasks
      final globalConfig = await getGlobalConfig();
      if (globalConfig?.hasMigrationTask == true) {
        return;
      }

      // Check if initialization or upgrade is needed
      bool needInitialize = false;
      bool needUpgrade = false;

      // Check if there are existing table structures
      final schemaMeta = await schemaManager!.getSchemaMeta();
      if (schemaMeta.tablePartitionMap.isEmpty) {
        // First run, need to initialize
        needInitialize = true;
      } else {
        // Compare hash values to check if upgrade is needed
        needUpgrade = await schemaManager!.isSchemaChanged(getInitialSchema());
      }

      // First run - create system tables and user tables
      if (needInitialize) {
        // Create system tables
        await createTables(SystemTable.gettableSchemas);

        // Create user tables
        if (_schemas.isNotEmpty) {
          for (var schema in _schemas) {
            await createTable(schema);
          }
          await schemaManager?.updateInitialSchemaHash();
        }

        // Call creation callback
        await _onCreate?.call(this);
      }
      // Need upgrade - perform table structure migration
      else if (needUpgrade) {
        // Perform automatic table structure migration
        if (_schemas.isNotEmpty) {
          await schemaManager?.updateInitialSchemaHash();
          await autoSchemaMigrate(getInitialSchema());
        }
      }
    } catch (e, stack) {
      Logger.error(
        'Database setup/upgrade failed: $e\n$stack',
        label: 'DataStoreImpl._startSetupAndUpgrade',
      );
      rethrow;
    }
  }

  /// Automatic table structure migration - based on table structure hash comparison
  Future<void> autoSchemaMigrate(List<TableSchema> schemas) async {
    String backupPath = '';
    try {
      final migrationConfig = config.migrationConfig ?? const MigrationConfig();

      // Backup database according to configuration
      if (migrationConfig.backupBeforeMigrate) {
        backupPath = await backup();
      }

      for (var schema in schemas) {
        if (!schema.validateTableSchema()) {
          throw const BusinessError(
            'Invalid table structure',
            type: BusinessErrorType.schemaError,
          );
        }
      }

      await migrationManager?.migrate(
        schemas,
        batchSize: migrationConfig.batchSize,
      );

      // Validate migration results according to configuration
      if (migrationConfig.validateAfterMigrate) {
        final isValid = await _validateMigration(schemas);
        if (!isValid && migrationConfig.strictMode) {
          throw const BusinessError(
            'Migration validation failed',
            type: BusinessErrorType.migrationError,
          );
        }
      }

      // After successful migration, delete backup
      if (backupPath.isNotEmpty) {
        await storage.deleteDirectory(backupPath);
      }

      Logger.info(
        'Table structure auto-migration completed',
        label: 'DataStoreImpl.autoSchemaMigrate',
      );
    } catch (e, stack) {
      Logger.error(
        'Table structure auto-migration failed: $e\n$stack',
        label: 'DataStoreImpl.autoSchemaMigrate',
      );
      // Restore backup on failure
      if (backupPath.isNotEmpty) {
        await restore(backupPath, deleteAfterRestore: true);
      }
      rethrow;
    }
  }

  /// Close database
  Future<void> close() async {
    if (!_isInitialized) return;

    try {
      // Attempt to save cache before closing
      try {
        await saveAllCacheBeforeExit();
      } catch (e) {
        Logger.error('Failed to save cache when closing: $e',
            label: 'DataStoreImpl.close');
      }

      CrontabManager.dispose();
      await _tableDataManager?.dispose();
      await storage.close(isMigrationInstance: isMigrationInstance);

      lockManager = null;

      // Release all managers
      _indexManager?.dispose();
      dataCacheManager.clear();
      await _transactionManager?.commit(null);

      // Clean up memory manager resources
      _memoryManager?.dispose();

      // Clear instance variables
      _transactionManager = null;
      _queryOptimizer = null;
      _indexManager = null;
      _queryExecutor = null;
      _config = null;
      _integrityChecker = null;
      _keyManager = null;
      migrationManager = null;
      schemaManager = null;
      _tableDataManager = null;
      _memoryManager = null;

      _globalConfigCache = null;
      _spaceConfigCache = null;

      _isInitialized = false;
      _initializing = false;
      _initCompleter = Completer<void>();

      _instances.remove(_instanceKey);

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
      await ensureInitialized();
    }

    try {
      var schemaValid = schema;

      // Check if table already exists
      final tableExists = await this.tableExists(schema.name);
      if (tableExists) {
        Logger.warn('Table ${schema.name} already exists',
            label: 'DataStore.createTable');
        return;
      }

      try {
        // Validate primary key configuration and field types
        if (!schemaValid.validateTableSchema()) {
          throw BusinessError(
            'The structure of table ${schema.name} is invalid, please check primary key configuration and index fields',
            type: BusinessErrorType.schemaError,
          );
        }

        // Create table path
        await _pathManager!.createTablePath(schema.name, schema.isGlobal);

        // Write schema file
        await updateTableSchema(schema.name, schemaValid);

        // Create primary key index
        await _indexManager?.createPrimaryIndex(schema.name, schema.primaryKey);

        // Create other indexes
        for (var index in schema.indexes) {
          await _indexManager?.createIndex(schema.name, index);
        }

        // Automatically create unique indexes for all fields with unique attribute (if not already existing)
        for (var field in schema.fields) {
          if (field.unique && field.name != schema.primaryKey) {
            // Check if the field already has an index (whether unique or not)
            final hasIndex = schema.indexes.any((idx) =>
                idx.fields.length == 1 && idx.fields.first == field.name);

            // If no index exists, automatically create a unique index
            if (!hasIndex) {
              // Create index schema, don't specify indexName parameter, let actualIndexName create a consistent naming based on field name
              final indexSchema =
                  IndexSchema(fields: [field.name], unique: true);
              await _indexManager?.createIndex(schema.name, indexSchema);
              Logger.debug(
                'Automatically created unique index ${indexSchema.actualIndexName} for unique field ${schema.name}.${field.name}',
                label: 'DataStore.createTable',
              );
            }
          }
        }

        // If auto primary key generation is configured, initialize id file
        if (schemaValid.primaryKeyConfig.type == PrimaryKeyType.sequential) {
          final maxIdPath =
              await _pathManager!.getAutoIncrementPath(schema.name);

          // Get initial auto-increment value
          int initialValue = 0;
          if (schemaValid.primaryKeyConfig.sequentialConfig != null) {
            initialValue =
                schemaValid.primaryKeyConfig.sequentialConfig!.initialValue;
          }

          await storage.writeAsString(maxIdPath, initialValue.toString());
        }

        // Mark new table as full table cache
        await dataCacheManager.cacheEntireTable(
          schema.name,
          schema.primaryKey,
          [],
          isFullTableCache: true,
        );

        // New table created successfully, call table creation statistics method
        tableDataManager.tableCreated(schema.name);

        if (!SystemTable.isSystemTable(schema.name)) {
          Logger.info(
            'Table ${schema.name} created successfully${schema.isGlobal ? ' (global)' : ' (space)'}',
            label: 'DataStore.createTable',
          );
        }
      } catch (e) {
        // Cleanup schema
        if (schemaManager != null) {
          await schemaManager!.deleteTableSchema(schema.name);
          // Release directory
          await directoryManager!.releaseTableDirectory(schema.name);
        }

        Logger.error('Create table failed: $e', label: 'DataStore.createTable');
        rethrow;
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

  /// Insert data complete process
  Future<DbResult> insert(String tableName, Map<String, dynamic> data) async {
    // Need to be fully initialized
    if (!_isInitialized) {
      await ensureInitialized();
    }

    // 1. Begin transaction
    final transaction = await _transactionManager!.beginTransaction();
    Map<String, dynamic>? validData;

    try {
      // 2. Data validation
      final schema = await getTableSchema(tableName);
      if (schema == null) {
        Logger.error('Table $tableName does not exist',
            label: 'DataStore.insert');
        return DbResult.error(
          type: ResultType.notFound,
          message: 'Table $tableName does not exist',
        );
      }
      validData = await _validateAndProcessData(schema, data, tableName);
      if (validData == null) {
        return DbResult.error(
          type: ResultType.validationFailed,
          message: 'Data validation failed',
        );
      }

      // 3. Unique check
      if (await _indexManager?.checkUniqueConstraints(tableName, validData) ==
          false) {
        // For primary key conflicts, try to update the maximum ID value to avoid assigning the same ID in the future
        final primaryKey = schema.primaryKey;
        final providedId = validData[primaryKey];

        // Only handle integer primary keys and auto-increment primary key configurations
        if (providedId is int &&
            schema.primaryKeyConfig.type == PrimaryKeyType.sequential) {
          // Notify TableDataManager to handle primary key conflict
          await tableDataManager.handlePrimaryKeyConflict(
              tableName, providedId);
        }

        return DbResult.error(
          type: ResultType.uniqueViolation,
          message: 'Unique constraint violation',
          failedKeys: providedId != null ? [providedId.toString()] : [],
        );
      }

      // 4. Update cache
      dataCacheManager.addCachedRecord(tableName, validData);

      // 5. Add to write queue (insert operation)
      await tableDataManager.addToWriteBuffer(tableName, validData,
          isUpdate: false);

      // 6. Commit transaction
      await _transactionManager!.commit(transaction);

      // Invalidate query caches that might be affected by the new record
      await dataCacheManager.invalidateAffectedQueries(tableName,
          records: [validData]);

      // Return string type primary key value
      final primaryKeyValue = validData[schema.primaryKey];
      return DbResult.success(
        successKey: primaryKeyValue?.toString(),
        message: 'Insert successful',
      );
    } catch (e) {
      Logger.error('Insert failed: $e', label: 'DataStore.insert');

      try {
        // Rollback transaction
        await _transactionManager!.rollback(transaction);

        // Clear cache
        final schema = await getTableSchema(tableName);
        final primaryKeyValue = validData != null && schema != null
            ? validData[schema.primaryKey]
            : null;
        if (primaryKeyValue != null) {
          await dataCacheManager
              .invalidateRecords(tableName, [primaryKeyValue.toString()], [
            validData!,
          ]);
        }

        // clear write queue
        final queue = tableDataManager.writeBuffer[tableName];
        if (queue != null && schema != null) {
          final primaryKey = schema.primaryKey;
          final recordId = data[primaryKey]?.toString();
          if (recordId != null) {
            queue.remove(recordId);
          }
        }
      } catch (rollbackError) {
        Logger.error('Rollback failed: $rollbackError',
            label: 'DataStore.insert');
      }

      // Identify the failed record's key
      List<String> failedKeys = [];
      try {
        final schema = await getTableSchema(tableName);
        if (schema != null && data.containsKey(schema.primaryKey)) {
          final keyValue = data[schema.primaryKey]?.toString();
          if (keyValue != null && keyValue.isNotEmpty) {
            failedKeys = [keyValue];
          }
        }
      } catch (_) {
        // Ignore errors during error handling
      }

      return DbResult.error(
        type: ResultType.dbError,
        message: 'Insert failed: $e',
        failedKeys: failedKeys,
      );
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

      // 1. handle primary key
      if (!data.containsKey(primaryKey) || data[primaryKey] == null) {
        if (schema.primaryKeyConfig.type != PrimaryKeyType.none) {
          final nextId = await tableDataManager.getNextId(tableName);
          if (nextId.isEmpty) {
            throw const BusinessError(
              'Failed to generate primary key',
              type: BusinessErrorType.invalidData,
            );
          }
          result[primaryKey] = nextId;
        } else {
          throw const BusinessError(
            'Primary key value cannot be null',
            type: BusinessErrorType.invalidData,
          );
        }
      } else {
        final providedId = data[primaryKey];

        // Validate primary key format and ordering
        if (providedId != null) {
          // Format validation
          if (!schema.validatePrimaryKeyFormat(providedId)) {
            throw BusinessError(
              'The provided primary key value $providedId does not meet the format requirements for type ${schema.primaryKeyConfig.type}',
              type: BusinessErrorType.invalidData,
            );
          }

          // Ordering validation
          if (!await _validatePrimaryKeyOrder(
              tableName, providedId, schema.primaryKeyConfig.type)) {
            throw BusinessError(
              'The provided primary key value $providedId violates the key ordering of table $tableName, data insertion rejected',
              type: BusinessErrorType.invalidData,
            );
          }
        }

        if (providedId is String &&
            schema.primaryKeyConfig.type == PrimaryKeyType.sequential) {
          tableDataManager.updateMaxIdInMemory(tableName, providedId);
        }
        result[primaryKey] = providedId;
      }

      // 2. fill default value and null value
      for (var field in schema.fields) {
        if (field.name == primaryKey) {
          continue;
        }

        if (!data.containsKey(field.name)) {
          // get default value
          final defaultVal = field.getDefaultValue();
          if (defaultVal == null) {
            // if field is not nullable and has no default value
            if (!field.nullable) {
              Logger.warn(
                'Field ${field.name} cannot be null and has no default value',
                label: 'DataStore._validateAndProcessData',
              );
              return null;
            } else {
              // allow null, set to null
              result[field.name] = null;
            }
          } else {
            // use converted default value
            result[field.name] = defaultVal;
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
            if (field.isValidDataType(value, field.type)) {
              result[field.name] = value; // type match, use directly
            } else {
              try {
                // try to convert type
                final convertedValue = field.convertValue(value);
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
      }

      // 3. validate data using schema constraints and apply constraints if needed
      final validatedResult =
          schema.validateData(result, applyConstraints: true);
      if (validatedResult == null) {
        Logger.warn(
          'Data validation failed for table $tableName',
          label: 'DataStore._validateAndProcessData',
        );
        return null;
      }

      return _prepareDataForStorage(validatedResult);
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

  /// Execute query
  Future<List<Map<String, dynamic>>> executeQuery(
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

  /// calculate checksum
  String calculateChecksum(Uint8List data) {
    final compressor = DataCompressor();
    return compressor.calculateChecksum(data).toString();
  }

  /// backup data and return backup path
  Future<String> backup({bool compress = true}) async {
    try {
      // 1. flush all pending data
      await tableDataManager.flushAllBuffers();

      // 2. create backup manager
      final backupManager = BackupManager(this);

      // 3. create backup
      final backupPath = await backupManager.createBackup(compress: compress);
      return backupPath;
    } catch (e) {
      Logger.error('Create backup failed: $e', label: 'DataStore-backup');
      rethrow;
    }
  }

  /// Restore database from backup
  Future<bool> restore(String backupPath,
      {bool deleteAfterRestore = false}) async {
    if (!_baseInitialized) {
      await ensureInitialized();
    }

    try {
      final backupManager = BackupManager(this);
      await backupManager.restore(backupPath,
          deleteAfterRestore: deleteAfterRestore);
      return true;
    } catch (e) {
      Logger.error(
        'Failed to restore database: $e',
        label: 'DataStoreImpl.restore',
      );
      return false;
    }
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

        // Validate value using update-specific method
        if (!field.validateUpdateValue(value)) {
          Logger.warn(
            'Field ${field.name} value does not meet constraints: $value',
            label: 'DataStore._validateAndProcessUpdateData',
          );
          return null;
        }

        // If value is not null, validate and convert type
        if (value != null) {
          if (field.isValidDataType(value, field.type)) {
            result[field.name] = value;
          } else {
            try {
              final convertedValue = field.convertValue(value);
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
  Future<DbResult> updateInternal(
    String tableName,
    Map<String, dynamic> data,
    QueryCondition condition, {
    List<String>? orderBy,
    int? limit,
    int? offset,
    bool allowAll = false,
    bool continueOnPartialErrors = false,
  }) async {
    await ensureInitialized();

    // check if condition is empty, avoid accidental update of all records
    if (condition.isEmpty && !allowAll) {
      Logger.warn(
          'Update operation without condition, this may cause accidental update of all records, please use allowUpdateAll() method to explicitly confirm.',
          label: 'DataStore.updateInternal');
      return DbResult.error(
        type: ResultType.validationFailed,
        message:
            'Update operation must specify a filter condition. If you really need to update all records, please use allowUpdateAll() method to explicitly confirm.',
      );
    }

    final transaction = await _transactionManager!.beginTransaction();

    try {
      // validate data
      final schema = await getTableSchema(tableName);
      if (schema == null) {
        Logger.error('Table $tableName does not exist',
            label: 'DataStore.updateInternal');
        return DbResult.error(
          type: ResultType.notFound,
          message: 'Table $tableName does not exist',
        );
      }
      final validData =
          await _validateAndProcessUpdateData(schema, data, tableName);
      if (validData == null || validData.isEmpty) {
        return DbResult.error(
          type: ResultType.validationFailed,
          message: 'Data validation failed',
        );
      }

      // find matching records
      final records = await executeQuery(tableName, condition,
          orderBy: orderBy, limit: limit, offset: offset);
      if (records.isEmpty) {
        return DbResult.error(
          type: ResultType.notFound,
          message: 'No matching records found',
        );
      }

      final primaryKey = schema.primaryKey;
      final List<String> successKeys = [];
      final List<String> failedKeys = [];

      // check unique constraints
      for (var record in records) {
        final recordKey = record[primaryKey]?.toString() ?? '';
        if (recordKey.isEmpty) {
          continue; // Skip records without primary key
        }

        // merge update data
        final updatedRecord = Map<String, dynamic>.from(record)
          ..addAll(validData);

        // check unique constraints of fields
        for (var field in schema.fields) {
          if (field.unique && validData.containsKey(field.name)) {
            final value = validData[field.name];
            // find if other records are using this value
            final existing = await executeQuery(
                tableName,
                QueryCondition()
                  ..where(field.name, '=', value)
                  ..where(schema.primaryKey, '!=', record[schema.primaryKey]));
            if (existing.isNotEmpty) {
              Logger.warn(
                  'Warning: value $value of field ${field.name} already exists');
              failedKeys.add(recordKey);

              // If continueOnPartialErrors is true, skip this record and continue
              if (continueOnPartialErrors) {
                continue;
              }

              return DbResult.error(
                type: ResultType.uniqueViolation,
                message: 'Field ${field.name} value $value already exists',
                failedKeys: [recordKey],
              );
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

            final existing = await executeQuery(tableName, condition);
            if (existing.isNotEmpty) {
              Logger.warn(
                  'Warning: value ${record[schema.primaryKey]} of unique index ${index.actualIndexName} already exists');
              failedKeys.add(recordKey);

              // If continueOnPartialErrors is true, skip this record and continue
              if (continueOnPartialErrors) {
                continue;
              }

              return DbResult.error(
                type: ResultType.uniqueViolation,
                message: 'Index ${index.actualIndexName} value already exists',
                failedKeys: [recordKey],
              );
            }
          }
        }

        // Update cached record directly (without changing order) and update query cache
        dataCacheManager.updateCachedRecord(tableName, updatedRecord);
        await dataCacheManager.updateQueryCacheForRecord(
            tableName, recordKey, updatedRecord);
        // update write queue
        await tableDataManager.addToWriteBuffer(tableName, updatedRecord,
            isUpdate: true);

        // Add to success keys list
        successKeys.add(recordKey);
      }

      // commit transaction
      await _transactionManager!.commit(transaction);

      // If there are both successful and failed records
      if (successKeys.isNotEmpty && failedKeys.isNotEmpty) {
        return DbResult.batch(
          successKeys: successKeys,
          failedKeys: failedKeys,
          message:
              'Update partially successful, ${successKeys.length} records updated, ${failedKeys.length} records failed',
        );
      } else {
        return DbResult.success(
          successKeys: successKeys,
          message: 'Update successful, affected ${successKeys.length} records',
        );
      }
    } catch (e) {
      Logger.error('Update failed: $e', label: 'DataStore-update');
      await _transactionManager!.rollback(transaction);
      return DbResult.error(
        type: ResultType.dbError,
        message: 'Update failed: $e',
      );
    }
  }

  /// clear table
  Future<void> clear(String tableName) async {
    await ensureInitialized();
    final schema = await getTableSchema(tableName);
    if (schema == null) {
      Logger.error('Table $tableName does not exist', label: 'DataStore.clear');
      return;
    }
    final transaction = await _transactionManager!.beginTransaction();

    try {
      //  clear partition file deletion, auto-increment ID reset, and related cache cleanup
      await tableDataManager.clearTable(tableName);

      //  reset index
      await _indexManager?.resetIndexes(tableName);

      //   clear application layer cache
      await dataCacheManager.invalidateCache(tableName, isFullTableCache: true);

      await _transactionManager!.commit(transaction);
    } catch (e) {
      Logger.info('Clear table failed: $e', label: 'DataStore-clear');
      await _transactionManager!.rollback(transaction);
      rethrow;
    }
  }

  /// delete record
  Future<DbResult> deleteInternal(
    String tableName,
    QueryCondition condition, {
    List<String>? orderBy,
    int? limit,
    int? offset,
    bool allowAll = false,
  }) async {
    await ensureInitialized();

    // check if condition is empty, avoid accidental deletion of all records
    if (condition.isEmpty) {
      if (!allowAll) {
        Logger.warn(
            'Delete operation without condition, this may cause accidental deletion of all records, please use allowDeleteAll() method to explicitly confirm.',
            label: 'DataStore.deleteInternal');
        return DbResult.error(
          type: ResultType.validationFailed,
          message:
              'Delete operation must specify a filter condition. If you really need to delete all records, please use allowDeleteAll() method to explicitly confirm.',
        );
      } else {
        // If allowAll=true and no condition, use clear() for better performance
        Logger.info(
            'Using clear() for better performance when deleting all records',
            label: 'DataStore.deleteInternal');

        try {
          await clear(tableName);
          return DbResult.success(
            message: 'All records in table $tableName have been deleted',
          );
        } catch (e) {
          Logger.error('Failed to clear table: $e',
              label: 'DataStore.deleteInternal');
          return DbResult.error(
            type: ResultType.dbError,
            message: 'Failed to delete all records: $e',
          );
        }
      }
    }

    final transaction = await _transactionManager!.beginTransaction();

    try {
      // Get table file metadata to make an informed decision on the deletion strategy
      final tableMeta = await tableDataManager.getTableFileMeta(tableName);
      final totalSizeInBytes = tableMeta?.fileSizeInBytes ?? 0;

      // Get memory manager to access cache size limits
      final recordCacheSize = memoryManager?.getRecordCacheSize() ?? 10000;

      // get table schema
      final schema = await getTableSchema(tableName);
      if (schema == null) {
        Logger.warn('Table $tableName does not exist',
            label: 'DataStore.deleteInternal');
        return DbResult.error(
          type: ResultType.notFound,
          message: 'Table $tableName does not exist',
        );
      }

      final primaryKey = schema.primaryKey;
      final writeQueue = tableDataManager.writeBuffer[tableName];

      // Check if condition is an equality on primary key or unique field - this can be optimized
      bool isOptimizableQuery = false;

      // Analyze condition to check if it's a primary key or unique field equality operation
      if (!condition.isEmpty) {
        final conditionMap = condition.build();

        // Check if condition involves primary key with equality operator
        if (conditionMap.containsKey(primaryKey)) {
          final op = conditionMap[primaryKey];
          if (op is Map<String, dynamic> && op.containsKey('=')) {
            isOptimizableQuery = true;
          }
        }

        // If not primary key, check for unique field equality
        if (!isOptimizableQuery) {
          // Get unique fields from schema
          final uniqueFields = schema.fields
              .where((field) => field.unique && field.name != primaryKey)
              .map((field) => field.name)
              .toList();

          // Add unique indexes fields
          for (final index in schema.indexes.where((idx) => idx.unique)) {
            // Only consider single-field unique indexes for optimization
            if (index.fields.length == 1) {
              uniqueFields.add(index.fields[0]);
            }
          }

          // Check if condition is on a unique field
          for (final uniqueField in uniqueFields) {
            if (conditionMap.containsKey(uniqueField)) {
              final op = conditionMap[uniqueField];
              if (op is Map<String, dynamic> && op.containsKey('=')) {
                isOptimizableQuery = true;
                break;
              }
            }
          }
        }
      }

      // Decide strategy:
      // If the table's total size is small (e.g., less than 30% of the record cache limit)
      // or if it's an optimizable query (on a PK or unique index),
      // we can load matching records into memory for deletion.
      // This is generally faster for smaller datasets.
      final bool useInMemoryStrategy =
          isOptimizableQuery || (totalSizeInBytes < recordCacheSize * 0.3);

      // when table record count is less than threshold or this is an optimizable query, use regular method
      if (useInMemoryStrategy) {
        // standard method: get all records
        final recordsToDelete = await executeQuery(tableName, condition,
            orderBy: orderBy, limit: limit, offset: offset);

        if (recordsToDelete.isEmpty) {
          return DbResult.success(
            message: 'No records found to delete',
            successKeys: [],
          );
        }

        // Collect successful primary keys
        final List<String> successKeys = [];

        for (var record in recordsToDelete) {
          final pkValue = record[primaryKey]?.toString();
          if (pkValue == null) {
            continue;
          }
          // Add to success keys
          successKeys.add(pkValue);

        

          // Remove from write queue if it exists there (for insert/update operations that haven't been flushed)
          writeQueue?.remove(pkValue);
        }

        // Remove from record cache
        await dataCacheManager.invalidateRecords(
            tableName, successKeys, recordsToDelete);

        // Add records to delete buffer instead of directly writing to file
        await tableDataManager.addToDeleteBuffer(tableName, recordsToDelete);

        // Update indexes - still necessary to keep indexes in sync
        await _indexManager?.batchDeleteFromIndexes(tableName, recordsToDelete);

        await _transactionManager!.commit(transaction);
        return DbResult.success(
          successKeys: successKeys,
          message: 'Successfully deleted ${successKeys.length} records',
        );
      } else {
        final lockKey = 'table_$tableName';
        final operationId =
            'process_partitions_delete_${DateTime.now().millisecondsSinceEpoch}';
        try {
          await lockManager!.acquireExclusiveLock(lockKey, operationId);
          // create counters
          int totalProcessed = 0;
          int totalDeleted = 0;
          // Collect deleted record keys
          final List<String> deletedKeys = [];

          // build a process function, to check if each partition's record matches the delete condition
          Future<List<Map<String, dynamic>>> processFunction(
              records, partitionIndex, controller) async {
            // record original count
            int originalCount = records.length;

            // Create a new list with all records (do not filter out)
            final resultRecords = List<Map<String, dynamic>>.from(records);

            // collect deleted records
            final deletedRecords = <Map<String, dynamic>>[];

            // optimized: track if all non-deleted records have been deleted
            bool allDeleted = true;

            // replace deleted records with _deleted_:true marker, instead of removing
            for (int i = 0; i < resultRecords.length; i++) {
              final record = resultRecords[i];

              // skip if already deleted record
              if (isDeletedRecord(record)) continue;

              final matches = condition.matches(record);
              if (matches) {
                // Apply limit before processing the record for deletion
                if (limit != null && totalDeleted >= limit) {
                  if (!controller.isStopped) {
                    controller.stop();
                  }
                  allDeleted = false;
                  continue; // Stop processing further matches in this partition
                }

                totalDeleted++;

                // add to deleted records list
                deletedRecords.add(record);

                // get record primary key value
                final pkValue = record[primaryKey]?.toString();
                if (pkValue != null) {
                  // Add to deleted keys list
                  deletedKeys.add(pkValue);

                  // remove from write queue (if exists)
                  writeQueue?.remove(pkValue);
                }

                // replace with explicit delete marker instead of empty object, to prevent migration issues
                resultRecords[i] = {'_deleted_': true};
              } else {
                // has non-deleted records
                allDeleted = false;
              }
            }

            totalProcessed += originalCount;

            if (deletedRecords.isNotEmpty) {
              await dataCacheManager.invalidateRecords(
                  tableName, deletedKeys, deletedRecords);
              // batch update indexes
              await _indexManager?.batchDeleteFromIndexes(
                  tableName, deletedRecords);

              // Optimized: if all records are deleted, return empty list, directly remove the partition, more efficient
              if (allDeleted) {
                return [];
              }
            }

            return resultRecords;
          }

          // use processTablePartitions to process all partition
          await tableDataManager.processTablePartitions(
            tableName: tableName,
            processFunction: processFunction,
          );

          await _transactionManager!.commit(transaction);
          return DbResult.success(
            successKeys: deletedKeys,
            message:
                'Successfully deleted $totalDeleted records (processed $totalProcessed)',
          );
        } finally {
          // Always ensure the lock is released.
          lockManager!.releaseExclusiveLock(lockKey, operationId);
        }
      }
    } catch (e) {
      Logger.error('Delete failed: $e', label: 'DataStore-delete');
      await _transactionManager!.rollback(transaction);
      // Clear cache, ensure data consistency
      return DbResult.error(
        type: ResultType.dbError,
        message: 'Delete failed: $e',
      );
    }
  }

  /// drop table
  /// [isMigration] is true when dropping space table during migration,
  Future<void> dropTable(String tableName, {bool isMigration = false}) async {
    try {
      if (isMigration) {
        // During migration, only delete the table data directory in the current space
        Logger.info(
          'Deleting table $tableName data in space $_currentSpaceName during migration',
          label: 'DataStore.dropTable',
        );

        // Get table directory path
        final tablePath = await directoryManager!
            .getTableDirectoryPath(tableName, spaceName: _currentSpaceName);

        // Delete table directory
        if (tablePath != null && await storage.existsDirectory(tablePath)) {
          await storage.deleteDirectory(tablePath);
          Logger.info(
            'Deleted data directory for table $tableName in space $_currentSpaceName: $tablePath',
            label: 'DataStore.dropTable',
          );
        }

        // Remove table directory mapping from space configuration
        await directoryManager!.removeTableDirectoryMapping(tableName,
            spaceName: _currentSpaceName);

        return;
      } else {
        // Non-migration process, normal table deletion

        // Deleting a table requires updating statistics
        await tableDataManager.tableDeleted(tableName);

        // Get table path
        String? tablePath;
        try {
          tablePath = await _pathManager!.getTablePath(tableName);
        } catch (e) {
          // Ignore errors where the table does not exist
        }

        // Delete table structure
        if (schemaManager != null) {
          await schemaManager!.deleteTableSchema(tableName);
          // Release directory
          await directoryManager!.releaseTableDirectory(tableName);
        }

        // Delete table directory and all related files
        if (tablePath != null && await storage.existsDirectory(tablePath)) {
          await storage.deleteDirectory(tablePath);
        }

        // Clear table cache and other memory caches
        await _invalidateTableCaches(tableName, isFullTableCache: true);

        // Clear path cache
        _pathManager?.clearTableCache(tableName);

        // Add migration task to delete table data in each space
        await migrationManager?.addMigrationTask(tableName,
            [const MigrationOperation(type: MigrationType.dropTable)]);

        Logger.info('Table $tableName has been successfully deleted',
            label: 'DataStore.dropTable');
        return;
      }
    } catch (e) {
      Logger.error('Failed to delete table: $e', label: 'DataStore-dropTable');
      rethrow;
    }
  }

  /// get initial schema
  List<TableSchema> getInitialSchema() {
    final existingTableNames = _schemas.map((schema) => schema.name).toSet();

    // Add system tables
    for (final systemTable in SystemTable.gettableSchemas) {
      if (!existingTableNames.contains(systemTable.name)) {
        _schemas.add(systemTable);
      }
    }

    return _schemas;
  }

  /// Get table schema
  Future<TableSchema?> getTableSchema(String tableName) async {
    try {
      // 1. Try to get from cache first
      final cachedSchema = dataCacheManager.getSchema(tableName);
      if (cachedSchema != null) {
        return cachedSchema;
      }

      // 2. Use SchemaPartitionManager to load schema
      if (schemaManager == null) {
        throw StateError('SchemaPartitionManager not initialized');
      }

      final schemaJson = await schemaManager!.readTableSchema(tableName);

      if (schemaJson != null) {
        try {
          final schemaMap = jsonDecode(schemaJson) as Map<String, dynamic>;
          final schema = TableSchema.fromJson(schemaMap);

          // Cache and return schema
          dataCacheManager.cacheSchema(tableName, schema);
          return schema;
        } catch (e) {
          Logger.error('Failed to parse schema JSON: $e',
              label: 'DataStoreImpl.getTableSchema');
        }
      }

      // Return empty schema if not found
      return null;
    } catch (e) {
      Logger.error(
        'Failed to get table schema: $e',
        label: 'DataStore.getTableSchema',
      );
      return null;
    }
  }

  /// check table exists
  Future<bool> tableExists(String tableName) async {
    try {
      if (schemaManager == null) {
        throw StateError('SchemaPartitionManager not initialized');
      }

      final schema = await schemaManager!.readTableSchema(tableName);
      return schema != null;
    } catch (e) {
      Logger.error(
        'Failed to check table existence: $e',
        label: 'DataStoreImpl._tableExists',
      );
      return false;
    }
  }

  /// get all table names
  Future<List<String>> getTableNames() async {
    try {
      if (schemaManager == null) {
        throw StateError('SchemaPartitionManager not initialized');
      }

      return await schemaManager!.listAllTables();
    } catch (e) {
      Logger.error(
        'Failed to get table names: $e',
        label: 'DataStoreImpl.getTableNames',
      );
      return [];
    }
  }

  /// batch insert data
  /// [allowPartialErrors] if true, continue processing remaining records even if some fail
  Future<DbResult> batchInsert(
      String tableName, List<Map<String, dynamic>> records,
      {bool allowPartialErrors = true}) async {
    await ensureInitialized();

    TableSchema? schema;
    try {
      // 1. Get table schema and validate data
      schema = await getTableSchema(tableName);
      if (schema == null || schema.name.isEmpty) {
        Logger.error('Table $tableName does not exist',
            label: 'DataStore.batchInsert');
        return DbResult.error(
          type: ResultType.notFound,
          message: 'Table $tableName does not exist',
        );
      }

      final primaryKey = schema.primaryKey;
      final validRecords = <Map<String, dynamic>>[];
      final invalidRecords = <Map<String, dynamic>>[];
      final List<String> successKeys = [];
      final List<String> failedKeys = [];

      // Begin a single transaction for the entire batch
      final transaction = await _transactionManager!.beginTransaction();

      try {
        // Process records in smaller batches to maintain memory efficiency
        const int batchSize = 1000;

        for (int i = 0; i < records.length; i += batchSize) {
          final int end =
              (i + batchSize < records.length) ? i + batchSize : records.length;
          final currentBatch = records.sublist(i, end);

          // Process each record in the current batch
          for (var record in currentBatch) {
            try {
              // Validate and process data
              final validData =
                  await _validateAndProcessData(schema, record, tableName);
              if (validData == null) {
                invalidRecords.add(record);
                final failedKey = record[primaryKey]?.toString() ?? '';
                if (failedKey.isNotEmpty) {
                  failedKeys.add(failedKey);
                }
                continue;
              }

              // Check unique constraints
              if (await _indexManager?.checkUniqueConstraints(
                      tableName, validData) ==
                  false) {
                invalidRecords.add(record);
                final failedKey = validData[primaryKey]?.toString() ?? '';
                if (failedKey.isNotEmpty) {
                  failedKeys.add(failedKey);
                }
                continue;
              }

              // Add to valid records
              validRecords.add(validData);

              // Add to cache and write buffer (like the insert method does)
              dataCacheManager.addCachedRecord(tableName, validData);
              await tableDataManager.addToWriteBuffer(tableName, validData,
                  isUpdate: false);

              // Track successful keys
              final successKey = validData[primaryKey]?.toString() ?? '';
              if (successKey.isNotEmpty) {
                successKeys.add(successKey);
              }
            } catch (e) {
              // Handle individual record errors
              Logger.warn('Error processing record: $e',
                  label: 'DataStore.batchInsert');
              invalidRecords.add(record);
              final failedKey = record[primaryKey]?.toString() ?? '';
              if (failedKey.isNotEmpty) {
                failedKeys.add(failedKey);
              }

              if (!allowPartialErrors) {
                // If not allowing partial errors, rollback and return error
                await _transactionManager!.rollback(transaction);
                return DbResult.error(
                  type: ResultType.dbError,
                  message: 'Error processing record: $e',
                  failedKeys: failedKeys,
                );
              }
            }
          }

          // Yield to event loop periodically to prevent UI freezing
          await Future.delayed(Duration.zero);
        }

        // If no valid records and not allowing partial errors, return error
        if (validRecords.isEmpty) {
          await _transactionManager!.rollback(transaction);
          return DbResult.error(
            type: ResultType.validationFailed,
            message: 'All data validation failed',
            failedKeys: failedKeys,
          );
        }

        // If not allowing partial errors and some records failed, return error
        if (!allowPartialErrors && invalidRecords.isNotEmpty) {
          await _transactionManager!.rollback(transaction);
          return DbResult.error(
            type: ResultType.validationFailed,
            message:
                'Some records failed validation or have unique constraint conflicts',
            failedKeys: failedKeys,
          );
        }

        // Commit the transaction to ensure all data is written
        await _transactionManager!.commit(transaction);

        // Async log transaction
        _logTransactionAsync('batchInsert', tableName, {
          'count': validRecords.length,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });

        // Invalidate query caches for all newly inserted valid records
        // Use a non-blocking future to avoid delaying the response
        Future(() => dataCacheManager.invalidateAffectedQueries(
            tableName, records: validRecords));

        // Return result
        if (invalidRecords.isEmpty) {
          return DbResult.success(
            successKeys: successKeys,
            message: 'All records inserted successfully',
          );
        } else {
          return DbResult.batch(
            successKeys: successKeys,
            failedKeys: failedKeys,
            message:
                'Partial records inserted successfully, ${validRecords.length} successful, ${failedKeys.length} failed',
          );
        }
      } catch (e) {
        // Rollback transaction on error
        await _transactionManager!.rollback(transaction);
        rethrow;
      }
    } catch (e) {
      Logger.error('Batch insertion failed: $e',
          label: 'DataStore-batchInsert');

      // try to collect primary keys of original records as failed keys list
      List<String> failedKeys = [];
      try {
        if (schema != null) {
          final primaryKey = schema.primaryKey;
          failedKeys = records
              .map((record) => record[primaryKey]?.toString() ?? '')
              .where((key) => key.isNotEmpty)
              .toList();
        }
      } catch (_) {
        // Ignore errors during error handling
      }

      return DbResult.error(
        type: ResultType.dbError,
        message: 'Batch insertion failed: $e',
        failedKeys: failedKeys,
      );
    }
  }

  /// Async log transaction
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

  /// load data from specified path
  Future<void> _loadTableRecordToCache() async {
    final bool? enablePrewarm = config.enablePrewarmCache;

    if (enablePrewarm == false) {
      return; // Explicitly disabled
    }

    // If enablePrewarm is null (auto mode)
    try {
      if (enablePrewarm == true) {
        // Explicitly enabled, proceed with loading
        await _executePrewarm();
        return;
      }

      final spaceConfig = await getSpaceConfig();
      final totalSize = spaceConfig?.totalDataSizeBytes ?? 0;
      final int prewarmThresholdBytes = config.prewarmThresholdMB * 1024 * 1024;

      if (totalSize < prewarmThresholdBytes) {
        await _executePrewarm();
      }
    } catch (e) {
      Logger.error('Failed to check for automatic prewarming: $e',
          label: 'DataStore._loadTableRecordToCache');
    }
  }

  Future<void> _executePrewarm() async {
    try {
      // From schemaManager get all tables
      final allTables = await getTableNames();
      if (allTables.isEmpty) {
        return;
      }

      // Sort tables by priority
      final prioritizedTables = await _prioritizeTables(allTables);

      // Load tables
      // Use a standard indexed for-loop for maximum safety and efficiency.
      for (int i = 0; i < prioritizedTables.length; i++) {
        final tableName = prioritizedTables[i];
        try {
          // Check if table exists in current space
          final tableExistsInSpace = await tableExistsInCurrentSpace(tableName);
          if (!tableExistsInSpace) {
            continue;
          }

          final schema = await getTableSchema(tableName);
          if (schema == null || schema.name.isEmpty) {
            continue;
          }

          // Load all records
          if (await tableDataManager.allowFullTableCache(tableName)) {
            // Use executeQuery to get a consistent snapshot, as it correctly
            // handles merging write buffers and filtering delete buffers.
            final records = await executeQuery(tableName, QueryCondition());

            await dataCacheManager.cacheEntireTable(
              tableName,
              schema.primaryKey,
              records,
            );
          }
          // Yield control to the event loop to prevent UI freezing during a long prewarm process.
          await Future.delayed(Duration.zero);
        } catch (e, stackTrace) {
          Logger.error('Load table data failed: $tableName, error: $e',
              label: 'DataStore._executePrewarm');
          Logger.error('Stack trace: $stackTrace',
              label: 'DataStore._executePrewarm');
          continue; // Continue load other tables
        }
      }
    } catch (e, stackTrace) {
      Logger.error('Error in _executePrewarm: $e',
          label: 'DataStore._executePrewarm');
      Logger.error('Stack trace: $stackTrace',
          label: 'DataStore._executePrewarm');
    }
  }

  /// Sort tables by priority
  Future<List<String>> _prioritizeTables(List<String> allTables) async {
    // Priority groups: global tables, normal tables
    final startupTables = <String>[];
    final globalTables = <String>[];
    final normalTables = <String>[];

    for (final tableName in allTables) {
      // Check if it's a global table
      final isGlobal = await schemaManager?.isTableGlobal(tableName) ?? false;
      if (isGlobal) {
        globalTables.add(tableName);
      } else {
        normalTables.add(tableName);
      }
    }

    // Combine priorities: startup cache tables > global tables > normal tables
    return [...startupTables, ...globalTables, ...normalTables];
  }

  /// query by id
  Future<Map<String, dynamic>?> queryById(String tableName, dynamic id) async {
    try {
      final schema = await getTableSchema(tableName);
      if (schema == null) {
        Logger.error('Table $tableName does not exist',
            label: 'DataStore.queryById');
        return null;
      }
      final condition = QueryCondition()..where(schema.primaryKey, '=', id);

      final results = await executeQuery(
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
      final schema = await getTableSchema(tableName);
      if (schema == null) {
        Logger.error('Table $tableName does not exist',
            label: 'DataStore.queryBy');
        return [];
      }
      final condition = QueryCondition()..where(field, '=', value);

      return await executeQuery(tableName, condition);
    } catch (e) {
      Logger.error('Query by field failed: $e', label: 'DataStore.queryBy');
      rethrow;
    }
  }

  /// Switch space
  Future<bool> switchSpace({String spaceName = 'default'}) async {
    await ensureInitialized();

    if (_currentSpaceName == spaceName) {
      return true;
    }

    // Check if global configuration has migration tasks
    final globalConfig = await getGlobalConfig();
    if (globalConfig?.hasMigrationTask == true) {
      // Check if currently migrating the space to switch to
      bool isTargetSpaceMigrating = false;

      if (migrationManager != null) {
        // Check if current migration tasks include the target space
        isTargetSpaceMigrating =
            await migrationManager!.isSpaceBeingMigrated(spaceName);
      }

      if (isTargetSpaceMigrating) {
        // 1. Adjust space priority, prioritize migrating this space
        final updatedSpaces = List<String>.from(globalConfig!.spaceNames)
          ..remove(spaceName)
          ..insert(0, spaceName);
        final updatedConfig =
            globalConfig.copyWith(spaceNames: updatedSpaces.toSet());
        await saveGlobalConfig(updatedConfig);

        // 2. Wait for this space's migration to complete
        Logger.info(
          'Space [$spaceName] is being migrated, waiting for migration to complete before switching',
          label: 'DataStoreImpl.switchSpace',
        );

        // Use timeout protection to avoid infinite waiting
        bool migrationCompleted = false;
        try {
          migrationCompleted = await migrationManager!.waitForSpaceMigration(
              spaceName,
              timeout: const Duration(minutes: 5));
        } catch (e) {
          Logger.error(
            'Error occurred while waiting for space migration to complete: $e',
            label: 'DataStoreImpl.switchSpace',
          );
        }

        if (!migrationCompleted) {
          Logger.warn(
            'Timeout waiting for space [$spaceName] migration to complete, cannot switch space',
            label: 'DataStoreImpl.switchSpace',
          );
          return false;
        }

        // Migration completed, continue switching space
        Logger.info(
          'Space [$spaceName] migration has completed, continuing switch',
          label: 'DataStoreImpl.switchSpace',
        );
      } else {
        // Currently migrating other spaces, but not the target space
        Logger.info(
          'Migration tasks are in progress, but do not affect switching to space [$spaceName]',
          label: 'DataStoreImpl.switchSpace',
        );
      }
    }

    final oldSpaceName = _currentSpaceName;
    _currentSpaceName = spaceName;
    try {
      await saveAllCacheBeforeExit();

      // Update configuration
      if (_config != null) {
        _config = _config!.copyWith(spaceName: _currentSpaceName);
      }

      // Clear caches
      await dataCacheManager.onBasePathChanged();
      await indexManager?.onSpacePathChanged();
      tableDataManager.writeBuffer.clear();

      // Reinitialize database
      _isInitialized = false;
      _baseInitialized = false;
      await initialize(dbPath: _config?.dbPath, config: _config);

      // Add new space to GlobalConfig
      final globalConfig = await getGlobalConfig();
      if (globalConfig != null &&
          !globalConfig.spaceNames.contains(spaceName)) {
        final updatedConfig = globalConfig.addSpace(spaceName);
        await saveGlobalConfig(updatedConfig);
      }

      return true;
    } catch (e) {
      // Rollback on failure
      _currentSpaceName = oldSpaceName;
      if (_config != null) {
        _config = _config!.copyWith(spaceName: oldSpaceName);
      }
      Logger.error('Space switch failed: $e', label: 'DataStore.switchSpace');
      return false;
    }
  }

  /// Save all cache data before application exit
  Future<bool> saveAllCacheBeforeExit() async {
    try {
      if (!_isInitialized) return false;

      // Process all table data buffers (write and delete)
      await tableDataManager.flushAllBuffers();

      // Process index write buffer
      await _indexManager?.prepareForClose();

      // Save all caches
      final hasChanges = await dataCacheManager.persistAllCaches();

      Logger.debug(
          'Data saved successfully before application exit${hasChanges ? "" : ", no changes"}',
          label: 'DataStoreImpl.saveAllCacheBeforeExit');

      return hasChanges;
    } catch (e) {
      Logger.error('Failed to save cache before exit: $e',
          label: 'DataStoreImpl.saveAllCacheBeforeExit');
      return false;
    }
  }

  /// Delete database
  Future<void> deleteDatabase({String? dbPath, String? dbName}) async {
    try {
      final dbDirPath = await getDatabasePath(dbPath: dbPath, dbName: dbName);
      await close();

      if (await storage.existsDirectory(dbDirPath)) {
        await storage.deleteDirectory(dbDirPath);
        Logger.info('Database deleted: $dbDirPath');
      }

      _instances.remove(_instanceKey);
    } catch (e) {
      Logger.error('Delete database failed: $e',
          label: 'DataStore.deleteDatabase');
      rethrow;
    }
  }

  /// Set key-value pair
  Future<bool> setValue(String key, dynamic value,
      {bool isGlobal = false}) async {
    await ensureInitialized();

    final tableName = SystemTable.getKeyValueName(isGlobal);

    // Build data
    final data = {
      'key': key,
      'value': jsonEncode(value),
      'updated_at': DateTime.now().toIso8601String(),
    };

    try {
      final existing = await executeQuery(
          tableName, QueryCondition()..where('key', '=', key));

      if (existing.isEmpty) {
        final result = await insert(tableName, data);
        return result.isSuccess;
      } else {
        // Build update condition
        final condition = QueryCondition()..where('key', '=', key);
        final result = await updateInternal(
          tableName,
          data,
          condition,
        );
        return result.isSuccess;
      }
    } catch (e) {
      Logger.error('Set key-value pair failed: $e',
          label: 'DataStore.setValue');
      return false;
    }
  }

  /// Get key-value pair
  Future<dynamic> getValue(String key, {bool isGlobal = false}) async {
    await ensureInitialized();

    final tableName = SystemTable.getKeyValueName(isGlobal);
    final result =
        await executeQuery(tableName, QueryCondition()..where('key', '=', key));
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
    await ensureInitialized();

    final tableName = SystemTable.getKeyValueName(isGlobal);
    // Build delete condition
    final condition = QueryCondition()..where('key', '=', key);
    await deleteInternal(tableName, condition);
    return true;
  }

  /// Get cache stats
  Map<String, int> getCacheStats() {
    return tableDataManager.writeBuffer
        .map((key, value) => MapEntry(key, value.length));
  }

  /// Get table info
  Future<TableInfo?> getTableInfo(String tableName) async {
    await ensureInitialized();
    final schema = await getTableSchema(tableName);
    if (schema == null) {
      Logger.error('Table $tableName does not exist',
          label: 'DataStore.getTableInfo');
      return null;
    }
    final dataPath = await pathManager.getDataMetaPath(tableName);
    DateTime? createdAt;
    if (await storage.existsFile(dataPath)) {
      createdAt = await storage.getFileCreationTime(dataPath);
    }
    return TableInfo(
      tableName: tableName,
      recordCount: await tableDataManager.getTableRecordCount(tableName),
      cacheCount: dataCacheManager.getTableCacheCount(tableName),
      fileSize: await tableDataManager.getTableFileSize(tableName),
      indexCount: schema.indexes.length,
      schema: schema,
      isGlobal: schema.isGlobal,
      lastModified: tableDataManager.getLastModifiedTime(tableName),
      createdAt: createdAt,
    );
  }

  /// Add field to table
  Future<void> addField(
    String tableName,
    FieldSchema field,
  ) async {
    final schema = await getTableSchema(tableName);
    if (schema == null) {
      return;
    }

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
  ) async {
    final schema = await getTableSchema(tableName);
    if (schema == null) {
      return;
    }

    // Check if field exists
    if (!schema.fields.any((f) => f.name == fieldName)) {
      Logger.warn(
        'Field $fieldName not found in table $tableName',
        label: "DataStore.removeField",
      );
      return;
    }

    // Delete all indexes that include this field
    await indexManager?.removeIndex(tableName, fields: [fieldName]);

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
  ) async {
    try {
      final schema = await getTableSchema(tableName);
      if (schema == null) {
        return;
      }
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

  /// Modify a field in the table schema
  Future<void> modifyField(
    String tableName,
    String fieldName,
    FieldSchemaUpdate newField,
  ) async {
    try {
      final schema = await getTableSchema(tableName);
      if (schema == null) {
        throw BusinessError(
          'Table $tableName not found',
          type: BusinessErrorType.invalidData,
        );
      }

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

      // create updated field, handle explicitly set to null case
      dynamic updatedDefaultValue = oldField.defaultValue;
      if (newField.isExplicitlySet('defaultValue')) {
        updatedDefaultValue = newField.defaultValue;
      }

      int? updatedMaxLength = oldField.maxLength;
      if (newField.isExplicitlySet('maxLength')) {
        updatedMaxLength = newField.maxLength;
      }

      int? updatedMinLength = oldField.minLength;
      if (newField.isExplicitlySet('minLength')) {
        updatedMinLength = newField.minLength;
      }

      num? updatedMinValue = oldField.minValue;
      if (newField.isExplicitlySet('minValue')) {
        updatedMinValue = newField.minValue;
      }

      num? updatedMaxValue = oldField.maxValue;
      if (newField.isExplicitlySet('maxValue')) {
        updatedMaxValue = newField.maxValue;
      }

      String? updatedComment = oldField.comment;
      if (newField.isExplicitlySet('comment')) {
        updatedComment = newField.comment;
      }

      DefaultValueType updatedDefaultValueType = oldField.defaultValueType;
      if (newField.isExplicitlySet('defaultValueType')) {
        updatedDefaultValueType =
            newField.defaultValueType ?? DefaultValueType.none;
      }

      final updatedField = oldField.copyWith(
        type: newField.type ?? oldField.type,
        nullable: newField.nullable ?? oldField.nullable,
        defaultValue: updatedDefaultValue,
        unique: newField.unique ?? oldField.unique,
        comment: updatedComment,
        minLength: updatedMinLength,
        maxLength: updatedMaxLength,
        minValue: updatedMinValue,
        maxValue: updatedMaxValue,
        defaultValueType: updatedDefaultValueType,
      );

      // Update schema
      final fields = List<FieldSchema>.from(schema.fields);
      final fieldIndex = fields.indexWhere((f) => f.name == fieldName);
      fields[fieldIndex] = updatedField;

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

  /// Update table schema
  Future<void> updateTableSchema(
    String tableName,
    TableSchema schema,
  ) async {
    try {
      if (schemaManager == null) {
        throw StateError('SchemaPartitionManager not initialized');
      }
      await schemaManager!
          .saveTableSchema(tableName, jsonEncode(schema.toJson()));

      dataCacheManager.cacheSchema(tableName, schema);
      dataCacheManager.persistAllCaches();
    } catch (e) {
      Logger.error(
        'Failed to update schema: $e',
        label: 'DataStoreImpl.updateTableSchema',
      );
      rethrow;
    }
  }

  /// Invalidate all caches for table
  Future<void> _invalidateTableCaches(String tableName,
      {bool isFullTableCache = false}) async {
    await dataCacheManager.invalidateCache(tableName,
        isFullTableCache: isFullTableCache);
    tableDataManager.writeBuffer.remove(tableName);

    // Clear index cache
    try {
      // Clear primary key index cache
      indexManager?.invalidateCache(tableName, 'pk_$tableName');

      // Get table structure, clear all index caches
      final schema = await getTableSchema(tableName);
      if (schema != null) {
        final List addToClear = [];
        // clear field unique index cache
        for (var field in schema.fields) {
          if (field.unique) {
            indexManager?.invalidateCache(tableName, 'uniq_${field.name}');
            addToClear.add(field.name);
          }
        }

        // Clear index cache for each index
        for (var index in schema.indexes) {
          //  If index has only one field and it's already cleared, skip
          if (index.fields.length == 1 &&
              addToClear.contains(index.fields.first)) {
            continue;
          }
          // Use actualIndexName to ensure clearing the correct cache
          if (index.actualIndexName.isNotEmpty) {
            indexManager?.invalidateCache(tableName, index.actualIndexName);
          }
          // If index has explicit name, also clear cache for that name
          if (index.indexName != null && index.indexName!.isNotEmpty) {
            indexManager?.invalidateCache(tableName, index.indexName!);
          }
        }
      }
    } catch (e) {
      Logger.error(
        'Error clearing cache for table [$tableName]: $e',
        label: 'DataStoreImpl._invalidateTableCaches',
      );
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
        if (!await _integrityChecker!.validateMigration(
          schema.name,
          schema,
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

  /// Get global configuration
  Future<GlobalConfig?> getGlobalConfig() async {
    try {
      // Get from cache first
      if (_globalConfigCache != null) {
        return _globalConfigCache;
      }

      final configPath = pathManager.getGlobalConfigPath();

      if (!await storage.existsFile(configPath)) {
        return null;
      }

      final content = await storage.readAsString(configPath);
      if (content == null || content.isEmpty) return null;

      final config =
          GlobalConfig.fromJson(jsonDecode(content) as Map<String, dynamic>);

      // Update cache
      _globalConfigCache = config;

      return config;
    } catch (e) {
      Logger.error('Failed to get global config: $e',
          label: 'DataStoreImpl.getGlobalConfig');
      return null;
    }
  }

  /// Save global configuration
  Future<void> saveGlobalConfig(GlobalConfig config) async {
    try {
      // Update memory cache
      _globalConfigCache = config;

      final configPath = pathManager.getGlobalConfigPath();

      // Ensure directory exists
      await storage.ensureDirectoryExists(
        configPath.substring(0, configPath.lastIndexOf('/')),
      );

      // Serialize and save
      final content = jsonEncode(config.toJson());
      await storage.writeAsString(configPath, content);
    } catch (e) {
      Logger.error('Failed to save global config: $e',
          label: 'DataStoreImpl.saveGlobalConfig');
    }
  }

  /// Get all space names
  Future<Set<String>> getAllSpaceNames() async {
    try {
      // First load global configuration
      final globalConfig = await getGlobalConfig();
      if (globalConfig != null && globalConfig.spaceNames.isNotEmpty) {
        return globalConfig.spaceNames;
      }

      // If no configuration record, get from file system
      final spacesPath = pathJoin(config.dbPath!, 'spaces');
      final spaceNames = <String>{};

      try {
        if (await storage.existsDirectory(spacesPath)) {
          // Use non-recursive mode to get direct subdirectories
          final entries =
              await storage.listDirectory(spacesPath, recursive: false);

          for (final entry in entries) {
            if (await storage.existsDirectory(entry)) {
              // Extract directory name
              final name = entry.split('/').last.split('\\').last;
              if (name != '.' && name != '..') {
                spaceNames.add(name);
              }
            }
          }
        }
      } catch (e) {
        Logger.error('Failed to read space directory: $e',
            label: 'DataStoreImpl.getAllSpaceNames');
      }

      // If spaces were found, update global configuration
      if (spaceNames.isNotEmpty) {
        // Ensure default space is included
        if (!spaceNames.contains('default')) {
          spaceNames.add('default');
        }
        final newConfig = GlobalConfig(spaceNames: spaceNames);
        await saveGlobalConfig(newConfig);
      }

      return spaceNames.isEmpty ? {'default'} : spaceNames;
    } catch (e) {
      Logger.error('Failed to get all space names: $e',
          label: 'DataStoreImpl.getAllSpaceNames');
      return {'default'};
    }
  }

  /// Add space to global configuration
  Future<void> addSpaceToGlobalConfig(String spaceName) async {
    try {
      if (spaceName.isEmpty) return;

      // Load existing configuration
      final existingConfig = await getGlobalConfig() ?? GlobalConfig();

      // Add new space
      final updatedConfig = existingConfig.addSpace(spaceName);

      // If there are changes, save the updated configuration
      if (updatedConfig.spaceNames.length != existingConfig.spaceNames.length) {
        await saveGlobalConfig(updatedConfig);
      }
    } catch (e) {
      Logger.error('Failed to add space to global config: $e',
          label: 'DataStoreImpl.addSpaceToGlobalConfig');
    }
  }

  /// Check and migrate old path structure (if needed)
  Future<void> _migrateOldStructureIfNeeded() async {
    try {
      // Create old structure migration handler
      final migrationHandler = OldStructureMigrationHandler(
        dataStore: this,
        pathManager: _pathManager!,
        storage: storage,
      );

      // Execute migration (this operation will block the main thread)
      await migrationHandler.migrate();
    } catch (e) {
      Logger.error('Error checking and migrating old path structure: $e',
          label: 'DataStoreImpl._migrateOldStructureIfNeeded');
      // Error doesn't affect continued use, just log it
    }
  }

  /// Check if table exists in current space
  Future<bool> tableExistsInCurrentSpace(String tableName) async {
    try {
      final spaceConfig = await getSpaceConfig();
      if (spaceConfig == null) {
        return false;
      }

      final spacePrefix = _currentSpaceName;
      final tableKey = '$spacePrefix:$tableName';
      return spaceConfig.tableDirectoryMap.containsKey(tableKey);
    } catch (e) {
      Logger.error('Error checking if table exists in current space: $e',
          label: 'DataStoreImpl.tableExistsInCurrentSpace');
      return false;
    }
  }

  /// Set table's primary key configuration
  Future<void> setPrimaryKeyConfig(
      String tableName, PrimaryKeyConfig config) async {
    try {
      // 1. Get table structure
      final schema = await getTableSchema(tableName);
      if (schema == null || schema.fields.isEmpty) {
        throw BusinessError(
          'Table $tableName not found',
          type: BusinessErrorType.schemaError,
        );
      }

      final newSchema = schema.copyWith(primaryKeyConfig: config);

      // 4. If settings haven't changed, return directly
      if (schema.primaryKeyConfig.type == config.type &&
          schema.primaryKeyConfig.isOrdered == config.isOrdered &&
          schema.primaryKeyConfig.name == config.name) {
        // For sequential auto-increment mode, check detailed configuration
        if (config.type == PrimaryKeyType.sequential &&
            schema.primaryKeyConfig.sequentialConfig?.toJson().toString() ==
                config.sequentialConfig?.toJson().toString()) {
          return;
        }
        // For timestamp or date prefix mode, no need for additional configuration checks
        if (config.type == PrimaryKeyType.timestampBased ||
            config.type == PrimaryKeyType.datePrefixed ||
            config.type == PrimaryKeyType.shortCode) {
          return;
        }
      }

      // 5. If primary key generation method has changed, output warning
      if (schema.primaryKeyConfig.type != config.type) {
        Logger.warn(
          'Primary key generation method changed: table[$tableName] from ${schema.primaryKeyConfig.type} to ${config.type}, existing record primary key values will be preserved, this change only affects new records',
          label: 'DataStoreImpl.setPrimaryKeyConfig',
        );
      }

      try {
        // 6. Update table structure
        await updateTableSchema(tableName, newSchema);

        // 7. If auto primary key generation is enabled, create auto-increment ID file
        if (config.type == PrimaryKeyType.sequential) {
          final maxIdPath = await pathManager.getAutoIncrementPath(tableName);
          if (!await storage.existsFile(maxIdPath)) {
            // Get initial value
            int initialValue = 0;
            if (config.sequentialConfig != null) {
              initialValue = config.sequentialConfig!.initialValue;
            }
            await storage.writeAsString(maxIdPath, initialValue.toString());
          }
        }

        // 8. Update cache
        dataCacheManager.cacheSchema(tableName, newSchema);

        Logger.info(
          'Table $tableName primary key configuration has been updated to ${config.type}',
          label: 'DataStore.setPrimaryKeyConfig',
        );
      } catch (e) {
        Logger.error(
          'Failed to update primary key configuration: $e',
          label: 'DataStore.setPrimaryKeyConfig',
        );
        rethrow;
      }
    } catch (e) {
      Logger.error(
        'Failed to set primary key configuration: $e',
        label: 'DataStore.setPrimaryKeyConfig',
      );
      rethrow;
    }
  }

  /// Validate if primary key value maintains ordering
  Future<bool> _validatePrimaryKeyOrder(
      String tableName, dynamic newId, PrimaryKeyType type) async {
    try {
      // Get table metadata
      final fileMeta = await tableDataManager.getTableFileMeta(tableName);
      if (fileMeta == null ||
          fileMeta.partitions == null ||
          fileMeta.partitions!.isEmpty) {
        return true; // New table, no need to check ordering
      }

      // Only find the last non-empty partition (usually contains the maximum primary key value)
      PartitionMeta? lastPartition;
      for (final partition in fileMeta.partitions!) {
        if (partition.totalRecords > 0 && partition.maxPrimaryKey != null) {
          if (lastPartition == null || partition.index > lastPartition.index) {
            lastPartition = partition;
          }
        }
      }

      if (lastPartition == null || lastPartition.maxPrimaryKey == null) {
        return true; // Cannot determine maximum primary key value, skip check
      }

      // Compare new ID with maximum ID
      int compareResult =
          ValueComparator.compare(newId, lastPartition.maxPrimaryKey);

      // Determine if strict incremental ordering is required based on primary key type
      switch (type) {
        case PrimaryKeyType.sequential:
        case PrimaryKeyType.timestampBased:
        case PrimaryKeyType.datePrefixed:
        case PrimaryKeyType.shortCode:
          // Ordered primary keys should be strictly increasing
          return compareResult > 0;
        case PrimaryKeyType.none:
          // Other primary key types, more relaxed check
          return true;
      }
    } catch (e) {
      Logger.error('Failed to check primary key ordering: $e',
          label: 'DataStore._validatePrimaryKeyOrder');
      // On error, allow insertion to be safe
      return true;
    }
  }

  /// Get information about the current space
  Future<SpaceInfo> getSpaceInfo() async {
    try {
      // Get space configuration
      final config = await getSpaceConfig();
      // Get only user-created tables by using onlyUserTables=true
      final allTables =
          await schemaManager?.listAllTables(onlyUserTables: true) ?? [];

      // Check if statistics are stale (older than 1 hour)
      final currentTime = DateTime.now();
      final lastStatsTime = config?.lastStatisticsTime ?? DateTime(2000);
      final statsDuration = currentTime.difference(lastStatsTime);

      if (statsDuration.inHours > 1) {
        // Schedule statistics recalculation without waiting for it to complete
        tableDataManager.recalculateAllStatistics();
      }

      // Get only tables that exist in the current space
      final userTables = <String>[];
      for (final tableName in allTables) {
        // Check if the table is used in the current space
        if (await tableExistsInCurrentSpace(tableName)) {
          userTables.add(tableName);
        }
      }

      // Create the SpaceInfo object with user-table information
      return SpaceInfo(
        spaceName: _currentSpaceName,
        version: await getVersion(),
        tableCount: userTables.length, // Use actual count of user tables
        recordCount: config?.totalRecordCount ?? 0,
        dataSizeBytes: config?.totalDataSizeBytes ?? 0,
        lastStatisticsTime: config?.lastStatisticsTime,
        tables: userTables,
      );
    } catch (e) {
      Logger.error('Failed to get space info: $e',
          label: 'DataStoreImpl.getSpaceInfo');
      rethrow;
    }
  }

  /// Stream records from a table with filtering
  /// This method provides an efficient way to process large datasets by streaming records one at a time
  ///
  /// @param tableName The name of the table to stream records from
  /// @param condition Optional query conditions to filter records
  /// @param selectedFields Optional list of fields to include in the results
  Stream<Map<String, dynamic>> streamRecords(
    String tableName, {
    QueryCondition? condition,
    List<String>? selectedFields,
  }) async* {
    try {
      await ensureInitialized();
      // Check if table exists
      if (!await tableExists(tableName)) {
        Logger.error('Table $tableName does not exist',
            label: 'DataStoreImpl.streamRecords');
        return;
      }

      // Get table schema
      final schema = await getTableSchema(tableName);
      if (schema == null) {
        Logger.error('Failed to get schema for $tableName',
            label: 'DataStoreImpl.streamRecords');
        return;
      }

      // Stream all records from table using the existing tableDataManager method
      final recordStream = tableDataManager.streamRecords(tableName);

      // Stream and filter records one by one
      await for (final record in recordStream) {
        // Apply filters if condition is provided
        if (condition != null && !condition.isEmpty) {
          if (!condition.matches(record)) {
            continue; // Skip non-matching records
          }
        }

        // Apply field selection (projection) and yield the record
        yield selectFields(record, selectedFields);
      }
    } catch (e) {
      Logger.error('Error streaming records: $e',
          label: 'DataStoreImpl.streamRecords');
    }
  }

  /// Select specific fields from a record
  Map<String, dynamic> selectFields(
      Map<String, dynamic> record, List<String>? fields) {
    if (fields == null || fields.isEmpty) {
      return record;
    }

    final result = <String, dynamic>{};
    for (final field in fields) {
      if (record.containsKey(field)) {
        result[field] = record[field];
      }
    }
    return result;
  }
}
