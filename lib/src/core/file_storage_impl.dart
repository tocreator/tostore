import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' if (dart.library.html) '../interface/io_stub.dart';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../handler/logger.dart';
import '../interface/storage_interface.dart';
import '../model/db_exception.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import 'yield_controller.dart';

/// File system storage implementation for native platforms
class FileStorageImpl implements StorageInterface {
  FileStorageImpl();

  bool _closed = false;

  /// Set at the start of [close] to reject new [_getHandle] callers while
  /// in-flight opens are allowed to finish and enter the pool, then closed
  /// together. Avoids post-open close+throw (which races Windows rename).
  bool _closing = false;

  /// Number of [_getHandle] calls currently inside `File.open` / pool insert.
  int _opensInFlight = 0;

  // File handle pool with simple LRU eviction to reduce open/close overhead
  final Map<String, RandomAccessFile> _handlePool = {};
  final LinkedHashMap<String, DateTime> _lru =
      LinkedHashMap<String, DateTime>();
  int _maxOpenHandles = 128;

  // Dedicated handle pool for purely synchronous append channels (e.g. WAL direct-to-OS).
  // These handles NEVER execute asynchronous operations (raf.flush/read/writeFrom/close),
  // ensuring Dart VM's internal asyncOperationInProgress is strictly false and preventing
  // "An async operation is currently pending" collisions with background flushes.
  final Map<String, RandomAccessFile> _syncHandlePool = {};
  final LinkedHashMap<String, int> _syncLruTicks = LinkedHashMap<String, int>();
  int _syncTick = 0;
  static const int _maxOpenSyncHandles = 16;

  // Per-handle operation queues to serialize async operations on the same RandomAccessFile
  final Map<String, Future<void>> _handleLocks = {};
  // Cached physical file length per canonical path to avoid frequent raf.length() on hot write paths
  final Map<String, int> _fileLengths = {};

  String? _lastRawPath;
  String? _lastCanonicalPath;
  String _canonicalPath(String path) {
    if (identical(path, _lastRawPath) || path == _lastRawPath) {
      return _lastCanonicalPath!;
    }
    final res = p.canonicalize(path);
    _lastRawPath = path;
    _lastCanonicalPath = res;
    return res;
  }

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

  String _poolKey(String path, FileMode mode, [String? normalizedPath]) {
    final modeKey = (mode == FileMode.append)
        ? 'a'
        : (mode == FileMode.write)
            ? 'w'
            : (mode == FileMode.read)
                ? 'r'
                : mode.toString();
    final norm = normalizedPath ?? _canonicalPath(path);
    return '$norm|$modeKey';
  }

  /// Flush and close all open handles whose file paths are under [dirPath].
  /// Used before deleting a directory to avoid "file in use" errors
  /// (especially on Windows, where open handles block deletion).
  Future<void> _flushAndCloseHandlesUnderDirectory(String dirPath) async {
    try {
      final normalizedDir = _canonicalPath(dirPath);
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
            _fileLengths.remove(filePath);
          });
        } catch (_) {}

        final y1 = yieldController.maybeYield();
        if (y1 != null) await y1;
      }

      // Also cleanly flush and close all dedicated sync handles under dirPath
      final syncEntries = _syncHandlePool.entries.toList();
      for (final e in syncEntries) {
        final key = e.key;
        final raf = e.value;
        final sepIdx = key.lastIndexOf('|');
        if (sepIdx <= 0) continue;
        final filePath = key.substring(0, sepIdx);
        if (filePath != normalizedDir && !filePath.startsWith(dirPrefix)) {
          continue;
        }
        try {
          raf.flushSync();
          raf.closeSync();
        } catch (_) {}
        _syncHandlePool.remove(key);
        _syncLruTicks.remove(key);
        _fileLengths.remove(filePath);
      }
    } catch (_) {}
  }

  Future<RandomAccessFile> _getHandle(String path, FileMode mode) async {
    if (_closed || _closing) {
      throw DbClosedException('Storage is closed');
    }
    final key = _poolKey(path, mode);

    var existing = _handlePool[key];
    if (existing != null) {
      _lru[key] = DateTime.now();
      return existing;
    }

    final file = File(path);
    // Read path must not mkdir: missing files return empty bytes upstream.
    if (mode != FileMode.read) {
      await file.parent.create(recursive: true);
    }

    // Count in-flight opens so [close] can drain them into the pool and close
    // every handle together — no post-open close+throw (that caused rename /
    // cascade errors on Windows).
    _opensInFlight++;
    try {
      if (_closed || _closing) {
        throw DbClosedException('Storage is closed');
      }
      RandomAccessFile raf;
      try {
        raf = await file.open(mode: mode);
      } on PathNotFoundException {
        if (mode != FileMode.read) {
          // Defensive self-healing: re-ensure parent exists and retry once
          await file.parent.create(recursive: true);
          raf = await file.open(mode: mode);
        } else {
          rethrow;
        }
      }
      // Always pool; if close is draining, it will close this handle next.
      _handlePool[key] = raf;
      _lru[key] = DateTime.now();

      // Evict if exceeding threshold
      if (_handlePool.length > _maxOpenHandles) {
        // remove least-recently used
        final oldestKey = _lru.entries
            .reduce((a, b) => a.value.isBefore(b.value) ? a : b)
            .key;

        // Remove from pool immediately to prevent new ops from checking it out
        final rafToClose = _handlePool.remove(oldestKey);
        _lru.remove(oldestKey);
        final sepIdx = oldestKey.lastIndexOf('|');
        if (sepIdx > 0) {
          final oldestPath = oldestKey.substring(0, sepIdx);
          final bool hasOtherHandle =
              _handlePool.containsKey('$oldestPath|a') ||
                  _handlePool.containsKey('$oldestPath|r') ||
                  _handlePool.containsKey('$oldestPath|w');
          if (!hasOtherHandle) {
            _fileLengths.remove(oldestPath);
          }
        }

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
    } finally {
      _opensInFlight--;
    }
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
      Logger.error('Delete file failed', rawError: e);
      throw _wrapIoError(e, 'deleteFile', path);
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
      Logger.error('Delete directory failed', rawError: e);
      throw _wrapIoError(e, 'deleteDirectory', path);
    }
  }

  /// Check if a directory exists at the specified path
  @override
  Future<bool> existsDirectory(String path) async {
    try {
      return await Directory(path).exists();
    } catch (e) {
      Logger.error('Check directory exists failed', rawError: e);
      return false;
    }
  }

  /// Check if a file exists at the specified path
  @override
  Future<bool> existsFile(String path) async {
    try {
      return await File(path).exists();
    } catch (e) {
      Logger.error('Check file exists failed', rawError: e);
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
      Logger.error('List directory failed', rawError: e);
      return [];
    }
  }

  @override
  Future<void> close() async {
    // Reject new opens first; let in-flight opens finish and enter the pool,
    // then close every pooled handle. Do not open-then-close+throw in
    // [_getHandle] — that races Windows rename and floods close-path errors.
    _closing = true;
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (_opensInFlight > 0 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      _closed = true;

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
      _handleLocks.clear();

      // Flush and close all dedicated sync handles synchronously
      final syncEntries = _syncHandlePool.entries.toList();
      for (final e in syncEntries) {
        try {
          e.value.flushSync();
          e.value.closeSync();
        } catch (_) {}
      }
      _syncHandlePool.clear();
      _syncLruTicks.clear();
      _fileLengths.clear();
    } catch (e) {
      Logger.error('Close storage failed', rawError: e);
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

      final normalized = _canonicalPath(path);
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
            _fileLengths[normalized] = await raf.position();
          } catch (_) {}
        } finally {
          if (flush && closeHandleAfterFlush) {
            try {
              await raf.close();
            } catch (_) {}
            _handlePool.remove(key);
            _lru.remove(key);
            _fileLengths.remove(normalized);
          }
        }
      });
    } catch (e) {
      Logger.error('Write string failed', rawError: e);
      throw _wrapIoError(e, 'writeAsString', path);
    }
  }

  @override
  Future<void> writeAsBytes(String path, Uint8List bytes,
      {bool flush = true, bool closeHandleAfterFlush = false}) async {
    try {
      final normalized = _canonicalPath(path);
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
          _fileLengths[normalized] = bytes.length;
        } finally {
          if (flush && closeHandleAfterFlush) {
            try {
              await raf.close();
            } catch (_) {}
            _handlePool.remove(key);
            _lru.remove(key);
            _fileLengths.remove(normalized);
          }
        }
      });
    } catch (e) {
      Logger.error('Write bytes failed', rawError: e);
      throw _wrapIoError(e, 'writeAsBytes', path);
    }
  }

  @override
  Future<Uint8List> readAsBytes(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        return Uint8List(0);
      }
      return await file.readAsBytes();
    } catch (e) {
      Logger.error('Read bytes failed', rawError: e);
      throw _wrapIoError(e, 'readAsBytes', path);
    }
  }

  static bool _isFileNotFound(Object e) {
    final s = e.toString();
    return s.contains('PathNotFoundException') ||
        s.contains('No such file or directory') ||
        s.contains('errno = 2');
  }

  @override
  Future<Uint8List> readAsBytesAt(String path, int start, {int? length}) async {
    final normalized = _canonicalPath(path);
    final key = _poolKey(path, FileMode.read);
    try {
      return await _withHandleLock<Uint8List>(key, () async {
        final raf = await _getHandle(path, FileMode.read);
        int? fileSize = _fileLengths[normalized];
        final int targetEnd = length != null ? start + length : start + 1;
        if (fileSize == null || targetEnd > fileSize) {
          try {
            fileSize = await raf.length();
            _fileLengths[normalized] = fileSize;
          } catch (_) {
            fileSize = 0;
          }
        }
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
      Logger.error('Read bytes at offset failed', rawError: e);
      return Uint8List(0);
    }
  }

  @override
  Future<List<Uint8List>> readManyAsBytesAt(
    String path,
    List<ByteReadRange> ranges,
  ) async {
    if (ranges.isEmpty) return const [];
    final normalized = _canonicalPath(path);
    final key = _poolKey(path, FileMode.read);
    try {
      return await _withHandleLock<List<Uint8List>>(key, () async {
        final raf = await _getHandle(path, FileMode.read);
        int? fileSize = _fileLengths[normalized];
        if (fileSize == null) {
          try {
            fileSize = await raf.length();
            _fileLengths[normalized] = fileSize;
          } catch (_) {
            fileSize = 0;
          }
        }

        final results = List<Uint8List>.filled(ranges.length, Uint8List(0),
            growable: false);
        for (int i = 0; i < ranges.length; i++) {
          final r = ranges[i];
          final start = r.offset;
          final length = r.length;
          if (start < 0 || length <= 0) continue;
          if (fileSize != null && start + length > fileSize) {
            try {
              fileSize = await raf.length();
              _fileLengths[normalized] = fileSize;
            } catch (_) {}
          }
          if (start >= fileSize!) continue;
          final readLen =
              (start + length > fileSize) ? fileSize - start : length;
          if (readLen <= 0) continue;
          await raf.setPosition(start);
          results[i] = await raf.read(readLen);
        }
        return results;
      });
    } catch (e) {
      if (_isFileNotFound(e)) {
        return List<Uint8List>.filled(ranges.length, Uint8List(0),
            growable: false);
      }
      Logger.error('Batch read bytes at offset failed', rawError: e);
      return List<Uint8List>.filled(ranges.length, Uint8List(0),
          growable: false);
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
        throw DbException([
          InvalidArgumentStatus(
            type: ResultType.engError,
            message: 'Offset must be >= 0, got ${s.offset}',
            parameterName: 'offset',
          ),
        ]);
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
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message: 'Overlapping write spans for $path',
          ),
        ]);
      }
      lastEnd = s.offset + s.bytes.length;
    }
    try {
      // Always use pooled handle for random writes to enable delayed flush batching.
      // Use FileMode.append to avoid truncation while allowing random access seeking.
      final normalized = _canonicalPath(path);
      final key = _poolKey(path, FileMode.append);
      await _withHandleLock<void>(key, () async {
        final raf = await _getHandle(path, FileMode.append);
        try {
          int? cachedLen = _fileLengths[normalized];
          if (cachedLen == null) {
            try {
              cachedLen = await raf.length();
            } catch (_) {
              cachedLen = 0;
            }
            _fileLengths[normalized] = cachedLen;
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

          // Update cached length (authoritative).
          _fileLengths[normalized] = maxEnd;
        } finally {
          if (flush && closeHandleAfterFlush) {
            try {
              await raf.close();
            } catch (_) {}
            _handlePool.remove(key);
            _lru.remove(key);
            _fileLengths.remove(normalized);
          }
        }
      });
    } catch (e) {
      Logger.error('Write many bytes at offsets failed', rawError: e);
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
      Logger.error('Read string failed', rawError: e);
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
      Logger.error('Get file creation time failed', rawError: e);
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
      Logger.error('Copy directory failed', rawError: e);
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
        throw DbException([
          GeneralStatus(
            type: ResultType.sysIoGeneric,
            message: 'Destination directory already exists: $destinationPath',
            operation: 'moveDirectory',
            target: destinationPath,
          ),
        ]);
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
      Logger.error('Move directory failed', rawError: e);
      throw _wrapIoError(e, 'moveDirectory', '$sourcePath -> $destinationPath');
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
      Logger.error('Copy file failed', rawError: e);
      throw _wrapIoError(e, 'copyFile', '$sourcePath -> $destinationPath');
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
        Logger.error('Write lines stream failed: $path', rawError: e);
        throw _wrapIoError(e, 'writeLinesStream', path);
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
    try {
      final normalized = _canonicalPath(path);
      final key = _poolKey(path, FileMode.append);
      return await _withHandleLock<int>(key, () async {
        final raf = await _getHandle(path, FileMode.append);
        int? cached = _fileLengths[normalized];
        if (cached == null) {
          cached = await raf.length();
          _fileLengths[normalized] = cached;
        }
        final offset = cached;
        await raf.setPosition(offset);
        await raf.writeFrom(bytes);
        if (flush) {
          await raf.flush();
        }
        _fileLengths[normalized] = offset + bytes.length;
        if (flush && closeHandleAfterFlush) {
          await raf.close();
          _handlePool.remove(key);
          _lru.remove(key);
          _fileLengths.remove(normalized);
        }
        return offset;
      });
    } catch (e) {
      throw _wrapIoError(e, 'appendBytes', path);
    }
  }

  @override
  int appendBytesSync(String path, List<int> bytes,
      {int offset = 0, int? length}) {
    if (_closed || _closing) {
      throw DbClosedException('Storage is closed');
    }
    final normalized = _canonicalPath(path);
    final key = _poolKey(path, FileMode.append, normalized);

    RandomAccessFile? raf = _syncHandlePool[key];
    try {
      if (raf == null) {
        final file = File(path);
        if (!file.parent.existsSync()) {
          file.parent.createSync(recursive: true);
        }
        raf = file.openSync(mode: FileMode.append);
        _syncHandlePool[key] = raf;
        _syncLruTicks[key] = ++_syncTick;

        // Evict oldest sync handle if pool exceeds limit to prevent handle leak
        if (_syncHandlePool.length > _maxOpenSyncHandles) {
          final oldestSyncKey = _syncLruTicks.entries
              .reduce((a, b) => a.value < b.value ? a : b)
              .key;
          if (oldestSyncKey != key) {
            final oldRaf = _syncHandlePool.remove(oldestSyncKey);
            _syncLruTicks.remove(oldestSyncKey);
            if (oldRaf != null) {
              try {
                oldRaf.flushSync();
                oldRaf.closeSync();
              } catch (_) {}
            }
          }
        }
      } else {
        _syncLruTicks[key] = ++_syncTick;
      }

      int? cached = _fileLengths[normalized];
      if (cached == null) {
        cached = raf.lengthSync();
        _fileLengths[normalized] = cached;
      }

      final writeOffset = cached;
      final int toWrite = (length ?? bytes.length) - offset;
      if (toWrite > 0) {
        raf.writeFromSync(bytes, offset, offset + toWrite);
        _fileLengths[normalized] = writeOffset + toWrite;
      }
      return writeOffset;
    } catch (e) {
      _syncHandlePool.remove(key);
      _syncLruTicks.remove(key);
      if (raf != null) {
        try {
          raf.closeSync();
        } catch (_) {}
      }
      throw _wrapIoError(e, 'appendBytesSync', path);
    }
  }

  @override
  Future<int> appendString(String path, String content,
      {bool flush = true, bool closeHandleAfterFlush = false}) async {
    try {
      final normalized = _canonicalPath(path);
      final key = _poolKey(path, FileMode.append);
      return await _withHandleLock<int>(key, () async {
        final raf = await _getHandle(path, FileMode.append);
        int? cached = _fileLengths[normalized];
        if (cached == null) {
          cached = await raf.length();
          _fileLengths[normalized] = cached;
        }
        final offset = cached;
        await raf.setPosition(offset);
        await raf.writeString(content);
        if (flush) {
          await raf.flush();
        }
        try {
          _fileLengths[normalized] = await raf.position();
        } catch (_) {}
        if (flush && closeHandleAfterFlush) {
          await raf.close();
          _handlePool.remove(key);
          _lru.remove(key);
          _fileLengths.remove(normalized);
        }
        return offset;
      });
    } catch (e) {
      throw _wrapIoError(e, 'appendString', path);
    }
  }

  @override
  Future<List<String>> readAsLines(String path, {int offset = 0}) async {
    final stream = readLinesStream(path, offset: offset);
    return await stream.toList();
  }

  @override
  Future<void> flushFile(String path) async {
    try {
      final normalizedPath = _canonicalPath(path);
      final syncRaf = _syncHandlePool['$normalizedPath|a'];
      if (syncRaf != null) {
        try {
          syncRaf.flushSync();
        } catch (_) {}
      }
      // Direct O(1) key lookups for writable modes avoid iterating hundreds of pooled handles
      final appendKey = '$normalizedPath|a';
      final appendRaf = _handlePool[appendKey];
      if (appendRaf != null) {
        await _withHandleLock(appendKey, () async {
          try {
            await appendRaf.flush();
          } catch (_) {}
        });
      }
      final writeKey = '$normalizedPath|w';
      final writeRaf = _handlePool[writeKey];
      if (writeRaf != null) {
        await _withHandleLock(writeKey, () async {
          try {
            await writeRaf.flush();
          } catch (_) {}
        });
      }
    } catch (e) {
      Logger.error('Flush file failed', rawError: e);
      rethrow;
    }
  }

  @override
  void flushFileSync(String path) {
    try {
      final normalizedPath = _canonicalPath(path);
      // 1. Flush dedicated sync handle (used by appendBytesSync)
      final syncRaf = _syncHandlePool['$normalizedPath|a'];
      if (syncRaf != null) {
        try {
          syncRaf.flushSync();
        } catch (_) {}
      }
      // 2. Direct O(1) handle lookups for writable modes, eliminating O(N) handle pool iteration
      final appendRaf = _handlePool['$normalizedPath|a'];
      if (appendRaf != null) {
        try {
          appendRaf.flushSync();
        } catch (_) {}
      }
      final writeRaf = _handlePool['$normalizedPath|w'];
      if (writeRaf != null) {
        try {
          writeRaf.flushSync();
        } catch (_) {}
      }
    } catch (e) {
      Logger.error('Flush file sync failed', rawError: e);
    }
  }

  @override
  void deleteFileSync(String path) {
    try {
      final normalizedPath = _canonicalPath(path);
      // 1. Close and remove dedicated sync handle
      final syncKey = '$normalizedPath|a';
      final syncRaf = _syncHandlePool.remove(syncKey);
      _syncLruTicks.remove(syncKey);
      if (syncRaf != null) {
        try {
          syncRaf.flushSync();
          syncRaf.closeSync();
        } catch (_) {}
      }
      // 2. Close and remove from general handle pool if present
      for (final mode in const ['a', 'w', 'r']) {
        final key = '$normalizedPath|$mode';
        final raf = _handlePool.remove(key);
        _lru.remove(key);
        if (raf != null) {
          try {
            raf.flushSync();
            raf.closeSync();
          } catch (_) {}
        }
      }
      // 3. Delete physical file if it exists
      final file = File(path);
      if (file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {}
      }
    } catch (e) {
      Logger.error('Delete file sync failed', rawError: e);
    }
  }

  @override
  Future<void> flushAll(
      {String? path, List<String>? paths, bool closeHandles = false}) async {
    const candidateModes = [FileMode.read, FileMode.write, FileMode.append];
    try {
      // 1. Flush/close dedicated sync handles purely synchronously.
      // Since these handles NEVER invoke async operations, they never set
      // _asyncOperationInProgress and are completely isolated from async handle locks.
      if (path != null) {
        final normalized = _canonicalPath(path);
        final syncKey = _poolKey(normalized, FileMode.append);
        final syncRaf = _syncHandlePool[syncKey];
        if (syncRaf != null) {
          try {
            syncRaf.flushSync();
          } catch (_) {}
          if (closeHandles) {
            try {
              syncRaf.closeSync();
            } catch (_) {}
            _syncHandlePool.remove(syncKey);
            _syncLruTicks.remove(syncKey);
            _fileLengths.remove(normalized);
          }
        }
      } else if (paths != null && paths.isNotEmpty) {
        for (final pth in paths) {
          final normalized = _canonicalPath(pth);
          final syncKey = _poolKey(normalized, FileMode.append);
          final syncRaf = _syncHandlePool[syncKey];
          if (syncRaf != null) {
            try {
              syncRaf.flushSync();
            } catch (_) {}
            if (closeHandles) {
              try {
                syncRaf.closeSync();
              } catch (_) {}
              _syncHandlePool.remove(syncKey);
              _syncLruTicks.remove(syncKey);
              _fileLengths.remove(normalized);
            }
          }
        }
      } else if (path == null && paths == null) {
        final syncEntries = _syncHandlePool.entries.toList();
        for (final e in syncEntries) {
          try {
            e.value.flushSync();
          } catch (_) {}
          if (closeHandles) {
            try {
              e.value.closeSync();
            } catch (_) {}
            final sepIdx = e.key.lastIndexOf('|');
            if (sepIdx > 0) {
              _fileLengths.remove(e.key.substring(0, sepIdx));
            }
          }
        }
        if (closeHandles) {
          _syncHandlePool.clear();
          _syncLruTicks.clear();
        }
      }

      if (paths != null && paths.isNotEmpty) {
        final yieldController = YieldController('storage_flush_paths');
        for (final pth in paths) {
          final normalized = _canonicalPath(pth);
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
                  _fileLengths.remove(normalized);
                }
              });
            }
          }
          final y2 = yieldController.maybeYield();
          if (y2 != null) await y2;
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
              final sepIdx = key.lastIndexOf('|');
              if (sepIdx > 0) {
                _fileLengths.remove(key.substring(0, sepIdx));
              }
            }
          });
          final y3 = yieldController.maybeYield();
          if (y3 != null) await y3;
        }
      } else {
        final normalized = _canonicalPath(path);
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
                _fileLengths.remove(normalized);
              }
            });
          }
        }
      }
    } catch (e) {
      Logger.error('Flush all failed', rawError: e);
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
        throw DbException([
          GeneralStatus(
            type: ResultType.sysIoNotFound,
            message: 'Temporary file does not exist: $tempPath',
            target: tempPath,
            operation: 'replaceFileAtomic',
          )
        ]);
      }
      await flushAll(path: finalPath, closeHandles: true);
      await flushAll(path: tempPath, closeHandles: true);

      const retryDelays = [50, 150, 400, 800, 1500];
      for (int attempt = 0; attempt <= retryDelays.length; attempt++) {
        try {
          // Ensure parent directory exists
          final finalFile = File(finalPath);
          if (!await finalFile.parent.exists()) {
            await finalFile.parent.create(recursive: true);
          }

          // Directly attempt atomic rename first (atomic overwrite on POSIX and Win32 MoveFileEx)
          try {
            await tmpFile.rename(finalPath);
            return;
          } catch (e) {
            if (Platform.isWindows && e is FileSystemException) {
              // On Windows, sharing violations (32) or access denied (5)
              // often mean handles are still closing. Flush and retry.
              await flushAll(path: finalPath, closeHandles: true);
              await flushAll(path: tempPath, closeHandles: true);
              await Future.delayed(const Duration(milliseconds: 20));

              // If direct rename still fails on late attempts, fallback to delete + rename
              if (attempt >= 2) {
                if (await finalFile.exists()) {
                  try {
                    await finalFile.delete();
                  } catch (_) {}
                }
              }
              await tmpFile.rename(finalPath);
              return;
            } else {
              rethrow;
            }
          }
        } on FileSystemException catch (e) {
          if (attempt >= retryDelays.length) {
            rethrow;
          }
          // Log transient error but continue retrying
          Logger.warn('Atomic replace transient failure (attempt $attempt)',
              rawError: e);

          await flushAll(path: finalPath, closeHandles: true);
          await flushAll(path: tempPath, closeHandles: true);
          await Future.delayed(Duration(milliseconds: retryDelays[attempt]));
        }
      }
    } catch (e) {
      Logger.error('Atomic replace failed', rawError: e);
      throw _wrapIoError(e, 'replaceFileAtomic', '$tempPath -> $finalPath');
    }
  }

  DbException _wrapIoError(Object e, String operation, String path) {
    ResultType type = ResultType.sysIoGeneric;
    String message = e.toString();

    if (e is FileSystemException) {
      final osCode = e.osError?.errorCode;
      final osMsg = e.osError?.message ?? '';
      final lowerMsg = '${osMsg.toLowerCase()} ${e.message.toLowerCase()}';

      bool isNotFound = false;
      bool isPermission = false;
      bool isDiskFull = false;
      bool isLocked = false;
      bool isDeviceFault = false;

      if (osCode != null) {
        if (Platform.isWindows) {
          isNotFound = (osCode == 2 || osCode == 3);
          isPermission = (osCode == 5 || osCode == 19);
          isDiskFull = (osCode == 112 || osCode == 39);
          isLocked = (osCode == 32 || osCode == 33);
          isDeviceFault = (osCode == 29 || osCode == 30 || osCode == 31);
        } else {
          // POSIX errno (macOS, Linux, iOS, Android)
          isNotFound = (osCode == 2 || osCode == 20); // ENOENT, ENOTDIR
          isPermission = (osCode == 13 || osCode == 1); // EACCES, EPERM
          isDiskFull = (osCode == 28); // ENOSPC
          isLocked = (osCode == 11 ||
              osCode == 35 ||
              osCode == 37 ||
              osCode == 16); // EAGAIN/EWOULDBLOCK, EDEADLK, ENOLCK, EBUSY
          isDeviceFault = (osCode == 5 ||
              osCode == 6 ||
              osCode == 19); // EIO, ENXIO, ENODEV
        }
      }

      if (isNotFound ||
          lowerMsg.contains('no such file') ||
          lowerMsg.contains('pathnotfoundexception') ||
          lowerMsg.contains('does not exist') ||
          lowerMsg.contains('not exist')) {
        type = ResultType.sysIoNotFound;
      } else if (isPermission ||
          lowerMsg.contains('permission denied') ||
          lowerMsg.contains('access is denied') ||
          lowerMsg.contains('operation not permitted')) {
        type = ResultType.sysIoPermissionDenied;
      } else if (isDiskFull ||
          lowerMsg.contains('no space left') ||
          lowerMsg.contains('disk full') ||
          lowerMsg.contains('quota exceeded')) {
        type = ResultType.sysIoDiskFull;
      } else if (isLocked ||
          lowerMsg.contains('sharing violation') ||
          lowerMsg.contains('lock') ||
          lowerMsg.contains('resource temporarily unavailable') ||
          lowerMsg.contains('file is locked')) {
        type = ResultType.sysIoFileLocked;
      } else if (isDeviceFault ||
          lowerMsg.contains('hardware') ||
          lowerMsg.contains('io error') ||
          lowerMsg.contains('i/o error') ||
          lowerMsg.contains('device fault')) {
        type = ResultType.sysIoDeviceFault;
      }
      message = '${e.message} (OS Error: $osMsg, errno = $osCode)';
    }

    final status = GeneralStatus(
      type: type,
      message: 'IO error during $operation on $path: $message',
      target: path,
      operation: operation,
    );
    return DbException([status]);
  }
}

final class _WriteSpan {
  final int offset;
  final Uint8List bytes;
  final int order;
  _WriteSpan({required this.offset, required this.bytes, required this.order});
}
