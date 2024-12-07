import 'dart:async';
import 'dart:collection';

/// 锁请求
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

/// 并发控制管理器
class ConcurrencyManager {
  final _readLocks = <String, int>{};
  final _writeLocks = <String, bool>{};
  final _lockQueues = <String, Queue<_LockRequest>>{};
  final _lockHolders = <String, String>{};

  final _lockCache = <String, bool>{};

  static const _lockTimeout = Duration(seconds: 2);

  static const _maxWaitingTime = Duration(milliseconds: 500);

  /// 获取写锁
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

  /// 释放写锁
  Future<void> releaseWriteLock(String resource) async {
    if (_lockCache[resource] == false) {
      return;
    }

    _writeLocks.remove(resource);
    _lockHolders.remove(resource);
    _lockCache[resource] = false;

    _processWaitingQueue(resource);
  }

  /// 尝试获取写锁
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

  /// 处理等待队列
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

  /// 设置超时处理
  void _setupTimeout(String resource, _LockRequest request) {
    Future.delayed(_lockTimeout, () {
      if (!request.completer.isCompleted) {
        _cleanupFailedRequest(resource, request);
        request.completer
            .completeError(TimeoutException('Lock acquisition timeout'));
      }
    });
  }

  /// 清理失败的请求
  void _cleanupFailedRequest(String resource, _LockRequest request) {
    _lockQueues[resource]?.remove(request);
    _lockHolders.remove(resource);
    _lockCache[resource] = false;
  }

  /// 计算请求优先级
  int _calculatePriority(String resource) {
    return 0;
  }
}
