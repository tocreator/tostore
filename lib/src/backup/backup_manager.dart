import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../handler/logger.dart';
import '../core/data_compressor.dart';
import '../core/data_store_impl.dart';

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
    return parts.last.replaceAll('.dat', '');
  }

  /// create backup file
  Future<String> createBackup() async {
    final timestamp = DateTime.now().toIso8601String();
    final backupPath = _dataStore.config.getBackupPath();
    final backupFile = File('$backupPath/backup_$timestamp.bak');

    // create backup directory
    await Directory(backupPath).create(recursive: true);

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
    final finalCompressed = _compressor.compress(
      Uint8List.fromList(utf8.encode(finalSerialized)),
    );

    // write to backup file
    await backupFile.writeAsBytes(finalCompressed);

    return backupFile.path;
  }

  /// collect data of specified path
  Future<void> _collectPathData(
      String path, Map<String, Map<String, dynamic>> allData) async {
    final dir = Directory(path);
    if (!await dir.exists()) return;

    await for (var entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.dat')) {
        final tablePath = entity.path.replaceAll('.dat', '');
        final tableName = _getFileName(tablePath);

        // read data file
        final lines = await entity.readAsLines();
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
    final backupFile = File(backupPath);
    if (!await backupFile.exists()) {
      throw FileSystemException('备份文件不存在', backupPath);
    }

    // read and decompress data
    final compressed = await backupFile.readAsBytes();
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
    final dir = Directory(backupPath);

    if (!await dir.exists()) {
      return backups;
    }

    await for (var entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.bak')) {
        try {
          final backupData = await loadBackup(entity.path);
          backups.add(BackupInfo(
            path: entity.path,
            timestamp: DateTime.parse(backupData['timestamp'] as String),
            isIncremental: entity.path.contains('incr_'),
            size: await entity.length(),
          ));
        } catch (e) {
          // skip invalid backup file
          Logger.error('Skip invalid backup file: ${entity.path}, error: $e',
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
      // load backup data
      final backupData = await loadBackup(backupPath);
      final data = backupData['data'] as Map<String, dynamic>;

      // clean existing data
      final dbDir = Directory(_dataStore.config.getBasePath());
      if (await dbDir.exists()) {
        await dbDir.delete(recursive: true);
      }
      await dbDir.create(recursive: true);

      // restore each table data
      for (var entry in data.entries) {
        final tableName = entry.key;
        final tableData = entry.value as Map<String, dynamic>;

        // restore table schema
        final schema = TableSchema.fromJson(tableData['schema']);
        await _dataStore.createTable(schema);

        // restore table data
        final records = tableData['data'] as List<dynamic>;
        for (var record in records) {
          await _dataStore.insert(tableName, record as Map<String, dynamic>);
        }

        Logger.info('Table $tableName restored');
      }

      Logger.info('Database restored');
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
        final file = File(backupPath);
        final content = await file.readAsBytes();
        final actualChecksum =
            _compressor.calculateChecksum(content).toString();
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
