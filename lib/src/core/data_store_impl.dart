import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as path;

import '../handler/common.dart';
import '../handler/global_config_codec.dart';
import '../handler/logger.dart';
import '../handler/parallel_processor.dart';
import '../handler/platform_handler.dart';
import '../handler/value_matcher.dart';
import '../interface/kv_store.dart';
import '../interface/noop_storage_impl.dart';
import '../interface/status_provider.dart';
import '../model/backup_scope.dart';
import '../model/buffer_entry.dart';
import '../model/cancellation_token.dart';
import '../model/change_event.dart';
import '../model/config_info.dart';
import '../model/data_store_config.dart';
import '../model/db_exception.dart';
import '../model/db_result.dart';
import '../model/db_startup_stage.dart';
import '../model/expr.dart';
import '../model/foreign_key_operation.dart';
import '../model/global_config.dart';
import '../model/id_generator.dart';
import '../model/memory_info.dart';
import '../model/migration_task.dart';
import '../model/query_result.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/space_info.dart';
import '../model/space_stats.dart';
import '../model/system_table.dart';
import '../model/table_context.dart';
import '../model/table_identity.dart';
import '../model/table_info.dart';
import '../model/table_meta.dart';
import '../model/table_op_meta.dart';
import '../model/table_schema.dart';
import '../model/transaction_result.dart';
import '../model/unique_violation.dart';
import '../query/query_condition.dart';
import '../query/query_executor.dart';
import '../query/query_optimizer.dart';
import '../upgrades/legacy_model/pre_v3.dart';
import '../upgrades/old_structure_migration_handler.dart';
import '../upgrades/version_upgrade_manager.dart';
import 'background_write_scheduler.dart';
import 'backup_manager.dart';
import 'cache_manager.dart';
import 'compaction_manager.dart';
import 'compute/batch_identifier_compute.dart';
import 'compute/batch_insert_compute.dart';
import 'compute/batch_update_compute.dart';
import 'compute/compute_batch_planner.dart';
import 'compute/kv_batch_prepare_compute.dart';
import 'compute/record_compute.dart';
import 'compute_manager.dart';
import 'cpu_work_chunk.dart';
import 'crontab_manager.dart';
import 'foreign_key_manager.dart';
import 'index_manager.dart';
import 'index_tree_partition_manager.dart';
import 'integrity_checker.dart';
import 'internal_kv_store.dart';
import 'key_manager.dart';
import 'large_operation_runner.dart';
import 'lock_manager.dart';
import 'migration_manager.dart';
import 'notification_manager.dart';
import 'overflow_manager.dart';
import 'parallel_journal_manager.dart';
import 'path_manager.dart';
import 'promote_primary_key.dart';
import 'read_view_manager.dart';
import 'resource_manager.dart';
import 'shared_engine_registry.dart';
import 'storage_adapter.dart';
import 'table_data_manager.dart';
import 'table_meta_manager.dart';
import 'table_tree_partition_manager.dart';
import 'transaction_context.dart';
import 'transaction_manager.dart';
import 'tree_meta_page_service.dart';
import 'ttl_cleanup_manager.dart';
import 'vector_index_manager.dart';
import 'wal_manager.dart';
import 'weight_manager.dart';
import 'workload_scheduler.dart';
import 'write_buffer_manager.dart';
import 'yield_controller.dart';

/// Core storage engine implementation
class DataStoreImpl {
  static final Map<String, DataStoreImpl> _instances = {};

  static const String _kvKeyField = SystemTable.keyValueKeyField;
  static const String _kvValueField = SystemTable.keyValueValueField;
  static const String _kvUpdatedAtField = SystemTable.keyValueUpdatedAtField;
  static const String _kvExpiresAtField = SystemTable.keyValueExpiresAtField;
  Completer<void> _initCompleter = Completer<void>();
  bool _isInitialized = false;
  bool _initializing = false;

  /// Set at the start of [close]; cleared when [initialize] begins.
  /// Used by best-effort paths (SpaceStats) to skip InternalKv during teardown.
  bool _closing = false;
  StartupProgressCallback? _startupProgressCallback;
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

  /// True after KeyManager/base engine wiring is ready, before full open.
  ///
  /// Internal recovery (schema migration, WAL-adjacent work) may run while this
  /// is true and [isInitialized] is still false. [close] clears both flags.
  bool get isBaseInitialized => _baseInitialized;

  /// True from [close] entry until the next [initialize] starts.
  ///
  /// Best-effort modules (SpaceStats) must not touch InternalKv while this is
  /// true. Durable InternalKv writers should finish before close or during the
  /// ordered close flush while managers are still alive.
  bool get isClosing => _closing;

  final bool isMigrationInstance;

  CancellationToken _globalQueryCancelToken = CancellationToken();
  CancellationToken get globalQueryCancelToken => _globalQueryCancelToken;

  // Global prewarming state (centralized)
  bool _isGlobalPrewarming = false;
  bool get isGlobalPrewarming => _isGlobalPrewarming;

  /// In-flight cache prewarm task. Close/switchSpace awaits this after cancel
  /// so full-table scans cannot race storage handle teardown.
  Future<void>? _prewarmFuture;

  /// True when long-running leaf scans should stop (close / switchSpace /
  /// global query cancel). Checked on each leaf page boundary.
  ///
  /// Do NOT gate on [isInitialized]: setup/migration/recovery scan table and
  /// index leaves before `_isInitialized` flips true. Aborting those scans
  /// silently yields empty results and breaks schema migration tests.
  bool get shouldAbortBackgroundScan =>
      _closing || _globalQueryCancelToken.isCancelled;

  // Global configuration cache
  GlobalConfig? _globalConfigCache;

  /// Engine version last successfully written to the downgrade-guard JSON stub.
  /// Process-local: avoids rewriting on every [saveGlobalConfig].
  int? _downgradeGuardJsonVersion;

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
  TableMetaManager? tableMetaManager;
  PathManager? _pathManager;
  LockManager? lockManager;
  TransactionManager? transactionManager;
  ResourceManager? _resourceManager;

  /// Key-value storage namespace
  late final KvStore kv = KvStore(this);

  /// Engine-internal key-value store (not user-facing).
  late final InternalKvStore internalKv = InternalKvStore(this);

  // Transaction zone key
  static const Symbol _txnZoneKey = #to_txn_zone;
  // Whether to rollback on DbResult error inside a transaction
  static const Symbol _txnRollbackOnErrorKey = #to_txn_rollback_on_error;

  KeyManager get keyManager {
    if (_keyManager == null) {
      throw DbClosedException();
    }
    return _keyManager!;
  }

  IntegrityChecker? get integrityChecker => _integrityChecker;

  PathManager get pathManager {
    if (_pathManager == null) {
      throw DbClosedException();
    }
    return _pathManager!;
  }

  /// Engine-managed directory sharding parameter (persisted in `global_config.tobf`).
  ///
  /// Used for deterministic sharding: `dirIndex = pIndex ~/ maxEntriesPerDir`.
  int get maxEntriesPerDir => (_globalConfigCache?.maxEntriesPerDir ??
      InternalConfig.defaultMaxEntriesPerDir);

  /// Fixed B+Tree / NGH page size for this database (from [GlobalConfig.pageSize]).
  ///
  /// Immutable after first persist / v3 upgrade. Falls back to
  /// [InternalConfig.defaultPageSize] when GlobalConfig is not loaded or when
  /// legacy configs still carry `pageSize == 0` (unset). Note: `??` alone is
  /// insufficient - a loaded cache with pageSize 0 must also fall back.
  int get configuredPageSize {
    final ps = _globalConfigCache?.pageSize ?? 0;
    return ps > 0 ? ps : InternalConfig.defaultPageSize;
  }

  /// True when [GlobalConfig.pageSize] has been persisted for this database.
  ///
  /// Uses `?? 0` (not defaultPageSize): unset must stay distinguishable from a
  /// real configured value so v3 upgrade can sample and write pageSize once.
  bool get hasConfiguredPageSize => (_globalConfigCache?.pageSize ?? 0) > 0;

  TableDataManager? _tableDataManager;
  TableDataManager get tableDataManager {
    if (_tableDataManager == null) {
      throw DbClosedException();
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
  late BackgroundWriteScheduler backgroundWriteScheduler;
  TableTreePartitionManager? tableTreePartitionManager;
  IndexTreePartitionManager? indexTreePartitionManager;
  TreeMetaPageService? _treeMetaPageService;

  /// Unified partition page-0 read/write (global meta + local stats).
  TreeMetaPageService get treeMetaPageService {
    if (_treeMetaPageService == null) {
      throw DbClosedException();
    }
    return _treeMetaPageService!;
  }

  /// Global workload scheduler for centralized concurrency budgeting.
  late WorkloadScheduler workloadScheduler;

  late NotificationManager notificationManager;

  /// Read view manager: tracks active queries to determine buffer delay cleanup boundaries
  late ReadViewManager readViewManager;

  /// Background compaction manager (budgeted, queue-based).
  late CompactionManager compactionManager;

  /// Out-of-line large value store (TOAST-like).
  late OverflowManager overflowManager;

  /// If inside a transaction and rollbackOnError=true, throw DbException on non-success DbResult
  DbResult _returnOrThrowIfTxn(
      DbResult result, String operation, String tableName) {
    final String? txId = Zone.current[_txnZoneKey] as String?;
    if (txId == null) return result;
    tableDataManager.ensureTransactionWithinResourceLimits(txId);
    final bool rollbackOnError =
        Zone.current[_txnRollbackOnErrorKey] as bool? ?? true;
    if (!rollbackOnError) return result;
    if (result.hasErrors) {
      final List<ResultStatus> statuses = result.statuses.isNotEmpty
          ? result.statuses
          : [
              TransactionOperationStatus(
                type: ResultType.sysTransactionAborted,
                message:
                    'Transaction operation failed: $operation on $tableName',
                txId: txId,
              ),
            ];
      throw DbException(statuses);
    }
    return result;
  }

  /// Normalize cascade operation errors to appropriate ResultType
  ///
  DbResult _normalizeCascadeError(
    dynamic error,
    String operation, // 'update', 'delete', or 'clear'
  ) {
    if (error is DbException) {
      return DbResult.batch(
        statuses: error.statuses,
        failedCount: error.statuses.length,
      );
    }

    return DbResult.error(
      type: ResultType.engError,
      message: 'Cascade $operation failed: ${error.toString()}',
    );
  }

  /// Whether [e] is a missing-table developer error from [getTableContext].
  bool _isDevTableNotFound(Object e) {
    return e is DbException &&
        e.statuses.any((s) => s.type == ResultType.devTableNotFound);
  }

  /// FK RESTRICT/NO ACTION rejects clear/drop before any child mutation.
  bool _isFkRestrictBeforeMutation(Object e) {
    return e is DbException &&
        e.statuses.any((s) => s.type == ResultType.bizForeignKeyChildRestrict);
  }

  /// Drop a pending clear/drop WAL table-op that never took effect.
  Future<void> _abortRegisteredTableOp(String? opId) async {
    if (opId == null || !config.enableJournal) return;
    try {
      await walManager.abortTableOp(opId);
    } catch (e) {
      Logger.warn('Abort table op failed', rawError: e);
    }
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

  /// Generate a globally unique resource key for LockManager including space and db context.
  String getScopedResourceKey(String resource) {
    if (instancePath == null) return resource;
    // Use path.join to maintain hierarchical locking properties for directory-like resources.
    return path.join(instancePath!, _currentSpaceName, resource);
  }

  /// Get query optimizer
  QueryOptimizer? getQueryOptimizer() => _queryOptimizer;

  /// Get query executor
  QueryExecutor? getQueryExecutor() => _queryExecutor;

  /// Non-null query executor accessor (internal use).
  QueryExecutor get queryExecutor {
    final qe = _queryExecutor;
    if (qe == null) {
      throw DbClosedException();
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

  void removeTtlPlanForTable(TableContext table) {
    _ttlCleanupManager.removePlanForTable(table);
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
      throw DbClosedException();
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

  /// Space aggregates - owned by [TableDataManager] (InternalKv + live deltas).
  Future<SpaceStats> getSpaceStats() => tableDataManager.getSpaceStats();

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
  ///
  /// After [close] resets [_initCompleter] with nothing initializing, waiting
  /// would hang forever - throw [DbClosedException] instead.
  Future<void> ensureInitialized() async {
    // Check if this is a system/internal operation (e.g., updating system tables during table creation)
    final isSystemOp = TransactionContext.isSystemOperation();

    // For system operations during initialization, allow if base initialization is complete
    // This is needed for operations like foreign key system table updates during table creation
    if (isSystemOp && _initializing) {
      return;
    }

    // Migration instance might share LockManager/Scheduler, ensure it's "initialized"
    // even if it bypasses full DSI initialization.
    if (isMigrationInstance && _baseInitialized) {
      return;
    }

    if (_isInitialized) return;

    // Close finished (or not yet opened): Completer is incomplete and nobody
    // is running initialize - never park on that future.
    if (!_initializing && !_initCompleter.isCompleted) {
      throw DbClosedException();
    }

    // Mid-close: flags cleared but previous Completer still completed - do not
    // await; callers in the close flush window proceed (managers may still
    // exist). Late work after Completer reset hits the branch above.
    if (!_initCompleter.isCompleted) {
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
        throw DbException([
          InvalidArgumentStatus(
            type: ResultType.devInvalidArgumentMissing,
            message:
                'On mobile platforms (Android/iOS ...), dbPath is required. Please inject a persistent app directory path via ToStore(dbPath: ...) or DataStoreConfig(dbPath: ...). See example/mobile_quickstart.dart',
            parameterName: 'dbPath',
            passedValue: null,
          ),
        ]);
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
      bool applyActiveSpaceOnDefault = false,
      StartupProgressCallback? onStartupProgress}) async {
    if (onStartupProgress != null) {
      _startupProgressCallback = onStartupProgress;
    }
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
    _closing = false;
    _startupProgressCallback?.call(0.0, DbStartupStage.opening);
    try {
      if (_config != null && (reinitialize || _isInitialized)) {
        // Always close the underlying storage when we are about to rebuild
        // managers + StorageAdapter below. Leaving it open leaks handle pools
        await close(
            persistChanges: !noPersistOnClose,
            closeStorage: true,
            removeRegistry: false);
        // close() clears _initializing and resets _initCompleter; restore so
        // mid-init system ops do not hit DbClosedException from ensureInitialized.
        _initializing = true;
        _closing = false;
      }
      _globalQueryCancelToken = CancellationToken();
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

      // Initialize YieldController global limit
      YieldController.globalSettings.enabled = true;
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

      // Initialize GlobalIdGenerator with the distributed node id from the config
      GlobalIdGenerator.initialize(_config!.distributedNodeConfig.nodeId);

      if (PlatformHandler.isWeb && _config!.enableJournal) {
        Logger.warn(
          'Web does not support enableJournal efficiently. Keeping it on can noticeably slow writes and startup. Recommended: set DataStoreConfig(enableJournal: false).',
        );
      }

      // Initialize or get shared workload scheduler using maxIoConcurrency as total token capacity.
      workloadScheduler = SharedEngineRegistry.getWorkloadScheduler(
        _instanceKey,
        _config!.maxIoConcurrency,
      );
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

      lockManager = SharedEngineRegistry.getLockManager(_instanceKey);
      // Close any previous adapter before replacing the field. Covers paths
      try {
        await storage.close();
      } catch (_) {}
      storage = isMemoryMode
          ? StorageAdapter.forStorage(const NoopStorageImpl(),
              lockManager: lockManager!)
          : StorageAdapter(lockManager: lockManager!);

      // Configure storage runtime and flush policy based on DataStoreConfig
      await storage.configure(
        maxOpenHandles: _config!.maxOpenFiles,
        flushPolicy: _config!.recoveryFlushPolicy,
      );

      tableMetaManager = TableMetaManager(this);
      _pathManager = PathManager(this);

      // Initialize resource manager
      _resourceManager = ResourceManager();

      // Create key manager instance but don't initialize yet
      _keyManager = KeyManager(this);

      transactionManager = TransactionManager(this);

      if (!isMemoryMode) {
        await Future.wait([
          getGlobalConfig(),
          _resourceManager!.initialize(_config!, this),
          Future(() async => await transactionManager!.initialize()),
        ]);
      } else {
        await Future.wait([
          _resourceManager!.initialize(_config!, this),
          Future(() async => await transactionManager!.initialize()),
        ]);
      }
      _startupProgressCallback?.call(0.1, DbStartupStage.opening);

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
        }
      }

      _indexManager = IndexManager(this);
      _vectorIndexManager = VectorIndexManager(this);
      indexTreePartitionManager = IndexTreePartitionManager(this);
      tableTreePartitionManager = TableTreePartitionManager(this);
      _tableDataManager = TableDataManager(this);
      _treeMetaPageService = TreeMetaPageService(this);
      // Initialize WAL and parallel journal pipeline
      walManager = WalManager(this);
      writeBufferManager = WriteBufferManager(this);
      backgroundWriteScheduler = BackgroundWriteScheduler();
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

      // Memory mode: register TableMeta only after managers above exist.
      // registerTableSchemaInMemory -> saveTableMeta may call getTableMeta,
      // which must not touch a null queryExecutor.
      if (isMemoryMode && tableMetaManager != null) {
        for (final s in SystemTable.gettableSchemas) {
          await tableMetaManager!.registerTableSchemaInMemory(s);
        }
        for (final s in _userSchemas) {
          await tableMetaManager!.registerTableSchemaInMemory(s);
        }
        tableMetaManager!.markNameInventoryReady();
      }

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
        }

        // Mark base initialization complete AFTER KeyManager is initialized
        _baseInitialized = true;
        _startupProgressCallback?.call(0.2, DbStartupStage.opening);
        if (!isMemoryMode) {
          // Prepare temp directory for crash-safe writes (native only)
          await _resetTempDir();

          _startupProgressCallback?.call(0.2, DbStartupStage.recovering);
          await walManager.initializeAndRecover();

          if (!isMigrationInstance) {
            final userSchemas = _getUserDefinedSchemas();
            final systemSchemas = SystemTable.gettableSchemas;
            await migrationManager?.initialize(
              userSchemas: userSchemas,
              systemSchemas: systemSchemas,
            );
          }

          await parallelJournalManager.start();

          if (!isMigrationInstance) {
            // Recover unfinished transactions (commit plans or rollbacks)
            await transactionManager!.recoverUnfinishedTransactionsOnStartup();

            // Resume pending table-level clear/drop operations before WAL replay.
            await _resumePendingTableOps();
            _startupProgressCallback?.call(0.35, DbStartupStage.recovering);

            // Execute old structure migration if needed
            await _migrateOldStructureIfNeeded();
            _startupProgressCallback?.call(0.4, DbStartupStage.recovering);

            // System tables (incl. key-migration progress) before key rewrite.
            await _startSetupAndUpgrade();
            _startupProgressCallback?.call(0.8, DbStartupStage.optimizing);

            // Key migration after setup so `_system_key_migration` exists
            // (schema tasks already recovered in migrationManager.initialize).
            await _keyManager!.startDeferredKeyMigrationWork();
          }
        }

        _isInitialized = true;

        // Space stats: lazy hydrate in TableDataManager (non-blocking).
        if (!isMigrationInstance) {
          unawaited(tableDataManager
              .ensureSpaceStatsHydrated()
              .catchError((Object e) {
            Logger.warn('Background space stats hydrate failed', rawError: e);
          }));
        }

        _startupProgressCallback?.call(1.0, DbStartupStage.ready);

        // Background: full TableMeta cache + reconcile dir high-water.
        if (!isMigrationInstance && !isMemoryMode) {
          unawaited(
              tableMetaManager?.loadAllTableMetaAsync().catchError((Object e) {
            Logger.warn('Background table meta load failed', rawError: e);
          }));

          migrationManager?.schedulePendingMigrationWork();
        }

        if (!_initCompleter.isCompleted) {
          _initCompleter.complete();
        }

        if (!isMigrationInstance) {
          // Initialize WeightManager
          if (_weightManager != null) {
            await _weightManager!.initialize();
          }
          await loadDataToCache();
          CrontabManager.start();
          _ttlCleanupManager.registerCleanupTask();

          // Database open callback
          await _onOpen?.call(this);
        }
      });

      return true;
    } catch (e) {
      _isInitialized = false;
      if (!_initCompleter.isCompleted) {
        _initCompleter.completeError(e);
      }
      Logger.error('Database initialization failed', rawError: e);
      try {
        // Prevent ReadViewManager callback leak if initialization failed after its creation
        readViewManager.dispose();
      } catch (_) {}
      rethrow;
    } finally {
      _initializing = false;
      _startupProgressCallback = null;
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
      Logger.warn('Reset temp directory failed', rawError: e);
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

      final systemSchemas = SystemTable.gettableSchemas;
      final userSchemas = _getUserDefinedSchemas();

      // Check if initialization or upgrade is needed
      bool needInitialize = false;
      bool systemSchemaChanged = false;
      bool userSchemaChanged = false;

      final globalConfig = await getGlobalConfig() ?? GlobalConfig();
      if (globalConfig.systemSchemaHash == null) {
        // First run, need to initialize
        needInitialize = true;
      } else {
        // Compare hash values to check if upgrade is needed
        systemSchemaChanged =
            await tableMetaManager!.isSystemSchemaChanged(systemSchemas);
        if (userSchemas.isNotEmpty) {
          userSchemaChanged =
              await tableMetaManager!.isSchemaChanged(userSchemas);
        }
      }

      // First run - create system tables and user tables.
      // This block is idempotent: if a previous startup created only some tables
      // and then crashed, we skip "table already exists" errors on retry and
      // only abort for true fatal errors (disk I/O, schema validation, etc.).
      if (needInitialize) {
        // Create system tables first (they have no foreign key dependencies)
        final systemTablesResult = await createTables(
          systemSchemas,
          isSystemTable: true,
        );
        if (systemTablesResult.hasErrors) {
          final systemFatalErrors = systemTablesResult.statuses
              .where((s) =>
                  s.type != ResultType.success &&
                  s.type != ResultType.devSchemaTableExists)
              .toList();
          if (systemFatalErrors.isNotEmpty) {
            throw DbException(systemFatalErrors);
          }
        }

        // Create user tables
        if (userSchemas.isNotEmpty) {
          final userTablesResult = await createTables(userSchemas);
          if (userTablesResult.hasErrors) {
            final userFatalErrors = userTablesResult.statuses
                .where((s) =>
                    s.type != ResultType.success &&
                    s.type != ResultType.devSchemaTableExists)
                .toList();
            if (userFatalErrors.isNotEmpty) {
              throw DbException(userFatalErrors);
            }
          }
        }

        // Single durability barrier: meta rows sit in the write buffer
        await _flushPendingWrites();
        await tableMetaManager?.updateSchemaHashes(
          systemSchemas: systemSchemas,
          userSchemas: userSchemas.isNotEmpty ? userSchemas : null,
        );

        // Call creation callback
        await _onCreate?.call(this);
      }
      // Need upgrade - perform table structure migration
      else if (systemSchemaChanged || userSchemaChanged) {
        bool optimizingCalled = false;
        await migrationManager?.migrate(
          userSchemas: userSchemas,
          systemSchemas: systemSchemas,
          batchSize: config.migrationConfig?.batchSize ?? 1000,
          onProgress: (double progress) {
            if (!optimizingCalled) {
              _startupProgressCallback?.call(0.4, DbStartupStage.optimizing);
              optimizingCalled = true;
            }
            double mappedProgress =
                0.4 + (progress * 0.4); // maps 0.0-1.0 to 0.4-0.8
            _startupProgressCallback?.call(
                mappedProgress.clamp(0.0, 1.0), DbStartupStage.optimizing);
          },
        );

        await tableMetaManager?.updateSchemaHashes(
          systemSchemas: systemSchemaChanged ? systemSchemas : null,
          userSchemas: userSchemaChanged ? userSchemas : null,
        );
      }
    } catch (e) {
      Logger.error('Setup and upgrade failed', rawError: e);
      rethrow;
    }
  }

  Future<void> flush({bool flushStorage = true}) async {
    if (!_isInitialized) {
      await ensureInitialized();
    }
    await _flushPendingWrites(flushStorage: flushStorage);
  }

  /// Drain write buffer + WAL queue (+ optional storage fsync).
  ///
  /// Unlike [flush], this does not call [ensureInitialized], so it is safe
  /// during bootstrap while [_isInitialized] is still false.
  Future<void> _flushPendingWrites({bool flushStorage = true}) async {
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

    // Mark closing before clearing init flags so SpaceStats skips InternalKv
    // while journal flush / teardown still runs.
    _closing = true;
    _tableDataManager?.suppressSpaceStatsKvPersistence();

    // Immediately mark as uninitialized to block new operations
    _isInitialized = false;
    _baseInitialized = false;
    _globalQueryCancelToken.cancel();
    await Future.delayed(Duration.zero);

    // Stop cache prewarm before maintenance / handle close. Without this,
    // 100k+ full-table/index scans keep shared locks + file handle queues
    // busy and switchSpace/close stalls for seconds.
    await _stopAndAwaitPrewarm();

    try {
      // Stop background triggers first to prevent new work from entering pipelines
      _ttlCleanupManager.unregisterCleanupTask();
      compactionManager.dispose();

      // Perform all flushing and shutdown as system operation to bypass transaction locks
      await TransactionContext.runAsSystemOperation(() async {
        // Stop producers BEFORE maintenance/crontab teardown so cooperative
        // cancel can finish without waiting forever on maintenance barriers.
        // Do NOT call CrontabManager.dispose() here: it clears ALL DBs' callbacks
        // and strips the shared LockManager timeout safety-net (reused on
        // switchSpace). Each manager removes its own callbacks in dispose().
        final keyPaused = await _keyManager?.pauseKeyMigration(
              skipIfRecentlyPaused: true,
            ) ??
            true;
        if (!keyPaused) {
          Logger.warn(
            'Key migration did not pause before close; continuing shutdown, '
            'but Windows file locks may linger until the runner exits',
          );
        }
        await migrationManager?.stopAllMigrations();
        await LargeOperationRunner.pauseForShutdown(this);

        // Stop crontab writers before maintenance drain. Weight periodic save
        // does not go through ensureInitialized and would otherwise park on
        // the maintenance barrier for baseLockTimeout (serialize lock errors).
        _weightManager?.stopBackgroundTasks();

        // Clear all background write scheduler entries to prevent flush blocking
        backgroundWriteScheduler.clearAll();

        // Primary instance only: wait for user transactions to drain, then flush.
        // Migration helper instances share LockManager - entering maintenance
        // from them deadlocks the parent's stopAllMigrations await.
        var enteredMaintenance = false;
        try {
          if (persistChanges && !isMigrationInstance) {
            try {
              // Only arm maintenance after quiescent succeeds; do not treat a
              // failed drain as "entered" (would leave barrier up until finally).
              enteredMaintenance = await lockManager?.enterMaintenance(
                      timeout: config.transactionTimeout) ??
                  false;
            } catch (_) {
              enteredMaintenance = false;
            }
          }

          // Flush and stop write pipelines
          try {
            await parallelJournalManager.stop(flush: persistChanges);
          } catch (e) {
            Logger.warn('Stop journal manager failed', rawError: e);
          }

          try {
            await walManager.flushQueueCompletely();
            if (persistChanges && config.enableJournal) {
              await walManager.persistMeta(flush: true);
            }
          } catch (e) {
            Logger.warn('Flush WAL failed', rawError: e);
          }

          // Flush weight data
          if (_weightManager != null) {
            if (persistChanges) {
              await _weightManager!.saveWeights(force: true);
            }
            _weightManager!.stopBackgroundTasks();
          }

          // Persist and dispose data managers via CacheManager
          await cacheManager.dispose();

          // Clear activeSpace while storage is still open (before close below).
          if (!keepActiveSpace) {
            try {
              final globalConfig = await getGlobalConfig();
              if (globalConfig != null && globalConfig.activeSpace != null) {
                await saveGlobalConfig(globalConfig.clearActiveSpace());
              }
            } catch (e) {
              Logger.error('Clear activeSpace on close failed', rawError: e);
            }
          }

          // Final storage flush and close
          try {
            await storage.flushAll(closeHandles: true);
            if (closeStorage) {
              await storage.close();
            }
          } catch (e) {
            Logger.warn('Storage flush/close failed', rawError: e);
          }
        } finally {
          // Always clear maintenance - even if flush/dispose threw - otherwise
          // switchSpace reuses a LockManager stuck in maintenance and user ops
          // can stall for baseLockTimeout.
          if (enteredMaintenance) {
            lockManager?.exitMaintenance();
          }
        }
      });

      // Cleanup remaining non-storage managers and stop background tasks
      readViewManager.dispose();
      transactionManager?.dispose();
      notificationManager.dispose();
      _resourceManager?.dispose();
      migrationManager?.dispose();

      _globalConfigCache = null;
      _downgradeGuardJsonVersion = null;

      // Now that we have yielded and called dispose, it is safe to
      // nullify manager references for GC. This satisfies the requirement
      // for "Immediate destruction" on true close() while preventing crashes.
      if (closeStorage) {
        _indexManager = null;
        tableTreePartitionManager = null;
        indexTreePartitionManager = null;
        _treeMetaPageService = null;
        _vectorIndexManager = null;
        _tableDataManager = null;
        _queryOptimizer = null;
        _queryExecutor = null;
        _integrityChecker = null;
        _keyManager = null;
        _weightManager = null;
        tableMetaManager = null;
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
      Logger.error('Database shutdown error', rawError: e);
      rethrow;
    } finally {
      _initializing = false;
      _baseInitialized = false;
      _isInitialized = false;
      _initCompleter = Completer<void>();

      // Only remove from factory cache if requested
      if (removeRegistry && _instances[_instanceKey] == this) {
        _instances.remove(_instanceKey);
        SharedEngineRegistry.remove(_instanceKey);
      }

      if (removeRegistry || closeStorage) {
        Logger.info('Database instance has been closed: $_instanceKey');
      }
    }
  }

  /// Create a single table
  /// Returns [DbResult] to allow graceful error handling for business logic errors
  Future<DbResult> createTable(
    TableSchema schema, {
    bool isSystemTable = false,
  }) async {
    DbResult finish(DbResult r) =>
        _returnOrThrowIfTxn(r, 'createTable', schema.name);

    if (!_baseInitialized) {
      await ensureInitialized();
    }

    // Privilege is caller-asserted only - never inferred from table name.
    final tableSchema =
        schema.materializeForCreate(isSystemTable: isSystemTable);
    final tableUid = tableSchema.tableUid;

    try {
      // Check if table already exists
      final tableExists = await this.tableExists(tableSchema.name);
      if (tableExists) {
        Logger.info(
            'Table ${tableSchema.name} already exists, skipping creation');
        return finish(DbResult.error(
          type: ResultType.devSchemaTableExists,
          message: 'Table ${tableSchema.name} already exists',
        ));
      }

      try {
        // Validate primary key configuration and field types
        final reservedSystemTableNames = SystemTable.systemTableNames;
        tableSchema.validateTableSchema(
          reservedTableNames: reservedSystemTableNames,
          allowReservedTableNames: isSystemTable,
          allowInternalTableNamePrefix: isSystemTable,
          allowOtherInternalFields: isSystemTable,
        );

        // Validate foreign key constraints with referenced tables
        for (final fk in tableSchema.foreignKeys) {
          if (!fk.enabled) continue;

          final referencedSchema = await tableMetaManager
              ?.getTableSchemaByName(TableName(fk.referencedTable));
          if (referencedSchema == null) {
            throw DbException([
              SchemaValidationStatus(
                type: ResultType.devTableNotFound,
                message:
                    'Cannot create table ${tableSchema.name}: Referenced table ${fk.referencedTable} does not exist for foreign key ${fk.actualName}',
                tableName: tableSchema.name,
                field: fk.fields.join(','),
                wrongValue: fk.referencedTable,
              ),
            ]);
          }

          if (tableSchema.isGlobal != referencedSchema.isGlobal) {
            throw DbException([
              SchemaValidationStatus(
                type: ResultType.devInvalidSchemaSpaceMismatch,
                message:
                    'Space mismatch in foreign key "${fk.actualName}" of table "${tableSchema.name}": '
                    '${tableSchema.name} is ${tableSchema.isGlobal ? "global" : "space-specific"} but '
                    'referenced table ${fk.referencedTable} is ${referencedSchema.isGlobal ? "global" : "space-specific"}. '
                    'Foreign key relationships across global and space boundaries are not allowed.',
                tableName: tableSchema.name,
                field: fk.fields.join(','),
                wrongValue: {
                  'tableIsGlobal': tableSchema.isGlobal,
                  'referencedTableIsGlobal': referencedSchema.isGlobal,
                },
              ),
            ]);
          }

          if (!tableSchema.validateForeignKeyWithReferencedTable(
              fk, referencedSchema)) {
            throw DbException([
              SchemaValidationStatus(
                type: ResultType.devInvalidSchemaForeignKey,
                message:
                    'Invalid foreign key ${fk.actualName} in table ${tableSchema.name}: Field type mismatch or invalid configuration',
                tableName: tableSchema.name,
                field: fk.fields.join(','),
              ),
            ]);
          }
        }

        // Register TableMeta (memory-only for _system_table_meta until indexes exist)
        final isTableMeta = SystemTable.isTableMetaTable(tableSchema.name);
        final dirIndex = isTableMeta
            ? SystemTable.tableMetaDirIndex
            : await tableMetaManager!.allocateDirIndex(tableSchema.isGlobal);
        final layout =
            tableMetaManager!.evolveFieldStorageLayout(nextSchema: tableSchema);
        final now = DateTime.now();
        final meta = TableMeta(
          tableUid: tableUid,
          tableName: TableName(tableSchema.name),
          isGlobal: tableSchema.isGlobal,
          schema: tableSchema,
          fieldLayout: layout,
          dirIndex: dirIndex,
          createdAt: now,
          updatedAt: now,
        );
        final savedMeta = await tableMetaManager!.saveTableMeta(
          meta,
          memoryOnly: isTableMeta,
          dirIndex: dirIndex,
          layoutOverride: layout,
        );
        final resolvedUid = savedMeta.tableUid;
        final resolvedSchema = savedMeta.schema;
        final tableCtx = TableContext(
          tableUid: resolvedUid,
          tableName: savedMeta.tableName,
          isGlobal: savedMeta.isGlobal,
          dirIndex: savedMeta.dirIndex,
          schema: resolvedSchema,
        );

        // Empty committed meta in memory: first insert skips disk unique probes
        // without a separate negative-cache. Persist happens on first flush.
        tableDataManager.seedEmptyTableDataMeta(tableCtx);

        // Persist self-row after schema is durable (bootstrap recursion avoided).
        // Index files/meta are created lazily on first write via writeChanges.
        if (isTableMeta) {
          await tableMetaManager?.saveTableMeta(
            savedMeta,
            dirIndex: savedMeta.dirIndex,
            layoutOverride: savedMeta.fieldLayout,
          );
        }

        // Auto-create indexes for foreign keys
        if (_foreignKeyManager != null && !resolvedSchema.isSystemTable) {
          await _foreignKeyManager!
              .updateSystemTableForTable(tableCtx, resolvedSchema);
        }

        if (!resolvedSchema.isSystemTable) {
          Logger.info(
            'Table ${resolvedSchema.name} created successfully${resolvedSchema.isGlobal ? ' (global)' : ' (space)'}',
          );
        }

        return finish(DbResult.success(
          successKey: resolvedSchema.name,
          message: 'Table ${resolvedSchema.name} created successfully',
        ));
      } catch (e) {
        // Cleanup schema (uid may have been reallocated during save)
        if (tableMetaManager != null) {
          final cleanupUid = await tableMetaManager!
                  .getUidByName(TableName(tableSchema.name)) ??
              tableUid;
          await tableMetaManager!.deleteTableMeta(cleanupUid);
        }

        Logger.error('Create table failed', rawError: e);
        // Convert exception to DbResult for graceful error handling
        if (e is DbException) {
          return finish(DbResult.batch(
            statuses: e.statuses,
            failedCount: e.statuses.length,
          ));
        }
        return finish(DbResult.error(
          type: ResultType.engError,
          message: 'Failed to create table ${schema.name}: $e',
        ));
      }
    } catch (e) {
      Logger.error('Create table failed', rawError: e);
      // Convert any unexpected exceptions to DbResult
      final dbEx = DbException.wrap(e,
          fallbackType: ResultType.engError,
          fallbackMessage: 'Failed to create table ${schema.name}');
      return finish(DbResult.batch(
        statuses: dbEx.statuses,
        failedCount: dbEx.statuses.length,
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
      );
      // Add unsorted tables at the end (they may have circular dependencies)
      sorted.addAll(unsorted);
    }

    return sorted;
  }

  /// Create multiple tables
  /// Automatically sorts tables by foreign key dependencies to ensure correct creation order
  /// Returns [DbResult] to allow graceful error handling for business logic errors
  Future<DbResult> createTables(
    List<TableSchema> schemas, {
    bool isSystemTable = false,
  }) async {
    if (schemas.isEmpty) {
      return DbResult.success(message: 'No tables to create');
    }

    // Sort tables by foreign key dependencies
    // This ensures parent tables (referenced tables) are created before child tables
    final sortedSchemas = _sortTablesByDependencies(schemas);

    // Create tables in sorted order
    final List<String> successKeys = [];
    final List<String> failedKeys = [];
    final List<ResultStatus> statuses = [];

    for (var schema in sortedSchemas) {
      final result = await createTable(
        schema,
        isSystemTable: isSystemTable,
      );
      statuses.addAll(result.statuses);
      if (!result.hasErrors) {
        successKeys.add(schema.name);
      } else {
        failedKeys.add(schema.name);
        // Continue creating other tables even if one fails
      }
    }

    if (failedKeys.isEmpty) {
      return DbResult(
        statuses: statuses,
        successKeys: successKeys,
        successCount: successKeys.length,
        failedCount: 0,
      );
    } else if (successKeys.isEmpty) {
      return DbResult.error(
        type: ResultType.engError,
        message: 'Failed to create all tables',
        failedKeys: failedKeys,
        statuses: statuses,
      );
    } else {
      return DbResult.batch(
        statuses: statuses,
        message:
            'Partially successful: ${successKeys.length} tables created, ${failedKeys.length} failed',
        successKeys: successKeys,
        failedKeys: failedKeys,
      );
    }
  }

  /// Easily obtain the TableContext of this table
  Future<TableContext> getTableContext(String tableName) async {
    final name = TableName(tableName);
    final tableUid = await tableMetaManager?.resolveTableUidFromName(name);
    if (tableUid == null) {
      throw DbException([
        SchemaValidationStatus(
          type: ResultType.devTableNotFound,
          message: 'Table $tableName does not exist',
          tableName: tableName,
        )
      ]);
    }
    final context = await tableMetaManager?.getTableContext(tableUid);
    if (context == null) {
      throw DbException([
        SchemaValidationStatus(
          type: ResultType.devTableNotFound,
          message: 'Table $tableName does not exist',
          tableName: tableName,
        )
      ]);
    }
    return context;
  }

  /// Insert data complete process
  ///
  /// [retryOnPkConflict] is an internal flag to avoid infinite recursion when
  /// automatically retrying once after fixing a sequential primary key conflict.
  /// [enablePromoteDualWrite] user-facing default true; engine/migration must
  /// pass false to avoid promote old->shadow recursion.
  Future<DbResult> insert(String tableName, Map<String, dynamic> data,
      {bool retryOnPkConflict = false,
      bool enablePromoteDualWrite = true}) async {
    DbResult finish(DbResult r) => _returnOrThrowIfTxn(r, 'insert', tableName);
    // Need to be fully initialized
    if (!_isInitialized) {
      await ensureInitialized();
    }

    // Emergency Resource Check
    if (_resourceManager?.isWriteBlocked ?? false) {
      return finish(DbResult.error(
        type: ResultType.sysResourceExhausted,
        message:
            'Insert operation blocked: System resources are critically low.',
      ));
    }

    // Capture transaction id once for performance and consistent visibility rules
    final String? txId = Zone.current[_txnZoneKey] as String?;

    Map<String, dynamic>? validData;
    TableContext? table;
    PromoteRuntimeDescriptor? promoteDesc;

    try {
      // 1. Data validation
      table = await getTableContext(tableName);
      promoteDesc = _promoteRuntimeForDualWrite(
        table.tableUid,
        enablePromoteDualWrite: enablePromoteDualWrite,
      );
      if (promoteDesc != null) {
        // User data is target-shaped; old table is the write authority.
        _promoteRemapRecordNewToOld(data, promoteDesc);
      }
      final schema = table.schema;

      final validationErrors = <String>[];
      try {
        validData = await _validateAndProcessData(
          schema,
          data,
          table,
          validationErrors: validationErrors,
        );
      } on DbException catch (e) {
        final detailMsg = e.statuses.isNotEmpty
            ? 'Data validation failed for table $tableName: ${e.statuses.map((s) => s.message).join("; ")}'
            : 'Data validation failed for table $tableName';
        return finish(DbResult.error(
          type: e.statuses.isNotEmpty
              ? e.statuses.first.type
              : ResultType.bizValidationFailed,
          message: detailMsg,
          statuses: e.statuses,
        ));
      }
      if (validData == null) {
        final detailMsg = validationErrors.isNotEmpty
            ? 'Data validation failed for table $tableName: ${validationErrors.join("; ")}'
            : 'Data validation failed for table $tableName';
        return finish(DbResult.error(
          type: ResultType.bizValidationFailed,
          message: detailMsg,
        ));
      }

      final recordId = validData[schema.primaryKey].toString();

      // 3. Reservation based: try reserve unique keys first to lock the buffer
      try {
        writeBufferManager.tryReserveUniques(
          table: table,
          schema: schema,
          recordId: recordId,
          data: validData,
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
                  table, providedId);
            }
            if (!retryOnPkConflict) {
              return await insert(tableName, data,
                  retryOnPkConflict: true,
                  enablePromoteDualWrite: enablePromoteDualWrite);
            }
          }

          return finish(DbResult.error(
            type: e.constraintResultType,
            message: e.message,
            failedKeys: [recordId],
          ));
        }
        rethrow;
      }

      // 4. Validate foreign key constraints after reservation
      final bool hasForeignKeys = _foreignKeyManager != null &&
          schema.foreignKeys.any((fk) => fk.enabled);
      if (hasForeignKeys) {
        try {
          await _foreignKeyManager!.validateForeignKeyConstraints(
            table: table,
            data: validData,
            operation: ForeignKeyOperation.insert,
          );
        } catch (e) {
          // Rollback reservation on FK failure
          try {
            writeBufferManager.releaseReservedUniques(
              table: table,
              recordId: recordId,
              transactionId: txId,
            );
          } catch (_) {}

          Logger.error('Foreign key constraint validation failed', rawError: e);
          return finish(DbResult.error(
            type: ResultType.bizForeignKeyViolation,
            message: e.toString(),
          ));
        }
      }

      // 5. Unique check (disk only) - skip buffer check as we already reserved the keys
      final uniqueViolation = await _indexManager?.checkUniqueConstraints(
          table, validData,
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
            await tableDataManager.handlePrimaryKeyConflict(table, providedId);
          }
          if (!retryOnPkConflict) {
            // Rollback reservation before retrying
            try {
              writeBufferManager.releaseReservedUniques(
                table: table,
                recordId: recordId,
                transactionId: txId,
              );
            } catch (_) {}

            return await insert(tableName, data,
                retryOnPkConflict: true,
                enablePromoteDualWrite: enablePromoteDualWrite);
          }
        }

        // Rollback reservation on disk conflict
        try {
          writeBufferManager.releaseReservedUniques(
            table: table,
            recordId: recordId,
            transactionId: txId,
          );
        } catch (_) {}

        return finish(DbResult.error(
          type: uniqueViolation.constraintResultType,
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

      // 7. Add to write queue (insert operation)
      await tableDataManager.addToBuffer(
        table,
        orderedValidData,
        BufferOperationType.insert,
        transactionId: txId,
        schemaVersion: table.schema.schemaVersion ?? '',
      );

      notificationManager.notify(ChangeEvent(
        type: ChangeType.insert,
        tableUid: table.tableUid,
        record: orderedValidData,
      ));

      if (promoteDesc != null) {
        await _promoteMirrorUpsertToShadow(promoteDesc, [orderedValidData]);
      }

      // Old-table success is authoritative; user-facing PK is O(1) field read
      // of the source unique field (already remapped new->old above).
      final primaryKeyValue = promoteDesc != null
          ? _promoteUserFacingSuccessKey(orderedValidData, promoteDesc)
          : validData[schema.primaryKey]?.toString();
      return finish(DbResult.success(
        successKey: primaryKeyValue,
        message: 'Insert successful',
      ));
    } catch (e) {
      Logger.error('Insert failed', rawError: e);

      try {
        // Roll back unique pre-reserve if apply never committed them.
        if (table != null && validData != null) {
          final schema = table.schema;
          final rid = validData[schema.primaryKey]?.toString();
          if (rid != null && rid.isNotEmpty) {
            writeBufferManager.releaseReservedUniques(
              table: table,
              recordId: rid,
              transactionId: txId,
            );
          }
        }
      } catch (_) {}

      try {
        // Clear cache
        final schema = table?.schema ??
            await tableMetaManager?.getTableSchemaByName(TableName(tableName));
        final primaryKeyValue = validData != null && schema != null
            ? validData[schema.primaryKey]
            : null;
        if (primaryKeyValue != null && table != null) {
          await tableDataManager.removeTableRecords(table, [
            primaryKeyValue.toString(),
          ]);
        }

        // clear write queue
        if (schema != null && table != null) {
          final primaryKey = schema.primaryKey;
          final recordId = data[primaryKey]?.toString();
          if (recordId != null) {
            tableDataManager.removeRecordFromBuffer(table, recordId);
          }
        }
      } catch (rollbackError) {
        Logger.error('Rollback failed: $rollbackError', rawError: e);
      }

      // Identify the failed record's key
      List<String> failedKeys = [];
      try {
        final schema =
            await tableMetaManager?.getTableSchemaByName(TableName(tableName));
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

      final dbEx = DbException.wrap(e,
          fallbackType: ResultType.engError, fallbackMessage: 'Insert failed');
      return finish(DbResult.batch(
        statuses: dbEx.statuses,
        failedCount: dbEx.statuses.length,
        failedKeys: failedKeys,
      ));
    }
  }

  /// validate and process data
  Future<Map<String, dynamic>?> _validateAndProcessData(
    TableSchema schema,
    Map<String, dynamic> data,
    TableContext table, {
    bool skipPrimaryKeyFormatCheck = false,
    List<String>? validationErrors,
    Map<String, FieldSchema>? fieldMap,
  }) async {
    Object? resolvedPrimaryKey;
    final primaryKey = schema.primaryKey;
    final tableName = table.tableName;

    if ((!data.containsKey(primaryKey) || data[primaryKey] == null) &&
        schema.primaryKeyConfig.type != PrimaryKeyType.none) {
      final nextId = await tableDataManager.getNextId(table);
      if (nextId.isEmpty) {
        if (validationErrors != null) {
          validationErrors.add('Failed to generate primary key');
        }
        Logger.error(
          'Data validation failed: Failed to generate primary key',
        );
        return null;
      }
      resolvedPrimaryKey = nextId;
    }

    return validateAndProcessRecordPure(
      schema: schema,
      data: data,
      tableName: tableName,
      skipPrimaryKeyFormatCheck: skipPrimaryKeyFormatCheck,
      validationErrors: validationErrors,
      fieldMap: fieldMap,
      hasResolvedPrimaryKey: resolvedPrimaryKey != null,
      resolvedPrimaryKey: resolvedPrimaryKey,
      ignoreUnknownFields: _config?.ignoreUnknownFields ?? true,
    );
  }

  Future<List<BatchInsertPreparedRecord>> _prepareBatchInsertRecords(
    TableSchema schema,
    TableContext table,
    List<Map<String, dynamic>> records,
    Set<Map<String, dynamic>> autoPkRecords,
  ) async {
    if (records.isEmpty) {
      return const <BatchInsertPreparedRecord>[];
    }

    // PERFORMANCE: batchInsert prepare is Map-allocation dominated. Shipping
    // records through isolates doubles the cost (structured-clone in + out)
    // and routinely exceeds the pure CPU work. Always prepare on the current
    // isolate with YieldController; keep the planner only for chunk sizing if
    // we later re-enable isolate for pathological CPU-heavy schemas.
    final skipPrimaryKeyFormatChecks = List<bool>.generate(
        records.length, (i) => autoPkRecords.contains(records[i]),
        growable: false);

    final batchTimestamp = DateTime.now();
    final result = await prepareBatchInsertChunk(
      BatchInsertPrepareRequest(
        schema: schema,
        tableName: table.tableName,
        records: records,
        skipPrimaryKeyFormatChecks: skipPrimaryKeyFormatChecks,
        ignoreUnknownFields: _config?.ignoreUnknownFields ?? true,
        batchTimestamp: batchTimestamp,
      ),
    );
    return result.records;
  }

  Future<List<IdentifierValidationRecordResult>>
      _validateRecordIdentifiersBatch(
    TableSchema schema,
    List<Map<String, dynamic>> records,
    List<IndexSchema> uniqueIndexes, {
    required bool checkRequiredFields,
  }) async {
    if (records.isEmpty) {
      return const <IdentifierValidationRecordResult>[];
    }

    final dispatchPlan = ComputeBatchPlanner.planTaskExecution(
      itemCount: records.length,
      estimateAverageItemBytes: () =>
          tableDataManager.estimateAverageRecordBytesForBatch(records),
    );
    final useIsolate = dispatchPlan.useIsolate;
    final actualTaskCount = dispatchPlan.actualTaskCount;

    final tasks = <ComputeTask<BatchIdentifierValidationRequest,
        BatchIdentifierValidationResult>>[];
    for (final range
        in ComputeBatchPlanner.splitRange(records.length, actualTaskCount)) {
      tasks.add(
        ComputeTask(
          function: validateIdentifierChunk,
          message: BatchIdentifierValidationRequest(
            schema: schema,
            records: records.sublist(range.start, range.end),
            uniqueIndexes: uniqueIndexes,
            checkRequiredFields: checkRequiredFields,
          ),
        ),
      );
    }

    final results =
        await ComputeManager.computeBatch(tasks, enableIsolate: useIsolate);

    final merged = <IdentifierValidationRecordResult>[];
    for (final result in results) {
      merged.addAll(result.records);
    }
    return merged;
  }

  int _estimateAverageUpdatePrepareBytes(
    List<Map<String, dynamic>> records,
    List<Map<String, dynamic>?> existingRecords,
  ) {
    if (records.isEmpty) return 0;

    final sampledIndices = <int>{
      0,
      if (records.length > 1) 1,
      if (records.length > 2) records.length - 2,
      if (records.length > 3) records.length - 1,
    };

    int total = 0;
    int count = 0;
    for (final index in sampledIndices) {
      final currentRecordBytes =
          max(1, tableDataManager.estimateRecordSizeBytes(records[index]));
      final existingRecord = existingRecords[index];
      final existingRecordBytes = existingRecord == null
          ? 0
          : max(1, tableDataManager.estimateRecordSizeBytes(existingRecord));
      total += currentRecordBytes + existingRecordBytes;
      count++;
    }

    return count == 0 ? 0 : max(1, (total / count).ceil());
  }

  Future<List<BatchUpdatePreparedRecord>> _prepareBatchUpdateRecords(
    TableSchema schema,
    TableContext table,
    List<Map<String, dynamic>> records,
    List<Map<String, dynamic>?> existingRecords,
  ) async {
    if (records.isEmpty) {
      return const <BatchUpdatePreparedRecord>[];
    }
    if (records.length != existingRecords.length) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              '_prepareBatchUpdateRecords length mismatch. Records length (${records.length}) does not match existing records list length (${existingRecords.length}).',
        )
      ]);
    }

    final dispatchPlan = ComputeBatchPlanner.planTaskExecution(
      itemCount: records.length,
      estimateAverageItemBytes: () {
        final avg = tableDataManager.averageTableRecordSizeBytes;
        // new + existing typical working set for update prepare.
        if (avg != null && avg > 0) return avg * 2;
        return _estimateAverageUpdatePrepareBytes(records, existingRecords);
      },
    );
    final useIsolate = dispatchPlan.useIsolate;
    final actualTaskCount = dispatchPlan.actualTaskCount;

    final tasks =
        <ComputeTask<BatchUpdatePrepareRequest, BatchUpdatePrepareResult>>[];
    for (final range
        in ComputeBatchPlanner.splitRange(records.length, actualTaskCount)) {
      tasks.add(
        ComputeTask(
          function: prepareBatchUpdateChunk,
          message: BatchUpdatePrepareRequest(
            schema: schema,
            table: table,
            records: records.sublist(range.start, range.end),
            existingRecords: existingRecords.sublist(range.start, range.end),
            ignoreUnknownFields: _config?.ignoreUnknownFields ?? true,
          ),
        ),
      );
    }

    final results =
        await ComputeManager.computeBatch(tasks, enableIsolate: useIsolate);

    final merged = <BatchUpdatePreparedRecord>[];
    for (final result in results) {
      merged.addAll(result.records);
    }
    return merged;
  }

  int _estimateKeyValueBatchItemBytes(KeyValueBatchItem item) {
    final keyBytes = max(1, calculateUtf8Length(item.key));
    final valueBytes = max(1, calculateUtf8Length(toStringWithAll(item.value)));
    return keyBytes + valueBytes + 128;
  }

  Future<List<Map<String, dynamic>>> _prepareKeyValueBatchRecords(
    Map<String, dynamic> items, {
    required String nowIso,
    required String? expiresAtIso,
  }) async {
    if (items.isEmpty) {
      return const <Map<String, dynamic>>[];
    }

    final kvItems = items.entries
        .map(
          (entry) => KeyValueBatchItem(
            key: entry.key,
            value: entry.value,
          ),
        )
        .toList(growable: false);

    final dispatchPlan = ComputeBatchPlanner.planTaskExecution(
      itemCount: kvItems.length,
      estimateAverageItemBytes: () =>
          ComputeBatchPlanner.estimateAverageItemBytes(
        kvItems,
        _estimateKeyValueBatchItemBytes,
      ),
    );
    final useIsolate = dispatchPlan.useIsolate;
    final actualTaskCount = dispatchPlan.actualTaskCount;

    final tasks = <ComputeTask<KeyValueBatchPrepareRequest,
        KeyValueBatchPrepareResult>>[];
    for (final range
        in ComputeBatchPlanner.splitRange(kvItems.length, actualTaskCount)) {
      tasks.add(
        ComputeTask(
          function: prepareKeyValueBatchChunk,
          message: KeyValueBatchPrepareRequest(
            items: kvItems.sublist(range.start, range.end),
            keyField: _kvKeyField,
            valueField: _kvValueField,
            updatedAtField: _kvUpdatedAtField,
            expiresAtField: _kvExpiresAtField,
            nowIso: nowIso,
            expiresAtIso: expiresAtIso,
          ),
        ),
      );
    }

    final results =
        await ComputeManager.computeBatch(tasks, enableIsolate: useIsolate);

    final records = <Map<String, dynamic>>[];
    final mergeYield =
        YieldController('DataStoreImpl._prepareKeyValueBatchRecords');
    for (final result in results) {
      for (final record in result.records) {
        final y1 = mergeYield.maybeYield();
        if (y1 != null) await y1;
        records.add(record);
      }
    }
    return records;
  }

  Future<List<UniformUpdatePreparedRecord>> prepareUniformUpdateRecords(
    TableSchema schema,
    TableContext table,
    Map<String, dynamic> validData,
    List<Map<String, dynamic>> existingRecords,
  ) async {
    if (existingRecords.isEmpty) {
      return const <UniformUpdatePreparedRecord>[];
    }

    final dispatchPlan = ComputeBatchPlanner.planTaskExecution(
      itemCount: existingRecords.length,
      estimateAverageItemBytes: () =>
          tableDataManager.estimateAverageRecordBytesForBatch(existingRecords),
    );
    final useIsolate = dispatchPlan.useIsolate;
    final actualTaskCount = dispatchPlan.actualTaskCount;

    final tasks = <ComputeTask<UniformUpdatePrepareRequest,
        UniformUpdatePrepareResult>>[];
    for (final range in ComputeBatchPlanner.splitRange(
        existingRecords.length, actualTaskCount)) {
      tasks.add(
        ComputeTask(
          function: prepareUniformUpdateChunk,
          message: UniformUpdatePrepareRequest(
            schema: schema,
            table: table,
            validData: validData,
            existingRecords: existingRecords.sublist(range.start, range.end),
          ),
        ),
      );
    }

    final results =
        await ComputeManager.computeBatch(tasks, enableIsolate: useIsolate);

    final merged = <UniformUpdatePreparedRecord>[];
    for (final result in results) {
      merged.addAll(result.records);
    }
    return merged;
  }

  /// User-facing query helper.
  ///
  /// Opt-in promote result reshape ([applyPromoteResultTransform]: true).
  /// Engine / migration / system paths must call [queryExecutor].execute
  /// directly (default keeps old-working row shape).
  Future<List<Map<String, dynamic>>> executeUserQuery(
    TableContext table,
    QueryCondition condition, {
    List<String>? orderBy,
    int? limit,
    int? offset,
  }) async {
    final result = await queryExecutor.execute(
      table,
      condition: condition,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
      applyPromoteResultTransform: true,
    );
    return result.records;
  }

  /// Upsert one record: update-first by pk or unique key, then insert if not found.
  /// Returns [DbResult]. No where clause; conflict target from data (pk or first complete unique index).
  Future<DbResult> upsert(String tableName, Map<String, dynamic> data) async {
    DbResult finish(DbResult r) => _returnOrThrowIfTxn(r, 'upsert', tableName);
    await ensureInitialized();

    // Emergency Resource Check
    if (_resourceManager?.isWriteBlocked ?? false) {
      return finish(DbResult.error(
        type: ResultType.sysResourceExhausted,
        message:
            'Upsert operation blocked: System resources are critically low.',
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
      Logger.error('Create backup failed', rawError: e);
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

      // Notify all listeners to refresh, as the entire data state has changed.
      for (final tableUid in notificationManager.getActiveTables()) {
        notificationManager.notify(ChangeEvent(
          type: ChangeType.clear,
          tableUid: TableUid(tableUid),
        ));
      }

      return true;
    } catch (e) {
      Logger.error('Failed to restore database', rawError: e);
      return false;
    }
  }

  /// validate and process update data
  Future<Map<String, dynamic>?> _validateAndProcessUpdateData(
    TableSchema schema,
    Map<String, dynamic> data,
    TableContext table,
  ) async {
    return validateAndProcessUpdateDataPure(
      schema: schema,
      data: data,
      tableName: table.tableName,
    );
  }

  /// Engine-facing update.
  ///
  /// Defaults allow large-scale ops ([allowLargeScaleOperation] true) while
  /// still collecting per-row details on the normal path ([returnResultDetails]
  /// true). Public builders must pass [allowLargeScaleOperation] false unless
  /// the user chained [UpdateBuilder.allowLargeScaleOperation]. Large-scale
  /// path never returns primary-key lists (only [DbResult.successCount]).
  ///
  /// [enablePromoteDualWrite] user-facing default true; engine/migration must
  /// pass false to avoid promote old->shadow recursion.
  Future<DbResult> updateInternal(
    TableContext table,
    Map<String, dynamic> data,
    QueryCondition condition, {
    List<String>? orderBy,
    int? limit,
    int? offset,
    bool allowAll = false,
    bool continueOnPartialErrors = false,
    bool returnResultDetails = true,
    bool allowLargeScaleOperation = true,
    bool enablePromoteDualWrite = true,
  }) async {
    final tableName = table.tableName;
    DbResult finish(DbResult r) => _returnOrThrowIfTxn(r, 'update', tableName);
    List<String>? partialUniqueFailedKeys;
    await ensureInitialized();

    // Emergency Resource Check
    if (_resourceManager?.isWriteBlocked ?? false) {
      return finish(DbResult.error(
        type: ResultType.sysResourceExhausted,
        message:
            'update operation blocked: System resources are critically low.',
      ));
    }

    // Capture transaction id once
    final String? txId = Zone.current[_txnZoneKey] as String?;

    // check if condition is empty, avoid accidental update of all records
    if (condition.isEmpty && !allowAll) {
      Logger.warn(
          'Update operation without condition, this may cause accidental update of all records, please use allowUpdateAll() method to explicitly confirm.');
      const message =
          'Update operation must specify a filter condition. If you really need to update all records, please use allowUpdateAll() method to explicitly confirm.';
      return finish(DbResult.error(
        type: ResultType.devInvalidArgumentMissing,
        message: message,
        statuses: [
          InvalidArgumentStatus(
            type: ResultType.devInvalidArgumentMissing,
            message: message,
            parameterName: 'condition',
            passedValue: null,
          )
        ],
      ));
    }

    try {
      // validate data
      final schema = table.schema;
      final promoteDesc = _promoteRuntimeForDualWrite(
        table.tableUid,
        enablePromoteDualWrite: enablePromoteDualWrite,
      );
      if (promoteDesc != null) {
        remapPromoteConditionNewToOld(condition, promoteDesc);
        _promoteRemapRecordNewToOld(data, promoteDesc);
      }
      Map<String, dynamic>? validData;
      try {
        validData = await _validateAndProcessUpdateData(schema, data, table);
      } on DbException catch (e) {
        return finish(DbResult.error(
          type: e.statuses.isNotEmpty
              ? e.statuses.first.type
              : ResultType.bizValidationFailed,
          message: e.statuses.isNotEmpty
              ? e.statuses.first.message
              : 'Data validation failed',
          statuses: e.statuses,
        ));
      }
      if (validData == null || validData.isEmpty) {
        return finish(DbResult.error(
          type: ResultType.bizValidationFailed,
          message: 'Data validation failed',
        ));
      }

      // Unique Key and Primary Key Detection
      final String? txIdCheck = Zone.current[_txnZoneKey] as String?;
      if (txIdCheck == null || TransactionContext.isApplyingCommit()) {
        final uniqueIndexes =
            tableMetaManager?.getUniqueIndexesFor(schema) ?? <IndexSchema>[];
        final uniqueFields = <String>{schema.primaryKey};
        for (final idx in uniqueIndexes) {
          uniqueFields.addAll(idx.fields);
        }

        final modifiesUniqueField =
            data.keys.any((k) => uniqueFields.contains(k));
        if (modifiesUniqueField) {
          bool isUniqueEquality = false;
          final conditionMap = condition.build();

          // Check if it's a primary key equality query (e.g., id = 1)
          if (conditionMap.length == 1 &&
              conditionMap.containsKey(schema.primaryKey)) {
            final pkVal = conditionMap[schema.primaryKey];
            if (pkVal is! Map || pkVal.containsKey('=')) {
              isUniqueEquality = true;
            }
          }

          // Or a unique index field equality query
          if (!isUniqueEquality) {
            for (final idx in uniqueIndexes) {
              if (idx.fields.length == conditionMap.length &&
                  idx.fields.every((f) => conditionMap.containsKey(f))) {
                bool allEquals = true;
                for (final f in idx.fields) {
                  final val = conditionMap[f];
                  if (val is Map && !val.containsKey('=')) {
                    allEquals = false;
                    break;
                  }
                }
                if (allEquals) {
                  isUniqueEquality = true;
                  break;
                }
              }
            }
          }

          if (!isUniqueEquality) {
            final evalResult = await queryExecutor.execute(
              table,
              condition: condition,
              limit: 2,
            );
            if (evalResult.records.length > 1) {
              if (!continueOnPartialErrors) {
                final conflictFields =
                    data.keys.where((k) => uniqueFields.contains(k)).toList();
                final conflictValues =
                    conflictFields.map((f) => data[f]).toList();

                throw DbException([
                  ConstraintStatus(
                    type: conflictFields.length == 1 &&
                            conflictFields.first == schema.primaryKey
                        ? ResultType.bizPrimaryKeyViolation
                        : ResultType.bizUniqueViolation,
                    message:
                        'Batch update would modify multiple records but unique key or primary key would be duplicated. '
                        'Conflicting fields: ${conflictFields.join(", ")}, Update values: ${conflictValues.map((v) => v.toString()).join(", ")}',
                    tableName: table.tableName,
                    fields: conflictFields.isNotEmpty
                        ? conflictFields
                        : [schema.primaryKey],
                    conflictingKeys: conflictValues,
                  ),
                ]);
              } else {
                limit = 1;
                final secondPk =
                    evalResult.records[1][schema.primaryKey]?.toString() ?? '';
                partialUniqueFailedKeys = [secondPk];
              }
            }
          }
        }
      }
      // Get table file metadata to make an informed decision on the update strategy
      final tableDataMeta =
          await tableDataManager.getTableDataMeta(table.tableUid);

      // Get memory manager to access cache size limits
      final recordCacheSize =
          _resourceManager?.getRecordCacheSize() ?? 200 * 1024 * 1024;
      final conditionMap = condition.build();

      final primaryKey = schema.primaryKey;

      // Check if condition is an equality on primary key or unique field - this can be optimized
      bool isOptimizableQuery = false;
      // Small table heuristics: always optimize when
      // - table data meta is unknown or size invalid
      // - size < 5MB (unconditional minimum threshold)
      // - size < 30% of record cache size
      const int minSmallTableBytes = 50 * 1024 * 1024; // 50MB
      if (tableDataMeta == null ||
          tableDataMeta.totalSizeBytes < minSmallTableBytes ||
          tableDataMeta.totalSizeBytes < recordCacheSize * 0.3) {
        isOptimizableQuery = true;
      }

      if (!isOptimizableQuery) {
        // Analyze condition to check if it's a primary key/unique/index-driven operation
        if (!condition.isEmpty) {
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
            final allIndexes = tableMetaManager?.getUniqueIndexesFor(schema) ??
                <IndexSchema>[];
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

      // Large-scale data update path: engine defaults allow; public API must opt in
      if (!isOptimizableQuery) {
        if (promoteDesc != null) {
          return finish(_promoteRejectLargeOp(tableName, 'update'));
        }
        if (!allowLargeScaleOperation) {
          const message =
              'This is a large-scale data update operation. To prevent memory overflow, you must explicitly call allowLargeScaleOperation(). The operation will run in background batches and block until completion; success/failure primary keys and per-row status details are not returned. If interrupted, already-persisted changes are kept and you must retry to continue.';
          Logger.warn(message);
          return finish(DbResult.error(
            type: ResultType.devLargeScaleOperationRequired,
            message: message,
          ));
        }
        // Large-scale ops are not supported in transactions (would buffer unbounded work).
        // Returning DbResult.error triggers transaction rollback when rollbackOnError is set.
        if (txId != null) {
          const message =
              'Large-scale data update is not allowed inside a transaction. '
              'Run it outside the transaction with allowLargeScaleOperation().';
          Logger.warn(message);
          return finish(DbResult.error(
            type: ResultType.devLargeScaleOperationNotAllowedInTransaction,
            message: message,
          ));
        }

        final largeUpdateOpId = GlobalIdGenerator.generate('large_update_');
        final outcome = await LargeOperationRunner.runLargeUpdate(
          this,
          LargeUpdateRequest(
            opId: largeUpdateOpId,
            tableUid: table.tableUid,
            condition: conditionMap,
            updateData: validData,
            orderBy: orderBy,
            limit: limit,
            offset: offset,
            continueOnPartialErrors: continueOnPartialErrors,
          ),
        );
        if (outcome.hasErrors) {
          return finish(DbResult.batch(
            statuses: outcome.errorStatuses,
            successCount: outcome.successCount,
            failedCount: outcome.errorStatuses.length,
            hasErrors: true,
          ));
        }

        return finish(DbResult(
          statuses: [
            SuccessStatus(
              message:
                  'Large-scale data update completed (${outcome.successCount} records).',
            ),
          ],
          successCount: outcome.successCount,
          failedCount: 0,
          hasErrors: false,
        ));
      } else {
        // Optimizable query path: use regular method
        // find matching records (for optimizable queries)
        // Use a large internal limit when limit is null to avoid default QueryLimit (e.g. 1000)
        final int effectiveLimit = limit ?? 1000000000;
        final records = (await queryExecutor.execute(
          table,
          condition: condition,
          orderBy: orderBy,
          limit: effectiveLimit,
          offset: offset,
        ))
            .records;
        if (records.isEmpty) {
          return finish(DbResult.error(
            type: ResultType.bizRecordNotFound,
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
            final y2 = yieldController.maybeYield();
            if (y2 != null) await y2;
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
                    table: table,
                    oldPkValues: oldPkValue,
                  );
                } catch (e) {
                  Logger.error('RESTRICT constraint check failed', rawError: e);
                  return finish(_normalizeCascadeError(e, 'update'));
                }

                // Phase 2: Handle CASCADE/SET NULL/SET DEFAULT operations
                if (txId != null) {
                  // In transaction: defer CASCADE operations until commit
                  // RESTRICT has already been checked above, so we can safely defer CASCADE
                  transactionManager?.registerDeferredCascadeUpdate(
                      txId, table, oldPkValue, newPkValue);
                } else {
                  // Outside transaction: execute CASCADE operations immediately
                  try {
                    await _foreignKeyManager!.handleCascadeUpdate(
                      table: table,
                      oldPkValues: oldPkValue,
                      newPkValues: newPkValue,
                      visitedTables:
                          null, // Start with fresh visited set for each update
                      skipRestrictCheck: true, // RESTRICT already checked above
                    );
                  } catch (e) {
                    Logger.error('Cascade update failed', rawError: e);
                    return finish(_normalizeCascadeError(e, 'update'));
                  }
                }
              }
            }
          }
        }
        final List<String> successKeys = [];
        final List<String> failedKeys = [];
        int successCount = 0;
        int failedCount = 0;
        final promoteUpdated =
            promoteDesc != null ? <Map<String, dynamic>>[] : null;
        final hasNotify = notificationManager.hasListeners(table.tableUid);

        // Mirror successful old-working rows before returning; skip when the
        // active transaction will abort and roll back those writes.
        Future<DbResult> finishWithPromoteMirror(DbResult r) async {
          final String? activeTxId = Zone.current[_txnZoneKey] as String?;
          final bool rollbackOnError =
              Zone.current[_txnRollbackOnErrorKey] as bool? ?? true;
          if (activeTxId != null && rollbackOnError && r.hasErrors) {
            promoteUpdated?.clear();
          } else {
            await _promoteFlushMirrorWritten(promoteDesc, promoteUpdated);
          }
          return finish(r);
        }

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
            tableMetaManager?.getUniqueIndexesFor(schema) ?? <IndexSchema>[];
        for (final index in allIndexes) {
          if (index.fields.any((f) => changedFields.contains(f))) {
            fieldsToCheck.addAll(index.fields);
          }
        }

        final preparedRecords = await prepareUniformUpdateRecords(
          schema,
          table,
          validData,
          records,
        );

        for (int recordIndex = 0; recordIndex < records.length; recordIndex++) {
          final y3 = yieldController.maybeYield();
          if (y3 != null) await y3;
          final record = records[recordIndex];
          final recordKey = record[primaryKey]?.toString() ?? '';
          if (recordKey.isEmpty) {
            continue; // Skip records without primary key
          }

          final updatedRecord = preparedRecords[recordIndex].updatedRecord;

          bool ok = true;
          UniqueViolation? uniqueViolation;
          List<List<dynamic>>? oldUniqueKeys;

          if (fieldsToCheck.isNotEmpty) {
            // 1. Try reserve unique keys first to lock the buffer
            try {
              oldUniqueKeys = writeBufferManager.tryReserveUniques(
                table: table,
                schema: schema,
                recordId: recordKey,
                data: updatedRecord,
                transactionId: txId,
                isUpdate: true,
                changedFields: changedFields,
              );
            } catch (e) {
              if (e is UniqueViolation) {
                if (continueOnPartialErrors) {
                  if (returnResultDetails) {
                    failedKeys.add(recordKey);
                  }
                  failedCount++;
                  continue;
                }
                return finishWithPromoteMirror(DbResult.error(
                  type: e.constraintResultType,
                  message: e.message,
                  failedKeys: returnResultDetails ? [recordKey] : const [],
                ));
              }
              rethrow;
            }

            // 2. Validate foreign key constraints after reservation
            if (hasForeignKeys && changedFields.isNotEmpty) {
              try {
                await _foreignKeyManager!.validateForeignKeyConstraints(
                  table: table,
                  data: updatedRecord,
                  operation: ForeignKeyOperation.update,
                );
              } catch (e) {
                // Rollback reservation on FK failure
                try {
                  writeBufferManager.releaseReservedUniques(
                    table: table,
                    recordId: recordKey,
                    transactionId: txId,
                    rollbackKeys: oldUniqueKeys,
                  );
                } catch (_) {}

                Logger.error('Foreign key constraint validation failed',
                    rawError: e);
                if (continueOnPartialErrors) {
                  if (returnResultDetails) {
                    failedKeys.add(recordKey);
                  }
                  failedCount++;
                  continue;
                }
                return finishWithPromoteMirror(DbResult.error(
                  type: ResultType.bizForeignKeyViolation,
                  message: e.toString(),
                  failedKeys: returnResultDetails ? [recordKey] : const [],
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
              table,
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
                writeBufferManager.releaseReservedUniques(
                  table: table,
                  recordId: recordKey,
                  transactionId: txId,
                  rollbackKeys: oldUniqueKeys,
                );
              } catch (_) {}
            }
          }

          if (!ok) {
            if (returnResultDetails) {
              failedKeys.add(recordKey);
            }
            failedCount++;
            if (continueOnPartialErrors) {
              continue;
            }
            return finishWithPromoteMirror(DbResult.error(
              type: uniqueViolation?.constraintResultType ??
                  ResultType.bizUniqueViolation,
              message:
                  uniqueViolation?.message ?? 'Unique constraint violation',
              failedKeys: returnResultDetails ? [recordKey] : const [],
            ));
          }

          // Acquire row lock
          if (lockMgr != null) {
            try {
              final res = 'row:$tableName:pk:$recordKey';
              final opId = GlobalIdGenerator.generate('update_row_');
              final ok = await lockMgr.acquireExclusiveLock(res, opId);
              if (!ok) {
                writeBufferManager.releaseReservedUniques(
                  table: table,
                  recordId: recordKey,
                  transactionId: txId,
                  rollbackKeys: oldUniqueKeys,
                );
                if (continueOnPartialErrors) {
                  // release unique locks before continuing
                  if (returnResultDetails) {
                    failedKeys.add(recordKey);
                  }
                  failedCount++;
                  continue;
                }
                // release unique locks before returning
                return finishWithPromoteMirror(DbResult.error(
                  type: ResultType.engError,
                  message: 'Lock conflict on primary key $recordKey',
                ));
              }
              acquiredResources[res] = opId;
              if (txId != null) {
                TransactionContext.registerExclusiveLock(res, opId);
              }
            } catch (_) {
              // Lock threw after reserve: must not leave unique slots behind.
              writeBufferManager.releaseReservedUniques(
                table: table,
                recordId: recordKey,
                transactionId: txId,
                rollbackKeys: oldUniqueKeys,
              );
              if (continueOnPartialErrors) {
                if (returnResultDetails) {
                  failedKeys.add(recordKey);
                }
                failedCount++;
                continue;
              }
              rethrow;
            }
          }

          // Register write-set for SSI conflict detection
          if (txId != null) {
            transactionManager?.registerWriteKey(txId, table, recordKey);
          }

          // update write queue
          final Set<String> indexFields = <String>{primaryKey};
          final bool pkChanged = isPrimaryKeyUpdate &&
              record[primaryKey] != null &&
              updatedRecord[primaryKey] != null &&
              record[primaryKey] != updatedRecord[primaryKey];
          final allIndexes = <IndexSchema>[
            ...?tableMetaManager?.getAllIndexesFor(schema),
            ...?indexManager?.getEngineManagedBtreeIndexes(
              table,
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
          try {
            await tableDataManager.addToBuffer(
              table,
              updatedRecord,
              BufferOperationType.update,
              oldValues: oldValues.isEmpty ? null : oldValues,
              transactionId: txId,
              schemaVersion: table.schema.schemaVersion ?? '',
            );
          } catch (e) {
            writeBufferManager.releaseReservedUniques(
              table: table,
              recordId: recordKey,
              transactionId: txId,
              rollbackKeys: oldUniqueKeys,
            );
            rethrow;
          }

          if (hasNotify) {
            notificationManager.notify(ChangeEvent(
              type: ChangeType.update,
              tableUid: table.tableUid,
              record: updatedRecord,
              oldRecord: record,
            ));
          }

          // Add to success keys list (user-facing PK when promote is active).
          if (returnResultDetails) {
            successKeys.add(
              promoteDesc != null
                  ? _promoteUserFacingSuccessKey(
                      updatedRecord,
                      promoteDesc,
                      alternateRecord: record,
                    )
                  : recordKey,
            );
          }
          successCount++;
          promoteUpdated?.add(updatedRecord);
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
        if (successCount > 0 && failedCount > 0) {
          if (!returnResultDetails) {
            return finishWithPromoteMirror(DbResult(
              statuses: const [],
              successKeys: const [],
              failedKeys: const [],
              successCount: successCount,
              failedCount: failedCount,
            ));
          }
          return finishWithPromoteMirror(DbResult.batch(
            successKeys: successKeys,
            failedKeys: failedKeys,
            message:
                'Update partially successful, ${successKeys.length} records updated, ${failedKeys.length} records failed',
          ));
        } else {
          if (partialUniqueFailedKeys != null) {
            final int partialFailedCount = partialUniqueFailedKeys.length;
            if (!returnResultDetails) {
              return finishWithPromoteMirror(DbResult(
                statuses: const [],
                successKeys: const [],
                failedKeys: const [],
                successCount: successCount,
                failedCount: partialFailedCount,
              ));
            }
            return finishWithPromoteMirror(DbResult.batch(
              successKeys: successKeys,
              failedKeys: partialUniqueFailedKeys,
              message:
                  'Update partially successful, unique constraint skipped remaining records',
            ));
          }
          if (!returnResultDetails) {
            return finishWithPromoteMirror(DbResult(
              statuses: const [],
              successKeys: const [],
              failedKeys: const [],
              successCount: successCount,
              failedCount: 0,
            ));
          }
          return finishWithPromoteMirror(DbResult.success(
            successKeys: successKeys,
            message:
                'Update successful, affected ${successKeys.length} records',
          ));
        }
      }
    } catch (e) {
      Logger.error('Update failed', rawError: e);
      if (isInTransactionWithRollback()) {
        rethrow;
      }
      if (e is DbException) {
        return finish(DbResult.batch(
          statuses: returnResultDetails ? e.statuses : const [],
          successCount: 0,
          failedCount: e.statuses.length,
        ));
      }
      // Best-effort release locks
      try {
        final lockMgr = lockManager;
        if (lockMgr != null) {
          // We didn't retain acquiredResources here on exception; rely on txn zone or opId unreleased is acceptable in failure since lock timeout exists
        }
      } catch (_) {}
      return DbResult.error(
        type: ResultType.engError,
        message: 'Update failed: $e',
      );
    }
  }

  /// clear table
  /// Returns [DbResult] to allow graceful error handling for business logic errors
  /// (e.g., RESTRICT foreign key constraints) instead of throwing exceptions
  /// This is consistent with other business operations (insert, update, delete)
  ///
  /// [enablePromoteDualWrite] when true (default), also clears the promote shadow.
  Future<DbResult> clear(String tableName,
      {bool registerWalOp = true, bool enablePromoteDualWrite = true}) async {
    DbResult finish(DbResult r) => _returnOrThrowIfTxn(r, 'clear', tableName);

    if (registerWalOp) {
      await ensureInitialized();
    }

    String? clearOpId;
    try {
      final table = await getTableContext(tableName);

      if (registerWalOp && config.enableJournal) {
        try {
          final cutoff = walManager.currentPointer;
          final opId = GlobalIdGenerator.generate('tbl_clear_');
          final op = TableOpMeta(
            opId: opId,
            tableUid: table.tableUid,
            type: 'clear',
            cutoff: cutoff,
            createdAt: DateTime.now().toIso8601String(),
          );
          await walManager.registerTableOp(op);
          clearOpId = opId;
        } catch (e) {
          Logger.warn('Register clear table op failed', rawError: e);
        }
      }

      // Handle foreign key cascade operations before clearing the table
      // This ensures data consistency: child records are handled according to foreign key policies
      if (_foreignKeyManager != null) {
        try {
          await _foreignKeyManager!.handleCascadeClear(table);
        } catch (e) {
          Logger.error('Cascade clear failed', rawError: e);
          // RESTRICT rejects before mutating children - drop the pending WAL op
          // so restart will not keep replaying a clear that never started.
          // Mid-cascade failures keep the op so resume can finish the wipe.
          if (_isFkRestrictBeforeMutation(e)) {
            await _abortRegisteredTableOp(clearOpId);
          }
          return finish(_normalizeCascadeError(e, 'clear'));
        }
      }

      // Abort in-flight / queued schema rewrites and purge all background writes
      // before wiping rows; otherwise a late flush could resurrect cleared data.
      // Key migration pause is global - always resume in finally after wipe.
      var keyMigrationPaused = false;
      try {
        keyMigrationPaused =
            await migrationManager?.reconcileOnClear(table) ?? false;

        // NOTE: clear() removes table data but keeps schema (esp. memory mode).
        await cacheManager.invalidateCache(table, invalidateSchema: false);
        await tableDataManager.clearTable(table);
        await _indexManager?.clearIndexesForTable(table);

        final promoteDesc = _promoteRuntimeForDualWrite(
          table.tableUid,
          enablePromoteDualWrite: enablePromoteDualWrite,
        );
        if (promoteDesc != null) {
          await _promoteMirrorClearShadow(promoteDesc);
        }
      } finally {
        // Restarts KeyMigrationRunner for remaining tables (and this empty one).
        migrationManager
            ?.resumeKeyMigrationAfterDestructive(keyMigrationPaused);
      }

      // Notify watchers that the table has been cleared
      notificationManager.notify(ChangeEvent(
        type: ChangeType.clear,
        tableUid: table.tableUid,
      ));

      // If there is no WAL segment newer than the cutoff (i.e. cutoff is at
      // or before checkpoint), the clear/drop op does not need to stay in
      // WAL meta for skip semantics. After a successful clear we can mark
      // the op as completed so that it will be removed if safe.
      if (registerWalOp && config.enableJournal && clearOpId != null) {
        try {
          await walManager.completeTableOp(clearOpId);
        } catch (e) {
          Logger.warn('Complete clear table op failed', rawError: e);
        }
      }

      return finish(DbResult.success(
        message: 'Table $tableName cleared successfully',
      ));
    } catch (e) {
      if (_isDevTableNotFound(e)) {
        if (isInTransactionWithRollback()) {
          rethrow;
        }
        return finish(DbResult.error(
          type: ResultType.devTableNotFound,
          message: 'Table $tableName does not exist',
          statuses: (e as DbException).statuses,
        ));
      }
      Logger.warn('Clear table failed', rawError: e);
      if (isInTransactionWithRollback()) {
        rethrow;
      }
      final dbEx = DbException.wrap(e,
          fallbackType: ResultType.engError,
          fallbackMessage: 'Failed to clear table $tableName');
      return finish(DbResult.batch(
        statuses: dbEx.statuses,
        failedCount: dbEx.statuses.length,
      ));
    }
  }

  /// Engine-facing delete. Defaults allow large-scale ops ([allowLargeScaleOperation]
  /// true) while still collecting per-row details on the normal path
  /// ([returnResultDetails] true). Public builders must pass
  /// [allowLargeScaleOperation] false unless the user chained
  /// [DeleteBuilder.allowLargeScaleOperation]. Large-scale path never returns
  /// primary-key lists (only [DbResult.successCount]), regardless of
  /// [returnResultDetails].
  Future<DbResult> deleteInternal(
    TableContext table,
    QueryCondition condition, {
    List<String>? orderBy,
    int? limit,
    int? offset,
    bool allowAll = false,
    bool returnResultDetails = true,
    bool allowLargeScaleOperation = true,
    bool enablePromoteDualWrite = true,
  }) async {
    final tableName = table.tableName;
    DbResult finish(DbResult r) => _returnOrThrowIfTxn(r, 'delete', tableName);
    await ensureInitialized();

    // Emergency Resource Check
    if (_resourceManager?.isWriteBlocked ?? false) {
      return finish(DbResult.error(
        type: ResultType.sysResourceExhausted,
        message:
            'Delete operation blocked: System resources are critically low.',
      ));
    }

    // check if condition is empty, avoid accidental deletion of all records
    if (condition.isEmpty) {
      if (!allowAll) {
        Logger.warn(
            'Delete operation without condition, this may cause accidental deletion of all records, please use allowDeleteAll() method to explicitly confirm.');
        const message =
            'Delete operation must specify a filter condition. If you really need to delete all records, please use allowDeleteAll() method to explicitly confirm.';
        return finish(DbResult.error(
          type: ResultType.devInvalidArgumentMissing,
          message: message,
          statuses: [
            InvalidArgumentStatus(
              type: ResultType.devInvalidArgumentMissing,
              message: message,
              parameterName: 'condition',
              passedValue: null,
            )
          ],
        ));
      } else {
        // If allowAll=true and no condition, use clear() for better performance
        Logger.info(
            'Using clear() for better performance when deleting all records');

        // Use clear() for better performance when deleting all records
        // clear() now returns DbResult for graceful error handling
        final clearResult = await clear(tableName,
            enablePromoteDualWrite: enablePromoteDualWrite);
        if (!clearResult.hasErrors) {
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
      final tableDataMeta =
          await tableDataManager.getTableDataMeta(table.tableUid);

      // Get memory manager to access cache size limits
      final recordCacheSize =
          resourceManager?.getRecordCacheSize() ?? 200 * 1024 * 1024;

      // get table schema
      final schema = table.schema;
      final promoteDesc = _promoteRuntimeForDualWrite(
        table.tableUid,
        enablePromoteDualWrite: enablePromoteDualWrite,
      );
      if (promoteDesc != null) {
        remapPromoteConditionNewToOld(condition, promoteDesc);
      }

      final conditionMap = condition.build();

      final primaryKey = schema.primaryKey;

      // Check if condition is an equality on primary key or unique field - this can be optimized
      bool isOptimizableQuery = false;
      // Small table heuristics: always optimize when
      // - table data meta is unknown or size invalid
      // - size < 5MB (unconditional minimum threshold)
      // - size < 30% of record cache size
      const int minSmallTableBytes = 50 * 1024 * 1024; // 50MB
      if (tableDataMeta == null ||
          tableDataMeta.totalSizeBytes < minSmallTableBytes ||
          tableDataMeta.totalSizeBytes < recordCacheSize * 0.3) {
        isOptimizableQuery = true;
      }

      if (!isOptimizableQuery) {
        // Analyze condition to check if it's a primary key/unique/index-driven operation
        if (!condition.isEmpty) {
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
            final allIndexes = tableMetaManager?.getUniqueIndexesFor(schema) ??
                <IndexSchema>[];
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

      // Large-scale data delete path: engine defaults allow; public API must opt in
      if (!isOptimizableQuery) {
        if (promoteDesc != null) {
          return finish(_promoteRejectLargeOp(tableName, 'delete'));
        }
        if (!allowLargeScaleOperation) {
          const message =
              'This is a large-scale data delete operation. To prevent memory overflow, you must explicitly call allowLargeScaleOperation(). The operation will run in background batches and block until completion; success/failure primary keys and per-row status details are not returned. If interrupted, already-persisted changes are kept and you must retry to continue.';
          Logger.warn(message);
          return finish(DbResult.error(
            type: ResultType.devLargeScaleOperationRequired,
            message: message,
          ));
        }
        if (txId != null) {
          const message =
              'Large-scale data delete is not allowed inside a transaction. '
              'Run it outside the transaction with allowLargeScaleOperation().';
          Logger.warn(message);
          return finish(DbResult.error(
            type: ResultType.devLargeScaleOperationNotAllowedInTransaction,
            message: message,
          ));
        }

        final largeDeleteOpId = GlobalIdGenerator.generate('large_delete_');
        final outcome = await LargeOperationRunner.runLargeDelete(
          this,
          LargeDeleteRequest(
            opId: largeDeleteOpId,
            tableUid: table.tableUid,
            condition: conditionMap,
            orderBy: orderBy,
            limit: limit,
            offset: offset,
          ),
        );
        if (outcome.hasErrors) {
          return finish(DbResult.batch(
            statuses: outcome.errorStatuses,
            successCount: outcome.successCount,
            failedCount: outcome.errorStatuses.length,
            hasErrors: true,
          ));
        }

        return finish(DbResult(
          statuses: [
            SuccessStatus(
              message:
                  'Large-scale data delete completed (${outcome.successCount} records).',
            ),
          ],
          successCount: outcome.successCount,
          failedCount: 0,
          hasErrors: false,
        ));
      }

      // Optimizable path: get all matching records
      {
        // Use a large internal limit when limit is null to avoid default QueryLimit (e.g. 1000)
        final int effectiveLimit = limit ?? 1000000000;
        final recordsToDelete = (await queryExecutor.execute(
          table,
          condition: condition,
          orderBy: orderBy,
          limit: effectiveLimit,
          offset: offset,
        ))
            .records;

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
            final y4 = yieldController.maybeYield();
            if (y4 != null) await y4;
            final pkValue = record[primaryKey];
            if (pkValue != null) {
              // Phase 1: Always check RESTRICT/NO ACTION constraints immediately (even in transaction)
              // This ensures violations are caught early and transaction can be rolled back
              try {
                await _foreignKeyManager!.checkRestrictConstraintsForDelete(
                  table: table,
                  deletedPkValues: pkValue,
                );
              } catch (e) {
                Logger.error('RESTRICT constraint check failed', rawError: e);
                return finish(_normalizeCascadeError(e, 'delete'));
              }

              // Phase 2: Handle CASCADE/SET NULL/SET DEFAULT operations
              if (txId != null) {
                // In transaction: defer CASCADE operations until commit
                // RESTRICT has already been checked above, so we can safely defer CASCADE
                transactionManager?.registerDeferredCascadeDelete(
                    txId, table, pkValue);
              } else {
                // Outside transaction: execute CASCADE operations immediately
                try {
                  await _foreignKeyManager!.handleCascadeDelete(
                    table: table,
                    deletedPkValues: pkValue,
                    skipRestrictCheck: true, // RESTRICT already checked above
                  );
                } catch (e) {
                  Logger.error('Cascade delete failed', rawError: e);
                  return finish(_normalizeCascadeError(e, 'delete'));
                }
              }
            }
          }
        }

        // Collect successful keys. Engine internals (locks / write-set / cache)
        // always use old-table PK; user-facing successKeys use promote source
        // field when active - collected directly, no post-pass remap.
        final List<String> successKeys = [];
        final List<String> deletedOldPks = [];
        int successCount = 0;

        // Row-level locks for delete
        final lockMgr = lockManager;
        final Map<String, String> acquiredResources = {};

        final yieldController =
            YieldController('DataStoreImpl._deleteInternal.loop');
        for (var i = 0; i < recordsToDelete.length; i++) {
          final record = recordsToDelete[i];
          final oldPk = record[primaryKey]?.toString();
          if (oldPk == null) {
            continue;
          }
          // Acquire lock per record with unique operation id per resource
          if (lockMgr != null) {
            try {
              final res = 'row:$tableName:pk:$oldPk';
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
          deletedOldPks.add(oldPk);
          if (returnResultDetails) {
            successKeys.add(
              promoteDesc != null
                  ? _promoteUserFacingSuccessKey(record, promoteDesc)
                  : oldPk,
            );
          }
          successCount++;

          // Register write-set for SSI conflict detection
          if (txId != null) {
            transactionManager?.registerWriteKey(txId, table, oldPk);
          }

          final y5 = yieldController.maybeYield();
          if (y5 != null) await y5;
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
          await tableDataManager.removeTableRecords(table, deletedOldPks);
        }

        // Add records to delete buffer instead of directly writing to file
        await tableDataManager.addToDeleteBuffer(
          table,
          recordsToDelete,
          schemaVersion: table.schema.schemaVersion ?? '',
        );

        if (notificationManager.hasListeners(table.tableUid)) {
          for (final record in recordsToDelete) {
            notificationManager.notify(ChangeEvent(
              type: ChangeType.delete,
              tableUid: table.tableUid,
              oldRecord: record,
            ));
          }
        }

        if (promoteDesc != null && successCount > 0) {
          await _promoteMirrorDeleteFromShadow(promoteDesc, recordsToDelete);
        }

        if (!returnResultDetails) {
          return finish(DbResult(
            statuses: const [],
            successKeys: const [],
            failedKeys: const [],
            successCount: successCount,
            failedCount: 0,
          ));
        }

        return finish(DbResult.success(
          successKeys: successKeys,
          message: 'Successfully deleted ${successKeys.length} records',
        ));
      }
    } catch (e) {
      Logger.error('Delete failed', rawError: e);
      if (isInTransactionWithRollback()) {
        rethrow;
      }
      final dbEx = DbException.wrap(e,
          fallbackType: ResultType.engError, fallbackMessage: 'Delete failed');
      return finish(DbResult.batch(
        statuses: dbEx.statuses,
        failedCount: dbEx.statuses.length,
      ));
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
        final tableName =
            (await tableMetaManager?.resolveTableNameFromField(op.tableUid))
                    ?.value ??
                'unknown';
        try {
          // 1) Re-execute the physical operation, but do not re-register WAL metadata
          if (op.type == 'clear') {
            if (tableName == 'unknown') {
              Logger.warn(
                'Skip resume clear for op ${op.opId}: table no longer exists',
              );
              continue;
            }
            final clearResult = await clear(tableName, registerWalOp: false);
            if (clearResult.hasErrors) {
              Logger.error(
                'Failed to resume clear operation for table $tableName: ${clearResult.message}',
              );
              // Continue with next operation even if this one failed
              continue;
            }
          } else if (op.type == 'drop') {
            final dropResult = await dropTable(
              tableName,
              isMigration: false,
              registerWalOp: false,
            );
            if (dropResult.hasErrors) {
              Logger.error(
                'Failed to resume drop operation for table $tableName: ${dropResult.message}',
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
                'Complete resumed table operation failed for ${op.opId}',
                rawError: e);
          }
        } catch (e) {
          Logger.warn(
              'Resume table operation failed for ${op.opId} (${op.type} $tableName)',
              rawError: e);
        }
      }
    } catch (e) {
      Logger.error('Resume pending table operations failed', rawError: e);
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
    final effectiveIsolation =
        isolation ?? config.defaultTransactionIsolationLevel;
    final bool isSerializable =
        effectiveIsolation == TransactionIsolationLevel.serializable;
    if (isSerializable) {
      transactionManager!
          .registerActiveSsiTransaction(txId, started.millisecondsSinceEpoch);
    }
    bool logFlushed = false;
    try {
      final result = await runZoned(() async {
        final Duration timeout = config.transactionTimeout;
        Future<void> doWork() async {
          try {
            tableDataManager.ensureTransactionWithinResourceLimits(txId);
            await Future.sync(action);
            // If SSI, check conflicts before applying commit
            if (isSerializable) {
              final readKeys = TransactionContext.getReadKeys();
              final conflicts = await transactionManager!
                  .checkSerializableConflictsTransactional(
                      readKeys, started, txId);
              if (conflicts.isNotEmpty) {
                throw DbException([
                  TransactionOperationStatus(
                    type: ResultType.sysTransactionConflict,
                    message:
                        'Serializable conflict on: ${conflicts.take(5).join(', ')}',
                    txId: txId,
                  )
                ]);
              }
            }
            tableDataManager.ensureTransactionWithinResourceLimits(txId);
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
              throw DbException([
                TransactionOperationStatus(
                  type: ResultType.sysTimeout,
                  message:
                      'Transaction timed out after ${timeout.inMilliseconds} ms',
                  txId: txId,
                )
              ]);
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
        TransactionContext.isolationLevelKey: effectiveIsolation,
        TransactionContext.acquiredExclusiveLocksKey: <String, String>{},
        TransactionContext.readKeysKey: <TableUid, Set<String>>{},
      });
      return result;
    } catch (e) {
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
      final List<ResultStatus> statuses;
      if (e is DbException) {
        statuses = e.statuses;
      } else {
        final resultType = _classifyErrorToResultType(e);
        statuses = [
          TransactionOperationStatus(
            type: resultType,
            message: e.toString(),
            txId: txId,
          ),
        ];
      }
      return TransactionResult.failed(
        txId: txId,
        startedAt: started,
        finishedAt: finished,
        statuses: statuses,
      );
    } finally {
      // Idempotent: commit/rollback already unregister; covers early failures.
      if (isSerializable) {
        transactionManager?.unregisterActiveSsiTransaction(txId);
      }
    }
  }

  ResultType _classifyErrorToResultType(Object e) {
    if (e is DbException) {
      return e.statuses.isNotEmpty
          ? e.statuses.first.type
          : ResultType.engError;
    }
    if (e is TimeoutException) return ResultType.sysTimeout;
    final msg = e.toString().toLowerCase();
    if (msg.contains('timeout')) return ResultType.sysTimeout;
    return ResultType.sysTransactionAborted;
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

      final table = await getTableContext(tableName);
      String? dropOpId;
      if (isMigration) {
        // During migration, only delete the table data directory in the current space
        Logger.info(
          'Deleting table $tableName data in space $_currentSpaceName during migration',
        );

        final tablePath = await _pathManager!.getTablePathByUid(table.tableUid);
        if (await storage.existsDirectory(tablePath)) {
          await storage.deleteDirectory(tablePath);
          Logger.info(
            'Deleted data directory for table $tableName in space $_currentSpaceName: $tablePath',
          );
        }
        await tableMetaManager?.deleteTableMeta(table.tableUid);

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
              tableUid: table.tableUid,
              type: 'drop',
              cutoff: cutoff,
              createdAt: DateTime.now().toIso8601String(),
            );
            await walManager.registerTableOp(op);
            dropOpId = opId;
          } catch (e) {
            Logger.warn('Register drop table op failed', rawError: e);
          }
        }

        // Handle foreign key cascade operations before dropping the table
        if (_foreignKeyManager != null) {
          try {
            await _foreignKeyManager!.handleCascadeClear(table);
          } catch (e) {
            Logger.error('Cascade drop failed', rawError: e);
            if (_isFkRestrictBeforeMutation(e)) {
              await _abortRegisteredTableOp(dropOpId);
            }
            return finish(_normalizeCascadeError(e, 'drop'));
          }

          // Clean up system table entries for the dropped table
          await _foreignKeyManager!.cleanupSystemTableForDroppedTable(table);
        }

        // Abort and remove all pending/running schema tasks for this table
        // before physical delete rewrites must not touch a dropped table.
        // Key migration pause is global always resume in finally after drop.
        var keyMigrationPaused = false;
        try {
          keyMigrationPaused =
              await migrationManager?.reconcileOnDrop(table) ?? false;

          // Clear table memory caches and table-manager state (not disk wipe).
          await cacheManager.invalidateCache(table, removeTableState: true);

          // Deleting a table requires updating statistics
          await tableDataManager.tableDeleted(table);

          // Get table path
          String? tablePath;
          try {
            tablePath = await _pathManager!.getTablePathByUid(table.tableUid);
          } catch (e) {
            // skip
          }

          // Delete table structure
          if (tableMetaManager != null) {
            await tableMetaManager!.deleteTableMeta(table.tableUid);
          }

          // Delete table directory and all related files
          if (tablePath != null && await storage.existsDirectory(tablePath)) {
            await storage.deleteDirectory(tablePath);
          }
        } finally {
          migrationManager
              ?.resumeKeyMigrationAfterDestructive(keyMigrationPaused);
        }

        if (registerWalOp) {
          // Cross-space cleanup: pass schema snapshot because current-space
          // meta/dir are already deleted above.
          await migrationManager?.addMigrationTask(
            table.tableUid,
            [const MigrationOperation(type: MigrationType.dropTable)],
            oldSchemaSnapshot: table.schema,
          );
        }

        // Same rationale as clear(): after the physical drop has completed,
        // try to mark the table-op as completed so that it can be removed
        // from WAL meta when its cutoff is not newer than checkpoint.
        if (registerWalOp && config.enableJournal && dropOpId != null) {
          try {
            await walManager.completeTableOp(dropOpId);
          } catch (e) {
            Logger.warn('Complete drop table op failed', rawError: e);
          }
        }

        Logger.info('Table $tableName has been successfully deleted');

        // Notify watchers that the table has been dropped/cleared
        notificationManager.notify(ChangeEvent(
          type: ChangeType.clear,
          tableUid: table.tableUid,
        ));

        return finish(DbResult.success(
          message: 'Table $tableName dropped successfully',
        ));
      }
    } catch (e) {
      if (_isDevTableNotFound(e)) {
        if (isInTransactionWithRollback()) {
          rethrow;
        }
        return finish(DbResult.error(
          type: ResultType.devTableNotFound,
          message: 'Table $tableName does not exist',
          statuses: (e as DbException).statuses,
        ));
      }
      Logger.error('Failed to delete table', rawError: e);
      if (isInTransactionWithRollback()) {
        rethrow;
      }
      final dbEx = DbException.wrap(e,
          fallbackType: ResultType.engError,
          fallbackMessage: 'Failed to drop table $tableName');
      return finish(DbResult.batch(
        statuses: dbEx.statuses,
        failedCount: dbEx.statuses.length,
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
    if (tableMetaManager == null) return false;
    try {
      final schema =
          await tableMetaManager!.getTableSchemaByName(TableName(tableName));
      return schema != null;
    } catch (e) {
      Logger.error('Failed to check table existence', rawError: e);
      return false;
    }
  }

  /// Get table names.
  ///
  /// [onlyUserTables] returns only user tables (not system tables).
  /// [isGlobal] filters by table scope (`true` / `false` / `null` = both).
  Future<List<String>> getTableNames({
    bool? isGlobal,
    bool onlyUserTables = false,
  }) async {
    if (tableMetaManager == null) return <String>[];
    try {
      return await tableMetaManager!.listAllTables(
        isGlobal: isGlobal,
        onlyUserTables: onlyUserTables,
      );
    } catch (e) {
      Logger.error('Failed to get table names', rawError: e);
      return [];
    }
  }

  /// batch insert data
  /// [allowPartialErrors] if true, continue processing remaining records even if some fail
  /// [enablePromoteDualWrite] user-facing default true; pass false when caller
  /// owns promote mirroring (e.g. [batchUpsert]) or when writing the shadow table.
  /// [promoteResultKeyDesc] when dual-write is disabled but caller still wants
  /// user-facing success keys (O(1) per success row in the existing loop).
  Future<DbResult> batchInsert(
      String tableName, List<Map<String, dynamic>> records,
      {bool allowPartialErrors = true,
      bool returnResultDetails = true,
      bool enablePromoteDualWrite = true,
      PromoteRuntimeDescriptor? promoteResultKeyDesc}) async {
    DbResult finish(DbResult r) =>
        _returnOrThrowIfTxn(r, 'batchInsert', tableName);
    await ensureInitialized();

    // Emergency Resource Check
    if (_resourceManager?.isWriteBlocked ?? false) {
      return finish(DbResult.error(
        type: ResultType.sysResourceExhausted,
        message:
            'Insert operation blocked: System resources are critically low.',
      ));
    }

    if (records.isEmpty) {
      return finish(DbResult.success(
        message: 'No records to insert',
        successKeys: [],
      ));
    }

    // Capture transaction id once
    final String? txId = Zone.current[_txnZoneKey] as String?;

    TableSchema? schema;
    TableContext? tableForRelease;
    final Set<String> reservedNotBuffered = <String>{};
    try {
      // 1. Get table schema and validate data
      final table = await getTableContext(tableName);
      tableForRelease = table;
      schema = table.schema;
      if (schema.name.isEmpty) {
        Logger.error('Table $tableName does not exist');
        return finish(DbResult.error(
          type: ResultType.devTableNotFound,
          message: 'Table $tableName does not exist',
        ));
      }

      final promoteDesc = _promoteRuntimeForDualWrite(
        table.tableUid,
        enablePromoteDualWrite: enablePromoteDualWrite,
      );
      final promoteKeyDesc = promoteDesc ?? promoteResultKeyDesc;
      if (promoteDesc != null) {
        final remapYield = YieldController(
          'DataStoreImpl.batchInsert.promoteRemap',
          checkInterval: 256,
        );
        for (final record in records) {
          final y6 = remapYield.maybeYield();
          if (y6 != null) await y6;
          _promoteRemapRecordNewToOld(record, promoteDesc);
        }
      }
      // Collect successful rows for shadow mirror when dual-write is enabled.
      final promoteWritten =
          promoteDesc != null ? <Map<String, dynamic>>[] : null;

      // Mirror successful old-working rows before returning; skip when the
      // active transaction will abort and roll back those writes.
      Future<DbResult> finishWithPromoteMirror(DbResult r) async {
        final String? activeTxId = Zone.current[_txnZoneKey] as String?;
        final bool rollbackOnError =
            Zone.current[_txnRollbackOnErrorKey] as bool? ?? true;
        if (activeTxId != null && rollbackOnError && r.hasErrors) {
          promoteWritten?.clear();
        } else {
          await _promoteFlushMirrorWritten(promoteDesc, promoteWritten);
        }
        return finish(r);
      }

      final TableSchema tableSchema = schema;
      final primaryKey = tableSchema.primaryKey;
      // Cache unique indexes for this table once per batch to avoid repeated
      // tableMetaManager lookups inside the hot record loop.
      final uniqueIndexesForTable =
          tableMetaManager?.getUniqueIndexesFor(tableSchema) ?? <IndexSchema>[];
      // Whether table has secondary (non-PK) unique indexes.
      final bool hasSecondaryUniqueIndexes = uniqueIndexesForTable.isNotEmpty;
      // Build a single fieldName -> FieldSchema map per table for this batch and
      // reuse it across all records to avoid per-record reconstruction cost.
      final fieldMapForValidation = {
        for (final f in tableSchema.fields) f.name: f
      };

      // Snapshot table data meta once: avoids repeated meta reads in hot loops.
      final tableDataMeta =
          await tableDataManager.getTableDataMeta(table.tableUid);
      // We can safely skip disk unique checks if there is no committed data.
      final bool hasCommittedData =
          tableDataMeta != null && tableDataMeta.totalRecordCount > 0;
      final bool skipDiskUniqueChecks = !hasCommittedData;
      final pkMatcher =
          ValueMatcher.getMatcher(tableSchema.getPrimaryKeyMatcherType());

      // FK validation is expensive; skip completely when table has no enabled FKs.
      final bool hasForeignKeys = _foreignKeyManager != null &&
          tableSchema.foreignKeys.any((fk) => fk.enabled);

      var recordsToProcess = List<Map<String, dynamic>>.from(records);
      final invalidRecords = <Map<String, dynamic>>[];
      final List<String> successKeys = [];
      final List<String> failedKeys = [];
      int successCount = 0;
      int failedCount = 0;
      // Collect a limited number of detailed validation error messages for result reporting.
      // This is per-batch only and does not grow with table size, so it is safe for large-scale data.
      final List<String> validationErrorsForResult = [];
      final List<ResultStatus> batchStatuses = [];
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
              table, recordsNeedingPk.length);

          if (newIds.length != recordsNeedingPk.length) {
            // Primary key generation failed for some/all records.
            if (!allowPartialErrors) {
              // Fail the entire batch.
              final allKeys = records
                  .map((r) => r[primaryKey]?.toString())
                  .where((k) => k != null && k.isNotEmpty)
                  .map((k) => k!)
                  .toList();
              return finish(DbResult.error(
                type: ResultType.engError,
                message:
                    'Failed to generate enough primary keys for batch insert',
                failedKeys: returnResultDetails ? allKeys : const [],
              ));
            } else {
              // Mark records that needed a key as invalid and remove them from processing.
              for (final record in recordsNeedingPk) {
                invalidRecords.add(record);
                failedCount++;
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
        return finish(DbResult.error(
          type: ResultType.engError,
          message:
              'All ${invalidRecords.length} records failed during primary key generation.',
          // failedKeys is empty because these records never received a key.
        ));
      }

      try {
        // Prepare + reserve + flush in windows of [bufferBatchSize].
        // Prepare now runs on the current isolate (no Map isolate transfer), so
        // avoid the old memory-aware adaptive planner / system-memory probe that
        // only existed to size isolate tasks.
        const int bufferBatchSize = 100000;

        int start = 0;
        while (start < recordsToProcess.length) {
          final int end = min(start + bufferBatchSize, recordsToProcess.length);
          final currentRecords = recordsToProcess.sublist(start, end);
          final preparedRecords = await _prepareBatchInsertRecords(
            tableSchema,
            table,
            currentRecords,
            autoPkRecords,
          );

          final yieldController = YieldController(
            'DataStoreImpl.batchInsert.loop',
            minCheckInterval: EngineCpuChunk.hotPathMinCheckInterval,
          );

          // Optimization: Create batch context to hoist table/buffer lookups out of the record loop
          final batchContext =
              writeBufferManager.createBatchReserveContext(table, txId);

          // Collect valid records for a single bulk enqueue into WAL + buffer + cache.
          final batchRecordsForBuffer = <Map<String, dynamic>>[];
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
                      table,
                      recs,
                      schemaOverride: tableSchema,
                      skipBufferCheck: true,
                    );
                  } catch (e) {
                    // Fallback: chunked validation to reduce peak memory/IO pressure.
                    // This keeps correctness (still checks committed data) while preventing
                    // "all failed" outcomes caused by transient overload.
                    Logger.warn(
                        'Batch unique disk check failed for ${recs.length} records, fallback to chunked checks',
                        rawError: e);
                    const int chunkSize = 512;
                    final out = List<UniqueViolation?>.filled(recs.length, null,
                        growable: false);
                    for (int off = 0; off < recs.length; off += chunkSize) {
                      final y = yieldController.maybeYield();
                      if (y != null) await y;
                      final int to = (off + chunkSize < recs.length)
                          ? off + chunkSize
                          : recs.length;
                      final sub = recs.sublist(off, to);
                      final subVios =
                          await _indexManager!.checkUniqueConstraintsBatch(
                        table,
                        sub,
                        schemaOverride: tableSchema,
                        skipBufferCheck: true,
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
                  final keepOriginalById = <String, Map<String, dynamic>>{};
                  final filterYield = YieldController(
                    'DataStore.batchInsert.flush.filter',
                    minCheckInterval: EngineCpuChunk.hotPathMinCheckInterval,
                  );

                  for (int i = 0; i < batchRecordsForBuffer.length; i++) {
                    final y7 = filterYield.maybeYield();
                    if (y7 != null) await y7;
                    final vio = vios[i];
                    final rec = batchRecordsForBuffer[i];
                    final rid = rec[primaryKey]?.toString() ?? '';

                    if (vio == null) {
                      keepRecords.add(rec);
                      if (rid.isNotEmpty) {
                        keepOriginalById[rid] = batchOriginalById[rid] ?? rec;
                      }
                      continue;
                    }

                    // Conflict with committed data: drop this record.
                    if (rid.isNotEmpty) {
                      try {
                        writeBufferManager.releaseReservedUniques(
                          table: table,
                          recordId: rid,
                          transactionId: txId,
                        );
                      } catch (_) {}
                      reservedNotBuffered.remove(rid);

                      final orig = batchOriginalById[rid];
                      if (orig != null) {
                        invalidRecords.add(orig);
                        // Efficient error capture for reporting
                        if (validationErrorsForResult.length < 20) {
                          validationErrorsForResult
                              .add('pk=$rid: [Disk Conflict] ${vio.message}');
                        }
                      }
                      final originalIndex = recordsToProcess
                          .indexWhere((r) => r[primaryKey]?.toString() == rid);
                      final effectiveIndex =
                          originalIndex != -1 ? originalIndex + start : 0;
                      if (returnResultDetails) {
                        batchStatuses.add(ConstraintStatus(
                          type: vio.constraintResultType,
                          message: 'pk=$rid: [Disk Conflict] ${vio.message}',
                          tableName: tableName,
                          fields: vio.fields,
                          conflictingKeys: [vio.value],
                          index: effectiveIndex,
                          primaryKey: rid,
                          constraintName: vio.indexName?.value,
                        ));
                        failedKeys.add(rid);
                      }
                      failedCount++;
                    }
                  }

                  batchRecordsForBuffer
                    ..clear()
                    ..addAll(keepRecords);
                  batchOriginalById
                    ..clear()
                    ..addAll(keepOriginalById);
                }
              } catch (e) {
                Logger.warn('Batch unique disk check failed', rawError: e);
                // Safety: if we cannot validate uniqueness reliably, treat as failure to avoid corruption.
                // We conservatively fail all pending records in this flush batch.
                final failYield = YieldController(
                  'DataStore.batchInsert.flush.failAll',
                  minCheckInterval: EngineCpuChunk.hotPathMinCheckInterval,
                );
                for (final rec in batchRecordsForBuffer) {
                  final y8 = failYield.maybeYield();
                  if (y8 != null) await y8;
                  final rid = rec[primaryKey]?.toString() ?? '';
                  if (rid.isEmpty) continue;
                  try {
                    writeBufferManager.releaseReservedUniques(
                      table: table,
                      recordId: rid,
                      transactionId: txId,
                    );
                  } catch (_) {}
                  reservedNotBuffered.remove(rid);
                  final orig = batchOriginalById[rid];
                  if (orig != null) invalidRecords.add(orig);
                  if (returnResultDetails) {
                    failedKeys.add(rid);
                  }
                  failedCount++;
                }
                batchRecordsForBuffer.clear();
                batchOriginalById.clear();
              }
            }

            if (batchRecordsForBuffer.isEmpty) {
              return false;
            }

            final bufferResult = await tableDataManager.addBatchToBuffer(
              table: table,
              records: batchRecordsForBuffer,
              operation: BufferOperationType.insert,
              schema: tableSchema,
              transactionId: txId,
              schemaVersion: tableSchema.schemaVersion ?? '',
            );

            if (bufferResult.successRecordIds.isNotEmpty) {
              for (final id in bufferResult.successRecordIds) {
                reservedNotBuffered.remove(id);
              }
              successCount += bufferResult.successRecordIds.length;

              final hasNotify =
                  notificationManager.hasListeners(tableSchema.tableUid);
              if (promoteKeyDesc != null ||
                  promoteWritten != null ||
                  hasNotify) {
                final successSet = bufferResult.successRecordIds.toSet();
                for (final record in batchRecordsForBuffer) {
                  final pkVal = record[primaryKey]?.toString();
                  if (pkVal == null || !successSet.contains(pkVal)) continue;
                  if (returnResultDetails) {
                    successKeys.add(
                      promoteKeyDesc != null
                          ? _promoteUserFacingSuccessKey(record, promoteKeyDesc)
                          : pkVal,
                    );
                  }
                  promoteWritten?.add(record);
                  if (hasNotify) {
                    notificationManager.notify(ChangeEvent(
                      type: ChangeType.insert,
                      tableUid: tableSchema.tableUid,
                      record: record,
                    ));
                  }
                }
              } else if (returnResultDetails) {
                successKeys.addAll(bufferResult.successRecordIds);
              }
            }

            bool hadFailures = false;
            if (bufferResult.failedRecordIds.isNotEmpty) {
              hadFailures = true;
              for (final failedId in bufferResult.failedRecordIds) {
                try {
                  writeBufferManager.releaseReservedUniques(
                    table: table,
                    recordId: failedId,
                    transactionId: txId,
                  );
                } catch (_) {}
                reservedNotBuffered.remove(failedId);
                final orig = batchOriginalById[failedId];
                if (orig != null) invalidRecords.add(orig);
                if (failedId.isNotEmpty) {
                  if (returnResultDetails) {
                    failedKeys.add(failedId);
                  }
                  failedCount++;
                }
              }
            }

            batchRecordsForBuffer.clear();
            batchOriginalById.clear();

            return hadFailures;
          }

          final recordErrors = <String>[];

          // Process prepared records: reserve unique keys and enqueue for flush.
          for (int offset = 0; offset < currentRecords.length; offset++) {
            final int j = start + offset;
            final record = currentRecords[offset];
            final preparedRecord = preparedRecords[offset];
            final loopYield = yieldController.maybeYield();
            if (loopYield != null) await loopYield;

            final bool isAutoPk = autoPkRecords.contains(record);

            try {
              bool finishedRecord = false;
              bool triedPkConflictRetry = false;

              while (!finishedRecord) {
                Map<String, dynamic>? validData;
                recordErrors.clear();
                if (triedPkConflictRetry) {
                  // Conflict retries are rare; keep them on the mature local path.
                  try {
                    validData = await _validateAndProcessData(
                      tableSchema,
                      record,
                      table,
                      skipPrimaryKeyFormatCheck: isAutoPk,
                      validationErrors: recordErrors,
                      fieldMap: fieldMapForValidation,
                    );
                  } on DbException catch (e) {
                    recordErrors.addAll(e.statuses.map((s) => s.message));
                    if (returnResultDetails) {
                      for (final s in e.statuses) {
                        batchStatuses.add(ResultStatus.fromJson(s.toJson(),
                            indexOverride: j));
                      }
                    }
                  }
                } else {
                  validData = preparedRecord.validData;
                  recordErrors.addAll(preparedRecord.validationErrors);

                  // Auto-generated PKs may be reassigned after an earlier conflict.
                  if (validData != null &&
                      isAutoPk &&
                      record.containsKey(primaryKey) &&
                      record[primaryKey] != null) {
                    validData[primaryKey] = tableSchema.primaryKeyConfig
                        .convertPrimaryKey(record[primaryKey],
                            tableName: tableName);
                  }
                }

                if (validData == null) {
                  invalidRecords.add(record);
                  final failedKey = record[primaryKey]?.toString() ?? '';
                  if (returnResultDetails && failedKey.isNotEmpty) {
                    failedKeys.add(failedKey);
                  }
                  failedCount++;
                  if (recordErrors.isNotEmpty &&
                      validationErrorsForResult.length < 20) {
                    final prefix =
                        failedKey.isNotEmpty ? 'pk=$failedKey' : 'index=$j';
                    validationErrorsForResult
                        .add('$prefix: ${recordErrors.join("; ")}');
                  }
                  if (!triedPkConflictRetry) {
                    if (returnResultDetails) {
                      if (preparedRecord.validationStatusesJson != null) {
                        for (final sJson
                            in preparedRecord.validationStatusesJson!) {
                          batchStatuses.add(
                              ResultStatus.fromJson(sJson, indexOverride: j));
                        }
                      } else {
                        batchStatuses.add(GeneralStatus(
                          type: ResultType.bizValidationFailed,
                          message: recordErrors.isNotEmpty
                              ? recordErrors.join("; ")
                              : 'Data validation failed',
                          index: j,
                        ));
                      }
                    }
                  }
                  finishedRecord = true;
                  break;
                }

                // Validate foreign key constraints (skip when table has no enabled FKs)
                if (hasForeignKeys) {
                  try {
                    await _foreignKeyManager!.validateForeignKeyConstraints(
                      table: table,
                      data: validData,
                      operation: ForeignKeyOperation.insert,
                    );
                  } catch (e) {
                    Logger.error('Foreign key constraint validation failed',
                        rawError: e);
                    invalidRecords.add(record);
                    final failedKey = validData[primaryKey]?.toString() ?? '';
                    if (returnResultDetails && failedKey.isNotEmpty) {
                      failedKeys.add(failedKey);
                    }
                    failedCount++;
                    if (returnResultDetails) {
                      if (e is DbException) {
                        for (final s in e.statuses) {
                          batchStatuses.add(ResultStatus.fromJson(s.toJson(),
                              indexOverride: j));
                        }
                      } else {
                        batchStatuses.add(GeneralStatus(
                          type: ResultType.bizForeignKeyViolation,
                          message: e.toString(),
                          index: j,
                        ));
                      }
                    }
                    finishedRecord = true;
                    break;
                  }
                }

                // Reservation based: try reserve unique keys first (schema+data)
                final recordId = validData[primaryKey].toString();
                try {
                  batchContext.tryReserve(
                    recordId,
                    validData,
                    isUpdate: false,
                    schema: tableSchema,
                  );
                  reservedNotBuffered.add(recordId);
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
                            table, pkVal);

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
                              table, maxInCurrentBatch);
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
                                table, subsequentToReassign.length);
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
                            rawError: e);
                      }
                      record[primaryKey] = null;
                      triedPkConflictRetry = true;
                      continue;
                    }

                    invalidRecords.add(record);
                    final failedKey = validData[primaryKey]?.toString() ?? '';
                    if (returnResultDetails && failedKey.isNotEmpty) {
                      failedKeys.add(failedKey);
                    }
                    failedCount++;
                    if (!allowPartialErrors) {
                      // Flush pending successful records to avoid leaving reservations behind.
                      await flushBatch();
                      return finishWithPromoteMirror(DbResult.error(
                        type: e.constraintResultType,
                        message: e.message,
                        failedKeys: returnResultDetails ? failedKeys : const [],
                      ));
                    }
                    finishedRecord = true;
                    break;
                  }
                  rethrow;
                }

                try {
                  batchRecordsForBuffer.add(validData);
                  batchOriginalById[recordId] = record;

                  // Flush is deferred to the end of the prepare window
                  // (window size == bufferBatchSize) to avoid mid-loop double work.

                  finishedRecord = true;
                } catch (e) {
                  // Release reservation on unexpected error
                  try {
                    writeBufferManager.releaseReservedUniques(
                      table: table,
                      recordId: recordId,
                      transactionId: txId,
                    );
                  } catch (_) {}
                  rethrow;
                }
              }
            } catch (e) {
              Logger.warn('Error processing record', rawError: e);
              invalidRecords.add(record);
              final failedKey = record[primaryKey]?.toString() ?? '';
              if (returnResultDetails && failedKey.isNotEmpty) {
                failedKeys.add(failedKey);
              }
              failedCount++;

              if (!allowPartialErrors) {
                // Flush pending successful records to avoid leaving reservations behind.
                await flushBatch();
                return finishWithPromoteMirror(DbResult.error(
                  type: ResultType.engError,
                  message: 'Error processing record: $e',
                  failedKeys: returnResultDetails ? failedKeys : const [],
                ));
              }
            }
          }

          final bool hadFlushFailures = await flushBatch();
          if (hadFlushFailures && !allowPartialErrors) {
            return finishWithPromoteMirror(DbResult.error(
              type: ResultType.engError,
              message: 'Error processing record: WAL append failed',
              failedKeys: returnResultDetails ? failedKeys : const [],
            ));
          }

          start = end;
        }

        if (returnResultDetails) {
          // Fill success statuses (match on user-facing keys when promote active)
          final successSet = successKeys.toSet();
          for (int i = 0; i < records.length; i++) {
            final oldPk = records[i][primaryKey]?.toString() ?? '';
            if (oldPk.isEmpty) continue;
            final displayPk = promoteKeyDesc != null
                ? _promoteUserFacingSuccessKey(records[i], promoteKeyDesc)
                : oldPk;
            if (successSet.contains(displayPk)) {
              batchStatuses.add(SuccessStatus(
                message: 'Record inserted successfully',
                index: i,
                primaryKey: displayPk,
              ));
            }
          }
        }

        // If no valid records and not allowing partial errors, return error
        if (successCount == 0) {
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
          return finishWithPromoteMirror(DbResult.error(
            type: ResultType.bizValidationFailed,
            message: message,
            failedKeys: returnResultDetails ? failedKeys : const [],
            statuses: returnResultDetails ? batchStatuses : const [],
          ));
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
          return finishWithPromoteMirror(DbResult.error(
            type: ResultType.bizValidationFailed,
            message: message,
            failedKeys: returnResultDetails ? failedKeys : const [],
            statuses: returnResultDetails ? batchStatuses : const [],
          ));
        }

        // Return result
        if (invalidRecords.isEmpty) {
          return finishWithPromoteMirror(DbResult(
            statuses: returnResultDetails ? batchStatuses : const [],
            successKeys: returnResultDetails ? successKeys : const [],
            failedKeys: const [],
            successCount: successCount,
            failedCount: 0,
          ));
        } else {
          String message =
              'Partial records inserted successfully, $successCount successful, $failedCount failed';
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
          return finishWithPromoteMirror(DbResult(
            statuses: returnResultDetails ? batchStatuses : const [],
            successKeys: returnResultDetails ? successKeys : const [],
            failedKeys: returnResultDetails ? failedKeys : const [],
            successCount: successCount,
            failedCount: failedCount,
          ));
        }
      } catch (e) {
        // Rollback transaction on error
        rethrow;
      }
    } catch (e) {
      Logger.error('Batch insertion failed', rawError: e);

      if (isInTransactionWithRollback()) {
        rethrow;
      }

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

      final dbEx = DbException.wrap(e,
          fallbackType: ResultType.engError,
          fallbackMessage: 'Batch insertion failed');
      return finish(DbResult.batch(
        statuses: returnResultDetails ? dbEx.statuses : const [],
        failedCount: dbEx.statuses.length,
        failedKeys: returnResultDetails ? failedKeys : const [],
      ));
    } finally {
      // Early returns (!allowPartialErrors) skip catch -- still release orphans.
      // Successes already committed bookkeeping -> release is a no-op for them.
      if (tableForRelease != null && reservedNotBuffered.isNotEmpty) {
        try {
          await writeBufferManager.releaseReservedUniquesForPks(
            table: tableForRelease,
            recordIds: reservedNotBuffered,
            transactionId: txId,
          );
        } catch (_) {}
        reservedNotBuffered.clear();
      }
    }
  }

  /// Batch upsert: each record must contain all non-nullable fields + pk or all fields
  /// of at least one unique index. No where support.
  /// Optimized to use batch index probing for high throughput.
  ///
  /// [enablePromoteDualWrite] user-facing default true; pass false for shadow
  /// backfill / mirror writes to prevent promote dual-write recursion.
  Future<DbResult> batchUpsert(
      String tableName, List<Map<String, dynamic>> records,
      {bool allowPartialErrors = true,
      bool returnResultDetails = true,
      bool enablePromoteDualWrite = true}) async {
    DbResult finish(DbResult r) =>
        _returnOrThrowIfTxn(r, 'batchUpsert', tableName);
    await ensureInitialized();

    if (_resourceManager?.isWriteBlocked ?? false) {
      return finish(DbResult.error(
        type: ResultType.sysResourceExhausted,
        message:
            'upsert operation blocked: System resources are critically low.',
      ));
    }

    if (records.isEmpty) {
      return finish(DbResult.success(
        message: 'No records to insert',
        successKeys: [],
      ));
    }

    final table = await getTableContext(tableName);
    final schema = table.schema;
    final promoteDesc = _promoteRuntimeForDualWrite(
      table.tableUid,
      enablePromoteDualWrite: enablePromoteDualWrite,
    );
    if (promoteDesc != null) {
      final remapYield = YieldController(
        'DataStoreImpl.batchUpsert.promoteRemap',
        checkInterval: 256,
      );
      for (final record in records) {
        final y9 = remapYield.maybeYield();
        if (y9 != null) await y9;
        _promoteRemapRecordNewToOld(record, promoteDesc);
      }
    }

    final uniqueIndexes =
        tableMetaManager?.getUniqueIndexesFor(schema) ?? <IndexSchema>[];
    final pk = schema.primaryKey;
    final successKeys = <String>[];
    final failedKeys = <String>[];
    int successCount = 0;
    int failedCount = 0;

    final validationErrorsForResult = <String>[];

    try {
      // 1. Bulk validation (O(N) CPU)
      final validatedRecords = <Map<String, dynamic>>[];
      final identifierResults = await _validateRecordIdentifiersBatch(
        schema,
        records,
        uniqueIndexes,
        checkRequiredFields: true,
      );
      final validationResultYield = YieldController(
        'DataStoreImpl.batchUpsert.validationResults',
        checkInterval: 1024,
      );
      for (int i = 0; i < records.length; i++) {
        final y10 = validationResultYield.maybeYield();
        if (y10 != null) await y10;
        final record = records[i];
        final err = identifierResults[i].error;
        if (err != null) {
          final failedKey = record[pk]?.toString() ?? 'index=$i';
          if (returnResultDetails) {
            failedKeys.add(record[pk]?.toString() ?? '');
          }
          failedCount++;

          if (validationErrorsForResult.length < 10) {
            validationErrorsForResult.add('pk=$failedKey: $err');
          }
          Logger.warn('Upsert validation failed for $failedKey: $err');

          if (!allowPartialErrors) {
            return finish(DbResult.error(
              type: ResultType.bizValidationFailed,
              message: err,
              failedKeys: returnResultDetails ? failedKeys : const [],
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
        return finish(DbResult(
          statuses: returnResultDetails
              ? [
                  GeneralStatus(
                      type: ResultType.bizValidationFailed, message: message)
                ]
              : const [],
          successKeys: const [],
          failedKeys: returnResultDetails ? failedKeys : const [],
          successCount: 0,
          failedCount: failedCount,
        ));
      }

      // 2. Full-set probing existence via unique indexes
      // Processing the full set here is more efficient as it maximizes
      // IndexManager's internal optimization and Page Cache reuse.
      final violations = await indexManager!.checkUniqueConstraintsBatch(
        table,
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
      // Promote mirror is owned once at this layer - nested batchUpdate /
      // batchInsert disable dual-write; pass promoteResultKeyDesc so success
      // keys are still O(1) user-facing reads without a post-mirror remap.
      // When promote is active, always collect keys so mirror can filter to
      // successful rows only (even if caller skipped returnResultDetails).
      final trackKeys = returnResultDetails || promoteDesc != null;

      Future<void> mirrorSuccessfulPromoteRows(List<String> userKeys) async {
        if (promoteDesc == null || userKeys.isEmpty) return;
        final successSet = userKeys.toSet();
        final toMirror = <Map<String, dynamic>>[];
        final mirrorYield = YieldController(
          'DataStoreImpl.batchUpsert.promoteMirrorFilter',
          checkInterval: 256,
        );
        for (final rec in validatedRecords) {
          final y11 = mirrorYield.maybeYield();
          if (y11 != null) await y11;
          final userPk = _promoteUserFacingSuccessKey(rec, promoteDesc);
          if (userPk.isNotEmpty && successSet.contains(userPk)) {
            toMirror.add(rec);
          }
        }
        if (toMirror.isNotEmpty) {
          await _promoteMirrorUpsertToShadow(promoteDesc, toMirror);
        }
      }

      if (toUpdate.isNotEmpty) {
        final upResult = await batchUpdate(
          tableName,
          toUpdate,
          allowPartialErrors: allowPartialErrors,
          returnResultDetails: trackKeys,
          enablePromoteDualWrite: false,
          promoteResultKeyDesc: promoteDesc,
        );
        if (!upResult.hasErrors || allowPartialErrors) {
          if (trackKeys) {
            successKeys.addAll(upResult.successKeys);
            failedKeys.addAll(upResult.failedKeys);
          }
          successCount += upResult.successCount;
          failedCount += upResult.failedCount;
        } else {
          // Prior sub-batches may already have landed on the old table.
          await mirrorSuccessfulPromoteRows(upResult.successKeys);
          return finish(
            returnResultDetails
                ? upResult
                : DbResult(
                    statuses: upResult.statuses,
                    successKeys: const [],
                    failedKeys: const [],
                    successCount: upResult.successCount,
                    failedCount: upResult.failedCount,
                  ),
          );
        }
      }

      // 4. Final Batch Insert for new records
      if (toInsert.isNotEmpty) {
        final insResult = await batchInsert(
          tableName,
          toInsert,
          allowPartialErrors: allowPartialErrors,
          returnResultDetails: trackKeys,
          enablePromoteDualWrite: false,
          promoteResultKeyDesc: promoteDesc,
        );
        if (trackKeys) {
          successKeys.addAll(insResult.successKeys);
          failedKeys.addAll(insResult.failedKeys);
        }
        successCount += insResult.successCount;
        failedCount += insResult.failedCount;
        if (!allowPartialErrors && insResult.hasErrors) {
          await mirrorSuccessfulPromoteRows(successKeys);
          return finish(
            returnResultDetails
                ? insResult
                : DbResult(
                    statuses: insResult.statuses,
                    successKeys: const [],
                    failedKeys: const [],
                    successCount: insResult.successCount,
                    failedCount: insResult.failedCount,
                  ),
          );
        }
      }

      // Online dual-write: old table already written above; mirror only
      // successful rows to the shadow (never re-write the old table).
      await mirrorSuccessfulPromoteRows(successKeys);

      String message = 'Batch upsert completed';
      if (failedCount > 0) {
        message =
            'Batch upsert partially successful: $successCount success, $failedCount failed';
        if (validationErrorsForResult.isNotEmpty) {
          message +=
              '. Validation errors: ${validationErrorsForResult.join(" | ")}';
        }
      }

      if (!returnResultDetails) {
        return finish(DbResult(
          statuses: const [],
          successKeys: const [],
          failedKeys: const [],
          successCount: successCount,
          failedCount: failedCount,
        ));
      }

      return finish(DbResult.batch(
        successKeys: successKeys,
        failedKeys: failedKeys,
        successCount: successCount,
        failedCount: failedCount,
        message: message,
      ));
    } catch (e) {
      Logger.error('Batch upsert failed', rawError: e);
      if (isInTransactionWithRollback()) {
        rethrow;
      }
      final dbEx = DbException.wrap(e,
          fallbackType: ResultType.engError,
          fallbackMessage: 'Batch upsert failed');
      return finish(DbResult.batch(
        statuses: returnResultDetails ? dbEx.statuses : const [],
        failedCount: dbEx.statuses.length,
      ));
    }
  }

  /// batch update data based on primary keys or unique identifiers.
  ///
  /// [enablePromoteDualWrite] user-facing default true; pass false when caller
  /// owns promote mirroring (e.g. [batchUpsert]) or when writing the shadow.
  /// [promoteResultKeyDesc] when dual-write is disabled but caller still wants
  /// user-facing success keys (O(1) per success row in the existing loop).
  Future<DbResult> batchUpdate(
      String tableName, List<Map<String, dynamic>> records,
      {bool allowPartialErrors = true,
      bool returnResultDetails = true,
      bool enablePromoteDualWrite = true,
      PromoteRuntimeDescriptor? promoteResultKeyDesc}) async {
    DbResult finish(DbResult r) =>
        _returnOrThrowIfTxn(r, 'batchUpdate', tableName);
    await ensureInitialized();

    // Emergency Resource Check
    if (_resourceManager?.isWriteBlocked ?? false) {
      return finish(DbResult.error(
        type: ResultType.sysResourceExhausted,
        message:
            'batch update operation blocked: System resources are critically low.',
      ));
    }

    if (records.isEmpty) {
      return finish(DbResult.success(
        message: 'No records to update',
        successKeys: [],
      ));
    }

    final TableSchema? schema =
        await tableMetaManager?.getTableSchemaByName(TableName(tableName));
    if (schema == null || schema.name.isEmpty) {
      return finish(DbResult.error(
        type: ResultType.devTableNotFound,
        message: 'Table $tableName does not exist',
      ));
    }

    final String? txId = Zone.current[_txnZoneKey] as String?;
    final table = await getTableContext(tableName);
    final promoteDesc = _promoteRuntimeForDualWrite(
      table.tableUid,
      enablePromoteDualWrite: enablePromoteDualWrite,
    );
    final promoteKeyDesc = promoteDesc ?? promoteResultKeyDesc;
    if (promoteDesc != null) {
      final remapYield = YieldController(
        'DataStoreImpl.batchUpdate.promoteRemap',
        checkInterval: 256,
      );
      for (final record in records) {
        final y12 = remapYield.maybeYield();
        if (y12 != null) await y12;
        _promoteRemapRecordNewToOld(record, promoteDesc);
      }
    }
    final promoteWritten =
        promoteDesc != null ? <Map<String, dynamic>>[] : null;

    // Mirror successful old-working rows before returning; skip when the
    // active transaction will abort and roll back those writes.
    Future<DbResult> finishWithPromoteMirror(DbResult r) async {
      final String? activeTxId = Zone.current[_txnZoneKey] as String?;
      final bool rollbackOnError =
          Zone.current[_txnRollbackOnErrorKey] as bool? ?? true;
      if (activeTxId != null && rollbackOnError && r.hasErrors) {
        promoteWritten?.clear();
      } else {
        await _promoteFlushMirrorWritten(promoteDesc, promoteWritten);
      }
      return finish(r);
    }

    final primaryKey = schema.primaryKey;
    final allUniqueIndexes =
        tableMetaManager?.getUniqueIndexesFor(schema) ?? <IndexSchema>[];

    final successKeys = <String>[];
    final failedKeys = <String>[];
    int successCount = 0;
    int failedCount = 0;
    final batchStatuses = <ResultStatus>[];
    // Reserved but not yet successfully buffered released on abort.
    final Set<String> outstandingReservedPks = <String>{};

    // 1. Identification & Resolution Phase
    // Pre-process records to ensure every record has a primary key.
    // If a record only has a unique identifier, resolve its PK via IndexManager.
    final List<Map<String, dynamic>> withPk = [];
    final List<Map<String, dynamic>> needsResolution = [];
    final List<Map<String, dynamic>> recordsNeedingIdentifierValidation = [];
    final List<int> recordsNeedingIdentifierValidationIndices = [];
    final identifierSplitYield = YieldController(
      'DataStoreImpl.batchUpdate.identify',
      checkInterval: 2048,
    );

    for (int i = 0; i < records.length; i++) {
      final y13 = identifierSplitYield.maybeYield();
      if (y13 != null) await y13;
      final record = records[i];
      final pkVal = record[primaryKey]?.toString();

      if (pkVal != null && pkVal.isNotEmpty) {
        withPk.add(record);
      } else {
        recordsNeedingIdentifierValidation.add(record);
        recordsNeedingIdentifierValidationIndices.add(i);
      }
    }

    if (recordsNeedingIdentifierValidation.isNotEmpty) {
      final identifierResults = await _validateRecordIdentifiersBatch(
        schema,
        recordsNeedingIdentifierValidation,
        allUniqueIndexes,
        checkRequiredFields: false,
      );
      final identifierResultYield = YieldController(
        'DataStoreImpl.batchUpdate.identifierResults',
        checkInterval: 1024,
      );

      for (int i = 0; i < recordsNeedingIdentifierValidation.length; i++) {
        final y14 = identifierResultYield.maybeYield();
        if (y14 != null) await y14;
        final record = recordsNeedingIdentifierValidation[i];
        final err = identifierResults[i].error;
        if (err != null) {
          final originalIndex = recordsNeedingIdentifierValidationIndices[i];
          final failedKey =
              record[primaryKey]?.toString() ?? 'missing_identifier';
          if (returnResultDetails) {
            failedKeys.add(failedKey);
          }
          failedCount++;
          if (!allowPartialErrors) {
            return finish(DbResult.error(
              type: ResultType.bizValidationFailed,
              message: 'Validation failed for record $originalIndex: $err',
              failedKeys: returnResultDetails ? failedKeys : const [],
            ));
          }
          continue;
        }
        needsResolution.add(record);
      }
    }

    // Perform batched PK resolution via IndexManager
    if (needsResolution.isNotEmpty) {
      // PERFORMANCE: IndexManager.checkUniqueConstraintsBatch now sorts probe keys internally.
      // resolveInPlace: true ensures records are updated with their existingPrimaryKey directly.
      await indexManager!.checkUniqueConstraintsBatch(
        table,
        needsResolution,
        schemaOverride: schema,
        isUpdate: false,
        resolveInPlace: true,
        transactionId: txId,
      );

      // Handle records that failed resolution (not found in DB/Buffer)
      for (final r in needsResolution) {
        if (r[primaryKey] == null) {
          if (returnResultDetails) {
            failedKeys.add('not_found');
          }
          failedCount++;
          if (!allowPartialErrors) {
            final idInfo = r.keys.take(3).map((k) => '$k=${r[k]}').join(', ');
            return finish(DbResult.error(
              type: ResultType.bizRecordNotFound,
              message: 'Record not found for unique identifier: {$idInfo}',
              failedKeys: returnResultDetails ? failedKeys : const [],
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
      return finish(DbResult(
        statuses: returnResultDetails
            ? [
                GeneralStatus(
                    type: ResultType.bizValidationFailed,
                    message: 'No valid records found to update')
              ]
            : const [],
        successKeys: returnResultDetails ? successKeys : const [],
        failedKeys: returnResultDetails ? failedKeys : const [],
        successCount: 0,
        failedCount: failedCount,
      ));
    }

    final batchYield =
        YieldController('DataStoreImpl.batchUpdate.batch', checkInterval: 1);
    final executionYield =
        YieldController('DataStoreImpl.batchUpdate.execute', checkInterval: 50);
    final hasNotify = notificationManager.hasListeners(schema.tableUid);

    try {
      // Process in batches to maintain UI responsiveness and manage memory
      const int batchSize = 1000;

      for (int i = 0; i < finalRecords.length; i += batchSize) {
        final y15 = batchYield.maybeYield();
        if (y15 != null) await y15;
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
        final results = (await queryExecutor.execute(
          table,
          condition: QueryCondition()..whereIn(primaryKey, pkList),
          limit: pkList.length,
        ))
            .records;

        // Convert results to a map for O(1) lookup
        final Map<String, Map<String, dynamic>> resultsMap = {
          for (var r in results) r[primaryKey].toString(): r
        };
        final existingRecords = List<Map<String, dynamic>?>.generate(
          subBatch.length,
          (index) {
            final pkVal = subBatch[index][primaryKey]?.toString();
            if (pkVal == null) return null;
            return resultsMap[pkVal];
          },
          growable: false,
        );

        // 5. Fast-path check for strict error mode (if results missing items)
        if (!allowPartialErrors && resultsMap.length < pkList.length) {
          for (final pkVal in pkList) {
            if (!resultsMap.containsKey(pkVal)) {
              if (returnResultDetails) {
                failedKeys.add(pkVal);
              }
              failedCount++;
            }
          }
          return finishWithPromoteMirror(DbResult.error(
            type: ResultType.bizRecordNotFound,
            message: 'Some records not found during batchUpdate',
            failedKeys: returnResultDetails ? failedKeys : const [],
          ));
        }

        // 6. Optimization: Create batch context to hoist table/buffer lookups
        final batchContext =
            writeBufferManager.createBatchReserveContext(table, txId);

        // 7. Pipeline Stage 1: Batch Merge and Validate
        final List<Map<String, dynamic>> candidateMergedRecords = [];
        final List<String> candidatePkVals = [];
        final List<Map<String, dynamic>> candidateOldRecords = [];
        final Map<String, Set<String>> candidateChangedFieldsMap = {};
        final preparedRecords = await _prepareBatchUpdateRecords(
          schema,
          table,
          subBatch,
          existingRecords,
        );

        for (int recordIndex = 0;
            recordIndex < subBatch.length;
            recordIndex++) {
          final record = subBatch[recordIndex];
          final pkVal = record[primaryKey]?.toString();
          if (pkVal == null) continue;

          final existingRecord = existingRecords[recordIndex];

          if (existingRecord == null) {
            if (allowPartialErrors) {
              if (returnResultDetails) {
                failedKeys.add(pkVal);
              }
            }
            failedCount++;
            continue;
          }

          final y16 = executionYield.maybeYield();
          if (y16 != null) await y16;
          final preparedRecord = preparedRecords[recordIndex];
          if (preparedRecord.missingExistingRecord) {
            if (allowPartialErrors) {
              if (returnResultDetails) {
                failedKeys.add(pkVal);
              }
            }
            failedCount++;
            continue;
          }

          if (preparedRecord.validationFailed) {
            if (returnResultDetails) {
              failedKeys.add(pkVal);
              if (preparedRecord.validationStatusesJson != null) {
                for (final sJson in preparedRecord.validationStatusesJson!) {
                  batchStatuses
                      .add(ResultStatus.fromJson(sJson, indexOverride: i));
                }
              } else {
                batchStatuses.add(GeneralStatus(
                  type: ResultType.bizValidationFailed,
                  message: 'Data validation failed for record $pkVal',
                  index: i,
                ));
              }
            }
            failedCount++;
            if (!allowPartialErrors) {
              return finishWithPromoteMirror(DbResult.error(
                type: ResultType.bizValidationFailed,
                message: 'Data validation failed for record $pkVal',
                failedKeys: returnResultDetails ? failedKeys : const [],
                statuses: returnResultDetails ? batchStatuses : const [],
              ));
            }
            continue;
          }

          if (preparedRecord.fieldConstraintErrors.isNotEmpty) {
            if (returnResultDetails) {
              failedKeys.add(pkVal);
              if (preparedRecord.validationStatusesJson != null) {
                for (final sJson in preparedRecord.validationStatusesJson!) {
                  batchStatuses
                      .add(ResultStatus.fromJson(sJson, indexOverride: i));
                }
              } else {
                for (final error in preparedRecord.fieldConstraintErrors) {
                  batchStatuses.add(GeneralStatus(
                    type: ResultType.bizValidationFailed,
                    message: error,
                    index: i,
                  ));
                }
              }
            }
            failedCount++;
            if (!allowPartialErrors) {
              return finishWithPromoteMirror(DbResult.error(
                type: ResultType.bizValidationFailed,
                message: preparedRecord.fieldConstraintErrors.join("; "),
                failedKeys: returnResultDetails ? failedKeys : const [],
                statuses: returnResultDetails ? batchStatuses : const [],
              ));
            }
            continue;
          }

          final updatedRecord = preparedRecord.updatedRecord;
          final changedFields = preparedRecord.changedFields;
          if (updatedRecord == null) continue;
          if (changedFields.isEmpty) {
            if (returnResultDetails) {
              successKeys.add(
                promoteKeyDesc != null
                    ? _promoteUserFacingSuccessKey(
                        updatedRecord,
                        promoteKeyDesc,
                        alternateRecord: existingRecord,
                      )
                    : pkVal,
              );
            }
            successCount++;
            continue;
          }

          candidateMergedRecords.add(updatedRecord);
          candidatePkVals.add(pkVal);
          candidateOldRecords.add(existingRecord);
          candidateChangedFieldsMap[pkVal] = changedFields.toSet();
        }

        if (candidateMergedRecords.isEmpty) continue;

        // 8. Pipeline Stage 2: Batch Reserve (Buffer Lock)
        // We lock the buffer FIRST to ensure atomic isolation during the subsequent slow disk check.
        final List<Map<String, dynamic>> readyForDiskCheck = [];
        final List<String> readyPkVals = [];
        final List<Map<String, dynamic>> readyOldRecords = [];
        final Map<String, Set<String>> readyChangedFieldsMap = {};
        final Set<String> reservedPkSet = {};
        // Hoist once per sub-batch: unique field names that can trigger reserve.
        final Set<String> uniqueFieldNames = <String>{
          for (final idx in allUniqueIndexes) ...idx.fields,
        };

        for (int j = 0; j < candidateMergedRecords.length; j++) {
          final pkVal = candidatePkVals[j];
          final updatedRecord = candidateMergedRecords[j];
          final changedFields = candidateChangedFieldsMap[pkVal]!;
          final needsReserve = uniqueFieldNames.isNotEmpty &&
              changedFields.any(uniqueFieldNames.contains);

          if (needsReserve) {
            try {
              batchContext.tryReserve(
                pkVal,
                updatedRecord,
                isUpdate: true,
                changedFields: changedFields,
                schema: schema,
              );
              reservedPkSet.add(pkVal);
              outstandingReservedPks.add(pkVal);
            } catch (e) {
              if (returnResultDetails) {
                failedKeys.add(pkVal);
              }
              failedCount++;
              final originalIndex =
                  records.indexWhere((r) => r[primaryKey]?.toString() == pkVal);
              final globalIndex = originalIndex != -1 ? originalIndex : 0;
              final violationType = e is UniqueViolation
                  ? e.constraintResultType
                  : ResultType.bizUniqueViolation;
              final violationMessage = e is UniqueViolation
                  ? e.message
                  : 'Unique reservation failed for $pkVal: $e';
              if (returnResultDetails) {
                batchStatuses.add(ConstraintStatus(
                  type: violationType,
                  message: violationMessage,
                  tableName: tableName,
                  index: globalIndex,
                  primaryKey: pkVal,
                  constraintName:
                      e is UniqueViolation ? e.indexName?.value : null,
                  fields: e is UniqueViolation ? e.fields : const [],
                  conflictingKeys: e is UniqueViolation ? [e.value] : const [],
                ));
              }
              if (!allowPartialErrors) {
                // Rollback all reservations in this sub-batch before returning
                await writeBufferManager.releaseReservedUniquesForPks(
                  table: table,
                  recordIds: reservedPkSet,
                  transactionId: txId,
                );
                outstandingReservedPks.removeAll(reservedPkSet);
                return finishWithPromoteMirror(DbResult.error(
                  type: violationType,
                  message: violationMessage,
                  failedKeys: returnResultDetails ? failedKeys : const [],
                  statuses: returnResultDetails ? batchStatuses : const [],
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
          table,
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
        final List<String> commitPkVals = [];

        for (int j = 0; j < readyForDiskCheck.length; j++) {
          final pkVal = readyPkVals[j];
          final violation = violations[j];

          if (violation != null) {
            if (returnResultDetails) {
              failedKeys.add(pkVal);
            }
            failedCount++;
            final originalIndex =
                records.indexWhere((r) => r[primaryKey]?.toString() == pkVal);
            final globalIndex = originalIndex != -1 ? originalIndex : 0;
            if (returnResultDetails) {
              batchStatuses.add(ConstraintStatus(
                type: violation.constraintResultType,
                message: violation.message,
                tableName: tableName,
                fields: violation.fields,
                conflictingKeys: [violation.value],
                index: globalIndex,
                primaryKey: pkVal,
                constraintName: violation.indexName?.value,
              ));
            }
            // Rollback reservation for this specific record on disk conflict
            if (reservedPkSet.contains(pkVal)) {
              writeBufferManager.releaseReservedUniques(
                table: table,
                recordId: pkVal,
                transactionId: txId,
              );
              outstandingReservedPks.remove(pkVal);
            }

            if (!allowPartialErrors) {
              // Rollback all other reservations in this sub-batch
              await writeBufferManager.releaseReservedUniquesForPks(
                table: table,
                recordIds: reservedPkSet,
                transactionId: txId,
              );
              outstandingReservedPks.removeAll(reservedPkSet);
              return finishWithPromoteMirror(DbResult.error(
                type: violation.constraintResultType,
                message: violation.message,
                failedKeys: returnResultDetails ? failedKeys : const [],
                statuses: returnResultDetails ? batchStatuses : const [],
              ));
            }
            continue;
          }

          final updatedRecord = readyForDiskCheck[j];
          final existingRecord = readyOldRecords[j];

          // 10.1: Foreign Key Checks
          if (_foreignKeyManager != null) {
            try {
              await _foreignKeyManager!.validateForeignKeyConstraints(
                table: table,
                data: updatedRecord,
                operation: ForeignKeyOperation.update,
              );
            } catch (e) {
              if (returnResultDetails) {
                failedKeys.add(pkVal);
              }
              failedCount++;
              final originalIndex =
                  records.indexWhere((r) => r[primaryKey]?.toString() == pkVal);
              final globalIndex = originalIndex != -1 ? originalIndex : 0;
              if (returnResultDetails) {
                if (e is DbException) {
                  for (final s in e.statuses) {
                    batchStatuses.add(ResultStatus.fromJson(s.toJson(),
                        indexOverride: globalIndex));
                  }
                } else {
                  batchStatuses.add(GeneralStatus(
                    type: ResultType.bizForeignKeyViolation,
                    message: e.toString(),
                    index: globalIndex,
                  ));
                }
              }
              if (reservedPkSet.contains(pkVal)) {
                writeBufferManager.releaseReservedUniques(
                  table: table,
                  recordId: pkVal,
                  transactionId: txId,
                );
                outstandingReservedPks.remove(pkVal);
              }
              if (!allowPartialErrors) {
                // Rollback all reservations
                await writeBufferManager.releaseReservedUniquesForPks(
                  table: table,
                  recordIds: reservedPkSet,
                  transactionId: txId,
                );
                outstandingReservedPks.removeAll(reservedPkSet);
                return finishWithPromoteMirror(DbResult.error(
                  type: ResultType.bizForeignKeyViolation,
                  message: e.toString(),
                  failedKeys: returnResultDetails ? failedKeys : const [],
                  statuses: returnResultDetails ? batchStatuses : const [],
                ));
              }
              continue;
            }
          }

          recordsToCommit.add(updatedRecord);
          oldRecordsToCommit.add(existingRecord);
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
            table: table,
            records: recordsToCommit,
            operation: BufferOperationType.update,
            schema: schema,
            oldRecordsMap: oldRecordsMap,
            transactionId: txId,
            schemaVersion: schema.schemaVersion ?? '',
          );

          if (returnResultDetails) {
            if (promoteKeyDesc != null) {
              final successSet = commitResult.successRecordIds.toSet();
              for (final rec in recordsToCommit) {
                final pkVal = rec[primaryKey]?.toString();
                if (pkVal == null || !successSet.contains(pkVal)) continue;
                successKeys
                    .add(_promoteUserFacingSuccessKey(rec, promoteKeyDesc));
              }
            } else {
              successKeys.addAll(commitResult.successRecordIds);
            }
          }
          successCount += commitResult.successRecordIds.length;
          outstandingReservedPks.removeAll(commitResult.successRecordIds);

          if (commitResult.failedRecordIds.isNotEmpty) {
            for (final fId in commitResult.failedRecordIds) {
              if (returnResultDetails) {
                failedKeys.add(fId);
              }
              failedCount++;
              if (reservedPkSet.contains(fId)) {
                writeBufferManager.releaseReservedUniques(
                  table: table,
                  recordId: fId,
                  transactionId: txId,
                );
                outstandingReservedPks.remove(fId);
              }
            }
          }

          if (commitResult.successRecordIds.isNotEmpty &&
              (promoteWritten != null || hasNotify)) {
            final successSet = commitResult.successRecordIds.toSet();
            for (int k = 0; k < recordsToCommit.length; k++) {
              if (successSet.contains(commitPkVals[k])) {
                promoteWritten?.add(recordsToCommit[k]);
                if (hasNotify) {
                  notificationManager.notify(ChangeEvent(
                    type: ChangeType.update,
                    tableUid: schema.tableUid,
                    record: recordsToCommit[k],
                    oldRecord: oldRecordsToCommit[k],
                  ));
                }
              }
            }
          }
        }
      }

      // Fill success statuses (match on user-facing keys when promote active)
      if (returnResultDetails) {
        final successSet = successKeys.toSet();
        for (int i = 0; i < records.length; i++) {
          final oldPk = records[i][primaryKey]?.toString() ?? '';
          if (oldPk.isEmpty) continue;
          final displayPk = promoteKeyDesc != null
              ? _promoteUserFacingSuccessKey(records[i], promoteKeyDesc)
              : oldPk;
          if (successSet.contains(displayPk)) {
            batchStatuses.add(SuccessStatus(
              message: 'Record updated successfully',
              index: i,
              primaryKey: displayPk,
            ));
          }
        }
      }

      if (successCount > 0 && failedCount > 0) {
        return finishWithPromoteMirror(DbResult(
          statuses: returnResultDetails ? batchStatuses : const [],
          successKeys: returnResultDetails ? successKeys : const [],
          failedKeys: returnResultDetails ? failedKeys : const [],
          successCount: successCount,
          failedCount: failedCount,
        ));
      } else if (successCount > 0) {
        return finishWithPromoteMirror(DbResult(
          statuses: returnResultDetails ? batchStatuses : const [],
          successKeys: returnResultDetails ? successKeys : const [],
          failedKeys: const [],
          successCount: successCount,
          failedCount: 0,
        ));
      } else {
        return finishWithPromoteMirror(DbResult.error(
          type: ResultType.bizRecordNotFound,
          message: 'No records were updated',
          failedKeys: returnResultDetails ? failedKeys : const [],
          statuses: returnResultDetails ? batchStatuses : const [],
        ));
      }
    } catch (e) {
      Logger.error('Batch update failed', rawError: e);
      if (isInTransactionWithRollback()) {
        rethrow;
      }
      final dbEx = DbException.wrap(e,
          fallbackType: ResultType.engError,
          fallbackMessage: 'Batch update failed');
      return finish(DbResult.batch(
        statuses: returnResultDetails
            ? [...batchStatuses, ...dbEx.statuses]
            : const [],
        failedCount: dbEx.statuses.length,
      ));
    } finally {
      // Covers early returns (!allowPartialErrors) that never hit catch:
      // only still-outstanding (not yet buffered/committed) pks are released;
      // commitReservedUniques already cleared bookkeeping for successes -> no-op.
      if (outstandingReservedPks.isNotEmpty) {
        try {
          await writeBufferManager.releaseReservedUniquesForPks(
            table: table,
            recordIds: outstandingReservedPks,
            transactionId: txId,
          );
        } catch (_) {}
        outstandingReservedPks.clear();
      }
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

    // Fire-and-forget, but keep a handle so close/switchSpace can await stop.
    final task = _executePrewarm();
    _prewarmFuture = task;
    unawaited(task.whenComplete(() {
      if (identical(_prewarmFuture, task)) {
        _prewarmFuture = null;
      }
    }));
  }

  /// Cancel-aware wait for the in-flight prewarm task.
  ///
  /// Caller must already have set [shouldAbortBackgroundScan] (via `_closing`
  /// / cancel token) so leaf scans exit cooperatively.
  Future<void> _stopAndAwaitPrewarm({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final future = _prewarmFuture;
    if (future == null) {
      _isGlobalPrewarming = false;
      return;
    }
    try {
      await future.timeout(timeout);
    } on TimeoutException {
      Logger.warn(
        'Cache prewarm did not stop within ${timeout.inMilliseconds}ms '
        'during close/switchSpace; continuing shutdown',
      );
    } catch (e) {
      // Errors inside prewarm are logged there; ignore here.
      if (_isInitialized) {
        Logger.warn('Await prewarm stop failed', rawError: e);
      }
    } finally {
      // If the task timed out, force the flag so later init can start fresh.
      // The orphaned future's finally will also clear _isGlobalPrewarming.
      _isGlobalPrewarming = false;
      if (identical(_prewarmFuture, future)) {
        _prewarmFuture = null;
      }
    }
  }

  Future<void> _executePrewarm() async {
    try {
      final schemaMgr = tableMetaManager;
      if (schemaMgr == null) return;

      // From tableMetaManager get all schemas (empty tables skip data load below).
      final allTables = await getTableNames();
      if (allTables.isEmpty || shouldAbortBackgroundScan) return;

      // Sort tables by weight
      final prioritizedTables = await _prioritizeTablesByWeight(allTables);
      if (shouldAbortBackgroundScan) return;

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
        if (shouldAbortBackgroundScan) break;
        try {
          if (shouldAbortBackgroundScan) {
            continue;
          }

          final table = await getTableContext(tableName);
          final tableDataMeta =
              await tableDataManager.getTableDataMeta(table.tableUid);
          if (tableDataMeta != null && !tableDataMeta.btreeFirstLeaf.isNull) {
            await tableTreePartitionManager?.prewarmBoundaryPages(
              table,
              meta: tableDataMeta,
            );
          }

          final schema =
              await schemaMgr.getTableSchemaByName(TableName(tableName));
          if (schema != null) {
            final indexes = schemaMgr
                .getBtreeIndexesFor(schema)
                .where((index) => index.type == IndexType.btree);
            for (final index in indexes) {
              if (shouldAbortBackgroundScan) break;
              final indexMeta = await _indexManager?.getIndexMeta(
                  table.tableUid, index.indexUid);
              if (indexMeta == null || indexMeta.btreeFirstLeaf.isNull) {
                continue;
              }
              await indexTreePartitionManager?.prewarmBoundaryPages(
                table,
                index.indexUid,
                meta: indexMeta,
              );
              final y17 = yieldController.maybeYield();
              if (y17 != null) await y17;
            }
          }

          // Yield control to the event loop to prevent UI freezing during a long prewarm process.
          final y18 = yieldController.maybeYield();
          if (y18 != null) await y18;
        } catch (e) {
          // If already closing/closed, suppress errors from missing managers
          if (shouldAbortBackgroundScan) break;

          Logger.error('Load table data failed: $tableName', rawError: e);
          continue; // Continue load other tables
        }
      }

      if (shouldAbortBackgroundScan) return;

      final effectivePrewarmThresholdMB =
          await _resourceManager!.initializeEffectivePrewarmThresholdMB();
      final effectivePrewarmBudgetBytes =
          effectivePrewarmThresholdMB * 1024 * 1024;

      var remainingPrewarmBytes = effectivePrewarmBudgetBytes;
      remainingPrewarmBytes = await _prewarmKvStore(
        maxPrewarmBytes: remainingPrewarmBytes,
      );

      if (shouldAbortBackgroundScan) return;

      await _prewarmUserTables(
        prioritizedTables: prioritizedTables,
        prewarmBudgetBytes: remainingPrewarmBytes,
      );
    } catch (e) {
      if (_isInitialized) {
        Logger.error('Error in _executePrewarm', rawError: e);
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
      if (shouldAbortBackgroundScan) {
        return maxPrewarmBytes - currentPrewarmedBytes;
      }
      try {
        final table = await getTableContext(tableName);
        final tableDataMeta =
            await tableDataManager.getTableDataMeta(table.tableUid);
        if (shouldAbortBackgroundScan) {
          return maxPrewarmBytes - currentPrewarmedBytes;
        }
        if (tableDataMeta == null || tableDataMeta.totalRecordCount <= 0) {
          continue;
        }

        final indexBytes = await _estimateTableIndexBytes(table);
        final estimatedBytes = tableDataMeta.totalSizeBytes + indexBytes;
        if (currentPrewarmedBytes + estimatedBytes > maxPrewarmBytes) {
          continue;
        }

        await queryExecutor.execute(
          table,
          condition: QueryCondition()
            ..where(SystemTable.keyValueKeyField, '>=', ''),
          limit: maxRecordsSafetyCap,
        );
        currentPrewarmedBytes += estimatedBytes;
        final y19 = yieldController.maybeYield();
        if (y19 != null) await y19;
      } catch (e) {
        if (shouldAbortBackgroundScan) {
          return maxPrewarmBytes - currentPrewarmedBytes;
        }
        Logger.warn('Prewarm KV store failed for $tableName', rawError: e);
      }
    }

    return maxPrewarmBytes - currentPrewarmedBytes;
  }

  /// Prewarm user tables when the current space remains small enough.
  Future<void> _prewarmUserTables({
    List<String>? prioritizedTables,
    required int prewarmBudgetBytes,
  }) async {
    final schemaMgr = tableMetaManager;
    if (schemaMgr == null || shouldAbortBackgroundScan) return;

    final spaceStats = await getSpaceStats();
    final spaceUsageBytes = spaceStats.totalSizeBytes;
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
      if (shouldAbortBackgroundScan) break;
      try {
        if (shouldAbortBackgroundScan) continue;

        final table = await getTableContext(tableName);
        final tableDataMeta =
            await tableDataManager.getTableDataMeta(table.tableUid);
        if (tableDataMeta == null || tableDataMeta.totalRecordCount <= 0) {
          continue;
        }

        final schema = table.schema;

        final indexBytes = await _estimateTableIndexBytes(table);
        final estimatedBytes = tableDataMeta.totalSizeBytes + indexBytes;

        if (currentPrewarmedBytes + estimatedBytes > prewarmBudgetBytes ||
            tableDataMeta.totalRecordCount > maxRecordsSafetyCap) {
          break;
        }

        await queryExecutor.execute(
          table,
          condition: QueryCondition()..where(schema.primaryKey, '>=', ''),
          limit: maxRecordsSafetyCap,
        );
        final y20 = yieldController.maybeYield();
        if (y20 != null) await y20;

        final indexes = schemaMgr.getBtreeIndexesFor(schema);
        for (final index in indexes) {
          if (shouldAbortBackgroundScan) break;
          final indexMeta =
              await _indexManager?.getIndexMeta(table.tableUid, index.indexUid);
          if (indexMeta == null || indexMeta.btreeFirstLeaf.isNull) continue;

          // Warm the full index by traversing its leaf chain directly.
          await indexTreePartitionManager?.searchByKeyRange(
            table: table,
            indexUid: index.indexUid,
            meta: indexMeta,
            startKeyInclusive: Uint8List(0),
            endKeyExclusive: Uint8List(0),
            limit: maxRecordsSafetyCap,
          );
          final y21 = yieldController.maybeYield();
          if (y21 != null) await y21;
        }

        currentPrewarmedBytes += estimatedBytes;
        final y22 = yieldController.maybeYield();
        if (y22 != null) await y22;
      } catch (e) {
        if (shouldAbortBackgroundScan) break;
        Logger.warn('Prewarm user table failed for $tableName', rawError: e);
      }
    }
  }

  Future<int> _estimateTableIndexBytes(TableContext table) async {
    final schemaMgr = tableMetaManager;
    if (schemaMgr == null) return 0;
    final schema = table.schema;

    var total = 0;
    final yieldController = YieldController(
        'DataStoreImpl._estimateTableIndexBytes',
        checkInterval: 2);
    final indexes = schemaMgr
        .getBtreeIndexesFor(schema)
        .where((index) => index.type == IndexType.btree);
    for (final index in indexes) {
      final indexMeta =
          await _indexManager?.getIndexMeta(table.tableUid, index.indexUid);
      if (indexMeta != null) {
        total += indexMeta.totalSizeBytes;
      }
      final y23 = yieldController.maybeYield();
      if (y23 != null) await y23;
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
          'Failed to prioritize tables by weight, falling back to default priority',
          rawError: e);
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
      final y24 = yieldController.maybeYield();
      if (y24 != null) await y24;
      // Check if it's a global table
      final uid = await tableMetaManager?.getUidByName(TableName(tableName));
      final isGlobal = uid != null
          ? await tableMetaManager?.isTableGlobal(uid) ?? false
          : false;
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
  Future<Map<String, dynamic>?> queryById(
      TableContext table, dynamic id) async {
    try {
      final schema = table.schema;
      if (schema.name.isEmpty) {
        Logger.error('Table ${table.tableName} does not exist');
        return null;
      }
      final condition = QueryCondition()..where(schema.primaryKey, '=', id);

      final results = (await queryExecutor.execute(
        table,
        condition: condition,
        limit: 1,
      ))
          .records;
      return results.isEmpty ? null : results.first;
    } catch (e) {
      Logger.error('Query by id failed', rawError: e);
      rethrow;
    }
  }

  /// query by field
  Future<List<Map<String, dynamic>>> queryBy(
    TableContext table,
    String field,
    dynamic value,
  ) async {
    try {
      final schema = table.schema;
      if (schema.name.isEmpty) {
        Logger.error('Table ${table.tableName} does not exist');
        return [];
      }
      final condition = QueryCondition()..where(field, '=', value);

      return (await queryExecutor.execute(
        table,
        condition: condition,
      ))
          .records;
    } catch (e) {
      Logger.error('Query by field failed', rawError: e);
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
    final table = await getTableContext(tableName);
    return _vectorIndexManager!.vectorSearch(
      table: table,
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

    final oldSpaceName = _currentSpaceName;
    try {
      // Pause key migration on the primary before tearing down space files.
      // Helper (isMigrationInstance) close must not cancel this runner - that is
      // enforced inside KeyManager.pauseKeyMigration.
      final paused = await _keyManager?.pauseKeyMigration() ?? true;
      if (!paused) {
        Logger.warn(
          'Space switch aborted: encodingKey migration did not pause in time '
          '(oldSpace=[$oldSpaceName], target=[$spaceName]). '
          'Refusing to open another space while file handles may still be held.',
        );
        return false;
      }

      // 1. Unified shutdown logic for the current space via close().
      // closeStorage: true releases the handle pool / Web retain so late async
      // cannot reopen files belonging to the old space (Windows errno 32).
      // initialize() rebuilds a fresh StorageAdapter afterwards.
      await close(closeStorage: true, removeRegistry: false);

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
      );

      return true;
    } catch (e) {
      // Rollback on failure
      _currentSpaceName = oldSpaceName;
      if (_config != null) {
        _config = _config!.copyWith(spaceName: oldSpaceName);
      }
      Logger.error('Space switch failed', rawError: e);
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
      Logger.error('Failed to save cache before exit', rawError: e);
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
      Logger.error('Delete database failed', rawError: e);
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
    final tableName = SystemTable.getKeyValueName(isGlobal);
    DbResult finish(DbResult r) =>
        _returnOrThrowIfTxn(r, 'setValue', tableName);
    await ensureInitialized();

    if (ttl != null && expiresAt != null) {
      return finish(DbResult.error(
        type: ResultType.devInvalidArgumentFormat,
        message: 'ttl and expiresAt are mutually exclusive',
        failedKeys: [key],
        statuses: [
          InvalidArgumentStatus(
            type: ResultType.devInvalidArgumentFormat,
            message: 'ttl and expiresAt are mutually exclusive',
            parameterName: 'ttl',
            passedValue: ttl,
          )
        ],
      ));
    }

    if (ttl != null && ttl <= Duration.zero) {
      return finish(DbResult.error(
        type: ResultType.devInvalidArgumentFormat,
        message: 'ttl must be greater than zero',
        failedKeys: [key],
        statuses: [
          InvalidArgumentStatus(
            type: ResultType.devInvalidArgumentFormat,
            message: 'ttl must be greater than zero',
            parameterName: 'ttl',
            passedValue: ttl,
          )
        ],
      ));
    }

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

    final schema =
        await tableMetaManager?.getTableSchemaByName(TableName(tableName));
    if (schema == null) {
      return finish(DbResult.error(
        type: ResultType.devTableNotFound,
        message: 'KV table not found',
        failedKeys: [key],
      ));
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
    final tableName = SystemTable.getKeyValueName(isGlobal);
    DbResult finish(DbResult r) =>
        _returnOrThrowIfTxn(r, 'setValueMany', tableName);
    await ensureInitialized();
    if (items.isEmpty) {
      return finish(DbResult.success(message: 'No items to set'));
    }

    if (ttl != null && expiresAt != null) {
      return finish(DbResult.error(
        type: ResultType.devInvalidArgumentFormat,
        message: 'ttl and expiresAt are mutually exclusive',
        statuses: [
          InvalidArgumentStatus(
            type: ResultType.devInvalidArgumentFormat,
            message: 'ttl and expiresAt are mutually exclusive',
            parameterName: 'ttl',
            passedValue: ttl,
          )
        ],
      ));
    }

    if (ttl != null && ttl <= Duration.zero) {
      return finish(DbResult.error(
        type: ResultType.devInvalidArgumentFormat,
        message: 'ttl must be greater than zero',
        statuses: [
          InvalidArgumentStatus(
            type: ResultType.devInvalidArgumentFormat,
            message: 'ttl must be greater than zero',
            parameterName: 'ttl',
            passedValue: ttl,
          )
        ],
      ));
    }

    final schema =
        await tableMetaManager?.getTableSchemaByName(TableName(tableName));
    if (schema == null) {
      return finish(DbResult.error(
        type: ResultType.devTableNotFound,
        message: 'KV table not found',
      ));
    }

    final now = DateTime.now();
    final nowIso = now.toIso8601String();
    final expiresAtIso = expiresAt?.toIso8601String() ??
        (ttl != null ? now.add(ttl).toIso8601String() : null);

    final records = await _prepareKeyValueBatchRecords(
      items,
      nowIso: nowIso,
      expiresAtIso: expiresAtIso,
    );
    return await batchUpsert(tableName, records,
        allowPartialErrors: allowPartialErrors);
  }

  /// Get key-value pair
  Future<dynamic> getValue(String key, {bool isGlobal = false}) async {
    await ensureInitialized();

    final tableName = SystemTable.getKeyValueName(isGlobal);
    final table = await getTableContext(tableName);
    final result = (await queryExecutor.execute(
      table,
      condition: QueryCondition()..where(_kvKeyField, '=', key),
      limit: 1,
    ))
        .records;
    if (result.isEmpty) {
      return null;
    }

    final row = result.first;
    if (_isKvRowExpired(row)) {
      _scheduleExactExpiredKvCleanup(table, key, row[_kvExpiresAtField]);
      return null;
    }

    return _decodeStoredKeyValue(row[_kvValueField], key: key);
  }

  /// Get all keys in the specified space, optionally filtered by prefix.
  Future<List<String>> getKeys({String? prefix, bool isGlobal = false}) async {
    await ensureInitialized();
    final tableName = SystemTable.getKeyValueName(isGlobal);
    final table = await getTableContext(tableName);
    final condition = QueryCondition();
    if (prefix != null && prefix.isNotEmpty) {
      condition.whereStartsWith(_kvKeyField, prefix);
    }

    final rows = (await queryExecutor.execute(
      table,
      condition: condition,
    ))
        .records;
    final now = DateTime.now();
    final keys = <String>[];

    for (final row in rows) {
      if (!_isKvRowExpired(row, now: now)) {
        keys.add(row[_kvKeyField].toString());
      } else {
        _scheduleExactExpiredKvCleanup(
            table, row[_kvKeyField].toString(), row[_kvExpiresAtField]);
      }
    }
    return keys;
  }

  /// Check if a key exists and is not expired.
  Future<bool> exists(String key, {bool isGlobal = false}) async {
    await ensureInitialized();
    final tableName = SystemTable.getKeyValueName(isGlobal);
    final table = await getTableContext(tableName);
    final result = (await queryExecutor.execute(
      table,
      condition: QueryCondition()..where(_kvKeyField, '=', key),
      limit: 1,
    ))
        .records;
    if (result.isEmpty) return false;

    final row = result.first;
    if (_isKvRowExpired(row)) {
      _scheduleExactExpiredKvCleanup(table, key, row[_kvExpiresAtField]);
      return false;
    }
    return true;
  }

  /// Remove key-value pair
  Future<DbResult> removeValue(String key, {bool isGlobal = false}) async {
    await ensureInitialized();

    final tableName = SystemTable.getKeyValueName(isGlobal);
    final table = await getTableContext(tableName);
    // Build delete condition
    final condition = QueryCondition()..where(_kvKeyField, '=', key);
    return await deleteInternal(table, condition);
  }

  /// Remove multiple key-value pairs.
  Future<DbResult> removeValues(Iterable<String> keys,
      {bool isGlobal = false}) async {
    await ensureInitialized();
    final keyList = keys.toList();
    if (keyList.isEmpty) return DbResult.success();

    final tableName = SystemTable.getKeyValueName(isGlobal);
    final table = await getTableContext(tableName);
    final condition = QueryCondition()..whereIn(_kvKeyField, keyList);
    return await deleteInternal(table, condition);
  }

  /// Get remaining TTL for a key.
  Future<Duration?> getTtl(String key, {bool isGlobal = false}) async {
    await ensureInitialized();
    final tableName = SystemTable.getKeyValueName(isGlobal);
    final table = await getTableContext(tableName);
    final result = (await queryExecutor.execute(
      table,
      condition: QueryCondition()..where(_kvKeyField, '=', key),
      limit: 1,
    ))
        .records;
    if (result.isEmpty) return null;

    final row = result.first;
    final expiresAt = _parseKvDateTime(row[_kvExpiresAtField]);
    if (expiresAt == null) return null;

    final now = DateTime.now();
    if (expiresAt.isBefore(now)) {
      _scheduleExactExpiredKvCleanup(table, key, row[_kvExpiresAtField]);
      return null;
    }
    return expiresAt.difference(now);
  }

  /// Set TTL for an existing key.
  Future<DbResult> setTtl(String key, Duration? ttl,
      {DateTime? expiresAt, bool isGlobal = false}) async {
    await ensureInitialized();
    final tableName = SystemTable.getKeyValueName(isGlobal);
    final table = await getTableContext(tableName);

    final now = DateTime.now();
    final expiresAtIso = expiresAt?.toIso8601String() ??
        (ttl != null ? now.add(ttl).toIso8601String() : null);

    final data = {
      _kvExpiresAtField: expiresAtIso,
      _kvUpdatedAtField: now.toIso8601String(),
    };

    final condition = QueryCondition()..where(_kvKeyField, '=', key);
    return await updateInternal(table, data, condition);
  }

  /// Atomic increment for a numeric value.
  Future<DbResult> setIncrement(String key,
      {int amount = 1, bool isGlobal = false}) async {
    await ensureInitialized();
    final tableName = SystemTable.getKeyValueName(isGlobal);
    final table = await getTableContext(tableName);

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
    return await updateInternal(table, data, condition);
  }

  /// Watch a single key-value pair and emit the latest value immediately.
  Stream<T?> watchValue<T>(String key,
      {bool isGlobal = false, T? defaultValue, bool distinct = true}) {
    final tableName = SystemTable.getKeyValueName(isGlobal);
    return Stream.fromFuture(getTableContext(tableName)).asyncExpand((table) {
      final condition = QueryCondition()..where(_kvKeyField, '=', key);
      return _watchKvQuery<T?>(
        table: table,
        condition: condition,
        distinct: distinct,
        loadSnapshot: () async {
          final rows = (await queryExecutor.execute(
            table,
            condition: condition,
          ))
              .records;
          if (rows.isEmpty) {
            return (
              value: defaultValue,
              fingerprint: Object.hash(key, false, null),
              nextRefreshAt: null,
            );
          }

          final row = rows.first;
          final rawExpiresAt = row[_kvExpiresAtField];
          final expiresAt = _parseKvDateTime(rawExpiresAt);
          if (expiresAt != null && !expiresAt.isAfter(DateTime.now())) {
            _scheduleExactExpiredKvCleanup(table, key, rawExpiresAt);
            return (
              value: defaultValue,
              fingerprint: Object.hash(key, false, null),
              nextRefreshAt: null,
            );
          }

          final rawValue = row[_kvValueField];
          return (
            value: _decodeStoredKeyValue(rawValue, key: key) as T?,
            fingerprint: Object.hash(key, true, rawValue),
            nextRefreshAt: expiresAt,
          );
        },
      );
    });
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
    return Stream.fromFuture(getTableContext(tableName)).asyncExpand((table) {
      final condition = QueryCondition();
      if (requestedKeys.length == 1) {
        condition.where(_kvKeyField, '=', requestedKeys.first);
      } else {
        condition.where(_kvKeyField, 'IN', requestedKeys);
      }

      return _watchKvQuery<Map<String, dynamic>>(
        table: table,
        condition: condition,
        distinct: distinct,
        loadSnapshot: () async {
          final rows = (await queryExecutor.execute(
            table,
            condition: condition,
          ))
              .records;
          final rowsByKey = <String, Map<String, dynamic>>{};
          for (final row in rows) {
            final rowKey = row[_kvKeyField];
            if (rowKey != null) {
              rowsByKey[rowKey.toString()] = row;
            }
          }

          final values = <String, dynamic>{};
          final fingerprintHashes = <int>[];
          DateTime? nextRefreshAt;
          final now = DateTime.now();
          for (final requestedKey in requestedKeys) {
            final row = rowsByKey[requestedKey];
            if (row == null) {
              values[requestedKey] = null;
              fingerprintHashes.add(Object.hash(requestedKey, false, null));
              continue;
            }

            final rawExpiresAt = row[_kvExpiresAtField];
            final expiresAt = _parseKvDateTime(rawExpiresAt);
            if (expiresAt != null && !expiresAt.isAfter(now)) {
              values[requestedKey] = null;
              fingerprintHashes.add(Object.hash(requestedKey, false, null));
              _scheduleExactExpiredKvCleanup(table, requestedKey, rawExpiresAt);
              continue;
            }

            if (expiresAt != null &&
                (nextRefreshAt == null || expiresAt.isBefore(nextRefreshAt))) {
              nextRefreshAt = expiresAt;
            }

            final rawValue = row[_kvValueField];
            values[requestedKey] =
                _decodeStoredKeyValue(rawValue, key: requestedKey);
            fingerprintHashes.add(Object.hash(requestedKey, true, rawValue));
          }

          return (
            value: Map<String, dynamic>.unmodifiable(values),
            fingerprint: Object.hashAll(fingerprintHashes),
            nextRefreshAt: nextRefreshAt,
          );
        },
      );
    });
  }

  Stream<T> _watchKvQuery<T>({
    required TableContext table,
    required QueryCondition condition,
    required Future<({T value, Object fingerprint, DateTime? nextRefreshAt})>
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
    Object? lastFingerprint;
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
          table.tableUid,
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
    TableContext table,
    String key,
    dynamic rawExpiresAt,
  ) {
    final expiresAtIso = _parseKvDateTime(rawExpiresAt)?.toIso8601String();
    if (expiresAtIso == null) {
      return;
    }
    unawaited(_deleteExpiredKvRecordExact(
      table,
      key: key,
      expiresAtIso: expiresAtIso,
    ));
  }

  Future<void> _deleteExpiredKvRecordExact(
    TableContext table, {
    required String key,
    required String expiresAtIso,
  }) async {
    try {
      final condition = QueryCondition()
        ..where(_kvKeyField, '=', key)
        ..where(_kvExpiresAtField, '=', expiresAtIso);
      await deleteInternal(table, condition, limit: 1);
    } catch (e) {
      if (e is DbClosedException) return;
      Logger.warn(
          'Failed to cleanup expired kv key "$key" in ${table.tableName}',
          rawError: e);
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
          'Failed to parse value for key "$key" as JSON. Returning raw value. This may indicate that the value was not set using `setValue`.',
          rawError: e);
      return rawValue;
    }
  }

  /// get table schema by name (user-facing entry point)
  Future<TableSchema?> getTableSchema(String tableName) async {
    final schema =
        await tableMetaManager?.getTableSchemaByName(TableName(tableName));
    if (schema == null) return null;
    final target = migrationManager?.getPromoteTargetSchema(schema.tableUid);
    if (target == null) return schema;
    // Overlay target shape; keep the logical user-facing table name.
    if (target.name == schema.name) return target;
    return target.copyWith(name: schema.name);
  }

  /// Get table info
  /// get table info
  Future<TableInfo?> getTableInfo(String tableName) async {
    await ensureInitialized();
    final table = await getTableContext(tableName);
    // User-facing schema overlay during promote (engine TableContext stays old).
    final schema = await getTableSchema(tableName) ?? table.schema;

    DateTime? createdAt;

    final tableDataMeta =
        await tableDataManager.getTableDataMeta(table.tableUid);
    createdAt = tableDataMeta?.timestamps.created;
    if (createdAt == null) {
      final part0Path =
          await pathManager.getPartitionFilePathByNo(table.tableUid, 0);
      if (await storage.existsFile(part0Path)) {
        createdAt = await storage.getFileCreationTime(part0Path);
      }
    }
    final lastModified = tableDataMeta?.timestamps.modified;
    final tableDataSize = tableDataMeta?.totalSizeBytes ?? 0;
    final totalRecordCount = await tableDataManager.getTableRecordCount(table);
    final indexDataSize =
        await tableDataManager.sumTableIndexDataSizeBytes(table);
    return TableInfo(
      tableName: tableName,
      totalRecordCount: totalRecordCount,
      totalTableDataSizeBytes: tableDataSize,
      totalIndexDataSizeBytes: indexDataSize,
      indexCount: schema.indexes.length,
      schema: schema,
      isGlobal: schema.isGlobal,
      lastModified: lastModified,
      createdAt: createdAt,
    );
  }

  // ---------------------------------------------------------------------------
  // promoteFieldToPrimaryKey dual-write helpers (old table is source of truth)
  // ---------------------------------------------------------------------------

  PromoteRuntimeDescriptor? _promoteRuntimeForDualWrite(
    TableUid tableUid, {
    required bool enablePromoteDualWrite,
  }) {
    // Hard gate: engine/migration callers must pass false. Never rely on
    // "shadow uid not in map" alone - a single missed flag would recurse.
    if (!enablePromoteDualWrite) return null;
    return migrationManager?.getPromoteRuntime(tableUid);
  }

  /// Remap user-facing record keys to old working shape (in-place).
  void _promoteRemapRecordNewToOld(
    Map<String, dynamic> record,
    PromoteRuntimeDescriptor desc,
  ) {
    transformPromoteNewToOldInPlace(record, desc);
  }

  /// Upsert transformed old-table rows onto the promote shadow table.
  ///
  /// Does not own user-facing success keys - callers read the source-field
  /// value (O(1)) from the already-successful old-table record.
  ///
  /// Failure policy (old table write already succeeded):
  /// - [DbClosedException] / closing: silent return
  /// - business-only errors: warn, do not interrupt the caller
  /// - eng / sys / dev errors: throw [DbException]
  Future<void> _promoteMirrorUpsertToShadow(
    PromoteRuntimeDescriptor desc,
    List<Map<String, dynamic>> oldRecords,
  ) async {
    if (oldRecords.isEmpty) return;
    if (isClosing) return;
    final shadowName = promoteShadowTableName(desc.taskId);
    final payloads = <Map<String, dynamic>>[];
    final yieldController = YieldController(
      'DataStoreImpl.promoteMirrorUpsert',
      checkInterval: 128,
    );
    for (final old in oldRecords) {
      final y25 = yieldController.maybeYield();
      if (y25 != null) await y25;
      final row = Map<String, dynamic>.from(old);
      transformPromoteOldToNewInPlace(row, desc);
      payloads.add(row);
    }
    try {
      // allowPartialErrors: a single business conflict must not abort the
      // whole mirror batch; hard failures are classified below.
      final result = await batchUpsert(
        shadowName,
        payloads,
        allowPartialErrors: true,
        returnResultDetails: false,
        enablePromoteDualWrite: false,
      );
      _promoteThrowIfNonBusinessFailure(result);
    } on DbClosedException {
      // Shutdown: old write may already be durable; do not surface noise.
    } catch (e) {
      _promoteRethrowUnlessBusinessOrClosed(e);
    }
  }

  /// Flush collected successful old-working rows to the promote shadow, then
  /// clear [written] only after mirror completes without a hard failure.
  Future<void> _promoteFlushMirrorWritten(
    PromoteRuntimeDescriptor? desc,
    List<Map<String, dynamic>>? written,
  ) async {
    if (desc == null || written == null || written.isEmpty) return;
    final batch = List<Map<String, dynamic>>.from(written);
    await _promoteMirrorUpsertToShadow(desc, batch);
    written.clear();
  }

  /// User-facing success key from an old-working record (O(1) field read).
  ///
  /// After new->old remap the value lives under [PromoteRuntimeDescriptor.sourceFieldName].
  /// Never falls back to the old auto PK - that would leak the internal identity.
  String _promoteUserFacingSuccessKey(
    Map<String, dynamic> oldWorkingRecord,
    PromoteRuntimeDescriptor desc, {
    Map<String, dynamic>? alternateRecord,
  }) {
    return promoteUserFacingPkFromOldRecord(oldWorkingRecord, desc) ??
        (alternateRecord != null
            ? promoteUserFacingPkFromOldRecord(alternateRecord, desc)
            : null) ??
        '';
  }

  /// Delete matching rows from the promote shadow table by target PK.
  ///
  /// Same failure policy as [_promoteMirrorUpsertToShadow].
  Future<void> _promoteMirrorDeleteFromShadow(
    PromoteRuntimeDescriptor desc,
    List<Map<String, dynamic>> oldRecords,
  ) async {
    if (oldRecords.isEmpty) return;
    if (isClosing) return;
    final shadowCtx =
        await migrationManager?.getPromoteShadowTableContext(desc.tableUid);
    if (shadowCtx == null) {
      return;
    }

    final targetPk = desc.targetPkName;
    // Per-record collection: check roughly every 64 items.
    final collectYield = YieldController(
      'DataStoreImpl.promoteMirrorDelete.collect',
      checkInterval: 64,
    );
    final pkValues = <String>[];
    for (final old in oldRecords) {
      final y26 = collectYield.maybeYield();
      if (y26 != null) await y26;
      final v = old[desc.sourceFieldName] ?? old[targetPk];
      if (v != null) pkValues.add(v.toString());
    }
    if (pkValues.isEmpty) return;

    // Each iteration already sends 500 keys; check every chunk.
    final chunkYield = YieldController(
      'DataStoreImpl.promoteMirrorDelete.chunk',
      checkInterval: 1,
    );
    const chunkSize = 500;
    try {
      for (var i = 0; i < pkValues.length; i += chunkSize) {
        final y27 = chunkYield.maybeYield();
        if (y27 != null) await y27;
        final end = min(i + chunkSize, pkValues.length);
        final chunk = pkValues.sublist(i, end);
        final result = await deleteInternal(
          shadowCtx,
          QueryCondition().where(targetPk, 'IN', chunk),
          allowAll: false,
          returnResultDetails: false,
          enablePromoteDualWrite: false,
        );
        _promoteThrowIfNonBusinessFailure(result);
      }
    } on DbClosedException {
      // Shutdown: silent.
    } catch (e) {
      _promoteRethrowUnlessBusinessOrClosed(e);
    }
  }

  /// Clear shadow table data when the logical table is cleared mid-promote.
  Future<void> _promoteMirrorClearShadow(
    PromoteRuntimeDescriptor desc,
  ) async {
    if (isClosing) return;
    final shadowCtx =
        await migrationManager?.getPromoteShadowTableContext(desc.tableUid);
    if (shadowCtx == null) {
      return;
    }
    try {
      // Direct physical clear - never route through clear()/deleteInternal
      // user dual-write (would recurse onto the same shadow).
      await cacheManager.invalidateCache(shadowCtx, invalidateSchema: false);
      await tableDataManager.clearTable(shadowCtx);
      await _indexManager?.clearIndexesForTable(shadowCtx);
    } on DbClosedException {
      // Shutdown: silent.
    } catch (e) {
      _promoteRethrowUnlessBusinessOrClosed(e);
    }
  }

  /// Skip business-only failures; otherwise throw with the original statuses.
  ///
  /// [returnResultDetails] is false for promote mirrors (no PK lists needed).
  /// Error [ResultType]s still arrive on [DbResult.statuses] for hard-fail
  /// paths; when statuses are empty we do not invent a generic type.
  void _promoteThrowIfNonBusinessFailure(DbResult result) {
    if (!result.hasErrors) return;
    final statuses = result.statuses;
    if (statuses.isEmpty) return;
    if (_promoteIsBusinessOnlyStatuses(statuses)) return;
    throw DbException(statuses);
  }

  /// Swallow [DbClosedException] and business-only [DbException]; otherwise
  /// rethrow the original exception unchanged.
  void _promoteRethrowUnlessBusinessOrClosed(Object e) {
    if (e is DbClosedException) return;
    if (e is DbException && _promoteIsBusinessOnlyStatuses(e.statuses)) {
      return;
    }
    throw e;
  }

  bool _promoteIsBusinessOnlyStatuses(List<ResultStatus> statuses) {
    if (statuses.isEmpty) return false;
    return statuses.every(
      (s) => s.type == ResultType.success || s.type.isBusinessError,
    );
  }

  DbResult _promoteRejectLargeOp(String tableName, String op) {
    final message =
        'Table "$tableName" is running promoteFieldToPrimaryKey; $op with a '
        'non-optimizable (large-scale data) condition may cause memory exhaustion. '
        'Narrow the query scope or wait until promote completes, then retry.';
    Logger.warn(message);
    return DbResult.error(
      type: ResultType.devMigrationPromoteLargeOpNotAllowed,
      message: message,
      statuses: [
        SchemaValidationStatus(
          type: ResultType.devMigrationPromoteLargeOpNotAllowed,
          message: message,
          tableName: tableName,
        ),
      ],
    );
  }

  /// Apply logical table-rename side effects during schema cutover.
  ///
  /// Data/index paths are keyed by stable [TableUid], so there is no directory
  /// move. This updates referencing schemas and FK system tables.
  Future<void> applyTableRenameSideEffects({
    required String oldTableName,
    required String newTableName,
  }) async {
    if (oldTableName == newTableName) return;

    final updatedReferencingTables = <String>{};
    await _updateSchemasReferencingRenamedTable(
      oldTableName,
      newTableName,
      updatedTables: updatedReferencingTables,
    );
    await _refreshForeignKeyMetadataAfterRename(
      oldTableName,
      newTableName,
      referencingTables: updatedReferencingTables,
      throwOnError: true,
    );
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
    final schemaMgr = tableMetaManager;
    if (schemaMgr == null) {
      return;
    }

    final tablesToScan = candidateTables ?? await schemaMgr.listAllTables();

    for (final tableName in tablesToScan) {
      if (tableName == newTableName) continue;

      final schema = await schemaMgr.getTableSchemaByName(TableName(tableName));
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
      final tableCtx = await getTableContext(tableName);
      await schemaMgr.updateTableMeta(
        tableCtx.tableUid,
        schema: updatedSchema,
      );
      updatedTables?.add(tableName);
    }
  }

  Future<void> _refreshForeignKeyMetadataAfterRename(
    String oldTableName,
    String newTableName, {
    Iterable<String> referencingTables = const <String>[],
    bool throwOnError = false,
  }) async {
    final fkManager = foreignKeyManager;
    final schemaMgr = tableMetaManager;
    if (fkManager == null || schemaMgr == null) {
      return;
    }

    final tablesToRefresh = <String>{newTableName};
    tablesToRefresh.addAll(referencingTables);

    final schemasToRefresh = <String, TableSchema>{};
    for (final tableName in tablesToRefresh) {
      final schema = await schemaMgr.getTableSchemaByName(TableName(tableName));
      if (schema != null) {
        schemasToRefresh[tableName] = schema;
      }
    }

    final requiresRefresh = referencingTables.isNotEmpty ||
        schemasToRefresh.values.any((schema) => schema.foreignKeys.isNotEmpty);

    // Meta already points at [newTableName]; old name no longer resolves.
    // Cleanup matches FK rows by the logical name string, so pass a context
    // that still carries the pre-rename name while keeping the stable uid.
    final renamedCtx = await getTableContext(newTableName);
    await fkManager.cleanupSystemTableForDroppedTable(
      TableContext(
        tableUid: renamedCtx.tableUid,
        tableName: TableName(oldTableName),
        isGlobal: renamedCtx.isGlobal,
        dirIndex: renamedCtx.dirIndex,
        schema: renamedCtx.schema,
      ),
      throwOnError: throwOnError,
    );

    if (!requiresRefresh) {
      return;
    }

    for (final entry in schemasToRefresh.entries) {
      await fkManager.updateSystemTableForTable(
        await getTableContext(entry.key),
        entry.value,
        throwOnError: throwOnError,
      );
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

      if (await storage.existsFile(configPath)) {
        final bytes = await storage.readAsBytes(configPath);
        if (bytes.isEmpty) return null;

        final preferred = _resolveEncryptionKeyForGlobalConfig();
        final decoded = GlobalConfigCodec.decodeFileWithFallback(
          bytes,
          preferredKey: preferred,
          fallbackKeys: [
            defaultEncryptionKey,
          ],
        );
        _globalConfigCache = decoded.config;

        // Auto-rewrap when opened with a newer encryptionKey than on disk.
        if (decoded.usedKey != preferred) {
          await saveGlobalConfig(decoded.config, propagateErrors: false);
        }
        return decoded.config;
      }

      // Pre-v3: read JSON into memory only - do NOT write TOBF or delete JSON.
      // `tableDirectoryMap` must remain on disk until V3Upgrade consumes it.
      final legacy = await LegacyConfigBootstrap.readGlobalConfig(this);
      if (legacy != null) {
        _globalConfigCache = legacy;
        return legacy;
      }
      return null;
    } catch (e) {
      Logger.error('Failed to get global config', rawError: e);
      return null;
    }
  }

  String _resolveEncryptionKeyForGlobalConfig() {
    final enc = _config?.encryptionConfig ?? const EncryptionConfig();
    return enc.resolveEncryptionKey();
  }

  /// Save global configuration
  ///
  /// When [propagateErrors] is true, failures are rethrown (required for v3
  /// finalize so legacy JSON is never deleted after a failed TOBF write).
  Future<void> saveGlobalConfig(
    GlobalConfig config, {
    bool propagateErrors = false,
  }) async {
    try {
      // Update memory cache only after successful disk write when propagating,
      // so a failed upgrade write cannot leave cache ahead of durable state.
      final configPath = pathManager.getGlobalConfigPath();

      await storage.ensureDirectoryExists(
        path.dirname(configPath),
      );

      final bytes = GlobalConfigCodec.encodeFile(
        config,
        encryptionKey: _resolveEncryptionKeyForGlobalConfig(),
        algorithm: ConfigCryptoAlgorithm.fromEncryptionType(
          _config?.encryptionConfig?.encryptionType,
        ),
      );
      await storage.writeAsBytes(configPath, bytes);
      _globalConfigCache = config;

      // Version-only JSON stub for older engines (once per version per process).
      unawaited(ensureDowngradeGuardJson(version: config.version));
    } catch (e) {
      Logger.error('Failed to save global config', rawError: e);
      if (propagateErrors) rethrow;
    }
  }

  /// Ensure `global_config.json` holds a version-only downgrade guard.
  ///
  /// Skips when [version] is less than 3, or when this process already confirmed
  /// the stub for [version] ([_downgradeGuardJsonVersion]). On restart, probes
  /// the existing stub first - matching version avoids a redundant rewrite.
  Future<void> ensureDowngradeGuardJson({required int version}) async {
    if (version < 3) return;
    if (_downgradeGuardJsonVersion == version) return;
    final ok = await LegacyConfigBootstrap.writeDowngradeGuardJson(
      this,
      version: version,
    );
    if (ok) {
      _downgradeGuardJsonVersion = version;
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
      Logger.error('Failed to add space to global config', rawError: e);
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
      Logger.error('Error checking and migrating old path structure',
          rawError: e);
      // Error doesn't affect continued use, just log it
    }
  }

  /// Get information about the current space
  Future<SpaceInfo> getSpaceInfo({bool useCache = true}) async {
    try {
      var stats = await getSpaceStats();

      // Full meta reconcile only when caller opts out of cache.
      // Day-to-day totals come from incremental counters; avoid O(tables)
      // meta scans on large spaces (e.g. tens of thousands of tables).
      if (!useCache) {
        await tableDataManager.recalculateAllStatistics();
        // Memory already holds absolute totals; do not re-read KV baseline.
        stats = await getSpaceStats();
      }

      return SpaceInfo(
        spaceName: _currentSpaceName,
        totalRecordCount: stats.totalRecordCount,
        totalTableDataSizeBytes: stats.totalTableDataSizeBytes,
        totalIndexDataSizeBytes: stats.totalIndexDataSizeBytes,
        lastStatisticsTime: stats.lastStatisticsTime,
      );
    } catch (e) {
      Logger.error('Failed to get space info', rawError: e);
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
      );
      return DbResult.error(
        type: ResultType.devInvalidArgumentFormat,
        message: 'Cannot delete the default space',
        statuses: [
          InvalidArgumentStatus(
            type: ResultType.devInvalidArgumentFormat,
            message: 'Cannot delete the default space',
            parameterName: 'spaceName',
            passedValue: spaceName,
          )
        ],
      );
    }

    if (spaceName == _currentSpaceName) {
      Logger.warn(
        'Cannot delete the currently active space. Please switch to another space before deleting.',
      );
      return DbResult.error(
        type: ResultType.devInvalidArgumentFormat,
        message:
            'Cannot delete the currently active space. Please switch to another space before deleting.',
        statuses: [
          InvalidArgumentStatus(
            type: ResultType.devInvalidArgumentFormat,
            message:
                'Cannot delete the currently active space. Please switch to another space before deleting.',
            parameterName: 'spaceName',
            passedValue: spaceName,
          )
        ],
      );
    }

    try {
      final globalConfig = await getGlobalConfig();
      if (globalConfig == null ||
          !globalConfig.spaceNames.contains(spaceName)) {
        Logger.warn('Space $spaceName does not exist, no need to delete.');
        return DbResult.error(
          type: ResultType.devSpaceNotFound,
          message: 'Space $spaceName does not exist',
        );
      }

      // 1. Get the path for the space
      final spacePath = pathManager.getSpacePath(spaceName: spaceName);

      // 2. Delete the space directory
      if (await storage.existsDirectory(spacePath)) {
        await storage.deleteDirectory(spacePath);
      }

      // 3. Remove the space from GlobalConfig
      final updatedSpaces = Set<String>.from(globalConfig.spaceNames)
        ..remove(spaceName);
      final updatedConfig = globalConfig.copyWith(spaceNames: updatedSpaces);
      await saveGlobalConfig(updatedConfig);

      Logger.info('Space $spaceName has been successfully deleted.');
      return DbResult.success(
        message: 'Space $spaceName deleted successfully',
      );
    } catch (e) {
      Logger.error('Failed to delete space $spaceName', rawError: e);
      // Convert any unexpected exceptions to DbResult
      final dbEx = DbException.wrap(e,
          fallbackType: ResultType.engError,
          fallbackMessage: 'Failed to delete space $spaceName');
      return DbResult.batch(
        statuses: dbEx.statuses,
        failedCount: dbEx.statuses.length,
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

  /// Update in-memory encryption key after [KeyManager.rotateEncryptionKey].
  void updateEncryptionKeyInConfig(String newKey) {
    final base = _config?.encryptionConfig ?? const EncryptionConfig();
    _config = _config!.copyWith(
      encryptionConfig: base.copyWith(encryptionKey: newKey),
    );
  }

  /// Rotate the master [encryptionKey] that protects GlobalConfig.
  ///
  /// When [oldKey] is null/empty, the engine built-in default KEK is used.
  Future<DbResult> rotateEncryptionKey({
    String? oldKey,
    required String newKey,
  }) async {
    await ensureInitialized();
    return keyManager.rotateEncryptionKey(oldKey: oldKey, newKey: newKey);
  }

  /// Stream records from a table with filtering
  /// This method provides an efficient way to process large datasets by streaming records one at a time
  ///
  /// @param tableName The name of the table to stream records from
  /// @param condition Optional query conditions to filter records
  /// @param selectedFields Optional list of fields to include in the results
  Stream<Map<String, dynamic>> streamRecords(
    TableContext table, {
    QueryCondition? condition,
    List<String>? selectedFields,
  }) async* {
    try {
      await ensureInitialized();
      final tableName = table.tableName;
      // Check if table exists
      if (!await tableExists(tableName)) {
        Logger.error('Table $tableName does not exist');
        return;
      }

      // Get table schema
      final schema = table.schema;
      if (schema.name.isEmpty) {
        Logger.error('Failed to get schema for $tableName');
        return;
      }

      final schemas = {tableName: schema};
      final matcher = condition != null
          ? ConditionRecordMatcher.prepare(condition, schemas, tableName)
          : null;

      // Stream all records from table using the existing tableDataManager method
      final recordStream = tableDataManager.streamRecords(table);

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
        Logger.error('Error streaming records', rawError: e);
        rethrow;
      }
    } catch (e) {
      Logger.error('Error streaming records', rawError: e);
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
