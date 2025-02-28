import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart';
import '../handler/logger.dart';
import 'dart:convert';
import '../handler/common.dart';

import '../model/business_error.dart';
import 'storage_interface.dart';
import '../model/file_meta.dart';

/// Web platform storage adapter implementation
class WebStorageImpl implements StorageInterface {
  static final Map<String, WebStorageImpl> _instances = {};
  IDBDatabase? _db;
  final Completer<void> _initCompleter = Completer<void>();

  // store type
  static const String _fileStore = 'files'; // file storage（meta data）

  /// Block size for chunked operations (256KB)
  static const int _blockSize = 256 * 1024;

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
  String _getFileType(String path) {
    if (path.endsWith('.dat')) return 'data';
    if (path.endsWith('.schema')) return 'schema';
    if (path.endsWith('.idx')) return 'index';
    if (path.endsWith('.maxid')) return 'auto_increment';
    if (path.endsWith('.stats')) return 'stats';
    if (path.endsWith('.transaction.log')) return 'transaction_log';
    if (path.endsWith('.checksum')) return 'checksum';
    if (path.endsWith('.json')) return 'json';
    if (path.endsWith('.txt')) return 'txt';
    if (path.endsWith('.csv')) return 'csv';
    if (path.endsWith('.bak')) return 'backup';
    if (path.endsWith('.log')) return 'log';
    if (path.endsWith('.tmp')) return 'temp';
    if (path.endsWith('.lock')) return 'lock';
    return 'unknown';
  }

  /// list directory content
  @override
  Future<List<String>> listDirectory(String path) async {
    await _initCompleter.future;

    try {
      if (_db == null) throw Exception('Database not initialized');

      final normalizedPath = path.replaceAll('\\', '/');

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
      final keys = await _wrapRequest<JSArray>(request);
      return keys.toDart
          .cast<String>()
          .toList()
          .where((key) => !key.contains('.block'))
          .toList();
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
      final transaction =
          _db!.transaction([_fileStore].jsify() as JSArray, 'readwrite');
      final store = transaction.objectStore(_fileStore);

      // 1. delete file metadata
      final meta = await _wrapRequest<JSAny?>(store.get(path.toJS));
      if (meta != null) {
        final metaData = Map<String, dynamic>.from(meta.dartify() as Map);

        // 2. delete all blocks if exists
        if (metaData.containsKey('totalBlocks')) {
          final totalBlocks = metaData['totalBlocks'] as int;
          for (var i = 0; i < totalBlocks; i++) {
            final blockPath = '$path.block$i';
            await _wrapRequest(store.delete(blockPath.toJS));
          }
        }
      }

      // delete file itself
      await _wrapRequest(store.delete(path.toJS));
    } catch (e) {
      Logger.error('Delete file failed: $e', label: 'WebStorageImpl');
      rethrow;
    }
  }

  /// check file exists
  @override
  Future<bool> exists(String path) async {
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

  @override
  Future<void> writeAsString(String path, String content,
      {bool append = false}) async {
    await _initCompleter.future;
    try {
      if (_db == null) throw Exception('Database not initialized');
      final normalizedPath = _normalizePath(path);
      int contentLength = calculateUtf8Length(content);
      bool isChunked = contentLength > _blockSize;

      // handle append mode
      String newContent = content;
      if (append && await exists(normalizedPath)) {
        final existingContent = await readAsString(normalizedPath);
        if (existingContent != null) {
          newContent = existingContent + content;
          contentLength = calculateUtf8Length(newContent);
          isChunked = contentLength > _blockSize;
        }
      }

      // clean old data
      await _cleanOldChunks(normalizedPath);

      // generate meta data
      final meta = _generateFileMeta(normalizedPath, newContent, isChunked);

      // choose storage method based on file size
      if (isChunked) {
        await _writeChunkedFile(normalizedPath, newContent, meta);
      } else {
        await _writeSingleFile(normalizedPath, newContent, meta);
      }
    } catch (e) {
      Logger.error('Write failed: ${e.toString()}',
          label: 'WebStorageImpl.writeAsString');
      rethrow;
    }
  }

  Future<void> _writeSingleFile(
      String path, String content, FileMeta meta) async {
    final transaction =
        _db!.transaction([_fileStore].jsify() as JSArray, 'readwrite');
    final store = transaction.objectStore(_fileStore);

    try {
      final bytes = utf8.encode(content);
      // explicitly convert to basic Map and copy
      final metaJson = Map<String, dynamic>.from(meta.toJson());

      await _wrapRequest(
          store.put({'path': path, 'data': bytes, 'meta': metaJson}.jsify()));
    } catch (e) {
      Logger.error('Write file failed: $e');
      rethrow;
    }
  }

  Future<void> _writeChunkedFile(
      String path, String content, FileMeta meta) async {
    final transaction =
        _db!.transaction([_fileStore].jsify() as JSArray, 'readwrite');
    final store = transaction.objectStore(_fileStore);

    // write main meta data
    await _wrapRequest(store.put({
      'path': path,
      'meta': meta.toJson() // use serialized meta data
    }.jsify()));

    // write chunks
    final totalChunks = meta.chunks!.total;
    int contentLength = calculateUtf8Length(content);
    for (var i = 0; i < totalChunks; i++) {
      final start = i * _blockSize;
      final end = (i + 1) * _blockSize;
      final chunkContent =
          content.substring(start, end.clamp(0, contentLength));

      // handle encoding
      final encodedChunkContent = utf8.encode(chunkContent);

      await _wrapRequest(store.put({
        'path': '$path.block$i',
        'data': encodedChunkContent,
        'meta': {
          'parent': path,
          'index': i,
        }
      }.jsify()));
    }
  }

  @override
  Future<void> writeLines(String path, List<String> lines) async {
    final buffer = StringBuffer();
    for (final line in lines) {
      buffer.writeln(line);
    }
    await writeAsString(path, buffer.toString());
  }

  @override
  Future<String?> readAsString(String path) async {
    await _initCompleter.future;
    try {
      final normalizedPath = _normalizePath(path);
      final mainRecord = await _getFileData(normalizedPath);
      if (mainRecord == null) return null;
      final meta =
          FileMeta.fromJson(mainRecord['meta'] as Map<String, dynamic>);

      // handle chunked file
      if (meta.chunks != null) {
        return _readChunkedFile(meta, normalizedPath);
      }

      // handle normal file
      final content = utf8.decode(mainRecord['data']);
      return content;
    } catch (e) {
      Logger.error('Read failed: ${e.toString()}',
          label: 'WebStorageImpl.readAsString');
      return null;
    }
  }

  @override
  Future<List<String>> readLines(String path) async {
    final content = await readAsString(path);
    if (content == null) return [];

    return const LineSplitter().convert(content);
  }

  @override
  Future<Uint8List> readAsBytes(String path) async {
    final content = await readAsString(path);
    if (content == null) return Uint8List(0);
    return Uint8List.fromList(utf8.encode(content));
  }

  /// get file metadata
  @override
  Future<FileMeta?> getFileMeta(String path, {bool validate = false}) async {
    try {
      final data = await _getFileData(path);
      if (data == null || data['meta'] == null) return null;

      // use JSON deep copy to ensure type safety
      final metaJson =
          jsonDecode(jsonEncode(data['meta'])) as Map<String, dynamic>;

      final meta = FileMeta.fromJson(metaJson);

      if (validate) _validateFileMeta(meta);
      return meta;
    } catch (e) {
      Logger.warn('Get file meta failed: $e');
      return null;
    }
  }

  void _validateFileMeta(FileMeta meta) {
    // validate meta data version
    if (meta.version != 1) {
      throw BusinessError('Unsupported metadata version: ${meta.version}',
          type: BusinessErrorType.invalidData);
    }

    // validate timestamp logic
    final now = DateTime.now();
    if (meta.timestamps.created.isAfter(now) ||
        meta.timestamps.modified.isAfter(now) ||
        meta.timestamps.accessed.isAfter(now)) {
      throw const BusinessError('Invalid timestamp in metadata',
          type: BusinessErrorType.invalidData);
    }

    // validate chunk info
    if (meta.chunks != null) {
      final chunkInfo = meta.chunks!;
      if (chunkInfo.indexes.length != chunkInfo.total) {
        throw const BusinessError('Chunk index count mismatch',
            type: BusinessErrorType.invalidData);
      }
    }
  }

  // calculate record count
  int _calculateRecordCount(String content) {
    return const LineSplitter().convert(content).length;
  }

  /// validate chunk integrity
  Future<bool> validateChunks(String path) async {
    try {
      final meta = await getFileMeta(path);
      if (meta == null) return false;

      final chunks = meta.chunks!;
      final total = chunks.total;
      final indexes = chunks.indexes;

      // validate index continuity
      if (indexes.length != total) {
        Logger.error('Chunk index count mismatch: ${indexes.length} vs $total');
        return false;
      }

      // check all chunks exist
      for (var i = 0; i < total; i++) {
        if (!await exists('$path.block$i')) {
          return false;
        }
      }

      return true;
    } catch (e) {
      Logger.error('Validate chunks failed: $e');
      return false;
    }
  }

  @override
  Future<int> getFileSize(String path) async {
    final meta = await getFileMeta(path);
    return meta?.size ?? 0;
  }

  @override
  Future<int> getFileRecordCount(String path) async {
    final meta = await getFileMeta(path);
    return meta?.records ?? 0;
  }

  @override
  Future<DateTime?> getFileCreationTime(String path) async {
    try {
      final meta = await getFileMeta(path);
      return meta?.timestamps.created;
    } catch (e) {
      Logger.error('Get creation time failed: $e');
      return null;
    }
  }

  @override
  Future<DateTime?> getFileModifiedTime(String path) async {
    final meta = await getFileMeta(path);
    return meta?.timestamps.modified;
  }

  @override
  Future<DateTime?> getFileAccessedTime(String path) async {
    final meta = await getFileMeta(path);
    return meta?.timestamps.accessed;
  }

  String _normalizePath(String path) {
    return path
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+'), '/')
        .replaceAll(RegExp(r'^/+'), '');
  }

  Future<void> _cleanOldChunks(String path) async {
    try {
      final meta = await getFileMeta(path);
      final chunks = meta?.chunks;

      if (chunks != null) {
        final total = chunks.total;
        for (var i = 0; i < total; i++) {
          final chunkPath = '$path.block$i';
          if (await exists(chunkPath)) {
            await deleteFile(chunkPath);
          }
        }
      }
    } catch (e) {
      Logger.error('Clean old chunks failed: $e');
    }
  }

  FileMeta _generateFileMeta(String path, String content, bool isChunked) {
    return FileMeta(
      version: 1,
      type: _getFileType(path),
      name: _extractFileName(path),
      size: calculateUtf8Length(content),
      records: _calculateRecordCount(content),
      timestamps: Timestamps(
        created: DateTime.now(),
        modified: DateTime.now(),
        accessed: DateTime.now(),
      ),
      chunks: isChunked ? _generateChunkInfo(content) : null,
    );
  }

  /// extract file name from path
  String _extractFileName(String path) {
    return path.split('/').last.split('.').first;
  }

  ChunkInfo _generateChunkInfo(String content) {
    final total = (calculateUtf8Length(content) / _blockSize).ceil();
    return ChunkInfo(
      total: total,
      size: _blockSize,
      indexes: List.generate(total, (i) => i),
      index: 0,
    );
  }

  Future<String> _readChunkedFile(FileMeta meta, String path) async {
    final buffer = StringBuffer();
    final chunkInfo = meta.chunks!;

    for (var i = 0; i < chunkInfo.total; i++) {
      final chunkPath = '$path.block$i';
      final chunkData = await _getFileData(chunkPath);
      if (chunkData == null) continue;

      final content = utf8.decode(chunkData['data']);
      buffer.write(content);
    }
    return buffer.toString();
  }

  Future<Map<String, dynamic>?> _getFileData(String path) async {
    final transaction =
        _db!.transaction([_fileStore].jsify() as JSArray, 'readonly');
    final store = transaction.objectStore(_fileStore);

    final result = await _wrapRequest<JSAny?>(store.get(path.toJS));
    if (result == null) return null;

    // deep convert nested structure
    return _deepConvert(result.dartify());
  }

  Future<bool> validateFile(String path) async {
    final meta = await getFileMeta(path);
    if (meta == null) return false;

    final content = await readAsString(path);
    return content != null && calculateUtf8Length(content) == meta.size;
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
        return Uint8List.fromList(List<int>.from(e.jsify() as List));
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
          return MapEntry(key,
              Uint8List.fromList(List<int>.from((v.jsify() as List<dynamic>))));
        } else {
          return MapEntry(key, v);
        }
      }

      dynamic value = v;
      // Process other nested structures
      if (value is JSArray) {
        value = Uint8List.fromList(
            List<int>.from((value.jsify() as List<dynamic>)));
      } else if (value is Map) {
        value = _convertJsMap(value);
      } else if (value is List) {
        value = value.map((e) {
          if (e is Map) return _convertJsMap(e);
          if (e is JSArray) {
            return Uint8List.fromList(
                List<int>.from((e.jsify() as List<dynamic>)));
          }
          return e;
        }).toList();
      }
      return MapEntry(key, value);
    });
  }
}
