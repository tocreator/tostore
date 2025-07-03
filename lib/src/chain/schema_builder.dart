import '../core/data_store_impl.dart';
import '../model/migration_task.dart';
import '../model/table_schema.dart';
import '../Interface/future_builder_mixin.dart';

/// Schema builder for chain operations
class SchemaBuilder with FutureBuilderMixin {
  final DataStoreImpl _dataStore;
  final String _tableName;
  final List<MigrationOperation> _operations = [];
  bool _allowAfterDataMigration = false;

  SchemaBuilder(this._dataStore, this._tableName);

  /// Add field to table
  SchemaBuilder addField(
    String name, {
    required DataType type,
    bool? nullable,
    dynamic defaultValue,
    bool? unique,
    String? comment,
  }) {
    _operations.add(MigrationOperation(
      type: MigrationType.addField,
      field: FieldSchema(
        name: name,
        type: type,
        nullable: nullable ?? true,
        defaultValue: defaultValue,
        unique: unique ?? false,
        comment: comment,
      ),
    ));
    return this;
  }

  /// Remove field from table
  SchemaBuilder removeField(String fieldName) {
    _operations.add(MigrationOperation(
      type: MigrationType.removeField,
      fieldName: fieldName,
    ));
    return this;
  }

  /// Rename field
  SchemaBuilder renameField(String oldName, String newName) {
    _operations.add(MigrationOperation(
      type: MigrationType.renameField,
      fieldName: oldName,
      newName: newName,
    ));
    return this;
  }

  /// Modify field
  SchemaBuilder modifyField(
    String fieldName, {
    DataType? type,
    bool? nullable,
    dynamic defaultValue,
    bool? unique,
    int? maxLength,
    int? minLength,
    num? minValue,
    num? maxValue,
    String? comment,
    DefaultValueType? defaultValueType,
  }) {
    _operations.add(MigrationOperation(
      type: MigrationType.modifyField,
      fieldName: fieldName,
      fieldUpdate: FieldSchemaUpdate(
        name: fieldName,
        type: type,
        nullable: nullable,
        defaultValue: defaultValue,
        unique: unique,
        comment: comment,
        minLength: minLength,
        maxLength: maxLength,
        minValue: minValue,
        maxValue: maxValue,
        defaultValueType: defaultValueType,
      ),
    ));
    return this;
  }

  /// Add index
  SchemaBuilder addIndex(
    String name, {
    required List<String> fields,
    bool? unique,
    IndexType type = IndexType.btree,
  }) {
    _operations.add(MigrationOperation(
      type: MigrationType.addIndex,
      index: IndexSchema(
        indexName: name,
        fields: fields,
        unique: unique ?? false,
        type: type,
      ),
    ));
    return this;
  }

  /// Remove index
  SchemaBuilder removeIndex({String? indexName, List<String>? fields}) {
    if (indexName == null && (fields == null || fields.isEmpty)) {
      throw ArgumentError('must provide indexName or fields');
    }

    _operations.add(MigrationOperation(
      type: MigrationType.removeIndex,
      indexName: indexName,
      fields: fields,
    ));
    return this;
  }

  /// Confirms that data migration is allowed to run after this schema change.
  SchemaBuilder allowAfterDataMigration() {
    _allowAfterDataMigration = true;
    return this;
  }

  /// Rename table
  SchemaBuilder renameTable(String newTableName) {
    _operations.add(MigrationOperation(
      type: MigrationType.renameTable,
      newTableName: newTableName,
    ));
    return this;
  }

  /// Set primary key config
  SchemaBuilder setPrimaryKeyConfig(PrimaryKeyConfig config) {
    _operations.add(MigrationOperation(
      type: MigrationType.setPrimaryKeyConfig,
      primaryKeyConfig: config,
    ));
    return this;
  }

  /// Get future result - returns migration task ID for tracking
  @override
  Future<String> get future async {
    // create migration task
    final task = await _dataStore.migrationManager?.addMigrationTask(
        _tableName, _operations,
        startProcessing: false,
        allowAfterDataMigration: _allowAfterDataMigration);

    if (task == null) {
      return ''; // Return empty string to indicate creation failed
    }

    // Create task ID
    final taskId = task.taskId;

    // Start task processing and wait for completion
    try {
      await _dataStore.migrationManager?.processMigrationTasks();
      return taskId;
    } catch (e) {
      // Return task ID even if failed, for subsequent query
      return taskId;
    }
  }
}
