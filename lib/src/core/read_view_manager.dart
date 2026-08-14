import 'dart:collection';

import '../model/wal_pointer.dart';
import 'crontab_manager.dart';
import 'data_store_impl.dart';
import 'yield_controller.dart';

/// ReadView: records the WAL position at query start
/// to prevent buffer data from being cleaned up
/// before the query is completed.
final class ReadView extends LinkedListEntry<ReadView> {
  final int id;
  final WalPointer? snapshotPointer;
  final int walCycle;
  final DateTime createdAt;

  ReadView({
    required this.id,
    this.snapshotPointer,
    required this.walCycle,
  }) : createdAt = DateTime.now();

  @override
  String toString() => 'ReadView(id: $id, snapshot: $snapshotPointer)';
}

/// Tracks active read views so flushed pending-buffer eviction can wait until
/// queries that still need file+buffer merge have finished.
///
/// Uses [LinkedList] ordered by creation time (head = oldest) for O(1) oldest
/// snapshot / createdAt. Does not raise buffer thresholds -- pending trees use
/// [TreeCacheEvictionMode.none] and a flushed-evict queue instead.
class ReadViewManager {
  final DataStoreImpl _dataStore;

  /// Active read view list (ordered): Head is the oldest view
  final LinkedList<ReadView> _orderedViews = LinkedList<ReadView>();

  /// Fast lookup mapping: viewId -> ReadView
  final Map<int, ReadView> _viewMap = {};

  /// Read view timeout in seconds, expired views will be automatically cleaned up
  static const int _viewTimeoutSeconds = 60;

  /// Internal auto-increment ID counter.
  /// Dart int is 64-bit, overflow is practically impossible in this context.
  int _nextViewId = 0;

  ReadViewManager(this._dataStore) {
    CrontabManager.addCallback(ExecuteInterval.seconds10, _periodicCleanup);
  }

  /// Stop the periodic cleanup task.
  /// Should be called when the DataStore is closed.
  void dispose() {
    CrontabManager.removeCallback(ExecuteInterval.seconds10, _periodicCleanup);
  }

  /// Periodic: expire zombie views, then drain flushed-evict + idle clear.
  Future<void> _periodicCleanup() async {
    if (hasActiveViews) {
      await _cleanupExpiredHead();
    }
    _notifyBufferDrain();
  }

  int get _walCycle => _dataStore.config.logPartitionCycle;

  /// Register a read view and return the view ID.
  ///
  /// Call this method before reading data from files to ensure that new data written during this period
  /// is not immediately cleaned up but remains in the buffer for merging.
  int registerReadView() {
    final id = _nextViewId++;
    final view = ReadView(
      id: id,
      snapshotPointer: _dataStore.walManager.currentPointer,
      walCycle: _walCycle,
    );

    _orderedViews.add(view);
    _viewMap[id] = view;
    return id;
  }

  /// Release a read view.
  ///
  /// Hot path (vast majority): release a non-oldest view -> unlink and return.
  /// Tier / buffer work only when the oldest (or last) view ends.
  void releaseReadView(int viewId) {
    final view = _viewMap.remove(viewId);
    if (view == null) return;

    final bool wasOldest = identical(_orderedViews.first, view);
    view.unlink();

    if (!wasOldest) return;
    _notifyBufferDrain();
  }

  void _notifyBufferDrain() {
    try {
      _dataStore.writeBufferManager.tryDrainAndIdleClear();
    } catch (_) {}
  }

  /// Get the oldest active read view pointer (cleanup boundary).
  WalPointer? getOldestActiveSnapshot() {
    if (_orderedViews.isEmpty) return null;
    return _orderedViews.first.snapshotPointer;
  }

  /// Check if there are any active read views
  bool get hasActiveViews => _orderedViews.isNotEmpty;

  /// Get the number of active read views (for monitoring)
  int get activeViewCount => _orderedViews.length;

  /// Oldest active view creation time (O(1) head), or null if none.
  DateTime? get oldestCreatedAt =>
      _orderedViews.isEmpty ? null : _orderedViews.first.createdAt;

  /// Clean up expired read views (only head)
  ///
  /// [OPTIMIZATION]
  /// Uses [YieldController] to prevent blocking the main thread (UI jank).
  /// Executed periodically by timer, NOT by user queries.
  Future<void> _cleanupExpiredHead() async {
    if (_orderedViews.isEmpty) return;

    final yieldController =
        YieldController('ReadViewManager._cleanupExpiredHead');
    final now = DateTime.now();

    while (_orderedViews.isNotEmpty) {
      final y = yieldController.maybeYield();
      if (y != null) await y;

      final oldest = _orderedViews.first;
      final age = now.difference(oldest.createdAt).inSeconds;

      if (age < _viewTimeoutSeconds) break;

      _viewMap.remove(oldest.id);
      oldest.unlink();
    }
  }
}
