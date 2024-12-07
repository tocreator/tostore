import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/data_compressor.dart';
import '../core/data_store_impl.dart';
import '../model/table_schema.dart';

/// 数据完整性检查器
class IntegrityChecker {
  final DataStoreImpl _dataStore;
  final Map<String, TableSchema> _schemas = {};
  final DataCompressor _compressor;

  IntegrityChecker(this._dataStore) : _compressor = DataCompressor();

  /// 检查表结构完整性
  Future<bool> checkTableStructure(String tableName) async {
    try {
      final schema = await _loadTableSchema(tableName);
      final tablePath = await _dataStore.getTablePath(tableName);
      final dataFile = File('$tablePath.dat');

      if (!await dataFile.exists()) {
        return false;
      }

      // 检查每条记录是否符合表结构
      final lines = await dataFile.readAsLines();
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

  /// 检查索引完整性
  Future<bool> checkIndexIntegrity(String tableName) async {
    try {
      final schema = await _loadTableSchema(tableName);
      final tablePath = await _dataStore.getTablePath(tableName);
      final dataFile = File('$tablePath.dat');

      // 检查每个索引文件
      for (var index in schema.indexes) {
        final indexFile = File('$tablePath.${index.actualIndexName}.idx');
        if (!await indexFile.exists()) {
          return false;
        }

        // 验证索引内容
        if (!await _validateIndex(tableName, index, dataFile)) {
          return false;
        }
      }

      return true;
    } catch (e) {
      return false;
    }
  }

  /// 检查数据一致性
  Future<bool> checkDataConsistency(String tableName) async {
    try {
      final tablePath = await _dataStore.getTablePath(tableName);
      final dataFile = File('$tablePath.dat');
      final checksumFile = File('$tablePath.checksum');

      if (!await dataFile.exists() || !await checksumFile.exists()) {
        return false;
      }

      // 读取校验和文件
      final lines = await dataFile.readAsLines();
      final checksums = await checksumFile.readAsLines();

      if (lines.length != checksums.length) {
        return false;
      }

      // 验证每条记录的校验和
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

  /// 检查外键约束
  Future<bool> checkForeignKeyConstraints(String tableName) async {
    try {
      final schema = await _loadTableSchema(tableName);
      final tablePath = await _dataStore.getTablePath(tableName);
      final dataFile = File('$tablePath.dat');
      final lines = await dataFile.readAsLines();

      for (var line in lines) {
        final data = jsonDecode(line) as Map<String, dynamic>;
        // 检查每个外键引用
        for (var field in schema.fields) {
          // 检查字段是否有外键引用
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

  /// 验证外键引用
  Future<bool> _validateForeignKeyReference(
    dynamic value,
    String fieldName,
    String tableName,
  ) async {
    if (value == null) return true;

    // 推断引用的表名（例如：user_id -> users）
    final referencedTable = _inferReferencedTable(fieldName);
    final tablePath = await _dataStore.getTablePath(referencedTable);
    final referencedFile = File('$tablePath.dat');

    if (!await referencedFile.exists()) {
      return false;
    }

    // 在引用的表中查找记录
    final lines = await referencedFile.readAsLines();
    for (var line in lines) {
      final record = jsonDecode(line) as Map<String, dynamic>;
      if (record['id'] == value) {
        return true;
      }
    }

    return false;
  }

  /// 推断引用的表名
  String _inferReferencedTable(String fieldName) {
    // 移除 _id 后缀
    final baseName = fieldName.substring(0, fieldName.length - 3);
    // 转换为复数形式（简单实现）
    return '${baseName}s';
  }

  /// 检查唯一约束
  Future<bool> checkUniqueConstraints(String tableName) async {
    try {
      final schema = await _loadTableSchema(tableName);
      final tablePath = await _dataStore.getTablePath(tableName);
      final dataFile = File('$tablePath.dat');
      final lines = await dataFile.readAsLines();

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

  /// 加载表结构
  Future<TableSchema> _loadTableSchema(String tableName) async {
    if (_schemas.containsKey(tableName)) {
      return _schemas[tableName]!;
    }

    final schema = await _dataStore.getTableSchema(tableName);
    _schemas[tableName] = schema;
    return schema;
  }

  /// 验证记录
  bool _validateRecord(Map<String, dynamic> data, TableSchema schema) {
    // 检查必填字段
    for (var field in schema.fields) {
      if (!field.nullable && !data.containsKey(field.name)) {
        return false;
      }
    }

    // 检查数据类型
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

  /// 验证索引
  Future<bool> _validateIndex(
    String tableName,
    IndexSchema index,
    File dataFile,
  ) async {
    final tablePath = await _dataStore.getTablePath(tableName);
    final indexFile = File('$tablePath.${index.actualIndexName}.idx');
    final indexContent = await indexFile.readAsString();
    final lines = await dataFile.readAsLines();

    // 检查索引记录数是否匹配
    final indexEntries =
        indexContent.split('\n').where((line) => line.isNotEmpty);
    final uniqueKeys = <String>{};

    for (var line in lines) {
      final data = jsonDecode(line) as Map<String, dynamic>;
      final key = _extractIndexKey(data, index.fields);
      uniqueKeys.add(key);
    }

    // 对于唯一索引，检查是否有重复
    if (index.unique && uniqueKeys.length != lines.length) {
      return false;
    }

    return indexEntries.length == uniqueKeys.length;
  }

  /// 提取索引键
  String _extractIndexKey(Map<String, dynamic> data, List<String> fields) {
    return fields.map((col) => data[col].toString()).join(':');
  }

  /// 检查数据类型
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
      default:
        return false;
    }
  }
}
