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
    int? maxLength,
    int? minLength,
    num? minValue,
    num? maxValue,
    String? comment,
    DefaultValueType? defaultValueType,
    VectorFieldConfig? vectorConfig,
  }) {
    _operations.add(MigrationOperation(
      type: MigrationType.addField,
      field: FieldSchema(
        name: name,
        type: type,
        nullable: nullable ?? true,
        defaultValue: defaultValue,
        unique: unique ?? false,
        maxLength: maxLength,
        minLength: minLength,
        minValue: minValue,
        maxValue: maxValue,
        comment: comment,
        defaultValueType: defaultValueType ?? DefaultValueType.none,
        vectorConfig: vectorConfig,
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
    VectorFieldConfig? vectorConfig,
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
        vectorConfig: vectorConfig,
      ),
    ));
    return this;
  }

  /// Add index
  SchemaBuilder addIndex({
    required List<String> fields,
    String? indexName,
    bool? unique,
    IndexType type = IndexType.btree,
    VectorIndexConfig? vectorConfig,
  }) {
    _operations.add(MigrationOperation(
      type: MigrationType.addIndex,
      index: IndexSchema(
        indexName: indexName,
        fields: fields,
        unique: unique ?? false,
        type: type,
        vectorConfig: vectorConfig,
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

  /// Add foreign key to table
  SchemaBuilder addForeignKey({
    String? name,
    required List<String> fields,
    required String referencedTable,
    required List<String> referencedFields,
    ForeignKeyCascadeAction onDelete = ForeignKeyCascadeAction.restrict,
    ForeignKeyCascadeAction onUpdate = ForeignKeyCascadeAction.restrict,
    bool autoCreateIndex = true,
    bool enabled = true,
    String? comment,
  }) {
    _operations.add(MigrationOperation(
      type: MigrationType.addForeignKey,
      foreignKey: ForeignKeySchema(
        name: name,
        fields: fields,
        referencedTable: referencedTable,
        referencedFields: referencedFields,
        onDelete: onDelete,
        onUpdate: onUpdate,
        autoCreateIndex: autoCreateIndex,
        enabled: enabled,
        comment: comment,
      ),
    ));
    return this;
  }

  /// Remove foreign key from table
  SchemaBuilder removeForeignKey(String foreignKeyName) {
    _operations.add(MigrationOperation(
      type: MigrationType.removeForeignKey,
      foreignKeyName: foreignKeyName,
    ));
    return this;
  }

  /// Modify foreign key properties
  ///
  /// Note: Core definitions (fields, referencedTable, referencedFields) cannot be modified.
  /// If these need to change, remove the old foreign key and add a new one.
  ///
  /// The actual modification will be done in migration manager during execution,
  /// which will load the current schema and merge old FK with new properties.
  SchemaBuilder modifyForeignKey({
    required String foreignKeyName,
    ForeignKeyCascadeAction? onDelete,
    ForeignKeyCascadeAction? onUpdate,
    bool? enabled,
    bool? autoCreateIndex,
    String? comment,
  }) {
    // Store modification parameters - will be applied during migration execution
    // The migration manager will load the current schema and merge properties
    _operations.add(MigrationOperation(
      type: MigrationType.modifyForeignKey,
      foreignKeyName: foreignKeyName,
      // Note: The new foreign key will be constructed during execution
      // by loading current schema and merging old FK with new properties
      // We store a partial FK with only the properties to modify
      foreignKey: ForeignKeySchema(
        name: foreignKeyName, // Use name to identify the FK
        fields: [], // Will be filled from old FK during execution
        referencedTable: '', // Will be filled from old FK during execution
        referencedFields: [], // Will be filled from old FK during execution
        onDelete: onDelete ??
            ForeignKeyCascadeAction.restrict, // Use provided or default
        onUpdate: onUpdate ??
            ForeignKeyCascadeAction.restrict, // Use provided or default
        enabled: enabled ?? true, // Use provided or default
        autoCreateIndex: autoCreateIndex ?? true, // Use provided or default
        comment: comment, // Use provided or null
      ),
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
