import '../handler/logger.dart';
import '../model/migration_meta.dart';
import '../model/migration_task.dart';
import '../model/table_schema.dart';
import 'data_store_impl.dart';
import 'dart:convert';
import 'dart:async';

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

  MigrationManager(this._dataStore);

  /// Execute migration from old version to new version
  Future<void> migrate(List<TableSchema> schemas,
      {int batchSize = 1000}) async {
    try {
      Logger.info(
        'Start database migration: involving ${schemas.length} tables',
        label: 'MigrationManager.migrate',
      );

      // Performance optimization: Skip migration if no schemas
      if (schemas.isEmpty) {
        return;
      }

      // Get all existing tables
      final existingTables = await _dataStore.getTableNames();
      final allTasks = <MigrationTask>[];

      // Record migration start time
      final startTime = DateTime.now();

      // 1. First detect table renaming to avoid subsequent processing misidentifying renamed tables as new + deleted
      final detectRenameResult =
          await _detectRenamedTables(existingTables, schemas);
      final renamedTables = detectRenameResult.renamedTables;
      final tablesToCreate = detectRenameResult.tablesToCreate;
      final tablesToDrop = detectRenameResult.tablesToDrop;

      // Handle renamed tables
      for (final entry in renamedTables.entries) {
        final oldTableName = entry.key;
        final newSchema = entry.value;

        try {
          // Get old table schema
          final oldSchema = await _dataStore.getTableSchema(oldTableName);
          if (oldSchema == null) {
            continue;
          }

          // Generate rename table operation
          final operations = <MigrationOperation>[
            MigrationOperation(
              type: MigrationType.renameTable,
              newTableName: newSchema.name,
            ),
          ];

          // Compare possible structure changes after renaming
          final schemaOperations =
              _compareSchemasAndGenerateOperations(oldSchema, newSchema);

          // Merge operations
          operations.addAll(schemaOperations);

          Logger.info(
            'Table [$oldTableName -> ${newSchema.name}] generated ${operations.length} migration operations',
            label: 'MigrationManager.migrate',
          );

          // Create migration task but do not process immediately
          final task = await addMigrationTask(oldTableName, operations,
              startProcessing: false);
          allTasks.add(task);
        } catch (e, stack) {
          Logger.error(
            'Failed to handle table renaming [$oldTableName -> ${newSchema.name}]: $e\n$stack',
            label: 'MigrationManager.migrate',
          );
        }
      }

      // 2. Handle remaining tables
      int tablesUpdated = 0;
      int tablesCreated = 0;

      for (var schema in schemas) {
        try {
          // Skip already processed renamed tables
          if (renamedTables.values.any((s) => s.name == schema.name)) {
            continue;
          }

          if (existingTables.contains(schema.name) &&
              !tablesToDrop.contains(schema.name)) {
            // Migrate existing table
            final task =
                await _migrateExistingTable(schema, batchSize: batchSize);
            if (task != null) {
              allTasks.add(task);
              tablesUpdated++;
            }
          } else if (tablesToCreate.contains(schema.name)) {
            // Create new table
            await _dataStore.createTable(schema);
            tablesCreated++;

            Logger.info(
              'Create new table: ${schema.name}',
              label: 'MigrationManager.migrate',
            );
          }
        } catch (e, stack) {
          Logger.error(
            'Failed to handle table [${schema.name}]: $e\n$stack',
            label: 'MigrationManager.migrate',
          );
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
              startProcessing: false);
          allTasks.add(task);
          tablesDropped++;

          Logger.info(
            'Handle table deletion: $tableName',
            label: 'MigrationManager.migrate',
          );
        } catch (e, stack) {
          Logger.error(
            'Failed to handle table deletion [$tableName]: $e\n$stack',
            label: 'MigrationManager.migrate',
          );
        }
      }

      // Start migration task processing
      if (allTasks.isNotEmpty) {
        Logger.info(
          'Database migration generated ${allTasks.length} migration tasks, starting execution...',
          label: 'MigrationManager.migrate',
        );
        final migrateSuccess = await processMigrationTasks();

        if (!migrateSuccess) {
          Logger.warn(
            'Some migration tasks failed, please check the log for details',
            label: 'MigrationManager.migrate',
          );
        } else {
          Logger.info(
            'All migration tasks have been successfully completed',
            label: 'MigrationManager.migrate',
          );
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
        final renameInfo = renamedTables.entries
            .map((e) => '${e.key} -> ${e.value.name}')
            .join(', ');
        Logger.info(
          'Final result of table renaming detection: $renameInfo',
          label: 'MigrationManager._detectRenamedTables',
        );
      }

      if (tablesToCreate.isNotEmpty) {
        Logger.info(
          'Tables to be created: ${tablesToCreate.join(', ')}',
          label: 'MigrationManager._detectRenamedTables',
        );
      }

      if (tablesToDrop.isNotEmpty) {
        Logger.info(
          'Tables to be deleted: ${tablesToDrop.join(', ')}',
          label: 'MigrationManager._detectRenamedTables',
        );
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
            await _dataStore.getTableSchema(existingTableName);
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
    // Similarity threshold, above which tables are considered the same
    const similarityThreshold = 0.75;

    // Similarity matrix
    final similarityMatrix = <String, Map<TableSchema, double>>{};

    // Calculate similarity for all tables
    for (final existingTableName in existingTables) {
      final existingSchema = await _dataStore.getTableSchema(existingTableName);
      if (existingSchema == null) continue;

      similarityMatrix[existingTableName] = {};

      for (final newSchema in newSchemas) {
        // Skip tables with the same name, these should not be identified as renamed tables
        if (existingTableName == newSchema.name) {
          continue;
        }

        // Calculate similarity
        final similarity = _calculateTableSimilarity(
            existingSchema,
            newSchema,
            existingTables.indexOf(existingTableName),
            newSchemas.indexOf(newSchema),
            existingTables.length,
            newSchemas.length);

        similarityMatrix[existingTableName]![newSchema] = similarity;
      }
    }

    // Greedy matching algorithm
    while (similarityMatrix.isNotEmpty) {
      // Find highest similarity
      String? bestExistingTable;
      TableSchema? bestNewSchema;
      double bestSimilarity = 0;

      for (final existingTable in similarityMatrix.keys) {
        for (final newSchema in similarityMatrix[existingTable]!.keys) {
          final similarity = similarityMatrix[existingTable]![newSchema]!;

          if (similarity > bestSimilarity) {
            bestSimilarity = similarity;
            bestExistingTable = existingTable;
            bestNewSchema = newSchema;
          }
        }
      }

      // If the best match exceeds the threshold, consider it a renamed table
      if (bestSimilarity >= similarityThreshold &&
          bestExistingTable != null &&
          bestNewSchema != null) {
        // Additional check: Even with high similarity, tables with the same name should not be considered renamed
        if (bestExistingTable == bestNewSchema.name) {
          // Remove same-name table match from similarity matrix
          similarityMatrix.remove(bestExistingTable);
          continue;
        }

        // Add to renamed results
        renamedTables[bestExistingTable] = bestNewSchema;

        // Remove matched items from matrix
        similarityMatrix.remove(bestExistingTable);
        for (final existingTable in similarityMatrix.keys) {
          similarityMatrix[existingTable]!.remove(bestNewSchema);
        }

        // Delete from remaining lists
        existingTables.remove(bestExistingTable);
        newSchemas.remove(bestNewSchema);
      } else {
        // No tables similar enough, terminate matching
        break;
      }
    }
  }

  /// Calculate table similarity
  double _calculateTableSimilarity(
      TableSchema oldSchema,
      TableSchema newSchema,
      int oldTableIndex,
      int newTableIndex,
      int oldTablesCount,
      int newTablesCount) {
    double score = 0.0;
    double totalWeight = 0.0;

    // 1. First check table name similarity (medium weight)
    const nameWeight = 10.0;
    totalWeight += nameWeight;
    double nameScore = _calculateNameSimilarity(oldSchema.name, newSchema.name);
    score += nameWeight * nameScore;

    // 2. Check primary key (high weight)
    const primaryKeyWeight = 20.0;
    totalWeight += primaryKeyWeight;
    if (oldSchema.primaryKey == newSchema.primaryKey) {
      score += primaryKeyWeight;
    } else {
      // Primary key mismatch is a strong negative signal
      score -= primaryKeyWeight * 0.5;
    }

    // 3. Check isGlobal property (medium weight)
    const globalWeight = 10.0;
    totalWeight += globalWeight;
    if (oldSchema.isGlobal == newSchema.isGlobal) {
      score += globalWeight;
    } else {
      // isGlobal mismatch is an important signal
      score -= globalWeight * 0.3;
    }

    // 4. Check field matching (highest weight)
    const fieldsWeight = 50.0;
    totalWeight += fieldsWeight;

    // 4.1 Field count comparison
    double fieldsScore = 0.0;
    if (oldSchema.fields.isEmpty || newSchema.fields.isEmpty) {
      fieldsScore = 0.0;
    } else {
      // Check common field count
      int matchingFields = 0;
      Set<String> oldFieldNames = oldSchema.fields.map((f) => f.name).toSet();
      Set<String> newFieldNames = newSchema.fields.map((f) => f.name).toSet();

      // Calculate number of common fields
      for (final name in oldFieldNames) {
        if (newFieldNames.contains(name)) {
          matchingFields++;
        }
      }

      // Calculate field match rate
      final matchingFieldsRatio =
          oldSchema.fields.isEmpty || newSchema.fields.isEmpty
              ? 0.0
              : (2 * matchingFields) /
                  (oldFieldNames.length + newFieldNames.length);

      fieldsScore = matchingFieldsRatio;
    }

    score += fieldsWeight * fieldsScore;

    // 5. Index match rate (medium weight)
    const indexWeight = 15.0;
    totalWeight += indexWeight;

    double indexScore = 0.0;
    if (oldSchema.indexes.isEmpty && newSchema.indexes.isEmpty) {
      // Both have no indexes, perfect match
      indexScore = 1.0;
    } else if (oldSchema.indexes.isEmpty || newSchema.indexes.isEmpty) {
      // One has indexes, one doesn't, not a good match
      indexScore = 0.1;
    } else {
      // Check index field matching
      int matchingIndexes = 0;

      for (final oldIndex in oldSchema.indexes) {
        for (final newIndex in newSchema.indexes) {
          if (_areFieldListsEqual(oldIndex.fields, newIndex.fields)) {
            matchingIndexes++;
            break;
          }
        }
      }

      // Calculate index match rate
      final totalIndexes = oldSchema.indexes.length + newSchema.indexes.length;
      indexScore =
          totalIndexes > 0 ? (2 * matchingIndexes) / totalIndexes : 0.0;
    }

    score += indexWeight * indexScore;

    // 6. Table position matching (low weight)
    const positionWeight = 5.0;
    totalWeight += positionWeight;

    // Calculate relative position difference
    double positionDiff;
    if (oldTablesCount <= 1 || newTablesCount <= 1) {
      positionDiff = 0;
    } else {
      positionDiff = (oldTableIndex / (oldTablesCount - 1) -
              newTableIndex / (newTablesCount - 1))
          .abs();
    }

    score += positionWeight * (1 - positionDiff);

    // Calculate final score
    return totalWeight > 0 ? score / totalWeight : 0.0;
  }

  /// Migrate existing table schema
  Future<MigrationTask?> _migrateExistingTable(TableSchema newSchema,
      {required int batchSize}) async {
    final tableName = newSchema.name;
    final oldSchema = await _dataStore.getTableSchema(tableName);
    if (oldSchema == null) {
      return null;
    }

    // Compare schemas and generate operations
    final operations =
        _compareSchemasAndGenerateOperations(oldSchema, newSchema);

    if (operations.isEmpty) {
      return null;
    } else {
      Logger.info(
        'Found ${operations.length} changes for table $tableName',
        label: 'MigrationManager._migrateExistingTable',
      );
    }

    // Check if there are existing migration tasks for this table
    final hasPendingTask =
        _pendingTasks.any((task) => task.tableName == tableName);

    // Check if there are any unfinished migration tasks marked in global config
    final globalConfig = await _dataStore.getGlobalConfig();
    if (hasPendingTask || (globalConfig?.hasMigrationTask == true)) {
      // If there are pending tasks, check if there are tasks for this table in migration metadata
      final meta = await _loadMigrationMeta();
      final allTaskFound = <String>[];

      // Find possible tasks for the same table name
      for (final entry in meta.taskIndex.entries) {
        try {
          final taskId = entry.key;
          final dirIndex = entry.value;
          final taskPath =
              _dataStore.pathManager.getMigrationTaskPath(dirIndex, taskId);
          final content = await _dataStore.storage.readAsString(taskPath);

          if (content != null && content.isNotEmpty) {
            final task = MigrationTask.fromJson(jsonDecode(content));
            if (task.tableName == tableName &&
                task.pendingMigrationSpaces.isNotEmpty) {
              allTaskFound.add(taskId);
            }
          }
        } catch (e) {
          // Ignore file reading errors
        }
      }

      if (allTaskFound.isNotEmpty) {
        Logger.info(
          'Table [$tableName] already has ${allTaskFound.length} unfinished migration tasks (${allTaskFound.join(',')}), skipping adding new task',
          label: 'MigrationManager._migrateExistingTable',
        );
        return null;
      }
    }

    final task =
        await addMigrationTask(tableName, operations, startProcessing: false);
    return task;
  }

  /// Add migration task for table schema update across all spaces
  Future<MigrationTask> addMigrationTask(
      String tableName, List<MigrationOperation> operations,
      {bool isAutoGenerated = false, bool startProcessing = true}) async {
    try {
      // create new migration task
      final taskId = DateTime.now().microsecondsSinceEpoch.toString();
      final dirIndex = await _getNextDirIndex();
      final spaces = await _getAllSpaces();

      final task = MigrationTask(
        taskId: taskId,
        tableName: tableName,
        isSchemaUpdated: false,
        pendingMigrationSpaces: spaces,
        operations: operations,
        createTime: DateTime.now(),
        dirIndex: dirIndex,
        isAutoGenerated: isAutoGenerated,
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

      // only trigger task processing when startProcessing is true
      if (startProcessing) {
        processMigrationTasks();
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

  /// Execute operations - only handle table structure updates
  Future<void> executeSchemaOperations(
      String tableName, List<MigrationOperation> operations) async {
    for (var operation in operations) {
      await _executeSchemaOperation(tableName, operation);
    }
  }

  Future<void> _executeSchemaOperation(
      String tableName, MigrationOperation operation) async {
    switch (operation.type) {
      case MigrationType.addField:
        await _dataStore.addField(tableName, operation.field!);
        break;

      case MigrationType.removeField:
        await _dataStore.removeField(tableName, operation.fieldName!);
        break;

      case MigrationType.renameField:
        await _dataStore.renameField(
          tableName,
          operation.fieldName!,
          operation.newName!,
        );
        break;

      case MigrationType.modifyField:
        await _dataStore.modifyField(
          tableName,
          operation.fieldUpdate!.name,
          operation.fieldUpdate!,
        );
        break;

      case MigrationType.addIndex:
        // Index operations are handled in each space's migration instance
        break;

      case MigrationType.removeIndex:
        // Index operations are handled in each space's migration instance
        break;

      case MigrationType.modifyIndex:
        // Index operations are handled in each space's migration instance
        break;

      case MigrationType.renameTable:
        final oldSchema = await _dataStore.getTableSchema(tableName);
        if (oldSchema == null) {
          return;
        }
        final newSchema = oldSchema.copyWith(name: operation.newTableName!);
        await _dataStore.createTable(newSchema);
        break;

      case MigrationType.dropTable:
        break;

      case MigrationType.setPrimaryKeyConfig:
        if (operation.primaryKeyConfig != null) {
          await _dataStore.setPrimaryKeyConfig(
            tableName,
            operation.primaryKeyConfig!,
          );
        }
        break;
    }
  }

  /// Compare schemas and generate operations
  List<MigrationOperation> _compareSchemasAndGenerateOperations(
    TableSchema oldSchema,
    TableSchema newSchema,
  ) {
    final operations = <MigrationOperation>[];

    // Check field changes
    _compareFields(oldSchema, newSchema, operations);

    // check primary key config change
    if (_isPrimaryKeyConfigChanged(oldSchema, newSchema)) {
      operations.add(MigrationOperation(
        type: MigrationType.setPrimaryKeyConfig,
        primaryKeyConfig: newSchema.primaryKeyConfig,
        oldPrimaryKeyConfig: oldSchema.primaryKeyConfig,
      ));
    }

    // Check indexes changes
    _compareIndexes(oldSchema, newSchema, operations);

    return operations;
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

  /// Compare fields and generate operations
  void _compareFields(
    TableSchema oldSchema,
    TableSchema newSchema,
    List<MigrationOperation> operations,
  ) {
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
        Logger.info(
          'Table ${newSchema.name}, field ${newField.name} has been modified',
          label: 'MigrationManager._compareSchemas',
        );
        operations.add(MigrationOperation(
          type: MigrationType.modifyField,
          fieldUpdate: FieldSchemaUpdate(
            name: newField.name,
            type: newField.type,
            nullable: newField.nullable,
            defaultValue: newField.defaultValue,
            unique: newField.unique,
            maxLength: newField.maxLength,
            minLength: newField.minLength,
            minValue: newField.minValue,
            maxValue: newField.maxValue,
            comment: newField.comment,
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
    _detectRenamedFields(oldSchema, newSchema, operations);
  }

  /// Compare indexes and generate operations
  void _compareIndexes(
    TableSchema oldSchema,
    TableSchema newSchema,
    List<MigrationOperation> operations,
  ) {
    // First mark all old indexes as to be removed
    final indexesToRemove = List<IndexSchema>.from(oldSchema.indexes);

    // Check for added and modified indexes
    for (var newIndex in newSchema.indexes) {
      // Try to find matching index in old schema
      IndexSchema? matchedOldIndex;

      for (var oldIndex in oldSchema.indexes) {
        if (_areIndexesSame(oldIndex, newIndex)) {
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

        // Check if modification is needed
        if (_isIndexModified(matchedOldIndex, newIndex)) {
          operations.add(MigrationOperation(
            type: MigrationType.modifyIndex,
            indexName: newIndex.indexName,
            fields: newIndex.fields,
            unique: newIndex.unique,
          ));
        }
      }
    }

    // Handle indexes that need to be removed
    for (var indexToRemove in indexesToRemove) {
      Logger.info(
        'Detected index to be removed: ${indexToRemove.actualIndexName}, fields: ${indexToRemove.fields.join(", ")}',
        label: 'MigrationManager._compareIndexes',
      );

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
    if (a.indexName != null && b.indexName != null) {
      return a.indexName == b.indexName;
    }
    // if no indexName, compare field list
    return _areFieldListsEqual(a.fields, b.fields);
  }

  /// Compare two field lists ignoring order
  bool _areFieldListsEqual(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    final setA = Set<String>.from(a);
    final setB = Set<String>.from(b);
    return setA.difference(setB).isEmpty;
  }

  /// Check if index is modified
  bool _isIndexModified(IndexSchema oldIndex, IndexSchema newIndex) {
    if (oldIndex.indexName != null && newIndex.indexName != null) {
      if (oldIndex.indexName != newIndex.indexName) {
        return true;
      }
    }
    return oldIndex.unique != newIndex.unique ||
        !_areFieldListsEqual(oldIndex.fields, newIndex.fields);
  }

  /// Detect renamed fields using strict matching
  void _detectRenamedFields(
    TableSchema oldSchema,
    TableSchema newSchema,
    List<MigrationOperation> operations,
  ) {
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
      _detectRenamedFieldsBySimilarity(
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

  /// match renamed fields by similarity
  void _detectRenamedFieldsBySimilarity(
    TableSchema oldSchema,
    TableSchema newSchema,
    List<MigrationOperation> operations,
    List<String> removedFields,
    List<FieldSchema> addedFields,
  ) {
    // field similarity threshold, only fields with score above this value will be considered as renamed
    const similarityThreshold = 0.6;

    // calculate similarity matrix for all removed and added fields
    final similarityMatrix = <String, Map<FieldSchema, double>>{};

    // iterate all removed fields
    for (var oldFieldName in removedFields) {
      // if old field is primary key, skip
      if (oldSchema.primaryKey == oldFieldName) continue;

      final oldField = oldSchema.fields.firstWhere(
        (f) => f.name == oldFieldName,
      );

      similarityMatrix[oldFieldName] = {};

      // calculate similarity with each added field
      for (var newField in addedFields) {
        // if new field is primary key, skip
        if (newSchema.primaryKey == newField.name) continue;

        final similarity = _calculateFieldSimilarityWithWeights(
            oldField,
            newField,
            oldSchema.fields.indexOf(oldField),
            newSchema.fields.indexOf(newField),
            oldSchema.fields.length,
            newSchema.fields.length,
            oldSchema: oldSchema,
            newSchema: newSchema);

        similarityMatrix[oldFieldName]![newField] = similarity;
      }
    }

    // greedy matching algorithm: find the highest similarity field pair
    while (similarityMatrix.isNotEmpty) {
      // find the highest similarity field pair
      String? bestOldField;
      FieldSchema? bestNewField;
      double bestSimilarity = 0;

      for (var oldField in similarityMatrix.keys) {
        for (var newField in similarityMatrix[oldField]!.keys) {
          final similarity = similarityMatrix[oldField]![newField]!;

          if (similarity > bestSimilarity) {
            bestSimilarity = similarity;
            bestOldField = oldField;
            bestNewField = newField;
          }
        }
      }

      // if similarity is above threshold, consider as renamed
      if (bestSimilarity >= similarityThreshold &&
          bestOldField != null &&
          bestNewField != null) {
        // remove existing add and remove operations
        operations.removeWhere((op) =>
            (op.type == MigrationType.removeField &&
                op.fieldName == bestOldField) ||
            (op.type == MigrationType.addField && op.field == bestNewField));

        // add rename operation
        operations.add(MigrationOperation(
          type: MigrationType.renameField,
          fieldName: bestOldField,
          newName: bestNewField.name,
        ));

        // record detailed log
        Logger.info(
          'Automatic field renaming detected: $bestOldField -> ${bestNewField.name}, similarity: ${bestSimilarity.toStringAsFixed(2)}',
          label: 'MigrationManager._detectRenamedFieldsBySimilarity',
        );

        // remove matched fields from similarity matrix
        similarityMatrix.remove(bestOldField);
        for (var oldField in similarityMatrix.keys) {
          similarityMatrix[oldField]!.remove(bestNewField);
        }
      } else {
        // if best match still not above threshold, break
        break;
      }
    }
  }

  /// calculate field similarity with weights
  double _calculateFieldSimilarityWithWeights(
      FieldSchema oldField,
      FieldSchema newField,
      int oldFieldIndex,
      int newFieldIndex,
      int oldFieldsCount,
      int newFieldsCount,
      {TableSchema? oldSchema,
      TableSchema? newSchema}) {
    // if no table schema provided, create default empty schema
    oldSchema ??= const TableSchema(
        name: '',
        primaryKeyConfig: PrimaryKeyConfig(),
        fields: [],
        indexes: []);

    newSchema ??= const TableSchema(
        name: '',
        primaryKeyConfig: PrimaryKeyConfig(),
        fields: [],
        indexes: []);

    double score = 0.0;
    double totalWeight = 0.0;

    // 1. basic type matching (high weight)
    const typeWeight = 20.0;
    totalWeight += typeWeight;
    if (oldField.type == newField.type) {
      score += typeWeight;
    } else {
      // when type not matched, subtract some weight
      score -= typeWeight * 0.7;
    }

    // 2. default value matching (if not basic null value)
    const defaultValueWeight = 15.0;
    totalWeight += defaultValueWeight;
    if (oldField.defaultValue != null && newField.defaultValue != null) {
      if (oldField.defaultValue == newField.defaultValue) {
        score += defaultValueWeight;
      } else {
        // default value different is strong negative signal
        score -= defaultValueWeight * 0.5;
      }
    } else if (oldField.defaultValue == null && newField.defaultValue == null) {
      // both are null, also consider as partial match
      score += defaultValueWeight * 0.5;
    }

    // 3. comment matching (give high weight to non-empty and meaningful comments)
    const commentWeight = 20.0;
    if (oldField.comment != null &&
        newField.comment != null &&
        oldField.comment!.length > 1 &&
        newField.comment!.length > 1) {
      totalWeight += commentWeight;
      if (oldField.comment == newField.comment) {
        score += commentWeight;
      } else {
        // different meaningful comments are strong negative signal
        score -= commentWeight * 0.5;
      }
    }

    // 4. nullable and unique property matching
    const nullableWeight = 10.0;
    totalWeight += nullableWeight;
    if (oldField.nullable == newField.nullable) {
      score += nullableWeight;
    } else {
      // nullable different is negative signal
      score -= nullableWeight * 0.3;
    }

    const uniqueWeight = 10.0;
    totalWeight += uniqueWeight;
    if (oldField.unique == newField.unique) {
      score += uniqueWeight;
    } else {
      // unique different is negative signal
      score -= uniqueWeight * 0.3;
    }

    // 5. length and value range constraint matching
    const constraintWeight = 5.0;
    double constraintsChecked = 0;
    double constraintsMatched = 0;

    // maxLength check
    if (oldField.maxLength != null || newField.maxLength != null) {
      constraintsChecked++;
      if (oldField.maxLength == newField.maxLength) {
        constraintsMatched++;
      }
    }

    // minLength check
    if (oldField.minLength != null || newField.minLength != null) {
      constraintsChecked++;
      if (oldField.minLength == newField.minLength) {
        constraintsMatched++;
      }
    }

    // minValue check
    if (oldField.minValue != null || newField.minValue != null) {
      constraintsChecked++;
      if (oldField.minValue == newField.minValue) {
        constraintsMatched++;
      }
    }

    // maxValue check
    if (oldField.maxValue != null || newField.maxValue != null) {
      constraintsChecked++;
      if (oldField.maxValue == newField.maxValue) {
        constraintsMatched++;
      }
    }

    if (constraintsChecked > 0) {
      totalWeight += constraintWeight;
      score += (constraintsMatched / constraintsChecked) * constraintWeight;
    }

    // 6. field position matching (very high weight)
    const positionWeight = 25.0;
    totalWeight += positionWeight;

    // calculate relative position difference (0-1 value, 0 means fully matched)
    double positionDiff;
    if (oldFieldsCount == 1 || newFieldsCount == 1) {
      // if only one field, position is not important
      positionDiff = 0;
    } else {
      // normalize position difference to 0-1
      positionDiff = (oldFieldIndex / (oldFieldsCount - 1) -
              newFieldIndex / (newFieldsCount - 1))
          .abs();
    }

    // the closer the position, the higher the score
    score += positionWeight * (1 - positionDiff);

    // 7. field name similarity check
    const nameWeight = 15.0;
    totalWeight += nameWeight;

    // field name string similarity
    double nameScore = _calculateNameSimilarity(oldField.name, newField.name);
    score += nameWeight * nameScore;

    // 8. index position check
    const indexWeight = 5.0;
    bool oldFieldInIndex = _isFieldInIndex(oldField.name, oldSchema.indexes);
    bool newFieldInIndex = _isFieldInIndex(newField.name, newSchema.indexes);

    if (oldFieldInIndex && newFieldInIndex) {
      totalWeight += indexWeight;
      score += indexWeight;
    } else if (!oldFieldInIndex && !newFieldInIndex) {
      // both not in index also consider as matched
      totalWeight += indexWeight;
      score += indexWeight * 0.5;
    }

    // 9. field number similarity (extra factor)
    if (oldFieldsCount == newFieldsCount) {
      // field total number is consistent, add a small extra score
      score += 5.0;
      totalWeight += 5.0;
    }

    // calculate final percentage score (0-1)
    return totalWeight > 0 ? score / totalWeight : 0.0;
  }

  /// 检查字段是否在任何索引中
  bool _isFieldInIndex(String fieldName, List<IndexSchema> indexes) {
    for (var index in indexes) {
      if (index.fields.contains(fieldName)) {
        return true;
      }
    }
    return false;
  }

  /// calculate field name similarity
  double _calculateNameSimilarity(String oldName, String newName) {
    // 1. normalize processing: convert to lowercase
    final oldNameLower = oldName.toLowerCase();
    final newNameLower = newName.toLowerCase();

    if (oldNameLower == newNameLower) {
      return 1.0; // fully matched
    }

    // 2. camel and underline conversion comparison
    String oldNameNormalized = _normalizeFieldName(oldNameLower);
    String newNameNormalized = _normalizeFieldName(newNameLower);

    if (oldNameNormalized == newNameNormalized) {
      return 0.9; // very close
    }

    // 3. calculate longest common subsequence
    int lcsLength = _getLongestCommonSubsequenceLength(
        oldNameNormalized, newNameNormalized);
    int maxLength = oldNameNormalized.length > newNameNormalized.length
        ? oldNameNormalized.length
        : newNameNormalized.length;

    // return similarity score between 0-1
    return maxLength > 0 ? lcsLength / maxLength : 0.0;
  }

  /// normalize field name: process camel and underline
  String _normalizeFieldName(String name) {
    // camel to underline
    String result = name.replaceAllMapped(
        RegExp(r'[A-Z]'), (match) => '_${match.group(0)!.toLowerCase()}');

    // process continuous underline
    result = result.replaceAll(RegExp(r'_+'), '_');

    // remove leading underline
    if (result.startsWith('_')) {
      result = result.substring(1);
    }

    return result;
  }

  /// get longest common subsequence length
  int _getLongestCommonSubsequenceLength(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;

    List<List<int>> dp =
        List.generate(a.length + 1, (_) => List.filled(b.length + 1, 0));

    for (int i = 1; i <= a.length; i++) {
      for (int j = 1; j <= b.length; j++) {
        if (a[i - 1] == b[j - 1]) {
          dp[i][j] = dp[i - 1][j - 1] + 1;
        } else {
          dp[i][j] = dp[i - 1][j] > dp[i][j - 1] ? dp[i - 1][j] : dp[i][j - 1];
        }
      }
    }

    return dp[a.length][b.length];
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

    return oldField.type != newField.type ||
        oldField.nullable != newField.nullable ||
        oldField.unique != newField.unique ||
        oldField.maxLength != newField.maxLength ||
        oldField.minLength != newField.minLength ||
        oldField.minValue != newField.minValue ||
        oldField.maxValue != newField.maxValue ||
        !areDefaultValuesEqual() ||
        oldField.comment != newField.comment;
  }

  /// Get next directory index for migration tasks
  Future<int> _getNextDirIndex() async {
    final meta = await _loadMigrationMeta();
    final currentDirIndex = meta.currentDirIndex;
    final dirUsage = Map<int, int>.from(meta.dirUsage);

    final maxEntriesPerDir = _dataStore.config.maxEntriesPerDir;
    if (dirUsage[currentDirIndex]! >= maxEntriesPerDir) {
      final newDirIndex = currentDirIndex + 1;
      dirUsage[newDirIndex] = 0;
      return newDirIndex;
    }
    dirUsage[currentDirIndex] = dirUsage[currentDirIndex]! + 1;
    return currentDirIndex;
  }

  /// Load migration metadata
  Future<MigrationMeta> _loadMigrationMeta() async {
    try {
      final metaPath = _dataStore.pathManager.getMigrationMetaPath();
      final metaContent = await _dataStore.storage.readAsString(metaPath);
      if (metaContent != null && metaContent.isNotEmpty) {
        return MigrationMeta.fromJson(jsonDecode(metaContent));
      }
    } catch (e) {
      Logger.warn(
        'Load migration meta failed, use initial: $e',
        label: 'MigrationManager._loadMigrationMeta',
      );
    }
    return MigrationMeta.initial();
  }

  /// Save migration metadata
  Future<void> _saveMigrationMeta(MigrationMeta meta) async {
    try {
      final metaPath = _dataStore.pathManager.getMigrationMetaPath();
      await _dataStore.storage
          .writeAsString(metaPath, jsonEncode(meta.toJson()));
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

    // update meta data
    final meta = await _loadMigrationMeta();
    final updatedMeta = meta.copyWith(
      currentDirIndex: task.dirIndex,
      dirUsage: Map<int, int>.from(meta.dirUsage)
        ..update(task.dirIndex, (value) => value + 1, ifAbsent: () => 1),
      taskIndex: Map<String, int>.from(meta.taskIndex)
        ..[task.taskId] = task.dirIndex,
    );
    await _saveMigrationMeta(updatedMeta);
  }

  /// Get all space names
  Future<List<String>> _getAllSpaces() async {
    final config = await _dataStore.getGlobalConfig();
    return config?.spaceNames.toList() ?? ['default'];
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
      while (_pendingTasks.isNotEmpty) {
        final task = _pendingTasks.first;

        // set timeout protection, avoid task execution time too long
        const taskTimeout = Duration(minutes: 5); // 5 minutes timeout
        try {
          await _executeMigrationTask(task).timeout(taskTimeout, onTimeout: () {
            Logger.error(
              'Task execution timed out: taskId=${task.taskId}, tableName=${task.tableName}',
              label: 'MigrationManager.processMigrationTasks',
            );

            // timeout consider as failed
            success = false;
            // timeout not remove task, continue to execute next time
            return;
          });

          // task completed successfully, remove and clean up
          _pendingTasks.removeAt(0);
          await _cleanupTask(task);
          // if auto generated task, update table structure definition file
          if (task.isAutoGenerated) {
            final initialSchema = _dataStore.getInitialSchema();
            final schema =
                initialSchema.firstWhere((s) => s.name == task.tableName);
            await _dataStore.updateTableSchema(task.tableName, schema);
          }
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
        }
      }

      // update global config after all tasks are completed
      final globalConfig = await _dataStore.getGlobalConfig();
      if (globalConfig != null) {
        await _dataStore
            .saveGlobalConfig(globalConfig.copyWith(hasMigrationTask: false));
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
    try {
      // record task start time
      final taskStopwatch = Stopwatch()..start();
      Logger.info(
        'Starting migration task execution: ${task.taskId}, table: ${task.tableName}',
        label: 'MigrationManager._executeMigrationTask',
      );

      // sort operations, ensure rename field operation is executed after property modification operation
      final sortedOperations = _sortOperations(List.from(task.operations));

      // save data in write buffer to disk before migration
      await _dataStore.tableDataManager.flushAllBuffers();

      // clear table record cache
      await _dataStore.dataCacheManager.invalidateCache(task.tableName);

      // update global table structure first
      if (!task.isSchemaUpdated) {
        await executeSchemaOperations(task.tableName, sortedOperations);
        final updatedTask = task.setSchemaUpdated(true);
        await _saveMigrationTask(updatedTask);
      }

      // get latest space priority order
      final globalConfig = await _dataStore.getGlobalConfig();
      final prioritizedSpaces = globalConfig?.spaceNames.toList() ?? [];

      // sort pending spaces by priority order
      final pendingSpaces = List<String>.from(task.pendingMigrationSpaces);
      pendingSpaces.sort((a, b) {
        final indexA = prioritizedSpaces.indexOf(a);
        final indexB = prioritizedSpaces.indexOf(b);
        return indexA.compareTo(indexB);
      });

      // get updated table name
      String originalTableName = task.tableName;
      String currentTableName = task.tableName;
      MigrationOperation? renameOp;
      try {
        renameOp = task.operations.firstWhere(
          (op) => op.type == MigrationType.renameTable,
        );
      } catch (e) {
        renameOp = null;
      }
      if (renameOp != null && renameOp.newTableName != null) {
        currentTableName = renameOp.newTableName!;
      }

      // get old table structure information
      final oldSchema = await _dataStore.getTableSchema(originalTableName);

      Logger.info(
        'Preparing to migrate data for ${pendingSpaces.length} spaces',
        label: 'MigrationManager._executeMigrationTask',
      );

      // process data migration for each space
      for (var space in pendingSpaces) {
        final spaceStopwatch = Stopwatch()..start();

        // create migration instance for specific space
        final migrationInstance = DataStoreImpl(
            dbPath: _dataStore.config.dbPath,
            config: _dataStore.config.copyWith(spaceName: space),
            isMigrationInstance: true);
        await migrationInstance.initialize();

        for (var operation in task.operations) {
          if (operation.type == MigrationType.addIndex) {
            await migrationInstance.indexManager
                ?.addIndex(currentTableName, operation.index!);
          } else if (operation.type == MigrationType.removeIndex) {
            // handle removeIndex operation, support delete by field list or index name
            final indexNameToRemove = operation.indexName;
            final fieldsToRemove = operation.fields;

            if (indexNameToRemove != null) {
              // if index name exists, delete by name
              await migrationInstance.indexManager
                  ?.removeIndex(currentTableName, indexName: indexNameToRemove);
            } else if (fieldsToRemove != null && fieldsToRemove.isNotEmpty) {
              // delete by field list
              await migrationInstance.indexManager
                  ?.removeIndex(currentTableName, fields: fieldsToRemove);
            }
          } else if (operation.type == MigrationType.modifyIndex) {
            await migrationInstance.indexManager?.modifyIndex(
              currentTableName,
              operation.indexName ?? operation.fields!.join('_'),
              IndexSchema(
                indexName: operation.indexName,
                fields: operation.fields!,
                unique: operation.unique ?? false,
              ),
            );
          } else if (operation.type == MigrationType.dropTable) {
            await migrationInstance.dropTable(task.tableName,
                isMigration: true);
          } else if (operation.type == MigrationType.removeField) {
            // delete all indexes containing the field before deleting the field
            final fieldName = operation.fieldName!;
            await migrationInstance.indexManager
                ?.removeIndex(currentTableName, fields: [fieldName]);
          }
        }

        // Check if should cache table (only when current space and table allow full table cache)
        bool shouldCache = space == _dataStore.currentSpaceName &&
            await _dataStore.tableDataManager
                .allowFullTableCache(currentTableName);
        final List<Map<String, dynamic>> allMigratedRecords =
            <Map<String, dynamic>>[];

        // Process data migration based on migration type, collect records for cache
        if (renameOp != null && renameOp.newTableName != null) {
          // use high performance batch processing method instead of stream processing
          await migrationInstance.tableDataManager
              .rewriteRecordsFromSourceTable(
            sourceTableName: originalTableName,
            targetTableName: currentTableName,
            processFunction: (records, partitionIndex) async {
              // apply migration operations to records
              final modifiedRecords = _applyMigrationOperations(
                  records, sortedOperations,
                  oldSchema: oldSchema);

              // if need cache, collect records
              if (shouldCache) {
                allMigratedRecords.addAll(modifiedRecords
                    .map((r) => Map<String, dynamic>.from(r))
                    .toList());
              }

              return modifiedRecords;
            },
          );
          // record partition migration performance data
          final migrationDuration = spaceStopwatch.elapsedMilliseconds;
          Logger.info(
            'Table rename batch processing performance: $migrationDuration ms for table $originalTableName -> $currentTableName',
            label: 'MigrationManager._executeMigrationTask',
          );
        } else {
          // no rename table operation, directly process data migration
          await migrationInstance.tableDataManager.processTablePartitions(
              tableName: currentTableName,
              processFunction: (records, partitionIndex) async {
                final migratedRecords = _applyMigrationOperations(
                    records, sortedOperations,
                    oldSchema: oldSchema);

                // if need cache, collect records
                if (shouldCache) {
                  allMigratedRecords.addAll(migratedRecords
                      .map((r) => Map<String, dynamic>.from(r))
                      .toList());
                }

                return migratedRecords;
              });
        }

        // if collect records, add to cache
        if (allMigratedRecords.isNotEmpty) {
          final schema = await _dataStore.getTableSchema(currentTableName);
          if (schema != null) {
            await _dataStore.dataCacheManager.cacheEntireTable(
              currentTableName,
              allMigratedRecords,
              schema.primaryKey,
              isFullTableCache: true,
            );
          }
        }

        // update task status
        final updatedTask = task.removePendingSpace(space);
        await _saveMigrationTask(updatedTask);

        // close migration instance
        await migrationInstance.close();

        spaceStopwatch.stop();
        Logger.info(
          'Space [$space] migration completed, time taken: ${spaceStopwatch.elapsedMilliseconds}ms',
          label: 'MigrationManager._executeMigrationTask',
        );
      }

      // if rename table operation exists, delete old table data and structure after new table creation
      if (renameOp != null && renameOp.newTableName != null) {
        await _dataStore.dropTable(originalTableName);
      }

      // calculate and print total time
      taskStopwatch.stop();
      Logger.info(
        'Migration task [${task.taskId}] completed, total time: ${taskStopwatch.elapsedMilliseconds}ms',
        label: 'MigrationManager._executeMigrationTask',
      );
    } catch (e, stack) {
      Logger.error(
        'Execute migration task failed: $e\n$stack',
        label: 'MigrationManager._executeMigrationTask',
      );
      rethrow;
    }
  }

  /// Apply migration operations to records
  List<Map<String, dynamic>> _applyMigrationOperations(
      List<Map<String, dynamic>> records, List<MigrationOperation> operations,
      {TableSchema? oldSchema}) {
    var modifiedRecords = List<Map<String, dynamic>>.from(records);

    // use the incoming sorted operations, no need to sort again
    for (var operation in operations) {
      switch (operation.type) {
        case MigrationType.addField:
          final field = operation.field!;
          modifiedRecords = modifiedRecords.map((record) {
            if (!record.containsKey(field.name)) {
              record[field.name] = field.getDefaultValue();
            }
            return record;
          }).toList();
          break;

        case MigrationType.removeField:
          final fieldName = operation.fieldName!;
          modifiedRecords = modifiedRecords.map((record) {
            record.remove(fieldName);
            return record;
          }).toList();
          break;

        case MigrationType.renameField:
          final oldName = operation.fieldName!;
          final newName = operation.newName!;
          modifiedRecords = modifiedRecords.map((record) {
            if (record.containsKey(oldName)) {
              record[newName] = record[oldName];
              record.remove(oldName);
            }
            return record;
          }).toList();
          break;

        case MigrationType.modifyField:
          final fieldUpdate = operation.fieldUpdate!;
          // get old field information
          FieldSchema? oldFieldSchema;
          if (oldSchema != null) {
            try {
              oldFieldSchema = oldSchema.fields
                  .firstWhere((f) => f.name == fieldUpdate.name);
            } catch (e) {
              oldFieldSchema = null;
            }
          }
          modifiedRecords = modifiedRecords.map((record) {
            if (record.containsKey(fieldUpdate.name)) {
              // call the extracted method to handle field modification, pass old field information
              record = _applyFieldModification(record, fieldUpdate,
                  oldFieldSchema: oldFieldSchema);
            }
            return record;
          }).toList();
          break;

        case MigrationType.addIndex:
          // index operation does not affect record data
          break;

        case MigrationType.removeIndex:
          break;

        case MigrationType.modifyIndex:
          break;

        case MigrationType.renameTable:
          // table rename operation does not affect current record data, but needs to be handled at a higher level
          break;

        case MigrationType.dropTable:
          // drop table operation does not affect record data
          break;

        case MigrationType.setPrimaryKeyConfig:
          // handle primary key configuration changes, especially handle primary key name changes and data type changes
          if (operation.oldPrimaryKeyConfig != null &&
              operation.primaryKeyConfig != null) {
            final oldConfig = operation.oldPrimaryKeyConfig!;
            final newConfig = operation.primaryKeyConfig!;

            // handle primary key name changes
            if (oldConfig.name != newConfig.name) {
              modifiedRecords = modifiedRecords.map((record) {
                if (record.containsKey(oldConfig.name)) {
                  // copy old primary key field value to new primary key field
                  record[newConfig.name] = record[oldConfig.name];
                  // delete old primary key field
                  record.remove(oldConfig.name);
                }
                return record;
              }).toList();
            }
          }
          break;
      }
    }

    return modifiedRecords;
  }

  /// Apply field modification to a single record with old field schema information
  Map<String, dynamic> _applyFieldModification(
      Map<String, dynamic> record, FieldSchemaUpdate fieldUpdate,
      {FieldSchema? oldFieldSchema}) {
    // create field schema for validation and get default value
    final fieldSchema = FieldSchema(
      name: fieldUpdate.name,
      type: fieldUpdate.type ?? (oldFieldSchema?.type ?? DataType.text),
      nullable: fieldUpdate.nullable ?? (oldFieldSchema?.nullable ?? true),
      defaultValue: fieldUpdate.defaultValue ?? oldFieldSchema?.defaultValue,
      unique: fieldUpdate.unique ?? (oldFieldSchema?.unique ?? false),
      maxLength: fieldUpdate.maxLength ?? oldFieldSchema?.maxLength,
      minLength: fieldUpdate.minLength ?? oldFieldSchema?.minLength,
      minValue: fieldUpdate.minValue ?? oldFieldSchema?.minValue,
      maxValue: fieldUpdate.maxValue ?? oldFieldSchema?.maxValue,
      comment: fieldUpdate.comment ?? oldFieldSchema?.comment,
    );

    // 1. handle type changes
    if (fieldUpdate.type != null) {
      try {
        record[fieldUpdate.name] = fieldSchema.convertValue(
          value: record[fieldUpdate.name],
        );
      } catch (e) {
        record[fieldUpdate.name] = fieldSchema.getDefaultValue();
        Logger.warn(
          'Failed to convert field ${fieldUpdate.name} to type ${fieldUpdate.type}, using default value: $e',
          label: 'MigrationManager._applyFieldModification',
        );
      }
    }

    // 2. handle null value constraint changes
    if (fieldUpdate.nullable != null &&
        !fieldUpdate.nullable! &&
        record[fieldUpdate.name] == null) {
      record[fieldUpdate.name] = fieldSchema.getDefaultValue();
      Logger.debug(
        'Field ${fieldUpdate.name} is now non-nullable, applied default value',
        label: 'MigrationManager._applyFieldModification',
      );
    }

    // 3. handle default value changes
    if (fieldUpdate.defaultValue != null && record[fieldUpdate.name] == null) {
      record[fieldUpdate.name] = fieldUpdate.defaultValue;
      Logger.debug(
        'Field ${fieldUpdate.name} has new default value, applied to null value',
        label: 'MigrationManager._applyFieldModification',
      );
    }

    // 4. handle unique constraint changes (only log, data itself is not directly processed)
    if (fieldUpdate.unique != null && fieldUpdate.unique!) {
      Logger.debug(
        'Field ${fieldUpdate.name} now has unique constraint, further validation may be needed',
        label: 'MigrationManager._applyFieldModification',
      );
    }

    // 5. handle length constraint changes (only log, data itself is not directly processed)
    if ((fieldUpdate.maxLength != null || fieldUpdate.minLength != null) &&
        record[fieldUpdate.name] is String) {
      String value = record[fieldUpdate.name];
      if (fieldUpdate.maxLength != null &&
          value.length > fieldUpdate.maxLength!) {
        record[fieldUpdate.name] = value.substring(0, fieldUpdate.maxLength!);
        Logger.warn(
          'Field ${fieldUpdate.name} exceeds max length of ${fieldUpdate.maxLength}, truncated',
          label: 'MigrationManager._applyFieldModification',
        );
      }
      if (fieldUpdate.minLength != null &&
          value.length < fieldUpdate.minLength!) {
        record[fieldUpdate.name] = fieldSchema.getDefaultValue();
        Logger.warn(
          'Field ${fieldUpdate.name} is shorter than min length of ${fieldUpdate.minLength}, using default value',
          label: 'MigrationManager._applyFieldModification',
        );
      }
    }

    // 6. handle numeric range constraint changes (only log, data itself is not directly processed)
    if ((fieldUpdate.minValue != null || fieldUpdate.maxValue != null) &&
        record[fieldUpdate.name] is num) {
      num value = record[fieldUpdate.name];

      if (fieldUpdate.minValue != null && value < fieldUpdate.minValue!) {
        record[fieldUpdate.name] = fieldUpdate.minValue;
        Logger.warn(
          'Field ${fieldUpdate.name} below min value of ${fieldUpdate.minValue}, set to min',
          label: 'MigrationManager._applyFieldModification',
        );
      }

      if (fieldUpdate.maxValue != null && value > fieldUpdate.maxValue!) {
        record[fieldUpdate.name] = fieldUpdate.maxValue;
        Logger.warn(
          'Field ${fieldUpdate.name} exceeds max value of ${fieldUpdate.maxValue}, set to max',
          label: 'MigrationManager._applyFieldModification',
        );
      }
    }

    // 7. final validation
    if (!fieldSchema.validateValue(record[fieldUpdate.name])) {
      record[fieldUpdate.name] = fieldSchema.getDefaultValue();
      Logger.warn(
        'Field ${fieldUpdate.name} value does not meet constraints after updates, using default value',
        label: 'MigrationManager._applyFieldModification',
      );
    }

    return record;
  }

  /// Cleanup task files after completion
  Future<void> _cleanupTask(MigrationTask task) async {
    try {
      final taskPath = _dataStore.pathManager
          .getMigrationTaskPath(task.dirIndex, task.taskId);
      await _dataStore.storage.deleteFile(taskPath);

      // update meta data
      final meta = await _loadMigrationMeta();
      final updatedTaskIndex = Map<String, int>.from(meta.taskIndex)
        ..remove(task.taskId);
      final updatedDirUsage = Map<int, int>.from(meta.dirUsage)
        ..update(task.dirIndex, (value) => value - 1);

      final updatedMeta = meta.copyWith(
        dirUsage: updatedDirUsage,
        taskIndex: updatedTaskIndex,
      );
      await _saveMigrationMeta(updatedMeta);
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
      // check if global config has unfinished migration
      final globalConfig = await _dataStore.getGlobalConfig();
      if (globalConfig != null && globalConfig.hasMigrationTask) {
        // load migration meta data
        final meta = await _loadMigrationMeta();
        if (meta.taskIndex.isNotEmpty) {
          // load unfinished tasks one by one
          for (final entry in meta.taskIndex.entries) {
            final taskId = entry.key;
            final dirIndex = entry.value;

            try {
              // read task file
              final taskPath =
                  _dataStore.pathManager.getMigrationTaskPath(dirIndex, taskId);
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
                }
              }
            } catch (e) {
              Logger.warn(
                'Failed to load task: taskId[$taskId], error[$e]',
                label: 'MigrationManager.initialize',
              );
            }
          }

          // start processing recovered tasks
          if (_pendingTasks.isNotEmpty) {
            final success = await processMigrationTasks();
            if (!success) {
              Logger.warn(
                'Some recovered migration tasks failed, please check the log for details',
                label: 'MigrationManager.initialize',
              );
            }
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

  /// sort migration operations, ensure rename operation is executed after other operations
  List<MigrationOperation> _sortOperations(
      List<MigrationOperation> operations) {
    // operation priority (the smaller the number, the higher the priority)
    final priorityMap = <MigrationType, int>{
      MigrationType.addField: 1, // add field first
      MigrationType.setPrimaryKeyConfig: 2,
      MigrationType.modifyField: 3, // then modify field properties
      MigrationType.addIndex: 4,
      MigrationType.modifyIndex: 5,
      MigrationType.removeIndex: 6,
      MigrationType.renameField: 7, // rename field
      MigrationType.removeField: 8, // remove field
      MigrationType.renameTable: 9, // rename table
      MigrationType.dropTable: 10,
    };

    operations.sort((a, b) {
      return (priorityMap[a.type] ?? 99).compareTo(priorityMap[b.type] ?? 99);
    });

    return operations;
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
      final meta = await _loadMigrationMeta();
      final taskIndex = meta.taskIndex;

      if (!taskIndex.containsKey(taskId)) {
        // task completed or not exist
        return MigrationStatus(
          taskId: taskId,
          isCompleted: true, // task ID not in index, consider as completed
          createTime: DateTime.now(),
          pendingSpaces: const [],
          processedSpacesCount: 0,
          totalSpacesCount: 0,
        );
      }

      // get task directory index
      final dirIndex = taskIndex[taskId]!;

      // read task file
      final taskPath =
          _dataStore.pathManager.getMigrationTaskPath(dirIndex, taskId);
      final taskContent = await _dataStore.storage.readAsString(taskPath);

      if (taskContent == null || taskContent.isEmpty) {
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

      return MigrationStatus(
        taskId: taskId,
        isCompleted: pendingSpaces.isEmpty,
        createTime: task.createTime,
        pendingSpaces: pendingSpaces,
        processedSpacesCount: processedSpaces,
        totalSpacesCount: allSpaces.length,
      );
    } catch (e) {
      Logger.error(
        'Failed to query task status: $e',
        label: 'MigrationManager.queryTaskStatus',
      );
      return null;
    }
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
