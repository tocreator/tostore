import 'dart:typed_data';

/// 数据压缩器
class DataCompressor {
  final int compressionLevel;

  DataCompressor({this.compressionLevel = 6});

  /// 压缩数据 (使用简单的 RLE 压缩算法)
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

  /// 解压数据
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

  /// 计算校验和 (使用简单的加法校验)
  int calculateChecksum(Uint8List data) {
    int sum = 0;
    for (var byte in data) {
      sum = (sum + byte) & 0xFF;
    }
    return sum;
  }
}

/// 压缩数据
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
