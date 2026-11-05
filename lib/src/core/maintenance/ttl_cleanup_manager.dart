import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../../handler/logger.dart';
import '../../handler/memcomparable.dart';
import '../../model/index_search.dart';
import '../../model/system_table.dart';
import '../../model/table_context.dart';
import '../../model/table_identity.dart';
import '../../model/table_schema.dart';
import '../compute/workload_scheduler.dart';
import '../compute/yield_controller.dart';
import '../engine/data_store_impl.dart';
import '../query/query_condition.dart';
import 'crontab_manager.dart';

class _TtlCleanupPlan {
  final TableUid tableUid;
  final int ttlMs;
  final String sourceField;

  const _TtlCleanupPlan({
    required this.tableUid,
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

  /// Timer for startup one-shot trigger
  Timer? _startupTimer;

  TtlCleanupManager(this._dataStore);

  void registerCleanupTask() {
    try {
      if (_cleanupRegistered) return;
      CrontabManager.addCallback(ExecuteInterval.minutes1, _onScheduleTick);
      _cleanupRegistered = true;

      // One-shot delayed trigger shortly after startup so short-lived/mobile
      // apps don't have to wait for the next cron tick. Does not block the
      // main thread and is still subject to ttlCleanupIntervalMs throttling.
      _startupTimer = Timer(const Duration(seconds: 10), () {
        _onScheduleTick();
      });
    } catch (_) {}
  }

  void unregisterCleanupTask() {
    _startupTimer?.cancel();
    _startupTimer = null;

    if (_cleanupRegistered) {
      try {
        CrontabManager.removeCallback(
            ExecuteInterval.minutes1, _onScheduleTick);
      } catch (_) {}
      _cleanupRegistered = false;
    }
    _cleanupRunning = false;
    _lastCleanupMs = 0;
    CrontabManager.releaseBackgroundWorkLease(_backgroundLeaseId);
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
      _planCache.remove(schema.tableUid);
      _planCacheRefreshedMs = DateTime.now().millisecondsSinceEpoch;
      return;
    }

    final sourceField = (ttl.sourceField == null || ttl.sourceField!.isEmpty)
        ? _systemIngestTsMsField
        : ttl.sourceField!;

    _planCache[schema.tableUid] = _TtlCleanupPlan(
      tableUid: schema.tableUid,
      ttlMs: ttl.ttlMs,
      sourceField: sourceField,
    );
    _planCacheRefreshedMs = DateTime.now().millisecondsSinceEpoch;
  }

  void removePlanForTable(TableContext table) {
    if (!_planCacheFullyLoaded) return;
    _planCache.remove(table.tableUid);
    _planCacheRefreshedMs = DateTime.now().millisecondsSinceEpoch;
  }

  void _onScheduleTick() {
    if (!_dataStore.isInitialized || _dataStore.isClosing) return;
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

  List<String> _systemKvTables() {
    return <String>[
      SystemTable.getKeyValueName(false),
      SystemTable.getKeyValueName(true),
    ];
  }

  Future<List<TableContext>> _systemKvTableContexts() async {
    final contexts = <TableContext>[];
    for (final name in _systemKvTables()) {
      final uid =
          await _dataStore.tableMetaManager?.getUidByName(TableName(name));
      if (uid == null) continue;
      final ctx = await _dataStore.tableMetaManager?.getTableContext(uid);
      if (ctx != null) contexts.add(ctx);
    }
    return contexts;
  }

  Future<Map<String, _TtlCleanupPlan>> _getCleanupPlans() async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final refreshIntervalMs =
        max(_dataStore.config.ttlCleanupIntervalMs * 6, 1800000);
    if (_planCacheFullyLoaded &&
        nowMs - _planCacheRefreshedMs < refreshIntervalMs) {
      return Map<String, _TtlCleanupPlan>.from(_planCache);
    }

    final tables = await _dataStore.tableMetaManager
            ?.listAllTables(onlyUserTables: true) ??
        const <String>[];
    if (tables.isEmpty) {
      _planCache.clear();
      _planCacheRefreshedMs = nowMs;
      _planCacheFullyLoaded = true;
      return Map<String, _TtlCleanupPlan>.from(_planCache);
    }

    try {
      final newPlans = <String, _TtlCleanupPlan>{};
      final yieldController = YieldController(
          'TtlCleanupManager.refreshPlanCache',
          checkInterval: 1);
      for (final table in tables) {
        final y = yieldController.maybeYield();
        if (y != null) await y;

        final schema = await _dataStore.tableMetaManager
            ?.getTableSchemaByName(TableName(table));
        final ttl = schema?.ttlConfig;
        if (schema == null || ttl == null) continue;

        final sourceField =
            (ttl.sourceField == null || ttl.sourceField!.isEmpty)
                ? _systemIngestTsMsField
                : ttl.sourceField!;

        newPlans[schema.tableUid.value] = _TtlCleanupPlan(
          tableUid: schema.tableUid,
          ttlMs: ttl.ttlMs,
          sourceField: sourceField,
        );
      }

      _planCache
        ..clear()
        ..addAll(newPlans);
      _planCacheRefreshedMs = nowMs;
      _planCacheFullyLoaded = true;
      return Map<String, _TtlCleanupPlan>.from(_planCache);
    } catch (e) {
      Logger.warn('Refresh TTL plan cache failed', rawError: e);
      return Map<String, _TtlCleanupPlan>.from(_planCache);
    }
  }

  Future<_TtlBatchResult> _runCleanupBatch(
    _TtlCleanupPlan plan,
    DateTime cycleNow, {
    required int batchSize,
  }) async {
    final tableName = await _dataStore.tableMetaManager
            ?.resolveTableNameFromField(plan.tableUid) ??
        TableName(plan.tableUid.value);
    try {
      final table =
          await _dataStore.tableMetaManager?.getTableContext(plan.tableUid);
      if (table == null) {
        return const _TtlBatchResult(deleted: 0, ok: false);
      }
      final cutoff = cycleNow.subtract(Duration(milliseconds: plan.ttlMs));
      final cutoffIso = cutoff.toIso8601String();

      // Internal TTL source is virtual/index-only. Use TTL index range scan to fetch PKs.
      if (plan.sourceField == _systemIngestTsMsField) {
        final schema = table.schema;
        IndexUid? ttlIndexUid;
        for (final idx in schema.getAllIndexes()) {
          if (idx.fields.contains(TableSchema.internalTtlIngestTsMsField) &&
              idx.indexUid.isNotEmpty) {
            ttlIndexUid = idx.indexUid;
            break;
          }
        }
        if (ttlIndexUid == null || ttlIndexUid.isEmpty) {
          return const _TtlBatchResult(deleted: 0, ok: true);
        }

        final res = await _dataStore.indexManager?.searchIndex(
          table,
          ttlIndexUid,
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
          table,
          condition,
          limit: batchSize,
        );
        if (r.hasErrors) {
          Logger.warn(
            'TTL cleanup delete failed on $tableName: ${r.message}',
          );
          return const _TtlBatchResult(deleted: 0, ok: false);
        }

        final deletedCount = r.successCount;

        // Virtual ingest keys cannot be encoded from the row on DELETE.
        // Tombstone only known keyBytes from this search — under table write
        // lock via IndexManager (must not race flush). Real sourceField TTL
        // below uses deleteInternal alone (no side channel).
        if (deletedCount > 0 &&
            entries != null &&
            entries.isNotEmpty &&
            ttlIndexUid.isNotEmpty) {
          try {
            final keysByPk = <String, List<Uint8List>>{};
            for (final e in entries) {
              if (e.keyBytes.isEmpty) continue;
              (keysByPk[e.primaryKey] ??= <Uint8List>[]).add(e.keyBytes);
            }
            final tombstoneKeys = <Uint8List>[];
            for (final pk in r.successKeys) {
              final keyList = keysByPk[pk];
              if (keyList == null) continue;
              tombstoneKeys.addAll(keyList);
            }
            if (tombstoneKeys.isNotEmpty) {
              await _dataStore.indexManager?.removeIndexEntriesByRawKeys(
                table,
                ttlIndexUid,
                tombstoneKeys,
              );
            }
          } catch (e) {
            Logger.warn('TTL ingest index cleanup failed on $tableName',
                rawError: e);
          }
        }

        return _TtlBatchResult(deleted: deletedCount, ok: true);
      }

      // User-defined TTL source field: use regular predicate delete.
      final condition = QueryCondition()
        ..whereLessThanOrEqualTo(plan.sourceField, cutoffIso);
      final r = await _dataStore.deleteInternal(
        table,
        condition,
        orderBy: [plan.sourceField],
        limit: batchSize,
      );
      if (r.hasErrors) {
        Logger.warn(
          'TTL cleanup delete failed on $tableName: ${r.message}',
        );
        return const _TtlBatchResult(deleted: 0, ok: false);
      }

      return _TtlBatchResult(deleted: r.successCount, ok: true);
    } catch (e) {
      if (_dataStore.isClosing) {
        return const _TtlBatchResult(deleted: 0, ok: false);
      }
      Logger.warn('TTL cleanup batch failed on $tableName', rawError: e);
      return const _TtlBatchResult(deleted: 0, ok: false);
    }
  }

  String? _normalizeDateTimeIso(dynamic rawValue) {
    if (rawValue == null) return null;
    if (rawValue is DateTime) {
      return rawValue.toIso8601String();
    }
    if (rawValue is String) {
      final value = rawValue.trim();
      if (value.isEmpty) return null;
      return DateTime.tryParse(value)?.toIso8601String();
    }
    if (rawValue is int) {
      return DateTime.fromMillisecondsSinceEpoch(rawValue).toIso8601String();
    }
    if (rawValue is BigInt) {
      return DateTime.fromMillisecondsSinceEpoch(rawValue.toInt())
          .toIso8601String();
    }
    return null;
  }

  String? _decodeKvExpiryIso(Uint8List keyBytes) {
    try {
      final values = MemComparableKey.decodeTuple(keyBytes);
      if (values.isEmpty) return null;
      final raw = values.first;
      if (raw == null) return null;
      return raw.toString();
    } catch (_) {
      return null;
    }
  }

  Future<_TtlBatchResult> _runKvCleanupBatch(
    TableContext table,
    DateTime cycleNow, {
    required int batchSize,
  }) async {
    final tableName = table.tableName;
    try {
      final schema = table.schema;

      final pkName = schema.primaryKey;
      final res =
          await _dataStore.indexManager?.searchInternalKvExpiryIndexUpTo(
        table,
        cycleNow,
        limit: batchSize,
      );
      final entries = res?.entries ?? const <IndexSearchEntry>[];
      if (entries.isEmpty) {
        return const _TtlBatchResult(deleted: 0, ok: true);
      }

      int deletedCount = 0;
      // Verify/delete must stay per-row (stale keys / renewed expiry), but
      // tombstones flush once — same batch writeChanges path as table TTL.
      final tombstoneKeys = <Uint8List>[];
      void queueTombstone(Uint8List keyBytes) {
        if (keyBytes.isEmpty) return;
        tombstoneKeys.add(keyBytes);
      }

      final yieldController =
          YieldController('TtlCleanupManager._runKvCleanupBatch');
      for (final entry in entries) {
        final y1 = yieldController.maybeYield();
        if (y1 != null) await y1;
        if (_dataStore.isClosing) break;

        final records = (await _dataStore.queryExecutor.execute(
          table,
          condition: QueryCondition()..where(pkName, '=', entry.primaryKey),
          limit: 1,
        ))
            .records;
        if (records.isEmpty) {
          queueTombstone(entry.keyBytes);
          continue;
        }

        final row = records.first;
        final currentExpiresAtIso =
            _normalizeDateTimeIso(row[SystemTable.keyValueExpiresAtField]);
        if (currentExpiresAtIso == null) {
          queueTombstone(entry.keyBytes);
          continue;
        }

        final currentExpiresAt = DateTime.tryParse(currentExpiresAtIso);
        if (currentExpiresAt == null || currentExpiresAt.isAfter(cycleNow)) {
          queueTombstone(entry.keyBytes);
          continue;
        }

        final deleteResult = await _dataStore.deleteInternal(
          table,
          QueryCondition()
            ..where(pkName, '=', entry.primaryKey)
            ..where(
              SystemTable.keyValueExpiresAtField,
              '=',
              currentExpiresAtIso,
            ),
          limit: 1,
        );
        if (deleteResult.hasErrors) {
          if (_dataStore.isClosing) {
            return const _TtlBatchResult(deleted: 0, ok: false);
          }
          Logger.warn(
            'KV TTL cleanup delete failed on $tableName pk=${entry.primaryKey}: ${deleteResult.message}',
          );
          // Still flush tombstones collected so far (orphan GC progress).
          if (tombstoneKeys.isNotEmpty) {
            await _dataStore.indexManager
                ?.removeInternalKvExpiryIndexEntriesByRawKeys(
              table,
              tombstoneKeys,
            );
          }
          return const _TtlBatchResult(deleted: 0, ok: false);
        }

        if (deleteResult.successCount > 0) {
          deletedCount += deleteResult.successCount;
        }

        queueTombstone(entry.keyBytes);

        if (deleteResult.successCount > 0) {
          final currentKeyBytes =
              await _dataStore.indexManager?.encodeInternalKvExpiryIndexKey(
            table,
            expiresAt: currentExpiresAtIso,
            primaryKey: entry.primaryKey,
          );
          if (currentKeyBytes != null &&
              currentKeyBytes.isNotEmpty &&
              MemComparableKey.compare(currentKeyBytes, entry.keyBytes) != 0) {
            queueTombstone(currentKeyBytes);
          }
        } else {
          final candidateExpiresAtIso = _decodeKvExpiryIso(entry.keyBytes);
          if (candidateExpiresAtIso != null &&
              candidateExpiresAtIso != currentExpiresAtIso) {
            queueTombstone(entry.keyBytes);
          }
        }
      }

      if (tombstoneKeys.isNotEmpty) {
        await _dataStore.indexManager
            ?.removeInternalKvExpiryIndexEntriesByRawKeys(
          table,
          tombstoneKeys,
        );
      }

      return _TtlBatchResult(deleted: deletedCount, ok: true);
    } catch (e) {
      if (_dataStore.isClosing) {
        return const _TtlBatchResult(deleted: 0, ok: false);
      }
      Logger.warn('KV TTL cleanup batch failed on $tableName', rawError: e);
      return const _TtlBatchResult(deleted: 0, ok: false);
    }
  }

  Future<void> _runCleanupCycle() async {
    if (_dataStore.isClosing) return;
    // Keep crontab awake only when we pause with unfinished work; resume on
    // the next minutes1 tick (no separate retry timer).
    var holdBackgroundLease = false;
    CrontabManager.acquireBackgroundWorkLease(_backgroundLeaseId);
    try {
      final plans = await _getCleanupPlans();
      final systemKvTables = await _systemKvTableContexts();
      if (plans.isEmpty && systemKvTables.isEmpty) return;

      const int batchSize = 500;
      final int cycleStartMs = DateTime.now().millisecondsSinceEpoch;
      final DateTime cycleNow = DateTime.now();
      final yieldController = YieldController(
          'TtlCleanupManager._runCleanupCycle',
          checkInterval: 1);

      int totalDeleted = 0;
      int round = 0;
      var activePlans = plans.values.toList(growable: false);
      var activeKvTables = systemKvTables;

      while (activePlans.isNotEmpty || activeKvTables.isNotEmpty) {
        final y2 = yieldController.maybeYield();
        if (y2 != null) await y2;
        if (_dataStore.isClosing) break;

        final lease = await _dataStore.workloadScheduler.tryAcquire(
          WorkloadType.maintenance,
          requestedTokens: 1,
          minTokens: 1,
          label: 'ttl-cleanup-round-$round',
        );

        if (lease == null) {
          holdBackgroundLease = true;
          break;
        }

        try {
          int roundDeleted = 0;
          final nextPlans = <_TtlCleanupPlan>[];
          final nextKvTables = <TableContext>[];
          bool yieldedToForeground = false;

          final int writeBatchSize = _dataStore.config.writeBatchSize;
          final int foregroundBusyThreshold =
              writeBatchSize > 0 ? (writeBatchSize * 0.2).ceil() : 0;

          // 1. Process user table TTL plans sequentially
          for (final plan in activePlans) {
            final y = yieldController.maybeYield();
            if (y != null) await y;
            if (_dataStore.isClosing) {
              nextPlans.add(plan);
              break;
            }

            // Preemptive backpressure: yield immediately if foreground writes are queueing
            if (foregroundBusyThreshold > 0 &&
                _dataStore.writeBufferManager.queueLength >=
                    foregroundBusyThreshold) {
              yieldedToForeground = true;
              nextPlans.add(plan);
              break;
            }

            final result = await _runCleanupBatch(
              plan,
              cycleNow,
              batchSize: batchSize,
            );

            if (result.ok && result.deleted > 0) {
              roundDeleted += result.deleted;
              totalDeleted += result.deleted;
            }

            // Full batch ⇒ more expired rows likely remain; keep draining.
            if (result.deleted >= batchSize) {
              nextPlans.add(plan);
            }
          }

          // 2. Process system KV tables sequentially
          if (!yieldedToForeground && !_dataStore.isClosing) {
            for (final table in activeKvTables) {
              final y = yieldController.maybeYield();
              if (y != null) await y;
              if (_dataStore.isClosing) {
                nextKvTables.add(table);
                break;
              }

              // Preemptive backpressure: yield immediately if foreground writes are queueing
              if (foregroundBusyThreshold > 0 &&
                  _dataStore.writeBufferManager.queueLength >=
                      foregroundBusyThreshold) {
                yieldedToForeground = true;
                nextKvTables.add(table);
                break;
              }

              final result = await _runKvCleanupBatch(
                table,
                cycleNow,
                batchSize: batchSize,
              );

              if (result.ok && result.deleted > 0) {
                roundDeleted += result.deleted;
                totalDeleted += result.deleted;
              }

              if (result.deleted >= batchSize) {
                nextKvTables.add(table);
              }
            }
          }

          final bool hasBacklog =
              nextPlans.isNotEmpty || nextKvTables.isNotEmpty;

          if (yieldedToForeground) {
            // Write buffer busy — resume on next minutes1 crontab tick.
            activePlans = const <_TtlCleanupPlan>[];
            activeKvTables = const <TableContext>[];
            holdBackgroundLease = true;
          } else if (roundDeleted <= 0) {
            // No deletes this round ⇒ no known expired backlog for these plans.
            activePlans = const <_TtlCleanupPlan>[];
            activeKvTables = const <TableContext>[];
          } else if (hasBacklog) {
            // Idle: keep draining in this while-loop.
            activePlans = nextPlans;
            activeKvTables = nextKvTables;
            CrontabManager.notifyActivity();
          } else {
            activePlans = const <_TtlCleanupPlan>[];
            activeKvTables = const <TableContext>[];
          }

          if (activePlans.isEmpty && activeKvTables.isEmpty) break;
        } finally {
          lease.release();
        }

        round++;
      }

      if (totalDeleted > 0) {
        final elapsedMs = DateTime.now().millisecondsSinceEpoch - cycleStartMs;
        Logger.info(
          'TTL cleanup cycle deleted $totalDeleted records in ${elapsedMs}ms',
        );
      }
    } catch (e) {
      if (_dataStore.isInitialized && !_dataStore.isClosing) {
        Logger.warn('TTL cleanup cycle failed', rawError: e);
      }
    } finally {
      if (!holdBackgroundLease) {
        CrontabManager.releaseBackgroundWorkLease(_backgroundLeaseId);
      }
    }
  }
}
