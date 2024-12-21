import 'dart:async';
import 'dart:collection';

/// lock request
class _LockRequest {
  final String id;
  final Completer<void> completer;
  final DateTime timestamp;
  final int priority;

  _LockRequest({
    required this.id,
    required this.completer,
    required this.timestamp,
    required this.priority,
  });
}

/// concurrency control manager
class ConcurrencyManager {
  final _readLocks = <String, int>{};
  final _writeLocks = <String, bool>{};
  final _lockQueues = <String, Queue<_LockRequest>>{};
  final _lockHolders = <String, String>{};

  final _lockCache = <String, bool>{};

  static const _lockTimeout = Duration(seconds: 2);

  static const _maxWaitingTime = Duration(milliseconds: 500);

  /// acquire write lock
  Future<void> acquireWriteLock(String resource) async {
    if (_lockCache[resource] == true) {
      return;
    }

    final requestId = DateTime.now().microsecondsSinceEpoch.toString();
    final completer = Completer<void>();

    if (_tryAcquireWriteLock(resource, requestId)) {
      _lockCache[resource] = true;
      completer.complete();
      return completer.future;
    }

    final request = _LockRequest(
      id: requestId,
      completer: completer,
      timestamp: DateTime.now(),
      priority: _calculatePriority(resource),
    );

    _addToWaitingQueue(resource, request);

    _setupTimeout(resource, request);

    try {
      await completer.future;
      _lockCache[resource] = true;
    } catch (e) {
      _cleanupFailedRequest(resource, request);
      rethrow;
    }
  }

  /// release write lock
  Future<void> releaseWriteLock(String resource) async {
    if (_lockCache[resource] == false) {
      return;
    }

    _writeLocks.remove(resource);
    _lockHolders.remove(resource);
    _lockCache[resource] = false;

    _processWaitingQueue(resource);
  }

  /// try acquire write lock
  bool _tryAcquireWriteLock(String resource, String requestId) {
    if (!_writeLocks.containsKey(resource) &&
        (!_readLocks.containsKey(resource) || _readLocks[resource] == 0)) {
      _writeLocks[resource] = true;
      _lockHolders[resource] = requestId;
      return true;
    }
    return false;
  }

  void _addToWaitingQueue(String resource, _LockRequest request) {
    final queue =
        _lockQueues.putIfAbsent(resource, () => Queue<_LockRequest>());

    queue.add(request);

    if (queue.length > 1) {
      final sorted = queue.toList()
        ..sort((a, b) => b.priority.compareTo(a.priority));

      queue.clear();
      queue.addAll(sorted);
    }
  }

  /// process waiting queue
  void _processWaitingQueue(String resource) {
    final queue = _lockQueues[resource];
    if (queue == null || queue.isEmpty) return;

    queue.removeWhere((request) {
      if (DateTime.now().difference(request.timestamp) > _maxWaitingTime) {
        request.completer
            .completeError(TimeoutException('Lock request expired'));
        return true;
      }
      return false;
    });

    while (queue.isNotEmpty) {
      final request = queue.first;
      if (_tryAcquireWriteLock(resource, request.id)) {
        queue.removeFirst();
        request.completer.complete();
        break;
      } else {
        break;
      }
    }
  }

  /// setup timeout handler
  void _setupTimeout(String resource, _LockRequest request) {
    Future.delayed(_lockTimeout, () {
      if (!request.completer.isCompleted) {
        _cleanupFailedRequest(resource, request);
        request.completer
            .completeError(TimeoutException('Lock acquisition timeout'));
      }
    });
  }

  /// cleanup failed request
  void _cleanupFailedRequest(String resource, _LockRequest request) {
    _lockQueues[resource]?.remove(request);
    _lockHolders.remove(resource);
    _lockCache[resource] = false;
  }

  /// calculate request priority
  int _calculatePriority(String resource) {
    return 0;
  }
}
