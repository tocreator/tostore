// Directory stub
class Directory {
  final String path;

  Directory(this.path);

  static Directory get systemTemp => Directory('/tmp');

  Future<Directory> createTemp([String prefix = '']) async {
    return Directory('$path/$prefix${DateTime.now().millisecondsSinceEpoch}');
  }

  Future<bool> exists() async => false;

  Future<Directory> create({bool recursive = false}) async {
    return this;
  }

  Stream<FileSystemEntity> list({bool recursive = false}) {
    throw UnsupportedError('Directory.list is not supported on web platform');
  }
}

// File stub
class File {
  final String path;

  File(this.path);

  Future<bool> exists() async => false;

  Future<File> create({bool recursive = false}) async {
    return this;
  }

  Future<File> writeAsBytes(List<int> bytes) async {
    return this;
  }

  Future<File> writeAsString(String contents,
      {FileMode mode = FileMode.write, bool flush = false}) async {
    return this;
  }

  Future<String> readAsString() async {
    return '';
  }

  Future<int> length() async {
    return 0;
  }

  Future<DateTime> lastModified() async {
    return DateTime.now();
  }

  Stream<List<int>> openRead() {
    throw UnsupportedError('File.openRead is not supported on web platform');
  }

  IOSink openWrite({FileMode mode = FileMode.write}) {
    throw UnsupportedError('File.openWrite is not supported on web platform');
  }

  Directory get parent => Directory(path.substring(0, path.lastIndexOf('/')));

  Future<File> copy(String newPath) async {
    return File(newPath);
  }

  Future<void> delete() async {}
}

// FileSystemEntity stub
class FileSystemEntity {
  final String path;

  FileSystemEntity(this.path);

  static Future<FileSystemEntityType> type(String path,
      {bool followLinks = true}) async {
    return FileSystemEntityType.notFound;
  }
}

// FileSystemEntityType stub
enum FileSystemEntityType { file, directory, link, notFound }

// FileMode stub
enum FileMode { read, write, append, writeOnly, writeOnlyAppend }

// IOSink stub
class IOSink {
  void writeln(Object? obj) {}

  Future<void> flush() async {}

  Future<void> close() async {}
}

// Platform stub
class Platform {
  static bool get isAndroid => false;
  static bool get isIOS => false;
  static bool get isMacOS => false;
  static bool get isWindows => false;
  static bool get isLinux => false;

  static int get numberOfProcessors => 2;

  static Map<String, String> get environment => {};
}
