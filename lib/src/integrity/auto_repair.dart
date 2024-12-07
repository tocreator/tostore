import 'dart:convert';
import 'dart:io';

import '../handler/logger.dart';
import '../backup/backup_manager.dart';
import '../core/data_store_impl.dart';
import '../core/index_manager.dart';
import '../model/row_pointer.dart';
import '../model/table_schema.dart';

/// 自动修复器
class AutoRepair {
  final DataStoreImpl _dataStore;
  final IndexManager _indexManager;
  final BackupManager _backupManager;

  AutoRepair(
    this._dataStore,
    this._indexManager,
    this._backupManager,
  );

  /// 修复损坏的记录
  Future<void> repairRecord(String tableName, String recordId) async {
    // 从最近的备份中恢复记录
    final backups = await _getBackups(tableName);
    if (backups.isEmpty) {
      throw StateError('No backup available for repair');
    }

    // 尝试从最近的备份中恢复
    for (var backup in backups) {
      try {
        await _restoreRecordFromBackup(tableName, recordId, backup);
        return;
      } catch (e) {
        // 继续尝试下一个备份
        continue;
      }
    }

    throw StateError('Unable to repair record from any backup');
  }

  /// 重建索引
  Future<void> rebuildIndex(String tableName, String indexName) async {
    final tablePath = await _dataStore.getTablePath(tableName);
    final schema = await _dataStore.getTableSchema(tableName);

    // 创建新的索引
    await _indexManager.createIndex(
      tableName,
      schema.indexes.firstWhere((idx) => idx.indexName == indexName),
    );

    // 读取所有数据并重建索引
    final dataFile = File('$tablePath.dat');
    final lines = await dataFile.readAsLines();

    var startOffset = await dataFile.length();

    for (var line in lines) {
      final data = jsonDecode(line) as Map<String, dynamic>;
      final encoded = jsonEncode(line);
      startOffset += encoded.length + 1;
      final pointer = await RowPointer.create(
        encoded,
        startOffset,
      );
      await _indexManager.updateIndexes(tableName, data, pointer);
    }
  }

  /// 修复表结构
  Future<void> repairTableStructure(String tableName) async {
    try {
      final schema = await _dataStore.getTableSchema(tableName);

      // 创建临时表
      final tempTableName = '${tableName}_repair';

      // 创建新表
      await _createNewTable(tempTableName, schema);

      // 迁移有效数据
      await _migrateValidData(tableName, tempTableName, schema);

      // 替换原表
      await _replaceTable(tableName, tempTableName);
    } catch (e) {
      Logger.error('修复表结构失败: $e');
      rethrow;
    }
  }

  /// 获取可用的备份
  Future<List<String>> _getBackups(String tableName) async {
    final backupPath = _dataStore.config.getBackupPath();
    final backupDir = Directory(backupPath);
    if (!await backupDir.exists()) return [];

    final backups = <String>[];
    await for (var entity in backupDir.list()) {
      if (entity is File && entity.path.contains(tableName)) {
        backups.add(entity.path);
      }
    }

    // 按时间排序，最新的在前
    backups.sort((a, b) => b.compareTo(a));
    return backups;
  }

  /// 从备份中恢复记录
  Future<void> _restoreRecordFromBackup(
    String tableName,
    String recordId,
    String backupPath,
  ) async {
    try {
      final backupData = await _backupManager.loadBackup(backupPath);

      // 从备份数据中获取表数据
      final data = backupData['data'] as Map<String, dynamic>;
      final tableData = data[tableName] as Map<String, dynamic>?;
      if (tableData == null) {
        throw StateError('备份中未找到表: $tableName');
      }

      // 获取表结构
      final schema =
          TableSchema.fromJson(tableData['schema'] as Map<String, dynamic>);
      final primaryKey = schema.primaryKey;

      // 获取记录数据并安全转换类型
      final recordsList = tableData['data'];
      if (recordsList is! List) {
        throw StateError('备份中的记录数据格式无效');
      }

      // 查找记录
      Map<String, dynamic>? targetRecord;
      for (var item in recordsList) {
        if (item is Map<String, dynamic> &&
            item[primaryKey].toString() == recordId) {
          targetRecord = item;
          break;
        }
      }

      if (targetRecord == null) {
        throw StateError('备份中未找到记录 ID: $recordId');
      }

      // 恢复记录
      final tablePath = await _dataStore.getTablePath(tableName);
      final dataFile = File('$tablePath.dat');
      final sink = dataFile.openWrite(mode: FileMode.append);
      try {
        sink.writeln(jsonEncode(targetRecord));
        await sink.flush();
      } finally {
        await sink.close();
      }
    } catch (e) {
      Logger.error('从备份恢复记录失败: $e');
      rethrow;
    }
  }

  /// 创建新表
  Future<void> _createNewTable(String tableName, TableSchema schema) async {
    final tablePath = await _dataStore.getTablePath(tableName);
    final dataFile = File('$tablePath.dat');
    final schemaFile = File('$tablePath.schema');

    await dataFile.create();
    await schemaFile.writeAsString(jsonEncode(schema.toJson()));

    // 创建索引
    await _indexManager.createPrimaryIndex(tableName, schema.primaryKey);
    for (var index in schema.indexes) {
      await _indexManager.createIndex(tableName, index);
    }
  }

  /// 迁移有效数据
  Future<void> _migrateValidData(
    String sourceName,
    String targetName,
    TableSchema schema,
  ) async {
    final sourcePath = await _dataStore.getTablePath(sourceName);
    final targetPath = await _dataStore.getTablePath(targetName);
    final sourceFile = File('$sourcePath.dat');
    final targetFile = File('$targetPath.dat');

    final lines = await sourceFile.readAsLines();
    final sink = targetFile.openWrite();

    var startOffset = await sourceFile.length();

    try {
      for (var line in lines) {
        try {
          final data = jsonDecode(line) as Map<String, dynamic>;
          if (_isValidRecord(data, schema)) {
            sink.writeln(line);
            // 更新索引
            final encoded = jsonEncode(data);
            startOffset += encoded.length + 1;
            final pointer = await RowPointer.create(
              encoded,
              startOffset,
            );
            await _indexManager.updateIndexes(targetName, data, pointer);
          }
        } catch (e) {
          // 跳过损坏的记录
          continue;
        }
      }
    } finally {
      await sink.close();
    }
  }

  /// 替换表
  Future<void> _replaceTable(String oldName, String newName) async {
    final oldPath = await _dataStore.getTablePath(oldName);
    final newPath = await _dataStore.getTablePath(newName);

    final oldDataFile = File('$oldPath.dat');
    final oldSchemaFile = File('$oldPath.schema');
    final oldIndexFiles = await _getIndexFiles(oldName);

    final newDataFile = File('$newPath.dat');
    final newSchemaFile = File('$newPath.schema');

    // 备份原表
    final backupSuffix = DateTime.now().millisecondsSinceEpoch.toString();
    await oldDataFile.rename('${oldDataFile.path}.$backupSuffix');
    await oldSchemaFile.rename('${oldSchemaFile.path}.$backupSuffix');
    for (var indexFile in oldIndexFiles) {
      await indexFile.rename('${indexFile.path}.$backupSuffix');
    }

    // 替换为新表
    await newDataFile.rename(oldDataFile.path);
    await newSchemaFile.rename(oldSchemaFile.path);
  }

  /// 获取索引文件
  Future<List<File>> _getIndexFiles(String tableName) async {
    final tablePath = await _dataStore.getTablePath(tableName);
    final dir = Directory(tablePath);
    final files = <File>[];

    await for (var entity in dir.list()) {
      if (entity is File &&
          entity.path.startsWith('$tablePath/${tableName}_') &&
          entity.path.endsWith('.idx')) {
        files.add(entity);
      }
    }

    return files;
  }

  /// 检查记录是否有效
  bool _isValidRecord(Map<String, dynamic> data, TableSchema schema) {
    try {
      for (var field in schema.fields) {
        final value = data[field.name];
        if (!field.nullable && value == null) {
          return false;
        }
        if (value != null && !_isValidDataType(value, field.type)) {
          return false;
        }
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  /// 检查数据类型是否有效
  bool _isValidDataType(dynamic value, DataType type) {
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
    }
  }
}
