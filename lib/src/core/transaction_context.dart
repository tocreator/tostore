import 'dart:async';
import '../model/data_store_config.dart';

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

  /// Zone key for read-set tracking in current transaction: `Map<tableName, Set<primaryKey>>`
  static const Symbol readKeysKey = #to_read_keys;

  /// Zone key indicating we are applying commit (bypassing tx deferral)
  static const Symbol applyingCommitKey = #to_applying_commit;

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
  static void registerReadKey(String tableName, String primaryKey) {
    final map = Zone.current[readKeysKey] as Map<String, Set<String>>?;
    if (map == null) return;
    final set = map.putIfAbsent(tableName, () => <String>{});
    set.add(primaryKey);
  }

  /// Snapshot read keys map
  static Map<String, Set<String>> getReadKeys() {
    final map = Zone.current[readKeysKey] as Map<String, Set<String>>?;
    if (map == null) return <String, Set<String>>{};
    // deep copy sets
    final out = <String, Set<String>>{};
    map.forEach((k, v) {
      out[k] = Set<String>.from(v);
    });
    return out;
  }

  /// Check if we are currently applying commit
  static bool isApplyingCommit() {
    return (Zone.current[applyingCommitKey] as bool?) == true;
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
