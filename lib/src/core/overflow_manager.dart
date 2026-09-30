import 'dart:async';
import 'dart:math' show max, min;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../handler/logger.dart';
import '../interface/storage_interface.dart';
import '../model/data_store_config.dart';
import '../model/db_exception.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/table_context.dart';
import '../model/table_identity.dart';
import '../model/value_ref.dart';
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
/// - This manager is **write-order safe** for references: overflow pages are
///   committed before callers persist [ValueRef] bytes in the primary tree.
///   Batch callers stage pages in [OverflowWriteBuffer] and must [OverflowWriteBuffer.commit]
///   before flushing B+Tree leaves. On-disk page layout is unchanged.
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

  /// In-flight meta after page reservation but before durable page writes.
  /// Disk meta is only advanced in [_commitInflightMeta] so a disk-full during
  /// page IO cannot leave ghost totalSizeBytes that force partition rotation.
  final Map<String, PartitionMetaPage> _inflightMeta = {};

  /// (pageSize, encryptionKeyId) -> max overflow chunk payload length.
  final Map<(int, int?), int> _maxChunkLenCache = {};

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
        PartitionMetaPage? rollbackMeta,
      })> _allocatePages({
    required int count,
    required TableContext table,
    required int pageSize,
    required int overflowPartitionCount,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool flush = true,
    bool requireAllInOnePartition = false,
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
        rollbackMeta: null,
      );
    }

    int activePNo =
        (overflowPartitionCount - 1) < 0 ? 0 : overflowPartitionCount - 1;
    int currentCount = overflowPartitionCount < 1 ? 1 : overflowPartitionCount;
    final maxPartitionSize = _dataStore.config.maxPartitionFileSize;
    // Skip full partitions; bound the walk so a corrupt meta chain cannot loop.
    var rotations = 0;
    const maxRotations = 256;

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

        final PartitionMetaPage meta;
        final inflight = _inflightMeta[path];
        if (inflight != null) {
          // Active batch reservations are intentionally ahead of durable file
          // bytes (pages are written later). Healing would shrink meta and
          // reissue page numbers already handed to the allocator.
          meta = inflight;
        } else {
          meta = await _healMetaIfAheadOfFile(
            path: path,
            pageSize: pageSize,
            partitionNo: activePNo,
            encryptionKey: encryptionKey,
            encryptionKeyId: encryptionKeyId,
            flush: flush,
          );
        }

        final growRoom = pageSize <= 0
            ? 0
            : max(0, (maxPartitionSize - meta.totalSizeBytes) ~/ pageSize);
        final available = meta.freePageCount + growRoom;
        final bool isEmptyPartition = meta.totalSizeBytes <= pageSize;

        int take;
        if (requireAllInOnePartition) {
          if (available >= count) {
            take = count;
          } else if (isEmptyPartition) {
            // One ValueRef must stay in one file; allow soft-max overrun.
            take = count;
          } else {
            return null; // Rotate to a fresher partition
          }
        } else {
          if (available <= 0) {
            return null; // Rotate
          }
          take = min(count, available);
        }

        return await _allocatePageNos(
          count: take,
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
          rollbackMeta: allocated.rollbackMeta,
        );
      }

      if (++rotations > maxRotations) {
        throw DbException([
          GeneralStatus(
            type: ResultType.sysResourceExhausted,
            message:
                'Overflow allocation failed: cannot place $count pages after '
                'skipping $maxRotations full partitions (last=$activePNo)',
          ),
        ]);
      }

      // Rotate to next partition
      activePNo += 1;
      currentCount = activePNo + 1;
    }
  }

  /// If meta.totalSizeBytes ran ahead of durable file bytes (common after
  /// disk-full: meta updated in [_allocatePageNos] then page writes failed),
  /// shrink meta to the page-aligned file size so the next retry reuses this
  /// partition instead of rotating to a new pN.dat.
  Future<PartitionMetaPage> _healMetaIfAheadOfFile({
    required String path,
    required int pageSize,
    required int partitionNo,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool flush = true,
  }) async {
    final meta = await _readMeta(
      path: path,
      pageSize: pageSize,
      partitionNo: partitionNo,
      encryptionKey: encryptionKey,
      encryptionKeyId: encryptionKeyId,
    );
    if (pageSize <= 0) return meta;

    int fileSize = 0;
    try {
      fileSize = await _dataStore.storage.getFileSize(path);
    } catch (_) {
      return meta;
    }
    if (fileSize < pageSize) return meta;

    final durableSize = (fileSize ~/ pageSize) * pageSize;
    if (meta.totalSizeBytes <= durableSize) return meta;

    Logger.debug(
      'Overflow meta ahead of file; healing totalSizeBytes '
      '${meta.totalSizeBytes} -> $durableSize (partition=$partitionNo)',
    );
    final healed = PartitionMetaPage(
      partitionNo: meta.partitionNo,
      totalEntryCount: meta.totalEntryCount,
      totalSizeBytes: durableSize,
      freeListHeadPageNo: meta.freeListHeadPageNo,
      freePageCount: meta.freePageCount,
    );
    await _writeMeta(
      path: path,
      pageSize: pageSize,
      partitionNo: partitionNo,
      meta: healed,
      encryptionKey: encryptionKey,
      encryptionKeyId: encryptionKeyId,
      flush: flush,
    );
    return healed;
  }

  /// Drop an in-flight page reservation after a failed overflow write.
  ///
  /// Clears the process-local reservation and best-effort restores
  /// [previousMeta] on disk (covers mid-flush meta commits and freelist pops)
  /// so retries reuse the same partition instead of rotating.
  Future<void> rollbackAllocation({
    required TableContext table,
    required int partitionNo,
    required int pageSize,
    required PartitionMetaPage previousMeta,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool flush = false,
  }) async {
    final path = _overflowPath(table, partitionNo);
    await _getLock(path).synchronized(() async {
      _inflightMeta.remove(path);
      if (!await _dataStore.storage.existsFile(path)) return;
      try {
        await _writeMeta(
          path: path,
          pageSize: pageSize,
          partitionNo: partitionNo,
          meta: previousMeta,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
          flush: flush,
        );
      } catch (_) {
        // Disk may still be full; heal size if possible so rotation stops.
        try {
          await _healMetaIfAheadOfFile(
            path: path,
            pageSize: pageSize,
            partitionNo: partitionNo,
            encryptionKey: encryptionKey,
            encryptionKeyId: encryptionKeyId,
            flush: flush,
          );
        } catch (_) {}
      }
    });
  }

  Future<void> _commitInflightMeta({
    required String path,
    required int pageSize,
    required int partitionNo,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool flush = true,
  }) async {
    await _getLock(path).synchronized(() async {
      final pending = _inflightMeta[path];
      if (pending == null) return;
      await _writeMeta(
        path: path,
        pageSize: pageSize,
        partitionNo: partitionNo,
        meta: pending,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        flush: flush,
      );
      // Only drop reservation after durable meta write succeeds.
      _inflightMeta.remove(path);
    });
  }

  /// Persist a reserved overflow allocation after page bytes are durable.
  Future<void> commitAllocation({
    required TableContext table,
    required int partitionNo,
    required int pageSize,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool flush = false,
  }) async {
    await _commitInflightMeta(
      path: _overflowPath(table, partitionNo),
      pageSize: pageSize,
      partitionNo: partitionNo,
      encryptionKey: encryptionKey,
      encryptionKeyId: encryptionKeyId,
      flush: flush,
    );
  }

  /// Commit every partition reserved by [allocator].
  Future<void> commitBatchAllocation({
    required TableContext table,
    required OverflowBatchAllocator allocator,
    required int pageSize,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool flush = false,
  }) async {
    for (final seg in allocator.segments) {
      await commitAllocation(
        table: table,
        partitionNo: seg.partitionNo,
        pageSize: pageSize,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        flush: flush,
      );
    }
  }

  /// Roll back every partition reserved by [allocator].
  Future<void> rollbackBatchAllocation({
    required TableContext table,
    required OverflowBatchAllocator allocator,
    required int pageSize,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool flush = false,
  }) async {
    // One segment per partition (first rollbackMeta). Reverse is harmless and
    // keeps same-partition layering safe if that invariant ever changes.
    for (final seg in allocator.segments.reversed) {
      final prev = seg.rollbackMeta;
      if (prev == null) continue;
      try {
        await rollbackAllocation(
          table: table,
          partitionNo: seg.partitionNo,
          pageSize: pageSize,
          previousMeta: prev,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
          flush: flush,
        );
      } catch (_) {}
    }
  }

  /// Reserve overflow pages for a known list of ValueRef chain lengths.
  ///
  /// Packs **whole chains** into partitions (never splits one chain across
  /// files, never reserves unusable leftovers). Each reserved page is assigned
  /// to exactly one chain and will be written by a matching [next] / stage call.
  Future<OverflowBatchAllocator> startBatchAllocation({
    required List<int> chainPageCounts,
    required TableContext table,
    required int pageSize,
    int overflowPartitionCount = 1,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool flush = true,
  }) async {
    final filtered = <int>[
      for (final c in chainPageCounts)
        if (c > 0) c,
    ];
    if (filtered.isEmpty) {
      return OverflowBatchAllocator(
        segments: <OverflowAllocSegment>[],
        chains: const [],
        updatedOverflowPartitionCount:
            overflowPartitionCount < 1 ? 1 : overflowPartitionCount,
      );
    }

    var partitionCount =
        overflowPartitionCount < 1 ? 1 : overflowPartitionCount;
    final chains = <OverflowChainSlot>[];
    final segmentsByPartition = <int, OverflowAllocSegment>{};
    var totalSizeDelta = 0;
    var emptyRounds = 0;
    var index = 0;

    while (index < filtered.length) {
      final packed = await _allocatePackedChains(
        chainPageCounts: filtered,
        startIndex: index,
        table: table,
        pageSize: pageSize,
        overflowPartitionCount: partitionCount,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        flush: flush,
      );
      if (packed.pageNos.isEmpty || packed.packedCounts.isEmpty) {
        if (++emptyRounds > 8) {
          throw DbException([
            GeneralStatus(
              type: ResultType.sysResourceExhausted,
              message: 'Overflow batch allocation made no progress '
                  '(remainingChains=${filtered.length - index}, '
                  'partitions=$partitionCount)',
            ),
          ]);
        }
        partitionCount += 1;
        continue;
      }
      emptyRounds = 0;

      var pageOffset = 0;
      for (final len in packed.packedCounts) {
        chains.add(OverflowChainSlot(
          partitionNo: packed.partitionNo,
          pages: packed.pageNos.sublist(pageOffset, pageOffset + len),
        ));
        pageOffset += len;
      }

      final existing = segmentsByPartition[packed.partitionNo];
      if (existing == null) {
        segmentsByPartition[packed.partitionNo] = OverflowAllocSegment(
          partitionNo: packed.partitionNo,
          pages: packed.pageNos,
          rollbackMeta: packed.rollbackMeta,
          sizeDeltaBytes: packed.sizeDeltaBytes,
        );
      } else {
        // Same partition revisited after packing more chains: keep the earliest
        // rollback meta so a full batch rollback restores the pre-batch state.
        segmentsByPartition[packed.partitionNo] = OverflowAllocSegment(
          partitionNo: packed.partitionNo,
          pages: <int>[...existing.pages, ...packed.pageNos],
          rollbackMeta: existing.rollbackMeta,
          sizeDeltaBytes: existing.sizeDeltaBytes + packed.sizeDeltaBytes,
        );
      }

      totalSizeDelta += packed.sizeDeltaBytes;
      partitionCount = max(partitionCount, packed.updatedPartitionCount);
      index += packed.packedCounts.length;
    }

    return OverflowBatchAllocator(
      segments: List<OverflowAllocSegment>.unmodifiable(
        segmentsByPartition.values,
      ),
      chains: chains,
      updatedOverflowPartitionCount: partitionCount,
      sizeDeltaBytes: totalSizeDelta,
    );
  }

  /// Place as many whole chains as fit in one partition allocation.
  Future<
      ({
        int partitionNo,
        List<int> pageNos,
        List<int> packedCounts,
        int updatedPartitionCount,
        int sizeDeltaBytes,
        PartitionMetaPage? rollbackMeta,
      })> _allocatePackedChains({
    required List<int> chainPageCounts,
    required int startIndex,
    required TableContext table,
    required int pageSize,
    required int overflowPartitionCount,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool flush = true,
  }) async {
    int activePNo =
        (overflowPartitionCount - 1) < 0 ? 0 : overflowPartitionCount - 1;
    int currentCount = overflowPartitionCount < 1 ? 1 : overflowPartitionCount;
    final maxPartitionSize = _dataStore.config.maxPartitionFileSize;
    var rotations = 0;
    const maxRotations = 256;

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

        final PartitionMetaPage meta;
        final inflight = _inflightMeta[path];
        if (inflight != null) {
          meta = inflight;
        } else {
          meta = await _healMetaIfAheadOfFile(
            path: path,
            pageSize: pageSize,
            partitionNo: activePNo,
            encryptionKey: encryptionKey,
            encryptionKeyId: encryptionKeyId,
            flush: flush,
          );
        }

        final growRoom = pageSize <= 0
            ? 0
            : max(0, (maxPartitionSize - meta.totalSizeBytes) ~/ pageSize);
        final available = meta.freePageCount + growRoom;
        final bool isEmptyPartition = meta.totalSizeBytes <= pageSize;

        final packedCounts = <int>[];
        var pagesNeeded = 0;
        for (var j = startIndex; j < chainPageCounts.length; j++) {
          final c = chainPageCounts[j];
          if (c <= 0) continue;
          if (pagesNeeded + c <= available) {
            packedCounts.add(c);
            pagesNeeded += c;
            continue;
          }
          // Chain does not fit. Soft-max overrun only for an empty partition
          // file so a single huge ValueRef can still land in one file.
          if (packedCounts.isEmpty && isEmptyPartition) {
            packedCounts.add(c);
            pagesNeeded += c;
          }
          break;
        }

        if (packedCounts.isEmpty || pagesNeeded <= 0) {
          return null; // Rotate
        }

        final pageAlloc = await _allocatePageNos(
          count: pagesNeeded,
          path: path,
          pageSize: pageSize,
          partitionNo: activePNo,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
          flush: flush,
          cachedMeta: meta,
        );
        return (
          pageNos: pageAlloc.pageNos,
          packedCounts: packedCounts,
          sizeDeltaBytes: pageAlloc.sizeDeltaBytes,
          rollbackMeta: pageAlloc.rollbackMeta,
        );
      });

      if (allocated != null) {
        return (
          partitionNo: activePNo,
          pageNos: allocated.pageNos,
          packedCounts: allocated.packedCounts,
          updatedPartitionCount: currentCount,
          sizeDeltaBytes: allocated.sizeDeltaBytes,
          rollbackMeta: allocated.rollbackMeta,
        );
      }

      if (++rotations > maxRotations) {
        throw DbException([
          GeneralStatus(
            type: ResultType.sysResourceExhausted,
            message:
                'Overflow chain packing failed after skipping $maxRotations '
                'full partitions (last=$activePNo)',
          ),
        ]);
      }

      activePNo += 1;
      currentCount = activePNo + 1;
    }
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
    OverflowWriteBuffer? writeBuffer,
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
    PartitionMetaPage? localRollbackMeta;

    if (allocator != null) {
      // Pre-assigned whole-chain reservation from startBatchAllocation.
      pageNos = allocator.next(chunks.length);
      targetPartitionNo = allocator.partitionNo;
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
        requireAllInOnePartition: true,
      );
      targetPartitionNo = allocRes.partitionNo;
      pageNos = allocRes.pageNos;
      updatedPartitionCount = allocRes.updatedPartitionCount;
      sizeDeltaBytes = allocRes.sizeDeltaBytes;
      localRollbackMeta = allocRes.rollbackMeta;
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
      writes.add(ByteWrite(
        offset: pn * pageSize,
        bytes: BTreePageIO.buildPageBytes(
          type: BTreePageType.overflow,
          encodedPayload: encodedPayload,
          pageSize: pageSize,
        ),
      ));
    }

    // Overflow pages must be on disk before ValueRefs are published. Batch
    // apply stages pages and commits in sequential runs (same bytes / page
    // numbers; each commit is awaited). Meta is committed only after durable
    // page IO so disk-full cannot strand ghost totalSizeBytes.
    try {
      if (writeBuffer != null) {
        writeBuffer.addWrites(path, writes);
        if (writeBuffer.pendingBytes >= OverflowWriteBuffer.maxStagedBytes) {
          await writeBuffer.commit(_dataStore.storage, flush: false);
          // Batch reservations stay in [_inflightMeta] until
          // [commitBatchAllocation]. Committing the full reservation while
          // only a prefix of pages is on disk makes meta ahead of the file;
          // a later alloc would heal/shrink and reissue those page numbers.
          if (allocator == null) {
            await _commitInflightMeta(
              path: path,
              pageSize: pageSize,
              partitionNo: targetPartitionNo,
              encryptionKey: encryptionKey,
              encryptionKeyId: encryptionKeyId,
              flush: false,
            );
          }
        }
      } else {
        await _dataStore.storage.writeManyAsBytesAt(path, writes, flush: flush);
        if (allocator == null) {
          await _commitInflightMeta(
            path: path,
            pageSize: pageSize,
            partitionNo: targetPartitionNo,
            encryptionKey: encryptionKey,
            encryptionKeyId: encryptionKeyId,
            flush: flush,
          );
        }
      }
    } catch (e) {
      // Solo alloc: drop reservation immediately. Batch allocators are rolled
      // back by the caller after the whole staging/commit attempt fails.
      if (allocator == null && localRollbackMeta != null) {
        try {
          await rollbackAllocation(
            table: table,
            partitionNo: targetPartitionNo,
            pageSize: pageSize,
            previousMeta: localRollbackMeta,
            encryptionKey: encryptionKey,
            encryptionKeyId: encryptionKeyId,
            flush: false,
          );
        } catch (_) {}
      }
      rethrow;
    }

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

  /// Synchronous batch staging: take a pre-reserved chain and append page
  /// writes to [writeBuffer] without scheduling a microtask.
  ///
  /// Returns whether the caller should await [OverflowWriteBuffer.commit].
  /// Does **not** commit overflow meta; that stays in-flight until
  /// [commitBatchAllocation].
  ({OverflowAllocationResult result, bool bufferNeedsCommit})
      stageLargeValueWithAllocator({
    required TableContext table,
    required Uint8List valueBytes,
    required int pageSize,
    required OverflowBatchAllocator allocator,
    required OverflowWriteBuffer writeBuffer,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) {
    if (valueBytes.isEmpty) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.engError,
          message: 'stage large value: valueBytes must not be empty',
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
    final pageNos = allocator.next(chunks.length);
    final targetPartitionNo = allocator.partitionNo;
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
      writes.add(ByteWrite(
        offset: pn * pageSize,
        bytes: BTreePageIO.buildPageBytes(
          type: BTreePageType.overflow,
          encodedPayload: encodedPayload,
          pageSize: pageSize,
        ),
      ));
      _pageCache.putPoint3(table.tableUid, targetPartitionNo, pn, page);
    }

    writeBuffer.addWrites(path, writes);

    final ref = ValueRef.overflow(
      overflowPartitionNo: targetPartitionNo,
      startPageNo: pageNos.first,
      totalLen: valueBytes.length,
      crc32: crc,
    );
    return (
      result: OverflowAllocationResult(
        ref: ref,
        overflowPartitionCount: allocator.updatedOverflowPartitionCount,
        sizeDeltaBytes: 0,
      ),
      bufferNeedsCommit:
          writeBuffer.pendingBytes >= OverflowWriteBuffer.maxStagedBytes,
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
    final key = (pageSize, encryptionKeyId);
    final cached = _maxChunkLenCache[key];
    if (cached != null) return cached;
    final computed =
        _computeMaxChunkLen(pageSize, encryptionKeyId: encryptionKeyId);
    _maxChunkLenCache[key] = computed;
    return computed;
  }

  int _computeMaxChunkLen(int pageSize, {int? encryptionKeyId}) {
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

  Future<
      ({
        List<int> pageNos,
        int sizeDeltaBytes,
        PartitionMetaPage rollbackMeta,
      })> _allocatePageNos({
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
      final emptyMeta = cachedMeta ??
          await _readMeta(
            path: path,
            pageSize: pageSize,
            partitionNo: partitionNo,
            encryptionKey: encryptionKey,
            encryptionKeyId: encryptionKeyId,
          );
      return (
        pageNos: const <int>[],
        sizeDeltaBytes: 0,
        rollbackMeta: emptyMeta,
      );
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
    final rollbackMeta = meta;

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

    // 3. Reserve meta in-memory only. Durable meta is written after page IO
    // via [_commitInflightMeta]; failures call [rollbackAllocation].
    final updatedMeta = PartitionMetaPage(
      partitionNo: meta.partitionNo,
      totalEntryCount: meta.totalEntryCount,
      totalSizeBytes: currentFileSize,
      freeListHeadPageNo: currentFreeHead,
      freePageCount: currentFreeCount,
    );
    _inflightMeta[path] = updatedMeta;

    return (
      pageNos: result,
      sizeDeltaBytes: currentFileSize - oldFileSize,
      rollbackMeta: rollbackMeta,
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

/// Stages overflow page writes so a batch apply issues sequential IO instead of
/// one `writeManyAsBytesAt` per record. On-disk format is unchanged.
final class OverflowWriteBuffer {
  /// Flush staged pages once this many bytes are pending (bounds Dart heap on
  /// large vector ingest). 4MB ≈ 256 × 16KB pages ≈ 256 overflow records.
  static const int maxStagedBytes = 4 * 1024 * 1024;

  final Map<String, List<ByteWrite>> _writes = {};
  int _pendingBytes = 0;

  int get pendingBytes => _pendingBytes;

  bool get isEmpty => _pendingBytes <= 0;

  void addWrites(String path, List<ByteWrite> writes) {
    if (writes.isEmpty) return;
    final list = _writes.putIfAbsent(path, () => <ByteWrite>[]);
    for (final w in writes) {
      if (w.bytes.isEmpty) continue;
      list.add(w);
      _pendingBytes += w.bytes.length;
    }
  }

  /// Coalesce adjacent spans and write each path. On IO failure the buffer is
  /// left intact so a retry overwrites the same page offsets (idempotent).
  Future<void> commit(StorageInterface storage, {bool flush = false}) async {
    if (_writes.isEmpty) return;
    for (final entry in _writes.entries) {
      final coalesced = _coalesceAdjacent(entry.value);
      if (coalesced.isEmpty) continue;
      await storage.writeManyAsBytesAt(entry.key, coalesced, flush: flush);
    }
    _writes.clear();
    _pendingBytes = 0;
  }

  static List<ByteWrite> _coalesceAdjacent(List<ByteWrite> writes) {
    if (writes.length <= 1) return writes;
    final items = List<ByteWrite>.from(writes)
      ..sort((a, b) => a.offset.compareTo(b.offset));
    final out = <ByteWrite>[];
    var runStart = items[0].offset;
    var runParts = <Uint8List>[items[0].bytes];
    var runLen = items[0].bytes.length;
    var runEnd = runStart + runLen;

    void flushRun() {
      if (runParts.length == 1) {
        out.add(ByteWrite(offset: runStart, bytes: runParts[0]));
        return;
      }
      final buf = Uint8List(runLen);
      var o = 0;
      for (final part in runParts) {
        buf.setRange(o, o + part.length, part);
        o += part.length;
      }
      out.add(ByteWrite(offset: runStart, bytes: buf));
    }

    for (int i = 1; i < items.length; i++) {
      final w = items[i];
      final adjacent = w.offset == runEnd;
      final canMerge = adjacent && runLen + w.bytes.length <= maxStagedBytes;
      if (canMerge) {
        runParts.add(w.bytes);
        runLen += w.bytes.length;
        runEnd += w.bytes.length;
      } else {
        flushRun();
        runStart = w.offset;
        runParts = <Uint8List>[w.bytes];
        runLen = w.bytes.length;
        runEnd = runStart + runLen;
      }
    }
    flushRun();
    return out;
  }
}

/// One overflow partition slice reserved by [OverflowManager.startBatchAllocation].
final class OverflowAllocSegment {
  final int partitionNo;
  final List<int> pages;
  final PartitionMetaPage? rollbackMeta;
  final int sizeDeltaBytes;

  const OverflowAllocSegment({
    required this.partitionNo,
    required this.pages,
    this.rollbackMeta,
    this.sizeDeltaBytes = 0,
  });
}

/// Pages reserved for a single ValueRef overflow chain (one partition).
final class OverflowChainSlot {
  final int partitionNo;
  final List<int> pages;

  const OverflowChainSlot({
    required this.partitionNo,
    required this.pages,
  });
}

/// Helper to allocate overflow pages in bulk across one or more partitions.
///
/// Chains are packed whole into partitions so each [next] call receives pages
/// that already fit one ValueRef; no segment-boundary leftovers are reserved.
class OverflowBatchAllocator {
  /// One entry per touched overflow partition (for commit/rollback).
  final List<OverflowAllocSegment> segments;

  /// Pre-assigned page lists in the same order callers will stage values.
  final List<OverflowChainSlot> chains;

  final int updatedOverflowPartitionCount;

  /// File-size growth from the upfront batch allocation (freelist reuse => 0).
  final int sizeDeltaBytes;

  int _chainIndex = 0;
  int _lastPartitionNo = 0;

  OverflowBatchAllocator({
    required this.segments,
    required this.chains,
    required this.updatedOverflowPartitionCount,
    this.sizeDeltaBytes = 0,
  });

  /// Partition used by the most recent successful [next] call.
  int get partitionNo => _lastPartitionNo;

  /// First segment rollback meta (legacy single-partition callers).
  PartitionMetaPage? get rollbackMeta =>
      segments.isEmpty ? null : segments.first.rollbackMeta;

  List<int> next(int count) {
    if (count <= 0) return const <int>[];
    if (_chainIndex >= chains.length) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'Batch allocator exhausted: needed $count pages '
              '(chainsUsed=$_chainIndex/${chains.length})',
        ),
      ]);
    }
    final slot = chains[_chainIndex++];
    if (slot.pages.length != count) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'Batch allocator chain size mismatch: reserved '
              '${slot.pages.length} pages, requested $count',
        ),
      ]);
    }
    _lastPartitionNo = slot.partitionNo;
    return slot.pages;
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
