import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../handler/binary_schema_codec.dart';
import '../Interface/storage_interface.dart';
import '../handler/parallel_processor.dart';
import '../handler/logger.dart';
import '../handler/common.dart';
import 'overflow_manager.dart';

import '../handler/memcomparable.dart';
import '../handler/encoder.dart';
import '../model/data_store_config.dart';
import '../model/encoder_config.dart';
import '../model/meta_info.dart';
import '../model/parallel_journal_entry.dart';
import '../model/table_schema.dart';
import '../model/stored_value.dart';
import 'data_store_impl.dart';
import 'storage_adapter.dart';
import 'btree_page.dart';
import 'compute_tasks.dart';
import 'compute_manager.dart';
import 'page_redo_log_codec.dart';
import 'yield_controller.dart';
import 'workload_scheduler.dart';
import 'tree_cache.dart';

/// New baseline implementation: paged global leaf-chain B+Tree per table.
///
/// - Cross-file global leaf chain: leaf next/prev uses (partitionNo,pageNo) and can cross files.
/// - Partition files are purely physical sharding by size threshold (NOT range split).
/// - Records are encoded by schema (values only) using [BinarySchemaCodec], then encrypted by [EncoderHandler].
///
/// NOTE: This is an initial implementation focused on correctness + batch-friendly IO.
final class TableTreePartitionManager {
  final DataStoreImpl _dataStore;
  DataStoreConfig get _config => _dataStore.config;
  StorageAdapter get _storage => _dataStore.storage;

  String keyOfPtr(TreePagePtr p) => '${p.partitionNo}:${p.pageNo}';

  Future<Map<String, dynamic>?> _decodeStoredRecord({
    required String tableName,
    required TableMeta meta,
    required Uint8List storedValue,
    required List<FieldStructure> fieldStruct,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    final sv = StoredValue.decode(storedValue);
    Uint8List bytes;
    if (sv.tag == StoredValue.tagOverflowRef) {
      bytes = await _dataStore.overflowManager.getLargeValue(
        tableName: tableName,
        ref: sv.ref!,
        pageSize: meta.btreePageSize,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
      );
    } else {
      bytes = sv.inlineBytes;
    }
    return BinarySchemaCodec.decodeRecord(bytes, fieldStruct);
  }

  // Instance-level page cache for read operations (cross-method calls)
  // Key format: [tableName, partitionNo, pageNo]
  // This cache significantly reduces IO reads for frequently accessed pages,
  // especially internal nodes which are shared across many queries.
  late final TreeCache<LeafPage> _leafPageCache;
  late final TreeCache<InternalPage> _internalPageCache;

  TableTreePartitionManager(this._dataStore) {
    // Initialize page caches using memory manager quota
    final memoryManager = _dataStore.memoryManager;
    final tableQuota =
        memoryManager?.getTableDataCacheSize() ?? (128 * 1024 * 1024);
    // Allocate 30% of table cache for B+Tree pages (15% for leaf, 15% for internal)
    final int pageCacheSize = (tableQuota * 0.30).toInt();
    final int leafCacheSize = (pageCacheSize * 0.50).toInt();
    final int internalCacheSize = pageCacheSize - leafCacheSize;

    _leafPageCache = TreeCache<LeafPage>(
      sizeCalculator: _estimateLeafPageSize,
      maxByteThreshold: leafCacheSize,
      minByteThreshold: 50 * 1024 * 1024, // 50MB minimum
      groupDepth: 1, // Group by tableName
      debugLabel: 'TableLeafPageCache',
    );

    _internalPageCache = TreeCache<InternalPage>(
      sizeCalculator: _estimateInternalPageSize,
      maxByteThreshold: internalCacheSize,
      minByteThreshold: 50 * 1024 * 1024, // 50MB minimum
      groupDepth: 1, // Group by tableName
      debugLabel: 'TableInternalPageCache',
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
          label: 'TableTreePartitionManager.evictPageCache');
    }
  }

  /// Clear all page caches synchronously
  void clearPageCacheSync() {
    try {
      _leafPageCache.clear();
      _internalPageCache.clear();
    } catch (e) {
      Logger.warn('Clear page cache failed: $e',
          label: 'TableTreePartitionManager.clearPageCacheSync');
    }
  }

  /// Clear page cache for a specific table
  void clearPageCacheForTable(String tableName) {
    try {
      _leafPageCache.remove([tableName]);
      _internalPageCache.remove([tableName]);
    } catch (e) {
      Logger.warn('Clear page cache for table failed: $e',
          label: 'TableTreePartitionManager.clearPageCacheForTable');
    }
  }

  /// Create an initial TableMeta with first partition and B+Tree fields.
  Future<TableMeta> _createInitialTableMeta(String tableName) async {
    return TableMeta.createEmpty(name: tableName);
  }

  /// Get partition file path using the dirIndex from partition meta.
  Future<String> _partitionFilePath(
      String tableName, TableMeta meta, int partitionNo) async {
    final count = meta.btreePartitionCount;
    if (partitionNo < 0 || partitionNo >= count) {
      throw StateError('Invalid partitionNo: $partitionNo (count=$count)');
    }
    return _dataStore.pathManager
        .getPartitionFilePathByNo(tableName, partitionNo);
  }

  Future<TableMeta> _rotatePartition(TableMeta state) async {
    final currentCount = state.btreePartitionCount;
    return state.copyWith(
      btreePartitionCount: currentCount + 1,
      // Reserve pageNo=0 for partition meta page.
      btreeNextPageNo: TableMeta.firstDataPageNo,
    );
  }

  TableMeta _consumeNextPageNo(TableMeta state) =>
      state.copyWith(btreeNextPageNo: state.btreeNextPageNo + 1);

  Future<LeafPage> _readLeafPage(
    String tableName,
    TableMeta meta,
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
    final cacheKey = [tableName, ptr.partitionNo, ptr.pageNo];
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
    final path = await _partitionFilePath(tableName, meta, ptr.partitionNo);
    final offset = ptr.pageNo * meta.btreePageSize;
    final raw =
        await _storage.readAsBytesAt(path, offset, length: meta.btreePageSize);
    if (raw.isEmpty) return LeafPage.empty();
    try {
      final parsed = BTreePageIO.parsePageBytes(raw);
      if (parsed.type == BTreePageType.free) return LeafPage.empty();
      if (parsed.type != BTreePageType.leaf) return LeafPage.empty();
      final payload = BTreePageCodec.decodePayload(
        parsed.encodedPayload,
        config: _config,
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
      // Do NOT silently treat corrupted pages as empty; that would create "missing data" illusions.
      throw StateError(
          'Corrupted B+Tree leaf page: table=$tableName ptr=$ptr path=$path offset=$offset err=$e');
    }
  }

  Uint8List _aad(TreePagePtr ptr, BTreePageType type) {
    // AAD = [partitionNo:i32][pageNo:i32][type:u8]
    final bd = ByteData(9);
    bd.setInt32(0, ptr.partitionNo, Endian.little);
    bd.setInt32(4, ptr.pageNo, Endian.little);
    bd.setUint8(8, type.index);
    return bd.buffer.asUint8List();
  }

  Future<InternalPage> _readInternalPage(
    String tableName,
    TableMeta meta,
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
    final cacheKey = [tableName, ptr.partitionNo, ptr.pageNo];
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
    final path = await _partitionFilePath(tableName, meta, ptr.partitionNo);
    final offset = ptr.pageNo * meta.btreePageSize;
    final raw =
        await _storage.readAsBytesAt(path, offset, length: meta.btreePageSize);
    if (raw.isEmpty) return InternalPage.empty();
    try {
      final parsed = BTreePageIO.parsePageBytes(raw);
      if (parsed.type == BTreePageType.free) return InternalPage.empty();
      if (parsed.type != BTreePageType.internal) return InternalPage.empty();
      final payload = BTreePageCodec.decodePayload(
        parsed.encodedPayload,
        config: _config,
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
          'Corrupted B+Tree internal page: table=$tableName ptr=$ptr path=$path offset=$offset err=$e');
    }
  }

  Future<TreePagePtr> _locateLeafForKey(
    String tableName,
    TableMeta meta,
    Uint8List keyBytes, {
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    if (meta.btreeRoot.isNull) return meta.btreeFirstLeaf;
    if (meta.btreeHeight <= 0) return meta.btreeRoot;
    TreePagePtr cur = meta.btreeRoot;
    for (int depth = meta.btreeHeight; depth > 0; depth--) {
      final node = await _readInternalPage(tableName, meta, cur,
          encryptionKey: encryptionKey, encryptionKeyId: encryptionKeyId);
      if (node.children.isEmpty) return meta.btreeFirstLeaf;
      final idx = node.childIndexForKey(keyBytes);
      cur = node.children[idx];
    }
    return cur;
  }

  Future<TreePagePtr> _locateRightmostLeaf(
    String tableName,
    TableMeta meta, {
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    if (meta.btreeRoot.isNull) return meta.btreeLastLeaf;
    if (meta.btreeHeight <= 0) return meta.btreeRoot;
    TreePagePtr cur = meta.btreeRoot;
    for (int depth = meta.btreeHeight; depth > 0; depth--) {
      final node = await _readInternalPage(tableName, meta, cur,
          encryptionKey: encryptionKey, encryptionKeyId: encryptionKeyId);
      if (node.children.isEmpty) return meta.btreeLastLeaf;
      cur = node.children.last;
    }

    return cur;
  }

  /// Batch write changes for a table.
  Future<void> writeChanges({
    required String tableName,
    List<Map<String, dynamic>> inserts = const [],
    List<Map<String, dynamic>> updates = const [],
    List<Map<String, dynamic>> deletes = const [],
    BatchContext? batchContext,
    int? concurrency,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    final sw = Stopwatch()..start();
    final totalRecords = inserts.length + updates.length + deletes.length;

    if (totalRecords == 0) {
      return;
    }

    final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
    if (schema == null) {
      throw StateError('Table schema not found: $tableName');
    }

    // Values-only encoding structure.
    final fieldStruct = schema.fields
        .map((f) => FieldStructure(name: f.name, typeIndex: f.type.index))
        .toList(growable: false);

    var meta = await _dataStore.tableDataManager.getTableMeta(tableName) ??
        await _createInitialTableMeta(tableName);

    // ---- Batch op coalescing (PK last-write-wins) ----
    final ops = <String, _TableOp>{};
    void addOp(Map<String, dynamic> r, _OpType t, {bool isInsert = false}) {
      final pk = r[schema.primaryKey]?.toString();
      if (pk == null || pk.isEmpty) return;
      ops[pk] = _TableOp(
        pk: pk,
        pkBytes: schema.encodePrimaryKeyComponent(pk),
        type: t,
        record: r,
        isInsert: isInsert,
      );
    }

    final yc = YieldController('TableTreePartitionManager.writeChanges',
        checkInterval: 200);
    for (final r in inserts) {
      await yc.maybeYield();
      addOp(r, _OpType.put, isInsert: true);
    }
    for (final r in updates) {
      await yc.maybeYield();
      addOp(r, _OpType.put, isInsert: false);
    }
    for (final r in deletes) {
      await yc.maybeYield();
      addOp(r, _OpType.del);
    }
    if (ops.isEmpty) return;

    // Sort by key to minimize page churn.
    final opList = ops.values.toList(growable: false);
    opList.sort((a, b) => MemComparableKey.compare(a.pkBytes, b.pkBytes));

    // ---- Write staging (per-path, last-write-wins per offset) ----
    final Map<String, Map<int, Uint8List>> staged = {};
    // Track per-partition: path, recordsDelta, staged bytes size.
    final Map<int, _PartitionStats> partitionStats = {};

    // ---- Local page cache to avoid re-reading within this batch ----
    // Moved from instance variables to local variables to prevent memory bloat
    // in large-scale data scenarios. Cache is automatically cleared after method returns.
    final Map<String, LeafPage> leafCache = {};
    final Map<String, InternalPage> internalCache = {};

    _PartitionStats getStats(int pNo) =>
        partitionStats.putIfAbsent(pNo, () => _PartitionStats());

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
      stats.path ??= await _partitionFilePath(tableName, meta, pNo);
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
            // Legacy file: meta page missing; keep zeros and only load file size.
            stats.oldFileSizeInBytes = await _storage.getFileSize(stats.path!);
          }
        }
      } catch (_) {
        // Best-effort: do not fail writes on meta read; size will be corrected later.
        try {
          stats.oldFileSizeInBytes = await _storage.getFileSize(stats.path!);
        } catch (_) {}
      } finally {
        stats.headerLoaded = true;
      }
    }

    Future<void> pushFreePage(TreePagePtr ptr) async {
      if (ptr.pageNo <= 0) return; // never free meta page
      await ensurePartitionHeaderLoaded(ptr.partitionNo);
      final stats = getStats(ptr.partitionNo);
      stats.path ??= await _partitionFilePath(tableName, meta, ptr.partitionNo);
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
      if (head < TableMeta.firstDataPageNo) return null;
      stats.path ??= await _partitionFilePath(tableName, meta, partitionNo);
      final pageSize = meta.btreePageSize;
      final off = head * pageSize;
      final stagedBytes = peekStaged(stats.path!, off);
      final raw = stagedBytes ??
          await _storage.readAsBytesAt(stats.path!, off, length: pageSize);
      if (raw.isEmpty) return null;
      try {
        final parsed = BTreePageIO.parsePageBytes(raw);
        if (parsed.type != BTreePageType.free) {
          throw StateError(
              'Freelist head page is not free: type=${parsed.type}');
        }
        final fp = FreePage.tryDecodePayload(parsed.encodedPayload);
        if (fp == null) {
          throw StateError('Failed to decode FreePage payload');
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
        pageSize: meta.btreePageSize,
        plainPayloadLen: leaf.estimatePayloadSize(),
        config: _config,
        encryptionKeyId: encryptionKeyId,
      );
    }

    bool internalFits(InternalPage page) {
      return BTreePageSizer.fitsInPage(
        pageSize: meta.btreePageSize,
        plainPayloadLen: page.estimatePayloadSize(),
        config: _config,
        encryptionKeyId: encryptionKeyId,
      );
    }

    void markLeafDirty(TreePagePtr ptr, LeafPage leaf) {
      leafCache[keyOfPtr(ptr)] = leaf;
      dirtyLeaves[ptr] = leaf;
      final stats = getStats(ptr.partitionNo);
      stats.maxPageNoWritten = max(stats.maxPageNoWritten, ptr.pageNo);
    }

    void markInternalDirty(TreePagePtr ptr, InternalPage page) {
      internalCache[keyOfPtr(ptr)] = page;
      dirtyInternals[ptr] = page;
      final stats = getStats(ptr.partitionNo);
      stats.maxPageNoWritten = max(stats.maxPageNoWritten, ptr.pageNo);
    }

    Future<LeafPage> getLeaf(TreePagePtr ptr) async {
      return await _readLeafPage(tableName, meta, ptr,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
          localCache: leafCache);
    }

    Future<InternalPage> getInternal(TreePagePtr ptr) async {
      return await _readInternalPage(tableName, meta, ptr,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
          localCache: internalCache);
    }

    Future<TreePagePtr> allocatePage() async {
      // Prefer page reuse in the active partition (O(1) freelist pop).
      final activePartitionNo = meta.btreePartitionCount - 1;
      final reused = await popFreePage(activePartitionNo);
      if (reused != null) {
        return reused;
      }

      final pageSize = meta.btreePageSize;
      final nextPg = meta.btreeNextPageNo;
      if (BTreeAllocator.estimateFileSizeBytes(pageSize, nextPg) >
          _config.maxPartitionFileSize) {
        meta = await _rotatePartition(meta);
      }
      final partitionCount = meta.btreePartitionCount;
      final ptr = TreePagePtr(partitionCount - 1, meta.btreeNextPageNo);
      meta = _consumeNextPageNo(meta);
      return ptr;
    }

    Future<TreePagePtr> ensureRootLeaf() async {
      if (!meta.btreeRoot.isNull) return meta.btreeRoot;
      final ptr = await allocatePage();
      final leaf = LeafPage.empty(); // highKey empty => +INF (rightmost)
      meta = meta.copyWith(
          btreeFirstLeaf: ptr,
          btreeLastLeaf: ptr,
          btreeRoot: ptr,
          btreeHeight: 0);
      markLeafDirty(ptr, leaf);
      return ptr;
    }

    Future<TreePagePtr> descendToLeaf(
        Uint8List key, List<_Frame> frames) async {
      await ensureRootLeaf();
      if (meta.btreeHeight <= 0) return meta.btreeRoot;
      TreePagePtr cur = meta.btreeRoot;
      for (int depth = meta.btreeHeight; depth > 0; depth--) {
        final node = await getInternal(cur);
        if (node.children.isEmpty) {
          // Corrupted or missing internal node; fall back to leaf chain anchor.
          return meta.btreeFirstLeaf;
        }
        final idx = node.childIndexForKey(key);
        if (idx < 0 || idx >= node.children.length) {
          return meta.btreeFirstLeaf;
        }
        frames.add(_Frame(ptr: cur, node: node, childIndex: idx));
        cur = node.children[idx];
      }
      return cur;
    }

    Future<void> insertSplitIntoParents(
      List<_Frame> frames, {
      required Uint8List leftHighKey,
      required TreePagePtr leftPtr,
      required Uint8List rightHighKey,
      required TreePagePtr rightPtr,
    }) async {
      if (frames.isEmpty) {
        // New root.
        final root = InternalPage(
          maxKeys: <Uint8List>[leftHighKey, rightHighKey],
          children: <TreePagePtr>[leftPtr, rightPtr],
        );
        final rootPtr = await allocatePage();
        meta = meta.copyWith(
            btreeRoot: rootPtr, btreeHeight: meta.btreeHeight + 1);
        markInternalDirty(rootPtr, root);
        return;
      }

      final frame = frames.removeLast();
      final node = frame.node;
      final i = frame.childIndex;
      node.setEntry(i, leftHighKey, leftPtr);
      node.insertEntry(i + 1, rightHighKey, rightPtr);

      // Split internal if it overflows the page.
      if (internalFits(node)) {
        markInternalDirty(frame.ptr, node);
        return;
      }

      final split = node.split();
      final rightNode = split.right;
      final rightNodePtr = await allocatePage();
      markInternalDirty(frame.ptr, node);
      markInternalDirty(rightNodePtr, rightNode);

      await insertSplitIntoParents(
        frames,
        leftHighKey: node.maxKey(),
        leftPtr: frame.ptr,
        rightHighKey: rightNode.maxKey(),
        rightPtr: rightNodePtr,
      );
    }

    bool isLeafUnderfull(LeafPage leaf) {
      if (leaf.keys.isEmpty) return false;
      // Approximate fill based on plaintext payload; good enough for heuristic.
      final int used = leaf.estimatePayloadSize();
      final int threshold = (meta.btreePageSize * 0.25).floor();
      return used > 0 && used < threshold;
    }

    Future<void> tryMergeLeafWithRightSibling(
      TreePagePtr leafPtr,
      LeafPage leaf,
      List<_Frame> frames,
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

      // Apply merge into left (current) leaf.
      leaf.keys.addAll(right.keys);
      leaf.values.addAll(right.values);
      leaf.highKey = right.highKey;
      final oldRightNext = right.next;
      leaf.next = oldRightNext;

      // Fix leaf chain.
      if (!oldRightNext.isNull) {
        final nextLeaf = await getLeaf(oldRightNext);
        nextLeaf.prev = leafPtr;
        markLeafDirty(oldRightNext, nextLeaf);
      } else {
        meta = meta.copyWith(btreeLastLeaf: leafPtr);
      }

      // Remove right child entry from parent and update fence for left.
      parent.setEntry(i, leaf.highKey, leafPtr);
      parent.maxKeys.removeAt(i + 1);
      parent.children.removeAt(i + 1);

      // If parent is root with a single remaining child, shrink height.
      if (parentFrame.ptr == meta.btreeRoot &&
          meta.btreeHeight == 1 &&
          parent.children.length == 1) {
        final newRoot = parent.children.first;
        meta = meta.copyWith(btreeRoot: newRoot, btreeHeight: 0);
        // Free the old root internal page.
        dirtyInternals.remove(parentFrame.ptr);
        await pushFreePage(parentFrame.ptr);
      } else {
        markInternalDirty(parentFrame.ptr, parent);
      }

      // Free the right leaf page.
      dirtyLeaves.remove(rightPtr);
      await pushFreePage(rightPtr);

      markLeafDirty(leafPtr, leaf);
    }

    // ---- Apply ops ----
    TreePagePtr? lastDeleteLeafPtr;

    // Bulk cursor: for sorted keys, avoid descending the tree for every record.
    TreePagePtr? curLeafPtr;
    LeafPage? curLeaf;

    Future<TreePagePtr> descendToLeafPtrOnly(Uint8List key) async {
      await ensureRootLeaf();
      if (meta.btreeHeight <= 0) return meta.btreeRoot;
      TreePagePtr cur = meta.btreeRoot;
      for (int depth = meta.btreeHeight; depth > 0; depth--) {
        final node = await getInternal(cur);
        if (node.children.isEmpty) return meta.btreeFirstLeaf;
        final idx = node.childIndexForKey(key);
        if (idx < 0 || idx >= node.children.length) return meta.btreeFirstLeaf;
        cur = node.children[idx];
      }
      return cur;
    }

    final dirtyOverflowPaths = <String>{};

    // Pre-calculate overflow requirements and cache encoded records.
    final Map<String, Uint8List> preEncoded = {};
    int totalOverflowChunks = 0;

    for (final op in opList) {
      await yc.maybeYield();
      if (op.type == _OpType.put) {
        final rec = Map<String, dynamic>.from(op.record);
        rec.remove(schema.primaryKey);
        final encoded = BinarySchemaCodec.encodeRecord(rec, fieldStruct);
        preEncoded[op.pk] = encoded;

        if (_dataStore.overflowManager
            .shouldExternalize(meta.btreePageSize, encoded.length)) {
          totalOverflowChunks += _dataStore.overflowManager.estimatePageCount(
            valueLen: encoded.length,
            pageSize: meta.btreePageSize,
            encryptionKeyId: encryptionKeyId,
          );
        }
      }
    }

    OverflowBatchAllocator? overflowAllocator;
    if (totalOverflowChunks > 0) {
      overflowAllocator = await _dataStore.overflowManager.startBatchAllocation(
        totalChunks: totalOverflowChunks,
        tableName: tableName,
        pageSize: meta.btreePageSize,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        flush: false,
      );
    }
    for (final op in opList) {
      await yc.maybeYield();
      final keyBytes = op.pkBytes;

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

      if (op.type == _OpType.del) {
        final i = leaf.find(keyBytes);
        if (i == null) continue;

        // Check and free old overflow value if exists.
        final oldStoredBytes = leaf.values[i];
        try {
          final oldSv = StoredValue.decode(oldStoredBytes);
          if (oldSv.tag == StoredValue.tagOverflowRef && oldSv.ref != null) {
            await _dataStore.overflowManager.deleteLargeValue(
              tableName: tableName,
              ref: oldSv.ref!,
              pageSize: meta.btreePageSize,
              encryptionKey: encryptionKey,
              encryptionKeyId: encryptionKeyId,
            );
          }
        } catch (_) {
          // Best effort on corruption.
        }

        leaf.delete(keyBytes);
        getStats(leafPtr.partitionNo).recordsDelta -= 1;
        // Delete cannot cause overflow; stage lazily.
        markLeafDirty(leafPtr, leaf);
        // Opportunistic compaction: only compute parent frames if underfull.
        if (meta.btreeHeight > 0 &&
            isLeafUnderfull(leaf) &&
            leaf.keys.isNotEmpty) {
          final frames = <_Frame>[];
          await descendToLeaf(leaf.keys.first, frames);
          await tryMergeLeafWithRightSibling(leafPtr, leaf, frames);
        }
        lastDeleteLeafPtr = leafPtr;
        continue;
      } else {
        // Encoded value is already cached.
        final encoded = preEncoded[op.pk]!;

        final oldIdx = leaf.find(keyBytes);
        final existed = oldIdx != null;

        if (existed) {
          // Check and free old overflow value if it's being replaced.
          final oldStoredBytes = leaf.values[oldIdx];
          try {
            final oldSv = StoredValue.decode(oldStoredBytes);
            if (oldSv.tag == StoredValue.tagOverflowRef && oldSv.ref != null) {
              await _dataStore.overflowManager.deleteLargeValue(
                tableName: tableName,
                ref: oldSv.ref!,
                pageSize: meta.btreePageSize,
                encryptionKey: encryptionKey,
                encryptionKeyId: encryptionKeyId,
              );
              final overflowPath = await _dataStore.pathManager
                  .getOverflowPartitionFilePathByNo(
                      tableName, oldSv.ref!.overflowPartitionNo);
              dirtyOverflowPaths.add(overflowPath);
            }
          } catch (_) {}
        }

        Uint8List stored;
        if (_dataStore.overflowManager
            .shouldExternalize(meta.btreePageSize, encoded.length)) {
          final ref = await _dataStore.overflowManager.putLargeValue(
            tableName: tableName,
            valueBytes: encoded,
            pageSize: meta.btreePageSize,
            encryptionKey: encryptionKey,
            encryptionKeyId: encryptionKeyId,
            flush: false,
            allocator: overflowAllocator,
          );
          final overflowPath = await _dataStore.pathManager
              .getOverflowPartitionFilePathByNo(
                  tableName, ref.overflowPartitionNo);
          dirtyOverflowPaths.add(overflowPath);
          stored = StoredValue.overflow(ref).encode();
        } else {
          stored = StoredValue.inline(encoded).encode();
        }
        leaf.upsert(keyBytes, stored);
        // Only count as +1 if it's a new insert (idempotent for recovery).
        if (op.isInsert && !existed) {
          getStats(leafPtr.partitionNo).recordsDelta += 1;
        }
      }

      // If leaf overflows, split and insert into parents.
      if (leafFits(leaf)) {
        markLeafDirty(leafPtr, leaf);
        continue;
      }

      // Structural update: compute parent frames only when needed (split).
      final frames = <_Frame>[];
      final locatedPtr = await descendToLeaf(keyBytes, frames);
      if (locatedPtr != leafPtr) {
        leafPtr = locatedPtr;
        leaf = await getLeaf(leafPtr);
        curLeafPtr = leafPtr;
        curLeaf = leaf;
      }

      final split = leaf.split();
      final rightPtr = await allocatePage();
      final right = split.right;

      // Wire leaf chain.
      right.prev = leafPtr;
      right.next = leaf.next;
      final oldNext = leaf.next;
      leaf.next = rightPtr;
      if (!oldNext.isNull) {
        final nextLeaf = await getLeaf(oldNext);
        nextLeaf.prev = rightPtr;
        markLeafDirty(oldNext, nextLeaf);
      } else {
        meta = meta.copyWith(btreeLastLeaf: rightPtr);
      }

      markLeafDirty(leafPtr, leaf);
      markLeafDirty(rightPtr, right);

      // Insert new fence into parents using high keys.
      await insertSplitIntoParents(
        frames,
        leftHighKey: leaf.highKey,
        leftPtr: leafPtr,
        rightHighKey: right.highKey,
        rightPtr: rightPtr,
      );

      // Update cursor after split for subsequent sorted keys.
      if (MemComparableKey.compare(leaf.highKey, keyBytes) < 0) {
        curLeafPtr = rightPtr;
        curLeaf = right;
      } else {
        curLeafPtr = leafPtr;
        curLeaf = leaf;
      }
    }

    // Lightweight trigger: enqueue background compaction when deletes happen.
    // This is O(1) and deduplicated by CompactionManager.
    if (lastDeleteLeafPtr != null && !lastDeleteLeafPtr.isNull) {
      try {
        _dataStore.compactionManager
            .enqueueTable(tableName, hint: lastDeleteLeafPtr);
      } catch (_) {}
    }

    if (dirtyOverflowPaths.isNotEmpty) {
      for (final path in dirtyOverflowPaths) {
        await _storage.flushFile(path);
      }
    }

    // ---- Encode dirty pages into staged writes (once per page) ----
    if (dirtyLeaves.isNotEmpty || dirtyInternals.isNotEmpty) {
      final stageYc = YieldController(
        'TableTreePartitionManager.writeChanges.stagePages',
        checkInterval: 40,
      );

      final int? encTypeIndex = _config.encryptionConfig?.encryptionType.index;
      final EncoderConfig encoderConfig =
          EncoderHandler.getCurrentEncodingState();

      EncryptionType? encType;
      if (encTypeIndex != null) {
        encType = EncryptionTypeExtension.fromInt(encTypeIndex);
      }

      bool shouldUseIsolateForPageEncode(int batchCount) {
        if (batchCount <= 0) return false;
        // AEAD is CPU heavy; worth isolate even for smaller batches.
        if (encType == EncryptionType.aes256Gcm ||
            encType == EncryptionType.chacha20Poly1305) {
          return batchCount >= 4;
        }
        // XOR / none: only worth isolate for larger batches.
        if (encType == EncryptionType.xorObfuscation ||
            encType == EncryptionType.none) {
          return batchCount >= 48;
        }
        // No encryption config (encTypeIndex == null): very large batches only.
        return batchCount >= 96;
      }

      final int totalPagesToEncode = dirtyLeaves.length + dirtyInternals.length;
      final bool useIsolateForPageEncode =
          shouldUseIsolateForPageEncode(totalPagesToEncode);

      bool payloadFitsInPage(int plainPayloadLen) => BTreePageSizer.fitsInPage(
            pageSize: meta.btreePageSize,
            plainPayloadLen: plainPayloadLen,
            config: _config,
            encryptionKeyId: encryptionKeyId,
          );

      const int chunkSize = 32;
      final pending = <BTreePageEncodeItem>[];
      final pendingPtrs = <TreePagePtr>[];

      Future<void> flushEncodeChunk() async {
        if (pending.isEmpty) return;

        final pageSize = meta.btreePageSize;

        final req = BatchBTreePageEncodeRequest(
          pageSize: pageSize,
          encryptionTypeIndex: encTypeIndex,
          encoderConfig: encoderConfig,
          customKey: encryptionKey,
          customKeyId: encryptionKeyId,
          pages: List<BTreePageEncodeItem>.from(pending, growable: false),
          pageRedoTreeKindIndex:
              batchContext != null ? PageRedoTreeKind.table.index : null,
          pageRedoTableName: batchContext != null ? tableName : null,
        );

        final res = await ComputeManager.run(
          batchEncodeBTreePages,
          req,
          useIsolate: useIsolateForPageEncode,
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
          await stageYc.maybeYield();
          final ptr = pendingPtrs[i];
          final stats = getStats(ptr.partitionNo);
          stats.path ??=
              await _partitionFilePath(tableName, meta, ptr.partitionNo);
          if (!stats.dirEnsured) {
            await _storage.ensureDirectoryExists(p.dirname(stats.path!));
            stats.dirEnsured = true;
          }
          stageWrite(
              stats.path!, ptr.pageNo * meta.btreePageSize, bytesList[i]);
        }

        pending.clear();
        pendingPtrs.clear();
      }

      // Build payloads and encode in chunks to bound peak memory.
      // Check actual encoded payload length to avoid page overflow (same as index).
      for (final entry in dirtyLeaves.entries) {
        await stageYc.maybeYield();
        final ptr = entry.key;
        final leaf = entry.value;
        final payload = leaf.encodePayload();
        if (!payloadFitsInPage(payload.length)) {
          final frames = <_Frame>[];
          await descendToLeaf(
              leaf.keys.isEmpty ? leaf.highKey : leaf.keys.first, frames);
          final split = leaf.split();
          final rightPtr = await allocatePage();
          final right = split.right;
          right.prev = ptr;
          right.next = leaf.next;
          final oldNext = leaf.next;
          leaf.next = rightPtr;
          if (!oldNext.isNull) {
            final nextLeaf = await getLeaf(oldNext);
            nextLeaf.prev = rightPtr;
            markLeafDirty(oldNext, nextLeaf);
          } else {
            meta = meta.copyWith(btreeLastLeaf: rightPtr);
          }
          await insertSplitIntoParents(
            frames,
            leftHighKey: leaf.highKey,
            leftPtr: ptr,
            rightHighKey: right.highKey,
            rightPtr: rightPtr,
          );
          leafCache[keyOfPtr(rightPtr)] = right;
          final leftPayload = leaf.encodePayload();
          final rightPayload = right.encodePayload();
          if (!payloadFitsInPage(leftPayload.length) ||
              !payloadFitsInPage(rightPayload.length)) {
            throw StateError(
              'Table $tableName: page overflow after split '
              '(single entry may exceed page capacity). '
              'leftPayload=${leftPayload.length} rightPayload=${rightPayload.length} '
              'pageSize=${meta.btreePageSize}',
            );
          }
          pendingPtrs.add(ptr);
          pending.add(BTreePageEncodeItem(
            typeIndex: BTreePageType.leaf.index,
            partitionNo: ptr.partitionNo,
            pageNo: ptr.pageNo,
            payload: leftPayload,
          ));
          pendingPtrs.add(rightPtr);
          pending.add(BTreePageEncodeItem(
            typeIndex: BTreePageType.leaf.index,
            partitionNo: rightPtr.partitionNo,
            pageNo: rightPtr.pageNo,
            payload: rightPayload,
          ));
        } else {
          pendingPtrs.add(ptr);
          pending.add(BTreePageEncodeItem(
            typeIndex: BTreePageType.leaf.index,
            partitionNo: ptr.partitionNo,
            pageNo: ptr.pageNo,
            payload: payload,
          ));
        }
        if (pending.length >= chunkSize) {
          await flushEncodeChunk();
        }
      }

      for (final entry in dirtyInternals.entries) {
        await stageYc.maybeYield();
        final ptr = entry.key;
        final node = entry.value;
        final payload = node.encodePayload();
        if (!payloadFitsInPage(payload.length)) {
          final frames = <_Frame>[];
          await descendToLeaf(
              node.maxKeys.isEmpty ? Uint8List(0) : node.maxKeys.first, frames);
          int selfFrameIndex = -1;
          for (int i = 0; i < frames.length; i++) {
            if (frames[i].ptr.partitionNo == ptr.partitionNo &&
                frames[i].ptr.pageNo == ptr.pageNo) {
              selfFrameIndex = i;
              break;
            }
          }
          if (selfFrameIndex < 0) {
            throw StateError(
              'Table $tableName: internal ptr not found in descent frames',
            );
          }
          if (selfFrameIndex > 0) {
            frames.removeRange(selfFrameIndex, frames.length);
          } else {
            frames.clear();
          }
          final split = node.split();
          final rightNode = split.right;
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
            throw StateError(
              'Table $tableName: internal page overflow after split. '
              'pageSize=${meta.btreePageSize}',
            );
          }
          pendingPtrs.add(ptr);
          pending.add(BTreePageEncodeItem(
            typeIndex: BTreePageType.internal.index,
            partitionNo: ptr.partitionNo,
            pageNo: ptr.pageNo,
            payload: leftPayload,
          ));
          pendingPtrs.add(rightNodePtr);
          pending.add(BTreePageEncodeItem(
            typeIndex: BTreePageType.internal.index,
            partitionNo: rightNodePtr.partitionNo,
            pageNo: rightNodePtr.pageNo,
            payload: rightPayload,
          ));
        } else {
          pendingPtrs.add(ptr);
          pending.add(BTreePageEncodeItem(
            typeIndex: BTreePageType.internal.index,
            partitionNo: ptr.partitionNo,
            pageNo: ptr.pageNo,
            payload: payload,
          ));
        }
        if (pending.length >= chunkSize) {
          await flushEncodeChunk();
        }
      }

      await flushEncodeChunk();
    }

    // ---- Stage per-partition meta page (pageNo=0) and compute table total deltas ----
    int recordsDeltaSum = 0;
    int sizeDeltaSum = 0;
    final int pageSize = meta.btreePageSize;

    for (final entry in partitionStats.entries) {
      await yc.maybeYield();
      final pNo = entry.key;
      final stats = entry.value;

      stats.path ??= await _partitionFilePath(tableName, meta, pNo);
      if (!stats.dirEnsured) {
        await _storage.ensureDirectoryExists(p.dirname(stats.path!));
        stats.dirEnsured = true;
      }
      // Load existing PartitionMetaPage if present.
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
              // Legacy file without meta page. Fall back to file size only.
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

      final int newEntries = max(0, oldEntries + stats.recordsDelta);
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

      // IMPORTANT: global totals delta must not depend on reading old partition meta page
      // (may be corrupted during crash tests). Use batch-local delta (idempotent).
      final int partitionRecordsDelta = stats.recordsDelta;
      final int partitionSizeDelta = newSize - oldSize;
      recordsDeltaSum += partitionRecordsDelta;
      sizeDeltaSum += partitionSizeDelta;

      // For maintenance batches, record per-partition delta in journal for efficient recovery
      if (batchContext != null &&
          batchContext.batchType == BatchType.maintenance &&
          (partitionRecordsDelta != 0 || partitionSizeDelta != 0)) {
        // Calculate current table totals after this partition's changes
        final currentTotalRecords = max(0, meta.totalRecords + recordsDeltaSum);
        final currentTotalSize = max(0, meta.totalSizeInBytes + sizeDeltaSum);
        await _dataStore.parallelJournalManager.appendJournalEntry(
          TablePartitionFlushedEntry(
            table: tableName,
            partitionNo: pNo,
            totalRecords: currentTotalRecords,
            totalSizeInBytes: currentTotalSize,
            batchId: batchContext.batchId,
            batchType: batchContext.batchType,
          ),
        );
      }
    }

    // ---- Page redo: persist tree structure snapshot (no totals) ----
    // Needed because replay may write newly split pages/partitions before meta.json update.
    if (batchContext != null) {
      final redoPath = _dataStore.pathManager.getPageRedoLogPath(
        batchContext.batchId,
        spaceName: _dataStore.currentSpaceName,
      );
      await _storage.ensureDirectoryExists(p.dirname(redoPath));
      final rec = PageRedoLogCodec.encodeTreeMetaRecord(
        treeKind: PageRedoTreeKind.table,
        tableName: tableName,
        btreePageSize: meta.btreePageSize,
        btreeNextPageNo: meta.btreeNextPageNo,
        btreePartitionCount: meta.btreePartitionCount,
        btreeRootPartitionNo: meta.btreeRoot.partitionNo,
        btreeRootPageNo: meta.btreeRoot.pageNo,
        btreeFirstLeafPartitionNo: meta.btreeFirstLeaf.partitionNo,
        btreeFirstLeafPageNo: meta.btreeFirstLeaf.pageNo,
        btreeLastLeafPartitionNo: meta.btreeLastLeaf.partitionNo,
        btreeLastLeafPageNo: meta.btreeLastLeaf.pageNo,
        btreeHeight: meta.btreeHeight,
      );
      await _storage.appendBytes(redoPath, rec, flush: true);
    }

    // ---- Flush staged random writes per file (budgeted parallel IO) ----
    if (staged.isNotEmpty) {
      final flushYc = YieldController(
        'TableTreePartitionManager.writeChanges.flushFiles',
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
        // Fallback: if scheduler is disabled/misconfigured, run sequentially.
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
              label: 'TableTreePartitionManager.writeChanges($tableName)',
            );

            final int ioConcurrency = min(tasks.length, max(1, lease.tokens));
            await ParallelProcessor.execute<void>(
              tasks,
              concurrency: ioConcurrency,
              label: 'TableTreePartitionManager.writeChanges.flush',
              continueOnError: false,
            );
          } finally {
            lease?.release();
          }
        }
      }
    }

    // Update table-level totals and B+Tree pointers (flush=false for batch atomicity).
    // This ensures queries see the latest metadata even during long-running maintenance operations.
    final now = DateTime.now();
    final updatedMeta = meta.copyWith(
      totalRecords: max(0, meta.totalRecords + recordsDeltaSum),
      totalSizeInBytes: max(0, meta.totalSizeInBytes + sizeDeltaSum),
      timestamps: Timestamps(created: meta.timestamps.created, modified: now),
    );
    await _dataStore.tableDataManager.updateTableMeta(
      tableName,
      updatedMeta,
      flush: false,
    );

    // Mark table metadata as updated in journal for crash recovery.
    // If this entry exists, recovery knows the metadata is consistent.
    if (batchContext != null) {
      await _dataStore.parallelJournalManager.appendJournalEntry(
        TableMetaUpdatedEntry(
          table: tableName,
          batchId: batchContext.batchId,
          batchType: batchContext.batchType,
        ),
      );
    }

    // Log persistence statistics
    if (InternalConfig.showLoggerInternalLabel && totalRecords > 0) {
      final now = DateTime.now();
      final at =
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${now.millisecond.toString().padLeft(3, '0')}';
      final totalRecordsAfter = updatedMeta.totalRecords;
      final totalSizeAfter = updatedMeta.totalSizeInBytes;
      Logger.debug(
          'Table persistence: table=$tableName, partitions=${updatedMeta.btreePartitionCount}, batchRecords=$totalRecords, totalRecords=$totalRecordsAfter, totalSize=${(totalSizeAfter / 1024 / 1024).toStringAsFixed(2)}MB, concurrency=${concurrency ?? 1}, cost=${sw.elapsedMilliseconds}ms, at: $at',
          label: 'TableTreePartitionManager.writeChanges');
    }
  }

  /// Background compaction: scan leaf chain and merge underfull adjacent siblings.
  ///
  /// - This method is **budgeted** (limits visited leaves and merges).
  /// - It does **not** scan all partitions; callers provide a cursor [startFrom] and
  ///   re-enqueue until completion.
  ///
  /// Returns the next leaf pointer cursor, or null when finished for now.
  Future<TreePagePtr?> compactLeafChain({
    required String tableName,
    TreePagePtr? startFrom,
    required int maxVisitedLeaves,
    required int maxMerges,
    BatchContext? batchContext,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    final meta0 = await _dataStore.tableDataManager.getTableMeta(tableName);
    if (meta0 == null || meta0.btreeFirstLeaf.isNull) return null;
    var meta = meta0;
    if (maxVisitedLeaves <= 0 || maxMerges <= 0) return startFrom;

    TreePagePtr ptr = startFrom ?? meta.btreeFirstLeaf;
    if (ptr.isNull) return null;

    // Reuse existing writeChanges machinery by performing merges directly with staged writes.
    final staged = <String, Map<int, Uint8List>>{};
    final partitionStats = <int, _PartitionStats>{};

    _PartitionStats getStats(int pNo) =>
        partitionStats.putIfAbsent(pNo, () => _PartitionStats());

    void stageWrite(String path, int offset, Uint8List bytes) {
      staged.putIfAbsent(path, () => <int, Uint8List>{})[offset] = bytes;
    }

    Future<void> ensureHeaderLoaded(int pNo) async {
      final s = getStats(pNo);
      if (s.headerLoaded) return;
      s.path ??= await _partitionFilePath(tableName, meta, pNo);
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
      s.path ??= await _partitionFilePath(tableName, meta, pagePtr.partitionNo);
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

    Uint8List encodeLeaf(TreePagePtr p, LeafPage leaf) {
      final plain = leaf.encodePayload();
      final enc = BTreePageCodec.encodePayload(
        plain,
        config: _config,
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

    Uint8List encodeInternal(TreePagePtr p, InternalPage node) {
      final plain = node.encodePayload();
      final enc = BTreePageCodec.encodePayload(
        plain,
        config: _config,
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
        Uint8List key, List<_Frame> frames) async {
      if (meta.btreeHeight <= 0) return meta.btreeRoot;
      TreePagePtr cur = meta.btreeRoot;
      for (int depth = meta.btreeHeight; depth > 0; depth--) {
        final node = await _readInternalPage(tableName, meta, cur,
            encryptionKey: encryptionKey, encryptionKeyId: encryptionKeyId);
        if (node.children.isEmpty) return meta.btreeFirstLeaf;
        final idx = node.childIndexForKey(key);
        frames.add(_Frame(ptr: cur, node: node, childIndex: idx));
        cur = node.children[idx];
      }
      return cur;
    }

    int visited = 0;
    int merged = 0;
    final yc = YieldController('TableTreePartitionManager.compactLeafChain',
        checkInterval: 30);

    while (!ptr.isNull && visited < maxVisitedLeaves && merged < maxMerges) {
      await yc.maybeYield();
      final leaf = await _readLeafPage(tableName, meta, ptr,
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

      // Recompute parent frame for this leaf using its first key.
      final frames = <_Frame>[];
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
      final right = await _readLeafPage(tableName, meta, rightPtr,
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
        config: _config,
        encryptionKeyId: encryptionKeyId,
      )) {
        ptr = leaf.next;
        continue;
      }

      // Apply merge into left leaf.
      leaf.keys.addAll(right.keys);
      leaf.values.addAll(right.values);
      leaf.highKey = right.highKey;
      final oldRightNext = right.next;
      leaf.next = oldRightNext;
      if (!oldRightNext.isNull) {
        final nextLeaf = await _readLeafPage(tableName, meta, oldRightNext,
            encryptionKey: encryptionKey, encryptionKeyId: encryptionKeyId);
        nextLeaf.prev = ptr;
        final nextPath =
            await _partitionFilePath(tableName, meta, oldRightNext.partitionNo);
        stageWrite(nextPath, oldRightNext.pageNo * meta.btreePageSize,
            encodeLeaf(oldRightNext, nextLeaf));
      }

      // Parent: move fence key from right child to left child, drop right child.
      parent.setEntry(i, leaf.highKey, ptr);
      parent.maxKeys.removeAt(i + 1);
      parent.children.removeAt(i + 1);

      // Shrink root if possible.
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
            tableName, meta, parentFrame.ptr.partitionNo);
        stageWrite(parentPath, parentFrame.ptr.pageNo * meta.btreePageSize,
            encodeInternal(parentFrame.ptr, parent));
      }

      // Persist leaf page and mark right as free.
      final leftPath =
          await _partitionFilePath(tableName, meta, ptr.partitionNo);
      stageWrite(
          leftPath, ptr.pageNo * meta.btreePageSize, encodeLeaf(ptr, leaf));
      await pushFree(rightPtr);

      // Update last leaf if needed.
      if (meta.btreeLastLeaf == rightPtr) {
        meta = meta.copyWith(btreeLastLeaf: ptr);
      }
      meta = meta.copyWith(btreeRoot: newRootPtr, btreeHeight: newHeight);

      merged++;
      ptr = leaf.next;
    }

    // Stage meta pages for partitions we touched (freelist updates).
    if (partitionStats.isNotEmpty) {
      for (final e in partitionStats.entries) {
        final pNo = e.key;
        final s = e.value;
        s.path ??= await _partitionFilePath(tableName, meta, pNo);
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

    // Flush staged writes.
    for (final e in staged.entries) {
      final path = e.key;
      final offsets = e.value.keys.toList(growable: false)..sort();
      final writes = <ByteWrite>[
        for (final off in offsets) ByteWrite(offset: off, bytes: e.value[off]!),
      ];
      await _storage.writeManyAsBytesAt(path, writes, flush: false);
    }

    // Persist updated table meta (structure pointers).
    await _dataStore.tableDataManager.updateTableMeta(
      tableName,
      meta.copyWith(
        timestamps: Timestamps(
            created: meta.timestamps.created, modified: DateTime.now()),
      ),
      flush: false,
    );

    // Return cursor to continue.
    // IMPORTANT:
    // If we didn't perform any merges in this budget window, do NOT continue scanning
    // (otherwise background compaction degenerates into a full-tree scan over time).
    if (merged == 0) return null;
    return ptr.isNull ? null : ptr;
  }

  /// Batch point lookup by primary keys.
  ///
  /// API shape matches existing caller expectations in `TableDataManager`.
  Future<List<Map<String, dynamic>>> queryRecordsBatch({
    required String tableName,
    required String primaryKey,
    required Comparator<dynamic> keyComparator,
    required List<dynamic> keys,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    TableSchema? schemaOverride,
  }) async {
    if (keys.isEmpty) return const <Map<String, dynamic>>[];
    final schema = schemaOverride ??
        await _dataStore.schemaManager?.getTableSchema(tableName);
    if (schema == null) return const <Map<String, dynamic>>[];

    final fieldStruct = schema.fields
        .map((f) => FieldStructure(name: f.name, typeIndex: f.type.index))
        .toList(growable: false);

    final meta = await _dataStore.tableDataManager.getTableMeta(tableName);
    if (meta == null || (meta.btreeFirstLeaf).isNull) {
      return const <Map<String, dynamic>>[];
    }

    // Group PKs by leaf to reduce IO.
    final leafToIndexes = <String, List<int>>{};
    final pkStrings = List<String?>.filled(keys.length, null, growable: false);
    for (int i = 0; i < keys.length; i++) {
      final pk = keys[i]?.toString();
      if (pk == null || pk.isEmpty) continue;
      pkStrings[i] = pk;
      final keyBytes = schema.encodePrimaryKeyComponent(pk);
      var ptr = await _locateLeafForKey(tableName, meta, keyBytes,
          encryptionKey: encryptionKey, encryptionKeyId: encryptionKeyId);
      if (ptr.isNull) ptr = (meta.btreeFirstLeaf);
      leafToIndexes
          .putIfAbsent('${ptr.partitionNo}:${ptr.pageNo}', () => <int>[])
          .add(i);
    }

    final out = <Map<String, dynamic>>[];
    final yc = YieldController('TableTreePartitionManager.queryRecordsBatch',
        checkInterval: 100);
    for (final e in leafToIndexes.entries) {
      await yc.maybeYield();
      final parts = e.key.split(':');
      final ptr = TreePagePtr(int.parse(parts[0]), int.parse(parts[1]));
      final leaf = await _readLeafPage(tableName, meta, ptr,
          encryptionKey: encryptionKey, encryptionKeyId: encryptionKeyId);
      for (final idx in e.value) {
        final pk = pkStrings[idx];
        if (pk == null) continue;
        final keyBytes = schema.encodePrimaryKeyComponent(pk);
        final pos = leaf.find(keyBytes);
        if (pos == null) continue;
        final decoded = await _decodeStoredRecord(
          tableName: tableName,
          meta: meta,
          storedValue: leaf.values[pos],
          fieldStruct: fieldStruct,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
        );
        if (decoded == null) continue;
        out.add(TableSchema.rowWithPrimaryKeyFirst(primaryKey, pk, decoded));
      }
    }
    return out;
  }

  /// Disk existence check for primary key.
  Future<bool> existsPrimaryKey(String tableName, String primaryKeyValue,
      {TableSchema? schemaOverride}) async {
    if (primaryKeyValue.isEmpty) return false;
    final schema = schemaOverride ??
        await _dataStore.schemaManager?.getTableSchema(tableName);
    if (schema == null) return false;
    final meta = await _dataStore.tableDataManager.getTableMeta(tableName);
    if (meta == null || (meta.btreeFirstLeaf).isNull) return false;
    final keyBytes = schema.encodePrimaryKeyComponent(primaryKeyValue);
    var ptr = await _locateLeafForKey(tableName, meta, keyBytes);
    if (ptr.isNull) ptr = (meta.btreeFirstLeaf);
    final leaf = await _readLeafPage(tableName, meta, ptr);
    return leaf.find(keyBytes) != null;
  }

  /// For custom PK inserts (PrimaryKeyType.none): check which PKs already exist on disk.
  Future<Set<String>> existingPrimaryKeysBatch(
    String tableName,
    List<String> primaryKeys, {
    TableSchema? schemaOverride,
  }) async {
    if (primaryKeys.isEmpty) return const <String>{};
    final schema = schemaOverride ??
        await _dataStore.schemaManager?.getTableSchema(tableName);
    if (schema == null) return const <String>{};
    final meta = await _dataStore.tableDataManager.getTableMeta(tableName);
    if (meta == null || (meta.btreeFirstLeaf).isNull) return const <String>{};
    final out = <String>{};
    final yc = YieldController(
        'TableTreePartitionManager.existingPrimaryKeysBatch',
        checkInterval: 200);
    for (final pk in primaryKeys) {
      await yc.maybeYield();
      final keyBytes = schema.encodePrimaryKeyComponent(pk);
      var leafPtr = await _locateLeafForKey(tableName, meta, keyBytes);
      if (leafPtr.isNull) leafPtr = (meta.btreeFirstLeaf);
      final leaf = await _readLeafPage(tableName, meta, leafPtr);
      if (leaf.find(keyBytes) != null) out.add(pk);
    }
    return out;
  }

  /// Load all records from a *physical* partition file (partitionNo).
  ///
  /// This is a v2+ maintenance helper for APIs that historically operated on a
  /// "partition-at-a-time" basis (e.g. key rotation / offline rewrite).
  ///
  /// [decodeSchema] - Optional schema to use for decoding records.
  /// If provided, uses this schema instead of current table schema.
  /// This is critical for migration scenarios where old data must be decoded
  /// using the old schema before applying schema changes.
  Future<List<Map<String, dynamic>>> loadPartitionDataByNo({
    required String tableName,
    required int partitionNo,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    TableSchema? decodeSchema,
  }) async {
    // Use provided decodeSchema for migration, or current schema for normal operations
    final schema = decodeSchema ??
        await _dataStore.schemaManager?.getTableSchema(tableName);
    if (schema == null) return const <Map<String, dynamic>>[];
    final meta = await _dataStore.tableDataManager.getTableMeta(tableName);
    if (meta == null) return const <Map<String, dynamic>>[];
    if (partitionNo < 0 || partitionNo >= meta.btreePartitionCount) {
      return const <Map<String, dynamic>>[];
    }

    final path = await _partitionFilePath(tableName, meta, partitionNo);
    if (!await _storage.existsFile(path)) return const <Map<String, dynamic>>[];
    final size = await _storage.getFileSize(path);
    if (size <= meta.btreePageSize) return const <Map<String, dynamic>>[];

    final fieldStruct = schema.fields
        .map((f) => FieldStructure(name: f.name, typeIndex: f.type.index))
        .toList(growable: false);

    final pageSize = meta.btreePageSize;
    final pageCount = (size + pageSize - 1) ~/ pageSize;

    final out = <Map<String, dynamic>>[];
    final yc = YieldController(
        'TableTreePartitionManager.loadPartitionDataByNo',
        checkInterval: 50);
    for (int pageNo = 1; pageNo < pageCount; pageNo++) {
      await yc.maybeYield();
      final ptr = TreePagePtr(partitionNo, pageNo);
      final leaf = await _readLeafPage(
        tableName,
        meta,
        ptr,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
      );
      if (leaf.keys.isEmpty) continue;
      for (int i = 0; i < leaf.keys.length; i++) {
        final decoded = await _decodeStoredRecord(
          tableName: tableName,
          meta: meta,
          storedValue: leaf.values[i],
          fieldStruct: fieldStruct,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
        );
        if (decoded == null) continue;
        final pk = MemComparableKey.decodeLastText(leaf.keys[i]);
        out.add(pk != null
            ? TableSchema.rowWithPrimaryKeyFirst(schema.primaryKey, pk, decoded)
            : decoded);
      }
    }
    return out;
  }

  /// Global PK-ordered scan over the paged leaf chain (preferred API).
  ///
  /// [decodeSchema] - Optional schema to use for decoding records.
  /// If provided, uses this schema instead of current table schema.
  /// This is critical for migration scenarios where old data must be decoded
  /// using the old schema before applying schema changes.
  Stream<Map<String, dynamic>> streamRecordsByPrimaryKeyRange({
    required String tableName,
    required Uint8List startKeyInclusive,
    required Uint8List endKeyExclusive,
    required bool reverse,
    required int? limit,
    bool Function(Map<String, dynamic>)? recordPredicate,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    TableSchema? decodeSchema,
  }) async* {
    // Use provided decodeSchema for migration, or current schema for normal operations
    final schema = decodeSchema ??
        await _dataStore.schemaManager?.getTableSchema(tableName);
    if (schema == null) return;

    final fieldStruct = schema.fields
        .map((f) => FieldStructure(name: f.name, typeIndex: f.type.index))
        .toList(growable: false);

    final meta = await _dataStore.tableDataManager.getTableMeta(tableName);
    if (meta == null || meta.btreeFirstLeaf.isNull) return;

    int remaining = (limit == null || limit <= 0) ? (1 << 30) : limit;

    TreePagePtr ptr;
    int startIndexInLeaf = -1;
    if (!reverse) {
      ptr = await _locateLeafForKey(tableName, meta, startKeyInclusive,
          encryptionKey: encryptionKey, encryptionKeyId: encryptionKeyId);
      if (ptr.isNull) ptr = meta.btreeFirstLeaf;
    } else {
      if (endKeyExclusive.isNotEmpty) {
        ptr = await _locateLeafForKey(tableName, meta, endKeyExclusive,
            encryptionKey: encryptionKey, encryptionKeyId: encryptionKeyId);
        if (ptr.isNull) ptr = meta.btreeLastLeaf;
      } else {
        // Robustness: descend tree to find true last leaf,
        // rather than trusting meta.btreeLastLeaf which might be stale after crash.
        ptr = await _locateRightmostLeaf(tableName, meta,
            encryptionKey: encryptionKey, encryptionKeyId: encryptionKeyId);
      }
    }

    final yc = YieldController(
        'TableTreePartitionManager.streamRecordsByPrimaryKeyRange',
        checkInterval: 50);

    // One-step prefetch for the next leaf page in the chain.
    // This pipelines IO with per-record decoding work and improves large range scans
    // without changing storage interfaces or materializing large lists.
    final Map<String, Future<LeafPage>> prefetched =
        <String, Future<LeafPage>>{};
    Future<LeafPage> getLeaf(TreePagePtr p) {
      final k = keyOfPtr(p);
      final f = prefetched.remove(k);
      if (f != null) return f;
      return _readLeafPage(
        tableName,
        meta,
        p,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
      );
    }

    void schedulePrefetch(TreePagePtr p) {
      if (p.isNull) return;
      // Keep at most one prefetched page to avoid memory/IO bursts.
      if (prefetched.isNotEmpty) return;
      final k = keyOfPtr(p);
      prefetched[k] = _readLeafPage(
        tableName,
        meta,
        p,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
      );
    }

    while (!ptr.isNull && remaining > 0) {
      await yc.maybeYield();
      final leaf = await getLeaf(ptr);
      if (leaf.keys.isEmpty) {
        ptr = reverse ? leaf.prev : leaf.next;
        continue;
      }

      // Prefetch the next leaf page while decoding records in the current leaf.
      schedulePrefetch(reverse ? leaf.prev : leaf.next);

      if (!reverse) {
        // Find lowerBound for startKeyInclusive in first leaf only.
        int i = 0;
        if (startIndexInLeaf < 0) {
          int lo = 0, hi = leaf.keys.length;
          while (lo < hi) {
            final mid = (lo + hi) >> 1;
            if (MemComparableKey.compare(leaf.keys[mid], startKeyInclusive) <
                0) {
              lo = mid + 1;
            } else {
              hi = mid;
            }
          }
          i = lo;
          startIndexInLeaf = 0; // mark initialized
        }
        for (; i < leaf.keys.length && remaining > 0; i++) {
          final k = leaf.keys[i];
          if (endKeyExclusive.isNotEmpty &&
              MemComparableKey.compare(k, endKeyExclusive) >= 0) {
            return;
          }
          final decoded = await _decodeStoredRecord(
            tableName: tableName,
            meta: meta,
            storedValue: leaf.values[i],
            fieldStruct: fieldStruct,
            encryptionKey: encryptionKey,
            encryptionKeyId: encryptionKeyId,
          );
          if (decoded == null) continue;
          final pk = MemComparableKey.decodeLastText(k);
          final row = pk != null
              ? TableSchema.rowWithPrimaryKeyFirst(
                  schema.primaryKey, pk, decoded)
              : decoded;
          if (recordPredicate != null && !recordPredicate(row)) continue;
          yield row;
          remaining--;
        }
        ptr = leaf.next;
      } else {
        // Reverse: start from endKeyExclusive upper bound in first leaf.
        int i = leaf.keys.length - 1;
        if (startIndexInLeaf < 0 && endKeyExclusive.isNotEmpty) {
          int lo = 0, hi = leaf.keys.length;
          while (lo < hi) {
            final mid = (lo + hi) >> 1;
            if (MemComparableKey.compare(leaf.keys[mid], endKeyExclusive) < 0) {
              lo = mid + 1;
            } else {
              hi = mid;
            }
          }
          i = lo - 1;
          startIndexInLeaf = 0;
        }
        for (; i >= 0 && remaining > 0; i--) {
          final k = leaf.keys[i];
          if (MemComparableKey.compare(k, startKeyInclusive) < 0) return;
          if (endKeyExclusive.isNotEmpty &&
              MemComparableKey.compare(k, endKeyExclusive) >= 0) {
            continue;
          }
          final decoded = await _decodeStoredRecord(
            tableName: tableName,
            meta: meta,
            storedValue: leaf.values[i],
            fieldStruct: fieldStruct,
            encryptionKey: encryptionKey,
            encryptionKeyId: encryptionKeyId,
          );
          if (decoded == null) continue;
          final pk = MemComparableKey.decodeLastText(k);
          final row = pk != null
              ? TableSchema.rowWithPrimaryKeyFirst(
                  schema.primaryKey, pk, decoded)
              : decoded;
          if (recordPredicate != null && !recordPredicate(row)) continue;
          yield row;
          remaining--;
        }
        ptr = leaf.prev;
      }
    }
  }

  Future<List<Map<String, dynamic>>> scanRecordsByPrimaryKeyRange({
    required String tableName,
    required Uint8List startKeyInclusive,
    required Uint8List endKeyExclusive,
    required bool reverse,
    required int? limit,
    bool Function(Map<String, dynamic>)? recordPredicate,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    final out = <Map<String, dynamic>>[];
    await forEachRecordByPrimaryKeyRange(
      tableName: tableName,
      startKeyInclusive: startKeyInclusive,
      endKeyExclusive: endKeyExclusive,
      reverse: reverse,
      limit: limit,
      recordPredicate: recordPredicate,
      encryptionKey: encryptionKey,
      encryptionKeyId: encryptionKeyId,
      onRecord: (r) {
        out.add(r);
        return true;
      },
    );
    return out;
  }

  Future<void> forEachRecordByPrimaryKeyRange({
    required String tableName,
    required Uint8List startKeyInclusive,
    required Uint8List endKeyExclusive,
    required bool reverse,
    required int? limit,
    bool Function(Map<String, dynamic>)? recordPredicate,
    required bool Function(Map<String, dynamic> record) onRecord,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
    if (schema == null) return;
    final fieldStruct = schema.fields
        .map((f) => FieldStructure(name: f.name, typeIndex: f.type.index))
        .toList(growable: false);
    final meta = await _dataStore.tableDataManager.getTableMeta(tableName);
    if (meta == null || (meta.btreeFirstLeaf).isNull) return;

    int remaining = (limit == null || limit <= 0) ? (1 << 30) : limit;

    TreePagePtr ptr;
    int startIndexInLeaf = -1;
    if (!reverse) {
      ptr = await _locateLeafForKey(tableName, meta, startKeyInclusive,
          encryptionKey: encryptionKey, encryptionKeyId: encryptionKeyId);
      if (ptr.isNull) ptr = (meta.btreeFirstLeaf);
    } else {
      if (endKeyExclusive.isNotEmpty) {
        ptr = await _locateLeafForKey(tableName, meta, endKeyExclusive,
            encryptionKey: encryptionKey, encryptionKeyId: encryptionKeyId);
        if (ptr.isNull) ptr = (meta.btreeLastLeaf);
      } else {
        // Robustness: descend tree to find true last leaf
        ptr = await _locateRightmostLeaf(tableName, meta,
            encryptionKey: encryptionKey, encryptionKeyId: encryptionKeyId);
      }
    }

    final yc = YieldController(
        'TableTreePartitionManager.forEachRecordByPrimaryKeyRange',
        checkInterval: 50);

    // One-step prefetch for the next leaf page in the chain.
    final Map<String, Future<LeafPage>> prefetched =
        <String, Future<LeafPage>>{};
    Future<LeafPage> getLeaf(TreePagePtr p) {
      final k = keyOfPtr(p);
      final f = prefetched.remove(k);
      if (f != null) return f;
      return _readLeafPage(
        tableName,
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
      prefetched[k] = _readLeafPage(
        tableName,
        meta,
        p,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
      );
    }

    while (!ptr.isNull && remaining > 0) {
      await yc.maybeYield();
      final leaf = await getLeaf(ptr);
      if (leaf.keys.isEmpty) {
        ptr = reverse ? leaf.prev : leaf.next;
        continue;
      }

      schedulePrefetch(reverse ? leaf.prev : leaf.next);

      if (!reverse) {
        // Find lowerBound for startKeyInclusive in first leaf only.
        int i = 0;
        if (startIndexInLeaf < 0) {
          int lo = 0, hi = leaf.keys.length;
          while (lo < hi) {
            final mid = (lo + hi) >> 1;
            if (MemComparableKey.compare(leaf.keys[mid], startKeyInclusive) <
                0) {
              lo = mid + 1;
            } else {
              hi = mid;
            }
          }
          i = lo;
          startIndexInLeaf = 0; // mark initialized
        }
        for (; i < leaf.keys.length && remaining > 0; i++) {
          final k = leaf.keys[i];
          if (endKeyExclusive.isNotEmpty &&
              MemComparableKey.compare(k, endKeyExclusive) >= 0) {
            return;
          }
          final decoded = await _decodeStoredRecord(
            tableName: tableName,
            meta: meta,
            storedValue: leaf.values[i],
            fieldStruct: fieldStruct,
            encryptionKey: encryptionKey,
            encryptionKeyId: encryptionKeyId,
          );
          if (decoded == null) continue;
          final pk = MemComparableKey.decodeLastText(k);
          final row = pk != null
              ? TableSchema.rowWithPrimaryKeyFirst(
                  schema.primaryKey, pk, decoded)
              : decoded;
          if (recordPredicate != null && !recordPredicate(row)) continue;
          if (!onRecord(row)) return;
          remaining--;
        }
        ptr = leaf.next;
      } else {
        // Reverse: start from endKeyExclusive upper bound in first leaf.
        int i = leaf.keys.length - 1;
        if (startIndexInLeaf < 0 && endKeyExclusive.isNotEmpty) {
          int lo = 0, hi = leaf.keys.length;
          while (lo < hi) {
            final mid = (lo + hi) >> 1;
            if (MemComparableKey.compare(leaf.keys[mid], endKeyExclusive) < 0) {
              lo = mid + 1;
            } else {
              hi = mid;
            }
          }
          i = lo - 1;
          startIndexInLeaf = 0;
        }
        for (; i >= 0 && remaining > 0; i--) {
          final k = leaf.keys[i];
          if (MemComparableKey.compare(k, startKeyInclusive) < 0) return;
          if (endKeyExclusive.isNotEmpty &&
              MemComparableKey.compare(k, endKeyExclusive) >= 0) {
            continue;
          }
          final decoded = await _decodeStoredRecord(
            tableName: tableName,
            meta: meta,
            storedValue: leaf.values[i],
            fieldStruct: fieldStruct,
            encryptionKey: encryptionKey,
            encryptionKeyId: encryptionKeyId,
          );
          if (decoded == null) continue;
          final pk = MemComparableKey.decodeLastText(k);
          final row = pk != null
              ? TableSchema.rowWithPrimaryKeyFirst(
                  schema.primaryKey, pk, decoded)
              : decoded;
          if (recordPredicate != null && !recordPredicate(row)) continue;
          if (!onRecord(row)) return;
          remaining--;
        }
        ptr = leaf.prev;
      }
    }
  }
}

enum _OpType { put, del }

/// Tracks per-partition statistics during batch write.
final class _PartitionStats {
  String? path;
  bool dirEnsured = false;
  int recordsDelta = 0;
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

final class _TableOp {
  final String pk;
  final Uint8List pkBytes;
  final _OpType type;
  final Map<String, dynamic> record;

  /// True if this is a new insert (affects record count delta).
  final bool isInsert;
  _TableOp({
    required this.pk,
    required this.pkBytes,
    required this.type,
    required this.record,
    this.isInsert = false,
  });
}

final class _Frame {
  final TreePagePtr ptr;
  final InternalPage node;
  final int childIndex;
  _Frame({required this.ptr, required this.node, required this.childIndex});
}
