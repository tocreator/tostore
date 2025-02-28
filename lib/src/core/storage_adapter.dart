import 'package:flutter/foundation.dart';
import '../model/data_store_config.dart';
import '../model/file_meta.dart';
import 'file_storage_impl.dart';
import 'storage_interface.dart';
import 'web_storage_impl.dart'
    if (dart.library.io) 'web_storage_impl_stub.dart';

/// Storage adapter to handle platform-specific storage implementations
class StorageAdapter implements StorageInterface {
  late final StorageInterface _storage;

  StorageAdapter(DataStoreConfig config) {
    if (kIsWeb) {
      _storage = WebStorageImpl('tostore_db');
    } else {
      _storage = FileStorageImpl();
    }
  }

  @override
  Future<void> writeAsString(String path, String content,
          {bool append = false}) =>
      _storage.writeAsString(path, content, append: append);

  @override
  Future<String?> readAsString(String path) => _storage.readAsString(path);

  @override
  Future<void> deleteFile(String path) => _storage.deleteFile(path);

  @override
  Future<bool> exists(String path) => _storage.exists(path);

  @override
  Future<List<String>> listDirectory(String path) =>
      _storage.listDirectory(path);

  @override
  Future<void> close() => _storage.close();

  @override
  Future<List<String>> readLines(String path) => _storage.readLines(path);

  @override
  Future<void> writeLines(String path, List<String> lines) =>
      _storage.writeLines(path, lines);

  @override
  Future<DateTime?> getFileCreationTime(String path) async {
    return _storage.getFileCreationTime(path);
  }

  @override
  Future<Uint8List> readAsBytes(String path) async {
    return _storage.readAsBytes(path);
  }

  @override
  Future<DateTime?> getFileModifiedTime(String path) async {
    return _storage.getFileModifiedTime(path);
  }

  @override
  Future<DateTime?> getFileAccessedTime(String path) async {
    return _storage.getFileAccessedTime(path);
  }

  @override
  Future<int> getFileSize(String path) async {
    return _storage.getFileSize(path);
  }

  @override
  Future<int> getFileRecordCount(String path) async {
    return _storage.getFileRecordCount(path);
  }

  @override
  Future<FileMeta?> getFileMeta(String path) async {
    return _storage.getFileMeta(path);
  }
}
