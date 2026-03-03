import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../handler/logger.dart';
import '../handler/parallel_processor.dart';
import '../model/data_block_entry.dart';
import '../model/table_schema.dart';
import '../query/query_condition.dart';
import '../model/index_search.dart';
import 'crontab_manager.dart';
import 'data_store_impl.dart';
import 'workload_scheduler.dart';
import 'yield_controller.dart';

class _TtlCleanupPlan {
  final String tableName;
  final int ttlMs;
  final String sourceField;

  const _TtlCleanupPlan({
    required this.tableName,
    required this.ttlMs,
    required this.sourceField,
  });
}

class _TtlBatchResult {
  final int deleted;
  final bool ok;

  const _TtlBatchResult({
    required this.deleted,
    required this.ok,
  });
}

class TtlCleanupManager {
  static const String _systemIngestTsMsField = '_system_ingest_ts_ms';
  static const String _backgroundLeaseId = 'ttl_cleanup';

  final DataStoreImpl _dataStore;

  bool _cleanupRegistered = false;
  int _lastCleanupMs = 0;
  bool _cleanupRunning = false;
  int _planCacheRefreshedMs = 0;
  bool _planCacheFullyLoaded = false;
  final Map<String, _TtlCleanupPlan> _planCache = <String, _TtlCleanupPlan>{};

  TtlCleanupManager(this._dataStore);

  void registerCleanupTask() {
    try {
      if (_cleanupRegistered) return;
      CrontabManager.addCallback(ExecuteInterval.minutes5, _onScheduleTick);
      _cleanupRegistered = true;

      // One-shot delayed trigger shortly after startup so short-lived/mobile
      // apps don't have to wait for the next cron tick. Does not block the
      // main thread and is still subject to ttlCleanupIntervalMs throttling.
      Timer(const Duration(seconds: 10), () {
        _onScheduleTick();
      });
    } catch (_) {}
  }

  void unregisterCleanupTask() {
    if (_cleanupRegistered) {
      try {
        CrontabManager.removeCallback(
            ExecuteInterval.minutes5, _onScheduleTick);
      } catch (_) {}
      _cleanupRegistered = false;
    }
    _cleanupRunning = false;
    _lastCleanupMs = 0;
  }

  void invalidatePlanCache() {
    _planCacheRefreshedMs = 0;
    _planCacheFullyLoaded = false;
    _planCache.clear();
  }

  void upsertPlanForSchema(TableSchema schema) {
    if (!_planCacheFullyLoaded) return;

    final ttl = schema.ttlConfig;
    if (ttl == null) {
      _planCache.remove(schema.name);
      _planCacheRefreshedMs = DateTime.now().millisecondsSinceEpoch;
      return;
    }

    final sourceField = (ttl.sourceField == null || ttl.sourceField!.isEmpty)
        ? _systemIngestTsMsField
        : ttl.sourceField!;

    _planCache[schema.name] = _TtlCleanupPlan(
      tableName: schema.name,
      ttlMs: ttl.ttlMs,
      sourceField: sourceField,
    );
    _planCacheRefreshedMs = DateTime.now().millisecondsSinceEpoch;
  }

  void removePlanForTable(String tableName) {
    if (!_planCacheFullyLoaded) return;
    _planCache.remove(tableName);
    _planCacheRefreshedMs = DateTime.now().millisecondsSinceEpoch;
  }

  void _onScheduleTick() {
    if (_cleanupRunning) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastCleanupMs < _dataStore.config.ttlCleanupIntervalMs) {
      return;
    }
    _lastCleanupMs = now;
    _cleanupRunning = true;
    _runCleanupCycle().whenComplete(() {
      _cleanupRunning = false;
    });
  }

  Future<Map<String, _TtlCleanupPlan>> _getCleanupPlans() async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final refreshIntervalMs =
        max(_dataStore.config.ttlCleanupIntervalMs * 6, 1800000);
    if (_planCacheFullyLoaded &&
        nowMs - _planCacheRefreshedMs < refreshIntervalMs) {
      return _planCache;
    }

    final tables =
        await _dataStore.schemaManager?.listAllTables(onlyUserTables: true) ??
            const <String>[];
    if (tables.isEmpty) {
      _planCache.clear();
      _planCacheRefreshedMs = nowMs;
      _planCacheFullyLoaded = true;
      return _planCache;
    }

    WorkloadLease? lease;
    try {
      lease = await _dataStore.workloadScheduler.tryAcquire(
        WorkloadType.maintenance,
        requestedTokens: _dataStore.workloadScheduler
            .capacityTokens(WorkloadType.maintenance),
        minTokens: 1,
        label: 'ttl-plan-scan',
      );

      final int maxParallel =
          max(1, min(_dataStore.config.maxIoConcurrency, 8));
      final int concurrency =
          (lease?.asConcurrency(2.0) ?? 1).clamp(1, maxParallel);

      final tasks = tables
          .map<Future<_TtlCleanupPlan?> Function()>(
            (table) => () async {
              final schema =
                  await _dataStore.schemaManager?.getTableSchema(table);
              final ttl = schema?.ttlConfig;
              if (schema == null || ttl == null) return null;

              final sourceField =
                  (ttl.sourceField == null || ttl.sourceField!.isEmpty)
                      ? _systemIngestTsMsField
                      : ttl.sourceField!;

              return _TtlCleanupPlan(
                tableName: table,
                ttlMs: ttl.ttlMs,
                sourceField: sourceField,
              );
            },
          )
          .toList(growable: false);

      final results = await ParallelProcessor.execute<_TtlCleanupPlan?>(
        tasks,
        label: 'ttl-plan-scan',
        concurrency: concurrency,
        continueOnError: true,
      );

      _planCache
        ..clear()
        ..addEntries(
          results.whereType<_TtlCleanupPlan>().map(
                (plan) => MapEntry(plan.tableName, plan),
              ),
        );
      _planCacheRefreshedMs = nowMs;
      _planCacheFullyLoaded = true;
      return _planCache;
    } catch (e) {
      Logger.warn('Refresh TTL plan cache failed: $e',
          label: 'TtlCleanupManager._getCleanupPlans');
      return _planCache;
    } finally {
      lease?.release();
    }
  }

  Future<_TtlBatchResult> _runCleanupBatch(
    _TtlCleanupPlan plan,
    DateTime cycleNow, {
    required int batchSize,
  }) async {
    try {
      final cutoff = cycleNow.subtract(Duration(milliseconds: plan.ttlMs));
      final cutoffIso = cutoff.toIso8601String();

      // Internal TTL source is virtual/index-only. Use TTL index range scan to fetch PKs.
      if (plan.sourceField == _systemIngestTsMsField) {
        final schema =
            await _dataStore.schemaManager?.getTableSchema(plan.tableName);
        if (schema == null) {
          return const _TtlBatchResult(deleted: 0, ok: false);
        }
        final ttlIndexName = IndexSchema(
          indexName: TableSchema.internalTtlIngestTsMsField,
          fields: const [TableSchema.internalTtlIngestTsMsField],
          unique: false,
        ).actualIndexName;

        final res = await _dataStore.indexManager?.searchIndex(
          plan.tableName,
          ttlIndexName,
          IndexCondition.lessThanOrEqual(cutoffIso),
          limit: batchSize,
        );

        final pks = res?.primaryKeys ?? const <String>[];
        final entries = res?.entries;
        if (pks.isEmpty) {
          return const _TtlBatchResult(deleted: 0, ok: true);
        }

        final pkName = schema.primaryKey;
        final condition = QueryCondition()..whereIn(pkName, pks);
        final r = await _dataStore.deleteInternal(
          plan.tableName,
          condition,
          limit: batchSize,
        );
        if (!r.isSuccess) {
          Logger.warn(
            'TTL cleanup delete failed on ${plan.tableName}: ${r.message}',
            label: 'TtlCleanupManager._runCleanupCycle',
          );
          return const _TtlBatchResult(deleted: 0, ok: false);
        }

        final deletedCount = r.successKeys.length;

        // Best-effort cleanup of TTL index entries for internal source.
        // We rely on IndexSearchResult.indexKeys being aligned with primaryKeys.
        if (deletedCount > 0 &&
            entries != null &&
            entries.length == pks.length) {
          try {
            final meta = await _dataStore.indexManager
                ?.getIndexMeta(plan.tableName, ttlIndexName);
            if (meta != null) {
              // Build pk -> index positions map to align deleted PKs with index keys.
              final Map<String, List<Uint8List>> keysByPk = {};
              for (final e in entries) {
                (keysByPk[e.primaryKey] ??= <Uint8List>[]).add(e.keyBytes);
              }

              Uint8List encodeDeleteValue() =>
                  Uint8List.fromList(const <int>[1]);

              final deltas = <DataBlockEntry>[];
              for (final pk in r.successKeys) {
                final keyList = keysByPk[pk];
                if (keyList == null || keyList.isEmpty) continue;
                for (final keyBytes in keyList) {
                  if (keyBytes.isEmpty) continue;
                  deltas.add(DataBlockEntry(keyBytes, encodeDeleteValue()));
                }
              }

              if (deltas.isNotEmpty) {
                await _dataStore.indexTreePartitionManager.writeChanges(
                  tableName: plan.tableName,
                  indexName: ttlIndexName,
                  indexMeta: meta,
                  deltas: deltas,
                );
              }
            }
          } catch (e) {
            Logger.warn(
              'TTL index cleanup failed on ${plan.tableName}: $e',
              label: 'TtlCleanupManager._runCleanupBatch',
            );
          }
        }

        return _TtlBatchResult(deleted: deletedCount, ok: true);
      }

      // User-defined TTL source field: use regular predicate delete.
      final condition = QueryCondition()
        ..whereLessThanOrEqualTo(plan.sourceField, cutoffIso);
      final r = await _dataStore.deleteInternal(plan.tableName, condition,
          limit: batchSize);
      if (!r.isSuccess) {
        Logger.warn(
          'TTL cleanup delete failed on ${plan.tableName}: ${r.message}',
          label: 'TtlCleanupManager._runCleanupCycle',
        );
        return const _TtlBatchResult(deleted: 0, ok: false);
      }

      return _TtlBatchResult(deleted: r.successKeys.length, ok: true);
    } catch (e) {
      Logger.warn('TTL cleanup batch failed on ${plan.tableName}: $e',
          label: 'TtlCleanupManager._runCleanupCycle');
      return const _TtlBatchResult(deleted: 0, ok: false);
    }
  }

  Future<void> _runCleanupCycle() async {
    bool cycleHasBacklog = false;
    CrontabManager.acquireBackgroundWorkLease(_backgroundLeaseId);
    try {
      final plans = await _getCleanupPlans();
      if (plans.isEmpty) return;

      const int batchSize = 1000;
      final int cycleStartMs = DateTime.now().millisecondsSinceEpoch;
      final DateTime cycleNow = DateTime.now();
      final yieldController = YieldController(
          'TtlCleanupManager._runCleanupCycle',
          checkInterval: 1);

      int totalDeleted = 0;
      int round = 0;
      var activePlans = plans.values.toList(growable: false);

      while (activePlans.isNotEmpty) {
        await yieldController.maybeYield();

        final lease = await _dataStore.workloadScheduler.tryAcquire(
          WorkloadType.maintenance,
          requestedTokens: _dataStore.workloadScheduler
              .capacityTokens(WorkloadType.maintenance),
          minTokens: 1,
          label: 'ttl-cleanup-round-$round',
        );

        if (lease == null) break;

        final int maxParallel =
            max(1, min(_dataStore.config.maxIoConcurrency, 8));
        final int concurrency = lease.asConcurrency(2.0).clamp(1, maxParallel);

        try {
          final tasks = activePlans
              .map<Future<_TtlBatchResult> Function()>(
                (plan) => () => _runCleanupBatch(
                      plan,
                      cycleNow,
                      batchSize: batchSize,
                    ),
              )
              .toList(growable: false);

          final roundResults = await ParallelProcessor.execute<_TtlBatchResult>(
            tasks,
            label: 'ttl-cleanup-round-$round',
            concurrency: concurrency,
            continueOnError: true,
          );

          int roundDeleted = 0;
          final nextPlans = <_TtlCleanupPlan>[];

          for (int i = 0; i < roundResults.length; i++) {
            final result = roundResults[i];
            final plan = activePlans[i];

            if (result == null || !result.ok) {
              continue;
            }

            final deleted = result.deleted;
            if (deleted > 0) {
              roundDeleted += deleted;
              totalDeleted += deleted;
              Logger.info(
                'TTL cleanup deleted $deleted rows from table ${plan.tableName}',
                label: 'TtlCleanupManager._runCleanupCycle',
              );
            }

            if (deleted >= batchSize) {
              nextPlans.add(plan);
            }
          }

          // Check write buffer pressure and intelligently decide whether to continue this cleanup cycle.
          final int writeBatchSize = _dataStore.config.writeBatchSize;
          final int queueLen = _dataStore.writeBufferManager.queueLength;
          final int flushThreshold =
              writeBatchSize > 0 ? (writeBatchSize / 10).ceil() : 0;
          final bool hasBacklog = nextPlans.isNotEmpty;
          final bool ioBusy = flushThreshold > 0 && queueLen >= flushThreshold;

          if (roundDeleted <= 0) {
            activePlans = const [];
          } else if (hasBacklog && !ioBusy) {
            // There is still TTL backlog and the write buffer is not busy:
            // continue another cleanup round and keep CrontabManager active.
            activePlans = nextPlans;
            CrontabManager.notifyActivity();
          } else {
            // Write buffer is under pressure or there is no backlog: yield to
            // foreground writes and end this cleanup cycle.
            activePlans = const [];
          }

          if (hasBacklog) {
            cycleHasBacklog = true;
          }

          if (activePlans.isEmpty) break;
        } finally {
          lease.release();
        }

        round++;
      }

      if (totalDeleted > 0) {
        final elapsedMs = DateTime.now().millisecondsSinceEpoch - cycleStartMs;
        Logger.info(
          'TTL cleanup cycle deleted $totalDeleted rows in ${elapsedMs}ms',
          label: 'TtlCleanupManager._runCleanupCycle',
        );
      }
    } catch (e) {
      Logger.warn('TTL cleanup cycle failed: $e',
          label: 'TtlCleanupManager._runCleanupCycle');
    } finally {
      // If this cycle did not see any backlog, it is safe to release the
      // background lease and allow CrontabManager to enter idle-sleep.
      // When backlog is detected, we intentionally keep the lease so future
      // idle-stop checks will keep the scheduler active until a backlog-free
      // cycle occurs.
      if (!cycleHasBacklog) {
        CrontabManager.releaseBackgroundWorkLease(_backgroundLeaseId);
      }
    }
  }
}
