import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../model/db_exception.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import 'yield_controller.dart';

/// Optional per-suffix comparator after the group prefix.
typedef TreeCacheComparatorFactory = Comparator<dynamic> Function(
  List<dynamic> groupPath, {
  int suffixIndex,
});

typedef TreeCacheSizeCalculator<T> = int Function(T value);

/// Eviction policy. [none] keeps Map-speed hot paths (no order list / bytes).
/// [lru] / [fifo] maintain a per-group order list for [cleanup].
enum TreeCacheEvictionMode {
  none,
  lru,
  fifo,
}

typedef TreeCacheEvictedCallback = void Function(int removedCount);
typedef TreeCacheBeforeCleanupCallback = FutureOr<bool> Function();
typedef TreeCacheWeightQueryCallback = Future<int?> Function(
  List<dynamic> groupPath,
);

/// Hierarchical path-key cache (point Map + lazy ordered range view).
///
/// - [TreeCacheEvictionMode.none]: Map-speed resident store (e.g. buffer trees)
/// - [lru]/[fifo]: side order-list + byte ledger for [cleanup]
/// - Ordered view is lazy (first [scanRange] / [ensureOrdered] / [prepareOrderedViews])
/// - Flat LRU leaves use [_LiveFlat] so get+touch needs one Hash probe
///
/// Gate: `bin/tree_cache_benchmark.dart` (Buffer shapes <= ~1.2x Nested Map in none mode).
class TreeCache<T> {
  final int groupDepth;

  /// Default component comparator when [comparatorFactory] is null.
  final Comparator<dynamic> compare;

  /// Typed suffix comparators (index / PK order). Null -> [compare] for all.
  final TreeCacheComparatorFactory? comparatorFactory;

  final TreeCacheSizeCalculator<T>? sizeCalculator;

  final TreeCacheEvictionMode evictionMode;

  final String debugLabel;

  final TreeCacheEvictedCallback? onEvicted;
  final TreeCacheBeforeCleanupCallback? beforeCleanup;
  final TreeCacheWeightQueryCallback? weightQueryCallback;

  /// True for [lru]/[fifo]: order list + byte ledger.
  final bool _orderEnabled;

  /// Move-to-MRU on get/put-update ([lru] only).
  final bool _reorderOnTouch;

  int _maxByteThreshold;
  int _minByteThreshold;
  int _estimatedTotalSizeBytes = 0;

  /// Nested group map (depth = [groupDepth]). Leaves are [_Group].
  final Map<Object?, dynamic> _groupsRoot = <Object?, dynamic>{};

  /// Nested fully-cached markers for prefix completeness.
  final Map<Object?, dynamic> _fullyCachedRoot = <Object?, dynamic>{};

  int _totalEntries = 0;

  Future<void>? _cleanupLock;
  DateTime _lastCleanupTime = DateTime.fromMillisecondsSinceEpoch(0);

  /// Group finger -- skips nested HashMap probes on steady same-group traffic.
  Object? _f0;
  Object? _f1;
  Object? _f2;
  _Group<T>? _fingerGroup;

  /// 0 = invalid; else matches [groupDepth] of the fingered group.
  int _fingerDepth = 0;

  TreeCache({
    this.groupDepth = 1,
    Comparator<dynamic>? compare,
    this.comparatorFactory,
    this.sizeCalculator,
    this.evictionMode = TreeCacheEvictionMode.lru,
    this.debugLabel = 'TreeCache',
    this.onEvicted,
    this.beforeCleanup,
    this.weightQueryCallback,
    int maxByteThreshold = 1,
    int minByteThreshold = 1,
  })  : compare = compare ?? compareNative,
        _orderEnabled = evictionMode != TreeCacheEvictionMode.none,
        _reorderOnTouch = evictionMode == TreeCacheEvictionMode.lru,
        _minByteThreshold = minByteThreshold < 1 ? 1 : minByteThreshold,
        _maxByteThreshold = math.max(
          maxByteThreshold,
          minByteThreshold < 1 ? 1 : minByteThreshold,
        ) {
    if (groupDepth < 1 || groupDepth > 3) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.engError,
          message: 'TreeCache groupDepth must be 1..3',
          parameterName: 'groupDepth',
          passedValue: groupDepth,
        )
      ]);
    }
  }

  int get length => _totalEntries;

  bool get isEmpty => _totalEntries <= 0;

  int get estimatedTotalSizeBytes => _estimatedTotalSizeBytes;

  int get maxByteThreshold => _maxByteThreshold;

  int get minByteThreshold => _minByteThreshold;

  void updateByteThreshold({int? max, int? min}) {
    if (min != null) _minByteThreshold = min < 1 ? 1 : min;
    if (max != null) _maxByteThreshold = max;
    if (_maxByteThreshold < _minByteThreshold) {
      _maxByteThreshold = _minByteThreshold;
    }
  }

  /// Entry count for an exact group key (`key` length == [groupDepth]).
  int groupEntryCount(dynamic key) {
    final k = _normalizeKey(key);
    if (k.length != groupDepth) return 0;
    return _getGroupForKey(k, create: false)?.entryCount ?? 0;
  }

  bool hasGroupEntries(dynamic key) => groupEntryCount(key) > 0;

  bool isFullyCached(dynamic keyOrPrefix) {
    final p = _normalizeKey(keyOrPrefix);
    return _isFullyCached(p);
  }

  void setFullyCached(dynamic keyOrPrefix, bool isFullyCached) {
    final p = _normalizeKey(keyOrPrefix);
    _setFullyCached(p, isFullyCached);
  }

  void _clearFinger() {
    _f0 = null;
    _f1 = null;
    _f2 = null;
    _fingerGroup = null;
    _fingerDepth = 0;
  }

  int _resolveSize(int? size, T value) {
    if (size != null && size > 0) return size;
    final calc = sizeCalculator;
    if (calc != null) {
      final n = calc(value);
      return n <= 0 ? 1 : n;
    }
    return 1;
  }

  void _applyGroupByteDelta(_Group<T> g, int beforeBytes) {
    if (!_orderEnabled) return;
    final diff = g.totalBytes - beforeBytes;
    if (diff == 0) return;
    _estimatedTotalSizeBytes += diff;
    if (_estimatedTotalSizeBytes < 0) _estimatedTotalSizeBytes = 0;
  }

  /// After a successful single-entry remove: debit totals and drop empty group.
  void _afterPointRemoved(_Group<T> g, {int? beforeBytes}) {
    _totalEntries--;
    if (_totalEntries < 0) _totalEntries = 0;
    if (beforeBytes != null) _applyGroupByteDelta(g, beforeBytes);
    if (g.entryCount <= 0 && g.pinCount <= 0) {
      _removeEmptyGroup(g.groupPath);
    }
  }

  /// Default comparator for dynamic key components.
  static int compareNative(dynamic a, dynamic b) {
    if (identical(a, b)) return 0;
    if (a is String && a == '\uffff') {
      return (b is String && b == '\uffff') ? 0 : 1;
    }
    if (b is String && b == '\uffff') return -1;

    if (a == null) return b == null ? 0 : -1;
    if (b == null) return 1;

    if (a is String && b is String) return a.compareTo(b);
    if (a is num && b is num) return a.compareTo(b);
    if (a is bool && b is bool) return (a == b) ? 0 : (a ? 1 : -1);

    if (a is Uint8List && b is Uint8List) {
      final int n = math.min(a.length, b.length);
      for (int i = 0; i < n; i++) {
        final av = a[i];
        final bv = b[i];
        if (av != bv) return av < bv ? -1 : 1;
      }
      if (a.length == b.length) return 0;
      return a.length < b.length ? -1 : 1;
    }

    int rank(dynamic v) {
      if (v == null) return 0;
      if (v is bool) return 1;
      if (v is num) return 2;
      if (v is String) return 3;
      if (v is Uint8List) return 4;
      return 5;
    }

    final ra = rank(a);
    final rb = rank(b);
    if (ra != rb) return ra < rb ? -1 : 1;
    return a.toString().compareTo(b.toString());
  }

  // ---------------------------------------------------------------------------
  // Point ops -- specialized hot paths for BufferTreeStore + page/meta caches
  // ---------------------------------------------------------------------------

  /// Accept List path or scalar (meta caches use tableUid alone).
  @pragma('vm:prefer-inline')
  List _keyList(dynamic key) {
    if (key is List) return key;
    return <dynamic>[key];
  }

  /// Same as [get] with touch/updateStats disabled.
  @pragma('vm:prefer-inline')
  T? peek(dynamic key) => get(key, touch: false);

  /// Zero-allocation 2-component point lookup.
  ///
  /// - gd=1: `[groupKey, flatKey]` (table record)
  /// - gd=2: exact group `[k0, k1]` (index meta)
  @pragma('vm:prefer-inline')
  T? getPoint2(Object? k0, Object? k1, {bool touch = true, bool? updateStats}) {
    final gd = groupDepth;
    final doTouch = _reorderOnTouch && (updateStats ?? touch);
    if (gd == 1) {
      final g = _groupOfDepth1(k0);
      if (g == null) return null;
      return g.getFlat(k1, touch: doTouch);
    }
    if (gd == 2) {
      final g = _groupOfDepth2(k0, k1);
      if (g == null || !g.hasExact) return null;
      if (doTouch) g.touchExact();
      return g.exact;
    }
    return null;
  }

  /// Zero-allocation 3-component point lookup.
  ///
  /// - gd=1: `[groupKey, deep1, deep2]` (table page)
  /// - gd=2: `[k0, k1, flatKey]` (unique index / pq node)
  /// - gd=3: exact group `[k0, k1, k2]`
  @pragma('vm:prefer-inline')
  T? getPoint3(Object? k0, Object? k1, Object? k2,
      {bool touch = true, bool? updateStats}) {
    final gd = groupDepth;
    final doTouch = _reorderOnTouch && (updateStats ?? touch);
    if (gd == 1) {
      final g = _groupOfDepth1(k0);
      if (g == null) return null;
      final v = g.getDeep2(k1, k2);
      if (v != null && doTouch) g.touchDeep2(k1, k2);
      return v;
    }
    if (gd == 2) {
      final g = _groupOfDepth2(k0, k1);
      if (g == null) return null;
      return g.getFlat(k2, touch: doTouch);
    }
    if (gd == 3) {
      final g = _groupOfDepth3(k0, k1, k2);
      if (g == null || !g.hasExact) return null;
      if (doTouch) g.touchExact();
      return g.exact;
    }
    return null;
  }

  /// Zero-allocation 4-component point lookup.
  ///
  /// - gd=2: `[k0, k1, deep1, deep2]` (index page / non-unique index)
  /// - gd=3: `[k0, k1, k2, flatKey]` (txn unique index / PK slot)
  @pragma('vm:prefer-inline')
  T? getPoint4(Object? k0, Object? k1, Object? k2, Object? k3,
      {bool touch = true, bool? updateStats}) {
    final gd = groupDepth;
    final doTouch = _reorderOnTouch && (updateStats ?? touch);
    if (gd == 2) {
      final g = _groupOfDepth2(k0, k1);
      if (g == null) return null;
      final v = g.getDeep2(k2, k3);
      if (v != null && doTouch) g.touchDeep2(k2, k3);
      return v;
    }
    if (gd == 3) {
      final g = _groupOfDepth3(k0, k1, k2);
      if (g == null) return null;
      return g.getFlat(k3, touch: doTouch);
    }
    return null;
  }

  /// Zero-allocation 5-component point lookup (gd=3 deep2: txn index).
  @pragma('vm:prefer-inline')
  T? getPoint5(
    Object? k0,
    Object? k1,
    Object? k2,
    Object? k3,
    Object? k4, {
    bool touch = true,
    bool? updateStats,
  }) {
    if (groupDepth != 3) return null;
    final g = _groupOfDepth3(k0, k1, k2);
    if (g == null) return null;
    final doTouch = _reorderOnTouch && (updateStats ?? touch);
    final v = g.getDeep2(k3, k4);
    if (v != null && doTouch) g.touchDeep2(k3, k4);
    return v;
  }

  @pragma('vm:prefer-inline')
  T? peekPoint2(Object? k0, Object? k1) => getPoint2(k0, k1, touch: false);

  @pragma('vm:prefer-inline')
  T? peekPoint3(Object? k0, Object? k1, Object? k2) =>
      getPoint3(k0, k1, k2, touch: false);

  @pragma('vm:prefer-inline')
  T? peekPoint4(Object? k0, Object? k1, Object? k2, Object? k3) =>
      getPoint4(k0, k1, k2, k3, touch: false);

  @pragma('vm:prefer-inline')
  T? peekPoint5(
    Object? k0,
    Object? k1,
    Object? k2,
    Object? k3,
    Object? k4,
  ) =>
      getPoint5(k0, k1, k2, k3, k4, touch: false);

  @pragma('vm:prefer-inline')
  bool containsPoint2(Object? k0, Object? k1) {
    final gd = groupDepth;
    if (gd == 1) {
      final g = _groupOfDepth1(k0);
      if (g == null) return false;
      return g.containsFlat(k1);
    }
    if (gd == 2) {
      final g = _groupOfDepth2(k0, k1);
      return g != null && g.hasExact;
    }
    return false;
  }

  @pragma('vm:prefer-inline')
  bool containsPoint3(Object? k0, Object? k1, Object? k2) {
    final gd = groupDepth;
    if (gd == 1) {
      final g = _groupOfDepth1(k0);
      if (g == null) return false;
      return g.containsDeep2(k1, k2);
    }
    if (gd == 2) {
      final g = _groupOfDepth2(k0, k1);
      if (g == null) return false;
      return g.containsFlat(k2);
    }
    if (gd == 3) {
      final g = _groupOfDepth3(k0, k1, k2);
      return g != null && g.hasExact;
    }
    return false;
  }

  @pragma('vm:prefer-inline')
  bool containsPoint4(Object? k0, Object? k1, Object? k2, Object? k3) {
    final gd = groupDepth;
    if (gd == 2) {
      final g = _groupOfDepth2(k0, k1);
      if (g == null) return false;
      return g.containsDeep2(k2, k3);
    }
    if (gd == 3) {
      final g = _groupOfDepth3(k0, k1, k2);
      if (g == null) return false;
      return g.containsFlat(k3);
    }
    return false;
  }

  @pragma('vm:prefer-inline')
  bool containsPoint5(
    Object? k0,
    Object? k1,
    Object? k2,
    Object? k3,
    Object? k4,
  ) {
    if (groupDepth != 3) return false;
    final g = _groupOfDepth3(k0, k1, k2);
    if (g == null) return false;
    return g.containsDeep2(k3, k4);
  }

  @pragma('vm:prefer-inline')
  void putPoint2(Object? k0, Object? k1, T value, {int? size}) {
    final gd = groupDepth;
    if (gd == 1) {
      if (!_orderEnabled) {
        final g = _groupOfDepth1Create(k0);
        if (g.putFlatNone(k1, value)) _totalEntries++;
        return;
      }
      final sz = _resolveSize(size, value);
      final g = _groupOfDepth1Create(k0);
      final beforeBytes = g.totalBytes;
      final isNew = g.putFlat(k1, value, sizeBytes: sz);
      if (isNew) _totalEntries++;
      _applyGroupByteDelta(g, beforeBytes);
      _maybeScheduleCleanup();
      return;
    }
    if (gd == 2) {
      final key = <dynamic>[k0, k1];
      if (!_orderEnabled) {
        final g = _groupOfDepth2Create(k0, k1);
        if (g.putExactNone(value)) _totalEntries++;
        return;
      }
      final sz = _resolveSize(size, value);
      final group = _groupOfDepth2Create(k0, k1);
      final beforeBytes = group.totalBytes;
      final isNew = group.putExact(value, key: key, sizeBytes: sz);
      if (isNew) _totalEntries++;
      _applyGroupByteDelta(group, beforeBytes);
      _maybeScheduleCleanup();
    }
  }

  @pragma('vm:prefer-inline')
  void putPoint3(Object? k0, Object? k1, Object? k2, T value, {int? size}) {
    final gd = groupDepth;
    if (gd == 1) {
      if (!_orderEnabled) {
        final g = _groupOfDepth1Create(k0);
        if (g.putDeep2None(k1, k2, value)) _totalEntries++;
        return;
      }
      final sz = _resolveSize(size, value);
      final g = _groupOfDepth1Create(k0);
      final beforeBytes = g.totalBytes;
      final isNew = g.putDeep2(k1, k2, value, sizeBytes: sz);
      if (isNew) _totalEntries++;
      _applyGroupByteDelta(g, beforeBytes);
      _maybeScheduleCleanup();
      return;
    }
    if (gd == 2) {
      if (!_orderEnabled) {
        final g = _groupOfDepth2Create(k0, k1);
        if (g.putFlatNone(k2, value)) _totalEntries++;
        return;
      }
      final sz = _resolveSize(size, value);
      final g = _groupOfDepth2Create(k0, k1);
      final beforeBytes = g.totalBytes;
      final isNew = g.putFlat(k2, value, sizeBytes: sz);
      if (isNew) _totalEntries++;
      _applyGroupByteDelta(g, beforeBytes);
      _maybeScheduleCleanup();
      return;
    }
    if (gd == 3) {
      final key = <dynamic>[k0, k1, k2];
      if (!_orderEnabled) {
        final g = _groupOfDepth3Create(k0, k1, k2);
        if (g.putExactNone(value)) _totalEntries++;
        return;
      }
      final sz = _resolveSize(size, value);
      final group = _groupOfDepth3Create(k0, k1, k2);
      final beforeBytes = group.totalBytes;
      final isNew = group.putExact(value, key: key, sizeBytes: sz);
      if (isNew) _totalEntries++;
      _applyGroupByteDelta(group, beforeBytes);
      _maybeScheduleCleanup();
    }
  }

  @pragma('vm:prefer-inline')
  void putPoint4(
    Object? k0,
    Object? k1,
    Object? k2,
    Object? k3,
    T value, {
    int? size,
  }) {
    final gd = groupDepth;
    if (gd == 2) {
      if (!_orderEnabled) {
        final g = _groupOfDepth2Create(k0, k1);
        if (g.putDeep2None(k2, k3, value)) _totalEntries++;
        return;
      }
      final sz = _resolveSize(size, value);
      final g = _groupOfDepth2Create(k0, k1);
      final beforeBytes = g.totalBytes;
      final isNew = g.putDeep2(k2, k3, value, sizeBytes: sz);
      if (isNew) _totalEntries++;
      _applyGroupByteDelta(g, beforeBytes);
      _maybeScheduleCleanup();
      return;
    }
    if (gd == 3) {
      if (!_orderEnabled) {
        final g = _groupOfDepth3Create(k0, k1, k2);
        if (g.putFlatNone(k3, value)) _totalEntries++;
        return;
      }
      final sz = _resolveSize(size, value);
      final g = _groupOfDepth3Create(k0, k1, k2);
      final beforeBytes = g.totalBytes;
      final isNew = g.putFlat(k3, value, sizeBytes: sz);
      if (isNew) _totalEntries++;
      _applyGroupByteDelta(g, beforeBytes);
      _maybeScheduleCleanup();
    }
  }

  @pragma('vm:prefer-inline')
  void putPoint5(
    Object? k0,
    Object? k1,
    Object? k2,
    Object? k3,
    Object? k4,
    T value, {
    int? size,
  }) {
    if (groupDepth != 3) return;
    if (!_orderEnabled) {
      final g = _groupOfDepth3Create(k0, k1, k2);
      if (g.putDeep2None(k3, k4, value)) _totalEntries++;
      return;
    }
    final sz = _resolveSize(size, value);
    final g = _groupOfDepth3Create(k0, k1, k2);
    final beforeBytes = g.totalBytes;
    final isNew = g.putDeep2(k3, k4, value, sizeBytes: sz);
    if (isNew) _totalEntries++;
    _applyGroupByteDelta(g, beforeBytes);
    _maybeScheduleCleanup();
  }

  T? putIfAbsentPoint2(Object? k0, Object? k1, T value, {int? size}) {
    if (containsPoint2(k0, k1)) return peekPoint2(k0, k1);
    putPoint2(k0, k1, value, size: size);
    return null;
  }

  T? putIfAbsentPoint3(
    Object? k0,
    Object? k1,
    Object? k2,
    T value, {
    int? size,
  }) {
    if (containsPoint3(k0, k1, k2)) return peekPoint3(k0, k1, k2);
    putPoint3(k0, k1, k2, value, size: size);
    return null;
  }

  T? putIfAbsentPoint4(
    Object? k0,
    Object? k1,
    Object? k2,
    Object? k3,
    T value, {
    int? size,
  }) {
    if (containsPoint4(k0, k1, k2, k3)) return peekPoint4(k0, k1, k2, k3);
    putPoint4(k0, k1, k2, k3, value, size: size);
    return null;
  }

  @pragma('vm:prefer-inline')
  void removePoint2(Object? k0, Object? k1) {
    final gd = groupDepth;
    if (gd == 1) {
      if (!_orderEnabled) {
        final g = _groupOfDepth1(k0);
        if (g == null || !g.removeFlatNone(k1)) return;
        _afterPointRemoved(g);
        return;
      }
      final g = _groupOfDepth1(k0);
      if (g == null) return;
      final beforeBytes = g.totalBytes;
      if (!g.removeFlat(k1)) return;
      _afterPointRemoved(g, beforeBytes: beforeBytes);
      return;
    }
    if (gd == 2) {
      final key = <dynamic>[k0, k1];
      final group = _getGroupForKey(key, create: false);
      if (group == null) return;
      if (!_orderEnabled) {
        if (group.removeExactNone()) {
          _afterPointRemoved(group);
        }
        return;
      }
      final beforeBytes = group.totalBytes;
      if (group.removeExact()) {
        _afterPointRemoved(group, beforeBytes: beforeBytes);
      }
    }
  }

  @pragma('vm:prefer-inline')
  void removePoint3(Object? k0, Object? k1, Object? k2) {
    final gd = groupDepth;
    if (gd == 1) {
      if (!_orderEnabled) {
        final g = _groupOfDepth1(k0);
        if (g == null || !g.removeDeep2None(k1, k2)) return;
        _afterPointRemoved(g);
        return;
      }
      final g = _groupOfDepth1(k0);
      if (g == null) return;
      final beforeBytes = g.totalBytes;
      if (!g.removeDeep2(k1, k2)) return;
      _afterPointRemoved(g, beforeBytes: beforeBytes);
      return;
    }
    if (gd == 2) {
      if (!_orderEnabled) {
        final g = _groupOfDepth2(k0, k1);
        if (g == null || !g.removeFlatNone(k2)) return;
        _afterPointRemoved(g);
        return;
      }
      final g = _groupOfDepth2(k0, k1);
      if (g == null) return;
      final beforeBytes = g.totalBytes;
      if (!g.removeFlat(k2)) return;
      _afterPointRemoved(g, beforeBytes: beforeBytes);
      return;
    }
    if (gd == 3) {
      final key = <dynamic>[k0, k1, k2];
      final group = _getGroupForKey(key, create: false);
      if (group == null) return;
      if (!_orderEnabled) {
        if (group.removeExactNone()) {
          _afterPointRemoved(group);
        }
        return;
      }
      final beforeBytes = group.totalBytes;
      if (group.removeExact()) {
        _afterPointRemoved(group, beforeBytes: beforeBytes);
      }
    }
  }

  @pragma('vm:prefer-inline')
  void removePoint4(Object? k0, Object? k1, Object? k2, Object? k3) {
    final gd = groupDepth;
    if (gd == 2) {
      if (!_orderEnabled) {
        final g = _groupOfDepth2(k0, k1);
        if (g == null || !g.removeDeep2None(k2, k3)) return;
        _afterPointRemoved(g);
        return;
      }
      final g = _groupOfDepth2(k0, k1);
      if (g == null) return;
      final beforeBytes = g.totalBytes;
      if (!g.removeDeep2(k2, k3)) return;
      _afterPointRemoved(g, beforeBytes: beforeBytes);
      return;
    }
    if (gd == 3) {
      if (!_orderEnabled) {
        final g = _groupOfDepth3(k0, k1, k2);
        if (g == null || !g.removeFlatNone(k3)) return;
        _afterPointRemoved(g);
        return;
      }
      final g = _groupOfDepth3(k0, k1, k2);
      if (g == null) return;
      final beforeBytes = g.totalBytes;
      if (!g.removeFlat(k3)) return;
      _afterPointRemoved(g, beforeBytes: beforeBytes);
    }
  }

  @pragma('vm:prefer-inline')
  void removePoint5(
    Object? k0,
    Object? k1,
    Object? k2,
    Object? k3,
    Object? k4,
  ) {
    if (groupDepth != 3) return;
    if (!_orderEnabled) {
      final g = _groupOfDepth3(k0, k1, k2);
      if (g == null || !g.removeDeep2None(k3, k4)) return;
      _afterPointRemoved(g);
      return;
    }
    final g = _groupOfDepth3(k0, k1, k2);
    if (g == null) return;
    final beforeBytes = g.totalBytes;
    if (!g.removeDeep2(k3, k4)) return;
    _afterPointRemoved(g, beforeBytes: beforeBytes);
  }

  /// Point lookup. [touch]/[updateStats] only matter when [evictionMode] is [lru].
  @pragma('vm:prefer-inline')
  T? get(dynamic key, {bool touch = true, bool? updateStats}) {
    final k = _keyList(key);
    final gd = groupDepth;
    final len = k.length;
    final doTouch = _reorderOnTouch && (updateStats ?? touch);

    // Meta / schema: scalar or [groupKey] -> exact slot
    if (len == gd) {
      if (gd == 1) {
        final g = _groupOfDepth1(k[0]);
        if (g == null || !g.hasExact) return null;
        if (doTouch) g.touchExact();
        return g.exact;
      }
      if (gd == 2) {
        final g = _groupOfDepth2(k[0], k[1]);
        if (g == null || !g.hasExact) return null;
        if (doTouch) g.touchExact();
        return g.exact;
      }
      if (gd == 3) {
        final g = _groupOfDepth3(k[0], k[1], k[2]);
        if (g == null || !g.hasExact) return null;
        if (doTouch) g.touchExact();
        return g.exact;
      }
    }

    // pendingRecord / tableRecord: [tableUid, pk]
    if (gd == 1 && len == 2) {
      final g = _groupOfDepth1(k[0]);
      if (g == null) return null;
      return g.getFlat(k[1], touch: doTouch);
    }
    // table page: [tableUid, partitionNo, pageNo]
    if (gd == 1 && len == 3) {
      final g = _groupOfDepth1(k[0]);
      if (g == null) return null;
      final v = g.getDeep2(k[1], k[2]);
      if (v != null && doTouch) g.touchDeep2(k[1], k[2]);
      return v;
    }
    // txnRecord: [txId, tableUid, pk]
    if (gd == 2 && len == 3) {
      final g = _groupOfDepth2(k[0], k[1]);
      if (g == null) return null;
      return g.getFlat(k[2], touch: doTouch);
    }
    // pendingIndex / index page: [tableUid, indexUid, ...]
    if (gd == 2 && len == 4) {
      final g = _groupOfDepth2(k[0], k[1]);
      if (g == null) return null;
      final v = g.getDeep2(k[2], k[3]);
      if (v != null && doTouch) g.touchDeep2(k[2], k[3]);
      return v;
    }
    // txn flat after depth-3 group (rare) / txnIndex deep
    if (gd == 3 && len == 4) {
      final g = _groupOfDepth3(k[0], k[1], k[2]);
      if (g == null) return null;
      return g.getFlat(k[3], touch: doTouch);
    }
    // txnIndex: [txId, tableUid, indexUid, field, pk]
    if (gd == 3 && len == 5) {
      final g = _groupOfDepth3(k[0], k[1], k[2]);
      if (g == null) return null;
      final v = g.getDeep2(k[3], k[4]);
      if (v != null && doTouch) g.touchDeep2(k[3], k[4]);
      return v;
    }

    final group = _getGroupForKey(k, create: false);
    if (group == null) return null;
    final v = group.pointGet(k);
    if (v != null && doTouch) group.touchPath(k);
    return v;
  }

  @pragma('vm:prefer-inline')
  bool containsKey(dynamic key) {
    final k = _keyList(key);
    final gd = groupDepth;
    final len = k.length;

    if (len == gd) {
      if (gd == 1) {
        final g = _groupOfDepth1(k[0]);
        return g != null && g.hasExact;
      }
      if (gd == 2) {
        final g = _groupOfDepth2(k[0], k[1]);
        return g != null && g.hasExact;
      }
      if (gd == 3) {
        final g = _groupOfDepth3(k[0], k[1], k[2]);
        return g != null && g.hasExact;
      }
    }
    if (gd == 1 && len == 2) {
      final g = _groupOfDepth1(k[0]);
      if (g == null) return false;
      return g.containsFlat(k[1]);
    }
    if (gd == 1 && len == 3) {
      final g = _groupOfDepth1(k[0]);
      if (g == null) return false;
      return g.containsDeep2(k[1], k[2]);
    }
    if (gd == 2 && len == 3) {
      final g = _groupOfDepth2(k[0], k[1]);
      if (g == null) return false;
      return g.containsFlat(k[2]);
    }
    if (gd == 2 && len == 4) {
      final g = _groupOfDepth2(k[0], k[1]);
      if (g == null) return false;
      return g.containsDeep2(k[2], k[3]);
    }
    if (gd == 3 && len == 4) {
      final g = _groupOfDepth3(k[0], k[1], k[2]);
      if (g == null) return false;
      return g.containsFlat(k[3]);
    }
    if (gd == 3 && len == 5) {
      final g = _groupOfDepth3(k[0], k[1], k[2]);
      if (g == null) return false;
      return g.containsDeep2(k[3], k[4]);
    }

    final group = _getGroupForKey(k, create: false);
    if (group == null) return false;
    return group.pointContains(k);
  }

  @pragma('vm:prefer-inline')
  void put(dynamic key, T value, {int? size}) {
    final k = _keyList(key);
    final gd = groupDepth;
    final len = k.length;

    if (!_orderEnabled) {
      // none: Map-speed -- no size/order/bytes.
      if (len == gd) {
        if (gd == 1) {
          final g = _groupOfDepth1Create(k[0]);
          if (g.putExactNone(value)) _totalEntries++;
          return;
        }
        if (gd == 2) {
          final g = _groupOfDepth2Create(k[0], k[1]);
          if (g.putExactNone(value)) _totalEntries++;
          return;
        }
        if (gd == 3) {
          final g = _groupOfDepth3Create(k[0], k[1], k[2]);
          if (g.putExactNone(value)) _totalEntries++;
          return;
        }
      }
      if (gd == 1 && len == 2) {
        final g = _groupOfDepth1Create(k[0]);
        if (g.putFlatNone(k[1], value)) _totalEntries++;
        return;
      }
      if (gd == 1 && len == 3) {
        final g = _groupOfDepth1Create(k[0]);
        if (g.putDeep2None(k[1], k[2], value)) _totalEntries++;
        return;
      }
      if (gd == 2 && len == 3) {
        final g = _groupOfDepth2Create(k[0], k[1]);
        if (g.putFlatNone(k[2], value)) _totalEntries++;
        return;
      }
      if (gd == 2 && len == 4) {
        final g = _groupOfDepth2Create(k[0], k[1]);
        if (g.putDeep2None(k[2], k[3], value)) _totalEntries++;
        return;
      }
      if (gd == 3 && len == 4) {
        final g = _groupOfDepth3Create(k[0], k[1], k[2]);
        if (g.putFlatNone(k[3], value)) _totalEntries++;
        return;
      }
      if (gd == 3 && len == 5) {
        final g = _groupOfDepth3Create(k[0], k[1], k[2]);
        if (g.putDeep2None(k[3], k[4], value)) _totalEntries++;
        return;
      }
      final group = _getGroupForKey(k, create: true)!;
      final before = group.entryCount;
      group.pointPut(k, value);
      if (group.entryCount > before) _totalEntries++;
      return;
    }

    final sz = _resolveSize(size, value);
    if (len == gd) {
      final group = _getGroupForKey(k, create: true)!;
      final beforeBytes = group.totalBytes;
      final isNew = group.putExact(value, key: k, sizeBytes: sz);
      if (isNew) _totalEntries++;
      _applyGroupByteDelta(group, beforeBytes);
      _maybeScheduleCleanup();
      return;
    }
    if (gd == 1 && len == 2) {
      final g = _groupOfDepth1Create(k[0]);
      final beforeBytes = g.totalBytes;
      final isNew = g.putFlat(k[1], value, sizeBytes: sz);
      if (isNew) _totalEntries++;
      _applyGroupByteDelta(g, beforeBytes);
      _maybeScheduleCleanup();
      return;
    }
    if (gd == 1 && len == 3) {
      final g = _groupOfDepth1Create(k[0]);
      final beforeBytes = g.totalBytes;
      final isNew = g.putDeep2(k[1], k[2], value, sizeBytes: sz);
      if (isNew) _totalEntries++;
      _applyGroupByteDelta(g, beforeBytes);
      _maybeScheduleCleanup();
      return;
    }
    if (gd == 2 && len == 3) {
      final g = _groupOfDepth2Create(k[0], k[1]);
      final beforeBytes = g.totalBytes;
      final isNew = g.putFlat(k[2], value, sizeBytes: sz);
      if (isNew) _totalEntries++;
      _applyGroupByteDelta(g, beforeBytes);
      _maybeScheduleCleanup();
      return;
    }
    if (gd == 2 && len == 4) {
      final g = _groupOfDepth2Create(k[0], k[1]);
      final beforeBytes = g.totalBytes;
      final isNew = g.putDeep2(k[2], k[3], value, sizeBytes: sz);
      if (isNew) _totalEntries++;
      _applyGroupByteDelta(g, beforeBytes);
      _maybeScheduleCleanup();
      return;
    }
    if (gd == 3 && len == 4) {
      final g = _groupOfDepth3Create(k[0], k[1], k[2]);
      final beforeBytes = g.totalBytes;
      final isNew = g.putFlat(k[3], value, sizeBytes: sz);
      if (isNew) _totalEntries++;
      _applyGroupByteDelta(g, beforeBytes);
      _maybeScheduleCleanup();
      return;
    }
    if (gd == 3 && len == 5) {
      final g = _groupOfDepth3Create(k[0], k[1], k[2]);
      final beforeBytes = g.totalBytes;
      final isNew = g.putDeep2(k[3], k[4], value, sizeBytes: sz);
      if (isNew) _totalEntries++;
      _applyGroupByteDelta(g, beforeBytes);
      _maybeScheduleCleanup();
      return;
    }

    final group = _getGroupForKey(k, create: true)!;
    final beforeBytes = group.totalBytes;
    final before = group.entryCount;
    group.pointPut(k, value, sizeBytes: sz);
    if (group.entryCount > before) _totalEntries++;
    _applyGroupByteDelta(group, beforeBytes);
    _maybeScheduleCleanup();
  }

  /// Insert only when absent. Returns existing value, or `null` if inserted.
  T? putIfAbsent(dynamic key, T value, {int? size}) {
    // containsKey distinguishes stored nulls from missing keys.
    if (containsKey(key)) return peek(key);
    put(key, value, size: size);
    return null;
  }

  void _maybeScheduleCleanup() {
    if (!_orderEnabled) return;
    if (_maxByteThreshold <= 0) return;
    if (_estimatedTotalSizeBytes <= _maxByteThreshold) return;
    if (_cleanupLock != null) return;
    final now = DateTime.now();
    if (now.difference(_lastCleanupTime).inSeconds < 5) return;
    // ignore: discarded_futures
    cleanup();
  }

  @pragma('vm:prefer-inline')
  void remove(dynamic keyOrPrefix) {
    final k = _keyList(keyOrPrefix);
    final gd = groupDepth;
    final len = k.length;

    if (len > gd) {
      if (!_orderEnabled) {
        // none: no byte ledger.
        if (gd == 1 && len == 2) {
          final g = _groupOfDepth1(k[0]);
          if (g == null || !g.removeFlatNone(k[1])) return;
          _afterPointRemoved(g);
          return;
        }
        if (gd == 1 && len == 3) {
          final g = _groupOfDepth1(k[0]);
          if (g == null || !g.removeDeep2None(k[1], k[2])) return;
          _afterPointRemoved(g);
          return;
        }
        if (gd == 2 && len == 3) {
          final g = _groupOfDepth2(k[0], k[1]);
          if (g == null || !g.removeFlatNone(k[2])) return;
          _afterPointRemoved(g);
          return;
        }
        if (gd == 2 && len == 4) {
          final g = _groupOfDepth2(k[0], k[1]);
          if (g == null || !g.removeDeep2None(k[2], k[3])) return;
          _afterPointRemoved(g);
          return;
        }
        if (gd == 3 && len == 4) {
          final g = _groupOfDepth3(k[0], k[1], k[2]);
          if (g == null || !g.removeFlatNone(k[3])) return;
          _afterPointRemoved(g);
          return;
        }
        if (gd == 3 && len == 5) {
          final g = _groupOfDepth3(k[0], k[1], k[2]);
          if (g == null || !g.removeDeep2None(k[3], k[4])) return;
          _afterPointRemoved(g);
          return;
        }
        final group = _getGroupForKey(k, create: false);
        if (group != null && group.pointRemove(k)) {
          _afterPointRemoved(group);
        }
        return;
      }

      if (gd == 1 && len == 2) {
        final g = _groupOfDepth1(k[0]);
        if (g == null) return;
        final beforeBytes = g.totalBytes;
        if (!g.removeFlat(k[1])) return;
        _afterPointRemoved(g, beforeBytes: beforeBytes);
        return;
      }
      if (gd == 1 && len == 3) {
        final g = _groupOfDepth1(k[0]);
        if (g == null) return;
        final beforeBytes = g.totalBytes;
        if (!g.removeDeep2(k[1], k[2])) return;
        _afterPointRemoved(g, beforeBytes: beforeBytes);
        return;
      }
      if (gd == 2 && len == 3) {
        final g = _groupOfDepth2(k[0], k[1]);
        if (g == null) return;
        final beforeBytes = g.totalBytes;
        if (!g.removeFlat(k[2])) return;
        _afterPointRemoved(g, beforeBytes: beforeBytes);
        return;
      }
      if (gd == 2 && len == 4) {
        final g = _groupOfDepth2(k[0], k[1]);
        if (g == null) return;
        final beforeBytes = g.totalBytes;
        if (!g.removeDeep2(k[2], k[3])) return;
        _afterPointRemoved(g, beforeBytes: beforeBytes);
        return;
      }
      if (gd == 3 && len == 4) {
        final g = _groupOfDepth3(k[0], k[1], k[2]);
        if (g == null) return;
        final beforeBytes = g.totalBytes;
        if (!g.removeFlat(k[3])) return;
        _afterPointRemoved(g, beforeBytes: beforeBytes);
        return;
      }
      if (gd == 3 && len == 5) {
        final g = _groupOfDepth3(k[0], k[1], k[2]);
        if (g == null) return;
        final beforeBytes = g.totalBytes;
        if (!g.removeDeep2(k[3], k[4])) return;
        _afterPointRemoved(g, beforeBytes: beforeBytes);
        return;
      }

      final group = _getGroupForKey(k, create: false);
      if (group != null) {
        final beforeBytes = group.totalBytes;
        if (group.pointRemove(k)) {
          _afterPointRemoved(group, beforeBytes: beforeBytes);
        }
      }
      return;
    }

    if (k.isEmpty) {
      clear();
      return;
    }

    // Exact entry first (meta caches), else prefix group remove.
    if (len == gd) {
      final group = _getGroupForKey(k, create: false);
      if (group != null) {
        if (!_orderEnabled) {
          if (group.removeExactNone()) {
            _afterPointRemoved(group);
            return;
          }
        } else {
          final beforeBytes = group.totalBytes;
          if (group.removeExact()) {
            _afterPointRemoved(group, beforeBytes: beforeBytes);
            return;
          }
        }
      }
    }

    if (len <= gd) {
      final removed = _removeGroupsByPrefix(k);
      _totalEntries -= removed;
      if (_totalEntries < 0) _totalEntries = 0;
      _removeFullyCachedPrefix(k);
    }
  }

  /// Batch insert/update. Uses [put] so hot-path specializations stay shared.
  void putAll(
    Map<dynamic, T> entries, {
    Map<dynamic, int>? sizes,
  }) {
    if (entries.isEmpty) return;
    for (final e in entries.entries) {
      final rawKey = e.key;
      put(rawKey, e.value, size: sizes?[rawKey]);
    }
  }

  /// Rename group prefix from [oldGroupKey] to [newGroupKey] in O(1) group move.
  /// Only supported when [groupDepth] == 1.
  void renameGroup(dynamic oldGroupKey, dynamic newGroupKey) {
    if (oldGroupKey == newGroupKey) return;
    if (groupDepth != 1) return;

    final group = _groupsRoot.remove(oldGroupKey);
    if (group == null) return;
    if (group is! _Group<T>) {
      _groupsRoot[oldGroupKey] = group;
      return;
    }

    group.groupPath[0] = newGroupKey;
    group.rewriteGroupKeyInOrderNodes(newGroupKey);
    _groupsRoot[newGroupKey] = group;
    if (_f0 == oldGroupKey) {
      _f0 = newGroupKey;
    }

    final isMarked = _isFullyCached(<dynamic>[oldGroupKey]);
    if (isMarked) {
      _setFullyCached(<dynamic>[oldGroupKey], false);
      _setFullyCached(<dynamic>[newGroupKey], true);
    }
  }

  void clear() {
    _groupsRoot.clear();
    _fullyCachedRoot.clear();
    _totalEntries = 0;
    _estimatedTotalSizeBytes = 0;
    _clearFinger();
  }

  /// Inclusive range scan (async + yielding).
  ///
  /// Short prefixes fan out across matching groups.
  Future<void> scanRange(
    dynamic startKey,
    dynamic endKey, {
    bool reverse = false,
    int? limit,
    required bool Function(List<dynamic> path, T value) onEntry,
  }) async {
    final start = _normalizeKey(startKey);
    final end = endKey == null ? null : _normalizeKey(endKey);

    final groups = <_Group<T>>[];
    if (start.length >= groupDepth) {
      final g = _getGroupForKey(start, create: false);
      if (g != null) groups.add(g);
    } else {
      _collectGroupsUnderPrefix(start, out: groups);
    }
    if (groups.isEmpty) return;

    for (final g in groups) {
      g.pinCount++;
    }

    try {
      var remaining = limit;
      var stop = false;
      final int groupCount = groups.length;
      final yieldController =
          YieldController('TreeCache.scanRange:$debugLabel');
      var sinceYield = 0;

      for (int gi = 0; gi < groupCount; gi++) {
        final group = groups[reverse ? (groupCount - 1 - gi) : gi];
        if (stop || (remaining != null && remaining <= 0)) return;
        if (group.entryCount <= 0) continue;

        final List<dynamic> localStart =
            start.length >= groupDepth ? start : group.groupPath;
        final emitted = group.scanRange(
          localStart,
          end,
          reverse: reverse,
          limit: remaining,
          onEntry: (path, value) {
            final cont = onEntry(path, value);
            if (!cont) stop = true;
            return cont;
          },
        );
        sinceYield += emitted;
        if (remaining != null) remaining = remaining - emitted;
        if (stop) return;
        if (sinceYield >= 4096) {
          sinceYield = 0;
          final y = yieldController.maybeYield();
          if (y != null) await y;
        }
      }
    } finally {
      for (final g in groups) {
        g.pinCount--;
        if (g.pinCount <= 0 && g.entryCount <= 0) {
          _removeEmptyGroup(g.groupPath);
        }
      }
    }
  }

  /// Remove entries matching [test], yielding periodically.
  Future<int> removeWhere(
    bool Function(List<dynamic> key, T value) test, {
    String? yieldLabel,
  }) async {
    if (_totalEntries <= 0) return 0;

    final groups = <_Group<T>>[];
    _collectGroups(_groupsRoot, depth: 1, out: groups);
    if (groups.isEmpty) return 0;

    final yieldController = YieldController(
      yieldLabel ?? 'TreeCache.removeWhere:$debugLabel',
    );
    var removedTotal = 0;

    for (final g in groups) {
      if (g.entryCount <= 0) continue;

      final matches = <List<dynamic>>[];
      g.forEachEntry((path, value) {
        if (test(path, value)) matches.add(path);
      });
      if (matches.isEmpty) continue;

      for (final path in matches) {
        final y = yieldController.maybeYield();
        if (y != null) await y;

        final beforeBytes = g.totalBytes;
        if (!g.pointRemove(path)) continue;
        _afterPointRemoved(g, beforeBytes: _orderEnabled ? beforeBytes : null);
        removedTotal++;
      }
    }
    return removedTotal;
  }

  /// Force materialize ordered vectors for all groups.
  void ensureOrdered() {
    final groups = <_Group<T>>[];
    _collectGroups(_groupsRoot, depth: 1, out: groups);
    for (final g in groups) {
      if (g.entryCount > 0) g.ensureOrdered();
    }
  }

  /// Materialize ordered views for all groups (async + yield).
  ///
  /// Yields between large groups so UI threads stay responsive after bulk loads.
  Future<void> prepareOrderedViews() async {
    final groups = <_Group<T>>[];
    _collectGroups(_groupsRoot, depth: 1, out: groups);
    if (groups.isEmpty) return;
    final yieldController =
        YieldController('TreeCache.prepareOrderedViews:$debugLabel');
    for (final g in groups) {
      if (g.entryCount <= 0) continue;
      final y = yieldController.maybeYield();
      if (y != null) await y;
      g.ensureOrdered();
    }
  }

  /// Evict oldest entries until roughly [removeRatio] of entries are gone
  /// (or order lists empty). No-op when [evictionMode] is [none].
  Future<void> cleanup({double removeRatio = 0.3}) async {
    if (!_orderEnabled) return;
    if (removeRatio <= 0) return;
    if (removeRatio > 1) removeRatio = 1;
    if (_estimatedTotalSizeBytes <= _minByteThreshold) return;

    if (_cleanupLock != null) {
      await _cleanupLock;
      return;
    }
    final completer = Completer<void>();
    _cleanupLock = completer.future;

    try {
      if (beforeCleanup != null) {
        try {
          final proceed = await beforeCleanup!();
          if (!proceed) {
            _lastCleanupTime = DateTime.now();
            return;
          }
        } catch (_) {}
        if (_estimatedTotalSizeBytes <= _minByteThreshold) return;
        if (_estimatedTotalSizeBytes <= _maxByteThreshold) return;
      }
      if (_totalEntries <= 0) return;

      final targetRemove = math.max(1, (_totalEntries * removeRatio).ceil());
      var removedTotal = 0;

      final groups = <_Group<T>>[];
      _collectGroups(_groupsRoot, depth: 1, out: groups);
      if (groups.isEmpty) return;

      final yieldController = YieldController('TreeCache.cleanup:$debugLabel');

      for (final g in groups) {
        final y1 = yieldController.maybeYield();
        if (y1 != null) await y1;
        if (weightQueryCallback == null) {
          g.cachedWeight = 0;
        } else {
          try {
            g.cachedWeight = await weightQueryCallback!(g.groupPath) ?? 0;
          } catch (_) {
            g.cachedWeight = 0;
          }
        }
      }

      groups.sort((a, b) {
        final c = (a.cachedWeight ?? 0).compareTo(b.cachedWeight ?? 0);
        if (c != 0) return c;
        return b.entryCount.compareTo(a.entryCount);
      });

      for (final g in groups) {
        if (removedTotal >= targetRemove) break;
        if (g.entryCount <= 0) continue;
        var need = math.min(
          math.max(1, (g.entryCount * removeRatio).ceil()),
          targetRemove - removedTotal,
        );
        var removedInGroup = 0;
        while (need > 0 && g.orderHead != null) {
          final y2 = yieldController.maybeYield();
          if (y2 != null) await y2;

          final beforeBytes = g.totalBytes;
          final ok = g.evictOrderHead();
          if (!ok) continue;
          _afterPointRemoved(g, beforeBytes: beforeBytes);
          need--;
          removedTotal++;
          removedInGroup++;
        }
        if (removedInGroup > 0) {
          _setFullyCached(g.groupPath, false);
        }
      }

      if (removedTotal > 0) {
        try {
          onEvicted?.call(removedTotal);
        } catch (_) {}
      }
      _lastCleanupTime = DateTime.now();
    } finally {
      if (identical(_cleanupLock, completer.future)) {
        _cleanupLock = null;
      }
      completer.complete();
    }
  }

  _Group<T> _newGroup(List<dynamic> groupPath) {
    return _Group<T>(
      groupPath: groupPath,
      groupDepth: groupDepth,
      compare: compare,
      comparatorFactory: comparatorFactory,
      orderEnabled: _orderEnabled,
      reorderOnTouch: _reorderOnTouch,
    );
  }

  // ---------------------------------------------------------------------------
  // Group finger + create
  // ---------------------------------------------------------------------------

  @pragma('vm:prefer-inline')
  _Group<T>? _groupOfDepth1(Object? a) {
    if (_fingerDepth == 1 && a == _f0) return _fingerGroup;
    final g = _groupsRoot[a];
    final typed = g is _Group<T> ? g : null;
    _f0 = a;
    _fingerGroup = typed;
    _fingerDepth = 1;
    return typed;
  }

  @pragma('vm:prefer-inline')
  _Group<T> _groupOfDepth1Create(Object? a) {
    if (_fingerDepth == 1 && a == _f0 && _fingerGroup != null) {
      return _fingerGroup!;
    }
    final existing = _groupsRoot[a];
    if (existing is _Group<T>) {
      _f0 = a;
      _fingerGroup = existing;
      _fingerDepth = 1;
      return existing;
    }
    final created = _newGroup(<dynamic>[a]);
    _groupsRoot[a] = created;
    _f0 = a;
    _fingerGroup = created;
    _fingerDepth = 1;
    return created;
  }

  @pragma('vm:prefer-inline')
  _Group<T>? _groupOfDepth2(Object? a, Object? b) {
    if (_fingerDepth == 2 && a == _f0 && b == _f1) return _fingerGroup;
    final mid = _groupsRoot[a];
    if (mid is! Map<Object?, dynamic>) {
      _f0 = a;
      _f1 = b;
      _fingerGroup = null;
      _fingerDepth = 2;
      return null;
    }
    final g = mid[b];
    final typed = g is _Group<T> ? g : null;
    _f0 = a;
    _f1 = b;
    _fingerGroup = typed;
    _fingerDepth = 2;
    return typed;
  }

  @pragma('vm:prefer-inline')
  _Group<T> _groupOfDepth2Create(Object? a, Object? b) {
    if (_fingerDepth == 2 && a == _f0 && b == _f1 && _fingerGroup != null) {
      return _fingerGroup!;
    }
    var mid = _groupsRoot[a];
    if (mid is! Map<Object?, dynamic>) {
      mid = <Object?, dynamic>{};
      _groupsRoot[a] = mid;
    }
    final existing = mid[b];
    if (existing is _Group<T>) {
      _f0 = a;
      _f1 = b;
      _fingerGroup = existing;
      _fingerDepth = 2;
      return existing;
    }
    final created = _newGroup(<dynamic>[a, b]);
    mid[b] = created;
    _f0 = a;
    _f1 = b;
    _fingerGroup = created;
    _fingerDepth = 2;
    return created;
  }

  @pragma('vm:prefer-inline')
  _Group<T>? _groupOfDepth3(Object? a, Object? b, Object? c) {
    if (_fingerDepth == 3 && a == _f0 && b == _f1 && c == _f2) {
      return _fingerGroup;
    }
    final mid1 = _groupsRoot[a];
    if (mid1 is! Map<Object?, dynamic>) {
      _f0 = a;
      _f1 = b;
      _f2 = c;
      _fingerGroup = null;
      _fingerDepth = 3;
      return null;
    }
    final mid2 = mid1[b];
    if (mid2 is! Map<Object?, dynamic>) {
      _f0 = a;
      _f1 = b;
      _f2 = c;
      _fingerGroup = null;
      _fingerDepth = 3;
      return null;
    }
    final g = mid2[c];
    final typed = g is _Group<T> ? g : null;
    _f0 = a;
    _f1 = b;
    _f2 = c;
    _fingerGroup = typed;
    _fingerDepth = 3;
    return typed;
  }

  @pragma('vm:prefer-inline')
  _Group<T> _groupOfDepth3Create(Object? a, Object? b, Object? c) {
    if (_fingerDepth == 3 &&
        a == _f0 &&
        b == _f1 &&
        c == _f2 &&
        _fingerGroup != null) {
      return _fingerGroup!;
    }
    var mid1 = _groupsRoot[a];
    if (mid1 is! Map<Object?, dynamic>) {
      mid1 = <Object?, dynamic>{};
      _groupsRoot[a] = mid1;
    }
    var mid2 = mid1[b];
    if (mid2 is! Map<Object?, dynamic>) {
      mid2 = <Object?, dynamic>{};
      mid1[b] = mid2;
    }
    final existing = mid2[c];
    if (existing is _Group<T>) {
      _f0 = a;
      _f1 = b;
      _f2 = c;
      _fingerGroup = existing;
      _fingerDepth = 3;
      return existing;
    }
    final created = _newGroup(<dynamic>[a, b, c]);
    mid2[c] = created;
    _f0 = a;
    _f1 = b;
    _f2 = c;
    _fingerGroup = created;
    _fingerDepth = 3;
    return created;
  }

  // ---------------------------------------------------------------------------
  // Group map walk (fallback)
  // ---------------------------------------------------------------------------

  _Group<T>? _getGroupForKey(List<dynamic> key, {required bool create}) {
    if (key.length < groupDepth) return null;

    if (groupDepth == 1) {
      return create ? _groupOfDepth1Create(key[0]) : _groupOfDepth1(key[0]);
    }
    if (groupDepth == 2) {
      return create
          ? _groupOfDepth2Create(key[0], key[1])
          : _groupOfDepth2(key[0], key[1]);
    }
    if (groupDepth == 3) {
      return create
          ? _groupOfDepth3Create(key[0], key[1], key[2])
          : _groupOfDepth3(key[0], key[1], key[2]);
    }
    return null;
  }

  void _collectGroups(
    Map<Object?, dynamic> node, {
    required int depth,
    required List<_Group<T>> out,
  }) {
    if (depth == groupDepth) {
      for (final v in node.values) {
        if (v is _Group<T>) out.add(v);
      }
      return;
    }
    for (final v in node.values) {
      if (v is _Group<T>) {
        out.add(v);
      } else if (v is Map<Object?, dynamic>) {
        _collectGroups(v, depth: depth + 1, out: out);
      }
    }
  }

  void _collectGroupsUnderPrefix(
    List<dynamic> prefix, {
    required List<_Group<T>> out,
  }) {
    if (prefix.isEmpty) {
      _collectGroups(_groupsRoot, depth: 1, out: out);
      return;
    }
    Map<Object?, dynamic> node = _groupsRoot;
    for (int i = 0; i < prefix.length; i++) {
      final next = node[prefix[i]];
      if (next == null) return;
      if (next is _Group<T>) {
        out.add(next);
        return;
      }
      if (next is! Map<Object?, dynamic>) return;
      node = next;
    }
    _collectGroups(node, depth: prefix.length + 1, out: out);
  }

  int _removeGroupsByPrefix(List<dynamic> prefix) {
    if (prefix.isEmpty) {
      final groups = <_Group<T>>[];
      _collectGroups(_groupsRoot, depth: 1, out: groups);
      var n = 0;
      for (final g in groups) {
        n += g.entryCount;
      }
      _groupsRoot.clear();
      _clearFinger();
      return n;
    }

    if (prefix.length == 1 && groupDepth == 1) {
      final g = _groupsRoot.remove(prefix[0]);
      if (_f0 == prefix[0]) _clearFinger();
      if (g is _Group<T>) {
        if (_orderEnabled) {
          _estimatedTotalSizeBytes -= g.totalBytes;
          if (_estimatedTotalSizeBytes < 0) _estimatedTotalSizeBytes = 0;
        }
        return g.entryCount;
      }
      return 0;
    }

    // Walk to parent of last component.
    if (prefix.length > groupDepth) return 0;

    Map<Object?, dynamic> map = _groupsRoot;
    final stack = <Map<Object?, dynamic>>[];
    for (int i = 0; i < prefix.length - 1; i++) {
      stack.add(map);
      final next = map[prefix[i]];
      if (next is! Map<Object?, dynamic>) return 0;
      map = next;
    }
    final last = prefix.last;
    final removedNode = map.remove(last);
    var n = 0;
    if (removedNode is _Group<T>) {
      n = removedNode.entryCount;
      if (_orderEnabled) {
        _estimatedTotalSizeBytes -= removedNode.totalBytes;
        if (_estimatedTotalSizeBytes < 0) _estimatedTotalSizeBytes = 0;
      }
    } else if (removedNode is Map<Object?, dynamic>) {
      final groups = <_Group<T>>[];
      _collectGroups(removedNode, depth: prefix.length + 1, out: groups);
      for (final g in groups) {
        n += g.entryCount;
        if (_orderEnabled) {
          _estimatedTotalSizeBytes -= g.totalBytes;
        }
      }
      if (_orderEnabled && _estimatedTotalSizeBytes < 0) {
        _estimatedTotalSizeBytes = 0;
      }
    }
    // Prune empty parents.
    for (int i = stack.length - 1; i >= 0; i--) {
      final parent = stack[i];
      final key = prefix[i];
      final child = parent[key];
      if (child is Map<Object?, dynamic> && child.isEmpty) {
        parent.remove(key);
      } else {
        break;
      }
    }
    _clearFinger();
    return n;
  }

  void _removeEmptyGroup(List<dynamic> groupPath) {
    if (groupPath.isEmpty) return;
    if (groupDepth == 1) {
      final g = _groupsRoot[groupPath[0]];
      if (g is _Group<T> && g.pinCount > 0) return;
      _groupsRoot.remove(groupPath[0]);
      if (_f0 == groupPath[0]) _clearFinger();
      return;
    }
    Map<Object?, dynamic> map = _groupsRoot;
    final stack = <Map<Object?, dynamic>>[];
    for (int i = 0; i < groupPath.length - 1; i++) {
      stack.add(map);
      final next = map[groupPath[i]];
      if (next is! Map<Object?, dynamic>) return;
      map = next;
    }
    final leaf = map[groupPath.last];
    if (leaf is _Group<T> && leaf.pinCount > 0) return;
    map.remove(groupPath.last);
    for (int i = stack.length - 1; i >= 0; i--) {
      final parent = stack[i];
      final key = groupPath[i];
      final child = parent[key];
      if (child is Map<Object?, dynamic> && child.isEmpty) {
        parent.remove(key);
      } else {
        break;
      }
    }
    _clearFinger();
  }

  // -------------------- Internal: fully cached markers --------------------

  bool _isFullyCached(List<dynamic> path) {
    if (path.isEmpty) return false;
    dynamic node = _fullyCachedRoot;
    for (int i = 0; i < path.length; i++) {
      if (node is! Map<Object?, dynamic>) return false;
      node = node[path[i]];
      if (node == null) return false;
    }
    return node == true;
  }

  void _setFullyCached(List<dynamic> path, bool value) {
    if (path.isEmpty) return;
    if (value) {
      Map<Object?, dynamic> map = _fullyCachedRoot;
      for (int i = 0; i < path.length; i++) {
        final k = path[i];
        if (i == path.length - 1) {
          map[k] = true;
        } else {
          final next = map[k];
          if (next is Map<Object?, dynamic>) {
            map = next;
          } else {
            final child = <Object?, dynamic>{};
            map[k] = child;
            map = child;
          }
        }
      }
      return;
    }

    Map<Object?, dynamic> map = _fullyCachedRoot;
    final stack = <Map<Object?, dynamic>>[];
    final keys = <Object?>[];

    for (int i = 0; i < path.length; i++) {
      final k = path[i];
      if (i == path.length - 1) {
        map.remove(k);
      } else {
        final next = map[k];
        if (next is! Map<Object?, dynamic>) return;
        stack.add(map);
        keys.add(k);
        map = next;
      }
    }

    for (int i = stack.length - 1; i >= 0; i--) {
      final m = (i == stack.length - 1) ? map : stack[i + 1];
      if (m.isNotEmpty) break;
      stack[i].remove(keys[i]);
    }
  }

  void _removeFullyCachedPrefix(List<dynamic> prefix) {
    if (prefix.isEmpty) {
      _fullyCachedRoot.clear();
      return;
    }
    Map<Object?, dynamic> map = _fullyCachedRoot;
    for (int i = 0; i < prefix.length - 1; i++) {
      final next = map[prefix[i]];
      if (next is! Map<Object?, dynamic>) return;
      map = next;
    }
    map.remove(prefix.last);
  }

  /// Cold-path key normalize (fullyCached / groupEntryCount / scanRange).
  /// Hot point ops use [_keyList] to avoid copying typed lists.
  List<dynamic> _normalizeKey(dynamic key) {
    if (key is List<dynamic>) return key;
    if (key is List) return List<dynamic>.from(key);
    return <dynamic>[key];
  }
}

// -----------------------------------------------------------------------------
// Eviction order node (side structure; point maps still store plain T in none)
// -----------------------------------------------------------------------------

final class _OrderNode {
  final List<dynamic> key;
  int sizeBytes;
  _OrderNode? prev;
  _OrderNode? next;

  _OrderNode(this.key, this.sizeBytes);
}

/// Order-mode flat leaf: value + order node (one HashMap probe on get+touch).
final class _LiveFlat<T> {
  T value;
  final _OrderNode order;

  _LiveFlat(this.value, this.order);
}

// -----------------------------------------------------------------------------
// Group
// -----------------------------------------------------------------------------

final class _Group<T> {
  final List<dynamic> groupPath;
  final int groupDepth;
  final Comparator<dynamic> compare;
  final TreeCacheComparatorFactory? comparatorFactory;
  final bool orderEnabled;
  final bool reorderOnTouch;

  /// Exact group key: `key.length == groupDepth`.
  T? exact;
  bool _hasExact = false;

  bool get hasExact => _hasExact;

  /// Single-suffix: `key.length == groupDepth + 1` (none-mode plain [T]).
  final Map<Object?, T> flat = <Object?, T>{};

  /// Order-mode single-suffix store (avoids second HashMap on get+touch).
  Map<Object?, _LiveFlat<T>>? flatLive;

  /// Multi-suffix nested maps; leaves are [T].
  Map<Object?, dynamic>? deep;

  int entryCount = 0;
  int totalBytes = 0;
  int? cachedWeight;
  int pinCount = 0;

  /// Single-suffix ordered view (suffix components only).
  List<Object?>? orderedFlat;

  /// Delta added suffixes since [orderedFlat] was last materialized.
  final List<Object?> _deltaFlatAdded = <Object?>[];

  /// Delta removed suffixes since [orderedFlat] was last materialized.
  final Set<Object?> _deltaFlatRemoved = <Object?>{};

  /// Multi-suffix / mixed ordered view (full paths).
  List<List<dynamic>>? orderedPaths;

  /// Delta added paths since [orderedPaths] was last materialized.
  final List<List<dynamic>> _deltaPathsAdded = <List<dynamic>>[];

  /// Delta removed path signatures since [orderedPaths] was last materialized.
  final Set<String> _deltaPathsRemoved = <String>{};

  /// Delta removed path list for fast bisection removal.
  final List<List<dynamic>> _deltaPathsRemovedList = <List<dynamic>>[];

  /// Schedule async compaction once |Δ|+|tombstones| exceeds this (never on put/scan hot path).
  static const int _deltaConsolidateThreshold = 2048;

  bool _flatConsolidateScheduled = false;
  bool _pathsConsolidateScheduled = false;

  bool dirty = true;

  /// When true, prefer [orderedPaths] (deep or exact present / mixed).
  bool _orderedNeedsPaths = false;

  /// Eviction order: head = oldest.
  _OrderNode? orderHead;
  _OrderNode? orderTail;

  /// Deep2 field -> pk -> order node (flat uses [_LiveFlat] instead).
  Map<Object?, Map<Object?, _OrderNode>>? deep2Order;

  /// Exact-key order node (`key.length == groupDepth`).
  _OrderNode? exactOrder;

  /// Deep path order tree (>2 suffixes); leaves are [_OrderNode].
  Map<Object?, dynamic>? deepPathOrder;

  Comparator<dynamic>? _cachedCmp0;
  Comparator<dynamic>? _cachedCmp1;

  _Group({
    required this.groupPath,
    required this.groupDepth,
    required this.compare,
    required this.comparatorFactory,
    required this.orderEnabled,
    required this.reorderOnTouch,
  });

  Comparator<dynamic> _suffixComparator(int suffixIndex) {
    if (suffixIndex == 0) {
      return _cachedCmp0 ??= (comparatorFactory != null
          ? comparatorFactory!(groupPath, suffixIndex: 0)
          : compare);
    }
    if (suffixIndex == 1) {
      return _cachedCmp1 ??= (comparatorFactory != null
          ? comparatorFactory!(groupPath, suffixIndex: 1)
          : compare);
    }
    if (comparatorFactory != null) {
      return comparatorFactory!(groupPath, suffixIndex: suffixIndex);
    }
    return compare;
  }

  String _pathSignature(List<dynamic> path) {
    final base = groupDepth;
    final len = path.length;
    if (len == base + 1) return '${path[base]}';
    if (len == base + 2) return '${path[base]}\x00${path[base + 1]}';
    if (len <= base) return '';
    return path.sublist(base).join('\x00');
  }

  int comparePaths(List<dynamic> a, List<dynamic> b) {
    final int base = groupDepth;
    final int al = a.length;
    final int bl = b.length;
    if (al <= base) return (bl <= base) ? 0 : -1;
    if (bl <= base) return 1;

    if (al == base + 2 && bl == base + 2) {
      final c0 = _suffixComparator(0)(a[base], b[base]);
      if (c0 != 0) return c0;
      return _suffixComparator(1)(a[base + 1], b[base + 1]);
    }

    var c = _suffixComparator(0)(a[base], b[base]);
    if (c != 0) return c;
    if (al == base + 1 || bl == base + 1) {
      if (al == bl) return 0;
      return al < bl ? -1 : 1;
    }
    var i = base + 1;
    var suffixIdx = 1;
    while (i < al && i < bl) {
      c = _suffixComparator(suffixIdx)(a[i], b[i]);
      if (c != 0) return c;
      i++;
      suffixIdx++;
    }
    if (al == bl) return 0;
    return al < bl ? -1 : 1;
  }

  // ---- Delta maintenance helpers (LSM-style sorted micro-buffers) ----

  void _maybeScheduleFlatConsolidate() {
    if (_flatConsolidateScheduled) return;
    if (orderedFlat == null) return;
    if (_deltaFlatAdded.isEmpty && _deltaFlatRemoved.isEmpty) return;
    if (_deltaFlatAdded.length + _deltaFlatRemoved.length <=
        _deltaConsolidateThreshold) {
      return;
    }
    _flatConsolidateScheduled = true;
    scheduleMicrotask(() {
      _flatConsolidateScheduled = false;
      if (orderedFlat != null) {
        _consolidateFlatDeltas();
      }
    });
  }

  void _maybeSchedulePathsConsolidate() {
    if (_pathsConsolidateScheduled) return;
    if (orderedPaths == null) return;
    if (_deltaPathsAdded.isEmpty && _deltaPathsRemoved.isEmpty) return;
    if (_deltaPathsAdded.length + _deltaPathsRemoved.length <=
        _deltaConsolidateThreshold) {
      return;
    }
    _pathsConsolidateScheduled = true;
    scheduleMicrotask(() {
      _pathsConsolidateScheduled = false;
      if (orderedPaths != null) {
        _consolidatePathsDeltas();
      }
    });
  }

  void _insertDeltaFlat(Object? suffix) {
    if (_deltaFlatRemoved.isNotEmpty) {
      _deltaFlatRemoved.remove(suffix);
    }
    final a = _deltaFlatAdded;
    final cmp = _suffixComparator(0);

    // Fast-path: sequential / monotonic append (e.g. auto-increment PKs / timestamps)
    if (a.isNotEmpty) {
      final cLast = cmp(a.last, suffix);
      if (cLast < 0) {
        a.add(suffix);
        _maybeScheduleFlatConsolidate();
        return;
      } else if (cLast == 0) {
        return;
      }
    }

    var lo = 0;
    var hi = a.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      final c = cmp(a[mid], suffix);
      if (c < 0) {
        lo = mid + 1;
      } else if (c == 0) {
        return;
      } else {
        hi = mid;
      }
    }
    a.insert(lo, suffix);
    _maybeScheduleFlatConsolidate();
  }

  void _removeDeltaFlat(Object? suffix) {
    final a = _deltaFlatAdded;
    if (a.isNotEmpty) {
      final cmp = _suffixComparator(0);
      var lo = 0;
      var hi = a.length;
      while (lo < hi) {
        final mid = (lo + hi) >> 1;
        final c = cmp(a[mid], suffix);
        if (c < 0) {
          lo = mid + 1;
        } else if (c == 0) {
          a.removeAt(mid);
          break;
        } else {
          hi = mid;
        }
      }
    }
    if (orderedFlat != null) {
      _deltaFlatRemoved.add(suffix);
      _maybeScheduleFlatConsolidate();
    }
  }

  int _lowerBoundDeltaFlat(Object? key) {
    final a = _deltaFlatAdded;
    final cmp = _suffixComparator(0);
    var lo = 0;
    var hi = a.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (cmp(a[mid], key) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  int _upperBoundDeltaFlat(Object? key) {
    final a = _deltaFlatAdded;
    final cmp = _suffixComparator(0);
    var lo = 0;
    var hi = a.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (cmp(a[mid], key) <= 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  void _insertDeltaPaths(List<dynamic> path) {
    if (_deltaPathsRemoved.isNotEmpty) {
      final sig = _pathSignature(path);
      _deltaPathsRemoved.remove(sig);
    }
    final a = _deltaPathsAdded;

    // Fast-path: monotonic path append
    if (a.isNotEmpty) {
      final cLast = comparePaths(a.last, path);
      if (cLast < 0) {
        a.add(path);
        _maybeSchedulePathsConsolidate();
        return;
      } else if (cLast == 0) {
        return;
      }
    }

    var lo = 0;
    var hi = a.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      final c = comparePaths(a[mid], path);
      if (c < 0) {
        lo = mid + 1;
      } else if (c == 0) {
        return;
      } else {
        hi = mid;
      }
    }
    a.insert(lo, path);
    _maybeSchedulePathsConsolidate();
  }

  void _removeDeltaPaths(List<dynamic> path) {
    final a = _deltaPathsAdded;
    if (a.isNotEmpty) {
      var lo = 0;
      var hi = a.length;
      while (lo < hi) {
        final mid = (lo + hi) >> 1;
        final c = comparePaths(a[mid], path);
        if (c < 0) {
          lo = mid + 1;
        } else if (c == 0) {
          a.removeAt(mid);
          break;
        } else {
          hi = mid;
        }
      }
    }
    if (orderedPaths != null) {
      _deltaPathsRemoved.add(_pathSignature(path));
      _maybeSchedulePathsConsolidate();
    }
  }

  int _lowerBoundDeltaPaths(List<dynamic> key) {
    final a = _deltaPathsAdded;
    var lo = 0;
    var hi = a.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (comparePaths(a[mid], key) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  int _upperBoundDeltaPaths(List<dynamic> key) {
    final a = _deltaPathsAdded;
    var lo = 0;
    var hi = a.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (comparePaths(a[mid], key) <= 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  // ---- order list ----

  /// After [TreeCache.renameGroup], rewrite group component on order keys.
  void rewriteGroupKeyInOrderNodes(Object? newGroupKey) {
    if (!orderEnabled) {
      // Ordered path vectors (if any) still carry the old group prefix.
      final paths = orderedPaths;
      if (paths != null) {
        for (final p in paths) {
          if (p.isNotEmpty) p[0] = newGroupKey;
        }
      }
      for (final p in _deltaPathsAdded) {
        if (p.isNotEmpty) p[0] = newGroupKey;
      }
      return;
    }
    var node = orderHead;
    while (node != null) {
      if (node.key.isNotEmpty) node.key[0] = newGroupKey;
      node = node.next;
    }
    final paths = orderedPaths;
    if (paths != null) {
      for (final p in paths) {
        if (p.isNotEmpty) p[0] = newGroupKey;
      }
    }
    for (final p in _deltaPathsAdded) {
      if (p.isNotEmpty) p[0] = newGroupKey;
    }
  }

  void attachNew(_OrderNode e) {
    if (!orderEnabled) return;
    if (orderTail == null) {
      orderHead = e;
      orderTail = e;
      return;
    }
    e.prev = orderTail;
    e.next = null;
    orderTail!.next = e;
    orderTail = e;
  }

  void touchNode(_OrderNode e) {
    if (!reorderOnTouch) return;
    if (identical(e, orderTail)) return;
    final p = e.prev;
    final n = e.next;
    if (p != null) p.next = n;
    if (n != null) n.prev = p;
    if (identical(e, orderHead)) orderHead = n;
    e.prev = orderTail;
    e.next = null;
    if (orderTail != null) orderTail!.next = e;
    orderTail = e;
    orderHead ??= e;
  }

  void detachNode(_OrderNode e) {
    if (!orderEnabled) return;
    final p = e.prev;
    final n = e.next;
    if (p != null) p.next = n;
    if (n != null) n.prev = p;
    if (identical(e, orderHead)) orderHead = n;
    if (identical(e, orderTail)) orderTail = p;
    e.prev = null;
    e.next = null;
  }

  @pragma('vm:prefer-inline')
  void touchFlat(Object? suffix) {
    final live = flatLive?[suffix];
    if (live != null) touchNode(live.order);
  }

  @pragma('vm:prefer-inline')
  void touchDeep2(Object? s0, Object? s1) {
    final n = deep2Order?[s0]?[s1];
    if (n != null) touchNode(n);
  }

  void touchExact() {
    final n = exactOrder;
    if (n != null) touchNode(n);
  }

  void touchPath(List<dynamic> key) {
    if (!reorderOnTouch) return;
    final base = groupDepth;
    final len = key.length;
    if (len == base) {
      final n = exactOrder;
      if (n != null) touchNode(n);
      return;
    }
    if (len == base + 1) {
      touchFlat(key[base]);
      return;
    }
    if (len == base + 2) {
      touchDeep2(key[base], key[base + 1]);
      return;
    }
    if (len > base + 2) {
      final n = _lookupDeepPathOrder(key);
      if (n != null) touchNode(n);
    }
  }

  /// Pop oldest order node and remove from point store. Returns false if stale.
  bool evictOrderHead() {
    final node = orderHead;
    if (node == null) return false;
    final removed = pointRemove(node.key);
    if (!removed) {
      // Stale order node -- drop from list only.
      _unlinkOrderOnly(node);
      return false;
    }
    return true;
  }

  void _unlinkOrderOnly(_OrderNode node) {
    detachNode(node);
    final key = node.key;
    final base = groupDepth;
    if (key.length == base) {
      if (identical(exactOrder, node)) exactOrder = null;
    } else if (key.length == base + 1) {
      flatLive?.remove(key[base]);
    } else if (key.length == base + 2) {
      final m = deep2Order?[key[base]];
      m?.remove(key[base + 1]);
      if (m != null && m.isEmpty) deep2Order?.remove(key[base]);
    } else if (key.length > base + 2) {
      // Index drop only -- node already detached; do not adjust totalBytes.
      _dropDeepPathOrderIndex(key);
    }
  }

  void _dropDeepPathOrderIndex(List<dynamic> key) {
    final root = deepPathOrder;
    if (root == null) return;
    final base = groupDepth;
    final stack = <Map<Object?, dynamic>>[];
    final keys = <Object?>[];
    Map<Object?, dynamic> map = root;
    for (int i = base; i < key.length - 1; i++) {
      stack.add(map);
      final comp = key[i];
      keys.add(comp);
      final next = map[comp];
      if (next is! Map<Object?, dynamic>) return;
      map = next;
    }
    map.remove(key[key.length - 1]);
    for (int i = stack.length - 1; i >= 0; i--) {
      final m = (i == stack.length - 1) ? map : stack[i + 1];
      if (m.isNotEmpty) break;
      stack[i].remove(keys[i]);
    }
    if (root.isEmpty) deepPathOrder = null;
  }

  void _noteExactOrder(List<dynamic> key, int sizeBytes,
      {required bool isNew}) {
    if (!orderEnabled) return;
    if (!isNew) {
      final n = exactOrder;
      if (n != null) {
        totalBytes += sizeBytes - n.sizeBytes;
        n.sizeBytes = sizeBytes;
        if (reorderOnTouch) touchNode(n);
      }
      return;
    }
    final node = _OrderNode(List<dynamic>.from(key), sizeBytes);
    exactOrder = node;
    totalBytes += sizeBytes;
    attachNew(node);
  }

  void _removeExactOrder() {
    if (!orderEnabled) return;
    final n = exactOrder;
    if (n == null) return;
    exactOrder = null;
    totalBytes -= n.sizeBytes;
    if (totalBytes < 0) totalBytes = 0;
    detachNode(n);
  }

  _OrderNode? _lookupDeepPathOrder(List<dynamic> key) {
    final root = deepPathOrder;
    if (root == null) return null;
    final base = groupDepth;
    dynamic node = root;
    for (int i = base; i < key.length; i++) {
      if (node is! Map<Object?, dynamic>) return null;
      node = node[key[i]];
      if (node == null) return null;
    }
    return node is _OrderNode ? node : null;
  }

  void _noteDeepPathOrder(List<dynamic> key, int sizeBytes,
      {required bool isNew}) {
    if (!orderEnabled) return;
    final base = groupDepth;
    var map = deepPathOrder;
    if (map == null) {
      map = <Object?, dynamic>{};
      deepPathOrder = map;
    }
    for (int i = base; i < key.length - 1; i++) {
      final comp = key[i];
      final next = map![comp];
      if (next is Map<Object?, dynamic>) {
        map = next;
      } else {
        final child = <Object?, dynamic>{};
        map[comp] = child;
        map = child;
      }
    }
    final last = key[key.length - 1];
    if (!isNew) {
      final existing = map![last];
      if (existing is _OrderNode) {
        totalBytes += sizeBytes - existing.sizeBytes;
        existing.sizeBytes = sizeBytes;
        if (reorderOnTouch) touchNode(existing);
      }
      return;
    }
    final node = _OrderNode(List<dynamic>.from(key), sizeBytes);
    map![last] = node;
    totalBytes += sizeBytes;
    attachNew(node);
  }

  void _removeDeepPathOrder(List<dynamic> key) {
    if (!orderEnabled) return;
    final root = deepPathOrder;
    if (root == null) return;
    final base = groupDepth;
    final stack = <Map<Object?, dynamic>>[];
    final keys = <Object?>[];
    Map<Object?, dynamic> map = root;
    for (int i = base; i < key.length - 1; i++) {
      stack.add(map);
      final comp = key[i];
      keys.add(comp);
      final next = map[comp];
      if (next is! Map<Object?, dynamic>) return;
      map = next;
    }
    final last = key[key.length - 1];
    final node = map[last];
    if (node is! _OrderNode) return;
    map.remove(last);
    totalBytes -= node.sizeBytes;
    if (totalBytes < 0) totalBytes = 0;
    detachNode(node);
    for (int i = stack.length - 1; i >= 0; i--) {
      final m = (i == stack.length - 1) ? map : stack[i + 1];
      if (m.isNotEmpty) break;
      stack[i].remove(keys[i]);
    }
    if (root.isEmpty) deepPathOrder = null;
  }

  void _noteDeep2Order(
    Object? s0,
    Object? s1,
    int sizeBytes, {
    required bool isNew,
  }) {
    if (!orderEnabled) return;
    final outer = deep2Order ??= <Object?, Map<Object?, _OrderNode>>{};
    final inner = outer[s0] ?? <Object?, _OrderNode>{};
    outer[s0] = inner;
    var node = inner[s1];
    if (node == null) {
      final key = List<dynamic>.from(groupPath)
        ..add(s0)
        ..add(s1);
      node = _OrderNode(key, sizeBytes);
      inner[s1] = node;
      attachNew(node);
      totalBytes += sizeBytes;
    } else {
      totalBytes += sizeBytes - node.sizeBytes;
      node.sizeBytes = sizeBytes;
      touchNode(node);
    }
  }

  void _removeDeep2Order(Object? s0, Object? s1) {
    if (!orderEnabled) return;
    final inner = deep2Order?[s0];
    if (inner == null) return;
    final node = inner.remove(s1);
    if (inner.isEmpty) deep2Order?.remove(s0);
    if (node == null) return;
    totalBytes -= node.sizeBytes;
    if (totalBytes < 0) totalBytes = 0;
    detachNode(node);
  }

  // ---- point store ----

  bool putExactNone(T value) {
    final was = _hasExact;
    exact = value;
    _hasExact = true;
    _orderedNeedsPaths = true;
    if (!was) {
      entryCount++;
      if (orderedPaths != null) {
        _insertDeltaPaths(List<dynamic>.from(groupPath));
      }
      return true;
    }
    return false;
  }

  bool removeExactNone() {
    if (!_hasExact) return false;
    exact = null;
    _hasExact = false;
    entryCount--;
    if (orderedPaths != null) {
      _removeDeltaPaths(List<dynamic>.from(groupPath));
    }
    return true;
  }

  /// Order-mode exact put. [key] must be length == [groupDepth].
  bool putExact(T value, {required List<dynamic> key, int sizeBytes = 0}) {
    final was = _hasExact;
    exact = value;
    _hasExact = true;
    _orderedNeedsPaths = true;
    if (!was) {
      entryCount++;
      if (orderedPaths != null) {
        _insertDeltaPaths(List<dynamic>.from(groupPath));
      }
    }
    if (orderEnabled) {
      _noteExactOrder(key, sizeBytes <= 0 ? 1 : sizeBytes, isNew: !was);
    }
    return !was;
  }

  bool removeExact() {
    if (!_hasExact) return false;
    exact = null;
    _hasExact = false;
    entryCount--;
    if (orderedPaths != null) {
      _removeDeltaPaths(List<dynamic>.from(groupPath));
    }
    _removeExactOrder();
    return true;
  }

  /// none-mode flat put: no order / size / length-branch tax beyond HashMap.
  @pragma('vm:prefer-inline')
  bool putFlatNone(Object? suffix, T value) {
    final before = flat.length;
    flat[suffix] = value;
    if (flat.length == before) return false;
    entryCount++;
    if (orderedFlat != null) {
      _insertDeltaFlat(suffix);
    }
    return true;
  }

  @pragma('vm:prefer-inline')
  bool removeFlatNone(Object? suffix) {
    if (flat.remove(suffix) == null) return false;
    entryCount--;
    if (orderedFlat != null) {
      _removeDeltaFlat(suffix);
    }
    return true;
  }

  @pragma('vm:prefer-inline')
  T? getFlat(Object? suffix, {required bool touch}) {
    if (!orderEnabled) return flat[suffix];
    final live = flatLive?[suffix];
    if (live == null) return null;
    if (touch) touchNode(live.order);
    return live.value;
  }

  @pragma('vm:prefer-inline')
  bool containsFlat(Object? suffix) {
    if (!orderEnabled) return flat.containsKey(suffix);
    return flatLive?.containsKey(suffix) ?? false;
  }

  @pragma('vm:prefer-inline')
  bool putDeep2None(Object? s0, Object? s1, T value) {
    _orderedNeedsPaths = true;
    var d = deep;
    if (d == null) {
      d = <Object?, dynamic>{};
      deep = d;
    }
    final existingInner = d[s0];
    final Map<Object?, dynamic> leaf;
    if (existingInner is Map<Object?, dynamic>) {
      leaf = existingInner;
    } else {
      leaf = <Object?, dynamic>{};
      d[s0] = leaf;
    }
    final before = leaf.length;
    leaf[s1] = value;
    if (leaf.length == before) return false;
    entryCount++;
    if (orderedPaths != null) {
      final path = List<dynamic>.from(groupPath)
        ..add(s0)
        ..add(s1);
      _insertDeltaPaths(path);
    }
    return true;
  }

  @pragma('vm:prefer-inline')
  bool removeDeep2None(Object? s0, Object? s1) {
    final d = deep;
    if (d == null) return false;
    final inner = d[s0];
    if (inner is! Map<Object?, dynamic>) return false;
    if (inner.remove(s1) == null) return false;
    entryCount--;
    if (orderedPaths != null) {
      final path = List<dynamic>.from(groupPath)
        ..add(s0)
        ..add(s1);
      _removeDeltaPaths(path);
    }
    if (inner.isEmpty) {
      d.remove(s0);
      if (d.isEmpty) deep = null;
    }
    return true;
  }

  /// Returns true when [suffix] was newly inserted.
  @pragma('vm:prefer-inline')
  bool putFlat(Object? suffix, T value, {int sizeBytes = 0}) {
    if (!orderEnabled) {
      return putFlatNone(suffix, value);
    }

    final sz = sizeBytes <= 0 ? 1 : sizeBytes;
    final map = flatLive ??= <Object?, _LiveFlat<T>>{};
    final existing = map[suffix];
    if (existing != null) {
      existing.value = value;
      totalBytes += sz - existing.order.sizeBytes;
      existing.order.sizeBytes = sz;
      touchNode(existing.order);
      return false;
    }
    final key = List<dynamic>.from(groupPath)..add(suffix);
    final order = _OrderNode(key, sz);
    map[suffix] = _LiveFlat<T>(value, order);
    attachNew(order);
    totalBytes += sz;
    entryCount++;
    if (orderedFlat != null) {
      _insertDeltaFlat(suffix);
    }
    return true;
  }

  @pragma('vm:prefer-inline')
  bool removeFlat(Object? suffix) {
    if (!orderEnabled) {
      return removeFlatNone(suffix);
    }
    final live = flatLive?.remove(suffix);
    if (live == null) return false;
    entryCount--;
    totalBytes -= live.order.sizeBytes;
    if (totalBytes < 0) totalBytes = 0;
    detachNode(live.order);
    if (orderedFlat != null) {
      _removeDeltaFlat(suffix);
    }
    return true;
  }

  /// Two-suffix deep leaf: index marker `[..., field, pk]`.
  @pragma('vm:prefer-inline')
  T? getDeep2(Object? s0, Object? s1) {
    final d = deep;
    if (d == null) return null;
    final inner = d[s0];
    if (inner is! Map<Object?, dynamic>) return null;
    final v = inner[s1];
    if (v is Map) return null;
    return v as T?;
  }

  @pragma('vm:prefer-inline')
  bool containsDeep2(Object? s0, Object? s1) {
    final d = deep;
    if (d == null) return false;
    final inner = d[s0];
    if (inner is! Map<Object?, dynamic>) return false;
    final v = inner[s1];
    return v != null || inner.containsKey(s1);
  }

  /// Returns true when newly inserted.
  @pragma('vm:prefer-inline')
  bool putDeep2(Object? s0, Object? s1, T value, {int sizeBytes = 0}) {
    if (!orderEnabled) {
      return putDeep2None(s0, s1, value);
    }
    _orderedNeedsPaths = true;
    var d = deep;
    if (d == null) {
      d = <Object?, dynamic>{};
      deep = d;
    }
    final existingInner = d[s0];
    final Map<Object?, dynamic> leaf;
    if (existingInner is Map<Object?, dynamic>) {
      leaf = existingInner;
    } else {
      leaf = <Object?, dynamic>{};
      d[s0] = leaf;
    }

    final before = leaf.length;
    leaf[s1] = value;
    final isNew = leaf.length > before;
    if (isNew) {
      entryCount++;
      if (orderedPaths != null) {
        final path = List<dynamic>.from(groupPath)
          ..add(s0)
          ..add(s1);
        _insertDeltaPaths(path);
      }
    }
    _noteDeep2Order(s0, s1, sizeBytes <= 0 ? 1 : sizeBytes, isNew: isNew);
    return isNew;
  }

  @pragma('vm:prefer-inline')
  bool removeDeep2(Object? s0, Object? s1) {
    if (!orderEnabled) {
      return removeDeep2None(s0, s1);
    }
    final d = deep;
    if (d == null) return false;
    final inner = d[s0];
    if (inner is! Map<Object?, dynamic>) return false;
    if (inner.remove(s1) == null) return false;
    entryCount--;
    if (orderedPaths != null) {
      final path = List<dynamic>.from(groupPath)
        ..add(s0)
        ..add(s1);
      _removeDeltaPaths(path);
    }
    _removeDeep2Order(s0, s1);
    if (inner.isEmpty) {
      d.remove(s0);
      if (d.isEmpty) deep = null;
    }
    return true;
  }

  /// Visit every live entry with its full path key.
  void forEachEntry(void Function(List<dynamic> path, T value) fn) {
    if (_hasExact) {
      fn(List<dynamic>.from(groupPath), exact as T);
    }
    if (orderEnabled) {
      final live = flatLive;
      if (live != null) {
        for (final e in live.entries) {
          final path = List<dynamic>.from(groupPath)..add(e.key);
          fn(path, e.value.value);
        }
      }
    } else {
      for (final e in flat.entries) {
        final path = List<dynamic>.from(groupPath)..add(e.key);
        fn(path, e.value);
      }
    }
    final d = deep;
    if (d != null) {
      _forEachDeep(d, List<dynamic>.from(groupPath), fn);
    }
  }

  void _forEachDeep(
    Map<Object?, dynamic> node,
    List<dynamic> prefix,
    void Function(List<dynamic> path, T value) fn,
  ) {
    for (final e in node.entries) {
      final next = List<dynamic>.from(prefix)..add(e.key);
      final v = e.value;
      if (v is Map<Object?, dynamic>) {
        _forEachDeep(v, next, fn);
      } else {
        fn(next, v as T);
      }
    }
  }

  T? pointGet(List<dynamic> key) {
    final int base = groupDepth;
    final int len = key.length;
    if (len < base) return null;
    if (len == base) return _hasExact ? exact : null;
    if (len == base + 1) return getFlat(key[base], touch: false);
    final d = deep;
    if (d == null) return null;
    dynamic node = d;
    for (int i = base; i < len; i++) {
      if (node is! Map<Object?, dynamic>) return null;
      node = node[key[i]];
      if (node == null) return null;
    }
    // Leaf is T stored directly (cannot distinguish Map vs T if T is Map --
    // engine values are not Maps of this shape; BufferEntry etc. are fine).
    if (node is Map<Object?, dynamic>) return null;
    return node as T?;
  }

  bool pointContains(List<dynamic> key) {
    final int base = groupDepth;
    final int len = key.length;
    if (len < base) return false;
    if (len == base) return _hasExact;
    if (len == base + 1) return containsFlat(key[base]);
    final d = deep;
    if (d == null) return false;
    dynamic node = d;
    for (int i = base; i < len; i++) {
      if (node is! Map<Object?, dynamic>) return false;
      node = node[key[i]];
      if (node == null) return false;
    }
    return node is! Map<Object?, dynamic>;
  }

  void pointPut(List<dynamic> key, T value, {int sizeBytes = 0}) {
    final int base = groupDepth;
    final int len = key.length;
    if (len < base) return;
    final sz = sizeBytes <= 0 ? 1 : sizeBytes;

    if (len == base) {
      if (orderEnabled) {
        putExact(value, key: key, sizeBytes: sz);
      } else {
        putExactNone(value);
      }
      return;
    }

    if (len == base + 1) {
      putFlat(key[base], value, sizeBytes: sz);
      return;
    }

    if (len == base + 2) {
      putDeep2(key[base], key[base + 1], value, sizeBytes: sz);
      return;
    }

    // Deep multi-suffix (>2).
    _orderedNeedsPaths = true;
    var map = deep;
    if (map == null) {
      map = <Object?, dynamic>{};
      deep = map;
    }
    for (int i = base; i < len - 1; i++) {
      final comp = key[i];
      final next = map![comp];
      if (next is Map<Object?, dynamic>) {
        map = next;
      } else {
        final child = <Object?, dynamic>{};
        map[comp] = child;
        map = child;
      }
    }
    final last = key[len - 1];
    final existed = map!.containsKey(last) && map[last] is! Map;
    map[last] = value;
    if (!existed) {
      entryCount++;
      if (orderedPaths != null) {
        _insertDeltaPaths(List<dynamic>.from(key));
      }
    }
    if (orderEnabled) {
      _noteDeepPathOrder(key, sz, isNew: !existed);
    }
  }

  bool pointRemove(List<dynamic> key) {
    final int base = groupDepth;
    final int len = key.length;
    if (len < base) return false;

    if (len == base) {
      return orderEnabled ? removeExact() : removeExactNone();
    }

    if (len == base + 1) {
      return removeFlat(key[base]);
    }

    if (len == base + 2) {
      return removeDeep2(key[base], key[base + 1]);
    }

    final d = deep;
    if (d == null) return false;
    final stack = <Map<Object?, dynamic>>[];
    final keys = <Object?>[];
    Map<Object?, dynamic> map = d;
    for (int i = base; i < len - 1; i++) {
      stack.add(map);
      final comp = key[i];
      keys.add(comp);
      final next = map[comp];
      if (next is! Map<Object?, dynamic>) return false;
      map = next;
    }
    final last = key[len - 1];
    if (!map.containsKey(last) || map[last] is Map) return false;
    map.remove(last);
    entryCount--;
    if (orderedPaths != null) {
      _removeDeltaPaths(List<dynamic>.from(key));
    }
    _removeDeepPathOrder(key);
    for (int i = stack.length - 1; i >= 0; i--) {
      final m = (i == stack.length - 1) ? map : stack[i + 1];
      if (m.isNotEmpty) break;
      stack[i].remove(keys[i]);
    }
    if (d.isEmpty) deep = null;
    return true;
  }

  // ---- ordered / range ----

  void _consolidateFlatDeltas() {
    if (_deltaFlatAdded.isEmpty && _deltaFlatRemoved.isEmpty) return;
    if (orderedFlat == null) {
      ensureOrdered();
      return;
    }
    final oldBase = orderedFlat!;
    final cmp = _suffixComparator(0);
    final n = oldBase.length;
    final m = _deltaFlatAdded.length;
    final newCap = n + m;
    final merged =
        List<Object?>.filled(newCap > 0 ? newCap : 0, null, growable: true);
    var i = 0, j = 0, k = 0;
    while (i < n && j < m) {
      final bk = oldBase[i];
      if (_deltaFlatRemoved.contains(bk)) {
        i++;
        continue;
      }
      final dk = _deltaFlatAdded[j];
      final c = cmp(bk, dk);
      if (c < 0) {
        merged[k++] = bk;
        i++;
      } else if (c > 0) {
        merged[k++] = dk;
        j++;
      } else {
        merged[k++] = dk;
        i++;
        j++;
      }
    }
    while (i < n) {
      final bk = oldBase[i++];
      if (!_deltaFlatRemoved.contains(bk)) {
        merged[k++] = bk;
      }
    }
    while (j < m) {
      merged[k++] = _deltaFlatAdded[j++];
    }
    if (k < merged.length) {
      merged.length = k;
    }
    orderedFlat = merged;
    _deltaFlatAdded.clear();
    _deltaFlatRemoved.clear();
  }

  void _consolidatePathsDeltas() {
    if (_deltaPathsAdded.isEmpty && _deltaPathsRemoved.isEmpty) return;
    if (orderedPaths == null) {
      ensureOrdered();
      return;
    }
    final oldBase = orderedPaths!;
    final n = oldBase.length;
    final m = _deltaPathsAdded.length;
    final newCap = n + m;
    final merged = List<List<dynamic>>.filled(
      newCap > 0 ? newCap : 0,
      const <dynamic>[],
      growable: true,
    );
    var i = 0, j = 0, k = 0;
    while (i < n && j < m) {
      final bp = oldBase[i];
      if (_deltaPathsRemoved.contains(_pathSignature(bp))) {
        i++;
        continue;
      }
      final dp = _deltaPathsAdded[j];
      final c = comparePaths(bp, dp);
      if (c < 0) {
        merged[k++] = bp;
        i++;
      } else if (c > 0) {
        merged[k++] = dp;
        j++;
      } else {
        merged[k++] = dp;
        i++;
        j++;
      }
    }
    while (i < n) {
      final bp = oldBase[i++];
      if (!_deltaPathsRemoved.contains(_pathSignature(bp))) {
        merged[k++] = bp;
      }
    }
    while (j < m) {
      merged[k++] = _deltaPathsAdded[j++];
    }
    if (k < merged.length) {
      merged.length = k;
    }
    orderedPaths = merged;
    _deltaPathsAdded.clear();
    _deltaPathsRemoved.clear();
    _deltaPathsRemovedList.clear();
  }

  void ensureOrdered() {
    final usePaths = _orderedNeedsPaths || _hasExact || deep != null;
    if (!usePaths) {
      if (orderedFlat == null) {
        final Iterable<Object?> keyIter =
            orderEnabled ? (flatLive?.keys ?? const <Object?>[]) : flat.keys;
        final keys = keyIter.toList(growable: true);
        keys.sort(_suffixComparator(0));
        orderedFlat = keys;
        _deltaFlatAdded.clear();
        _deltaFlatRemoved.clear();
        orderedPaths = null;
        dirty = false;
        return;
      }
      _consolidateFlatDeltas();
      dirty = false;
      return;
    }

    if (orderedPaths == null) {
      final paths = <List<dynamic>>[];
      if (_hasExact) {
        paths.add(List<dynamic>.from(groupPath));
      }
      if (orderEnabled) {
        final live = flatLive;
        if (live != null) {
          for (final e in live.entries) {
            paths.add(List<dynamic>.from(groupPath)..add(e.key));
          }
        }
      } else {
        for (final e in flat.entries) {
          paths.add(List<dynamic>.from(groupPath)..add(e.key));
        }
      }
      final d = deep;
      if (d != null) {
        _collectDeepPaths(d, List<dynamic>.from(groupPath), paths);
      }
      paths.sort(comparePaths);
      orderedPaths = paths;
      orderedFlat = null;
      _deltaPathsAdded.clear();
      _deltaPathsRemoved.clear();
      _deltaPathsRemovedList.clear();
      dirty = false;
      _orderedNeedsPaths = usePaths;
      return;
    }
    _consolidatePathsDeltas();
    dirty = false;
    _orderedNeedsPaths = usePaths;
  }

  void _collectDeepPaths(
    Map<Object?, dynamic> node,
    List<dynamic> prefix,
    List<List<dynamic>> out,
  ) {
    for (final e in node.entries) {
      final nextPrefix = List<dynamic>.from(prefix)..add(e.key);
      final v = e.value;
      if (v is Map<Object?, dynamic>) {
        _collectDeepPaths(v, nextPrefix, out);
      } else {
        out.add(nextPrefix);
      }
    }
  }

  /// Two-way merge scan for single-suffix groups (O(limit) early-stop).
  int _scanRangeTwoWayFlat(
    List<dynamic> start,
    List<dynamic>? end, {
    required bool reverse,
    int? limit,
    required bool Function(List<dynamic> path, T value) onEntry,
  }) {
    if (orderedFlat == null) {
      ensureOrdered();
    }
    final base = orderedFlat!;
    final delta = _deltaFlatAdded;
    final removed = _deltaFlatRemoved;
    final n = base.length;
    final m = delta.length;

    if (n == 0 && m == 0) return 0;

    final Object? startSuffix =
        start.length > groupDepth ? start[groupDepth] : null;
    final Object? endSuffix =
        (end != null && end.length > groupDepth && _prefixMatchesGroup(end))
            ? end[groupDepth]
            : null;

    final cmp = _suffixComparator(0);
    final path = List<dynamic>.from(groupPath)..add(null);
    var emitted = 0;
    var remaining = limit;

    if (!reverse) {
      var i = startSuffix == null ? 0 : _lowerBoundFlat(startSuffix);
      var j = startSuffix == null ? 0 : _lowerBoundDeltaFlat(startSuffix);

      while ((i < n || j < m) && (remaining == null || remaining > 0)) {
        Object? curKey;
        T? curVal;

        if (i < n && j < m) {
          final bk = base[i];
          final dk = delta[j];
          final c = cmp(bk, dk);
          if (c < 0) {
            i++;
            if (removed.contains(bk)) continue;
            curKey = bk;
            curVal = getFlat(bk, touch: false);
          } else if (c > 0) {
            j++;
            curKey = dk;
            curVal = getFlat(dk, touch: false);
          } else {
            i++;
            j++;
            curKey = dk;
            curVal = getFlat(dk, touch: false);
          }
        } else if (i < n) {
          final bk = base[i++];
          if (removed.contains(bk)) continue;
          curKey = bk;
          curVal = getFlat(bk, touch: false);
        } else {
          final dk = delta[j++];
          curKey = dk;
          curVal = getFlat(dk, touch: false);
        }

        if (curVal == null) continue;
        if (endSuffix != null && cmp(curKey, endSuffix) > 0) break;

        path[groupDepth] = curKey;
        emitted++;
        if (!onEntry(path, curVal)) break;
        if (remaining != null) remaining--;
      }
    } else {
      var i = endSuffix == null ? n - 1 : _upperBoundFlat(endSuffix) - 1;
      var j = endSuffix == null ? m - 1 : _upperBoundDeltaFlat(endSuffix) - 1;
      final loBase = startSuffix == null ? 0 : _lowerBoundFlat(startSuffix);
      final loDelta =
          startSuffix == null ? 0 : _lowerBoundDeltaFlat(startSuffix);

      while ((i >= loBase || j >= loDelta) &&
          (remaining == null || remaining > 0)) {
        Object? curKey;
        T? curVal;

        if (i >= loBase && j >= loDelta) {
          final bk = base[i];
          final dk = delta[j];
          final c = cmp(bk, dk);
          if (c > 0) {
            i--;
            if (removed.contains(bk)) continue;
            curKey = bk;
            curVal = getFlat(bk, touch: false);
          } else if (c < 0) {
            j--;
            curKey = dk;
            curVal = getFlat(dk, touch: false);
          } else {
            i--;
            j--;
            curKey = dk;
            curVal = getFlat(dk, touch: false);
          }
        } else if (i >= loBase) {
          final bk = base[i--];
          if (removed.contains(bk)) continue;
          curKey = bk;
          curVal = getFlat(bk, touch: false);
        } else {
          final dk = delta[j--];
          curKey = dk;
          curVal = getFlat(dk, touch: false);
        }

        if (curVal == null) continue;
        if (startSuffix != null && cmp(curKey, startSuffix) < 0) break;

        path[groupDepth] = curKey;
        emitted++;
        if (!onEntry(path, curVal)) break;
        if (remaining != null) remaining--;
      }
    }

    _maybeScheduleFlatConsolidate();
    return emitted;
  }

  /// Two-way merge scan for multi-suffix path groups (O(limit) early-stop).
  int _scanRangeTwoWayPaths(
    List<dynamic> start,
    List<dynamic>? end, {
    required bool reverse,
    int? limit,
    required bool Function(List<dynamic> path, T value) onEntry,
  }) {
    if (orderedPaths == null) {
      ensureOrdered();
    }
    final base = orderedPaths!;
    final delta = _deltaPathsAdded;
    final removed = _deltaPathsRemoved;
    final n = base.length;
    final m = delta.length;

    if (n == 0 && m == 0) return 0;

    var emitted = 0;
    var remaining = limit;

    if (!reverse) {
      var i = _lowerBoundPaths(start);
      var j = _lowerBoundDeltaPaths(start);

      while ((i < n || j < m) && (remaining == null || remaining > 0)) {
        List<dynamic>? curPath;
        T? curVal;

        if (i < n && j < m) {
          final bp = base[i];
          final dp = delta[j];
          final c = comparePaths(bp, dp);
          if (c < 0) {
            i++;
            if (removed.contains(_pathSignature(bp))) continue;
            curPath = bp;
            curVal = pointGet(bp);
          } else if (c > 0) {
            j++;
            curPath = dp;
            curVal = pointGet(dp);
          } else {
            i++;
            j++;
            curPath = dp;
            curVal = pointGet(dp);
          }
        } else if (i < n) {
          final bp = base[i++];
          if (removed.contains(_pathSignature(bp))) continue;
          curPath = bp;
          curVal = pointGet(bp);
        } else {
          final dp = delta[j++];
          curPath = dp;
          curVal = pointGet(dp);
        }

        if (curVal == null) continue;
        if (end != null && comparePaths(curPath, end) > 0) break;

        emitted++;
        if (!onEntry(curPath, curVal)) break;
        if (remaining != null) remaining--;
      }
    } else {
      var i = end == null ? n - 1 : _upperBoundPaths(end) - 1;
      var j = end == null ? m - 1 : _upperBoundDeltaPaths(end) - 1;
      final loBase = _lowerBoundPaths(start);
      final loDelta = _lowerBoundDeltaPaths(start);

      while ((i >= loBase || j >= loDelta) &&
          (remaining == null || remaining > 0)) {
        List<dynamic>? curPath;
        T? curVal;

        if (i >= loBase && j >= loDelta) {
          final bp = base[i];
          final dp = delta[j];
          final c = comparePaths(bp, dp);
          if (c > 0) {
            i--;
            if (removed.contains(_pathSignature(bp))) continue;
            curPath = bp;
            curVal = pointGet(bp);
          } else if (c < 0) {
            j--;
            curPath = dp;
            curVal = pointGet(dp);
          } else {
            i--;
            j--;
            curPath = dp;
            curVal = pointGet(dp);
          }
        } else if (i >= loBase) {
          final bp = base[i--];
          if (removed.contains(_pathSignature(bp))) continue;
          curPath = bp;
          curVal = pointGet(bp);
        } else {
          final dp = delta[j--];
          curPath = dp;
          curVal = pointGet(dp);
        }

        if (curVal == null) continue;
        if (comparePaths(curPath, start) < 0) break;

        emitted++;
        if (!onEntry(curPath, curVal)) break;
        if (remaining != null) remaining--;
      }
    }

    _maybeSchedulePathsConsolidate();
    return emitted;
  }

  /// Returns number of entries emitted.
  int scanRange(
    List<dynamic> start,
    List<dynamic>? end, {
    required bool reverse,
    int? limit,
    required bool Function(List<dynamic> path, T value) onEntry,
  }) {
    final usePaths = _orderedNeedsPaths || _hasExact || deep != null;
    if (!usePaths) {
      return _scanRangeTwoWayFlat(
        start,
        end,
        reverse: reverse,
        limit: limit,
        onEntry: onEntry,
      );
    }
    return _scanRangeTwoWayPaths(
      start,
      end,
      reverse: reverse,
      limit: limit,
      onEntry: onEntry,
    );
  }

  bool _prefixMatchesGroup(List<dynamic> key) {
    if (key.length < groupDepth) return false;
    for (int i = 0; i < groupDepth; i++) {
      if (key[i] != groupPath[i]) return false;
    }
    return true;
  }

  int _lowerBoundFlat(Object? key) {
    final a = orderedFlat!;
    final cmp = _suffixComparator(0);
    var lo = 0;
    var hi = a.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (cmp(a[mid], key) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  int _upperBoundFlat(Object? key) {
    final a = orderedFlat!;
    final cmp = _suffixComparator(0);
    var lo = 0;
    var hi = a.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (cmp(a[mid], key) <= 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  int _lowerBoundPaths(List<dynamic> key) {
    final a = orderedPaths!;
    var lo = 0;
    var hi = a.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (comparePaths(a[mid], key) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  int _upperBoundPaths(List<dynamic> key) {
    final a = orderedPaths!;
    var lo = 0;
    var hi = a.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (comparePaths(a[mid], key) <= 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}
