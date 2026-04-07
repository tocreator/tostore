import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' if (dart.library.html) '../Interface/io_stub.dart';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../Interface/storage_interface.dart';
import '../handler/logger.dart';
import 'yield_controller.dart';

/// File system storage implementation for native platforms
class FileStorageImpl implements StorageInterface {
  FileStorageImpl();

  // File handle pool with simple LRU eviction to reduce open/close overhead
  final Map<String, RandomAccessFile> _handlePool = {};
  final LinkedHashMap<String, DateTime> _lru =
      LinkedHashMap<String, DateTime>();
  int _maxOpenHandles = 128;

  // Per-handle operation queues to serialize async operations on the same RandomAccessFile
  final Map<String, Future<void>> _handleLocks = {};
  // Cached file length per handle key to avoid frequent raf.length() on hot append paths
  final Map<String, int> _handleLengths = {};

  Future<T> _withHandleLock<T>(
      String key, Future<T> Function() operation) async {
    // Chain this operation after the previous one for the same handle key
    final previous = _handleLocks[key] ?? Future.value();
    final completer = Completer<void>();
    final current = previous.then((_) => completer.future);
    // Next waiter will wait on this composite future
    _handleLocks[key] = current;
    try {
      // Ensure previous completes before executing
      await previous;
      return await operation();
    } finally {
      // Complete this slot and clean up if no one replaced it in the meantime
      if (identical(_handleLocks[key], current)) {
        _handleLocks.remove(key);
      }
      completer.complete();
    }
  }

  String _poolKey(String path, FileMode mode) {
    final modeKey = (mode == FileMode.append)
        ? 'a'
        : (mode == FileMode.write)
            ? 'w'
            : (mode == FileMode.read)
                ? 'r'
                : mode.toString();
    return '${p.canonicalize(path)}|$modeKey';
  }

  /// Flush and close all open handles whose file paths are under [dirPath].
  /// Used before deleting a directory to avoid "file in use" errors
  /// (especially on Windows, where open handles block deletion).
  Future<void> _flushAndCloseHandlesUnderDirectory(String dirPath) async {
    try {
      final normalizedDir = p.canonicalize(dirPath);
      final String dirPrefix;
      if (normalizedDir.endsWith(p.separator)) {
        dirPrefix = normalizedDir;
      } else {
        dirPrefix = '$normalizedDir${p.separator}';
      }

      // Snapshot to avoid concurrent modification while iterating.
      final entries = _handlePool.entries.toList();
      final yieldController =
          YieldController('storage_flush_dir_handles'); // best-effort

      for (final e in entries) {
        final key = e.key;
        final raf = e.value;
        // key format: "<normalizedPath>|<modeKey>"
        final sepIdx = key.lastIndexOf('|');
        if (sepIdx <= 0) {
          continue;
        }
        final filePath = key.substring(0, sepIdx);

        // Match both the directory itself and any child paths.
        if (filePath != normalizedDir && !filePath.startsWith(dirPrefix)) {
          continue;
        }

        try {
          await _withHandleLock(key, () async {
            try {
              await raf.flush();
            } catch (_) {}
            try {
              await raf.close();
            } catch (_) {}
            _handlePool.remove(key);
            _lru.remove(key);
            _handleLengths.remove(key);
          });
        } catch (_) {}

        await yieldController.maybeYield();
      }
    } catch (_) {}
  }

  Future<RandomAccessFile> _getHandle(String path, FileMode mode) async {
    final key = _poolKey(path, mode);
    final file = File(path);
    await file.parent.create(recursive: true);

    var existing = _handlePool[key];
    if (existing != null) {
      _lru[key] = DateTime.now();
      return existing;
    }

    // Open new handle
    final raf = await file.open(mode: mode);
    _handlePool[key] = raf;
    _lru[key] = DateTime.now();

    // Evict if exceeding threshold
    if (_handlePool.length > _maxOpenHandles) {
      // remove least-recently used
      final oldestKey =
          _lru.entries.reduce((a, b) => a.value.isBefore(b.value) ? a : b).key;

      // Remove from pool immediately to prevent new ops from checking it out
      final rafToClose = _handlePool.remove(oldestKey);
      _lru.remove(oldestKey);
      _handleLengths.remove(oldestKey);

      if (rafToClose != null) {
        // Asynchronously close it, ensuring we respect existing locks.
        // ignore: unawaited_futures
        _withHandleLock(oldestKey, () async {
          try {
            await rafToClose.flush();
            await rafToClose.close();
          } catch (_) {}
        });
      }
    }

    return raf;
  }

  @override
  Future<void> deleteFile(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await flushAll(path: path, closeHandles: true);

        if (Platform.isWindows) {
          const retryDelays = [100, 300, 800, 1500];
          for (int attempt = 0; attempt <= retryDelays.length; attempt++) {
            try {
              await file.delete();
              return;
            } on FileSystemException catch (_) {
              if (attempt >= retryDelays.length) {
                rethrow;
              }
              await flushAll(path: path, closeHandles: true);
              await Future.delayed(
                  Duration(milliseconds: retryDelays[attempt]));
            }
          }
        } else {
          await file.delete();
        }
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
        await _flushAndCloseHandlesUnderDirectory(path);

        if (Platform.isWindows) {
          const retryDelays = [200, 500, 1000, 2000];
          for (int attempt = 0; attempt <= retryDelays.length; attempt++) {
            try {
              await directory.delete(recursive: true);
              return;
            } on FileSystemException catch (_) {
              if (attempt >= retryDelays.length) {
                rethrow;
              }
              await _flushAndCloseHandlesUnderDirectory(path);
              await Future.delayed(
                  Duration(milliseconds: retryDelays[attempt]));
            }
          }
        } else {
          await directory.delete(recursive: true);
        }
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
      if (!await dir.exists()) {
        return [];
      }

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
    try {
      // Snapshot handles (key, raf) to avoid concurrent modification if pool changes during close
      final entries = _handlePool.entries.toList();
      for (final e in entries) {
        final key = e.key;
        final raf = e.value;
        try {
          await _withHandleLock(key, () async {
            try {
              await raf.flush();
              await raf.close();
            } catch (_) {}
          });
        } catch (_) {}
      }
      _handlePool.clear();
      _lru.clear();
      _handleLengths.clear();
    } catch (e) {
      Logger.error('Close storage failed: $e', label: 'FileStorageImpl');
    }
  }

  @override
  Future<void> writeAsString(String path, String content,
      {bool append = false,
      bool flush = true,
      bool closeHandleAfterFlush = false}) async {
    try {
      if (append) {
        await appendString(path, content,
            flush: flush, closeHandleAfterFlush: closeHandleAfterFlush);
        return;
      }

      final key = _poolKey(path, FileMode.write);
      await _withHandleLock(key, () async {
        final raf = await _getHandle(path, FileMode.write);
        try {
          await raf.truncate(0);
          await raf.setPosition(0);
          await raf.writeString(content);
          if (flush) {
            await raf.flush();
          }
          try {
            _handleLengths[key] = await raf.position();
          } catch (_) {}
        } finally {
          if (flush && closeHandleAfterFlush) {
            try {
              await raf.close();
            } catch (_) {}
            _handlePool.remove(key);
            _lru.remove(key);
            _handleLengths.remove(key);
          }
        }
      });
    } catch (e) {
      Logger.error('Write string failed: $e', label: 'FileStorageImpl');
      rethrow;
    }
  }

  @override
  Future<void> writeAsBytes(String path, Uint8List bytes,
      {bool flush = true, bool closeHandleAfterFlush = false}) async {
    try {
      final key = _poolKey(path, FileMode.write);
      await _withHandleLock(key, () async {
        final raf = await _getHandle(path, FileMode.write);
        try {
          await raf.truncate(0);
          await raf.setPosition(0);
          await raf.writeFrom(bytes);
          if (flush) {
            await raf.flush();
          }
          _handleLengths[key] = bytes.length;
        } finally {
          if (flush && closeHandleAfterFlush) {
            try {
              await raf.close();
            } catch (_) {}
            _handlePool.remove(key);
            _lru.remove(key);
            _handleLengths.remove(key);
          }
        }
      });
    } catch (e) {
      Logger.error('Write bytes failed: $e', label: 'FileStorageImpl');
      rethrow;
    }
  }

  @override
  Future<Uint8List> readAsBytes(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      return Uint8List(0);
    }
    return await file.readAsBytes();
  }

  static bool _isFileNotFound(Object e) {
    final s = e.toString();
    return s.contains('PathNotFoundException') ||
        s.contains('No such file or directory') ||
        s.contains('errno = 2');
  }

  @override
  Future<Uint8List> readAsBytesAt(String path, int start, {int? length}) async {
    final key = _poolKey(path, FileMode.read);
    try {
      return await _withHandleLock<Uint8List>(key, () async {
        final raf = await _getHandle(path, FileMode.read);
        final fileSize = await raf.length();
        if (start >= fileSize) {
          return Uint8List(0);
        }
        final readLen = length != null
            ? (start + length > fileSize ? fileSize - start : length)
            : fileSize - start;
        if (readLen <= 0) {
          return Uint8List(0);
        }
        await raf.setPosition(start);
        return await raf.read(readLen);
      });
    } catch (e) {
      if (_isFileNotFound(e)) {
        return Uint8List(0);
      }
      Logger.error('Read bytes at offset failed: $e', label: 'FileStorageImpl');
      return Uint8List(0);
    }
  }

  @override
  Future<void> writeAsBytesAt(
    String path,
    int start,
    Uint8List bytes, {
    bool flush = true,
    bool closeHandleAfterFlush = false,
  }) async {
    if (bytes.isEmpty) {
      return;
    }
    await writeManyAsBytesAt(
      path,
      <ByteWrite>[ByteWrite(offset: start, bytes: bytes)],
      flush: flush,
      closeHandleAfterFlush: closeHandleAfterFlush,
    );
  }

  @override
  Future<void> writeManyAsBytesAt(
    String path,
    List<ByteWrite> writes, {
    bool flush = true,
    bool closeHandleAfterFlush = false,
  }) async {
    if (writes.isEmpty) {
      return;
    }
    final items = <_WriteSpan>[
      for (int i = 0; i < writes.length; i++)
        _WriteSpan(offset: writes[i].offset, bytes: writes[i].bytes, order: i),
    ];
    for (final s in items) {
      if (s.offset < 0) {
        throw ArgumentError.value(s.offset, 'offset', 'must be >= 0');
      }
    }
    items.sort((a, b) {
      final c = a.offset.compareTo(b.offset);
      return c != 0 ? c : a.order.compareTo(b.order);
    });
    int lastEnd = -1;
    for (final s in items) {
      if (s.bytes.isEmpty) {
        continue;
      }
      if (lastEnd >= 0 && s.offset < lastEnd) {
        throw StateError('Overlapping write spans for $path');
      }
      lastEnd = s.offset + s.bytes.length;
    }
    try {
      // Always use pooled handle for random writes to enable delayed flush batching.
      // Use FileMode.append to avoid truncation while allowing random access seeking.
      final key = _poolKey(path, FileMode.append);
      await _withHandleLock<void>(key, () async {
        final raf = await _getHandle(path, FileMode.append);
        try {
          int? cachedLen = _handleLengths[key];
          if (cachedLen == null) {
            try {
              cachedLen = await raf.length();
            } catch (_) {
              cachedLen = 0;
            }
            _handleLengths[key] = cachedLen;
          }
          int currentPos = -1;
          int maxEnd = cachedLen;
          for (final s in items) {
            final data = s.bytes;
            if (data.isEmpty) {
              continue;
            }
            if (currentPos != s.offset) {
              await raf.setPosition(s.offset);
              currentPos = s.offset;
            }
            await raf.writeFrom(data);
            currentPos += data.length;
            if (currentPos > maxEnd) {
              maxEnd = currentPos;
            }
          }
          if (flush) {
            await raf.flush();
          }

          // Update cached length (best-effort).
          _handleLengths[key] = maxEnd;
        } finally {
          if (flush && closeHandleAfterFlush) {
            try {
              await raf.close();
            } catch (_) {}
            _handlePool.remove(key);
            _lru.remove(key);
            _handleLengths.remove(key);
          }
        }
      });
    } catch (e) {
      Logger.error('Write many bytes at offsets failed: $e',
          label: 'FileStorageImpl.writeManyAsBytesAt');
      rethrow;
    }
  }

  @override
  Future<String?> readAsString(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        return null;
      }
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
      if (!await file.exists()) {
        return null;
      }
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
    if (!await file.exists()) {
      return 0;
    }
    return await file.length();
  }

  @override
  Future<DateTime?> getFileModifiedTime(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      return null;
    }
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
          final newPath = p.join(destinationPath, relativePath);
          await Directory(p.dirname(newPath)).create(recursive: true);
          await entity.copy(newPath);
        } else if (entity is Directory) {
          final relativePath = entity.path.substring(sourcePath.length);
          final newDirPath = p.join(destinationPath, relativePath);
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
  Future<void> moveDirectory(String sourcePath, String destinationPath) async {
    try {
      final normalizedSource = p.normalize(sourcePath);
      final normalizedDestination = p.normalize(destinationPath);
      if (normalizedSource == normalizedDestination) {
        return;
      }

      final sourceDir = Directory(sourcePath);
      if (!await sourceDir.exists()) {
        return;
      }

      final destDir = Directory(destinationPath);
      if (await destDir.exists()) {
        throw StateError(
            'Destination directory already exists: $destinationPath');
      }

      await _flushAndCloseHandlesUnderDirectory(sourcePath);
      await _flushAndCloseHandlesUnderDirectory(destinationPath);
      await destDir.parent.create(recursive: true);

      try {
        await sourceDir.rename(destinationPath);
        return;
      } on FileSystemException {
        await copyDirectory(sourcePath, destinationPath);
        await deleteDirectory(sourcePath);
      }
    } catch (e) {
      Logger.error('Move directory failed: $e',
          label: 'FileStorageImpl.moveDirectory');
      rethrow;
    }
  }

  @override
  Future<void> copyFile(String sourcePath, String destinationPath) async {
    try {
      final srcFile = File(sourcePath);
      if (!await srcFile.exists()) {
        return;
      }
      await Directory(p.dirname(destinationPath)).create(recursive: true);
      await srcFile.copy(destinationPath);
    } catch (e) {
      Logger.error('Copy file failed: $e', label: 'FileStorageImpl.copyFile');
      rethrow;
    }
  }

  @override
  Stream<String> readLinesStream(String path, {int offset = 0}) {
    late StreamController<String> controller;

    controller = StreamController<String>(
      onListen: () async {
        try {
          final file = File(path);
          if (!await file.exists()) {
            await controller.close();
            return;
          }
          final key = _poolKey(path, FileMode.read);

          await _withHandleLock(key, () async {
            try {
              final raf = await _getHandle(path, FileMode.read);
              await raf.setPosition(offset);
              final length = await raf.length();
              final List<int> buffer = [];
              const int chunkSize = 64 * 1024;

              while ((await raf.position()) < length && !controller.isClosed) {
                final bytes = await raf.read(chunkSize);
                if (bytes.isEmpty) {
                  break;
                }
                for (int i = 0; i < bytes.length; i++) {
                  if (bytes[i] == 10) {
                    controller.add(utf8.decode(buffer));
                    buffer.clear();
                  } else if (bytes[i] != 13) {
                    buffer.add(bytes[i]);
                  }
                }
              }
              if (buffer.isNotEmpty && !controller.isClosed) {
                controller.add(utf8.decode(buffer));
              }
            } finally {
              if (!controller.isClosed) {
                await controller.close();
              }
            }
          });
        } catch (e) {
          if (!controller.isClosed) {
            controller.addError(e);
            await controller.close();
          }
        }
      },
    );

    return controller.stream;
  }

  @override
  Future<void> writeLinesStream(String path, Stream<String> lines,
      {bool append = false}) async {
    final mode = append ? FileMode.append : FileMode.write;
    final key = _poolKey(path, mode);
    await _withHandleLock(key, () async {
      try {
        final raf = await _getHandle(path, mode);
        if (!append) {
          await raf.setPosition(0);
        }
        await for (final line in lines) {
          await raf.writeString('$line\n');
        }
        await raf.flush();
      } catch (e) {
        Logger.error('Write lines stream failed: $path, error: $e',
            label: 'FileStorageImpl');
        rethrow;
      }
    });
  }

  @override
  Future<void> ensureDirectoryExists(String path) async {
    await Directory(path).create(recursive: true);
  }

  @override
  Future<int> appendBytes(String path, Uint8List bytes,
      {bool flush = true, bool closeHandleAfterFlush = false}) async {
    final key = _poolKey(path, FileMode.append);
    return await _withHandleLock<int>(key, () async {
      final raf = await _getHandle(path, FileMode.append);
      int? cached = _handleLengths[key];
      if (cached == null) {
        cached = await raf.length();
        _handleLengths[key] = cached;
      }
      final offset = cached;
      await raf.setPosition(offset);
      await raf.writeFrom(bytes);
      if (flush) {
        await raf.flush();
      }
      _handleLengths[key] = offset + bytes.length;
      if (flush && closeHandleAfterFlush) {
        await raf.close();
        _handlePool.remove(key);
        _lru.remove(key);
        _handleLengths.remove(key);
      }
      return offset;
    });
  }

  @override
  Future<int> appendString(String path, String content,
      {bool flush = true, bool closeHandleAfterFlush = false}) async {
    final key = _poolKey(path, FileMode.append);
    return await _withHandleLock<int>(key, () async {
      final raf = await _getHandle(path, FileMode.append);
      int? cached = _handleLengths[key];
      if (cached == null) {
        cached = await raf.length();
        _handleLengths[key] = cached;
      }
      final offset = cached;
      await raf.setPosition(offset);
      await raf.writeString(content);
      if (flush) {
        await raf.flush();
      }
      try {
        _handleLengths[key] = await raf.position();
      } catch (_) {}
      if (flush && closeHandleAfterFlush) {
        await raf.close();
        _handlePool.remove(key);
        _lru.remove(key);
        _handleLengths.remove(key);
      }
      return offset;
    });
  }

  @override
  Future<List<String>> readAsLines(String path, {int offset = 0}) async {
    final stream = readLinesStream(path, offset: offset);
    return await stream.toList();
  }

  @override
  Future<void> flushFile(String path) async {
    try {
      final normalizedPath = p.canonicalize(path);
      final entries = _handlePool.entries.toList();
      for (final e in entries) {
        final key = e.key;
        final raf = e.value;
        final sepIdx = key.lastIndexOf('|');
        if (sepIdx <= 0) {
          continue;
        }
        final filePath = key.substring(0, sepIdx);
        if (filePath == normalizedPath) {
          await _withHandleLock(key, () async {
            try {
              await raf.flush();
            } catch (_) {}
          });
        }
      }
    } catch (e) {
      Logger.error('Flush file failed: $e', label: 'FileStorageImpl.flushFile');
      rethrow;
    }
  }

  @override
  Future<void> flushAll(
      {String? path, List<String>? paths, bool closeHandles = false}) async {
    const candidateModes = [FileMode.read, FileMode.write, FileMode.append];
    try {
      if (paths != null && paths.isNotEmpty) {
        final yieldController = YieldController('storage_flush_paths');
        for (final pth in paths) {
          final normalized = p.canonicalize(pth);
          for (final mode in candidateModes) {
            final key = _poolKey(normalized, mode);
            final raf = _handlePool[key];
            if (raf != null) {
              await _withHandleLock(key, () async {
                try {
                  await raf.flush();
                } catch (_) {}
                if (closeHandles) {
                  try {
                    await raf.close();
                  } catch (_) {}
                  _handlePool.remove(key);
                  _lru.remove(key);
                  _handleLengths.remove(key);
                }
              });
            }
          }
          await yieldController.maybeYield();
        }
      } else if (path == null) {
        // Snapshot current handles to avoid concurrent modification during eviction/open
        final entries = _handlePool.entries.toList();
        final yieldController = YieldController('storage_flush_all');
        for (final e in entries) {
          final key = e.key;
          final raf = e.value;
          await _withHandleLock(key, () async {
            try {
              await raf.flush();
            } catch (_) {}
            if (closeHandles) {
              try {
                await raf.close();
              } catch (_) {}
              _handlePool.remove(key);
              _lru.remove(key);
              _handleLengths.remove(key);
            }
          });
          await yieldController.maybeYield();
        }
      } else {
        final normalized = p.canonicalize(path);
        for (final mode in candidateModes) {
          final key = _poolKey(normalized, mode);
          final raf = _handlePool[key];
          if (raf != null) {
            await _withHandleLock(key, () async {
              try {
                await raf.flush();
              } catch (_) {}
              if (closeHandles) {
                try {
                  await raf.close();
                } catch (_) {}
                _handlePool.remove(key);
                _lru.remove(key);
                _handleLengths.remove(key);
              }
            });
          }
        }
      }
    } catch (e) {
      Logger.error('Flush all failed: $e', label: 'FileStorageImpl');
    }
  }

  @override
  Future<void> configureStorage({int? maxOpenHandles}) async {
    if (maxOpenHandles != null && maxOpenHandles > 0) {
      _maxOpenHandles = maxOpenHandles;
    }
  }

  @override
  Future<void> replaceFileAtomic(String tempPath, String finalPath) async {
    try {
      final tmpFile = File(tempPath);
      if (!await tmpFile.exists()) {
        throw FileSystemException('Temporary file does not exist', tempPath);
      }
      await flushAll(path: finalPath, closeHandles: true);
      await flushAll(path: tempPath, closeHandles: true);

      const retryDelays = [50, 150, 400, 800, 1500];
      for (int attempt = 0; attempt <= retryDelays.length; attempt++) {
        try {
          if (Platform.isWindows) {
            final dst = File(finalPath);
            if (await dst.exists()) {
              try {
                await dst.delete();
              } catch (e) {
                // If delete fails on Windows, it's often due to a lingering handle.
                // Try one more aggressive flush before giving up on this attempt.
                await flushAll(path: finalPath, closeHandles: true);
                if (attempt >= retryDelays.length) rethrow;
              }
            } else {
              await dst.parent.create(recursive: true);
            }
          } else {
            await File(finalPath).parent.create(recursive: true);
          }

          // Before rename, ensure no one else opened a handle in the tiny window
          if (Platform.isWindows) {
            await flushAll(path: finalPath, closeHandles: true);
            await flushAll(path: tempPath, closeHandles: true);
          }

          // Try to rename
          try {
            await tmpFile.rename(finalPath);
          } catch (e) {
            if (Platform.isWindows &&
                e is FileSystemException &&
                (e.osError?.errorCode == 32 || e.osError?.errorCode == 5)) {
              // On Windows, sharing violations (32) or access denied (5)
              // often mean handles are still closing.
              await flushAll(path: finalPath, closeHandles: true);
              await flushAll(path: tempPath, closeHandles: true);
              await Future.delayed(const Duration(milliseconds: 20));
              await tmpFile.rename(finalPath);
            } else {
              rethrow;
            }
          }
          return;
        } on FileSystemException catch (e) {
          if (attempt >= retryDelays.length) {
            rethrow;
          }
          // Log transient error but continue retrying
          Logger.warn('Atomic replace transient failure (attempt $attempt): $e',
              label: 'FileStorageImpl');

          await flushAll(path: finalPath, closeHandles: true);
          await flushAll(path: tempPath, closeHandles: true);
          await Future.delayed(Duration(milliseconds: retryDelays[attempt]));
        }
      }
    } catch (e) {
      Logger.error('Atomic replace failed: $e', label: 'FileStorageImpl');
      rethrow;
    }
  }
}

final class _WriteSpan {
  final int offset;
  final Uint8List bytes;
  final int order;
  _WriteSpan({required this.offset, required this.bytes, required this.order});
}
