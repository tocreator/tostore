import 'dart:async';
import 'dart:collection';
import '../handler/logger.dart';
import 'crontab_manager.dart';
import 'transaction_context.dart';
import 'dart:math';

/// Database lock manager optimized for large-scale scenarios
///
/// Provides shared lock (read lock) and exclusive lock (write lock) mechanisms for managing concurrent database access.
/// Shared locks allow multiple read operations simultaneously but block write operations.
/// Exclusive locks allow a single write operation while blocking all other read and write operations.
class LockManager {
  /// Dynamic lock timeout based on operation type and system load
  final int baseLockTimeout;

  /// Whether to enable deadlock detection
  final bool enableDeadlockDetection;

  /// Dynamic resource limits based on system capacity
  int _maxActiveResources;
  int _maxLocksPerResource;
  int _maxQueuedRequestsPerResource;

  /// Lock request queue - maintains fair ordering
  final Queue<_LockRequest> _requestQueue = Queue<_LockRequest>();

  /// Active locks by resource - using more efficient data structure
  final Map<String, _LockResource> _activeLocks = {};

  /// Operation ID to lock request mapping for quick lookup
  final Map<String, _LockRequest> _operationToRequest = {};

  /// Resource-specific request queues for better performance
  final Map<String, Queue<_LockRequest>> _resourceQueues = {};

  /// Hierarchical lock tracking for better granularity
  final Map<String, Set<String>> _resourceHierarchy = {};

  /// Deadlock detection cycle counter
  int _deadlockDetectionCycle = 0;

  /// Last cleanup time for performance optimization
  DateTime _lastCleanupTime = DateTime.now();

  /// Dynamic cleanup interval based on system load
  Duration _cleanupInterval = const Duration(minutes: 5);

  /// Dynamic batch size for cleanup operations
  int _cleanupBatchSize = 100;

  /// System load tracking
  int _currentLoad = 0;
  int _peakLoad = 0;
  DateTime _lastLoadUpdate = DateTime.now();

  /// Statistics tracking
  int _totalRequests = 0;
  int _totalTimeouts = 0;
  int _totalDeadlocks = 0;
  int _totalRejected = 0;
  DateTime _lastStatsTime = DateTime.now();

  /// Maintenance mode barrier: when enabled, new lock requests will wait until maintenance ends
  bool _maintenanceMode = false;
  Completer<void>? _maintenanceCompleter;

  /// Shutdown mode: reject all new lock requests immediately
  bool _shutdownMode = false;

  LockManager({
    this.baseLockTimeout = 300000, // 5 minutes default
    this.enableDeadlockDetection = true,
    int? maxActiveResources,
    int? maxLocksPerResource,
    int? maxQueuedRequestsPerResource,
  })  : _maxActiveResources =
            maxActiveResources ?? 1000000, // 1M resources default
        _maxLocksPerResource =
            maxLocksPerResource ?? 50000, // 50K locks per resource
        _maxQueuedRequestsPerResource = maxQueuedRequestsPerResource ?? 25000 {
    // 25K queued requests

    // Register unified management task - combines all periodic operations safely
    CrontabManager.addCallback(
        ExecuteInterval.minutes5, _unifiedManagementTask);
  }

  /// Enter maintenance mode: block new lock acquisitions and wait for quiescent state
  Future<bool> enterMaintenance(
      {Duration timeout = const Duration(minutes: 5)}) async {
    if (_maintenanceMode) return true;
    _maintenanceMode = true;
    _maintenanceCompleter = Completer<void>();
    final bool ok = await _waitForQuiescent(timeout: timeout);
    return ok;
  }

  /// Exit maintenance mode and unblock waiting requests
  void exitMaintenance() {
    if (!_maintenanceMode) return;
    _maintenanceMode = false;
    try {
      _maintenanceCompleter?.complete();
    } catch (_) {}
    _maintenanceCompleter = null;
  }

  /// Whether maintenance mode is active
  bool get isInMaintenance => _maintenanceMode;
  bool get isShutdown => _shutdownMode;

  /// Wait until there are no active locks and no queued requests (quiescent)
  Future<bool> _waitForQuiescent({required Duration timeout}) async {
    final int end =
        DateTime.now().millisecondsSinceEpoch + timeout.inMilliseconds;
    while (true) {
      final int now = DateTime.now().millisecondsSinceEpoch;
      if (_activeLocks.isEmpty &&
          _operationToRequest.isEmpty &&
          _resourceQueues.isEmpty) {
        return true;
      }
      if (now >= end) return false;
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }

  /// Enter shutdown mode: reject all new lock requests
  void enterShutdown() {
    _shutdownMode = true;
  }

  /// Exit shutdown mode: allow new lock requests
  void exitShutdown() {
    _shutdownMode = false;
  }

  /// Unified management task that combines all periodic operations safely
  /// This reduces the number of polling tasks from 3 to 1, improving performance
  /// Uses a state machine approach to avoid recursive calls
  void _unifiedManagementTask() {
    try {
      final now = DateTime.now();

      // Skip execution if system is idle (no active locks or requests)
      if (_activeLocks.isEmpty &&
          _operationToRequest.isEmpty &&
          _resourceQueues.isEmpty) {
        return;
      }

      // 1. Dynamic limits adjustment (every 10 minutes)
      if (_deadlockDetectionCycle % 2 == 0) {
        // Every 10 minutes (2 * 5 minutes)
        _adjustDynamicLimits();
      }

      // 2. Periodic cleanup with dynamic interval - SAFE VERSION
      if (now.difference(_lastCleanupTime) >= _cleanupInterval) {
        _performSafeCleanup();
        _lastCleanupTime = now;
      }

      // 3. Statistics logging (every hour) - only if there's activity
      if (_deadlockDetectionCycle % 12 == 0 && _totalRequests > 0) {
        // Every hour (12 * 5 minutes)
        _logStatistics();
      }

      // 4. Enhanced deadlock detection (every 15 minutes) - more frequent for better responsiveness
      if (enableDeadlockDetection &&
          _deadlockDetectionCycle % 3 == 0 &&
          _activeLocks.isNotEmpty) {
        _detectDeadlocks();
      }

      // 5. Proactive timeout handling (every 5 minutes) - check for long-waiting requests
      _checkForLongWaitingRequests();

      _deadlockDetectionCycle++;
    } catch (e) {
      Logger.error('Error in unified management task: $e',
          label: 'LockManager._unifiedManagementTask');
    }
  }

  /// Check for requests that have been waiting too long and proactively timeout them
  void _checkForLongWaitingRequests() {
    try {
      final now = DateTime.now();
      final longWaitThreshold =
          Duration(milliseconds: _dynamicLockTimeout * 2); // 2x normal timeout
      final requestsToTimeout = <_LockRequest>[];

      for (final resourceQueue in _resourceQueues.values) {
        for (final request in resourceQueue) {
          if (now.difference(request.requestTime) > longWaitThreshold) {
            requestsToTimeout.add(request);
          }
        }
      }

      // Proactively timeout long-waiting requests to prevent indefinite waiting
      for (final request in requestsToTimeout) {
        Logger.warn(
            'Proactively timing out long-waiting request: ${request.operationId} (waited ${now.difference(request.requestTime).inMilliseconds}ms)',
            label: 'LockManager._checkForLongWaitingRequests');
        _handleTimeoutSafely(request);
      }

      if (requestsToTimeout.isNotEmpty) {
        Logger.info(
            'Proactively timed out ${requestsToTimeout.length} long-waiting requests',
            label: 'LockManager._checkForLongWaitingRequests');
      }
    } catch (e) {
      Logger.error('Error checking for long waiting requests: $e',
          label: 'LockManager._checkForLongWaitingRequests');
    }
  }

  /// Perform cleanup operations safely without recursive calls
  void _performSafeCleanup() {
    try {
      final now = DateTime.now();
      int totalCleaned = 0;

      // Clean up timed out requests from all resource queues
      final timeoutThreshold =
          now.subtract(Duration(milliseconds: _dynamicLockTimeout));
      final requestsToRemove = <_LockRequest>[];

      int processedCount = 0;
      for (final resourceQueue in _resourceQueues.values) {
        for (final request in resourceQueue) {
          if (request.requestTime.isBefore(timeoutThreshold)) {
            requestsToRemove.add(request);
          }

          processedCount++;
          if (processedCount >= _cleanupBatchSize) {
            break; // Process in batches to avoid blocking
          }
        }
        if (processedCount >= _cleanupBatchSize) {
          break;
        }
      }

      // SAFE: Handle timeouts without recursive calls
      for (final request in requestsToRemove) {
        _handleTimeoutSafely(request);
        totalCleaned++;
      }

      // Clean up orphaned operation mappings - more efficient approach
      final orphanedOperations = <String>[];
      final activeRequests = <_LockRequest>{};

      // Build set of active requests for O(1) lookup
      for (final resourceQueue in _resourceQueues.values) {
        activeRequests.addAll(resourceQueue);
      }

      for (final entry in _operationToRequest.entries) {
        // IMPORTANT:
        // A granted lock request is removed from _resourceQueues but must remain
        // in _operationToRequest until explicit release. We can distinguish it by
        // `completer.isCompleted == true` (lock granted).
        //
        // Removing such mappings would make releases impossible and can lead to
        // permanent deadlocks (_activeLocks still holds the lock).
        if (!entry.value.completer.isCompleted &&
            !activeRequests.contains(entry.value)) {
          orphanedOperations.add(entry.key);
        }
      }

      for (final operationId in orphanedOperations) {
        _operationToRequest.remove(operationId);
        totalCleaned++;
      }

      // Clean up empty resource queues
      final emptyQueues = <String>[];
      for (final entry in _resourceQueues.entries) {
        if (entry.value.isEmpty) {
          emptyQueues.add(entry.key);
        }
      }
      for (final resource in emptyQueues) {
        _resourceQueues.remove(resource);
        totalCleaned++;
      }

      // Log cleanup results if significant
      if (totalCleaned > 0) {
        Logger.debug(
            'Safe cleanup completed: removed $totalCleaned items (${requestsToRemove.length} timeouts, ${orphanedOperations.length} orphans, ${emptyQueues.length} empty queues)',
            label: 'LockManager._performSafeCleanup');
      }
    } catch (e) {
      Logger.error('Error during safe cleanup: $e',
          label: 'LockManager._performSafeCleanup');
    }
  }

  /// Handle lock timeout safely without recursive calls
  void _handleTimeoutSafely(_LockRequest request) {
    _totalTimeouts++;
    _removeRequestSafely(request);

    Logger.warn(
        'Lock timeout for operation ${request.operationId} on resource ${request.resource}',
        label: 'LockManager._handleTimeoutSafely');
  }

  /// Remove a request safely without triggering additional cleanup
  void _removeRequestSafely(_LockRequest request) {
    _operationToRequest.remove(request.operationId);

    // Remove from resource queue
    final resourceQueue = _resourceQueues[request.resource];
    if (resourceQueue != null) {
      resourceQueue.remove(request);
      if (resourceQueue.isEmpty) {
        _resourceQueues.remove(request.resource);
      }
    }

    // Only complete if not already completed to avoid "Future already completed" error
    if (!request.completer.isCompleted) {
      try {
        request.completer.complete(false);
      } catch (e) {
        // Ignore "Future already completed" errors
        Logger.debug('Request already completed: ${request.operationId}',
            label: 'LockManager._removeRequestSafely');
      }
    }
  }

  /// Get dynamic lock timeout based on current system load
  int get _dynamicLockTimeout {
    final loadFactor =
        _currentLoad / (_maxActiveResources * 0.8); // 80% capacity threshold
    if (loadFactor > 0.9) {
      return (baseLockTimeout * 0.5).toInt(); // Reduce timeout under high load
    } else if (loadFactor > 0.7) {
      return (baseLockTimeout * 0.8).toInt();
    }
    return baseLockTimeout;
  }

  /// Acquire a shared lock (read lock)
  /// Multiple shared locks can be held simultaneously
  Future<bool> acquireSharedLock(String resource, String operationId) async {
    // Reject during shutdown (except system ops)
    if (_shutdownMode && !TransactionContext.isSystemOperation()) {
      Logger.warn(
          'Shutdown mode active: reject shared lock $operationId on $resource',
          label: 'LockManager');
      return false;
    }
    // Intercept during maintenance: user ops wait until maintenance ends;
    // system ops (e.g. migration) bypass and can acquire locks.
    if (_maintenanceMode && !TransactionContext.isSystemOperation()) {
      final c = _maintenanceCompleter;
      if (c != null) {
        try {
          await c.future;
        } catch (_) {}
      }
    }
    return _acquireLock(resource, operationId, LockType.shared);
  }

  /// Acquire an exclusive lock (write lock)
  /// Only one exclusive lock can be held at a time
  Future<bool> acquireExclusiveLock(String resource, String operationId) async {
    if (_shutdownMode && !TransactionContext.isSystemOperation()) {
      Logger.warn(
          'Shutdown mode active: reject exclusive lock $operationId on $resource',
          label: 'LockManager');
      return false;
    }
    // Intercept during maintenance: user ops wait; system ops (e.g. migration) bypass.
    if (_maintenanceMode && !TransactionContext.isSystemOperation()) {
      final c = _maintenanceCompleter;
      if (c != null) {
        try {
          await c.future;
        } catch (_) {}
      }
    }
    return _acquireLock(resource, operationId, LockType.exclusive);
  }

  /// Try to acquire a shared lock without waiting
  bool tryAcquireSharedLock(String resource, String operationId) {
    if (_shutdownMode || _maintenanceMode) return false;
    return _tryAcquireLock(resource, operationId, LockType.shared);
  }

  /// Try to acquire an exclusive lock without waiting
  bool tryAcquireExclusiveLock(String resource, String operationId) {
    if (_shutdownMode || _maintenanceMode) return false;
    return _tryAcquireLock(resource, operationId, LockType.exclusive);
  }

  /// Release a shared lock
  void releaseSharedLock(String resource, String operationId) {
    _releaseLock(resource, operationId, LockType.shared);
  }

  /// Release an exclusive lock
  void releaseExclusiveLock(String resource, String operationId) {
    _releaseLock(resource, operationId, LockType.exclusive);
  }

  /// Core lock acquisition logic with improved performance
  Future<bool> _acquireLock(
      String resource, String operationId, LockType lockType) async {
    _totalRequests++;
    _updateLoadMetrics();

    // Check if operation already has a lock
    if (_operationToRequest.containsKey(operationId)) {
      Logger.warn('Operation $operationId already has a lock',
          label: 'LockManager');
      return false;
    }

    // Validate operation ID format to prevent duplicates
    if (operationId.isEmpty || operationId.length > 100) {
      Logger.warn('Invalid operation ID: $operationId', label: 'LockManager');
      return false;
    }

    // Check resource limits with dynamic adjustment
    if (!_checkResourceLimits(resource)) {
      _totalRejected++;
      Logger.warn(
          'Resource limit exceeded for $resource (current load: $_currentLoad)',
          label: 'LockManager');
      return false;
    }

    // Create lock request with optimized memory usage
    final request = _LockRequest(
      resource: resource,
      operationId: operationId,
      lockType: lockType,
      requestTime: DateTime.now(),
      completer: Completer<bool>(),
    );

    // Add to operation mapping
    _operationToRequest[operationId] = request;

    // Add to resource-specific queue
    _getResourceQueue(resource).add(request);

    try {
      // Try to process the request immediately
      if (_tryProcessRequest(request)) {
        return true;
      }

      // If immediate processing failed, wait for timeout or completion
      final result = await request.completer.future.timeout(
        Duration(milliseconds: _dynamicLockTimeout),
        onTimeout: () {
          _handleTimeout(request);
          return false;
        },
      );

      return result;
    } catch (e) {
      _removeRequest(request);
      Logger.error('Lock acquisition failed: $e', label: 'LockManager');
      return false;
    }
  }

  /// Update load metrics for dynamic adjustments
  void _updateLoadMetrics() {
    final now = DateTime.now();
    if (now.difference(_lastLoadUpdate).inSeconds >= 60) {
      _currentLoad = _activeLocks.length + _operationToRequest.length;
      _peakLoad = _currentLoad > _peakLoad ? _currentLoad : _peakLoad;
      _lastLoadUpdate = now;
    }
  }

  /// Check resource limits with dynamic adjustment
  bool _checkResourceLimits(String resource) {
    // Check total active resources limit with dynamic adjustment
    final effectiveMaxResources = _maxActiveResources;
    if (_activeLocks.length >= effectiveMaxResources &&
        !_activeLocks.containsKey(resource)) {
      return false;
    }

    // Check per-resource limits with dynamic adjustment
    final resourceQueue = _resourceQueues[resource];
    if (resourceQueue != null &&
        resourceQueue.length >= _maxQueuedRequestsPerResource) {
      return false;
    }

    final lockResource = _activeLocks[resource];
    if (lockResource != null &&
        lockResource.lockCount >= _maxLocksPerResource) {
      return false;
    }

    return true;
  }

  /// Get or create resource-specific queue
  Queue<_LockRequest> _getResourceQueue(String resource) {
    return _resourceQueues.putIfAbsent(resource, () => Queue<_LockRequest>());
  }

  /// Try to acquire lock without waiting
  bool _tryAcquireLock(String resource, String operationId, LockType lockType) {
    // Check if operation already has a lock
    if (_operationToRequest.containsKey(operationId)) {
      return false;
    }

    // Check resource limits
    if (!_checkResourceLimits(resource)) {
      return false;
    }

    // Create temporary request for validation
    final request = _LockRequest(
      resource: resource,
      operationId: operationId,
      lockType: lockType,
      requestTime: DateTime.now(),
      completer: Completer<bool>(),
    );

    // Try to process immediately
    final success = _tryProcessRequest(request);

    if (success) {
      _operationToRequest[operationId] = request;
      // Don't complete here as _tryProcessRequest already completes it
    } else {
      // For tryAcquire operations, we need to clean up without completing the completer
      // since these are synchronous operations
      _cleanupTryAcquireRequest(request);
    }

    return success;
  }

  /// Try to process a lock request
  bool _tryProcessRequest(_LockRequest request) {
    final resource =
        _activeLocks.putIfAbsent(request.resource, () => _LockResource());

    // Check if lock can be granted
    if (_canGrantLock(resource, request)) {
      // Grant the lock
      resource.addLock(request);

      // Only complete if not already completed to avoid "Future already completed" error
      if (!request.completer.isCompleted) {
        try {
          request.completer.complete(true);
        } catch (e) {
          // Ignore "Future already completed" errors
          Logger.debug('Request already completed: ${request.operationId}',
              label: 'LockManager._tryProcessRequest');
        }
      }

      // Process next requests for this resource
      _processResourceQueue(request.resource);
      return true;
    }

    return false;
  }

  /// Check if a lock can be granted
  bool _canGrantLock(_LockResource resource, _LockRequest request) {
    // Check resource limits
    if (resource.lockCount >= _maxLocksPerResource) {
      return false;
    }

    // If no active locks, can always grant
    if (resource.sharedLocks.isEmpty && resource.exclusiveLock == null) {
      return true;
    }

    switch (request.lockType) {
      case LockType.shared:
        // Shared lock can be granted if there's no exclusive lock
        return resource.exclusiveLock == null;

      case LockType.exclusive:
        // Exclusive lock can only be granted if there are no active locks
        return resource.sharedLocks.isEmpty && resource.exclusiveLock == null;
    }
  }

  /// Process requests for a specific resource
  void _processResourceQueue(String resourceName) {
    final resourceQueue = _resourceQueues[resourceName];
    if (resourceQueue == null || resourceQueue.isEmpty) {
      return;
    }

    final resource = _activeLocks[resourceName];
    if (resource == null) {
      return;
    }

    final processedRequests = <_LockRequest>[];

    // Process requests in order (fair queuing)
    for (final request in resourceQueue.toList()) {
      // Skip already processed requests
      if (request.completer.isCompleted) {
        processedRequests.add(request);
        continue;
      }

      // Check resource limits
      if (resource.lockCount >= _maxLocksPerResource) {
        break; // Stop processing if limit reached
      }

      if (_canGrantLock(resource, request)) {
        // Grant the lock
        resource.addLock(request);

        // Only complete if not already completed to avoid "Future already completed" error
        if (!request.completer.isCompleted) {
          try {
            request.completer.complete(true);
          } catch (e) {
            // Ignore "Future already completed" errors
            Logger.debug('Request already completed: ${request.operationId}',
                label: 'LockManager._processResourceQueue');
          }
        }

        processedRequests.add(request);
      } else {
        // Cannot grant lock, stop processing (maintains fair ordering)
        break;
      }
    }

    // Remove processed requests from queue
    for (final request in processedRequests) {
      resourceQueue.remove(request);
    }

    // Clean up empty resource queue
    if (resourceQueue.isEmpty) {
      _resourceQueues.remove(resourceName);
    }
  }

  /// Release a lock
  void _releaseLock(String resource, String operationId, LockType lockType) {
    final request = _operationToRequest.remove(operationId);
    if (request == null) {
      Logger.warn('Attempted to release non-existent lock: $operationId',
          label: 'LockManager');
      // Best-effort self-heal: if the operation mapping was lost (e.g. due to a bug
      // or stale cleanup), attempt to remove the held lock from the resource to
      // prevent permanent deadlocks.
      final lockResource = _activeLocks[resource];
      if (lockResource != null) {
        bool removed = false;
        if (lockResource.exclusiveLock?.operationId == operationId) {
          lockResource.exclusiveLock = null;
          removed = true;
        }
        if (lockResource.sharedLocks.isNotEmpty) {
          final toRemove = <_LockRequest>[];
          for (final r in lockResource.sharedLocks) {
            if (r.operationId == operationId) toRemove.add(r);
          }
          for (final r in toRemove) {
            lockResource.sharedLocks.remove(r);
            removed = true;
          }
        }

        if (removed) {
          // Grant next waiters, and drop the empty resource.
          _processResourceQueue(resource);
          if (lockResource.isEmpty) {
            _activeLocks.remove(resource);
          }
          Logger.warn(
              'Recovered orphaned lock state for $operationId on $resource',
              label: 'LockManager._releaseLock');
        }
      }
      return;
    }

    final lockResource = _activeLocks[resource];
    if (lockResource == null) {
      Logger.warn('Lock resource not found: $resource', label: 'LockManager');
      return;
    }

    // Remove the lock
    lockResource.removeLock(request);

    // Remove from resource queue if still there
    final resourceQueue = _resourceQueues[resource];
    if (resourceQueue != null) {
      resourceQueue.remove(request);
      if (resourceQueue.isEmpty) {
        _resourceQueues.remove(resource);
      }
    }

    // Complete the request if not already completed
    if (!request.completer.isCompleted) {
      try {
        request.completer.complete(false);
      } catch (e) {
        // Ignore "Future already completed" errors
        Logger.debug('Request already completed: ${request.operationId}',
            label: 'LockManager._releaseLock');
      }
    }

    // Process next requests for this resource
    _processResourceQueue(resource);

    // Clean up empty resources
    if (lockResource.isEmpty) {
      _activeLocks.remove(resource);
    }
  }

  /// Handle lock timeout
  void _handleTimeout(_LockRequest request) {
    _totalTimeouts++;
    _removeRequest(request);

    Logger.warn(
        'Lock timeout for operation ${request.operationId} on resource ${request.resource}',
        label: 'LockManager');
  }

  /// Remove a request from all tracking structures
  void _removeRequest(_LockRequest request) {
    _operationToRequest.remove(request.operationId);

    // Remove from resource queue
    final resourceQueue = _resourceQueues[request.resource];
    if (resourceQueue != null) {
      resourceQueue.remove(request);
      if (resourceQueue.isEmpty) {
        _resourceQueues.remove(request.resource);
      }
    }

    // Only complete if not already completed to avoid "Future already completed" error
    if (!request.completer.isCompleted) {
      try {
        request.completer.complete(false);
      } catch (e) {
        // Ignore "Future already completed" errors
        Logger.debug('Request already completed: ${request.operationId}',
            label: 'LockManager._removeRequest');
      }
    }
  }

  /// Clean up tryAcquire request without completing the completer
  /// This is used for synchronous tryAcquire operations
  void _cleanupTryAcquireRequest(_LockRequest request) {
    // Remove from resource queue only
    final resourceQueue = _resourceQueues[request.resource];
    if (resourceQueue != null) {
      resourceQueue.remove(request);
      if (resourceQueue.isEmpty) {
        _resourceQueues.remove(request.resource);
      }
    }

    // Don't complete the completer for tryAcquire operations
    // as they are synchronous and don't need async completion
  }

  /// Adjust dynamic limits based on system load
  void _adjustDynamicLimits() {
    try {
      final loadFactor = _currentLoad / (_maxActiveResources * 0.8);

      if (loadFactor > 0.9) {
        // High load - reduce limits to prevent resource exhaustion
        _maxActiveResources = (_maxActiveResources * 0.95).toInt();
        _maxLocksPerResource = (_maxLocksPerResource * 0.95).toInt();
        _maxQueuedRequestsPerResource =
            (_maxQueuedRequestsPerResource * 0.95).toInt();
        _cleanupInterval = const Duration(minutes: 2); // More frequent cleanup
        _cleanupBatchSize = 200; // Larger batches
      } else if (loadFactor < 0.5) {
        // Low load - increase limits for better performance
        _maxActiveResources = (_maxActiveResources * 1.05).toInt();
        _maxLocksPerResource = (_maxLocksPerResource * 1.05).toInt();
        _maxQueuedRequestsPerResource =
            (_maxQueuedRequestsPerResource * 1.05).toInt();
        _cleanupInterval = const Duration(minutes: 10); // Less frequent cleanup
        _cleanupBatchSize = 50; // Smaller batches
      }
    } catch (e) {
      Logger.error('Error adjusting dynamic limits: $e',
          label: 'LockManager._adjustDynamicLimits');
    }
  }

  /// Detect and resolve deadlocks with improved algorithm for large-scale scenarios
  void _detectDeadlocks() {
    try {
      // Use sampling-based deadlock detection for large-scale scenarios
      if (_activeLocks.length > 10000) {
        _detectDeadlocksSampling();
        return;
      }

      // Use full deadlock detection for smaller scenarios
      _detectDeadlocksFull();
    } catch (e) {
      Logger.error('Error during deadlock detection: $e', label: 'LockManager');
    }
  }

  /// Full deadlock detection for smaller scenarios
  void _detectDeadlocksFull() {
    final visited = <String>{};
    final recursionStack = <String>{};

    for (final resource in _activeLocks.keys) {
      if (!visited.contains(resource)) {
        if (_hasCycle(resource, visited, recursionStack)) {
          _resolveDeadlock(resource);
          return;
        }
      }
    }
  }

  /// Sampling-based deadlock detection for large-scale scenarios
  void _detectDeadlocksSampling() {
    const sampleSize = 1000;
    final resources = _activeLocks.keys.toList();

    if (resources.length <= sampleSize) {
      _detectDeadlocksFull();
      return;
    }

    // Sample resources for deadlock detection
    final random = Random();
    final sampledResources = <String>{};

    for (int i = 0; i < sampleSize; i++) {
      final randomIndex = random.nextInt(resources.length);
      sampledResources.add(resources[randomIndex]);
    }

    final visited = <String>{};
    final recursionStack = <String>{};

    for (final resource in sampledResources) {
      if (!visited.contains(resource)) {
        if (_hasCycle(resource, visited, recursionStack)) {
          _resolveDeadlock(resource);
          return;
        }
      }
    }

    Logger.debug(
        'Completed sampling-based deadlock detection on ${sampledResources.length} resources from ${resources.length} total',
        label: 'LockManager._detectDeadlocksSampling');
  }

  /// Check for cycles in lock graph
  bool _hasCycle(
      String resource, Set<String> visited, Set<String> recursionStack) {
    if (recursionStack.contains(resource)) {
      return true; // Cycle detected
    }

    if (visited.contains(resource)) {
      return false;
    }

    visited.add(resource);
    recursionStack.add(resource);

    // Check dependencies (simplified - in real implementation would track actual dependencies)
    final lockResource = _activeLocks[resource];
    if (lockResource != null) {
      // Check if any waiting requests depend on other resources
      final resourceQueue = _resourceQueues[resource];
      if (resourceQueue != null) {
        for (final request in resourceQueue) {
          if (request.resource != resource &&
              _activeLocks.containsKey(request.resource)) {
            if (_hasCycle(request.resource, visited, recursionStack)) {
              return true;
            }
          }
        }
      }
    }

    recursionStack.remove(resource);
    return false;
  }

  /// Resolve deadlock by timing out oldest request
  void _resolveDeadlock(String resource) {
    _totalDeadlocks++;

    // Find oldest request for this resource
    _LockRequest? oldestRequest;
    DateTime? oldestTime;

    final resourceQueue = _resourceQueues[resource];
    if (resourceQueue != null) {
      for (final request in resourceQueue) {
        if (oldestTime == null || request.requestTime.isBefore(oldestTime)) {
          oldestTime = request.requestTime;
          oldestRequest = request;
        }
      }
    }

    if (oldestRequest != null) {
      Logger.warn(
          'Deadlock detected, timing out oldest request: ${oldestRequest.operationId}',
          label: 'LockManager');
      _handleTimeout(oldestRequest);
    }
  }

  /// Log statistics periodically with improved metrics
  void _logStatistics() {
    final now = DateTime.now();
    final duration = now.difference(_lastStatsTime);
    final requestsPerSecond =
        duration.inSeconds > 0 ? _totalRequests / duration.inSeconds : 0;

    Logger.info(
        'LockManager stats: $_totalRequests requests, $_totalTimeouts timeouts, '
        '$_totalDeadlocks deadlocks, $_totalRejected rejected, ${requestsPerSecond.toStringAsFixed(2)} req/s, '
        '${_activeLocks.length} active resources, ${_resourceQueues.length} resource queues, '
        'current load: $_currentLoad, peak load: $_peakLoad, '
        'limits: $_maxActiveResources resources, $_maxLocksPerResource locks/resource',
        label: 'LockManager');

    // Reset counters
    _totalRequests = 0;
    _totalTimeouts = 0;
    _totalDeadlocks = 0;
    _totalRejected = 0;
    _lastStatsTime = now;
  }

  /// Get current lock statistics with enhanced metrics
  Map<String, dynamic> getStatistics() {
    int totalQueuedRequests = 0;
    for (final queue in _resourceQueues.values) {
      totalQueuedRequests += queue.length;
    }

    return {
      'activeResources': _activeLocks.length,
      'resourceQueues': _resourceQueues.length,
      'totalQueuedRequests': totalQueuedRequests,
      'totalRequests': _totalRequests,
      'totalTimeouts': _totalTimeouts,
      'totalDeadlocks': _totalDeadlocks,
      'totalRejected': _totalRejected,
      'operationMappings': _operationToRequest.length,
      'currentLoad': _currentLoad,
      'peakLoad': _peakLoad,
      'maxActiveResources': _maxActiveResources,
      'maxLocksPerResource': _maxLocksPerResource,
      'maxQueuedRequestsPerResource': _maxQueuedRequestsPerResource,
      'dynamicLockTimeout': _dynamicLockTimeout,
      'cleanupInterval': _cleanupInterval.inMinutes,
      'cleanupBatchSize': _cleanupBatchSize,
    };
  }

  /// Dispose resources
  void dispose() {
    // Cancel all pending requests
    for (final resourceQueue in _resourceQueues.values) {
      for (final request in resourceQueue) {
        if (!request.completer.isCompleted) {
          try {
            request.completer.complete(false);
          } catch (e) {
            // Ignore "Future already completed" errors
            Logger.debug('Request already completed: ${request.operationId}',
                label: 'LockManager.dispose');
          }
        }
      }
    }

    // Clear all data structures
    _requestQueue.clear();
    _activeLocks.clear();
    _operationToRequest.clear();
    _resourceQueues.clear();
    _resourceHierarchy.clear();

    // Remove unified management task from crontab manager
    CrontabManager.removeCallback(
        ExecuteInterval.minutes5, _unifiedManagementTask);
  }
}

/// Lock types
enum LockType {
  shared, // Read lock - multiple can be held simultaneously
  exclusive, // Write lock - only one can be held at a time
}

/// Lock request representation with optimized memory usage
class _LockRequest {
  final String resource;
  final String operationId;
  final LockType lockType;
  final DateTime requestTime;
  final Completer<bool> completer;

  _LockRequest({
    required this.resource,
    required this.operationId,
    required this.lockType,
    required this.requestTime,
    required this.completer,
  });

  @override
  bool operator ==(Object other) {
    return other is _LockRequest && other.operationId == operationId;
  }

  @override
  int get hashCode => operationId.hashCode;
}

/// Lock resource representation with improved efficiency
class _LockResource {
  final Set<_LockRequest> sharedLocks = {};
  _LockRequest? exclusiveLock;

  /// Add a lock to this resource
  void addLock(_LockRequest request) {
    switch (request.lockType) {
      case LockType.shared:
        sharedLocks.add(request);
        break;
      case LockType.exclusive:
        exclusiveLock = request;
        break;
    }
  }

  /// Remove a lock from this resource
  void removeLock(_LockRequest request) {
    switch (request.lockType) {
      case LockType.shared:
        sharedLocks.remove(request);
        break;
      case LockType.exclusive:
        if (exclusiveLock?.operationId == request.operationId) {
          exclusiveLock = null;
        }
        break;
    }
  }

  /// Check if resource has no active locks
  bool get isEmpty => sharedLocks.isEmpty && exclusiveLock == null;

  /// Get total number of active locks
  int get lockCount => sharedLocks.length + (exclusiveLock != null ? 1 : 0);
}
