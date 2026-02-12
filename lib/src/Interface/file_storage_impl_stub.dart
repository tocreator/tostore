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
  Future<Uint8List> readAsBytesAt(String path, int start, {int? length}) async {
    throw UnsupportedError('FileStorageImpl is not supported on Web platform');
  }

  @override
  Future<void> writeAsBytesAt(String path, int start, Uint8List bytes,
      {bool flush = true, bool closeHandleAfterFlush = false}) async {
    throw UnsupportedError('FileStorageImpl is not supported on Web platform');
  }

  @override
  Future<void> writeManyAsBytesAt(String path, List<ByteWrite> writes,
      {bool flush = true, bool closeHandleAfterFlush = false}) async {
    throw UnsupportedError('FileStorageImpl is not supported on Web platform');
  }

  @override
  Future<String?> readAsString(String path) async {
    throw UnsupportedError('FileStorageImpl is not supported on Web platform');
  }

  @override
  Future<void> writeAsBytes(String path, Uint8List bytes,
      {bool flush = true, bool closeHandleAfterFlush = false}) async {
    throw UnsupportedError('FileStorageImpl is not supported on Web platform');
  }

  @override
  Future<void> writeAsString(String path, String content,
      {bool append = false,
      bool flush = true,
      bool closeHandleAfterFlush = false}) async {
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

  @override
  Future<int> appendBytes(String path, Uint8List bytes,
      {bool flush = true, bool closeHandleAfterFlush = false}) async {
    throw UnsupportedError('FileStorageImpl is not supported on Web platform');
  }

  @override
  Future<int> appendString(String path, String content,
      {bool flush = true, bool closeHandleAfterFlush = false}) async {
    throw UnsupportedError('FileStorageImpl is not supported on Web platform');
  }

  @override
  Future<List<String>> readAsLines(String path, {int offset = 0}) async {
    throw UnsupportedError('FileStorageImpl is not supported on Web platform');
  }

  @override
  Future<void> flushFile(String path) async {
    throw UnsupportedError('FileStorageImpl is not supported on Web platform');
  }

  @override
  Future<void> flushAll(
      {String? path, List<String>? paths, bool closeHandles = false}) async {
    throw UnsupportedError('FileStorageImpl is not supported on Web platform');
  }

  @override
  Future<void> configureStorage({int? maxOpenHandles}) async {
    throw UnsupportedError('FileStorageImpl is not supported on Web platform');
  }

  @override
  Future<void> replaceFileAtomic(String tempPath, String finalPath) async {
    throw UnsupportedError('FileStorageImpl is not supported on Web platform');
  }
}
