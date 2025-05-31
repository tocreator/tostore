/// Platform capability detection abstract interface
abstract class PlatformInterface {
  /// Whether it's a mobile platform (Android/iOS)
  bool get isMobile;

  /// Whether it's a desktop platform (Windows/macOS/Linux)
  bool get isDesktop;

  /// Number of logical processor cores (estimated value)
  int get processorCores;

  /// Whether it's a test environment (Flutter Driver Test)
  bool get isTestEnvironment;

  /// Whether it's a Web platform
  bool get isWeb;

  /// Whether it's an Android platform
  bool get isAndroid;

  /// Whether it's an iOS platform
  bool get isIOS;

  /// Whether it's a Windows platform
  bool get isWindows;

  /// Whether it's a macOS platform
  bool get isMacOS;

  /// Whether it's a Linux platform
  bool get isLinux;

  /// Get system memory (MB)
  Future<int> getSystemMemoryMB();
}
