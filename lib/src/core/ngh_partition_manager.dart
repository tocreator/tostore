import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../handler/logger.dart';
import '../handler/meta_binary_codec.dart';
import '../handler/parallel_processor.dart';
import '../interface/storage_interface.dart';
import '../model/data_store_config.dart';
import '../model/ngh_index_meta.dart';
import '../model/parallel_journal_entry.dart';
import '../model/table_context.dart';
import '../model/table_identity.dart';
import 'btree_page.dart';
import 'data_store_impl.dart';
import 'ngh_page.dart';
import 'tree_cache.dart';
import 'workload_scheduler.dart';
import 'yield_controller.dart';

// ============================================================================
// NGH Partition Manager
//
// Manages page I/O, allocation, free-list, batch staged writes, and flush for
// NGH vector index partition files.
//
// Three independent file series per index:
//   graph/  -- graph pages (neighbor lists)
//   pqcode/ -- PQ code pages (quantised vectors)
//   rawvec/ -- raw vector pages (full-precision vectors)
//
// Each file series has its own partition rotation and free-list.
// ============================================================================

/// Category of NGH partition data.
enum NghDataCategory {
  posting,
}

/// Identifies a physical page location.
///
/// On-disk centroid/chain refs pack `(partitionNo, pageNo)` into a single i32
/// via [packRef] / [unpackRef] (same layout as the in-memory cache key).
/// Legacy bare pageNos decode as partition 0.
final class NghPagePtr {
  /// Low bits reserved for pageNo in packed refs / cache keys.
  static const int pageNoBits = 20;
  static const int pageNoMask = (1 << pageNoBits) - 1;

  final NghDataCategory category;
  final int partitionNo;
  final int pageNo;

  const NghPagePtr(this.category, this.partitionNo, this.pageNo);
  static const NghPagePtr nullPtr = NghPagePtr(NghDataCategory.posting, -1, -1);
  bool get isNull => partitionNo < 0 || pageNo < 0;

  /// Packed `(partitionNo << 20) | pageNo` for nav-graph / chain fields.
  /// Sentinels (`<= 0`) are returned unchanged.
  int get packedRef => packRef(partitionNo, pageNo);

  factory NghPagePtr.fromPacked(NghDataCategory category, int packed) {
    final (part, page) = unpackRef(packed);
    return NghPagePtr(category, part, page);
  }

  /// Pack partition+page into one i32. Values `<= 0` pass through as sentinels.
  static int packRef(int partitionNo, int pageNo) {
    if (pageNo <= 0) return pageNo;
    return (partitionNo << pageNoBits) | (pageNo & pageNoMask);
  }

  /// Unpack a packed ref. Sentinels (`<= 0`) yield `(-1, packed)`.
  static (int partitionNo, int pageNo) unpackRef(int packed) {
    if (packed <= 0) return (-1, packed);
    return (packed >> pageNoBits, packed & pageNoMask);
  }

  @override
  String toString() => 'NghPagePtr(${category.name}, p$partitionNo, pg$pageNo)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NghPagePtr &&
          category == other.category &&
          partitionNo == other.partitionNo &&
          pageNo == other.pageNo);

  @override
  int get hashCode => Object.hash(category.index, partitionNo, pageNo);
}

/// Mutable per-partition stats accumulated during a single writeChanges batch.
final class _NghPartitionStats {
  int entriesDelta = 0;
  int maxPageNoWritten = 0;
  int freeListHeadPageNo = -1;
  int freePageCount = 0;
  int oldTotalEntries = 0;
  int oldFileSizeInBytes = 0;
  bool headerLoaded = false;
  String? path;
  bool dirEnsured = false;
}

/// Manages page-level I/O for NGH vector index partitions.
final class NghPartitionManager {
  final DataStoreImpl _dataStore;

  // -- Page Caches --
  // Inverted posting pages with inlined SQ8 vector slots.
  late final TreeCache<NghPostingPage> _postingPageCache;

  NghPartitionManager(this._dataStore) {
    final indexBudget =
        _dataStore.resourceManager?.getIndexCacheSize() ?? (64 * 1024 * 1024);
    _initCaches(indexBudget);
  }

  int get configuredPageSize => _dataStore.configuredPageSize;

  void _initCaches(int indexBudget) {
    // Search prefers the float compact cluster cache; keep posting pages smaller.
    final nghBudget = max(1, (indexBudget * 0.35).round());
    // Never force a min floor above the actual budget (avoids OOM on small devices).
    final int minThreshold = max(1, min(nghBudget ~/ 2, 16 * 1024 * 1024));
    _postingPageCache = TreeCache<NghPostingPage>(
      sizeCalculator: (page) => page.estimatePayloadSize() + 32,
      maxByteThreshold: nghBudget,
      minByteThreshold: minThreshold,
      groupDepth: 2,
      debugLabel: 'NghPostingPageCache',
    );
  }

  /// Delete all physical files and directories belonging to a vector index.
  Future<void> deletePhysicalIndexArtifacts(
    TableContext table,
    IndexUid indexUid,
  ) async {
    _postingPageCache.remove([table.tableUid, indexUid]);

    final basePath =
        _dataStore.pathManager.getIndexPathByContext(table, indexUid);
    if (await _dataStore.storage.existsDirectory(basePath)) {
      await _dataStore.storage.deleteDirectory(basePath);
    }
  }

  /// Clear all in-memory caches and reset state.
  Future<void> dispose() async {
    _postingPageCache.clear();
  }

  /// Synchronous memory cache lookup for an inverted posting page (0 I/O).
  NghPostingPage? getCachedPostingPage(
    TableUid tableUid,
    IndexUid indexUid,
    int partitionNo,
    int pageNo,
  ) {
    return _postingPageCache.getPoint4(tableUid, indexUid, partitionNo, pageNo);
  }

  /// Read an inverted posting page from cache or disk.
  Future<NghPostingPage?> readPostingPage(
    TableContext table,
    IndexUid indexUid,
    NghIndexMeta meta,
    int partitionNo,
    int pageNo, {
    Map<int, NghPostingPage>? localCache,
  }) async {
    final tableUid = table.tableUid;
    final cacheKey = _cacheKey(partitionNo, pageNo);

    if (localCache != null) {
      final cached = localCache[cacheKey];
      if (cached != null) return cached;
    }

    final cached =
        _postingPageCache.getPoint4(tableUid, indexUid, partitionNo, pageNo);
    if (cached != null) return cached;

    final path = _dataStore.pathManager
        .getNghPostingPartitionPathByContext(table, indexUid, partitionNo);
    try {
      final raw = await _dataStore.storage.readAsBytesAt(
          path, pageNo * _dataStore.configuredPageSize,
          length: _dataStore.configuredPageSize);
      if (raw.isEmpty) return null;

      final parsed = BTreePageIO.parsePageBytes(raw);
      final page = NghPostingPage.tryDecodePayload(
          _decodePayload(parsed.encodedPayload));
      if (page == null) return null;

      _postingPageCache.putPoint4(
          tableUid, indexUid, partitionNo, pageNo, page);
      return page;
    } catch (e) {
      Logger.warn(
        'NGH posting page corrupted or torn at partition $partitionNo, page $pageNo for index "$indexUid". Gracefully degrading to null.',
        rawError: e,
      );
      return null;
    }
  }

  /// Read specific posting pages by packed refs, grouped by partition for parallel I/O.
  ///
  /// Each entry in [packedRefs] is `partitionNo<<20|pageNo` (legacy bare pageNo = p0).
  Future<List<({int packedRef, NghPostingPage page})>> readPostingPagesBatch(
    TableContext table,
    IndexUid indexUid,
    NghIndexMeta meta,
    List<int> packedRefs, {
    Map<int, NghPostingPage>? localCache,
    bool populatePageCache = true,
  }) async {
    if (packedRefs.isEmpty) return const [];
    final results = <({int packedRef, NghPostingPage page})>[];
    // partitionNo -> packed refs still needing disk I/O
    final missingByPartition = <int, List<int>>{};

    for (final packed in packedRefs) {
      if (packed <= 0) continue;
      final (part, pageNo) = NghPagePtr.unpackRef(packed);
      if (pageNo <= 0) continue;

      final local = localCache?[packed];
      if (local != null) {
        results.add((packedRef: packed, page: local));
        continue;
      }
      final cached =
          _postingPageCache.getPoint4(table.tableUid, indexUid, part, pageNo);
      if (cached != null) {
        results.add((packedRef: packed, page: cached));
        continue;
      }
      missingByPartition.putIfAbsent(part, () => <int>[]).add(packed);
    }

    if (missingByPartition.isEmpty) return results;

    final pageSize = _dataStore.configuredPageSize;
    final tableUid = table.tableUid;

    Future<List<({int packedRef, NghPostingPage page})>> readOnePartition(
      int part,
      List<int> missingPacked,
    ) async {
      final partResults = <({int packedRef, NghPostingPage page})>[];
      final path = _dataStore.pathManager
          .getNghPostingPartitionPathByContext(table, indexUid, part);
      final ranges = <ByteReadRange>[
        for (final packed in missingPacked)
          ByteReadRange(
            offset: NghPagePtr.unpackRef(packed).$2 * pageSize,
            length: pageSize,
          ),
      ];

      final rawBlocks =
          await _dataStore.storage.readManyAsBytesAt(path, ranges);

      for (int i = 0; i < missingPacked.length; i++) {
        final packed = missingPacked[i];
        final pageNo = NghPagePtr.unpackRef(packed).$2;
        final raw = (i < rawBlocks.length) ? rawBlocks[i] : Uint8List(0);
        if (raw.isEmpty) continue;
        try {
          final parsed = BTreePageIO.parsePageBytes(raw);
          final page = NghPostingPage.tryDecodePayload(
              _decodePayload(parsed.encodedPayload));
          if (page != null) {
            if (populatePageCache) {
              _postingPageCache.putPoint4(
                  tableUid, indexUid, part, pageNo, page);
            }
            localCache?[packed] = page;
            partResults.add((packedRef: packed, page: page));
          }
        } catch (_) {}
      }
      return partResults;
    }

    final partitions = missingByPartition.entries.toList(growable: false);
    if (partitions.length == 1) {
      results.addAll(await readOnePartition(
        partitions.first.key,
        partitions.first.value,
      ));
    } else {
      final tasks = [
        for (final entry in partitions)
          () => readOnePartition(entry.key, entry.value),
      ];
      final partLists = await ParallelProcessor.execute<
          List<({int packedRef, NghPostingPage page})>>(
        tasks,
        concurrency: min(5, tasks.length),
        label: 'readPostingPagesBatch',
      );
      for (final partList in partLists) {
        if (partList != null) results.addAll(partList);
      }
    }
    return results;
  }

  /// Read the entire posting cluster chain starting at [headPackedRef].
  Future<List<({int packedRef, NghPostingPage page})>> readPostingCluster(
    TableContext table,
    IndexUid indexUid,
    NghIndexMeta meta,
    int headPackedRef, {
    Map<int, NghPostingPage>? localCache,
  }) async {
    if (headPackedRef <= 0) return const [];
    final pages = <({int packedRef, NghPostingPage page})>[];
    int current = headPackedRef;
    final visited = <int>{};

    while (current > 0 && !visited.contains(current)) {
      visited.add(current);
      final (part, pageNo) = NghPagePtr.unpackRef(current);
      if (pageNo <= 0) break;
      final pg = await readPostingPage(
        table,
        indexUid,
        meta,
        part,
        pageNo,
        localCache: localCache,
      );
      if (pg == null) break;
      pages.add((packedRef: current, page: pg));
      current = pg.nextPostingPageNo;
    }
    return pages;
  }

  /// Batch read multiple posting clusters in parallel or sequentially.
  Future<List<List<({int packedRef, NghPostingPage page})>>>
      readPostingClustersBatch(
    TableContext table,
    IndexUid indexUid,
    NghIndexMeta meta,
    List<int> headPackedRefs, {
    Map<int, NghPostingPage>? localCache,
    int concurrency = 4,
  }) async {
    if (headPackedRefs.isEmpty) return const [];
    final tasks = [
      for (final headRef in headPackedRefs)
        () => readPostingCluster(table, indexUid, meta, headRef,
            localCache: localCache),
    ];
    final res = await ParallelProcessor.execute<
        List<({int packedRef, NghPostingPage page})>>(
      tasks,
      concurrency: min(concurrency, tasks.length),
      label: 'readPostingClustersBatch',
    );
    return res
        .whereType<List<({int packedRef, NghPostingPage page})>>()
        .toList();
  }

  /// Read the navigating centroid graph from disk.
  Future<NghNavGraphPage?> readNavGraph(
    TableContext table,
    IndexUid indexUid,
  ) async {
    final path =
        _dataStore.pathManager.getNghNavGraphPathByContext(table, indexUid);
    final bytes = await _dataStore.storage.readAsBytes(path);
    if (bytes.isEmpty) return null;

    if (bytes.length >= 20 && bytes[0] == 0x54 && bytes[1] == 0x53) {
      try {
        final parsed = BTreePageIO.parsePageBytes(bytes);
        return NghNavGraphPage.tryDecodePayload(
            _decodePayload(parsed.encodedPayload));
      } catch (_) {}
    }
    return NghNavGraphPage.tryDecodePayload(bytes);
  }

  // =====================================================================
  // Lazy full-cache preload for vector search (TreeCache isFullyCached)
  // =====================================================================

  /// Prefix key for TreeCache group [table.tableUid, indexUid] (groupDepth 2).
  List<dynamic> _indexPrefix(TableUid tableUid, IndexUid indexUid) =>
      [tableUid, indexUid];

  /// Clear fully-cached markers for an index after write.
  void clearFullyCachedForIndex(TableUid tableUid, IndexUid indexUid) {
    final prefix = _indexPrefix(tableUid, indexUid);
    _postingPageCache.setFullyCached(prefix, false);
  }

  // =====================================================================
  // Batch Write Changes -- Core Flush Pipeline
  // =====================================================================

  /// Apply a batch of vector deltas to the NGH index.
  ///
  /// This method is called by [VectorIndexManager] during the flush pipeline.
  /// All pages are first staged into an in-memory map, then flushed once at the
  /// end to minimise I/O syscalls and avoid write amplification.
  Future<NghIndexMeta> writeChanges({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    Map<NghPagePtr, NghPostingPage> dirtyPostingPages = const {},
    NghNavGraphPage? navGraphPage,
    int vectorsDelta = 0,
    int deletedDelta = 0,
    BatchContext? batchContext,
    int? concurrency,
    int? yieldBudgetMs,
  }) async {
    final tableUid = table.tableUid;
    if (dirtyPostingPages.isEmpty && navGraphPage == null) {
      return meta;
    }

    final pageSize = _dataStore.configuredPageSize;
    final yc = YieldController(
      'NghPartitionManager.writeChanges',
      checkInterval: 40,
      budgetMs: yieldBudgetMs,
    );

    // Staged writes: path -> (offset -> bytes)
    final staged = <String, Map<int, Uint8List>>{};

    void stageWrite(String path, int offset, Uint8List bytes) {
      staged.putIfAbsent(path, () => <int, Uint8List>{})[offset] = bytes;
    }

    // Per-partition stats for meta page updates
    final postingStats = <int, _NghPartitionStats>{};

    _NghPartitionStats getStats(Map<int, _NghPartitionStats> map, int pNo) {
      return map.putIfAbsent(pNo, () => _NghPartitionStats());
    }

    // Vector pages encrypt under EncryptionScope.full (or legacy encryptVectorIndex).
    final encCfg = _dataStore.config.encryptionConfig;
    final bool encrypt = encCfg?.shouldEncryptVectorIndex ?? false;

    // -- Encode & stage posting pages --
    for (final entry in dirtyPostingPages.entries) {
      final y0 = yc.maybeYield();
      if (y0 != null) await y0;
      final ptr = entry.key;
      final page = entry.value;
      final payload = page.encodePayload();
      final pageBytes =
          _buildPageBytes(BTreePageType.nghPosting, payload, pageSize, encrypt);
      final stats = getStats(postingStats, ptr.partitionNo);
      stats.path ??= _dataStore.pathManager.getNghPostingPartitionPathByContext(
          table, indexUid, ptr.partitionNo);
      if (!stats.dirEnsured) {
        await _dataStore.storage.ensureDirectoryExists(p.dirname(stats.path!));
        stats.dirEnsured = true;
      }
      stageWrite(stats.path!, ptr.pageNo * pageSize, pageBytes);
      stats.maxPageNoWritten = max(stats.maxPageNoWritten, ptr.pageNo);

      _postingPageCache.putPoint4(
          tableUid, indexUid, ptr.partitionNo, ptr.pageNo, page);
    }

    // -- Encode & stage nav graph file --
    if (navGraphPage != null) {
      final navPath =
          _dataStore.pathManager.getNghNavGraphPathByContext(table, indexUid);
      await _dataStore.storage.ensureDirectoryExists(p.dirname(navPath));
      final navPayload = navGraphPage.encodePayload();
      stageWrite(navPath, 0, navPayload);
    }

    final sizeDeltaSum = await _computePartitionSizeDeltaSum(
      [postingStats],
      pageSize,
    );
    final now = DateTime.now();
    final updatedMeta = meta.copyWith(
      totalVectors: max(0, meta.totalVectors + vectorsDelta),
      deletedCount: max(0, meta.deletedCount + deletedDelta),
      totalSizeBytes: max(0, meta.totalSizeBytes + sizeDeltaSum),
      timestamps: meta.timestamps.copyWith(modified: now),
    );
    _dataStore.tableDataManager.applyIndexOccupancyDelta(
      table,
      sizeDelta: sizeDeltaSum,
      entryDelta: vectorsDelta,
    );

    // -- Stage per-partition meta pages (pageNo=0) --
    await _stagePartitionMeta(postingStats, pageSize, updatedMeta, stageWrite,
        yc, NghDataCategory.posting);

    // Posting partition 0 carrying NghIndexMeta
    if (!postingStats.containsKey(0) && staged.isNotEmpty) {
      final p0Stats = getStats(postingStats, 0);
      p0Stats.path ??= _dataStore.pathManager
          .getNghPostingPartitionPathByContext(table, indexUid, 0);
      await _stagePartitionMeta(
        {0: p0Stats},
        pageSize,
        updatedMeta,
        stageWrite,
        yc,
        NghDataCategory.posting,
      );
    }

    // -- Flush all staged writes --
    if (staged.isNotEmpty) {
      final flushYc = YieldController(
        'NghPartitionManager.writeChanges.flush',
        checkInterval: 20,
      );

      final tasks = <Future<void> Function()>[];
      for (final e in staged.entries) {
        final y4 = flushYc.maybeYield();
        if (y4 != null) await y4;
        final path = e.key;
        final offsets = e.value.keys.toList(growable: false)..sort();
        final writes = <ByteWrite>[
          for (final off in offsets)
            ByteWrite(offset: off, bytes: e.value[off]!),
        ];
        tasks.add(() async {
          await _dataStore.storage
              .writeManyAsBytesAt(path, writes, flush: false);
        });
      }

      if (tasks.length <= 1) {
        for (final t in tasks) {
          await t();
        }
      } else {
        final scheduler = _dataStore.workloadScheduler;
        final workloadType = (batchContext?.batchType == BatchType.maintenance)
            ? WorkloadType.maintenance
            : WorkloadType.flush;
        final int requested = (concurrency != null && concurrency > 0)
            ? min(concurrency, tasks.length)
            : min(scheduler.capacityTokens(workloadType), tasks.length);

        WorkloadLease? lease;
        try {
          lease = await scheduler.acquire(
            workloadType,
            requestedTokens: requested,
            minTokens: 1,
            label:
                'NghPartitionManager.writeChanges(${table.tableName}.$indexUid)',
          );
          await ParallelProcessor.execute<void>(
            tasks,
            concurrency: min(tasks.length, max(1, lease.tokens)),
            label: 'NghPartitionManager.writeChanges.flush',
            continueOnError: false,
          );
        } finally {
          lease?.release();
        }
      }
    }

    return updatedMeta;
  }

  // =====================================================================
  // Page Allocation & Free-List
  // =====================================================================

  /// Synchronously allocate [count] pages with partition rotation (0 I/O, 0 await).
  ///
  /// Mirrors B+Tree / [allocatePage]: when the active file would exceed
  /// [DataStoreConfig.maxPartitionFileSize], opens a new partition and resets
  /// page numbering to [NghIndexMeta.firstDataPageNo]. A single batch may
  /// rotate more than once.
  (List<NghPagePtr>, NghIndexMeta) allocatePagesBatchSync(
    NghDataCategory category,
    NghIndexMeta meta,
    int count,
  ) {
    if (count <= 0) return (const [], meta);

    final maxFileSize = _dataStore.config.maxPartitionFileSize;
    final pageSize = _dataStore.configuredPageSize;
    final pages = <NghPagePtr>[];
    var current = meta;

    if (current.postingPartitionCount < 1) {
      current = current.copyWith(
        postingPartitionCount: 1,
        postingNextPageNo: NghIndexMeta.firstDataPageNo,
      );
    }

    for (int i = 0; i < count; i++) {
      var activePartition = current.postingPartitionCount - 1;
      var nextPg = current.postingNextPageNo;
      if (NghPageSizer.estimateFileSizeBytes(pageSize, nextPg) > maxFileSize) {
        final newPartitionCount = current.postingPartitionCount + 1;
        current = current.copyWith(
          postingPartitionCount: newPartitionCount,
          postingNextPageNo: NghIndexMeta.firstDataPageNo + 1,
        );
        pages.add(NghPagePtr(
          category,
          newPartitionCount - 1,
          NghIndexMeta.firstDataPageNo,
        ));
        continue;
      }
      pages.add(NghPagePtr(category, activePartition, nextPg));
      current = current.copyWith(postingNextPageNo: nextPg + 1);
    }
    return (pages, current);
  }

  /// Allocate a new page in the specified category.
  Future<(NghPagePtr, NghIndexMeta)> allocatePage(
    NghDataCategory category,
    NghIndexMeta meta,
    TableContext table,
    IndexUid indexUid,
  ) async {
    // 1) Try free-list pop
    final (reused, metaAfterPop) =
        await _popFreePage(category, meta, table, indexUid);
    if (reused != null) {
      return (reused, metaAfterPop);
    }

    // 2) Append allocation with partition rotation (shared with batch path)
    final (pages, updated) = allocatePagesBatchSync(category, metaAfterPop, 1);
    return (pages.first, updated);
  }

  /// Push a released page onto the free-list for its category and partition.
  Future<NghIndexMeta> pushFreePage(
    NghDataCategory category,
    NghIndexMeta meta,
    NghPagePtr ptr,
    TableContext table,
    IndexUid indexUid,
    void Function(String path, int offset, Uint8List bytes) stageWrite,
  ) async {
    final pageSize = _dataStore.configuredPageSize;
    final heads = _getFreeListHeads(category, meta);
    final currentHead = heads[ptr.partitionNo] ?? -1;

    final freePayload = FreePage(nextFreePageNo: currentHead).encodePayload();
    final freeBytes = BTreePageIO.buildPageBytes(
      type: BTreePageType.free,
      encodedPayload: freePayload,
      pageSize: pageSize,
    );

    final path = _partitionPath(category, table, indexUid, ptr.partitionNo);
    stageWrite(path, ptr.pageNo * pageSize, freeBytes);

    final updatedHeads = Map<int, int>.from(heads);
    updatedHeads[ptr.partitionNo] = ptr.pageNo;

    return _setFreeListHeads(category, meta, updatedHeads);
  }

  /// Pop a free page from the category's free-list. Returns null if empty.
  Future<(NghPagePtr?, NghIndexMeta)> _popFreePage(
    NghDataCategory category,
    NghIndexMeta meta,
    TableContext table,
    IndexUid indexUid,
  ) async {
    final heads = _getFreeListHeads(category, meta);
    final yc = YieldController(
      'NghPartitionManager._popFreePage',
      checkInterval: 5,
      budgetMs: 10,
    );
    for (final entry in heads.entries) {
      final y5 = yc.maybeYield();
      if (y5 != null) await y5;
      final partitionNo = entry.key;
      final headPageNo = entry.value;
      if (headPageNo < NghIndexMeta.firstDataPageNo) continue;

      final path = _partitionPath(category, table, indexUid, partitionNo);
      final pageSize = _dataStore.configuredPageSize;

      try {
        final raw = await _dataStore.storage
            .readAsBytesAt(path, headPageNo * pageSize, length: pageSize);
        if (raw.isEmpty) {
          final updatedHeads = Map<int, int>.from(heads)..[partitionNo] = -1;
          meta = _setFreeListHeads(category, meta, updatedHeads);
          continue;
        }

        final parsed = BTreePageIO.parsePageBytes(raw);
        if (parsed.type != BTreePageType.free) {
          final updatedHeads = Map<int, int>.from(heads)..[partitionNo] = -1;
          meta = _setFreeListHeads(category, meta, updatedHeads);
          continue;
        }

        final fp = FreePage.tryDecodePayload(parsed.encodedPayload);
        if (fp == null || fp.nextFreePageNo == headPageNo) {
          final updatedHeads = Map<int, int>.from(heads)..[partitionNo] = -1;
          meta = _setFreeListHeads(category, meta, updatedHeads);
          continue;
        }

        final updatedHeads = Map<int, int>.from(heads)
          ..[partitionNo] = fp.nextFreePageNo;
        final updatedMeta = _setFreeListHeads(category, meta, updatedHeads);
        return (NghPagePtr(category, partitionNo, headPageNo), updatedMeta);
      } catch (_) {
        final updatedHeads = Map<int, int>.from(heads)..[partitionNo] = -1;
        meta = _setFreeListHeads(category, meta, updatedHeads);
        continue;
      }
    }
    return (null, meta);
  }

  /// Get the free-list heads map for a given category.
  Map<int, int> _getFreeListHeads(NghDataCategory category, NghIndexMeta meta) {
    return Map<int, int>.from(meta.postingFreeListHeads);
  }

  /// Return a new meta with updated free-list heads for the given category.
  NghIndexMeta _setFreeListHeads(
      NghDataCategory category, NghIndexMeta meta, Map<int, int> heads) {
    return meta.copyWith(postingFreeListHeads: heads);
  }

  /// Resolve the partition file path for a given category and partition number.
  String _partitionPath(NghDataCategory category, TableContext table,
      IndexUid indexUid, int partitionNo) {
    return _dataStore.pathManager
        .getNghPostingPartitionPathByContext(table, indexUid, partitionNo);
  }

  // =====================================================================
  // Cache Management
  // =====================================================================

  /// Current total size of all NGH page caches.
  int getCurrentPageCacheSize() {
    return _postingPageCache.estimatedTotalSizeBytes;
  }

  /// Evict a portion of all NGH page caches.
  Future<void> evictPageCache({double ratio = 0.3}) async {
    await _postingPageCache.cleanup(removeRatio: ratio);
  }

  /// Clear all NGH page caches synchronously.
  void clearPageCacheSync() {
    _postingPageCache.clear();
  }

  /// Clear caches for a specific table.
  void clearPageCacheForTable(TableUid tableUid) {
    _postingPageCache.remove([tableUid]);
  }

  /// Clear caches for a specific index.
  void clearPageCacheForIndex(TableUid tableUid, IndexUid indexUid) {
    _postingPageCache.remove([tableUid, indexUid]);
  }

  // =====================================================================
  // Private Helpers
  // =====================================================================

  int _cacheKey(int partitionNo, int pageNo) =>
      NghPagePtr.packRef(partitionNo, pageNo);

  /// Build raw page bytes (header + payload + padding).
  ///
  /// When [encrypt] is true, routes payload through [BTreePageCodec.encodePayload]
  /// which respects [EncryptionConfig.encryptionType] (ChaCha20/AES-GCM/XOR/none).
  /// When false, uses raw payload directly for maximum throughput.
  Uint8List _buildPageBytes(
    BTreePageType type,
    Uint8List payload,
    int pageSize,
    bool encrypt,
  ) {
    final Uint8List encodedPayload;
    if (encrypt) {
      encodedPayload = BTreePageCodec.encodePayload(
        payload,
        config: _dataStore.config,
      );
    } else {
      encodedPayload = payload;
    }
    return BTreePageIO.buildPageBytes(
      type: type,
      encodedPayload: encodedPayload,
      pageSize: pageSize,
    );
  }

  /// Decode page payload, applying decryption if vector encryption is enabled.
  Uint8List _decodePayload(Uint8List encodedPayload) {
    return BTreePageCodec.decodePayload(
      encodedPayload,
    );
  }

  /// Best-effort size delta across touched NGH partition files (O(touched)).
  Future<int> _computePartitionSizeDeltaSum(
    List<Map<int, _NghPartitionStats>> statsMaps,
    int pageSize,
  ) async {
    var sum = 0;
    for (final statsMap in statsMaps) {
      for (final entry in statsMap.entries) {
        final stats = entry.value;
        if (stats.path == null) continue;
        await _ensureNghPartitionHeaderLoaded(
          stats,
          partitionNo: entry.key,
          pageSize: pageSize,
        );
        final computedSize = (stats.maxPageNoWritten + 1) * pageSize;
        final newSize = max(stats.oldFileSizeInBytes, computedSize);
        sum += newSize - stats.oldFileSizeInBytes;
      }
    }
    return sum;
  }

  Future<void> _ensureNghPartitionHeaderLoaded(
    _NghPartitionStats stats, {
    required int partitionNo,
    required int pageSize,
  }) async {
    if (stats.headerLoaded || stats.path == null) return;
    try {
      final raw0 = await _dataStore.storage
          .readAsBytesAt(stats.path!, 0, length: pageSize);
      if (raw0.isNotEmpty) {
        final local =
            _dataStore.treeMetaPageService.parsePartitionLocalFromPageBytes(
          raw0,
          partitionNo: partitionNo,
          pageType: BTreePageType.nghMeta,
        );
        if (local != null) {
          stats.oldTotalEntries = local.totalEntryCount;
          stats.oldFileSizeInBytes = local.totalSizeBytes;
          stats.freeListHeadPageNo = local.freeListHeadPageNo;
          stats.freePageCount = local.freePageCount;
        }
      }
    } catch (_) {
      try {
        stats.oldFileSizeInBytes =
            await _dataStore.storage.getFileSize(stats.path!);
      } catch (_) {}
    } finally {
      stats.headerLoaded = true;
    }
  }

  /// Stage per-file meta pages (pageNo=0) for each touched partition.
  Future<void> _stagePartitionMeta(
    Map<int, _NghPartitionStats> statsMap,
    int pageSize,
    NghIndexMeta meta,
    void Function(String path, int offset, Uint8List bytes) stageWrite,
    YieldController yc,
    NghDataCategory category,
  ) async {
    for (final entry in statsMap.entries) {
      final y6 = yc.maybeYield();
      if (y6 != null) await y6;
      final pNo = entry.key;
      final stats = entry.value;

      if (stats.path == null) continue;

      await _ensureNghPartitionHeaderLoaded(
        stats,
        partitionNo: pNo,
        pageSize: pageSize,
      );

      final newEntries = max(0, stats.oldTotalEntries + stats.entriesDelta);
      final computedSize = (stats.maxPageNoWritten + 1) * pageSize;
      final newSize = max(stats.oldFileSizeInBytes, computedSize);

      // NghIndexMeta lives only on posting partition 0 (same as table/index p0).
      Uint8List? treeGlobalMeta;
      if (category == NghDataCategory.posting && pNo == 0) {
        treeGlobalMeta = TreeGlobalMetaBlobCodec.encode(
          TreeGlobalMetaKind.ngh,
          NghIndexMetaCodec.encode(meta),
        );
      }

      final metaBytes = _dataStore.treeMetaPageService.buildPartitionPage0Bytes(
        pageSize: pageSize,
        partitionNo: pNo,
        pageType: BTreePageType.nghMeta,
        partitionLocal: PartitionLocalStats(
          partitionNo: pNo,
          dataCategory: category.index,
          totalEntryCount: newEntries,
          totalSizeBytes: newSize,
          freeListHeadPageNo: stats.freeListHeadPageNo,
          freePageCount: stats.freePageCount,
        ),
        treeGlobalMeta: treeGlobalMeta,
      );
      stageWrite(stats.path!, 0, metaBytes);
    }
  }
}
