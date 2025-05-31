import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';

import '../handler/logger.dart';
import '../handler/common.dart';
import '../backup/backup_manager.dart';
import '../core/data_store_impl.dart';
import '../core/index_manager.dart';
import '../model/store_index.dart';
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
    final backups = await _getBackups();
    if (backups.isEmpty) {
      throw StateError('No backup available for repair');
    }

    // try to restore from latest backup
    for (var backupPath in backups) {
      try {
        await _restoreRecordFromBackup(tableName, recordId, backupPath);
        return;
      } catch (e) {
        Logger.error('Failed to restore from backup $backupPath: $e',
            label: 'AutoRepair.repairRecord');
        // try next backup
        continue;
      }
    }

    throw StateError('Unable to repair record from any backup');
  }

  /// rebuild index
  Future<void> rebuildIndex(String tableName, String indexName) async {
    try {
      Logger.info('Starting to rebuild index $indexName for table $tableName',
          label: 'AutoRepair.rebuildIndex');

      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
        return;
      }
      final indexSchema =
          schema.indexes.firstWhere((idx) => idx.actualIndexName == indexName);
      final primaryKey = schema.primaryKey;

      // remove old index
      await _indexManager.removeIndex(tableName, indexName);

      // create new index
      await _indexManager.createIndex(tableName, indexSchema);

      Logger.info('Created new index structure for $indexName',
          label: 'AutoRepair.rebuildIndex');

      // First get the real physical locations of all records in the table
      final recordStoreIndexes = <String, StoreIndex>{};

      // Step 1: Scan all partitions to get record physical location mapping
      final fileMeta =
          await _dataStore.tableDataManager.getTableFileMeta(tableName);
      if (fileMeta != null && fileMeta.partitions != null) {
        for (final partition in fileMeta.partitions!) {
          final partitionId = partition.index;
          final partitionRecords = await _dataStore.tableDataManager
              .readRecordsFromPartition(
                  tableName, schema.isGlobal, partitionId, primaryKey);

          // Calculate the physical offset for each record
          int recordOffset = 0;
          for (final record in partitionRecords) {
            final pk = record[primaryKey]?.toString() ?? '';
            if (pk.isNotEmpty) {
              // Encode record as JSON to get accurate size
              final encoded = jsonEncode(record);
              final storeIndex = await StoreIndex.create(encoded, recordOffset,
                  partitionId: partitionId);

              recordStoreIndexes[pk] = storeIndex;
              recordOffset += encoded.length; // Update offset for next record
            }
          }
        }
      }

      // Step 2: Rebuild index using real StoreIndex
      var recordCount = 0;
      await for (final record
          in _dataStore.tableDataManager.streamRecords(tableName)) {
        final pk = record[primaryKey]?.toString() ?? '';

        if (pk.isNotEmpty) {
          // Find the actual physical location of the record
          final storeIndex = recordStoreIndexes[pk];

          if (storeIndex != null) {
            // Update index using actual physical location
            await _indexManager.updateIndexes(tableName, record, storeIndex);
            recordCount++;

            if (recordCount % 1000 == 0) {
              Logger.info('Processed $recordCount records',
                  label: 'AutoRepair.rebuildIndex');
            }
          } else {
            // If physical location not found, might be a new record or in cache
            Logger.warn(
                'Cannot find physical location for record $pk, might be data in cache',
                label: 'AutoRepair.rebuildIndex');

            // Create a temporary index for cached data (using a special partition ID, e.g. -1 for cache area)
            final encoded = jsonEncode(record);
            final tempIndex = await StoreIndex.create(
                encoded, recordCount, // As temporary offset
                partitionId: -1 // Indicates record in cache
                );

            await _indexManager.updateIndexes(tableName, record, tempIndex);
            recordCount++;
          }
        }
      }

      Logger.info(
          'Successfully rebuilt index $indexName with $recordCount records',
          label: 'AutoRepair.rebuildIndex');
    } catch (e) {
      Logger.error('Failed to rebuild index: $e',
          label: 'AutoRepair.rebuildIndex');
      rethrow;
    }
  }

  /// repair table structure
  Future<void> repairTableStructure(String tableName) async {
    try {
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
        return;
      }

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
  Future<List<String>> _getBackups() async {
    try {
      final backups = await _backupManager.listBackups();
      return backups.map((b) => b.path).toList();
    } catch (e) {
      Logger.error('Failed to get backups: $e',
          label: 'AutoRepair._getBackups');
      return [];
    }
  }

  /// restore record from backup
  Future<void> _restoreRecordFromBackup(
    String tableName,
    String recordId,
    String backupPath,
  ) async {
    try {
      final isZip = backupPath.endsWith('.zip');
      String workingPath = backupPath;
      bool needsCleanup = false;

      try {
        if (isZip) {
          workingPath = await _extractBackupForRecordRecovery(backupPath);
          needsCleanup = true;
        }

        final schemaInfo =
            await _getTableSchemaFromBackup(workingPath, tableName);
        if (schemaInfo == null) {
          throw StateError('Schema for table $tableName not found in backup');
        }

        final schema = schemaInfo.schema;
        final isGlobal = schema.isGlobal;
        final primaryKey = schema.primaryKey;

        Map<String, dynamic>? targetRecord;

        await for (final record
            in _dataStore.tableDataManager.streamRecordsFromCustomPath(
          customRootPath: workingPath,
          tableName: tableName,
          isGlobal: isGlobal,
          targetKey: recordId,
          primaryKey: primaryKey,
          spaceName: _dataStore.config.spaceName,
        )) {
          targetRecord = record;
          break;
        }

        if (targetRecord == null) {
          throw StateError('Record $recordId not found in backup');
        }

        await _dataStore.insert(tableName, targetRecord);
      } finally {
        if (needsCleanup && workingPath != backupPath) {
          try {
            await _dataStore.storage.deleteDirectory(workingPath);
          } catch (e) {
            Logger.error('Failed to cleanup temporary directory: $e',
                label: 'AutoRepair._restoreRecordFromBackup');
          }
        }
      }
    } catch (e) {
      Logger.error('Failed to restore record from backup: $e',
          label: 'AutoRepair._restoreRecordFromBackup');
      rethrow;
    }
  }

  /// get table schema from backup
  Future<_SchemaInfo?> _getTableSchemaFromBackup(
      String backupPath, String tableName) async {
    // try to find table in spaces directory
    final spacesPath = pathJoin(backupPath, 'spaces');
    if (await _dataStore.storage.existsDirectory(spacesPath)) {
      // traverse all base directories
      final baseDirs = await _dataStore.storage.listDirectory(spacesPath);
      for (final baseDir in baseDirs) {
        if (await _dataStore.storage.existsDirectory(baseDir)) {
          final tablePath = pathJoin(baseDir, tableName);
          if (await _dataStore.storage.existsDirectory(tablePath)) {
            final schemaPath = pathJoin(tablePath, 'schema.sch');
            if (await _dataStore.storage.existsFile(schemaPath)) {
              final schemaJson =
                  await _dataStore.storage.readAsString(schemaPath);
              if (schemaJson != null) {
                final schema = TableSchema.fromJson(jsonDecode(schemaJson));
                return _SchemaInfo(schema, tablePath);
              }
            }
          }
        }
      }
    }

    // try to find table in global directory
    final globalPath = pathJoin(backupPath, 'global');
    if (await _dataStore.storage.existsDirectory(globalPath)) {
      final tablePath = pathJoin(globalPath, tableName);
      if (await _dataStore.storage.existsDirectory(tablePath)) {
        final schemaPath = pathJoin(tablePath, 'schema.sch');
        if (await _dataStore.storage.existsFile(schemaPath)) {
          final schemaJson = await _dataStore.storage.readAsString(schemaPath);
          if (schemaJson != null) {
            final schema = TableSchema.fromJson(jsonDecode(schemaJson));
            return _SchemaInfo(schema, tablePath);
          }
        }
      }
    }

    return null;
  }

  /// from zip backup
  Future<String> _extractBackupForRecordRecovery(String zipPath) async {
    if (kIsWeb) {
      throw UnsupportedError('ZIP extraction not supported on web platform');
    }

    final tempDir = await Directory.systemTemp.createTemp('tostore_repair_');
    final tempPath = tempDir.path;

    try {
      try {
        await extractFileToDisk(zipPath, tempPath);
      } catch (e) {
        Logger.error('Failed to extract ZIP file using standard method: $e',
            label: 'AutoRepair._extractBackupForRecordRecovery');

        // try alternative unzip method
        final bytes = await File(zipPath).readAsBytes();
        final archive = ZipDecoder().decodeBytes(bytes);

        for (final file in archive) {
          final filename = file.name;
          if (file.isFile) {
            final data = file.content as List<int>;
            final outFile = File('$tempPath/$filename');
            await outFile.parent.create(recursive: true);
            await outFile.writeAsBytes(data);
          } else {
            await Directory('$tempPath/$filename').create(recursive: true);
          }
        }
      }

      return tempPath;
    } catch (e) {
      await tempDir.delete(recursive: true);
      Logger.error('Failed to extract backup ZIP for record recovery: $e',
          label: 'AutoRepair._extractBackupForRecordRecovery');
      rethrow;
    }
  }

  /// create new table
  Future<void> _createNewTable(String tableName, TableSchema schema) async {
    final dataPath = await _dataStore.pathManager.getDataMetaPath(tableName);

    // use partitioned table structure storage
    final schemaMetaPath = _dataStore.pathManager.getSchemaMetaPath();
    final schemaPartitionPath = _dataStore.pathManager
        .getSchemaPartitionFilePath(0); // use first partition

    // ensure directory exists
    await _dataStore.storage.ensureDirectoryExists(schemaMetaPath);
    await _dataStore.storage.ensureDirectoryExists(schemaPartitionPath);

    // Create empty data file
    await _dataStore.storage.writeAsString(dataPath, '');

    // store table schema
    await _dataStore.updateTableSchema(schema.name, schema);

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
    try {
      final recordStream = _dataStore.tableDataManager
          .streamRecords(sourceName)
          .where((record) => _isValidRecord(record, schema));

      final batchSize = _dataStore.config.migrationConfig?.batchSize ?? 1000;

      // Write filtered records to target table using partitioned approach
      await _dataStore.tableDataManager.rewriteRecordsFromStream(
        tableName: targetName,
        recordStream: recordStream,
        batchSize: batchSize,
      );
    } catch (e) {
      Logger.error('Failed to migrate valid data: $e',
          label: 'AutoRepair._migrateValidData');
      rethrow;
    }
  }

  /// replace table
  Future<void> _replaceTable(String oldName, String newName) async {
    try {
      final schema = await _dataStore.getTableSchema(oldName);
      if (schema == null) {
        return;
      }

      // 1. backup original indexes - for safety
      await _backupIndexes(oldName, schema);

      // 2. read all records from temp table
      var recordsStream = _dataStore.tableDataManager.streamRecords(newName);

      // 3. rewrite records from temp table to original table, using partitioned approach
      await _dataStore.tableDataManager.rewriteRecordsFromStream(
        tableName: oldName,
        recordStream: recordsStream,
        batchSize: _dataStore.config.migrationConfig?.batchSize ?? 1000,
      );

      // 4. delete temp table
      await _deleteTable(newName);

      Logger.info('Table $oldName successfully restored from repair table',
          label: 'AutoRepair._replaceTable');
    } catch (e) {
      Logger.error('Failed to replace table: $e',
          label: 'AutoRepair._replaceTable');
      rethrow;
    }
  }

  /// backup indexes
  Future<void> _backupIndexes(String tableName, TableSchema schema) async {
    final backupSuffix = DateTime.now().millisecondsSinceEpoch.toString();
    final oldIndexPaths = await _getIndexPaths(tableName, schema);

    for (var indexPath in oldIndexPaths) {
      if (await _dataStore.storage.existsFile(indexPath)) {
        final content = await _dataStore.storage.readAsString(indexPath);
        await _dataStore.storage
            .writeAsString('$indexPath.$backupSuffix', content ?? '');
      }
    }
  }

  /// delete table
  Future<void> _deleteTable(String tableName) async {
    try {
      final tablePath = await _dataStore.pathManager.getTablePath(tableName);

      if (await _dataStore.storage.existsDirectory(tablePath)) {
        await _dataStore.storage.deleteDirectory(tablePath);
      }
    } catch (e) {
      Logger.error('Failed to delete table: $e',
          label: 'AutoRepair._deleteTable');
    }
  }

  /// get index paths
  Future<List<String>> _getIndexPaths(
      String tableName, TableSchema schema) async {
    final paths = <String>[];

    // get all index paths
    for (var index in schema.indexes) {
      final indexPartitions = await _indexManager.getIndexPartitions(
          tableName, index.actualIndexName);
      if (indexPartitions.isNotEmpty) {
        for (var partition in indexPartitions.values) {
          paths.add(partition.path);
        }
      }
    }

    // add primary key index path
    final pkIndexPartitions =
        await _indexManager.getIndexPartitions(tableName, 'pk_$tableName');
    for (var partition in pkIndexPartitions.values) {
      paths.add(partition.path);
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
        if (value != null && !field.isValidDataType(value, field.type)) {
          return false;
        }
      }
      return true;
    } catch (e) {
      return false;
    }
  }
}

/// schema info
class _SchemaInfo {
  final TableSchema schema;
  final String basePath;

  _SchemaInfo(this.schema, this.basePath);
}
