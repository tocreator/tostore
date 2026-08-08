import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../interface/storage_interface.dart';
import '../handler/binary_schema_codec.dart';
import '../handler/common.dart';
import '../handler/encryption.dart';
import '../handler/logger.dart';
import '../handler/memcomparable.dart';
import '../handler/meta_binary_codec.dart';
import '../handler/parallel_processor.dart';
import '../model/data_store_config.dart';
import '../model/db_exception.dart';
import '../model/encoder_config.dart';
import '../model/meta_info.dart';
import '../model/parallel_journal_entry.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/table_context.dart';
import '../model/stored_value.dart';
import '../model/table_schema.dart';
import 'btree_page.dart';
import 'compute/btree_page_encode_batch_runner.dart';
import 'compute/compute_batch_planner.dart';
import 'compute/table_record_encode_compute.dart';
import 'compute_manager.dart';
import 'compute_tasks.dart';
import 'data_store_impl.dart';
import 'overflow_manager.dart';
import 'page_redo_log_codec.dart';
import 'storage_adapter.dart';
import 'tree_cache.dart';
import 'workload_scheduler.dart';
import 'yield_controller.dart';

/// New baseline implementation: paged global leaf-chain B+Tree per table.
///
/// - Cross-file global leaf chain: leaf next/prev uses (partitionNo,pageNo) and can cross files.
/// - Partition files are purely physical sharding by size threshold (NOT range split).
/// - Records are encoded by schema (values only) using [BinarySchemaCodec], then encrypted by [EncryptionManager].
///
/// NOTE: This is an initial implementation focused on correctness + batch-friendly IO.
final class TableTreePartitionManager {
  final DataStoreImpl _dataStore;
  DataStoreConfig get _config => _dataStore.config;
  StorageAdapter get _storage => _dataStore.storage;
  static const int _recordEncodeMinUsefulTaskItems = 256;

  String keyOfPtr(TreePagePtr p) => '${p.partitionNo}:${p.pageNo}';

  Future<Map<String, dynamic>?> _decodeStoredRecord({
    required TableContext table,
    required TableDataMeta meta,
    required Uint8List storedValue,
    required List<FieldStructure> fieldStruct,
    bool allowLegacyMigrationFallback = true,
    Uint8List? primaryKeyBytes,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    final tableUid = table.tableUid;
    final sv = StoredValue.decode(storedValue);
    Uint8List bytes;
    if (sv.tag == StoredValue.tagOverflowRef) {
      bytes = await _dataStore.overflowManager.getLargeValue(
        table: table,
        ref: sv.ref!,
        pageSize: _dataStore.configuredPageSize,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
      );
    } else {
      bytes = sv.inlineBytes;
    }

    int? storedFieldCount;
    if (bytes.length >= 2) {
      storedFieldCount = (bytes[0] << 8) | bytes[1];
    }

    final migrationManager = _dataStore.migrationManager;
    final hasRuntimeMigration = migrationManager != null &&
        migrationManager.hasRuntimeMigrationForTable(table);

    // Tier 1: Direct decoding if slot counts match
    if (storedFieldCount != null && storedFieldCount == fieldStruct.length) {
      final decoded = BinarySchemaCodec.decodeRecord(bytes, fieldStruct);
      if (decoded != null) {
        return decoded;
      }
    }

    // Tier 2: Match layout dynamically by slot count if they differ (independent of fallback flag)
    if (hasRuntimeMigration && storedFieldCount != null) {
      final resolved = await migrationManager.resolveFieldLayoutBySlotCount(
        table,
        storedFieldCount,
      );
      if (resolved != null) {
        final historicFieldStruct =
            await _dataStore.tableMetaManager?.getStorageFieldStructure(
          tableUid,
          layoutOverride: resolved.layout,
        );
        if (historicFieldStruct != null && historicFieldStruct.isNotEmpty) {
          final decoded =
              BinarySchemaCodec.decodeRecord(bytes, historicFieldStruct);
          if (decoded != null) {
            return migrationManager.normalizeRecordToLatestSync(
              table,
              decoded,
              fromVersion: resolved.schema?.schemaVersion ?? '',
            );
          }
        }
      }
    }

    // Tier 3: Legacy migration fallback pathway
    if (allowLegacyMigrationFallback && hasRuntimeMigration) {
      final legacyDecoded =
          migrationManager.decodeLegacyRecordForReadSync(table, bytes);
      if (legacyDecoded != null) {
        return legacyDecoded;
      }
    }

    // Tier 3.5: Payload encoded without deleted slots (fieldCount == active
    // slots) while current structure still includes deleted markers — e.g.
    // promote shadow rows after an evolve layout was incorrectly applied.
    // Synthetic names match TableMetaManager deleted-slot encode convention.
    // Must run BEFORE append-only prefix fallback so leading deleted slots
    // are never silently filled from a compacted payload.
    if (storedFieldCount != null && storedFieldCount < fieldStruct.length) {
      final activeStruct = <FieldStructure>[
        for (final f in fieldStruct)
          if (!f.name.startsWith('_system_storage_deleted_slot_')) f,
      ];
      if (activeStruct.length == storedFieldCount) {
        final activeDecoded =
            BinarySchemaCodec.decodeRecord(bytes, activeStruct);
        if (activeDecoded != null) {
          return activeDecoded;
        }
      }

      // Tier 4a: Append-only evolution (addField). New slots are always
      // appended by evolveFieldStorageLayout; shorter on-disk payloads map
      // onto the structure prefix. Refuse if the prefix contains deleted
      // markers (would shift values — promote/compaction must use 3.5).
      final prefix = fieldStruct.sublist(0, storedFieldCount);
      var deletedInPrefix = false;
      for (final f in prefix) {
        if (f.name.startsWith('_system_storage_deleted_slot_')) {
          deletedInPrefix = true;
          break;
        }
      }
      if (!deletedInPrefix) {
        final prefixDecoded = BinarySchemaCodec.decodeRecord(bytes, prefix);
        if (prefixDecoded != null) {
          return prefixDecoded;
        }
      }
    }

    // Tier 4b: Exact-match fallback with the provided layout
    final fallbackDecoded = BinarySchemaCodec.decodeRecord(bytes, fieldStruct);
    if (fallbackDecoded != null) {
      return fallbackDecoded;
    }

    return null;
  }

  Future<List<FieldStructure>> _resolveStorageFieldStructure({
    required TableContext table,
    required TableSchema schema,
    List<FieldStructure>? override,
  }) async {
    final tableUid = table.tableUid;
    if (override != null) {
      return override;
    }

    final resolved =
        await _dataStore.tableMetaManager?.getStorageFieldStructure(
      tableUid,
      schema: schema,
    );
    if (resolved != null && resolved.isNotEmpty) {
      return resolved;
    }

    return schema.fields
        .map((f) => FieldStructure(name: f.name, typeIndex: f.type.index))
        .toList(growable: false);
  }

  // Instance-level page cache for read operations (cross-method calls)
  // Key format: [tableName, partitionNo, pageNo]
  // This cache significantly reduces IO reads for frequently accessed pages,
  // especially internal nodes which are shared across many queries.
  late final TreeCache<LeafPage> _leafPageCache;
  late final TreeCache<InternalPage> _internalPageCache;

  TableTreePartitionManager(this._dataStore) {
    // Initialize page caches using memory manager quota
    final resourceManager = _dataStore.resourceManager;
    final recordCacheSize =
        resourceManager?.getTableDataCacheSize() ?? (128 * 1024 * 1024);
    // Allocate 30% of table cache for B+Tree pages (15% for leaf, 15% for internal)
    final int pageCacheSize = (recordCacheSize * 0.30).toInt();
    final int leafCacheSize = (pageCacheSize * 0.50).toInt();
    final int internalCacheSize = pageCacheSize - leafCacheSize;

    _leafPageCache = TreeCache<LeafPage>(
      sizeCalculator: _estimateLeafPageSize,
      maxByteThreshold: leafCacheSize,
      minByteThreshold: 50 * 1024 * 1024, // 50MB minimum
      groupDepth: 1, // Group by tableUid
      debugLabel: 'TableLeafPageCache',
    );

    _internalPageCache = TreeCache<InternalPage>(
      sizeCalculator: _estimateInternalPageSize,
      maxByteThreshold: internalCacheSize,
      minByteThreshold: 50 * 1024 * 1024, // 50MB minimum
      groupDepth: 1, // Group by tableUid
      debugLabel: 'TableInternalPageCache',
    );
  }

  Future<List<Uint8List>> _encodeRecordPayloadsForWrite({
    required List<Map<String, dynamic>> records,
    required String primaryKeyField,
    required List<FieldStructure> fieldStruct,
  }) async {
    if (records.isEmpty) return const <Uint8List>[];

    final dispatchPlan = ComputeBatchPlanner.planTaskExecution(
      itemCount: records.length,
      minUsefulTaskItems: _recordEncodeMinUsefulTaskItems,
      estimateAverageItemBytes: () =>
          ComputeBatchPlanner.estimateAverageItemBytes(
        records,
        _dataStore.tableDataManager.estimateRecordSizeBytes,
      ),
    );

    final actualTaskCount = dispatchPlan.actualTaskCount;
    final useIsolate = dispatchPlan.useIsolate;
    final tasks =
        <ComputeTask<TableRecordEncodeRequest, TableRecordEncodeResult>>[];

    for (final range
        in ComputeBatchPlanner.splitRange(records.length, actualTaskCount)) {
      tasks.add(
        ComputeTask(
          function: encodeTableRecordChunk,
          message: TableRecordEncodeRequest(
            primaryKeyField: primaryKeyField,
            fieldStructure: fieldStruct,
            records: records.sublist(range.start, range.end),
          ),
        ),
      );
    }

    final results =
        await ComputeManager.computeBatch(tasks, enableIsolate: useIsolate);
    final merged = <Uint8List>[];
    final mergeYield = YieldController(
      'TableTreePartitionManager._encodeRecordPayloadsForWrite',
    );

    for (final result in results) {
      for (final encoded in result.encodedRecords) {
        final y1 = mergeYield.maybeYield();
        if (y1 != null) await y1;
        merged.add(encoded);
      }
    }

    if (merged.length != records.length) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Encoded record count mismatch: expected=${records.length}, actual=${merged.length}',
        ),
      ]);
    }
    return merged;
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

  /// Prewarm boundary leaf pages (first/last) for a table B+Tree.
  ///
  /// Returns an approximate number of bytes loaded into the page cache.
  Future<int> prewarmBoundaryPages(
    TableContext table, {
    TableDataMeta? meta,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    final tableUid = table.tableUid;
    final resolvedMeta = meta ??
        await _dataStore.tableDataManager.getTableDataMeta(table.tableUid);
    if (resolvedMeta == null || resolvedMeta.btreeFirstLeaf.isNull) {
      return 0;
    }

    int loadedBytes = 0;
    final pageSize = _dataStore.configuredPageSize;
    final firstLeaf = resolvedMeta.btreeFirstLeaf;
    final lastLeaf = resolvedMeta.btreeLastLeaf;

    Future<void> prewarmLeaf(TreePagePtr ptr) async {
      if (ptr.isNull) return;
      final cacheKey = [tableUid, ptr.partitionNo, ptr.pageNo];
      final alreadyCached = _leafPageCache.containsKey(cacheKey);
      await _readLeafPage(
        table,
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

  Future<TableDataMeta> _createInitialTableDataMeta(TableContext table) async {
    return TableDataMeta.createEmpty(
      tableUid: table.tableUid,
    );
  }

  /// Get partition file path using the dirIndex from partition meta.
  Future<String> _partitionFilePath(
      TableContext table, TableDataMeta meta, int partitionNo) async {
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
        .getPartitionFilePathByNo(table.tableUid, partitionNo);
  }

  Future<TableDataMeta> _rotatePartition(TableDataMeta state) async {
    final currentCount = state.btreePartitionCount;
    return state.copyWith(
      btreePartitionCount: currentCount + 1,
      // Reserve pageNo=0 for partition meta page.
      btreeNextPageNo: TableDataMeta.firstDataPageNo,
    );
  }

  TableDataMeta _consumeNextPageNo(TableDataMeta state) =>
      state.copyWith(btreeNextPageNo: state.btreeNextPageNo + 1);

  Future<LeafPage> _readLeafPage(
    TableContext table,
    TableDataMeta meta,
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
    final cacheKey = [tableUid, ptr.partitionNo, ptr.pageNo];
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
    final path = await _partitionFilePath(table, meta, ptr.partitionNo);
    final offset = ptr.pageNo * _dataStore.configuredPageSize;
    final raw = await _storage.readAsBytesAt(path, offset,
        length: _dataStore.configuredPageSize);
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
        forceType: ResultType.sysIoDataCorrupted,
        message:
            'Corrupted B+Tree leaf page: table=$tableName ptr=$ptr path=$path offset=$offset err=$e',
      );
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
    TableContext table,
    TableDataMeta meta,
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
    final cacheKey = [tableUid, ptr.partitionNo, ptr.pageNo];
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
    final path = await _partitionFilePath(table, meta, ptr.partitionNo);
    final offset = ptr.pageNo * _dataStore.configuredPageSize;
    final raw = await _storage.readAsBytesAt(path, offset,
        length: _dataStore.configuredPageSize);
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
            'Corrupted B+Tree internal page: table=$tableName ptr=$ptr path=$path offset=$offset err=$e',
      );
    }
  }

  Future<TreePagePtr> _locateLeafForKey(
    TableContext table,
    TableDataMeta meta,
    Uint8List keyBytes, {
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool readFromFileOnly = false,
  }) async {
    if (meta.btreeRoot.isNull) return meta.btreeFirstLeaf;
    if (meta.btreeHeight <= 0) return meta.btreeRoot;
    TreePagePtr cur = meta.btreeRoot;
    for (int depth = meta.btreeHeight; depth > 0; depth--) {
      final node = await _readInternalPage(table, meta, cur,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
          readFromFileOnly: readFromFileOnly);
      if (node.children.isEmpty) return meta.btreeFirstLeaf;
      final idx = node.childIndexForKey(keyBytes);
      cur = node.children[idx];
    }
    return cur;
  }

  Future<TreePagePtr> _locateRightmostLeaf(
    TableContext table,
    TableDataMeta meta, {
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool readFromFileOnly = false,
  }) async {
    if (meta.btreeRoot.isNull) return meta.btreeLastLeaf;
    if (meta.btreeHeight <= 0) return meta.btreeRoot;
    TreePagePtr cur = meta.btreeRoot;
    for (int depth = meta.btreeHeight; depth > 0; depth--) {
      final node = await _readInternalPage(table, meta, cur,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
          readFromFileOnly: readFromFileOnly);
      if (node.children.isEmpty) return meta.btreeLastLeaf;
      cur = node.children.last;
    }

    return cur;
  }

  Future<TreePagePtr> _locateRightmostLeafFast(
    TableContext table,
    TableDataMeta meta, {
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
        meta,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        readFromFileOnly: readFromFileOnly,
      );
    }

    try {
      final leaf = await _readLeafPage(
        table,
        meta,
        lastLeaf,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        readFromFileOnly: readFromFileOnly,
      );
      final looksValid = leaf.next.isNull &&
          (leaf.keys.isNotEmpty ||
              !leaf.prev.isNull ||
              meta.totalRecordCount <= 0);
      if (looksValid) {
        return lastLeaf;
      }
    } catch (_) {}

    return _locateRightmostLeaf(
      table,
      meta,
      encryptionKey: encryptionKey,
      encryptionKeyId: encryptionKeyId,
      readFromFileOnly: readFromFileOnly,
    );
  }

  /// Batch write changes for a table.
  Future<void> writeChanges({
    required TableContext table,
    List<Map<String, dynamic>> inserts = const [],
    List<Map<String, dynamic>> updates = const [],
    List<Map<String, dynamic>> deletes = const [],
    BatchContext? batchContext,
    int? concurrency,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    List<FieldStructure>? fieldStructureOverride,
    TableSchema? schemaOverride,
  }) async {
    final tableName = table.tableName;
    final tableUid = table.tableUid;
    final sw = Stopwatch()..start();
    final totalRecordCount = inserts.length + updates.length + deletes.length;

    if (totalRecordCount == 0) {
      return;
    }

    final schema = schemaOverride ??
        await _dataStore.tableMetaManager?.getTableSchema(table.tableUid);
    if (schema == null) {
      throw DbException([
        SchemaValidationStatus(
          type: ResultType.engError,
          message: 'Table schema not found: $tableName',
          tableName: tableName,
        ),
      ]);
    }

    // Values-only encoding structure.
    final fieldStruct = await _resolveStorageFieldStructure(
      table: table,
      schema: schema,
      override: fieldStructureOverride,
    );

    var meta =
        await _dataStore.tableDataManager.getTableDataMeta(table.tableUid) ??
            await _createInitialTableDataMeta(table);

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
      final y2 = yc.maybeYield();
      if (y2 != null) await y2;
      addOp(r, _OpType.put, isInsert: true);
    }
    for (final r in updates) {
      final y3 = yc.maybeYield();
      if (y3 != null) await y3;
      addOp(r, _OpType.put, isInsert: false);
    }
    for (final r in deletes) {
      final y4 = yc.maybeYield();
      if (y4 != null) await y4;
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
      stats.path ??= await _partitionFilePath(table, meta, pNo);
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
      stats.path ??= await _partitionFilePath(table, meta, ptr.partitionNo);
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
      if (head < TableDataMeta.firstDataPageNo) return null;
      stats.path ??= await _partitionFilePath(table, meta, partitionNo);
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
        config: _config,
        encryptionKeyId: encryptionKeyId,
      );
    }

    bool internalFits(InternalPage page) {
      return BTreePageSizer.fitsInPage(
        pageSize: _dataStore.configuredPageSize,
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
      return await _readLeafPage(table, meta, ptr,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
          localCache: leafCache);
    }

    Future<InternalPage> getInternal(TreePagePtr ptr) async {
      return await _readInternalPage(table, meta, ptr,
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

      final pageSize = _dataStore.configuredPageSize;
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
      final int threshold = (_dataStore.configuredPageSize * 0.25).floor();
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

    final putOps = <_TableOp>[];
    for (final op in opList) {
      final y5 = yc.maybeYield();
      if (y5 != null) await y5;
      if (op.type == _OpType.put) {
        putOps.add(op);
      }
    }
    if (putOps.isNotEmpty) {
      final putRecords = <Map<String, dynamic>>[];
      for (final op in putOps) {
        final y6 = yc.maybeYield();
        if (y6 != null) await y6;
        putRecords.add(op.record);
      }
      final encodedRecords = await _encodeRecordPayloadsForWrite(
        records: putRecords,
        primaryKeyField: schema.primaryKey,
        fieldStruct: fieldStruct,
      );

      for (int i = 0; i < putOps.length; i++) {
        final y7 = yc.maybeYield();
        if (y7 != null) await y7;
        final op = putOps[i];
        final encoded = encodedRecords[i];
        preEncoded[op.pk] = encoded;

        if (_dataStore.overflowManager
            .shouldExternalize(_dataStore.configuredPageSize, encoded.length)) {
          totalOverflowChunks += _dataStore.overflowManager.estimatePageCount(
            valueLen: encoded.length,
            pageSize: _dataStore.configuredPageSize,
            encryptionKeyId: encryptionKeyId,
          );
        }
      }
    }

    OverflowBatchAllocator? overflowAllocator;
    if (totalOverflowChunks > 0) {
      overflowAllocator = await _dataStore.overflowManager.startBatchAllocation(
        totalChunks: totalOverflowChunks,
        table: table,
        pageSize: _dataStore.configuredPageSize,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        flush: false,
      );
    }
    for (final op in opList) {
      final y8 = yc.maybeYield();
      if (y8 != null) await y8;
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
              table: table,
              ref: oldSv.ref!,
              pageSize: _dataStore.configuredPageSize,
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
                table: table,
                ref: oldSv.ref!,
                pageSize: _dataStore.configuredPageSize,
                encryptionKey: encryptionKey,
                encryptionKeyId: encryptionKeyId,
              );
              final overflowPath = await _dataStore.pathManager
                  .getOverflowPartitionFilePathByNo(
                      tableUid, oldSv.ref!.overflowPartitionNo);
              dirtyOverflowPaths.add(overflowPath);
            }
          } catch (_) {}
        }

        Uint8List stored;
        if (_dataStore.overflowManager
            .shouldExternalize(_dataStore.configuredPageSize, encoded.length)) {
          final ref = await _dataStore.overflowManager.putLargeValue(
            table: table,
            valueBytes: encoded,
            pageSize: _dataStore.configuredPageSize,
            encryptionKey: encryptionKey,
            encryptionKeyId: encryptionKeyId,
            flush: false,
            allocator: overflowAllocator,
          );
          final overflowPath = await _dataStore.pathManager
              .getOverflowPartitionFilePathByNo(
                  tableUid, ref.overflowPartitionNo);
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
            .enqueueTable(table, hint: lastDeleteLeafPtr);
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
        checkInterval: 5,
      );

      final int? encTypeIndex = _config.encryptionConfig?.encryptionType.index;
      final EncoderConfig encoderConfig =
          EncryptionManager.getCurrentEncodingState();

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
            pageSize: _dataStore.configuredPageSize,
            plainPayloadLen: plainPayloadLen,
            config: _config,
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
              batchContext != null ? PageRedoTreeKind.table.index : null,
          pageRedoTableUid: batchContext != null ? tableUid : null,
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
          final y9 = stageYc.maybeYield();
          if (y9 != null) await y9;
          final ptr = pendingPtrs[i];
          final stats = getStats(ptr.partitionNo);
          stats.path ??= await _partitionFilePath(table, meta, ptr.partitionNo);
          if (!stats.dirEnsured) {
            await _storage.ensureDirectoryExists(p.dirname(stats.path!));
            stats.dirEnsured = true;
          }
          stageWrite(stats.path!, ptr.pageNo * _dataStore.configuredPageSize,
              bytesList[i]);
        }

        pending.clear();
        pendingPtrs.clear();
      }

      // Encode in chunks to bound peak memory. Use exact payload-size
      // estimates first; split paths still validate actual payload bytes.
      for (final entry in dirtyLeaves.entries) {
        final y10 = stageYc.maybeYield();
        if (y10 != null) await y10;
        final ptr = entry.key;
        final leaf = entry.value;
        final payloadLength = leaf.estimatePayloadSize();
        if (!payloadFitsInPage(payloadLength)) {
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
            throw DbException([
              GeneralStatus(
                type: ResultType.engError,
                message:
                    'Table $tableName: page overflow after split (single entry may exceed page capacity). leftPayload=${leftPayload.length} rightPayload=${rightPayload.length} pageSize=${_dataStore.configuredPageSize}',
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
          pendingPtrs.add(rightPtr);
          pending.add(BTreePageEncodeItem(
            typeIndex: BTreePageType.leaf.index,
            partitionNo: rightPtr.partitionNo,
            pageNo: rightPtr.pageNo,
            payload: rightPayload,
          ));
        } else {
          pendingPtrs.add(ptr);
          pending.add(BTreePageEncodeItem.leaf(
            partitionNo: ptr.partitionNo,
            pageNo: ptr.pageNo,
            page: leaf,
          ));
        }
        if (pending.length >= chunkSize) {
          await flushEncodeChunk();
        }
      }

      for (final entry in dirtyInternals.entries) {
        final y11 = stageYc.maybeYield();
        if (y11 != null) await y11;
        final ptr = entry.key;
        final node = entry.value;
        final payloadLength = node.estimatePayloadSize();
        if (!payloadFitsInPage(payloadLength)) {
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
            throw DbException([
              GeneralStatus(
                type: ResultType.engError,
                message:
                    'Table $tableName: internal ptr not found in descent frames',
              ),
            ]);
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
            throw DbException([
              GeneralStatus(
                type: ResultType.engError,
                message:
                    'Table $tableName: internal page overflow after split. pageSize=${_dataStore.configuredPageSize}',
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
          pendingPtrs.add(rightNodePtr);
          pending.add(BTreePageEncodeItem(
            typeIndex: BTreePageType.internal.index,
            partitionNo: rightNodePtr.partitionNo,
            pageNo: rightNodePtr.pageNo,
            payload: rightPayload,
          ));
        } else {
          pendingPtrs.add(ptr);
          pending.add(BTreePageEncodeItem.internal(
            partitionNo: ptr.partitionNo,
            pageNo: ptr.pageNo,
            page: node,
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
    final int pageSize = _dataStore.configuredPageSize;

    for (final entry in partitionStats.entries) {
      final y12 = yc.maybeYield();
      if (y12 != null) await y12;
      final pNo = entry.key;
      final stats = entry.value;

      stats.path ??= await _partitionFilePath(table, meta, pNo);
      if (!stats.dirEnsured) {
        await _storage.ensureDirectoryExists(p.dirname(stats.path!));
        stats.dirEnsured = true;
      }
      // Load existing page-0 partition-local stats if present.
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
      final int computedSize;
      if (pNo == meta.btreePartitionCount - 1) {
        computedSize = meta.btreeNextPageNo * pageSize;
      } else {
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
      final int partitionRecordsDelta = stats.recordsDelta;
      final int partitionSizeDelta = newSize - oldSize;
      recordsDeltaSum += partitionRecordsDelta;
      sizeDeltaSum += partitionSizeDelta;
    }

    final now = DateTime.now();
    final updatedMeta = meta.copyWith(
      totalRecordCount: max(0, meta.totalRecordCount + recordsDeltaSum),
      totalSizeBytes: max(0, meta.totalSizeBytes + sizeDeltaSum),
      timestamps: Timestamps(created: meta.timestamps.created, modified: now),
    );
    if (sizeDeltaSum != 0) {
      _dataStore.tableDataManager.applyTableDataSizeDelta(table, sizeDeltaSum);
    }

    // Partition 0 page 0 carries tree-global metadata + local partition stats.
    // Local size must use the same rule as the loop above: btreeNextPageNo only
    // applies when partition 0 is the active (last) partition.
    {
      final p0Stats = getStats(0);
      p0Stats.path ??= await _partitionFilePath(table, updatedMeta, 0);
      if (!p0Stats.dirEnsured) {
        await _storage.ensureDirectoryExists(p.dirname(p0Stats.path!));
        p0Stats.dirEnsured = true;
      }
      if (!p0Stats.headerLoaded) {
        await ensurePartitionHeaderLoaded(0);
      }
      final int p0NewEntries =
          max(0, p0Stats.oldTotalEntries + p0Stats.recordsDelta);
      final int p0ComputedSize;
      if (updatedMeta.btreePartitionCount <= 1) {
        p0ComputedSize = updatedMeta.btreeNextPageNo * pageSize;
      } else {
        // Sealed partition: size from pages written this batch, else keep old.
        p0ComputedSize = p0Stats.maxPageNoWritten > 0
            ? (p0Stats.maxPageNoWritten + 1) * pageSize
            : p0Stats.oldFileSizeInBytes;
      }
      final int p0NewSize = max(p0Stats.oldFileSizeInBytes, p0ComputedSize);
      final globalBlob = TreeGlobalMetaBlobCodec.encode(
        TreeGlobalMetaKind.table,
        TableDataMetaCodec.encode(updatedMeta),
      );
      // Recovery may have rolled global totals back to batch-start base while
      // some partition files already carry this batch's marker. If any sibling
      // was previously marked durable, always rewrite p0 so recomputed totals
      // land; never treat partition-0 alone as "whole tree done".
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
            treeKind: PageRedoTreeKind.table,
            tableUid: table.tableUid,
            partitionNo: 0,
            pageNo: 0,
            payload: p0Bytes,
          );
          await _storage.appendBytes(redoPath, rec, flush: true);
        }
      }
    }

    // ---- Flush staged random writes per file (budgeted parallel IO) ----
    if (staged.isNotEmpty) {
      final flushYc = YieldController(
        'TableTreePartitionManager.writeChanges.flushFiles',
        checkInterval: 20,
      );

      final tasks = <Future<void> Function()>[];
      for (final e in staged.entries) {
        final y13 = flushYc.maybeYield();
        if (y13 != null) await y13;
        final path = e.key;
        // Skip partition files already durable for this batch (crash recovery).
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
        // Fallback: if scheduler is disabled/misconfigured, run sequentially.
        if (scheduler.globalMax <= 0 || tasks.length <= 1) {
          for (final t in tasks) {
            final y14 = flushYc.maybeYield();
            if (y14 != null) await y14;
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

    await _dataStore.tableDataManager.mutateTableDataMeta(
      table,
      (current) {
        if (current == null) return updatedMeta;
        return updatedMeta.copyWith(
          maxAutoIncrementId: current.maxAutoIncrementId,
        );
      },
      flush: false,
      persistToDisk: false,
      batchContext: batchContext,
      encryptionKey: encryptionKey,
      encryptionKeyId: encryptionKeyId,
    );

    // Log persistence statistics
    if (InternalConfig.showLoggerInternalLabel && totalRecordCount > 0) {
      final now = DateTime.now();
      final at =
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${now.millisecond.toString().padLeft(3, '0')}';
      final totalRecordsAfter = updatedMeta.totalRecordCount;
      final totalSizeAfter = updatedMeta.totalSizeBytes;
      Logger.debug(
          'Table persistence: table=$tableName, partitions=${updatedMeta.btreePartitionCount}, batchRecords=$totalRecordCount, totalRecordCount=$totalRecordsAfter, totalSize=${(totalSizeAfter / 1024 / 1024).toStringAsFixed(2)}MB, concurrency=${concurrency ?? 1}, cost=${sw.elapsedMilliseconds}ms, at: $at');
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
    required TableContext table,
    TreePagePtr? startFrom,
    required int maxVisitedLeaves,
    required int maxMerges,
    BatchContext? batchContext,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    final meta0 =
        await _dataStore.tableDataManager.getTableDataMeta(table.tableUid);
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
      s.path ??= await _partitionFilePath(table, meta, pNo);
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
      s.path ??= await _partitionFilePath(table, meta, pagePtr.partitionNo);
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
        config: _config,
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
        config: _config,
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
        Uint8List key, List<_Frame> frames) async {
      if (meta.btreeHeight <= 0) return meta.btreeRoot;
      TreePagePtr cur = meta.btreeRoot;
      for (int depth = meta.btreeHeight; depth > 0; depth--) {
        final node = await _readInternalPage(table, meta, cur,
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
      final y15 = yc.maybeYield();
      if (y15 != null) await y15;
      final leaf = await _readLeafPage(table, meta, ptr,
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
      final right = await _readLeafPage(table, meta, rightPtr,
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
        final nextLeaf = await _readLeafPage(table, meta, oldRightNext,
            encryptionKey: encryptionKey, encryptionKeyId: encryptionKeyId);
        nextLeaf.prev = ptr;
        final nextPath =
            await _partitionFilePath(table, meta, oldRightNext.partitionNo);
        stageWrite(
            nextPath,
            oldRightNext.pageNo * _dataStore.configuredPageSize,
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
        final parentPath =
            await _partitionFilePath(table, meta, parentFrame.ptr.partitionNo);
        stageWrite(
            parentPath,
            parentFrame.ptr.pageNo * _dataStore.configuredPageSize,
            encodeInternal(parentFrame.ptr, parent));
      }

      // Persist leaf page and mark right as free.
      final leftPath = await _partitionFilePath(table, meta, ptr.partitionNo);
      stageWrite(leftPath, ptr.pageNo * _dataStore.configuredPageSize,
          encodeLeaf(ptr, leaf));
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
        s.path ??= await _partitionFilePath(table, meta, pNo);
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
            TreeGlobalMetaKind.table,
            TableDataMetaCodec.encode(meta),
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

    // Flush staged writes.
    for (final e in staged.entries) {
      final path = e.key;
      final offsets = e.value.keys.toList(growable: false)..sort();
      final writes = <ByteWrite>[
        for (final off in offsets) ByteWrite(offset: off, bytes: e.value[off]!),
      ];
      await _storage.writeManyAsBytesAt(path, writes, flush: false);
    }

    // Persist updated table data meta (structure pointers) in cache; page 0 already staged.
    final compactedMeta = meta.copyWith(
      timestamps: Timestamps(
          created: meta.timestamps.created, modified: DateTime.now()),
    );
    await _dataStore.tableDataManager.mutateTableDataMeta(
      table,
      (current) {
        if (current == null) return compactedMeta;
        return compactedMeta.copyWith(
          maxAutoIncrementId: current.maxAutoIncrementId,
        );
      },
      flush: false,
      persistToDisk: false,
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
    required TableContext table,
    required String primaryKey,
    required Comparator<dynamic> keyComparator,
    required List<dynamic> keys,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    TableSchema? schemaOverride,
    List<FieldStructure>? decodeFieldStructureOverride,
    bool readFromFileOnly = false,
  }) async {
    if (keys.isEmpty) return const <Map<String, dynamic>>[];
    final schema = schemaOverride ??
        await _dataStore.tableMetaManager?.getTableSchema(table.tableUid);
    if (schema == null) return const <Map<String, dynamic>>[];

    final fieldStruct = await _resolveStorageFieldStructure(
      table: table,
      schema: schema,
      override: decodeFieldStructureOverride,
    );

    final meta =
        await _dataStore.tableDataManager.getTableDataMeta(table.tableUid);
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
      var ptr = await _locateLeafForKey(table, meta, keyBytes,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
          readFromFileOnly: readFromFileOnly);
      if (ptr.isNull) ptr = (meta.btreeFirstLeaf);
      leafToIndexes
          .putIfAbsent('${ptr.partitionNo}:${ptr.pageNo}', () => <int>[])
          .add(i);
    }

    final out = <Map<String, dynamic>>[];
    final yc = YieldController('TableTreePartitionManager.queryRecordsBatch',
        checkInterval: 100);
    for (final e in leafToIndexes.entries) {
      final y16 = yc.maybeYield();
      if (y16 != null) await y16;
      final parts = e.key.split(':');
      final ptr = TreePagePtr(int.parse(parts[0]), int.parse(parts[1]));
      final leaf = await _readLeafPage(table, meta, ptr,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
          readFromFileOnly: readFromFileOnly);
      for (final idx in e.value) {
        final pk = pkStrings[idx];
        if (pk == null) continue;
        final keyBytes = schema.encodePrimaryKeyComponent(pk);
        final pos = leaf.find(keyBytes);
        if (pos == null) continue;
        final decoded = await _decodeStoredRecord(
          table: table,
          meta: meta,
          storedValue: leaf.values[pos],
          fieldStruct: fieldStruct,
          allowLegacyMigrationFallback: schemaOverride == null,
          primaryKeyBytes: keyBytes,
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
  Future<bool> existsPrimaryKey(TableContext table, String primaryKeyValue,
      {TableSchema? schemaOverride}) async {
    if (primaryKeyValue.isEmpty) return false;
    final schema = schemaOverride ??
        await _dataStore.tableMetaManager?.getTableSchema(table.tableUid);
    if (schema == null) return false;
    final meta =
        await _dataStore.tableDataManager.getTableDataMeta(table.tableUid);
    if (meta == null || (meta.btreeFirstLeaf).isNull) return false;
    final keyBytes = schema.encodePrimaryKeyComponent(primaryKeyValue);
    var ptr = await _locateLeafForKey(table, meta, keyBytes);
    if (ptr.isNull) ptr = (meta.btreeFirstLeaf);
    final leaf = await _readLeafPage(table, meta, ptr);
    return leaf.find(keyBytes) != null;
  }

  /// For custom PK inserts (PrimaryKeyType.none): check which PKs already exist on disk.
  Future<Set<String>> existingPrimaryKeysBatch(
    TableContext table,
    List<String> primaryKeys, {
    TableSchema? schemaOverride,
  }) async {
    if (primaryKeys.isEmpty) return const <String>{};
    final schema = schemaOverride ??
        await _dataStore.tableMetaManager?.getTableSchema(table.tableUid);
    if (schema == null) return const <String>{};
    final meta =
        await _dataStore.tableDataManager.getTableDataMeta(table.tableUid);
    if (meta == null || (meta.btreeFirstLeaf).isNull) return const <String>{};
    final out = <String>{};
    final yc = YieldController(
        'TableTreePartitionManager.existingPrimaryKeysBatch',
        checkInterval: 200);
    for (final pk in primaryKeys) {
      final y17 = yc.maybeYield();
      if (y17 != null) await y17;
      final keyBytes = schema.encodePrimaryKeyComponent(pk);
      var leafPtr = await _locateLeafForKey(table, meta, keyBytes);
      if (leafPtr.isNull) leafPtr = (meta.btreeFirstLeaf);
      final leaf = await _readLeafPage(table, meta, leafPtr);
      if (leaf.find(keyBytes) != null) out.add(pk);
    }
    return out;
  }

  /// Return the current physical partition file size, or zero if it is missing.
  Future<int> getPartitionFileSizeByNo({
    required TableContext table,
    required int partitionNo,
    TableDataMeta? metaOverride,
  }) async {
    final meta = metaOverride ??
        await _dataStore.tableDataManager.getTableDataMeta(table.tableUid);
    if (meta == null) return 0;
    if (partitionNo < 0 || partitionNo >= meta.btreePartitionCount) {
      return 0;
    }
    final path = await _partitionFilePath(table, meta, partitionNo);
    if (!await _storage.existsFile(path)) return 0;
    return _storage.getFileSize(path);
  }

  Future<({List<Map<String, dynamic>> records, bool reachedEnd})>
      _loadPartitionDataPageRangeByNo({
    required TableContext table,
    required int partitionNo,
    required int startPageNo,
    required int pageLimit,
    TableDataMeta? metaSnapshot,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    TableSchema? decodeSchema,
    List<FieldStructure>? decodeFieldStructureOverride,
  }) async {
    final tableName = table.tableName;
    if (pageLimit <= 0) {
      return (records: const <Map<String, dynamic>>[], reachedEnd: false);
    }

    final schema = decodeSchema ??
        await _dataStore.tableMetaManager?.getTableSchema(table.tableUid);
    if (schema == null) {
      return (records: const <Map<String, dynamic>>[], reachedEnd: true);
    }
    final meta = metaSnapshot ??
        await _dataStore.tableDataManager.getTableDataMeta(table.tableUid);
    if (meta == null) {
      return (records: const <Map<String, dynamic>>[], reachedEnd: true);
    }
    if (partitionNo < 0 || partitionNo >= meta.btreePartitionCount) {
      return (records: const <Map<String, dynamic>>[], reachedEnd: true);
    }

    final path = await _partitionFilePath(table, meta, partitionNo);

    final fieldStruct = await _resolveStorageFieldStructure(
      table: table,
      schema: schema,
      override: decodeFieldStructureOverride,
    );

    final pageSize = _dataStore.configuredPageSize;
    final fromPage = max(TableDataMeta.firstDataPageNo, startPageNo);
    final toPage = fromPage + pageLimit;

    final out = <Map<String, dynamic>>[];
    final yc = YieldController(
        'TableTreePartitionManager.loadPartitionDataPageRangeByNo',
        checkInterval: 1);
    final startOffset = fromPage * pageSize;
    final readLength = (toPage - fromPage) * pageSize;
    final rawRange = await _storage.readAsBytesAt(
      path,
      startOffset,
      length: readLength,
    );
    if (rawRange.isEmpty) {
      return (records: out, reachedEnd: true);
    }

    for (int pageNo = fromPage; pageNo < toPage; pageNo++) {
      final y18 = yc.maybeYield();
      if (y18 != null) await y18;
      final ptr = TreePagePtr(partitionNo, pageNo);
      final pageOffsetInRange = (pageNo - fromPage) * pageSize;
      if (pageOffsetInRange >= rawRange.length) {
        return (records: out, reachedEnd: true);
      }
      final available = rawRange.length - pageOffsetInRange;
      if (available < pageSize) {
        return (records: out, reachedEnd: true);
      }
      final raw = Uint8List.sublistView(
        rawRange,
        pageOffsetInRange,
        pageOffsetInRange + pageSize,
      );

      LeafPage leaf;
      try {
        final parsed = BTreePageIO.parsePageBytes(raw);
        if (parsed.type == BTreePageType.free ||
            parsed.type == BTreePageType.internal ||
            parsed.type == BTreePageType.meta) {
          continue;
        }
        if (parsed.type != BTreePageType.leaf) {
          continue;
        }
        final payload = BTreePageCodec.decodePayload(
          parsed.encodedPayload,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
          aad: _aad(ptr, parsed.type),
        );
        leaf = LeafPage.tryDecodePayload(payload) ?? LeafPage.empty();
      } catch (e) {
        final offset = pageNo * pageSize;
        throw DbException.forceWrap(
          e,
          forceType: ResultType.engError,
          message:
              'Corrupted B+Tree page while streaming partition: table=$tableName ptr=$ptr path=$path offset=$offset err=$e',
        );
      }

      if (leaf.keys.isEmpty) continue;
      for (int i = 0; i < leaf.keys.length; i++) {
        final decoded = await _decodeStoredRecord(
          table: table,
          meta: meta,
          storedValue: leaf.values[i],
          fieldStruct: fieldStruct,
          allowLegacyMigrationFallback: decodeSchema == null,
          primaryKeyBytes: leaf.keys[i],
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
    return (records: out, reachedEnd: false);
  }

  /// Stream records from a physical partition in fixed page batches.
  ///
  /// This keeps maintenance callers from materializing a very large partition
  /// file as one in-memory list.
  Stream<List<Map<String, dynamic>>> streamPartitionDataPageBatchesByNo({
    required TableContext table,
    required int partitionNo,
    int pagesPerBatch = 500,
    bool prefetchNextPageBatch = false,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    TableSchema? decodeSchema,
    List<FieldStructure>? decodeFieldStructureOverride,
  }) async* {
    if (pagesPerBatch <= 0) pagesPerBatch = 500;

    final meta =
        await _dataStore.tableDataManager.getTableDataMeta(table.tableUid);
    if (meta == null) return;
    if (partitionNo < 0 || partitionNo >= meta.btreePartitionCount) {
      return;
    }
    final path = await _partitionFilePath(table, meta, partitionNo);
    if (!await _storage.existsFile(path)) return;
    final size = await _storage.getFileSize(path);
    final snapshotPageCount = (size + _dataStore.configuredPageSize - 1) ~/
        _dataStore.configuredPageSize;
    if (snapshotPageCount <= TableDataMeta.firstDataPageNo) {
      return;
    }

    final yc = YieldController(
        'TableTreePartitionManager.streamPartitionDataPageBatchesByNo',
        checkInterval: 1);

    Future<({List<Map<String, dynamic>> records, bool reachedEnd})> loadBatch(
      int pageNo,
    ) {
      final pageLimit = min(pagesPerBatch, snapshotPageCount - pageNo);
      return _loadPartitionDataPageRangeByNo(
        table: table,
        partitionNo: partitionNo,
        startPageNo: pageNo,
        pageLimit: pageLimit,
        metaSnapshot: meta,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        decodeSchema: decodeSchema,
        decodeFieldStructureOverride: decodeFieldStructureOverride,
      );
    }

    Future<({List<Map<String, dynamic>> records, bool reachedEnd})>? pending;

    for (int pageNo = TableDataMeta.firstDataPageNo;
        pageNo < snapshotPageCount;) {
      final y19 = yc.maybeYield();
      if (y19 != null) await y19;
      final pageLimit = min(pagesPerBatch, snapshotPageCount - pageNo);
      final batchFuture = pending ?? loadBatch(pageNo);
      pending = null;
      final batch = await batchFuture;
      final nextPageNo = pageNo + pageLimit;

      if (prefetchNextPageBatch &&
          !batch.reachedEnd &&
          nextPageNo < snapshotPageCount) {
        pending = loadBatch(nextPageNo);
      }

      final records = batch.records;
      if (records.isNotEmpty) {
        yield records;
      }
      if (batch.reachedEnd) {
        break;
      }
      pageNo = nextPageNo;
    }
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
    required TableContext table,
    required int partitionNo,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    TableSchema? decodeSchema,
    List<FieldStructure>? decodeFieldStructureOverride,
  }) async {
    // Use provided decodeSchema for migration, or current schema for normal operations
    final schema = decodeSchema ??
        await _dataStore.tableMetaManager?.getTableSchema(table.tableUid);
    if (schema == null) return const <Map<String, dynamic>>[];
    final meta =
        await _dataStore.tableDataManager.getTableDataMeta(table.tableUid);
    if (meta == null) return const <Map<String, dynamic>>[];
    if (partitionNo < 0 || partitionNo >= meta.btreePartitionCount) {
      return const <Map<String, dynamic>>[];
    }

    final path = await _partitionFilePath(table, meta, partitionNo);
    if (!await _storage.existsFile(path)) return const <Map<String, dynamic>>[];
    final size = await _storage.getFileSize(path);
    if (size <= _dataStore.configuredPageSize) {
      return const <Map<String, dynamic>>[];
    }

    final fieldStruct = await _resolveStorageFieldStructure(
      table: table,
      schema: schema,
      override: decodeFieldStructureOverride,
    );

    final pageSize = _dataStore.configuredPageSize;
    final pageCount = (size + pageSize - 1) ~/ pageSize;

    final out = <Map<String, dynamic>>[];
    final yc = YieldController(
        'TableTreePartitionManager.loadPartitionDataByNo',
        checkInterval: 50);
    for (int pageNo = 1; pageNo < pageCount; pageNo++) {
      final y20 = yc.maybeYield();
      if (y20 != null) await y20;
      final ptr = TreePagePtr(partitionNo, pageNo);
      final leaf = await _readLeafPage(
        table,
        meta,
        ptr,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
      );
      if (leaf.keys.isEmpty) continue;
      for (int i = 0; i < leaf.keys.length; i++) {
        final decoded = await _decodeStoredRecord(
          table: table,
          meta: meta,
          storedValue: leaf.values[i],
          fieldStruct: fieldStruct,
          allowLegacyMigrationFallback: decodeSchema == null,
          primaryKeyBytes: leaf.keys[i],
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
    required TableContext table,
    required Uint8List startKeyInclusive,
    required Uint8List endKeyExclusive,
    required bool reverse,
    required int? limit,
    bool Function(Map<String, dynamic>)? recordPredicate,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    TableSchema? decodeSchema,
    List<FieldStructure>? decodeFieldStructureOverride,
    bool readFromFileOnly = false,
  }) async* {
    // Use provided decodeSchema for migration, or current schema for normal operations
    final schema = decodeSchema ??
        await _dataStore.tableMetaManager?.getTableSchema(table.tableUid);
    if (schema == null) return;

    final fieldStruct = await _resolveStorageFieldStructure(
      table: table,
      schema: schema,
      override: decodeFieldStructureOverride,
    );

    final meta =
        await _dataStore.tableDataManager.getTableDataMeta(table.tableUid);
    if (meta == null || meta.btreeFirstLeaf.isNull) return;

    int remaining = (limit == null || limit <= 0) ? (1 << 30) : limit;

    TreePagePtr ptr;
    int startIndexInLeaf = -1;
    if (!reverse) {
      ptr = await _locateLeafForKey(table, meta, startKeyInclusive,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
          readFromFileOnly: readFromFileOnly);
      if (ptr.isNull) ptr = meta.btreeFirstLeaf;
    } else {
      if (endKeyExclusive.isNotEmpty) {
        ptr = await _locateLeafForKey(table, meta, endKeyExclusive,
            encryptionKey: encryptionKey,
            encryptionKeyId: encryptionKeyId,
            readFromFileOnly: readFromFileOnly);
        if (ptr.isNull) ptr = meta.btreeLastLeaf;
      } else {
        // Fast path: trust meta.btreeLastLeaf when it still points to the
        // boundary leaf, and fall back to a full right-edge descent otherwise.
        ptr = await _locateRightmostLeafFast(table, meta,
            encryptionKey: encryptionKey,
            encryptionKeyId: encryptionKeyId,
            readFromFileOnly: readFromFileOnly);
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
        table,
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
      // Keep at most one prefetched page to avoid memory/IO bursts.
      if (prefetched.isNotEmpty) return;
      final k = keyOfPtr(p);
      prefetched[k] = _readLeafPage(
        table,
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

    while (!ptr.isNull && remaining > 0) {
      if (_dataStore.shouldAbortBackgroundScan) {
        await drainPrefetch();
        return;
      }
      final y21 = yc.maybeYield();
      if (y21 != null) await y21;
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
            table: table,
            meta: meta,
            storedValue: leaf.values[i],
            fieldStruct: fieldStruct,
            allowLegacyMigrationFallback: decodeSchema == null,
            primaryKeyBytes: k,
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
            table: table,
            meta: meta,
            storedValue: leaf.values[i],
            fieldStruct: fieldStruct,
            allowLegacyMigrationFallback: decodeSchema == null,
            primaryKeyBytes: k,
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
    required TableContext table,
    required Uint8List startKeyInclusive,
    required Uint8List endKeyExclusive,
    required bool reverse,
    required int? limit,
    bool Function(Map<String, dynamic>)? recordPredicate,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    TableSchema? decodeSchema,
    List<FieldStructure>? decodeFieldStructureOverride,
    bool readFromFileOnly = false,
  }) async {
    final out = <Map<String, dynamic>>[];
    await forEachRecordByPrimaryKeyRange(
      table: table,
      startKeyInclusive: startKeyInclusive,
      endKeyExclusive: endKeyExclusive,
      reverse: reverse,
      limit: limit,
      recordPredicate: recordPredicate,
      encryptionKey: encryptionKey,
      encryptionKeyId: encryptionKeyId,
      decodeSchema: decodeSchema,
      decodeFieldStructureOverride: decodeFieldStructureOverride,
      readFromFileOnly: readFromFileOnly,
      onRecord: (r) {
        out.add(r);
        return true;
      },
    );
    return out;
  }

  Future<void> forEachRecordByPrimaryKeyRange({
    required TableContext table,
    required Uint8List startKeyInclusive,
    required Uint8List endKeyExclusive,
    required bool reverse,
    required int? limit,
    bool Function(Map<String, dynamic>)? recordPredicate,
    required bool Function(Map<String, dynamic> record) onRecord,
    bool decodeRecord = true,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    TableSchema? decodeSchema,
    List<FieldStructure>? decodeFieldStructureOverride,
    bool readFromFileOnly = false,
  }) async {
    final schema = decodeSchema ??
        await _dataStore.tableMetaManager?.getTableSchema(table.tableUid);
    if (schema == null) return;
    final fieldStruct = await _resolveStorageFieldStructure(
      table: table,
      schema: schema,
      override: decodeFieldStructureOverride,
    );
    final meta =
        await _dataStore.tableDataManager.getTableDataMeta(table.tableUid);
    if (meta == null || (meta.btreeFirstLeaf).isNull) return;

    int remaining = (limit == null || limit <= 0) ? (1 << 30) : limit;

    TreePagePtr ptr;
    int startIndexInLeaf = -1;
    if (!reverse) {
      ptr = await _locateLeafForKey(table, meta, startKeyInclusive,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
          readFromFileOnly: readFromFileOnly);
      if (ptr.isNull) ptr = (meta.btreeFirstLeaf);
    } else {
      if (endKeyExclusive.isNotEmpty) {
        ptr = await _locateLeafForKey(table, meta, endKeyExclusive,
            encryptionKey: encryptionKey,
            encryptionKeyId: encryptionKeyId,
            readFromFileOnly: readFromFileOnly);
        if (ptr.isNull) ptr = (meta.btreeLastLeaf);
      } else {
        ptr = await _locateRightmostLeafFast(table, meta,
            encryptionKey: encryptionKey,
            encryptionKeyId: encryptionKeyId,
            readFromFileOnly: readFromFileOnly);
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
        table,
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
      prefetched[k] = _readLeafPage(
        table,
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

    while (!ptr.isNull && remaining > 0) {
      if (_dataStore.shouldAbortBackgroundScan) {
        await drainPrefetch();
        return;
      }
      final y22 = yc.maybeYield();
      if (y22 != null) await y22;
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
          final pk = MemComparableKey.decodeLastText(k);
          Map<String, dynamic> row;
          if (decodeRecord) {
            final decoded = await _decodeStoredRecord(
              table: table,
              meta: meta,
              storedValue: leaf.values[i],
              fieldStruct: fieldStruct,
              allowLegacyMigrationFallback: decodeSchema == null,
              primaryKeyBytes: k,
              encryptionKey: encryptionKey,
              encryptionKeyId: encryptionKeyId,
            );
            if (decoded == null) continue;
            row = pk != null
                ? TableSchema.rowWithPrimaryKeyFirst(
                    schema.primaryKey, pk, decoded)
                : decoded;
          } else {
            if (pk == null) continue;
            row = {schema.primaryKey: pk};
          }
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
          final pk = MemComparableKey.decodeLastText(k);
          Map<String, dynamic> row;
          if (decodeRecord) {
            final decoded = await _decodeStoredRecord(
              table: table,
              meta: meta,
              storedValue: leaf.values[i],
              fieldStruct: fieldStruct,
              allowLegacyMigrationFallback: decodeSchema == null,
              primaryKeyBytes: k,
              encryptionKey: encryptionKey,
              encryptionKeyId: encryptionKeyId,
            );
            if (decoded == null) continue;
            row = pk != null
                ? TableSchema.rowWithPrimaryKeyFirst(
                    schema.primaryKey, pk, decoded)
                : decoded;
          } else {
            if (pk == null) continue;
            row = {schema.primaryKey: pk};
          }
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
  int oldFlushBatchKey = 0;
  int oldMaintBatchKey = 0;

  /// True when on-disk page0 already carries this batch's durable marker.
  bool alreadyDurableForBatch = false;

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
