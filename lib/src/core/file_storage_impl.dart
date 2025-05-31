import 'dart:async';
import 'dart:io' if (dart.library.html) '../Interface/io_stub.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:tostore/src/handler/common.dart';

import '../Interface/storage_interface.dart';
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
  Future<void> deleteDirectory(String path) async {
    try {
      final directory = Directory(path);
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } catch (e) {
      Logger.error('Delete directory failed: $e', label: 'FileStorageImpl');
      rethrow;
    }
  }

  /// Check if a directory exists at the specified path
  @override
  Future<bool> existsDirectory(String path) async {
    try {
      return await Directory(path).exists();
    } catch (e) {
      Logger.error('Check directory exists failed: $e',
          label: 'FileStorageImpl');
      return false;
    }
  }

  /// Check if a file exists at the specified path
  @override
  Future<bool> existsFile(String path) async {
    try {
      return await File(path).exists();
    } catch (e) {
      Logger.error('Check file exists failed: $e', label: 'FileStorageImpl');
      return false;
    }
  }

  @override
  Future<List<String>> listDirectory(String path,
      {bool recursive = false}) async {
    try {
      final dir = Directory(path);
      if (!await dir.exists()) return [];

      final entries = <String>[];
      await for (final entity in dir.list(recursive: recursive)) {
        if (recursive) {
          if (entity is File) {
            entries.add(entity.path);
          }
        } else {
          entries.add(entity.path);
        }
      }
      return entries;
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
  Future<void> writeAsBytes(String path, Uint8List bytes) async {
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
    } catch (e) {
      Logger.error('Write bytes failed: $e', label: 'FileStorageImpl');
      rethrow;
    }
  }

  @override
  Future<Uint8List> readAsBytes(String path) async {
    final file = File(path);
    if (!await file.exists()) return Uint8List(0);
    return await file.readAsBytes();
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
  Future<int> getFileSize(String path) async {
    final file = File(path);
    if (!await file.exists()) return 0;
    return await file.length();
  }

  @override
  Future<DateTime?> getFileModifiedTime(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    return await file.lastModified();
  }

  @override
  Future<void> copyDirectory(String sourcePath, String destinationPath) async {
    try {
      final sourceDir = Directory(sourcePath);
      final destDir = Directory(destinationPath);
      if (await destDir.exists()) {
        await destDir.delete(recursive: true);
      }
      await destDir.create(recursive: true);
      await for (final entity in sourceDir.list(recursive: true)) {
        if (entity is File) {
          final relativePath = entity.path.substring(sourcePath.length);
          final newPath = pathJoin(destinationPath, relativePath);
          await Directory(p.dirname(newPath)).create(recursive: true);
          await entity.copy(newPath);
        } else if (entity is Directory) {
          final relativePath = entity.path.substring(sourcePath.length);
          final newDirPath = pathJoin(destinationPath, relativePath);
          await Directory(newDirPath).create(recursive: true);
        }
      }
    } catch (e) {
      Logger.error('Copy directory failed: $e',
          label: 'FileStorageImpl.copyDirectory');
      rethrow;
    }
  }

  @override
  Future<void> copyFile(String sourcePath, String destinationPath) async {
    try {
      final srcFile = File(sourcePath);
      if (!await srcFile.exists()) {
        Logger.error('Source file does not exist',
            label: 'FileStorageImpl.copyFile');
        return;
      }
      final destDir = Directory(p.dirname(destinationPath));
      await destDir.create(recursive: true);
      await srcFile.copy(destinationPath);
    } catch (e) {
      Logger.error('Copy file failed: $e', label: 'FileStorageImpl.copyFile');
      rethrow;
    }
  }

  @override
  Stream<String> readLinesStream(String path, {int offset = 0}) {
    final controller = StreamController<String>();

    File(path)
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .skip(offset)
        .listen(
          (line) => controller.add(line),
          onError: (e) {
            Logger.error('Read lines stream failed: $e',
                label: 'FileStorageImpl');
            controller.addError(e);
          },
          onDone: () => controller.close(),
        );

    return controller.stream;
  }

  @override
  Future<void> writeLinesStream(String path, Stream<String> lines,
      {bool append = false}) async {
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      final sink =
          file.openWrite(mode: append ? FileMode.append : FileMode.write);

      try {
        await for (final line in lines) {
          sink.writeln(line);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
    } catch (e) {
      Logger.error('Write lines stream failed: $e', label: 'FileStorageImpl');
      rethrow;
    }
  }

  /// Creates directory if it doesn't already exist
  @override
  Future<void> ensureDirectoryExists(String path) async {
    try {
      final directory = Directory(path);
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
    } catch (e) {
      Logger.error('Ensure directory exists failed: $e',
          label: 'FileStorageImpl.ensureDirectoryExists');
      rethrow;
    }
  }
}
