import 'dart:convert';
import 'dart:typed_data';

import '../model/db_exception.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/table_identity.dart';

/// Page redo log: append-only records for crash-safe page replay.
///
/// ## Write path (current)
/// Only [PageRedoLogCodec.encodePageRecord]. Partition-0 page0 payloads carry
/// full tree-global meta (TMP1 [TreeMetaPagePayload]); do not invent a separate
/// structure-only record for new batches.
///
/// ## Read path
/// [PageRedoLogCodec.decodeRecord] accepts:
/// - type 1: [PageRedoPageRecord] (current)
/// - type 2: [PageRedoTreeMetaRecord] (legacy structure snapshot only)
///
/// Legacy type-2 records are applied by recovery **only when** the same redo
/// log did not restore partition-0 page0.
///
/// Framing: `[recLen:u32 LE][recType:u8][payload...]`
/// Strings: UTF-8 with `[len:u16 LE][bytes]`.
enum PageRedoTreeKind {
  table,
  indexTree,

  /// NGH vector pages (global meta on graph partition 0 page 0).
  ngh,
}

sealed class PageRedoLogRecord {
  final int nextStart;
  const PageRedoLogRecord({required this.nextStart});
}

/// Full page after-image (the only record type new code should append).
final class PageRedoPageRecord extends PageRedoLogRecord {
  final PageRedoTreeKind treeKind;
  final TableUid tableUid;
  final IndexUid? indexUid;
  final int partitionNo;
  final int pageNo;
  final Uint8List payload;

  const PageRedoPageRecord({
    required this.treeKind,
    required this.tableUid,
    required this.indexUid,
    required this.partitionNo,
    required this.pageNo,
    required this.payload,
    required super.nextStart,
  });
}

/// Legacy decode-only: structure pointers without totals.
///
/// Written by older engines before global meta lived in page0. There is **no**
/// public encode API anymore -- new writers must use [PageRedoPageRecord].
final class PageRedoTreeMetaRecord extends PageRedoLogRecord {
  final PageRedoTreeKind treeKind;
  final TableUid tableUid;
  final IndexUid? indexUid;

  /// Wire field from legacy logs; runtime page size is [DataStoreImpl.configuredPageSize].
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
    required this.tableUid,
    required this.indexUid,
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
  static const int _recTypeTreeMetaLegacy = 2;

  static Uint8List _u16StringBytes(String s) {
    final b = Uint8List.fromList(utf8.encode(s));
    if (b.length > 0xFFFF) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.engError,
          message: 'PageRedoLog: string too long (${b.length})',
          parameterName: 's',
          passedValue: s,
        ),
      ]);
    }
    return b;
  }

  /// Encode one page write (full page bytes). This is the sole write API.
  static Uint8List encodePageRecord({
    required PageRedoTreeKind treeKind,
    required TableUid tableUid,
    IndexUid? indexUid,
    required int partitionNo,
    required int pageNo,
    required Uint8List payload,
  }) {
    final tableBytes = _u16StringBytes(tableUid);
    final needsIndex = treeKind == PageRedoTreeKind.indexTree ||
        treeKind == PageRedoTreeKind.ngh;
    final indexBytes =
        needsIndex ? _u16StringBytes(indexUid?.value ?? '') : Uint8List(0);

    if (needsIndex && (indexUid == null || indexUid.isEmpty)) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.engError,
          message: 'PageRedoLog: indexUid required for index/ngh records',
          parameterName: 'indexUid',
        ),
      ]);
    }

    final int payloadLen = payload.length;
    final int recLen = 4 + // recLen
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

  /// Decode next record at [start], or null if truncated / invalid.
  static PageRedoLogRecord? decodeRecord(Uint8List bytes, int start) {
    if (start + 4 > bytes.length) return null;
    final bd = ByteData.sublistView(bytes);
    final recLen = bd.getUint32(start, Endian.little);
    if (recLen < 6) return null;
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
    final tableUid = TableUid(
        utf8.decode(Uint8List.sublistView(bytes, pos, pos + tableLen)));
    pos += tableLen;

    if (pos + 2 > end) return null;
    final indexLen = bd.getUint16(pos, Endian.little);
    pos += 2;
    if (pos + indexLen > end) return null;
    final IndexUid? indexUid = indexLen == 0
        ? null
        : IndexUid(
            utf8.decode(Uint8List.sublistView(bytes, pos, pos + indexLen)));
    pos += indexLen;

    switch (recType) {
      case _recTypePage:
        return _decodePageRecord(
          bd: bd,
          bytes: bytes,
          pos: pos,
          end: end,
          kind: kind,
          tableUid: tableUid,
          indexUid: indexUid,
        );
      case _recTypeTreeMetaLegacy:
        return _decodeLegacyTreeMetaRecord(
          bd: bd,
          pos: pos,
          end: end,
          kind: kind,
          tableUid: tableUid,
          indexUid: indexUid,
        );
      default:
        return null;
    }
  }

  static PageRedoPageRecord? _decodePageRecord({
    required ByteData bd,
    required Uint8List bytes,
    required int pos,
    required int end,
    required PageRedoTreeKind kind,
    required TableUid tableUid,
    required IndexUid? indexUid,
  }) {
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
      tableUid: tableUid,
      indexUid: indexUid,
      partitionNo: partitionNo,
      pageNo: pageNo,
      payload: payload,
      nextStart: end,
    );
  }

  /// Fixed 40-byte numeric trailer after names (legacy type 2).
  static PageRedoTreeMetaRecord? _decodeLegacyTreeMetaRecord({
    required ByteData bd,
    required int pos,
    required int end,
    required PageRedoTreeKind kind,
    required TableUid tableUid,
    required IndexUid? indexUid,
  }) {
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
      tableUid: tableUid,
      indexUid: indexUid,
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
  }
}
