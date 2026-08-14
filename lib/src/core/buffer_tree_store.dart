import 'dart:collection';

import '../handler/value_matcher.dart';
import '../model/buffer_entry.dart';
import '../model/db_exception.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/table_context.dart';
import '../model/table_identity.dart';
import '../model/table_schema.dart';
import '../model/unique_violation.dart';
import '../model/wal_pointer.dart';
import 'data_store_impl.dart';
import 'tree_cache.dart';
import 'yield_controller.dart';

/// Sentinel IndexUid for primary-key uniqueness in buffer index trees.
final IndexUid kBufferPkIndexUid = IndexUid('pk');

/// Precomputed index slots for one table (build once per batch).
///
/// [isUnique] is parallel to [indexUids] / [fieldsPerIndex].
/// Empty [fieldsPerIndex] slot means PK unique: keyParts = `[pk]`.
///
/// - [includeUniques]=false: non-unique overlays only (online after reserve).
/// - [includeUniques]=true: PK + unique (putIfAbsent) + non-unique (put) in one pass.
final class IndexWritePlan {
  final TableUid tableUid;
  final List<IndexUid> indexUids;
  final List<List<String>> fieldsPerIndex;
  final List<bool> isUnique;
  final bool includeUniques;

  const IndexWritePlan({
    required this.tableUid,
    required this.indexUids,
    required this.fieldsPerIndex,
    required this.isUnique,
    required this.includeUniques,
  });

  bool get isEmpty => indexUids.isEmpty;
  int get length => indexUids.length;
}

/// One successful flush batch awaiting / executing wal-matched pending eviction.
///
/// Queued only when a read view (or an in-flight drain) defers cleanup; the
/// common no-RV path runs via [BufferTreeStore.scheduleFlushedEvict] directly.
final class FlushedEvictTask {
  final TableUid tableUid;
  final Map<String, WalPointer?> flushedWalByPk;
  final Map<String, List<List<dynamic>>> indexPathsByPk;
  final DateTime flushAt;
  final int gen;

  FlushedEvictTask({
    required this.tableUid,
    required this.flushedWalByPk,
    required this.indexPathsByPk,
    required this.flushAt,
    required this.gen,
  });
}

/// Owns pending/txn record + index TreeCaches used as buffer fact stores.
///
/// Path keys:
/// - pending record: `[tableUid, pk]` -> [BufferEntry]
/// - pending index (unique): `[tableUid, indexUid, key...]` -> pk
/// - pending index (non-unique): `[tableUid, indexUid, key..., pk]` -> true
/// - txn record: `[txId, tableUid, pk]` -> [BufferEntry] (groupDepth=2)
/// - txn index: `[txId, tableUid, indexUid, ...]` (groupDepth=3)
class BufferTreeStore {
  final DataStoreImpl _dataStore;

  late final TreeCache<BufferEntry> pendingRecordCache;
  late final TreeCache<dynamic> pendingIndexCache;
  late final TreeCache<BufferEntry> txnRecordCache;
  late final TreeCache<dynamic> txnIndexCache;

  final Map<String, Comparator<dynamic>> _pkComparators = {};
  final Map<String, List<MatcherFunction>> _indexFieldMatchers = {};

  /// Generation bumped on clear/close/switchSpace to cancel queued eviction.
  int _evictGeneration = 0;

  final Queue<FlushedEvictTask> _evictQueue = Queue<FlushedEvictTask>();
  bool _drainRunning = false;

  /// Dummy thresholds: [TreeCacheEvictionMode.none] never auto-cleans.
  static const int _residentCacheBytes = 1;

  BufferTreeStore(this._dataStore) {
    pendingRecordCache = TreeCache<BufferEntry>(
      sizeCalculator: _recordSize,
      maxByteThreshold: _residentCacheBytes,
      minByteThreshold: _residentCacheBytes,
      groupDepth: 1,
      comparatorFactory: _pendingRecordComparatorFactory,
      evictionMode: TreeCacheEvictionMode.none,
      debugLabel: 'PendingRecordCache',
    );
    pendingIndexCache = TreeCache<dynamic>(
      sizeCalculator: _indexSize,
      maxByteThreshold: _residentCacheBytes,
      minByteThreshold: _residentCacheBytes,
      groupDepth: 2,
      comparatorFactory: _pendingIndexComparatorFactory,
      evictionMode: TreeCacheEvictionMode.none,
      debugLabel: 'PendingIndexCache',
    );
    txnRecordCache = TreeCache<BufferEntry>(
      sizeCalculator: _recordSize,
      maxByteThreshold: _residentCacheBytes,
      minByteThreshold: _residentCacheBytes,
      groupDepth: 2,
      comparatorFactory: _txnRecordComparatorFactory,
      evictionMode: TreeCacheEvictionMode.none,
      debugLabel: 'TxnRecordCache',
    );
    txnIndexCache = TreeCache<dynamic>(
      sizeCalculator: _indexSize,
      maxByteThreshold: _residentCacheBytes,
      minByteThreshold: _residentCacheBytes,
      groupDepth: 3,
      comparatorFactory: _txnIndexComparatorFactory,
      evictionMode: TreeCacheEvictionMode.none,
      debugLabel: 'TxnIndexCache',
    );
  }

  int get evictGeneration => _evictGeneration;

  /// True while tasks remain or a drain is in flight (idle clear must wait).
  bool get hasPendingFlushedEvict => _evictQueue.isNotEmpty || _drainRunning;

  void bumpEvictGeneration() {
    _evictGeneration++;
    _evictQueue.clear();
  }

  int _recordSize(BufferEntry e) {
    final avg = _dataStore.tableDataManager.averageTableRecordSizeBytes;
    if (avg != null && avg > 0) return avg;
    return _dataStore.tableDataManager.resolveRecordSizeBytes(e.data);
  }

  int _indexSize(dynamic _) {
    final avg = _dataStore.tableDataManager.averageIndexEntrySizeBytes;
    if (avg != null && avg > 0) return avg;
    return 64;
  }

  Comparator<dynamic> _pendingRecordComparatorFactory(
    List<dynamic> path, {
    int suffixIndex = 0,
  }) {
    if (suffixIndex > 0) return TreeCache.compareNative;
    if (path.isEmpty) return TreeCache.compareNative;
    final tableUid = path[0]?.toString() ?? '';
    return _pkComparators[tableUid] ?? TreeCache.compareNative;
  }

  Comparator<dynamic> _txnRecordComparatorFactory(
    List<dynamic> path, {
    int suffixIndex = 0,
  }) {
    // groupDepth=2 -> groupPath [txId, tableUid], first suffix = pk
    if (suffixIndex > 0) return TreeCache.compareNative;
    if (path.length < 2) return TreeCache.compareNative;
    final tableUid = path[1]?.toString() ?? '';
    return _pkComparators[tableUid] ?? TreeCache.compareNative;
  }

  Comparator<dynamic> _pendingIndexComparatorFactory(
    List<dynamic> path, {
    int suffixIndex = 0,
  }) {
    return _indexComparatorFor(path, pathOffset: 0, suffixIndex: suffixIndex);
  }

  Comparator<dynamic> _txnIndexComparatorFactory(
    List<dynamic> path, {
    int suffixIndex = 0,
  }) {
    // groupDepth=3 -> [txId, tableUid, indexUid], first suffix = field1
    if (path.length < 3) return TreeCache.compareNative;
    return _indexComparatorFor(path.sublist(1),
        pathOffset: 0, suffixIndex: suffixIndex);
  }

  Comparator<dynamic> _indexComparatorFor(
    List<dynamic> path, {
    required int pathOffset,
    int suffixIndex = 0,
  }) {
    if (path.length < 2) return TreeCache.compareNative;
    final tableUid = path[pathOffset]?.toString() ?? '';
    final indexUid = path[pathOffset + 1]?.toString() ?? '';
    final matchers = _indexFieldMatchers['$tableUid:$indexUid'];
    if (matchers != null) {
      // groupPath length is typically 2 ([tableUid, indexUid]); suffixIndex
      // selects field0, field1, ..., trailing pk for non-unique indexes.
      final fieldIndex = (path.length - 2 - pathOffset) + suffixIndex;
      if (fieldIndex >= 0 && fieldIndex < matchers.length) {
        return matchers[fieldIndex];
      }
    }
    return TreeCache.compareNative;
  }

  void registerTableComparator(TableContext table, TableSchema schema) {
    final tableUid = table.tableUid;
    if (_pkComparators.containsKey(tableUid)) return;
    _pkComparators[tableUid] =
        ValueMatcher.getMatcher(schema.getPrimaryKeyMatcherType());
  }

  void registerIndexComparator(
      TableContext table, IndexUid indexUid, TableSchema schema) {
    final key = '${table.tableUid}:$indexUid';
    if (_indexFieldMatchers.containsKey(key)) return;

    if (indexUid == kBufferPkIndexUid) {
      _indexFieldMatchers[key] = [
        ValueMatcher.getMatcher(schema.getPrimaryKeyMatcherType()),
      ];
      return;
    }

    IndexSchema? indexSchema;
    for (final idx in schema.getAllIndexes()) {
      if (idx.indexUid == indexUid) {
        indexSchema = idx;
        break;
      }
    }
    if (indexSchema == null || indexSchema.fields.isEmpty) return;

    final matchers = <MatcherFunction>[];
    for (final field in indexSchema.fields) {
      matchers.add(ValueMatcher.getMatcher(schema.getFieldMatcherType(field)));
    }
    if (!indexSchema.unique) {
      matchers.add(ValueMatcher.getMatcher(schema.getPrimaryKeyMatcherType()));
    }
    _indexFieldMatchers[key] = matchers;
  }

  void ensureComparators(TableContext table, TableSchema schema) {
    registerTableComparator(table, schema);
    registerIndexComparator(table, kBufferPkIndexUid, schema);
    for (final idx in schema.getAllIndexes()) {
      registerIndexComparator(table, idx.indexUid, schema);
    }
  }

  /// Once-per-batch index plan + ensure comparators.
  ///
  /// When [includeUniques] is false, only non-unique slots (reserve owns uniques).
  /// When true, PK + all schema indexes for a single pending install pass.
  IndexWritePlan prepareIndexWritePlan(
    TableContext table,
    TableSchema schema, {
    required bool includeUniques,
  }) {
    ensureComparators(table, schema);
    final uids = <IndexUid>[];
    final fields = <List<String>>[];
    final uniqueFlags = <bool>[];
    if (includeUniques) {
      uids.add(kBufferPkIndexUid);
      fields.add(const <String>[]);
      uniqueFlags.add(true);
    }
    for (final idx in schema.getAllIndexes()) {
      if (idx.fields.isEmpty) continue;
      if (!includeUniques && idx.unique) continue;
      uids.add(idx.indexUid);
      fields.add(idx.fields);
      uniqueFlags.add(idx.unique);
    }
    return IndexWritePlan(
      tableUid: table.tableUid,
      indexUids: uids,
      fieldsPerIndex: fields,
      isUnique: uniqueFlags,
      includeUniques: includeUniques,
    );
  }

  // -------------------- Point lookups --------------------

  BufferEntry? getPendingRecord(TableUid tableUid, String pk) =>
      pendingRecordCache.peek([tableUid, pk]);

  BufferEntry? getTxnRecord(String txId, TableUid tableUid, String pk) =>
      txnRecordCache.peek([txId, tableUid, pk]);

  BufferEntry? getVisibleRecord(
    TableContext table,
    String pk, {
    String? transactionId,
  }) {
    final tableUid = table.tableUid;
    if (transactionId != null) {
      final tx = getTxnRecord(transactionId, tableUid, pk);
      if (tx != null) return tx;
    }
    return getPendingRecord(tableUid, pk);
  }

  bool hasPendingWritesForUid(TableUid tableUid) {
    // pending record groupDepth=1 -> one group per tableUid (O(1) map walk).
    return pendingRecordCache.hasGroupEntries(tableUid);
  }

  // -------------------- PK overlay apply --------------------

  /// Apply a buffer operation into pending or txn record/index trees.
  ///
  /// Returns the effective entry stored (or null if cancelled insert+delete).
  ///
  /// [installAllIndexes]: when true (commit ? pending), unique slots are
  /// installed via putIfAbsent in the same pass as non-unique. When false,
  /// uniques are assumed already reserved and apply only maintains non-unique.
  ///
  /// [indexPlan]: optional once-per-batch plan; when null, built from
  /// [installAllIndexes] on the fresh-insert index path only.
  BufferEntry? applyRecord({
    required TableContext table,
    required TableSchema schema,
    required String pk,
    required BufferEntry entry,
    String? transactionId,
    Set<String>? changedFields,
    bool installAllIndexes = false,
    IndexWritePlan? indexPlan,
  }) {
    ensureComparators(table, schema);
    final tableUid = table.tableUid;
    final isTxn = transactionId != null;

    final prior = isTxn
        ? getTxnRecord(transactionId, tableUid, pk)
        : getPendingRecord(tableUid, pk);

    BufferEntry? effective = entry;
    bool removeEntirely = false;

    if (prior != null) {
      if (prior.operation == BufferOperationType.insert &&
          entry.operation == BufferOperationType.update) {
        final merged = Map<String, dynamic>.from(prior.data)
          ..addAll(entry.data);
        effective = BufferEntry(
          data: merged,
          operation: BufferOperationType.insert,
          timestamp: entry.timestamp,
          walPointer: entry.walPointer ?? prior.walPointer,
          transactionId: prior.transactionId ?? entry.transactionId,
          oldValues: null,
          schemaVersion: entry.schemaVersion,
        );
      } else if (prior.operation == BufferOperationType.insert &&
          entry.operation == BufferOperationType.delete) {
        removeEntirely = true;
        effective = null;
      } else if (prior.operation == BufferOperationType.delete &&
          entry.operation == BufferOperationType.insert) {
        effective = BufferEntry(
          data: entry.data,
          operation: BufferOperationType.update,
          timestamp: entry.timestamp,
          walPointer: entry.walPointer,
          transactionId: prior.transactionId ?? entry.transactionId,
          oldValues: prior.oldValues ?? prior.data,
          schemaVersion: entry.schemaVersion,
        );
      } else if (prior.operation == BufferOperationType.update &&
          entry.operation == BufferOperationType.update) {
        final merged = Map<String, dynamic>.from(prior.data)
          ..addAll(entry.data);
        effective = BufferEntry(
          data: merged,
          operation: BufferOperationType.update,
          timestamp: entry.timestamp,
          walPointer: entry.walPointer ?? prior.walPointer,
          transactionId: prior.transactionId ?? entry.transactionId,
          oldValues: prior.oldValues ?? entry.oldValues,
          schemaVersion: entry.schemaVersion,
        );
      } else if (prior.operation == BufferOperationType.update &&
          entry.operation == BufferOperationType.delete) {
        effective = BufferEntry(
          data: entry.data,
          operation: BufferOperationType.delete,
          timestamp: entry.timestamp,
          walPointer: entry.walPointer,
          transactionId: prior.transactionId ?? entry.transactionId,
          oldValues: prior.oldValues ?? prior.data,
          schemaVersion: entry.schemaVersion,
        );
      } else if (prior.operation == BufferOperationType.delete &&
          entry.operation == BufferOperationType.update) {
        throw DbException([
          ConstraintStatus(
            type: ResultType.bizRecordNotFound,
            tableName: table.tableName,
            fields: [schema.primaryKey],
            conflictingKeys: [pk],
            message:
                'Cannot update record $pk in table ${table.tableName} because it has already been deleted',
          ),
        ]);
      }
    }

    if (removeEntirely) {
      _removeRecordAndIndexes(
        table: table,
        schema: schema,
        pk: pk,
        prior: prior!,
        transactionId: transactionId,
      );
      return null;
    }

    if (effective == null) return null;

    // Index delta relative to prior.
    if (prior != null &&
        prior.operation != BufferOperationType.delete &&
        effective.operation != BufferOperationType.delete) {
      _updateIndexesIncremental(
        table: table,
        schema: schema,
        pk: pk,
        oldData: prior.data,
        newData: effective.data,
        changedFields: changedFields,
        transactionId: transactionId,
        isInsert: effective.operation == BufferOperationType.insert &&
            prior.operation == BufferOperationType.insert,
        installAllIndexes: installAllIndexes,
      );
    } else if (prior != null &&
        prior.operation != BufferOperationType.delete &&
        effective.operation == BufferOperationType.delete) {
      _removeAllIndexesForRecord(
        table: table,
        schema: schema,
        pk: pk,
        data: prior.oldValues ?? prior.data,
        transactionId: transactionId,
      );
    } else if ((prior == null ||
            prior.operation == BufferOperationType.delete) &&
        effective.operation != BufferOperationType.delete) {
      // Fresh insert / insert-after-delete: one plan pass.
      applyIndexWritePlan(
        plan: indexPlan ??
            prepareIndexWritePlan(table, schema,
                includeUniques: installAllIndexes),
        pk: pk,
        data: effective.data,
        transactionId: transactionId,
      );
    } else if (prior == null &&
        effective.operation == BufferOperationType.delete) {
      // Delete of a disk-only row: store tombstone; indexes from oldValues/data.
      _removeAllIndexesForRecord(
        table: table,
        schema: schema,
        pk: pk,
        data: effective.oldValues ?? effective.data,
        transactionId: transactionId,
      );
    }

    final recordKey = isTxn
        ? <dynamic>[transactionId, tableUid, pk]
        : <dynamic>[tableUid, pk];
    final cache = isTxn ? txnRecordCache : pendingRecordCache;
    cache.put(recordKey, effective);
    return effective;
  }

  /// Fast path for virgin inserts.
  ///
  /// Prefer [applyVirginInsertWithPlan] inside batches (plan built once).
  void applyVirginInsert({
    required TableContext table,
    required TableSchema schema,
    required String pk,
    required BufferEntry entry,
    String? transactionId,
    bool installAllIndexes = false,
  }) {
    applyVirginInsertWithPlan(
      plan: prepareIndexWritePlan(table, schema,
          includeUniques: installAllIndexes),
      pk: pk,
      entry: entry,
      transactionId: transactionId,
    );
  }

  /// Virgin insert using a precomputed [IndexWritePlan] (batch hot path).
  ///
  /// Per row: record put + one loop over plan slots (unique putIfAbsent /
  /// non-unique put). No per-row `getAllIndexes` / comparator ensure.
  void applyVirginInsertWithPlan({
    required IndexWritePlan plan,
    required String pk,
    required BufferEntry entry,
    String? transactionId,
  }) {
    final tableUid = plan.tableUid;
    final isTxn = transactionId != null;
    final recordCache = isTxn ? txnRecordCache : pendingRecordCache;
    recordCache.put(
      isTxn ? <dynamic>[transactionId, tableUid, pk] : <dynamic>[tableUid, pk],
      entry,
    );
    applyIndexWritePlan(
      plan: plan,
      pk: pk,
      data: entry.data,
      transactionId: transactionId,
    );
  }

  /// Apply precomputed index slots once (unique and/or non-unique).
  void applyIndexWritePlan({
    required IndexWritePlan plan,
    required String pk,
    required Map<String, dynamic> data,
    String? transactionId,
  }) {
    if (plan.isEmpty) return;
    final tableUid = plan.tableUid;
    final isTxn = transactionId != null;
    final indexCache = isTxn ? txnIndexCache : pendingIndexCache;
    final int markerSize = pk.length + 1;
    final uids = plan.indexUids;
    final fieldsList = plan.fieldsPerIndex;
    final uniqueFlags = plan.isUnique;
    for (int s = 0; s < uids.length; s++) {
      final fields = fieldsList[s];
      final List<dynamic> parts;
      if (fields.isEmpty) {
        // PK unique sentinel.
        parts = <dynamic>[pk];
      } else {
        parts = _indexFieldsValue(data, fields);
        if (parts.isEmpty) continue;
      }
      final IndexUid indexUid = uids[s];
      final bool isUnique = uniqueFlags[s];
      if (isUnique) {
        final List<dynamic> path = isTxn
            ? <dynamic>[transactionId, tableUid, indexUid, ...parts]
            : <dynamic>[tableUid, indexUid, ...parts];
        indexCache.putIfAbsent(path, pk);
      } else {
        final List<dynamic> path = isTxn
            ? <dynamic>[transactionId, tableUid, indexUid, ...parts, pk]
            : <dynamic>[tableUid, indexUid, ...parts, pk];
        indexCache.put(path, true, size: markerSize);
      }
    }
  }

  void removeRecordEntirely({
    required TableContext table,
    required TableSchema schema,
    required String pk,
    String? transactionId,
  }) {
    final prior = getVisibleRecord(table, pk, transactionId: transactionId);
    if (prior == null) {
      final key = transactionId != null
          ? <dynamic>[transactionId, table.tableUid, pk]
          : <dynamic>[table.tableUid, pk];
      (transactionId != null ? txnRecordCache : pendingRecordCache).remove(key);
      return;
    }
    _removeRecordAndIndexes(
      table: table,
      schema: schema,
      pk: pk,
      prior: prior,
      transactionId: transactionId,
    );
  }

  void _removeRecordAndIndexes({
    required TableContext table,
    required TableSchema schema,
    required String pk,
    required BufferEntry prior,
    String? transactionId,
  }) {
    if (prior.operation != BufferOperationType.delete) {
      _removeAllIndexesForRecord(
        table: table,
        schema: schema,
        pk: pk,
        data: prior.data,
        transactionId: transactionId,
      );
    }
    // Also drop PK unique reservation.
    _removeUniqueIndexKey(
      table: table,
      indexUid: kBufferPkIndexUid,
      keyParts: [pk],
      pk: pk,
      transactionId: transactionId,
      isUnique: true,
    );
    final key = transactionId != null
        ? <dynamic>[transactionId, table.tableUid, pk]
        : <dynamic>[table.tableUid, pk];
    (transactionId != null ? txnRecordCache : pendingRecordCache).remove(key);
  }

  // -------------------- Index maintenance --------------------

  List<dynamic> _indexFieldsValue(
      Map<String, dynamic> data, List<String> fields) {
    final out = <dynamic>[];
    for (final f in fields) {
      final v = data[f];
      if (v == null) return const <dynamic>[];
      out.add(v);
    }
    return out;
  }

  void _removeAllIndexesForRecord({
    required TableContext table,
    required TableSchema schema,
    required String pk,
    required Map<String, dynamic> data,
    String? transactionId,
  }) {
    ensureComparators(table, schema);
    _removeUniqueIndexKey(
      table: table,
      indexUid: kBufferPkIndexUid,
      keyParts: [pk],
      pk: pk,
      transactionId: transactionId,
      isUnique: true,
    );
    for (final idx in schema.getAllIndexes()) {
      final parts = _indexFieldsValue(data, idx.fields);
      if (parts.isEmpty) continue;
      _removeUniqueIndexKey(
        table: table,
        indexUid: idx.indexUid,
        keyParts: parts,
        pk: pk,
        transactionId: transactionId,
        isUnique: idx.unique,
      );
    }
  }

  void _updateIndexesIncremental({
    required TableContext table,
    required TableSchema schema,
    required String pk,
    required Map<String, dynamic> oldData,
    required Map<String, dynamic> newData,
    Set<String>? changedFields,
    String? transactionId,
    bool isInsert = false,
    bool installAllIndexes = false,
  }) {
    if (isInsert) {
      // Insert overlay rewrite wiped prior leaves -- reinstall via one plan.
      _removeAllIndexesForRecord(
        table: table,
        schema: schema,
        pk: pk,
        data: oldData,
        transactionId: transactionId,
      );
      applyIndexWritePlan(
        plan: prepareIndexWritePlan(table, schema, includeUniques: true),
        pk: pk,
        data: newData,
        transactionId: transactionId,
      );
      return;
    }

    for (final idx in schema.getAllIndexes()) {
      final touches = changedFields == null ||
          changedFields.isEmpty ||
          idx.fields.any(changedFields.contains);
      if (!touches) continue;
      final oldParts = _indexFieldsValue(oldData, idx.fields);
      final newParts = _indexFieldsValue(newData, idx.fields);
      if (oldParts.isNotEmpty) {
        _removeUniqueIndexKey(
          table: table,
          indexUid: idx.indexUid,
          keyParts: oldParts,
          pk: pk,
          transactionId: transactionId,
          isUnique: idx.unique,
        );
      }
      if (newParts.isEmpty) continue;
      if (idx.unique) {
        // Online: new unique already putIfAbsent by tryReserveUniques.
        // Commit?pending: install into pending domain here.
        if (!installAllIndexes) continue;
        _putIndexEntry(
          table: table,
          indexUid: idx.indexUid,
          keyParts: newParts,
          pk: pk,
          isUnique: true,
          transactionId: transactionId,
        );
        continue;
      }
      _putIndexEntry(
        table: table,
        indexUid: idx.indexUid,
        keyParts: newParts,
        pk: pk,
        isUnique: false,
        transactionId: transactionId,
      );
    }
  }

  List<dynamic> _indexPath({
    required TableUid tableUid,
    required IndexUid indexUid,
    required List<dynamic> keyParts,
    required String pk,
    required bool isUnique,
    String? transactionId,
  }) {
    if (transactionId != null) {
      if (isUnique) {
        return <dynamic>[transactionId, tableUid, indexUid, ...keyParts];
      }
      return <dynamic>[transactionId, tableUid, indexUid, ...keyParts, pk];
    }
    if (isUnique) {
      return <dynamic>[tableUid, indexUid, ...keyParts];
    }
    return <dynamic>[tableUid, indexUid, ...keyParts, pk];
  }

  void _putIndexEntry({
    required TableContext table,
    required IndexUid indexUid,
    required List<dynamic> keyParts,
    required String pk,
    required bool isUnique,
    String? transactionId,
  }) {
    registerIndexComparator(table, indexUid, table.schema);
    final path = _indexPath(
      tableUid: table.tableUid,
      indexUid: indexUid,
      keyParts: keyParts,
      pk: pk,
      isUnique: isUnique,
      transactionId: transactionId,
    );
    final cache = transactionId != null ? txnIndexCache : pendingIndexCache;
    if (isUnique) {
      // Same primitive as tryReserveUniqueInMemory -- never overwrite.
      cache.putIfAbsent(path, pk);
    } else {
      cache.put(path, true, size: pk.length + 1);
    }
  }

  void _removeUniqueIndexKey({
    required TableContext table,
    required IndexUid indexUid,
    required List<dynamic> keyParts,
    required String pk,
    required bool isUnique,
    String? transactionId,
  }) {
    final path = _indexPath(
      tableUid: table.tableUid,
      indexUid: indexUid,
      keyParts: keyParts,
      pk: pk,
      isUnique: isUnique,
      transactionId: transactionId,
    );
    final cache = transactionId != null ? txnIndexCache : pendingIndexCache;
    cache.remove(path);
  }

  // -------------------- Unique reservation (putIfAbsent) --------------------

  /// Memory unique pre-reserve via putIfAbsent. Returns violation or null.
  ///
  /// On success, keys are already placed. On failure, [rollbackKeys] lists
  /// paths that this call inserted (caller should remove them).
  UniqueViolation? tryReserveUniqueInMemory({
    required TableContext table,
    required TableSchema schema,
    required String pk,
    required Map<String, dynamic> data,
    required bool isUpdate,
    Set<String>? changedFields,
    String? transactionId,
    List<List<dynamic>>? rollbackKeys,
  }) {
    ensureComparators(table, schema);
    final tableUid = table.tableUid;
    final cache = transactionId != null ? txnIndexCache : pendingIndexCache;

    UniqueViolation? conflictOn({
      required IndexUid indexUid,
      required List<dynamic> keyParts,
      required List<String> fields,
      required dynamic value,
      required IndexName? indexName,
    }) {
      final path = _indexPath(
        tableUid: tableUid,
        indexUid: indexUid,
        keyParts: keyParts,
        pk: pk,
        isUnique: true,
        transactionId: transactionId,
      );
      final existing = cache.putIfAbsent(path, pk);
      if (existing == null) {
        rollbackKeys?.add(path);
        return null;
      }
      final existingPk = existing.toString();
      // PK sentinel slot: path already is the identity ([..., pkValue] -> pk).
      // "existingPk == pk" is ALWAYS true for a duplicate insert, so the
      // secondary-unique same-owner idempotent bypass must NOT apply here ?
      // otherwise concurrent/duplicate inserts with the same PK all "succeed"
      // and later record puts just overwrite.
      // PK sentinel: path identity IS the pk, so existing always means conflict.
      // Secondary unique: same-owner re-reserve is idempotent.
      if (indexUid != kBufferPkIndexUid && existingPk == pk) return null;
      return UniqueViolation(
        tableName: table.tableName,
        fields: fields,
        value: value,
        indexName: indexName,
        existingPrimaryKey: existingPk,
      );
    }

    // Also check the other buffer domain (txn vs pending) for conflicts.
    UniqueViolation? crossDomainConflict({
      required IndexUid indexUid,
      required List<dynamic> keyParts,
      required List<String> fields,
      required dynamic value,
      required IndexName? indexName,
    }) {
      // Check pending if we are in txn, and all txn trees if in pending.
      if (transactionId != null) {
        final pendingPath = _indexPath(
          tableUid: tableUid,
          indexUid: indexUid,
          keyParts: keyParts,
          pk: pk,
          isUnique: true,
        );
        final existing = pendingIndexCache.peek(pendingPath);
        if (existing != null) {
          final existingPk = existing.toString();
          if (!(isUpdate && existingPk == pk)) {
            return UniqueViolation(
              tableName: table.tableName,
              fields: fields,
              value: value,
              indexName: indexName,
              existingPrimaryKey: existingPk,
            );
          }
        }
      } else {
        // Scan other txns: groupDepth=3, no cheap global scan by key without txId.
        // Cross-txn uniqueness is enforced by checking all active txn prefixes
        // via hasUniqueOwnedByOtherTransaction (WriteBufferManager helper).
      }
      return null;
    }

    // PK
    if (!isUpdate) {
      final v = conflictOn(
        indexUid: kBufferPkIndexUid,
        keyParts: [pk],
        fields: [schema.primaryKey],
        value: pk,
        indexName: IndexName('pk'),
      );
      if (v != null) return v;
      final cross = crossDomainConflict(
        indexUid: kBufferPkIndexUid,
        keyParts: [pk],
        fields: [schema.primaryKey],
        value: pk,
        indexName: IndexName('pk'),
      );
      if (cross != null) {
        rollbackReserved(rollbackKeys ?? const [],
            transactionId: transactionId);
        return cross;
      }
    }

    for (final idx in schema.getAllIndexes()) {
      if (!idx.unique) continue;
      if (isUpdate &&
          changedFields != null &&
          changedFields.isNotEmpty &&
          !idx.fields.any(changedFields.contains)) {
        continue;
      }
      final parts = _indexFieldsValue(data, idx.fields);
      if (parts.isEmpty) continue;
      final value = parts.length == 1 ? parts.first : parts;
      final v = conflictOn(
        indexUid: idx.indexUid,
        keyParts: parts,
        fields: idx.fields,
        value: value,
        indexName: IndexName(idx.actualIndexName),
      );
      if (v != null) {
        rollbackReserved(rollbackKeys ?? const [],
            transactionId: transactionId);
        return v;
      }
      final cross = crossDomainConflict(
        indexUid: idx.indexUid,
        keyParts: parts,
        fields: idx.fields,
        value: value,
        indexName: IndexName(idx.actualIndexName),
      );
      if (cross != null) {
        rollbackReserved(rollbackKeys ?? const [],
            transactionId: transactionId);
        return cross;
      }
    }
    return null;
  }

  void rollbackReserved(List<List<dynamic>> paths, {String? transactionId}) {
    final cache = transactionId != null ? txnIndexCache : pendingIndexCache;
    for (final p in paths) {
      cache.remove(p);
    }
  }

  /// Lookup owner pk of a unique index key in pending (and optionally txn).
  String? lookupUniqueOwner({
    required TableUid tableUid,
    required IndexUid indexUid,
    required List<dynamic> keyParts,
    String? transactionId,
    String? excludeTxId,
  }) {
    if (transactionId != null) {
      final path = _indexPath(
        tableUid: tableUid,
        indexUid: indexUid,
        keyParts: keyParts,
        pk: '',
        isUnique: true,
        transactionId: transactionId,
      );
      final v = txnIndexCache.peek(path);
      if (v != null) return v.toString();
    }
    final pendingPath = _indexPath(
      tableUid: tableUid,
      indexUid: indexUid,
      keyParts: keyParts,
      pk: '',
      isUnique: true,
    );
    final pv = pendingIndexCache.peek(pendingPath);
    if (pv != null) return pv.toString();
    return null;
  }

  /// Whether another row (not [selfPk]) owns the unique key in pending/txn trees.
  String? hasUniqueOwnedByOther({
    required TableUid tableUid,
    required IndexUid indexUid,
    required List<dynamic> keyParts,
    String? selfPk,
    String? transactionId,
  }) {
    final owner = lookupUniqueOwner(
      tableUid: tableUid,
      indexUid: indexUid,
      keyParts: keyParts,
      transactionId: transactionId,
    );
    if (owner == null) return null;
    if (selfPk != null && owner == selfPk) return null;
    return owner;
  }

  /// Drop all txn-scoped record/index overlays (whole instance).
  ///
  /// Prefer this over per-[txId] [clearTransaction] when every transaction is
  /// going away (dispose / space switch). Prefix-remove per tx is O(groups);
  /// [TreeCache.clear] is a single reset.
  void clearAllTransactions() {
    txnRecordCache.clear();
    txnIndexCache.clear();
  }

  void clearTransaction(String txId) {
    // Prefix remove is O(groups under txId), not O(entries) -- sync is fine.
    txnRecordCache.remove([txId]);
    txnIndexCache.remove([txId]);
  }

  /// Drop pending overlays for [tableUid], and any txn overlays for that table.
  ///
  /// Pending paths are `[tableUid, ...]` (prefix remove). Txn paths are
  /// `[txId, tableUid, ...]` -- must [TreeCache.removeWhere] (no single prefix).
  Future<void> clearTable(TableUid tableUid) async {
    _evictQueue.removeWhere((t) => t.tableUid == tableUid);
    pendingRecordCache.remove([tableUid]);
    pendingIndexCache.remove([tableUid]);
    await txnRecordCache.removeWhere(
      (key, _) => key.length >= 2 && key[1] == tableUid,
      yieldLabel: 'BufferTreeStore.clearTable.txnRecord',
    );
    await txnIndexCache.removeWhere(
      (key, _) => key.length >= 2 && key[1] == tableUid,
      yieldLabel: 'BufferTreeStore.clearTable.txnIndex',
    );
  }

  /// Drop pending (non-txn) trees only -- used when flush queue is idle and no
  /// read views / flushed-evict tasks remain.
  void clearPendingCaches() {
    bumpEvictGeneration();
    pendingRecordCache.clear();
    pendingIndexCache.clear();
  }

  void clearAll() {
    bumpEvictGeneration();
    pendingRecordCache.clear();
    pendingIndexCache.clear();
    txnRecordCache.clear();
    txnIndexCache.clear();
  }

  // -------------------- Max PK / insert keys --------------------

  Future<dynamic> getMaxPrimaryKey(
    TableContext table,
    String pkField,
  ) async {
    dynamic maxVal;
    final matcher = _pkComparators[table.tableUid] ?? TreeCache.compareNative;
    await pendingRecordCache.scanRange(
      [table.tableUid],
      null,
      reverse: true,
      limit: 64,
      onEntry: (path, entry) {
        if (entry.operation == BufferOperationType.delete) return true;
        final v = entry.data[pkField];
        if (v == null) return true;
        if (maxVal == null || matcher(v, maxVal) > 0) {
          maxVal = v;
        }
        // With reverse PK order, first non-delete is the max.
        return false;
      },
    );
    return maxVal;
  }

  Future<void> forEachPendingRecord(
    TableContext table, {
    dynamic startPk,
    dynamic endPk,
    bool reverse = false,
    int? limit,
    required bool Function(String pk, BufferEntry entry) onEntry,
  }) async {
    // ASC after cursor: start=[table,cursor], end=null, reverse=false
    // DESC after cursor: start=[table], end=[table,cursor], reverse=true
    //   (TreeCache reverse seeks LastLE(end) -- must NOT pass cursor as start
    //   or it walks from the group max down to the cursor every page.)
    final List<dynamic> start;
    final List<dynamic>? end;
    if (reverse) {
      start = <dynamic>[table.tableUid];
      end = endPk == null && startPk == null
          ? null
          : <dynamic>[table.tableUid, endPk ?? startPk];
    } else {
      start = startPk == null
          ? <dynamic>[table.tableUid]
          : <dynamic>[table.tableUid, startPk];
      end = endPk == null ? null : <dynamic>[table.tableUid, endPk];
    }
    await pendingRecordCache.scanRange(
      start,
      end,
      reverse: reverse,
      limit: limit,
      onEntry: (path, entry) {
        if (path.length < 2) return true;
        final pk = path.last.toString();
        return onEntry(pk, entry);
      },
    );
  }

  Future<void> forEachTxnRecord(
    String txId,
    TableContext table, {
    dynamic startPk,
    dynamic endPk,
    bool reverse = false,
    int? limit,
    required bool Function(String pk, BufferEntry entry) onEntry,
  }) async {
    final List<dynamic> start;
    final List<dynamic>? end;
    if (reverse) {
      start = <dynamic>[txId, table.tableUid];
      end = endPk == null && startPk == null
          ? null
          : <dynamic>[txId, table.tableUid, endPk ?? startPk];
    } else {
      start = startPk == null
          ? <dynamic>[txId, table.tableUid]
          : <dynamic>[txId, table.tableUid, startPk];
      end = endPk == null ? null : <dynamic>[txId, table.tableUid, endPk];
    }
    await txnRecordCache.scanRange(
      start,
      end,
      reverse: reverse,
      limit: limit,
      onEntry: (path, entry) {
        if (path.length < 3) return true;
        final pk = path.last.toString();
        return onEntry(pk, entry);
      },
    );
  }

  /// Collect all txn ops for commit (pk -> entry).
  Future<Map<String, Map<String, BufferEntry>>> collectTxnOps(
      String txId) async {
    final out = <String, Map<String, BufferEntry>>{};
    await txnRecordCache.scanRange(
      [txId],
      null,
      onEntry: (path, entry) {
        if (path.length < 3) return true;
        final tableUid = path[1].toString();
        final pk = path[2].toString();
        out.putIfAbsent(tableUid, () => <String, BufferEntry>{})[pk] = entry;
        return true;
      },
    );
    return out;
  }

  // -------------------- Flushed evict queue / index paths --------------------

  /// Leaf paths currently held in [pendingIndexCache] for a flushed row.
  ///
  /// Includes PK unique slot + all schema indexes (unique from reserve,
  /// non-unique from apply). Deletes return empty.
  List<List<dynamic>> collectPendingIndexPathsForFlush({
    required TableContext table,
    required TableSchema schema,
    required String pk,
    required BufferEntry entry,
  }) {
    if (entry.operation == BufferOperationType.delete) {
      return const <List<dynamic>>[];
    }
    ensureComparators(table, schema);
    final tableUid = table.tableUid;
    final paths = <List<dynamic>>[
      _indexPath(
        tableUid: tableUid,
        indexUid: kBufferPkIndexUid,
        keyParts: <dynamic>[pk],
        pk: pk,
        isUnique: true,
      ),
    ];
    for (final idx in schema.getAllIndexes()) {
      final parts = _indexFieldsValue(entry.data, idx.fields);
      if (parts.isEmpty) continue;
      paths.add(
        _indexPath(
          tableUid: tableUid,
          indexUid: idx.indexUid,
          keyParts: parts,
          pk: pk,
          isUnique: idx.unique,
        ),
      );
    }
    return paths;
  }

  /// Schedule wal-matched eviction for a successful flush batch.
  ///
  /// - **Common (no read view, no backlog):** run directly -- no [_evictQueue]
  ///   allocate/churn; still single-flight with [tryDrainFlushedEvict].
  /// - **Deferred:** active read views and/or pending tasks -> enqueue, drain
  ///   when the oldest view no longer predates [flushAt].
  void scheduleFlushedEvict({
    required TableUid tableUid,
    required Map<String, WalPointer?> flushedWalByPk,
    required Map<String, List<List<dynamic>>> indexPathsByPk,
    required DateTime flushAt,
    void Function()? onIdle,
  }) {
    if (flushedWalByPk.isEmpty) return;

    final task = FlushedEvictTask(
      tableUid: tableUid,
      flushedWalByPk: flushedWalByPk,
      indexPathsByPk: indexPathsByPk,
      flushAt: flushAt,
      gen: _evictGeneration,
    );

    // Fast path: nothing waiting and no RV -> skip queue.
    if (!_drainRunning &&
        _evictQueue.isEmpty &&
        !_dataStore.readViewManager.hasActiveViews) {
      // ignore: discarded_futures
      _runDirectEvict(task, onIdle: onIdle);
      return;
    }

    _evictQueue.add(task);
    tryDrainFlushedEvict(onIdle: onIdle);
  }

  Future<void> _runDirectEvict(
    FlushedEvictTask task, {
    void Function()? onIdle,
  }) async {
    // Lost the race with another drain -- fall back to queue.
    if (_drainRunning) {
      _evictQueue.add(task);
      tryDrainFlushedEvict(onIdle: onIdle);
      return;
    }
    _drainRunning = true;
    try {
      await _executeEvictTask(task);
      // Sibling tables may have enqueued while we ran.
      await _drainEvictQueueLocked();
    } finally {
      _drainRunning = false;
    }
    onIdle?.call();
  }

  /// Drain head-blocked [FlushedEvictTask]s when no older read view remains.
  ///
  /// Single-flight; safe to call from hot paths (no-op if already draining).
  void tryDrainFlushedEvict({void Function()? onIdle}) {
    if (_drainRunning) return;
    // ignore: discarded_futures
    _drainFlushedEvict(onIdle: onIdle);
  }

  Future<void> _drainFlushedEvict({void Function()? onIdle}) async {
    if (_drainRunning) return;
    _drainRunning = true;
    try {
      await _drainEvictQueueLocked();
    } finally {
      _drainRunning = false;
    }
    onIdle?.call();
  }

  /// Caller must hold [_drainRunning] == true.
  Future<void> _drainEvictQueueLocked() async {
    while (_evictQueue.isNotEmpty) {
      if (_dataStore.isClosing) {
        _evictQueue.clear();
        break;
      }
      final task = _evictQueue.first;
      if (task.gen != _evictGeneration) {
        _evictQueue.removeFirst();
        continue;
      }
      final rvm = _dataStore.readViewManager;
      if (rvm.hasActiveViews) {
        final oldest = rvm.oldestCreatedAt;
        if (oldest != null && oldest.isBefore(task.flushAt)) {
          // Head blocked by a view that started before this flush.
          break;
        }
      }
      _evictQueue.removeFirst();
      await _executeEvictTask(task);
    }
  }

  Future<void> _executeEvictTask(FlushedEvictTask task) async {
    if (task.gen != _evictGeneration || _dataStore.isClosing) return;

    final yc = YieldController('BufferTreeStore.evictFlushed');
    final tableUid = task.tableUid;
    final indexGroupDepth = pendingIndexCache.groupDepth;

    for (final pk in task.flushedWalByPk.keys) {
      if (task.gen != _evictGeneration || _dataStore.isClosing) return;
      final y = yc.maybeYield();
      if (y != null) await y;

      final key = <dynamic>[tableUid, pk];
      final live = pendingRecordCache.peek(key);
      if (live == null) continue;
      // Keep when a newer enqueue replaced this row after the flush snapshot.
      if (live.walPointer != task.flushedWalByPk[pk]) continue;

      pendingRecordCache.remove(key);

      final paths = task.indexPathsByPk[pk];
      if (paths == null || paths.isEmpty) continue;
      for (final path in paths) {
        if (task.gen != _evictGeneration || _dataStore.isClosing) return;
        final y2 = yc.maybeYield();
        if (y2 != null) await y2;
        // Exact leaf only -- length <= groupDepth would prefix-delete whole groups.
        if (path.length <= indexGroupDepth) continue;
        pendingIndexCache.remove(path);
      }
    }
  }
}
