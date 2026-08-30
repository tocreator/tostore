import 'dart:async';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../interface/storage_interface.dart';
import '../handler/logger.dart';
import '../model/db_exception.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/value_ref.dart';
import '../model/data_store_config.dart';
import '../model/table_context.dart';
import '../model/table_identity.dart';
import 'btree_page.dart';
import 'data_store_impl.dart';
import 'tree_cache.dart';

/// Out-of-line large value store (TOAST-like), page based.
///
/// Storage format:
/// - One or more overflow partition files per table, each file is a BTree-like
///   page file with:
///   - pageNo=0: [PartitionMetaPage] (tracks fileSize + freelist)
///   - pageNo>=1: [OverflowPage] or [FreePage]
///
/// Notes:
/// - This manager is **write-order safe** for references: we write overflow pages
///   first, then callers store the resulting [ValueRef] bytes in the primary tree.
/// - Reuse via freelist is supported, but freeing old blobs is intentionally
///   **best-effort** and should be wired to a safe GC policy later.
final class OverflowAllocationResult {
  final ValueRef ref;
  final int overflowPartitionCount;

  /// File-size growth from this allocation (freelist reuse => 0).
  final int sizeDeltaBytes;

  const OverflowAllocationResult({
    required this.ref,
    required this.overflowPartitionCount,
    this.sizeDeltaBytes = 0,
  });
}

final class OverflowManager {
  final DataStoreImpl _dataStore;

  // Page cache for fast retrieval: [tableUid, partitionNo, pageNo] -> OverflowPage
  late final TreeCache<OverflowPage> _pageCache;

  OverflowManager(this._dataStore) {
    final resourceManager = _dataStore.resourceManager;
    final recordCacheSize =
        resourceManager?.getTableDataCacheSize() ?? (128 * 1024 * 1024);
    // Allocate 15% of table cache for Overflow pages
    final int overflowCacheSize = (recordCacheSize * 0.15).toInt();
    final bool isMemoryMode =
        _dataStore.config.persistenceMode == PersistenceMode.memory;

    _pageCache = TreeCache<OverflowPage>(
      sizeCalculator: (page) => page.data.length + 32,
      maxByteThreshold: overflowCacheSize,
      minByteThreshold: 30 * 1024 * 1024, // 30MB minimum
      groupDepth: 1, // Group by tableUid
      evictionMode:
          isMemoryMode ? TreeCacheEvictionMode.none : TreeCacheEvictionMode.lru,
      debugLabel: 'OverflowPageCache',
    );
  }

  // Locks to prevent concurrent metadata updates (race on free list/file size).
  final Map<String, SimpleLock> _locks = {};

  SimpleLock _getLock(String path) {
    return _locks.putIfAbsent(path, () => SimpleLock());
  }

  int _thresholdForPageSize(int pageSize) {
    // Only externalize when value is large enough to materially impact splits.
    final t = pageSize ~/ 4;
    return t < 512 ? 512 : t;
  }

  bool shouldExternalize(int pageSize, int valueLen) {
    return valueLen >= _thresholdForPageSize(pageSize);
  }

  int estimatePageCount({
    required int valueLen,
    required int pageSize,
    int? encryptionKeyId,
  }) {
    final maxChunk = _maxChunkLen(pageSize, encryptionKeyId: encryptionKeyId);
    return (valueLen + maxChunk - 1) ~/ maxChunk;
  }

  Future<
      ({
        int partitionNo,
        List<int> pageNos,
        int updatedPartitionCount,
        int sizeDeltaBytes,
      })> _allocatePages({
    required int count,
    required TableContext table,
    required int pageSize,
    required int overflowPartitionCount,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool flush = true,
  }) async {
    if (count <= 0) {
      final pNo =
          (overflowPartitionCount - 1) < 0 ? 0 : overflowPartitionCount - 1;
      return (
        partitionNo: pNo,
        pageNos: const <int>[],
        updatedPartitionCount:
            overflowPartitionCount < 1 ? 1 : overflowPartitionCount,
        sizeDeltaBytes: 0,
      );
    }

    int activePNo =
        (overflowPartitionCount - 1) < 0 ? 0 : overflowPartitionCount - 1;
    int currentCount = overflowPartitionCount < 1 ? 1 : overflowPartitionCount;
    final maxPartitionSize = _dataStore.config.maxPartitionFileSize;

    while (true) {
      final path = _overflowPath(table, activePNo);
      final allocated = await _getLock(path).synchronized(() async {
        await _ensureFileInitialized(
          path: path,
          pageSize: pageSize,
          partitionNo: activePNo,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
          flush: flush,
        );

        final meta = await _readMeta(
          path: path,
          pageSize: pageSize,
          partitionNo: activePNo,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
        );

        // Check if rotation is needed:
        // If current partition already has data (> pageSize) and adding `count` pages
        // would exceed maxPartitionFileSize, and there are not enough free pages, rotate.
        final int neededBytes = count * pageSize;
        final bool isNonEmpty = meta.totalSizeBytes > pageSize;
        final bool willExceed =
            (meta.totalSizeBytes + neededBytes) > maxPartitionSize;

        if (isNonEmpty && willExceed && meta.freePageCount < count) {
          return null; // Signal rotation
        }

        return await _allocatePageNos(
          count: count,
          path: path,
          pageSize: pageSize,
          partitionNo: activePNo,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
          flush: flush,
          cachedMeta: meta,
        );
      });

      if (allocated != null) {
        return (
          partitionNo: activePNo,
          pageNos: allocated.pageNos,
          updatedPartitionCount: currentCount,
          sizeDeltaBytes: allocated.sizeDeltaBytes,
        );
      }

      // Rotate to next partition
      activePNo += 1;
      currentCount = activePNo + 1;
    }
  }

  Future<OverflowBatchAllocator> startBatchAllocation({
    required int totalChunks,
    required TableContext table,
    required int pageSize,
    int overflowPartitionCount = 1,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool flush = true,
  }) async {
    final allocRes = await _allocatePages(
      count: totalChunks,
      table: table,
      pageSize: pageSize,
      overflowPartitionCount: overflowPartitionCount,
      encryptionKey: encryptionKey,
      encryptionKeyId: encryptionKeyId,
      flush: flush,
    );

    return OverflowBatchAllocator(
      partitionNo: allocRes.partitionNo,
      pages: allocRes.pageNos,
      updatedOverflowPartitionCount: allocRes.updatedPartitionCount,
      sizeDeltaBytes: allocRes.sizeDeltaBytes,
    );
  }

  Future<OverflowAllocationResult> putLargeValue({
    required TableContext table,
    required Uint8List valueBytes,
    required int pageSize,
    int overflowPartitionCount = 1,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool flush = true,
    OverflowBatchAllocator? allocator,
  }) async {
    if (valueBytes.isEmpty) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.engError,
          message: 'put large value: valueBytes must not be empty',
          parameterName: 'valueBytes',
          passedValue: valueBytes.length,
        ),
      ]);
    }

    final crc = Crc32.of(valueBytes);
    final maxChunk = _maxChunkLen(
      pageSize,
      encryptionKeyId: encryptionKeyId,
    );
    final chunks = _splitIntoChunks(valueBytes, maxChunk);

    final int targetPartitionNo;
    final List<int> pageNos;
    final int updatedPartitionCount;
    final int sizeDeltaBytes;

    if (allocator != null) {
      targetPartitionNo = allocator.partitionNo;
      pageNos = allocator.next(chunks.length);
      updatedPartitionCount = allocator.updatedOverflowPartitionCount;
      // Batch allocator already accounted file growth at startBatchAllocation.
      sizeDeltaBytes = 0;
    } else {
      final allocRes = await _allocatePages(
        count: chunks.length,
        table: table,
        pageSize: pageSize,
        overflowPartitionCount: overflowPartitionCount,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        flush: flush,
      );
      targetPartitionNo = allocRes.partitionNo;
      pageNos = allocRes.pageNos;
      updatedPartitionCount = allocRes.updatedPartitionCount;
      sizeDeltaBytes = allocRes.sizeDeltaBytes;
    }

    final path = _overflowPath(table, targetPartitionNo);
    final writes = <ByteWrite>[];
    for (int i = 0; i < pageNos.length; i++) {
      final pn = pageNos[i];
      final next = (i + 1 < pageNos.length) ? pageNos[i + 1] : -1;
      final page = OverflowPage(nextPageNo: next, data: chunks[i]);
      final payload = page.encodePayload();
      final encodedPayload = BTreePageCodec.encodePayload(
        payload,
        config: _dataStore.config,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        aad: _aadForOverflowPage(targetPartitionNo, pn),
      );
      final pageBytes = BTreePageIO.buildPageBytes(
        type: BTreePageType.overflow,
        encodedPayload: encodedPayload,
        pageSize: pageSize,
      );
      writes.add(ByteWrite(offset: pn * pageSize, bytes: pageBytes));
    }

    // IMPORTANT: write overflow pages first (reference safety).
    await _dataStore.storage.writeManyAsBytesAt(path, writes, flush: flush);

    // Warm cache with newly written pages
    for (int i = 0; i < pageNos.length; i++) {
      final pn = pageNos[i];
      final next = (i + 1 < pageNos.length) ? pageNos[i + 1] : -1;
      final page = OverflowPage(nextPageNo: next, data: chunks[i]);
      _pageCache.putPoint3(table.tableUid, targetPartitionNo, pn, page);
    }

    final ref = ValueRef.overflow(
      overflowPartitionNo: targetPartitionNo,
      startPageNo: pageNos.first,
      totalLen: valueBytes.length,
      crc32: crc,
    );

    return OverflowAllocationResult(
      ref: ref,
      overflowPartitionCount: updatedPartitionCount,
      sizeDeltaBytes: sizeDeltaBytes,
    );
  }

  /// Free overflow pages back to the freelist.
  Future<void> deleteLargeValue({
    required TableContext table,
    required ValueRef ref,
    required int pageSize,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    if (ref.kind != ValueRef.kindOverflow) return;

    final path = _overflowPath(table, ref.overflowPartitionNo);
    if (!await _dataStore.storage.existsFile(path)) return;

    await _getLock(path).synchronized(() async {
      // 1. Follow the chain to collect all page numbers.
      final pageNos = <int>[];
      int curPageNo = ref.startPageNo;
      int guard = 0;
      while (curPageNo > 0) {
        if (guard++ > 1 << 20) break; // cycle safety
        pageNos.add(curPageNo);

        // Check cache first for nextPageNo
        final cached = _pageCache.getPoint3(
          table.tableUid,
          ref.overflowPartitionNo,
          curPageNo,
        );
        if (cached != null) {
          curPageNo = cached.nextPageNo;
          continue;
        }

        // We only need to read the nextPageNo to follow the chain.
        // Reading the whole page is slightly expensive but safer for CRC/type checks.
        final pageBytes = await _dataStore.storage
            .readAsBytesAt(path, curPageNo * pageSize, length: pageSize);
        if (pageBytes.isEmpty) break;
        try {
          final parsed = BTreePageIO.parsePageBytes(pageBytes);
          if (parsed.type != BTreePageType.overflow) break;
          final decodedPayload = BTreePageCodec.decodePayload(
            parsed.encodedPayload,
            encryptionKey: encryptionKey,
            encryptionKeyId: encryptionKeyId,
            aad: _aadForOverflowPage(ref.overflowPartitionNo, curPageNo),
          );
          final page = OverflowPage.tryDecodePayload(decodedPayload);
          if (page == null) break;
          curPageNo = page.nextPageNo;
        } catch (_) {
          break; // stop on corruption
        }
      }

      if (pageNos.isEmpty) return;

      // Invalidate removed pages from cache
      for (final pn in pageNos) {
        _pageCache.removePoint3(table.tableUid, ref.overflowPartitionNo, pn);
      }

      // 2. Read meta to get current freelist head.
      final meta = await _readMeta(
        path: path,
        pageSize: pageSize,
        partitionNo: ref.overflowPartitionNo,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
      );

      // 3. Chain these pages and link the last one to current freelist head.
      final writes = <ByteWrite>[];
      int nextInFree = meta.freeListHeadPageNo;
      // We iterate backwards so the first page of the chain points to the rest,
      // and the last page points to the old head.
      for (int i = pageNos.length - 1; i >= 0; i--) {
        final pn = pageNos[i];
        final freePage = FreePage(nextFreePageNo: nextInFree);
        final payload = freePage.encodePayload();
        final encodedPayload = BTreePageCodec.encodePayload(
          payload,
          config: _dataStore.config,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
          aad: _aadForOverflowPage(ref.overflowPartitionNo, pn),
        );
        final pageBytes = BTreePageIO.buildPageBytes(
          type: BTreePageType.free,
          encodedPayload: encodedPayload,
          pageSize: pageSize,
        );
        writes.add(ByteWrite(offset: pn * pageSize, bytes: pageBytes));
        nextInFree = pn;
      }

      // 4. Write all free pages.
      await _dataStore.storage.writeManyAsBytesAt(path, writes, flush: false);

      // 5. Update meta.
      final newMeta = PartitionMetaPage(
        partitionNo: meta.partitionNo,
        totalEntryCount: meta.totalEntryCount,
        totalSizeBytes: meta.totalSizeBytes,
        freeListHeadPageNo:
            pageNos.first, // The first page in our reconstructed chain
        freePageCount: meta.freePageCount + pageNos.length,
      );
      await _writeMeta(
        path: path,
        pageSize: pageSize,
        partitionNo: ref.overflowPartitionNo,
        meta: newMeta,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        flush: false,
      );
    });
  }

  Future<Uint8List> getLargeValue({
    required TableContext table,
    required ValueRef ref,
    required int pageSize,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    final out = BytesBuilder(copy: false);
    int remaining = ref.totalLen;
    int pageNo = ref.startPageNo;
    int guard = 0;
    String? resolvedPath;

    while (pageNo > 0 && remaining > 0) {
      if (guard++ > 1 << 20) {
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message: 'get overflow: overflow chain too long (cycle?)',
          ),
        ]);
      }

      // 1. Check page cache first (point 3: tableUid, partitionNo, pageNo)
      OverflowPage? page = _pageCache.getPoint3(
        table.tableUid,
        ref.overflowPartitionNo,
        pageNo,
      );

      // 2. On cache miss, read from disk
      if (page == null) {
        resolvedPath ??= _overflowPath(table, ref.overflowPartitionNo);
        final pageBytes = await _dataStore.storage
            .readAsBytesAt(resolvedPath, pageNo * pageSize, length: pageSize);
        if (pageBytes.isEmpty) {
          throw DbException([
            GeneralStatus(
              type: ResultType.engError,
              message:
                  'Overflow page empty or missing at partition=${ref.overflowPartitionNo}, page=$pageNo',
            ),
          ]);
        }
        final parsed = BTreePageIO.parsePageBytes(pageBytes);
        if (parsed.type != BTreePageType.overflow) {
          throw DbException([
            GeneralStatus(
              type: ResultType.engError,
              message: 'Expected overflow page, got ${parsed.type}',
            ),
          ]);
        }
        final decodedPayload = BTreePageCodec.decodePayload(
          parsed.encodedPayload,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
          aad: _aadForOverflowPage(ref.overflowPartitionNo, pageNo),
        );
        final decodedPage = OverflowPage.tryDecodePayload(decodedPayload);
        if (decodedPage == null) {
          throw DbException([
            GeneralStatus(
              type: ResultType.engError,
              message: 'Invalid overflow payload',
            ),
          ]);
        }
        page = decodedPage;
        _pageCache.putPoint3(
          table.tableUid,
          ref.overflowPartitionNo,
          pageNo,
          page,
        );
      }

      final take = page.data.length < remaining ? page.data.length : remaining;
      if (take > 0) out.add(page.data.sublist(0, take));
      remaining -= take;
      pageNo = page.nextPageNo;
    }

    final bytes = out.toBytes();
    if (bytes.length != ref.totalLen) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Overflow length mismatch: expected=${ref.totalLen} actual=${bytes.length}',
        ),
      ]);
    }
    final crc = Crc32.of(bytes);
    if (crc != ref.crc32) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'Overflow CRC mismatch: expected=${ref.crc32} actual=$crc',
        ),
      ]);
    }
    return bytes;
  }

  /// Evict overflow page cache by ratio under memory pressure.
  Future<void> evictPageCache({double ratio = 0.3}) async {
    await _pageCache.cleanup(removeRatio: ratio);
  }

  /// Remove all cached overflow pages for a table (e.g. on truncate / drop).
  void clearTableCache(TableUid tableUid) {
    _pageCache.remove([tableUid]);
  }

  /// Reset all overflow page caches.
  void clearAllCache() {
    _pageCache.clear();
  }

  /// Estimated total bytes held in overflow page cache.
  int get estimatedCacheSizeBytes => _pageCache.estimatedTotalSizeBytes;

  // ---- Internal helpers ----

  String _overflowPath(TableContext table, int partitionNo) {
    return _dataStore.pathManager
        .getOverflowPartitionFilePathByContext(table, partitionNo);
  }

  Uint8List _aadForOverflowPage(int partitionNo, int pageNo) {
    final bd = ByteData(8);
    bd.setInt32(0, partitionNo, Endian.little);
    bd.setInt32(4, pageNo, Endian.little);
    return bd.buffer.asUint8List();
  }

  List<Uint8List> _splitIntoChunks(Uint8List bytes, int chunkSize) {
    if (bytes.isEmpty) return const <Uint8List>[];
    if (chunkSize <= 0) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'Invalid overflow chunkSize=$chunkSize',
        ),
      ]);
    }
    final out = <Uint8List>[];
    int off = 0;
    while (off < bytes.length) {
      final end =
          (off + chunkSize < bytes.length) ? (off + chunkSize) : bytes.length;
      out.add(bytes.sublist(off, end));
      off = end;
    }
    return out;
  }

  int _maxChunkLen(int pageSize, {int? encryptionKeyId}) {
    // Ensure the whole page fits after optional encryption wrapper:
    // BTreeHeader + encodeBytes(header + payload) <= pageSize.
    const int overflowPayloadHeader = 16; // magic+ver+flags+next+len
    int lo = 0;
    int hi = pageSize; // upper bound
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      final plainLen = overflowPayloadHeader + mid;
      final ok = BTreePageSizer.fitsInPage(
        pageSize: pageSize,
        plainPayloadLen: plainLen,
        config: _dataStore.config,
        encryptionKeyId: encryptionKeyId,
      );
      if (ok) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    if (lo <= 0) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'Overflow pageSize too small: pageSize=$pageSize',
        ),
      ]);
    }
    return lo;
  }

  Future<void> _ensureFileInitialized({
    required String path,
    required int pageSize,
    required int partitionNo,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool flush = true,
  }) async {
    await _dataStore.storage.ensureDirectoryExists(p.dirname(path));
    if (await _dataStore.storage.existsFile(path)) {
      // If file exists but is empty, initialize it.
      final sz = await _dataStore.storage.getFileSize(path);
      if (sz >= pageSize) return;
    }

    final meta = PartitionMetaPage(
      partitionNo: partitionNo,
      totalEntryCount: 0,
      totalSizeBytes: pageSize,
      freeListHeadPageNo: -1,
      freePageCount: 0,
    );
    final payload = meta.encodePayload();
    final encodedPayload = BTreePageCodec.encodePayload(
      payload,
      config: _dataStore.config,
      encryptionKey: encryptionKey,
      encryptionKeyId: encryptionKeyId,
      aad: _aadForOverflowPage(partitionNo, 0),
    );
    final page0 = BTreePageIO.buildPageBytes(
      type: BTreePageType.meta,
      encodedPayload: encodedPayload,
      pageSize: pageSize,
    );
    await _dataStore.storage.writeAsBytesAt(path, 0, page0, flush: flush);
  }

  Future<PartitionMetaPage> _readMeta({
    required String path,
    required int pageSize,
    required int partitionNo,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    final page0 =
        await _dataStore.storage.readAsBytesAt(path, 0, length: pageSize);
    final parsed = BTreePageIO.parsePageBytes(page0);
    if (parsed.type != BTreePageType.meta) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'Overflow meta page type mismatch: ${parsed.type}',
        ),
      ]);
    }
    final decodedPayload = BTreePageCodec.decodePayload(
      parsed.encodedPayload,
      encryptionKey: encryptionKey,
      encryptionKeyId: encryptionKeyId,
      aad: _aadForOverflowPage(partitionNo, 0),
    );
    final meta = PartitionMetaPage.tryDecodePayload(decodedPayload);
    if (meta == null) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'Overflow meta payload invalid',
        ),
      ]);
    }
    return meta;
  }

  Future<void> _writeMeta({
    required String path,
    required int pageSize,
    required int partitionNo,
    required PartitionMetaPage meta,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool flush = true,
  }) async {
    final payload = meta.encodePayload();
    final encodedPayload = BTreePageCodec.encodePayload(
      payload,
      config: _dataStore.config,
      encryptionKey: encryptionKey,
      encryptionKeyId: encryptionKeyId,
      aad: _aadForOverflowPage(partitionNo, 0),
    );
    final page0 = BTreePageIO.buildPageBytes(
      type: BTreePageType.meta,
      encodedPayload: encodedPayload,
      pageSize: pageSize,
    );
    await _dataStore.storage.writeAsBytesAt(path, 0, page0, flush: flush);
  }

  Future<({List<int> pageNos, int sizeDeltaBytes})> _allocatePageNos({
    required int count,
    required String path,
    required int pageSize,
    required int partitionNo,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool flush = true,
    PartitionMetaPage? cachedMeta,
  }) async {
    if (count <= 0) {
      return (pageNos: const <int>[], sizeDeltaBytes: 0);
    }

    // This is intentionally serialized by StorageAdapter per-path exclusive locks.
    var meta = cachedMeta ??
        await _readMeta(
          path: path,
          pageSize: pageSize,
          partitionNo: partitionNo,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
        );

    final result = <int>[];
    int currentFreeHead = meta.freeListHeadPageNo;
    int currentFreeCount = meta.freePageCount;
    final int oldFileSize = meta.totalSizeBytes;

    // 1. Pop from freelist with cycle protection and self-healing.
    final visited = <int>{};
    while (result.length < count && currentFreeHead >= 1) {
      final head = currentFreeHead;
      if (visited.contains(head)) {
        Logger.warn(
            'Overflow freelist cycle detected at page=$head, truncating freelist');
        currentFreeHead = -1;
        currentFreeCount = 0;
        break;
      }
      visited.add(head);

      final bytes = await _dataStore.storage
          .readAsBytesAt(path, head * pageSize, length: pageSize);
      if (bytes.isEmpty) {
        Logger.warn(
            'Overflow freelist points to EOF/empty at page=$head, truncating freelist');
        currentFreeHead = -1;
        currentFreeCount = 0;
        break;
      }

      try {
        final parsed = BTreePageIO.parsePageBytes(bytes);
        if (parsed.type != BTreePageType.free) {
          Logger.warn(
              'Overflow freelist corrupted at page=$head (type: ${parsed.type}), resetting freelist head');
          currentFreeHead = -1;
          currentFreeCount = 0;
          break;
        }
        final decodedPayload = BTreePageCodec.decodePayload(
          parsed.encodedPayload,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
          aad: _aadForOverflowPage(partitionNo, head),
        );
        final free = FreePage.tryDecodePayload(decodedPayload);
        if (free == null) {
          Logger.warn(
              'Overflow freelist payload decode failed at page=$head, resetting freelist head');
          currentFreeHead = -1;
          currentFreeCount = 0;
          break;
        }

        result.add(head);
        currentFreeHead = free.nextFreePageNo;
        currentFreeCount = currentFreeCount > 0 ? currentFreeCount - 1 : 0;
      } catch (e) {
        Logger.warn(
            'Error popping from freelist at page=$head, resetting freelist head',
            rawError: e);
        currentFreeHead = -1;
        currentFreeCount = 0;
        break;
      }
    }

    // 2. Allocate new pages if needed.
    int currentFileSize = oldFileSize;
    while (result.length < count) {
      final pn = currentFileSize ~/ pageSize;
      result.add(pn);
      currentFileSize += pageSize;
    }

    // 3. Update meta once.
    final updatedMeta = PartitionMetaPage(
      partitionNo: meta.partitionNo,
      totalEntryCount: meta.totalEntryCount,
      totalSizeBytes: currentFileSize,
      freeListHeadPageNo: currentFreeHead,
      freePageCount: currentFreeCount,
    );
    await _writeMeta(
      path: path,
      pageSize: pageSize,
      partitionNo: partitionNo,
      meta: updatedMeta,
      encryptionKey: encryptionKey,
      encryptionKeyId: encryptionKeyId,
      flush: flush,
    );

    return (
      pageNos: result,
      sizeDeltaBytes: currentFileSize - oldFileSize,
    );
  }

  /// Sum overflow occupancy from partition meta pages (page 0 only).
  ///
  /// Used solely by SpaceStats full reconcile to heal legacy metas that lack
  /// [TableDataMeta.overflowTotalSizeBytes]. Never call on flush / query hot
  /// paths -- those must use the incrementally maintained meta field.
  ///
  /// Does **not** use filesystem `getFileSize`.
  Future<int> sumOverflowSizeFromPartitionMetas({
    required TableContext table,
    required int overflowPartitionCount,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    final count = overflowPartitionCount < 1 ? 0 : overflowPartitionCount;
    if (count <= 0) return 0;

    final pageSize = _dataStore.configuredPageSize;
    var total = 0;
    for (var pNo = 0; pNo < count; pNo++) {
      final path = _overflowPath(table, pNo);
      try {
        final meta = await _readMeta(
          path: path,
          pageSize: pageSize,
          partitionNo: pNo,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
        );
        if (meta.totalSizeBytes > 0) total += meta.totalSizeBytes;
      } catch (_) {
        // Missing / unreadable partition -- treat as empty.
      }
    }
    return total;
  }
}

/// Helper to allocate overflow pages in bulk.
class OverflowBatchAllocator {
  final int partitionNo;
  final List<int> _pages;
  final int updatedOverflowPartitionCount;

  /// File-size growth from the upfront batch allocation (freelist reuse => 0).
  final int sizeDeltaBytes;
  int _consumed = 0;

  OverflowBatchAllocator({
    required this.partitionNo,
    required List<int> pages,
    required this.updatedOverflowPartitionCount,
    this.sizeDeltaBytes = 0,
  }) : _pages = pages;

  List<int> next(int count) {
    if (_consumed + count > _pages.length) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Batch allocator exhausted: needed $count, available ${_pages.length - _consumed}',
        ),
      ]);
    }
    final range = _pages.sublist(_consumed, _consumed + count);
    _consumed += count;
    return range;
  }
}

/// A simple async lock to serialize operations.
class SimpleLock {
  Future<void>? _last;

  Future<T> synchronized<T>(Future<T> Function() callback) async {
    final prev = _last;
    final completer = Completer<void>();
    _last = completer.future;
    if (prev != null) {
      try {
        await prev;
      } catch (_) {}
    }
    try {
      return await callback();
    } finally {
      completer.complete();
    }
  }
}
