import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../Interface/storage_interface.dart';
import '../handler/parallel_processor.dart';
import '../handler/logger.dart';
import '../handler/common.dart';
import '../handler/memcomparable.dart';
import '../handler/encoder.dart';
import '../model/data_block_entry.dart';
import '../model/data_store_config.dart';
import '../model/encoder_config.dart';
import '../model/meta_info.dart';
import '../model/index_search.dart';
import '../model/parallel_journal_entry.dart';
import 'data_store_impl.dart';
import 'storage_adapter.dart';
import 'btree_page.dart';
import 'compute_tasks.dart';
import 'compute_manager.dart';
import 'yield_controller.dart';
import 'workload_scheduler.dart';
import 'tree_cache.dart';

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
  // Key format: [tableName, indexName, partitionNo, pageNo]
  // This cache significantly reduces IO reads for frequently accessed pages,
  // especially internal nodes which are shared across many queries.
  late final TreeCache<LeafPage> _leafPageCache;
  late final TreeCache<InternalPage> _internalPageCache;

  IndexTreePartitionManager(this._dataStore) {
    // Initialize page caches using memory manager quota
    final memoryManager = _dataStore.memoryManager;
    final indexQuota =
        memoryManager?.getIndexCacheSize() ?? (128 * 1024 * 1024);
    // Allocate 30% of index cache for B+Tree pages (15% for leaf, 15% for internal)
    final int pageCacheSize = (indexQuota * 0.30).toInt();
    final int leafCacheSize = (pageCacheSize * 0.50).toInt();
    final int internalCacheSize = pageCacheSize - leafCacheSize;

    _leafPageCache = TreeCache<LeafPage>(
      sizeCalculator: _estimateLeafPageSize,
      maxByteThreshold: leafCacheSize,
      minByteThreshold: 50 * 1024 * 1024, // 50MB minimum
      groupDepth: 2, // Group by [tableName, indexName]
      debugLabel: 'IndexLeafPageCache',
    );

    _internalPageCache = TreeCache<InternalPage>(
      sizeCalculator: _estimateInternalPageSize,
      maxByteThreshold: internalCacheSize,
      minByteThreshold: 50 * 1024 * 1024, // 50MB minimum
      groupDepth: 2, // Group by [tableName, indexName]
      debugLabel: 'IndexInternalPageCache',
    );
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
      Logger.warn('Evict page cache failed: $e',
          label: 'IndexTreePartitionManager.evictPageCache');
    }
  }

  /// Clear all page caches synchronously
  void clearPageCacheSync() {
    try {
      _leafPageCache.clear();
      _internalPageCache.clear();
    } catch (e) {
      Logger.warn('Clear page cache failed: $e',
          label: 'IndexTreePartitionManager.clearPageCacheSync');
    }
  }

  /// Clear page cache for a specific table
  void clearPageCacheForTable(String tableName) {
    try {
      _leafPageCache.remove([tableName]);
      _internalPageCache.remove([tableName]);
    } catch (e) {
      Logger.warn('Clear page cache for table failed: $e',
          label: 'IndexTreePartitionManager.clearPageCacheForTable');
    }
  }

  /// Clear page cache for a specific index
  void clearPageCacheForIndex(String tableName, String indexName) {
    try {
      _leafPageCache.remove([tableName, indexName]);
      _internalPageCache.remove([tableName, indexName]);
    } catch (e) {
      Logger.warn('Clear page cache for index failed: $e',
          label: 'IndexTreePartitionManager.clearPageCacheForIndex');
    }
  }

  /// Get partition file path using the dirIndex from partition meta.
  Future<String> _partitionFilePath(String tableName, String indexName,
      IndexMeta meta, int partitionNo) async {
    final count = meta.btreePartitionCount;
    if (partitionNo < 0 || partitionNo >= count) {
      throw StateError('Invalid partitionNo: $partitionNo (count=$count)');
    }
    return _dataStore.pathManager
        .getIndexPartitionPathByNo(tableName, indexName, partitionNo);
  }

  Uint8List _aad(TreePagePtr ptr, BTreePageType type) {
    final bd = ByteData(9);
    bd.setInt32(0, ptr.partitionNo, Endian.little);
    bd.setInt32(4, ptr.pageNo, Endian.little);
    bd.setUint8(8, type.index);
    return bd.buffer.asUint8List();
  }

  Future<LeafPage> _readLeaf(
    String tableName,
    String indexName,
    IndexMeta meta,
    TreePagePtr ptr, {
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    Map<String, LeafPage>? localCache,
  }) async {
    if (ptr.isNull) return LeafPage.empty();

    // Check local cache first (for writeChanges batch consistency)
    if (localCache != null) {
      final k = keyOfPtr(ptr);
      final cached = localCache[k];
      if (cached != null) return cached;
    }

    // Check instance-level cache
    final cacheKey = [tableName, indexName, ptr.partitionNo, ptr.pageNo];
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
    if (ptr.partitionNo < 0 || ptr.partitionNo >= count)
      return LeafPage.empty();
    final path =
        await _partitionFilePath(tableName, indexName, meta, ptr.partitionNo);
    final pageSize = meta.btreePageSize;
    final raw = await _storage.readAsBytesAt(path, ptr.pageNo * pageSize,
        length: pageSize);
    if (raw.isEmpty) return LeafPage.empty();
    try {
      final parsed = BTreePageIO.parsePageBytes(raw);
      if (parsed.type == BTreePageType.free) return LeafPage.empty();
      if (parsed.type != BTreePageType.leaf) return LeafPage.empty();
      final payload = BTreePageCodec.decodePayload(
        parsed.encodedPayload,
        config: _dataStore.config,
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
        _leafPageCache.put(cacheKey, leaf);
      }
      return leaf;
    } catch (e) {
      throw StateError(
          'Corrupted B+Tree leaf page: index=$tableName.$indexName ptr=$ptr path=$path err=$e');
    }
  }

  Future<InternalPage> _readInternal(
    String tableName,
    String indexName,
    IndexMeta meta,
    TreePagePtr ptr, {
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    Map<String, InternalPage>? localCache,
  }) async {
    if (ptr.isNull) return InternalPage.empty();

    // Check local cache first (for writeChanges batch consistency)
    if (localCache != null) {
      final k = keyOfPtr(ptr);
      final cached = localCache[k];
      if (cached != null) return cached;
    }

    // Check instance-level cache
    final cacheKey = [tableName, indexName, ptr.partitionNo, ptr.pageNo];
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
        await _partitionFilePath(tableName, indexName, meta, ptr.partitionNo);
    final pageSize = meta.btreePageSize;
    final raw = await _storage.readAsBytesAt(path, ptr.pageNo * pageSize,
        length: pageSize);
    if (raw.isEmpty) return InternalPage.empty();
    try {
      final parsed = BTreePageIO.parsePageBytes(raw);
      if (parsed.type == BTreePageType.free) return InternalPage.empty();
      if (parsed.type != BTreePageType.internal) return InternalPage.empty();
      final payload = BTreePageCodec.decodePayload(
        parsed.encodedPayload,
        config: _dataStore.config,
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
        _internalPageCache.put(cacheKey, page);
      }
      return page;
    } catch (e) {
      throw StateError(
          'Corrupted B+Tree internal page: index=$tableName.$indexName ptr=$ptr path=$path err=$e');
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
    String tableName,
    String indexName,
    IndexMeta meta,
    Uint8List keyBytes, {
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    final root = meta.btreeRoot;
    final firstLeaf = meta.btreeFirstLeaf;
    if (root.isNull) return firstLeaf;
    if (meta.btreeHeight <= 0) return root;
    TreePagePtr cur = root;
    for (int depth = meta.btreeHeight; depth > 0; depth--) {
      final node = await _readInternal(tableName, indexName, meta, cur,
          encryptionKey: encryptionKey, encryptionKeyId: encryptionKeyId);
      if (node.children.isEmpty) return firstLeaf;
      final idx = node.childIndexForKey(keyBytes);
      cur = node.children[idx];
    }
    return cur;
  }

  /// Apply index deltas (put/delete) to paged tree.
  Future<void> writeChanges({
    required String tableName,
    required String indexName,
    required IndexMeta indexMeta,
    required List<DataBlockEntry> deltas,
    BatchContext? batchContext,
    int? concurrency,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
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
      await yc.maybeYield();
      ops[ByteKey(d.key)] = d.value;
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
      stats.path ??= await _partitionFilePath(tableName, indexName, meta, pNo);
      final pageSize = meta.btreePageSize;
      try {
        final raw0 =
            await _storage.readAsBytesAt(stats.path!, 0, length: pageSize);
        if (raw0.isNotEmpty) {
          final parsed0 = BTreePageIO.parsePageBytes(raw0);
          if (parsed0.type == BTreePageType.meta) {
            final hdr =
                PartitionMetaPage.tryDecodePayload(parsed0.encodedPayload);
            if (hdr != null) {
              stats.oldTotalEntries = hdr.totalEntries;
              stats.oldFileSizeInBytes = hdr.fileSizeInBytes;
              stats.oldFreeListHeadPageNo = hdr.freeListHeadPageNo;
              stats.oldFreePageCount = hdr.freePageCount;
              stats.freeListHeadPageNo = hdr.freeListHeadPageNo;
              stats.freePageCount = hdr.freePageCount;
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
          await _partitionFilePath(tableName, indexName, meta, ptr.partitionNo);
      if (!stats.dirEnsured) {
        await _storage.ensureDirectoryExists(p.dirname(stats.path!));
        stats.dirEnsured = true;
      }
      final next = stats.freeListHeadPageNo;
      final freeBytes = BTreePageIO.buildPageBytes(
        type: BTreePageType.free,
        encodedPayload: FreePage(nextFreePageNo: next).encodePayload(),
        pageSize: meta.btreePageSize,
      );
      stageWrite(stats.path!, ptr.pageNo * meta.btreePageSize, freeBytes);
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
          await _partitionFilePath(tableName, indexName, meta, partitionNo);
      final pageSize = meta.btreePageSize;
      final off = head * pageSize;
      final stagedBytes = peekStaged(stats.path!, off);
      final raw = stagedBytes ??
          await _storage.readAsBytesAt(stats.path!, off, length: pageSize);
      if (raw.isEmpty) return null;
      final parsed = BTreePageIO.parsePageBytes(raw);
      if (parsed.type != BTreePageType.free) {
        throw StateError(
            'Freelist head page is not free: index=$tableName.$indexName partition=$partitionNo pageNo=$head type=${parsed.type}');
      }
      final fp = FreePage.tryDecodePayload(parsed.encodedPayload);
      if (fp == null) {
        throw StateError(
            'Failed to decode FreePage payload: index=$tableName.$indexName partition=$partitionNo pageNo=$head');
      }
      stats.freeListHeadPageNo = fp.nextFreePageNo;
      stats.freePageCount = max(0, stats.freePageCount - 1);
      return TreePagePtr(partitionNo, head);
    }

    // ---- Dirty pages (encode once per page at end) ----
    final Map<TreePagePtr, LeafPage> dirtyLeaves = <TreePagePtr, LeafPage>{};
    final Map<TreePagePtr, InternalPage> dirtyInternals =
        <TreePagePtr, InternalPage>{};

    bool leafFits(LeafPage leaf) {
      return BTreePageSizer.fitsInPage(
        pageSize: meta.btreePageSize,
        plainPayloadLen: leaf.estimatePayloadSize(),
        config: _dataStore.config,
        encryptionKeyId: encryptionKeyId,
      );
    }

    bool internalFits(InternalPage page) {
      return BTreePageSizer.fitsInPage(
        pageSize: meta.btreePageSize,
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

      final pageSize = meta.btreePageSize;
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
      return await _readLeaf(tableName, indexName, meta, ptr,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
          localCache: leafCache);
    }

    Future<InternalPage> getInternal(TreePagePtr ptr) async {
      return await _readInternal(tableName, indexName, meta, ptr,
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
      final int threshold = (meta.btreePageSize * 0.25).floor();
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
    for (final e in entries) {
      await yc.maybeYield();
      final keyBytes = e.key.bytes;
      final val = e.value;
      final isDelete = val.isNotEmpty && val[0] == 1;
      if (isDelete) sawDelete = true;

      final frames = <_IFrame>[];
      final leafPtr = await descendToLeaf(keyBytes, frames);
      final leaf = await getLeaf(leafPtr);

      if (isDelete) {
        final deleted = leaf.delete(keyBytes);
        if (!deleted) continue;
        getStats(leafPtr.partitionNo).entriesDelta -= 1;
        // Delete cannot cause overflow.
        markLeafDirty(leafPtr, leaf);
        await tryMergeLeafWithRightSibling(leafPtr, leaf, frames);
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
    }

    // Lightweight trigger: enqueue background compaction when deletes happen.
    if (sawDelete && lastDeleteLeafPtr != null && !lastDeleteLeafPtr.isNull) {
      try {
        _dataStore.compactionManager
            .enqueueIndex(tableName, indexName, hint: lastDeleteLeafPtr);
      } catch (_) {}
    }

    // ---- Encode dirty pages into staged writes (once per page) ----
    if (dirtyLeaves.isNotEmpty || dirtyInternals.isNotEmpty) {
      final stageYc = YieldController(
        'IndexTreePartitionManager.writeChanges.stagePages',
        checkInterval: 40,
      );

      final int? encTypeIndex =
          _dataStore.config.encryptionConfig?.encryptionType.index;
      final EncoderConfig encoderConfig =
          EncoderHandler.getCurrentEncodingState();

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

      const int chunkSize = 32;
      final pending = <BTreePageEncodeItem>[];
      final pendingPtrs = <TreePagePtr>[];

      Future<void> flushEncodeChunk() async {
        if (pending.isEmpty) return;

        final req = BatchBTreePageEncodeRequest(
          pageSize: meta.btreePageSize,
          encryptionTypeIndex: encTypeIndex,
          encoderConfig: encoderConfig,
          customKey: encryptionKey,
          customKeyId: encryptionKeyId,
          pages: List<BTreePageEncodeItem>.from(pending, growable: false),
        );

        final res = await ComputeManager.run(
          batchEncodeBTreePages,
          req,
          useIsolate: useIsolateForPageEncode,
        );

        final bytesList = res.pageBytes;
        for (int i = 0; i < bytesList.length; i++) {
          await stageYc.maybeYield();
          final ptr = pendingPtrs[i];
          final stats = getStats(ptr.partitionNo);
          if (stats.path == null) {
            stats.path = await _partitionFilePath(
                tableName, indexName, meta, ptr.partitionNo);
          }
          if (!stats.dirEnsured) {
            await _storage.ensureDirectoryExists(p.dirname(stats.path!));
            stats.dirEnsured = true;
          }
          final pageSize = meta.btreePageSize;
          stageWrite(stats.path!, ptr.pageNo * pageSize, bytesList[i]);
        }

        pending.clear();
        pendingPtrs.clear();
      }

      for (final entry in dirtyLeaves.entries) {
        await stageYc.maybeYield();
        final ptr = entry.key;
        final leaf = entry.value;
        pendingPtrs.add(ptr);
        pending.add(BTreePageEncodeItem(
          typeIndex: BTreePageType.leaf.index,
          partitionNo: ptr.partitionNo,
          pageNo: ptr.pageNo,
          payload: leaf.encodePayload(),
        ));
        if (pending.length >= chunkSize) {
          await flushEncodeChunk();
        }
      }

      for (final entry in dirtyInternals.entries) {
        await stageYc.maybeYield();
        final ptr = entry.key;
        final node = entry.value;
        pendingPtrs.add(ptr);
        pending.add(BTreePageEncodeItem(
          typeIndex: BTreePageType.internal.index,
          partitionNo: ptr.partitionNo,
          pageNo: ptr.pageNo,
          payload: node.encodePayload(),
        ));
        if (pending.length >= chunkSize) {
          await flushEncodeChunk();
        }
      }

      await flushEncodeChunk();
    }

    // ---- Stage per-partition meta page (pageNo=0) and compute index total deltas ----
    int entriesDeltaSum = 0;
    int sizeDeltaSum = 0;
    final int pageSize = meta.btreePageSize;

    for (final entry in partitionStats.entries) {
      await yc.maybeYield();
      final pNo = entry.key;
      final stats = entry.value;

      if (stats.path == null) {
        stats.path = await _partitionFilePath(tableName, indexName, meta, pNo);
      }
      if (!stats.dirEnsured) {
        await _storage.ensureDirectoryExists(p.dirname(stats.path!));
        stats.dirEnsured = true;
      }

      if (!stats.headerLoaded) {
        try {
          final raw0 =
              await _storage.readAsBytesAt(stats.path!, 0, length: pageSize);
          if (raw0.isNotEmpty) {
            final parsed0 = BTreePageIO.parsePageBytes(raw0);
            if (parsed0.type == BTreePageType.meta) {
              final hdr =
                  PartitionMetaPage.tryDecodePayload(parsed0.encodedPayload);
              if (hdr != null) {
                stats.oldTotalEntries = hdr.totalEntries;
                stats.oldFileSizeInBytes = hdr.fileSizeInBytes;
                stats.oldFreeListHeadPageNo = hdr.freeListHeadPageNo;
                stats.oldFreePageCount = hdr.freePageCount;
                // Initialize current freelist state from persisted header.
                stats.freeListHeadPageNo = hdr.freeListHeadPageNo;
                stats.freePageCount = hdr.freePageCount;
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

      final metaBytes = BTreePageIO.buildPageBytes(
        type: BTreePageType.meta,
        encodedPayload: PartitionMetaPage(
          partitionNo: pNo,
          totalEntries: newEntries,
          fileSizeInBytes: newSize,
          freeListHeadPageNo: stats.freeListHeadPageNo,
          freePageCount: stats.freePageCount,
        ).encodePayload(),
        pageSize: pageSize,
      );
      stageWrite(stats.path!, 0, metaBytes);

      final int partitionEntriesDelta = newEntries - oldEntries;
      final int partitionSizeDelta = newSize - oldSize;
      entriesDeltaSum += partitionEntriesDelta;
      sizeDeltaSum += partitionSizeDelta;

      // For maintenance batches, record per-partition entry with complete index statistics
      // This allows recovery to simply use the last entry's values, avoiding partition traversal
      if (batchContext != null &&
          batchContext.batchType == BatchType.maintenance &&
          (partitionEntriesDelta != 0 || partitionSizeDelta != 0)) {
        // Calculate current index totals after this partition's changes
        final currentTotalEntries = max(0, meta.totalEntries + entriesDeltaSum);
        final currentTotalSize = max(0, meta.totalSizeInBytes + sizeDeltaSum);
        await _dataStore.parallelJournalManager.appendJournalEntry(
          IndexPartitionFlushedEntry(
            table: tableName,
            index: indexName,
            partitionNo: pNo,
            totalEntries: currentTotalEntries, // New: complete index statistics
            totalSizeInBytes:
                currentTotalSize, // New: complete index statistics
            batchId: batchContext.batchId,
            batchType: batchContext.batchType,
          ),
        );
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
        await flushYc.maybeYield();
        final path = e.key;
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
            await flushYc.maybeYield();
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
                  'IndexTreePartitionManager.writeChanges($tableName.$indexName)',
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
    // Use flush=false for batch atomicity; caller flushes at batch end.
    final indexManager = _dataStore.indexManager;
    if (indexManager != null) {
      final now = DateTime.now();
      final updatedMeta = meta.copyWith(
        totalEntries: max(0, meta.totalEntries + entriesDeltaSum),
        totalSizeInBytes: max(0, meta.totalSizeInBytes + sizeDeltaSum),
        timestamps: Timestamps(created: meta.timestamps.created, modified: now),
      );

      await indexManager.updateIndexMeta(
        tableName: tableName,
        indexName: indexName,
        updatedMeta: updatedMeta,
        flush: false,
      );

      // Mark index metadata as updated in journal for crash recovery.
      // If this entry exists, recovery knows the metadata is consistent.
      if (batchContext != null) {
        await _dataStore.parallelJournalManager.appendJournalEntry(
          IndexMetaUpdatedEntry(
            table: tableName,
            index: indexName,
            batchId: batchContext.batchId,
            batchType: batchContext.batchType,
          ),
        );
      }
    }

    // Log persistence statistics
    if (InternalConfig.showLoggerInternalLabel && totalDeltas > 0) {
      final now = DateTime.now();
      final at =
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${now.millisecond.toString().padLeft(3, '0')}';
      final totalEntries = max(0, meta.totalEntries + entriesDeltaSum);
      final totalSize = max(0, meta.totalSizeInBytes + sizeDeltaSum);
      Logger.debug(
          'Index persistence: table=$tableName, partitions=${meta.btreePartitionCount}, index=$indexName, batchEntries=$totalDeltas, totalEntries=$totalEntries, totalSize=${(totalSize / 1024 / 1024).toStringAsFixed(2)}MB, concurrency=${concurrency ?? 1}, cost=${sw.elapsedMilliseconds}ms, at: $at',
          label: 'IndexTreePartitionManager.writeChanges');
    }
  }

  /// Background compaction: scan leaf chain and merge underfull adjacent siblings.
  /// Returns next cursor, or null when finished for now.
  Future<TreePagePtr?> compactLeafChain({
    required String tableName,
    required String indexName,
    TreePagePtr? startFrom,
    required int maxVisitedLeaves,
    required int maxMerges,
    BatchContext? batchContext,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    final meta0 =
        await _dataStore.indexManager?.getIndexMeta(tableName, indexName);
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
      s.path ??= await _partitionFilePath(tableName, indexName, meta, pNo);
      try {
        final raw0 = await _storage.readAsBytesAt(s.path!, 0,
            length: meta.btreePageSize);
        if (raw0.isNotEmpty) {
          final parsed0 = BTreePageIO.parsePageBytes(raw0);
          if (parsed0.type == BTreePageType.meta) {
            final hdr =
                PartitionMetaPage.tryDecodePayload(parsed0.encodedPayload);
            if (hdr != null) {
              s.oldFileSizeInBytes = hdr.fileSizeInBytes;
              s.oldTotalEntries = hdr.totalEntries;
              s.freeListHeadPageNo = hdr.freeListHeadPageNo;
              s.freePageCount = hdr.freePageCount;
            }
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
      s.path ??= await _partitionFilePath(
          tableName, indexName, meta, pagePtr.partitionNo);
      if (!s.dirEnsured) {
        await _storage.ensureDirectoryExists(p.dirname(s.path!));
        s.dirEnsured = true;
      }
      final next = s.freeListHeadPageNo;
      final freeBytes = BTreePageIO.buildPageBytes(
        type: BTreePageType.free,
        encodedPayload: FreePage(nextFreePageNo: next).encodePayload(),
        pageSize: meta.btreePageSize,
      );
      stageWrite(s.path!, pagePtr.pageNo * meta.btreePageSize, freeBytes);
      s.freeListHeadPageNo = pagePtr.pageNo;
      s.freePageCount = s.freePageCount + 1;
      s.maxPageNoWritten = max(s.maxPageNoWritten, pagePtr.pageNo);
    }

    Uint8List _encodeLeaf(TreePagePtr p, LeafPage leaf) {
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
        pageSize: meta.btreePageSize,
      );
    }

    Uint8List _encodeInternal(TreePagePtr p, InternalPage node) {
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
        pageSize: meta.btreePageSize,
      );
    }

    bool underfull(LeafPage leaf) {
      if (leaf.keys.isEmpty) return false;
      final used = leaf.estimatePayloadSize();
      return used > 0 && used < (meta.btreePageSize * 0.25).floor();
    }

    Future<TreePagePtr> descendToLeaf(
        Uint8List key, List<_IFrame> frames) async {
      if (meta.btreeHeight <= 0) return meta.btreeRoot;
      TreePagePtr cur = meta.btreeRoot;
      for (int depth = meta.btreeHeight; depth > 0; depth--) {
        final node = await _readInternal(tableName, indexName, meta, cur,
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
      await yc.maybeYield();
      final leaf = await _readLeaf(tableName, indexName, meta, ptr,
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
      final right = await _readLeaf(tableName, indexName, meta, rightPtr,
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
        pageSize: meta.btreePageSize,
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
        final nextLeaf = await _readLeaf(
            tableName, indexName, meta, oldRightNext,
            encryptionKey: encryptionKey, encryptionKeyId: encryptionKeyId);
        nextLeaf.prev = ptr;
        final pth = await _partitionFilePath(
            tableName, indexName, meta, oldRightNext.partitionNo);
        stageWrite(pth, oldRightNext.pageNo * meta.btreePageSize,
            _encodeLeaf(oldRightNext, nextLeaf));
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
            tableName, indexName, meta, parentFrame.ptr.partitionNo);
        stageWrite(parentPath, parentFrame.ptr.pageNo * meta.btreePageSize,
            _encodeInternal(parentFrame.ptr, parent));
      }

      final leftPath =
          await _partitionFilePath(tableName, indexName, meta, ptr.partitionNo);
      stageWrite(
          leftPath, ptr.pageNo * meta.btreePageSize, _encodeLeaf(ptr, leaf));
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
        s.path ??= await _partitionFilePath(tableName, indexName, meta, pNo);
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
        final metaBytes = BTreePageIO.buildPageBytes(
          type: BTreePageType.meta,
          encodedPayload: PartitionMetaPage(
            partitionNo: pNo,
            totalEntries: s.oldTotalEntries,
            fileSizeInBytes: newSize,
            freeListHeadPageNo: s.freeListHeadPageNo,
            freePageCount: s.freePageCount,
          ).encodePayload(),
          pageSize: meta.btreePageSize,
        );
        stageWrite(s.path!, 0, metaBytes);
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

    // Update IndexMeta (structure pointers only).
    await _dataStore.indexManager?.updateIndexMeta(
      tableName: tableName,
      indexName: indexName,
      updatedMeta: meta.copyWith(
        timestamps: Timestamps(
            created: meta.timestamps.created, modified: DateTime.now()),
      ),
      flush: false,
    );

    if (merged == 0) return null;
    return ptr.isNull ? null : ptr;
  }

  /// Point lookup for unique index key. Returns PK string if exists.
  Future<String?> lookupUniquePrimaryKey({
    required String tableName,
    required String indexName,
    required IndexMeta meta,
    required Uint8List uniqueKey,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    final firstLeaf = meta.btreeFirstLeaf;
    if (firstLeaf.isNull) return null;
    var leafPtr = await _locateLeafForKey(
      tableName,
      indexName,
      meta,
      uniqueKey,
      encryptionKey: encryptionKey,
      encryptionKeyId: encryptionKeyId,
    );
    if (leafPtr.isNull) leafPtr = firstLeaf;
    final leaf = await _readLeaf(tableName, indexName, meta, leafPtr,
        encryptionKey: encryptionKey, encryptionKeyId: encryptionKeyId);
    final idx = leaf.find(uniqueKey);
    if (idx == null) return null;
    final v = leaf.values[idx];
    if (v.isEmpty || v[0] != 0) return null;
    if (v.length <= 1) return null;
    try {
      return utf8.decode(v.sublist(1), allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  /// Batch existence check for unique keys (bool per key).
  Future<List<bool>> existsUniqueKeysBatch({
    required String tableName,
    required String indexName,
    required IndexMeta meta,
    required List<Uint8List> uniqueKeys,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
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
        tableName,
        indexName,
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
      await yc.maybeYield();
      final parts = e.key.split(':');
      final ptr = TreePagePtr(int.parse(parts[0]), int.parse(parts[1]));
      final leaf = await _readLeaf(tableName, indexName, meta, ptr,
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
    required String tableName,
    required String indexName,
    required IndexMeta meta,
    required Uint8List startKeyInclusive,
    required Uint8List endKeyExclusive,
    bool reverse = false,
    int? limit,
    int? offset,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    final firstLeaf = meta.btreeFirstLeaf;
    if (firstLeaf.isNull) return IndexSearchResult.empty();

    int effectiveOffset = offset ?? 0;
    int remaining = (limit == null || limit <= 0) ? 1 << 30 : limit;
    final out = <String>[];

    TreePagePtr leafPtr;
    if (reverse) {
      if (endKeyExclusive.isNotEmpty) {
        // Reverse scan with upper bound (or cursor): start near the upper bound.
        leafPtr = await _locateLeafForKey(
          tableName,
          indexName,
          meta,
          endKeyExclusive,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
        );
      } else {
        // Reverse scan from end (Infinity).
        leafPtr = meta.btreeLastLeaf;
      }
    } else {
      // Forward scan: start at lower bound.
      leafPtr = await _locateLeafForKey(
        tableName,
        indexName,
        meta,
        startKeyInclusive,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
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
        tableName,
        indexName,
        meta,
        p,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
      );
    }

    void schedulePrefetch(TreePagePtr p) {
      if (p.isNull) return;
      if (prefetched.isNotEmpty) return;
      final k = keyOfPtr(p);
      prefetched[k] = _readLeaf(
        tableName,
        indexName,
        meta,
        p,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
      );
    }

    while (!leafPtr.isNull && remaining > 0) {
      await yc.maybeYield();
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
            return IndexSearchResult(primaryKeys: out);
          }
          if (effectiveOffset > 0) {
            effectiveOffset--;
            continue;
          }
          final pk = _extractPk(meta, k, leaf.values[i]);
          if (pk != null) {
            out.add(pk);
            remaining--;
          }
        }
        leafPtr = leaf.next;
      } else {
        i = leaf.keys.length - 1;
        for (; i >= 0 && remaining > 0; i--) {
          final k = leaf.keys[i];
          if (MemComparableKey.compare(k, startKeyInclusive) < 0) {
            // We are before start; stop.
            return IndexSearchResult(primaryKeys: out);
          }
          if (endKeyExclusive.isNotEmpty &&
              MemComparableKey.compare(k, endKeyExclusive) >= 0) {
            // Skip keys beyond end.
            continue;
          }
          if (effectiveOffset > 0) {
            effectiveOffset--;
            continue;
          }
          final pk = _extractPk(meta, k, leaf.values[i]);
          if (pk != null) {
            out.add(pk);
            remaining--;
          }
        }
        leafPtr = leaf.prev;
      }
    }

    return IndexSearchResult(primaryKeys: out);
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
    required String tableName,
    required String indexName,
    required IndexMeta meta,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    final firstLeaf = meta.btreeFirstLeaf;
    if (firstLeaf.isNull) return const <DecodedIndexEntry>[];

    final out = <DecodedIndexEntry>[];
    var ptr = firstLeaf;
    final yc = YieldController('IndexTreePartitionManager.getAllDecodedEntries',
        checkInterval: 50);
    while (!ptr.isNull) {
      await yc.maybeYield();
      final leaf = await _readLeaf(tableName, indexName, meta, ptr,
          encryptionKey: encryptionKey, encryptionKeyId: encryptionKeyId);
      for (int i = 0; i < leaf.keys.length; i++) {
        await yc.maybeYield();
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
