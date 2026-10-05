import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../handler/common.dart';
import '../handler/platform_byte_data.dart';
import '../model/db_exception.dart';
import '../model/ngh_index_meta.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import 'btree_page.dart';
import 'vector_quantizer.dart';

// ============================================================================
// NGH Page Structures
//
// All pages reuse BTreePageHeader (20-byte header with magic/CRC/type/flags)
// and BTreePageIO for encoding/decoding.
//
// Page types:
//   nghMeta -- per-partition-file metadata (pageNo=0)
//   nghLeaf -- physical vector-leaf page with inlined SQ8 slots
//   nghNav  -- hierarchical nav (root table or nav B+Tree page)
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
// NGH Physical Leaf Page
// ============================================================================

/// Inlined SQ8 compressed vector entry with metadata inside a physical vector leaf page.
final class NghLeafSlot {
  /// Tombstone bit (logical delete).
  static const int flagDeleted = 0x01;

  /// Unique vector node/document ID (Dart [int]; wire may be u32 or u64).
  int nodeId;

  /// Slot flags: [flagDeleted], …
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

  /// Cached 48-d SIMD view for Level 2A coarse scoring
  Float32List? low48D;
  Float32x4List? low48DSimd;

  NghLeafSlot({
    required this.nodeId,
    this.flags = 0,
    String? primaryKey,
    this.primaryKeyBytes,
    required this.sq8Codes,
    required this.offset,
    required this.scale,
    required this.squaredNorm,
    this.low48D,
  }) : _decodedPrimaryKey = primaryKey {
    if (low48D != null) {
      low48DSimd = Float32x4List.sublistView(low48D!);
    }
  }

  Float32x4List getLow48DSimd(int dimensions) {
    if (low48DSimd != null) return low48DSimd!;
    final low = Float32List(48);
    final dims = dimensions < 1 ? sq8Codes.length : dimensions;
    final n = min(dims, sq8Codes.length);
    if (n <= 48) {
      double norm = 0.0;
      for (int d = 0; d < n; d++) {
        final val = offset + sq8Codes[d] * scale;
        low[d] = val;
        norm += val * val;
      }
      if (norm > 0) {
        final inv = 1.0 / sqrt(norm);
        for (int d = 0; d < n; d++) {
          low[d] *= inv;
        }
      }
    } else {
      // Match NghGraphEngine._extractLow48Into: fold SQ8 dims into 48 bins.
      // Chunked path avoids per-element modulo (materialize / cold-page cost).
      for (int i = 0; i < 48; i++) {
        low[i] = 0.0;
      }
      final fullChunks = n - (n % 48);
      var d = 0;
      while (d < fullChunks) {
        for (int i = 0; i < 48; i++) {
          low[i] += offset + sq8Codes[d + i] * scale;
        }
        d += 48;
      }
      while (d < n) {
        low[d - fullChunks] += offset + sq8Codes[d] * scale;
        d++;
      }
      double norm = 0.0;
      for (int i = 0; i < 48; i++) {
        norm += low[i] * low[i];
      }
      if (norm > 0) {
        final inv = 1.0 / sqrt(norm);
        for (int i = 0; i < 48; i++) {
          low[i] *= inv;
        }
      }
    }
    low48D = low;
    low48DSimd = Float32x4List.sublistView(low);
    return low48DSimd!;
  }

  Float32List getLow48D(int dimensions) {
    if (low48D != null) return low48D!;
    getLow48DSimd(dimensions);
    return low48D!;
  }

  /// True when Level-2A 48-D view is already resident (no SQ8 rebuild).
  bool get hasLow48 => low48DSimd != null;

  /// Original string primary key (decoded on demand for disk-loaded slots).
  String get primaryKey {
    final cached = _decodedPrimaryKey;
    if (cached != null) return cached;
    final bytes = primaryKeyBytes;
    if (bytes == null || bytes.isEmpty) return '';
    return _decodedPrimaryKey = utf8.decode(bytes);
  }

  /// Already-decoded PK if resident (search emit — avoids utf8.decode).
  String? get cachedPrimaryKey => _decodedPrimaryKey;

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

  bool get isDeleted => (flags & flagDeleted) != 0;

  /// Approximate in-memory / serialized byte size of this slot.
  int estimateSize() {
    final pkLen = primaryKeyBytes?.length ?? (primaryKey.length * 2);
    final idBytes = nodeId > NghLeafPage.maxCompactNodeId ? 8 : 4;
    return 16 + idBytes + pkLen + sq8Codes.length;
  }
}

/// A physical vector leaf page storing multiple inlined [NghLeafSlot]s.
final class NghLeafPage {
  /// Max nodeId that fits the legacy compact (u32) slot wire.
  static const int maxCompactNodeId = 0xFFFFFFFF;

  /// High bit of the u16 slotCount word: page uses u64 nodeId on every slot.
  /// Untouched legacy pages never set this bit — decode stays u32-compatible.
  static const int slotCountWideNodeIdFlag = 0x8000;

  /// Bit14 of slotCount: advisory — next uses wide u32+u32 extension after the
  /// 12-byte header (authoritative marker is [wideNextSentinel] at offset 4).
  static const int slotCountWideNextFlag = 0x4000;

  /// i32 next field value meaning "u32 partition + u32 page follow at offset 12".
  static const int wideNextSentinel = -2;

  static const int _slotCountFlagMask =
      slotCountWideNodeIdFlag | slotCountWideNextFlag;

  /// Max live slots when both wide flags are reserved in the count word.
  static const int maxSlotCount = 0x3FFF; // 16383

  /// Fixed bytes after nodeId on wire: flags + 3×f32 + pkLen.
  static const int _slotTailFixedBytes = 15; // 1+4+4+4+2

  /// Owning nav centroid ID.
  final int centroidId;

  /// Next chained leaf page (none = end of chain).
  ///
  /// Wire: legacy pages store packed i32 at offset 4; when [needsWideNext],
  /// offset 4 holds [wideNextSentinel] and u32+u32 follow before slots
  /// (partition ≥2048 / pageNo ≥2^20 safe). Dims/count stay at offsets 8/10.
  NghPageId nextLeafPage;

  /// Legacy packed-int view of [nextLeafPage] (tryPack, or -1 if none/unrepresentable).
  /// Prefer reading/writing [nextLeafPage] for partition ≥2048.
  int get nextLeafPageNo {
    if (nextLeafPage.isNone) return -1;
    return nextLeafPage.tryPack() ?? -1;
  }

  set nextLeafPageNo(int packed) {
    final next = packed <= 0 ? NghPageId.none : NghPageId.fromPacked(packed);
    _setNextLeafPage(next);
  }

  /// Vector dimensionality.
  final int dimensions;

  /// List of vector entries stored in this page.
  ///
  /// Prefer [addSlot] / [replaceSlots] for mutations so layout/centroid caches
  /// stay coherent. Direct list edits must call [invalidateCaches].
  final List<NghLeafSlot> slots;

  /// Cached [needsWideNodeIds]; null = unknown.
  bool? _wideCache;

  /// Cached [estimatePayloadSize]; null = unknown.
  int? _payloadCache;

  /// Running sum of slot low48 (unnormalized); null = unknown.
  Float32List? _sum48;

  /// Cached [needsWideNext]; null = unknown.
  bool? _wideNextCache;

  /// Contiguous live-slot 48-D SIMD rows for L2A (12 Float32x4 per slot).
  /// Same values as per-slot [NghLeafSlot.low48DSimd]; layout only.
  Float32x4List? _search48Simd;

  /// Live (non-tombstone) slots parallel to [_search48Simd] rows.
  List<NghLeafSlot>? _searchLiveSlots;

  NghLeafPage({
    required this.centroidId,
    NghPageId? nextLeafPage,
    int nextLeafPageNo = -1,
    required this.dimensions,
    required this.slots,
  }) : nextLeafPage = nextLeafPage ??
            (nextLeafPageNo <= 0
                ? NghPageId.none
                : NghPageId.fromPacked(nextLeafPageNo));

  /// Create an empty leaf page for a nav centroid.
  factory NghLeafPage.empty({
    required int centroidId,
    required int dimensions,
  }) {
    return NghLeafPage(
      centroidId: centroidId,
      dimensions: dimensions,
      slots: [],
    )
      .._wideCache = false
      .._wideNextCache = false
      .._payloadCache = 12
      .._sum48 = Float32List(48);
  }

  /// Drop layout + centroid-sum caches (call after raw [slots] mutation).
  void invalidateCaches() {
    _wideCache = null;
    _wideNextCache = null;
    _payloadCache = null;
    _sum48 = null;
    _clearSearch48Pack();
  }

  void _clearSearch48Pack() {
    _search48Simd = null;
    _searchLiveSlots = null;
  }

  /// Soft-delete [slot] and drop search/nav summaries that included it.
  ///
  /// Wire payload still contains the tombstone (slot stays on the page).
  /// [_sum48] is dropped (not incrementally subtracted) so the next
  /// [normalizedMean48] rebuilds over live slots only.
  void markSlotDeleted(NghLeafSlot slot) {
    if ((slot.flags & NghLeafSlot.flagDeleted) != 0) return;
    slot.flags |= NghLeafSlot.flagDeleted;
    _clearSearch48Pack();
    _sum48 = null;
  }

  /// Packed L2A 48-D rows (null until [ensureLow48Ready]).
  Float32x4List? get searchLow48Simd => _search48Simd;

  /// Live slots aligned with [searchLow48Simd] (null until [ensureLow48Ready]).
  List<NghLeafSlot>? get searchLiveSlots => _searchLiveSlots;

  void _setNextLeafPage(NghPageId next) {
    if (next == nextLeafPage) return;
    final prevWideNext = needsWideNext;
    nextLeafPage = next;
    _wideNextCache = null;
    if (prevWideNext != needsWideNext) {
      _payloadCache = null;
    }
  }

  /// Assign next chain pointer (invalidates payload cache if header width changes).
  void setNextLeafPage(NghPageId next) => _setNextLeafPage(next);

  /// True when next cannot fit legacy i32 pack (or already encoded wide).
  bool get needsWideNext {
    final cached = _wideNextCache;
    if (cached != null) return cached;
    if (nextLeafPage.isNone) return _wideNextCache = false;
    return _wideNextCache = nextLeafPage.tryPack() == null;
  }

  static int headerBytes({required bool wideNext}) => wideNext ? 20 : 12;

  /// True when any slot needs u64 nodeId (page must encode in wide mode).
  bool get needsWideNodeIds {
    final cached = _wideCache;
    if (cached != null) return cached;
    for (final s in slots) {
      if (s.nodeId > maxCompactNodeId) {
        return _wideCache = true;
      }
    }
    return _wideCache = false;
  }

  /// Wire bytes for one slot's fixed header (nodeId + tail), given page mode.
  static int slotFixedHeaderBytes({required bool wideNodeIds}) =>
      (wideNodeIds ? 8 : 4) + _slotTailFixedBytes;

  int _slotPkLen(NghLeafSlot s) => s.primaryKeyUtf8.length;

  /// Append one slot and keep wide/payload/sum caches incremental (O(1) / O(48)).
  void addSlot(NghLeafSlot slot) {
    final pkLen = _slotPkLen(slot);
    final wasWide = needsWideNodeIds;
    final becomesWide = !wasWide && slot.nodeId > maxCompactNodeId;
    if (becomesWide) {
      // Compact→wide: every existing slot gains 4 header bytes.
      final prev = _payloadCache ?? estimatePayloadSize();
      slots.add(slot);
      _wideCache = true;
      _payloadCache = prev +
          (slots.length - 1) * 4 +
          slotFixedHeaderBytes(wideNodeIds: true) +
          pkLen +
          dimensions;
    } else {
      final prev = _payloadCache ?? estimatePayloadSize();
      slots.add(slot);
      // wasWide already true, or slot is compact — wide flag unchanged unless
      // slot itself is wide (only reachable when wasWide).
      if (slot.nodeId > maxCompactNodeId) _wideCache = true;
      _payloadCache = prev +
          slotFixedHeaderBytes(wideNodeIds: wasWide) +
          pkLen +
          dimensions;
    }
    _addToSum48(slot);
    _clearSearch48Pack();
  }

  /// Pop the last slot; reverses sum when warm, drops layout caches (wide may
  /// have been solely due to the removed slot).
  void removeLastSlot() {
    if (slots.isEmpty) return;
    final last = slots.removeLast();
    if (_sum48 != null && (last.flags & NghLeafSlot.flagDeleted) == 0) {
      final low = last.getLow48D(48);
      final sum = _sum48!;
      for (int d = 0; d < 48; d++) {
        sum[d] -= low[d];
      }
    }
    _wideCache = null;
    _payloadCache = null;
    _clearSearch48Pack();
  }

  /// Replace all slots (split / rebuild); rebuilds caches in one pass.
  void replaceSlots(List<NghLeafSlot> next) {
    if (identical(next, slots)) {
      _rebuildCachesFromSlots();
      return;
    }
    slots
      ..clear()
      ..addAll(next);
    _rebuildCachesFromSlots();
  }

  void _rebuildCachesFromSlots() {
    var wide = false;
    final wideNext = needsWideNext;
    var payload = headerBytes(wideNext: wideNext);
    final sum = Float32List(48);
    for (final s in slots) {
      if (s.nodeId > maxCompactNodeId) wide = true;
      final pkLen = _slotPkLen(s);
      // Header width depends on final page mode — second pass avoided by
      // accumulating compact first then adding upgrade if wide.
      payload += slotFixedHeaderBytes(wideNodeIds: false) + pkLen + dimensions;
      if ((s.flags & NghLeafSlot.flagDeleted) != 0) continue;
      final low = s.getLow48D(48);
      for (int d = 0; d < 48; d++) {
        sum[d] += low[d];
      }
    }
    if (wide) payload += slots.length * 4;
    _wideCache = wide;
    _payloadCache = payload;
    _sum48 = sum;
    _clearSearch48Pack();
  }

  void _ensureSum48() {
    if (_sum48 != null) return;
    final sum = Float32List(48);
    for (final s in slots) {
      if ((s.flags & NghLeafSlot.flagDeleted) != 0) continue;
      final low = s.getLow48D(48);
      for (int d = 0; d < 48; d++) {
        sum[d] += low[d];
      }
    }
    _sum48 = sum;
  }

  void _addToSum48(NghLeafSlot slot) {
    if ((slot.flags & NghLeafSlot.flagDeleted) != 0) return;
    _ensureSum48();
    final sum = _sum48!;
    final low = slot.getLow48D(48);
    for (int d = 0; d < 48; d++) {
      sum[d] += low[d];
    }
  }

  int get _liveSlotCount {
    var n = 0;
    for (final s in slots) {
      if ((s.flags & NghLeafSlot.flagDeleted) == 0) n++;
    }
    return n;
  }

  /// Live (non-tombstone) slot count.
  int get liveSlotCount => _liveSlotCount;

  /// L2-normalized arithmetic mean of **live** slot low48 (tombstones excluded).
  Float32List normalizedMean48() {
    final count = _liveSlotCount;
    final mean = Float32List(48);
    if (count == 0) return mean;
    _ensureSum48();
    final sum = _sum48!;
    double norm = 0.0;
    final inv = 1.0 / count;
    for (int d = 0; d < 48; d++) {
      final v = sum[d] * inv;
      mean[d] = v;
      norm += v * v;
    }
    norm = sqrt(norm);
    if (norm > 0) {
      final scale = 1.0 / norm;
      for (int d = 0; d < 48; d++) {
        mean[d] *= scale;
      }
    }
    return mean;
  }

  /// Extra payload bytes if [addingNodeId] forces a compact→wide page upgrade.
  int wideUpgradeCostBytes(int addingNodeId) {
    if (addingNodeId <= maxCompactNodeId || needsWideNodeIds) return 0;
    return slots.length * 4;
  }

  /// Encode leaf page payload.
  ///
  /// Base header (offsets fixed for legacy readers):
  ///   [centroidId: u32][next: i32][dimensions: u16][slotCount: u16]
  ///   next = packed ref | -1 (none) | [wideNextSentinel] (−2)
  /// When next == [wideNextSentinel]:
  ///   [nextPart: u32][nextPage: u32] then slots (total header 20 bytes)
  /// slotCount bit15 = wide nodeId; bit14 = advisory wide-next flag.
  ///
  /// Untouched legacy pages stay compact forever. Only dirty pages that need
  /// wide nodeId and/or wide next rewrite that page (no full-index rewrite).
  Uint8List encodePayload() {
    final slotCount = slots.length;
    if (slotCount > maxSlotCount) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'NghLeafPage slotCount overflow: $slotCount > $maxSlotCount',
        )
      ]);
    }
    final wide = needsWideNodeIds;
    final wideNext = needsWideNext;
    final fixed = slotFixedHeaderBytes(wideNodeIds: wide);
    final hdr = headerBytes(wideNext: wideNext);
    int totalBytes = hdr;

    final pks =
        List<Uint8List>.filled(slotCount, Uint8List(0), growable: false);
    for (int i = 0; i < slotCount; i++) {
      final pkBytes = slots[i].primaryKeyUtf8;
      pks[i] = pkBytes;
      totalBytes += fixed + pkBytes.length + dimensions;
    }

    final buf = Uint8List(totalBytes);
    final bd = ByteData.sublistView(buf);

    bd.setUint32(0, centroidId, Endian.little);
    var flags = 0;
    if (wide) flags |= slotCountWideNodeIdFlag;
    if (wideNext) flags |= slotCountWideNextFlag;
    if (wideNext) {
      bd.setInt32(4, wideNextSentinel, Endian.little);
      bd.setUint16(8, dimensions, Endian.little);
      bd.setUint16(10, slotCount | flags, Endian.little);
      bd.setUint32(12, nextLeafPage.wirePartition, Endian.little);
      bd.setUint32(16, nextLeafPage.wirePage, Endian.little);
    } else {
      final packed = nextLeafPage.isNone ? -1 : (nextLeafPage.tryPack() ?? -1);
      bd.setInt32(4, packed, Endian.little);
      bd.setUint16(8, dimensions, Endian.little);
      bd.setUint16(10, slotCount | flags, Endian.little);
    }

    int off = hdr;
    for (int i = 0; i < slotCount; i++) {
      final slot = slots[i];
      final pkBytes = pks[i];

      if (wide) {
        PlatformByteData.setUint64(bd, off, slot.nodeId, Endian.little);
        buf[off + 8] = slot.flags;
        bd.setFloat32(off + 9, slot.offset, Endian.little);
        bd.setFloat32(off + 13, slot.scale, Endian.little);
        bd.setFloat32(off + 17, slot.squaredNorm, Endian.little);
        bd.setUint16(off + 21, pkBytes.length, Endian.little);
        off += 23;
      } else {
        bd.setUint32(off, slot.nodeId, Endian.little);
        buf[off + 4] = slot.flags;
        bd.setFloat32(off + 5, slot.offset, Endian.little);
        bd.setFloat32(off + 9, slot.scale, Endian.little);
        bd.setFloat32(off + 13, slot.squaredNorm, Endian.little);
        bd.setUint16(off + 17, pkBytes.length, Endian.little);
        off += 19;
      }

      buf.setRange(off, off + pkBytes.length, pkBytes);
      off += pkBytes.length;

      buf.setRange(off, off + dimensions, slot.sq8Codes);
      off += dimensions;
    }

    return buf;
  }

  /// Decode leaf page payload (compact/wide nodeId + compact/wide next).
  static NghLeafPage? tryDecodePayload(Uint8List bytes) {
    if (bytes.length < 12) return null;
    final bd = ByteData.sublistView(bytes);

    final cId = bd.getUint32(0, Endian.little);
    final nextRaw = bd.getInt32(4, Endian.little);
    final dims = bd.getUint16(8, Endian.little);
    final countWord = bd.getUint16(10, Endian.little);
    final wide = (countWord & slotCountWideNodeIdFlag) != 0;
    final wideNext = nextRaw == wideNextSentinel;
    final count = countWord & ~_slotCountFlagMask;

    if (dims == 0) return null;

    final NghPageId nextId;
    final int off0;
    if (wideNext) {
      if (bytes.length < 20) return null;
      nextId = NghPageId.fromWire(
        bd.getUint32(12, Endian.little),
        bd.getUint32(16, Endian.little),
      );
      off0 = 20;
    } else {
      nextId = NghPageId.fromPacked(nextRaw);
      off0 = 12;
    }

    final fixed = slotFixedHeaderBytes(wideNodeIds: wide);
    int off = off0;
    final slots = <NghLeafSlot>[];

    for (int i = 0; i < count; i++) {
      if (off + fixed > bytes.length) break;
      final int nodeId;
      final int flags;
      final double offset;
      final double scale;
      final double sqNorm;
      final int pkLen;
      if (wide) {
        nodeId = PlatformByteData.getUint64(bd, off, Endian.little);
        flags = bytes[off + 8];
        offset = bd.getFloat32(off + 9, Endian.little);
        scale = bd.getFloat32(off + 13, Endian.little);
        sqNorm = bd.getFloat32(off + 17, Endian.little);
        pkLen = bd.getUint16(off + 21, Endian.little);
        off += 23;
      } else {
        nodeId = bd.getUint32(off, Endian.little);
        flags = bytes[off + 4];
        offset = bd.getFloat32(off + 5, Endian.little);
        scale = bd.getFloat32(off + 9, Endian.little);
        sqNorm = bd.getFloat32(off + 13, Endian.little);
        pkLen = bd.getUint16(off + 17, Endian.little);
        off += 19;
      }

      if (off + pkLen + dims > bytes.length) break;

      final pkBytes = Uint8List.sublistView(bytes, off, off + pkLen);
      off += pkLen;

      final sq8Codes = Uint8List.sublistView(bytes, off, off + dims);
      off += dims;

      slots.add(NghLeafSlot(
        nodeId: nodeId,
        flags: flags,
        primaryKeyBytes: pkBytes,
        sq8Codes: sq8Codes,
        offset: offset,
        scale: scale,
        squaredNorm: sqNorm,
      ));
    }

    final page = NghLeafPage(
      centroidId: cId,
      nextLeafPage: nextId,
      dimensions: dims,
      slots: slots,
    );
    page._wideCache = wide;
    page._wideNextCache = wideNext && !nextId.isNone;
    if (slots.length == count) {
      page._payloadCache = bytes.length;
    }
    page.ensureLow48Ready();
    return page;
  }

  /// Build normalized 48-D SIMD views for every live slot (no-op if already warm).
  /// Also materializes UTF-8 PK bytes so search emit never utf8.encodes per query.
  /// Rebuilds packed L2A rows only after [_clearSearch48Pack] (never by live count).
  void ensureLow48Ready() {
    for (final s in slots) {
      if ((s.flags & NghLeafSlot.flagDeleted) != 0) continue;
      if (s.primaryKeyBytes == null) {
        final pk = s.cachedPrimaryKey;
        if (pk != null) {
          s.primaryKeyBytes =
              pk.isEmpty ? Uint8List(0) : Uint8List.fromList(utf8.encode(pk));
        }
      }
      if (s.hasLow48) continue;
      s.getLow48DSimd(dimensions);
    }
    if (_search48Simd == null || _searchLiveSlots == null) {
      _rebuildSearch48Pack();
    }
  }

  void _rebuildSearch48Pack() {
    final liveSlots = <NghLeafSlot>[];
    for (final s in slots) {
      if ((s.flags & NghLeafSlot.flagDeleted) != 0) continue;
      if (!s.hasLow48) {
        s.getLow48DSimd(dimensions);
      }
      liveSlots.add(s);
    }
    final live = liveSlots.length;
    if (live <= 0) {
      _search48Simd = Float32x4List(0);
      _searchLiveSlots = const <NghLeafSlot>[];
      return;
    }
    final packed = Float32List(live * 48);
    var row = 0;
    for (final s in liveSlots) {
      packed.setRange(row, row + 48, s.low48D!);
      row += 48;
    }
    _search48Simd = Float32x4List.sublistView(packed);
    _searchLiveSlots = liveSlots;
  }

  /// Wire payload plus resident low48 scratch (~192 B/slot when materialized).
  int estimateResidentBytes() {
    var size = estimatePayloadSize() + 64;
    for (final s in slots) {
      if (s.hasLow48) size += 192;
    }
    final packed = _search48Simd;
    if (packed != null) size += packed.length * 16;
    return size;
  }

  int estimatePayloadSize() {
    final cached = _payloadCache;
    if (cached != null) return cached;
    final wide = needsWideNodeIds;
    final fixed = slotFixedHeaderBytes(wideNodeIds: wide);
    int size = headerBytes(wideNext: needsWideNext);
    for (final s in slots) {
      size += fixed + s.primaryKeyUtf8.length + dimensions;
    }
    return _payloadCache = size;
  }

  // ---------------------------------------------------------------------------
  // Page-redo: full page (low-D) vs structure+PK (mid/high-D)
  // ---------------------------------------------------------------------------

  /// Below/equal: leaf page redo stores full page bytes (cheap vs PK path).
  /// Above: redo stores centroid/next/nodeId/flags/PK only; recovery reloads
  /// vectors from the table and re-quantizes (avoids ~3× write amp at high-D).
  static const int fullPageRedoMaxDimensions = 64;

  /// Magic for compact leaf redo payloads embedded in [PageRedoPageRecord].
  static const int pkStructureRedoMagic = 0x4B50474E; // 'NGPK'

  static bool prefersPkStructureRedo(int dimensions) =>
      dimensions > fullPageRedoMaxDimensions;

  static bool isPkStructureRedoPayload(Uint8List bytes) {
    if (bytes.length < 4) return false;
    return ByteData.sublistView(bytes).getUint32(0, Endian.little) ==
        pkStructureRedoMagic;
  }

  /// Compact crash-redo body: page identity lives on the [PageRedoPageRecord];
  /// this payload keeps centroid, next pointer, and per-slot nodeId/flags/PK.
  Uint8List encodePkStructureRedoPayload() {
    final slotCount = slots.length;
    if (slotCount > maxSlotCount) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'NghLeafPage PK redo slotCount overflow: $slotCount > $maxSlotCount',
        )
      ]);
    }
    final pks = List<Uint8List>.generate(
      slotCount,
      (i) => slots[i].primaryKeyUtf8,
      growable: false,
    );
    var total =
        4 + 4 + 4 + 4 + 2 + 2; // magic+centroid+nextPart+nextPage+dims+count
    for (final pk in pks) {
      total += 8 + 1 + 2 + pk.length; // nodeId + flags + pkLen + pk
    }
    final buf = Uint8List(total);
    final bd = ByteData.sublistView(buf);
    bd.setUint32(0, pkStructureRedoMagic, Endian.little);
    bd.setUint32(4, centroidId, Endian.little);
    bd.setUint32(8, nextLeafPage.wirePartition, Endian.little);
    bd.setUint32(12, nextLeafPage.wirePage, Endian.little);
    bd.setUint16(16, dimensions, Endian.little);
    bd.setUint16(18, slotCount, Endian.little);
    var off = 20;
    for (int i = 0; i < slotCount; i++) {
      final s = slots[i];
      final pk = pks[i];
      PlatformByteData.setUint64(bd, off, s.nodeId, Endian.little);
      buf[off + 8] = s.flags;
      bd.setUint16(off + 9, pk.length, Endian.little);
      off += 11;
      buf.setRange(off, off + pk.length, pk);
      off += pk.length;
    }
    return buf;
  }

  /// Decode [encodePkStructureRedoPayload] body, or null if not NGPK / truncated.
  static ({
    int centroidId,
    NghPageId nextLeafPage,
    int dimensions,
    List<({int nodeId, int flags, Uint8List pkBytes})> slots,
  })? tryDecodePkStructureRedoPayload(Uint8List bytes) {
    if (!isPkStructureRedoPayload(bytes) || bytes.length < 20) return null;
    final bd = ByteData.sublistView(bytes);
    final centroidId = bd.getUint32(4, Endian.little);
    final next = NghPageId.fromWire(
      bd.getUint32(8, Endian.little),
      bd.getUint32(12, Endian.little),
    );
    final dims = bd.getUint16(16, Endian.little);
    final count = bd.getUint16(18, Endian.little);
    if (dims == 0 || count > maxSlotCount) return null;
    var off = 20;
    final slots = <({int nodeId, int flags, Uint8List pkBytes})>[];
    for (int i = 0; i < count; i++) {
      if (off + 11 > bytes.length) return null;
      final nodeId = PlatformByteData.getUint64(bd, off, Endian.little);
      final flags = bytes[off + 8];
      final pkLen = bd.getUint16(off + 9, Endian.little);
      off += 11;
      if (off + pkLen > bytes.length) return null;
      final pkBytes = Uint8List.sublistView(bytes, off, off + pkLen);
      off += pkLen;
      slots.add((nodeId: nodeId, flags: flags, pkBytes: pkBytes));
    }
    return (
      centroidId: centroidId,
      nextLeafPage: next,
      dimensions: dims,
      slots: slots,
    );
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

  /// Legacy i32 pack used inside v1 leaf `next` fields. Null if unrepresentable.
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

  /// Head leaf page packed ref (`partitionNo<<20|pageNo`), or -1.
  int headLeafPageNo;

  /// Tail leaf page packed ref (`partitionNo<<20|pageNo`), or -1.
  int tailLeafPageNo;

  /// Total number of active vectors belonging to this centroid.
  int entryCount;

  /// Out-degree and neighbor centroid IDs in the navigating graph.
  final List<int> neighbors;

  /// All physical vector leaf pages for this leaf-level centroid (v2 source of truth).
  final List<NghPageId> leafPages;

  /// Packed leaf-page refs for search batch I/O when they still fit in i32.
  List<int> get leafPageNos => [
        for (final p in leafPages)
          if (p.tryPack() != null) p.tryPack()!,
      ];

  /// 0 = coarse (no leaf pages, has children), 1 = leaf (owns leaf pages).
  int level;

  /// Parent coarse centroid, or -1.
  int parentId;

  /// Root / tail of the leaf-page directory chain.
  NghPageId leafDirRoot;
  NghPageId leafDirTail;

  /// Overflow children directory (inline [childIds] is preferred).
  NghPageId childrenDirRoot;

  /// Inline child centroid ids (hierarchical tree). Empty for flat leaves.
  final List<int> childIds;

  /// Directory pages need a flush (append or rewrite).
  bool leafDirDirty;

  /// True when [leafPages] is the full live list.
  bool leafPageListReady;

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
    this.headLeafPageNo = -1,
    this.tailLeafPageNo = -1,
    this.entryCount = 0,
    List<int>? neighbors,
    List<int>? leafPageNos,
    List<NghPageId>? leafPages,
    this.level = levelLeaf,
    this.parentId = -1,
    this.leafDirRoot = NghPageId.none,
    this.leafDirTail = NghPageId.none,
    this.childrenDirRoot = NghPageId.none,
    List<int>? childIds,
    this.leafDirDirty = false,
    this.leafPageListReady = false,
  })  : neighbors = List<int>.of(neighbors ?? const <int>[]),
        childIds = List<int>.of(childIds ?? const <int>[]),
        leafPages = List<NghPageId>.of(
          leafPages ??
              _pagesFromPacked(
                leafPageNos,
                headLeafPageNo,
                tailLeafPageNo,
              ),
        ) {
    if (!leafPageListReady) {
      leafPageListReady = this.leafPages.isNotEmpty;
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

  void addLeafPage(NghPageId id) {
    if (id.isNone) return;
    leafDirDirty = true;
    if (!leafPageListReady && !leafDirRoot.isNone) return;
    for (final e in leafPages) {
      if (e.partitionNo == id.partitionNo && e.pageNo == id.pageNo) return;
    }
    leafPages.add(id);
    if (leafDirRoot.isNone) leafPageListReady = true;
  }

  void replaceLeafPages(List<NghPageId> pages) {
    leafPages
      ..clear()
      ..addAll(pages);
    leafDirDirty = true;
    leafPageListReady = true;
  }

  void setHeadTailFromIds(NghPageId head, NghPageId tail) {
    headLeafPageNo = head.tryPack() ?? -1;
    tailLeafPageNo = tail.tryPack() ?? -1;
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
          c.leafPageNos.length * 4);
    }

    final buf = Uint8List(totalBytes);
    final bd = ByteData.sublistView(buf);

    bd.setUint16(0, dimensions, Endian.little);
    bd.setUint16(2, count, Endian.little);

    int off = 4;
    for (final c in centroids) {
      bd.setUint32(off, c.centroidId, Endian.little);
      bd.setInt32(off + 4, c.headLeafPageNo, Endian.little);
      bd.setInt32(off + 8, c.tailLeafPageNo, Endian.little);
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

      final pLen = c.leafPageNos.length;
      bd.setUint16(off, pLen, Endian.little);
      off += 2;

      for (int p = 0; p < pLen; p++) {
        bd.setInt32(off, c.leafPageNos[p], Endian.little);
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

      final leafPageNos = <int>[];
      if (off + 2 <= bytes.length) {
        final pLen = bd.getUint16(off, Endian.little);
        off += 2;
        if (off + pLen * 4 <= bytes.length) {
          for (int p = 0; p < pLen; p++) {
            leafPageNos.add(bd.getInt32(off, Endian.little));
            off += 4;
          }
        }
      }

      if (leafPageNos.isEmpty && headPg > 0) {
        leafPageNos.add(headPg);
        if (tailPg > 0 && tailPg != headPg) {
          leafPageNos.add(tailPg);
        }
      }

      list.add(NghNavCentroidNode(
        centroidId: cId,
        vector: vec,
        headLeafPageNo: headPg,
        tailLeafPageNo: tailPg,
        entryCount: countEntries,
        neighbors: neighbors,
        leafPageNos: leafPageNos,
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
// NGH v2 paged centroid + leaf directory (TPG2 payloads)
// ============================================================================

/// One TPG2 page of v2 centroid records (no inlined leaf page lists).
///
/// Disk vectors are SQ8 (payloadVersion >= 2). Memory still uses float32
/// ([NghNavCentroidNode.vector]) after dequantize. payloadVersion 1 is the
/// unreleased float32 layout and remains readable.
final class NghNavCentroidPage {
  static const int magic = 0x3256434E; // 'NCV2'
  static const int payloadVersionFloat32 = 1;
  static const int payloadVersionSq8 = 2;
  static const int payloadVersion = payloadVersionSq8;

  /// offset:f32 + scale:f32 + codes[D].
  static int sq8VectorBytes(int dimensions) => 8 + dimensions;

  final int dimensions;
  final List<NghNavCentroidNode> centroids;

  NghNavCentroidPage({
    required this.dimensions,
    required this.centroids,
  });

  static int recordSize(int dimensions, int neighborCount, int childCount) {
    return 58 + neighborCount * 4 + childCount * 4 + sq8VectorBytes(dimensions);
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
      bd.setUint32(off + 14, c.leafDirRoot.wirePartition, Endian.little);
      bd.setUint32(off + 18, c.leafDirRoot.wirePage, Endian.little);
      bd.setUint32(off + 22, c.leafDirTail.wirePartition, Endian.little);
      bd.setUint32(off + 26, c.leafDirTail.wirePage, Endian.little);
      final head = NghPageId.fromPacked(c.headLeafPageNo);
      final tail = NghPageId.fromPacked(c.tailLeafPageNo);
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
      final src = c.vector;
      final toQuantize =
          src.length == dimensions ? src : _paddedCentroid(src, dimensions);
      final sq8 = ScalarQuantizer.quantize(toQuantize);
      bd.setFloat32(off, sq8.offset, Endian.little);
      bd.setFloat32(off + 4, sq8.scale, Endian.little);
      off += 8;
      final codeLen =
          sq8.codes.length < dimensions ? sq8.codes.length : dimensions;
      if (codeLen > 0) {
        buf.setRange(off, off + codeLen, sq8.codes);
      }
      if (codeLen < dimensions) {
        buf.fillRange(off + codeLen, off + dimensions, 0);
      }
      off += dimensions;
    }
    return buf;
  }

  static Float32List _paddedCentroid(Float32List src, int dimensions) {
    final out = Float32List(dimensions);
    final n = src.length < dimensions ? src.length : dimensions;
    for (int i = 0; i < n; i++) {
      out[i] = src[i];
    }
    return out;
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
      final leafDirRootWire = NghPageId.fromWire(
          bd.getUint32(off + 14, Endian.little),
          bd.getUint32(off + 18, Endian.little));
      final leafDirTailWire = NghPageId.fromWire(
          bd.getUint32(off + 22, Endian.little),
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
      if (off + cLen * 4 > bytes.length) break;
      final children = <int>[];
      for (int n = 0; n < cLen; n++) {
        children.add(bd.getUint32(off, Endian.little));
        off += 4;
      }
      final Float32List vec;
      if (ver >= payloadVersionSq8) {
        if (off + 8 + dims > bytes.length) break;
        final qOff = bd.getFloat32(off, Endian.little);
        final qScale = bd.getFloat32(off + 4, Endian.little);
        off += 8;
        final codes = Uint8List.sublistView(bytes, off, off + dims);
        off += dims;
        vec = ScalarQuantizer.dequantize(codes, qOff, qScale);
      } else {
        if (off + dims * 4 > bytes.length) break;
        vec = Float32List(dims);
        for (int d = 0; d < dims; d++) {
          vec[d] = bd.getFloat32(off, Endian.little);
          off += 4;
        }
      }
      list.add(NghNavCentroidNode(
        centroidId: cId,
        vector: vec,
        headLeafPageNo: head.tryPack() ?? -1,
        tailLeafPageNo: tail.tryPack() ?? -1,
        entryCount: entries,
        neighbors: neighbors,
        leafPages: <NghPageId>[],
        level: level,
        parentId: parentRaw == NghPageId.noneWire ? -1 : parentRaw,
        leafDirRoot: leafDirRootWire,
        leafDirTail: leafDirTailWire,
        childrenDirRoot: childDir,
        childIds: children,
      ));
    }
    return NghNavCentroidPage(dimensions: dims, centroids: list);
  }
}

/// PK locator value: one or more (centroid, partition, page, slot) tuples.
final class NghPkLocator {
  /// Wire and writers share this cap (L0 dual-home × leaf dual-home × mid fork).
  static const int maxLocatorsPerPk = 8;

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
    final n = locs.length.clamp(0, maxLocatorsPerPk);
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

  /// Inclusive max vector width (leaf/nav `dimensions` fields are u16).
  static const int maxDimensions = InternalConfig.maxVectorDimensions;

  /// Largest TPG2 page we will choose for a high-D NGH index (1MB).
  static const int maxNghPageSize = 1024 * 1024;

  /// PK bytes reserved when choosing a leaf page size (typical keys).
  static const int leafSlotPkBudget = 256;

  /// Flush-time overhead matching [BTreePageSizer.fitsInPage] (128) plus
  /// encoder/AEAD slack so page-size choice stays valid with encryption on.
  static const int flushFitOverhead =
      pageHeaderSize + 128 + encodingSafetyMargin;

  /// Compute how many leaf slots can fit in one page for a given average PK length.
  ///
  /// Soft-caps occupancy at [searchCalibMaxSlotsPerPage] so low-D indexes
  /// (128D would otherwise pack ~99 vectors into 16KB) keep leaf fanout near
  /// the 768D search calibration (~20–32 slots/page). Otherwise L2A scans
  /// 5× more vectors per probed leaf and density hacks fight QPS vs recall.
  static const int searchCalibMaxSlotsPerPage = 32;

  static int estimateLeafSlotsPerPage(
    int pageSize,
    int dimensions, {
    int avgPkLength = 16,
  }) {
    final slotSize = 19 + avgPkLength + dimensions;
    final usable = pageSize - pageHeaderSize - 12 - encodingSafetyMargin;
    if (usable < slotSize) return 1;
    final fit = (usable ~/ slotSize).clamp(1, 1024);
    return min(fit, searchCalibMaxSlotsPerPage);
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
  ///
  /// Returns 1 when the page was sized for a single high-D centroid. Callers
  /// must choose [pageSize] via [chooseNavPageSize] so that 1 SQ8 record
  /// actually fits.
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

  /// Smallest power-of-two page size that can hold [minPlainPayload] after
  /// TPG2 header, 128-byte flush margin, and encoder/AEAD slack.
  static int choosePageSize(int minPlainPayload, int basePageSize) {
    var size = basePageSize > 0 ? basePageSize : InternalConfig.defaultPageSize;
    if (size < InternalConfig.defaultPageSize) {
      size = InternalConfig.defaultPageSize;
    }
    final need = minPlainPayload + flushFitOverhead;
    while (size < need && size < maxNghPageSize) {
      size *= 2;
    }
    if (size > maxNghPageSize) return maxNghPageSize;
    return size;
  }

  /// Page size for one inlined SQ8 leaf slot (frozen layout).
  static int chooseLeafPageSize(int dimensions, int basePageSize) {
    final dim = dimensions.clamp(1, maxDimensions);
    final payload = 12 + 19 + leafSlotPkBudget + dim;
    return choosePageSize(payload, basePageSize);
  }

  /// Page size for one SQ8 nav centroid (max neighbors + min children).
  ///
  /// Disk is SQ8 (1 byte/dim + offset/scale). 4096-d fits the database 16KB
  /// page; 65535-d needs ~128KB, same order as leaf pages.
  static int chooseNavPageSize(int dimensions, int basePageSize) {
    final dim = dimensions.clamp(1, maxDimensions);
    final payload = 12 + NghNavCentroidPage.recordSize(dim, maxNavNeighbors, 8);
    return choosePageSize(payload, basePageSize);
  }

  /// Assign leaf/nav page sizes for a new or still-empty index.
  ///
  /// Existing data pages freeze that category's size so on-disk offsets stay
  /// valid (no leaf rewrite). Empty nav may be resized -- the v2 nav
  /// format is unreleased.
  static NghIndexMeta ensureIndexPageSizes(
    NghIndexMeta meta,
    int basePageSize,
  ) {
    final needLeaf = chooseLeafPageSize(meta.dimensions, basePageSize);
    final needNav = chooseNavPageSize(meta.dimensions, basePageSize);
    final leafSize = meta.hasLeafData
        ? meta.leafPageSize
        : (needLeaf > basePageSize ? needLeaf : 0);
    final nav = meta.hasNavData
        ? meta.navPageSize
        : (needNav > basePageSize ? needNav : 0);
    if (leafSize == meta.leafPageSize && nav == meta.navPageSize) {
      return meta;
    }
    return meta.copyWith(leafPageSize: leafSize, navPageSize: nav);
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

// ============================================================================
// Centroid B+Tree Hardware SIMD Kernels (Pure Dart, 0 FFI)
// ============================================================================

/// High-speed 48-d Hardware SIMD Inner Product (15 ns).
@pragma('vm:prefer-inline')
double innerProduct48(Float32x4List q, Float32x4List flat48, int base) {
  final acc0 = q[0] * flat48[base] +
      q[1] * flat48[base + 1] +
      q[2] * flat48[base + 2] +
      q[3] * flat48[base + 3];
  final acc1 = q[4] * flat48[base + 4] +
      q[5] * flat48[base + 5] +
      q[6] * flat48[base + 6] +
      q[7] * flat48[base + 7];
  final acc2 = q[8] * flat48[base + 8] +
      q[9] * flat48[base + 9] +
      q[10] * flat48[base + 10] +
      q[11] * flat48[base + 11];
  final acc = (acc0 + acc1) + acc2;
  return acc.x + acc.y + acc.z + acc.w;
}

/// Ultra-fast 48-d Hardware SIMD Inner Product with register preloading (0 memory reads for q).
@pragma('vm:prefer-inline')
double innerProduct48Reg(
  Float32x4 q0,
  Float32x4 q1,
  Float32x4 q2,
  Float32x4 q3,
  Float32x4 q4,
  Float32x4 q5,
  Float32x4 q6,
  Float32x4 q7,
  Float32x4 q8,
  Float32x4 q9,
  Float32x4 q10,
  Float32x4 q11,
  Float32x4List flat48,
  int base,
) {
  final acc0 = q0 * flat48[base] +
      q1 * flat48[base + 1] +
      q2 * flat48[base + 2] +
      q3 * flat48[base + 3];
  final acc1 = q4 * flat48[base + 4] +
      q5 * flat48[base + 5] +
      q6 * flat48[base + 6] +
      q7 * flat48[base + 7];
  final acc2 = q8 * flat48[base + 8] +
      q9 * flat48[base + 9] +
      q10 * flat48[base + 10] +
      q11 * flat48[base + 11];
  final acc = (acc0 + acc1) + acc2;
  return acc.x + acc.y + acc.z + acc.w;
}

// ============================================================================
// Centroid Navigation Tree (L0 root + fanout-bounded nav pages)
//
// LOCKED scale contract (tens of billions):
//   - Each nav page holds ≤64 children (one physical page = one tree node).
//   - Growth is SPLIT + optional mid promotion — never sibling linked lists.
//   - Leaf-level pages: entries.child → physical leaf page.
//   - Mid-level pages: entries.child → child nav page.
//   - Fanout 64 × 3 hops × ~4k slots/leaf ≫ tens of billions with bounded
//     probe cost: O(L0 + hops × 64 × beam), independent of corpus size N.
//
// Wire version = 2 (NGH/vector v2 not yet released). Do not bump to 3.
// Online production is still monolithic nav_graph.ngh — only that needs migrate.
// ============================================================================

/// Branch entry under a nav page: child is leaf OR child nav page.
final class CentroidBranchEntry {
  int centroidId;

  /// Physical leaf page when parent [NghNavBTreePage.isLeafLevel]; else child nav page.
  NghPageId childPageId;

  /// Leaf slot count (leaf-level) or approx child weight (mid-level).
  int childWeight;
  Float32List centroid48D;
  Float32x4List centroid48DSimd;

  CentroidBranchEntry({
    required this.centroidId,
    required NghPageId leafPageId,
    required int leafSlotCount,
    required this.centroid48D,
  })  : childPageId = leafPageId,
        childWeight = leafSlotCount,
        centroid48DSimd = Float32x4List.sublistView(centroid48D);

  /// Leaf-level alias — child is a leaf page.
  NghPageId get leafPageId => childPageId;
  set leafPageId(NghPageId v) => childPageId = v;

  int get leafSlotCount => childWeight;
  set leafSlotCount(int v) => childWeight = v;
}

/// Fanout-bounded nav node stored in `.nav` partitions.
///
/// One node = one page; [isLeafLevel] selects whether children are
/// physical leaf pages or child nav pages. Growth is split + mid promotion only.
final class NghNavBTreePage {
  static const int magic = 0x434E4254; // 'CNBT'
  /// NGH/vector wire v2 (unreleased). Do not bump without a real format break.
  static const int version = 2;
  static const int headerSize = 20;

  /// bit0: leaf-level (children are leaf pages). Clear = mid-level.
  static const int flagLeafLevel = 0x1;

  /// Maximum entries that fit safely in a 16KB Nav page.
  /// 16384 - 20 (BTreePageHeader) - 20 (NghNavBTreePage header) = 16344 bytes.
  /// Floor(16344 / 206) = 79 max. 64 provides generous 3.1KB safety margin.
  static const int maxEntriesPerPage = 64;

  /// Safety hop cap while descending `!isLeafLevel` (cycle / corrupt tree).
  /// Normal stop is the leaf-level flag — never rewrite mid pages as leaves.
  /// 64^8 leaf pages ≫ tens of trillions of vectors.
  static const int maxTreeHops = 8;

  final int rootCentroidId;

  /// [flagLeafLevel] etc.
  int flags;
  final List<CentroidBranchEntry> entries;

  NghNavBTreePage({
    required this.rootCentroidId,
    this.flags = flagLeafLevel,
    required this.entries,
  });

  bool get isLeafLevel => (flags & flagLeafLevel) != 0;
  set isLeafLevel(bool v) {
    if (v) {
      flags |= flagLeafLevel;
    } else {
      flags &= ~flagLeafLevel;
    }
  }

  /// Contiguous child 48-D SIMD rows (12 Float32x4 per entry).
  /// Same values as [CentroidBranchEntry.centroid48DSimd]; layout only.
  Float32x4List? _search48Simd;

  /// Packed nav 48-D rows (null until [ensureSearch48Ready]).
  Float32x4List? get search48Simd => _search48Simd;

  void invalidateSearch48Pack() {
    _search48Simd = null;
  }

  /// Rebuild packed child 48-D (no-op if already warm). Wire format unchanged.
  void ensureSearch48Ready() {
    if (_search48Simd != null) return;
    final n = entries.length;
    if (n <= 0) {
      _search48Simd = Float32x4List(0);
      return;
    }
    final packed = Float32List(n * 48);
    var row = 0;
    for (final e in entries) {
      packed.setRange(row, row + 48, e.centroid48D);
      row += 48;
    }
    _search48Simd = Float32x4List.sublistView(packed);
  }

  /// Approximate resident bytes for TreeCache budgeting (object + 48-D vectors).
  int estimateResidentBytes() {
    var size = 96 + entries.length * 280;
    final packed = _search48Simd;
    if (packed != null) size += packed.length * 16;
    return size;
  }

  Uint8List encodePayload() {
    final count = entries.length;
    if (count > 79) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'NghNavBTreePage entry overflow: count=$count > 79 (pageSize=16384)',
        )
      ]);
    }
    final totalBytes = headerSize + count * 206;
    final buf = Uint8List(totalBytes);
    final bd = ByteData.sublistView(buf);

    bd.setUint32(0, magic, Endian.little);
    bd.setUint16(4, version, Endian.little);
    bd.setUint16(6, count, Endian.little);
    bd.setUint32(8, rootCentroidId, Endian.little);
    bd.setUint32(12, flags, Endian.little);
    bd.setUint32(16, 0, Endian.little); // reserved

    int off = headerSize;
    for (int i = 0; i < count; i++) {
      final e = entries[i];
      bd.setUint32(off, e.centroidId, Endian.little);
      bd.setUint32(off + 4, e.childPageId.wirePartition, Endian.little);
      bd.setUint32(off + 8, e.childPageId.wirePage, Endian.little);
      bd.setUint16(off + 12, e.childWeight.clamp(0, 0xFFFF), Endian.little);
      off += 14;

      final c48 = e.centroid48D;
      for (int d = 0; d < 48; d++) {
        bd.setFloat32(off, c48[d], Endian.little);
        off += 4;
      }
    }
    return buf;
  }

  static NghNavBTreePage? tryDecodePayload(Uint8List bytes) {
    if (bytes.length < headerSize) return null;
    final bd = ByteData.sublistView(bytes);
    if (bd.getUint32(0, Endian.little) != magic) return null;
    final ver = bd.getUint16(4, Endian.little);
    if (ver != version) return null;

    final count = bd.getUint16(6, Endian.little);
    final rId = bd.getUint32(8, Endian.little);
    final flags = bd.getUint32(12, Endian.little);

    int off = headerSize;
    final entries = <CentroidBranchEntry>[];
    for (int i = 0; i < count; i++) {
      if (off + 206 > bytes.length) break;
      final cId = bd.getUint32(off, Endian.little);
      final part = bd.getUint32(off + 4, Endian.little);
      final pg = bd.getUint32(off + 8, Endian.little);
      final slotCount = bd.getUint16(off + 12, Endian.little);
      off += 14;

      final c48 = Float32List(48);
      for (int d = 0; d < 48; d++) {
        c48[d] = bd.getFloat32(off, Endian.little);
        off += 4;
      }

      entries.add(CentroidBranchEntry(
        centroidId: cId,
        leafPageId: NghPageId.fromWire(part, pg),
        leafSlotCount: slotCount,
        centroid48D: c48,
      ));
    }

    return NghNavBTreePage(
      rootCentroidId: rId,
      flags: flags,
      entries: entries,
    );
  }
}

/// Root table page stored at page 1 of partition 0 in `.nav` files.
final class NghNavRootPage {
  static const int magic = 0x434E5254; // 'CNRT'
  static const int version = 2;
  static const int headerSize = 16;

  final int lowDim;
  final int fullDim;

  /// High-water centroid id for leaf splits (persisted; avoids full L1 scan on open).
  final int nextCentroidId;

  final List<
          ({int rootId, NghPageId firstInternalPage, Float32List centroid48D})>
      roots;

  NghNavRootPage({
    this.lowDim = 48,
    required this.fullDim,
    this.nextCentroidId = 0,
    required this.roots,
  });

  Uint8List encodePayload() {
    final count = roots.length;
    final totalBytes = headerSize + count * 204;
    final buf = Uint8List(totalBytes);
    final bd = ByteData.sublistView(buf);

    bd.setUint32(0, magic, Endian.little);
    bd.setUint16(4, version, Endian.little);
    bd.setUint16(6, count, Endian.little);
    bd.setUint16(8, lowDim, Endian.little);
    bd.setUint16(10, fullDim, Endian.little);
    bd.setUint32(12, nextCentroidId, Endian.little);

    int off = headerSize;
    for (int i = 0; i < count; i++) {
      final r = roots[i];
      bd.setUint32(off, r.rootId, Endian.little);
      bd.setUint32(off + 4, r.firstInternalPage.wirePartition, Endian.little);
      bd.setUint32(off + 8, r.firstInternalPage.wirePage, Endian.little);
      off += 12;

      final c48 = r.centroid48D;
      for (int d = 0; d < 48; d++) {
        bd.setFloat32(off, c48[d], Endian.little);
        off += 4;
      }
    }
    return buf;
  }

  static NghNavRootPage? tryDecodePayload(Uint8List bytes) {
    if (bytes.length < headerSize) return null;
    final bd = ByteData.sublistView(bytes);
    if (bd.getUint32(0, Endian.little) != magic) return null;
    final ver = bd.getUint16(4, Endian.little);
    if (ver != version) return null;

    final count = bd.getUint16(6, Endian.little);
    final lDim = bd.getUint16(8, Endian.little);
    final fDim = bd.getUint16(10, Endian.little);
    final nextCentroidId = bd.getUint32(12, Endian.little);

    int off = headerSize;
    final roots = <({
      int rootId,
      NghPageId firstInternalPage,
      Float32List centroid48D
    })>[];
    for (int i = 0; i < count; i++) {
      if (off + 204 > bytes.length) break;
      final rId = bd.getUint32(off, Endian.little);
      final part = bd.getUint32(off + 4, Endian.little);
      final pg = bd.getUint32(off + 8, Endian.little);
      off += 12;

      final c48 = Float32List(48);
      for (int d = 0; d < 48; d++) {
        c48[d] = bd.getFloat32(off, Endian.little);
        off += 4;
      }

      roots.add((
        rootId: rId,
        firstInternalPage: NghPageId.fromWire(part, pg),
        centroid48D: c48,
      ));
    }

    return NghNavRootPage(
      lowDim: lDim,
      fullDim: fDim,
      nextCentroidId: nextCentroidId,
      roots: roots,
    );
  }
}
