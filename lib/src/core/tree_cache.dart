import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../handler/logger.dart';
import 'yield_controller.dart';

typedef TreeCacheSizeCalculator<T> = int Function(T value);
typedef TreeCacheComparatorFactory = Comparator<dynamic> Function(
    List<dynamic> groupPath);
typedef TreeCacheWeightQueryCallback = Future<int?> Function(
    List<dynamic> groupPath);

/// A high-performance hierarchical cache built on a custom B+Tree.
///
/// Key model:
/// - Accepts either a scalar key (e.g. `String`) or a `List` path key.
/// - Internally, all keys are normalized to a `List<dynamic>` path.
///
/// Performance model:
/// - **Group partitioning** (controlled by [groupDepth]) provides O(1) prefix removal
///   for prefixes aligned to group boundaries (e.g. `[table]`, `[table, index]`,
///   `[table, index, partition]`).
/// - Within each group, a B+Tree provides O(log n) point lookup and fast range scans.
/// - Eviction uses **group-level weights** (optional) + **entry-level LRU**.
class TreeCache<T> {
  final TreeCacheSizeCalculator<T> sizeCalculator;

  /// Effective max threshold (will be clamped to >= [minByteThreshold]).
  final int maxByteThreshold;

  /// Minimum threshold guardrail (prevents extremely small cache sizes).
  final int minByteThreshold;

  /// Group depth for hierarchical operations:
  /// - 1: group by first component (e.g. tableName)
  /// - 2: group by first 2 components (e.g. tableName + indexName)
  /// - 3: group by first 3 components (e.g. tableName + indexName + partitionNo)
  ///
  /// Prefix removals whose path length is <= [groupDepth] can be executed without
  /// scanning entries (O(number of affected groups)).
  final int groupDepth;

  /// Factory to provide the comparator for the **first component after group prefix**.
  /// For example:
  /// - groupDepth=1 (table records): comparator for PK based on [tableName]
  /// - groupDepth=2 (index data): comparator for first index field based on [table, index]
  final TreeCacheComparatorFactory? comparatorFactory;

  /// Optional group-level weight callback used by eviction.
  final TreeCacheWeightQueryCallback? weightQueryCallback;

  final String debugLabel;

  int _estimatedTotalSizeBytes = 0;
  int _totalEntries = 0;

  /// Nested group map (depth = [groupDepth]).
  /// - depth=1: Map<k0, _Group>
  /// - depth=2: Map<k0, Map<k1, _Group>>
  /// - depth=3: Map<k0, Map<k1, Map<k2, _Group>>>
  final Map<Object?, dynamic> _groupsRoot = <Object?, dynamic>{};

  /// Fully-cached markers (nested map by prefix path).
  final Map<Object?, dynamic> _fullyCachedRoot = <Object?, dynamic>{};

  Future<void>? _cleanupLock;

  /// Cooldown timestamp to prevent cleanup storms.
  /// After a cleanup completes, we wait at least 5 seconds before triggering another.
  DateTime _lastCleanupTime = DateTime.fromMillisecondsSinceEpoch(0);

  TreeCache({
    required this.sizeCalculator,
    required int maxByteThreshold,
    required this.minByteThreshold,
    this.groupDepth = 1,
    this.comparatorFactory,
    this.weightQueryCallback,
    String? debugLabel,
  })  : maxByteThreshold = math.max(maxByteThreshold, minByteThreshold),
        debugLabel = debugLabel ?? 'TreeCache' {
    if (groupDepth <= 0) {
      throw ArgumentError.value(groupDepth, 'groupDepth', 'must be >= 1');
    }
  }

  int get estimatedTotalSizeBytes => _estimatedTotalSizeBytes;
  int get length => _totalEntries;

  /// Default comparator for dynamic values used in keys.
  ///
  /// Notes:
  /// - Supports `null`, `bool`, `num`, `String`, `Uint8List`.
  /// - Treats the string `'\uffff'` as a MAX sentinel (always greatest).
  /// - Provides deterministic ordering across mixed types.
  static int compareNative(dynamic a, dynamic b) {
    if (identical(a, b)) return 0;
    // Sentinel MAX for common range scans.
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

    // Mixed types: compare by a stable type rank, then string fallback.
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

  T? peek(dynamic key) => get(key, updateStats: false);

  T? get(dynamic key, {bool updateStats = true}) {
    final k = _normalizeKey(key);
    final group = _getGroupForKey(k, create: false);
    if (group == null) return null;
    final entry = group.tree.get(k);
    if (entry == null) return null;
    if (updateStats) {
      group.touch(entry);
    }
    return entry.value;
  }

  bool containsKey(dynamic key) {
    final k = _normalizeKey(key);
    final group = _getGroupForKey(k, create: false);
    if (group == null) return false;
    return group.tree.containsKey(k);
  }

  void put(dynamic key, T value, {int? size}) {
    final k = _normalizeKey(key);
    final group = _getGroupForKey(k, create: true)!;

    final int newSize = _sanitizeSize(size ?? sizeCalculator(value));
    final existing = group.tree.findForInsert(k);
    if (existing != null) {
      final int oldSize = existing.sizeBytes;
      existing.value = value;
      existing.sizeBytes = newSize;
      final diff = newSize - oldSize;
      if (diff != 0) {
        group.totalBytes += diff;
        _estimatedTotalSizeBytes += diff;
      }
      group.touch(existing);
    } else {
      final entry = _CacheEntry<T>(k, value, newSize);
      group.tree.insertPrepared(k, entry);
      group.attachNew(entry);
      group.totalBytes += newSize;
      group.entryCount++;
      _estimatedTotalSizeBytes += newSize;
      _totalEntries++;
    }

    _maybeScheduleCleanup();
  }

  /// Batch insert/update.
  ///
  /// [sizes] is optional; when provided, it must use the same keys as [entries].
  void putAll(
    Map<dynamic, T> entries, {
    Map<dynamic, int>? sizes,
  }) {
    if (entries.isEmpty) return;

    for (final e in entries.entries) {
      final dynamic rawKey = e.key;
      final k = _normalizeKey(rawKey);
      final group = _getGroupForKey(k, create: true)!;

      final int newSize = _sanitizeSize(sizes != null
          ? (sizes[rawKey] ?? sizeCalculator(e.value))
          : sizeCalculator(e.value));

      final existing = group.tree.findForInsert(k);
      if (existing != null) {
        final oldSize = existing.sizeBytes;
        existing.value = e.value;
        existing.sizeBytes = newSize;
        final diff = newSize - oldSize;
        if (diff != 0) {
          group.totalBytes += diff;
          _estimatedTotalSizeBytes += diff;
        }
        // For batch operations, we still "touch" to keep LRU sane,
        // but we avoid any extra global work (cleanup check is done once).
        group.touch(existing);
      } else {
        final entry = _CacheEntry<T>(k, e.value, newSize);
        group.tree.insertPrepared(k, entry);
        group.attachNew(entry);
        group.totalBytes += newSize;
        group.entryCount++;
        _estimatedTotalSizeBytes += newSize;
        _totalEntries++;
      }
    }

    _maybeScheduleCleanup();
  }

  /// Remove an entry or a prefix subtree.
  ///
  /// Semantics:
  /// - If [keyOrPrefix] is a scalar: removes that single key.
  /// - If it's a `List`: tries to remove the exact key first. If not found and
  ///   prefix length <= [groupDepth], removes the aligned prefix groups.
  void remove(dynamic keyOrPrefix) {
    final p = _normalizeKey(keyOrPrefix);

    // 1) Try exact remove.
    final group = _getGroupForKey(p, create: false);
    if (group != null) {
      final removed = group.tree.remove(p);
      if (removed != null) {
        group.detach(removed);
        group.totalBytes -= removed.sizeBytes;
        group.entryCount--;
        _estimatedTotalSizeBytes -= removed.sizeBytes;
        _totalEntries--;

        // Do NOT invalidate fully-cached marker on single-entry removals.

        if (group.entryCount <= 0 && group.pinCount <= 0) {
          _removeEmptyGroup(group.groupPath);
        }
        return;
      }
    }

    // 2) Prefix remove (only optimized for prefixes aligned to group boundaries).
    if (p.length <= groupDepth) {
      _removeGroupsByPrefix(p);
      // Clear fully-cached markers under the same prefix.
      _removeFullyCachedPrefix(p);
      return;
    }

    // 3) Fallback: no-op for deep prefixes (not used by current hot paths).
  }

  void clear() {
    _groupsRoot.clear();
    _fullyCachedRoot.clear();
    _estimatedTotalSizeBytes = 0;
    _totalEntries = 0;
  }

  bool isFullyCached(dynamic keyOrPrefix) {
    final p = _normalizeKey(keyOrPrefix);
    return _isFullyCached(p);
  }

  void setFullyCached(dynamic keyOrPrefix, bool isFullyCached) {
    final p = _normalizeKey(keyOrPrefix);
    _setFullyCached(p, isFullyCached);
  }

  /// Scan a range (inclusive) inside a single group.
  ///
  /// - If [endKey] is null, scans until the end of the group.
  /// - For prefix scans, pass a group prefix as [startKey] (e.g. `[table]` or
  ///   `[table, index]`) and set [endKey] to null; stop condition can be implemented
  ///   in [onEntry] by returning false.
  Future<void> scanRange(
    dynamic startKey,
    dynamic endKey, {
    bool reverse = false,
    int? limit,
    required bool Function(List<dynamic> path, T value) onEntry,
  }) async {
    final List<dynamic> start = _normalizeKey(startKey);
    final List<dynamic>? end = endKey == null ? null : _normalizeKey(endKey);

    final group = _getGroupForKey(start, create: false);
    if (group == null) return;

    group.pinCount++;
    try {
      final yieldController =
          YieldController('TreeCache.scanRange:$debugLabel');
      await group.tree.scanRange(
        start,
        end,
        reverse: reverse,
        limit: limit,
        yieldController: yieldController,
        onEntry: (k, entry) {
          // Skip tombstoned/removed entries are not possible here since we physically remove.
          return onEntry(k, entry.value);
        },
      );
    } finally {
      group.pinCount--;
      if (group.pinCount <= 0 && group.entryCount <= 0) {
        _removeEmptyGroup(group.groupPath);
      }
    }
  }

  /// Scan all entries under a prefix (best-effort, async-yielding).
  ///
  /// This is a convenience wrapper over [scanRange] with `endKey = null`.
  Future<void> scan(
    dynamic prefix, {
    bool reverse = false,
    int? limit,
    required bool Function(List<dynamic> keyPath, T value) onEntry,
  }) async {
    await scanRange(
      prefix,
      null,
      reverse: reverse,
      limit: limit,
      onEntry: onEntry,
    );
  }

  Future<void> cleanup({double removeRatio = 0.3}) async {
    if (removeRatio <= 0) return;
    if (removeRatio > 1) removeRatio = 1;

    // Lock to prevent concurrent cleanups.
    if (_cleanupLock != null) {
      await _cleanupLock;
      return;
    }

    final completer = Completer<void>();
    _cleanupLock = completer.future;

    try {
      if (_totalEntries <= 0) return;

      final int targetRemove =
          math.max(1, (_totalEntries * removeRatio).ceil());
      int removedTotal = 0;

      final groups = <_Group<T>>[];
      _collectGroups(_groupsRoot, depth: 1, out: groups);
      if (groups.isEmpty) return;

      final yieldController = YieldController('TreeCache.cleanup:$debugLabel');

      // Query weights (best-effort).
      for (final g in groups) {
        await yieldController.maybeYield();
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

      // Sort groups by weight ASC (lowest first).
      groups.sort((a, b) {
        final wa = a.cachedWeight ?? 0;
        final wb = b.cachedWeight ?? 0;
        final c = wa.compareTo(wb);
        if (c != 0) return c;
        // Tie-break: larger groups first to converge faster.
        return b.entryCount.compareTo(a.entryCount);
      });

      for (final g in groups) {
        if (removedTotal >= targetRemove) break;
        if (g.entryCount <= 0) continue;

        final int groupTarget =
            math.max(1, (g.entryCount * removeRatio).ceil());
        int need = math.min(groupTarget, targetRemove - removedTotal);

        if (need <= 0) continue;

        // Eviction invalidates full-cache marker for this group.
        _setFullyCached(g.groupPath, false);

        while (need > 0 && g.lruHead != null) {
          await yieldController.maybeYield();

          final entry = g.lruHead!;

          final removedEntry = g.tree.remove(entry.key);
          if (removedEntry == null) {
            // Inconsistent; detach defensively and continue.
            g.detach(entry);
            need--;
            removedTotal++;
            continue;
          }

          g.detach(removedEntry);
          g.totalBytes -= removedEntry.sizeBytes;
          g.entryCount--;
          _estimatedTotalSizeBytes -= removedEntry.sizeBytes;
          _totalEntries--;

          need--;
          removedTotal++;
          if (removedTotal >= targetRemove) break;
        }

        if (g.entryCount <= 0 && g.pinCount <= 0) {
          _removeEmptyGroup(g.groupPath);
        }
      }

      if (removedTotal > 0) {
        Logger.debug(
          '[$debugLabel] cleanup removed=$removedTotal target=$targetRemove '
          'entries=$_totalEntries bytes=$_estimatedTotalSizeBytes',
          label: debugLabel,
        );
      }
      // Update cooldown timestamp AFTER cleanup completes.
      _lastCleanupTime = DateTime.now();
    } finally {
      completer.complete();
      if (identical(_cleanupLock, completer.future)) {
        _cleanupLock = null;
      }
    }
  }

  // -------------------- Internal: groups --------------------

  List<dynamic> _normalizeKey(dynamic key) {
    if (key is List) return key;
    return <dynamic>[key];
  }

  int _sanitizeSize(int size) => size <= 0 ? 1 : size;

  _Group<T>? _getGroupForKey(
    List<dynamic> key, {
    required bool create,
  }) {
    if (key.isEmpty) return null;
    if (key.length < groupDepth) return null;

    Map<Object?, dynamic> map = _groupsRoot;
    for (int depth = 0; depth < groupDepth; depth++) {
      final comp = key[depth];
      if (depth == groupDepth - 1) {
        final existing = map[comp];
        if (existing is _Group<T>) return existing;
        if (!create) return null;

        final groupPath = key.sublist(0, groupDepth);
        final Comparator<dynamic> firstSuffixComparator =
            comparatorFactory != null
                ? comparatorFactory!(groupPath)
                : compareNative;

        final group = _Group<T>(
          groupPath: groupPath,
          groupDepth: groupDepth,
          firstSuffixComparator: firstSuffixComparator,
        );
        map[comp] = group;
        return group;
      }

      final next = map[comp];
      if (next is Map<Object?, dynamic>) {
        map = next;
      } else {
        if (!create) return null;
        final child = <Object?, dynamic>{};
        map[comp] = child;
        map = child;
      }
    }
    return null;
  }

  void _collectGroups(
    Map<Object?, dynamic> node, {
    required int depth,
    required List<_Group<T>> out,
  }) {
    if (groupDepth == 1) {
      for (final v in node.values) {
        if (v is _Group<T>) out.add(v);
      }
      return;
    }

    if (depth == groupDepth) {
      for (final v in node.values) {
        if (v is _Group<T>) out.add(v);
      }
      return;
    }

    for (final v in node.values) {
      if (v is Map<Object?, dynamic>) {
        _collectGroups(v, depth: depth + 1, out: out);
      } else if (v is _Group<T>) {
        out.add(v);
      }
    }
  }

  void _removeEmptyGroup(List<dynamic> groupPath) {
    if (groupPath.isEmpty) return;
    Map<Object?, dynamic> map = _groupsRoot;
    final stack = <Map<Object?, dynamic>>[];
    final keys = <Object?>[];

    for (int depth = 0; depth < groupDepth; depth++) {
      stack.add(map);
      final comp = groupPath[depth];
      keys.add(comp);
      if (depth == groupDepth - 1) break;
      final next = map[comp];
      if (next is Map<Object?, dynamic>) {
        map = next;
      } else {
        return;
      }
    }

    // Check for pinCount before removing.
    final potentialGroup = stack.last[keys.last];
    if (potentialGroup is _Group<T> && potentialGroup.pinCount > 0) {
      return;
    }

    // Remove leaf group.
    stack.last.remove(keys.last);

    // Prune empty maps upwards.
    for (int i = stack.length - 1; i > 0; i--) {
      final m = stack[i];
      if (m.isNotEmpty) break;
      stack[i - 1].remove(keys[i - 1]);
    }
  }

  void _removeGroupsByPrefix(List<dynamic> prefix) {
    if (prefix.isEmpty) return;

    // Remove entire cache.
    if (prefix.length == 1 && groupDepth == 1) {
      final g = _groupsRoot.remove(prefix[0]);
      if (g is _Group<T>) {
        _estimatedTotalSizeBytes -= g.totalBytes;
        _totalEntries -= g.entryCount;
      } else if (g is Map<Object?, dynamic>) {
        final tmp = <_Group<T>>[];
        _collectGroups(g, depth: 2, out: tmp);
        for (final gg in tmp) {
          _estimatedTotalSizeBytes -= gg.totalBytes;
          _totalEntries -= gg.entryCount;
        }
      }
      return;
    }

    // Prefix aligns to a group boundary or higher.
    final int cutoff = math.min(prefix.length, groupDepth);

    Map<Object?, dynamic> map = _groupsRoot;
    final stack = <Map<Object?, dynamic>>[];
    final keys = <Object?>[];

    for (int i = 0; i < cutoff - 1; i++) {
      final comp = prefix[i];
      final next = map[comp];
      if (next is! Map<Object?, dynamic>) return;
      stack.add(map);
      keys.add(comp);
      map = next;
    }

    final Object? lastKey = prefix[cutoff - 1];
    final removed = map.remove(lastKey);
    if (removed == null) return;

    if (removed is _Group<T>) {
      _estimatedTotalSizeBytes -= removed.totalBytes;
      _totalEntries -= removed.entryCount;
    } else if (removed is Map<Object?, dynamic>) {
      final tmp = <_Group<T>>[];
      _collectGroups(removed, depth: cutoff + 1, out: tmp);
      for (final g in tmp) {
        _estimatedTotalSizeBytes -= g.totalBytes;
        _totalEntries -= g.entryCount;
      }
    }

    // Prune empty maps upwards.
    for (int i = stack.length - 1; i >= 0; i--) {
      final m = (i == stack.length - 1) ? map : stack[i + 1];
      if (m.isNotEmpty) break;
      stack[i].remove(keys[i]);
    }
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

    // Remove marker and prune.
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
    if (prefix.isEmpty) return;
    Map<Object?, dynamic> map = _fullyCachedRoot;
    for (int i = 0; i < prefix.length - 1; i++) {
      final next = map[prefix[i]];
      if (next is! Map<Object?, dynamic>) return;
      map = next;
    }
    map.remove(prefix.last);
  }

  void _maybeScheduleCleanup() {
    if (maxByteThreshold <= 0) return;
    if (_estimatedTotalSizeBytes <= maxByteThreshold) return;
    if (_cleanupLock != null) return;

    // Cooldown: avoid cleanup storms when cleanup cannot free enough bytes
    // to drop below threshold (e.g., when few large entries remain).
    // Wait at least 5 seconds after last cleanup before triggering another.
    final now = DateTime.now();
    if (now.difference(_lastCleanupTime).inSeconds < 5) {
      return;
    }

    // Best-effort: do not await; cleanup yields to avoid UI jank.
    // ignore: discarded_futures
    cleanup();
  }
}

// -------------------- Internal: group + entry + LRU --------------------

final class _CacheEntry<T> {
  final List<dynamic> key;
  T value;
  int sizeBytes;
  _CacheEntry<T>? lruPrev;
  _CacheEntry<T>? lruNext;
  _CacheEntry(this.key, this.value, this.sizeBytes);
}

final class _Group<T> {
  final List<dynamic> groupPath;
  final int groupDepth;
  final Comparator<dynamic> firstSuffixComparator;
  final _BPlusTree<List<dynamic>, _CacheEntry<T>> tree;

  int totalBytes = 0;
  int entryCount = 0;
  int pinCount = 0;
  int? cachedWeight;

  _CacheEntry<T>? lruHead;
  _CacheEntry<T>? lruTail;

  _Group({
    required this.groupPath,
    required this.groupDepth,
    required this.firstSuffixComparator,
  }) : tree = _BPlusTree<List<dynamic>, _CacheEntry<T>>(
          order: 64,
          compare: (a, b) {
            // Compare only the suffix after group prefix.
            //
            // Hot-path optimization:
            // - Most cache keys are short (1-3 suffix components).
            // - Avoid loop/branch overhead by specializing common lengths.
            final int al = a.length;
            final int bl = b.length;
            final int base = groupDepth;

            // If either key is shorter than the group prefix, treat it as smaller.
            if (al <= base) return (bl <= base) ? 0 : -1;
            if (bl <= base) return 1;

            // Compare first suffix component with custom comparator.
            int c = firstSuffixComparator(a[base], b[base]);
            if (c != 0) return c;

            // Common case: exactly one suffix component.
            if (al == base + 1 || bl == base + 1) {
              if (al == bl) return 0;
              return al < bl ? -1 : 1;
            }

            // Common case: exactly two suffix components.
            if (al == base + 2 && bl == base + 2) {
              c = TreeCache.compareNative(a[base + 1], b[base + 1]);
              if (c != 0) return c;
              return 0;
            }

            // Fallback: compare remaining components.
            int i = base + 1;
            while (i < al && i < bl) {
              c = TreeCache.compareNative(a[i], b[i]);
              if (c != 0) return c;
              i++;
            }
            if (al == bl) return 0;
            return al < bl ? -1 : 1;
          },
        );

  void attachNew(_CacheEntry<T> e) {
    if (lruTail == null) {
      lruHead = e;
      lruTail = e;
      return;
    }
    e.lruPrev = lruTail;
    e.lruNext = null;
    lruTail!.lruNext = e;
    lruTail = e;
  }

  void touch(_CacheEntry<T> e) {
    if (identical(e, lruTail)) return;
    final p = e.lruPrev;
    final n = e.lruNext;
    if (p != null) p.lruNext = n;
    if (n != null) n.lruPrev = p;
    if (identical(e, lruHead)) lruHead = n;

    e.lruPrev = lruTail;
    e.lruNext = null;
    if (lruTail != null) lruTail!.lruNext = e;
    lruTail = e;
    lruHead ??= e;
  }

  void detach(_CacheEntry<T> e) {
    final p = e.lruPrev;
    final n = e.lruNext;
    if (p != null) p.lruNext = n;
    if (n != null) n.lruPrev = p;
    if (identical(e, lruHead)) lruHead = n;
    if (identical(e, lruTail)) lruTail = p;
    e.lruPrev = null;
    e.lruNext = null;
  }
}

// -------------------- Internal: B+Tree (high fanout) --------------------

abstract class _BPlusNode<K, V> {
  bool get isLeaf;
}

final class _BPlusLeaf<K, V> extends _BPlusNode<K, V> {
  @override
  bool get isLeaf => true;

  final List<K> keys = <K>[];
  final List<V> values = <V>[];
  _BPlusLeaf<K, V>? next;
  _BPlusLeaf<K, V>? prev;
}

final class _BPlusInternal<K, V> extends _BPlusNode<K, V> {
  @override
  bool get isLeaf => false;

  final List<K> keys = <K>[];
  final List<_BPlusNode<K, V>> children = <_BPlusNode<K, V>>[];
}

final class _BPlusTree<K, V> {
  final int order; // max children per internal node
  final Comparator<K> compare;
  final bool rebalanceOnDelete;

  // Scratch buffers to avoid per-op allocations on hot paths.
  final List<_BPlusInternal<K, V>> _scratchPath = <_BPlusInternal<K, V>>[];
  final List<int> _scratchIdxPath = <int>[];

  late final int _maxKeys;
  late final int _minLeafKeys;
  late final int _minInternalChildren;

  _BPlusNode<K, V> _root = _BPlusLeaf<K, V>();
  int _length = 0;

  // Prepared insert state (set by [findForInsert], consumed by [insertPrepared]).
  _BPlusLeaf<K, V>? _preparedLeaf;
  int _preparedPos = 0;
  bool _preparedNeedPath = false;
  bool _preparedValid = false;

  // Finger (sequential) optimization for hot get/contains loops.
  _BPlusLeaf<K, V>? _fingerLeaf;
  K? _fingerKey;

  _BPlusTree({
    required this.order,
    required this.compare,
    this.rebalanceOnDelete = false,
  }) {
    if (order < 4) {
      throw ArgumentError.value(order, 'order', 'must be >= 4');
    }
    _maxKeys = order - 1;
    _minLeafKeys = (_maxKeys + 1) ~/ 2;
    _minInternalChildren = (order + 1) ~/ 2;
  }

  int get length => _length;

  bool containsKey(K key) {
    // Fast path: finger search without value retrieval or LRU updates.
    final fingerLeaf = _fingerLeaf;
    final fingerKey = _fingerKey;
    if (fingerLeaf != null && fingerKey != null) {
      final fk = fingerLeaf.keys;
      if (fk.isNotEmpty && compare(fingerKey, key) <= 0) {
        // Try current finger leaf.
        final last = fk.last;
        if (compare(key, last) <= 0) {
          final idx = _lowerBound(fk, key);
          _fingerKey = key;
          if (idx < fk.length && compare(fk[idx], key) == 0) {
            return true;
          }
          return false;
        }

        // Try one hop to next leaf.
        final next = fingerLeaf.next;
        if (next != null && next.keys.isNotEmpty) {
          final nk = next.keys;
          if (compare(key, nk.last) <= 0) {
            final idx = _lowerBound(nk, key);
            _fingerLeaf = next;
            _fingerKey = key;
            if (idx < nk.length && compare(nk[idx], key) == 0) {
              return true;
            }
            return false;
          }
        }
      }
    }

    var node = _root;
    while (!node.isLeaf) {
      final inl = node as _BPlusInternal<K, V>;
      final idx = _childIndex(inl.keys, key);
      node = inl.children[idx];
    }
    final leaf = node as _BPlusLeaf<K, V>;
    final idx = _lowerBound(leaf.keys, key);
    _fingerLeaf = leaf;
    _fingerKey = key;
    return idx < leaf.keys.length && compare(leaf.keys[idx], key) == 0;
  }

  V? get(K key) {
    // Fast path: finger search for monotonic forward access patterns.
    final fingerLeaf = _fingerLeaf;
    final fingerKey = _fingerKey;
    if (fingerLeaf != null && fingerKey != null) {
      final fk = fingerLeaf.keys;
      if (fk.isNotEmpty && compare(fingerKey, key) <= 0) {
        // Try current finger leaf (most common case: sequential gets).
        final last = fk.last;
        if (compare(key, last) <= 0) {
          final idx = _lowerBound(fk, key);
          _fingerKey = key;
          if (idx < fk.length && compare(fk[idx], key) == 0) {
            return fingerLeaf.values[idx];
          }
          return null;
        }

        // Try one hop to next leaf (handles boundary crossing).
        final next = fingerLeaf.next;
        if (next != null && next.keys.isNotEmpty) {
          final nk = next.keys;
          if (compare(key, nk.last) <= 0) {
            final idx = _lowerBound(nk, key);
            _fingerLeaf = next;
            _fingerKey = key;
            if (idx < nk.length && compare(nk[idx], key) == 0) {
              return next.values[idx];
            }
            return null;
          }
        }
      }
    }

    var node = _root;
    while (!node.isLeaf) {
      final inl = node as _BPlusInternal<K, V>;
      final idx = _childIndex(inl.keys, key);
      node = inl.children[idx];
    }
    final leaf = node as _BPlusLeaf<K, V>;
    final idx = _lowerBound(leaf.keys, key);
    _fingerLeaf = leaf;
    _fingerKey = key;
    if (idx < leaf.keys.length && compare(leaf.keys[idx], key) == 0) {
      return leaf.values[idx];
    }
    return null;
  }

  void put(K key, V value) {
    // Fast path: finger-based locality for monotonic inserts/updates.
    final fingerLeaf = _fingerLeaf;
    final fingerKey = _fingerKey;
    _BPlusLeaf<K, V>? leaf;
    int? pos;

    if (fingerLeaf != null && fingerKey != null) {
      final fk = fingerLeaf.keys;
      if (fk.isNotEmpty && compare(fingerKey, key) <= 0) {
        // Try current finger leaf.
        // CHANGE: Handle append case (key > last).
        // If key <= last, we are inside.
        // If key > last, we might be appending to this leaf IF
        if (fk.isNotEmpty && compare(fingerKey, key) <= 0) {
          // Try current finger leaf.
          if (compare(key, fk.last) <= 0) {
            final idx = _lowerBound(fk, key);
            if (idx < fk.length && compare(fk[idx], key) == 0) {
              fingerLeaf.values[idx] = value;
              _fingerLeaf = fingerLeaf;
              _fingerKey = key;
              return;
            }
            leaf = fingerLeaf;
            pos = idx;
          } else {
            // Try one hop to next leaf.
            final next = fingerLeaf.next;
            if (next != null && next.keys.isNotEmpty) {
              final nextFirst = next.keys.first;
              // If key < nextFirst, we append to current leaf (or split current leaf).
              if (compare(key, nextFirst) < 0) {
                leaf = fingerLeaf;
                pos = fk.length;
              } else {
                // key >= nextFirst. Try next leaf.
                final nk = next.keys;
                if (nk.isNotEmpty && compare(key, nk.last) <= 0) {
                  pos = _lowerBound(nk, key);
                  if (pos < nk.length && compare(nk[pos], key) == 0) {
                    next.values[pos] = value;
                    _fingerLeaf = next;
                    _fingerKey = key;
                    return;
                  }
                  leaf = next;
                } else {
                  // Even > next.last.
                  // If next is rightmost, we append to next.
                  if (next.next == null ||
                      (next.next!.keys.isNotEmpty &&
                          compare(key, next.next!.keys.first) < 0)) {
                    leaf = next;
                    pos = nk.length;
                  }
                }
              }
            } else {
              // No next leaf (or empty), so we append to current.
              leaf = fingerLeaf;
              pos = fk.length;
            }
          }
        }
      }
    }

    // Fallback: full descent.
    if (leaf == null || pos == null) {
      var node = _root;
      while (!node.isLeaf) {
        final inl = node as _BPlusInternal<K, V>;
        final idx = _childIndex(inl.keys, key);
        node = inl.children[idx];
      }
      leaf = node as _BPlusLeaf<K, V>;
      pos = _lowerBound(leaf.keys, key);
    }

    final leafFinal = leaf;
    final posFinal = pos;

    if (posFinal < leafFinal.keys.length &&
        compare(leafFinal.keys[posFinal], key) == 0) {
      leafFinal.values[posFinal] = value;
      _fingerLeaf = leafFinal;
      _fingerKey = key;
      return;
    }

    final bool willOverflow = leafFinal.keys.length >= _maxKeys;
    final bool needMinUpdate = posFinal == 0 && !identical(_root, leafFinal);

    if (!willOverflow && !needMinUpdate) {
      if (posFinal == leafFinal.keys.length) {
        leafFinal.keys.add(key);
        leafFinal.values.add(value);
      } else {
        leafFinal.keys.insert(posFinal, key);
        leafFinal.values.insert(posFinal, value);
      }
      _length++;
      _fingerLeaf = leafFinal;
      _fingerKey = key;
      return;
    }

    // Slow path with stacks for correctness when split/min-update is required.
    _scratchPath.clear();
    _scratchIdxPath.clear();
    final leaf2 = _findLeaf(key, path: _scratchPath, idxPath: _scratchIdxPath);
    final pos2 = _lowerBound(leaf2.keys, key);
    if (pos2 < leaf2.keys.length && compare(leaf2.keys[pos2], key) == 0) {
      leaf2.values[pos2] = value;
      _fingerLeaf = leaf2;
      _fingerKey = key;
      return;
    }

    if (pos2 == leaf2.keys.length) {
      leaf2.keys.add(key);
      leaf2.values.add(value);
    } else {
      leaf2.keys.insert(pos2, key);
      leaf2.values.insert(pos2, value);
    }
    _length++;
    _fingerLeaf = leaf2;
    _fingerKey = key;

    if (pos2 == 0) {
      _refreshAncestorsMinKey(path: _scratchPath, idxPath: _scratchIdxPath);
    }

    if (leaf2.keys.length > _maxKeys) {
      _splitLeaf(leaf2, path: _scratchPath, idxPath: _scratchIdxPath);
    }
  }

  /// Locate [key] and prepare for a potential insert.
  ///
  /// - If found, returns the existing value.
  /// - If not found, returns null and stores a cheap insertion hint used by [insertPrepared].
  V? findForInsert(K key) {
    // Fast path: finger-based locality for monotonic inserts/updates.
    final fingerLeaf = _fingerLeaf;
    final fingerKey = _fingerKey;
    if (fingerLeaf != null && fingerKey != null) {
      final fk = fingerLeaf.keys;
      if (fk.isNotEmpty && compare(fingerKey, key) <= 0) {
        // Try current finger leaf.
        if (compare(key, fk.last) <= 0) {
          final pos = _lowerBound(fk, key);
          _preparedLeaf = fingerLeaf;
          _preparedPos = pos;
          _preparedNeedPath = fk.length >= _maxKeys ||
              (pos == 0 && !identical(_root, fingerLeaf));
          _preparedValid = true;
          _fingerKey = key;
          if (pos < fk.length && compare(fk[pos], key) == 0) {
            return fingerLeaf.values[pos];
          }
          return null;
        }

        // Try one hop to next leaf or append.
        final next = fingerLeaf.next;
        if (next != null && next.keys.isNotEmpty) {
          final nextFirst = next.keys.first;
          if (compare(key, nextFirst) < 0) {
            // Append to current fingerLeaf
            _preparedLeaf = fingerLeaf;
            _preparedPos = fk.length;
            _preparedNeedPath = fk.length >=
                _maxKeys; // Appending never updates min key unless we split
            _preparedValid = true;
            _fingerKey = key;
            return null;
          }

          final nk = next.keys;
          if (compare(key, nk.last) <= 0) {
            final pos = _lowerBound(nk, key);
            _preparedLeaf = next;
            _preparedPos = pos;
            _preparedNeedPath =
                nk.length >= _maxKeys || (pos == 0 && !identical(_root, next));
            _preparedValid = true;
            _fingerLeaf = next;
            _fingerKey = key;
            if (pos < nk.length && compare(nk[pos], key) == 0) {
              return next.values[pos];
            }
            return null;
          } else {
            // Check if appending to next?
            if (next.next == null ||
                (next.next!.keys.isNotEmpty &&
                    compare(key, next.next!.keys.first) < 0)) {
              _preparedLeaf = next;
              _preparedPos = nk.length;
              _preparedNeedPath = nk.length >= _maxKeys;
              _preparedValid = true;
              _fingerLeaf = next;
              _fingerKey = key;
              return null;
            }
          }
        } else {
          // No next leaf, so append to current!
          _preparedLeaf = fingerLeaf;
          _preparedPos = fk.length;
          _preparedNeedPath = fk.length >= _maxKeys;
          _preparedValid = true;
          _fingerKey = key;
          return null;
        }
      }
    }

    var node = _root;
    while (!node.isLeaf) {
      final inl = node as _BPlusInternal<K, V>;
      final idx = _childIndex(inl.keys, key);
      node = inl.children[idx];
    }
    final leaf = node as _BPlusLeaf<K, V>;
    final pos = _lowerBound(leaf.keys, key);

    _preparedLeaf = leaf;
    _preparedPos = pos;
    _preparedNeedPath =
        leaf.keys.length >= _maxKeys || (pos == 0 && !identical(_root, leaf));
    _preparedValid = true;
    _fingerLeaf = leaf;
    _fingerKey = key;

    if (pos < leaf.keys.length && compare(leaf.keys[pos], key) == 0) {
      return leaf.values[pos];
    }
    return null;
  }

  /// Insert [value] for [key] using the last hint from [findForInsert].
  ///
  /// This avoids a second full tree search for the common case (no split, no min-key update).
  void insertPrepared(K key, V value) {
    if (!_preparedValid || _preparedLeaf == null) {
      put(key, value);
      return;
    }

    final leaf = _preparedLeaf!;
    final pos = _preparedPos;
    _preparedValid = false;

    if (!_preparedNeedPath) {
      if (pos == leaf.keys.length) {
        leaf.keys.add(key);
        leaf.values.add(value);
      } else {
        leaf.keys.insert(pos, key);
        leaf.values.insert(pos, value);
      }
      _length++;
      _fingerLeaf = leaf;
      _fingerKey = key;
      return;
    }

    // Slow path: we need parent path (split or min-key update). Use scratch buffers.
    _scratchPath.clear();
    _scratchIdxPath.clear();
    final leaf2 = _findLeaf(key, path: _scratchPath, idxPath: _scratchIdxPath);
    final pos2 = _lowerBound(leaf2.keys, key);
    if (pos2 < leaf2.keys.length && compare(leaf2.keys[pos2], key) == 0) {
      // Race-safe fallback: treat as overwrite.
      leaf2.values[pos2] = value;
      return;
    }

    if (pos2 == leaf2.keys.length) {
      leaf2.keys.add(key);
      leaf2.values.add(value);
    } else {
      leaf2.keys.insert(pos2, key);
      leaf2.values.insert(pos2, value);
    }
    _length++;
    _fingerLeaf = leaf2;
    _fingerKey = key;

    if (pos2 == 0 && _scratchPath.isNotEmpty) {
      _refreshAncestorsMinKey(path: _scratchPath, idxPath: _scratchIdxPath);
    }

    if (leaf2.keys.length > _maxKeys) {
      _splitLeaf(leaf2, path: _scratchPath, idxPath: _scratchIdxPath);
    }
  }

  V? remove(K key) {
    if (!rebalanceOnDelete) {
      // [Optimization] Lazy delete: do not rebalance or update separators.
      // Separator keys can safely remain stale-smaller after deletions (min key only increases),
      // and we refresh separators on insert-at-front paths.
      final fingerLeaf = _fingerLeaf;
      final fingerKey = _fingerKey;
      if (fingerLeaf != null && fingerKey != null) {
        final fk = fingerLeaf.keys;
        if (fk.isNotEmpty && compare(fingerKey, key) <= 0) {
          // Try current finger leaf.
          if (compare(key, fk.last) <= 0) {
            final idx = _lowerBound(fk, key);
            _fingerKey = key;
            if (idx < fk.length && compare(fk[idx], key) == 0) {
              // Optimize removal based on position.
              final values = fingerLeaf.values;
              final removedValue = values[idx];

              // Always use removeAt to maintain sorted order (critical for binary search).
              // The previous swap-then-removeLast optimization broke B+Tree invariant.
              if (idx == fk.length - 1) {
                fk.removeLast();
                values.removeLast();
              } else {
                fk.removeAt(idx);
                values.removeAt(idx);
              }
              _length--;
              // Clear finger to avoid pointing to deleted entry.
              _fingerLeaf = null;
              _fingerKey = null;
              return removedValue;
            }
            return null;
          }

          // Try one hop to next leaf.
          final next = fingerLeaf.next;
          if (next != null && next.keys.isNotEmpty) {
            final nk = next.keys;
            if (compare(key, nk.last) <= 0) {
              final idx = _lowerBound(nk, key);
              _fingerLeaf = next;
              _fingerKey = key;
              if (idx < nk.length && compare(nk[idx], key) == 0) {
                final values = next.values;
                final removedValue = values[idx];

                // Always use removeAt to maintain sorted order (critical for binary search).
                if (idx == nk.length - 1) {
                  nk.removeLast();
                  values.removeLast();
                } else {
                  nk.removeAt(idx);
                  values.removeAt(idx);
                }
                _length--;
                // Clear finger to avoid pointing to deleted entry.
                _fingerLeaf = null;
                _fingerKey = null;
                return removedValue;
              }
              return null;
            }
          }
        }
      }

      var node = _root;
      while (!node.isLeaf) {
        final inl = node as _BPlusInternal<K, V>;
        final idx = _childIndex(inl.keys, key);
        node = inl.children[idx];
      }
      final leaf = node as _BPlusLeaf<K, V>;

      final pos = _lowerBound(leaf.keys, key);
      if (pos >= leaf.keys.length || compare(leaf.keys[pos], key) != 0) {
        return null;
      }

      // Removal strategy:
      // - End: removeLast (O(1))
      // - Other positions: removeAt to preserve sorted order (required for binary search)
      final keys = leaf.keys;
      final values = leaf.values;
      final removedValue = values[pos];

      // Always use removeAt to maintain sorted order (critical for binary search).
      // The previous swap-then-removeLast optimization broke the B+Tree sorted invariant,
      // causing _lowerBound to return wrong indices and get() to miss existing entries.
      if (pos == keys.length - 1) {
        keys.removeLast();
        values.removeLast();
      } else {
        keys.removeAt(pos);
        values.removeAt(pos);
      }

      _length--;
      // Clear finger to avoid pointing to deleted entry.
      // Update to a valid key if leaf still has entries, otherwise clear.
      if (keys.isNotEmpty) {
        _fingerLeaf = leaf;
        _fingerKey =
            pos > 0 ? keys[math.min(pos - 1, keys.length - 1)] : keys.first;
      } else {
        _fingerLeaf = null;
        _fingerKey = null;
      }
      return removedValue;
    }

    // Strict delete path (keeps tree dense; higher CPU cost).
    _scratchPath.clear();
    _scratchIdxPath.clear();
    final leaf = _findLeaf(key, path: _scratchPath, idxPath: _scratchIdxPath);

    final pos = _lowerBound(leaf.keys, key);
    if (pos >= leaf.keys.length || compare(leaf.keys[pos], key) != 0) {
      return null;
    }

    // Optimize removal: same strategy as lazy delete path.
    final keys = leaf.keys;
    final values = leaf.values;
    final removedValue = values[pos];

    // Always use removeAt to maintain sorted order (critical for binary search).
    if (pos == keys.length - 1) {
      keys.removeLast();
      values.removeLast();
    } else {
      keys.removeAt(pos);
      values.removeAt(pos);
    }
    _length--;

    // Clear finger to avoid pointing to deleted entry.
    if (keys.isNotEmpty) {
      _fingerLeaf = leaf;
      _fingerKey =
          pos > 0 ? keys[math.min(pos - 1, keys.length - 1)] : keys.first;
    } else {
      _fingerLeaf = null;
      _fingerKey = null;
    }

    if (identical(_root, leaf)) {
      return removedValue;
    }

    // If we removed the smallest key of this leaf, the subtree minimum may change.
    // We must refresh separators up the path (not only the direct parent) to keep
    // navigation correct when the affected leaf is in a non-leftmost subtree.
    if (pos == 0 && leaf.keys.isNotEmpty) {
      _refreshAncestorsMinKey(path: _scratchPath, idxPath: _scratchIdxPath);
    }

    if (leaf.keys.length < _minLeafKeys) {
      _rebalanceLeaf(leaf, path: _scratchPath, idxPath: _scratchIdxPath);
    }

    return removedValue;
  }

  Future<void> scanRange(
    K start,
    K? end, {
    bool reverse = false,
    int? limit,
    required bool Function(K key, V value) onEntry,
    YieldController? yieldController,
  }) async {
    if (_length <= 0) return;
    if (limit != null && limit <= 0) return;

    if (!reverse) {
      final startPos = _seekLowerBound(start);
      var leaf = startPos.leaf;
      var i = startPos.index;
      int produced = 0;

      while (leaf != null) {
        // Snapshot keys and values to avoid concurrent modification issues (index shifts)
        // caused by background cleanup/eviction while yielding.
        final currentKeys = leaf.keys.toList(growable: false);
        final currentValues = leaf.values.toList(growable: false);
        final len = currentKeys.length;

        // Note: We use the local 'len' and snapshot lists.
        // Even if 'leaf' is concurrently modified (shrunk), we iterate our snapshot.
        while (i < len) {
          if (yieldController != null) {
            await yieldController.maybeYield();
          }

          final k = currentKeys[i];
          if (end != null && compare(k, end) > 0) return;
          final v = currentValues[i];
          if (!onEntry(k, v)) return;
          produced++;
          if (limit != null && produced >= limit) return;
          i++;
        }
        leaf = leaf.next;
        i = 0;
      }
      return;
    }

    // Reverse scan: start from end bound (or rightmost).
    final endPos = end == null ? _seekLast() : _seekLastLE(end);
    var leaf = endPos.leaf;
    var i = endPos.index;
    int produced = 0;

    while (leaf != null) {
      // Snapshot keys and values to avoid concurrent modification issues.
      final currentKeys = leaf.keys.toList(growable: false);
      final currentValues = leaf.values.toList(growable: false);

      // Clamp 'i' to the current snapshot length if the leaf was modified
      // between the seek and this snapshot (unlikely given sync seek, but safe).
      // Actually seek is sync, so i is valid for the leaf AT THAT MOMENT.
      // But if we loop: next iteration 'leaf = leaf.prev', we enter loop.
      // We snapshot. 'i' is 'leaf.keys.length - 1'.
      // If leaf grew/shrank?
      // For reverse, we calculate 'i' for standard iteration as length-1.
      // For the first leaf (found by seek), 'i' is derived from seek.

      // Safety check for the first leaf if concurrent modification happened (though unlikely to shrink exactly here)
      if (i >= currentKeys.length) {
        i = currentKeys.length - 1;
      }

      while (i >= 0) {
        if (yieldController != null) {
          await yieldController.maybeYield();
        }

        final k = currentKeys[i];
        if (compare(k, start) < 0) return;
        final v = currentValues[i];
        if (!onEntry(k, v)) return;
        produced++;
        if (limit != null && produced >= limit) return;
        i--;
      }
      leaf = leaf.prev;
      if (leaf == null) return;
      // For subsequent leaves, start at the end.
      // Note: We access leaf.keys.length directly here.
      // Strictly speaking, we should snapshot first, then set i = len - 1.
      // But we set i here, then loop loops back to snapshot.
      // So 'leaf.keys.length' might be unstable?
      // Better to set i = -1 (flag) and handle "start at end" inside the loop?
      // Or just accept that 'i' is just an initial capacity guess and we re-clamp?
      // Let's rely on snapshot.length in the next iteration.
      i = leaf.keys.length - 1;
    }
  }

  // -------------------- Internal: navigation --------------------

  _BPlusLeaf<K, V> _findLeaf(
    K key, {
    required List<_BPlusInternal<K, V>> path,
    required List<int> idxPath,
  }) {
    var node = _root;
    while (!node.isLeaf) {
      final inl = node as _BPlusInternal<K, V>;
      final idx = _childIndex(inl.keys, key);
      path.add(inl);
      idxPath.add(idx);
      node = inl.children[idx];
    }
    return node as _BPlusLeaf<K, V>;
  }

  int _childIndex(List<K> keys, K key) {
    // Upper-bound: first keys[mid] > key
    int lo = 0;
    int hi = keys.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (compare(keys[mid], key) <= 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  int _lowerBound(List<K> keys, K key) {
    int lo = 0;
    int hi = keys.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (compare(keys[mid], key) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  ({_BPlusLeaf<K, V>? leaf, int index}) _seekLowerBound(K key) {
    final path = <_BPlusInternal<K, V>>[];
    final idxPath = <int>[];
    final leaf = _findLeaf(key, path: path, idxPath: idxPath);
    final idx = _lowerBound(leaf.keys, key);
    if (idx < leaf.keys.length) {
      return (leaf: leaf, index: idx);
    }
    return (leaf: leaf.next, index: 0);
  }

  ({_BPlusLeaf<K, V>? leaf, int index}) _seekLast() {
    var node = _root;
    while (!node.isLeaf) {
      final inl = node as _BPlusInternal<K, V>;
      node = inl.children.last;
    }
    final leaf = node as _BPlusLeaf<K, V>;
    return (leaf: leaf, index: leaf.keys.length - 1);
  }

  ({_BPlusLeaf<K, V>? leaf, int index}) _seekLastLE(K key) {
    final path = <_BPlusInternal<K, V>>[];
    final idxPath = <int>[];
    final leaf = _findLeaf(key, path: path, idxPath: idxPath);
    int lo = 0;
    int hi = leaf.keys.length;
    // upperBound (<= key): first > key, then -1
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (compare(leaf.keys[mid], key) <= 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final idx = lo - 1;
    if (idx >= 0) return (leaf: leaf, index: idx);
    // Go to previous leaf.
    final prev = leaf.prev;
    if (prev == null) return (leaf: null, index: -1);
    return (leaf: prev, index: prev.keys.length - 1);
  }

  // -------------------- Internal: split --------------------

  void _splitLeaf(
    _BPlusLeaf<K, V> leaf, {
    required List<_BPlusInternal<K, V>> path,
    required List<int> idxPath,
  }) {
    final int mid = leaf.keys.length >> 1;
    final right = _BPlusLeaf<K, V>();
    right.keys.addAll(leaf.keys.sublist(mid));
    right.values.addAll(leaf.values.sublist(mid));
    leaf.keys.removeRange(mid, leaf.keys.length);
    leaf.values.removeRange(mid, leaf.values.length);

    // Link leaves.
    right.next = leaf.next;
    if (right.next != null) right.next!.prev = right;
    right.prev = leaf;
    leaf.next = right;

    final sepKey = right.keys.first;

    if (path.isEmpty) {
      final root = _BPlusInternal<K, V>();
      root.children.add(leaf);
      root.children.add(right);
      root.keys.add(sepKey);
      _root = root;
      return;
    }

    final parent = path.last;
    final int leafIdx = idxPath.last;
    parent.children.insert(leafIdx + 1, right);
    parent.keys.insert(leafIdx, sepKey);

    if (parent.keys.length > _maxKeys) {
      _splitInternal(parent, path: path, idxPath: idxPath);
    }
  }

  void _splitInternal(
    _BPlusInternal<K, V> node, {
    required List<_BPlusInternal<K, V>> path,
    required List<int> idxPath,
  }) {
    final int childrenLen = node.children.length;
    final int splitChildIndex = (childrenLen / 2).ceil();
    final K sepKey = node.keys[splitChildIndex - 1];

    final right = _BPlusInternal<K, V>();
    right.children.addAll(node.children.sublist(splitChildIndex));
    right.keys.addAll(node.keys.sublist(splitChildIndex));

    node.children.removeRange(splitChildIndex, node.children.length);
    node.keys.removeRange(splitChildIndex - 1, node.keys.length);

    if (path.length == 1) {
      // node is root
      final root = _BPlusInternal<K, V>();
      root.children.add(node);
      root.children.add(right);
      root.keys.add(sepKey);
      _root = root;
      return;
    }

    final parent = path[path.length - 2];
    final int nodeIdx = idxPath[idxPath.length - 2];
    parent.children.insert(nodeIdx + 1, right);
    parent.keys.insert(nodeIdx, sepKey);

    if (parent.keys.length > _maxKeys) {
      // Pop one level and continue.
      path.removeLast();
      idxPath.removeLast();
      _splitInternal(parent, path: path, idxPath: idxPath);
    }
  }

  // -------------------- Internal: delete rebalance --------------------

  void _rebalanceLeaf(
    _BPlusLeaf<K, V> leaf, {
    required List<_BPlusInternal<K, V>> path,
    required List<int> idxPath,
  }) {
    if (path.isEmpty) return;
    final parent = path.last;
    final int idx = idxPath.last;

    final _BPlusLeaf<K, V>? left =
        idx > 0 ? parent.children[idx - 1] as _BPlusLeaf<K, V>? : null;
    final _BPlusLeaf<K, V>? right = (idx + 1 < parent.children.length)
        ? parent.children[idx + 1] as _BPlusLeaf<K, V>?
        : null;

    // Borrow from left.
    if (left != null && left.keys.length > _minLeafKeys) {
      leaf.keys.insert(0, left.keys.removeLast());
      leaf.values.insert(0, left.values.removeLast());
      // Update separator for this leaf.
      parent.keys[idx - 1] = leaf.keys.first;
      return;
    }

    // Borrow from right.
    if (right != null && right.keys.length > _minLeafKeys) {
      leaf.keys.add(right.keys.removeAt(0));
      leaf.values.add(right.values.removeAt(0));
      // Update separator for right leaf.
      parent.keys[idx] = right.keys.first;
      return;
    }

    // Merge.
    if (left != null) {
      // Merge leaf into left.
      left.keys.addAll(leaf.keys);
      left.values.addAll(leaf.values);
      // Fix links.
      left.next = leaf.next;
      if (leaf.next != null) leaf.next!.prev = left;

      // Remove child + separator key.
      parent.children.removeAt(idx);
      parent.keys.removeAt(idx - 1);

      _rebalanceInternalAfterChildRemoved(path: path, idxPath: idxPath);
      return;
    }

    if (right != null) {
      // Merge right into leaf.
      leaf.keys.addAll(right.keys);
      leaf.values.addAll(right.values);
      leaf.next = right.next;
      if (right.next != null) right.next!.prev = leaf;

      parent.children.removeAt(idx + 1);
      parent.keys.removeAt(idx);

      _rebalanceInternalAfterChildRemoved(path: path, idxPath: idxPath);
    }
  }

  void _rebalanceInternalAfterChildRemoved({
    required List<_BPlusInternal<K, V>> path,
    required List<int> idxPath,
  }) {
    // Collapse root if needed.
    if (path.isEmpty) return;
    final parent = path.last;
    if (identical(parent, _root)) {
      if (parent.children.length == 1) {
        _root = parent.children.first;
      }
      return;
    }

    if (parent.children.length >= _minInternalChildren) return;

    // Rebalance internal node using B-tree rotation/merge.
    final grand = path[path.length - 2];
    final int parentIdx = idxPath[idxPath.length - 2];

    final left = parentIdx > 0
        ? grand.children[parentIdx - 1] as _BPlusInternal<K, V>?
        : null;
    final leftSepIdx = parentIdx - 1;
    final right = (parentIdx + 1 < grand.children.length)
        ? grand.children[parentIdx + 1] as _BPlusInternal<K, V>?
        : null;

    // Borrow from left.
    if (left != null && left.children.length > _minInternalChildren) {
      final borrowedChild = left.children.removeLast();
      final borrowedSep = left.keys.removeLast(); // min key of borrowed child

      final oldParentSep = grand.keys[leftSepIdx];
      // Parent receives borrowed child at front.
      parent.children.insert(0, borrowedChild);
      parent.keys.insert(0, oldParentSep);
      // Grand separator becomes borrowedSep.
      grand.keys[leftSepIdx] = borrowedSep;
      return;
    }

    // Borrow from right.
    if (right != null && right.children.length > _minInternalChildren) {
      final borrowedChild = right.children.removeAt(0);
      final newGrandSep = right.keys.removeAt(0);

      final oldGrandSep = grand.keys[parentIdx];
      parent.children.add(borrowedChild);
      parent.keys.add(oldGrandSep);
      grand.keys[parentIdx] = newGrandSep;
      return;
    }

    // Merge.
    if (left != null) {
      final sep = grand.keys[leftSepIdx];
      left.keys.add(sep);
      left.keys.addAll(parent.keys);
      left.children.addAll(parent.children);
      grand.children.removeAt(parentIdx);
      grand.keys.removeAt(leftSepIdx);

      // Pop one level and continue.
      path.removeLast();
      idxPath.removeLast();
      _rebalanceInternalAfterChildRemoved(path: path, idxPath: idxPath);
      return;
    }

    if (right != null) {
      final sep = grand.keys[parentIdx];
      parent.keys.add(sep);
      parent.keys.addAll(right.keys);
      parent.children.addAll(right.children);
      grand.children.removeAt(parentIdx + 1);
      grand.keys.removeAt(parentIdx);

      path.removeLast();
      idxPath.removeLast();
      _rebalanceInternalAfterChildRemoved(path: path, idxPath: idxPath);
    }
  }

  void _refreshAncestorsMinKey({
    required List<_BPlusInternal<K, V>> path,
    required List<int> idxPath,
  }) {
    // When a leaf's minimum key changes, update separators on the path.
    for (int level = path.length - 1; level >= 0; level--) {
      final parent = path[level];
      final int childIdx = idxPath[level];
      if (childIdx <= 0) continue;
      final child = parent.children[childIdx];
      final K? newMin = _minKeyOfNode(child);
      if (newMin == null) continue;
      parent.keys[childIdx - 1] = newMin;
    }
  }

  K? _minKeyOfNode(_BPlusNode<K, V> node) {
    var n = node;
    while (!n.isLeaf) {
      final inl = n as _BPlusInternal<K, V>;
      n = inl.children.first;
    }
    final leaf = n as _BPlusLeaf<K, V>;
    if (leaf.keys.isEmpty) return null;
    return leaf.keys.first;
  }
}
