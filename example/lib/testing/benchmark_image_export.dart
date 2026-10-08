import 'dart:typed_data';

import 'benchmark_image_export_stub.dart'
    if (dart.library.io) 'benchmark_image_export_io.dart' as impl;

/// Whether the current platform can write a PNG to disk (desktop only).
bool get canExportBenchmarkImage => impl.canExportBenchmarkImage;

/// Writes [bytes] as [fileName] under Desktop/Downloads and reveals the file.
Future<String> exportBenchmarkPng({
  required Uint8List bytes,
  required String fileName,
}) =>
    impl.exportBenchmarkPng(bytes: bytes, fileName: fileName);
