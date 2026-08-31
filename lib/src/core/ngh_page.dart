import 'dart:convert';
import 'dart:typed_data';

import '../handler/platform_byte_data.dart';
import 'btree_page.dart';

// ============================================================================
// NGH Page Structures
//
// All pages reuse BTreePageHeader (20-byte header with magic/CRC/type/flags)
// and BTreePageIO for encoding/decoding.
//
// Page types:
//   nghMeta      -- per-partition-file metadata (pageNo=0)
//   nghPosting   -- inverted cluster posting page with inlined SQ8 vector slots
//   nghNavGraph  -- memory/disk navigating centroid graph nodes
// ============================================================================

// ============================================================================
// NGH Per-Partition Meta Page (pageNo=0)
// ============================================================================

/// Per-partition-file metadata for NGH index partitions.
///
/// Stored in-band at pageNo=0. Fixed 128-byte payload for forward-compatibility.
/// Tracks per-file entry counts, file size, and free-list head.
final class NghPartitionMetaPage {
  static const int payloadSize = 128;
  static const int payloadVersion = 1;
  static const int _payloadMagic = 0x3148474E; // 'NGH1'

  /// Which partition file this meta belongs to.
  final int partitionNo;

  /// Category of data stored in this partition file.
  /// 0 = graph, 1 = pqCode, 2 = rawVector, 3 = codebook.
  final int dataCategory;

  /// Total entries (nodes / vectors / codebook pages) in this file.
  final int totalEntryCount;

  /// Actual file size in bytes.
  final int totalSizeBytes;

  /// Freelist head pageNo within this file (-1 = empty).
  final int freeListHeadPageNo;

  /// Best-effort count of free pages in this file.
  final int freePageCount;

  const NghPartitionMetaPage({
    required this.partitionNo,
    this.dataCategory = 0,
    this.totalEntryCount = 0,
    this.totalSizeBytes = 0,
    this.freeListHeadPageNo = -1,
    this.freePageCount = 0,
  });

  Uint8List encodePayload() {
    final bd = ByteData(payloadSize);
    bd.setUint32(0, _payloadMagic, Endian.little);
    bd.setUint16(4, payloadVersion, Endian.little);
    bd.setUint16(6, dataCategory, Endian.little);
    bd.setInt32(8, partitionNo, Endian.little);
    bd.setInt32(12, 0, Endian.little); // reserved
    PlatformByteData.setInt64(bd, 16, totalEntryCount, Endian.little);
    PlatformByteData.setInt64(bd, 24, totalSizeBytes, Endian.little);
    bd.setInt32(32, freeListHeadPageNo, Endian.little);
    bd.setInt32(36, freePageCount, Endian.little);
    // [40..127] reserved
    return bd.buffer.asUint8List();
  }

  static NghPartitionMetaPage? tryDecodePayload(Uint8List bytes) {
    if (bytes.length < 40) return null;
    final bd = ByteData.sublistView(bytes);
    if (bd.getUint32(0, Endian.little) != _payloadMagic) return null;
    final v = bd.getUint16(4, Endian.little);
    if (v <= 0) return null;
    final cat = bd.getUint16(6, Endian.little);
    final pNo = bd.getInt32(8, Endian.little);
    final total = PlatformByteData.getInt64(bd, 16, Endian.little);
    final size = PlatformByteData.getInt64(bd, 24, Endian.little);
    final freeHead = bd.getInt32(32, Endian.little);
    final freeCount = bd.getInt32(36, Endian.little);
    return NghPartitionMetaPage(
      partitionNo: pNo,
      dataCategory: cat,
      totalEntryCount: total < 0 ? 0 : total,
      totalSizeBytes: size < 0 ? 0 : size,
      freeListHeadPageNo: freeHead,
      freePageCount: freeCount < 0 ? 0 : freeCount,
    );
  }
}

// ============================================================================
// NGH Posting Page (Inverted Cluster Data Page)
// ============================================================================

/// Inlined SQ8 compressed vector entry with metadata inside an inverted cluster posting page.
final class NghPostingSlot {
  /// Unique vector node/document ID.
  int nodeId;

  /// Logical deletion / tombstone flag (0 = active, 1 = deleted).
  int flags;

  /// Lazily decoded primary key (set on insert, or first access after disk decode).
  String? _decodedPrimaryKey;

  /// UTF-8 PK bytes from disk (sublistView). Avoids decode until needed.
  Uint8List? primaryKeyBytes;

  /// 8-bit quantized vector components. Length == dimensions.
  Uint8List sq8Codes;

  /// Min raw component value (offset).
  double offset;

  /// Step size per quantization level: (max - min) / 255.0.
  double scale;

  /// Pre-computed squared L2 norm for fast exact/approximate distance calculations.
  double squaredNorm;

  NghPostingSlot({
    required this.nodeId,
    this.flags = 0,
    String? primaryKey,
    this.primaryKeyBytes,
    required this.sq8Codes,
    required this.offset,
    required this.scale,
    required this.squaredNorm,
  }) : _decodedPrimaryKey = primaryKey;

  /// Original string primary key (decoded on demand for disk-loaded slots).
  String get primaryKey {
    final cached = _decodedPrimaryKey;
    if (cached != null) return cached;
    final bytes = primaryKeyBytes;
    if (bytes == null || bytes.isEmpty) return '';
    return _decodedPrimaryKey = utf8.decode(bytes);
  }

  set primaryKey(String value) {
    _decodedPrimaryKey = value;
    primaryKeyBytes = null;
  }

  /// Wire-format UTF-8 bytes without forcing a Dart String round-trip.
  Uint8List get primaryKeyUtf8 {
    final bytes = primaryKeyBytes;
    if (bytes != null) return bytes;
    return Uint8List.fromList(utf8.encode(primaryKey));
  }

  bool get isDeleted => (flags & 0x01) != 0;

  /// Approximate in-memory / serialized byte size of this slot.
  int estimateSize() {
    final pkLen = primaryKeyBytes?.length ?? (primaryKey.length * 2);
    return 20 + pkLen + sq8Codes.length;
  }
}

/// An inverted cluster posting page storing multiple inlined [NghPostingSlot]s.
final class NghPostingPage {
  /// Owning cluster/centroid ID.
  final int centroidId;

  /// Next chained posting page packed ref (`partitionNo<<20|pageNo`), or -1.
  int nextPostingPageNo;

  /// Vector dimensionality.
  final int dimensions;

  /// List of vector entries stored in this page.
  final List<NghPostingSlot> slots;

  NghPostingPage({
    required this.centroidId,
    this.nextPostingPageNo = -1,
    required this.dimensions,
    required this.slots,
  });

  /// Create an empty posting page for a cluster.
  factory NghPostingPage.empty({
    required int centroidId,
    required int dimensions,
  }) {
    return NghPostingPage(
      centroidId: centroidId,
      dimensions: dimensions,
      slots: [],
    );
  }

  /// Encode posting page payload.
  ///
  /// Wire layout:
  ///   [centroidId: u32][nextPostingPackedRef: i32][dimensions: u16][slotCount: u16]
  ///   For each slot:
  ///     [nodeId: u32][flags: u8][offset: f32][scale: f32][sqNorm: f32][pkLen: u16][pkBytes: pkLen][sq8Codes: D bytes]
  Uint8List encodePayload() {
    final slotCount = slots.length;
    int totalBytes = 12; // 4 + 4 + 2 + 2

    final pks =
        List<Uint8List>.filled(slotCount, Uint8List(0), growable: false);
    for (int i = 0; i < slotCount; i++) {
      final pkBytes = slots[i].primaryKeyUtf8;
      pks[i] = pkBytes;
      totalBytes += 19 + pkBytes.length + dimensions;
    }

    final buf = Uint8List(totalBytes);
    final bd = ByteData.sublistView(buf);

    bd.setUint32(0, centroidId, Endian.little);
    bd.setInt32(4, nextPostingPageNo, Endian.little);
    bd.setUint16(8, dimensions, Endian.little);
    bd.setUint16(10, slotCount, Endian.little);

    int off = 12;
    for (int i = 0; i < slotCount; i++) {
      final slot = slots[i];
      final pkBytes = pks[i];

      bd.setUint32(off, slot.nodeId, Endian.little);
      buf[off + 4] = slot.flags;
      bd.setFloat32(off + 5, slot.offset, Endian.little);
      bd.setFloat32(off + 9, slot.scale, Endian.little);
      bd.setFloat32(off + 13, slot.squaredNorm, Endian.little);
      bd.setUint16(off + 17, pkBytes.length, Endian.little);
      off += 19;

      buf.setRange(off, off + pkBytes.length, pkBytes);
      off += pkBytes.length;

      buf.setRange(off, off + dimensions, slot.sq8Codes);
      off += dimensions;
    }

    return buf;
  }

  /// Decode posting page payload.
  static NghPostingPage? tryDecodePayload(Uint8List bytes) {
    if (bytes.length < 12) return null;
    final bd = ByteData.sublistView(bytes);

    final cId = bd.getUint32(0, Endian.little);
    final nextPg = bd.getInt32(4, Endian.little);
    final dims = bd.getUint16(8, Endian.little);
    final count = bd.getUint16(10, Endian.little);

    if (dims == 0) return null;

    int off = 12;
    final slots = <NghPostingSlot>[];

    for (int i = 0; i < count; i++) {
      if (off + 19 > bytes.length) break;
      final nodeId = bd.getUint32(off, Endian.little);
      final flags = bytes[off + 4];
      final offset = bd.getFloat32(off + 5, Endian.little);
      final scale = bd.getFloat32(off + 9, Endian.little);
      final sqNorm = bd.getFloat32(off + 13, Endian.little);
      final pkLen = bd.getUint16(off + 17, Endian.little);
      off += 19;

      if (off + pkLen + dims > bytes.length) break;

      // Keep UTF-8 view; decode only when primaryKey is accessed.
      final pkBytes = Uint8List.sublistView(bytes, off, off + pkLen);
      off += pkLen;

      // View into page buffer — avoid per-slot SQ8 copies on decode.
      final sq8Codes = Uint8List.sublistView(bytes, off, off + dims);
      off += dims;

      slots.add(NghPostingSlot(
        nodeId: nodeId,
        flags: flags,
        primaryKeyBytes: pkBytes,
        sq8Codes: sq8Codes,
        offset: offset,
        scale: scale,
        squaredNorm: sqNorm,
      ));
    }

    return NghPostingPage(
      centroidId: cId,
      nextPostingPageNo: nextPg,
      dimensions: dims,
      slots: slots,
    );
  }

  int estimatePayloadSize() {
    int size = 12;
    for (final s in slots) {
      final pkLen = s.primaryKeyBytes?.length ?? s.primaryKey.length * 2;
      size += 19 + pkLen + dimensions;
    }
    return size;
  }
}

// ============================================================================
// NGH Navigating Centroid Graph Page
// ============================================================================

/// A centroid node in the navigating graph.
final class NghNavCentroidNode {
  /// Centroid identifier (0..K-1).
  final int centroidId;

  /// Centroid vector (Float32List of length [dimensions]).
  final Float32List vector;

  /// Head posting page packed ref (`partitionNo<<20|pageNo`), or -1.
  int headPostingPageNo;

  /// Tail posting page packed ref (`partitionNo<<20|pageNo`), or -1.
  int tailPostingPageNo;

  /// Total number of active vectors belonging to this cluster.
  int entryCount;

  /// Out-degree and neighbor centroid IDs in the navigating graph.
  final List<int> neighbors;

  /// All physical inverted posting page packed refs for this cluster.
  final List<int> postingPageNos;

  NghNavCentroidNode({
    required this.centroidId,
    required this.vector,
    this.headPostingPageNo = -1,
    this.tailPostingPageNo = -1,
    this.entryCount = 0,
    List<int>? neighbors,
    List<int>? postingPageNos,
  })  : neighbors = neighbors ?? [],
        postingPageNos = postingPageNos ??
            (headPostingPageNo > 0
                ? (headPostingPageNo == tailPostingPageNo ||
                        tailPostingPageNo <= 0
                    ? [headPostingPageNo]
                    : [headPostingPageNo, tailPostingPageNo])
                : []);
}

/// A serialized page of navigating centroid graph nodes.
final class NghNavGraphPage {
  final int dimensions;
  final List<NghNavCentroidNode> centroids;

  NghNavGraphPage({
    required this.dimensions,
    required this.centroids,
  });

  Uint8List encodePayload() {
    final count = centroids.length;
    int totalBytes = 4; // dims: u16, count: u16

    for (final c in centroids) {
      totalBytes += (4 +
          4 +
          4 +
          4 +
          dimensions * 4 +
          2 +
          c.neighbors.length * 2 +
          2 +
          c.postingPageNos.length * 4);
    }

    final buf = Uint8List(totalBytes);
    final bd = ByteData.sublistView(buf);

    bd.setUint16(0, dimensions, Endian.little);
    bd.setUint16(2, count, Endian.little);

    int off = 4;
    for (final c in centroids) {
      bd.setUint32(off, c.centroidId, Endian.little);
      bd.setInt32(off + 4, c.headPostingPageNo, Endian.little);
      bd.setInt32(off + 8, c.tailPostingPageNo, Endian.little);
      bd.setInt32(off + 12, c.entryCount, Endian.little);
      off += 16;

      for (int d = 0; d < dimensions; d++) {
        bd.setFloat32(off, c.vector[d], Endian.little);
        off += 4;
      }

      final nLen = c.neighbors.length;
      bd.setUint16(off, nLen, Endian.little);
      off += 2;

      for (int n = 0; n < nLen; n++) {
        bd.setUint16(off, c.neighbors[n], Endian.little);
        off += 2;
      }

      final pLen = c.postingPageNos.length;
      bd.setUint16(off, pLen, Endian.little);
      off += 2;

      for (int p = 0; p < pLen; p++) {
        bd.setInt32(off, c.postingPageNos[p], Endian.little);
        off += 4;
      }
    }

    return buf;
  }

  static NghNavGraphPage? tryDecodePayload(Uint8List bytes) {
    if (bytes.length < 4) return null;
    final bd = ByteData.sublistView(bytes);

    final dims = bd.getUint16(0, Endian.little);
    final count = bd.getUint16(2, Endian.little);
    if (dims == 0) return null;

    int off = 4;
    final list = <NghNavCentroidNode>[];

    for (int i = 0; i < count; i++) {
      if (off + 16 > bytes.length) break;
      final cId = bd.getUint32(off, Endian.little);
      final headPg = bd.getInt32(off + 4, Endian.little);
      final tailPg = bd.getInt32(off + 8, Endian.little);
      final countEntries = bd.getInt32(off + 12, Endian.little);
      off += 16;

      if (off + dims * 4 + 2 > bytes.length) break;
      final vec = Float32List(dims);
      for (int d = 0; d < dims; d++) {
        vec[d] = bd.getFloat32(off, Endian.little);
        off += 4;
      }

      final nLen = bd.getUint16(off, Endian.little);
      off += 2;

      if (off + nLen * 2 > bytes.length) break;
      final neighbors = <int>[];
      for (int n = 0; n < nLen; n++) {
        neighbors.add(bd.getUint16(off, Endian.little));
        off += 2;
      }

      final postingPageNos = <int>[];
      if (off + 2 <= bytes.length) {
        final pLen = bd.getUint16(off, Endian.little);
        off += 2;
        if (off + pLen * 4 <= bytes.length) {
          for (int p = 0; p < pLen; p++) {
            postingPageNos.add(bd.getInt32(off, Endian.little));
            off += 4;
          }
        }
      }

      if (postingPageNos.isEmpty && headPg > 0) {
        postingPageNos.add(headPg);
        if (tailPg > 0 && tailPg != headPg) {
          postingPageNos.add(tailPg);
        }
      }

      list.add(NghNavCentroidNode(
        centroidId: cId,
        vector: vec,
        headPostingPageNo: headPg,
        tailPostingPageNo: tailPg,
        entryCount: countEntries,
        neighbors: neighbors,
        postingPageNos: postingPageNos,
      ));
    }

    return NghNavGraphPage(dimensions: dims, centroids: list);
  }

  int estimatePayloadSize() {
    int size = 4;
    for (final c in centroids) {
      size += 18 + dimensions * 4 + c.neighbors.length * 2;
    }
    return size;
  }
}

// ============================================================================
// NGH Page Size Utilities
// ============================================================================

/// Helper to compute slot counts and check page capacity.
final class NghPageSizer {
  NghPageSizer._();

  static const int pageHeaderSize = BTreePageHeader.size; // 20

  /// Safety margin for encoding/encryption overhead (header, padding, etc).
  static const int encodingSafetyMargin = 64;

  /// Compute how many posting slots can fit in one page for a given average PK length.
  static int estimatePostingSlotsPerPage(
    int pageSize,
    int dimensions, {
    int avgPkLength = 16,
  }) {
    final slotSize = 19 + avgPkLength + dimensions;
    final usable = pageSize - pageHeaderSize - 12 - encodingSafetyMargin;
    return usable > 0 ? (usable ~/ slotSize).clamp(1, 1024) : 1;
  }

  /// Estimate file size given page count and page size.
  static int estimateFileSizeBytes(int pageSize, int nextPageNo) {
    return pageSize * nextPageNo;
  }

  /// Whether the encoded payload fits within the page.
  static bool fitsInPage(int payloadSize, int pageSize) {
    return (pageHeaderSize + payloadSize) <= pageSize;
  }
}
