import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Desktop file export only — mobile/web use the stub via conditional import.
bool get canExportBenchmarkImage =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

Future<String> exportBenchmarkPng({
  required Uint8List bytes,
  required String fileName,
}) async {
  if (!canExportBenchmarkImage) {
    throw UnsupportedError(
      'Benchmark image export is only available on desktop '
      '(Windows, macOS, Linux).',
    );
  }

  final dir = await _resolveSaveDirectory();
  final file = File(p.join(dir.path, fileName));
  await file.writeAsBytes(bytes, flush: true);
  await _revealSavedFile(file);
  return file.path;
}

Future<Directory> _resolveSaveDirectory() async {
  if (Platform.isWindows) {
    final desktop = await _knownFolder('USERPROFILE', 'Desktop');
    if (desktop != null) return desktop;
    final downloads = await _knownFolder('USERPROFILE', 'Downloads');
    if (downloads != null) return downloads;
  } else if (Platform.isMacOS || Platform.isLinux) {
    final homeKey = 'HOME';
    final desktop = await _knownFolder(homeKey, 'Desktop');
    if (desktop != null) return desktop;
    final downloads = await _knownFolder(homeKey, 'Downloads');
    if (downloads != null) return downloads;
  }

  try {
    final downloads = await getDownloadsDirectory();
    if (downloads != null) return downloads;
  } catch (_) {}
  return getApplicationDocumentsDirectory();
}

Future<Directory?> _knownFolder(String envKey, String folderName) async {
  final root = Platform.environment[envKey];
  if (root == null || root.isEmpty) return null;
  final dir = Directory(p.join(root, folderName));
  if (await dir.exists()) return dir;
  return null;
}

Future<void> _revealSavedFile(File file) async {
  try {
    if (Platform.isWindows) {
      await Process.run('explorer', ['/select,', file.path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', ['-R', file.path]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [file.parent.path]);
    }
  } catch (_) {}
}
