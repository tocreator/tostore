import 'dart:convert';

import 'package:path/path.dart' as p;

import '../handler/common.dart';
import '../handler/logger.dart';
import 'data_store_impl.dart';
import '../model/backup_scope.dart';
import '../model/backup_metadata.dart';
import '../handler/platform_handler.dart';

/// backup manager
class BackupManager {
  final DataStoreImpl _dataStore;

  BackupManager(this._dataStore);

  /// Extract file name or directory name from path
  String _getFileName(String path) {
    final normalizedPath = path.replaceAll('\\', '/');
    final parts = normalizedPath.split('/');
    return parts.isEmpty ? path : parts.last;
  }

  /// Create backup using directory-based approach
  /// Returns the path to the backup directory or zip file
  ///
  /// Parameters:
  /// - compress: Whether to compress the backup into a zip file
  /// - fullBackup: If true, backs up the entire database directory including init files
  ///               If false, only backs up the spaces and global directories
  Future<String> createBackup(
      {bool compress = false,
      BackupScope scope = BackupScope.currentSpaceWithGlobal}) async {
    final timestamp = _formatBackupTimestamp();
    final backupPath = _dataStore.pathManager.getBackupPath();
    final backupDir = pathJoin(backupPath, 'backup_$timestamp');

    try {
      Logger.info(
          'Creating backup using directory-based approach, scope=$scope',
          label: 'BackupManager.createBackup');

      // Ensure backup directory exists
      await _dataStore.storage.ensureDirectoryExists(backupPath);
      await _dataStore.storage.ensureDirectoryExists(backupDir);

      // Check if directory was created successfully
      if (!await _dataStore.storage.existsDirectory(backupDir)) {
        if (!PlatformHandler.isWeb) {
          throw StateError('Failed to create backup directory: $backupDir');
        }
      }

      // Create metadata file with backup information
      final meta = BackupMetadata(
        timestamp: timestamp,
        version: await _dataStore.getVersion(),
        scope: scope,
        compressed: compress,
      );
      await _dataStore.storage.writeAsString(
          pathJoin(backupDir, 'meta.json'), jsonEncode(meta.toJson()));

      if (scope == BackupScope.database) {
        // Full database backup: copy the entire database directory (excluding backups dir)
        final dbRootDir = _dataStore.instancePath!;
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
        // Copy current space directory
        final basePath = _dataStore.pathManager.getSpacePath();
        final backupSpacePath =
            _dataStore.pathManager.getSpacePath(rootPath: backupDir);
        if (await _isDirectory(basePath)) {
          await _safeCopyDirectory(basePath, backupSpacePath);
        }

        // Optionally copy global directory
        if (scope == BackupScope.currentSpaceWithGlobal) {
          final globalPath = _dataStore.pathManager.getGlobalPath();
          final backupGlobalPath =
              _dataStore.pathManager.getGlobalPath(rootPath: backupDir);
          if (await _isDirectory(globalPath)) {
            await _safeCopyDirectory(globalPath, backupGlobalPath);
          }
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

  /// Format timestamp for safe filesystem naming: no ':', '.', '+'
  String _formatBackupTimestamp() {
    final ts = DateTime.now().toUtc().toIso8601String();
    // Example: 2025-09-26T12:34:56.123456Z -> 2025-09-26T12-34-56-123456Z
    return ts.replaceAll(':', '-').replaceAll('.', '-').replaceAll('+', '-');
  }

  /// Compress directory to a zip file
  /// Using PlatformHandler for cross-platform support
  Future<void> _compressDirectory(String sourceDir, String targetZip) async {
    try {
      Logger.info('Compressing directory: $sourceDir to $targetZip',
          label: 'BackupManager._compressDirectory');

      await PlatformHandler.compressDirectory(sourceDir, targetZip);

      Logger.info('Directory compressed successfully',
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

      final items = await _dataStore.storage.listDirectory(sourcePath);
      for (final itemPath in items) {
        final fileName = _getFileName(itemPath);
        final targetItemPath = pathJoin(destPath, fileName);

        if (await _isDirectory(itemPath)) {
          await _safeCopyDirectory(itemPath, targetItemPath);
        } else {
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
  Future<void> _restoreFullBackup(String backupPath, String dbRootDir,
      {bool cleanupBeforeRestore = true}) async {
    try {
      // Clean database directory but preserve backups if requested
      if (cleanupBeforeRestore) {
        await _cleanDatabaseRoot(dbRootDir);
      }

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
  Future<void> _restorePartialBackup(String backupPath,
      {bool cleanupBeforeRestore = true, bool includeGlobal = true}) async {
    try {
      final basePath = _dataStore.pathManager.getSpacePath();
      final globalPath = _dataStore.pathManager.getGlobalPath();

      // Clean base directory
      if (cleanupBeforeRestore) {
        if (await _dataStore.storage.existsDirectory(basePath)) {
          await _dataStore.storage.deleteDirectory(basePath);
          await _dataStore.storage.ensureDirectoryExists(basePath);
        }
      }

      // Clean global directory when included in this restore
      if (includeGlobal && cleanupBeforeRestore) {
        if (await _dataStore.storage.existsDirectory(globalPath)) {
          await _dataStore.storage.deleteDirectory(globalPath);
          await _dataStore.storage.ensureDirectoryExists(globalPath);
        }
      }

      // Copy base directory from backup
      final backupBasePath = _dataStore.pathManager.getSpacePath(
          rootPath: backupPath, spaceName: _dataStore.currentSpaceName);
      if (await _isDirectory(backupBasePath)) {
        await _safeCopyDirectory(backupBasePath, basePath);
      }

      // Copy global directory from backup (optional)
      if (includeGlobal) {
        final backupGlobalPath =
            _dataStore.pathManager.getGlobalPath(rootPath: backupPath);
        if (await _isDirectory(backupGlobalPath)) {
          await _safeCopyDirectory(backupGlobalPath, globalPath);
        }
      }
    } catch (e) {
      Logger.error('Error during partial backup restoration: $e',
          label: 'BackupManager.restore');
      rethrow;
    }
  }

  /// Restore from backup
  /// `backupPath` can be a zip file or a backup root directory
  /// `deleteAfterRestore` controls deletion of the original backup source after successful restore
  Future<void> restore(String backupPath,
      {bool deleteAfterRestore = false,
      bool cleanupBeforeRestore = true}) async {
    try {
      final String originalInput = backupPath;
      final bool inputIsZip = originalInput.toLowerCase().endsWith('.zip');

      // Normalize to a backup root directory that contains meta.json
      String normalizedRoot = originalInput;
      String? extractedTempDir;

      if (inputIsZip) {
        // Extract zip into a temporary directory
        extractedTempDir = await _extractZipBackup(originalInput);
        normalizedRoot = extractedTempDir;
      } else if (await _dataStore.storage
          .existsFile(pathJoin(originalInput, 'meta.json'))) {
        // Accept as backup root if it contains meta.json even when directory APIs are unreliable
        normalizedRoot = originalInput;
      } else if (await _isDirectory(originalInput)) {
        // Already a directory root
        normalizedRoot = originalInput;
      } else {
        throw FormatException('Invalid backup path: $originalInput');
      }

      // Ensure meta.json exists under normalizedRoot
      final metaPath = pathJoin(normalizedRoot, 'meta.json');
      if (!await _dataStore.storage.existsFile(metaPath)) {
        throw StateError(
            'Backup metadata file not found under: $normalizedRoot');
      }

      // Read metadata to choose restore scope
      final metaMap = await readBackupMetadata(normalizedRoot);
      final metadata = BackupMetadata.fromJson(metaMap);
      final dbRootDir = _dataStore.instancePath!;

      // Quiesce database IO before deleting/replacing directories to avoid ENOTEMPTY/EBUSY races.
      // We only need to CLOSE the current instance here; it will be re-opened after files are restored.
      try {
        if (_dataStore.isInitialized) {
          await _dataStore.close(persistChanges: false, closeStorage: false);
        }
      } catch (e) {
        Logger.warn('Close datastore before restore failed: $e',
            label: 'BackupManager.restore');
      }

      if (metadata.scope == BackupScope.database) {
        await _restoreFullBackup(normalizedRoot, dbRootDir,
            cleanupBeforeRestore: cleanupBeforeRestore);
      } else {
        final bool includeGlobal =
            metadata.scope == BackupScope.currentSpaceWithGlobal;
        await _restorePartialBackup(normalizedRoot,
            cleanupBeforeRestore: cleanupBeforeRestore,
            includeGlobal: includeGlobal);
      }

      // Handle deletion of original backup source if requested
      if (deleteAfterRestore) {
        if (inputIsZip) {
          await _dataStore.storage.deleteFile(originalInput);
        } else if (await _isDirectory(originalInput)) {
          await _dataStore.storage.deleteDirectory(originalInput);
        }
      }

      // Cleanup extracted temporary directory if used
      if (extractedTempDir != null) {
        try {
          await PlatformHandler.deleteDirectory(extractedTempDir);
        } catch (_) {}
      }

      await _dataStore.initialize(reinitialize: true);

      Logger.info('Database restored successfully',
          label: 'BackupManager.restore');
    } catch (e) {
      Logger.error('Failed to restore from backup: $e',
          label: 'BackupManager.restore');
      rethrow;
    }
  }

  /// Extract a zip backup to a temporary directory
  /// Using PlatformHandler for cross-platform support
  Future<String> _extractZipBackup(String zipPath) async {
    final tempPath =
        await PlatformHandler.createTempDirectory('tostore_backup_');

    try {
      Logger.info('Extracting zip backup to: $tempPath',
          label: 'BackupManager._extractZipBackup');

      // use PlatformHandler's extractZip method
      await PlatformHandler.extractZip(zipPath, tempPath);

      Logger.info('Zip backup extracted successfully',
          label: 'BackupManager._extractZipBackup');

      return tempPath;
    } catch (e) {
      // Clean up temp directory on failure
      await PlatformHandler.deleteDirectory(tempPath);
      Logger.error('Failed to extract zip backup: $e',
          label: 'BackupManager._extractZipBackup');
      rethrow;
    }
  }

  /// Verify backup integrity
  /// [fast] = true: only do fast verification (zip exists & size threshold, directory exists & meta.json exists)
  /// [fast] = false: parse BackupMetadata and do more strict structure verification based on scope
  Future<bool> verifyBackup(String backupPath, {bool fast = true}) async {
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
        // Fast path: file exists + size threshold
        try {
          if (!await _dataStore.storage.existsFile(backupPath)) return false;
          final size = await _dataStore.storage.getFileSize(backupPath);
          if (size <= 2048) {
            Logger.warn('ZIP file size too small to be valid: ${size}B',
                label: 'BackupManager.verifyBackup');
            return false;
          }

          if (fast) return true;

          // Strict: decode zip to check required file exists without full extract
          // Use platform verify to inspect entries efficiently
          return await PlatformHandler.verifyZipFile(backupPath,
              requiredFile: 'meta.json');
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

      // Read metadata to determine backup scope (use BackupMetadata model)
      if (fast) {
        // Fast: only check if meta.json can be parsed
        try {
          final metaMap = await readBackupMetadata(backupPath);
          BackupMetadata.fromJson(metaMap);
          return true;
        } catch (e) {
          Logger.error('Fast verify: failed to parse metadata: $e',
              label: 'BackupManager.verifyBackup');
          return false;
        }
      }

      final metaMap = await readBackupMetadata(backupPath);
      final meta = BackupMetadata.fromJson(metaMap);

      // Build standardized paths via PathManager
      final backupSpaceDir =
          _dataStore.pathManager.getSpacePath(rootPath: backupPath);
      final spacesRoot = p.dirname(backupSpaceDir);
      final backupGlobalDir =
          _dataStore.pathManager.getGlobalPath(rootPath: backupPath);

      if (meta.scope == BackupScope.database) {
        // For full backups, verify some essential directories
        // This is a basic check - could be expanded
        final spacesExists =
            await _dataStore.storage.existsDirectory(spacesRoot);
        final globalExists =
            await _dataStore.storage.existsDirectory(backupGlobalDir);

        if (!spacesExists && !globalExists) {
          // at Web platform, try to verify by listing files if directory check fails
          if (PlatformHandler.isWeb) {
            try {
              // try to list directory content
              final spacesFiles =
                  await _dataStore.storage.listDirectory(spacesRoot);
              final globalFiles =
                  await _dataStore.storage.listDirectory(backupGlobalDir);

              if (spacesFiles.isNotEmpty || globalFiles.isNotEmpty) {
                Logger.warn(
                    'Web platform: Directory existence check failed but found files in spaces or global directories',
                    label: 'BackupManager.verifyBackup');
                return true;
              }
            } catch (e) {
              // ignore listing directory error
            }
          }

          Logger.error('Missing essential directories in full backup',
              label: 'BackupManager.verifyBackup');
          return false;
        }
      } else {
        // For partial backups, check current space directory exists and is not empty
        if (await _dataStore.storage.existsDirectory(backupSpaceDir)) {
          try {
            final items =
                await _dataStore.storage.listDirectory(backupSpaceDir);
            if (items.isEmpty) {
              Logger.error('Spaces directory is empty in partial backup',
                  label: 'BackupManager.verifyBackup');
              return false;
            }
          } catch (e) {
            // On environments where listing may fail (e.g., some web FS), accept existence
          }
        } else {
          if (PlatformHandler.isWeb) {
            try {
              final files =
                  await _dataStore.storage.listDirectory(backupSpaceDir);
              if (files.isNotEmpty) {
                Logger.warn(
                    'Web platform: Directory existence check failed but found files in spaces',
                    label: 'BackupManager.verifyBackup');
                return true;
              }
            } catch (_) {}
          }
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
    // Prefer explicit directory/file checks first
    if (await _dataStore.storage.existsDirectory(path)) {
      return true;
    }
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
