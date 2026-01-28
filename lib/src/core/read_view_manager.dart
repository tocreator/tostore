import 'dart:collection';
import 'dart:async';
import '../model/wal_pointer.dart';
import 'crontab_manager.dart'; // Import CrontabManager

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

/// ReadViewManager: tracks active read views to determine delayed cleanup boundaries
///
/// In high-concurrency scenarios, multiple queries may simultaneously read data from files.
/// After the flush task is completed, buffer data cannot be immediately deleted,
/// as these queries may still need this data for merging.
///
/// Optimization: uses [LinkedList] to maintain read views in time order,
/// implements O(1) retrieval of the oldest snapshot.
/// Assuming WAL pointers increase monotonically with time, the earliest created view has the oldest snapshot.
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
    // Auto-start periodic cleanup on instantiation
    CrontabManager.addCallback(ExecuteInterval.seconds10, _periodicCleanup);
  }

  /// Stop the periodic cleanup task.
  /// Should be called when the DataStore is closed.
  void dispose() {
    CrontabManager.removeCallback(ExecuteInterval.seconds10, _periodicCleanup);
  }

  /// Periodic cleanup callback
  Future<void> _periodicCleanup() async {
    await _cleanupExpiredHead();
    // After cleaning expired views, try to purge pending buffer cleanups
    // This is the ONLY place where purgePendingCleanups is triggered automatically,
    // avoiding per-request overhead and potential recursion.
    // The WriteBufferManager has its own guard (_isPurging) to handle concurrency.
    await _dataStore.writeBufferManager.purgePendingCleanups();
  }

  int get _walCycle => _dataStore.config.logPartitionCycle;

  /// Register a read view and return the view ID.
  ///
  /// Call this method before reading data from files to ensure that new data written during this period
  /// is not immediately cleaned up but remains in the buffer for merging.
  int registerReadView() {
    // Simple local increment is much faster than GlobalIdGenerator strings
    final id = _nextViewId++;
    final view = ReadView(
      id: id,
      snapshotPointer: _dataStore.walManager.currentPointer,
      walCycle: _walCycle,
    );

    // Append to tail, maintain time order
    _orderedViews.add(view);
    _viewMap[id] = view;

    return id;
  }

  /// Release a read view.
  ///
  /// Must be called after the query is completed to release the read view,
  /// otherwise the buffer data will not be recycled.
  void releaseReadView(int viewId) {
    final view = _viewMap.remove(viewId);
    if (view != null) {
      view.unlink();
    }
  }

  /// Get the oldest active read view pointer (cleanup boundary).
  ///
  /// Returns the oldest active read view pointer (cleanup boundary).
  /// Utilizes the LinkedList's ordered nature to directly check the head, with O(1) complexity.
  ///
  /// [OPTIMIZATION]: Reverted to Synchronous O(1).
  /// No longer triggers cleanup side-effects to prevent recursion and blocking.
  WalPointer? getOldestActiveSnapshot() {
    if (_orderedViews.isEmpty) return null;
    // Returns the oldest active read view pointer (cleanup boundary).
    return _orderedViews.first.snapshotPointer;
  }

  /// Check if there are any active read views
  bool get hasActiveViews => _orderedViews.isNotEmpty;

  /// Get the number of active read views (for monitoring)
  int get activeViewCount => _orderedViews.length;

  /// Clean up expired read views (only head)
  ///
  /// [OPTIMIZATION]
  /// Uses [YieldController] to prevent blocking the main thread (UI jank).
  /// Executed periodically by timer, NOT by user queries.
  Future<void> _cleanupExpiredHead() async {
    final now = DateTime.now();
    final yieldController =
        YieldController('ReadViewManager._cleanupExpiredHead');

    while (_orderedViews.isNotEmpty) {
      await yieldController.maybeYield();
      final head = _orderedViews.first;
      final age = now.difference(head.createdAt).inSeconds;

      if (age > _viewTimeoutSeconds) {
        head.unlink();
        _viewMap.remove(head.id);
      } else {
        break;
      }
    }
  }

  /// Clear all read views (for closing the database)
  void clearAll() {
    dispose();
    _orderedViews.clear();
    _viewMap.clear();
  }
}
