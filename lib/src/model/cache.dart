import 'dart:math';

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
  }

  /// Update record type counts
  void _updateRecordTypeCounts() {
    _startupRecordCount = 0;
    _runtimeRecordCount = 0;

    for (final cache in recordsMap.values) {
      if (cache.cacheType == CacheType.startup) {
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
    CacheType cacheType = CacheType.runtime,
  }) {
    final pkValue = record[primaryKeyField]?.toString() ?? '';
    if (pkValue.isEmpty) {
      throw ArgumentError('Record missing valid primary key: $primaryKeyField');
    }

    // Update if already exists
    if (recordsMap.containsKey(pkValue)) {
      final existingCache = recordsMap[pkValue]!;

      // Update record content
      existingCache.record.addAll(record);

      // Record access, update weight
      existingCache.recordAccess();

      return existingCache;
    } else {
      // Otherwise add new record
      final newCache = RecordCache(
        record: Map<String, dynamic>.from(record),
        primaryKeyValue: pkValue,
        cacheType: cacheType,
      );

      recordsMap[pkValue] = newCache;

      // Update statistics
      if (cacheType == CacheType.startup) {
        _startupRecordCount++;
      } else {
        _runtimeRecordCount++;
      }

      return newCache;
    }
  }

  /// Batch add records
  void addRecords(
    List<Map<String, dynamic>> records, {
    CacheType cacheType = CacheType.runtime,
  }) {
    for (final record in records) {
      addOrUpdateRecord(record, cacheType: cacheType);
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
  void applyTimeDecay() {
    for (final cache in recordsMap.values) {
      cache.applyTimeDecay();
    }
  }

  /// Evict low priority records
  /// Returns the number of evicted records and freed memory
  Map<String, int> evictLowPriorityRecords(int count,
      {bool preserveStartupRecords =
          true // Whether to preserve startup cache records
      }) {
    if (count <= 0 || recordsMap.isEmpty) {
      return {'count': 0, 'memory': 0};
    }

    // First apply time decay
    applyTimeDecay();

    // Calculate priority for all records and sort
    final sortedRecords = recordsMap.entries.toList()
      ..sort((a, b) =>
          a.value.calculatePriority().compareTo(b.value.calculatePriority()));

    // Records to remove
    final keysToRemove = <String>[];
    int freedMemory = 0;

    // Evict from low priority
    for (int i = 0; i < count && i < sortedRecords.length; i++) {
      final entry = sortedRecords[i];
      final cache = entry.value;

      // Skip if we need to preserve startup cache records
      if (preserveStartupRecords && cache.cacheType == CacheType.startup) {
        continue;
      }

      keysToRemove.add(entry.key);
      freedMemory += cache.estimateMemoryUsage();
    }

    // Execute eviction
    for (final key in keysToRemove) {
      final cache = recordsMap.remove(key);
      if (cache != null && cache.cacheType == CacheType.startup) {
        _startupRecordCount--;
      } else if (cache != null) {
        _runtimeRecordCount--;
      }
    }

    return {
      'count': keysToRemove.length,
      'memory': freedMemory,
    };
  }

  /// Estimate table cache memory usage
  int estimateMemoryUsage() {
    // Table basic overhead
    int total = 120; // Basic object overhead

    // Record map overhead
    total += recordsMap.length * 16; // Map entry overhead

    // Each record overhead
    for (final cache in recordsMap.values) {
      total += cache.estimateMemoryUsage();
    }

    return total;
  }

  @override
  String toString() {
    final fullCacheStr = isFullTableCache ? 'complete' : 'partial';
    return 'TableCache{Table: $tableName, $fullCacheStr, Records: $recordCount, Startup: $_startupRecordCount, Runtime: $_runtimeRecordCount}';
  }
}

/// Cache type enum
enum CacheType {
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
  CacheType cacheType; // Cache type: startup or runtime

  RecordCache({
    required this.record,
    required this.primaryKeyValue,
    DateTime? lastAccessed,
    DateTime? lastWeightUpdateDay,
    this.weightValue = 0, // Initial weight is 0
    this.cacheType = CacheType.runtime,
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
    final typeFactor = cacheType == CacheType.startup ? 0.3 : 0.0;

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
    // Basic object overhead
    int total = 80; // Approximate size of object header and basic fields

    // Calculate record content size
    for (var entry in record.entries) {
      // Key name overhead
      total += entry.key.length * 2;

      // Estimate value overhead based on type
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
        total += 8;
      }
    }

    return total;
  }

  @override
  String toString() {
    return 'RecordCache{pk: $primaryKeyValue, weight: $weightValue, priority: ${calculatePriority().toStringAsFixed(2)}, type: $cacheType}';
  }
}
