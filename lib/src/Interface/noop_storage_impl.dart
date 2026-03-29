import 'dart:async';
import 'dart:typed_data';

import 'storage_interface.dart';

/// A no-op storage implementation used for pure in-memory mode.
///
/// Contract:
/// - Performs **no IO**.
/// - Read APIs return empty/false/null values.
/// - Write/delete/flush APIs complete successfully without touching disk.
///
/// This is intentionally conservative: callers must not rely on persistence
/// semantics in memory mode.
final class NoopStorageImpl implements StorageInterface {
  const NoopStorageImpl();

  @override
  Future<void> writeAsString(
    String path,
    String content, {
    bool append = false,
    bool flush = true,
    bool closeHandleAfterFlush = false,
  }) async {}

  @override
  Future<void> writeAsBytes(
    String path,
    Uint8List bytes, {
    bool flush = true,
    bool closeHandleAfterFlush = false,
  }) async {}

  @override
  Future<String?> readAsString(String path) async => null;

  @override
  Future<void> deleteFile(String path) async {}

  @override
  Future<void> deleteDirectory(String path) async {}

  @override
  Future<bool> existsDirectory(String path) async => false;

  @override
  Future<bool> existsFile(String path) async => false;

  @override
  Future<void> ensureDirectoryExists(String path) async {}

  @override
  Future<List<String>> listDirectory(String path,
          {bool recursive = false}) async =>
      const <String>[];

  @override
  Future<void> close() async {}

  @override
  Future<Uint8List> readAsBytes(String path) async => Uint8List(0);

  @override
  Future<Uint8List> readAsBytesAt(String path, int start,
          {int? length}) async =>
      Uint8List(0);

  @override
  Future<void> writeAsBytesAt(
    String path,
    int start,
    Uint8List bytes, {
    bool flush = true,
    bool closeHandleAfterFlush = false,
  }) async {}

  @override
  Future<void> writeManyAsBytesAt(
    String path,
    List<ByteWrite> writes, {
    bool flush = true,
    bool closeHandleAfterFlush = false,
  }) async {}

  @override
  Future<DateTime?> getFileCreationTime(String path) async => null;

  @override
  Future<DateTime?> getFileModifiedTime(String path) async => null;

  @override
  Future<int> getFileSize(String path) async => 0;

  @override
  Future<void> copyDirectory(String sourcePath, String destinationPath) async {}

  @override
  Future<void> moveDirectory(String sourcePath, String destinationPath) async {}

  @override
  Future<void> copyFile(String sourcePath, String destinationPath) async {}

  @override
  Stream<String> readLinesStream(String path, {int offset = 0}) =>
      const Stream<String>.empty();

  @override
  Future<void> writeLinesStream(
    String path,
    Stream<String> lines, {
    bool append = false,
  }) async {
    // Drain stream to avoid leaking producers.
    await lines.drain<void>();
  }

  @override
  Future<int> appendString(
    String path,
    String content, {
    bool flush = true,
    bool closeHandleAfterFlush = false,
  }) async =>
      0;

  @override
  Future<int> appendBytes(
    String path,
    Uint8List bytes, {
    bool flush = true,
    bool closeHandleAfterFlush = false,
  }) async =>
      0;

  @override
  Future<List<String>> readAsLines(String path, {int offset = 0}) async =>
      const <String>[];

  @override
  Future<void> flushAll(
      {String? path, List<String>? paths, bool closeHandles = false}) async {}

  @override
  Future<void> configureStorage({int? maxOpenHandles}) async {}

  @override
  Future<void> replaceFileAtomic(String tempPath, String finalPath) async {}

  @override
  Future<void> flushFile(String path) async {}
}
