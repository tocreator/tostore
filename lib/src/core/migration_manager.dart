import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../handler/binary_schema_codec.dart';
import '../handler/logger.dart';
import '../model/background_write_entry.dart';
import '../model/background_write_type.dart';
import '../model/buffer_entry.dart';
import '../model/cancellation_token.dart';
import '../model/db_exception.dart';
import '../model/id_generator.dart';
import '../model/key_migration_info.dart';
import '../model/meta_info.dart';
import '../model/migration_meta.dart';
import '../model/migration_task.dart';
import '../model/migration_write_mode.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/system_table.dart';
import '../model/table_schema.dart';
import '../model/table_context.dart';
import '../model/wal_pointer.dart';
import 'backup_manager.dart';
import 'compute_manager.dart';
import 'compute_tasks.dart';
import 'crontab_manager.dart';
import 'data_store_impl.dart';
import 'key_migration_progress.dart';
import 'key_migration_runner.dart';
import 'large_operation_runner.dart';
import 'transaction_context.dart';
import 'yield_controller.dart';
import '../model/table_identity.dart';

/// Migration manager for handling database version upgrades
///
/// 1. Efficiently and automatically detect table structure changes
///   - Accurately detect field renaming, table renaming, and table deletion
///   - Use field ID or weight system to avoid misjudgment
///   - Table renaming detection based on multi-dimensional similarity analysis
///
/// 2. Optimized migration process
///   - Automatically generate migration tasks and execute them by space
///   - Transaction guarantee and error recovery mechanism
///   - Migration task persistence and status tracking
///
/// 3. High-performance data transformation
///   - Batch processing to optimize performance
///   - Priority processing for important spaces
///   - Memory management and cache optimization
class MigrationManager {
  final DataStoreImpl _dataStore;
  // Pending migration tasks
  final List<MigrationTask> _pendingTasks = [];
  // Whether migration tasks are being processed
  bool _isProcessingTasks = false;
  // Telemetry for migration progress
  final _MigrationTelemetry _telemetry = _MigrationTelemetry();

  // Active progress callback for blocking/synchronized migration task.
  void Function(double progress)? _activeTaskProgressCallback;

  // In-memory cache for migration metadata to avoid frequent file reads
  MigrationMeta? _migrationMetaCache;
  // Current directory index cache (derived from directoryMapping)
  int? _currentDirIndexCache;
  // Lock for thread-safe access to cache
  Future<MigrationMeta>? _loadingFuture;
  // Runtime conversion descriptors for tables that are schema-updated but data not fully migrated yet.
  final Map<TableUid, _RuntimeMigrationDescriptor> _runtimeMigrations =
      <TableUid, _RuntimeMigrationDescriptor>{};

  // Cache of versioned table schemas for active migrations keyed by schemaVersion
  final Map<String, TableSchema> _schemaByVersion = {};

  /// Register schema version in memory cache.
  void registerSchemaVersion(TableSchema schema) {
    if (schema.schemaVersion != null && schema.schemaVersion!.isNotEmpty) {
      _schemaByVersion[schema.schemaVersion!] = schema;
    }
  }

  /// Batch register schema versions from migration tasks.
  void registerSchemaVersionsFromTasks(List<MigrationTask> tasks) {
    for (final task in tasks) {
      if (task.oldSchemaSnapshot != null) {
        registerSchemaVersion(task.oldSchemaSnapshot!);
      }
      if (task.targetSchemaSnapshot != null) {
        registerSchemaVersion(task.targetSchemaSnapshot!);
      }
    }
  }

  /// Retrieve TableSchema by schema version.
  TableSchema? getTableSchemaByVersion(String schemaVersion) {
    return _schemaByVersion[schemaVersion];
  }

  static const String _deletedSlotFieldPrefix = '_system_storage_deleted_slot_';
  static const String _globalMigrationScope = '__global__';

  // Active partition stream controllers for graceful cancellation
  final Map<String, CancellationToken> _activeControllers = {};

  // Active migration instances: spaceName -> DataStoreImpl
  final Map<String, DataStoreImpl> _activeMigrationInstances = {};

  // Active migration tasks: spaceName -> Future
  final Map<String, Future<void>> _activeSpaceMigrationTasks = {};

  // Key: tableUid, Value: latest in-memory read cursor during active migration
  final Map<String, String> _activeReadCursors = {};

  // Active executing task ID
  String? _activeExecutingTaskId;
  // Active executing task Future
  Future<void>? _activeTaskFuture;

  /// Whether schema or key migration work is still pending.
  static bool computeHasPendingMigrationWork({
    required bool hasSchemaTasks,
    required KeyMigrationInfo? keyMigrationInfo,
  }) {
    final hasKeyMigration =
        keyMigrationInfo != null && keyMigrationInfo.isRunning;
    return hasSchemaTasks || hasKeyMigration;
  }

  /// Read persisted key migration metadata.
  Future<KeyMigrationInfo?> getKeyMigrationInfo() async {
    final meta = await _getOrLoadMigrationMeta();
    return meta.keyMigrationInfo;
  }

  /// Whether a key re-encryption migration is in progress (uses in-memory meta cache).
  bool hasRunningKeyMigration() {
    final info = _migrationMetaCache?.keyMigrationInfo;
    return info != null && info.isRunning;
  }

  /// Persist key migration metadata and sync [GlobalConfig.hasMigrationTask].
  Future<void> persistKeyMigrationInfo(KeyMigrationInfo info) async {
    final meta = await _getOrLoadMigrationMeta();
    await _saveMigrationMeta(meta.copyWith(keyMigrationInfo: info));
    await syncHasMigrationTask();
  }

  /// Remove key migration metadata after successful completion.
  Future<void> clearKeyMigrationInfo() async {
    final meta = await _getOrLoadMigrationMeta();
    if (meta.keyMigrationInfo == null) return;
    await _saveMigrationMeta(meta.copyWith(clearKeyMigrationInfo: true));
    await syncHasMigrationTask();
  }

  /// Single entry point to align [GlobalConfig.hasMigrationTask] with migration meta.
  ///
  /// Clears the flag only when both schema tasks and key migration are complete.
  Future<void> syncHasMigrationTask() async {
    final globalConfig = await _dataStore.getGlobalConfig();
    if (globalConfig == null) return;

    final meta = await _getOrLoadMigrationMeta();
    final hasPending = computeHasPendingMigrationWork(
      hasSchemaTasks: _pendingTasks.isNotEmpty,
      keyMigrationInfo: meta.keyMigrationInfo,
    );

    if (globalConfig.hasMigrationTask != hasPending) {
      await _dataStore.saveGlobalConfig(
        globalConfig.copyWith(hasMigrationTask: hasPending),
      );
    }
  }

  /// Get the active in-memory read cursor for a table undergoing migration
  String? getActiveReadCursor(TableContext table) {
    return _activeReadCursors[table.tableUid];
  }

  Future<TableContext> _requireTableContext(String tableName) =>
      _dataStore.getTableContext(tableName);

  Future<TableContext?> _tableContextForUid(TableUid tableUid) async =>
      _dataStore.tableMetaManager?.getTableContext(tableUid);

  String _resolveCurrentTableNameFromName(
    String tableName,
    List<MigrationOperation> operations,
  ) {
    final renameOp = _findRenameOperation(operations);
    return renameOp?.newTableName ?? tableName;
  }

  MigrationManager(this._dataStore) {
    _startPollingTimer();
  }

  void _startPollingTimer() {
    // Use global CrontabManager for energy-efficient safety-net polling.
    // This ensures migration progress even if event-based notifications are missed.
    CrontabManager.addCallback(ExecuteInterval.seconds30, _triggerFlushes);
  }

  void _triggerFlushes() {
    if (!_dataStore.isInitialized) return;
    // Trigger flush for the primary datastore
    if (!_dataStore.backgroundWriteScheduler.isEmpty) {
      _dataStore.parallelJournalManager.scheduleFlushIfNeeded();
    }
    // Trigger flush for all active space migration instances
    for (final space in _activeMigrationInstances.keys) {
      final instance = _activeMigrationInstances[space];
      if (instance != null && !instance.backgroundWriteScheduler.isEmpty) {
        instance.parallelJournalManager.scheduleFlushIfNeeded();
      }
    }
  }

  void dispose() {
    CrontabManager.removeCallback(ExecuteInterval.seconds30, _triggerFlushes);
  }

  bool get hasPendingTasks => _pendingTasks.isNotEmpty;

  /// Whether unfinished **schema** migration tasks exist (in memory or on disk).
  ///
  /// Does not include key migration; use [hasPendingKeyMigrationWork] for that.
  Future<bool> hasPendingSchemaMigrationWork() async {
    if (_pendingTasks.isNotEmpty) return true;
    return (await _findUnfinishedSchemaTaskIdsForTableUid(null)).isNotEmpty;
  }

  /// Whether key re-encryption migration is still in progress (reads persisted meta).
  Future<bool> hasPendingKeyMigrationWork() async {
    final info = await getKeyMigrationInfo();
    return info != null && info.isRunning;
  }

  /// Whether schema or key migration work is still pending (authoritative meta check).
  Future<bool> hasAnyPendingMigrationWork() async {
    if (await hasPendingSchemaMigrationWork()) return true;
    return hasPendingKeyMigrationWork();
  }

  /// Get all currently pending migration tasks.
  List<MigrationTask> get pendingTasks => List.unmodifiable(_pendingTasks);

  /// Check if there is an unfinished migration task for the table that builds the specified index.
  bool hasPendingIndexBuild(TableUid tableUid, IndexUid indexUid) {
    for (final task in _pendingTasks) {
      if (task.tableUid != tableUid || task.pendingMigrationSpaces.isEmpty) {
        continue;
      }
      if (task.specificIndexUids == null) return true;
      final schema = task.targetSchemaSnapshot ?? task.oldSchemaSnapshot;
      for (final field in task.specificIndexUids!) {
        if (field == indexUid) return true;
        if (schema == null) continue;
        final a = _dataStore.tableMetaManager
            ?.resolveIndexUidFromField(schema, field);
        if (a != null && a == indexUid) return true;
      }
    }
    return false;
  }

  bool hasRuntimeMigrationForTable(TableContext table) {
    return _findRuntimeMigrationDescriptor(table) != null;
  }

  String? getPersistedCheckpointKey(TableUid tableUid, String spaceName) {
    final task = _findTaskInMemoryByTableUid(tableUid);
    if (task == null) return null;
    return task.checkpointKeyForSpace(spaceName);
  }

  String? getPersistedCheckpointKeyForTask(String taskId, String spaceName) {
    for (final task in _pendingTasks) {
      if (task.taskId == taskId) {
        return task.checkpointKeyForSpace(spaceName);
      }
    }
    return null;
  }

  MigrationTask? _findTaskInMemoryByTableUid(TableUid tableUid) {
    try {
      return _pendingTasks.firstWhere((t) => t.tableUid == tableUid);
    } catch (_) {
      return null;
    }
  }

  /// Callback when a batch of background write entries are successfully persisted.
  Future<void> onBackgroundWritePersisted(
      Map<String, BgTaskProgress> progressMap) async {
    if (progressMap.isEmpty) return;

    final yieldController =
        YieldController('MigrationManager.onBackgroundWritePersisted');

    try {
      final currentSpace = _dataStore.currentSpaceName;

      // Update task checkpoints atomically per task
      for (final entry in progressMap.entries) {
        await yieldController.maybeYield();
        final taskId = entry.key;
        final progress = entry.value;

        if (taskId.startsWith('large_delete_')) {
          final op = _dataStore.walManager.meta.largeDeletes[taskId];
          if (op != null) {
            final nextDeletedSoFar = op.deletedSoFar + progress.count;
            await _dataStore.walManager.updateLargeDeleteCheckpoint(
              opId: taskId,
              deletedSoFar: nextDeletedSoFar,
              checkpointCursor: progress.checkpointKey,
            );
            final tableCtx = await _tableContextForUid(op.tableUid);
            if (tableCtx != null) {
              await _dataStore.tableDataManager.updateTableRecordCountDelta(
                tableCtx,
                deleteDelta: progress.count,
              );
              await _dataStore.cacheManager.invalidateCache(tableCtx);
            }
          }
          continue;
        }

        if (taskId.startsWith('large_update_')) {
          final op = _dataStore.walManager.meta.largeUpdates[taskId];
          if (op != null) {
            final nextUpdatedSoFar = op.updatedSoFar + progress.count;
            await _dataStore.walManager.updateLargeUpdateCheckpoint(
              opId: taskId,
              updatedSoFar: nextUpdatedSoFar,
              checkpointCursor: progress.checkpointKey,
            );
            final tableCtx = await _tableContextForUid(op.tableUid);
            if (tableCtx != null) {
              await _dataStore.cacheManager.invalidateCache(tableCtx);
            }
          }
          continue;
        }

        final keyMigrationTableUid =
            KeyMigrationRunner.tableUidFromTaskId(taskId);
        if (keyMigrationTableUid != null) {
          if (progress.checkpointKey != null) {
            final tableCtx =
                await _tableContextForUid(TableUid(keyMigrationTableUid));
            if (tableCtx != null) {
              final scope =
                  KeyMigrationRunner.scopeForTable(_dataStore, tableCtx);
              await KeyMigrationProgressStore.upsertRunning(
                _dataStore,
                table: tableCtx,
                spaceName: scope,
                checkpointKey: progress.checkpointKey,
              );
            }
          }
          continue;
        }

        final task = _findTaskInMemory(taskId);
        if (task == null) continue;

        MigrationTask updatedTask = task;
        if (progress.checkpointKey != null) {
          final checkpointBytes = base64Decode(progress.checkpointKey!);
          updatedTask = _updateTaskCheckpointForSpace(
            updatedTask,
            currentSpace,
            checkpointBytes,
          );
        }

        await _saveMigrationTask(updatedTask);
        _updatePendingTaskInMemory(updatedTask);
        _rebuildRuntimeMigrations(TableUid(updatedTask.tableUid));

        // Update telemetry
        _telemetry.recordRecordsProcessed(taskId, progress.count);

        if (_activeTaskProgressCallback != null) {
          final allSpaces =
              await _getMigrationScopesForSchema(updatedTask.oldSchemaSnapshot);
          final totalSpaces = allSpaces.isNotEmpty ? allSpaces.length : 1;
          final progressVal = _telemetry.getTaskProgress(
            taskId,
            totalSpaces,
            updatedTask.pendingMigrationSpaces.length,
          );
          _activeTaskProgressCallback!(progressVal);
        }
      }
    } catch (e) {
      Logger.error('Failed to notify background write completion', rawError: e);
    }
  }

  MigrationTask? _findTaskInMemory(String taskId) {
    try {
      return _pendingTasks.firstWhere((t) => t.taskId == taskId);
    } catch (_) {
      return null;
    }
  }

  /// Stop all active migrations managed by this manager.
  Future<void> stopAllMigrations() async {
    final spaces = _activeSpaceMigrationTasks.keys.toList();
    for (final space in spaces) {
      await stopMigrationForSpace(space);
    }

    final futures = _activeSpaceMigrationTasks.values.toList();
    if (futures.isNotEmpty) {
      await Future.wait(futures).catchError((_) => const []);
    }

    // Clear global migration caches to ensure fresh state on next open/switch
    _migrationMetaCache = null;
    _currentDirIndexCache = null;
    _pendingTasks.clear();
    _runtimeMigrations.clear();
    _isProcessingTasks = false;
  }

  /// Stop any active migration for a specific space (e.g. during space switch).
  Future<void> stopMigrationForSpace(String spaceName) async {
    final controller = _activeControllers[spaceName];
    if (controller != null) {
      Logger.info('Stopping background migration for space [$spaceName]...');
      controller.cancel();
      // Do not remove from _activeControllers yet, let the task finish
    }

    // Wait for the migration task future to complete
    final taskFuture = _activeSpaceMigrationTasks[spaceName];
    if (taskFuture != null) {
      try {
        await taskFuture;
      } catch (e) {
        if (e is DbClosedException) {
          Logger.info('Migration for space [$spaceName] stopped gracefully');
        } else {
          Logger.error('Failed to wait for migration task stop', rawError: e);
        }
      }
    }

    // Ensure the migration instance is closed (this will flush remaining migration data)
    final instance = _activeMigrationInstances[spaceName];
    if (instance != null && instance != _dataStore) {
      try {
        await instance.close();
      } catch (e) {
        Logger.error('Failed to close migration instance', rawError: e);
      }
    }

    // Cleanup
    _activeControllers.remove(spaceName);
    _activeSpaceMigrationTasks.remove(spaceName);
    _activeMigrationInstances.remove(spaceName);
  }

  /// Whether a buffered write should be normalized through runtime migration
  /// operations before flush.
  ///
  /// Rule:
  /// - no runtime descriptor => false
  /// - alias table name (e.g. pre-rename name) => true
  /// - cutover unknown / wal pointer missing => true (safe default)
  /// - record newer than cutover => false (already written in new logical shape)
  /// - otherwise => true
  bool shouldNormalizeBufferedWrite(
      TableContext table, WalPointer? walPointer) {
    final descriptor = _findRuntimeMigrationDescriptor(table);
    if (descriptor == null) {
      return false;
    }

    final canonicalName =
        _dataStore.tableMetaManager?.getNameByUid(descriptor.tableUid);
    if (canonicalName != null && table.tableName != canonicalName) {
      return true;
    }

    final cutover = descriptor.cutoverPointer;
    if (cutover == null || walPointer == null) {
      return true;
    }

    final walCycle = _dataStore.config.logPartitionCycle;
    return !walPointer.isNewerThan(cutover, walCycle);
  }

  List<FieldStructure>? getLegacyFieldStructureForWrite(TableContext table) {
    final descriptor = _findRuntimeMigrationDescriptor(table);
    if (descriptor == null) {
      return null;
    }
    return descriptor.oldFieldStruct;
  }

  TableSchema? getLegacySchemaForWrite(TableContext table) {
    final descriptor = _findRuntimeMigrationDescriptor(table);
    return descriptor?.oldSchema;
  }

  List<String> getRuntimeReadTableCandidates(TableContext table) {
    final descriptor = _findRuntimeMigrationDescriptor(table);
    if (descriptor == null) {
      return const <String>[];
    }
    final out = <String>[];
    for (final alias in descriptor.tableAliases) {
      if (alias == table.tableName) continue;
      out.add(alias);
    }
    return out;
  }

  _RuntimeMigrationDescriptor? _findRuntimeMigrationDescriptor(
      TableContext table) {
    return _runtimeMigrations[table.tableUid];
  }

  /// Symmetrically normalizes a record from a historical version up to the latest active schema version.
  Map<String, dynamic> normalizeRecordToLatestSync(
    TableContext table,
    Map<String, dynamic> record, {
    required String fromVersion,
  }) {
    final tableTasks = _pendingTasks.where((t) {
      final currentName = t.currentTableName ??
          _resolveCurrentTableNameFromName(t.tableName, t.operations);
      return t.tableUid == table.tableUid ||
          t.tableName == table.tableName ||
          currentName == table.tableName;
    }).toList()
      ..sort((a, b) => a.createTime.compareTo(b.createTime));

    var currentRecord = Map<String, dynamic>.from(record);

    if (fromVersion.isEmpty) {
      bool shouldApply = false;
      for (final task in tableTasks) {
        if (!shouldApply) {
          for (final op in task.operations) {
            if (op.type == MigrationType.renameField &&
                op.fieldName != null &&
                op.newName != null &&
                record.containsKey(op.fieldName) &&
                !record.containsKey(op.newName)) {
              shouldApply = true;
              break;
            }
            if (op.type == MigrationType.addField) {
              final newName = op.field?.name ?? op.fieldName;
              if (newName != null && !record.containsKey(newName)) {
                shouldApply = true;
                break;
              }
            }
          }
        }
        if (shouldApply) {
          currentRecord = applyMigrationOperationsSync(
            currentRecord,
            task.operations,
            task.oldSchemaSnapshot,
          );
        }
      }
      return currentRecord;
    }

    bool startUpgrading = false;

    for (final task in tableTasks) {
      final taskOldVersion = task.oldSchemaSnapshot?.schemaVersion;
      final taskTargetVersion = task.targetSchemaSnapshot?.schemaVersion;

      if (taskOldVersion == fromVersion) {
        startUpgrading = true;
      }

      if (startUpgrading) {
        currentRecord = applyMigrationOperationsSync(
          currentRecord,
          task.operations,
          task.oldSchemaSnapshot,
        );
      }

      if (taskTargetVersion == fromVersion) {
        startUpgrading = true;
      }
    }

    return currentRecord;
  }

  /// Symmetrically resolves a historical TableSchema by slot count from pending tasks list.
  Future<TableSchema?> getTableSchemaBySlotCount(
    TableContext table,
    int slotCount,
  ) async {
    final schemaMgr = _dataStore.tableMetaManager;
    if (schemaMgr == null) return null;

    final tableTasks = _pendingTasks.where((t) {
      final currentName = t.currentTableName ??
          _resolveCurrentTableNameFromName(t.tableName, t.operations);
      return t.tableUid == table.tableUid ||
          t.tableName == table.tableName ||
          currentName == table.tableName;
    });

    for (final t in tableTasks) {
      if (t.oldSchemaSnapshot != null) {
        final layout = await schemaMgr.getTableFieldLayout(
          table.tableUid,
          schema: t.oldSchemaSnapshot,
        );
        if (layout.totalSlots == slotCount) {
          return t.oldSchemaSnapshot;
        }
      }
      if (t.targetSchemaSnapshot != null) {
        final layout = await schemaMgr.getTableFieldLayout(
          table.tableUid,
          schema: t.targetSchemaSnapshot,
        );
        if (layout.totalSlots == slotCount) {
          return t.targetSchemaSnapshot;
        }
      }
    }
    return null;
  }

  /// Execute migration from old version to new version
  Future<void> migrate({
    required List<TableSchema> userSchemas,
    required List<TableSchema> systemSchemas,
    int batchSize = 1000,
    bool waitForCompletion = false,
    void Function(double progress)? onProgress,
  }) async {
    try {
      final targetSchemas = <TableSchema>[];

      // System schemas: trusted engine definitions — do not strip engine fields.
      for (final schema in systemSchemas) {
        final reservedSystemTableNames = SystemTable.systemTableNames;
        final systemSchema = schema.copyWith(isSystemTable: true);
        systemSchema.validateTableSchema(
          reservedTableNames: reservedSystemTableNames,
          allowReservedTableNames: true,
          allowInternalTableNamePrefix: true,
          allowOtherInternalFields: true,
        );
        targetSchemas.add(systemSchema);
      }

      // User schemas: strip any injected engine fields at the migrate boundary.
      for (final schema in userSchemas) {
        final reservedSystemTableNames = SystemTable.systemTableNames;
        final userSchema = schema.cleanInternalFields();
        userSchema.validateTableSchema(
          reservedTableNames: reservedSystemTableNames,
          allowReservedTableNames: false,
          allowInternalTableNamePrefix: false,
          allowOtherInternalFields: false,
        );
        targetSchemas.add(userSchema);
      }

      Logger.info(
        'Start database migration: involving ${targetSchemas.length} tables',
      );

      // Performance optimization: Skip migration if no schemas
      if (targetSchemas.isEmpty) {
        return;
      }

      // Get all existing tables
      var existingTables = await _dataStore.getTableNames();
      existingTables = existingTables
          .where((t) => !t.startsWith('_system_temp_op_conflict_'))
          .toList();

      final allTasks = <MigrationTask>[];

      // Record migration start time
      final startTime = DateTime.now();

      // 1. First detect table renaming to avoid subsequent processing misidentifying renamed tables as new + deleted
      final detectRenameResult =
          await _detectRenamedTables(existingTables, targetSchemas);
      final renamedTables = detectRenameResult.renamedTables;
      final tablesToCreate = detectRenameResult.tablesToCreate;
      final rawTablesToDrop = detectRenameResult.tablesToDrop;

      final tablesToDrop = userSchemas.isNotEmpty
          ? rawTablesToDrop
          : rawTablesToDrop.where(SystemTable.isSystemTable).toList();

      final renamedTableTargets = <String, String>{};
      for (final entry in renamedTables.entries) {
        renamedTableTargets[entry.key] = entry.value.name;
      }

      // Perform global database schema consistency validation before executing migration
      await _validateGlobalSchemaConsistency(
        targetSchemas: targetSchemas,
        renamedTableTargets: renamedTableTargets,
        existingTables: existingTables,
      );

      // Handle renamed tables
      for (final entry in renamedTables.entries) {
        final oldTableName = entry.key;
        final newSchema = entry.value;

        try {
          // Get old table schema
          final oldSchema = await _dataStore.tableMetaManager
              ?.getTableSchemaByName(TableName(oldTableName));
          if (oldSchema == null) {
            continue;
          }

          // Compare possible structure changes
          final schemaOperations = await _compareSchemasAndGenerateOperations(
            oldSchema,
            newSchema,
            renamedTableTargets: renamedTableTargets,
          );

          // Generate final operations list
          final operations = <MigrationOperation>[];
          // 1. First add structural changes (performed on the old table name)
          operations.addAll(schemaOperations);
          // 2. Finally add the table rename operation
          operations.add(MigrationOperation(
            type: MigrationType.renameTable,
            newTableName: newSchema.name,
          ));

          if (!SystemTable.isSystemTable(oldTableName)) {
            Logger.info(
              'Table [$oldTableName -> ${newSchema.name}] generated ${operations.length} migration operations',
            );
          }

          // Create migration task but do not process immediately
          final task = await addMigrationTask(
            TableUid(oldSchema.tableUid),
            operations,
            startProcessing: false,
            isAutoGenerated: true,
            targetSchemaSnapshot: newSchema,
          );
          if (task != null) {
            allTasks.add(task);
          }
        } catch (e) {
          Logger.error(
              'Failed to handle table renaming [$oldTableName -> ${newSchema.name}]',
              rawError: e);
          rethrow;
        }
      }

      // 2. Handle remaining tables
      int tablesUpdated = 0;
      int tablesCreated = 0;

      for (var schema in targetSchemas) {
        try {
          // Skip already processed renamed tables
          if (renamedTables.values.any((s) => s.name == schema.name)) {
            continue;
          }

          if (existingTables.contains(schema.name) &&
              !tablesToDrop.contains(schema.name)) {
            // Migrate existing table
            final task = await _migrateExistingTable(
              schema,
              batchSize: batchSize,
              renamedTableTargets: renamedTableTargets,
            );
            if (task != null) {
              allTasks.add(task);
              tablesUpdated++;
            }
          } else if (tablesToCreate.contains(schema.name)) {
            // Create new table (isSystemTable already set at migrate entry)
            await _dataStore.createTable(
              schema,
              isSystemTable: schema.isSystemTable,
            );
            tablesCreated++;

            if (!schema.isSystemTable) {
              Logger.info(
                'Create new table: ${schema.name}',
              );
            }
          }
        } catch (e) {
          Logger.error('Failed to handle table [${schema.name}]', rawError: e);
          rethrow;
        }
      }

      // 3. Handle tables to be deleted
      int tablesDropped = 0;
      for (final tableName in tablesToDrop) {
        try {
          // Skip old names of already processed renamed tables
          if (renamedTables.containsKey(tableName)) {
            continue;
          }

          // Create delete task for tables to be deleted
          final operations = <MigrationOperation>[
            const MigrationOperation(
              type: MigrationType.dropTable,
            ),
          ];

          final tableUid =
              _dataStore.tableMetaManager?.getUidByName(TableName(tableName)) ??
                  TableUid(tableName);
          final task = await addMigrationTask(tableUid, operations,
              startProcessing: false, isAutoGenerated: true);
          if (task != null) {
            allTasks.add(task);
            tablesDropped++;
          }

          if (!SystemTable.isSystemTable(tableName)) {
            Logger.info(
              'Handle table deletion: $tableName',
            );
          }
        } catch (e) {
          Logger.error('Failed to handle table deletion [$tableName]',
              rawError: e);
          rethrow;
        }
      }

      // Start migration task processing
      if (allTasks.isNotEmpty) {
        if (waitForCompletion) {
          Logger.info(
            'Database migration generated ${allTasks.length} migration tasks, starting execution...',
          );
          final migrateResult = await processMigrationTasks();

          if (!migrateResult.success) {
            Logger.error(
              'Some migration tasks failed, please check the log for details',
            );
            if (migrateResult.errors.isNotEmpty) {
              final firstError = migrateResult.errors.first;
              if (firstError is DbException) {
                throw firstError;
              } else {
                throw DbException([
                  GeneralStatus(
                    type: ResultType.engError,
                    message: 'Migration task failed: $firstError',
                  ),
                ]);
              }
            }
            throw DbException([
              GeneralStatus(
                type: ResultType.engError,
                message: 'Some migration tasks failed',
              ),
            ]);
          } else {
            Logger.info(
              'All migration tasks have been successfully completed',
            );
          }
        } else {
          Logger.info(
            'Database migration generated ${allTasks.length} migration tasks, running asynchronously in background.',
          );
          unawaited(processMigrationTasks().catchError((e) {
            if (e is DbClosedException) {
              return MigrationTasksResult(success: false);
            }
            throw e;
          }));
        }
      }

      // Calculate and record total duration
      final endTime = DateTime.now();
      final duration = endTime.difference(startTime);

      Logger.info(
        'Database migration completed:  Renamed tables [${renamedTables.length}], Updated tables [$tablesUpdated], New tables [$tablesCreated], Deleted tables [$tablesDropped], Total duration [${duration.inMilliseconds}ms]',
      );
    } catch (e) {
      Logger.error('Database migration failed', rawError: e);
      rethrow;
    }
  }

  /// Perform global database schema consistency validation before executing migration
  Future<void> _validateGlobalSchemaConsistency({
    required List<TableSchema> targetSchemas,
    required Map<String, String> renamedTableTargets,
    required List<String> existingTables,
  }) async {
    // 1. Check duplicate table names in target schemas
    final seenTableNames = <String>{};
    for (final schema in targetSchemas) {
      if (seenTableNames.contains(schema.name)) {
        throw DbException([
          SchemaValidationStatus(
            type: ResultType.devSchemaTableExists,
            message:
                'Duplicate table name "${schema.name}" found in target schema list.',
            tableName: schema.name,
          ),
        ]);
      }
      seenTableNames.add(schema.name);
    }

    final targetSchemaMap = {for (final s in targetSchemas) s.name: s};

    // 2. Validate cross-table foreign key constraints and other inconsistencies
    for (final schema in targetSchemas) {
      // Validate duplicate foreign key names within the same table
      final seenFkNames = <String>{};
      for (final fk in schema.foreignKeys) {
        final fkName = fk.actualName;
        if (seenFkNames.contains(fkName)) {
          throw DbException([
            SchemaValidationStatus(
              type: ResultType.devInvalidSchemaForeignKey,
              message:
                  'Duplicate foreign key name "$fkName" in table "${schema.name}".',
              tableName: schema.name,
              field: fk.fields.join(','),
              wrongValue: fkName,
            )
          ]);
        }
        seenFkNames.add(fkName);

        if (!fk.enabled) continue;

        final refTableName = fk.referencedTable;

        // Check if referenced table exists in target schemas
        if (!targetSchemaMap.containsKey(refTableName)) {
          // Check if it was renamed but not updated in foreign key config
          if (renamedTableTargets.containsKey(refTableName)) {
            final newName = renamedTableTargets[refTableName];
            throw DbException([
              SchemaValidationStatus(
                type: ResultType.devTableNotFound,
                message:
                    'Foreign key "${fk.actualName}" in table "${schema.name}" references table "$refTableName", '
                    'which has been renamed to "$newName". Please update the foreign key definition in the schema code to reference the new table name.',
                tableName: schema.name,
                field: fk.fields.join(','),
                wrongValue: {
                  'referencedTable': refTableName,
                  'renamedTo': newName,
                },
              )
            ]);
          } else {
            throw DbException([
              SchemaValidationStatus(
                type: ResultType.devTableNotFound,
                message:
                    'Foreign key "${fk.actualName}" in table "${schema.name}" references non-existent table "$refTableName".',
                tableName: schema.name,
                field: fk.fields.join(','),
                wrongValue: refTableName,
              )
            ]);
          }
        }

        // Validate foreign key with referenced table
        final referencedSchema = targetSchemaMap[refTableName]!;
        if (!schema.validateForeignKeyWithReferencedTable(
            fk, referencedSchema)) {
          throw DbException([
            SchemaValidationStatus(
              type: ResultType.devInvalidSchemaForeignKey,
              message:
                  'Invalid foreign key "${fk.actualName}" in table "${schema.name}": '
                  'referenced fields in table "$refTableName" are not compatible or do not exist.',
              tableName: schema.name,
              field: fk.fields.join(','),
              wrongValue: {
                'referencedFields': fk.referencedFields.join(','),
                'referencedTable': refTableName,
              },
            )
          ]);
        }

        // Validate space consistency: Space tables cannot reference Global tables and vice versa
        if (schema.isGlobal != referencedSchema.isGlobal) {
          throw DbException([
            SchemaValidationStatus(
              type: ResultType.devInvalidSchemaSpaceMismatch,
              message:
                  'Space mismatch in foreign key "${fk.actualName}" of table "${schema.name}": '
                  '${schema.name} is ${schema.isGlobal ? "global" : "space-specific"} but '
                  'referenced table $refTableName is ${referencedSchema.isGlobal ? "global" : "space-specific"}. '
                  'Foreign key relationships across global and space boundaries are not allowed.',
              tableName: schema.name,
              field: fk.fields.join(','),
              wrongValue: {
                'tableIsGlobal': schema.isGlobal,
                'referencedTable': refTableName,
                'referencedTableIsGlobal': referencedSchema.isGlobal,
              },
            )
          ]);
        }
      }
    }
  }

  /// Detect renamed tables
  Future<RenamedTableResult> _detectRenamedTables(
      List<String> existingTables, List<TableSchema> newSchemas) async {
    try {
      // Result set
      final renamedTables = <String, TableSchema>{};
      final remainingExistingTables = List<String>.from(existingTables);
      final remainingNewTables = List<TableSchema>.from(newSchemas);

      // 0. First filter out tables with the same name, these do not need renaming matching
      final existingTableNames = Set<String>.from(remainingExistingTables);
      final newTableNames = remainingNewTables.map((s) => s.name).toSet();

      // Find tables with the same name and remove them from the matching list
      final commonTableNames = existingTableNames.intersection(newTableNames);
      if (commonTableNames.isNotEmpty) {
        // Remove tables with the same name from the matching list
        remainingExistingTables
            .removeWhere((name) => commonTableNames.contains(name));
        remainingNewTables
            .removeWhere((schema) => commonTableNames.contains(schema.name));
      }

      // Performance optimization: If after removing tables with the same name, all tables match (i.e., old and new tables are completely consistent), return the result directly
      if (remainingExistingTables.isEmpty && remainingNewTables.isEmpty) {
        return const RenamedTableResult(
          renamedTables: {},
          tablesToCreate: [],
          tablesToDrop: [],
        );
      }

      // 1. First match directly by tableId
      await _detectRenamedTablesByTableId(
          remainingExistingTables, remainingNewTables, renamedTables);

      // 2. Then match by similarity
      if (remainingExistingTables.isNotEmpty && remainingNewTables.isNotEmpty) {
        await _detectRenamedTablesBySimilarity(
            remainingExistingTables, remainingNewTables, renamedTables);
      }

      // 3. Determine tables to be created and to be deleted
      final tablesToCreate = <String>[];
      for (final schema in remainingNewTables) {
        tablesToCreate.add(schema.name);
      }

      final tablesToDrop = List<String>.from(remainingExistingTables);

      // Output detailed results
      if (renamedTables.isNotEmpty) {
        final userRenamedTables = renamedTables.entries
            .where((e) => !SystemTable.isSystemTable(e.key));
        if (userRenamedTables.isNotEmpty) {
          final renameInfo = userRenamedTables
              .map((e) => '${e.key} -> ${e.value.name}')
              .join(', ');
          Logger.info(
            'Final result of table renaming detection: $renameInfo',
          );
        }
      }

      if (tablesToCreate.isNotEmpty) {
        final userTablesToCreate = tablesToCreate
            .where((name) => !SystemTable.isSystemTable(name))
            .toList();
        if (userTablesToCreate.isNotEmpty) {
          Logger.info(
            'Tables to be created: ${userTablesToCreate.join(', ')}',
          );
        }
      }

      if (tablesToDrop.isNotEmpty) {
        final userTablesToDrop = tablesToDrop
            .where((name) => !SystemTable.isSystemTable(name))
            .toList();
        if (userTablesToDrop.isNotEmpty) {
          Logger.info(
            'Tables to be deleted: ${userTablesToDrop.join(', ')}',
          );
        }
      }

      return RenamedTableResult(
        renamedTables: renamedTables,
        tablesToCreate: tablesToCreate,
        tablesToDrop: tablesToDrop,
      );
    } catch (e) {
      Logger.error('Error occurred during table renaming detection',
          rawError: e);

      // Return empty result in case of error to avoid misjudgment
      return const RenamedTableResult(
        renamedTables: {},
        tablesToCreate: [],
        tablesToDrop: [],
      );
    }
  }

  /// Detect renamed tables by tableId
  Future<void> _detectRenamedTablesByTableId(
      List<String> existingTables,
      List<TableSchema> newSchemas,
      Map<String, TableSchema> renamedTables) async {
    final matchedExistingTables = <String>{};
    final matchedNewSchemas = <TableSchema>{};

    for (final newSchema in newSchemas) {
      // Only process tables with tableId set
      if (newSchema.tableId == null) continue;

      for (final existingTableName in existingTables) {
        // Skip tables with the same name, these don't need to be identified as renamed
        if (existingTableName == newSchema.name) continue;

        final existingSchema = await _dataStore.tableMetaManager
            ?.getTableSchemaByName(TableName(existingTableName));
        if (existingSchema == null) continue;

        // Check if tableId matches
        if (existingSchema.tableId != null &&
            existingSchema.tableId == newSchema.tableId &&
            existingTableName != newSchema.name) {
          // Record renamed table
          renamedTables[existingTableName] = newSchema;
          matchedExistingTables.add(existingTableName);
          matchedNewSchemas.add(newSchema);

          break;
        }
      }
    }

    // Remove matched tables
    existingTables
        .removeWhere((table) => matchedExistingTables.contains(table));
    newSchemas.removeWhere((schema) => matchedNewSchemas.contains(schema));
  }

  /// Detect renamed tables by similarity
  Future<void> _detectRenamedTablesBySimilarity(
      List<String> existingTables,
      List<TableSchema> newSchemas,
      Map<String, TableSchema> renamedTables) async {
    try {
      // Similarity threshold, above which tables are considered the same
      const similarityThreshold = 0.75;

      // prepare parallel calculation requests
      final similarityRequests = <TableSimilarityRequest>[];
      final existingSchemasMap = <String, TableSchema>{};

      // get all old table schemas
      for (final existingTableName in existingTables) {
        final existingSchema = await _dataStore.tableMetaManager
            ?.getTableSchemaByName(TableName(existingTableName));
        if (existingSchema == null) continue;
        existingSchemasMap[existingTableName] = existingSchema;
      }

      // build all similarity requests
      for (final existingTableName in existingSchemasMap.keys) {
        final existingSchema = existingSchemasMap[existingTableName]!;

        for (final newSchema in newSchemas) {
          // skip tables with the same name, these should not be identified as renamed tables
          if (existingTableName == newSchema.name) {
            continue;
          }

          similarityRequests.add(TableSimilarityRequest(
            oldSchema: existingSchema,
            newSchema: newSchema,
            oldTableIndex: existingTables.indexOf(existingTableName),
            newTableIndex: newSchemas.indexOf(newSchema),
            oldTablesCount: existingTables.length,
            newTablesCount: newSchemas.length,
          ));
        }
      }

      // if no requests to process, return
      if (similarityRequests.isEmpty) {
        return;
      }

      // max concurrent
      final maxConcurrent = _dataStore.config.maxConcurrency;

      // batch processing requests
      final int batchSize = (similarityRequests.length / maxConcurrent).ceil();
      final batches = <List<TableSimilarityRequest>>[];

      for (int i = 0; i < similarityRequests.length; i += batchSize) {
        final end = min(i + batchSize, similarityRequests.length);
        batches.add(similarityRequests.sublist(i, end));
      }

      // parallel processing all batches
      final batchResults =
          await Future.wait(batches.map((batch) => ComputeManager.run(
                ComputeTask(
                  function: calculateBatchTableSimilarity,
                  message: BatchTableSimilarityRequest(requests: batch),
                ),
                useIsolate: similarityRequests.length > 20,
              )));

      // merge all results
      final allResults = <TableSimilarityResult>[];
      for (final batchResult in batchResults) {
        allResults.addAll(batchResult.results);
      }

      // sort results by similarity
      allResults.sort((a, b) => b.similarity.compareTo(a.similarity));

      // greedy matching algorithm
      final processedOldTables = <String>{};
      final processedNewSchemas = <TableSchema>{};

      for (final result in allResults) {
        // if table is already processed, skip
        if (processedOldTables.contains(result.oldTableName) ||
            processedNewSchemas.contains(result.newSchema)) {
          continue;
        }

        // if best match is above threshold, consider as renamed table
        if (result.similarity >= similarityThreshold) {
          // additional check: even with high similarity, tables with the same name should not be considered renamed
          if (result.oldTableName == result.newSchema.name) {
            continue;
          }

          // add to renamed results
          renamedTables[result.oldTableName] = result.newSchema;

          // record processed tables
          processedOldTables.add(result.oldTableName);
          processedNewSchemas.add(result.newSchema);

          // remove from remaining lists
          existingTables.remove(result.oldTableName);
          newSchemas.remove(result.newSchema);
        } else {
          // if similarity is not high enough, break
          break;
        }
      }
    } catch (e) {
      Logger.error('Error during parallel table similarity detection',
          rawError: e);
    }
  }

  /// Migrate existing table schema
  Future<MigrationTask?> _migrateExistingTable(
    TableSchema newSchema, {
    required int batchSize,
    Map<String, String> renamedTableTargets = const {},
  }) async {
    final tableName = newSchema.name;
    final tableUid = newSchema.tableUid.isNotEmpty
        ? TableUid(newSchema.tableUid)
        : (_dataStore.tableMetaManager?.getUidByName(TableName(tableName)) ??
            TableUid(tableName));
    final oldSchema =
        await _dataStore.tableMetaManager?.getTableSchema(tableUid);
    if (oldSchema == null) {
      return null;
    }

    // Compare schemas and generate operations
    final operations = await _compareSchemasAndGenerateOperations(
      oldSchema,
      newSchema,
      renamedTableTargets: renamedTableTargets,
    );

    if (operations.isEmpty) {
      return null;
    } else {
      if (!SystemTable.isSystemTable(tableName)) {
        Logger.info(
          'Found ${operations.length} changes for table $tableName',
        );
      }
    }

    // Additional schema diff tasks coalesce in addMigrationTask when data migration
    // has not started yet.
    final existingTaskIds =
        await _findUnfinishedSchemaTaskIdsForTableUid(tableUid);
    if (existingTaskIds.isNotEmpty) {
      Logger.info(
        'Table [$tableName] has ${existingTaskIds.length} unfinished schema migration task(s); '
        'new changes will coalesce when background rewrite has not started',
      );
    }

    final task = await addMigrationTask(
      tableUid,
      operations,
      startProcessing: false,
      isAutoGenerated: true,
      targetSchemaSnapshot: newSchema,
    );
    return task;
  }

  /// Add migration task for table schema update across all spaces.
  ///
  /// Returns `null` when every operation is already satisfied by the effective
  /// schema (idempotent no-op). This is common for auto-generated startup
  /// migrations after a crash/restart.
  Future<MigrationTask?> addMigrationTask(
      TableUid tableUid, List<MigrationOperation> operations,
      {bool isAutoGenerated = false,
      bool startProcessing = true,
      bool allowAfterDataMigration = false,
      TableSchema? targetSchemaSnapshot,
      MigrationWriteMode? writeMode,
      List<IndexUid>? specificIndexUids}) async {
    final latestPending = _findLatestPendingTaskForTableUid(tableUid);
    final oldSchema = latestPending != null
        ? latestPending.targetSchemaSnapshot
        : await _dataStore.tableMetaManager?.getTableSchema(tableUid);

    TableSchema? targetSchema = targetSchemaSnapshot;
    if (targetSchema != null) {
      // Snapshot is already sanitized at migrate/create boundaries.
      // Runtime updateSchema does not pass a snapshot.
      // schemaVersion bumps only when a migration task is added.
      targetSchema = targetSchema
          .copyWith(
            tableUid: tableUid,
            schemaVersion: GlobalIdGenerator.generate("s"),
          )
          .generateAutoIndexes(oldSchema: oldSchema);
    }

    final tableDisplayName = await _resolveTableDisplayName(
      tableUid,
      schemaHint: targetSchema,
    );

    final tableLockResource = _tableLockResource(tableUid);
    final tableLockOpId = GlobalIdGenerator.generate('add_migration_');
    final lockMgr = _dataStore.lockManager;
    if (lockMgr != null) {
      final locked = await lockMgr.acquireExclusiveLock(
        tableLockResource,
        tableLockOpId,
      );
      if (!locked) {
        throw DbException([
          GeneralStatus(
            type: ResultType.sysTimeoutLockAcquisition,
            message:
                'Timed out waiting to add schema migration task for table [$tableDisplayName]. '
                'Another schema change or write may be in progress on this table.',
          ),
        ]);
      }
    }
    try {
      var sortedOperations =
          _sortOperations(List<MigrationOperation>.from(operations));
      final renameOp = _findRenameOperation(sortedOperations);

      final tableName =
          oldSchema?.name ?? targetSchema?.name ?? tableDisplayName;

      if (sortedOperations.isEmpty) {
        throw DbException([
          InvalidArgumentStatus(
            type: ResultType.devInvalidArgumentMissing,
            message:
                "Failed to add migration task for table '$tableName' because no schema operations were provided. "
                "If you are updating the schema programmatically, please ensure at least one operation (such as addField, renameField, or alterField) "
                "is added to the operation list before executing the migration.",
            parameterName: 'operations',
            passedValue: operations,
          ),
        ]);
      }

      final isDropTable =
          sortedOperations.any((op) => op.type == MigrationType.dropTable);
      if (oldSchema != null && !isDropTable) {
        final indexTableCtx = await _requireTableContext(tableName);
        sortedOperations = await _foldRedundantMigrationOperations(
          effectiveSchema: oldSchema,
          operations: sortedOperations,
          tableUid: tableUid,
          table: indexTableCtx,
          tableName: tableName,
          isAutoGenerated: isAutoGenerated,
          declaredTargetSchema: targetSchema,
        );
        if (sortedOperations.isEmpty) {
          return null;
        }
      }

      final targetTableName = renameOp?.newTableName ?? tableName;

      FieldStorageLayout? oldFieldLayout;
      if (latestPending != null) {
        final prevLayout = latestPending.oldFieldLayoutSnapshot;
        if (prevLayout != null && latestPending.targetSchemaSnapshot != null) {
          final renameHints = _buildFieldRenameHints(latestPending.operations);
          oldFieldLayout =
              _dataStore.tableMetaManager?.evolveFieldStorageLayout(
            existingLayout: prevLayout,
            nextSchema: latestPending.targetSchemaSnapshot!,
            renameHints: renameHints,
          );
        }
      } else {
        oldFieldLayout = oldSchema != null
            ? await _dataStore.tableMetaManager
                ?.getTableFieldLayout(tableUid, schema: oldSchema)
            : null;
      }

      if (oldSchema == null) {
        // If it's not a system auto-migration and the table doesn't exist, it's an error for updateSchema
        if (!isAutoGenerated) {
          throw DbException([
            SchemaValidationStatus(
              type: ResultType.devTableNotFound,
              message:
                  'Table [$tableName] does not exist. updateSchema can only be used to modify existing tables.',
              tableName: tableName,
            )
          ]);
        }
      } else {
        if (!isDropTable) {
          // Runtime updateSchema: validate ops against effective schema.
          // Auto-generated startup migrations rely on declarative [targetSchema]
          // validation plus [_foldRedundantMigrationOperations] idempotency instead.
          if (!isAutoGenerated) {
            for (final op in sortedOperations) {
              switch (op.type) {
                case MigrationType.addField:
                  final field = op.field;
                  if (field != null &&
                      oldSchema.fields.any((f) => f.name == field.name)) {
                    throw DbException([
                      SchemaValidationStatus(
                        type: ResultType.devSchemaFieldExists,
                        message:
                            'Cannot add field [${field.name}] to table [$tableName]: field already exists.',
                        tableName: tableName,
                        field: field.name,
                      )
                    ]);
                  }
                  break;
                case MigrationType.removeField:
                case MigrationType.renameField:
                case MigrationType.modifyField:
                  final fieldName = op.fieldName ?? op.fieldUpdate?.name;
                  if (fieldName != null &&
                      !oldSchema.fields.any((f) => f.name == fieldName)) {
                    throw DbException([
                      SchemaValidationStatus(
                        type: ResultType.devInvalidSchemaFieldName,
                        message:
                            'Cannot ${op.type.name} field [$fieldName] in table [$tableName]: field does not exist.',
                        tableName: tableName,
                        field: fieldName,
                      )
                    ]);
                  }
                  break;
                default:
                  break;
              }
            }
          }

          // Validate the declarative target structure (duplicate names, reserved
          // words, etc.) regardless of migration source.
          if (targetSchema == null) {
            targetSchema = _predictTargetSchema(
              oldSchema,
              sortedOperations,
              isAutoGenerated: isAutoGenerated,
            );
            // Inherit engine fields from oldSchema; only bump schemaVersion.
            targetSchema = targetSchema
                .copyWith(
                  tableUid: tableUid,
                  schemaVersion: GlobalIdGenerator.generate("s"),
                )
                .generateAutoIndexes(oldSchema: oldSchema);
          }
          final reservedSystemTableNames = SystemTable.systemTableNames;
          final allowSystemSchema = targetSchema.isSystemTable;
          targetSchema.validateTableSchema(
            reservedTableNames: reservedSystemTableNames,
            allowReservedTableNames: allowSystemSchema,
            allowInternalTableNamePrefix: allowSystemSchema,
            allowOtherInternalFields: allowSystemSchema,
          );

          // 3. For runtime manual migrations, validate new foreign key constraints
          if (!isAutoGenerated) {
            for (final fk in targetSchema.foreignKeys) {
              if (!fk.enabled) continue;

              final referencedSchema = await _dataStore.tableMetaManager
                  ?.getTableSchemaByName(TableName(fk.referencedTable));
              if (referencedSchema == null) {
                throw DbException([
                  SchemaValidationStatus(
                    type: ResultType.devTableNotFound,
                    message:
                        'Cannot upgrade table $tableName: Referenced table "${fk.referencedTable}" does not exist for foreign key "${fk.actualName}".',
                    tableName: tableName,
                    field: fk.fields.join(','),
                    wrongValue: fk.referencedTable,
                  )
                ]);
              }

              if (targetSchema.isGlobal != referencedSchema.isGlobal) {
                throw DbException([
                  SchemaValidationStatus(
                    type: ResultType.devInvalidSchemaSpaceMismatch,
                    message:
                        'Space mismatch in foreign key "${fk.actualName}" of table "${targetSchema.name}": '
                        '${targetSchema.name} is ${targetSchema.isGlobal ? "global" : "space-specific"} but '
                        'referenced table ${fk.referencedTable} is ${referencedSchema.isGlobal ? "global" : "space-specific"}. '
                        'Foreign key relationships across global and space boundaries are not allowed.',
                    tableName: targetSchema.name,
                    field: fk.fields.join(','),
                    wrongValue: {
                      'tableIsGlobal': targetSchema.isGlobal,
                      'referencedTable': fk.referencedTable,
                      'referencedTableIsGlobal': referencedSchema.isGlobal,
                    },
                  )
                ]);
              }

              if (!targetSchema.validateForeignKeyWithReferencedTable(
                  fk, referencedSchema)) {
                throw DbException([
                  SchemaValidationStatus(
                    type: ResultType.devInvalidSchemaForeignKey,
                    message:
                        'Invalid foreign key "${fk.actualName}" in table "${targetSchema.name}": '
                        'referenced fields in table "${fk.referencedTable}" are not compatible or do not exist.',
                    tableName: targetSchema.name,
                    field: fk.fields.join(','),
                    wrongValue: {
                      'referencedFields': fk.referencedFields.join(','),
                      'referencedTable': fk.referencedTable,
                    },
                  )
                ]);
              }
            }
          }

          // Only check for existing tables
          bool isAllowed = false;
          if (allowAfterDataMigration) {
            isAllowed = true;
          } else if (isAutoGenerated) {
            final allowedTables = _dataStore
                    .config.migrationConfig?.allowedAfterDataMigrationTables ??
                [];
            if (allowedTables.contains(tableName)) {
              isAllowed = true;
            }
          }

          final requiresMigration = await _requiresDataMigration(
              sortedOperations, oldSchema,
              targetSchema: targetSchema, isAllowed: isAllowed);

          if (requiresMigration) {
            if (!isAllowed) {
              final tableCtx = await _requireTableContext(tableName);
              final recordCount = await _dataStore.tableDataManager
                  .getTableRecordCount(tableCtx);
              if (recordCount != 0) {
                throw DbException([
                  SchemaValidationStatus(
                    type: ResultType.devMigrationNotAllowedWithData,
                    message:
                        'Migration for table "$tableName" requires data modification and was not explicitly allowed. '
                        'This is to prevent accidental data loss or long-running migrations. \n'
                        'For changes during app startup, add the table name to `MigrationConfig.allowedAfterDataMigrationTables`. \n'
                        'For changes via SchemaBuilder, use the `.allowAfterDataMigration()` method before calling `.future`.',
                    tableName: tableName,
                  )
                ]);
              }
            }
          }
        }
      }
      // Calculate table write requirement once
      final needsTableWrite = _needDataMigration(sortedOperations, oldSchema);

      // create new migration task
      final taskId = DateTime.now().microsecondsSinceEpoch.toString();
      final dirIndex = await _getNextDirIndex();
      final spaces = await _getMigrationScopesForSchema(
        targetSchema ?? oldSchema,
      );
      final cutoverPointer = _dataStore.walManager.currentPointer;

      final childIndexesToDrop = <TableUid, List<IndexUid>>{};

      var task = MigrationTask(
        taskId: taskId,
        tableUid: tableUid,
        isSchemaUpdated: false,
        pendingMigrationSpaces: spaces,
        operations: sortedOperations,
        createTime: DateTime.now(),
        dirIndex: dirIndex,
        isAutoGenerated: isAutoGenerated,
        oldSchemaSnapshot: oldSchema,
        targetSchemaSnapshot: targetSchema,
        oldFieldLayoutSnapshot: oldFieldLayout,
        schemaCutoverWalPointer: cutoverPointer,
        writeMode: writeMode,
        specificIndexUids: specificIndexUids,
        referencingChildIndexesToDrop: childIndexesToDrop,
      );

      // Schema metadata update is performed synchronously to ensure that subsequent operations
      // can immediately use the new schema. Data migration remains asynchronous.
      if (!task.isSchemaUpdated && task.targetSchemaSnapshot != null) {
        await TransactionContext.runAsSystemOperation(() async {
          await executeSchemaOperations(
            await _requireTableContext(tableName),
            sortedOperations,
            targetSchema: task.targetSchemaSnapshot!,
            tableLockHeldExternally: true,
            outDroppedChildIndexes: childIndexesToDrop,
          );
        });
        task = task.copyWith(
          isSchemaUpdated: true,
          referencingChildIndexesToDrop:
              childIndexesToDrop.isNotEmpty ? childIndexesToDrop : null,
        );
      }

      task = await _maybeEnableDeletedSlotCompaction(task, sortedOperations);

      // Pre-calculate MigrationWriteMode and specificIndexUids upfront if not provided
      if (task.writeMode == null || task.specificIndexUids == null) {
        final calcOldSchema = task.oldSchemaSnapshot ?? oldSchema;
        final calcTargetSchema = task.targetSchemaSnapshot ?? targetSchema;
        final currentNeedsTableWrite =
            task.forceDataMigration || needsTableWrite;
        final indexesToBuild = _calculateBuildingIndexes(
          oldSchema: calcOldSchema,
          targetSchema: calcTargetSchema,
          sortedOperations: sortedOperations,
          table: await _requireTableContext(
              task.currentTableName ?? targetTableName),
        );

        final derivedWriteMode = task.writeMode ??
            (currentNeedsTableWrite
                ? (indexesToBuild.isNotEmpty
                    ? MigrationWriteMode.tableAndIndex
                    : MigrationWriteMode.tableOnly)
                : (indexesToBuild.isNotEmpty
                    ? MigrationWriteMode.indexOnly
                    : MigrationWriteMode.none));
        final derivedSpecificIndexes = task.specificIndexUids ?? indexesToBuild;

        task = task.copyWith(
          writeMode: derivedWriteMode,
          specificIndexUids: derivedSpecificIndexes,
        );
      }

      // Calculate and set estimateDuration
      if (task.estimateDuration == null) {
        final physicalTableName = task.currentTableName ?? targetTableName;
        final physicalTableCtx = await _requireTableContext(physicalTableName);
        final recordCount = await _dataStore.tableDataManager
            .getTableRecordCount(physicalTableCtx);
        final derivedWriteMode = task.writeMode ?? MigrationWriteMode.none;
        final duration =
            _estimateMigrationDuration(derivedWriteMode, recordCount);
        task = task.copyWith(
          estimateDuration: duration,
        );
      }

      // For the active space, immediately set `isBuilding = true` for target indexes
      if (task.specificIndexUids != null &&
          task.specificIndexUids!.isNotEmpty) {
        final currentSchema = task.targetSchemaSnapshot ?? targetSchema;
        if (currentSchema != null) {
          final indexTableCtx = await _requireTableContext(
              task.currentTableName ?? targetTableName);
          final allIndexes = <IndexSchema>[
            ...currentSchema.getAllIndexes(),
            ...?_dataStore.indexManager
                ?.getEngineManagedBtreeIndexes(indexTableCtx, currentSchema),
          ];
          for (final indexField in task.specificIndexUids!) {
            final idxSchema = _resolveSpecificIndexSchema(
              allIndexes,
              indexField,
            );
            final indexUid = idxSchema.indexUid;
            await _dataStore.indexManager?.deletePhysicalIndexArtifacts(
              indexTableCtx,
              indexUid,
            );
            final indexMeta = IndexMeta.createEmpty(
              indexUid: indexUid,
              tableUid: indexTableCtx.tableUid,
              isUnique: idxSchema.unique,
              isBuilding: true,
            );
            await _dataStore.indexManager?.updateIndexMeta(
              table: indexTableCtx,
              indexUid: indexUid,
              updatedMeta: indexMeta,
            );
          }
        }
      }

      // persist migration task
      await _saveMigrationTask(task);
      _updatePendingTaskInMemory(task);
      _pendingTasks.add(task);

      // Reconcile pending tasks for the table to merge or cancel redundant ops
      await _reconcilePendingTasksForTable(
          await _requireTableContext(tableName));

      await syncHasMigrationTask();

      final needDataMigration = task.forceDataMigration || needsTableWrite;

      await _invalidatePrimaryInstanceCachesForMigration(
        originalTableName: tableName,
        currentTableName: task.currentTableName ?? targetTableName,
        operations: sortedOperations,
        renameOp: renameOp,
        needDataMigration: needDataMigration,
      );
      _registerRuntimeMigration(task);

      if (task.oldSchemaSnapshot != null) {
        registerSchemaVersion(task.oldSchemaSnapshot!);
      }
      if (task.targetSchemaSnapshot != null) {
        registerSchemaVersion(task.targetSchemaSnapshot!);
      }

      // only trigger task processing when startProcessing is true
      if (startProcessing) {
        unawaited(processMigrationTasks().catchError((e) {
          if (e is DbClosedException) {
            return MigrationTasksResult(success: false);
          }
          throw e;
        }));
      }

      return task;
    } catch (e) {
      if (e is! DbClosedException) {
        Logger.error('Add migration task failed', rawError: e);
      }
      rethrow;
    } finally {
      lockMgr?.releaseExclusiveLock(tableLockResource, tableLockOpId);
    }
  }

  MigrationTask? _findLatestPendingTaskForTableUid(TableUid tableUid) {
    MigrationTask? latest;
    for (final task in _pendingTasks) {
      if (task.tableUid == tableUid) {
        if (latest == null || task.createTime.isAfter(latest.createTime)) {
          latest = task;
        }
      }
    }
    return latest;
  }

  /// Wait for a specific migration task to complete (either currently executing or in queue).
  Future<void> waitForTaskCompletion(
    String taskId, {
    void Function(double progress)? onProgress,
  }) async {
    if (onProgress != null) {
      _activeTaskProgressCallback = onProgress;
    }

    // Wait until the task is no longer pending and no longer executing.
    while (_pendingTasks.any((t) => t.taskId == taskId) ||
        _activeExecutingTaskId == taskId) {
      if (_activeExecutingTaskId == taskId && _activeTaskFuture != null) {
        // Directly await the running future zero-polling, event-driven.
        try {
          await _activeTaskFuture;
        } catch (_) {
          // Ignore task failure during wait; let the caller of migrate() surface the error.
        }
      } else {
        // Task is still queued, waiting for its turn in the serial channel.
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }
  }

  bool _taskMatchesTable(
      MigrationTask task, TableContext table, String targetTableName) {
    final currentName = task.currentTableName ??
        _resolveCurrentTableNameFromName(task.tableName, task.operations);
    return task.tableUid == table.tableUid ||
        task.tableName == table.tableName ||
        task.tableName == targetTableName ||
        currentName == table.tableName ||
        currentName == targetTableName;
  }

  void _registerRuntimeMigration(MigrationTask task) {
    _rebuildRuntimeMigrations(TableUid(task.tableUid));
  }

  List<FieldStructure> _buildFieldStructureFromLayout(
    FieldStorageLayout layout,
  ) {
    if (layout.slots.isEmpty) {
      return const <FieldStructure>[];
    }
    final out = <FieldStructure>[];
    for (final slot in layout.slots) {
      final fieldName = slot.deleted
          ? '$_deletedSlotFieldPrefix${slot.slotId}'
          : slot.fieldName;
      out.add(FieldStructure(name: fieldName, typeIndex: slot.typeIndex));
    }
    return List<FieldStructure>.unmodifiable(out);
  }

  void _unregisterRuntimeMigrationForTask(MigrationTask task) {
    _rebuildRuntimeMigrations(TableUid(task.tableUid));
  }

  Set<String> _taskRuntimeAliases(MigrationTask task) {
    final aliases = <String>{task.tableName};
    final current = task.currentTableName ??
        _resolveCurrentTableNameFromName(task.tableName, task.operations);
    aliases.add(current);
    return aliases;
  }

  List<MigrationTask> _collectLinkedPendingTasks(
    List<MigrationTask> source,
    MigrationTask seed,
  ) {
    final linked = <MigrationTask>[];
    final aliasSet = _taskRuntimeAliases(seed);
    var changed = true;

    while (changed) {
      changed = false;
      for (final task in source) {
        if (linked.contains(task)) continue;
        final aliases = _taskRuntimeAliases(task);
        var intersects = false;
        for (final alias in aliases) {
          if (aliasSet.contains(alias)) {
            intersects = true;
            break;
          }
        }
        if (!intersects) continue;
        linked.add(task);
        aliasSet.addAll(aliases);
        changed = true;
      }
    }

    return linked;
  }

  _RuntimeMigrationDescriptor? _buildRuntimeDescriptorForComponent(
    List<MigrationTask> tasks,
  ) {
    if (tasks.isEmpty) return null;

    tasks.sort((a, b) {
      final c = a.createTime.compareTo(b.createTime);
      if (c != 0) return c;
      return a.taskId.compareTo(b.taskId);
    });

    MigrationTask? oldestWithSnapshot;
    for (final task in tasks) {
      if (task.oldSchemaSnapshot != null) {
        oldestWithSnapshot = task;
        break;
      }
    }
    if (oldestWithSnapshot == null) {
      return null;
    }

    final oldSchema = oldestWithSnapshot.oldSchemaSnapshot!;
    final aliases = <String>{};
    final operations = <MigrationOperation>[];
    var needBridge = false;

    for (final task in tasks) {
      aliases.addAll(_taskRuntimeAliases(task));
      final schemaForNeed = task.oldSchemaSnapshot ?? oldSchema;
      if (task.forceDataMigration ||
          _needRuntimeRecordBridge(task.operations, schemaForNeed)) {
        needBridge = true;
      }
      operations.addAll(
          _sortOperations(List<MigrationOperation>.from(task.operations)));
    }

    if (!needBridge) {
      return null;
    }

    final oldFieldStruct = oldestWithSnapshot.oldFieldLayoutSnapshot != null
        ? _buildFieldStructureFromLayout(
            oldestWithSnapshot.oldFieldLayoutSnapshot!)
        : oldSchema.fields
            .map((f) => FieldStructure(name: f.name, typeIndex: f.type.index))
            .toList(growable: false);

    final latest = tasks.last;

    final currentSpaceName = _dataStore.currentSpaceName;
    Uint8List? checkpointKey;
    for (final task in tasks) {
      final checkpointScope =
          task.pendingMigrationSpaces.contains(_globalMigrationScope)
              ? _globalMigrationScope
              : currentSpaceName;
      final encoded = task.checkpointKeyForSpace(checkpointScope);
      if (encoded == null || encoded.isEmpty) {
        continue;
      }
      try {
        checkpointKey = Uint8List.fromList(base64Decode(encoded));
      } catch (_) {
        checkpointKey = null;
      }
      break;
    }

    return _RuntimeMigrationDescriptor(
      taskId: latest.taskId,
      tableUid: TableUid(latest.tableUid),
      oldSchema: oldSchema,
      operations: operations,
      oldFieldStruct: oldFieldStruct,
      cutoverPointer: oldestWithSnapshot.schemaCutoverWalPointer,
      currentSpaceCheckpointKey: checkpointKey,
      tableAliases: Set<String>.unmodifiable(aliases),
    );
  }

  void _rebuildRuntimeMigrations([TableUid? affectedTableUid]) {
    final currentSpaceName = _dataStore.currentSpaceName;
    final pending = <MigrationTask>[
      for (final task in _pendingTasks)
        if (task.pendingMigrationSpaces.contains(currentSpaceName) ||
            task.pendingMigrationSpaces.contains(_globalMigrationScope))
          task,
    ];

    if (affectedTableUid == null) {
      _runtimeMigrations.clear();
      if (pending.isEmpty) {
        return;
      }

      final visitedTaskIds = <String>{};
      for (final seed in pending) {
        if (visitedTaskIds.contains(seed.taskId)) continue;
        final component = _collectLinkedPendingTasks(pending, seed);
        for (final task in component) {
          visitedTaskIds.add(task.taskId);
        }
        final descriptor = _buildRuntimeDescriptorForComponent(component);
        if (descriptor == null) continue;
        _runtimeMigrations[descriptor.tableUid] = descriptor;
      }
    } else {
      // Incremental rebuild for a specific table component
      MigrationTask? seed;
      for (final task in pending) {
        if (task.tableUid == affectedTableUid) {
          seed = task;
          break;
        }
      }

      // If no task found for this table, remove any existing descriptor
      if (seed == null) {
        _runtimeMigrations.remove(affectedTableUid);
        return;
      }

      // Collect component and rebuild
      final component = _collectLinkedPendingTasks(pending, seed);
      final descriptor = _buildRuntimeDescriptorForComponent(component);

      // Remove old descriptor for this table uid
      _runtimeMigrations.remove(affectedTableUid);

      // Add new descriptor
      if (descriptor != null) {
        _runtimeMigrations[descriptor.tableUid] = descriptor;
      }
    }
  }

  Map<String, dynamic>? decodeLegacyRecordForReadSync(
    TableContext table,
    Uint8List encodedRecord,
  ) {
    final descriptor = _findRuntimeMigrationDescriptor(table);
    if (descriptor == null) {
      return null;
    }
    final decoded = BinarySchemaCodec.decodeRecord(
      encodedRecord,
      descriptor.oldFieldStruct,
    );
    if (decoded == null) {
      return null;
    }
    return applyMigrationOperationsSync(
      decoded,
      descriptor.operations,
      descriptor.oldSchema,
    );
  }

  /// Execute operations - only handle logical table structure updates.
  ///
  /// This is the synchronous cutover phase. It must stay cheap: persist the
  /// target schema and the minimum path metadata needed for the active scope.
  /// Physical index work and per-space data/layout migration are performed by
  /// [_executeMigrationTask].
  Future<String> executeSchemaOperations(
    TableContext table,
    List<MigrationOperation> operations, {
    required TableSchema targetSchema,
    bool tableLockHeldExternally = false,
    Map<TableUid, List<IndexUid>>? outDroppedChildIndexes,
  }) async {
    final tableName = table.tableName;
    final renameOp = _findRenameOperation(operations);
    final lockMgr = _dataStore.lockManager;
    final tableLockResource = _tableLockResource(table.tableUid);
    final acquiredLocks = <String, String>{};
    if (!tableLockHeldExternally && lockMgr != null) {
      final opId = GlobalIdGenerator.generate('schema_cutover_');
      final locked = await lockMgr.acquireExclusiveLock(
        tableLockResource,
        opId,
      );
      if (!locked) {
        throw DbException([
          GeneralStatus(
            type: ResultType.sysTimeoutLockAcquisition,
            message:
                'Failed to acquire schema cutover lock for table [${table.tableName}]',
          ),
        ]);
      }
      acquiredLocks[tableLockResource] = opId;
    }

    final currentSpace = _dataStore.currentSpaceName;
    bool keyMigrating = false;
    bool backgroundPaused = false;

    try {
      // 1. Pause background tasks to isolate schema cutover
      await LargeOperationRunner.pauseAndAwait(currentSpace);
      backgroundPaused = true;

      keyMigrating = KeyMigrationRunner.isTableMigrating(table);
      if (keyMigrating) {
        await _dataStore.keyManager.pauseKeyMigration();
      }

      // 2. Clear pending background write scheduler entries for this table
      await _dataStore.backgroundWriteScheduler
          .clearEntriesForTable(table, BackgroundWriteType.largeUpdate);
      await _dataStore.backgroundWriteScheduler
          .clearEntriesForTable(table, BackgroundWriteType.largeDelete);
      await _dataStore.backgroundWriteScheduler
          .clearEntriesForTable(table, BackgroundWriteType.keyMigration);

      final currentTableName = targetSchema.name;
      final fieldRenameHints = _buildFieldRenameHints(operations);
      final isTableRename = renameOp != null &&
          renameOp.newTableName != null &&
          tableName != currentTableName;

      final tableUid = targetSchema.tableUid.isNotEmpty
          ? targetSchema.tableUid
          : table.tableUid;
      final schemaToSave = targetSchema;

      final tableForSave = TableContext(
        tableUid: TableUid(tableUid),
        tableName: TableName(currentTableName),
        isGlobal: targetSchema.isGlobal,
        dataDirIndex: table.dataDirIndex,
        schema: schemaToSave,
      );

      await _dataStore.tableMetaManager?.saveTableSchema(
        tableForSave,
        schemaToSave,
        fieldRenameHints: fieldRenameHints,
      );

      await _syncReferencingForeignKeysMetadata(
        tableForSave,
        targetSchema: schemaToSave,
        operations: operations,
        outDroppedChildIndexes: outDroppedChildIndexes,
      );

      if (isTableRename) {
        await _dataStore.applyTableRenameSideEffects(
          oldTableName: tableName,
          newTableName: currentTableName,
        );
      }

      final fkManager = _dataStore.foreignKeyManager;
      await fkManager?.updateSystemTableForTable(
        tableForSave,
        targetSchema,
      );

      if (isTableRename) {
        await _dataStore.cacheManager.invalidateCache(table);
        await _dataStore.cacheManager.invalidateCache(
          tableForSave,
          invalidateSchema: true,
        );
      }
      return currentTableName;
    } finally {
      if (backgroundPaused) {
        unawaited(LargeOperationRunner.runPendingOperations(_dataStore)
            .catchError((_) {}, test: (e) => e is DbClosedException));
      }
      if (keyMigrating) {
        unawaited(_dataStore.keyManager
            .startDeferredKeyMigrationWork()
            .catchError((_) {}, test: (e) => e is DbClosedException));
      }
      if (lockMgr != null) {
        for (final entry in acquiredLocks.entries.toList().reversed) {
          lockMgr.releaseExclusiveLock(entry.key, entry.value);
        }
      }
    }
  }

  Map<String, String> _buildFieldRenameHints(
    List<MigrationOperation> operations,
  ) {
    // oldFieldName -> newFieldName (matches evolveFieldStorageLayout lookup)
    final hints = <String, String>{};
    for (final operation in operations) {
      if (operation.type == MigrationType.renameField &&
          operation.fieldName != null &&
          operation.newName != null) {
        hints[operation.fieldName!] = operation.newName!;
      }
    }
    return hints;
  }

  MigrationOperation? _findRenameOperation(
      List<MigrationOperation> operations) {
    for (final operation in operations) {
      if (operation.type == MigrationType.renameTable) {
        return operation;
      }
    }
    return null;
  }

  String resolveCurrentTableName(
      TableContext table, List<MigrationOperation> operations) {
    return _resolveCurrentTableName(table, operations);
  }

  String _resolveCurrentTableName(
      TableContext table, List<MigrationOperation> operations) {
    return _resolveCurrentTableNameFromName(table.tableName, operations);
  }

  /// Asynchronously clean up a migration backup file or directory
  void _cleanupMigrationBackup(String backupPath) {
    unawaited(() async {
      try {
        final isDir = await _dataStore.storage.existsDirectory(backupPath);
        final isFile =
            !isDir && await _dataStore.storage.existsFile(backupPath);

        if (isDir) {
          await _dataStore.storage.deleteDirectory(backupPath);
        } else if (isFile) {
          await _dataStore.storage.deleteFile(backupPath);
        }

        Logger.info('Cleaned up migration backup: $backupPath');
      } catch (e) {
        if (e is DbClosedException) return;
        // Just log warning, backup cleanup is non-critical
        Logger.warn('Failed to cleanup migration backup [$backupPath]',
            rawError: e);
      }
    }());
  }

  void _updatePendingTaskInMemory(MigrationTask task) {
    final index = _pendingTasks.indexWhere((t) => t.taskId == task.taskId);
    if (index >= 0) {
      _pendingTasks[index] = task;
    }
  }

  MigrationTask _updateTaskCheckpointForSpace(
    MigrationTask task,
    String spaceName,
    Uint8List checkpointKey,
  ) {
    final updated = task.upsertCheckpointKeyForSpace(spaceName, checkpointKey);
    _updatePendingTaskInMemory(updated);
    return updated;
  }

  Future<TableSchema?> _resolveOldSchemaSnapshot(MigrationTask task) async {
    if (task.oldSchemaSnapshot != null) {
      return task.oldSchemaSnapshot;
    }

    final renameOp = _findRenameOperation(task.operations);
    if (renameOp != null) {
      if (task.forceDataMigration ||
          _mayNeedDataRewriteWithoutSnapshot(task.operations)) {
        Logger.error(
          'Migration task [${task.taskId}] is missing an old schema snapshot for rename + data rewrite. Continuing would decode old records with the wrong layout.',
        );
        return null;
      }

      final currentSchema = await _dataStore.tableMetaManager
          ?.getTableSchemaByName(
              TableName(renameOp.newTableName ?? task.tableName));
      if (currentSchema != null) {
        Logger.warn(
          'Migration task [${task.taskId}] is missing an old schema snapshot for rename-only migration. Falling back to the current schema of ${currentSchema.name}.',
        );
      }
      return currentSchema;
    }

    if (!task.isSchemaUpdated) {
      final currentSchema = await _dataStore.tableMetaManager
          ?.getTableSchemaByName(TableName(task.tableName));
      if (currentSchema != null) {
        Logger.warn(
          'Migration task [${task.taskId}] is missing an old schema snapshot. Falling back to the current schema of ${task.tableName}.',
        );
      }
      return currentSchema;
    }

    Logger.error(
      'Migration task [${task.taskId}] is missing an old schema snapshot after schema update. In-place data rewrite cannot continue safely.',
    );
    return null;
  }

  bool _mayNeedDataRewriteWithoutSnapshot(List<MigrationOperation> operations) {
    for (final operation in operations) {
      switch (operation.type) {
        case MigrationType.modifyField:
        case MigrationType.setPrimaryKeyConfig:
          return true;
        default:
          break;
      }
    }
    return false;
  }

  bool _specificIndexFieldMatches(IndexSchema index, IndexUid field) =>
      index.indexUid == field;

  IndexSchema _resolveSpecificIndexSchema(
    List<IndexSchema> allIndexes,
    IndexUid field,
  ) {
    for (final i in allIndexes) {
      if (_specificIndexFieldMatches(i, field)) return i;
    }
    return IndexSchema(indexName: field.value, fields: const []);
  }

  void _markIndexRemoved(Set<String> removed, IndexSchema index) {
    if (index.indexUid.isNotEmpty) {
      removed.add(index.indexUid.value);
    }
    // Legacy aliases for persisted tasks that still reference logical names.
    removed.add(index.actualIndexName);
    final logicalName = index.indexName;
    if (logicalName != null && logicalName.isNotEmpty) {
      removed.add(logicalName);
    }
  }

  List<IndexUid> _calculateBuildingIndexes({
    required TableSchema? oldSchema,
    required TableSchema? targetSchema,
    required List<MigrationOperation> sortedOperations,
    required TableContext table,
  }) {
    final indexesToBuild = <IndexUid>[];

    if (oldSchema != null && targetSchema != null) {
      // Build field rename mapping: old field name -> new field name
      final fieldRenames = <String, String>{};
      for (final op in sortedOperations) {
        if (op.type == MigrationType.renameField &&
            op.fieldName != null &&
            op.newName != null) {
          fieldRenames[op.fieldName!] = op.newName!;
        }
      }

      final oldAllIndexes = <IndexSchema>[
        ...oldSchema.getAllIndexes(),
        ...?_dataStore.indexManager
            ?.getEngineManagedBtreeIndexes(table, oldSchema),
      ];

      final targetAllIndexes = <IndexSchema>[
        ...targetSchema.getAllIndexes(),
        ...?_dataStore.indexManager
            ?.getEngineManagedBtreeIndexes(table, targetSchema),
      ];

      // 1. Identify newly added or modified index definitions (including unique constraints, TTL, foreign keys)
      for (final newIdx in targetAllIndexes) {
        final newIdxUid = newIdx.indexUid;
        IndexSchema? oldIdx;

        if (fieldRenames.isNotEmpty) {
          for (final oldIndex in oldAllIndexes) {
            final mappedOldFields =
                oldIndex.fields.map((f) => fieldRenames[f] ?? f).toList();
            final sameName = oldIndex.indexName != null &&
                newIdx.indexName != null &&
                oldIndex.indexName == newIdx.indexName;
            final sameFields =
                _areIndexFieldsEqual(mappedOldFields, newIdx.fields);
            if (sameName || sameFields) {
              oldIdx = oldIndex;
              break;
            }
          }
        } else {
          for (final oldIndex in oldAllIndexes) {
            if (oldIndex.indexUid.isNotEmpty &&
                oldIndex.indexUid == newIdx.indexUid) {
              oldIdx = oldIndex;
              break;
            }
            if (oldIndex.actualIndexName == newIdx.actualIndexName) {
              oldIdx = oldIndex;
              break;
            }
          }
        }

        if (oldIdx == null) {
          // Brand new index, must be physically built
          if (newIdxUid.isNotEmpty) {
            indexesToBuild.add(newIdxUid);
          }
        } else {
          // Existing index, check if its definition changed
          bool definitionChanged = false;
          final mappedOldFields =
              oldIdx.fields.map((f) => fieldRenames[f] ?? f).toList();

          if (mappedOldFields.length != newIdx.fields.length) {
            definitionChanged = true;
          } else {
            for (int i = 0; i < mappedOldFields.length; i++) {
              if (mappedOldFields[i] != newIdx.fields[i]) {
                definitionChanged = true;
                break;
              }
            }
          }

          // Check if any field in the index changed its data type
          bool typeChanged = false;
          for (final oldFieldName in oldIdx.fields) {
            final newFieldName = fieldRenames[oldFieldName] ?? oldFieldName;
            FieldSchema? oldField;
            for (final f in oldSchema.fields) {
              if (f.name == oldFieldName) {
                oldField = f;
                break;
              }
            }
            FieldSchema? targetField;
            for (final f in targetSchema.fields) {
              if (f.name == newFieldName) {
                targetField = f;
                break;
              }
            }
            if (oldField != null &&
                targetField != null &&
                oldField.type != targetField.type) {
              typeChanged = true;
              break;
            }
          }

          if (oldIdx.unique != newIdx.unique ||
              oldIdx.type != newIdx.type ||
              oldIdx.vectorConfig != newIdx.vectorConfig ||
              typeChanged) {
            definitionChanged = true;
          }

          if (definitionChanged && newIdxUid.isNotEmpty) {
            indexesToBuild.add(newIdxUid);
          }
        }
      }

      // 2. Identify indexes impacted by field type modifications
      for (final op in sortedOperations) {
        if (op.type == MigrationType.modifyField) {
          final fieldUpdate = op.fieldUpdate!;
          FieldSchema? oldField;
          for (final f in oldSchema.fields) {
            if (f.name == fieldUpdate.name) {
              oldField = f;
              break;
            }
          }
          if (oldField != null &&
              fieldUpdate.type != null &&
              oldField.type != fieldUpdate.type) {
            final newFieldName =
                fieldRenames[fieldUpdate.name] ?? fieldUpdate.name;
            // Rebuild all indexes referencing the modified field name
            for (final idx in targetAllIndexes) {
              if (idx.fields.contains(fieldUpdate.name) ||
                  idx.fields.contains(newFieldName)) {
                if (idx.indexUid.isNotEmpty) {
                  indexesToBuild.add(idx.indexUid);
                }
              }
            }
          }
        }
      }
    }

    return indexesToBuild.toSet().toList();
  }

  bool _needDataMigration(
      List<MigrationOperation> operations, TableSchema? oldSchema) {
    if (oldSchema == null) return false;
    for (final operation in operations) {
      if (operation.type == MigrationType.modifyField) {
        // Only migrate data if field definition changes affect storage or constraints
        final update = operation.fieldUpdate!;
        final oldField = oldSchema.fields.cast<FieldSchema?>().firstWhere(
              (f) => f?.name == update.name,
              orElse: () => null,
            );

        if (oldField != null) {
          // 1. Type change requires migration
          if (update.type != null && oldField.type != update.type) {
            return true;
          }
          // 2. Nullable -> Non-nullable requires migration (to fill defaults)
          if (oldField.nullable && update.nullable == false) {
            return true;
          }
          // 3. Length constraints requires migration
          if (update.maxLength != null &&
              (oldField.maxLength == null ||
                  update.maxLength! < oldField.maxLength!)) {
            return true;
          }
          if (update.minLength != null &&
              (oldField.minLength == null ||
                  update.minLength! > oldField.minLength!)) {
            return true;
          }
          // 4. Value range constraints requires migration
          if (update.minValue != null &&
              (oldField.minValue == null ||
                  update.minValue! > oldField.minValue!)) {
            return true;
          }
          if (update.maxValue != null &&
              (oldField.maxValue == null ||
                  update.maxValue! < oldField.maxValue!)) {
            return true;
          }
        }
      } else if (operation.type == MigrationType.setPrimaryKeyConfig) {
        final newConfig = operation.primaryKeyConfig;
        final oldConfig = oldSchema.primaryKeyConfig;
        if (newConfig != null &&
            (newConfig.name != oldConfig.name ||
                newConfig.type != oldConfig.type)) {
          return true;
        }
      }
    }
    return false;
  }

  bool _needRuntimeRecordBridge(
    List<MigrationOperation> operations,
    TableSchema? oldSchema,
  ) {
    if (_needDataMigration(operations, oldSchema)) {
      return true;
    }

    for (final operation in operations) {
      switch (operation.type) {
        case MigrationType.addField:
        case MigrationType.removeField:
        case MigrationType.renameField:
        case MigrationType.renameTable:
          return true;
        default:
          break;
      }
    }
    return false;
  }

  /// Compare schemas and generate operations
  Future<List<MigrationOperation>> _compareSchemasAndGenerateOperations(
      TableSchema oldSchema, TableSchema newSchema,
      {Map<String, String> renamedTableTargets = const {}}) async {
    final normalizedOldSchema = _normalizeSchemaForRenameAwareComparison(
      oldSchema,
      renamedTableTargets,
    );
    final normalizedNewSchema = _normalizeSchemaForRenameAwareComparison(
      newSchema,
      renamedTableTargets,
    );

    if (oldSchema.isGlobal != newSchema.isGlobal) {
      final tableName = newSchema.name;
      final recordCount = await _dataStore.tableDataManager
          .getTableRecordCount(await _requireTableContext(tableName));

      if (recordCount != 0) {
        Logger.warn(
          'Attempted to change "isGlobal" for table $tableName with existing data (recordCount=$recordCount). '
          'This requires complex data migration between spaces and the global scope and is therefore rejected.',
        );
        throw DbException([
          SchemaValidationStatus(
            type: ResultType.devInvalidSchemaSpaceMismatch,
            message:
                'Changing the "isGlobal" property (from ${oldSchema.isGlobal} to ${newSchema.isGlobal}) for an existing table ($tableName) with existing data is not supported. '
                'Please perform the data migration manually, or clear the table before changing "isGlobal".',
            tableName: tableName,
            wrongValue: {
              'oldIsGlobal': oldSchema.isGlobal,
              'newIsGlobal': newSchema.isGlobal,
              'recordCount': recordCount,
            },
          )
        ]);
      }

      Logger.info(
        'Table $tableName has no data (recordCount=0), allowing "isGlobal" change '
        'from ${oldSchema.isGlobal} to ${newSchema.isGlobal}.',
      );
    }
    final operations = <MigrationOperation>[];

    // Check field changes
    await _compareFields(normalizedOldSchema, normalizedNewSchema, operations);

    // check primary key config change
    if (_isPrimaryKeyConfigChanged(normalizedOldSchema, normalizedNewSchema)) {
      operations.add(MigrationOperation(
        type: MigrationType.setPrimaryKeyConfig,
        primaryKeyConfig: newSchema.primaryKeyConfig,
        oldPrimaryKeyConfig: oldSchema.primaryKeyConfig,
      ));
    }

    if (_isTtlConfigChanged(
      normalizedOldSchema.ttlConfig,
      normalizedNewSchema.ttlConfig,
    )) {
      operations.add(MigrationOperation(
        type: MigrationType.setTableTtlConfig,
        ttlConfig: newSchema.ttlConfig,
        oldTtlConfig: oldSchema.ttlConfig,
      ));
    }

    // Check indexes changes
    _compareIndexes(normalizedOldSchema, normalizedNewSchema, operations);

    // Check foreign key changes
    _compareForeignKeys(normalizedOldSchema, normalizedNewSchema, operations);

    return operations;
  }

  TableSchema _normalizeSchemaForRenameAwareComparison(
    TableSchema schema,
    Map<String, String> renamedTableTargets,
  ) {
    if (renamedTableTargets.isEmpty || schema.foreignKeys.isEmpty) {
      return schema;
    }

    var changed = false;
    final normalizedForeignKeys = schema.foreignKeys.map((fk) {
      final renamedTarget = renamedTableTargets[fk.referencedTable];
      if (renamedTarget == null || renamedTarget == fk.referencedTable) {
        return fk;
      }
      changed = true;
      return fk.copyWith(referencedTable: renamedTarget);
    }).toList(growable: false);

    if (!changed) {
      return schema;
    }

    return schema.copyWith(foreignKeys: normalizedForeignKeys);
  }

  /// check primary key config change (compare detailed config instead of only type)
  bool _isPrimaryKeyConfigChanged(
      TableSchema oldSchema, TableSchema newSchema) {
    // check added properties change
    // 1. check primary key field name change
    if (oldSchema.primaryKeyConfig.name != newSchema.primaryKeyConfig.name) {
      Logger.info(
        'Primary key name change detected: ${oldSchema.primaryKeyConfig.name} -> ${newSchema.primaryKeyConfig.name}',
      );
      return true;
    }

    // 2. check primary key ordered change
    if (oldSchema.primaryKeyConfig.isOrdered !=
        newSchema.primaryKeyConfig.isOrdered) {
      Logger.info(
        'Primary key ordering change detected: ${oldSchema.primaryKeyConfig.isOrdered} -> ${newSchema.primaryKeyConfig.isOrdered}',
      );
      return true;
    }

    // check primary key generation type change
    if (oldSchema.primaryKeyConfig.type != newSchema.primaryKeyConfig.type) {
      return true;
    }

    // if both are sequential increment mode, check detailed config
    if (oldSchema.primaryKeyConfig.type == PrimaryKeyType.sequential &&
        newSchema.primaryKeyConfig.type == PrimaryKeyType.sequential) {
      final oldConfig = oldSchema.primaryKeyConfig.sequentialConfig;
      final newConfig = newSchema.primaryKeyConfig.sequentialConfig;

      // special handling: if one is null but the other is not null
      if ((oldConfig == null) != (newConfig == null)) {
        // if old config is default config and new config is null, consider as same
        if (newConfig == null &&
            oldConfig != null &&
            oldConfig.initialValue == 1 &&
            oldConfig.increment == 1 &&
            !oldConfig.useRandomIncrement) {
          return false; // consider as no change
        }
        // if new config is default config and old config is null, consider as same
        if (oldConfig == null &&
            newConfig != null &&
            newConfig.initialValue == 1 &&
            newConfig.increment == 1 &&
            !newConfig.useRandomIncrement) {
          return false; // consider as no change
        }
        return true;
      }

      // if both are not null, compare detailed config
      if (oldConfig != null && newConfig != null) {
        if (oldConfig.initialValue != newConfig.initialValue ||
            oldConfig.increment != newConfig.increment ||
            oldConfig.useRandomIncrement != newConfig.useRandomIncrement) {
          return true;
        }
      }
    }

    // if both are timestamp based type, no need to compare detailed config
    if ((oldSchema.primaryKeyConfig.type == PrimaryKeyType.timestampBased ||
                oldSchema.primaryKeyConfig.type ==
                    PrimaryKeyType.datePrefixed) &&
            (newSchema.primaryKeyConfig.type == PrimaryKeyType.timestampBased ||
                newSchema.primaryKeyConfig.type ==
                    PrimaryKeyType.datePrefixed) ||
        (oldSchema.primaryKeyConfig.type == PrimaryKeyType.shortCode ||
            newSchema.primaryKeyConfig.type == PrimaryKeyType.shortCode)) {
      // if timestamp based type changed to date prefixed type, or vice versa, consider as change
      return oldSchema.primaryKeyConfig.type != newSchema.primaryKeyConfig.type;
    }

    // all conditions are not met, config is not changed
    return false;
  }

  bool _isTtlConfigChanged(TableTtlConfig? oldTtl, TableTtlConfig? newTtl) {
    if (identical(oldTtl, newTtl)) return false;
    if (oldTtl == null || newTtl == null) return oldTtl != newTtl;

    final oldSource =
        (oldTtl.sourceField == null || oldTtl.sourceField!.isEmpty)
            ? null
            : oldTtl.sourceField;
    final newSource =
        (newTtl.sourceField == null || newTtl.sourceField!.isEmpty)
            ? null
            : newTtl.sourceField;

    return oldTtl.ttlMs != newTtl.ttlMs || oldSource != newSource;
  }

  /// Compare fields and generate operations
  Future<void> _compareFields(
    TableSchema oldSchema,
    TableSchema newSchema,
    List<MigrationOperation> operations,
  ) async {
    // check added fields
    for (var newField in newSchema.fields) {
      if (!oldSchema.fields.any((f) => f.name == newField.name)) {
        operations.add(MigrationOperation(
          type: MigrationType.addField,
          field: newField,
        ));
        continue;
      }

      // check modified fields
      final oldField = oldSchema.fields.firstWhere(
        (f) => f.name == newField.name,
      );
      if (_isFieldModified(oldField, newField)) {
        // Add check for dangerous type conversions before adding the operation
        if (oldField.type != newField.type) {
          _preventDangerousTypeConversion(oldField, newField);
        }

        if (!SystemTable.isSystemTable(newSchema.name)) {
          Logger.info(
            'Table ${newSchema.name}, field ${newField.name} has been modified',
          );
        }
        operations.add(MigrationOperation(
          type: MigrationType.modifyField,
          fieldUpdate: FieldSchemaUpdate(
            name: newField.name,
            type: newField.type,
            nullable: newField.nullable,
            defaultValue: newField.defaultValue,
            unique: newField.unique,
            comment: newField.comment,
            minLength: newField.minLength,
            maxLength: newField.maxLength,
            minValue: newField.minValue,
            maxValue: newField.maxValue,
            defaultValueType: newField.defaultValueType,
            fieldId: newField.fieldId,
            vectorConfig: newField.vectorConfig,
          ),
        ));
      }
    }

    // Check for removed fields
    for (var oldField in oldSchema.fields) {
      if (!newSchema.fields.any((f) => f.name == oldField.name)) {
        operations.add(MigrationOperation(
          type: MigrationType.removeField,
          fieldName: oldField.name,
        ));
      }
    }

    // Check for renamed fields
    await _detectRenamedFields(oldSchema, newSchema, operations);
  }

  /// Compare indexes and generate operations
  void _compareIndexes(
    TableSchema oldSchema,
    TableSchema newSchema,
    List<MigrationOperation> operations,
  ) {
    final oldIndexes = oldSchema.indexes;
    final newIndexes = newSchema.indexes;

    // Build field rename mapping
    final fieldRenames = <String, String>{};
    for (final op in operations) {
      if (op.type == MigrationType.renameField &&
          op.fieldName != null &&
          op.newName != null) {
        fieldRenames[op.fieldName!] = op.newName!;
      }
    }

    // First mark all old indexes as to be removed
    final indexesToRemove = List<IndexSchema>.from(oldIndexes);

    // Check for added and modified indexes
    for (var newIndex in newIndexes) {
      // Try to find matching index in old schema
      IndexSchema? matchedOldIndex;

      for (var oldIndex in indexesToRemove) {
        // Map old index fields to new names using rename operations
        final mappedOldFields =
            oldIndex.fields.map((f) => fieldRenames[f] ?? f).toList();
        final mappedOldIndex = oldIndex.copyWith(fields: mappedOldFields);

        if (_areIndexesSame(mappedOldIndex, newIndex)) {
          matchedOldIndex = oldIndex;
          break;
        }
      }

      if (matchedOldIndex == null) {
        // No matching old index found, this is a new index
        operations.add(MigrationOperation(
          type: MigrationType.addIndex,
          index: newIndex,
        ));
      } else {
        // Found matching old index, remove from to-be-deleted list
        indexesToRemove.remove(matchedOldIndex);

        // Check if rename is needed
        if (matchedOldIndex.actualIndexName != newIndex.actualIndexName) {
          operations.add(MigrationOperation(
            type: MigrationType.renameIndex,
            indexName: matchedOldIndex.actualIndexName,
            newName: newIndex.actualIndexName,
            fields: newIndex.fields,
          ));

          // After rename, it might also be modified (e.g. type changed)
          if (matchedOldIndex.unique != newIndex.unique ||
              matchedOldIndex.type != newIndex.type ||
              matchedOldIndex.vectorConfig != newIndex.vectorConfig) {
            operations.add(MigrationOperation(
              type: MigrationType.modifyIndex,
              indexName: newIndex.actualIndexName, // It will be renamed first
              index: newIndex,
              fields: newIndex.fields,
              unique: newIndex.unique,
            ));
          }
        }
        // Check if modification is needed (no rename)
        else if (_isIndexModified(matchedOldIndex, newIndex)) {
          operations.add(MigrationOperation(
            type: MigrationType.modifyIndex,
            indexName: matchedOldIndex.actualIndexName,
            index: newIndex,
            fields: newIndex.fields,
            unique: newIndex.unique,
          ));
        }
      }
    }

    // Handle indexes that need to be removed
    for (var indexToRemove in indexesToRemove) {
      if (!SystemTable.isSystemTable(oldSchema.name)) {
        Logger.info(
          'Detected index to be removed: ${indexToRemove.actualIndexName}, fields: ${indexToRemove.fields.join(", ")}',
        );
      }

      operations.add(MigrationOperation(
        type: MigrationType.removeIndex,
        indexName: indexToRemove
            .actualIndexName, // Use actualIndexName instead of indexName
        fields: indexToRemove
            .fields, // Also provide field list for more reliable matching
      ));
    }
  }

  /// Check if two indexes are the same
  bool _areIndexesSame(IndexSchema a, IndexSchema b) {
    if (a.indexName != null &&
        b.indexName != null &&
        a.indexName == b.indexName) {
      return true;
    }
    return _areIndexFieldsEqual(a.fields, b.fields);
  }

  /// Compare two index field lists with order preserved.
  bool _areIndexFieldsEqual(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  bool _areFieldListsEqual(List<String> a, List<String> b) {
    return _areIndexFieldsEqual(a, b);
  }

  /// Check if index is modified
  bool _isIndexModified(IndexSchema oldIndex, IndexSchema newIndex) {
    // Note: logical indexName change is handled by MigrationType.renameIndex
    // (schema only). Physical reconciliation uses stable [IndexUid].
    // ModifyIndex causes a full rebuild (drop + recreate), so it should only trigger
    // if structural configuration (unique, type, vector config, or fields) changes.
    return oldIndex.unique != newIndex.unique ||
        oldIndex.type != newIndex.type ||
        oldIndex.vectorConfig != newIndex.vectorConfig ||
        !_areIndexFieldsEqual(oldIndex.fields, newIndex.fields);
  }

  /// Compare foreign keys and generate operations
  ///
  /// Foreign key change rules:
  /// - **Allowed to modify**: onDelete, onUpdate, enabled, autoCreateIndex, comment
  /// - **Not allowed to modify**: fields, referencedTable, referencedFields
  ///   (These are core definitions. If changed, must remove old FK and add new FK)
  void _compareForeignKeys(
    TableSchema oldSchema,
    TableSchema newSchema,
    List<MigrationOperation> operations,
  ) {
    // First mark all old foreign keys as to be removed
    final foreignKeysToRemove =
        List<ForeignKeySchema>.from(oldSchema.foreignKeys);

    // Check for added and modified foreign keys
    for (var newFk in newSchema.foreignKeys) {
      // Try to find matching foreign key in old schema by name
      ForeignKeySchema? matchedOldFk;

      for (var oldFk in oldSchema.foreignKeys) {
        // Match by actual name (handles auto-generated names)
        if (oldFk.actualName == newFk.actualName) {
          matchedOldFk = oldFk;
          break;
        }
      }

      if (matchedOldFk == null) {
        // No matching old foreign key found, this is a new foreign key
        operations.add(MigrationOperation(
          type: MigrationType.addForeignKey,
          foreignKey: newFk,
        ));
      } else {
        // Found matching old foreign key, remove from to-be-deleted list
        foreignKeysToRemove.remove(matchedOldFk);

        // Check if modification is needed
        // Core definitions (fields, referencedTable, referencedFields) cannot be modified
        // If they change, we must remove old FK and add new FK
        final coreDefinitionChanged =
            !_areFieldListsEqual(matchedOldFk.fields, newFk.fields) ||
                matchedOldFk.referencedTable != newFk.referencedTable ||
                !_areFieldListsEqual(
                    matchedOldFk.referencedFields, newFk.referencedFields);

        if (coreDefinitionChanged) {
          // Core definition changed - this is a breaking change that requires manual handling
          // Throwing exception to warn developer that this requires data migration
          throw DbException([
            SchemaValidationStatus(
              type: ResultType.devInvalidSchemaForeignKey,
              message:
                  'Foreign key core definition change detected for ${matchedOldFk.actualName} in table ${oldSchema.name}. '
                  'Core definitions (fields, referencedTable, referencedFields) cannot be automatically modified. '
                  'This is a breaking change that may cause data inconsistency.\n'
                  'Old definition: fields=${matchedOldFk.fields}, referencedTable=${matchedOldFk.referencedTable}, referencedFields=${matchedOldFk.referencedFields}\n'
                  'New definition: fields=${newFk.fields}, referencedTable=${newFk.referencedTable}, referencedFields=${newFk.referencedFields}\n'
                  'Please handle this manually:\n'
                  '1. Remove the old foreign key: db.schema("${oldSchema.name}").removeForeignKey("${matchedOldFk.actualName}")\n'
                  '2. Ensure data integrity (check for orphaned records, update data if needed)\n'
                  '3. Add the new foreign key: db.schema("${oldSchema.name}").addForeignKey(...)',
              tableName: oldSchema.name,
              field: matchedOldFk.fields.join(','),
              wrongValue: {
                'oldFk': {
                  'fields': matchedOldFk.fields,
                  'referencedTable': matchedOldFk.referencedTable,
                  'referencedFields': matchedOldFk.referencedFields,
                },
                'newFk': {
                  'fields': newFk.fields,
                  'referencedTable': newFk.referencedTable,
                  'referencedFields': newFk.referencedFields,
                }
              },
            )
          ]);
        } else {
          // Only non-core properties changed - can modify
          final needsModification = matchedOldFk.onDelete != newFk.onDelete ||
              matchedOldFk.onUpdate != newFk.onUpdate ||
              matchedOldFk.enabled != newFk.enabled ||
              matchedOldFk.autoCreateIndex != newFk.autoCreateIndex ||
              matchedOldFk.comment != newFk.comment;

          if (needsModification) {
            operations.add(MigrationOperation(
              type: MigrationType.modifyForeignKey,
              foreignKey: newFk,
              oldForeignKey: matchedOldFk,
            ));
          }
        }
      }
    }

    // Handle foreign keys that need to be removed
    for (var fkToRemove in foreignKeysToRemove) {
      if (!SystemTable.isSystemTable(oldSchema.name)) {
        Logger.info(
          'Detected foreign key to be removed: ${fkToRemove.actualName}',
        );
      }

      operations.add(MigrationOperation(
        type: MigrationType.removeForeignKey,
        foreignKeyName: fkToRemove.actualName,
      ));
    }
  }

  /// Detect renamed fields using strict matching
  Future<void> _detectRenamedFields(
    TableSchema oldSchema,
    TableSchema newSchema,
    List<MigrationOperation> operations,
  ) async {
    // Get removed and added fields
    final removedFields = operations
        .where((op) => op.type == MigrationType.removeField)
        .map((op) => op.fieldName!)
        .toList();
    final addedFields = operations
        .where((op) => op.type == MigrationType.addField)
        .map((op) => op.field!)
        .toList();

    // if no removed or added fields, no need to detect renamed fields
    if (removedFields.isEmpty || addedFields.isEmpty) return;

    // match renamed fields by fieldId directly
    _detectRenamedFieldsByFieldId(
        oldSchema, newSchema, operations, removedFields, addedFields);

    // if there are still fields to match, match by similarity
    if (removedFields.isNotEmpty && addedFields.isNotEmpty) {
      await _detectRenamedFieldsBySimilarityParallel(
          oldSchema, newSchema, operations, removedFields, addedFields);
    }
  }

  /// match renamed fields by fieldId directly
  void _detectRenamedFieldsByFieldId(
    TableSchema oldSchema,
    TableSchema newSchema,
    List<MigrationOperation> operations,
    List<String> removedFields,
    List<FieldSchema> addedFields,
  ) {
    // for storing matched fields, avoid duplicate processing
    final matchedRemovedFields = <String>{};
    final matchedAddedFields = <FieldSchema>{};

    // iterate added fields
    for (var newField in addedFields) {
      // only process fields with fieldId
      if (newField.fieldId == null) continue;

      // if new field is primary key, skip
      if (newField.name == newSchema.primaryKey) continue;

      // find field in old schema with same fieldId
      for (var oldFieldName in removedFields) {
        // if old field is primary key, skip
        if (oldSchema.primaryKey == oldFieldName) continue;

        final oldField = oldSchema.fields.firstWhere(
          (f) => f.name == oldFieldName,
          orElse: () => const FieldSchema(name: '', type: DataType.text),
        );

        // if found matching fieldId, consider as renamed
        if (oldField.fieldId != null && oldField.fieldId == newField.fieldId) {
          // remove existing add and remove operations
          operations.removeWhere((op) =>
              (op.type == MigrationType.removeField &&
                  op.fieldName == oldFieldName) ||
              (op.type == MigrationType.addField && op.field == newField));

          // add rename operation
          operations.add(MigrationOperation(
            type: MigrationType.renameField,
            fieldName: oldFieldName,
            newName: newField.name,
          ));

          // After rename, it might also be modified (e.g. type changed, maxLength changed)
          if (_isFieldModified(oldField, newField)) {
            // Add check for dangerous type conversions before adding the operation
            if (oldField.type != newField.type) {
              _preventDangerousTypeConversion(oldField, newField);
            }

            operations.add(MigrationOperation(
              type: MigrationType.modifyField,
              fieldUpdate: FieldSchemaUpdate(
                name: oldFieldName,
                type: newField.type,
                nullable: newField.nullable,
                defaultValue: newField.defaultValue,
                unique: newField.unique,
                comment: newField.comment,
                minLength: newField.minLength,
                maxLength: newField.maxLength,
                minValue: newField.minValue,
                maxValue: newField.maxValue,
                defaultValueType: newField.defaultValueType,
                fieldId: newField.fieldId,
                vectorConfig: newField.vectorConfig,
              ),
            ));
          }

          // record matched fields
          matchedRemovedFields.add(oldFieldName);
          matchedAddedFields.add(newField);
          break;
        }
      }
    }

    // remove matched fields from original list
    removedFields.removeWhere((field) => matchedRemovedFields.contains(field));
    addedFields.removeWhere((field) => matchedAddedFields.contains(field));
  }

  /// parallel way to detect renamed fields
  Future<void> _detectRenamedFieldsBySimilarityParallel(
    TableSchema oldSchema,
    TableSchema newSchema,
    List<MigrationOperation> operations,
    List<String> removedFields,
    List<FieldSchema> addedFields,
  ) async {
    // field similarity threshold, only fields with score above this value will be considered as renamed
    const similarityThreshold = 0.6;

    // prepare parallel calculation requests
    final similarityRequests = <FieldSimilarityRequest>[];

    // iterate all fields to compare
    for (var oldFieldName in removedFields) {
      // if old field is primary key, skip
      if (oldSchema.primaryKey == oldFieldName) continue;

      final oldField = oldSchema.fields.firstWhere(
        (f) => f.name == oldFieldName,
      );

      for (var newField in addedFields) {
        // if new field is primary key, skip
        if (newSchema.primaryKey == newField.name) continue;

        similarityRequests.add(FieldSimilarityRequest(
          oldField: oldField,
          newField: newField,
          oldFieldIndex: oldSchema.fields.indexOf(oldField),
          newFieldIndex: newSchema.fields.indexOf(newField),
          oldFieldsCount: oldSchema.fields.length,
          newFieldsCount: newSchema.fields.length,
          oldSchema: oldSchema,
          newSchema: newSchema,
        ));
      }
    }

    // if no requests to process, return
    if (similarityRequests.isEmpty) {
      return;
    }

    // max concurrent
    final maxConcurrent = _dataStore.config.maxConcurrency;

    // batch processing requests
    final int batchSize = (similarityRequests.length / maxConcurrent).ceil();
    final batches = <List<FieldSimilarityRequest>>[];

    for (int i = 0; i < similarityRequests.length; i += batchSize) {
      final end = min(i + batchSize, similarityRequests.length);
      batches.add(similarityRequests.sublist(i, end));
    }

    // parallel processing all batches
    final batchResults =
        await Future.wait(batches.map((batch) => ComputeManager.run(
              ComputeTask(
                function: calculateBatchFieldSimilarity,
                message: BatchFieldSimilarityRequest(requests: batch),
              ),
              useIsolate: similarityRequests.length > 100,
            )));

    // merge all results
    final allResults = <FieldSimilarityResult>[];
    for (final batchResult in batchResults) {
      allResults.addAll(batchResult.results);
    }

    // sort results by similarity
    allResults.sort((a, b) => b.similarity.compareTo(a.similarity));

    // greedy matching algorithm
    final processedOldFields = <String>{};
    final processedNewFields = <FieldSchema>{};

    for (final result in allResults) {
      // if field is already processed, skip
      if (processedOldFields.contains(result.oldFieldName) ||
          processedNewFields.contains(result.newField)) {
        continue;
      }

      // if best match is above threshold, consider as renamed field
      if (result.similarity >= similarityThreshold) {
        // remove existing add and remove operations
        operations.removeWhere((op) =>
            (op.type == MigrationType.removeField &&
                op.fieldName == result.oldFieldName) ||
            (op.type == MigrationType.addField && op.field == result.newField));

        // add rename operation
        operations.add(MigrationOperation(
          type: MigrationType.renameField,
          fieldName: result.oldFieldName,
          newName: result.newField.name,
        ));

        final oldField = oldSchema.fields.firstWhere(
          (f) => f.name == result.oldFieldName,
        );

        // After rename, it might also be modified (e.g. type changed, maxLength changed)
        if (_isFieldModified(oldField, result.newField)) {
          // Add check for dangerous type conversions before adding the operation
          if (oldField.type != result.newField.type) {
            _preventDangerousTypeConversion(oldField, result.newField);
          }

          operations.add(MigrationOperation(
            type: MigrationType.modifyField,
            fieldUpdate: FieldSchemaUpdate(
              name: result.oldFieldName,
              type: result.newField.type,
              nullable: result.newField.nullable,
              defaultValue: result.newField.defaultValue,
              unique: result.newField.unique,
              comment: result.newField.comment,
              minLength: result.newField.minLength,
              maxLength: result.newField.maxLength,
              minValue: result.newField.minValue,
              maxValue: result.newField.maxValue,
              defaultValueType: result.newField.defaultValueType,
              fieldId: result.newField.fieldId,
              vectorConfig: result.newField.vectorConfig,
            ),
          ));
        }

        // record processed fields
        processedOldFields.add(result.oldFieldName);
        processedNewFields.add(result.newField);

        // remove from processing list
        removedFields.remove(result.oldFieldName);
        addedFields.remove(result.newField);
      } else {
        // if similarity is not high enough, break
        break;
      }
    }
  }

  /// Prevents unsafe data type conversions during schema migration.
  void _preventDangerousTypeConversion(
      FieldSchema oldField, FieldSchema newField) {
    final oldType = oldField.type;
    final newType = newField.type;
    bool isDangerous = false;
    String reason = '';

    // General rule: Converting from a less restrictive type to a more restrictive one is dangerous.
    // e.g., Text -> Integer, Blob -> Anything, Vector -> Anything (except itself)

    if (newType == DataType.integer ||
        newType == DataType.double ||
        newType == DataType.bigInt ||
        newType == DataType.datetime) {
      if (oldType == DataType.text ||
          oldType == DataType.blob ||
          oldType == DataType.vector ||
          oldType == DataType.json ||
          oldType == DataType.array) {
        isDangerous = true;
        reason = 'cannot be reliably converted to a numeric or date type.';
      }
    }

    // Changing from a vector to anything else is dangerous because embeddings would be lost.
    if (oldType == DataType.vector && newType != DataType.vector) {
      isDangerous = true;
      reason = 'would discard all existing vector embedding data.';
    }

    // Changing from blob, json, or array to an incompatible type is dangerous.
    if ((oldType == DataType.blob ||
            oldType == DataType.json ||
            oldType == DataType.array) &&
        (newType != oldType && newType != DataType.text)) {
      isDangerous = true;
      reason =
          'is a complex type and cannot be safely converted to the target type.';
    }

    if (isDangerous) {
      throw DbException([
        SchemaValidationStatus(
          type: ResultType.devMigrationUnsafeTypeConversion,
          message:
              'Unsupported data type change for field "${newField.name}" from ${oldType.name} to ${newType.name}. This conversion is unsafe because existing data $reason This could lead to data loss or migration failure. Please handle this migration manually by creating a new field and migrating the data yourself.',
          tableName: '',
          field: newField.name,
          wrongValue: {
            'oldType': oldType.name,
            'newType': newType.name,
          },
        )
      ]);
    }
  }

  /// Check if field is modified
  bool _isFieldModified(FieldSchema oldField, FieldSchema newField) {
    // check if default value is equal, special handling for datetime type
    bool areDefaultValuesEqual() {
      // if two default values are fully equal, return true directly
      if (oldField.defaultValue == newField.defaultValue) {
        return true;
      }

      // if datetime type, ignore default value change
      if (oldField.type == DataType.datetime &&
          newField.type == DataType.datetime) {
        return true; // consider as equal, no field change
      }

      // other types, default value different consider as not equal
      return false;
    }

    // Check for vector config changes, as this would invalidate existing vector data.
    if (jsonEncode(oldField.vectorConfig?.toJson()) !=
        jsonEncode(newField.vectorConfig?.toJson())) {
      Logger.warn(
        'Detected a change in vectorConfig for field "${newField.name}". This is considered a breaking change.',
      );
      return true;
    }

    // check if field is modified
    return oldField.type != newField.type ||
        oldField.nullable != newField.nullable ||
        oldField.unique != newField.unique ||
        oldField.maxLength != newField.maxLength ||
        oldField.minLength != newField.minLength ||
        oldField.minValue != newField.minValue ||
        oldField.maxValue != newField.maxValue ||
        !areDefaultValuesEqual() ||
        oldField.comment != newField.comment ||
        oldField.defaultValueType != newField.defaultValueType ||
        oldField.fieldId != newField.fieldId;
  }

  /// Get next directory index for migration tasks
  Future<int> _getNextDirIndex() async {
    final meta = await _getOrLoadMigrationMeta();
    final mapping = meta.directoryMapping;
    final maxEntriesPerDir = _dataStore.maxEntriesPerDir;

    // Use cached currentDirIndex if available, otherwise calculate
    int currentDirIndex;
    if (_currentDirIndexCache != null) {
      currentDirIndex = _currentDirIndexCache!;
    } else {
      // Find current directory index (highest dirIndex with files)
      currentDirIndex = 0;
      if (mapping.dirToFileCount.isNotEmpty) {
        currentDirIndex =
            mapping.dirToFileCount.keys.reduce((a, b) => a > b ? a : b);
      }
      _currentDirIndexCache = currentDirIndex;
    }

    // Check if current directory is full
    final currentCount = mapping.getFileCount(currentDirIndex);
    if (currentCount >= maxEntriesPerDir) {
      // Allocate new directory
      final newDirIndex = currentDirIndex + 1;
      _currentDirIndexCache = newDirIndex;
      return newDirIndex;
    }

    return currentDirIndex;
  }

  /// Get or load migration metadata from cache or file
  Future<MigrationMeta> _getOrLoadMigrationMeta() async {
    // Return cached value if available
    if (_migrationMetaCache != null) {
      return _migrationMetaCache!;
    }

    // Load from file and cache
    return await _loadMigrationMeta();
  }

  /// Load migration metadata from file and update cache
  Future<MigrationMeta> _loadMigrationMeta() async {
    // If already loading, wait for that operation
    if (_loadingFuture != null) {
      return await _loadingFuture!;
    }

    // Start loading operation
    final loadOp = _performLoadMigrationMeta();
    _loadingFuture = loadOp;

    try {
      final result = await loadOp;
      return result;
    } finally {
      // Clear loading future after completion
      if (identical(_loadingFuture, loadOp)) {
        _loadingFuture = null;
      }
    }
  }

  /// Perform actual loading of migration metadata
  Future<MigrationMeta> _performLoadMigrationMeta() async {
    // Double-check after acquiring lock
    if (_migrationMetaCache != null) {
      return _migrationMetaCache!;
    }

    try {
      final metaPath = _dataStore.pathManager.getMigrationMetaPath();
      final metaContent = await _dataStore.storage.readAsString(metaPath);
      if (metaContent != null && metaContent.isNotEmpty) {
        _migrationMetaCache = MigrationMeta.fromJson(jsonDecode(metaContent));
      } else {
        _migrationMetaCache = MigrationMeta.initial();
      }
    } catch (e) {
      Logger.warn('Load migration meta failed, use initial', rawError: e);
      _migrationMetaCache = MigrationMeta.initial();
    }

    // Update currentDirIndex cache
    _updateCurrentDirIndexCache();

    return _migrationMetaCache!;
  }

  /// Update current directory index cache from directoryMapping
  void _updateCurrentDirIndexCache() {
    if (_migrationMetaCache == null) {
      _currentDirIndexCache = null;
      return;
    }

    final mapping = _migrationMetaCache!.directoryMapping;
    if (mapping.dirToFileCount.isNotEmpty) {
      _currentDirIndexCache =
          mapping.dirToFileCount.keys.reduce((a, b) => a > b ? a : b);
    } else {
      _currentDirIndexCache = 0;
    }
  }

  /// Save migration metadata to file and update cache
  Future<void> _saveMigrationMeta(MigrationMeta meta) async {
    try {
      final metaPath = _dataStore.pathManager.getMigrationMetaPath();
      await _dataStore.storage
          .writeAsString(metaPath, jsonEncode(meta.toJson()));

      // Update cache after successful save
      _migrationMetaCache = meta;
      _updateCurrentDirIndexCache();
    } catch (e) {
      Logger.warn('Save migration meta failed', rawError: e);
    }
  }

  /// Save migration task to file
  Future<void> _saveMigrationTask(MigrationTask task) async {
    final taskPath =
        _dataStore.pathManager.getMigrationTaskPath(task.dirIndex, task.taskId);
    await _dataStore.storage.writeAsString(taskPath, jsonEncode(task.toJson()));

    // update meta data with directory mapping
    final meta = await _getOrLoadMigrationMeta();
    final currentMapping = meta.directoryMapping;

    // Check if task already exists in mapping
    final existingDirIndex = currentMapping.getDirIndex(task.taskId);

    // Build updated mapping
    final newIdToDir = Map<String, int>.from(currentMapping.idToDir);
    newIdToDir[task.taskId] = task.dirIndex;

    final newDirToFileCount = Map<int, int>.from(currentMapping.dirToFileCount);

    // If task was moved from another directory, decrement old directory count
    if (existingDirIndex != null && existingDirIndex != task.dirIndex) {
      final oldCount = newDirToFileCount[existingDirIndex] ?? 0;
      if (oldCount > 1) {
        newDirToFileCount[existingDirIndex] = oldCount - 1;
      } else {
        // Remove directory from mapping when count reaches 0
        newDirToFileCount.remove(existingDirIndex);
      }
    }

    // Increment new directory count
    final newCount = newDirToFileCount[task.dirIndex] ?? 0;
    newDirToFileCount[task.dirIndex] = newCount + 1;

    final updatedMapping = DirectoryMappingString(
      idToDir: newIdToDir,
      dirToFileCount: newDirToFileCount,
    );

    final updatedMeta = meta.copyWith(directoryMapping: updatedMapping);
    await _saveMigrationMeta(updatedMeta);
  }

  /// Get all space names
  Future<List<String>> _getAllSpaces() async {
    final config = await _dataStore.getGlobalConfig();
    return config?.spaceNames.toList() ?? ['default'];
  }

  Future<List<String>> _getMigrationScopesForSchema(TableSchema? schema) async {
    if (schema?.isGlobal == true) {
      return const [_globalMigrationScope];
    }
    return _getAllSpaces();
  }

  /// Process pending migration tasks
  /// [return] MigrationTasksResult indicating if all tasks are successfully processed
  Future<MigrationTasksResult> processMigrationTasks() async {
    if (_isProcessingTasks || _pendingTasks.isEmpty) {
      return MigrationTasksResult(
          success: true); // no task to process, consider as success
    }

    _isProcessingTasks = true;
    bool success = true; // track if all tasks are successful
    final errors = <dynamic>[];
    try {
      // 1. Wait for primary instance recovery to complete before starting migration tasks.
      // This prevents migration writes from conflicting with WAL replay or missing
      // data that was about to be replayed.
      await _dataStore.parallelJournalManager.waitUntilRecoveryCompleted();

      while (_pendingTasks.isNotEmpty) {
        final task = _pendingTasks.first;

        // Large-scale migration can run for a long time; keep a broad timeout
        // only for deadlock/leak protection.
        const taskTimeout = Duration(hours: 24);
        try {
          _activeExecutingTaskId = task.taskId;
          _activeTaskFuture = _executeMigrationTask(task);
          final completed = await _activeTaskFuture!
              .then((_) => true)
              .timeout(taskTimeout, onTimeout: () {
            Logger.error(
              'Task execution timed out: taskId=${task.taskId}, tableName=${task.tableName}',
            );

            // timeout consider as failed
            success = false;
            errors.add(TimeoutException(
                'Migration task execution timed out for ${task.tableName}'));
            // timeout not remove task, continue to execute next time
            return false;
          });

          if (!completed) {
            break;
          }

          // task completed successfully, remove and clean up
          _pendingTasks.removeWhere((t) => t.taskId == task.taskId);
          if (task.oldSchemaSnapshot?.schemaVersion != null) {
            _schemaByVersion.remove(task.oldSchemaSnapshot!.schemaVersion!);
          }
          await _cleanupTask(task);
          _unregisterRuntimeMigrationForTask(task);
        } catch (e) {
          if (e is DbClosedException) {
            break;
          }

          Logger.error('Migration task execution failed', rawError: e);

          // task execution failed
          success = false;
          errors.add(e);

          final List<ResultStatus> newErrors = [];
          if (e is DbException) {
            newErrors.addAll(e.statuses);
          } else {
            newErrors.add(GeneralStatus(
              type: ResultType.engError,
              message: e.toString(),
            ));
          }
          final updatedTask = task.copyWith(
            errors: newErrors,
          );
          await _saveMigrationTask(updatedTask);
          _updatePendingTaskInMemory(updatedTask);

          // Keep the task on disk and in memory so startup / the next scheduler
          // pass can retry idempotent cutover steps after a crash or transient error.
          _unregisterRuntimeMigrationForTask(task);

          if (e is DbException) {
            final hasCritical = e.statuses.any((s) => s.type.isCriticalError);
            if (hasCritical) {
              rethrow;
            }
          }
          break;
        } finally {
          _activeExecutingTaskId = null;
          _activeTaskFuture = null;
        }
      }

      await syncHasMigrationTask();
    } catch (e) {
      Logger.error('Process migration tasks failed', rawError: e);
      success = false;
      errors.add(e);
      if (e is DbException) {
        final hasCritical = e.statuses.any((s) => s.type.isCriticalError);
        if (hasCritical) {
          rethrow;
        }
      } else {
        rethrow;
      }
    } finally {
      _isProcessingTasks = false;
    }

    return MigrationTasksResult(success: success, errors: errors);
  }

  /// Execute single migration task across spaces
  Future<void> _executeMigrationTask(MigrationTask task) async {
    var currentTask = task;
    final sortedOperations = _sortOperations(List.from(task.operations));
    final originalTableName = currentTask.tableName;
    var currentTableName = currentTask.currentTableName ??
        _resolveCurrentTableNameFromName(originalTableName, sortedOperations);
    final renameOp = _findRenameOperation(sortedOperations);

    try {
      // record task start time
      final taskStopwatch = Stopwatch()..start();
      _telemetry.recordTaskStart(task.taskId);
      if (!SystemTable.isSystemTable(task.tableName)) {
        Logger.info(
          'Starting migration task execution: ${task.taskId}, table: ${task.tableName}',
        );
      }

      var oldSchema = await _resolveOldSchemaSnapshot(currentTask);
      final shouldFlushBeforeMigration = currentTask.forceDataMigration ||
          _needRuntimeRecordBridge(sortedOperations, oldSchema);
      if (shouldFlushBeforeMigration) {
        await _dataStore.saveAllCacheBeforeExit();
      }
      var oldFieldLayout = currentTask.oldFieldLayoutSnapshot;
      if (oldFieldLayout == null && oldSchema != null) {
        oldFieldLayout = await _dataStore.tableMetaManager?.getTableFieldLayout(
          TableUid(currentTask.tableUid),
          schema: oldSchema,
        );
      }
      if ((oldSchema != null && currentTask.oldSchemaSnapshot == null) ||
          (oldFieldLayout != null &&
              currentTask.oldFieldLayoutSnapshot == null)) {
        currentTask = currentTask.copyWith(
          oldSchemaSnapshot: oldSchema,
          oldFieldLayoutSnapshot: oldFieldLayout,
        );
        await _saveMigrationTask(currentTask);
        _updatePendingTaskInMemory(currentTask);
      }

      // update global table structure first
      if (!currentTask.isSchemaUpdated &&
          currentTask.targetSchemaSnapshot != null) {
        final childIndexesToDrop = <TableUid, List<IndexUid>>{};
        currentTableName = await executeSchemaOperations(
          await _requireTableContext(currentTask.tableName),
          sortedOperations,
          targetSchema: currentTask.targetSchemaSnapshot!,
          outDroppedChildIndexes: childIndexesToDrop,
        );
        currentTask = currentTask.copyWith(
          isSchemaUpdated: true,
          referencingChildIndexesToDrop:
              childIndexesToDrop.isNotEmpty ? childIndexesToDrop : null,
        );
        await _saveMigrationTask(currentTask);
        _updatePendingTaskInMemory(currentTask);
        _registerRuntimeMigration(currentTask);
      }

      // 1. Perform pre-migration backup if configured
      if (_dataStore.config.migrationConfig?.backupBeforeMigrate ?? false) {
        bool needNewBackup = true;

        // If a backup path is already recorded, verify its integrity first
        if (currentTask.backupPath != null &&
            currentTask.backupPath!.isNotEmpty) {
          final backupManager = BackupManager(_dataStore);
          final isValid = await backupManager
              .verifyBackup(currentTask.backupPath!, fast: true);
          if (isValid) {
            Logger.info(
              'Found valid existing pre-migration backup at [${currentTask.backupPath}], skipping re-backup.',
            );
            needNewBackup = false;
          } else {
            Logger.warn(
              'Recorded backup at [${currentTask.backupPath}] is missing or invalid.',
            );
          }
        }

        if (needNewBackup) {
          Logger.info(
            'Starting scheduled backup before data migration for table [${currentTask.tableName}]...',
          );
          try {
            final path = await _dataStore.backup();
            currentTask = currentTask.copyWith(backupPath: path);
            await _saveMigrationTask(currentTask);
            _updatePendingTaskInMemory(currentTask);
          } catch (e) {
            Logger.error('Pre-migration backup failed', rawError: e);
            // In strict mode, backup failure stops the migration for safety
            if (_dataStore.config.migrationConfig?.strictMode ?? false) {
              rethrow;
            }
          }
        }
      }

      oldFieldLayout = currentTask.oldFieldLayoutSnapshot ?? oldFieldLayout;

      final needsTableWrite = _needDataMigration(sortedOperations, oldSchema);
      final specificIndexUids =
          currentTask.specificIndexUids ?? const <IndexUid>[];
      final needDataMigration =
          currentTask.writeMode != MigrationWriteMode.none &&
              (currentTask.forceDataMigration ||
                  needsTableWrite ||
                  specificIndexUids.isNotEmpty);

      if (renameOp == null && needDataMigration && oldSchema == null) {
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message:
                'Migration task [${currentTask.taskId}] for table [$currentTableName] '
                'requires old schema decoding, but no old schema snapshot is available.',
          ),
        ]);
      }

      await _invalidatePrimaryInstanceCachesForMigration(
        originalTableName: originalTableName,
        currentTableName: currentTableName,
        operations: sortedOperations,
        renameOp: renameOp,
        needDataMigration: needDataMigration,
      );

      // get latest space priority order
      final globalConfig = await _dataStore.getGlobalConfig();
      final prioritizedSpaces = globalConfig?.spaceNames.toList() ?? [];

      // sort pending spaces by priority order
      final pendingSpaces =
          List<String>.from(currentTask.pendingMigrationSpaces);
      pendingSpaces.sort((a, b) {
        if (a == _globalMigrationScope || b == _globalMigrationScope) {
          return a == _globalMigrationScope ? -1 : 1;
        }
        final isACurrent = a == _dataStore.currentSpaceName;
        final isBCurrent = b == _dataStore.currentSpaceName;
        if (isACurrent != isBCurrent) {
          return isACurrent ? -1 : 1;
        }
        final indexA = prioritizedSpaces.indexOf(a);
        final indexB = prioritizedSpaces.indexOf(b);
        return indexA.compareTo(indexB);
      });

      Logger.info(
        'Preparing to migrate data for ${pendingSpaces.length} spaces',
      );

      final taskScopes = await _getMigrationScopesForSchema(oldSchema);
      final int totalSpaces = taskScopes.isNotEmpty ? taskScopes.length : 1;

      // process data migration for each space
      for (var space in pendingSpaces) {
        if (_activeTaskProgressCallback != null) {
          final int remainingSpaces =
              pendingSpaces.length - pendingSpaces.indexOf(space);
          final progressVal = _telemetry.getTaskProgress(
            currentTask.taskId,
            totalSpaces,
            remainingSpaces,
          );
          _activeTaskProgressCallback!(progressVal);
        }
        final spaceStopwatch = Stopwatch()..start();

        final isGlobalScope = space == _globalMigrationScope;
        final reusePrimaryInstance =
            isGlobalScope || _dataStore.currentSpaceName == space;
        final migrationInstance = reusePrimaryInstance
            ? _dataStore
            : DataStoreImpl(
                dbPath: _dataStore.config.dbPath,
                dbName: _dataStore.config.dbName,
                config: _dataStore.config.copyWith(spaceName: space),
                isMigrationInstance: true,
              );

        // Track active instance
        if (!reusePrimaryInstance) {
          _activeMigrationInstances[space] = migrationInstance;
        }

        final migrationController = CancellationToken();
        _activeControllers[space] = migrationController;

        final spaceMigrationFuture = () async {
          try {
            if (!reusePrimaryInstance) {
              await migrationInstance.initialize();
            }

            // Check if table exists under either the old or new name in this space before migration.
            final isGlobalTable = oldSchema?.isGlobal ?? false;
            bool exists = false;
            final schemaMgr = migrationInstance.tableMetaManager;
            if (schemaMgr != null) {
              if (isGlobalTable) {
                exists = schemaMgr.getUidByName(TableName(originalTableName)) !=
                        null ||
                    schemaMgr.getUidByName(TableName(currentTableName)) != null;
              } else {
                final originalUid =
                    schemaMgr.getUidByName(TableName(originalTableName));
                final currentUid =
                    schemaMgr.getUidByName(TableName(currentTableName));
                final activeUids = await schemaMgr.getActiveUidsForSpace(space);
                exists =
                    (originalUid != null && activeUids.contains(originalUid)) ||
                        (currentUid != null && activeUids.contains(currentUid));
              }
            }

            if (!exists && !SystemTable.isSystemTable(originalTableName)) {
              Logger.info(
                'Skip migration for table [$originalTableName] in space [$space]: table mapping not found',
              );
              return;
            }

            final cutover = currentTask.schemaCutoverWalPointer;
            if (cutover != null) {
              // Wait until the WAL checkpoint advances past schemaCutoverWalPointer.
              // This ensures all buffered legacy-shape writes are safely flushed to disk.
              while (!_dataStore.walManager.isAtOrBefore(
                  cutover, _dataStore.walManager.meta.checkpoint)) {
                await Future.delayed(const Duration(milliseconds: 100));
              }
            }

            final migrationTableCtx =
                await migrationInstance.getTableContext(currentTableName);

            await _reconcileSchemaSideEffectsAfterSchemaCutover(
              migrationInstance,
              migrationTableCtx,
              oldSchema: oldSchema,
              targetSchema: await migrationInstance.tableMetaManager
                  ?.getTableSchema(migrationTableCtx.tableUid),
              operations: sortedOperations,
              task: currentTask,
            );

            final shouldDropTable = sortedOperations
                .any((op) => op.type == MigrationType.dropTable);
            if (shouldDropTable) {
              await migrationInstance.dropTable(
                currentTask.tableName,
                isMigration: true,
              );
            }

            // Process data migration in place after schema cutover.
            if (needDataMigration) {
              final decodeFieldStructureOverride = oldFieldLayout != null
                  ? _buildFieldStructureFromLayout(oldFieldLayout)
                  : null;

              final int writeBatchSize =
                  max(1, migrationInstance.config.writeBatchSize);

              final sourceSchema = oldSchema ??
                  await migrationInstance.tableMetaManager
                      ?.getTableSchema(migrationTableCtx.tableUid);
              if (sourceSchema == null) {
                throw DbException([
                  GeneralStatus(
                    type: ResultType.engError,
                    message:
                        'Missing source schema for migration task ${currentTask.taskId} on table ${migrationTableCtx.tableName}',
                  ),
                ]);
              }

              final sourcePkName = sourceSchema.primaryKey;

              final tableDataMeta = await migrationInstance.tableDataManager
                  .getTableDataMeta(migrationTableCtx.tableUid);
              if (tableDataMeta != null) {
                _telemetry.setCurrentSpaceExpectedRecords(
                    currentTask.taskId, tableDataMeta.totalRecords);
              }

              final startCursor = currentTask.checkpointKeyForSpace(space);

              final writeMode =
                  currentTask.writeMode ?? MigrationWriteMode.tableAndIndex;
              final specificIndexUids = currentTask.specificIndexUids != null &&
                      currentTask.specificIndexUids!.isNotEmpty
                  ? currentTask.specificIndexUids
                  : null;

              // Initialize index locks (isBuilding = true) and clean physical files in this space ONLY IF this is the first execution (no checkpoint cursor)
              if (migrationInstance.indexManager != null &&
                  currentTask.specificIndexUids != null &&
                  currentTask.specificIndexUids!.isNotEmpty) {
                final isResume = startCursor != null && startCursor.isNotEmpty;
                final targetSchema = await migrationInstance.tableMetaManager
                    ?.getTableSchema(migrationTableCtx.tableUid);
                if (targetSchema != null) {
                  final allIndexes = <IndexSchema>[
                    ...targetSchema.getAllIndexes(),
                    ...?migrationInstance.indexManager
                        ?.getEngineManagedBtreeIndexes(
                            migrationTableCtx, targetSchema),
                  ];
                  for (final indexField in currentTask.specificIndexUids!) {
                    final idxSchema = _resolveSpecificIndexSchema(
                      allIndexes,
                      indexField,
                    );
                    final indexUid = idxSchema.indexUid;
                    if (!isResume) {
                      // Only delete physical files if starting fresh
                      await migrationInstance.indexManager!
                          .deletePhysicalIndexArtifacts(
                        migrationTableCtx,
                        indexUid,
                      );
                    }

                    // Always ensure/repair metadata as isBuilding = true during ongoing migration
                    final existingMeta =
                        await migrationInstance.indexManager!.getIndexMeta(
                      migrationTableCtx.tableUid,
                      indexUid,
                    );
                    if (existingMeta == null || !existingMeta.isBuilding) {
                      final resolvedUid = indexUid;
                      final indexMeta = (existingMeta != null)
                          ? existingMeta.copyWith(isBuilding: true)
                          : IndexMeta.createEmpty(
                              indexUid: resolvedUid,
                              tableUid: migrationTableCtx.tableUid,
                              isUnique: idxSchema.unique,
                              isBuilding: true,
                            );
                      await migrationInstance.indexManager!.updateIndexMeta(
                        table: migrationTableCtx,
                        indexUid: indexUid,
                        updatedMeta: indexMeta,
                      );
                    }
                  }
                }
              }

              await migrationInstance.queryExecutor.queryEachBatch(
                migrationTableCtx,
                batchSize: 1000,
                checkpointCursor: startCursor,
                cancellationToken: migrationController,
                decodeSchema: oldSchema,
                decodeFieldStructureOverride: decodeFieldStructureOverride,
                onBatch: (records, currentCursor, nextCursor) async {
                  if (nextCursor != null) {
                    _activeReadCursors[migrationTableCtx.tableUid] = nextCursor;
                  }

                  if (migrationController.isCancelled) {
                    return false;
                  }

                  // Memory threshold backpressure control with cancellation detection
                  await migrationInstance.backgroundWriteScheduler
                      .waitIfCongested(
                    writeBatchSize,
                    migrationInstance.writeBufferManager.queueLength,
                    cancellationToken: migrationController,
                  );

                  if (migrationController.isCancelled) {
                    return false;
                  }

                  if (records.isEmpty) return true;

                  final migratedRecords = await _applyMigrationOperations(
                    records,
                    sortedOperations,
                    oldSchema: oldSchema,
                    targetSchemaVersion:
                        currentTask.targetSchemaSnapshot?.schemaVersion ?? '',
                  );

                  if (migratedRecords.isNotEmpty) {
                    final yieldController = YieldController(
                        'MigrationManager.toBackgroundScheduler',
                        checkInterval: 64);

                    for (int i = 0; i < migratedRecords.length; i++) {
                      await yieldController.maybeYield();
                      final be = migratedRecords[i];
                      final pk = be.data[sourcePkName]?.toString() ?? '';

                      final bgEntry = BackgroundWriteEntry(
                        taskId: currentTask.taskId,
                        tableUid: migrationTableCtx.tableUid,
                        primaryKey: pk,
                        type: BackgroundWriteType.schemaMigration,
                        mode: writeMode,
                        entry: be,
                        specificIndexUids: specificIndexUids,
                        currentCursor: currentCursor,
                        nextCursor: nextCursor,
                      );

                      migrationInstance.backgroundWriteScheduler
                          .addEntry(bgEntry, pk);
                    }

                    migrationInstance.parallelJournalManager
                        .scheduleFlushIfNeeded();
                  }

                  return true;
                },
              );

              if (migrationController.isCancelled) {
                throw DbClosedException('Migration stopped for space [$space]');
              }

              // Ensure all migration data is physically persisted before marking complete.
              // flushCompletely() waits until the PJM queue is fully drained to disk.
              await migrationInstance.parallelJournalManager.flushCompletely();

              // Unlock isBuilding = false
              if (migrationInstance.indexManager != null &&
                  currentTask.specificIndexUids != null &&
                  currentTask.specificIndexUids!.isNotEmpty) {
                final unlockSchema = await migrationInstance.tableMetaManager
                    ?.getTableSchema(migrationTableCtx.tableUid);
                for (final indexField in currentTask.specificIndexUids!) {
                  final idxSchema = unlockSchema != null
                      ? _resolveSpecificIndexSchema(
                          <IndexSchema>[
                            ...unlockSchema.getAllIndexes(),
                            ...?migrationInstance.indexManager
                                ?.getEngineManagedBtreeIndexes(
                                    migrationTableCtx, unlockSchema),
                          ],
                          indexField,
                        )
                      : IndexSchema(indexName: indexField, fields: const []);
                  final indexUid = idxSchema.indexUid;
                  final existingMeta = await migrationInstance.indexManager!
                      .getIndexMeta(migrationTableCtx.tableUid, indexUid);
                  if (existingMeta != null && existingMeta.isBuilding) {
                    await migrationInstance.indexManager!.updateIndexMeta(
                      table: migrationTableCtx,
                      indexUid: indexUid,
                      updatedMeta: existingMeta.copyWith(isBuilding: false),
                    );
                  }
                }
              }

              // After persistence, perform a spot check validation of the actual physical data.
              if ((_dataStore.config.migrationConfig?.validateAfterMigrate ??
                      false) &&
                  _dataStore.integrityChecker != null) {
                final schema = await migrationInstance.tableMetaManager
                    ?.getTableSchema(migrationTableCtx.tableUid);
                if (schema != null) {
                  final isValid = await _dataStore.integrityChecker!
                      .validateMigration(migrationTableCtx, schema);
                  if (!isValid &&
                      (_dataStore.config.migrationConfig?.strictMode ??
                          false)) {
                    Logger.error(
                      'Background migration validation failed for space [$space] in table [${currentTask.tableName}]. '
                      'Stopping migration for safety.',
                    );
                    // Throwing here will be caught by the outer try-finally, releasing the lease.
                    throw DbException([
                      GeneralStatus(
                        type: ResultType.sysIoDataCorrupted,
                        message:
                            'Migration data corruption detected for table ${currentTask.tableName}',
                      ),
                    ]);
                  }
                }
              }
            }

            // update task status
            currentTask = currentTask.removePendingSpace(space);
            await _saveMigrationTask(currentTask);
            _updatePendingTaskInMemory(currentTask);
          } catch (e) {
            rethrow;
          }
        }();

        _activeSpaceMigrationTasks[space] = spaceMigrationFuture;

        try {
          CrontabManager.acquireBackgroundWorkLease('migration_$space');
          await spaceMigrationFuture;
        } finally {
          CrontabManager.releaseBackgroundWorkLease('migration_$space');
          if (!reusePrimaryInstance) {
            await migrationInstance.close();
            _activeMigrationInstances.remove(space);
          }
          _activeControllers.remove(space);
          _activeSpaceMigrationTasks.remove(space);
          _activeReadCursors.remove(currentTableName);
        }

        spaceStopwatch.stop();
        Logger.info(
          'Space [$space] migration completed, time taken: ${spaceStopwatch.elapsedMilliseconds}ms',
        );
      }

      // calculate and print total time
      taskStopwatch.stop();
      _telemetry.recordTaskCompletion(currentTask, taskStopwatch.elapsed);

      // If we've processed all spaces, the task is finished
      if (currentTask.pendingMigrationSpaces.isEmpty) {
        // Record task completion stats
        final duration = taskStopwatch.elapsed;
        _telemetry.recordTaskCompletion(currentTask, duration);

        if (!SystemTable.isSystemTable(currentTask.tableName)) {
          Logger.info(
            'Migration task finished successfully: ${currentTask.taskId}, table: ${currentTask.tableName}. '
            'Summary: ${_telemetry.getTaskSummary(currentTask.taskId)}',
          );
        }

        // After successful migration, clean up the pre-migration backup to save space
        if (currentTask.backupPath != null &&
            currentTask.backupPath!.isNotEmpty) {
          _cleanupMigrationBackup(currentTask.backupPath!);
        }

        if (_activeTaskProgressCallback != null) {
          _activeTaskProgressCallback!(1.0);
        }
      }
    } catch (e) {
      if (e is DbClosedException) {
        Logger.info(
          'Migration task ${task.taskId} paused',
        );
        rethrow;
      }
      _telemetry.recordTaskFailure(task.taskId, e.toString());
      Logger.critical(GeneralStatus(
        type: ResultType.sysMigrationBatchExecutionFailed,
        message: 'Execute migration task failed: $e',
      ));

      // If a backup was made, inform the user that it has been preserved
      if (currentTask.backupPath != null) {
        Logger.critical(GeneralStatus(
          type: ResultType.sysMigrationBatchExecutionFailed,
          message:
              'CRITICAL: Migration for table [${currentTask.tableName}] failed during background data movement. '
              'To prevent overwriting new data written during migration, NO automatic restoration was performed. '
              'A safety snapshot of the state BEFORE migration is preserved at: ${currentTask.backupPath}. '
              'If you decide to restore manually using this backup, be aware that any data written after the migration started will be LOST.',
        ));
      }
      rethrow;
    } finally {
      _activeTaskProgressCallback = null;
    }
  }

  /// Sort operations to ensure they are executed in correct order
  Future<void> _reconcilePhysicalIndexesAfterSchemaCutover(
    DataStoreImpl migrationInstance,
    TableContext table, {
    required TableSchema? oldSchema,
    required TableSchema targetSchema,
    required List<MigrationOperation> operations,
  }) async {
    if (oldSchema == null || migrationInstance.tableMetaManager == null) {
      return;
    }

    // Use TableSchema.getAllIndexes() directly here. tableMetaManager caches by
    // table name, and during cutover that cache may already contain the target
    // schema for the same name; this reconciliation must compare the real old
    // snapshot against the real target schema.
    final oldIndexes = oldSchema.getAllIndexes();
    final targetIndexes = targetSchema.getAllIndexes();
    if (oldIndexes.isEmpty && targetIndexes.isEmpty) {
      return;
    }

    final fieldRenames = _buildOldToNewFieldRenameMap(operations);
    final targetByUid = <IndexUid, IndexSchema>{
      for (final index in targetIndexes)
        if (index.indexUid.isNotEmpty) index.indexUid: index,
    };
    final handledOldUids = <IndexUid>{};
    final updatedUids = <IndexUid>{};

    if (fieldRenames.isNotEmpty) {
      for (final oldIndex in oldIndexes) {
        final usesRenamedField =
            oldIndex.fields.any((field) => fieldRenames.containsKey(field));
        if (!usesRenamedField) {
          continue;
        }

        final targetIndex =
            _findIndexAfterFieldRename(oldIndex, targetIndexes, fieldRenames);
        if (targetIndex == null) {
          continue;
        }

        if (oldIndex.indexUid.isNotEmpty) {
          handledOldUids.add(oldIndex.indexUid);
        }
        bool typeChanged = false;
        for (final oldFieldName in oldIndex.fields) {
          FieldSchema? oldField;
          for (final f in oldSchema.fields) {
            if (f.name == oldFieldName) {
              oldField = f;
              break;
            }
          }
          final newFieldName = fieldRenames[oldFieldName] ?? oldFieldName;
          FieldSchema? targetField;
          for (final f in targetSchema.fields) {
            if (f.name == newFieldName) {
              targetField = f;
              break;
            }
          }
          if (oldField != null &&
              targetField != null &&
              oldField.type != targetField.type) {
            typeChanged = true;
            break;
          }
        }

        if (_sameIndexBuildDefinition(oldIndex, targetIndex,
                ignoreFields: true) &&
            !typeChanged) {
          await migrationInstance.indexManager
              ?.reconcileIndexAfterLogicalRename(
            table,
            indexUid: oldIndex.indexUid,
            legacyLogicalName: oldIndex.actualIndexName,
          );
          if (targetIndex.indexUid.isNotEmpty) {
            updatedUids.add(targetIndex.indexUid);
          }
        } else {
          await migrationInstance.indexManager
              ?.deleteIndexArtifactsForMigration(
            table,
            indexUid: oldIndex.indexUid,
          );
        }
      }
    }

    for (final oldIndex in oldIndexes) {
      final oldUid = oldIndex.indexUid;
      if (oldUid.isNotEmpty && handledOldUids.contains(oldUid)) {
        continue;
      }

      final targetIndex = oldUid.isNotEmpty
          ? targetByUid[oldUid]
          : targetIndexes.cast<IndexSchema?>().firstWhere(
                (t) => t!.actualIndexName == oldIndex.actualIndexName,
                orElse: () => null,
              );
      if (targetIndex == null) {
        if (oldUid.isNotEmpty) {
          await migrationInstance.indexManager
              ?.deleteIndexArtifactsForMigration(
            table,
            indexUid: oldUid,
          );
        }
        continue;
      }

      if (oldUid.isNotEmpty && updatedUids.contains(oldUid)) {
        continue;
      }

      bool typeChanged = false;
      for (final fieldName in oldIndex.fields) {
        FieldSchema? oldField;
        for (final f in oldSchema.fields) {
          if (f.name == fieldName) {
            oldField = f;
            break;
          }
        }
        FieldSchema? targetField;
        for (final f in targetSchema.fields) {
          if (f.name == fieldName) {
            targetField = f;
            break;
          }
        }
        if (oldField != null &&
            targetField != null &&
            oldField.type != targetField.type) {
          typeChanged = true;
          break;
        }
      }

      if (!_sameIndexBuildDefinition(oldIndex, targetIndex) || typeChanged) {
        await migrationInstance.indexManager?.deleteIndexArtifactsForMigration(
          table,
          indexUid: oldIndex.indexUid,
        );
      }
    }
  }

  Future<void> _reconcileSchemaSideEffectsAfterSchemaCutover(
    DataStoreImpl migrationInstance,
    TableContext table, {
    required TableSchema? oldSchema,
    required TableSchema? targetSchema,
    required List<MigrationOperation> operations,
    required MigrationTask task,
  }) async {
    if (targetSchema == null) {
      return;
    }

    await _reconcilePhysicalIndexesAfterSchemaCutover(
      migrationInstance,
      table,
      oldSchema: oldSchema,
      targetSchema: targetSchema,
      operations: operations,
    );

    // Clean physical indexes for referencing child tables in this space
    final droppedChildIndexes = task.referencingChildIndexesToDrop;
    if (droppedChildIndexes != null && droppedChildIndexes.isNotEmpty) {
      final schemaMgr = migrationInstance.tableMetaManager;
      if (schemaMgr != null) {
        for (final entry in droppedChildIndexes.entries) {
          final childTableUid = entry.key;
          final childSchema = await schemaMgr.getTableSchema(childTableUid);
          if (childSchema != null) {
            final childTableCtx =
                await migrationInstance.getTableContext(childSchema.name);
            for (final indexUid in entry.value) {
              await migrationInstance.indexManager
                  ?.deletePhysicalIndexArtifacts(
                childTableCtx,
                indexUid,
              );
            }
          }
        }
      }
    }
  }

  Future<void> _syncReferencingForeignKeysMetadata(
    TableContext parentTable, {
    required TableSchema targetSchema,
    required List<MigrationOperation> operations,
    Map<TableUid, List<IndexUid>>? outDroppedChildIndexes,
  }) async {
    final parentTableName = parentTable.tableName;
    final schemaMgr = _dataStore.tableMetaManager;
    final fkManager = _dataStore.foreignKeyManager;
    if (fkManager == null || schemaMgr == null) {
      return;
    }

    final referencingTables =
        await fkManager.findReferencingTables(parentTable);
    if (referencingTables.isEmpty) {
      return;
    }

    final fieldOps = operations.where((op) {
      return op.type == MigrationType.renameField ||
          op.type == MigrationType.removeField;
    }).toList(growable: false);

    for (final entry in referencingTables.entries) {
      final childTableUid = entry.key;
      final childSchema = await schemaMgr.getTableSchema(childTableUid);
      if (childSchema == null) {
        continue;
      }

      var updatedChildSchema = childSchema;
      var childChanged = false;

      for (final op in fieldOps) {
        if (op.type == MigrationType.renameField &&
            op.fieldName != null &&
            op.newName != null) {
          final renamed = _applyParentFieldRenameToChildSchema(
            updatedChildSchema,
            parentTableName.value,
            op.fieldName!,
            op.newName!,
          );
          if (renamed != null) {
            updatedChildSchema = renamed;
            childChanged = true;
          }
        } else if (op.type == MigrationType.removeField &&
            op.fieldName != null) {
          final removed = _applyParentFieldRemovalToChildSchema(
            updatedChildSchema,
            parentTableName.value,
            op.fieldName!,
          );
          if (removed != null) {
            updatedChildSchema = removed;
            childChanged = true;
          }
        }
      }

      final childFksOnParent = updatedChildSchema.foreignKeys
          .where((fk) => fk.referencedTable == parentTableName.value)
          .toList(growable: false);
      final childTableName = childSchema.name;
      for (final fk in childFksOnParent) {
        if (!updatedChildSchema.validateForeignKeyWithReferencedTable(
          fk,
          targetSchema,
        )) {
          throw DbException([
            SchemaValidationStatus(
              type: ResultType.devInvalidSchemaForeignKey,
              message:
                  'Foreign key ${fk.actualName} in table $childTableName is no longer compatible with the migrated table $parentTableName.',
              tableName: childTableName,
              field: fk.fields.join(','),
              wrongValue: {
                'fkName': fk.actualName,
                'referencedTable': parentTableName,
              },
            )
          ]);
        }
      }

      if (!childChanged) {
        continue;
      }

      final childTableCtx = schemaMgr.getTableContextSync(childTableUid);
      if (childTableCtx == null) continue;

      if (outDroppedChildIndexes != null) {
        // Regenerate auto indexes to reflect the foreign key changes in newChildIndexes
        final updatedChildSchemaWithAuto =
            updatedChildSchema.generateAutoIndexes(oldSchema: childSchema);

        final oldChildIndexes = childSchema.getAllIndexes();
        final newChildIndexes = updatedChildSchemaWithAuto.getAllIndexes();
        final droppedUids = <IndexUid>[];

        for (final oldIdx in oldChildIndexes) {
          final stillExists = oldIdx.indexUid.isNotEmpty
              ? newChildIndexes
                  .any((newIdx) => newIdx.indexUid == oldIdx.indexUid)
              : newChildIndexes.any(
                  (newIdx) => newIdx.actualIndexName == oldIdx.actualIndexName,
                );
          if (!stillExists && oldIdx.indexUid.isNotEmpty) {
            droppedUids.add(oldIdx.indexUid);
          }
        }

        if (droppedUids.isNotEmpty) {
          outDroppedChildIndexes[childTableUid] = droppedUids;
        }
      }

      final childUid = updatedChildSchema.tableUid;
      final childSchemaToSave = updatedChildSchema.copyWith(
        tableUid: childUid,
        schemaVersion: GlobalIdGenerator.generate("s"),
      );
      await schemaMgr.saveTableSchema(childTableCtx, childSchemaToSave);
      await fkManager.updateSystemTableForTable(
        childTableCtx,
        updatedChildSchema,
      );
    }
  }

  TableSchema? _applyParentFieldRenameToChildSchema(
    TableSchema childSchema,
    String parentTableName,
    String oldFieldName,
    String newFieldName,
  ) {
    var changed = false;
    final updatedForeignKeys = childSchema.foreignKeys.map((fk) {
      if (fk.referencedTable != parentTableName ||
          !fk.referencedFields.contains(oldFieldName)) {
        return fk;
      }
      changed = true;
      return fk.copyWith(
        referencedFields: fk.referencedFields
            .map((field) => field == oldFieldName ? newFieldName : field)
            .toList(growable: false),
      );
    }).toList(growable: false);

    if (!changed) {
      return null;
    }
    return childSchema.copyWith(foreignKeys: updatedForeignKeys);
  }

  TableSchema? _applyParentFieldRemovalToChildSchema(
    TableSchema childSchema,
    String parentTableName,
    String removedFieldName,
  ) {
    var changed = false;
    final updatedForeignKeys = <ForeignKeySchema>[];
    for (final fk in childSchema.foreignKeys) {
      if (fk.referencedTable == parentTableName &&
          fk.referencedFields.contains(removedFieldName)) {
        changed = true;
        continue;
      }
      updatedForeignKeys.add(fk);
    }

    if (!changed) {
      return null;
    }
    return childSchema.copyWith(foreignKeys: updatedForeignKeys);
  }

  Map<String, String> _buildOldToNewFieldRenameMap(
    List<MigrationOperation> operations,
  ) {
    final renames = <String, String>{};
    for (final operation in operations) {
      if (operation.type == MigrationType.renameField &&
          operation.fieldName != null &&
          operation.newName != null) {
        renames[operation.fieldName!] = operation.newName!;
      }
    }
    return renames;
  }

  IndexSchema? _findIndexAfterFieldRename(
    IndexSchema oldIndex,
    List<IndexSchema> targetIndexes,
    Map<String, String> fieldRenames,
  ) {
    if (oldIndex.indexUid.isNotEmpty) {
      for (final target in targetIndexes) {
        if (target.indexUid == oldIndex.indexUid) {
          return target;
        }
      }
    }

    final expectedFields = oldIndex.fields
        .map((field) => fieldRenames[field] ?? field)
        .toList(growable: false);

    for (final target in targetIndexes) {
      final sameNamedExplicitIndex = oldIndex.indexName != null &&
          target.indexName != null &&
          oldIndex.indexName == target.indexName;
      if (sameNamedExplicitIndex &&
          _sameFieldList(target.fields, expectedFields)) {
        return target;
      }

      if (oldIndex.indexName == null &&
          target.indexName == null &&
          _sameFieldList(target.fields, expectedFields)) {
        return target;
      }
    }
    return null;
  }

  bool _sameIndexBuildDefinition(
    IndexSchema a,
    IndexSchema b, {
    bool ignoreFields = false,
  }) {
    if (a.unique != b.unique || a.type != b.type) {
      return false;
    }
    if ((a.vectorConfig == null) != (b.vectorConfig == null)) {
      return false;
    }
    if (a.vectorConfig != null &&
        jsonEncode(a.vectorConfig!.toJson()) !=
            jsonEncode(b.vectorConfig!.toJson())) {
      return false;
    }
    return ignoreFields || _sameFieldList(a.fields, b.fields);
  }

  bool _sameFieldList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Sort operations to ensure they are executed in correct order
  List<MigrationOperation> _sortOperations(
      List<MigrationOperation> operations) {
    // Define operation type priority
    final typePriority = {
      MigrationType.setPrimaryKeyConfig: 1,
      MigrationType.setTableTtlConfig: 2,
      MigrationType.addIndex: 3,
      MigrationType.modifyIndex: 4,
      MigrationType.renameIndex: 5,
      MigrationType.removeIndex: 6,
      MigrationType.addField: 7,
      MigrationType.modifyField: 8,
      MigrationType.renameField: 9,
      MigrationType.removeField: 10,
      MigrationType.renameTable: 11,
      MigrationType.dropTable: 12,
    };

    // Sort operations by priority
    operations.sort((a, b) =>
        (typePriority[a.type] ?? 99).compareTo(typePriority[b.type] ?? 99));

    return operations;
  }

  /// Apply migration operations to records
  Future<List<BufferEntry>> _applyMigrationOperations(
      List<Map<String, dynamic>> records, List<MigrationOperation> operations,
      {TableSchema? oldSchema, required String targetSchemaVersion}) async {
    if (records.isEmpty || operations.isEmpty) {
      final timestamp = DateTime.now();
      return records
          .map((r) => BufferEntry(
                operation: BufferOperationType.update,
                data: r,
                timestamp: timestamp,
                walPointer: const WalPointer(partitionIndex: -1, entrySeq: 0),
                schemaVersion: targetSchemaVersion,
              ))
          .toList();
    }
    // Get max concurrent
    final maxConcurrent = _dataStore.config.maxConcurrency;

    // Batch size
    final int batchSize = (records.length / maxConcurrent).ceil();

    // Create batches
    final batches = <List<Map<String, dynamic>>>[];
    for (int i = 0; i < records.length; i += batchSize) {
      final end = min(i + batchSize, records.length);
      batches.add(records.sublist(i, end));
    }

    // Parallel processing all batches
    final batchResults =
        await Future.wait(batches.map((batch) => ComputeManager.run(
              ComputeTask(
                function: processMigrationRecords,
                message: MigrationRecordProcessRequest(
                  records: batch,
                  operations: operations,
                  oldSchema: oldSchema,
                  yieldDurationMs: _dataStore.config.yieldDurationMs,
                  targetSchemaVersion: targetSchemaVersion,
                ),
              ),
              useIsolate: records.length > 500,
            )));

    // Merge results
    final allProcessedEntries = <BufferEntry>[];
    for (final batchResult in batchResults) {
      if (batchResult.success) {
        allProcessedEntries.addAll(batchResult.migratedEntries);
      } else {
        // Critical error: fail the entire migration task to prevent data loss
        throw DbException([
          GeneralStatus(
            type: ResultType.sysMigrationBatchExecutionFailed,
            message: 'Batch migration failed: ${batchResult.errorMessage}',
          )
        ]);
      }
    }

    return allProcessedEntries;
  }

  /// Cleanup task files after completion
  Future<void> _cleanupTask(MigrationTask task) async {
    try {
      final taskPath = _dataStore.pathManager
          .getMigrationTaskPath(task.dirIndex, task.taskId);

      // Check if file exists before attempting to delete
      final fileExists = await _dataStore.storage.existsFile(taskPath);
      if (fileExists) {
        await _dataStore.storage.deleteFile(taskPath);
      }

      // Always update meta data: remove task from directory mapping
      // This ensures mapping stays consistent even if file was already deleted
      final meta = await _getOrLoadMigrationMeta();

      // Verify task still exists in mapping before removing
      if (meta.directoryMapping.getDirIndex(task.taskId) != null) {
        final updatedMapping = meta.directoryMapping.removeId(task.taskId);
        final updatedMeta = meta.copyWith(directoryMapping: updatedMapping);
        await _saveMigrationMeta(updatedMeta);
      }
    } catch (e) {
      if (e is DbClosedException) return;
      Logger.error('Cleanup migration task failed', rawError: e);
    }
  }

  /// initialize migration manager, recover unfinished tasks and sort conflict tasks to the front
  Future<void> initialize({
    List<TableSchema> userSchemas = const [],
    List<TableSchema> systemSchemas = const [],
  }) async {
    try {
      _runtimeMigrations.clear();
      await _recoverPendingSchemaTasksFromDisk(
        userSchemas: userSchemas,
        systemSchemas: systemSchemas,
      );

      await syncHasMigrationTask();
    } catch (e) {
      Logger.error('Failed to initialize migration manager', rawError: e);
    }
  }

  /// Returns a map of pending table renames: oldTableName -> newTableName
  Map<String, String> getPendingTableRenames() {
    final renames = <String, String>{};
    for (final task in _pendingTasks) {
      final renameOp = _findRenameOperation(task.operations);
      if (renameOp != null && renameOp.newTableName != null) {
        renames[task.tableName] = renameOp.newTableName!;
      }
    }
    return renames;
  }

  /// Load unfinished schema migration tasks from disk into [_pendingTasks].
  Future<void> _recoverPendingSchemaTasksFromDisk({
    List<TableSchema> userSchemas = const [],
    List<TableSchema> systemSchemas = const [],
  }) async {
    final meta = await _getOrLoadMigrationMeta();
    if (meta.directoryMapping.idToDir.isEmpty) return;

    final tasksToRemove = <String>[];

    for (final entry in meta.directoryMapping.idToDir.entries) {
      final taskId = entry.key;
      final dirIndex = entry.value;

      try {
        final taskPath =
            _dataStore.pathManager.getMigrationTaskPath(dirIndex, taskId);
        final fileExists = await _dataStore.storage.existsFile(taskPath);

        if (!fileExists) {
          Logger.warn(
            'Task file not found but exists in mapping: taskId[$taskId], dirIndex[$dirIndex], cleaning up mapping',
          );
          tasksToRemove.add(taskId);
          continue;
        }

        final taskContent = await _dataStore.storage.readAsString(taskPath);

        if (taskContent != null && taskContent.isNotEmpty) {
          final task = MigrationTask.fromJson(jsonDecode(taskContent));

          if (task.pendingMigrationSpaces.isNotEmpty) {
            if (_pendingTasks.any((t) => t.taskId == task.taskId)) continue;
            Logger.info(
              'Found unfinished migration task: taskId[${task.taskId}], table[${task.tableName}], remaining spaces[${task.pendingMigrationSpaces.length}]',
            );
            _pendingTasks.add(task);
          } else {
            Logger.info(
              'Task completed but still in mapping: taskId[$taskId], cleaning up mapping',
            );
            tasksToRemove.add(taskId);
          }
        } else {
          Logger.warn(
            'Task file is empty: taskId[$taskId], dirIndex[$dirIndex], cleaning up mapping',
          );
          tasksToRemove.add(taskId);
        }
      } catch (e) {
        Logger.warn('Failed to load task: taskId[$taskId], cleaning up mapping',
            rawError: e);
        tasksToRemove.add(taskId);
      }
    }

    if (tasksToRemove.isNotEmpty) {
      await _cleanupOrphanedMappings(tasksToRemove);
    }

    if (_pendingTasks.isNotEmpty) {
      registerSchemaVersionsFromTasks(_pendingTasks);

      // Reconcile pending tasks for recovered tables to merge or cancel redundant ops
      final uniqueTableNames = _pendingTasks.map((t) => t.tableName).toSet();
      for (final tName in uniqueTableNames) {
        await _reconcilePendingTasksForTable(await _requireTableContext(tName));
      }

      _rebuildRuntimeMigrations();
      unawaited(processMigrationTasks().catchError((e) {
        if (e is DbClosedException) {
          return MigrationTasksResult(success: false);
        }
        throw e;
      }));
    }
  }

  /// Find unfinished schema task ids; when [tableUid] is null, match any table.
  Future<List<String>> _findUnfinishedSchemaTaskIdsForTableUid(
    String? tableUid,
  ) async {
    final found = <String>[];

    for (final task in _pendingTasks) {
      if (task.pendingMigrationSpaces.isEmpty) continue;
      if (tableUid != null && task.tableUid != tableUid) continue;
      found.add(task.taskId);
    }
    if (tableUid != null && found.isNotEmpty) return found;

    final meta = await _getOrLoadMigrationMeta();
    if (meta.directoryMapping.idToDir.isEmpty) return found;

    final tasksToRemove = <String>[];
    for (final entry in meta.directoryMapping.idToDir.entries) {
      final taskId = entry.key;
      if (found.contains(taskId)) continue;

      try {
        final dirIndex = entry.value;
        final taskPath =
            _dataStore.pathManager.getMigrationTaskPath(dirIndex, taskId);
        final fileExists = await _dataStore.storage.existsFile(taskPath);
        if (!fileExists) {
          tasksToRemove.add(taskId);
          continue;
        }

        final content = await _dataStore.storage.readAsString(taskPath);
        if (content != null && content.isNotEmpty) {
          final task = MigrationTask.fromJson(jsonDecode(content));
          if (task.pendingMigrationSpaces.isEmpty) continue;
          if (tableUid != null && task.tableUid != tableUid) continue;
          found.add(taskId);
        } else {
          tasksToRemove.add(taskId);
        }
      } catch (e) {
        tasksToRemove.add(taskId);
      }
    }

    if (tasksToRemove.isNotEmpty) {
      await _cleanupOrphanedMappings(tasksToRemove);
    }

    return found;
  }

  /// Clean up orphaned task mappings (tasks that no longer exist)
  Future<void> _cleanupOrphanedMappings(List<String> taskIds) async {
    try {
      final meta = await _getOrLoadMigrationMeta();
      var updatedMapping = meta.directoryMapping;

      // Remove each orphaned task from mapping
      for (final taskId in taskIds) {
        updatedMapping = updatedMapping.removeId(taskId);
      }

      // Only save if mapping changed
      if (updatedMapping.idToDir.length !=
          meta.directoryMapping.idToDir.length) {
        final updatedMeta = meta.copyWith(directoryMapping: updatedMapping);
        await _saveMigrationMeta(updatedMeta);

        Logger.info(
          'Cleaned up ${taskIds.length} orphaned task mapping(s)',
        );
      }
    } catch (e) {
      Logger.error('Failed to cleanup orphaned mappings', rawError: e);
    }
  }

  /// check if specified space is being migrated
  Future<bool> isSpaceBeingMigrated(String spaceName) async {
    for (final task in _pendingTasks) {
      if (task.pendingMigrationSpaces.contains(spaceName)) {
        return true;
      }
    }
    return false;
  }

  /// wait for migration of specified space to complete
  Future<bool> waitForSpaceMigration(String spaceName,
      {Duration? timeout}) async {
    // create a completer to handle asynchronous waiting
    final completer = Completer<bool>();

    // create a timer to check migration status
    Timer? checkTimer;
    Timer? timeoutTimer;

    // set timeout
    if (timeout != null) {
      timeoutTimer = Timer(timeout, () {
        if (!completer.isCompleted) {
          checkTimer?.cancel();
          completer.complete(false);
        }
      });
    }

    // check migration status periodically
    checkTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      final isStillMigrating = await isSpaceBeingMigrated(spaceName);
      if (!isStillMigrating && !completer.isCompleted) {
        timer.cancel();
        timeoutTimer?.cancel();
        completer.complete(true);
      }
    });

    return completer.future;
  }

  /// query migration task status
  ///
  /// [taskId] task ID
  /// return task details, null if task does not exist
  Future<MigrationStatus?> queryTaskStatus(String taskId) async {
    try {
      // load migration meta data
      final meta = await _getOrLoadMigrationMeta();
      final dirIndex = meta.directoryMapping.getDirIndex(taskId);

      if (dirIndex == null) {
        // task completed or not exist
        return MigrationStatus(
          taskId: taskId,
          isCompleted: true, // task ID not in mapping, consider as completed
          createTime: DateTime.now(),
          pendingSpaces: const [],
          processedSpacesCount: 0,
          totalSpacesCount: 0,
          errors: const [],
          writeMode: MigrationWriteMode.none,
        );
      }

      // read task file
      final taskPath =
          _dataStore.pathManager.getMigrationTaskPath(dirIndex, taskId);

      // Check if file exists
      final fileExists = await _dataStore.storage.existsFile(taskPath);
      if (!fileExists) {
        // File doesn't exist but mapping has it - cleanup mapping
        Logger.warn(
          'Task file not found but exists in mapping: taskId[$taskId], dirIndex[$dirIndex], cleaning up mapping',
        );
        await _cleanupOrphanedMappings([taskId]);
        return MigrationStatus(
          taskId: taskId,
          isCompleted: true,
          createTime: DateTime.now(),
          pendingSpaces: const [],
          processedSpacesCount: 0,
          totalSpacesCount: 0,
          errors: const [],
          writeMode: MigrationWriteMode.none,
        );
      }

      final taskContent = await _dataStore.storage.readAsString(taskPath);

      if (taskContent == null || taskContent.isEmpty) {
        // File exists but is empty - cleanup mapping
        Logger.warn(
          'Task file is empty: taskId[$taskId], dirIndex[$dirIndex], cleaning up mapping',
        );
        await _cleanupOrphanedMappings([taskId]);
        return null;
      }

      // parse task information
      final taskJson = jsonDecode(taskContent);
      final task = MigrationTask.fromJson(taskJson);

      // get processed and pending spaces information
      final allSpaces = await _getAllSpaces();
      final pendingSpaces = task.pendingMigrationSpaces;
      final processedSpaces =
          allSpaces.where((space) => !pendingSpaces.contains(space)).length;

      // Get telemetry stats
      final stats = _telemetry._stats[taskId];

      return MigrationStatus(
        taskId: taskId,
        isCompleted: pendingSpaces.isEmpty,
        createTime: task.createTime,
        pendingSpaces: pendingSpaces,
        processedSpacesCount: processedSpaces,
        totalSpacesCount: allSpaces.length,
        totalRecordsProcessed: stats?.totalRecords ?? 0,
        throughput: stats?.calculateThroughput() ?? 0.0,
        currentSpaceProgress: stats?.calculateCurrentSpaceProgress() ?? 0.0,
        errors: task.errors ?? const [],
        writeMode: task.writeMode,
      );
    } catch (e) {
      Logger.error('Failed to query task status', rawError: e);
      return null;
    }
  }

  Future<MigrationTask> _maybeEnableDeletedSlotCompaction(
    MigrationTask task,
    List<MigrationOperation> sortedOperations,
  ) async {
    if (task.forceDataMigration) {
      return task;
    }

    var hasRemoveField = false;
    for (final op in sortedOperations) {
      if (op.type == MigrationType.removeField) {
        hasRemoveField = true;
        break;
      }
    }
    if (!hasRemoveField) {
      return task;
    }

    final schemaMgr = _dataStore.tableMetaManager;
    if (schemaMgr == null) {
      return task;
    }

    final currentTableName = task.currentTableName ??
        _resolveCurrentTableNameFromName(task.tableName, task.operations);
    final currentSchema =
        await schemaMgr.getTableSchemaByName(TableName(currentTableName));
    if (currentSchema == null) {
      return task;
    }

    final currentLayout = await schemaMgr.getTableFieldLayout(
      TableUid(task.tableUid),
      schema: currentSchema,
    );
    if (currentLayout.totalSlots == 0) {
      return task;
    }
    final deletedCount = currentLayout.deletedSlotsCount;
    final totalCount = currentLayout.totalSlots;
    final targetCompactedSlotsCount = totalCount - deletedCount;

    final hasRatioPass = currentLayout.deletedSlotsRatio >= 0.30;
    final hasCountPass = deletedCount >= 50;

    if (!hasRatioPass || !hasCountPass) {
      return task;
    }

    bool hasCollision = false;
    for (final t in _pendingTasks) {
      if (t.taskId == task.taskId) continue;
      final prevLayout = t.oldFieldLayoutSnapshot;
      if (prevLayout != null &&
          prevLayout.totalSlots == targetCompactedSlotsCount) {
        hasCollision = true;
        break;
      }
      if (t.targetSchemaSnapshot != null) {
        final targetLayout = await schemaMgr.getTableFieldLayout(
          TableUid(task.tableUid),
          schema: t.targetSchemaSnapshot,
        );
        if (targetLayout.totalSlots == targetCompactedSlotsCount) {
          hasCollision = true;
          break;
        }
      }
    }

    if (hasCollision) {
      Logger.warn(
        'Compaction of table [$currentTableName] deferred because target compacted slots count ($targetCompactedSlotsCount) '
        'collides with another pending task version total slots.',
      );
      return task;
    }

    final updatedTask = task.copyWith(
      forceDataMigration: true,
      oldFieldLayoutSnapshot: task.oldFieldLayoutSnapshot ?? currentLayout,
    );
    await _saveMigrationTask(updatedTask);
    _updatePendingTaskInMemory(updatedTask);

    Logger.info(
      'Table [$currentTableName] deleted slots ratio reached '
      '${(currentLayout.deletedSlotsRatio * 100).toStringAsFixed(1)}%, '
      'enabled background rewrite migration for task ${task.taskId} '
      'to purge deleted-slot payload values.',
    );

    return updatedTask;
  }

  /// check if the migration operations require data migration.
  Future<bool> _requiresDataMigration(
      List<MigrationOperation> operations, TableSchema oldSchema,
      {TableSchema? targetSchema, bool isAllowed = false}) async {
    final recordCount = await _dataStore.tableDataManager
        .getTableRecordCount(await _requireTableContext(oldSchema.name));

    // Check for unique index tightening (both explicit and implicit unique properties)
    if (targetSchema != null) {
      final oldIndexes = oldSchema.getAllIndexes();
      final targetIndexes = targetSchema.getAllIndexes();

      for (final newIdx in targetIndexes) {
        if (newIdx.unique) {
          final hasEquivalentOldUnique = oldIndexes.any((oldIdx) =>
              oldIdx.unique && _sameFieldList(oldIdx.fields, newIdx.fields));

          if (!hasEquivalentOldUnique) {
            if (recordCount > 0 && !isAllowed) {
              throw DbException([
                SchemaValidationStatus(
                  type: ResultType.devMigrationUniqueTighteningNotAllowed,
                  message:
                      'Adding or modifying unique index "${newIdx.actualIndexName}" is not allowed on non-empty table "${oldSchema.name}" '
                      'without explicit data migration allowance, as it may cause duplicate key errors.',
                  tableName: oldSchema.name,
                  field: newIdx.fields.join(','),
                  wrongValue: newIdx.actualIndexName,
                )
              ]);
            }
            Logger.warn(
              'Data migration required: adding or modifying unique index "${newIdx.actualIndexName}" on table "${oldSchema.name}".',
            );
            return true;
          }
        }
      }
    }

    bool isNumericType(DataType type) {
      return type == DataType.integer ||
          type == DataType.bigInt ||
          type == DataType.double;
    }

    for (final op in operations) {
      switch (op.type) {
        case MigrationType.addField:
          final field = op.field!;
          if (!field.nullable &&
              field.defaultValue == null &&
              field.defaultValueType == DefaultValueType.none) {
            if (recordCount > 0) {
              throw DbException([
                SchemaValidationStatus(
                  type: ResultType.devMigrationCannotAddNonNullField,
                  message:
                      'Cannot add non-nullable field "${field.name}" without a default value to non-empty table "${oldSchema.name}". '
                      'This operation is physically impossible and would fail during data write.',
                  tableName: oldSchema.name,
                  field: field.name,
                  wrongValue: {
                    'nullable': field.nullable,
                    'defaultValue': field.defaultValue,
                  },
                )
              ]);
            }
            Logger.warn(
              'Data migration required: adding non-nullable field "${field.name}" without a default value.',
            );
            return true;
          }
          break;
        case MigrationType.modifyField:
          final fieldUpdate = op.fieldUpdate!;
          FieldSchema? oldField;
          for (final f in oldSchema.fields) {
            if (f.name == fieldUpdate.name) {
              oldField = f;
              break;
            }
          }

          if (oldField != null) {
            // Check text to numeric high risk conversion
            if (oldField.type == DataType.text &&
                fieldUpdate.type != null &&
                isNumericType(fieldUpdate.type!)) {
              if (recordCount > 0 && !isAllowed) {
                throw DbException([
                  SchemaValidationStatus(
                    type: ResultType.devMigrationUnsafeTypeConversion,
                    message:
                        'Changing field "${fieldUpdate.name}" type from text to numeric is not allowed on non-empty table "${oldSchema.name}" '
                        'without explicit data migration allowance, as it may cause parsing errors for non-numeric data.',
                    tableName: oldSchema.name,
                    field: fieldUpdate.name,
                    wrongValue: {
                      'oldType': 'text',
                      'newType': fieldUpdate.type?.name,
                    },
                  )
                ]);
              }
            }

            // from nullable to non-nullable
            if (oldField.nullable && (fieldUpdate.nullable == false)) {
              if (recordCount > 0 && !isAllowed) {
                throw DbException([
                  SchemaValidationStatus(
                    type: ResultType.devMigrationNullableToNonNullNotAllowed,
                    message:
                        'Changing field "${fieldUpdate.name}" from nullable to non-nullable is not allowed on non-empty table "${oldSchema.name}" '
                        'without explicit data migration allowance.',
                    tableName: oldSchema.name,
                    field: fieldUpdate.name,
                    wrongValue: {
                      'oldNullable': true,
                      'newNullable': false,
                    },
                  )
                ]);
              }
              Logger.warn(
                'Data migration required: changing field "${fieldUpdate.name}" from nullable to non-nullable.',
              );
              return true;
            }
            // Type change requires migration
            if (fieldUpdate.type != null && oldField.type != fieldUpdate.type) {
              if (recordCount > 0 && !isAllowed) {
                throw DbException([
                  SchemaValidationStatus(
                    type: ResultType.devMigrationUnsafeTypeConversion,
                    message:
                        'Changing field "${fieldUpdate.name}" type from ${oldField.type} to ${fieldUpdate.type} '
                        'is not allowed on non-empty table "${oldSchema.name}" without explicit data migration allowance.',
                    tableName: oldSchema.name,
                    field: fieldUpdate.name,
                    wrongValue: {
                      'oldType': oldField.type.name,
                      'newType': fieldUpdate.type?.name,
                    },
                  )
                ]);
              }
              Logger.warn(
                'Data migration required: changing field "${fieldUpdate.name}" type from ${oldField.type} to ${fieldUpdate.type}.',
              );
              return true;
            }
            // from non-unique to unique
            if (!oldField.unique && (fieldUpdate.unique == true)) {
              if (recordCount > 0 && !isAllowed) {
                throw DbException([
                  SchemaValidationStatus(
                    type: ResultType.devMigrationUniqueTighteningNotAllowed,
                    message:
                        'Changing field "${fieldUpdate.name}" from non-unique to unique is not allowed on non-empty table "${oldSchema.name}" '
                        'without explicit data migration allowance.',
                    tableName: oldSchema.name,
                    field: fieldUpdate.name,
                    wrongValue: {
                      'oldUnique': false,
                      'newUnique': true,
                    },
                  )
                ]);
              }
              Logger.warn(
                'Data migration required: changing field "${fieldUpdate.name}" from non-unique to unique.',
              );
              return true;
            }
          }
          break;
        case MigrationType.setPrimaryKeyConfig:
          final newConfig = op.primaryKeyConfig;
          final oldConfig = oldSchema.primaryKeyConfig;
          if (newConfig != null &&
              (newConfig.name != oldConfig.name ||
                  newConfig.type != oldConfig.type)) {
            if (recordCount > 0 && !isAllowed) {
              throw DbException([
                SchemaValidationStatus(
                  type: ResultType.devInvalidSchemaPrimaryKey,
                  message:
                      'Changing primary key config is not allowed on non-empty table "${oldSchema.name}" '
                      'without explicit data migration allowance.',
                  tableName: oldSchema.name,
                  field: oldSchema.primaryKey,
                  wrongValue: {
                    'oldPrimaryKey': oldSchema.primaryKey,
                    'newPrimaryKey': newConfig.name,
                  },
                )
              ]);
            }
            Logger.warn(
              'Data migration required: changing primary key name or type.',
            );
            return true;
          }
          break;
        default:
          break;
      }
    }
    return false;
  }

  Future<void> _invalidatePrimaryInstanceCachesForMigration({
    required String originalTableName,
    required String currentTableName,
    required List<MigrationOperation> operations,
    required MigrationOperation? renameOp,
    required bool needDataMigration,
  }) async {
    if (renameOp != null) {
      await _dataStore.cacheManager.invalidateCache(
        await _requireTableContext(originalTableName),
        invalidateSchema: false,
      );
      await _dataStore.cacheManager.invalidateCache(
        await _requireTableContext(currentTableName),
        invalidateSchema: false,
      );
      return;
    }

    if (needDataMigration) {
      // Physical table records will be rewritten. Keep the freshly updated
      // schema cache, but drop all read-side/runtime caches for the table.
      await _dataStore.cacheManager.invalidateCache(
        await _requireTableContext(originalTableName),
        invalidateSchema: false,
      );
      return;
    }

    final invalidateRecordViews =
        _requiresRecordViewInvalidationWithoutDataRewrite(operations);
    final invalidateIndexCaches =
        _requiresIndexCacheInvalidationWithoutDataRewrite(operations);

    if (invalidateRecordViews || invalidateIndexCaches) {
      await _dataStore.cacheManager.invalidateCache(
        await _requireTableContext(currentTableName),
        invalidateSchema: false,
        invalidateQuery: invalidateRecordViews,
        invalidateRecords: invalidateRecordViews,
        invalidateRecordCount: false,
        invalidateTableDataMeta: false,
        invalidateTablePages: false,
        invalidateIndexData: invalidateIndexCaches,
        invalidateIndexMeta: invalidateIndexCaches,
        invalidateIndexPages: invalidateIndexCaches,
        invalidateVectorCache: invalidateIndexCaches,
      );
    }
  }

  bool _requiresRecordViewInvalidationWithoutDataRewrite(
    List<MigrationOperation> operations,
  ) {
    for (final op in operations) {
      switch (op.type) {
        case MigrationType.addField:
        case MigrationType.removeField:
        case MigrationType.renameField:
        case MigrationType.modifyField:
        case MigrationType.setPrimaryKeyConfig:
          return true;
        default:
          break;
      }
    }
    return false;
  }

  bool _requiresIndexCacheInvalidationWithoutDataRewrite(
    List<MigrationOperation> operations,
  ) {
    for (final op in operations) {
      switch (op.type) {
        case MigrationType.addField:
        case MigrationType.removeField:
        case MigrationType.renameField:
        case MigrationType.addIndex:
        case MigrationType.removeIndex:
        case MigrationType.modifyIndex:
        case MigrationType.setTableTtlConfig:
        case MigrationType.addForeignKey:
        case MigrationType.removeForeignKey:
        case MigrationType.modifyForeignKey:
          return true;
        default:
          break;
      }
    }
    return false;
  }

  /// Predict the resulting TableSchema after applying operations
  TableSchema _predictTargetSchema(
      TableSchema oldSchema, List<MigrationOperation> operations,
      {bool isAutoGenerated = false}) {
    var result = oldSchema;
    for (final op in operations) {
      switch (op.type) {
        case MigrationType.addField:
          if (op.field != null) {
            result = result.copyWith(fields: [...result.fields, op.field!]);
          }
          break;
        case MigrationType.removeField:
          if (op.fieldName != null) {
            final fieldName = op.fieldName!;
            result = result.copyWith(
              fields: result.fields.where((f) => f.name != fieldName).toList(),
              // Also remove indexes and foreign keys that depend on this field
              indexes: result.indexes
                  .where((idx) => !idx.fields.contains(fieldName))
                  .toList(),
              foreignKeys: result.foreignKeys
                  .where((fk) => !fk.fields.contains(fieldName))
                  .toList(),
              // Disable TTL if the source field is removed
              ttlConfig: result.ttlConfig?.sourceField == fieldName
                  ? null
                  : result.ttlConfig,
            );
          }
          break;
        case MigrationType.renameField:
          if (op.fieldName != null && op.newName != null) {
            final oldName = op.fieldName!;
            final newName = op.newName!;

            result = result.copyWith(
              fields: result.fields.map((f) {
                if (f.name == oldName) {
                  return f.copyWith(name: newName);
                }
                return f;
              }).toList(),
            );

            // Smart propagation for manual (imperative) updates:
            // Auto-update metadata that references this field.
            // For auto-generated (mobile) tasks, we stay strict as the user's
            // declarative definition is expected to be complete and consistent.
            if (!isAutoGenerated) {
              result = result.copyWith(
                // Update indexes
                indexes: result.indexes.map((idx) {
                  if (idx.fields.contains(oldName)) {
                    return idx.copyWith(
                      fields: idx.fields
                          .map((f) => f == oldName ? newName : f)
                          .toList(),
                    );
                  }
                  return idx;
                }).toList(),
                // Update foreign keys
                foreignKeys: result.foreignKeys.map((fk) {
                  if (fk.fields.contains(oldName)) {
                    return fk.copyWith(
                      fields: fk.fields
                          .map((f) => f == oldName ? newName : f)
                          .toList(),
                    );
                  }
                  return fk;
                }).toList(),
                // Update TTL config
                ttlConfig: result.ttlConfig?.sourceField == oldName
                    ? result.ttlConfig!.copyWith(sourceField: newName)
                    : result.ttlConfig,
              );
            }
          }
          break;
        case MigrationType.modifyField:
          if (op.fieldUpdate != null) {
            final update = op.fieldUpdate!;
            result = result.copyWith(
                fields: result.fields.map((f) {
              if (f.name == update.name) {
                return f.copyWith(
                  type: update.type ?? f.type,
                  nullable: update.nullable ?? f.nullable,
                  defaultValue: update.isExplicitlySet('defaultValue')
                      ? update.defaultValue
                      : f.defaultValue,
                  unique: update.unique ?? f.unique,
                  createIndex: update.isExplicitlySet('createIndex')
                      ? (update.unique == true ? false : true)
                      : f.createIndex,
                  comment: update.isExplicitlySet('comment')
                      ? update.comment
                      : f.comment,
                  minLength: update.isExplicitlySet('minLength')
                      ? update.minLength
                      : f.minLength,
                  maxLength: update.isExplicitlySet('maxLength')
                      ? update.maxLength
                      : f.maxLength,
                  minValue: update.isExplicitlySet('minValue')
                      ? update.minValue
                      : f.minValue,
                  maxValue: update.isExplicitlySet('maxValue')
                      ? update.maxValue
                      : f.maxValue,
                  defaultValueType:
                      update.defaultValueType ?? f.defaultValueType,
                  vectorConfig: update.vectorConfig ?? f.vectorConfig,
                );
              }
              return f;
            }).toList());
          }
          break;
        case MigrationType.addIndex:
          if (op.index != null) {
            result = result.copyWith(indexes: [...result.indexes, op.index!]);
          }
          break;
        case MigrationType.removeIndex:
          if (op.indexName != null) {
            result = result.copyWith(
              indexes: result.indexes
                  .where((idx) => idx.actualIndexName != op.indexName)
                  .toList(),
            );
          }
          break;
        case MigrationType.renameIndex:
          if (op.indexName != null && op.newName != null) {
            result = result.copyWith(
              indexes: result.indexes.map((idx) {
                if (idx.actualIndexName == op.indexName) {
                  // IndexSchema renaming usually involves updating indexName property
                  return idx.copyWith(indexName: op.newName);
                }
                return idx;
              }).toList(),
            );
          }
          break;
        case MigrationType.modifyIndex:
          if (op.indexName != null && op.index != null) {
            result = result.copyWith(
              indexes: result.indexes.map((idx) {
                if (idx.actualIndexName == op.indexName) {
                  return op.index!;
                }
                return idx;
              }).toList(),
            );
          }
          break;
        case MigrationType.addForeignKey:
          if (op.foreignKey != null) {
            result = result
                .copyWith(foreignKeys: [...result.foreignKeys, op.foreignKey!]);
          }
          break;
        case MigrationType.removeForeignKey:
          final fkName = op.foreignKeyName ?? op.indexName;
          if (fkName != null) {
            result = result.copyWith(
              foreignKeys: result.foreignKeys
                  .where((fk) => fk.actualName != fkName)
                  .toList(),
            );
          }
          break;
        case MigrationType.modifyForeignKey:
          final fkName =
              op.foreignKeyName ?? op.foreignKey?.actualName ?? op.indexName;
          if (fkName != null && op.foreignKey != null) {
            result = result.copyWith(
              foreignKeys: result.foreignKeys.map((fk) {
                if (fk.actualName == fkName) {
                  final update = op.foreignKey!;
                  return fk.copyWith(
                    onDelete: update.onDelete,
                    onUpdate: update.onUpdate,
                    enabled: update.enabled,
                    autoCreateIndex: update.autoCreateIndex,
                    comment: update.comment,
                  );
                }
                return fk;
              }).toList(),
            );
          }
          break;
        case MigrationType.dropTable:
          // This would effectively clear the schema, but typically we just
          // let it pass as the table will be deleted anyway.
          break;
        case MigrationType.renameTable:
          if (op.newTableName != null) {
            result = result.copyWith(name: op.newTableName!);
          }
          break;
        case MigrationType.setPrimaryKeyConfig:
          if (op.primaryKeyConfig != null) {
            result = result.copyWith(primaryKeyConfig: op.primaryKeyConfig);
          }
          break;
        case MigrationType.setTableTtlConfig:
          result = result.copyWith(ttlConfig: op.ttlConfig);
          break;
      }
    }
    return result;
  }

  /// Estimate migration duration based on writeMode and recordCount
  Duration _estimateMigrationDuration(
      MigrationWriteMode writeMode, int recordCount) {
    if (writeMode == MigrationWriteMode.none) {
      return const Duration(milliseconds: 5); // Base schema write overhead
    }
    double msPerRecord = 0.0;
    switch (writeMode) {
      case MigrationWriteMode.indexOnly:
        msPerRecord = 0.03;
        break;
      case MigrationWriteMode.tableOnly:
        msPerRecord = 0.08;
        break;
      case MigrationWriteMode.tableAndIndex:
        msPerRecord = 0.12;
        break;
      case MigrationWriteMode.none:
        msPerRecord = 0.0;
        break;
    }
    final calculatedMs = (recordCount * msPerRecord).round() + 5;
    return Duration(milliseconds: calculatedMs);
  }

  /// Same resource key as table CRUD writes (`table_data_manager`).
  String _tableLockResource(TableUid tableUid) =>
      _dataStore.getScopedResourceKey('table_${tableUid.value}');

  /// Resolve a user-visible table name for error messages (never expose raw uid).
  Future<String> _resolveTableDisplayName(
    TableUid tableUid, {
    TableSchema? schemaHint,
  }) async {
    if (schemaHint != null && schemaHint.name.isNotEmpty) {
      return schemaHint.name;
    }
    final routed = _dataStore.tableMetaManager?.getNameByUid(tableUid);
    if (routed != null && routed.isNotEmpty) {
      return routed.value;
    }
    final schema = await _dataStore.tableMetaManager?.getTableSchema(tableUid);
    if (schema != null && schema.name.isNotEmpty) {
      return schema.name;
    }
    return 'unknown';
  }

  /// Remove operations already satisfied by storage state.
  ///
  /// For runtime [updateSchema] ([isAutoGenerated] false), conflicts with the
  /// effective schema (e.g. duplicate addField) throw semantic errors.
  ///
  /// For mobile/startup declarative migrations ([isAutoGenerated] true), only
  /// the caller-provided [declaredTargetSchema] is treated as the source of
  /// truth. Partial cutover from a prior crash must be idempotent: if storage
  /// already reflects the declared target, ops are silently dropped and startup
  /// must never fail with "already exists" style errors.
  Future<List<MigrationOperation>> _foldRedundantMigrationOperations({
    required TableSchema effectiveSchema,
    required List<MigrationOperation> operations,
    required TableUid tableUid,
    required TableContext table,
    required String tableName,
    required bool isAutoGenerated,
    TableSchema? declaredTargetSchema,
  }) async {
    final folded = <MigrationOperation>[];

    for (final op in operations) {
      switch (op.type) {
        case MigrationType.addField:
          final field = op.field;
          if (field == null) {
            folded.add(op);
            break;
          }
          final existingField = _findFieldByName(effectiveSchema, field.name);
          if (existingField == null) {
            folded.add(op);
            break;
          }
          if (_areFieldDefinitionsEqual(existingField, field)) {
            break;
          }
          if (isAutoGenerated) {
            final declaredField =
                _findFieldByName(declaredTargetSchema, field.name);
            if (declaredField != null &&
                _areFieldDefinitionsEqual(existingField, declaredField)) {
              break;
            }
            _warnAutoGeneratedStorageDrift(
              'Table [$tableName] field [${field.name}] is already present in storage after a partial migration; '
              'skipping redundant addField so startup can continue.',
            );
            break;
          }
          throw DbException([
            SchemaValidationStatus(
              type: ResultType.devSchemaFieldExists,
              message:
                  'Cannot add field [${field.name}] to table [$tableName]: field already exists.',
              tableName: tableName,
              field: field.name,
            ),
          ]);

        case MigrationType.removeField:
          final fieldName = op.fieldName;
          if (fieldName == null) {
            folded.add(op);
            break;
          }
          if (_findFieldByName(effectiveSchema, fieldName) == null) {
            break;
          }
          folded.add(op);
          break;

        case MigrationType.renameField:
          final fromName = op.fieldName;
          final toName = op.newName;
          if (fromName == null || toName == null) {
            folded.add(op);
            break;
          }
          if (_findFieldByName(effectiveSchema, fromName) == null) {
            if (_findFieldByName(effectiveSchema, toName) != null) {
              break;
            }
            if (isAutoGenerated) {
              break;
            }
            throw DbException([
              SchemaValidationStatus(
                type: ResultType.devInvalidSchemaFieldName,
                message:
                    'Cannot rename field [$fromName] in table [$tableName]: field does not exist.',
                tableName: tableName,
                field: fromName,
              ),
            ]);
          }
          if (_findFieldByName(effectiveSchema, toName) != null) {
            break;
          }
          folded.add(op);
          break;

        case MigrationType.modifyField:
          final update = op.fieldUpdate;
          if (update == null) {
            folded.add(op);
            break;
          }
          final existingField = _findFieldByName(effectiveSchema, update.name);
          if (existingField == null) {
            if (isAutoGenerated) {
              final declaredField =
                  _findFieldByName(declaredTargetSchema, update.name);
              if (declaredField != null &&
                  _areFieldDefinitionsEqual(
                    declaredField,
                    _applyFieldSchemaUpdate(declaredField, update),
                  )) {
                break;
              }
              _warnAutoGeneratedStorageDrift(
                'Table [$tableName] modifyField [${update.name}] skipped because the field is absent in storage after a partial migration.',
              );
              break;
            }
            throw DbException([
              SchemaValidationStatus(
                type: ResultType.devInvalidSchemaFieldName,
                message:
                    'Cannot modify field [${update.name}] in table [$tableName]: field does not exist.',
                tableName: tableName,
                field: update.name,
              ),
            ]);
          }
          if (_areFieldDefinitionsEqual(
            existingField,
            _applyFieldSchemaUpdate(existingField, update),
          )) {
            break;
          }
          if (isAutoGenerated) {
            final declaredField =
                _findFieldByName(declaredTargetSchema, update.name);
            if (declaredField != null &&
                _areFieldDefinitionsEqual(existingField, declaredField)) {
              break;
            }
          }
          folded.add(op);
          break;

        case MigrationType.addIndex:
          final index = op.index;
          if (index == null) {
            folded.add(op);
            break;
          }
          final existingIndex =
              _findMatchingIndexInSchema(effectiveSchema, index, table);
          if (existingIndex == null) {
            folded.add(op);
            break;
          }
          if (!_isIndexModified(existingIndex, index)) {
            break;
          }
          if (isAutoGenerated) {
            final declaredIndex = _findMatchingIndexInDeclarativeTarget(
              declaredTargetSchema,
              index,
            );
            if (declaredIndex != null &&
                !_isIndexModified(existingIndex, declaredIndex)) {
              break;
            }
            _warnAutoGeneratedStorageDrift(
              'Table [$tableName] index [${index.actualIndexName}] is already present in storage after a partial migration; '
              'skipping redundant addIndex so startup can continue.',
            );
            break;
          }
          throw DbException([
            SchemaValidationStatus(
              type: ResultType.devSchemaIndexExists,
              message:
                  'Index [${index.actualIndexName}] on table [$tableName] already exists.',
              tableName: tableName,
              field: index.fields.join(','),
              wrongValue: index.actualIndexName,
            ),
          ]);

        case MigrationType.removeIndex:
          final resolvedName = op.indexName;
          if (resolvedName == null &&
              (op.fields == null || op.fields!.isEmpty)) {
            folded.add(op);
            break;
          }
          if (_resolveIndexInSchema(
                effectiveSchema,
                indexName: resolvedName,
                fields: op.fields,
                table: table,
              ) ==
              null) {
            break;
          }
          folded.add(op);
          break;

        case MigrationType.modifyIndex:
          final indexName = op.indexName;
          final index = op.index;
          if (indexName == null || index == null) {
            folded.add(op);
            break;
          }
          final existingIndex = _resolveIndexInSchema(
            effectiveSchema,
            indexName: indexName,
            fields: op.fields ?? index.fields,
            table: table,
          );
          if (existingIndex == null) {
            if (isAutoGenerated) {
              break;
            }
            folded.add(op);
            break;
          }
          if (!_isIndexModified(existingIndex, index)) {
            break;
          }
          if (isAutoGenerated) {
            final declaredIndex = _resolveIndexInDeclarativeTarget(
              declaredTargetSchema,
              indexName: indexName,
              fields: op.fields ?? index.fields,
            );
            if (declaredIndex != null &&
                !_isIndexModified(existingIndex, declaredIndex)) {
              break;
            }
          }
          folded.add(op);
          break;

        case MigrationType.renameIndex:
          final fromName = op.indexName;
          final toName = op.newName;
          if (fromName == null || toName == null) {
            folded.add(op);
            break;
          }
          final existingIndex = _resolveIndexInSchema(
            effectiveSchema,
            indexName: fromName,
            fields: op.fields,
            table: table,
          );
          if (existingIndex == null) {
            final targetIndex = _resolveIndexInSchema(
              effectiveSchema,
              indexName: toName,
              fields: op.fields,
              table: table,
            );
            if (targetIndex != null) {
              break;
            }
            if (isAutoGenerated) {
              break;
            }
            throw DbException([
              SchemaValidationStatus(
                type: ResultType.devInvalidSchemaIndexField,
                message:
                    'Cannot rename index [$fromName] in table [$tableName]: index does not exist.',
                tableName: tableName,
                field: fromName,
              ),
            ]);
          }
          if (existingIndex.actualIndexName == toName ||
              existingIndex.indexName == toName) {
            break;
          }
          folded.add(op);
          break;

        case MigrationType.addForeignKey:
          final fk = op.foreignKey;
          if (fk == null) {
            folded.add(op);
            break;
          }
          final existingFk = _findForeignKeyInSchema(effectiveSchema, fk);
          if (existingFk == null) {
            folded.add(op);
            break;
          }
          if (_areForeignKeyDefinitionsEqual(existingFk, fk)) {
            break;
          }
          if (isAutoGenerated) {
            final declaredFk = declaredTargetSchema != null
                ? _findForeignKeyInSchema(declaredTargetSchema, fk)
                : null;
            if (declaredFk != null &&
                _areForeignKeyDefinitionsEqual(existingFk, declaredFk)) {
              break;
            }
            _warnAutoGeneratedStorageDrift(
              'Table [$tableName] foreign key [${fk.actualName}] is already present in storage after a partial migration; '
              'skipping redundant addForeignKey so startup can continue.',
            );
            break;
          }
          throw DbException([
            SchemaValidationStatus(
              type: ResultType.devInvalidSchemaForeignKey,
              message:
                  'Foreign key [${fk.actualName}] already exists in table [$tableName] with a different definition.',
              tableName: tableName,
              field: fk.fields.join(','),
            ),
          ]);

        case MigrationType.removeForeignKey:
          final fkName = op.foreignKeyName;
          if (fkName == null) {
            folded.add(op);
            break;
          }
          if (_findForeignKeyByName(effectiveSchema, fkName) == null) {
            break;
          }
          folded.add(op);
          break;

        case MigrationType.modifyForeignKey:
          final fkName = op.foreignKeyName ?? op.foreignKey?.actualName;
          final update = op.foreignKey;
          if (fkName == null || update == null) {
            folded.add(op);
            break;
          }
          final existingFk = _findForeignKeyByName(effectiveSchema, fkName);
          if (existingFk == null) {
            if (isAutoGenerated) {
              break;
            }
            folded.add(op);
            break;
          }
          final merged = existingFk.copyWith(
            onDelete: update.onDelete,
            onUpdate: update.onUpdate,
            enabled: update.enabled,
            autoCreateIndex: update.autoCreateIndex,
            comment: update.comment,
          );
          if (_areForeignKeyDefinitionsEqual(existingFk, merged)) {
            break;
          }
          if (isAutoGenerated) {
            final declaredFk =
                _findForeignKeyByName(declaredTargetSchema, fkName);
            if (declaredFk != null &&
                _areForeignKeyDefinitionsEqual(existingFk, declaredFk)) {
              break;
            }
          }
          folded.add(op);
          break;

        case MigrationType.renameTable:
          final newName = op.newTableName;
          if (newName == null) {
            folded.add(op);
            break;
          }
          if (effectiveSchema.name == newName) {
            break;
          }
          folded.add(op);
          break;

        case MigrationType.setPrimaryKeyConfig:
          final newConfig = op.primaryKeyConfig;
          if (newConfig == null) {
            folded.add(op);
            break;
          }
          if (_arePrimaryKeyConfigsEqual(
              effectiveSchema.primaryKeyConfig, newConfig)) {
            break;
          }
          if (isAutoGenerated &&
              declaredTargetSchema != null &&
              _arePrimaryKeyConfigsEqual(
                effectiveSchema.primaryKeyConfig,
                declaredTargetSchema.primaryKeyConfig,
              )) {
            break;
          }
          folded.add(op);
          break;

        case MigrationType.setTableTtlConfig:
          if (_areTtlConfigsEqual(effectiveSchema.ttlConfig, op.ttlConfig)) {
            break;
          }
          if (isAutoGenerated &&
              declaredTargetSchema != null &&
              _areTtlConfigsEqual(
                effectiveSchema.ttlConfig,
                declaredTargetSchema.ttlConfig,
              )) {
            break;
          }
          folded.add(op);
          break;

        case MigrationType.dropTable:
          if (_hasPendingDropTaskForTable(tableUid)) {
            break;
          }
          folded.add(op);
          break;
      }
    }

    return _sortOperations(folded);
  }

  void _warnAutoGeneratedStorageDrift(String message) {
    Logger.warn(message);
  }

  FieldSchema? _findFieldByName(TableSchema? schema, String name) {
    if (schema == null) return null;
    for (final field in schema.fields) {
      if (field.name == name) {
        return field;
      }
    }
    return null;
  }

  IndexSchema? _findMatchingIndexInDeclarativeTarget(
    TableSchema? schema,
    IndexSchema candidate,
  ) {
    if (schema == null) return null;
    for (final idx in schema.getAllIndexes()) {
      if (candidate.indexUid.isNotEmpty && idx.indexUid == candidate.indexUid) {
        return idx;
      }
      if (_areIndexesSame(idx, candidate)) {
        return idx;
      }
    }
    return null;
  }

  IndexSchema? _resolveIndexInDeclarativeTarget(
    TableSchema? schema, {
    String? indexName,
    List<String>? fields,
  }) {
    if (schema == null) return null;
    final indexes = schema.getAllIndexes();
    if (indexName != null) {
      for (final idx in indexes) {
        if (idx.actualIndexName == indexName || idx.indexName == indexName) {
          return idx;
        }
      }
    }
    if (fields != null && fields.isNotEmpty) {
      for (final idx in indexes) {
        if (_areIndexFieldsEqual(idx.fields, fields)) {
          return idx;
        }
      }
    }
    return null;
  }

  ForeignKeySchema? _findForeignKeyByName(
    TableSchema? schema,
    String foreignKeyName,
  ) {
    if (schema == null) return null;
    for (final fk in schema.foreignKeys) {
      if (fk.actualName == foreignKeyName) {
        return fk;
      }
    }
    return null;
  }

  bool _areFieldDefinitionsEqual(FieldSchema a, FieldSchema b) {
    return a.type == b.type &&
        a.nullable == b.nullable &&
        a.defaultValue == b.defaultValue &&
        a.unique == b.unique &&
        a.createIndex == b.createIndex &&
        a.maxLength == b.maxLength &&
        a.minLength == b.minLength &&
        a.minValue == b.minValue &&
        a.maxValue == b.maxValue &&
        a.defaultValueType == b.defaultValueType &&
        a.vectorConfig == b.vectorConfig;
  }

  FieldSchema _applyFieldSchemaUpdate(
    FieldSchema existing,
    FieldSchemaUpdate update,
  ) {
    return existing.copyWith(
      type: update.type ?? existing.type,
      nullable: update.nullable ?? existing.nullable,
      defaultValue: update.isExplicitlySet('defaultValue')
          ? update.defaultValue
          : existing.defaultValue,
      unique: update.unique ?? existing.unique,
      comment:
          update.isExplicitlySet('comment') ? update.comment : existing.comment,
      minLength: update.isExplicitlySet('minLength')
          ? update.minLength
          : existing.minLength,
      maxLength: update.isExplicitlySet('maxLength')
          ? update.maxLength
          : existing.maxLength,
      minValue: update.isExplicitlySet('minValue')
          ? update.minValue
          : existing.minValue,
      maxValue: update.isExplicitlySet('maxValue')
          ? update.maxValue
          : existing.maxValue,
      defaultValueType: update.defaultValueType ?? existing.defaultValueType,
      vectorConfig: update.vectorConfig ?? existing.vectorConfig,
    );
  }

  List<IndexSchema> _allIndexesForSchema(
      TableSchema schema, TableContext table) {
    return <IndexSchema>[
      ...schema.getAllIndexes(),
      ...?_dataStore.indexManager?.getEngineManagedBtreeIndexes(table, schema),
    ];
  }

  IndexSchema? _findMatchingIndexInSchema(
    TableSchema schema,
    IndexSchema candidate,
    TableContext table,
  ) {
    final indexes = _allIndexesForSchema(schema, table);
    if (candidate.indexUid.isNotEmpty) {
      for (final idx in indexes) {
        if (idx.indexUid == candidate.indexUid) {
          return idx;
        }
      }
    }
    for (final idx in indexes) {
      if (_areIndexesSame(idx, candidate)) {
        return idx;
      }
    }
    return null;
  }

  IndexSchema? _resolveIndexInSchema(
    TableSchema schema, {
    String? indexName,
    List<String>? fields,
    required TableContext table,
  }) {
    final indexes = _allIndexesForSchema(schema, table);
    if (indexName != null) {
      for (final idx in indexes) {
        if (idx.actualIndexName == indexName || idx.indexName == indexName) {
          return idx;
        }
      }
      final byField = _dataStore.tableMetaManager?.findIndexSchemaByField(
        schema,
        indexName,
      );
      if (byField != null) {
        return byField;
      }
    }
    if (fields != null && fields.isNotEmpty) {
      for (final idx in indexes) {
        if (_areIndexFieldsEqual(idx.fields, fields)) {
          return idx;
        }
      }
    }
    return null;
  }

  ForeignKeySchema? _findForeignKeyInSchema(
    TableSchema? schema,
    ForeignKeySchema candidate,
  ) {
    if (schema == null) return null;
    final byName = _findForeignKeyByName(schema, candidate.actualName);
    if (byName != null) {
      return byName;
    }
    for (final fk in schema.foreignKeys) {
      if (_areFieldListsEqual(fk.fields, candidate.fields) &&
          fk.referencedTable == candidate.referencedTable &&
          _areFieldListsEqual(
              fk.referencedFields, candidate.referencedFields)) {
        return fk;
      }
    }
    return null;
  }

  bool _areForeignKeyDefinitionsEqual(
    ForeignKeySchema a,
    ForeignKeySchema b,
  ) {
    return _areFieldListsEqual(a.fields, b.fields) &&
        a.referencedTable == b.referencedTable &&
        _areFieldListsEqual(a.referencedFields, b.referencedFields) &&
        a.onDelete == b.onDelete &&
        a.onUpdate == b.onUpdate &&
        a.enabled == b.enabled &&
        a.autoCreateIndex == b.autoCreateIndex &&
        a.comment == b.comment;
  }

  bool _arePrimaryKeyConfigsEqual(
    PrimaryKeyConfig a,
    PrimaryKeyConfig b,
  ) {
    return a.name == b.name && a.type == b.type;
  }

  bool _areTtlConfigsEqual(TableTtlConfig? a, TableTtlConfig? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return a == b;
    return a.ttlMs == b.ttlMs && a.sourceField == b.sourceField;
  }

  bool _hasPendingDropTaskForTable(TableUid tableUid) {
    for (final task in _pendingTasks) {
      if (task.tableUid != tableUid) continue;
      if (task.operations.any((op) => op.type == MigrationType.dropTable)) {
        return true;
      }
    }
    return false;
  }

  Future<void> _applyPendingTaskIndexReconcile(
    MigrationTask task, {
    required List<IndexUid> updatedSpecificIndexes,
    required String cancelReason,
  }) async {
    var updatedTask = task.copyWith(specificIndexUids: updatedSpecificIndexes);

    if (updatedSpecificIndexes.isEmpty) {
      if (updatedTask.writeMode == MigrationWriteMode.indexOnly) {
        updatedTask = updatedTask.copyWith(writeMode: MigrationWriteMode.none);
      } else if (updatedTask.writeMode == MigrationWriteMode.tableAndIndex) {
        updatedTask =
            updatedTask.copyWith(writeMode: MigrationWriteMode.tableOnly);
      }
    }

    final isTaskStarted = await _isMigrationTaskPhysicallyStarted(task);
    if (updatedTask.writeMode == MigrationWriteMode.none &&
        !updatedTask.forceDataMigration &&
        updatedTask.isSchemaUpdated &&
        !isTaskStarted) {
      _pendingTasks.removeWhere((t) => t.taskId == task.taskId);
      await _cleanupTask(task);
      _unregisterRuntimeMigrationForTask(task);
      Logger.info(
        'Cancelled redundant migration task [${task.taskId}] on table [${task.tableName}] due to $cancelReason',
      );
      return;
    }

    await _saveMigrationTask(updatedTask);
    _updatePendingTaskInMemory(updatedTask);
  }

  /// Whether background data migration has started (checkpoints or partial spaces).
  Future<bool> _isMigrationTaskPhysicallyStarted(MigrationTask task) async {
    if (task.taskId == _activeExecutingTaskId) {
      return true;
    }
    if (task.spaceCheckpointKeys.isNotEmpty) {
      return true;
    }
    final scopes = await _getMigrationScopesForSchema(
      task.targetSchemaSnapshot ?? task.oldSchemaSnapshot,
    );
    return task.pendingMigrationSpaces.length < scopes.length;
  }

  /// Reconcile already-queued pending tasks for one table.
  ///
  /// Unlike [_foldRedundantMigrationOperations] (ingress filter for a new task),
  /// this mutates existing tasks after enqueue or disk recovery: trims redundant
  /// index builds and merges chained table renames.
  Future<void> _reconcilePendingTasksForTable(TableContext table) async {
    final pending = <MigrationTask>[..._pendingTasks];
    if (pending.isEmpty) return;

    MigrationTask? seed;
    for (final task in pending) {
      if (_taskMatchesTable(task, table, '')) {
        seed = task;
        break;
      }
    }
    if (seed == null) return;

    final component = _collectLinkedPendingTasks(pending, seed);
    if (component.length < 2) return;

    // Sort by createTime
    component.sort((a, b) {
      final c = a.createTime.compareTo(b.createTime);
      if (c != 0) return c;
      return a.taskId.compareTo(b.taskId);
    });

    // 1. Reconcile index builds across chained tasks (newest wins):
    //    - drop builds for indexes removed by newer tasks
    //    - deduplicate identical IndexUid builds claimed by newer tasks
    final removedIndexes = <String>{};
    final claimedIndexUids = <String>{};
    for (int i = component.length - 1; i >= 0; i--) {
      final taskId = component[i].taskId;
      final pendingIndex = _pendingTasks.indexWhere((t) => t.taskId == taskId);
      if (pendingIndex < 0) continue;
      final task = _pendingTasks[pendingIndex];

      if (task.specificIndexUids != null &&
          task.specificIndexUids!.isNotEmpty) {
        final isTaskStarted = await _isMigrationTaskPhysicallyStarted(task);
        final List<IndexUid> updatedSpecificIndexes;
        if (isTaskStarted) {
          updatedSpecificIndexes = task.specificIndexUids!;
        } else {
          updatedSpecificIndexes = task.specificIndexUids!
              .where((idx) =>
                  !removedIndexes.contains(idx.value) &&
                  !claimedIndexUids.contains(idx.value))
              .toList();
        }

        claimedIndexUids.addAll(
          updatedSpecificIndexes.map((uid) => uid.value),
        );

        if (updatedSpecificIndexes.length != task.specificIndexUids!.length) {
          await _applyPendingTaskIndexReconcile(
            task,
            updatedSpecificIndexes: updatedSpecificIndexes,
            cancelReason: 'index reconciliation',
          );
        }
      }

      for (final op in task.operations) {
        if (op.type == MigrationType.removeIndex && op.indexName != null) {
          removedIndexes.add(op.indexName!);
          final schema = task.targetSchemaSnapshot ?? task.oldSchemaSnapshot;
          if (schema != null) {
            final idx = _dataStore.tableMetaManager
                ?.findIndexSchemaByField(schema, op.indexName!);
            if (idx != null) {
              _markIndexRemoved(removedIndexes, idx);
            }
          }
        }
      }
      if (task.targetSchemaSnapshot != null) {
        final targetIdxNames = task.targetSchemaSnapshot!
            .getAllIndexes()
            .map((idx) => idx.actualIndexName)
            .toSet();
        final targetIdxUids = task.targetSchemaSnapshot!
            .getAllIndexes()
            .map((idx) => idx.indexUid.value)
            .toSet();
        if (task.oldSchemaSnapshot != null) {
          for (final oldIdx in task.oldSchemaSnapshot!.getAllIndexes()) {
            if (!targetIdxNames.contains(oldIdx.actualIndexName) &&
                !targetIdxUids.contains(oldIdx.indexUid.value)) {
              _markIndexRemoved(removedIndexes, oldIdx);
            }
          }
        }
      }
    }

    // Refresh component after index reconciliation
    final refreshedPending = <MigrationTask>[..._pendingTasks];
    final refreshedComponent =
        _collectLinkedPendingTasks(refreshedPending, seed)
          ..sort((a, b) {
            final c = a.createTime.compareTo(b.createTime);
            if (c != 0) return c;
            return a.taskId.compareTo(b.taskId);
          });

    // 2. Chained table rename merging
    for (int i = 0; i < refreshedComponent.length - 1; i++) {
      final taskA = refreshedComponent[i];
      final renameOpA = _findRenameOperation(taskA.operations);
      if (renameOpA == null || renameOpA.newTableName == null) continue;

      final isTaskAStarted = await _isMigrationTaskPhysicallyStarted(taskA);
      if (isTaskAStarted) continue;

      for (int j = i + 1; j < refreshedComponent.length; j++) {
        final taskB = refreshedComponent[j];
        final renameOpB = _findRenameOperation(taskB.operations);
        if (renameOpB == null || renameOpB.newTableName == null) continue;

        final isTaskBStarted = await _isMigrationTaskPhysicallyStarted(taskB);
        if (isTaskBStarted) continue;

        if (renameOpA.newTableName == taskB.tableName) {
          final finalNewName = renameOpB.newTableName!;

          // Update taskA rename operation and schema snapshot
          final updatedOpsA = taskA.operations.map((op) {
            if (op.type == MigrationType.renameTable) {
              return MigrationOperation(
                type: MigrationType.renameTable,
                newTableName: finalNewName,
              );
            }
            return op;
          }).toList();

          TableSchema? updatedTargetSchemaA = taskA.targetSchemaSnapshot;
          if (updatedTargetSchemaA != null) {
            updatedTargetSchemaA =
                updatedTargetSchemaA.copyWith(name: finalNewName);
          }

          var updatedTaskA = taskA.copyWith(
            operations: updatedOpsA,
            targetSchemaSnapshot: updatedTargetSchemaA,
          );

          await _saveMigrationTask(updatedTaskA);
          _updatePendingTaskInMemory(updatedTaskA);

          // Update/Remove taskB rename operation
          final updatedOpsB = taskB.operations
              .where((op) => op.type != MigrationType.renameTable)
              .toList();

          if (updatedOpsB.isEmpty) {
            _pendingTasks.removeWhere((t) => t.taskId == taskB.taskId);
            await _cleanupTask(taskB);
            _unregisterRuntimeMigrationForTask(taskB);
          } else {
            final updatedOldSchemaB =
                taskB.oldSchemaSnapshot?.copyWith(name: finalNewName);
            var updatedTaskB = taskB.copyWith(
              oldSchemaSnapshot: updatedOldSchemaB,
              operations: updatedOpsB,
            );
            await _saveMigrationTask(updatedTaskB);
            _updatePendingTaskInMemory(updatedTaskB);
          }

          Logger.info(
              'Merged chained rename tasks for table [${taskA.tableName}]: rename directly to $finalNewName');
          break;
        }
      }
    }

    _rebuildRuntimeMigrations(table.tableUid);
  }
}

/// table rename detection result
class RenamedTableResult {
  /// rename table mapping {old table name: new table structure}
  final Map<String, TableSchema> renamedTables;

  /// tables to create
  final List<String> tablesToCreate;

  /// tables to drop
  final List<String> tablesToDrop;

  const RenamedTableResult({
    required this.renamedTables,
    required this.tablesToCreate,
    required this.tablesToDrop,
  });
}

class _MigrationTelemetry {
  final Map<String, _TaskStats> _stats = {};

  double getTaskProgress(String taskId, int totalSpaces, int remainingSpaces) {
    final s = _stats[taskId];
    if (s == null || totalSpaces <= 0) return 0.0;
    final completedSpaces = totalSpaces - remainingSpaces;
    final double currentSpaceProgress = s.calculateCurrentSpaceProgress();
    return ((completedSpaces + currentSpaceProgress) / totalSpaces)
        .clamp(0.0, 1.0);
  }

  void recordTaskStart(String taskId) {
    _stats.putIfAbsent(taskId, () => _TaskStats(taskId)).startTime =
        DateTime.now();
  }

  void setCurrentSpaceExpectedRecords(String taskId, int expected) {
    final s = _stats.putIfAbsent(taskId, () => _TaskStats(taskId));
    s.currentSpaceExpectedRecords = expected;
    s.currentSpaceProcessedRecords = 0;
  }

  void recordRecordsProcessed(String taskId, int count) {
    final s = _stats.putIfAbsent(taskId, () => _TaskStats(taskId));
    s.totalRecords += count;
    s.currentSpaceProcessedRecords += count;
  }

  void recordTaskCompletion(MigrationTask task, Duration duration) {
    final s = _stats.putIfAbsent(task.taskId, () => _TaskStats(task.taskId));
    s.duration = duration;
    s.success = true;
    s.endTime = DateTime.now();
  }

  void recordTaskFailure(String taskId, String error) {
    final s = _stats.putIfAbsent(taskId, () => _TaskStats(taskId));
    s.success = false;
    s.lastError = error;
    s.endTime = DateTime.now();
  }

  String getTaskSummary(String taskId) {
    final s = _stats[taskId];
    if (s == null) return 'No stats';
    final throughput = s.calculateThroughput();
    return 'Duration: ${s.duration?.inMilliseconds ?? 0}ms, '
        'Records: ${s.totalRecords}, '
        'Throughput: ${throughput.toStringAsFixed(1)} rec/s, '
        'Success: ${s.success}';
  }
}

class _TaskStats {
  final String taskId;
  Duration? duration;
  bool success = false;
  String? lastError;
  DateTime? endTime;
  DateTime? startTime;
  int totalRecords = 0;
  int currentSpaceExpectedRecords = 0;
  int currentSpaceProcessedRecords = 0;

  _TaskStats(this.taskId);

  double calculateThroughput() {
    final start = startTime;
    if (start == null) return 0.0;
    final end = endTime ?? DateTime.now();
    final elapsedMs = end.difference(start).inMilliseconds;
    if (elapsedMs <= 0) return 0.0;
    return (totalRecords / (elapsedMs / 1000.0));
  }

  double calculateCurrentSpaceProgress() {
    if (currentSpaceExpectedRecords <= 0) return 0.0;
    return (currentSpaceProcessedRecords / currentSpaceExpectedRecords)
        .clamp(0.0, 1.0);
  }
}

class _RuntimeMigrationDescriptor {
  final String taskId;
  final TableUid tableUid;
  final Set<String> tableAliases;
  final TableSchema oldSchema;
  final List<MigrationOperation> operations;
  final List<FieldStructure> oldFieldStruct;
  final WalPointer? cutoverPointer;
  final Uint8List? currentSpaceCheckpointKey;

  const _RuntimeMigrationDescriptor({
    required this.taskId,
    required this.tableUid,
    required this.tableAliases,
    required this.oldSchema,
    required this.operations,
    required this.oldFieldStruct,
    required this.cutoverPointer,
    required this.currentSpaceCheckpointKey,
  });
}

class BgTaskProgress {
  final String? checkpointKey;
  final int count;

  BgTaskProgress({this.checkpointKey, required this.count});
}

class MigrationTasksResult {
  final bool success;
  final List<dynamic> errors;

  MigrationTasksResult({required this.success, this.errors = const []});
}
