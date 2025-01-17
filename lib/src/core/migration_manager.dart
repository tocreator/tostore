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

          case MigrationType.removeField:
            await _dataStore.removeField(tableName, operation.oldName!, txn);
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

          case MigrationType.removeIndex:
            if (operation.indexName != null) {
              await _dataStore.removeIndex(
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
          type: MigrationType.removeField,
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

    // Check for remove indexes
    for (var oldIndex in oldSchema.indexes) {
      if (!newSchema.indexes.any((i) => _areIndexesSame(i, oldIndex))) {
        operations.add(MigrationOperation(
          type: MigrationType.removeIndex,
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

  /// Detect renamed fields using strict matching
  void _detectRenamedFields(
    TableSchema oldSchema,
    TableSchema newSchema,
    List<MigrationOperation> operations,
  ) {
    // Get removed and added fields
    final removedFields = operations
        .where((op) => op.type == MigrationType.removeField)
        .map((op) => op.oldName!)
        .toList();
    final addedFields = operations
        .where((op) => op.type == MigrationType.addField)
        .map((op) => op.field!)
        .toList();

    // Only process when exactly one field is removed and one field is added
    if (removedFields.isEmpty || addedFields.isEmpty) return;
    if (removedFields.length != 1 || addedFields.length != 1) return;
    final oldName = removedFields.first;
    final newField = addedFields.first;
    final oldField = oldSchema.fields.firstWhere((f) => f.name == oldName);

    // Check if all attributes match exactly
    if (_calculateFieldSimilarity(oldField, newField) == 1.0) {
      // Convert add and remove operations to rename
      operations.removeWhere((op) =>
          (op.type == MigrationType.removeField && op.oldName == oldName) ||
          (op.type == MigrationType.addField && op.field == newField));

      operations.add(MigrationOperation(
        type: MigrationType.renameField,
        oldName: oldName,
        newName: newField.name,
      ));
    }
  }

  /// Calculate similarity between fields - strict matching
  double _calculateFieldSimilarity(FieldSchema oldField, FieldSchema newField) {
    // All critical attributes must match exactly
    if (oldField.type != newField.type ||
        oldField.nullable != newField.nullable ||
        oldField.unique != newField.unique ||
        oldField.maxLength != newField.maxLength ||
        oldField.defaultValue != newField.defaultValue) {
      return 0.0;
    }

    // If all attributes match, return full score
    return 1.0;
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
  removeField,
  renameField,
  modifyField,
  addIndex,
  removeIndex,
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
      case MigrationType.removeField:
        return 'Drop field: $oldName';
      case MigrationType.renameField:
        return 'Rename field: $oldName -> $newName';
      case MigrationType.modifyField:
        return 'Modify field: ${field?.name}';
      case MigrationType.addIndex:
        return 'Add index: ${index?.indexName ?? index?.fields.join("_")}';
      case MigrationType.removeIndex:
        return 'Drop index: ${indexName ?? fields?.join("_")}';
      case MigrationType.modifyIndex:
        return 'Modify index: ${indexName ?? fields?.join("_")}';
    }
  }
}
