import 'dart:async';
import 'dart:collection';

import '../handler/logger.dart';
import '../model/meta_info.dart';
import '../model/parallel_journal_entry.dart';
import 'crontab_manager.dart';
import 'data_store_impl.dart';
import 'workload_scheduler.dart';

/// Background compaction manager.
///
/// Design goals:
/// - **No global scanning**: never iterate all partitions in huge deployments.
/// - **Write-triggered**: writes enqueue compact candidates cheaply (O(1)).
/// - **Budgeted background**: periodic worker consumes a bounded amount of work.
/// - **Idempotent & deduplicated**: repeated triggers collapse into one pending task.
final class CompactionManager {
  final DataStoreImpl _dataStore;

  final Queue<_CompactionTask> _queue = Queue<_CompactionTask>();
  final Set<String> _dedup = <String>{};
  // Latest locality hints (best-effort).
  final Map<String, TreePagePtr> _tableHint = <String, TreePagePtr>{};
  final Map<String, TreePagePtr> _indexHint = <String, TreePagePtr>{};

  bool _pumpInProgress = false;

  // Policy: run only when the system is idle enough.
  static const int _maxWalPendingForIdle = 200;
  static const int _maxWriteQueueForIdle = 200;

  // Per-tick budgets (bounded; never "run until empty").
  static const int _idleBudgetMs = 600;
  static const int _busyBudgetMs = 0; // busy => skip
  static const int _maxTasksPerTick = 16;

  CompactionManager(this._dataStore) {
    // Keep cadence low to avoid timer overhead; work is budgeted anyway.
    CrontabManager.addCallback(ExecuteInterval.minutes1, _tick);
  }

  void dispose() {
    try {
      CrontabManager.removeCallback(ExecuteInterval.minutes1, _tick);
      _queue.clear();
      _dedup.clear();
      _tableHint.clear();
      _indexHint.clear();
      _pumpInProgress = false;
    } catch (_) {}
  }

  /// Enqueue a table compaction task (deduplicated by table).
  void enqueueTable(String tableName, {TreePagePtr? hint}) {
    if (tableName.isEmpty) return;
    final key = 't:$tableName';
    if (hint != null && !hint.isNull) {
      _tableHint[tableName] = hint;
    }
    if (_dedup.contains(key)) return;
    _dedup.add(key);
    _queue.add(_CompactionTask.table(tableName));
  }

  /// Enqueue an index compaction task (deduplicated by table+index).
  void enqueueIndex(String tableName, String indexName, {TreePagePtr? hint}) {
    if (tableName.isEmpty || indexName.isEmpty) return;
    final key = 'i:$tableName:$indexName';
    if (hint != null && !hint.isNull) {
      _indexHint['$tableName:$indexName'] = hint;
    }
    if (_dedup.contains(key)) return;
    _dedup.add(key);
    _queue.add(_CompactionTask.index(tableName, indexName));
  }

  Future<void> _tick() async {
    if (_pumpInProgress) return;
    if (_queue.isEmpty) return;
    // Only run after engine init to avoid startup churn.
    if (!_dataStore.isInitialized) return;
    // Avoid running on migration instance.
    if (_dataStore.isMigrationInstance) return;

    _pumpInProgress = true;
    try {
      await _pumpOnce();
    } catch (e) {
      Logger.warn('Compaction tick failed: $e', label: 'CompactionManager');
    } finally {
      _pumpInProgress = false;
    }
  }

  bool _isIdleEnough() {
    // Avoid competing with flush batches and hot write paths.
    try {
      if (_dataStore.parallelJournalManager.activeBatchContext != null) {
        return false;
      }
    } catch (_) {}
    try {
      if (_dataStore.writeBufferManager.queueLength > _maxWriteQueueForIdle) {
        return false;
      }
    } catch (_) {}
    try {
      if (_dataStore.walManager.pendingQueueLength > _maxWalPendingForIdle) {
        return false;
      }
    } catch (_) {}
    return true;
  }

  Future<void> _pumpOnce() async {
    if (_queue.isEmpty) return;

    final idle = _isIdleEnough();
    final int budgetMs = idle ? _idleBudgetMs : _busyBudgetMs;
    if (budgetMs <= 0) return;

    // Small fixed per-task work (prevents long stalls even within idle budget).
    const int maxVisitedLeaves = 64;
    const int maxMerges = 8;

    final sw = Stopwatch()..start();
    int tasks = 0;

    while (_queue.isNotEmpty &&
        tasks < _maxTasksPerTick &&
        sw.elapsedMilliseconds < budgetMs) {
      // Acquire a small maintenance token per task. If contention appears, stop immediately.
      final lease = await _dataStore.workloadScheduler.tryAcquire(
        WorkloadType.maintenance,
        requestedTokens: 1,
        minTokens: 1,
        label: 'CompactionManager',
      );
      if (lease == null) return;

      try {
        final task = _queue.removeFirst();
        final dedupKey = task.dedupKey;
        bool finished = true;
        try {
          if (task.kind == _CompactionKind.table) {
            final TreePagePtr? hint = _tableHint[task.tableName];
            final next =
                await _dataStore.tableTreePartitionManager.compactLeafChain(
              tableName: task.tableName,
              startFrom: task.cursor ?? hint,
              maxVisitedLeaves: maxVisitedLeaves,
              maxMerges: maxMerges,
              batchContext: BatchContext.maintenance(''),
            );
            if (next != null && !next.isNull) {
              _queue.add(task.withCursor(next));
              finished = false;
            }
          } else {
            final TreePagePtr? hint =
                _indexHint['${task.tableName}:${task.indexName}'];
            final next =
                await _dataStore.indexTreePartitionManager.compactLeafChain(
              tableName: task.tableName,
              indexName: task.indexName!,
              startFrom: task.cursor ?? hint,
              maxVisitedLeaves: maxVisitedLeaves,
              maxMerges: maxMerges,
              batchContext: BatchContext.maintenance(''),
            );
            if (next != null && !next.isNull) {
              _queue.add(task.withCursor(next));
              finished = false;
            }
          }
        } finally {
          if (finished) {
            _dedup.remove(dedupKey);
            if (task.kind == _CompactionKind.table) {
              _tableHint.remove(task.tableName);
            } else {
              _indexHint.remove('${task.tableName}:${task.indexName}');
            }
          }
        }
      } finally {
        lease.release();
      }

      tasks++;
      // If system becomes busy mid-tick, stop early.
      if (!_isIdleEnough()) return;
    }
  }
}

enum _CompactionKind { table, idx }

final class _CompactionTask {
  final _CompactionKind kind;
  final String tableName;
  final String? indexName;
  final TreePagePtr? cursor;

  const _CompactionTask._(
      {required this.kind,
      required this.tableName,
      this.indexName,
      this.cursor});

  factory _CompactionTask.table(String table) =>
      _CompactionTask._(kind: _CompactionKind.table, tableName: table);

  factory _CompactionTask.index(String table, String index) =>
      _CompactionTask._(
          kind: _CompactionKind.idx, tableName: table, indexName: index);

  String get dedupKey => kind == _CompactionKind.table
      ? 't:$tableName'
      : 'i:$tableName:$indexName';

  _CompactionTask withCursor(TreePagePtr next) => _CompactionTask._(
        kind: kind,
        tableName: tableName,
        indexName: indexName,
        cursor: next,
      );
}
