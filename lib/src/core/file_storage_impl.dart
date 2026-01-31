import 'dart:async';
import 'dart:io' if (dart.library.html) '../Interface/io_stub.dart';
import 'dart:convert';
import 'dart:collection';
import 'dart:typed_data';
import '../handler/common.dart';

import '../Interface/storage_interface.dart';
import '../handler/logger.dart';
import 'package:path/path.dart' as p;
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
            : mode.toString();
    return '${p.normalize(path)}|$modeKey';
  }

  bool _isRecoveryArtifact(String path) {
    final normalized = p.normalize(path).replaceAll('\\', '/');
    if (normalized.endsWith('.log')) {
      return true; // WAL partitions and parallel journal
    }
    if (normalized.endsWith('/wal/meta.json') ||
        normalized.contains('/wal/meta.json')) {
      return true; // WAL meta
    }
    return false;
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
      try {
        await _handlePool[oldestKey]?.flush();
        await _handlePool[oldestKey]?.close();
      } catch (_) {}
      _handlePool.remove(oldestKey);
      _lru.remove(oldestKey);
      _handleLengths.remove(oldestKey);
    }

    return raf;
  }

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
            } catch (_) {}
            try {
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

      // Serialize operations on the same file (by logical key) to avoid
      // concurrent async ops.
      final key = _poolKey(path, FileMode.write);
      final usePooled = _isRecoveryArtifact(path);
      await _withHandleLock(key, () async {
        if (usePooled) {
          final raf = await _getHandle(path, FileMode.write);
          try {
            await raf.truncate(0);
            await raf.setPosition(0);
            await raf.writeString(content);
            if (flush) {
              await raf.flush();
            }
            // Update cached length precisely using current file position
            try {
              final pos = await raf.position();
              _handleLengths[key] = pos;
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
        } else {
          // Non-recovery artifact: use a short-lived handle (flush applies).
          final file = File(path);
          await file.parent.create(recursive: true);
          final raf = await file.open(mode: FileMode.write);
          try {
            await raf.truncate(0);
            await raf.setPosition(0);
            await raf.writeString(content);
            if (flush) {
              await raf.flush();
            }
          } finally {
            try {
              await raf.close();
            } catch (_) {}
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
      final usePooled = _isRecoveryArtifact(path);
      await _withHandleLock(key, () async {
        if (usePooled) {
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
        } else {
          // Non-recovery artifact: short-lived handle; flush applies if requested.
          final file = File(path);
          await file.parent.create(recursive: true);
          final raf = await file.open(mode: FileMode.write);
          try {
            await raf.truncate(0);
            await raf.setPosition(0);
            await raf.writeFrom(bytes);
            if (flush) {
              await raf.flush();
            }
          } finally {
            try {
              await raf.close();
            } catch (_) {}
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
    if (!await file.exists()) return Uint8List(0);
    return await file.readAsBytes();
  }

  @override
  Future<Uint8List> readAsBytesAt(String path, int start, {int? length}) async {
    try {
      final file = File(path);
      if (!await file.exists()) return Uint8List(0);

      final fileSize = await file.length();
      if (start >= fileSize) return Uint8List(0);

      final end = length != null
          ? (start + length > fileSize ? fileSize : start + length)
          : fileSize;

      // Use openRead with start and end to read only the needed portion
      final stream = file.openRead(start, end);
      final bytes = <int>[];
      await for (final chunk in stream) {
        bytes.addAll(chunk);
      }

      return Uint8List.fromList(bytes);
    } catch (e) {
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
    if (bytes.isEmpty) return;
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
    if (writes.isEmpty) return;

    // Validate and copy for sorting without mutating caller list.
    final items = <_WriteSpan>[
      for (int i = 0; i < writes.length; i++)
        _WriteSpan(offset: writes[i].offset, bytes: writes[i].bytes, order: i),
    ];
    for (final s in items) {
      if (s.offset < 0) {
        throw ArgumentError.value(s.offset, 'offset', 'must be >= 0');
      }
    }

    // Sort by offset; tie-break by original order for determinism.
    items.sort((a, b) {
      final c = a.offset.compareTo(b.offset);
      return c != 0 ? c : a.order.compareTo(b.order);
    });

    // Strict overlap check (database-grade determinism).
    int lastEnd = -1;
    for (final s in items) {
      if (s.bytes.isEmpty) continue;
      if (lastEnd >= 0 && s.offset < lastEnd) {
        throw StateError(
            'Overlapping write spans for $path: offset=${s.offset} < lastEnd=$lastEnd');
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
            if (data.isEmpty) continue;

            if (currentPos != s.offset) {
              await raf.setPosition(s.offset);
              currentPos = s.offset;
            }
            await raf.writeFrom(data);
            currentPos += data.length;
            if (currentPos > maxEnd) maxEnd = currentPos;
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
      Logger.error('Write bytes at offsets failed: $e',
          label: 'FileStorageImpl.writeManyAsBytesAt');
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

  @override
  Future<int> appendBytes(String path, Uint8List bytes,
      {bool flush = true, bool closeHandleAfterFlush = false}) async {
    try {
      final key = _poolKey(path, FileMode.append);
      return await _withHandleLock<int>(key, () async {
        final raf = await _getHandle(path, FileMode.append);
        try {
          // Initialize cached length lazily to avoid repeated length() calls
          int? cached = _handleLengths[key];
          if (cached == null) {
            try {
              cached = await raf.length();
            } catch (_) {
              cached = 0;
            }
            _handleLengths[key] = cached;
          }
          final offset = cached;
          // IMPORTANT: Do not assume file position is at EOF.
          // Other operations (e.g., random writes) may have moved it.
          try {
            await raf.setPosition(offset);
          } catch (_) {}
          await raf.writeFrom(bytes);
          if (flush) {
            await raf.flush();
          }
          _handleLengths[key] = cached + bytes.length;
          if (flush && closeHandleAfterFlush) {
            try {
              await raf.close();
            } catch (_) {}
            _handlePool.remove(key);
            _lru.remove(key);
            _handleLengths.remove(key);
          }
          return offset;
        } catch (e) {
          _handleLengths.remove(key);
          rethrow;
        }
      });
    } catch (e) {
      Logger.error('Append bytes failed: $e', label: 'FileStorageImpl');
      rethrow;
    }
  }

  @override
  Future<int> appendString(String path, String content,
      {bool flush = true, bool closeHandleAfterFlush = false}) async {
    try {
      final key = _poolKey(path, FileMode.append);
      return await _withHandleLock<int>(key, () async {
        final raf = await _getHandle(path, FileMode.append);
        try {
          // Initialize cached length lazily to avoid repeated length() calls
          int? cached = _handleLengths[key];
          if (cached == null) {
            try {
              cached = await raf.length();
            } catch (_) {
              cached = 0;
            }
            _handleLengths[key] = cached;
          }
          final offset = cached;
          // IMPORTANT: Do not assume file position is at EOF.
          try {
            await raf.setPosition(offset);
          } catch (_) {}
          await raf.writeString(content);
          if (flush) {
            await raf.flush();
          }
          // Update cached length using current file position for accuracy
          try {
            final pos = await raf.position();
            _handleLengths[key] = pos;
          } catch (_) {
            // Fallback to approximate increment by content bytes if position() fails
            try {
              _handleLengths[key] = offset + utf8.encode(content).length;
            } catch (_) {}
          }
          return offset;
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
      Logger.error('Append string failed: $e', label: 'FileStorageImpl');
      rethrow;
    }
  }

  @override
  Future<List<String>> readAsLines(String path, {int offset = 0}) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        return [];
      }
      // openRead can create a read stream starting from a specified byte offset
      return file
          .openRead(offset)
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .toList();
    } catch (e) {
      Logger.error('Read as lines failed: $e', label: 'FileStorageImpl');
      return [];
    }
  }

  @override
  Future<void> flushAll(
      {String? path, List<String>? paths, bool closeHandles = false}) async {
    try {
      if (paths != null && paths.isNotEmpty) {
        final yieldController = YieldController('storage_flush_paths');
        for (final pth in paths) {
          final normalized = p.normalize(pth);
          const List<FileMode> candidateModes = [
            FileMode.write,
            FileMode.append
          ];
          for (final mode in candidateModes) {
            final key = _poolKey(normalized, mode);
            final raf = _handlePool[key];
            if (raf != null) {
              try {
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
              } catch (_) {}
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
          try {
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
          } catch (_) {}
          await yieldController.maybeYield();
        }
      } else {
        final normalized = p.normalize(path);
        // Try the two common modes directly to avoid scanning the entire pool
        const List<FileMode> candidateModes = [FileMode.write, FileMode.append];
        for (final mode in candidateModes) {
          final key = _poolKey(normalized, mode);
          final raf = _handlePool[key];
          if (raf != null) {
            try {
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
            } catch (_) {}
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
        throw FileSystemException('Temp file does not exist', tempPath);
      }
      // Ensure destination directory exists
      await Directory(p.dirname(finalPath)).create(recursive: true);
      try {
        // Attempt atomic rename (same volume)
        await tmpFile.rename(finalPath);
      } on FileSystemException catch (_) {
        // Fallback: delete destination first (best-effort), then rename
        try {
          final dst = File(finalPath);
          if (await dst.exists()) {
            await dst.delete();
          }
        } catch (_) {}
        await tmpFile.rename(finalPath);
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
