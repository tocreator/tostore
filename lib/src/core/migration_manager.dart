import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../handler/binary_schema_codec.dart';
import '../handler/logger.dart';
import '../handler/memcomparable.dart';
import '../model/buffer_entry.dart';
import '../model/business_error.dart';
import '../model/meta_info.dart';
import '../model/migration_meta.dart';
import '../model/migration_task.dart';
import '../model/system_table.dart';
import '../model/table_schema.dart';
import '../model/wal_pointer.dart';
import 'backup_manager.dart';
import 'compute_manager.dart';
import 'compute_tasks.dart';
import 'data_store_impl.dart';
import 'index_manager.dart';
import 'table_data_manager.dart';
import 'transaction_context.dart';
import 'crontab_manager.dart';
import 'yield_controller.dart';
import 'dart:collection';

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

  // In-memory cache for migration metadata to avoid frequent file reads
  MigrationMeta? _migrationMetaCache;
  // Current directory index cache (derived from directoryMapping)
  int? _currentDirIndexCache;
  // Lock for thread-safe access to cache
  Future<MigrationMeta>? _loadingFuture;
  // Runtime conversion descriptors for tables that are schema-updated but data not fully migrated yet.
  final Map<String, _RuntimeMigrationDescriptor> _runtimeMigrations =
      <String, _RuntimeMigrationDescriptor>{};
  static const String _deletedSlotFieldPrefix = '_system_storage_deleted_slot_';
  static const String _globalMigrationScope = '__global__';

  // Migration data queue: spaceName -> Queue
  final Map<String, Queue<MigrationPreparedBatch>> _preparedBatches = {};

  // Total records in all prepared batches for backpressure calculation
  int _totalPreparedRecords = 0;

  // Active partition stream controllers for graceful cancellation
  final Map<String, PartitionStreamController> _activeControllers = {};

  // Active migration instances: spaceName -> DataStoreImpl
  final Map<String, DataStoreImpl> _activeMigrationInstances = {};

  // Active migration tasks: spaceName -> Future
  final Map<String, Future<void>> _activeSpaceMigrationTasks = {};

  bool get hasPreparedData {
    for (final q in _preparedBatches.values) {
      if (q.isNotEmpty) return true;
    }
    return false;
  }

  bool hasPreparedDataFor(String spaceName) {
    final queue = _preparedBatches[spaceName];
    return queue != null && queue.isNotEmpty;
  }

  int get totalPreparedRecords => _totalPreparedRecords;

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
    if (hasPreparedData) {
      for (final space in _preparedBatches.keys) {
        if (hasPreparedDataFor(space)) {
          final instance = _activeMigrationInstances[space];
          if (instance == null) continue;
          instance.parallelJournalManager.scheduleFlushIfNeeded();
        }
      }
    }
  }

  void dispose() {
    CrontabManager.removeCallback(ExecuteInterval.seconds30, _triggerFlushes);
  }

  bool get hasPendingTasks => _pendingTasks.isNotEmpty;

  bool hasRuntimeMigrationForTable(String tableName) {
    return _findRuntimeMigrationDescriptor(tableName) != null;
  }

  /// Poll migration batches for a specific space, with dynamic quota management.
  ///
  /// Priority logic:
  /// 1. Guaranteed minimum 10% of totalBatchSize to ensure progress.
  /// 2. If business write queue is low, use all remaining capacity (totalBatchSize - businessQueueLength).
  List<MigrationPreparedBatch> pollMigrationBatches(
      String spaceName, int totalBatchSize) {
    final effectiveSpace = (_preparedBatches[spaceName]?.isNotEmpty ?? false)
        ? spaceName
        : ((_preparedBatches[_globalMigrationScope]?.isNotEmpty ?? false)
            ? _globalMigrationScope
            : spaceName);
    final queue = _preparedBatches[effectiveSpace];
    if (queue == null || queue.isEmpty) return const [];

    // 1. Guaranteed minimum progress (10% of totalBatchSize)
    final int minQuota = max(1, totalBatchSize ~/ 10);

    // 2. Idle-time capacity utilization
    // Access the primary instance's buffer manager to see how much "spare" room we have
    final int businessQueueLength = _dataStore.writeBufferManager.queueLength;
    final int idleExtra = max(0, totalBatchSize - businessQueueLength);

    // Dynamic quota: use more when system is idle, but keep a minimum floor.
    final int allowedRecords = max(minQuota, idleExtra);

    final result = <MigrationPreparedBatch>[];
    int polledRecords = 0;

    while (queue.isNotEmpty && polledRecords < allowedRecords) {
      final nextBatch = queue.first;
      if (polledRecords + nextBatch.entries.length > allowedRecords &&
          result.isNotEmpty) {
        // If adding this batch would exceed our dynamic quota significantly,
        // and we already have some data, stop here.
        break;
      }

      result.add(queue.removeFirst());
      polledRecords += nextBatch.entries.length;
      _totalPreparedRecords -= nextBatch.entries.length;
    }

    if (result.isNotEmpty) {
      // If we still have data, notify again to keep the loop going
      if (queue.isNotEmpty) {
        final instance = _activeMigrationInstances[spaceName] ?? _dataStore;
        instance.parallelJournalManager.scheduleFlushIfNeeded();
      }
    }

    return result;
  }

  /// Callback from ParallelJournalManager when migration batches have been safely persisted.
  Future<void> onMigrationBatchPersisted(
      List<MigrationPreparedBatch> batches) async {
    if (batches.isEmpty) return;

    final yieldController =
        YieldController('MigrationManager.onMigrationBatchPersisted');

    try {
      // Group by (taskId, spaceName) to avoid redundant persistence calls
      final groupedCheckpoints = <String, Map<String, Uint8List>>{};
      final processedRecords = <String, int>{};

      for (final batch in batches) {
        await yieldController.maybeYield();
        if (batch.checkpointKey != null) {
          final spaceMap =
              groupedCheckpoints.putIfAbsent(batch.taskId, () => {});
          spaceMap[batch.spaceName] = batch.checkpointKey!;
        }
        processedRecords[batch.taskId] =
            (processedRecords[batch.taskId] ?? 0) + batch.entries.length;
      }

      // Update task checkpoints atomically per task
      for (final taskId in groupedCheckpoints.keys) {
        await yieldController.maybeYield();
        final task = _findTaskInMemory(taskId);
        if (task == null) continue;

        MigrationTask updatedTask = task;
        final spaceMap = groupedCheckpoints[taskId]!;
        for (final entry in spaceMap.entries) {
          updatedTask = _updateTaskCheckpointForSpace(
            updatedTask,
            entry.key,
            entry.value,
          );
        }

        await _saveMigrationTask(updatedTask);
        _updatePendingTaskInMemory(updatedTask);
        _rebuildRuntimeMigrations(updatedTask.tableName);
      }

      // Update telemetry and notify PJM for remaining data
      for (final taskId in processedRecords.keys) {
        await yieldController.maybeYield();
        _telemetry.recordRecordsProcessed(taskId, processedRecords[taskId]!);
      }

      // Identify spaces that still have data and notify their PJM
      final spacesWithData = batches.map((b) => b.spaceName).toSet();
      for (final space in spacesWithData) {
        if (hasPreparedDataFor(space)) {
          final instance = _activeMigrationInstances[space] ?? _dataStore;
          instance.parallelJournalManager.scheduleFlushIfNeeded();
        }
      }
    } catch (e) {
      Logger.error('Failed to notify migration completion: $e',
          label: 'MigrationManager.onMigrationBatchPersisted');
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
      Logger.info('Stopping background migration for space [$spaceName]...',
          label: 'MigrationManager');
      controller.stopAfterBatch();
      // Do not remove from _activeControllers yet, let the task finish
    }

    // Wait for the migration task future to complete
    final taskFuture = _activeSpaceMigrationTasks[spaceName];
    if (taskFuture != null) {
      try {
        await taskFuture;
      } catch (e) {
        if (e is _MigrationStoppedException) {
          Logger.info('Migration for space [$spaceName] stopped gracefully',
              label: 'MigrationManager');
        } else {
          Logger.error('Failed to wait for migration task stop: $e',
              label: 'MigrationManager');
        }
      }
    }

    // Ensure the migration instance is closed (this will flush remaining migration data)
    final instance = _activeMigrationInstances[spaceName];
    if (instance != null && instance != _dataStore) {
      try {
        await instance.close();
      } catch (e) {
        Logger.error('Failed to close migration instance: $e',
            label: 'MigrationManager');
      }
    }

    // Cleanup
    _activeControllers.remove(spaceName);
    _activeSpaceMigrationTasks.remove(spaceName);
    _activeMigrationInstances.remove(spaceName);

    final queue = _preparedBatches.remove(spaceName);
    if (queue != null) {
      for (final batch in queue) {
        _totalPreparedRecords -= batch.entries.length;
      }
    }
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
  bool shouldNormalizeBufferedWrite(String tableName, WalPointer? walPointer) {
    final descriptor = _findRuntimeMigrationDescriptor(tableName);
    if (descriptor == null) {
      return false;
    }

    if (tableName != descriptor.tableName) {
      return true;
    }

    final cutover = descriptor.cutoverPointer;
    if (cutover == null || walPointer == null) {
      return true;
    }

    final walCycle = _dataStore.config.logPartitionCycle;
    return !walPointer.isNewerThan(cutover, walCycle);
  }

  /// Returns true when the storage payload for [record] should still be written
  /// in legacy physical field layout for the current space.
  ///
  /// This uses the per-space PK checkpoint:
  /// - key <= checkpoint  => new layout
  /// - key > checkpoint   => legacy layout
  /// - no checkpoint      => legacy layout
  bool shouldStoreLegacyPhysicalFormatForRecord(
    String tableName,
    Map<String, dynamic> record, {
    Uint8List? batchCheckpoint,
  }) {
    final descriptor = _findRuntimeMigrationDescriptor(tableName);
    if (descriptor == null) {
      return false;
    }

    // Alias table entries (typically pre-rename) are always treated as legacy.
    if (tableName != descriptor.tableName) {
      return true;
    }

    final checkpoint = batchCheckpoint ?? descriptor.currentSpaceCheckpointKey;
    if (checkpoint == null || checkpoint.isEmpty) {
      return true;
    }

    final keyBytes = _encodeLegacyPrimaryKeyBytes(descriptor, record);
    if (keyBytes == null || keyBytes.isEmpty) {
      return true;
    }
    return MemComparableKey.compare(keyBytes, checkpoint) > 0;
  }

  /// Prefer decoding the payload by legacy layout first for this key.
  bool shouldPreferLegacyDecodeForKey(
    String tableName,
    Uint8List? primaryKeyBytes, {
    Uint8List? batchCheckpoint,
  }) {
    final descriptor = _findRuntimeMigrationDescriptor(tableName);
    if (descriptor == null) {
      return false;
    }
    if (tableName != descriptor.tableName) {
      return true;
    }

    final checkpoint = batchCheckpoint ?? descriptor.currentSpaceCheckpointKey;
    if (checkpoint == null || checkpoint.isEmpty || primaryKeyBytes == null) {
      return true;
    }

    return MemComparableKey.compare(primaryKeyBytes, checkpoint) > 0;
  }

  /// Prefer decoding the payload by legacy layout first for this record.
  bool shouldPreferLegacyDecodeForRecord(
    String tableName,
    Map<String, dynamic> record, {
    Uint8List? batchCheckpoint,
  }) {
    final descriptor = _findRuntimeMigrationDescriptor(tableName);
    if (descriptor == null) {
      return false;
    }

    final keyBytes = _encodeLegacyPrimaryKeyBytes(descriptor, record);
    return shouldPreferLegacyDecodeForKey(
      tableName,
      keyBytes,
      batchCheckpoint: batchCheckpoint,
    );
  }

  List<FieldStructure>? getLegacyFieldStructureForWrite(String tableName) {
    final descriptor = _findRuntimeMigrationDescriptor(tableName);
    if (descriptor == null) {
      return null;
    }
    return descriptor.oldFieldStruct;
  }

  TableSchema? getLegacySchemaForWrite(String tableName) {
    final descriptor = _findRuntimeMigrationDescriptor(tableName);
    return descriptor?.oldSchema;
  }

  List<String> getRuntimeReadTableCandidates(String tableName) {
    final descriptor = _findRuntimeMigrationDescriptor(tableName);
    if (descriptor == null) {
      return const <String>[];
    }
    final out = <String>[];
    for (final alias in descriptor.tableAliases) {
      if (alias == tableName) continue;
      out.add(alias);
    }
    return out;
  }

  Map<String, dynamic> convertCurrentRecordToLegacyForWriteSync(
    String tableName,
    Map<String, dynamic> record,
  ) {
    final descriptor = _findRuntimeMigrationDescriptor(tableName);
    if (descriptor == null) {
      return record;
    }
    return applyMigrationReverseOperationsSync(
      Map<String, dynamic>.from(record),
      descriptor.operations,
      descriptor.oldSchema,
    );
  }

  _RuntimeMigrationDescriptor? _findRuntimeMigrationDescriptor(
      String tableName) {
    final direct = _runtimeMigrations[tableName];
    if (direct != null) {
      return direct;
    }
    for (final descriptor in _runtimeMigrations.values) {
      if (descriptor.tableAliases.contains(tableName)) {
        return descriptor;
      }
    }
    return null;
  }

  Uint8List? _encodeLegacyPrimaryKeyBytes(
    _RuntimeMigrationDescriptor descriptor,
    Map<String, dynamic> record,
  ) {
    // Resolve current PK name by replaying PK-rename operations from old -> new.
    var currentPrimaryKeyName = descriptor.oldSchema.primaryKey;
    for (final op in descriptor.operations) {
      if (op.type != MigrationType.setPrimaryKeyConfig) continue;
      final oldPk = op.oldPrimaryKeyConfig?.name;
      final newPk = op.primaryKeyConfig?.name;
      if (oldPk == null || newPk == null) continue;
      if (currentPrimaryKeyName == oldPk) {
        currentPrimaryKeyName = newPk;
      }
    }

    dynamic rawValue;
    if (record.containsKey(currentPrimaryKeyName)) {
      rawValue = record[currentPrimaryKeyName];
    } else if (record.containsKey(descriptor.oldSchema.primaryKey)) {
      rawValue = record[descriptor.oldSchema.primaryKey];
    }

    final pk = rawValue?.toString();
    if (pk == null || pk.isEmpty) {
      return null;
    }
    try {
      return descriptor.oldSchema.encodePrimaryKeyComponent(pk);
    } catch (_) {
      return null;
    }
  }

  /// Execute migration from old version to new version
  Future<void> migrate(
    List<TableSchema> schemas, {
    int batchSize = 1000,
    bool systemOnly = false,
    bool waitForCompletion = false,
  }) async {
    try {
      var targetSchemas = schemas;
      if (systemOnly) {
        // Filter schemas to only include system tables
        targetSchemas =
            schemas.where((s) => SystemTable.isSystemTable(s.name)).toList();
      }

      Logger.info(
        'Start database migration: involving ${targetSchemas.length} tables${systemOnly ? ' (systemOnly mode)' : ''}',
        label: 'MigrationManager.migrate',
      );

      // Performance optimization: Skip migration if no schemas
      if (targetSchemas.isEmpty) {
        return;
      }

      // Explicitly validate each user-defined schema for internal consistency
      // before starting the migration process. This catches errors in mobile declarative
      // definitions (e.g., index referencing non-existent field) early.
      for (final schema in targetSchemas) {
        if (!schema.validateTableSchema()) {
          throw BusinessError(
            'Invalid schema definition for table ${schema.name}. Please check field names, index fields, and foreign keys.',
            type: BusinessErrorType.schemaError,
          );
        }
      }

      // Get all existing tables
      var existingTables = await _dataStore.getTableNames();
      if (systemOnly) {
        // Only consider on-disk tables that are known system tables (current or legacy).
        // User-created tables are never in this set, so they are never dropped in systemOnly mode.
        // This list is code-only (SystemTable._knownSystemTableNames), not from user schemas,
        // so server-side open() without schemas and runtime createTables() do not affect it.
        existingTables = existingTables
            .where((t) => SystemTable.isKnownSystemTable(t))
            .toList();
      }

      final allTasks = <MigrationTask>[];

      // Record migration start time
      final startTime = DateTime.now();

      // 1. First detect table renaming to avoid subsequent processing misidentifying renamed tables as new + deleted
      final detectRenameResult =
          await _detectRenamedTables(existingTables, targetSchemas);
      final renamedTables = detectRenameResult.renamedTables;
      final tablesToCreate = detectRenameResult.tablesToCreate;
      final tablesToDrop = detectRenameResult.tablesToDrop;

      final renamedTableTargets = <String, String>{};
      for (final entry in renamedTables.entries) {
        renamedTableTargets[entry.key] = entry.value.name;
      }

      // Handle renamed tables
      for (final entry in renamedTables.entries) {
        final oldTableName = entry.key;
        final newSchema = entry.value;

        try {
          // Get old table schema
          final oldSchema =
              await _dataStore.schemaManager?.getTableSchema(oldTableName);
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
              label: 'MigrationManager.migrate',
            );
          }

          // Create migration task but do not process immediately
          final task = await addMigrationTask(
            oldTableName,
            operations,
            startProcessing: false,
            isAutoGenerated: true,
            targetSchemaSnapshot: newSchema,
          );
          allTasks.add(task);
        } catch (e, stack) {
          Logger.error(
            'Failed to handle table renaming [$oldTableName -> ${newSchema.name}]: $e\n$stack',
            label: 'MigrationManager.migrate',
          );
          // Rethrow critical errors to alert developer in IDE
          if (e is BusinessError &&
              (e.type == BusinessErrorType.schemaError ||
                  e.type == BusinessErrorType.migrationError)) {
            rethrow;
          }
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
            // Create new table
            await _dataStore.createTable(schema);
            tablesCreated++;

            if (!SystemTable.isSystemTable(schema.name)) {
              Logger.info(
                'Create new table: ${schema.name}',
                label: 'MigrationManager.migrate',
              );
            }
          }
        } catch (e, stack) {
          Logger.error(
            'Failed to handle table [${schema.name}]: $e\n$stack',
            label: 'MigrationManager.migrate',
          );
          // Rethrow critical errors to alert developer in IDE
          if (e is BusinessError &&
              (e.type == BusinessErrorType.schemaError ||
                  e.type == BusinessErrorType.migrationError)) {
            rethrow;
          }
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

          final task = await addMigrationTask(tableName, operations,
              startProcessing: false, isAutoGenerated: true);
          allTasks.add(task);
          tablesDropped++;

          if (!SystemTable.isSystemTable(tableName)) {
            Logger.info(
              'Handle table deletion: $tableName',
              label: 'MigrationManager.migrate',
            );
          }
        } catch (e, stack) {
          Logger.error(
            'Failed to handle table deletion [$tableName]: $e\n$stack',
            label: 'MigrationManager.migrate',
          );
          // Rethrow critical errors to alert developer in IDE
          if (e is BusinessError &&
              (e.type == BusinessErrorType.schemaError ||
                  e.type == BusinessErrorType.migrationError)) {
            rethrow;
          }
        }
      }

      // Start migration task processing
      if (allTasks.isNotEmpty) {
        if (waitForCompletion) {
          Logger.info(
            'Database migration generated ${allTasks.length} migration tasks, starting execution...',
            label: 'MigrationManager.migrate',
          );
          final migrateSuccess = await processMigrationTasks();

          if (!migrateSuccess) {
            Logger.error(
              'Some migration tasks failed, please check the log for details',
              label: 'MigrationManager.migrate',
            );
            throw const BusinessError(
              'Some migration tasks failed',
              type: BusinessErrorType.migrationError,
            );
          } else {
            Logger.info(
              'All migration tasks have been successfully completed',
              label: 'MigrationManager.migrate',
            );
          }
        } else {
          Logger.info(
            'Database migration generated ${allTasks.length} migration tasks, running asynchronously in background.',
            label: 'MigrationManager.migrate',
          );
          unawaited(processMigrationTasks());
        }
      }

      // Calculate and record total duration
      final endTime = DateTime.now();
      final duration = endTime.difference(startTime);

      Logger.info(
        'Database migration completed:  Renamed tables [${renamedTables.length}], Updated tables [$tablesUpdated], New tables [$tablesCreated], Deleted tables [$tablesDropped], Total duration [${duration.inMilliseconds}ms]',
        label: 'MigrationManager.migrate',
      );
    } catch (e, stack) {
      Logger.error(
        'Database migration failed: $e\n$stack',
        label: 'MigrationManager.migrate',
      );
      rethrow;
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
            label: 'MigrationManager._detectRenamedTables',
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
            label: 'MigrationManager._detectRenamedTables',
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
            label: 'MigrationManager._detectRenamedTables',
          );
        }
      }

      return RenamedTableResult(
        renamedTables: renamedTables,
        tablesToCreate: tablesToCreate,
        tablesToDrop: tablesToDrop,
      );
    } catch (e, stack) {
      Logger.error(
        'Error occurred during table renaming detection: $e\n$stack',
        label: 'MigrationManager._detectRenamedTables',
      );

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

        final existingSchema =
            await _dataStore.schemaManager?.getTableSchema(existingTableName);
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
        final existingSchema =
            await _dataStore.schemaManager?.getTableSchema(existingTableName);
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
    } catch (e, stack) {
      Logger.error(
        'Error during parallel table similarity detection: $e\n$stack',
        label: 'MigrationManager._detectRenamedTablesBySimilarity',
      );
    }
  }

  /// Migrate existing table schema
  Future<MigrationTask?> _migrateExistingTable(
    TableSchema newSchema, {
    required int batchSize,
    Map<String, String> renamedTableTargets = const {},
  }) async {
    final tableName = newSchema.name;
    final oldSchema = await _dataStore.schemaManager?.getTableSchema(tableName);
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
          label: 'MigrationManager._migrateExistingTable',
        );
      }
    }

    // Check if there are existing migration tasks for this table
    final hasPendingTask =
        _pendingTasks.any((task) => task.tableName == tableName);

    // Check if there are any unfinished migration tasks marked in global config
    final globalConfig = await _dataStore.getGlobalConfig();
    if (hasPendingTask || (globalConfig?.hasMigrationTask == true)) {
      // If there are pending tasks, check if there are tasks for this table in migration metadata
      final meta = await _getOrLoadMigrationMeta();
      final allTaskFound = <String>[];

      // Find possible tasks for the same table name
      final tasksToRemove = <String>[];
      for (final entry in meta.directoryMapping.idToDir.entries) {
        try {
          final taskId = entry.key;
          final dirIndex = entry.value;
          final taskPath =
              _dataStore.pathManager.getMigrationTaskPath(dirIndex, taskId);

          // Check if file exists
          final fileExists = await _dataStore.storage.existsFile(taskPath);
          if (!fileExists) {
            // File doesn't exist but mapping has it - mark for cleanup
            tasksToRemove.add(taskId);
            continue;
          }

          final content = await _dataStore.storage.readAsString(taskPath);

          if (content != null && content.isNotEmpty) {
            final task = MigrationTask.fromJson(jsonDecode(content));
            if (task.tableName == tableName &&
                task.pendingMigrationSpaces.isNotEmpty) {
              allTaskFound.add(taskId);
            }
          } else {
            // File exists but is empty - mark for cleanup
            tasksToRemove.add(taskId);
          }
        } catch (e) {
          // File reading error - mark for cleanup
          final taskId = entry.key;
          tasksToRemove.add(taskId);
        }
      }

      // Clean up orphaned mappings if any found
      if (tasksToRemove.isNotEmpty) {
        await _cleanupOrphanedMappings(tasksToRemove);
      }

      if (allTaskFound.isNotEmpty) {
        Logger.info(
          'Table [$tableName] already has ${allTaskFound.length} unfinished migration tasks (${allTaskFound.join(',')}), skipping adding new task',
          label: 'MigrationManager._migrateExistingTable',
        );
        return null;
      }
    }

    final task = await addMigrationTask(
      tableName,
      operations,
      startProcessing: false,
      isAutoGenerated: true,
      targetSchemaSnapshot: newSchema,
    );
    return task;
  }

  /// Add migration task for table schema update across all spaces
  Future<MigrationTask> addMigrationTask(
      String tableName, List<MigrationOperation> operations,
      {bool isAutoGenerated = false,
      bool startProcessing = true,
      bool allowAfterDataMigration = false,
      TableSchema? targetSchemaSnapshot}) async {
    try {
      if (operations.isEmpty) {
        throw ArgumentError('Migration operations cannot be empty');
      }

      final sortedOperations = _sortOperations(List.from(operations));
      final renameOp = _findRenameOperation(sortedOperations);
      final targetTableName = renameOp?.newTableName ?? tableName;
      final pendingTask = await _findPendingTaskForTable(
        tableName: tableName,
        targetTableName: targetTableName,
      );
      if (pendingTask != null) {
        throw BusinessError(
          'Table [$tableName] already has a pending migration task '
          '[${pendingTask.taskId}]. Wait until it completes before calling updateSchema again.',
          type: BusinessErrorType.migrationError,
        );
      }

      final oldSchema =
          await _dataStore.schemaManager?.getTableSchema(tableName);
      final oldFieldLayout = oldSchema != null
          ? await _dataStore.schemaManager
              ?.getTableFieldLayout(tableName, schema: oldSchema)
          : null;
      TableSchema? targetSchema = targetSchemaSnapshot;
      if (oldSchema == null) {
        // If it's not a system auto-migration and the table doesn't exist, it's an error for updateSchema
        if (!isAutoGenerated) {
          throw BusinessError(
            'Table [$tableName] does not exist. updateSchema can only be used to modify existing tables.',
            type: BusinessErrorType.migrationError,
          );
        }
      } else {
        // Deep validation of operations against current schema
        for (final op in sortedOperations) {
          switch (op.type) {
            case MigrationType.addField:
              final field = op.field;
              if (field != null &&
                  oldSchema.fields.any((f) => f.name == field.name)) {
                throw BusinessError(
                  'Cannot add field [${field.name}] to table [$tableName]: field already exists.',
                  type: BusinessErrorType.migrationError,
                );
              }
              break;
            case MigrationType.removeField:
            case MigrationType.renameField:
            case MigrationType.modifyField:
              final fieldName = op.fieldName ?? op.fieldUpdate?.name;
              if (fieldName != null &&
                  !oldSchema.fields.any((f) => f.name == fieldName)) {
                throw BusinessError(
                  'Cannot ${op.type.name} field [$fieldName] in table [$tableName]: field does not exist.',
                  type: BusinessErrorType.migrationError,
                );
              }
              break;
            default:
              break;
          }
        }

        // 2. Predict target schema and validate its overall structure
        // This catches invalid field names, reserved words, etc. before the task is even saved.
        targetSchema ??= _predictTargetSchema(
          oldSchema,
          sortedOperations,
          isAutoGenerated: isAutoGenerated,
        );
        final reservedSystemTableNames = SystemTable.knownSystemTableNames;
        if (!targetSchema.validateTableSchema(
          reservedTableNames: reservedSystemTableNames,
          allowReservedTableNames:
              SystemTable.isKnownSystemTable(targetSchema.name),
          allowInternalTableNamePrefix:
              SystemTable.isKnownSystemTable(targetSchema.name),
          allowOtherInternalFields:
              SystemTable.isKnownSystemTable(targetSchema.name),
        )) {
          throw const BusinessError(
            'Invalid table structure after migration operations',
            type: BusinessErrorType.schemaError,
          );
        }

        // Only check for existing tables
        final requiresMigration =
            await _requiresDataMigration(sortedOperations, oldSchema);

        if (requiresMigration) {
          bool isAllowed = false;
          if (allowAfterDataMigration) {
            // From SchemaBuilder
            isAllowed = true;
          } else if (isAutoGenerated) {
            // From migrate()
            final allowedTables = _dataStore
                    .config.migrationConfig?.allowedAfterDataMigrationTables ??
                [];
            if (allowedTables.contains(tableName)) {
              isAllowed = true;
            }
          }

          if (!isAllowed) {
            final recordCount = await _dataStore.tableDataManager
                .getTableRecordCount(tableName);
            if (recordCount != 0) {
              throw Exception(
                  'Migration for table "$tableName" requires data modification and was not explicitly allowed. '
                  'This is to prevent accidental data loss or long-running migrations. \n'
                  'For changes during app startup, add the table name to `MigrationConfig.allowedAfterDataMigrationTables`. \n'
                  'For changes via SchemaBuilder, use the `.allowAfterDataMigration()` method before calling `.future`.');
            }
          }
        }
      }
      // create new migration task
      final taskId = DateTime.now().microsecondsSinceEpoch.toString();
      final dirIndex = await _getNextDirIndex();
      final spaces = await _getMigrationScopesForSchema(
        targetSchema ?? oldSchema,
      );
      final cutoverPointer = _dataStore.walManager.currentPointer;

      var task = MigrationTask(
        taskId: taskId,
        tableName: tableName,
        isSchemaUpdated: false,
        pendingMigrationSpaces: spaces,
        operations: sortedOperations,
        createTime: DateTime.now(),
        dirIndex: dirIndex,
        isAutoGenerated: isAutoGenerated,
        oldSchemaSnapshot: oldSchema,
        targetSchemaSnapshot: targetSchema,
        oldFieldLayoutSnapshot: oldFieldLayout,
        currentTableName: targetTableName,
        schemaCutoverWalPointer: cutoverPointer,
      );

      // persist migration task
      await _saveMigrationTask(task);
      _pendingTasks.add(task);

      // update global config
      final globalConfig = await _dataStore.getGlobalConfig();
      if (globalConfig != null && !globalConfig.hasMigrationTask) {
        // only update when hasMigrationTask is false, avoid unnecessary write
        await _dataStore
            .saveGlobalConfig(globalConfig.copyWith(hasMigrationTask: true));
      }

      // Schema metadata update is performed synchronously to ensure that subsequent operations
      // can immediately use the new schema. Data migration remains asynchronous.
      if (!task.isSchemaUpdated) {
        String currentTableName = tableName;
        await TransactionContext.runAsSystemOperation(() async {
          currentTableName = await executeSchemaOperations(
            tableName,
            sortedOperations,
            targetSchema: task.targetSchemaSnapshot,
          );
        });
        task = task.copyWith(
          isSchemaUpdated: true,
          currentTableName: currentTableName,
        );
        await _saveMigrationTask(task);
        _updatePendingTaskInMemory(task);
      }

      var needDataMigration = task.forceDataMigration ||
          _needDataMigration(sortedOperations, oldSchema);

      task = await _maybeEnableDeletedSlotCompaction(task, sortedOperations);
      await _invalidatePrimaryInstanceCachesForMigration(
        originalTableName: tableName,
        currentTableName: task.currentTableName ?? targetTableName,
        operations: sortedOperations,
        renameOp: renameOp,
        needDataMigration: needDataMigration,
      );
      _registerRuntimeMigration(task);

      // only trigger task processing when startProcessing is true
      if (startProcessing) {
        unawaited(processMigrationTasks());
      }

      return task;
    } catch (e, stack) {
      Logger.error(
        'Add migration task failed: $e\n$stack',
        label: 'MigrationManager.addMigrationTask',
      );
      rethrow;
    }
  }

  Future<MigrationTask?> _findPendingTaskForTable({
    required String tableName,
    required String targetTableName,
  }) async {
    for (final task in _pendingTasks) {
      if (task.pendingMigrationSpaces.isEmpty) continue;
      if (_taskMatchesTable(task, tableName, targetTableName)) {
        return task;
      }
    }

    final meta = await _getOrLoadMigrationMeta();
    final tasksToRemove = <String>[];
    for (final entry in meta.directoryMapping.idToDir.entries) {
      final taskId = entry.key;
      final dirIndex = entry.value;
      try {
        final taskPath =
            _dataStore.pathManager.getMigrationTaskPath(dirIndex, taskId);
        final fileExists = await _dataStore.storage.existsFile(taskPath);
        if (!fileExists) {
          tasksToRemove.add(taskId);
          continue;
        }
        final content = await _dataStore.storage.readAsString(taskPath);
        if (content == null || content.isEmpty) {
          tasksToRemove.add(taskId);
          continue;
        }
        final task = MigrationTask.fromJson(jsonDecode(content));
        if (task.pendingMigrationSpaces.isEmpty) {
          tasksToRemove.add(taskId);
          continue;
        }
        if (_taskMatchesTable(task, tableName, targetTableName)) {
          return task;
        }
      } catch (_) {
        tasksToRemove.add(taskId);
      }
    }

    if (tasksToRemove.isNotEmpty) {
      await _cleanupOrphanedMappings(tasksToRemove);
    }

    return null;
  }

  bool _taskMatchesTable(
      MigrationTask task, String tableName, String targetTableName) {
    final currentName = task.currentTableName ??
        _resolveCurrentTableName(task.tableName, task.operations);
    return task.tableName == tableName ||
        task.tableName == targetTableName ||
        currentName == tableName ||
        currentName == targetTableName;
  }

  void _registerRuntimeMigration(MigrationTask task) {
    _rebuildRuntimeMigrations(task.tableName);
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
    _rebuildRuntimeMigrations(task.tableName);
  }

  Set<String> _taskRuntimeAliases(MigrationTask task) {
    final aliases = <String>{task.tableName};
    final current = task.currentTableName ??
        _resolveCurrentTableName(task.tableName, task.operations);
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
    final tableName = latest.currentTableName ??
        _resolveCurrentTableName(latest.tableName, latest.operations);
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
      tableName: tableName,
      oldSchema: oldSchema,
      operations: operations,
      oldFieldStruct: oldFieldStruct,
      cutoverPointer: oldestWithSnapshot.schemaCutoverWalPointer,
      currentSpaceCheckpointKey: checkpointKey,
      tableAliases: Set<String>.unmodifiable(aliases),
    );
  }

  void _rebuildRuntimeMigrations([String? affectedTableName]) {
    final currentSpaceName = _dataStore.currentSpaceName;
    final pending = <MigrationTask>[
      for (final task in _pendingTasks)
        if (task.pendingMigrationSpaces.contains(currentSpaceName) ||
            task.pendingMigrationSpaces.contains(_globalMigrationScope))
          task,
    ];

    if (affectedTableName == null) {
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
        _runtimeMigrations[descriptor.tableName] = descriptor;
      }
    } else {
      // Incremental rebuild for a specific table component
      // 1. Find the seed task that involves this table name
      MigrationTask? seed;
      for (final task in pending) {
        if (_taskMatchesTable(task, affectedTableName, '')) {
          seed = task;
          break;
        }
      }

      // 2. If no task found for this table, remove any existing descriptor
      if (seed == null) {
        _runtimeMigrations.remove(affectedTableName);
        // Also remove any descriptors where this table is an alias
        _runtimeMigrations.removeWhere((key, desc) =>
            desc.tableName == affectedTableName ||
            desc.tableAliases.contains(affectedTableName));
        return;
      }

      // 3. Collect component and rebuild
      final component = _collectLinkedPendingTasks(pending, seed);
      final descriptor = _buildRuntimeDescriptorForComponent(component);

      // 4. Remove old descriptors for this component (as table names might have changed)
      final componentAliases = <String>{};
      for (final t in component) {
        componentAliases.addAll(_taskRuntimeAliases(t));
      }
      _runtimeMigrations
          .removeWhere((key, desc) => componentAliases.contains(key));

      // 5. Add new descriptor
      if (descriptor != null) {
        _runtimeMigrations[descriptor.tableName] = descriptor;
      }
    }
  }

  Map<String, dynamic> normalizeRecordForReadSync(
    String tableName,
    Map<String, dynamic> record,
  ) {
    final descriptor = _findRuntimeMigrationDescriptor(tableName);
    if (descriptor == null) {
      return record;
    }
    final normalized = applyMigrationOperationsSync(
      Map<String, dynamic>.from(record),
      descriptor.operations,
      descriptor.oldSchema,
    );
    return normalized;
  }

  Map<String, dynamic>? decodeLegacyRecordForReadSync(
    String tableName,
    Uint8List encodedRecord,
  ) {
    final descriptor = _findRuntimeMigrationDescriptor(tableName);
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

  Map<String, dynamic>? normalizeOldValuesForReadSync(
    String tableName,
    Map<String, dynamic>? oldValues,
  ) {
    if (oldValues == null) return null;
    final descriptor = _findRuntimeMigrationDescriptor(tableName);
    if (descriptor == null) return oldValues;
    return applyMigrationOperationsSync(
      Map<String, dynamic>.from(oldValues),
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
    String tableName,
    List<MigrationOperation> operations, {
    TableSchema? targetSchema,
  }) async {
    final renameOp = _findRenameOperation(operations);
    final lockNames = <String>{
      tableName,
      if (targetSchema != null) targetSchema.name,
      if (renameOp?.newTableName != null) renameOp!.newTableName!,
    }.toList()
      ..sort();
    final lockMgr = _dataStore.lockManager;
    final lockOpId = 'schema_cutover_${DateTime.now().microsecondsSinceEpoch}';
    final acquiredLocks = <String>[];
    if (lockMgr != null) {
      for (final name in lockNames) {
        final resource = 'schema_table:$name';
        final locked = await lockMgr.acquireExclusiveLock(resource, lockOpId);
        if (!locked) {
          for (final acquired in acquiredLocks.reversed) {
            lockMgr.releaseExclusiveLock(acquired, lockOpId);
          }
          throw StateError('Failed to acquire schema cutover lock for $name');
        }
        acquiredLocks.add(resource);
      }
    }

    try {
      final oldSchema =
          await _dataStore.schemaManager?.getTableSchema(tableName);
      final resolvedTargetSchema = targetSchema ??
          (oldSchema != null
              ? _predictTargetSchema(
                  oldSchema,
                  operations,
                  isAutoGenerated: false,
                )
              : null);
      if (resolvedTargetSchema == null) {
        return _resolveCurrentTableName(tableName, operations);
      }

      final currentTableName = resolvedTargetSchema.name;
      final fieldRenameHints = _buildFieldRenameHints(operations);

      if (renameOp != null && renameOp.newTableName != null) {
        await _dataStore.renameTableForMigration(
          tableName,
          currentTableName,
          oldSchemaSnapshot: oldSchema,
          updateSchema: true,
          refreshForeignKeySystemTables: true,
        );
      }

      await _dataStore.schemaManager?.saveTableSchema(
        currentTableName,
        resolvedTargetSchema,
        fieldRenameHints: fieldRenameHints,
      );

      final fkManager = _dataStore.foreignKeyManager;
      await fkManager?.updateSystemTableForTable(
        currentTableName,
        resolvedTargetSchema,
      );

      if (renameOp != null && tableName != currentTableName) {
        await _dataStore.cacheManager.invalidateCache(tableName);
      }
      return currentTableName;
    } finally {
      if (lockMgr != null) {
        for (final resource in acquiredLocks.reversed) {
          lockMgr.releaseExclusiveLock(resource, lockOpId);
        }
      }
    }
  }

  Map<String, String> _buildFieldRenameHints(
    List<MigrationOperation> operations,
  ) {
    final hints = <String, String>{};
    for (final operation in operations) {
      if (operation.type == MigrationType.renameField &&
          operation.fieldName != null &&
          operation.newName != null) {
        hints[operation.newName!] = operation.fieldName!;
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

  String _resolveCurrentTableName(
      String tableName, List<MigrationOperation> operations) {
    final renameOp = _findRenameOperation(operations);
    return renameOp?.newTableName ?? tableName;
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

        Logger.info('Cleaned up migration backup: $backupPath',
            label: 'MigrationManager');
      } catch (e) {
        // Just log warning, backup cleanup is non-critical
        Logger.warn('Failed to cleanup migration backup [$backupPath]: $e',
            label: 'MigrationManager');
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
          label: 'MigrationManager._resolveOldSchemaSnapshot',
        );
        return null;
      }

      final currentSchema = await _dataStore.schemaManager
          ?.getTableSchema(renameOp.newTableName ?? task.tableName);
      if (currentSchema != null) {
        Logger.warn(
          'Migration task [${task.taskId}] is missing an old schema snapshot for rename-only migration. Falling back to the current schema of ${currentSchema.name}.',
          label: 'MigrationManager._resolveOldSchemaSnapshot',
        );
      }
      return currentSchema;
    }

    if (!task.isSchemaUpdated) {
      final currentSchema =
          await _dataStore.schemaManager?.getTableSchema(task.tableName);
      if (currentSchema != null) {
        Logger.warn(
          'Migration task [${task.taskId}] is missing an old schema snapshot. Falling back to the current schema of ${task.tableName}.',
          label: 'MigrationManager._resolveOldSchemaSnapshot',
        );
      }
      return currentSchema;
    }

    Logger.error(
      'Migration task [${task.taskId}] is missing an old schema snapshot after schema update. In-place data rewrite cannot continue safely.',
      label: 'MigrationManager._resolveOldSchemaSnapshot',
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

  bool _needDataMigration(
      List<MigrationOperation> operations, TableSchema? oldSchema) {
    for (final operation in operations) {
      if (operation.type == MigrationType.addField) {
        final field = operation.field;
        if (field != null &&
            !field.nullable &&
            field.defaultValue == null &&
            field.defaultValueType == DefaultValueType.none) {
          return true;
        }
      } else if (operation.type == MigrationType.modifyField) {
        // Only migrate data if field definition changes affect storage
        final update = operation.fieldUpdate!;
        final oldField = oldSchema?.fields.cast<FieldSchema?>().firstWhere(
              (f) => f?.name == update.name,
              orElse: () => null,
            );

        if (oldField != null) {
          // Type change requires migration
          if (update.type != null && oldField.type != update.type) {
            return true;
          }
          // Nullable -> Non-nullable requires migration (to fill defaults)
          else if (oldField.nullable && update.nullable == false) {
            return true;
          }
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
      final recordCount =
          await _dataStore.tableDataManager.getTableRecordCount(tableName);

      if (recordCount != 0) {
        Logger.warn(
          'Attempted to change "isGlobal" for table $tableName with existing data (recordCount=$recordCount). '
          'This requires complex data migration between spaces and the global scope and is therefore rejected.',
          label: 'MigrationManager._compareSchemasAndGenerateOperations',
        );
        throw Exception(
            'Changing the "isGlobal" property for an existing table ($tableName) with existing data is not supported. '
            'Please perform the data migration manually, or clear the table before changing "isGlobal".');
      }

      Logger.info(
        'Table $tableName has no data (recordCount=0), allowing "isGlobal" change '
        'from ${oldSchema.isGlobal} to ${newSchema.isGlobal}.',
        label: 'MigrationManager._compareSchemasAndGenerateOperations',
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
        label: 'MigrationManager._isPrimaryKeyConfigChanged',
      );
      return true;
    }

    // 2. check primary key ordered change
    if (oldSchema.primaryKeyConfig.isOrdered !=
        newSchema.primaryKeyConfig.isOrdered) {
      Logger.info(
        'Primary key ordering change detected: ${oldSchema.primaryKeyConfig.isOrdered} -> ${newSchema.primaryKeyConfig.isOrdered}',
        label: 'MigrationManager._isPrimaryKeyConfigChanged',
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
            label: 'MigrationManager._compareSchemas',
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
          label: 'MigrationManager._compareIndexes',
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
    // Note: indexName change is handled by renameIndex, not modifyIndex.
    // ModifyIndex causes a full rebuild (drop + recreate), so it should only trigger
    // if structural configuration (like uniqueness, type, vector config, or fields) changes.
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
          throw Exception(
            'Foreign key core definition change detected for ${matchedOldFk.actualName} in table ${oldSchema.name}. '
            'Core definitions (fields, referencedTable, referencedFields) cannot be automatically modified. '
            'This is a breaking change that may cause data inconsistency.\n'
            'Old definition: fields=${matchedOldFk.fields}, referencedTable=${matchedOldFk.referencedTable}, referencedFields=${matchedOldFk.referencedFields}\n'
            'New definition: fields=${newFk.fields}, referencedTable=${newFk.referencedTable}, referencedFields=${newFk.referencedFields}\n'
            'Please handle this manually:\n'
            '1. Remove the old foreign key: db.schema("${oldSchema.name}").removeForeignKey("${matchedOldFk.actualName}")\n'
            '2. Ensure data integrity (check for orphaned records, update data if needed)\n'
            '3. Add the new foreign key: db.schema("${oldSchema.name}").addForeignKey(...)',
          );
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
          label: 'MigrationManager._compareForeignKeys',
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
      throw Exception(
          'Unsupported data type change for field "${newField.name}" from ${oldType.name} to ${newType.name}. This conversion is unsafe because existing data $reason This could lead to data loss or migration failure. Please handle this migration manually by creating a new field and migrating the data yourself.');
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
        label: 'MigrationManager._isFieldModified',
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
      Logger.warn(
        'Load migration meta failed, use initial: $e',
        label: 'MigrationManager._loadMigrationMeta',
      );
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
      Logger.warn(
        'Save migration meta failed: $e',
        label: 'MigrationManager._saveMigrationMeta',
      );
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
  /// [return] boolean value indicating if all tasks are successfully processed
  Future<bool> processMigrationTasks() async {
    if (_isProcessingTasks || _pendingTasks.isEmpty) {
      return true; // no task to process, consider as success
    }

    _isProcessingTasks = true;
    bool success = true; // track if all tasks are successful
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
          final completed = await _executeMigrationTask(task)
              .then((_) => true)
              .timeout(taskTimeout, onTimeout: () {
            Logger.error(
              'Task execution timed out: taskId=${task.taskId}, tableName=${task.tableName}',
              label: 'MigrationManager.processMigrationTasks',
            );

            // timeout consider as failed
            success = false;
            // timeout not remove task, continue to execute next time
            return false;
          });

          if (!completed) {
            break;
          }

          // task completed successfully, remove and clean up
          _pendingTasks.removeAt(0);
          await _cleanupTask(task);
          _unregisterRuntimeMigrationForTask(task);
        } catch (e, stack) {
          Logger.error(
            'Migration task execution failed: $e\n$stack',
            label: 'MigrationManager.processMigrationTasks',
          );

          // task execution failed
          success = false;

          // remove failed task, avoid infinite loop
          if (_pendingTasks.isNotEmpty &&
              _pendingTasks.first.taskId == task.taskId) {
            _pendingTasks.removeAt(0);
          }
          _unregisterRuntimeMigrationForTask(task);
        }
      }

      // update global config after all tasks are completed
      final globalConfig = await _dataStore.getGlobalConfig();
      if (globalConfig != null) {
        final hasTasks = _pendingTasks.isNotEmpty;
        if (globalConfig.hasMigrationTask != hasTasks) {
          await _dataStore.saveGlobalConfig(
            globalConfig.copyWith(hasMigrationTask: hasTasks),
          );
        }
      }
    } catch (e, stack) {
      Logger.error(
        'Process migration tasks failed: $e\n$stack',
        label: 'MigrationManager.processMigrationTasks',
      );
      success = false;
    } finally {
      _isProcessingTasks = false;
    }

    return success;
  }

  /// Execute single migration task across spaces
  Future<void> _executeMigrationTask(MigrationTask task) async {
    var currentTask = task;
    final sortedOperations = _sortOperations(List.from(task.operations));
    final originalTableName = currentTask.tableName;
    var currentTableName = currentTask.currentTableName ??
        _resolveCurrentTableName(originalTableName, sortedOperations);
    final renameOp = _findRenameOperation(sortedOperations);

    try {
      // record task start time
      final taskStopwatch = Stopwatch()..start();
      _telemetry.recordTaskStart(task.taskId);
      if (!SystemTable.isSystemTable(task.tableName)) {
        Logger.info(
          'Starting migration task execution: ${task.taskId}, table: ${task.tableName}',
          label: 'MigrationManager._executeMigrationTask',
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
        oldFieldLayout = await _dataStore.schemaManager?.getTableFieldLayout(
          originalTableName,
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
      if (!currentTask.isSchemaUpdated) {
        currentTableName = await executeSchemaOperations(
          currentTask.tableName,
          sortedOperations,
          targetSchema: currentTask.targetSchemaSnapshot,
        );
        currentTask = currentTask.copyWith(
          isSchemaUpdated: true,
          currentTableName: currentTableName,
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
              label: 'MigrationManager',
            );
            needNewBackup = false;
          } else {
            Logger.warn(
              'Recorded backup at [${currentTask.backupPath}] is missing or invalid.',
              label: 'MigrationManager',
            );
          }
        }

        if (needNewBackup) {
          Logger.info(
            'Starting scheduled backup before data migration for table [${currentTask.tableName}]...',
            label: 'MigrationManager',
          );
          try {
            final path = await _dataStore.backup();
            currentTask = currentTask.copyWith(backupPath: path);
            await _saveMigrationTask(currentTask);
            _updatePendingTaskInMemory(currentTask);
          } catch (e) {
            Logger.error('Pre-migration backup failed: $e',
                label: 'MigrationManager');
            // In strict mode, backup failure stops the migration for safety
            if (_dataStore.config.migrationConfig?.strictMode ?? false) {
              rethrow;
            }
          }
        }
      }

      await _syncAutoGeneratedSchemaToDefinition(
        currentTask,
        currentTableName,
      );

      currentTask = await _maybeEnableDeletedSlotCompaction(
          currentTask, sortedOperations);
      oldFieldLayout = currentTask.oldFieldLayoutSnapshot ?? oldFieldLayout;

      final needDataMigration = currentTask.forceDataMigration ||
          _needDataMigration(sortedOperations, oldSchema);

      if (renameOp == null && needDataMigration && oldSchema == null) {
        throw StateError(
          'Migration task [${currentTask.taskId}] for table [$currentTableName] '
          'requires old schema decoding, but no old schema snapshot is available.',
        );
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
        label: 'MigrationManager._executeMigrationTask',
      );

      // process data migration for each space
      for (var space in pendingSpaces) {
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

        final migrationController = PartitionStreamController();
        _activeControllers[space] = migrationController;

        final spaceMigrationFuture = () async {
          try {
            if (!reusePrimaryInstance) {
              await migrationInstance.initialize();
            }

            // Check if table exists under either the old or new name in this space before migration.
            final isGlobalTable = oldSchema?.isGlobal ?? false;
            final dirInfo = await migrationInstance.directoryManager
                ?.getTableDirectoryInfo(originalTableName, isGlobalTable);

            bool exists = dirInfo != null;
            if (!exists && originalTableName != currentTableName) {
              final dirInfoNew = await migrationInstance.directoryManager
                  ?.getTableDirectoryInfo(currentTableName, isGlobalTable);
              exists = dirInfoNew != null;
            }

            if (!exists && !SystemTable.isSystemTable(originalTableName)) {
              Logger.info(
                'Skip migration for table [$originalTableName] in space [$space]: table mapping not found',
                label: 'MigrationManager._executeMigrationTask',
              );
              return;
            }

            if (renameOp != null && renameOp.newTableName != null) {
              await migrationInstance.renameTableForMigration(
                originalTableName,
                currentTableName,
                oldSchemaSnapshot: oldSchema,
                updateSchema: false,
                refreshForeignKeySystemTables: true,
              );
            }

            await _reconcileSchemaSideEffectsAfterSchemaCutover(
              migrationInstance,
              currentTableName,
              oldSchema: oldSchema,
              targetSchema: await _dataStore.schemaManager
                  ?.getTableSchema(currentTableName),
              operations: sortedOperations,
            );

            final shouldDropTable = sortedOperations
                .any((op) => op.type == MigrationType.dropTable);
            if (shouldDropTable) {
              await migrationInstance.dropTable(
                currentTask.tableName,
                isMigration: true,
              );
            }

            // Process data migration in place after any physical rename is done.
            if (needDataMigration) {
              final decodeFieldStructureOverride = oldFieldLayout != null
                  ? _buildFieldStructureFromLayout(oldFieldLayout)
                  : null;

              final int writeBatchSize =
                  max(1, migrationInstance.config.writeBatchSize);
              final int queueSoftCap = writeBatchSize * 2 -
                  _dataStore.writeBufferManager.queueLength;

              final sourceSchema = oldSchema ??
                  await _dataStore.schemaManager
                      ?.getTableSchema(currentTableName);
              if (sourceSchema == null) {
                throw StateError(
                  'Missing source schema for migration task ${currentTask.taskId} on table $currentTableName',
                );
              }

              final sourcePkName = sourceSchema.primaryKey;

              // Optimized default: 500 pages (~8MB) provides near-peak sequential throughput
              // while keeping memory pressure predictable.
              final int pagesPerBatch = 500;

              final tableMeta = await migrationInstance.tableDataManager
                  .getTableMeta(currentTableName);
              if (tableMeta != null) {
                _telemetry.setCurrentSpaceExpectedRecords(
                    currentTask.taskId, tableMeta.totalRecords);
              }

              await migrationInstance.tableDataManager
                  .streamPartitionPageBatches(
                tableName: currentTableName,
                decodeSchema: oldSchema,
                decodeFieldStructureOverride: decodeFieldStructureOverride,
                prefetchNextPageBatch: true,
                pagesPerBatch: pagesPerBatch,
                controller: migrationController,
                onPartition: (partitionNo, batches, ctrl) async {
                  await for (final batch in batches) {
                    if (ctrl.isStopped) break;

                    while (_totalPreparedRecords >= queueSoftCap &&
                        !ctrl.isStopped) {
                      await Future.delayed(const Duration(milliseconds: 100));
                    }

                    if (batch.records.isEmpty) continue;

                    final migratedRecords = await _applyMigrationOperations(
                      batch.records,
                      sortedOperations,
                      oldSchema: oldSchema,
                    );

                    if (migratedRecords.isNotEmpty) {
                      final yieldController = YieldController(
                          'MigrationManager.subBatching',
                          checkInterval: 64);
                      // Sub-batching: Split large results into 1000-record chunks.
                      // This ensures PJM can poll precise amounts without overfilling or splitting.
                      const int subBatchSize = 1000;
                      for (int i = 0;
                          i < migratedRecords.length;
                          i += subBatchSize) {
                        await yieldController.maybeYield();
                        final int end =
                            (i + subBatchSize < migratedRecords.length)
                                ? i + subBatchSize
                                : migratedRecords.length;
                        final entries = migratedRecords.sublist(i, end);

                        final lastRecord = entries.last.data;
                        final sourcePk = lastRecord[sourcePkName]?.toString();
                        Uint8List? sourcePkBytes;
                        if (sourcePk != null) {
                          try {
                            sourcePkBytes = sourceSchema
                                .encodePrimaryKeyComponent(sourcePk);
                          } catch (_) {}
                        }

                        final preparedBatch = MigrationPreparedBatch(
                          taskId: currentTask.taskId,
                          tableName: currentTableName,
                          spaceName: space,
                          entries: entries,
                          partitionNo: partitionNo,
                          checkpointKey: sourcePkBytes,
                        );

                        _preparedBatches
                            .putIfAbsent(space, () => Queue())
                            .add(preparedBatch);
                      }

                      _totalPreparedRecords += migratedRecords.length;
                      migrationInstance.parallelJournalManager
                          .scheduleFlushIfNeeded();
                    }
                  }
                  return PartitionStreamAction.continueScan;
                },
              );

              // Ensure all migration data is physically persisted before marking complete.
              // flushCompletely() waits until the PJM queue is fully drained to disk.
              await migrationInstance.parallelJournalManager.flushCompletely();

              if (migrationController.isStopped) {
                throw _MigrationStoppedException(space);
              }

              // After persistence, perform a spot check validation of the actual physical data.
              if ((_dataStore.config.migrationConfig?.validateAfterMigrate ??
                      false) &&
                  _dataStore.integrityChecker != null) {
                final schema = await _dataStore.schemaManager
                    ?.getTableSchema(currentTask.tableName);
                if (schema != null) {
                  final isValid = await _dataStore.integrityChecker!
                      .validateMigration(currentTask.tableName, schema);
                  if (!isValid &&
                      (_dataStore.config.migrationConfig?.strictMode ??
                          false)) {
                    Logger.error(
                      'Background migration validation failed for space [$space] in table [${currentTask.tableName}]. '
                      'Stopping migration for safety.',
                      label: 'MigrationManager._executeMigrationTask',
                    );
                    // Throwing here will be caught by the outer try-finally, releasing the lease.
                    throw StateError(
                        'Migration data corruption detected for table ${currentTask.tableName}');
                  }
                }
              }
            }

            await _ensureTargetIndexesBuilt(
              migrationInstance,
              currentTableName,
              targetSchema: currentTask.targetSchemaSnapshot ??
                  await _dataStore.schemaManager
                      ?.getTableSchema(currentTableName),
              controller: migrationController,
            );

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
        }

        spaceStopwatch.stop();
        Logger.info(
          'Space [$space] migration completed, time taken: ${spaceStopwatch.elapsedMilliseconds}ms',
          label: 'MigrationManager._executeMigrationTask',
        );
      }

      // if auto generated task, ensure schema consistency
      if (renameOp == null && currentTask.isAutoGenerated) {
        await _ensureSchemaConsistency(currentTask);
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
            label: 'MigrationManager._executeMigrationTask',
          );
        }

        // After successful migration, clean up the pre-migration backup to save space
        if (currentTask.backupPath != null &&
            currentTask.backupPath!.isNotEmpty) {
          _cleanupMigrationBackup(currentTask.backupPath!);
        }
      }
    } catch (e, stack) {
      if (e is _MigrationStoppedException) {
        Logger.info(
          'Migration task ${task.taskId} paused: $e',
          label: 'MigrationManager._executeMigrationTask',
        );
        rethrow;
      }
      _telemetry.recordTaskFailure(task.taskId, e.toString());
      Logger.error(
        'Execute migration task failed: $e\n$stack',
        label: 'MigrationManager._executeMigrationTask',
      );

      // If a backup was made, inform the user that it has been preserved
      if (currentTask.backupPath != null) {
        Logger.error(
          'CRITICAL: Migration for table [${currentTask.tableName}] failed during background data movement. '
          'To prevent overwriting new data written during migration, NO automatic restoration was performed. '
          'A safety snapshot of the state BEFORE migration is preserved at: ${currentTask.backupPath}. '
          'If you decide to restore manually using this backup, be aware that any data written after the migration started will be LOST.',
          label: 'MigrationManager._executeMigrationTask',
        );
      }
      rethrow;
    }
  }

  /// Sort operations to ensure they are executed in correct order
  Future<void> _reconcilePhysicalIndexesAfterSchemaCutover(
    DataStoreImpl migrationInstance,
    String tableName, {
    required TableSchema? oldSchema,
    required TableSchema targetSchema,
    required List<MigrationOperation> operations,
  }) async {
    if (oldSchema == null || migrationInstance.schemaManager == null) {
      return;
    }

    // Use TableSchema.getAllIndexes() directly here. SchemaManager caches by
    // table name, and during cutover that cache may already contain the target
    // schema for the same name; this reconciliation must compare the real old
    // snapshot against the real target schema.
    final oldIndexes = oldSchema.getAllIndexes();
    final targetIndexes = targetSchema.getAllIndexes();
    if (oldIndexes.isEmpty && targetIndexes.isEmpty) {
      return;
    }

    final fieldRenames = _buildOldToNewFieldRenameMap(operations);
    final targetByActual = <String, IndexSchema>{
      for (final index in targetIndexes) index.actualIndexName: index,
    };
    final handledOldActualNames = <String>{};
    final updatedActualNames = <String>{};

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

        handledOldActualNames.add(oldIndex.actualIndexName);
        if (_sameIndexBuildDefinition(oldIndex, targetIndex,
            ignoreFields: true)) {
          await migrationInstance.indexManager?.renameIndex(
            tableName,
            oldIndexName: oldIndex.actualIndexName,
            newIndexName: targetIndex.actualIndexName,
            newFields: targetIndex.fields,
          );
          updatedActualNames.add(targetIndex.actualIndexName);
        } else {
          await migrationInstance.indexManager
              ?.deleteIndexArtifactsForMigration(
            tableName,
            indexName: oldIndex.actualIndexName,
          );
        }
      }
    }

    for (final oldIndex in oldIndexes) {
      final oldActual = oldIndex.actualIndexName;
      if (handledOldActualNames.contains(oldActual)) {
        continue;
      }

      final targetIndex = targetByActual[oldActual];
      if (targetIndex == null) {
        await migrationInstance.indexManager?.deleteIndexArtifactsForMigration(
          tableName,
          indexName: oldActual,
        );
        continue;
      }

      if (updatedActualNames.contains(oldActual)) {
        continue;
      }

      if (!_sameIndexBuildDefinition(oldIndex, targetIndex)) {
        await migrationInstance.indexManager?.deleteIndexArtifactsForMigration(
          tableName,
          indexName: oldActual,
        );
      }
    }
  }

  Future<void> _reconcileSchemaSideEffectsAfterSchemaCutover(
    DataStoreImpl migrationInstance,
    String tableName, {
    required TableSchema? oldSchema,
    required TableSchema? targetSchema,
    required List<MigrationOperation> operations,
  }) async {
    if (targetSchema == null) {
      return;
    }

    await _syncReferencingForeignKeysAfterFieldChanges(
      migrationInstance,
      tableName,
      targetSchema: targetSchema,
      operations: operations,
    );

    await _reconcilePhysicalIndexesAfterSchemaCutover(
      migrationInstance,
      tableName,
      oldSchema: oldSchema,
      targetSchema: targetSchema,
      operations: operations,
    );
  }

  Future<void> _syncReferencingForeignKeysAfterFieldChanges(
    DataStoreImpl migrationInstance,
    String parentTableName, {
    required TableSchema targetSchema,
    required List<MigrationOperation> operations,
  }) async {
    final schemaMgr = _dataStore.schemaManager;
    final fkManager = migrationInstance.foreignKeyManager;
    if (fkManager == null || schemaMgr == null) {
      return;
    }

    final referencingTables =
        await fkManager.findReferencingTables(parentTableName);
    if (referencingTables.isEmpty) {
      return;
    }

    final fieldOps = operations.where((op) {
      return op.type == MigrationType.renameField ||
          op.type == MigrationType.removeField;
    }).toList(growable: false);

    for (final entry in referencingTables.entries) {
      final childTableName = entry.key;
      final childSchema = await schemaMgr.getTableSchema(childTableName);
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
            parentTableName,
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
            parentTableName,
            op.fieldName!,
          );
          if (removed != null) {
            updatedChildSchema = removed;
            childChanged = true;
          }
        }
      }

      final childFksOnParent = updatedChildSchema.foreignKeys
          .where((fk) => fk.referencedTable == parentTableName)
          .toList(growable: false);
      for (final fk in childFksOnParent) {
        if (!updatedChildSchema.validateForeignKeyWithReferencedTable(
          fk,
          targetSchema,
        )) {
          throw BusinessError(
            'Foreign key ${fk.actualName} in table $childTableName is no longer compatible with the migrated table $parentTableName.',
            type: BusinessErrorType.schemaError,
          );
        }
      }

      if (!childChanged) {
        continue;
      }

      final oldChildIndexes = childSchema.getAllIndexes();
      final newChildIndexes = updatedChildSchema.getAllIndexes();
      for (final oldIdx in oldChildIndexes) {
        final stillExists = newChildIndexes
            .any((newIdx) => newIdx.actualIndexName == oldIdx.actualIndexName);
        if (!stillExists) {
          await migrationInstance.indexManager?.removeIndex(
            childTableName,
            indexName: oldIdx.actualIndexName,
          );
        }
      }

      await schemaMgr.saveTableSchema(childTableName, updatedChildSchema);
      await fkManager.updateSystemTableForTable(
        childTableName,
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
  Future<void> _ensureTargetIndexesBuilt(
    DataStoreImpl migrationInstance,
    String tableName, {
    required TableSchema? targetSchema,
    required PartitionStreamController controller,
  }) async {
    final schema = targetSchema ??
        await _dataStore.schemaManager?.getTableSchema(tableName);
    if (schema == null) {
      return;
    }

    final indexes = _dataStore.schemaManager?.getAllIndexesFor(schema) ??
        const <IndexSchema>[];
    for (final index in indexes) {
      if (controller.isStopped) {
        throw _MigrationStoppedException(migrationInstance.currentSpaceName);
      }
      try {
        await migrationInstance.indexManager?.createIndex(
          tableName,
          index,
          tableSchemaOverride: schema,
          controller: controller,
        );
      } catch (e) {
        if (e is IndexBuildCancelledException) {
          throw _MigrationStoppedException(migrationInstance.currentSpaceName);
        }
        Logger.warn(
          'Failed to ensure index ${index.actualIndexName} for table $tableName: $e',
          label: 'MigrationManager._ensureTargetIndexesBuilt',
        );
        rethrow;
      }
    }
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
      {TableSchema? oldSchema}) async {
    if (records.isEmpty || operations.isEmpty) {
      final timestamp = DateTime.now();
      return records
          .map((r) => BufferEntry(
                operation: BufferOperationType.update,
                data: r,
                timestamp: timestamp,
                walPointer: const WalPointer(partitionIndex: -1, entrySeq: 0),
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
        throw BusinessError(
          'Batch migration failed: ${batchResult.errorMessage}',
          type: BusinessErrorType.migrationError,
        );
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
      Logger.error(
        'Cleanup migration task failed: $e',
        label: 'MigrationManager._cleanupTask',
      );
    }
  }

  /// initialize migration manager, recover unfinished tasks
  Future<void> initialize() async {
    try {
      _runtimeMigrations.clear();
      // check if global config has unfinished migration
      final globalConfig = await _dataStore.getGlobalConfig();
      if (globalConfig != null && globalConfig.hasMigrationTask) {
        // load migration meta data
        final meta = await _getOrLoadMigrationMeta();
        if (meta.directoryMapping.idToDir.isNotEmpty) {
          // Track tasks to remove from mapping (file doesn't exist)
          final tasksToRemove = <String>[];

          // load unfinished tasks one by one
          for (final entry in meta.directoryMapping.idToDir.entries) {
            final taskId = entry.key;
            final dirIndex = entry.value;

            try {
              // Check if task file exists
              final taskPath =
                  _dataStore.pathManager.getMigrationTaskPath(dirIndex, taskId);
              final fileExists = await _dataStore.storage.existsFile(taskPath);

              if (!fileExists) {
                // File doesn't exist but mapping has it - mark for cleanup
                Logger.warn(
                  'Task file not found but exists in mapping: taskId[$taskId], dirIndex[$dirIndex], cleaning up mapping',
                  label: 'MigrationManager.initialize',
                );
                tasksToRemove.add(taskId);
                continue;
              }

              // read task file
              final taskContent =
                  await _dataStore.storage.readAsString(taskPath);

              if (taskContent != null && taskContent.isNotEmpty) {
                // parse task
                final task = MigrationTask.fromJson(jsonDecode(taskContent));

                // check if there are remaining spaces to be processed
                if (task.pendingMigrationSpaces.isNotEmpty) {
                  Logger.info(
                    'Found unfinished migration task: taskId[${task.taskId}], table[${task.tableName}], remaining spaces[${task.pendingMigrationSpaces.length}]',
                    label: 'MigrationManager.initialize',
                  );

                  // add to pending tasks queue
                  _pendingTasks.add(task);
                } else {
                  // Task is completed but still in mapping - mark for cleanup
                  Logger.info(
                    'Task completed but still in mapping: taskId[$taskId], cleaning up mapping',
                    label: 'MigrationManager.initialize',
                  );
                  tasksToRemove.add(taskId);
                }
              } else {
                // File exists but is empty - mark for cleanup
                Logger.warn(
                  'Task file is empty: taskId[$taskId], dirIndex[$dirIndex], cleaning up mapping',
                  label: 'MigrationManager.initialize',
                );
                tasksToRemove.add(taskId);
              }
            } catch (e) {
              Logger.warn(
                'Failed to load task: taskId[$taskId], error[$e], cleaning up mapping',
                label: 'MigrationManager.initialize',
              );
              tasksToRemove.add(taskId);
            }
          }

          // Clean up orphaned mappings (tasks that don't exist or are completed)
          if (tasksToRemove.isNotEmpty) {
            await _cleanupOrphanedMappings(tasksToRemove);
          }

          // start processing recovered tasks
          if (_pendingTasks.isNotEmpty) {
            _rebuildRuntimeMigrations();
            unawaited(processMigrationTasks());
          }
        }
      }
    } catch (e, stack) {
      Logger.error(
        'Failed to initialize migration manager: $e\n$stack',
        label: 'MigrationManager.initialize',
      );
    }
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
          label: 'MigrationManager._cleanupOrphanedMappings',
        );
      }
    } catch (e) {
      Logger.error(
        'Failed to cleanup orphaned mappings: $e',
        label: 'MigrationManager._cleanupOrphanedMappings',
      );
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
          label: 'MigrationManager.queryTaskStatus',
        );
        await _cleanupOrphanedMappings([taskId]);
        return MigrationStatus(
          taskId: taskId,
          isCompleted: true,
          createTime: DateTime.now(),
          pendingSpaces: const [],
          processedSpacesCount: 0,
          totalSpacesCount: 0,
        );
      }

      final taskContent = await _dataStore.storage.readAsString(taskPath);

      if (taskContent == null || taskContent.isEmpty) {
        // File exists but is empty - cleanup mapping
        Logger.warn(
          'Task file is empty: taskId[$taskId], dirIndex[$dirIndex], cleaning up mapping',
          label: 'MigrationManager.queryTaskStatus',
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
      );
    } catch (e) {
      Logger.error(
        'Failed to query task status: $e',
        label: 'MigrationManager.queryTaskStatus',
      );
      return null;
    }
  }

  /// Asynchronously ensure schema consistency for auto-generated tasks
  Future<void> _ensureSchemaConsistency(MigrationTask task) async {
    try {
      // Get the final table name (considering table renaming)
      String targetTableName = task.tableName;

      // Check if there's a rename table operation
      MigrationOperation? renameOp;
      try {
        renameOp = task.operations.firstWhere(
          (op) => op.type == MigrationType.renameTable,
        );
        // If there's a rename operation, use the new table name
        if (renameOp.newTableName != null) {
          targetTableName = renameOp.newTableName!;
        }
      } catch (e) {
        // No rename operation found, continue using original table name
      }

      // Get both schemas for comparison
      final definitionSchema = task.targetSchemaSnapshot ??
          _dataStore.getInitialSchemas().firstWhere(
                (s) => s.name == targetTableName,
                orElse: () =>
                    throw Exception('Schema not found in initial schema'),
              );

      final currentSchema =
          await _dataStore.schemaManager?.getTableSchema(targetTableName);

      // Convert schemas to JSON for deep comparison
      final definitionJson = jsonEncode(definitionSchema.toJson());
      final currentJson =
          currentSchema != null ? jsonEncode(currentSchema.toJson()) : null;

      // Only update if schemas are different
      if (currentJson == null || definitionJson != currentJson) {
        await _dataStore.schemaManager!
            .saveTableSchema(targetTableName, definitionSchema);
      } else {
        Logger.debug(
          'Schema for table [$targetTableName] is already consistent with definition',
          label: 'MigrationManager._ensureSchemaConsistency',
        );
      }
    } catch (e, stack) {
      Logger.error(
        'Schema consistency check failed: $e\n$stack',
        label: 'MigrationManager._ensureSchemaConsistency',
      );
    }
  }

  Future<void> _syncAutoGeneratedSchemaToDefinition(
    MigrationTask task,
    String currentTableName,
  ) async {
    if (!task.isAutoGenerated) {
      return;
    }

    final definitionSchema = task.targetSchemaSnapshot ??
        _resolveDefinitionSchemaForTable(currentTableName);
    if (definitionSchema == null) {
      return;
    }

    final currentSchema =
        await _dataStore.schemaManager?.getTableSchema(currentTableName);
    final currentJson =
        currentSchema != null ? jsonEncode(currentSchema.toJson()) : null;
    final definitionJson = jsonEncode(definitionSchema.toJson());

    if (currentJson == definitionJson) {
      return;
    }

    await _dataStore.schemaManager?.saveTableSchema(
      currentTableName,
      definitionSchema,
    );
  }

  TableSchema? _resolveDefinitionSchemaForTable(String tableName) {
    final initialSchemas = _dataStore.getInitialSchemas();
    for (final schema in initialSchemas) {
      if (schema.name == tableName) {
        return schema;
      }
    }
    return null;
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

    final schemaMgr = _dataStore.schemaManager;
    if (schemaMgr == null) {
      return task;
    }

    final currentTableName = task.currentTableName ??
        _resolveCurrentTableName(task.tableName, task.operations);
    final currentSchema = await schemaMgr.getTableSchema(currentTableName);
    if (currentSchema == null) {
      return task;
    }

    final currentLayout = await schemaMgr.getTableFieldLayout(
      currentTableName,
      schema: currentSchema,
    );
    if (currentLayout.totalSlots == 0) {
      return task;
    }
    if (currentLayout.deletedSlotsRatio < 0.30) {
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
      label: 'MigrationManager._maybeEnableDeletedSlotCompaction',
    );

    return updatedTask;
  }

  /// check if the migration operations require data migration.
  Future<bool> _requiresDataMigration(
      List<MigrationOperation> operations, TableSchema oldSchema) async {
    for (final op in operations) {
      switch (op.type) {
        case MigrationType.addField:
          final field = op.field!;
          if (!field.nullable &&
              field.defaultValue == null &&
              field.defaultValueType == DefaultValueType.none) {
            Logger.warn(
              'Data migration required: adding non-nullable field "${field.name}" without a default value.',
              label: 'MigrationManager._requiresDataMigration',
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
            // from nullable to non-nullable
            if (oldField.nullable && (fieldUpdate.nullable == false)) {
              Logger.warn(
                'Data migration required: changing field "${fieldUpdate.name}" from nullable to non-nullable.',
                label: 'MigrationManager._requiresDataMigration',
              );
              return true;
            }
            // Type change requires migration
            if (fieldUpdate.type != null && oldField.type != fieldUpdate.type) {
              Logger.warn(
                'Data migration required: changing field "${fieldUpdate.name}" type from ${oldField.type} to ${fieldUpdate.type}.',
                label: 'MigrationManager._requiresDataMigration',
              );
              return true;
            }
            // from non-unique to unique
            if (!oldField.unique && (fieldUpdate.unique == true)) {
              Logger.warn(
                'Data migration required: changing field "${fieldUpdate.name}" from non-unique to unique.',
                label: 'MigrationManager._requiresDataMigration',
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
            Logger.warn(
              'Data migration required: changing primary key name or type.',
              label: 'MigrationManager._requiresDataMigration',
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
      // renameTableForMigration() already handles the heavier old/new table
      // invalidation, including path cache updates.
      return;
    }

    if (needDataMigration) {
      // Physical table records will be rewritten. Keep the freshly updated
      // schema cache, but drop all read-side/runtime caches for the table.
      await _dataStore.cacheManager.invalidateCache(
        originalTableName,
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
        currentTableName,
        invalidateSchema: false,
        invalidateQuery: invalidateRecordViews,
        invalidateRecords: invalidateRecordViews,
        invalidateRecordCount: false,
        invalidateTableMeta: false,
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
  final String tableName;
  final Set<String> tableAliases;
  final TableSchema oldSchema;
  final List<MigrationOperation> operations;
  final List<FieldStructure> oldFieldStruct;
  final WalPointer? cutoverPointer;
  final Uint8List? currentSpaceCheckpointKey;

  const _RuntimeMigrationDescriptor({
    required this.taskId,
    required this.tableName,
    required this.tableAliases,
    required this.oldSchema,
    required this.operations,
    required this.oldFieldStruct,
    required this.cutoverPointer,
    required this.currentSpaceCheckpointKey,
  });
}

class _MigrationStoppedException implements Exception {
  final String spaceName;

  const _MigrationStoppedException(this.spaceName);

  @override
  String toString() => 'Migration stopped for space [$spaceName]';
}

/// Encapsulates a batch of data prepared for migration to be flushed via ParallelJournalManager.
class MigrationPreparedBatch {
  final String taskId;
  final String tableName;
  final String spaceName;
  final List<BufferEntry> entries;
  final int partitionNo;
  final Uint8List? checkpointKey;

  MigrationPreparedBatch({
    required this.taskId,
    required this.tableName,
    required this.spaceName,
    required this.entries,
    required this.partitionNo,
    this.checkpointKey,
  });
}
