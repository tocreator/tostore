import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../Interface/storage_interface.dart';
import '../handler/meta_binary_codec.dart';
import '../handler/parallel_processor.dart';
import '../model/data_store_config.dart';
import '../model/db_exception.dart';
import '../model/ngh_index_meta.dart';
import '../model/parallel_journal_entry.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/table_context.dart';
import 'btree_page.dart';
import 'data_store_impl.dart';
import 'ngh_page.dart';
import 'tree_cache.dart';
import 'workload_scheduler.dart';
import 'yield_controller.dart';
import '../model/table_identity.dart';

// ============================================================================
// NGH Partition Manager
//
// Manages page I/O, allocation, free-list, batch staged writes, and flush for
// NGH vector index partition files.
//
// Three independent file series per index:
//   graph/  — graph pages (neighbor lists)
//   pqcode/ — PQ code pages (quantised vectors)
//   rawvec/ — raw vector pages (full-precision vectors)
//
// Each file series has its own partition rotation and free-list.
// ============================================================================

/// Category of NGH partition data.
enum NghDataCategory {
  graph, // 0
  pqCode, // 1
  rawVector, // 2
}

/// Identifies a physical page location.
final class NghPagePtr {
  final NghDataCategory category;
  final int partitionNo;
  final int pageNo;

  const NghPagePtr(this.category, this.partitionNo, this.pageNo);
  static const NghPagePtr nullPtr = NghPagePtr(NghDataCategory.graph, -1, -1);
  bool get isNull => partitionNo < 0 || pageNo < 0;

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

  // ── Page Caches ──
  // Graph pages are accessed randomly during beam search → LRU cache critical.
  late final TreeCache<NghGraphPage> _graphPageCache;

  // PQ code pages are scanned sequentially; caching still helps for warm queries.
  late final TreeCache<NghPqCodePage> _pqCodePageCache;

  // Raw vector pages are loaded on demand for re-ranking; moderate cache.
  late final TreeCache<NghRawVectorPage> _rawVectorPageCache;

  /// In-flight preload future per index; concurrent queries await the same future.
  final Map<String, Future<void>> _preloadFutures = {};

  NghPartitionManager(this._dataStore) {
    final indexBudget =
        _dataStore.resourceManager?.getIndexCacheSize() ?? (64 * 1024 * 1024);
    _initCaches(indexBudget);
  }

  int get configuredPageSize => _dataStore.configuredPageSize;

  void _initCaches(int indexBudget) {
    final nghBudget = (indexBudget * 0.15).round();
    final int minThreshold = 50 * 1024 * 1024;
    _graphPageCache = TreeCache<NghGraphPage>(
      sizeCalculator: (page) => page.estimatePayloadSize() + 64,
      maxByteThreshold: nghBudget,
      minByteThreshold: minThreshold,
      groupDepth: 2,
      debugLabel: 'NghGraphPageCache',
    );
    _pqCodePageCache = TreeCache<NghPqCodePage>(
      sizeCalculator: (page) => page.estimatePayloadSize() + 32,
      maxByteThreshold: nghBudget,
      minByteThreshold: minThreshold,
      groupDepth: 2,
      debugLabel: 'NghPqCodePageCache',
    );
    _rawVectorPageCache = TreeCache<NghRawVectorPage>(
      sizeCalculator: (page) => page.estimatePayloadSize() + 32,
      maxByteThreshold: nghBudget,
      minByteThreshold: minThreshold,
      groupDepth: 2,
      debugLabel: 'NghRawVectorPageCache',
    );
  }

  // =====================================================================
  // Page Reading (with cache hierarchy: local → instance → disk)
  // =====================================================================

  /// Read a graph page from cache or disk.
  Future<NghGraphPage> readGraphPage(
    TableContext table,
    IndexUid indexUid,
    NghIndexMeta meta,
    int partitionNo,
    int pageNo, {
    Map<int, NghGraphPage>? localCache,
  }) async {
    final tableUid = table.tableUid;
    final cacheKey = _cacheKey(partitionNo, pageNo);

    // 1. Local batch cache
    if (localCache != null) {
      final cached = localCache[cacheKey];
      if (cached != null) return cached;
    }

    // 2. Instance cache
    final instanceKey = [tableUid, indexUid, partitionNo, pageNo];
    final cached = _graphPageCache.get(instanceKey);
    if (cached != null) return cached;

    // When index is marked fully cached, do not fall back to disk
    if (_graphPageCache.isFullyCached(_indexPrefix(tableUid, indexUid))) {
      return NghGraphPage.empty(
          maxDegree: meta.maxDegree,
          slotCount: meta.nodesPerGraphPage(_dataStore.configuredPageSize));
    }

    // 3. Disk read
    final path = await _dataStore.pathManager
        .getNghGraphPartitionPath(tableUid, indexUid, partitionNo);
    final raw = await _dataStore.storage.readAsBytesAt(
        path, pageNo * _dataStore.configuredPageSize,
        length: _dataStore.configuredPageSize);
    if (raw.isEmpty) {
      // Return empty page
      return NghGraphPage.empty(
          maxDegree: meta.maxDegree,
          slotCount: meta.nodesPerGraphPage(_dataStore.configuredPageSize));
    }
    final parsed = BTreePageIO.parsePageBytes(raw);
    final page =
        NghGraphPage.tryDecodePayload(_decodePayload(parsed.encodedPayload));
    if (page == null) {
      return NghGraphPage.empty(
          maxDegree: meta.maxDegree,
          slotCount: meta.nodesPerGraphPage(_dataStore.configuredPageSize));
    }
    _graphPageCache.put(instanceKey, page);
    return page;
  }

  /// Clear all in-memory caches and reset state.
  Future<void> dispose() async {
    if (_preloadFutures.isNotEmpty) {
      try {
        await Future.wait(_preloadFutures.values);
      } catch (_) {}
    }
    _graphPageCache.clear();
    _pqCodePageCache.clear();
    _rawVectorPageCache.clear();
    _preloadFutures.clear();
  }

  /// Read a PQ-code page from cache or disk.
  Future<NghPqCodePage> readPqCodePage(
    TableContext table,
    IndexUid indexUid,
    NghIndexMeta meta,
    int partitionNo,
    int pageNo, {
    Map<int, NghPqCodePage>? localCache,
  }) async {
    final tableUid = table.tableUid;
    final cacheKey = _cacheKey(partitionNo, pageNo);

    if (localCache != null) {
      final cached = localCache[cacheKey];
      if (cached != null) return cached;
    }

    final instanceKey = [tableUid, indexUid, partitionNo, pageNo];
    final cached = _pqCodePageCache.get(instanceKey);
    if (cached != null) return cached;

    if (_pqCodePageCache.isFullyCached(_indexPrefix(tableUid, indexUid))) {
      return NghPqCodePage.empty(
          pqSubspaces: meta.pqSubspaces,
          capacity: meta.vectorsPerPqPage(_dataStore.configuredPageSize));
    }

    final path = await _dataStore.pathManager
        .getNghPqCodePartitionPath(tableUid, indexUid, partitionNo);
    final raw = await _dataStore.storage.readAsBytesAt(
        path, pageNo * _dataStore.configuredPageSize,
        length: _dataStore.configuredPageSize);
    if (raw.isEmpty) {
      return NghPqCodePage.empty(
          pqSubspaces: meta.pqSubspaces,
          capacity: meta.vectorsPerPqPage(_dataStore.configuredPageSize));
    }
    final parsed = BTreePageIO.parsePageBytes(raw);
    final page =
        NghPqCodePage.tryDecodePayload(_decodePayload(parsed.encodedPayload));
    if (page == null) {
      return NghPqCodePage.empty(
          pqSubspaces: meta.pqSubspaces,
          capacity: meta.vectorsPerPqPage(_dataStore.configuredPageSize));
    }
    _pqCodePageCache.put(instanceKey, page);
    return page;
  }

  /// Read a raw-vector page from cache or disk.
  Future<NghRawVectorPage> readRawVectorPage(
    TableContext table,
    IndexUid indexUid,
    NghIndexMeta meta,
    int partitionNo,
    int pageNo, {
    Map<int, NghRawVectorPage>? localCache,
  }) async {
    final tableUid = table.tableUid;
    final cacheKey = _cacheKey(partitionNo, pageNo);

    if (localCache != null) {
      final cached = localCache[cacheKey];
      if (cached != null) return cached;
    }

    final instanceKey = [tableUid, indexUid, partitionNo, pageNo];
    final cached = _rawVectorPageCache.get(instanceKey);
    if (cached != null) return cached;

    if (_rawVectorPageCache.isFullyCached(_indexPrefix(tableUid, indexUid))) {
      return NghRawVectorPage.empty(
          dimensions: meta.dimensions,
          precisionIndex: meta.precision.index,
          capacity: meta.vectorsPerRawPage(_dataStore.configuredPageSize));
    }

    final path = await _dataStore.pathManager
        .getNghRawVectorPartitionPath(tableUid, indexUid, partitionNo);
    final raw = await _dataStore.storage.readAsBytesAt(
        path, pageNo * _dataStore.configuredPageSize,
        length: _dataStore.configuredPageSize);
    if (raw.isEmpty) {
      return NghRawVectorPage.empty(
          dimensions: meta.dimensions,
          precisionIndex: meta.precision.index,
          capacity: meta.vectorsPerRawPage(_dataStore.configuredPageSize));
    }
    final parsed = BTreePageIO.parsePageBytes(raw);
    final page = NghRawVectorPage.tryDecodePayload(
        _decodePayload(parsed.encodedPayload));
    if (page == null) {
      return NghRawVectorPage.empty(
          dimensions: meta.dimensions,
          precisionIndex: meta.precision.index,
          capacity: meta.vectorsPerRawPage(_dataStore.configuredPageSize));
    }
    _rawVectorPageCache.put(instanceKey, page);
    return page;
  }

  // =====================================================================
  // Lazy full-cache preload for vector search (TreeCache isFullyCached)
  // =====================================================================

  /// Prefix key for TreeCache group [table.tableUid, indexUid] (groupDepth 2).
  List<dynamic> _indexPrefix(TableUid tableUid, IndexUid indexUid) =>
      [tableUid, indexUid];

  /// Whether this index is already marked fully cached (skip preload).
  bool isFullyCachedForIndex(TableUid tableUid, IndexUid indexUid) {
    final prefix = _indexPrefix(tableUid, indexUid);
    return _graphPageCache.isFullyCached(prefix);
  }

  /// Lazy preload: fire-and-forget. Loads graph + PQ pages in background using
  /// [WorkloadType.maintenance] and [ParallelProcessor]. Schedules work in a
  /// microtask so the caller is not blocked by any computation.
  Future<void> preloadForVectorSearch(
    TableContext table,
    IndexUid indexUid,
    NghIndexMeta meta,
  ) {
    final tableUid = table.tableUid;
    return Future.microtask(() {
      final prefix = _indexPrefix(tableUid, indexUid);
      if (_graphPageCache.isFullyCached(prefix)) return;
      if (meta.totalVectors <= 0) return;
      final indexBudget =
          _dataStore.resourceManager?.getIndexCacheSize() ?? (64 * 1024 * 1024);
      final nghBudget = (indexBudget * 0.15).round();
      // Use single-cache budget so preloaded data fits in each of graph/pq
      // caches and is not evicted by cleanup (each cache has max nghBudget).
      if (meta.totalSizeInBytes <= 0 || meta.totalSizeInBytes > nghBudget) {
        return;
      }

      final key = '$tableUid/$indexUid';
      if (_preloadFutures.containsKey(key)) return;

      final future = _doPreloadForVectorSearch(table, indexUid, meta)
          .whenComplete(() => _preloadFutures.remove(key));
      _preloadFutures[key] = future;
    });
  }

  Future<void> _doPreloadForVectorSearch(
    TableContext table,
    IndexUid indexUid,
    NghIndexMeta meta,
  ) async {
    final tableUid = table.tableUid;
    WorkloadLease? lease;
    try {
      lease = await _dataStore.workloadScheduler.acquire(
        WorkloadType.maintenance,
        requestedTokens: _dataStore.workloadScheduler
            .capacityTokens(WorkloadType.maintenance),
        minTokens: 1,
        label: 'NghPartitionManager.preload',
      );
    } catch (_) {
      lease = null;
    }

    final concurrency = lease?.asConcurrency(0.3).clamp(1, 16) ?? 4;
    const firstData = NghIndexMeta.firstDataPageNo;
    final n = meta.totalVectors;
    final graphPages =
        (n + meta.nodesPerGraphPage(_dataStore.configuredPageSize) - 1) ~/
            meta.nodesPerGraphPage(_dataStore.configuredPageSize);
    final pqPages =
        (n + meta.vectorsPerPqPage(_dataStore.configuredPageSize) - 1) ~/
            meta.vectorsPerPqPage(_dataStore.configuredPageSize);

    final graphTasks = <Future<void> Function()>[];
    for (int logicalPage = 0; logicalPage < graphPages; logicalPage++) {
      final partitionNo = logicalPage ~/
          meta.graphPagesPerPartition(_dataStore.configuredPageSize);
      final pageNo = firstData +
          (logicalPage %
              meta.graphPagesPerPartition(_dataStore.configuredPageSize));
      graphTasks.add(() async {
        await readGraphPage(table, indexUid, meta, partitionNo, pageNo);
      });
    }
    final pqTasks = <Future<void> Function()>[];
    for (int logicalPage = 0; logicalPage < pqPages; logicalPage++) {
      final partitionNo = logicalPage ~/
          meta.pqCodePagesPerPartition(_dataStore.configuredPageSize);
      final pageNo = firstData +
          (logicalPage %
              meta.pqCodePagesPerPartition(_dataStore.configuredPageSize));
      pqTasks.add(() async {
        await readPqCodePage(table, indexUid, meta, partitionNo, pageNo);
      });
    }

    await ParallelProcessor.execute<void>(
      [...graphTasks, ...pqTasks],
      concurrency: concurrency,
      label: 'ngh_preload',
    );

    final prefix = _indexPrefix(tableUid, indexUid);
    _graphPageCache.setFullyCached(prefix, true);
    _pqCodePageCache.setFullyCached(prefix, true);
    lease?.release();
  }

  /// Clear fully-cached markers for an index after write (next search may preload again).
  void clearFullyCachedForIndex(TableUid tableUid, IndexUid indexUid) {
    final prefix = _indexPrefix(tableUid, indexUid);
    _graphPageCache.setFullyCached(prefix, false);
    _pqCodePageCache.setFullyCached(prefix, false);
    _rawVectorPageCache.setFullyCached(prefix, false);
  }

  // =====================================================================
  // Batch Write Changes — Core Flush Pipeline
  // =====================================================================

  /// Apply a batch of vector deltas to the NGH index.
  ///
  /// This method is called by [VectorIndexManager] during the flush pipeline.
  /// All pages are first staged into an in-memory map, then flushed once at the
  /// end to minimise I/O syscalls and avoid write amplification.
  ///
  /// [dirtyGraphPages]     — graph pages modified by the graph engine.
  /// [dirtyPqCodePages]    — PQ-code pages modified during encoding.
  /// [dirtyRawVectorPages] — raw-vector pages modified during insertion.
  /// [meta]                — current NGH index metadata (may be mutated for partition rotation).
  Future<NghIndexMeta> writeChanges({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required Map<NghPagePtr, NghGraphPage> dirtyGraphPages,
    required Map<NghPagePtr, NghPqCodePage> dirtyPqCodePages,
    required Map<NghPagePtr, NghRawVectorPage> dirtyRawVectorPages,
    int vectorsDelta = 0,
    int deletedDelta = 0,
    BatchContext? batchContext,
    int? concurrency,
    int? yieldBudgetMs,
  }) async {
    final tableUid = table.tableUid;
    if (dirtyGraphPages.isEmpty &&
        dirtyPqCodePages.isEmpty &&
        dirtyRawVectorPages.isEmpty) {
      return meta;
    }

    final pageSize = _dataStore.configuredPageSize;
    final yc = YieldController(
      'NghPartitionManager.writeChanges',
      checkInterval: 40,
      budgetMs: yieldBudgetMs,
    );

    // Staged writes: path → (offset → bytes)
    final staged = <String, Map<int, Uint8List>>{};

    void stageWrite(String path, int offset, Uint8List bytes) {
      staged.putIfAbsent(path, () => <int, Uint8List>{})[offset] = bytes;
    }

    // Per-partition stats for meta page updates
    final graphStats = <int, _NghPartitionStats>{};
    final pqStats = <int, _NghPartitionStats>{};
    final rawStats = <int, _NghPartitionStats>{};

    _NghPartitionStats getStats(Map<int, _NghPartitionStats> map, int pNo) {
      return map.putIfAbsent(pNo, () => _NghPartitionStats());
    }

    // Determine whether to use encryption:
    // encryptVectorIndex must be true AND encryptionType must not be none.
    final encCfg = _dataStore.config.encryptionConfig;
    final bool encrypt = encCfg != null &&
        encCfg.encryptVectorIndex &&
        encCfg.encryptionType != EncryptionType.none;

    // ── Encode & stage graph pages ──
    for (final entry in dirtyGraphPages.entries) {
      await yc.maybeYield();
      final ptr = entry.key;
      final page = entry.value;
      final payload = page.encodePayload();
      final pageBytes =
          _buildPageBytes(BTreePageType.nghGraph, payload, pageSize, encrypt);
      final stats = getStats(graphStats, ptr.partitionNo);
      stats.path ??= await _dataStore.pathManager
          .getNghGraphPartitionPath(tableUid, indexUid, ptr.partitionNo);
      if (!stats.dirEnsured) {
        await _dataStore.storage.ensureDirectoryExists(p.dirname(stats.path!));
        stats.dirEnsured = true;
      }
      stageWrite(stats.path!, ptr.pageNo * pageSize, pageBytes);
      stats.maxPageNoWritten = max(stats.maxPageNoWritten, ptr.pageNo);

      // Update instance cache
      _graphPageCache
          .put([tableUid, indexUid, ptr.partitionNo, ptr.pageNo], page);
    }

    // ── Encode & stage PQ-code pages ──
    for (final entry in dirtyPqCodePages.entries) {
      await yc.maybeYield();
      final ptr = entry.key;
      final page = entry.value;
      final payload = page.encodePayload();
      final pageBytes =
          _buildPageBytes(BTreePageType.nghPqCode, payload, pageSize, encrypt);
      final stats = getStats(pqStats, ptr.partitionNo);
      stats.path ??= await _dataStore.pathManager
          .getNghPqCodePartitionPath(tableUid, indexUid, ptr.partitionNo);
      if (!stats.dirEnsured) {
        await _dataStore.storage.ensureDirectoryExists(p.dirname(stats.path!));
        stats.dirEnsured = true;
      }
      stageWrite(stats.path!, ptr.pageNo * pageSize, pageBytes);
      stats.maxPageNoWritten = max(stats.maxPageNoWritten, ptr.pageNo);

      _pqCodePageCache
          .put([tableUid, indexUid, ptr.partitionNo, ptr.pageNo], page);
    }

    // ── Encode & stage raw-vector pages ──
    for (final entry in dirtyRawVectorPages.entries) {
      await yc.maybeYield();
      final ptr = entry.key;
      final page = entry.value;
      final payload = page.encodePayload();
      final pageBytes = _buildPageBytes(
          BTreePageType.nghRawVector, payload, pageSize, encrypt);
      final stats = getStats(rawStats, ptr.partitionNo);
      stats.path ??= await _dataStore.pathManager
          .getNghRawVectorPartitionPath(tableUid, indexUid, ptr.partitionNo);
      if (!stats.dirEnsured) {
        await _dataStore.storage.ensureDirectoryExists(p.dirname(stats.path!));
        stats.dirEnsured = true;
      }
      stageWrite(stats.path!, ptr.pageNo * pageSize, pageBytes);
      stats.maxPageNoWritten = max(stats.maxPageNoWritten, ptr.pageNo);

      _rawVectorPageCache
          .put([tableUid, indexUid, ptr.partitionNo, ptr.pageNo], page);
    }

    // Apply meta deltas before staging page0 so graph partition 0 embeds the
    // same NghIndexMeta that callers will cache (no wipe-before-persist window).
    final now = DateTime.now();
    final updatedMeta = meta.copyWith(
      totalVectors: max(0, meta.totalVectors + vectorsDelta),
      deletedCount: max(0, meta.deletedCount + deletedDelta),
      timestamps: meta.timestamps.copyWith(modified: now),
    );

    // ── Stage per-partition meta pages (pageNo=0) ──
    await _stagePartitionMeta(graphStats, pageSize, updatedMeta, stageWrite, yc,
        NghDataCategory.graph);
    await _stagePartitionMeta(
        pqStats, pageSize, updatedMeta, stageWrite, yc, NghDataCategory.pqCode);
    await _stagePartitionMeta(rawStats, pageSize, updatedMeta, stageWrite, yc,
        NghDataCategory.rawVector);

    // Graph partition 0 always carries NghIndexMeta (same as table/index p0).
    // Ensure it is refreshed even when this batch only touched other files.
    if (!graphStats.containsKey(0) && staged.isNotEmpty) {
      final p0Stats = getStats(graphStats, 0);
      p0Stats.path ??= await _dataStore.pathManager
          .getNghGraphPartitionPath(tableUid, indexUid, 0);
      await _stagePartitionMeta(
        {0: p0Stats},
        pageSize,
        updatedMeta,
        stageWrite,
        yc,
        NghDataCategory.graph,
      );
    }

    // ── Flush all staged writes ──
    if (staged.isNotEmpty) {
      final flushYc = YieldController(
        'NghPartitionManager.writeChanges.flush',
        checkInterval: 20,
      );

      final tasks = <Future<void> Function()>[];
      for (final e in staged.entries) {
        await flushYc.maybeYield();
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

  /// Allocate a new page in the specified category.
  ///
  /// Priority: 1) pop from free-list (O(1) reuse), 2) append at end,
  /// 3) rotate to new partition if file size exceeded.
  ///
  /// Returns the [NghPagePtr] and the (possibly rotated) [NghIndexMeta].
  Future<(NghPagePtr, NghIndexMeta)> allocatePage(
    NghDataCategory category,
    NghIndexMeta meta,
    TableContext table,
    IndexUid indexUid,
  ) async {
    // 1) Try free-list pop
    final reused = await _popFreePage(category, meta, table, indexUid);
    if (reused != null) {
      return (reused, meta);
    }

    // 2) Append allocation with partition rotation
    final maxFileSize = _dataStore.config.maxPartitionFileSize;
    final pageSize = _dataStore.configuredPageSize;

    switch (category) {
      case NghDataCategory.graph:
        final activePartition = meta.graphPartitionCount - 1;
        final nextPg = meta.graphNextPageNo;
        if (NghPageSizer.estimateFileSizeBytes(pageSize, nextPg) >
            maxFileSize) {
          // Rotate: create new partition
          final newPartitionCount = meta.graphPartitionCount + 1;
          meta = meta.copyWith(
            graphPartitionCount: newPartitionCount,
            graphNextPageNo: NghIndexMeta.firstDataPageNo + 1,
          );
          return (
            NghPagePtr(
                category, newPartitionCount - 1, NghIndexMeta.firstDataPageNo),
            meta,
          );
        }
        meta = meta.copyWith(graphNextPageNo: nextPg + 1);
        return (NghPagePtr(category, activePartition, nextPg), meta);

      case NghDataCategory.pqCode:
        final activePartition = meta.pqCodePartitionCount - 1;
        final nextPg = meta.pqCodeNextPageNo;
        if (NghPageSizer.estimateFileSizeBytes(pageSize, nextPg) >
            maxFileSize) {
          final newPartitionCount = meta.pqCodePartitionCount + 1;
          meta = meta.copyWith(
            pqCodePartitionCount: newPartitionCount,
            pqCodeNextPageNo: NghIndexMeta.firstDataPageNo + 1,
          );
          return (
            NghPagePtr(
                category, newPartitionCount - 1, NghIndexMeta.firstDataPageNo),
            meta,
          );
        }
        meta = meta.copyWith(pqCodeNextPageNo: nextPg + 1);
        return (NghPagePtr(category, activePartition, nextPg), meta);

      case NghDataCategory.rawVector:
        final activePartition = meta.rawVectorPartitionCount - 1;
        final nextPg = meta.rawVectorNextPageNo;
        if (NghPageSizer.estimateFileSizeBytes(pageSize, nextPg) >
            maxFileSize) {
          final newPartitionCount = meta.rawVectorPartitionCount + 1;
          meta = meta.copyWith(
            rawVectorPartitionCount: newPartitionCount,
            rawVectorNextPageNo: NghIndexMeta.firstDataPageNo + 1,
          );
          return (
            NghPagePtr(
                category, newPartitionCount - 1, NghIndexMeta.firstDataPageNo),
            meta,
          );
        }
        meta = meta.copyWith(rawVectorNextPageNo: nextPg + 1);
        return (NghPagePtr(category, activePartition, nextPg), meta);
    }
  }

  /// Push a released page onto the free-list for its category and partition.
  ///
  /// Writes a [FreePage] in-band at the released page's location, linked
  /// to the previous free-list head. O(1) push, no scanning.
  Future<NghIndexMeta> pushFreePage(
    NghDataCategory category,
    NghPagePtr ptr,
    NghIndexMeta meta,
    TableContext table,
    IndexUid indexUid,
    void Function(String path, int offset, Uint8List bytes) stageWrite,
  ) async {
    final pageSize = _dataStore.configuredPageSize;
    final heads = _getFreeListHeads(category, meta);
    final currentHead = heads[ptr.partitionNo] ?? -1;

    // Write FreePage at the released slot, pointing to current head
    final freePayload = FreePage(nextFreePageNo: currentHead).encodePayload();
    final freeBytes = BTreePageIO.buildPageBytes(
      type: BTreePageType.free,
      encodedPayload: freePayload,
      pageSize: pageSize,
    );

    final path =
        await _partitionPath(category, table, indexUid, ptr.partitionNo);
    stageWrite(path, ptr.pageNo * pageSize, freeBytes);

    // Update head pointer
    final updatedHeads = Map<int, int>.from(heads);
    updatedHeads[ptr.partitionNo] = ptr.pageNo;

    return _setFreeListHeads(category, meta, updatedHeads);
  }

  /// Pop a free page from the category's free-list. Returns null if empty.
  Future<NghPagePtr?> _popFreePage(
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
    // Find any partition with a free page
    for (final entry in heads.entries) {
      await yc.maybeYield();
      final partitionNo = entry.key;
      final headPageNo = entry.value;
      if (headPageNo < NghIndexMeta.firstDataPageNo) continue;

      final path = await _partitionPath(category, table, indexUid, partitionNo);
      final pageSize = _dataStore.configuredPageSize;

      try {
        final raw = await _dataStore.storage
            .readAsBytesAt(path, headPageNo * pageSize, length: pageSize);
        if (raw.isEmpty) continue;

        final parsed = BTreePageIO.parsePageBytes(raw);
        if (parsed.type != BTreePageType.free) continue;

        final fp = FreePage.tryDecodePayload(parsed.encodedPayload);
        if (fp == null) continue;

        // Cycle safety: self-referencing head → reset
        if (fp.nextFreePageNo == headPageNo) {
          heads[partitionNo] = -1;
          continue;
        }

        // Pop: advance head to next
        heads[partitionNo] = fp.nextFreePageNo;
        return NghPagePtr(category, partitionNo, headPageNo);
      } catch (_) {
        // Corruption tolerance: reset this partition's free-list
        heads[partitionNo] = -1;
        continue;
      }
    }
    return null;
  }

  /// Get the free-list heads map for a given category.
  Map<int, int> _getFreeListHeads(NghDataCategory category, NghIndexMeta meta) {
    switch (category) {
      case NghDataCategory.graph:
        return Map<int, int>.from(meta.graphFreeListHeads);
      case NghDataCategory.pqCode:
        return Map<int, int>.from(meta.pqCodeFreeListHeads);
      case NghDataCategory.rawVector:
        return Map<int, int>.from(meta.rawVectorFreeListHeads);
    }
  }

  /// Return a new meta with updated free-list heads for the given category.
  NghIndexMeta _setFreeListHeads(
      NghDataCategory category, NghIndexMeta meta, Map<int, int> heads) {
    switch (category) {
      case NghDataCategory.graph:
        return meta.copyWith(graphFreeListHeads: heads);
      case NghDataCategory.pqCode:
        return meta.copyWith(pqCodeFreeListHeads: heads);
      case NghDataCategory.rawVector:
        return meta.copyWith(rawVectorFreeListHeads: heads);
    }
  }

  /// Resolve the partition file path for a given category and partition number.
  Future<String> _partitionPath(NghDataCategory category, TableContext table,
      IndexUid indexUid, int partitionNo) async {
    final tableUid = table.tableUid;
    switch (category) {
      case NghDataCategory.graph:
        return _dataStore.pathManager
            .getNghGraphPartitionPath(tableUid, indexUid, partitionNo);
      case NghDataCategory.pqCode:
        return _dataStore.pathManager
            .getNghPqCodePartitionPath(tableUid, indexUid, partitionNo);
      case NghDataCategory.rawVector:
        return _dataStore.pathManager
            .getNghRawVectorPartitionPath(tableUid, indexUid, partitionNo);
    }
  }

  // =====================================================================
  // Codebook I/O
  // =====================================================================

  /// Write a PQ codebook to the dedicated codebook file.
  Future<void> writeCodebook(
    TableContext table,
    IndexUid indexUid,
    NghCodebookPage codebook,
    int pageSize,
  ) async {
    final tableUid = table.tableUid;
    final encCfg = _dataStore.config.encryptionConfig;
    final bool encrypt = encCfg != null &&
        encCfg.encryptVectorIndex &&
        encCfg.encryptionType != EncryptionType.none;
    final path =
        await _dataStore.pathManager.getNghCodebookPath(tableUid, indexUid);
    await _dataStore.storage.ensureDirectoryExists(p.dirname(path));

    // Check if codebook fits in a single page
    final payloadSize = codebook.estimatePayloadSize();
    if (NghPageSizer.fitsInPage(payloadSize, pageSize)) {
      // Single page: write directly
      final payload = codebook.encodePayload();
      final pageBytes = _buildPageBytes(
          BTreePageType.nghCodebook, payload, pageSize, encrypt);
      await _dataStore.storage.writeManyAsBytesAt(
        path,
        [ByteWrite(offset: 0, bytes: pageBytes)],
        flush: false,
      );
      return;
    }

    // Multi-page: split codebook across multiple pages
    final subspacesPerPage = NghPageSizer.subspacesPerCodebookPage(
      pageSize,
      codebook.centroidsPerSubspace,
      codebook.subspaceDimensions,
    );
    if (subspacesPerPage <= 0) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Codebook sub-space size (${codebook.centroidsPerSubspace} × ${codebook.subspaceDimensions} × 4 bytes) exceeds page capacity',
        ),
      ]);
    }

    final totalSubspaces = codebook.subspaceCount;
    final writes = <ByteWrite>[];

    int remainingSubspaces = totalSubspaces;
    int pageIdx = 0;
    int globalSubspaceOffset = 0;

    final centroidsPerSubspace = codebook.centroidsPerSubspace;
    final subspaceDimensions = codebook.subspaceDimensions;
    final floatsPerSubspace = centroidsPerSubspace * subspaceDimensions;
    final srcBaseOffset = codebook.subspaceStart * floatsPerSubspace;

    while (remainingSubspaces > 0) {
      // Start with estimated subspaces per page
      int countSubspaces = min(subspacesPerPage, remainingSubspaces);

      // Try to fit as many subspaces as possible, reducing if needed
      NghCodebookPage? pageCodebook;
      Uint8List? payload;

      while (countSubspaces > 0) {
        final testFloats = countSubspaces * floatsPerSubspace;
        final testCentroids = Float32List(testFloats);
        final srcOffset =
            srcBaseOffset + globalSubspaceOffset * floatsPerSubspace;
        testCentroids.setRange(0, testFloats, codebook.centroids, srcOffset);

        pageCodebook = NghCodebookPage(
          subspaceStart: codebook.subspaceStart + globalSubspaceOffset,
          subspaceCount: countSubspaces,
          centroidsPerSubspace: centroidsPerSubspace,
          subspaceDimensions: subspaceDimensions,
          centroids: testCentroids,
        );

        // Use actual encoded payload size for verification
        payload = pageCodebook.encodePayload();
        final actualPayloadSize = payload.length;

        if (NghPageSizer.fitsInPage(actualPayloadSize, pageSize)) {
          break; // This size fits
        }

        countSubspaces--;
      }

      if (countSubspaces <= 0 || pageCodebook == null || payload == null) {
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message:
                'Codebook sub-space size ($centroidsPerSubspace × $subspaceDimensions × 4 bytes) exceeds page capacity',
          ),
        ]);
      }

      final pageBytes = _buildPageBytes(
          BTreePageType.nghCodebook, payload, pageSize, encrypt);
      writes.add(ByteWrite(offset: pageIdx * pageSize, bytes: pageBytes));

      globalSubspaceOffset += countSubspaces;
      remainingSubspaces -= countSubspaces;
      pageIdx++;
    }

    await _dataStore.storage.writeManyAsBytesAt(path, writes, flush: false);
  }

  /// Read the PQ codebook from disk.
  /// Supports both single-page and multi-page codebooks.
  Future<NghCodebookPage?> readCodebook(
    TableContext table,
    IndexUid indexUid,
    int pageSize,
  ) async {
    final tableUid = table.tableUid;
    final path =
        await _dataStore.pathManager.getNghCodebookPath(tableUid, indexUid);
    try {
      // Read first page to determine structure
      final firstPageRaw =
          await _dataStore.storage.readAsBytesAt(path, 0, length: pageSize);
      if (firstPageRaw.isEmpty) return null;

      final firstParsed = BTreePageIO.parsePageBytes(firstPageRaw);
      final firstPage = NghCodebookPage.tryDecodePayload(
          _decodePayload(firstParsed.encodedPayload));
      if (firstPage == null) return null;

      // Determine if this is a multi-page codebook
      final subspacesPerPage = NghPageSizer.subspacesPerCodebookPage(
        pageSize,
        firstPage.centroidsPerSubspace,
        firstPage.subspaceDimensions,
      );

      // If subspacesPerPage is 0, even a single sub-space doesn't fit
      if (subspacesPerPage <= 0) {
        // Fallback: return first page (may be incomplete, but better than nothing)
        return firstPage;
      }

      // Check if this is a single-page codebook
      // Single-page if: subspaceCount < subspacesPerPage (meaning no more pages)
      // or it is exactly subspacesPerPage but happens to fit perfectly as the only page?
      // Actually, if it is exactly subspacesPerPage, we MUST check if there's a next page
      // to avoid returning a truncated codebook.
      final firstPayloadSize = firstPage.estimatePayloadSize();
      if (firstPage.subspaceCount < subspacesPerPage &&
          NghPageSizer.fitsInPage(firstPayloadSize, pageSize)) {
        return firstPage;
      }

      // Estimate total pages needed (read until we get a page with fewer subspaces)
      final pages = <NghCodebookPage>[firstPage];
      int totalSubspaces = firstPage.subspaceCount;
      int pageIdx = 1;

      while (true) {
        try {
          final pageRaw = await _dataStore.storage
              .readAsBytesAt(path, pageIdx * pageSize, length: pageSize);
          if (pageRaw.isEmpty) break;

          final parsed = BTreePageIO.parsePageBytes(pageRaw);
          final page = NghCodebookPage.tryDecodePayload(
              _decodePayload(parsed.encodedPayload));
          if (page == null) break;

          pages.add(page);
          totalSubspaces += page.subspaceCount;

          // Last page if it has fewer subspaces than capacity
          if (page.subspaceCount < subspacesPerPage) break;
          pageIdx++;
        } catch (_) {
          break;
        }
      }

      // Merge all pages into a single codebook
      final centroidsPerSubspace = firstPage.centroidsPerSubspace;
      final subspaceDimensions = firstPage.subspaceDimensions;
      final floatsPerSubspace = centroidsPerSubspace * subspaceDimensions;
      final totalFloats = totalSubspaces * floatsPerSubspace;
      final mergedCentroids = Float32List(totalFloats);

      int destOffset = 0;
      for (final page in pages) {
        final count = page.subspaceCount * floatsPerSubspace;
        mergedCentroids.setRange(
            destOffset, destOffset + count, page.centroids);
        destOffset += count;
      }

      return NghCodebookPage(
        subspaceStart: firstPage.subspaceStart,
        subspaceCount: totalSubspaces,
        centroidsPerSubspace: centroidsPerSubspace,
        subspaceDimensions: subspaceDimensions,
        centroids: mergedCentroids,
      );
    } catch (_) {
      return null;
    }
  }

  // =====================================================================
  // Cache Management
  // =====================================================================

  /// Current total size of all NGH page caches.
  int getCurrentPageCacheSize() {
    return _graphPageCache.estimatedTotalSizeBytes +
        _pqCodePageCache.estimatedTotalSizeBytes +
        _rawVectorPageCache.estimatedTotalSizeBytes;
  }

  /// Evict a portion of all NGH page caches.
  Future<void> evictPageCache({double ratio = 0.3}) async {
    await _graphPageCache.cleanup(removeRatio: ratio);
    await _pqCodePageCache.cleanup(removeRatio: ratio);
    await _rawVectorPageCache.cleanup(removeRatio: ratio);
  }

  /// Clear all NGH page caches synchronously.
  void clearPageCacheSync() {
    _graphPageCache.clear();
    _pqCodePageCache.clear();
    _rawVectorPageCache.clear();
  }

  /// Clear caches for a specific table.
  void clearPageCacheForTable(TableUid tableUid) {
    _graphPageCache.remove([tableUid]);
    _pqCodePageCache.remove([tableUid]);
    _rawVectorPageCache.remove([tableUid]);
  }

  /// Clear caches for a specific index.
  void clearPageCacheForIndex(TableUid tableUid, IndexUid indexUid) {
    _graphPageCache.remove([tableUid, indexUid]);
    _pqCodePageCache.remove([tableUid, indexUid]);
    _rawVectorPageCache.remove([tableUid, indexUid]);
  }

  // =====================================================================
  // Private Helpers
  // =====================================================================

  int _cacheKey(int partitionNo, int pageNo) => partitionNo << 20 | pageNo;

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
      await yc.maybeYield();
      final pNo = entry.key;
      final stats = entry.value;

      if (stats.path == null) continue;

      // Try to load existing meta page
      if (!stats.headerLoaded) {
        try {
          final raw0 = await _dataStore.storage
              .readAsBytesAt(stats.path!, 0, length: pageSize);
          if (raw0.isNotEmpty) {
            final local =
                _dataStore.treeMetaPageService.parsePartitionLocalFromPageBytes(
              raw0,
              partitionNo: pNo,
              pageType: BTreePageType.nghMeta,
            );
            if (local != null) {
              stats.oldTotalEntries = local.totalEntries;
              stats.oldFileSizeInBytes = local.fileSizeInBytes;
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

      final newEntries = max(0, stats.oldTotalEntries + stats.entriesDelta);
      final computedSize = (stats.maxPageNoWritten + 1) * pageSize;
      final newSize = max(stats.oldFileSizeInBytes, computedSize);

      // NghIndexMeta lives only on graph partition 0 (same as table/index p0).
      Uint8List? treeGlobalMeta;
      if (category == NghDataCategory.graph && pNo == 0) {
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
          totalEntries: newEntries,
          fileSizeInBytes: newSize,
          freeListHeadPageNo: stats.freeListHeadPageNo,
          freePageCount: stats.freePageCount,
        ),
        treeGlobalMeta: treeGlobalMeta,
      );
      stageWrite(stats.path!, 0, metaBytes);
    }
  }
}
