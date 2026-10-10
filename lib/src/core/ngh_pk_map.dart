import 'dart:typed_data';

import '../handler/memcomparable.dart';
import '../model/data_store_config.dart';
import '../model/meta_info.dart';
import '../model/ngh_index_meta.dart';
import '../model/table_context.dart';
import '../model/table_identity.dart';
import 'btree_page.dart';
import 'ngh_page.dart';
import 'ngh_partition_manager.dart';

/// One PK-map upsert in a sorted bulk write.
final class NghPkMapWrite {
  final Uint8List key;
  final List<NghPkLocator> locators;
  final bool mergeRewritten;

  NghPkMapWrite({
    required this.key,
    required this.locators,
    this.mergeRewritten = false,
  });
}

/// In-memory PK-map node (leaf or internal) staged for flush. No page redo.
final class NghPkMapDirtyPage {
  final bool isLeaf;
  final LeafPage? leaf;
  final InternalPage? internal;

  NghPkMapDirtyPage.leaf(LeafPage page)
      : isLeaf = true,
        leaf = page,
        internal = null;

  NghPkMapDirtyPage.internal(InternalPage page)
      : isLeaf = false,
        leaf = null,
        internal = page;

  int estimatePayloadSize() => isLeaf
      ? (leaf?.estimatePayloadSize() ?? 0)
      : (internal?.estimatePayloadSize() ?? 0);

  Uint8List encodePayload() => isLeaf
      ? (leaf?.encodePayload() ?? Uint8List(0))
      : (internal?.encodePayload() ?? Uint8List(0));

  BTreePageType get pageType =>
      isLeaf ? BTreePageType.leaf : BTreePageType.internal;
}

/// Mutable PK-map write batch (dirty nodes + meta).
final class NghPkMapBatch {
  NghIndexMeta meta;
  final Map<NghPagePtr, NghPkMapDirtyPage> dirty;

  NghPkMapBatch({required this.meta, Map<NghPagePtr, NghPkMapDirtyPage>? dirty})
      : dirty = dirty ?? <NghPagePtr, NghPkMapDirtyPage>{};
}

/// Slim B+Tree of memcomparable PK → [NghPkLocator] list. No page redo.
final class NghPkMapEngine {
  final NghPartitionManager _partitions;
  final DataStoreConfig _config;

  NghPkMapEngine(this._partitions, this._config);

  int get _pageSize => _partitions.configuredPageSize;

  Future<List<NghPkLocator>> lookup({
    required TableContext table,
    required IndexUid indexUid,
    required NghPkMapBatch batch,
    required Uint8List key,
  }) async {
    final leaf = await _findLeaf(table, indexUid, batch, key);
    if (leaf == null) return const [];
    final idx = leaf.page.find(key);
    if (idx == null) return const [];
    return NghPkLocator.decodeList(leaf.page.values[idx]);
  }

  /// Sorted bulk upsert. Walks leaves forward so 10k keys do not each
  /// restart from the root (random leaf I/O would dominate 1M–10M flushes).
  Future<void> upsertSorted({
    required TableContext table,
    required IndexUid indexUid,
    required NghPkMapBatch batch,
    required List<NghPkMapWrite> entries,
    Set<int> rewrittenIds = const {},
    Set<int>? dirtyLeafKeys,
  }) async {
    if (entries.isEmpty) return;
    ({NghPagePtr ptr, LeafPage page})? cursor;
    final filterDirty = dirtyLeafKeys != null && dirtyLeafKeys.isNotEmpty;
    final filterRewrite = rewrittenIds.isNotEmpty;
    // Merge only when a filter is present — bare mergeRewritten would keep
    // every old locator and can duplicate / thrash the maxLocators cap.
    final mergeOld = filterDirty || filterRewrite;

    for (final e in entries) {
      var locs = e.locators;
      if (batch.meta.pkmapRootIsNull) {
        if (locs.length > NghPkLocator.maxLocatorsPerPk) {
          locs = locs.sublist(locs.length - NghPkLocator.maxLocatorsPerPk);
        }
        await upsert(
          table: table,
          indexUid: indexUid,
          batch: batch,
          key: e.key,
          locators: locs,
        );
        cursor = await _findLeaf(table, indexUid, batch, e.key);
        continue;
      }
      cursor = await _leafForSortedKey(
        table,
        indexUid,
        batch,
        cursor,
        e.key,
      );
      if (cursor == null) continue;
      if (mergeOld) {
        final idx = cursor.page.find(e.key);
        if (idx != null) {
          final old = NghPkLocator.decodeList(cursor.page.values[idx]);
          final merged = <NghPkLocator>[
            for (final l in old)
              if ((!filterDirty ||
                      !dirtyLeafKeys.contains(
                          (l.partitionNo << 32) | (l.pageNo & 0xFFFFFFFF))) &&
                  (!filterRewrite || !rewrittenIds.contains(l.centroidId)))
                l,
            ...locs,
          ];
          locs = merged;
        }
      }
      if (locs.length > NghPkLocator.maxLocatorsPerPk) {
        // Prefer newest locators (tail) so dual/reinsert homes are kept.
        locs = locs.sublist(locs.length - NghPkLocator.maxLocatorsPerPk);
      }
      cursor.page.upsert(e.key, NghPkLocator.encodeList(locs));
      batch.dirty[cursor.ptr] = NghPkMapDirtyPage.leaf(cursor.page);
      if (_fits(cursor.page.estimatePayloadSize())) continue;
      await _splitLeaf(table, indexUid, batch, cursor.ptr, cursor.page);
      cursor = await _findLeaf(table, indexUid, batch, e.key);
    }
  }

  Future<void> upsert({
    required TableContext table,
    required IndexUid indexUid,
    required NghPkMapBatch batch,
    required Uint8List key,
    required List<NghPkLocator> locators,
  }) async {
    final value = NghPkLocator.encodeList(locators);
    if (batch.meta.pkmapRootIsNull) {
      final (ptr, meta) = _partitions.allocatePagesBatchSync(
        NghDataCategory.pkmap,
        batch.meta,
        1,
      );
      batch.meta = meta.copyWith(
        pkmapRootPartition: ptr.first.partitionNo,
        pkmapRootPage: ptr.first.pageNo,
        pkmapHeight: 1,
      );
      final leaf = LeafPage.empty();
      leaf.upsert(key, value);
      batch.dirty[ptr.first] = NghPkMapDirtyPage.leaf(leaf);
      return;
    }
    final found = await _findLeaf(table, indexUid, batch, key);
    if (found == null) return;
    found.page.upsert(key, value);
    batch.dirty[found.ptr] = NghPkMapDirtyPage.leaf(found.page);
    if (_fits(found.page.estimatePayloadSize())) return;
    await _splitLeaf(table, indexUid, batch, found.ptr, found.page);
  }

  Future<void> remove({
    required TableContext table,
    required IndexUid indexUid,
    required NghPkMapBatch batch,
    required Uint8List key,
  }) async {
    if (batch.meta.pkmapRootIsNull) return;
    final found = await _findLeaf(table, indexUid, batch, key);
    if (found == null) return;
    if (!found.page.delete(key)) return;
    batch.dirty[found.ptr] = NghPkMapDirtyPage.leaf(found.page);
  }

  bool _fits(int plainLen) => BTreePageSizer.fitsInPage(
        pageSize: _pageSize,
        plainPayloadLen: plainLen,
        config: _config,
      );

  bool _keyFitsLeaf(LeafPage leaf, Uint8List key) {
    if (leaf.highKey.isEmpty) return true;
    return MemComparableKey.compare(key, leaf.highKey) <= 0;
  }

  Future<({NghPagePtr ptr, LeafPage page})?> _leafForSortedKey(
    TableContext table,
    IndexUid indexUid,
    NghPkMapBatch batch,
    ({NghPagePtr ptr, LeafPage page})? cursor,
    Uint8List key,
  ) async {
    var cur = cursor;
    while (cur != null && !_keyFitsLeaf(cur.page, key)) {
      final next = cur.page.next;
      if (next.isNull) break;
      final ptr = NghPagePtr(
        NghDataCategory.pkmap,
        next.partitionNo,
        next.pageNo,
      );
      final node = await _load(table, indexUid, batch, ptr);
      if (node == null || !node.isLeaf || node.leaf == null) {
        cur = null;
        break;
      }
      cur = (ptr: ptr, page: node.leaf!);
    }
    if (cur != null && _keyFitsLeaf(cur.page, key)) return cur;
    return _findLeaf(table, indexUid, batch, key);
  }

  Future<({NghPagePtr ptr, LeafPage page})?> _findLeaf(
    TableContext table,
    IndexUid indexUid,
    NghPkMapBatch batch,
    Uint8List key,
  ) async {
    var part = batch.meta.pkmapRootPartition;
    var pageNo = batch.meta.pkmapRootPage;
    var height = batch.meta.pkmapHeight;
    if (part < 0 || pageNo <= 0 || height <= 0) return null;

    for (int level = height; level > 1; level--) {
      final ptr = NghPagePtr(NghDataCategory.pkmap, part, pageNo);
      final node = await _load(table, indexUid, batch, ptr);
      if (node == null || node.isLeaf || node.internal == null) return null;
      final child =
          node.internal!.children[node.internal!.childIndexForKey(key)];
      if (child.isNull) return null;
      part = child.partitionNo;
      pageNo = child.pageNo;
    }
    final leafPtr = NghPagePtr(NghDataCategory.pkmap, part, pageNo);
    final node = await _load(table, indexUid, batch, leafPtr);
    if (node == null || !node.isLeaf || node.leaf == null) return null;
    return (ptr: leafPtr, page: node.leaf!);
  }

  Future<NghPkMapDirtyPage?> _load(
    TableContext table,
    IndexUid indexUid,
    NghPkMapBatch batch,
    NghPagePtr ptr,
  ) async {
    final dirty = batch.dirty[ptr];
    if (dirty != null) return dirty;
    return _partitions.readPkmapPage(table, indexUid, ptr);
  }

  Future<void> _splitLeaf(
    TableContext table,
    IndexUid indexUid,
    NghPkMapBatch batch,
    NghPagePtr leftPtr,
    LeafPage left,
  ) async {
    final split = left.split();
    final (rightPtrs, metaAfter) = _partitions.allocatePagesBatchSync(
      NghDataCategory.pkmap,
      batch.meta,
      1,
    );
    batch.meta = metaAfter;
    final rightPtr = rightPtrs.first;
    split.right.prev = TreePagePtr(leftPtr.partitionNo, leftPtr.pageNo);
    split.right.next = left.next;
    left.next = TreePagePtr(rightPtr.partitionNo, rightPtr.pageNo);
    batch.dirty[leftPtr] = NghPkMapDirtyPage.leaf(left);
    batch.dirty[rightPtr] = NghPkMapDirtyPage.leaf(split.right);

    if (batch.meta.pkmapHeight <= 1) {
      final (rootPtrs, meta2) = _partitions.allocatePagesBatchSync(
        NghDataCategory.pkmap,
        batch.meta,
        1,
      );
      batch.meta = meta2;
      final root = InternalPage.empty();
      root.maxKeys.add(split.leftMaxKey);
      root.children.add(TreePagePtr(leftPtr.partitionNo, leftPtr.pageNo));
      root.maxKeys.add(Uint8List(0));
      root.children.add(TreePagePtr(rightPtr.partitionNo, rightPtr.pageNo));
      batch.dirty[rootPtrs.first] = NghPkMapDirtyPage.internal(root);
      batch.meta = batch.meta.copyWith(
        pkmapRootPartition: rootPtrs.first.partitionNo,
        pkmapRootPage: rootPtrs.first.pageNo,
        pkmapHeight: 2,
      );
      return;
    }
    await _insertInternal(
      table,
      indexUid,
      batch,
      split.leftMaxKey,
      leftPtr,
      rightPtr,
      parentHeight: batch.meta.pkmapHeight - 1,
    );
  }

  Future<void> _insertInternal(
    TableContext table,
    IndexUid indexUid,
    NghPkMapBatch batch,
    Uint8List leftMaxKey,
    NghPagePtr left,
    NghPagePtr right, {
    required int parentHeight,
  }) async {
    // Walk from root to the internal parent of [left].
    var part = batch.meta.pkmapRootPartition;
    var pageNo = batch.meta.pkmapRootPage;
    NghPagePtr? parentPtr;
    InternalPage? parent;
    for (int level = batch.meta.pkmapHeight; level > parentHeight; level--) {
      final ptr = NghPagePtr(NghDataCategory.pkmap, part, pageNo);
      final node = await _load(table, indexUid, batch, ptr);
      if (node == null || node.internal == null) return;
      parentPtr = ptr;
      parent = node.internal;
      final child = parent!.children[parent.childIndexForKey(leftMaxKey)];
      part = child.partitionNo;
      pageNo = child.pageNo;
    }
    if (parentPtr == null || parent == null) return;

    final idx = parent.childIndexForKey(leftMaxKey);
    parent.setEntry(
        idx, leftMaxKey, TreePagePtr(left.partitionNo, left.pageNo));
    parent.insertEntry(
        idx + 1,
        idx + 1 < parent.maxKeys.length
            ? parent.maxKeys[idx + 1]
            : Uint8List(0),
        TreePagePtr(right.partitionNo, right.pageNo));
    // High-key of the right sibling should keep the previous boundary.
    batch.dirty[parentPtr] = NghPkMapDirtyPage.internal(parent);
    if (_fits(parent.estimatePayloadSize())) return;

    final split = parent.split();
    final (newPtrs, metaAfter) = _partitions.allocatePagesBatchSync(
      NghDataCategory.pkmap,
      batch.meta,
      1,
    );
    batch.meta = metaAfter;
    final newPtr = newPtrs.first;
    batch.dirty[parentPtr] = NghPkMapDirtyPage.internal(parent);
    batch.dirty[newPtr] = NghPkMapDirtyPage.internal(split.right);

    if (parentHeight + 1 >= batch.meta.pkmapHeight) {
      final (rootPtrs, meta2) = _partitions.allocatePagesBatchSync(
        NghDataCategory.pkmap,
        batch.meta,
        1,
      );
      batch.meta = meta2;
      final root = InternalPage.empty();
      root.maxKeys.add(split.leftMaxKey);
      root.children.add(TreePagePtr(parentPtr.partitionNo, parentPtr.pageNo));
      root.maxKeys.add(Uint8List(0));
      root.children.add(TreePagePtr(newPtr.partitionNo, newPtr.pageNo));
      batch.dirty[rootPtrs.first] = NghPkMapDirtyPage.internal(root);
      batch.meta = batch.meta.copyWith(
        pkmapRootPartition: rootPtrs.first.partitionNo,
        pkmapRootPage: rootPtrs.first.pageNo,
        pkmapHeight: batch.meta.pkmapHeight + 1,
      );
    } else {
      await _insertInternal(
        table,
        indexUid,
        batch,
        split.leftMaxKey,
        parentPtr,
        newPtr,
        parentHeight: parentHeight + 1,
      );
    }
  }
}
