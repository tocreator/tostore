import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

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
    final schema = await _dataStore.getTableSchema(tableName);

    // create new index
    await _indexManager.createIndex(
      tableName,
      schema.indexes.firstWhere((idx) => idx.indexName == indexName),
    );

    // read all data and rebuild index
    final dataPath = _dataStore.config.getDataPath(tableName, schema.isGlobal);
    final lines = await _dataStore.storage.readLines(dataPath);

    var startOffset = 0;

    for (var line in lines) {
      final data = jsonDecode(line) as Map<String, dynamic>;
      final encoded = jsonEncode(line);
      final pointer = await RowPointer.create(
        encoded,
        startOffset,
      );
      await _indexManager.updateIndexes(tableName, data, pointer);
      startOffset += encoded.length + 1;
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
    if (!await _dataStore.storage.exists(backupPath)) return [];

    final backups = <String>[];
    for (var path in await _dataStore.storage.listDirectory(backupPath)) {
      if (path.contains(tableName)) {
        backups.add(path);
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
      final dataPath =
          _dataStore.config.getDataPath(tableName, schema.isGlobal);

      if (kIsWeb) {
        final content = await _dataStore.storage.readAsString(dataPath) ?? '';
        final contentWithNewRecord = '$content\n${jsonEncode(targetRecord)}';
        await _dataStore.storage.writeAsString(dataPath, contentWithNewRecord);
      } else {
        final dataFile = File(dataPath);
        final sink = dataFile.openWrite(mode: FileMode.append);
        try {
          sink.writeln(jsonEncode(targetRecord));
          await sink.flush();
        } finally {
          await sink.close();
        }
      }
    } catch (e) {
      Logger.error('restore record from backup failed: $e');
    }
  }

  /// create new table
  Future<void> _createNewTable(String tableName, TableSchema schema) async {
    final dataPath = _dataStore.config.getDataPath(tableName, schema.isGlobal);
    final schemaPath =
        _dataStore.config.getSchemaPath(tableName, schema.isGlobal);

    // Create empty data file
    await _dataStore.storage.writeAsString(dataPath, '');
    // Write schema file
    await _dataStore.storage
        .writeAsString(schemaPath, jsonEncode(schema.toJson()));

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
    final sourceDataPath =
        _dataStore.config.getDataPath(sourceName, schema.isGlobal);
    final targetDataPath =
        _dataStore.config.getDataPath(targetName, schema.isGlobal);

    final lines = await _dataStore.storage.readLines(sourceDataPath);

    if (kIsWeb) {
      final validLines = <String>[];
      var startOffset = 0;

      for (var line in lines) {
        try {
          if (line.trim().isEmpty) continue;

          final data = jsonDecode(line) as Map<String, dynamic>;
          if (_isValidRecord(data, schema)) {
            validLines.add(line);
            // update index
            final encoded = jsonEncode(data);
            final pointer = await RowPointer.create(encoded, startOffset);
            await _indexManager.updateIndexes(targetName, data, pointer);
            startOffset += encoded.length + 1; // +1 for newline
          }
        } catch (e) {
          // skip damaged record
          Logger.warn('Skipping damaged record: $e');
          continue;
        }
      }

      // write all valid lines at once
      if (validLines.isNotEmpty) {
        await _dataStore.storage.writeLines(targetDataPath, validLines);
      }
    } else {
      // native platform implementation: use streaming write
      final file = File(targetDataPath);
      final sink = file.openWrite(mode: FileMode.write);

      var startOffset = 0;

      try {
        for (var line in lines) {
          try {
            if (line.trim().isEmpty) continue;

            final data = jsonDecode(line) as Map<String, dynamic>;
            if (_isValidRecord(data, schema)) {
              // stream write each line
              sink.writeln(line);

              // update index
              final encoded = jsonEncode(data);
              final pointer = await RowPointer.create(encoded, startOffset);
              await _indexManager.updateIndexes(targetName, data, pointer);
              startOffset += encoded.length + 1; // +1 for newline
            }
          } catch (e) {
            // skip damaged record
            Logger.warn('Skipping damaged record: $e');
            continue;
          }
        }

        // ensure all data is written
        await sink.flush();
      } finally {
        // close file stream
        await sink.close();
      }
    }
  }

  /// replace table
  Future<void> _replaceTable(String oldName, String newName) async {
    final schema = await _dataStore.getTableSchema(oldName);
    final oldDataPath = _dataStore.config.getDataPath(oldName, schema.isGlobal);
    final oldSchemaPath =
        _dataStore.config.getSchemaPath(oldName, schema.isGlobal);
    final newDataPath = _dataStore.config.getDataPath(newName, schema.isGlobal);
    final newSchemaPath =
        _dataStore.config.getSchemaPath(newName, schema.isGlobal);

    // Get all index files for old table
    final oldIndexPaths = await _getIndexPaths(oldName, schema);

    // Backup original files
    final backupSuffix = DateTime.now().millisecondsSinceEpoch.toString();

    // Backup data and schema files
    if (await _dataStore.storage.exists(oldDataPath)) {
      final oldDataContent = await _dataStore.storage.readAsString(oldDataPath);
      await _dataStore.storage
          .writeAsString('$oldDataPath.$backupSuffix', oldDataContent ?? '');
    }

    if (await _dataStore.storage.exists(oldSchemaPath)) {
      final oldSchemaContent =
          await _dataStore.storage.readAsString(oldSchemaPath);
      await _dataStore.storage.writeAsString(
          '$oldSchemaPath.$backupSuffix', oldSchemaContent ?? '');
    }

    // Backup index files
    for (var indexPath in oldIndexPaths) {
      if (await _dataStore.storage.exists(indexPath)) {
        final content = await _dataStore.storage.readAsString(indexPath);
        await _dataStore.storage
            .writeAsString('$indexPath.$backupSuffix', content ?? '');
      }
    }

    // Replace files
    if (await _dataStore.storage.exists(newDataPath)) {
      final content = await _dataStore.storage.readAsString(newDataPath);
      await _dataStore.storage.writeAsString(oldDataPath, content ?? '');
      await _dataStore.storage.deleteFile(newDataPath);
    }

    if (await _dataStore.storage.exists(newSchemaPath)) {
      final content = await _dataStore.storage.readAsString(newSchemaPath);
      await _dataStore.storage.writeAsString(oldSchemaPath, content ?? '');
      await _dataStore.storage.deleteFile(newSchemaPath);
    }
  }

  /// get index paths
  Future<List<String>> _getIndexPaths(
      String tableName, TableSchema schema) async {
    final paths = <String>[];

    for (var index in schema.indexes) {
      final indexPath = _dataStore.config.getIndexPath(
        tableName,
        index.actualIndexName,
        schema.isGlobal,
      );
      if (await _dataStore.storage.exists(indexPath)) {
        paths.add(indexPath);
      }
    }

    // Add primary index path
    final pkIndexPath = _dataStore.config.getIndexPath(
      tableName,
      'pk_$tableName',
      schema.isGlobal,
    );
    if (await _dataStore.storage.exists(pkIndexPath)) {
      paths.add(pkIndexPath);
    }

    return paths;
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
      case DataType.array:
        return value is List;
    }
  }
}
