import 'dart:typed_data';

import '../handler/memcomparable.dart';
import '../handler/encoder.dart';
import '../handler/platform_byte_data.dart';
import '../model/data_store_config.dart';
import '../model/meta_info.dart';

// ============================================================================
// B+Tree Page Types and Constants
// ============================================================================

/// Page type enumeration for B+Tree nodes.
enum BTreePageType {
  /// Leaf page containing key-value pairs.
  leaf,

  /// Internal page containing child pointers.
  internal,

  /// Partition meta page (pageNo=0) for per-file statistics.
  ///
  /// This page is not part of the B+Tree structure. It is stored in-band as a
  /// normal page to avoid shifting offsets and to allow updating metadata by
  /// rewriting only a single page.
  meta,

  /// Free page used for page reuse (freelist).
  ///
  /// A freed page is stored in-band and linked via a per-partition freelist head
  /// stored in [PartitionMetaPage]. This enables O(1) page reuse without scanning.
  free,

  /// Overflow (TOAST-like) data page for large values stored out-of-line.
  ///
  /// IMPORTANT: appended at end to preserve on-disk enum indices.
  overflow,
}

// ============================================================================
// CRC32 and Utility Classes
// ============================================================================

/// CRC32 (IEEE) for page integrity checks.
///
/// Used to detect torn writes / partial page updates even when encryption is off.
final class Crc32 {
  static final Uint32List _table = _buildTable();

  static Uint32List _buildTable() {
    const int poly = 0xEDB88320;
    final t = Uint32List(256);
    for (int i = 0; i < 256; i++) {
      int c = i;
      for (int k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (poly ^ (c >>> 1)) : (c >>> 1);
      }
      t[i] = c;
    }
    return t;
  }

  /// Compute CRC32 of [data] from [start] for [length] bytes.
  static int of(Uint8List data, [int start = 0, int? length]) {
    final int end = (length == null) ? data.length : (start + length);
    int c = 0xFFFFFFFF;
    for (int i = start; i < end; i++) {
      c = _table[(c ^ data[i]) & 0xFF] ^ (c >>> 8);
    }
    return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}

/// A value-based key wrapper for Uint8List.
///
/// Dart's Uint8List uses identity for ==/hashCode, so it cannot be used directly
/// as a Map key when you need content-based equality.
final class ByteKey {
  final Uint8List bytes;
  final int _hash;

  ByteKey(this.bytes) : _hash = Crc32.of(bytes);

  @override
  int get hashCode => _hash;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ByteKey) return false;
    final a = bytes;
    final b = other.bytes;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

// ============================================================================
// Page Header and IO
// ============================================================================

/// Fixed page header (little-endian). Header is NOT encrypted.
///
/// Layout:
/// - magic:u32 = 'TPG2'
/// - headerSize:u16
/// - pageType:u8
/// - flags:u8
/// - payloadLen:u32   (bytes of encoded payload)
/// - payloadCrc32:u32 (crc over encoded payload bytes)
/// - reserved:u32     (future use)
final class BTreePageHeader {
  static const int size = 4 + 2 + 1 + 1 + 4 + 4 + 4;
  static const int _magic = 0x32475054; // 'TPG2' little-endian

  final BTreePageType pageType;
  final int payloadLen;
  final int payloadCrc32;
  final int flags;

  const BTreePageHeader({
    required this.pageType,
    required this.payloadLen,
    required this.payloadCrc32,
    this.flags = 0,
  });

  /// Encode header to bytes.
  Uint8List encode() {
    final bd = ByteData(size);
    bd.setUint32(0, _magic, Endian.little);
    bd.setUint16(4, size, Endian.little);
    bd.setUint8(6, pageType.index);
    bd.setUint8(7, flags);
    bd.setUint32(8, payloadLen, Endian.little);
    bd.setUint32(12, payloadCrc32, Endian.little);
    bd.setUint32(16, 0, Endian.little);
    return bd.buffer.asUint8List();
  }

  /// Try to decode header from page bytes. Returns null if invalid.
  static BTreePageHeader? tryDecode(Uint8List pageBytes) {
    if (pageBytes.length < size) return null;
    final bd = ByteData.sublistView(pageBytes, 0, size);
    final magic = bd.getUint32(0, Endian.little);
    if (magic != _magic) return null;
    final hs = bd.getUint16(4, Endian.little);
    if (hs != size) return null;
    final pt = bd.getUint8(6);
    if (pt < 0 || pt >= BTreePageType.values.length) return null;
    final flags = bd.getUint8(7);
    final len = bd.getUint32(8, Endian.little);
    final crc = bd.getUint32(12, Endian.little);
    return BTreePageHeader(
      pageType: BTreePageType.values[pt],
      payloadLen: len,
      payloadCrc32: crc,
      flags: flags,
    );
  }
}

/// Page IO helper: wraps encoded payload with header + crc + padding.
final class BTreePageIO {
  /// Build complete page bytes from encoded payload.
  static Uint8List buildPageBytes({
    required BTreePageType type,
    required Uint8List encodedPayload,
    required int pageSize,
  }) {
    final hdr = BTreePageHeader(
      pageType: type,
      payloadLen: encodedPayload.length,
      payloadCrc32: Crc32.of(encodedPayload),
    );
    final headerBytes = hdr.encode();
    final total = BTreePageHeader.size + encodedPayload.length;
    if (total > pageSize) {
      throw StateError(
        'Page overflow: total=$total > pageSize=$pageSize '
        '(header=${BTreePageHeader.size}, payload=${encodedPayload.length}, '
        'overflow=${total - pageSize} bytes). '
        'This indicates the page size estimation was inaccurate. '
        'Consider checking BTreePageSizer.fitsInPage before encoding.',
      );
    }
    final out = Uint8List(pageSize);
    out.setRange(0, BTreePageHeader.size, headerBytes);
    out.setRange(BTreePageHeader.size,
        BTreePageHeader.size + encodedPayload.length, encodedPayload);
    return out;
  }

  /// Parse page bytes and return type + encoded payload.
  static ({BTreePageType type, Uint8List encodedPayload}) parsePageBytes(
      Uint8List pageBytes) {
    final hdr = BTreePageHeader.tryDecode(pageBytes);
    if (hdr == null) {
      throw StateError('Invalid page header/magic');
    }
    final int off = BTreePageHeader.size;
    final int end = off + hdr.payloadLen;
    if (hdr.payloadLen < 0 || end > pageBytes.length) {
      throw StateError('Invalid payload length: ${hdr.payloadLen}');
    }
    final payload = pageBytes.sublist(off, end);
    final crc = Crc32.of(payload);
    if (crc != hdr.payloadCrc32) {
      throw StateError(
          'Page CRC mismatch: expected=${hdr.payloadCrc32} actual=$crc');
    }
    return (type: hdr.pageType, encodedPayload: payload);
  }
}

// ============================================================================
// Partition Meta Page (pageNo = 0)
// ============================================================================

/// Per-partition-file statistics stored in-band at pageNo=0.
///
/// This page is intentionally **fixed-size payload** (with a reserved area) so that
/// adding future fields only requires rewriting this single page, without shifting
/// any other pages or offsets in the partition file.
final class PartitionMetaPage {
  static const int payloadVersion = 1;
  static const int _payloadMagic = 0x31485054; // 'TPH1' little-endian

  /// Fixed payload size in bytes (independent of pageSize).
  static const int payloadSize = 128;

  final int partitionNo;
  final int totalEntries;
  final int fileSizeInBytes;

  /// Head pageNo of per-partition freelist (within this partition file).
  /// -1 means empty.
  final int freeListHeadPageNo;

  /// Number of free pages in freelist (best-effort).
  final int freePageCount;

  const PartitionMetaPage({
    required this.partitionNo,
    required this.totalEntries,
    required this.fileSizeInBytes,
    this.freeListHeadPageNo = -1,
    this.freePageCount = 0,
  });

  Uint8List encodePayload() {
    final bd = ByteData(payloadSize);
    bd.setUint32(0, _payloadMagic, Endian.little);
    bd.setUint16(4, payloadVersion, Endian.little);
    bd.setUint16(6, 0, Endian.little); // flags
    bd.setInt32(8, partitionNo, Endian.little);
    bd.setInt32(12, 0, Endian.little); // reserved
    PlatformByteData.setInt64(bd, 16, totalEntries, Endian.little);
    PlatformByteData.setInt64(bd, 24, fileSizeInBytes, Endian.little);
    // [32..] reserved for future fields.
    bd.setInt32(32, freeListHeadPageNo, Endian.little);
    bd.setInt32(36, freePageCount, Endian.little);
    return bd.buffer.asUint8List();
  }

  static PartitionMetaPage? tryDecodePayload(Uint8List bytes) {
    if (bytes.length < 32) return null;
    final bd = ByteData.sublistView(bytes);
    final magic = bd.getUint32(0, Endian.little);
    if (magic != _payloadMagic) return null;
    final v = bd.getUint16(4, Endian.little);
    if (v <= 0) return null;
    final pNo = bd.getInt32(8, Endian.little);
    final total = PlatformByteData.getInt64(bd, 16, Endian.little);
    final size = PlatformByteData.getInt64(bd, 24, Endian.little);
    int freeHead = -1;
    int freeCount = 0;
    if (bytes.length >= 40) {
      freeHead = bd.getInt32(32, Endian.little);
      freeCount = bd.getInt32(36, Endian.little);
    }
    return PartitionMetaPage(
      partitionNo: pNo,
      totalEntries: total < 0 ? 0 : total,
      fileSizeInBytes: size < 0 ? 0 : size,
      freeListHeadPageNo: freeHead,
      freePageCount: freeCount < 0 ? 0 : freeCount,
    );
  }
}

// ============================================================================
// Overflow Page (TOAST-like)
// ============================================================================

/// A fixed-size page used to store a chunk of a large value out-of-line.
///
/// Payload format (little-endian):
/// - magic:u32 = 'OVP1'
/// - version:u16
/// - flags:u16
/// - nextPageNo:i32   (-1 means end)
/// - dataLen:u32
/// - dataBytes...[dataLen]
final class OverflowPage {
  static const int payloadVersion = 1;
  static const int _payloadMagic = 0x3150564F; // 'OVP1' little-endian

  final int nextPageNo;
  final Uint8List data;

  const OverflowPage({required this.nextPageNo, required this.data});

  Uint8List encodePayload() {
    final header = ByteData(4 + 2 + 2 + 4 + 4);
    header.setUint32(0, _payloadMagic, Endian.little);
    header.setUint16(4, payloadVersion, Endian.little);
    header.setUint16(6, 0, Endian.little);
    header.setInt32(8, nextPageNo, Endian.little);
    header.setUint32(12, data.length, Endian.little);
    final b = BytesBuilder(copy: false);
    b.add(header.buffer.asUint8List());
    if (data.isNotEmpty) b.add(data);
    return b.toBytes();
  }

  static OverflowPage? tryDecodePayload(Uint8List bytes) {
    if (bytes.length < 4 + 2 + 2 + 4 + 4) return null;
    final bd = ByteData.sublistView(bytes);
    final magic = bd.getUint32(0, Endian.little);
    if (magic != _payloadMagic) return null;
    final v = bd.getUint16(4, Endian.little);
    if (v <= 0) return null;
    final next = bd.getInt32(8, Endian.little);
    final len = bd.getUint32(12, Endian.little);
    const int off = 16;
    if (off + len > bytes.length) return null;
    final data = bytes.sublist(off, off + len);
    return OverflowPage(nextPageNo: next, data: data);
  }

  /// Max data bytes that can fit in one overflow page given a [pageSize] and
  /// encoded/encrypted payload overhead already applied at page layer.
  static int maxChunkLenForPageSize(int pageSize) {
    // BTree page header is outside payload; within payload we reserve 16 bytes.
    final maxPayload = pageSize - BTreePageHeader.size;
    final overhead = 16;
    final max = maxPayload - overhead;
    return max < 0 ? 0 : max;
  }
}

// ============================================================================
// Free Page (Freelist Node)
// ============================================================================

/// A freelist node stored in-band as a normal fixed-size page.
///
/// Payload format (little-endian, fixed 16 bytes):
/// - magic:u32 = 'FPG1'
/// - version:u16
/// - flags:u16
/// - nextFreePageNo:i32  (-1 means end)
/// - reserved:i32
final class FreePage {
  static const int payloadVersion = 1;
  static const int payloadSize = 16;
  static const int _payloadMagic = 0x31475046; // 'FPG1' little-endian

  final int nextFreePageNo;
  const FreePage({required this.nextFreePageNo});

  Uint8List encodePayload() {
    final bd = ByteData(payloadSize);
    bd.setUint32(0, _payloadMagic, Endian.little);
    bd.setUint16(4, payloadVersion, Endian.little);
    bd.setUint16(6, 0, Endian.little);
    bd.setInt32(8, nextFreePageNo, Endian.little);
    bd.setInt32(12, 0, Endian.little);
    return bd.buffer.asUint8List();
  }

  static FreePage? tryDecodePayload(Uint8List bytes) {
    if (bytes.length < payloadSize) return null;
    final bd = ByteData.sublistView(bytes);
    final magic = bd.getUint32(0, Endian.little);
    if (magic != _payloadMagic) return null;
    final v = bd.getUint16(4, Endian.little);
    if (v <= 0) return null;
    final next = bd.getInt32(8, Endian.little);
    return FreePage(nextFreePageNo: next);
  }
}

// ============================================================================
// Leaf Page
// ============================================================================

/// A compact leaf page that is rewritten as a whole on update (page-granularity).
///
/// Format (all little-endian):
/// [count:u16][highKeyLen:u16][prevP:i32][prevPg:i32][nextP:i32][nextPg:i32]
/// [highKey bytes]
/// then repeated count times:
///   [kLen:u16][vLen:u32][keyBytes][valBytes]
///
/// Key ordering uses [MemComparableKey.compare] on encoded key bytes.
final class LeafPage {
  TreePagePtr prev;
  TreePagePtr next;

  /// High key (inclusive) for this leaf's key range.
  /// - Empty means +INF (rightmost leaf).
  /// - This is a **range boundary**, not necessarily equal to the current max record key.
  Uint8List highKey;

  final List<Uint8List> keys; // sorted
  final List<Uint8List> values; // aligned

  LeafPage({
    required this.prev,
    required this.next,
    required this.highKey,
    required this.keys,
    required this.values,
  });

  factory LeafPage.empty() => LeafPage(
        prev: TreePagePtr.nullPtr,
        next: TreePagePtr.nullPtr,
        highKey: Uint8List(0),
        keys: <Uint8List>[],
        values: <Uint8List>[],
      );

  /// Try to decode payload bytes into a LeafPage.
  static LeafPage? tryDecodePayload(Uint8List bytes) {
    // [count:u16][highKeyLen:u16][prevP:i32][prevPg:i32][nextP:i32][nextPg:i32][highKey][entries...]
    if (bytes.length < 2 + 2 + 16) return null;
    final bd = ByteData.sublistView(bytes);
    final count = bd.getUint16(0, Endian.little);
    final highLen = bd.getUint16(2, Endian.little);
    int off = 4;
    int rp() {
      final v = bd.getInt32(off, Endian.little);
      off += 4;
      return v;
    }

    final prev = TreePagePtr(rp(), rp());
    final next = TreePagePtr(rp(), rp());
    if (off + highLen > bytes.length) return null;
    final highKey = bytes.sublist(off, off + highLen);
    off += highLen;

    final keys = List<Uint8List>.filled(count, Uint8List(0), growable: true);
    final vals = List<Uint8List>.filled(count, Uint8List(0), growable: true);

    for (int i = 0; i < count; i++) {
      if (off + 2 + 4 > bytes.length) return null;
      final kLen = bd.getUint16(off, Endian.little);
      off += 2;
      final vLen = bd.getUint32(off, Endian.little);
      off += 4;
      if (off + kLen + vLen > bytes.length) return null;
      final k = bytes.sublist(off, off + kLen);
      off += kLen;
      final v = bytes.sublist(off, off + vLen);
      off += vLen;
      keys[i] = k;
      vals[i] = v;
    }

    return LeafPage(
      prev: prev,
      next: next,
      highKey: highKey,
      keys: keys,
      values: vals,
    );
  }

  /// Encode this leaf page to payload bytes.
  Uint8List encodePayload() {
    final b = BytesBuilder(copy: false);
    final header = ByteData(2 + 2 + 16);
    header.setUint16(0, keys.length, Endian.little);
    header.setUint16(2, highKey.length, Endian.little);
    int off = 4;
    void wp(int v) {
      header.setInt32(off, v, Endian.little);
      off += 4;
    }

    wp(prev.partitionNo);
    wp(prev.pageNo);
    wp(next.partitionNo);
    wp(next.pageNo);

    b.add(header.buffer.asUint8List());
    if (highKey.isNotEmpty) {
      b.add(highKey);
    }
    for (int i = 0; i < keys.length; i++) {
      final k = keys[i];
      final v = values[i];
      final hdr = ByteData(2 + 4);
      hdr.setUint16(0, k.length, Endian.little);
      hdr.setUint32(2, v.length, Endian.little);
      b.add(hdr.buffer.asUint8List());
      b.add(k);
      b.add(v);
    }
    return b.toBytes();
  }

  /// Estimate plaintext payload size in bytes for this leaf page.
  ///
  /// This avoids allocating the payload buffer and is used for fast overflow checks
  /// in hot write paths (e.g. batch inserts).
  int estimatePayloadSize() {
    // [count:u16][highKeyLen:u16][prevP:i32][prevPg:i32][nextP:i32][nextPg:i32]
    int size = 2 + 2 + 16;
    size += highKey.length;
    for (int i = 0; i < keys.length; i++) {
      // [kLen:u16][vLen:u32][keyBytes][valBytes]
      size += 2 + 4 + keys[i].length + values[i].length;
    }
    return size;
  }

  /// Current max record key (NOT the page boundary).
  Uint8List maxRecordKey() => keys.isEmpty ? Uint8List(0) : keys.last;

  int _lowerBound(Uint8List key) {
    int lo = 0;
    int hi = keys.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      final cmp = MemComparableKey.compare(keys[mid], key);
      if (cmp < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// Find exact key index, or null if not found.
  int? find(Uint8List key) {
    final i = _lowerBound(key);
    if (i < keys.length && MemComparableKey.compare(keys[i], key) == 0) {
      return i;
    }
    return null;
  }

  /// Upsert a key-value pair.
  void upsert(Uint8List key, Uint8List value) {
    final i = _lowerBound(key);
    if (i < keys.length && MemComparableKey.compare(keys[i], key) == 0) {
      values[i] = value;
      return;
    }
    keys.insert(i, key);
    values.insert(i, value);
  }

  /// Delete a key. Returns true if found and deleted.
  bool delete(Uint8List key) {
    final i = find(key);
    if (i == null) return false;
    keys.removeAt(i);
    values.removeAt(i);
    return true;
  }

  /// Split this leaf page into two pages (left=this mutated, right returned).
  ///
  /// Returns the separator key (max key of left) and the right page content.
  ({Uint8List oldMaxKey, Uint8List leftMaxKey, LeafPage right}) split() {
    final oldHigh = highKey;
    final n = keys.length;
    final mid = n >> 1;
    final rightKeys = keys.sublist(mid);
    final rightVals = values.sublist(mid);
    keys.removeRange(mid, n);
    values.removeRange(mid, n);
    // After split:
    // - left highKey becomes the boundary between left/right (max record key in left)
    // - right highKey keeps the old highKey (+INF or previous boundary)
    final leftMax = maxRecordKey();
    highKey = leftMax;
    final right = LeafPage(
      prev: TreePagePtr.nullPtr,
      next: TreePagePtr.nullPtr,
      highKey: oldHigh,
      keys: rightKeys,
      values: rightVals,
    );
    return (oldMaxKey: oldHigh, leftMaxKey: leftMax, right: right);
  }
}

// ============================================================================
// Internal Page
// ============================================================================

/// Internal node page: stores fences (maxKey -> childPtr), like a multi-level directory.
///
/// Payload format:
/// [count:u16]
/// repeated count:
///   [kLen:u16][childP:i32][childPg:i32][keyBytes]
final class InternalPage {
  final List<Uint8List> maxKeys; // sorted
  final List<TreePagePtr> children; // aligned

  InternalPage({required this.maxKeys, required this.children});

  factory InternalPage.empty() =>
      InternalPage(maxKeys: <Uint8List>[], children: <TreePagePtr>[]);

  /// Try to decode payload bytes into an InternalPage.
  static InternalPage? tryDecodePayload(Uint8List bytes) {
    if (bytes.length < 2) return null;
    final bd = ByteData.sublistView(bytes);
    final count = bd.getUint16(0, Endian.little);
    int off = 2;

    final keys = List<Uint8List>.filled(count, Uint8List(0), growable: true);
    final kids =
        List<TreePagePtr>.filled(count, TreePagePtr.nullPtr, growable: true);

    for (int i = 0; i < count; i++) {
      if (off + 2 + 8 > bytes.length) return null;
      final kLen = bd.getUint16(off, Endian.little);
      off += 2;
      final p = bd.getInt32(off, Endian.little);
      off += 4;
      final pg = bd.getInt32(off, Endian.little);
      off += 4;
      if (off + kLen > bytes.length) return null;
      final k = bytes.sublist(off, off + kLen);
      off += kLen;
      keys[i] = k;
      kids[i] = TreePagePtr(p, pg);
    }
    return InternalPage(maxKeys: keys, children: kids);
  }

  /// Encode this internal page to payload bytes.
  Uint8List encodePayload() {
    final b = BytesBuilder(copy: false);
    final header = ByteData(2);
    header.setUint16(0, maxKeys.length, Endian.little);
    b.add(header.buffer.asUint8List());
    for (int i = 0; i < maxKeys.length; i++) {
      final k = maxKeys[i];
      final c = children[i];
      final hdr = ByteData(2 + 8);
      hdr.setUint16(0, k.length, Endian.little);
      hdr.setInt32(2, c.partitionNo, Endian.little);
      hdr.setInt32(6, c.pageNo, Endian.little);
      b.add(hdr.buffer.asUint8List());
      b.add(k);
    }
    return b.toBytes();
  }

  /// Estimate plaintext payload size in bytes for this internal page.
  ///
  /// This avoids allocating the payload buffer and is used for fast overflow checks
  /// in hot write paths (e.g. batch inserts).
  int estimatePayloadSize() {
    // [count:u16] then repeated:
    //   [kLen:u16][childP:i32][childPg:i32][keyBytes]
    int size = 2;
    for (final k in maxKeys) {
      size += 2 + 8 + k.length;
    }
    return size;
  }

  Uint8List maxKey() => maxKeys.isEmpty ? Uint8List(0) : maxKeys.last;

  static int _compareHighKey(Uint8List highKey, Uint8List key) {
    // Empty highKey means +INF.
    if (highKey.isEmpty) return 1;
    return MemComparableKey.compare(highKey, key);
  }

  /// Find child index for a given key.
  int childIndexForKey(Uint8List key) {
    if (children.isEmpty || maxKeys.isEmpty) return 0;
    // first maxKey >= key
    int lo = 0;
    int hi = maxKeys.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_compareHighKey(maxKeys[mid], key) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    // Clamp to children length (may be smaller if corrupted).
    if (lo >= children.length) return children.length - 1;
    return lo;
  }

  void setEntry(int index, Uint8List highKey, TreePagePtr child) {
    maxKeys[index] = highKey;
    children[index] = child;
  }

  void insertEntry(int index, Uint8List highKey, TreePagePtr child) {
    maxKeys.insert(index, highKey);
    children.insert(index, child);
  }

  ({Uint8List oldMaxKey, Uint8List leftMaxKey, InternalPage right}) split() {
    final oldMax = maxKey();
    final n = maxKeys.length;
    final mid = n >> 1;
    final rightKeys = maxKeys.sublist(mid);
    final rightKids = children.sublist(mid);
    maxKeys.removeRange(mid, n);
    children.removeRange(mid, n);
    final right = InternalPage(maxKeys: rightKeys, children: rightKids);
    return (oldMaxKey: oldMax, leftMaxKey: maxKey(), right: right);
  }
}

// ============================================================================
// Page Codec (Encryption Support)
// ============================================================================

/// Helpers to encode/decode a page payload with optional encryption.
final class BTreePageCodec {
  /// Encode payload with optional encryption.
  static Uint8List encodePayload(
    Uint8List payload, {
    required DataStoreConfig config,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    Uint8List? aad,
  }) {
    final ec = config.encryptionConfig;
    if (ec == null) return payload;
    return EncoderHandler.encodeBytes(
      payload,
      customKey: encryptionKey,
      keyId: encryptionKeyId,
      encryptionType: ec.encryptionType,
      aad: aad,
    );
  }

  /// Decode payload with optional decryption.
  static Uint8List decodePayload(
    Uint8List encoded, {
    required DataStoreConfig config,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    Uint8List? aad,
  }) {
    final ec = config.encryptionConfig;
    if (ec == null) return encoded;
    return EncoderHandler.decodeBytes(
      encoded,
      customKey: encryptionKey,
      keyId: encryptionKeyId,
      aad: aad,
    );
  }
}

// ============================================================================
// Page Size Estimation Helpers
// ============================================================================

/// Fast estimators for B+Tree page encoded sizes.
///
/// These helpers avoid repeatedly building full page byte buffers just to detect
/// overflow during hot write loops. They intentionally mirror `EncoderHandler.encodeBytes`
/// output sizes (header + optional AEAD overhead).
final class BTreePageSizer {
  // EncoderHandler header format:
  //   <prefix>v<ver>_k<keyId>_
  // where <prefix> is always 5 ASCII chars in current format (e.g. "ToU8_").
  static const int _encoderPrefixLen = 5;
  static const int _encoderVersion = 1;
  static const int _aeadOverheadBytes = 12 + 16; // nonce(12) + tag(16)

  static int _digits(int v) {
    if (v == 0) return 1;
    int n = v.abs();
    int d = 0;
    while (n > 0) {
      n ~/= 10;
      d++;
    }
    return d;
  }

  static int _encoderHeaderLen(int keyId) {
    // prefix + 'v' + verDigits + '_' + 'k' + keyIdDigits + '_'
    return _encoderPrefixLen +
        1 +
        _digits(_encoderVersion) +
        1 +
        1 +
        _digits(keyId) +
        1;
  }

  /// Estimate encoded payload length (bytes) after applying optional encryption wrapper.
  ///
  /// - If encryption is disabled (config.encryptionConfig == null), returns [plainPayloadLen].
  /// - If encryption is enabled, returns:
  ///   - headerLen + plainLen (+ AEAD overhead for ChaCha20-Poly1305 / AES-256-GCM)
  static int estimateEncodedPayloadLength(
    int plainPayloadLen, {
    required DataStoreConfig config,
    int? encryptionKeyId,
  }) {
    if (plainPayloadLen <= 0) return 0;
    final ec = config.encryptionConfig;
    if (ec == null) return plainPayloadLen;

    final int keyId = encryptionKeyId ?? EncoderHandler.getCurrentKeyId();
    final int headerLen = _encoderHeaderLen(keyId);

    switch (ec.encryptionType) {
      case EncryptionType.chacha20Poly1305:
      case EncryptionType.aes256Gcm:
        return plainPayloadLen + headerLen + _aeadOverheadBytes;
      case EncryptionType.none:
      case EncryptionType.xorObfuscation:
        return plainPayloadLen + headerLen;
    }
  }

  /// Returns true if a payload of [plainPayloadLen] will fit into a fixed-size page.
  ///
  /// Prefer passing actual plain length (e.g. [encodePayload].length) when available.
  /// Uses a safety margin for encoder header/keyId and AEAD overhead variance.
  static bool fitsInPage({
    required int pageSize,
    required int plainPayloadLen,
    required DataStoreConfig config,
    int? encryptionKeyId,
  }) {
    final encodedLen = estimateEncodedPayloadLength(
      plainPayloadLen,
      config: config,
      encryptionKeyId: encryptionKeyId,
    );
    // 128-byte margin to avoid page overflow during batch flush/recovery.
    // The previous 24-byte margin was insufficient for certain variable-length
    // encoder headers or crypto overheads, causing "total > pageSize" crashes.
    const int safetyMargin = 128;
    return BTreePageHeader.size + encodedLen + safetyMargin <= pageSize;
  }
}

// ============================================================================
// Tree Allocator Helper
// ============================================================================

/// Estimates file size for page allocation decisions.
final class BTreeAllocator {
  /// Estimate file size after allocating one more page.
  static int estimateFileSizeBytes(int pageSize, int nextPageNoInclusive) {
    if (nextPageNoInclusive < 0) return 0;
    return (nextPageNoInclusive + 1) * pageSize;
  }
}
