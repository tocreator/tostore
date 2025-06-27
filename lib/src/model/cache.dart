import 'dart:math';
import 'dart:convert';

/// table cache
class TableCache {
  final String tableName; // Table name
  final String primaryKeyField; // Primary key field name
  final Map<String, RecordCache>
      recordsMap; // Primary key value -> record cache mapping
  bool isFullTableCache; // Whether it's a complete table cache
  DateTime cacheTime; // Cache creation time
  DateTime lastAccessed; // Last access time

  // Cache statistics
  int _startupRecordCount = 0; // Startup cache record count
  int _runtimeRecordCount = 0; // Runtime cache record count

  // Total cache size statistics (bytes)
  int _totalCacheSize = 0;

  // Get total cache size
  int get totalCacheSize => _totalCacheSize;

  // Get all record data list (for compatibility)
  List<Map<String, dynamic>> get records =>
      recordsMap.values.map((rc) => rc.record).toList();

  TableCache({
    required this.tableName,
    required this.primaryKeyField,
    Map<String, RecordCache>? recordsMap,
    this.isFullTableCache = false,
    DateTime? cacheTime,
    DateTime? lastAccessed,
  })  : recordsMap = recordsMap ?? {},
        cacheTime = cacheTime ?? DateTime.now(),
        lastAccessed = lastAccessed ?? DateTime.now() {
    // Count records by type
    _updateRecordTypeCounts();

    // Initialize total cache size
    _recalculateTotalCacheSize();
  }

  /// Clears all records from the cache and resets the size counters.
  void clearRecords() {
    recordsMap.clear();
    _startupRecordCount = 0;
    _runtimeRecordCount = 0;
    // After clearing, reset the size to the base overhead of the TableCache object itself.
    _recalculateTotalCacheSize();
  }

  /// Recalculate total cache size (only used when initializing or resetting)
  void _recalculateTotalCacheSize() {
    _totalCacheSize = 0;

    // Table basic overhead
    _totalCacheSize += 120; // Basic object overhead

    // Record mapping overhead
    _totalCacheSize += recordsMap.length * 16; // Map entry overhead

    // Each record overhead
    for (final cache in recordsMap.values) {
      _totalCacheSize += cache.estimateMemoryUsage();
    }
  }

  /// Update record type counts
  void _updateRecordTypeCounts() {
    _startupRecordCount = 0;
    _runtimeRecordCount = 0;

    for (final cache in recordsMap.values) {
      if (cache.cacheType == RecordCacheType.startup) {
        _startupRecordCount++;
      } else {
        _runtimeRecordCount++;
      }
    }
  }

  /// Get cache record count
  int get recordCount => recordsMap.length;

  /// Get startup cache record count
  int get startupRecordCount => _startupRecordCount;

  /// Get runtime cache record count
  int get runtimeRecordCount => _runtimeRecordCount;

  /// Record table access
  void recordAccess() {
    lastAccessed = DateTime.now();
  }

  /// Add or update record
  RecordCache addOrUpdateRecord(
    Map<String, dynamic> record, {
    RecordCacheType cacheType = RecordCacheType.runtime,
  }) {
    final pkValue = record[primaryKeyField]?.toString() ?? '';
    if (pkValue.isEmpty) {
      throw ArgumentError('Record missing valid primary key: $primaryKeyField');
    }

    // Update if already exists
    if (recordsMap.containsKey(pkValue)) {
      final existingCache = recordsMap[pkValue]!;

      // Subtract old record size
      _totalCacheSize -= existingCache.estimateMemoryUsage();

      // Update record content
      existingCache.record.addAll(record);

      // Record access, update weight
      existingCache.recordAccess();

      // Add updated record size
      _totalCacheSize += existingCache.estimateMemoryUsage();

      return existingCache;
    } else {
      // Otherwise add new record
      final newCache = RecordCache(
        record: Map<String, dynamic>.from(record),
        primaryKeyValue: pkValue,
        cacheType: cacheType,
      );

      // Add new record size
      _totalCacheSize += newCache.estimateMemoryUsage();

      recordsMap[pkValue] = newCache;

      // Update statistics
      if (cacheType == RecordCacheType.startup) {
        _startupRecordCount++;
      } else {
        _runtimeRecordCount++;
      }

      // Add Map entry overhead (each new entry)
      _totalCacheSize += 16; // Map entry overhead

      return newCache;
    }
  }

  /// Batch add records
  Future<void> addRecords(
    List<Map<String, dynamic>> records, {
    RecordCacheType cacheType = RecordCacheType.runtime,
  }) async {

    int processedCount = 0;
    // Add records
    for (final record in records) {
      addOrUpdateRecord(record, cacheType: cacheType);
      processedCount++;
      if (processedCount % 500 == 0) {
        await Future.delayed(Duration.zero);
      }
    }
  }

  /// Get record and record access
  RecordCache? getRecord(String pkValue) {
    final cache = recordsMap[pkValue];
    if (cache != null) {
      cache.recordAccess();
      recordAccess();
    }
    return cache;
  }

  /// Get record content and record access
  Map<String, dynamic>? getRecordData(String pkValue) {
    final cache = getRecord(pkValue);
    return cache?.record;
  }

  /// Apply time decay to all records
  Future<void> applyTimeDecay() async {
    int processedCount = 0;
    for (final cache in recordsMap.values.toList()) {
      cache.applyTimeDecay();
      processedCount++;
      if (processedCount % 500 == 0) {
        await Future.delayed(Duration.zero);
      }
    }
  }

  /// Evict low priority records
  /// Returns the number of evicted records and freed memory
  Future<Map<String, int>> evictLowPriorityRecords(int count,
      {bool preserveStartupRecords =
          true // Whether to preserve startup cache records
      }) async {
    if (count <= 0 || recordsMap.isEmpty) {
      return {'count': 0, 'memory': 0};
    }

    // First apply time decay
    await applyTimeDecay();

    // Optimization: Use a bucket-based approach to avoid sorting all records,
    // which is very slow for large caches.
    final buckets = List.generate(11, (_) => <MapEntry<String, RecordCache>>[]);
    int processedCount = 0;
    for (final entry in recordsMap.entries.toList()) {
      final priority = entry.value.calculatePriority();
      final bucketIndex = (priority * 10).floor().clamp(0, 10);
      buckets[bucketIndex].add(entry);
      processedCount++;
      if (processedCount % 500 == 0) {
        await Future.delayed(Duration.zero);
      }
    }

    // Records to remove
    final keysToRemove = <String>[];
    int freedMemory = 0;
    int evictedCount = 0;

    // Evict from low priority buckets first
    for (int i = 0; i < buckets.length && evictedCount < count; i++) {
      final bucket = buckets[i];
      if (bucket.isEmpty) continue;

      // Shuffle to evict randomly from within the same priority bucket
      bucket.shuffle();

      for (final entry in bucket.toList()) {
        if (evictedCount >= count) break;

        final cache = entry.value;

        // Skip if we need to preserve startup cache records
        if (preserveStartupRecords &&
            cache.cacheType == RecordCacheType.startup) {
          continue;
        }

        keysToRemove.add(entry.key);
        freedMemory += cache.estimateMemoryUsage();
        evictedCount++;
        if (evictedCount % 500 == 0) {
          await Future.delayed(Duration.zero);
        }
      }
    }

    // Execute eviction
    processedCount = 0;
    for (final key in keysToRemove.toList()) {
      final cache = recordsMap.remove(key);
      if (cache != null) {
        if (cache.cacheType == RecordCacheType.startup) {
          _startupRecordCount--;
        } else {
          _runtimeRecordCount--;
        }

        // Subtract removed record size
        _totalCacheSize -= cache.estimateMemoryUsage();
        // Subtract Map entry overhead
        _totalCacheSize -= 16;
      }
      processedCount++;
      if (processedCount % 500 == 0) {
        await Future.delayed(Duration.zero);
      }
    }

    return {
      'count': keysToRemove.length,
      'memory': freedMemory,
    };
  }

  /// Estimate table cache memory usage
  int estimateMemoryUsage() {
    // Return incremental accumulated cache size
    return _totalCacheSize;
  }

  /// Statically estimates the memory size of a list of records using a sampling technique.
  static int estimateRecordsSize(List<Map<String, dynamic>> records) {
    if (records.isEmpty) return 0;

    // To maintain performance, we estimate the size based on a small sample of records.
    int sampleCount = min(10, records.length);
    if (sampleCount == 0) return 0;

    double totalSampleSize = 0;
    for (int i = 0; i < sampleCount; i++) {
      // Select records spread evenly across the list for a representative sample.
      final index = (i * records.length ~/ sampleCount);
      totalSampleSize += RecordCache.estimateRecordSize(records[index]);
    }

    final averageRecordSize = totalSampleSize / sampleCount;
    return (averageRecordSize * records.length).round();
  }

  /// Update record directly, without changing its position in the cache
  RecordCache updateRecord(Map<String, dynamic> record) {
    final pkValue = record[primaryKeyField]?.toString() ?? '';
    if (pkValue.isEmpty) {
      throw ArgumentError('Record missing valid primary key: $primaryKeyField');
    }

    // Check if the record exists
    if (recordsMap.containsKey(pkValue)) {
      final existingCache = recordsMap[pkValue]!;

      // Subtract old record size
      _totalCacheSize -= existingCache.estimateMemoryUsage();

      // Update record content (preserve original object reference)
      existingCache.record.clear(); // Clear old content
      existingCache.record.addAll(record); // Add new content

      // Record access, update weight
      existingCache.recordAccess();

      // Clear cache size estimate, will be recalculated next time accessed
      existingCache._cachedSize = -1;

      // Add updated record size
      _totalCacheSize += existingCache.estimateMemoryUsage();

      return existingCache;
    } else {
      // If the record does not exist, add a new record
      return addOrUpdateRecord(record);
    }
  }

  @override
  String toString() {
    final fullCacheStr = isFullTableCache ? 'complete' : 'partial';
    return 'TableCache{Table: $tableName, $fullCacheStr, Records: $recordCount, Startup: $_startupRecordCount, Runtime: $_runtimeRecordCount}';
  }
}

/// Cache type enum
enum RecordCacheType {
  /// Critical cache loaded at startup
  startup,

  /// Cache dynamically loaded at runtime
  runtime
}

/// Single record cache
class RecordCache {
  final Map<String, dynamic> record; // Record data
  final String primaryKeyValue; // Primary key value (for quick lookup)
  DateTime lastAccessed; // Last access time
  DateTime lastWeightUpdateDay; // Last day weight was updated
  int weightValue; // Weight value, range 0-10
  RecordCacheType cacheType; // Cache type: startup or runtime

  // Cache record size estimate
  int _cachedSize = -1;

  RecordCache({
    required this.record,
    required this.primaryKeyValue,
    DateTime? lastAccessed,
    DateTime? lastWeightUpdateDay,
    this.weightValue = 0, // Initial weight is 0
    this.cacheType = RecordCacheType.runtime,
  })  : lastWeightUpdateDay = lastWeightUpdateDay ?? DateTime.now(),
        lastAccessed = lastAccessed ?? DateTime.now();

  /// Record access and update weight
  void recordAccess() {
    final now = DateTime.now();
    lastAccessed = now;

    // Check if it's a new day
    final today = DateTime(now.year, now.month, now.day);
    final lastUpdateDay = DateTime(lastWeightUpdateDay.year,
        lastWeightUpdateDay.month, lastWeightUpdateDay.day);

    // If it's a new day, update weight
    if (today.isAfter(lastUpdateDay)) {
      // First calculate days passed, apply weight decay
      final daysPassed = today.difference(lastUpdateDay).inDays;

      // Weight decay, decrease by 1 per day, but not below 0
      weightValue = max(0, weightValue - daysPassed);

      // Today's access increases weight, but not above 10
      weightValue = min(10, weightValue + 1);

      // Update last weight update date
      lastWeightUpdateDay = today;
    }
  }

  /// Apply time decay (for periodic checks)
  void applyTimeDecay() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final lastUpdateDay = DateTime(lastWeightUpdateDay.year,
        lastWeightUpdateDay.month, lastWeightUpdateDay.day);

    // Calculate days without access
    final daysPassed = today.difference(lastUpdateDay).inDays;

    // Only decay if at least one day has passed without access
    if (daysPassed > 0) {
      // Weight decay, decrease by 1 per day, but not below 0
      weightValue = max(0, weightValue - daysPassed);

      // Update last weight update date to today (only update date, don't increase weight)
      lastWeightUpdateDay = today;
    }
  }

  /// Calculate record priority (0-1 range)
  double calculatePriority() {
    // First apply time decay, ensure weight is up-to-date
    applyTimeDecay();

    // Weight-based priority (0-1 range)
    final weightFactor = weightValue / 10.0;

    // Cache type weighting
    final typeFactor = cacheType == RecordCacheType.startup ? 0.3 : 0.0;

    // Additional time factor - further reduce priority for records not accessed for a very long time (beyond weight decay days)
    final daysUnaccessed = DateTime.now().difference(lastAccessed).inDays;
    final extraTimeFactor = daysUnaccessed > 10
        ? max(0.0, 1.0 - ((daysUnaccessed - 10) / 20.0))
        : 1.0;

    // Calculate combined priority
    return min(1.0, (weightFactor * 0.7 + typeFactor) * extraTimeFactor);
  }

  /// Estimate record memory usage (bytes)
  int estimateMemoryUsage() {
    // If cached size estimate is already available, return it
    if (_cachedSize >= 0) {
      return _cachedSize;
    }

    // Use the standardized static method for estimation and cache the result.
    _cachedSize = RecordCache.estimateRecordSize(record);
    return _cachedSize;
  }

  @override
  String toString() {
    return 'RecordCache{pk: $primaryKeyValue, weight: $weightValue, priority: ${calculatePriority().toStringAsFixed(2)}, type: $cacheType}';
  }

  /// Statically estimates the memory usage of a single record map in bytes.
  ///
  /// This method is the standardized logic for size estimation and is used across the cache system.
  /// It uses JSON serialization for a more accurate and efficient estimation.
  static int estimateRecordSize(Map<String, dynamic> record) {
    // Use JSON serialization to estimate size (more accurate and efficient)
    try {
      String jsonString = jsonEncode(record);
      // JSON string length * 2 (Unicode characters) + object overhead
      return jsonString.length * 2 + 80;
    } catch (e) {
      // If JSON serialization fails, fall back to a traditional, safer estimation method.
      int total = 80; // Approximate size of object header and basic fields
      for (var entry in record.entries) {
        total += entry.key.length * 2;
        var value = entry.value;
        if (value is String) {
          total += value.length * 2;
        } else if (value is num) {
          total += 8;
        } else if (value is bool) {
          total += 1;
        } else if (value is List) {
          total += 16 + value.length * 8;
        } else if (value is Map) {
          total += 16 + value.length * 16;
        } else {
          total += 8; // Default for other types
        }
      }
      return total;
    }
  }
}
