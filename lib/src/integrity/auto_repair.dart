import 'dart:convert';
import 'dart:io';

import '../handler/logger.dart';
import '../backup/backup_manager.dart';
import '../core/data_store_impl.dart';
import '../core/index_manager.dart';
import '../model/row_pointer.dart';
import '../model/table_schema.dart';

/// auto repair
class AutoRepair {
  final DataStoreImpl _dataStore;
  final IndexManager _indexManager;
  final BackupManager _backupManager;

  AutoRepair(
    this._dataStore,
    this._indexManager,
    this._backupManager,
  );

  /// repair damaged record
  Future<void> repairRecord(String tableName, String recordId) async {
    // restore record from latest backup
    final backups = await _getBackups(tableName);
    if (backups.isEmpty) {
      throw StateError('No backup available for repair');
    }

    // try to restore from latest backup
    for (var backup in backups) {
      try {
        await _restoreRecordFromBackup(tableName, recordId, backup);
        return;
      } catch (e) {
        // try next backup
        continue;
      }
    }

    throw StateError('Unable to repair record from any backup');
  }

  /// rebuild index
  Future<void> rebuildIndex(String tableName, String indexName) async {
    final tablePath = await _dataStore.getTablePath(tableName);
    final schema = await _dataStore.getTableSchema(tableName);

    // create new index
    await _indexManager.createIndex(
      tableName,
      schema.indexes.firstWhere((idx) => idx.indexName == indexName),
    );

    // read all data and rebuild index
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

  /// repair table structure
  Future<void> repairTableStructure(String tableName) async {
    try {
      final schema = await _dataStore.getTableSchema(tableName);

      // create temp table
      final tempTableName = '${tableName}_repair';

      // create new table
      await _createNewTable(tempTableName, schema);

      // migrate valid data
      await _migrateValidData(tableName, tempTableName, schema);

      // replace original table
      await _replaceTable(tableName, tempTableName);
    } catch (e) {
      Logger.error('repair table structure failed: $e');
      rethrow;
    }
  }

  /// get available backups
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

    // sort by time, latest first
    backups.sort((a, b) => b.compareTo(a));
    return backups;
  }

  /// restore record from backup
  Future<void> _restoreRecordFromBackup(
    String tableName,
    String recordId,
    String backupPath,
  ) async {
    try {
      final backupData = await _backupManager.loadBackup(backupPath);

      // get table data from backup
      final data = backupData['data'] as Map<String, dynamic>;
      final tableData = data[tableName] as Map<String, dynamic>?;
      if (tableData == null) {
        throw StateError('table not found: $tableName');
      }

      // get table schema
      final schema =
          TableSchema.fromJson(tableData['schema'] as Map<String, dynamic>);
      final primaryKey = schema.primaryKey;

      // get record data and safe convert type
      final recordsList = tableData['data'];
      if (recordsList is! List) {
        throw StateError('backup record data format invalid');
      }

      // find record
      Map<String, dynamic>? targetRecord;
      for (var item in recordsList) {
        if (item is Map<String, dynamic> &&
            item[primaryKey].toString() == recordId) {
          targetRecord = item;
          break;
        }
      }

      if (targetRecord == null) {
        throw StateError('record not found: $recordId');
      }

      // restore record
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
      Logger.error('restore record from backup failed: $e');
      rethrow;
    }
  }

  /// create new table
  Future<void> _createNewTable(String tableName, TableSchema schema) async {
    final tablePath = await _dataStore.getTablePath(tableName);
    final dataFile = File('$tablePath.dat');
    final schemaFile = File('$tablePath.schema');

    await dataFile.create();
    await schemaFile.writeAsString(jsonEncode(schema.toJson()));

    // create index
    await _indexManager.createPrimaryIndex(tableName, schema.primaryKey);
    for (var index in schema.indexes) {
      await _indexManager.createIndex(tableName, index);
    }
  }

  /// migrate valid data
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
            // update index
            final encoded = jsonEncode(data);
            startOffset += encoded.length + 1;
            final pointer = await RowPointer.create(
              encoded,
              startOffset,
            );
            await _indexManager.updateIndexes(targetName, data, pointer);
          }
        } catch (e) {
          // skip damaged record
          continue;
        }
      }
    } finally {
      await sink.close();
    }
  }

  /// replace table
  Future<void> _replaceTable(String oldName, String newName) async {
    final oldPath = await _dataStore.getTablePath(oldName);
    final newPath = await _dataStore.getTablePath(newName);

    final oldDataFile = File('$oldPath.dat');
    final oldSchemaFile = File('$oldPath.schema');
    final oldIndexFiles = await _getIndexFiles(oldName);

    final newDataFile = File('$newPath.dat');
    final newSchemaFile = File('$newPath.schema');

    // backup original table
    final backupSuffix = DateTime.now().millisecondsSinceEpoch.toString();
    await oldDataFile.rename('${oldDataFile.path}.$backupSuffix');
    await oldSchemaFile.rename('${oldSchemaFile.path}.$backupSuffix');
    for (var indexFile in oldIndexFiles) {
      await indexFile.rename('${indexFile.path}.$backupSuffix');
    }

    // replace with new table
    await newDataFile.rename(oldDataFile.path);
    await newSchemaFile.rename(oldSchemaFile.path);
  }

  /// get index files
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

  /// check record is valid
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

  /// check data type is valid
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
