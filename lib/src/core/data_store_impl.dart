import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as path;

import '../Interface/kv_store.dart';
import '../Interface/noop_storage_impl.dart';
import '../Interface/status_provider.dart';
import '../handler/common.dart';
import '../handler/logger.dart';
import '../handler/parallel_processor.dart';
import '../handler/platform_handler.dart';
import '../handler/value_matcher.dart';
import '../model/backup_scope.dart';
import '../model/buffer_entry.dart';
import '../model/business_error.dart';
import '../model/change_event.dart';
import '../model/config_info.dart';
import '../model/data_store_config.dart';
import '../model/db_result.dart';
import '../model/expr.dart';
import '../model/foreign_key_operation.dart';
import '../model/global_config.dart';
import '../model/id_generator.dart';
import '../model/index_entry.dart';
import '../model/log_config.dart';
import '../model/memory_info.dart';
import '../model/migration_config.dart';
import '../model/migration_task.dart';
import '../model/ngh_index_meta.dart';
import '../model/query_result.dart';
import '../model/result_type.dart';
import '../model/space_config.dart';
import '../model/space_info.dart';
import '../model/system_table.dart';
import '../model/table_info.dart';
import '../model/table_op_meta.dart';
import '../model/table_schema.dart';
import '../model/transaction_models.dart';
import '../model/transaction_result.dart';
import '../model/unique_violation.dart';
import '../query/query_condition.dart';
import '../query/query_executor.dart';
import '../query/query_optimizer.dart';
import '../upgrades/old_structure_migration_handler.dart';
import '../upgrades/version_upgrade_manager.dart';
import 'backup_manager.dart';
import 'cache_manager.dart';
import 'compaction_manager.dart';
import 'crontab_manager.dart';
import 'directory_manager.dart';
import 'foreign_key_manager.dart';
import 'index_manager.dart';
import 'index_tree_partition_manager.dart';
import 'integrity_checker.dart';
import 'key_manager.dart';
import 'lock_manager.dart';
import 'migration_manager.dart';
import 'notification_manager.dart';

import 'overflow_manager.dart';
import 'parallel_journal_manager.dart';
import 'path_manager.dart';
import 'read_view_manager.dart';
import 'resource_manager.dart';
import 'schema_manager.dart';
import 'storage_adapter.dart';
import 'table_data_manager.dart';
import 'table_tree_partition_manager.dart';
import 'transaction_context.dart';
import 'transaction_manager.dart';
import 'ttl_cleanup_manager.dart';
import 'vector_index_manager.dart';
import 'wal_manager.dart';
import 'weight_manager.dart';
import 'workload_scheduler.dart';
import 'write_buffer_manager.dart';
import 'yield_controller.dart';

/// Core storage engine implementation
class DataStoreImpl {
  // Concurrency control for heavy delete operations
  static int _heavyDeleteOperationsInProgress = 0;
  static final _heavyDeleteQueue = Queue<Completer<void>>();

  // Concurrency control for heavy update operations
  static int _heavyUpdateOperationsInProgress = 0;
  static final _heavyUpdateQueue = Queue<Completer<void>>();

  static final Map<String, DataStoreImpl> _instances = {};

  // Internal reserved field for TTL ingest-time source (ISO8601 datetime string).
  static const String _systemIngestTsMsField = '_system_ingest_ts_ms';
  static const String _kvKeyField = SystemTable.keyValueKeyField;
  static const String _kvValueField = SystemTable.keyValueValueField;
  static const String _kvUpdatedAtField = SystemTable.keyValueUpdatedAtField;
  static const String _kvExpiresAtField = SystemTable.keyValueExpiresAtField;
  Completer<void> _initCompleter = Completer<void>();
  bool _isInitialized = false;
  bool _initializing = false;
  final String _instanceKey;
  final Future<void> Function(DataStoreImpl db)? _onConfigure;
  final Future<void> Function(DataStoreImpl db)? _onCreate;
  final Future<void> Function(DataStoreImpl db)? _onOpen;
  final List<TableSchema> _userSchemas;

  /// Get list of user schemas provided during initialization
  List<TableSchema> get userSchemas => _userSchemas;

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
  GlobalConfig? _globalConfigCache;

  String _currentSpaceName = 'default';
  DataStoreConfig? _config;

  IndexManager? _indexManager;
  VectorIndexManager? _vectorIndexManager;
  QueryOptimizer? _queryOptimizer;
  QueryExecutor? _queryExecutor;
  ForeignKeyManager? _foreignKeyManager;
  late CacheManager cacheManager;
  MigrationManager? migrationManager;
  VersionUpgradeManager? versionUpgradeManager;

  // Cached high pressure status to avoid redundant calculations in query paths.
  bool _isHighPressure = false;
  bool get isHighPressure => _isHighPressure;
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
  ResourceManager? _resourceManager;

  /// Key-value storage namespace
  late final KvStore kv = KvStore(this);

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
      if (_isInitialized) {
        throw StateError('TableDataManager not initialized');
      }
    }
    return _tableDataManager!;
  }

  // TTL cleanup manager
  late TtlCleanupManager _ttlCleanupManager;

  // WAL/write buffering/parallel journal managers
  // Not `final` so that they can be recreated on `initialize(reinitialize: true)`.
  late WalManager walManager;
  late WriteBufferManager writeBufferManager;
  late ParallelJournalManager parallelJournalManager;
  TableTreePartitionManager? tableTreePartitionManager;
  IndexTreePartitionManager? indexTreePartitionManager;

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

  /// Get vector index manager
  VectorIndexManager? get vectorIndexManager => _vectorIndexManager;

  /// Get resource manager
  ResourceManager? get resourceManager => _resourceManager;

  /// Check if the system is currently under low pressure, suitable for non-critical pre-warming tasks.
  bool isLowPressure() {
    if (!_isInitialized) return false;
    // Use cached pressure status (updated via WorkloadScheduler and ResourceManager callbacks)
    return !_isHighPressure;
  }

  void updatePressureStatus() {
    bool high = workloadScheduler.isHighPressure;

    // Check memory pressure (Cache Usage vs Threshold)
    if (!high && _resourceManager != null) {
      if (_resourceManager!.isLowMemoryMode) {
        high = true;
      } else {
        // Compare against the cached effective prewarm threshold.
        final usageMB = _resourceManager!.lastMeasuredTotalUsageMB;
        final thresholdMB = _resourceManager!.getEffectivePrewarmThresholdMB();
        if (usageMB >= thresholdMB) {
          high = true;
        }
      }
    }

    final bool oldHigh = _isHighPressure;
    _isHighPressure = high;

    // Reactive: If transitioning to high pressure, trigger an immediate resource check
    // to see if memory eviction is needed to relieve system stress.
    if (_isHighPressure && !oldHigh) {
      _resourceManager?.triggerImmediateCheck();
    }
  }

  /// TTL cache hooks for schema/cache managers.
  void upsertTtlPlanForSchema(TableSchema schema) {
    _ttlCleanupManager.upsertPlanForSchema(schema);
  }

  void removeTtlPlanForTable(String tableName) {
    _ttlCleanupManager.removePlanForTable(tableName);
  }

  void clearAllTtlPlanCache() {
    _ttlCleanupManager.invalidatePlanCache();
  }

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

    final applyActive = !isMigrationInstance;
    initialize(
            dbPath: dbPath,
            dbName: dbName,
            config: config,
            applyActiveSpaceOnDefault: applyActive)
        .then((_) {
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
    rootPath = path.canonicalize(rootPath);

    return pathJoin(rootPath, 'db', effectiveDbName);
  }

  /// Initialize storage engine
  /// [reinitialize]: when true, always close current instance
  /// [applyActiveSpaceOnDefault]: when true and spaceName is default, use stored activeSpace. Default false so that upgrade/reinit/switchSpace with default space are not overwritten; set true only for app first open when opening with default and wanting to use stored active space.
  Future<bool> initialize(
      {String? dbPath,
      String? dbName,
      DataStoreConfig? config,
      bool reinitialize = false,
      bool noPersistOnClose = false,
      bool applyActiveSpaceOnDefault = false}) async {
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
        await close(
            persistChanges: !noPersistOnClose,
            closeStorage: false,
            removeRegistry: false);
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

      final bool isMemoryMode =
          _config!.persistenceMode == PersistenceMode.memory;

      // Resolve the final database path (file mode only).
      // Memory mode must not touch filesystem.
      if (!isMemoryMode) {
        _instancePath = await getDatabasePath(dbPath: _dbPath, dbName: _dbName);
      } else {
        final n = _dbName ?? _config!.dbName;
        _instancePath = 'memory://$n';
      }

      _config =
          _config!.copyWith(dbPath: _dbPath, dbName: _dbName ?? config?.dbName);

      if (PlatformHandler.isWeb && _config!.enableJournal) {
        Logger.warn(
          'Web does not support enableJournal efficiently. Keeping it on can noticeably slow writes and startup. Recommended: set DataStoreConfig(enableJournal: false).',
          label: 'DataStore.initialize',
        );
      }

      // Initialize global workload scheduler using maxIoConcurrency as total token capacity.
      workloadScheduler =
          WorkloadScheduler(globalMax: _config!.maxIoConcurrency);
      workloadScheduler.onPressureChanged = updatePressureStatus;

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

      storage = isMemoryMode
          ? StorageAdapter.forStorage(const NoopStorageImpl())
          : StorageAdapter();
      lockManager = LockManager();

      // Configure storage runtime and flush policy based on DataStoreConfig
      await storage.configure(
        maxOpenHandles: _config!.maxOpenFiles,
        flushPolicy: _config!.recoveryFlushPolicy,
      );

      schemaManager = SchemaManager(this);
      _pathManager = PathManager(this);

      // Initialize resource manager
      _resourceManager = ResourceManager();

      // Create key manager instance but don't initialize yet
      _keyManager = KeyManager(this);

      transactionManager = TransactionManager(this);

      if (!isMemoryMode) {
        await Future.wait([
          getGlobalConfig(),
          getSpaceConfig(),
          _resourceManager!.initialize(_config!, this),
          Future(() async => await transactionManager!.initialize()),
        ]);
      } else {
        // In memory mode, pre-cache all known schemas so that SchemaManager
        // can serve getTableSchema() without touching storage.
        if (isMemoryMode) {
          for (final s in SystemTable.gettableSchemas) {
            schemaManager?.cacheTableSchema(s.name, s);
          }
          for (final s in _userSchemas) {
            schemaManager?.cacheTableSchema(s.name, s);
          }
        }
        await Future.wait([
          _resourceManager!.initialize(_config!, this),
          Future(() async => await transactionManager!.initialize()),
        ]);
      }

      // When opening with default space (first open only), use stored activeSpace so one open lands in the right space.
      // Memory mode does not persist global config, so skip.
      if (!isMemoryMode &&
          applyActiveSpaceOnDefault &&
          _config!.spaceName == 'default') {
        final globalConfig = await getGlobalConfig();
        final active = globalConfig?.activeSpace;
        if (active != null && active != 'default') {
          _config = _config!.copyWith(spaceName: active);
          _currentSpaceName = active;
          _spaceConfigCache = null;
          await getSpaceConfig(nowGetFromFile: true);
        }
      }

      directoryManager = DirectoryManager(this);
      _indexManager = IndexManager(this);
      _vectorIndexManager = VectorIndexManager(this);
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
      _ttlCleanupManager = TtlCleanupManager(this);

      cacheManager = CacheManager(this);
      notificationManager = NotificationManager([
        ...SystemTable.gettableSchemas,
        ..._userSchemas,
      ]);

      // Mark all operations from this point as system operations during initialization
      // This allows internal operations (like updating system tables, resuming pending ops)
      // to proceed even if _isInitialized is false, while external user operations must wait
      await TransactionContext.runAsSystemOperation(() async {
        if (!isMemoryMode) {
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
        }

        // Mark base initialization complete AFTER KeyManager is initialized
        _baseInitialized = true;
        if (!isMemoryMode) {
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
        }

        _isInitialized = true;

        if (!_initCompleter.isCompleted) {
          _initCompleter.complete();
        }

        if (!isMigrationInstance) {
          await loadDataToCache();
          CrontabManager.start();
          _ttlCleanupManager.registerCleanupTask();

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

  String? _resolveTtlSourceField(TableTtlConfig? ttl) {
    if (ttl == null) return null;
    final source = ttl.sourceField;
    if (source == null || source.isEmpty) {
      return _systemIngestTsMsField;
    }
    return source;
  }

  bool _isTtlConfigEquivalent(TableTtlConfig? a, TableTtlConfig? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    final aSource = (a.sourceField == null || a.sourceField!.isEmpty)
        ? null
        : a.sourceField;
    final bSource = (b.sourceField == null || b.sourceField!.isEmpty)
        ? null
        : b.sourceField;
    return a.ttlMs == b.ttlMs && aSource == bSource;
  }

  TableSchema _copySchemaWithTtlConfig(
      TableSchema schema, TableTtlConfig? ttlConfig) {
    return TableSchema(
      name: schema.name,
      primaryKeyConfig: schema.primaryKeyConfig,
      fields: schema.fields,
      indexes: schema.indexes,
      foreignKeys: schema.foreignKeys,
      isGlobal: schema.isGlobal,
      tableId: schema.tableId,
      ttlConfig: ttlConfig,
    );
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
        // When only system schema changed, use systemOnly: true so migrate() only manages
        // on-disk tables that are known system tables (SystemTable.isKnownSystemTable).
        // User tables are never touched even when userSchemas is empty (e.g. server-side
        // open() without schemas and runtime createTables()).
        final systemOnly = systemSchemaChanged && !userSchemaChanged;

        // Perform automatic table structure migration
        final migrationSchemas = getInitialSchemas(systemOnly: systemOnly);

        await autoSchemaMigrate(migrationSchemas, systemOnly: systemOnly);

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
  Future<void> autoSchemaMigrate(List<TableSchema> schemas,
      {bool systemOnly = false}) async {
    String backupPath = '';
    final migrationConfig = config.migrationConfig ?? const MigrationConfig();

    final reservedSystemTableNames = SystemTable.knownSystemTableNames;
    for (var schema in schemas) {
      if (!schema.validateTableSchema(
        reservedTableNames: reservedSystemTableNames,
        allowReservedTableNames: SystemTable.isKnownSystemTable(schema.name),
        allowInternalTableNamePrefix:
            SystemTable.isKnownSystemTable(schema.name),
        allowOtherInternalFields: SystemTable.isKnownSystemTable(schema.name),
      )) {
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
          systemOnly: systemOnly,
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

  Future<void> flush({bool flushStorage = true}) async {
    if (!_isInitialized) {
      await ensureInitialized();
    }
    await TransactionContext.runAsSystemOperation(() async {
      try {
        await parallelJournalManager.flushCompletely();
      } catch (_) {}
      try {
        await walManager.flushQueueCompletely();
      } catch (_) {}
      if (flushStorage) {
        try {
          await storage.flushAll();
        } catch (_) {}
      }
    });
  }

  /// Close database
  /// Close database
  /// [persistChanges]: when true, save buffers/caches to disk (default behavior).
  /// When false, DO NOT persist pending data; only flush OS handles and clear memory to avoid overwriting restore data.
  /// [closeStorage]: whether to close the underlying storage (IndexedDB etc.).
  /// Set [closeStorage] to false when performing operations like Restore that need
  /// to re-initialize the DataStore but keep the connection logic alive.
  /// [keepActiveSpace]: when false, clears [GlobalConfig.activeSpace] so next launch uses default (e.g. logout). Default true.
  Future<void> close({
    bool persistChanges = true,
    bool closeStorage = true,
    bool keepActiveSpace = true,
    bool removeRegistry = true,
  }) async {
    if (!_isInitialized && !_baseInitialized) return;

    // Immediately mark as uninitialized to block new operations
    _isInitialized = false;
    _baseInitialized = false;
    await Future.delayed(Duration.zero);

    try {
      // Stop background triggers first to prevent new work from entering pipelines
      _ttlCleanupManager.unregisterCleanupTask();
      compactionManager.dispose();

      // Perform all flushing and shutdown as system operation to bypass transaction locks
      await TransactionContext.runAsSystemOperation(() async {
        CrontabManager.dispose();
        if (persistChanges) {
          // Enter maintenance mode to wait for active transactions to finish
          try {
            await lockManager?.enterMaintenance(
                timeout: config.transactionTimeout);
          } catch (_) {}
        }

        // Flush and stop write pipelines
        try {
          if (persistChanges) {
            await parallelJournalManager.flushCompletely();
          }
          await parallelJournalManager.drainAndStop();
        } catch (e) {
          Logger.warn('Stop journal manager failed: $e',
              label: 'DataStoreImpl');
        }

        try {
          await walManager.flushQueueCompletely();
          if (persistChanges && config.enableJournal) {
            await walManager.persistMeta(flush: true);
          }
        } catch (e) {
          Logger.warn('Flush WAL failed: $e', label: 'DataStoreImpl');
        }

        // Flush weight data
        if (_weightManager != null) {
          if (persistChanges) {
            await _weightManager!.saveWeights(force: true);
          }
          _weightManager!.dispose();
        }

        // Persist and dispose data managers via CacheManager
        await cacheManager.dispose();

        // Final storage flush and close
        try {
          await storage.flushAll(closeHandles: true);
          if (closeStorage) {
            await storage.close(isMigrationInstance: isMigrationInstance);
          }
        } catch (e) {
          Logger.warn('Storage flush/close failed: $e', label: 'DataStoreImpl');
        }
      });

      // Clear active space if requested
      if (!keepActiveSpace) {
        try {
          final globalConfig = await getGlobalConfig();
          if (globalConfig != null && globalConfig.activeSpace != null) {
            await saveGlobalConfig(globalConfig.clearActiveSpace());
          }
        } catch (e) {
          Logger.error('Clear activeSpace on close failed: $e',
              label: 'DataStoreImpl.close');
        }
      }

      // Cleanup remaining non-storage managers and stop background tasks
      readViewManager.dispose();
      transactionManager?.dispose();
      notificationManager.dispose();
      _resourceManager?.dispose();

      _globalConfigCache = null;
      _spaceConfigCache = null;

      // Now that we have yielded and called dispose, it is safe to
      // nullify manager references for GC. This satisfies the requirement
      // for "Immediate destruction" on true close() while preventing crashes.
      if (closeStorage) {
        _indexManager = null;
        tableTreePartitionManager = null;
        indexTreePartitionManager = null;
        _vectorIndexManager = null;
        _tableDataManager = null;
        _queryOptimizer = null;
        _queryExecutor = null;
        _integrityChecker = null;
        _keyManager = null;
        _weightManager = null;
        directoryManager = null;
        schemaManager = null;
        transactionManager = null;
        _resourceManager = null;
        migrationManager = null;
        versionUpgradeManager = null;
        _foreignKeyManager = null;
      }

      if (removeRegistry) {
        lockManager = null;
      }
    } catch (e) {
      Logger.error('Database shutdown error: $e', label: 'DataStoreImpl.close');
      rethrow;
    } finally {
      _initializing = false;
      _baseInitialized = false;
      _isInitialized = false;
      _initCompleter = Completer<void>();

      // Only remove from factory cache if requested
      if (removeRegistry && _instances[_instanceKey] == this) {
        _instances.remove(_instanceKey);
      }

      if (removeRegistry || closeStorage) {
        Logger.info('Database instance has been closed: $_instanceKey',
            label: 'DataStoreImpl.close');
      }
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
        final reservedSystemTableNames = SystemTable.knownSystemTableNames;
        final bool isSystemTableName =
            SystemTable.isKnownSystemTable(schema.name);
        final bool allowSystemSchema =
            isSystemTableName && TransactionContext.isSystemOperation();
        if (!schemaValid.validateTableSchema(
          reservedTableNames: reservedSystemTableNames,
          allowReservedTableNames: allowSystemSchema,
          allowInternalTableNamePrefix: allowSystemSchema,
          allowOtherInternalFields: allowSystemSchema,
        )) {
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

        // Create B+Tree indexes (explicit, unique, and foreign key).
        // Vector indexes are managed by VectorIndexManager (lazy init on first write).
        final btreeIndexes =
            schemaManager?.getBtreeIndexesFor(schemaValid) ?? <IndexSchema>[];
        for (var index in btreeIndexes) {
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

    // Emergency Resource Check
    if (_resourceManager?.isWriteBlocked ?? false) {
      return DbResult.error(
        type: ResultType.resourceExhausted,
        message:
            'Insert operation blocked: System resources are critically low.',
      );
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

      final validationErrors = <String>[];
      validData = await _validateAndProcessData(
        schema,
        data,
        tableName,
        validationErrors: validationErrors,
      );
      if (validData == null) {
        final detailMsg = validationErrors.isNotEmpty
            ? 'Data validation failed for table $tableName: ${validationErrors.join("; ")}'
            : 'Data validation failed for table $tableName';
        return finish(DbResult.error(
          type: ResultType.validationFailed,
          message: detailMsg,
        ));
      }

      // 2. Plan unique locks + refs once; acquire locks then reuse refs for buffer
      final planIns = planUniqueForInsert(tableName, schema, validData);

      final recordId = validData[schema.primaryKey].toString();

      // 3. Reservation based: try reserve unique keys first to lock the buffer
      try {
        writeBufferManager.tryReserveUniqueKeys(
          tableName: tableName,
          recordId: recordId,
          uniqueKeys: planIns.refs,
          transactionId: txId,
        );
      } catch (e) {
        if (e is UniqueViolation) {
          final bool isPkConflict = e.indexName == 'pk';
          final bool isSequentialPk =
              schema.primaryKeyConfig.type == PrimaryKeyType.sequential;

          // Handle PK conflict: only auto-correct if the ID was generated by the system.
          // If the user provided a manual ID, we must respect it and return a violation.
          final bool userProvidedPk = data.containsKey(schema.primaryKey) &&
              data[schema.primaryKey] != null;

          if (isPkConflict && isSequentialPk && !userProvidedPk) {
            final providedId = validData[schema.primaryKey];
            if (providedId != null) {
              await tableDataManager.handlePrimaryKeyConflict(
                  tableName, providedId);
            }
            if (!retryOnPkConflict) {
              return await insert(tableName, data, retryOnPkConflict: true);
            }
          }

          return finish(DbResult.error(
            type: ResultType.uniqueViolation,
            message: e.message,
            failedKeys: [recordId],
          ));
        }
        rethrow;
      }

      // 4. Validate foreign key constraints after reservation
      final bool hasForeignKeys = _foreignKeyManager != null;
      if (hasForeignKeys) {
        try {
          await _foreignKeyManager!.validateForeignKeyConstraints(
            tableName: tableName,
            data: validData,
            operation: ForeignKeyOperation.insert,
          );
        } catch (e) {
          // Rollback reservation on FK failure
          try {
            writeBufferManager.releaseReservedUniqueKeys(
              tableName: tableName,
              recordId: recordId,
              transactionId: txId,
            );
          } catch (_) {}

          Logger.error('Foreign key constraint validation failed: $e',
              label: 'DataStore.insert');
          return finish(DbResult.error(
            type: ResultType.foreignKeyViolation,
            message: e.toString(),
          ));
        }
      }

      // 5. Unique check (disk only) - skip buffer check as we already reserved the keys
      final uniqueViolation = await _indexManager?.checkUniqueConstraints(
          tableName, validData,
          txId: txId, schemaOverride: schema, skipBufferCheck: true);

      if (uniqueViolation != null) {
        final bool isPkConflict = uniqueViolation.indexName == 'pk';
        final bool isSequentialPk =
            schema.primaryKeyConfig.type == PrimaryKeyType.sequential;

        // Handle PK conflict found on disk: only auto-correct if ID was NOT user-provided
        final bool userProvidedPk = data.containsKey(schema.primaryKey) &&
            data[schema.primaryKey] != null;

        if (isPkConflict && isSequentialPk && !userProvidedPk) {
          final providedId = validData[schema.primaryKey];
          if (providedId != null) {
            await tableDataManager.handlePrimaryKeyConflict(
                tableName, providedId);
          }
          if (!retryOnPkConflict) {
            // Rollback reservation before retrying
            try {
              writeBufferManager.releaseReservedUniqueKeys(
                tableName: tableName,
                recordId: recordId,
                transactionId: txId,
              );
            } catch (_) {}

            return await insert(tableName, data, retryOnPkConflict: true);
          }
        }

        // Rollback reservation on disk conflict
        try {
          writeBufferManager.releaseReservedUniqueKeys(
            tableName: tableName,
            recordId: recordId,
            transactionId: txId,
          );
        } catch (_) {}

        return finish(DbResult.error(
          type: ResultType.uniqueViolation,
          message: uniqueViolation.message,
          failedKeys: [recordId],
        ));
      }

      // 6. Rebuild record strictly following schema order (primary key first)
      final orderedValidData = <String, dynamic>{
        schema.primaryKey: validData[schema.primaryKey],
      };
      for (final field in schema.fields) {
        if (field.name == schema.primaryKey) {
          continue;
        }
        orderedValidData[field.name] = validData[field.name];
      }

      // 7. Add to write queue (insert operation) using planned refs (no extra parsing)
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
    TableSchema schema,
    Map<String, dynamic> data,
    String tableName, {
    bool skipPrimaryKeyFormatCheck = false,
    List<String>? validationErrors,
    Map<String, FieldSchema>? fieldMap,
  }) async {
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

      // 3. validate data using schema constraints and apply constraints if needed.
      // Values in [result] have already gone through FieldSchema.convertValue,
      // so we can safely skip the most expensive deep type checks here.
      final validatedResult = schema.validateData(
        result,
        applyConstraints: true,
        errors: validationErrors,
        trustedConvertedValues: true,
        fieldMap: fieldMap,
      );
      if (validatedResult == null) {
        Logger.warn(
          'Data validation failed for table $tableName',
          label: 'DataStore._validateAndProcessData',
        );
        return null;
      }

      return validatedResult;
    } catch (e) {
      Logger.error(
        'Data validation failed: $e',
        label: 'DataStore._validateAndProcessData',
      );
      // propagate a meaningful message to caller if a buffer is provided
      if (validationErrors != null) {
        if (e is BusinessError &&
            e.type == BusinessErrorType.invalidData &&
            e.message.isNotEmpty) {
          validationErrors.add(e.message);
        } else {
          validationErrors.add(e.toString());
        }
      }
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
      String tableName, TableSchema schema, Map<String, dynamic> data,
      {List<IndexSchema>? uniqueIndexes}) {
    final refs = <UniqueKeyRef>[];
    final pk = schema.primaryKey;
    final pkVal = data[pk];
    if (pkVal != null) {
      // Primary key uniqueness is enforced via table range partitions (no pk index).
      refs.add(UniqueKeyRef('pk', pkVal.toString()));
    }

    final allIndexes = uniqueIndexes ??
        schemaManager?.getUniqueIndexesFor(schema) ??
        <IndexSchema>[];
    for (final idx in allIndexes) {
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
    final allIndexes =
        schemaManager?.getUniqueIndexesFor(schema) ?? <IndexSchema>[];
    for (final idx in allIndexes) {
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

  /// Validate if a record contains enough information to identify it (pk or a complete unique index).
  /// If [checkRequiredFields] is true, also validates that all non-nullable fields are present.
  /// Returns null on valid, or error message.
  String? _validateRecordIdentifier(
    TableSchema schema,
    Map<String, dynamic> data,
    List<IndexSchema> uniqueIndexes, {
    bool checkRequiredFields = false,
  }) {
    final pk = schema.primaryKey;
    if (checkRequiredFields) {
      for (final f in schema.fields) {
        if (f.name == pk) continue;
        if (!f.nullable &&
            (!data.containsKey(f.name) || data[f.name] == null)) {
          return 'Field ${f.name} is required (nullable=false) for this operation';
        }
      }
    }

    final hasPk = data.containsKey(pk) && data[pk] != null;
    if (hasPk) return null;

    if (uniqueIndexes.isEmpty) {
      return 'Record has no primary key and table has no unique constraints; '
          'a unique identifier is required.';
    }

    bool hasValidUnique = false;
    for (final idx in uniqueIndexes) {
      if (idx.fields.every((f) =>
          data.containsKey(f) &&
          data[f] != null &&
          data[f].toString().trim().isNotEmpty)) {
        hasValidUnique = true;
        break;
      }
    }

    if (!hasValidUnique) {
      return 'Record has no primary key; provide all fields of at least one '
          'unique index: ${uniqueIndexes.map((i) => i.fields.join(",")).join(" or ")}';
    }
    return null;
  }

  /// Upsert one record: update-first by pk or unique key, then insert if not found.
  /// Returns [DbResult]. No where clause; conflict target from data (pk or first complete unique index).
  Future<DbResult> upsert(String tableName, Map<String, dynamic> data) async {
    DbResult finish(DbResult r) => _returnOrThrowIfTxn(r, 'upsert', tableName);
    await ensureInitialized();

    // Emergency Resource Check
    if (_resourceManager?.isWriteBlocked ?? false) {
      return DbResult.error(
        type: ResultType.resourceExhausted,
        message:
            'Upsert operation blocked: System resources are critically low.',
      );
    }

    final schema = await schemaManager?.getTableSchema(tableName);
    if (schema == null) {
      return finish(DbResult.error(
        type: ResultType.notFound,
        message: 'Table $tableName does not exist',
      ));
    }
    return await batchUpsert(tableName, [data]);
  }

  /// backup data and return backup path
  Future<String> backup(
      {bool compress = true,
      BackupScope scope = BackupScope.currentSpaceWithGlobal}) async {
    // In pure memory mode, backup has no persistence semantics.
    // Avoid creating fake paths or touching storage; just log and return empty.
    if (_config?.persistenceMode == PersistenceMode.memory) {
      Logger.warn(
        'Backup is not supported in memory persistence mode. '
        'This operation will be a no-op and return empty path.',
        label: 'DataStoreImpl.backup',
      );
      return '';
    }

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
    // In pure memory mode, there is nothing to restore from disk.
    if (_config?.persistenceMode == PersistenceMode.memory) {
      Logger.warn(
        'Restore is not supported in memory persistence mode. '
        'This operation will be a no-op and return false.',
        label: 'DataStoreImpl.restore',
      );
      return false;
    }

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

    // Emergency Resource Check
    if (_resourceManager?.isWriteBlocked ?? false) {
      return DbResult.error(
        type: ResultType.resourceExhausted,
        message:
            'update operation blocked: System resources are critically low.',
      );
    }

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
          _resourceManager?.getRecordCacheSize() ?? 200 * 1024 * 1024;

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
              final allIndexes =
                  schemaManager?.getUniqueIndexesFor(schema) ?? <IndexSchema>[];
              for (final index in allIndexes) {
                if (index.fields.length == 1) {
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
              resourceManager?.getRecordCacheSize() ?? 200 * 1024 * 1024;
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
          final Set<String> indexedFieldNames = <String>{primaryKey}..addAll(
              <IndexSchema>[
                ...?schemaManager?.getAllIndexesFor(schema),
                ...?indexManager?.getEngineManagedBtreeIndexes(
                  tableName,
                  schema,
                ),
              ].expand((i) => i.fields),
            );

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
            final allIndexes =
                schemaManager?.getUniqueIndexesFor(schema) ?? <IndexSchema>[];
            for (final index in allIndexes) {
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
                    try {
                      final result = _evaluateExpression(
                        proposed,
                        record,
                        schema,
                        isUpdate: true,
                      );
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
        final bool hasForeignKeys = _foreignKeyManager != null;
        if (hasForeignKeys) {
          final yieldController = YieldController('db_update_fk');
          for (final record in records) {
            await yieldController.maybeYield();
            // Merge existing record with update data
            final mergedData = Map<String, dynamic>.from(record);
            mergedData.addAll(validData);

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
        final allIndexes =
            schemaManager?.getUniqueIndexesFor(schema) ?? <IndexSchema>[];
        for (final index in allIndexes) {
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
              try {
                final result = _evaluateExpression(
                  proposed,
                  record,
                  schema,
                  isUpdate: true,
                );
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

            // 1. Try reserve unique keys first to lock the buffer
            try {
              oldUniqueKeys = writeBufferManager.tryReserveUniqueKeys(
                tableName: tableName,
                recordId: recordKey,
                uniqueKeys: planUpd.refs,
                transactionId: txId,
                isUpdate: true,
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

            // 2. Validate foreign key constraints after reservation
            if (hasForeignKeys && changedFields.isNotEmpty) {
              try {
                await _foreignKeyManager!.validateForeignKeyConstraints(
                  tableName: tableName,
                  data: updatedRecord,
                  operation: ForeignKeyOperation.update,
                );
              } catch (e) {
                // Rollback reservation on FK failure
                try {
                  writeBufferManager.releaseReservedUniqueKeys(
                    tableName: tableName,
                    recordId: recordKey,
                    transactionId: txId,
                    restoreKeys: oldUniqueKeys,
                  );
                } catch (_) {}

                Logger.error('Foreign key constraint validation failed: $e',
                    label: 'DataStore.updateInternal');
                if (continueOnPartialErrors) {
                  failedKeys.add(recordKey);
                  continue;
                }
                return finish(DbResult.error(
                  type: ResultType.foreignKeyViolation,
                  message: e.toString(),
                  failedKeys: [recordKey],
                ));
              }
            }

            // 3. Perform unique check (disk only) - skip buffer check as we already reserved the keys
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
              skipBufferCheck: true,
            );
            ok = uniqueViolation == null;

            if (!ok) {
              // Rollback reservation on disk conflict
              try {
                writeBufferManager.releaseReservedUniqueKeys(
                  tableName: tableName,
                  recordId: recordKey,
                  transactionId: txId,
                  restoreKeys: oldUniqueKeys,
                );
              } catch (_) {}
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
          final allIndexes = <IndexSchema>[
            ...?schemaManager?.getAllIndexesFor(schema),
            ...?indexManager?.getEngineManagedBtreeIndexes(
              tableName,
              schema,
            ),
          ];
          if (pkChanged) {
            // Primary key change affects all secondary indexes (non-unique: key suffix; unique: value).
            for (final idx in allIndexes) {
              indexFields.addAll(idx.fields);
            }
          } else {
            for (final idx in allIndexes) {
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
      if (e is BusinessError) {
        if (e.type == BusinessErrorType.notFound) {
          return finish(DbResult.error(
            type: ResultType.notFound,
            message: e.message,
          ));
        }
        if (e.type == BusinessErrorType.invalidData) {
          return finish(DbResult.error(
            type: ResultType.validationFailed,
            message: e.message,
          ));
        }
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

      // clear application layer cache
      // NOTE: clear() removes table data but keeps schema. Do not invalidate schema cache here,
      // especially in memory mode where schema may be in-memory only.
      await cacheManager.invalidateCache(tableName, invalidateSchema: false);

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

    // Emergency Resource Check
    if (_resourceManager?.isWriteBlocked ?? false) {
      return DbResult.error(
        type: ResultType.resourceExhausted,
        message:
            'Delete operation blocked: System resources are critically low.',
      );
    }

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
          resourceManager?.getRecordCacheSize() ?? 200 * 1024 * 1024;

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
              final allIndexes =
                  schemaManager?.getUniqueIndexesFor(schema) ?? <IndexSchema>[];
              for (final index in allIndexes) {
                if (index.fields.length == 1) {
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
              resourceManager?.getRecordCacheSize() ?? 200 * 1024 * 1024;
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
    if (e is TimeoutException) return TransactionErrorType.timeout;

    final businessClassification = _classifyBusinessTransactionError(e);
    if (businessClassification != null) {
      return businessClassification;
    }

    final msg = e.toString().toLowerCase();
    if (msg.contains('timeout')) return TransactionErrorType.timeout;
    if (_looksLikeIoFailure(e, msg)) {
      return TransactionErrorType.io;
    }
    if (msg.contains('unique') ||
        msg.contains('constraint') ||
        msg.contains('integrity')) {
      return TransactionErrorType.integrityViolation;
    }
    if (msg.contains('lock') || msg.contains('conflict')) {
      return TransactionErrorType.conflict;
    }
    return TransactionErrorType.unknown;
  }

  bool _looksLikeIoFailure(Object e, String msg) {
    final typeName = e.runtimeType.toString().toLowerCase();
    return typeName.contains('filesystemexception') ||
        typeName.contains('ioexception') ||
        typeName.contains('socketexception') ||
        msg.contains('filesystem') ||
        msg.contains('file system') ||
        msg.contains('io error') ||
        msg.contains('i/o') ||
        msg.contains('disk');
  }

  TransactionErrorType? _classifyBusinessTransactionError(Object e) {
    if (e is! BusinessError) return null;

    final resultType = _extractResultTypeFromBusinessError(e);
    if (resultType != null) {
      return _mapResultTypeToTransactionError(resultType);
    }

    switch (e.type) {
      case BusinessErrorType.duplicateKey:
      case BusinessErrorType.duplicateValue:
      case BusinessErrorType.uniqueError:
      case BusinessErrorType.primaryKeyError:
        return TransactionErrorType.integrityViolation;
      default:
        return TransactionErrorType.operationError;
    }
  }

  ResultType? _extractResultTypeFromBusinessError(BusinessError error) {
    final data = error.data;
    if (data is! Map) return null;

    final code = data['code'];
    if (code is! int) return null;

    return ResultType.fromCode(code);
  }

  TransactionErrorType _mapResultTypeToTransactionError(ResultType type) {
    switch (type) {
      case ResultType.uniqueViolation:
      case ResultType.primaryKeyViolation:
      case ResultType.foreignKeyViolation:
      case ResultType.notNullViolation:
        return TransactionErrorType.integrityViolation;
      case ResultType.timeout:
        return TransactionErrorType.timeout;
      case ResultType.ioError:
        return TransactionErrorType.io;
      case ResultType.success:
      case ResultType.partialSuccess:
      case ResultType.unknown:
      case ResultType.validationFailed:
      case ResultType.notFound:
      case ResultType.tableExists:
      case ResultType.fieldExists:
      case ResultType.indexExists:
      case ResultType.resourceExhausted:
      case ResultType.dbError:
        return TransactionErrorType.operationError;
    }
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
  List<TableSchema> getInitialSchemas({bool systemOnly = false}) {
    final existingTableNames =
        _userSchemas.map((schema) => schema.name).toSet();

    final tables = <TableSchema>[];

    for (final systemTable in SystemTable.gettableSchemas) {
      if (!existingTableNames.contains(systemTable.name)) {
        tables.add(systemTable);
      }
    }
    if (!systemOnly) {
      tables.addAll(_userSchemas);
    }

    // Return a new list instead of mutating _userSchemas which might be unmodifiable
    // and to avoid side effects
    return tables;
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

    // Emergency Resource Check
    if (_resourceManager?.isWriteBlocked ?? false) {
      return DbResult.error(
        type: ResultType.resourceExhausted,
        message:
            'Insert operation blocked: System resources are critically low.',
      );
    }

    if (records.isEmpty) {
      return DbResult.success(
        message: 'No records to insert',
        successKeys: [],
      );
    }

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
      // Cache unique indexes for this table once per batch to avoid repeated
      // schemaManager lookups inside the hot record loop.
      final uniqueIndexesForTable =
          schemaManager?.getUniqueIndexesFor(tableSchema) ?? <IndexSchema>[];
      // Whether table has secondary (non-PK) unique indexes.
      final bool hasSecondaryUniqueIndexes = uniqueIndexesForTable.isNotEmpty;
      // Build a single fieldName -> FieldSchema map per table for this batch and
      // reuse it across all records to avoid per-record reconstruction cost.
      final fieldMapForValidation = {
        for (final f in tableSchema.fields) f.name: f
      };

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
              await tableTreePartitionManager?.scanRecordsByPrimaryKeyRange(
            tableName: tableName,
            startKeyInclusive: Uint8List(0),
            endKeyExclusive: Uint8List(0),
            reverse: true,
            limit: 1,
          );
          if (last != null && last.isNotEmpty) {
            lastMaxKey = last.first[primaryKey];
          }
        } catch (_) {}
      }

      // FK validation is expensive; skip completely when table has no enabled FKs.
      final bool hasForeignKeys = _foreignKeyManager != null &&
          tableSchema.foreignKeys.any((fk) => fk.enabled);

      var recordsToProcess = List<Map<String, dynamic>>.from(records);
      final invalidRecords = <Map<String, dynamic>>[];
      final List<String> successKeys = [];
      final List<String> failedKeys = [];
      // Collect a limited number of detailed validation error messages for result reporting.
      // This is per-batch only and does not grow with table size, so it is safe for large-scale data.
      final List<String> validationErrorsForResult = [];
      // Track records whose primary key was auto-generated in this batch
      final Set<Map<String, dynamic>> autoPkRecords = <Map<String, dynamic>>{};
      // Track whether any record in this batch has a user-provided primary key.
      bool hasUserProvidedPrimaryKey = false;

      // Batch assign primary keys if needed, to improve performance.
      if (tableSchema.primaryKeyConfig.type != PrimaryKeyType.none) {
        final recordsNeedingPk = <Map<String, dynamic>>[];
        for (final r in recordsToProcess) {
          final pkVal = r[primaryKey];
          if (pkVal == null) {
            recordsNeedingPk.add(r);
          } else {
            hasUserProvidedPrimaryKey = true;
          }
        }

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

      // Disk unique checks are only needed when:
      // - the table has committed data to check against (skipDiskUniqueChecks is false),
      // - the table uses custom primary keys (type == none),
      // - the table defines secondary unique indexes, OR
      // - the user manually provided a primary key in this batch.
      final bool needDiskUniqueCheck = !skipDiskUniqueChecks &&
          _indexManager != null &&
          (tableSchema.primaryKeyConfig.type == PrimaryKeyType.none ||
              hasSecondaryUniqueIndexes ||
              hasUserProvidedPrimaryKey);

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
        // Process records in small batches to provide frequent "heartbeats" for
        final int batchSize = 1000;

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
            if (needDiskUniqueCheck && batchRecordsForBuffer.isNotEmpty) {
              try {
                // The disk batch unique check can become expensive for very large batches
                // (e.g., 10w+ inserts) because it may need to locate many leaves.
                // When pressure is high, a large batch can fail transiently. For safety,
                // we retry with smaller chunks instead of failing the entire batch.
                Future<List<UniqueViolation?>> checkWithFallback(
                    List<Map<String, dynamic>> recs) async {
                  try {
                    return await _indexManager!.checkUniqueConstraintsBatch(
                      tableName,
                      recs,
                      schemaOverride: tableSchema,
                      skipBufferCheck: true,
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
                      final subVios =
                          await _indexManager!.checkUniqueConstraintsBatch(
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
                      if (orig != null) {
                        invalidRecords.add(orig);
                        // Efficient error capture for reporting
                        if (validationErrorsForResult.length < 20) {
                          validationErrorsForResult
                              .add('pk=$rid: [Disk Conflict] ${vio.message}');
                        }
                      }
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

            final bufferResult = await tableDataManager.addBatchToBuffer(
              tableName: tableName,
              records: batchRecordsForBuffer,
              operation: BufferOperationType.insert,
              schema: tableSchema,
              uniqueKeyRefsList: batchUniqueRefsForBuffer,
              transactionId: txId,
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

          final recordErrors = <String>[];

          for (int j = start; j < end; j++) {
            final record = recordsToProcess[j];
            await yieldController.maybeYield();

            final bool isAutoPk = autoPkRecords.contains(record);

            try {
              bool finishedRecord = false;
              bool triedPkConflictRetry = false;

              while (!finishedRecord) {
                // Validate and process data (may be re-run once if we correct PK)
                recordErrors.clear();
                final validData = await _validateAndProcessData(
                  tableSchema,
                  record,
                  tableName,
                  skipPrimaryKeyFormatCheck: isAutoPk,
                  validationErrors: recordErrors,
                  fieldMap: fieldMapForValidation,
                );

                if (validData == null) {
                  invalidRecords.add(record);
                  final failedKey = record[primaryKey]?.toString() ?? '';
                  if (failedKey.isNotEmpty) {
                    failedKeys.add(failedKey);
                  }
                  if (recordErrors.isNotEmpty &&
                      validationErrorsForResult.length < 20) {
                    final prefix =
                        failedKey.isNotEmpty ? 'pk=$failedKey' : 'index=$j';
                    validationErrorsForResult
                        .add('$prefix: ${recordErrors.join("; ")}');
                  }
                  finishedRecord = true;
                  break;
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
                final planIns = planUniqueForInsert(
                  tableName,
                  tableSchema,
                  validData,
                  uniqueIndexes: uniqueIndexesForTable,
                );

                // Reservation based: try reserve unique keys first
                final recordId = validData[primaryKey].toString();
                try {
                  batchContext.tryReserve(recordId, planIns.refs);
                } catch (e) {
                  if (e is UniqueViolation) {
                    final bool isPkConflict = e.indexName == 'pk';
                    final bool isSequentialPk =
                        tableSchema.primaryKeyConfig.type ==
                            PrimaryKeyType.sequential;
                    // Only adjust maxId and retry when the conflict is on the primary key
                    // and the ID was originally generated by the system (Auto-ID).
                    // Manual IDs must result in a violation if they conflict.
                    if (isPkConflict &&
                        isSequentialPk &&
                        isAutoPk &&
                        !triedPkConflictRetry) {
                      try {
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
          String message = 'All data validation failed';
          if (validationErrorsForResult.isNotEmpty) {
            final preview = validationErrorsForResult.length > 5
                ? validationErrorsForResult.sublist(0, 5)
                : validationErrorsForResult;
            final suffix = validationErrorsForResult.length > preview.length
                ? ' (showing ${preview.length} of ${validationErrorsForResult.length} validation errors)'
                : '';
            message =
                '$message. Example validation errors: ${preview.join(" | ")}$suffix';
          }
          return DbResult.error(
            type: ResultType.validationFailed,
            message: message,
            failedKeys: failedKeys,
          );
        }

        // If not allowing partial errors and some records failed, return error
        if (!allowPartialErrors && invalidRecords.isNotEmpty) {
          String message =
              'Some records failed validation or have unique constraint conflicts';
          if (validationErrorsForResult.isNotEmpty) {
            final preview = validationErrorsForResult.length > 5
                ? validationErrorsForResult.sublist(0, 5)
                : validationErrorsForResult;
            final suffix = validationErrorsForResult.length > preview.length
                ? ' (showing ${preview.length} of ${validationErrorsForResult.length} validation errors)'
                : '';
            message =
                '$message. Example validation errors: ${preview.join(" | ")}$suffix';
          }
          return DbResult.error(
            type: ResultType.validationFailed,
            message: message,
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
          String message =
              'Partial records inserted successfully, ${successKeys.length} successful, ${failedKeys.length} failed';
          if (validationErrorsForResult.isNotEmpty) {
            final preview = validationErrorsForResult.length > 5
                ? validationErrorsForResult.sublist(0, 5)
                : validationErrorsForResult;
            final suffix = validationErrorsForResult.length > preview.length
                ? ' (showing ${preview.length} of ${validationErrorsForResult.length} validation errors)'
                : '';
            message =
                '$message. Example validation errors: ${preview.join(" | ")}$suffix';
          }
          return DbResult.batch(
            successKeys: successKeys,
            failedKeys: failedKeys,
            message: message,
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

  /// Batch upsert: each record must contain all non-nullable fields + pk or all fields
  /// of at least one unique index. No where support.
  /// Optimized to use batch index probing for high throughput.
  Future<DbResult> batchUpsert(
      String tableName, List<Map<String, dynamic>> records,
      {bool allowPartialErrors = true}) async {
    DbResult finish(DbResult r) =>
        _returnOrThrowIfTxn(r, 'batchUpsert', tableName);
    await ensureInitialized();

    if (_resourceManager?.isWriteBlocked ?? false) {
      return DbResult.error(
        type: ResultType.resourceExhausted,
        message:
            'upsert operation blocked: System resources are critically low.',
      );
    }

    if (records.isEmpty) {
      return DbResult.success(
        message: 'No records to insert',
        successKeys: [],
      );
    }

    final TableSchema? schema = await schemaManager?.getTableSchema(tableName);
    if (schema == null || schema.name.isEmpty) {
      return finish(DbResult.error(
        type: ResultType.notFound,
        message: 'Table $tableName does not exist',
      ));
    }

    final uniqueIndexes =
        schemaManager?.getUniqueIndexesFor(schema) ?? <IndexSchema>[];
    final pk = schema.primaryKey;
    final successKeys = <String>[];
    final failedKeys = <String>[];
    final validationYield = YieldController(
        'DataStoreImpl.batchUpsert.validate',
        checkInterval: 200);

    final validationErrorsForResult = <String>[];

    try {
      // 1. Bulk validation (O(N) CPU)
      final validatedRecords = <Map<String, dynamic>>[];
      for (int i = 0; i < records.length; i++) {
        final record = records[i];
        await validationYield.maybeYield();
        final err = _validateRecordIdentifier(schema, record, uniqueIndexes,
            checkRequiredFields: true);
        if (err != null) {
          final failedKey = record[pk]?.toString() ?? 'index=$i';
          failedKeys.add(record[pk]?.toString() ?? '');

          if (validationErrorsForResult.length < 10) {
            validationErrorsForResult.add('pk=$failedKey: $err');
          }
          Logger.warn('Upsert validation failed for $failedKey: $err',
              label: 'DataStore.batchUpsert');

          if (!allowPartialErrors) {
            return finish(DbResult.error(
              type: ResultType.validationFailed,
              message: err,
              failedKeys: failedKeys,
            ));
          }
        } else {
          validatedRecords.add(record);
        }
      }

      if (validatedRecords.isEmpty) {
        String message = 'All operations failed during validation';
        if (validationErrorsForResult.isNotEmpty) {
          message += '. Examples: ${validationErrorsForResult.join(" | ")}';
        }
        return finish(DbResult.batch(
          successKeys: successKeys,
          failedKeys: failedKeys,
          message: message,
        ));
      }

      // 2. Full-set probing existence via unique indexes
      // Processing the full set here is more efficient as it maximizes
      // IndexManager's internal optimization and Page Cache reuse.
      final violations = await indexManager!.checkUniqueConstraintsBatch(
        tableName,
        validatedRecords,
        schemaOverride: schema,
        resolveInPlace: true,
      );

      final toInsert = <Map<String, dynamic>>[];
      final toUpdate = <Map<String, dynamic>>[];
      for (int j = 0; j < validatedRecords.length; j++) {
        final record = validatedRecords[j];

        if (violations[j] == null) {
          toInsert.add(record);
        } else {
          toUpdate.add(record);
        }
      }

      // 3. Batch Update for existing records
      if (toUpdate.isNotEmpty) {
        final upResult = await batchUpdate(
          tableName,
          toUpdate,
          allowPartialErrors: allowPartialErrors,
        );
        if (upResult.isSuccess || allowPartialErrors) {
          successKeys.addAll(upResult.successKeys);
          failedKeys.addAll(upResult.failedKeys);
        } else {
          return finish(upResult);
        }
      }

      // 4. Final Batch Insert for new records
      if (toInsert.isNotEmpty) {
        final insResult = await batchInsert(
          tableName,
          toInsert,
          allowPartialErrors: allowPartialErrors,
        );
        successKeys.addAll(insResult.successKeys);
        failedKeys.addAll(insResult.failedKeys);
        if (!allowPartialErrors && !insResult.isSuccess) {
          return finish(insResult);
        }
      }

      String message = 'Batch upsert completed';
      if (failedKeys.isNotEmpty) {
        message =
            'Batch upsert partially successful: ${successKeys.length} success, ${failedKeys.length} failed';
        if (validationErrorsForResult.isNotEmpty) {
          message +=
              '. Validation errors: ${validationErrorsForResult.join(" | ")}';
        }
      }

      return finish(DbResult.batch(
        successKeys: successKeys,
        failedKeys: failedKeys,
        message: message,
      ));
    } catch (e) {
      Logger.error('Batch upsert failed: $e', label: 'DataStore.batchUpsert');
      return finish(DbResult.error(
        type: ResultType.dbError,
        message: 'Batch upsert failed: $e',
      ));
    }
  }

  /// batch update data based on primary keys or unique identifiers.
  Future<DbResult> batchUpdate(
      String tableName, List<Map<String, dynamic>> records,
      {bool allowPartialErrors = true}) async {
    DbResult finish(DbResult r) =>
        _returnOrThrowIfTxn(r, 'batchUpdate', tableName);
    await ensureInitialized();

    // Emergency Resource Check
    if (_resourceManager?.isWriteBlocked ?? false) {
      return DbResult.error(
        type: ResultType.resourceExhausted,
        message:
            'batch update operation blocked: System resources are critically low.',
      );
    }

    if (records.isEmpty) {
      return DbResult.success(
        message: 'No records to update',
        successKeys: [],
      );
    }

    final TableSchema? schema = await schemaManager?.getTableSchema(tableName);
    if (schema == null || schema.name.isEmpty) {
      return finish(DbResult.error(
        type: ResultType.notFound,
        message: 'Table $tableName does not exist',
      ));
    }

    final String? txId = Zone.current[_txnZoneKey] as String?;
    final primaryKey = schema.primaryKey;
    final allUniqueIndexes =
        schemaManager?.getUniqueIndexesFor(schema) ?? <IndexSchema>[];

    final successKeys = <String>[];
    final failedKeys = <String>[];

    final validationYield = YieldController(
        'DataStoreImpl.batchUpdate.validate',
        checkInterval: 200);

    // 1. Identification & Resolution Phase
    // Pre-process records to ensure every record has a primary key.
    // If a record only has a unique identifier, resolve its PK via IndexManager.
    final List<Map<String, dynamic>> withPk = [];
    final List<Map<String, dynamic>> needsResolution = [];

    for (int i = 0; i < records.length; i++) {
      await validationYield.maybeYield();
      final record = records[i];
      final pkVal = record[primaryKey]?.toString();

      if (pkVal != null && pkVal.isNotEmpty) {
        withPk.add(record);
      } else {
        // Missing PK, validate if it has enough info to resolve (at least one complete Unique Index)
        final err = _validateRecordIdentifier(schema, record, allUniqueIndexes);
        if (err != null) {
          failedKeys.add(pkVal ?? 'missing_identifier');
          if (!allowPartialErrors) {
            return finish(DbResult.error(
              type: ResultType.validationFailed,
              message: 'Validation failed for record $i: $err',
              failedKeys: failedKeys,
            ));
          }
          continue; // Skip this record
        }
        needsResolution.add(record);
      }
    }

    // Perform batched PK resolution via IndexManager
    if (needsResolution.isNotEmpty) {
      // PERFORMANCE: IndexManager.checkUniqueConstraintsBatch now sorts probe keys internally.
      // resolveInPlace: true ensures records are updated with their existingPrimaryKey directly.
      await indexManager!.checkUniqueConstraintsBatch(
        tableName,
        needsResolution,
        schemaOverride: schema,
        isUpdate: false,
        resolveInPlace: true,
        transactionId: txId,
      );

      // Handle records that failed resolution (not found in DB/Buffer)
      for (final r in needsResolution) {
        if (r[primaryKey] == null) {
          failedKeys.add('not_found');
          if (!allowPartialErrors) {
            final idInfo = r.keys.take(3).map((k) => '$k=${r[k]}').join(', ');
            return finish(DbResult.error(
              type: ResultType.notFound,
              message: 'Record not found for unique identifier: {$idInfo}',
              failedKeys: failedKeys,
            ));
          }
        }
      }
    }

    // Combine all records that now have a valid PK
    final List<Map<String, dynamic>> finalRecords = [
      ...withPk,
      ...needsResolution.where((r) => r[primaryKey] != null)
    ];

    if (finalRecords.isEmpty) {
      return finish(DbResult.batch(
        successKeys: successKeys,
        failedKeys: failedKeys,
        message: 'No valid records found to update',
      ));
    }

    final batchYield =
        YieldController('DataStoreImpl.batchUpdate.batch', checkInterval: 1);
    final executionYield =
        YieldController('DataStoreImpl.batchUpdate.execute', checkInterval: 50);

    try {
      // Process in batches to maintain UI responsiveness and manage memory
      const int batchSize = 1000;

      for (int i = 0; i < finalRecords.length; i += batchSize) {
        await batchYield.maybeYield();
        final int end = (i + batchSize < finalRecords.length)
            ? i + batchSize
            : finalRecords.length;
        final subBatch = finalRecords.sublist(i, end);

        // 3. Prepare primary key list
        final List<String> pkList = [];
        for (final record in subBatch) {
          final pkVal = record[primaryKey]?.toString();
          if (pkVal != null) pkList.add(pkVal);
        }

        if (pkList.isEmpty) continue;

        // 4. Bulk Fetch Existing Records
        final results = await executeQuery(
          tableName,
          QueryCondition()..whereIn(primaryKey, pkList),
          limit: pkList.length,
        );

        // Convert results to a map for O(1) lookup
        final Map<String, Map<String, dynamic>> resultsMap = {
          for (var r in results) r[primaryKey].toString(): r
        };

        // 5. Fast-path check for strict error mode (if results missing items)
        if (!allowPartialErrors && resultsMap.length < pkList.length) {
          for (final pkVal in pkList) {
            if (!resultsMap.containsKey(pkVal)) {
              failedKeys.add(pkVal);
            }
          }
          return finish(DbResult.error(
            type: ResultType.notFound,
            message: 'Some records not found during batchUpdate',
            failedKeys: failedKeys,
          ));
        }

        // 6. Optimization: Create batch context to hoist table/buffer lookups
        final batchContext =
            writeBufferManager.createBatchCheckContext(tableName, txId);

        // 7. Pipeline Stage 1: Batch Merge and Validate
        final List<Map<String, dynamic>> candidateMergedRecords = [];
        final List<String> candidatePkVals = [];
        final List<Map<String, dynamic>> candidateOldRecords = [];
        final Map<String, Set<String>> candidateChangedFieldsMap = {};

        for (final record in subBatch) {
          final pkVal = record[primaryKey]?.toString();
          if (pkVal == null) continue;

          final existingRecord = resultsMap[pkVal];

          if (existingRecord == null) {
            if (allowPartialErrors) {
              failedKeys.add(pkVal);
            }
            continue;
          }

          await executionYield.maybeYield();

          // Validate update data
          final validData =
              await _validateAndProcessUpdateData(schema, record, tableName);
          if (validData == null || validData.isEmpty) {
            failedKeys.add(pkVal);
            if (!allowPartialErrors) {
              return finish(DbResult.error(
                type: ResultType.validationFailed,
                message: 'Data validation failed for record $pkVal',
                failedKeys: failedKeys,
              ));
            }
            continue;
          }

          // Merge fields and detect changes
          final updatedRecord = <String, dynamic>{...existingRecord};
          final Set<String> changedFields = {};

          for (final entry in validData.entries) {
            final fname = entry.key;
            final dynamic proposed = entry.value;

            if (proposed is ExprNode) {
              try {
                final result = _evaluateExpression(
                  proposed,
                  existingRecord,
                  schema,
                  isUpdate: true,
                );
                final field = schema.fields.firstWhere((f) => f.name == fname);
                final converted = field.convertValue(result);

                // Re-validate after expression evaluation
                if (!field.validateUpdateValue(converted)) {
                  failedKeys.add(pkVal);
                  if (!allowPartialErrors) {
                    return finish(DbResult.error(
                      type: ResultType.validationFailed,
                      message:
                          'Result of expression for $fname exceeds constraints: $converted',
                      failedKeys: failedKeys,
                    ));
                  }
                  continue;
                }

                var finalValue = converted;
                if (finalValue is String && field.maxLength != null) {
                  if (finalValue.length > field.maxLength!) {
                    finalValue = finalValue.substring(0, field.maxLength!);
                  }
                }

                if (updatedRecord[fname] != finalValue) {
                  updatedRecord[fname] = finalValue;
                  changedFields.add(fname);
                }
              } catch (e) {
                Logger.error('Expression evaluation failed for $fname: $e');
              }
            } else {
              if (updatedRecord[fname] != proposed) {
                updatedRecord[fname] = proposed;
                changedFields.add(fname);
              }
            }
          }

          if (changedFields.isEmpty) {
            successKeys.add(pkVal);
            continue;
          }

          candidateMergedRecords.add(updatedRecord);
          candidatePkVals.add(pkVal);
          candidateOldRecords.add(existingRecord);
          candidateChangedFieldsMap[pkVal] = changedFields;
        }

        if (candidateMergedRecords.isEmpty) continue;

        // 8. Pipeline Stage 2: Batch Reserve (Buffer Lock)
        // We lock the buffer FIRST to ensure atomic isolation during the subsequent slow disk check.
        final List<Map<String, dynamic>> readyForDiskCheck = [];
        final List<String> readyPkVals = [];
        final List<Map<String, dynamic>> readyOldRecords = [];
        final Map<String, Set<String>> readyChangedFieldsMap = {};
        final Map<String, List<UniqueKeyRef>> reservedRefsMap = {};

        for (int j = 0; j < candidateMergedRecords.length; j++) {
          final pkVal = candidatePkVals[j];
          final updatedRecord = candidateMergedRecords[j];
          final changedFields = candidateChangedFieldsMap[pkVal]!;

          // Collect unique keys that need reservation
          final List<UniqueKeyRef> refsToReserve = [];
          for (final idx in allUniqueIndexes) {
            if (idx.fields.any((f) => changedFields.contains(f))) {
              final canKey =
                  schema.createCanonicalIndexKey(idx.fields, updatedRecord);
              if (canKey != null) {
                refsToReserve.add(UniqueKeyRef(idx.actualIndexName, canKey));
              }
            }
          }

          if (refsToReserve.isNotEmpty) {
            try {
              batchContext.tryReserve(pkVal, refsToReserve);
              reservedRefsMap[pkVal] = refsToReserve;
            } catch (e) {
              failedKeys.add(pkVal);
              if (!allowPartialErrors) {
                // Rollback all reservations in this sub-batch before returning
                for (final rPk in reservedRefsMap.keys) {
                  try {
                    writeBufferManager.releaseReservedUniqueKeys(
                      tableName: tableName,
                      recordId: rPk,
                      transactionId: txId,
                    );
                  } catch (_) {}
                }
                return finish(DbResult.error(
                  type: ResultType.uniqueViolation,
                  message: 'Unique reservation failed for $pkVal: $e',
                  failedKeys: failedKeys,
                ));
              }
              continue;
            }
          }

          readyForDiskCheck.add(updatedRecord);
          readyPkVals.add(pkVal);
          readyOldRecords.add(candidateOldRecords[j]);
          readyChangedFieldsMap[pkVal] = changedFields;
        }

        if (readyForDiskCheck.isEmpty) continue;

        // 9. Pipeline Stage 3: Batch Unique Constraint Check (Disk Only)
        // Since we already hold the buffer locks, we only need to verify against committed disk state.
        final violations = await indexManager!.checkUniqueConstraintsBatch(
          tableName,
          readyForDiskCheck,
          schemaOverride: schema,
          transactionId: txId,
          isUpdate: true,
          skipBufferCheck: true,
          changedFieldsMap: readyChangedFieldsMap,
        );

        // 10. Pipeline Stage 4: Validation and Commit
        final List<Map<String, dynamic>> recordsToCommit = [];
        final List<Map<String, dynamic>> oldRecordsToCommit = [];
        final List<List<UniqueKeyRef>> batchUniqueKeyRefs = [];
        final List<String> commitPkVals = [];

        for (int j = 0; j < readyForDiskCheck.length; j++) {
          final pkVal = readyPkVals[j];
          final violation = violations[j];

          if (violation != null) {
            failedKeys.add(pkVal);
            // Rollback reservation for this specific record on disk conflict
            if (reservedRefsMap.containsKey(pkVal)) {
              try {
                writeBufferManager.releaseReservedUniqueKeys(
                  tableName: tableName,
                  recordId: pkVal,
                  transactionId: txId,
                );
              } catch (_) {}
            }

            if (!allowPartialErrors) {
              // Rollback all other reservations in this sub-batch
              for (final rPk in reservedRefsMap.keys) {
                try {
                  writeBufferManager.releaseReservedUniqueKeys(
                    tableName: tableName,
                    recordId: rPk,
                    transactionId: txId,
                  );
                } catch (_) {}
              }
              return finish(DbResult.error(
                type: ResultType.uniqueViolation,
                message:
                    'Unique constraint violation on ${violation.fields.join(', ')}: ${violation.value}',
                failedKeys: failedKeys,
              ));
            }
            continue;
          }

          final updatedRecord = readyForDiskCheck[j];
          final existingRecord = readyOldRecords[j];

          // Prepare full unique key refs for buffer consistency
          final currentUniqueRefs = <UniqueKeyRef>[UniqueKeyRef('pk', pkVal)];
          for (final idx in allUniqueIndexes) {
            final canKey =
                schema.createCanonicalIndexKey(idx.fields, updatedRecord);
            if (canKey != null) {
              currentUniqueRefs.add(UniqueKeyRef(idx.actualIndexName, canKey));
            }
          }

          // 10.1: Foreign Key Checks
          if (_foreignKeyManager != null) {
            try {
              await _foreignKeyManager!.validateForeignKeyConstraints(
                tableName: tableName,
                data: updatedRecord,
                operation: ForeignKeyOperation.update,
              );
            } catch (e) {
              failedKeys.add(pkVal);
              if (reservedRefsMap.containsKey(pkVal)) {
                try {
                  writeBufferManager.releaseReservedUniqueKeys(
                    tableName: tableName,
                    recordId: pkVal,
                    transactionId: txId,
                  );
                } catch (_) {}
              }
              if (!allowPartialErrors) {
                // Rollback all reservations
                for (final rPk in reservedRefsMap.keys) {
                  try {
                    writeBufferManager.releaseReservedUniqueKeys(
                      tableName: tableName,
                      recordId: rPk,
                      transactionId: txId,
                    );
                  } catch (_) {}
                }
                return finish(DbResult.error(
                  type: ResultType.foreignKeyViolation,
                  message: e.toString(),
                  failedKeys: [pkVal],
                ));
              }
              continue;
            }
          }

          recordsToCommit.add(updatedRecord);
          oldRecordsToCommit.add(existingRecord);
          batchUniqueKeyRefs.add(currentUniqueRefs);
          commitPkVals.add(pkVal);
        }

        // 10.2: Single atomic batch commit to TableDataManager
        if (recordsToCommit.isNotEmpty) {
          final Map<String, Map<String, dynamic>> oldRecordsMap = {};
          for (int k = 0; k < recordsToCommit.length; k++) {
            final rec = recordsToCommit[k];
            final pk = rec[primaryKey]?.toString();
            if (pk != null) {
              oldRecordsMap[pk] = oldRecordsToCommit[k];
            }
          }

          final commitResult = await tableDataManager.addBatchToBuffer(
            tableName: tableName,
            records: recordsToCommit,
            operation: BufferOperationType.update,
            schema: schema,
            uniqueKeyRefsList: batchUniqueKeyRefs,
            oldRecordsMap: oldRecordsMap,
            transactionId: txId,
          );

          successKeys.addAll(commitResult.successRecordIds);

          if (commitResult.failedRecordIds.isNotEmpty) {
            for (final fId in commitResult.failedRecordIds) {
              failedKeys.add(fId);
              if (reservedRefsMap.containsKey(fId)) {
                try {
                  writeBufferManager.releaseReservedUniqueKeys(
                    tableName: tableName,
                    recordId: fId,
                    transactionId: txId,
                  );
                } catch (_) {}
              }
            }
          }

          for (int k = 0; k < recordsToCommit.length; k++) {
            if (commitResult.successRecordIds.contains(commitPkVals[k])) {
              notificationManager.notify(ChangeEvent(
                type: ChangeType.update,
                tableName: tableName,
                record: recordsToCommit[k],
                oldRecord: oldRecordsToCommit[k],
              ));
            }
          }
        }
      }

      if (successKeys.isNotEmpty && failedKeys.isNotEmpty) {
        return finish(DbResult.batch(
          successKeys: successKeys,
          failedKeys: failedKeys,
          message:
              'Batch update partially successful: ${successKeys.length} updated, ${failedKeys.length} failed',
        ));
      } else if (successKeys.isNotEmpty) {
        return finish(DbResult.success(
          successKeys: successKeys,
          message: 'Batch update successful: ${successKeys.length} updated',
        ));
      } else {
        return finish(DbResult.error(
          type: ResultType.notFound,
          message: 'No records were updated',
          failedKeys: failedKeys,
        ));
      }
    } catch (e) {
      Logger.error('Batch update failed: $e', label: 'DataStore.batchUpdate');
      return finish(DbResult.error(
        type: ResultType.dbError,
        message: 'Batch update failed: $e',
      ));
    }
  }

  /// load data from specified path
  Future<void> loadDataToCache() async {
    if (_isGlobalPrewarming) {
      return;
    }
    if (config.persistenceMode == PersistenceMode.memory) {
      return;
    }

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
      final schemaMgr = schemaManager;
      if (schemaMgr == null) return;

      // From schemaManager get all tables
      final allTables = await getTableNames();
      if (allTables.isEmpty || !_isInitialized) return;

      // Sort tables by weight
      final prioritizedTables = await _prioritizeTablesByWeight(allTables);
      if (!_isInitialized) return;

      final yieldController =
          YieldController('DataStoreImpl._executePrewarm', checkInterval: 1);
      const maxPrewarmTables = 50;
      final selectedTables = prioritizedTables.length <= maxPrewarmTables
          ? prioritizedTables
          : prioritizedTables.take(maxPrewarmTables).toList(growable: false);

      // Load tables by weight order.
      // If total table count is small, prewarm all tables to avoid missing hot
      // tables when weight data is incomplete.
      for (final tableName in selectedTables) {
        if (!_isInitialized) break;
        try {
          // Check if table exists in current space
          final tableExistsInSpace = await tableExistsInCurrentSpace(tableName);
          if (!tableExistsInSpace || !_isInitialized) {
            continue;
          }

          final tableMeta = await tableDataManager.getTableMeta(tableName);
          if (tableMeta != null && !tableMeta.btreeFirstLeaf.isNull) {
            await tableTreePartitionManager?.prewarmBoundaryPages(
              tableName,
              meta: tableMeta,
            );
          }

          final schema = await schemaMgr.getTableSchema(tableName);
          if (schema != null) {
            final indexes = schemaMgr
                .getBtreeIndexesFor(schema)
                .where((index) => index.type == IndexType.btree);
            for (final index in indexes) {
              if (!_isInitialized) break;
              final indexName = index.actualIndexName;
              final indexMeta =
                  await _indexManager?.getIndexMeta(tableName, indexName);
              if (indexMeta == null || indexMeta.btreeFirstLeaf.isNull) {
                continue;
              }
              await indexTreePartitionManager?.prewarmBoundaryPages(
                tableName,
                indexName,
                meta: indexMeta,
              );
              await yieldController.maybeYield();
            }
          }

          // Yield control to the event loop to prevent UI freezing during a long prewarm process.
          await yieldController.maybeYield();
        } catch (e) {
          // If already closing/closed, suppress errors from missing managers
          if (!_isInitialized) break;

          Logger.error('Load table data failed: $tableName, error: $e',
              label: 'DataStore._executePrewarm');
          continue; // Continue load other tables
        }
      }

      final effectivePrewarmThresholdMB =
          await _resourceManager!.initializeEffectivePrewarmThresholdMB(config);
      final effectivePrewarmBudgetBytes =
          effectivePrewarmThresholdMB * 1024 * 1024;

      var remainingPrewarmBytes = effectivePrewarmBudgetBytes;
      remainingPrewarmBytes = await _prewarmKvStore(
        maxPrewarmBytes: remainingPrewarmBytes,
      );

      await _prewarmUserTables(
        prioritizedTables: prioritizedTables,
        prewarmBudgetBytes: remainingPrewarmBytes,
      );
    } catch (e) {
      if (_isInitialized) {
        Logger.error('Error in _executePrewarm: $e',
            label: 'DataStore._executePrewarm');
      }
    } finally {
      _isGlobalPrewarming = false;
    }
  }

  /// Prewarm KV store tables into TreeCache.
  /// Returns the remaining budget after KV warmup.
  Future<int> _prewarmKvStore({required int maxPrewarmBytes}) async {
    const maxRecordsSafetyCap = 200000;

    final kvTables = [
      SystemTable.getKeyValueName(true),
      SystemTable.getKeyValueName(false),
    ];

    var currentPrewarmedBytes = 0;
    final yieldController =
        YieldController('DataStoreImpl._prewarmKvStore', checkInterval: 1);

    for (final tableName in kvTables) {
      if (!_isInitialized) return maxPrewarmBytes - currentPrewarmedBytes;
      try {
        final tableMeta = await tableDataManager.getTableMeta(tableName);
        if (!_isInitialized) return maxPrewarmBytes - currentPrewarmedBytes;
        if (tableMeta == null || tableMeta.totalRecords <= 0) continue;

        final indexBytes = await _estimateTableIndexBytes(tableName);
        final estimatedBytes = tableMeta.totalSizeInBytes + indexBytes;
        if (currentPrewarmedBytes + estimatedBytes > maxPrewarmBytes) {
          continue;
        }

        await executeQuery(
          tableName,
          QueryCondition()..where(SystemTable.keyValueKeyField, '>=', ''),
          limit: maxRecordsSafetyCap,
        );
        currentPrewarmedBytes += estimatedBytes;
        await yieldController.maybeYield();
      } catch (e) {
        if (!_isInitialized) return maxPrewarmBytes - currentPrewarmedBytes;
        Logger.warn('Prewarm KV store failed for $tableName: $e',
            label: 'DataStore.prewarm');
      }
    }

    return maxPrewarmBytes - currentPrewarmedBytes;
  }

  /// Prewarm user tables when the current space remains small enough.
  Future<void> _prewarmUserTables({
    List<String>? prioritizedTables,
    required int prewarmBudgetBytes,
  }) async {
    final schemaMgr = schemaManager;
    if (schemaMgr == null || !_isInitialized) return;

    final spaceConfig = await getSpaceConfig();
    final spaceUsageBytes = spaceConfig?.totalDataSizeBytes ?? 0;
    const maxRecordsSafetyCap = 200000;

    if (spaceUsageBytes >= prewarmBudgetBytes) {
      return;
    }

    final tables = prioritizedTables ??
        _getUserDefinedSchemas()
            .map((schema) => schema.name)
            .toList(growable: false);
    if (tables.isEmpty) return;

    final userTables = tables
        .where((t) => !SystemTable.isSystemTable(t))
        .toList(growable: false);
    if (userTables.isEmpty) return;

    final yieldController =
        YieldController('DataStoreImpl._prewarmUserTables', checkInterval: 1);

    var currentPrewarmedBytes = 0;

    for (final tableName in userTables) {
      if (!_isInitialized) break;
      try {
        final tableExistsInSpace = await tableExistsInCurrentSpace(tableName);
        if (!tableExistsInSpace || !_isInitialized) continue;

        final tableMeta = await tableDataManager.getTableMeta(tableName);
        if (tableMeta == null || tableMeta.totalRecords <= 0) continue;

        final schema = await schemaMgr.getTableSchema(tableName);
        if (schema == null) continue;

        final indexBytes = await _estimateTableIndexBytes(tableName);
        final estimatedBytes = tableMeta.totalSizeInBytes + indexBytes;

        if (currentPrewarmedBytes + estimatedBytes > prewarmBudgetBytes ||
            tableMeta.totalRecords > maxRecordsSafetyCap) {
          break;
        }

        await executeQuery(
          tableName,
          QueryCondition()..where(schema.primaryKey, '>=', ''),
          limit: maxRecordsSafetyCap,
        );
        await yieldController.maybeYield();

        final indexes = schemaMgr.getBtreeIndexesFor(schema);
        for (final index in indexes) {
          if (!_isInitialized) break;
          final indexName = index.actualIndexName;
          final indexMeta =
              await _indexManager?.getIndexMeta(tableName, indexName);
          if (indexMeta == null || indexMeta.btreeFirstLeaf.isNull) continue;

          // Warm the full index by traversing its leaf chain directly.
          await indexTreePartitionManager?.searchByKeyRange(
            tableName: tableName,
            indexName: indexName,
            meta: indexMeta,
            startKeyInclusive: Uint8List(0),
            endKeyExclusive: Uint8List(0),
            limit: maxRecordsSafetyCap,
          );
          await yieldController.maybeYield();
        }

        currentPrewarmedBytes += estimatedBytes;
        await yieldController.maybeYield();
      } catch (e) {
        if (!_isInitialized) break;
        Logger.warn('Prewarm user table failed for $tableName: $e',
            label: 'DataStore.prewarm');
      }
    }
  }

  Future<int> _estimateTableIndexBytes(String tableName) async {
    final schemaMgr = schemaManager;
    if (schemaMgr == null) return 0;
    final schema = await schemaMgr.getTableSchema(tableName);
    if (schema == null) return 0;

    var total = 0;
    final yieldController = YieldController(
        'DataStoreImpl._estimateTableIndexBytes',
        checkInterval: 2);
    final indexes = schemaMgr
        .getBtreeIndexesFor(schema)
        .where((index) => index.type == IndexType.btree);
    for (final index in indexes) {
      final indexMeta =
          await _indexManager?.getIndexMeta(tableName, index.actualIndexName);
      if (indexMeta != null) {
        total += indexMeta.totalSizeInBytes;
      }
      await yieldController.maybeYield();
    }
    return total;
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

  /// Perform approximate nearest neighbor (ANN) vector similarity search.
  ///
  /// Searches the NGH vector index on [fieldName] in [tableName] to find
  /// the top-[topK] records most similar to [queryVector].
  ///
  /// Returns a list of [VectorSearchResult] sorted by similarity
  /// (highest score first). Each entry contains the matching record's
  /// primary key, distance, and normalised score.
  ///
  /// Example:
  /// ```dart
  /// final results = await db.vectorSearch(
  ///   'articles',
  ///   fieldName: 'embedding',
  ///   queryVector: VectorData([0.1, 0.2, ...]),
  ///   topK: 10,
  /// );
  /// ```
  Future<List<VectorSearchResult>> vectorSearch(
    String tableName, {
    required String fieldName,
    required VectorData queryVector,
    int topK = 10,
    int? efSearch,
    double? distanceThreshold,
  }) async {
    await ensureInitialized();
    if (_vectorIndexManager == null) return const [];
    return _vectorIndexManager!.vectorSearch(
      tableName: tableName,
      fieldName: fieldName,
      queryVector: queryVector,
      topK: topK,
      efSearch: efSearch,
      distanceThreshold: distanceThreshold,
    );
  }

  /// Switch space
  ///
  /// [keepActive] When true (default), writes this [spaceName] to
  /// [GlobalConfig.activeSpace]. When opening with default space, init will use activeSpace so one open lands in the right space.
  Future<bool> switchSpace(
      {String spaceName = 'default', bool keepActive = true}) async {
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
      // 1. Unified shutdown logic for the current space via close()
      // closeStorage: false keeps the driver connection alive during space switch.
      // removeRegistry: false ensures this DataStoreImpl instance stays in the factory cache.
      await close(closeStorage: false, removeRegistry: false);

      // 2. Update current space name and config
      _currentSpaceName = spaceName;
      if (_config != null) {
        _config = _config!.copyWith(spaceName: _currentSpaceName);
      }

      // Reinitialize database with the new space configuration
      await initialize(applyActiveSpaceOnDefault: false);

      // Update GlobalConfig only if there are actual changes to avoid unnecessary IO
      final globalConfig = await getGlobalConfig();
      if (globalConfig != null) {
        bool needsUpdate = false;
        GlobalConfig updatedConfig = globalConfig;

        // Add space if it doesn't exist
        if (!globalConfig.spaceNames.contains(spaceName)) {
          updatedConfig = updatedConfig.addSpace(spaceName);
          needsUpdate = true;
        }

        // Update activeSpace only if keepActive is true and it's different
        if (keepActive && globalConfig.activeSpace != spaceName) {
          updatedConfig = updatedConfig.copyWith(activeSpace: spaceName);
          needsUpdate = true;
        }

        // Save only if there are actual changes
        if (needsUpdate) {
          await saveGlobalConfig(updatedConfig);
        }
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
      await walManager.flushQueueCompletely();
      if (config.enableJournal) {
        await walManager.persistMeta(flush: true);
      }

      // 2) Flush all pending writes and index updates from the write queue.
      await parallelJournalManager.flushCompletely();

      // 3) Persist runtime metadata (max IDs, table statistics) eagerly.
      await tableDataManager.persistRuntimeMetaIfNeeded(force: true);

      // 4) Save weights
      await weightManager?.saveWeights(force: true);

      // 5) Ensure buffered IO is flushed to disk (releases handles on Windows)
      await storage.flushAll(closeHandles: true);
    } catch (e) {
      Logger.error('Failed to save cache before exit: $e',
          label: 'DataStoreImpl.saveAllCacheBeforeExit');
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
  Future<DbResult> setValue(
    String key,
    dynamic value, {
    Duration? ttl,
    DateTime? expiresAt,
    bool isGlobal = false,
  }) async {
    await ensureInitialized();

    if (ttl != null && expiresAt != null) {
      return DbResult.error(
        type: ResultType.validationFailed,
        message: 'ttl and expiresAt are mutually exclusive',
        failedKeys: [key],
      );
    }

    if (ttl != null && ttl <= Duration.zero) {
      return DbResult.error(
        type: ResultType.validationFailed,
        message: 'ttl must be greater than zero',
        failedKeys: [key],
      );
    }

    final tableName = SystemTable.getKeyValueName(isGlobal);
    final now = DateTime.now();
    final expiresAtIso = expiresAt?.toIso8601String() ??
        (ttl != null ? now.add(ttl).toIso8601String() : null);

    // Build data for upsert
    final data = {
      _kvKeyField: key,
      _kvValueField: jsonEncode(value),
      _kvUpdatedAtField: now.toIso8601String(),
      _kvExpiresAtField: expiresAtIso,
    };

    final schema = await schemaManager?.getTableSchema(tableName);
    if (schema == null) {
      return DbResult.error(
        type: ResultType.notFound,
        message: 'KV table not found',
        failedKeys: [key],
      );
    }

    return await batchUpsert(tableName, [data]);
  }

  Future<DbResult> setValueMany(
    Map<String, dynamic> items, {
    Duration? ttl,
    DateTime? expiresAt,
    bool isGlobal = false,
    bool allowPartialErrors = true,
  }) async {
    await ensureInitialized();
    if (items.isEmpty) {
      return DbResult.success(message: 'No items to set');
    }

    if (ttl != null && expiresAt != null) {
      return DbResult.error(
        type: ResultType.validationFailed,
        message: 'ttl and expiresAt are mutually exclusive',
      );
    }

    if (ttl != null && ttl <= Duration.zero) {
      return DbResult.error(
        type: ResultType.validationFailed,
        message: 'ttl must be greater than zero',
      );
    }

    final tableName = SystemTable.getKeyValueName(isGlobal);
    final schema = await schemaManager?.getTableSchema(tableName);
    if (schema == null) {
      return DbResult.error(
        type: ResultType.notFound,
        message: 'KV table not found',
      );
    }

    final now = DateTime.now();
    final nowIso = now.toIso8601String();
    final expiresAtIso = expiresAt?.toIso8601String() ??
        (ttl != null ? now.add(ttl).toIso8601String() : null);

    final records = <Map<String, dynamic>>[];
    final preparationYield = YieldController(
        'DataStoreImpl.setValueMany.prepare',
        checkInterval: 200);
    for (final entry in items.entries) {
      await preparationYield.maybeYield();
      records.add({
        _kvKeyField: entry.key,
        _kvValueField: jsonEncode(entry.value),
        _kvUpdatedAtField: nowIso,
        _kvExpiresAtField: expiresAtIso,
      });
    }
    return await batchUpsert(tableName, records,
        allowPartialErrors: allowPartialErrors);
  }

  /// Get key-value pair
  Future<dynamic> getValue(String key, {bool isGlobal = false}) async {
    await ensureInitialized();

    final tableName = SystemTable.getKeyValueName(isGlobal);
    final result = await executeQuery(
      tableName,
      QueryCondition()..where(_kvKeyField, '=', key),
      limit: 1,
    );
    if (result.isEmpty) {
      return null;
    }

    final row = result.first;
    if (_isKvRowExpired(row)) {
      _scheduleExactExpiredKvCleanup(tableName, key, row[_kvExpiresAtField]);
      return null;
    }

    return _decodeStoredKeyValue(row[_kvValueField], key: key);
  }

  /// Get all keys in the specified space, optionally filtered by prefix.
  Future<List<String>> getKeys({String? prefix, bool isGlobal = false}) async {
    await ensureInitialized();
    final tableName = SystemTable.getKeyValueName(isGlobal);
    final condition = QueryCondition();
    if (prefix != null && prefix.isNotEmpty) {
      condition.whereStartsWith(_kvKeyField, prefix);
    }

    final rows = await executeQuery(tableName, condition);
    final now = DateTime.now();
    final keys = <String>[];

    for (final row in rows) {
      if (!_isKvRowExpired(row, now: now)) {
        keys.add(row[_kvKeyField].toString());
      } else {
        _scheduleExactExpiredKvCleanup(
            tableName, row[_kvKeyField].toString(), row[_kvExpiresAtField]);
      }
    }
    return keys;
  }

  /// Check if a key exists and is not expired.
  Future<bool> exists(String key, {bool isGlobal = false}) async {
    await ensureInitialized();
    final tableName = SystemTable.getKeyValueName(isGlobal);
    final result = await executeQuery(
      tableName,
      QueryCondition()..where(_kvKeyField, '=', key),
      limit: 1,
    );
    if (result.isEmpty) return false;

    final row = result.first;
    if (_isKvRowExpired(row)) {
      _scheduleExactExpiredKvCleanup(tableName, key, row[_kvExpiresAtField]);
      return false;
    }
    return true;
  }

  /// Remove key-value pair
  Future<DbResult> removeValue(String key, {bool isGlobal = false}) async {
    await ensureInitialized();

    final tableName = SystemTable.getKeyValueName(isGlobal);
    // Build delete condition
    final condition = QueryCondition()..where(_kvKeyField, '=', key);
    return await deleteInternal(tableName, condition);
  }

  /// Remove multiple key-value pairs.
  Future<DbResult> removeValues(Iterable<String> keys,
      {bool isGlobal = false}) async {
    await ensureInitialized();
    final keyList = keys.toList();
    if (keyList.isEmpty) return DbResult.success();

    final tableName = SystemTable.getKeyValueName(isGlobal);
    final condition = QueryCondition()..whereIn(_kvKeyField, keyList);
    return await deleteInternal(tableName, condition);
  }

  /// Get remaining TTL for a key.
  Future<Duration?> getTtl(String key, {bool isGlobal = false}) async {
    await ensureInitialized();
    final tableName = SystemTable.getKeyValueName(isGlobal);
    final result = await executeQuery(
      tableName,
      QueryCondition()..where(_kvKeyField, '=', key),
      limit: 1,
    );
    if (result.isEmpty) return null;

    final row = result.first;
    final expiresAt = _parseKvDateTime(row[_kvExpiresAtField]);
    if (expiresAt == null) return null;

    final now = DateTime.now();
    if (expiresAt.isBefore(now)) {
      _scheduleExactExpiredKvCleanup(tableName, key, row[_kvExpiresAtField]);
      return null;
    }
    return expiresAt.difference(now);
  }

  /// Set TTL for an existing key.
  Future<DbResult> setTtl(String key, Duration? ttl,
      {DateTime? expiresAt, bool isGlobal = false}) async {
    await ensureInitialized();
    final tableName = SystemTable.getKeyValueName(isGlobal);

    final now = DateTime.now();
    final expiresAtIso = expiresAt?.toIso8601String() ??
        (ttl != null ? now.add(ttl).toIso8601String() : null);

    final data = {
      _kvExpiresAtField: expiresAtIso,
      _kvUpdatedAtField: now.toIso8601String(),
    };

    final condition = QueryCondition()..where(_kvKeyField, '=', key);
    return await updateInternal(tableName, data, condition);
  }

  /// Atomic increment for a numeric value.
  Future<DbResult> setIncrement(String key,
      {int amount = 1, bool isGlobal = false}) async {
    await ensureInitialized();
    final tableName = SystemTable.getKeyValueName(isGlobal);

    // Efficiently check if key exists and is not expired.
    // If not exists, we use setValue to handle insert and default values (TTL etc.)
    if (!(await exists(key, isGlobal: isGlobal))) {
      return await setValue(key, amount, isGlobal: isGlobal);
    }

    // Atomic update using expression system.
    // The expression evaluator in TableDataManager automatically handles
    // numeric strings (from jsonEncode) by parsing them.
    final nowIso = DateTime.now().toIso8601String();
    final data = {
      _kvValueField: Expr.field(_kvValueField) + Expr.value(amount),
      _kvUpdatedAtField: nowIso,
    };

    final condition = QueryCondition()..where(_kvKeyField, '=', key);
    return await updateInternal(tableName, data, condition);
  }

  /// Watch a single key-value pair and emit the latest value immediately.
  Stream<T?> watchValue<T>(String key,
      {bool isGlobal = false, T? defaultValue, bool distinct = true}) {
    final tableName = SystemTable.getKeyValueName(isGlobal);
    final condition = QueryCondition()..where(_kvKeyField, '=', key);

    return _watchKvQuery<T?>(
      tableName: tableName,
      condition: condition,
      distinct: distinct,
      loadSnapshot: () async {
        final rows = await executeQuery(tableName, condition);
        if (rows.isEmpty) {
          return (
            value: defaultValue,
            fingerprint: jsonEncode([
              key,
              false,
              null,
            ]),
            nextRefreshAt: null,
          );
        }

        final row = rows.first;
        final rawExpiresAt = row[_kvExpiresAtField];
        final expiresAt = _parseKvDateTime(rawExpiresAt);
        if (expiresAt != null && !expiresAt.isAfter(DateTime.now())) {
          _scheduleExactExpiredKvCleanup(tableName, key, rawExpiresAt);
          return (
            value: defaultValue,
            fingerprint: jsonEncode([
              key,
              false,
              null,
            ]),
            nextRefreshAt: null,
          );
        }

        final rawValue = row[_kvValueField];
        return (
          value: _decodeStoredKeyValue(rawValue, key: key) as T?,
          fingerprint: jsonEncode([
            key,
            true,
            rawValue,
          ]),
          nextRefreshAt: expiresAt,
        );
      },
    );
  }

  /// Watch multiple key-value pairs and emit the latest snapshot immediately.
  /// Missing keys are included with `null` values.
  Stream<Map<String, dynamic>> watchValues(Iterable<String> keys,
      {bool isGlobal = false, bool distinct = true}) {
    final requestedKeys =
        LinkedHashSet<String>.from(keys).toList(growable: false);
    if (requestedKeys.isEmpty) {
      return Stream.value(const <String, dynamic>{});
    }

    final tableName = SystemTable.getKeyValueName(isGlobal);
    final condition = QueryCondition();
    if (requestedKeys.length == 1) {
      condition.where(_kvKeyField, '=', requestedKeys.first);
    } else {
      condition.where(_kvKeyField, 'IN', requestedKeys);
    }

    return _watchKvQuery<Map<String, dynamic>>(
      tableName: tableName,
      condition: condition,
      distinct: distinct,
      loadSnapshot: () async {
        final rows = await executeQuery(tableName, condition);
        final rowsByKey = <String, Map<String, dynamic>>{};
        for (final row in rows) {
          final rowKey = row[_kvKeyField];
          if (rowKey != null) {
            rowsByKey[rowKey.toString()] = row;
          }
        }

        final values = <String, dynamic>{};
        final fingerprintParts = <Object?>[];
        DateTime? nextRefreshAt;
        final now = DateTime.now();
        for (final requestedKey in requestedKeys) {
          final row = rowsByKey[requestedKey];
          if (row == null) {
            values[requestedKey] = null;
            fingerprintParts.add([requestedKey, false, null]);
            continue;
          }

          final rawExpiresAt = row[_kvExpiresAtField];
          final expiresAt = _parseKvDateTime(rawExpiresAt);
          if (expiresAt != null && !expiresAt.isAfter(now)) {
            values[requestedKey] = null;
            fingerprintParts.add([requestedKey, false, null]);
            _scheduleExactExpiredKvCleanup(
                tableName, requestedKey, rawExpiresAt);
            continue;
          }

          if (expiresAt != null &&
              (nextRefreshAt == null || expiresAt.isBefore(nextRefreshAt))) {
            nextRefreshAt = expiresAt;
          }

          final rawValue = row[_kvValueField];
          values[requestedKey] =
              _decodeStoredKeyValue(rawValue, key: requestedKey);
          fingerprintParts.add([requestedKey, true, rawValue]);
        }

        return (
          value: Map<String, dynamic>.unmodifiable(values),
          fingerprint: jsonEncode(fingerprintParts),
          nextRefreshAt: nextRefreshAt,
        );
      },
    );
  }

  Stream<T> _watchKvQuery<T>({
    required String tableName,
    required QueryCondition condition,
    required Future<({T value, String fingerprint, DateTime? nextRefreshAt})>
            Function()
        loadSnapshot,
    bool distinct = true,
  }) {
    late StreamController<T> controller;
    StreamSubscription? subscription;
    Timer? refreshTimer;
    bool queryPending = false;
    bool needsRefresh = false;
    bool hasEmitted = false;
    String? lastFingerprint;
    late Future<void> Function() emitLatest;

    void scheduleRefresh(DateTime? refreshAt) {
      refreshTimer?.cancel();
      if (refreshAt == null || controller.isClosed) {
        return;
      }

      final delay = refreshAt.difference(DateTime.now());
      refreshTimer = Timer(
        delay <= Duration.zero ? Duration.zero : delay,
        () async {
          if (controller.isClosed) {
            return;
          }
          if (queryPending) {
            needsRefresh = true;
            return;
          }

          queryPending = true;
          try {
            do {
              needsRefresh = false;
              await emitLatest();
            } while (needsRefresh && !controller.isClosed);
          } catch (e, st) {
            if (!controller.isClosed) {
              controller.addError(e, st);
            }
          } finally {
            queryPending = false;
          }
        },
      );
    }

    emitLatest = () async {
      final snapshot = await loadSnapshot();
      scheduleRefresh(snapshot.nextRefreshAt);
      final shouldEmit =
          !distinct || !hasEmitted || snapshot.fingerprint != lastFingerprint;

      hasEmitted = true;
      lastFingerprint = snapshot.fingerprint;

      if (shouldEmit && !controller.isClosed) {
        controller.add(snapshot.value);
      }
    };

    controller = StreamController<T>(
      onListen: () async {
        try {
          await ensureInitialized();
          await emitLatest();
        } catch (e, st) {
          if (!controller.isClosed) {
            controller.addError(e, st);
          }
        }

        if (controller.isClosed) {
          return;
        }

        subscription = notificationManager.register(
          tableName,
          condition,
          (event) async {
            if (queryPending) {
              needsRefresh = true;
              return;
            }

            queryPending = true;
            try {
              do {
                needsRefresh = false;
                await emitLatest();
              } while (needsRefresh && !controller.isClosed);
            } catch (e, st) {
              if (!controller.isClosed) {
                controller.addError(e, st);
              }
            } finally {
              queryPending = false;
            }
          },
        );
      },
      onCancel: () async {
        refreshTimer?.cancel();
        await subscription?.cancel();
      },
    );

    return controller.stream;
  }

  DateTime? _parseKvDateTime(dynamic rawValue) {
    if (rawValue == null) {
      return null;
    }
    if (rawValue is DateTime) {
      return rawValue;
    }
    if (rawValue is String) {
      final value = rawValue.trim();
      if (value.isEmpty) {
        return null;
      }
      try {
        return DateTime.parse(value);
      } catch (_) {
        return null;
      }
    }
    if (rawValue is int) {
      try {
        return DateTime.fromMillisecondsSinceEpoch(rawValue);
      } catch (_) {
        return null;
      }
    }
    if (rawValue is BigInt) {
      try {
        return DateTime.fromMillisecondsSinceEpoch(rawValue.toInt());
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  bool _isKvRowExpired(Map<String, dynamic> row, {DateTime? now}) {
    final expiresAt = _parseKvDateTime(row[_kvExpiresAtField]);
    if (expiresAt == null) {
      return false;
    }
    final referenceTime = now ?? DateTime.now();
    return !expiresAt.isAfter(referenceTime);
  }

  void _scheduleExactExpiredKvCleanup(
    String tableName,
    String key,
    dynamic rawExpiresAt,
  ) {
    final expiresAtIso = _parseKvDateTime(rawExpiresAt)?.toIso8601String();
    if (expiresAtIso == null) {
      return;
    }
    unawaited(_deleteExpiredKvRecordExact(
      tableName,
      key: key,
      expiresAtIso: expiresAtIso,
    ));
  }

  Future<void> _deleteExpiredKvRecordExact(
    String tableName, {
    required String key,
    required String expiresAtIso,
  }) async {
    try {
      final condition = QueryCondition()
        ..where(_kvKeyField, '=', key)
        ..where(_kvExpiresAtField, '=', expiresAtIso);
      await deleteInternal(tableName, condition, limit: 1);
    } catch (e) {
      Logger.warn(
        'Failed to cleanup expired kv key "$key" in $tableName: $e',
        label: 'DataStore._deleteExpiredKvRecordExact',
      );
    }
  }

  dynamic _decodeStoredKeyValue(dynamic rawValue, {required String key}) {
    if (rawValue == null) {
      return null;
    }

    try {
      final encodedValue = rawValue is String ? rawValue : rawValue.toString();
      return jsonDecode(encodedValue);
    } catch (e) {
      Logger.warn(
          'Failed to parse value for key "$key" as JSON. Returning raw value. This may indicate that the value was not set using `setValue`. Error: $e',
          label: 'DataStore.getValue');
      return rawValue;
    }
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

  Future<void> setTableTtlConfig(
    String tableName,
    TableTtlConfig? ttlConfig, {
    TableTtlConfig? previousTtlConfig,
    bool updateSchema = true,
    bool syncIndexes = true,
  }) async {
    final schema = await schemaManager?.getTableSchema(tableName);
    if (schema == null) {
      throw BusinessError(
        'Table $tableName not found',
        type: BusinessErrorType.schemaError,
      );
    }

    final schemaChanged = !_isTtlConfigEquivalent(schema.ttlConfig, ttlConfig);
    if (!schemaChanged && !syncIndexes) {
      return;
    }

    var updatedSchema =
        schemaChanged ? _copySchemaWithTtlConfig(schema, ttlConfig) : schema;

    final reservedSystemTableNames = SystemTable.knownSystemTableNames;
    final bool isSystemTableName = SystemTable.isKnownSystemTable(tableName);
    final bool allowSystemSchema =
        isSystemTableName && TransactionContext.isSystemOperation();

    if (!updatedSchema.validateTableSchema(
      reservedTableNames: reservedSystemTableNames,
      allowReservedTableNames: allowSystemSchema,
      allowInternalTableNamePrefix: allowSystemSchema,
      allowOtherInternalFields: allowSystemSchema,
    )) {
      throw BusinessError(
        'Invalid TTL configuration for table $tableName',
        type: BusinessErrorType.schemaError,
      );
    }

    if (updateSchema && schemaChanged) {
      await schemaManager?.saveTableSchema(tableName, updatedSchema);
    }

    if (!syncIndexes) {
      return;
    }

    final oldSchemaForCoverage = previousTtlConfig != null
        ? _copySchemaWithTtlConfig(schema, previousTtlConfig)
        : schema;

    final oldSourceField =
        _resolveTtlSourceField(previousTtlConfig ?? schema.ttlConfig);
    final newSourceField = _resolveTtlSourceField(updatedSchema.ttlConfig);

    final oldSchemaIndexes = oldSchemaForCoverage.getAllIndexes();
    final newSchemaIndexes = updatedSchema.getAllIndexes();

    if (oldSourceField != null && oldSourceField != newSourceField) {
      final stillCovered = newSchemaIndexes.any(
        (i) => i.fields.isNotEmpty && i.fields.first == oldSourceField,
      );
      if (!stillCovered) {
        await indexManager?.removeIndex(tableName, indexName: oldSourceField);
      }
    }

    if (newSourceField != null && newSourceField != oldSourceField) {
      final existedBefore = oldSchemaIndexes.any(
        (i) => i.fields.isNotEmpty && i.fields.first == newSourceField,
      );
      if (!existedBefore) {
        await indexManager?.createIndex(
          tableName,
          IndexSchema(indexName: newSourceField, fields: [newSourceField]),
        );
      }
    }

    if (newSourceField != null) {
      await indexManager?.createIndex(
        tableName,
        IndexSchema(indexName: newSourceField, fields: [newSourceField]),
      );
    }
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

    final indexesToRemove = schema
        .getAllIndexes()
        .where((index) => index.fields.contains(fieldName))
        .toList(growable: false);
    for (final index in indexesToRemove) {
      await indexManager?.removeIndex(tableName,
          indexName: index.actualIndexName);
    }

    // Remove field from schema
    final newFields = schema.fields.where((f) => f.name != fieldName).toList();
    final newIndexes = schema.indexes
        .where((index) => !index.fields.contains(fieldName))
        .toList(growable: false);
    final newSchema = schema.copyWith(fields: newFields, indexes: newIndexes);

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

      final indexes = schema.indexes
          .map((index) => index.copyWith(
                fields: index.fields
                    .map((field) => field == oldName ? newName : field)
                    .toList(growable: false),
              ))
          .toList(growable: false);

      final newSchema = schema.copyWith(fields: fields, indexes: indexes);
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

  /// Rename table storage and metadata as part of a migration task.
  ///
  /// This is intentionally more conservative than normal write paths:
  /// it flushes pending writes first, then moves the physical table directory,
  /// rewrites directory/schema metadata, and finally refreshes dependent caches.
  Future<void> renameTableForMigration(
    String oldTableName,
    String newTableName, {
    TableSchema? oldSchemaSnapshot,
    bool updateSchema = true,
    bool refreshForeignKeySystemTables = true,
  }) async {
    if (oldTableName == newTableName) {
      return;
    }

    final schemaMgr = schemaManager;
    final dirMgr = directoryManager;
    if (schemaMgr == null || dirMgr == null) {
      throw StateError('Database managers are not initialized');
    }

    final existingOldSchema =
        oldSchemaSnapshot ?? await schemaMgr.getTableSchema(oldTableName);
    final existingNewSchema = await schemaMgr.getTableSchema(newTableName);
    if (updateSchema &&
        existingOldSchema != null &&
        existingNewSchema != null &&
        oldTableName != newTableName) {
      throw StateError(
        'Cannot rename table $oldTableName -> $newTableName: target table already exists',
      );
    }
    final schemaForLayout = existingOldSchema ?? existingNewSchema;
    if (schemaForLayout == null) {
      throw StateError(
        'Cannot rename table $oldTableName -> $newTableName: schema not found',
      );
    }

    final isGlobal = schemaForLayout.isGlobal;
    final renamedSchema = _schemaWithRenamedReferencedTable(
      schemaForLayout.copyWith(name: newTableName),
      oldTableName,
      newTableName,
    );

    await flush();

    await cacheManager.invalidateCache(oldTableName, invalidateSchema: false);
    await cacheManager.invalidateCache(newTableName, invalidateSchema: false);

    final oldDirInfo =
        await dirMgr.getTableDirectoryInfo(oldTableName, isGlobal);
    final newDirInfo =
        await dirMgr.getTableDirectoryInfo(newTableName, isGlobal);
    final oldPath = await dirMgr.getTableDirectoryPathByScope(
      oldTableName,
      isGlobal: isGlobal,
    );
    String? newPath = await dirMgr.getTableDirectoryPathByScope(
      newTableName,
      isGlobal: isGlobal,
    );
    final resolvedDirIndex = oldDirInfo?.dirIndex ?? newDirInfo?.dirIndex;
    if (newPath == null && resolvedDirIndex != null) {
      newPath = dirMgr.buildTableDirectoryPath(
        newTableName,
        isGlobal: isGlobal,
        dirIndex: resolvedDirIndex,
      );
    }

    final sourceExists =
        oldPath != null && await storage.existsDirectory(oldPath);
    final targetExists =
        newPath != null && await storage.existsDirectory(newPath);
    final updatedReferencingTables = <String>{};

    try {
      if (sourceExists && newPath != null && oldPath != newPath) {
        if (targetExists) {
          throw StateError(
            'Cannot rename table $oldTableName -> $newTableName: destination directory already exists',
          );
        }
        await storage.moveDirectory(oldPath, newPath);
      }

      final mappingRenamed = await dirMgr.renameTableDirectoryMapping(
        oldTableName,
        newTableName,
        isGlobal: isGlobal,
      );
      if (!mappingRenamed) {
        throw StateError(
          'Cannot rename table $oldTableName -> $newTableName: directory mapping not found',
        );
      }

      if (updateSchema && existingOldSchema != null) {
        await schemaMgr.renameTableSchema(oldTableName, renamedSchema);
        await _updateSchemasReferencingRenamedTable(
          oldTableName,
          newTableName,
          updatedTables: updatedReferencingTables,
        );
      }

      await _rewriteMovedTableMetadataAfterRename(
        newTableName,
        schemaForLayout,
      );

      if (refreshForeignKeySystemTables) {
        await _refreshForeignKeyMetadataAfterRename(
          oldTableName,
          newTableName,
          referencingTables: updatedReferencingTables,
          throwOnError: true,
        );
      }
    } catch (error, stackTrace) {
      try {
        await _rollbackRenameTableForMigration(
          oldTableName,
          newTableName,
          isGlobal: isGlobal,
          schemaForLayout: schemaForLayout,
          existingOldSchema: existingOldSchema,
          updateSchema: updateSchema,
          refreshForeignKeySystemTables: refreshForeignKeySystemTables,
          updatedReferencingTables: updatedReferencingTables,
          oldPath: oldPath,
          newPath: newPath,
        );
      } catch (rollbackError, rollbackStackTrace) {
        Logger.error(
          'Failed to rollback table rename $oldTableName -> $newTableName after error: $rollbackError\n$rollbackStackTrace',
          label: 'DataStoreImpl.renameTableForMigration',
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }

    _pathManager?.clearTableCache(oldTableName);
    _pathManager?.clearTableCache(newTableName);
    await cacheManager.invalidateCache(oldTableName);
    await cacheManager.invalidateCache(newTableName);
  }

  Future<void> _rollbackRenameTableForMigration(
    String oldTableName,
    String newTableName, {
    required bool isGlobal,
    required TableSchema schemaForLayout,
    required TableSchema? existingOldSchema,
    required bool updateSchema,
    required bool refreshForeignKeySystemTables,
    required Set<String> updatedReferencingTables,
    String? oldPath,
    String? newPath,
  }) async {
    final schemaMgr = schemaManager;
    final dirMgr = directoryManager;
    if (schemaMgr == null || dirMgr == null) {
      throw StateError('Database managers are not initialized');
    }

    final rollbackSchema = existingOldSchema ??
        _schemaWithRenamedReferencedTable(
          schemaForLayout.copyWith(name: oldTableName),
          newTableName,
          oldTableName,
        );

    if (updateSchema && updatedReferencingTables.isNotEmpty) {
      await _updateSchemasReferencingRenamedTable(
        newTableName,
        oldTableName,
        candidateTables: updatedReferencingTables,
      );
    }

    if (updateSchema) {
      final currentOldSchema = await schemaMgr.getTableSchema(oldTableName);
      final currentNewSchema = await schemaMgr.getTableSchema(newTableName);
      if (currentOldSchema == null && currentNewSchema != null) {
        await schemaMgr.renameTableSchema(newTableName, rollbackSchema);
      }
    }

    final currentOldDirInfo =
        await dirMgr.getTableDirectoryInfo(oldTableName, isGlobal);
    final currentNewDirInfo =
        await dirMgr.getTableDirectoryInfo(newTableName, isGlobal);
    if (currentOldDirInfo == null && currentNewDirInfo != null) {
      final restored = await dirMgr.renameTableDirectoryMapping(
        newTableName,
        oldTableName,
        isGlobal: isGlobal,
      );
      if (!restored) {
        throw StateError(
          'Failed to restore directory mapping for table $oldTableName during rollback',
        );
      }
    }

    if (oldPath != null && newPath != null && oldPath != newPath) {
      final oldExists = await storage.existsDirectory(oldPath);
      final newExists = await storage.existsDirectory(newPath);
      if (!oldExists && newExists) {
        await storage.moveDirectory(newPath, oldPath);
      }
    }

    _pathManager?.clearTableCache(oldTableName);
    _pathManager?.clearTableCache(newTableName);
    await cacheManager.invalidateCache(oldTableName, invalidateSchema: false);
    await cacheManager.invalidateCache(newTableName, invalidateSchema: false);

    final restoredSchema = await schemaMgr.getTableSchema(oldTableName);
    if (restoredSchema != null) {
      await _rewriteMovedTableMetadataAfterRename(
        oldTableName,
        rollbackSchema,
      );
    }

    if (refreshForeignKeySystemTables && updateSchema) {
      await _refreshForeignKeyMetadataAfterRename(
        newTableName,
        oldTableName,
        referencingTables: updatedReferencingTables,
        throwOnError: true,
      );
    }
  }

  TableSchema _schemaWithRenamedReferencedTable(
    TableSchema schema,
    String oldTableName,
    String newTableName,
  ) {
    var changed = false;
    final updatedForeignKeys = schema.foreignKeys.map((fk) {
      if (fk.referencedTable != oldTableName) {
        return fk;
      }
      changed = true;
      return fk.copyWith(referencedTable: newTableName);
    }).toList(growable: false);

    if (!changed) {
      return schema;
    }
    return schema.copyWith(foreignKeys: updatedForeignKeys);
  }

  Future<void> _updateSchemasReferencingRenamedTable(
      String oldTableName, String newTableName,
      {Iterable<String>? candidateTables, Set<String>? updatedTables}) async {
    final schemaMgr = schemaManager;
    if (schemaMgr == null) {
      return;
    }

    final tablesToScan = candidateTables ?? await schemaMgr.listAllTables();

    for (final tableName in tablesToScan) {
      if (tableName == newTableName) continue;

      final schema = await schemaMgr.getTableSchema(tableName);
      if (schema == null) {
        continue;
      }

      final updatedSchema = _schemaWithRenamedReferencedTable(
        schema,
        oldTableName,
        newTableName,
      );
      if (identical(updatedSchema, schema)) {
        continue;
      }
      await schemaMgr.saveTableSchema(tableName, updatedSchema);
      updatedTables?.add(tableName);
    }
  }

  Future<void> _rewriteMovedTableMetadataAfterRename(
    String tableName,
    TableSchema schemaForLayout,
  ) async {
    final currentTableMeta = await tableDataManager.getTableMeta(tableName);
    if (currentTableMeta != null && currentTableMeta.name != tableName) {
      await tableDataManager.updateTableMeta(
        tableName,
        currentTableMeta.copyWith(name: tableName),
      );
    }

    final btreeIndexes =
        schemaManager?.getBtreeIndexesFor(schemaForLayout) ?? <IndexSchema>[];
    for (final index in btreeIndexes) {
      final indexMeta =
          await indexManager?.getIndexMeta(tableName, index.actualIndexName);
      if (indexMeta == null || indexMeta.tableName == tableName) {
        continue;
      }
      await indexManager?.updateIndexMeta(
        tableName: tableName,
        indexName: index.actualIndexName,
        updatedMeta: indexMeta.copyWith(tableName: tableName),
      );
    }

    final vectorIndexes =
        schemaManager?.getVectorIndexesFor(schemaForLayout) ?? <IndexSchema>[];
    for (final index in vectorIndexes) {
      final metaPath =
          await pathManager.getNghMetaPath(tableName, index.actualIndexName);
      if (!await storage.existsFile(metaPath)) {
        continue;
      }

      final content = await storage.readAsString(metaPath);
      if (content == null || content.isEmpty) {
        continue;
      }

      final json = jsonDecode(content);
      if (json is! Map) {
        continue;
      }

      final meta = NghIndexMeta.fromJson(Map<String, dynamic>.from(json));
      final updatedMeta = meta.copyWith(
        tableName: tableName,
        nodeIdToPkMeta: meta.nodeIdToPkMeta?.copyWith(tableName: tableName),
        pkToNodeIdMeta: meta.pkToNodeIdMeta?.copyWith(tableName: tableName),
      );

      if (updatedMeta.tableName == meta.tableName &&
          updatedMeta.nodeIdToPkMeta?.tableName ==
              meta.nodeIdToPkMeta?.tableName &&
          updatedMeta.pkToNodeIdMeta?.tableName ==
              meta.pkToNodeIdMeta?.tableName) {
        continue;
      }

      await storage.writeAsString(metaPath, jsonEncode(updatedMeta.toJson()));

      if (updatedMeta.nodeIdToPkMeta != null) {
        await indexManager?.updateIndexMeta(
          tableName: tableName,
          indexName: updatedMeta.nid2pkIndexName,
          updatedMeta: updatedMeta.nodeIdToPkMeta,
        );
      }
      if (updatedMeta.pkToNodeIdMeta != null) {
        await indexManager?.updateIndexMeta(
          tableName: tableName,
          indexName: updatedMeta.pk2nidIndexName,
          updatedMeta: updatedMeta.pkToNodeIdMeta,
        );
      }
    }
  }

  Future<void> _refreshForeignKeyMetadataAfterRename(
    String oldTableName,
    String newTableName, {
    Iterable<String> referencingTables = const <String>[],
    bool throwOnError = false,
  }) async {
    final fkManager = foreignKeyManager;
    final schemaMgr = schemaManager;
    if (fkManager == null || schemaMgr == null) {
      return;
    }

    final tablesToRefresh = <String>{newTableName};
    tablesToRefresh.addAll(referencingTables);

    final schemasToRefresh = <String, TableSchema>{};
    for (final tableName in tablesToRefresh) {
      final schema = await schemaMgr.getTableSchema(tableName);
      if (schema != null) {
        schemasToRefresh[tableName] = schema;
      }
    }

    final requiresRefresh = referencingTables.isNotEmpty ||
        schemasToRefresh.values.any((schema) => schema.foreignKeys.isNotEmpty);
    await fkManager.cleanupSystemTableForDroppedTable(
      oldTableName,
      throwOnError: throwOnError,
    );

    if (!requiresRefresh) {
      return;
    }

    for (final entry in schemasToRefresh.entries) {
      await fkManager.updateSystemTableForTable(
        entry.key,
        entry.value,
        throwOnError: throwOnError,
      );
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

  /// Get information about the current space
  Future<SpaceInfo> getSpaceInfo({bool useCache = true}) async {
    try {
      // Get space configuration
      var config = await getSpaceConfig();

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

      final spacePrefix = '$_currentSpaceName:';
      final userTables = (config?.tableDirectoryMap.keys ?? const <String>[])
          .where((tableKey) => tableKey.startsWith(spacePrefix))
          .map((tableKey) => tableKey.substring(spacePrefix.length))
          .where((tableName) => !SystemTable.isSystemTable(tableName))
          .toList(growable: false);

      // Create the SpaceInfo object with user-table information
      return SpaceInfo(
        spaceName: _currentSpaceName,
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

  /// List all space names (e.g. for multi-account UI or admin).
  /// Returns sorted list; at least contains 'default'.
  Future<List<String>> listSpaces() async {
    await ensureInitialized();
    final globalConfig = await getGlobalConfig();
    if (globalConfig == null || globalConfig.spaceNames.isEmpty) {
      return ['default'];
    }
    final list = List<String>.from(globalConfig.spaceNames)..sort();
    return list;
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
  /// [isUpdate] - When true, [Expr.isUpdate]/[Expr.isInsert] resolve accordingly.
  ///
  /// Returns the computed value.
  ///
  /// Throws [ArgumentError] if a field reference is invalid or field doesn't exist.
  dynamic _evaluateExpression(
    ExprNode expression,
    Map<String, dynamic> record,
    TableSchema schema, {
    bool isUpdate = false,
  }) {
    final validFieldNames = <String>{
      ...schema.fields.map((f) => f.name),
      schema.primaryKey,
    };
    return _evaluateExprNode(
      expression,
      record,
      validFieldNames,
      isUpdate: isUpdate,
    );
  }

  static bool _toBool(dynamic v) {
    if (v == null) return false;
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) return v.isNotEmpty;
    return true;
  }

  /// Recursively evaluates an expression node.
  ///
  /// [isUpdate] - Used by IsUpdate/IsInsert; true when the operation is update.
  dynamic _evaluateExprNode(
    ExprNode node,
    Map<String, dynamic> record,
    Set<String> validFieldNames, {
    bool isUpdate = false,
  }) {
    if (node is IsUpdate) {
      return isUpdate;
    } else if (node is IsInsert) {
      return !isUpdate;
    } else if (node is IfElse) {
      final cond = _evaluateExprNode(
        node.condition,
        record,
        validFieldNames,
        isUpdate: isUpdate,
      );
      final branch = _toBool(cond) ? node.thenValue : node.elseValue;
      if (branch is ExprNode) {
        return _evaluateExprNode(
          branch,
          record,
          validFieldNames,
          isUpdate: isUpdate,
        );
      }
      return branch;
    } else if (node is When) {
      final cond = _evaluateExprNode(
        node.condition,
        record,
        validFieldNames,
        isUpdate: isUpdate,
      );
      if (_toBool(cond)) {
        final v = node.value;
        if (v is ExprNode) {
          return _evaluateExprNode(
            v,
            record,
            validFieldNames,
            isUpdate: isUpdate,
          );
        }
        return v;
      }
      final o = node.otherwise;
      if (o is ExprNode) {
        return _evaluateExprNode(
          o,
          record,
          validFieldNames,
          isUpdate: isUpdate,
        );
      }
      return o;
    } else if (node is TimestampExpr) {
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
      final left = _evaluateExprNode(
        node.left,
        record,
        validFieldNames,
        isUpdate: isUpdate,
      );
      final right = _evaluateExprNode(
        node.right,
        record,
        validFieldNames,
        isUpdate: isUpdate,
      );

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
      final operand = _evaluateExprNode(
        node.operand,
        record,
        validFieldNames,
        isUpdate: isUpdate,
      );

      switch (node.op) {
        case UnaryOperator.negate:
          return -operand;
        case UnaryOperator.abs:
          return operand.abs();
      }
    } else if (node is FunctionCall) {
      final args = node.arguments
          .map((arg) => _evaluateExprNode(
                arg,
                record,
                validFieldNames,
                isUpdate: isUpdate,
              ))
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
    if (_db._resourceManager == null) {
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
        totalUsageBytes: 0,
        isLowMemoryMode: false,
      );
    }
    return await _db._resourceManager!.getMemoryInfo();
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
      isMemoryManaged: _db._resourceManager != null,
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
