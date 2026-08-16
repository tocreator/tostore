import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../handler/common.dart';
import '../handler/encryption.dart';
import '../handler/logger.dart';
import '../handler/memcomparable.dart';
import '../handler/meta_binary_codec.dart';
import '../handler/parallel_processor.dart';
import '../interface/storage_interface.dart';
import '../model/data_block_entry.dart';
import '../model/data_store_config.dart';
import '../model/db_exception.dart';
import '../model/encoder_config.dart';
import '../model/index_search.dart';
import '../model/meta_info.dart';
import '../model/parallel_journal_entry.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/table_context.dart';
import '../model/table_identity.dart';
import 'btree_page.dart';
import 'compute/btree_page_encode_batch_runner.dart';
import 'compute_tasks.dart';
import 'data_store_impl.dart';
import 'page_redo_log_codec.dart';
import 'storage_adapter.dart';
import 'tree_cache.dart';
import 'workload_scheduler.dart';
import 'yield_controller.dart';

/// New baseline implementation: paged global leaf-chain B+Tree per index.
///
/// Key/value format is defined by [IndexManager]:
/// - Unique index: key=tuple(fields...), value=[0][utf8(pk)]
/// - Non-unique index: key=tuple(fields..., pk), value=[0]
/// - Delete: value=[1] indicates removing that key
final class IndexTreePartitionManager {
  final DataStoreImpl _dataStore;
  StorageAdapter get _storage => _dataStore.storage;

  // pageNo=0 is reserved for PartitionMetaPage; data pages start at 1.
  static const int _firstDataPageNo = 1;

  String keyOfPtr(TreePagePtr p) => '${p.partitionNo}:${p.pageNo}';

  // Instance-level page cache for read operations (cross-method calls)
  // Key format: [tableUid, indexUid, partitionNo, pageNo]
  // This cache significantly reduces IO reads for frequently accessed pages,
  // especially internal nodes which are shared across many queries.
  late final TreeCache<LeafPage> _leafPageCache;
  late final TreeCache<InternalPage> _internalPageCache;

  IndexTreePartitionManager(this._dataStore) {
    // Initialize page caches using memory manager quota
    final resourceManager = _dataStore.resourceManager;
    final indexCacheSize =
        resourceManager?.getIndexCacheSize() ?? (128 * 1024 * 1024);
    // Allocate 30% of index cache for B+Tree pages (15% for leaf, 15% for internal)
    final int pageCacheSize = (indexCacheSize * 0.30).toInt();
    final int leafCacheSize = (pageCacheSize * 0.50).toInt();
    final int internalCacheSize = pageCacheSize - leafCacheSize;

    _leafPageCache = TreeCache<LeafPage>(
      sizeCalculator: _estimateLeafPageSize,
      maxByteThreshold: leafCacheSize,
      minByteThreshold: 50 * 1024 * 1024, // 50MB minimum
      groupDepth: 2, // Group by [table.tableUid, indexUid]
      debugLabel: 'IndexLeafPageCache',
    );

    _internalPageCache = TreeCache<InternalPage>(
      sizeCalculator: _estimateInternalPageSize,
      maxByteThreshold: internalCacheSize,
      minByteThreshold: 50 * 1024 * 1024, // 50MB minimum
      groupDepth: 2, // Group by [table.tableUid, indexUid]
      debugLabel: 'IndexInternalPageCache',
    );
  }

  String _indexDisplayName(TableContext table, IndexUid indexUid) {
    final idx = _dataStore.tableMetaManager
        ?.findIndexSchemaByUid(table.schema, indexUid);
    return idx?.actualIndexName ?? 'index';
  }

  /// Estimate size in bytes for a LeafPage
  int _estimateLeafPageSize(LeafPage page) {
    int size = 64; // Object overhead
    size += page.highKey.length;
    for (final k in page.keys) {
      size += k.length;
    }
    for (final v in page.values) {
      size += v.length;
    }
    return size;
  }

  /// Estimate size in bytes for an InternalPage
  int _estimateInternalPageSize(InternalPage page) {
    int size = 64; // Object overhead
    for (final k in page.maxKeys) {
      size += k.length;
    }
    size += page.children.length * 8; // TreePagePtr = 8 bytes (2 ints)
    return size;
  }

  /// Get current page cache size in bytes (leaf + internal)
  int getCurrentPageCacheSize() {
    return _leafPageCache.estimatedTotalSizeBytes +
        _internalPageCache.estimatedTotalSizeBytes;
  }

  /// Evict a ratio of page cache entries under memory pressure
  Future<void> evictPageCache({double ratio = 0.3}) async {
    try {
      await _leafPageCache.cleanup(removeRatio: ratio);
      await _internalPageCache.cleanup(removeRatio: ratio);
    } catch (e) {
      Logger.warn('Evict page cache failed', rawError: e);
    }
  }

  /// Clear all page caches synchronously
  void clearPageCacheSync() {
    try {
      _leafPageCache.clear();
      _internalPageCache.clear();
    } catch (e) {
      Logger.warn('Clear page cache failed', rawError: e);
    }
  }

  /// Clear page cache for a specific table
  void clearPageCacheForTable(TableContext table) {
    try {
      _leafPageCache.remove([table.tableUid]);
      _internalPageCache.remove([table.tableUid]);
    } catch (e) {
      Logger.warn('Clear page cache for table failed', rawError: e);
    }
  }

  /// Clear page cache for a specific index
  void clearPageCacheForIndex(TableContext table, IndexUid indexUid) {
    try {
      _leafPageCache.remove([table.tableUid, indexUid]);
      _internalPageCache.remove([table.tableUid, indexUid]);
    } catch (e) {
      Logger.warn('Clear page cache for index failed', rawError: e);
    }
  }

  /// Prewarm boundary leaf pages (first/last) for a B+Tree index.
  ///
  /// Returns an approximate number of bytes loaded into the page cache.
  Future<int> prewarmBoundaryPages(
    TableContext table,
    IndexUid indexUid, {
    IndexMeta? meta,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    final tableUid = table.tableUid;
    final resolvedMeta = meta ??
        await _dataStore.indexManager?.getIndexMeta(table.tableUid, indexUid);
    if (resolvedMeta == null || resolvedMeta.btreeFirstLeaf.isNull) {
      return 0;
    }

    int loadedBytes = 0;
    final pageSize = _dataStore.configuredPageSize;
    final firstLeaf = resolvedMeta.btreeFirstLeaf;
    final lastLeaf = resolvedMeta.btreeLastLeaf;

    Future<void> prewarmLeaf(TreePagePtr ptr) async {
      if (ptr.isNull) return;
      final cacheKey = [tableUid, indexUid, ptr.partitionNo, ptr.pageNo];
      final alreadyCached = _leafPageCache.containsKey(cacheKey);
      await _readLeaf(
        table,
        indexUid,
        resolvedMeta,
        ptr,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
      );
      if (!alreadyCached) {
        loadedBytes += pageSize;
      }
    }

    await prewarmLeaf(firstLeaf);
    if (lastLeaf != firstLeaf) {
      await prewarmLeaf(lastLeaf);
    }

    return loadedBytes;
  }

  /// Get partition file path using the dirIndex from partition meta.
  Future<String> _partitionFilePath(TableContext table, IndexUid indexUid,
      IndexMeta meta, int partitionNo) async {
    final count = meta.btreePartitionCount;
    if (partitionNo < 0 || partitionNo >= count) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'Invalid partitionNo: $partitionNo (count=$count)',
        ),
      ]);
    }
    return _dataStore.pathManager
        .getIndexPartitionPathByNo(table.tableUid, indexUid, partitionNo);
  }

  Uint8List _aad(TreePagePtr ptr, BTreePageType type) {
    final bd = ByteData(9);
    bd.setInt32(0, ptr.partitionNo, Endian.little);
    bd.setInt32(4, ptr.pageNo, Endian.little);
    bd.setUint8(8, type.index);
    return bd.buffer.asUint8List();
  }

  Future<LeafPage> _readLeaf(
    TableContext table,
    IndexUid indexUid,
    IndexMeta meta,
    TreePagePtr ptr, {
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    Map<String, LeafPage>? localCache,
    bool readFromFileOnly = false,
  }) async {
    final tableName = table.tableName;
    final tableUid = table.tableUid;
    if (ptr.isNull) return LeafPage.empty();

    // Check local cache first (for writeChanges batch consistency)
    if (localCache != null) {
      final k = keyOfPtr(ptr);
      final cached = localCache[k];
      if (cached != null) return cached;
    }

    // Check instance-level cache
    final cacheKey = [tableUid, indexUid, ptr.partitionNo, ptr.pageNo];
    final instanceCached = _leafPageCache.get(cacheKey);
    if (instanceCached != null) {
      // Copy to local cache if provided
      if (localCache != null) {
        localCache[keyOfPtr(ptr)] = instanceCached;
      }
      return instanceCached;
    }

    // Cache miss: read from disk
    final count = meta.btreePartitionCount;
    if (ptr.partitionNo < 0 || ptr.partitionNo >= count) {
      return LeafPage.empty();
    }
    final path =
        await _partitionFilePath(table, indexUid, meta, ptr.partitionNo);
    final pageSize = _dataStore.configuredPageSize;
    final raw = await _storage.readAsBytesAt(path, ptr.pageNo * pageSize,
        length: pageSize);
    if (raw.isEmpty) return LeafPage.empty();
    try {
      final parsed = BTreePageIO.parsePageBytes(raw);
      if (parsed.type == BTreePageType.free) return LeafPage.empty();
      if (parsed.type != BTreePageType.leaf) return LeafPage.empty();
      final payload = BTreePageCodec.decodePayload(
        parsed.encodedPayload,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        aad: _aad(ptr, parsed.type),
      );
      final leaf = LeafPage.tryDecodePayload(payload) ?? LeafPage.empty();

      // Cache the page (both local and instance-level)
      if (leaf.keys.isNotEmpty) {
        if (localCache != null) {
          localCache[keyOfPtr(ptr)] = leaf;
        }
        if (!readFromFileOnly) {
          _leafPageCache.put(cacheKey, leaf);
        }
      }
      return leaf;
    } catch (e) {
      throw DbException.forceWrap(
        e,
        forceType: ResultType.engError,
        message:
            'Corrupted B+Tree leaf page: index=$tableName.${_indexDisplayName(table, indexUid)} ptr=$ptr path=$path err=$e',
      );
    }
  }

  Future<InternalPage> _readInternal(
    TableContext table,
    IndexUid indexUid,
    IndexMeta meta,
    TreePagePtr ptr, {
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    Map<String, InternalPage>? localCache,
    bool readFromFileOnly = false,
  }) async {
    final tableName = table.tableName;
    final tableUid = table.tableUid;
    if (ptr.isNull) return InternalPage.empty();

    // Check local cache first (for writeChanges batch consistency)
    if (localCache != null) {
      final k = keyOfPtr(ptr);
      final cached = localCache[k];
      if (cached != null) return cached;
    }

    // Check instance-level cache
    final cacheKey = [tableUid, indexUid, ptr.partitionNo, ptr.pageNo];
    final instanceCached = _internalPageCache.get(cacheKey);
    if (instanceCached != null) {
      // Copy to local cache if provided
      if (localCache != null) {
        localCache[keyOfPtr(ptr)] = instanceCached;
      }
      return instanceCached;
    }

    // Cache miss: read from disk
    final count = meta.btreePartitionCount;
    if (ptr.partitionNo < 0 || ptr.partitionNo >= count) {
      return InternalPage.empty();
    }
    final path =
        await _partitionFilePath(table, indexUid, meta, ptr.partitionNo);
    final pageSize = _dataStore.configuredPageSize;
    final raw = await _storage.readAsBytesAt(path, ptr.pageNo * pageSize,
        length: pageSize);
    if (raw.isEmpty) return InternalPage.empty();
    try {
      final parsed = BTreePageIO.parsePageBytes(raw);
      if (parsed.type == BTreePageType.free) return InternalPage.empty();
      if (parsed.type != BTreePageType.internal) return InternalPage.empty();
      final payload = BTreePageCodec.decodePayload(
        parsed.encodedPayload,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        aad: _aad(ptr, parsed.type),
      );
      final page =
          InternalPage.tryDecodePayload(payload) ?? InternalPage.empty();

      // Cache the page (both local and instance-level)
      if (page.children.isNotEmpty) {
        if (localCache != null) {
          localCache[keyOfPtr(ptr)] = page;
        }
        if (!readFromFileOnly) {
          _internalPageCache.put(cacheKey, page);
        }
      }
      return page;
    } catch (e) {
      throw DbException.forceWrap(
        e,
        forceType: ResultType.engError,
        message:
            'Corrupted B+Tree internal page: index=$tableName.${_indexDisplayName(table, indexUid)} ptr=$ptr path=$path err=$e',
      );
    }
  }

  Future<IndexMeta> _rotatePartition(IndexMeta meta) async {
    final now = DateTime.now();
    final currentCount = meta.btreePartitionCount;
    return meta.copyWith(
      btreePartitionCount: currentCount + 1,
      // Reserve pageNo=0 for partition meta page.
      btreeNextPageNo: _firstDataPageNo,
      timestamps: Timestamps(created: meta.timestamps.created, modified: now),
    );
  }

  IndexMeta _consumeNext(IndexMeta meta) =>
      meta.copyWith(btreeNextPageNo: meta.btreeNextPageNo + 1);

  Future<TreePagePtr> _locateLeafForKey(
    TableContext table,
    IndexUid indexUid,
    IndexMeta meta,
    Uint8List keyBytes, {
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool readFromFileOnly = false,
  }) async {
    final root = meta.btreeRoot;
    final firstLeaf = meta.btreeFirstLeaf;
    if (root.isNull) return firstLeaf;
    if (meta.btreeHeight <= 0) return root;
    TreePagePtr cur = root;
    for (int depth = meta.btreeHeight; depth > 0; depth--) {
      final node = await _readInternal(table, indexUid, meta, cur,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
          readFromFileOnly: readFromFileOnly);
      if (node.children.isEmpty) return firstLeaf;
      final idx = node.childIndexForKey(keyBytes);
      cur = node.children[idx];
    }
    return cur;
  }

  Future<TreePagePtr> _locateRightmostLeaf(
    TableContext table,
    IndexUid indexUid,
    IndexMeta meta, {
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool readFromFileOnly = false,
  }) async {
    final root = meta.btreeRoot;
    final lastLeaf = meta.btreeLastLeaf;
    if (root.isNull) return lastLeaf;
    if (meta.btreeHeight <= 0) return root;
    TreePagePtr cur = root;
    for (int depth = meta.btreeHeight; depth > 0; depth--) {
      final node = await _readInternal(table, indexUid, meta, cur,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
          readFromFileOnly: readFromFileOnly);
      if (node.children.isEmpty) return lastLeaf;
      cur = node.children.last;
    }

    return cur;
  }

  Future<TreePagePtr> _locateRightmostLeafFast(
    TableContext table,
    IndexUid indexUid,
    IndexMeta meta, {
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool readFromFileOnly = false,
  }) async {
    final root = meta.btreeRoot;
    final lastLeaf = meta.btreeLastLeaf;
    if (root.isNull) return lastLeaf;
    if (meta.btreeHeight <= 0) return root;
    if (lastLeaf.isNull) {
      return _locateRightmostLeaf(
        table,
        indexUid,
        meta,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        readFromFileOnly: readFromFileOnly,
      );
    }

    try {
      final leaf = await _readLeaf(
        table,
        indexUid,
        meta,
        lastLeaf,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        readFromFileOnly: readFromFileOnly,
      );
      final looksValid = leaf.next.isNull &&
          (leaf.keys.isNotEmpty ||
              !leaf.prev.isNull ||
              meta.totalEntryCount <= 0);
      if (looksValid) {
        return lastLeaf;
      }
    } catch (_) {}

    return _locateRightmostLeaf(
      table,
      indexUid,
      meta,
      encryptionKey: encryptionKey,
      encryptionKeyId: encryptionKeyId,
      readFromFileOnly: readFromFileOnly,
    );
  }

  /// Apply index deltas (put/delete) to paged tree.
  Future<void> writeChanges({
    required TableContext table,
    required IndexUid indexUid,
    required IndexMeta indexMeta,
    required List<DataBlockEntry> deltas,
    BatchContext? batchContext,
    int? concurrency,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    final tableName = table.tableName;
    final tableUid = table.tableUid;
    final indexLogName = _indexDisplayName(table, indexUid);
    final sw = Stopwatch()..start();
    final totalDeltas = deltas.length;

    if (totalDeltas == 0) {
      return;
    }

    // Initialize meta with B+Tree fields if not present
    var meta = indexMeta;
    // Coalesce by key bytes (last-write-wins), then sort by key.
    final ops = <ByteKey, Uint8List>{};
    final yc = YieldController('IndexTreePartitionManager.writeChanges',
        checkInterval: 300);
    for (final d in deltas) {
      final y1 = yc.maybeYield();
      if (y1 != null) await y1;
      final key = ByteKey(d.key);
      final existing = ops[key];
      if (existing == null) {
        ops[key] = d.value;
        continue;
      }

      if (meta.isUnique) {
        final existingIsDelete = existing.isNotEmpty && existing[0] == 1;
        final incomingIsDelete = d.value.isNotEmpty && d.value[0] == 1;

        // Unique replacement in one flush batch is often encoded as:
        // put(newOwner) -> delete(oldOwner) on the same logical key.
        // The final state must keep the key present rather than deleted.
        if (!existingIsDelete && incomingIsDelete) {
          continue;
        }
      }

      ops[key] = d.value;
    }
    if (ops.isEmpty) return;

    final entries = ops.entries.toList(growable: false);
    entries.sort((a, b) => MemComparableKey.compare(a.key.bytes, b.key.bytes));

    // Stage writes per path (last-write-wins per offset).
    final Map<String, Map<int, Uint8List>> staged = {};
    // Track per-partition: path, entriesDelta.
    final Map<int, _IndexPartitionStats> partitionStats = {};

    // ---- Local page cache to avoid re-reading within this batch ----
    // Moved from instance variables to local variables to prevent memory bloat
    // in large-scale data scenarios. Cache is automatically cleared after method returns.
    final Map<String, LeafPage> leafCache = {};
    final Map<String, InternalPage> internalCache = {};

    _IndexPartitionStats getStats(int pNo) =>
        partitionStats.putIfAbsent(pNo, () => _IndexPartitionStats());

    void stageWrite(String path, int offset, Uint8List bytes) {
      staged.putIfAbsent(path, () => <int, Uint8List>{})[offset] = bytes;
    }

    Uint8List? peekStaged(String path, int offset) {
      final m = staged[path];
      if (m == null) return null;
      return m[offset];
    }

    Future<void> ensurePartitionHeaderLoaded(int pNo) async {
      final stats = getStats(pNo);
      if (stats.headerLoaded) return;
      stats.path ??= await _partitionFilePath(table, indexUid, meta, pNo);
      final pageSize = _dataStore.configuredPageSize;
      try {
        final raw0 =
            await _storage.readAsBytesAt(stats.path!, 0, length: pageSize);
        if (raw0.isNotEmpty) {
          final local =
              _dataStore.treeMetaPageService.parsePartitionLocalFromPageBytes(
            raw0,
            partitionNo: pNo,
            pageType: BTreePageType.meta,
            encryptionKey: encryptionKey,
            encryptionKeyId: encryptionKeyId,
          );
          if (local != null) {
            stats.oldTotalEntries = local.totalEntryCount;
            stats.oldFileSizeInBytes = local.totalSizeBytes;
            stats.oldFreeListHeadPageNo = local.freeListHeadPageNo;
            stats.oldFreePageCount = local.freePageCount;
            stats.oldFlushBatchKey = local.lastFlushBatchKey;
            stats.oldMaintBatchKey = local.lastMaintenanceBatchKey;
            stats.freeListHeadPageNo = local.freeListHeadPageNo;
            stats.freePageCount = local.freePageCount;
            if (batchContext != null && batchContext.batchId.isNotEmpty) {
              stats.alreadyDurableForBatch = local.matchesBatchKey(
                isMaintenance: batchContext.batchType == BatchType.maintenance,
                batchId: batchContext.batchId,
              );
            }
          } else {
            stats.oldFileSizeInBytes = await _storage.getFileSize(stats.path!);
          }
        }
      } catch (_) {
        try {
          stats.oldFileSizeInBytes = await _storage.getFileSize(stats.path!);
        } catch (_) {}
      } finally {
        stats.headerLoaded = true;
      }
    }

    Future<void> pushFreePage(TreePagePtr ptr) async {
      if (ptr.pageNo <= 0) return;
      await ensurePartitionHeaderLoaded(ptr.partitionNo);
      final stats = getStats(ptr.partitionNo);
      stats.path ??=
          await _partitionFilePath(table, indexUid, meta, ptr.partitionNo);
      if (!stats.dirEnsured) {
        await _storage.ensureDirectoryExists(p.dirname(stats.path!));
        stats.dirEnsured = true;
      }
      final next = stats.freeListHeadPageNo;
      final freeBytes = BTreePageIO.buildPageBytes(
        type: BTreePageType.free,
        encodedPayload: FreePage(nextFreePageNo: next).encodePayload(),
        pageSize: _dataStore.configuredPageSize,
      );
      stageWrite(
          stats.path!, ptr.pageNo * _dataStore.configuredPageSize, freeBytes);
      stats.freeListHeadPageNo = ptr.pageNo;
      stats.freePageCount = stats.freePageCount + 1;
      stats.maxPageNoWritten = max(stats.maxPageNoWritten, ptr.pageNo);
    }

    Future<TreePagePtr?> popFreePage(int partitionNo) async {
      await ensurePartitionHeaderLoaded(partitionNo);
      final stats = getStats(partitionNo);
      final head = stats.freeListHeadPageNo;
      if (head < _firstDataPageNo) return null;
      stats.path ??=
          await _partitionFilePath(table, indexUid, meta, partitionNo);
      final pageSize = _dataStore.configuredPageSize;
      final off = head * pageSize;
      final stagedBytes = peekStaged(stats.path!, off);
      final raw = stagedBytes ??
          await _storage.readAsBytesAt(stats.path!, off, length: pageSize);
      if (raw.isEmpty) return null;
      try {
        final parsed = BTreePageIO.parsePageBytes(raw);
        if (parsed.type != BTreePageType.free) {
          throw DbException([
            GeneralStatus(
              type: ResultType.engError,
              message: 'Freelist head page is not free: type=${parsed.type}',
            ),
          ]);
        }
        final fp = FreePage.tryDecodePayload(parsed.encodedPayload);
        if (fp == null) {
          throw DbException([
            GeneralStatus(
              type: ResultType.engError,
              message: 'Failed to decode FreePage payload',
            ),
          ]);
        }
        // Cycle safety: if corrupted and points to itself, drop the freelist.
        if (fp.nextFreePageNo == head) {
          stats.freeListHeadPageNo = -1;
          stats.freePageCount = 0;
          return null;
        }
        stats.freeListHeadPageNo = fp.nextFreePageNo;
        stats.freePageCount = max(0, stats.freePageCount - 1);
        return TreePagePtr(partitionNo, head);
      } catch (_) {
        // Corruption tolerance:
        // freelist is an optimization; if it is damaged, reset it and fall back to append allocation.
        stats.freeListHeadPageNo = -1;
        stats.freePageCount = 0;
        return null;
      }
    }

    // ---- Dirty pages (encode once per page at end) ----
    final Map<TreePagePtr, LeafPage> dirtyLeaves = <TreePagePtr, LeafPage>{};
    final Map<TreePagePtr, InternalPage> dirtyInternals =
        <TreePagePtr, InternalPage>{};

    bool leafFits(LeafPage leaf) {
      return BTreePageSizer.fitsInPage(
        pageSize: _dataStore.configuredPageSize,
        plainPayloadLen: leaf.estimatePayloadSize(),
        config: _dataStore.config,
        encryptionKeyId: encryptionKeyId,
      );
    }

    bool internalFits(InternalPage page) {
      return BTreePageSizer.fitsInPage(
        pageSize: _dataStore.configuredPageSize,
        plainPayloadLen: page.estimatePayloadSize(),
        config: _dataStore.config,
        encryptionKeyId: encryptionKeyId,
      );
    }

    void markLeafDirty(TreePagePtr ptr, LeafPage leaf) {
      leafCache[keyOfPtr(ptr)] = leaf;
      dirtyLeaves[ptr] = leaf;
      final stats = getStats(ptr.partitionNo);
      stats.maxPageNoWritten = max(stats.maxPageNoWritten, ptr.pageNo);
    }

    void markInternalDirty(TreePagePtr ptr, InternalPage node) {
      internalCache[keyOfPtr(ptr)] = node;
      dirtyInternals[ptr] = node;
      final stats = getStats(ptr.partitionNo);
      stats.maxPageNoWritten = max(stats.maxPageNoWritten, ptr.pageNo);
    }

    Future<TreePagePtr> allocatePage() async {
      final activePartitionNo = meta.btreePartitionCount - 1;
      final reused = await popFreePage(activePartitionNo);
      if (reused != null) return reused;

      final pageSize = _dataStore.configuredPageSize;
      final nextPg = meta.btreeNextPageNo;
      if (BTreeAllocator.estimateFileSizeBytes(pageSize, nextPg) >
          _dataStore.config.maxPartitionFileSize) {
        meta = await _rotatePartition(meta);
      }
      final partitionCount = meta.btreePartitionCount;
      final ptr = TreePagePtr(partitionCount - 1, meta.btreeNextPageNo);
      meta = _consumeNext(meta);
      return ptr;
    }

    Future<LeafPage> getLeaf(TreePagePtr ptr) async {
      return await _readLeaf(table, indexUid, meta, ptr,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
          localCache: leafCache);
    }

    Future<InternalPage> getInternal(TreePagePtr ptr) async {
      return await _readInternal(table, indexUid, meta, ptr,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
          localCache: internalCache);
    }

    Future<TreePagePtr> ensureRootLeaf() async {
      final root = meta.btreeRoot;
      if (!root.isNull) return root;
      final ptr = await allocatePage();
      final leaf = LeafPage.empty();
      meta = meta.copyWith(
        btreeFirstLeaf: ptr,
        btreeLastLeaf: ptr,
        btreeRoot: ptr,
        btreeHeight: 0,
      );
      markLeafDirty(ptr, leaf);
      return ptr;
    }

    Future<TreePagePtr> descendToLeaf(
        Uint8List key, List<_IFrame> frames) async {
      await ensureRootLeaf();
      final height = meta.btreeHeight;
      if (height <= 0) return meta.btreeRoot;
      TreePagePtr cur = meta.btreeRoot;
      for (int depth = height; depth > 0; depth--) {
        final node = await getInternal(cur);
        if (node.children.isEmpty) {
          return meta.btreeFirstLeaf;
        }
        final idx = node.childIndexForKey(key);
        if (idx < 0 || idx >= node.children.length) {
          return meta.btreeFirstLeaf;
        }
        frames.add(_IFrame(ptr: cur, node: node, childIndex: idx));
        cur = node.children[idx];
      }
      return cur;
    }

    Future<void> insertSplitIntoParents(
      List<_IFrame> frames, {
      required Uint8List leftHighKey,
      required TreePagePtr leftPtr,
      required Uint8List rightHighKey,
      required TreePagePtr rightPtr,
    }) async {
      if (frames.isEmpty) {
        final root = InternalPage(
          maxKeys: <Uint8List>[leftHighKey, rightHighKey],
          children: <TreePagePtr>[leftPtr, rightPtr],
        );
        final rootPtr = await allocatePage();
        meta = meta.copyWith(
          btreeRoot: rootPtr,
          btreeHeight: meta.btreeHeight + 1,
        );
        markInternalDirty(rootPtr, root);
        return;
      }
      final frame = frames.removeLast();
      final node = frame.node;
      final i = frame.childIndex;
      node.setEntry(i, leftHighKey, leftPtr);
      node.insertEntry(i + 1, rightHighKey, rightPtr);

      if (internalFits(node)) {
        markInternalDirty(frame.ptr, node);
        return;
      }

      final split = node.split();
      final rightNode = split.right;
      final rightPtrNode = await allocatePage();

      markInternalDirty(frame.ptr, node);
      markInternalDirty(rightPtrNode, rightNode);

      await insertSplitIntoParents(
        frames,
        leftHighKey: node.maxKey(),
        leftPtr: frame.ptr,
        rightHighKey: rightNode.maxKey(),
        rightPtr: rightPtrNode,
      );
    }

    bool isLeafUnderfull(LeafPage leaf) {
      if (leaf.keys.isEmpty) return false;
      final int used = leaf.estimatePayloadSize();
      final int threshold = (_dataStore.configuredPageSize * 0.25).floor();
      return used > 0 && used < threshold;
    }

    Future<void> tryMergeLeafWithRightSibling(
      TreePagePtr leafPtr,
      LeafPage leaf,
      List<_IFrame> frames,
    ) async {
      if (meta.btreeHeight <= 0) return;
      if (frames.isEmpty) return;
      if (!isLeafUnderfull(leaf)) return;

      final parentFrame = frames.last;
      final parent = parentFrame.node;
      final int i = parentFrame.childIndex;
      if (i < 0 || i + 1 >= parent.children.length) return;

      final rightPtr = parent.children[i + 1];
      if (rightPtr.isNull) return;
      final right = await getLeaf(rightPtr);
      if (right.keys.isEmpty) return;

      final merged = LeafPage(
        prev: leaf.prev,
        next: right.next,
        highKey: right.highKey,
        keys: <Uint8List>[...leaf.keys, ...right.keys],
        values: <Uint8List>[...leaf.values, ...right.values],
      );
      if (!leafFits(merged)) return;

      leaf.keys.addAll(right.keys);
      leaf.values.addAll(right.values);
      leaf.highKey = right.highKey;
      final oldRightNext = right.next;
      leaf.next = oldRightNext;

      if (!oldRightNext.isNull) {
        final nextLeaf = await getLeaf(oldRightNext);
        nextLeaf.prev = leafPtr;
        markLeafDirty(oldRightNext, nextLeaf);
      } else {
        meta = meta.copyWith(btreeLastLeaf: leafPtr);
      }

      parent.setEntry(i, leaf.highKey, leafPtr);
      parent.maxKeys.removeAt(i + 1);
      parent.children.removeAt(i + 1);

      if (parentFrame.ptr == meta.btreeRoot &&
          meta.btreeHeight == 1 &&
          parent.children.length == 1) {
        final newRoot = parent.children.first;
        meta = meta.copyWith(btreeRoot: newRoot, btreeHeight: 0);
        dirtyInternals.remove(parentFrame.ptr);
        await pushFreePage(parentFrame.ptr);
      } else {
        markInternalDirty(parentFrame.ptr, parent);
      }

      dirtyLeaves.remove(rightPtr);
      await pushFreePage(rightPtr);

      markLeafDirty(leafPtr, leaf);
    }

    bool sawDelete = false;
    TreePagePtr? lastDeleteLeafPtr;
    // Apply sorted ops.

    // Bulk cursor: for sorted keys, avoid descending the tree for every delta.
    TreePagePtr? curLeafPtr;
    LeafPage? curLeaf;

    Future<TreePagePtr> descendToLeafPtrOnly(Uint8List key) async {
      await ensureRootLeaf();
      final height = meta.btreeHeight;
      if (height <= 0) return meta.btreeRoot;
      TreePagePtr cur = meta.btreeRoot;
      for (int depth = height; depth > 0; depth--) {
        final node = await getInternal(cur);
        if (node.children.isEmpty) return meta.btreeFirstLeaf;
        final idx = node.childIndexForKey(key);
        if (idx < 0 || idx >= node.children.length) return meta.btreeFirstLeaf;
        cur = node.children[idx];
      }
      return cur;
    }

    for (final e in entries) {
      final y2 = yc.maybeYield();
      if (y2 != null) await y2;
      final keyBytes = e.key.bytes;
      final val = e.value;
      final isDelete = val.isNotEmpty && val[0] == 1;
      if (isDelete) sawDelete = true;

      TreePagePtr leafPtr;
      LeafPage leaf;
      final lp = curLeafPtr;
      final lf = curLeaf;
      if (lp != null &&
          lf != null &&
          (lf.highKey.isEmpty ||
              MemComparableKey.compare(lf.highKey, keyBytes) >= 0)) {
        leafPtr = lp;
        leaf = lf;
      } else {
        leafPtr = await descendToLeafPtrOnly(keyBytes);
        leaf = await getLeaf(leafPtr);
        curLeafPtr = leafPtr;
        curLeaf = leaf;
      }

      if (isDelete) {
        final deleted = leaf.delete(keyBytes);
        if (!deleted) continue;
        getStats(leafPtr.partitionNo).entriesDelta -= 1;
        // Delete cannot cause overflow.
        markLeafDirty(leafPtr, leaf);
        // Only compute parent frames if underfull to avoid per-op descent.
        if (meta.btreeHeight > 0 &&
            isLeafUnderfull(leaf) &&
            leaf.keys.isNotEmpty) {
          final frames = <_IFrame>[];
          await descendToLeaf(leaf.keys.first, frames);
          await tryMergeLeafWithRightSibling(leafPtr, leaf, frames);
        }
        lastDeleteLeafPtr = leafPtr;
        continue;
      } else {
        // Check if key exists before upsert to distinguish insert vs update.
        final exists = leaf.find(keyBytes) != null;
        leaf.upsert(keyBytes, val);
        if (!exists) {
          getStats(leafPtr.partitionNo).entriesDelta += 1;
        }
      }

      if (leafFits(leaf)) {
        markLeafDirty(leafPtr, leaf);
        continue;
      }

      // Structural update: compute parent frames only when needed (split).
      final frames = <_IFrame>[];
      final locatedPtr = await descendToLeaf(keyBytes, frames);
      if (locatedPtr != leafPtr) {
        leafPtr = locatedPtr;
        leaf = await getLeaf(leafPtr);
        curLeafPtr = leafPtr;
        curLeaf = leaf;
      }

      final split = leaf.split();
      final rightLeafPtr = await allocatePage();
      final rightLeaf = split.right;

      rightLeaf.prev = leafPtr;
      rightLeaf.next = leaf.next;
      final oldNext = leaf.next;
      leaf.next = rightLeafPtr;
      if (!oldNext.isNull) {
        final nextLeaf = await getLeaf(oldNext);
        nextLeaf.prev = rightLeafPtr;
        markLeafDirty(oldNext, nextLeaf);
      } else {
        meta = meta.copyWith(btreeLastLeaf: rightLeafPtr);
      }

      markLeafDirty(leafPtr, leaf);
      markLeafDirty(rightLeafPtr, rightLeaf);

      await insertSplitIntoParents(
        frames,
        leftHighKey: leaf.highKey,
        leftPtr: leafPtr,
        rightHighKey: rightLeaf.highKey,
        rightPtr: rightLeafPtr,
      );

      // Update cursor after split for subsequent sorted keys.
      if (MemComparableKey.compare(leaf.highKey, keyBytes) < 0) {
        curLeafPtr = rightLeafPtr;
        curLeaf = rightLeaf;
      } else {
        curLeafPtr = leafPtr;
        curLeaf = leaf;
      }
    }

    // Lightweight trigger: enqueue background compaction when deletes happen.
    if (sawDelete && lastDeleteLeafPtr != null && !lastDeleteLeafPtr.isNull) {
      try {
        _dataStore.compactionManager
            .enqueueIndex(table, indexUid, hint: lastDeleteLeafPtr);
      } catch (_) {}
    }

    // Pages touched by this batch's entries (leaf + internal), excluding meta/free.
    int targetLeafPages = 0;
    int targetInternalPages = 0;

    // ---- Encode dirty pages into staged writes (once per page) ----
    if (dirtyLeaves.isNotEmpty || dirtyInternals.isNotEmpty) {
      final stageYc = YieldController(
        'IndexTreePartitionManager.writeChanges.stagePages',
        checkInterval: 40,
      );

      final int? encTypeIndex =
          _dataStore.config.encryptionConfig?.encryptionType.index;
      final EncoderConfig encoderConfig =
          EncryptionManager.getCurrentEncodingState();

      EncryptionType? encType;
      if (encTypeIndex != null) {
        encType = EncryptionTypeExtension.fromInt(encTypeIndex);
      }

      bool shouldUseIsolateForPageEncode(int batchCount) {
        if (batchCount <= 0) return false;
        if (encType == EncryptionType.aes256Gcm ||
            encType == EncryptionType.chacha20Poly1305) {
          return batchCount >= 4;
        }
        if (encType == EncryptionType.xorObfuscation ||
            encType == EncryptionType.none) {
          return batchCount >= 48;
        }
        return batchCount >= 96;
      }

      final int totalPagesToEncode = dirtyLeaves.length + dirtyInternals.length;
      final bool useIsolateForPageEncode =
          shouldUseIsolateForPageEncode(totalPagesToEncode);

      bool payloadFitsInPage(int plainPayloadLen) => BTreePageSizer.fitsInPage(
            pageSize: _dataStore.configuredPageSize,
            plainPayloadLen: plainPayloadLen,
            config: _dataStore.config,
            encryptionKeyId: encryptionKeyId,
          );

      const int chunkSize = 32;
      final pending = <BTreePageEncodeItem>[];
      final pendingPtrs = <TreePagePtr>[];

      Future<void> flushEncodeChunk() async {
        if (pending.isEmpty) return;

        final pageSize = _dataStore.configuredPageSize;
        final res = await BTreePageEncodeBatchRunner.encode(
          enableIsolate: useIsolateForPageEncode,
          pageSize: pageSize,
          encryptionTypeIndex: encTypeIndex,
          encoderConfig: encoderConfig,
          customKey: encryptionKey,
          customKeyId: encryptionKeyId,
          pages: List<BTreePageEncodeItem>.from(pending, growable: false),
          pageRedoTreeKindIndex:
              batchContext != null ? PageRedoTreeKind.indexTree.index : null,
          pageRedoTableUid: batchContext != null ? tableUid : null,
          pageRedoIndexUid: batchContext != null ? indexUid : null,
        );

        final bytesList = res.pageBytes;

        if (res.pageRedoBytes != null && batchContext != null) {
          final redoPath = _dataStore.pathManager.getPageRedoLogPath(
              batchContext.batchId,
              spaceName: _dataStore.currentSpaceName);
          await _storage.ensureDirectoryExists(p.dirname(redoPath));
          await _storage.appendBytes(redoPath, res.pageRedoBytes!, flush: true);
        }

        for (int i = 0; i < bytesList.length; i++) {
          final y3 = stageYc.maybeYield();
          if (y3 != null) await y3;
          final ptr = pendingPtrs[i];
          final stats = getStats(ptr.partitionNo);
          stats.path ??=
              await _partitionFilePath(table, indexUid, meta, ptr.partitionNo);
          if (!stats.dirEnsured) {
            await _storage.ensureDirectoryExists(p.dirname(stats.path!));
            stats.dirEnsured = true;
          }
          stageWrite(stats.path!, ptr.pageNo * pageSize, bytesList[i]);
        }

        pending.clear();
        pendingPtrs.clear();
      }

      while (dirtyLeaves.isNotEmpty) {
        final batch = Map<TreePagePtr, LeafPage>.from(dirtyLeaves);
        dirtyLeaves.clear();
        for (final entry in batch.entries) {
          final y4 = stageYc.maybeYield();
          if (y4 != null) await y4;
          final ptr = entry.key;
          final leaf = entry.value;
          final payloadLength = leaf.estimatePayloadSize();
          if (!payloadFitsInPage(payloadLength)) {
            final frames = <_IFrame>[];
            await descendToLeaf(
                leaf.keys.isEmpty ? leaf.highKey : leaf.keys.first, frames);
            final splitResult = leaf.split();
            final rightLeaf = splitResult.right;
            final rightLeafPtr = await allocatePage();
            rightLeaf.prev = ptr;
            rightLeaf.next = leaf.next;
            final oldNext = leaf.next;
            leaf.next = rightLeafPtr;
            if (!oldNext.isNull) {
              final nextLeaf = await getLeaf(oldNext);
              nextLeaf.prev = rightLeafPtr;
              markLeafDirty(oldNext, nextLeaf);
            } else {
              meta = meta.copyWith(btreeLastLeaf: rightLeafPtr);
            }
            await insertSplitIntoParents(
              frames,
              leftHighKey: leaf.highKey,
              leftPtr: ptr,
              rightHighKey: rightLeaf.highKey,
              rightPtr: rightLeafPtr,
            );
            leafCache[keyOfPtr(rightLeafPtr)] = rightLeaf;
            final leftPayload = leaf.encodePayload();
            final rightPayload = rightLeaf.encodePayload();
            if (!payloadFitsInPage(leftPayload.length) ||
                !payloadFitsInPage(rightPayload.length)) {
              throw DbException([
                GeneralStatus(
                  type: ResultType.engError,
                  message:
                      'Index $tableName.$indexLogName: page overflow after split '
                      '(single entry may exceed page capacity). '
                      'leftPayload=${leftPayload.length} rightPayload=${rightPayload.length} '
                      'pageSize=${_dataStore.configuredPageSize}',
                ),
              ]);
            }
            pendingPtrs.add(ptr);
            pending.add(BTreePageEncodeItem(
              typeIndex: BTreePageType.leaf.index,
              partitionNo: ptr.partitionNo,
              pageNo: ptr.pageNo,
              payload: leftPayload,
            ));
            targetLeafPages++;
            pendingPtrs.add(rightLeafPtr);
            pending.add(BTreePageEncodeItem(
              typeIndex: BTreePageType.leaf.index,
              partitionNo: rightLeafPtr.partitionNo,
              pageNo: rightLeafPtr.pageNo,
              payload: rightPayload,
            ));
            targetLeafPages++;
          } else {
            pendingPtrs.add(ptr);
            pending.add(BTreePageEncodeItem.leaf(
              partitionNo: ptr.partitionNo,
              pageNo: ptr.pageNo,
              page: leaf,
            ));
            targetLeafPages++;
          }
          if (pending.length >= chunkSize) {
            await flushEncodeChunk();
          }
        }
      }

      while (dirtyInternals.isNotEmpty) {
        final batch = Map<TreePagePtr, InternalPage>.from(dirtyInternals);
        dirtyInternals.clear();
        for (final entry in batch.entries) {
          final y5 = stageYc.maybeYield();
          if (y5 != null) await y5;
          final ptr = entry.key;
          final node = entry.value;
          final payloadLength = node.estimatePayloadSize();
          if (!payloadFitsInPage(payloadLength)) {
            final frames = <_IFrame>[];
            await descendToLeaf(
                node.maxKeys.isEmpty ? Uint8List(0) : node.maxKeys.first,
                frames);
            int selfFrameIndex = -1;
            for (int i = 0; i < frames.length; i++) {
              if (frames[i].ptr.partitionNo == ptr.partitionNo &&
                  frames[i].ptr.pageNo == ptr.pageNo) {
                selfFrameIndex = i;
                break;
              }
            }
            if (selfFrameIndex < 0) {
              throw DbException([
                GeneralStatus(
                  type: ResultType.engError,
                  message:
                      'Index $tableName.$indexLogName: internal ptr not found in descent frames',
                ),
              ]);
            }
            if (selfFrameIndex > 0) {
              frames.removeRange(selfFrameIndex, frames.length);
            } else {
              frames.clear();
            }
            final splitResult = node.split();
            final rightNode = splitResult.right;
            final rightNodePtr = await allocatePage();
            await insertSplitIntoParents(
              frames,
              leftHighKey: node.maxKey(),
              leftPtr: ptr,
              rightHighKey: rightNode.maxKey(),
              rightPtr: rightNodePtr,
            );
            internalCache[keyOfPtr(rightNodePtr)] = rightNode;
            final leftPayload = node.encodePayload();
            final rightPayload = rightNode.encodePayload();
            if (!payloadFitsInPage(leftPayload.length) ||
                !payloadFitsInPage(rightPayload.length)) {
              throw DbException([
                GeneralStatus(
                  type: ResultType.engError,
                  message:
                      'Index $tableName.$indexLogName: internal page overflow after split. '
                      'pageSize=${_dataStore.configuredPageSize}',
                ),
              ]);
            }
            pendingPtrs.add(ptr);
            pending.add(BTreePageEncodeItem(
              typeIndex: BTreePageType.internal.index,
              partitionNo: ptr.partitionNo,
              pageNo: ptr.pageNo,
              payload: leftPayload,
            ));
            targetInternalPages++;
            pendingPtrs.add(rightNodePtr);
            pending.add(BTreePageEncodeItem(
              typeIndex: BTreePageType.internal.index,
              partitionNo: rightNodePtr.partitionNo,
              pageNo: rightNodePtr.pageNo,
              payload: rightPayload,
            ));
            targetInternalPages++;
          } else {
            pendingPtrs.add(ptr);
            pending.add(BTreePageEncodeItem.internal(
              partitionNo: ptr.partitionNo,
              pageNo: ptr.pageNo,
              page: node,
            ));
            targetInternalPages++;
          }
          if (pending.length >= chunkSize) {
            await flushEncodeChunk();
          }
        }
      }

      await flushEncodeChunk();
    }

    // ---- Stage per-partition meta page (pageNo=0) and compute index total deltas ----
    int entriesDeltaSum = 0;
    int sizeDeltaSum = 0;
    final int pageSize = _dataStore.configuredPageSize;

    for (final entry in partitionStats.entries) {
      final y6 = yc.maybeYield();
      if (y6 != null) await y6;
      final pNo = entry.key;
      final stats = entry.value;

      stats.path ??= await _partitionFilePath(table, indexUid, meta, pNo);
      if (!stats.dirEnsured) {
        await _storage.ensureDirectoryExists(p.dirname(stats.path!));
        stats.dirEnsured = true;
      }

      if (!stats.headerLoaded) {
        try {
          final raw0 =
              await _storage.readAsBytesAt(stats.path!, 0, length: pageSize);
          if (raw0.isNotEmpty) {
            final local =
                _dataStore.treeMetaPageService.parsePartitionLocalFromPageBytes(
              raw0,
              partitionNo: pNo,
              pageType: BTreePageType.meta,
              encryptionKey: encryptionKey,
              encryptionKeyId: encryptionKeyId,
            );
            if (local != null) {
              stats.oldTotalEntries = local.totalEntryCount;
              stats.oldFileSizeInBytes = local.totalSizeBytes;
              stats.oldFreeListHeadPageNo = local.freeListHeadPageNo;
              stats.oldFreePageCount = local.freePageCount;
              stats.oldFlushBatchKey = local.lastFlushBatchKey;
              stats.oldMaintBatchKey = local.lastMaintenanceBatchKey;
              stats.freeListHeadPageNo = local.freeListHeadPageNo;
              stats.freePageCount = local.freePageCount;
              if (batchContext != null && batchContext.batchId.isNotEmpty) {
                stats.alreadyDurableForBatch = local.matchesBatchKey(
                  isMaintenance:
                      batchContext.batchType == BatchType.maintenance,
                  batchId: batchContext.batchId,
                );
              }
            } else {
              stats.oldFileSizeInBytes =
                  await _storage.getFileSize(stats.path!);
            }
          }
        } catch (_) {
          // Read failed (e.g. file lock or I/O error).
          // Fallback to file size to prevent double-counting delta.
          try {
            stats.oldFileSizeInBytes = await _storage.getFileSize(stats.path!);
          } catch (_) {}
        } finally {
          stats.headerLoaded = true;
        }
      }

      final int oldEntries = stats.oldTotalEntries;
      final int oldSize = stats.oldFileSizeInBytes;

      final int newEntries = max(0, oldEntries + stats.entriesDelta);
      // For active partition (latest), use btreeNextPageNo which tracks actual allocation.
      // For historical partitions, use maxPageNoWritten from current batch.
      // This prevents size miscalculation when old meta page read fails.
      final int computedSize;
      if (pNo == meta.btreePartitionCount - 1) {
        // Active partition: btreeNextPageNo is the authoritative page count
        computedSize = meta.btreeNextPageNo * pageSize;
      } else {
        // Historical partition: use batch-local max, but never shrink
        computedSize = (stats.maxPageNoWritten + 1) * pageSize;
      }
      final int newSize = max(oldSize, computedSize);

      if (pNo != 0) {
        if (!stats.alreadyDurableForBatch) {
          final metaBytes =
              _dataStore.treeMetaPageService.buildPartitionPage0Bytes(
            pageSize: pageSize,
            partitionNo: pNo,
            pageType: BTreePageType.meta,
            partitionLocal: PartitionLocalStats(
              partitionNo: pNo,
              totalEntryCount: newEntries,
              totalSizeBytes: newSize,
              freeListHeadPageNo: stats.freeListHeadPageNo,
              freePageCount: stats.freePageCount,
            ).withBatchMarkers(
              isMaintenance: batchContext?.batchType == BatchType.maintenance,
              batchId: batchContext?.batchId,
              preservedFlushKey: stats.oldFlushBatchKey,
              preservedMaintKey: stats.oldMaintBatchKey,
            ),
            encryptionKey: encryptionKey,
            encryptionKeyId: encryptionKeyId,
          );
          stageWrite(stats.path!, 0, metaBytes);
        }
      }

      // IMPORTANT: global totals delta must not depend on reading old partition meta page
      // (may be corrupted during crash tests). Use batch-local delta (idempotent).
      final int partitionEntriesDelta = stats.entriesDelta;
      final int partitionSizeDelta = newSize - oldSize;
      entriesDeltaSum += partitionEntriesDelta;
      sizeDeltaSum += partitionSizeDelta;
    }

    final now = DateTime.now();
    final updatedMeta = meta.copyWith(
      totalEntryCount: max(0, meta.totalEntryCount + entriesDeltaSum),
      totalSizeBytes: max(0, meta.totalSizeBytes + sizeDeltaSum),
      timestamps: Timestamps(created: meta.timestamps.created, modified: now),
    );
    _dataStore.tableDataManager.applyIndexOccupancyDelta(
      table,
      sizeDelta: sizeDeltaSum,
      entryDelta: entriesDeltaSum,
    );

    // Partition 0 page 0 carries index-global metadata + local partition stats.
    // Local size must use the same rule as the loop above: btreeNextPageNo only
    // applies when partition 0 is the active (last) partition.
    {
      final p0Stats = getStats(0);
      p0Stats.path ??=
          await _partitionFilePath(table, indexUid, updatedMeta, 0);
      if (!p0Stats.dirEnsured) {
        await _storage.ensureDirectoryExists(p.dirname(p0Stats.path!));
        p0Stats.dirEnsured = true;
      }
      if (!p0Stats.headerLoaded) {
        try {
          final raw0 =
              await _storage.readAsBytesAt(p0Stats.path!, 0, length: pageSize);
          if (raw0.isNotEmpty) {
            final local =
                _dataStore.treeMetaPageService.parsePartitionLocalFromPageBytes(
              raw0,
              partitionNo: 0,
              pageType: BTreePageType.meta,
              encryptionKey: encryptionKey,
              encryptionKeyId: encryptionKeyId,
            );
            if (local != null) {
              p0Stats.oldTotalEntries = local.totalEntryCount;
              p0Stats.oldFileSizeInBytes = local.totalSizeBytes;
              p0Stats.oldFreeListHeadPageNo = local.freeListHeadPageNo;
              p0Stats.oldFreePageCount = local.freePageCount;
              p0Stats.oldFlushBatchKey = local.lastFlushBatchKey;
              p0Stats.oldMaintBatchKey = local.lastMaintenanceBatchKey;
              p0Stats.freeListHeadPageNo = local.freeListHeadPageNo;
              p0Stats.freePageCount = local.freePageCount;
              if (batchContext != null && batchContext.batchId.isNotEmpty) {
                p0Stats.alreadyDurableForBatch = local.matchesBatchKey(
                  isMaintenance:
                      batchContext.batchType == BatchType.maintenance,
                  batchId: batchContext.batchId,
                );
              }
            }
          }
        } catch (_) {}
        p0Stats.headerLoaded = true;
      }
      final int p0NewEntries =
          max(0, p0Stats.oldTotalEntries + p0Stats.entriesDelta);
      final int p0ComputedSize;
      if (updatedMeta.btreePartitionCount <= 1) {
        p0ComputedSize = updatedMeta.btreeNextPageNo * pageSize;
      } else {
        p0ComputedSize = p0Stats.maxPageNoWritten > 0
            ? (p0Stats.maxPageNoWritten + 1) * pageSize
            : p0Stats.oldFileSizeInBytes;
      }
      final int p0NewSize = max(p0Stats.oldFileSizeInBytes, p0ComputedSize);
      final globalBlob = TreeGlobalMetaBlobCodec.encode(
        TreeGlobalMetaKind.indexTree,
        IndexMetaCodec.encode(updatedMeta),
      );
      // Same recovery rule as table writeChanges: prior-marked siblings mean we
      // must rewrite p0 global totals after a base-totals rollback.
      if (partitionStats.values.any((s) => s.alreadyDurableForBatch)) {
        p0Stats.alreadyDurableForBatch = false;
      }
      if (!p0Stats.alreadyDurableForBatch) {
        final p0Bytes = _dataStore.treeMetaPageService.buildPartitionPage0Bytes(
          pageSize: pageSize,
          partitionNo: 0,
          pageType: BTreePageType.meta,
          partitionLocal: PartitionLocalStats(
            partitionNo: 0,
            totalEntryCount: p0NewEntries,
            totalSizeBytes: p0NewSize,
            freeListHeadPageNo: p0Stats.freeListHeadPageNo,
            freePageCount: p0Stats.freePageCount,
          ).withBatchMarkers(
            isMaintenance: batchContext?.batchType == BatchType.maintenance,
            batchId: batchContext?.batchId,
            preservedFlushKey: p0Stats.oldFlushBatchKey,
            preservedMaintKey: p0Stats.oldMaintBatchKey,
          ),
          treeGlobalMeta: globalBlob,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
        );
        stageWrite(p0Stats.path!, 0, p0Bytes);

        if (batchContext != null) {
          final redoPath = _dataStore.pathManager.getPageRedoLogPath(
            batchContext.batchId,
            spaceName: _dataStore.currentSpaceName,
          );
          await _storage.ensureDirectoryExists(p.dirname(redoPath));
          final rec = PageRedoLogCodec.encodePageRecord(
            treeKind: PageRedoTreeKind.indexTree,
            tableUid: table.tableUid,
            indexUid: indexUid,
            partitionNo: 0,
            pageNo: 0,
            payload: p0Bytes,
          );
          await _storage.appendBytes(redoPath, rec, flush: true);
        }
      }
    }

    // Flush staged random writes per file.
    if (staged.isNotEmpty) {
      final flushYc = YieldController(
        'IndexTreePartitionManager.writeChanges.flushFiles',
        checkInterval: 20,
      );

      final tasks = <Future<void> Function()>[];
      for (final e in staged.entries) {
        final y7 = flushYc.maybeYield();
        if (y7 != null) await y7;
        final path = e.key;
        final durable = partitionStats.values
            .any((s) => s.path == path && s.alreadyDurableForBatch);
        if (durable) continue;
        final offsets = e.value.keys.toList(growable: false)..sort();
        final writes = <ByteWrite>[
          for (final off in offsets)
            ByteWrite(offset: off, bytes: e.value[off]!),
        ];
        tasks.add(() async {
          await _storage.writeManyAsBytesAt(path, writes, flush: false);
        });
      }

      if (tasks.isNotEmpty) {
        final scheduler = _dataStore.workloadScheduler;
        if (scheduler.globalMax <= 0 || tasks.length <= 1) {
          for (final t in tasks) {
            final y8 = flushYc.maybeYield();
            if (y8 != null) await y8;
            await t();
          }
        } else {
          final workloadType =
              (batchContext?.batchType == BatchType.maintenance)
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
                  'IndexTreePartitionManager.writeChanges($tableName.$indexLogName)',
            );

            final int ioConcurrency = min(tasks.length, max(1, lease.tokens));
            await ParallelProcessor.execute<void>(
              tasks,
              concurrency: ioConcurrency,
              label: 'IndexTreePartitionManager.writeChanges.flush',
              continueOnError: false,
            );
          } finally {
            lease?.release();
          }
        }
      }
    }

    // Atomically update IndexMeta with corrected totals and B+Tree pointers.
    final indexManager = _dataStore.indexManager;
    if (indexManager != null) {
      await indexManager.mutateIndexMeta(
        table,
        indexUid,
        (_) => updatedMeta,
        flush: false,
        persistToDisk: false,
        batchContext: batchContext,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
      );
    }

    // Log persistence statistics
    if (InternalConfig.showLoggerInternalLabel && totalDeltas > 0) {
      final now = DateTime.now();
      final at =
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${now.millisecond.toString().padLeft(3, '0')}';
      final totalEntryCount = max(0, meta.totalEntryCount + entriesDeltaSum);
      final totalSize = max(0, meta.totalSizeBytes + sizeDeltaSum);
      final targetPages = targetLeafPages + targetInternalPages;
      Logger.debug(
          'Index persistence: table=$tableName, partitions=${meta.btreePartitionCount}, index=$indexLogName, batchEntries=$totalDeltas, targetPages=$targetPages (leaves=$targetLeafPages, internals=$targetInternalPages), totalEntryCount=$totalEntryCount, totalSize=${(totalSize / 1024 / 1024).toStringAsFixed(2)}MB, concurrency=${concurrency ?? 1}, cost=${sw.elapsedMilliseconds}ms, at: $at');
    }
  }

  /// Background compaction: scan leaf chain and merge underfull adjacent siblings.
  /// Returns next cursor, or null when finished for now.
  Future<TreePagePtr?> compactLeafChain({
    required TableContext table,
    required IndexUid indexUid,
    TreePagePtr? startFrom,
    required int maxVisitedLeaves,
    required int maxMerges,
    BatchContext? batchContext,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    final meta0 =
        await _dataStore.indexManager?.getIndexMeta(table.tableUid, indexUid);
    if (meta0 == null || meta0.btreeFirstLeaf.isNull) return null;
    var meta = meta0;
    if (maxVisitedLeaves <= 0 || maxMerges <= 0) return startFrom;

    TreePagePtr ptr = startFrom ?? meta.btreeFirstLeaf;
    if (ptr.isNull) return null;

    final staged = <String, Map<int, Uint8List>>{};
    final partitionStats = <int, _IndexPartitionStats>{};

    _IndexPartitionStats getStats(int pNo) =>
        partitionStats.putIfAbsent(pNo, () => _IndexPartitionStats());

    void stageWrite(String path, int offset, Uint8List bytes) {
      staged.putIfAbsent(path, () => <int, Uint8List>{})[offset] = bytes;
    }

    Future<void> ensureHeaderLoaded(int pNo) async {
      final s = getStats(pNo);
      if (s.headerLoaded) return;
      s.path ??= await _partitionFilePath(table, indexUid, meta, pNo);
      try {
        final raw0 = await _storage.readAsBytesAt(s.path!, 0,
            length: _dataStore.configuredPageSize);
        if (raw0.isNotEmpty) {
          final local =
              _dataStore.treeMetaPageService.parsePartitionLocalFromPageBytes(
            raw0,
            partitionNo: pNo,
            pageType: BTreePageType.meta,
            encryptionKey: encryptionKey,
            encryptionKeyId: encryptionKeyId,
          );
          if (local != null) {
            s.oldFileSizeInBytes = local.totalSizeBytes;
            s.oldTotalEntries = local.totalEntryCount;
            s.oldFlushBatchKey = local.lastFlushBatchKey;
            s.oldMaintBatchKey = local.lastMaintenanceBatchKey;
            s.freeListHeadPageNo = local.freeListHeadPageNo;
            s.freePageCount = local.freePageCount;
          }
        }
      } catch (_) {
      } finally {
        s.headerLoaded = true;
      }
    }

    Future<void> pushFree(TreePagePtr pagePtr) async {
      if (pagePtr.pageNo <= 0) return;
      await ensureHeaderLoaded(pagePtr.partitionNo);
      final s = getStats(pagePtr.partitionNo);
      s.path ??=
          await _partitionFilePath(table, indexUid, meta, pagePtr.partitionNo);
      if (!s.dirEnsured) {
        await _storage.ensureDirectoryExists(p.dirname(s.path!));
        s.dirEnsured = true;
      }
      final next = s.freeListHeadPageNo;
      final freeBytes = BTreePageIO.buildPageBytes(
        type: BTreePageType.free,
        encodedPayload: FreePage(nextFreePageNo: next).encodePayload(),
        pageSize: _dataStore.configuredPageSize,
      );
      stageWrite(
          s.path!, pagePtr.pageNo * _dataStore.configuredPageSize, freeBytes);
      s.freeListHeadPageNo = pagePtr.pageNo;
      s.freePageCount = s.freePageCount + 1;
      s.maxPageNoWritten = max(s.maxPageNoWritten, pagePtr.pageNo);
    }

    Uint8List encodeLeaf(TreePagePtr p, LeafPage leaf) {
      final plain = leaf.encodePayload();
      final enc = BTreePageCodec.encodePayload(
        plain,
        config: _dataStore.config,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        aad: _aad(p, BTreePageType.leaf),
      );
      return BTreePageIO.buildPageBytes(
        type: BTreePageType.leaf,
        encodedPayload: enc,
        pageSize: _dataStore.configuredPageSize,
      );
    }

    Uint8List encodeInternal(TreePagePtr p, InternalPage node) {
      final plain = node.encodePayload();
      final enc = BTreePageCodec.encodePayload(
        plain,
        config: _dataStore.config,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        aad: _aad(p, BTreePageType.internal),
      );
      return BTreePageIO.buildPageBytes(
        type: BTreePageType.internal,
        encodedPayload: enc,
        pageSize: _dataStore.configuredPageSize,
      );
    }

    bool underfull(LeafPage leaf) {
      if (leaf.keys.isEmpty) return false;
      final used = leaf.estimatePayloadSize();
      return used > 0 && used < (_dataStore.configuredPageSize * 0.25).floor();
    }

    Future<TreePagePtr> descendToLeaf(
        Uint8List key, List<_IFrame> frames) async {
      if (meta.btreeHeight <= 0) return meta.btreeRoot;
      TreePagePtr cur = meta.btreeRoot;
      for (int depth = meta.btreeHeight; depth > 0; depth--) {
        final node = await _readInternal(table, indexUid, meta, cur,
            encryptionKey: encryptionKey, encryptionKeyId: encryptionKeyId);
        if (node.children.isEmpty) return meta.btreeFirstLeaf;
        final idx = node.childIndexForKey(key);
        frames.add(_IFrame(ptr: cur, node: node, childIndex: idx));
        cur = node.children[idx];
      }
      return cur;
    }

    int visited = 0;
    int merged = 0;
    final yc = YieldController('IndexTreePartitionManager.compactLeafChain',
        checkInterval: 30);

    while (!ptr.isNull && visited < maxVisitedLeaves && merged < maxMerges) {
      final y9 = yc.maybeYield();
      if (y9 != null) await y9;
      final leaf = await _readLeaf(table, indexUid, meta, ptr,
          encryptionKey: encryptionKey, encryptionKeyId: encryptionKeyId);
      visited++;
      if (leaf.keys.isEmpty) {
        ptr = leaf.next;
        continue;
      }
      if (!underfull(leaf)) {
        ptr = leaf.next;
        continue;
      }

      final frames = <_IFrame>[];
      final located = await descendToLeaf(leaf.keys.first, frames);
      if (located != ptr || frames.isEmpty) {
        ptr = leaf.next;
        continue;
      }

      final parentFrame = frames.last;
      final parent = parentFrame.node;
      final i = parentFrame.childIndex;
      if (i + 1 >= parent.children.length) {
        ptr = leaf.next;
        continue;
      }
      final rightPtr = parent.children[i + 1];
      if (rightPtr.isNull) {
        ptr = leaf.next;
        continue;
      }
      final right = await _readLeaf(table, indexUid, meta, rightPtr,
          encryptionKey: encryptionKey, encryptionKeyId: encryptionKeyId);
      if (right.keys.isEmpty) {
        ptr = leaf.next;
        continue;
      }

      final mergedLeaf = LeafPage(
        prev: leaf.prev,
        next: right.next,
        highKey: right.highKey,
        keys: <Uint8List>[...leaf.keys, ...right.keys],
        values: <Uint8List>[...leaf.values, ...right.values],
      );
      if (!BTreePageSizer.fitsInPage(
        pageSize: _dataStore.configuredPageSize,
        plainPayloadLen: mergedLeaf.estimatePayloadSize(),
        config: _dataStore.config,
        encryptionKeyId: encryptionKeyId,
      )) {
        ptr = leaf.next;
        continue;
      }

      leaf.keys.addAll(right.keys);
      leaf.values.addAll(right.values);
      leaf.highKey = right.highKey;
      final oldRightNext = right.next;
      leaf.next = oldRightNext;
      if (!oldRightNext.isNull) {
        final nextLeaf = await _readLeaf(table, indexUid, meta, oldRightNext,
            encryptionKey: encryptionKey, encryptionKeyId: encryptionKeyId);
        nextLeaf.prev = ptr;
        final pth = await _partitionFilePath(
            table, indexUid, meta, oldRightNext.partitionNo);
        stageWrite(pth, oldRightNext.pageNo * _dataStore.configuredPageSize,
            encodeLeaf(oldRightNext, nextLeaf));
      }

      parent.setEntry(i, leaf.highKey, ptr);
      parent.maxKeys.removeAt(i + 1);
      parent.children.removeAt(i + 1);

      var newRootPtr = meta.btreeRoot;
      var newHeight = meta.btreeHeight;
      if (parentFrame.ptr == meta.btreeRoot &&
          meta.btreeHeight == 1 &&
          parent.children.length == 1) {
        newRootPtr = parent.children.first;
        newHeight = 0;
        await pushFree(parentFrame.ptr);
      } else {
        final parentPath = await _partitionFilePath(
            table, indexUid, meta, parentFrame.ptr.partitionNo);
        stageWrite(
            parentPath,
            parentFrame.ptr.pageNo * _dataStore.configuredPageSize,
            encodeInternal(parentFrame.ptr, parent));
      }

      final leftPath =
          await _partitionFilePath(table, indexUid, meta, ptr.partitionNo);
      stageWrite(leftPath, ptr.pageNo * _dataStore.configuredPageSize,
          encodeLeaf(ptr, leaf));
      await pushFree(rightPtr);

      if (meta.btreeLastLeaf == rightPtr) {
        meta = meta.copyWith(btreeLastLeaf: ptr);
      }
      meta = meta.copyWith(btreeRoot: newRootPtr, btreeHeight: newHeight);

      merged++;
      ptr = leaf.next;
    }

    if (partitionStats.isNotEmpty) {
      for (final e in partitionStats.entries) {
        final pNo = e.key;
        final s = e.value;
        s.path ??= await _partitionFilePath(table, indexUid, meta, pNo);
        if (!s.dirEnsured) {
          await _storage.ensureDirectoryExists(p.dirname(s.path!));
          s.dirEnsured = true;
        }
        int actualSize = 0;
        try {
          actualSize = await _storage.getFileSize(s.path!);
        } catch (_) {
          actualSize = 0;
        }
        final newSize = max(s.oldFileSizeInBytes, actualSize);
        final local = PartitionLocalStats(
          partitionNo: pNo,
          totalEntryCount: s.oldTotalEntries,
          totalSizeBytes: newSize,
          freeListHeadPageNo: s.freeListHeadPageNo,
          freePageCount: s.freePageCount,
        ).withBatchMarkers(
          isMaintenance: batchContext?.batchType == BatchType.maintenance,
          batchId: batchContext?.batchId,
          preservedFlushKey: s.oldFlushBatchKey,
          preservedMaintKey: s.oldMaintBatchKey,
        );
        if (pNo == 0) {
          final globalBlob = TreeGlobalMetaBlobCodec.encode(
            TreeGlobalMetaKind.indexTree,
            IndexMetaCodec.encode(meta),
          );
          stageWrite(
            s.path!,
            0,
            _dataStore.treeMetaPageService.buildPartitionPage0Bytes(
              pageSize: _dataStore.configuredPageSize,
              partitionNo: 0,
              pageType: BTreePageType.meta,
              partitionLocal: local,
              treeGlobalMeta: globalBlob,
              encryptionKey: encryptionKey,
              encryptionKeyId: encryptionKeyId,
            ),
          );
        } else {
          stageWrite(
            s.path!,
            0,
            _dataStore.treeMetaPageService.buildPartitionPage0Bytes(
              pageSize: _dataStore.configuredPageSize,
              partitionNo: pNo,
              pageType: BTreePageType.meta,
              partitionLocal: local,
              encryptionKey: encryptionKey,
              encryptionKeyId: encryptionKeyId,
            ),
          );
        }
      }
    }

    for (final e in staged.entries) {
      final path = e.key;
      final offsets = e.value.keys.toList(growable: false)..sort();
      final writes = <ByteWrite>[
        for (final off in offsets) ByteWrite(offset: off, bytes: e.value[off]!),
      ];
      await _storage.writeManyAsBytesAt(path, writes, flush: false);
    }

    final compactedMeta = meta.copyWith(
      timestamps: Timestamps(
          created: meta.timestamps.created, modified: DateTime.now()),
    );
    await _dataStore.indexManager?.mutateIndexMeta(
      table,
      indexUid,
      (_) => compactedMeta,
      flush: false,
      persistToDisk: false,
    );

    if (merged == 0) return null;
    return ptr.isNull ? null : ptr;
  }

  IndexUid _effectiveIndexUid(IndexUid indexUid, IndexMeta meta) {
    return meta.indexUid.isNotEmpty ? meta.indexUid : indexUid;
  }

  /// Point lookup for unique index key. Returns PK string if exists.
  Future<String?> lookupUniquePrimaryKey({
    required TableContext table,
    required IndexUid indexUid,
    required IndexMeta meta,
    required Uint8List uniqueKey,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool readFromFileOnly = false,
  }) async {
    final resolvedUid = _effectiveIndexUid(indexUid, meta);
    final firstLeaf = meta.btreeFirstLeaf;
    if (firstLeaf.isNull) return null;
    var leafPtr = await _locateLeafForKey(
      table,
      resolvedUid,
      meta,
      uniqueKey,
      encryptionKey: encryptionKey,
      encryptionKeyId: encryptionKeyId,
      readFromFileOnly: readFromFileOnly,
    );
    if (leafPtr.isNull) leafPtr = firstLeaf;
    final leaf = await _readLeaf(table, resolvedUid, meta, leafPtr,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        readFromFileOnly: readFromFileOnly);
    final idx = leaf.find(uniqueKey);
    if (idx == null) return null;
    final v = leaf.values[idx];
    if (v.isEmpty || v[0] != 0) return null;
    if (v.length <= 1) return null;
    try {
      final pk = utf8.decode(v.sublist(1), allowMalformed: true);
      return pk;
    } catch (_) {
      return null;
    }
  }

  /// Batch lookup PKs for unique index keys. Returns one PK per key (null if not found).
  /// Groups by leaf to minimize leaf reads; tree descent is still per-key.
  Future<List<String?>> lookupUniquePrimaryKeysBatch({
    required TableContext table,
    required IndexUid indexUid,
    required IndexMeta meta,
    required List<Uint8List> uniqueKeys,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool readFromFileOnly = false,
  }) async {
    final resolvedUid = _effectiveIndexUid(indexUid, meta);
    if (uniqueKeys.isEmpty) return const [];
    final firstLeaf = meta.btreeFirstLeaf;
    if (firstLeaf.isNull) {
      return List<String?>.filled(uniqueKeys.length, null, growable: false);
    }
    final leafPtrToKeyIndices = <String, List<int>>{};
    for (int i = 0; i < uniqueKeys.length; i++) {
      var leafPtr = await _locateLeafForKey(
        table,
        resolvedUid,
        meta,
        uniqueKeys[i],
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        readFromFileOnly: readFromFileOnly,
      );
      if (leafPtr.isNull) leafPtr = firstLeaf;
      leafPtrToKeyIndices.putIfAbsent(keyOfPtr(leafPtr), () => <int>[]).add(i);
    }
    final result =
        List<String?>.filled(uniqueKeys.length, null, growable: false);
    for (final entry in leafPtrToKeyIndices.entries) {
      final parts = entry.key.split(':');
      final ptr = TreePagePtr(int.parse(parts[0]), int.parse(parts[1]));
      final leaf = await _readLeaf(table, resolvedUid, meta, ptr,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
          readFromFileOnly: readFromFileOnly);
      for (final idx in entry.value) {
        final key = uniqueKeys[idx];
        final slot = leaf.find(key);
        if (slot == null) continue;
        final v = leaf.values[slot];
        if (v.isEmpty || v[0] != 0 || v.length <= 1) continue;
        try {
          result[idx] = utf8.decode(v.sublist(1), allowMalformed: true);
        } catch (_) {}
      }
    }
    return result;
  }

  /// Batch existence check for unique keys (bool per key).
  Future<List<bool>> existsUniqueKeysBatch({
    required TableContext table,
    required IndexUid indexUid,
    required IndexMeta meta,
    required List<Uint8List> uniqueKeys,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    final resolvedUid = _effectiveIndexUid(indexUid, meta);
    if (uniqueKeys.isEmpty) return const <bool>[];
    final firstLeaf = meta.btreeFirstLeaf;
    if (firstLeaf.isNull) {
      return List<bool>.filled(uniqueKeys.length, false, growable: false);
    }

    // Group by leaf to reduce IO.
    final leafToKeys = <String, List<int>>{};
    for (int i = 0; i < uniqueKeys.length; i++) {
      final k = uniqueKeys[i];
      final ptr = await _locateLeafForKey(
        table,
        resolvedUid,
        meta,
        k,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
      );
      final use = ptr.isNull ? firstLeaf : ptr;
      leafToKeys
          .putIfAbsent('${use.partitionNo}:${use.pageNo}', () => <int>[])
          .add(i);
    }

    final out = List<bool>.filled(uniqueKeys.length, false, growable: false);
    final yc = YieldController(
        'IndexTreePartitionManager.existsUniqueKeysBatch',
        checkInterval: 200);
    for (final e in leafToKeys.entries) {
      final y10 = yc.maybeYield();
      if (y10 != null) await y10;
      final parts = e.key.split(':');
      final ptr = TreePagePtr(int.parse(parts[0]), int.parse(parts[1]));
      final leaf = await _readLeaf(table, resolvedUid, meta, ptr,
          encryptionKey: encryptionKey, encryptionKeyId: encryptionKeyId);
      for (final idx in e.value) {
        final key = uniqueKeys[idx];
        out[idx] = leaf.find(key) != null;
      }
    }
    return out;
  }

  /// Range scan over index keys; returns primary keys.
  ///
  /// For non-unique indexes, PK is encoded as last component of key bytes.
  /// For unique indexes, PK is stored in value bytes.
  Future<IndexSearchResult> searchByKeyRange({
    required TableContext table,
    required IndexUid indexUid,
    required IndexMeta meta,
    required Uint8List startKeyInclusive,
    required Uint8List endKeyExclusive,
    bool reverse = false,
    int? limit,
    int? offset,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool readFromFileOnly = false,
  }) async {
    final resolvedUid = _effectiveIndexUid(indexUid, meta);
    final firstLeaf = meta.btreeFirstLeaf;
    if (firstLeaf.isNull) return IndexSearchResult.empty();

    int effectiveOffset = offset ?? 0;
    int remaining = (limit == null || limit <= 0) ? 1 << 30 : limit;
    final out = <String>[];
    final entriesOut = <IndexSearchEntry>[];
    Uint8List? lastKey;

    TreePagePtr leafPtr;
    if (reverse) {
      if (endKeyExclusive.isNotEmpty) {
        // Reverse scan with upper bound (or cursor): start near the upper bound.
        leafPtr = await _locateLeafForKey(
          table,
          resolvedUid,
          meta,
          endKeyExclusive,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
          readFromFileOnly: readFromFileOnly,
        );
      } else {
        // Reverse scan from end (Infinity).
        // Fast path: trust meta.btreeLastLeaf when it still points to the
        // boundary leaf, and fall back to a full right-edge descent otherwise.
        leafPtr = await _locateRightmostLeafFast(
          table,
          resolvedUid,
          meta,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
          readFromFileOnly: readFromFileOnly,
        );
      }
    } else {
      // Forward scan: start at lower bound.
      leafPtr = await _locateLeafForKey(
        table,
        resolvedUid,
        meta,
        startKeyInclusive,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        readFromFileOnly: readFromFileOnly,
      );
    }

    if (leafPtr.isNull) leafPtr = firstLeaf;

    final yc = YieldController('IndexTreePartitionManager.searchByKeyRange',
        checkInterval: 50);

    // One-step prefetch for the next leaf page in the chain to pipeline IO.
    final Map<String, Future<LeafPage>> prefetched =
        <String, Future<LeafPage>>{};
    Future<LeafPage> getLeaf(TreePagePtr p) {
      final k = keyOfPtr(p);
      final f = prefetched.remove(k);
      if (f != null) return f;
      return _readLeaf(
        table,
        resolvedUid,
        meta,
        p,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        readFromFileOnly: readFromFileOnly,
      );
    }

    void schedulePrefetch(TreePagePtr p) {
      if (p.isNull) return;
      if (_dataStore.shouldAbortBackgroundScan) return;
      if (prefetched.isNotEmpty) return;
      final k = keyOfPtr(p);
      prefetched[k] = _readLeaf(
        table,
        resolvedUid,
        meta,
        p,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        readFromFileOnly: readFromFileOnly,
      );
    }

    Future<void> drainPrefetch() async {
      if (prefetched.isEmpty) return;
      final pending = prefetched.values.toList(growable: false);
      prefetched.clear();
      for (final f in pending) {
        try {
          await f;
        } catch (_) {}
      }
    }

    while (!leafPtr.isNull && remaining > 0) {
      if (_dataStore.shouldAbortBackgroundScan) {
        await drainPrefetch();
        return IndexSearchResult(
          primaryKeys: out,
          entries: entriesOut.isEmpty ? null : entriesOut,
          lastKey: lastKey,
        );
      }
      final y11 = yc.maybeYield();
      if (y11 != null) await y11;
      final leaf = await getLeaf(leafPtr);
      if (leaf.keys.isEmpty) {
        leafPtr = reverse ? leaf.prev : leaf.next;
        continue;
      }

      schedulePrefetch(reverse ? leaf.prev : leaf.next);

      // Determine scan direction and starting position in leaf.
      int i;
      if (!reverse) {
        i = 0;
        // lowerBound for startKeyInclusive
        int lo = 0, hi = leaf.keys.length;
        while (lo < hi) {
          final mid = (lo + hi) >> 1;
          if (MemComparableKey.compare(leaf.keys[mid], startKeyInclusive) < 0) {
            lo = mid + 1;
          } else {
            hi = mid;
          }
        }
        i = lo;
        for (; i < leaf.keys.length && remaining > 0; i++) {
          final k = leaf.keys[i];
          if (endKeyExclusive.isNotEmpty &&
              MemComparableKey.compare(k, endKeyExclusive) >= 0) {
            return IndexSearchResult(primaryKeys: out, lastKey: lastKey);
          }
          if (effectiveOffset > 0) {
            effectiveOffset--;
            continue;
          }
          final pk = _extractPk(meta, k, leaf.values[i]);
          if (pk != null) {
            final keyCopy = Uint8List.fromList(k);
            out.add(pk);
            entriesOut.add(IndexSearchEntry(primaryKey: pk, keyBytes: keyCopy));
            lastKey = keyCopy;
            remaining--;
          }
        }
        leafPtr = leaf.next;
      } else {
        i = leaf.keys.length - 1;
        for (; i >= 0 && remaining > 0; i--) {
          final k = leaf.keys[i];
          if (MemComparableKey.compare(k, startKeyInclusive) < 0) {
            return IndexSearchResult(primaryKeys: out, lastKey: lastKey);
          }
          if (endKeyExclusive.isNotEmpty &&
              MemComparableKey.compare(k, endKeyExclusive) >= 0) {
            continue;
          }
          if (effectiveOffset > 0) {
            effectiveOffset--;
            continue;
          }
          final pk = _extractPk(meta, k, leaf.values[i]);
          if (pk != null) {
            final keyCopy = Uint8List.fromList(k);
            out.add(pk);
            entriesOut.add(IndexSearchEntry(primaryKey: pk, keyBytes: keyCopy));
            lastKey = keyCopy;
            remaining--;
          }
        }
        leafPtr = leaf.prev;
      }
    }

    return IndexSearchResult(
      primaryKeys: out,
      entries: entriesOut.isEmpty ? null : entriesOut,
      lastKey: lastKey,
    );
  }

  String? _extractPk(IndexMeta meta, Uint8List key, Uint8List value) {
    if (meta.isUnique) {
      if (value.isEmpty || value[0] != 0) return null;
      if (value.length <= 1) return null;
      try {
        return utf8.decode(value.sublist(1), allowMalformed: true);
      } catch (_) {
        return null;
      }
    }
    final res = MemComparableKey.splitLastComponent(key);
    return res.lastText;
  }

  /// Decode all index entries in key order for full-cache prewarming.
  ///
  /// WARNING: This is inherently a full scan; only used when user explicitly
  /// calls `IndexManager.prewarmIndexDataCache`.
  Future<List<DecodedIndexEntry>> getAllDecodedEntries({
    required TableContext table,
    required IndexUid indexUid,
    required IndexMeta meta,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    final resolvedUid = _effectiveIndexUid(indexUid, meta);
    final firstLeaf = meta.btreeFirstLeaf;
    if (firstLeaf.isNull) return const <DecodedIndexEntry>[];

    final out = <DecodedIndexEntry>[];
    var ptr = firstLeaf;
    final yc = YieldController('IndexTreePartitionManager.getAllDecodedEntries',
        checkInterval: 50);
    while (!ptr.isNull) {
      final y12 = yc.maybeYield();
      if (y12 != null) await y12;
      final leaf = await _readLeaf(table, resolvedUid, meta, ptr,
          encryptionKey: encryptionKey, encryptionKeyId: encryptionKeyId);
      for (int i = 0; i < leaf.keys.length; i++) {
        final y13 = yc.maybeYield();
        if (y13 != null) await y13;
        final k = leaf.keys[i];
        final v = leaf.values[i];
        final pk = _extractPk(meta, k, v);
        if (pk == null || pk.isEmpty) continue;
        final comps = MemComparableKey.decodeTuple(k);
        if (comps.isEmpty) continue;
        // Non-unique: last component is PK; strip it from key components.
        final keyComps =
            meta.isUnique ? comps : comps.sublist(0, comps.length - 1);
        out.add(DecodedIndexEntry(keyComponents: keyComps, pk: pk));
      }
      ptr = leaf.next;
    }
    return out;
  }
}

final class DecodedIndexEntry {
  final List<Object?> keyComponents;
  final String pk;
  const DecodedIndexEntry({required this.keyComponents, required this.pk});
}

/// Tracks per-partition statistics during batch write.
final class _IndexPartitionStats {
  String? path;
  bool dirEnsured = false;
  int entriesDelta = 0;
  int maxPageNoWritten = 0;

  // Loaded from PartitionMetaPage (pageNo=0) when available.
  bool headerLoaded = false;
  int oldTotalEntries = 0;
  int oldFileSizeInBytes = 0;
  int oldFlushBatchKey = 0;
  int oldMaintBatchKey = 0;
  bool alreadyDurableForBatch = false;

  // Freelist state (per-partition).
  int oldFreeListHeadPageNo = -1;
  int oldFreePageCount = 0;
  int freeListHeadPageNo = -1;
  int freePageCount = 0;
}

final class _IFrame {
  final TreePagePtr ptr;
  final InternalPage node;
  final int childIndex;
  _IFrame({required this.ptr, required this.node, required this.childIndex});
}
