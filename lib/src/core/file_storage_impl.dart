import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import '../model/file_meta.dart';
import 'storage_interface.dart';
import '../handler/logger.dart';
import 'package:path/path.dart' as p;

/// File system storage implementation for native platforms
class FileStorageImpl implements StorageInterface {
  FileStorageImpl();

  @override
  Future<void> deleteFile(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      Logger.error('Delete file failed: $e', label: 'FileStorageImpl');
      rethrow;
    }
  }

  @override
  Future<bool> exists(String path) async {
    try {
      return await File(path).exists();
    } catch (e) {
      Logger.error('Check file exists failed: $e', label: 'FileStorageImpl');
      return false;
    }
  }

  @override
  Future<List<String>> listDirectory(String path) async {
    try {
      final dir = Directory(path);
      if (!await dir.exists()) return [];

      final files = <String>[];
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) {
          files.add(entity.path);
        }
      }
      return files;
    } catch (e) {
      Logger.error('List directory failed: $e', label: 'FileStorageImpl');
      return [];
    }
  }

  @override
  Future<void> close() async {
    // No resources to clean up for file system implementation,only for web
  }

  @override
  Future<void> writeAsString(String path, String content,
      {bool append = false}) async {
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      if (append) {
        await file.writeAsString(content, mode: FileMode.append);
      } else {
        await file.writeAsString(content);
      }
    } catch (e) {
      Logger.error('Write string failed: $e', label: 'FileStorageImpl');
      rethrow;
    }
  }

  @override
  Future<void> writeLines(String path, List<String> lines) async {
    try {
      final file = File(path);
      await file.parent.create(recursive: true);

      final sink = file.openWrite(mode: FileMode.write);
      try {
        for (final line in lines) {
          sink.writeln(line);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
    } catch (e) {
      Logger.error('Write lines failed: $e', label: 'FileStorageImpl');
      rethrow;
    }
  }

  @override
  Future<String?> readAsString(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (e) {
      Logger.error('Read string failed: $e', label: 'FileStorageImpl');
      return null;
    }
  }

  @override
  Future<List<String>> readLines(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return [];

      final lines = <String>[];
      final stream = file
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in stream) {
        lines.add(line);
      }

      return lines;
    } catch (e) {
      Logger.error('Read lines failed: $e', label: 'FileStorageImpl');
      return [];
    }
  }

  @override
  Future<DateTime?> getFileCreationTime(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;

      final stat = await file.stat();
      return stat.modified;
    } catch (e) {
      Logger.error('Get file creation time failed: $e',
          label: 'FileStorageImpl');
      return null;
    }
  }

  @override
  Future<Uint8List> readAsBytes(String path) async {
    final file = File(path);
    if (!await file.exists()) return Uint8List(0);
    return await file.readAsBytes();
  }

  @override
  Future<FileMeta?> getFileMeta(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;

    final stat = await file.stat();
    final lines = await readLines(path);
    if (lines.isEmpty) return null;

    return FileMeta(
      name: path,
      version: 1,
      type: _getFileType(path),
      size: await file.length(),
      records: lines.length,
      timestamps: Timestamps(
        created: stat.accessed,
        modified: stat.modified,
        accessed: stat.accessed,
      ),
      chunks: null, // file is not chunked
    );
  }

  String _getFileType(String path) {
    final ext = p.extension(path).replaceFirst('.', '');
    if (ext == 'dat') return 'data';
    if (ext == 'schema') return 'schema';
    return 'other';
  }

  @override
  Future<int> getFileSize(String path) async {
    final file = File(path);
    if (!await file.exists()) return 0;
    return await file.length();
  }

  @override
  Future<int> getFileRecordCount(String path) async {
    final lines = await readLines(path);
    return lines.length;
  }

  @override
  Future<DateTime?> getFileModifiedTime(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    return await file.lastModified();
  }

  @override
  Future<DateTime?> getFileAccessedTime(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    return await file.lastAccessed();
  }
}
