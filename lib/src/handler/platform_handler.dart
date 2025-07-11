import '../Interface/platform_interface.dart';
import 'platform_handler_web.dart'
    if (dart.library.io) 'platform_handler_impl.dart';

/// Platform capability detection entry point
class PlatformHandler {
  static final PlatformInterface _instance = PlatformHandlerImpl();

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

  /// Recommended IO concurrency (optimized by platform and memory)
  static Future<int> getRecommendedConcurrency() async {
    if (isWeb) return 2;
    if (isMobile) {
      // Adjust concurrency based on memory for mobile devices
      final memGB = await getSystemMemoryGB();
      if (memGB < 2.0) return 1; // Low memory devices
      if (memGB < 4.0) return 2; // Medium memory devices
      return 3; // High memory devices
    }

    // Optimize concurrency based on memory and CPU for desktop devices
    final memGB = await getSystemMemoryGB();
    final cores = processorCores;

    if (memGB < 4.0) return cores.clamp(2, 4); // Low memory devices
    if (memGB < 8.0) return cores.clamp(2, 6); // Medium memory devices
    return cores.clamp(2, 8); // High memory devices
  }

  /// Recommended IO concurrency (synchronous version)
  static int get recommendedConcurrency {
    if (isWeb) return 2;
    if (isMobile) {
      // For mobile, be more conservative. Use half the cores, but at least 1 and at most 3.
      return (processorCores / 2).round().clamp(1, 3);
    }
    return processorCores.clamp(
        2, 8); // Maximum 8 concurrent operations for desktop
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
}
