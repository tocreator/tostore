import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart';
import '../handler/logger.dart';
import 'dart:convert';
import '../handler/common.dart';

import '../Interface/storage_interface.dart';
import '../model/file_info.dart';

/// Web platform storage adapter implementation
class WebStorageImpl implements StorageInterface {
  static final Map<String, WebStorageImpl> _instances = {};
  IDBDatabase? _db;
  final Completer<void> _initCompleter = Completer<void>();

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
      final allPaths = allKeys.toDart
          .cast<String>()
          .where((key) => !key.contains('.block'))
          .toList();

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
      final exists = keys.toDart.isNotEmpty;

      return exists;
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
      final fileInfo = await _getFileInfo(normalizedPath);
      if (fileInfo == null || fileInfo.data == null) return null;
      final bytes = List<int>.from(fileInfo.data!);
      return utf8.decode(bytes);
    } catch (e) {
      Logger.error('Read failed: $e', label: 'WebStorageImpl.readAsString');
      return null;
    }
  }

  /// Update writeAsString to store FileInfo
  @override
  Future<void> writeAsString(String path, String content,
      {bool append = false}) async {
    await _initCompleter.future;
    try {
      if (_db == null) throw Exception('Database not initialized');
      final normalizedPath = _normalizePath(path);
      String newContent = content;
      if (append && await existsFile(normalizedPath)) {
        final existingContent = await readAsString(normalizedPath);
        if (existingContent != null) {
          newContent = existingContent + content;
        }
      }
      final meta = _generateFileMeta(normalizedPath, newContent);
      // Encode the content to bytes using utf8.encode
      final encoded = utf8.encode(newContent);
      final fileInfo =
          FileInfo(path: normalizedPath, meta: meta, data: encoded);
      await _storeFileInfo(fileInfo);
    } catch (e) {
      Logger.error('Write failed: $e', label: 'WebStorageImpl.writeAsString');
      rethrow;
    }
  }

  /// Update writeAsBytes to store FileInfo
  @override
  Future<void> writeAsBytes(String path, Uint8List bytes) async {
    await _initCompleter.future;
    try {
      if (_db == null) throw Exception('Database not initialized');
      final normalizedPath = _normalizePath(path);
      final now = DateTime.now();
      final meta = FileMeta(
        version: 1,
        type: _getFileType(normalizedPath),
        name: _extractFileName(normalizedPath),
        fileSizeInBytes: bytes.length,
        totalRecords: 0,
        timestamps: Timestamps(
          created: now,
          modified: now,
        ),
        partitions: null,
      );
      final fileInfo = FileInfo(path: normalizedPath, meta: meta, data: bytes);
      await _storeFileInfo(fileInfo);
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
      final fileInfo = await _getFileInfo(normalizedPath);
      if (fileInfo == null || fileInfo.data == null) return Uint8List(0);
      final bytes = List<int>.from(fileInfo.data!);
      return Uint8List.fromList(bytes);
    } catch (e) {
      Logger.error('Read failed: $e', label: 'WebStorageImpl.readAsString');
      return Uint8List(0);
    }
  }

  /// Update copyFile to use FileInfo
  @override
  Future<void> copyFile(String sourcePath, String targetPath) async {
    await _initCompleter.future;
    try {
      final normalizedSource = _normalizePath(sourcePath);
      final normalizedDest = _normalizePath(targetPath);
      final fileInfo = await _getFileInfo(normalizedSource);
      if (fileInfo == null) {
        throw Exception('Source file not found: $sourcePath');
      }
      final newName = _extractFileName(normalizedDest);
      final newMeta = fileInfo.meta.copyWith(name: newName);
      final newFileInfo =
          FileInfo(path: normalizedDest, meta: newMeta, data: fileInfo.data);
      await _storeFileInfo(newFileInfo);
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

  // calculate record count
  int _calculateRecordCount(String content) {
    return const LineSplitter().convert(content).length;
  }

  @override
  Future<int> getFileSize(String path) async {
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
    final meta = await _getFileMeta(path);
    return meta?.timestamps.modified;
  }

  String _normalizePath(String path) {
    return path
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+'), '/')
        .replaceAll(RegExp(r'^/+'), '');
  }

  FileMeta _generateFileMeta(String path, String content) {
    return FileMeta(
      version: 1,
      type: _getFileType(path),
      name: _extractFileName(path),
      fileSizeInBytes: calculateUtf8Length(content),
      totalRecords: _calculateRecordCount(content),
      timestamps: Timestamps(
        created: DateTime.now(),
        modified: DateTime.now(),
      ),
      partitions: null,
    );
  }

  /// extract file name from path
  String _extractFileName(String path) {
    return path.split('/').last.split('.').first;
  }

  Future<bool> validateFile(String path) async {
    final meta = await _getFileMeta(path);
    if (meta == null) return false;

    final content = await readAsString(path);
    return content != null &&
        calculateUtf8Length(content) == meta.fileSizeInBytes;
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
      }
      if (e is Map) return _convertJsMap(e);
      if (e is List) return _convertJsList(e);
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
        } else {
          return MapEntry(key, v);
        }
      }

      dynamic value = v;
      // Process other nested structures
      if (value is JSArray) {
        value = Uint8List.fromList(List<int>.from(value.toDart));
      } else if (value is Map) {
        value = _convertJsMap(value);
      } else if (value is List) {
        value = value.map((e) {
          if (e is Map) return _convertJsMap(e);
          if (e is JSArray) {
            return Uint8List.fromList(List<int>.from(e.toDart));
          }
          return e;
        }).toList();
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
}
