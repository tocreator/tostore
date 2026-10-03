import 'dart:math';

import '../../core/btree_page.dart';
import '../../core/data_store_impl.dart';
import '../../core/ngh_page.dart';
import '../../core/ngh_partition_manager.dart';
import '../../core/tree_meta_page.dart';
import '../../handler/common.dart';
import '../../handler/logger.dart';
import '../../handler/meta_binary_codec.dart';
import '../../handler/parallel_processor.dart';
import '../../model/db_exception.dart';
import '../../model/ngh_index_meta.dart';
import '../../model/table_context.dart';
import '../../model/table_identity.dart';
import 'legacy_ngh_paths.dart';

/// Page I/O for engine-v3 vector files under `ngh_old/` (16KB pages).
///
/// Independent of live hierarchical-nav caches. Used only by [LegacyNghSearch].
final class LegacyNghIo {
  final DataStoreImpl _dataStore;

  LegacyNghIo(this._dataStore);

  /// Online v3 posting files used the database 16KB page.
  int get configuredPageSize => InternalConfig.defaultPageSize;

  int _pageSize(NghIndexMeta? meta) {
    final stored = meta?.leafPageSize ?? 0;
    return stored > 0 ? stored : InternalConfig.defaultPageSize;
  }

  Future<bool> hasOldIndex(TableContext table, IndexUid indexUid) async {
    final nav =
        LegacyNghPaths.navGraphBlob(_dataStore.pathManager, table, indexUid);
    if (await _dataStore.storage.existsFile(nav)) return true;
    final p0 = LegacyNghPaths.postingPartition(_dataStore, table, indexUid, 0);
    return _dataStore.storage.existsFile(p0);
  }

  Future<void> deleteOldIndex(TableContext table, IndexUid indexUid) async {
    final root =
        LegacyNghPaths.oldIndexRoot(_dataStore.pathManager, table, indexUid);
    if (await _dataStore.storage.existsDirectory(root)) {
      await _dataStore.storage.deleteDirectory(root);
    }
  }

  Future<NghIndexMeta?> readMeta(TableContext table, IndexUid indexUid) async {
    final path =
        LegacyNghPaths.postingPartition(_dataStore, table, indexUid, 0);
    try {
      final pageSize = InternalConfig.defaultPageSize;
      final raw =
          await _dataStore.storage.readAsBytesAt(path, 0, length: pageSize);
      if (raw.isEmpty) return null;
      final parsed = BTreePageIO.parsePageBytes(raw);
      final plain = BTreePageCodec.decodePayload(parsed.encodedPayload);
      final payload = TreeMetaPagePayload.tryDecodePlainPayload(plain);
      if (payload?.treeGlobalMeta == null) return null;
      final blob = TreeGlobalMetaBlobCodec.decode(payload!.treeGlobalMeta!);
      if (blob == null || blob.kind != TreeGlobalMetaKind.ngh) return null;
      return NghIndexMetaCodec.decode(
        blob.payload,
        tableUidFallback: table.tableUid,
        indexUidFallback: indexUid,
      );
    } catch (e) {
      if (e is DbClosedException) rethrow;
      Logger.warn(
        'Failed to read engine-v3 NGH meta under ngh_old for index "$indexUid"',
        rawError: e,
      );
      return null;
    }
  }

  Future<NghNavGraphPage?> readNavGraph(
    TableContext table,
    IndexUid indexUid,
  ) async {
    final path =
        LegacyNghPaths.navGraphBlob(_dataStore.pathManager, table, indexUid);
    try {
      final bytes = await _dataStore.storage.readAsBytes(path);
      if (bytes.isEmpty) return null;
      if (bytes.length >= 20 && bytes[0] == 0x54 && bytes[1] == 0x53) {
        try {
          final parsed = BTreePageIO.parsePageBytes(bytes);
          final page = NghNavGraphPage.tryDecodePayload(
            BTreePageCodec.decodePayload(parsed.encodedPayload),
          );
          if (page != null) return page;
        } catch (_) {}
      }
      return NghNavGraphPage.tryDecodePayload(bytes);
    } catch (e) {
      if (e is DbClosedException) rethrow;
      return null;
    }
  }

  Future<NghLeafPage?> readPostingPage(
    TableContext table,
    IndexUid indexUid,
    NghIndexMeta meta,
    int partitionNo,
    int pageNo, {
    Map<int, NghLeafPage>? localCache,
  }) async {
    if (pageNo <= 0) return null;
    final cacheKey = NghPagePtr.packRef(partitionNo, pageNo);
    if (localCache != null) {
      final hit = localCache[cacheKey];
      if (hit != null) return hit;
    }
    final path = LegacyNghPaths.postingPartition(
        _dataStore, table, indexUid, partitionNo);
    try {
      final pageSize = _pageSize(meta);
      final raw = await _dataStore.storage
          .readAsBytesAt(path, pageNo * pageSize, length: pageSize);
      if (raw.isEmpty) return null;
      final parsed = BTreePageIO.parsePageBytes(raw);
      final page = NghLeafPage.tryDecodePayload(
        BTreePageCodec.decodePayload(parsed.encodedPayload),
      );
      if (page != null && localCache != null) {
        localCache[cacheKey] = page;
      }
      return page;
    } catch (e) {
      if (e is DbClosedException) rethrow;
      return null;
    }
  }

  Future<List<({int packedRef, NghLeafPage page})>> readPostingPagesBatch(
    TableContext table,
    IndexUid indexUid,
    NghIndexMeta meta,
    List<int> packedRefs, {
    Map<int, NghLeafPage>? localCache,
    bool populatePageCache = true,
  }) async {
    if (packedRefs.isEmpty) return const [];
    final results = <({int packedRef, NghLeafPage page})>[];
    final byPart = <int, List<int>>{};
    for (final packed in packedRefs) {
      if (packed <= 0) continue;
      final (part, pageNo) = NghPagePtr.unpackRef(packed);
      if (pageNo <= 0) continue;
      byPart.putIfAbsent(part < 0 ? 0 : part, () => []).add(packed);
    }
    Future<List<({int packedRef, NghLeafPage page})>> readOne(
        int part, List<int> refs) async {
      final out = <({int packedRef, NghLeafPage page})>[];
      for (final packed in refs) {
        final (_, pageNo) = NghPagePtr.unpackRef(packed);
        final page = await readPostingPage(
          table,
          indexUid,
          meta,
          part,
          pageNo,
          localCache: localCache,
        );
        if (page != null) {
          out.add((packedRef: packed, page: page));
        }
      }
      return out;
    }

    if (byPart.length == 1) {
      final entry = byPart.entries.first;
      return readOne(entry.key, entry.value);
    }
    final tasks = [
      for (final e in byPart.entries) () => readOne(e.key, e.value),
    ];
    final parts = await ParallelProcessor.execute<
        List<({int packedRef, NghLeafPage page})>>(
      tasks,
      concurrency: min(5, tasks.length),
      label: 'legacyNghReadPagesBatch',
    );
    for (final partList in parts) {
      if (partList != null) results.addAll(partList);
    }
    return results;
  }

  Future<List<({int packedRef, NghLeafPage page})>> readPostingCluster(
    TableContext table,
    IndexUid indexUid,
    NghIndexMeta meta,
    int headPackedRef, {
    Map<int, NghLeafPage>? localCache,
  }) async {
    if (headPackedRef <= 0) return const [];
    final pages = <({int packedRef, NghLeafPage page})>[];
    var current = headPackedRef;
    final visited = <int>{};
    while (current > 0 && visited.add(current) && visited.length < 4096) {
      final (part, pageNo) = NghPagePtr.unpackRef(current);
      if (pageNo <= 0) break;
      final page = await readPostingPage(
        table,
        indexUid,
        meta,
        part < 0 ? 0 : part,
        pageNo,
        localCache: localCache,
      );
      if (page == null) break;
      pages.add((packedRef: current, page: page));
      current = page.nextLeafPageNo;
    }
    return pages;
  }

  Future<List<List<({int packedRef, NghLeafPage page})>>>
      readPostingClustersBatch(
    TableContext table,
    IndexUid indexUid,
    NghIndexMeta meta,
    List<int> chainHeads,
  ) async {
    if (chainHeads.isEmpty) return const [];
    final tasks = [
      for (final head in chainHeads)
        () => readPostingCluster(table, indexUid, meta, head),
    ];
    final res = await ParallelProcessor.execute<
        List<({int packedRef, NghLeafPage page})>>(
      tasks,
      concurrency: min(5, tasks.length),
      label: 'legacyNghReadClustersBatch',
    );
    return [
      for (final chain in res)
        if (chain != null) chain,
    ];
  }
}
