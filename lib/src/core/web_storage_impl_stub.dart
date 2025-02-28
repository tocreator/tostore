import 'dart:async';
import 'dart:typed_data';
import '../model/file_meta.dart';
import 'storage_interface.dart';

/// not supported on web platform
class WebStorageImpl implements StorageInterface {
  WebStorageImpl(String dbName) {
    throw UnsupportedError('WebStorageImpl is only supported on Web platform');
  }

  @override
  Future<void> close() async {
    throw UnsupportedError('WebStorageImpl is only supported on Web platform');
  }

  @override
  Future<void> deleteFile(String path) async {
    throw UnsupportedError('WebStorageImpl is only supported on Web platform');
  }

  @override
  Future<bool> exists(String path) async {
    throw UnsupportedError('WebStorageImpl is only supported on Web platform');
  }

  @override
  Future<DateTime?> getFileCreationTime(String path) async {
    throw UnsupportedError('WebStorageImpl is only supported on Web platform');
  }

  @override
  Future<List<String>> listDirectory(String path) async {
    throw UnsupportedError('WebStorageImpl is only supported on Web platform');
  }

  @override
  Future<Uint8List> readAsBytes(String path) async {
    throw UnsupportedError('WebStorageImpl is only supported on Web platform');
  }

  @override
  Future<String?> readAsString(String path) async {
    throw UnsupportedError('WebStorageImpl is only supported on Web platform');
  }

  @override
  Future<List<String>> readLines(String path) async {
    throw UnsupportedError('WebStorageImpl is only supported on Web platform');
  }

  @override
  Future<void> writeAsString(String path, String content,
      {bool append = false}) async {
    throw UnsupportedError('WebStorageImpl is only supported on Web platform');
  }

  @override
  Future<void> writeLines(String path, List<String> lines) async {
    throw UnsupportedError('WebStorageImpl is only supported on Web platform');
  }

  @override
  Future<FileMeta?> getFileMeta(String path) async {
    throw UnsupportedError('WebStorageImpl is only supported on Web platform');
  }

  @override
  Future<DateTime?> getFileModifiedTime(String path) async {
    throw UnsupportedError('WebStorageImpl is only supported on Web platform');
  }

  @override
  Future<DateTime?> getFileAccessedTime(String path) async {
    throw UnsupportedError('WebStorageImpl is only supported on Web platform');
  }

  @override
  Future<int> getFileSize(String path) async {
    throw UnsupportedError('WebStorageImpl is only supported on Web platform');
  }

  @override
  Future<int> getFileRecordCount(String path) async {
    throw UnsupportedError('WebStorageImpl is only supported on Web platform');
  }
}
