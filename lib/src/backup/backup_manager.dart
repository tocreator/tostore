import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

import 'package:flutter/foundation.dart';
import 'package:archive/archive_io.dart';

import '../handler/common.dart';
import '../handler/logger.dart';
import '../core/data_store_impl.dart';

import 'backup_info.dart';

/// backup manager
class BackupManager {
  final DataStoreImpl _dataStore;

  BackupManager(this._dataStore);

  /// Extract file name or directory name from path
  String _getFileName(String path) {
    final normalizedPath = path.replaceAll('\\', '/');
    final parts = normalizedPath.split('/');
    final fileName = parts.isEmpty ? path : parts.last;

    if (fileName.contains('.')) {
      return fileName.substring(0, fileName.lastIndexOf('.'));
    }

    return fileName;
  }

  /// Create backup using directory-based approach
  /// Returns the path to the backup directory or zip file
  ///
  /// Parameters:
  /// - compress: Whether to compress the backup into a zip file
  /// - fullBackup: If true, backs up the entire database directory including init files
  ///               If false, only backs up the spaces and global directories
  Future<String> createBackup(
      {bool compress = false, bool fullBackup = false}) async {
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final backupPath = _dataStore.pathManager.getBackupPath();
    final backupDir = pathJoin(backupPath, 'backup_$timestamp');

    try {
      Logger.info(
          'Creating ${fullBackup ? "full" : "partial"} backup using directory-based approach',
          label: 'BackupManager.createBackup');

      // Ensure backup directory exists
      await _dataStore.storage.ensureDirectoryExists(backupPath);
      await _dataStore.storage.ensureDirectoryExists(backupDir);

      // Check if directory was created successfully
      if (!await _dataStore.storage.existsDirectory(backupDir)) {
        throw StateError('Failed to create backup directory: $backupDir');
      }

      // Create metadata file with backup information
      final metaData = {
        'timestamp': timestamp,
        'version': await _dataStore.getVersion(),
        'type': fullBackup ? 'full' : 'partial',
        'compressed': compress,
      };
      await _dataStore.storage.writeAsString(
          pathJoin(backupDir, 'meta.json'), jsonEncode(metaData));

      if (fullBackup) {
        // Full backup: copy the entire database directory (excluding backups dir)
        final dbRootDir = _dataStore.config.dbPath!;
        final dirItems = await _dataStore.storage.listDirectory(dbRootDir);

        for (String itemPath in dirItems) {
          final name = _getFileName(itemPath);

          // Skip backing up the backups directory to avoid recursion
          if (name == 'backups') continue;

          final isDir = await _isDirectory(itemPath);
          final targetPath = pathJoin(backupDir, name);

          if (isDir) {
            await _safeCopyDirectory(itemPath, targetPath);
          } else {
            await _safeCopyFile(itemPath, targetPath);
          }
        }
      } else {
        // Partial backup: only copy spaces and global directories
        // Copy base directory (contains all user tables)
        final basePath = _dataStore.pathManager.getSpacePath();
        if (await _isDirectory(basePath)) {
          await _safeCopyDirectory(basePath, pathJoin(backupDir, 'spaces'));
        }

        // Copy global directory (contains global tables)
        final globalPath = _dataStore.pathManager.getGlobalPath();
        if (await _isDirectory(globalPath)) {
          await _safeCopyDirectory(globalPath, pathJoin(backupDir, 'global'));
        }

        // Copy init.json file if it exists
        final initFilePath = _dataStore.pathManager
            .getSpaceConfigPath(_dataStore.currentSpaceName);
        if (await _dataStore.storage.existsFile(initFilePath)) {
          final targetPath = pathJoin(backupDir, 'space_config.json');
          await _safeCopyFile(initFilePath, targetPath);
        }
      }

      // Optional: Create compressed version if requested
      if (compress) {
        final zipPath = '$backupDir.zip';
        try {
          await _compressDirectory(backupDir, zipPath);

          // Delete original directory after successful compression
          await _dataStore.storage.deleteDirectory(backupDir);

          Logger.info('Created compressed backup: $zipPath',
              label: 'BackupManager.createBackup');
          return zipPath;
        } catch (e) {
          // if compression failed, log error and return original backup directory
          Logger.error(
              'Failed to compress backup directory: $e, returning uncompressed backup.',
              label: 'BackupManager.createBackup');
          return backupDir;
        }
      }

      Logger.info('Backup created successfully: $backupDir',
          label: 'BackupManager.createBackup');
      return backupDir;
    } catch (e) {
      Logger.error('Failed to create backup: $e',
          label: 'BackupManager.createBackup');
      rethrow;
    }
  }

  /// Compress directory to a zip file
  /// Using archive package for cross-platform support
  Future<void> _compressDirectory(String sourceDir, String targetZip) async {
    if (kIsWeb) {
      throw UnsupportedError(
          'Directory compression not supported on web platform');
    }

    try {
      Logger.info('Compressing directory: $sourceDir to $targetZip',
          label: 'BackupManager._compressDirectory');

      final encoder = ZipFileEncoder();
      encoder.create(targetZip);
      await encoder.addDirectory(Directory(sourceDir),
          includeDirName: false, level: _dataStore.config.compressionLevel);
      await encoder.close();

      Logger.info('Directory compressed successfully using archive package',
          label: 'BackupManager._compressDirectory');
    } catch (e) {
      Logger.error('Failed to compress directory: $e',
          label: 'BackupManager._compressDirectory');
      rethrow;
    }
  }

  /// Read metadata from a backup directory
  Future<Map<String, dynamic>> readBackupMetadata(String backupPath) async {
    final metaPath = pathJoin(backupPath, 'meta.json');
    if (!await _dataStore.storage.existsFile(metaPath)) {
      throw StateError('Backup metadata file not found');
    }

    final metaJson = await _dataStore.storage.readAsString(metaPath);
    if (metaJson == null) {
      throw const FormatException('Failed to read backup metadata');
    }

    return jsonDecode(metaJson) as Map<String, dynamic>;
  }

  /// List all backups
  Future<List<BackupInfo>> listBackups() async {
    final backups = <BackupInfo>[];
    final backupPath = _dataStore.pathManager.getBackupPath();

    if (!await _dataStore.storage.existsDirectory(backupPath)) {
      return backups;
    }

    // Get list of items in backup directory
    final items = await _dataStore.storage.listDirectory(backupPath);

    for (String path in items) {
      // Skip non-backup items
      if (!path.contains('backup_') ||
          !(await _dataStore.storage.existsDirectory(path) ||
              path.endsWith('.zip'))) {
        continue;
      }

      try {
        // Get metadata
        final isDirectory = await _isDirectory(path);
        final metaData = isDirectory
            ? await readBackupMetadata(path)
            : {'timestamp': _extractTimestampFromPath(path)};

        int size = await _calculateBackupSize(path);
        final isFullBackup = metaData['type'] == 'full';

        backups.add(BackupInfo(
          path: path,
          timestamp: DateTime.parse(metaData['timestamp'] as String),
          isIncremental: false, // Directory backups are always full backups
          size: size,
          isFullBackup: isFullBackup,
        ));
      } catch (e) {
        // Skip invalid backup
        Logger.error('Skip invalid backup: $path, error: $e',
            label: 'BackupManager.listBackups');
        continue;
      }
    }

    // Sort by timestamp (newest first)
    backups.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return backups;
  }

  /// Extract timestamp from backup path
  String _extractTimestampFromPath(String path) {
    final regex = RegExp(r'backup_([0-9T\-:]+)');
    final match = regex.firstMatch(path);
    if (match != null && match.groupCount >= 1) {
      return match.group(1)!.replaceAll('-', ':');
    }
    return DateTime.now().toIso8601String();
  }

  /// Calculate the size of a backup (directory or zip file)
  Future<int> _calculateBackupSize(String path) async {
    // For zip files, just get the file size
    if (path.endsWith('.zip')) {
      if (kIsWeb) return 0; // Size calculation might not be available on Web
      return await _dataStore.storage.getFileSize(path);
    }

    // For directories, calculate total size of all files
    int size = 0;
    try {
      // On Web, we may need a different approach
      // This is a simplified calculation that may not work perfectly on Web
      final files = await _dataStore.storage.listDirectory(path);
      for (String filePath in files) {
        if (await _dataStore.storage.existsFile(filePath)) {
          size += await _dataStore.storage.getFileSize(filePath);
        }
      }
    } catch (e) {
      Logger.error('Error calculating backup size: $e');
    }
    return size;
  }

  /// Clean the database root directory but preserve specific directories
  Future<void> _cleanDatabaseRoot(String dbRootDir,
      {List<String> preserve = const ['backups']}) async {
    final items = await _dataStore.storage.listDirectory(dbRootDir);

    for (final path in items) {
      final name = _getFileName(path);

      // Skip preserved directories
      if (preserve.contains(name)) continue;

      if (await _isDirectory(path)) {
        await _dataStore.storage.deleteDirectory(path);
      } else {
        await _dataStore.storage.deleteFile(path);
      }
    }
  }

  /// Copy directory that works around Android file system limitations
  Future<void> _safeCopyDirectory(String sourcePath, String destPath) async {
    try {
      // First ensure the target directory exists
      await _dataStore.storage.ensureDirectoryExists(destPath);

      // List all contents in the source directory
      final sourceItems = await _dataStore.storage.listDirectory(sourcePath);

      for (final itemPath in sourceItems) {
        final fileName = _getFileName(itemPath);
        final targetItemPath = pathJoin(destPath, fileName);

        if (await _isDirectory(itemPath)) {
          // If it's a directory, copy recursively
          await _safeCopyDirectory(itemPath, targetItemPath);
        } else {
          // If it's a file, use the safe copy method
          await _safeCopyFile(itemPath, targetItemPath);
        }
      }
    } catch (e) {
      Logger.error('Error copying directory: $e',
          label: 'BackupManager._safeCopyDirectory');
      rethrow;
    }
  }

  /// Safely copy a file by reading content and writing
  Future<void> _safeCopyFile(String sourcePath, String destPath) async {
    try {
      // Ensure target directory exists
      await _dataStore.storage.ensureDirectoryExists(p.dirname(destPath));

      // If all previous methods fail, try direct copy
      await _dataStore.storage.copyFile(sourcePath, destPath);
    } catch (e) {
      Logger.error('Error safely copying file: $e',
          label: 'BackupManager._safeCopyFile');
      rethrow;
    }
  }

  /// Full backup restoration: replace entire database directory (excluding backups)
  Future<void> _restoreFullBackup(String backupPath, String dbRootDir) async {
    try {
      // Clean database directory but preserve backups
      await _cleanDatabaseRoot(dbRootDir);

      // Copy all items from backup to database directory
      final backupItems = await _dataStore.storage.listDirectory(backupPath);

      for (final itemPath in backupItems) {
        final name = _getFileName(itemPath);

        // Skip metadata file and backups directory
        if (name == 'meta.json' || name == 'backups') continue;

        final targetPath = pathJoin(dbRootDir, name);
        final isDir = await _isDirectory(itemPath);

        if (isDir) {
          await _safeCopyDirectory(itemPath, targetPath);
        } else {
          await _safeCopyFile(itemPath, targetPath);
        }
      }
    } catch (e) {
      Logger.error('Error during full backup restoration: $e',
          label: 'BackupManager.restore');
      rethrow;
    }
  }

  /// Partial backup restoration: only restore spaces and global directories
  Future<void> _restorePartialBackup(String backupPath) async {
    try {
      final basePath = _dataStore.pathManager.getSpacePath();
      final globalPath = _dataStore.pathManager.getGlobalPath();

      // Clean base directory
      if (await _dataStore.storage.existsDirectory(basePath)) {
        await _dataStore.storage.deleteDirectory(basePath);
        await _dataStore.storage.ensureDirectoryExists(basePath);
      }

      // Clean global directory
      if (await _dataStore.storage.existsDirectory(globalPath)) {
        await _dataStore.storage.deleteDirectory(globalPath);
        await _dataStore.storage.ensureDirectoryExists(globalPath);
      }

      // Copy base directory from backup
      final backupBasePath = pathJoin(backupPath, 'spaces');
      if (await _dataStore.storage.existsDirectory(backupBasePath)) {
        await _safeCopyDirectory(backupBasePath, basePath);
      }

      // Copy global directory from backup
      final backupGlobalPath = pathJoin(backupPath, 'global');
      if (await _dataStore.storage.existsDirectory(backupGlobalPath)) {
        await _safeCopyDirectory(backupGlobalPath, globalPath);
      }

      // Restore space_config.json file if it exists in the backup
      final backupConfigPath = pathJoin(backupPath, 'space_config.json');
      if (await _dataStore.storage.existsFile(backupConfigPath)) {
        final targetConfigPath = _dataStore.pathManager
            .getSpaceConfigPath(_dataStore.config.spaceName);
        await _safeCopyFile(backupConfigPath, targetConfigPath);
      }
    } catch (e) {
      Logger.error('Error during partial backup restoration: $e',
          label: 'BackupManager.restore');
      rethrow;
    }
  }

  /// Restore from backup
  Future<void> restore(String backupPath) async {
    try {
      // Determine backup type
      final isZip = backupPath.endsWith('.zip');
      final isDirectory = await _isDirectory(backupPath);

      if (isZip) {
        // Extract zip first
        final extractedDir = await _extractZipBackup(backupPath);
        await restore(extractedDir);
        await _dataStore.storage.deleteDirectory(extractedDir); // Clean up
        return;
      }

      if (!isDirectory) {
        throw FormatException(
            'Invalid backup format: $backupPath is not a directory or zip file');
      }

      // Read metadata to verify backup
      final metadata = await readBackupMetadata(backupPath);
      final isFullBackup = metadata['type'] == 'full';

      final dbRootDir = _dataStore.config.dbPath!;

      if (isFullBackup) {
        await _restoreFullBackup(backupPath, dbRootDir);
      } else {
        await _restorePartialBackup(backupPath);
      }

      await _dataStore.close();
      await _dataStore.initialize();

      Logger.info('Database restored successfully',
          label: 'BackupManager.restore');
    } catch (e) {
      Logger.error('Failed to restore from backup: $e',
          label: 'BackupManager.restore');
      rethrow;
    }
  }

  /// Extract a zip backup to a temporary directory
  /// Using archive package for cross-platform support
  Future<String> _extractZipBackup(String zipPath) async {
    if (kIsWeb) {
      throw UnsupportedError('Zip extraction not supported on web platform');
    }

    final tempDir = await Directory.systemTemp.createTemp('tostore_backup_');
    final tempPath = tempDir.path;

    try {
      Logger.info('Extracting zip backup to: $tempPath',
          label: 'BackupManager._extractZipBackup');

      try {
        await extractFileToDisk(zipPath, tempPath);
      } catch (e) {
        Logger.error('Failed to extract ZIP file: $e',
            label: 'BackupManager._extractZipBackup');

        // try alternative unzip method
        final bytes = await File(zipPath).readAsBytes();
        final archive = ZipDecoder().decodeBytes(bytes);

        for (final file in archive) {
          final filename = file.name;
          if (file.isFile) {
            final data = file.content as List<int>;
            final outFile = File('$tempPath/$filename');
            await outFile.parent.create(recursive: true);
            await outFile.writeAsBytes(data);
          } else {
            await Directory('$tempPath/$filename').create(recursive: true);
          }
        }
      }

      Logger.info('Zip backup extracted successfully',
          label: 'BackupManager._extractZipBackup');

      return tempPath;
    } catch (e) {
      // Clean up temp directory on failure
      await tempDir.delete(recursive: true);
      Logger.error('Failed to extract zip backup: $e',
          label: 'BackupManager._extractZipBackup');
      rethrow;
    }
  }

  /// Verify backup integrity
  Future<bool> verifyBackup(String backupPath) async {
    try {
      // Determine backup type
      final isZip = backupPath.endsWith('.zip');
      final isDirectory = await _isDirectory(backupPath);

      if (!isDirectory && !isZip) {
        Logger.error('Invalid backup format: not a directory or zip file',
            label: 'BackupManager.verifyBackup');
        return false;
      }

      if (isZip) {
        // For zip files, verify archive integrity
        try {
          final file = File(backupPath);
          if (!await file.exists()) return false;

          final bytes = await file.readAsBytes();
          final archive = ZipDecoder().decodeBytes(bytes);

          // verify if essential files are included
          final hasMeta = archive.findFile('meta.json') != null;
          return hasMeta;
        } catch (e) {
          Logger.error('Zip file verification failed: $e',
              label: 'BackupManager.verifyBackup');
          return false;
        }
      }

      // For directories, check for essential components
      final metaPath = pathJoin(backupPath, 'meta.json');
      if (!await _dataStore.storage.existsFile(metaPath)) {
        Logger.error('Missing metadata file in backup',
            label: 'BackupManager.verifyBackup');
        return false;
      }

      // Read metadata to determine backup type
      final metadata = await readBackupMetadata(backupPath);
      final isFullBackup = metadata['type'] == 'full';

      if (isFullBackup) {
        // For full backups, verify some essential directories
        // This is a basic check - could be expanded
        final spacesExists = await _dataStore.storage
            .existsDirectory(pathJoin(backupPath, 'spaces'));
        final globalExists = await _dataStore.storage
            .existsDirectory(pathJoin(backupPath, 'global'));

        if (!spacesExists && !globalExists) {
          Logger.error('Missing essential directories in full backup',
              label: 'BackupManager.verifyBackup');
          return false;
        }
      } else {
        // For partial backups, check base directory
        final spacesPath = pathJoin(backupPath, 'spaces');
        if (!await _dataStore.storage.existsDirectory(spacesPath)) {
          Logger.error('Missing spaces directory in partial backup',
              label: 'BackupManager.verifyBackup');
          return false;
        }
      }

      return true;
    } catch (e) {
      Logger.error('Failed to verify backup: $e',
          label: 'BackupManager.verifyBackup');
      return false;
    }
  }

  /// Add improved directory check method
  Future<bool> _isDirectory(String path) async {
    // First check if it's a file
    if (await _dataStore.storage.existsFile(path)) {
      return false;
    }

    // Auxiliary check based on file extension (optional, only if naming rules are strict)
    // If path has a typical file extension, assume it's a file
    if (path.contains('.')) {
      final extension = path.split('.').last.toLowerCase();
      final commonFileExtensions = {
        'json',
        'txt',
        'dat',
        'idx',
        'log',
        'bin',
        'zip'
      };
      if (commonFileExtensions.contains(extension)) {
        return false;
      }
    }

    // Then check if it's a directory
    if (await _dataStore.storage.existsDirectory(path)) {
      return true;
    }

    // If existsDirectory returns false, try using listDirectory to further confirm
    // On Web platform, existsDirectory might not be accurate
    try {
      final items = await _dataStore.storage.listDirectory(path);
      if (items.isNotEmpty) {
        Logger.warn(
            'Path $path is considered a directory based on listDirectory result, despite existsDirectory returning false',
            label: 'BackupManager._isDirectory');
        return true;
      }
    } catch (e) {
      Logger.warn('Failed to list directory for path $path: $e',
          label: 'BackupManager._isDirectory');
    }

    return false;
  }
}

/// file change record
class FileChange {
  final String filePath;
  final DateTime modifiedTime;

  FileChange({
    required this.filePath,
    required this.modifiedTime,
  });
}
