import 'dart:async';
import 'dart:typed_data';

import '../model/file_meta.dart';

/// Storage interface for cross-platform compatibility
abstract class StorageInterface {
  /// Write string to file
  Future<void> writeAsString(String path, String content,
      {bool append = false});

  /// Write lines to file with stream
  Future<void> writeLines(String path, List<String> lines);

  /// Read file as string
  Future<String?> readAsString(String path);

  /// Read file as lines
  Future<List<String>> readLines(String path);

  /// Delete file
  Future<void> deleteFile(String path);

  /// Check if file exists
  Future<bool> exists(String path);

  /// List directory contents
  Future<List<String>> listDirectory(String path);

  /// Close storage and cleanup resources
  Future<void> close();

  /// Read file as bytes
  Future<Uint8List> readAsBytes(String path);

  /// Get file creation time
  Future<DateTime?> getFileCreationTime(String path);

  /// Get file modified time
  Future<DateTime?> getFileModifiedTime(String path);

  /// Get file accessed time
  Future<DateTime?> getFileAccessedTime(String path);

  /// Get file size
  Future<int> getFileSize(String path);

  /// Get file record count
  Future<int> getFileRecordCount(String path);

  /// Get file metadata
  /// return:
  /// {
  ///   'path': string,          // full file path
  ///   'type': string,          // file type (data/schema/index)
  ///   'size': int,             // file size
  ///   'records': int,          // record count
  ///   'created': iso8601,       // created time
  ///   'modified': iso8601,      // last modified time
  ///   'accessed': iso8601,      // last accessed time
  ///   'checksum': string,       // content checksum
  ///   'chunks': {              // chunk info (if applicable)
  ///     'total': int,
  ///     'size': int,
  ///     'indexes': List<int>
  ///   }
  /// }
  Future<FileMeta?> getFileMeta(String path);
}
