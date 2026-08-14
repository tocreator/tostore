import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../handler/encryption.dart';
import '../handler/meta_binary_codec.dart';
import '../model/data_store_config.dart';
import '../model/db_exception.dart';
import '../model/meta_info.dart';
import '../model/ngh_index_meta.dart';
import '../model/parallel_journal_entry.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/table_identity.dart';
import 'btree_page.dart';
import 'data_store_impl.dart';
import 'page_redo_log_codec.dart';
import 'storage_adapter.dart';
import 'tree_meta_page.dart';

/// Unified read/write path for partition page 0 (local stats + optional global meta).
///
/// All encryption/decryption and AAD construction is centralized here so table,
/// index, and vector managers stay consistent.
///
/// **Encryption:** When [encryptionKey] / [encryptionKeyId] are omitted, keys are
/// taken from [EncryptionManager.getCurrentEncodingState] at call time (main-isolate
/// global state, including [EncoderConfig.fallbackKeys] for decoding older pages).
/// This service does not run in compute isolates; batch data-page encode uses a
/// separate [EncoderConfig] snapshot -- page-0 meta in the same [writeChanges] should
/// pass the same [encryptionKey] / [encryptionKeyId] as sibling B+Tree pages when a
/// non-default key is required.
final class TreeMetaPageService {
  final DataStoreImpl _dataStore;
  DataStoreConfig get _config => _dataStore.config;
  StorageAdapter get _storage => _dataStore.storage;

  TreeMetaPageService(this._dataStore);

  // ---------------------------------------------------------------------------
  // Global meta -- table
  // ---------------------------------------------------------------------------

  Future<TableDataMeta?> readTableGlobalMeta(TableUid tableUid) async {
    final parsed = await _readPayload(
      partitionPath:
          await _dataStore.pathManager.getPartitionFilePathByNo(tableUid, 0),
      partitionNo: 0,
      pageType: BTreePageType.meta,
    );
    if (parsed == null || parsed.treeGlobalMeta == null) return null;
    final blob = TreeGlobalMetaBlobCodec.decode(parsed.treeGlobalMeta!);
    if (blob == null || blob.kind != TreeGlobalMetaKind.table) return null;
    return TableDataMetaCodec.decode(
      blob.payload,
      tableUidFallback: tableUid,
    );
  }

  Future<void> persistTableGlobalMeta({
    required TableUid tableUid,
    required TableDataMeta meta,
    PartitionLocalStats? partitionLocalOverride,
    BatchContext? batchContext,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool flush = true,
  }) async {
    final pageSize = _requireConfiguredPageSize();
    final path =
        await _dataStore.pathManager.getPartitionFilePathByNo(tableUid, 0);
    final local = partitionLocalOverride ??
        (await readPartitionLocal(
          path: path,
          partitionNo: 0,
          pageType: BTreePageType.meta,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
        )) ??
        PartitionLocalStats(partitionNo: 0);

    final globalBlob = TreeGlobalMetaBlobCodec.encode(
      TreeGlobalMetaKind.table,
      TableDataMetaCodec.encode(meta),
    );
    await _writePage0WithRedoBatch(
      tableUid: tableUid,
      batchContext: batchContext,
      write: (ctx, {required bool ownedBatch}) => writePartitionPage0(
        path: path,
        pageSize: pageSize,
        partitionNo: 0,
        pageType: BTreePageType.meta,
        partitionLocal: _applyBatchMarkers(local, ctx),
        treeGlobalMeta: globalBlob,
        batchContext: ctx,
        pageRedoTreeKind: PageRedoTreeKind.table,
        pageRedoTableUid: tableUid,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        flush: flush || ownedBatch,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Global meta -- index B+Tree
  // ---------------------------------------------------------------------------

  Future<IndexMeta?> readIndexGlobalMeta(
    TableUid tableUid,
    IndexUid indexUid,
  ) async {
    final path = await _dataStore.pathManager
        .getIndexPartitionPathByNo(tableUid, indexUid, 0);
    final parsed = await _readPayload(
      partitionPath: path,
      partitionNo: 0,
      pageType: BTreePageType.meta,
    );
    if (parsed == null || parsed.treeGlobalMeta == null) return null;
    final blob = TreeGlobalMetaBlobCodec.decode(parsed.treeGlobalMeta!);
    if (blob == null || blob.kind != TreeGlobalMetaKind.indexTree) return null;
    return IndexMetaCodec.decode(
      blob.payload,
      tableUidFallback: tableUid,
      indexUidFallback: indexUid,
    );
  }

  Future<void> persistIndexGlobalMeta({
    required TableUid tableUid,
    required IndexUid indexUid,
    required IndexMeta meta,
    PartitionLocalStats? partitionLocalOverride,
    BatchContext? batchContext,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool flush = true,
  }) async {
    final pageSize = _requireConfiguredPageSize();
    final path = await _dataStore.pathManager
        .getIndexPartitionPathByNo(tableUid, indexUid, 0);
    final local = partitionLocalOverride ??
        (await readPartitionLocal(
          path: path,
          partitionNo: 0,
          pageType: BTreePageType.meta,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
        )) ??
        PartitionLocalStats(partitionNo: 0);

    final globalBlob = TreeGlobalMetaBlobCodec.encode(
      TreeGlobalMetaKind.indexTree,
      IndexMetaCodec.encode(meta),
    );
    await _writePage0WithRedoBatch(
      tableUid: tableUid,
      batchContext: batchContext,
      write: (ctx, {required bool ownedBatch}) => writePartitionPage0(
        path: path,
        pageSize: pageSize,
        partitionNo: 0,
        pageType: BTreePageType.meta,
        partitionLocal: _applyBatchMarkers(local, ctx),
        treeGlobalMeta: globalBlob,
        batchContext: ctx,
        pageRedoTreeKind: PageRedoTreeKind.indexTree,
        pageRedoTableUid: tableUid,
        pageRedoIndexUid: indexUid,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        flush: flush || ownedBatch,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Global meta -- NGH vector (stored on graph partition 0 page 0)
  // ---------------------------------------------------------------------------

  Future<NghIndexMeta?> readNghGlobalMeta(
    TableUid tableUid,
    IndexUid indexUid,
  ) async {
    final path = await _dataStore.pathManager
        .getNghGraphPartitionPath(tableUid, indexUid, 0);
    final parsed = await _readPayload(
      partitionPath: path,
      partitionNo: 0,
      pageType: BTreePageType.nghMeta,
    );
    if (parsed == null || parsed.treeGlobalMeta == null) return null;
    final blob = TreeGlobalMetaBlobCodec.decode(parsed.treeGlobalMeta!);
    if (blob == null || blob.kind != TreeGlobalMetaKind.ngh) return null;
    return NghIndexMetaCodec.decode(
      blob.payload,
      tableUidFallback: tableUid,
      indexUidFallback: indexUid,
    );
  }

  Future<void> persistNghGlobalMeta({
    required TableUid tableUid,
    required IndexUid indexUid,
    required NghIndexMeta meta,
    PartitionLocalStats? partitionLocalOverride,
    BatchContext? batchContext,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool flush = true,
  }) async {
    final pageSize = _requireConfiguredPageSize();
    final path = await _dataStore.pathManager
        .getNghGraphPartitionPath(tableUid, indexUid, 0);
    final local = partitionLocalOverride ??
        (await readPartitionLocal(
          path: path,
          partitionNo: 0,
          pageType: BTreePageType.nghMeta,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
        )) ??
        const PartitionLocalStats(partitionNo: 0, dataCategory: 0);

    final globalBlob = TreeGlobalMetaBlobCodec.encode(
      TreeGlobalMetaKind.ngh,
      NghIndexMetaCodec.encode(meta),
    );
    await _writePage0WithRedoBatch(
      tableUid: tableUid,
      batchContext: batchContext,
      write: (ctx, {required bool ownedBatch}) => writePartitionPage0(
        path: path,
        pageSize: pageSize,
        partitionNo: 0,
        pageType: BTreePageType.nghMeta,
        partitionLocal: _applyBatchMarkers(local, ctx),
        treeGlobalMeta: globalBlob,
        batchContext: ctx,
        pageRedoTreeKind: PageRedoTreeKind.ngh,
        pageRedoTableUid: tableUid,
        pageRedoIndexUid: indexUid,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        flush: flush || ownedBatch,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Partition-local stats (all partition files)
  // ---------------------------------------------------------------------------

  /// Read partition-local stats from page 0.
  ///
  /// Prefers a single full-page IO when [DataStoreImpl.hasConfiguredPageSize];
  /// otherwise falls back to two-phase IO (header -> payload) for upgrade /
  /// bootstrap before GlobalConfig.pageSize is known.
  Future<PartitionLocalStats?> readPartitionLocal({
    required String path,
    required int partitionNo,
    required BTreePageType pageType,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    final parsed = await _readPayload(
      partitionPath: path,
      partitionNo: partitionNo,
      pageType: pageType,
      encryptionKey: encryptionKey,
      encryptionKeyId: encryptionKeyId,
    );
    return parsed?.partitionLocal;
  }

  /// Build encrypted page-0 bytes for staging inside batch flush loops.
  Uint8List buildPartitionPage0Bytes({
    required int pageSize,
    required int partitionNo,
    required BTreePageType pageType,
    required PartitionLocalStats partitionLocal,
    Uint8List? treeGlobalMeta,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) {
    final payload = TreeMetaPagePayload(
      partitionLocal: partitionLocal,
      treeGlobalMeta: treeGlobalMeta,
    ).encodePlainPayload();
    final keys = _resolveEncryptionKeys(encryptionKey, encryptionKeyId);
    final encoded = BTreePageCodec.encodePayload(
      payload,
      config: _config,
      encryptionKey: keys.key,
      encryptionKeyId: keys.keyId,
      aad: _aad(partitionNo, pageType),
    );
    return BTreePageIO.buildPageBytes(
      type: pageType,
      encodedPayload: encoded,
      pageSize: pageSize,
    );
  }

  /// Apply flush/maintenance durable markers onto partition-local stats.
  PartitionLocalStats _applyBatchMarkers(
    PartitionLocalStats local,
    BatchContext? ctx,
  ) {
    if (ctx == null || ctx.batchId.isEmpty) return local;
    return local.withBatchMarkers(
      isMaintenance: ctx.batchType == BatchType.maintenance,
      batchId: ctx.batchId,
      preservedFlushKey: local.lastFlushBatchKey,
      preservedMaintKey: local.lastMaintenanceBatchKey,
    );
  }

  /// Write page 0 under a recovery-visible batch when needed.
  ///
  /// Uses [ParallelJournalManager.runWithPageRedoBatch]: existing flush/
  /// maintenance batches are reused; otherwise a short-lived maintenance batch
  /// is registered so `page_redo_$batchId.log` can be found via
  /// `pendingBatches` after a crash.
  Future<void> _writePage0WithRedoBatch({
    required TableUid tableUid,
    required BatchContext? batchContext,
    required Future<void> Function(BatchContext? ctx,
            {required bool ownedBatch})
        write,
  }) async {
    final table = await _dataStore.tableMetaManager?.getTableContext(tableUid);
    if (table == null) {
      // Cannot register a pending batch without a table context.
      await write(batchContext, ownedBatch: false);
      return;
    }
    await _dataStore.parallelJournalManager.runWithPageRedoBatch(
      table: table,
      batchContext: batchContext,
      action: write,
    );
  }

  Future<void> writePartitionPage0({
    required String path,
    required int pageSize,
    required int partitionNo,
    required BTreePageType pageType,
    required PartitionLocalStats partitionLocal,
    Uint8List? treeGlobalMeta,
    BatchContext? batchContext,
    PageRedoTreeKind? pageRedoTreeKind,
    TableUid? pageRedoTableUid,
    IndexUid? pageRedoIndexUid,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    bool flush = true,
  }) async {
    final pageBytes = buildPartitionPage0Bytes(
      pageSize: pageSize,
      partitionNo: partitionNo,
      pageType: pageType,
      partitionLocal: partitionLocal,
      treeGlobalMeta: treeGlobalMeta,
      encryptionKey: encryptionKey,
      encryptionKeyId: encryptionKeyId,
    );

    // Redo is only valid when backed by a pending batch in WAL meta.
    // Prefer explicit BatchContext, else active flush/maintenance batch.
    // Do NOT invent an unregistered batchId -- recovery cannot discover it.
    final resolvedBatchId = _resolveRegisteredBatchId(batchContext);
    if (resolvedBatchId != null &&
        pageRedoTreeKind != null &&
        pageRedoTableUid != null) {
      final redoPath = _dataStore.pathManager.getPageRedoLogPath(
        resolvedBatchId,
        spaceName: _dataStore.currentSpaceName,
      );
      await _storage.ensureDirectoryExists(p.dirname(redoPath));
      final rec = PageRedoLogCodec.encodePageRecord(
        treeKind: pageRedoTreeKind,
        tableUid: pageRedoTableUid,
        indexUid: pageRedoIndexUid,
        partitionNo: partitionNo,
        pageNo: 0,
        payload: pageBytes,
      );
      await _storage.appendBytes(redoPath, rec, flush: true);
    }

    await _storage.ensureDirectoryExists(p.dirname(path));
    await _storage.writeAsBytesAt(path, 0, pageBytes, flush: flush);
  }

  /// Batch id usable for page redo: must already be in WAL `pendingBatches`
  /// (or currently active under that registration). Empty / invented ids are
  /// rejected -- orphan `page_redo_*.log` files are not a recovery signal.
  String? _resolveRegisteredBatchId(BatchContext? batchContext) {
    if (!_config.enableJournal) return null;
    if (batchContext != null && batchContext.batchId.isNotEmpty) {
      return batchContext.batchId;
    }
    final active = _dataStore.parallelJournalManager.activeBatchContext;
    if (active != null && active.batchId.isNotEmpty) {
      return active.batchId;
    }
    return null;
  }

  /// Parse partition-local stats from a full on-disk page image.
  PartitionLocalStats? parsePartitionLocalFromPageBytes(
    Uint8List pageBytes, {
    required int partitionNo,
    required BTreePageType pageType,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) {
    if (pageBytes.isEmpty) return null;
    try {
      final parsedPage = BTreePageIO.parsePageBytes(pageBytes);
      final plain = _decodePayloadAlways(
        parsedPage.encodedPayload,
        partitionNo: partitionNo,
        pageType: pageType,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
      );
      return TreeMetaPagePayload.tryDecodePlainPayload(plain)?.partitionLocal;
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Page size for writing padded page-0 images. Must never be 0.
  int _requireConfiguredPageSize() {
    final pageSize = _dataStore.configuredPageSize;
    if (pageSize <= 0) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'Invalid configured page size: $pageSize. '
              'GlobalConfig.pageSize must be set before writing tree meta pages.',
        ),
      ]);
    }
    return pageSize;
  }

  /// Read and decode page 0.
  ///
  /// Page layout is `[BTreePageHeader][encodedPayload][zero padding to pageSize]`.
  ///
  /// - When [DataStoreImpl.hasConfiguredPageSize]: one IO of the full padded
  ///   page (normal path; page size is immutable and known).
  /// - Otherwise: two-phase IO (fixed header -> [BTreePageHeader.payloadLen])
  ///   so v3 / bootstrap can decode meta before GlobalConfig.pageSize exists.
  Future<TreeMetaPagePayload?> _readPayload({
    required String partitionPath,
    required int partitionNo,
    required BTreePageType pageType,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) async {
    if (!await _storage.existsFile(partitionPath)) return null;

    if (_dataStore.hasConfiguredPageSize) {
      final pageBytes = await _storage.readAsBytesAt(
        partitionPath,
        0,
        length: _dataStore.configuredPageSize,
      );
      if (pageBytes.isEmpty) return null;
      try {
        final parsedPage = BTreePageIO.parsePageBytes(pageBytes);
        final plain = _decodePayloadAlways(
          parsedPage.encodedPayload,
          partitionNo: partitionNo,
          pageType: pageType,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
        );
        return TreeMetaPagePayload.tryDecodePlainPayload(plain);
      } catch (_) {
        return null;
      }
    }

    // Bootstrap / legacy: page size not yet in GlobalConfig.
    final headerBytes = await _storage.readAsBytesAt(
      partitionPath,
      0,
      length: BTreePageHeader.size,
    );
    if (headerBytes.length < BTreePageHeader.size) return null;

    final header = BTreePageHeader.tryDecode(headerBytes);
    if (header == null || header.payloadLen <= 0) return null;

    final encodedPayload = await _storage.readAsBytesAt(
      partitionPath,
      BTreePageHeader.size,
      length: header.payloadLen,
    );
    if (encodedPayload.length != header.payloadLen) return null;

    try {
      final parsedPage = BTreePageIO.parseHeaderAndPayload(
        header: header,
        encodedPayload: encodedPayload,
      );
      final plain = _decodePayloadAlways(
        parsedPage.encodedPayload,
        partitionNo: partitionNo,
        pageType: pageType,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
      );
      return TreeMetaPagePayload.tryDecodePlainPayload(plain);
    } catch (_) {
      return null;
    }
  }

  Uint8List _decodePayloadAlways(
    Uint8List encoded, {
    required int partitionNo,
    required BTreePageType pageType,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  }) {
    final keys = _resolveEncryptionKeys(encryptionKey, encryptionKeyId);
    return BTreePageCodec.decodePayload(
      encoded,
      encryptionKey: keys.key,
      encryptionKeyId: keys.keyId,
      aad: _aad(partitionNo, pageType),
    );
  }

  ({Uint8List key, int keyId}) _resolveEncryptionKeys(
    Uint8List? encryptionKey,
    int? encryptionKeyId,
  ) {
    if (encryptionKey != null) {
      return (
        key: encryptionKey,
        keyId: encryptionKeyId ?? EncryptionManager.getCurrentKeyId(),
      );
    }
    final state = EncryptionManager.getCurrentEncodingState();
    return (key: state.activeKey, keyId: state.keyId);
  }

  Uint8List _aad(int partitionNo, BTreePageType type) {
    final bd = ByteData(9);
    bd.setInt32(0, partitionNo, Endian.little);
    bd.setInt32(4, 0, Endian.little);
    bd.setUint8(8, type.index);
    return bd.buffer.asUint8List();
  }
}
