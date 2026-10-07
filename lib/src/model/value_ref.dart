import 'dart:typed_data';

/// One fragment of a ValueRef v2 overflow value.
enum OverflowFragmentKind {
  /// Exclusive full-page run: [pageNo, pageNo+pageCount).
  extent,

  /// Slot inside a mixed OVP2 page.
  slot,
}

final class OverflowFragment {
  final OverflowFragmentKind kind;
  final int pageNo;

  /// pageCount for [OverflowFragmentKind.extent], slotId for slot.
  final int countOrSlot;

  const OverflowFragment.extent({
    required this.pageNo,
    required int pageCount,
  })  : kind = OverflowFragmentKind.extent,
        countOrSlot = pageCount;

  const OverflowFragment.slot({
    required this.pageNo,
    required int slotId,
  })  : kind = OverflowFragmentKind.slot,
        countOrSlot = slotId;

  int get pageCount => kind == OverflowFragmentKind.extent ? countOrSlot : 1;

  int get slotId => kind == OverflowFragmentKind.slot ? countOrSlot : -1;
}

/// Pointer stored in B+Tree leaf values / field slots for out-of-line storage.
///
/// Wire formats:
/// - v1 (legacy): `[0xFF][1][kind][0][pNo i32][startPage i32][totalLen u32][crc u32]`
///   Reads follow OVP1 `nextPageNo` chains.
/// - v2: fragment list (extents + OVP2 slots); optional indirect directory.
final class ValueRef {
  static const int _marker = 0xFF;
  static const int versionV1 = 1;
  static const int versionV2 = 2;

  /// Max fragments inlined in the pointer before using an indirect directory.
  static const int maxInlineFragments = 16;

  static const int flagIndirectDirectory = 0x01;

  /// Current pointer kind.
  static const int kindOverflow = 1;

  final int version;
  final int kind;
  final int overflowPartitionNo;

  /// v1 only: chain head. v2: unused (0).
  final int startPageNo;

  final int totalLen;
  final int crc32;

  /// v2 fragment list (empty for v1).
  final List<OverflowFragment> fragments;

  /// v2: first fragment is a directory page when set.
  final bool indirectDirectory;

  const ValueRef._({
    required this.version,
    required this.kind,
    required this.overflowPartitionNo,
    required this.startPageNo,
    required this.totalLen,
    required this.crc32,
    this.fragments = const <OverflowFragment>[],
    this.indirectDirectory = false,
  });

  /// Legacy v1 exclusive-chain pointer.
  factory ValueRef.overflow({
    required int overflowPartitionNo,
    required int startPageNo,
    required int totalLen,
    required int crc32,
  }) {
    return ValueRef._(
      version: versionV1,
      kind: kindOverflow,
      overflowPartitionNo: overflowPartitionNo,
      startPageNo: startPageNo,
      totalLen: totalLen,
      crc32: crc32,
    );
  }

  /// v2 mixed-page / extent pointer.
  factory ValueRef.overflowV2({
    required int overflowPartitionNo,
    required int totalLen,
    required int crc32,
    required List<OverflowFragment> fragments,
    bool indirectDirectory = false,
  }) {
    return ValueRef._(
      version: versionV2,
      kind: kindOverflow,
      overflowPartitionNo: overflowPartitionNo,
      startPageNo: 0,
      totalLen: totalLen,
      crc32: crc32,
      fragments: List<OverflowFragment>.unmodifiable(fragments),
      indirectDirectory: indirectDirectory,
    );
  }

  bool get isV1 => version == versionV1;
  bool get isV2 => version == versionV2;

  Uint8List encode() {
    if (version == versionV1) {
      final bd = ByteData(20);
      bd.setUint8(0, _marker);
      bd.setUint8(1, versionV1);
      bd.setUint8(2, kind);
      bd.setUint8(3, 0);
      bd.setInt32(4, overflowPartitionNo, Endian.little);
      bd.setInt32(8, startPageNo, Endian.little);
      bd.setUint32(12, totalLen, Endian.little);
      bd.setUint32(16, crc32, Endian.little);
      return bd.buffer.asUint8List();
    }

    // v2: [FF][2][kind][flags][pNo i32][totalLen u32][crc u32]
    //     [fragCount u16][frag...]
    // frag: [type u8][pageNo u32][countOrSlot u16]  => 7 bytes
    final fragCount = fragments.length;
    final out = Uint8List(18 + 2 + fragCount * 7);
    final bd = ByteData.sublistView(out);
    bd.setUint8(0, _marker);
    bd.setUint8(1, versionV2);
    bd.setUint8(2, kind);
    bd.setUint8(3, indirectDirectory ? flagIndirectDirectory : 0);
    bd.setInt32(4, overflowPartitionNo, Endian.little);
    bd.setUint32(8, totalLen, Endian.little);
    bd.setUint32(12, crc32, Endian.little);
    bd.setUint16(16, fragCount, Endian.little);
    var off = 18;
    for (final f in fragments) {
      out[off] = f.kind == OverflowFragmentKind.extent ? 0 : 1;
      bd.setUint32(off + 1, f.pageNo, Endian.little);
      bd.setUint16(off + 5, f.countOrSlot, Endian.little);
      off += 7;
    }
    return out;
  }

  static ValueRef? tryDecode(Uint8List bytes) {
    if (bytes.length < 4) return null;
    if (bytes[0] != _marker) return null;
    final ver = bytes[1];
    if (ver == versionV1) {
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
        version: versionV1,
        kind: kindOverflow,
        overflowPartitionNo: pNo,
        startPageNo: start,
        totalLen: total,
        crc32: crc,
      );
    }
    if (ver == versionV2) {
      if (bytes.length < 18) return null;
      final bd = ByteData.sublistView(bytes);
      final kind = bd.getUint8(2);
      final flags = bd.getUint8(3);
      final pNo = bd.getInt32(4, Endian.little);
      final total = bd.getUint32(8, Endian.little);
      final crc = bd.getUint32(12, Endian.little);
      final fragCount = bd.getUint16(16, Endian.little);
      if (kind != kindOverflow) return null;
      if (pNo < 0 || total <= 0) return null;
      if (18 + fragCount * 7 > bytes.length) return null;
      final frags = <OverflowFragment>[];
      var off = 18;
      for (int i = 0; i < fragCount; i++) {
        final type = bytes[off];
        final pageNo = bd.getUint32(off + 1, Endian.little);
        final cos = bd.getUint16(off + 5, Endian.little);
        if (pageNo <= 0) return null;
        if (type == 0) {
          if (cos <= 0) return null;
          frags.add(OverflowFragment.extent(pageNo: pageNo, pageCount: cos));
        } else if (type == 1) {
          frags.add(OverflowFragment.slot(pageNo: pageNo, slotId: cos));
        } else {
          return null;
        }
        off += 7;
      }
      return ValueRef._(
        version: versionV2,
        kind: kindOverflow,
        overflowPartitionNo: pNo,
        startPageNo: 0,
        totalLen: total,
        crc32: crc,
        fragments: frags,
        indirectDirectory: (flags & flagIndirectDirectory) != 0,
      );
    }
    return null;
  }
}
