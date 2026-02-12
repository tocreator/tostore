import 'dart:async';
import 'dart:typed_data';

/// A byte write span for random-access file IO.
///
/// - [offset] is the byte offset from the beginning of the file.
/// - [bytes] is the payload to write at [offset].
///
/// Implementations may require:
/// - [offset] >= 0
/// - [bytes] is not empty
/// - write spans do not overlap (recommended for deterministic high-throughput batching)
final class ByteWrite {
  final int offset;
  final Uint8List bytes;
  ByteWrite({required this.offset, required this.bytes});
}

/// Storage interface for cross-platform compatibility
abstract class StorageInterface {
  /// Write string to file
  Future<void> writeAsString(
    String path,
    String content, {
    bool append = false,
    bool flush = true,
    bool closeHandleAfterFlush = false,
  });

  /// Write binary data to file
  Future<void> writeAsBytes(String path, Uint8List bytes,
      {bool flush = true, bool closeHandleAfterFlush = false});

  /// Read file as string
  Future<String?> readAsString(String path);

  /// Delete file
  Future<void> deleteFile(String path);

  /// Delete directory and all its contents
  Future<void> deleteDirectory(String path);

  /// Check if directory exists at the specified path
  Future<bool> existsDirectory(String path);

  /// Check if file exists at the specified path
  Future<bool> existsFile(String path);

  /// Creates directory if it doesn't already exist
  Future<void> ensureDirectoryExists(String path);

  /// List directory contents
  ///
  /// If [recursive] is true, lists all files in the directory and its subdirectories.
  /// If [recursive] is false, only lists direct children (files and directories).
  Future<List<String>> listDirectory(String path, {bool recursive = false});

  /// Close storage and cleanup resources
  Future<void> close();

  /// Read file as bytes
  Future<Uint8List> readAsBytes(String path);

  /// Read file as bytes from a specific offset and length.
  /// [start] - byte offset to start reading from
  /// [length] - number of bytes to read (null means read to end)
  /// Returns empty Uint8List if start is beyond file size.
  Future<Uint8List> readAsBytesAt(String path, int start, {int? length});

  /// Write bytes at a specific offset (random write).
  ///
  /// If [flush] is false, the write should be left in OS/page cache (or an
  /// in-memory buffer on web) and can be persisted later via [flushAll].
  Future<void> writeAsBytesAt(
    String path,
    int start,
    Uint8List bytes, {
    bool flush = true,
    bool closeHandleAfterFlush = false,
  });

  /// Write many byte spans at specified offsets (random write batching).
  ///
  /// Implementations should:
  /// - Apply the writes in a deterministic order (recommended: sort by offset).
  /// - Avoid per-span flush; flush at most once when [flush] is true.
  /// - Prefer minimizing seek/setPosition calls (contiguous spans may be written sequentially).
  Future<void> writeManyAsBytesAt(
    String path,
    List<ByteWrite> writes, {
    bool flush = true,
    bool closeHandleAfterFlush = false,
  });

  /// Get file creation time
  Future<DateTime?> getFileCreationTime(String path);

  /// Get file modified time
  Future<DateTime?> getFileModifiedTime(String path);

  /// Get file size
  Future<int> getFileSize(String path);

  /// Copy a directory
  Future<void> copyDirectory(String sourcePath, String destinationPath);

  /// Copy a file
  Future<void> copyFile(String sourcePath, String destinationPath);

  /// Stream lines from a file
  Stream<String> readLinesStream(String path, {int offset = 0});

  /// Write lines to a file using a stream
  Future<void> writeLinesStream(
    String path,
    Stream<String> lines, {
    bool append = false,
  });

  /// Appends a string to a file and returns the offset before writing.
  /// If [flush] is false, the content will be left in the OS/page cache and not forced to disk immediately.
  Future<int> appendString(String path, String content,
      {bool flush = true, bool closeHandleAfterFlush = false});

  /// Appends binary data to a file and returns the offset before writing.
  /// If [flush] is false, the content will be left in the OS/page cache and not forced to disk immediately.
  Future<int> appendBytes(String path, Uint8List bytes,
      {bool flush = true, bool closeHandleAfterFlush = false});

  /// Reads a file as a list of lines, starting from a specific byte offset.
  Future<List<String>> readAsLines(String path, {int offset = 0});

  /// Flush pending buffered writes to disk.
  /// If [path] is provided, only flush that file.
  /// If [paths] is provided, flush all files in the list.
  /// If neither is provided, flush all open handles/buffers.
  /// When [closeHandles] is true, also close handles for the flushed paths.
  Future<void> flushAll(
      {String? path, List<String>? paths, bool closeHandles = false});

  /// Configure storage runtime options like handle pool size, etc.
  Future<void> configureStorage({int? maxOpenHandles});

  /// Atomically replace [finalPath] with the contents of [tempPath].
  /// Requirements:
  /// - [tempPath] and [finalPath] must be on the same filesystem/volume.
  /// - Caller is responsible for ensuring parent directory exists.
  /// On platforms that do not support atomic rename, fallback to best-effort replace.
  Future<void> replaceFileAtomic(String tempPath, String finalPath);

  /// Flush any buffered writes for the specific file path.
  /// This ensures data durability for the given file without closing the handle necessarily.
  Future<void> flushFile(String path);
}
