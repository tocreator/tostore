import 'dart:convert';
import 'dart:typed_data';

/// Page redo log: append-only records for crash-safe page replay.
///
/// Goals:
/// - Avoid hardcoding absolute file paths (paths may change across restart).
/// - Support last-write-wins semantics for repeated attempts / duplicate pages.
/// - Allow storing both page images and tree-structure metadata snapshots.
///
/// Record framing:
/// `[recLen:u32 LE][recType:u8][payload...]`
///
/// String encoding: UTF-8 with `[len:u16 LE][bytes]`.
enum PageRedoTreeKind {
  table,
  indexTree,
}

sealed class PageRedoLogRecord {
  final int nextStart;
  const PageRedoLogRecord({required this.nextStart});
}

/// One full page image write (after-image).
final class PageRedoPageRecord extends PageRedoLogRecord {
  final PageRedoTreeKind treeKind;
  final String tableName;
  final String? indexName;
  final int partitionNo;
  final int pageNo;
  final Uint8List payload; // full page bytes

  const PageRedoPageRecord({
    required this.treeKind,
    required this.tableName,
    required this.indexName,
    required this.partitionNo,
    required this.pageNo,
    required this.payload,
    required super.nextStart,
  });
}

/// Tree structure snapshot (no totals). Used to keep meta consistent with replayed pages.
final class PageRedoTreeMetaRecord extends PageRedoLogRecord {
  final PageRedoTreeKind treeKind;
  final String tableName;
  final String? indexName;

  final int btreePageSize;
  final int btreeNextPageNo;
  final int btreePartitionCount;

  final int btreeRootPartitionNo;
  final int btreeRootPageNo;
  final int btreeFirstLeafPartitionNo;
  final int btreeFirstLeafPageNo;
  final int btreeLastLeafPartitionNo;
  final int btreeLastLeafPageNo;
  final int btreeHeight;

  const PageRedoTreeMetaRecord({
    required this.treeKind,
    required this.tableName,
    required this.indexName,
    required this.btreePageSize,
    required this.btreeNextPageNo,
    required this.btreePartitionCount,
    required this.btreeRootPartitionNo,
    required this.btreeRootPageNo,
    required this.btreeFirstLeafPartitionNo,
    required this.btreeFirstLeafPageNo,
    required this.btreeLastLeafPartitionNo,
    required this.btreeLastLeafPageNo,
    required this.btreeHeight,
    required super.nextStart,
  });
}

final class PageRedoLogCodec {
  static const int _recTypePage = 1;
  static const int _recTypeTreeMeta = 2;

  static Uint8List _u16StringBytes(String s) {
    final b = Uint8List.fromList(utf8.encode(s));
    if (b.length > 0xFFFF) {
      throw StateError('PageRedoLog: string too long (${b.length})');
    }
    return b;
  }

  /// Encode one page write record (full page bytes).
  static Uint8List encodePageRecord({
    required PageRedoTreeKind treeKind,
    required String tableName,
    String? indexName,
    required int partitionNo,
    required int pageNo,
    required Uint8List payload,
  }) {
    final tableBytes = _u16StringBytes(tableName);
    final indexBytes = (treeKind == PageRedoTreeKind.indexTree)
        ? _u16StringBytes(indexName ?? '')
        : Uint8List(0);

    if (treeKind == PageRedoTreeKind.indexTree &&
        (indexName == null || indexName.isEmpty)) {
      throw StateError('PageRedoLog: indexName required for index records');
    }

    final int payloadLen = payload.length;
    final int recLen = 4 + // recLen itself
        1 + // recType
        1 + // treeKind
        2 +
        tableBytes.length +
        2 +
        indexBytes.length +
        4 + // partitionNo
        4 + // pageNo
        4 + // payloadLen
        payloadLen;

    final out = Uint8List(recLen);
    final bd = ByteData.sublistView(out);
    int pos = 0;
    bd.setUint32(pos, recLen, Endian.little);
    pos += 4;
    out[pos++] = _recTypePage;
    out[pos++] = treeKind.index;

    bd.setUint16(pos, tableBytes.length, Endian.little);
    pos += 2;
    out.setRange(pos, pos + tableBytes.length, tableBytes);
    pos += tableBytes.length;

    bd.setUint16(pos, indexBytes.length, Endian.little);
    pos += 2;
    if (indexBytes.isNotEmpty) {
      out.setRange(pos, pos + indexBytes.length, indexBytes);
      pos += indexBytes.length;
    }

    bd.setInt32(pos, partitionNo, Endian.little);
    pos += 4;
    bd.setInt32(pos, pageNo, Endian.little);
    pos += 4;
    bd.setUint32(pos, payloadLen, Endian.little);
    pos += 4;
    out.setRange(pos, pos + payloadLen, payload);
    return out;
  }

  /// Encode one tree structure snapshot record (no totals).
  static Uint8List encodeTreeMetaRecord({
    required PageRedoTreeKind treeKind,
    required String tableName,
    String? indexName,
    required int btreePageSize,
    required int btreeNextPageNo,
    required int btreePartitionCount,
    required int btreeRootPartitionNo,
    required int btreeRootPageNo,
    required int btreeFirstLeafPartitionNo,
    required int btreeFirstLeafPageNo,
    required int btreeLastLeafPartitionNo,
    required int btreeLastLeafPageNo,
    required int btreeHeight,
  }) {
    final tableBytes = _u16StringBytes(tableName);
    final indexBytes = (treeKind == PageRedoTreeKind.indexTree)
        ? _u16StringBytes(indexName ?? '')
        : Uint8List(0);

    if (treeKind == PageRedoTreeKind.indexTree &&
        (indexName == null || indexName.isEmpty)) {
      throw StateError(
          'PageRedoLog: indexName required for index meta records');
    }

    final int recLen = 4 + // recLen itself
        1 + // recType
        1 + // treeKind
        2 +
        tableBytes.length +
        2 +
        indexBytes.length +
        4 + // btreePageSize
        4 + // btreeNextPageNo
        4 + // btreePartitionCount
        4 + // root partition
        4 + // root page
        4 + // firstLeaf partition
        4 + // firstLeaf page
        4 + // lastLeaf partition
        4 + // lastLeaf page
        4; // height

    final out = Uint8List(recLen);
    final bd = ByteData.sublistView(out);
    int pos = 0;
    bd.setUint32(pos, recLen, Endian.little);
    pos += 4;
    out[pos++] = _recTypeTreeMeta;
    out[pos++] = treeKind.index;

    bd.setUint16(pos, tableBytes.length, Endian.little);
    pos += 2;
    out.setRange(pos, pos + tableBytes.length, tableBytes);
    pos += tableBytes.length;

    bd.setUint16(pos, indexBytes.length, Endian.little);
    pos += 2;
    if (indexBytes.isNotEmpty) {
      out.setRange(pos, pos + indexBytes.length, indexBytes);
      pos += indexBytes.length;
    }

    bd.setUint32(pos, btreePageSize, Endian.little);
    pos += 4;
    bd.setUint32(pos, btreeNextPageNo, Endian.little);
    pos += 4;
    bd.setUint32(pos, btreePartitionCount, Endian.little);
    pos += 4;

    bd.setInt32(pos, btreeRootPartitionNo, Endian.little);
    pos += 4;
    bd.setInt32(pos, btreeRootPageNo, Endian.little);
    pos += 4;
    bd.setInt32(pos, btreeFirstLeafPartitionNo, Endian.little);
    pos += 4;
    bd.setInt32(pos, btreeFirstLeafPageNo, Endian.little);
    pos += 4;
    bd.setInt32(pos, btreeLastLeafPartitionNo, Endian.little);
    pos += 4;
    bd.setInt32(pos, btreeLastLeafPageNo, Endian.little);
    pos += 4;
    bd.setInt32(pos, btreeHeight, Endian.little);
    return out;
  }

  /// Decode next record from [bytes] at [start]. Returns null if not enough data or invalid.
  static PageRedoLogRecord? decodeRecord(Uint8List bytes, int start) {
    if (start + 4 > bytes.length) return null;
    final bd = ByteData.sublistView(bytes);
    final recLen = bd.getUint32(start, Endian.little);
    if (recLen < 6) return null; // minimal: len + type + kind
    final end = start + recLen;
    if (end > bytes.length) return null;

    int pos = start + 4;
    final recType = bytes[pos++];
    final kindIdx = bytes[pos++];
    if (kindIdx < 0 || kindIdx >= PageRedoTreeKind.values.length) return null;
    final kind = PageRedoTreeKind.values[kindIdx];

    if (pos + 2 > end) return null;
    final tableLen = bd.getUint16(pos, Endian.little);
    pos += 2;
    if (pos + tableLen > end) return null;
    final tableName =
        utf8.decode(Uint8List.sublistView(bytes, pos, pos + tableLen));
    pos += tableLen;

    if (pos + 2 > end) return null;
    final indexLen = bd.getUint16(pos, Endian.little);
    pos += 2;
    if (pos + indexLen > end) return null;
    final String? indexName = indexLen == 0
        ? null
        : utf8.decode(Uint8List.sublistView(bytes, pos, pos + indexLen));
    pos += indexLen;

    switch (recType) {
      case _recTypePage:
        if (pos + 4 + 4 + 4 > end) return null;
        final partitionNo = bd.getInt32(pos, Endian.little);
        pos += 4;
        final pageNo = bd.getInt32(pos, Endian.little);
        pos += 4;
        final payloadLen = bd.getUint32(pos, Endian.little);
        pos += 4;
        if (pos + payloadLen > end) return null;
        final payload = Uint8List.sublistView(bytes, pos, pos + payloadLen);
        return PageRedoPageRecord(
          treeKind: kind,
          tableName: tableName,
          indexName: indexName,
          partitionNo: partitionNo,
          pageNo: pageNo,
          payload: payload,
          nextStart: end,
        );

      case _recTypeTreeMeta:
        // Fixed numeric payload (40 bytes) after names.
        if (pos + 40 > end) return null;
        final btreePageSize = bd.getUint32(pos, Endian.little);
        pos += 4;
        final btreeNextPageNo = bd.getUint32(pos, Endian.little);
        pos += 4;
        final btreePartitionCount = bd.getUint32(pos, Endian.little);
        pos += 4;
        final btreeRootPartitionNo = bd.getInt32(pos, Endian.little);
        pos += 4;
        final btreeRootPageNo = bd.getInt32(pos, Endian.little);
        pos += 4;
        final btreeFirstLeafPartitionNo = bd.getInt32(pos, Endian.little);
        pos += 4;
        final btreeFirstLeafPageNo = bd.getInt32(pos, Endian.little);
        pos += 4;
        final btreeLastLeafPartitionNo = bd.getInt32(pos, Endian.little);
        pos += 4;
        final btreeLastLeafPageNo = bd.getInt32(pos, Endian.little);
        pos += 4;
        final btreeHeight = bd.getInt32(pos, Endian.little);
        return PageRedoTreeMetaRecord(
          treeKind: kind,
          tableName: tableName,
          indexName: indexName,
          btreePageSize: btreePageSize,
          btreeNextPageNo: btreeNextPageNo,
          btreePartitionCount: btreePartitionCount,
          btreeRootPartitionNo: btreeRootPartitionNo,
          btreeRootPageNo: btreeRootPageNo,
          btreeFirstLeafPartitionNo: btreeFirstLeafPartitionNo,
          btreeFirstLeafPageNo: btreeFirstLeafPageNo,
          btreeLastLeafPartitionNo: btreeLastLeafPartitionNo,
          btreeLastLeafPageNo: btreeLastLeafPageNo,
          btreeHeight: btreeHeight,
          nextStart: end,
        );

      default:
        return null;
    }
  }
}
