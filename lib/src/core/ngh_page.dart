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
  /// **Frozen wire layout** (engine v4 and later). Do not change field widths
  /// or drop inlined PK — tens-of-billions scale uses pdir (`u32+u32`) as the
  /// page-list authority, not a posting rewrite. `nextPostingPackedRef` is a
  /// hint; unrepresentable locations write `-1`.
  ///
  ///   [centroidId: u32][nextPostingPackedRef: i32][dimensions: u16][slotCount: u16]
  ///   For each slot:
  ///     [nodeId: u32][flags: u8][offset: f32][scale: f32][sqNorm: f32]
  ///     [pkLen: u16][pkBytes: pkLen][sq8Codes: D bytes]
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
// NGH page identity (v2: u32 partition + u32 page, not packed i32)
// ============================================================================

/// Physical page location that does not overflow at partition >= 2048.
final class NghPageId {
  static const int noneWire = 0xFFFFFFFF;
  static const int _maxPackedPartition = 2047;

  final int partitionNo;
  final int pageNo;

  const NghPageId(this.partitionNo, this.pageNo);
  static const NghPageId none = NghPageId(-1, -1);

  bool get isNone => partitionNo < 0 || pageNo <= 0;

  /// Cache / map key (Dart int is arbitrary-width).
  int get cacheKey => (partitionNo << 32) | (pageNo & 0xFFFFFFFF);

  /// Legacy i32 pack used inside v1 posting `next` fields. Null if unrepresentable.
  int? tryPack() {
    if (isNone) return -1;
    if (partitionNo > _maxPackedPartition ||
        pageNo > ((1 << 20) - 1) ||
        partitionNo < 0) {
      return null;
    }
    if (pageNo <= 0) return pageNo;
    return (partitionNo << 20) | (pageNo & ((1 << 20) - 1));
  }

  factory NghPageId.fromPacked(int packed) {
    if (packed <= 0) return none;
    return NghPageId(packed >> 20, packed & ((1 << 20) - 1));
  }

  static NghPageId fromWire(int partitionNo, int pageNo) {
    if (partitionNo == noneWire ||
        pageNo == noneWire ||
        partitionNo < 0 ||
        pageNo <= 0) {
      return none;
    }
    return NghPageId(partitionNo, pageNo);
  }

  int get wirePartition => isNone ? noneWire : partitionNo;
  int get wirePage => isNone ? noneWire : pageNo;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NghPageId &&
          other.partitionNo == partitionNo &&
          other.pageNo == pageNo);

  @override
  int get hashCode => Object.hash(partitionNo, pageNo);

  @override
  String toString() =>
      isNone ? 'NghPageId.none' : 'NghPageId(p$partitionNo, pg$pageNo)';
}

// ============================================================================
// NGH Navigating Centroid Graph Page
// ============================================================================

/// A centroid node in the navigating graph.
final class NghNavCentroidNode {
  static const int levelCoarse = 0;
  static const int levelLeaf = 1;

  /// Centroid identifier (0..K-1, u32 on v2 wire).
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

  /// All physical inverted posting pages for this cluster (v2 source of truth).
  final List<NghPageId> postingPages;

  /// Packed posting refs for search batch I/O when they still fit in i32.
  List<int> get postingPageNos => [
        for (final p in postingPages)
          if (p.tryPack() != null) p.tryPack()!,
      ];

  /// 0 = coarse (no posting, has children), 1 = leaf (owns posting lists).
  int level;

  /// Parent coarse centroid, or -1.
  int parentId;

  /// Root / tail of the posting-page directory chain.
  NghPageId postingDirRoot;
  NghPageId postingDirTail;

  /// Overflow children directory (inline [childIds] is preferred).
  NghPageId childrenDirRoot;

  /// Inline child centroid ids (hierarchical IVF). Empty for flat leaves.
  final List<int> childIds;

  /// Directory pages need a flush (append or rewrite).
  bool postingDirDirty;

  /// True when [postingPages] is the full live list (hydrate / rewrite /
  /// new cluster). False after loading nav from disk so search still hydrates
  /// pdir. Insert must not flip this by appending only the new tail pages.
  bool postingPageListReady;

  /// Pre-computed SIMD view for zero-allocation dot product kernels.
  Float32x4List? simdVector;

  Float32x4List? getSimdVector() {
    if (simdVector != null) return simdVector;
    final len = vector.length;
    final n = len >> 2;
    if (n <= 0) return null;
    if ((vector.offsetInBytes & 15) == 0) {
      simdVector = Float32x4List.view(vector.buffer, vector.offsetInBytes, n);
    } else {
      final aligned = Float32List(len);
      aligned.setAll(0, vector);
      simdVector = Float32x4List.view(aligned.buffer, aligned.offsetInBytes, n);
    }
    return simdVector;
  }

  bool get isCoarse => level == levelCoarse;
  bool get isLeaf => level != levelCoarse;

  NghNavCentroidNode({
    required this.centroidId,
    required this.vector,
    this.headPostingPageNo = -1,
    this.tailPostingPageNo = -1,
    this.entryCount = 0,
    List<int>? neighbors,
    List<int>? postingPageNos,
    List<NghPageId>? postingPages,
    this.level = levelLeaf,
    this.parentId = -1,
    this.postingDirRoot = NghPageId.none,
    this.postingDirTail = NghPageId.none,
    this.childrenDirRoot = NghPageId.none,
    List<int>? childIds,
    this.postingDirDirty = false,
    this.postingPageListReady = false,
  })  : neighbors = List<int>.of(neighbors ?? const <int>[]),
        childIds = List<int>.of(childIds ?? const <int>[]),
        postingPages = List<NghPageId>.of(
          postingPages ??
              _pagesFromPacked(
                postingPageNos,
                headPostingPageNo,
                tailPostingPageNo,
              ),
        ) {
    if (!postingPageListReady) {
      postingPageListReady = this.postingPages.isNotEmpty;
    }
    final len = vector.length;
    final n = len >> 2;
    if (n > 0 && (vector.offsetInBytes & 15) == 0) {
      simdVector = Float32x4List.view(vector.buffer, vector.offsetInBytes, n);
    }
  }

  static List<NghPageId> _pagesFromPacked(
    List<int>? packed,
    int headPacked,
    int tailPacked,
  ) {
    if (packed != null && packed.isNotEmpty) {
      return [
        for (final p in packed)
          if (p > 0) NghPageId.fromPacked(p)
      ];
    }
    if (headPacked > 0) {
      if (tailPacked > 0 && tailPacked != headPacked) {
        return [
          NghPageId.fromPacked(headPacked),
          NghPageId.fromPacked(tailPacked),
        ];
      }
      return [NghPageId.fromPacked(headPacked)];
    }
    return <NghPageId>[];
  }

  void addPostingPage(NghPageId id) {
    if (id.isNone) return;
    postingDirDirty = true;
    // Disk pdir is still authoritative. Recording only the new tail pages
    // would make postingPages non-empty and skip hydrate on search.
    if (!postingPageListReady && !postingDirRoot.isNone) return;
    for (final e in postingPages) {
      if (e.partitionNo == id.partitionNo && e.pageNo == id.pageNo) return;
    }
    postingPages.add(id);
    if (postingDirRoot.isNone) postingPageListReady = true;
  }

  void replacePostingPages(List<NghPageId> pages) {
    postingPages
      ..clear()
      ..addAll(pages);
    postingDirDirty = true;
    postingPageListReady = true;
  }

  void setHeadTailFromIds(NghPageId head, NghPageId tail) {
    headPostingPageNo = head.tryPack() ?? -1;
    tailPostingPageNo = tail.tryPack() ?? -1;
  }
}

/// A serialized page of navigating centroid graph nodes.
final class NghNavGraphPage {
  final int dimensions;
  final List<NghNavCentroidNode> centroids;

  /// On-disk records/page observed at load (first nav page). `null` = new graph.
  /// Used to detect 7-pack → 5-pack occupancy changes and rewrite all pages once.
  int? navPackPerPage;

  /// Cached top-level routing centroid IDs to eliminate repeated O(N) full graph scans on read queries.
  List<int>? cachedTopLevelRoutingIds;

  /// Cached centroid imbalance metric.
  double? cachedImbalance;

  /// Cached count of leaf centroids.
  int? cachedNLeaves;

  NghNavGraphPage({
    required this.dimensions,
    required this.centroids,
    this.navPackPerPage,
    this.cachedTopLevelRoutingIds,
    this.cachedImbalance,
    this.cachedNLeaves,
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
// NGH v2 paged centroid + posting directory (TPG2 payloads)
// ============================================================================

/// One TPG2 page of v2 centroid records (no inlined posting page lists).
final class NghNavCentroidPage {
  static const int magic = 0x3256434E; // 'NCV2'
  static const int payloadVersion = 1;

  final int dimensions;
  final List<NghNavCentroidNode> centroids;

  NghNavCentroidPage({
    required this.dimensions,
    required this.centroids,
  });

  static int recordSize(int dimensions, int neighborCount, int childCount) {
    return 58 + neighborCount * 4 + childCount * 4 + dimensions * 4;
  }

  int estimatePayloadSize({int pageSize = 16 * 1024}) {
    var total = 12;
    final maxChildren = NghPageSizer.maxNavInlineChildren(pageSize, dimensions);
    for (final c in centroids) {
      total += recordSize(
        dimensions,
        c.neighbors.length > NghPageSizer.maxNavNeighbors
            ? NghPageSizer.maxNavNeighbors
            : c.neighbors.length,
        c.childIds.length > maxChildren ? maxChildren : c.childIds.length,
      );
    }
    return total;
  }

  Uint8List encodePayload({int pageSize = 16 * 1024}) {
    final total = estimatePayloadSize(pageSize: pageSize);
    final maxChildren = NghPageSizer.maxNavInlineChildren(pageSize, dimensions);
    final buf = Uint8List(total);
    final bd = ByteData.sublistView(buf);
    bd.setUint32(0, magic, Endian.little);
    bd.setUint16(4, payloadVersion, Endian.little);
    bd.setUint16(6, dimensions, Endian.little);
    bd.setUint16(8, centroids.length, Endian.little);
    bd.setUint16(10, 0, Endian.little);
    int off = 12;
    for (final c in centroids) {
      bd.setUint32(off, c.centroidId, Endian.little);
      buf[off + 4] = c.level;
      buf[off + 5] = 0;
      bd.setUint32(off + 6, c.parentId < 0 ? NghPageId.noneWire : c.parentId,
          Endian.little);
      bd.setUint32(
          off + 10, c.entryCount < 0 ? 0 : c.entryCount, Endian.little);
      bd.setUint32(off + 14, c.postingDirRoot.wirePartition, Endian.little);
      bd.setUint32(off + 18, c.postingDirRoot.wirePage, Endian.little);
      bd.setUint32(off + 22, c.postingDirTail.wirePartition, Endian.little);
      bd.setUint32(off + 26, c.postingDirTail.wirePage, Endian.little);
      final head = NghPageId.fromPacked(c.headPostingPageNo);
      final tail = NghPageId.fromPacked(c.tailPostingPageNo);
      bd.setUint32(off + 30, head.wirePartition, Endian.little);
      bd.setUint32(off + 34, head.wirePage, Endian.little);
      bd.setUint32(off + 38, tail.wirePartition, Endian.little);
      bd.setUint32(off + 42, tail.wirePage, Endian.little);
      bd.setUint32(off + 46, c.childrenDirRoot.wirePartition, Endian.little);
      bd.setUint32(off + 50, c.childrenDirRoot.wirePage, Endian.little);
      off += 54;
      final nLen = c.neighbors.length > NghPageSizer.maxNavNeighbors
          ? NghPageSizer.maxNavNeighbors
          : c.neighbors.length;
      bd.setUint16(off, nLen, Endian.little);
      off += 2;
      for (int n = 0; n < nLen; n++) {
        bd.setUint32(off, c.neighbors[n], Endian.little);
        off += 4;
      }
      final cLen =
          c.childIds.length > maxChildren ? maxChildren : c.childIds.length;
      bd.setUint16(off, cLen, Endian.little);
      off += 2;
      for (int n = 0; n < cLen; n++) {
        bd.setUint32(off, c.childIds[n], Endian.little);
        off += 4;
      }
      for (int d = 0; d < dimensions; d++) {
        bd.setFloat32(
            off, d < c.vector.length ? c.vector[d] : 0.0, Endian.little);
        off += 4;
      }
    }
    return buf;
  }

  static NghNavCentroidPage? tryDecodePayload(Uint8List bytes) {
    if (bytes.length < 12) return null;
    final bd = ByteData.sublistView(bytes);
    if (bd.getUint32(0, Endian.little) != magic) return null;
    final ver = bd.getUint16(4, Endian.little);
    if (ver <= 0) return null;
    final dims = bd.getUint16(6, Endian.little);
    final count = bd.getUint16(8, Endian.little);
    if (dims == 0) return null;
    int off = 12;
    final list = <NghNavCentroidNode>[];
    for (int i = 0; i < count; i++) {
      if (off + 54 + 4 > bytes.length) break;
      final cId = bd.getUint32(off, Endian.little);
      final level = bytes[off + 4];
      final parentRaw = bd.getUint32(off + 6, Endian.little);
      final entries = bd.getUint32(off + 10, Endian.little);
      final pdirRoot = NghPageId.fromWire(bd.getUint32(off + 14, Endian.little),
          bd.getUint32(off + 18, Endian.little));
      final pdirTail = NghPageId.fromWire(bd.getUint32(off + 22, Endian.little),
          bd.getUint32(off + 26, Endian.little));
      final head = NghPageId.fromWire(bd.getUint32(off + 30, Endian.little),
          bd.getUint32(off + 34, Endian.little));
      final tail = NghPageId.fromWire(bd.getUint32(off + 38, Endian.little),
          bd.getUint32(off + 42, Endian.little));
      final childDir = NghPageId.fromWire(bd.getUint32(off + 46, Endian.little),
          bd.getUint32(off + 50, Endian.little));
      off += 54;
      if (off + 2 > bytes.length) break;
      final nLen = bd.getUint16(off, Endian.little);
      off += 2;
      if (off + nLen * 4 + 2 > bytes.length) break;
      final neighbors = <int>[];
      for (int n = 0; n < nLen; n++) {
        neighbors.add(bd.getUint32(off, Endian.little));
        off += 4;
      }
      final cLen = bd.getUint16(off, Endian.little);
      off += 2;
      if (off + cLen * 4 + dims * 4 > bytes.length) break;
      final children = <int>[];
      for (int n = 0; n < cLen; n++) {
        children.add(bd.getUint32(off, Endian.little));
        off += 4;
      }
      final vec = Float32List(dims);
      for (int d = 0; d < dims; d++) {
        vec[d] = bd.getFloat32(off, Endian.little);
        off += 4;
      }
      list.add(NghNavCentroidNode(
        centroidId: cId,
        vector: vec,
        headPostingPageNo: head.tryPack() ?? -1,
        tailPostingPageNo: tail.tryPack() ?? -1,
        entryCount: entries,
        neighbors: neighbors,
        postingPages: <NghPageId>[],
        level: level,
        parentId: parentRaw == NghPageId.noneWire ? -1 : parentRaw,
        postingDirRoot: pdirRoot,
        postingDirTail: pdirTail,
        childrenDirRoot: childDir,
        childIds: children,
      ));
    }
    return NghNavCentroidPage(dimensions: dims, centroids: list);
  }
}

/// Linked directory of posting [NghPageId]s for one leaf centroid.
final class NghPostingDirPage {
  static const int magic = 0x32564450; // 'PDV2'
  static const int headerSize = 20;

  final int centroidId;
  NghPageId next;
  final List<NghPageId> pages;

  NghPostingDirPage({
    required this.centroidId,
    this.next = NghPageId.none,
    List<NghPageId>? pages,
  }) : pages = pages ?? <NghPageId>[];

  static int maxEntriesForPage(int pageSize) {
    final usable =
        pageSize - BTreePageHeader.size - NghPageSizer.encodingSafetyMargin;
    final body = usable - headerSize;
    return body > 8 ? body ~/ 8 : 1;
  }

  Uint8List encodePayload() {
    final buf = Uint8List(headerSize + pages.length * 8);
    final bd = ByteData.sublistView(buf);
    bd.setUint32(0, magic, Endian.little);
    bd.setUint32(4, centroidId, Endian.little);
    bd.setUint32(8, next.wirePartition, Endian.little);
    bd.setUint32(12, next.wirePage, Endian.little);
    bd.setUint16(16, pages.length, Endian.little);
    bd.setUint16(18, 0, Endian.little);
    int off = headerSize;
    for (final p in pages) {
      bd.setUint32(off, p.wirePartition, Endian.little);
      bd.setUint32(off + 4, p.wirePage, Endian.little);
      off += 8;
    }
    return buf;
  }

  static NghPostingDirPage? tryDecodePayload(Uint8List bytes) {
    if (bytes.length < headerSize) return null;
    final bd = ByteData.sublistView(bytes);
    if (bd.getUint32(0, Endian.little) != magic) return null;
    final cId = bd.getUint32(4, Endian.little);
    final next = NghPageId.fromWire(
        bd.getUint32(8, Endian.little), bd.getUint32(12, Endian.little));
    final count = bd.getUint16(16, Endian.little);
    int off = headerSize;
    final pages = <NghPageId>[];
    for (int i = 0; i < count; i++) {
      if (off + 8 > bytes.length) break;
      pages.add(NghPageId.fromWire(bd.getUint32(off, Endian.little),
          bd.getUint32(off + 4, Endian.little)));
      off += 8;
    }
    return NghPostingDirPage(centroidId: cId, next: next, pages: pages);
  }
}

/// PK locator value: one or more (centroid, partition, page, slot) tuples.
final class NghPkLocator {
  final int centroidId;
  final int partitionNo;
  final int pageNo;
  final int slotIndex;

  const NghPkLocator({
    required this.centroidId,
    required this.partitionNo,
    required this.pageNo,
    required this.slotIndex,
  });

  NghPageId get pageId => NghPageId(partitionNo, pageNo);

  static Uint8List encodeList(List<NghPkLocator> locs) {
    final n = locs.length.clamp(0, 8);
    final buf = Uint8List(1 + n * 14);
    buf[0] = n;
    final bd = ByteData.sublistView(buf);
    int off = 1;
    for (int i = 0; i < n; i++) {
      final l = locs[i];
      bd.setUint32(off, l.centroidId, Endian.little);
      bd.setUint32(off + 4, l.partitionNo, Endian.little);
      bd.setUint32(off + 8, l.pageNo, Endian.little);
      bd.setUint16(off + 12, l.slotIndex, Endian.little);
      off += 14;
    }
    return buf;
  }

  static List<NghPkLocator> decodeList(Uint8List bytes) {
    if (bytes.isEmpty) return const [];
    final n = bytes[0];
    final bd = ByteData.sublistView(bytes);
    int off = 1;
    final out = <NghPkLocator>[];
    for (int i = 0; i < n; i++) {
      if (off + 14 > bytes.length) break;
      out.add(NghPkLocator(
        centroidId: bd.getUint32(off, Endian.little),
        partitionNo: bd.getUint32(off + 4, Endian.little),
        pageNo: bd.getUint32(off + 8, Endian.little),
        slotIndex: bd.getUint16(off + 12, Endian.little),
      ));
      off += 14;
    }
    return out;
  }
}

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

  /// Bytes reserved besides the centroid records: TPG2 header, page payload
  /// header, encoder/AEAD slack, and [BTreePageSizer] 128-byte flush margin.
  static const int navPagePackReserve =
      pageHeaderSize + 12 + encodingSafetyMargin + 128 + 48;

  /// Neighbor cap used by insert splits and nav packing.
  static const int maxNavNeighbors = 16;

  /// How many v2 centroid records fit on one TPG2 page.
  ///
  /// Must assume **max** neighbors and inline children. Packing with
  /// `childCount=4` overflowed at ~1M vectors once coarses held 100+ children
  /// (`payload=17082 > 16384-20`).
  static int navCentroidsPerPage(int pageSize, int dimensions) {
    final maxChildren = maxNavInlineChildren(pageSize, dimensions);
    final rec =
        NghNavCentroidPage.recordSize(dimensions, maxNavNeighbors, maxChildren);
    final usable = pageSize - navPagePackReserve;
    if (rec <= 0 || usable < rec) return 1;
    return (usable ~/ rec).clamp(1, 256);
  }

  /// Max inline child ids on one coarse so the nav record still fits a page.
  ///
  ///   16384 coarses × 256 leaves × ~4k vectors/leaf ≈ 17B at two levels; three
  /// levels at 256^3 × ~4k ≈ 68B. Larger child lists belong in `childrenDirRoot`.
  static int maxNavInlineChildren(int pageSize, int dimensions) {
    final usable = pageSize - navPagePackReserve;
    final base = NghNavCentroidPage.recordSize(dimensions, maxNavNeighbors, 0);
    if (usable <= base + 4) return 8;
    return ((usable - base) ~/ 4).clamp(8, 256);
  }

  /// Drop out-of-range parent/child/neighbor ids and clamp inline lists so a
  /// partial nav redo cannot `RangeError` on `centroids[id]`.
  static void sanitizeNavGraph(
    List<NghNavCentroidNode> centroids, {
    required int pageSize,
    int? dimensions,
  }) {
    final n = centroids.length;
    if (n == 0) return;
    final dims = dimensions ?? centroids.first.vector.length;
    final maxChildren = maxNavInlineChildren(pageSize, dims);
    for (final c in centroids) {
      if (c.parentId < -1 || c.parentId >= n) {
        c.parentId = -1;
      }
      c.childIds.removeWhere((id) => id < 0 || id >= n);
      if (c.childIds.length > maxChildren) {
        c.childIds.removeRange(maxChildren, c.childIds.length);
      }
      c.neighbors.removeWhere((id) => id < 0 || id >= n);
      if (c.neighbors.length > maxNavNeighbors) {
        c.neighbors.removeRange(maxNavNeighbors, c.neighbors.length);
      }
    }
  }
}
