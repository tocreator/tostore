import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../handler/logger.dart';
import '../core/data_compressor.dart';
import '../core/data_store_impl.dart';

import '../model/table_schema.dart';
import 'backup_info.dart';

/// 备份管理器
class BackupManager {
  final DataStoreImpl _dataStore;
  final DataCompressor _compressor;

  BackupManager(this._dataStore)
      : _compressor = DataCompressor(
            compressionLevel: _dataStore.config.compressionLevel);

  /// 从路径中提取文件名
  String _getFileName(String path) {
    final normalizedPath = path.replaceAll('\\', '/');
    final parts = normalizedPath.split('/');
    return parts.last.replaceAll('.dat', '');
  }

  /// 创建备份
  Future<String> createBackup() async {
    final timestamp = DateTime.now().toIso8601String();
    final backupPath = _dataStore.config.getBackupPath();
    final backupFile = File('$backupPath/backup_$timestamp.bak');

    // 创建备份目录
    await Directory(backupPath).create(recursive: true);

    // 收集基础空间和公共路径的数据
    final allData = <String, Map<String, dynamic>>{};

    // 1. 收集基础空间路径数据
    final basePath = _dataStore.config.getBasePath();
    await _collectPathData(basePath, allData);

    // 2. 收集全局路径数据
    final globalPath = _dataStore.config.getGlobalPath();
    await _collectPathData(globalPath, allData);

    // 创建备份数据结构
    final backupData = {
      'timestamp': timestamp,
      'data': allData,
      'checksum': '', // 先留空，后面计算
    };

    // 序列化并压缩数据
    final serialized = jsonEncode(backupData);
    final compressed = _compressor.compress(
      Uint8List.fromList(utf8.encode(serialized)),
    );

    // 计算校验和
    final checksum = _compressor.calculateChecksum(compressed);
    backupData['checksum'] = checksum.toString();

    // 重新序列化并压缩（现在包含校验和）
    final finalSerialized = jsonEncode(backupData);
    final finalCompressed = _compressor.compress(
      Uint8List.fromList(utf8.encode(finalSerialized)),
    );

    // 写入备份文件
    await backupFile.writeAsBytes(finalCompressed);

    return backupFile.path;
  }

  /// 收集指定路径下的数据
  Future<void> _collectPathData(
      String path, Map<String, Map<String, dynamic>> allData) async {
    final dir = Directory(path);
    if (!await dir.exists()) return;

    await for (var entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.dat')) {
        final tablePath = entity.path.replaceAll('.dat', '');
        final tableName = _getFileName(tablePath);

        // 读取数据文件
        final lines = await entity.readAsLines();
        final tableData = <String, dynamic>{};

        // 读取表结构
        final schema = await _dataStore.getTableSchema(tableName);
        tableData['schema'] = schema;

        // 读取表数据
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

  /// 加载备份
  Future<Map<String, dynamic>> loadBackup(String backupPath) async {
    final backupFile = File(backupPath);
    if (!await backupFile.exists()) {
      throw FileSystemException('备份文件不存在', backupPath);
    }

    // 读取并解压数据
    final compressed = await backupFile.readAsBytes();
    final decompressed = _compressor.decompress(compressed);

    // 解析数据
    final decoded = utf8.decode(decompressed);
    final backupData = jsonDecode(decoded) as Map<String, dynamic>;

    // 验证数据结构
    if (!backupData.containsKey('timestamp') ||
        !backupData.containsKey('data') ||
        !backupData.containsKey('checksum')) {
      Logger.error('备份数据结构无效', label: 'BackupManager.loadBackup');
      throw const FormatException('无效的备份文件格式');
    }

    return backupData;
  }

  /// 列出所有备份
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
          // 跳过无效的备份文件
          Logger.error('跳过无效的备份文件: ${entity.path}, 错误: $e',
              label: 'BackupManager.listBackups');
          continue;
        }
      }
    }

    // 按时间排序
    backups.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return backups;
  }

  /// 从备份恢复
  Future<void> restore(String backupPath) async {
    try {
      // 加载备份数据
      final backupData = await loadBackup(backupPath);
      final data = backupData['data'] as Map<String, dynamic>;

      // 清理现有数据
      final dbDir = Directory(_dataStore.config.getBasePath());
      if (await dbDir.exists()) {
        await dbDir.delete(recursive: true);
      }
      await dbDir.create(recursive: true);

      // 恢复每个表的数据
      for (var entry in data.entries) {
        final tableName = entry.key;
        final tableData = entry.value as Map<String, dynamic>;

        // 恢复表结构
        final schema = TableSchema.fromJson(tableData['schema']);
        await _dataStore.createTable(tableName, schema);

        // 恢复表数据
        final records = tableData['data'] as List<dynamic>;
        for (var record in records) {
          await _dataStore.insert(tableName, record as Map<String, dynamic>);
        }

        Logger.info('表 $tableName 恢复完成');
      }

      Logger.info('数据库恢复完成');
    } catch (e) {
      Logger.error('从备份恢复失败: $e', label: 'BackupManager.restore');
      rethrow;
    }
  }

  /// 验证备份完整性
  Future<bool> verifyBackup(String backupPath) async {
    try {
      final backupData = await loadBackup(backupPath);
      final storedChecksum = backupData['checksum'] as String;

      // 验证校验和
      if (storedChecksum.isNotEmpty) {
        final file = File(backupPath);
        final content = await file.readAsBytes();
        final actualChecksum =
            _compressor.calculateChecksum(content).toString();
        if (actualChecksum != storedChecksum) {
          Logger.debug('校验和不匹配');
          return false;
        }
      }

      // 验证数据完整性
      final data = backupData['data'] as Map<String, dynamic>;
      for (var tableData in data.values) {
        if (tableData == null || tableData is! Map<String, dynamic>) {
          Logger.debug('表数据格式无效');
          return false;
        }

        // 验证表结构
        if (!tableData.containsKey('schema')) {
          Logger.debug('缺少表结构定义');
          return false;
        }

        // 验证表数据
        if (!tableData.containsKey('data') || tableData['data'] is! List) {
          Logger.debug('表数据格式无效');
          return false;
        }
      }

      return true;
    } catch (e) {
      Logger.error('验证备份失败: $e', label: 'BackupManager.verifyBackup');
      return false;
    }
  }
}

/// 文件变更记录
class FileChange {
  final String filePath;
  final DateTime modifiedTime;

  FileChange({
    required this.filePath,
    required this.modifiedTime,
  });
}
