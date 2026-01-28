import 'dart:async';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import '../Interface/platform_interface.dart';
import '../handler/logger.dart';
import '../core/storage_adapter.dart';

/// Web platform implementation
class PlatformHandlerImpl implements PlatformInterface {
  static final Map<String, String> _tempDirs = {};
  static int _tempCounter = 0;

  @override
  bool get isMobile => false;

  @override
  bool get isDesktop => false;

  @override
  int get processorCores {
    return 2;
  }

  @override
  bool get isTestEnvironment => false;

  @override
  bool get isWeb => true;

  @override
  bool get isAndroid => false;

  @override
  bool get isIOS => false;

  @override
  bool get isWindows => false;

  @override
  bool get isMacOS => false;

  @override
  bool get isLinux => false;

  @override
  Future<int> getSystemMemoryMB() async {
    return 512;
  }

  @override
  Future<int> getAvailableSystemMemoryMB({bool forceRefresh = false}) async {
    // Web platform cannot accurately get available memory, return an estimated value (40% of total memory)
    return 204; // 512 * 0.4
  }

  @override
  Future<String> getPathApp() async {
    return '';
  }

  @override
  Future<String> createTempDirectory(String prefix) async {
    try {
      final storage = StorageAdapter();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final counter = _tempCounter++;

      // use a better path format for web
      final tempPath = 'temp/${prefix}_${timestamp}_$counter';

      // actually create directory
      await storage.ensureDirectoryExists(tempPath);

      // record created temporary directory
      _tempDirs[tempPath] = tempPath;

      return tempPath;
    } catch (e) {
      Logger.error('Web platform create temporary directory failed: $e',
          label: 'PlatformHandlerWeb.createTempDirectory');

      final fallbackPath =
          'temp/fallback_${DateTime.now().millisecondsSinceEpoch}';
      _tempDirs[fallbackPath] = fallbackPath;
      return fallbackPath;
    }
  }

  @override
  Future<void> deleteDirectory(String path, {bool recursive = true}) async {
    try {
      final storage = StorageAdapter();

      // actually delete directory
      if (await storage.existsDirectory(path)) {
        await storage.deleteDirectory(path);
      }
    } catch (e) {
      Logger.error('Web platform delete directory failed: $path - $e',
          label: 'PlatformHandlerWeb.deleteDirectory');
    } finally {
      // remove from record
      _tempDirs.remove(path);
    }
  }

  /// compress directory to ZIP file
  @override
  Future<void> compressDirectory(String sourceDir, String targetZip) async {
    try {
      final archive = Archive();
      final storage = StorageAdapter();

      // check if source directory exists
      if (!await storage.existsDirectory(sourceDir)) {
        Logger.info('Source directory not found: $sourceDir');
        return;
      }

      final files = await storage.listDirectory(sourceDir, recursive: true);

      for (final filePath in files) {
        try {
          if (await storage.existsFile(filePath)) {
            // calculate relative path
            final relativePath = filePath.substring(sourceDir.length + 1);

            // read file content
            final bytes = await storage.readAsBytes(filePath);
            if (bytes.isNotEmpty) {
              // create ArchiveFile and add to archive
              final archiveFile =
                  ArchiveFile(relativePath, bytes.length, bytes);
              archive.addFile(archiveFile);
            } else {
              Logger.warn('File read is empty: $filePath',
                  label: 'PlatformHandlerWeb.compressDirectory');
            }
          }
        } catch (fileError) {
          Logger.error('Error processing file: $filePath - $fileError',
              label: 'PlatformHandlerWeb.compressDirectory');
        }
      }

      if (archive.files.isEmpty) {
        return;
      }

      // write archive to file
      final encodedBytes = ZipEncoder().encode(archive);
      if (encodedBytes.isNotEmpty) {
        await storage.writeAsBytes(targetZip, Uint8List.fromList(encodedBytes));
      } else {
        Logger.info('ZIP encoding result is empty');
      }
    } catch (e) {
      Logger.error('Web platform compress directory failed: $e',
          label: 'PlatformHandlerWeb.compressDirectory');
      rethrow;
    }
  }

  /// decompress ZIP file to specified directory
  @override
  Future<void> extractZip(String zipPath, String targetDir) async {
    try {
      final storage = StorageAdapter();

      // ensure target directory exists
      await storage.ensureDirectoryExists(targetDir);

      // check if ZIP file exists
      if (!await storage.existsFile(zipPath)) {
        throw Exception('ZIP file not found: $zipPath');
      }

      // read ZIP file content
      final bytes = await storage.readAsBytes(zipPath);
      if (bytes.isEmpty) {
        throw Exception('Failed to read ZIP file');
      }

      // decode ZIP file
      final archive = ZipDecoder().decodeBytes(bytes);
      Logger.info(
          'Web platform decode ZIP file successfully, contains ${archive.files.length} files',
          label: 'PlatformHandlerWeb.extractZip');

      for (final file in archive) {
        try {
          final filename = file.name;
          if (file.isFile) {
            final data = file.content as List<int>;
            final outFilePath = '$targetDir/$filename';

            final dirPath =
                outFilePath.substring(0, outFilePath.lastIndexOf('/'));
            await storage.ensureDirectoryExists(dirPath);

            await storage.writeAsBytes(outFilePath, Uint8List.fromList(data));
          } else {
            await storage.ensureDirectoryExists('$targetDir/$filename');
          }
        } catch (fileError) {
          Logger.error('Error decompressing file: ${file.name} - $fileError',
              label: 'PlatformHandlerWeb.extractZip');
        }
      }
    } catch (e) {
      Logger.error('Web platform extract ZIP file failed: $e',
          label: 'PlatformHandlerWeb.extractZip');
      rethrow;
    }
  }

  /// Verify if a ZIP file is valid and optionally check if it contains a specific file
  @override
  Future<bool> verifyZipFile(String zipPath, {String? requiredFile}) async {
    try {
      final storage = StorageAdapter();

      // Check if file exists
      if (!await storage.existsFile(zipPath)) {
        Logger.warn('ZIP file does not exist: $zipPath',
            label: 'PlatformHandlerWeb.verifyZipFile');
        return false;
      }

      // Read file bytes
      final bytes = await storage.readAsBytes(zipPath);
      if (bytes.isEmpty) {
        Logger.warn('ZIP file is empty: $zipPath',
            label: 'PlatformHandlerWeb.verifyZipFile');
        return false;
      }

      // Web platform simple validation - just check if the file has the ZIP signature
      // ZIP files start with the signature: PK\x03\x04
      if (bytes.length < 4 ||
          bytes[0] != 0x50 || // 'P'
          bytes[1] != 0x4B || // 'K'
          bytes[2] != 0x03 || // '\x03'
          bytes[3] != 0x04) {
        // '\x04'
        Logger.warn('File is not a valid ZIP (wrong signature): $zipPath',
            label: 'PlatformHandlerWeb.verifyZipFile');
        return false;
      }

      // For Web platform, if a specific file is required, we need to actually
      // try to decode the ZIP to verify, which is more expensive
      if (requiredFile != null) {
        try {
          // Attempt to decode the ZIP
          final archive = ZipDecoder().decodeBytes(bytes);

          // Check if the required file exists
          final hasRequiredFile = archive.findFile(requiredFile) != null;
          if (!hasRequiredFile) {
            Logger.warn('Required file not found in ZIP: $requiredFile',
                label: 'PlatformHandlerWeb.verifyZipFile');
            return false;
          }
        } catch (decodeError) {
          Logger.error('Failed to decode ZIP file: $decodeError',
              label: 'PlatformHandlerWeb.verifyZipFile');
          return false;
        }
      }

      return true;
    } catch (e) {
      Logger.error('Error verifying ZIP file: $e',
          label: 'PlatformHandlerWeb.verifyZipFile');
      return false;
    }
  }

  @override
  int get deviceFingerprint {
    return 0;
  }

  @override
  bool get supportsHardwareKeyDerivation {
    return false;
  }
}
