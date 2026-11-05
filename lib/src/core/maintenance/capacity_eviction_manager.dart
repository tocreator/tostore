import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../../handler/logger.dart';
import '../../model/buffer_entry.dart';
import '../../model/data_store_config.dart';
import '../../model/system_table.dart';
import '../../model/table_context.dart';
import '../../model/table_identity.dart';
import '../../model/table_schema.dart';
import '../compute/workload_scheduler.dart';
import '../compute/yield_controller.dart';
import '../engine/data_store_impl.dart';
import '../query/query_condition.dart';
import 'crontab_manager.dart';

class _CapacityPlan {
  final TableUid tableUid;
  final CapacityConfig config;
  final PrimaryKeyType pkType;

  const _CapacityPlan({
    required this.tableUid,
    required this.config,
    required this.pkType,
  });
}

class _CapacityBatchResult {
  final int deleted;
  final bool ok;

  /// Keyset cursor: next PK-FIFO batch starts strictly after this PK.
  final String? nextAfterPk;

  /// Keyset cursor: next index-oldest batch starts strictly after this key.
  final Uint8List? nextAfterIndexKey;

  const _CapacityBatchResult({
    required this.deleted,
    required this.ok,
    this.nextAfterPk,
    this.nextAfterIndexKey,
  });
}

/// Advances eviction scans so each batch continues after the previous one
/// instead of re-reading the same oldest head (which stuck on buffered deletes).
class _EvictScanCursor {
  String? afterPk;
  Uint8List? afterIndexKey;
}

/// Capacity (maxEntries / maxBytes) eviction for user tables and KV stores.
///
/// Independent of [TtlCleanupManager], but mirrors its scheduling skeleton:
/// crontab (~1 min idle) + startup one-shot + batch/flush wake + yield-retry,
/// maintenance leases, write-buffer backpressure, fair per-table batches, and
/// YieldController coverage.
///
/// Idle = crontab only (no resident timer). Batch insert / flush may call
/// [maybeWakeAfterGrowth] when over the high watermark; if a cycle is already
/// running or scheduled, the call is a no-op. Unfinished drains use a short
/// one-shot [_resumeTimer]. Once over high, a cycle drains to the low watermark.
class CapacityEvictionManager {
  static const String _backgroundLeaseId = 'capacity_eviction';
  static const int _batchSize = 500;

  final DataStoreImpl _dataStore;

  bool _cleanupRegistered = false;
  ExecuteInterval? _scheduleInterval;
  int _lastCleanupMs = 0;
  bool _cleanupRunning = false;

  /// When true, skip [ttlCleanupIntervalMs] gate so a paused drain can resume
  /// quickly (via [_resumeTimer]) instead of waiting a full idle interval.
  bool _backlogPending = false;
  int _planCacheRefreshedMs = 0;
  bool _planCacheFullyLoaded = false;
  final Map<String, _CapacityPlan> _planCache = <String, _CapacityPlan>{};

  Timer? _startupTimer;

  /// One-shot only: unfinished-drain resume or a writer/flush wake.
  /// Never a resident poller — idle leaves this null and relies on crontab.
  Timer? _resumeTimer;

  /// Remaining rows of a **fixed** episode target when a drain pauses mid-way
  /// (lease / buffer). Resume continues this count — does not re-snapshot meta.
  final Map<TableUid, int> _pendingDeleteTarget = <TableUid, int>{};

  CapacityEvictionManager(this._dataStore);

  bool get _isMemoryMode =>
      _dataStore.config.persistenceMode == PersistenceMode.memory;

  void registerCleanupTask() {
    try {
      if (_cleanupRegistered) return;
      // Memory: 30s — no durable flush to wake maxBytes; disk: 1 min + flush wake.
      _scheduleInterval =
          _isMemoryMode ? ExecuteInterval.seconds30 : ExecuteInterval.minutes1;
      CrontabManager.addCallback(_scheduleInterval!, _onScheduleTick);
      _cleanupRegistered = true;

      // Start after TTL's typical 10s one-shot so the first catch-up prefers TTL.
      final startupDelay = _isMemoryMode
          ? const Duration(seconds: 3)
          : const Duration(seconds: 15);
      _startupTimer = Timer(startupDelay, () {
        _onScheduleTick();
      });
    } catch (_) {}
  }

  void unregisterCleanupTask() {
    _startupTimer?.cancel();
    _startupTimer = null;
    _resumeTimer?.cancel();
    _resumeTimer = null;

    if (_cleanupRegistered) {
      try {
        final interval = _scheduleInterval ?? ExecuteInterval.minutes1;
        CrontabManager.removeCallback(interval, _onScheduleTick);
      } catch (_) {}
      _cleanupRegistered = false;
      _scheduleInterval = null;
    }
    _cleanupRunning = false;
    _lastCleanupMs = 0;
    _backlogPending = false;
    _pendingDeleteTarget.clear();
    CrontabManager.releaseBackgroundWorkLease(_backgroundLeaseId);
  }

  /// One-shot resume for an unfinished drain. Idle path must leave this unset.
  void _scheduleBacklogResume() {
    if (_dataStore.isClosing || !_cleanupRegistered) return;
    _resumeTimer?.cancel();
    _resumeTimer = Timer(const Duration(milliseconds: 200), () {
      _resumeTimer = null;
      if (_dataStore.isClosing || !_cleanupRegistered) return;
      _onScheduleTick();
    });
  }

  /// Writer/flush wake when over high watermark.
  ///
  /// Call sites: durable PJM flush; memory-mode batch insert only. If a cycle
  /// is already running or scheduled, skip. Idle: memory ~30s / disk ~1 min
  /// crontab (memory `maxBytes` avg is warmed on that poll, not on writes).
  @pragma('vm:prefer-inline')
  void maybeWakeAfterGrowth(TableContext table) {
    if (!_cleanupRegistered || _dataStore.isClosing) return;
    if (_cleanupRunning || _backlogPending || _resumeTimer != null) return;

    final CapacityConfig? config;
    final tableCap = table.schema.capacityConfig;
    if (tableCap != null) {
      config = tableCap;
    } else if (SystemTable.isKeyValueTable(table.tableName)) {
      config = table.isGlobal
          ? _dataStore.config.globalKvCapacityConfig
          : _dataStore.config.kvCapacityConfig;
      if (config == null) return;
    } else {
      return;
    }

    if (_isOverHighWatermarkSync(table, config) != true) return;

    _backlogPending = true;
    _scheduleBacklogResume();
  }

  void invalidatePlanCache() {
    _planCacheRefreshedMs = 0;
    _planCacheFullyLoaded = false;
    _planCache.clear();
  }

  void upsertPlanForSchema(TableSchema schema) {
    if (!_planCacheFullyLoaded) return;

    final capacity = schema.capacityConfig;
    if (capacity == null) {
      _planCache.remove(schema.tableUid.value);
      _planCacheRefreshedMs = DateTime.now().millisecondsSinceEpoch;
      return;
    }

    _planCache[schema.tableUid.value] = _CapacityPlan(
      tableUid: schema.tableUid,
      config: capacity,
      pkType: schema.primaryKeyConfig.type,
    );
    _planCacheRefreshedMs = DateTime.now().millisecondsSinceEpoch;
  }

  void removePlanForTable(TableContext table) {
    if (!_planCacheFullyLoaded) return;
    _planCache.remove(table.tableUid.value);
    _pendingDeleteTarget.remove(table.tableUid);
    _planCacheRefreshedMs = DateTime.now().millisecondsSinceEpoch;
  }

  void _onScheduleTick() {
    if (!_dataStore.isInitialized || _dataStore.isClosing) return;
    if (_cleanupRunning) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    // Idle probe: memory 30s (no flush wake); disk shares TTL interval (~60s+).
    // Active backlog skips the gate so overshoot keeps draining.
    if (!_backlogPending) {
      final intervalMs =
          _isMemoryMode ? 30000 : _dataStore.config.ttlCleanupIntervalMs;
      if (now - _lastCleanupMs < intervalMs) {
        return;
      }
    }
    _lastCleanupMs = now;
    _cleanupRunning = true;
    _runCleanupCycle().whenComplete(() {
      _cleanupRunning = false;
    });
  }

  /// Wait for write-buffer pressure to ease so this cycle can keep draining.
  ///
  /// [threshold] `1` waits until the queue is empty. Uses [flushCompletely]
  /// so we do not sit in PJM's online tail-fill / maxFlushLatencyMs window
  /// (that looked like a multi-second "pause" with no eviction logs).
  Future<bool> _waitForWriteBufferDrain({
    required int threshold,
    required YieldController yieldController,
  }) async {
    if (threshold <= 0) return true;
    final deadlineMs = DateTime.now().millisecondsSinceEpoch + 60000;
    var kickedFlush = false;
    while (!_dataStore.isClosing &&
        _dataStore.writeBufferManager.queueLength >= threshold) {
      if (DateTime.now().millisecondsSinceEpoch >= deadlineMs) {
        return false;
      }
      if (!kickedFlush) {
        kickedFlush = true;
        try {
          if (threshold <= 1) {
            // Force drain now — scheduleFlushIfNeeded alone waits to fill a
            // huge writeBatchSize / latency window before flushing a small tail.
            await _dataStore.parallelJournalManager.flushCompletely();
            continue;
          }
          _dataStore.parallelJournalManager.scheduleFlushIfNeeded();
        } catch (_) {}
      }
      final y = yieldController.maybeYield();
      if (y != null) await y;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return !_dataStore.isClosing;
  }

  Future<Map<String, _CapacityPlan>> _getCleanupPlans() async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final refreshIntervalMs =
        max(_dataStore.config.ttlCleanupIntervalMs * 6, 1800000);
    if (_planCacheFullyLoaded &&
        nowMs - _planCacheRefreshedMs < refreshIntervalMs) {
      return Map<String, _CapacityPlan>.from(_planCache);
    }

    final tables = await _dataStore.tableMetaManager
            ?.listAllTables(onlyUserTables: true) ??
        const <String>[];
    if (tables.isEmpty) {
      _planCache.clear();
      _planCacheRefreshedMs = nowMs;
      _planCacheFullyLoaded = true;
      return Map<String, _CapacityPlan>.from(_planCache);
    }

    try {
      final newPlans = <String, _CapacityPlan>{};
      final yieldController = YieldController(
          'CapacityEvictionManager.refreshPlanCache',
          checkInterval: 1);
      for (final tableName in tables) {
        final y = yieldController.maybeYield();
        if (y != null) await y;

        final schema = await _dataStore.tableMetaManager
            ?.getTableSchemaByName(TableName(tableName));
        final capacity = schema?.capacityConfig;
        if (schema == null || capacity == null) continue;

        newPlans[schema.tableUid.value] = _CapacityPlan(
          tableUid: schema.tableUid,
          config: capacity,
          pkType: schema.primaryKeyConfig.type,
        );
      }

      _planCache
        ..clear()
        ..addAll(newPlans);
      _planCacheRefreshedMs = nowMs;
      _planCacheFullyLoaded = true;
      return Map<String, _CapacityPlan>.from(_planCache);
    } catch (e) {
      Logger.warn('Refresh capacity plan cache failed', rawError: e);
      return Map<String, _CapacityPlan>.from(_planCache);
    }
  }

  Future<TableContext?> _resolveKvTable(bool isGlobal) async {
    final name = SystemTable.getKeyValueName(isGlobal);
    final uid =
        await _dataStore.tableMetaManager?.getUidByName(TableName(name));
    if (uid == null) return null;
    return _dataStore.tableMetaManager?.getTableContext(uid);
  }

  Future<List<({TableContext table, CapacityConfig config})>>
      _activeKvTargets() async {
    final out = <({TableContext table, CapacityConfig config})>[];
    final spaceCfg = _dataStore.config.kvCapacityConfig;
    if (spaceCfg != null) {
      final t = await _resolveKvTable(false);
      if (t != null) out.add((table: t, config: spaceCfg));
    }
    final globalCfg = _dataStore.config.globalKvCapacityConfig;
    if (globalCfg != null) {
      final t = await _resolveKvTable(true);
      if (t != null) out.add((table: t, config: globalCfg));
    }
    return out;
  }

  /// Approximate live occupancy for capacity `maxBytes`:
  /// `count × (recordEncodeAvg + Σ indexBytesPerRecord)`.
  ///
  /// Avgs are process-lifetime: disk put/index flush samples, or a one-shot
  /// memory-cache sample on eviction poll when avg is still cold. If the
  /// record avg is not warm yet, returns null and callers **skip the bytes
  /// dim**. Never uses file HWM.
  int? _capacityBytesSync(TableContext table) {
    return _dataStore.tableDataManager.estimateCapacityBytesSync(table);
  }

  /// O(1) watermark probe using in-memory count / logical-avg caches only.
  ///
  /// Dimensions are independent. Missing record-count → unknown (may hydrate
  /// count). Missing logical avg with `maxBytes` → skip bytes dim this round;
  /// do not treat as unknown and do not fall back to file HWM.
  bool? _isOverHighWatermarkSync(TableContext table, CapacityConfig config) {
    var anyOver = false;
    var anyUnknown = false;

    final highEntries = config.highEntries();
    if (highEntries != null) {
      final count = _dataStore.tableDataManager.getTableRecordCountSync(table);
      if (count == null) {
        anyUnknown = true;
      } else if (count > highEntries) {
        anyOver = true;
      }
    }

    final highBytes = config.highBytes();
    if (highBytes != null) {
      final bytes = _capacityBytesSync(table);
      if (bytes != null && bytes > highBytes) {
        anyOver = true;
      }
      // bytes == null: avg still cold → skip bytes dim.
    }

    if (anyOver) return true;
    if (anyUnknown) return null;
    return false;
  }

  /// Memory + `maxBytes`: warm logical avg once from the record cache (off
  /// the write hot path) so the bytes dim can arm.
  Future<void> _ensureMemoryBytesAvgIfNeeded(
    TableContext table,
    CapacityConfig config,
  ) async {
    if (!_isMemoryMode) return;
    if (config.highBytes() == null) return;
    if (_dataStore.tableDataManager.getCapacityLogicalAvgBytesSync(table) !=
        null) {
      return;
    }
    await _dataStore.tableDataManager
        .ensureCapacityLogicalAvgFromMemoryCache(table);
  }

  Future<bool> _isOverHighWatermark(
    TableContext table,
    CapacityConfig config,
  ) async {
    await _ensureMemoryBytesAvgIfNeeded(table, config);

    final sync = _isOverHighWatermarkSync(table, config);
    if (sync != null) return sync;

    // Entries dim needs record count. Bytes stay skipped until avg is warm.
    if (config.highEntries() != null || config.highBytes() != null) {
      await _dataStore.tableDataManager.getTableRecordCount(table);
    }
    return _isOverHighWatermarkSync(table, config) == true;
  }

  /// Rows to delete to reach the low watermark (max of entries + bytes dims).
  int _entriesOverLowSync(TableContext table, CapacityConfig config) {
    var over = 0;

    final lowEntries = config.lowEntries();
    if (lowEntries != null) {
      final count = _dataStore.tableDataManager.getTableRecordCountSync(table);
      if (count != null) over = max(over, count - lowEntries);
    }

    final lowBytes = config.lowBytes();
    if (lowBytes != null) {
      final bytes = _capacityBytesSync(table);
      final avg =
          _dataStore.tableDataManager.getCapacityLogicalAvgBytesSync(table);
      final count = _dataStore.tableDataManager.getTableRecordCountSync(table);
      if (bytes != null &&
          avg != null &&
          count != null &&
          count > 0 &&
          bytes > lowBytes) {
        over = max(over, ((bytes - lowBytes) / avg).ceil());
      }
    }

    return max(0, over);
  }

  /// Snapshot delete target from live count + flush-sampled logical avg.
  Future<int> _resolveDeleteTarget(
    TableContext table,
    CapacityConfig config,
  ) async {
    await _dataStore.tableDataManager.getTableRecordCount(table);
    return _entriesOverLowSync(table, config);
  }

  /// Over high → new episode. Or resume a paused fixed [_pendingDeleteTarget].
  Future<bool> _shouldStartOrResumeEviction(
    TableContext table,
    CapacityConfig config,
  ) async {
    final pending = _pendingDeleteTarget[table.tableUid];
    if (pending != null && pending > 0) return true;
    // New episode only from high watermark — never from "still over low"
    // after a completed target (that re-opened targets and wiped the table).
    return await _isOverHighWatermark(table, config);
  }

  /// After buffered deletes flush, reload record count so watermark math uses
  /// post-delete count × logical avg (bytes dim does not re-read file HWM).
  Future<void> _reloadWatermarkCaches(TableContext table) async {
    if (_isMemoryMode) {
      // Memory mode keeps the live record-count cache as the watermark source;
      // wiping it and reloading from TableDataMeta can snap the count to 0
      // (meta is not the capacity authority in pure memory mode).
      await _dataStore.tableDataManager.getTableRecordCount(table);
      return;
    }
    _dataStore.tableDataManager.removeRecordCountCache(table);
    await _dataStore.tableDataManager.getTableRecordCount(table);
  }

  IndexUid? _findIndexUidForField(TableSchema schema, String field) {
    for (final idx in schema.getAllIndexes()) {
      if (idx.fields.isNotEmpty &&
          idx.fields.first == field &&
          idx.indexUid.isNotEmpty) {
        return idx.indexUid;
      }
    }
    return null;
  }

  Future<bool> _isIndexBuilding(TableContext table, IndexUid indexUid) async {
    if (indexUid.isEmpty) return true;
    final meta =
        await _dataStore.indexManager?.getIndexMeta(table.tableUid, indexUid);
    // Missing meta: memory mode keeps the index only in TreeCache (no disk
    // IndexMeta), so treat as ready. Disk mode waits until meta exists.
    if (meta == null) return !_isMemoryMode;
    return meta.isBuilding;
  }

  Future<({_CapacityBatchResult result, Set<String> successKeys})>
      _deleteByPrimaryKeysDetailed(
    TableContext table,
    List<String> pks, {
    required int batchSize,
  }) async {
    if (pks.isEmpty) {
      return (
        result: const _CapacityBatchResult(deleted: 0, ok: true),
        successKeys: const <String>{},
      );
    }
    final pkName = table.schema.primaryKey;
    final condition = QueryCondition()..whereIn(pkName, pks);
    final r = await _dataStore.deleteInternal(
      table,
      condition,
      limit: batchSize,
    );
    if (r.hasErrors) {
      Logger.warn(
        'Capacity eviction delete failed on ${table.tableName}: ${r.message}',
      );
      return (
        result: const _CapacityBatchResult(deleted: 0, ok: false),
        successKeys: const <String>{},
      );
    }
    // ignore: deprecated_member_use_from_same_package
    final keys = r.successKeys.toSet();
    return (
      result: _CapacityBatchResult(deleted: r.successCount, ok: true),
      successKeys: keys,
    );
  }

  Future<_CapacityBatchResult> _deleteByPrimaryKeys(
    TableContext table,
    List<String> pks, {
    required int batchSize,
  }) async {
    final detailed = await _deleteByPrimaryKeysDetailed(
      table,
      pks,
      batchSize: batchSize,
    );
    return detailed.result;
  }

  bool _isPendingDelete(TableContext table, String pk) {
    final entry = _dataStore.writeBufferManager.getBufferedRecord(table, pk);
    return entry != null && entry.operation == BufferOperationType.delete;
  }

  Future<_CapacityBatchResult> _evictByOrderedPrimaryKey(
    TableContext table, {
    required int batchSize,
    required _EvictScanCursor cursor,
  }) async {
    final pkName = table.schema.primaryKey;
    final condition = QueryCondition();
    final afterPk = cursor.afterPk;
    if (afterPk != null && afterPk.isNotEmpty) {
      // Keyset: continue strictly after the previous batch's last PK.
      condition.where(pkName, '>', afterPk);
    }

    final records = (await _dataStore.queryExecutor.execute(
      table,
      condition: condition,
      orderBy: [pkName],
      limit: batchSize,
      selectedFields: [pkName],
      engineInternal: true,
      enableQueryCache: false,
    ))
        .records;
    if (records.isEmpty) {
      return const _CapacityBatchResult(deleted: 0, ok: true);
    }

    final pks = <String>[];
    String? lastSeenPk;
    for (final record in records) {
      final pk = record[pkName]?.toString();
      if (pk == null || pk.isEmpty) continue;
      lastSeenPk = pk;
      if (_isPendingDelete(table, pk)) continue;
      pks.add(pk);
    }
    // Always advance past the scanned window, even if all were pending deletes.
    if (lastSeenPk != null) cursor.afterPk = lastSeenPk;

    if (pks.isEmpty) {
      return _CapacityBatchResult(
        deleted: 0,
        ok: true,
        nextAfterPk: cursor.afterPk,
      );
    }
    final detailed = await _deleteByPrimaryKeysDetailed(
      table,
      pks,
      batchSize: batchSize,
    );
    // Cursor already advanced to lastSeenPk (scan order); keep that.
    return _CapacityBatchResult(
      deleted: detailed.result.deleted,
      ok: detailed.result.ok,
      nextAfterPk: cursor.afterPk,
    );
  }

  /// Evict via oldest entries on a real field index (table sourceField / KV
  /// updated_at). Index maintenance is **only** via [deleteInternal] → flush —
  /// never a parallel index writeChanges channel (that races flush).
  Future<_CapacityBatchResult> _evictByIndexOldest(
    TableContext table,
    IndexUid indexUid, {
    required int batchSize,
    required _EvictScanCursor cursor,
  }) async {
    final res = await _dataStore.indexManager?.searchOldestEntries(
      table,
      indexUid,
      limit: batchSize,
      startAfterKey: cursor.afterIndexKey,
    );
    if (res == null || res.requiresTableScan) {
      return const _CapacityBatchResult(deleted: 0, ok: true);
    }

    // Advance cursor to last scanned index key before filtering.
    if (res.lastKey != null && res.lastKey!.isNotEmpty) {
      cursor.afterIndexKey = res.lastKey;
    }

    final pks = <String>[];
    final entries = res.entries;
    if (entries != null && entries.isNotEmpty) {
      for (final e in entries) {
        if (e.primaryKey.isEmpty) continue;
        if (_isPendingDelete(table, e.primaryKey)) continue;
        pks.add(e.primaryKey);
      }
    } else {
      for (final pk in res.primaryKeys) {
        if (pk.isEmpty || _isPendingDelete(table, pk)) continue;
        pks.add(pk);
      }
    }
    if (pks.isEmpty) {
      return _CapacityBatchResult(
        deleted: 0,
        ok: true,
        nextAfterIndexKey: cursor.afterIndexKey,
      );
    }
    final result = await _deleteByPrimaryKeys(table, pks, batchSize: batchSize);
    return _CapacityBatchResult(
      deleted: result.deleted,
      ok: result.ok,
      nextAfterIndexKey: cursor.afterIndexKey,
    );
  }

  Future<_CapacityBatchResult> _runFifoTableEvictionBatch(
    TableContext table,
    CapacityConfig config,
    PrimaryKeyType pkType, {
    required int batchSize,
    required _EvictScanCursor cursor,
  }) async {
    if (config.usesPrimaryKeyFifo(pkType)) {
      return await _evictByOrderedPrimaryKey(
        table,
        batchSize: batchSize,
        cursor: cursor,
      );
    }

    // FIFO + PrimaryKeyType.none: durable sourceField index (same path as LRU).
    final field = config.sourceField;
    if (field == null || field.isEmpty) {
      return const _CapacityBatchResult(deleted: 0, ok: true);
    }
    final indexUid = _findIndexUidForField(table.schema, field);
    if (indexUid == null ||
        indexUid.isEmpty ||
        await _isIndexBuilding(table, indexUid)) {
      return const _CapacityBatchResult(deleted: 0, ok: true);
    }
    return await _evictByIndexOldest(
      table,
      indexUid,
      batchSize: batchSize,
      cursor: cursor,
    );
  }

  Future<_CapacityBatchResult> _runTableEvictionBatch(
    TableContext table,
    CapacityConfig config,
    PrimaryKeyType pkType, {
    required int batchSize,
    required _EvictScanCursor cursor,
  }) async {
    try {
      final schema = table.schema;

      if (config.policy == CapacityEvictionPolicy.lru) {
        final lruField = config.sourceField;
        if (lruField != null && lruField.isNotEmpty) {
          final indexUid = _findIndexUidForField(schema, lruField);
          if (indexUid == null ||
              indexUid.isEmpty ||
              await _isIndexBuilding(table, indexUid)) {
            return const _CapacityBatchResult(deleted: 0, ok: true);
          }
          return await _evictByIndexOldest(
            table,
            indexUid,
            batchSize: batchSize,
            cursor: cursor,
          );
        }
        // Misconfigured LRU (no sourceField) → FIFO fallback.
      }

      return await _runFifoTableEvictionBatch(
        table,
        config,
        pkType,
        batchSize: batchSize,
        cursor: cursor,
      );
    } catch (e) {
      if (_dataStore.isClosing) {
        return const _CapacityBatchResult(deleted: 0, ok: false);
      }
      Logger.warn(
        'Capacity eviction batch failed on ${table.tableName}',
        rawError: e,
      );
      return const _CapacityBatchResult(deleted: 0, ok: false);
    }
  }

  Future<_CapacityBatchResult> _runKvEvictionBatch(
    TableContext table,
    CapacityConfig config, {
    required int batchSize,
    required _EvictScanCursor cursor,
  }) async {
    try {
      // KV order field is engine-owned; both fifo and lru scan oldest-first.
      final updatedAtIndex = _findIndexUidForField(
        table.schema,
        SystemTable.keyValueUpdatedAtField,
      );
      if (updatedAtIndex == null ||
          updatedAtIndex.isEmpty ||
          await _isIndexBuilding(table, updatedAtIndex)) {
        // Wait for the order index — never ordered-scan the whole KV table.
        return const _CapacityBatchResult(deleted: 0, ok: true);
      }
      return await _evictByIndexOldest(
        table,
        updatedAtIndex,
        batchSize: batchSize,
        cursor: cursor,
      );
    } catch (e) {
      if (_dataStore.isClosing) {
        return const _CapacityBatchResult(deleted: 0, ok: false);
      }
      Logger.warn(
        'KV capacity eviction batch failed on ${table.tableName}',
        rawError: e,
      );
      return const _CapacityBatchResult(deleted: 0, ok: false);
    }
  }

  /// Drain one table using a **fixed** delete target for this episode.
  ///
  /// 1. Snapshot target once from meta/count (or resume [_pendingDeleteTarget]).
  /// 2. Delete until that count is reached — never re-snapshot mid-episode.
  /// 3. Wait for durable flush, then reload meta (post-flush judgment only).
  /// 4. Episode done → stop. Do not open a second target because soft-delete
  ///    meta bytes are still over the watermark.
  ///
  /// [needResume] only when the fixed remainder is paused mid-way.
  Future<({int deleted, bool needResume})> _drainTableToLow(
    TableContext table,
    CapacityConfig config,
    PrimaryKeyType? pkType, {
    required bool isKv,
    required YieldController yieldController,
  }) async {
    final flushBatchSize = max(
      _batchSize,
      _dataStore.parallelJournalManager.effectiveWriteBatchSize,
    );

    final uid = table.tableUid;
    final resumed = _pendingDeleteTarget.remove(uid);
    final target = resumed ?? await _resolveDeleteTarget(table, config);
    if (target <= 0) {
      return (deleted: 0, needResume: false);
    }

    Logger.info(
      'Capacity eviction target $target records for table ${table.tableName} '
      '(evictRatio=${config.evictRatio}, flushBatch=$flushBatchSize'
      '${resumed != null ? ', resume' : ''})',
    );

    var deleted = 0;
    var pendingSinceFlush = 0;
    var stuckRounds = 0;
    var round = 0;
    final cursor = _EvictScanCursor();

    void saveRemainder() {
      final left = target - deleted;
      if (left > 0) {
        _pendingDeleteTarget[uid] = left;
      } else {
        _pendingDeleteTarget.remove(uid);
      }
    }

    while (deleted < target && !_dataStore.isClosing) {
      final y = yieldController.maybeYield();
      if (y != null) await y;

      var lease = await _dataStore.workloadScheduler.tryAcquire(
        WorkloadType.maintenance,
        requestedTokens: 1,
        minTokens: 1,
        label: 'capacity-eviction-${table.tableName}-$round',
      );
      if (lease == null) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        lease = await _dataStore.workloadScheduler.tryAcquire(
          WorkloadType.maintenance,
          requestedTokens: 1,
          minTokens: 1,
          label: 'capacity-eviction-${table.tableName}-$round-retry',
        );
        if (lease == null) {
          saveRemainder();
          return (deleted: deleted, needResume: true);
        }
      }

      var leaseHeld = true;
      try {
        final batchLimit = min(_batchSize, target - deleted);
        final result = isKv
            ? await _runKvEvictionBatch(
                table,
                config,
                batchSize: batchLimit,
                cursor: cursor,
              )
            : await _runTableEvictionBatch(
                table,
                config,
                pkType ?? PrimaryKeyType.sequential,
                batchSize: batchLimit,
                cursor: cursor,
              );

        if (!result.ok) {
          saveRemainder();
          return (deleted: deleted, needResume: true);
        }
        if (result.deleted <= 0) {
          final cursorMoved =
              result.nextAfterPk != null || result.nextAfterIndexKey != null;
          if (cursorMoved) {
            stuckRounds = 0;
            continue;
          }
          stuckRounds++;
          if (stuckRounds >= 3) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
          continue;
        }

        stuckRounds = 0;
        deleted += result.deleted;
        pendingSinceFlush += result.deleted;
        CrontabManager.notifyActivity();

        if (pendingSinceFlush >= flushBatchSize) {
          lease.release();
          leaseHeld = false;
          if (!await _waitForWriteBufferDrain(
            threshold: 1,
            yieldController: yieldController,
          )) {
            saveRemainder();
            return (deleted: deleted, needResume: true);
          }
          pendingSinceFlush = 0;
        }
      } finally {
        if (leaseHeld) lease.release();
      }
      round++;
    }

    // Mid-episode pause already returned. Here: finish flush, then judge meta.
    if (!await _waitForWriteBufferDrain(
      threshold: 1,
      yieldController: yieldController,
    )) {
      saveRemainder();
      return (deleted: deleted, needResume: true);
    }
    await _reloadWatermarkCaches(table);

    if (deleted < target) {
      // Scan exhausted before the fixed count — drop remainder; next over-high
      // wake may open a fresh episode.
      _pendingDeleteTarget.remove(uid);
      return (deleted: deleted, needResume: false);
    }

    // Fixed target reached + flushed. Stop this episode — do not recompute a
    // new target from still-high soft-delete occupancy.
    _pendingDeleteTarget.remove(uid);
    return (deleted: deleted, needResume: false);
  }

  Future<void> _runCleanupCycle() async {
    if (_dataStore.isClosing) return;
    var holdBackgroundLease = false;
    CrontabManager.acquireBackgroundWorkLease(_backgroundLeaseId);
    try {
      final plans = await _getCleanupPlans();
      final kvTargets = await _activeKvTargets();
      if (plans.isEmpty && kvTargets.isEmpty) return;

      final int cycleStartMs = DateTime.now().millisecondsSinceEpoch;
      final yieldController = YieldController(
        'CapacityEvictionManager._runCleanupCycle',
        checkInterval: 1,
      );

      int totalDeleted = 0;

      for (final plan in plans.values) {
        if (_dataStore.isClosing) break;
        final table =
            await _dataStore.tableMetaManager?.getTableContext(plan.tableUid);
        if (table == null) continue;
        if (!await _shouldStartOrResumeEviction(table, plan.config)) {
          continue;
        }

        final outcome = await _drainTableToLow(
          table,
          plan.config,
          plan.pkType,
          isKv: false,
          yieldController: yieldController,
        );
        totalDeleted += outcome.deleted;
        if (outcome.needResume) holdBackgroundLease = true;
      }

      for (final target in kvTargets) {
        if (_dataStore.isClosing) break;
        if (!await _shouldStartOrResumeEviction(
          target.table,
          target.config,
        )) {
          continue;
        }

        final outcome = await _drainTableToLow(
          target.table,
          target.config,
          null,
          isKv: true,
          yieldController: yieldController,
        );
        totalDeleted += outcome.deleted;
        if (outcome.needResume) holdBackgroundLease = true;
      }

      if (totalDeleted > 0) {
        final elapsedMs = DateTime.now().millisecondsSinceEpoch - cycleStartMs;
        Logger.info(
          'Capacity eviction cycle deleted $totalDeleted records in ${elapsedMs}ms',
        );
      }
    } catch (e) {
      if (_dataStore.isInitialized && !_dataStore.isClosing) {
        Logger.warn('Capacity eviction cycle failed', rawError: e);
      }
    } finally {
      if (_dataStore.isClosing || !_cleanupRegistered) {
        // Close/unregister is terminal — never re-arm resume after teardown.
        _backlogPending = false;
        _resumeTimer?.cancel();
        _resumeTimer = null;
        CrontabManager.releaseBackgroundWorkLease(_backgroundLeaseId);
      } else {
        _backlogPending = holdBackgroundLease;
        if (!holdBackgroundLease) {
          CrontabManager.releaseBackgroundWorkLease(_backgroundLeaseId);
        } else {
          // Do not wait for minutes1 (~30–60s) to continue an unfinished drain.
          _scheduleBacklogResume();
        }
      }
    }
  }
}
