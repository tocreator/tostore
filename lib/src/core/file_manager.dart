import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../handler/logger.dart';
import 'data_store_impl.dart';
import '../model/row_pointer.dart';

/// file manager - schedule data read/write, backup, index update, etc.
class FileManager {
  final DataStoreImpl _dataStore;

  // write queue
  final Map<String, List<Map<String, dynamic>>> _writeQueue = {};
  Map<String, List<Map<String, dynamic>>> get writeQueue => _writeQueue;

  // last write time
  DateTime _lastWriteTime =
      DateTime.now().subtract(const Duration(seconds: 15));

  // write strategy configuration
  static const int _maxQueueSize =
      100; // queue max capacity threshold (per table)
  static const Duration _checkInterval = Duration(seconds: 3); // check interval
  static const int _idleWriteCount =
      5; // idle write count (5 times 3 seconds = 15 seconds)

  Timer? _timer;
  int _idleCount = 0; // idle counter
  bool _isWriting = false; // write status flag

  // store table file size information
  final Map<String, int> _fileSizes = {};
  // store file last modified time
  final Map<String, DateTime> _lastModifiedTimes = {};

  // add backup write lock
  bool _isBackingUp = false;
  bool _isNeedBackup = false; // need backup write queue

  FileManager(this._dataStore);

  /// add to write queue
  void addToWriteQueue(String tableName, Map<String, dynamic> data,
      {bool isUpdate = false}) {
    final queue = _writeQueue.putIfAbsent(tableName, () => []);
    queue.add(data);
    _idleCount = 0; // reset idle counter
    _isNeedBackup = true;
  }

  /// start timer
  void startTimer() {
    loadBackups();
    _timer?.cancel();
    _timer = Timer.periodic(_checkInterval, (timer) async {
      try {
        if (_writeQueue.isEmpty) {
          _idleCount = 0;
          return;
        }

        // 1. create backup of write queue
        if (!_isBackingUp && _isNeedBackup) {
          final currentQueue =
              Map<String, List<Map<String, dynamic>>>.from(_writeQueue);
          await _backupWriteQueue(currentQueue);
        }

        // 2. check if need to write data file
        if (_isWriting) return;

        // check if any table queue exceeds threshold
        bool needsImmediateWrite = false;
        for (var queue in _writeQueue.values) {
          if (queue.length >= _maxQueueSize) {
            needsImmediateWrite = true;
            break;
          }
        }

        // 3. if time since last write is >= 15 seconds, trigger flush
        final idleWriteDuration = DateTime.now().difference(_lastWriteTime);
        if (idleWriteDuration >= const Duration(seconds: 15)) {
          needsImmediateWrite = true;
        }

        // check if need to write based on idle count or immediate need
        if (needsImmediateWrite || _idleCount >= _idleWriteCount) {
          _idleCount = 0;
          if (_writeQueue.isNotEmpty && !_isWriting) {
            _isWriting = true;
            try {
              await flushWriteQueue();
              // handle auto-increment ID write
              await _dataStore.flushMaxIds();
              // update last write time
              _lastWriteTime = DateTime.now();
            } finally {
              _isWriting = false;
            }
          }
        } else {
          _idleCount++;
        }
      } catch (e, stackTrace) {
        Logger.error('timer process failed: $e\n$stackTrace',
            label: 'FileManager-startTimer');
        _isWriting = false;
      }
    });
  }

  /// stop timer
  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;

    // last flush all write queue
    if (_writeQueue.isNotEmpty) {
      // first backup
      final currentQueue =
          Map<String, List<Map<String, dynamic>>>.from(_writeQueue);
      await _backupWriteQueue(currentQueue);
      // then write
      await flushWriteQueue();
    }
    // cleanup all backup files
    await _cleanupBackupFiles();
    // cleanup file size information
    clearFileSizes();
    // cleanup write queue
    _writeQueue.clear();
  }

  /// flush write queue
  Future<void> flushWriteQueue() async {
    if (_writeQueue.isEmpty) return;
    // copy current queue to avoid modification during processing
    final currentQueue =
        Map<String, List<Map<String, dynamic>>>.from(_writeQueue);
    try {
      for (var entry in currentQueue.entries) {
        final tableName = entry.key;
        final records = entry.value;
        if (records.isEmpty) continue;
        await writeRecords(tableName: tableName, records: records);
      }
    } catch (e, stackTrace) {
      Logger.error('write queue flush failed: $e',
          label: 'FileManager-flushWriteQueue');
      Logger.error(stackTrace.toString(), label: 'FileManager-flushWriteQueue');
      // restore all backups when error occurs
      await _restoreAllBackups();
    }
  }

  /// backup write queue
  Future<void> _backupWriteQueue(
      Map<String, List<Map<String, dynamic>>> queue) async {
    if (_isBackingUp) return;
    try {
      _isBackingUp = true;
      final needBackupBeforeStart = _isNeedBackup; // record start backup status

      for (var entry in queue.entries) {
        final tableName = entry.key;
        await _dataStore.concurrencyManager
            ?.acquireWriteLock('backup_$tableName');
        try {
          final schema = await _dataStore.getTableSchema(tableName);
          final backupPath =
              '${_dataStore.config.getTablePath(tableName, schema.isGlobal)}.write.bak';
          await _dataStore.storage
              .writeAsString(backupPath, jsonEncode(entry.value));
        } finally {
          await _dataStore.concurrencyManager
              ?.releaseWriteLock('backup_$tableName');
        }
      }

      // only reset flag when need backup before start
      // this can keep backup requirement for new added data during backup
      if (needBackupBeforeStart) {
        _isNeedBackup = false;
      }
    } finally {
      _isBackingUp = false;
    }
  }

  /// restore single table write queue from backup
  Future<void> _restoreFromBackup(String tableName) async {
    final schema = await _dataStore.getTableSchema(tableName);
    final backupPath =
        '${_dataStore.config.getTablePath(tableName, schema.isGlobal)}.write.bak';
    if (await _dataStore.storage.exists(backupPath)) {
      try {
        final content = await _dataStore.storage.readAsString(backupPath);
        final records =
            (jsonDecode(content ?? '') as List).cast<Map<String, dynamic>>();
        _writeQueue[tableName] = records;
      } catch (e) {
        Logger.error('restore write queue from backup failed: $e',
            label: 'FileManager._restoreFromBackup');
      }
    }
  }

  /// restore all backups
  Future<void> _restoreAllBackups() async {
    final basePath = _dataStore.config.getBasePath();

    if (!await _dataStore.storage.exists(basePath)) return;

    for (var path in await _dataStore.storage.listDirectory(basePath)) {
      if (path.endsWith('.write.bak')) {
        final tableName = _getTableNameFromPath(path);
        await _restoreFromBackup(tableName);
      }
    }
  }

  /// delete backup file
  Future<void> _removeBackupFile(String tableName) async {
    final schema = await _dataStore.getTableSchema(tableName);
    final backupPath =
        '${_dataStore.config.getTablePath(tableName, schema.isGlobal)}.write.bak';
    if (await _dataStore.storage.exists(backupPath)) {
      await _dataStore.storage.deleteFile(backupPath);
    }
  }

  /// extract table name from path
  String _getTableNameFromPath(String path) {
    final normalizedPath = path.replaceAll('\\', '/');
    final parts = normalizedPath.split('/');
    final fileName = parts.isEmpty ? path : parts.last;

    // Handle backup files first
    if (fileName.endsWith('.write.bak')) {
      return fileName.replaceAll('.write.bak', '');
    }

    // Handle regular files
    final dotIndex = fileName.indexOf('.');
    if (dotIndex != -1) {
      return fileName.substring(0, dotIndex);
    }

    return fileName;
  }

  /// cleanup all backup files
  Future<void> _cleanupBackupFiles() async {
    final basePath = _dataStore.config.getBasePath();
    if (!await _dataStore.storage.exists(basePath)) return;

    for (var path in await _dataStore.storage.listDirectory(basePath)) {
      if (path.endsWith('.write.bak')) {
        await _dataStore.storage.deleteFile(path);
      }
    }
  }

  /// get table file size
  int getFileSize(String tableName) {
    return _fileSizes[tableName] ?? 0;
  }

  /// update table file size and modified time
  Future<void> updateFileSize(String tableName, int size) async {
    _fileSizes[tableName] = size;
    _lastModifiedTimes[tableName] = DateTime.now();
  }

  /// check if allow full table cache
  bool allowFullTableCache(String tableName, int maxSize) {
    final size = getFileSize(tableName);
    return size <= maxSize;
  }

  /// check if file is modified
  bool isFileModified(String tableName, DateTime lastReadTime) {
    final lastModified = _lastModifiedTimes[tableName];
    return lastModified == null || lastModified.isAfter(lastReadTime);
  }

  /// get file last modified time
  DateTime? getLastModifiedTime(String tableName) {
    return _lastModifiedTimes[tableName];
  }

  /// cleanup table size information
  void clearFileSizes() {
    _fileSizes.clear();
    _lastModifiedTimes.clear();
  }

  /// load backups when initialize
  Future<void> loadBackups() async {
    try {
      final basePath = _dataStore.config.getBasePath();
      if (!await _dataStore.storage.exists(basePath)) return;
      for (var path in await _dataStore.storage.listDirectory(basePath)) {
        if (path.endsWith('.write.bak')) {
          final tableName = _getTableNameFromPath(path);
          await _restoreFromBackup(tableName);
        }
      }
    } catch (e) {
      Logger.error('load backups failed: $e', label: 'FileManager.loadBackups');
    }
  }

  /// get all files of a table
  Future<List<String>> getTableFiles(String tableName) async {
    final schema = await _dataStore.getTableSchema(tableName);
    final tablePath =
        _dataStore.config.getTablePath(tableName, schema.isGlobal);
    final files = <String>[];

    if (kIsWeb) {
      // Web implementation: use storage to list files
      final allFiles = await _dataStore.storage
          .listDirectory(tablePath.substring(0, tablePath.lastIndexOf('/')));

      for (var path in allFiles) {
        if (path.startsWith('$tablePath.')) {
          files.add(path);
        }
      }
    } else {
      // native platform implementation: use Directory API
      final dir = Directory(tablePath).parent;
      await for (var entity in dir.list()) {
        if (entity is File && entity.path.startsWith('$tablePath.')) {
          files.add(entity.path);
        }
      }
    }

    return files;
  }

  /// Read records from data file
  /// Returns a map of records with primary key as key
  Future<Map<String, Map<String, dynamic>>> readRecords(
      String tableName) async {
    final schema = await _dataStore.getTableSchema(tableName);
    final dataPath = _dataStore.config.getDataPath(tableName, schema.isGlobal);
    if (!await _dataStore.storage.exists(dataPath)) return {};

    final records = <String, Map<String, dynamic>>{};
    final primaryKey = schema.primaryKey;

    try {
      // use storage interface to read file
      final lines = await _dataStore.storage.readLines(dataPath);

      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final record = jsonDecode(line) as Map<String, dynamic>;
          records[record[primaryKey].toString()] = record;
        } catch (e) {
          Logger.error('Parse record failed: $e',
              label: 'FileManager.readRecords');
        }
      }
    } catch (e) {
      Logger.error('Read records failed: $e', label: 'FileManager.readRecords');
    }

    return records;
  }

  /// write records to data file
  Future<void> writeRecords({
    required String tableName,
    required List<Map<String, dynamic>> records,
    bool fullRewrite = false,
  }) async {
    if (records.isEmpty) return;
    // get data file write lock
    await _dataStore.concurrencyManager?.acquireWriteLock(tableName);
    try {
      final schema = await _dataStore.getTableSchema(tableName);
      final dataPath =
          _dataStore.config.getDataPath(tableName, schema.isGlobal);

      if (!await _dataStore.storage.exists(dataPath)) {
        await _dataStore.storage.writeAsString(dataPath, '');
      }

      final primaryKey = schema.primaryKey;
      var allRecords = <String, Map<String, dynamic>>{};

      var currentOffset = 0; // start from 0
      if (!fullRewrite) {
        // read existing file content
        allRecords = await readRecords(tableName);
        currentOffset = allRecords.length;
      }

      // update/add new records
      for (var record in records) {
        final recordId = record[primaryKey].toString();
        // update record
        allRecords[recordId] = record;
      }

      if (kIsWeb) {
        final lines = <String>[];
        for (var record in allRecords.values) {
          final encoded = jsonEncode(record);
          lines.add(encoded);

          // create row pointer (use current offset)
          final pointer = await RowPointer.create(encoded, currentOffset);

          // update index
          await _dataStore.indexManager
              ?.updateIndexes(tableName, record, pointer);

          // update offset (add record length and newline)
          currentOffset += encoded.length + 1;
        }

        // write all lines
        await _dataStore.storage.writeLines(dataPath, lines);
      } else {
        // native platform implementation: use file stream
        final file = File(dataPath);
        final sink = file.openWrite(mode: FileMode.write);

        try {
          for (var record in allRecords.values) {
            final encoded = jsonEncode(record);

            // create row pointer (use current offset)
            final pointer = await RowPointer.create(encoded, currentOffset);

            // write record
            sink.writeln(encoded);

            // update index
            await _dataStore.indexManager
                ?.updateIndexes(tableName, record, pointer);

            // update offset (add record length and newline)
            currentOffset += encoded.length + 1;
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
      }

      // update file size information
      await updateFileSize(tableName, currentOffset);

      // clear write queue after successful write
      _writeQueue.remove(tableName);

      // delete backup file of this table (need backup lock)
      if (!_isBackingUp) {
        // if no backup operation is in progress
        await _dataStore.concurrencyManager
            ?.acquireWriteLock('backup_$tableName');
        try {
          await _removeBackupFile(tableName);
        } finally {
          await _dataStore.concurrencyManager
              ?.releaseWriteLock('backup_$tableName');
        }
      }
    } finally {
      await _dataStore.concurrencyManager?.releaseWriteLock(tableName);
    }
  }

  /// Stream interface for reading large datasets
  Stream<Map<String, dynamic>> streamRecords(String tableName) async* {
    final schema = await _dataStore.getTableSchema(tableName);
    final dataPath = _dataStore.config.getDataPath(tableName, schema.isGlobal);

    if (!await _dataStore.storage.exists(dataPath)) return;

    if (kIsWeb) {
      // Web implementation
      final content = await _dataStore.storage.readAsString(dataPath);
      if (content == null) return;

      final lines = content.split('\n');
      for (var line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final record = jsonDecode(line) as Map<String, dynamic>;
          yield record;
        } catch (e) {
          Logger.error('Parse record failed: $e',
              label: 'FileManager.streamRecords');
        }
      }
    } else {
      // native platform implementation: use file stream
      final file = File(dataPath);
      final stream = file
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in stream) {
        if (line.trim().isEmpty) continue;
        try {
          final record = jsonDecode(line) as Map<String, dynamic>;
          yield record;
        } catch (e) {
          Logger.error('Parse record failed: $e',
              label: 'FileManager.streamRecords');
        }
      }
    }
  }
}
