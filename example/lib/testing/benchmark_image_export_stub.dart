import 'dart:typed_data';

/// Web / non-IO platforms: image export is unavailable.
bool get canExportBenchmarkImage => false;

Future<String> exportBenchmarkPng({
  required Uint8List bytes,
  required String fileName,
}) async {
  throw UnsupportedError(
    'Benchmark image export is only available on desktop '
    '(Windows, macOS, Linux).',
  );
}
