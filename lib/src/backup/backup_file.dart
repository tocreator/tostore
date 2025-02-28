import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/data_compressor.dart';
import '../core/data_store_impl.dart';

/// backup file
class BackupFile {
  final DataStoreImpl _dataStore;
  final String path;
  final DateTime timestamp;
  final Map<String, BackupFileEntry> entries;
  final String checksum;

  BackupFile(
    this._dataStore, {
    required this.path,
    required this.timestamp,
    required this.entries,
    required this.checksum,
  });

  /// find file
  BackupFileEntry? findF2ile(String name) {
    return entries[name];
  }

  /// load from backup file
  Future<BackupFile> fromFile(String path) async {
    if (!await _dataStore.storage.exists(path)) {
      throw FileSystemException('Backup file not found', path);
    }

    final compressor = DataCompressor();
    final compressed = await _dataStore.storage.readAsBytes(path);
    final decompressed = compressor.decompress(compressed);

    // parse backup file format
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

    // parse timestamp
    final timestamp = DateTime.parse(
      path.split('_').last.split('.').first,
    );

    // read checksum
    String checksum = '';
    if (kIsWeb) {
      final checksumPath = '$path.checksum';
      if (await _dataStore.storage.exists(checksumPath)) {
        checksum = await _dataStore.storage.readAsString(checksumPath) ?? '';
      }
    } else {
      final checksumFile = File('$path.checksum');
      checksum =
          await checksumFile.exists() ? await checksumFile.readAsString() : '';
    }

    return BackupFile(
      _dataStore,
      path: path,
      timestamp: timestamp,
      entries: entries,
      checksum: checksum,
    );
  }

  /// get backup file size
  Future<int> get size async {
    int fileSize = 0;
    if (kIsWeb) {
      if (await _dataStore.storage.exists(path)) {
        final content = await _dataStore.storage.readAsString(path);
        fileSize = content?.length ?? 0;
      }
    } else {
      final file = File(path);
      if (await file.exists()) {
        fileSize = await file.length();
      }
    }
    return fileSize;
  }

  /// verify integrity
  Future<bool> verifyIntegrity() async {
    if (checksum.isEmpty) return true;

    if (!await _dataStore.storage.exists(path)) {
      return false;
    }

    final content = await _dataStore.storage.readAsString(path);
    if (content == null) return false;

    final compressor = DataCompressor();
    final actualChecksum = compressor
        .calculateChecksum(
          Uint8List.fromList(content.codeUnits),
        )
        .toString();
    return actualChecksum == checksum;
  }

  /// parse backup data
  Map<String, Map<String, dynamic>> _parseBackupData(Uint8List data) {
    final content = utf8.decode(data);
    final Map<String, dynamic> json = jsonDecode(content);

    final result = <String, Map<String, dynamic>>{};
    for (var entry in json.entries) {
      result[entry.key] = Map<String, dynamic>.from(entry.value as Map);
    }

    return result;
  }

  /// serialize to backup data
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

/// backup file entry
class BackupFileEntry {
  final String name;
  final List<int> content;
  final DateTime lastModified;

  BackupFileEntry({
    required this.name,
    required this.content,
    required this.lastModified,
  });

  /// get entry size
  int get size => content.length;

  /// get content checksum
  int getChecksum() {
    final compressor = DataCompressor();
    return compressor.calculateChecksum(Uint8List.fromList(content));
  }

  /// verify content integrity
  bool verifyContent(int expectedChecksum) {
    return getChecksum() == expectedChecksum;
  }
}
