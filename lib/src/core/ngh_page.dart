import 'dart:typed_data';

import '../handler/platform_byte_data.dart';
import 'btree_page.dart';

// ============================================================================
// NGH (Node-Graph Hybrid) Page Structures
//
// All pages reuse BTreePageHeader (20-byte header with magic/CRC/type/flags)
// and BTreePageIO for encoding/decoding. The payload formats below are specific
// to NGH vector index storage.
//
// Page types:
//   nghMeta      — per-partition-file metadata (pageNo=0)
//   nghGraph     — fixed-slot graph nodes with neighbor lists
//   nghPqCode    — densely packed PQ codes
//   nghRawVector — full-precision vectors for re-ranking
//   nghCodebook  — trained PQ centroid vectors
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
  final int totalEntries;

  /// Actual file size in bytes.
  final int fileSizeInBytes;

  /// Freelist head pageNo within this file (-1 = empty).
  final int freeListHeadPageNo;

  /// Best-effort count of free pages in this file.
  final int freePageCount;

  const NghPartitionMetaPage({
    required this.partitionNo,
    this.dataCategory = 0,
    this.totalEntries = 0,
    this.fileSizeInBytes = 0,
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
    PlatformByteData.setInt64(bd, 16, totalEntries, Endian.little);
    PlatformByteData.setInt64(bd, 24, fileSizeInBytes, Endian.little);
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
      totalEntries: total < 0 ? 0 : total,
      fileSizeInBytes: size < 0 ? 0 : size,
      freeListHeadPageNo: freeHead,
      freePageCount: freeCount < 0 ? 0 : freeCount,
    );
  }
}

// ============================================================================
// NGH Graph Page — Fixed-Slot Neighbor Lists
// ============================================================================

/// Node flags stored in the first byte of each graph slot.
abstract final class NghNodeFlags {
  static const int deleted = 0x01; // tombstone
  static const int updated = 0x02; // pending compaction
}

/// A single graph node within an [NghGraphPage].
///
/// Fixed-size slot layout:
///   [flags:u8][actualDegree:u8][neighbors: maxDegree × u32]
final class NghGraphNode {
  /// Node status flags (see [NghNodeFlags]).
  int flags;

  /// Actual number of valid neighbors (≤ maxDegree).
  int actualDegree;

  /// Neighbor node IDs. Length == maxDegree; only first [actualDegree] valid.
  final Uint32List neighbors;

  NghGraphNode({
    this.flags = 0,
    this.actualDegree = 0,
    required this.neighbors,
  });

  bool get isDeleted => (flags & NghNodeFlags.deleted) != 0;

  /// Create an empty node with the given max degree.
  factory NghGraphNode.empty(int maxDegree) {
    return NghGraphNode(neighbors: Uint32List(maxDegree));
  }
}

/// A page of fixed-size graph node slots.
///
/// Payload layout:
///   [slotCount:u16][maxDegree:u16]
///   [slot_0][slot_1]...[slot_{slotCount-1}]
///
/// Each slot is exactly `2 + maxDegree * 4` bytes.
final class NghGraphPage {
  /// Configured max degree (same for all slots in this page).
  final int maxDegree;

  /// Node slots. Length == slotCount (the number of slots that fit per page).
  final List<NghGraphNode> slots;

  NghGraphPage({required this.maxDegree, required this.slots});

  /// Bytes per node slot: 1(flags) + 1(degree) + maxDegree * 4.
  int get nodeSlotSize => 2 + maxDegree * 4;

  /// Create a page pre-filled with empty slots.
  factory NghGraphPage.empty({required int maxDegree, required int slotCount}) {
    return NghGraphPage(
      maxDegree: maxDegree,
      slots: List.generate(slotCount, (_) => NghGraphNode.empty(maxDegree),
          growable: false),
    );
  }

  Uint8List encodePayload() {
    final slotSize = nodeSlotSize;
    final totalLen = 4 + slots.length * slotSize;
    final buf = Uint8List(totalLen);
    final bd = ByteData.sublistView(buf);
    bd.setUint16(0, slots.length, Endian.little);
    bd.setUint16(2, maxDegree, Endian.little);

    int off = 4;
    for (int i = 0; i < slots.length; i++) {
      final node = slots[i];
      buf[off] = node.flags;
      buf[off + 1] = node.actualDegree;
      off += 2;
      for (int j = 0; j < maxDegree; j++) {
        bd.setUint32(
            off, j < node.actualDegree ? node.neighbors[j] : 0, Endian.little);
        off += 4;
      }
    }
    return buf;
  }

  static NghGraphPage? tryDecodePayload(Uint8List bytes) {
    if (bytes.length < 4) return null;
    final bd = ByteData.sublistView(bytes);
    final slotCount = bd.getUint16(0, Endian.little);
    final maxDeg = bd.getUint16(2, Endian.little);
    if (maxDeg == 0) return null;
    final slotSize = 2 + maxDeg * 4;
    if (bytes.length < 4 + slotCount * slotSize) return null;

    int off = 4;
    final slots = List<NghGraphNode>.generate(slotCount, (_) {
      final flags = bytes[off];
      final degree = bytes[off + 1];
      off += 2;
      final neighbors = Uint32List(maxDeg);
      for (int j = 0; j < maxDeg; j++) {
        neighbors[j] = bd.getUint32(off, Endian.little);
        off += 4;
      }
      return NghGraphNode(
        flags: flags,
        actualDegree: degree > maxDeg ? maxDeg : degree,
        neighbors: neighbors,
      );
    }, growable: false);

    return NghGraphPage(maxDegree: maxDeg, slots: slots);
  }

  int estimatePayloadSize() => 4 + slots.length * nodeSlotSize;
}

// ============================================================================
// NGH PQ-Code Page — Dense Quantisation Codes
// ============================================================================

/// A page of densely packed PQ codes.
///
/// Payload layout:
///   [vectorCount:u16][pqSubspaces:u16]
///   [code_0: M bytes][code_1: M bytes]...
///
/// Total payload = 4 + vectorCount × M bytes.
final class NghPqCodePage {
  /// Number of PQ sub-spaces (M); each code is M bytes.
  final int pqSubspaces;

  /// Packed PQ codes; each entry is [pqSubspaces] bytes.
  /// Total length = vectorCount × pqSubspaces.
  final Uint8List codes;

  /// Number of vectors stored in this page.
  final int vectorCount;

  NghPqCodePage({
    required this.pqSubspaces,
    required this.codes,
    required this.vectorCount,
  });

  /// Create an empty page pre-allocated for [capacity] vectors.
  factory NghPqCodePage.empty(
      {required int pqSubspaces, required int capacity}) {
    return NghPqCodePage(
      pqSubspaces: pqSubspaces,
      codes: Uint8List(capacity * pqSubspaces),
      vectorCount: capacity,
    );
  }

  /// Get PQ code for the vector at [index] within this page.
  /// Returns a view (zero-copy) — safe for Uint8List on all platforms.
  Uint8List getCode(int index) {
    final off = index * pqSubspaces;
    return Uint8List.view(codes.buffer, codes.offsetInBytes + off, pqSubspaces);
  }

  /// Set PQ code for the vector at [index] within this page.
  void setCode(int index, Uint8List code) {
    if (code.length != pqSubspaces) {
      throw StateError(
          'PQ code length mismatch: expected $pqSubspaces, got ${code.length}');
    }
    final off = index * pqSubspaces;
    codes.setRange(off, off + pqSubspaces, code);
  }

  Uint8List encodePayload() {
    final totalLen = 4 + vectorCount * pqSubspaces;
    final buf = Uint8List(totalLen);
    final bd = ByteData.sublistView(buf);
    bd.setUint16(0, vectorCount, Endian.little);
    bd.setUint16(2, pqSubspaces, Endian.little);
    buf.setRange(4, 4 + codes.length, codes);
    return buf;
  }

  static NghPqCodePage? tryDecodePayload(Uint8List bytes) {
    if (bytes.length < 4) return null;
    final bd = ByteData.sublistView(bytes);
    final vCount = bd.getUint16(0, Endian.little);
    final m = bd.getUint16(2, Endian.little);
    if (m == 0) return null;
    final dataLen = vCount * m;
    if (bytes.length < 4 + dataLen) return null;
    final codes = Uint8List.fromList(bytes.sublist(4, 4 + dataLen));
    return NghPqCodePage(pqSubspaces: m, codes: codes, vectorCount: vCount);
  }

  int estimatePayloadSize() => 4 + vectorCount * pqSubspaces;
}

// ============================================================================
// NGH Raw-Vector Page — Full-Precision Vectors
// ============================================================================

/// A page of full-precision raw vectors for re-ranking.
///
/// Payload layout:
///   [vectorCount:u16][dimensions:u16][precision:u8][padding:u24]
///   [vec_0: D × bytesPerElem][vec_1: D × bytesPerElem]...
final class NghRawVectorPage {
  final int dimensions;

  /// 0=float64, 1=float32, 2=int8 (same order as [VectorPrecision] enum).
  final int precisionIndex;

  /// Raw bytes for all vectors, packed contiguously.
  /// Length = vectorCount × dimensions × bytesPerElement.
  final Uint8List data;

  /// Number of vectors in this page.
  final int vectorCount;

  NghRawVectorPage({
    required this.dimensions,
    required this.precisionIndex,
    required this.data,
    required this.vectorCount,
  });

  /// Bytes per element based on precision.
  int get bytesPerElement {
    switch (precisionIndex) {
      case 0:
        return 8; // float64
      case 2:
        return 1; // int8
      default:
        return 4; // float32
    }
  }

  /// Bytes per single vector.
  int get vectorSize => dimensions * bytesPerElement;

  /// Create an empty page pre-allocated for [capacity] vectors.
  factory NghRawVectorPage.empty({
    required int dimensions,
    required int precisionIndex,
    required int capacity,
  }) {
    final bpe = precisionIndex == 0
        ? 8
        : precisionIndex == 2
            ? 1
            : 4;
    return NghRawVectorPage(
      dimensions: dimensions,
      precisionIndex: precisionIndex,
      data: Uint8List(capacity * dimensions * bpe),
      vectorCount: capacity,
    );
  }

  /// Read vector at [index] as Float32List (normalised to float32).
  ///
  /// Uses ByteData element-wise reads to avoid alignment issues on web
  /// (Dart2JS typed-array views require platform-aligned offsets).
  Float32List getVectorAsFloat32(int index) {
    final off = index * vectorSize;
    final result = Float32List(dimensions);
    final bd = ByteData.sublistView(data, off, off + vectorSize);
    if (precisionIndex == 1) {
      // float32 → float32
      for (int i = 0; i < dimensions; i++) {
        result[i] = bd.getFloat32(i * 4, Endian.little);
      }
    } else if (precisionIndex == 0) {
      // float64 → float32
      for (int i = 0; i < dimensions; i++) {
        result[i] = bd.getFloat64(i * 8, Endian.little).toDouble();
      }
    } else {
      // int8 → float32 (de-quantize: value / 127.0)
      for (int i = 0; i < dimensions; i++) {
        result[i] = data[off + i].toSigned(8) / 127.0;
      }
    }
    return result;
  }

  /// Write a float32 vector at [index].
  ///
  /// Uses ByteData element-wise writes for web-safe unaligned access.
  void setVectorFromFloat32(int index, Float32List vec) {
    final off = index * vectorSize;
    final bd = ByteData.sublistView(data, off, off + vectorSize);
    if (precisionIndex == 1) {
      for (int i = 0; i < dimensions; i++) {
        bd.setFloat32(i * 4, vec[i], Endian.little);
      }
    } else if (precisionIndex == 0) {
      for (int i = 0; i < dimensions; i++) {
        bd.setFloat64(i * 8, vec[i].toDouble(), Endian.little);
      }
    } else {
      // float32 → int8 quantize (clamp to [-1, 1], scale to [-127, 127])
      for (int i = 0; i < dimensions; i++) {
        final clamped = vec[i].clamp(-1.0, 1.0);
        data[off + i] = (clamped * 127.0).round().toSigned(8).toUnsigned(8);
      }
    }
  }

  Uint8List encodePayload() {
    final headerLen = 8; // 2+2+1+3
    final totalLen = headerLen + data.length;
    final buf = Uint8List(totalLen);
    final bd = ByteData.sublistView(buf);
    bd.setUint16(0, vectorCount, Endian.little);
    bd.setUint16(2, dimensions, Endian.little);
    buf[4] = precisionIndex;
    // [5..7] padding
    buf.setRange(headerLen, headerLen + data.length, data);
    return buf;
  }

  static NghRawVectorPage? tryDecodePayload(Uint8List bytes) {
    if (bytes.length < 8) return null;
    final bd = ByteData.sublistView(bytes);
    final vCount = bd.getUint16(0, Endian.little);
    final dims = bd.getUint16(2, Endian.little);
    final prec = bytes[4];
    if (dims == 0) return null;
    final bpe = prec == 0
        ? 8
        : prec == 2
            ? 1
            : 4;
    final dataLen = vCount * dims * bpe;
    if (bytes.length < 8 + dataLen) return null;
    return NghRawVectorPage(
      dimensions: dims,
      precisionIndex: prec,
      data: Uint8List.fromList(bytes.sublist(8, 8 + dataLen)),
      vectorCount: vCount,
    );
  }

  int estimatePayloadSize() => 8 + data.length;
}

// ============================================================================
// NGH Codebook Page — PQ Centroid Vectors
// ============================================================================

/// Stores PQ codebook for one or more sub-spaces.
///
/// Payload layout:
///   [subspaceStart:u16] — first sub-space index stored in this page
///   [subspaceCount:u16] — number of sub-spaces in this page
///   [centroidsPerSubspace:u16] — K (typically 256)
///   [subspaceDimensions:u16]   — D/M (dimensions per sub-space)
///   [centroids: subspaceCount × K × (D/M) × 4 bytes (float32)]
final class NghCodebookPage {
  /// First sub-space index (for multi-page codebooks).
  final int subspaceStart;

  /// Number of sub-spaces stored in this page.
  final int subspaceCount;

  /// Number of centroids per sub-space (typically 256).
  final int centroidsPerSubspace;

  /// Dimensions per sub-space (D / M).
  final int subspaceDimensions;

  /// Centroid data, packed as float32.
  /// Layout: [sub0_cent0 ... sub0_centK-1][sub1_cent0 ...]...
  /// Total: subspaceCount × centroidsPerSubspace × subspaceDimensions floats.
  final Float32List centroids;

  NghCodebookPage({
    required this.subspaceStart,
    required this.subspaceCount,
    required this.centroidsPerSubspace,
    required this.subspaceDimensions,
    required this.centroids,
  });

  /// Get centroid vector for sub-space [m], centroid [k].
  /// Returns a sub-list view (safe on all platforms since [centroids] is aligned).
  Float32List getCentroid(int m, int k) {
    final offset = (m * centroidsPerSubspace + k) * subspaceDimensions;
    return centroids.sublist(offset, offset + subspaceDimensions);
  }

  Uint8List encodePayload() {
    final headerLen = 8; // 4 × u16
    final floatCount =
        subspaceCount * centroidsPerSubspace * subspaceDimensions;
    final dataBytes = floatCount * 4;
    final buf = Uint8List(headerLen + dataBytes);
    final bd = ByteData.sublistView(buf);
    bd.setUint16(0, subspaceStart, Endian.little);
    bd.setUint16(2, subspaceCount, Endian.little);
    bd.setUint16(4, centroidsPerSubspace, Endian.little);
    bd.setUint16(6, subspaceDimensions, Endian.little);
    // Write centroid floats element-wise for web-safe unaligned access
    for (int i = 0; i < floatCount; i++) {
      bd.setFloat32(headerLen + i * 4, centroids[i], Endian.little);
    }
    return buf;
  }

  static NghCodebookPage? tryDecodePayload(Uint8List bytes) {
    if (bytes.length < 8) return null;
    final bd = ByteData.sublistView(bytes);
    final start = bd.getUint16(0, Endian.little);
    final count = bd.getUint16(2, Endian.little);
    final k = bd.getUint16(4, Endian.little);
    final sDim = bd.getUint16(6, Endian.little);
    if (count == 0 || k == 0 || sDim == 0) return null;
    final floatCount = count * k * sDim;
    final dataBytes = floatCount * 4;
    if (bytes.length < 8 + dataBytes) return null;
    // Copy to aligned float32 buffer
    final aligned = Float32List(floatCount);
    final srcBd = ByteData.sublistView(bytes, 8, 8 + dataBytes);
    for (int i = 0; i < floatCount; i++) {
      aligned[i] = srcBd.getFloat32(i * 4, Endian.little);
    }
    return NghCodebookPage(
      subspaceStart: start,
      subspaceCount: count,
      centroidsPerSubspace: k,
      subspaceDimensions: sDim,
      centroids: aligned,
    );
  }

  int estimatePayloadSize() =>
      8 + subspaceCount * centroidsPerSubspace * subspaceDimensions * 4;
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

  /// Compute how many graph node slots fit in one page.
  static int nodesPerGraphPage(int pageSize, int maxDegree) {
    final slotSize = 2 + maxDegree * 4; // flags(1) + degree(1) + R*4
    final usable = pageSize -
        pageHeaderSize -
        4 -
        encodingSafetyMargin; // 4 = page-level header
    return usable > 0 ? usable ~/ slotSize : 0;
  }

  /// Compute how many PQ code entries fit in one page.
  static int vectorsPerPqPage(int pageSize, int pqSubspaces) {
    final usable = pageSize - pageHeaderSize - 4 - encodingSafetyMargin;
    return usable > 0 ? usable ~/ pqSubspaces : 0;
  }

  /// Compute how many raw vectors fit in one page.
  static int vectorsPerRawPage(int pageSize, int dimensions, int bpe) {
    final usable = pageSize - pageHeaderSize - 8 - encodingSafetyMargin;
    final vecSize = dimensions * bpe;
    return (usable > 0 && vecSize > 0) ? usable ~/ vecSize : 0;
  }

  /// Estimate file size given page count and page size.
  static int estimateFileSizeBytes(int pageSize, int nextPageNo) {
    return pageSize * nextPageNo;
  }

  /// Whether the encoded payload fits within the page.
  static bool fitsInPage(int payloadSize, int pageSize) {
    return (pageHeaderSize + payloadSize) <= pageSize;
  }

  /// Compute how many sub-spaces fit in one codebook page.
  /// Returns 0 if even a single sub-space exceeds page capacity.
  static int subspacesPerCodebookPage(
    int pageSize,
    int centroidsPerSubspace,
    int subspaceDimensions,
  ) {
    final headerLen = 8; // codebook page header
    // Codebook pages are generally not encrypted but we keep the margin for safety
    final usable = pageSize - pageHeaderSize - headerLen - encodingSafetyMargin;
    if (usable <= 0) return 0;
    final bytesPerSubspace = centroidsPerSubspace * subspaceDimensions * 4;
    if (bytesPerSubspace <= 0) return 0;
    // Must fit at least one sub-space
    if (bytesPerSubspace > usable) return 0;
    return usable ~/ bytesPerSubspace;
  }
}
