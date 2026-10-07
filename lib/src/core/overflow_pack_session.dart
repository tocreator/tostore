import 'dart:typed_data';

import '../interface/storage_interface.dart';
import '../model/db_exception.dart';
import '../model/parallel_journal_entry.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/table_context.dart';
import '../model/value_ref.dart';
import 'btree_page.dart';
import 'overflow_manager.dart';
import 'page_redo_log_codec.dart';

/// In-memory batch packer for OVP2 mixed overflow (single apply / flush path).
///
/// Allocates slots across half-full pages (FSM), empty freelist pages, and file
/// growth; stages page bytes into [writeBuffer]. Holds the partition lock from
/// [OverflowManager.beginPackSession] until [finish]/[rollback].
final class OverflowPackSession {
  final OverflowManager manager;
  final TableContext table;
  final int pageSize;
  final int partitionNo;
  final String path;
  final Uint8List? encryptionKey;
  final int? encryptionKeyId;
  final OverflowWriteBuffer writeBuffer;
  final int payloadCapacity;
  final int maxChunkLen;

  PartitionMetaPage meta;

  /// Durable meta checkpoint for rollback. Advanced after each successful
  /// mid-flush persist so growth/freelist pops are never rewound below disk.
  PartitionMetaPage rollbackMeta;
  OverflowFsmPage fsm;

  /// Pre-popped freelist page numbers for mixed packing (no async during pack).
  final List<int> reusableFreePages;
  final Map<int, OverflowPackedPage> dirtyPages = {};

  /// Pages that already held (or may hold) live mixed slots before this session
  /// mutation — after-image must go to page redo before overwrite.
  final Set<int> pagesNeedingRedo = {};

  /// When false, skip FSM shared pages (recovery reflush without page redo).
  final bool allowSharedPageOverwrite;
  int sizeDeltaBytes = 0;
  bool _committed = false;
  bool _rolledBack = false;
  void Function()? _releaseLock;

  OverflowPackSession({
    required this.manager,
    required this.table,
    required this.pageSize,
    required this.partitionNo,
    required this.path,
    required this.encryptionKey,
    required this.encryptionKeyId,
    required this.writeBuffer,
    required this.payloadCapacity,
    required this.maxChunkLen,
    required this.meta,
    required this.rollbackMeta,
    required this.fsm,
    List<int>? reusableFreePages,
    void Function()? releaseLock,
    this.allowSharedPageOverwrite = true,
  })  : reusableFreePages = reusableFreePages ?? <int>[],
        _releaseLock = releaseLock;

  void _releaseLockIfHeld() {
    final release = _releaseLock;
    _releaseLock = null;
    release?.call();
  }

  /// Pack [valueBytes] into OVP2 slots / full-page extents; return ValueRef v2.
  ValueRef packValue(Uint8List valueBytes) {
    if (_committed || _rolledBack) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'OverflowPackSession already finished',
        ),
      ]);
    }
    if (valueBytes.isEmpty) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.engError,
          message: 'packValue: valueBytes must not be empty',
          parameterName: 'valueBytes',
          passedValue: 0,
        ),
      ]);
    }

    final crc = Crc32.of(valueBytes);
    final chunks = _split(valueBytes, maxChunkLen);
    final fragments = <OverflowFragment>[];

    // Group consecutive max-size chunks into exclusive full-page extents when
    // we can allocate contiguous new pages; smaller / remainder use mixed slots.
    var i = 0;
    while (i < chunks.length) {
      final chunk = chunks[i];
      final isFull = chunk.length == maxChunkLen;
      if (isFull) {
        var run = 1;
        while (
            i + run < chunks.length && chunks[i + run].length == maxChunkLen) {
          run++;
        }
        final pages = _allocateContiguousPages(run);
        if (pages != null && pages.length == run) {
          for (int k = 0; k < run; k++) {
            _writeExclusiveFullPage(pages[k], chunks[i + k]);
          }
          fragments.add(OverflowFragment.extent(
            pageNo: pages.first,
            pageCount: run,
          ));
          i += run;
          continue;
        }
      }

      final (pageNo, slotId) = _insertIntoMixedPage(chunk);
      fragments.add(OverflowFragment.slot(pageNo: pageNo, slotId: slotId));
      i++;
    }

    List<OverflowFragment> wireFrags = fragments;
    var indirect = false;
    if (fragments.length > ValueRef.maxInlineFragments) {
      final dirBytes = _encodeFragmentDirectory(fragments);
      if (dirBytes.length > maxChunkLen) {
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message: 'Overflow fragment directory too large: '
                '${fragments.length} fragments (${dirBytes.length} bytes) '
                'exceed maxChunkLen=$maxChunkLen',
          ),
        ]);
      }
      final (dirPage, dirSlot) = _insertIntoMixedPage(dirBytes);
      wireFrags = [
        OverflowFragment.slot(pageNo: dirPage, slotId: dirSlot),
      ];
      indirect = true;
    }

    return ValueRef.overflowV2(
      overflowPartitionNo: partitionNo,
      totalLen: valueBytes.length,
      crc32: crc,
      fragments: wireFrags,
      indirectDirectory: indirect,
    );
  }

  /// Stage dirty packed pages (+ FSM) into [writeBuffer].
  ///
  /// Returns encoded [PageRedoPageRecord] bytes for pages in [pagesNeedingRedo]
  /// (full after-images). Caller must append/fsync those redo records before
  /// [OverflowWriteBuffer.commit].
  Future<List<Uint8List>> flushDirtyPages() async {
    final redoRecords = <Uint8List>[];
    final writes = <ByteWrite>[];
    final flushedRedoPages = <int>[];
    for (final e in dirtyPages.entries) {
      final pageBytes = manager.buildOverflowPageBytes(
        partitionNo: partitionNo,
        pageNo: e.key,
        payload: e.value.encodePayload(),
        pageSize: pageSize,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
      );
      if (pagesNeedingRedo.contains(e.key)) {
        redoRecords.add(PageRedoLogCodec.encodePageRecord(
          treeKind: PageRedoTreeKind.overflow,
          tableUid: table.tableUid,
          partitionNo: partitionNo,
          pageNo: e.key,
          payload: pageBytes,
        ));
        flushedRedoPages.add(e.key);
      }
      writes.add(ByteWrite(
        offset: e.key * pageSize,
        bytes: pageBytes,
      ));
      manager.cachePackedPage(
        table.tableUid,
        partitionNo,
        e.key,
        e.value,
      );
    }
    // FSM page — space map only; slot payloads live on data pages.
    var fsmPageNo = meta.fsmPageNo;
    if (fsmPageNo <= 0) {
      final allocated = _allocateContiguousPages(1);
      if (allocated == null || allocated.isEmpty) {
        throw DbException([
          GeneralStatus(
            type: ResultType.sysResourceExhausted,
            message: 'Cannot allocate FSM page for overflow partition',
          ),
        ]);
      }
      fsmPageNo = allocated.first;
      meta = meta.copyWith(fsmPageNo: fsmPageNo);
    }
    fsm.compactToFit(payloadCapacity);
    writes.add(ByteWrite(
      offset: fsmPageNo * pageSize,
      bytes: manager.buildOverflowPageBytes(
        partitionNo: partitionNo,
        pageNo: fsmPageNo,
        payload: fsm.encodePayload(capacity: payloadCapacity),
        pageSize: pageSize,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
      ),
    ));
    if (writes.isNotEmpty) {
      writeBuffer.addWrites(path, writes);
    }
    dirtyPages.clear();
    for (final pn in flushedRedoPages) {
      pagesNeedingRedo.remove(pn);
    }
    return redoRecords;
  }

  /// Mid-batch flush: redo → page IO → durable meta (prevents page-number reuse).
  ///
  /// After success, [rollbackMeta] advances to the persisted checkpoint so a
  /// later rollback cannot rewind file growth / freelist pops.
  Future<void> flushPersist({
    BatchContext? batchContext,
    bool flush = false,
  }) async {
    if (_committed || _rolledBack) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'OverflowPackSession already finished',
        ),
      ]);
    }
    final redo = await flushDirtyPages();
    await manager.appendOverflowPageRedoIfNeeded(
      batchContext: batchContext,
      redoRecords: redo,
    );
    final hadWrites = !writeBuffer.isEmpty;
    if (hadWrites) {
      await writeBuffer.commit(manager.storage, flush: flush);
    }
    try {
      await manager.commitPackSessionMeta(
        path: path,
        pageSize: pageSize,
        partitionNo: partitionNo,
        meta: meta,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        flush: flush,
        alreadyHoldingLock: true,
        keepInflight: true,
      );
      rollbackMeta = meta;
    } catch (_) {
      // Pages may already be durable; never leave meta behind page growth.
      if (hadWrites) {
        try {
          await manager.commitPackSessionMeta(
            path: path,
            pageSize: pageSize,
            partitionNo: partitionNo,
            meta: meta,
            encryptionKey: encryptionKey,
            encryptionKeyId: encryptionKeyId,
            flush: flush,
            alreadyHoldingLock: true,
            keepInflight: true,
          );
          rollbackMeta = meta;
        } catch (_) {}
      }
      rethrow;
    }
  }

  /// Commit meta/pages after all [packValue] calls.
  ///
  /// When [batchContext] records page redo, mixed-page after-images are
  /// appended and fsynced before overflow page IO.
  Future<({int overflowPartitionCount, int sizeDeltaBytes})> finish({
    bool flush = false,
    BatchContext? batchContext,
  }) async {
    if (_committed || _rolledBack) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'OverflowPackSession already finished',
        ),
      ]);
    }
    // On failure keep the partition lock so [rollback] can run safely.
    // Return unused pre-popped freelist pages so they are not leaked.
    if (reusableFreePages.isNotEmpty) {
      var head = meta.freeListHeadPageNo;
      var count = meta.freePageCount;
      final writes = <ByteWrite>[];
      for (final pn in reusableFreePages) {
        writes.add(ByteWrite(
          offset: pn * pageSize,
          bytes: manager.buildFreePageBytes(
            partitionNo: partitionNo,
            pageNo: pn,
            nextFreePageNo: head,
            pageSize: pageSize,
            encryptionKey: encryptionKey,
            encryptionKeyId: encryptionKeyId,
          ),
        ));
        head = pn;
        count += 1;
      }
      writeBuffer.addWrites(path, writes);
      reusableFreePages.clear();
      meta = meta.copyWith(freeListHeadPageNo: head, freePageCount: count);
    }

    final redo = await flushDirtyPages();
    await manager.appendOverflowPageRedoIfNeeded(
      batchContext: batchContext,
      redoRecords: redo,
    );
    final hadWrites = !writeBuffer.isEmpty;
    if (hadWrites) {
      await writeBuffer.commit(manager.storage, flush: flush);
    }
    try {
      await manager.commitPackSessionMeta(
        path: path,
        pageSize: pageSize,
        partitionNo: partitionNo,
        meta: meta,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        flush: flush,
        alreadyHoldingLock: true,
        keepInflight: false,
      );
    } catch (_) {
      if (hadWrites) {
        try {
          await manager.commitPackSessionMeta(
            path: path,
            pageSize: pageSize,
            partitionNo: partitionNo,
            meta: meta,
            encryptionKey: encryptionKey,
            encryptionKeyId: encryptionKeyId,
            flush: flush,
            alreadyHoldingLock: true,
            keepInflight: false,
          );
        } catch (_) {}
      }
      rethrow;
    }
    rollbackMeta = meta;
    _committed = true;
    _releaseLockIfHeld();
    return (
      overflowPartitionCount: partitionNo + 1,
      sizeDeltaBytes: sizeDeltaBytes,
    );
  }

  Future<void> rollback() async {
    if (_committed) return;
    if (_rolledBack) {
      _releaseLockIfHeld();
      return;
    }
    _rolledBack = true;
    dirtyPages.clear();
    pagesNeedingRedo.clear();
    try {
      await manager.rollbackAllocation(
        table: table,
        partitionNo: partitionNo,
        pageSize: pageSize,
        previousMeta: rollbackMeta,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        flush: false,
        alreadyHoldingLock: true,
      );
    } finally {
      _releaseLockIfHeld();
    }
  }

  (int pageNo, int slotId) _insertIntoMixedPage(Uint8List chunk) {
    final need = chunk.length + OverflowPackedPage.slotEntrySize;
    // 1) FSM half-full — shared pages; always need redo on overwrite.
    //    Never invent an empty page on cache miss (would wipe live slots).
    //    Disabled when [allowSharedPageOverwrite] is false.
    if (allowSharedPageOverwrite) {
      final fromFsm = fsm.findPageWithSpace(need);
      if (fromFsm != null) {
        final page = _tryLoadPacked(fromFsm);
        if (page == null) {
          fsm.setFree(fromFsm, 0);
        } else if (page.canFit(chunk.length)) {
          pagesNeedingRedo.add(fromFsm);
          final slotId = page.insert(chunk);
          dirtyPages[fromFsm] = page;
          fsm.setFree(fromFsm, page.freeBytes);
          return (fromFsm, slotId);
        } else {
          // Heal stale FSM entry
          fsm.setFree(fromFsm, page.freeBytes);
        }
      }
    }

    // 2) Empty freelist page — first use; no live slots → no redo.
    final freePage = _popFreePage();
    if (freePage != null) {
      final page = OverflowPackedPage.empty(payloadCapacity);
      final slotId = page.insert(chunk);
      dirtyPages[freePage] = page;
      fsm.setFree(freePage, page.freeBytes);
      return (freePage, slotId);
    }

    // 3) Grow — brand-new pages; no redo.
    final grown = _allocateContiguousPages(1);
    if (grown == null || grown.isEmpty) {
      throw DbException([
        GeneralStatus(
          type: ResultType.sysResourceExhausted,
          message: 'Overflow pack: cannot grow page for chunk=${chunk.length}',
        ),
      ]);
    }
    final pageNo = grown.first;
    final page = OverflowPackedPage.empty(payloadCapacity);
    final slotId = page.insert(chunk);
    dirtyPages[pageNo] = page;
    fsm.setFree(pageNo, page.freeBytes);
    return (pageNo, slotId);
  }

  void _writeExclusiveFullPage(int pageNo, Uint8List chunk) {
    final page = OverflowPackedPage.empty(payloadCapacity);
    page.insert(chunk);
    dirtyPages[pageNo] = page;
    // Full or near-full: leave out of FSM when freeBytes is tiny.
    if (page.freeBytes > OverflowPackedPage.slotEntrySize + 64) {
      fsm.setFree(pageNo, page.freeBytes);
    } else {
      fsm.setFree(pageNo, 0);
    }
  }

  /// Load an existing packed page for mutation. Returns null if unavailable —
  /// caller must heal FSM / fall through (never fabricate an empty page).
  OverflowPackedPage? _tryLoadPacked(int pageNo) {
    final dirty = dirtyPages[pageNo];
    if (dirty != null) return dirty;
    final cached = manager.getCachedPackedPage(
      table.tableUid,
      partitionNo,
      pageNo,
    );
    if (cached == null) return null;
    if (cached.hasLiveSlots) {
      pagesNeedingRedo.add(pageNo);
    }
    final copy = OverflowPackedPage(
      capacity: cached.capacity,
      slots: List<Uint8List?>.from(cached.slots),
    );
    dirtyPages[pageNo] = copy;
    return copy;
  }

  int? _popFreePage() {
    if (reusableFreePages.isEmpty) return null;
    final pageNo = reusableFreePages.removeLast();
    if (meta.freePageCount > 0) {
      meta = meta.copyWith(freePageCount: meta.freePageCount - 1);
    }
    return pageNo;
  }

  List<int>? _allocateContiguousPages(int count) {
    if (count <= 0) return const <int>[];
    final startPage = meta.totalSizeBytes ~/ pageSize;
    final pageNos = <int>[];
    for (int i = 0; i < count; i++) {
      pageNos.add(startPage + i);
    }
    // Ensure startPage >= 1
    if (pageNos.first < 1) {
      final shift = 1 - pageNos.first;
      for (int i = 0; i < pageNos.length; i++) {
        pageNos[i] += shift;
      }
    }
    final newSize = (pageNos.last + 1) * pageSize;
    final delta = newSize - meta.totalSizeBytes;
    if (delta > 0) sizeDeltaBytes += delta;
    meta = meta.copyWith(
        totalSizeBytes:
            newSize > meta.totalSizeBytes ? newSize : meta.totalSizeBytes);
    return pageNos;
  }

  static List<Uint8List> _split(Uint8List bytes, int chunkSize) {
    if (bytes.isEmpty) return const [];
    final out = <Uint8List>[];
    var off = 0;
    while (off < bytes.length) {
      final end =
          off + chunkSize < bytes.length ? off + chunkSize : bytes.length;
      out.add(bytes.sublist(off, end));
      off = end;
    }
    return out;
  }

  static Uint8List _encodeFragmentDirectory(List<OverflowFragment> frags) {
    final out = Uint8List(2 + frags.length * 7);
    final bd = ByteData.sublistView(out);
    bd.setUint16(0, frags.length, Endian.little);
    var off = 2;
    for (final f in frags) {
      out[off] = f.kind == OverflowFragmentKind.extent ? 0 : 1;
      bd.setUint32(off + 1, f.pageNo, Endian.little);
      bd.setUint16(off + 5, f.countOrSlot, Endian.little);
      off += 7;
    }
    return out;
  }
}

/// Decode indirect directory bytes produced by [OverflowPackSession].
List<OverflowFragment> decodeOverflowFragmentDirectory(Uint8List bytes) {
  if (bytes.length < 2) return const [];
  final bd = ByteData.sublistView(bytes);
  final count = bd.getUint16(0, Endian.little);
  if (2 + count * 7 > bytes.length) return const [];
  final out = <OverflowFragment>[];
  var off = 2;
  for (int i = 0; i < count; i++) {
    final type = bytes[off];
    final pageNo = bd.getUint32(off + 1, Endian.little);
    final cos = bd.getUint16(off + 5, Endian.little);
    if (type == 0) {
      out.add(OverflowFragment.extent(pageNo: pageNo, pageCount: cos));
    } else {
      out.add(OverflowFragment.slot(pageNo: pageNo, slotId: cos));
    }
    off += 7;
  }
  return out;
}
