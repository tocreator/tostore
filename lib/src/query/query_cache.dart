import 'dart:convert';
import 'dart:math';

import '../model/join_clause.dart';
import 'query_condition.dart';
import '../handler/logger.dart';

/// query cache
class QueryCache {
  final int _maxSize;
  final Map<String, CachedQuery> _cache = {};
  Map<String, CachedQuery> get cache => _cache;

  // Total cache size statistics (bytes)
  int _totalCacheSize = 0;

  // Get total cache size
  int get totalCacheSize => _totalCacheSize;

  QueryCache({
    int maxSize = 5000,
    Duration maxAge = const Duration(minutes: 10),
  }) : _maxSize = maxSize;

  /// get cache size
  int get size => _cache.length;

  /// get cached query results
  List<Map<String, dynamic>>? get(String key) {
    final cached = _cache[key];
    if (cached == null) return null;

    // Check if cache is expired
    if (cached.expiryTime != null &&
        DateTime.now().isAfter(cached.expiryTime!)) {
      // Cache is expired, remove it
      invalidate(
          key); // Use invalidate method to ensure total cache size is reduced
      return null;
    }

    // Record access time for cache eviction policy
    cached.lastAccessed = DateTime.now();
    return cached.results;
  }

  /// Estimate query result size
  int _estimateCacheEntrySize(List<Map<String, dynamic>> results) {
    // Basic size (CachedQuery object overhead)
    int size = 100;

    // Special handling for empty result set
    if (results.isEmpty) {
      return size;
    }

    // Sample calculation size (at most sample 10 records)
    int sampleSize = min(10, results.length);
    if (sampleSize > 0) {
      int totalSampleSize = 0;
      for (int i = 0; i < sampleSize; i++) {
        int index = (i * results.length ~/ sampleSize);
        // Use JSON serialization to estimate size
        totalSampleSize +=
            jsonEncode(results[index]).length * 2; // Unicode chars are 2 bytes
      }
      // Estimate total size: average size per record * number of records
      size += (totalSampleSize / sampleSize * results.length).round();
    }

    return size;
  }

  /// cache query results
  Future<void> put(String key, List<Map<String, dynamic>> results,
      String tableName, String primaryKeyField,
      {Duration? expiryDuration}) async {
    // Calculate new cache size
    int newEntrySize = _estimateCacheEntrySize(results);

    // If replacing existing cache, subtract old cache size
    if (_cache.containsKey(key)) {
      int oldSize = _estimateCacheEntrySize(_cache[key]!.results);
      _totalCacheSize -= oldSize;
    }

    if (_cache.length >= _maxSize) {
      // Find and remove the oldest cache entry by last access time
      MapEntry<String, CachedQuery>? oldest;
      int processedCount = 0;
      for (final entry in _cache.entries) {
        if (oldest == null ||
            entry.value.lastAccessed.isBefore(oldest.value.lastAccessed)) {
          oldest = entry;
        }
        processedCount++;
        if (processedCount % 500 == 0) {
          await Future.delayed(Duration.zero);
        }
      }

      if (oldest != null) {
        // Subtract removed cache size
        _totalCacheSize -= _estimateCacheEntrySize(oldest.value.results);
        _cache.remove(oldest.key);
      }
    }

    final now = DateTime.now();

    // Calculate expiry time if provided
    DateTime? expiryTime;
    if (expiryDuration != null) {
      expiryTime = now.add(expiryDuration);
    }

    _cache[key] = CachedQuery(
      results: results,
      timestamp: now,
      lastAccessed: now,
      expiryTime: expiryTime,
      tableName: tableName,
      primaryKeyField: primaryKeyField,
    );

    // Update total cache size
    _totalCacheSize += newEntrySize;
  }

  /// invalidate cache
  void invalidate(String key) {
    // Subtract removed cache size
    if (_cache.containsKey(key)) {
      _totalCacheSize -= _estimateCacheEntrySize(_cache[key]!.results);
    }

    _cache.remove(key);
  }

  /// invalidate a specific query
  /// returns 1 if removed, 0 if not found
  Future<int> invalidateQuery(String queryKey) async {
    if (_cache.containsKey(queryKey)) {
      // Subtract removed cache size
      _totalCacheSize -= _estimateCacheEntrySize(_cache[queryKey]!.results);

      _cache.remove(queryKey);
      return 1;
    }
    return 0;
  }

  /// clear all cache
  void clear() {
    _cache.clear();
    _totalCacheSize = 0; // Reset total cache size
  }

  /// Evict expired and least recently used entries to make room
  Future<void> evictStaleEntries() async {
    try {
      final now = DateTime.now();

      // First remove expired entries
      final expiredKeys = <String>[];
      _cache.forEach((key, value) {
        if (value.expiryTime != null && now.isAfter(value.expiryTime!)) {
          expiredKeys.add(key);
        }
      });

      for (final key in expiredKeys) {
        invalidate(
            key); // Use invalidate method to ensure total cache size is reduced
      }

      // If still over capacity, remove oldest entries
      if (_cache.length >= _maxSize) {
        // Use a bucket-based approach to avoid sorting, which is slow.
        // Group entries by access time into buckets.
        final buckets = <int, List<MapEntry<String, CachedQuery>>>{};
        final nowMs = now.millisecondsSinceEpoch;
        const oneHourMs = Duration.millisecondsPerSecond *
            Duration.secondsPerMinute *
            Duration.minutesPerHour;

        int processedCount = 0;
        for (final entry in _cache.entries) {
          final ageHours =
              (nowMs - entry.value.lastAccessed.millisecondsSinceEpoch) ~/
                  oneHourMs;
          buckets.putIfAbsent(ageHours, () => []).add(entry);
          processedCount++;
          if (processedCount % 500 == 0) {
            await Future.delayed(Duration.zero);
          }
        }

        final removeCount =
            (_cache.length * 0.2).ceil(); // Remove 20% of entries
        int removed = 0;

        final sortedBucketKeys = buckets.keys.toList()
          ..sort((a, b) => b.compareTo(a)); // Oldest first (largest ageHours)

        for (final key in sortedBucketKeys) {
          if (removed >= removeCount) break;
          final bucket = buckets[key]!;
          bucket.shuffle(); // Evict randomly within the same bucket

          for (final entry in bucket) {
            if (removed >= removeCount) break;
            invalidate(entry.key);
            removed++;
          }
        }

        Logger.debug(
          'Evicted $removed stale query cache entries, remaining: ${_cache.length}, total size: ${(_totalCacheSize / 1024).toStringAsFixed(1)}KB',
          label: 'QueryCache.evictStaleEntries',
        );
      }
    } catch (e) {
      Logger.error(
        'Error evicting stale query cache entries: $e',
        label: 'QueryCache.evictStaleEntries',
      );
    }
  }

  /// Evict specified number of entries
  /// [count] The number of entries to evict
  Future<void> evictByCount(int count) async {
    if (count <= 0 || _cache.isEmpty) return;

    try {
      // If count is greater than cache size, clear all
      if (count >= _cache.length) {
        final oldSize = _cache.length;
        clear(); // Use clear method to ensure total cache size is reset
        Logger.debug(
          'Cleared all $oldSize query cache entries',
          label: 'QueryCache.evictByCount',
        );
        return;
      }

      // Use a bucket-based approach to avoid sorting
      final buckets = <int, List<MapEntry<String, CachedQuery>>>{};
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      const oneHourMs = Duration.millisecondsPerSecond *
          Duration.secondsPerMinute *
          Duration.minutesPerHour;

      int processedCount = 0;
      for (final entry in _cache.entries) {
        final ageHours =
            (nowMs - entry.value.lastAccessed.millisecondsSinceEpoch) ~/
                oneHourMs;
        buckets.putIfAbsent(ageHours, () => []).add(entry);
        processedCount++;
        if (processedCount % 500 == 0) {
          await Future.delayed(Duration.zero);
        }
      }

      int removed = 0;
      final sortedBucketKeys = buckets.keys.toList()
        ..sort((a, b) => b.compareTo(a)); // Oldest first (largest age)

      for (final key in sortedBucketKeys) {
        if (removed >= count) break;
        final bucket = buckets[key]!;
        bucket.shuffle();

        for (final entry in bucket) {
          if (removed >= count) break;
          invalidate(entry.key);
          removed++;
        }
      }

      Logger.debug(
        'Evicted $removed query cache entries, remaining: ${_cache.length}, total size: ${(_totalCacheSize / 1024).toStringAsFixed(1)}KB',
        label: 'QueryCache.evictByCount',
      );
    } catch (e) {
      Logger.error(
        'Error evicting query cache entries: $e',
        label: 'QueryCache.evictByCount',
      );
    }
  }
}

/// cached query
class CachedQuery {
  final List<Map<String, dynamic>> results;
  final DateTime timestamp;
  DateTime lastAccessed;
  final DateTime? expiryTime;
  final String tableName;
  final String primaryKeyField;

  CachedQuery({
    required this.results,
    required this.timestamp,
    required this.lastAccessed,
    this.expiryTime,
    required this.tableName,
    required this.primaryKeyField,
  });
}

/// query cache key
class QueryCacheKey {
  final String tableName;
  final QueryCondition condition;
  final List<String>? orderBy;
  final int? limit;
  final int? offset;
  final List<JoinClause>? joins;

  /// whether the cache is user-managed
  /// true: user explicitly created through useQueryCache(), will not expire automatically
  /// false: system-created cache, will expire automatically when records are modified
  final bool isUserManaged;

  /// Cache the result of toString to avoid repeated calculation
  String? _cachedString;

  QueryCacheKey({
    required this.tableName,
    required this.condition,
    this.orderBy,
    this.limit,
    this.offset,
    this.joins,
    this.isUserManaged = false,
  });

  @override
  String toString() {
    // Use cached results to avoid repeated calculations
    if (_cachedString != null) {
      return _cachedString!;
    }

    try {
      // Uniformly generate cache keys for easier comparison and lookup
      final Map<String, dynamic> keyData = {
        'tableName': tableName,
        'condition': condition.build(),
        'isUserManaged': isUserManaged,
      };

      // Only add non-empty values to reduce complexity
      if (orderBy != null && orderBy!.isNotEmpty) keyData['orderBy'] = orderBy;
      if (limit != null) keyData['limit'] = limit;
      if (offset != null) keyData['offset'] = offset;

      if (joins != null && joins!.isNotEmpty) {
        keyData['joins'] = joins!
            .map((j) => {
                  'type': j.type.toString().split('.').last,
                  'table': j.table,
                  'firstKey': j.firstKey,
                  'operator': j.operator,
                  'secondKey': j.secondKey,
                })
            .toList();
      }

      // Use JSON to generate cache keys to ensure consistency
      _cachedString = jsonEncode(keyData);
      return _cachedString!;
    } catch (e) {
      // Final fallback option, ensure cache key can always be generated
      final fallbackKey =
          '$tableName-${condition.build()}-${DateTime.now().millisecondsSinceEpoch}';
      return fallbackKey;
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    // Use toString for comparison to ensure consistency
    // Because the toString() method already contains all key properties
    if (other is QueryCacheKey) {
      return toString() == other.toString();
    }
    return false;
  }

  @override
  int get hashCode {
    // Use consistent JSON structure to calculate hash values, ensure equivalent objects have the same hash
    final Map<String, dynamic> keyData = {
      'tableName': tableName,
      'condition': condition.build().toString(),
    };

    if (orderBy != null && orderBy!.isNotEmpty) keyData['orderBy'] = orderBy;
    if (limit != null) keyData['limit'] = limit;
    if (offset != null) keyData['offset'] = offset;
    if (isUserManaged) keyData['isUserManaged'] = true;

    if (joins != null && joins!.isNotEmpty) {
      keyData['joins'] = joins!
          .map((j) => {
                'type': j.type.toString(),
                'table': j.table,
                'firstKey': j.firstKey,
                'operator': j.operator,
                'secondKey': j.secondKey,
              })
          .toList();
    }

    return keyData.toString().hashCode;
  }
}
