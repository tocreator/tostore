import 'dart:async';
import 'dart:collection';
import 'dart:math';

import '../core/compute_manager.dart';
import '../core/compute_tasks.dart';
import '../core/lock_manager.dart';
import '../handler/logger.dart';
import '../model/data_store_config.dart';
import '../model/table_identity.dart';
import '../model/table_schema.dart';
import 'db_exception.dart';
import 'result_status.dart';
import 'result_type.dart';

/// ID generator interface
abstract class IdGenerator {
  /// Unified ID retrieval method
  Future<List<String>> getId(int count, {int recentTotal = 0});

  /// Current remaining allocatable ID count
  int get remainingIds;

  /// Whether a new ID segment needs to be fetched
  bool get needsFetch;

  /// Request a new ID segment
  Future<bool> requestNewBatch();

  /// Generator type
  String get type;

  /// Purge cached IDs in pool that are <= actualMaxId, and advance internal counter if needed.
  void purgeIdsLessThanOrEqualTo(dynamic actualMaxId);
}

/// Sequential ID generator with ID pool pre-generation (lock-free consumption).
/// Only acquires lock when refilling pool; high concurrency gets IDs from queue.
class SequentialIdGenerator implements IdGenerator {
  final SequentialIdConfig config;
  final DistributedNodeConfig? nodeConfig;
  String? tableUid;
  final CentralServerClient? centralClient;

  int _currentId;
  int _maxId = 0;
  int _lastRequestTime = 0;
  final Random _random = Random(DateTime.now().millisecondsSinceEpoch);

  final Queue<String> _idPool = Queue<String>();
  Future<void>? _refillTask;

  int _recentRequestCount = 0;
  DateTime _lastCountResetTime = DateTime.now();

  static const int _minGenerateBatchSize = 100;
  static const Duration _recentWindow = Duration(seconds: 3);

  bool get isDistributed =>
      nodeConfig != null &&
      nodeConfig!.enableDistributed &&
      centralClient != null;

  SequentialIdGenerator(
    this.config, {
    this.nodeConfig,
    this.tableUid,
    this.centralClient,
  }) : _currentId = config.initialValue - 1 {
    _initializeGenerator();
    Future.microtask(() => _refillIdPool(_minGenerateBatchSize, 0));
  }

  void _initializeGenerator() {
    if (!isDistributed) {
      if (_currentId < config.initialValue - 1) {
        _currentId = config.initialValue - 1;
      }
    }
  }

  /// Request stats over last 3 seconds for pool size prediction.
  void _updateRequestStats(int count) {
    final now = DateTime.now();
    if (now.difference(_lastCountResetTime) > _recentWindow) {
      _recentRequestCount = count;
      _lastCountResetTime = now;
    } else {
      _recentRequestCount += count;
    }
  }

  /// Recent request count in last 3 seconds.
  int _getRecentRequestCount() {
    final now = DateTime.now();
    if (now.difference(_lastCountResetTime) > _recentWindow) {
      _recentRequestCount = 0;
      _lastCountResetTime = now;
      return 0;
    }
    return _recentRequestCount;
  }

  /// Predict next batch from recent 3s request count; pre-generate 2x to avoid over/under.
  int _calculateExpectedPoolSize(int recentTotal) {
    if (recentTotal <= 0) return _minGenerateBatchSize;
    return max((recentTotal * 2).ceil(), _minGenerateBatchSize);
  }

  Future<void> _refillIdPool(int targetCount, int recentTotal) async {
    if (_refillTask != null) {
      await _refillTask;
      if (_idPool.length >= targetCount) return;
    }

    final completer = Completer<void>();
    _refillTask = completer.future;

    try {
      final currentPoolSize = _idPool.length;
      if (currentPoolSize >= targetCount) return;

      final latestRecentTotal = _getRecentRequestCount();
      final expectedSize = _calculateExpectedPoolSize(latestRecentTotal);
      int neededCount = max(targetCount, expectedSize) - currentPoolSize;
      if (neededCount <= 0) return;

      int generated = 0;
      while (generated < neededCount) {
        if (isDistributed) {
          final minIncrement = config.useRandomIncrement ? 1 : config.increment;
          if (_currentId + minIncrement > _maxId) {
            if (!await requestNewBatch()) break;
          }
        }

        final increment = config.useRandomIncrement
            ? _random.nextInt(config.increment) + 1
            : config.increment;

        if (isDistributed && _currentId + increment > _maxId) {
          if (!await requestNewBatch()) break;
        }

        _currentId += increment;
        _idPool.add(_currentId.toString());
        generated++;
      }
    } catch (e) {
      Logger.error('SequentialIdGenerator refill failed', rawError: e);
    } finally {
      _refillTask = null;
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
  }

  @override
  Future<List<String>> getId(int count, {int recentTotal = 0}) async {
    if (count <= 0) return [];

    _updateRequestStats(count);

    // 1. Consume readily available IDs from pre-filled pool (pure synchronous, 0 block)
    final result = <String>[];
    while (result.length < count && _idPool.isNotEmpty) {
      result.add(_idPool.removeFirst());
    }

    if (result.length == count) {
      // Background proactive refill when pool drops below half batch size
      if (_idPool.length < _minGenerateBatchSize ~/ 2 && _refillTask == null) {
        unawaited(_refillIdPool(
            _calculateExpectedPoolSize(_getRecentRequestCount()), 0));
      }
      return result;
    }

    // 2. Pool empty or insufficient: synchronous refill to satisfy remainder
    final effectiveRecentTotal =
        recentTotal > 0 ? recentTotal : _getRecentRequestCount();
    final expectedPoolSize = _calculateExpectedPoolSize(effectiveRecentTotal);
    final targetSize = expectedPoolSize + (count - result.length);

    await _refillIdPool(targetSize, effectiveRecentTotal);

    while (result.length < count && _idPool.isNotEmpty) {
      result.add(_idPool.removeFirst());
    }

    if (result.isEmpty) {
      throw DbException([
        GeneralStatus(
          type: ResultType.sysTimeout,
          message:
              'SequentialIdGenerator: Pool empty and fill timeout. Request=$count, '
              'RefillInProgress=${_refillTask != null}, PoolSize=${_idPool.length}.',
        )
      ]);
    }
    return result;
  }

  @override
  int get remainingIds => _idPool.length;

  @override
  bool get needsFetch {
    if (!isDistributed) return false;
    final threshold = (10000 * nodeConfig!.idFetchThreshold).toInt();
    return _idPool.length < threshold;
  }

  @override
  Future<bool> requestNewBatch() async {
    if (!isDistributed) return true;

    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastRequestTime < 5000) return false;

      _lastRequestTime = now;

      final result = await centralClient!.requestIdBatch(
          tableUid: tableUid!, nodeId: nodeConfig!.nodeId, batchSize: 10000);

      if (result != null) {
        _currentId = result.startId - 1;
        _maxId = result.endId;
        return true;
      }
      return false;
    } catch (e) {
      Logger.error('Request ID segment failed', rawError: e);
      return false;
    }
  }

  @override
  String get type => isDistributed ? 'distributed-sequential' : 'sequential';

  void setCurrentId(int id) {
    _currentId = id;
  }

  void setIdRange(int currentId, int maxId) {
    _currentId = currentId;
    _maxId = maxId;
  }

  /// Current id position (for persistence/recovery). Last allocated id.
  int get currentId => _currentId;

  @override
  void purgeIdsLessThanOrEqualTo(dynamic actualMaxId) {
    if (actualMaxId == null) return;
    int maxInt;
    if (actualMaxId is int) {
      maxInt = actualMaxId;
    } else if (actualMaxId is String) {
      maxInt = int.tryParse(actualMaxId) ?? 0;
    } else {
      maxInt = 0;
    }

    if (maxInt <= 0) return;

    if (_currentId < maxInt) {
      _currentId = maxInt;
    }

    if (_idPool.isEmpty) return;

    // Check pool maximum (last element since queue is monotonically increasing)
    final poolLastStr = _idPool.last;
    final poolLastInt = int.tryParse(poolLastStr);
    if (poolLastInt != null && poolLastInt <= maxInt) {
      // Entire pool is stale, clear immediately in O(1)
      _idPool.clear();
      return;
    }

    // Otherwise, selectively discard stale head elements until head > maxInt
    while (_idPool.isNotEmpty) {
      final headStr = _idPool.first;
      final headInt = int.tryParse(headStr);
      if (headInt != null && headInt <= maxInt) {
        _idPool.removeFirst();
      } else {
        break;
      }
    }
  }
}

/// Base62 encoder (used for generating short code IDs)
class Base62Encoder {
  static const String _charset =
      '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

  /// Encode BigInt to Base62 string
  static String encode(BigInt value) {
    if (value < BigInt.zero) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Base62 encoding does not support negative numbers. Passed value: $value.',
        )
      ]);
    }
    if (value == BigInt.zero) {
      return '0';
    }

    String result = '';
    BigInt base = BigInt.from(62);
    BigInt remainder;

    while (value > BigInt.zero) {
      remainder = value % base;
      value = value ~/ base;
      result = _charset[remainder.toInt()] + result;
    }

    return result;
  }

  /// Encode BigInt to a fixed-length Base62 string
  static String encodeFixed(BigInt value, int length) {
    String result = encode(value);
    // If the length is insufficient, pad with 0 in front
    if (result.length < length) {
      result = _charset[0] * (length - result.length) + result;
    }
    return result;
  }

  /// Decode Base62 string to BigInt
  static BigInt decode(String value) {
    BigInt result = BigInt.zero;
    BigInt base = BigInt.from(62);
    BigInt power = BigInt.one;

    for (int i = value.length - 1; i >= 0; i--) {
      int digit = _charset.indexOf(value[i]);
      if (digit == -1) {
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message: 'Illegal Base62 character: ${value[i]} at index $i.',
          )
        ]);
      }
      result += BigInt.from(digit) * power;
      power *= base;
    }

    return result;
  }
}

/// Time-based ID generator
class TimeBasedIdGenerator implements IdGenerator {
  final PrimaryKeyType keyType; // timestampBased, datePrefixed or shortCode
  final DistributedNodeConfig nodeConfig;
  String tableUid;
  final String tableDisplayName;

  // Timestamp/date prefix ID generation related properties
  final Map<String, int> _sequenceMap =
      {}; // table name -> current sequence number
  final Map<String, dynamic> _lastValueMap =
      {}; // table name -> last timestamp/date string
  dynamic _lastValue; // last generated timestamp or date string
  final Random _random = Random.secure();

  // Lock manager - for handling concurrency
  final LockManager _lockManager = LockManager();

  // ID config constants
  static const int _maxSequence = 99999; // max sequence number (5 digits)

  // Logical timestamp starting point (Jan 1, 1984 00:00:00 UTC)
  static const int _epochStartSeconds = 441763200;

  // Number of digits for node ID (cache calculation result)
  late final int _nodeIdDigits;

  // Cache commonly used BigInt values to avoid repeated calculation
  late final BigInt _sequenceFactor;
  late final BigInt _powerFactor;
  late final BigInt? _nodeIdBig;

  // ID pool related fields - use Queue instead of List
  final Map<String, Queue<String>> _idPools = {};
  final Map<String, DateTime> _idPoolLastUpdateTime = {};
  final Map<String, bool> _idGenerationInProgress = {};

  // ID request statistics
  final Map<String, int> _recentRequestCount = {};
  final Map<String, DateTime> _lastCountResetTime = {};

  // ID pool config constants
  static const Duration _idPoolExpiry = Duration(minutes: 60);
  static const int _minGenerateBatchSize =
      100; // minimum batch generation count

  // Instance idle timeout recycling
  static const Duration _instanceIdleTimeout = Duration(
      minutes: 30); // recycle instance if idle for more than 30 minutes
  static final Map<String, DateTime> _lastInstanceAccessTime =
      {}; // record last access time of instance

  // Isolate batch generation control related properties
  bool _enableParallel = true; // Whether to enable parallel generation
  int _maxConcurrent = 4; // Maximum parallel count, default is 4
  static const int _minCountPerIsolate =
      100; // Minimum number of IDs to generate for each isolate

  // Static mapping for global access to all generator instances
  static final Map<String, TimeBasedIdGenerator> _instances = {};

  /// Clean up static states when a table is deleted to avoid memory leaks
  static void handleTableDelete(String tableUid) {
    final keysToRemove = <String>[];
    for (final key in _instances.keys) {
      if (key.endsWith('_$tableUid')) {
        keysToRemove.add(key);
      }
    }

    for (final key in keysToRemove) {
      _instances.remove(key);
      _lastInstanceAccessTime.remove(key);
    }
  }

  /// Get generator from instance map, create new instance if not exists
  static TimeBasedIdGenerator getInstance(
      PrimaryKeyType keyType, DistributedNodeConfig nodeConfig, String tableUid,
      {int? maxConcurrent, String? tableName}) {
    final key = '${keyType}_$tableUid';

    // If instance already exists, return directly
    if (_instances.containsKey(key)) {
      // Update last access time
      _lastInstanceAccessTime[key] = DateTime.now();

      // If parallel count is specified, update parallel settings of existing instance
      if (maxConcurrent != null && maxConcurrent > 0) {
        _instances[key]!
            .setParallelGeneration(true, maxConcurrent: maxConcurrent);
      }

      return _instances[key]!;
    }

    // Create new instance
    final generator = TimeBasedIdGenerator._(
      keyType,
      nodeConfig,
      tableUid,
      tableName ?? 'unknown',
    );

    // Set parallel count
    if (maxConcurrent != null && maxConcurrent > 0) {
      generator.setParallelGeneration(true, maxConcurrent: maxConcurrent);
    }

    _instances[key] = generator;
    _lastInstanceAccessTime[key] = DateTime.now();
    return generator;
  }

  // Make constructor private, force use of getInstance
  TimeBasedIdGenerator._(
    this.keyType,
    this.nodeConfig,
    this.tableUid,
    this.tableDisplayName,
  ) {
    // Check if keyType is a valid type
    if (keyType != PrimaryKeyType.timestampBased &&
        keyType != PrimaryKeyType.datePrefixed &&
        keyType != PrimaryKeyType.shortCode) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'keyType must be timestampBased, datePrefixed, or shortCode. Passed: $keyType.',
        )
      ]);
    }

    // Calculate and cache the number of digits for node ID
    _nodeIdDigits = _calculateNodeIdDigits(nodeConfig.nodeId);
    _initializeGenerator();
  }

  /// Set parallel generation parameters
  void setParallelGeneration(bool enable, {int? maxConcurrent}) {
    _enableParallel = enable;
    if (maxConcurrent != null && maxConcurrent > 0) {
      _maxConcurrent = maxConcurrent;
    }
  }

  /// Calculate the number of digits for node ID
  int _calculateNodeIdDigits(int nodeId) {
    if (nodeId == 0) return 1;
    int digits = 0;
    int temp = nodeId;
    while (temp > 0) {
      temp ~/= 10;
      digits++;
    }
    return digits;
  }

  /// Initialize generator
  void _initializeGenerator() {
    // Initialize different values according to ID type
    if (keyType == PrimaryKeyType.timestampBased ||
        keyType == PrimaryKeyType.shortCode) {
      _lastValue = _getCurrentLogicalTimestamp();
    } else {
      // datePrefixed
      _lastValue = _getCurrentDateString();
    }

    // Create separate sequence number count for table
    _sequenceMap[tableUid] = 0;
    _lastValueMap[tableUid] = _lastValue;

    // Ensure ID pool exists
    if (!_idPools.containsKey(tableUid)) {
      _idPools[tableUid] = Queue<String>();
    }

    // Initialize statistics
    _recentRequestCount[tableUid] = 0;
    _lastCountResetTime[tableUid] = DateTime.now();
    _idGenerationInProgress[tableUid] = false;

    // Precompute commonly used values
    _sequenceFactor = BigInt.from(100000); // 10^5

    if (nodeConfig.enableDistributed) {
      _powerFactor = BigInt.from(10).pow(_nodeIdDigits + 5);
      // Ensure node ID exists, use default value 1 if 0
      final nodeId = nodeConfig.nodeId > 0 ? nodeConfig.nodeId : 1;
      _nodeIdBig = BigInt.from(nodeId);
    } else {
      _powerFactor =
          _sequenceFactor; // use 10^5 as power factor in non-distributed mode
      _nodeIdBig = BigInt.from(1);
    }

    // Preheat ID pool - use microtask to ensure non-blocking initialization
    Future.microtask(() => _refillIdPool(100, 0));
  }

  /// Format IDs according to ID type
  List<String> _formatIds(List<BigInt> numericIds) {
    if (keyType == PrimaryKeyType.shortCode) {
      return numericIds.map((id) => _convertIdToShortCode(id)).toList();
    } else {
      return numericIds.map((id) => id.toString()).toList();
    }
  }

  /// Refill ID pool - the only entry point for all ID generation
  Future<void> _refillIdPool(int targetCount, int recentTotal) async {
    // Add duplicate fill check
    if (_idGenerationInProgress[tableUid] == true) {
      Logger.debug(
          'Skip duplicate ID pool fill request: $tableUid, fill task already running');
      return;
    }

    bool acquired = false;
    final lockResource = 'id_refill_$tableUid';
    final operationId = '${tableUid}_id_fill';
    try {
      // Mark generation task start - mark before acquiring lock to avoid duplicate requests
      _idGenerationInProgress[tableUid] = true;

      // Acquire lock to ensure only one thread is generating IDs at the same time

      acquired =
          await _lockManager.acquireExclusiveLock(lockResource, operationId);
      if (!acquired) {
        Logger.warn(
            'Failed to acquire exclusive lock for ID pool refill: $tableUid');
        return;
      }

      try {
        // Ensure ID pool exists
        if (!_idPools.containsKey(tableUid)) {
          _idPools[tableUid] = Queue<String>();
        }

        // Recheck pool size, it might have been filled by other threads while waiting for lock
        final currentPoolSize = _idPools[tableUid]!.length;
        if (currentPoolSize >= targetCount) {
          return; // Pool ID is enough
        }

        // Get latest request stats instead of using passed value to avoid multiple threads generating
        final latestRecentTotal = _getRecentRequestCount();
        final latestExpectedSize =
            _calculateExpectedPoolSize(latestRecentTotal);

        // Use latest obtained expected size and current pool size to recalculate the number of IDs to generate
        int neededCount =
            max(targetCount, latestExpectedSize) - currentPoolSize;

        if (neededCount <= 0) {
          return; // Pool ID is enough
        }

        // Record start time
        final startTime = DateTime.now();
        int totalGenerated = 0;

        // Offload a large ID batch to a single isolate only when it can
        // amortize isolate startup and message transfer overhead.
        final canUseIsolateBatch = _enableParallel &&
            _maxConcurrent > 0 &&
            neededCount >= _minCountPerIsolate * 2;

        if (canUseIsolateBatch) {
          // Generate one full batch in a single isolate to preserve
          // sequence semantics and avoid cross-task range overlap.
          final generatedIds =
              await _generateIdsInIsolateBatch(neededCount, latestRecentTotal);

          // Add generated IDs to ID pool
          if (generatedIds.isNotEmpty) {
            _idPools[tableUid]!.addAll(generatedIds);
            _idPoolLastUpdateTime[tableUid] = DateTime.now();

            totalGenerated = generatedIds.length;

            // Record performance data
            final duration =
                DateTime.now().difference(startTime).inMilliseconds;
            final genRate =
                duration > 0 ? ((totalGenerated * 1000) ~/ duration) : 0;

            Logger.debug(
                'ID isolate batch generated: $tableUid, added count: $totalGenerated, current pool size: ${_idPools[tableUid]!.length},'
                'Duration: ${duration}ms, Generation rate: $genRate IDs/s');
          }
        } else {
          // Old serial generation method remains unchanged
          // Generate in batches to avoid long lock time
          int remainingCount = neededCount;
          // Increase batch size to reduce iteration count
          const int batchSize = 1000; // Generate 1000 IDs per batch

          // Last check demand time
          var lastCheckTime = DateTime.now();

          // Generate in small batches continuously until demand is met
          while (remainingCount > 0) {
            final currentBatchSize = min(remainingCount, batchSize);

            // Generate a batch of IDs - use latest obtained request stats
            final numericIds =
                await _generateIds(currentBatchSize, latestRecentTotal);
            final formattedIds = _formatIds(numericIds);

            // Add to ID pool
            _idPools[tableUid]!.addAll(formattedIds);
            _idPoolLastUpdateTime[tableUid] = DateTime.now();

            // Update instance last access time
            _lastInstanceAccessTime['${keyType}_$tableUid'] = DateTime.now();

            totalGenerated += formattedIds.length;
            remainingCount -= formattedIds.length;

            // When remaining count is less or has passed a certain time, check if there's new demand
            final now = DateTime.now();
            bool needsCheck = remainingCount < _minGenerateBatchSize ||
                now.difference(lastCheckTime).inMilliseconds > 800;

            if (needsCheck && remainingCount < 300) {
              lastCheckTime = now;

              // Get latest request stats
              final newRecentTotal = _getRecentRequestCount();

              // Calculate new expected pool size
              final newExpectedSize =
                  _calculateExpectedPoolSize(newRecentTotal);

              // Get current pool size (already generated minus already consumed)
              final currentSize = _idPools[tableUid]!.length;

              // Calculate the number of IDs needed to generate
              final newNeededCount = max(0, newExpectedSize - currentSize);

              // If new demand is greater than minimum batch size, continue generating
              if (newNeededCount > _minGenerateBatchSize) {
                // Update remaining count
                remainingCount += newNeededCount;
              }
            }

            // Generate each batch, yield execution thread
            if (remainingCount > 0) {
              await Future.delayed(const Duration(milliseconds: 5));
            }
          }

          // Record performance data
          final duration = DateTime.now().difference(startTime).inMilliseconds;
          final genRate =
              duration > 0 ? ((totalGenerated * 1000) ~/ duration) : 0;
          final purpose = totalGenerated > 1000 ? "refill" : "preheat";
          Logger.debug(
              'ID ${purpose}ed: $tableUid, added count: $totalGenerated, current pool size: ${_idPools[tableUid]!.length},'
              'Duration: ${duration}ms, Generation rate: $genRate IDs/s');
        }
      } finally {
        // Ensure mark is cleared
        _idGenerationInProgress[tableUid] = false;
      }
    } catch (e) {
      // Ensure mark is cleared (even if exception occurs)
      _idGenerationInProgress[tableUid] = false;
      Logger.error('Refill ID pool failed', rawError: e);
      rethrow; // Re-throw exception for caller to handle
    } finally {
      // Release lock
      if (acquired) {
        _lockManager.releaseExclusiveLock(lockResource, operationId);
      }
    }
  }

  /// Generate one full ID batch in a single isolate.
  ///
  /// The name is kept for compatibility with existing call sites, but the
  /// implementation intentionally avoids splitting the batch across multiple
  /// tasks so timestamp/date sequence allocation stays reliable.
  Future<List<String>> _generateIdsInIsolateBatch(
      int neededCount, int recentTotal) async {
    try {
      final isHighGeneration = recentTotal >= (_maxSequence ~/ 5);
      final startSequence = _sequenceMap[tableUid] ?? 0;
      dynamic startValue;
      bool useNewTimestamp = false;

      if (keyType == PrimaryKeyType.timestampBased ||
          keyType == PrimaryKeyType.shortCode) {
        final currentTimestamp = _getCurrentLogicalTimestamp();
        final lastTimestamp = _lastValueMap[tableUid] ?? currentTimestamp;
        useNewTimestamp =
            currentTimestamp > (lastTimestamp + 60) || !isHighGeneration;
        startValue = useNewTimestamp ? currentTimestamp : lastTimestamp;
      } else {
        final currentDateString = _getCurrentDateString();
        final lastDate = _lastValueMap[tableUid] ?? currentDateString;
        useNewTimestamp =
            currentDateString.compareTo(lastDate) != 0 || !isHighGeneration;
        startValue = useNewTimestamp ? currentDateString : lastDate;
      }

      final result = await ComputeManager.run(
        ComputeTask(
          function: generateTimeBasedIds,
          message: TimeBasedIdGenerateRequest(
            keyType: keyType,
            nodeConfig: nodeConfig,
            tableUid: TableUid(tableUid),
            count: neededCount,
            startValue: startValue,
            startSequence: startSequence,
            useNewTimestamp: useNewTimestamp,
            useRandomStep: !isHighGeneration,
            isHighGeneration: isHighGeneration,
          ),
        ),
        useIsolate: true,
      );

      if (!result.success || result.ids.isEmpty) {
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message:
                'Single isolate ID generation returned empty. Error: ${result.errorMessage != null ? (result.errorMessage!.length > 200 ? "${result.errorMessage!.substring(0, 200)}..." : result.errorMessage) : "none"}.',
          )
        ]);
      }

      _sequenceMap[tableUid] = result.lastSequence;
      _lastValueMap[tableUid] = result.lastValue;
      _lastValue = result.lastValue;

      return result.ids;
    } catch (e) {
      Logger.error('Single isolate ID generation failed', rawError: e);

      // If error occurs, fall back to traditional generation method
      final numericIds = await _generateIds(neededCount, recentTotal);
      return _formatIds(numericIds);
    }
  }

  /// Unified ID retrieval method - add timeout protection
  @override
  Future<List<String>> getId(int count, {int recentTotal = 0}) async {
    if (count <= 0) return [];

    // Update request stats
    _updateRequestStats(count);

    // Ensure ID pool exists
    if (!_idPools.containsKey(tableUid)) {
      _idPools[tableUid] = Queue<String>();
    }

    // Prepare result list
    final result = <String>[];

    // Check existing IDs in pool
    if (_idPools[tableUid]!.isNotEmpty) {
      // Update last use time
      _idPoolLastUpdateTime[tableUid] = DateTime.now();

      // Get IDs from pool until demand is met or pool is empty
      while (result.length < count && _idPools[tableUid]!.isNotEmpty) {
        result.add(_idPools[tableUid]!.removeFirst());
      }

      // If enough IDs are retrieved, return directly
      if (result.length == count) {
        return result;
      }
    }

    // Here indicates pool ID is insufficient, need to synchronize waiting for refill

    // Get effective recent request count
    final effectiveRecentTotal =
        recentTotal > 0 ? recentTotal : _getRecentRequestCount();
    // Calculate expected pool size
    final expectedPoolSize = _calculateExpectedPoolSize(effectiveRecentTotal);

    // Calculate the number of IDs needed
    final targetSize = expectedPoolSize + (count - result.length);

    try {
      // Directly await refill to avoid un-awaited timer polling
      await _refillIdPool(targetSize, effectiveRecentTotal);

      // Drain remaining required IDs from pool
      while (
          result.length < count && (_idPools[tableUid]?.isNotEmpty ?? false)) {
        result.add(_idPools[tableUid]!.removeFirst());
      }
    } catch (e) {
      Logger.error('ID pool fill or get failed', rawError: e);
    }

    // If no ID is retrieved, throw exception
    if (result.isEmpty) {
      throw DbException([
        GeneralStatus(
          type: ResultType.sysTimeout,
          message:
              'Unable to generate ID: Pool is empty and fill timeout. Table=$tableDisplayName, Request=$count, '
              'FillInProgress=${_idGenerationInProgress[tableUid] ?? false}, '
              'Current pool size=${_idPools[tableUid]?.length ?? 0}.',
        )
      ]);
    }

    return result;
  }

  /// Update request stats
  void _updateRequestStats(int count) {
    final now = DateTime.now();
    final lastReset = _lastCountResetTime[tableUid] ??
        now.subtract(const Duration(seconds: 4));

    // Reset count if more than 3 seconds
    if (now.difference(lastReset).inSeconds > 3) {
      _recentRequestCount[tableUid] = count;
      _lastCountResetTime[tableUid] = now;
    } else {
      // Accumulate count
      _recentRequestCount[tableUid] =
          (_recentRequestCount[tableUid] ?? 0) + count;
    }
  }

  /// Get recent request count
  int _getRecentRequestCount() {
    final now = DateTime.now();
    final lastReset = _lastCountResetTime[tableUid] ??
        now.subtract(const Duration(seconds: 4));

    // Count over 3 seconds is considered expired
    if (now.difference(lastReset).inSeconds > 3) {
      _recentRequestCount[tableUid] = 0;
      _lastCountResetTime[tableUid] = now;
      return 0;
    }

    return _recentRequestCount[tableUid] ?? 0;
  }

  /// Calculate expected ID pool size
  int _calculateExpectedPoolSize(int recentTotal) {
    if (recentTotal <= 0) return _minGenerateBatchSize;

    // Estimate based on recent 3 seconds request count
    int estimatedSize = (recentTotal * 2).ceil();

    // Ensure reach minimum generation count
    return max(estimatedSize, _minGenerateBatchSize);
  }

  /// Clean up expired ID pools
  void _cleanupExpiredPools() {
    final now = DateTime.now();
    for (final tableUid in List.from(_idPoolLastUpdateTime.keys)) {
      final lastUpdateTime = _idPoolLastUpdateTime[tableUid];
      if (lastUpdateTime != null &&
          now.difference(lastUpdateTime) > _idPoolExpiry) {
        _idPools.remove(tableUid);
        _idPoolLastUpdateTime.remove(tableUid);

        Logger.debug('Clean up expired ID pool: $tableUid');
      }
    }
  }

  /// Core ID generation method (unified logic)
  Future<List<BigInt>> _generateIds(int count, int recentTotal) async {
    if (keyType == PrimaryKeyType.timestampBased ||
        keyType == PrimaryKeyType.shortCode) {
      return await _generateTimestampIds(count, recentTotal);
    } else if (keyType == PrimaryKeyType.datePrefixed) {
      return await _generateDatePrefixedIds(count, recentTotal);
    } else {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'Unsupported ID type: $keyType.',
        )
      ]);
    }
  }

  /// Generate timestamp ID (optimized batch generation logic)
  Future<List<BigInt>> _generateTimestampIds(int count, int recentTotal) async {
    // Use preallocated capacity List and BigInt.zero initialization to avoid null
    final result = List<BigInt>.filled(count, BigInt.zero);

    // Get current state
    int currentTimestamp = _getCurrentLogicalTimestamp();
    int sequence = _sequenceMap[tableUid] ?? 0;
    int lastTimestamp = _lastValueMap[tableUid] ?? currentTimestamp;

    // Determine generation strategy based on load
    bool isHighGeneration = recentTotal >= (_maxSequence ~/ 5);

    // If current timestamp is too far from last or load is not high, use new timestamp
    bool useNewTimestamp =
        currentTimestamp > (lastTimestamp + 60) || !isHighGeneration;

    int timestamp = useNewTimestamp ? currentTimestamp : lastTimestamp;

    // Batch optimization: Precompute most IDs
    if (isHighGeneration && sequence + count <= _maxSequence) {
      // All IDs can be generated in the same timestamp - efficient batch processing
      for (int i = 0; i < count; i++) {
        sequence += 1;
        result[i] = _calculateTimestampIdAsBigInt(timestamp, sequence);
      }

      // Update state
      _sequenceMap[tableUid] = sequence;
      _lastValueMap[tableUid] = timestamp;
      _lastValue = timestamp;

      return result;
    }

    // Sequence number step strategy: Calculate based on count and business volume
    int step = 1;
    if (!isHighGeneration) {
      // Calculate average step
      step = _maxSequence ~/
          max(count, 100); // Avoid division by 0 or very small number
    } else if (useNewTimestamp) {
      sequence = _random.nextInt(1000) +
          1; // If using new timestamp, reset sequence number
    }

    // Generate batch of IDs
    for (int i = 0; i < count; i++) {
      // Increment sequence number
      sequence += step < 2 ? 1 : _random.nextInt(step) + 1;
      // Check if sequence number exceeds max value
      if (sequence > _maxSequence) {
        // Remaining space is not enough, wait for next timestamp
        timestamp = await _waitNextTimestamp(timestamp);
        sequence = _random.nextInt(1000) + 1;
      }
      // Calculate ID and directly assign to result array
      result[i] = _calculateTimestampIdAsBigInt(timestamp, sequence);
    }

    // Update state
    _sequenceMap[tableUid] = sequence;
    _lastValueMap[tableUid] = timestamp;
    _lastValue = timestamp;

    return result;
  }

  /// Generate date prefixed ID (optimized batch generation logic)
  Future<List<BigInt>> _generateDatePrefixedIds(
      int count, int recentTotal) async {
    // Use preallocated capacity List and BigInt.zero initialization to avoid null
    final result = List<BigInt>.filled(count, BigInt.zero);

    // Get current date string
    String currentDateString = _getCurrentDateString();
    int sequence = _sequenceMap[tableUid] ?? 0;
    String lastDate = _lastValueMap[tableUid] ?? currentDateString;

    // Determine generation strategy based on load
    bool isHighGeneration = recentTotal >= (_maxSequence ~/ 5);

    // If current date is different from last or load is not high, use new date
    bool useNewDate =
        currentDateString.compareTo(lastDate) != 0 || !isHighGeneration;

    // Set working date string
    String dateString = useNewDate ? currentDateString : lastDate;

    // Batch optimization: Precompute most IDs
    if (isHighGeneration && sequence + count <= _maxSequence) {
      // All IDs can be generated in the same date string - efficient batch processing
      for (int i = 0; i < count; i++) {
        sequence += 1;
        result[i] = _calculateDatePrefixedIdAsBigInt(dateString, sequence);
      }

      // Update state
      _sequenceMap[tableUid] = sequence;
      _lastValueMap[tableUid] = dateString;
      _lastValue = dateString;

      return result;
    }

    // Sequence number step strategy: Calculate based on count and business volume
    int step = 1;
    if (!isHighGeneration) {
      // Calculate average step
      step = _maxSequence ~/
          max(count, 100); // Avoid division by 0 or very small number
    } else if (useNewDate) {
      sequence =
          _random.nextInt(1000) + 1; // If using new date, reset sequence number
    }

    // Generate batch of IDs
    for (int i = 0; i < count; i++) {
      // Increment sequence number
      sequence += step < 2 ? 1 : _random.nextInt(step) + 1;

      // Check if sequence number exceeds max value
      if (sequence > _maxSequence) {
        // Remaining space is not enough, wait for next second
        dateString = await _waitNextSecond(dateString);
        sequence = _random.nextInt(1000) + 1;
      }

      // Calculate final ID and directly assign to result array
      result[i] = _calculateDatePrefixedIdAsBigInt(dateString, sequence);
    }

    // Update state
    _sequenceMap[tableUid] = sequence;
    _lastValueMap[tableUid] = dateString;
    _lastValue = dateString;

    return result;
  }

  /// Periodic pool check and maintenance task - add instance recycling mechanism
  static void periodicPoolCheck() {
    final now = DateTime.now();

    // First clean up idle instances to reduce subsequent traversal count
    _cleanupIdleInstances(now);

    // Only traverse active instances for pool check
    for (final generator in _instances.values) {
      generator._periodicMaintenance();
    }
  }

  /// Clean up idle generator instances
  static void _cleanupIdleInstances(DateTime now) {
    try {
      // Find idle instances that exceed idle time
      final keysToRemove = <String>[];

      for (final entry in _lastInstanceAccessTime.entries) {
        final key = entry.key;
        final lastAccess = entry.value;

        // If idle time exceeds and instance still exists
        if (now.difference(lastAccess) > _instanceIdleTimeout &&
            _instances.containsKey(key)) {
          // Check if there's associated ID pool
          final instance = _instances[key]!;
          final tableUid = instance.tableUid;

          // Check if pool exists and is not empty (pool with data should not be recycled)
          if (!instance._idPools.containsKey(tableUid) ||
              instance._idPools[tableUid]!.isEmpty) {
            keysToRemove.add(key);
          }
        }
      }

      // Delete idle instances
      if (keysToRemove.isNotEmpty) {
        for (final key in keysToRemove) {
          _instances.remove(key);
          _lastInstanceAccessTime.remove(key);

          // Record instance recycling
          Logger.debug('Recycle idle ID generator instance: $key');
        }
      }
    } catch (e) {
      Logger.error('Clean up idle generator instance failed', rawError: e);
    }
  }

  /// Single instance periodic maintenance
  void _periodicMaintenance() {
    try {
      // Update instance last access time to indicate this instance is still active
      _lastInstanceAccessTime['${keyType}_$tableUid'] = DateTime.now();

      // Clean up expired pools
      _cleanupExpiredPools();

      // Get recent request count
      final recentTotal = _getRecentRequestCount();

      // Only perform maintenance check if there's recent request or pool is not empty
      if (recentTotal > 0 || (_idPools[tableUid]?.isNotEmpty ?? false)) {
        // Calculate expected pool size
        final expectedPoolSize = _calculateExpectedPoolSize(recentTotal);
        final currentPoolSize = _idPools[tableUid]?.length ?? 0;

        // If pool size is less than 70% of expected and current no generation task in progress, trigger refill
        if (currentPoolSize < expectedPoolSize * 0.7 &&
            _idGenerationInProgress[tableUid] != true) {
          // Asynchronous refill pool, no waiting for result
          Future.microtask(() => _refillIdPool(expectedPoolSize, recentTotal));
        }
      }
    } catch (e) {
      Logger.error('ID pool periodic maintenance failed', rawError: e);
    }
  }

  @override
  int get remainingIds => _idPools[tableUid]?.length ?? 0;

  @override
  bool get needsFetch => false; // Local generation, no need to get

  @override
  Future<bool> requestNewBatch() async => true; // No operation needed

  @override
  String get type => keyType == PrimaryKeyType.timestampBased
      ? 'timestamp-based'
      : keyType == PrimaryKeyType.datePrefixed
          ? 'date-prefixed'
          : 'short-code';

  /// Convert numeric ID to short code
  String _convertIdToShortCode(BigInt numericId) {
    return Base62Encoder.encode(numericId);
  }

  /// Get logical timestamp based on custom epoch (seconds level)
  int _getCurrentLogicalTimestamp() {
    // System timestamp (seconds) minus epoch start point
    int timestamp =
        (DateTime.now().millisecondsSinceEpoch ~/ 1000) - _epochStartSeconds;
    return timestamp;
  }

  /// Get current date string (yyyyMMddHHmmss)
  String _getCurrentDateString() {
    // Get current date time, format as yyyyMMddHHmmss
    final now = DateTime.now();
    final dateString = '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
    return dateString;
  }

  /// Wait for next timestamp - optimized version, avoid excessive CPU usage and stack overflow risk
  Future<int> _waitNextTimestamp(int lastTimestamp) async {
    // Highest priority strategy: Check directly after small delay
    await Future.delayed(const Duration(milliseconds: 1));
    int timestamp = _getCurrentLogicalTimestamp();

    // If it's already a new timestamp, return directly
    if (timestamp > lastTimestamp) {
      return timestamp;
    }

    // If still not changed, use progressive delay strategy
    int attempts = 1;
    int maxAttempts = 200; // Limit maximum attempt count
    int delayMs = 1; // Initial delay 1 millisecond

    while (timestamp <= lastTimestamp && attempts < maxAttempts) {
      attempts++;

      // Incremental delay strategy, but limit maximum delay to 50ms
      delayMs = min(delayMs + 1, 50);

      // Use await to yield CPU time, avoid blocking thread
      await Future.delayed(Duration(milliseconds: delayMs));
      timestamp = _getCurrentLogicalTimestamp();
    }

    // If attempt count reaches upper limit without obtaining new timestamp, force return subsequent timestamp
    if (timestamp <= lastTimestamp) {
      Logger.warn('Timestamp wait timeout, force increment timestamp');
      return lastTimestamp + 1;
    }

    return timestamp;
  }

  /// Wait for next second - optimized version, avoid excessive CPU usage and stack overflow risk
  Future<String> _waitNextSecond(String lastDate) async {
    // Highest priority strategy: Check directly after small delay
    await Future.delayed(const Duration(milliseconds: 1));
    String dateString = _getCurrentDateString();

    // If it's already a new date, return directly
    if (dateString.compareTo(lastDate) > 0) {
      return dateString;
    }

    // If still not changed, use progressive delay strategy
    int attempts = 1;
    int maxAttempts = 200; // Limit maximum attempt count
    int delayMs = 1; // Initial delay 1 millisecond

    while (dateString.compareTo(lastDate) <= 0 && attempts < maxAttempts) {
      attempts++;

      // Incremental delay strategy, but limit maximum delay to 50ms
      delayMs = min(delayMs + 1, 50);

      // Use await to yield CPU time, avoid blocking thread
      await Future.delayed(Duration(milliseconds: delayMs));
      dateString = _getCurrentDateString();
    }

    // If attempt count reaches upper limit without obtaining new date string, force generate subsequent date
    if (dateString.compareTo(lastDate) <= 0) {
      Logger.warn('Date wait timeout, force increment date');

      try {
        // Parse date string and increment 1 second
        final fmt =
            '${lastDate.substring(0, 8)}T${lastDate.substring(8, 10)}:${lastDate.substring(10, 12)}:${lastDate.substring(12, 14)}';
        final dt = DateTime.parse(fmt).add(const Duration(seconds: 1));
        return '${dt.year}${dt.month.toString().padLeft(2, '0')}${dt.day.toString().padLeft(2, '0')}${dt.hour.toString().padLeft(2, '0')}${dt.minute.toString().padLeft(2, '0')}${dt.second.toString().padLeft(2, '0')}';
      } catch (e) {
        // If parsing fails, return current time
        return _getCurrentDateString();
      }
    }

    return dateString;
  }

  /// Calculate timestamp ID (using BigInt)
  BigInt _calculateTimestampIdAsBigInt(int timestamp, int sequence) {
    // Use cached BigInt values to calculate to avoid repeated creation
    final BigInt timestampBig = BigInt.from(timestamp);
    final BigInt sequenceBig = BigInt.from(sequence);

    if (nodeConfig.enableDistributed) {
      // Distributed mode uses algorithm with included node ID
      // Algorithm: timestamp * 10^(nodeIdDigits+5) + nodeId * 10^5 + sequence
      return timestampBig * _powerFactor +
          _nodeIdBig! * _sequenceFactor +
          sequenceBig;
    } else {
      // Non-distributed mode uses simplified algorithm
      // Algorithm: timestamp * 10^5 + sequence
      return timestampBig * _sequenceFactor + sequenceBig;
    }
  }

  /// Calculate date prefixed ID (using BigInt)
  BigInt _calculateDatePrefixedIdAsBigInt(String dateString, int sequence) {
    // Convert date string to number
    BigInt dateValue;
    try {
      dateValue = BigInt.parse(dateString);
    } catch (e) {
      Logger.error('Date string conversion to number failed: $dateString',
          rawError: e);
      // Use current timestamp as fallback solution
      dateValue = BigInt.from(
          (DateTime.now().millisecondsSinceEpoch ~/ 1000) % 10000000000);
    }

    // Use cached BigInt values to calculate
    final BigInt sequenceBig = BigInt.from(sequence);

    // Use BigInt calculation to avoid precision issues
    if (nodeConfig.enableDistributed) {
      // Algorithm: date * 10^(nodeIdDigits+5) + nodeId * 10^5 + sequence
      return dateValue * _powerFactor +
          _nodeIdBig! * _sequenceFactor +
          sequenceBig;
    } else {
      // Without node ID, directly combine date and sequence number
      // Algorithm: date * 10^5 + sequence
      return dateValue * _sequenceFactor + sequenceBig;
    }
  }

  @override
  void purgeIdsLessThanOrEqualTo(dynamic actualMaxId) {
    if (actualMaxId == null) return;
    final maxStr = actualMaxId.toString();
    if (maxStr.isEmpty) return;

    for (final pool in _idPools.values) {
      if (pool.isEmpty) continue;
      if (pool.last.compareTo(maxStr) <= 0) {
        pool.clear();
      } else {
        while (pool.isNotEmpty && pool.first.compareTo(maxStr) <= 0) {
          pool.removeFirst();
        }
      }
    }
  }
}

/// Central server ID segment
class IdBatchResult {
  final int startId;
  final int endId;
  final DateTime timestamp;

  IdBatchResult(
      {required this.startId, required this.endId, required this.timestamp});
}

/// Central server client interface
abstract class CentralServerClient {
  /// Request ID segment
  Future<IdBatchResult?> requestIdBatch(
      {required String tableUid, required int nodeId, required int batchSize});

  /// Get node information
  Future<DistributedNodeConfig?> fetchNodeInfo(String? accessToken);
}

/// ID generator factory
class IdGeneratorFactory {
  /// Create ID generator
  static IdGenerator createGenerator(TableSchema schema, DataStoreConfig config,
      {CentralServerClient? centralClient}) {
    final pkConfig = schema.primaryKeyConfig;

    switch (pkConfig.type) {
      case PrimaryKeyType.sequential:
        // Create sequential ID generator, if distributed configuration enabled, pass related parameters
        return SequentialIdGenerator(
          pkConfig.sequentialConfig ?? const SequentialIdConfig(),
          nodeConfig: config.distributedNodeConfig,
          tableUid: schema.tableUid,
          centralClient: centralClient,
        );

      case PrimaryKeyType.timestampBased:
      case PrimaryKeyType.datePrefixed:
      case PrimaryKeyType.shortCode:
        // Create timestamp/date prefixed/short code ID generator - use instance retrieval method
        return TimeBasedIdGenerator.getInstance(
          pkConfig.type,
          config.distributedNodeConfig,
          schema.tableUid,
          maxConcurrent: config.maxConcurrency,
          tableName: schema.name,
        );

      case PrimaryKeyType.none:
        // Return an empty implementation, user needs to provide ID
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message:
                'Unsupported primary key generation type: ${pkConfig.type}.',
          )
        ]);
    }
  }
}

/// Global ID generator shared by locks, partitions, WAL, migration etc.
/// Generates short, filesystem-safe IDs.
///
/// Output: `[prefix]` + optional default lead + fixed-width Base36 body.
/// - Non-empty [prefix]: caller-owned prefix + [_bodyLen] Base36 digits.
/// - Empty [prefix]: default lead `'a'` + [_bodyLen] Base36 digits (avoids a
///   leading digit, which is unsafe for identifiers / some filesystems).
/// All output chars are lowercase letters or digits; the first char is always
/// a letter when [prefix] is empty or itself starts with a letter.
/// Safe as a filename, table name, identifier, and cross-platform path component.
class GlobalIdGenerator {
  static final Random _random = Random.secure();
  static const int _timestampBits = 36; // 36 bits seconds (~2177 years)
  static const int _nodeBits = 14; // 14 bits node ID (up to 16384 nodes)
  static const int _sequenceBits =
      22; // 22 bits sequence (4,194,304 ids/sec/node)

  static const int _sequenceMask = (1 << _sequenceBits) - 1;
  static const int _nodeMask = (1 << _nodeBits) - 1;
  static const int _timestampMask = (1 << _timestampBits) - 1;

  // Custom Epoch: 2026-01-01 00:00:00 UTC (1767225600 seconds)
  static const int _epochStartSeconds = 1767225600;

  // Global static node ID, defaults to 1. Injected at startup using initialize(nodeId)
  static int _nodeId = 1;

  /// Initializes the GlobalIdGenerator with the distributed nodeId.
  /// Node ID is clamped to 14 bits (0 - 16383).
  static void initialize(int nodeId) {
    _nodeId = nodeId & _nodeMask;
  }

  // Base36 charset: digits first, then lowercase letters.
  static const String _base36Chars = '0123456789abcdefghijklmnopqrstuvwxyz';
  // Pre-computed code-unit tables -- avoids repeated String indexing in the hot path.
  static final List<int> _base36Units =
      _base36Chars.codeUnits.toList(growable: false);

  static const int _totalBits =
      _timestampBits + _nodeBits + _sequenceBits; // 72 bits

  /// Fixed-width Base36 body length derived from [_totalBits].
  /// Uses final instead of const since log/ceil are computed at runtime.
  static final int _bodyLen = (_totalBits / (log(36) / log(2))).ceil();

  /// Unified static output buffer for prefix + body + suffix in a single allocation.
  /// WARNING: This buffer is globally shared and reused in a single isolate.
  /// Do not read directly from it or pass it out of _build.
  /// It is dirty-written; String.fromCharCodes relies strictly on the length argument to isolate output.
  static final List<int> _outBuf = List<int>.filled(128, 0x30);

  static int _lastTimestampSec = 0;
  static int _sequence = 0;

  /// Generates [prefix] + Base36 body in a single [String.fromCharCodes] call.
  /// Empty [prefix] injects a default lead `'a'` before the body.
  static String generate(String prefix) => _build(prefix, null);

  /// Generates [prefix] + Base36 body + optional [suffix] in one allocation.
  /// Empty [prefix] injects a default lead 'a' before the body.
  static String generateWithSuffix(String prefix, {String? suffix}) =>
      _build(prefix, suffix);

  /// Builds the complete output string in-place with exactly one String allocation.
  static String _build(String prefix, String? suffix) {
    final BigInt id = _nextId();
    final int pLen = prefix.length;
    final int sLen = suffix?.length ?? 0;
    // Empty prefix: inject default lead 'a' so the ID never starts with a digit.
    final int leadLen = pLen == 0 ? 1 : 0;
    final int bodyStart = pLen + leadLen;
    final int bodyEnd = bodyStart + _bodyLen;
    final int totalLen = bodyEnd + sLen;

    // Fallback dynamic buffer to prevent out-of-bounds RangeError crash in production.
    // Keeps 0-GC overhead for <= 128 chars, but handles arbitrarily long inputs gracefully.
    final List<int> buf =
        totalLen <= 128 ? _outBuf : List<int>.filled(totalLen, 0x30);

    // -- prefix --------------------------------------------------------------
    for (int i = 0; i < pLen; i++) {
      buf[i] = prefix.codeUnitAt(i);
    }

    // -- default lead (empty prefix only) ------------------------------------
    if (leadLen == 1) {
      buf[0] = 0x61; // 'a'
    }

    // -- suffix (write before body so pos cursor starts cleanly at bodyEnd) --
    for (int i = 0; i < sLen; i++) {
      buf[bodyEnd + i] = suffix!.codeUnitAt(i);
    }

    // -- body: right-to-left into [bodyStart .. bodyEnd-1] -------------------
    int pos = bodyEnd;
    BigInt body = id;
    final BigInt base = BigInt.from(36);
    do {
      final BigInt q = body ~/ base;
      final BigInt r = body - q * base;
      buf[pos - 1] = _base36Units[r.toInt()];
      pos--;
      body = q;
    } while (body > BigInt.zero);

    // -- zero-pad remaining body slots ---------------------------------------
    while (pos > bodyStart) {
      buf[pos - 1] = 0x30; // '0'
      pos--;
    }

    return String.fromCharCodes(buf, 0, totalLen); // single allocation
  }

  static BigInt _nextId() {
    int timestamp =
        (DateTime.now().millisecondsSinceEpoch ~/ 1000) - _epochStartSeconds;

    if (timestamp < _lastTimestampSec) {
      // Clock went backwards -- typically an NTP step correction.
      // Force monotonicity.
      timestamp = _lastTimestampSec;
    }

    if (timestamp == _lastTimestampSec) {
      _sequence = (_sequence + 1) & _sequenceMask;
      if (_sequence == 0) {
        // Sequence overflow within same second, wait for next second.
        timestamp = _waitNextSecond(_lastTimestampSec);
      }
    } else {
      // Randomize start sequence a bit to reduce contention under bursts.
      _sequence = _random.nextInt(4);
    }

    _lastTimestampSec = timestamp;

    // Assemble 72 bits unsigned value using BigInt
    final BigInt timestampBig = BigInt.from(timestamp & _timestampMask);
    final BigInt nodeBig = BigInt.from(_nodeId & _nodeMask);
    final BigInt seqBig = BigInt.from(_sequence & _sequenceMask);

    return (timestampBig << (_nodeBits + _sequenceBits)) |
        (nodeBig << _sequenceBits) |
        seqBig;
  }

  static int _waitNextSecond(int lastTimestamp) {
    final int startMs = DateTime.now().millisecondsSinceEpoch;
    int ts = (startMs ~/ 1000) - _epochStartSeconds;

    // Spin-wait but limit to a maximum of 50ms to prevent Isolate freeze and CPU starvation
    while (ts <= lastTimestamp) {
      final int nowMs = DateTime.now().millisecondsSinceEpoch;
      if (nowMs - startMs > 50) {
        break; // Spin timeout reached
      }
      ts = (nowMs ~/ 1000) - _epochStartSeconds;
    }

    if (ts <= lastTimestamp) {
      // Force virtual time forward by 1 second as a monotonic fallback
      ts = lastTimestamp + 1;
    }
    return ts;
  }
}
