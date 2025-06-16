import 'dart:math';
import 'dart:async';
import 'dart:collection';
import '../model/table_schema.dart';
import '../model/data_store_config.dart';
import '../handler/logger.dart';
import '../core/lock_manager.dart';
import '../core/compute_manager.dart';
import '../core/compute_tasks.dart';

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
}

/// Sequential ID generator
class SequentialIdGenerator implements IdGenerator {
  final SequentialIdConfig config;
  final DistributedNodeConfig? nodeConfig;
  final String? tableName;
  final CentralServerClient? centralClient;

  int _currentId;
  int _maxId = 0;
  int _lastRequestTime = 0;
  final Random _random = Random(DateTime.now().millisecondsSinceEpoch);

  // Whether to use distributed mode
  bool get isDistributed =>
      nodeConfig != null &&
      nodeConfig!.enableDistributed &&
      centralClient != null;

  SequentialIdGenerator(
    this.config, {
    this.nodeConfig,
    this.tableName,
    this.centralClient,
  }) : _currentId = config.initialValue - 1 {
    // Subtract 1 because nextId will first add increment
    _initializeGenerator();
  }

  /// Initialize generator
  void _initializeGenerator() {
    // If using distributed mode, initial value depends on central server allocation
    if (!isDistributed) {
      // Ensure _currentId is initialized to at least equal to initialValue
      if (_currentId < config.initialValue - 1) {
        _currentId = config.initialValue - 1;
      }
    }
  }

  /// Unified ID retrieval method implementation
  @override
  Future<List<String>> getId(int count, {int recentTotal = 0}) async {
    if (count <= 0) return [];

    final result = <String>[];

    // In distributed mode, need to check ID segment
    if (isDistributed && (_currentId + config.increment * count > _maxId)) {
      if (!await requestNewBatch()) {
        throw Exception('Unable to get enough ID segments');
      }

      // Recalculate the number of IDs that can be retrieved
      final availableIds = (_maxId - _currentId) ~/ config.increment;
      if (availableIds < count) {
        // If not enough to generate the required amount, only return available amount
        count = max(availableIds, 0);
        if (count <= 0) {
          throw Exception('No ID segment available');
        }
      }
    }

    // Efficiently generate multiple IDs
    for (int i = 0; i < count; i++) {
      // Calculate increment, each ID can have different step
      final increment = config.useRandomIncrement
          ? _random.nextInt(config.increment) + 1
          : config.increment;

      _currentId += increment;
      result.add(_currentId.toString());
    }

    return result;
  }

  @override
  int get remainingIds => isDistributed ? _maxId - _currentId : -1;

  @override
  bool get needsFetch {
    if (!isDistributed) return false;

    // If remaining ID count is below threshold, need to get new batch
    final threshold = (10000 * nodeConfig!.idFetchThreshold).toInt();
    return remainingIds < threshold;
  }

  @override
  Future<bool> requestNewBatch() async {
    if (!isDistributed) {
      return true; // Non-distributed mode does not need request
    }

    try {
      // Limit request frequency
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastRequestTime < 5000) {
        // Do not repeat request within 5 seconds
        return false;
      }

      _lastRequestTime = now;

      // Request new ID segment
      final result = await centralClient!.requestIdBatch(
          tableName: tableName!, nodeId: nodeConfig!.nodeId, batchSize: 10000);

      if (result != null) {
        _currentId = result.startId -
            1; // Subtract 1 because nextId() will first add increment
        _maxId = result.endId;
        return true;
      }

      return false;
    } catch (e) {
      Logger.error('Request ID segment failed: $e',
          label: 'SequentialIdGenerator');
      return false;
    }
  }

  @override
  String get type => isDistributed ? 'distributed-sequential' : 'sequential';

  /// Set current ID value (for recovery from storage)
  void setCurrentId(int id) {
    _currentId = id;
  }

  /// Set current ID range (for recovery from distributed storage)
  void setIdRange(int currentId, int maxId) {
    _currentId = currentId;
    _maxId = maxId;
  }
}

/// Base62 encoder (used for generating short code IDs)
class Base62Encoder {
  static const String _charset =
      '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

  /// Encode BigInt to Base62 string
  static String encode(BigInt value) {
    if (value < BigInt.zero) {
      throw ArgumentError('Base62 encoding does not support negative numbers');
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
        throw FormatException('Illegal Base62 character: ${value[i]}');
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
  final String tableName;

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

  // Parallel generation control related properties
  bool _enableParallel = true; // Whether to enable parallel generation
  int _maxConcurrent = 4; // Maximum parallel count, default is 4
  static const int _minCountPerIsolate = 100; // Minimum number of IDs to generate for each isolate

  // Static mapping for global access to all generator instances
  static final Map<String, TimeBasedIdGenerator> _instances = {};

  /// Get generator from instance map, create new instance if not exists
  static TimeBasedIdGenerator getInstance(PrimaryKeyType keyType,
      DistributedNodeConfig nodeConfig, String tableName, {int? maxConcurrent}) {
    final key = '${keyType}_$tableName';

    // If instance already exists, return directly
    if (_instances.containsKey(key)) {
      // Update last access time
      _lastInstanceAccessTime[key] = DateTime.now();
      
      // If parallel count is specified, update parallel settings of existing instance
      if (maxConcurrent != null && maxConcurrent > 0) {
        _instances[key]!.setParallelGeneration(true, maxConcurrent: maxConcurrent);
      }
      
      return _instances[key]!;
    }

    // Create new instance
    final generator = TimeBasedIdGenerator._(keyType, nodeConfig, tableName);
    
    // Set parallel count
    if (maxConcurrent != null && maxConcurrent > 0) {
      generator.setParallelGeneration(true, maxConcurrent: maxConcurrent);
    }
    
    _instances[key] = generator;
    _lastInstanceAccessTime[key] = DateTime.now();
    return generator;
  }

  // Make constructor private, force use of getInstance
  TimeBasedIdGenerator._(this.keyType, this.nodeConfig, this.tableName) {
    // Check if keyType is a valid type
    if (keyType != PrimaryKeyType.timestampBased &&
        keyType != PrimaryKeyType.datePrefixed &&
        keyType != PrimaryKeyType.shortCode) {
      throw ArgumentError(
          'keyType must be timestampBased, datePrefixed, or shortCode');
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
    _sequenceMap[tableName] = 0;
    _lastValueMap[tableName] = _lastValue;

    // Ensure ID pool exists
    if (!_idPools.containsKey(tableName)) {
      _idPools[tableName] = Queue<String>();
    }

    // Initialize statistics
    _recentRequestCount[tableName] = 0;
    _lastCountResetTime[tableName] = DateTime.now();
    _idGenerationInProgress[tableName] = false;

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
    final operationId = '${tableName}_id_fill';

    // Add duplicate fill check
    if (_idGenerationInProgress[tableName] == true) {
      Logger.debug(
          'Skip duplicate ID pool fill request: $tableName, fill task already running',
          label: 'TimeBasedIdGenerator._refillIdPool');
      return;
    }

    try {
      // Mark generation task start - mark before acquiring lock to avoid duplicate requests
      _idGenerationInProgress[tableName] = true;

      // Acquire lock to ensure only one thread is generating IDs at the same time
      await _lockManager.acquireExclusiveLock(operationId, 'id_generator');

      try {
        // Ensure ID pool exists
        if (!_idPools.containsKey(tableName)) {
          _idPools[tableName] = Queue<String>();
        }

        // Recheck pool size, it might have been filled by other threads while waiting for lock
        final currentPoolSize = _idPools[tableName]!.length;
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

        // Check if parallel generation conditions are met
        final canUseParallel = _enableParallel &&
                              neededCount >= _minCountPerIsolate * 2;
        
        if (canUseParallel) {
            // Parallel generate IDs
            final generatedIds = await _generateIdsInParallel(neededCount, latestRecentTotal);
            
            // Add generated IDs to ID pool
            if (generatedIds.isNotEmpty) {
              _idPools[tableName]!.addAll(generatedIds);
              _idPoolLastUpdateTime[tableName] = DateTime.now();
              
              totalGenerated = generatedIds.length;
              
              // Record performance data
              final duration = DateTime.now().difference(startTime).inMilliseconds;
              final genRate = duration > 0 ? ((totalGenerated * 1000) ~/ duration) : 0;

              Logger.debug(
              'ID parallel generated: $tableName, added count: $totalGenerated, current pool size: ${_idPools[tableName]!.length},'
              'Duration: ${duration}ms, Generation rate: $genRate IDs/s',
              label: 'TimeBasedIdGenerator._refillIdPool');
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
            _idPools[tableName]!.addAll(formattedIds);
            _idPoolLastUpdateTime[tableName] = DateTime.now();

            // Update instance last access time
            _lastInstanceAccessTime['${keyType}_$tableName'] = DateTime.now();

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
              final newExpectedSize = _calculateExpectedPoolSize(newRecentTotal);

              // Get current pool size (already generated minus already consumed)
              final currentSize = _idPools[tableName]!.length;

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
              'ID ${purpose}ed: $tableName, added count: $totalGenerated, current pool size: ${_idPools[tableName]!.length},'
              'Duration: ${duration}ms, Generation rate: $genRate IDs/s',
              label: 'TimeBasedIdGenerator._refillIdPool');
        }
      } finally {
        // Ensure mark is cleared
        _idGenerationInProgress[tableName] = false;
      }
    } catch (e) {
      // Ensure mark is cleared (even if exception occurs)
      _idGenerationInProgress[tableName] = false;
      Logger.error('Refill ID pool failed: $e',
          label: 'TimeBasedIdGenerator._refillIdPool');
      rethrow; // Re-throw exception for caller to handle
    } finally {
      // Release lock
      _lockManager.releaseExclusiveLock(operationId, 'id_generator');
    }
  }
  
  /// Parallel generate IDs
  Future<List<String>> _generateIdsInParallel(int neededCount, int recentTotal) async {
    
    try {
      
      // Parallel generation control parameters
      final isHighGeneration = recentTotal >= (_maxSequence ~/ 5);
      
      // Calculate the number of IDs to generate for each parallel task based on maximum concurrency and total demand
      int parallelCount = min(_maxConcurrent, 8); // Maximum 8 parallel tasks
      // Ensure each isolate at least processes a certain number of IDs
      parallelCount = min(parallelCount, neededCount ~/ _minCountPerIsolate);
      if (parallelCount < 1) parallelCount = 1;
      
      // Calculate the number of IDs to generate for each isolate
      final idsPerIsolate = neededCount ~/ parallelCount;
      final remainingIds = neededCount % parallelCount;
      
      // Prepare parallel task list, use Map to store results for sequential merging
      final tasks = <int, Future<TimeBasedIdGenerateResult>>{};
      int currentSequence = _sequenceMap[tableName] ?? 0;
      dynamic currentValue;
      
      // Get current base value
      if (keyType == PrimaryKeyType.timestampBased || keyType == PrimaryKeyType.shortCode) {
        currentValue = _getCurrentLogicalTimestamp();
      } else {
        currentValue = _getCurrentDateString();
      }
      
      // Create multiple generation tasks
      for (int i = 0; i < parallelCount; i++) {
        // Calculate the number of IDs to generate for this task
        final countForThisIsolate = i == parallelCount - 1 
            ? idsPerIsolate + remainingIds 
            : idsPerIsolate;
            
        // Create request
        final request = TimeBasedIdGenerateRequest(
          keyType: keyType,
          nodeConfig: nodeConfig,
          tableName: tableName,
          count: countForThisIsolate,
          startValue: currentValue,
          startSequence: currentSequence,
          useNewTimestamp: i > 0, // The first one uses current timestamp, others use new timestamp
          useRandomStep: !isHighGeneration,
          isHighGeneration: isHighGeneration,
        );
        
        // Add task, record task index for order preservation
        final task = ComputeManager.run(
          generateTimeBasedIds,
          request,
          useIsolate: true,
          fallbackToMainThread: true,
        );
        
        tasks[i] = task;
        
        // Reserve sequence number space for next task
        if (isHighGeneration) {
          // High generation mode uses continuous sequence numbers
          currentSequence += countForThisIsolate;
          if (currentSequence > _maxSequence) {
            // If sequence number is insufficient, use new timestamp value
            if (keyType == PrimaryKeyType.timestampBased || keyType == PrimaryKeyType.shortCode) {
              currentValue = _getCurrentLogicalTimestamp() + 1; // +1 ensure it's a new timestamp
            } else {
              // Get next second string
              final now = DateTime.now().add(const Duration(seconds: 1));
              currentValue = '${now.year}'
                '${now.month.toString().padLeft(2, '0')}'
                '${now.day.toString().padLeft(2, '0')}'
                '${now.hour.toString().padLeft(2, '0')}'
                '${now.minute.toString().padLeft(2, '0')}'
                '${now.second.toString().padLeft(2, '0')}';
            }
            currentSequence = 0;
          }
        } else {
          // Non-high generation mode uses different sequence number ranges
          // Each task uses a different sequence number starting point to avoid conflicts
          final step = _maxSequence ~/ (parallelCount + 1);
          currentSequence += step;
          if (currentSequence > _maxSequence) currentSequence = 1;
        }
      }
      
      // Wait for all tasks to complete and collect results
      final results = <TimeBasedIdGenerateResult>[];
      // Process results in order, ensure ID order
      for (int i = 0; i < parallelCount; i++) {
        results.add(await tasks[i]!);
      }
      
      final allGeneratedIds = <String>[];
      dynamic lastValue = currentValue;
      int lastSequence = currentSequence;
      
      // Process and merge results in original order
      for (final result in results) {
        if (result.success && result.ids.isNotEmpty) {
          // Add generated IDs in order of task index, ensure correct order
          allGeneratedIds.addAll(result.ids);
          
          // Update latest value and sequence number
          if (keyType == PrimaryKeyType.timestampBased || keyType == PrimaryKeyType.shortCode) {
            // For timestamp, use larger value
            if (result.lastValue is int && lastValue is int && result.lastValue > lastValue) {
              lastValue = result.lastValue;
            }
          } else if (keyType == PrimaryKeyType.datePrefixed) {
            // For date prefixed, compare string size
            if (result.lastValue is String && lastValue is String && 
                result.lastValue.compareTo(lastValue) > 0) {
              lastValue = result.lastValue;
            }
          }
          
          // Use the largest sequence number
          if (result.lastSequence > lastSequence) {
            lastSequence = result.lastSequence;
          }
        }
      }
      
      // Update state
      _sequenceMap[tableName] = lastSequence;
      _lastValueMap[tableName] = lastValue;
      _lastValue = lastValue;
      
  
      
      return allGeneratedIds;
    } catch (e) {
      Logger.error('Parallel generate IDs failed: $e', label: 'TimeBasedIdGenerator._generateIdsInParallel');
      
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

    final operationId = '${tableName}_id_get';
    try {
      await _lockManager.acquireExclusiveLock(operationId, 'id_get');

      // Ensure ID pool exists
      if (!_idPools.containsKey(tableName)) {
        _idPools[tableName] = Queue<String>();
      }

      // Prepare result list
      final result = <String>[];

      // Check existing IDs in pool
      if (_idPools[tableName]!.isNotEmpty) {
        // Update last use time
        _idPoolLastUpdateTime[tableName] = DateTime.now();

        // Get IDs from pool until demand is met or pool is empty
        while (result.length < count && _idPools[tableName]!.isNotEmpty) {
          result.add(_idPools[tableName]!.removeFirst());
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

      // Calculate reasonable timeout time - base time 5 seconds + 5 seconds per 1000 IDs
      final remainingCount = count - result.length;
      final timeout = Duration(
        seconds: 5 + ((remainingCount ~/ 1000) * 5),
      );
      // Record start time
      final startTime = DateTime.now();
      final endTime = startTime.add(timeout);

      try {
        // Start asynchronous pool refill, no waiting
        // This will start ID generation process in the background
        _refillIdPool(targetSize, effectiveRecentTotal);

        // Get remaining required IDs from pool with timeout check
        while (result.length < count) {
          // Timeout check: If it has exceeded the set time, exit loop
          if (DateTime.now().isAfter(endTime)) {
            Logger.warn(
                'Get ID timeout: Table=$tableName, Request=$count, Retrieved=${result.length}, Timeout=${timeout.inSeconds} seconds',
                label: 'TimeBasedIdGenerator.getId');
            break; // Exit loop, return retrieved IDs
          }
          // Directly get latest queue state from _idPools
          if (_idPools[tableName]?.isNotEmpty ?? false) {
            result.add(_idPools[tableName]!.removeFirst());
          } else {
            // Briefly wait to yield CPU, avoid tight loop
            await Future.delayed(const Duration(milliseconds: 10));
          }
        }
      } catch (e) {
        Logger.error('ID pool fill or get failed: $e',
            label: 'TimeBasedIdGenerator.getId');
      }

      // If no ID is retrieved, throw exception
      if (result.isEmpty) {
        throw Exception(
            'Unable to generate ID: Pool is empty and fill timeout. Table=$tableName, Request=$count, '
            'Fill in=${_idGenerationInProgress[tableName] ?? false}, '
            'Current pool size=${_idPools[tableName]?.length ?? 0}');
      }

      return result;
    } finally {
      _lockManager.releaseExclusiveLock(operationId, 'id_get');
    }
  }

  /// Update request stats
  void _updateRequestStats(int count) {
    final now = DateTime.now();
    final lastReset = _lastCountResetTime[tableName] ??
        now.subtract(const Duration(seconds: 4));

    // Reset count if more than 3 seconds
    if (now.difference(lastReset).inSeconds > 3) {
      _recentRequestCount[tableName] = count;
      _lastCountResetTime[tableName] = now;
    } else {
      // Accumulate count
      _recentRequestCount[tableName] =
          (_recentRequestCount[tableName] ?? 0) + count;
    }
  }

  /// Get recent request count
  int _getRecentRequestCount() {
    final now = DateTime.now();
    final lastReset = _lastCountResetTime[tableName] ??
        now.subtract(const Duration(seconds: 4));

    // Count over 3 seconds is considered expired
    if (now.difference(lastReset).inSeconds > 3) {
      _recentRequestCount[tableName] = 0;
      _lastCountResetTime[tableName] = now;
      return 0;
    }

    return _recentRequestCount[tableName] ?? 0;
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
    for (final tableName in List.from(_idPoolLastUpdateTime.keys)) {
      final lastUpdateTime = _idPoolLastUpdateTime[tableName];
      if (lastUpdateTime != null &&
          now.difference(lastUpdateTime) > _idPoolExpiry) {
        _idPools.remove(tableName);
        _idPoolLastUpdateTime.remove(tableName);

        Logger.debug('Clean up expired ID pool: $tableName',
            label: 'TimeBasedIdGenerator._cleanupExpiredPools');
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
      throw UnsupportedError('Unsupported ID type: $keyType');
    }
  }

  /// Generate timestamp ID (optimized batch generation logic)
  Future<List<BigInt>> _generateTimestampIds(int count, int recentTotal) async {
    // Use preallocated capacity List and BigInt.zero initialization to avoid null
    final result = List<BigInt>.filled(count, BigInt.zero);

    // Get current state
    int currentTimestamp = _getCurrentLogicalTimestamp();
    int sequence = _sequenceMap[tableName] ?? 0;
    int lastTimestamp = _lastValueMap[tableName] ?? currentTimestamp;

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
      _sequenceMap[tableName] = sequence;
      _lastValueMap[tableName] = timestamp;
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
    _sequenceMap[tableName] = sequence;
    _lastValueMap[tableName] = timestamp;
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
    int sequence = _sequenceMap[tableName] ?? 0;
    String lastDate = _lastValueMap[tableName] ?? currentDateString;

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
      _sequenceMap[tableName] = sequence;
      _lastValueMap[tableName] = dateString;
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
    _sequenceMap[tableName] = sequence;
    _lastValueMap[tableName] = dateString;
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
          final tableName = instance.tableName;

          // Check if pool exists and is not empty (pool with data should not be recycled)
          if (!instance._idPools.containsKey(tableName) ||
              instance._idPools[tableName]!.isEmpty) {
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
          Logger.debug('Recycle idle ID generator instance: $key',
              label: 'TimeBasedIdGenerator._cleanupIdleInstances');
        }
      }
    } catch (e) {
      Logger.error('Clean up idle generator instance failed: $e',
          label: 'TimeBasedIdGenerator._cleanupIdleInstances');
    }
  }

  /// Single instance periodic maintenance
  void _periodicMaintenance() {
    try {
      // Update instance last access time to indicate this instance is still active
      _lastInstanceAccessTime['${keyType}_$tableName'] = DateTime.now();

      // Clean up expired pools
      _cleanupExpiredPools();

      // Get recent request count
      final recentTotal = _getRecentRequestCount();

      // Only perform maintenance check if there's recent request or pool is not empty
      if (recentTotal > 0 || (_idPools[tableName]?.isNotEmpty ?? false)) {
        // Calculate expected pool size
        final expectedPoolSize = _calculateExpectedPoolSize(recentTotal);
        final currentPoolSize = _idPools[tableName]?.length ?? 0;

        // If pool size is less than 70% of expected and current no generation task in progress, trigger refill
        if (currentPoolSize < expectedPoolSize * 0.7 &&
            _idGenerationInProgress[tableName] != true) {
          // Asynchronous refill pool, no waiting for result
          Future.microtask(() => _refillIdPool(expectedPoolSize, recentTotal));
        }
      }
    } catch (e) {
      Logger.error('ID pool periodic maintenance failed: $e',
          label: 'TimeBasedIdGenerator._periodicMaintenance');
    }
  }

  @override
  int get remainingIds => _idPools[tableName]?.length ?? 0;

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
      Logger.warn('Timestamp wait timeout, force increment timestamp',
          label: 'TimeBasedIdGenerator._waitNextTimestamp');
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
      Logger.warn('Date wait timeout, force increment date',
          label: 'TimeBasedIdGenerator._waitNextSecond');

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
          label: 'TimeBasedIdGenerator');
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
      {required String tableName, required int nodeId, required int batchSize});

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
          tableName: schema.name,
          centralClient: centralClient,
        );

      case PrimaryKeyType.timestampBased:
      case PrimaryKeyType.datePrefixed:
      case PrimaryKeyType.shortCode:
        // Create timestamp/date prefixed/short code ID generator - use instance retrieval method
        return TimeBasedIdGenerator.getInstance(
          pkConfig.type,
          config.distributedNodeConfig,
          schema.name,
          maxConcurrent: config.maxConcurrent,
        );

      case PrimaryKeyType.none:
        // Return an empty implementation, user needs to provide ID
        throw UnsupportedError(
            'Unsupported primary key generation type: ${pkConfig.type}');
    }
  }
}
