import 'dart:io' if (dart.library.html) '../Interface/io_stub.dart';
import 'dart:async';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive_io.dart';
import '../Interface/platform_interface.dart';
import '../handler/logger.dart';
import 'flutter_check.dart';

/// Native platform implementation
class PlatformHandlerImpl implements PlatformInterface {
  // Platform type cache - these remain constant within the application lifecycle
  static bool? _cachedIsMobile;
  static bool? _cachedIsDesktop;
  static bool? _cachedIsTestEnvironment;
  static bool? _cachedIsAndroid;
  static bool? _cachedIsIOS;
  static bool? _cachedIsWindows;
  static bool? _cachedIsMacOS;
  static bool? _cachedIsLinux;
  static bool? _cachedIsServerEnvironment;

  // path provider cache
  static String? _cachedAppPath;

  // Processor info cache - these remain constant within the application lifecycle
  static int? _cachedProcessorCores;
  static DateTime? _lastProcessorCheck;
  static const Duration _processorCacheTimeout = Duration(hours: 1);

  // Cache for memory values
  static int? _cachedSystemMemoryMB;
  static DateTime? _lastSystemMemoryFetch;

  static int? _cachedAvailableSystemMemoryMB;
  static DateTime? _lastAvailableSystemMemoryFetch;

  static const _memoryFetchTimeout = Duration(seconds: 5);

  @override
  bool get isMobile {
    // Lazy load cache: only calculate when first accessed
    if (_cachedIsMobile == null) {
      try {
        _cachedIsMobile = Platform.isAndroid || Platform.isIOS;
      } catch (e) {
        _cachedIsMobile = false;
        Logger.warn('Error detecting mobile platform: $e',
            label: 'PlatformHandlerImpl.isMobile');
      }
    }
    return _cachedIsMobile!;
  }

  @override
  bool get isDesktop {
    // Lazy load cache: only calculate when first accessed
    if (_cachedIsDesktop == null) {
      try {
        _cachedIsDesktop =
            Platform.isWindows || Platform.isMacOS || Platform.isLinux;
      } catch (e) {
        _cachedIsDesktop = false;
        Logger.warn('Error detecting desktop platform: $e',
            label: 'PlatformHandlerImpl.isDesktop');
      }
    }
    return _cachedIsDesktop!;
  }

  @override
  int get processorCores {
    final now = DateTime.now();

    // Check if cache is valid (processor core count unlikely to change, but set long timeout for safety)
    if (_cachedProcessorCores != null &&
        _lastProcessorCheck != null &&
        now.difference(_lastProcessorCheck!) < _processorCacheTimeout) {
      return _cachedProcessorCores!;
    }

    try {
      _cachedProcessorCores = Platform.numberOfProcessors;
      _lastProcessorCheck = now;
      return _cachedProcessorCores!;
    } catch (e) {
      // Cache default value
      _cachedProcessorCores = 4;
      _lastProcessorCheck = now;
      return _cachedProcessorCores!;
    }
  }

  @override
  bool get isTestEnvironment {
    if (_cachedIsTestEnvironment == null) {
      try {
        _cachedIsTestEnvironment =
            Platform.environment.containsKey('FLUTTER_TEST');
      } catch (e) {
        _cachedIsTestEnvironment = false;
      }
    }
    return _cachedIsTestEnvironment!;
  }

  @override
  bool get isWeb => false;

  @override
  bool get isAndroid {
    if (_cachedIsAndroid == null) {
      try {
        _cachedIsAndroid = Platform.isAndroid;
      } catch (e) {
        _cachedIsAndroid = false;
      }
    }
    return _cachedIsAndroid!;
  }

  @override
  bool get isIOS {
    if (_cachedIsIOS == null) {
      try {
        _cachedIsIOS = Platform.isIOS;
      } catch (e) {
        _cachedIsIOS = false;
      }
    }
    return _cachedIsIOS!;
  }

  @override
  bool get isWindows {
    if (_cachedIsWindows == null) {
      try {
        _cachedIsWindows = Platform.isWindows;
      } catch (e) {
        _cachedIsWindows = false;
      }
    }
    return _cachedIsWindows!;
  }

  @override
  bool get isMacOS {
    if (_cachedIsMacOS == null) {
      try {
        _cachedIsMacOS = Platform.isMacOS;
      } catch (e) {
        _cachedIsMacOS = false;
      }
    }
    return _cachedIsMacOS!;
  }

  @override
  bool get isLinux {
    if (_cachedIsLinux == null) {
      try {
        _cachedIsLinux = Platform.isLinux;
      } catch (e) {
        _cachedIsLinux = false;
      }
    }
    return _cachedIsLinux!;
  }

  bool get isServerEnvironment {
    if (_cachedIsServerEnvironment == null) {
      try {
        // Server environment detection strategy
        if (isLinux) {
          // Linux server may be a database server
          _cachedIsServerEnvironment = true;
        } else if (isMacOS && processorCores >= 8) {
          // Mac server usually has more processor cores
          _cachedIsServerEnvironment = true;
        } else {
          _cachedIsServerEnvironment = false;
        }
      } catch (e) {
        _cachedIsServerEnvironment = false;
        Logger.warn('Error detecting server environment: $e',
            label: 'PlatformHandlerImpl.isServerEnvironment');
      }
    }
    return _cachedIsServerEnvironment!;
  }

  /// Clear memory related caches
  void clearMemoryCaches() {
    _cachedSystemMemoryMB = null;
    _lastSystemMemoryFetch = null;
    _cachedAvailableSystemMemoryMB = null;
    _lastAvailableSystemMemoryFetch = null;
  }

  /// Get system memory size (MB)
  @override
  Future<int> getSystemMemoryMB() async {
    final now = DateTime.now();
    if (_cachedSystemMemoryMB != null &&
        _lastSystemMemoryFetch != null &&
        now.difference(_lastSystemMemoryFetch!) < _memoryFetchTimeout) {
      return _cachedSystemMemoryMB!;
    }

    int memoryMB;
    try {
      if (isWindows) {
        memoryMB = await _getWindowsMemory();
      } else if (isLinux) {
        memoryMB = await _getLinuxMemory();
      } else if (isMacOS) {
        memoryMB = await _getMacOSMemory();
      } else if (isAndroid) {
        memoryMB = await _getAndroidMemory();
      } else {
        // Unknown platform or retrieval failed, estimate based on core count
        memoryMB = processorCores * 1024;
      }
    } catch (e) {
      // Return a safe default value based on platform
      memoryMB = isMobile ? 2048 : 4096;
    }

    _cachedSystemMemoryMB = memoryMB;
    _lastSystemMemoryFetch = now;
    return memoryMB;
  }

  /// Get available system memory size (MB)
  @override
  Future<int> getAvailableSystemMemoryMB({bool forceRefresh = false}) async {
    final now = DateTime.now();
    if (!forceRefresh &&
        _cachedAvailableSystemMemoryMB != null &&
        _lastAvailableSystemMemoryFetch != null &&
        now.difference(_lastAvailableSystemMemoryFetch!) <
            _memoryFetchTimeout) {
      return _cachedAvailableSystemMemoryMB!;
    }

    int memoryMB;
    try {
      if (isWindows) {
        memoryMB = await _getWindowsAvailableMemory();
      } else if (isLinux) {
        memoryMB = await _getLinuxAvailableMemory();
      } else if (isMacOS) {
        memoryMB = await _getMacOSAvailableMemory();
      } else if (isAndroid) {
        memoryMB = await _getAndroidAvailableMemory();
      } else {
        // Unknown platform or retrieval failed, estimate 25% of total
        memoryMB = (await getSystemMemoryMB()) ~/ 4;
      }
    } catch (e) {
      // Return a safe default value based on platform
      memoryMB = isMobile ? 512 : 1024;
    }

    _cachedAvailableSystemMemoryMB = memoryMB;
    _lastAvailableSystemMemoryFetch = now;
    return memoryMB;
  }

  /// Get app save directory, for data, config, etc.
  /// In a Flutter environment, it uses `path_provider`. In a pure Dart environment,
  /// it falls back to OS-specific directories.
  @override
  Future<String> getPathApp() async {
    if (_cachedAppPath != null) {
      return _cachedAppPath!;
    }

    String? appPath;
    const appName = 'tostore';
    const dataDirName = 'common';

    // If in a Flutter environment, prioritize path_provider.
    if (isFlutterEnvironment) {
      try {
        final docDir = await getApplicationDocumentsDirectory();
        appPath = path.join(docDir.path, 'common');
      } catch (e) {
        Logger.error(
            'Flutter environment detected, but path_provider failed. '
            'Ensure "WidgetsFlutterBinding.ensureInitialized()" is called. Error: $e',
            label: 'PlatformHandlerImpl.getPathApp');
        // Fall through to OS-specific logic as a backup.
      }
    }

    // If not in a Flutter environment or if path_provider failed, use OS-specific paths.
    if (appPath == null) {
      String? basePath;
      try {
        if (isWindows) {
          basePath = Platform.environment['APPDATA'];
          if (basePath != null) {
            basePath = path.join(basePath, appName);
          }
        } else if (isMacOS) {
          final home = Platform.environment['HOME'];
          if (home != null) {
            basePath =
                path.join(home, 'Library', 'Application Support', appName);
          }
        } else if (isLinux) {
          // Respect XDG Base Directory Specification.
          final xdgDataHome = Platform.environment['XDG_DATA_HOME'];
          if (xdgDataHome != null && xdgDataHome.isNotEmpty) {
            basePath = path.join(xdgDataHome, appName);
          } else {
            final home = Platform.environment['HOME'];
            if (home != null) {
              basePath = path.join(home, '.local', 'share', appName);
            }
          }
        }
      } catch (e) {
        Logger.error('Error getting environment variables for path: $e',
            label: 'PlatformHandlerImpl.getPathApp');
      }

      if (basePath != null && basePath.isNotEmpty) {
        appPath = path.join(basePath, dataDirName);
      }
    }

    // If a path was determined, create the directory and cache it.
    if (appPath != null) {
      try {
        final directory = Directory(appPath);
        if (!await directory.exists()) {
          await directory.create(recursive: true);
        }
        _cachedAppPath = directory.path;
        return _cachedAppPath!;
      } catch (e) {
        Logger.error(
            'Failed to create application directory at $appPath. Error: $e',
            label: 'PlatformHandlerImpl.getPathApp');
        // Fall through to the final fallback.
      }
    }

    // Final fallback: use a directory in the system temp folder.
    Logger.warn(
        'Could not determine a standard application data directory. Falling back to a temporary directory. Data may be lost on system restart.',
        label: 'PlatformHandlerImpl.getPathApp');
    try {
      final tempPath =
          path.join(Directory.systemTemp.path, appName, dataDirName);
      final tempDir = Directory(tempPath);
      if (!await tempDir.exists()) {
        await tempDir.create(recursive: true);
      }
      _cachedAppPath = tempDir.path;
      return _cachedAppPath!;
    } catch (e) {
      Logger.error('Failed to create temporary directory. Error: $e',
          label: 'PlatformHandlerImpl.getPathApp');
      // As an absolute last resort, use a path in the current directory.
      final fallbackPath = path.join(Directory.current.path, '.tostore_data');
      final fallbackDir = Directory(fallbackPath);
      if (!await fallbackDir.exists()) {
        await fallbackDir.create(recursive: true);
      }
      _cachedAppPath = fallbackDir.path;
      return _cachedAppPath!;
    }
  }

  /// create temp directory
  /// return temp directory path
  @override
  Future<String> createTempDirectory(String prefix) async {
    final tempDir = await Directory.systemTemp.createTemp(prefix);
    return tempDir.path;
  }

  /// delete directory
  @override
  Future<void> deleteDirectory(String path, {bool recursive = true}) async {
    final dir = Directory(path);
    if (await dir.exists()) {
      await dir.delete(recursive: recursive);
    }
  }

  /// Get Windows system memory
  Future<int> _getWindowsMemory() async {
    try {
      // Use PowerShell to get system memory information
      final result = await Process.run('powershell', [
        '-Command',
        '(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1MB'
      ]);

      if (result.exitCode == 0 && result.stdout != null) {
        // Parse the result (PowerShell returns MB value with decimal point)
        final memoryMB = double.tryParse((result.stdout as String).trim());
        if (memoryMB != null && memoryMB > 0) {
          return memoryMB.round();
        }
      }

      // If the command fails, try to get environment variable
      final memEnv = Platform.environment['MEMORYSIZE'];
      if (memEnv != null) {
        // Try to parse the environment variable value (usually in "xxxx MB" format)
        final memMatch = RegExp(r'(\d+)').firstMatch(memEnv);
        if (memMatch != null) {
          return int.tryParse(memMatch.group(1) ?? '4096') ?? 4096;
        }
      }

      // Return an estimate based on core count if unable to retrieve
      return processorCores * 1024;
    } catch (e) {
      return 8192; // 8GB as default value
    }
  }

  /// Get Windows available memory
  Future<int> _getWindowsAvailableMemory() async {
    try {
      // Use PowerShell to get available memory information
      final result = await Process.run('powershell', [
        '-Command',
        '(Get-Counter "\\Memory\\Available MBytes").CounterSamples[0].CookedValue'
      ]);

      if (result.exitCode == 0 && result.stdout != null) {
        final memoryMB = double.tryParse((result.stdout as String).trim());
        if (memoryMB != null && memoryMB > 0) {
          return memoryMB.round();
        }
      }

      // Backup method: calculate available memory from system information
      final fallbackResult = await Process.run('powershell', [
        '-Command',
        '(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1KB'
      ]);

      if (fallbackResult.exitCode == 0 && fallbackResult.stdout != null) {
        final memoryKB =
            double.tryParse((fallbackResult.stdout as String).trim());
        if (memoryKB != null && memoryKB > 0) {
          return (memoryKB / 1024).round(); // Convert to MB
        }
      }

      // If all fail, return 25% of total memory as an estimate
      final totalMemory = await _getWindowsMemory();
      return totalMemory ~/ 4;
    } catch (e) {
      final totalMemory = await _getWindowsMemory();
      return totalMemory ~/ 4; // Return 1/4 of total memory as default value
    }
  }

  /// Get Linux system memory
  Future<int> _getLinuxMemory() async {
    try {
      // Use /proc/meminfo to get system memory
      final file = File('/proc/meminfo');
      if (await file.exists()) {
        final contents = await file.readAsString();
        final memTotalMatch =
            RegExp(r'MemTotal:\s+(\d+) kB').firstMatch(contents);

        if (memTotalMatch != null) {
          final memKB = int.tryParse(memTotalMatch.group(1) ?? '0') ?? 0;
          return (memKB / 1024).round(); // Convert to MB
        }
      }

      // Backup command: use free command
      final result = await Process.run('free', ['-m']);
      if (result.exitCode == 0 && result.stdout != null) {
        final lines = (result.stdout as String).split('\n');
        if (lines.length > 1) {
          // The second line contains memory info, format like:
          // "Mem:          7723       5516       1271        179        934       2001"
          final memParts = lines[1].split(RegExp(r'\s+'));
          if (memParts.length > 1) {
            return int.tryParse(memParts[1]) ?? (processorCores * 1024);
          }
        }
      }

      return processorCores * 1024;
    } catch (e) {
      return 4096; // 4GB as default value
    }
  }

  /// Get Linux available memory
  Future<int> _getLinuxAvailableMemory() async {
    try {
      // use /proc/meminfo to get available memory
      final file = File('/proc/meminfo');
      if (await file.exists()) {
        final contents = await file.readAsString();

        // first try to get MemAvailable (more accurate metric)
        final memAvailableMatch =
            RegExp(r'MemAvailable:\s+(\d+) kB').firstMatch(contents);

        if (memAvailableMatch != null) {
          final memKB = int.tryParse(memAvailableMatch.group(1) ?? '0') ?? 0;
          return (memKB / 1024).round(); // convert to MB
        }

        // if MemAvailable does not exist (older kernel), calculate: MemFree + Buffers + Cached
        final memFreeMatch =
            RegExp(r'MemFree:\s+(\d+) kB').firstMatch(contents);
        final buffersMatch =
            RegExp(r'Buffers:\s+(\d+) kB').firstMatch(contents);
        final cachedMatch = RegExp(r'Cached:\s+(\d+) kB').firstMatch(contents);

        if (memFreeMatch != null &&
            buffersMatch != null &&
            cachedMatch != null) {
          final memFreeKB = int.tryParse(memFreeMatch.group(1) ?? '0') ?? 0;
          final buffersKB = int.tryParse(buffersMatch.group(1) ?? '0') ?? 0;
          final cachedKB = int.tryParse(cachedMatch.group(1) ?? '0') ?? 0;

          return ((memFreeKB + buffersKB + cachedKB) / 1024)
              .round(); // convert to MB
        }
      }

      // backup command: use free command
      final result = await Process.run('free', ['-m']);
      if (result.exitCode == 0 && result.stdout != null) {
        final lines = (result.stdout as String).split('\n');
        if (lines.length > 1) {
          final memParts = lines[1].split(RegExp(r'\s+'));
          if (memParts.length > 3) {
            // free -m output format: Mem: total used free shared buffers cached
            // available memory = free + buffers + cached (usually the 4th, 6th, and 7th columns)
            return int.tryParse(memParts[3]) ?? (processorCores * 256);
          }
        }
      }

      // estimate 1/4 of total memory
      final totalMemory = await _getLinuxMemory();
      return totalMemory ~/ 4;
    } catch (e) {
      return 1024; // 1GB as default value
    }
  }

  /// Get macOS system memory
  Future<int> _getMacOSMemory() async {
    try {
      // Use sysctl command to get system memory
      final result = await Process.run('sysctl', ['-n', 'hw.memsize']);

      if (result.exitCode == 0 && result.stdout != null) {
        final bytes = int.tryParse((result.stdout as String).trim());
        if (bytes != null && bytes > 0) {
          return (bytes / (1024 * 1024)).round(); // Convert to MB
        }
      }

      // Backup command: system_profiler
      final fallbackResult =
          await Process.run('system_profiler', ['SPHardwareDataType']);
      if (fallbackResult.exitCode == 0 && fallbackResult.stdout != null) {
        final output = fallbackResult.stdout as String;
        final memMatch = RegExp(r'Memory: (\d+) GB').firstMatch(output);

        if (memMatch != null) {
          final memGB = int.tryParse(memMatch.group(1) ?? '0') ?? 0;
          return memGB * 1024; // Convert to MB
        }
      }

      return processorCores * 1024;
    } catch (e) {
      return 8192; // 8GB as default value
    }
  }

  /// Get macOS available memory
  Future<int> _getMacOSAvailableMemory() async {
    try {
      // Use vm_stat command to get memory statistics
      final result = await Process.run('vm_stat', []);

      if (result.exitCode == 0 && result.stdout != null) {
        final output = result.stdout as String;

        // Parse page size
        final pageSizeMatch =
            RegExp(r'page size of (\d+) bytes').firstMatch(output);
        final pageSize = pageSizeMatch != null
            ? int.tryParse(pageSizeMatch.group(1) ?? '4096') ?? 4096
            : 4096;

        // Parse free pages
        final freeMatch = RegExp(r'Pages free:\s+(\d+)').firstMatch(output);
        final inactiveMatch =
            RegExp(r'Pages inactive:\s+(\d+)').firstMatch(output);
        final purgableMatch =
            RegExp(r'Pages purgeable:\s+(\d+)').firstMatch(output);

        if (freeMatch != null &&
            inactiveMatch != null &&
            purgableMatch != null) {
          final freePages = int.tryParse(freeMatch.group(1) ?? '0') ?? 0;
          final inactivePages =
              int.tryParse(inactiveMatch.group(1) ?? '0') ?? 0;
          final purgablePages =
              int.tryParse(purgableMatch.group(1) ?? '0') ?? 0;

          // Calculate available memory: free pages + inactive pages + purgeable pages
          final totalAvailableBytes =
              (freePages + inactivePages + purgablePages) * pageSize;
          return (totalAvailableBytes / (1024 * 1024)).round(); // Convert to MB
        }
      }

      // Backup command: use top command
      final topResult = await Process.run('top', ['-l', '1', '-n', '0']);
      if (topResult.exitCode == 0 && topResult.stdout != null) {
        final output = topResult.stdout as String;
        // Find memory usage from top output
        final memMatch =
            RegExp(r'PhysMem: .*?(\d+)([MG]) unused').firstMatch(output);
        if (memMatch != null) {
          final value = int.tryParse(memMatch.group(1) ?? '0') ?? 0;
          final unit = memMatch.group(2);
          if (unit == 'G') {
            return value * 1024; // Convert GB to MB
          } else {
            return value; // Already in MB
          }
        }
      }

      // If all fail, estimate 1/4 of total memory
      final totalMemory = await _getMacOSMemory();
      return totalMemory ~/ 4;
    } catch (e) {
      // Return 1/4 of total memory as default value
      final totalMemory = await _getMacOSMemory();
      return totalMemory ~/ 4;
    }
  }

  /// Get Android system memory
  Future<int> _getAndroidMemory() async {
    try {
      // Use /proc/meminfo to get system memory
      final file = File('/proc/meminfo');
      if (await file.exists()) {
        final contents = await file.readAsString();
        final memTotalMatch =
            RegExp(r'MemTotal:\s+(\d+) kB').firstMatch(contents);

        if (memTotalMatch != null) {
          final memKB = int.tryParse(memTotalMatch.group(1) ?? '0') ?? 0;
          return (memKB / 1024).round(); // Convert to MB
        }
      }

      // If direct file reading fails, use command line tool
      final result = await Process.run('cat', ['/proc/meminfo']);
      if (result.exitCode == 0 && result.stdout != null) {
        final contents = result.stdout as String;
        final memTotalMatch =
            RegExp(r'MemTotal:\s+(\d+) kB').firstMatch(contents);

        if (memTotalMatch != null) {
          final memKB = int.tryParse(memTotalMatch.group(1) ?? '0') ?? 0;
          return (memKB / 1024).round(); // Convert to MB
        }
      }

      // Core count estimate
      return processorCores <= 4 ? 2048 : 4096;
    } catch (e) {
      return 2048; // 2GB as default value
    }
  }

  /// Get Android available memory
  Future<int> _getAndroidAvailableMemory() async {
    try {
      // Similar to Linux, use /proc/meminfo to get available memory
      final file = File('/proc/meminfo');
      if (await file.exists()) {
        final contents = await file.readAsString();

        // First try to get MemAvailable (more modern Android system)
        final memAvailableMatch =
            RegExp(r'MemAvailable:\s+(\d+) kB').firstMatch(contents);

        if (memAvailableMatch != null) {
          final memKB = int.tryParse(memAvailableMatch.group(1) ?? '0') ?? 0;
          return (memKB / 1024).round(); // Convert to MB
        }

        // Backup method: calculate MemFree + Cached + Buffers
        final memFreeMatch =
            RegExp(r'MemFree:\s+(\d+) kB').firstMatch(contents);
        final buffersMatch =
            RegExp(r'Buffers:\s+(\d+) kB').firstMatch(contents);
        final cachedMatch = RegExp(r'Cached:\s+(\d+) kB').firstMatch(contents);

        if (memFreeMatch != null &&
            buffersMatch != null &&
            cachedMatch != null) {
          final memFreeKB = int.tryParse(memFreeMatch.group(1) ?? '0') ?? 0;
          final buffersKB = int.tryParse(buffersMatch.group(1) ?? '0') ?? 0;
          final cachedKB = int.tryParse(cachedMatch.group(1) ?? '0') ?? 0;

          return ((memFreeKB + buffersKB + cachedKB) / 1024)
              .round(); // Convert to MB
        }
      }

      // If file reading fails, try using command line tool
      final result = await Process.run('cat', ['/proc/meminfo']);
      if (result.exitCode == 0 && result.stdout != null) {
        final contents = result.stdout as String;

        final memAvailableMatch =
            RegExp(r'MemAvailable:\s+(\d+) kB').firstMatch(contents);

        if (memAvailableMatch != null) {
          final memKB = int.tryParse(memAvailableMatch.group(1) ?? '0') ?? 0;
          return (memKB / 1024).round(); // Convert to MB
        }
      }

      // Estimate 25% of total memory
      final totalMemory = await _getAndroidMemory();
      return totalMemory ~/ 4;
    } catch (e) {
      return 512; // Default 512MB available
    }
  }

  /// compress directory to ZIP file
  @override
  Future<void> compressDirectory(String sourceDir, String targetZip) async {
    try {
      // use archive package
      final encoder = ZipFileEncoder();
      encoder.create(targetZip);

      // add directory
      await encoder.addDirectory(Directory(sourceDir), includeDirName: false);
      await encoder.close();
    } catch (e) {
      Logger.error('compress directory failed: $e',
          label: 'PlatformHandlerImpl.compressDirectory');
      rethrow;
    }
  }

  /// decompress ZIP file to specified directory
  @override
  Future<void> extractZip(String zipPath, String targetDir) async {
    try {
      final directory = Directory(targetDir);
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }

      await extractFileToDisk(zipPath, targetDir);
    } catch (e) {
      Logger.error('decompress ZIP file failed: $e',
          label: 'PlatformHandlerImpl.extractZip');

      // try alternative decompression method
      try {
        final bytes = await File(zipPath).readAsBytes();
        final archive = ZipDecoder().decodeBytes(bytes);

        for (final file in archive) {
          final filename = file.name;
          if (file.isFile) {
            final data = file.content as List<int>;
            final outFile = File('$targetDir/$filename');
            await outFile.parent.create(recursive: true);
            await outFile.writeAsBytes(data);
          } else {
            await Directory('$targetDir/$filename').create(recursive: true);
          }
        }
      } catch (fallbackError) {
        Logger.error(
            'alternative decompression method also failed: $fallbackError',
            label: 'PlatformHandlerImpl.extractZip');
        rethrow;
      }
    }
  }

  /// Verify if a ZIP file is valid and optionally check if it contains a specific file
  @override
  Future<bool> verifyZipFile(String zipPath, {String? requiredFile}) async {
    try {
      // Check if file exists
      final file = File(zipPath);
      if (!await file.exists()) {
        Logger.warn('ZIP file does not exist: $zipPath',
            label: 'PlatformHandlerImpl.verifyZipFile');
        return false;
      }

      // Read file bytes
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        Logger.warn('ZIP file is empty: $zipPath',
            label: 'PlatformHandlerImpl.verifyZipFile');
        return false;
      }

      // Attempt to decode the ZIP file
      try {
        final archive = ZipDecoder().decodeBytes(bytes);

        // If a specific file is required, check for its existence
        if (requiredFile != null) {
          final hasRequiredFile = archive.findFile(requiredFile) != null;
          if (!hasRequiredFile) {
            Logger.warn('Required file not found in ZIP: $requiredFile',
                label: 'PlatformHandlerImpl.verifyZipFile');
            return false;
          }
        }

        return true;
      } catch (decodeError) {
        Logger.error('Failed to decode ZIP file: $decodeError',
            label: 'PlatformHandlerImpl.verifyZipFile');
        return false;
      }
    } catch (e) {
      Logger.error('Error verifying ZIP file: $e',
          label: 'PlatformHandlerImpl.verifyZipFile');
      return false;
    }
  }
}
