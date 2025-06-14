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
  
  /// Get available system memory (MB)
  Future<int> getAvailableSystemMemoryMB();

  /// Get app save directory, for data, config, etc.
  Future<String> getPathApp();

  /// create temp directory
  /// return temp directory path
  Future<String> createTempDirectory(String prefix);

  /// delete directory
  Future<void> deleteDirectory(String path, {bool recursive = true});

  /// compress directory to ZIP file
  /// sourceDir: source directory path
  /// targetZip: target ZIP file path
  Future<void> compressDirectory(String sourceDir, String targetZip);

  /// decompress ZIP file to specified directory
  /// zipPath: ZIP file path
  /// targetDir: target directory path
  Future<void> extractZip(String zipPath, String targetDir);

  /// Verify if a ZIP file is valid and optionally check if it contains a specific file
  /// zipPath: ZIP file path
  /// requiredFile: Optional file path to check inside the ZIP (e.g., 'meta.json')
  /// Returns true if ZIP is valid and contains the required file (if specified)
  Future<bool> verifyZipFile(String zipPath, {String? requiredFile});
}
