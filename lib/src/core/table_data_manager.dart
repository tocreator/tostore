import 'dart:async';
import 'dart:convert';
import 'dart:math';
import '../../tostore.dart';
import '../handler/logger.dart';
import '../handler/common.dart';
import '../handler/encoder.dart';
import '../model/buffer_entry.dart';
import 'data_store_impl.dart';
import '../model/store_index.dart';
import '../model/file_info.dart';
import '../handler/platform_handler.dart';
import 'crontab_manager.dart';
import '../model/id_generator.dart';
import '../handler/value_comparator.dart';
import 'compute_manager.dart';
import 'compute_tasks.dart';
import '../model/system_table.dart';
import 'memory_manager.dart';
import '../handler/parallel_processor.dart';

/// table data manager - schedule data read/write, backup, index update, etc.
class TableDataManager {
  final DataStoreImpl _dataStore;

  // Write Buffer: Map<tableName, Map<recordId, BufferEntry>>
  final Map<String, Map<String, BufferEntry>> _writeBuffer = {};
  Map<String, Map<String, BufferEntry>> get writeBuffer => _writeBuffer;

  // Delete Buffer: Map<tableName, Map<recordId, BufferEntry>>
  final Map<String, Map<String, BufferEntry>> _deleteBuffer = {};
  Map<String, Map<String, BufferEntry>> get deleteBuffer => _deleteBuffer;

  // Table refresh status flags
  final Map<String, bool> _tableFlushingFlags = {};

  // List of tables currently being processed, for concurrency control
  final Set<String> _processingTables = {};

  // Last write time
  DateTime _lastWriteTime = DateTime.now().subtract(const Duration(seconds: 5));

  // Write strategy configuration
  static const int _maxBufferSize =
      100; // Maximum queue capacity threshold (per table)

  // Store table partition size configuration (in bytes)
  final Map<String, int> _tablePartitionSizes = {};

  bool _isWriting = false; // Write status flag

  // Store table file size information
  final Map<String, int> _fileSizes = {};
  // Store file last modified time
  final Map<String, DateTime> _lastModifiedTimes = {};
  // Cache for table file meta to avoid repeated reads
  final Map<String, FileMeta> _fileMetaCache = {};
  // Current table metadata cache total size (bytes)
  int _currentTableMetaCacheSize = 0;
  // Table metadata size cache - cache the size of each table metadata to avoid repeated calculation
  final Map<String, int> _tableMetaSizeCache = {};

  /// Add auto-increment ID to write buffer
  final Map<String, dynamic> _maxIds = {};
  final Map<String, bool> _maxIdsDirty = {}; // Mark if need to write

  /// ID generator cache
  final Map<String, IdGenerator> _idGenerators = {};

  /// ID range storage data
  final Map<String, Map<String, dynamic>> _idRanges = {};

  /// Whether table has checked ordered range
  final Map<String, bool> _checkedOrderedRange = {};

  /// Client connected to central server
  CentralServerClient? _centralClient;

  // Total table count tracking
  int _totalTableCount = 0;

  // Total record count tracking for all tables
  int _totalRecordCount = 0;

  // Total data file size (bytes) tracking for all tables
  int _totalDataSizeBytes = 0;

  // Last time statistics were saved
  DateTime? _lastSaveStatsTime;

  // Flag indicating if statistics need to be saved
  bool _needSaveStats = false;

  int get _effectiveMaxConcurrent {
    // Test environment forced single-threaded
    if (PlatformHandler.isTestEnvironment) return 1;

    // User-defined configuration takes precedence
    return _dataStore.config.maxConcurrent;
  }

  /// Estimate table metadata size (bytes)
  int _estimateTableMetaSize(FileMeta meta) {
    // Base structure size
    int size = 100;

    // Table name size
    size += meta.name.length * 2;

    // Partition metadata size
    if (meta.partitions != null) {
      size += meta.partitions!.length * 150; // About 150 bytes per partition
    }

    // Other fields size
    size += 50; // Version, type, size, record count, etc.

    return size;
  }

  /// Clean up table metadata cache
  void _cleanupTableMetaCache() {
    try {
      if (_fileMetaCache.isEmpty) return;

      // Calculate the ratio to be cleared
      final metaCacheLimit =
          _dataStore.memoryManager?.getTableMetaCacheSize() ?? 10000;

      // If the cache is less than the limit, no need to clean up
      if (_currentTableMetaCacheSize < metaCacheLimit * 0.9) return;

      // Calculate target size (70% of the limit)
      final targetSize = (metaCacheLimit * 0.7).toInt();
      final needToRemoveBytes = _currentTableMetaCacheSize - targetSize;

      if (needToRemoveBytes <= 0) return;

      // Optimization: use a bucket approach to avoid full sorting
      // We'll divide time into buckets (e.g., by hour) and process oldest buckets first
      final buckets = <int, List<String>>{};
      int removedSize = 0;

      // System tables to preserve
      final systemTables = <String>{};

      // Single pass to categorize entries into time buckets
      // Use epoch hours as bucket keys (rough time division)
      for (final entry in _fileMetaCache.entries) {
        final tableName = entry.key;

        // Identify system tables to preserve
        if (SystemTable.isSystemTable(tableName)) {
          systemTables.add(tableName);
          continue;
        }

        // Get last access time, convert to bucket
        final lastModified = _lastModifiedTimes[tableName] ?? DateTime(1970);
        // Use hours since epoch as bucket key (coarse-grained time division)
        final bucketKey = lastModified.millisecondsSinceEpoch ~/ 3600000;

        // Add to appropriate bucket
        buckets.putIfAbsent(bucketKey, () => <String>[]).add(tableName);
      }

      // Process buckets from oldest to newest
      final sortedBuckets = buckets.keys.toList()..sort();

      for (final bucketKey in sortedBuckets) {
        final tablesInBucket = buckets[bucketKey]!;

        // Process all tables in this time bucket
        for (final tableName in tablesInBucket) {
          // Skip if we've removed enough already
          if (removedSize >= needToRemoveBytes) break;

          // Remove this entry if not a system table
          if (!systemTables.contains(tableName)) {
            final metaSize = _tableMetaSizeCache[tableName] ?? 0;
            _fileMetaCache.remove(tableName);
            _tableMetaSizeCache.remove(tableName);
            _lastModifiedTimes.remove(tableName);

            removedSize += metaSize;
          }
        }

        // If we've removed enough, stop processing more buckets
        if (removedSize >= needToRemoveBytes) break;
      }

      // Update current cache size
      _currentTableMetaCacheSize -= removedSize;
    } catch (e) {
      Logger.error('Failed to clean up table metadata cache: $e',
          label: 'TableDataManager._cleanupTableMetaCache');
    }
  }

  TableDataManager(this._dataStore) {
    // Register scheduled task to CrontabManager
    CrontabManager.addCallback(ExecuteInterval.seconds3, _processWriteBuffer);

    // Register memory callbacks
    _registerMemoryCallbacks();

    // Initialize auto-increment ID generator and set periodic check task
    CrontabManager.addCallback(
        ExecuteInterval.seconds3, TimeBasedIdGenerator.periodicPoolCheck);

    // Load statistics
    _loadStatisticsFromConfig();

    CrontabManager.addCallback(
        ExecuteInterval.hour24, _updateTableStatisticsIfNeeded);
    // Use delayed execution
    Future.delayed(const Duration(seconds: 10), () {
      _updateTableStatisticsIfNeeded();
    });
  }

  /// Register memory callbacks
  void _registerMemoryCallbacks() {
    final memoryManager = _dataStore.memoryManager;
    if (memoryManager != null) {
      // Register table metadata cache cleanup callback
      memoryManager.registerCacheEvictionCallback(
          CacheType.tableMeta, _cleanupTableMetaCache);
    }
  }

  /// Load statistics from configuration
  Future<void> _loadStatisticsFromConfig() async {
    try {
      final config = await _dataStore.getSpaceConfig();
      if (config != null) {
        _totalTableCount = config.totalTableCount;
        _totalRecordCount = config.totalRecordCount;
        _totalDataSizeBytes = config.totalDataSizeBytes;
      }
    } catch (e) {
      Logger.error('Failed to load table statistics: $e',
          label: 'TableDataManager._loadStatisticsFromConfig');
    }
  }

  /// Update statistics if needed (full scan once per day)
  Future<void> _updateTableStatisticsIfNeeded() async {
    try {
      final config = await _dataStore.getSpaceConfig();
      if (config != null && config.needUpdateStatistics()) {
        await recalculateAllStatistics();
      }
    } catch (e) {
      Logger.error('Failed to check for updated statistics: $e',
          label: 'TableDataManager._updateTableStatisticsIfNeeded');
    }
  }

  /// Calculate statistics for all tables
  Future<void> recalculateAllStatistics() async {
    try {
      // Get all table metadata
      final schemaManager = _dataStore.schemaManager;
      if (schemaManager == null) return;

      final tableNames = await schemaManager.listAllTables();

      int tableCount = tableNames.length;
      int totalRecords = 0;
      int totalSize = 0;

      // Use ParallelProcessor to fetch table metadata concurrently
      final metaList = await ParallelProcessor.execute<FileMeta?>(
        tableNames.map((tableName) {
          return () => getTableFileMeta(tableName);
        }).toList(),
      );

      // Iterate through the results to calculate statistics
      for (final meta in metaList) {
        if (meta != null) {
          // Accumulate record count
          totalRecords += meta.totalRecords;

          // Calculate file size
          if (meta.partitions != null) {
            for (final partition in meta.partitions!) {
              totalSize += partition.fileSizeInBytes;
            }
          }
        }
      }

      // Update statistics
      _totalTableCount = tableCount;
      _totalRecordCount = totalRecords;
      _totalDataSizeBytes = totalSize;

      // Save to configuration
      await _saveStatisticsToConfig();

      Logger.debug(
          'Table statistics calculation completed: table count=$tableCount, record count=$totalRecords, data size=${totalSize / 1024 / 1024}MB',
          label: 'TableDataManager._calculateTableStatistics');
    } catch (e) {
      Logger.error('Failed to calculate table statistics: $e',
          label: 'TableDataManager._calculateTableStatistics');
    }
  }

  /// Save statistics to configuration
  Future<void> _saveStatisticsToConfig() async {
    try {
      final config = await _dataStore.getSpaceConfig();
      if (config != null) {
        final updatedConfig = config.copyWith(
            totalTableCount: _totalTableCount,
            totalRecordCount: _totalRecordCount,
            totalDataSizeBytes: _totalDataSizeBytes,
            lastStatisticsTime: DateTime.now());

        await _dataStore.saveSpaceConfigToFile(updatedConfig);
        _needSaveStats = false;
        _lastSaveStatsTime = DateTime.now();
      }
    } catch (e) {
      Logger.error('Failed to save table statistics: $e',
          label: 'TableDataManager._saveStatisticsToConfig');
    }
  }

  /// Update max ID value (only in memory)
  void updateMaxIdInMemory(String tableName, dynamic id) {
    try {
      // Ensure id is in string format
      String idStr = id.toString();

      // Check if it's a numeric string
      if (!_isNumericString(idStr)) {
        return;
      }

      final currentMaxId = _maxIds[tableName];
      if (currentMaxId == null) {
        // First set max ID
        _maxIds[tableName] = idStr;
        _maxIdsDirty[tableName] = true;
        return;
      }

      // Ensure currentMaxId is also a string
      String currentMaxIdStr = currentMaxId.toString();

      // Compare current value with max value
      if (_compareNumericStrings(idStr, currentMaxIdStr) > 0) {
        _maxIds[tableName] = idStr;
        _maxIdsDirty[tableName] = true;
      }
    } catch (e) {
      Logger.error('Failed to update max ID: $e, tableName=$tableName, id=$id',
          label: 'TableDataManager.updateMaxIdInMemory');
    }
  }

  /// Get next auto-increment ID
  Future<String> getNextId(String tableName) async {
    try {
      // Get table schema
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
        Logger.error('Table schema is null, cannot get next id',
            label: 'TableDataManager.getNextId');
        return '';
      }
      // Check if initialization of auto-increment ID is needed for the table (lazy loading)
      if (schema.primaryKeyConfig.type == PrimaryKeyType.sequential &&
          !_maxIds.containsKey(tableName)) {
        // Load auto-increment ID value only when first used
        await _initTableAutoIncrementId(tableName);
      }

      // Get ID generator
      final generator = await _getIdGenerator(tableName);

      // Use ID pool optimization - batch generation method is implemented internally
      final ids = await generator.getId(1);
      if (ids.isEmpty) {
        throw Exception('Failed to generate ID, returned empty list');
      }

      // If it's a sequential increment type, update max ID value
      if (schema.primaryKeyConfig.type == PrimaryKeyType.sequential) {
        updateMaxIdInMemory(tableName, ids.first);
      }

      // Save ID range (if needed)
      await _saveIdRange(tableName);

      return ids.first;
    } catch (e) {
      Logger.error('Failed to get next ID: $e',
          label: 'TableDataManager.getNextId');
      return '';
    }
  }

  /// Get batch of IDs (used for optimizing bulk insert scenarios)
  Future<List<String>> getBatchIds(String tableName, int count) async {
    try {
      if (count <= 0) return [];

      // Get table schema
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
        return [];
      }
      // Check if initialization of auto-increment ID is needed for the table (lazy loading)
      if (schema.primaryKeyConfig.type == PrimaryKeyType.sequential &&
          !_maxIds.containsKey(tableName)) {
        // Load auto-increment ID value only when first used
        await _initTableAutoIncrementId(tableName);
      }

      // Get ID generator
      final generator = await _getIdGenerator(tableName);

      // Get IDs directly in batch
      final ids = await generator.getId(count);

      // If it's a sequential increment type, update max ID value
      if (schema.primaryKeyConfig.type == PrimaryKeyType.sequential &&
          ids.isNotEmpty) {
        updateMaxIdInMemory(tableName, ids.last);
      }

      // Save ID range (if needed)
      await _saveIdRange(tableName);

      return ids;
    } catch (e) {
      Logger.error('Failed to get batch of IDs: $e',
          label: 'TableDataManager.getBatchIds');
      return [];
    }
  }

  /// Remove scheduled task when instance is closed
  Future<void> dispose() async {
    CrontabManager.removeCallback(
        ExecuteInterval.seconds3, _processWriteBuffer);
    CrontabManager.removeCallback(
        ExecuteInterval.seconds3, TimeBasedIdGenerator.periodicPoolCheck);

    // Cancel register memory callback
    _dataStore.memoryManager
        ?.unregisterCacheEvictionCallback(CacheType.tableMeta);

    try {
      // Flush all pending data (both write and delete buffers)
      await flushAllBuffers();

      // cleanup file size information
      clearFileSizes();

      // cleanup file meta cache and size information
      _fileMetaCache.clear();
      _tableMetaSizeCache.clear();
      _currentTableMetaCacheSize = 0;

      _maxIds.clear();
      _maxIdsDirty.clear();

      // Save ID range information for all tables
      for (final tableName in _idGenerators.keys) {
        await _saveIdRange(tableName);
      }

      // Cleanup ID generator resources
      _idGenerators.clear();
      _idRanges.clear();
      _checkedOrderedRange.clear();

      // Ensure all buffers are cleared
      _writeBuffer.clear();
      _deleteBuffer.clear();
      _processingTables.clear();
    } catch (e) {
      Logger.error('Failed to dispose TableDataManager: $e',
          label: 'TableDataManager.dispose');
    }
  }

  /// Process write buffer
  Future<void> _processWriteBuffer() async {
    try {
      // Check ID range status
      await _checkIdFetch();

      if (_writeBuffer.isEmpty && _deleteBuffer.isEmpty) {
        return;
      }

      // Check if data file write is needed
      if (_isWriting) return;

      // Evaluate write requirements and system status
      bool needsImmediateWrite = false;

      // Condition 1: Check write queue size
      int largestQueueSize = 0;
      String? largestQueueTable;
      int totalRecords = 0;
      final maxBatchSize = _dataStore.config.maxBatchSize;

      for (final entry in _writeBuffer.entries) {
        final queueSize = entry.value.length;
        totalRecords += queueSize;

        if (queueSize > largestQueueSize) {
          largestQueueSize = queueSize;
          largestQueueTable = entry.key;
        }

        if (queueSize >= _maxBufferSize) {
          needsImmediateWrite = true;
          break;
        }
      }

      // Condition 1b: Check delete queue size
      int largestDeleteQueueSize = 0;
      String? largestDeleteQueueTable;
      int totalDeleteRecords = 0;

      for (final entry in _deleteBuffer.entries) {
        final queueSize = entry.value.length;
        totalDeleteRecords += queueSize;

        if (queueSize > largestDeleteQueueSize) {
          largestDeleteQueueSize = queueSize;
          largestDeleteQueueTable = entry.key;
        }

        if (queueSize >= _maxBufferSize) {
          needsImmediateWrite = true;
          break;
        }
      }

      // Update total records count to include both write and delete records
      totalRecords += totalDeleteRecords;

      // Condition 2: Check idle time
      final idleWriteDuration = DateTime.now().difference(_lastWriteTime);
      if (idleWriteDuration >= const Duration(seconds: 5)) {
        needsImmediateWrite = true;
      }

      // Condition 3: Number of tables with pending writes or deletes
      final totalTablesCount = _writeBuffer.length + _deleteBuffer.length;
      if (totalTablesCount >= _dataStore.config.maxTablesPerFlush * 1.5) {
        needsImmediateWrite = true;
      }

      // Condition 4: Total records exceed threshold should also write
      if (totalRecords >= maxBatchSize * 2) {
        needsImmediateWrite = true;
      }

      if (needsImmediateWrite &&
          ((_writeBuffer.isNotEmpty || _deleteBuffer.isNotEmpty)) &&
          !_isWriting) {
        _isWriting = true;
        Logger.debug(
            'Starting batch operation, table count: ${_writeBuffer.length} write + ${_deleteBuffer.length} delete, largest write queue: ${largestQueueTable ?? "none"} ($largestQueueSize records), largest delete queue: ${largestDeleteQueueTable ?? "none"} ($largestDeleteQueueSize records), total records: $totalRecords',
            label: 'TableDataManager._processWriteBuffer');
        try {
          // Record start time for performance monitoring
          final startTime = DateTime.now();

          // Execute write operation
          await flushWriteBuffer();

          // Execute delete operation
          await flushDeleteBuffer();

          // Handle auto-increment ID save
          await flushMaxIds();

          // Update last write time
          _lastWriteTime = DateTime.now();

          // Record write performance data
          final writeDuration =
              _lastWriteTime.difference(startTime).inMilliseconds;
          if ((largestQueueTable != null && largestQueueSize > 100) ||
              (largestDeleteQueueTable != null &&
                  largestDeleteQueueSize > 100)) {
            Logger.debug(
                'Batch operation completed, duration: ${writeDuration}ms, largest write queue: ${largestQueueTable ?? "none"} ($largestQueueSize records), largest delete queue: ${largestDeleteQueueTable ?? "none"} ($largestDeleteQueueSize records)',
                label: 'TableDataManager._processWriteBuffer');
          }
        } finally {
          _isWriting = false;
          // After processing, if statistics need to be saved and it's been more than 15 seconds since last save, then save
          final now = DateTime.now();
          if (_needSaveStats &&
              (_lastSaveStatsTime == null ||
                  now.difference(_lastSaveStatsTime!).inSeconds > 15)) {
            await _saveStatisticsToConfig();
            _lastSaveStatsTime = now;
          }
        }
      }
    } catch (e, stackTrace) {
      Logger.error('Scheduled processing failed: $e\n$stackTrace',
          label: 'TableDataManager._processWriteBuffer');
      _isWriting = false;
    }
  }

  /// Flush max IDs to disk
  Future<void> flushMaxIds() async {
    try {
      for (var entry in _maxIdsDirty.entries) {
        if (!entry.value) continue;

        final tableName = entry.key;
        final maxId = _maxIds[tableName];

        if (maxId == null) continue;

        final maxIdPath =
            await _dataStore.pathManager.getAutoIncrementPath(tableName);

        await _dataStore.storage.writeAsString(maxIdPath, maxId.toString());
        _maxIdsDirty[tableName] = false;
      }
    } catch (e) {
      Logger.error(
        'Failed to flush max IDs: $e',
        label: 'TableDataManager.flushMaxIds',
      );
    }
  }

  /// Get partition size limit for a table
  int _getPartitionSizeLimit(String tableName) {
    // If table has specific partition size configuration, use it
    if (_tablePartitionSizes.containsKey(tableName)) {
      final configuredSize = _tablePartitionSizes[tableName]!;

      // Ensure configured partition size doesn't exceed system maximum
      final systemMax = _dataStore.config.maxPartitionFileSize;
      if (configuredSize > systemMax) {
        Logger.warn(
          'Table $tableName configured partition size ${configuredSize ~/ 1024}KB exceeds system limit ${systemMax ~/ 1024}KB, will use system limit',
          label: 'TableDataManager._getPartitionSizeLimit',
        );
        return systemMax;
      }

      // Ensure partition size has a reasonable minimum value
      const minSize = 10 * 1024; // 10KB
      if (configuredSize < minSize) {
        Logger.warn(
          'Table $tableName configured partition size ${configuredSize ~/ 1024}KB is too small, will use minimum value ${minSize ~/ 1024}KB',
          label: 'TableDataManager._getPartitionSizeLimit',
        );
        return minSize;
      }

      return configuredSize;
    }

    // Otherwise return default value from DataStoreConfig
    return _dataStore.config.maxPartitionFileSize;
  }

  /// Set partition size limit for a table
  void setTablePartitionSize(String tableName, int sizeInBytes) {
    if (sizeInBytes <= 0) {
      Logger.warn(
        'Attempted to set partition size for table $tableName to $sizeInBytes, invalid value, will use default',
        label: 'TableDataManager.setTablePartitionSize',
      );
      _tablePartitionSizes
          .remove(tableName); // Remove invalid config, use default
      return;
    }

    _tablePartitionSizes[tableName] = sizeInBytes;

    // Log configuration change
    Logger.debug(
      'Set partition size for table $tableName to ${sizeInBytes ~/ 1024}KB',
      label: 'TableDataManager.setTablePartitionSize',
    );
  }

  /// Get partition size limit for a table (public method)
  int getTablePartitionSize(String tableName) {
    return _getPartitionSizeLimit(tableName);
  }

  /// add to write buffer
  Future<void> addToWriteBuffer(String tableName, Map<String, dynamic> data,
      {bool isUpdate = false}) async {
    final tableQueue = _writeBuffer.putIfAbsent(tableName, () => {});
    // Get table's primary key field
    final schema = await _dataStore.getTableSchema(tableName);
    if (schema == null) {
      Logger.error('Table schema is null, cannot add to write buffer',
          label: 'TableDataManager.addToWriteBuffer');
      return;
    }
    final primaryKey = schema.primaryKey;
    // Use primary key value as record's unique identifier
    final recordId = data[primaryKey]?.toString();
    if (recordId == null) {
      Logger.error(
        'Record in table $tableName does not have a primary key value, cannot add to write buffer',
        label: 'TableDataManager-addToWriteBuffer',
      );
      return;
    }
    tableQueue[recordId] = BufferEntry(
      data: data,
      operation:
          isUpdate ? BufferOperationType.update : BufferOperationType.insert,
      timestamp: DateTime.now(),
    );

    // Record data change, need to update statistics
    _needSaveStats = true;
  }

  /// Add records to delete buffer - for batch deleting
  Future<void> addToDeleteBuffer(
      String tableName, List<Map<String, dynamic>> records) async {
    if (records.isEmpty) return;

    // Get table schema to extract primary key
    final schema = await _dataStore.getTableSchema(tableName);
    if (schema == null) {
      Logger.error('Table schema is null, cannot add to delete buffer',
          label: 'TableDataManager.addToDeleteBuffer');
      return;
    }

    final primaryKey = schema.primaryKey;
    final tableQueue = _deleteBuffer.putIfAbsent(tableName, () => {});

    // Process each record
    for (final record in records) {
      final recordId = record[primaryKey]?.toString();
      if (recordId == null) {
        Logger.warn(
          'Record in table $tableName does not have a primary key value, skipping',
          label: 'TableDataManager.addToDeleteBuffer',
        );
        continue;
      }

      // if record is already in write buffer, remove it, because it is not written to file, no need to add to delete buffer
      if (_writeBuffer.containsKey(tableName) &&
          _writeBuffer[tableName]!.containsKey(recordId)) {
        _writeBuffer[tableName]!.remove(recordId);
        continue;
      }

      // Store in delete buffer
      tableQueue[recordId] = BufferEntry(
        operation: BufferOperationType.delete,
        data: record,
        timestamp: DateTime.now(),
      );
    }

    // Record data change, need to update statistics
    _needSaveStats = true;
  }

  /// Flush single table buffer
  Future<void> _flushTableBuffer(String tableName, {int? concurrency}) async {
    // Use lock manager's exclusive lock to ensure data for the same table isn't processed concurrently
    final lockKey = 'table_$tableName';
    bool lockAcquired = false;

    // Try to acquire lock, skip this processing if already occupied
    if (_dataStore.lockManager != null) {
      if (!_dataStore.lockManager!.tryAcquireExclusiveLock(lockKey)) {
        Logger.debug(
            'Table $tableName is being processed by another operation, skipping this flush',
            label: 'TableDataManager._flushTableBuffer');
        return;
      }
      lockAcquired = true;
      _processingTables.add(tableName);
    } else if (_processingTables.contains(tableName)) {
      // Without lock manager, use _processingTables as simple reentry prevention
      Logger.debug('Table $tableName is being processed, skipping this flush',
          label: 'TableDataManager._flushTableBuffer');
      return;
    } else {
      _processingTables.add(tableName);
    }

    try {
      // Check buffer state again (may have been modified while acquiring lock)
      if (!_writeBuffer.containsKey(tableName) ||
          _writeBuffer[tableName]!.isEmpty) {
        return;
      }

      final totalQueueSize = _writeBuffer[tableName]!.length;
      final maxBatchSize =
          _dataStore.config.maxBatchSize * _effectiveMaxConcurrent;

      Logger.debug(
          'Starting to process write buffer for table $tableName, queue size: $totalQueueSize',
          label: 'TableDataManager._flushTableBuffer');

      // Record start time
      final startTime = DateTime.now();
      // Track processed records
      int recordsProcessed = 0;

      // Continue processing buffer as long as there's data and table buffer exists
      while (_writeBuffer.containsKey(tableName) &&
          !(_writeBuffer[tableName]?.isEmpty ?? true)) {
        // Get current queue size
        final currentQueueSize = _writeBuffer[tableName]!.length;

        // If we've processed all data from the initial queue and remaining data is less than a batch, stop processing
        // This avoids frequent processing of small batches, improving efficiency
        if (recordsProcessed >= totalQueueSize &&
            currentQueueSize < maxBatchSize) {
          break;
        }

        // Determine batch size for this iteration, directly from current buffer state
        final currentBatchSize = min(currentQueueSize, maxBatchSize);

        if (currentBatchSize <= 0) {
          break;
        }

        // Get latest keys directly from current buffer
        final keysToProcess = _writeBuffer[tableName]!
            .keys
            .take(currentBatchSize.toInt())
            .toList();

        if (keysToProcess.isEmpty ||
            (_writeBuffer[tableName]?.isEmpty ?? true)) {
          _writeBuffer.remove(tableName);
          break;
        }

        // Group by operation type
        final insertRecords = <Map<String, dynamic>>[];
        final updateRecords = <Map<String, dynamic>>[];
        // Store processed entries for error recovery
        final processedEntries = <String, BufferEntry>{};

        // Extract data from original buffer and remove immediately
        for (final key in keysToProcess) {
          final entry = _writeBuffer[tableName]?[key];
          if (entry != null) {
            processedEntries[key] = entry;
            _writeBuffer[tableName]!
                .remove(key); // Remove from original buffer immediately

            final data = entry.data;
            final operation = entry.operation;

            if (operation == BufferOperationType.update) {
              updateRecords.add(data);
            } else {
              insertRecords.add(data);
            }
          }
        }

        // If table buffer is now empty, remove it from write buffer
        if (_writeBuffer[tableName]?.isEmpty ?? true) {
          _writeBuffer.remove(tableName);
        }

        try {
          // Process insert and update operations separately
          if (insertRecords.isNotEmpty) {
            await writeRecords(
                tableName: tableName,
                records: insertRecords,
                operationType: BufferOperationType.insert,
                concurrency: concurrency);
          }

          if (updateRecords.isNotEmpty) {
            await writeRecords(
                tableName: tableName,
                records: updateRecords,
                operationType: BufferOperationType.update,
                concurrency: concurrency);
          }

          recordsProcessed += processedEntries.length;

          // After current batch is processed, yield execution thread to avoid blocking UI
          if (_writeBuffer.containsKey(tableName) &&
              !(_writeBuffer[tableName]?.isEmpty ?? true)) {
            await Future.delayed(Duration.zero);
          }
        } catch (e) {
          Logger.error('Failed to process data for table $tableName: $e',
              label: 'TableDataManager._flushTableBuffer');

          // failed to process data, add data back to buffer
          final tableBuffer = _writeBuffer.putIfAbsent(tableName, () => {});
          tableBuffer.addAll(processedEntries);
          break; // stop processing when error occurs
        }
      }

      final endTime = DateTime.now();
      final processingDuration = endTime.difference(startTime).inMilliseconds;

      Logger.debug(
          'Table $tableName buffer processing completed, processed $recordsProcessed/$totalQueueSize records, time: ${processingDuration}ms, remaining ${_writeBuffer[tableName]?.length ?? 0} records',
          label: 'TableDataManager._flushTableBuffer');
    } catch (e, stackTrace) {
      Logger.error('Failed to flush table $tableName buffer: $e',
          label: 'TableDataManager._flushTableBuffer');
      Logger.error(stackTrace.toString(),
          label: 'TableDataManager._flushTableBuffer');
    } finally {
      // ensure to release lock and remove from processing list whether success or failed
      _processingTables.remove(tableName);
      if (lockAcquired && _dataStore.lockManager != null) {
        _dataStore.lockManager!.releaseExclusiveLock(lockKey);
      }
    }
  }

  /// flush write queue
  Future<void> flushWriteBuffer() async {
    // flush max id to disk
    if (_maxIdsDirty.values.any((isDirty) => isDirty)) {
      await flushMaxIds();
    }

    if (_writeBuffer.isEmpty) return;

    final tableCount = _writeBuffer.length;
    final totalRecords =
        _writeBuffer.values.fold(0, (sum, table) => sum + table.length);

    Logger.debug(
        'Start to flush write buffer, table count: $tableCount, total records: $totalRecords',
        label: 'TableDataManager.flushWriteBuffer');

    try {
      // get configured batch processing parameters
      final maxTablesPerFlush = _dataStore.config.maxTablesPerFlush;
      final maxBatchSize = _dataStore.config.maxBatchSize;

      // remove tables being processed to avoid duplicate processing
      final availableTables = _writeBuffer.keys
          .where((tableName) => !_processingTables.contains(tableName))
          .toList();

      if (availableTables.isEmpty) {
        return;
      }

      // record start time for monitoring processing time
      final startTime = DateTime.now();

      // sort tables by priority (larger queue size has higher priority)
      availableTables.sort((a, b) =>
          (_writeBuffer[b]?.length ?? 0) - (_writeBuffer[a]?.length ?? 0));

      // filter out tables with queue size reaching batch processing threshold
      final highPriorityTables = availableTables
          .where(
              (table) => (_writeBuffer[table]?.length ?? 0) >= maxBatchSize / 2)
          .take(maxTablesPerFlush)
          .toList();

      // if no high priority tables, take the largest tables
      final tablesToProcess = highPriorityTables.isNotEmpty
          ? highPriorityTables
          : availableTables
              .take(min(maxTablesPerFlush, availableTables.length))
              .toList();

      if (tablesToProcess.isEmpty) {
        return;
      }

      // mark these tables as being processed
      for (final tableName in tablesToProcess) {
        _processingTables.add(tableName);
      }

      // Dynamic Concurrency Distribution
      final totalConcurrency = _effectiveMaxConcurrent;
      final numTables = tablesToProcess.length;
      final baseConcurrency = totalConcurrency ~/ numTables;
      final remainder = totalConcurrency % numTables;

      final concurrencyPerTable = List.generate(
          numTables, (i) => baseConcurrency + (i < remainder ? 1 : 0));

      // Process tables in parallel using ParallelProcessor
      await ParallelProcessor.execute<void>(
        List.generate(tablesToProcess.length, (index) {
          final tableName = tablesToProcess[index];
          final concurrencyForThisTable = concurrencyPerTable[index];
          return () async {
            if (_writeBuffer.containsKey(tableName) &&
                !(_writeBuffer[tableName]?.isEmpty ?? true)) {
              await _flushTableBuffer(tableName,
                  concurrency: concurrencyForThisTable);
            } else {
              // if found table is empty before processing, remove it from processing list
              _processingTables.remove(tableName);
              _writeBuffer.remove(tableName);
            }
          };
        }),
        // The outer concurrency is still governed by ParallelProcessor's default,
        // which is set to _effectiveMaxConcurrent.
        timeout: ParallelProcessor.noTimeout,
      );

      // after processing, record the result
      final endTime = DateTime.now();
      final duration = endTime.difference(startTime).inMilliseconds;

      // check how many tables and records are left to process
      final remainingTables = _writeBuffer.length;
      final remainingRecords =
          _writeBuffer.values.fold(0, (sum, table) => sum + table.length);

      if (remainingTables > 0) {
        Logger.debug(
            'This flush processed ${tablesToProcess.length} tables, time: ${duration}ms, there are $remainingTables tables and $remainingRecords records left to process',
            label: 'TableDataManager.flushWriteBuffer');
      } else {
        Logger.debug(
            'All table buffers flushed, processed ${tablesToProcess.length} tables, time: ${duration}ms',
            label: 'TableDataManager.flushWriteBuffer');
      }
    } catch (e, stackTrace) {
      Logger.error('Failed to flush write buffer: $e',
          label: 'TableDataManager.flushWriteBuffer');
      Logger.error(stackTrace.toString(),
          label: 'TableDataManager.flushWriteBuffer');

      // when error occurs, clear the processing table marks
      _processingTables.clear();
    }
  }

  /// Flush all pending write and delete buffers
  Future<void> flushAllBuffers() async {
    // First flush write buffer
    await flushWriteBuffer();

    // Then flush delete buffer
    await flushDeleteBuffer();

    // Finally flush max IDs
    await flushMaxIds();
  }

  /// get total table count
  int getTotalTableCount() {
    return _totalTableCount;
  }

  /// get total record count
  int getTotalRecordCount() {
    return _totalRecordCount;
  }

  /// get total data size (bytes)
  int getTotalDataSizeBytes() {
    return _totalDataSizeBytes;
  }

  /// mark stats data need to be updated
  void markStatsDirty() {
    _needSaveStats = true;
  }

  /// table created, update stats
  void tableCreated(String tableName) {
    _totalTableCount++;
    markStatsDirty();
  }

  /// table deleted, update stats
  Future<void> tableDeleted(String tableName) async {
    try {
      // get current table stats
      final meta = await getTableFileMeta(tableName);
      if (meta != null) {
        // update total record count and total size
        _totalRecordCount = max(0, _totalRecordCount - meta.totalRecords);
        _totalDataSizeBytes =
            max(0, _totalDataSizeBytes - meta.fileSizeInBytes);
      }

      // update table count
      _totalTableCount = max(0, _totalTableCount - 1);

      markStatsDirty();
    } catch (e) {
      Logger.error('Failed to update table deleted stats: $e',
          label: 'TableDataManager.tableDeleted');
    }
  }

  /// get table record count by table name
  Future<int> getTableRecordCount(String tableName) async {
    // check if table is fully cached
    if (await _dataStore.dataCacheManager.isTableFullyCached(tableName)) {
      final cacheCount =
          _dataStore.dataCacheManager.getTableCacheCount(tableName);
      return cacheCount;
    }
    // get total records from meta
    final meta = await getTableFileMeta(tableName);
    final metadataCount = meta?.totalRecords ?? 0;

    // check pending records in write buffer
    final pendingRecords = _writeBuffer[tableName];
    if (pendingRecords == null || pendingRecords.isEmpty) {
      return metadataCount; // no pending records
    }

    // calculate pending insert records count (only count insert operation, not update operation)
    int pendingInsertCount = 0;
    for (final entry in pendingRecords.entries) {
      if (entry.value.operation == BufferOperationType.insert) {
        pendingInsertCount++;
      }
    }

    return metadataCount + pendingInsertCount;
  }

  /// get table file size
  Future<int> getTableFileSize(String tableName) async {
    if (!_fileSizes.containsKey(tableName)) {
      final meta = await getTableFileMeta(tableName);
      return meta?.fileSizeInBytes ?? 0;
    }
    return _fileSizes[tableName] ?? 0;
  }

  /// update table file size and modified time
  Future<void> updateFileSize(String tableName, int size) async {
    _fileSizes[tableName] = size;
    _lastModifiedTimes[tableName] = DateTime.now();
  }

  /// check if allow full table cache
  Future<bool> allowFullTableCache(String tableName) async {
    try {
      final recordCount = await getTableRecordCount(tableName);
      if (recordCount > 0) {
        if (await _dataStore.dataCacheManager.isTableFullyCached(tableName)) {
          return false;
        }
      }

      final cachedTables = _dataStore.dataCacheManager.getAllFullTableCaches();
      int totalSize = 0;
      for (final cachedTable in cachedTables) {
        totalSize += await getTableFileSize(cachedTable);
      }

      // Get record cache size using MemoryManager
      final recordCacheSize =
          _dataStore.memoryManager?.getRecordCacheSize() ?? 10000000;
      // Check if file size exceeds limit
      return recordCacheSize * 0.9 > totalSize;
    } catch (e) {
      Logger.error('Failed to check if allow full table cache: $e',
          label: 'TableDataManager.allowFullTableCache');
      return false;
    }
  }

  /// check if file is modified
  bool isFileModified(String tableName, DateTime lastReadTime) {
    final lastModified = _lastModifiedTimes[tableName];
    return lastModified == null || lastModified.isAfter(lastReadTime);
  }

  /// get file last modified time
  DateTime? getLastModifiedTime(String tableName) {
    return _lastModifiedTimes[tableName];
  }

  /// cleanup table size information
  void clearFileSizes() {
    _fileSizes.clear();
    _lastModifiedTimes.clear();
  }

  /// Get table meta information
  Future<FileMeta?> getTableFileMeta(String tableName) async {
    // Check cache first
    if (_fileMetaCache.containsKey(tableName)) {
      return _fileMetaCache[tableName];
    }
    try {
      final mainFilePath =
          await _dataStore.pathManager.getDataMetaPath(tableName);
      if (!await _dataStore.storage.existsFile(mainFilePath)) {
        return null;
      }
      try {
        final decodedString =
            await _dataStore.storage.readAsString(mainFilePath);
        if (decodedString == null) {
          Logger.error("Failed to decode file meta: $mainFilePath",
              label: 'TableDataManager.getTableFileMeta');
          return null;
        }

        // parse JSON
        Map<String, dynamic> jsonData;
        try {
          jsonData = jsonDecode(decodedString) as Map<String, dynamic>;
        } catch (e) {
          Logger.error(
              "Failed to parse JSON meta: $e\ncontent: ${decodedString.substring(0, min(100, decodedString.length))}...",
              label: 'TableDataManager.getTableFileMeta');
          return null;
        }

        final fileInfo = FileInfo.fromJson(jsonData);

        // Estimate metadata size
        final metaSize = _estimateTableMetaSize(fileInfo.meta);

        // Check if metadata cache exceeds limit
        final metaCacheLimit =
            _dataStore.memoryManager?.getTableMetaCacheSize() ?? 10000;
        if (_currentTableMetaCacheSize + metaSize > metaCacheLimit * 0.9) {
          // If exceeds limit, trigger metadata cache cleanup
          _cleanupTableMetaCache();
        }

        // Cache the meta for future use
        _fileMetaCache[tableName] = fileInfo.meta;
        _tableMetaSizeCache[tableName] = metaSize;
        _currentTableMetaCacheSize += metaSize;

        // Update last access time
        _lastModifiedTimes[tableName] = DateTime.now();

        return fileInfo.meta;
      } catch (e, stack) {
        Logger.error('Failed to read table meta: $e\n$stack',
            label: 'TableDataManager.getTableFileMeta');
        return null;
      }
    } catch (e) {
      return null;
    }
  }

  /// Update table file meta
  Future<void> updateTableFileMeta(String tableName, FileMeta meta,
      {bool recalculateTotals = true}) async {
    final mainFilePath =
        await _dataStore.pathManager.getDataMetaPath(tableName);

    // Create directory if not exists
    final partitionsDir =
        await _dataStore.pathManager.getPartitionsDirPath(tableName);
    await _ensureDirectoryExists(partitionsDir);

    // If we need to recalculate totals, calculate from partition data
    if (recalculateTotals &&
        meta.partitions != null &&
        meta.partitions!.isNotEmpty) {
      int totalRecords = 0;
      int totalSize = 0;

      for (var partition in meta.partitions!) {
        if (partition.totalRecords > 0) {
          totalRecords += partition.totalRecords;
          totalSize += partition.fileSizeInBytes;
        }
      }

      meta = meta.copyWith(
        totalRecords: totalRecords,
        fileSizeInBytes: totalSize,
        timestamps: meta.timestamps,
      );
    }

    // Create FileInfo with updated meta
    final fileInfo = FileInfo(
      path: mainFilePath,
      meta: meta,
      // data field is not needed for main file
    );

    try {
      // Get previous metadata size (if exists)
      final oldSize = _tableMetaSizeCache[tableName] ?? 0;

      // Calculate new metadata size
      final newSize = _estimateTableMetaSize(meta);

      // Update cache size count
      if (oldSize > 0) {
        _currentTableMetaCacheSize =
            _currentTableMetaCacheSize - oldSize + newSize;
      } else {
        _currentTableMetaCacheSize += newSize;
      }

      // update cache in memory first, ensure subsequent read can get the latest value
      _fileMetaCache[tableName] = meta;
      _tableMetaSizeCache[tableName] = newSize;
      _lastModifiedTimes[tableName] = DateTime.now();

      // then write to file
      await _dataStore.storage
          .writeAsString(mainFilePath, jsonEncode(fileInfo.toJson()));
    } catch (e) {
      Logger.error('Failed to update table meta: $e',
          label: 'TableDataManager.updateTableFileMeta');
      // Re-throw to handle at higher level
      rethrow;
    }

    // update file size
    updateFileSize(tableName, meta.fileSizeInBytes);
  }

  /// Ensure directory exists
  Future<void> _ensureDirectoryExists(String path) async {
    await _dataStore.storage.ensureDirectoryExists(path);
  }

  /// Save a partition file
  Future<PartitionMeta> _savePartitionFile(
    String tableName,
    bool isGlobal,
    int partitionIndex,
    List<Map<String, dynamic>> records,
    String primaryKey,
    List<PartitionMeta>? existingPartitions, {
    required BufferOperationType operationType,
    List<int>? encryptionKey,
    int? encryptionKeyId,
  }) async {
    try {
      // if no records, return empty partition meta
      if (records.isEmpty) {
        // delete partition file if exists
        final partitionPath = await _dataStore.pathManager
            .getPartitionFilePath(tableName, partitionIndex);
        if (await _dataStore.storage.existsFile(partitionPath)) {
          await _dataStore.storage.deleteFile(partitionPath);
        }

        return PartitionMeta(
          version: 1,
          index: partitionIndex,
          totalRecords: 0,
          fileSizeInBytes: 0,
          minPrimaryKey: null,
          maxPrimaryKey: null,
          checksum: "",
          timestamps: Timestamps(
            created: DateTime.now(),
            modified: DateTime.now(),
          ),
          parentPath: await _dataStore.pathManager.getTablePath(tableName),
        );
      }

      final timeStamp = DateTime.now();
      final partitionPath = await _dataStore.pathManager
          .getPartitionFilePath(tableName, partitionIndex);
      final parentPath = await _dataStore.pathManager.getTablePath(tableName);

      // calculate non-deleted record count (only for statistics)

      // handle primary key range
      dynamic minPk, maxPk;
      bool shouldSaveKeyRange = false;

      // check if primary key is ordered
      shouldSaveKeyRange = await _isPrimaryKeyOrdered(tableName);

      // handle primary key range based on operation type
      if (operationType == BufferOperationType.update ||
          operationType == BufferOperationType.delete) {
        // for update and delete operation, get range from existing partitions
        if (existingPartitions != null) {
          for (final partition in existingPartitions) {
            if (partition.index == partitionIndex) {
              minPk = partition.minPrimaryKey;
              maxPk = partition.maxPrimaryKey;
              break;
            }
          }
        }
      }
      // for insert and rewrite operation, calculate range
      else if ((operationType == BufferOperationType.insert ||
              operationType == BufferOperationType.rewrite) &&
          shouldSaveKeyRange &&
          records.isNotEmpty) {
        try {
          final request = PartitionRangeAnalysisRequest(
            records:
                records, // pass all records, internal will filter deleted records
            primaryKey: primaryKey,
            partitionIndex: partitionIndex,
            existingPartitions: existingPartitions,
          );

          // use ComputeManager to execute range analysis
          PartitionRangeAnalysisResult rangeResult;
          try {
            rangeResult = await ComputeManager.run(
                analyzePartitionKeyRange, request,
                useIsolate: records.length > 500 ||
                    (existingPartitions?.length ?? 0) > 1000);
          } catch (computeError) {
            Logger.error(
                'Error running analyzePartitionKeyRange in ComputeManager: $computeError',
                label: 'TableDataManager._savePartitionFile');

            // if compute error, call function directly
            rangeResult = await analyzePartitionKeyRange(request);
          }

          // ensure result is valid before using
          minPk = rangeResult.minPk;
          maxPk = rangeResult.maxPk;

          // If analysis result is not ordered, mark table as non-ordered
          if (!rangeResult.isOrdered) {
            await _markTableAsUnordered(tableName);
          }

          // check again, because partition analysis may change the table's ordered state
          shouldSaveKeyRange = _checkedOrderedRange.containsKey(tableName)
              ? _checkedOrderedRange[tableName]!
              : await _isPrimaryKeyOrdered(tableName);
        } catch (e) {
          // handle exception
          Logger.error('Error analyzing partition key range: $e',
              label: 'TableDataManager._savePartitionFile');
          minPk = null;
          maxPk = null;
          shouldSaveKeyRange = false;
        }
      }

      // if table is not ordered, clear primary key range
      if (!shouldSaveKeyRange) {
        minPk = null;
        maxPk = null;
      }

      // use ComputeManager.run, fallback to main thread if failed
      final encodeResult = await ComputeManager.run(
          encodePartitionData,
          EncodePartitionRequest(
            records: records,
            partitionIndex: partitionIndex,
            primaryKey: primaryKey,
            minPk: minPk,
            maxPk: maxPk,
            partitionPath: partitionPath,
            parentPath: parentPath,
            timestamps: Timestamps(
              created: timeStamp,
              modified: timeStamp,
            ),
            encryptionKey: encryptionKey,
            encryptionKeyId: encryptionKeyId,
            // Only pass encoderState when no specific encryption key/keyId provided (avoid conflicts with migration data)
            encoderState: (encryptionKey == null && encryptionKeyId == null)
                ? EncoderHandler.getCurrentEncodingState()
                : null,
          ),
          useIsolate: records.length > 500);

      final encodedData = encodeResult.encodedData;
      final updatedPartitionMeta = encodeResult.partitionMeta;

      // Ensure partition directory exists
      final dirPath = await _dataStore.pathManager
          .getPartitionDirPath(tableName, partitionIndex);
      await _ensureDirectoryExists(dirPath);

      // Write partition file
      await _dataStore.storage.writeAsBytes(partitionPath, encodedData);

      // Record operation duration
      final endTime = DateTime.now();
      final duration = endTime.difference(timeStamp);
      Logger.debug(
          'Partition $partitionIndex write completed, time: ${duration.inMilliseconds}ms',
          label: 'TableDataManager._savePartitionFile');

      // return updated partition meta
      return updatedPartitionMeta;
    } catch (e, stack) {
      Logger.error('Failed to save partition file: $e\n$stack',
          label: 'TableDataManager._savePartitionFile');
      rethrow;
    }
  }

  /// mark table as non-ordered range
  Future<void> _markTableAsUnordered(String tableName) async {
    try {
      final meta = await getTableFileMeta(tableName);
      if (meta == null) return;

      // already non-ordered, no need to update
      if (meta.isOrdered == false) return;

      // update meta
      final updatedMeta = meta.copyWith(isOrdered: false);
      await updateTableFileMeta(tableName, updatedMeta);

      // update cache
      _checkedOrderedRange[tableName] = false;

      Logger.debug('Table $tableName is marked as non-ordered range',
          label: 'TableDataManager._markTableAsUnordered');
    } catch (e) {
      Logger.error('Failed to mark table as non-ordered range: $e',
          label: 'TableDataManager._markTableAsUnordered');
    }
  }

  /// assign records to partitions
  Future<Map<int, List<Map<String, dynamic>>>> _assignRecordsToPartitions(
      String tableName, List<Map<String, dynamic>> records, String primaryKey,
      {bool useExistingPartitions = true}) async {
    if (records.isEmpty) {
      return <int, List<Map<String, dynamic>>>{};
    }

    try {
      final fileMeta = await getTableFileMeta(tableName);
      final partitionSizeLimit = _getPartitionSizeLimit(tableName);
      int currentPartitionIndex = 0;
      int currentPartitionSize = 0;

      // initialize partition info
      if (fileMeta != null &&
          fileMeta.partitions != null &&
          fileMeta.partitions!.isNotEmpty &&
          useExistingPartitions) {
        // find the last non-empty partition as starting partition
        PartitionMeta? lastPartition;
        for (var partition in fileMeta.partitions!) {
          if (partition.totalRecords > 0) {
            if (lastPartition == null ||
                partition.index > lastPartition.index) {
              lastPartition = partition;
            }
          }
        }

        // set current partition index and size
        if (lastPartition != null) {
          currentPartitionIndex = lastPartition.index;
          currentPartitionSize = lastPartition.fileSizeInBytes;

          // check if current partition is close to full load
          if (currentPartitionSize >= partitionSizeLimit * 0.9) {
            // if current partition is close to full load, use next partition index
            currentPartitionIndex = lastPartition.index + 1;
            currentPartitionSize = 0;
          }
        } else {
          // no non-empty partition, use index 0
          currentPartitionIndex = 0;
          currentPartitionSize = 0;
        }
      }

      final assignmentResult = await ComputeManager.run(
          assignRecordsToPartitions,
          PartitionAssignmentRequest(
            records: records,
            partitionSizeLimit: partitionSizeLimit,
            currentPartitionIndex: currentPartitionIndex,
            currentPartitionSize: currentPartitionSize,
          ),
          useIsolate: records.length > 1000);
      Logger.debug(
          'Partition assignment completed, ${assignmentResult.partitionRecords.length} partitions, ${records.length} records',
          label: 'TableDataManager._assignRecordsToPartitions');
      return assignmentResult.partitionRecords;
    } catch (e) {
      Logger.error('Failed to assign records to partitions: $e',
          label: 'TableDataManager._assignRecordsToPartitions');

      // if error, put all records into single partition
      final result = <int, List<Map<String, dynamic>>>{};
      result[0] = List.from(records);
      return result;
    }
  }

  /// get id generator, create if not exists
  Future<IdGenerator> _getIdGenerator(String tableName) async {
    // check cache
    if (_idGenerators.containsKey(tableName)) {
      return _idGenerators[tableName]!;
    }

    try {
      // get table schema
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
        throw Exception('Table schema is null, cannot get batch ids');
      }

      // create id generator
      final generator = IdGeneratorFactory.createGenerator(
        schema,
        _dataStore.config,
        centralClient: _centralClient,
      );

      // if sequential id generator, set current id value
      if (generator is SequentialIdGenerator) {
        final currentId = _maxIds[tableName];

        // if current id value exists in memory, try to convert to integer and set to generator
        if (currentId != null) {
          try {
            // convert string id to integer (because generator still uses integer internally)
            if (currentId is String && _isNumericString(currentId)) {
              final intId = int.parse(currentId);
              if (intId > 0) {
                generator.setCurrentId(intId);
              }
            } else if (currentId is int && currentId > 0) {
              // backward compatible, handle possible integer value
              generator.setCurrentId(currentId);
            }
          } catch (e) {
            Logger.error(
                'Failed to set id generator current value: $e, value=$currentId',
                label: 'TableDataManager._getIdGenerator');
          }
        }
        // if using distributed mode, restore id range info
        if (_idRanges.containsKey(tableName)) {
          final rangeInfo = _idRanges[tableName];
          if (rangeInfo != null &&
              rangeInfo.containsKey('current') &&
              rangeInfo.containsKey('max')) {
            try {
              final current = rangeInfo['current'];
              final max = rangeInfo['max'];

              int currentInt, maxInt;

              if (current is String && max is String) {
                // new string format id
                currentInt = int.parse(current);
                maxInt = int.parse(max);
              } else {
                // old integer format id
                currentInt = current as int;
                maxInt = max as int;
              }

              generator.setIdRange(currentInt, maxInt);
            } catch (e) {
              Logger.error('Failed to set id generator range: $e',
                  label: 'TableDataManager._getIdGenerator');
            }
          }
        }
      }

      // save to cache
      _idGenerators[tableName] = generator;

      return generator;
    } catch (e) {
      Logger.error(
        'Failed to get id generator: $e',
        label: 'TableDataManager._getIdGenerator',
      );

      // return a simple default generator
      const defaultConfig = SequentialIdConfig();
      final defaultGenerator =
          SequentialIdGenerator(defaultConfig, tableName: tableName);

      // cache this generator to avoid duplicate creation
      _idGenerators[tableName] = defaultGenerator;

      return defaultGenerator;
    }
  }

  /// save id range info
  Future<void> _saveIdRange(String tableName) async {
    final generator = _idGenerators[tableName];
    if (generator is SequentialIdGenerator && generator.isDistributed) {
      // get current max id value
      final currentMaxId = _maxIds[tableName];

      if (currentMaxId == null) return;

      // all ids use string type
      final maxIdStr = currentMaxId.toString();

      // if max id is numeric string, calculate current id
      if (_isNumericString(maxIdStr)) {
        // get remaining ids
        final remainingIds =
            generator.remainingIds > 0 ? generator.remainingIds : 0;

        try {
          // convert string to integer for calculation
          final maxIdInt = int.parse(maxIdStr);
          final currentIdInt = maxIdInt - remainingIds;

          // save as string type
          _idRanges[tableName] = {
            'current': currentIdInt.toString(),
            'max': maxIdStr,
          };
        } catch (e) {
          Logger.error(
              'Failed to save id range: cannot parse string id to integer: $e',
              label: 'TableDataManager._saveIdRange');
        }
      } else {
        // non-numeric string id, save current value directly
        _idRanges[tableName] = {
          'current': maxIdStr,
          'max': maxIdStr,
        };
      }
    }
  }

  /// check if need to fetch new id range
  Future<void> _checkIdFetch() async {
    try {
      for (final entry in _idGenerators.entries) {
        final tableName = entry.key;
        final generator = entry.value;

        if (generator.needsFetch) {
          try {
            await generator.requestNewBatch();
            await _saveIdRange(tableName);
          } catch (e) {
            Logger.error(
              'Failed to get new id range for table $tableName: $e',
              label: 'TableDataManager._checkIdFetch',
            );
          }
        }
      }
    } catch (e) {
      Logger.error(
        'Failed to check id range status: $e',
        label: 'TableDataManager._checkIdFetch',
      );
    }
  }

  /// update max id from table meta
  Future<void> _updateMaxIdFromTable(String tableName) async {
    try {
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
        Logger.error('Table schema is null, cannot update max id',
            label: 'TableDataManager._updateMaxIdFromTable');
        return;
      }
      // handle sequential primary key
      if (schema.primaryKeyConfig.type == PrimaryKeyType.sequential) {
        // get max id from table meta
        final fileMeta = await getTableFileMeta(tableName);

        if (fileMeta != null &&
            fileMeta.partitions != null &&
            fileMeta.partitions!.isNotEmpty) {
          // find max id from partition meta
          dynamic maxId;

          for (final partition in fileMeta.partitions!) {
            // get max id from partition meta
            final partitionMaxId = partition.maxPrimaryKey;

            if (partitionMaxId != null) {
              if (maxId == null) {
                maxId = partitionMaxId;
              } else {
                // use general compare method to compare values
                if (_compareValues(partitionMaxId, maxId) > 0) {
                  maxId = partitionMaxId;
                }
              }
            }
          }

          if (maxId != null) {
            // update memory cache, use string type
            _maxIds[tableName] = maxId.toString();
            _maxIdsDirty[tableName] = true;

            // update file
            final maxIdPath =
                await _dataStore.pathManager.getAutoIncrementPath(tableName);
            await _dataStore.storage.writeAsString(maxIdPath, maxId.toString());
            return;
          }
        }

        // if table is empty, select initial value based on primary key type
        const initialValue = "0";
        _maxIds[tableName] = initialValue;
        _maxIdsDirty[tableName] = true;

        final maxIdPath =
            await _dataStore.pathManager.getAutoIncrementPath(tableName);
        await _dataStore.storage.writeAsString(maxIdPath, initialValue);
      }
    } catch (e) {
      Logger.error(
        'Failed to update max id for table $tableName: $e',
        label: 'TableDataManager._updateMaxIdFromTable',
      );
    }
  }

  /// initialize auto increment id for single table
  Future<void> _initTableAutoIncrementId(String tableName) async {
    try {
      Logger.debug('Initialize auto increment id for table $tableName',
          label: 'TableDataManager._initTableAutoIncrementId');
      // check auto increment id file
      final maxIdPath =
          await _dataStore.pathManager.getAutoIncrementPath(tableName);

      if (await _dataStore.storage.existsFile(maxIdPath)) {
        // read value from file
        final content = await _dataStore.storage.readAsString(maxIdPath);
        if (content != null && content.isNotEmpty) {
          // save as string type
          _maxIds[tableName] = content.trim();
          return;
        }
      }

      // if file not exists or cannot read, query max id from table
      await _updateMaxIdFromTable(tableName);
    } catch (e) {
      Logger.error(
        'Failed to initialize auto increment id for table $tableName: $e',
        label: 'TableDataManager._initTableAutoIncrementId',
      );
    }
  }

  /// handle primary key conflict when updating max id
  Future<void> handlePrimaryKeyConflict(
      String tableName, dynamic conflictId) async {
    try {
      // check if id value is loaded
      if (!_maxIds.containsKey(tableName)) {
        // if not loaded, initialize auto increment id first
        await _initTableAutoIncrementId(tableName);
      }

      // get current max id
      final currentMaxId = _maxIds[tableName];
      if (currentMaxId == null) return;

      // use general compare method to compare id
      final compareResult = _compareValues(conflictId, currentMaxId);

      // only update when conflict id is greater than or equal to current max id
      if (compareResult >= 0) {
        String? newId;

        // select different processing strategy based on id type
        if (conflictId is int) {
          // integer type, increment
          newId = (conflictId + 1).toString();
        } else if (conflictId is String) {
          if (_isNumericString(conflictId)) {
            // numeric string, convert to integer and increment
            try {
              final intValue = int.parse(conflictId);
              newId = (intValue + 1).toString();
            } catch (e) {
              Logger.error(
                  'Failed to parse conflict id to integer: $conflictId',
                  label: 'TableDataManager.handlePrimaryKeyConflict');
              return;
            }
          } else if (_isShortCodeFormat(conflictId)) {
            // shortCode format, append a character to ensure uniqueness
            newId =
                '$conflictId${String.fromCharCode(97 + (DateTime.now().millisecondsSinceEpoch % 26))}';
          } else {
            // other string type, append a random character to ensure uniqueness
            newId =
                '$conflictId${String.fromCharCode(97 + (DateTime.now().millisecondsSinceEpoch % 26))}';
          }
        } else {
          // other type, convert to string and process
          newId =
              '${conflictId.toString()}${String.fromCharCode(97 + (DateTime.now().millisecondsSinceEpoch % 26))}';
        }

        _maxIds[tableName] = newId;
        _maxIdsDirty[tableName] = true;

        // update file
        final maxIdPath =
            await _dataStore.pathManager.getAutoIncrementPath(tableName);
        await _dataStore.storage.writeAsString(maxIdPath, newId);

        Logger.warn(
          'Table $tableName has primary key conflict, update auto increment start: $newId',
          label: 'TableDataManager.handlePrimaryKeyConflict',
        );

        // update generator current id (only for numeric id)
        if (_idGenerators.containsKey(tableName)) {
          final generator = _idGenerators[tableName];
          if (generator is SequentialIdGenerator && _isNumericString(newId)) {
            try {
              final newIdInt = int.parse(newId);
              generator.setCurrentId(newIdInt);
            } catch (e) {
              Logger.error('Failed to parse new id to integer: $newId',
                  label: 'TableDataManager.handlePrimaryKeyConflict');
            }
          }
        }
      } else {
        // if current id is greater than conflict id, no need to adjust
        Logger.debug(
          'Table $tableName has primary key conflict, but current max id $currentMaxId is greater than conflict id $conflictId, no need to adjust',
          label: 'TableDataManager.handlePrimaryKeyConflict',
        );
      }
    } catch (e) {
      Logger.error(
        'Failed to handle primary key conflict: $e',
        label: 'TableDataManager.handlePrimaryKeyConflict',
      );
    }
  }

  /// check if table uses ordered range
  Future<bool> _checkTableOrderedRange(String tableName) async {
    try {
      // if already checked, return cached result
      if (_checkedOrderedRange.containsKey(tableName)) {
        return _checkedOrderedRange[tableName] ?? false;
      }

      final meta = await getTableFileMeta(tableName);
      if (meta == null) {
        return false; // table not exists
      }

      // if meta explicitly specifies if ordered, use that value
      if (meta.isOrdered != null) {
        _checkedOrderedRange[tableName] = meta.isOrdered!;
        return meta.isOrdered!;
      }

      // get table schema and check if primary key type should be considered ordered
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
        Logger.error('Table schema is null, cannot check ordered',
            label: 'TableDataManager._checkTableOrderedRange');
        return false;
      }
      bool shouldBeOrdered = schema.isPrimaryKeyOrdered();

      if (!shouldBeOrdered) {
        // if primary key type should not be considered ordered, return false directly
        _checkedOrderedRange[tableName] = false;

        // update meta
        final updatedMeta = meta.copyWith(isOrdered: false);
        await updateTableFileMeta(tableName, updatedMeta);

        return false;
      }

      // default new table is ordered
      bool isOrdered = true;

      // if has partitions, check primary key type and ordered
      if (meta.partitions != null && meta.partitions!.isNotEmpty) {
        // check first primary key value type
        dynamic firstKey = meta.partitions![0].minPrimaryKey;

        // non-numeric primary key does not use ordered range query optimization
        if (firstKey != null && firstKey is! num && firstKey is! String) {
          isOrdered = false;
        } else {
          // check partition ordered
          for (int i = 1; i < meta.partitions!.length; i++) {
            final prevPartition = meta.partitions![i - 1];
            final currentPartition = meta.partitions![i];

            // if max value of previous partition is greater than or equal to min value of current partition, then non-ordered
            if (prevPartition.maxPrimaryKey != null &&
                currentPartition.minPrimaryKey != null) {
              final comparison = _compareValues(
                  prevPartition.maxPrimaryKey, currentPartition.minPrimaryKey);

              if (comparison >= 0) {
                isOrdered = false;
                break;
              }
            }

            // Periodically yield to prevent blocking the UI thread
            if (i % 200 == 0) {
              await Future.delayed(Duration.zero);
            }
          }
        }
      }

      // update meta
      if (meta.isOrdered == null) {
        final updatedMeta = meta.copyWith(isOrdered: isOrdered);
        await updateTableFileMeta(tableName, updatedMeta);
      }

      // cache result
      _checkedOrderedRange[tableName] = isOrdered;
      return isOrdered;
    } catch (e) {
      Logger.error('Failed to check table ordered range: $e',
          label: 'TableDataManager._checkTableOrderedRange');
      return false;
    }
  }

  /// Stream records from a table
  Stream<Map<String, dynamic>> streamRecords(String tableName,
      {List<int>? encryptionKey, int? encryptionKeyId}) async* {
    final schema = await _dataStore.getTableSchema(tableName);
    if (schema == null) {
      Logger.error('Failed to get schema for $tableName',
          label: 'TableDataManager.streamRecords');
      return;
    }
    final isGlobal = schema.isGlobal;
    final primaryKey = schema.primaryKey;

    final fileMeta = await getTableFileMeta(tableName);

    // If we have partitions, stream from them in parallel while maintaining order.
    if (fileMeta != null &&
        fileMeta.partitions != null &&
        fileMeta.partitions!.isNotEmpty) {
      final partitions = List<PartitionMeta>.from(fileMeta.partitions!)
        ..sort((a, b) => a.index.compareTo(b.index));

      // Create a list of futures to read each partition.
      // The order of futures corresponds to the partition order.
      final partitionReadFutures = partitions
          .map((p) => readRecordsFromPartition(
                tableName,
                isGlobal,
                p.index,
                primaryKey,
                encryptionKey: encryptionKey,
                encryptionKeyId: encryptionKeyId,
              ))
          .toList();

      // Await each future in sequence to yield records in order.
      // The I/O operations themselves run in parallel because the futures were created together.
      for (final future in partitionReadFutures) {
        try {
          final records = await future;
          for (final record in records) {
            if (!isDeletedRecord(record)) {
              yield record;
            }
          }
        } catch (e, s) {
          Logger.error('Error reading partition stream: $e\n$s',
              label: 'TableDataManager.streamRecords');
          // Continue to the next partition on error.
        }
      }
    }

    // Include pending data from the write buffer that hasn't been flushed yet.
    final pendingData = _writeBuffer[tableName] ?? {};
    for (var entry in pendingData.values) {
      // ensure only return non-deleted data
      if (!isDeletedRecord(entry.data)) {
        yield entry.data;
      }
    }
  }

  /// Stream records from a custom path (backup or external location)
  /// - customRootPath: Root path of the custom location
  /// - tableName: Table name
  /// - isGlobal: Whether this is a global table
  /// - targetKey: Optional specific primary key to find
  /// - spaceName: Optional space name, defaults to current instance's space name
  /// - primaryKey: Optional primary key field name, avoids reading from schema
  /// - encryptionKey: Optional custom encryption key for decoding
  /// - encryptionKeyId: Optional encryption key ID
  Stream<Map<String, dynamic>> streamRecordsFromCustomPath(
      {required String customRootPath,
      required String tableName,
      required bool isGlobal,
      String? targetKey,
      String? spaceName,
      String? primaryKey,
      List<int>? encryptionKey,
      int? encryptionKeyId}) async* {
    try {
      final effectiveSpaceName = spaceName ?? _dataStore.config.spaceName;

      final String tablePath;
      if (isGlobal) {
        tablePath = pathJoin(customRootPath, 'global', tableName);
      } else {
        tablePath =
            pathJoin(customRootPath, 'spaces', effectiveSpaceName, tableName);
      }

      // if primary key is not provided, try to get it from schema file
      String? effectivePrimaryKey = primaryKey;
      if (effectivePrimaryKey == null) {
        final schemaPath = pathJoin(tablePath, 'schema', 'schema.json');
        if (await _dataStore.storage.existsFile(schemaPath)) {
          final schemaContent =
              await _dataStore.storage.readAsString(schemaPath);
          if (schemaContent != null) {
            try {
              final schema = TableSchema.fromJson(jsonDecode(schemaContent));
              effectivePrimaryKey = schema.primaryKey;
            } catch (e) {
              Logger.error('Failed to parse schema: $e',
                  label: 'TableDataManager.streamRecordsFromCustomPath');
            }
          }
        }
      }

      final dataDir = pathJoin(tablePath, 'data');
      final mainFilePath = pathJoin(dataDir, 'main.dat');
      final partitionsDir = pathJoin(dataDir, 'partitions');

      // check if main data file exists
      if (await _dataStore.storage.existsFile(mainFilePath)) {
        try {
          // read and decode file meta
          final bytes = await _dataStore.storage.readAsBytes(mainFilePath);
          final decodedString = await EncoderHandler.decode(bytes,
              customKey: encryptionKey, keyId: encryptionKeyId);

          final fileInfo = FileInfo.fromJson(
              jsonDecode(decodedString) as Map<String, dynamic>);
          final fileMeta = fileInfo.meta;

          // if there are partitions, read them stream
          if (fileMeta.partitions != null && fileMeta.partitions!.isNotEmpty) {
            List<PartitionMeta> partitionsToProcess;

            // if there is primary key and target key, try to optimize partition search
            if (effectivePrimaryKey != null && targetKey != null) {
              // try to find partitions that might contain target key
              partitionsToProcess = await _findPotentialPartitionsForKey(
                  fileMeta.partitions!, targetKey);

              if (partitionsToProcess.isEmpty) {
                // if no partitions found, log warning and return
                Logger.warn(
                    'No partitions found that might contain key $targetKey',
                    label: 'TableDataManager.streamRecordsFromCustomPath');
                return;
              }
            } else {
              // no primary key or target key, process all partitions
              partitionsToProcess =
                  List<PartitionMeta>.from(fileMeta.partitions!)
                    ..sort((a, b) => a.index.compareTo(b.index));
            }

            // process selected partitions
            for (final partition in partitionsToProcess) {
              // calculate directory based on partition index
              final dirIndex =
                  partition.index ~/ _dataStore.config.maxEntriesPerDir;
              final dirPath = pathJoin(partitionsDir, 'dir_$dirIndex');
              final partitionPath =
                  pathJoin(dirPath, 'p${partition.index}.dat');

              if (await _dataStore.storage.existsFile(partitionPath)) {
                // read partition file
                final bytes =
                    await _dataStore.storage.readAsBytes(partitionPath);
                final decodedString = await EncoderHandler.decode(bytes,
                    customKey: encryptionKey, keyId: encryptionKeyId);
                final partitionInfo = PartitionInfo.fromJson(
                    jsonDecode(decodedString) as Map<String, dynamic>);

                // process records, filter out empty records
                for (final record in partitionInfo.data) {
                  if (record is Map<String, dynamic> &&
                      !isDeletedRecord(record)) {
                    yield record;
                  }
                }
              }
            }
          }
        } catch (e) {
          Logger.error('Process main file failed: $e',
              label: 'TableDataManager.streamRecordsFromCustomPath');
        }
      } else {
        Logger.warn('Main file does not exist: $mainFilePath',
            label: 'TableDataManager.streamRecordsFromCustomPath');
      }
    } catch (e) {
      Logger.error('Stream records from custom path failed: $e',
          label: 'TableDataManager.streamRecordsFromCustomPath');
    }
  }

  /// find partitions that might contain target key
  Future<List<PartitionMeta>> _findPotentialPartitionsForKey(
      List<PartitionMeta> partitions, String targetKey) async {
    final result = <PartitionMeta>[];

    int processedCount = 0;
    // First check if any partition contains target key
    for (final partition in partitions) {
      // If partition has primary key range info, check if target key is in range
      if (partition.minPrimaryKey != null && partition.maxPrimaryKey != null) {
        // Use ValueComparator to check if target key is in range
        if (ValueComparator.isInRange(
          targetKey,
          partition.minPrimaryKey,
          partition.maxPrimaryKey,
        )) {
          result.add(partition);
        }
      } else {
        // If partition has no range info, assume it needs processing
        result.add(partition);
      }
      processedCount++;
      if (processedCount % 200 == 0) {
        await Future.delayed(Duration.zero);
      }
    }

    // If no partitions found, return all partitions
    if (result.isEmpty) {
      return List<PartitionMeta>.from(partitions)
        ..sort((a, b) => a.index.compareTo(b.index));
    }

    // Sort by index to maintain consistent read order
    result.sort((a, b) => a.index.compareTo(b.index));
    return result;
  }

  Future<Map<String, dynamic>?> getRecordByPointer(
      String tableName, StoreIndex pointer,
      {List<int>? encryptionKey,
      int? encryptionKeyId,
      String? fieldName,
      dynamic expectedValue}) async {
    try {
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
        return null;
      }
      final records = await readRecordsFromPartition(
        tableName,
        schema.isGlobal,
        pointer.partitionId,
        schema.primaryKey,
        recordIndex: pointer.offset,
        encryptionKey: encryptionKey,
        encryptionKeyId: encryptionKeyId,
        fieldName: fieldName,
        expectedValue: expectedValue,
      );

      // return non-empty record
      if (records.isNotEmpty && !isDeletedRecord(records.first)) {
        return records.first;
      }
      return null;
    } catch (e) {
      Logger.error(
        'Failed to get record by pointer: $e',
        label: 'TableDataManager.getRecordByPointer',
      );
      return null;
    }
  }

  /// Process table partitions with multiple operations at once
  Future<void> processTablePartitions({
    required String tableName,
    required Future<List<Map<String, dynamic>>> Function(
      List<Map<String, dynamic>> records,
      int partitionIndex,
      ParallelController controller,
    ) processFunction,
    bool onlyRead =
        false, // if true, only read records from partitions, do not write records
    int? maxConcurrent,
    List<int>? encryptionKey,
    int? encryptionKeyId,
    List<int>?
        targetPartitions, // Specify the list of partitions to process, if null, process all partitions
    ParallelController? controller,
  }) async {
    // get table meta
    final fileMeta = await getTableFileMeta(tableName);
    if (fileMeta == null || fileMeta.partitions == null) {
      return;
    }

    // get table schema
    final schema = await _dataStore.getTableSchema(tableName);
    if (schema == null) {
      return;
    }
    final isGlobal = schema.isGlobal;
    final primaryKey = schema.primaryKey;

    // Determine the list of partitions to process
    List<int> partitionIndexesToProcess;
    if (targetPartitions != null && targetPartitions.isNotEmpty) {
      // If target partitions are provided, only process these partitions
      partitionIndexesToProcess = targetPartitions;

      // Verify if target partitions exist
      final availablePartitions =
          fileMeta.partitions!.map((p) => p.index).toSet();
      partitionIndexesToProcess = partitionIndexesToProcess
          .where((index) => availablePartitions.contains(index))
          .toList();

      if (partitionIndexesToProcess.isEmpty) {
        Logger.warn(
          'No valid partitions to process for table $tableName from targetPartitions',
          label: 'TableDataManager.processTablePartitions',
        );
        return;
      }
    } else {
      // Otherwise, process all partitions
      partitionIndexesToProcess =
          fileMeta.partitions!.map((p) => p.index).toList();
    }

    final effectiveController = controller ?? ParallelController();

    // Process all partitions using ParallelProcessor and get the new metadata back.
    final newPartitionMetas = await ParallelProcessor.execute<PartitionMeta?>(
      partitionIndexesToProcess.map((partitionIndex) {
        return () async {
          // read partition data
          final records = await readRecordsFromPartition(
              tableName, isGlobal, partitionIndex, primaryKey,
              encryptionKey: encryptionKey, encryptionKeyId: encryptionKeyId);

          // process data
          final processedRecords =
              await processFunction(records, partitionIndex, effectiveController);

          // if only read or if the process was stopped, return directly
          if (onlyRead || effectiveController.isStopped) {
            return null;
          }

          final partitionMeta = await _savePartitionFile(
            tableName,
            isGlobal,
            partitionIndex,
            processedRecords,
            primaryKey,
            fileMeta.partitions!,
            operationType: BufferOperationType.update,
            encryptionKey: encryptionKey,
            encryptionKeyId: encryptionKeyId,
          );

          // Return the new metadata for this partition.
          return partitionMeta;
        };
      }).toList(),
      concurrency: maxConcurrent,
      controller: effectiveController,
    );

    // if only read, return directly
    if (onlyRead) {
      return;
    }

    final validMetas = newPartitionMetas.whereType<PartitionMeta>().toList();

    if (validMetas.isNotEmpty) {
      // update table meta
      await _updateTableMetadataWithAllPartitions(
          tableName, validMetas, fileMeta.partitions);
    }
  }

  // Add new method to recalculate table meta
  Future<void> recalculateTableMeta(String tableName) async {
    final fileMeta = await getTableFileMeta(tableName);
    if (fileMeta == null || fileMeta.partitions == null) {
      Logger.warn(
          'Failed to recalculate table meta: table $tableName meta not found',
          label: 'TableDataManager.recalculateTableMeta');
      return;
    }

    // Use existing meta but force recalculation of totals
    await updateTableFileMeta(tableName, fileMeta, recalculateTotals: true);
  }

  /// set central server client
  void setCentralServerClient(CentralServerClient client) {
    _centralClient = client;
  }

  /// value comparison for sorting and range checking
  int _compareValues(dynamic a, dynamic b) {
    return ValueComparator.compare(a, b);
  }

  /// check if string is pure numeric string
  bool _isNumericString(String? str) {
    if (str == null || str.isEmpty) return false;
    return ValueComparator.isNumericString(str);
  }

  /// check if string is shortCode format (mixed alphanumeric short code)
  bool _isShortCodeFormat(String? str) {
    if (str == null || str.isEmpty) return false;
    return ValueComparator.isShortCodeFormat(str);
  }

  /// compare two numeric strings
  int _compareNumericStrings(String a, String b) {
    return ValueComparator.compareNumericStrings(a, b);
  }

  /// Read records from partition
  Future<List<Map<String, dynamic>>> readRecordsFromPartition(
    String tableName,
    bool isGlobal,
    int partitionIndex,
    String primaryKey, {
    int? recordIndex,
    List<int>? encryptionKey,
    int? encryptionKeyId,
    String? fieldName,
    dynamic expectedValue,
  }) async {
    final partitionPath = await _dataStore.pathManager
        .getPartitionFilePath(tableName, partitionIndex);

    if (!await _dataStore.storage.existsFile(partitionPath)) {
      return [];
    }

    try {
      // Read partition file
      final bytes = await _dataStore.storage.readAsBytes(partitionPath);
      if (bytes.isEmpty) {
        Logger.warn('Partition file is empty: $partitionPath',
            label: 'TableDataManager.readRecordsFromPartition');
        return [];
      }

      final decodedData = await ComputeManager.run(
          decodePartitionData,
          DecodePartitionRequest(
            bytes: bytes,
            encryptionKey: encryptionKey,
            encryptionKeyId: encryptionKeyId,
            // Only pass encoderState when no specific encryption key/keyId provided (avoid conflicts with migration data)
            encoderState: (encryptionKey == null && encryptionKeyId == null)
                ? EncoderHandler.getCurrentEncodingState()
                : null,
          ),
          useIsolate: bytes.length >
              500 * 1024 // only use isolate if data size is larger than 500KB
          );

      // if request specific record (by index position)
      if (recordIndex != null) {
        // check if index is in valid range
        if (recordIndex >= 0 && recordIndex < decodedData.length) {
          final record = decodedData[recordIndex];

          // if no expected value and field is provided, return the record directly
          if (fieldName == null || expectedValue == null) {
            return [record];
          }

          // if expected value and field are provided, verify if the record matches
          if (record.containsKey(fieldName) &&
              ValueComparator.compare(record[fieldName], expectedValue) == 0) {
            // record matches, return directly
            return [record];
          } else if (record.isNotEmpty) {
            // record does not match, but there is a valid record, indicating that the index position may be inaccurate
            Logger.warn(
              'Index position record does not match, find correct record in partition $partitionIndex: expected $fieldName=$expectedValue, actual: ${record[fieldName]}',
              label: 'TableDataManager.readRecordsFromPartition',
            );
          }

          // index is inaccurate, scan the entire partition to find the matching record
          for (int i = 0; i < decodedData.length; i++) {
            final currentRecord = decodedData[i];
            if (currentRecord.isNotEmpty &&
                currentRecord.containsKey(fieldName) &&
                ValueComparator.compare(
                        currentRecord[fieldName], expectedValue) ==
                    0) {
              // found matching record, update index
              if (i != recordIndex) {
                // try to update index (here only add log, actual index update needs to call index manager)
                try {
                  // find table schema to get more information
                  final schema = await _dataStore.getTableSchema(tableName);
                  if (schema != null) {
                    // create new index pointer
                    final newPointer = await StoreIndex.create(
                        offset: i,
                        partitionId: partitionIndex,
                        clusterId: _dataStore
                                .config.distributedNodeConfig.enableDistributed
                            ? _dataStore.config.distributedNodeConfig.clusterId
                            : null,
                        nodeId: _dataStore
                                .config.distributedNodeConfig.enableDistributed
                            ? _dataStore.config.distributedNodeConfig.nodeId
                            : null);

                    // update index (may need additional processing in actual business)
                    // here only add log, actual index update needs to call index manager
                    Logger.debug(
                      'Index pointer needs to be updated: value=$fieldName=$expectedValue, new pointer=$newPointer',
                      label: 'TableDataManager.readRecordsFromPartition',
                    );

                    // if there is index manager, try to update index
                    if (_dataStore.indexManager != null &&
                        fieldName == schema.primaryKey) {
                      // use updateIndexes method to update index, it will update all necessary indexes
                      await _dataStore.indexManager
                          ?.updateIndexes(tableName, currentRecord, newPointer);
                    }
                  }
                } catch (updateError) {
                  Logger.error(
                    'Failed to update index: $updateError',
                    label: 'TableDataManager.readRecordsFromPartition',
                  );
                }
              }

              // return found matching record
              return [currentRecord];
            }
            if (i % 500 == 0) {
              await Future.delayed(Duration.zero);
            }
          }
          return [];
        }
        return [];
      }

      // allow empty records (deleted records), avoid deleted records being filtered out during migration
      return decodedData;
    } catch (e, stack) {
      Logger.error('''Read records from partition failed:
            error: $e
            stack: $stack
            tableName: $tableName
            partitionIndex: $partitionIndex
            partitionPath: $partitionPath
          ''', label: 'TableDataManager.readRecordsFromPartition');
      return [];
    }
  }

  /// write records to partitioned data files
  Future<void> writeRecords({
    required String tableName,
    required List<Map<String, dynamic>> records,
    required BufferOperationType operationType,
    List<int>? encryptionKey,
    int? encryptionKeyId,
    int? concurrency,
  }) async {
    if (tableName.isEmpty) {
      throw ArgumentError('Table name cannot be empty');
    }

    // if records are empty and operation is not rewrite, return directly
    if (records.isEmpty && operationType != BufferOperationType.rewrite) {
      return;
    }

    Logger.debug("Table $tableName is ready to write ${records.length} records",
        label: "TableDataManager.writeRecords");

    final schema = await _dataStore.getTableSchema(tableName);
    if (schema == null) {
      return;
    }
    final isGlobal = schema.isGlobal;
    final primaryKey = schema.primaryKey;

    // get table meta
    FileMeta? fileMeta = await getTableFileMeta(tableName);
    List<PartitionMeta>? existingPartitions =
        fileMeta?.partitions?.toList() ?? [];

    try {
      // handle based on operation type
      if (operationType == BufferOperationType.insert) {
        // pre-allocate records to partitions
        final partitionRecords = await _assignRecordsToPartitions(
            tableName, records, primaryKey,
            useExistingPartitions: true);

        // create a map to store partition index and records to create index
        final Map<int, List<Map<String, dynamic>>> recordsToCreateIndex = {};
        // store the starting offset of each partition
        final Map<int, int> partitionOffsets = {};

        // store all processed partition meta
        List<PartitionMeta> allPartitionMetas = [];

        final tasks = partitionRecords.keys.map((partitionIndex) {
          return () async {
            final recordsForPartition = partitionRecords[partitionIndex]!;
            if (recordsForPartition.isEmpty) {
              return PartitionMeta(
                version: 1,
                index: partitionIndex,
                totalRecords: 0,
                fileSizeInBytes: 0,
                minPrimaryKey: null,
                maxPrimaryKey: null,
                checksum: "",
                timestamps: Timestamps(
                  created: DateTime.now(),
                  modified: DateTime.now(),
                ),
                parentPath:
                    await _dataStore.pathManager.getTablePath(tableName),
              );
            }

            // if adding records to an existing partition, need to read existing records first
            List<Map<String, dynamic>> allRecords = [];

            final partitionExists =
                existingPartitions.any((p) => p.index == partitionIndex);
            if (partitionExists) {
              allRecords = await readRecordsFromPartition(
                  tableName, isGlobal, partitionIndex, primaryKey,
                  encryptionKey: encryptionKey,
                  encryptionKeyId: encryptionKeyId);
            }

            // collect records to create index
            if (recordsForPartition.isNotEmpty) {
              recordsToCreateIndex[partitionIndex] = recordsForPartition;
              partitionOffsets[partitionIndex] = allRecords.length;
            }

            // merge records
            allRecords.addAll(recordsForPartition);

            // save partition, but not update table meta
            return await _savePartitionFile(
              tableName,
              isGlobal,
              partitionIndex,
              allRecords,
              primaryKey,
              existingPartitions,
              encryptionKey: encryptionKey,
              encryptionKeyId: encryptionKeyId,
              operationType: BufferOperationType.insert,
            );
          };
        }).toList();

        final partitionResults =
            await ParallelProcessor.execute<PartitionMeta>(tasks,
                concurrency: concurrency);
        allPartitionMetas.addAll(partitionResults.whereType<PartitionMeta>());

        // all partitions processed, update table meta once
        await _updateTableMetadataWithAllPartitions(
            tableName, allPartitionMetas, existingPartitions);

        // create index for all records asynchronously
        if (recordsToCreateIndex.isNotEmpty) {
          _asyncCreateIndexes(
              tableName: tableName,
              primaryKey: primaryKey,
              recordsToCreateIndex: recordsToCreateIndex,
              partitionOffsets: partitionOffsets);
        }
      } else if (operationType == BufferOperationType.delete ||
          operationType == BufferOperationType.update) {
        // Use Map to optimize lookup efficiency, avoid duplicate queries
        final recordsByPk = <String, Map<String, dynamic>>{};
        final List<PartitionMeta> allPartitionMetas = [];

        // create efficient lookup index
        for (final record in records) {
          final pk = record[primaryKey]?.toString() ?? '';
          if (pk.isNotEmpty) {
            recordsByPk[pk] = record;
          }
        }

        // Identify which partitions might contain records
        final partitionsToProcess = <PartitionMeta>[];
        int partitionCheckCount = 0;
        for (final partition in existingPartitions) {
          if (partition.minPrimaryKey != null &&
              partition.maxPrimaryKey != null) {
            // Check if any records may be in this partition range
            for (final pk in recordsByPk.keys) {
              if (ValueComparator.isInRange(
                  pk, partition.minPrimaryKey, partition.maxPrimaryKey)) {
                partitionsToProcess.add(partition);
                break;
              }
            }
          } else {
            // If partition has no range info, assume it needs processing
            partitionsToProcess.add(partition);
          }

          // Yield to the event loop periodically to avoid blocking the UI thread
          // when checking a large number of partitions.
          partitionCheckCount++;
          if (partitionCheckCount % 200 == 0) {
            await Future.delayed(Duration.zero);
          }
        }

        final tasks = partitionsToProcess.map((partition) {
          return () async {
            final partitionRecords = await readRecordsFromPartition(
                tableName, isGlobal, partition.index, primaryKey,
                encryptionKey: encryptionKey, encryptionKeyId: encryptionKeyId);

            bool modified = false;
            List<Map<String, dynamic>> resultRecords;
            Set<String> processedKeysInPartition = {};

            if (operationType == BufferOperationType.delete) {
              resultRecords = List<Map<String, dynamic>>.from(partitionRecords);
              for (int i = 0; i < resultRecords.length; i++) {
                final record = resultRecords[i];
                if (isDeletedRecord(record)) continue;

                final pk = record[primaryKey]?.toString() ?? '';
                if (recordsByPk.containsKey(pk)) {
                  resultRecords[i] = {'_deleted_': true};
                  modified = true;
                  processedKeysInPartition.add(pk);
                }
                if (i % 500 == 0) {
                  await Future.delayed(Duration.zero);
                }
              }
            } else {
              // update operation
              resultRecords = List<Map<String, dynamic>>.from(partitionRecords);
              for (int i = 0; i < resultRecords.length; i++) {
                final record = resultRecords[i];
                final pk = record[primaryKey]?.toString() ?? '';
                if (pk.isNotEmpty && recordsByPk.containsKey(pk)) {
                  resultRecords[i] = recordsByPk[pk]!;
                  modified = true;
                  processedKeysInPartition.add(pk);
                }
                if (i % 500 == 0) {
                  await Future.delayed(Duration.zero);
                }
              }
            }

            PartitionMeta? updatedPartitionMeta;
            if (modified) {
              bool allEmpty = resultRecords.isNotEmpty &&
                  resultRecords.every((record) => isDeletedRecord(record));

              if (resultRecords.isEmpty || allEmpty) {
                final partitionPath = await _dataStore.pathManager
                    .getPartitionFilePath(tableName, partition.index);
                if (await _dataStore.storage.existsFile(partitionPath)) {
                  await _dataStore.storage.deleteFile(partitionPath);
                }
                updatedPartitionMeta = partition.copyWith(
                    totalRecords: 0,
                    fileSizeInBytes: 0,
                    timestamps: Timestamps(
                        created: partition.timestamps.created,
                        modified: DateTime.now()));
              } else {
                updatedPartitionMeta = await _savePartitionFile(
                  tableName,
                  isGlobal,
                  partition.index,
                  resultRecords,
                  primaryKey,
                  existingPartitions,
                  encryptionKey: encryptionKey,
                  encryptionKeyId: encryptionKeyId,
                  operationType: BufferOperationType.update,
                );
              }
            }
            return {
              'meta': updatedPartitionMeta,
              'keys': processedKeysInPartition,
            };
          };
        }).toList();

        final partitionResults =
            await ParallelProcessor.execute<Map<String, dynamic>>(tasks,
                concurrency: concurrency);

        final processedKeys = <String>{};
        for (final result in partitionResults) {
          if (result != null) {
            if (result['meta'] is PartitionMeta) {
              allPartitionMetas.add(result['meta']);
            }
            if (result['keys'] is Set<String>) {
              processedKeys.addAll(result['keys']);
            }
          }
        }

        await _updateTableMetadataWithAllPartitions(
            tableName, allPartitionMetas, existingPartitions);

        // if update operation, need to handle records not found (as insert operation)
        if (operationType == BufferOperationType.update) {
          // find records not processed
          final recordsToInsert = records.where((record) {
            final pk = record[primaryKey]?.toString() ?? '';
            return pk.isNotEmpty && !processedKeys.contains(pk);
          }).toList();

          // if there are records not processed, recursively call but use insert operation
          if (recordsToInsert.isNotEmpty) {
            await writeRecords(
              tableName: tableName,
              records: recordsToInsert,
              encryptionKey: encryptionKey,
              encryptionKeyId: encryptionKeyId,
              operationType: BufferOperationType.insert,
              concurrency: concurrency,
            );
          }
        }
      } else if (operationType == BufferOperationType.rewrite) {
        // pre-allocate records to new partitions
        final partitionRecords = await _assignRecordsToPartitions(
            tableName, records, primaryKey,
            useExistingPartitions:
                false // key: not use existing partitions, create new
            );

        // store all processed partition meta
        List<PartitionMeta> allPartitionMetas = [];

        final tasks = partitionRecords.keys.map((partitionIndex) {
          return () async {
            final recordsForPartition = partitionRecords[partitionIndex]!;
            if (recordsForPartition.isEmpty) return null;

            // save partition but not update table meta
            return await _savePartitionFile(
                tableName,
                isGlobal,
                partitionIndex,
                recordsForPartition,
                primaryKey,
                [], // key: empty existing partitions list, because it's a full rewrite
                encryptionKey: encryptionKey,
                encryptionKeyId: encryptionKeyId,
                operationType: BufferOperationType.rewrite);
          };
        }).toList();
        final partitionResults = await ParallelProcessor.execute<PartitionMeta?>(
            tasks,
            concurrency: concurrency);

        // collect all valid partition meta
        allPartitionMetas.addAll(partitionResults.whereType<PartitionMeta>());

        // all partitions processed, update table meta once
        await _updateTableMetadataWithAllPartitions(
            tableName,
            allPartitionMetas,
            [] // key: empty existing partitions list, because it's a full rewrite
            );

        // delete unused old partitions
        if (existingPartitions.isNotEmpty) {
          final newPartitionIndexes = partitionRecords.keys.toList();
          for (var oldPartition in existingPartitions) {
            if (!newPartitionIndexes.contains(oldPartition.index)) {
              final partitionPath = await _dataStore.pathManager
                  .getPartitionFilePath(tableName, oldPartition.index);
              if (await _dataStore.storage.existsFile(partitionPath)) {
                await _dataStore.storage.deleteFile(partitionPath);
              }
            }
            await Future.delayed(Duration.zero);
          }
        }
      }

      // after updating table meta, check ordered range
      final newMeta = await getTableFileMeta(tableName);
      if (newMeta != null && newMeta.isOrdered == null) {
        await _checkTableOrderedRange(tableName);
      }

      // data will be written, need to update stats
      _needSaveStats = true;
    } catch (e, stack) {
      Logger.error('write records failed: $e\n$stack',
          label: 'TableDataManager.writeRecords');
      // when error, force recalculate meta to ensure consistency
      await recalculateTableMeta(tableName);
      rethrow;
    }
  }

  /// update table meta, merge all partition info
  Future<void> _updateTableMetadataWithAllPartitions(
      String tableName,
      List<PartitionMeta> partitionMetas,
      List<PartitionMeta>? existingPartitions) async {
    try {
      // read latest table meta
      FileMeta? fileMeta = await getTableFileMeta(tableName);

      // if table meta not found, create new
      fileMeta ??= FileMeta(
        version: 1,
        type: FileType.data,
        name: tableName,
        fileSizeInBytes: 0,
        totalRecords: 0,
        timestamps: Timestamps(
          created: DateTime.now(),
          modified: DateTime.now(),
        ),
        partitions: [],
      );

      // create efficient lookup index
      final partitionsMap = {
        for (var p in fileMeta.partitions ?? []) p.index: p
      };

      // process new partition meta, update or add to Map
      for (var meta in partitionMetas) {
        // only add non-empty partition to table meta
        if (meta.totalRecords > 0) {
          partitionsMap[meta.index] = meta;
        } else {
          // if partition is empty, remove from Map
          partitionsMap.remove(meta.index);
        }
      }

      // calculate total stats from ALL partitions after processing updates
      int totalRecords = 0;
      int totalSize = 0;

      // now calculate totals from all remaining partitions
      for (var partition in partitionsMap.values) {
        totalRecords += partition.totalRecords as int;
        totalSize += partition.fileSizeInBytes as int;
      }

      // convert Map to List<PartitionMeta> with consistent ordering by partition index
      final allPartitions = partitionsMap.values.toList().cast<PartitionMeta>()
        ..sort((a, b) => a.index.compareTo(b.index));

      // calculate stats delta
      final recordsDelta = totalRecords - fileMeta.totalRecords;
      final sizeDelta = totalSize - fileMeta.fileSizeInBytes;

      // update in-memory stats
      _totalRecordCount += recordsDelta;
      _totalDataSizeBytes += sizeDelta;
      _needSaveStats = true;

      // update table meta
      final updatedFileMeta = fileMeta.copyWith(
        totalRecords: totalRecords,
        fileSizeInBytes: totalSize,
        timestamps: Timestamps(
          created: fileMeta.timestamps.created,
          modified: DateTime.now(),
        ),
        partitions: allPartitions,
      );

      // write updated meta
      await updateTableFileMeta(tableName, updatedFileMeta,
          recalculateTotals: false);

      Logger.debug(
        'update table meta completed: $tableName, ${allPartitions.length} partitions, $totalRecords records, ${totalSize ~/ 1024}KB',
        label: 'TableDataManager._updateTableMetadataWithAllPartitions',
      );
    } catch (e) {
      Logger.error(
        'update table meta failed: $tableName, error: $e',
        label: 'TableDataManager._updateTableMetadataWithAllPartitions',
      );
      // when error, try to recalculate meta
      await recalculateTableMeta(tableName);
    }
  }

  /// high performance table data cleanup, including physical files and memory cache
  Future<void> clearTable(String tableName) async {
    final lockKey = 'table_$tableName';
    bool lockAcquired = false;

    // try to acquire lock, if locked, show message and return
    if (_dataStore.lockManager != null) {
      await _dataStore.lockManager!.acquireExclusiveLock(lockKey);
      lockAcquired = true;
    } else {
      // when no lock manager, check if table is being processed
      if (_processingTables.contains(tableName)) {
        Logger.warn('table $tableName is being processed, waiting to cleanup',
            label: 'TableDataManager.clearTable');
        // wait for a while and try again
        await Future.delayed(const Duration(milliseconds: 100));
        while (_processingTables.contains(tableName)) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
      }
      _processingTables.add(tableName);
      lockAcquired = true;
    }

    try {
      // First, update statistics by subtracting this table's counts
      try {
        final fileMeta = await getTableFileMeta(tableName);
        if (fileMeta != null) {
          // Subtract this table's records and size from the totals
          _totalRecordCount = max(0, _totalRecordCount - fileMeta.totalRecords);
          _totalDataSizeBytes =
              max(0, _totalDataSizeBytes - fileMeta.fileSizeInBytes);

          // Mark statistics as needing to be saved
          _needSaveStats = true;
        }
      } catch (e) {
        Logger.error(
            'Failed to update statistics when clearing table $tableName: $e',
            label: 'TableDataManager.clearTable');
      }

      // mark table cleanup is in progress
      _tableFlushingFlags[tableName] = true;

      // 1. clean write and delete buffers
      _writeBuffer.remove(tableName);
      _deleteBuffer.remove(tableName);

      // 2. directly delete the entire partition directory
      try {
        final partitionsDir =
            await _dataStore.pathManager.getPartitionsDirPath(tableName);
        if (await _dataStore.storage.existsDirectory(partitionsDir)) {
          await _dataStore.storage.deleteDirectory(partitionsDir);
          // delete and recreate empty directory, ensure directory structure is complete
          await _dataStore.storage.ensureDirectoryExists(partitionsDir);
          Logger.debug(
              'deleted entire partition directory for table $tableName',
              label: 'TableDataManager.clearTable');
        }
      } catch (e) {
        Logger.error('delete table $tableName partition directory failed: $e',
            label: 'TableDataManager.clearTable');
        // delete directory failed, fallback to file level delete
        final fileMeta = await getTableFileMeta(tableName);
        if (fileMeta != null && fileMeta.partitions != null) {
          int processedCount = 0;
          for (final partition in fileMeta.partitions!) {
            if (partition.fileSizeInBytes > 0) {
              final partitionPath = await _dataStore.pathManager
                  .getPartitionFilePath(tableName, partition.index);
              if (await _dataStore.storage.existsFile(partitionPath)) {
                await _dataStore.storage.deleteFile(partitionPath);
              }
            }
            processedCount++;
            if (processedCount % 50 == 0) {
              await Future.delayed(Duration.zero);
            }
          }
        }
      }

      // 3. create empty table meta
      final emptyMeta = FileMeta(
        version: 1,
        type: FileType.data,
        name: tableName,
        fileSizeInBytes: 0,
        totalRecords: 0,
        timestamps: Timestamps(
          created: DateTime.now(),
          modified: DateTime.now(),
        ),
        partitions: [],
      );

      // 4. update table meta
      await updateTableFileMeta(tableName, emptyMeta);

      // 5. clean ID generator related resources
      // remove ID generator instance for this table
      _idGenerators.remove(tableName);

      // 6. handle auto increment ID reset
      try {
        final schema = await _dataStore.getTableSchema(tableName);
        if (schema == null) {
          return;
        }
        if (schema.primaryKeyConfig.type == PrimaryKeyType.sequential) {
          // get configured initial value
          const initialValue = 0;

          // update ID file
          final maxIdPath =
              await _dataStore.pathManager.getAutoIncrementPath(tableName);
          await _dataStore.storage.writeAsString(maxIdPath, "0");

          // update memory cache
          _maxIds[tableName] = initialValue;
          _maxIdsDirty[tableName] = true;
          await flushMaxIds();

          // clean ID generator resources
          _idRanges.remove(tableName);
        }
      } catch (e) {
        Logger.error('reset table $tableName auto increment ID failed: $e',
            label: 'TableDataManager.clearTable');
      }

      // 7. clean other caches
      _fileMetaCache.remove(tableName);
      _fileSizes.remove(tableName);
      _lastModifiedTimes.remove(tableName);
      _checkedOrderedRange.remove(tableName);
    } catch (e) {
      Logger.error('clear table $tableName failed: $e',
          label: 'TableDataManager.clearTable');
      rethrow; // rethrow error to upper level
    } finally {
      // clear table flush flag
      _tableFlushingFlags.remove(tableName);

      // release lock and processing flag
      if (lockAcquired) {
        if (_dataStore.lockManager != null) {
          _dataStore.lockManager!.releaseExclusiveLock(lockKey);
        } else {
          _processingTables.remove(tableName);
        }
      }
    }
  }

  /// Rewrite records from source table to target table using batch processing
  /// This is optimized for table renaming operations, much faster than using stream approach
  Future<void> rewriteRecordsFromSourceTable({
    required String sourceTableName,
    required String targetTableName,
    required Future<List<Map<String, dynamic>>> Function(
      List<Map<String, dynamic>> records,
      int partitionIndex,
    ) processFunction,
    List<int>? encryptionKey,
    int? encryptionKeyId,
  }) async {
    try {
      // Get source table meta
      final sourceFileMeta = await getTableFileMeta(sourceTableName);
      if (sourceFileMeta == null || sourceFileMeta.partitions == null) {
        return;
      }

      // Get source table schema
      final sourceSchema = await _dataStore.getTableSchema(sourceTableName);
      if (sourceSchema == null) {
        return;
      }
      final isGlobal = sourceSchema.isGlobal;
      final primaryKey = sourceSchema.primaryKey;

      final tasks =
          sourceFileMeta.partitions!.map((p) => p.index).map((partitionIndex) {
        return () async {
          // Read source partition data
          final records = await readRecordsFromPartition(
              sourceTableName, isGlobal, partitionIndex, primaryKey,
              encryptionKey: encryptionKey, encryptionKeyId: encryptionKeyId);

          // Process data with transformation function
          final processedRecords =
              await processFunction(records, partitionIndex);

          // Write to target table with same partition index
          return await _savePartitionFile(
            targetTableName,
            isGlobal,
            partitionIndex,
            processedRecords,
            primaryKey,
            [], // No existing partitions for target table
            operationType: BufferOperationType.rewrite,
            encryptionKey: encryptionKey,
            encryptionKeyId: encryptionKeyId,
          );
        };
      }).toList();
      final partitionMetas =
          await ParallelProcessor.execute<PartitionMeta>(tasks);

      // Update target table meta with all collected partitions
      final validMetas = partitionMetas.whereType<PartitionMeta>().toList();
      if (validMetas.isNotEmpty) {
        await _updateTableMetadataWithAllPartitions(
            targetTableName, validMetas, []);
      }
    } catch (e, stack) {
      Logger.error(
        'Failed to rewrite records from source table: $e\n$stack',
        label: 'TableDataManager.rewriteRecordsFromSourceTable',
      );
    }
  }

  /// check if primary key is ordered type
  Future<bool> _isPrimaryKeyOrdered(String tableName) async {
    try {
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
        return false;
      }
      return schema.isPrimaryKeyOrdered();
    } catch (e) {
      Logger.error('check if primary key is ordered type failed: $e',
          label: 'TableDataManager._isPrimaryKeyOrdered');
      return false;
    }
  }

  /// flush all delete buffer
  Future<void> flushDeleteBuffer() async {
    if (_deleteBuffer.isEmpty) return;

    final startTime = DateTime.now();
    final maxTablesPerFlush = _dataStore.config.maxTablesPerFlush;
    final maxBatchSize = _dataStore.config.maxBatchSize;

    // Get list of tables to process that are not already being processed
    final availableTables = _deleteBuffer.keys
        .where((tableName) => !_processingTables.contains(tableName))
        .toList();

    if (availableTables.isEmpty) {
      return;
    }

    // Sort tables by priority (larger queue size has higher priority)
    availableTables.sort((a, b) =>
        (_deleteBuffer[b]?.length ?? 0) - (_deleteBuffer[a]?.length ?? 0));

    // Filter for high-priority tables that meet the batch size threshold
    final highPriorityTables = availableTables
        .where(
            (table) => (_deleteBuffer[table]?.length ?? 0) >= maxBatchSize / 2)
        .take(maxTablesPerFlush)
        .toList();

    // If no high-priority tables, take the largest ones up to the flush limit
    final tablesToProcess = highPriorityTables.isNotEmpty
        ? highPriorityTables
        : availableTables
            .take(min(maxTablesPerFlush, availableTables.length))
            .toList();

    if (tablesToProcess.isEmpty) {
      return;
    }

    try {
      // Dynamic Concurrency Distribution
      final totalConcurrency = _effectiveMaxConcurrent;
      final numTables = tablesToProcess.length;
      final baseConcurrency = totalConcurrency ~/ numTables;
      final remainder = totalConcurrency % numTables;

      final concurrencyPerTable = List.generate(
          numTables, (i) => baseConcurrency + (i < remainder ? 1 : 0));

      // Process tables in parallel
      await ParallelProcessor.execute<void>(
        List.generate(tablesToProcess.length, (index) {
          final tableName = tablesToProcess[index];
          final concurrencyForThisTable = concurrencyPerTable[index];
          return () => _flushTableDeleteBuffer(tableName,
              concurrency: concurrencyForThisTable);
        }),
        timeout: ParallelProcessor.noTimeout,
      );

      final duration = DateTime.now().difference(startTime).inMilliseconds;

      // check how many tables and records are left to process
      final remainingTables = _deleteBuffer.length;
      final remainingRecords =
          _deleteBuffer.values.fold(0, (sum, table) => sum + table.length);

      if (remainingTables > 0) {
        Logger.debug(
            'This delete flush processed ${tablesToProcess.length} tables, time: ${duration}ms, there are $remainingTables tables and $remainingRecords records left to process',
            label: 'TableDataManager.flushDeleteBuffer');
      } else {
        Logger.debug(
            'All table delete buffers flushed, processed ${tablesToProcess.length} tables, time: ${duration}ms',
            label: 'TableDataManager.flushDeleteBuffer');
      }
    } catch (e, stackTrace) {
      Logger.error('Failed to flush delete buffer: $e',
          label: 'TableDataManager.flushDeleteBuffer');
      Logger.error(stackTrace.toString(),
          label: 'TableDataManager.flushDeleteBuffer');

      // when error occurs, clear the processing table marks
      _processingTables.clear();
    }
  }

  /// Flush single table delete buffer
  Future<void> _flushTableDeleteBuffer(String tableName,
      {int? concurrency}) async {
    // Use lock manager's exclusive lock to ensure data for the same table isn't processed concurrently
    final lockKey = 'table_$tableName';
    bool lockAcquired = false;

    // Try to acquire lock, skip this processing if already occupied
    if (_dataStore.lockManager != null) {
      if (!_dataStore.lockManager!.tryAcquireExclusiveLock(lockKey)) {
        Logger.debug(
            'Table $tableName is being processed by another operation, skipping this delete flush',
            label: 'TableDataManager._flushTableDeleteBuffer');
        return;
      }
      lockAcquired = true;
      _processingTables.add(tableName);
    } else if (_processingTables.contains(tableName)) {
      // Without lock manager, use _processingTables as simple reentry prevention
      Logger.debug(
          'Table $tableName is being processed, skipping this delete flush',
          label: 'TableDataManager._flushTableDeleteBuffer');
      return;
    } else {
      _processingTables.add(tableName);
    }

    try {
      // Check buffer state again (may have been modified while acquiring lock)
      if (!_deleteBuffer.containsKey(tableName) ||
          _deleteBuffer[tableName]!.isEmpty) {
        return;
      }

      final totalQueueSize = _deleteBuffer[tableName]!.length;
      final maxBatchSize =
          _dataStore.config.maxBatchSize * _effectiveMaxConcurrent;

      Logger.debug(
          'Starting to process delete buffer for table $tableName, queue size: $totalQueueSize',
          label: 'TableDataManager._flushTableDeleteBuffer');

      // Record start time
      final startTime = DateTime.now();
      // Track processed records
      int recordsProcessed = 0;

      // Continue processing buffer as long as there's data and table buffer exists
      while (_deleteBuffer.containsKey(tableName) &&
          !(_deleteBuffer[tableName]?.isEmpty ?? true)) {
        // Get current queue size
        final currentQueueSize = _deleteBuffer[tableName]!.length;

        // Determine batch size for current iteration
        final currentBatchSize = min(maxBatchSize, currentQueueSize);
        if (currentBatchSize <= 0) {
          break;
        }

        // Get latest keys directly from current buffer
        final keysToProcess = _deleteBuffer[tableName]!
            .keys
            .take(currentBatchSize.toInt())
            .toList();

        if (keysToProcess.isEmpty ||
            (_deleteBuffer[tableName]?.isEmpty ?? true)) {
          _deleteBuffer.remove(tableName);
          break;
        }

        // Prepare a list of records to delete
        final recordsToDelete = <Map<String, dynamic>>[];
        // Store processed entries for error recovery
        final processedEntries = <String, BufferEntry>{};

        // Extract data from original buffer and remove immediately
        for (final key in keysToProcess) {
          final entry = _deleteBuffer[tableName]?[key];
          if (entry != null) {
            processedEntries[key] = entry;
            _deleteBuffer[tableName]!
                .remove(key); // Remove from original buffer immediately
            recordsToDelete.add(entry.data);
          }
        }

        // If table buffer is now empty, remove it from delete buffer
        if (_deleteBuffer[tableName]?.isEmpty ?? true) {
          _deleteBuffer.remove(tableName);
        }

        try {
          // Process delete operations
          if (recordsToDelete.isNotEmpty) {
            await writeRecords(
                tableName: tableName,
                records: recordsToDelete,
                operationType: BufferOperationType.delete,
                concurrency: concurrency);
          }

          recordsProcessed += processedEntries.length;

          // After current batch is processed, yield execution thread for 1ms to avoid blocking UI
          if (_deleteBuffer.containsKey(tableName) &&
              !(_deleteBuffer[tableName]?.isEmpty ?? true)) {
            await Future.delayed(const Duration(milliseconds: 1));
          }
        } catch (e) {
          Logger.error('Failed to process delete data for table $tableName: $e',
              label: 'TableDataManager._flushTableDeleteBuffer');

          // failed to process data, add data back to buffer
          final tableBuffer = _deleteBuffer.putIfAbsent(tableName, () => {});
          tableBuffer.addAll(processedEntries);
          break; // stop processing when error occurs
        }
      }

      final endTime = DateTime.now();
      final processingDuration = endTime.difference(startTime).inMilliseconds;

      Logger.debug(
          'Table $tableName delete buffer processing completed, processed $recordsProcessed/$totalQueueSize records, time: ${processingDuration}ms, remaining ${_deleteBuffer[tableName]?.length ?? 0} records',
          label: 'TableDataManager._flushTableDeleteBuffer');
    } catch (e, stackTrace) {
      Logger.error('Failed to flush table $tableName delete buffer: $e',
          label: 'TableDataManager._flushTableDeleteBuffer');
      Logger.error(stackTrace.toString(),
          label: 'TableDataManager._flushTableDeleteBuffer');
    } finally {
      // Release lock regardless of outcome
      if (lockAcquired && _dataStore.lockManager != null) {
        _dataStore.lockManager!.releaseExclusiveLock(lockKey);
      }
      _processingTables.remove(tableName);
    }
  }

  /// Create indexes asynchronously to avoid blocking the main thread
  Future<void> _asyncCreateIndexes({
    required String tableName,
    required String primaryKey,
    required Map<int, List<Map<String, dynamic>>> recordsToCreateIndex,
    required Map<int, int> partitionOffsets,
  }) async {
    try {
      // get distributed node information
      int? clusterId;
      int? nodeId;
      if (_dataStore.config.distributedNodeConfig.enableDistributed) {
        clusterId = _dataStore.config.distributedNodeConfig.clusterId;
        nodeId = _dataStore.config.distributedNodeConfig.nodeId;
      }

      // process by partition index order
      final sortedPartitionIndexes = recordsToCreateIndex.keys.toList()..sort();

      // performance optimization: batch process index creation
      const int indexBatchSize = 500;

      for (final partitionIndex in sortedPartitionIndexes) {
        final recordsForIndex = recordsToCreateIndex[partitionIndex]!;
        final oldRecordsCount = partitionOffsets[partitionIndex] ?? 0;
        int offset = oldRecordsCount; // calculate offset from old record count

        // batch process index creation
        for (int i = 0; i < recordsForIndex.length; i += indexBatchSize) {
          final endIndex = min(i + indexBatchSize, recordsForIndex.length);
          final batch = recordsForIndex.sublist(i, endIndex);

          for (int j = 0; j < batch.length; j++) {
            final record = batch[j];
            final currentOffset = offset + j;

            // skip is deleted record
            if (isDeletedRecord(record)) continue;

            try {
              final recordPointer = await StoreIndex.create(
                  offset: currentOffset,
                  partitionId: partitionIndex,
                  clusterId: clusterId,
                  nodeId: nodeId);
              await _dataStore.indexManager
                  ?.updateIndexes(tableName, record, recordPointer);
            } catch (e) {
              Logger.error(
                  'Failed to update record index: $e, record: ${record[primaryKey]}',
                  label: 'TableDataManager._asyncCreateIndexes');
            }
          }

          offset += batch.length;

          // Yield to the event loop after processing each batch to keep the UI responsive.
          await Future.delayed(Duration.zero);
        }
      }
    } catch (e) {
      // Handle any exceptions to prevent them from affecting other operations
      Logger.error('Error during async index creation for table $tableName: $e',
          label: 'TableDataManager._asyncCreateIndexes');
    }
  }

  /// Get current table metadata cache size in bytes
  int getCurrentTableMetaCacheSize() {
    return _currentTableMetaCacheSize;
  }

  /// Get the set of primary key values for records pending deletion in the buffer.
  Set<String> getPendingDeletePrimaryKeys(String tableName) {
    final deleteQueue = _deleteBuffer[tableName];
    if (deleteQueue == null || deleteQueue.isEmpty) {
      return const <String>{};
    }
    return deleteQueue.keys.toSet();
  }
}

/// Check if a record is a deleted record (marked with _deleted_:true flag)
bool isDeletedRecord(Map<String, dynamic> record) {
  // Check for explicit deletion marker (preferred method)
  if (record['_deleted_'] == true) {
    return true;
  }

  // For backward compatibility: empty object is also considered a deleted record
  return record.isEmpty;
}
