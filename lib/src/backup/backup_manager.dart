import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../handler/common.dart';
import '../handler/logger.dart';
import '../core/data_compressor.dart';
import '../core/data_store_impl.dart';

import '../model/row_pointer.dart';
import '../model/table_schema.dart';
import 'backup_info.dart';

/// backup manager
class BackupManager {
  final DataStoreImpl _dataStore;
  final DataCompressor _compressor;

  BackupManager(this._dataStore)
      : _compressor = DataCompressor(
            compressionLevel: _dataStore.config.compressionLevel);

  /// extract file name from path
  String _getFileName(String path) {
    final normalizedPath = path.replaceAll('\\', '/');
    final parts = normalizedPath.split('/');
    final fileName = parts.isEmpty ? path : parts.last;

    if (fileName.contains('.')) {
      return fileName.substring(0, fileName.lastIndexOf('.'));
    }

    return fileName;
  }

  /// create backup file
  Future<String> createBackup() async {
    final timestamp = DateTime.now().toIso8601String();
    final backupPath = _dataStore.config.getBackupPath();
    final backupFilePath = pathJoin(backupPath, 'backup_$timestamp.bak');

    // create backup directory
    await _dataStore.storage.writeAsString(backupFilePath, '');

    // collect data of base space and public path
    final allData = <String, Map<String, dynamic>>{};

    // 1. collect data of base space
    final basePath = _dataStore.config.getBasePath();
    await _collectPathData(basePath, allData);

    // 2. collect data of global path
    final globalPath = _dataStore.config.getGlobalPath();
    await _collectPathData(globalPath, allData);

    // create backup data structure
    final backupData = {
      'timestamp': timestamp,
      'data': allData,
      'checksum': '', // leave empty, calculate later
    };

    // serialize and compress data
    final serialized = jsonEncode(backupData);
    final compressed = _compressor.compress(
      Uint8List.fromList(utf8.encode(serialized)),
    );

    // calculate checksum
    final checksum = _compressor.calculateChecksum(compressed);
    backupData['checksum'] = checksum.toString();

    final finalSerialized = jsonEncode(backupData);

    // write to backup file
    await _dataStore.storage.writeAsString(backupFilePath, finalSerialized);

    return backupFilePath;
  }

  /// collect data of specified path
  Future<void> _collectPathData(
      String path, Map<String, Map<String, dynamic>> allData) async {
    if (!await _dataStore.storage.exists(path)) return;

    final files = await _dataStore.storage.listDirectory(path);
    for (var file in files) {
      if (file.endsWith('.dat')) {
        final tableName = _getFileName(file);

        // read data file
        final lines = await _dataStore.storage.readLines(file);
        final tableData = <String, dynamic>{};

        // read table schema
        final schema = await _dataStore.getTableSchema(tableName);
        tableData['schema'] = schema;

        // read table data
        final records = <Map<String, dynamic>>[];
        for (var line in lines) {
          if (line.trim().isEmpty) continue;
          records.add(jsonDecode(line));
        }
        tableData['data'] = records;

        allData[tableName] = tableData;
      }
    }
  }

  /// load backup
  Future<Map<String, dynamic>> loadBackup(String backupPath) async {
    if (!await _dataStore.storage.exists(backupPath)) {
      throw FileSystemException('backup file not found', backupPath);
    }

    // read and decompress data
    final compressed = await _dataStore.storage.readAsBytes(backupPath);
    final decompressed = _compressor.decompress(compressed);

    // parse data
    final decoded = utf8.decode(decompressed);
    final backupData = jsonDecode(decoded) as Map<String, dynamic>;

    // verify data structure
    if (!backupData.containsKey('timestamp') ||
        !backupData.containsKey('data') ||
        !backupData.containsKey('checksum')) {
      Logger.error('Invalid backup data structure',
          label: 'BackupManager.loadBackup');
      throw const FormatException('Invalid backup file format');
    }

    return backupData;
  }

  /// list all backups
  Future<List<BackupInfo>> listBackups() async {
    final backups = <BackupInfo>[];
    final backupPath = _dataStore.config.getBackupPath();
    final files = await _dataStore.storage.listDirectory(backupPath);

    if (!await _dataStore.storage.exists(backupPath)) {
      return backups;
    }

    for (var file in files) {
      if (file.endsWith('.bak')) {
        try {
          final backupData = await loadBackup(file);
          int size = 0;
          if (kIsWeb) {
            final compressed = await _dataStore.storage.readAsBytes(file);
            size = compressed.length;
          } else {
            final fileEntity = File(file);
            size = await fileEntity.length();
          }
          backups.add(BackupInfo(
            path: file,
            timestamp: DateTime.parse(backupData['timestamp'] as String),
            isIncremental: file.contains('incr_'),
            size: size,
          ));
        } catch (e) {
          // skip invalid backup file
          Logger.error('Skip invalid backup file: $file, error: $e',
              label: 'BackupManager.listBackups');
          continue;
        }
      }
    }

    // sort by timestamp
    backups.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return backups;
  }

  /// restore from backup
  Future<void> restore(String backupPath) async {
    try {
      // Load backup data
      final backupData = await loadBackup(backupPath);
      final data = backupData['data'] as Map<String, dynamic>;

      // Clean existing data
      final basePath = _dataStore.config.getBasePath();
      if (kIsWeb) {
        // Web platform: clean via storage API
        final files = await _dataStore.storage.listDirectory(basePath);
        for (var file in files) {
          await _dataStore.storage.deleteFile(file);
        }
      } else {
        // Native platform: use directory operations
        final dbDir = Directory(basePath);
        if (await dbDir.exists()) {
          await dbDir.delete(recursive: true);
        }
        await dbDir.create(recursive: true);
      }

      // Restore each table data
      for (var entry in data.entries) {
        final tableName = entry.key;
        final tableData = entry.value as Map<String, dynamic>;

        // Restore table schema
        final schema = TableSchema.fromJson(tableData['schema']);
        await _dataStore.createTable(schema);

        // Restore table data
        final records = tableData['data'] as List<dynamic>;

        // Write data to files using appropriate file modes
        final dataPath =
            _dataStore.config.getDataPath(tableName, schema.isGlobal);

        if (kIsWeb) {
          // Web implementation: build content and write at once
          final lines = records
              .map((r) => jsonEncode(r as Map<String, dynamic>))
              .toList();
          await _dataStore.storage.writeLines(dataPath, lines);
        } else {
          // Native implementation: use FileMode.write to ensure we're replacing contents
          final file = File(dataPath);
          final sink = file.openWrite(mode: FileMode.write);
          try {
            for (var record in records) {
              sink.writeln(jsonEncode(record));
            }
            await sink.flush();
          } finally {
            await sink.close();
          }
        }

        // Update indexes for all records
        await _dataStore.indexManager?.resetIndexes(tableName);

        var offset = 0;
        for (var record in records) {
          final data = record as Map<String, dynamic>;
          final encoded = jsonEncode(data);
          final pointer = await RowPointer.create(encoded, offset);
          await _dataStore.indexManager
              ?.updateIndexes(tableName, data, pointer);
          offset += encoded.length + 1; // +1 for newline
        }

        Logger.info('Table $tableName restored');
      }

      Logger.info('Database restored successfully');
    } catch (e) {
      Logger.error('Failed to restore from backup: $e',
          label: 'BackupManager.restore');
      rethrow;
    }
  }

  /// verify backup integrity
  Future<bool> verifyBackup(String backupPath) async {
    try {
      final backupData = await loadBackup(backupPath);
      final storedChecksum = backupData['checksum'] as String;

      // verify checksum
      if (storedChecksum.isNotEmpty) {
        final compressed = await _dataStore.storage.readAsBytes(backupPath);
        final actualChecksum =
            _compressor.calculateChecksum(compressed).toString();
        if (actualChecksum != storedChecksum) {
          Logger.debug('Checksum mismatch');
          return false;
        }
      }

      // verify data integrity
      final data = backupData['data'] as Map<String, dynamic>;
      for (var tableData in data.values) {
        if (tableData == null || tableData is! Map<String, dynamic>) {
          Logger.debug('Invalid table data format');
          return false;
        }

        // verify table schema
        if (!tableData.containsKey('schema')) {
          Logger.debug('Missing table schema definition');
          return false;
        }

        // verify table data
        if (!tableData.containsKey('data') || tableData['data'] is! List) {
          Logger.debug('Invalid table data format');
          return false;
        }
      }

      return true;
    } catch (e) {
      Logger.error('Failed to verify backup: $e',
          label: 'BackupManager.verifyBackup');
      return false;
    }
  }
}

/// file change record
class FileChange {
  final String filePath;
  final DateTime modifiedTime;

  FileChange({
    required this.filePath,
    required this.modifiedTime,
  });
}
