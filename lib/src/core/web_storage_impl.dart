import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart';
import '../handler/logger.dart';
import 'dart:convert';
import '../handler/common.dart';
import 'yield_controller.dart';

import '../Interface/storage_interface.dart';
import '../model/meta_info.dart';

/// Web platform storage adapter implementation
class WebStorageImpl implements StorageInterface {
  static final Map<String, WebStorageImpl> _instances = {};
  IDBDatabase? _db;
  final Completer<void> _initCompleter = Completer<void>();

  // In-memory write buffer to simulate OS page cache on web.
  // Key: normalized path
  final Map<String, _BufferedEntry> _writeBuffer = {};

  // store type
  static const String _fileStore = 'files'; // file storage（meta data）

  factory WebStorageImpl(String dbName) {
    return _instances.putIfAbsent(
        dbName, () => WebStorageImpl._internal(dbName));
  }

  WebStorageImpl._internal(String dbName) {
    _initDB(dbName);
  }

  Future<void> _initDB(String dbName) async {
    try {
      final request = window.indexedDB.open(dbName, 1);

      request.onupgradeneeded = ((Event event) {
        final db = request.result as IDBDatabase;

        // create file store
        if (!db.objectStoreNames.contains(_fileStore)) {
          final store = db.createObjectStore(
              _fileStore,
              IDBObjectStoreParameters(
                  keyPath: 'path'.toJS, autoIncrement: false));
          // add file path index
          store.createIndex('by_path', 'path'.toJS);
          // add name index
          store.createIndex('by_name', 'meta.name'.toJS);
        }
      }).toJS;

      request.onsuccess = ((Event event) {
        _db = request.result as IDBDatabase;
        if (!_initCompleter.isCompleted) {
          _initCompleter.complete();
        }
      }).toJS;

      request.onerror = ((Event event) {
        final error =
            request.error ?? 'Unknown error during database initialization';
        Logger.error('Database open failed: $error',
            label: 'WebStorageAdapter');
        if (!_initCompleter.isCompleted) {
          _initCompleter.completeError(error);
        }
      }).toJS;

      await _initCompleter.future;
    } catch (e) {
      Logger.error('IndexedDB init failed: $e', label: 'WebStorageAdapter');
      rethrow;
    }
  }

  /// get file type
  FileType _getFileType(String path) {
    if (path.endsWith('.dat')) return FileType.data;
    if (path.contains('schema.')) return FileType.schema;
    if (path.endsWith('.idx')) return FileType.idx;
    if (path.endsWith('.log')) return FileType.log;
    return FileType.other;
  }

  /// list directory content
  @override
  Future<List<String>> listDirectory(String path,
      {bool recursive = false}) async {
    await _initCompleter.future;

    try {
      if (_db == null) throw Exception('Database not initialized');

      final normalizedPath = _normalizePath(path);

      final transaction =
          _db!.transaction([_fileStore].jsify() as JSArray, 'readonly');
      final store = transaction.objectStore(_fileStore);
      final index = store.index('by_path');

      // use index range query
      final range = IDBKeyRange.bound(
        '$normalizedPath/'.toJS,
        '$normalizedPath/\uffff'.toJS,
        false,
        false,
      );

      final request = index.getAllKeys(range);
      final allKeys = await _wrapRequest<JSArray>(request);
      final allPathsSet = allKeys.toDart
          .cast<String>()
          .where((key) => !key.contains('.block'))
          .toSet();

      // Overlay buffered (unflushed) files so listing reflects in-memory state
      for (final p in _writeBuffer.keys) {
        if (p == normalizedPath) continue;
        if (p == normalizedPath || p.startsWith('$normalizedPath/')) {
          allPathsSet.add(p);
        }
      }
      final allPaths = allPathsSet.toList();

      // if recursive mode, return all paths directly
      if (recursive) {
        return allPaths;
      }

      // non-recursive mode: only return direct children
      final directChildren = <String>{};

      for (final path in allPaths) {
        // skip self path
        if (path == normalizedPath) continue;

        // remove base path prefix
        String relativePath = path;
        if (path.startsWith('$normalizedPath/')) {
          relativePath = path.substring(normalizedPath.length + 1);
        }

        // split path and take the first segment as direct child
        final segments = relativePath.split('/');
        if (segments.isNotEmpty && segments[0].isNotEmpty) {
          // add full path to result
          final directChildPath = '$normalizedPath/${segments[0]}';
          directChildren.add(directChildPath);
        }
      }

      return directChildren.toList();
    } catch (e) {
      Logger.error('List directory failed: $e', label: 'WebStorageAdapter');
      return [];
    }
  }

  /// delete file
  @override
  Future<void> deleteFile(String path) async {
    await _initCompleter.future;

    try {
      if (_db == null) throw Exception('Database not initialized');
      final normalizedPath = _normalizePath(path);
      // Drop from buffer first
      _writeBuffer.remove(normalizedPath);
      final transaction =
          _db!.transaction([_fileStore].jsify() as JSArray, 'readwrite');
      final store = transaction.objectStore(_fileStore);

      // delete file itself
      await _wrapRequest(store.delete(normalizedPath.toJS));
    } catch (e) {
      Logger.error('Delete file failed: $e', label: 'WebStorageImpl');
      rethrow;
    }
  }

  /// delete directory and all its contents
  @override
  Future<void> deleteDirectory(String path) async {
    await _initCompleter.future;

    try {
      if (_db == null) throw Exception('Database not initialized');

      final normalizedPath = _normalizePath(path);
      final transaction =
          _db!.transaction([_fileStore].jsify() as JSArray, 'readwrite');
      final store = transaction.objectStore(_fileStore);
      final index = store.index('by_path');

      // Use index range query to find all files within this directory
      final range = IDBKeyRange.bound(
        '$normalizedPath/'.toJS,
        '$normalizedPath/\uffff'.toJS,
        false,
        false,
      );

      // Get all keys in this directory
      final request = index.getAllKeys(range);
      final keys = await _wrapRequest<JSArray>(request);
      final filePaths = keys.toDart.cast<String>().toList();

      // Delete all files within this directory
      for (var filePath in filePaths) {
        await deleteFile(filePath);
      }

      // Also remove buffered entries under this directory
      final toRemove = <String>[];
      for (final p in _writeBuffer.keys) {
        if (p.startsWith('$normalizedPath/')) {
          toRemove.add(p);
        }
      }
      for (final p in toRemove) {
        _writeBuffer.remove(p);
      }
    } catch (e) {
      Logger.error('Delete directory failed: $e', label: 'WebStorageImpl');
      rethrow;
    }
  }

  /// check file exists
  @override
  Future<bool> existsFile(String path) async {
    await _initCompleter.future;

    try {
      if (_db == null) throw Exception('Database not initialized');

      final normalizedPath = _normalizePath(path);

      // If there is a pending buffered entry, consider file existing
      if (_writeBuffer.containsKey(normalizedPath)) {
        return true;
      }

      final transaction =
          _db!.transaction([_fileStore].jsify() as JSArray, 'readonly');
      final store = transaction.objectStore(_fileStore);

      final result = await _wrapRequest<JSAny?>(store.get(normalizedPath.toJS));
      return result != null;
    } catch (e) {
      Logger.error('Check file exists failed: $e', label: 'WebStorageAdapter');
      return false;
    }
  }

  @override
  Future<bool> existsDirectory(String path) async {
    await _initCompleter.future;

    try {
      if (_db == null) throw Exception('Database not initialized');

      final normalizedPath = _normalizePath(path);

      final transaction =
          _db!.transaction([_fileStore].jsify() as JSArray, 'readonly');
      final store = transaction.objectStore(_fileStore);
      final index = store.index('by_path');

      // use index range query, check if the key exists with this path prefix
      final range = IDBKeyRange.bound(
        '$normalizedPath/'.toJS,
        '$normalizedPath/\uffff'.toJS,
        false,
        false,
      );

      final request =
          index.getAllKeys(range, 1); // limit to only one key for performance
      final keys = await _wrapRequest<JSArray>(request);
      final existsOnDisk = keys.toDart.isNotEmpty;

      if (existsOnDisk) return true;

      // Check buffered entries for any path under this directory
      for (final p in _writeBuffer.keys) {
        if (p.startsWith('$normalizedPath/')) return true;
      }
      return false;
    } catch (e) {
      Logger.error('Check directory exists failed: $e',
          label: 'WebStorageAdapter');
      return false;
    }
  }

  /// simple JSON object evaluation
  dynamic eval(String jsonStr) {
    // should use safer JSON parsing method
    // current implementation is for demonstration only
    return jsonStr;
  }

  /// wrap IndexedDB request to Future
  Future<T> _wrapRequest<T>(IDBRequest request) {
    final completer = Completer<T>();

    request.onsuccess = ((Event event) {
      completer.complete(request.result as T);
    }).toJS;

    request.onerror = ((Event event) {
      completer.completeError(request.error ?? 'Unknown error');
    }).toJS;

    return completer.future;
  }

  /// close database connection
  @override
  Future<void> close() async {
    await _initCompleter.future; // ensure database is initialized

    try {
      // Ensure buffered data is flushed before closing
      try {
        await flushAll();
      } catch (e) {
        Logger.warn('Flush on close failed: $e', label: 'WebStorageAdapter');
      }

      if (_db == null) throw Exception('Database not initialized');
      _db!.close();
      _instances.remove(_db!.name);
    } catch (e) {
      Logger.error('Close database failed: $e', label: 'WebStorageAdapter');
      rethrow;
    }
  }

  /// delete database
  static Future<void> deleteDatabase(String dbName) async {
    try {
      final instance = _instances[dbName];
      if (instance != null) {
        await instance.close();
      }

      final request = window.indexedDB.deleteDatabase(dbName);
      await _wrapDeleteRequest(request);
    } catch (e) {
      Logger.error('Delete database failed: $e', label: 'WebStorageAdapter');
      rethrow;
    }
  }

  /// wrap delete database request
  static Future<void> _wrapDeleteRequest(IDBOpenDBRequest request) {
    final completer = Completer<void>();

    request.onsuccess = ((Event event) {
      completer.complete();
    }).toJS;

    request.onerror = ((Event event) {
      completer.completeError(request.error ?? 'Delete database failed');
    }).toJS;

    return completer.future;
  }

  /// Replace _writeSingleFileGeneric with _storeFileInfo
  Future<void> _storeFileInfo(FileInfo fileInfo) async {
    final transaction =
        _db!.transaction([_fileStore].jsify() as JSArray, 'readwrite');
    final store = transaction.objectStore(_fileStore);
    try {
      await _wrapRequest(store.put(fileInfo.toJson().jsify()));
    } catch (e) {
      Logger.error('Write file failed: $e');
      rethrow;
    }
  }

  /// Create _getFileInfo to replace _getFileData
  Future<FileInfo?> _getFileInfo(String path) async {
    final normalizedPath = _normalizePath(path);
    final transaction =
        _db!.transaction([_fileStore].jsify() as JSArray, 'readonly');
    final store = transaction.objectStore(_fileStore);
    final result = await _wrapRequest<JSAny?>(store.get(normalizedPath.toJS));
    if (result == null) return null;
    final json = _deepConvert(result.dartify());
    return FileInfo.fromJson(json);
  }

  /// Update readAsString to decode from stored bytes
  @override
  Future<String?> readAsString(String path) async {
    await _initCompleter.future;
    try {
      final normalizedPath = _normalizePath(path);
      final buffered = _writeBuffer[normalizedPath];
      if (buffered != null) {
        final bytes = buffered.buildBytes();
        return utf8.decode(bytes);
      }
      final fileInfo = await _getFileInfo(normalizedPath);
      if (fileInfo == null || fileInfo.data == null) return null;
      final bytes = _convertDataToList(fileInfo.data);
      return utf8.decode(bytes);
    } catch (e) {
      Logger.error('Read failed: $e', label: 'WebStorageImpl.readAsString');
      return null;
    }
  }

  /// Update writeAsString to store FileInfo
  @override
  Future<void> writeAsString(String path, String content,
      {bool append = false,
      bool flush = true,
      bool closeHandleAfterFlush = false}) async {
    await _initCompleter.future;
    try {
      if (_db == null) throw Exception('Database not initialized');
      final normalizedPath = _normalizePath(path);
      final entry = await _getOrCreateBufferedEntry(normalizedPath,
          prepareBase: append && !_writeBuffer.containsKey(normalizedPath));
      final bytes = Uint8List.fromList(utf8.encode(content));
      if (append) {
        entry.append(bytes);
      } else {
        entry.overwrite(bytes);
      }
      if (flush) {
        await _flushPath(normalizedPath);
      }
    } catch (e) {
      Logger.error('Write failed: $e', label: 'WebStorageImpl.writeAsString');
      rethrow;
    }
  }

  /// Update writeAsBytes to store FileInfo
  @override
  Future<void> writeAsBytes(String path, Uint8List bytes,
      {bool flush = true, bool closeHandleAfterFlush = false}) async {
    await _initCompleter.future;
    try {
      if (_db == null) throw Exception('Database not initialized');
      final normalizedPath = _normalizePath(path);
      final entry =
          await _getOrCreateBufferedEntry(normalizedPath, prepareBase: false);
      entry.overwrite(bytes);
      if (flush) {
        await _flushPath(normalizedPath);
      }
    } catch (e) {
      Logger.error('Write bytes failed: $e',
          label: 'WebStorageImpl.writeAsBytes');
      rethrow;
    }
  }

  @override
  Future<Uint8List> readAsBytes(String path) async {
    await _initCompleter.future;
    try {
      final normalizedPath = _normalizePath(path);
      final buffered = _writeBuffer[normalizedPath];
      if (buffered != null) {
        return buffered.buildBytes();
      }
      final fileInfo = await _getFileInfo(normalizedPath);
      if (fileInfo == null || fileInfo.data == null) return Uint8List(0);
      return _convertDataToUint8List(fileInfo.data);
    } catch (e) {
      Logger.error('Read failed: $e', label: 'WebStorageImpl.readAsBytes');
      return Uint8List(0);
    }
  }

  @override
  Future<Uint8List> readAsBytesAt(String path, int start, {int? length}) async {
    await _initCompleter.future;
    try {
      final normalizedPath = _normalizePath(path);
      final buffered = _writeBuffer[normalizedPath];
      Uint8List fullData;
      if (buffered != null) {
        fullData = buffered.buildBytes();
      } else {
        final fileInfo = await _getFileInfo(normalizedPath);
        if (fileInfo == null || fileInfo.data == null) return Uint8List(0);
        fullData = _convertDataToUint8List(fileInfo.data);
      }

      if (start >= fullData.length) return Uint8List(0);

      final end = length != null
          ? (start + length > fullData.length
              ? fullData.length
              : start + length)
          : fullData.length;

      return fullData.sublist(start, end);
    } catch (e) {
      Logger.error('Read bytes at offset failed: $e', label: 'WebStorageImpl');
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
    await _initCompleter.future;
    if (writes.isEmpty) return;
    try {
      if (_db == null) throw Exception('Database not initialized');
      final normalizedPath = _normalizePath(path);
      // Random writes require base for correct in-place modification.
      final entry =
          await _getOrCreateBufferedEntry(normalizedPath, prepareBase: true);
      entry.writeManyAt(writes);
      if (flush) {
        await _flushPath(normalizedPath);
      }
    } catch (e) {
      Logger.error('Write bytes at offsets failed: $e',
          label: 'WebStorageImpl.writeManyAsBytesAt');
      rethrow;
    }
  }

  /// Update copyFile to use FileInfo
  @override
  Future<void> copyFile(String sourcePath, String targetPath) async {
    await _initCompleter.future;
    try {
      final normalizedSource = _normalizePath(sourcePath);
      final normalizedDest = _normalizePath(targetPath);
      final data = await readAsBytes(normalizedSource);
      await writeAsBytes(normalizedDest, data, flush: true);
    } catch (e) {
      Logger.error('Copy file failed: $e', label: 'WebStorageImpl.copyFile');
    }
  }

  @override
  Future<void> copyDirectory(String sourcePath, String targetPath) async {
    await _initCompleter.future;

    try {
      if (_db == null) throw Exception('Database not initialized');

      final normalizedSourcePath = _normalizePath(sourcePath);
      final normalizedTargetPath = _normalizePath(targetPath);

      // get all files and subdirectories in the source directory
      final items = await listDirectory(sourcePath, recursive: true);

      for (var itemPath in items) {
        // calculate relative path
        String relativePath = itemPath;
        if (itemPath.startsWith('$normalizedSourcePath/')) {
          relativePath = itemPath.substring(normalizedSourcePath.length + 1);
        } else if (itemPath == normalizedSourcePath) {
          continue; // skip source directory itself
        }

        // calculate target path
        final targetItemPath = pathJoin(normalizedTargetPath, relativePath);

        // check if it is a file (through existsFile)
        if (await existsFile(itemPath)) {
          await copyFile(itemPath, targetItemPath);
        } else {
          Logger.debug(
              'Skipping non-file item during directory copy: $itemPath',
              label: 'WebStorageImpl.copyDirectory');
        }
      }
    } catch (e) {
      Logger.error('Copy directory failed: $e',
          label: 'WebStorageImpl.copyDirectory');
    }
  }

  /// Update getFileMeta to use FileInfo structure
  Future<FileMeta?> _getFileMeta(String path) async {
    try {
      final fileInfo = await _getFileInfo(path);
      if (fileInfo == null) return null;
      final meta = fileInfo.meta;
      return meta;
    } catch (e) {
      Logger.warn('Get file meta failed: $e}');
      return null;
    }
  }

  @override
  Future<int> getFileSize(String path) async {
    final normalizedPath = _normalizePath(path);
    final buffered = _writeBuffer[normalizedPath];
    if (buffered != null) return buffered.length;
    final meta = await _getFileMeta(path);
    return meta?.fileSizeInBytes ?? 0;
  }

  @override
  Future<DateTime?> getFileCreationTime(String path) async {
    try {
      final meta = await _getFileMeta(path);
      return meta?.timestamps.created;
    } catch (e) {
      Logger.error('Get creation time failed: $e');
      return null;
    }
  }

  @override
  Future<DateTime?> getFileModifiedTime(String path) async {
    final normalizedPath = _normalizePath(path);
    final buffered = _writeBuffer[normalizedPath];
    if (buffered != null) return buffered.modified;
    final meta = await _getFileMeta(path);
    return meta?.timestamps.modified;
  }

  String _normalizePath(String path) {
    return path
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+'), '/')
        .replaceAll(RegExp(r'^/+'), '');
  }

  /// extract file name from path
  String _extractFileName(String path) {
    return path.split('/').last.split('.').first;
  }

  /// Safely convert FileInfo.data to Uint8List
  Uint8List _convertDataToUint8List(dynamic data) {
    if (data is Uint8List) {
      return data;
    } else if (data is List) {
      return Uint8List.fromList(List<int>.from(data));
    } else {
      throw Exception('Unexpected data type: ${data.runtimeType}');
    }
  }

  /// Safely convert FileInfo.data to List<int>
  List<int> _convertDataToList(dynamic data) {
    if (data is Uint8List) {
      return data.toList();
    } else if (data is List) {
      return List<int>.from(data);
    } else {
      throw Exception('Unexpected data type: ${data.runtimeType}');
    }
  }

  // enhance type conversion method
  dynamic _deepConvert(dynamic value) {
    if (value is Map) {
      return _convertJsMap(value.cast<dynamic, dynamic>());
    } else if (value is List) {
      return _convertJsList(value);
    }
    return value;
  }

  List<dynamic> _convertJsList(List<dynamic> list) {
    return list.map((e) {
      if (e is JSArray) {
        return Uint8List.fromList(List<int>.from(e.toDart));
      } else if (e is List) {
        // Handle regular List as well - recursively convert nested lists
        return _convertJsList(e);
      } else if (e is Map) {
        return _convertJsMap(e);
      }
      return e;
    }).toList();
  }

  Map<String, dynamic> _convertJsMap(Map<dynamic, dynamic> raw) {
    return raw.map<String, dynamic>((k, v) {
      final key = k is String ? k : k.toString();
      // Special handling for the 'data' field
      if (key == 'data') {
        if (v is JSArray) {
          // Directly convert JSArray to Uint8List for 'data' field and return immediately
          return MapEntry(key, Uint8List.fromList(List<int>.from(v.toDart)));
        } else if (v is List) {
          // Handle regular List as well
          return MapEntry(key, Uint8List.fromList(List<int>.from(v)));
        } else if (v is Uint8List) {
          // Already a Uint8List, return as is
          return MapEntry(key, v);
        } else {
          return MapEntry(key, v);
        }
      }

      dynamic value = v;
      // Process other nested structures
      if (value is JSArray) {
        value = Uint8List.fromList(List<int>.from(value.toDart));
      } else if (value is List) {
        // For non-data fields, convert nested lists recursively
        value = _convertJsList(value);
      } else if (value is Map) {
        value = _convertJsMap(value);
      }
      return MapEntry(key, value);
    });
  }

  @override
  Stream<String> readLinesStream(String path, {int offset = 0}) async* {
    final content = await readAsString(path);
    if (content == null) return;
    final lines = const LineSplitter().convert(content);
    for (var i = offset; i < lines.length; i++) {
      yield lines[i];
    }
  }

  @override
  Future<void> writeLinesStream(String path, Stream<String> lines,
      {bool append = false}) async {
    final buffer = StringBuffer();
    await for (final line in lines) {
      buffer.writeln(line);
    }
    await writeAsString(path, buffer.toString(), append: append);
  }

  /// Web storage does not require directory creation
  @override
  Future<void> ensureDirectoryExists(String path) async {
    return;
  }

  @override
  Future<int> appendBytes(String path, Uint8List bytes,
      {bool flush = true, bool closeHandleAfterFlush = false}) async {
    await _initCompleter.future;
    try {
      if (_db == null) throw Exception('Database not initialized');
      final normalizedPath = _normalizePath(path);
      final entry =
          await _getOrCreateBufferedEntry(normalizedPath, prepareBase: true);
      final offset = entry.length;
      entry.append(bytes);
      if (flush) {
        await _flushPath(normalizedPath);
      }
      return offset;
    } catch (e) {
      Logger.error('Append bytes failed: $e', label: 'WebStorageImpl');
      rethrow;
    }
  }

  @override
  Future<int> appendString(String path, String content,
      {bool flush = true, bool closeHandleAfterFlush = false}) async {
    await _initCompleter.future;
    try {
      if (_db == null) throw Exception('Database not initialized');
      final normalizedPath = _normalizePath(path);
      final entry =
          await _getOrCreateBufferedEntry(normalizedPath, prepareBase: true);
      final offset = entry.length;
      entry.append(Uint8List.fromList(utf8.encode(content)));
      if (flush) {
        await _flushPath(normalizedPath);
      }
      return offset;
    } catch (e) {
      Logger.error('Append string failed: $e', label: 'WebStorageImpl');
      rethrow;
    }
  }

  @override
  Future<List<String>> readAsLines(String path, {int offset = 0}) async {
    await _initCompleter.future;
    try {
      final bytes = await readAsBytes(path);
      if (bytes.isEmpty || offset >= bytes.length) {
        return [];
      }
      final byteStream = Stream.fromIterable([bytes.sublist(offset)]);
      return utf8.decoder
          .bind(byteStream)
          .transform(const LineSplitter())
          .toList();
    } catch (e) {
      Logger.error('Read as lines failed: $e', label: 'WebStorageImpl');
      return [];
    }
  }

  @override
  Future<void> flushAll(
      {String? path, List<String>? paths, bool closeHandles = false}) async {
    await _initCompleter.future;
    if (_writeBuffer.isEmpty &&
        path == null &&
        (paths == null || paths.isEmpty)) {
      return;
    }
    if (paths != null && paths.isNotEmpty) {
      final yieldController = YieldController('web_storage_flush_paths');
      for (final pth in paths) {
        final normalized = _normalizePath(pth);
        await _flushPath(normalized);
        await yieldController.maybeYield();
      }
      return;
    }
    if (path != null) {
      final normalized = _normalizePath(path);
      await _flushPath(normalized);
      return;
    }
    // Flush all dirty entries
    final yieldController = YieldController('web_storage_flush_all');
    for (final entry in _writeBuffer.entries.toList()) {
      if (entry.value.dirty) {
        await _flushPath(entry.key);
      }
      await yieldController.maybeYield();
    }
  }

  @override
  Future<void> configureStorage({int? maxOpenHandles}) async {
    // No-op for web
    return;
  }

  @override
  Future<void> replaceFileAtomic(String tempPath, String finalPath) async {
    // Web platform lacks true atomic rename; emulate by copy then delete.
    await _initCompleter.future;
    try {
      final normalizedTmp = _normalizePath(tempPath);
      final normalizedFinal = _normalizePath(finalPath);
      final bytes = await readAsBytes(normalizedTmp);
      await writeAsBytes(normalizedFinal, bytes, flush: true);
      await deleteFile(normalizedTmp);
    } catch (e) {
      Logger.error('replaceFileAtomic (web fallback) failed: $e',
          label: 'WebStorageImpl');
      rethrow;
    }
  }

  Future<_BufferedEntry> _getOrCreateBufferedEntry(String normalizedPath,
      {required bool prepareBase}) async {
    final existing = _writeBuffer[normalizedPath];
    if (existing != null) return existing;
    final entry = _BufferedEntry();
    _writeBuffer[normalizedPath] = entry;
    if (prepareBase) {
      final info = await _getFileInfo(normalizedPath);
      if (info != null && info.data != null) {
        entry.ensureBase(_convertDataToUint8List(info.data));
      } else {
        entry.ensureBase(Uint8List(0));
      }
    }
    return entry;
  }

  Future<void> _flushPath(String normalizedPath) async {
    final entry = _writeBuffer[normalizedPath];
    if (entry == null || !entry.dirty) return;
    final bytes = entry.buildBytes();
    final now = DateTime.now();
    final meta = FileMeta(
      version: 1,
      type: _getFileType(normalizedPath),
      name: _extractFileName(normalizedPath),
      fileSizeInBytes: bytes.length,
      timestamps: Timestamps(
        created: now,
        modified: now,
      ),
    );
    final fileInfo = FileInfo(path: normalizedPath, meta: meta, data: bytes);
    await _storeFileInfo(fileInfo);
    // After flush, release buffered memory to avoid growth; base can be reloaded lazily on next append
    _writeBuffer.remove(normalizedPath);
  }
}

class _BufferedEntry {
  Uint8List? _base; // persisted or lazily loaded
  final List<Uint8List> _chunks = [];
  bool _overwrite = false; // true if write replaces base
  Uint8List? _materialized; // materialized full bytes for random writes
  bool dirty = false;
  DateTime modified = DateTime.now();

  int get length {
    final mat = _materialized;
    if (mat != null) return mat.length;
    final baseLen = _overwrite ? 0 : (_base?.length ?? 0);
    int chunksLen = 0;
    for (final c in _chunks) {
      chunksLen += c.length;
    }
    return baseLen + chunksLen;
  }

  void ensureBase(Uint8List? base) {
    if (_materialized != null) return;
    if (_base == null && !_overwrite) {
      _base = base ?? Uint8List(0);
    }
  }

  void append(Uint8List chunk) {
    final mat = _materialized;
    if (mat != null) {
      final oldLen = mat.length;
      final next = Uint8List(oldLen + chunk.length);
      next.setRange(0, oldLen, mat);
      next.setRange(oldLen, oldLen + chunk.length, chunk);
      _materialized = next;
      dirty = true;
      modified = DateTime.now();
      return;
    }
    _chunks.add(chunk);
    dirty = true;
    modified = DateTime.now();
  }

  void overwrite(Uint8List data) {
    _materialized = Uint8List.fromList(data);
    _base = null;
    _chunks.clear();
    _overwrite = true;
    dirty = true;
    modified = DateTime.now();
  }

  void _ensureMaterialized() {
    if (_materialized != null) return;
    _materialized = buildBytes();
    // Drop chunk/base state to avoid duplication; materialized becomes the source of truth.
    _base = null;
    _chunks.clear();
    _overwrite = true;
  }

  void writeAt(int offset, Uint8List data) {
    if (data.isEmpty) return;
    if (offset < 0) {
      throw ArgumentError.value(offset, 'offset', 'must be >= 0');
    }
    _ensureMaterialized();
    final buf = _materialized!;
    final end = offset + data.length;
    Uint8List out = buf;
    if (end > buf.length) {
      out = Uint8List(end);
      out.setRange(0, buf.length, buf);
    }
    out.setRange(offset, end, data);
    _materialized = out;
    dirty = true;
    modified = DateTime.now();
  }

  void writeManyAt(List<ByteWrite> writes) {
    if (writes.isEmpty) return;
    // Deterministic order: sort by offset, stable by original order.
    final items = <_WebWriteSpan>[];
    items.addAll(<_WebWriteSpan>[
      for (int i = 0; i < writes.length; i++)
        _WebWriteSpan(
          offset: writes[i].offset,
          bytes: writes[i].bytes,
          order: i,
        ),
    ]);
    items.sort((a, b) {
      final c = a.offset.compareTo(b.offset);
      return c != 0 ? c : a.order.compareTo(b.order);
    });
    int lastEnd = -1;
    for (final s in items) {
      if (s.bytes.isEmpty) continue;
      if (s.offset < 0) {
        throw ArgumentError.value(s.offset, 'offset', 'must be >= 0');
      }
      if (lastEnd >= 0 && s.offset < lastEnd) {
        throw StateError(
            'Overlapping write spans: offset=${s.offset} < lastEnd=$lastEnd');
      }
      lastEnd = s.offset + s.bytes.length;
    }
    for (final s in items) {
      writeAt(s.offset, s.bytes);
    }
  }

  Uint8List buildBytes() {
    final mat = _materialized;
    if (mat != null) return mat;
    final total = length;
    final out = Uint8List(total);
    int offset = 0;
    if (!_overwrite && _base != null && _base!.isNotEmpty) {
      out.setRange(0, _base!.length, _base!);
      offset = _base!.length;
    }
    for (final c in _chunks) {
      out.setRange(offset, offset + c.length, c);
      offset += c.length;
    }
    return out;
  }
}

final class _WebWriteSpan {
  final int offset;
  final Uint8List bytes;
  final int order;
  _WebWriteSpan(
      {required this.offset, required this.bytes, required this.order});
}
