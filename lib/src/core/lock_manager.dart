import 'dart:async';
import 'dart:collection';
import '../handler/logger.dart';

/// Database lock manager
///
/// Provides shared lock (read lock) and exclusive lock (write lock) mechanisms for managing concurrent database access.
/// Shared locks allow multiple read operations simultaneously but block write operations.
/// Exclusive locks allow a single write operation while blocking all other read and write operations.
class LockManager {
  /// Resource lock mapping table, key is the resource identifier (usually table name)
  final Map<String, LockState> _lockMap = {};

  /// Lock timeout duration (milliseconds)
  final int _lockTimeout;

  /// Deadlock detection interval (milliseconds)
  final int _deadlockCheckInterval;

  /// Whether to enable deadlock detection
  final bool _enableDeadlockDetection;

  /// Deadlock detection timer
  Timer? _deadlockDetectionTimer;

  /// Create a lock manager instance
  ///
  /// [lockTimeout] specifies the timeout for acquiring a lock (milliseconds), default is 300000ms (5 minutes)
  /// [enableDeadlockDetection] whether to enable simple deadlock detection, default is true
  /// [deadlockCheckInterval] deadlock detection interval (milliseconds), default is 5000ms (5 seconds)
  LockManager({
    int lockTimeout = 300000,
    bool enableDeadlockDetection = true,
    int deadlockCheckInterval = 5000,
  })  : _lockTimeout = lockTimeout,
        _enableDeadlockDetection = enableDeadlockDetection,
        _deadlockCheckInterval = deadlockCheckInterval {
    // Start deadlock detection
    if (_enableDeadlockDetection) {
      _startDeadlockDetection();
    }
  }

  /// Start deadlock detection
  void _startDeadlockDetection() {
    _deadlockDetectionTimer?.cancel();
    _deadlockDetectionTimer = Timer.periodic(
      Duration(milliseconds: _deadlockCheckInterval),
      (_) => _checkForDeadlocks(),
    );
  }

  /// Stop deadlock detection
  void stopDeadlockDetection() {
    _deadlockDetectionTimer?.cancel();
    _deadlockDetectionTimer = null;
  }

  /// Check for deadlocks
  void _checkForDeadlocks() {
    final now = DateTime.now();

    for (final entry in _lockMap.entries) {
      final resource = entry.key;
      final state = entry.value;

      // Check for requests that have been waiting too long
      if (state.waitQueue.isNotEmpty) {
        final oldestRequest = state.waitQueue.first;
        final waitTime = now.difference(oldestRequest.timestamp).inMilliseconds;

        if (waitTime > _lockTimeout) {
          // Log potential deadlock
          Logger.warn(
            'Potential deadlock: ${oldestRequest.type} lock request (${oldestRequest.operationId}) '
            'on resource $resource has been waiting for ${waitTime}ms',
            label: 'LockManager',
          );

          // Optional: Automatically resolve deadlock, e.g., by randomly aborting a waiting transaction
          // Here we simply log without auto-resolving, as auto-resolution may lead to unpredictable behavior
        }
      }
    }
  }

  /// Get the lock state for a specified resource, create if it doesn't exist
  LockState _getLockState(String resource) {
    return _lockMap.putIfAbsent(resource, () => LockState());
  }

  /// Request a shared lock (read lock)
  ///
  /// [resource] identifier of the resource to lock (usually table name)
  /// [operationId] unique identifier for the operation, used for debug tracking
  ///
  /// Returns a Future that completes when the lock is acquired, throws exception on timeout or error
  Future<void> acquireSharedLock(String resource, [String? operationId]) async {
    final opId = operationId ?? 'op-${DateTime.now().millisecondsSinceEpoch}';
    final state = _getLockState(resource);

    // If there's no exclusive lock, shared lock can be acquired immediately
    if (!state.hasExclusive) {
      state.sharedCount++;
      state.sharedHolders.add(opId);
      state.lastModified = DateTime.now();
      return;
    }

    // There's an exclusive lock, need to wait
    Logger.debug(
        '2: $resource ($opId), currently exclusive locked by ${state.exclusiveHolder}',
        label: 'LockManager');

    final completer = Completer<void>();
    final request = LockRequest(LockType.shared, opId, completer);
    state.waitQueue.add(request);

    // Set timeout
    final timeout = Timer(Duration(milliseconds: _lockTimeout), () {
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException(
            'Shared lock acquisition timeout: $resource ($opId)',
            Duration(milliseconds: _lockTimeout)));
        state.waitQueue.remove(request);
      }
    });

    try {
      await completer.future;
      state.sharedCount++;
      state.sharedHolders.add(opId);
      state.lastModified = DateTime.now();
    } finally {
      timeout.cancel();
    }
  }

  /// Request an exclusive lock (write lock)
  ///
  /// [resource] identifier of the resource to lock (usually table name)
  /// [operationId] unique identifier for the operation, used for debug tracking
  ///
  /// Returns a Future that completes when the lock is acquired, throws exception on timeout or error
  Future<void> acquireExclusiveLock(String resource,
      [String? operationId]) async {
    final opId = operationId ?? 'op-${DateTime.now().millisecondsSinceEpoch}';
    final state = _getLockState(resource);

    // If there are no locks, exclusive lock can be acquired immediately
    if (state.sharedCount == 0 && !state.hasExclusive) {
      state.hasExclusive = true;
      state.exclusiveHolder = opId;
      state.lastModified = DateTime.now();
      return;
    }

    final completer = Completer<void>();
    final request = LockRequest(LockType.exclusive, opId, completer);
    state.waitQueue.add(request);

    // Set timeout
    final timeout = Timer(Duration(milliseconds: _lockTimeout), () {
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException(
            'Exclusive lock acquisition timeout: $resource ($opId)',
            Duration(milliseconds: _lockTimeout)));
        state.waitQueue.remove(request);
      }
    });

    try {
      await completer.future;
      state.hasExclusive = true;
      state.exclusiveHolder = opId;
      state.lastModified = DateTime.now();
    } finally {
      timeout.cancel();
    }
  }

  /// Try to acquire a shared lock (non-blocking)
  ///
  /// [resource] identifier of the resource to lock
  /// [operationId] unique identifier for the operation
  ///
  /// Returns whether the lock was successfully acquired
  bool tryAcquireSharedLock(String resource, [String? operationId]) {
    final opId = operationId ?? 'op-${DateTime.now().millisecondsSinceEpoch}';
    final state = _getLockState(resource);

    if (!state.hasExclusive) {
      state.sharedCount++;
      state.sharedHolders.add(opId);
      state.lastModified = DateTime.now();
      return true;
    }

    Logger.debug('Failed to acquire shared lock: $resource ($opId)',
        label: 'LockManager');
    return false;
  }

  /// Try to acquire an exclusive lock (non-blocking)
  ///
  /// [resource] identifier of the resource to lock
  /// [operationId] unique identifier for the operation
  ///
  /// Returns whether the lock was successfully acquired
  bool tryAcquireExclusiveLock(String resource, [String? operationId]) {
    final opId = operationId ?? 'op-${DateTime.now().millisecondsSinceEpoch}';
    final state = _getLockState(resource);

    if (state.sharedCount == 0 && !state.hasExclusive) {
      state.hasExclusive = true;
      state.exclusiveHolder = opId;
      state.lastModified = DateTime.now();
      return true;
    }

    Logger.debug('Failed to acquire exclusive lock: $resource ($opId)',
        label: 'LockManager');
    return false;
  }

  /// Upgrade a shared lock to an exclusive lock
  ///
  /// [resource] identifier of the resource to upgrade lock for
  /// [operationId] unique identifier for the operation
  ///
  /// Note: This operation must be used carefully as it may cause deadlocks.
  /// Returns true on success, false on failure.
  Future<bool> upgradeSharedToExclusive(
      String resource, String operationId) async {
    final state = _lockMap[resource];
    if (state == null || !state.sharedHolders.contains(operationId)) {
      Logger.warn(
          'Attempted to upgrade a shared lock not held by this operation: $resource, $operationId',
          label: 'LockManager');
      return false;
    }

    // If there's only one shared lock and the holder is the current operation, can upgrade directly
    if (state.sharedCount == 1 &&
        state.sharedHolders.length == 1 &&
        state.sharedHolders.contains(operationId) &&
        !state.hasExclusive) {
      // Release shared lock
      state.sharedCount = 0;
      state.sharedHolders.clear();

      // Acquire exclusive lock
      state.hasExclusive = true;
      state.exclusiveHolder = operationId;
      state.lastModified = DateTime.now();

      return true;
    }

    // Otherwise need to release shared lock and then request exclusive lock
    Logger.debug('Lock upgrade requires waiting: $resource ($operationId)',
        label: 'LockManager');

    // Release shared lock
    releaseSharedLock(resource, operationId);

    // Try to acquire exclusive lock
    try {
      await acquireExclusiveLock(resource, operationId);
      return true;
    } catch (e) {
      Logger.error('Lock upgrade failed: $resource ($operationId), error: $e',
          label: 'LockManager');
      return false;
    }
  }

  /// Release a shared lock
  ///
  /// [resource] identifier of the resource to release lock for
  /// [operationId] unique identifier for the operation, ensures only own locks are released
  void releaseSharedLock(String resource, [String? operationId]) {
    final opId = operationId ?? '';
    final state = _lockMap[resource];
    if (state == null) return;

    if (operationId != null) {
      if (state.sharedHolders.remove(opId)) {
        state.sharedCount = state.sharedCount > 0 ? state.sharedCount - 1 : 0;
      }
    } else {
      // Without operationId, simply decrease the count
      if (state.sharedCount > 0) {
        state.sharedCount--;
      }
    }

    state.lastModified = DateTime.now();

    _processWaitQueue(resource);

    // If there are no locks, remove the state object to save memory
    if (state.sharedCount == 0 &&
        !state.hasExclusive &&
        state.waitQueue.isEmpty) {
      _lockMap.remove(resource);
    }
  }

  /// Release an exclusive lock
  ///
  /// [resource] identifier of the resource to release lock for
  /// [operationId] unique identifier for the operation, ensures only own locks are released
  void releaseExclusiveLock(String resource, [String? operationId]) {
    final opId = operationId ?? '';
    final state = _lockMap[resource];
    if (state == null) return;

    try {
      // Verify lock holder (if operationId is provided)
      if (operationId != null &&
          state.exclusiveHolder != null &&
          state.exclusiveHolder != opId) {
        return;
      }

      if (state.hasExclusive) {
        state.hasExclusive = false;
        state.exclusiveHolder = null;
        state.lastModified = DateTime.now();
      }

      _processWaitQueue(resource);

      // If there are no locks, remove the state object to save memory
      if (state.sharedCount == 0 &&
          !state.hasExclusive &&
          state.waitQueue.isEmpty) {
        _lockMap.remove(resource);
      }
    } catch (e) {
      Logger.error('Error while releasing exclusive lock: $resource, error: $e',
          label: 'LockManager');
      // Ensure state is cleaned up even if error occurs
      state.hasExclusive = false;
      state.exclusiveHolder = null;
      state.lastModified = DateTime.now();
      _processWaitQueue(resource);
      if (state.sharedCount == 0 &&
          !state.hasExclusive &&
          state.waitQueue.isEmpty) {
        _lockMap.remove(resource);
      }
    }
  }

  /// Process waiting lock requests in the queue
  void _processWaitQueue(String resource) {
    final state = _lockMap[resource];
    if (state == null || state.waitQueue.isEmpty) return;

    // If there's still an exclusive lock, can't process the wait queue
    if (state.hasExclusive) return;

    // Prioritize exclusive lock requests
    LockRequest? exclusiveRequest;
    for (var request in state.waitQueue) {
      if (request.type == LockType.exclusive) {
        exclusiveRequest = request;
        break;
      }
    }

    if (exclusiveRequest != null && state.sharedCount == 0) {
      state.waitQueue.remove(exclusiveRequest);
      if (!exclusiveRequest.completer.isCompleted) {
        exclusiveRequest.completer.complete();
      }
      return;
    }

    // Process shared lock requests
    while (state.waitQueue.isNotEmpty) {
      final nextRequest = state.waitQueue.first;
      if (nextRequest.type == LockType.shared) {
        state.waitQueue.removeFirst();
        if (!nextRequest.completer.isCompleted) {
          nextRequest.completer.complete();
        }
      } else {
        break;
      }
    }
  }

  /// Check if a resource has a shared lock
  bool hasSharedLock(String resource) {
    final state = _lockMap[resource];
    return state != null && state.sharedCount > 0;
  }

  /// Check if a resource has an exclusive lock
  bool hasExclusiveLock(String resource) {
    final state = _lockMap[resource];
    return state != null && state.hasExclusive;
  }

  /// Check if the specified operation holds a shared lock
  bool isSharedLockHolder(String resource, String operationId) {
    final state = _lockMap[resource];
    return state != null && state.sharedHolders.contains(operationId);
  }

  /// Check if the specified operation holds an exclusive lock
  bool isExclusiveLockHolder(String resource, String operationId) {
    final state = _lockMap[resource];
    return state != null &&
        state.hasExclusive &&
        state.exclusiveHolder == operationId;
  }

  /// Get the length of the wait queue
  int getWaitQueueLength(String resource) {
    final state = _lockMap[resource];
    return state?.waitQueue.length ?? 0;
  }

  /// Get lock status statistics
  Map<String, dynamic> getStats() {
    final result = <String, dynamic>{};
    for (final entry in _lockMap.entries) {
      result[entry.key] = {
        'sharedCount': entry.value.sharedCount,
        'hasExclusive': entry.value.hasExclusive,
        'waitQueueLength': entry.value.waitQueue.length,
        'sharedHolders': entry.value.sharedHolders.toList(),
        'exclusiveHolder': entry.value.exclusiveHolder,
        'lastModified': entry.value.lastModified.toIso8601String(),
      };
    }
    return result;
  }

  /// Clear all locks (only for testing or system reset)
  void clearAllLocks() {
    for (final state in _lockMap.values) {
      for (final request in state.waitQueue) {
        if (!request.completer.isCompleted) {
          request.completer.completeError('Lock manager has been reset');
        }
      }
    }
    _lockMap.clear();
  }

  /// Get a list of all operation IDs waiting for locks
  List<String> getWaitingOperations(String resource) {
    final state = _lockMap[resource];
    if (state == null) return [];

    return state.waitQueue.map((request) => request.operationId).toList();
  }

  /// Force release all locks for a specific resource
  ///
  /// Warning: This operation may lead to data inconsistency, only for emergency situations
  bool forceReleaseAllLocks(String resource) {
    final state = _lockMap[resource];
    if (state == null) return false;

    final hadLocks = state.sharedCount > 0 || state.hasExclusive;

    // Release all locks
    state.sharedCount = 0;
    state.sharedHolders.clear();
    state.hasExclusive = false;
    state.exclusiveHolder = null;

    // Process the wait queue
    _processWaitQueue(resource);

    Logger.warn('Force released all locks: $resource', label: 'LockManager');
    return hadLocks;
  }

  /// Dispose the lock manager
  void dispose() {
    stopDeadlockDetection();
    clearAllLocks();
  }
}

/// Lock type enumeration
enum LockType {
  /// Shared lock (read lock) - allows multiple read operations simultaneously
  shared,

  /// Exclusive lock (write lock) - exclusive resource access, blocks other read/write operations
  exclusive
}

/// Lock request information class
class LockRequest {
  /// Lock type
  final LockType type;

  /// Operation ID
  final String operationId;

  /// Completer, for asynchronous lock waiting
  final Completer<void> completer;

  /// Request timestamp
  final DateTime timestamp;

  /// Constructor
  LockRequest(this.type, this.operationId, this.completer)
      : timestamp = DateTime.now();
}

/// Lock state class, used to track resource lock status
class LockState {
  /// Current number of shared locks
  int sharedCount = 0;

  /// Whether there is an exclusive lock
  bool hasExclusive = false;

  /// Queue of lock requests waiting to be processed
  final Queue<LockRequest> waitQueue = Queue<LockRequest>();

  /// List of operation IDs holding shared locks, for debugging
  final Set<String> sharedHolders = {};

  /// Operation ID holding the exclusive lock, for debugging
  String? exclusiveHolder;

  /// Timestamp of last lock operation
  DateTime lastModified = DateTime.now();
}
