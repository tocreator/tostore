import 'dart:typed_data';

/// Pointer stored in B+Tree leaf values for out-of-line (overflow) storage.
///
/// Backward compatibility:
/// - Old inline values (BinarySchemaCodec bytes) start with fieldCount:u16be,
///   so their first byte is always `<= 0x27` for practical schemas.
/// - We reserve 0xFF as a marker for ValueRef bytes so old data remains readable
///   without migration.
final class ValueRef {
  static const int _marker = 0xFF;
  static const int _version = 1;

  /// Current pointer kind.
  static const int kindOverflow = 1;

  final int kind;
  final int overflowPartitionNo;
  final int startPageNo;
  final int totalLen;
  final int crc32;

  const ValueRef._({
    required this.kind,
    required this.overflowPartitionNo,
    required this.startPageNo,
    required this.totalLen,
    required this.crc32,
  });

  factory ValueRef.overflow({
    required int overflowPartitionNo,
    required int startPageNo,
    required int totalLen,
    required int crc32,
  }) {
    return ValueRef._(
      kind: kindOverflow,
      overflowPartitionNo: overflowPartitionNo,
      startPageNo: startPageNo,
      totalLen: totalLen,
      crc32: crc32,
    );
  }

  Uint8List encode() {
    final bd = ByteData(20);
    bd.setUint8(0, _marker);
    bd.setUint8(1, _version);
    bd.setUint8(2, kind);
    bd.setUint8(3, 0); // reserved
    bd.setInt32(4, overflowPartitionNo, Endian.little);
    bd.setInt32(8, startPageNo, Endian.little);
    bd.setUint32(12, totalLen, Endian.little);
    bd.setUint32(16, crc32, Endian.little);
    return bd.buffer.asUint8List();
  }

  static ValueRef? tryDecode(Uint8List bytes) {
    if (bytes.length < 4) return null;
    if (bytes[0] != _marker) return null;
    if (bytes[1] != _version) return null;
    if (bytes.length < 20) return null;
    final bd = ByteData.sublistView(bytes);
    final kind = bd.getUint8(2);
    final pNo = bd.getInt32(4, Endian.little);
    final start = bd.getInt32(8, Endian.little);
    final total = bd.getUint32(12, Endian.little);
    final crc = bd.getUint32(16, Endian.little);
    if (kind != kindOverflow) return null;
    if (pNo < 0 || start <= 0 || total <= 0) return null;
    return ValueRef._(
      kind: kind,
      overflowPartitionNo: pNo,
      startPageNo: start,
      totalLen: total,
      crc32: crc,
    );
  }
}
