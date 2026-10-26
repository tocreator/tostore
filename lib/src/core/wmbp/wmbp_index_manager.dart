import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../handler/logger.dart';
import '../../handler/parallel_processor.dart';
import '../../interface/storage_interface.dart';
import '../../model/data_store_config.dart';
import '../../model/db_exception.dart';
import '../../model/index_entry.dart'; // IndexRecordUpdate
import '../../model/parallel_journal_entry.dart';
import '../../model/result_status.dart';
import '../../model/result_type.dart';
import '../../model/sparse_vector_data.dart';
import '../../model/table_context.dart';
import '../../model/table_identity.dart';
import '../../model/table_schema.dart';
import '../../model/text_query.dart';
import '../compute/workload_scheduler.dart';
import '../compute/yield_controller.dart';
import '../engine/data_store_impl.dart';
import '../storage/store_page.dart';
import '../txn/page_redo_log_codec.dart';
import 'wmbp_constants.dart';
import 'wmbp_index.dart';
import 'wmbp_scheduler.dart';
import 'wmbp_store.dart';

/// Per-index WMBP runtime: pending visibility, seal, and page snapshot I/O.
class WmbpIndexManager {
  final DataStoreImpl _dataStore;
  final Map<String, WmbpCorpus> _corpora = <String, WmbpCorpus>{};
  final Map<String, Future<WmbpCorpus>> _inFlight =
      <String, Future<WmbpCorpus>>{};
  final Map<String, _WmbpStorageVolume> _volumes =
      <String, _WmbpStorageVolume>{};

  WmbpIndexManager(this._dataStore);

  List<WmbpHit>? searchTextSync({
    required TableContext table,
    required String fieldName,
    required TextQuery query,
    required int topK,
    TextMatchOperator operator = TextMatchOperator.or,
  }) {
    final index = _findIndex(table.schema, fieldName, IndexType.text);
    if (index == null) return const <WmbpHit>[];
    final key = _key(table, index);
    final corpus = _corpora[key];
    if (corpus == null) return null;
    return corpus.searchTextSync(query, topK: topK, operator: operator);
  }

  Future<List<WmbpHit>> searchText({
    required TableContext table,
    required String fieldName,
    required TextQuery query,
    required int topK,
    TextMatchOperator operator = TextMatchOperator.or,
  }) {
    final index = _findIndex(table.schema, fieldName, IndexType.text);
    if (index == null) return Future.value(const <WmbpHit>[]);
    final key = _key(table, index);
    final corpus = _corpora[key];
    if (corpus != null) {
      return corpus.prefersPagedSearch
          ? corpus.searchTextPaged(query, topK: topK, operator: operator)
          : Future<List<WmbpHit>>.value(
              corpus.searchText(query, topK: topK, operator: operator),
            );
    }
    return _search(
      table: table,
      fieldName: fieldName,
      indexType: IndexType.text,
      topK: topK,
      run: (c) => c.prefersPagedSearch
          ? c.searchTextPaged(query, topK: topK, operator: operator)
          : Future<List<WmbpHit>>.value(
              c.searchText(query, topK: topK, operator: operator),
            ),
    );
  }

  List<WmbpHit>? searchSparseSync({
    required TableContext table,
    required String fieldName,
    required SparseVectorData query,
    required int topK,
  }) {
    final index = _findIndex(table.schema, fieldName, IndexType.sparse);
    if (index == null) return const <WmbpHit>[];
    final key = _key(table, index);
    final corpus = _corpora[key];
    if (corpus == null) return null;
    return corpus.searchSparseSync(query, topK: topK);
  }

  Future<List<WmbpHit>> searchSparse({
    required TableContext table,
    required String fieldName,
    required SparseVectorData query,
    required int topK,
  }) {
    return _search(
      table: table,
      fieldName: fieldName,
      indexType: IndexType.sparse,
      topK: topK,
      run: (corpus) => corpus.prefersPagedSearch
          ? corpus.searchSparsePaged(query, topK: topK)
          : Future<List<WmbpHit>>.value(
              corpus.searchSparse(query, topK: topK),
            ),
    );
  }

  bool applyChangesSync({
    required TableContext table,
    required TableSchema schema,
    List<Map<String, dynamic>> inserts = const [],
    List<IndexRecordUpdate> updates = const [],
    List<Map<String, dynamic>> deletes = const [],
    List<IndexSchema>? targetIndexes,
  }) {
    if (inserts.isEmpty && updates.isEmpty && deletes.isEmpty) return true;
    final indexes = targetIndexes ??
        _dataStore.tableMetaManager?.getWmbpIndexesFor(schema) ??
        const <IndexSchema>[];
    if (indexes.isEmpty) return true;
    for (final index in indexes) {
      if (_corpora[_key(table, index)] == null) return false;
    }
    final pkName = schema.primaryKey;
    for (final index in indexes) {
      if (index.fields.isEmpty) continue;
      final corpus = _corpora[_key(table, index)]!;
      final field = index.fields.first;
      for (final row in inserts) {
        final pk = row[pkName]?.toString() ?? '';
        if (pk.isNotEmpty &&
            corpus.prefersPagedSearch &&
            !corpus.tryDeactivatePrimaryKeySync(pk)) {
          return false;
        }
        _upsertRecordSync(corpus, index.type, pkName, field, row);
      }
      for (final update in updates) {
        final pk = update.primaryKey?.toString() ?? '';
        if (pk.isEmpty) continue;
        if (corpus.prefersPagedSearch &&
            !corpus.tryDeactivatePrimaryKeySync(pk)) {
          return false;
        }
        _upsertRecordSync(
          corpus,
          index.type,
          pkName,
          field,
          update.newValues,
          pk: pk,
        );
      }
      for (final row in deletes) {
        final pk = row[pkName]?.toString() ?? '';
        if (pk.isEmpty) continue;
        if (corpus.prefersPagedSearch &&
            !corpus.tryDeactivatePrimaryKeySync(pk)) {
          return false;
        }
        corpus.remove(pk);
      }
    }
    return true;
  }

  Future<void> applyChanges({
    required TableContext table,
    required TableSchema schema,
    List<Map<String, dynamic>> inserts = const [],
    List<IndexRecordUpdate> updates = const [],
    List<Map<String, dynamic>> deletes = const [],
    bool seal = false,
    BatchContext? batchContext,
    int? concurrency,
    List<IndexSchema>? targetIndexes,
  }) async {
    final indexes = targetIndexes ??
        _dataStore.tableMetaManager?.getWmbpIndexesFor(schema) ??
        const <IndexSchema>[];
    if (indexes.isEmpty) return;
    final pkName = schema.primaryKey;
    for (final index in indexes) {
      if (index.fields.isEmpty) continue;
      final corpus = await _corpusFor(table, index);
      final field = index.fields.first;
      final applyYc = YieldController(
        'WmbpIndexManager.applyChanges',
        checkInterval: 256,
        minCheckInterval: 64,
      );
      for (final row in inserts) {
        final y = applyYc.maybeYield();
        if (y != null) await y;
        final pk = row[pkName]?.toString() ?? '';
        // If this record was already ingested into the pending read cache by
        // [applyChangesSync] when it entered the write buffer, reuse the
        // tokenized impacts directly and avoid deactivating + re-tokenizing.
        if (pk.isNotEmpty && corpus.hasLocalPk(pk)) {
          continue;
        }
        // Inserts can replace an existing sealed PK (upsert / rewrite). Always
        // deactivate prior local + sealed docIds before assigning a new one.
        if (pk.isNotEmpty &&
            corpus.prefersPagedSearch &&
            !corpus.tryDeactivatePrimaryKeySync(pk)) {
          await corpus.deactivatePrimaryKey(pk);
        }
        _upsertRecordSync(corpus, index.type, pkName, field, row);
      }
      for (final update in updates) {
        final y = applyYc.maybeYield();
        if (y != null) await y;
        final pk = update.primaryKey?.toString() ?? '';
        if (pk.isEmpty) continue;
        // Always deactivate when sealed pages exist — including when a local
        // overlay doc is present — so older sealed docIds cannot keep matching.
        if (corpus.prefersPagedSearch &&
            !corpus.tryDeactivatePrimaryKeySync(pk)) {
          await corpus.deactivatePrimaryKey(pk);
        }
        _upsertRecordSync(
          corpus,
          index.type,
          pkName,
          field,
          update.newValues,
          pk: pk,
        );
      }
      for (final row in deletes) {
        final y = applyYc.maybeYield();
        if (y != null) await y;
        final pk = row[pkName]?.toString() ?? '';
        if (pk.isEmpty) continue;
        // Always retire the sealed reverse-map entry when pages exist. The old
        // hasLocalPk→remove-only branch left sealed ghosts searchable after a
        // local overlay rewrite (upsert without deactivate, or update+delete
        // before flush).
        if (corpus.prefersPagedSearch) {
          if (!corpus.tryDeactivatePrimaryKeySync(pk)) {
            await corpus.deactivatePrimaryKey(pk);
          }
        } else {
          corpus.remove(pk);
        }
      }
      if (seal) {
        final bool memory =
            _dataStore.config.persistenceMode == PersistenceMode.memory;
        if (memory) {
          corpus.sealAll();
        } else {
          // Disk pages must land under a registered page-redo batch (same as
          // B+Tree / NGH). Callers that omit [batchContext] used to write pages
          // with no replay image — torn 16KB slots on crash.
          Future<void> sealDurable(BatchContext? ctx) async {
            final volume = _volumes[_key(table, index)];
            if (volume == null) {
              await corpus.commitDurable();
              return;
            }
            await volume.runExclusiveCommit(() async {
              volume.batchContext = ctx;
              volume.beginCommit();
              try {
                await corpus.commitDurable();
                // Budgeted micro-seal into the same staged page-redo batch so
                // closed OPEN_RAW debt drains without a second commit race.
                final view = corpus.sealedView;
                if (view != null && view.dirtyOpenRawPairCount > 0) {
                  await view.sealDirtyClosedWindows(
                    maxTerms: 8,
                    maxSealMs: 2,
                    maxSealBytes: 256 * 1024,
                  );
                }
                await volume.flushCommit(concurrency: concurrency);
              } catch (e) {
                Logger.warn('WMBP page commit failed', rawError: e);
                rethrow;
              } finally {
                volume.cancelCommit();
                volume.batchContext = null;
              }
            });
          }

          if ((batchContext == null || batchContext.batchId.isEmpty) &&
              _dataStore.config.enableJournal) {
            await _dataStore.parallelJournalManager.runWithPageRedoBatch(
              table: table,
              action: (ctx, {required bool ownedBatch}) => sealDurable(ctx),
            );
          } else {
            await sealDurable(batchContext);
          }
        }
      }
    }
  }

  /// Bounded background OPEN_RAW→I/II/III seal for closed windows.
  ///
  /// Never scans the full term dictionary. Serializes against ingest commit
  /// on the same volume and uses page-redo when journal is enabled.
  Future<int> sealDirtyOpenRaw({
    int maxTermsPerIndex = 64,
    int maxSealMs = 50,
    int maxSealBytes = 2 * 1024 * 1024,
  }) async {
    if (maxTermsPerIndex <= 0) return 0;
    var total = 0;
    // Snapshot keys only: map may mutate across awaits; re-lookup skips removed.
    final keys = _corpora.keys.toList(growable: false);
    for (final key in keys) {
      final corpus = _corpora[key];
      if (corpus == null) continue;
      final view = corpus.sealedView;
      if (view == null) continue;
      if (view.dirtyOpenRawPairCount <= 0) continue;
      final volume = _volumes[key];
      if (volume == null) continue;

      Future<int> run(BatchContext? ctx) {
        return volume.runExclusiveCommit(() async {
          volume.batchContext = ctx;
          volume.beginCommit();
          try {
            final int n = await view.sealDirtyClosedWindows(
              maxTerms: maxTermsPerIndex,
              maxSealMs: maxSealMs,
              maxSealBytes: maxSealBytes,
            );
            // flushCommit no-ops when nothing was staged.
            await volume.flushCommit();
            return n;
          } finally {
            volume.cancelCommit();
            volume.batchContext = null;
          }
        });
      }

      if (_dataStore.config.enableJournal) {
        total += await _dataStore.parallelJournalManager.runWithPageRedoBatch(
          table: volume.table,
          action: (ctx, {required bool ownedBatch}) => run(ctx),
        );
      } else {
        total += await run(null);
      }
    }
    return total;
  }

  Future<List<WmbpHit>> _search({
    required TableContext table,
    required String fieldName,
    required IndexType indexType,
    required int topK,
    required Future<List<WmbpHit>> Function(WmbpCorpus corpus) run,
  }) async {
    final index = _findIndex(table.schema, fieldName, indexType);
    if (index == null) return const <WmbpHit>[];
    final corpus = await _corpusFor(table, index);
    return run(corpus);
  }

  IndexSchema? _findIndex(TableSchema schema, String field, IndexType type) {
    final indexes = _dataStore.tableMetaManager?.getWmbpIndexesFor(schema) ??
        schema.indexes;
    for (final index in indexes) {
      if (index.type == type && index.fields.contains(field)) return index;
    }
    return null;
  }

  Future<WmbpCorpus> _corpusFor(TableContext table, IndexSchema index) {
    final key = _key(table, index);
    final cached = _corpora[key];
    if (cached != null) return Future<WmbpCorpus>.value(cached);
    final inflight = _inFlight[key];
    if (inflight != null) return inflight;
    // Completer so the Future identity is registered before _load's sync
    // prologue calls stillCurrent() (late final would still be uninitialized).
    final completer = Completer<WmbpCorpus>();
    final future = completer.future;
    _inFlight[key] = future;
    _load(table, index, key, () => identical(_inFlight[key], future)).then(
      completer.complete,
      onError: completer.completeError,
    );
    return future;
  }

  /// Shared index-pool ceiling for one WMBP view (also prewarm stop line).
  ///
  /// Prefer [ResourceManager.getIndexCacheSize] (shared with B+Tree). Otherwise
  /// use 30% of the process memory budget, floored at
  /// [WmbpConstants.cacheLruBytes] — the documented WMBP LRU envelope.
  int resolveWmbpCacheBudget() {
    final sized = _dataStore.resourceManager?.getIndexCacheSize() ?? 0;
    if (sized > 0) return sized;
    final totalBudgetMB = _dataStore.resourceManager?.memoryThresholdInMB ?? 0;
    final resolvedMB = totalBudgetMB > 0
        ? totalBudgetMB
        : (_dataStore.config.cacheMemoryBudgetMB ?? 1024);
    final share = (resolvedMB * 1024 * 1024 * 0.30).round();
    return math.max(WmbpConstants.cacheLruBytes, share);
  }

  /// Resident WMBP cache bytes across all open corpora (for shared index budget).
  int getCurrentCacheSize() {
    var total = 0;
    for (final corpus in _corpora.values) {
      total += corpus.sealedView?.estimatedCacheSizeBytes ?? 0;
    }
    return total;
  }

  Future<void> evictCaches({required double ratio}) async {
    for (final corpus in _corpora.values) {
      await corpus.evictCaches(ratio: ratio);
    }
  }

  /// Startup / explicit warm of text+sparse search caches.
  ///
  /// Shares [getIndexCacheSize] with B+Tree index pages: stops as soon as
  /// btree+wmbp usage reaches that ceiling. Returns approximate bytes added.
  Future<int> prewarmIndex(
    TableContext table,
    IndexSchema index, {
    int? sharedBudgetBytes,
    int Function()? sharedUsageBytes,
  }) async {
    try {
      if (_dataStore.shouldAbortPrewarmForTable(table.tableUid)) return 0;
      if (index.indexUid.isEmpty && index.actualIndexName.isEmpty) return 0;

      final corpus = await _corpusFor(table, index);
      if (_dataStore.shouldAbortPrewarmForTable(table.tableUid)) return 0;
      final view = corpus.sealedView;
      if (view == null) return 0;

      final budget = sharedBudgetBytes ?? resolveWmbpCacheBudget();
      if (budget <= 0) return 0;

      final usage = sharedUsageBytes ??
          () {
            final btree = _dataStore.indexTreePartitionManager
                    ?.getCurrentPageCacheSize() ??
                0;
            final indexData =
                _dataStore.indexManager?.indexDataCacheEstimatedBytes ?? 0;
            return btree + indexData + getCurrentCacheSize();
          };

      final added = await view.prewarmCaches(
        sharedBudgetBytes: budget,
        sharedUsageBytes: usage,
        shouldAbort: () =>
            _dataStore.shouldAbortPrewarmForTable(table.tableUid),
      );
      if (!_dataStore.shouldAbortPrewarmForTable(table.tableUid)) {
        corpus.prewarmSearchContext();
      }
      return added;
    } catch (e) {
      Logger.warn(
        'WMBP prewarm failed for index "${index.actualIndexName}" '
        'in table "${table.tableName}"',
        rawError: e,
      );
      return 0;
    }
  }

  /// Prewarm every WMBP index on [table] under the shared index budget.
  Future<int> prewarmTable(
    TableContext table, {
    int? sharedBudgetBytes,
    int Function()? sharedUsageBytes,
  }) async {
    final indexes =
        _dataStore.tableMetaManager?.getWmbpIndexesFor(table.schema) ??
            const <IndexSchema>[];
    if (indexes.isEmpty) return 0;
    var added = 0;
    final budget = sharedBudgetBytes ?? resolveWmbpCacheBudget();
    final usage = sharedUsageBytes ??
        () {
          final btree =
              _dataStore.indexTreePartitionManager?.getCurrentPageCacheSize() ??
                  0;
          final indexData =
              _dataStore.indexManager?.indexDataCacheEstimatedBytes ?? 0;
          return btree + indexData + getCurrentCacheSize();
        };
    for (final index in indexes) {
      if (_dataStore.shouldAbortPrewarmForTable(table.tableUid)) break;
      if (usage() >= budget) break;
      added += await prewarmIndex(
        table,
        index,
        sharedBudgetBytes: budget,
        sharedUsageBytes: usage,
      );
    }
    return added;
  }

  Future<WmbpCorpus> _load(
    TableContext table,
    IndexSchema index,
    String key,
    bool Function() stillCurrent,
  ) async {
    try {
      final corpus = WmbpCorpus();
      if (_dataStore.config.persistenceMode != PersistenceMode.memory) {
        try {
          if (!stillCurrent()) return corpus;
          final volume = _WmbpStorageVolume(_dataStore, table, index);
          final view = await WmbpSealedView.open(
            volume,
            maxPartitionFileSize: _dataStore.config.maxPartitionFileSize,
            densePagesPerPartition: _pagesPerPartition(),
            cacheBudgetBytes: resolveWmbpCacheBudget(),
          );
          if (!stillCurrent()) return corpus;
          _volumes[key] = volume;
          corpus.attachSealed(view);
        } catch (e) {
          Logger.warn('WMBP page open failed', rawError: e);
        }
      }
      if (stillCurrent()) {
        _corpora[key] = corpus;
      }
      return corpus;
    } finally {
      if (stillCurrent()) {
        _inFlight.remove(key);
      }
    }
  }

  /// Hint for freezing `densePagesPerPartition` on first seal (win/fwd only).
  int _pagesPerPartition() {
    final int pages =
        _dataStore.config.maxPartitionFileSize ~/ WmbpConstants.storePageSize;
    return pages < 1 ? 1 : pages;
  }

  /// Rewrites every WMBP page so the current encoding key seals it.
  ///
  /// Pages are staged and flushed through the shared batch page-redo log.
  /// Partition range comes from sealed meta (`partitionCountExclusive`),
  /// not a directory walk.
  Future<void> rewriteEncryptedPages() async {
    final names = await _dataStore.getTableNames();
    final yc = YieldController(
      'WmbpIndexManager.rewriteEncryptedPages',
      checkInterval: 4,
      minCheckInterval: 2,
    );
    for (final name in names) {
      final yName = yc.maybeYield();
      if (yName != null) await yName;
      final uid =
          await _dataStore.tableMetaManager?.getUidByName(TableName(name));
      if (uid == null) continue;
      final table = await _dataStore.tableMetaManager?.getTableContext(uid);
      if (table == null) continue;
      final indexes =
          _dataStore.tableMetaManager?.getWmbpIndexesFor(table.schema) ??
              const <IndexSchema>[];
      for (final index in indexes) {
        if (index.indexUid.isEmpty) continue;
        final volume = _volumes[_key(table, index)] ??
            _WmbpStorageVolume(_dataStore, table, index);
        _volumes[_key(table, index)] = volume;

        WmbpSealedView? metaView;
        try {
          final corpus = await _corpusFor(table, index);
          metaView = corpus.sealedView;
        } catch (e) {
          Logger.warn(
            'WMBP rewrite: could not open sealed meta for partition bounds',
            rawError: e,
          );
        }

        Future<void> rewrite(BatchContext? ctx) async {
          volume.batchContext = ctx;
          try {
            // One commit/flush per partition file so redo chunks stay bounded.
            const categories = <String>['dict', 'post', 'win', 'fwd', 'rev'];
            for (final category in categories) {
              final yCat = yc.maybeYield();
              if (yCat != null) await yCat;
              final int metaMax =
                  metaView?.partitionCountExclusive(category) ?? 0;
              final partitions = await volume.discoverPartitions(
                category,
                metaMaxExclusive: metaMax,
              );
              for (final partition in partitions) {
                final yPart = yc.maybeYield();
                if (yPart != null) await yPart;
                volume.beginCommit();
                try {
                  await volume.rewriteEncryptedPartition(category, partition);
                  await volume.flushCommit();
                } finally {
                  volume.cancelCommit();
                }
              }
            }
          } finally {
            volume.batchContext = null;
          }
        }

        if (_dataStore.config.enableJournal) {
          await _dataStore.parallelJournalManager.runWithPageRedoBatch(
            table: table,
            action: (ctx, {required bool ownedBatch}) => rewrite(ctx),
          );
        } else {
          await rewrite(null);
        }
      }
    }
  }

  void _upsertRecordSync(
    WmbpCorpus corpus,
    IndexType type,
    String pkName,
    String field,
    Map<String, dynamic> row, {
    String? pk,
  }) {
    final id = pk ?? row[pkName]?.toString() ?? '';
    if (id.isEmpty) return;
    final value = row[field];
    if (type == IndexType.text) {
      if (value is String) {
        corpus.upsertText(id, value);
      } else if (value == null) {
        corpus.remove(id);
      }
      return;
    }
    final sparse = _asSparse(value);
    if (sparse == null) {
      corpus.remove(id);
      return;
    }
    corpus.upsertSparse(id, sparse);
  }

  SparseVectorData? _asSparse(dynamic value) {
    if (value is SparseVectorData) return value;
    if (value is Map) {
      try {
        return SparseVectorData.fromMap(value.map(
          (key, item) => MapEntry(key as Object, item as num),
        ));
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  void clearTable(TableUid tableUid) {
    final prefix = '${tableUid.value}/';
    _corpora.removeWhere((key, _) => key.startsWith(prefix));
    _volumes.removeWhere((key, _) => key.startsWith(prefix));
    // Drop in-flight loads so a late _load cannot reinsert a stale corpus.
    _inFlight.removeWhere((key, _) => key.startsWith(prefix));
  }

  void dropIndex(TableContext table, IndexSchema index) {
    final key = _key(table, index);
    _corpora.remove(key);
    _volumes.remove(key);
    _inFlight.remove(key);
  }

  /// Drops a sealed runtime so recovery reloads restored pages.
  void invalidateIndex(TableUid tableUid, IndexUid indexUid) {
    if (indexUid.isEmpty) {
      clearTable(tableUid);
      return;
    }
    final key = '${tableUid.value}/${indexUid.value}';
    _corpora.remove(key);
    _volumes.remove(key);
    _inFlight.remove(key);
  }

  /// Drop every corpus/volume (close / switchSpace teardown).
  void clearAll() {
    _corpora.clear();
    _volumes.clear();
    _inFlight.clear();
  }

  String _key(TableContext table, IndexSchema index) {
    final id = index.indexUid.isNotEmpty
        ? index.indexUid.value
        : index.actualIndexName;
    return '${table.tableUid}/$id';
  }
}

class _StagedWmbpPage {
  final String category;
  final int partitionNo;
  final int offset;
  Uint8List image;

  _StagedWmbpPage({
    required this.category,
    required this.partitionNo,
    required this.offset,
    required this.image,
  });
}

class _WmbpStorageVolume implements WmbpPageVolume {
  final DataStoreImpl store;
  final TableContext table;
  final IndexSchema index;

  /// Active flush / maintenance batch. [flushCommit] appends after-images to
  /// `parallel_journal/page_redo_$batchId.log` when [BatchContext.recordsPageRedo].
  BatchContext? batchContext;

  /// When true, [writeAt] coalesces page images until [flushCommit].
  bool _committing = false;
  final Map<String, _StagedWmbpPage> _staged = <String, _StagedWmbpPage>{};

  /// Serializes ingest seal and dirty OPEN_RAW seal on this volume so
  /// overlapping [beginCommit]/[cancelCommit] cannot wipe another txn's
  /// staged pages.
  Future<void> _commitQueue = Future<void>.value();

  static const int _encryptFlag = 0x80;
  static const int _encryptSlack = 96;

  _WmbpStorageVolume(this.store, this.table, this.index);

  bool get _encryptPages =>
      store.config.encryptionConfig?.shouldEncryptVectorIndex ?? false;

  @override
  int get payloadBudget => _encryptPages
      ? WmbpConstants.pagePayloadSize - _encryptSlack
      : WmbpConstants.pagePayloadSize;

  /// Runs [action] exclusively against this volume's commit lifecycle.
  Future<T> runExclusiveCommit<T>(Future<T> Function() action) {
    final done = Completer<T>();
    _commitQueue = _commitQueue.catchError((_) {}).then((_) async {
      try {
        done.complete(await action());
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  void beginCommit() {
    _committing = true;
    _staged.clear();
  }

  /// Writes one coalesced page-redo chunk, then flushes staged pages by file.
  ///
  /// Same pipeline as [IndexTreePartitionManager.writeChanges]:
  /// 1. pages already staged in memory during commit
  /// 2. one page-redo chunk fsync'd first
  /// 3. per-file `writeManyAsBytesAt(flush: false)` + `flushFile`, run in
  ///    parallel under [WorkloadScheduler] / [ParallelProcessor]
  Future<void> flushCommit({int? concurrency}) async {
    if (!_committing) return;
    final staged = List<_StagedWmbpPage>.from(_staged.values);
    _staged.clear();
    _committing = false;
    if (staged.isEmpty) return;

    final flushYc = YieldController(
      'WmbpStorageVolume.flushCommit',
      checkInterval: 8,
    );

    final ctx = batchContext;
    if (store.config.enableJournal &&
        index.indexUid.isNotEmpty &&
        (ctx == null || ctx.batchId.isEmpty)) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.devInvalidArgumentMissing,
          message:
              'WMBP flushCommit requires a registered page-redo batch when journal is enabled '
              '(table=${table.tableName}, index=${index.actualIndexName})',
          parameterName: 'batchContext',
          passedValue: ctx,
        ),
      ]);
    }
    if (ctx != null &&
        ctx.batchId.isNotEmpty &&
        ctx.recordsPageRedo &&
        index.indexUid.isNotEmpty) {
      final records = <Uint8List>[];
      for (final page in staged) {
        final yRedo = flushYc.maybeYield();
        if (yRedo != null) await yRedo;
        final kind = pageRedoKindForWmbp(page.category);
        if (kind == null ||
            page.image.length != WmbpConstants.storePageSize ||
            page.offset % WmbpConstants.storePageSize != 0) {
          continue;
        }
        records.add(PageRedoLogCodec.encodePageRecord(
          treeKind: kind,
          tableUid: table.tableUid,
          indexUid: index.indexUid,
          partitionNo: page.partitionNo,
          pageNo: page.offset ~/ WmbpConstants.storePageSize,
          payload: page.image,
        ));
      }
      if (records.isNotEmpty) {
        final redoPath = store.pathManager.getPageRedoLogPath(
          ctx.batchId,
          spaceName: store.currentSpaceName,
        );
        await store.storage.ensureDirectoryExists(p.dirname(redoPath));
        final int totalLen = records.fold<int>(0, (sum, b) => sum + b.length);
        final Uint8List merged;
        if (records.length == 1) {
          merged = records.first;
        } else {
          merged = Uint8List(totalLen);
          var at = 0;
          for (final b in records) {
            merged.setRange(at, at + b.length, b);
            at += b.length;
          }
        }
        await store.storage.appendBytes(
          redoPath,
          PageRedoLogCodec.wrapChunk(merged),
          flush: true,
        );
      }
    }
    final byPath = <String, Map<int, Uint8List>>{};
    for (final page in staged) {
      final path = _path(page.category, page.partitionNo);
      byPath.putIfAbsent(path, () => <int, Uint8List>{})[page.offset] =
          page.image;
    }

    final tasks = <Future<void> Function()>[];
    for (final entry in byPath.entries) {
      final yPath = flushYc.maybeYield();
      if (yPath != null) await yPath;
      final offsets = entry.value.keys.toList(growable: false)..sort();
      final writes = <ByteWrite>[
        for (final off in offsets)
          ByteWrite(offset: off, bytes: entry.value[off]!),
      ];
      if (writes.isEmpty) continue;
      final path = entry.key;
      tasks.add(() async {
        await store.storage.writeManyAsBytesAt(path, writes, flush: false);
        await store.storage.flushFile(path);
      });
    }
    if (tasks.isEmpty) return;

    final scheduler = store.workloadScheduler;
    final workloadType = (ctx?.batchType == BatchType.maintenance)
        ? WorkloadType.maintenance
        : WorkloadType.flush;
    final indexLabel = index.actualIndexName;

    if (scheduler.globalMax <= 0 || tasks.length <= 1) {
      for (final t in tasks) {
        final y = flushYc.maybeYield();
        if (y != null) await y;
        await t();
      }
      return;
    }

    final int requested = (concurrency != null && concurrency > 0)
        ? math.min(concurrency, tasks.length)
        : math.min(scheduler.capacityTokens(workloadType), tasks.length);
    WorkloadLease? lease;
    try {
      lease = await scheduler.acquire(
        workloadType,
        requestedTokens: requested,
        minTokens: 1,
        label: 'WmbpStorageVolume.flushCommit(${table.tableName}.$indexLabel)',
      );
      final int ioConcurrency =
          math.min(tasks.length, math.max(1, lease.tokens));
      await ParallelProcessor.execute<void>(
        tasks,
        concurrency: ioConcurrency,
        label: 'WmbpStorageVolume.flushCommit',
        continueOnError: false,
      );
    } finally {
      lease?.release();
    }
  }

  void cancelCommit() {
    _staged.clear();
    _committing = false;
  }

  String _stageKey(String category, int partitionNo, int offset) =>
      '$category:$partitionNo:$offset';

  String _path(String category, int partitionNo) {
    final paths = store.pathManager;
    final uid = index.indexUid;
    switch (category) {
      case 'dict':
        return paths.getWmbpDictPartitionPathByContext(table, uid, partitionNo);
      case 'post':
        return paths.getWmbpPostPartitionPathByContext(table, uid, partitionNo);
      case 'win':
        return paths.getWmbpWinPartitionPathByContext(table, uid, partitionNo);
      case 'fwd':
        return paths.getWmbpFwdPartitionPathByContext(table, uid, partitionNo);
      case 'rev':
        return paths.getWmbpRevPartitionPathByContext(table, uid, partitionNo);
    }
    throw DbException([
      InvalidArgumentStatus(
        type: ResultType.devInvalidArgumentType,
        message: 'Unknown WMBP category $category',
        parameterName: 'category',
        passedValue: category,
      ),
    ]);
  }

  @override
  Uint8List? readAtSync(
    String category,
    int partitionNo,
    int offset,
    int length,
  ) {
    final staged = _staged[_stageKey(category, partitionNo, offset)];
    if (staged != null && staged.image.length >= length) {
      return _openPage(staged.image, category);
    }
    return null;
  }

  @override
  void writeAtSync(
    String category,
    int partitionNo,
    int offset,
    Uint8List page, {
    required bool stable,
  }) {
    final image = _sealPage(page, category);
    if (_committing) {
      final key = _stageKey(category, partitionNo, offset);
      final existing = _staged[key];
      if (existing != null) {
        existing.image = image;
      } else {
        _staged[key] = _StagedWmbpPage(
          category: category,
          partitionNo: partitionNo,
          offset: offset,
          image: image,
        );
      }
    }
  }

  @override
  Future<Uint8List?> readAt(
    String category,
    int partitionNo,
    int offset,
    int length,
  ) async {
    final staged = _staged[_stageKey(category, partitionNo, offset)];
    if (staged != null && staged.image.length >= length) {
      return _openPage(staged.image, category);
    }
    final path = _path(category, partitionNo);
    try {
      if (!await store.storage.existsFile(path)) return null;
      final int size = await store.storage.getFileSize(path);
      if (offset < 0 || offset + length > size) return null;
      final bytes =
          await store.storage.readAsBytesAt(path, offset, length: length);
      if (bytes.length < length) return null;
      return _openPage(bytes, category);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeAt(
    String category,
    int partitionNo,
    int offset,
    Uint8List page, {
    required bool stable,
  }) async {
    final image = _sealPage(page, category);
    if (_committing) {
      final key = _stageKey(category, partitionNo, offset);
      final existing = _staged[key];
      if (existing != null) {
        existing.image = image;
      } else {
        _staged[key] = _StagedWmbpPage(
          category: category,
          partitionNo: partitionNo,
          offset: offset,
          image: image,
        );
      }
      return;
    }
    // Escape hatch only (journal off / tooling). Crash-safe overwrites must go
    // through beginCommit → flushCommit with a registered page-redo batch —
    // never a private per-index redo file.
    final path = _path(category, partitionNo);
    await store.storage.writeAsBytesAt(path, offset, image, flush: false);
    await store.storage.flushFile(path);
  }

  Future<bool> partitionFileExists(String category, int partitionNo) {
    return store.storage.existsFile(_path(category, partitionNo));
  }

  static final RegExp _partitionFileName =
      RegExp(r'^p(\d+)\.wmbp$', caseSensitive: false);

  /// Partition numbers for [category], derived from sealed meta high-water.
  ///
  /// When [metaMaxExclusive] > 0 returns `0 .. metaMaxExclusive-1` in O(1)
  /// (allocator page counts are contiguous; [rewriteEncryptedPartition] no-ops
  /// on sparse holes such as unused `win/` slots). Directory listing is only
  /// a cold fallback when meta is unavailable.
  Future<List<int>> discoverPartitions(
    String category, {
    int metaMaxExclusive = 0,
  }) async {
    final int metaMax = metaMaxExclusive < 0 ? 0 : metaMaxExclusive;
    if (metaMax > 0) {
      return List<int>.generate(metaMax, (i) => i, growable: false);
    }
    return _listPartitionsFromFilesystem(category);
  }

  /// Cold path only: meta missing / unreadable. Prefer not to hit this in
  /// normal key migration once the sealed view is open.
  Future<List<int>> _listPartitionsFromFilesystem(String category) async {
    final found = <int>{};
    try {
      if (index.indexUid.isEmpty) return const <int>[];
      final root = store.pathManager.getWmbpCategoryRootPathByContext(
        table,
        index.indexUid,
        category,
      );
      if (!await store.storage.existsDirectory(root)) {
        return const <int>[];
      }
      final yc = YieldController(
        'WmbpStorageVolume.listPartitionsFromFilesystem',
        checkInterval: 64,
        minCheckInterval: 16,
      );
      final entries = await store.storage.listDirectory(root, recursive: true);
      for (final entry in entries) {
        final y = yc.maybeYield();
        if (y != null) await y;
        final match = _partitionFileName.firstMatch(p.basename(entry));
        if (match == null) continue;
        final int? n = int.tryParse(match.group(1)!);
        if (n != null && n >= 0) found.add(n);
      }
    } catch (e) {
      Logger.warn(
        'WMBP partition filesystem fallback failed for $category',
        rawError: e,
      );
      return const <int>[];
    }
    if (found.isEmpty) return const <int>[];
    return found.toList()..sort();
  }

  /// Stages re-sealed page images for one partition (caller owns flush).
  Future<void> rewriteEncryptedPartition(
    String category,
    int partitionNo,
  ) async {
    final path = _path(category, partitionNo);
    if (!await store.storage.existsFile(path)) return;
    final int size = await store.storage.getFileSize(path);
    for (int offset = 0;
        offset + WmbpConstants.storePageSize <= size;
        offset += WmbpConstants.storePageSize) {
      final page = await readAt(
        category,
        partitionNo,
        offset,
        WmbpConstants.storePageSize,
      );
      if (page == null) continue;
      final plain = Uint8List.fromList(page);
      if (plain.length > 7) plain[7] = plain[7] & ~_encryptFlag;
      await writeAt(category, partitionNo, offset, plain, stable: false);
    }
  }

  Uint8List _sealPage(Uint8List page, String category) {
    // win/ uses the same framed StorePage codec as post/dict/fwd/rev so
    // EncryptionScope.full covers ActiveMask pages too.
    if (!_encryptPages || page.length != WmbpConstants.storePageSize) {
      return page;
    }
    final data = ByteData.sublistView(page);
    if (data.getUint32(0, Endian.little) != WmbpPageCodecMagic.magic) {
      return page;
    }
    if ((page[7] & _encryptFlag) != 0) return page;
    final int len = data.getUint32(12, Endian.little);
    if (len <= 0 || WmbpConstants.pageHeaderSize + len > page.length) {
      return page;
    }
    final plain = Uint8List.sublistView(
      page,
      WmbpConstants.pageHeaderSize,
      WmbpConstants.pageHeaderSize + len,
    );
    final encoded = StorePageCodec.encodePayload(plain, config: store.config);
    if (encoded.length > WmbpConstants.pagePayloadSize) {
      throw DbException([
        GeneralStatus(
          type: ResultType.sysIoDataCorrupted,
          message: 'WMBP encrypted page does not fit in 16KB',
          operation: 'wmbpSeal',
        ),
      ]);
    }
    final out = Uint8List.fromList(page);
    out.setRange(
      WmbpConstants.pageHeaderSize,
      WmbpConstants.pageHeaderSize + encoded.length,
      encoded,
    );
    final outData = ByteData.sublistView(out);
    outData.setUint32(12, encoded.length, Endian.little);
    out[7] = out[7] | _encryptFlag;
    return out;
  }

  Uint8List _openPage(Uint8List page, String category) {
    if (!_encryptPages || page.length < WmbpConstants.storePageSize) {
      return page;
    }
    final data = ByteData.sublistView(page);
    if (data.getUint32(0, Endian.little) != WmbpPageCodecMagic.magic) {
      return page;
    }
    if ((page[7] & _encryptFlag) == 0) {
      return page;
    }
    final int len = data.getUint32(12, Endian.little);
    if (len <= 0 || WmbpConstants.pageHeaderSize + len > page.length) {
      throw DbException([
        GeneralStatus(
          type: ResultType.sysIoDataCorrupted,
          message: 'WMBP encrypted page payload is truncated',
          operation: 'wmbpOpen',
        ),
      ]);
    }
    final encoded = Uint8List.sublistView(
      page,
      WmbpConstants.pageHeaderSize,
      WmbpConstants.pageHeaderSize + len,
    );
    final plain = StorePageCodec.decodePayload(encoded);
    if (plain.length > WmbpConstants.pagePayloadSize) {
      throw DbException([
        GeneralStatus(
          type: ResultType.sysIoDataCorrupted,
          message: 'WMBP decrypted page exceeds the frame',
          operation: 'wmbpOpen',
        ),
      ]);
    }
    final out = Uint8List(WmbpConstants.storePageSize);
    out.setRange(0, WmbpConstants.pageHeaderSize, page);
    out.setRange(
      WmbpConstants.pageHeaderSize,
      WmbpConstants.pageHeaderSize + plain.length,
      plain,
    );
    final outData = ByteData.sublistView(out);
    outData.setUint32(12, plain.length, Endian.little);
    out[7] = page[7] & ~_encryptFlag;
    return out;
  }
}
