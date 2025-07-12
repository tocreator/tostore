import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';

/// data compressor
class DataCompressor {
  final int compressionLevel;

  DataCompressor({this.compressionLevel = 6});

  /// compress data (using simple RLE compression algorithm)
  Uint8List compress(Uint8List data) {
    if (data.isEmpty) return data;

    final result = <int>[];
    int count = 1;
    int current = data[0];

    for (int i = 1; i < data.length; i++) {
      if (data[i] == current && count < 255) {
        count++;
      } else {
        result.addAll([count, current]);
        count = 1;
        current = data[i];
      }
    }
    result.addAll([count, current]);

    return Uint8List.fromList(result);
  }

  /// decompress data
  Uint8List decompress(Uint8List compressedData) {
    if (compressedData.isEmpty) return compressedData;

    final result = <int>[];
    for (int i = 0; i < compressedData.length; i += 2) {
      if (i + 1 >= compressedData.length) break;
      final count = compressedData[i];
      final value = compressedData[i + 1];
      result.addAll(List.filled(count, value));
    }

    return Uint8List.fromList(result);
  }

  /// calculate checksum
  int calculateChecksum(Uint8List data) {
    return getCrc32(data);
  }

  /// Calculate CRC32 checksum from bytes and return as a hex string.
  String getChecksumStringFromBytes(Uint8List bytes) {
    final checksum = calculateChecksum(bytes);
    return checksum.toRadixString(16).padLeft(8, '0');
  }

  /// Calculate CRC32 checksum from a string and return as a hex string.
  String getChecksumStringFromString(String content) {
    final bytes = utf8.encode(content);
    return getChecksumStringFromBytes(bytes);
  }
}

/// compressed data
class CompressedData {
  final Uint8List data;
  final int originalSize;
  final int compressedSize;
  final int checksum;

  CompressedData({
    required this.data,
    required this.originalSize,
    required this.compressedSize,
    required this.checksum,
  });
}
