import 'lock_manager.dart';
import 'workload_scheduler.dart';

/// Registry for shared database engine resources.
///
/// Ensures that multiple DataStoreImpl instances (e.g. primary and migration)
/// sharing the same physical database also share concurrency and resource management.
class SharedEngineRegistry {
  static final Map<String, LockManager> _lockManagers = {};
  static final Map<String, WorkloadScheduler> _schedulers = {};

  /// Get or create a shared LockManager for a specific database.
  static LockManager getLockManager(String dbKey, {int? timeout}) {
    return _lockManagers.putIfAbsent(
      dbKey,
      () => LockManager(baseLockTimeout: timeout ?? 300000),
    );
  }

  /// Get or create a shared WorkloadScheduler for a specific database.
  static WorkloadScheduler getWorkloadScheduler(String dbKey, int globalMax) {
    return _schedulers.putIfAbsent(
      dbKey,
      () => WorkloadScheduler(globalMax: globalMax),
    );
  }

  /// Remove registries for a database (e.g. on full close).
  static void remove(String dbKey) {
    _lockManagers[dbKey]?.dispose();
    _lockManagers.remove(dbKey);
    _schedulers.remove(dbKey);
  }
}
