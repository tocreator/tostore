import 'dart:async';
import 'dart:typed_data';

/// Storage interface for cross-platform compatibility
abstract class StorageInterface {
  /// Write string to file
  Future<void> writeAsString(
    String path,
    String content, {
    bool append = false,
  });

  /// Write binary data to file
  Future<void> writeAsBytes(String path, Uint8List bytes);

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

  /// Create a directory if it doesn't exist
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
}
