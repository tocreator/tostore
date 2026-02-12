import '../Interface/platform_interface.dart';
import '../Interface/platform_handler_web.dart'
    if (dart.library.io) 'platform_handler_impl.dart';

/// Platform capability detection entry point
class PlatformHandler {
  static final PlatformInterface _instance = PlatformHandlerImpl();

  /// Build mode detection
  static bool get isRelease => const bool.fromEnvironment('dart.vm.product');
  static bool get isProfile => const bool.fromEnvironment('dart.vm.profile');
  static bool get isDebug {
    var inDebug = false;
    assert(() {
      inDebug = true;
      return true;
    }());
    if (isRelease || isProfile) return false;
    return inDebug;
  }

  /// Whether it's a mobile platform
  static bool get isMobile => _instance.isMobile;

  /// Whether it's a desktop platform
  static bool get isDesktop => _instance.isDesktop;

  /// Number of logical processor cores
  static int get processorCores => _instance.processorCores;

  /// Whether it's a test environment
  static bool get isTestEnvironment => _instance.isTestEnvironment;

  /// Whether it's a Web platform
  static bool get isWeb => _instance.isWeb;

  // Platform-specific detection
  static bool get isAndroid => _instance.isAndroid;
  static bool get isIOS => _instance.isIOS;
  static bool get isWindows => _instance.isWindows;
  static bool get isMacOS => _instance.isMacOS;
  static bool get isLinux => _instance.isLinux;

  /// Get system memory (MB)
  static Future<int> getSystemMemoryMB() => _instance.getSystemMemoryMB();

  /// Get available system memory (MB)
  /// @param forceRefresh Whether to force a refresh of the memory information (bypass cache)
  static Future<int> getAvailableSystemMemoryMB({bool forceRefresh = false}) =>
      _instance.getAvailableSystemMemoryMB(forceRefresh: forceRefresh);

  /// Get system memory (GB)
  static Future<double> getSystemMemoryGB() async {
    final memoryMB = await getSystemMemoryMB();
    return memoryMB / 1024.0;
  }

  /// Get available system memory (GB)
  static Future<double> getAvailableSystemMemoryGB() async {
    final memoryMB = await getAvailableSystemMemoryMB();
    return memoryMB / 1024.0;
  }

  /// Get app save directory, for data, config, etc.
  static Future<String> getPathApp() => _instance.getPathApp();

  /// create temp directory
  /// return temp directory path
  static Future<String> createTempDirectory(String prefix) =>
      _instance.createTempDirectory(prefix);

  /// delete directory
  static Future<void> deleteDirectory(String path, {bool recursive = true}) =>
      _instance.deleteDirectory(path, recursive: recursive);

  /// compress directory to ZIP file
  /// sourceDir: source directory path
  /// targetZip: target ZIP file path
  static Future<void> compressDirectory(String sourceDir, String targetZip) =>
      _instance.compressDirectory(sourceDir, targetZip);

  /// decompress ZIP file to specified directory
  /// zipPath: ZIP file path
  /// targetDir: target directory path
  static Future<void> extractZip(String zipPath, String targetDir) =>
      _instance.extractZip(zipPath, targetDir);

  /// Verify if a ZIP file is valid and optionally check if it contains a specific file
  /// zipPath: ZIP file path
  /// requiredFile: Optional file path to check inside the ZIP (e.g., 'meta.json')
  /// Returns true if ZIP is valid and contains the required file (if specified)
  static Future<bool> verifyZipFile(String zipPath, {String? requiredFile}) =>
      _instance.verifyZipFile(zipPath, requiredFile: requiredFile);

  /// Recommended IO concurrency (synchronous version)
  ///
  /// Calculates optimal concurrency for I/O-bound tasks (e.g., partition file processing)
  /// based on CPU cores and platform type. Uses core reservation strategy for servers
  /// to ensure system stability while maximizing throughput.
  static int get recommendedConcurrency {
    final cores = processorCores;

    if (isServerEnvironment) {
      // For servers, utilize all available cores.
      // YieldController inside the engine will handle any necessary execution pauses.
      return cores.clamp(10, 128);
    } else if (isDesktop) {
      // For desktops, utilize all available cores.
      // Modern OS schedulers and YieldController ensure UI responsiveness.
      return cores.clamp(8, 64);
    } else if (isMobile) {
      // For mobile, utilize all cores but cap at 8 to avoid excessive memory/thermal pressure.
      return cores.clamp(6, 16);
    } else {
      // For web and unknown platforms, use cores but cap at 6.
      return cores.clamp(3, 8);
    }
  }

  /// Detect if it's a server environment
  static bool get isServerEnvironment {
    // Server environment detection strategy:
    // 1. Linux systems are almost always servers or high-performance environments in this context.
    // 2. Windows/macOS with high core counts (>=12) often act as workstations or build servers.
    if (isLinux) {
      return true;
    } else if ((isWindows || isMacOS) && processorCores >= 12) {
      return true;
    }

    return false;
  }

  /// Get device hardware signature for enhanced security
  /// Combines CPU, memory, and platform identifiers
  /// Used for hardware-bound encryption key derivation
  static int get deviceFingerprint {
    return _instance.deviceFingerprint;
  }

  /// Check if hardware-based key derivation is available
  /// Returns true if device supports TPM/Secure Enclave
  static bool get supportsHardwareKeyDerivation {
    return _instance.supportsHardwareKeyDerivation;
  }
}
