import 'dart:typed_data';
import 'dart:math';
import 'dart:async';
import '../Interface/storage_interface.dart';
import '../handler/logger.dart';
import '../handler/platform_handler.dart';
import 'lock_manager.dart';
import 'package:path/path.dart' as path;
import '../model/data_store_config.dart';
import '../model/id_generator.dart';

// Import platform-specific implementations with conditional imports
import 'web_storage_impl.dart'
    if (dart.library.io) '../Interface/web_storage_impl_stub.dart';
import '../Interface/file_storage_impl_stub.dart'
    if (dart.library.io) 'file_storage_impl.dart';
import 'transaction_context.dart';

/// Storage adapter to handle platform-specific storage implementations
class StorageAdapter implements StorageInterface {
  late final StorageInterface _storage;

  /// lock manager
  final LockManager _lockManager;

  /// Guard against concurrent flushAll executions
  bool _flushInProgress = false;

  /// Global scheduler and activity tracking (shared across adapters)
  static final Set<StorageAdapter> _instances = <StorageAdapter>{};
  static DateTime? _lastWriteAt;
  static DateTime? _lastFlushAt;
  static RecoveryFlushPolicy _flushPolicy = RecoveryFlushPolicy.adaptive;

  static Timer? _burstTimer;
  static DateTime? _lastBurstAt;
  static const Duration _burstMinGap = Duration(seconds: 1);
  static RecoveryFlushPolicy get flushPolicy => _flushPolicy;

  /// operation prefix
  static const String _readOpPrefix = 'read-';
  static const String _writeOpPrefix = 'write-';
  static const String _listOpPrefix = 'list-';
  static const String _deleteOpPrefix = 'delete-';
  static const String _writeOpSerializePrefix = 'write-serialize-';
  StorageAdapter()
      : _lockManager = LockManager(
            baseLockTimeout: 300000, enableDeadlockDetection: true) {
    if (PlatformHandler.isWeb) {
      _storage = WebStorageImpl('db');
    } else {
      _storage = FileStorageImpl();
    }

    // Register instance for global flush operations
    _instances.add(this);
  }

  /// Unified configuration entry to reduce initialization redundancy
  Future<void> configure(
      {int? maxOpenHandles, RecoveryFlushPolicy? flushPolicy}) async {
    try {
      if (flushPolicy != null) {
        setFlushPolicy(flushPolicy);
      }
      await configureStorage(maxOpenHandles: maxOpenHandles);
    } catch (e) {
      Logger.error('Configure storage failed: $e', label: 'StorageAdapter');
    }
  }

  /// generate lock resource name for resource path
  String _getLockResource(String filePath) {
    // normalize path, remove unnecessary separators
    final normalizedPath = path.normalize(filePath);

    // use hash to handle long path, avoid lock resource name too long
    if (normalizedPath.length > 128) {
      // Use more stable hash method and add prefix for better identification
      final hash = normalizedPath.hashCode.abs();
      return 'path-hash-$hash';
    }

    return 'path-$normalizedPath';
  }

  /// generate write serialization lock resource name for resource path
  String _getWriteLockResource(String filePath) {
    final normalizedPath = path.normalize(filePath);

    if (normalizedPath.length > 128) {
      final hash = normalizedPath.hashCode.abs();
      return '$_writeOpSerializePrefix$hash';
    }

    return '$_writeOpSerializePrefix$normalizedPath';
  }

  /// Build a temporary file path for crash-safe atomic replacement.
  ///
  /// For paths under a database space root (`.../spaces/{spaceName}/...`),
  /// place all temporary files under that space's `tmp` directory with
  /// the same relative layout:
  ///
  /// ```text
  /// final:  /.../spaces/{spaceName}/data/xxx/meta.json
  /// temp :  /.../spaces/{spaceName}/tmp/data/xxx/.meta.json.tmp-{ts}
  /// ```
  ///
  /// This allows the caller to simply delete the `tmp` directory on
  /// startup for cleanup, without scanning all data/index directories.
  /// For other paths (schemas/global/logs), fall back to same-directory
  /// temporary files.
  String _buildTempPath(String filePath) {
    final normalized = path.normalize(filePath);
    final parts = path.split(normalized);
    final idx = parts.indexOf('spaces');

    if (idx != -1 && idx + 1 < parts.length) {
      final spaceRootParts = parts.sublist(0, idx + 2); // .../spaces/<space>
      final spaceRoot = path.joinAll(spaceRootParts);
      final tmpRoot = path.join(spaceRoot, 'tmp');

      final relParts = parts.sublist(idx + 2); // after .../spaces/<space>
      final ts = DateTime.now().microsecondsSinceEpoch;
      final rand = Random().nextInt(1000000);

      if (relParts.isEmpty) {
        return path.join(tmpRoot, '.temp.tmp-$ts-$rand');
      }

      final base = relParts.removeLast();
      final relDir = relParts.isEmpty ? '' : path.joinAll(relParts);
      final tmpName = '.$base.tmp-$ts-$rand';

      return relDir.isEmpty
          ? path.join(tmpRoot, tmpName)
          : path.join(tmpRoot, relDir, tmpName);
    }

    final dir = path.dirname(normalized);
    final base = path.basename(normalized);
    final ts = DateTime.now().microsecondsSinceEpoch;
    final rand = Random().nextInt(1000000);
    return path.join(dir, '.$base.tmp-$ts-$rand');
  }

  Future<void> _cleanupTemp(String? tempPath) async {
    if (tempPath == null) return;
    try {
      if (await _storage.existsFile(tempPath)) {
        await _storage.deleteFile(tempPath);
      }
    } catch (_) {}
  }

  /// generate operation id with high uniqueness
  String _generateOperationId(String prefix) {
    return GlobalIdGenerator.generate(prefix);
  }

  /// Update recovery flush policy and (re)register global scheduler accordingly
  void setFlushPolicy(RecoveryFlushPolicy policy) {
    _flushPolicy = policy;
  }

  // Debounced event-driven flush for recovery artifacts (pooled handles).
  static void _scheduleBurstFlush() {
    // If a burst timer is already pending, do not reschedule; coalesce triggers.
    if (_burstTimer != null && _burstTimer!.isActive) {
      return;
    }
    Duration? delay;
    switch (_flushPolicy) {
      case RecoveryFlushPolicy.off:
      case RecoveryFlushPolicy.low:
        delay = null;
        break;
      case RecoveryFlushPolicy.medium:
        delay = const Duration(seconds: 1);
        break;
      case RecoveryFlushPolicy.high:
        delay = const Duration(milliseconds: 200);
        break;
      case RecoveryFlushPolicy.adaptive:
        final now = DateTime.now();
        final last = _lastWriteAt;
        if (last == null) {
          delay = null;
        } else {
          final since = now.difference(last);
          if (since.inMinutes >= 1) {
            delay = null; // idle
          } else if (since.inSeconds <= 30) {
            delay = const Duration(milliseconds: 200); // busy
          } else {
            delay = const Duration(milliseconds: 500); // normal
          }
        }
        break;
    }
    if (delay == null) return;

    _burstTimer = Timer(delay, () async {
      final now = DateTime.now();
      // Prevent overly frequent bursts
      if (_lastBurstAt != null &&
          now.difference(_lastBurstAt!) < _burstMinGap) {
        return;
      }
      // Skip if no new write since last flush
      final lastWrite = _lastWriteAt;
      if (lastWrite == null) return;
      if (_lastFlushAt != null && !lastWrite.isAfter(_lastFlushAt!)) return;

      _lastBurstAt = now;
      try {
        final instances = _instances.toList(growable: false);
        await Future.wait(instances.map((inst) async {
          try {
            await inst.flushAll();
          } catch (_) {}
        }));
        _lastFlushAt = DateTime.now();
      } catch (_) {}
    });
  }

  static void notifyRecoveryWrite() {
    _lastWriteAt = DateTime.now();
    _scheduleBurstFlush();
  }

  @override
  Future<void> writeAsString(String path, String content,
      {bool append = false,
      bool flush = true,
      bool closeHandleAfterFlush = false}) async {
    final resource = _getLockResource(path);
    final writeResource = _getWriteLockResource(path);
    final opId = _generateOperationId(_writeOpPrefix);
    final serializeOpId = '$opId-serialize';

    bool serializeAcquired = false;
    try {
      // Serialize writers to avoid concurrent overwrites while allowing readers during temp write.
      serializeAcquired =
          await _lockManager.acquireExclusiveLock(writeResource, serializeOpId);
      if (!serializeAcquired) {
        throw Exception(
            'Failed to acquire serialize lock for write: $writeResource');
      }

      // Atomic path for non-append + flush=true: long write goes to temp without blocking readers.
      if (!append && flush) {
        final tempPath = _buildTempPath(path);
        try {
          await _storage.writeAsString(tempPath, content,
              append: false, flush: true, closeHandleAfterFlush: true);

          final replaceOpId = '$opId-replace';
          bool replaceAcquired = false;
          try {
            replaceAcquired =
                await _lockManager.acquireExclusiveLock(resource, replaceOpId);
            if (!replaceAcquired) {
              throw Exception(
                  'Failed to acquire exclusive lock for atomic replace: $resource');
            }
            await _storage.replaceFileAtomic(tempPath, path);
            TransactionContext.registerTouchedPath(path);
          } finally {
            if (replaceAcquired) {
              _lockManager.releaseExclusiveLock(resource, replaceOpId);
            }
          }
        } finally {
          await _cleanupTemp(tempPath);
        }
        return;
      }

      bool acquired = false;
      try {
        // Legacy path for append or flush=false: hold write lock to protect readers.
        acquired = await _lockManager.acquireExclusiveLock(resource, opId);
        if (!acquired) {
          throw Exception(
              'Failed to acquire exclusive lock for write: $resource');
        }

        await _storage.writeAsString(path, content,
            append: append,
            flush: flush,
            closeHandleAfterFlush: closeHandleAfterFlush);
        TransactionContext.registerTouchedPath(path);
      } finally {
        if (acquired) {
          _lockManager.releaseExclusiveLock(resource, opId);
        }
      }
    } finally {
      if (serializeAcquired) {
        _lockManager.releaseExclusiveLock(writeResource, serializeOpId);
      }
    }
  }

  @override
  Future<void> writeAsBytes(String path, Uint8List bytes,
      {bool flush = true, bool closeHandleAfterFlush = false}) async {
    final resource = _getLockResource(path);
    final writeResource = _getWriteLockResource(path);
    final opId = _generateOperationId(_writeOpPrefix);
    final serializeOpId = '$opId-serialize';

    bool serializeAcquired = false;
    try {
      serializeAcquired =
          await _lockManager.acquireExclusiveLock(writeResource, serializeOpId);
      if (!serializeAcquired) {
        throw Exception(
            'Failed to acquire serialize lock for writeBytes: $writeResource');
      }

      if (flush) {
        final tempPath = _buildTempPath(path);
        try {
          await _storage.writeAsBytes(tempPath, bytes,
              flush: true, closeHandleAfterFlush: true);

          final replaceOpId = '$opId-replace';
          bool replaceAcquired = false;
          try {
            replaceAcquired =
                await _lockManager.acquireExclusiveLock(resource, replaceOpId);
            if (!replaceAcquired) {
              throw Exception(
                  'Failed to acquire exclusive lock for atomic replace: $resource');
            }
            await _storage.replaceFileAtomic(tempPath, path);
            TransactionContext.registerTouchedPath(path);
          } finally {
            if (replaceAcquired) {
              _lockManager.releaseExclusiveLock(resource, replaceOpId);
            }
          }
        } finally {
          await _cleanupTemp(tempPath);
        }
        return;
      }

      bool acquired = false;
      try {
        acquired = await _lockManager.acquireExclusiveLock(resource, opId);
        if (!acquired) {
          throw Exception(
              'Failed to acquire exclusive lock for writeBytes: $resource');
        }

        await _storage.writeAsBytes(path, bytes,
            flush: flush, closeHandleAfterFlush: closeHandleAfterFlush);
        TransactionContext.registerTouchedPath(path);
      } finally {
        if (acquired) {
          _lockManager.releaseExclusiveLock(resource, opId);
        }
      }
    } finally {
      if (serializeAcquired) {
        _lockManager.releaseExclusiveLock(writeResource, serializeOpId);
      }
    }
  }

  @override
  Future<String?> readAsString(String path) async {
    final resource = _getLockResource(path);
    final opId = _generateOperationId(_readOpPrefix);

    bool acquired = false;
    try {
      acquired = await _lockManager.acquireSharedLock(resource, opId);
      if (!acquired) {
        throw Exception('Failed to acquire shared lock for read: $resource');
      }
      return await _storage.readAsString(path);
    } finally {
      if (acquired) {
        _lockManager.releaseSharedLock(resource, opId);
      }
    }
  }

  @override
  Future<void> deleteFile(String path) async {
    final resource = _getLockResource(path);
    final opId = _generateOperationId(_deleteOpPrefix);

    bool acquired = false;
    try {
      acquired = await _lockManager.acquireExclusiveLock(resource, opId);
      if (!acquired) {
        throw Exception(
            'Failed to acquire exclusive lock for deleteFile: $resource');
      }
      await _storage.deleteFile(path);
    } finally {
      if (acquired) {
        _lockManager.releaseExclusiveLock(resource, opId);
      }
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

    bool acquired = false;
    try {
      acquired = await _lockManager.acquireSharedLock(resource, opId);
      if (!acquired) {
        throw Exception('Failed to acquire shared lock for list: $resource');
      }
      return await _storage.listDirectory(path, recursive: recursive);
    } finally {
      if (acquired) {
        _lockManager.releaseSharedLock(resource, opId);
      }
    }
  }

  @override
  Future<void> close({bool isMigrationInstance = false}) async {
    if (!isMigrationInstance) {
      await _storage.close();
    }
    _lockManager.dispose();
    _instances.remove(this);
  }

  @override
  Future<DateTime?> getFileCreationTime(String path) async {
    final resource = _getLockResource(path);
    final opId = _generateOperationId(_readOpPrefix);

    bool acquired = false;
    try {
      acquired = await _lockManager.acquireSharedLock(resource, opId);
      if (!acquired) {
        throw Exception(
            'Failed to acquire shared lock for getFileCreationTime: $resource');
      }
      return await _storage.getFileCreationTime(path);
    } finally {
      if (acquired) {
        _lockManager.releaseSharedLock(resource, opId);
      }
    }
  }

  @override
  Future<Uint8List> readAsBytes(String path) async {
    final resource = _getLockResource(path);
    final opId = _generateOperationId(_readOpPrefix);

    bool acquired = false;
    try {
      acquired = await _lockManager.acquireSharedLock(resource, opId);
      if (!acquired) {
        throw Exception(
            'Failed to acquire shared lock for readBytes: $resource');
      }
      return await _storage.readAsBytes(path);
    } finally {
      if (acquired) {
        _lockManager.releaseSharedLock(resource, opId);
      }
    }
  }

  @override
  Future<Uint8List> readAsBytesAt(String path, int start, {int? length}) async {
    final resource = _getLockResource(path);
    final opId = _generateOperationId(_readOpPrefix);

    bool acquired = false;
    try {
      acquired = await _lockManager.acquireSharedLock(resource, opId);
      if (!acquired) {
        throw Exception(
            'Failed to acquire shared lock for readBytesAt: $resource');
      }
      return await _storage.readAsBytesAt(path, start, length: length);
    } finally {
      if (acquired) {
        _lockManager.releaseSharedLock(resource, opId);
      }
    }
  }

  @override
  Future<void> writeAsBytesAt(String path, int start, Uint8List bytes,
      {bool flush = true, bool closeHandleAfterFlush = false}) async {
    if (bytes.isEmpty) return;
    if (start < 0) {
      throw ArgumentError.value(start, 'start', 'must be >= 0');
    }
    final resource = _getLockResource(path);
    final writeResource = _getWriteLockResource(path);
    final opId = _generateOperationId(_writeOpPrefix);

    bool serializeAcquired = false;
    bool resourceAcquired = false;
    try {
      // Serialize writes on the same path to avoid handle/position races.
      serializeAcquired =
          await _lockManager.acquireExclusiveLock(writeResource, opId);
      if (!serializeAcquired) {
        throw Exception(
            'Failed to acquire serialize lock for writeAsBytesAt: $writeResource');
      }

      // Block concurrent readers while applying random writes.
      resourceAcquired =
          await _lockManager.acquireExclusiveLock(resource, '$opId-path');
      if (!resourceAcquired) {
        throw Exception(
            'Failed to acquire exclusive lock for writeAsBytesAt: $resource');
      }

      await _storage.writeAsBytesAt(path, start, bytes,
          flush: flush, closeHandleAfterFlush: closeHandleAfterFlush);
      TransactionContext.registerTouchedPath(path);
    } finally {
      if (resourceAcquired) {
        _lockManager.releaseExclusiveLock(resource, '$opId-path');
      }
      if (serializeAcquired) {
        _lockManager.releaseExclusiveLock(writeResource, opId);
      }
    }
  }

  @override
  Future<void> writeManyAsBytesAt(String path, List<ByteWrite> writes,
      {bool flush = true, bool closeHandleAfterFlush = false}) async {
    if (writes.isEmpty) return;
    final resource = _getLockResource(path);
    final writeResource = _getWriteLockResource(path);
    final opId = _generateOperationId(_writeOpPrefix);

    bool serializeAcquired = false;
    bool resourceAcquired = false;
    try {
      serializeAcquired =
          await _lockManager.acquireExclusiveLock(writeResource, opId);
      if (!serializeAcquired) {
        throw Exception(
            'Failed to acquire serialize lock for writeManyAsBytesAt: $writeResource');
      }

      // Block concurrent readers while applying random writes batch.
      resourceAcquired =
          await _lockManager.acquireExclusiveLock(resource, '$opId-path');
      if (!resourceAcquired) {
        throw Exception(
            'Failed to acquire exclusive lock for writeManyAsBytesAt: $resource');
      }

      await _storage.writeManyAsBytesAt(path, writes,
          flush: flush, closeHandleAfterFlush: closeHandleAfterFlush);
      TransactionContext.registerTouchedPath(path);
    } finally {
      if (resourceAcquired) {
        _lockManager.releaseExclusiveLock(resource, '$opId-path');
      }
      if (serializeAcquired) {
        _lockManager.releaseExclusiveLock(writeResource, opId);
      }
    }
  }

  @override
  Future<DateTime?> getFileModifiedTime(String path) async {
    final resource = _getLockResource(path);
    final opId = _generateOperationId(_readOpPrefix);

    bool acquired = false;
    try {
      acquired = await _lockManager.acquireSharedLock(resource, opId);

      if (!acquired) {
        throw Exception(
            'Failed to acquire shared lock for getFileModifiedTime: $resource');
      }

      return await _storage.getFileModifiedTime(path);
    } finally {
      if (acquired) {
        _lockManager.releaseSharedLock(resource, opId);
      }
    }
  }

  @override
  Future<int> getFileSize(String path) async {
    final resource = _getLockResource(path);
    final opId = _generateOperationId(_readOpPrefix);

    bool acquired = false;
    try {
      acquired = await _lockManager.acquireSharedLock(resource, opId);
      if (!acquired) {
        throw Exception(
            'Failed to acquire shared lock for getFileSize: $resource');
      }
      return await _storage.getFileSize(path);
    } finally {
      if (acquired) {
        _lockManager.releaseSharedLock(resource, opId);
      }
    }
  }

  @override
  Future<void> deleteDirectory(String path) async {
    final resource = _getLockResource(path);
    final opId = _generateOperationId(_deleteOpPrefix);

    bool acquired = false;
    try {
      acquired = await _lockManager.acquireExclusiveLock(resource, opId);
      if (!acquired) {
        throw Exception(
            'Failed to acquire exclusive lock for deleteDirectory: $resource');
      }

      await _storage.deleteDirectory(path);
    } finally {
      if (acquired) {
        _lockManager.releaseExclusiveLock(resource, opId);
      }
    }
  }

  @override
  Future<void> copyDirectory(String sourcePath, String destinationPath) async {
    final sourceResource = _getLockResource(sourcePath);
    final destResource = _getLockResource(destinationPath);
    final opId = _generateOperationId(_writeOpPrefix);

    // Enforce deterministic lock ordering to avoid deadlocks
    final firstResource = sourceResource.compareTo(destResource) <= 0
        ? sourceResource
        : destResource;
    final secondResource =
        firstResource == sourceResource ? destResource : sourceResource;

    final firstIsSource = firstResource == sourceResource;
    final secondIsSource = !firstIsSource;

    bool firstAcquired = false;
    bool secondAcquired = false;
    try {
      // Acquire first lock (shared if source, exclusive if dest)
      if (firstIsSource) {
        firstAcquired =
            await _lockManager.acquireSharedLock(firstResource, '$opId-first');
      } else {
        firstAcquired = await _lockManager.acquireExclusiveLock(
            firstResource, '$opId-first');
      }
      if (!firstAcquired) {
        throw Exception(
            'Failed to acquire lock for copyDirectory first: $firstResource');
      }

      // Acquire second lock
      if (secondIsSource) {
        secondAcquired = await _lockManager.acquireSharedLock(
            secondResource, '$opId-second');
      } else {
        secondAcquired = await _lockManager.acquireExclusiveLock(
            secondResource, '$opId-second');
      }
      if (!secondAcquired) {
        throw Exception(
            'Failed to acquire lock for copyDirectory second: $secondResource');
      }

      await _storage.copyDirectory(sourcePath, destinationPath);
    } finally {
      // Release in reverse order
      if (secondAcquired) {
        if (secondIsSource) {
          _lockManager.releaseSharedLock(secondResource, '$opId-second');
        } else {
          _lockManager.releaseExclusiveLock(secondResource, '$opId-second');
        }
      }
      if (firstAcquired) {
        if (firstIsSource) {
          _lockManager.releaseSharedLock(firstResource, '$opId-first');
        } else {
          _lockManager.releaseExclusiveLock(firstResource, '$opId-first');
        }
      }
    }
  }

  @override
  Future<void> copyFile(String sourcePath, String destinationPath) async {
    final sourceResource = _getLockResource(sourcePath);
    final destResource = _getLockResource(destinationPath);
    final opId = _generateOperationId(_writeOpPrefix);

    // Enforce deterministic lock ordering to avoid deadlocks
    final firstResource = sourceResource.compareTo(destResource) <= 0
        ? sourceResource
        : destResource;
    final secondResource =
        firstResource == sourceResource ? destResource : sourceResource;

    final firstIsSource = firstResource == sourceResource;
    final secondIsSource = !firstIsSource;

    bool firstAcquired = false;
    bool secondAcquired = false;
    try {
      // Acquire first lock (shared if source, exclusive if dest)
      if (firstIsSource) {
        firstAcquired =
            await _lockManager.acquireSharedLock(firstResource, '$opId-first');
      } else {
        firstAcquired = await _lockManager.acquireExclusiveLock(
            firstResource, '$opId-first');
      }
      if (!firstAcquired) {
        throw Exception(
            'Failed to acquire lock for copyFile first: $firstResource');
      }

      // Acquire second lock
      if (secondIsSource) {
        secondAcquired = await _lockManager.acquireSharedLock(
            secondResource, '$opId-second');
      } else {
        secondAcquired = await _lockManager.acquireExclusiveLock(
            secondResource, '$opId-second');
      }
      if (!secondAcquired) {
        throw Exception(
            'Failed to acquire lock for copyFile second: $secondResource');
      }

      await _storage.copyFile(sourcePath, destinationPath);
    } finally {
      // Release in reverse order
      if (secondAcquired) {
        if (secondIsSource) {
          _lockManager.releaseSharedLock(secondResource, '$opId-second');
        } else {
          _lockManager.releaseExclusiveLock(secondResource, '$opId-second');
        }
      }
      if (firstAcquired) {
        if (firstIsSource) {
          _lockManager.releaseSharedLock(firstResource, '$opId-first');
        } else {
          _lockManager.releaseExclusiveLock(firstResource, '$opId-first');
        }
      }
    }
  }

  @override
  Stream<String> readLinesStream(String path, {int offset = 0}) async* {
    final resource = _getLockResource(path);
    final opId = _generateOperationId(_readOpPrefix);

    bool acquired = false;
    try {
      acquired = await _lockManager.acquireSharedLock(resource, opId);
      if (!acquired) {
        throw Exception(
            'Failed to acquire shared lock for readLinesStream: $resource');
      }

      final stream = _storage.readLinesStream(path, offset: offset);
      await for (final line in stream) {
        yield line;
      }
    } finally {
      if (acquired) {
        _lockManager.releaseSharedLock(resource, opId);
      }
    }
  }

  @override
  Future<void> writeLinesStream(String path, Stream<String> lines,
      {bool append = false}) async {
    final resource = _getLockResource(path);
    final opId = _generateOperationId(_writeOpPrefix);

    bool acquired = false;
    try {
      acquired = await _lockManager.acquireExclusiveLock(resource, opId);
      if (!acquired) {
        throw Exception(
            'Failed to acquire exclusive lock for writeLinesStream: $resource');
      }
      await _storage.writeLinesStream(path, lines, append: append);
    } finally {
      if (acquired) {
        _lockManager.releaseExclusiveLock(resource, opId);
      }
    }
  }

  @override
  Future<void> ensureDirectoryExists(String path) async {
    return _storage.ensureDirectoryExists(path);
  }

  @override
  Future<int> appendBytes(String path, Uint8List bytes,
      {bool flush = true, bool closeHandleAfterFlush = false}) async {
    final resource = _getLockResource(path);
    final opId = _generateOperationId(_writeOpPrefix);
    bool acquired = false;
    try {
      acquired = await _lockManager.acquireExclusiveLock(resource, opId);
      if (!acquired) {
        throw Exception(
            'Failed to acquire exclusive lock for appendBytes: $resource');
      }
      final off = await _storage.appendBytes(path, bytes,
          flush: flush, closeHandleAfterFlush: closeHandleAfterFlush);
      TransactionContext.registerTouchedPath(path);
      return off;
    } finally {
      if (acquired) {
        _lockManager.releaseExclusiveLock(resource, opId);
      }
    }
  }

  @override
  Future<int> appendString(String path, String content,
      {bool flush = true, bool closeHandleAfterFlush = false}) async {
    final resource = _getLockResource(path);
    final opId = _generateOperationId(_writeOpPrefix);
    bool acquired = false;
    try {
      acquired = await _lockManager.acquireExclusiveLock(resource, opId);
      if (!acquired) {
        throw Exception(
            'Failed to acquire exclusive lock for appendString: $resource');
      }
      final off = await _storage.appendString(path, content,
          flush: flush, closeHandleAfterFlush: closeHandleAfterFlush);
      TransactionContext.registerTouchedPath(path);
      return off;
    } finally {
      if (acquired) {
        _lockManager.releaseExclusiveLock(resource, opId);
      }
    }
  }

  @override
  Future<List<String>> readAsLines(String path, {int offset = 0}) async {
    final resource = _getLockResource(path);
    final opId = _generateOperationId(_readOpPrefix);
    bool acquired = false;
    try {
      acquired = await _lockManager.acquireSharedLock(resource, opId);
      if (!acquired) {
        throw Exception(
            'Failed to acquire shared lock for readAsLines: $resource');
      }
      return await _storage.readAsLines(path, offset: offset);
    } finally {
      if (acquired) {
        _lockManager.releaseSharedLock(resource, opId);
      }
    }
  }

  @override
  Future<void> flushFile(String path) async {
    return _storage.flushFile(path);
  }

  @override
  Future<void> flushAll(
      {String? path, List<String>? paths, bool closeHandles = false}) async {
    // Prevent concurrent flushes which could thrash IO
    if (_flushInProgress) return;
    _flushInProgress = true;
    try {
      return await _storage.flushAll(
          path: path, paths: paths, closeHandles: closeHandles);
    } finally {
      _flushInProgress = false;
    }
  }

  @override
  Future<void> configureStorage({int? maxOpenHandles}) async {
    return _storage.configureStorage(maxOpenHandles: maxOpenHandles);
  }

  @override
  Future<void> replaceFileAtomic(String tempPath, String finalPath) async {
    // Acquire exclusive lock on final path to serialize atomic replacement
    final resource = _getLockResource(finalPath);
    final opId = _generateOperationId(_writeOpPrefix);
    bool acquired = false;
    try {
      acquired = await _lockManager.acquireExclusiveLock(resource, opId);
      if (!acquired) {
        throw Exception(
            'Failed to acquire exclusive lock for replaceFileAtomic: $resource');
      }
      await _storage.replaceFileAtomic(tempPath, finalPath);
      // Register final path as touched for current transaction scope (if any)
      TransactionContext.registerTouchedPath(finalPath);
    } finally {
      if (acquired) {
        _lockManager.releaseExclusiveLock(resource, opId);
      }
    }
  }
}
