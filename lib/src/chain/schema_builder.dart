import 'package:tostore/src/handler/logger.dart';

import '../core/data_store_impl.dart';
import '../core/transaction_manager.dart';
import '../model/table_schema.dart';
import 'future_builder_mixin.dart';

/// Schema builder for chain operations
class SchemaBuilder with FutureBuilderMixin {
  static const _unsetValue = Object();

  final DataStoreImpl _dataStore;
  final String _tableName;
  final List<_UpdateSchemaOperation> _operations = [];

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
    _operations.add(_UpdateSchemaOperation(
      type: _UpdateSchemaType.addField,
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
  SchemaBuilder dropField(String fieldName) {
    _operations.add(_UpdateSchemaOperation(
      type: _UpdateSchemaType.dropField,
      fieldName: fieldName,
    ));
    return this;
  }

  /// Rename field
  SchemaBuilder renameField(String oldName, String newName) {
    _operations.add(_UpdateSchemaOperation(
      type: _UpdateSchemaType.renameField,
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
    _operations.add(_UpdateSchemaOperation(
      type: _UpdateSchemaType.modifyField,
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
    _operations.add(_UpdateSchemaOperation(
      type: _UpdateSchemaType.addIndex,
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
  SchemaBuilder dropIndex(String indexName) {
    _operations.add(_UpdateSchemaOperation(
      type: _UpdateSchemaType.dropIndex,
      indexName: indexName,
    ));
    return this;
  }

  /// Rename table
  SchemaBuilder renameTo(String newTableName) {
    _operations.add(_UpdateSchemaOperation(
      type: _UpdateSchemaType.renameTable,
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
      _UpdateSchemaOperation operation, Transaction txn) async {
    switch (operation.type) {
      case _UpdateSchemaType.addField:
        await _dataStore.addField(_tableName, operation.field!, txn);
        break;
      case _UpdateSchemaType.dropField:
        await _dataStore.dropField(_tableName, operation.fieldName!, txn);
        break;
      case _UpdateSchemaType.renameField:
        await _dataStore.renameField(
            _tableName, operation.fieldName!, operation.newName!, txn);
        break;
      case _UpdateSchemaType.modifyField:
        Logger.error(
            "operation${operation.fieldName},${operation.field?.toJson()}");
        await _dataStore.modifyField(
            _tableName, operation.fieldName!, operation.field!, txn);
        break;
      case _UpdateSchemaType.addIndex:
        await _dataStore.addIndex(_tableName, operation.index!, txn);
        break;
      case _UpdateSchemaType.dropIndex:
        await _dataStore.dropIndex(_tableName, operation.indexName!, txn);
        break;
      case _UpdateSchemaType.renameTable:
        await _dataStore.renameTable(_tableName, operation.newTableName!, txn);
        break;
    }
  }
}

/// Operation type for schema update
enum _UpdateSchemaType {
  addField,
  dropField,
  renameField,
  modifyField,
  addIndex,
  dropIndex,
  renameTable,
}

/// Operation class for schema update
class _UpdateSchemaOperation {
  final _UpdateSchemaType type;
  final FieldSchema? field;
  final String? fieldName;
  final String? newName;
  final IndexSchema? index;
  final String? indexName;
  final String? newTableName;

  _UpdateSchemaOperation({
    required this.type,
    this.field,
    this.fieldName,
    this.newName,
    this.index,
    this.indexName,
    this.newTableName,
  });
}
