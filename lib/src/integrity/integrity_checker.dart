import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

import '../core/data_compressor.dart';
import '../core/data_store_impl.dart';
import '../model/business_error.dart';
import '../model/table_schema.dart';
import '../model/data_store_config.dart';

/// data integrity checker
class IntegrityChecker {
  final DataStoreImpl _dataStore;
  final Map<String, TableSchema> _schemas = {};
  final DataCompressor _compressor;

  IntegrityChecker(this._dataStore) : _compressor = DataCompressor();

  /// check table structure integrity
  Future<bool> checkTableStructure(String tableName) async {
    try {
      final schema = await _loadTableSchema(tableName);
      final dataPath =
          _dataStore.config.getDataPath(tableName, schema.isGlobal);

      if (!await _dataStore.storage.exists(dataPath)) {
        return false;
      }

      // check each record is valid
      final lines = await _dataStore.storage.readLines(dataPath);
      for (var line in lines) {
        try {
          final data = jsonDecode(line) as Map<String, dynamic>;
          if (!_validateRecord(data, schema)) {
            return false;
          }
        } catch (e) {
          return false;
        }
      }

      return true;
    } catch (e) {
      return false;
    }
  }

  /// check index integrity
  Future<bool> checkIndexIntegrity(String tableName) async {
    try {
      final schema = await _loadTableSchema(tableName);
      final dataPath =
          _dataStore.config.getDataPath(tableName, schema.isGlobal);

      // check each index file
      for (var index in schema.indexes) {
        final indexPath = _dataStore.config.getIndexPath(
          tableName,
          index.actualIndexName,
          schema.isGlobal,
        );
        if (!await _dataStore.storage.exists(indexPath)) {
          return false;
        }

        // validate index content
        if (!await _validateIndex(tableName, index, dataPath)) {
          return false;
        }
      }

      return true;
    } catch (e) {
      return false;
    }
  }

  /// check data consistency
  Future<bool> checkDataConsistency(String tableName) async {
    try {
      final schema = await _loadTableSchema(tableName);
      final dataPath =
          _dataStore.config.getDataPath(tableName, schema.isGlobal);
      final checksumPath =
          _dataStore.config.getChecksumPath(tableName, schema.isGlobal);

      if (!await _dataStore.storage.exists(dataPath) ||
          !await _dataStore.storage.exists(checksumPath)) {
        return false;
      }

      // read checksum file
      final lines = await _dataStore.storage.readLines(dataPath);
      final checksums = await _dataStore.storage.readLines(checksumPath);

      if (lines.length != checksums.length) {
        return false;
      }

      // validate each record checksum
      for (var i = 0; i < lines.length; i++) {
        final data = Uint8List.fromList(utf8.encode(lines[i]));
        final actualChecksum = _compressor.calculateChecksum(data);
        final expectedChecksum = int.parse(checksums[i]);

        if (actualChecksum != expectedChecksum) {
          return false;
        }
      }

      return true;
    } catch (e) {
      return false;
    }
  }

  /// check foreign key constraints
  Future<bool> checkForeignKeyConstraints(String tableName) async {
    try {
      final schema = await _loadTableSchema(tableName);
      final dataPath =
          _dataStore.config.getDataPath(tableName, schema.isGlobal);
      final lines = await _dataStore.storage.readLines(dataPath);

      for (var line in lines) {
        final data = jsonDecode(line) as Map<String, dynamic>;
        // check each foreign key reference
        for (var field in schema.fields) {
          // check field is foreign key reference
          if (field.type == DataType.integer && field.name.endsWith('_id')) {
            if (!await _validateForeignKeyReference(
              data[field.name],
              field.name,
              tableName,
            )) {
              return false;
            }
          }
        }
      }

      return true;
    } catch (e) {
      return false;
    }
  }

  /// validate foreign key reference
  Future<bool> _validateForeignKeyReference(
    dynamic value,
    String fieldName,
    String tableName,
  ) async {
    if (value == null) return true;

    final referencedTable = _inferReferencedTable(fieldName);
    try {
      final referencedSchema = await _loadTableSchema(referencedTable);
      final dataPath = _dataStore.config.getDataPath(
        referencedTable,
        referencedSchema.isGlobal,
      );

      if (!await _dataStore.storage.exists(dataPath)) {
        return false;
      }

      // find record in referenced table
      final lines = await _dataStore.storage.readLines(dataPath);
      for (var line in lines) {
        final record = jsonDecode(line) as Map<String, dynamic>;
        if (record[referencedSchema.primaryKey] == value) {
          return true;
        }
      }

      return false;
    } catch (e) {
      return false;
    }
  }

  /// infer referenced table name
  String _inferReferencedTable(String fieldName) {
    // remove _id suffix
    final baseName = fieldName.substring(0, fieldName.length - 3);
    // convert to plural form (simple implementation)
    return '${baseName}s';
  }

  /// check unique constraints
  Future<bool> checkUniqueConstraints(String tableName) async {
    try {
      final schema = await _loadTableSchema(tableName);
      final dataPath =
          _dataStore.config.getDataPath(tableName, schema.isGlobal);
      final lines = await _dataStore.storage.readLines(dataPath);

      final uniqueValues = <String, Set<String>>{};
      for (var index in schema.indexes.where((idx) => idx.unique)) {
        uniqueValues[index.actualIndexName] = {};
      }

      for (var line in lines) {
        final data = jsonDecode(line) as Map<String, dynamic>;
        for (var index in schema.indexes.where((idx) => idx.unique)) {
          final key = _extractIndexKey(data, index.fields);
          if (!uniqueValues[index.actualIndexName]!.add(key)) {
            return false;
          }
        }
      }

      return true;
    } catch (e) {
      return false;
    }
  }

  /// load table schema
  Future<TableSchema> _loadTableSchema(String tableName) async {
    // Try to get from cache first
    if (_schemas.containsKey(tableName)) {
      return _schemas[tableName]!;
    }

    // Load schema from file
    final schemaPath = _dataStore.config.getSchemaPath(tableName, true);
    if (!await _dataStore.storage.exists(schemaPath)) {
      final baseSchemaPath = _dataStore.config.getSchemaPath(tableName, false);
      if (!await _dataStore.storage.exists(baseSchemaPath)) {
        throw BusinessError(
          'Table schema not found: $tableName',
          type: BusinessErrorType.schemaError,
        );
      }
      final content = await _dataStore.storage.readAsString(baseSchemaPath);
      final json = jsonDecode(content!) as Map<String, dynamic>;

      if (!json.containsKey('name')) {
        json['name'] = tableName;
      }
      final schema = TableSchema.fromJson(json);
      _schemas[tableName] = schema;
      return schema;
    }

    final content = await _dataStore.storage.readAsString(schemaPath);
    final json = jsonDecode(content!) as Map<String, dynamic>;

    if (!json.containsKey('name')) {
      json['name'] = tableName;
    }
    final schema = TableSchema.fromJson(json);
    _schemas[tableName] = schema;
    return schema;
  }

  /// validate record
  bool _validateRecord(Map<String, dynamic> data, TableSchema schema) {
    // check required fields
    for (var field in schema.fields) {
      if (!field.nullable && !data.containsKey(field.name)) {
        return false;
      }
    }

    // check data type
    for (var entry in data.entries) {
      final field = schema.fields.firstWhere(
        (col) => col.name == entry.key,
        orElse: () => throw StateError('Unknown field ${entry.key}'),
      );

      if (!_isValidDataType(entry.value, field.type)) {
        return false;
      }
    }

    return true;
  }

  /// validate index
  Future<bool> _validateIndex(
    String tableName,
    IndexSchema index,
    String dataPath,
  ) async {
    try {
      final schema = await _loadTableSchema(tableName);
      final indexPath = _dataStore.config.getIndexPath(
        tableName,
        index.actualIndexName,
        schema.isGlobal,
      );

      if (!await _dataStore.storage.exists(indexPath)) {
        return false;
      }

      final indexContent = await _dataStore.storage.readAsString(indexPath);
      final lines = await _dataStore.storage.readLines(dataPath);

      // check index record count is match
      final indexEntries =
          indexContent!.split('\n').where((line) => line.isNotEmpty);
      final uniqueKeys = <String>{};

      for (var line in lines) {
        final data = jsonDecode(line) as Map<String, dynamic>;
        final key = _extractIndexKey(data, index.fields);
        uniqueKeys.add(key);
      }

      // for unique index, check if there are duplicates
      if (index.unique && uniqueKeys.length != lines.length) {
        return false;
      }

      return indexEntries.length == uniqueKeys.length;
    } catch (e) {
      return false;
    }
  }

  /// extract index key
  String _extractIndexKey(Map<String, dynamic> data, List<String> fields) {
    return fields.map((col) => data[col].toString()).join(':');
  }

  /// check data type
  bool _isValidDataType(dynamic value, DataType type) {
    if (value == null) return true;
    switch (type) {
      case DataType.integer:
        return value is int;
      case DataType.double:
        return value is double;
      case DataType.text:
        return value is String;
      case DataType.blob:
        return value is List<int>;
      case DataType.boolean:
        return value is bool;
      case DataType.datetime:
        return value is String && DateTime.tryParse(value) != null;
      case DataType.array:
        return value is List;
    }
  }

  Future<bool> validateMigration(
    String tableName,
    TableSchema oldSchema,
    TableSchema newSchema,
  ) async {
    // 1. Validate table structure
    if (!await validateTableStructure(
      tableName,
      newSchema,
      _dataStore.config,
    )) {
      return false;
    }

    // 2. Validate data integrity
    if (!await validateTableData(
      tableName,
      newSchema,
      _dataStore.config,
    )) {
      return false;
    }

    return true;
  }

  /// Validate table structure matches schema
  Future<bool> validateTableStructure(
    String tableName,
    TableSchema schema,
    DataStoreConfig config,
  ) async {
    try {
      // Check table structure integrity
      if (!await checkTableStructure(tableName)) {
        return false;
      }

      // Check index integrity
      if (!await checkIndexIntegrity(tableName)) {
        return false;
      }

      return true;
    } catch (e) {
      return false;
    }
  }

  /// Validate table data integrity
  Future<bool> validateTableData(
    String tableName,
    TableSchema schema,
    DataStoreConfig config,
  ) async {
    try {
      // Check data consistency
      if (!await checkDataConsistency(tableName)) {
        return false;
      }

      // Check unique constraints
      if (!await checkUniqueConstraints(tableName)) {
        return false;
      }

      // Check foreign key constraints if any
      if (!await checkForeignKeyConstraints(tableName)) {
        return false;
      }

      return true;
    } catch (e) {
      return false;
    }
  }
}
