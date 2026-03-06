import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

/// Unified FFI helper for system-level information across platforms.
/// This class centralizes all native system calls to avoid multiple files.
class SystemFfiHelper {
  // --- Shared / Internal ---

  static bool get _isWindows => Platform.isWindows;
  static bool get _isMacOS => Platform.isMacOS;
  static bool get _isIOS => Platform.isIOS;
  static bool get _isLinux => Platform.isLinux;
  static bool get _isAndroid => Platform.isAndroid;
  static bool get _isDarwin => _isMacOS || _isIOS;
  static bool get _isPosix => _isLinux || _isAndroid;

  // --- Memory APIs ---

  /// Get total physical memory in MB
  static int getTotalMemoryMB() {
    try {
      if (_isWindows) return _getWindowsTotalMemory();
      if (_isDarwin) return _getDarwinTotalMemory();
      if (_isPosix) return _getPosixTotalMemory();
    } catch (_) {
      // Fallback
    }
    return 0;
  }

  /// Get available physical memory in MB
  static int getAvailableMemoryMB() {
    try {
      if (_isWindows) return _getWindowsAvailableMemory();
      if (_isDarwin) return _getDarwinAvailableMemory();
      if (_isPosix) return _getPosixAvailableMemory();
    } catch (_) {
      // Fallback
    }
    return 0;
  }

  // --- Disk APIs ---

  /// Get available disk space in MB for the given path
  static int getDiskFreeSpaceMB(String path) {
    try {
      if (_isWindows) return _getWindowsDiskFreeSpace(path);
      if (_isDarwin || _isPosix) return _getPosixDiskFreeSpace(path);
    } catch (_) {
      // Fallback
    }
    return 0;
  }

  // --- Windows Implementation (kernel32.dll) ---

  static final DynamicLibrary? _kernel32 =
      _isWindows ? DynamicLibrary.open('kernel32.dll') : null;

  static int _getWindowsTotalMemory() {
    if (_kernel32 == null) return 0;
    final func = _kernel32!.lookupFunction<
        Int32 Function(Pointer<MEMORYSTATUSEX>),
        int Function(Pointer<MEMORYSTATUSEX>)>('GlobalMemoryStatusEx');

    Pointer<MEMORYSTATUSEX>? status;
    try {
      status = calloc<MEMORYSTATUSEX>();
      status.ref.dwLength = sizeOf<MEMORYSTATUSEX>();
      if (func(status) != 0) {
        return (status.ref.ullTotalPhys / (1024 * 1024)).round();
      }
    } finally {
      if (status != null) calloc.free(status);
    }
    return 0;
  }

  static int _getWindowsAvailableMemory() {
    if (_kernel32 == null) return 0;
    final func = _kernel32!.lookupFunction<
        Int32 Function(Pointer<MEMORYSTATUSEX>),
        int Function(Pointer<MEMORYSTATUSEX>)>('GlobalMemoryStatusEx');

    Pointer<MEMORYSTATUSEX>? status;
    try {
      status = calloc<MEMORYSTATUSEX>();
      status.ref.dwLength = sizeOf<MEMORYSTATUSEX>();
      if (func(status) != 0) {
        return (status.ref.ullAvailPhys / (1024 * 1024)).round();
      }
    } finally {
      if (status != null) calloc.free(status);
    }
    return 0;
  }

  static int _getWindowsDiskFreeSpace(String path) {
    if (_kernel32 == null) return 0;
    final func = _kernel32!.lookupFunction<
        Int32 Function(
            Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>),
        int Function(Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>,
            Pointer<Uint64>)>('GetDiskFreeSpaceExW');

    final pathPtr = path.toNativeUtf16();
    final freeAvailable = calloc<Uint64>();
    final totalBytes = calloc<Uint64>();
    final totalFree = calloc<Uint64>();

    try {
      if (func(pathPtr, freeAvailable, totalBytes, totalFree) != 0) {
        return (freeAvailable.value / (1024 * 1024)).round();
      }
    } finally {
      calloc.free(pathPtr);
      calloc.free(freeAvailable);
      calloc.free(totalBytes);
      calloc.free(totalFree);
    }
    return 0;
  }

  // --- Darwin Implementation (libc / mach) ---

  static final DynamicLibrary? _libcDarwin =
      _isDarwin ? DynamicLibrary.process() : null;

  static int _getDarwinTotalMemory() {
    if (_libcDarwin == null) return 0;
    final sysctlbyname = _libcDarwin!.lookupFunction<
        Int32 Function(
            Pointer<Utf8>, Pointer<Uint64>, Pointer<Size>, Pointer<Void>, Size),
        int Function(Pointer<Utf8>, Pointer<Uint64>, Pointer<Size>,
            Pointer<Void>, int)>('sysctlbyname');

    final namePtr = 'hw.memsize'.toNativeUtf8();
    final valuePtr = calloc<Uint64>();
    final lenPtr = calloc<Size>();
    lenPtr.value = sizeOf<Uint64>();

    try {
      if (sysctlbyname(namePtr, valuePtr, lenPtr, nullptr, 0) == 0) {
        return (valuePtr.value / (1024 * 1024)).round();
      }
    } finally {
      calloc.free(namePtr);
      calloc.free(valuePtr);
      calloc.free(lenPtr);
    }
    return 0;
  }

  static int _getDarwinAvailableMemory() {
    if (_libcDarwin == null) return 0;
    final hostSelfFunc = _libcDarwin!
        .lookupFunction<Int32 Function(), int Function()>('mach_host_self');
    final hostStatsFunc = _libcDarwin!.lookupFunction<
        Int32 Function(Int32, Int32, Pointer<Int32>, Pointer<Uint32>),
        int Function(
            int, int, Pointer<Int32>, Pointer<Uint32>)>('host_statistics64');

    const hostVmInfo64 = 4;
    const hostVmInfo64Count = 38;

    final host = hostSelfFunc();
    final countPtr = calloc<Uint32>();
    countPtr.value = hostVmInfo64Count;
    final statsPtr = calloc<Int32>(hostVmInfo64Count);

    try {
      if (hostStatsFunc(host, hostVmInfo64, statsPtr, countPtr) == 0) {
        final free = statsPtr[1];
        final inactive = statsPtr[7];
        final purgeable = statsPtr[10];
        final pageSize = _getDarwinPageSize();
        final availBytes = (free + inactive + purgeable) * pageSize;
        return (availBytes / (1024 * 1024)).round();
      }
    } finally {
      calloc.free(countPtr);
      calloc.free(statsPtr);
    }
    return 0;
  }

  static int _getDarwinPageSize() {
    if (_libcDarwin == null) return 4096;
    final sysctlbyname = _libcDarwin!.lookupFunction<
        Int32 Function(
            Pointer<Utf8>, Pointer<Uint32>, Pointer<Size>, Pointer<Void>, Size),
        int Function(Pointer<Utf8>, Pointer<Uint32>, Pointer<Size>,
            Pointer<Void>, int)>('sysctlbyname');

    final namePtr = 'hw.pagesize'.toNativeUtf8();
    final valuePtr = calloc<Uint32>();
    final lenPtr = calloc<Size>();
    lenPtr.value = sizeOf<Uint32>();

    try {
      if (sysctlbyname(namePtr, valuePtr, lenPtr, nullptr, 0) == 0) {
        return valuePtr.value;
      }
    } finally {
      calloc.free(namePtr);
      calloc.free(valuePtr);
      calloc.free(lenPtr);
    }
    return 4096;
  }

  // --- Posix Implementation (libc) ---

  static final DynamicLibrary? _libc =
      (_isPosix || _isDarwin) ? DynamicLibrary.process() : null;

  static int _getPosixTotalMemory() {
    if (_libc == null || !_isPosix) return 0;
    final sysinfoFunc = _libc!.lookupFunction<Int32 Function(Pointer<SYSINFO>),
        int Function(Pointer<SYSINFO>)>('sysinfo');

    final info = calloc<SYSINFO>();
    try {
      if (sysinfoFunc(info) == 0) {
        return (info.ref.totalram * info.ref.memUnit / (1024 * 1024)).round();
      }
    } finally {
      calloc.free(info);
    }
    return 0;
  }

  static int _getPosixAvailableMemory() {
    if (_libc == null || !_isPosix) return 0;
    final sysinfoFunc = _libc!.lookupFunction<Int32 Function(Pointer<SYSINFO>),
        int Function(Pointer<SYSINFO>)>('sysinfo');

    final info = calloc<SYSINFO>();
    try {
      if (sysinfoFunc(info) == 0) {
        final avail =
            (info.ref.freeram + info.ref.bufferram) * info.ref.memUnit;
        return (avail / (1024 * 1024)).round();
      }
    } finally {
      calloc.free(info);
    }
    return 0;
  }

  static int _getPosixDiskFreeSpace(String path) {
    if (_libc == null) return 0;
    final statvfsFunc = _libc!.lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<STATVFS>),
        int Function(Pointer<Utf8>, Pointer<STATVFS>)>('statvfs');

    final pathPtr = path.toNativeUtf8();
    final info = calloc<STATVFS>();
    try {
      if (statvfsFunc(pathPtr, info) == 0) {
        final availBytes = info.ref.bavail * info.ref.frsize;
        return (availBytes / (1024 * 1024)).round();
      }
    } finally {
      calloc.free(pathPtr);
      calloc.free(info);
    }
    return 0;
  }
}

// --- Native Structs ---

/// Windows MEMORYSTATUSEX
base class MEMORYSTATUSEX extends Struct {
  @Uint32()
  external int dwLength;
  @Uint32()
  external int dwMemoryLoad;
  @Uint64()
  external int ullTotalPhys;
  @Uint64()
  external int ullAvailPhys;
  @Uint64()
  external int ullTotalPageFile;
  @Uint64()
  external int ullAvailPageFile;
  @Uint64()
  external int ullTotalVirtual;
  @Uint64()
  external int ullAvailVirtual;
  @Uint64()
  external int ullAvailExtendedVirtual;
}

/// Linux sysinfo structure
base class SYSINFO extends Struct {
  @Long()
  external int uptime;
  @Uint64()
  external int loads1;
  @Uint64()
  external int loads5;
  @Uint64()
  external int loads15;
  @UnsignedLong()
  external int totalram;
  @UnsignedLong()
  external int freeram;
  @UnsignedLong()
  external int sharedram;
  @UnsignedLong()
  external int bufferram;
  @UnsignedLong()
  external int totalswap;
  @UnsignedLong()
  external int freeswap;
  @Uint16()
  external int procs;
  @Uint16()
  external int padding;
  @UnsignedLong()
  external int totalhigh;
  @UnsignedLong()
  external int freehigh;
  @Uint32()
  external int memUnit;
}

/// Posix statvfs structure
base class STATVFS extends Struct {
  @UnsignedLong()
  external int bsize;
  @UnsignedLong()
  external int frsize;
  @UnsignedLong()
  external int blocks;
  @UnsignedLong()
  external int bfree;
  @UnsignedLong()
  external int bavail;
  @UnsignedLong()
  external int files;
  @UnsignedLong()
  external int ffree;
  @UnsignedLong()
  external int favail;
  @UnsignedLong()
  external int fsid;
  @UnsignedLong()
  external int flag;
  @UnsignedLong()
  external int namemax;
}
