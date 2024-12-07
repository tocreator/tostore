import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../handler/logger.dart';
import 'data_store_impl.dart';
import '../model/row_pointer.dart';

/// 文件管理器 - 调度数据读写、备份、索引更新等操作
class FileManager {
  final DataStoreImpl _dataStore;

  // 写入队列
  final Map<String, List<Map<String, dynamic>>> _writeQueue = {};
  Map<String, List<Map<String, dynamic>>> get writeQueue => _writeQueue;

  // 写入策略配置
  static const int _maxQueueSize = 100; // 队列最大容量阈值(每个表)
  static const Duration _checkInterval = Duration(seconds: 3); // 检查间隔
  static const int _idleWriteCount = 5; // 闲置写入计数(5次3秒 = 15秒)

  Timer? _timer;
  int _idleCount = 0; // 闲置计数器
  bool _isWriting = false; // 写入状态标记

  // 存储表文件大小信息
  final Map<String, int> _fileSizes = {};
  // 存储文件最后修改时间
  final Map<String, DateTime> _lastModifiedTimes = {};

  // 添加备份写入锁
  bool _isBackingUp = false;
  bool _isNeedBackup = false; // 需要备份待写入

  FileManager(this._dataStore);

  /// 添加到写入队列
  void addToWriteQueue(String tableName, Map<String, dynamic> data,
      {bool isUpdate = false}) {
    final queue = _writeQueue.putIfAbsent(tableName, () => []);
    queue.add(data);
    _idleCount = 0; // 重置闲置计数
    _isNeedBackup = true;
  }

  /// 启动定时器
  void startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(_checkInterval, (timer) async {
      try {
        if (_writeQueue.isEmpty) {
          _idleCount = 0;
          return;
        }

        // 1. 先创建待写入队列的备份
        if (!_isBackingUp && _isNeedBackup) {
          final currentQueue =
              Map<String, List<Map<String, dynamic>>>.from(_writeQueue);
          await _backupWriteQueue(currentQueue);
        }

        // 2. 检查是否需要写入数据文件
        if (_isWriting) return;

        // 检查是否有表的队列超过阈值
        bool needsImmediateWrite = false;
        for (var queue in _writeQueue.values) {
          if (queue.length >= _maxQueueSize) {
            needsImmediateWrite = true;
            break;
          }
        }

        // 3. 检查是否需要写入数据文件
        if (needsImmediateWrite || _idleCount >= _idleWriteCount) {
          _idleCount = 0;
          if (_writeQueue.isNotEmpty) {
            _isWriting = true;
            try {
              await flushWriteQueue();
              // 处理自增ID写入
              await _dataStore.flushMaxIds();
            } finally {
              _isWriting = false;
            }
          }
        } else {
          _idleCount++;
        }
      } catch (e) {
        Logger.error('定时处理失败: $e', label: 'FileManager-startTimer');
        _isWriting = false;
      }
    });
  }

  /// 停止定时器
  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;

    // 最后一次刷新所有待写入数据
    if (_writeQueue.isNotEmpty) {
      // 先备份
      final currentQueue =
          Map<String, List<Map<String, dynamic>>>.from(_writeQueue);
      await _backupWriteQueue(currentQueue);
      // 再写入
      await flushWriteQueue();
    }
    // 清理所有备份文件
    await _cleanupBackupFiles();
    // 清理文件大小信息
    clearFileSizes();
    // 清理写入队列
    _writeQueue.clear();
  }

  /// 刷新写入队列
  Future<void> flushWriteQueue() async {
    if (_writeQueue.isEmpty) return;

    // 复制当前队列,避免处理过程中的修改
    final currentQueue =
        Map<String, List<Map<String, dynamic>>>.from(_writeQueue);

    try {
      for (var entry in currentQueue.entries) {
        final tableName = entry.key;
        final records = entry.value;
        if (records.isEmpty) continue;

        // 获取数据文件写入锁
        await _dataStore.concurrencyManager?.acquireWriteLock(tableName);
        try {
          final schema = await _dataStore.getTableSchema(tableName);
          final dataFile =
              File(_dataStore.config.getDataPath(tableName, schema.isGlobal));
          if (!await dataFile.exists()) continue;

          final primaryKey = schema.primaryKey;
          final allRecords = <String, Map<String, dynamic>>{};

          // 1. 读取现有文件内容
          final lines = await dataFile.readAsLines();

          // 2. 使用 Map 来存储记录，以主键为键，确保唯一性
          for (var line in lines) {
            if (line.trim().isEmpty) continue;
            try {
              final record = jsonDecode(line) as Map<String, dynamic>;
              allRecords[record[primaryKey].toString()] = record;
            } catch (e) {
              Logger.error('解析记录失败: $e', label: 'DataStore-_flushWriteQueue');
            }
          }

          // 3. 更新/添加新记录并处理索引
          for (var record in records) {
            final recordId = record[primaryKey].toString();
            final oldRecord = allRecords[recordId];

            // 3.1 如果是更新操作，先删除旧索引
            if (oldRecord != null) {
              await _dataStore.indexManager
                  ?.deleteFromIndexes(tableName, oldRecord);
            }

            // 3.2 更新记录
            allRecords[recordId] = record;
          }

          // 5. 写入所有记录
          final sink = dataFile.openWrite(mode: FileMode.write);
          var currentOffset = 0; // 从0开始计算偏移量

          try {
            for (var record in allRecords.values) {
              final encoded = jsonEncode(record);

              // 创建行指针（使用当前偏移量）
              final pointer = await RowPointer.create(
                encoded,
                currentOffset,
              );

              // 写入记录
              sink.writeln(encoded);

              // 更新索引
              _dataStore.indexManager
                  ?.updateIndexes(tableName, record, pointer);

              // 更新偏移量（加上记录长度和换行符）
              currentOffset += encoded.length + 1;
            }
            await sink.flush();
          } finally {
            await sink.close();
          }

          // 更新文件大小信息
          await updateFileSize(tableName, currentOffset);

          // 写入成功后再清除对应表的待写入队列
          _writeQueue.remove(tableName);

          // 删除该表的备份文件(需要获取备份锁)
          if (!_isBackingUp) {
            // 如果没有正在进行的备份操作
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
    } catch (e, stackTrace) {
      Logger.error('写入队列刷新失败: $e', label: 'FileManager-flushWriteQueue');
      Logger.error(stackTrace.toString(), label: 'FileManager-flushWriteQueue');
      // 发生错误时恢复所有备份
      await _restoreAllBackups();
    }
  }

  /// 备份待写入队列
  Future<void> _backupWriteQueue(
      Map<String, List<Map<String, dynamic>>> queue) async {
    if (_isBackingUp) return;

    try {
      _isBackingUp = true;
      final needBackupBeforeStart = _isNeedBackup; // 记录开始备份时的状态

      for (var entry in queue.entries) {
        final tableName = entry.key;
        await _dataStore.concurrencyManager
            ?.acquireWriteLock('backup_$tableName');
        try {
          final schema = await _dataStore.getTableSchema(tableName);
          final backupFile = File(
              '${_dataStore.config.getTablePath(tableName, schema.isGlobal)}.write.bak');
          await backupFile.writeAsString(jsonEncode(entry.value));
        } finally {
          await _dataStore.concurrencyManager
              ?.releaseWriteLock('backup_$tableName');
        }
      }

      // 只有当开始备份时需要备份的标记为true时,才重置标记
      // 这样可以保留备份过程中新添加数据的备份需求
      if (needBackupBeforeStart) {
        _isNeedBackup = false;
      }
    } finally {
      _isBackingUp = false;
    }
  }

  /// 从备份恢复单个表的写入队列
  Future<void> _restoreFromBackup(String tableName) async {
    final schema = await _dataStore.getTableSchema(tableName);
    final backupFile = File(
        '${_dataStore.config.getTablePath(tableName, schema.isGlobal)}.write.bak');
    if (await backupFile.exists()) {
      try {
        final content = await backupFile.readAsString();
        final records =
            (jsonDecode(content) as List).cast<Map<String, dynamic>>();
        _writeQueue[tableName] = records;
      } catch (e) {
        Logger.error('恢复写入队列备份失败: $e', label: 'FileManager._restoreFromBackup');
      }
    }
  }

  /// 恢复所有备份
  Future<void> _restoreAllBackups() async {
    final basePath = _dataStore.config.getBasePath();
    final dir = Directory(basePath);
    if (!await dir.exists()) return;

    await for (var entity in dir.list(recursive: true)) {
      if (entity is File && entity.path.endsWith('.write.bak')) {
        final tableName = _getTableNameFromPath(entity.path);
        await _restoreFromBackup(tableName);
      }
    }
  }

  /// 删除备份文件
  Future<void> _removeBackupFile(String tableName) async {
    final schema = await _dataStore.getTableSchema(tableName);
    final backupFile = File(
        '${_dataStore.config.getTablePath(tableName, schema.isGlobal)}.write.bak');
    if (await backupFile.exists()) {
      await backupFile.delete();
    }
  }

  /// 从路径中提取表名
  String _getTableNameFromPath(String path) {
    final fileName = path.split(Platform.pathSeparator).last;
    return fileName.split('.').first;
  }

  /// 清理所有备份文件
  Future<void> _cleanupBackupFiles() async {
    final basePath = _dataStore.config.getBasePath();
    final dir = Directory(basePath);
    if (!await dir.exists()) return;

    await for (var entity in dir.list(recursive: true)) {
      if (entity is File && entity.path.endsWith('.write.bak')) {
        await entity.delete();
      }
    }
  }

  /// 获取表文件大小
  int getFileSize(String tableName) {
    return _fileSizes[tableName] ?? 0;
  }

  /// 更新表文件大小和修改时间
  Future<void> updateFileSize(String tableName, int size) async {
    _fileSizes[tableName] = size;
    _lastModifiedTimes[tableName] = DateTime.now();
  }

  /// 检查是否允许全表缓存
  bool allowFullTableCache(String tableName, int maxSize) {
    final size = getFileSize(tableName);
    return size <= maxSize;
  }

  /// 检查文件是否被修改过
  bool isFileModified(String tableName, DateTime lastReadTime) {
    final lastModified = _lastModifiedTimes[tableName];
    return lastModified == null || lastModified.isAfter(lastReadTime);
  }

  /// 获取文件最后修改时间
  DateTime? getLastModifiedTime(String tableName) {
    return _lastModifiedTimes[tableName];
  }

  /// 清理表大小信息
  void clearFileSizes() {
    _fileSizes.clear();
    _lastModifiedTimes.clear();
  }

  /// 初始化时加载备份
  Future<void> loadBackups() async {
    try {
      final basePath = _dataStore.config.getBasePath();
      final dir = Directory(basePath);
      if (!await dir.exists()) return;

      await for (var entity in dir.list(recursive: true)) {
        if (entity is File && entity.path.endsWith('.write.bak')) {
          final tableName = _getTableNameFromPath(entity.path);
          await _restoreFromBackup(tableName);
        }
      }
    } catch (e) {
      Logger.error('加载备份失败: $e', label: 'FileManager.loadBackups');
    }
  }

  /// 获取表的所有文件
  Future<List<File>> getTableFiles(String tableName) async {
    final tablePath = await _dataStore.getTablePath(tableName);
    final files = <File>[];

    // 数据文件
    files.add(File('$tablePath.dat'));
    // Schema文件
    files.add(File('$tablePath.schema'));
    // 索引文件
    final dir = Directory(tablePath).parent;
    await for (var entity in dir.list()) {
      if (entity is File &&
          entity.path.startsWith('$tablePath.') &&
          entity.path.endsWith('.idx')) {
        files.add(entity);
      }
    }
    return files;
  }
}
