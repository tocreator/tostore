import 'dart:async';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../handler/logger.dart';
import '../Interface/storage_interface.dart';
import '../model/value_ref.dart';
import 'btree_page.dart';
import 'data_store_impl.dart';

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
final class OverflowManager {
  final DataStoreImpl _dataStore;
  OverflowManager(this._dataStore);

  static const int _defaultPartitionNo = 0;

  // Locks to prevent concurrent metadata updates (race on free list/file size).
  final Map<String, SimpleLock> _locks = {};

  SimpleLock _getLock(String path) {
    return _locks.putIfAbsent(path, () => SimpleLock());
  }

  // Marker to help future debugging (not a public guarantee).
  static const String _label = 'OverflowManager';

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

  Future<OverflowBatchAllocator> startBatchAllocation({
    required int totalChunks,
    required String tableName,
    required int pageSize,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool flush = true,
  }) async {
    final path = await _overflowPath(tableName, _defaultPartitionNo);
    return _getLock(path).synchronized(() async {
      await _ensureFileInitialized(
        path: path,
        pageSize: pageSize,
        partitionNo: _defaultPartitionNo,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        flush: flush,
      );

      final pages = await _allocatePageNos(
        count: totalChunks,
        path: path,
        pageSize: pageSize,
        partitionNo: _defaultPartitionNo,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        flush: flush,
      );
      return OverflowBatchAllocator(pages);
    });
  }

  Future<ValueRef> putLargeValue({
    required String tableName,
    required Uint8List valueBytes,
    required int pageSize,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool flush = true,
    OverflowBatchAllocator? allocator,
  }) async {
    if (valueBytes.isEmpty) {
      throw ArgumentError.value(valueBytes.length, 'valueBytes', 'must be > 0');
    }

    final path = await _overflowPath(tableName, _defaultPartitionNo);

    final crc = Crc32.of(valueBytes);
    final maxChunk = _maxChunkLen(
      pageSize,
      encryptionKeyId: encryptionKeyId,
    );
    final chunks = _splitIntoChunks(valueBytes, maxChunk);

    // Optimized batch allocation:
    final List<int> pageNos;
    if (allocator != null) {
      pageNos = allocator.next(chunks.length);
    } else {
      pageNos = await _getLock(path).synchronized(() async {
        await _ensureFileInitialized(
          path: path,
          pageSize: pageSize,
          partitionNo: _defaultPartitionNo,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
          flush: flush,
        );
        return await _allocatePageNos(
          count: chunks.length,
          path: path,
          pageSize: pageSize,
          partitionNo: _defaultPartitionNo,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
          flush: flush,
        );
      });
    }

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
        aad: _aadForOverflowPage(_defaultPartitionNo, pn),
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

    return ValueRef.overflow(
      overflowPartitionNo: _defaultPartitionNo,
      startPageNo: pageNos.first,
      totalLen: valueBytes.length,
      crc32: crc,
    );
  }

  /// Free overflow pages back to the freelist.
  Future<void> deleteLargeValue({
    required String tableName,
    required ValueRef ref,
    required int pageSize,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    if (ref.kind != ValueRef.kindOverflow) return;

    final path = await _overflowPath(tableName, ref.overflowPartitionNo);
    if (!await _dataStore.storage.existsFile(path)) return;

    await _getLock(path).synchronized(() async {
      // 1. Follow the chain to collect all page numbers.
      final pageNos = <int>[];
      int curPageNo = ref.startPageNo;
      int guard = 0;
      while (curPageNo > 0) {
        if (guard++ > 1 << 20) break; // cycle safety
        pageNos.add(curPageNo);

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
            config: _dataStore.config,
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
        totalEntries: meta.totalEntries,
        fileSizeInBytes: meta.fileSizeInBytes,
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
    required String tableName,
    required ValueRef ref,
    required int pageSize,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    final path = await _overflowPath(tableName, ref.overflowPartitionNo);
    // Fast path: if file missing, treat as corruption.
    if (!await _dataStore.storage.existsFile(path)) {
      throw StateError('Overflow file missing: $path');
    }

    final out = BytesBuilder(copy: false);
    int remaining = ref.totalLen;
    int pageNo = ref.startPageNo;
    int guard = 0;
    while (pageNo > 0 && remaining > 0) {
      if (guard++ > 1 << 20) {
        throw StateError('Overflow chain too long (cycle?)');
      }
      final pageBytes = await _dataStore.storage
          .readAsBytesAt(path, pageNo * pageSize, length: pageSize);
      final parsed = BTreePageIO.parsePageBytes(pageBytes);
      if (parsed.type != BTreePageType.overflow) {
        throw StateError('Expected overflow page, got ${parsed.type}');
      }
      final decodedPayload = BTreePageCodec.decodePayload(
        parsed.encodedPayload,
        config: _dataStore.config,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        aad: _aadForOverflowPage(ref.overflowPartitionNo, pageNo),
      );
      final page = OverflowPage.tryDecodePayload(decodedPayload);
      if (page == null) {
        throw StateError('Invalid overflow payload');
      }
      final take = page.data.length < remaining ? page.data.length : remaining;
      if (take > 0) out.add(page.data.sublist(0, take));
      remaining -= take;
      pageNo = page.nextPageNo;
    }

    final bytes = out.toBytes();
    if (bytes.length != ref.totalLen) {
      throw StateError(
          'Overflow length mismatch: expected=${ref.totalLen} actual=${bytes.length}');
    }
    final crc = Crc32.of(bytes);
    if (crc != ref.crc32) {
      throw StateError(
          'Overflow CRC mismatch: expected=${ref.crc32} actual=$crc');
    }
    return bytes;
  }

  // ---- Internal helpers ----

  Future<String> _overflowPath(String tableName, int partitionNo) async {
    return _dataStore.pathManager
        .getOverflowPartitionFilePathByNo(tableName, partitionNo);
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
      throw StateError('Invalid overflow chunkSize=$chunkSize');
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
      throw StateError('Overflow pageSize too small: pageSize=$pageSize');
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
      totalEntries: 0,
      fileSizeInBytes: pageSize,
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
      throw StateError('Overflow meta page type mismatch: ${parsed.type}');
    }
    final decodedPayload = BTreePageCodec.decodePayload(
      parsed.encodedPayload,
      config: _dataStore.config,
      encryptionKey: encryptionKey,
      encryptionKeyId: encryptionKeyId,
      aad: _aadForOverflowPage(partitionNo, 0),
    );
    final meta = PartitionMetaPage.tryDecodePayload(decodedPayload);
    if (meta == null) {
      throw StateError('Overflow meta payload invalid');
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

  Future<List<int>> _allocatePageNos({
    required int count,
    required String path,
    required int pageSize,
    required int partitionNo,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool flush = true,
  }) async {
    if (count <= 0) return const [];

    // This is intentionally serialized by StorageAdapter per-path exclusive locks.
    var meta = await _readMeta(
      path: path,
      pageSize: pageSize,
      partitionNo: partitionNo,
      encryptionKey: encryptionKey,
      encryptionKeyId: encryptionKeyId,
    );

    final result = <int>[];
    int currentFreeHead = meta.freeListHeadPageNo;
    int currentFreeCount = meta.freePageCount;

    // 1. Pop from freelist.
    while (result.length < count && currentFreeHead >= 1) {
      final head = currentFreeHead;
      final bytes = await _dataStore.storage
          .readAsBytesAt(path, head * pageSize, length: pageSize);
      if (bytes.isEmpty) break;

      try {
        final parsed = BTreePageIO.parsePageBytes(bytes);
        if (parsed.type != BTreePageType.free) {
          Logger.warn('Overflow freelist corrupted at page=$head',
              label: _label);
          break;
        }
        final decodedPayload = BTreePageCodec.decodePayload(
          parsed.encodedPayload,
          config: _dataStore.config,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
          aad: _aadForOverflowPage(partitionNo, head),
        );
        final free = FreePage.tryDecodePayload(decodedPayload);
        if (free == null) break;

        result.add(head);
        currentFreeHead = free.nextFreePageNo;
        currentFreeCount = currentFreeCount > 0 ? currentFreeCount - 1 : 0;
      } catch (e) {
        Logger.warn('Error popping from freelist: $e', label: _label);
        break;
      }
    }

    // 2. Allocate new pages if needed.
    int currentFileSize = meta.fileSizeInBytes;
    while (result.length < count) {
      final pn = currentFileSize ~/ pageSize;
      result.add(pn);
      currentFileSize += pageSize;
    }

    // 3. Update meta once.
    final updatedMeta = PartitionMetaPage(
      partitionNo: meta.partitionNo,
      totalEntries: meta.totalEntries,
      fileSizeInBytes: currentFileSize,
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

    return result;
  }
}

/// Helper to allocate overflow pages in bulk.
class OverflowBatchAllocator {
  final List<int> _pages;
  int _consumed = 0;

  OverflowBatchAllocator(this._pages);

  List<int> next(int count) {
    if (_consumed + count > _pages.length) {
      throw StateError(
          'Batch allocator exhausted: needed $count, available ${_pages.length - _consumed}');
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
