import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../handler/logger.dart';
import '../handler/meta_binary_codec.dart';
import '../handler/parallel_processor.dart';
import '../handler/platform_handler.dart';
import '../interface/storage_interface.dart';
import '../model/data_store_config.dart';
import '../model/db_exception.dart';
import '../model/ngh_index_meta.dart';
import '../model/parallel_journal_entry.dart';
import '../model/table_context.dart';
import '../model/table_identity.dart';
import 'btree_page.dart';
import 'data_store_impl.dart';
import 'ngh_page.dart';
import 'ngh_pk_map.dart';
import 'page_redo_log_codec.dart';
import 'tree_cache.dart';
import 'workload_scheduler.dart';
import 'yield_controller.dart';

// ============================================================================
// NGH Partition Manager
//
// Page I/O for NGH partition files:
//   posting/ -- inverted cluster SQ8 pages (frozen slot layout, incl. PK)
//   nav/     -- paged Centroid B+Tree pages (the only write path)
//   pkmap/   -- PK locator B+Tree (no page redo)
// Read-only until migrated: ngh/nav_graph.ngh (layoutVersion == 1). Never
// rewritten after engine v4.
// ============================================================================

/// Category of NGH partition data.
enum NghDataCategory {
  posting,
  nav,
  pkmap,
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

  /// Packed `(partitionNo << 20) | pageNo` for **legacy posting `next` only**.
  int get packedRef => packRef(partitionNo, pageNo);

  factory NghPagePtr.fromPacked(NghDataCategory category, int packed) {
    final (part, page) = unpackRef(packed);
    return NghPagePtr(category, part, page);
  }

  /// Pack partition+page into one i32. Values `<= 0` pass through as sentinels.
  /// Returns `-1` when the location cannot be represented.
  static int packRef(int partitionNo, int pageNo) {
    if (pageNo <= 0) return pageNo;
    const maxPackedPartition = 2047;
    if (partitionNo < 0 ||
        partitionNo > maxPackedPartition ||
        pageNo > pageNoMask) {
      return -1;
    }
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

  NghPageId get pageId => NghPageId(partitionNo, pageNo);

  int get cacheKey => pageId.cacheKey;

  factory NghPagePtr.fromPageId(NghDataCategory category, NghPageId id) {
    return NghPagePtr(category, id.partitionNo, id.pageNo);
  }
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
  late final TreeCache<NghNavCentroidPage> _navPageCache;
  late final TreeCache<NghPkMapDirtyPage> _pkmapPageCache;

  NghPartitionManager(this._dataStore) {
    final indexBudget =
        _dataStore.resourceManager?.getIndexCacheSize() ?? (64 * 1024 * 1024);
    _initCaches(indexBudget);
  }

  int get configuredPageSize => _dataStore.configuredPageSize;

  /// TPG2 page size for an NGH category. Posting/nav may be larger than the
  /// database 16KB page for high-D indexes; pkmap always inherits 16KB.
  int pageSizeFor(NghDataCategory category, NghIndexMeta? meta) {
    if (meta == null) return configuredPageSize;
    switch (category) {
      case NghDataCategory.posting:
        return meta.resolvedPostingPageSize(configuredPageSize);
      case NghDataCategory.nav:
        return meta.resolvedNavPageSize(configuredPageSize);
      case NghDataCategory.pkmap:
        return configuredPageSize;
    }
  }

  /// A partition file must hold meta page 0 plus at least one data page.
  int _nghMaxFileSize(int pageSize) =>
      max(_dataStore.config.maxPartitionFileSize, pageSize * 2);

  DataStoreConfig get engineConfig => _dataStore.config;

  /// 8MB payload covers a ~1M-key locator tree and a hot slice at 10M+.
  static const int _pkmapBurstCacheMaxBytes = 8 * 1024 * 1024;
  static const int _pkmapBurstCacheMinBytes = 1 * 1024 * 1024;

  /// Nav page cache vs posting: Centroid B+Tree routing is ~MB-class (48-D
  /// branch entries), while posting holds full-D SQ8. Legacy `~/4` overshot.
  /// Keep a small share of [postingBudget] with a platform floor.
  static (int maxBytes, int minBytes) _navPageCacheBudget(int postingBudget) {
    final floor = PlatformHandler.isMobile ? 8 * 1024 * 1024 : 16 * 1024 * 1024;
    final ratio = PlatformHandler.isMobile ? 0.05 : 0.08;
    final maxBytes = max(floor, (postingBudget * ratio).round());
    final minBytes = max(floor ~/ 2, maxBytes ~/ 2);
    return (maxBytes, minBytes);
  }

  void _initCaches(int indexBudget) {
    // Search-hot leaves use NghGraphEngine._btreeLeafCache (vector quota).
    // Posting pages are the I/O fill layer and must track vector scale —
    // indexBudget*30% alone thrashs after tens of thousands of inserts.
    final nghBudget = max(32 * 1024 * 1024, (indexBudget * 0.30).round());
    final int minThreshold =
        max(8 * 1024 * 1024, min(nghBudget ~/ 2, 32 * 1024 * 1024));
    final (navMax, navMin) = _navPageCacheBudget(nghBudget);
    _postingPageCache = TreeCache<NghPostingPage>(
      sizeCalculator: (page) => page.estimateResidentBytes(),
      maxByteThreshold: nghBudget,
      minByteThreshold: minThreshold,
      groupDepth: 2,
      debugLabel: 'NghPostingPageCache',
    );
    _navPageCache = TreeCache<NghNavCentroidPage>(
      sizeCalculator: (page) =>
          32 + page.centroids.length * (64 + page.dimensions * 4 + 64),
      maxByteThreshold: navMax,
      minByteThreshold: navMin,
      groupDepth: 2,
      debugLabel: 'NghNavPageCache',
    );
    _pkmapPageCache = TreeCache<NghPkMapDirtyPage>(
      sizeCalculator: (page) => page.estimatePayloadSize() + 32,
      maxByteThreshold: _pkmapBurstCacheMaxBytes,
      minByteThreshold: _pkmapBurstCacheMinBytes,
      groupDepth: 2,
      debugLabel: 'NghPkmapPageCache',
    );
  }

  /// Refresh TreeCache byte ceilings after ResourceManager finishes sizing.
  void syncCacheBudget({
    required int indexBudget,
    int? vectorPostingBudget,
  }) {
    final budget = indexBudget > 0 ? indexBudget : 128 * 1024 * 1024;
    final fromIndex = max(16 * 1024 * 1024, (budget * 0.30).round());
    final nghBudget = max(fromIndex, vectorPostingBudget ?? fromIndex);
    final minThreshold =
        max(8 * 1024 * 1024, min(nghBudget ~/ 2, 32 * 1024 * 1024));
    final (navMax, navMin) = _navPageCacheBudget(nghBudget);
    _postingPageCache.updateByteThreshold(
      max: nghBudget,
      min: minThreshold,
    );
    _navPageCache.updateByteThreshold(
      max: navMax,
      min: navMin,
    );
    _pkmapPageCache.updateByteThreshold(
      max: _pkmapBurstCacheMaxBytes,
      min: _pkmapBurstCacheMinBytes,
    );
  }

  /// Delete all physical files and directories belonging to a vector index.
  Future<void> deletePhysicalIndexArtifacts(
    TableContext table,
    IndexUid indexUid,
  ) async {
    _postingPageCache.remove([table.tableUid, indexUid]);
    _navPageCache.remove([table.tableUid, indexUid]);
    _pkmapPageCache.remove([table.tableUid, indexUid]);

    final basePath =
        _dataStore.pathManager.getIndexPathByContext(table, indexUid);
    if (await _dataStore.storage.existsDirectory(basePath)) {
      await _dataStore.storage.deleteDirectory(basePath);
    }
  }

  /// Clear all in-memory caches and reset state.
  Future<void> dispose() async {
    _postingPageCache.clear();
    _navPageCache.clear();
    _pkmapPageCache.clear();
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
      final pageSize = pageSizeFor(NghDataCategory.posting, meta);
      final raw = await _dataStore.storage
          .readAsBytesAt(path, pageNo * pageSize, length: pageSize);
      if (raw.isEmpty) return null;

      final parsed = BTreePageIO.parsePageBytes(raw);
      final page = NghPostingPage.tryDecodePayload(
          _decodePayload(parsed.encodedPayload));
      if (page == null) return null;

      _postingPageCache.putPoint4(
          tableUid, indexUid, partitionNo, pageNo, page);
      return page;
    } catch (e) {
      if (e is DbClosedException) rethrow;
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

    final pageSize = pageSizeFor(NghDataCategory.posting, meta);
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

  /// Read the navigating centroid graph from disk (legacy blob or paged v2).
  Future<NghNavGraphPage?> readNavGraph(
    TableContext table,
    IndexUid indexUid, {
    NghIndexMeta? meta,
  }) async {
    if (meta != null && meta.isPagedLayout) {
      return readPagedNavGraph(table, indexUid, meta);
    }
    final pagedGuess =
        meta == null ? await readPagedNavGraph(table, indexUid, null) : null;
    if (pagedGuess != null && pagedGuess.centroids.isNotEmpty) {
      return pagedGuess;
    }
    return readLegacyNavGraphBlob(table, indexUid);
  }

  /// Legacy whole-file `nav_graph.ngh`.
  Future<NghNavGraphPage?> readLegacyNavGraphBlob(
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
        final page = NghNavGraphPage.tryDecodePayload(
            _decodePayload(parsed.encodedPayload));
        if (page != null) {
          NghPageSizer.sanitizeNavGraph(
            page.centroids,
            pageSize: configuredPageSize,
            dimensions: page.dimensions,
          );
        }
        return page;
      } catch (_) {}
    }
    final blob = NghNavGraphPage.tryDecodePayload(bytes);
    if (blob != null) {
      NghPageSizer.sanitizeNavGraph(
        blob.centroids,
        pageSize: configuredPageSize,
        dimensions: blob.dimensions,
      );
    }
    return blob;
  }

  /// Load all v2 centroid pages into an in-memory [NghNavGraphPage].
  Future<NghNavGraphPage?> readPagedNavGraph(
    TableContext table,
    IndexUid indexUid,
    NghIndexMeta? meta,
  ) async {
    final dims = meta?.dimensions ?? 0;
    final expected = meta?.centroidCount ?? 0;
    if (meta != null && (dims <= 0 || expected <= 0)) {
      return NghNavGraphPage(dimensions: max(1, dims), centroids: []);
    }

    if (meta == null) {
      final centroids = <NghNavCentroidNode>[];
      var dimensions = 1;
      int? diskPack;
      const maxPages = 1 << 16;
      for (int linear = 0; linear < maxPages; linear++) {
        final page = await readNavCentroidPage(
          table,
          indexUid,
          _linearNavPtr(null, linear),
        );
        if (page == null || page.centroids.isEmpty) break;
        diskPack ??= page.centroids.length;
        dimensions = page.dimensions;
        centroids.addAll(page.centroids);
      }
      if (centroids.isEmpty) return null;
      NghPageSizer.sanitizeNavGraph(
        centroids,
        pageSize: configuredPageSize,
        dimensions: dimensions,
      );
      return NghNavGraphPage(
        dimensions: dimensions,
        centroids: centroids,
        navPackPerPage: diskPack,
      );
    }

    final navPageSize = pageSizeFor(NghDataCategory.nav, meta);
    final perPage = NghPageSizer.navCentroidsPerPage(navPageSize, dims);
    final fromCount = expected > 0 ? (expected + perPage - 1) ~/ perPage : 0;
    final fromNext = max(0, meta.navNextPageNo - NghIndexMeta.firstDataPageNo);
    final pageCount = max(fromCount, fromNext);
    if (pageCount <= 0) return null;

    final centroids = <NghNavCentroidNode>[];
    int dimensions = dims;
    int? diskPack;
    for (int linear = 0; linear < max(pageCount, 1); linear++) {
      final ptr = _linearNavPtr(meta, linear);
      final page = await readNavCentroidPage(table, indexUid, ptr,
          pageSize: navPageSize);
      if (page == null) break;
      diskPack ??= page.centroids.length;
      dimensions = page.dimensions;
      centroids.addAll(page.centroids);
      if (expected > 0 && centroids.length >= expected) break;
    }
    if (centroids.isEmpty) return null;
    NghPageSizer.sanitizeNavGraph(
      centroids,
      pageSize: navPageSize,
      dimensions: dimensions,
    );
    return NghNavGraphPage(
      dimensions: dimensions,
      centroids: centroids,
      navPackPerPage: diskPack,
    );
  }

  NghPagePtr _linearNavPtr(NghIndexMeta? meta, int linear) {
    final pageSize = pageSizeFor(NghDataCategory.nav, meta);
    final maxFile = _nghMaxFileSize(pageSize);
    final dataPagesPerPart = max(1, (maxFile ~/ pageSize) - 1);
    final partition = linear ~/ dataPagesPerPart;
    final pageNo = (linear % dataPagesPerPart) + NghIndexMeta.firstDataPageNo;
    return NghPagePtr(NghDataCategory.nav, partition, pageNo);
  }

  Future<NghNavCentroidPage?> readNavCentroidPage(
    TableContext table,
    IndexUid indexUid,
    NghPagePtr ptr, {
    int? pageSize,
  }) async {
    final cached = _navPageCache.getPoint4(
        table.tableUid, indexUid, ptr.partitionNo, ptr.pageNo);
    if (cached != null) return cached;
    final path =
        _partitionPath(NghDataCategory.nav, table, indexUid, ptr.partitionNo);
    final ps = pageSize ?? configuredPageSize;
    try {
      final raw = await _dataStore.storage
          .readAsBytesAt(path, ptr.pageNo * ps, length: ps);
      if (raw.isEmpty) return null;
      final parsed = BTreePageIO.parsePageBytes(raw);
      final page = NghNavCentroidPage.tryDecodePayload(
          _decodePayload(parsed.encodedPayload));
      if (page == null) return null;
      _navPageCache.putPoint4(
          table.tableUid, indexUid, ptr.partitionNo, ptr.pageNo, page);
      return page;
    } catch (e) {
      if (e is DbClosedException) rethrow;
      Logger.warn(
        'NGH nav page torn at p${ptr.partitionNo} pg${ptr.pageNo} for "$indexUid".',
        rawError: e,
      );
      return null;
    }
  }

  /// Read the Centroid B+Tree Root Table page (page 1 of partition 0 in nav).
  Future<NghNavRootPage?> readNavRootPage(
    TableContext table,
    IndexUid indexUid, {
    NghIndexMeta? meta,
    int partitionNo = 0,
    int pageNo = 1,
  }) async {
    final pageSize = pageSizeFor(NghDataCategory.nav, meta);
    final path =
        _partitionPath(NghDataCategory.nav, table, indexUid, partitionNo);
    try {
      final raw = await _dataStore.storage
          .readAsBytesAt(path, pageNo * pageSize, length: pageSize);
      if (raw.isEmpty) return null;
      final parsed = BTreePageIO.parsePageBytes(raw);
      return NghNavRootPage.tryDecodePayload(
          _decodePayload(parsed.encodedPayload));
    } catch (e) {
      if (e is DbClosedException) rethrow;
      return null;
    }
  }

  /// Read a Centroid B+Tree internal branch page from nav partition.
  Future<NghNavBTreePage?> readNavBTreePage(
    TableContext table,
    IndexUid indexUid,
    NghPageId id, {
    NghIndexMeta? meta,
  }) async {
    if (id.isNone) return null;
    final pageSize = pageSizeFor(NghDataCategory.nav, meta);
    final path =
        _partitionPath(NghDataCategory.nav, table, indexUid, id.partitionNo);
    try {
      final raw = await _dataStore.storage
          .readAsBytesAt(path, id.pageNo * pageSize, length: pageSize);
      if (raw.isEmpty) return null;
      final parsed = BTreePageIO.parsePageBytes(raw);
      return NghNavBTreePage.tryDecodePayload(
          _decodePayload(parsed.encodedPayload));
    } catch (e) {
      if (e is DbClosedException) rethrow;
      return null;
    }
  }

  Future<NghPkMapDirtyPage?> readPkmapPage(
    TableContext table,
    IndexUid indexUid,
    NghPagePtr ptr,
  ) async {
    final cached = _pkmapPageCache.getPoint4(
        table.tableUid, indexUid, ptr.partitionNo, ptr.pageNo);
    if (cached != null) return cached;
    final path =
        _partitionPath(NghDataCategory.pkmap, table, indexUid, ptr.partitionNo);
    try {
      final raw = await _dataStore.storage.readAsBytesAt(
          path, ptr.pageNo * configuredPageSize,
          length: configuredPageSize);
      if (raw.isEmpty) return null;
      final parsed = BTreePageIO.parsePageBytes(raw);
      final payload = _decodePayload(parsed.encodedPayload);
      final NghPkMapDirtyPage page;
      if (parsed.type == BTreePageType.internal) {
        final inner = InternalPage.tryDecodePayload(payload);
        if (inner == null) return null;
        page = NghPkMapDirtyPage.internal(inner);
      } else {
        final leaf = LeafPage.tryDecodePayload(payload);
        if (leaf == null) return null;
        page = NghPkMapDirtyPage.leaf(leaf);
      }
      _pkmapPageCache.putPoint4(
          table.tableUid, indexUid, ptr.partitionNo, ptr.pageNo, page);
      return page;
    } catch (e) {
      if (e is DbClosedException) rethrow;
      Logger.warn(
        'NGH pkmap page torn at p${ptr.partitionNo} pg${ptr.pageNo} for "$indexUid".',
        rawError: e,
      );
      return null;
    }
  }

  /// Read posting pages by v2 page ids (partition >= 2048 safe).
  Future<List<({NghPageId id, NghPostingPage page})>> readPostingPagesByIds(
    TableContext table,
    IndexUid indexUid,
    NghIndexMeta meta,
    List<NghPageId> ids, {
    Map<int, NghPostingPage>? localCache,
    bool populatePageCache = true,
  }) async {
    if (ids.isEmpty) return const [];
    final packed = <int>[];
    final packedToId = <int, NghPageId>{};
    final unpacked = <NghPageId>[];
    for (final id in ids) {
      if (id.isNone) continue;
      final p = id.tryPack();
      if (p != null && p > 0) {
        packed.add(p);
        packedToId[p] = id;
      } else {
        unpacked.add(id);
      }
    }
    final out = <({NghPageId id, NghPostingPage page})>[];
    if (packed.isNotEmpty) {
      final loaded = await readPostingPagesBatch(
        table,
        indexUid,
        meta,
        packed,
        localCache: localCache,
        populatePageCache: populatePageCache,
      );
      for (final item in loaded) {
        out.add((
          id: packedToId[item.packedRef] ??
              NghPageId.fromPacked(item.packedRef),
          page: item.page,
        ));
      }
    }
    for (final id in unpacked) {
      final page = await readPostingPage(
        table,
        indexUid,
        meta,
        id.partitionNo,
        id.pageNo,
        localCache: localCache,
      );
      if (page != null) out.add((id: id, page: page));
    }
    return out;
  }

  /// Convert a legacy `nav_graph.ngh` blob into paged nav. Does not
  /// rewrite posting files.
  Future<
      ({
        NghIndexMeta meta,
        Map<NghPagePtr, NghNavCentroidPage> nav,
      })> migrateLegacyNavGraph({
    required TableContext table,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    required NghNavGraphPage blob,
  }) async {
    final dirtyNav = <NghPagePtr, NghNavCentroidPage>{};
    var current = meta;
    final dims = blob.dimensions;
    final navPageSize = pageSizeFor(NghDataCategory.nav, current);
    final perPage = NghPageSizer.navCentroidsPerPage(navPageSize, dims);

    final centroids = blob.centroids;
    for (final c in centroids) {
      c.level = NghNavCentroidNode.levelLeaf;
      if (c.postingPages.isEmpty) {
        for (final packed in c.postingPageNos) {
          c.addPostingPage(NghPageId.fromPacked(packed));
        }
      }
      c.postingDirDirty = false;
    }

    for (int i = 0; i < centroids.length; i += perPage) {
      final chunk = centroids.sublist(i, min(i + perPage, centroids.length));
      final (ptrs, nextMeta) = allocatePagesBatchSync(
        NghDataCategory.nav,
        current,
        1,
      );
      current = nextMeta;
      dirtyNav[ptrs.first] = NghNavCentroidPage(
        dimensions: dims,
        centroids: chunk,
      );
    }

    current = current.copyWith(
      layoutVersion: NghIndexMeta.layoutPaged,
      centroidCount: centroids.length,
    );
    return (meta: current, nav: dirtyNav);
  }

  /// Rebuild nav pages covering [dirtyCentroidIds].
  ///
  /// Worst-case records/page is stable for a given D, so a dirty flush writes
  /// only the linear pages that contain dirty ids (plus the last page if the
  /// graph grew). If on-disk occupancy differs (old 7-pack vs 5-pack), rewrite
  /// **every** linear page once so ranges do not mix.
  Map<NghPagePtr, NghNavCentroidPage> buildDirtyNavPages({
    required NghIndexMeta meta,
    required List<NghNavCentroidNode> centroids,
    required Set<int> dirtyCentroidIds,
    int? diskRecordsPerPage,
    bool rewriteAll = false,
  }) {
    if (centroids.isEmpty) return {};
    final navPageSize = pageSizeFor(NghDataCategory.nav, meta);
    NghPageSizer.sanitizeNavGraph(
      centroids,
      pageSize: navPageSize,
      dimensions: meta.dimensions,
    );
    var perPage =
        NghPageSizer.navCentroidsPerPage(navPageSize, meta.dimensions);
    final occupancyChanged = diskRecordsPerPage != null &&
        diskRecordsPerPage > 0 &&
        diskRecordsPerPage != perPage;
    final full = rewriteAll || occupancyChanged;

    Map<NghPagePtr, NghNavCentroidPage> pack(int per, {required bool all}) {
      final dirty = <NghPagePtr, NghNavCentroidPage>{};
      final needed = (centroids.length + per - 1) ~/ per;
      final linears = <int>{};
      if (all) {
        for (int linear = 0; linear < needed; linear++) {
          linears.add(linear);
        }
      } else {
        for (final id in dirtyCentroidIds) {
          if (id >= 0 && id < centroids.length) linears.add(id ~/ per);
        }
        if (centroids.isNotEmpty) {
          linears.add((centroids.length - 1) ~/ per);
        }
      }
      for (final linear in linears) {
        if (linear < 0 || linear >= needed) continue;
        final start = linear * per;
        final end = min(start + per, centroids.length);
        dirty[_linearNavPtr(meta, linear)] = NghNavCentroidPage(
          dimensions: meta.dimensions,
          centroids: centroids.sublist(start, end),
        );
      }
      return dirty;
    }

    var dirty = pack(perPage, all: full);
    while (perPage > 1 &&
        dirty.values.any((p) => !_navPayloadFits(
            p.estimatePayloadSize(pageSize: navPageSize), navPageSize))) {
      perPage--;
      dirty = pack(perPage, all: true);
    }
    return dirty;
  }

  /// Whether a posting payload will fit this index's posting TPG2 page.
  bool postingPayloadFits(int plainPayloadLen, {required int pageSize}) {
    return BTreePageSizer.fitsInPage(
      pageSize: pageSize,
      plainPayloadLen: plainPayloadLen,
      config: _dataStore.config,
    );
  }

  bool _navPayloadFits(int plainPayloadLen, int pageSize) {
    return BTreePageSizer.fitsInPage(
      pageSize: pageSize,
      plainPayloadLen: plainPayloadLen,
      config: _dataStore.config,
    );
  }

  /// Ensure nav allocation covers [centroidCount] densely addressed pages.
  NghIndexMeta ensureNavCoverage(
    NghIndexMeta meta,
    int centroidCount, {
    int navPageCount = 0,
  }) {
    if (centroidCount <= 0) {
      return meta.copyWith(centroidCount: 0);
    }
    final perPage = NghPageSizer.navCentroidsPerPage(
      pageSizeFor(NghDataCategory.nav, meta),
      meta.dimensions,
    );
    final needed = max(
      navPageCount,
      (centroidCount + perPage - 1) ~/ perPage,
    );
    var partCount = max(1, meta.navPartitionCount);
    var next = meta.navNextPageNo;
    for (int linear = 0; linear < needed; linear++) {
      final ptr = _linearNavPtr(meta, linear);
      if (ptr.partitionNo + 1 > partCount) {
        partCount = ptr.partitionNo + 1;
      }
      if (ptr.partitionNo == partCount - 1 && ptr.pageNo >= next) {
        next = ptr.pageNo + 1;
      }
    }
    return meta.copyWith(
      centroidCount: centroidCount,
      navPartitionCount: partCount,
      navNextPageNo: max(next, NghIndexMeta.firstDataPageNo),
    );
  }

  /// Number of pages in a posting partition file (including page 0 meta).
  Future<int> postingFilePageCount(
    TableContext table,
    IndexUid indexUid,
    NghIndexMeta meta,
    int partitionNo,
  ) async {
    final path = _dataStore.pathManager
        .getNghPostingPartitionPathByContext(table, indexUid, partitionNo);
    try {
      if (!await _dataStore.storage.existsFile(path)) return 0;
      final size = await _dataStore.storage.getFileSize(path);
      final pageSize = pageSizeFor(NghDataCategory.posting, meta);
      return size ~/ pageSize;
    } catch (_) {
      return 0;
    }
  }

  /// Rewrite NGH TPG2 pages under the current encoding key (key migration).
  Future<void> rewriteEncryptedPages(
    TableContext table,
    IndexUid indexUid,
    NghIndexMeta meta,
  ) async {
    Future<void> rewriteCategory(NghDataCategory category, int count) async {
      final pageSize = pageSizeFor(category, meta);
      for (int p = 0; p < max(1, count); p++) {
        final path = _partitionPath(category, table, indexUid, p);
        if (!await _dataStore.storage.existsFile(path)) continue;
        int fileSize = 0;
        try {
          fileSize = await _dataStore.storage.getFileSize(path);
        } catch (_) {
          continue;
        }
        final pageCount = fileSize ~/ pageSize;
        for (int pg = 0; pg < pageCount; pg++) {
          try {
            final raw = await _dataStore.storage
                .readAsBytesAt(path, pg * pageSize, length: pageSize);
            if (raw.isEmpty) continue;
            final parsed = BTreePageIO.parsePageBytes(raw);
            final plain = _decodePayload(parsed.encodedPayload);
            final rebuilt = _buildPageBytes(
              parsed.type,
              plain,
              pageSize,
              _dataStore.config.encryptionConfig?.shouldEncryptVectorIndex ??
                  false,
            );
            await _dataStore.storage
                .writeAsBytesAt(path, pg * pageSize, rebuilt);
          } catch (_) {}
        }
      }
    }

    await rewriteCategory(NghDataCategory.posting, meta.postingPartitionCount);
    await rewriteCategory(NghDataCategory.nav, meta.navPartitionCount);
    await rewriteCategory(NghDataCategory.pkmap, meta.pkmapPartitionCount);
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
    Map<NghPagePtr, NghNavCentroidPage> dirtyNavPages = const {},
    Map<NghPagePtr, NghNavBTreePage> dirtyNavBTreePages = const {},
    ({NghPagePtr ptr, NghNavRootPage page})? dirtyNavRootPage,
    Map<NghPagePtr, NghPkMapDirtyPage> dirtyPkmapPages = const {},
    List<NghPagePtr> freePostingPages = const [],
    bool deleteLegacyNavGraph = false,
    int vectorsDelta = 0,
    int deletedDelta = 0,
    BatchContext? batchContext,
    int? concurrency,
    int? yieldBudgetMs,
  }) async {
    final tableUid = table.tableUid;
    if (dirtyPostingPages.isEmpty &&
        dirtyNavPages.isEmpty &&
        dirtyNavBTreePages.isEmpty &&
        dirtyNavRootPage == null &&
        dirtyPkmapPages.isEmpty &&
        freePostingPages.isEmpty &&
        !deleteLegacyNavGraph) {
      return meta;
    }

    final postingPageSize = pageSizeFor(NghDataCategory.posting, meta);
    final navPageSize = pageSizeFor(NghDataCategory.nav, meta);
    final sidecarPageSize = configuredPageSize;
    int sizeOf(NghDataCategory category) {
      switch (category) {
        case NghDataCategory.posting:
          return postingPageSize;
        case NghDataCategory.nav:
          return navPageSize;
        case NghDataCategory.pkmap:
          return sidecarPageSize;
      }
    }

    final yc = YieldController(
      'NghPartitionManager.writeChanges',
      checkInterval: 40,
      budgetMs: yieldBudgetMs,
    );

    final staged = <String, Map<int, Uint8List>>{};

    void stageWrite(String path, int offset, Uint8List bytes) {
      staged.putIfAbsent(path, () => <int, Uint8List>{})[offset] = bytes;
    }

    final postingStats = <int, _NghPartitionStats>{};
    final navStats = <int, _NghPartitionStats>{};
    final pkmapStats = <int, _NghPartitionStats>{};

    _NghPartitionStats getStats(Map<int, _NghPartitionStats> map, int pNo) {
      return map.putIfAbsent(pNo, () => _NghPartitionStats());
    }

    final encCfg = _dataStore.config.encryptionConfig;
    final bool encrypt = encCfg?.shouldEncryptVectorIndex ?? false;
    final redoRecords = <Uint8List>[];
    final redoBatch = (batchContext != null && batchContext.batchId.isNotEmpty)
        ? batchContext
        : _dataStore.parallelJournalManager.activeBatchContext;
    final recordPageRedo = redoBatch != null &&
        redoBatch.batchId.isNotEmpty &&
        redoBatch.recordsPageRedo &&
        _dataStore.config.enableJournal;

    // Encode every nav page before recording nghNav redo. Overflow used to
    // throw mid-loop after earlier pages were already in the batch redo, and
    // replay mixed 7-pack with 5-pack pages → RangeError on child ids.
    final navBuilt =
        <({NghPagePtr ptr, Uint8List pageBytes, NghNavCentroidPage? page})>[];
    for (final entry in dirtyNavPages.entries) {
      final payload = entry.value.encodePayload(pageSize: navPageSize);
      navBuilt.add((
        ptr: entry.key,
        pageBytes: _buildPageBytes(
          BTreePageType.nghNavGraph,
          payload,
          navPageSize,
          encrypt,
        ),
        page: entry.value,
      ));
    }
    for (final entry in dirtyNavBTreePages.entries) {
      final payload = entry.value.encodePayload();
      navBuilt.add((
        ptr: entry.key,
        pageBytes: _buildPageBytes(
          BTreePageType.nghNavGraph,
          payload,
          navPageSize,
          encrypt,
        ),
        page: null,
      ));
    }
    if (dirtyNavRootPage != null) {
      final payload = dirtyNavRootPage.page.encodePayload();
      navBuilt.add((
        ptr: dirtyNavRootPage.ptr,
        pageBytes: _buildPageBytes(
          BTreePageType.nghNavGraph,
          payload,
          navPageSize,
          encrypt,
        ),
        page: null,
      ));
    }

    Future<void> stageBuilt({
      required NghDataCategory category,
      required Map<int, _NghPartitionStats> statsMap,
      required NghPagePtr ptr,
      required Uint8List pageBytes,
      PageRedoTreeKind? redoKind,
    }) async {
      final stats = getStats(statsMap, ptr.partitionNo);
      stats.path ??= _partitionPath(category, table, indexUid, ptr.partitionNo);
      if (!stats.dirEnsured) {
        await _dataStore.storage.ensureDirectoryExists(p.dirname(stats.path!));
        stats.dirEnsured = true;
      }
      stageWrite(stats.path!, ptr.pageNo * sizeOf(category), pageBytes);
      stats.maxPageNoWritten = max(stats.maxPageNoWritten, ptr.pageNo);
      if (redoKind != null && recordPageRedo) {
        redoRecords.add(PageRedoLogCodec.encodePageRecord(
          treeKind: redoKind,
          tableUid: table.tableUid,
          indexUid: indexUid,
          partitionNo: ptr.partitionNo,
          pageNo: ptr.pageNo,
          payload: pageBytes,
        ));
      }
    }

    Future<void> stageTyped({
      required NghDataCategory category,
      required Map<int, _NghPartitionStats> statsMap,
      required NghPagePtr ptr,
      required BTreePageType pageType,
      required Uint8List payload,
      PageRedoTreeKind? redoKind,
    }) async {
      await stageBuilt(
        category: category,
        statsMap: statsMap,
        ptr: ptr,
        pageBytes:
            _buildPageBytes(pageType, payload, sizeOf(category), encrypt),
        redoKind: redoKind,
      );
    }

    var workingMeta = meta;
    final freedKeys = <int>{
      for (final ptr in freePostingPages) ptr.cacheKey,
    };
    for (final ptr in freePostingPages) {
      final stats = getStats(postingStats, ptr.partitionNo);
      stats.path ??= _partitionPath(
          NghDataCategory.posting, table, indexUid, ptr.partitionNo);
      if (!stats.dirEnsured) {
        await _dataStore.storage.ensureDirectoryExists(p.dirname(stats.path!));
        stats.dirEnsured = true;
      }
      await _ensureNghPartitionHeaderLoaded(
        stats,
        partitionNo: ptr.partitionNo,
        pageSize: postingPageSize,
      );
      final diskHead = stats.freeListHeadPageNo;
      if ((workingMeta.postingFreeListHeads[ptr.partitionNo] ?? -1) <
              NghIndexMeta.firstDataPageNo &&
          diskHead >= NghIndexMeta.firstDataPageNo) {
        final heads = Map<int, int>.from(workingMeta.postingFreeListHeads);
        heads[ptr.partitionNo] = diskHead;
        workingMeta = workingMeta.copyWith(postingFreeListHeads: heads);
      }
      workingMeta = await pushFreePage(
        NghDataCategory.posting,
        workingMeta,
        ptr,
        table,
        indexUid,
        stageWrite,
      );
      stats.freeListHeadPageNo = ptr.pageNo;
      stats.freePageCount += 1;
      stats.maxPageNoWritten = max(stats.maxPageNoWritten, ptr.pageNo);
    }

    for (final entry in dirtyPostingPages.entries) {
      if (freedKeys.contains(entry.key.cacheKey)) continue;
      final y0 = yc.maybeYield();
      if (y0 != null) await y0;
      await stageTyped(
        category: NghDataCategory.posting,
        statsMap: postingStats,
        ptr: entry.key,
        pageType: BTreePageType.nghPosting,
        payload: entry.value.encodePayload(),
      );
      _postingPageCache.putPoint4(tableUid, indexUid, entry.key.partitionNo,
          entry.key.pageNo, entry.value);
    }

    for (final item in navBuilt) {
      final y1 = yc.maybeYield();
      if (y1 != null) await y1;
      await stageBuilt(
        category: NghDataCategory.nav,
        statsMap: navStats,
        ptr: item.ptr,
        pageBytes: item.pageBytes,
        redoKind: PageRedoTreeKind.nghNav,
      );
      if (item.page != null) {
        _navPageCache.putPoint4(tableUid, indexUid, item.ptr.partitionNo,
            item.ptr.pageNo, item.page!);
      }
    }

    for (final entry in dirtyPkmapPages.entries) {
      final y3 = yc.maybeYield();
      if (y3 != null) await y3;
      await stageTyped(
        category: NghDataCategory.pkmap,
        statsMap: pkmapStats,
        ptr: entry.key,
        pageType: entry.value.pageType,
        payload: entry.value.encodePayload(),
      );
      _pkmapPageCache.putPoint4(tableUid, indexUid, entry.key.partitionNo,
          entry.key.pageNo, entry.value);
    }

    // Engine v4: never rewrite nav_graph.ngh.
    // Persist posting p0 NghIndexMeta *before* deleting the blob so a crash
    // cannot leave layout=1 with no readable nav.
    if (deleteLegacyNavGraph) {
      final p0 = getStats(postingStats, 0);
      p0.path ??= _dataStore.pathManager
          .getNghPostingPartitionPathByContext(table, indexUid, 0);
    }

    final sizeDeltaSum = await _computePartitionSizeDeltaSum([
      (stats: postingStats, pageSize: postingPageSize),
      (stats: navStats, pageSize: navPageSize),
      (stats: pkmapStats, pageSize: sidecarPageSize),
    ]);
    final now = DateTime.now();
    final updatedMeta = workingMeta.copyWith(
      totalVectors: max(0, workingMeta.totalVectors + vectorsDelta),
      deletedCount: max(0, workingMeta.deletedCount + deletedDelta),
      totalSizeBytes: max(0, workingMeta.totalSizeBytes + sizeDeltaSum),
      timestamps: workingMeta.timestamps.copyWith(modified: now),
    );
    _dataStore.tableDataManager.applyIndexOccupancyDelta(
      table,
      sizeDelta: sizeDeltaSum,
      entryDelta: vectorsDelta,
    );

    await _stagePartitionMeta(postingStats, postingPageSize, updatedMeta,
        stageWrite, yc, NghDataCategory.posting);
    await _stagePartitionMeta(navStats, navPageSize, updatedMeta, stageWrite,
        yc, NghDataCategory.nav);
    await _stagePartitionMeta(pkmapStats, sidecarPageSize, updatedMeta,
        stageWrite, yc, NghDataCategory.pkmap);

    if (!postingStats.containsKey(0) && staged.isNotEmpty) {
      final p0Stats = getStats(postingStats, 0);
      p0Stats.path ??= _dataStore.pathManager
          .getNghPostingPartitionPathByContext(table, indexUid, 0);
      await _stagePartitionMeta(
        {0: p0Stats},
        postingPageSize,
        updatedMeta,
        stageWrite,
        yc,
        NghDataCategory.posting,
      );
    }

    if (redoRecords.isNotEmpty && recordPageRedo) {
      final batchId = redoBatch.batchId;
      final redoPath = _dataStore.pathManager.getPageRedoLogPath(
        batchId,
        spaceName: _dataStore.currentSpaceName,
      );
      await _dataStore.storage.ensureDirectoryExists(p.dirname(redoPath));
      var total = 0;
      for (final r in redoRecords) {
        total += r.length;
      }
      final merged = Uint8List(total);
      var off = 0;
      for (final r in redoRecords) {
        merged.setRange(off, off + r.length, r);
        off += r.length;
      }
      await _dataStore.storage.appendBytes(
        redoPath,
        PageRedoLogCodec.wrapChunk(merged),
        flush: true,
      );
    }

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

    if (deleteLegacyNavGraph) {
      await deleteLegacyNavBlobIfExists(table, indexUid);
    }

    return updatedMeta;
  }

  /// Delete leftover `nav_graph.ngh` after a successful paged migrate.
  Future<void> deleteLegacyNavBlobIfExists(
    TableContext table,
    IndexUid indexUid,
  ) async {
    final legacy =
        _dataStore.pathManager.getNghNavGraphPathByContext(table, indexUid);
    try {
      if (await _dataStore.storage.existsFile(legacy)) {
        await _dataStore.storage.deleteFile(legacy);
      }
    } catch (_) {}
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

    final pageSize = pageSizeFor(category, meta);
    final maxFileSize = _nghMaxFileSize(pageSize);
    final pages = <NghPagePtr>[];
    var partitionCount = _partitionCountOf(category, meta);
    var nextPg = _nextPageNoOf(category, meta);
    if (partitionCount < 1) {
      partitionCount = 1;
      nextPg = NghIndexMeta.firstDataPageNo;
    }

    for (int i = 0; i < count; i++) {
      final activePartition = partitionCount - 1;
      if (NghPageSizer.estimateFileSizeBytes(pageSize, nextPg) > maxFileSize) {
        partitionCount += 1;
        nextPg = NghIndexMeta.firstDataPageNo + 1;
        pages.add(NghPagePtr(
          category,
          partitionCount - 1,
          NghIndexMeta.firstDataPageNo,
        ));
        continue;
      }
      pages.add(NghPagePtr(category, activePartition, nextPg));
      nextPg += 1;
    }
    return (pages, _copyAlloc(category, meta, partitionCount, nextPg));
  }

  int _partitionCountOf(NghDataCategory category, NghIndexMeta meta) {
    switch (category) {
      case NghDataCategory.posting:
        return meta.postingPartitionCount;
      case NghDataCategory.nav:
        return meta.navPartitionCount;
      case NghDataCategory.pkmap:
        return meta.pkmapPartitionCount;
    }
  }

  int _nextPageNoOf(NghDataCategory category, NghIndexMeta meta) {
    switch (category) {
      case NghDataCategory.posting:
        return meta.postingNextPageNo;
      case NghDataCategory.nav:
        return meta.navNextPageNo;
      case NghDataCategory.pkmap:
        return meta.pkmapNextPageNo;
    }
  }

  NghIndexMeta _copyAlloc(
    NghDataCategory category,
    NghIndexMeta meta,
    int partitionCount,
    int nextPageNo,
  ) {
    switch (category) {
      case NghDataCategory.posting:
        return meta.copyWith(
          postingPartitionCount: partitionCount,
          postingNextPageNo: nextPageNo,
        );
      case NghDataCategory.nav:
        return meta.copyWith(
          navPartitionCount: partitionCount,
          navNextPageNo: nextPageNo,
        );
      case NghDataCategory.pkmap:
        return meta.copyWith(
          pkmapPartitionCount: partitionCount,
          pkmapNextPageNo: nextPageNo,
        );
    }
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
    final pageSize = pageSizeFor(category, meta);
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
      final pageSize = pageSizeFor(category, meta);

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
    switch (category) {
      case NghDataCategory.posting:
        return Map<int, int>.from(meta.postingFreeListHeads);
      case NghDataCategory.nav:
        return Map<int, int>.from(meta.navFreeListHeads);
      case NghDataCategory.pkmap:
        return Map<int, int>.from(meta.pkmapFreeListHeads);
    }
  }

  /// Return a new meta with updated free-list heads for the given category.
  NghIndexMeta _setFreeListHeads(
      NghDataCategory category, NghIndexMeta meta, Map<int, int> heads) {
    switch (category) {
      case NghDataCategory.posting:
        return meta.copyWith(postingFreeListHeads: heads);
      case NghDataCategory.nav:
        return meta.copyWith(navFreeListHeads: heads);
      case NghDataCategory.pkmap:
        return meta.copyWith(pkmapFreeListHeads: heads);
    }
  }

  /// Resolve the partition file path for a given category and partition number.
  String _partitionPath(NghDataCategory category, TableContext table,
      IndexUid indexUid, int partitionNo) {
    final pm = _dataStore.pathManager;
    switch (category) {
      case NghDataCategory.posting:
        return pm.getNghPostingPartitionPathByContext(
            table, indexUid, partitionNo);
      case NghDataCategory.nav:
        return pm.getNghNavPartitionPathByContext(table, indexUid, partitionNo);
      case NghDataCategory.pkmap:
        return pm.getNghPkmapPartitionPathByContext(
            table, indexUid, partitionNo);
    }
  }

  // =====================================================================
  // Cache Management
  // =====================================================================

  /// Current total size of all NGH page caches.
  int getCurrentPageCacheSize() {
    return _postingPageCache.estimatedTotalSizeBytes +
        _navPageCache.estimatedTotalSizeBytes +
        _pkmapPageCache.estimatedTotalSizeBytes;
  }

  /// Evict a portion of all NGH page caches.
  Future<void> evictPageCache({double ratio = 0.3}) async {
    await _postingPageCache.cleanup(removeRatio: ratio);
    await _navPageCache.cleanup(removeRatio: ratio);
    await _pkmapPageCache.cleanup(removeRatio: ratio);
  }

  /// Clear all NGH page caches synchronously.
  void clearPageCacheSync() {
    _postingPageCache.clear();
    _navPageCache.clear();
    _pkmapPageCache.clear();
  }

  /// Clear caches for a specific table.
  void clearPageCacheForTable(TableUid tableUid) {
    _postingPageCache.remove([tableUid]);
    _navPageCache.remove([tableUid]);
    _pkmapPageCache.remove([tableUid]);
  }

  /// Clear caches for a specific index.
  void clearPageCacheForIndex(TableUid tableUid, IndexUid indexUid) {
    _postingPageCache.remove([tableUid, indexUid]);
    _navPageCache.remove([tableUid, indexUid]);
    _pkmapPageCache.remove([tableUid, indexUid]);
  }

  // =====================================================================
  // Private Helpers
  // =====================================================================

  int _cacheKey(int partitionNo, int pageNo) =>
      (partitionNo << 32) | (pageNo & 0xFFFFFFFF);

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
    List<({Map<int, _NghPartitionStats> stats, int pageSize})> groups,
  ) async {
    var sum = 0;
    for (final group in groups) {
      for (final entry in group.stats.entries) {
        final stats = entry.value;
        if (stats.path == null) continue;
        await _ensureNghPartitionHeaderLoaded(
          stats,
          partitionNo: entry.key,
          pageSize: group.pageSize,
        );
        final computedSize = (stats.maxPageNoWritten + 1) * group.pageSize;
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
