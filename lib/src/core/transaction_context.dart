import 'dart:async';
import '../model/change_event.dart';
import '../model/data_store_config.dart';
import '../model/table_identity.dart';

/// Lightweight transaction-scoped context for tracking touched file paths
/// without introducing circular dependencies. Values are stored in Zone.
class TransactionContext {
  /// Zone key to store a `Set<String>` of touched file paths in current transaction
  static const Symbol touchedPathsKey = #to_touched_paths;

  /// Zone key for current transaction id
  static const Symbol currentTxIdKey = #to_current_tx_id;

  /// Zone key for current transaction isolation level
  static const Symbol isolationLevelKey = #to_isolation_level;

  /// Zone key for current transaction acquired exclusive locks: `Map<resource, operationId>`
  static const Symbol acquiredExclusiveLocksKey = #to_exclusive_locks;

  /// Zone key for read-set tracking in current transaction: `Map<tableUid, Set<primaryKey>>`
  static const Symbol readKeysKey = #to_read_keys;

  /// Zone key indicating we are applying commit (bypassing tx deferral)
  static const Symbol applyingCommitKey = #to_applying_commit;

  /// Zone key for deferred [ChangeEvent]s flushed after successful commit.
  /// External watchers must not observe uncommitted buffer writes.
  static const Symbol pendingChangeEventsKey = #to_pending_change_events;

  /// Register a file path as touched in current transaction scope (if any)
  static void registerTouchedPath(String path) {
    final set = Zone.current[touchedPathsKey] as Set<String>?;
    if (set == null) return;
    set.add(path);
  }

  /// Get a snapshot of touched paths in the current transaction scope
  static Set<String> getTouchedPaths() {
    final set = Zone.current[touchedPathsKey] as Set<String>?;
    return set ?? const <String>{};
  }

  /// Get current transaction id from Zone if any
  static String? getCurrentTransactionId() {
    return Zone.current[currentTxIdKey] as String?;
  }

  /// Get current transaction isolation level from Zone if any
  static TransactionIsolationLevel? getCurrentIsolationLevel() {
    return Zone.current[isolationLevelKey] as TransactionIsolationLevel?;
  }

  /// Register an acquired exclusive lock for current transaction
  static void registerExclusiveLock(String resource, String operationId) {
    final map = Zone.current[acquiredExclusiveLocksKey] as Map<String, String>?;
    if (map == null) return;
    map[resource] = operationId;
  }

  /// Get snapshot of acquired exclusive locks
  static Map<String, String> getExclusiveLocks() {
    final map = Zone.current[acquiredExclusiveLocksKey] as Map<String, String>?;
    return map == null ? <String, String>{} : Map<String, String>.from(map);
  }

  /// Register a read key under table in current transaction scope (for SSI)
  static void registerReadKey(TableUid tableUid, String primaryKey) {
    final map = Zone.current[readKeysKey] as Map<TableUid, Set<String>>?;
    if (map == null) return;
    final set = map.putIfAbsent(tableUid, () => <String>{});
    set.add(primaryKey);
  }

  /// Snapshot read keys map
  static Map<TableUid, Set<String>> getReadKeys() {
    final map = Zone.current[readKeysKey] as Map<TableUid, Set<String>>?;
    if (map == null) return <TableUid, Set<String>>{};
    // deep copy sets
    final out = <TableUid, Set<String>>{};
    map.forEach((k, v) {
      out[k] = Set<String>.from(v);
    });
    return out;
  }

  /// Check if we are currently applying commit
  static bool isApplyingCommit() {
    return (Zone.current[applyingCommitKey] as bool?) == true;
  }

  /// Whether change notifications should be deferred until commit.
  ///
  /// True while executing the user transaction body (writes land in the
  /// deferred txn buffer and are invisible to external queries). False
  /// during [isApplyingCommit] when changes are promoted to the visible
  /// write buffer, and outside any transaction.
  static bool shouldDeferChangeNotification() {
    return getCurrentTransactionId() != null && !isApplyingCommit();
  }

  /// Enqueue a change event for flush after successful commit.
  /// No-op outside a transaction zone that installed the pending list.
  static void enqueuePendingChangeEvent(ChangeEvent event) {
    final list = Zone.current[pendingChangeEventsKey] as List<ChangeEvent>?;
    if (list == null) return;
    list.add(event);
  }

  /// Snapshot and clear pending change events (or empty if none).
  static List<ChangeEvent> takePendingChangeEvents() {
    final list = Zone.current[pendingChangeEventsKey] as List<ChangeEvent>?;
    if (list == null || list.isEmpty) return const <ChangeEvent>[];
    final out = List<ChangeEvent>.from(list);
    list.clear();
    return out;
  }

  /// Zone key indicating system/internal operation (bypass certain gates)
  static const Symbol systemOpKey = #tostore_system_op;

  /// Whether current zone is marked as a system/internal operation
  static bool isSystemOperation() {
    return (Zone.current[systemOpKey] as bool?) == true;
  }

  /// Run action in a zone marked as system/internal operation
  static Future<T> runAsSystemOperation<T>(
      FutureOr<T> Function() action) async {
    return await runZoned(() async {
      return await Future.sync(action);
    }, zoneValues: {systemOpKey: true});
  }
}
