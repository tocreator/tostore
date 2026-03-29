import 'dart:async';
import 'dart:math';

/// Centralized concurrency scheduler implementing global token budgeting.
///
/// - Global capacity = [globalMax] tokens
/// - Per type baseline = floor(globalMax * share[type])
/// - Call [acquire] to reserve tokens for a workload; call [release] when done.
///
/// Long-running callers should split work into smaller chunks and keep reporting
/// their remaining total demand through [totalPlannedTokens]. That allows the
/// scheduler to rebalance capacity across rounds instead of letting the first
/// requester monopolize the entire budget for too long.
class WorkloadScheduler {
  final int globalMax;
  final Map<WorkloadType, double> _share;
  final Map<WorkloadType, int> _usedTokens = {
    WorkloadType.flush: 0,
    WorkloadType.query: 0,
    WorkloadType.maintenance: 0,
    WorkloadType.aux: 0,
  };
  final Map<WorkloadType, int> _activeDemandTokens = {
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

  /// Capacity in tokens for a given type under the current declared demand.
  ///
  /// [extraDemandTokens] lets callers preview how much capacity a new/next round
  /// of work would get before they actually enqueue it.
  int capacityTokens(
    WorkloadType type, {
    int extraDemandTokens = 0,
  }) {
    return _capacityTokensFor(type, extraDemandTokens: extraDemandTokens);
  }

  /// Total tokens currently in use across all types.
  int get totalUsedTokens {
    var sum = 0;
    for (final value in _usedTokens.values) {
      sum += value;
    }
    return sum;
  }

  /// Reserve tokens for a workload type.
  ///
  /// - [requestedTokens]: desired tokens (defaults to the current fair capacity)
  /// - [minTokens]: minimum tokens to grant when available (defaults to 1)
  /// - [totalPlannedTokens]: total remaining demand represented by this request
  ///   across future rounds/chunks; defaults to [requestedTokens]
  /// - [label]: optional tag for diagnostics
  Future<WorkloadLease> acquire(
    WorkloadType type, {
    int? requestedTokens,
    int? minTokens,
    int? totalPlannedTokens,
    String? label,
  }) async {
    final normalizedMin = _normalizeMinTokens(minTokens);
    final declaredDemand = _normalizeDeclaredDemand(
      requestedTokens,
      totalPlannedTokens,
      type,
    );
    final requested = _normalizeRequestedTokens(
      type,
      requestedTokens,
      extraDemandTokens: declaredDemand,
    );

    final immediate = _tryGrantImmediate(
      type,
      requestedTokens: requested,
      minTokens: normalizedMin,
      declaredDemandTokens: declaredDemand,
      label: label,
    );
    if (immediate != null) {
      return immediate;
    }

    final completer = Completer<WorkloadLease>();
    _queues[type]!.add(
      _PendingRequest(
        completer,
        requested,
        normalizedMin,
        declaredDemand,
        label,
      ),
    );
    _drainQueues();
    return completer.future;
  }

  /// Try to reserve tokens without waiting.
  ///
  /// Returns a [WorkloadLease] if enough tokens are immediately available,
  /// otherwise returns `null`.
  Future<WorkloadLease?> tryAcquire(
    WorkloadType type, {
    int? requestedTokens,
    int? minTokens,
    int? totalPlannedTokens,
    String? label,
  }) async {
    final normalizedMin = _normalizeMinTokens(minTokens);
    final declaredDemand = _normalizeDeclaredDemand(
      requestedTokens,
      totalPlannedTokens,
      type,
    );
    final requested = _normalizeRequestedTokens(
      type,
      requestedTokens,
      extraDemandTokens: declaredDemand,
    );

    return _tryGrantImmediate(
      type,
      requestedTokens: requested,
      minTokens: normalizedMin,
      declaredDemandTokens: declaredDemand,
      label: label,
    );
  }

  void _release(
    WorkloadType type,
    int tokens,
    int declaredDemandTokens,
  ) {
    if (tokens <= 0 && declaredDemandTokens <= 0) {
      return;
    }

    _usedTokens[type] = max(0, _usedTokens[type]! - tokens);
    _activeDemandTokens[type] =
        max(0, _activeDemandTokens[type]! - declaredDemandTokens);
    _drainQueues();
  }

  void _drainQueues() {
    var madeProgress = false;
    do {
      madeProgress = false;
      for (final type in WorkloadType.values) {
        if (_grantQueuedRequest(type)) {
          madeProgress = true;
        }
      }
    } while (madeProgress);
  }

  bool _grantQueuedRequest(WorkloadType type) {
    final queue = _queues[type]!;
    if (queue.isEmpty) {
      return false;
    }

    final request = queue.first;
    final available = _availableTokensFor(
      type,
      extraDemandTokens: 0,
    );
    if (available < request.minTokens) {
      return false;
    }

    final grant = _clampGrant(available, request.requested, request.minTokens);
    _usedTokens[type] = _usedTokens[type]! + grant;
    _activeDemandTokens[type] =
        _activeDemandTokens[type]! + request.declaredDemandTokens;
    queue.removeAt(0);
    request.completer.complete(
      WorkloadLease(
        this,
        type,
        grant,
        label: request.label,
        declaredDemandTokens: request.declaredDemandTokens,
      ),
    );
    return true;
  }

  WorkloadLease? _tryGrantImmediate(
    WorkloadType type, {
    required int requestedTokens,
    required int minTokens,
    required int declaredDemandTokens,
    String? label,
  }) {
    final available = _availableTokensFor(
      type,
      extraDemandTokens: declaredDemandTokens,
    );
    if (available < minTokens) {
      return null;
    }

    final grant = _clampGrant(available, requestedTokens, minTokens);
    _usedTokens[type] = _usedTokens[type]! + grant;
    _activeDemandTokens[type] =
        _activeDemandTokens[type]! + declaredDemandTokens;
    return WorkloadLease(
      this,
      type,
      grant,
      label: label,
      declaredDemandTokens: declaredDemandTokens,
    );
  }

  int _availableTokensFor(
    WorkloadType type, {
    required int extraDemandTokens,
    WorkloadLease? replacingLease,
    bool includeReplacingLeaseTokens = false,
  }) {
    final replacingTokens = includeReplacingLeaseTokens &&
            replacingLease != null &&
            !replacingLease._released &&
            replacingLease.type == type
        ? replacingLease.tokens
        : 0;

    final usedByType = max(0, _usedTokens[type]! - replacingTokens);
    final physicalAvailable =
        max(0, globalMax - totalUsedTokens + replacingTokens);
    final fairCapacity = _capacityTokensFor(
      type,
      extraDemandTokens: extraDemandTokens,
      replacingLease: replacingLease,
    );
    final typeAvailable = max(0, fairCapacity - usedByType);
    return min(typeAvailable, physicalAvailable);
  }

  int _capacityTokensFor(
    WorkloadType type, {
    int extraDemandTokens = 0,
    WorkloadLease? replacingLease,
  }) {
    if (globalMax <= 0) {
      return 0;
    }

    final demandByType = <WorkloadType, int>{};
    for (final workloadType in WorkloadType.values) {
      demandByType[workloadType] =
          _declaredDemandFor(workloadType, replacingLease: replacingLease);
    }
    demandByType[type] = demandByType[type]! + max(0, extraDemandTokens);

    final activeTypes = WorkloadType.values
        .where((workloadType) => demandByType[workloadType]! > 0)
        .toList(growable: false);
    if (activeTypes.isEmpty) {
      return globalMax;
    }

    final allocations = {
      for (final workloadType in WorkloadType.values) workloadType: 0,
    };
    final baseTargets = <WorkloadType, int>{};
    var allocated = 0;

    for (final workloadType in activeTypes) {
      final base = min(
        demandByType[workloadType]!,
        _baselineCapacityTokens(workloadType),
      );
      baseTargets[workloadType] = base;
      allocated += base;
    }

    if (allocated > globalMax) {
      final scaled = _allocateProportionally(baseTargets, globalMax);
      for (final workloadType in activeTypes) {
        allocations[workloadType] = scaled[workloadType] ?? 0;
      }
      allocated = globalMax;
    } else {
      for (final workloadType in activeTypes) {
        allocations[workloadType] = baseTargets[workloadType] ?? 0;
      }
    }

    final remainingBudget = globalMax - allocated;
    if (remainingBudget > 0) {
      final remainingDemand = <WorkloadType, int>{};
      for (final workloadType in activeTypes) {
        final stillNeeded =
            demandByType[workloadType]! - allocations[workloadType]!;
        if (stillNeeded > 0) {
          remainingDemand[workloadType] = stillNeeded;
        }
      }

      final burstAllocations =
          _allocateProportionally(remainingDemand, remainingBudget);
      for (final workloadType in activeTypes) {
        allocations[workloadType] =
            allocations[workloadType]! + (burstAllocations[workloadType] ?? 0);
      }
    }

    return allocations[type] ?? 0;
  }

  int _declaredDemandFor(
    WorkloadType type, {
    WorkloadLease? replacingLease,
  }) {
    var activeDemand = _activeDemandTokens[type]!;
    if (replacingLease != null &&
        !replacingLease._released &&
        replacingLease.type == type) {
      activeDemand = max(0, activeDemand - replacingLease.declaredDemandTokens);
    }

    var queuedDemand = 0;
    for (final request in _queues[type]!) {
      queuedDemand += request.declaredDemandTokens;
    }
    return activeDemand + queuedDemand;
  }

  int _baselineCapacityTokens(WorkloadType type) {
    if (globalMax <= 0) {
      return 0;
    }

    var cap = (globalMax * (_share[type] ?? 0.0)).floor();
    if (type != WorkloadType.aux && cap < 1) {
      cap = 1;
    }
    return min(cap, globalMax);
  }

  Map<WorkloadType, int> _allocateProportionally(
    Map<WorkloadType, int> weights,
    int tokens,
  ) {
    final allocations = {
      for (final workloadType in WorkloadType.values) workloadType: 0,
    };
    if (tokens <= 0) {
      return allocations;
    }

    final activeTypes = weights.entries
        .where((entry) => entry.value > 0)
        .map((entry) => entry.key)
        .toList(growable: false);
    if (activeTypes.isEmpty) {
      return allocations;
    }

    final totalWeight = activeTypes.fold<int>(
      0,
      (sum, workloadType) => sum + (weights[workloadType] ?? 0),
    );
    if (totalWeight <= 0) {
      return allocations;
    }

    final remainders = <WorkloadType, double>{};
    var used = 0;
    for (final workloadType in activeTypes) {
      final weight = weights[workloadType]!;
      final exact = tokens * weight / totalWeight;
      final whole = min(weight, exact.floor());
      allocations[workloadType] = whole;
      used += whole;
      remainders[workloadType] = exact - whole;
    }

    var leftover = tokens - used;
    while (leftover > 0) {
      WorkloadType? bestType;
      var bestScore = double.negativeInfinity;

      for (final workloadType in activeTypes) {
        final remainingWeight =
            weights[workloadType]! - allocations[workloadType]!;
        if (remainingWeight <= 0) {
          continue;
        }

        final score = remainders[workloadType]! +
            remainingWeight / weights[workloadType]!;
        if (bestType == null || score > bestScore) {
          bestType = workloadType;
          bestScore = score;
        }
      }

      if (bestType == null) {
        break;
      }

      allocations[bestType] = allocations[bestType]! + 1;
      remainders[bestType] = 0;
      leftover--;
    }

    return allocations;
  }

  int _normalizeMinTokens(int? minTokens) {
    if (minTokens == null || minTokens <= 0) {
      return 1;
    }
    return minTokens;
  }

  int _normalizeRequestedTokens(
    WorkloadType type,
    int? requestedTokens, {
    required int extraDemandTokens,
  }) {
    if (requestedTokens != null && requestedTokens > 0) {
      return requestedTokens;
    }

    final capacity = capacityTokens(
      type,
      extraDemandTokens: extraDemandTokens,
    );
    return max(1, capacity);
  }

  int _normalizeDeclaredDemand(
    int? requestedTokens,
    int? totalPlannedTokens,
    WorkloadType type,
  ) {
    final requested = _normalizeRequestedTokens(
      type,
      requestedTokens,
      extraDemandTokens: max(0, totalPlannedTokens ?? 0),
    );
    final planned = totalPlannedTokens ?? requested;
    return max(requested, planned);
  }

  int _clampGrant(int available, int requested, int minTokens) {
    var grant = requested;
    if (grant > available) {
      grant = available;
    }
    if (grant < minTokens) {
      grant = minTokens;
    }
    if (grant < 1) {
      grant = 1;
    }
    return grant;
  }

  /// Reacquire a lease with updated token allocation.
  ///
  /// The caller should pass the remaining work through [totalPlannedTokens] so
  /// the next round can be rebalanced against other active queues.
  Future<WorkloadLease> reacquire(
    WorkloadLease oldLease, {
    int? requestedTokens,
    int? minTokens,
    int? totalPlannedTokens,
    String? label,
  }) async {
    final swapped = tryReacquire(
      oldLease,
      requestedTokens: requestedTokens,
      minTokens: minTokens,
      totalPlannedTokens: totalPlannedTokens,
      label: label,
    );
    if (swapped != null) {
      return swapped;
    }

    final newLease = await acquire(
      oldLease.type,
      requestedTokens: requestedTokens,
      minTokens: minTokens,
      totalPlannedTokens: totalPlannedTokens,
      label: label ?? oldLease.label,
    );
    oldLease.release();
    return newLease;
  }

  /// Try to reacquire a lease without blocking.
  WorkloadLease? tryReacquire(
    WorkloadLease oldLease, {
    int? requestedTokens,
    int? minTokens,
    int? totalPlannedTokens,
    String? label,
  }) {
    if (oldLease._released) {
      return null;
    }

    final normalizedMin = _normalizeMinTokens(minTokens);
    final declaredDemand = _normalizeDeclaredDemand(
      requestedTokens,
      totalPlannedTokens,
      oldLease.type,
    );
    final requested = _normalizeRequestedTokens(
      oldLease.type,
      requestedTokens,
      extraDemandTokens: declaredDemand,
    );

    final available = _availableTokensFor(
      oldLease.type,
      extraDemandTokens: declaredDemand,
      replacingLease: oldLease,
      includeReplacingLeaseTokens: true,
    );
    if (available < normalizedMin) {
      return null;
    }

    final grant = _clampGrant(available, requested, normalizedMin);
    _usedTokens[oldLease.type] =
        _usedTokens[oldLease.type]! + grant - oldLease.tokens;
    _activeDemandTokens[oldLease.type] = _activeDemandTokens[oldLease.type]! +
        declaredDemand -
        oldLease.declaredDemandTokens;
    oldLease._released = true;

    return WorkloadLease(
      this,
      oldLease.type,
      grant,
      label: label ?? oldLease.label,
      declaredDemandTokens: declaredDemand,
    );
  }
}

/// Workload categories for centralized concurrency budgeting.
enum WorkloadType { flush, query, maintenance, aux }

/// A lease representing reserved scheduler tokens (energy units).
/// Call [release] when finished to return tokens to the pool.
class WorkloadLease {
  final WorkloadScheduler _scheduler;
  final WorkloadType type;
  final int tokens;
  final int declaredDemandTokens;
  final String? label;
  bool _released = false;

  WorkloadLease(
    this._scheduler,
    this.type,
    this.tokens, {
    this.label,
    required this.declaredDemandTokens,
  });

  /// Convert reserved tokens to an integer concurrency based on energy cost.
  int asConcurrency(double cost) {
    if (tokens <= 0) {
      return 1;
    }
    final concurrency = (tokens / cost).floor();
    return concurrency < 1 ? 1 : concurrency;
  }

  void release() {
    if (_released) {
      return;
    }
    _released = true;
    _scheduler._release(type, tokens, declaredDemandTokens);
  }
}

class _PendingRequest {
  final Completer<WorkloadLease> completer;
  final int requested;
  final int minTokens;
  final int declaredDemandTokens;
  final String? label;

  _PendingRequest(
    this.completer,
    this.requested,
    this.minTokens,
    this.declaredDemandTokens,
    this.label,
  );
}
