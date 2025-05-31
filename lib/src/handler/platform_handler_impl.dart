import 'dart:io';
import 'dart:async';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import '../Interface/platform_interface.dart';

/// Native platform implementation
class PlatformHandlerImpl implements PlatformInterface {
  @override
  bool get isMobile => Platform.isAndroid || Platform.isIOS;

  @override
  bool get isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  @override
  int get processorCores {
    try {
      return Platform.numberOfProcessors;
    } catch (e) {
      return 4; // Return a safe value if an exception occurs
    }
  }

  @override
  bool get isTestEnvironment {
    try {
      return Platform.environment.containsKey('FLUTTER_TEST');
    } catch (e) {
      return false;
    }
  }

  @override
  bool get isWeb => false;

  @override
  bool get isAndroid => Platform.isAndroid;

  @override
  bool get isIOS => Platform.isIOS;

  @override
  bool get isWindows => Platform.isWindows;

  @override
  bool get isMacOS => Platform.isMacOS;

  @override
  bool get isLinux => Platform.isLinux;

  /// Get system memory size (MB)
  @override
  Future<int> getSystemMemoryMB() async {
    try {
      if (isWindows) {
        return await _getWindowsMemory();
      } else if (isLinux) {
        return await _getLinuxMemory();
      } else if (isMacOS) {
        return await _getMacOSMemory();
      } else if (isAndroid) {
        return await _getAndroidMemory();
      }

      // Unknown platform or retrieval failed, estimate based on core count
      return processorCores * 1024;
    } catch (e) {
      // Return a safe default value based on platform
      return isMobile ? 2048 : 4096;
    }
  }

  /// Get app save directory, for data, config, etc.
  @override
  Future<String> getPathApp() async {
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final cachePath = Directory(path.join(docDir.path, 'common'));
      if (!cachePath.existsSync()) {
        cachePath.create();
      }
      return cachePath.path;
    } catch (e) {
      // Fallback to temporary directory
      final tempDir = await Directory.systemTemp.createTemp('tostore_');
      return tempDir.path;
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
}
