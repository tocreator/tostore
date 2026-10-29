import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../handler/logger.dart';
import '../../handler/platform_byte_data.dart';
import '../../model/db_exception.dart';
import '../../model/result_status.dart';
import '../../model/result_type.dart';
import '../../model/wal_pointer.dart';
import '../btree/tree_cache.dart';
import '../compute/yield_controller.dart';
import '../maintenance/prewarm_budget_ledger.dart';
import 'wmbp_constants.dart';
import 'wmbp_scheduler.dart';
import 'wmbp_window.dart';

/// Explicit physical page location (NGH/B+Tree style). Not derived from
/// `maxPartitionFileSize` at read time.
final class WmbpPagePtr {
  final int partitionNo;
  final int pageNo;

  const WmbpPagePtr(this.partitionNo, this.pageNo);

  static const WmbpPagePtr nullPtr = WmbpPagePtr(-1, -1);

  bool get isNull => partitionNo < 0 || pageNo < 0;

  /// Packed `partitionNo * 2^pageNoBits + pageNo` (web-safe arithmetic).
  /// Sentinel `-1` / on-disk `0xFFFFFFFF` when unset.
  int get packed => pack(partitionNo, pageNo);

  static int pack(int partitionNo, int pageNo) {
    if (partitionNo < 0 || pageNo < 0) return -1;
    if (partitionNo > WmbpConstants.pagePtrMaxPartition ||
        pageNo > WmbpConstants.pagePtrPageNoMask) {
      return -1;
    }
    // Prefer * over << so dart2js does not ToInt32-truncate into the sign bit
    final int stride = WmbpConstants.pagePtrPageNoMask + 1;
    final int packed = partitionNo * stride + pageNo;
    if (packed >= 0xFFFFFFFF) return -1;
    return packed;
  }

  static (int partitionNo, int pageNo) unpack(int packed) {
    if (packed < 0 || packed == 0xFFFFFFFF) return (-1, -1);
    final int stride = WmbpConstants.pagePtrPageNoMask + 1;
    return (packed ~/ stride, packed % stride);
  }

  factory WmbpPagePtr.fromPacked(int packed) {
    final (p, n) = unpack(packed);
    return WmbpPagePtr(p, n);
  }

  @override
  String toString() => 'WmbpPagePtr(p$partitionNo, pg$pageNo)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is WmbpPagePtr &&
          partitionNo == other.partitionNo &&
          pageNo == other.pageNo);

  @override
  int get hashCode => Object.hash(partitionNo, pageNo);
}

/// Fixed 16KB page slot addressed by category, partition, and offset.
abstract class WmbpPageVolume {
  Future<Uint8List?> readAt(
    String category,
    int partitionNo,
    int offset,
    int length,
  );

  /// Plaintext bytes available inside one 16KB page.
  int get payloadBudget => WmbpConstants.pagePayloadSize;

  /// [stable] marks an in-place rewrite of an existing page slot (vs first
  /// allocation). Durable volumes ignore it for I/O - batch page-redo covers
  /// every staged page at flush time.
  Future<void> writeAt(
    String category,
    int partitionNo,
    int offset,
    Uint8List page, {
    required bool stable,
  });

  Uint8List? readAtSync(
    String category,
    int partitionNo,
    int offset,
    int length,
  ) =>
      null;

  void writeAtSync(
    String category,
    int partitionNo,
    int offset,
    Uint8List page, {
    required bool stable,
  }) {}
}

/// In-memory volume used by tests and by the page-cache unit path.
class WmbpMemoryVolume implements WmbpPageVolume {
  final Map<String, Uint8List> _files = <String, Uint8List>{};
  int reads = 0;
  Duration readDelay = Duration.zero;

  @override
  int get payloadBudget => WmbpConstants.pagePayloadSize;

  /// Runs once, before the next page write. Tests use it to insert while a
  /// flush is in flight.
  Future<void> Function()? beforeWrite;

  int filesOf(String category) {
    final prefix = '$category:';
    var n = 0;
    for (final key in _files.keys) {
      if (key.startsWith(prefix)) n++;
    }
    return n;
  }

  int bytesOf(String category) {
    final prefix = '$category:';
    var n = 0;
    for (final entry in _files.entries) {
      if (entry.key.startsWith(prefix)) n += entry.value.length;
    }
    return n;
  }

  void debugFill(String category, int partitionNo, int offset, int byte) {
    final file = _files['$category:$partitionNo'];
    if (file == null) return;
    for (int i = offset;
        i < offset + WmbpConstants.storePageSize && i < file.length;
        i++) {
      file[i] = byte;
    }
  }

  @override
  Future<Uint8List?> readAt(
    String category,
    int partitionNo,
    int offset,
    int length,
  ) async {
    reads++;
    if (readDelay > Duration.zero) await Future<void>.delayed(readDelay);
    final file = _files['$category:$partitionNo'];
    if (file == null || offset < 0 || offset + length > file.length) {
      return null;
    }
    return Uint8List.fromList(file.sublist(offset, offset + length));
  }

  @override
  Future<void> writeAt(
    String category,
    int partitionNo,
    int offset,
    Uint8List page, {
    required bool stable,
  }) async {
    final hook = beforeWrite;
    if (hook != null) {
      beforeWrite = null;
      await hook();
    }
    final key = '$category:$partitionNo';
    final current = _files[key];
    final end = offset + page.length;
    final next = Uint8List(
        current == null ? end : (current.length > end ? current.length : end));
    if (current != null) next.setRange(0, current.length, current);
    next.setRange(offset, end, page);
    _files[key] = next;
  }

  @override
  Uint8List? readAtSync(
    String category,
    int partitionNo,
    int offset,
    int length,
  ) {
    final file = _files['$category:$partitionNo'];
    if (file == null || offset < 0 || offset + length > file.length) {
      return null;
    }
    return Uint8List.fromList(file.sublist(offset, offset + length));
  }

  @override
  void writeAtSync(
    String category,
    int partitionNo,
    int offset,
    Uint8List page, {
    required bool stable,
  }) {
    final key = '$category:$partitionNo';
    final current = _files[key];
    final end = offset + page.length;
    final next = Uint8List(
        current == null ? end : (current.length > end ? current.length : end));
    if (current != null) next.setRange(0, current.length, current);
    next.setRange(offset, end, page);
    _files[key] = next;
  }
}

/// One document handed to a seal commit.
class WmbpSealDoc {
  final int docId;
  final String primaryKey;
  final Map<int, int> impacts;

  const WmbpSealDoc({
    required this.docId,
    required this.primaryKey,
    required this.impacts,
  });
}

/// Incremental batch: newly visible documents plus lazy deletes.
class WmbpCommitBatch {
  final int nextDocId;
  final int nextTermId;
  final List<WmbpSealDoc> added;
  final Map<int, String> termNames;
  final List<int> deactivated;
  final List<String> removedPks;

  /// Newest delete mark included in this batch. Later marks stay visible.
  final WalPointer? flushedDelete;

  const WmbpCommitBatch({
    required this.nextDocId,
    required this.nextTermId,
    required this.added,
    required this.termNames,
    required this.deactivated,
    required this.removedPks,
    this.flushedDelete,
  });
}

class _NameSkip {
  String term;
  int page;
  _NameSkip(this.term, this.page);
}

class _RevNode {
  final bool leaf;
  final List<_RevRec> records;
  final List<int> children;
  final List<String> separators;

  _RevNode.leaf(this.records)
      : leaf = true,
        children = <int>[],
        separators = <String>[];

  _RevNode.internal({
    required this.children,
    required this.separators,
  })  : leaf = false,
        records = <_RevRec>[];
}

class _IdRec {
  int termId;
  int df;
  int postPage;
  int postOffset;
  int postLength;
  _IdRec(this.termId, this.df, this.postPage, this.postOffset, this.postLength);
}

/// Outcome of one dirty OPEN_RAW → I/II/III attempt.
enum _OpenRawSealStatus {
  /// Body rewritten; dirty bit may be cleared.
  sealed,

  /// Disk body already non-OPEN_RAW; dirty bit may be cleared.
  alreadySealed,

  /// Term/window absent; dirty bit may be cleared.
  notFound,

  /// Transient failure; dirty bit must be kept for retry.
  retryLater,
}

final class _OpenRawSealResult {
  final _OpenRawSealStatus status;
  final _IdRec? idUpdate;
  final int bytesWritten;

  const _OpenRawSealResult(
    this.status, {
    this.idUpdate,
    this.bytesWritten = 0,
  });
}

/// Durable pointer for one closed window's OPEN_RAW term list.
final class _ClosedDirtyEntry {
  int page;
  int count;

  /// In-memory term set changed; rewrite this window's term blob only.
  bool blobDirty;

  _ClosedDirtyEntry({
    this.page = 0,
    this.count = 0,
    this.blobDirty = false,
  });
}

class _NameRec {
  int termId;
  String name;
  _NameRec(this.termId, this.name);
}

class _RevRec {
  String pk;
  int docId;
  _RevRec(this.pk, this.docId);
}

final class _TermPostings {
  Uint32List deltas = Uint32List(2);
  Uint8List q8s = Uint8List(2);
  int length = 0;

  void add(int delta, int q8) {
    if (length == deltas.length) {
      final int cur = deltas.length;
      final int newCap = cur < 512 ? cur * 2 : (cur * 3) ~/ 2;
      final newDeltas = Uint32List(newCap);
      final newQ8s = Uint8List(newCap);
      newDeltas.setRange(0, length, deltas);
      newQ8s.setRange(0, length, q8s);
      deltas = newDeltas;
      q8s = newQ8s;
    }
    deltas[length] = delta;
    q8s[length] = q8;
    length++;
  }
}

int _utf8SuffixLength(String s, int start) {
  var len = 0;
  for (int i = start; i < s.length; i++) {
    final code = s.codeUnitAt(i);
    if (code <= 0x7F) {
      len++;
    } else if (code <= 0x7FF) {
      len += 2;
    } else if (code >= 0xD800 && code <= 0xDFFF) {
      len += 2;
    } else {
      len += 3;
    }
  }
  return len;
}

@pragma('vm:prefer-inline')
int _utf8ByteLength(String s) => _utf8SuffixLength(s, 0);

int _revLeafEncodedLength(List<_RevRec> records) {
  var bytes = 3; // u8(1) + u16(records.length)
  for (int i = 0; i < records.length; i++) {
    bytes += 10 + _utf8ByteLength(records[i].pk);
  }
  return bytes;
}

int _revInternalEncodedLength(List<int> children, List<String> separators) {
  var bytes = 5 +
      children.length * 4; // u8(2) + u16(childCount) + u32*N + u16(sepCount)
  for (int i = 0; i < separators.length; i++) {
    bytes += 2 + _utf8ByteLength(separators[i]);
  }
  return bytes;
}

int _namePageEncodedLength(List<_NameRec> recs) {
  var bytes = 2; // u16(recs.length)
  var prev = '';
  for (int i = 0; i < recs.length; i++) {
    final name = recs[i].name;
    final int share = _sharedPrefix(prev, name);
    bytes += 8 + _utf8SuffixLength(name, share);
    prev = name;
  }
  return bytes;
}

class _WinAcc {
  final List<int> offsets = <int>[];
  final List<int> impacts = <int>[];
}

class _TermImage {
  int termId;
  int df = 0;
  final List<WmbpChampionPosting> champion = <WmbpChampionPosting>[];
  final Map<int, _WinAcc> windows = <int, _WinAcc>{};

  _TermImage(this.termId);
}

/// One macro directory chunk expanded in memory (up to 64 windows).
class _TermMacroSlice {
  final List<int> windowIds;
  final Uint8List maxImpacts;
  final Uint32List bodyPages;
  final Uint32List bodyOffset;
  final Uint32List bodyLength;

  _TermMacroSlice({
    required this.windowIds,
    required this.maxImpacts,
    required this.bodyPages,
    required this.bodyOffset,
    required this.bodyLength,
  });

  int indexOf(int windowId) {
    var lo = 0;
    var hi = windowIds.length;
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      final int v = windowIds[mid];
      if (v < windowId) {
        lo = mid + 1;
      } else if (v > windowId) {
        hi = mid;
      } else {
        return mid;
      }
    }
    return -1;
  }
}

/// Root Head (+ lazily loaded Macro Chunks).
///
/// Disk Root is always slim: champions + macroMaxImpact[] + macroDirPtr[].
/// Window SoA lives in per-macro chunks and is loaded only when needed.
class _TermHead {
  final int termId;
  final int df;
  final List<WmbpChampionPosting> champion;

  /// Per-macro max impact for O(1) Stage-2 macro pruning (Root Head).
  final Uint8List macroMaxImpacts;
  final Uint32List macroDirPages;
  final Uint32List macroDirOffsets;
  final Uint32List macroDirLengths;

  /// Loaded macro slices keyed by macroId (never force-load all).
  final Map<int, _TermMacroSlice> macros;

  int postPage;
  int postOffset;
  int postLength;

  _TermHead({
    required this.termId,
    required this.df,
    required this.champion,
    required this.macroMaxImpacts,
    required this.macroDirPages,
    required this.macroDirOffsets,
    required this.macroDirLengths,
    Map<int, _TermMacroSlice>? macros,
    this.postPage = -1,
    this.postOffset = 0,
    this.postLength = 0,
  }) : macros = macros ?? <int, _TermMacroSlice>{};

  int get macroCount => macroMaxImpacts.length;

  bool get hasMacroDirs =>
      macroDirPages.length == macroCount &&
      macroDirOffsets.length == macroCount &&
      macroDirLengths.length == macroCount;

  /// Window ids from *loaded* macros only (sorted by macroId).
  List<int> get windowIds {
    if (macros.isEmpty) return const <int>[];
    if (macros.length == 1) return macros.values.first.windowIds;
    final keys = macros.keys.toList()..sort();
    final out = <int>[];
    for (final m in keys) {
      out.addAll(macros[m]!.windowIds);
    }
    return out;
  }

  int macroMaxImpact(int macroId) {
    if (macroId < 0 || macroId >= macroMaxImpacts.length) return 0;
    return macroMaxImpacts[macroId];
  }

  /// Body ptr + maxImpact for [windowId] when its macro slice is resident.
  ({int page, int offset, int length, int maxImpact})? lookupWindow(
      int windowId) {
    final int m = WmbpConstants.macroIdOfWindow(windowId);
    final slice = macros[m];
    if (slice == null) return null;
    final int i = slice.indexOf(windowId);
    if (i < 0) return null;
    return (
      page: slice.bodyPages[i],
      offset: slice.bodyOffset[i],
      length: slice.bodyLength[i],
      maxImpact: slice.maxImpacts[i],
    );
  }

  /// Install a decoded macro slice (idempotent).
  void putMacro(int macroId, _TermMacroSlice slice) {
    macros[macroId] = slice;
  }

  /// Build an in-memory head from a complete windows map (commit / compact).
  factory _TermHead.fromWindowsMap({
    required int termId,
    required int df,
    required List<WmbpChampionPosting> champion,
    required Map<int, ({int page, int offset, int length, int maxImpact})>
        windows,
    required Uint8List macroMax,
    required Uint32List dirPages,
    required Uint32List dirOffsets,
    required Uint32List dirLengths,
    int postPage = -1,
    int postOffset = 0,
    int postLength = 0,
  }) {
    final byMacro = <int, List<int>>{};
    for (final id in windows.keys) {
      byMacro
          .putIfAbsent(WmbpConstants.macroIdOfWindow(id), () => <int>[])
          .add(id);
    }
    final macros = <int, _TermMacroSlice>{};
    for (final entry in byMacro.entries) {
      final ids = entry.value..sort();
      final n = ids.length;
      final maxQ = Uint8List(n);
      final pages = Uint32List(n);
      final offs = Uint32List(n);
      final lens = Uint32List(n);
      for (int i = 0; i < n; i++) {
        final w = windows[ids[i]]!;
        maxQ[i] = w.maxImpact;
        pages[i] = w.page;
        offs[i] = w.offset;
        lens[i] = w.length;
      }
      macros[entry.key] = _TermMacroSlice(
        windowIds: ids,
        maxImpacts: maxQ,
        bodyPages: pages,
        bodyOffset: offs,
        bodyLength: lens,
      );
    }
    return _TermHead(
      termId: termId,
      df: df,
      champion: champion,
      macroMaxImpacts: macroMax,
      macroDirPages: dirPages,
      macroDirOffsets: dirOffsets,
      macroDirLengths: dirLengths,
      macros: macros,
      postPage: postPage,
      postOffset: postOffset,
      postLength: postLength,
    );
  }
}

/// Paged sealed corpus. Pending documents stay outside this object.
class WmbpSealedView {
  final WmbpPageVolume volume;

  /// Allocation rotate threshold only - never used to map reads.
  final int maxPartitionFileSize;

  /// Frozen at first seal for dense `win`/`fwd` O(1) math only.
  int densePagesPerPartition;

  final int payloadCapacity;
  final int fwdSlotsPerPage;
  final int cacheBudgetBytes;
  late final TreeCache<Uint8List> _pages;
  late final TreeCache<int> _nameCache;
  late final TreeCache<_TermHead> _headCache;
  late final TreeCache<WmbpEncodedWindow> _windowCache;
  late final TreeCache<Uint32List> _maskCache;
  late final TreeCache<String> _fwdPkCache;
  late final TreeCache<int> _revPkCache;
  late final TreeCache<List<_IdRec>> _idPageCache;
  late final TreeCache<List<_NameRec>> _namePageCache;

  /// Decoded reverse-tree (PK -> docId) nodes keyed by rev page number.
  ///
  /// [lookupPk] runs once per inserted PK (index-manager deactivate + commit
  /// safety net). Re-decoding a 16KB leaf (hundreds of UTF-8 strings) per
  /// lookup made a 10K-doc seal spend seconds in lookups alone. Writes go
  /// through [_writeRevNode], which refreshes this cache with the new node.
  late final TreeCache<_RevNode> _revNodeCache;
  final Map<String, Future<Uint8List?>> _inFlight =
      <String, Future<Uint8List?>>{};

  int nextDocId = 0;
  int nextTermId = 1;
  int activeDocs = 0;

  /// Inclusive watermark: every window `<= sealedThroughWindowId` has no
  /// remaining OPEN_RAW bodies. `-1` means nothing has been background-sealed.
  int sealedThroughWindowId = -1;

  /// Magic for the closed-dirty **index** blob (kind 16). Text index is
  /// unreleased — no legacy mega-blob compatibility path.
  static const int _closedDirtyIndexMagic = 0x57444349; // 'WDCI'

  /// In-memory OPEN_RAW term sets (open window + closed windows being sealed).
  /// Closed durable state lives in [_closedDirtyIndex] as per-window blobs.
  final Map<int, Set<int>> _dirtyOpenRawByWindow = <int, Set<int>>{};

  /// Closed-window durable index: windowId → per-window term blob pointer.
  /// [_dirtySealPage]/[_dirtySealCount] store this small index on disk.
  final Map<int, _ClosedDirtyEntry> _closedDirtyIndex =
      <int, _ClosedDirtyEntry>{};
  int _dirtySealPage = 0;
  int _dirtySealCount = 0;
  bool _closedDirtyIndexDirty = false;

  int _openDirtySealPage = 0;
  int _openDirtySealCount = 0;

  /// When true, next [_writeAuxiliary] rewrites the small open-window dirty blob.
  bool _openDirtySealDirty = false;

  /// Resident `(window, term)` pairs currently held in [_dirtyOpenRawByWindow].
  int get dirtyOpenRawPairCount {
    var n = 0;
    for (final set in _dirtyOpenRawByWindow.values) {
      n += set.length;
    }
    return n;
  }

  /// True when closed OPEN_RAW promotion work remains (resident or on-disk).
  bool get hasClosedOpenRawDebt {
    final int open = _openWindowId;
    for (final e in _dirtyOpenRawByWindow.entries) {
      if (e.key < open && e.value.isNotEmpty) return true;
    }
    for (final entry in _closedDirtyIndex.values) {
      if (entry.page > 0 && entry.count > 0) return true;
      if (entry.blobDirty) return true;
    }
    return false;
  }

  /// Dirty OPEN_RAW term count for one window (0 if none resident).
  int dirtyOpenRawTermCount(int windowId) =>
      _dirtyOpenRawByWindow[windowId]?.length ?? 0;

  /// Total pages ever allocated in `post/` (stats / discover high-water).
  int _postPageCount = 0;
  int _postPartitionCount = 1;
  int _postNextPageNo = 0;
  int _postTailPage = -1;
  int _postTailUsed = 0;
  Uint8List? _postTailImage;
  bool _postTailDirty = false;

  int _fwdPageCount = 0;
  int _revPageCount = 0;
  int _revPartitionCount = 1;
  int _revNextPageNo = 0;
  int _revRoot = 0;
  int _revHeight = 0;
  int _dictPageCount = 1;
  int _dictPartitionCount = 1;

  /// Next local page in dict; page 0 is reserved for sealed meta.
  int _dictNextPageNo = 1;

  /// Contiguous dict runs freed by blob chain relocation. Session-local —
  /// not persisted; stops further orphan growth after reopen. Existing
  /// on-disk orphans need a rebuild/compact to reclaim.
  ///
  /// Only runs whose meta pointers are already durable may be allocated
  /// from; see [_dictPendingFreeRuns].
  final List<({int page, int count})> _dictFreeRuns =
      <({int page, int count})>[];

  /// Released blob runs waiting for sealed meta to land. Must not be handed
  /// out by [_allocDictRun] yet — otherwise a crash after overwrite but
  /// before meta flush would leave on-disk meta pointing at recycled pages.
  final List<({int page, int count})> _dictPendingFreeRuns =
      <({int page, int count})>[];

  /// Per-window live doc counts. `u32` so a full super-window (65536) fits.
  Uint32List _activeCounts = Uint32List(0);
  final List<_NameSkip> _nameSkips = <_NameSkip>[];

  /// Dense O(1) id-slot pages: `pageIndex = termId ~/ idRecSlotsPerPage`
  /// ? dict global page (-1 = unallocated).
  final List<int> _idPages = <int>[];
  int _summaryPage = 0;
  int _summaryCount = 0;

  /// Global dict page number per summaryValuesPerPage activeCounts chunk.
  final List<int> _summaryChunkPages = <int>[];
  int _nameSkipPage = 0;
  int _nameSkipCount = 0;
  int _idDirPage = 0;
  int _idDirCount = 0;
  bool _nameSkipsDirty = true;
  bool _idDirDirty = true;

  /// Long-PK overflow tail in `post/` (never `dict/`).
  int _fwdOvPage = -1;
  int _fwdOvUsed = 0;
  int inFlightDedupHits = 0;

  /// Monotonic write counter used to detect concurrent page overwrites while an
  /// async read is in flight, preventing stale reads from re-populating caches.
  int _writeGeneration = 0;

  /// TreeCache group+flat key - web-safe (no 32-bit shift packing).
  @pragma('vm:prefer-inline')
  static List<int> _winKey(int termId, int windowId) => <int>[termId, windowId];

  /// Height of the primary-key to docId tree. Zero means the tree is empty.
  int get revHeight => _revHeight;

  WmbpSealedView._(
    this.volume, {
    required this.maxPartitionFileSize,
    required this.densePagesPerPartition,
    int? cacheBudgetBytes,
  })  : payloadCapacity = volume.payloadBudget < WmbpConstants.safePayloadSize
            ? volume.payloadBudget
            : WmbpConstants.safePayloadSize,
        fwdSlotsPerPage = WmbpConstants.fwdDocsPerPage,
        cacheBudgetBytes = cacheBudgetBytes ?? WmbpConstants.cacheLruBytes {
    // Soft ceilings: ratios sum to 1.0 of [budget] (shared index envelope).
    // Protect floors are absolute (not budget-derived) so small budgets do not
    // collapse hot navigation to a few MB. Eviction priority (see
    // [evictCaches]): payload floors are lower so T1/T2 reclaim first;
    // search/flush navigation floors stay high so cold-read does not avalanche.
    final int budget =
        this.cacheBudgetBytes < (1 << 20) ? (1 << 20) : this.cacheBudgetBytes;
    const int protect50 = 50 << 20; // search-critical term heads
    const int protect32 = 32 << 20; // dict / rev navigation
    const int protect16 = 16 << 20; // payload / I/O fill / result maps
    int sliceMax(double ratio) {
      final n = (budget * ratio).round();
      return n < (256 << 10) ? (256 << 10) : n;
    }

    // Heap accounting: see [_tcHeap] — approximate so LRU ceilings bite; OS
    // low-memory remains the hard backstop (do not deepen for precision).
    _pages = TreeCache<Uint8List>(
      evictionMode: TreeCacheEvictionMode.lru,
      maxByteThreshold: sliceMax(0.12),
      minByteThreshold: protect16,
      sizeCalculator: _estimatePageBytes,
      debugLabel: 'wmbp-pages',
    );
    _nameCache = TreeCache<int>(
      evictionMode: TreeCacheEvictionMode.lru,
      maxByteThreshold: sliceMax(0.10),
      minByteThreshold: protect32,
      sizeCalculator: (_) => _tcEntryHeap + 48,
      debugLabel: 'wmbp-names',
    );
    _headCache = TreeCache<_TermHead>(
      evictionMode: TreeCacheEvictionMode.lru,
      maxByteThreshold: sliceMax(0.20),
      minByteThreshold: protect50,
      sizeCalculator: _estimateHeadBytes,
      debugLabel: 'wmbp-heads',
    );
    _windowCache = TreeCache<WmbpEncodedWindow>(
      evictionMode: TreeCacheEvictionMode.lru,
      maxByteThreshold: sliceMax(0.30),
      minByteThreshold: protect16,
      sizeCalculator: _estimateWindowBytes,
      debugLabel: 'wmbp-windows',
    );
    _maskCache = TreeCache<Uint32List>(
      evictionMode: TreeCacheEvictionMode.lru,
      maxByteThreshold: sliceMax(0.05),
      minByteThreshold: protect16,
      sizeCalculator: _estimateMaskBytes,
      debugLabel: 'wmbp-masks',
    );
    _fwdPkCache = TreeCache<String>(
      evictionMode: TreeCacheEvictionMode.lru,
      maxByteThreshold: sliceMax(0.08),
      minByteThreshold: protect16,
      sizeCalculator: _estimateFwdPkBytes,
      debugLabel: 'wmbp-fwd-pk',
    );
    _revPkCache = TreeCache<int>(
      evictionMode: TreeCacheEvictionMode.lru,
      maxByteThreshold: sliceMax(0.03),
      minByteThreshold: protect32,
      sizeCalculator: (_) => _tcEntryHeap + 64,
      debugLabel: 'wmbp-rev-pk',
    );
    _idPageCache = TreeCache<List<_IdRec>>(
      evictionMode: TreeCacheEvictionMode.lru,
      maxByteThreshold: sliceMax(0.03),
      minByteThreshold: protect32,
      sizeCalculator: (List<_IdRec> value) =>
          _tcHeap(payload: value.length * 48),
      debugLabel: 'wmbp-id-pages',
    );
    _namePageCache = TreeCache<List<_NameRec>>(
      evictionMode: TreeCacheEvictionMode.lru,
      maxByteThreshold: sliceMax(0.03),
      minByteThreshold: protect32,
      sizeCalculator: (List<_NameRec> value) {
        var payload = 0;
        for (final rec in value) {
          payload += 32 + _utf16(rec.name);
        }
        return _tcHeap(payload: payload);
      },
      debugLabel: 'wmbp-name-pages',
    );
    _revNodeCache = TreeCache<_RevNode>(
      evictionMode: TreeCacheEvictionMode.lru,
      maxByteThreshold: sliceMax(0.06),
      minByteThreshold: protect32,
      sizeCalculator: _estimateRevNodeBytes,
      debugLabel: 'wmbp-rev-nodes',
    );
  }

  // ---------------------------------------------------------------------------
  // TreeCache heap accounting (approximate)
  //
  //   accounted ≈ entryHeap + strings(UTF-16) + typed/payload bytes
  //
  // - entryHeap: fixed Dart Map/TreeCache tax per entry. Calibrated ~1KB from
  //   1.6M RSS isolation (names≈1933MB, fwd≈1654MB after ~660MB baseline).
  //   Independent of document text length.
  // - strings: length*2. Scales with PK / term length, not body text.
  // - typed/payload: page bytes, mask bitmap, window offsets/impacts/presence,
  //   head macro dirs. Longer docs → denser postings → larger windows/heads;
  //   those buffers grow here automatically.
  //
  // Good enough for LRU ceilings + ResourceManager; OS critical is the safety
  // net. Do not add deep walks or per-field micro-accounting on the hot path.
  // ---------------------------------------------------------------------------

  static const int _tcEntryHeap = 896;

  @pragma('vm:prefer-inline')
  static int _utf16(String s) => s.length * 2;

  @pragma('vm:prefer-inline')
  static int _tcHeap({int payload = 0}) => _tcEntryHeap + payload;

  static int _nameEntryBytes(String name) =>
      _tcHeap(payload: 32 + _utf16(name));

  static int _fwdPkEntryBytes(String pk) => _tcHeap(payload: 48 + _utf16(pk));

  static int _revPkEntryBytes(String pk) => _tcHeap(payload: 48 + _utf16(pk));

  static int _estimatePageBytes(Uint8List page) =>
      _tcHeap(payload: 64 + page.length);

  static int _estimateMaskBytes(Uint32List words) =>
      _tcHeap(payload: words.lengthInBytes);

  static int _estimateFwdPkBytes(String pk) => _fwdPkEntryBytes(pk);

  static int _estimateRevNodeBytes(_RevNode node) {
    var payload = 64;
    if (node.leaf) {
      for (final rec in node.records) {
        payload += 64 + _utf16(rec.pk);
      }
      return _tcHeap(payload: payload);
    }
    payload += node.children.length * 16;
    for (final sep in node.separators) {
      payload += 48 + _utf16(sep);
    }
    return _tcHeap(payload: payload);
  }

  static int _estimateHeadBytes(_TermHead head) {
    // Champion/macro graph; denser terms (long docs) load more macro slices.
    var payload = 192 +
        head.champion.length * 40 +
        head.macroMaxImpacts.lengthInBytes +
        head.macroDirPages.lengthInBytes +
        head.macroDirOffsets.lengthInBytes +
        head.macroDirLengths.lengthInBytes;
    payload += head.macros.length * 96;
    for (final slice in head.macros.values) {
      payload += 48 +
          slice.windowIds.length * 8 +
          slice.maxImpacts.lengthInBytes +
          slice.bodyPages.lengthInBytes +
          slice.bodyOffset.lengthInBytes +
          slice.bodyLength.lengthInBytes;
    }
    return _tcHeap(payload: payload);
  }

  static int _estimateWindowBytes(WmbpEncodedWindow win) {
    // Posting density scales with DF in the super-window (long docs → larger).
    final payload = 96 +
        win.allocatedOffsetsBytes +
        win.impacts.lengthInBytes +
        (win.presence?.lengthInBytes ?? 0) +
        win.blocks.length * 48;
    return _tcHeap(payload: payload);
  }

  static Future<WmbpSealedView> open(
    WmbpPageVolume volume, {
    required int maxPartitionFileSize,
    required int densePagesPerPartition,
    int? cacheBudgetBytes,
  }) async {
    final int maxBytes = maxPartitionFileSize < WmbpConstants.storePageSize
        ? WmbpConstants.storePageSize
        : maxPartitionFileSize;
    final int denseHint =
        densePagesPerPartition < 1 ? 1 : densePagesPerPartition;
    final view = WmbpSealedView._(
      volume,
      maxPartitionFileSize: maxBytes,
      densePagesPerPartition: denseHint,
      cacheBudgetBytes: cacheBudgetBytes,
    );
    await view._loadMeta();
    if (view.densePagesPerPartition != denseHint) {
      Logger.warn(
        'WMBP densePagesPerPartition frozen at ${view.densePagesPerPartition} '
        '(config hint $denseHint); win/fwd layout unchanged',
      );
    }
    return view;
  }

  /// Maps a category page ref to physical (partition, localPage).
  ///
  /// `win`/`fwd`: dense logical id - [densePagesPerPartition].
  /// Others: packed [WmbpPagePtr].
  @pragma('vm:prefer-inline')
  (int partition, int local) _physical(String category, int pageRef) {
    if (category == 'win' || category == 'fwd') {
      final int ppp = densePagesPerPartition < 1 ? 1 : densePagesPerPartition;
      if (pageRef < 0) return (-1, -1);
      return (pageRef ~/ ppp, pageRef % ppp);
    }
    return WmbpPagePtr.unpack(pageRef);
  }

  /// Tiered LRU trim under memory pressure (mirror of [prewarmCaches] order).
  ///
  /// Low-priority payload first; search/flush navigation last. After each
  /// tier, [shouldContinue] may stop further reclaim so hot nav stays resident.
  /// When [protectFlushNav] is true (active flush), reverse-map caches are
  /// skipped entirely.
  Future<void> evictCaches({
    required double ratio,
    Future<bool> Function()? shouldContinue,
    bool protectFlushNav = false,
  }) async {
    if (ratio <= 0.0) return;

    Future<bool> stillNeed() async {
      if (shouldContinue == null) return true;
      return shouldContinue();
    }

    // T1 — search payload (post window bodies + raw page I/O fill).
    await _windowCache.cleanup(removeRatio: ratio);
    if (!await stillNeed()) return;
    await _pages.cleanup(removeRatio: ratio);
    if (!await stillNeed()) return;

    // T2 — result map (docId → PK); scoring does not need it.
    await _fwdPkCache.cleanup(removeRatio: ratio);
    if (!await stillNeed()) return;

    // T3 — search navigation (term heads, dict id/name pages).
    await _headCache.cleanup(removeRatio: ratio);
    if (!await stillNeed()) return;
    await _idPageCache.cleanup(removeRatio: ratio);
    if (!await stillNeed()) return;
    await _nameCache.cleanup(removeRatio: ratio);
    if (!await stillNeed()) return;
    await _namePageCache.cleanup(removeRatio: ratio);
    if (!await stillNeed()) return;

    // T4 — active masks (tiny; only if still under pressure).
    await _maskCache.cleanup(removeRatio: ratio);
    if (!await stillNeed()) return;

    // T5 — flush / seal navigation (PK → docId); last and flush-protected.
    if (protectFlushNav) return;
    await _revPkCache.cleanup(removeRatio: ratio);
    if (!await stillNeed()) return;
    await _revNodeCache.cleanup(removeRatio: ratio);
  }

  int get _structuredCacheSizeBytes =>
      _nameCache.estimatedTotalSizeBytes +
      _headCache.estimatedTotalSizeBytes +
      _windowCache.estimatedTotalSizeBytes +
      _maskCache.estimatedTotalSizeBytes +
      _fwdPkCache.estimatedTotalSizeBytes +
      _revPkCache.estimatedTotalSizeBytes +
      _idPageCache.estimatedTotalSizeBytes +
      _namePageCache.estimatedTotalSizeBytes +
      _revNodeCache.estimatedTotalSizeBytes;

  int? _firstWarmTermId;

  /// First termId warmed into [_headCache] during [prewarmCaches], if any.
  int? get firstWarmTermId => _firstWarmTermId;

  /// Approximate resident bytes for shared index-budget accounting (O(1)).
  int get estimatedCacheSizeBytes =>
      _pages.estimatedTotalSizeBytes + _structuredCacheSizeBytes;

  /// Coarse on-disk footprint from durable page high-water marks (O(1)).
  int get estimatedDiskBytes {
    final pages = pageCountOf('dict') +
        pageCountOf('post') +
        pageCountOf('fwd') +
        pageCountOf('rev') +
        pageCountOf('win');
    return pages * WmbpConstants.storePageSize;
  }

  /// Fill search-hot caches until [ledger] is exhausted.
  ///
  /// [ledger] is the shared B+Tree+WMBP warm ceiling — charges are monotonic
  /// so ResourceManager / TreeCache eviction cannot reopen the budget and
  /// resume colder loads. When [navOnly] (or corpus &gt; budget×1.5), only
  /// navigation / metadata is warmed (names, id pages, masks, rev internals).
  Future<int> prewarmCaches({
    required PrewarmBudgetLedger ledger,
    bool navOnly = false,
    bool Function()? shouldAbort,
  }) async {
    if (ledger.capBytes <= 0 || nextTermId <= 1) return 0;
    bool aborted() => shouldAbort?.call() ?? false;
    if (aborted() || ledger.isExhausted) return 0;

    final int before = _structuredCacheSizeBytes;
    final payloadWorthless = navOnly ||
        isPrewarmPayloadWorthless(
          dataBytes: estimatedDiskBytes,
          budgetBytes: ledger.capBytes,
        );

    bool overBudget() => ledger.isExhausted;

    // Charge before a load; latch stop when the estimate no longer fits.
    bool charge(int est) {
      if (est <= 0) return !ledger.isExhausted;
      return ledger.tryCharge(est);
    }

    // 1) Dictionary names - TreeCache (query compile / sync resolve path).
    final int nameCacheCap = (_nameCache.maxByteThreshold * 0.90).round();
    for (int si = 0; si < _nameSkips.length; si++) {
      if (aborted() ||
          overBudget() ||
          _nameCache.estimatedTotalSizeBytes >= nameCacheCap) {
        break;
      }
      final skip = _nameSkips[si];
      try {
        final recs = await _readNamePage(skip.page);
        for (int ri = 0; ri < recs.length; ri++) {
          if (aborted() ||
              overBudget() ||
              _nameCache.estimatedTotalSizeBytes >= nameCacheCap) {
            break;
          }
          final rec = recs[ri];
          if (_nameCache.get(rec.name) != null) continue;
          final est = _nameEntryBytes(rec.name);
          if (!charge(est)) break;
          _nameCache.put(rec.name, rec.termId, size: est);
        }
      } catch (_) {
        continue;
      }
    }

    // 2) Active window masks (8KB per 65,536 docs - required for sync scoring).
    final int maskCacheCap = (_maskCache.maxByteThreshold * 0.90).round();
    for (int winId = 0; winId < _activeCounts.length; winId++) {
      if (aborted() ||
          overBudget() ||
          _maskCache.estimatedTotalSizeBytes >= maskCacheCap) {
        break;
      }
      if (_activeCounts[winId] <= 0) continue;
      if (_maskCache.containsKey(winId)) continue;
      try {
        if (!charge(WmbpConstants.activeMaskBytes + 32)) break;
        await _rememberMask(winId);
      } catch (_) {
        continue;
      }
    }

    // 3) Reverse PK B+Tree — navigation. Cap upfront PK share so postings
    // (when allowed) still get most of a medium-corpus budget.
    final int pkShareCeiling =
        ledger.committedBytes + (ledger.remainingBytes * 0.35).round();
    bool overUpfrontPkBudget() =>
        overBudget() || ledger.committedBytes >= pkShareCeiling;

    Future<bool> chargeRevOrFwd(int est) async {
      if (overUpfrontPkBudget()) return false;
      return charge(est);
    }

    var revFullyWarmed = _revHeight <= 0;
    if (!aborted() && !overUpfrontPkBudget() && _revHeight > 0) {
      revFullyWarmed = await _warmRevPagesBudgeted(
        aborted: aborted,
        overBudget: overUpfrontPkBudget,
        tryCharge: chargeRevOrFwd,
      );
    }

    // Fwd bulk is payload-ish; skip when navOnly / worthless corpus.
    var fwdNextPage = 0;
    if (!payloadWorthless &&
        !aborted() &&
        !overUpfrontPkBudget() &&
        _fwdPageCount > 0) {
      fwdNextPage = await _warmFwdPagesBudgeted(
        startPage: 0,
        aborted: aborted,
        overBudget: overUpfrontPkBudget,
        tryCharge: chargeRevOrFwd,
      );
    }

    // 4) Id-page catalog (term → post pointer). Budgeted; needed for nav and
    // for ranking hottest terms when payload warm is allowed.
    final terms = <_IdRec>[];
    final int idPageCount = _idPages.length;
    final int idPageCap = (_idPageCache.maxByteThreshold * 0.90).round();
    for (int pageIndex = 0; pageIndex < idPageCount; pageIndex++) {
      if (aborted() || overBudget()) break;
      if (_idPageCache.estimatedTotalSizeBytes >= idPageCap) break;
      if (pageIndex >= _idPages.length) break;
      final int page = _idPages[pageIndex];
      if (page < 0) continue;
      if (_idPageCache.get(page) != null) {
        final cached = _idPageCache.get(page)!;
        terms.addAll(cached);
        continue;
      }
      try {
        if (!charge(WmbpConstants.storePageSize)) break;
        terms.addAll(await _readIdPageSlots(page, pageIndex));
      } catch (_) {
        continue;
      }
    }

    if (payloadWorthless) {
      // Nav/metadata only for this corpus — do not latch the shared ledger so
      // other smaller indexes in the same Phase 2 pass can still fill payload.
      _pages.clear();
      return math.max(0, _structuredCacheSizeBytes - before);
    }

    terms.sort((a, b) {
      final int cmpDf = b.df.compareTo(a.df);
      if (cmpDf != 0) return cmpDf;
      final int cmpPage = a.postPage.compareTo(b.postPage);
      if (cmpPage != 0) return cmpPage;
      return a.postOffset.compareTo(b.postOffset);
    });

    // 5) Hottest postings: head + macros + windows.
    final int headCacheCap = (_headCache.maxByteThreshold * 0.90).round();
    final int windowCacheCap = (_windowCache.maxByteThreshold * 0.90).round();
    bool overPostSubCacheCap() =>
        _headCache.estimatedTotalSizeBytes >= headCacheCap ||
        _windowCache.estimatedTotalSizeBytes >= windowCacheCap;

    final yieldController = YieldController(
      'WmbpSealedView.prewarmCaches',
      checkInterval: 256,
      minCheckInterval: 64,
    );
    for (final rec in terms) {
      if (aborted() || overBudget() || overPostSubCacheCap()) break;
      if (rec.postPage < 0) continue;
      try {
        var head = _headCache.get(rec.termId);
        if (head == null) {
          final headEst = math.max(64, rec.postLength);
          if (!charge(headEst)) break;
          final syncHeadBytes = _tryReadPayloadRangeSync(
            'post',
            rec.postPage,
            rec.postOffset,
            rec.postLength,
          );
          if (syncHeadBytes != null) {
            head = _decodeHeadBytes(
              syncHeadBytes,
              rec.postPage,
              rec.postOffset,
              rec.postLength,
            );
          } else {
            head = await _readHead(
              rec.postPage,
              rec.postOffset,
              rec.postLength,
            );
            yieldController.reset();
          }
          _putHeadCache(rec.termId, head);
          _firstWarmTermId ??= rec.termId;
        }
        final macroOrder = _macroWarmOrder(head);
        for (final int m in macroOrder) {
          if (aborted() || overBudget() || overPostSubCacheCap()) break;
          final int dirLen = (m >= 0 && m < head.macroDirLengths.length)
              ? head.macroDirLengths[m]
              : 0;
          if (!head.macros.containsKey(m) && dirLen > 0 && !charge(dirLen)) {
            break;
          }
          await _ensureMacro(head, m);
          // Macros mutate head in place — re-put so TreeCache byte estimate
          // tracks the expanded directory (avoids under-count thrash).
          _putHeadCache(rec.termId, head);
          final slice = head.macros[m];
          if (slice == null) continue;
          for (int wi = 0; wi < slice.windowIds.length; wi++) {
            if (aborted() || overBudget() || overPostSubCacheCap()) break;
            final int winId = slice.windowIds[wi];
            if (!_rememberMaskSync(winId)) {
              if (!charge(WmbpConstants.activeMaskBytes + 32)) break;
              await _rememberMask(winId);
              yieldController.reset();
            }
            final key = _winKey(rec.termId, winId);
            if (!_windowCache.containsKey(key)) {
              final int len = slice.bodyLength[wi];
              if (len > 0) {
                if (!charge(len + 64)) break;
                final int bodyPage = slice.bodyPages[wi];
                final int bodyOff = slice.bodyOffset[wi];
                var bytes =
                    _tryReadPayloadRangeSync('post', bodyPage, bodyOff, len);
                if (bytes == null) {
                  bytes =
                      await _readPayloadRange('post', bodyPage, bodyOff, len);
                  yieldController.reset();
                }
                _putWindowCache(key, WmbpEncodedWindow.fromBytes(bytes));
              }
            }
            final y = yieldController.maybeYield();
            if (y != null) await y;
          }
        }
      } catch (_) {
        continue;
      }
    }

    // Drop raw page buffers so they do not double-count residency — ledger
    // already charged structured warm and must not resume after clear.
    _pages.clear();

    // 6) Leftover ledger only (not live residency after clear).
    if (!aborted() && !overBudget() && !revFullyWarmed && _revHeight > 0) {
      await _warmRevPagesBudgeted(
        aborted: aborted,
        overBudget: overBudget,
        tryCharge: (est) async => charge(est),
      );
    }
    if (!aborted() && !overBudget() && fwdNextPage < _fwdPageCount) {
      await _warmFwdPagesBudgeted(
        startPage: fwdNextPage,
        aborted: aborted,
        overBudget: overBudget,
        tryCharge: (est) async => charge(est),
      );
    }
    _pages.clear();

    return math.max(0, _structuredCacheSizeBytes - before);
  }

  void _putHeadCache(int termId, _TermHead head) =>
      _headCache.put(termId, head, size: _estimateHeadBytes(head));

  void _putWindowCache(List<int> key, WmbpEncodedWindow window) =>
      _windowCache.put(key, window, size: _estimateWindowBytes(window));

  void _rememberRevPk(String pk, int docId) =>
      _revPkCache.put(pk, docId, size: _revPkEntryBytes(pk));

  void _forgetRevPk(String pk) => _revPkCache.remove(pk);

  void _rememberFwdPk(int docId, String pk) =>
      _fwdPkCache.put(docId, pk, size: _fwdPkEntryBytes(pk));

  void _rememberIdPageCache(int page, List<_IdRec> recs) =>
      _idPageCache.put(page, recs);

  void _rememberNamePageCache(int page, List<_NameRec> recs) =>
      _namePageCache.put(page, recs);

  void _putMaskCache(int windowId, Uint32List words) =>
      _maskCache.put(windowId, words, size: _estimateMaskBytes(words));

  int sealedActiveCount(int windowId) {
    if (windowId < 0 || windowId >= _activeCounts.length) return 0;
    return _activeCounts[windowId];
  }

  /// Durable global page count for [category] (meta / allocation high-water).
  ///
  /// `win/` uses one ActiveMask page per super-window, so the bound is derived
  /// from [nextDocId] rather than a dedicated counter.
  int pageCountOf(String category) {
    switch (category) {
      case 'dict':
        return _dictPageCount < 0 ? 0 : _dictPageCount;
      case 'post':
        return _postPageCount < 0 ? 0 : _postPageCount;
      case 'fwd':
        return _fwdPageCount < 0 ? 0 : _fwdPageCount;
      case 'rev':
        return _revPageCount < 0 ? 0 : _revPageCount;
      case 'win':
        if (nextDocId <= 0) return 0;
        return WmbpConstants.windowIdOf(nextDocId - 1) + 1;
      default:
        return 0;
    }
  }

  /// Exclusive upper bound on partition numbers that may exist for [category].
  ///
  /// Packed categories expose allocator [partitionCount]; dense `win`/`fwd` use
  /// `ceil(pageCount / densePagesPerPartition)`. Key rewrite uses this O(1).
  int partitionCountExclusive(String category) {
    switch (category) {
      case 'post':
        return _postPageCount <= 0 ? 0 : _postPartitionCount;
      case 'dict':
        return _dictPageCount <= 0 ? 0 : _dictPartitionCount;
      case 'rev':
        return _revPageCount <= 0 ? 0 : _revPartitionCount;
      case 'fwd':
      case 'win':
        final int pages = pageCountOf(category);
        if (pages <= 0) return 0;
        final int ppp = densePagesPerPartition < 1 ? 1 : densePagesPerPartition;
        return (pages + ppp - 1) ~/ ppp;
      default:
        return 0;
    }
  }

  int? cachedName(String term) => _nameCache.get(term);

  /// Heads exposed atomically at publish time before they are drained into
  /// [_headCache] (so large batches can yield while copying into the LRU).
  Map<int, _TermHead>? _publishOverlay;

  _TermHead? _loadedHead(int termId) =>
      _publishOverlay?[termId] ?? _headCache.get(termId);

  int loadedDf(int termId) => _loadedHead(termId)?.df ?? 0;

  List<int> loadedWindowIds(int termId) =>
      _loadedHead(termId)?.windowIds ?? const <int>[];

  int loadedMacroCount(int termId) => _loadedHead(termId)?.macroCount ?? 0;

  int loadedMacroMaxImpact(int termId, int macroId) =>
      _loadedHead(termId)?.macroMaxImpact(macroId) ?? 0;

  List<int> loadedWindowIdsOfMacro(int termId, int macroId) =>
      _loadedHead(termId)?.macros[macroId]?.windowIds ?? const <int>[];

  int loadedMaxImpact(int termId, int windowId) {
    final head = _loadedHead(termId);
    if (head == null) return 0;
    return head.lookupWindow(windowId)?.maxImpact ?? 0;
  }

  List<WmbpChampionPosting> loadedChampions(int termId) =>
      _loadedHead(termId)?.champion ?? const <WmbpChampionPosting>[];

  WmbpEncodedWindow? loadedWindow(int termId, int windowId) =>
      _windowCache.get(_winKey(termId, windowId));

  bool? loadedActiveBit(int docId) {
    final int windowId = WmbpConstants.windowIdOf(docId);
    final mask = _maskCache.get(windowId);
    if (mask == null) return null;
    final int offset = WmbpConstants.docOffsetOf(docId);
    final int word = mask[offset >> 5];
    return (word & (1 << (offset & 31))) != 0;
  }

  String? loadedPrimaryKey(int docId) => _fwdPkCache.get(docId);

  bool hasHead(int termId) => _loadedHead(termId) != null;

  bool ensureHeadSync(int termId) => _loadedHead(termId) != null;

  bool _rememberMaskSync(int windowId) => _maskCache.containsKey(windowId);

  bool ensureWindowSync(int termId, int windowId) {
    if (!_rememberMaskSync(windowId)) return false;
    final key = _winKey(termId, windowId);
    if (_windowCache.containsKey(key)) return true;
    // Opportunistic sync materialize when head + macro + raw pages are hot
    // (avoids sync?async escalate after a prior page-touching search).
    final head = _loadedHead(termId);
    if (head == null) return false;
    final int macroId = WmbpConstants.macroIdOfWindow(windowId);
    if (!_tryEnsureMacroSync(head, macroId)) return false;
    final loc = head.lookupWindow(windowId);
    if (loc == null || loc.length <= 0) return true;
    final bytes = _tryReadPayloadRangeSync(
      'post',
      loc.page,
      loc.offset,
      loc.length,
    );
    if (bytes == null) return false;
    _putWindowCache(key, WmbpEncodedWindow.fromBytes(bytes));
    return true;
  }

  Future<Uint8List?> loadPage(String category, int globalPage) {
    return _readGlobal(category, globalPage);
  }

  Future<int?> lookupName(String term) async {
    final cached = _nameCache.get(term);
    if (cached != null) return cached;
    final int skip = _rightmostName(term);
    if (skip < 0) return null;
    final recs = await _readNamePage(_nameSkips[skip].page);
    return _binarySearchName(recs, term);
  }

  /// Resident / sync-disk dictionary probe for the upsert hot path.
  ///
  /// Returns the durable term id when the name page is already cached or the
  /// volume supports [WmbpPageVolume.readAtSync]. A null result means "not
  /// known synchronously" — callers must not mint a parallel id without an
  /// async [lookupName] (cold remints orphan the historical posting chain).
  int? lookupNameSync(String term) {
    final cached = _nameCache.get(term);
    if (cached != null) return cached;
    final int skip = _rightmostName(term);
    if (skip < 0) return null;
    final int page = _nameSkips[skip].page;
    final pageCached = _namePageCache.get(page);
    if (pageCached != null) {
      return _binarySearchName(pageCached, term);
    }
    final pageBytes = _readGlobalSync('dict', page);
    if (pageBytes == null) return null;
    final recs = _decodeNamePageBytes(pageBytes);
    _rememberNamePageCache(page, recs);
    return _binarySearchName(recs, term);
  }

  int? _binarySearchName(List<_NameRec> recs, String term) {
    var lo = 0;
    var hi = recs.length - 1;
    while (lo <= hi) {
      final int mid = (lo + hi) >> 1;
      final int cmp = recs[mid].name.compareTo(term);
      if (cmp == 0) {
        final int foundId = recs[mid].termId;
        _nameCache.put(term, foundId, size: _nameEntryBytes(term));
        return foundId;
      }
      if (cmp < 0) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return null;
  }

  int? cachedLookupPk(String pk) => _revPkCache.get(pk);

  /// Sentinel from [lookupPkResident]: a rev node on the path is not
  /// resident, so the caller must fall back to the async [lookupPk].
  static const int revLookupNeedsIo = -2;

  /// Resolves [pk] through resident rev nodes only - no await, no I/O.
  ///
  /// Returns the docId, `-1` for a definite miss, or [revLookupNeedsIo].
  int lookupPkResident(String pk) {
    final cached = _revPkCache.get(pk);
    if (cached != null) return cached;
    if (_revHeight == 0) return -1;
    var page = _revRoot;
    for (int depth = 0; depth < _revHeight; depth++) {
      final node = _readRevNodeSync(page);
      if (node == null) return revLookupNeedsIo;
      if (node.leaf) return _resolveLeafPk(pk, node);
      page = _revChild(pk, node);
    }
    return -1;
  }

  /// Binary search inside a sorted rev leaf; remembers hits in [_revPkCache].
  int _resolveLeafPk(String pk, _RevNode leaf) {
    final recs = leaf.records;
    var lo = 0;
    var hi = recs.length - 1;
    while (lo <= hi) {
      final int mid = (lo + hi) >> 1;
      final int cmp = recs[mid].pk.compareTo(pk);
      if (cmp == 0) {
        final int docId = recs[mid].docId;
        _rememberRevPk(pk, docId);
        return docId;
      }
      if (cmp < 0) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return -1;
  }

  Future<int?> lookupPk(String pk) async {
    final int resident = lookupPkResident(pk);
    if (resident != revLookupNeedsIo) return resident < 0 ? null : resident;
    var page = _revRoot;
    for (int depth = 0; depth < _revHeight; depth++) {
      final node = await _readRevNode(page);
      if (node.leaf) {
        final int docId = _resolveLeafPk(pk, node);
        return docId < 0 ? null : docId;
      }
      page = _revChild(pk, node);
    }
    return null;
  }

  Future<void> loadHead(int termId) async {
    final overlay = _publishOverlay?[termId];
    if (overlay != null) {
      _putHeadCache(termId, overlay);
      return;
    }
    if (_headCache.containsKey(termId)) return;
    final rec = await _findId(termId);
    if (rec == null || rec.postPage < 0) return;
    final head = await _readHead(
      rec.postPage,
      rec.postOffset,
      rec.postLength,
    );
    _putHeadCache(termId, head);
  }

  /// Hottest-first macro ids with a non-empty dir (for budgeted warm).
  static List<int> _macroWarmOrder(_TermHead head) {
    final n = head.macroCount;
    if (n <= 0 || !head.hasMacroDirs) return const <int>[];
    final ids = <int>[];
    for (int m = 0; m < n; m++) {
      if (head.macroDirLengths[m] > 0) ids.add(m);
    }
    if (ids.length <= 1) return ids;
    ids.sort((a, b) {
      final int byQ =
          head.macroMaxImpacts[b].compareTo(head.macroMaxImpacts[a]);
      if (byQ != 0) return byQ;
      return a.compareTo(b);
    });
    return ids;
  }

  /// Load one macro directory chunk into [head.macros] (no-op if resident).
  Future<void> _ensureMacro(_TermHead head, int macroId) async {
    if (_tryEnsureMacroSync(head, macroId)) return;
    if (macroId < 0 || macroId >= head.macroCount) return;
    if (!head.hasMacroDirs) return;
    final int len = head.macroDirLengths[macroId];
    if (len <= 0) return;
    final chunk = await _readPayloadRange(
      'post',
      head.macroDirPages[macroId],
      head.macroDirOffsets[macroId],
      len,
    );
    head.putMacro(macroId, _decodeMacroSlice(chunk));
  }

  /// Resident-only macro materialize: already decoded, empty dir, or raw page
  /// still in [_pages] / post-tail. Never performs async I/O.
  bool _tryEnsureMacroSync(_TermHead head, int macroId) {
    if (macroId < 0 || macroId >= head.macroCount) return true;
    if (head.macros.containsKey(macroId)) return true;
    if (!head.hasMacroDirs) return true;
    final int len = head.macroDirLengths[macroId];
    if (len <= 0) return true;
    final chunk = _tryReadPayloadRangeSync(
      'post',
      head.macroDirPages[macroId],
      head.macroDirOffsets[macroId],
      len,
    );
    if (chunk == null) return false;
    head.putMacro(macroId, _decodeMacroSlice(chunk));
    return true;
  }

  /// Sync search gate: true when the macro slice is usable without await.
  bool ensureMacroSync(int termId, int macroId) {
    final head = _loadedHead(termId);
    if (head == null) return false;
    return _tryEnsureMacroSync(head, macroId);
  }

  Future<void> ensureMacroForTerm(int termId, int macroId) async {
    if (!ensureHeadSync(termId)) {
      await loadHead(termId);
    }
    final head = _loadedHead(termId);
    if (head == null) return;
    await _ensureMacro(head, macroId);
  }

  /// Expand every macro with a non-empty dir ptr (GC / rare full reads).
  Future<void> _ensureAllMacros(_TermHead head) async {
    for (int m = 0; m < head.macroCount; m++) {
      if (head.macroDirLengths[m] > 0) {
        await _ensureMacro(head, m);
      }
    }
  }

  Future<void> ensureWindow(int termId, int windowId) async {
    if (!_rememberMaskSync(windowId)) {
      await _rememberMask(windowId);
    }
    final key = _winKey(termId, windowId);
    if (_windowCache.containsKey(key)) return;
    if (!ensureHeadSync(termId)) {
      await loadHead(termId);
    }
    final head = _loadedHead(termId);
    if (head == null) return;
    final int macroId = WmbpConstants.macroIdOfWindow(windowId);
    await _ensureMacro(head, macroId);
    final loc = head.lookupWindow(windowId);
    if (loc == null || loc.length <= 0) return;
    final syncBytes = _tryReadPayloadRangeSync(
      'post',
      loc.page,
      loc.offset,
      loc.length,
    );
    final bytes = syncBytes ??
        await _readPayloadRange(
          'post',
          loc.page,
          loc.offset,
          loc.length,
        );
    _putWindowCache(key, WmbpEncodedWindow.fromBytes(bytes));
  }

  Future<String?> lookupFwd(int docId) => _lookupFwd(docId);

  Future<int> windowPairCount(int termId, int windowId) async {
    final rec = await _findId(termId);
    if (rec == null) return 0;
    final image = await _readTerm(rec.postPage, rec.postOffset, rec.postLength);
    return image.windows[windowId]?.offsets.length ?? 0;
  }

  /// Seals [batch] onto durable pages.
  ///
  /// [handoff] runs after pages are durable. It must:
  /// 1. Install corpus compensation for the dual-layer handoff
  /// 2. Call [publish] (sync, O(windows)+O(1) overlay install)
  /// 3. Chunk-evict the local overlay with yields
  ///
  /// Search stays correct across yields via compensation + [_publishOverlay].
  Future<void> commit(
    WmbpCommitBatch batch, {
    required Future<void> Function({
      required List<int> deactivated,
      required void Function() publish,
    }) handoff,
  }) async {
    // Defer nextDocId / open-window advance until AFTER posting writes so a
    // cross-window batch can still appendOpenRaw into the previous live window.
    // Sync full-vocab OPEN_RAW→I/II/III seal is forbidden on this path (10B
    // scale): closed windows stay searchable as state 0 until dirty-only
    // background seal catches up.
    final int pendingNextDocId =
        batch.nextDocId > nextDocId ? batch.nextDocId : nextDocId;
    final int pendingNextTermId =
        batch.nextTermId > nextTermId ? batch.nextTermId : nextTermId;
    final deactivated = <int>[...batch.deactivated];
    final deactivatedSet = deactivated.toSet();
    // One coarse YC for the whole seal CPU path: tick on posting-scale work
    // (byTerm + per-term merges). Do not create per-phase controllers - each
    // adds park/check overhead for tiny loops that barely move the UI needle.
    final commitYc = YieldController(
      'wmbp_commit',
      checkInterval: 512,
      minCheckInterval: 128,
    );
    // PK overwrite discovery is folded into [_applyRev] (ordered leaf merge).
    // Do not run N unordered async lookupPk probes here.
    // Fast in-order check (O(N) integer comparisons, ~0.01ms on 10K docs).
    // Avoids sort closure overhead completely on sequential inserts while
    // safely catching and correcting any out-of-order ingestions.
    if (batch.added.length > 1) {
      var isSorted = true;
      for (int i = 1; i < batch.added.length; i++) {
        if (batch.added[i - 1].docId > batch.added[i].docId) {
          isSorted = false;
          break;
        }
      }
      if (!isSorted) {
        batch.added.sort((a, b) => a.docId.compareTo(b.docId));
      }
    }

    // Flat TypedData postings - eliminates millions of (docId, q8) Record
    // allocations and GC pauses on large document collections.
    // Uses 32-bit delta offsets against [baseDocId] to support 10B+ documents
    final byTerm = <int, _TermPostings>{};
    final int baseDocId = batch.added.isNotEmpty ? batch.added.first.docId : 0;
    final int firstDocId = baseDocId;
    final int lastDocId = batch.added.isNotEmpty ? batch.added.last.docId : 0;
    final bool isSingleWindow = batch.added.isNotEmpty &&
        (WmbpConstants.windowIdOf(firstDocId) ==
            WmbpConstants.windowIdOf(lastDocId));
    final int singleWinId = WmbpConstants.windowIdOf(firstDocId);

    int docCounter = 0;
    for (final doc in batch.added) {
      if ((++docCounter & 0xFF) == 0) {
        final y = commitYc.maybeYield();
        if (y != null) await y;
      }
      final int docId = doc.docId;
      final int delta = docId - baseDocId;
      if (delta < 0 || delta > 0xFFFFFFFF) {
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message:
                'WMBP delta docId out of 32-bit range: delta=$delta, base=$baseDocId, docId=$docId',
          ),
        ]);
      }
      for (final entry in doc.impacts.entries) {
        (byTerm[entry.key] ??= _TermPostings()).add(delta, entry.value);
      }
      // Defer _addActive until the publish barrier -otherwise
      // activeCountOf double-subtracts against corpus _inactiveWindows.
      _rememberFwdPk(docId, doc.primaryKey);
      _rememberRevPk(doc.primaryKey, docId);
    }
    for (final pk in batch.removedPks) {
      _forgetRevPk(pk);
    }
    // Defer _subActive / activeDocs / head-cache until the sync barrier.

    final idUpdates = <_IdRec>[];
    final nameUpdates = <_NameRec>[];
    final publishHeads = <int, _TermHead>{};

    if (_postTailPage >= 0 && _postTailImage == null) {
      final existing = await _readGlobal('post', _postTailPage);
      if (existing != null) {
        final image = Uint8List(WmbpConstants.storePageSize);
        final int n =
            existing.length < image.length ? existing.length : image.length;
        image.setRange(0, n, existing);
        _postTailImage = image;
      }
    }
    if (_postTailPage < 0) {
      final int page = _allocPost(1);
      final image = Uint8List(WmbpConstants.storePageSize);
      final data = ByteData.sublistView(image);
      data.setUint32(0, WmbpPageCodecMagic.magic, Endian.little);
      data.setUint16(4, 1, Endian.little);
      data.setUint8(6, 4);
      data.setUint8(7, 0);
      data.setUint32(8, page, Endian.little);
      data.setUint32(12, 0, Endian.little);
      _postTailPage = page;
      _postTailUsed = 0;
      _postTailImage = image;
      _postTailDirty = true;
    }

    final sortedTermIds = byTerm.keys.toList()..sort();
    var scratchExtraOff = Uint16List(256);
    var scratchExtraQ = Uint8List(256);
    int termCounter = 0;
    for (final termId in sortedTermIds) {
      if ((++termCounter & 0xFF) == 0) {
        final y = commitYc.maybeYield();
        if (y != null) await y;
      }
      final postings = byTerm[termId]!;
      _TermHead? head;
      int reusePage = -1;
      int reuseOffset = 0;
      int reuseLength = 0;
      // Always probe by termId existence -sparse dims are raw ids and may be
      // >= nextTermId while still having durable heads from prior flushes.
      final cachedHead = _headCache.get(termId);
      if (cachedHead != null) {
        head = cachedHead;
        reusePage = cachedHead.postPage;
        reuseOffset = cachedHead.postOffset;
        reuseLength = cachedHead.postLength;
      } else {
        final existing = await _findId(termId);
        if (existing != null && existing.postPage >= 0) {
          reusePage = existing.postPage;
          reuseOffset = existing.postOffset;
          reuseLength = existing.postLength;
          head = await _readHead(
            existing.postPage,
            existing.postOffset,
            existing.postLength,
          );
        }
      }
      final windows =
          <int, ({int page, int offset, int length, int maxImpact})>{};
      final dirtyMacros = <int>{};
      // Seed dirty macros from this batch's postings (active / open macros).
      if (isSingleWindow) {
        dirtyMacros.add(WmbpConstants.macroIdOfWindow(singleWinId));
      } else {
        for (int pi = 0; pi < postings.length; pi++) {
          final int docId = baseDocId + postings.deltas[pi];
          dirtyMacros.add(
              WmbpConstants.macroIdOfWindow(WmbpConstants.windowIdOf(docId)));
        }
      }
      if (head != null) {
        for (final m in dirtyMacros) {
          await _ensureMacro(head, m);
          final slice = head.macros[m];
          if (slice == null) {
            // Prior macro dir exists but the chunk did not materialize. Rewriting
            // the dirty macro from this batch alone would drop every historical
            // window pointer (recent-only recall + inflated IDF after remint-like
            // df collapse). Abort the commit instead of silently truncating.
            if (m < head.macroCount &&
                head.hasMacroDirs &&
                head.macroDirLengths[m] > 0) {
              throw DbException([
                GeneralStatus(
                  type: ResultType.sysIoDataCorrupted,
                  message:
                      'WMBP seal cannot rewrite dirty macro $m for term $termId: '
                      'prior directory chunk failed to load',
                  operation: 'wmbpSeal',
                ),
              ]);
            }
            continue;
          }
          for (int i = 0; i < slice.windowIds.length; i++) {
            windows[slice.windowIds[i]] = (
              page: slice.bodyPages[i],
              offset: slice.bodyOffset[i],
              length: slice.bodyLength[i],
              maxImpact: slice.maxImpacts[i],
            );
          }
        }
      }
      final List<WmbpChampionPosting> champions;
      if (head == null) {
        // Brand-new term: one-shot Top-128 beats N ordered inserts.
        final candidates = <WmbpChampionPosting>[];
        for (int pi = 0; pi < postings.length; pi++) {
          final int q = postings.q8s[pi];
          if (q <= 0) continue;
          final int docId = baseDocId + postings.deltas[pi];
          candidates.add(WmbpChampionPosting(docId: docId, q8: q));
        }
        champions = WmbpChampionPosting.selectTop(candidates);
      } else {
        champions = <WmbpChampionPosting>[...head.champion];
        for (int pi = 0; pi < postings.length; pi++) {
          final int q = postings.q8s[pi];
          if (q <= 0) continue;
          final int docId = baseDocId + postings.deltas[pi];
          _pushChampion(champions, docId, q);
        }
      }
      var df = head?.df ?? 0;
      if (isSingleWindow) {
        final prev = windows[singleWinId];
        final int postLen = postings.length;
        if (postLen > scratchExtraOff.length) {
          final int newCap = postLen < 1024 ? postLen * 2 : (postLen * 3) ~/ 2;
          scratchExtraOff = Uint16List(newCap);
          scratchExtraQ = Uint8List(newCap);
        }
        for (int pi = 0; pi < postLen; pi++) {
          final int docId = baseDocId + postings.deltas[pi];
          scratchExtraOff[pi] = WmbpConstants.docOffsetOf(docId);
          scratchExtraQ[pi] = postings.q8s[pi];
        }
        final extraOff = Uint16List.sublistView(scratchExtraOff, 0, postLen);
        final extraQ = Uint8List.sublistView(scratchExtraQ, 0, postLen);
        final syncWin = _appendWindowPairsSync(
          termId: termId,
          windowId: singleWinId,
          bodyPage: prev?.page ?? -1,
          offset: prev?.offset ?? 0,
          length: prev?.length ?? 0,
          maxImpact: prev?.maxImpact ?? 0,
          extraOff: extraOff,
          extraQ: extraQ,
        );
        if (syncWin != null) {
          windows[singleWinId] = syncWin;
        } else {
          windows[singleWinId] = await _appendWindowPairs(
            termId: termId,
            windowId: singleWinId,
            bodyPage: prev?.page ?? -1,
            offset: prev?.offset ?? 0,
            length: prev?.length ?? 0,
            maxImpact: prev?.maxImpact ?? 0,
            extraOff: extraOff,
            extraQ: extraQ,
          );
        }
        df += postLen;
      } else {
        final touched = <int, ({List<int> extraOff, List<int> extraQ})>{};
        for (int pi = 0; pi < postings.length; pi++) {
          final int docId = baseDocId + postings.deltas[pi];
          final int windowId = WmbpConstants.windowIdOf(docId);
          final entry = touched.putIfAbsent(
            windowId,
            () => (extraOff: <int>[], extraQ: <int>[]),
          );
          entry.extraOff.add(WmbpConstants.docOffsetOf(docId));
          entry.extraQ.add(postings.q8s[pi]);
        }
        for (final win in touched.entries) {
          final prev = windows[win.key];
          final extraOff = win.value.extraOff;
          final extraQ = win.value.extraQ;
          final syncWin = _appendWindowPairsSync(
            termId: termId,
            windowId: win.key,
            bodyPage: prev?.page ?? -1,
            offset: prev?.offset ?? 0,
            length: prev?.length ?? 0,
            maxImpact: prev?.maxImpact ?? 0,
            extraOff: extraOff,
            extraQ: extraQ,
          );
          if (syncWin != null) {
            windows[win.key] = syncWin;
          } else {
            windows[win.key] = await _appendWindowPairs(
              termId: termId,
              windowId: win.key,
              bodyPage: prev?.page ?? -1,
              offset: prev?.offset ?? 0,
              length: prev?.length ?? 0,
              maxImpact: prev?.maxImpact ?? 0,
              extraOff: extraOff,
              extraQ: extraQ,
            );
          }
          df += extraOff.length;
        }
      }
      final headImage = _encodeTermHeadSync(
            termId,
            df,
            champions,
            windows,
            prior: head,
            dirtyMacros: dirtyMacros,
          ) ??
          await _encodeTermHead(
            termId,
            df,
            champions,
            windows,
            prior: head,
            dirtyMacros: dirtyMacros,
          );
      final headAt = _placeHeadSync(
            headImage.bytes,
            reusePage: reusePage,
            reuseOffset: reuseOffset,
            reuseLength: reuseLength,
          ) ??
          await _placeHead(
            headImage.bytes,
            reusePage: reusePage,
            reuseOffset: reuseOffset,
            reuseLength: reuseLength,
          );
      final newHead = _TermHead.fromWindowsMap(
        termId: termId,
        df: df,
        champion: champions,
        windows: windows,
        macroMax: headImage.macroMax,
        dirPages: headImage.dirPages,
        dirOffsets: headImage.dirOffsets,
        dirLengths: headImage.dirLengths,
        postPage: headAt.page,
        postOffset: headAt.offset,
        postLength: headAt.length,
      );
      // Preserve prior sealed macro slices so search can use them without I/O.
      if (head != null) {
        for (final entry in head.macros.entries) {
          if (!dirtyMacros.contains(entry.key)) {
            newHead.putMacro(entry.key, entry.value);
          }
        }
      }
      publishHeads[termId] = newHead;
      idUpdates.add(_IdRec(
        termId,
        df,
        headAt.page,
        headAt.offset,
        headAt.length,
      ));
      // Flush-scoped seal may leave survivor reminted ids below the prior
      // nextTermId watermark. Always persist names carried in this batch —
      // gating on `>= initialNextTermId` would permanently drop them.
      final name = batch.termNames[termId];
      if (name != null && name.isNotEmpty) {
        nameUpdates.add(_NameRec(termId, name));
        _nameCache.put(name, termId, size: _nameEntryBytes(name));
      }
    }
    // Names for pending terms not touched as posting heads this round (rare:
    // deactivate-only batches). Still durable-write so scoped seals cannot
    // strand reminted dictionary entries.
    for (final entry in batch.termNames.entries) {
      if (entry.value.isEmpty) continue;
      if (byTerm.containsKey(entry.key)) continue;
      nameUpdates.add(_NameRec(entry.key, entry.value));
      _nameCache.put(entry.value, entry.key,
          size: _nameEntryBytes(entry.value));
    }

    // Raise open window only after all OPEN_RAW appends for this batch.
    // Newly-closed windows get a per-window term blob (O(one window)), never
    // a rewrite of all historical closed debt.
    final int openBefore = _openWindowId;
    if (pendingNextDocId > nextDocId) nextDocId = pendingNextDocId;
    if (pendingNextTermId > nextTermId) nextTermId = pendingNextTermId;
    final int openAfter = _openWindowId;
    if (openAfter > openBefore) {
      for (int w = openBefore; w < openAfter; w++) {
        final terms = _dirtyOpenRawByWindow[w];
        if (terms == null || terms.isEmpty) continue;
        final entry = _closedDirtyIndex.putIfAbsent(w, _ClosedDirtyEntry.new);
        entry.blobDirty = true;
      }
      _closedDirtyIndexDirty = true;
      _openDirtySealDirty = true;
    }

    await _bulkUpsertIds(idUpdates);
    await _bulkUpsertNames(nameUpdates);

    // Discover PK overwrites while merging rev leaves, then apply masks.
    await _applyRev(
      batch.added,
      batch.removedPks,
      deactivated: deactivated,
      deactivatedSet: deactivatedSet,
    );
    await _applyMasks(batch.added, deactivated);
    await _appendFwd(batch.added);
    // Do NOT run [compactWindow] on the ingest seal path. It scans every
    // term id-page (full dictionary) and at multi-million scale made a
    // single cold update of a sparse closed window cost ~tens of seconds —
    // the same whether 1 or 10k rows flushed. Active-mask tombstones keep
    // search correct; use [compactClosedWindows] for maintenance GC.
    await _flushPostTail();

    // Aggregate window deltas (100k docs often touch 1-2 windows).
    final addByWindow = <int, int>{};
    final subByWindow = <int, int>{};
    for (final doc in batch.added) {
      final int wid = WmbpConstants.windowIdOf(doc.docId);
      addByWindow[wid] = (addByWindow[wid] ?? 0) + 1;
    }
    for (final docId in deactivated) {
      final int wid = WmbpConstants.windowIdOf(docId);
      subByWindow[wid] = (subByWindow[wid] ?? 0) + 1;
    }

    await handoff(
      deactivated: deactivated,
      publish: () {
        // O(1) visibility flip for heads -drain into LRU after local evict.
        _publishOverlay = publishHeads;
        for (final entry in addByWindow.entries) {
          _addActiveN(entry.key, entry.value);
        }
        for (final entry in subByWindow.entries) {
          _subActiveN(entry.key, entry.value);
        }
        activeDocs += batch.added.length;
        activeDocs -= deactivated.length;
        if (activeDocs < 0) activeDocs = 0;
      },
    );

    // Summary pages must reflect the published counters; awaiting here is safe
    // because local overlay and sealed visibility are already consistent.
    await _writeAuxiliary();
  }

  /// Copies [_publishOverlay] into [_headCache] with yields, then clears it.
  Future<void> drainPublishOverlay() async {
    final overlay = _publishOverlay;
    if (overlay == null || overlay.isEmpty) {
      _publishOverlay = null;
      return;
    }
    final yc = YieldController(
      'wmbp_drain_publish_overlay',
      checkInterval: 256,
      minCheckInterval: 64,
    );
    for (final head in overlay.values) {
      final y = yc.maybeYield();
      if (y != null) await y;
      _putHeadCache(head.termId, head);
    }
    _publishOverlay = null;
  }

  void _markOpenRawDirty(int termId, int windowId) {
    final set = _dirtyOpenRawByWindow.putIfAbsent(windowId, () => <int>{});
    if (!set.add(termId)) return;
    if (windowId < _openWindowId) {
      // Touch only this window's durable slot — never rewrite all closed debt.
      final entry =
          _closedDirtyIndex.putIfAbsent(windowId, _ClosedDirtyEntry.new);
      entry.blobDirty = true;
      _closedDirtyIndexDirty = true;
      return;
    }
    // Open-window dirty is a small blob; checkpoint on every auxiliary write.
    _openDirtySealDirty = true;
  }

  void _clearOpenRawDirty(int termId, int windowId) {
    final set = _dirtyOpenRawByWindow[windowId];
    if (set == null) return;
    if (!set.remove(termId)) return;
    if (windowId < _openWindowId) {
      final entry = _closedDirtyIndex[windowId];
      if (entry != null) {
        entry.blobDirty = true;
        _closedDirtyIndexDirty = true;
      }
    } else {
      _openDirtySealDirty = true;
    }
    if (set.isEmpty) {
      _dirtyOpenRawByWindow.remove(windowId);
      final entry = _closedDirtyIndex[windowId];
      if (entry != null) {
        entry.blobDirty = true;
        _closedDirtyIndexDirty = true;
      }
      _tryAdvanceSealedThrough();
    }
  }

  void _tryAdvanceSealedThrough() {
    final int open = _openWindowId;
    var through = sealedThroughWindowId;
    while (true) {
      final int next = through + 1;
      if (next >= open) break;
      final dirty = _dirtyOpenRawByWindow[next];
      if (dirty != null && dirty.isNotEmpty) break;
      final entry = _closedDirtyIndex[next];
      if (entry != null &&
          (entry.page > 0 || entry.count > 0 || entry.blobDirty)) {
        break;
      }
      if (entry != null) {
        _closedDirtyIndex.remove(next);
        _closedDirtyIndexDirty = true;
      }
      through = next;
    }
    // Watermark lives in meta (always rewritten); do not force an index
    // rewrite solely because sealedThrough advanced.
    sealedThroughWindowId = through;
  }

  /// Promote dirty OPEN_RAW bodies on *closed* windows to state I/II/III.
  ///
  /// Uses per-window term lists (memory or durable blob). No full-dictionary
  /// scan — text index is unreleased and does not carry legacy debt recovery.
  ///
  /// Budgets stop when any of [maxTerms], [maxSealMs], or [maxSealBytes]
  /// is exhausted. Transient failures keep the dirty bit (`retryLater`).
  Future<int> sealDirtyClosedWindows({
    int maxTerms = 64,
    int maxSealMs = 0,
    int maxSealBytes = 0,
  }) async {
    if (maxTerms <= 0) return 0;
    final int open = _openWindowId;
    final windowIds = <int>{
      ..._dirtyOpenRawByWindow.keys.where((w) => w < open),
      ..._closedDirtyIndex.keys.where((w) => w < open),
    }.toList()
      ..sort();
    if (windowIds.isEmpty) return 0;
    var sealed = 0;
    var bytesWritten = 0;
    final idUpdates = <_IdRec>[];
    final sw = maxSealMs > 0 ? (Stopwatch()..start()) : null;
    final yc = YieldController(
      'WmbpSealedView.sealDirtyClosedWindows',
      checkInterval: 8,
      minCheckInterval: 4,
    );

    bool overBudget() {
      if (sealed >= maxTerms) return true;
      if (sw != null && sw.elapsedMilliseconds >= maxSealMs) return true;
      if (maxSealBytes > 0 && bytesWritten >= maxSealBytes) return true;
      return false;
    }

    for (final windowId in windowIds) {
      if (overBudget()) break;
      var terms = _dirtyOpenRawByWindow[windowId];
      if (terms == null || terms.isEmpty) {
        final loaded = await _ensureClosedDirtyTerms(windowId);
        if (loaded == null || loaded.isEmpty) {
          _dirtyOpenRawByWindow.remove(windowId);
          continue;
        }
        terms = loaded;
      }
      final termList = terms.toList()..sort();
      for (final termId in termList) {
        if (overBudget()) break;
        final y = yc.maybeYield();
        if (y != null) await y;
        final result = await _sealOneDirtyTermWindow(termId, windowId);
        switch (result.status) {
          case _OpenRawSealStatus.sealed:
            sealed++;
            bytesWritten += result.bytesWritten;
            if (result.idUpdate != null) idUpdates.add(result.idUpdate!);
            _clearOpenRawDirty(termId, windowId);
          case _OpenRawSealStatus.alreadySealed:
          case _OpenRawSealStatus.notFound:
            _clearOpenRawDirty(termId, windowId);
          case _OpenRawSealStatus.retryLater:
            // Keep dirty for the next maintenance / micro-seal pass.
            break;
        }
      }
    }
    if (idUpdates.isNotEmpty) {
      await _bulkUpsertIds(idUpdates);
    }
    _tryAdvanceSealedThrough();
    if (sealed > 0 ||
        idUpdates.isNotEmpty ||
        _closedDirtyIndexDirty ||
        _openDirtySealDirty) {
      await _flushPostTail();
      await _writeAuxiliary();
    }
    return sealed;
  }

  /// Seals one closed-window OPEN_RAW body. Uses dirtyMacros so historical
  /// window pointers on other macros are preserved by reference.
  ///
  /// Does not write the id slot — caller batches via [_bulkUpsertIds].
  Future<_OpenRawSealResult> _sealOneDirtyTermWindow(
    int termId,
    int windowId,
  ) async {
    try {
      final existing = await _findId(termId);
      if (existing == null || existing.postPage < 0) {
        return const _OpenRawSealResult(_OpenRawSealStatus.notFound);
      }
      final head = await _readHead(
        existing.postPage,
        existing.postOffset,
        existing.postLength,
      );
      final int macroId = WmbpConstants.macroIdOfWindow(windowId);
      await _ensureMacro(head, macroId);
      final loc = head.lookupWindow(windowId);
      if (loc == null || loc.length <= 0) {
        return const _OpenRawSealResult(_OpenRawSealStatus.notFound);
      }
      final bytes = await _readPayloadRange(
        'post',
        loc.page,
        loc.offset,
        loc.length,
      );
      final win = WmbpEncodedWindow.fromBytes(bytes);
      if (win.state != 0) {
        return const _OpenRawSealResult(_OpenRawSealStatus.alreadySealed);
      }
      final sealed = WmbpEncodedWindow.encode(
        win.offsets,
        win.impacts,
        presorted: true,
      );
      final bodyBytes = sealed.toBytes();
      final placed = await _placePost(5, bodyBytes);
      _putWindowCache(_winKey(termId, windowId), sealed);
      final windows =
          <int, ({int page, int offset, int length, int maxImpact})>{
        windowId: (
          page: placed.page,
          offset: placed.offset,
          length: placed.length,
          maxImpact: sealed.maxImpact > loc.maxImpact
              ? sealed.maxImpact
              : loc.maxImpact,
        ),
      };
      // Preserve sibling windows inside the dirty macro by reference.
      final slice = head.macros[macroId];
      if (slice != null) {
        for (int i = 0; i < slice.windowIds.length; i++) {
          final int wid = slice.windowIds[i];
          if (wid == windowId) continue;
          windows[wid] = (
            page: slice.bodyPages[i],
            offset: slice.bodyOffset[i],
            length: slice.bodyLength[i],
            maxImpact: slice.maxImpacts[i],
          );
        }
      }
      final headImage = await _encodeTermHead(
        termId,
        head.df,
        head.champion,
        windows,
        prior: head,
        dirtyMacros: <int>{macroId},
      );
      final headAt = await _placeHead(
        headImage.bytes,
        reusePage: existing.postPage,
        reuseOffset: existing.postOffset,
        reuseLength: existing.postLength,
      );
      final newHead = _TermHead.fromWindowsMap(
        termId: termId,
        df: head.df,
        champion: head.champion,
        windows: windows,
        macroMax: headImage.macroMax,
        dirPages: headImage.dirPages,
        dirOffsets: headImage.dirOffsets,
        dirLengths: headImage.dirLengths,
        postPage: headAt.page,
        postOffset: headAt.offset,
        postLength: headAt.length,
      );
      for (final entry in head.macros.entries) {
        if (entry.key != macroId) {
          newHead.putMacro(entry.key, entry.value);
        }
      }
      _putHeadCache(termId, newHead);
      return _OpenRawSealResult(
        _OpenRawSealStatus.sealed,
        idUpdate: _IdRec(
          termId,
          head.df,
          headAt.page,
          headAt.offset,
          headAt.length,
        ),
        bytesWritten: bodyBytes.length + headImage.bytes.length,
      );
    } catch (e) {
      // Transient I/O / decode issues must not drop dirty bits.
      Logger.warn(
        'WMBP OPEN_RAW seal deferred for term=$termId window=$windowId',
        rawError: e,
      );
      return const _OpenRawSealResult(_OpenRawSealStatus.retryLater);
    }
  }

  /// Full sweep of closed windows below the tombstone floor (maintenance).
  Future<int> compactClosedWindows() async {
    if (nextDocId <= 0) return 0;
    final int openWindow = WmbpConstants.windowIdOf(nextDocId);
    final int limit =
        openWindow < _activeCounts.length ? openWindow : _activeCounts.length;
    var removed = 0;
    final yc = YieldController(
      'WmbpSealedView.compactClosedWindows',
      checkInterval: 32,
      minCheckInterval: 8,
    );
    for (int windowId = 0; windowId < limit; windowId++) {
      final y = yc.maybeYield();
      if (y != null) await y;
      final int live = _activeCounts[windowId];
      if (live == 0 || live >= WmbpConstants.gcActiveCountFloor) continue;
      removed += await compactWindow(windowId);
    }
    return removed;
  }

  /// Drops inactive postings inside one sealed window and retightens bounds.
  Future<int> compactWindow(
    int windowId, {
    int? activeBelow,
    Set<int>? compactedTerms,
  }) async {
    final int below = activeBelow ?? WmbpConstants.gcActiveCountFloor;
    if (sealedActiveCount(windowId) >= below) return 0;
    final mask = await _maskBytes(windowId);
    var removed = 0;
    for (int pageIndex = 0; pageIndex < _idPages.length; pageIndex++) {
      final int page = _idPages[pageIndex];
      if (page < 0) continue;
      final recs = await _readIdPageSlots(page, pageIndex);
      for (final rec in recs) {
        if (rec.postPage < 0) continue;
        final head = await _readHead(
          rec.postPage,
          rec.postOffset,
          rec.postLength,
        );
        final int dirtyMacro = WmbpConstants.macroIdOfWindow(windowId);
        await _ensureMacro(head, dirtyMacro);
        if (!head.macros.containsKey(dirtyMacro) &&
            dirtyMacro < head.macroCount &&
            head.hasMacroDirs &&
            head.macroDirLengths[dirtyMacro] > 0) {
          throw DbException([
            GeneralStatus(
              type: ResultType.sysIoDataCorrupted,
              message:
                  'WMBP compact cannot rewrite dirty macro $dirtyMacro for '
                  'term ${rec.termId}: prior directory chunk failed to load',
              operation: 'wmbpCompactWindow',
            ),
          ]);
        }
        final loc = head.lookupWindow(windowId);
        if (loc == null) continue;
        final pairs = await _readPairs(loc.page, loc.offset, loc.length);
        final keptOff = <int>[];
        final keptQ = <int>[];
        for (int i = 0; i < pairs.$1.length; i++) {
          if (_maskBitOn(mask, pairs.$1[i])) {
            keptOff.add(pairs.$1[i]);
            keptQ.add(pairs.$2[i]);
          } else {
            removed++;
          }
        }
        if (keptOff.length == pairs.$1.length) continue;
        compactedTerms?.add(rec.termId);
        final windows =
            <int, ({int page, int offset, int length, int maxImpact})>{};
        final dirtySlice = head.macros[dirtyMacro];
        if (dirtySlice != null) {
          for (int i = 0; i < dirtySlice.windowIds.length; i++) {
            if (dirtySlice.windowIds[i] == windowId) continue;
            windows[dirtySlice.windowIds[i]] = (
              page: dirtySlice.bodyPages[i],
              offset: dirtySlice.bodyOffset[i],
              length: dirtySlice.bodyLength[i],
              maxImpact: dirtySlice.maxImpacts[i],
            );
          }
        }
        if (keptOff.isNotEmpty) {
          windows[windowId] = await _appendWindowPairs(
            termId: rec.termId,
            windowId: windowId,
            bodyPage: -1,
            offset: 0,
            length: 0,
            maxImpact: 0,
            extraOff: keptOff,
            extraQ: keptQ,
          );
        }
        final int df = head.df - (pairs.$1.length - keptOff.length);
        final headImage = await _encodeTermHead(
          rec.termId,
          df < 0 ? 0 : df,
          head.champion,
          windows,
          prior: head,
          dirtyMacros: <int>{dirtyMacro},
        );
        final headAt = await _placeHead(
          headImage.bytes,
          reusePage: rec.postPage,
          reuseOffset: rec.postOffset,
          reuseLength: rec.postLength,
        );
        await _upsertId(
          rec.termId,
          df < 0 ? 0 : df,
          headAt.page,
          headAt.offset,
          headAt.length,
        );
      }
    }
    await _flushPostTail();
    await _writeAuxiliary();
    return removed;
  }

  Future<void> _loadMeta() async {
    final page = await _readGlobal('dict', 0);
    if (page == null) return;
    final data = ByteData.sublistView(page);
    if (data.getUint32(0, Endian.little) != WmbpPageCodecMagic.magic) return;
    final payload = page.sublist(WmbpConstants.pageHeaderSize);
    final reader = _R(payload);
    nextDocId = reader.u64();
    nextTermId = reader.u32();
    activeDocs = reader.u64();
    _postPageCount = reader.u32();
    _fwdPageCount = reader.u32();
    _revPageCount = reader.u32();
    _dictPageCount = reader.u32();
    _summaryPage = reader.u32();
    _summaryCount = reader.u32();
    _nameSkipPage = reader.u32();
    _nameSkipCount = reader.u32();
    _idDirPage = reader.u32();
    _idDirCount = reader.u32();
    final int fwdOv = reader.u32();
    // 0xFFFFFFFF = unset (same as postTail). Do not use 0 -pack(0,0) is valid.
    _fwdOvPage = fwdOv == 0xFFFFFFFF ? -1 : fwdOv;
    _fwdOvUsed = reader.u32();
    _revRoot = reader.u32();
    _revHeight = reader.u32();
    if (reader.remaining >= 8) {
      final int tail = reader.u32();
      _postTailPage = tail == 0xFFFFFFFF ? -1 : tail;
      _postTailUsed = reader.u32();
    }
    // Physical layout trailer (optional on older images -cold bootstrap).
    if (reader.remaining >= 28) {
      final int frozenDense = reader.u32();
      if (frozenDense > 0) densePagesPerPartition = frozenDense;
      _postPartitionCount = math.max(1, reader.u32());
      _postNextPageNo = reader.u32();
      _dictPartitionCount = math.max(1, reader.u32());
      _dictNextPageNo = reader.u32();
      if (_dictPartitionCount == 1 && _dictNextPageNo < 1) {
        _dictNextPageNo = 1;
      }
      _revPartitionCount = math.max(1, reader.u32());
      _revNextPageNo = reader.u32();
    } else {
      // Pre-ptr meta: treat legacy sequential page ids as packed(0, pageNo).
      _postPartitionCount = 1;
      _postNextPageNo = _postPageCount < 0 ? 0 : _postPageCount;
      _dictPartitionCount = 1;
      _dictNextPageNo = _dictPageCount < 1 ? 1 : _dictPageCount;
      _revPartitionCount = 1;
      _revNextPageNo = _revPageCount < 0 ? 0 : _revPageCount;
    }
    if (_dictPageCount < 1) _dictPageCount = 1;
    if (reader.remaining >= 12) {
      final int through = reader.u32();
      // 0xFFFFFFFF = none sealed yet.
      sealedThroughWindowId = through == 0xFFFFFFFF ? -1 : through;
      _dirtySealPage = reader.u32();
      _dirtySealCount = reader.u32();
      await _loadClosedDirtyIndex();
    } else {
      sealedThroughWindowId = -1;
      _dirtyOpenRawByWindow.clear();
      _closedDirtyIndex.clear();
      _dirtySealPage = 0;
      _dirtySealCount = 0;
    }
    // Optional open-window dirty checkpoint (added after closed dirty trailer).
    if (reader.remaining >= 8) {
      _openDirtySealPage = reader.u32();
      _openDirtySealCount = reader.u32();
      await _loadOpenDirtySealBlob();
    } else {
      _openDirtySealPage = 0;
      _openDirtySealCount = 0;
    }
    await _readSummary(_summaryPage, _summaryCount);
    await _readNameSkips(_nameSkipPage, _nameSkipCount);
    await _readIdDir(_idDirPage, _idDirCount);
    _nameSkipsDirty = false;
    _idDirDirty = false;
    _closedDirtyIndexDirty = false;
    _openDirtySealDirty = false;
  }

  Future<void> _writeAuxiliary() async {
    await _flushSummaryDirty();
    if (_nameSkipsDirty) {
      final names = await _writeBlobReusable(
        'dict',
        9,
        _nameSkipBytes(),
        page: _nameSkipPage,
        count: _nameSkipCount,
      );
      _nameSkipPage = names.page;
      _nameSkipCount = names.count;
      _nameSkipsDirty = false;
    }
    if (_idDirDirty) {
      final ids = await _writeBlobReusable(
        'dict',
        10,
        _idDirBytes(),
        page: _idDirPage,
        count: _idDirCount,
      );
      _idDirPage = ids.page;
      _idDirCount = ids.count;
      _idDirDirty = false;
    }
    if (_closedDirtyIndexDirty) {
      await _persistClosedDirtyIndex();
    }
    if (_openDirtySealDirty) {
      await _persistOpenDirtySealBlob();
    }
    if (densePagesPerPartition < 1) densePagesPerPartition = 1;
    final writer = _W()
      ..u64(nextDocId)
      ..u32(nextTermId)
      ..u64(activeDocs)
      ..u32(_postPageCount)
      ..u32(_fwdPageCount)
      ..u32(_revPageCount)
      ..u32(_dictPageCount)
      ..u32(_summaryPage)
      ..u32(_summaryCount)
      ..u32(_nameSkipPage)
      ..u32(_nameSkipCount)
      ..u32(_idDirPage)
      ..u32(_idDirCount)
      ..u32(_fwdOvPage < 0 ? 0xFFFFFFFF : _fwdOvPage)
      ..u32(_fwdOvUsed)
      ..u32(_revHeight == 0 ? 0 : _revRoot)
      ..u32(_revHeight)
      ..u32(_postTailPage < 0 ? 0xFFFFFFFF : _postTailPage)
      ..u32(_postTailUsed)
      ..u32(densePagesPerPartition)
      ..u32(_postPartitionCount < 1 ? 1 : _postPartitionCount)
      ..u32(_postNextPageNo)
      ..u32(_dictPartitionCount < 1 ? 1 : _dictPartitionCount)
      ..u32(_dictNextPageNo)
      ..u32(_revPartitionCount < 1 ? 1 : _revPartitionCount)
      ..u32(_revNextPageNo)
      ..u32(sealedThroughWindowId < 0 ? 0xFFFFFFFF : sealedThroughWindowId)
      ..u32(_dirtySealPage)
      ..u32(_dirtySealCount)
      ..u32(_openDirtySealPage)
      ..u32(_openDirtySealCount);
    await _writeFramed('dict', 0, 1, writer.bytes(), stable: true);
    // Meta now points at the new blob chains — safe to recycle prior runs.
    _publishDictFreeRuns();
  }

  Uint8List _closedDirtyIndexBytes() {
    final windows = _closedDirtyIndex.keys.toList()..sort();
    final writer = _W()
      ..u32(_closedDirtyIndexMagic)
      ..u32(windows.length);
    for (final windowId in windows) {
      final entry = _closedDirtyIndex[windowId]!;
      writer
        ..u32(windowId)
        ..u32(entry.page)
        ..u32(entry.count);
    }
    return writer.bytes();
  }

  Uint8List _closedWindowTermBytes(int windowId, Set<int> terms) {
    final sorted = terms.toList()..sort();
    final writer = _W()
      ..u32(windowId)
      ..u32(sorted.length);
    for (final termId in sorted) {
      writer.u32(termId);
    }
    return writer.bytes();
  }

  Uint8List _openDirtySealBytes() {
    final int open = _openWindowId;
    final set = _dirtyOpenRawByWindow[open];
    final writer = _W()..u32(open);
    if (set == null || set.isEmpty) {
      writer.u32(0);
      return writer.bytes();
    }
    final terms = set.toList()..sort();
    writer.u32(terms.length);
    for (final termId in terms) {
      writer.u32(termId);
    }
    return writer.bytes();
  }

  Future<void> _persistClosedDirtyIndex() async {
    final int open = _openWindowId;
    // Drop open-window leftovers from the closed index.
    _closedDirtyIndex.removeWhere((w, _) => w >= open);

    final toRemove = <int>[];
    for (final entry in _closedDirtyIndex.entries) {
      final int windowId = entry.key;
      final slot = entry.value;
      if (!slot.blobDirty) continue;
      final terms = _dirtyOpenRawByWindow[windowId];
      if (terms == null || terms.isEmpty) {
        if (slot.page > 0 && slot.count > 0) {
          _releaseDictRun(slot.page, slot.count);
        }
        toRemove.add(windowId);
        continue;
      }
      final bytes = _closedWindowTermBytes(windowId, terms);
      final written = await _writeBlobReusable(
        'dict',
        18,
        bytes,
        page: slot.page,
        count: slot.count,
      );
      slot.page = written.page;
      slot.count = written.count;
      slot.blobDirty = false;
      // Evict resident terms once durable; seal reloads via lazy blob load.
      _dirtyOpenRawByWindow.remove(windowId);
    }
    for (final w in toRemove) {
      _closedDirtyIndex.remove(w);
    }

    if (_closedDirtyIndex.isEmpty) {
      if (_dirtySealPage > 0 && _dirtySealCount > 0) {
        _releaseDictRun(_dirtySealPage, _dirtySealCount);
      }
      _dirtySealPage = 0;
      _dirtySealCount = 0;
      _closedDirtyIndexDirty = false;
      _tryAdvanceSealedThrough();
      return;
    }

    final indexBytes = _closedDirtyIndexBytes();
    final written = await _writeBlobReusable(
      'dict',
      16,
      indexBytes,
      page: _dirtySealPage,
      count: _dirtySealCount,
    );
    _dirtySealPage = written.page;
    _dirtySealCount = written.count;
    _closedDirtyIndexDirty = false;
    _tryAdvanceSealedThrough();
  }

  Future<void> _persistOpenDirtySealBlob() async {
    final bytes = _openDirtySealBytes();
    final data = ByteData.sublistView(bytes);
    final int termCount =
        bytes.length >= 8 ? data.getUint32(4, Endian.little) : 0;
    if (termCount <= 0) {
      if (_openDirtySealPage > 0 && _openDirtySealCount > 0) {
        _releaseDictRun(_openDirtySealPage, _openDirtySealCount);
      }
      _openDirtySealPage = 0;
      _openDirtySealCount = 0;
      _openDirtySealDirty = false;
      return;
    }
    final written = await _writeBlobReusable(
      'dict',
      17,
      bytes,
      page: _openDirtySealPage,
      count: _openDirtySealCount,
    );
    _openDirtySealPage = written.page;
    _openDirtySealCount = written.count;
    _openDirtySealDirty = false;
  }

  /// Loads the closed-dirty index. Unknown/corrupt images are dropped — text
  /// index is unreleased, so there is no legacy mega-blob recovery path.
  Future<void> _loadClosedDirtyIndex() async {
    _closedDirtyIndex.clear();
    if (_dirtySealPage <= 0 || _dirtySealCount <= 0) return;
    final bytes = await _readChain('dict', _dirtySealPage, _dirtySealCount);
    if (bytes.length < 8) {
      _releaseDictRun(_dirtySealPage, _dirtySealCount);
      _dirtySealPage = 0;
      _dirtySealCount = 0;
      return;
    }
    final reader = _R(bytes);
    final int magic = reader.u32();
    if (magic != _closedDirtyIndexMagic) {
      _releaseDictRun(_dirtySealPage, _dirtySealCount);
      _dirtySealPage = 0;
      _dirtySealCount = 0;
      return;
    }
    final int windowCount = reader.u32();
    for (int w = 0; w < windowCount; w++) {
      if (reader.remaining < 12) break;
      final int windowId = reader.u32();
      final int page = reader.u32();
      final int count = reader.u32();
      if (page <= 0 || count <= 0) continue;
      _closedDirtyIndex[windowId] = _ClosedDirtyEntry(page: page, count: count);
    }
  }

  Future<void> _loadOpenDirtySealBlob() async {
    if (_openDirtySealPage <= 0 || _openDirtySealCount <= 0) return;
    final bytes =
        await _readChain('dict', _openDirtySealPage, _openDirtySealCount);
    if (bytes.length < 8) return;
    final reader = _R(bytes);
    final int windowId = reader.u32();
    final int termCount = reader.u32();
    if (termCount <= 0) return;
    final set = <int>{};
    for (int t = 0; t < termCount; t++) {
      if (reader.remaining < 4) break;
      set.add(reader.u32());
    }
    if (set.isEmpty) return;
    final existing = _dirtyOpenRawByWindow[windowId];
    if (existing == null) {
      _dirtyOpenRawByWindow[windowId] = set;
    } else {
      existing.addAll(set);
    }
    // Stale open checkpoint for a window that is already closed.
    if (windowId < _openWindowId) {
      final entry =
          _closedDirtyIndex.putIfAbsent(windowId, _ClosedDirtyEntry.new);
      entry.blobDirty = true;
      _closedDirtyIndexDirty = true;
    }
  }

  /// Resolves closed-window terms: resident memory, else durable per-window blob.
  Future<Set<int>?> _ensureClosedDirtyTerms(int windowId) async {
    final resident = _dirtyOpenRawByWindow[windowId];
    if (resident != null && resident.isNotEmpty) return resident;

    final entry = _closedDirtyIndex[windowId];
    if (entry == null) return null;
    if (entry.page <= 0 || entry.count <= 0) {
      _closedDirtyIndex.remove(windowId);
      _closedDirtyIndexDirty = true;
      return null;
    }

    final loaded = await _loadClosedWindowTermBlob(entry);
    if (loaded != null && loaded.isNotEmpty) {
      _dirtyOpenRawByWindow[windowId] = loaded;
      return loaded;
    }
    _releaseDictRun(entry.page, entry.count);
    _closedDirtyIndex.remove(windowId);
    _closedDirtyIndexDirty = true;
    return null;
  }

  Future<Set<int>?> _loadClosedWindowTermBlob(_ClosedDirtyEntry entry) async {
    if (entry.page <= 0 || entry.count <= 0) return null;
    final bytes = await _readChain('dict', entry.page, entry.count);
    if (bytes.length < 8) return null;
    final reader = _R(bytes);
    reader.u32(); // windowId
    final int termCount = reader.u32();
    final set = <int>{};
    for (int t = 0; t < termCount; t++) {
      if (reader.remaining < 4) break;
      set.add(reader.u32());
    }
    return set;
  }

  Future<void> _flushSummaryDirty() async {
    final int n = _activeCounts.length;
    final int needed =
        n <= 0 ? 0 : (n + _summaryValuesPerPage - 1) ~/ _summaryValuesPerPage;
    while (_summaryChunkPages.length < needed) {
      _summaryChunkPages.add(-1);
      _summaryMetaDirty = true;
    }
    if (needed < _summaryChunkPages.length) {
      _summaryChunkPages.removeRange(needed, _summaryChunkPages.length);
      _summaryMetaDirty = true;
    }
    for (final p in List<int>.of(_dirtySummaryPages)) {
      if (p < 0 || p >= needed) continue;
      final int start = p * _summaryValuesPerPage;
      final int len = math.min(_summaryValuesPerPage, n - start);
      final bytes = Uint8List(len * 4);
      final data = ByteData.sublistView(bytes);
      for (int i = 0; i < len; i++) {
        data.setUint32(i * 4, _activeCounts[start + i], Endian.little);
      }
      var page = _summaryChunkPages[p];
      if (page < 0) {
        page = _allocDict();
        _summaryChunkPages[p] = page;
        _summaryMetaDirty = true;
      }
      await _writeFramed('dict', page, 8, bytes, stable: true);
    }
    _dirtySummaryPages.clear();
    if (_summaryMetaDirty || _summaryPage == 0) {
      final writer = _W()
        ..u32(n)
        ..u32(needed);
      for (int i = 0; i < needed; i++) {
        writer.u32(_summaryChunkPages[i]);
      }
      final summary = await _writeBlobReusable(
        'dict',
        11,
        writer.bytes(),
        page: _summaryPage,
        count: _summaryCount,
      );
      _summaryPage = summary.page;
      _summaryCount = summary.count;
      _summaryMetaDirty = false;
    }
  }

  Uint8List _nameSkipBytes() {
    final writer = _W()..u32(_nameSkips.length);
    for (final skip in _nameSkips) {
      final bytes = utf8.encode(skip.term);
      writer
        ..u16(bytes.length)
        ..raw(bytes)
        ..u32(skip.page);
    }
    return writer.bytes();
  }

  Uint8List _idDirBytes() {
    final writer = _W()..u32(_idPages.length);
    for (final page in _idPages) {
      writer.u32(page < 0 ? 0xFFFFFFFF : page);
    }
    return writer.bytes();
  }

  Future<void> _readSummary(int page, int count) async {
    if (count <= 0) return;
    final chain = await _readChain('dict', page, count);
    if (chain.length < 8) return;
    final reader = _R(chain);
    final int n = reader.u32();
    final int chunks = reader.u32();
    if (n < 0 || chunks < 0 || reader.remaining < chunks * 4) return;
    _summaryChunkPages
      ..clear()
      ..addAll([for (int i = 0; i < chunks; i++) reader.u32()]);
    final counts = Uint32List(n);
    for (int c = 0; c < chunks; c++) {
      final int chunkPage = _summaryChunkPages[c];
      if (chunkPage < 0) continue;
      final bytes = await _readFramedPayload('dict', chunkPage);
      if (bytes == null) continue;
      final data = ByteData.sublistView(bytes);
      final int start = c * _summaryValuesPerPage;
      final int len = math.min(_summaryValuesPerPage, n - start);
      final int avail = bytes.length ~/ 4;
      final int take = len < avail ? len : avail;
      for (int i = 0; i < take; i++) {
        counts[start + i] = data.getUint32(i * 4, Endian.little);
      }
    }
    _activeCounts = counts;
    _dirtySummaryPages.clear();
    _summaryMetaDirty = false;
  }

  Future<void> _readNameSkips(int page, int count) async {
    if (count <= 0) return;
    final chain = await _readChain('dict', page, count);
    if (chain.length < 4) return;
    final reader = _R(chain);
    final int n = reader.u32();
    _nameSkips.clear();
    for (int i = 0; i < n && reader.remaining >= 2; i++) {
      final int len = reader.u16();
      if (reader.remaining < len + 4) break;
      _nameSkips.add(_NameSkip(reader.str(len), reader.u32()));
    }
  }

  Future<void> _readIdDir(int page, int count) async {
    _idPages.clear();
    if (count <= 0) return;
    final chain = await _readChain('dict', page, count);
    if (chain.length < 4) return;
    final reader = _R(chain);
    final int n = reader.u32();
    for (int i = 0; i < n && reader.remaining >= 4; i++) {
      final int p = reader.u32();
      _idPages.add(p == 0xFFFFFFFF ? -1 : p);
    }
  }

  Future<void> _applyMasks(
      List<WmbpSealDoc> added, List<int> deactivated) async {
    // One framed win page per super-window (8KB mask payload) so
    // EncryptionScope.full can seal via the shared page codec.
    final windowIds = <int>{};
    for (final doc in added) {
      windowIds.add(WmbpConstants.windowIdOf(doc.docId));
    }
    for (final docId in deactivated) {
      windowIds.add(WmbpConstants.windowIdOf(docId));
    }
    final masks = <int, Uint8List>{};
    final existed = <int, bool>{};
    for (final windowId in windowIds) {
      final loaded = await _readGlobal('win', windowId);
      existed[windowId] = loaded != null;
      if (loaded == null) {
        masks[windowId] = Uint8List(WmbpConstants.activeMaskBytes);
        continue;
      }
      final payload = _framedPayloadOrNull(loaded);
      if (payload == null || payload.isEmpty) {
        masks[windowId] = Uint8List(WmbpConstants.activeMaskBytes);
      } else if (payload.length == WmbpConstants.activeMaskBytes) {
        masks[windowId] = Uint8List.fromList(payload);
      } else {
        final out = Uint8List(WmbpConstants.activeMaskBytes);
        final int n = payload.length < out.length ? payload.length : out.length;
        out.setRange(0, n, payload);
        masks[windowId] = out;
      }
    }
    for (final doc in added) {
      final int windowId = WmbpConstants.windowIdOf(doc.docId);
      _setMaskBit(
        masks[windowId]!,
        WmbpConstants.docOffsetOf(doc.docId),
        true,
      );
    }
    for (final docId in deactivated) {
      final int windowId = WmbpConstants.windowIdOf(docId);
      _setMaskBit(
        masks[windowId]!,
        WmbpConstants.docOffsetOf(docId),
        false,
      );
    }
    for (final entry in masks.entries) {
      await _writeFramed(
        'win',
        entry.key,
        10,
        entry.value,
        stable: existed[entry.key] ?? false,
      );
      _putMaskCache(entry.key, _maskWordsFromPayload(entry.value));
    }
  }

  Future<void> _appendFwd(List<WmbpSealDoc> docs) async {
    if (docs.isEmpty) return;
    final byPage = <int, List<WmbpSealDoc>>{};
    for (final doc in docs) {
      final int page = doc.docId ~/ fwdSlotsPerPage;
      byPage.putIfAbsent(page, () => <WmbpSealDoc>[]).add(doc);
      if (page + 1 > _fwdPageCount) _fwdPageCount = page + 1;
    }
    final fwdYc = YieldController('wmbp_append_fwd', checkInterval: 8);
    for (final entry in byPage.entries) {
      final y = fwdYc.maybeYield();
      if (y != null) await y;
      final loaded = await _readGlobal('fwd', entry.key);
      // Page-local slotted: 512 - (u16 off + u16 len) directory + compact payload.
      final payload = Uint8List(payloadCapacity);
      var used = WmbpConstants.fwdDirBytes;
      if (loaded != null) {
        final prev = _payload(loaded);
        final int n =
            prev.length < payload.length ? prev.length : payload.length;
        payload.setRange(0, n, prev);
        used = _fwdPayloadUsed(payload);
      }
      final data = ByteData.sublistView(payload);
      for (final doc in entry.value) {
        final bytes = utf8.encode(doc.primaryKey);
        if (bytes.length > 0xFFFF) {
          throw DbException([
            InvalidArgumentStatus(
              type: ResultType.devInvalidArgumentType,
              message: 'WMBP primary key exceeds 65535 bytes',
              parameterName: 'primaryKey',
              passedValue: doc.primaryKey,
            ),
          ]);
        }
        final int slot = doc.docId % fwdSlotsPerPage;
        final int dirAt = slot * 4;
        if (bytes.length <= WmbpConstants.fwdMaxInlinePkBytes) {
          if (used + bytes.length > payload.length) {
            throw DbException([
              GeneralStatus(
                type: ResultType.engError,
                message: 'WMBP fwd page overflow for inline PK',
              ),
            ]);
          }
          payload.setRange(used, used + bytes.length, bytes);
          data.setUint16(dirAt, used, Endian.little);
          data.setUint16(dirAt + 2, bytes.length, Endian.little);
          used += bytes.length;
        } else {
          // Long PK -post/ overflow; store 8B descriptor in fwd payload.
          final loc = await _putFwdOverflowPost(bytes);
          if (used + WmbpConstants.fwdOverflowDescBytes > payload.length) {
            throw DbException([
              GeneralStatus(
                type: ResultType.engError,
                message: 'WMBP fwd page overflow for long-PK descriptor',
              ),
            ]);
          }
          data.setUint32(used, loc.page, Endian.little);
          data.setUint32(used + 4, loc.offset, Endian.little);
          data.setUint16(
            dirAt,
            used | WmbpConstants.fwdOverflowFlag,
            Endian.little,
          );
          data.setUint16(dirAt + 2, bytes.length, Endian.little);
          used += WmbpConstants.fwdOverflowDescBytes;
        }
      }
      await _writeFramed('fwd', entry.key, 6, payload, stable: loaded != null);
    }
  }

  int _fwdPayloadUsed(Uint8List payload) {
    final data = ByteData.sublistView(payload);
    var used = WmbpConstants.fwdDirBytes;
    for (int s = 0; s < WmbpConstants.fwdDocsPerPage; s++) {
      final int dirAt = s * 4;
      if (dirAt + 4 > payload.length) break;
      final int rawOff = data.getUint16(dirAt, Endian.little);
      final int len = data.getUint16(dirAt + 2, Endian.little);
      if (len == 0) continue;
      final bool overflow = (rawOff & WmbpConstants.fwdOverflowFlag) != 0;
      final int off = rawOff & 0x7FFF;
      final int end =
          overflow ? off + WmbpConstants.fwdOverflowDescBytes : off + len;
      if (end > used) used = end;
    }
    return used;
  }

  /// Long primary keys land in `post/` (never `dict/`).
  Future<({int page, int offset})> _putFwdOverflowPost(List<int> bytes) async {
    final image = Uint8List.fromList(bytes);
    final placed = await _placePost(14, image);
    _fwdOvPage = placed.page;
    _fwdOvUsed = placed.offset + placed.length;
    return (page: placed.page, offset: placed.offset);
  }

  Future<void> _applyRev(
    List<WmbpSealDoc> added,
    List<String> removed, {
    List<int>? deactivated,
    Set<int>? deactivatedSet,
  }) async {
    for (final pk in removed) {
      await _deleteRev(pk);
    }
    if (added.isEmpty) return;
    final sorted = List<WmbpSealDoc>.from(added)
      ..sort((a, b) => a.primaryKey.compareTo(b.primaryKey));

    final revYc = YieldController('wmbp_apply_rev', checkInterval: 64);
    if (_revHeight == 0) {
      final leafPages = <int>[];
      final separators = <String>[];
      var currentRecs = <_RevRec>[];
      var currentBytes = 3;
      for (final doc in sorted) {
        final y = revYc.maybeYield();
        if (y != null) await y;
        final recCost = 10 + _utf8ByteLength(doc.primaryKey);
        if (currentRecs.isNotEmpty &&
            currentBytes + recCost > payloadCapacity) {
          final int page = _allocRev();
          await _writeRevNode(page, _RevNode.leaf(currentRecs), stable: false);
          leafPages.add(page);
          separators.add(doc.primaryKey);
          currentRecs = <_RevRec>[_RevRec(doc.primaryKey, doc.docId)];
          currentBytes = 3 + recCost;
        } else {
          currentRecs.add(_RevRec(doc.primaryKey, doc.docId));
          currentBytes += recCost;
        }
      }
      if (currentRecs.isNotEmpty) {
        final int page = _allocRev();
        await _writeRevNode(page, _RevNode.leaf(currentRecs), stable: false);
        leafPages.add(page);
      }
      if (leafPages.isEmpty) return;
      if (leafPages.length == 1) {
        _revRoot = leafPages.first;
        _revHeight = 1;
        return;
      }
      var currentLevelChildren = leafPages;
      var currentLevelSeps = separators;
      var height = 1;
      while (currentLevelChildren.length > 1) {
        height++;
        final nextLevelChildren = <int>[];
        final nextLevelSeps = <String>[];
        var chunkKids = <int>[currentLevelChildren[0]];
        var chunkSeps = <String>[];
        var currentBytes = 9;
        for (int i = 0; i < currentLevelSeps.length; i++) {
          final y = revYc.maybeYield();
          if (y != null) await y;
          final sep = currentLevelSeps[i];
          final kid = currentLevelChildren[i + 1];
          final pairCost = 6 + _utf8ByteLength(sep);
          if (chunkSeps.isNotEmpty &&
              currentBytes + pairCost > payloadCapacity) {
            final int page = _allocRev();
            await _writeRevNode(page,
                _RevNode.internal(children: chunkKids, separators: chunkSeps),
                stable: false);
            nextLevelChildren.add(page);
            nextLevelSeps.add(sep);
            chunkKids = <int>[kid];
            chunkSeps = <String>[];
            currentBytes = 9;
          } else {
            chunkKids.add(kid);
            chunkSeps.add(sep);
            currentBytes += pairCost;
          }
        }
        if (chunkKids.isNotEmpty) {
          final int page = _allocRev();
          await _writeRevNode(page,
              _RevNode.internal(children: chunkKids, separators: chunkSeps),
              stable: false);
          nextLevelChildren.add(page);
        }
        currentLevelChildren = nextLevelChildren;
        currentLevelSeps = nextLevelSeps;
      }
      _revRoot = currentLevelChildren.first;
      _revHeight = height;
      return;
    }

    int i = 0;
    while (i < sorted.length) {
      final y = revYc.maybeYield();
      if (y != null) await y;
      final doc = sorted[i];
      final leafInfo = await _findLeafWithBound(doc.primaryKey);
      final path = leafInfo.path;
      final leaf = leafInfo.leaf;
      final upperBound = leafInfo.upperBound;

      int j = i + 1;
      if (upperBound != null) {
        while (j < sorted.length &&
            sorted[j].primaryKey.compareTo(upperBound) < 0) {
          j++;
        }
      } else {
        j = sorted.length;
      }

      final merged = <_RevRec>[];
      var mergedBytes = 3;
      int p1 = 0;
      int p2 = i;
      final oldRecs = leaf.records;
      while (p1 < oldRecs.length && p2 < j) {
        final cmp = oldRecs[p1].pk.compareTo(sorted[p2].primaryKey);
        if (cmp == 0) {
          final pk = oldRecs[p1].pk;
          final int oldDocId = oldRecs[p1].docId;
          final int newDocId = sorted[p2].docId;
          if (deactivated != null &&
              deactivatedSet != null &&
              oldDocId != newDocId &&
              deactivatedSet.add(oldDocId)) {
            deactivated.add(oldDocId);
          }
          merged.add(_RevRec(pk, newDocId));
          mergedBytes += 10 + _utf8ByteLength(pk);
          p1++;
          p2++;
        } else if (cmp < 0) {
          final rec = oldRecs[p1++];
          merged.add(rec);
          mergedBytes += 10 + _utf8ByteLength(rec.pk);
        } else {
          final pk = sorted[p2].primaryKey;
          merged.add(_RevRec(pk, sorted[p2].docId));
          mergedBytes += 10 + _utf8ByteLength(pk);
          p2++;
        }
      }
      while (p1 < oldRecs.length) {
        final rec = oldRecs[p1++];
        merged.add(rec);
        mergedBytes += 10 + _utf8ByteLength(rec.pk);
      }
      while (p2 < j) {
        final pk = sorted[p2].primaryKey;
        merged.add(_RevRec(pk, sorted[p2].docId));
        mergedBytes += 10 + _utf8ByteLength(pk);
        p2++;
      }

      if (mergedBytes <= payloadCapacity) {
        await _writeRevNode(path.last, _RevNode.leaf(merged), stable: true);
      } else {
        final chunks = <List<_RevRec>>[];
        var cur = <_RevRec>[];
        var curBytes = 3;
        for (final rec in merged) {
          final recCost = 10 + _utf8ByteLength(rec.pk);
          if (cur.isNotEmpty && curBytes + recCost > payloadCapacity) {
            chunks.add(cur);
            cur = <_RevRec>[rec];
            curBytes = 3 + recCost;
          } else {
            cur.add(rec);
            curBytes += recCost;
          }
        }
        if (cur.isNotEmpty) {
          chunks.add(cur);
        }

        await _writeRevNode(path.last, _RevNode.leaf(chunks[0]), stable: true);
        final newPages = <int>[];
        final newSeps = <String>[];
        for (int c = 1; c < chunks.length; c++) {
          final newPage = _allocRev();
          await _writeRevNode(newPage, _RevNode.leaf(chunks[c]), stable: false);
          newPages.add(newPage);
          newSeps.add(chunks[c].first.pk);
        }
        await _insertSeparatorsBatch(
          path.sublist(0, path.length - 1),
          path.last,
          newSeps,
          newPages,
        );
      }

      i = j;
    }
  }

  Future<({List<int> path, _RevNode leaf, String? upperBound})>
      _findLeafWithBound(String pk) async {
    final path = <int>[];
    var page = _revRoot;
    String? upperBound;
    _RevNode? leaf;
    for (int depth = 0; depth < _revHeight; depth++) {
      path.add(page);
      final node = await _readRevNode(page);
      if (node.leaf) {
        leaf = node;
        break;
      }
      var lo = 0;
      var hi = node.separators.length;
      while (lo < hi) {
        final int mid = (lo + hi) >> 1;
        if (pk.compareTo(node.separators[mid]) < 0) {
          hi = mid;
        } else {
          lo = mid + 1;
        }
      }
      page = node.children[lo];
      if (lo < node.separators.length) {
        upperBound = node.separators[lo];
      }
    }
    return (path: path, leaf: leaf!, upperBound: upperBound);
  }

  Future<void> _insertSeparatorsBatch(
    List<int> parentPath,
    int leftPage,
    List<String> separators,
    List<int> newPages,
  ) async {
    if (separators.isEmpty || newPages.isEmpty) return;
    if (parentPath.isEmpty) {
      final allKids = <int>[leftPage, ...newPages];
      final allSeps = separators;
      if (_revInternalEncodedLength(allKids, allSeps) <= payloadCapacity) {
        final int root = _allocRev();
        await _writeRevNode(
          root,
          _RevNode.internal(children: allKids, separators: allSeps),
          stable: false,
        );
        _revRoot = root;
        _revHeight++;
        return;
      }
      var currentLevelChildren = allKids;
      var currentLevelSeps = allSeps;
      while (currentLevelChildren.length > 1) {
        final nextLevelChildren = <int>[];
        final nextLevelSeps = <String>[];
        var chunkKids = <int>[currentLevelChildren[0]];
        var chunkSeps = <String>[];
        var currentBytes = 9;
        for (int i = 0; i < currentLevelSeps.length; i++) {
          final sep = currentLevelSeps[i];
          final kid = currentLevelChildren[i + 1];
          final pairCost = 6 + _utf8ByteLength(sep);
          if (chunkSeps.isNotEmpty &&
              currentBytes + pairCost > payloadCapacity) {
            final int page = _allocRev();
            await _writeRevNode(
              page,
              _RevNode.internal(children: chunkKids, separators: chunkSeps),
              stable: false,
            );
            nextLevelChildren.add(page);
            nextLevelSeps.add(sep);
            chunkKids = <int>[kid];
            chunkSeps = <String>[];
            currentBytes = 9;
          } else {
            chunkKids.add(kid);
            chunkSeps.add(sep);
            currentBytes += pairCost;
          }
        }
        if (chunkKids.isNotEmpty) {
          final int page = _allocRev();
          await _writeRevNode(
            page,
            _RevNode.internal(children: chunkKids, separators: chunkSeps),
            stable: false,
          );
          nextLevelChildren.add(page);
        }
        currentLevelChildren = nextLevelChildren;
        currentLevelSeps = nextLevelSeps;
        _revHeight++;
      }
      _revRoot = currentLevelChildren.first;
      return;
    }

    final int parentPage = parentPath.last;
    final parent = await _readRevNode(parentPage);
    final int index = parent.children.indexOf(leftPage);
    if (index < 0) {
      throw DbException([
        GeneralStatus(
          type: ResultType.sysIoDataCorrupted,
          message: 'WMBP reverse tree lost child page $leftPage',
          operation: 'wmbpRevInsert',
        ),
      ]);
    }
    // Build fresh lists instead of mutating the cached [_RevNode] in place.
    final nextSeparators = <String>[
      ...parent.separators.sublist(0, index),
      ...separators,
      ...parent.separators.sublist(index),
    ];
    final nextChildren = <int>[
      ...parent.children.sublist(0, index + 1),
      ...newPages,
      ...parent.children.sublist(index + 1),
    ];
    if (_revInternalEncodedLength(nextChildren, nextSeparators) <=
        payloadCapacity) {
      await _writeRevNode(
        parentPage,
        _RevNode.internal(children: nextChildren, separators: nextSeparators),
        stable: true,
      );
      return;
    }

    final chunkKidsList = <List<int>>[];
    final chunkSepsList = <List<String>>[];
    final promoteSeps = <String>[];
    var curKids = <int>[nextChildren[0]];
    var curSeps = <String>[];
    var curBytes = 9;
    for (int i = 0; i < nextSeparators.length; i++) {
      final sep = nextSeparators[i];
      final kid = nextChildren[i + 1];
      final pairCost = 6 + _utf8ByteLength(sep);
      if (curSeps.isNotEmpty && curBytes + pairCost > payloadCapacity) {
        chunkKidsList.add(curKids);
        chunkSepsList.add(curSeps);
        promoteSeps.add(sep);
        curKids = <int>[kid];
        curSeps = <String>[];
        curBytes = 9;
      } else {
        curKids.add(kid);
        curSeps.add(sep);
        curBytes += pairCost;
      }
    }
    if (curKids.isNotEmpty) {
      chunkKidsList.add(curKids);
      chunkSepsList.add(curSeps);
    }

    await _writeRevNode(
      parentPage,
      _RevNode.internal(
        children: chunkKidsList[0],
        separators: chunkSepsList[0],
      ),
      stable: true,
    );
    final nextPromotePages = <int>[];
    for (int i = 1; i < chunkKidsList.length; i++) {
      final newPage = _allocRev();
      await _writeRevNode(
        newPage,
        _RevNode.internal(
          children: chunkKidsList[i],
          separators: chunkSepsList[i],
        ),
        stable: false,
      );
      nextPromotePages.add(newPage);
    }

    await _insertSeparatorsBatch(
      parentPath.sublist(0, parentPath.length - 1),
      parentPage,
      promoteSeps,
      nextPromotePages,
    );
  }

  /// Concatenate without the `[...a, ...b]` temporary that dominated CPU when
  /// rewriting large term-windows on every single-doc seal.
  static List<int> _concatInts(List<int> left, List<int> right) {
    if (left.isEmpty) return right;
    if (right.isEmpty) return left;
    final out = List<int>.filled(left.length + right.length, 0);
    for (int i = 0; i < left.length; i++) {
      out[i] = left[i];
    }
    for (int i = 0; i < right.length; i++) {
      out[left.length + i] = right[i];
    }
    return out;
  }

  /// Live open super-window (still receiving appends).
  int get _openWindowId =>
      nextDocId <= 0 ? 0 : WmbpConstants.windowIdOf(nextDocId - 1);

  WmbpEncodedWindow _encodeWindowForSeal(
    int windowId,
    List<int> offsets,
    List<int> impacts,
  ) {
    final bool presorted = _isNonDecreasing(offsets);
    // Open window stays OPEN_RAW (state 0) to avoid O(N?) tri-state rebuilds.
    if (windowId >= _openWindowId) {
      return WmbpEncodedWindow.openRaw(
        offsets,
        impacts,
        presorted: presorted,
      );
    }
    // Closed window: finalize into state I/II/III.
    return WmbpEncodedWindow.encode(
      offsets,
      impacts,
      presorted: presorted,
    );
  }

  /// Prefer OPEN_RAW tail-append when the live window already holds state 0.
  WmbpEncodedWindow _encodeAppendForSeal({
    required int windowId,
    required WmbpEncodedWindow? cached,
    required List<int> extraOff,
    required List<int> extraQ,
  }) {
    final bool open = windowId >= _openWindowId;
    if (open && cached != null && cached.state == 0) {
      final appended = cached.appendOpenRaw(extraOff, extraQ);
      if (appended != null) return appended;
    }
    if (cached == null || cached.offsets.isEmpty) {
      return _encodeWindowForSeal(windowId, extraOff, extraQ);
    }
    return _encodeWindowForSeal(
      windowId,
      _concatInts(cached.offsets, extraOff),
      _concatInts(cached.impacts, extraQ),
    );
  }

  ({int page, int offset, int length, int maxImpact})? _appendWindowPairsSync({
    required int termId,
    required int windowId,
    required int bodyPage,
    required int offset,
    required int length,
    required int maxImpact,
    required List<int> extraOff,
    required List<int> extraQ,
  }) {
    final WmbpEncodedWindow encoded;
    if (bodyPage >= 0 && length > 0) {
      final cachedWin = _windowCache.get(_winKey(termId, windowId));
      if (cachedWin == null) return null;
      encoded = _encodeAppendForSeal(
        windowId: windowId,
        cached: cachedWin,
        extraOff: extraOff,
        extraQ: extraQ,
      );
    } else {
      encoded = _encodeWindowForSeal(windowId, extraOff, extraQ);
    }
    final int bound =
        encoded.maxImpact > maxImpact ? encoded.maxImpact : maxImpact;
    final bytes = encoded.toBytes();
    if (bytes.isEmpty) {
      return (page: 0, offset: 0, length: 0, maxImpact: bound);
    }
    final placed = _tryPlacePostSync(
      5,
      bytes,
      reusePage: bodyPage,
      reuseOffset: offset,
      reuseLength: length,
    );
    if (placed != null) {
      _putWindowCache(_winKey(termId, windowId), encoded);
      if (encoded.state == 0) {
        _markOpenRawDirty(termId, windowId);
      }
      return (
        page: placed.page,
        offset: placed.offset,
        length: placed.length,
        maxImpact: bound,
      );
    }
    return null;
  }

  Future<({int page, int offset, int length, int maxImpact})>
      _appendWindowPairs({
    required int termId,
    required int windowId,
    required int bodyPage,
    required int offset,
    required int length,
    required int maxImpact,
    required List<int> extraOff,
    required List<int> extraQ,
  }) async {
    final WmbpEncodedWindow encoded;
    if (bodyPage < 0 || length <= 0) {
      encoded = _encodeWindowForSeal(windowId, extraOff, extraQ);
    } else {
      var cachedWin = _windowCache.get(_winKey(termId, windowId));
      if (cachedWin == null) {
        final bytes = await _readPayloadRange(
          'post',
          bodyPage,
          offset,
          length,
        );
        cachedWin = WmbpEncodedWindow.fromBytes(bytes);
        _putWindowCache(_winKey(termId, windowId), cachedWin);
      }
      encoded = _encodeAppendForSeal(
        windowId: windowId,
        cached: cachedWin,
        extraOff: extraOff,
        extraQ: extraQ,
      );
    }
    final int bound =
        encoded.maxImpact > maxImpact ? encoded.maxImpact : maxImpact;
    final bytes = encoded.toBytes();
    if (bytes.isEmpty) {
      return (page: 0, offset: 0, length: 0, maxImpact: bound);
    }
    _putWindowCache(_winKey(termId, windowId), encoded);
    final placedFast = _tryPlacePostSync(
      5,
      bytes,
      reusePage: bodyPage,
      reuseOffset: offset,
      reuseLength: length,
    );
    if (placedFast != null) {
      if (encoded.state == 0) {
        _markOpenRawDirty(termId, windowId);
      }
      return (
        page: placedFast.page,
        offset: placedFast.offset,
        length: placedFast.length,
        maxImpact: bound,
      );
    }
    final placed = await _placePost(
      5,
      bytes,
      reusePage: bodyPage,
      reuseOffset: offset,
      reuseLength: length,
    );
    if (encoded.state == 0) {
      _markOpenRawDirty(termId, windowId);
    }
    return (
      page: placed.page,
      offset: placed.offset,
      length: placed.length,
      maxImpact: bound,
    );
  }

  ({int page, int offset, int length})? _placeHeadSync(
    Uint8List bytes, {
    int reusePage = -1,
    int reuseOffset = 0,
    int reuseLength = 0,
  }) {
    if (bytes.isEmpty) {
      return (page: 0, offset: 0, length: 0);
    }
    return _tryPlacePostSync(
      4,
      bytes,
      reusePage: reusePage,
      reuseOffset: reuseOffset,
      reuseLength: reuseLength,
    );
  }

  Future<({int page, int offset, int length})> _placeHead(
    Uint8List bytes, {
    int reusePage = -1,
    int reuseOffset = 0,
    int reuseLength = 0,
  }) async {
    if (bytes.isEmpty) {
      return (page: 0, offset: 0, length: 0);
    }
    final placedFast = _tryPlacePostSync(
      4,
      bytes,
      reusePage: reusePage,
      reuseOffset: reuseOffset,
      reuseLength: reuseLength,
    );
    if (placedFast != null) {
      return (
        page: placedFast.page,
        offset: placedFast.offset,
        length: placedFast.length,
      );
    }
    return _placePost(
      4,
      bytes,
      reusePage: reusePage,
      reuseOffset: reuseOffset,
      reuseLength: reuseLength,
    );
  }

  /// Root Head + Macro Directory Chunks.
  ///
  /// Root (hot): termId, df:u64, champions, macroMaxImpact[], macroDirPtr[].
  /// Each macro chunk (~1KB): up to 64 windows of hot+cold SoA.
  ///
  /// [dirtyMacros]: macros whose chunks must be rewritten. Untouched macros
  /// with a prior dir ptr are copied by reference (sealed history = read-only).
  /// When null, every macro present in [windows] is rewritten (and prior macros
  /// not in [windows] are dropped -used by compact/GC full rebuilds).
  Future<
      ({
        Uint8List bytes,
        List<int> windowIds,
        Uint8List macroMax,
        Uint32List dirPages,
        Uint32List dirOffsets,
        Uint32List dirLengths,
      })> _encodeTermHead(
    int termId,
    int df,
    List<WmbpChampionPosting> champion,
    Map<int, ({int page, int offset, int length, int maxImpact})> windows, {
    _TermHead? prior,
    Set<int>? dirtyMacros,
  }) async {
    final ids = windows.length == 1
        ? <int>[windows.keys.first]
        : (windows.keys.toList()..sort());
    final byMacro = <int, List<int>>{};
    for (final id in ids) {
      final int m = WmbpConstants.macroIdOfWindow(id);
      byMacro.putIfAbsent(m, () => <int>[]).add(id);
    }

    final int priorCount = prior?.macroCount ?? 0;
    var maxMacroId = -1;
    for (final m in byMacro.keys) {
      if (m > maxMacroId) maxMacroId = m;
    }
    if (dirtyMacros == null) {
      // Full rebuild from [windows] only.
    } else if (prior != null) {
      for (int m = 0; m < priorCount; m++) {
        if (prior.macroDirLengths[m] > 0 && m > maxMacroId) {
          maxMacroId = m;
        }
      }
      for (final m in dirtyMacros) {
        if (m > maxMacroId) maxMacroId = m;
      }
    }
    final int macroCount = maxMacroId < 0 ? 0 : maxMacroId + 1;
    final macroMax = Uint8List(macroCount);
    final dirPages = Uint32List(macroCount);
    final dirOffsets = Uint32List(macroCount);
    final dirLengths = Uint32List(macroCount);

    for (int m = 0; m < macroCount; m++) {
      final winList = byMacro[m];
      final bool dirty =
          dirtyMacros == null ? winList != null : dirtyMacros.contains(m);

      if (dirty) {
        if (winList == null || winList.isEmpty) {
          // Macro emptied by compact - drop dir ptr.
          continue;
        }
        var maxQ = 0;
        for (final w in winList) {
          final int q = windows[w]!.maxImpact;
          if (q > maxQ) maxQ = q;
        }
        macroMax[m] = maxQ;
        final chunk = _encodeMacroChunk(winList, windows);
        final int reusePage =
            (prior != null && m < priorCount) ? prior.macroDirPages[m] : -1;
        final int reuseOff =
            (prior != null && m < priorCount) ? prior.macroDirOffsets[m] : 0;
        final int reuseLen =
            (prior != null && m < priorCount) ? prior.macroDirLengths[m] : 0;
        final placedFast = _tryPlacePostSync(
          15,
          chunk,
          reusePage: reusePage,
          reuseOffset: reuseOff,
          reuseLength: reuseLen,
        );
        final placed = placedFast ??
            await _placePost(
              15,
              chunk,
              reusePage: reusePage,
              reuseOffset: reuseOff,
              reuseLength: reuseLen,
            );
        dirPages[m] = placed.page;
        dirOffsets[m] = placed.offset;
        dirLengths[m] = placed.length;
      } else if (prior != null &&
          m < priorCount &&
          prior.macroDirLengths[m] > 0) {
        // Sealed / untouched macro - reuse prior chunk pointer.
        macroMax[m] = prior.macroMaxImpacts[m];
        dirPages[m] = prior.macroDirPages[m];
        dirOffsets[m] = prior.macroDirOffsets[m];
        dirLengths[m] = prior.macroDirLengths[m];
      }
    }

    // Root: 18B core + champions + macroCount + max[] + ptrs
    final int rootLen =
        18 + champion.length * 9 + 4 + macroCount + macroCount * 12;
    final out = Uint8List(rootLen);
    final data = ByteData.sublistView(out);
    data.setUint32(0, termId, Endian.little);
    data.setUint32(4, PlatformByteData.lo32(df), Endian.little);
    data.setUint32(8, PlatformByteData.hi32(df), Endian.little);
    data.setUint16(12, champion.length, Endian.little);
    data.setUint32(14, macroCount, Endian.little);
    var at = 18;
    for (final posting in champion) {
      data.setUint32(at, PlatformByteData.lo32(posting.docId), Endian.little);
      data.setUint32(
          at + 4, PlatformByteData.hi32(posting.docId), Endian.little);
      out[at + 8] = posting.q8;
      at += 9;
    }
    for (int i = 0; i < macroCount; i++) {
      out[at++] = macroMax[i];
    }
    for (int i = 0; i < macroCount; i++) {
      data.setUint32(at, dirPages[i], Endian.little);
      data.setUint32(at + 4, dirOffsets[i], Endian.little);
      data.setUint32(at + 8, dirLengths[i], Endian.little);
      at += 12;
    }
    return (
      bytes: out,
      windowIds: ids,
      macroMax: macroMax,
      dirPages: dirPages,
      dirOffsets: dirOffsets,
      dirLengths: dirLengths,
    );
  }

  /// Synchronous variant of [_encodeTermHead] when all chunks and head fit in memory/staged tail.
  /// Returns null if any chunk requires asynchronous disk read/allocation.
  ({
    Uint8List bytes,
    List<int> windowIds,
    Uint8List macroMax,
    Uint32List dirPages,
    Uint32List dirOffsets,
    Uint32List dirLengths,
  })? _encodeTermHeadSync(
    int termId,
    int df,
    List<WmbpChampionPosting> champion,
    Map<int, ({int page, int offset, int length, int maxImpact})> windows, {
    _TermHead? prior,
    Set<int>? dirtyMacros,
  }) {
    final ids = windows.length == 1
        ? <int>[windows.keys.first]
        : (windows.keys.toList()..sort());
    final byMacro = <int, List<int>>{};
    for (final id in ids) {
      final int m = WmbpConstants.macroIdOfWindow(id);
      byMacro.putIfAbsent(m, () => <int>[]).add(id);
    }

    final int priorCount = prior?.macroCount ?? 0;
    var maxMacroId = -1;
    for (final m in byMacro.keys) {
      if (m > maxMacroId) maxMacroId = m;
    }
    if (dirtyMacros == null) {
      // Full rebuild from [windows] only.
    } else if (prior != null) {
      for (int m = 0; m < priorCount; m++) {
        if (prior.macroDirLengths[m] > 0 && m > maxMacroId) {
          maxMacroId = m;
        }
      }
      for (final m in dirtyMacros) {
        if (m > maxMacroId) maxMacroId = m;
      }
    }
    final int macroCount = maxMacroId < 0 ? 0 : maxMacroId + 1;
    final macroMax = Uint8List(macroCount);
    final dirPages = Uint32List(macroCount);
    final dirOffsets = Uint32List(macroCount);
    final dirLengths = Uint32List(macroCount);

    for (int m = 0; m < macroCount; m++) {
      final winList = byMacro[m];
      final bool dirty =
          dirtyMacros == null ? winList != null : dirtyMacros.contains(m);

      if (dirty) {
        if (winList == null || winList.isEmpty) {
          // Macro emptied by compact - drop dir ptr.
          continue;
        }
        var maxQ = 0;
        for (final w in winList) {
          final int q = windows[w]!.maxImpact;
          if (q > maxQ) maxQ = q;
        }
        macroMax[m] = maxQ;
        final chunk = _encodeMacroChunk(winList, windows);
        final int reusePage =
            (prior != null && m < priorCount) ? prior.macroDirPages[m] : -1;
        final int reuseOff =
            (prior != null && m < priorCount) ? prior.macroDirOffsets[m] : 0;
        final int reuseLen =
            (prior != null && m < priorCount) ? prior.macroDirLengths[m] : 0;
        final placed = _tryPlacePostSync(
          15,
          chunk,
          reusePage: reusePage,
          reuseOffset: reuseOff,
          reuseLength: reuseLen,
        );
        if (placed == null) {
          return null;
        }
        dirPages[m] = placed.page;
        dirOffsets[m] = placed.offset;
        dirLengths[m] = placed.length;
      } else if (prior != null &&
          m < priorCount &&
          prior.macroDirLengths[m] > 0) {
        // Sealed / untouched macro - reuse prior chunk pointer.
        macroMax[m] = prior.macroMaxImpacts[m];
        dirPages[m] = prior.macroDirPages[m];
        dirOffsets[m] = prior.macroDirOffsets[m];
        dirLengths[m] = prior.macroDirLengths[m];
      }
    }

    // Root: 18B core + champions + macroCount + max[] + ptrs
    final int rootLen =
        18 + champion.length * 9 + 4 + macroCount + macroCount * 12;
    final out = Uint8List(rootLen);
    final data = ByteData.sublistView(out);
    data.setUint32(0, termId, Endian.little);
    data.setUint32(4, PlatformByteData.lo32(df), Endian.little);
    data.setUint32(8, PlatformByteData.hi32(df), Endian.little);
    data.setUint16(12, champion.length, Endian.little);
    data.setUint32(14, macroCount, Endian.little);
    var at = 18;
    for (final posting in champion) {
      data.setUint32(at, PlatformByteData.lo32(posting.docId), Endian.little);
      data.setUint32(
          at + 4, PlatformByteData.hi32(posting.docId), Endian.little);
      out[at + 8] = posting.q8;
      at += 9;
    }
    for (int i = 0; i < macroCount; i++) {
      out[at++] = macroMax[i];
    }
    for (int i = 0; i < macroCount; i++) {
      data.setUint32(at, dirPages[i], Endian.little);
      data.setUint32(at + 4, dirOffsets[i], Endian.little);
      data.setUint32(at + 8, dirLengths[i], Endian.little);
      at += 12;
    }
    return (
      bytes: out,
      windowIds: ids,
      macroMax: macroMax,
      dirPages: dirPages,
      dirOffsets: dirOffsets,
      dirLengths: dirLengths,
    );
  }

  static Uint8List _encodeMacroChunk(
    List<int> winIds,
    Map<int, ({int page, int offset, int length, int maxImpact})> windows,
  ) {
    final int n = winIds.length;
    final out = Uint8List(2 + n * 17);
    final data = ByteData.sublistView(out);
    data.setUint16(0, n, Endian.little);
    var at = 2;
    for (final id in winIds) {
      data.setUint32(at, id, Endian.little);
      at += 4;
    }
    for (final id in winIds) {
      out[at++] = windows[id]!.maxImpact;
    }
    for (final id in winIds) {
      final w = windows[id]!;
      data.setUint32(at, w.page, Endian.little);
      data.setUint32(at + 4, w.offset, Endian.little);
      data.setUint32(at + 8, w.length, Endian.little);
      at += 12;
    }
    return out;
  }

  static const int _summaryValuesPerPage = WmbpConstants.summaryValuesPerPage;
  final Set<int> _dirtySummaryPages = <int>{};
  bool _summaryMetaDirty = true;

  void _markSummaryDirty(int windowId) {
    if (windowId < 0) return;
    _dirtySummaryPages.add(windowId ~/ _summaryValuesPerPage);
    _summaryMetaDirty = true;
  }

  void _addActiveN(int windowId, int n) {
    if (windowId < 0 || n <= 0) return;
    if (windowId >= _activeCounts.length) {
      final int oldPages = _activeCounts.isEmpty
          ? 0
          : (_activeCounts.length + _summaryValuesPerPage - 1) ~/
              _summaryValuesPerPage;
      // Grow by summary-page chunks to avoid per-window array copies.
      final int needed = windowId + 1;
      final int chunked =
          ((needed + _summaryValuesPerPage - 1) ~/ _summaryValuesPerPage) *
              _summaryValuesPerPage;
      final next = Uint32List(chunked);
      next.setRange(0, _activeCounts.length, _activeCounts);
      _activeCounts = next;
      final int lastPage = windowId ~/ _summaryValuesPerPage;
      for (int p = oldPages; p <= lastPage; p++) {
        _dirtySummaryPages.add(p);
      }
      _summaryMetaDirty = true;
    }
    final int cur = _activeCounts[windowId];
    final int next = cur + n;
    final int capped =
        next > WmbpConstants.windowSize ? WmbpConstants.windowSize : next;
    if (capped != cur) {
      _activeCounts[windowId] = capped;
      _markSummaryDirty(windowId);
    }
  }

  void _subActiveN(int windowId, int n) {
    if (windowId < 0 || n <= 0 || windowId >= _activeCounts.length) return;
    final int cur = _activeCounts[windowId];
    if (cur <= 0) return;
    final int next = cur - n;
    _activeCounts[windowId] = next < 0 ? 0 : next;
    _markSummaryDirty(windowId);
  }

  Future<_TermHead> _readHead(int page, int offset, int length) async {
    final bytes = _tryReadPayloadRangeSync('post', page, offset, length) ??
        await _readPayloadRange('post', page, offset, length);
    return _decodeHeadBytes(bytes, page, offset, length);
  }

  /// Decode Root Head only ? Macro Chunks stay on disk until [_ensureMacro].
  /// Sync on purpose: no `async` microtask tax on the warm / load-head path.
  _TermHead _decodeHeadBytes(
    Uint8List bytes,
    int page,
    int offset,
    int length,
  ) {
    final reader = _R(bytes);
    final int termId = reader.u32();
    final int df = reader.u64();
    final int champs = reader.u16();
    final int macroCount = reader.u32();
    final champion = <WmbpChampionPosting>[];
    for (int i = 0; i < champs; i++) {
      champion.add(WmbpChampionPosting(docId: reader.u64(), q8: reader.u8()));
    }
    final macroMax = Uint8List(macroCount);
    for (int i = 0; i < macroCount; i++) {
      macroMax[i] = reader.u8();
    }
    final dirPages = Uint32List(macroCount);
    final dirOffsets = Uint32List(macroCount);
    final dirLengths = Uint32List(macroCount);
    for (int i = 0; i < macroCount; i++) {
      dirPages[i] = reader.u32();
      dirOffsets[i] = reader.u32();
      dirLengths[i] = reader.u32();
    }
    return _TermHead(
      termId: termId,
      df: df,
      champion: champion,
      macroMaxImpacts: macroMax,
      macroDirPages: dirPages,
      macroDirOffsets: dirOffsets,
      macroDirLengths: dirLengths,
      postPage: page,
      postOffset: offset,
      postLength: length,
    );
  }

  static _TermMacroSlice _decodeMacroSlice(Uint8List chunk) {
    if (chunk.length < 2) {
      return _TermMacroSlice(
        windowIds: const <int>[],
        maxImpacts: Uint8List(0),
        bodyPages: Uint32List(0),
        bodyOffset: Uint32List(0),
        bodyLength: Uint32List(0),
      );
    }
    final reader = _R(chunk);
    final int n = reader.u16();
    final ids = List<int>.filled(n, 0, growable: false);
    for (int i = 0; i < n; i++) {
      ids[i] = reader.u32();
    }
    final maxQ = Uint8List(n);
    for (int i = 0; i < n; i++) {
      maxQ[i] = reader.u8();
    }
    final pages = Uint32List(n);
    final offs = Uint32List(n);
    final lens = Uint32List(n);
    for (int i = 0; i < n; i++) {
      pages[i] = reader.u32();
      offs[i] = reader.u32();
      lens[i] = reader.u32();
    }
    return _TermMacroSlice(
      windowIds: ids,
      maxImpacts: maxQ,
      bodyPages: pages,
      bodyOffset: offs,
      bodyLength: lens,
    );
  }

  Future<_TermImage> _readTerm(int page, int offset, int length) async {
    final head = await _readHead(page, offset, length);
    await _ensureAllMacros(head);
    final image = _TermImage(head.termId)..df = head.df;
    image.champion.addAll(head.champion);
    for (final slice in head.macros.values) {
      for (int i = 0; i < slice.windowIds.length; i++) {
        final pairs = await _readPairs(
          slice.bodyPages[i],
          slice.bodyOffset[i],
          slice.bodyLength[i],
        );
        final acc = _WinAcc();
        acc.offsets.addAll(pairs.$1);
        acc.impacts.addAll(pairs.$2);
        image.windows[slice.windowIds[i]] = acc;
      }
    }
    return image;
  }

  Future<(List<int>, List<int>)> _readPairs(
      int bodyPage, int offset, int length) async {
    if (length <= 0) return (const <int>[], const <int>[]);
    final bytes = await _readPayloadRange('post', bodyPage, offset, length);
    final window = WmbpEncodedWindow.fromBytes(bytes);
    return (window.offsets, window.impacts);
  }

  Future<void> _upsertId(
    int termId,
    int df,
    int postPage,
    int postOffset,
    int postLength,
  ) async {
    await _writeIdSlot(_IdRec(termId, df, postPage, postOffset, postLength));
  }

  Future<int> _ensureIdPage(int pageIndex) async {
    while (_idPages.length <= pageIndex) {
      _idPages.add(-1);
      _idDirDirty = true;
    }
    var page = _idPages[pageIndex];
    if (page >= 0) return page;
    page = _allocDict();
    _idPages[pageIndex] = page;
    _idDirDirty = true;
    final blank = Uint8List(
      WmbpConstants.idRecSlotsPerPage * WmbpConstants.idRecSize,
    );
    // Mark every slot empty: headPage = 0xFFFFFFFF.
    final data = ByteData.sublistView(blank);
    for (int s = 0; s < WmbpConstants.idRecSlotsPerPage; s++) {
      data.setUint32(
          s * WmbpConstants.idRecSize + 8, 0xFFFFFFFF, Endian.little);
    }
    await _writeFramed('dict', page, 3, blank, stable: false);
    return page;
  }

  Future<void> _writeIdSlot(_IdRec rec) async {
    final int pageIndex = rec.termId ~/ WmbpConstants.idRecSlotsPerPage;
    final int slot = rec.termId % WmbpConstants.idRecSlotsPerPage;
    final int page = await _ensureIdPage(pageIndex);
    final existing = await _readGlobal('dict', page);
    final payload = Uint8List(
      WmbpConstants.idRecSlotsPerPage * WmbpConstants.idRecSize,
    );
    if (existing != null) {
      final prev = _payload(existing);
      final int n = prev.length < payload.length ? prev.length : payload.length;
      payload.setRange(0, n, prev);
    }
    final data = ByteData.sublistView(payload);
    final int at = slot * WmbpConstants.idRecSize;
    data.setUint32(at, PlatformByteData.lo32(rec.df), Endian.little);
    data.setUint32(at + 4, PlatformByteData.hi32(rec.df), Endian.little);
    data.setUint32(at + 8, rec.postPage, Endian.little);
    data.setUint32(at + 12, rec.postOffset, Endian.little);
    data.setUint32(at + 16, rec.postLength, Endian.little);
    _idPageCache.remove(page);
    await _writeFramed('dict', page, 3, payload, stable: true);
  }

  Future<void> _spillName(int skip, List<_NameRec> recs) async {
    if (_namePageEncodedLength(recs) <= payloadCapacity) {
      if (recs.isNotEmpty) _nameSkips[skip].term = recs.first.name;
      _nameSkipsDirty = true;
      await _writeNamePage(_nameSkips[skip].page, recs, stable: true);
      return;
    }
    final chunks = <List<_NameRec>>[];
    var current = <_NameRec>[];
    var currentLen = 2;
    var prevName = '';
    for (final rec in recs) {
      final int share = current.isEmpty ? 0 : _sharedPrefix(prevName, rec.name);
      final suffixLen = _utf8SuffixLength(rec.name, share);
      final int recLen = 8 + suffixLen;
      if (current.isNotEmpty && currentLen + recLen > payloadCapacity) {
        chunks.add(current);
        current = <_NameRec>[rec];
        final firstSuffixLen = _utf8ByteLength(rec.name);
        currentLen = 2 + (8 + firstSuffixLen);
        prevName = rec.name;
      } else {
        current.add(rec);
        currentLen += recLen;
        prevName = rec.name;
      }
    }
    if (current.isNotEmpty) {
      chunks.add(current);
    }
    if (chunks.isEmpty) return;
    if (chunks[0].isNotEmpty) _nameSkips[skip].term = chunks[0].first.name;
    await _writeNamePage(_nameSkips[skip].page, chunks[0], stable: true);
    for (int i = 1; i < chunks.length; i++) {
      final chunk = chunks[i];
      final int page = _allocDict();
      _nameSkips.insert(skip + i, _NameSkip(chunk.first.name, page));
      await _writeNamePage(page, chunk, stable: false);
    }
    _nameSkipsDirty = true;
  }

  Future<void> _bulkUpsertIds(List<_IdRec> updates) async {
    if (updates.isEmpty) return;
    updates.sort((a, b) => a.termId.compareTo(b.termId));
    final idYc = YieldController('wmbp_bulk_upsert_ids', checkInterval: 8);
    // Group by fixed id page so each page is RMW'd once per batch.
    final grouped = <int, List<_IdRec>>{};
    for (final update in updates) {
      final int pageIndex = update.termId ~/ WmbpConstants.idRecSlotsPerPage;
      grouped.putIfAbsent(pageIndex, () => <_IdRec>[]).add(update);
    }
    for (final entry in grouped.entries) {
      final y = idYc.maybeYield();
      if (y != null) await y;
      final int pageIndex = entry.key;
      final int page = await _ensureIdPage(pageIndex);
      final existing = await _readGlobal('dict', page);
      final payload = Uint8List(
        WmbpConstants.idRecSlotsPerPage * WmbpConstants.idRecSize,
      );
      if (existing != null) {
        final prev = _payload(existing);
        final int n =
            prev.length < payload.length ? prev.length : payload.length;
        payload.setRange(0, n, prev);
      } else {
        final data = ByteData.sublistView(payload);
        for (int s = 0; s < WmbpConstants.idRecSlotsPerPage; s++) {
          data.setUint32(
            s * WmbpConstants.idRecSize + 8,
            0xFFFFFFFF,
            Endian.little,
          );
        }
      }
      final data = ByteData.sublistView(payload);
      for (final rec in entry.value) {
        final int slot = rec.termId % WmbpConstants.idRecSlotsPerPage;
        final int at = slot * WmbpConstants.idRecSize;
        data.setUint32(at, PlatformByteData.lo32(rec.df), Endian.little);
        data.setUint32(at + 4, PlatformByteData.hi32(rec.df), Endian.little);
        data.setUint32(at + 8, rec.postPage, Endian.little);
        data.setUint32(at + 12, rec.postOffset, Endian.little);
        data.setUint32(at + 16, rec.postLength, Endian.little);
      }
      _idPageCache.remove(page);
      await _writeFramed('dict', page, 3, payload, stable: true);
    }
  }

  Future<void> _bulkUpsertNames(List<_NameRec> updates) async {
    if (updates.isEmpty) return;
    updates.sort((a, b) => a.name.compareTo(b.name));
    final nameYc = YieldController('wmbp_bulk_upsert_names', checkInterval: 8);
    if (_nameSkips.isEmpty) {
      var current = <_NameRec>[];
      var currentLen = 2;
      var prevName = '';
      for (final rec in updates) {
        final int share = _sharedPrefix(prevName, rec.name);
        final suffixLen = _utf8SuffixLength(rec.name, share);
        final int recLen = 8 + suffixLen;
        if (current.isNotEmpty && currentLen + recLen > payloadCapacity) {
          final y = nameYc.maybeYield();
          if (y != null) await y;
          final int page = _allocDict();
          _nameSkips.add(_NameSkip(current.first.name, page));
          _nameSkipsDirty = true;
          await _writeNamePage(page, current, stable: false);
          current = <_NameRec>[rec];
          currentLen = 2 + (8 + _utf8SuffixLength(rec.name, 0));
          prevName = rec.name;
        } else {
          current.add(rec);
          currentLen += recLen;
          prevName = rec.name;
        }
      }
      if (current.isNotEmpty) {
        final int page = _allocDict();
        _nameSkips.add(_NameSkip(current.first.name, page));
        _nameSkipsDirty = true;
        await _writeNamePage(page, current, stable: false);
      }
      return;
    }
    final grouped = <int, List<_NameRec>>{};
    for (final update in updates) {
      final int found = _rightmostName(update.name);
      final int skip = found < 0 ? 0 : found;
      grouped.putIfAbsent(skip, () => <_NameRec>[]).add(update);
    }
    final skips = grouped.keys.toList()..sort((a, b) => b.compareTo(a));
    for (final skip in skips) {
      final y = nameYc.maybeYield();
      if (y != null) await y;
      final batch = grouped[skip]!;
      final recs = await _readNamePage(_nameSkips[skip].page);
      final map = <String, _NameRec>{for (final r in recs) r.name: r};
      for (final u in batch) {
        map[u.name] = u;
      }
      final merged = map.values.toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      await _spillName(skip, merged);
    }
  }

  Future<void> _deleteRev(String pk) async {
    if (_revHeight == 0) return;
    final path = <int>[];
    var page = _revRoot;
    _RevNode? leaf;
    for (int depth = 0; depth < _revHeight; depth++) {
      path.add(page);
      final node = await _readRevNode(page);
      if (node.leaf) {
        leaf = node;
        break;
      }
      page = _revChild(pk, node);
    }
    if (leaf == null) return;
    final oldRecs = leaf.records;
    var lo = 0;
    var hi = oldRecs.length - 1;
    var foundIndex = -1;
    while (lo <= hi) {
      final int mid = (lo + hi) >> 1;
      final int cmp = oldRecs[mid].pk.compareTo(pk);
      if (cmp == 0) {
        foundIndex = mid;
        break;
      }
      if (cmp < 0) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (foundIndex < 0) return;
    _forgetRevPk(pk);
    final nextRecs = <_RevRec>[
      ...oldRecs.sublist(0, foundIndex),
      ...oldRecs.sublist(foundIndex + 1),
    ];
    final nextLeaf = _RevNode.leaf(nextRecs);
    await _writeRevNode(path.last, nextLeaf, stable: true);
    if (path.length == 1) {
      if (nextRecs.isEmpty) {
        _revHeight = 0;
        _revRoot = 0;
      }
      return;
    }
    await _mergeLeaf(path, nextLeaf);
  }

  Future<void> _mergeLeaf(List<int> path, _RevNode leaf) async {
    if (_revLeafEncodedLength(leaf.records) * 2 >= payloadCapacity) return;
    final int parentPage = path[path.length - 2];
    final parent = await _readRevNode(parentPage);
    final int index = parent.children.indexOf(path.last);
    if (index < 0 || parent.children.length < 2) return;
    final int sibIndex = index > 0 ? index - 1 : index + 1;
    final int sibPage = parent.children[sibIndex];
    final sib = await _readRevNode(sibPage);
    if (!sib.leaf) return;
    final bool leafIsRight = index > sibIndex;
    final left = leafIsRight ? sib : leaf;
    final right = leafIsRight ? leaf : sib;
    final mergedRecs = <_RevRec>[...left.records, ...right.records];
    if (_revLeafEncodedLength(mergedRecs) > payloadCapacity) return;
    final merged = _RevNode.leaf(mergedRecs);
    final int leftPage = leafIsRight ? sibPage : path.last;
    final int rightPage = leafIsRight ? path.last : sibPage;
    await _writeRevNode(leftPage, merged, stable: true);
    _revNodeCache.remove(rightPage);
    final int rightIndex = parent.children.indexOf(rightPage);
    if (rightIndex < 0) return;
    if (parent.children.length == 2 && path.length == 2) {
      // Root had 2 children and 1 separator; merging collapses root to leftPage.
      _revNodeCache.remove(parentPage);
      _revRoot = leftPage;
      _revHeight = 1;
      return;
    }
    final nextChildren = <int>[
      ...parent.children.sublist(0, rightIndex),
      ...parent.children.sublist(rightIndex + 1),
    ];
    final int sepRemoveAt = rightIndex > 0 ? rightIndex - 1 : 0;
    final nextSeparators = <String>[
      if (sepRemoveAt <= parent.separators.length)
        ...parent.separators.sublist(0, sepRemoveAt),
      if (sepRemoveAt + 1 <= parent.separators.length)
        ...parent.separators.sublist(sepRemoveAt + 1),
    ];
    await _writeRevNode(
      parentPage,
      _RevNode.internal(children: nextChildren, separators: nextSeparators),
      stable: true,
    );
  }

  int _revChild(String pk, _RevNode node) {
    var lo = 0;
    var hi = node.separators.length;
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (pk.compareTo(node.separators[mid]) < 0) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return node.children[lo];
  }

  /// Warms the reverse PK B+Tree (`rev`) in BFS order (root & internal nodes
  /// first so tree descent is always resident, then leaf nodes in [_revNodeCache]).
  /// Returns `true` when the entire tree was warmed without hitting [overBudget].
  Future<bool> _warmRevPagesBudgeted({
    required bool Function() aborted,
    required bool Function() overBudget,
    Future<bool> Function(int estimatedBytes)? tryCharge,
  }) async {
    if (_revHeight <= 0) return true;
    final int revNodeCap = (_revNodeCache.maxByteThreshold * 0.90).round();
    final yc = YieldController(
      'WmbpSealedView.warmRevBudgeted',
      checkInterval: 16,
    );
    final queue = <int>[_revRoot];
    final visited = <int>{_revRoot};
    var qi = 0;
    while (qi < queue.length) {
      if (aborted() ||
          overBudget() ||
          _revNodeCache.estimatedTotalSizeBytes >= revNodeCap) {
        return false;
      }
      final int page = queue[qi++];
      if (_revNodeCache.get(page) != null) continue;
      if (tryCharge != null && !await tryCharge(WmbpConstants.storePageSize)) {
        return false;
      }
      try {
        final node = await _readRevNode(page);
        _pages.remove('rev:$page');
        if (!node.leaf) {
          for (final child in node.children) {
            if (child >= 0 && visited.add(child)) {
              queue.add(child);
            }
          }
        }
      } catch (_) {
        continue;
      }
      final y = yc.maybeYield();
      if (y != null) await y;
    }
    return true;
  }

  /// Fills [_fwdPkCache] from fwd pages while budget remains.
  /// Returns the next page index to resume from if stopped early by [overBudget].
  Future<int> _warmFwdPagesBudgeted({
    int startPage = 0,
    required bool Function() aborted,
    required bool Function() overBudget,
    Future<bool> Function(int estimatedBytes)? tryCharge,
  }) async {
    final int fwdPkCap = (_fwdPkCache.maxByteThreshold * 0.90).round();
    final yc = YieldController(
      'WmbpSealedView.warmFwdBudgeted',
      checkInterval: 4,
    );
    for (int pageNo = startPage; pageNo < _fwdPageCount; pageNo++) {
      if (aborted() ||
          overBudget() ||
          _fwdPkCache.estimatedTotalSizeBytes >= fwdPkCap) {
        return pageNo;
      }
      if (tryCharge != null && !await tryCharge(WmbpConstants.storePageSize)) {
        return pageNo;
      }
      final page = await _readGlobal('fwd', pageNo);
      if (page == null) continue;
      final payload = _payload(page);
      final data = ByteData.sublistView(payload);
      final int startDocId = pageNo * fwdSlotsPerPage;
      for (int s = 0; s < WmbpConstants.fwdDocsPerPage; s++) {
        if (overBudget() || _fwdPkCache.estimatedTotalSizeBytes >= fwdPkCap) {
          _pages.remove('fwd:$pageNo');
          return pageNo;
        }
        final int docId = startDocId + s;
        if (_fwdPkCache.get(docId) != null) continue;
        final pk = await _decodeFwdSlot(payload, data, s);
        if (pk != null) _rememberFwdPk(docId, pk);
      }
      _pages.remove('fwd:$pageNo');
      final y = yc.maybeYield();
      if (y != null) await y;
    }
    return _fwdPageCount;
  }

  Future<String?> _decodeFwdSlot(
    Uint8List payload,
    ByteData data,
    int slot,
  ) async {
    final int dirAt = slot * 4;
    if (dirAt + 4 > payload.length) return null;
    final int rawOff = data.getUint16(dirAt, Endian.little);
    final int len = data.getUint16(dirAt + 2, Endian.little);
    if (len == 0) return null;
    final bool overflow = (rawOff & WmbpConstants.fwdOverflowFlag) != 0;
    final int off = rawOff & 0x7FFF;
    if (!overflow) {
      if (off + len > payload.length) return null;
      return _utf8(payload, off, len);
    }
    if (off + WmbpConstants.fwdOverflowDescBytes > payload.length) return null;
    final int ovPage = data.getUint32(off, Endian.little);
    final int ovOff = data.getUint32(off + 4, Endian.little);
    final ov = await _readPayloadRange('post', ovPage, ovOff, len);
    return _utf8(ov, 0, len);
  }

  Future<String?> _lookupFwd(int docId) async {
    final cached = _fwdPkCache.get(docId);
    if (cached != null) return cached;
    final int pageNo = docId ~/ fwdSlotsPerPage;
    final page = await _readGlobal('fwd', pageNo);
    if (page == null) return null;
    final payload = _payload(page);
    final data = ByteData.sublistView(payload);
    final int startDocId = pageNo * fwdSlotsPerPage;
    // Warm sibling slots on the same page while decoding the target.
    for (int s = 0; s < WmbpConstants.fwdDocsPerPage; s++) {
      final int id = startDocId + s;
      if (_fwdPkCache.get(id) != null) continue;
      final pk = await _decodeFwdSlot(payload, data, s);
      if (pk != null) _rememberFwdPk(id, pk);
    }
    return _fwdPkCache.get(docId);
  }

  Future<_IdRec?> _findId(int termId) async {
    if (termId <= 0) return null;
    final int pageIndex = termId ~/ WmbpConstants.idRecSlotsPerPage;
    if (pageIndex >= _idPages.length) return null;
    final int page = _idPages[pageIndex];
    if (page < 0) return null;
    // Prefer decoded id-page cache so commit's per-term probes share one RMW.
    final cached = _idPageCache.get(page);
    if (cached != null) {
      for (final rec in cached) {
        if (rec.termId == termId) return rec;
      }
      return null;
    }
    final recs = await _readIdPageSlots(page, pageIndex);
    for (final rec in recs) {
      if (rec.termId == termId) return rec;
    }
    return null;
  }

  int _rightmostName(String term) {
    var lo = 0;
    var hi = _nameSkips.length;
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (_nameSkips[mid].term.compareTo(term) <= 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo - 1;
  }

  Future<void> _rememberMask(int windowId) async {
    if (_maskCache.containsKey(windowId)) return;
    final words = _maskWordsFromPayload(await _maskBytes(windowId));
    _putMaskCache(windowId, words);
    _pages.remove('win:$windowId');
  }

  /// 8KB ActiveMask payload for [windowId] (one framed win page).
  Future<Uint8List> _maskBytes(int windowId) async {
    final loaded = await _readGlobal('win', windowId);
    if (loaded == null) {
      return Uint8List(WmbpConstants.activeMaskBytes);
    }
    final payload = _framedPayloadOrNull(loaded);
    if (payload == null || payload.isEmpty) {
      return Uint8List(WmbpConstants.activeMaskBytes);
    }
    if (payload.length == WmbpConstants.activeMaskBytes) {
      return Uint8List.fromList(payload);
    }
    final out = Uint8List(WmbpConstants.activeMaskBytes);
    final int n = payload.length < out.length ? payload.length : out.length;
    out.setRange(0, n, payload);
    return out;
  }

  /// Max local pages that fit under [maxPartitionFileSize] and ptr pageNo bits.
  int _maxLocalPagesPerPartition() {
    final int bySize = maxPartitionFileSize ~/ WmbpConstants.storePageSize;
    final int capped = bySize < 1 ? 1 : bySize;
    // pageNo is 0..mask inclusive -at most mask+1 slots.
    final int bitCap = WmbpConstants.pagePtrPageNoMask + 1;
    return capped > bitCap ? bitCap : capped;
  }

  /// Contiguous packed run in one partition (so `start+i` chain math holds).
  ///
  /// Rotates the active partition when the run would exceed the file budget.
  int _allocPackedRun({
    required int pages,
    required int Function() pageCount,
    required void Function(int) setPageCount,
    required int Function() partitionCount,
    required void Function(int) setPartitionCount,
    required int Function() nextPageNo,
    required void Function(int) setNextPageNo,
    int firstPageNoOnFreshPartition = 0,
  }) {
    final int n = pages < 1 ? 1 : pages;
    final int maxLocal = _maxLocalPagesPerPartition();
    var parts = partitionCount();
    var next = nextPageNo();
    if (parts < 1) {
      parts = 1;
      next = firstPageNoOnFreshPartition;
    }
    if (n > maxLocal) {
      throw DbException([
        GeneralStatus(
          type: ResultType.sysInvalidDataFormat,
          message:
              'WMBP contiguous alloc needs $n pages but maxPartitionFileSize '
              'only holds $maxLocal pages per file',
          operation: 'wmbpAlloc',
        ),
      ]);
    }
    if (next + n > maxLocal) {
      parts += 1;
      next = firstPageNoOnFreshPartition;
    }
    final int startPageNo = next;
    final int part = parts - 1;
    final int packed = WmbpPagePtr.pack(part, startPageNo);
    if (packed < 0) {
      throw DbException([
        GeneralStatus(
          type: ResultType.sysInvalidDataFormat,
          message: 'WMBP page ptr overflow: partition $part page $startPageNo '
              '(max partition ${WmbpConstants.pagePtrMaxPartition})',
          operation: 'wmbpAlloc',
        ),
      ]);
    }
    next += n;
    setPartitionCount(parts);
    setNextPageNo(next);
    setPageCount(pageCount() + n);
    return packed;
  }

  void _ensureDictAllocatorReady() {
    if (_dictPageCount < 1) _dictPageCount = 1;
    if (_dictPartitionCount < 1) {
      _dictPartitionCount = 1;
      _dictNextPageNo = 1;
    }
    // Partition 0 page 0 is sealed meta -never hand it out as a data page.
    if (_dictPartitionCount == 1 && _dictNextPageNo < 1) {
      _dictNextPageNo = 1;
    }
  }

  int _allocDictRun(int pages) {
    _ensureDictAllocatorReady();
    final int n = pages < 1 ? 1 : pages;
    // Prefer recycled blob runs so dirtySeal / skip-list growth does not
    // permanently abandon prior chains in the partition files.
    for (int i = 0; i < _dictFreeRuns.length; i++) {
      final run = _dictFreeRuns[i];
      if (run.count < n) continue;
      _dictFreeRuns.removeAt(i);
      if (run.count > n) {
        _dictFreeRuns.add((page: run.page + n, count: run.count - n));
      }
      return run.page;
    }
    return _allocPackedRun(
      pages: n,
      pageCount: () => _dictPageCount,
      setPageCount: (v) => _dictPageCount = v,
      partitionCount: () => _dictPartitionCount,
      setPartitionCount: (v) => _dictPartitionCount = v,
      nextPageNo: () => _dictNextPageNo,
      setNextPageNo: (v) => _dictNextPageNo = v,
      // Rotated partitions have no reserved meta page.
      firstPageNoOnFreshPartition: 0,
    );
  }

  /// Queue a relocated dict blob chain for reuse after the next durable meta
  /// write ([_publishDictFreeRuns]).
  void _releaseDictRun(int page, int count) {
    if (page <= 0 || count <= 0) return;
    // Page 0 is sealed meta — never recycle into data allocations.
    final (part, local) = WmbpPagePtr.unpack(page);
    if (part == 0 && local == 0) return;
    _dictPendingFreeRuns.add((page: page, count: count));
  }

  /// Move pending releases into the allocatable free list. Call only after
  /// sealed meta that no longer references those runs has been written.
  void _publishDictFreeRuns() {
    if (_dictPendingFreeRuns.isEmpty) return;
    _dictFreeRuns.addAll(_dictPendingFreeRuns);
    _dictPendingFreeRuns.clear();
  }

  /// When [startPage] is the live tip of the dict allocator, grow it in place
  /// so a larger blob does not orphan the previous contiguous chain.
  /// Returns the new count on success, otherwise null.
  int? _tryExtendDictRun(int startPage, int oldCount, int newCount) {
    if (startPage <= 0 || oldCount <= 0 || newCount <= oldCount) {
      return newCount <= oldCount && oldCount > 0 ? oldCount : null;
    }
    final (part, local) = WmbpPagePtr.unpack(startPage);
    if (part < 0 || local < 0) return null;
    if (part != _dictPartitionCount - 1) return null;
    if (local + oldCount != _dictNextPageNo) return null;
    final int maxLocal = _maxLocalPagesPerPartition();
    if (local + newCount > maxLocal) return null;
    final int extra = newCount - oldCount;
    _dictNextPageNo += extra;
    _dictPageCount += extra;
    return newCount;
  }

  int _allocDict() => _allocDictRun(1);

  int _allocPost(int pages) {
    return _allocPackedRun(
      pages: pages,
      pageCount: () => _postPageCount,
      setPageCount: (v) => _postPageCount = v,
      partitionCount: () => _postPartitionCount,
      setPartitionCount: (v) => _postPartitionCount = v,
      nextPageNo: () => _postNextPageNo,
      setNextPageNo: (v) => _postNextPageNo = v,
    );
  }

  int _allocRev() {
    return _allocPackedRun(
      pages: 1,
      pageCount: () => _revPageCount,
      setPageCount: (v) => _revPageCount = v,
      partitionCount: () => _revPartitionCount,
      setPartitionCount: (v) => _revPartitionCount = v,
      nextPageNo: () => _revNextPageNo,
      setNextPageNo: (v) => _revNextPageNo = v,
    );
  }

  bool _overlayPostSync(
    int kind,
    int startPage,
    int offset,
    Uint8List bytes,
  ) {
    final int cap = payloadCapacity;
    var preCursor = offset;
    while (preCursor < offset + bytes.length) {
      final int pageIndex = preCursor ~/ cap;
      final int global = startPage + pageIndex;
      final existing = _readGlobalSync('post', global);
      if (existing == null && global < _postPageCount) {
        return false;
      }
      final int inner = preCursor % cap;
      preCursor += (cap - inner);
    }

    var filled = 0;
    var cursor = offset;
    while (filled < bytes.length) {
      final int pageIndex = cursor ~/ cap;
      final int inner = cursor % cap;
      final int global = startPage + pageIndex;
      final existing = _readGlobalSync('post', global);
      final image = Uint8List(WmbpConstants.storePageSize);
      if (existing != null) {
        final int n =
            existing.length < image.length ? existing.length : image.length;
        image.setRange(0, n, existing);
      }
      final int room = cap - inner;
      final int take =
          bytes.length - filled < room ? bytes.length - filled : room;
      final int dest = WmbpConstants.pageHeaderSize + inner;
      image.setRange(dest, dest + take, bytes, filled);
      final data = ByteData.sublistView(image);
      final int prevLen =
          existing == null ? 0 : data.getUint32(12, Endian.little);
      final int end = inner + take;
      data.setUint32(0, WmbpPageCodecMagic.magic, Endian.little);
      data.setUint16(4, 1, Endian.little);
      data.setUint8(6, existing == null ? kind : data.getUint8(6));
      data.setUint8(7, 0);
      data.setUint32(8, global, Endian.little);
      data.setUint32(12, end > prevLen ? end : prevLen, Endian.little);
      _writeRawSync('post', global, image, stable: existing != null);
      // Keep the live post-tail mirror in sync. Otherwise a later
      // [_flushPostTail] can rewrite an older [_postTailImage] and wipe this
      // overlay (stale OPEN_RAW length → headerDf=0 remaining=3).
      if (global == _postTailPage) {
        _postTailImage = image;
        _postTailDirty = true;
      }
      filled += take;
      cursor += take;
    }
    return true;
  }

  /// Inplace reuse of a post slot: write [bytes] and zero the abandoned tail so
  /// a stale longer length cannot resurrect old posting triples.
  void _writePostReuseInto(
    Uint8List image, {
    required int reuseOffset,
    required int reuseLength,
    required Uint8List bytes,
  }) {
    final int dest = WmbpConstants.pageHeaderSize + reuseOffset;
    image.setRange(dest, dest + bytes.length, bytes);
    if (bytes.length < reuseLength) {
      image.fillRange(dest + bytes.length, dest + reuseLength, 0);
    }
  }

  Uint8List _paddedPostReuseBytes(Uint8List bytes, int reuseLength) {
    if (bytes.length >= reuseLength) return bytes;
    final padded = Uint8List(reuseLength);
    padded.setRange(0, bytes.length, bytes);
    return padded;
  }

  ({int page, int offset, int length})? _tryPlacePostSync(
    int kind,
    Uint8List bytes, {
    int reusePage = -1,
    int reuseOffset = 0,
    int reuseLength = 0,
  }) {
    if (bytes.isEmpty) return (page: 0, offset: 0, length: 0);
    if (reusePage >= 0 && bytes.length <= reuseLength) {
      if (reusePage == _postTailPage && _postTailImage != null) {
        _writePostReuseInto(
          _postTailImage!,
          reuseOffset: reuseOffset,
          reuseLength: reuseLength,
          bytes: bytes,
        );
        _postTailDirty = true;
        return (page: reusePage, offset: reuseOffset, length: bytes.length);
      }
      if (_overlayPostSync(
        kind,
        reusePage,
        reuseOffset,
        _paddedPostReuseBytes(bytes, reuseLength),
      )) {
        return (page: reusePage, offset: reuseOffset, length: bytes.length);
      }
      return null;
    }
    // In-place extend when the prior body occupies the post-tail tip
    // (common OPEN_RAW small-batch append path).
    final int cap = payloadCapacity;
    if (reusePage >= 0 &&
        reusePage == _postTailPage &&
        _postTailImage != null &&
        reuseOffset + reuseLength == _postTailUsed &&
        reuseOffset + bytes.length <= cap) {
      final int dest = WmbpConstants.pageHeaderSize + reuseOffset;
      _postTailImage!.setRange(dest, dest + bytes.length, bytes);
      final data = ByteData.sublistView(_postTailImage!);
      final int end = reuseOffset + bytes.length;
      final int prevLen = data.getUint32(12, Endian.little);
      data.setUint32(12, end > prevLen ? end : prevLen, Endian.little);
      _postTailUsed = end;
      _postTailDirty = true;
      return (page: reusePage, offset: reuseOffset, length: bytes.length);
    }
    if (_postTailPage >= 0 && _postTailImage == null) {
      final existing = _readGlobalSync('post', _postTailPage);
      if (existing != null) {
        final image = Uint8List(WmbpConstants.storePageSize);
        final int n =
            existing.length < image.length ? existing.length : image.length;
        image.setRange(0, n, existing);
        _postTailImage = image;
      }
    }
    if (_postTailPage >= 0 &&
        _postTailImage != null &&
        bytes.length <= cap &&
        _postTailUsed + bytes.length <= cap) {
      final int offset = _postTailUsed;
      final int dest = WmbpConstants.pageHeaderSize + offset;
      _postTailImage!.setRange(dest, dest + bytes.length, bytes);
      final int end = offset + bytes.length;
      final data = ByteData.sublistView(_postTailImage!);
      final int prevLen = data.getUint32(12, Endian.little);
      data.setUint32(0, WmbpPageCodecMagic.magic, Endian.little);
      data.setUint16(4, 1, Endian.little);
      data.setUint8(6, kind);
      data.setUint8(7, 0);
      data.setUint32(8, _postTailPage, Endian.little);
      data.setUint32(12, end > prevLen ? end : prevLen, Endian.little);
      _postTailUsed += bytes.length;
      _postTailDirty = true;
      return (page: _postTailPage, offset: offset, length: bytes.length);
    }
    if (bytes.length <= cap) {
      if (_postTailDirty && _postTailImage != null && _postTailPage >= 0) {
        _writeRawSync('post', _postTailPage, _postTailImage!, stable: true);
        _postTailDirty = false;
      }
      final int page = _allocPost(1);
      final image = Uint8List(WmbpConstants.storePageSize);
      final int dest = WmbpConstants.pageHeaderSize;
      image.setRange(dest, dest + bytes.length, bytes);
      final data = ByteData.sublistView(image);
      data.setUint32(0, WmbpPageCodecMagic.magic, Endian.little);
      data.setUint16(4, 1, Endian.little);
      data.setUint8(6, kind);
      data.setUint8(7, 0);
      data.setUint32(8, page, Endian.little);
      data.setUint32(12, bytes.length, Endian.little);
      _postTailPage = page;
      _postTailUsed = bytes.length;
      _postTailImage = image;
      _postTailDirty = true;
      return (page: page, offset: 0, length: bytes.length);
    }
    return null;
  }

  /// Packs a posting blob into the open post page, or rewrites it in place
  /// when the previous slot is large enough.
  Future<({int page, int offset, int length})> _placePost(
    int kind,
    Uint8List bytes, {
    int reusePage = -1,
    int reuseOffset = 0,
    int reuseLength = 0,
  }) async {
    if (bytes.isEmpty) return (page: 0, offset: 0, length: 0);
    if (reusePage >= 0 && bytes.length <= reuseLength) {
      if (reusePage == _postTailPage && _postTailImage != null) {
        _writePostReuseInto(
          _postTailImage!,
          reuseOffset: reuseOffset,
          reuseLength: reuseLength,
          bytes: bytes,
        );
        _postTailDirty = true;
        return (page: reusePage, offset: reuseOffset, length: bytes.length);
      }
      await _overlayPost(
        kind,
        reusePage,
        reuseOffset,
        _paddedPostReuseBytes(bytes, reuseLength),
      );
      return (page: reusePage, offset: reuseOffset, length: bytes.length);
    }
    final int cap = payloadCapacity;
    if (reusePage >= 0 &&
        reusePage == _postTailPage &&
        _postTailImage != null &&
        reuseOffset + reuseLength == _postTailUsed &&
        reuseOffset + bytes.length <= cap) {
      final int dest = WmbpConstants.pageHeaderSize + reuseOffset;
      _postTailImage!.setRange(dest, dest + bytes.length, bytes);
      final data = ByteData.sublistView(_postTailImage!);
      final int end = reuseOffset + bytes.length;
      final int prevLen = data.getUint32(12, Endian.little);
      data.setUint32(12, end > prevLen ? end : prevLen, Endian.little);
      _postTailUsed = end;
      _postTailDirty = true;
      return (page: reusePage, offset: reuseOffset, length: bytes.length);
    }
    if (_postTailPage >= 0 &&
        bytes.length <= cap &&
        _postTailUsed + bytes.length <= cap) {
      if (_postTailImage == null) {
        final existing = await _readGlobal('post', _postTailPage);
        final image = Uint8List(WmbpConstants.storePageSize);
        if (existing != null) {
          final int n =
              existing.length < image.length ? existing.length : image.length;
          image.setRange(0, n, existing);
        }
        _postTailImage = image;
      }
      final int offset = _postTailUsed;
      final int dest = WmbpConstants.pageHeaderSize + offset;
      _postTailImage!.setRange(dest, dest + bytes.length, bytes);
      final int end = offset + bytes.length;
      final data = ByteData.sublistView(_postTailImage!);
      final int prevLen = data.getUint32(12, Endian.little);
      data.setUint32(0, WmbpPageCodecMagic.magic, Endian.little);
      data.setUint16(4, 1, Endian.little);
      data.setUint8(6, kind);
      data.setUint8(7, 0);
      data.setUint32(8, _postTailPage, Endian.little);
      data.setUint32(12, end > prevLen ? end : prevLen, Endian.little);
      _postTailUsed += bytes.length;
      _postTailDirty = true;
      return (page: _postTailPage, offset: offset, length: bytes.length);
    }
    if (_postTailDirty && _postTailImage != null && _postTailPage >= 0) {
      await _writeRaw('post', _postTailPage, _postTailImage!, stable: true);
      _postTailDirty = false;
    }
    if (bytes.length <= cap) {
      final int page = _allocPost(1);
      final image = Uint8List(WmbpConstants.storePageSize);
      final int dest = WmbpConstants.pageHeaderSize;
      image.setRange(dest, dest + bytes.length, bytes);
      final data = ByteData.sublistView(image);
      data.setUint32(0, WmbpPageCodecMagic.magic, Endian.little);
      data.setUint16(4, 1, Endian.little);
      data.setUint8(6, kind);
      data.setUint8(7, 0);
      data.setUint32(8, page, Endian.little);
      data.setUint32(12, bytes.length, Endian.little);
      _postTailPage = page;
      _postTailUsed = bytes.length;
      _postTailImage = image;
      _postTailDirty = true;
      return (page: page, offset: 0, length: bytes.length);
    }
    final int pages = _pagesFor(bytes.length);
    final int page = _allocPost(pages);
    await _overlayPost(kind, page, 0, bytes);
    _postTailPage = page + pages - 1;
    _postTailUsed = bytes.length - (pages - 1) * cap;
    _postTailImage = null;
    _postTailDirty = false;
    return (page: page, offset: 0, length: bytes.length);
  }

  Future<void> _flushPostTail() async {
    if (_postTailDirty && _postTailImage != null && _postTailPage >= 0) {
      await _writeRaw('post', _postTailPage, _postTailImage!, stable: true);
      _postTailDirty = false;
    }
  }

  Future<void> _overlayPost(
    int kind,
    int startPage,
    int offset,
    Uint8List bytes,
  ) async {
    final int cap = payloadCapacity;
    var filled = 0;
    var cursor = offset;
    while (filled < bytes.length) {
      final int pageIndex = cursor ~/ cap;
      final int inner = cursor % cap;
      final int global = startPage + pageIndex;
      final existing = await _readGlobal('post', global);
      final image = Uint8List(WmbpConstants.storePageSize);
      if (existing != null) {
        final int n =
            existing.length < image.length ? existing.length : image.length;
        image.setRange(0, n, existing);
      }
      final int room = cap - inner;
      final int take =
          bytes.length - filled < room ? bytes.length - filled : room;
      final int dest = WmbpConstants.pageHeaderSize + inner;
      image.setRange(dest, dest + take, bytes, filled);
      final data = ByteData.sublistView(image);
      final int prevLen =
          existing == null ? 0 : data.getUint32(12, Endian.little);
      final int end = inner + take;
      data.setUint32(0, WmbpPageCodecMagic.magic, Endian.little);
      data.setUint16(4, 1, Endian.little);
      data.setUint8(6, existing == null ? kind : data.getUint8(6));
      data.setUint8(7, 0);
      data.setUint32(8, global, Endian.little);
      data.setUint32(12, end > prevLen ? end : prevLen, Endian.little);
      await _writeRaw('post', global, image, stable: existing != null);
      // Keep the live post-tail mirror in sync. Otherwise a later
      // [_flushPostTail] can rewrite an older [_postTailImage] and wipe this
      // overlay (stale OPEN_RAW length → headerDf=0 remaining=3).
      if (global == _postTailPage) {
        _postTailImage = image;
        _postTailDirty = true;
      }
      filled += take;
      cursor += take;
    }
  }

  int _pagesFor(int payloadLength) {
    if (payloadLength <= 0) return 0;
    return (payloadLength + payloadCapacity - 1) ~/ payloadCapacity;
  }

  /// Rewrites an existing dict blob chain when [count] still covers [payload].
  ///
  /// Growth strategy (dict only — all current callers use `dict/`):
  /// 1. Rewrite in place when reserved pages still fit
  /// 2. Else tip-extend the live allocator run (no orphan) with geometric slack
  /// 3. Else allocate a new geometric run and queue the old chain on
  ///    [_dictPendingFreeRuns] (published to [_dictFreeRuns] only after meta
  ///    is durable) so dirtySeal-style growth cannot pile O(N²) dead pages
  Future<({int page, int count})> _writeBlobReusable(
    String category,
    int kind,
    Uint8List payload, {
    required int page,
    required int count,
  }) async {
    if (payload.isEmpty) return (page: page, count: count);
    final int need = _pagesFor(payload.length);
    if (page > 0 && count >= need) {
      await _writePayloadChain(category, kind, page, payload);
      return (page: page, count: count);
    }
    // Contiguous packed run so `_writePayloadChain` `start+i` stays valid;
    // never reserve more pages than one partition file can hold.
    final int maxLocal = _maxLocalPagesPerPartition();
    if (need > maxLocal) {
      throw DbException([
        GeneralStatus(
          type: ResultType.sysInvalidDataFormat,
          message: 'WMBP dict blob needs $need pages but maxPartitionFileSize '
              'only holds $maxLocal pages per file',
          operation: 'wmbpWriteBlob',
        ),
      ]);
    }
    // Geometric headroom when growing: doubles prior reserve so each relocate
    // is rare. First alloc keeps a single spare page while still tiny.
    var reserve = need;
    if (page > 0 && count > 0) {
      reserve = count << 1;
      if (reserve < need) reserve = need;
    } else if (need < 8) {
      reserve = need + 1;
    }
    if (reserve > maxLocal) reserve = maxLocal;

    if (category == 'dict' && page > 0 && count > 0) {
      final int? extended = _tryExtendDictRun(page, count, reserve);
      if (extended != null) {
        await _writePayloadChain(category, kind, page, payload);
        return (page: page, count: extended);
      }
      // Partition nearly full: extend only to exact need if that still fits.
      if (reserve > need) {
        final int? exact = _tryExtendDictRun(page, count, need);
        if (exact != null) {
          await _writePayloadChain(category, kind, page, payload);
          return (page: page, count: exact);
        }
      }
    }

    final int start = _allocDictRun(reserve);
    await _writePayloadChain(category, kind, start, payload);
    if (category == 'dict' && page > 0 && count > 0) {
      _releaseDictRun(page, count);
    }
    return (page: start, count: reserve);
  }

  Future<void> _writePayloadChain(
    String category,
    int kind,
    int start,
    Uint8List payload,
  ) async {
    final int cap = payloadCapacity;
    final int count = payload.isEmpty ? 1 : _pagesFor(payload.length);
    for (int i = 0; i < count; i++) {
      final int from = i * cap;
      var to = from + cap;
      if (to > payload.length) to = payload.length;
      final slice = from >= payload.length
          ? Uint8List(0)
          : Uint8List.sublistView(payload, from, to);
      await _writeFramed(
        category,
        start + i,
        kind,
        slice,
        stable: false,
        cont: i + 1 < count,
      );
    }
  }

  Future<Uint8List?> _readFramedPayload(String category, int globalPage) async {
    final page = await _readGlobal(category, globalPage);
    if (page == null) return null;
    final data = ByteData.sublistView(page);
    if (data.getUint32(0, Endian.little) != WmbpPageCodecMagic.magic) {
      return null;
    }
    final int len = data.getUint32(12, Endian.little);
    if (len <= 0) return Uint8List(0);
    final int end = WmbpConstants.pageHeaderSize + len;
    if (end > page.length) return null;
    return page.sublist(WmbpConstants.pageHeaderSize, end);
  }

  Future<Uint8List> _readChain(
      String category, int start, int pageCount) async {
    final out = BytesBuilder(copy: false);
    final int limit = pageCount > 1000000 ? 1000000 : pageCount;
    for (int i = 0; i < limit; i++) {
      final page = await _readGlobal(category, start + i);
      if (page == null) break;
      final data = ByteData.sublistView(page);
      if (data.getUint32(0, Endian.little) != WmbpPageCodecMagic.magic) break;
      final int len = data.getUint32(12, Endian.little);
      final int flags = data.getUint8(7);
      if (len > 0) {
        final int end = WmbpConstants.pageHeaderSize + len;
        if (end <= page.length) {
          out.add(page.sublist(WmbpConstants.pageHeaderSize, end));
        }
      }
      if (i + 1 >= pageCount || flags == 0) break;
    }
    return out.toBytes();
  }

  Uint8List? _tryReadPayloadRangeSync(
    String category,
    int start,
    int offset,
    int length,
  ) {
    if (length <= 0) return Uint8List(0);
    final int cap = payloadCapacity;
    final out = Uint8List(length);
    var filled = 0;
    var cursor = offset;
    while (filled < length) {
      final int pageIndex = cursor ~/ cap;
      final int inner = cursor % cap;
      final int global = start + pageIndex;
      final Uint8List? page = (category == 'post' &&
              global == _postTailPage &&
              _postTailImage != null)
          ? _postTailImage
          : _pages.get('$category:$global');
      if (page == null) return null;
      final int avail = cap - inner;
      final int take = length - filled < avail ? length - filled : avail;
      final int from = WmbpConstants.pageHeaderSize + inner;
      if (from + take > page.length) return null;
      out.setRange(filled, filled + take, page, from);
      filled += take;
      cursor += take;
    }
    return out;
  }

  Future<Uint8List> _readPayloadRange(
    String category,
    int start,
    int offset,
    int length,
  ) async {
    if (length <= 0) return Uint8List(0);
    final int cap = payloadCapacity;
    final out = Uint8List(length);
    var filled = 0;
    var cursor = offset;
    while (filled < length) {
      final int pageIndex = cursor ~/ cap;
      final int inner = cursor % cap;
      final int global = start + pageIndex;
      final page = await _readGlobal(category, global);
      if (page == null) {
        throw DbException([
          GeneralStatus(
            type: ResultType.sysIoDataCorrupted,
            message:
                'WMBP page range read missing page for category $category page $global (filled $filled, needed $length)',
            operation: 'wmbpReadRange',
          ),
        ]);
      }
      final int avail = cap - inner;
      final int take = length - filled < avail ? length - filled : avail;
      final int from = WmbpConstants.pageHeaderSize + inner;
      if (from + take > page.length) {
        throw DbException([
          GeneralStatus(
            type: ResultType.sysIoDataCorrupted,
            message:
                'WMBP page range read out of bounds for category $category page $global (from $from + take $take > pageLen ${page.length})',
            operation: 'wmbpReadRange',
          ),
        ]);
      }
      out.setRange(filled, filled + take, page, from);
      filled += take;
      cursor += take;
    }
    return out;
  }

  Future<void> _writeFramed(
    String category,
    int globalPage,
    int kind,
    Uint8List payload, {
    required bool stable,
    bool cont = false,
  }) async {
    if (payload.length > payloadCapacity) {
      throw DbException([
        GeneralStatus(
          type: ResultType.sysInvalidDataFormat,
          message:
              'WMBP framed payload (${payload.length}B) exceeds page payload capacity (${payloadCapacity}B) for category $category page $globalPage',
          operation: 'wmbpWriteFramed',
        ),
      ]);
    }
    final page = Uint8List(WmbpConstants.storePageSize);
    final data = ByteData.sublistView(page);
    data.setUint32(0, WmbpPageCodecMagic.magic, Endian.little);
    data.setUint16(4, 1, Endian.little);
    data.setUint8(6, kind);
    data.setUint8(7, cont ? 1 : 0);
    data.setUint32(8, globalPage, Endian.little);
    data.setUint32(12, payload.length, Endian.little);
    page.setRange(WmbpConstants.pageHeaderSize,
        WmbpConstants.pageHeaderSize + payload.length, payload);
    await _writeRaw(category, globalPage, page, stable: stable);
  }

  void _writeRawSync(
    String category,
    int globalPage,
    Uint8List page, {
    required bool stable,
  }) {
    final (partition, local) = _physical(category, globalPage);
    if (partition < 0 || local < 0) {
      throw DbException([
        GeneralStatus(
          type: ResultType.sysInvalidDataFormat,
          message:
              'WMBP write refused: invalid page ref $globalPage for $category',
          operation: 'wmbpWriteRaw',
        ),
      ]);
    }
    final key = '$category:$globalPage';
    _writeGeneration++;
    _pages.remove(key);
    _inFlight.remove(key);
    volume.writeAtSync(
      category,
      partition,
      local * WmbpConstants.storePageSize,
      page,
      stable: stable,
    );
  }

  Future<void> _writeRaw(
    String category,
    int globalPage,
    Uint8List page, {
    required bool stable,
  }) async {
    final (partition, local) = _physical(category, globalPage);
    if (partition < 0 || local < 0) {
      throw DbException([
        GeneralStatus(
          type: ResultType.sysInvalidDataFormat,
          message:
              'WMBP write refused: invalid page ref $globalPage for $category',
          operation: 'wmbpWriteRaw',
        ),
      ]);
    }
    final key = '$category:$globalPage';
    _writeGeneration++;
    _pages.remove(key);
    _inFlight.remove(key);
    await volume.writeAt(
      category,
      partition,
      local * WmbpConstants.storePageSize,
      page,
      stable: stable,
    );
    _writeGeneration++;
    _pages.remove(key);
    _inFlight.remove(key);
  }

  Uint8List? _readGlobalSync(String category, int globalPage) {
    if (category == 'post' &&
        globalPage == _postTailPage &&
        _postTailImage != null) {
      return _postTailImage;
    }
    final key = '$category:$globalPage';
    final cached = _pages.get(key);
    if (cached != null) return cached;
    final (partition, local) = _physical(category, globalPage);
    if (partition < 0 || local < 0) return null;
    final raw = volume.readAtSync(
      category,
      partition,
      local * WmbpConstants.storePageSize,
      WmbpConstants.storePageSize,
    );
    if (raw != null && raw.length >= WmbpConstants.storePageSize) {
      _pages.put(key, raw, size: _estimatePageBytes(raw));
      return raw;
    }
    return null;
  }

  Future<Uint8List?> _readGlobal(String category, int globalPage) {
    if (category == 'post' &&
        globalPage == _postTailPage &&
        _postTailImage != null) {
      return Future<Uint8List?>.value(_postTailImage);
    }
    final key = '$category:$globalPage';
    final cached = _pages.get(key);
    if (cached != null) return Future<Uint8List?>.value(cached);
    final pending = _inFlight[key];
    if (pending != null) {
      inFlightDedupHits++;
      return pending;
    }
    final int gen = _writeGeneration;
    final future = _loadUncached(category, globalPage, key, gen);
    _inFlight[key] = future;
    return future;
  }

  Future<Uint8List?> _loadUncached(
    String category,
    int globalPage,
    String key,
    int startGen,
  ) async {
    try {
      final (partition, local) = _physical(category, globalPage);
      if (partition < 0 || local < 0) return null;
      final bytes = await volume.readAt(
        category,
        partition,
        local * WmbpConstants.storePageSize,
        WmbpConstants.storePageSize,
      );
      if (bytes == null || bytes.length < WmbpConstants.storePageSize) {
        return null;
      }
      // Only cache the raw page if no write happened while readAt was in flight.
      if (_writeGeneration == startGen) {
        _pages.put(key, bytes, size: _estimatePageBytes(bytes));
      }
      return bytes;
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<List<_NameRec>> _readNamePage(int page) async {
    final cached = _namePageCache.get(page);
    if (cached != null) return cached;
    final int gen = _writeGeneration;
    final pageBytes = await _readGlobal('dict', page);
    final raced = _namePageCache.get(page);
    if (raced != null) return raced;
    final recs = _decodeNamePageBytes(pageBytes);
    if (_writeGeneration == gen) {
      _rememberNamePageCache(page, recs);
      _pages.remove('dict:$page');
    }
    return recs;
  }

  List<_NameRec> _decodeNamePageBytes(Uint8List? pageBytes) {
    final payload = _framedPayloadOrNull(pageBytes);
    // Sparse/unwritten slots and empty frames: treat as empty (prewarm/open).
    if (payload == null || payload.length < 2) return <_NameRec>[];
    final reader = _R(payload);
    final int n = reader.u16();
    final recs = <_NameRec>[];
    var prev = '';
    for (int i = 0; i < n; i++) {
      final int termId = reader.u32();
      final int share = reader.u16();
      final int len = reader.u16();
      if (share > prev.length) {
        throw DbException([
          GeneralStatus(
            type: ResultType.sysIoDataCorrupted,
            message: 'WMBP dictionary prefix is longer than the previous term',
            operation: 'wmbpDict',
          ),
        ]);
      }
      final name = prev.substring(0, share) + reader.str(len);
      recs.add(_NameRec(termId, name));
      prev = name;
    }
    return recs;
  }

  Future<Uint8List?> _readIdPagePayload(int page) async {
    final pageBytes = await _readGlobal('dict', page);
    return _framedPayloadOrNull(pageBytes);
  }

  /// Decode occupied fixed slots on one id page (`pageIndex` supplies termId base).
  Future<List<_IdRec>> _readIdPageSlots(int page, int pageIndex) async {
    final cached = _idPageCache.get(page);
    if (cached != null) return cached;
    final int gen = _writeGeneration;
    final payload = await _readIdPagePayload(page);
    if (payload == null || payload.length < WmbpConstants.idRecSize) {
      return <_IdRec>[];
    }
    final data = ByteData.sublistView(payload);
    final recs = <_IdRec>[];
    final int base = pageIndex * WmbpConstants.idRecSlotsPerPage;
    final int slots = payload.length ~/ WmbpConstants.idRecSize;
    final int limit = slots < WmbpConstants.idRecSlotsPerPage
        ? slots
        : WmbpConstants.idRecSlotsPerPage;
    for (int s = 0; s < limit; s++) {
      final int at = s * WmbpConstants.idRecSize;
      final int postPage = data.getUint32(at + 8, Endian.little);
      if (postPage == 0xFFFFFFFF) continue;
      final int dfLo = data.getUint32(at, Endian.little);
      final int dfHi = data.getUint32(at + 4, Endian.little);
      recs.add(_IdRec(
        base + s,
        PlatformByteData.fromLoHi32(dfLo, dfHi),
        postPage,
        data.getUint32(at + 12, Endian.little),
        data.getUint32(at + 16, Endian.little),
      ));
    }
    if (_writeGeneration == gen) {
      _rememberIdPageCache(page, recs);
      _pages.remove('dict:$page');
    }
    return recs;
  }

  Future<_RevNode> _readRevNode(int page) async {
    final cached = _revNodeCache.get(page);
    if (cached != null) return cached;
    final int gen = _writeGeneration;
    final pageBytes = await _readGlobal('rev', page);
    // A concurrent [_writeRevNode] may have landed while we awaited I/O.
    final raced = _revNodeCache.get(page);
    if (raced != null) return raced;
    return _decodeRevNode(page, pageBytes, cache: _writeGeneration == gen);
  }

  /// Resident-only read: decoded cache, raw page cache, then staged volume.
  /// Null means the caller must await [_readRevNode].
  _RevNode? _readRevNodeSync(int page) {
    final cached = _revNodeCache.get(page);
    if (cached != null) return cached;
    var raw = _pages.get('rev:$page');
    if (raw == null) {
      final (partition, local) = _physical('rev', page);
      if (partition < 0 || local < 0) return null;
      raw = volume.readAtSync(
        'rev',
        partition,
        local * WmbpConstants.storePageSize,
        WmbpConstants.storePageSize,
      );
      if (raw == null) return null;
    }
    return _decodeRevNode(page, raw, cache: true);
  }

  _RevNode _decodeRevNode(
    int page,
    Uint8List? pageBytes, {
    required bool cache,
  }) {
    final payload = _framedPayloadOrNull(pageBytes);
    if (payload == null || payload.isEmpty) {
      // Not cached: an unwritten slot must not shadow a later write.
      return _RevNode.leaf(<_RevRec>[]);
    }
    final reader = _R(payload);
    final int kind = reader.u8();
    final _RevNode node;
    if (kind == 2) {
      final int childCount = reader.u16();
      final children = <int>[for (int i = 0; i < childCount; i++) reader.u32()];
      final int sepCount = reader.u16();
      final separators = <String>[
        for (int i = 0; i < sepCount; i++) reader.str(reader.u16()),
      ];
      node = _RevNode.internal(children: children, separators: separators);
    } else {
      final int n = reader.u16();
      final recs = <_RevRec>[];
      for (int i = 0; i < n; i++) {
        final int len = reader.u16();
        recs.add(_RevRec(reader.str(len), reader.u64()));
      }
      node = _RevNode.leaf(recs);
    }
    if (cache) {
      _revNodeCache.put(page, node, size: _estimateRevNodeBytes(node));
      _pages.remove('rev:$page');
    }
    return node;
  }

  Future<void> _writeNamePage(int page, List<_NameRec> recs,
      {required bool stable}) {
    _rememberNamePageCache(page, recs);
    return _writeFramed('dict', page, 2, _nameBytes(recs), stable: stable);
  }

  Future<void> _writeRevNode(int page, _RevNode node, {required bool stable}) {
    _revNodeCache.put(page, node, size: _estimateRevNodeBytes(node));
    return _writeFramed('rev', page, node.leaf ? 7 : 13, _revNodeBytes(node),
        stable: stable);
  }

  static void _pushChampion(List<WmbpChampionPosting> list, int docId, int q8) {
    WmbpChampionPosting.pushOrdered(list, docId, q8);
  }

  /// True when [offsets] is already non-decreasing (first-seal / append-tail).
  static bool _isNonDecreasing(List<int> offsets) {
    for (int i = 1; i < offsets.length; i++) {
      if (offsets[i] < offsets[i - 1]) return false;
    }
    return true;
  }
}

Uint8List _payload(Uint8List page) {
  final data = ByteData.sublistView(page);
  final int len = data.getUint32(12, Endian.little);
  if (len <= 0) return Uint8List(0);
  final int end = WmbpConstants.pageHeaderSize + len;
  if (end > page.length) {
    return Uint8List.sublistView(page, WmbpConstants.pageHeaderSize);
  }
  return Uint8List.sublistView(page, WmbpConstants.pageHeaderSize, end);
}

/// Valid framed WMBP page payload, or null when missing / not magic / empty.
Uint8List? _framedPayloadOrNull(Uint8List? page) {
  if (page == null || page.length < WmbpConstants.storePageSize) return null;
  final data = ByteData.sublistView(page);
  if (data.getUint32(0, Endian.little) != WmbpPageCodecMagic.magic) {
    return null;
  }
  final payload = _payload(page);
  return payload.isEmpty ? null : payload;
}

Uint8List _nameBytes(List<_NameRec> recs) {
  final writer = _W()..u16(recs.length);
  var prev = '';
  for (final rec in recs) {
    final int share = _sharedPrefix(prev, rec.name);
    final bytes = utf8.encode(rec.name.substring(share));
    writer
      ..u32(rec.termId)
      ..u16(share)
      ..u16(bytes.length)
      ..raw(bytes);
    prev = rec.name;
  }
  return writer.bytes();
}

int _sharedPrefix(String left, String right) {
  final int n = left.length < right.length ? left.length : right.length;
  var i = 0;
  while (i < n && left.codeUnitAt(i) == right.codeUnitAt(i)) {
    i++;
  }
  return i;
}

String _utf8(Uint8List bytes, int offset, int length) {
  try {
    return utf8.decode(Uint8List.sublistView(bytes, offset, offset + length));
  } on FormatException {
    throw DbException([
      GeneralStatus(
        type: ResultType.sysInvalidDataFormat,
        message: 'WMBP primary key is not valid UTF-8',
        operation: 'wmbpFwd',
      ),
    ]);
  }
}

Uint8List _revNodeBytes(_RevNode node) {
  final writer = _W();
  if (!node.leaf) {
    writer
      ..u8(2)
      ..u16(node.children.length);
    for (final child in node.children) {
      writer.u32(child);
    }
    writer.u16(node.separators.length);
    for (final key in node.separators) {
      final bytes = utf8.encode(key);
      writer
        ..u16(bytes.length)
        ..raw(bytes);
    }
    return writer.bytes();
  }
  writer
    ..u8(1)
    ..u16(node.records.length);
  for (final rec in node.records) {
    final bytes = utf8.encode(rec.pk);
    writer
      ..u16(bytes.length)
      ..raw(bytes)
      ..u64(rec.docId);
  }
  return writer.bytes();
}

void _setMaskBit(Uint8List mask, int offset, bool on) {
  final int index = offset >> 3;
  if (index < 0 || index >= mask.length) return;
  final int bit = 1 << (offset & 7);
  if (on) {
    mask[index] |= bit;
  } else {
    mask[index] &= ~bit & 0xFF;
  }
}

bool _maskBitOn(Uint8List mask, int offset) {
  final int index = offset >> 3;
  if (index < 0 || index >= mask.length) return false;
  return (mask[index] & (1 << (offset & 7))) != 0;
}

Uint32List _maskWordsFromPayload(Uint8List payload) {
  final words = Uint32List(WmbpConstants.activeMaskWords);
  final data = ByteData.sublistView(payload);
  final int limit = payload.length ~/ 4;
  final int n = limit < words.length ? limit : words.length;
  for (int i = 0; i < n; i++) {
    words[i] = data.getUint32(i * 4, Endian.little);
  }
  return words;
}

abstract final class WmbpPageCodecMagic {
  static const int magic = 0x50424D57;
}

class _W {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  int get length => _builder.length;

  void u8(int value) => _builder.addByte(value & 0xFF);

  void u16(int value) {
    _builder.addByte(value & 0xFF);
    _builder.addByte((value >> 8) & 0xFF);
  }

  void u32(int value) {
    _builder.addByte(value & 0xFF);
    _builder.addByte((value >> 8) & 0xFF);
    _builder.addByte((value >> 16) & 0xFF);
    _builder.addByte((value >> 24) & 0xFF);
  }

  void u64(int value) {
    u32(PlatformByteData.lo32(value));
    u32(PlatformByteData.hi32(value));
  }

  void raw(List<int> bytes) => _builder.add(bytes);

  Uint8List bytes() => _builder.toBytes();
}

class _R {
  final Uint8List bytes;
  int i = 0;

  _R(this.bytes);

  int get remaining => bytes.length - i;

  int u8() {
    _need(1);
    return bytes[i++];
  }

  int u16() {
    _need(2);
    final int v = bytes[i] | (bytes[i + 1] << 8);
    i += 2;
    return v;
  }

  int u32() {
    _need(4);
    final int v = bytes[i] |
        (bytes[i + 1] << 8) |
        (bytes[i + 2] << 16) |
        (bytes[i + 3] << 24);
    i += 4;
    return v & 0xFFFFFFFF;
  }

  int u64() {
    final int lo = u32();
    final int hi = u32();
    return PlatformByteData.fromLoHi32(lo, hi);
  }

  String str(int length) {
    _need(length);
    try {
      final out = utf8.decode(bytes.sublist(i, i + length));
      i += length;
      return out;
    } on FormatException {
      throw DbException([
        GeneralStatus(
          type: ResultType.sysInvalidDataFormat,
          message: 'WMBP page text is not valid UTF-8',
          operation: 'wmbpRead',
        ),
      ]);
    }
  }

  void _need(int n) {
    if (remaining < n) {
      throw DbException([
        GeneralStatus(
          type: ResultType.sysIoDataCorrupted,
          message:
              'WMBP page payload is truncated (needed $n, remaining $remaining, offset $i, total ${bytes.length})',
          operation: 'wmbpRead',
        ),
      ]);
    }
  }
}
