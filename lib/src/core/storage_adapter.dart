import 'package:flutter/foundation.dart';
import '../model/data_store_config.dart';
import '../Interface/storage_interface.dart';
import 'lock_manager.dart';
import 'package:path/path.dart' as path;

// Import platform-specific implementations with conditional imports
import 'web_storage_impl.dart'
    if (dart.library.io) '../Interface/web_storage_impl_stub.dart';
import '../Interface/file_storage_impl_stub.dart'
    if (dart.library.io) 'file_storage_impl.dart';

/// Storage adapter to handle platform-specific storage implementations
class StorageAdapter implements StorageInterface {
  late final StorageInterface _storage;

  /// lock manager
  final LockManager _lockManager;

  /// operation prefix
  static const String _readOpPrefix = 'read-';
  static const String _writeOpPrefix = 'write-';
  static const String _listOpPrefix = 'list-';
  static const String _deleteOpPrefix = 'delete-';

  StorageAdapter(DataStoreConfig config)
      : _lockManager =
            LockManager(lockTimeout: 300000, enableDeadlockDetection: true) {
    if (kIsWeb) {
      _storage = WebStorageImpl('db');
    } else {
      _storage = FileStorageImpl();
    }
  }

  /// generate lock resource name for resource path\
  String _getLockResource(String filePath) {
    // normalize path, remove unnecessary separators
    final normalizedPath = path.normalize(filePath);

    // use hash to handle long path, avoid lock resource name too long
    if (normalizedPath.length > 128) {
      return 'path-${normalizedPath.hashCode}';
    }

    return 'path-$normalizedPath';
  }

  /// generate operation id
  String _generateOperationId(String prefix) {
    return '$prefix${DateTime.now().millisecondsSinceEpoch}';
  }

  @override
  Future<void> writeAsString(String path, String content,
      {bool append = false}) async {
    final resource = _getLockResource(path);
    final opId = _generateOperationId(_writeOpPrefix);

    try {
      // acquire exclusive lock
      await _lockManager.acquireExclusiveLock(resource, opId);

      // execute write operation
      await _storage.writeAsString(path, content, append: append);
    } finally {
      // ensure release lock
      _lockManager.releaseExclusiveLock(resource, opId);
    }
  }

  @override
  Future<void> writeAsBytes(String path, Uint8List bytes) async {
    final resource = _getLockResource(path);
    final opId = _generateOperationId(_writeOpPrefix);

    try {
      await _lockManager.acquireExclusiveLock(resource, opId);

      await _storage.writeAsBytes(path, bytes);
    } finally {
      _lockManager.releaseExclusiveLock(resource, opId);
    }
  }

  @override
  Future<String?> readAsString(String path) async {
    final resource = _getLockResource(path);
    final opId = _generateOperationId(_readOpPrefix);

    try {
      await _lockManager.acquireSharedLock(resource, opId);
      return await _storage.readAsString(path);
    } finally {
      _lockManager.releaseSharedLock(resource, opId);
    }
  }

  @override
  Future<void> deleteFile(String path) async {
    final resource = _getLockResource(path);
    final opId = _generateOperationId(_deleteOpPrefix);

    try {
      await _lockManager.acquireExclusiveLock(resource, opId);
      await _storage.deleteFile(path);
    } finally {
      _lockManager.releaseExclusiveLock(resource, opId);
    }
  }

  @override
  Future<bool> existsDirectory(String path) => _storage.existsDirectory(path);

  @override
  Future<bool> existsFile(String path) => _storage.existsFile(path);

  @override
  Future<List<String>> listDirectory(String path,
      {bool recursive = false}) async {
    final resource = _getLockResource(path);
    final opId = _generateOperationId(_listOpPrefix);

    try {
      await _lockManager.acquireSharedLock(resource, opId);
      return await _storage.listDirectory(path, recursive: recursive);
    } finally {
      _lockManager.releaseSharedLock(resource, opId);
    }
  }

  @override
  Future<void> close({bool isMigrationInstance = false}) async {
    if (!isMigrationInstance) {
      await _storage.close();
    }
    _lockManager.dispose();
  }

  @override
  Future<DateTime?> getFileCreationTime(String path) async {
    final resource = _getLockResource(path);
    final opId = _generateOperationId(_readOpPrefix);

    try {
      await _lockManager.acquireSharedLock(resource, opId);
      return await _storage.getFileCreationTime(path);
    } finally {
      _lockManager.releaseSharedLock(resource, opId);
    }
  }

  @override
  Future<Uint8List> readAsBytes(String path) async {
    final resource = _getLockResource(path);
    final opId = _generateOperationId(_readOpPrefix);

    try {
      await _lockManager.acquireSharedLock(resource, opId);
      return await _storage.readAsBytes(path);
    } finally {
      _lockManager.releaseSharedLock(resource, opId);
    }
  }

  @override
  Future<DateTime?> getFileModifiedTime(String path) async {
    final resource = _getLockResource(path);
    final opId = _generateOperationId(_readOpPrefix);

    try {
      await _lockManager.acquireSharedLock(resource, opId);

      return await _storage.getFileModifiedTime(path);
    } finally {
      _lockManager.releaseSharedLock(resource, opId);
    }
  }

  @override
  Future<int> getFileSize(String path) async {
    final resource = _getLockResource(path);
    final opId = _generateOperationId(_readOpPrefix);

    try {
      await _lockManager.acquireSharedLock(resource, opId);
      return await _storage.getFileSize(path);
    } finally {
      _lockManager.releaseSharedLock(resource, opId);
    }
  }

  @override
  Future<void> deleteDirectory(String path) async {
    final resource = _getLockResource(path);
    final opId = _generateOperationId(_deleteOpPrefix);

    try {
      await _lockManager.acquireExclusiveLock(resource, opId);

      await _storage.deleteDirectory(path);
    } finally {
      _lockManager.releaseExclusiveLock(resource, opId);
    }
  }

  @override
  Future<void> copyDirectory(String sourcePath, String destinationPath) async {
    final sourceResource = _getLockResource(sourcePath);
    final destResource = _getLockResource(destinationPath);
    final opId = _generateOperationId(_writeOpPrefix);

    try {
      await _lockManager.acquireSharedLock(sourceResource, '$opId-src');
      await _lockManager.acquireExclusiveLock(destResource, '$opId-dest');

      await _storage.copyDirectory(sourcePath, destinationPath);
    } finally {
      _lockManager.releaseExclusiveLock(destResource, '$opId-dest');
      _lockManager.releaseSharedLock(sourceResource, '$opId-src');
    }
  }

  @override
  Future<void> copyFile(String sourcePath, String destinationPath) async {
    final sourceResource = _getLockResource(sourcePath);
    final destResource = _getLockResource(destinationPath);
    final opId = _generateOperationId(_writeOpPrefix);

    try {
      await _lockManager.acquireSharedLock(sourceResource, '$opId-src');
      await _lockManager.acquireExclusiveLock(destResource, '$opId-dest');

      await _storage.copyFile(sourcePath, destinationPath);
    } finally {
      _lockManager.releaseExclusiveLock(destResource, '$opId-dest');
      _lockManager.releaseSharedLock(sourceResource, '$opId-src');
    }
  }

  @override
  Stream<String> readLinesStream(String path, {int offset = 0}) async* {
    final resource = _getLockResource(path);
    final opId = _generateOperationId(_readOpPrefix);

    try {
      await _lockManager.acquireSharedLock(resource, opId);

      final stream = _storage.readLinesStream(path, offset: offset);
      await for (final line in stream) {
        yield line;
      }
    } finally {
      _lockManager.releaseSharedLock(resource, opId);
    }
  }

  @override
  Future<void> writeLinesStream(String path, Stream<String> lines,
      {bool append = false}) async {
    final resource = _getLockResource(path);
    final opId = _generateOperationId(_writeOpPrefix);

    try {
      await _lockManager.acquireExclusiveLock(resource, opId);
      await _storage.writeLinesStream(path, lines, append: append);
    } finally {
      _lockManager.releaseExclusiveLock(resource, opId);
    }
  }

  @override
  Future<void> ensureDirectoryExists(String path) async {
    return _storage.ensureDirectoryExists(path);
  }
}
