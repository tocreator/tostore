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
      // For servers, dynamically reserve cores based on the total number of cores.
      // This prevents system overload on high-core-count machines.
      int reservedCores;
      if (cores <= 10) {
        reservedCores = 1;
      } else if (cores <= 15) {
        reservedCores = 2;
      } else if (cores <= 30) {
        reservedCores = 3;
      } else {
        reservedCores = 4;
      }

      int baseConcurrency = cores - reservedCores;

      // Memory-aware cap: estimate ~80MB per concurrent task
      // For very high concurrency, we need to consider memory limits
      return baseConcurrency.clamp(1, 96);
    } else if (isDesktop) {
      // For desktops, use half the cores, but at least 2.
      // Increase max cap to 16 for high-core desktops (e.g., 16-core systems)
      // This better utilizes modern desktop hardware while still being conservative
      return (cores / 2).round().clamp(2, 16);
    } else if (isMobile) {
      // For mobile, be more conservative: use cores but cap at 4
      // Mobile devices have limited memory and battery constraints
      return cores.clamp(1, 4);
    } else {
      // For web and unknown platforms, be very conservative
      return cores.clamp(1, 4);
    }
  }

  /// Detect if it's a server environment
  static bool get isServerEnvironment {
    // Server environment detection strategy:
    // 1. Check if it's a Linux or macOS system (servers typically use these systems)
    // 2. Check if it has large amount of memory (servers typically have more memory)
    // 3. Check processor core count (servers typically have multiple cores)
    if (isLinux) {
      // Linux server is likely a database server
      return true;
    } else if (isMacOS && processorCores >= 8) {
      // Mac servers typically have more processor cores
      return true;
    }

    // Not a clear server environment
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
