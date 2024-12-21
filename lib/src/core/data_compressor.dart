import 'dart:typed_data';

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

  /// calculate checksum (using simple addition checksum)
  int calculateChecksum(Uint8List data) {
    int sum = 0;
    for (var byte in data) {
      sum = (sum + byte) & 0xFF;
    }
    return sum;
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
