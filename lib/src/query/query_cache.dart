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
      invalidate(key); // Use invalidate method to ensure total cache size is reduced
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
        totalSampleSize += jsonEncode(results[index]).length * 2; // Unicode chars are 2 bytes
      }
      // Estimate total size: average size per record * number of records
      size += (totalSampleSize / sampleSize * results.length).round();
    }
    
    return size;
  }

  /// cache query results
  void put(String key, List<Map<String, dynamic>> results, String tableName,
      String primaryKeyField,
      {Duration? expiryDuration}) {
    // Calculate new cache size
    int newEntrySize = _estimateCacheEntrySize(results);
    
    // If replacing existing cache, subtract old cache size
    if (_cache.containsKey(key)) {
      int oldSize = _estimateCacheEntrySize(_cache[key]!.results);
      _totalCacheSize -= oldSize;
    }
        
    if (_cache.length >= _maxSize) {
      // Find and remove the oldest cache entry by last access time
      final oldest = _cache.entries.reduce((a, b) =>
          a.value.lastAccessed.isBefore(b.value.lastAccessed) ? a : b);
      
      // Subtract removed cache size
      _totalCacheSize -= _estimateCacheEntrySize(oldest.value.results);
      
      _cache.remove(oldest.key);
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
  int invalidateQuery(String queryKey) {
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
  void evictStaleEntries() {
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
        invalidate(key); // Use invalidate method to ensure total cache size is reduced
      }

      // If still over capacity, remove oldest entries by last access time
      if (_cache.length >= _maxSize) {
        final sortedEntries = _cache.entries.toList()
          ..sort(
              (a, b) => a.value.lastAccessed.compareTo(b.value.lastAccessed));

        // Remove oldest entries until under capacity
        final removeCount =
            (_cache.length * 0.2).ceil(); // Remove 20% of entries
        for (int i = 0; i < removeCount && i < sortedEntries.length; i++) {
          invalidate(sortedEntries[i].key); // Use invalidate method to ensure total cache size is reduced
        }

        Logger.debug(
          'Evicted $removeCount stale query cache entries, remaining: ${_cache.length}, total size: ${(_totalCacheSize/1024).toStringAsFixed(1)}KB',
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
  void evictByCount(int count) {
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
      
      // Sort entries by last access time (oldest first)
      final sortedEntries = _cache.entries.toList()
        ..sort((a, b) => a.value.lastAccessed.compareTo(b.value.lastAccessed));
      
      // Remove the specified number of oldest entries
      int removed = 0;
      for (int i = 0; i < count && i < sortedEntries.length; i++) {
        invalidate(sortedEntries[i].key); // Use invalidate method to ensure total cache size is reduced
        removed++;
      }
      
      Logger.debug(
        'Evicted $removed query cache entries, remaining: ${_cache.length}, total size: ${(_totalCacheSize/1024).toStringAsFixed(1)}KB',
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
    return jsonEncode({
      'tableName': tableName,
      'condition': condition.build(),
      'orderBy': orderBy,
      'limit': limit,
      'offset': offset,
      'joins': joins
          ?.map((j) => {
                'type': j.type.toString().split('.').last,
                'table': j.table,
                'firstKey': j.firstKey,
                'operator': j.operator,
                'secondKey': j.secondKey,
              })
          .toList(),
      'isUserManaged': isUserManaged,
    });
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is QueryCacheKey &&
        other.tableName == tableName &&
        _conditionEquals(other.condition, condition) &&
        _listEquals(other.orderBy, orderBy) &&
        other.limit == limit &&
        other.offset == offset &&
        other.isUserManaged == isUserManaged &&
        _joinsEquals(other.joins, joins);
  }

  @override
  int get hashCode {
    return Object.hash(
      tableName,
      condition.build().toString(),
      orderBy?.join(','),
      limit,
      offset,
      isUserManaged,
      joins?.map((j) => j.toString()).join(';'),
    );
  }

  bool _conditionEquals(QueryCondition a, QueryCondition b) {
    return a.build().toString() == b.build().toString();
  }

  bool _listEquals(List? a, List? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  bool _joinsEquals(List<JoinClause>? a, List<JoinClause>? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;

    for (var i = 0; i < a.length; i++) {
      final joinA = a[i];
      final joinB = b[i];

      if (joinA.type != joinB.type ||
          joinA.table != joinB.table ||
          joinA.firstKey != joinB.firstKey ||
          joinA.operator != joinB.operator ||
          joinA.secondKey != joinB.secondKey) {
        return false;
      }
    }

    return true;
  }
}
