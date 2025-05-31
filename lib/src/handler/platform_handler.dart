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

  /// Get system memory (GB)
  static Future<double> getSystemMemoryGB() async {
    final memoryMB = await getSystemMemoryMB();
    return memoryMB / 1024.0;
  }

  /// Get app save directory, for data, config, etc.
  static Future<String> getPathApp() => _instance.getPathApp();

  /// Recommended IO concurrency (optimized by platform and memory)
  static Future<int> getRecommendedConcurrency() async {
    if (isWeb) return 2;
    if (isMobile) {
      // Adjust concurrency based on memory for mobile devices
      final memGB = await getSystemMemoryGB();
      if (memGB < 2.0) return 2; // Low memory devices
      if (memGB < 4.0) return 3; // Medium memory devices
      return 4; // High memory devices
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
    if (isMobile) return 3;
    return processorCores.clamp(
        2, 6); // Maximum 6 concurrent operations for desktop
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
