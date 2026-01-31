import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:path/path.dart' as path;

import '../Interface/status_provider.dart';
import '../model/buffer_entry.dart';
import 'lock_manager.dart';
import 'backup_manager.dart';
import '../handler/common.dart';
import '../handler/logger.dart';
import '../model/business_error.dart';
import '../model/db_result.dart';
import '../model/global_config.dart';
import '../model/migration_config.dart';
import '../model/migration_task.dart';
import '../model/result_type.dart';
import '../model/unique_violation.dart';
import '../model/index_entry.dart';
import '../model/system_table.dart';
import '../model/table_schema.dart';
import 'cache_manager.dart';
import '../model/data_store_config.dart';
import 'memory_manager.dart';
import 'table_data_manager.dart';
import 'index_manager.dart';
import 'foreign_key_manager.dart';
import '../model/foreign_key_operation.dart';
import '../model/table_info.dart';
import '../query/query_condition.dart';
import '../query/query_executor.dart';
import '../query/query_optimizer.dart';
import 'migration_manager.dart';
import 'integrity_checker.dart';
import 'storage_adapter.dart';
import 'key_manager.dart';
import '../model/space_config.dart';
import 'schema_manager.dart';
import 'path_manager.dart';
import 'crontab_manager.dart';
import '../model/log_config.dart';
import '../upgrades/old_structure_migration_handler.dart';
import 'directory_manager.dart';
import '../model/table_op_meta.dart';
import '../model/id_generator.dart';
import '../model/space_info.dart';
import '../handler/parallel_processor.dart';
import '../handler/value_matcher.dart';
import 'wal_manager.dart';
import 'yield_controller.dart';
import 'workload_scheduler.dart';
import 'write_buffer_manager.dart';
import 'parallel_journal_manager.dart';
import '../model/transaction_result.dart';
import 'transaction_manager.dart';
import '../model/transaction_models.dart';
import '../model/backup_scope.dart';
import 'transaction_context.dart';
import '../model/expr.dart';
import '../handler/platform_handler.dart';
import '../model/change_event.dart';
import 'notification_manager.dart';
import '../upgrades/version_upgrade_manager.dart';
import '../model/memory_info.dart';
import '../model/config_info.dart';
import 'weight_manager.dart';
import 'read_view_manager.dart';
import 'table_tree_partition_manager.dart';
import 'index_tree_partition_manager.dart';
import 'compaction_manager.dart';
import 'overflow_manager.dart';

/// Core storage engine implementation
class DataStoreImpl {
  // Concurrency control for heavy delete operations
  static int _heavyDeleteOperationsInProgress = 0;
  static final _heavyDeleteQueue = Queue<Completer<void>>();

  // Concurrency control for heavy update operations
  static int _heavyUpdateOperationsInProgress = 0;
  static final _heavyUpdateQueue = Queue<Completer<void>>();

  static final Map<String, DataStoreImpl> _instances = {};
  Completer<void> _initCompleter = Completer<void>();
  bool _isInitialized = false;
  bool _initializing = false;
  final String _instanceKey;
  final Future<void> Function(DataStoreImpl db)? _onConfigure;
  final Future<void> Function(DataStoreImpl db)? _onCreate;
  final Future<void> Function(DataStoreImpl db)? _onOpen;
  final List<TableSchema> _userSchemas;

  bool _baseInitialized = false;
  String? _dbName;
  String? _dbPath;

  /// The final, resolved path to the database instance directory.
  String? _instancePath;

  /// The final, resolved path to the database instance directory.
  String? get instancePath => _instancePath;

  bool get isInitialized => _isInitialized;
  final bool isMigrationInstance;

  // Global prewarming state (centralized)
  bool _isGlobalPrewarming = false;
  bool get isGlobalPrewarming => _isGlobalPrewarming;

  // Global configuration cache
  static GlobalConfig? _globalConfigCache;

  String _currentSpaceName = 'default';
  DataStoreConfig? _config;

  IndexManager? _indexManager;
  QueryOptimizer? _queryOptimizer;
  QueryExecutor? _queryExecutor;
  ForeignKeyManager? _foreignKeyManager;
  late CacheManager cacheManager;
  MigrationManager? migrationManager;
  VersionUpgradeManager? versionUpgradeManager;
  IntegrityChecker? _integrityChecker;
  KeyManager? _keyManager;
  WeightManager? _weightManager;
  late StorageAdapter storage;
  SpaceConfig? _spaceConfigCache;
  SchemaManager? schemaManager;
  PathManager? _pathManager;
  DirectoryManager? directoryManager;
  LockManager? lockManager;
  TransactionManager? transactionManager;
  MemoryManager? _memoryManager;

  // Transaction zone key
  static const Symbol _txnZoneKey = #to_txn_zone;
  // Whether to rollback on DbResult error inside a transaction
  static const Symbol _txnRollbackOnErrorKey = #to_txn_rollback_on_error;

  KeyManager get keyManager {
    if (_keyManager == null) {
      throw StateError('KeyManager not initialized');
    }
    return _keyManager!;
  }

  PathManager get pathManager {
    if (_pathManager == null) {
      throw StateError('PathManager not initialized');
    }
    return _pathManager!;
  }

  int get _maxConcurrentPartitionMaintenances =>
      config.maxConcurrentPartitionMaintenances;

  /// Engine-managed directory sharding parameter (persisted in `global_config.json`).
  ///
  /// Used for deterministic sharding: `dirIndex = pIndex ~/ maxEntriesPerDir`.
  int get maxEntriesPerDir => (_globalConfigCache?.maxEntriesPerDir ??
      InternalConfig.defaultMaxEntriesPerDir);

  TableDataManager? _tableDataManager;
  TableDataManager get tableDataManager {
    if (_tableDataManager == null) {
      throw StateError('TableDataManager not initialized');
    }
    return _tableDataManager!;
  }

  // WAL/write buffering/parallel journal managers
  // Not `final` so that they can be recreated on `initialize(reinitialize: true)`.
  late WalManager walManager;
  late WriteBufferManager writeBufferManager;
  late ParallelJournalManager parallelJournalManager;
  late TableTreePartitionManager tableTreePartitionManager;
  late IndexTreePartitionManager indexTreePartitionManager;

  /// Global workload scheduler for centralized concurrency budgeting.
  late WorkloadScheduler workloadScheduler;

  late NotificationManager notificationManager;

  /// Read view manager: tracks active queries to determine buffer delay cleanup boundaries
  late ReadViewManager readViewManager;

  /// Background compaction manager (budgeted, queue-based).
  late CompactionManager compactionManager;

  /// Out-of-line large value store (TOAST-like).
  late OverflowManager overflowManager;

  /// If inside a transaction and rollbackOnError=true, throw BusinessError on non-success DbResult
  DbResult _returnOrThrowIfTxn(
      DbResult result, String operation, String tableName) {
    final String? txId = Zone.current[_txnZoneKey] as String?;
    if (txId == null) return result;
    final bool rollbackOnError =
        Zone.current[_txnRollbackOnErrorKey] as bool? ?? true;
    if (!rollbackOnError) return result;
    if (!result.isSuccess && result.type != ResultType.notFound) {
      throw BusinessError(
        'Transaction operation failed: $operation on $tableName -> ${result.message}',
        type: BusinessErrorType.transactionError,
        data: result.toJson(),
      );
    }
    return result;
  }

  /// Normalize cascade operation errors to appropriate ResultType
  ///
  /// This function maps different error types from cascade operations (update/delete)
  /// to appropriate ResultType values, providing better error classification:
  ///
  /// - BusinessError with invalidData/notFound -> foreignKeyViolation/notFound
  /// - BusinessError with dbError -> dbError
  /// - System errors -> dbError or ioError
  ///
  /// This helps users distinguish between constraint violations and system errors
  /// without being too granular.
  DbResult _normalizeCascadeError(
    dynamic error,
    String operation, // 'update', 'delete', or 'clear'
  ) {
    // Handle BusinessError
    if (error is BusinessError) {
      switch (error.type) {
        case BusinessErrorType.invalidData:
          // Foreign key constraint violation or data validation error
          // Check if it's a foreign key related error
          if (error.message.toLowerCase().contains('foreign key') ||
              error.message.toLowerCase().contains('referenced') ||
              error.message.toLowerCase().contains('cannot update') ||
              error.message.toLowerCase().contains('cannot delete') ||
              error.message.toLowerCase().contains('cannot clear')) {
            return DbResult.error(
              type: ResultType.foreignKeyViolation,
              message: error.message,
            );
          }
          // Other data validation errors
          return DbResult.error(
            type: ResultType.validationFailed,
            message: error.message,
          );

        case BusinessErrorType.notFound:
          return DbResult.error(
            type: ResultType.notFound,
            message: error.message,
          );

        case BusinessErrorType.dbError:
        case BusinessErrorType.primaryKeyError:
          return DbResult.error(
            type: ResultType.dbError,
            message: error.message,
          );

        case BusinessErrorType.transactionError:
          return DbResult.error(
            type: ResultType.dbError,
            message:
                'Transaction error during cascade $operation: ${error.message}',
          );

        default:
          // For other BusinessError types, use dbError as fallback
          return DbResult.error(
            type: ResultType.dbError,
            message: 'Cascade $operation failed: ${error.message}',
          );
      }
    }

    // Handle other exceptions (system errors, IO errors, etc.)
    final errorMessage = error.toString();

    // Check for IO-related errors
    if (errorMessage.toLowerCase().contains('io') ||
        errorMessage.toLowerCase().contains('file') ||
        errorMessage.toLowerCase().contains('permission') ||
        errorMessage.toLowerCase().contains('access')) {
      return DbResult.error(
        type: ResultType.ioError,
        message: 'IO error during cascade $operation: $errorMessage',
      );
    }

    // Default to dbError for unknown errors
    return DbResult.error(
      type: ResultType.dbError,
      message: 'Cascade $operation failed: $errorMessage',
    );
  }

  /// Whether we're inside a transaction scope and should rollback on errors
  static bool isInTransactionWithRollback() {
    final String? txId = Zone.current[_txnZoneKey] as String?;
    final bool rollbackOnError =
        Zone.current[_txnRollbackOnErrorKey] as bool? ?? true;
    return txId != null && rollbackOnError;
  }

  /// Get current space name
  String get currentSpaceName => _currentSpaceName;

  /// Get query optimizer
  QueryOptimizer? getQueryOptimizer() => _queryOptimizer;

  /// Get query executor
  QueryExecutor? getQueryExecutor() => _queryExecutor;

  /// Non-null query executor accessor (internal use).
  QueryExecutor get queryExecutor {
    final qe = _queryExecutor;
    if (qe == null) {
      throw StateError('QueryExecutor not initialized');
    }
    return qe;
  }

  IndexManager? get indexManager => _indexManager;

  /// Get memory manager
  MemoryManager? get memoryManager => _memoryManager;

  /// Get foreign key manager
  ForeignKeyManager? get foreignKeyManager => _foreignKeyManager;

  /// Get weight manager
  WeightManager? get weightManager => _weightManager;

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
    final effectiveDbPath = dbPath ?? config?.dbPath;
    final effectiveDbName = dbName ?? config?.dbName ?? 'default';
    final key = '${effectiveDbPath ?? 'default'}-$effectiveDbName';

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
      instance._startInitialize(effectiveDbPath, effectiveDbName, config);
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
      instance._startInitialize(effectiveDbPath, effectiveDbName, config);
      return instance;
    }
    return _instances[key]!;
  }

  DataStoreImpl._internal(
    this._instanceKey,
    List<TableSchema> schemas,
    this._onConfigure,
    this._onCreate,
    this._onOpen,
    this.isMigrationInstance,
  ) : _userSchemas = schemas.toList();

  /// Start initialization process
  void _startInitialize(
      String? dbPath, String? dbName, DataStoreConfig? config) {
    if (_initializing || _isInitialized) {
      return;
    }
    _dbName = dbName;
    _dbPath = dbPath;
    _config = config ?? DataStoreConfig();

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

    final spaceFilePath =
        pathManager.getSpaceConfigPath(spaceName: _currentSpaceName);

    try {
      final content = await storage.readAsString(spaceFilePath) ?? "";
      if (content.isEmpty) {
        // If SpaceConfig doesn't exist and KeyManager is available, create it
        if (_keyManager != null) {
          final spaceConfig = await _keyManager!.createKeySpaceConfig();
          await saveSpaceConfigToFile(spaceConfig);
          return spaceConfig;
        }
        return null;
      }

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
      final spaceFilePath =
          pathManager.getSpaceConfigPath(spaceName: _currentSpaceName);

      final content = jsonEncode(config.toJson());
      await storage.writeAsString(spaceFilePath, content);
      _spaceConfigCache = config;
    } catch (e) {
      Logger.error('Failed to save space config: $e', label: 'spaceConfig');
    }
  }

  /// Get database version
  Future<int> getVersion() async {
    final globalConfig = await getGlobalConfig();
    return globalConfig?.userVersion ?? 0;
  }

  /// Set database version
  Future<void> setVersion(int newVersion) async {
    final existingConfig = await getGlobalConfig() ?? GlobalConfig();
    final updatedConfig = existingConfig.setUserVersion(newVersion);
    await saveGlobalConfig(updatedConfig);
  }

  DbStatus get status => _statusProvider;

  late final DbStatus _statusProvider = _DbStatusImpl(this);

  /// Ensure initialization is complete
  ///
  /// For internal/system operations during initialization, this method allows
  /// operations to proceed if base initialization is complete and we're still initializing.
  /// External user operations must wait for full initialization to complete.
  Future<void> ensureInitialized() async {
    // Check if this is a system/internal operation (e.g., updating system tables during table creation)
    final isSystemOp = TransactionContext.isSystemOperation();

    // For system operations during initialization, allow if base initialization is complete
    // This is needed for operations like foreign key system table updates during table creation
    if (isSystemOp && _baseInitialized && _initializing) {
      return;
    }

    // For all other operations (external user operations or operations after initialization),
    // wait for full initialization to complete
    if (!_isInitialized && !_initCompleter.isCompleted) {
      await _initCompleter.future;
    }
  }

  /// Get database path
  Future<String> getDatabasePath({String? dbPath, String? dbName}) async {
    if (dbPath == null && dbName == null && instancePath != null) {
      return instancePath!;
    }
    String rootPath;
    final effectiveDbName = dbName ?? _dbName ?? 'default';
    if (dbPath != null && dbPath.isNotEmpty) {
      rootPath = dbPath;
    } else if (_dbPath != null && _dbPath!.isNotEmpty) {
      rootPath = _dbPath!;
    } else {
      // On mobile platforms, a persistent dbPath must be explicitly provided by the app.
      // This avoids silently falling back to temporary or undefined locations.
      if (PlatformHandler.isMobile) {
        throw const BusinessError(
          'On mobile platforms (Android/iOS ...), dbPath is required. Please inject a persistent app directory path via ToStore(dbPath: ...) or DataStoreConfig(dbPath: ...). See example/mobile_quickstart.dart',
          type: BusinessErrorType.invalidData,
        );
      }
      rootPath = await getPathApp();
    }

    // Normalize path separators for cross-platform consistency.
    rootPath = rootPath.replaceAll(r'\', '/');
    // Remove any trailing slashes to prevent duplication.
    while (rootPath.endsWith('/')) {
      rootPath = rootPath.substring(0, rootPath.length - 1);
    }

    return pathJoin(rootPath, 'db', effectiveDbName);
  }

  /// Initialize storage engine
  /// [reinitialize]: when true, always close current instance
  Future<bool> initialize(
      {String? dbPath,
      String? dbName,
      DataStoreConfig? config,
      bool reinitialize = false,
      bool noPersistOnClose = false}) async {
    if (_initializing && !_initCompleter.isCompleted) {
      await _initCompleter.future;
      return true;
    }

    if (_isInitialized &&
        dbPath == _dbPath &&
        dbName == _dbName &&
        config == _config) {
      return true;
    }

    _initializing = true;
    try {
      if (_config != null && (reinitialize || _isInitialized)) {
        await close(persistChanges: !noPersistOnClose);
      }
      // Ensure this instance is re-registered after successful initialization
      // especially when initialize(reinitialize: true) called after close() removed it.
      if (!isMigrationInstance) {
        if (_instances[_instanceKey] == null) {
          _instances[_instanceKey] = this;
        }
      }

      if (config != null) {
        _config = config;
        if (_config?.dbPath != null) {
          _dbPath = _config?.dbPath;
        }
        if (_config?.dbName != 'default') {
          _dbName = _config?.dbName;
        }
      }

      if (dbPath != null) {
        _dbPath = dbPath;
      }
      if (dbName != null) {
        _dbName = dbName;
      }

      _config ??= DataStoreConfig();
      _dbName ??= _config?.dbName;

      // Apply log configuration as early as possible.
      LogConfig.setConfig(
        enableLog: _config!.enableLog,
        logLevel: _config!.logLevel,
      );

      // Initialize YieldController global limit
      YieldController.globalSettings.targetBudgetMs = _config!.yieldDurationMs;

      // Resolve the final database path
      _instancePath = await getDatabasePath(dbPath: _dbPath, dbName: _dbName);

      _config =
          _config!.copyWith(dbPath: _dbPath, dbName: _dbName ?? config?.dbName);

      // Initialize global workload scheduler using maxIoConcurrency as total token capacity.
      // This allows higher I/O parallelism while CPU tasks are naturally limited by isolate count.
      workloadScheduler =
          WorkloadScheduler(globalMax: _config!.maxIoConcurrency);

      // Configure the global parallel processor with sensible defaults
      ParallelProcessor.setConfig(
        concurrency: _config!.maxIoConcurrency,
        // Calculate a dynamic timeout based on max partition size.
        // Formula: 60 seconds base + 1 second per 200KB.
        timeout: Duration(
            seconds:
                60 + (_config!.maxPartitionFileSize / (200 * 1024)).ceil()),
      );

      // Ensure _currentSpaceName is synchronized with config.spaceName
      _currentSpaceName = _config!.spaceName;

      storage = StorageAdapter();
      lockManager = LockManager();

      // Configure storage runtime and flush policy based on DataStoreConfig
      await storage.configure(
        maxOpenHandles: _config!.maxOpenFiles,
        flushPolicy: _config!.recoveryFlushPolicy,
      );

      schemaManager = SchemaManager(this);
      _pathManager = PathManager(this);

      // Initialize memory manager
      _memoryManager = MemoryManager();

      // Create key manager instance but don't initialize yet
      _keyManager = KeyManager(this);

      transactionManager = TransactionManager(this);

      await Future.wait([
        getGlobalConfig(),
        getSpaceConfig(),
        _memoryManager!.initialize(_config!, this),
        Future(() async => await transactionManager!.initialize()),
      ]);

      directoryManager = DirectoryManager(this);
      _indexManager = IndexManager(this);
      indexTreePartitionManager = IndexTreePartitionManager(this);
      tableTreePartitionManager = TableTreePartitionManager(this);
      _tableDataManager = TableDataManager(this);
      // Initialize WAL and parallel journal pipeline
      walManager = WalManager(this);
      writeBufferManager = WriteBufferManager(this);
      parallelJournalManager =
          ParallelJournalManager(this, walManager, writeBufferManager);
      migrationManager = MigrationManager(this);
      versionUpgradeManager = VersionUpgradeManager(this);
      _integrityChecker = IntegrityChecker(this);
      _queryOptimizer = QueryOptimizer(this);
      _queryExecutor = QueryExecutor(this, _indexManager!);
      _foreignKeyManager = ForeignKeyManager(this);
      _weightManager = WeightManager(this);
      readViewManager = ReadViewManager(this);
      compactionManager = CompactionManager(this);
      overflowManager = OverflowManager(this);

      cacheManager = CacheManager(this);
      notificationManager = NotificationManager([
        ...SystemTable.gettableSchemas,
        ..._userSchemas,
      ]);

      // Mark all operations from this point as system operations during initialization
      // This allows internal operations (like updating system tables, resuming pending ops)
      // to proceed even if _isInitialized is false, while external user operations must wait
      await TransactionContext.runAsSystemOperation(() async {
        if (!isMigrationInstance) {
          // Run database version upgrades
          await versionUpgradeManager?.runDatabaseUpgradesIfNeeded();
        }

        // NOW initialize KeyManager for ALL instances (including migration instances)
        await _keyManager!.initialize();

        // Initialize WeightManager
        if (_weightManager != null) {
          await _weightManager!.initialize();
        }

        // Mark base initialization complete AFTER KeyManager is initialized
        _baseInitialized = true;

        // Prepare temp directory for crash-safe writes (native only)
        await _resetTempDir();

        if (!isMigrationInstance) {
          await walManager.initializeAndRecover();
          await parallelJournalManager.start();

          await _resumePendingLargeDeletes();
          await _resumePendingLargeUpdates();

          // Recover unfinished transactions (commit plans or rollbacks)
          await transactionManager!.recoverUnfinishedTransactionsOnStartup();

          // Resume pending table-level clear/drop operations before WAL replay.
          await _resumePendingTableOps();
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
          // await loadDataToCache();
          CrontabManager.start();

          // Database open callback
          await _onOpen?.call(this);
        }
      });

      return true;
    } catch (e, stack) {
      _isInitialized = false;
      if (!_initCompleter.isCompleted) {
        _initCompleter.completeError(e);
      }
      Logger.error('Database initialization failed: $e\n$stack',
          label: 'DataStore.initialize');
      try {
        // Prevent ReadViewManager callback leak if initialization failed after its creation
        readViewManager.dispose();
      } catch (_) {}
      rethrow;
    } finally {
      _initializing = false;
    }
  }

  /// Delete and recreate temp directory quickly (preferred for large deployments).
  Future<void> _resetTempDir() async {
    try {
      if (PlatformHandler.isWeb) return;
      final tempDir = pathManager.getTempDirPath();
      // Best-effort delete; then recreate
      await storage.deleteDirectory(tempDir);
      await storage.ensureDirectoryExists(tempDir);
    } catch (e) {
      Logger.warn('Reset temp directory failed: $e',
          label: 'DataStore.initialize');
    }
  }

  /// Get user-defined business tables (excluding system tables)
  List<TableSchema> _getUserDefinedSchemas() {
    if (_userSchemas.isEmpty) return const [];
    return _userSchemas
        .where((schema) => !SystemTable.isSystemTable(schema.name))
        .toList(growable: false);
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

      final systemSchemas = SystemTable.gettableSchemas;
      final userSchemas = _getUserDefinedSchemas();

      // Check if initialization or upgrade is needed
      bool needInitialize = false;
      bool systemSchemaChanged = false;
      bool userSchemaChanged = false;

      // Check if there are existing table structures
      final schemaMeta = await schemaManager!.getSchemaMeta();
      if (schemaMeta.tablePartitionMap.isEmpty) {
        // First run, need to initialize
        needInitialize = true;
      } else {
        // Compare hash values to check if upgrade is needed
        systemSchemaChanged =
            await schemaManager!.isSystemSchemaChanged(systemSchemas);
        if (userSchemas.isNotEmpty) {
          userSchemaChanged = await schemaManager!.isSchemaChanged(userSchemas);
        }
      }

      // First run - create system tables and user tables
      if (needInitialize) {
        // Create system tables first (they have no foreign key dependencies)
        final systemTablesResult = await createTables(systemSchemas);
        if (!systemTablesResult.isSuccess) {
          Logger.warn(
            'Failed to create system tables: ${systemTablesResult.message}',
            label: 'DataStoreImpl._startSetupAndUpgrade',
          );
        }

        await schemaManager?.updateSystemSchemaHash(systemSchemas);

        // Create user tables
        // Use createTables instead of loop to automatically sort by foreign key dependencies
        // This ensures parent tables are created before child tables, regardless of definition order
        if (userSchemas.isNotEmpty) {
          final userTablesResult = await createTables(userSchemas);
          if (!userTablesResult.isSuccess &&
              userTablesResult.failedKeys.isNotEmpty) {
            // If all tables failed, throw error; if partial success, log warning but continue
            if (userTablesResult.successKeys.isEmpty) {
              Logger.error(
                'Failed to create user tables: ${userTablesResult.message}',
                label: 'DataStoreImpl._startSetupAndUpgrade',
              );
            } else {
              Logger.warn(
                'Some user tables failed to create: ${userTablesResult.failedKeys.join(", ")}',
                label: 'DataStoreImpl._startSetupAndUpgrade',
              );
            }
          }
          await schemaManager?.updateUserSchemaHash(userSchemas);
        }

        // Call creation callback
        await _onCreate?.call(this);
      }
      // Need upgrade - perform table structure migration
      else if (systemSchemaChanged || userSchemaChanged) {
        // Perform automatic table structure migration
        final migrationSchemas = getInitialSchemas();
        await autoSchemaMigrate(migrationSchemas);

        if (systemSchemaChanged) {
          await schemaManager?.updateSystemSchemaHash(systemSchemas);
        }

        if (userSchemaChanged && userSchemas.isNotEmpty) {
          await schemaManager?.updateUserSchemaHash(userSchemas);
        }
      }
    } catch (e, stack) {
      Logger.error(
        'Setup and upgrade failed: $e\n$stack',
        label: 'DataStoreImpl._startSetupAndUpgrade',
      );
      rethrow;
    }
  }

  /// Automatic table structure migration - based on table structure hash comparison.
  /// Uses maintenance mode: user operations are suspended until migration completes
  /// to avoid conflicts with schema/data changes.
  Future<void> autoSchemaMigrate(List<TableSchema> schemas) async {
    String backupPath = '';
    final migrationConfig = config.migrationConfig ?? const MigrationConfig();

    for (var schema in schemas) {
      if (!schema.validateTableSchema()) {
        throw const BusinessError(
          'Invalid table structure',
          type: BusinessErrorType.schemaError,
        );
      }
    }

    // Backup before entering maintenance so restore is available on failure
    if (migrationConfig.backupBeforeMigrate) {
      backupPath = await backup();
    }

    // Enter maintenance: block new user lock acquisitions and wait for quiescent state.
    // Migration runs as system operation so it can acquire locks; user ops wait until exitMaintenance.
    try {
      Logger.info(
        'Entering maintenance for table structure migration (user ops will wait)',
        label: 'DataStoreImpl.autoSchemaMigrate',
      );
      final entered = await lockManager?.enterMaintenance(
              timeout: config.transactionTimeout) ??
          true;
      if (!entered) {
        Logger.warn(
          'Maintenance enter timeout (quiescent not reached), proceeding with migration',
          label: 'DataStoreImpl.autoSchemaMigrate',
        );
      }
    } catch (e) {
      Logger.error(
        'Failed to enter maintenance for migration: $e',
        label: 'DataStoreImpl.autoSchemaMigrate',
      );
      rethrow;
    }

    try {
      await TransactionContext.runAsSystemOperation(() async {
        await migrationManager?.migrate(
          schemas,
          batchSize: migrationConfig.batchSize,
        );

        if (migrationConfig.validateAfterMigrate) {
          final isValid = await _validateMigration(schemas);
          if (!isValid && migrationConfig.strictMode) {
            throw const BusinessError(
              'Migration validation failed',
              type: BusinessErrorType.migrationError,
            );
          }
        }
      });

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
      if (backupPath.isNotEmpty) {
        await restore(backupPath, deleteAfterRestore: true);
      }
      rethrow;
    } finally {
      lockManager?.exitMaintenance();
      Logger.info(
        'Exited maintenance after table structure migration',
        label: 'DataStoreImpl.autoSchemaMigrate',
      );
    }
  }

  /// Close database
  /// Close database
  /// [persistChanges]: when true, save buffers/caches to disk (default behavior).
  /// When false, DO NOT persist pending data; only flush OS handles and clear memory to avoid overwriting restore data.
  /// [closeStorage]: whether to close the underlying storage (IndexedDB etc.).
  /// Set [closeStorage] to false when performing operations like Restore that need
  /// to re-initialize the DataStore but keep the connection logic alive.
  Future<void> close(
      {bool persistChanges = true, bool closeStorage = true}) async {
    if (!_isInitialized) return;

    try {
      // Run save/close sequence as system operation so storage locks can be acquired
      await TransactionContext.runAsSystemOperation(() async {
        if (persistChanges) {
          // Enter maintenance before saving: block new external locks and wait for quiescent
          try {
            await lockManager?.enterMaintenance(
                timeout: config.transactionTimeout);
          } catch (_) {}

          // Force flush and stop the write queue and index update pipeline.
          try {
            await parallelJournalManager.drainAndStop();
          } catch (e) {
            Logger.error('Failed to save cache when closing: $e',
                label: 'DataStoreImpl.close');
          }
          // Ensure runtime metadata is also persisted once all data is durable.
          try {
            await tableDataManager.persistRuntimeMetaIfNeeded(force: true);
          } catch (e) {
            Logger.error('Persist runtime metadata on close failed: $e',
                label: 'DataStoreImpl.close');
          }
        } else {
          // For close without persistChanges (e.g. restore), do not enter maintenance to avoid
          // blocking internal flush tasks; just stop pipeline and flush handles best-effort.
          try {
            await parallelJournalManager.stopWithoutFlush();
          } catch (e) {
            Logger.error('Stop journal manager without flush failed: $e',
                label: 'DataStoreImpl.close');
          }
          // Minimize IO: only ensure buffers of open handles are flushed to avoid handle
          // competition with subsequent directory deletion/replacement.
          try {
            await storage.flushAll(closeHandles: true);
          } catch (_) {}
        }

        // Regardless of persistChanges, ensure WAL append queue is quiescent before closing storage,
        // to avoid WAL flush task writing to storage after close causing File closed exception.
        try {
          await walManager.flushQueueCompletely();
        } catch (e) {
          Logger.error('Flush WAL queue on close failed: $e',
              label: 'DataStoreImpl.close');
        }

        // Flush weight data
        if (_weightManager != null) {
          await _weightManager!.saveWeights(force: true);
          _weightManager!.dispose();
        }

        await _tableDataManager?.dispose(persistChanges: persistChanges);
        if (closeStorage) {
          await storage.close(isMigrationInstance: isMigrationInstance);
        }
        CrontabManager.dispose();
      });

      // After storage closed, old lockManager no longer used; new instance will create a fresh lock manager
      lockManager = null;

      // Release all managers
      readViewManager.dispose();
      compactionManager.dispose();
      cacheManager.clear();

      // Clean up memory manager resources
      _memoryManager?.dispose();

      // Clear instance variables
      _queryOptimizer = null;
      _indexManager = null;
      _queryExecutor = null;
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

      // Only remove if the registry still points to this instance
      if (_instances[_instanceKey] == this) {
        _instances.remove(_instanceKey);
      }

      Logger.info('The database instance has been closed: $_instanceKey',
          label: 'DataStoreImpl.close');
    } catch (e) {
      Logger.error('Database shutdown failed: $e', label: 'DataStore.close');
      rethrow;
    }
  }

  /// Create a single table
  /// Returns [DbResult] to allow graceful error handling for business logic errors
  Future<DbResult> createTable(TableSchema schema) async {
    DbResult finish(DbResult r) =>
        _returnOrThrowIfTxn(r, 'createTable', schema.name);

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
        return finish(DbResult.error(
          type: ResultType.tableExists,
          message: 'Table ${schema.name} already exists',
        ));
      }

      try {
        // Validate primary key configuration and field types
        if (!schemaValid.validateTableSchema()) {
          throw BusinessError(
            'The structure of table ${schema.name} is invalid, please check primary key configuration and index fields',
            type: BusinessErrorType.schemaError,
          );
        }

        // Validate foreign key constraints with referenced tables
        // This ensures field type compatibility and referenced table existence
        for (final fk in schemaValid.foreignKeys) {
          if (!fk.enabled) continue;

          final referencedSchema =
              await schemaManager?.getTableSchema(fk.referencedTable);
          if (referencedSchema == null) {
            throw BusinessError(
              'Cannot create table ${schema.name}: Referenced table ${fk.referencedTable} does not exist for foreign key ${fk.actualName}',
              type: BusinessErrorType.schemaError,
            );
          }

          if (!schemaValid.validateForeignKeyWithReferencedTable(
              fk, referencedSchema)) {
            throw BusinessError(
              'Invalid foreign key ${fk.actualName} in table ${schema.name}: Field type mismatch or invalid configuration',
              type: BusinessErrorType.schemaError,
            );
          }
        }

        // Create table path
        await _pathManager!.createTablePath(schema.name, schema.isGlobal);

        // Write schema file
        await schemaManager?.saveTableSchema(schema.name, schemaValid);

        // Create all indexes (explicit, unique, and foreign key)
        for (var index in schema.getAllIndexes()) {
          await _indexManager?.createIndex(schema.name, index);
        }

        // Auto-create indexes for foreign keys
        // Skip for system tables - they don't have foreign keys and system_fk_references
        // may not be fully initialized yet during system table creation
        if (_foreignKeyManager != null &&
            !SystemTable.isSystemTable(schema.name)) {
          //Update system table with foreign key relationships (for fast startup loading)
          await _foreignKeyManager!
              .updateSystemTableForTable(schema.name, schemaValid);
        }

        // New table created successfully, call table creation statistics method
        tableDataManager.tableCreated(schema.name);

        if (!SystemTable.isSystemTable(schema.name)) {
          Logger.info(
            'Table ${schema.name} created successfully${schema.isGlobal ? ' (global)' : ' (space)'}',
            label: 'DataStore.createTable',
          );
        }

        return finish(DbResult.success(
          message: 'Table ${schema.name} created successfully',
        ));
      } catch (e) {
        // Cleanup schema
        if (schemaManager != null) {
          await schemaManager!.deleteTableSchema(schema.name);
          // Release directory
          await directoryManager!.releaseTableDirectory(schema.name);
        }

        Logger.error('Create table failed: $e', label: 'DataStore.createTable');
        // Convert exception to DbResult for graceful error handling
        if (e is BusinessError) {
          if (e.type == BusinessErrorType.schemaError) {
            return finish(DbResult.error(
              type: ResultType.validationFailed,
              message: e.message,
            ));
          }
          return finish(DbResult.error(
            type: ResultType.dbError,
            message: e.message,
          ));
        }
        return finish(DbResult.error(
          type: ResultType.dbError,
          message: 'Failed to create table ${schema.name}: $e',
        ));
      }
    } catch (e) {
      Logger.error('Create table failed: $e', label: 'DataStore.createTable');
      // Convert any unexpected exceptions to DbResult
      return finish(DbResult.error(
        type: ResultType.dbError,
        message: 'Failed to create table ${schema.name}: $e',
      ));
    }
  }

  /// Sort tables by foreign key dependencies using topological sort
  /// This ensures parent tables (referenced tables) are created before child tables
  /// Returns sorted list and list of tables with circular dependencies (if any)
  List<TableSchema> _sortTablesByDependencies(List<TableSchema> schemas) {
    // Build dependency graph: table -> set of tables it depends on (referenced tables)
    final dependencies = <String, Set<String>>{};
    final tableMap = <String, TableSchema>{};

    // Initialize maps
    for (final schema in schemas) {
      tableMap[schema.name] = schema;
      dependencies[schema.name] = <String>{};
    }

    // Build dependency graph from foreign keys
    for (final schema in schemas) {
      for (final fk in schema.foreignKeys) {
        if (!fk.enabled) continue;

        // Only add dependency if referenced table is in the same schema list
        if (tableMap.containsKey(fk.referencedTable)) {
          dependencies[schema.name]!.add(fk.referencedTable);
        }
      }
    }

    // Topological sort using Kahn's algorithm
    final sorted = <TableSchema>[];
    final inDegree = <String, int>{};
    final queue = <String>[];

    // Calculate in-degree for each table
    // In-degree = number of tables this table depends on (referenced tables)
    for (final tableName in tableMap.keys) {
      inDegree[tableName] = dependencies[tableName]!.length;
    }

    // Find all tables with no dependencies (in-degree = 0)
    for (final entry in inDegree.entries) {
      if (entry.value == 0) {
        queue.add(entry.key);
      }
    }

    // Process queue
    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      sorted.add(tableMap[current]!);

      // Reduce in-degree for tables that depend on current table
      for (final entry in dependencies.entries) {
        if (entry.value.contains(current)) {
          inDegree[entry.key] = (inDegree[entry.key] ?? 0) - 1;
          if (inDegree[entry.key] == 0) {
            queue.add(entry.key);
          }
        }
      }
    }

    // Check for circular dependencies
    if (sorted.length < schemas.length) {
      final unsorted = schemas
          .where((s) => !sorted.any((sortedS) => sortedS.name == s.name))
          .toList();
      Logger.warn(
        'Circular foreign key dependencies detected. Tables with circular dependencies: ${unsorted.map((s) => s.name).join(', ')}. '
        'These tables will be created in their original order, which may cause foreign key validation to fail. '
        'Please review your foreign key definitions.',
        label: 'DataStoreImpl._sortTablesByDependencies',
      );
      // Add unsorted tables at the end (they may have circular dependencies)
      sorted.addAll(unsorted);
    }

    return sorted;
  }

  /// Create multiple tables
  /// Automatically sorts tables by foreign key dependencies to ensure correct creation order
  /// Returns [DbResult] to allow graceful error handling for business logic errors
  Future<DbResult> createTables(List<TableSchema> schemas) async {
    if (schemas.isEmpty) {
      return DbResult.success(message: 'No tables to create');
    }

    // Sort tables by foreign key dependencies
    // This ensures parent tables (referenced tables) are created before child tables
    final sortedSchemas = _sortTablesByDependencies(schemas);

    // Create tables in sorted order
    final List<String> successKeys = [];
    final List<String> failedKeys = [];

    for (var schema in sortedSchemas) {
      final result = await createTable(schema);
      if (result.isSuccess) {
        successKeys.add(schema.name);
      } else {
        failedKeys.add(schema.name);
        // Continue creating other tables even if one fails
      }
    }

    if (failedKeys.isEmpty) {
      return DbResult.success(
        message: 'All ${successKeys.length} tables created successfully',
        successKeys: successKeys,
      );
    } else if (successKeys.isEmpty) {
      return DbResult.error(
        type: ResultType.dbError,
        message: 'Failed to create all tables',
        failedKeys: failedKeys,
      );
    } else {
      return DbResult.batch(
        message:
            'Partially successful: ${successKeys.length} tables created, ${failedKeys.length} failed',
        successKeys: successKeys,
        failedKeys: failedKeys,
      );
    }
  }

  /// Insert data complete process
  ///
  /// [retryOnPkConflict] is an internal flag to avoid infinite recursion when
  /// automatically retrying once after fixing a sequential primary key conflict.
  Future<DbResult> insert(String tableName, Map<String, dynamic> data,
      {bool retryOnPkConflict = false}) async {
    DbResult finish(DbResult r) => _returnOrThrowIfTxn(r, 'insert', tableName);
    // Need to be fully initialized
    if (!_isInitialized) {
      await ensureInitialized();
    }

    // Capture transaction id once for performance and consistent visibility rules
    final String? txId = Zone.current[_txnZoneKey] as String?;

    Map<String, dynamic>? validData;

    try {
      // 1. Data validation
      final schema = await schemaManager?.getTableSchema(tableName);
      if (schema == null) {
        Logger.error('Table $tableName does not exist',
            label: 'DataStore.insert');
        return finish(DbResult.error(
          type: ResultType.notFound,
          message: 'Table $tableName does not exist',
        ));
      }

      validData = await _validateAndProcessData(schema, data, tableName);
      if (validData == null) {
        return finish(DbResult.error(
          type: ResultType.validationFailed,
          message: 'Data validation failed',
        ));
      }

      // 2. Validate foreign key constraints
      if (_foreignKeyManager != null) {
        try {
          await _foreignKeyManager!.validateForeignKeyConstraints(
            tableName: tableName,
            data: validData,
            operation: ForeignKeyOperation.insert,
          );
        } catch (e) {
          Logger.error('Foreign key constraint validation failed: $e',
              label: 'DataStore.insert');
          return finish(DbResult.error(
            type: ResultType.foreignKeyViolation,
            message: e.toString(),
          ));
        }
      }

      // 3. Plan unique locks + refs once; acquire locks then reuse refs for buffer
      final planIns = planUniqueForInsert(tableName, schema, validData);

      // Reservation based: try reserve unique keys first
      final recordId = validData[schema.primaryKey].toString();
      try {
        writeBufferManager.tryReserveUniqueKeys(
          tableName: tableName,
          recordId: recordId,
          uniqueKeys: planIns.refs,
          transactionId: txId,
        );
      } catch (e) {
        if (e is UniqueViolation) {
          return finish(DbResult.error(
            type: ResultType.uniqueViolation,
            message: e.message,
            failedKeys: [e.value?.toString() ?? ''],
          ));
        }
        rethrow;
      }

      // 3. Unique check (disk/cache only)
      final uniqueViolation = await _indexManager?.checkUniqueConstraints(
          tableName, validData,
          txId: txId, schemaOverride: schema);

      if (uniqueViolation != null) {
        // Release reservation
        writeBufferManager.releaseReservedUniqueKeys(
            tableName: tableName, recordId: recordId, transactionId: txId);

        final primaryKey = schema.primaryKey;
        final providedId = validData[primaryKey];

        final bool isSequentialPk =
            schema.primaryKeyConfig.type == PrimaryKeyType.sequential;

        if (isSequentialPk && providedId != null) {
          // Notify TableDataManager to handle primary key conflict
          await tableDataManager.handlePrimaryKeyConflict(
              tableName, providedId);
        }

        final bool userProvidedPk =
            data.containsKey(primaryKey) && data[primaryKey] != null;
        if (isSequentialPk && providedId != null && !retryOnPkConflict) {
          // Automatic correction and retry: if conflict occurs on sequential PK, we fix the sequence
          // and then retry insertion. If user provided the PK, we clear it to let the system generate a new one.
          final Map<String, dynamic> retryData =
              userProvidedPk ? (Map.from(data)..remove(primaryKey)) : data;
          return await insert(tableName, retryData, retryOnPkConflict: true);
        }

        return finish(DbResult.error(
          type: ResultType.uniqueViolation,
          message: uniqueViolation.message,
          failedKeys: providedId != null ? [providedId.toString()] : [],
        ));
      }

      // 4. Rebuild record strictly following schema order (primary key first)
      final orderedValidData = <String, dynamic>{
        schema.primaryKey: validData[schema.primaryKey],
      };
      for (final field in schema.fields) {
        if (field.name == schema.primaryKey) {
          continue;
        }
        orderedValidData[field.name] = validData[field.name];
      }

      // 5. Add to write queue (insert operation) using planned refs (no extra parsing)
      final uniqueRefs = planIns.refs;
      await tableDataManager.addToBuffer(
        tableName,
        orderedValidData,
        BufferOperationType.insert,
        uniqueKeyRefs: uniqueRefs,
        transactionId: txId,
      );

      notificationManager.notify(ChangeEvent(
        type: ChangeType.insert,
        tableName: tableName,
        record: orderedValidData,
      ));

      // Return string type primary key value
      final primaryKeyValue = validData[schema.primaryKey];
      return finish(DbResult.success(
        successKey: primaryKeyValue?.toString(),
        message: 'Insert successful',
      ));
    } catch (e) {
      Logger.error('Insert failed: $e', label: 'DataStore.insert');

      try {
        // Clear cache
        final schema = await schemaManager?.getTableSchema(tableName);
        final primaryKeyValue = validData != null && schema != null
            ? validData[schema.primaryKey]
            : null;
        if (primaryKeyValue != null) {
          await tableDataManager.removeTableRecords(tableName, [
            primaryKeyValue.toString(),
          ]);
        }

        // clear write queue
        if (schema != null) {
          final primaryKey = schema.primaryKey;
          final recordId = data[primaryKey]?.toString();
          if (recordId != null) {
            tableDataManager.removeRecordFromBuffer(tableName, recordId);
          }
        }
      } catch (rollbackError) {
        Logger.error('Rollback failed: $rollbackError',
            label: 'DataStore.insert');
      }

      // Identify the failed record's key
      List<String> failedKeys = [];
      try {
        final schema = await schemaManager?.getTableSchema(tableName);
        if (schema != null && data.containsKey(schema.primaryKey)) {
          final keyValue = data[schema.primaryKey]?.toString();
          if (keyValue != null && keyValue.isNotEmpty) {
            failedKeys = [keyValue];
          }
        }
      } catch (_) {
        // Ignore errors during error handling
      }

      if (isInTransactionWithRollback()) {
        rethrow;
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
      TableSchema schema, Map<String, dynamic> data, String tableName,
      {bool skipPrimaryKeyOrderCheck = false,
      bool skipPrimaryKeyFormatCheck = false}) async {
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
          if (!skipPrimaryKeyFormatCheck &&
              !schema.validatePrimaryKeyFormat(providedId)) {
            throw BusinessError(
              'The provided primary key value $providedId does not meet the format requirements for type ${schema.primaryKeyConfig.type}',
              type: BusinessErrorType.invalidData,
            );
          }

          // Ordering validation
          if (!skipPrimaryKeyOrderCheck &&
              !await _validatePrimaryKeyOrder(
                  tableName, providedId, schema.primaryKeyConfig.type)) {
            throw BusinessError(
              'The provided primary key value $providedId violates the key ordering of table $tableName, data insertion rejected',
              type: BusinessErrorType.invalidData,
            );
          }
        }

        result[primaryKey] =
            schema.primaryKeyConfig.convertPrimaryKey(providedId);
      }

      // 2. fill default value and null value (support FieldValue for insert)
      for (var field in schema.fields) {
        if (field.name == primaryKey) {
          continue;
        }
        final raw = data[field.name];
        dynamic value = raw;
        if (raw is ExprNode) {
          // For insert operations, evaluate expressions with null/0 as initial values
          // This provides sensible defaults for insert scenarios
          if (raw is TimestampExpr) {
            value = DateTime.now().toIso8601String();
          } else if (raw is Constant) {
            value = raw.value;
          } else if (raw is FieldRef) {
            // For insert, field reference defaults to 0 (will be evaluated as 0 in expression)
            value = 0;
          } else {
            // For complex expressions in insert, evaluate with empty record (all fields = 0/null)
            // This provides reasonable defaults
            final emptyRecord = <String, dynamic>{};
            try {
              value = _evaluateExpression(raw, emptyRecord, schema);
            } catch (e) {
              Logger.warn(
                'Failed to evaluate expression for insert on field ${field.name}: $e. Using 0 as default.',
                label: 'DataStore._validateAndProcessData',
              );
              value = 0;
            }
          }
        }
        result[field.name] = field.convertValue(value);
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

      return validatedResult;
    } catch (e) {
      Logger.error('Data validation failed: $e',
          label: 'DataStore._validateAndProcessData');
      return null;
    }
  }

  /// Execute query
  Future<List<Map<String, dynamic>>> executeQuery(
    String tableName,
    QueryCondition condition, {
    List<String>? orderBy,
    int? limit,
    int? offset,
  }) async {
    // Execute query using QueryExecutor (optimizer runs inside executor).
    final result = await _queryExecutor?.execute(
          tableName,
          condition: condition,
          orderBy: orderBy,
          limit: limit,
          offset: offset,
        ) ??
        const ExecuteResult.empty();
    return result.records;
  }

  UniquePlan planUniqueForInsert(
      String tableName, TableSchema schema, Map<String, dynamic> data) {
    final refs = <UniqueKeyRef>[];
    final pk = schema.primaryKey;
    final pkVal = data[pk];
    if (pkVal != null) {
      // Primary key uniqueness is enforced via table range partitions (no pk index).
      refs.add(UniqueKeyRef('pk', pkVal.toString()));
    }

    for (final idx in schema.getAllIndexes()) {
      if (!idx.unique) continue;
      // use actualIndexName which handles both explicit and implicit names
      final canKey = schema.createCanonicalIndexKey(idx.fields, data);
      if (canKey != null) {
        refs.add(UniqueKeyRef(idx.actualIndexName, canKey));
      }
    }
    return UniquePlan(refs);
  }

  UniquePlan planUniqueForUpdate(String tableName, TableSchema schema,
      Map<String, dynamic> updatedRecord, Set<String> changedFields) {
    final refs = <UniqueKeyRef>[];
    for (final idx in schema.getAllIndexes()) {
      if (!idx.unique) continue;
      // Check if any field in the unique index is changed
      if (idx.fields.any((f) => changedFields.contains(f))) {
        final canKey =
            schema.createCanonicalIndexKey(idx.fields, updatedRecord);
        if (canKey != null) {
          refs.add(UniqueKeyRef(idx.actualIndexName, canKey));
        }
      }
    }
    return UniquePlan(refs);
  }

  /// backup data and return backup path
  Future<String> backup(
      {bool compress = true,
      BackupScope scope = BackupScope.currentSpaceWithGlobal}) async {
    try {
      // 1. Save all pending data and runtime metadata to ensure a consistent backup point.
      await saveAllCacheBeforeExit();

      // 2. create backup manager
      final backupManager = BackupManager(this);

      // 3. create backup
      final backupPath = await backupManager.createBackup(
        compress: compress,
        scope: scope,
      );
      return backupPath;
    } catch (e) {
      Logger.error('Create backup failed: $e', label: 'DataStore-backup');
      rethrow;
    }
  }

  /// Restore database from backup
  Future<bool> restore(String backupPath,
      {bool deleteAfterRestore = false,
      bool cleanupBeforeRestore = true}) async {
    if (!_baseInitialized) {
      await ensureInitialized();
    }

    try {
      final backupManager = BackupManager(this);
      await backupManager.restore(backupPath,
          deleteAfterRestore: deleteAfterRestore,
          cleanupBeforeRestore: cleanupBeforeRestore);
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
        // If it's an expression (atomic operation), skip validation here. It will be handled later.
        if (value is ExprNode) {
          result[field.name] = value;
          continue;
        }

        // Validate value using update-specific method
        if (!field.validateUpdateValue(value)) {
          Logger.warn(
            'Field ${field.name} value does not meet constraints: $value',
            label: 'DataStore._validateAndProcessUpdateData',
          );
          return null;
        }

        result[field.name] = field.convertValue(value);

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

      return result;
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
    // Optional checkpoint to resume heavy update from a specific partition and updated count
    int? checkpointStartPartitionNo,
    int? checkpointUpdatedSoFar,
    String? checkpointOpId,
  }) async {
    DbResult finish(DbResult r) => _returnOrThrowIfTxn(r, 'update', tableName);
    await ensureInitialized();

    // Capture transaction id once
    final String? txId = Zone.current[_txnZoneKey] as String?;

    // check if condition is empty, avoid accidental update of all records
    if (condition.isEmpty && !allowAll) {
      Logger.warn(
          'Update operation without condition, this may cause accidental update of all records, please use allowUpdateAll() method to explicitly confirm.',
          label: 'DataStore.updateInternal');
      return finish(DbResult.error(
        type: ResultType.validationFailed,
        message:
            'Update operation must specify a filter condition. If you really need to update all records, please use allowUpdateAll() method to explicitly confirm.',
      ));
    }

    try {
      // validate data
      final schema = await schemaManager?.getTableSchema(tableName);
      if (schema == null) {
        Logger.error('Table $tableName does not exist',
            label: 'DataStore.updateInternal');
        return finish(DbResult.error(
          type: ResultType.notFound,
          message: 'Table $tableName does not exist',
        ));
      }
      final validData =
          await _validateAndProcessUpdateData(schema, data, tableName);
      if (validData == null || validData.isEmpty) {
        return finish(DbResult.error(
          type: ResultType.validationFailed,
          message: 'Data validation failed',
        ));
      }

      // Get table file metadata to make an informed decision on the update strategy
      final tableMeta = await tableDataManager.getTableMeta(tableName);

      // Get memory manager to access cache size limits
      final recordCacheSize =
          memoryManager?.getRecordCacheSize() ?? 200 * 1024 * 1024;

      final schemas = {tableName: schema};
      final matcher =
          ConditionRecordMatcher.prepare(condition, schemas, tableName);

      final primaryKey = schema.primaryKey;

      // Check if condition is an equality on primary key or unique field - this can be optimized
      bool isOptimizableQuery = false;
      // If resuming a large update from checkpoint, force heavy path (disable optimizable branch)
      if (checkpointOpId == null) {
        // Small table heuristics: always optimize when
        // - table meta is unknown or size invalid
        // - size < 5MB (unconditional minimum threshold)
        // - size < 30% of record cache size
        const int minSmallTableBytes = 5 * 1024 * 1024; // 5MB
        if (tableMeta == null ||
            tableMeta.totalSizeInBytes < minSmallTableBytes ||
            tableMeta.totalSizeInBytes < recordCacheSize * 0.3) {
          isOptimizableQuery = true;
        }

        if (!isOptimizableQuery) {
          // Analyze condition to check if it's a primary key/unique/index-driven operation
          if (!condition.isEmpty) {
            final conditionMap = condition.build();

            // Heuristic 2: primary key queries for equality-like ops only (=, IN, BETWEEN)
            if (conditionMap.containsKey(primaryKey)) {
              final pkCond = conditionMap[primaryKey];
              if (pkCond is Map<String, dynamic>) {
                const supportedOps = ['=', 'IN', 'BETWEEN'];
                for (final op in supportedOps) {
                  if (pkCond.containsKey(op)) {
                    isOptimizableQuery = true;
                    break;
                  }
                }
              } else {
                // Direct equality value
                isOptimizableQuery = true;
              }
            }

            // Heuristic 3: unique field equality or IN (range operators are excluded)
            if (!isOptimizableQuery) {
              final uniqueFieldNames = <String>{};
              for (final index in schema.getAllIndexes()) {
                if (index.unique && index.fields.length == 1) {
                  uniqueFieldNames.add(index.fields[0]);
                }
              }
              for (final fname in uniqueFieldNames) {
                if (conditionMap.containsKey(fname)) {
                  final v = conditionMap[fname];
                  if (v is Map<String, dynamic>) {
                    if (v.containsKey('=') || v.containsKey('IN')) {
                      isOptimizableQuery = true;
                      break;
                    }
                  } else {
                    isOptimizableQuery = true;
                    break;
                  }
                }
              }
            }
          }

          // If limit is not null and less than 200000, set isOptimizableQuery to true
          if (limit != null && limit < 200000) {
            isOptimizableQuery = true;
            if (offset != null && offset > 200000) {
              isOptimizableQuery = false;
            }
          }
        }
      } else {
        isOptimizableQuery = false;
      }

      // If inside a transaction and this is a heavy update path, we should defer execution
      if (!isOptimizableQuery) {
        // Heavy update branch
        if (txId != null && !TransactionContext.isApplyingCommit()) {
          // Defer heavy update within transaction: record plan only and return success
          final hu = HeavyUpdatePlan(
            tableName: tableName,
            condition: condition.build(),
            updateData: validData,
            orderBy: orderBy,
            limit: limit,
            offset: offset,
          );
          transactionManager?.registerDeferredHeavyUpdate(txId, hu);
          return finish(DbResult.success(
            message: 'Deferred heavy update recorded in transaction',
          ));
        }
        // Heavy update execution path (not in transaction or during commit)
        // Use processTablePartitions for batch processing to avoid memory overflow
        // Concurrency check for heavy operations (global throttling of processTablePartitions)
        if (_heavyUpdateOperationsInProgress >=
            _maxConcurrentPartitionMaintenances) {
          final completer = Completer<void>();
          _heavyUpdateQueue.add(completer);
          Logger.info(
              'Heavy update operation for table $tableName queued due to concurrency limit.',
              label: 'DataStore-update');
          await completer.future;
        }
        _heavyUpdateOperationsInProgress++;
        String largeUpdateOpId = '';
        bool createdNewOp = false;
        try {
          Logger.info(
              'Table $tableName has a large number of records and a complex update condition. A multi-batch update process will be used. Please wait.',
              label: 'DataStore-update');

          // create counters
          int totalProcessed = 0;
          int totalUpdated = checkpointUpdatedSoFar ?? 0;
          // Collect updated record keys
          final List<String> updatedKeys = [];
          const maxUpdatedKeysToReturn = 100000;

          // Determine opId and start partition via checkpoint or create new
          final bool hasCheckpointOp =
              (checkpointOpId != null && checkpointOpId.isNotEmpty);
          largeUpdateOpId = hasCheckpointOp
              ? checkpointOpId
              : GlobalIdGenerator.generate('large_update_');

          // Use checkpoint partition number if provided
          final int? startPartitionNo = checkpointStartPartitionNo;
          try {
            // Only create a new WAL large update entry when not resuming an existing op
            if (!hasCheckpointOp) {
              await walManager.beginLargeUpdate(
                opId: largeUpdateOpId,
                table: tableName,
                condition: condition.build(),
                updateData: validData,
                orderBy: orderBy,
                limit: limit,
                offset: offset,
                startPartitionNo: startPartitionNo,
              );
              createdNewOp = true;
            }
          } catch (_) {}

          // Determine the batch size threshold based on record cache size, with a 200MB default.
          final effectiveRecordCacheSize =
              memoryManager?.getRecordCacheSize() ?? 200 * 1024 * 1024;
          final maxBatchMemorySizeInBytes = effectiveRecordCacheSize * 0.2;

          // Calculate max partitions in a batch based on memory limits and max partition file size.
          final maxPartitionsInBatch = (config.maxPartitionFileSize > 0
                  ? (maxBatchMemorySizeInBytes / config.maxPartitionFileSize)
                  : 10)
              .ceil()
              .clamp(1, 100);

          final recordsInBatch = <Map<String, dynamic>>[];
          final partitionsInBatch = <int>[];
          final oldRecordsInBatch = <Map<String, dynamic>>[];

          final isPrimaryKeyUpdate = validData.containsKey(primaryKey);
          final Set<String> indexedFieldNames = <String>{primaryKey}
            ..addAll(schema.getAllIndexes().expand((i) => i.fields));

          Future<void> flushIndexUpdateBatch() async {
            if (_indexManager == null || recordsInBatch.isEmpty) return;
            final updates = <IndexRecordUpdate>[];
            final int len =
                min(recordsInBatch.length, oldRecordsInBatch.length);

            final yieldController =
                YieldController('DataStoreImpl._updateInternal.flushIndex');
            for (int i = 0; i < len; i++) {
              final newRec = recordsInBatch[i];
              final oldRec = oldRecordsInBatch[i];
              final pk = newRec[primaryKey]?.toString();
              if (pk == null || pk.isEmpty) continue;

              final changed = <String>{};
              final oldVals = <String, dynamic>{};
              for (final field in indexedFieldNames) {
                final oldVal = oldRec[field];
                final newVal = newRec[field];
                if (oldVal != newVal) {
                  changed.add(field);
                  oldVals[field] = oldVal;
                }
              }

              if (changed.isEmpty) continue;

              updates.add(IndexRecordUpdate(
                primaryKey: pk,
                newValues: Map<String, dynamic>.from(newRec),
                oldValues:
                    oldVals.isEmpty ? null : Map<String, dynamic>.from(oldVals),
                changedFields: changed,
              ));
              await yieldController.maybeYield();
            }

            if (updates.isEmpty) return;
            await _indexManager?.writeChanges(
              tableName: tableName,
              updates: updates,
            );
          }

          // Identify unique fields that need validation during heavy update
          final Set<String> uniqueFieldsToCheck = <String>{};
          if (_indexManager != null) {
            for (final index in schema.getAllIndexes()) {
              if (!index.unique) continue;
              if (index.fields.any((f) => validData.containsKey(f))) {
                uniqueFieldsToCheck.addAll(index.fields);
              }
            }
          }

          // build a process function, to check if each partition's record matches the update condition
          Future<List<Map<String, dynamic>>> processFunction(
              records, partitionNo, controller) async {
            // record original count
            int originalCount = records.length;

            // Create a new list with all records (do not filter out)
            final resultRecords = List<Map<String, dynamic>>.from(records);

            // collect updated records
            final updatedRecordsInPartition = <Map<String, dynamic>>[];
            final oldRecordsInPartition = <Map<String, dynamic>>[];

            final yieldController =
                YieldController('DataStoreImpl._updateInternal.process');
            // Process each record in the partition
            for (int i = 0; i < resultRecords.length; i++) {
              final record = resultRecords[i];

              // skip if already deleted record
              if (isDeletedRecord(record)) continue;

              final matches = matcher.matches(record);
              if (matches) {
                // Apply limit before processing the record for update
                if (limit != null && totalUpdated >= limit) {
                  if (!controller.isStopped) {
                    controller.stop();
                  }
                  continue; // Stop processing further matches in this partition
                }

                totalUpdated++;

                // Store old record for index diff and foreign key validation
                oldRecordsInPartition.add(Map<String, dynamic>.from(record));

                // Build updated record by merging with update data
                final updatedRecord = <String, dynamic>{};
                updatedRecord[primaryKey] = record[primaryKey];

                for (final field in schema.fields) {
                  if (field.name == primaryKey) {
                    continue;
                  }
                  final String fname = field.name;
                  final dynamic proposed =
                      validData.containsKey(fname) ? validData[fname] : null;

                  if (proposed is ExprNode) {
                    // Evaluate expression atomically using current record values
                    try {
                      final result = _evaluateExpression(
                        proposed,
                        record,
                        schema,
                      );
                      // Convert result to match field type (e.g., round double to int for integer fields)
                      updatedRecord[fname] = field.convertValue(result);
                    } catch (e) {
                      Logger.error(
                        'Failed to evaluate expression for field $fname: $e',
                        label: 'DataStore.updateInternal',
                      );
                      // On error, keep the current value to maintain data integrity
                      updatedRecord[fname] = record[fname];
                    }
                  } else if (validData.containsKey(fname)) {
                    updatedRecord[fname] = proposed;
                  } else {
                    updatedRecord[fname] = record[fname];
                  }
                }

                // Verify unique constraints for heavy update (bypass buffer/reservation)
                if (uniqueFieldsToCheck.isNotEmpty && _indexManager != null) {
                  try {
                    final uniqueCheckData = <String, dynamic>{
                      primaryKey: updatedRecord[primaryKey],
                    };
                    for (final f in uniqueFieldsToCheck) {
                      uniqueCheckData[f] = updatedRecord[f];
                    }

                    final violation =
                        await _indexManager!.checkUniqueConstraints(
                      tableName,
                      uniqueCheckData,
                      isUpdate: true,
                      // checkDiskOnly: false (default) - MUST check buffer for conflicts to avoid duplication,
                      // even though we don't add to buffer.
                      // checkInBuffer() is read-only and won't add to buffer.
                    );

                    if (violation != null) {
                      Logger.warn(
                          '[Unique Constraint Violation] Skipping record during heavy update - ${violation.message}',
                          label: 'DataStore.updateInternal');
                      continue;
                    }
                  } catch (e) {
                    Logger.error(
                        'Unique constraint check failed during heavy update: $e',
                        label: 'DataStore.updateInternal');
                    continue;
                  }
                }

                // Validate foreign key constraints if needed
                if (_foreignKeyManager != null) {
                  try {
                    await _foreignKeyManager!.validateForeignKeyConstraints(
                      tableName: tableName,
                      data: updatedRecord,
                      operation: ForeignKeyOperation.update,
                    );
                  } catch (e) {
                    Logger.error(
                        'Foreign key constraint validation failed during heavy update: $e',
                        label: 'DataStore.updateInternal');
                    // Skip this record in heavy update (continue processing others)
                    continue;
                  }

                  // Handle foreign key constraints for primary key update in heavy update path
                  // CRITICAL: RESTRICT/NO ACTION constraints must be checked immediately,
                  // only CASCADE operations can be deferred
                  if (isPrimaryKeyUpdate) {
                    final oldPkValue = record[primaryKey];
                    final newPkValue = updatedRecord[primaryKey];
                    if (oldPkValue != null &&
                        newPkValue != null &&
                        oldPkValue != newPkValue) {
                      // Phase 1: Always check RESTRICT/NO ACTION constraints immediately
                      try {
                        await _foreignKeyManager!
                            .checkRestrictConstraintsForUpdate(
                          tableName: tableName,
                          oldPkValues: oldPkValue,
                        );
                      } catch (e) {
                        Logger.error(
                            'RESTRICT constraint check failed during heavy update: $e',
                            label: 'DataStore.updateInternal');
                        // Skip this record
                        continue;
                      }

                      // Phase 2: Handle CASCADE/SET NULL/SET DEFAULT operations
                      // CRITICAL: For heavy update, execute cascade immediately for each record
                      // to ensure atomicity. If cascade fails, the update should also fail.
                      // This prevents partial updates where some records are updated but cascade fails.
                      try {
                        await _foreignKeyManager!.handleCascadeUpdate(
                          tableName: tableName,
                          oldPkValues: oldPkValue,
                          newPkValues: newPkValue,
                          visitedTables: null,
                          skipRestrictCheck:
                              true, // RESTRICT already checked above
                        );
                      } catch (e) {
                        Logger.error(
                            'Cascade update failed during heavy update: $e',
                            label: 'DataStore.updateInternal');
                        // Skip this record - don't update if cascade fails
                        // This ensures data consistency: if cascade fails, the update is also skipped
                        continue;
                      }
                    }
                  }
                }

                // get record primary key value
                final pkValue = record[primaryKey];
                if (pkValue != null) {
                  final pkValueStr = pkValue.toString();
                  // Add to updated keys list (with limit)
                  if (updatedKeys.length < maxUpdatedKeysToReturn) {
                    updatedKeys.add(pkValueStr);
                  }

                  // remove from write queue (if exists)
                  tableDataManager.removeRecordFromBuffer(
                      tableName, pkValueStr);
                }

                // Replace record with updated version
                resultRecords[i] = updatedRecord;
                updatedRecordsInPartition.add(updatedRecord);

                notificationManager.notify(ChangeEvent(
                  type: ChangeType.update,
                  tableName: tableName,
                  record: updatedRecord,
                  oldRecord: record,
                ));
              }
              await yieldController.maybeYield();
            }

            totalProcessed += originalCount;

            if (updatedRecordsInPartition.isNotEmpty) {
              recordsInBatch.addAll(updatedRecordsInPartition);
              oldRecordsInBatch.addAll(oldRecordsInPartition);
              partitionsInBatch.add(partitionNo);

              // Flush the batch when the number of partitions with updates reaches the calculated threshold.
              if (partitionsInBatch.length >= maxPartitionsInBatch) {
                // Invalidate records from cache
                await tableDataManager.removeTableRecords(
                    tableName,
                    recordsInBatch
                        .map((r) => r[primaryKey]?.toString())
                        .where((k) => k != null)
                        .map((k) => k!)
                        .toList());

                await flushIndexUpdateBatch();

                recordsInBatch.clear();
                oldRecordsInBatch.clear();
                partitionsInBatch.clear();
              }
            }

            return resultRecords;
          }

          // use processTablePartitions to process all partitions (skip global maintenance lock; no journal)
          await tableDataManager.processTablePartitions(
            tableName: tableName,
            processFunction: processFunction,
            startPartitionNo: startPartitionNo,
            skipMaintenanceGlobalLock: true,
            largeUpdateOpId: largeUpdateOpId,
            onPartitionFlushed: (int partitionNo) async {
              try {
                await walManager.updateLargeUpdateCheckpoint(
                  opId: largeUpdateOpId,
                  lastProcessedPartitionNo: partitionNo,
                  updatedSoFar: totalUpdated,
                );
              } catch (_) {}
            },
          );

          // Process any remaining records in the last batch
          if (recordsInBatch.isNotEmpty) {
            // Invalidate records from cache
            await tableDataManager.removeTableRecords(
              tableName,
              recordsInBatch
                  .map((r) => r[primaryKey]?.toString())
                  .where((k) => k != null)
                  .map((k) => k!)
                  .toList(),
            );

            await flushIndexUpdateBatch();
          }

          // Complete large update tracking in WAL meta
          try {
            await walManager.completeLargeUpdate(largeUpdateOpId);
          } catch (_) {}

          return finish(DbResult.success(
            successKeys: updatedKeys,
            message:
                'Successfully updated $totalUpdated records (processed $totalProcessed)',
          ));
        } catch (updateError) {
          // If heavy update fails and we created a new op, cancel it to avoid orphaned checkpoints
          if (createdNewOp) {
            try {
              await walManager.cancelLargeUpdate(largeUpdateOpId);
            } catch (_) {
              // Best effort cleanup, ignore errors
            }
          }
          rethrow;
        } finally {
          _heavyUpdateOperationsInProgress--;
          if (_heavyUpdateQueue.isNotEmpty) {
            _heavyUpdateQueue.removeFirst().complete();
          }
        }
      } else {
        // Optimizable query path: use regular method
        // find matching records (for optimizable queries)
        // Use a large internal limit when limit is null to avoid default QueryLimit (e.g. 1000)
        final int effectiveLimit = limit ?? 1000000000;
        final records = await executeQuery(tableName, condition,
            orderBy: orderBy, limit: effectiveLimit, offset: offset);
        if (records.isEmpty) {
          return finish(DbResult.error(
            type: ResultType.notFound,
            message: 'No matching records found',
          ));
        }

        // Check if primary key is being updated (for cascade update handling)
        final isPrimaryKeyUpdate = validData.containsKey(primaryKey);

        // Validate foreign key constraints for each record to be updated
        if (_foreignKeyManager != null) {
          final yieldController = YieldController('db_update_fk');
          for (final record in records) {
            await yieldController.maybeYield();
            // Merge existing record with update data
            final mergedData = Map<String, dynamic>.from(record);
            mergedData.addAll(validData);

            try {
              await _foreignKeyManager!.validateForeignKeyConstraints(
                tableName: tableName,
                data: mergedData,
                operation: ForeignKeyOperation.update,
              );
            } catch (e) {
              Logger.error('Foreign key constraint validation failed: $e',
                  label: 'DataStore.updateInternal');
              return finish(DbResult.error(
                type: ResultType.foreignKeyViolation,
                message: e.toString(),
              ));
            }

            // Handle foreign key constraints for primary key update: RESTRICT must be checked immediately, CASCADE can be deferred
            // CRITICAL: RESTRICT/NO ACTION constraints must be checked immediately when update is attempted,
            // not at commit time. Only CASCADE/SET NULL/SET DEFAULT operations can be deferred to commit.
            if (isPrimaryKeyUpdate) {
              final oldPkValue = record[primaryKey];
              final newPkValue = mergedData[primaryKey];
              if (oldPkValue != null &&
                  newPkValue != null &&
                  oldPkValue != newPkValue) {
                // Phase 1: Always check RESTRICT/NO ACTION constraints immediately (even in transaction)
                // This ensures violations are caught early and transaction can be rolled back
                try {
                  await _foreignKeyManager!.checkRestrictConstraintsForUpdate(
                    tableName: tableName,
                    oldPkValues: oldPkValue,
                  );
                } catch (e) {
                  Logger.error('RESTRICT constraint check failed: $e',
                      label: 'DataStore.updateInternal');
                  return finish(_normalizeCascadeError(e, 'update'));
                }

                // Phase 2: Handle CASCADE/SET NULL/SET DEFAULT operations
                if (txId != null) {
                  // In transaction: defer CASCADE operations until commit
                  // RESTRICT has already been checked above, so we can safely defer CASCADE
                  transactionManager?.registerDeferredCascadeUpdate(
                      txId, tableName, oldPkValue, newPkValue);
                } else {
                  // Outside transaction: execute CASCADE operations immediately
                  try {
                    await _foreignKeyManager!.handleCascadeUpdate(
                      tableName: tableName,
                      oldPkValues: oldPkValue,
                      newPkValues: newPkValue,
                      visitedTables:
                          null, // Start with fresh visited set for each update
                      skipRestrictCheck: true, // RESTRICT already checked above
                    );
                  } catch (e) {
                    Logger.error('Cascade update failed: $e',
                        label: 'DataStore.updateInternal');
                    return finish(_normalizeCascadeError(e, 'update'));
                  }
                }
              }
            }
          }
        }
        final List<String> successKeys = [];
        final List<String> failedKeys = [];

        // Row-level locks for target records
        final lockMgr = lockManager;
        final Map<String, String> acquiredResources = {};

        final yieldController =
            YieldController('DataStoreImpl._updateInternal.loop');

        // Unified unique constraints check using IndexManager, with unique-key granular locks.
        // Only pass affected unique-constrained fields (including composite index fields) plus primary key.
        final Set<String> changedFields = validData.keys.toSet();
        final Set<String> fieldsToCheck = <String>{};

        // Collect fields from unique composite/single-field indexes that are affected by this update
        for (final index in schema.getAllIndexes()) {
          if (!index.unique) continue;
          if (index.fields.any((f) => changedFields.contains(f))) {
            fieldsToCheck.addAll(index.fields);
          }
        }

        for (var record in records) {
          await yieldController.maybeYield();
          final recordKey = record[primaryKey]?.toString() ?? '';
          if (recordKey.isEmpty) {
            continue; // Skip records without primary key
          }

          // Single-pass merge in schema order; interpret FieldValue inline
          var updatedRecord = <String, dynamic>{};

          // Primary key first (not updatable)
          updatedRecord[primaryKey] = record[primaryKey];

          for (final field in schema.fields) {
            if (field.name == primaryKey) {
              continue;
            }
            final String fname = field.name;
            final dynamic proposed =
                validData.containsKey(fname) ? validData[fname] : null;

            if (proposed is ExprNode) {
              // Evaluate expression atomically using current record values
              try {
                final result = _evaluateExpression(
                  proposed,
                  record,
                  schema,
                );
                // Convert result to match field type (e.g., round double to int for integer fields)
                updatedRecord[fname] = field.convertValue(result);
              } catch (e) {
                Logger.error(
                  'Failed to evaluate expression for field $fname: $e',
                  label: 'DataStore.updateInternal',
                );
                // On error, keep the current value to maintain data integrity
                updatedRecord[fname] = record[fname];
              }
            } else if (validData.containsKey(fname)) {
              updatedRecord[fname] = proposed;
            } else {
              updatedRecord[fname] = record[fname];
            }
          }

          bool ok = true;
          UniqueViolation? uniqueViolation;
          UniquePlan? planUpd;
          List<UniqueKeyRef>? oldUniqueKeys;

          if (fieldsToCheck.isNotEmpty) {
            // Plan unique + refs for update
            planUpd = planUniqueForUpdate(
                tableName, schema, updatedRecord, changedFields);

            // Try reserve unique keys (replaces manual locking)
            try {
              oldUniqueKeys = writeBufferManager.tryReserveUniqueKeys(
                tableName: tableName,
                recordId: recordKey,
                uniqueKeys: planUpd.refs,
                transactionId: txId,
              );
            } catch (e) {
              if (e is UniqueViolation) {
                if (continueOnPartialErrors) {
                  failedKeys.add(recordKey);
                  continue;
                }
                return finish(DbResult.error(
                  type: ResultType.uniqueViolation,
                  message: e.message,
                  failedKeys: [recordKey],
                ));
              }
              rethrow;
            }

            // Perform unique check under reservation (disk/cache only)
            final Map<String, dynamic> uniqueCheckData = <String, dynamic>{};
            // Include primary key for self-identification during update
            uniqueCheckData[primaryKey] = record[primaryKey];
            for (final fname in fieldsToCheck) {
              uniqueCheckData[fname] = updatedRecord[fname];
            }
            uniqueViolation = await _indexManager?.checkUniqueConstraints(
              tableName,
              uniqueCheckData,
              isUpdate: true,
              txId: txId,
              schemaOverride: schema,
            );
            ok = uniqueViolation == null;
            if (!ok) {
              // Release reservation and restore old keys if check failed
              writeBufferManager.releaseReservedUniqueKeys(
                tableName: tableName,
                recordId: recordKey,
                transactionId: txId,
                restoreKeys: oldUniqueKeys,
              );
            }
          }

          if (!ok) {
            failedKeys.add(recordKey);
            if (continueOnPartialErrors) {
              continue;
            }
            return finish(DbResult.error(
              type: ResultType.uniqueViolation,
              message:
                  uniqueViolation?.message ?? 'Unique constraint violation',
              failedKeys: [recordKey],
            ));
          }

          // Acquire row lock
          if (lockMgr != null) {
            try {
              final res = 'row:$tableName:pk:$recordKey';
              final opId = GlobalIdGenerator.generate('update_row_');
              final ok = await lockMgr.acquireExclusiveLock(res, opId);
              if (!ok) {
                writeBufferManager.releaseReservedUniqueKeys(
                  tableName: tableName,
                  recordId: recordKey,
                  transactionId: txId,
                  restoreKeys: oldUniqueKeys,
                );
                if (continueOnPartialErrors) {
                  // release unique locks before continuing
                  failedKeys.add(recordKey);
                  continue;
                }
                // release unique locks before returning
                return finish(DbResult.error(
                  type: ResultType.dbError,
                  message: 'Lock conflict on primary key $recordKey',
                ));
              }
              acquiredResources[res] = opId;
              if (txId != null) {
                TransactionContext.registerExclusiveLock(res, opId);
              }
            } catch (_) {}
          }

          // Register write-set for SSI conflict detection
          if (txId != null) {
            transactionManager?.registerWriteKey(txId, tableName, recordKey);
          }

          // update write queue using planned refs
          final uniqueRefsUpd = planUpd?.refs ?? const <UniqueKeyRef>[];
          final Set<String> indexFields = <String>{primaryKey};
          final bool pkChanged = isPrimaryKeyUpdate &&
              record[primaryKey] != null &&
              updatedRecord[primaryKey] != null &&
              record[primaryKey] != updatedRecord[primaryKey];
          if (pkChanged) {
            // Primary key change affects all secondary indexes (non-unique: key suffix; unique: value).
            for (final idx in schema.getAllIndexes()) {
              indexFields.addAll(idx.fields);
            }
          } else {
            for (final idx in schema.getAllIndexes()) {
              if (idx.fields.any((f) => changedFields.contains(f))) {
                indexFields.addAll(idx.fields);
              }
            }
          }
          final Map<String, dynamic> oldValues = {};
          for (final k in indexFields) {
            if (record.containsKey(k)) {
              oldValues[k] = record[k];
            }
          }
          await tableDataManager.addToBuffer(
            tableName,
            updatedRecord,
            BufferOperationType.update,
            uniqueKeyRefs: uniqueRefsUpd,
            oldValues: oldValues.isEmpty ? null : oldValues,
            transactionId: txId,
          );

          notificationManager.notify(ChangeEvent(
            type: ChangeType.update,
            tableName: tableName,
            record: updatedRecord,
            oldRecord: record,
          ));

          // Add to success keys list
          successKeys.add(recordKey);
        }

        // Non-transaction: release locks immediately; transaction: release by commit/rollback
        try {
          if (lockMgr != null && txId == null && acquiredResources.isNotEmpty) {
            acquiredResources.forEach((res, opId) {
              try {
                lockMgr.releaseExclusiveLock(res, opId);
              } catch (_) {}
            });
          }
        } catch (_) {}

        // If there are both successful and failed records
        if (successKeys.isNotEmpty && failedKeys.isNotEmpty) {
          return finish(DbResult.batch(
            successKeys: successKeys,
            failedKeys: failedKeys,
            message:
                'Update partially successful, ${successKeys.length} records updated, ${failedKeys.length} records failed',
          ));
        } else {
          return finish(DbResult.success(
            successKeys: successKeys,
            message:
                'Update successful, affected ${successKeys.length} records',
          ));
        }
      }
    } catch (e) {
      Logger.error('Update failed: $e', label: 'DataStore-update');
      if (isInTransactionWithRollback()) {
        rethrow;
      }
      // Best-effort release locks
      try {
        final lockMgr = lockManager;
        if (lockMgr != null) {
          // We didn't retain acquiredResources here on exception; rely on txn zone or opId unreleased is acceptable in failure since lock timeout exists
        }
      } catch (_) {}
      return DbResult.error(
        type: ResultType.dbError,
        message: 'Update failed: $e',
      );
    }
  }

  /// clear table
  /// Returns [DbResult] to allow graceful error handling for business logic errors
  /// (e.g., RESTRICT foreign key constraints) instead of throwing exceptions
  /// This is consistent with other business operations (insert, update, delete)
  Future<DbResult> clear(String tableName, {bool registerWalOp = true}) async {
    DbResult finish(DbResult r) => _returnOrThrowIfTxn(r, 'clear', tableName);

    if (registerWalOp) {
      await ensureInitialized();
    }
    final schema = await schemaManager?.getTableSchema(tableName);
    if (schema == null) {
      Logger.error('Table $tableName does not exist', label: 'DataStore.clear');
      return finish(DbResult.error(
        type: ResultType.notFound,
        message: 'Table $tableName does not exist',
      ));
    }

    String? clearOpId;
    if (registerWalOp && config.enableJournal) {
      try {
        final cutoff = walManager.currentPointer;
        final opId = GlobalIdGenerator.generate('tbl_clear_');
        final op = TableOpMeta(
          opId: opId,
          table: tableName,
          type: 'clear',
          cutoff: cutoff,
          createdAt: DateTime.now().toIso8601String(),
        );
        await walManager.registerTableOp(op);
        clearOpId = opId;
      } catch (e) {
        Logger.warn('Register clear table op failed: $e',
            label: 'DataStore.clear');
      }
    }

    try {
      // Handle foreign key cascade operations before clearing the table
      // This ensures data consistency: child records are handled according to foreign key policies
      if (_foreignKeyManager != null) {
        try {
          await _foreignKeyManager!.handleCascadeClear(tableName);
        } catch (e) {
          Logger.error('Cascade clear failed: $e', label: 'DataStore.clear');
          // Convert exception to DbResult for graceful error handling
          // This allows developers to handle business logic errors (e.g., RESTRICT constraints)
          // without using try-catch, making the API consistent with insert/update/delete
          return finish(_normalizeCascadeError(e, 'clear'));
        }
      }

      //   clear application layer cache
      await cacheManager.invalidateCache(tableName);

      //  clear partition file deletion, auto-increment ID reset, and related cache cleanup
      await tableDataManager.clearTable(tableName);

      //  reset index
      await _indexManager?.resetIndexes(tableName);

      // If there is no WAL segment newer than the cutoff (i.e. cutoff is at
      // or before checkpoint), the clear/drop op does not need to stay in
      // WAL meta for skip semantics. After a successful clear we can mark
      // the op as completed so that it will be removed if safe.
      if (registerWalOp && config.enableJournal && clearOpId != null) {
        try {
          await walManager.completeTableOp(clearOpId);
        } catch (e) {
          Logger.warn('Complete clear table op failed: $e',
              label: 'DataStore.clear');
        }
      }

      return finish(DbResult.success(
        message: 'Table $tableName cleared successfully',
      ));
    } catch (e) {
      Logger.info('Clear table failed: $e', label: 'DataStore-clear');
      // Convert any unexpected exceptions to DbResult for graceful error handling
      return finish(DbResult.error(
        type: ResultType.dbError,
        message: 'Failed to clear table $tableName: $e',
      ));
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
    // Optional checkpoint to resume heavy delete from a specific partition and deleted count
    int? checkpointStartPartitionNo,
    int? checkpointDeletedSoFar,
    String? checkpointOpId,
  }) async {
    DbResult finish(DbResult r) => _returnOrThrowIfTxn(r, 'delete', tableName);
    await ensureInitialized();

    // check if condition is empty, avoid accidental deletion of all records
    if (condition.isEmpty) {
      if (!allowAll) {
        Logger.warn(
            'Delete operation without condition, this may cause accidental deletion of all records, please use allowDeleteAll() method to explicitly confirm.',
            label: 'DataStore.deleteInternal');
        return finish(DbResult.error(
          type: ResultType.validationFailed,
          message:
              'Delete operation must specify a filter condition. If you really need to delete all records, please use allowDeleteAll() method to explicitly confirm.',
        ));
      } else {
        // If allowAll=true and no condition, use clear() for better performance
        Logger.info(
            'Using clear() for better performance when deleting all records',
            label: 'DataStore.deleteInternal');

        // Use clear() for better performance when deleting all records
        // clear() now returns DbResult for graceful error handling
        final clearResult = await clear(tableName);
        if (clearResult.isSuccess) {
          return finish(DbResult.success(
            message: 'All records in table $tableName have been deleted',
          ));
        } else {
          // clear() failed (e.g., due to RESTRICT foreign key constraints)
          // Return the error result from clear()
          return finish(clearResult);
        }
      }
    }

    try {
      // If inside a transaction and this is a heavy delete path, we should defer execution
      final String? txId = Zone.current[_txnZoneKey] as String?;
      // Get table file metadata to make an informed decision on the deletion strategy
      final tableMeta = await tableDataManager.getTableMeta(tableName);

      // Get memory manager to access cache size limits
      final recordCacheSize =
          memoryManager?.getRecordCacheSize() ?? 200 * 1024 * 1024;

      // get table schema
      final schema = await schemaManager?.getTableSchema(tableName);
      if (schema == null) {
        Logger.warn('Table $tableName does not exist',
            label: 'DataStore.deleteInternal');
        return finish(DbResult.error(
          type: ResultType.notFound,
          message: 'Table $tableName does not exist',
        ));
      }

      final schemas = {tableName: schema};
      final matcher =
          ConditionRecordMatcher.prepare(condition, schemas, tableName);

      final primaryKey = schema.primaryKey;

      // Check if condition is an equality on primary key or unique field - this can be optimized
      bool isOptimizableQuery = false;
      // If resuming a large delete from checkpoint, force heavy path (disable optimizable branch)
      if (checkpointOpId == null) {
        // Small table heuristics: always optimize when
        // - table meta is unknown or size invalid
        // - size < 5MB (unconditional minimum threshold)
        // - size < 30% of record cache size
        const int minSmallTableBytes = 5 * 1024 * 1024; // 5MB
        if (tableMeta == null ||
            tableMeta.totalSizeInBytes < minSmallTableBytes ||
            tableMeta.totalSizeInBytes < recordCacheSize * 0.3) {
          isOptimizableQuery = true;
        }

        if (!isOptimizableQuery) {
          // Analyze condition to check if it's a primary key/unique/index-driven operation
          if (!condition.isEmpty) {
            final conditionMap = condition.build();

            // Heuristic 2: primary key queries for equality-like ops only (=, IN, BETWEEN)
            if (conditionMap.containsKey(primaryKey)) {
              final pkCond = conditionMap[primaryKey];
              if (pkCond is Map<String, dynamic>) {
                const supportedOps = ['=', 'IN', 'BETWEEN'];
                for (final op in supportedOps) {
                  if (pkCond.containsKey(op)) {
                    isOptimizableQuery = true;
                    break;
                  }
                }
              } else {
                // Direct equality value
                isOptimizableQuery = true;
              }
            }

            // Heuristic 3: unique field equality or IN (range operators are excluded)
            if (!isOptimizableQuery) {
              final uniqueFieldNames = <String>{};
              for (final index in schema.getAllIndexes()) {
                if (index.unique && index.fields.length == 1) {
                  uniqueFieldNames.add(index.fields[0]);
                }
              }
              for (final fname in uniqueFieldNames) {
                if (conditionMap.containsKey(fname)) {
                  final v = conditionMap[fname];
                  if (v is Map<String, dynamic>) {
                    if (v.containsKey('=') || v.containsKey('IN')) {
                      isOptimizableQuery = true;
                      break;
                    }
                  } else {
                    isOptimizableQuery = true;
                    break;
                  }
                }
              }
            }
          }

          // If limit is not null and less than 200000, set isOptimizableQuery to true
          if (limit != null && limit < 200000) {
            isOptimizableQuery = true;
            if (offset != null && offset > 200000) {
              isOptimizableQuery = false;
            }
          }
        }
      } else {
        isOptimizableQuery = false;
      }

      // when table record count is less than threshold or this is an optimizable query, use regular method
      if (isOptimizableQuery) {
        // standard method: get all records
        // Use a large internal limit when limit is null to avoid default QueryLimit (e.g. 1000)
        final int effectiveLimit = limit ?? 1000000000;
        final recordsToDelete = await executeQuery(tableName, condition,
            orderBy: orderBy, limit: effectiveLimit, offset: offset);

        if (recordsToDelete.isEmpty) {
          return finish(DbResult.success(
            message: 'No records found to delete',
            successKeys: [],
          ));
        }

        // Handle foreign key constraints: RESTRICT must be checked immediately, CASCADE can be deferred
        // CRITICAL: RESTRICT/NO ACTION constraints must be checked immediately when delete is attempted,
        // not at commit time. Only CASCADE/SET NULL/SET DEFAULT operations can be deferred to commit.
        if (_foreignKeyManager != null) {
          final yieldController = YieldController('db_delete_fk');
          for (final record in recordsToDelete) {
            await yieldController.maybeYield();
            final pkValue = record[primaryKey];
            if (pkValue != null) {
              // Phase 1: Always check RESTRICT/NO ACTION constraints immediately (even in transaction)
              // This ensures violations are caught early and transaction can be rolled back
              try {
                await _foreignKeyManager!.checkRestrictConstraintsForDelete(
                  tableName: tableName,
                  deletedPkValues: pkValue,
                );
              } catch (e) {
                Logger.error('RESTRICT constraint check failed: $e',
                    label: 'DataStore.deleteInternal');
                return finish(_normalizeCascadeError(e, 'delete'));
              }

              // Phase 2: Handle CASCADE/SET NULL/SET DEFAULT operations
              if (txId != null) {
                // In transaction: defer CASCADE operations until commit
                // RESTRICT has already been checked above, so we can safely defer CASCADE
                transactionManager?.registerDeferredCascadeDelete(
                    txId, tableName, pkValue);
              } else {
                // Outside transaction: execute CASCADE operations immediately
                try {
                  await _foreignKeyManager!.handleCascadeDelete(
                    tableName: tableName,
                    deletedPkValues: pkValue,
                    skipRestrictCheck: true, // RESTRICT already checked above
                  );
                } catch (e) {
                  Logger.error('Cascade delete failed: $e',
                      label: 'DataStore.deleteInternal');
                  return finish(_normalizeCascadeError(e, 'delete'));
                }
              }
            }
          }
        }

        // Collect successful primary keys
        final List<String> successKeys = [];

        // Row-level locks for delete
        final lockMgr = lockManager;
        final Map<String, String> acquiredResources = {};

        final yieldController =
            YieldController('DataStoreImpl._deleteInternal.loop');
        for (var i = 0; i < recordsToDelete.length; i++) {
          final record = recordsToDelete[i];
          final pkValue = record[primaryKey]?.toString();
          if (pkValue == null) {
            continue;
          }
          // Acquire lock per record with unique operation id per resource
          if (lockMgr != null) {
            try {
              final res = 'row:$tableName:pk:$pkValue';
              final opId = GlobalIdGenerator.generate('delete_row_');
              final ok = await lockMgr.acquireExclusiveLock(res, opId);
              if (ok) {
                acquiredResources[res] = opId;
                if (txId != null) {
                  TransactionContext.registerExclusiveLock(res, opId);
                }
              }
            } catch (_) {}
          }
          // Add to success keys
          successKeys.add(pkValue);

          // Register write-set for SSI conflict detection
          if (txId != null) {
            transactionManager?.registerWriteKey(txId, tableName, pkValue);
          }

          await yieldController.maybeYield();
        }

        // Not in transaction: release locks immediately; in transaction: release by commit/rollback
        try {
          if (lockMgr != null && txId == null && acquiredResources.isNotEmpty) {
            acquiredResources.forEach((res, opId) {
              try {
                lockMgr.releaseExclusiveLock(res, opId);
              } catch (_) {}
            });
          }
        } catch (_) {}

        // Remove from record cache only when not in a transaction
        if (txId == null) {
          await tableDataManager.removeTableRecords(tableName, successKeys);
        }

        // Add records to delete buffer instead of directly writing to file
        await tableDataManager.addToDeleteBuffer(tableName, recordsToDelete);

        for (final record in recordsToDelete) {
          notificationManager.notify(ChangeEvent(
            type: ChangeType.delete,
            tableName: tableName,
            oldRecord: record,
          ));
        }

        return finish(DbResult.success(
          successKeys: successKeys,
          message: 'Successfully deleted ${successKeys.length} records',
        ));
      } else {
        // Heavy delete branch
        if (txId != null && !TransactionContext.isApplyingCommit()) {
          // Defer heavy delete within transaction: record plan only and return success
          final hd = HeavyDeletePlan(
            tableName: tableName,
            condition: condition.build(),
            orderBy: orderBy,
            limit: limit,
            offset: offset,
          );
          transactionManager?.registerDeferredHeavyDelete(txId, hd);
          return finish(DbResult.success(
            message: 'Deferred heavy delete recorded in transaction',
          ));
        }
        // Concurrency check for heavy operations (global throttling of processTablePartitions)
        if (_heavyDeleteOperationsInProgress >=
            _maxConcurrentPartitionMaintenances) {
          final completer = Completer<void>();
          _heavyDeleteQueue.add(completer);
          Logger.info(
              'Heavy delete operation for table $tableName queued due to concurrency limit.',
              label: 'DataStore-delete');
          await completer.future;
        }
        _heavyDeleteOperationsInProgress++;
        try {
          Logger.info(
              'Table $tableName has a large number of records and a complex deletion condition. A multi-batch deletion process will be used. Please wait.',
              label: 'DataStore-delete');

          // create counters
          int totalProcessed = 0;
          int deletedCount = checkpointDeletedSoFar ?? 0;
          // Collect deleted record keys
          final List<String> deletedKeys = [];
          const maxDeletedKeysToReturn = 100000;

          // Determine opId and start partition via checkpoint or create new
          final bool hasCheckpointOp =
              (checkpointOpId != null && checkpointOpId.isNotEmpty);
          final String largeDeleteOpId = hasCheckpointOp
              ? checkpointOpId
              : GlobalIdGenerator.generate('large_delete_');

          // Use checkpoint partition number if provided
          final int? startPartitionNo = checkpointStartPartitionNo;
          // If no checkpoint, start from the beginning (null = all partitions)

          try {
            // Only create a new WAL large delete entry when not resuming an existing op
            if (!hasCheckpointOp) {
              await walManager.beginLargeDelete(
                opId: largeDeleteOpId,
                table: tableName,
                condition: condition.build(),
                orderBy: orderBy,
                limit: limit,
                offset: offset,
                startPartitionNo: startPartitionNo,
              );
            }
          } catch (_) {}

          // Determine the batch size threshold based on record cache size, with a 200MB default.
          final effectiveRecordCacheSize =
              memoryManager?.getRecordCacheSize() ?? 200 * 1024 * 1024;
          final maxBatchMemorySizeInBytes = effectiveRecordCacheSize * 0.2;

          // Calculate max partitions in a batch based on memory limits and max partition file size.
          // This avoids per-record size calculation and provides a stable batch size.
          final maxPartitionsInBatch = (config.maxPartitionFileSize > 0
                  ? (maxBatchMemorySizeInBytes / config.maxPartitionFileSize)
                  : 10)
              .ceil()
              .clamp(1,
                  100); // Clamp to a reasonable range to avoid excessive memory usage

          final recordsInBatch = <Map<String, dynamic>>[];
          final partitionsInBatch = <int>[];

          Future<void> flushIndexDeleteBatch() async {
            if (_indexManager == null || recordsInBatch.isEmpty) return;
            await _indexManager!.writeChanges(
              tableName: tableName,
              deletes: recordsInBatch,
            );
          }

          // build a process function, to check if each partition's record matches the delete condition
          Future<List<Map<String, dynamic>>> processFunction(
              records, partitionNo, controller) async {
            // record original count
            int originalCount = records.length;

            // Create a new list with all records (do not filter out)
            final resultRecords = List<Map<String, dynamic>>.from(records);

            // collect deleted records
            final deletedRecordsInPartition = <Map<String, dynamic>>[];

            // optimized: track if all non-deleted records have been deleted
            bool allDeleted = true;

            final yieldController =
                YieldController('DataStoreImpl._deleteInternal.process');
            // replace deleted records with _deleted_:true marker, instead of removing
            for (int i = 0; i < resultRecords.length; i++) {
              final record = resultRecords[i];

              // skip if already deleted record
              if (isDeletedRecord(record)) continue;

              final matches = matcher.matches(record);
              if (matches) {
                // Apply limit before processing the record for deletion
                if (limit != null && deletedCount >= limit) {
                  if (!controller.isStopped) {
                    controller.stop();
                  }
                  allDeleted = false;
                  continue; // Stop processing further matches in this partition
                }

                // CRITICAL: Process each record atomically - check RESTRICT and execute CASCADE immediately
                // This ensures data consistency: if cascade fails, the record deletion is also rolled back
                final pkValue = record[primaryKey];
                if (pkValue == null) {
                  // Skip records without primary key
                  continue;
                }

                // Phase 1: Check RESTRICT/NO ACTION constraints immediately
                if (_foreignKeyManager != null) {
                  try {
                    await _foreignKeyManager!.checkRestrictConstraintsForDelete(
                      tableName: tableName,
                      deletedPkValues: pkValue,
                    );
                  } catch (e) {
                    Logger.error(
                        'RESTRICT constraint check failed in heavy delete: $e',
                        label: 'DataStore.deleteInternal');
                    // Stop processing and propagate error to ensure transaction rollback
                    if (!controller.isStopped) {
                      controller.stop();
                    }
                    rethrow; // This will be caught by the outer try-catch
                  }

                  // Phase 2: Execute CASCADE operations immediately for this record
                  // CRITICAL: Execute cascade immediately, not in batch, to ensure atomicity
                  // If cascade fails, the record deletion should also fail (transaction rollback)
                  try {
                    await _foreignKeyManager!.handleCascadeDelete(
                      tableName: tableName,
                      deletedPkValues: pkValue,
                      skipRestrictCheck: true, // RESTRICT already checked above
                    );
                  } catch (e) {
                    Logger.error(
                        'Cascade delete failed in heavy delete for record: $e',
                        label: 'DataStore.deleteInternal');
                    // Stop processing and propagate error to ensure transaction rollback
                    if (!controller.isStopped) {
                      controller.stop();
                    }
                    rethrow; // This will be caught by the outer try-catch
                  }
                }

                // Phase 3: Only after RESTRICT check and CASCADE succeed, mark record for deletion
                deletedCount++; // Changed totalDeleted to deletedCount

                // add to deleted records list
                deletedRecordsInPartition.add(record);

                notificationManager.notify(ChangeEvent(
                  type: ChangeType.delete,
                  tableName: tableName,
                  oldRecord: record,
                ));

                // Transaction logging for rollback

                // get record primary key value as string
                final pkValueStr = pkValue.toString();
                // Add to deleted keys list (with limit)
                if (deletedKeys.length < maxDeletedKeysToReturn) {
                  deletedKeys.add(pkValueStr);
                }

                // remove from write queue (if exists)
                tableDataManager.removeRecordFromBuffer(tableName, pkValueStr);

                // replace with explicit delete marker instead of empty object, to prevent migration issues
                resultRecords[i] = {'_deleted_': true};
              } else {
                // has non-deleted records
                allDeleted = false;
              }
              await yieldController.maybeYield();
            }

            totalProcessed += originalCount;

            if (deletedRecordsInPartition.isNotEmpty) {
              recordsInBatch.addAll(deletedRecordsInPartition);
              partitionsInBatch.add(partitionNo);

              // Flush the batch when the number of partitions with deletions reaches the calculated threshold.
              if (partitionsInBatch.length >= maxPartitionsInBatch) {
                await tableDataManager.removeTableRecords(
                  tableName,
                  recordsInBatch
                      .map((r) => r[primaryKey]?.toString())
                      .where((k) => k != null)
                      .map((k) => k!)
                      .toList(),
                );
                await flushIndexDeleteBatch();

                recordsInBatch.clear();
                partitionsInBatch.clear();
              }

              // Optimized: if all records are deleted, return empty list, directly remove the partition, more efficient
              if (allDeleted) {
                return [];
              }
            }

            return resultRecords;
          }

          // use processTablePartitions to process all partitions (skip global maintenance lock; no journal)
          await tableDataManager.processTablePartitions(
            tableName: tableName,
            processFunction: processFunction,
            startPartitionNo: startPartitionNo,
            skipMaintenanceGlobalLock: true,
            largeDeleteOpId: largeDeleteOpId,
            onPartitionFlushed: (int partitionNo) async {
              try {
                await walManager.updateLargeDeleteCheckpoint(
                  opId: largeDeleteOpId,
                  lastProcessedPartitionNo: partitionNo,
                  deletedSoFar: deletedCount,
                );
              } catch (_) {}
            },
          );

          // Process any remaining records in the last batch
          if (recordsInBatch.isNotEmpty) {
            await tableDataManager.removeTableRecords(
                tableName,
                recordsInBatch
                    .map((r) => r[primaryKey]?.toString())
                    .where((k) => k != null)
                    .map((k) => k!)
                    .toList());
            await flushIndexDeleteBatch();
          }

          // Complete large delete tracking in WAL meta
          try {
            await walManager.completeLargeDelete(largeDeleteOpId);
          } catch (_) {}

          return finish(DbResult.success(
            successKeys: deletedKeys,
            message:
                'Successfully deleted $deletedCount records (processed $totalProcessed)',
          ));
        } finally {
          _heavyDeleteOperationsInProgress--;
          if (_heavyDeleteQueue.isNotEmpty) {
            _heavyDeleteQueue.removeFirst().complete();
          }
        }
      }
    } catch (e) {
      Logger.error('Delete failed: $e', label: 'DataStore-delete');
      if (isInTransactionWithRollback()) {
        rethrow;
      }
      return DbResult.error(
        type: ResultType.dbError,
        message: 'Delete failed: $e',
      );
    }
  }

  /// Resume pending large delete operations recorded in WAL by delegating to deleteInternal with checkpoints.
  Future<void> _resumePendingLargeDeletes() async {
    try {
      final pendingLargeDeletes = walManager.meta.largeDeletes.values.toList();
      for (final m in pendingLargeDeletes) {
        if (m.status == 'completed') continue;
        try {
          await deleteInternal(
            m.table,
            QueryCondition.fromMap(m.condition),
            orderBy: m.orderBy,
            limit: m.limit,
            offset: m.offset,
            allowAll: false,
            checkpointStartPartitionNo: m.lastProcessedPartitionNo,
            checkpointDeletedSoFar: m.deletedSoFar,
            checkpointOpId: m.opId,
          );
        } catch (e) {
          Logger.warn('Resume large delete failed for ${m.opId}: $e',
              label: 'DataStore.resumeLargeDeletes');
        }
      }
    } catch (e) {
      Logger.error('Resume pending large deletes failed: $e',
          label: 'DataStore.resumeLargeDeletes');
    }
  }

  /// Resume pending large update operations recorded in WAL by delegating to updateInternal with checkpoints.
  Future<void> _resumePendingLargeUpdates() async {
    try {
      final pendingLargeUpdates = walManager.meta.largeUpdates.values.toList();
      for (final m in pendingLargeUpdates) {
        if (m.status == 'completed') continue;
        try {
          await updateInternal(
            m.table,
            m.updateData,
            QueryCondition.fromMap(m.condition),
            orderBy: m.orderBy,
            limit: m.limit,
            offset: m.offset,
            allowAll: false,
            checkpointStartPartitionNo: m.lastProcessedPartitionNo,
            checkpointUpdatedSoFar: m.updatedSoFar,
            checkpointOpId: m.opId,
          );
        } catch (e) {
          Logger.warn('Resume large update failed for ${m.opId}: $e',
              label: 'DataStore.resumeLargeUpdates');
        }
      }
    } catch (e) {
      Logger.error('Resume pending large updates failed: $e',
          label: 'DataStore.resumeLargeUpdates');
    }
  }

  /// Resume pending table-level maintenance operations (clear/drop) recorded in WAL meta.
  ///
  /// Only ops with [completed]==false are re-executed (physical op was registered
  /// but not finished before crash). Completed ops remain only for WAL cutoff
  /// semantics and must not be re-executed to avoid repeated clear on every restart.
  Future<void> _resumePendingTableOps() async {
    try {
      final ops = walManager.tableOps.values.toList();
      if (ops.isEmpty) return;
      for (final op in ops) {
        if (op.completed) {
          continue; // Already finished; only used for cutoff, do not re-execute
        }
        try {
          // 1) Re-execute the physical operation, but do not re-register WAL metadata
          if (op.type == 'clear') {
            final clearResult = await clear(op.table, registerWalOp: false);
            if (!clearResult.isSuccess) {
              Logger.error(
                'Failed to resume clear operation for table ${op.table}: ${clearResult.message}',
                label: 'DataStore._resumePendingTableOps',
              );
              // Continue with next operation even if this one failed
              continue;
            }
          } else if (op.type == 'drop') {
            final dropResult = await dropTable(
              op.table,
              isMigration: false,
              registerWalOp: false,
            );
            if (!dropResult.isSuccess) {
              Logger.error(
                'Failed to resume drop operation for table ${op.table}: ${dropResult.message}',
                label: 'DataStore._resumePendingTableOps',
              );
              // Continue with next operation even if this one failed
              continue;
            }
          }

          // 2) Try to mark the operation as completed after successful completion
          try {
            await walManager.completeTableOp(op.opId);
          } catch (e) {
            Logger.warn(
              'Complete resumed table operation failed for ${op.opId}: $e',
              label: 'DataStore.resumeTableOps',
            );
          }
        } catch (e) {
          Logger.warn(
            'Resume table operation failed for ${op.opId} (${op.type} ${op.table}): $e',
            label: 'DataStore.resumeTableOps',
          );
        }
      }
    } catch (e) {
      Logger.error(
        'Resume pending table operations failed: $e',
        label: 'DataStore.resumeTableOps',
      );
    }
  }

  /// Run a transactional scope. All operations inside are logged to a dedicated
  /// transaction log for potential rollback. If the callback throws, changes are
  /// compensated using the recorded before-images. On success, the transaction is
  /// marked committed and its files cleaned up.
  Future<TransactionResult> transaction<T>(FutureOr<T> Function() action,
      {bool rollbackOnError = true,
      bool? persistRecoveryOnCommit,
      TransactionIsolationLevel? isolation}) async {
    await ensureInitialized();
    final txId = await transactionManager!.beginTransaction();
    final started = DateTime.now();
    bool logFlushed = false;
    try {
      final result = await runZoned(() async {
        final Duration timeout = config.transactionTimeout;
        Future<void> doWork() async {
          try {
            await Future.sync(action);
            // If SSI, check conflicts before applying commit
            if ((isolation ?? config.defaultTransactionIsolationLevel) ==
                TransactionIsolationLevel.serializable) {
              final readKeys = TransactionContext.getReadKeys();
              final conflicts = await transactionManager!
                  .checkSerializableConflictsTransactional(
                      readKeys, started, txId);
              if (conflicts.isNotEmpty) {
                throw StateError(
                    'Serializable conflict on: ${conflicts.take(5).join(', ')}');
              }
            }
            // Build and persist commit plan (inserts/updates/deletes), then apply
            final plan = await transactionManager!.buildCommitPlan(txId);
            await transactionManager!.persistCommitPlan(plan);
            // Promote tx changes before marking commit
            // Set applying-commit flag to bypass deferral
            await runZoned(() async {
              await transactionManager!.applyCommitPlan(plan);
            }, zoneValues: {TransactionContext.applyingCommitKey: true});
            await transactionManager!
                .commit(txId, persistRecovery: persistRecoveryOnCommit);
            final bool effective =
                persistRecoveryOnCommit ?? config.persistRecoveryOnCommit;
            logFlushed = effective;
          } finally {
            // Release any row locks acquired in this transaction zone
            try {
              final locks = TransactionContext.getExclusiveLocks();
              if (locks.isNotEmpty) {
                for (final e in locks.entries) {
                  try {
                    lockManager?.releaseExclusiveLock(e.key, e.value);
                  } catch (_) {}
                }
                locks.clear();
              }
            } catch (_) {}
          }
        }

        if (timeout.inMilliseconds > 0) {
          await doWork().timeout(
            timeout,
            onTimeout: () {
              throw TimeoutException(
                  'Transaction timed out after ${timeout.inMilliseconds} ms');
            },
          );
        } else {
          await doWork();
        }

        final finished = DateTime.now();
        return TransactionResult.success(
          txId: txId,
          startedAt: started,
          finishedAt: finished,
          logFlushed: logFlushed,
        );
      }, zoneValues: {
        _txnZoneKey: txId,
        _txnRollbackOnErrorKey: rollbackOnError,
        // track touched paths during this transaction
        TransactionContext.touchedPathsKey: <String>{},
        TransactionContext.currentTxIdKey: txId,
        TransactionContext.isolationLevelKey:
            isolation ?? config.defaultTransactionIsolationLevel,
        TransactionContext.acquiredExclusiveLocksKey: <String, String>{},
        TransactionContext.readKeysKey: <String, Set<String>>{},
      });
      return result;
    } catch (e, stack) {
      // Rollback on any error
      try {
        await tableDataManager.applyTransactionRollback(txId);
        await transactionManager!.rollback(txId);
      } catch (_) {}

      // Best-effort: release any row locks retrieved from zone (if available)
      try {
        final locks = TransactionContext.getExclusiveLocks();
        if (locks.isNotEmpty) {
          for (final e in locks.entries) {
            try {
              lockManager?.releaseExclusiveLock(e.key, e.value);
            } catch (_) {}
          }
          locks.clear();
        }
      } catch (_) {}

      final finished = DateTime.now();
      // If SSI is enabled, we could signal retry advice here (future work)
      return TransactionResult.failed(
        txId: txId,
        startedAt: started,
        finishedAt: finished,
        error: TransactionError(
          type: _classifyTransactionErrorOrUnknown(e),
          message: e.toString(),
          cause: e,
          stackTrace: stack.toString(),
        ),
      );
    }
  }

  TransactionErrorType _classifyTransactionErrorOrUnknown(Object e) {
    final msg = e.toString().toLowerCase();
    if (msg.contains('timeout')) return TransactionErrorType.timeout;
    if (msg.contains('io') || msg.contains('filesystem')) {
      return TransactionErrorType.io;
    }
    if (msg.contains('unique') ||
        msg.contains('constraint') ||
        msg.contains('integrity')) {
      return TransactionErrorType.integrityViolation;
    }
    if (msg.contains('lock')) return TransactionErrorType.conflict;
    return TransactionErrorType.unknown;
  }

  /// drop table
  /// Returns [DbResult] to allow graceful error handling for business logic errors
  /// [isMigration] is true when dropping space table during migration,
  Future<DbResult> dropTable(
    String tableName, {
    bool isMigration = false,
    bool registerWalOp = true,
  }) async {
    DbResult finish(DbResult r) =>
        _returnOrThrowIfTxn(r, 'dropTable', tableName);

    try {
      if (registerWalOp) {
        await ensureInitialized();
      }

      // Check if table exists
      final schema = await schemaManager?.getTableSchema(tableName);
      if (schema == null) {
        return finish(DbResult.error(
          type: ResultType.notFound,
          message: 'Table $tableName does not exist',
        ));
      }
      String? dropOpId;
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

        return finish(DbResult.success(
          message:
              'Table $tableName data deleted in space $_currentSpaceName during migration',
        ));
      } else {
        if (registerWalOp && config.enableJournal) {
          try {
            final cutoff = walManager.currentPointer;
            final opId = GlobalIdGenerator.generate('tbl_drop_');
            final op = TableOpMeta(
              opId: opId,
              table: tableName,
              type: 'drop',
              cutoff: cutoff,
              createdAt: DateTime.now().toIso8601String(),
            );
            await walManager.registerTableOp(op);
            dropOpId = opId;
          } catch (e) {
            Logger.warn('Register drop table op failed: $e',
                label: 'DataStore.dropTable');
          }
        }

        // Handle foreign key cascade operations before dropping the table
        // This ensures data consistency: child records are handled according to foreign key policies
        // Note: handleCascadeClear can be reused for dropTable since the logic is the same:
        // both operations remove all records from the parent table, requiring the same cascade handling
        if (_foreignKeyManager != null) {
          try {
            await _foreignKeyManager!.handleCascadeClear(tableName);
          } catch (e) {
            Logger.error('Cascade drop failed: $e',
                label: 'DataStore.dropTable');
            // Convert exception to DbResult for graceful error handling
            return finish(_normalizeCascadeError(e, 'drop'));
          }

          // Clean up system table entries for the dropped table
          // This removes both: records where this table references others,
          // and records where others reference this table
          await _foreignKeyManager!
              .cleanupSystemTableForDroppedTable(tableName);
        }

        // Clear table cache and other memory caches
        await _invalidateTableCaches(tableName);

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

        // Clear path cache
        _pathManager?.clearTableCache(tableName);

        if (registerWalOp) {
          // Add migration task to delete table data in each space
          await migrationManager?.addMigrationTask(tableName,
              [const MigrationOperation(type: MigrationType.dropTable)]);
        }

        // Same rationale as clear(): after the physical drop has completed,
        // try to mark the table-op as completed so that it can be removed
        // from WAL meta when its cutoff is not newer than checkpoint.
        if (registerWalOp && config.enableJournal && dropOpId != null) {
          try {
            await walManager.completeTableOp(dropOpId);
          } catch (e) {
            Logger.warn('Complete drop table op failed: $e',
                label: 'DataStore.dropTable');
          }
        }

        Logger.info('Table $tableName has been successfully deleted',
            label: 'DataStore.dropTable');
        return finish(DbResult.success(
          message: 'Table $tableName dropped successfully',
        ));
      }
    } catch (e) {
      Logger.error('Failed to delete table: $e', label: 'DataStore-dropTable');
      // Convert any unexpected exceptions to DbResult
      return finish(DbResult.error(
        type: ResultType.dbError,
        message: 'Failed to drop table $tableName: $e',
      ));
    }
  }

  /// get initial user-defined and system schemas
  List<TableSchema> getInitialSchemas() {
    final existingTableNames =
        _userSchemas.map((schema) => schema.name).toSet();

    // Add system tables FIRST (before user tables)
    // This ensures system tables (especially system_fk_references) are created/upgraded
    // before user tables that may have foreign keys, preventing failures when
    // updateSystemTableForTable is called during user table creation/migration.
    //
    // Critical for upgrade scenarios: when upgrading from old version without
    // system_fk_references table, user tables with foreign keys will try to update
    // the system table, which must exist first.
    final systemTables = <TableSchema>[];
    for (final systemTable in SystemTable.gettableSchemas) {
      if (!existingTableNames.contains(systemTable.name)) {
        systemTables.add(systemTable);
      }
    }

    // Return a new list instead of mutating _userSchemas which might be unmodifiable
    // and to avoid side effects
    return [...systemTables, ..._userSchemas];
  }

  /// check table exists
  Future<bool> tableExists(String tableName) async {
    try {
      if (schemaManager == null) {
        throw StateError('SchemaPartitionManager not initialized');
      }

      final schema = await schemaManager?.getTableSchema(tableName);
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

    // Capture transaction id once
    final String? txId = Zone.current[_txnZoneKey] as String?;

    TableSchema? schema;
    try {
      // 1. Get table schema and validate data
      schema = await schemaManager?.getTableSchema(tableName);
      if (schema == null || schema.name.isEmpty) {
        Logger.error('Table $tableName does not exist',
            label: 'DataStore.batchInsert');
        return DbResult.error(
          type: ResultType.notFound,
          message: 'Table $tableName does not exist',
        );
      }

      final TableSchema tableSchema = schema;
      final primaryKey = tableSchema.primaryKey;

      // Snapshot table meta once: avoids repeated meta reads in hot loops.
      final tableMeta = await tableDataManager.getTableMeta(tableName);
      // We can safely skip disk unique checks if there is no committed data.
      final bool hasCommittedData =
          tableMeta != null && tableMeta.totalRecords > 0;
      final bool skipDiskUniqueChecks = !hasCommittedData;

      // PK order validation optimization: compare against the last partition maxKey once.
      dynamic lastMaxKey = tableMeta?.maxAutoIncrementId;
      final pkMatcher =
          ValueMatcher.getMatcher(tableSchema.getPrimaryKeyMatcherType());
      final bool requireStrictPkOrder =
          switch (tableSchema.primaryKeyConfig.type) {
        PrimaryKeyType.sequential ||
        PrimaryKeyType.timestampBased ||
        PrimaryKeyType.datePrefixed ||
        PrimaryKeyType.shortCode =>
          true,
        _ => false,
      };
      if (lastMaxKey == null && requireStrictPkOrder && hasCommittedData) {
        try {
          final last =
              await tableTreePartitionManager.scanRecordsByPrimaryKeyRange(
            tableName: tableName,
            startKeyInclusive: Uint8List(0),
            endKeyExclusive: Uint8List(0),
            reverse: true,
            limit: 1,
          );
          if (last.isNotEmpty) lastMaxKey = last.first[primaryKey];
        } catch (_) {}
      }
      final bool needPkOrderCheck = requireStrictPkOrder && lastMaxKey != null;

      // FK validation is expensive; skip completely when table has no enabled FKs.
      final bool hasForeignKeys = _foreignKeyManager != null &&
          tableSchema.foreignKeys.any((fk) => fk.enabled);

      final recordsToProcess = List<Map<String, dynamic>>.from(records);
      final invalidRecords = <Map<String, dynamic>>[];
      final List<String> successKeys = [];
      final List<String> failedKeys = [];
      // Track records whose primary key was auto-generated in this batch
      final Set<Map<String, dynamic>> autoPkRecords = <Map<String, dynamic>>{};

      // Batch assign primary keys if needed, to improve performance.
      if (tableSchema.primaryKeyConfig.type != PrimaryKeyType.none) {
        final recordsNeedingPk =
            recordsToProcess.where((r) => r[primaryKey] == null).toList();

        if (recordsNeedingPk.isNotEmpty) {
          final newIds = await tableDataManager.getBatchIds(
              tableName, recordsNeedingPk.length);

          if (newIds.length != recordsNeedingPk.length) {
            // Primary key generation failed for some/all records.
            if (!allowPartialErrors) {
              // Fail the entire batch.
              final allKeys = records
                  .map((r) => r[primaryKey]?.toString())
                  .where((k) => k != null && k.isNotEmpty)
                  .map((k) => k!)
                  .toList();
              return DbResult.error(
                type: ResultType.dbError,
                message:
                    'Failed to generate enough primary keys for batch insert',
                failedKeys: allKeys,
              );
            } else {
              // Mark records that needed a key as invalid and remove them from processing.
              for (final record in recordsNeedingPk) {
                invalidRecords.add(record);
                // These records don't have a PK, so nothing to add to failedKeys yet.
              }
              recordsToProcess.removeWhere((r) => r[primaryKey] == null);
            }
          } else {
            // Key generation succeeded, assign keys and mark as auto-generated.
            for (var i = 0; i < recordsNeedingPk.length; i++) {
              final rec = recordsNeedingPk[i];
              rec[primaryKey] = newIds[i];
              autoPkRecords.add(rec);
            }
          }
        }
      }

      // If all records were filtered out due to PK generation failure and partial errors are allowed,
      // we can end early without starting a transaction.
      if (recordsToProcess.isEmpty) {
        return DbResult.error(
          type: ResultType.dbError,
          message:
              'All ${invalidRecords.length} records failed during primary key generation.',
          // failedKeys is empty because these records never received a key.
        );
      }

      try {
        // Process records in batches to maintain memory efficiency
        // Use larger batches for throughput; YieldController keeps UI responsive.
        // For very large batches, cap to avoid excessive transient structures.
        final int batchSize = 20000;

        for (int start = 0;
            start < recordsToProcess.length;
            start += batchSize) {
          final int end = (start + batchSize < recordsToProcess.length)
              ? start + batchSize
              : recordsToProcess.length;

          final yieldController =
              YieldController('DataStoreImpl.batchInsert.loop');

          // Optimization: Create batch context to hoist table/buffer lookups out of the record loop
          final batchContext =
              writeBufferManager.createBatchCheckContext(tableName, txId);

          // Collect valid records for a single bulk enqueue into WAL + buffer + cache.
          final batchRecordsForBuffer = <Map<String, dynamic>>[];
          final batchUniqueRefsForBuffer = <List<UniqueKeyRef>>[];
          final batchOriginalById = <String, Map<String, dynamic>>{};

          Future<bool> flushBatch() async {
            if (batchRecordsForBuffer.isEmpty) return false;

            // Batch disk unique check (committed state only).
            // - Avoids per-record checkUniqueConstraints()
            // - Avoids searchIndex() for insert-only uniqueness
            if (!skipDiskUniqueChecks &&
                _indexManager != null &&
                batchRecordsForBuffer.isNotEmpty) {
              try {
                // The disk batch unique check can become expensive for very large batches
                // (e.g., 10w+ inserts) because it may need to locate many leaves.
                // When pressure is high, a large batch can fail transiently. For safety,
                // we retry with smaller chunks instead of failing the entire batch.
                Future<List<UniqueViolation?>> checkWithFallback(
                    List<Map<String, dynamic>> recs) async {
                  try {
                    return await _indexManager!
                        .checkUniqueConstraintsBatchForInsert(
                      tableName,
                      recs,
                      schemaOverride: tableSchema,
                    );
                  } catch (e) {
                    // Fallback: chunked validation to reduce peak memory/IO pressure.
                    // This keeps correctness (still checks committed data) while preventing
                    // "all failed" outcomes caused by transient overload.
                    Logger.warn(
                      'Batch unique disk check failed for ${recs.length} records, fallback to chunked checks: $e',
                      label: 'DataStore.batchInsert',
                    );
                    const int chunkSize = 512;
                    final out = List<UniqueViolation?>.filled(recs.length, null,
                        growable: false);
                    for (int off = 0; off < recs.length; off += chunkSize) {
                      await yieldController.maybeYield();
                      final int to = (off + chunkSize < recs.length)
                          ? off + chunkSize
                          : recs.length;
                      final sub = recs.sublist(off, to);
                      final subVios = await _indexManager!
                          .checkUniqueConstraintsBatchForInsert(
                        tableName,
                        sub,
                        schemaOverride: tableSchema,
                      );
                      for (int i = 0; i < subVios.length; i++) {
                        out[off + i] = subVios[i];
                      }
                    }
                    return out;
                  }
                }

                final vios = await checkWithFallback(batchRecordsForBuffer);

                if (vios.isNotEmpty) {
                  final keepRecords = <Map<String, dynamic>>[];
                  final keepRefs = <List<UniqueKeyRef>>[];
                  final keepOriginalById = <String, Map<String, dynamic>>{};
                  final filterYield =
                      YieldController('DataStore.batchInsert.flush.filter');

                  for (int i = 0; i < batchRecordsForBuffer.length; i++) {
                    await filterYield.maybeYield();
                    final vio = vios[i];
                    final rec = batchRecordsForBuffer[i];
                    final refs = batchUniqueRefsForBuffer[i];
                    final rid = rec[primaryKey]?.toString() ?? '';

                    if (vio == null) {
                      keepRecords.add(rec);
                      keepRefs.add(refs);
                      if (rid.isNotEmpty) {
                        keepOriginalById[rid] = batchOriginalById[rid] ?? rec;
                      }
                      continue;
                    }

                    // Conflict with committed data: drop this record.
                    if (rid.isNotEmpty) {
                      try {
                        writeBufferManager.releaseReservedUniqueKeys(
                          tableName: tableName,
                          recordId: rid,
                          transactionId: txId,
                        );
                      } catch (_) {}

                      final orig = batchOriginalById[rid];
                      if (orig != null) invalidRecords.add(orig);
                      failedKeys.add(rid);
                    }
                  }

                  batchRecordsForBuffer
                    ..clear()
                    ..addAll(keepRecords);
                  batchUniqueRefsForBuffer
                    ..clear()
                    ..addAll(keepRefs);
                  batchOriginalById
                    ..clear()
                    ..addAll(keepOriginalById);
                }
              } catch (e) {
                Logger.warn(
                  'Batch unique disk check failed: $e',
                  label: 'DataStore.batchInsert',
                );
                // Safety: if we cannot validate uniqueness reliably, treat as failure to avoid corruption.
                // We conservatively fail all pending records in this flush batch.
                final failYield =
                    YieldController('DataStore.batchInsert.flush.failAll');
                for (final rec in batchRecordsForBuffer) {
                  await failYield.maybeYield();
                  final rid = rec[primaryKey]?.toString() ?? '';
                  if (rid.isEmpty) continue;
                  try {
                    writeBufferManager.releaseReservedUniqueKeys(
                      tableName: tableName,
                      recordId: rid,
                      transactionId: txId,
                    );
                  } catch (_) {}
                  final orig = batchOriginalById[rid];
                  if (orig != null) invalidRecords.add(orig);
                  failedKeys.add(rid);
                }
                batchRecordsForBuffer.clear();
                batchUniqueRefsForBuffer.clear();
                batchOriginalById.clear();
              }
            }

            if (batchRecordsForBuffer.isEmpty) {
              return false;
            }

            final bufferResult = await tableDataManager.addInsertBatchToBuffer(
              tableName,
              batchRecordsForBuffer,
              schema: tableSchema,
              uniqueKeyRefsList: batchUniqueRefsForBuffer,
            );

            if (bufferResult.successRecordIds.isNotEmpty) {
              successKeys.addAll(bufferResult.successRecordIds);
            }

            bool hadFailures = false;
            if (bufferResult.failedRecordIds.isNotEmpty) {
              hadFailures = true;
              for (final failedId in bufferResult.failedRecordIds) {
                try {
                  writeBufferManager.releaseReservedUniqueKeys(
                    tableName: tableName,
                    recordId: failedId,
                    transactionId: txId,
                  );
                } catch (_) {}
                final orig = batchOriginalById[failedId];
                if (orig != null) invalidRecords.add(orig);
                if (failedId.isNotEmpty) failedKeys.add(failedId);
              }
            }

            batchRecordsForBuffer.clear();
            batchUniqueRefsForBuffer.clear();
            batchOriginalById.clear();

            return hadFailures;
          }

          for (int j = start; j < end; j++) {
            final record = recordsToProcess[j];
            await yieldController.maybeYield();

            final bool isAutoPk = autoPkRecords.contains(record);

            try {
              bool finishedRecord = false;
              bool triedPkConflictRetry = false;

              while (!finishedRecord) {
                // Validate and process data (may be re-run once if we correct PK)
                final validData = await _validateAndProcessData(
                  tableSchema,
                  record,
                  tableName,
                  skipPrimaryKeyOrderCheck: true,
                  skipPrimaryKeyFormatCheck: isAutoPk,
                );

                if (validData == null) {
                  invalidRecords.add(record);
                  final failedKey = record[primaryKey]?.toString() ?? '';
                  if (failedKey.isNotEmpty) {
                    failedKeys.add(failedKey);
                  }
                  finishedRecord = true;
                  break;
                }

                // PK order check (batch-optimized): compare against last committed maxKey.
                if (needPkOrderCheck) {
                  final dynamic pkVal = validData[primaryKey];
                  if (pkVal == null || pkMatcher(pkVal, lastMaxKey) <= 0) {
                    final bool isSequentialPk =
                        tableSchema.primaryKeyConfig.type ==
                            PrimaryKeyType.sequential;
                    if (isSequentialPk &&
                        isAutoPk &&
                        pkVal != null &&
                        !triedPkConflictRetry) {
                      try {
                        // Handle primary key conflict: recalculate from disk/buffer
                        await tableDataManager.handlePrimaryKeyConflict(
                            tableName, pkVal);

                        // CRITICAL: Also consider records already processed in the current flush batch
                        // to ensure the new ID stays ahead of everything currently in-flight.
                        dynamic maxInCurrentBatch;
                        for (final r in batchRecordsForBuffer) {
                          final val = r[primaryKey];
                          if (val != null) {
                            if (maxInCurrentBatch == null ||
                                pkMatcher(val, maxInCurrentBatch) > 0) {
                              maxInCurrentBatch = val;
                            }
                          }
                        }
                        if (maxInCurrentBatch != null) {
                          await tableDataManager.updateMaxIdInMemory(
                              tableName, maxInCurrentBatch);
                        }

                        // Update local lastMaxKey
                        final newMaxId =
                            tableDataManager.getMaxIdInMemory(tableName);
                        if (newMaxId != null) {
                          lastMaxKey = newMaxId;
                        }

                        // If this was an auto-generated PK, re-assign all subsequent auto-PKs in the batch
                        if (isAutoPk) {
                          final List<Map<String, dynamic>>
                              subsequentToReassign = [];
                          for (int k = j + 1;
                              k < recordsToProcess.length;
                              k++) {
                            if (autoPkRecords.contains(recordsToProcess[k])) {
                              subsequentToReassign.add(recordsToProcess[k]);
                            }
                          }

                          if (subsequentToReassign.isNotEmpty) {
                            final newIds = await tableDataManager.getBatchIds(
                                tableName, subsequentToReassign.length);
                            for (int k = 0;
                                k < subsequentToReassign.length;
                                k++) {
                              if (k < newIds.length) {
                                subsequentToReassign[k][primaryKey] = newIds[k];
                              }
                            }
                          }
                        } else {
                          // For user-provided PK, remove it so retry uses next auto ID
                          record.remove(primaryKey);
                        }
                      } catch (err) {
                        Logger.warn(
                            'Failed to auto-correct PK order violation in batch: $err',
                            label: 'DataStore.batchInsert');
                      }
                      record[primaryKey] = null;
                      triedPkConflictRetry = true;
                      continue;
                    }

                    invalidRecords.add(record);
                    final failedKey = pkVal?.toString() ?? '';
                    if (failedKey.isNotEmpty) {
                      failedKeys.add(failedKey);
                    }
                    finishedRecord = true;
                    break;
                  }
                }

                // Validate foreign key constraints (skip when table has no enabled FKs)
                if (hasForeignKeys) {
                  try {
                    await _foreignKeyManager!.validateForeignKeyConstraints(
                      tableName: tableName,
                      data: validData,
                      operation: ForeignKeyOperation.insert,
                    );
                  } catch (e) {
                    Logger.error(
                      'Foreign key constraint validation failed: $e',
                      label: 'DataStore.batchInsert',
                    );
                    invalidRecords.add(record);
                    final failedKey = validData[primaryKey]?.toString() ?? '';
                    if (failedKey.isNotEmpty) {
                      failedKeys.add(failedKey);
                    }
                    finishedRecord = true;
                    break;
                  }
                }

                // Plan unique locks + refs for atomic check+reserve
                final planIns =
                    planUniqueForInsert(tableName, tableSchema, validData);

                // Reservation based: try reserve unique keys first
                final recordId = validData[primaryKey].toString();
                try {
                  batchContext.tryReserve(recordId, planIns.refs);
                } catch (e) {
                  if (e is UniqueViolation) {
                    final bool isSequentialPk =
                        tableSchema.primaryKeyConfig.type ==
                            PrimaryKeyType.sequential;
                    if (isSequentialPk && !triedPkConflictRetry) {
                      try {
                        // Handle primary key conflict: recalculate from disk and buffer
                        final dynamic pkVal = validData[primaryKey];
                        await tableDataManager.handlePrimaryKeyConflict(
                            tableName, pkVal);

                        // CRITICAL: Also consider records already processed in the current flush batch
                        // (but not yet in WriteBufferManager) to ensure the corrected sequence
                        // stays ahead of everything currently in-flight.
                        dynamic maxInCurrentBatch;
                        for (final r in batchRecordsForBuffer) {
                          final val = r[primaryKey];
                          if (val != null) {
                            if (maxInCurrentBatch == null ||
                                pkMatcher(val, maxInCurrentBatch) > 0) {
                              maxInCurrentBatch = val;
                            }
                          }
                        }
                        if (maxInCurrentBatch != null) {
                          await tableDataManager.updateMaxIdInMemory(
                              tableName, maxInCurrentBatch);
                        }

                        // Update local lastMaxKey to stay consistent and avoid repeated order checks
                        final newMaxId =
                            tableDataManager.getMaxIdInMemory(tableName);
                        if (newMaxId != null) {
                          lastMaxKey = newMaxId;
                        }

                        // If this was an auto-generated PK, re-assign all subsequent auto-PKs in the batch
                        if (isAutoPk) {
                          final List<Map<String, dynamic>>
                              subsequentToReassign = [];
                          for (int k = j + 1;
                              k < recordsToProcess.length;
                              k++) {
                            if (autoPkRecords.contains(recordsToProcess[k])) {
                              subsequentToReassign.add(recordsToProcess[k]);
                            }
                          }

                          if (subsequentToReassign.isNotEmpty) {
                            final newIds = await tableDataManager.getBatchIds(
                                tableName, subsequentToReassign.length);
                            for (int k = 0;
                                k < subsequentToReassign.length;
                                k++) {
                              if (k < newIds.length) {
                                subsequentToReassign[k][primaryKey] = newIds[k];
                              }
                            }
                          }
                        } else {
                          // For user-provided PK, remove it so retry uses next auto ID
                          record.remove(primaryKey);
                        }
                      } catch (err) {
                        Logger.warn(
                            'Failed to auto-correct PK conflict in batch: $err',
                            label: 'DataStore.batchInsert');
                      }
                      record[primaryKey] = null;
                      triedPkConflictRetry = true;
                      continue;
                    }

                    invalidRecords.add(record);
                    final failedKey = validData[primaryKey]?.toString() ?? '';
                    if (failedKey.isNotEmpty) {
                      failedKeys.add(failedKey);
                    }
                    if (!allowPartialErrors) {
                      // Flush pending successful records to avoid leaving reservations behind.
                      await flushBatch();
                      return DbResult.error(
                        type: ResultType.uniqueViolation,
                        message: e.message,
                        failedKeys: failedKeys,
                      );
                    }
                    finishedRecord = true;
                    break;
                  }
                  rethrow;
                }

                try {
                  batchRecordsForBuffer.add(validData);
                  batchUniqueRefsForBuffer.add(planIns.refs);
                  batchOriginalById[recordId] = record;

                  finishedRecord = true;
                } catch (e) {
                  // Release reservation on unexpected error
                  try {
                    writeBufferManager.releaseReservedUniqueKeys(
                      tableName: tableName,
                      recordId: recordId,
                      transactionId: txId,
                    );
                  } catch (_) {}
                  rethrow;
                }
              }
            } catch (e) {
              Logger.warn(
                'Error processing record: $e',
                label: 'DataStore.batchInsert',
              );
              invalidRecords.add(record);
              final failedKey = record[primaryKey]?.toString() ?? '';
              if (failedKey.isNotEmpty) {
                failedKeys.add(failedKey);
              }

              if (!allowPartialErrors) {
                // Flush pending successful records to avoid leaving reservations behind.
                await flushBatch();
                return DbResult.error(
                  type: ResultType.dbError,
                  message: 'Error processing record: $e',
                  failedKeys: failedKeys,
                );
              }
            }
          }

          final bool hadFlushFailures = await flushBatch();
          if (hadFlushFailures && !allowPartialErrors) {
            return DbResult.error(
              type: ResultType.dbError,
              message: 'Error processing record: WAL append failed',
              failedKeys: failedKeys,
            );
          }
        }

        // If no valid records and not allowing partial errors, return error
        if (successKeys.isEmpty) {
          return DbResult.error(
            type: ResultType.validationFailed,
            message: 'All data validation failed',
            failedKeys: failedKeys,
          );
        }

        // If not allowing partial errors and some records failed, return error
        if (!allowPartialErrors && invalidRecords.isNotEmpty) {
          return DbResult.error(
            type: ResultType.validationFailed,
            message:
                'Some records failed validation or have unique constraint conflicts',
            failedKeys: failedKeys,
          );
        }

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
                'Partial records inserted successfully, ${successKeys.length} successful, ${failedKeys.length} failed',
          );
        }
      } catch (e) {
        // Rollback transaction on error
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

  /// load data from specified path
  Future<void> loadDataToCache() async {
    // Priority 1: Preload foreign key system table cache first
    // This ensures the cache is loaded before user table caches consume memory,
    // preventing it from being evicted due to memory pressure
    if (_foreignKeyManager != null) {
      await _foreignKeyManager!.preloadCache();
    }

    // Priority 2: Load user table caches
    final bool? enablePrewarm = config.enablePrewarmCache;

    if (enablePrewarm == false) {
      return; // Explicitly disabled
    }
    _isGlobalPrewarming = true;

    _executePrewarm();
  }

  Future<void> _executePrewarm() async {
    try {
      // From schemaManager get all tables
      final allTables = await getTableNames();
      if (allTables.isEmpty) {
        return;
      }

      // Sort tables by weight
      final prioritizedTables = await _prioritizeTablesByWeight(allTables);

      final yieldController =
          YieldController('DataStoreImpl._executePrewarm', checkInterval: 1);

      // Prewarm threshold (MB to bytes)
      final thresholdBytes = (config.prewarmThresholdMB * 1024 * 1024).toInt();
      final threshold95Percent = ((thresholdBytes * 0.95).round()).toInt();
      int loadedSizeBytes = 0;

      // Load tables by weight order
      for (int i = 0; i < prioritizedTables.length; i++) {
        final tableName = prioritizedTables[i];
        try {
          // Check if 95% threshold is reached
          if (loadedSizeBytes >= threshold95Percent) {
            Logger.info(
              'Prewarm stopped at 95% threshold: ${loadedSizeBytes ~/ (1024 * 1024)}MB / ${config.prewarmThresholdMB}MB',
              label: 'DataStore._executePrewarm',
            );
            break;
          }

          // Check if table exists in current space
          final tableExistsInSpace = await tableExistsInCurrentSpace(tableName);
          if (!tableExistsInSpace) {
            continue;
          }

          // Yield control to the event loop to prevent UI freezing during a long prewarm process.
          await yieldController.maybeYield();
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
    } finally {
      _isGlobalPrewarming = false;
    }
  }

  /// Sort tables by weight (descending)
  Future<List<String>> _prioritizeTablesByWeight(List<String> allTables) async {
    if (_weightManager == null) {
      // Fallback to old priority logic if weight manager not available
      return await _prioritizeTables(allTables);
    }

    try {
      // Get sorted table list by weight
      final sortedTables = await _weightManager!.getSortedIdentifiers(
        WeightType.tableRecord,
        descending: true,
      );

      // Create weight mapping
      final weightMap = <String, int>{};
      for (int i = 0; i < sortedTables.length; i++) {
        weightMap[sortedTables[i]] =
            sortedTables.length - i; // Higher weight, larger sorting value
      }

      // Sort tables by weight
      final sorted = allTables.toList()
        ..sort((a, b) {
          final weightA = weightMap[a] ?? 0;
          final weightB = weightMap[b] ?? 0;
          if (weightA != weightB) {
            return weightB.compareTo(weightA); // Descending order
          }
          // If weights are the same, keep original order
          return allTables.indexOf(a).compareTo(allTables.indexOf(b));
        });

      return sorted;
    } catch (e) {
      Logger.warn(
        'Failed to prioritize tables by weight: $e, falling back to default priority',
        label: 'DataStore._prioritizeTablesByWeight',
      );
      return await _prioritizeTables(allTables);
    }
  }

  /// Sort tables by priority (legacy method)
  Future<List<String>> _prioritizeTables(List<String> allTables) async {
    // Priority groups: global tables, normal tables
    final globalTables = <String>[];
    final normalTables = <String>[];
    final yieldController = YieldController('DataStoreImpl._prioritizeTables');
    for (final tableName in allTables) {
      await yieldController.maybeYield();
      // Check if it's a global table
      final isGlobal = await schemaManager?.isTableGlobal(tableName) ?? false;
      if (isGlobal) {
        globalTables.add(tableName);
      } else {
        normalTables.add(tableName);
      }
    }

    // Combine priorities: global tables > normal tables
    return [...globalTables, ...normalTables];
  }

  /// query by id
  Future<Map<String, dynamic>?> queryById(String tableName, dynamic id) async {
    try {
      final schema = await schemaManager?.getTableSchema(tableName);
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
      final schema = await schemaManager?.getTableSchema(tableName);
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
    try {
      // Before switching space, first flush and stop the write queue and index update pipeline,
      // to avoid "old space data" being incorrectly flushed to new space path.
      await parallelJournalManager.drainAndStop();

      // Before switching space, first save weights for the current space
      if (_weightManager != null) {
        await _weightManager!.saveWeights(force: true);
      }
      // Now it is safe to switch the current space name
      _currentSpaceName = spaceName;

      // Update configuration
      if (_config != null) {
        _config = _config!.copyWith(spaceName: _currentSpaceName);
      }

      // Clear caches
      await cacheManager.onBasePathChanged();

      // Reinitialize database
      _isInitialized = false;
      _baseInitialized = false;
      await initialize();

      // Add new space to GlobalConfig
      final globalConfig = await getGlobalConfig();
      if (globalConfig != null &&
          !globalConfig.spaceNames.contains(spaceName)) {
        final updatedConfig = globalConfig.addSpace(spaceName);
        await saveGlobalConfig(updatedConfig);
      }

      Logger.info(
        'Switched space from [$oldSpaceName] to [$spaceName]',
        label: 'DataStoreImpl.switchSpace',
      );

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
  Future<void> saveAllCacheBeforeExit() async {
    try {
      if (!_isInitialized) return;

      // 1) Flush WAL queue and persist metadata to ensure durability.
      try {
        await walManager.flushQueueCompletely();
        await walManager.persistMeta(flush: true);
      } catch (e) {
        Logger.error('Flush WAL queue failed: $e',
            label: 'DataStoreImpl.saveAllCacheBeforeExit');
      }

      // 2) Flush all pending writes and index updates from the write queue.
      try {
        await parallelJournalManager.flushCompletely();
      } catch (e) {
        Logger.error('flushCompletely failed: $e',
            label: 'DataStoreImpl.saveAllCacheBeforeExit');
      }

      // 3) Persist runtime metadata (max IDs, table statistics) eagerly.
      try {
        await tableDataManager.persistRuntimeMetaIfNeeded(force: true);
      } catch (e) {
        Logger.error('Persist runtime metadata failed: $e',
            label: 'DataStoreImpl.saveAllCacheBeforeExit');
      }

      // Ensure buffered IO is flushed to disk
      try {
        await storage.flushAll(closeHandles: true);
      } catch (e) {
        Logger.warn('Flush buffered IO failed: $e',
            label: 'DataStoreImpl.saveAllCacheBeforeExit');
      }

      // 4) Save weights
      try {
        await weightManager?.saveWeights(force: true);
      } catch (e) {
        Logger.error('Save weights failed: $e',
            label: 'DataStoreImpl.saveAllCacheBeforeExit');
      }
    } catch (e) {
      Logger.error('Failed to save cache before exit: $e',
          label: 'DataStoreImpl.saveAllCacheBeforeExit');
      return;
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
  Future<DbResult> setValue(String key, dynamic value,
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
        return result;
      } else {
        // Build update condition
        final condition = QueryCondition()..where('key', '=', key);
        final result = await updateInternal(
          tableName,
          data,
          condition,
        );
        return result;
      }
    } catch (e) {
      Logger.error('Set key-value pair failed: $e',
          label: 'DataStore.setValue');
      return DbResult.error(
        type: ResultType.dbError,
        message: 'Set key-value pair failed: $e',
        failedKeys: [key],
      );
    }
  }

  /// Get key-value pair
  Future<dynamic> getValue(String key, {bool isGlobal = false}) async {
    await ensureInitialized();

    final tableName = SystemTable.getKeyValueName(isGlobal);
    final result =
        await executeQuery(tableName, QueryCondition()..where('key', '=', key));
    if (result.isEmpty) {
      return null;
    }

    final rawValue = result.first['value'];
    if (rawValue == null) {
      return null;
    }

    try {
      // Try to parse as JSON first
      return jsonDecode(rawValue);
    } catch (e) {
      // If it fails, it's likely a plain string that was stored directly, not as JSON.
      // We return the raw string value for backward compatibility.
      Logger.warn(
          'Failed to parse value for key "$key" as JSON. Returning raw value. This may indicate that the value was not set using `setValue`. Error: $e',
          label: 'DataStore.getValue');
      return rawValue;
    }
  }

  /// Remove key-value pair
  Future<DbResult> removeValue(String key, {bool isGlobal = false}) async {
    await ensureInitialized();

    final tableName = SystemTable.getKeyValueName(isGlobal);
    // Build delete condition
    final condition = QueryCondition()..where('key', '=', key);
    return await deleteInternal(tableName, condition);
  }

  /// Get table info
  Future<TableInfo?> getTableInfo(String tableName) async {
    await ensureInitialized();
    final schema = await schemaManager?.getTableSchema(tableName);
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
    final totalRecords = await tableDataManager.getTableRecordCount(tableName);
    final fileSize = await tableDataManager.getTableFileSize(tableName);
    return TableInfo(
      tableName: tableName,
      totalRecords: totalRecords,
      fileSizeInBytes: fileSize,
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
    final schema = await schemaManager?.getTableSchema(tableName);
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
    await schemaManager?.saveTableSchema(tableName, newSchema);
  }

  /// Drop field from table
  Future<void> removeField(
    String tableName,
    String fieldName,
  ) async {
    final schema = await schemaManager?.getTableSchema(tableName);
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
    await schemaManager?.saveTableSchema(tableName, newSchema);
  }

  /// Rename field
  Future<void> renameField(
    String tableName,
    String oldName,
    String newName,
  ) async {
    try {
      final schema = await schemaManager?.getTableSchema(tableName);
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
      await schemaManager?.saveTableSchema(tableName, newSchema);
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
      final schema = await schemaManager?.getTableSchema(tableName);
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
      await schemaManager?.saveTableSchema(tableName, newSchema);
    } catch (e) {
      Logger.error(
        'Failed to modify field: $e',
        label: 'DataStoreImpl.modifyField',
      );
      rethrow;
    }
  }

  /// Invalidate all caches for table
  Future<void> _invalidateTableCaches(String tableName) async {
    await cacheManager.invalidateCache(tableName);
    await tableDataManager.removeTable(tableName);
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
        path.dirname(configPath),
      );

      // Serialize and save
      final content = jsonEncode(config.toJson());
      await storage.writeAsString(configPath, content);
    } catch (e) {
      Logger.error('Failed to save global config: $e',
          label: 'DataStoreImpl.saveGlobalConfig');
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
      final schema = await schemaManager?.getTableSchema(tableName);
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
        await schemaManager?.saveTableSchema(tableName, newSchema);

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
      final fileMeta = await tableDataManager.getTableMeta(tableName);
      if (fileMeta == null || fileMeta.totalRecords <= 0) {
        return true; // New table, no need to check ordering
      }

      // Compare new ID with maximum ID
      final schema = await schemaManager?.getTableSchema(tableName);
      if (schema == null) {
        return true; // Should not happen
      }
      final pkMatcher =
          ValueMatcher.getMatcher(schema.getPrimaryKeyMatcherType());

      // Convert newId to the correct type before comparison.
      final pkFieldSchema = FieldSchema(
          name: schema.primaryKey,
          type: schema.primaryKeyConfig.getDefaultDataType());
      final convertedNewId = pkFieldSchema.convertValue(newId);
      if (convertedNewId == null) {
        return true; // Cannot compare, assume valid to be safe.
      }

      // Prefer maxAutoIncrementId (cheap) and fall back to reading the max key from the global leaf tail.
      dynamic lastMax = fileMeta.maxAutoIncrementId;
      if (lastMax == null) {
        try {
          final last =
              await tableTreePartitionManager.scanRecordsByPrimaryKeyRange(
            tableName: tableName,
            startKeyInclusive: Uint8List(0),
            endKeyExclusive: Uint8List(0),
            reverse: true,
            limit: 1,
          );
          if (last.isNotEmpty) {
            lastMax = last.first[schema.primaryKey];
          }
        } catch (_) {}
      }
      if (lastMax == null) {
        return true; // Cannot determine maximum primary key value, skip check
      }
      final convertedLastMax = pkFieldSchema.convertValue(lastMax);
      if (convertedLastMax == null) return true;

      int compareResult = pkMatcher(convertedNewId, convertedLastMax);

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
  Future<SpaceInfo> getSpaceInfo({bool useCache = true}) async {
    try {
      // Get space configuration
      var config = await getSpaceConfig();
      // Get only user-created tables by using onlyUserTables=true
      final allTables =
          await schemaManager?.listAllTables(onlyUserTables: true) ?? [];

      // Check if statistics are stale (older than 1 hour) or if cache is disabled
      final currentTime = DateTime.now();
      final lastStatsTime = config?.lastStatisticsTime ?? DateTime(2000);
      final statsDuration = currentTime.difference(lastStatsTime);

      if (!useCache || statsDuration.inHours > 1) {
        // Schedule statistics recalculation and wait for it to complete
        await tableDataManager.recalculateAllStatistics();
        // Reload the space config from file to get the updated stats
        config = await getSpaceConfig();
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

  /// Delete a space
  /// Returns [DbResult] to allow graceful error handling for business logic errors
  /// [spaceName] Space name to delete
  Future<DbResult> deleteSpace(String spaceName) async {
    await ensureInitialized();

    if (spaceName == 'default') {
      Logger.warn(
        'Cannot delete the default space',
        label: 'DataStore.deleteSpace',
      );
      return DbResult.error(
        type: ResultType.validationFailed,
        message: 'Cannot delete the default space',
      );
    }

    if (spaceName == _currentSpaceName) {
      Logger.warn(
        'Cannot delete the currently active space. Please switch to another space before deleting.',
        label: 'DataStore.deleteSpace',
      );
      return DbResult.error(
        type: ResultType.validationFailed,
        message:
            'Cannot delete the currently active space. Please switch to another space before deleting.',
      );
    }

    try {
      final globalConfig = await getGlobalConfig();
      if (globalConfig == null ||
          !globalConfig.spaceNames.contains(spaceName)) {
        Logger.warn('Space $spaceName does not exist, no need to delete.',
            label: 'DataStore.deleteSpace');
        return DbResult.error(
          type: ResultType.notFound,
          message: 'Space $spaceName does not exist',
        );
      }

      // 1. Get the path for the space
      final spacePath = pathManager.getSpacePath();

      // 2. Delete the space directory
      if (await storage.existsDirectory(spacePath)) {
        await storage.deleteDirectory(spacePath);
      }

      // 3. Remove the space from GlobalConfig
      final updatedSpaces = Set<String>.from(globalConfig.spaceNames)
        ..remove(spaceName);
      final updatedConfig = globalConfig.copyWith(spaceNames: updatedSpaces);
      await saveGlobalConfig(updatedConfig);

      Logger.info('Space $spaceName has been successfully deleted.',
          label: 'DataStore.deleteSpace');
      return DbResult.success(
        message: 'Space $spaceName deleted successfully',
      );
    } catch (e) {
      Logger.error('Failed to delete space $spaceName: $e',
          label: 'DataStore.deleteSpace');
      // Convert any unexpected exceptions to DbResult
      return DbResult.error(
        type: ResultType.dbError,
        message: 'Failed to delete space $spaceName: $e',
      );
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
      final schema = await schemaManager?.getTableSchema(tableName);
      if (schema == null) {
        Logger.error('Failed to get schema for $tableName',
            label: 'DataStoreImpl.streamRecords');
        return;
      }

      final schemas = {tableName: schema};
      final matcher = condition != null
          ? ConditionRecordMatcher.prepare(condition, schemas, tableName)
          : null;

      // Stream all records from table using the existing tableDataManager method
      final recordStream = tableDataManager.streamRecords(tableName);

      try {
        await for (final record in recordStream) {
          // Apply filters if condition is provided
          if (matcher != null) {
            if (!matcher.matches(record)) {
              continue; // Skip non-matching records
            }
          }
          yield selectFields(record, selectedFields);
        }
      } catch (e) {
        Logger.error('Error streaming records: $e',
            label: 'DataStoreImpl.streamRecords');
        rethrow;
      }
    } catch (e) {
      Logger.error('Error streaming records: $e',
          label: 'DataStoreImpl.streamRecords');
      rethrow;
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

  /// Evaluates an expression AST using current record values.
  ///
  /// This method performs atomic expression evaluation with field name validation
  /// to prevent injection attacks. Only fields defined in the schema are accessible.
  ///
  /// [expression] - The expression AST to evaluate
  /// [record] - The current record containing field values
  /// [schema] - The table schema for field name validation
  ///
  /// Returns the computed numeric value.
  ///
  /// Throws [ArgumentError] if a field reference is invalid or field doesn't exist.
  dynamic _evaluateExpression(
    ExprNode expression,
    Map<String, dynamic> record,
    TableSchema schema,
  ) {
    // Build field name whitelist from schema for security validation
    final validFieldNames = <String>{
      ...schema.fields.map((f) => f.name),
      schema.primaryKey,
    };

    return _evaluateExprNode(expression, record, validFieldNames);
  }

  /// Recursively evaluates an expression node.
  ///
  /// This is the core evaluation engine that safely computes expression values
  /// while validating all field references against the whitelist.
  ///
  /// Returns num for numeric expressions, or String for timestamp expressions.
  dynamic _evaluateExprNode(
    ExprNode node,
    Map<String, dynamic> record,
    Set<String> validFieldNames,
  ) {
    if (node is TimestampExpr) {
      // Return ISO 8601 timestamp string
      return DateTime.now().toIso8601String();
    } else if (node is FieldRef) {
      // Validate field name against whitelist to prevent injection
      if (!validFieldNames.contains(node.fieldName)) {
        throw ArgumentError(
          'Invalid field reference: "${node.fieldName}". '
          'Field must exist in the table schema.',
        );
      }

      // Get field value from record, defaulting to 0 if null or not numeric
      final value = record[node.fieldName];
      if (value == null) {
        return 0;
      }
      if (value is num) {
        return value;
      }
      // Try to convert to number if possible
      if (value is String) {
        final parsed = num.tryParse(value);
        if (parsed != null) {
          return parsed;
        }
      }
      // If not convertible, treat as 0 for numeric operations
      Logger.warn(
        'Field "${node.fieldName}" has non-numeric value: $value. Treating as 0.',
        label: 'DataStore._evaluateExprNode',
      );
      return 0;
    } else if (node is Constant) {
      return node.value;
    } else if (node is BinaryOp) {
      final left = _evaluateExprNode(node.left, record, validFieldNames);
      final right = _evaluateExprNode(node.right, record, validFieldNames);

      switch (node.op) {
        case BinaryOperator.add:
          return left + right;
        case BinaryOperator.subtract:
          return left - right;
        case BinaryOperator.multiply:
          return left * right;
        case BinaryOperator.divide:
          if (right == 0) {
            Logger.warn(
              'Division by zero in expression. Returning 0.',
              label: 'DataStore._evaluateExprNode',
            );
            return 0;
          }
          return left / right;
        case BinaryOperator.modulo:
          if (right == 0) {
            Logger.warn(
              'Modulo by zero in expression. Returning 0.',
              label: 'DataStore._evaluateExprNode',
            );
            return 0;
          }
          return left % right;
        case BinaryOperator.min:
          return left < right ? left : right;
        case BinaryOperator.max:
          return left > right ? left : right;
      }
    } else if (node is UnaryOp) {
      final operand = _evaluateExprNode(node.operand, record, validFieldNames);

      switch (node.op) {
        case UnaryOperator.negate:
          return -operand;
        case UnaryOperator.abs:
          return operand.abs();
      }
    } else if (node is FunctionCall) {
      // Evaluate all arguments first
      final args = node.arguments
          .map((arg) => _evaluateExprNode(arg, record, validFieldNames))
          .toList();

      switch (node.functionName) {
        case 'min':
          if (args.length != 2) {
            throw ArgumentError('min() requires exactly 2 arguments');
          }
          return args[0] < args[1] ? args[0] : args[1];
        case 'max':
          if (args.length != 2) {
            throw ArgumentError('max() requires exactly 2 arguments');
          }
          return args[0] > args[1] ? args[0] : args[1];
        case 'round':
          if (args.length != 1) {
            throw ArgumentError('round() requires exactly 1 argument');
          }
          return args[0].round(); // returns int
        case 'floor':
          if (args.length != 1) {
            throw ArgumentError('floor() requires exactly 1 argument');
          }
          return args[0].floor(); // returns int
        case 'ceil':
          if (args.length != 1) {
            throw ArgumentError('ceil() requires exactly 1 argument');
          }
          return args[0].ceil(); // returns int
        case 'abs':
          if (args.length != 1) {
            throw ArgumentError('abs() requires exactly 1 argument');
          }
          return args[0].abs();
        default:
          throw ArgumentError(
            'Unknown function: ${node.functionName}. '
            'Supported functions: min, max, round, floor, ceil, abs.',
          );
      }
    } else {
      throw ArgumentError('Unknown expression node type: ${node.runtimeType}');
    }
  }
}

/// Implementation of the unified status API
class _DbStatusImpl implements DbStatus {
  final DataStoreImpl _db;

  _DbStatusImpl(this._db);

  @override
  Future<MemoryInfo> memory() async {
    if (_db._memoryManager == null) {
      // Return empty/default memory info if manager not initialized
      return const MemoryInfo(
        totalThresholdMB: 0,
        tableDataCacheUsage: 0,
        tableDataCacheLimit: 0,
        indexCacheUsage: 0,
        indexCacheLimit: 0,
        queryCacheUsage: 0,
        queryCacheLimit: 0,
        schemaCacheUsage: 0,
        schemaCacheLimit: 0,
        metaCacheUsage: 0,
        metaCacheLimit: 0,
        isLowMemoryMode: false,
      );
    }
    return await _db._memoryManager!.getMemoryInfo();
  }

  @override
  Future<SpaceInfo> space({bool useCache = true}) async {
    return await _db.getSpaceInfo(useCache: useCache);
  }

  @override
  Future<TableInfo?> table(String tableName) async {
    return await _db.getTableInfo(tableName);
  }

  @override
  Future<ConfigInfo> config() async {
    final encryptionType =
        _db.config.encryptionConfig?.encryptionType ?? EncryptionType.none;
    final userVersion = await _db.getVersion();

    return ConfigInfo(
      dbPath: _db._dbPath ?? 'default',
      dbName: _db._dbName ?? 'default',
      instancePath: _db.instancePath ?? '',
      currentSpaceName: _db.currentSpaceName,
      userVersion: userVersion,
      engineVersion: InternalConfig.engineVersion,
      isJournalEnabled: _db.config.enableJournal,
      encryptionType: encryptionType.name,
      isEncryptionEnabled: encryptionType != EncryptionType.none,
      cacheMemoryBudgetMB: _db.config.cacheMemoryBudgetMB ?? 0,
      isMemoryManaged: _db._memoryManager != null,
      maxParallelWorkers: _db.config.maxConcurrency,
      flushPolicy: StorageAdapter.flushPolicy.name,
    );
  }

  @override
  Future<MigrationStatus?> migration(String taskId) async {
    if (_db.migrationManager == null) {
      return null;
    }
    return await _db.migrationManager!.queryTaskStatus(taskId);
  }
}
