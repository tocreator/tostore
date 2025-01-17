import '../core/data_store_impl.dart';
import '../core/transaction_manager.dart';
import '../model/table_schema.dart';
import 'future_builder_mixin.dart';

/// Schema builder for chain operations
class SchemaBuilder with FutureBuilderMixin {
  static const _unsetValue = Object();

  final DataStoreImpl _dataStore;
  final String _tableName;
  final List<_SchemaOperation> _operations = [];

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
    _operations.add(_SchemaOperation(
      type: _SchemaOperationType.addField,
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

  /// Drop field from table
  SchemaBuilder removeField(String fieldName) {
    _operations.add(_SchemaOperation(
      type: _SchemaOperationType.removeField,
      fieldName: fieldName,
    ));
    return this;
  }

  /// Rename field
  SchemaBuilder renameField(String oldName, String newName) {
    _operations.add(_SchemaOperation(
      type: _SchemaOperationType.renameField,
      fieldName: oldName,
      newName: newName,
    ));
    return this;
  }

  /// Modify field
  SchemaBuilder modifyField(
    String name, {
    DataType? type,
    bool? nullable,
    dynamic defaultValue = _unsetValue,
    bool? unique,
    String? comment,
  }) {
    _operations.add(_SchemaOperation(
      type: _SchemaOperationType.modifyField,
      fieldName: name,
      field: FieldSchema(
        name: name,
        type: type ?? DataType.text,
        nullable: nullable ?? true,
        defaultValue: defaultValue == _unsetValue ? null : defaultValue,
        unique: unique ?? false,
        comment: comment,
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
    _operations.add(_SchemaOperation(
      type: _SchemaOperationType.addIndex,
      index: IndexSchema(
        indexName: name,
        fields: fields,
        unique: unique ?? false,
        type: type,
      ),
    ));
    return this;
  }

  /// Drop index
  SchemaBuilder removeIndex(String indexName) {
    _operations.add(_SchemaOperation(
      type: _SchemaOperationType.removeIndex,
      indexName: indexName,
    ));
    return this;
  }

  /// Rename table
  SchemaBuilder renameTable(String newTableName) {
    _operations.add(_SchemaOperation(
      type: _SchemaOperationType.renameTable,
      newTableName: newTableName,
    ));
    return this;
  }

  @override
  Future<void> get future async {
    // Execute all operations in a transaction
    await _dataStore.transaction((txn) async {
      for (var operation in _operations) {
        await _executeOperation(operation, txn);
      }
    });
  }

  Future<void> _executeOperation(
      _SchemaOperation operation, Transaction txn) async {
    switch (operation.type) {
      case _SchemaOperationType.addField:
        await _dataStore.addField(_tableName, operation.field!, txn);
        await _dataStore.addFieldToRecords(
          _tableName,
          operation.field!,
          batchSize: _dataStore.config.migrationConfig?.batchSize ?? 1000,
        );
        break;

      case _SchemaOperationType.removeField:
        await _dataStore.removeField(_tableName, operation.fieldName!, txn);
        await _dataStore.removeFieldFromRecords(
          _tableName,
          operation.fieldName!,
          batchSize: _dataStore.config.migrationConfig?.batchSize ?? 1000,
        );
        break;

      case _SchemaOperationType.modifyField:
        final oldSchema = await _dataStore.getTableSchema(_tableName);
        final oldField =
            oldSchema.fields.firstWhere((f) => f.name == operation.fieldName);
        await _dataStore.modifyField(
            _tableName, operation.fieldName!, operation.field!, txn);
        await _dataStore.migrateFieldData(
          _tableName,
          oldField,
          operation.field!,
          txn,
          batchSize: _dataStore.config.migrationConfig?.batchSize ?? 1000,
        );
        break;

      case _SchemaOperationType.renameField:
        await _dataStore.renameField(
            _tableName, operation.fieldName!, operation.newName!, txn);
        await _dataStore.renameFieldInRecords(
          _tableName,
          operation.fieldName!,
          operation.newName!,
          batchSize: _dataStore.config.migrationConfig?.batchSize ?? 1000,
        );
        break;
      case _SchemaOperationType.addIndex:
        await _dataStore.addIndex(_tableName, operation.index!, txn);
        break;
      case _SchemaOperationType.removeIndex:
        await _dataStore.removeIndex(_tableName, operation.indexName!, txn);
        break;
      case _SchemaOperationType.renameTable:
        await _dataStore.renameTable(_tableName, operation.newTableName!, txn);
        break;
    }
  }
}

/// Operation type for schema update
enum _SchemaOperationType {
  addField,
  removeField,
  renameField,
  modifyField,
  addIndex,
  removeIndex,
  renameTable,
}

/// Operation class for schema update
class _SchemaOperation {
  final _SchemaOperationType type;
  final FieldSchema? field;
  final String? fieldName;
  final String? newName;
  final IndexSchema? index;
  final String? indexName;
  final String? newTableName;

  _SchemaOperation({
    required this.type,
    this.field,
    this.fieldName,
    this.newName,
    this.index,
    this.indexName,
    this.newTableName,
  });
}
