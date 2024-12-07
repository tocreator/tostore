import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/data_compressor.dart';

/// 备份文件
class BackupFile {
  final String path;
  final DateTime timestamp;
  final Map<String, BackupFileEntry> entries;
  final String checksum;

  BackupFile({
    required this.path,
    required this.timestamp,
    required this.entries,
    required this.checksum,
  });

  /// 查找文件
  BackupFileEntry? findFile(String name) {
    return entries[name];
  }

  /// 从备份文件加载
  static Future<BackupFile> fromFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw FileSystemException('Backup file not found', path);
    }

    final compressor = DataCompressor();
    final compressed = await file.readAsBytes();
    final decompressed = compressor.decompress(compressed);

    // 解析备份文件格式
    final backupData = _parseBackupData(decompressed);
    final entries = <String, BackupFileEntry>{};

    for (var entry in backupData.entries) {
      entries[entry.key] = BackupFileEntry(
        name: entry.key,
        content: entry.value['content'] as List<int>,
        lastModified: DateTime.fromMillisecondsSinceEpoch(
          entry.value['lastModified'] as int,
        ),
      );
    }

    // 解析时间戳
    final timestamp = DateTime.parse(
      path.split('_').last.split('.').first,
    );

    // 读取校验和
    final checksumFile = File('$path.checksum');
    final checksum =
        await checksumFile.exists() ? await checksumFile.readAsString() : '';

    return BackupFile(
      path: path,
      timestamp: timestamp,
      entries: entries,
      checksum: checksum,
    );
  }

  /// 获取备份大小
  Future<int> get size async {
    final file = File(path);
    return await file.length();
  }

  /// 验证完整性
  Future<bool> verifyIntegrity() async {
    if (checksum.isEmpty) return true;

    final file = File(path);
    final content = await file.readAsBytes();
    final compressor = DataCompressor();
    final actualChecksum = compressor.calculateChecksum(content).toString();
    return actualChecksum == checksum;
  }

  /// 解析备份数据
  static Map<String, Map<String, dynamic>> _parseBackupData(Uint8List data) {
    final content = utf8.decode(data);
    final Map<String, dynamic> json = jsonDecode(content);

    final result = <String, Map<String, dynamic>>{};
    for (var entry in json.entries) {
      result[entry.key] = Map<String, dynamic>.from(entry.value as Map);
    }

    return result;
  }

  /// 序列化为备份数据
  Future<Uint8List> serialize() async {
    final data = <String, Map<String, dynamic>>{};

    for (var entry in entries.entries) {
      data[entry.key] = {
        'content': entry.value.content,
        'lastModified': entry.value.lastModified.millisecondsSinceEpoch,
      };
    }

    final json = jsonEncode(data);
    return Uint8List.fromList(utf8.encode(json));
  }
}

/// 备份文件条目
class BackupFileEntry {
  final String name;
  final List<int> content;
  final DateTime lastModified;

  BackupFileEntry({
    required this.name,
    required this.content,
    required this.lastModified,
  });

  /// 获取条目大小
  int get size => content.length;

  /// 获取内容的校验和
  int getChecksum() {
    final compressor = DataCompressor();
    return compressor.calculateChecksum(Uint8List.fromList(content));
  }

  /// 验证内容完整性
  bool verifyContent(int expectedChecksum) {
    return getChecksum() == expectedChecksum;
  }
}
