import '../handler/logger.dart';
import '../model/table_schema.dart';
import 'data_store_impl.dart';
import 'transaction_manager.dart';

/// Migration manager for handling database version upgrades
class MigrationManager {
  final DataStoreImpl _dataStore;

  MigrationManager(this._dataStore);

  /// Execute migration from old version to new version
  Future<void> migrate(
      int oldVersion, int newVersion, List<TableSchema> schemas,
      {int batchSize = 1000}) async {
    try {
      // Get all existing tables
      final existingTables = await _dataStore.getTableNames();

      // Process each schema
      for (var schema in schemas) {
        if (existingTables.contains(schema.name)) {
          // Migrate existing table
          await _migrateExistingTable(schema, batchSize: batchSize);
        } else {
          // Create new table
          await _dataStore.createTable(schema);
        }
      }
    } catch (e, stack) {
      Logger.error(
        'Database migration failed: $e\n$stack',
        label: 'MigrationManager.migrate',
      );
      rethrow;
    }
  }

  /// Migrate existing table schema
  Future<void> _migrateExistingTable(TableSchema newSchema,
      {required int batchSize}) async {
    final tableName = newSchema.name;
    final oldSchema = await _dataStore.getTableSchema(tableName);

    // Compare schemas and generate operations
    final operations =
        _compareSchemasAndGenerateOperations(oldSchema, newSchema);

    if (operations.isEmpty) {
      Logger.debug(
        'No changes detected for table $tableName',
        label: 'MigrationManager._migrateExistingTable',
      );
      return;
    }
    // Execute operations in transaction
    await _dataStore.transaction((txn) async {
      for (var operation in operations) {
        switch (operation.type) {
          case MigrationType.addField:
            await _dataStore.addField(tableName, operation.field!, txn);
            await _dataStore.addFieldToRecords(
              tableName,
              operation.field!,
              batchSize: batchSize,
            );
            break;

          case MigrationType.dropField:
            await _dataStore.dropField(tableName, operation.oldName!, txn);
            await _dataStore.removeFieldFromRecords(
              tableName,
              operation.oldName!,
              batchSize: batchSize,
            );
            break;

          case MigrationType.renameField:
            await _dataStore.renameField(
              tableName,
              operation.oldName!,
              operation.newName!,
              txn,
            );
            await _dataStore.renameFieldInRecords(
              tableName,
              operation.oldName!,
              operation.newName!,
              batchSize: batchSize,
            );
            break;

          case MigrationType.modifyField:
            final oldField = oldSchema.fields.firstWhere(
              (f) => f.name == operation.field!.name,
            );
            await _dataStore.modifyField(
              tableName,
              operation.field!.name,
              operation.field!,
              txn,
            );
            await _migrateFieldData(
              tableName,
              oldField,
              operation.field!,
              txn,
              batchSize: batchSize,
            );
            break;

          case MigrationType.addIndex:
            await _dataStore.addIndex(tableName, operation.index!, txn);
            break;

          case MigrationType.dropIndex:
            if (operation.indexName != null) {
              await _dataStore.dropIndex(
                tableName,
                operation.indexName!,
                txn,
              );
            }
            break;

          case MigrationType.modifyIndex:
            await _dataStore.modifyIndex(
              tableName,
              operation.indexName ?? operation.fields!.join('_'),
              IndexSchema(
                indexName: operation.indexName,
                fields: operation.fields!,
                unique: operation.unique ?? false,
              ),
              txn,
            );
            break;
        }
      }
      // Update schema file with new schema
      await _dataStore.updateTableSchema(tableName, newSchema);
    });
  }

  /// Compare schemas and generate operations
  List<MigrationOperation> _compareSchemasAndGenerateOperations(
    TableSchema oldSchema,
    TableSchema newSchema,
  ) {
    final operations = <MigrationOperation>[];

    // Check fields changes
    _compareFields(oldSchema, newSchema, operations);

    // Check indexes changes
    _compareIndexes(oldSchema, newSchema, operations);

    return operations;
  }

  /// Compare fields and generate operations
  void _compareFields(
    TableSchema oldSchema,
    TableSchema newSchema,
    List<MigrationOperation> operations,
  ) {
    // Check for added fields
    for (var newField in newSchema.fields) {
      if (!oldSchema.fields.any((f) => f.name == newField.name)) {
        operations.add(MigrationOperation(
          type: MigrationType.addField,
          field: newField,
        ));
        continue;
      }

      // Check for modified fields
      final oldField = oldSchema.fields.firstWhere(
        (f) => f.name == newField.name,
      );
      if (_isFieldModified(oldField, newField)) {
        operations.add(MigrationOperation(
          type: MigrationType.modifyField,
          field: newField,
        ));
      }
    }

    // Check for removed fields
    for (var oldField in oldSchema.fields) {
      if (!newSchema.fields.any((f) => f.name == oldField.name)) {
        operations.add(MigrationOperation(
          type: MigrationType.dropField,
          oldName: oldField.name,
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
    // Check for added and modified indexes
    for (var newIndex in newSchema.indexes) {
      final oldIndex = oldSchema.indexes.firstWhere(
        (i) => _areIndexesSame(i, newIndex),
        orElse: () => const IndexSchema(fields: []),
      );

      if (oldIndex.fields.isEmpty) {
        // New index
        operations.add(MigrationOperation(
          type: MigrationType.addIndex,
          index: newIndex,
        ));
      } else if (_isIndexModified(oldIndex, newIndex)) {
        // Modified index
        operations.add(MigrationOperation(
          type: MigrationType.modifyIndex,
          indexName: newIndex.indexName,
          fields: newIndex.fields,
          unique: newIndex.unique,
        ));
      }
    }

    // Check for dropped indexes
    for (var oldIndex in oldSchema.indexes) {
      if (!newSchema.indexes.any((i) => _areIndexesSame(i, oldIndex))) {
        operations.add(MigrationOperation(
          type: MigrationType.dropIndex,
          indexName: oldIndex.indexName,
          fields: oldIndex.fields,
        ));
      }
    }
  }

  /// Check if two indexes are the same
  bool _areIndexesSame(IndexSchema a, IndexSchema b) {
    if (a.indexName != null && b.indexName != null) {
      return a.indexName == b.indexName;
    }
    // 如果没有 indexName，比较字段列表
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

  /// Detect renamed fields using heuristics
  void _detectRenamedFields(
    TableSchema oldSchema,
    TableSchema newSchema,
    List<MigrationOperation> operations,
  ) {
    // Get removed and added fields
    final removedFields = operations
        .where((op) => op.type == MigrationType.dropField)
        .map((op) => op.oldName!)
        .toList();
    final addedFields = operations
        .where((op) => op.type == MigrationType.addField)
        .map((op) => op.field!)
        .toList();

    // Try to match removed and added fields with similar types
    for (var oldName in removedFields) {
      final oldField = oldSchema.fields.firstWhere((f) => f.name == oldName);

      for (var newField in addedFields) {
        if (_areFieldsSimilar(oldField, newField)) {
          // Remove the add and drop operations
          operations.removeWhere((op) =>
              (op.type == MigrationType.dropField && op.oldName == oldName) ||
              (op.type == MigrationType.addField && op.field == newField));

          // Add rename operation
          operations.add(MigrationOperation(
            type: MigrationType.renameField,
            oldName: oldName,
            newName: newField.name,
          ));
          break;
        }
      }
    }
  }

  /// Check if two fields are similar (likely renamed)
  bool _areFieldsSimilar(FieldSchema oldField, FieldSchema newField) {
    // Same type is a strong indicator
    if (oldField.type != newField.type) {
      return false;
    }

    // Similar constraints increase likelihood
    int similarity = 0;
    if (oldField.nullable == newField.nullable) similarity++;
    if (oldField.unique == newField.unique) similarity++;
    if (oldField.maxLength == newField.maxLength) similarity++;
    if (oldField.defaultValue == newField.defaultValue) similarity++;

    // Consider fields similar if they share most properties
    return similarity >= 3;
  }

  /// Check if field is modified
  bool _isFieldModified(FieldSchema oldField, FieldSchema newField) {
    return oldField.type != newField.type ||
        oldField.nullable != newField.nullable ||
        oldField.unique != newField.unique ||
        oldField.maxLength != newField.maxLength ||
        oldField.defaultValue != newField.defaultValue ||
        oldField.comment != newField.comment;
  }

  /// Migrate field data
  Future<void> _migrateFieldData(String tableName, FieldSchema oldField,
      FieldSchema newField, Transaction txn,
      {required int batchSize}) async {
    try {
      await _dataStore.migrateFieldData(tableName, oldField, newField, txn);
    } catch (e) {
      Logger.error(
        'Field data migration failed: $e',
        label: 'MigrationManager._migrateFieldData',
      );
      rethrow;
    }
  }
}

/// Migration operation type
enum MigrationType {
  addField,
  dropField,
  renameField,
  modifyField,
  addIndex,
  dropIndex,
  modifyIndex,
}

/// Migration operation
class MigrationOperation {
  final MigrationType type;
  final FieldSchema? field;
  final String? oldName;
  final String? newName;
  final IndexSchema? index;
  final String? indexName;
  final List<String>? fields;
  final bool? unique;

  const MigrationOperation({
    required this.type,
    this.field,
    this.oldName,
    this.newName,
    this.index,
    this.indexName,
    this.fields,
    this.unique,
  });

  @override
  String toString() {
    switch (type) {
      case MigrationType.addField:
        return 'Add field: ${field?.name}';
      case MigrationType.dropField:
        return 'Drop field: $oldName';
      case MigrationType.renameField:
        return 'Rename field: $oldName -> $newName';
      case MigrationType.modifyField:
        return 'Modify field: ${field?.name}';
      case MigrationType.addIndex:
        return 'Add index: ${index?.indexName ?? index?.fields.join("_")}';
      case MigrationType.dropIndex:
        return 'Drop index: ${indexName ?? fields?.join("_")}';
      case MigrationType.modifyIndex:
        return 'Modify index: ${indexName ?? fields?.join("_")}';
    }
  }
}
