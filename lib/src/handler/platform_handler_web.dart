import '../Interface/platform_interface.dart';

/// Web platform implementation
class PlatformHandlerImpl implements PlatformInterface {
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
  Future<String> getPathApp() async {
    return '';
  }
}
