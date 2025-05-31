import 'dart:async';
import 'dart:typed_data';
import 'storage_interface.dart';

/// Stub implementation for web platform - will never be used on web
class FileStorageImpl implements StorageInterface {
  FileStorageImpl() {
    throw UnsupportedError('FileStorageImpl is not supported on Web platform');
  }

  @override
  Future<void> close() async {
    throw UnsupportedError('FileStorageImpl is not supported on Web platform');
  }

  @override
  Future<void> deleteFile(String path) async {
    throw UnsupportedError('FileStorageImpl is not supported on Web platform');
  }

  @override
  Future<void> deleteDirectory(String path) async {
    throw UnsupportedError('FileStorageImpl is not supported on Web platform');
  }

  @override
  Future<bool> existsDirectory(String path) async {
    throw UnsupportedError('FileStorageImpl is not supported on Web platform');
  }

  @override
  Future<bool> existsFile(String path) async {
    throw UnsupportedError('FileStorageImpl is not supported on Web platform');
  }

  @override
  Future<DateTime?> getFileCreationTime(String path) async {
    throw UnsupportedError('FileStorageImpl is not supported on Web platform');
  }

  @override
  Future<List<String>> listDirectory(String path,
      {bool recursive = false}) async {
    throw UnsupportedError('FileStorageImpl is not supported on Web platform');
  }

  @override
  Future<Uint8List> readAsBytes(String path) async {
    throw UnsupportedError('FileStorageImpl is not supported on Web platform');
  }

  @override
  Future<String?> readAsString(String path) async {
    throw UnsupportedError('FileStorageImpl is not supported on Web platform');
  }

  @override
  Future<void> writeAsBytes(String path, Uint8List bytes) async {
    throw UnsupportedError('FileStorageImpl is not supported on Web platform');
  }

  @override
  Future<void> writeAsString(String path, String content,
      {bool append = false}) async {
    throw UnsupportedError('FileStorageImpl is not supported on Web platform');
  }

  @override
  Future<DateTime?> getFileModifiedTime(String path) async {
    throw UnsupportedError('FileStorageImpl is not supported on Web platform');
  }

  @override
  Future<int> getFileSize(String path) async {
    throw UnsupportedError('FileStorageImpl is not supported on Web platform');
  }

  @override
  Future<void> copyDirectory(String sourcePath, String destinationPath) async {
    throw UnsupportedError('FileStorageImpl is not supported on Web platform');
  }

  @override
  Future<void> copyFile(String sourcePath, String destinationPath) async {
    throw UnsupportedError('FileStorageImpl is not supported on Web platform');
  }

  @override
  Stream<String> readLinesStream(String path, {int offset = 0}) async* {
    throw UnsupportedError('FileStorageImpl is not supported on Web platform');
  }

  @override
  Future<void> writeLinesStream(String path, Stream<String> lines,
      {bool append = false}) async {
    throw UnsupportedError('FileStorageImpl is not supported on Web platform');
  }

  @override
  Future<void> ensureDirectoryExists(String path) async {
    throw UnsupportedError('FileStorageImpl is not supported on Web platform');
  }
}
