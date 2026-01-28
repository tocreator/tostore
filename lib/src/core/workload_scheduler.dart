import 'dart:async';
import 'dart:math';

/// Centralized concurrency scheduler implementing global token budgeting.
///
/// - Global capacity = [globalMax] tokens
/// - Per type capacity = floor(globalMax * share[type])
/// - Call [acquire] to reserve tokens for a workload; call [release] when done.
///
/// Notes:
/// - A "token" equals the energy cost of 1 flush/write unit.
/// - Convert tokens to task concurrency via: floor(tokens / costPerTask).
/// - For critical types (flush/query/maintenance), [acquire] guarantees at least 1 token
///   once capacity becomes available (no preemption).
class WorkloadScheduler {
  final int globalMax;
  final Map<WorkloadType, double> _share;
  final Map<WorkloadType, int> _usedTokens = {
    WorkloadType.flush: 0,
    WorkloadType.query: 0,
    WorkloadType.maintenance: 0,
    WorkloadType.aux: 0,
  };
  final Map<WorkloadType, List<_PendingRequest>> _queues = {
    WorkloadType.flush: <_PendingRequest>[],
    WorkloadType.query: <_PendingRequest>[],
    WorkloadType.maintenance: <_PendingRequest>[],
    WorkloadType.aux: <_PendingRequest>[],
  };

  WorkloadScheduler({
    required this.globalMax,
    Map<WorkloadType, double>? shares,
  }) : _share = shares ??
            const {
              WorkloadType.flush: 0.40,
              WorkloadType.query: 0.40,
              WorkloadType.maintenance: 0.15,
              WorkloadType.aux: 0.05,
            };

  /// Capacity in tokens for a given type.
  ///
  /// This supports **Elastic Capacity**:
  /// - If system is under contention (other queues have waiters), returns [share] based limit.
  /// - If system is idle (other queues empty), returns [globalMax] to allow bursting.
  int capacityTokens(WorkloadType type) {
    if (globalMax <= 0) return 0;

    // Check if other types have pending requests (contention)
    bool hasContention = false;
    for (final t in WorkloadType.values) {
      if (t != type && _queues[t]!.isNotEmpty) {
        hasContention = true;
        break;
      }
    }

    if (!hasContention) {
      // Elastic mode: allowed to use up to globalMax
      return globalMax;
    }

    // Strict mode: share-based limit
    int cap = (globalMax * (_share[type] ?? 0.0)).floor();
    // Ensure critical types always have at least 1 token when globalMax > 0
    if (type != WorkloadType.aux && cap < 1) cap = 1;
    if (cap > globalMax) cap = globalMax;
    return cap;
  }

  /// Total tokens currently in use across all types.
  int get totalUsedTokens {
    int sum = 0;
    for (final v in _usedTokens.values) {
      sum += v;
    }
    return sum;
  }

  /// Reserve tokens for a workload type.
  ///
  /// - requestedTokens: desired tokens (defaults to type capacity)
  /// - minTokens: minimum tokens to grant when available (defaults to 1 for critical, 0 for aux)
  /// - label: optional tag for diagnostics
  Future<WorkloadLease> acquire(
    WorkloadType type, {
    int? requestedTokens,
    int? minTokens,
    String? label,
  }) async {
    final int cap = capacityTokens(type);
    final int req = (requestedTokens == null || requestedTokens <= 0)
        ? cap
        : requestedTokens;
    final int minTok = minTokens ?? (type == WorkloadType.aux ? 0 : 1);

    // Fast path: try to allocate immediately.
    // In elastic mode, we check against global available too.
    final int typeCap = capacityTokens(type);

    // We are limited by whichever is smaller: type capacity (elastic) or physical global tokens left
    // Actually, capacityTokens(type) returning globalMax means logic is:
    // available = capacityTokens(type) - _usedTokens[type] -> This is standard logic
    // But we must ALSO respect the hard globalMax ceiling.

    // Simplification: logic is always globalMax - totalUsedTokens?
    // No, because we want to reserve shares for others if they are waiting.

    // Correct logic with elastic capacityTokens():
    // 1. Calculate how many tokens this type is *allowed* to have (elastic limit).
    // 2. Calculate how many it *can* take physically (globalMax - totalUsed).
    // 3. Take min.

    // Wait, capacityTokens() already checks queues.
    // If queues are empty, it returns globalMax.
    // So currentUsed + grant <= globalMax.
    // grant <= globalMax - currentUsed.
    // BUT, we also have to respect the physical global limit:
    // grant <= globalMax - totalUsedTokens.

    final int typeAllowed = typeCap - _usedTokens[type]!;
    final int physicalAvailable = globalMax - totalUsedTokens;
    final int available = min(typeAllowed, physicalAvailable);

    if (available >= (minTok <= 0 ? 1 : minTok)) {
      final grant = _clampGrant(available, req, minTok);
      _usedTokens[type] = _usedTokens[type]! + grant;
      return WorkloadLease(this, type, grant, label: label);
    }

    // Otherwise, enqueue and wait.
    final completer = Completer<WorkloadLease>();
    _queues[type]!.add(
        _PendingRequest(completer, req, (minTok <= 0 ? 1 : minTok), label));
    return completer.future;
  }

  /// Try to reserve tokens without waiting.
  ///
  /// Returns a [WorkloadLease] if enough tokens are immediately available,
  /// otherwise returns `null`. This is a non-blocking alternative to [acquire].
  Future<WorkloadLease?> tryAcquire(
    WorkloadType type, {
    int? requestedTokens,
    int? minTokens,
    String? label,
  }) async {
    final int cap = capacityTokens(type);
    final int req = (requestedTokens == null || requestedTokens <= 0)
        ? cap
        : requestedTokens;
    final int minTok = minTokens ?? (type == WorkloadType.aux ? 0 : 1);

    final int typeCap = capacityTokens(type);
    final int typeAllowed = typeCap - _usedTokens[type]!;
    final int physicalAvailable = globalMax - totalUsedTokens;
    final int available = min(typeAllowed, physicalAvailable);

    if (available >= (minTok <= 0 ? 1 : minTok)) {
      final grant = _clampGrant(available, req, (minTok <= 0 ? 1 : minTok));
      _usedTokens[type] = _usedTokens[type]! + grant;
      return WorkloadLease(this, type, grant, label: label);
    }
    return null;
  }

  void _release(WorkloadType type, int tokens) {
    if (tokens <= 0) return;
    _usedTokens[type] = (_usedTokens[type]! - tokens);
    if (_usedTokens[type]! < 0) _usedTokens[type] = 0;
    _drainQueue(type);
  }

  void _drainQueue(WorkloadType type) {
    if (_queues[type]!.isEmpty) return;
    final int typeCap = capacityTokens(type); // Re-evaluate elastic capacity
    final int typeAllowed = typeCap - _usedTokens[type]!;
    final int physicalAvailable = globalMax - totalUsedTokens;
    int available = min(typeAllowed, physicalAvailable);

    if (available <= 0) return;

    // FIFO fairness within type.
    final queue = _queues[type]!;
    int i = 0;
    while (i < queue.length && available > 0) {
      final p = queue[i];
      if (available >= p.minTokens) {
        final grant = _clampGrant(available, p.requested, p.minTokens);
        _usedTokens[type] = _usedTokens[type]! + grant;
        available -= grant;
        queue.removeAt(i);
        p.completer.complete(WorkloadLease(this, type, grant, label: p.label));
      } else {
        i++;
      }
    }
  }

  int _clampGrant(int available, int requested, int minTokens) {
    int grant = requested;
    if (grant > available) grant = available;
    if (grant < minTokens) grant = minTokens;
    if (grant < 1) grant = 1;
    return grant;
  }

  /// Reacquire a lease with updated token allocation.
  ///
  /// Releases the old lease and acquires a new one with the latest available capacity.
  /// This is useful for long-running tasks that want to dynamically adjust their
  /// concurrency based on system load changes.
  ///
  /// - [oldLease]: The lease to replace
  /// - [requestedTokens]: Desired tokens (defaults to type capacity)
  /// - [minTokens]: Minimum tokens to grant (defaults to 1 for critical types)
  /// - [label]: Optional label for the new lease
  ///
  /// Note: This method will wait until at least minTokens are available.
  /// The old lease is released only after the new lease is acquired to ensure
  /// continuous token occupation.
  Future<WorkloadLease> reacquire(
    WorkloadLease oldLease, {
    int? requestedTokens,
    int? minTokens,
    String? label,
  }) async {
    final newLease = await acquire(
      oldLease.type,
      requestedTokens: requestedTokens,
      minTokens: minTokens,
      label: label ?? oldLease.label,
    );
    oldLease.release();
    return newLease;
  }

  /// Try to reacquire a lease without blocking.
  ///
  /// Attempts to replace the old lease with a new one with updated capacity.
  /// If insufficient tokens are available, returns null and keeps the old lease intact.
  ///
  /// - [oldLease]: The lease to replace
  /// - [requestedTokens]: Desired tokens (defaults to type capacity)
  /// - [minTokens]: Minimum tokens to grant (defaults to 1 for critical types)
  /// - [label]: Optional label for the new lease
  ///
  /// Returns the new lease if successful, null otherwise.
  /// The old lease remains valid if reacquisition fails.
  WorkloadLease? tryReacquire(
    WorkloadLease oldLease, {
    int? requestedTokens,
    int? minTokens,
    String? label,
  }) {
    if (oldLease._released) return null;

    final int req = (requestedTokens == null || requestedTokens <= 0)
        ? capacityTokens(oldLease.type)
        : requestedTokens;
    final int minTok = minTokens ?? (oldLease.type == WorkloadType.aux ? 0 : 1);

    // Elastic check
    final int typeCap = capacityTokens(oldLease.type);
    final int typeAllowed =
        typeCap - _usedTokens[oldLease.type]! + oldLease.tokens;
    final int physicalAvailable = globalMax - totalUsedTokens + oldLease.tokens;
    final int available = min(typeAllowed, physicalAvailable);

    if (available >= (minTok <= 0 ? 1 : minTok)) {
      final grant = _clampGrant(available, req, minTok);

      // Atomically swap: add new tokens, remove old tokens
      _usedTokens[oldLease.type] =
          _usedTokens[oldLease.type]! + grant - oldLease.tokens;
      if (_usedTokens[oldLease.type]! < 0) _usedTokens[oldLease.type] = 0;

      // Mark old lease as released and create new lease
      oldLease._released = true;
      return WorkloadLease(this, oldLease.type, grant,
          label: label ?? oldLease.label);
    }
    return null;
  }
}

/// Workload categories for centralized concurrency budgeting.
enum WorkloadType { flush, query, maintenance, aux }

/// A lease representing reserved scheduler tokens (energy units).
/// Call [release] when finished to return tokens to the pool.
class WorkloadLease {
  final WorkloadScheduler _scheduler;
  final WorkloadType type;
  final int tokens; // reserved energy tokens
  final String? label;
  bool _released = false;

  WorkloadLease(this._scheduler, this.type, this.tokens, {this.label});

  /// Convert reserved tokens to an integer concurrency based on energy cost.
  /// Example: cost=1 for flush/write, 0.3 for read/query.
  int asConcurrency(double cost) {
    if (tokens <= 0) return 1;
    final c = (tokens / cost).floor();
    return c < 1 ? 1 : c;
  }

  void release() {
    if (_released) return;
    _released = true;
    _scheduler._release(type, tokens);
  }
}

class _PendingRequest {
  final Completer<WorkloadLease> completer;
  final int requested; // requested tokens
  final int minTokens;
  final String? label;
  _PendingRequest(this.completer, this.requested, this.minTokens, this.label);
}
