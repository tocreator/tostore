import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../handler/logger.dart';
import '../handler/common.dart';
import '../model/file_info.dart';
import '../model/store_index.dart';
import '../model/table_schema.dart';
import '../handler/value_comparator.dart';
import '../model/index_entry.dart';
import 'crontab_manager.dart';
import 'b_plus_tree.dart';
import 'data_store_impl.dart';

/// Index Manager
/// Responsible for index creation, update, deletion, and query operations
class IndexManager {
  final DataStoreImpl _dataStore;

  // Index cache - table name + index name -> B+ tree index instance
  final Map<String, BPlusTree> _indexCache = {};

  // Index metadata cache - table name + index name -> index metadata
  final Map<String, IndexMeta> _indexMetaCache = {};

  // Index cache status - table name + index name -> whether fully cached
  final Map<String, bool> _indexFullyCached = {};

  // Index access weight - table name + index name -> {weight: weight value, lastAccess: last access time}
  final Map<String, Map<String, dynamic>> _indexAccessWeights = {};

  // Index write buffer - table name + index name -> Map<String, IndexBufferEntry>
  // "tableName:indexName"，"indexKey|recordPointer"
  final Map<String, Map<String, IndexBufferEntry>> _writeBuffer = {};

  // Index delete buffer - table name + index name -> Map<String, IndexBufferEntry>
  // "tableName:indexName"，"indexKey|recordPointer"
  final Map<String, Map<String, IndexBufferEntry>> _deleteBuffer = {};

  // Index writing status - table name + index name -> whether writing
  final Map<String, bool> _indexWriting = {};

  // Last index write time - table name + index name -> last write time
  final Map<String, DateTime> _indexLastWriteTime = {};

  // Whether the cron task has been initialized
  bool _cronInitialized = false;

  // Whether the database is closing
  bool _isClosing = false;

  // Number of asynchronous write operations being processed
  int _pendingWrites = 0;

  // Number of pending index entries to process
  int _pendingEntriesCount = 0;

  // Asynchronous write completion event
  final Completer<void> _allWritesCompleted = Completer<void>();

  // Fast processing mode handler
  void Function()? _fastProcessCallback;

  // Whether fast processing mode is enabled
  bool _fastProcessEnabled = false;

  // Fast processing mode size threshold
  static const int _fastProcessThreshold = 1000;

  // Number of consecutive small buffer checks, used to automatically disable fast mode
  static const int _maxSmallBufferChecks = 5;

  // Small buffer check count
  int _smallBufferCheckCount = 0;

  // Mark whether the index write buffer is being processed
  bool _isProcessingWriteBuffer = false;

  IndexManager(this._dataStore) {
    _initCronTask();
  }

  /// Initialize cron task
  void _initCronTask() {
    if (_cronInitialized) return;

    // Process index write buffer periodically
    CrontabManager.addCallback(ExecuteInterval.seconds3, () {
      _processIndexWriteBuffer();
    });

    _cronInitialized = true;

    // Check if immediate write buffer processing is needed
    _checkInitialWriteBuffer();
  }

  /// Enable fast processing mode
  void _enableFastProcessMode() {
    if (_fastProcessEnabled) return;

    _fastProcessEnabled = true;
    _fastProcessCallback = () {
      _checkBufferSizes();
    };

    // Add 1 second cycle check
    CrontabManager.addCallback(ExecuteInterval.seconds1, _fastProcessCallback!);

    Logger.debug('Enabled index fast processing mode',
        label: 'IndexManager._enableFastProcessMode');
  }

  /// Disable fast processing mode
  void _disableFastProcessMode() {
    if (!_fastProcessEnabled || _fastProcessCallback == null) return;

    // Remove 1 second cycle check
    CrontabManager.removeCallback(
        ExecuteInterval.seconds1, _fastProcessCallback!);
    _fastProcessEnabled = false;
    _fastProcessCallback = null;
  }

  /// Check all buffer sizes
  void _checkBufferSizes() {
    bool hasLargeBuffer = false;
    List<String> keysToProcess = [];

    // Check insert buffer
    for (final key in _writeBuffer.keys) {
      if (_writeBuffer[key] != null &&
          _writeBuffer[key]!.length >= _fastProcessThreshold) {
        hasLargeBuffer = true;
        keysToProcess.add(key);
      }
    }

    // Check delete buffer
    for (final key in _deleteBuffer.keys) {
      if (_deleteBuffer[key] != null &&
          _deleteBuffer[key]!.length >= _fastProcessThreshold) {
        hasLargeBuffer = true;
        keysToProcess.add(key);
      }
    }

    // If there is a large buffer, process immediately
    if (hasLargeBuffer) {
      _processIndexWriteBuffer(specificKeys: keysToProcess);
      _smallBufferCheckCount = 0; // Reset counter
    } else {
      // If no large buffer is found after multiple consecutive checks, disable fast mode
      _smallBufferCheckCount++;

      if (_smallBufferCheckCount >= _maxSmallBufferChecks) {
        _disableFastProcessMode();
        _smallBufferCheckCount = 0;
      }
    }
  }

  /// Check initial write buffer, if the index last write time exceeds 3 seconds, trigger write immediately
  Future<void> _checkInitialWriteBuffer() async {
    final now = DateTime.now();
    final keysToProcess = <String>[];

    _indexLastWriteTime.forEach((key, lastWrite) {
      if (now.difference(lastWrite).inSeconds > 3) {
        keysToProcess.add(key);
      }
    });

    if (keysToProcess.isNotEmpty) {
      await _processIndexWriteBuffer(specificKeys: keysToProcess);
    }
  }

  /// Process index write buffer
  Future<void> _processIndexWriteBuffer({List<String>? specificKeys}) async {
    // If already processing, avoid duplicate execution
    if (!_isClosing && _isProcessingWriteBuffer) {
      Logger.debug('Index write buffer is being processed, skipping',
          label: 'IndexManager._processIndexWriteBuffer');
      return;
    }

    // Get keys from both buffers if not specified
    final keysToProcess = specificKeys ?? _getKeysWithEntries();

    if (keysToProcess.isEmpty) {
      // If there are no keys to process but in the closing phase, mark all writes as completed
      if (_isClosing &&
          _pendingWrites == 0 &&
          !_allWritesCompleted.isCompleted) {
        _allWritesCompleted.complete();
      }
      return;
    }

    try {
      // Set processing flag, only set when not closing
      if (!_isClosing) {
        _isProcessingWriteBuffer = true;
      }

      // Track operations to wait for completion when the database is closing
      _pendingWrites++;

      // Calculate total entries, determine if batch processing is needed
      int totalEntries = 0;
      final keysWithEntries = <String>[];

      // Check each key's buffer situation
      for (final key in keysToProcess) {
        try {
          // Check if the buffer has data in either insert or delete buffer
          int entries = 0;

          // Check insert buffer
          if (_writeBuffer.containsKey(key) && _writeBuffer[key]!.isNotEmpty) {
            entries += _writeBuffer[key]!.length;
          }

          // Check delete buffer
          if (_deleteBuffer.containsKey(key) &&
              _deleteBuffer[key]!.isNotEmpty) {
            entries += _deleteBuffer[key]!.length;
          }

          if (entries > 0) {
            totalEntries += entries;
            keysWithEntries.add(key);
          }
        } catch (e) {
          Logger.error('Error checking buffer: $e',
              label: 'IndexManager._processIndexWriteBuffer');
        }
      }

      // Record the current total number of pending entries, only used to estimate when closing
      _pendingEntriesCount = totalEntries;

      Logger.debug('Total pending index entries: $totalEntries',
          label: 'IndexManager._processIndexWriteBuffer');

      // If there are no keys to process, return directly
      if (keysWithEntries.isEmpty) {
        _pendingWrites--; // Reduce count, because there are no actual operations
        // If closing phase and no pending writes, mark completed
        if (_isClosing &&
            _pendingWrites == 0 &&
            !_allWritesCompleted.isCompleted) {
          _allWritesCompleted.complete();
        }
        return;
      }

      if (totalEntries > 1000) {
        await _processBatchIndexWrites(keysWithEntries, totalEntries);
      } else {
        // Use existing processing logic for small number of entries
        await _processRegularIndexWrites(keysWithEntries);
      }

      // After processing, reduce count
      _pendingEntriesCount = max(0, _pendingEntriesCount - totalEntries);
      _pendingWrites--;

      Logger.debug(
          'Processing completed, total index entries processed: $totalEntries, remaining pending writes: $_pendingWrites',
          label: 'IndexManager._processIndexWriteBuffer');

      // Check if it is the last write operation
      if (_isClosing &&
          _pendingWrites == 0 &&
          !_allWritesCompleted.isCompleted) {
        _allWritesCompleted.complete();
      }
    } catch (e) {
      Logger.error('Failed to process index write buffer: $e',
          label: 'IndexManager._processIndexWriteBuffer');

      // Even if an error occurs, reduce the count to avoid blocking the closing process
      _pendingWrites--;

      // Check if it is the last write operation
      if (_isClosing &&
          _pendingWrites == 0 &&
          !_allWritesCompleted.isCompleted) {
        _allWritesCompleted.complete();
      }
    } finally {
      if (!_isClosing) {
        _isProcessingWriteBuffer = false;
      }
    }
  }

  /// Helper to get all keys with entries in either buffer
  List<String> _getKeysWithEntries() {
    final result = <String>{};

    // Add keys from insert buffer
    for (final key in _writeBuffer.keys) {
      if (_writeBuffer[key] != null && _writeBuffer[key]!.isNotEmpty) {
        result.add(key);
      }
    }

    // Add keys from delete buffer
    for (final key in _deleteBuffer.keys) {
      if (_deleteBuffer[key] != null && _deleteBuffer[key]!.isNotEmpty) {
        result.add(key);
      }
    }

    return result.toList();
  }

  /// Process regular index writes
  Future<void> _processRegularIndexWrites(List<String> keysToProcess) async {
    for (final key in keysToProcess) {
      if (_indexWriting[key] == true) continue;

      try {
        _indexWriting[key] = true;

        // Check if there's any data to process
        bool hasInserts =
            _writeBuffer.containsKey(key) && _writeBuffer[key]!.isNotEmpty;
        bool hasDeletes =
            _deleteBuffer.containsKey(key) && _deleteBuffer[key]!.isNotEmpty;

        if (!hasInserts && !hasDeletes) {
          _indexWriting[key] = false;
          continue;
        }

        final parts = key.split(':');
        if (parts.length != 2) {
          _indexWriting[key] = false;
          continue;
        }

        final tableName = parts[0];
        final indexName = parts[1];

        // Get index metadata
        final indexMeta = await _getIndexMeta(tableName, indexName);
        if (indexMeta == null) {
          _indexWriting[key] = false;
          continue;
        }

        // Process inserts - new optimized approach
        if (hasInserts) {
          final writeBuffer = _writeBuffer[key]!;
          final maxBatchSize = _dataStore.config.maxBatchSize;
          final maxPartitionFileSize = _dataStore.config.maxPartitionFileSize;

          // Get initial snapshot of buffer size to process in this run
          final initialBufferSize = writeBuffer.length;
          int processedCount = 0;

          // Get last partition index and remaining size
          int currentPartitionSize = indexMeta.partitions.isEmpty
              ? 0
              : indexMeta.partitions.last.fileSizeInBytes;
          int remainingSpaceInPartition =
              maxPartitionFileSize - currentPartitionSize;

          // Process until we've completed the initial buffer size or no more data
          while (processedCount < initialBufferSize && writeBuffer.isNotEmpty) {
            // Determine optimal batch size based on remaining space and max batch size
            const estimatedEntrySize =
                100; // Approximate average size per entry
            int optimalBatchSize = min(
                min(
                    maxBatchSize,
                    writeBuffer
                        .length), // Don't exceed buffer size or max batch
                remainingSpaceInPartition ~/
                    estimatedEntrySize // Don't exceed partition capacity
                );

            // Ensure we process at least some entries even if space is tight
            optimalBatchSize = max(optimalBatchSize, 1);

            // Take a batch of keys
            final processingKeys =
                writeBuffer.keys.take(optimalBatchSize).toList();
            final currentBatchMap = <dynamic, Set<dynamic>>{};

            // Convert to old format for this batch
            for (final k in processingKeys) {
              final entry = writeBuffer[k]!;
              final indexKey = entry.indexEntry.indexKey;
              final recordId = entry.indexEntry.recordPointer.toString();

              if (!currentBatchMap.containsKey(indexKey)) {
                currentBatchMap[indexKey] = <dynamic>{};
              }
              currentBatchMap[indexKey]!.add(recordId);
            }

            // Process this batch
            await _writeIndexToFile(tableName, indexName, currentBatchMap);

            // Remove processed entries immediately
            for (final k in processingKeys) {
              writeBuffer.remove(k);
            }

            // Update counters
            processedCount += processingKeys.length;

            // Get updated partition info
            final updatedMeta = await _getIndexMeta(tableName, indexName);
            if (updatedMeta != null) {
              currentPartitionSize = updatedMeta.partitions.isEmpty
                  ? 0
                  : updatedMeta.partitions.last.fileSizeInBytes;
              remainingSpaceInPartition =
                  maxPartitionFileSize - currentPartitionSize;
            } else {
              // Reset if metadata not available
              currentPartitionSize = 0;
              remainingSpaceInPartition = maxPartitionFileSize;
            }

            // Small delay between batches
            await Future.delayed(const Duration(milliseconds: 5));
          }
        }

        // Process deletes
        if (hasDeletes) {
          // Get all entries at once
          final deleteBuffer = _deleteBuffer[key]!;
          final allDeleteEntries = <dynamic, Set<dynamic>>{};

          // Convert all entries to old format
          for (final entry in deleteBuffer.values) {
            final indexKey = entry.indexEntry.indexKey;
            final recordId = entry.indexEntry.recordPointer.toString();

            if (!allDeleteEntries.containsKey(indexKey)) {
              allDeleteEntries[indexKey] = <dynamic>{};
            }
            allDeleteEntries[indexKey]!.add(recordId);
          }

          // Clear the buffer immediately to avoid duplicate processing
          deleteBuffer.clear();

          // Process all deletes
          await _processDeleteEntries(tableName, indexName, allDeleteEntries);
        }

        // Update last write time
        _indexLastWriteTime[key] = DateTime.now();
      } catch (e) {
        Logger.error('Failed to process index write buffer: $e',
            label: 'IndexManager._processIndexWriteBuffer');
      } finally {
        _indexWriting[key] = false;
      }
    }
  }

  /// Process delete entries - remove entries from the B+ tree in the file
  Future<void> _processDeleteEntries(String tableName, String indexName,
      Map<dynamic, Set<dynamic>> entriesToDelete) async {
    try {
      // Need to get all partitions for this index
      final indexMeta = await _getIndexMeta(tableName, indexName);
      if (indexMeta == null) return;

      // Check if this is a primary key or unique index
      final isUniqueIndex = indexName == 'pk_$tableName' ||
          indexMeta.isUnique ||
          indexName.startsWith('uniq_');

      // Process each delete entry by finding it in each partition
      await processIndexPartitions(tableName, indexName,
          processor: (_, __, btree) async {
        int processedCount = 0;
        final entryList = entriesToDelete.entries.toList();

        for (final entry in entryList) {
          final key = entry.key;
          final recordIds = entry.value;

          // Search for this key in the current partition
          final existingValues = await btree.search(key);

          // Remove matching record IDs
          for (final recordId in recordIds) {
            for (final existingValue in existingValues) {
              if (existingValue.toString() == recordId) {
                await btree.delete(key, recordId);
                processedCount++;

                // Remove processed entries from entriesToDelete
                entriesToDelete[key]!.remove(recordId);
                if (entriesToDelete[key]!.isEmpty) {
                  entriesToDelete.remove(key);
                }

                // Give the main thread a break every 50 deletions
                if (processedCount % 50 == 0) {
                  await Future.delayed(const Duration(milliseconds: 1));
                }

                // For unique indexes, stop after first match since they only have one record per key
                if (isUniqueIndex) {
                  return false; // stop processing more partitions
                }

                break;
              }
            }
          }
        }

        // For regular indexes, continue checking other partitions as entries may be spread across multiple partitions
        return true;
      });

      Logger.debug(
          'Processed ${entriesToDelete.length} delete entries for $tableName.$indexName',
          label: 'IndexManager._processDeleteEntries');
    } catch (e, stack) {
      Logger.error('Failed to process delete entries: $e\n$stack',
          label: 'IndexManager._processDeleteEntries');
    }
  }

  /// Batch process index writes
  Future<void> _processBatchIndexWrites(
      List<String> keys, int totalEntries) async {
    // Calculate optimal batch size - reduce batch size to improve stability
    final int batchSize = _calculateOptimalBatchSize(totalEntries);

    // Process each index
    for (final key in keys) {
      if (_indexWriting[key] == true) continue;

      try {
        _indexWriting[key] = true;

        // No need to extract data anymore, we'll use the collections directly

        // Check if there's any data to process
        bool hasInserts =
            _writeBuffer.containsKey(key) && _writeBuffer[key]!.isNotEmpty;
        bool hasDeletes =
            _deleteBuffer.containsKey(key) && _deleteBuffer[key]!.isNotEmpty;

        if (!hasInserts && !hasDeletes) {
          _indexWriting[key] = false;
          continue;
        }

        // Get index information
        final parts = key.split(':');
        if (parts.length != 2) {
          _indexWriting[key] = false;
          continue;
        }

        final tableName = parts[0];
        final indexName = parts[1];

        // Get index metadata
        final indexMeta = await _getIndexMeta(tableName, indexName);
        if (indexMeta == null) {
          _indexWriting[key] = false;
          continue;
        }

        // Process inserts (using batch mode)
        if (hasInserts) {
          final entryList = _writeBuffer[key]!.values.toList();

          for (int i = 0; i < entryList.length; i += batchSize) {
            final end = min(i + batchSize, entryList.length);

            // Create current batch entries map for backward compatibility
            final batchEntries = <dynamic, Set<dynamic>>{};
            for (int j = i; j < end; j++) {
              final entry = entryList[j];
              final indexKey = entry.indexEntry.indexKey;
              final recordId = entry.indexEntry.recordPointer.toString();

              if (!batchEntries.containsKey(indexKey)) {
                batchEntries[indexKey] = <dynamic>{};
              }
              batchEntries[indexKey]!.add(recordId);
            }

            // Write current batch
            await _writeIndexToFile(tableName, indexName, batchEntries);

            // Small delay between batches to avoid blocking the main thread
            if (i + batchSize < entryList.length) {
              await Future.delayed(const Duration(milliseconds: 5));
            }
          }

          // Clear insert buffer
          _writeBuffer[key]!.clear();
        }

        // Process deletes (also in batch mode)
        if (hasDeletes) {
          final entryList = _deleteBuffer[key]!.values.toList();

          // Process deletes in batches to avoid loading too many partitions at once
          for (int i = 0; i < entryList.length; i += batchSize) {
            final end = min(i + batchSize, entryList.length);

            // Create current batch delete map for backward compatibility
            final batchDeletes = <dynamic, Set<dynamic>>{};
            for (int j = i; j < end; j++) {
              final entry = entryList[j];
              final indexKey = entry.indexEntry.indexKey;
              final recordId = entry.indexEntry.recordPointer.toString();

              if (!batchDeletes.containsKey(indexKey)) {
                batchDeletes[indexKey] = <dynamic>{};
              }
              batchDeletes[indexKey]!.add(recordId);
            }

            // Process this batch of deletes
            await _processDeleteEntries(tableName, indexName, batchDeletes);

            // Small delay between batches
            if (i + batchSize < entryList.length) {
              await Future.delayed(const Duration(milliseconds: 5));
            }
          }

          // Clear delete buffer
          _deleteBuffer[key]!.clear();
        }

        // Update last write time
        _indexLastWriteTime[key] = DateTime.now();
      } catch (e, stack) {
        Logger.error('Failed to batch write index: $e\n$stack',
            label: 'IndexManager._processBatchIndexWrites');
      } finally {
        _indexWriting[key] = false;
      }
    }
  }

  /// Calculate optimal batch size
  int _calculateOptimalBatchSize(int totalEntries) {
    // Dynamically adjust batch size based on total entries, use smaller batches for large data
    if (totalEntries > 100000) return 2000;
    if (totalEntries > 10000) return 1000;
    if (totalEntries > 5000) return 500;
    return 200;
  }

  void dispose() {
    // Ensure fast processing mode is disabled
    _disableFastProcessMode();

    _indexCache.clear();
    _indexMetaCache.clear();
    _indexFullyCached.clear();
    _indexAccessWeights.clear();
    _writeBuffer.clear();
    _indexWriting.clear();
    _indexLastWriteTime.clear();
    _deleteBuffer.clear();
    _pendingWrites = 0;
    _pendingEntriesCount = 0;
    _isClosing = false;

    // Reset completion event
    if (!_allWritesCompleted.isCompleted) {
      _allWritesCompleted.complete();
    }
  }

  /// Save important data before application exit
  Future<bool> saveBeforeAppExit() async {
    try {
      // Check if there are pending write buffers
      bool hasChanges = false;

      // Check insert buffer
      for (final key in _writeBuffer.keys) {
        if (_writeBuffer[key] != null && _writeBuffer[key]!.isNotEmpty) {
          hasChanges = true;
          break;
        }
      }

      // Check delete buffer if insert buffer has no changes
      if (!hasChanges) {
        for (final key in _deleteBuffer.keys) {
          if (_deleteBuffer[key] != null && _deleteBuffer[key]!.isNotEmpty) {
            hasChanges = true;
            break;
          }
        }
      }

      if (hasChanges) {
        // Set closing flag, ensure synchronous processing
        _isClosing = true;

        // Force processing all write buffers
        await _processIndexWriteBuffer();
        return true;
      } else {
        return false;
      }
    } catch (e) {
      Logger.error('Failed to save before app exit: $e', label: 'IndexManager');
      return false;
    } finally {
      // Reset closing flag
      _isClosing = false;
    }
  }

  /// Get index cache key
  String _getIndexCacheKey(String tableName, String indexName) {
    return '$tableName:$indexName';
  }

  /// Update index access weight
  void _updateIndexAccessWeight(String cacheKey) {
    try {
      final now = DateTime.now();
      final currentDate = DateTime(now.year, now.month, now.day);

      // Initialize or get current weight information
      final weights = _indexAccessWeights[cacheKey] ??
          {
            'weight': 0,
            'lastAccess': now, // Use current time as initial access time
            'lastWeightUpdate': currentDate
          };

      // Update last access time
      weights['lastAccess'] = now;

      // If it's a new day, update the weight value +1
      final lastUpdate =
          weights['lastWeightUpdate'] as DateTime? ?? DateTime(1970);
      if (currentDate.isAfter(lastUpdate)) {
        weights['weight'] = (weights['weight'] as int? ?? 0) + 1;
        weights['lastWeightUpdate'] = currentDate;
      }

      // Update weight in memory
      _indexAccessWeights[cacheKey] = weights;

      // Check if cache needs to be cleaned
      _checkAndCleanupCache();
    } catch (e) {
      // Weight update exception不影响主流程，只记录日志
      Logger.error('Failed to update index access weight: $e',
          label: 'IndexManager._updateIndexAccessWeight');
    }
  }

  /// Check and clean cache
  void _checkAndCleanupCache() {
    try {
      final cacheSize = _indexCache.length;
      final maxSize = _dataStore.config.maxIndexCacheSize;

      if (cacheSize <= maxSize) return;

      // Need to clean cache, clean 30% of low weight
      final needToRemove = (cacheSize * 0.3).ceil();

      // Sort by weight
      final weightEntries = _indexAccessWeights.entries.toList()
        ..sort((a, b) =>
            (a.value['weight'] as int).compareTo(b.value['weight'] as int));

      // Delete 30% of lowest weight
      int removed = 0;
      for (int i = 0; i < weightEntries.length && removed < needToRemove; i++) {
        final key = weightEntries[i].key;

        _indexCache.remove(key);
        _indexFullyCached.remove(key);
        _indexAccessWeights.remove(key);
        removed++;
      }

      Logger.debug('Cleaned $removed low weight index caches',
          label: 'IndexManager._checkAndCleanupCache');
    } catch (e) {
      Logger.error('Failed to clean index cache: $e',
          label: 'IndexManager._checkAndCleanupCache');
    }
  }

  /// Get index metadata
  Future<IndexMeta?> _getIndexMeta(String tableName, String indexName) async {
    try {
      final cacheKey = _getIndexCacheKey(tableName, indexName);

      // Check cache
      if (_indexMetaCache.containsKey(cacheKey)) {
        return _indexMetaCache[cacheKey];
      }

      // Read index metadata from file
      final metaPath =
          await _dataStore.pathManager.getIndexMetaPath(tableName, indexName);
      if (!await _dataStore.storage.existsFile(metaPath)) {
        return null;
      }

      final content = await _dataStore.storage.readAsString(metaPath);
      if (content == null || content.isEmpty) {
        return null;
      }

      // Parse index metadata
      final json = jsonDecode(content);
      final meta = IndexMeta.fromJson(json);

      // Update cache
      _indexMetaCache[cacheKey] = meta;

      return meta;
    } catch (e) {
      Logger.error('Failed to get index metadata: $e',
          label: 'IndexManager._getIndexMeta');
      return null;
    }
  }

  /// Get index
  /// @param tableName Table name
  /// @param indexName Index name
  Future<BPlusTree?> getIndex(String tableName, String indexName) async {
    try {
      final cacheKey = _getIndexCacheKey(tableName, indexName);

      // Check cache
      if (_indexCache.containsKey(cacheKey)) {
        // Update access weight
        _updateIndexAccessWeight(cacheKey);

        return _indexCache[cacheKey];
      }

      // Check index metadata
      final meta = await _getIndexMeta(tableName, indexName);
      if (meta == null) {
        // When index metadata is not found, check if the table exists
        final tableSchema = await _dataStore.getTableSchema(tableName);
        if (tableSchema == null) {
          return null;
        }
        if (tableSchema.fields.isNotEmpty) {
          // Table exists, check if the index is defined in the table
          if (indexName == 'pk_$tableName') {
            // Primary key index, automatically create
            Logger.info('找不到主键索引 $indexName，自动创建',
                label: 'IndexManager.getIndex');
            await createPrimaryIndex(tableName, tableSchema.primaryKey);
            return getIndex(tableName,
                indexName); // Recursively call to get the created index
          } else {
            // Try to find if it is a normal index
            final indexSchema = tableSchema.indexes.firstWhere(
              (idx) => idx.actualIndexName == indexName,
              orElse: () => const IndexSchema(fields: []),
            );

            if (indexSchema.fields.isNotEmpty) {
              // The table defines this index, but the index file does not exist, create it
              Logger.info(
                  'not found index $indexName, but defined in table schema, auto create',
                  label: 'IndexManager.getIndex');
              await createIndex(tableName, indexSchema);
              return getIndex(tableName,
                  indexName); // Recursively call to get the created index
            }
            // Check if it is a unique field index automatically created
            else if (indexName.startsWith('uniq_')) {
              // Extract possible field names - remove prefix 'uniq_'
              final fieldName = indexName.substring(5);

              // Find if the field is set to unique constraint
              final uniqueField = tableSchema.fields.firstWhere(
                (field) => field.name == fieldName && field.unique,
                orElse: () => const FieldSchema(name: '', type: DataType.text),
              );

              if (uniqueField.name.isNotEmpty) {
                final autoIndexSchema = IndexSchema(
                  fields: [fieldName],
                  unique: true,
                );

                await createIndex(tableName, autoIndexSchema);
                return getIndex(tableName,
                    indexName); // Recursively call to get the created index
              }
            }
          }
        }

        Logger.debug('not found index: $tableName.$indexName, skip index check',
            label: 'IndexManager.getIndex');
        return null;
      }

      // Initialize B+ tree
      final btree = await _loadIndexFromFile(tableName, indexName, meta);
      if (btree == null) {
        return null;
      }

      // Update cache
      _indexCache[cacheKey] = btree;
      _indexFullyCached[cacheKey] =
          true; // From file fully loaded, marked as complete
      _updateIndexAccessWeight(cacheKey);

      return btree;
    } catch (e) {
      Logger.error('Failed to get index: $e', label: 'IndexManager.getIndex');
      return null;
    }
  }

  /// Load index from file
  Future<BPlusTree?> _loadIndexFromFile(
      String tableName, String indexName, IndexMeta meta) async {
    try {
      // Create an empty B+ tree
      final bTree = BPlusTree(
        order: meta.bTreeOrder,
        isUnique: meta.isUnique,
      );

      // Load index data from each partition
      for (final partition in meta.partitions) {
        try {
          final partitionPath = await _dataStore.pathManager
              .getIndexPartitionPath(tableName, indexName, partition.index);

          if (!await _dataStore.storage.existsFile(partitionPath)) {
            continue;
          }

          final content = await _dataStore.storage.readAsString(partitionPath);
          if (content == null || content.isEmpty) {
            continue;
          }

          // Verify checksum (if exists)
          if (partition.checksum != null &&
              !_verifyChecksum(content, partition.checksum!)) {
            Logger.error(
                'Index partition checksum verification failed: $tableName, $indexName, partition: ${partition.index}',
                label: 'IndexManager._loadIndexFromFile');
            continue; // Skip damaged partition
          }

          // Parse B+ tree data
          final data = _parseBTreeData(content);

          // Merge partition data into main B+ tree
          for (final entry in data.entries) {
            for (final value in entry.value) {
              await bTree.insert(entry.key, value);
            }
          }
        } catch (e) {
          Logger.error('Failed to load index partition: $e',
              label: 'IndexManager._loadIndexFromFile');
        }
      }

      return bTree;
    } catch (e) {
      Logger.error('Failed to load index from file: $e',
          label: 'IndexManager._loadIndexFromFile');
      return null;
    }
  }

  /// Parse B+ tree data
  Map<dynamic, List<dynamic>> _parseBTreeData(String content) {
    final result = <dynamic, List<dynamic>>{};
    final lines = content.split('\n');

    for (final line in lines) {
      if (line.trim().isEmpty) continue;

      final parts = line.split('|');
      if (parts.length >= 2) {
        final key = BPlusTree.deserializeValue(parts[0]);
        final values = BPlusTree.deserializeValues(parts[1]);
        result[key] = values;
      }
    }

    return result;
  }

  /// Write index to file
  Future<void> _writeIndexToFile(String tableName, String indexName,
      Map<dynamic, Set<dynamic>> entries) async {
    if (entries.isEmpty) return;

    // Create lock resource identifier for index write operation
    final lockResource = 'index:$tableName:$indexName';
    final operationId = 'write_index_${DateTime.now().millisecondsSinceEpoch}';

    try {
      // Acquire exclusive lock to prevent concurrent writes to the same index file
      await _dataStore.lockManager
          ?.acquireExclusiveLock(lockResource, operationId);

      // Get index metadata
      IndexMeta? meta = await _getIndexMeta(tableName, indexName);
      final bool isNew = meta == null;

      if (isNew) {
        // Create index metadata
        final isUnique =
            indexName.startsWith('uniq_') || indexName.startsWith('pk_');
        final fields = [indexName.split('_').last]; // Simple processing

        meta = IndexMeta(
          version: 1,
          name: indexName,
          tableName: tableName,
          fields: fields,
          isUnique: isUnique,
          bTreeOrder: _dataStore.config.bTreeOrder,
          partitions: [],
          timestamps: Timestamps(
            created: DateTime.now(),
            modified: DateTime.now(),
          ),
        );
      }

      // Get current available partition
      int partitionIndex =
          meta.partitions.isEmpty ? 0 : meta.partitions.last.index;

      // Get current partition size
      int currentSize =
          meta.partitions.isEmpty ? 0 : meta.partitions.last.fileSizeInBytes;

      // Calculate estimated size based on number of entries
      // Use average size estimate: 100 bytes per key-value pair (conservative estimate)
      int estimatedNewSize = currentSize + (entries.length * 100);

      // If the estimated size exceeds the maximum file size, create a new partition
      if (estimatedNewSize > _dataStore.config.maxPartitionFileSize) {
        partitionIndex++;
        currentSize = 0;
      }

      // Ensure partition directory exists
      final dirPath = await _dataStore.pathManager
          .getIndexPartitionDirPath(tableName, indexName, partitionIndex);
      await _dataStore.storage.ensureDirectoryExists(dirPath);

      // Get partition file path
      final partitionPath = await _dataStore.pathManager
          .getIndexPartitionPath(tableName, indexName, partitionIndex);

      // Create or get B+ tree
      BPlusTree btree;
      try {
        if (await _dataStore.storage.existsFile(partitionPath)) {
          final content =
              await _dataStore.storage.readAsString(partitionPath) ?? '';
          btree = BPlusTree.fromString(
            content,
            order: meta.bTreeOrder,
            isUnique: meta.isUnique,
          );
        } else {
          btree = BPlusTree(
            order: meta.bTreeOrder,
            isUnique: meta.isUnique,
          );
        }

        // Batch process key-value pairs to avoid processing too many at once
        // Reduce insert batch size to avoid overflow of B+ tree nodes
        const int insertBatchSize =
            50; // Reduce batch size to improve stability
        final entryList = entries.entries.toList();

        for (int i = 0; i < entryList.length; i += insertBatchSize) {
          final endIndex = min(i + insertBatchSize, entryList.length);
          final batchEntries = entryList.sublist(i, endIndex);

          for (final entry in batchEntries) {
            // Process each key separately to reduce the problem of inserting too many values at once
            for (final value in entry.value) {
              try {
                await btree.insert(entry.key, value);
              } catch (e, stack) {
                Logger.error(
                    'Failed to insert B+ tree: key=${entry.key}, value=$value, error=$e\n$stack',
                    label: 'IndexManager._writeIndexToFile');
                // If it is an index overflow error, reduce the processing batch and continue to try
                if (e.toString().contains('RangeError') ||
                    e.toString().contains('out of range')) {
                  // It may be a B+ tree structure problem, skip this value and continue to process other values
                  continue;
                }
              }
            }
          }

          // Slight delay between batches to avoid blocking
          if (i + insertBatchSize < entryList.length) {
            await Future.delayed(const Duration(milliseconds: 1));
          }
        }

        // Serialize B+ tree
        final serialized = btree.toStringHandle();

        // Calculate partition size
        final newSize = serialized.length;

        // Write to partition file
        await _dataStore.storage.writeAsString(partitionPath, serialized);

        // Calculate checksum
        final checksum = _calculateChecksum(serialized);

        // Update index metadata
        final hasExistingPartition =
            meta.partitions.any((p) => p.index == partitionIndex);

        // Calculate index value range information
        dynamic minKey, maxKey;

        try {
          if (entries.isNotEmpty) {
            final keys = entries.keys.toList();

            // Check if this index is a primary key index
            bool isPrimaryKeyIndex = false;
            if (indexName == 'pk_$tableName') {
              isPrimaryKeyIndex = true;
            }

            // Get table structure, for checking if the index is ordered
            final schema = await _dataStore.getTableSchema(tableName);
            if (schema == null) {
              return;
            }

            // Only primary key index or field explicitly set to ordered, calculate partition key range
            bool shouldCalculateRange = false;

            if (isPrimaryKeyIndex) {
              // For primary key index, check if the primary key is ordered
              shouldCalculateRange = _isPrimaryKeyOrdered(schema);
            }

            if (shouldCalculateRange) {
              minKey = _calculateMinKey(keys);
              maxKey = _calculateMaxKey(keys);
            }
          }
        } catch (e) {
          // Calculation exception, not affect main process
          Logger.debug('Failed to calculate index range: $e',
              label: 'IndexManager._writeIndexToFile');
        }

        if (hasExistingPartition) {
          // Update existing partition
          meta = meta.copyWith(
            partitions: meta.partitions.map((p) {
              if (p.index == partitionIndex) {
                return p.copyWith(
                  fileSizeInBytes: newSize,
                  bTreeSize: serialized.length,
                  entries: btree.count(),
                  minKey: minKey != null ? (p.minKey ?? minKey) : p.minKey,
                  maxKey: maxKey != null
                      ? (ValueComparator.compare(maxKey, (p.maxKey ?? maxKey)) >
                              0
                          ? maxKey
                          : p.maxKey)
                      : p.maxKey,
                  timestamps: Timestamps(
                    created: p.timestamps.created,
                    modified: DateTime.now(),
                  ),
                  checksum: checksum,
                );
              }
              return p;
            }).toList(),
            timestamps: Timestamps(
              created: meta.timestamps.created,
              modified: DateTime.now(),
            ),
          );
        } else {
          // Add new partition
          final newPartition = IndexPartitionMeta(
            version: 1,
            index: partitionIndex,
            fileSizeInBytes: newSize,
            minKey: minKey,
            maxKey: maxKey,
            bTreeSize: serialized.length,
            entries: btree.count(),
            timestamps: Timestamps(
              created: DateTime.now(),
              modified: DateTime.now(),
            ),
            checksum: checksum,
          );

          meta = meta.copyWith(
            partitions: [...meta.partitions, newPartition],
            timestamps: Timestamps(
              created: meta.timestamps.created,
              modified: DateTime.now(),
            ),
          );
        }

        // Write index metadata
        final metaPath =
            await _dataStore.pathManager.getIndexMetaPath(tableName, indexName);
        await _dataStore.storage
            .writeAsString(metaPath, jsonEncode(meta.toJson()));

        // Update cache
        final cacheKey = _getIndexCacheKey(tableName, indexName);
        _indexMetaCache[cacheKey] = meta;

        // If the index is cached, update the cache
        if (_indexCache.containsKey(cacheKey)) {
          try {
            // Batch update memory cache to avoid processing too many at once
            final entryList = entries.entries.toList();
            // Further reduce memory cache batch size
            const int memCacheBatchSize = 30;
            for (int i = 0; i < entryList.length; i += memCacheBatchSize) {
              final endIndex = min(i + memCacheBatchSize, entryList.length);
              final batchEntries = entryList.sublist(i, endIndex);

              bool batchHadErrors = false;

              for (final entry in batchEntries) {
                // Each key-value pair is processed independently, a failure does not affect other key-value pairs
                for (final value in entry.value) {
                  try {
                    // Check if the B+ tree is approaching capacity limit
                    final btree = _indexCache[cacheKey]!;
                    // Use smaller batch size to process each key's value collection
                    await btree.insert(entry.key, value);
                  } catch (e) {
                    batchHadErrors = true;
                    // Capture error and record, but do not interrupt the process
                    Logger.warn(
                        'Failed to update memory index cache: ${e.toString().substring(0, min(100, e.toString().length))}... key=${entry.key}, value=$value',
                        label: 'IndexManager._writeIndexToFile');

                    // If it is an index overflow error, consider rebuilding the memory cache
                    if (e.toString().contains('out of range') ||
                        e.toString().contains('RangeError')) {
                      // Remove the index from the cache, it will be reloaded from the file next time
                      _indexCache.remove(cacheKey);
                      _indexFullyCached.remove(cacheKey);
                      Logger.info(
                          'Detected index overflow, removed from cache: $tableName.$indexName',
                          label: 'IndexManager._writeIndexToFile');
                      break; // Do not process remaining values
                    }
                  }
                }

                // If the batch has errors and the index cache has been removed, do not continue processing
                if (batchHadErrors && !_indexCache.containsKey(cacheKey)) {
                  break;
                }
              }

              // If there are errors and the index cache has been removed, do not continue processing
              if (batchHadErrors && !_indexCache.containsKey(cacheKey)) {
                break;
              }

              // Slight delay between batches to avoid blocking, especially when processing large data
              if (i + memCacheBatchSize < entryList.length) {
                await Future.delayed(const Duration(milliseconds: 1));
              }
            }
          } catch (e) {
            // Capture errors in the overall processing, ensure that even if an error occurs, the process will not be interrupted
            Logger.error('Error during index cache update process: $e',
                label: 'IndexManager._writeIndexToFile');
          }
        }
      } catch (e, stack) {
        Logger.error('Failed to process B+ tree: $e\n$stack',
            label: 'IndexManager._writeIndexToFile');
        rethrow;
      }
    } catch (e, stack) {
      Logger.error('Failed to write index to file: $e\n$stack',
          label: 'IndexManager._writeIndexToFile');
      rethrow;
    } finally {
      // Release lock resource, whether the operation succeeds or fails
      _dataStore.lockManager?.releaseExclusiveLock(lockResource, operationId);
    }
  }

  /// Verify content checksum
  bool _verifyChecksum(String content, String checksum) {
    if (checksum.isEmpty) return true; // Empty checksum is considered valid
    final calculatedChecksum = _calculateChecksum(content);
    return calculatedChecksum == checksum;
  }

  /// Calculate content checksum
  String _calculateChecksum(String content) {
    // Use simple hash value as checksum
    final hash = content.hashCode;
    return hash.toRadixString(16).padLeft(8, '0');
  }

  /// update index
  Future<void> updateIndexes(
    String tableName,
    Map<String, dynamic> record,
    StoreIndex pointer,
  ) async {
    try {
      // Get table structure
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
        return;
      }
      final primaryKey = schema.primaryKey;
      final primaryValue = record[primaryKey];

      if (primaryValue == null) {
        Logger.error('Record has no primary key value',
            label: 'IndexManager.updateIndexes');
        return;
      }

      final recordId = pointer.toString();

      // Record processed field indexes to avoid duplicate creation
      final Set<String> processedFieldIndexes = {};

      // 1. Update primary key index
      final pkIndexName = 'pk_$tableName';
      await _addToInsertBuffer(tableName, pkIndexName, primaryValue, recordId);
      processedFieldIndexes.add(primaryKey);

      // 2. Update normal indexes and unique indexes
      for (final index in schema.indexes) {
        final indexName = index.actualIndexName;
        final isUnique = index.unique;

        // Ensure special handling for unique indexes
        if (isUnique) {
          // For unique indexes, possible special handling
          final meta = await _getIndexMeta(tableName, indexName);
          if (meta != null && !meta.isUnique) {
            // If the index is defined as unique but the metadata is not set, update the metadata
            final updatedMeta = IndexMeta(
              version: meta.version,
              name: indexName,
              tableName: tableName,
              fields: index.fields,
              isUnique: true,
              bTreeOrder: meta.bTreeOrder,
              partitions: meta.partitions,
              timestamps: meta.timestamps,
            );

            // Update index metadata
            final metaPath = await _dataStore.pathManager
                .getIndexMetaPath(tableName, indexName);
            await _dataStore.storage
                .writeAsString(metaPath, jsonEncode(updatedMeta.toJson()));

            // Update cache
            final cacheKey = _getIndexCacheKey(tableName, indexName);
            _indexMetaCache[cacheKey] = updatedMeta;

            // If the index is in the cache, ensure the unique flag is correct
            if (_indexCache.containsKey(cacheKey)) {
              final index = _indexCache[cacheKey]!;
              if (!index.isUnique) {
                // Re-create the index with the unique flag
                _indexCache[cacheKey] =
                    BPlusTree(order: meta.bTreeOrder, isUnique: true);
              }
            }
          }
        }

        if (index.fields.length == 1) {
          // Single field index
          final fieldName = index.fields[0];
          final fieldValue = record[fieldName];

          if (fieldValue != null) {
            await _addToInsertBuffer(
                tableName, indexName, fieldValue, recordId);

            // Record processed field indexes
            processedFieldIndexes.add(fieldName);
          }
        } else {
          // Composite index
          final compositeKey = _createIndexKey(record, index.fields);
          if (compositeKey != null) {
            await _addToInsertBuffer(
                tableName, indexName, compositeKey, recordId);

            // Record processed composite index fields
            for (final field in index.fields) {
              processedFieldIndexes.add(field);
            }
          }
        }
      }

      // 3. Handle the case where a normal field is set to unique=true but no index is created
      for (final field in schema.fields) {
        // Check if the field is set to unique=true
        if (field.unique) {
          // Skip if the field has been processed or is the primary key
          if (processedFieldIndexes.contains(field.name) ||
              field.name == primaryKey) {
            continue;
          }

          // Check if there is an explicit index (for safety)
          bool hasExplicitIndex = schema.indexes.any((index) =>
              index.fields.length == 1 && index.fields.first == field.name);

          // If there is no explicit index, create an auto-generated unique index
          if (!hasExplicitIndex) {
            final fieldValue = record[field.name];
            if (fieldValue != null) {
              // Build unique index name
              final uniqueIndexName = 'uniq_${field.name}';

              // Automatically create index metadata (if not exists)
              IndexMeta? meta = await _getIndexMeta(tableName, uniqueIndexName);
              if (meta == null) {
                meta = IndexMeta(
                  version: 1,
                  name: uniqueIndexName,
                  tableName: tableName,
                  fields: [field.name],
                  isUnique: true,
                  bTreeOrder: _dataStore.config.bTreeOrder,
                  partitions: [],
                  timestamps: Timestamps(
                    created: DateTime.now(),
                    modified: DateTime.now(),
                  ),
                );

                // Write index metadata
                final metaPath = await _dataStore.pathManager
                    .getIndexMetaPath(tableName, uniqueIndexName);
                await _dataStore.storage
                    .writeAsString(metaPath, jsonEncode(meta.toJson()));

                // Update cache
                final cacheKey = _getIndexCacheKey(tableName, uniqueIndexName);
                _indexMetaCache[cacheKey] = meta;

                Logger.debug(
                  'Auto-created unique index for field ${field.name}: $uniqueIndexName',
                  label: 'IndexManager.updateIndexes',
                );
              }

              // Update unique index
              await _addToInsertBuffer(
                  tableName, uniqueIndexName, fieldValue, recordId);
            }
          }
        }
      }
    } catch (e, stack) {
      Logger.error('Failed to update indexes: $e\n$stack',
          label: 'IndexManager.updateIndexes');
    }
  }

  /// Create index key
  dynamic _createIndexKey(Map<String, dynamic> record, List<String> fields) {
    if (fields.isEmpty) return null;

    // Single field index
    if (fields.length == 1) {
      return record[fields[0]];
    }

    // Composite index - combine field values
    final keyParts = <String>[];
    for (final field in fields) {
      final value = record[field];
      if (value == null) return null; // Return null if any field is null
      keyParts.add(value.toString());
    }

    return keyParts.join(':');
  }

  /// force execute all update index
  Future<void> flushIndexes() async {
    await _processIndexWriteBuffer();
  }

  /// create primary index
  Future<void> createPrimaryIndex(String tableName, String primaryKey) async {
    try {
      final indexName = 'pk_$tableName';

      // Check if the index exists
      final meta = await _getIndexMeta(tableName, indexName);
      if (meta != null) {
        Logger.debug('Primary key index already exists: $indexName',
            label: 'IndexManager.createPrimaryIndex');
        return;
      }

      // Create index metadata
      final newMeta = IndexMeta(
        version: 1,
        name: indexName,
        tableName: tableName,
        fields: [primaryKey],
        isUnique: true,
        bTreeOrder: _dataStore.config.bTreeOrder,
        partitions: [],
        timestamps: Timestamps(
          created: DateTime.now(),
          modified: DateTime.now(),
        ),
      );

      // Write index metadata
      final metaPath =
          await _dataStore.pathManager.getIndexMetaPath(tableName, indexName);
      await _dataStore.storage
          .writeAsString(metaPath, jsonEncode(newMeta.toJson()));

      // Update cache
      final cacheKey = _getIndexCacheKey(tableName, indexName);
      _indexMetaCache[cacheKey] = newMeta;

      // Scan table data to create index
      // TODO
    } catch (e) {
      Logger.error('Failed to create primary key index: $e',
          label: 'IndexManager.createPrimaryIndex');
      rethrow;
    }
  }

  /// create index
  Future<void> createIndex(String tableName, IndexSchema schema) async {
    try {
      final indexName = schema.actualIndexName;

      // Check if the index exists
      final meta = await _getIndexMeta(tableName, indexName);
      if (meta != null) {
        Logger.debug('Index already exists: $indexName',
            label: 'IndexManager.createIndex');
        return;
      }

      // get table structure to check if a redundant primary key index is created
      final tableSchema = await _dataStore.getTableSchema(tableName);
      if (tableSchema != null) {
        final primaryKeyName = tableSchema.primaryKey;
        // check if a redundant primary key index is created
        if (schema.fields.length == 1 &&
            schema.fields.first == primaryKeyName &&
            indexName != 'pk_$tableName') {
          Logger.warn(
            'Skipping creation of redundant primary key index: $indexName, primary key "$primaryKeyName" is automatically indexed as pk_$tableName',
            label: 'IndexManager.createIndex',
          );
          return; // skip creation of redundant primary key index
        }

        // Check if this index would duplicate an auto-created unique field index
        if (schema.fields.length == 1 && schema.unique) {
          final fieldName = schema.fields[0];
          final autoUniqueIndexName = 'uniq_$fieldName';

          // Check if the auto-created unique index exists
          final autoIndexMeta =
              await _getIndexMeta(tableName, autoUniqueIndexName);

          if (autoIndexMeta != null && indexName != autoUniqueIndexName) {
            Logger.warn(
              'Detected redundant unique index creation: $indexName would duplicate the auto-created unique index "$autoUniqueIndexName". Removing auto-created index and proceeding with explicit index.',
              label: 'IndexManager.createIndex',
            );

            // Remove the auto-created unique index before creating the explicit one
            await removeIndex(tableName, indexName: autoUniqueIndexName);
          }
        }
      }

      // Create index metadata
      final newMeta = IndexMeta(
        version: 1,
        name: indexName,
        tableName: tableName,
        fields: schema.fields,
        isUnique: schema.unique,
        bTreeOrder: _dataStore.config.bTreeOrder,
        partitions: [],
        timestamps: Timestamps(
          created: DateTime.now(),
          modified: DateTime.now(),
        ),
      );

      // Write index metadata
      final metaPath =
          await _dataStore.pathManager.getIndexMetaPath(tableName, indexName);
      await _dataStore.storage
          .writeAsString(metaPath, jsonEncode(newMeta.toJson()));

      // Update cache
      final cacheKey = _getIndexCacheKey(tableName, indexName);
      _indexMetaCache[cacheKey] = newMeta;

      // Scan table data to create index data to create index
      //  TODO
    } catch (e) {
      Logger.error('Failed to create index: $e',
          label: 'IndexManager.createIndex');
      rethrow;
    }
  }

  /// Check if running in a WASM environment
  static bool get isWasmPlatform {
    try {
      // In Dart 3 with WASM support, you can detect WASM with this:
      return const bool.fromEnvironment('dart.library.wasm',
          defaultValue: false);
    } catch (e) {
      return false;
    }
  }

  /// Delete single record from all indexes
  /// @param tableName Table name
  /// @param record Record to delete
  /// Note: This method requires fetching the StoreIndex associated with the primaryKey
  Future<void> deleteFromIndexes(
    String tableName,
    Map<String, dynamic> record,
  ) async {
    try {
      // Get table structure
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
        return;
      }
      final primaryKey = schema.primaryKey;
      final primaryKeyValue = record[primaryKey];

      if (primaryKeyValue == null) {
        Logger.error('Record has no primary key value',
            label: 'IndexManager.deleteFromIndexes');
        return;
      }

      // Get the StoreIndex by primary key value
      final storeIndex =
          await getStoreIndexByPrimaryKey(tableName, primaryKeyValue);
      if (storeIndex == null) {
        return;
      }

      final storeIndexStr = storeIndex.toString();

      // 1. Delete from primary key index
      final pkIndexName = 'pk_$tableName';
      await addToDeleteBuffer(
          tableName, pkIndexName, primaryKeyValue, storeIndexStr);

      // 2. Delete from normal indexes and unique indexes
      for (final index in schema.indexes) {
        final indexName = index.actualIndexName;

        if (index.fields.length == 1) {
          // Single field index
          final fieldName = index.fields[0];
          final fieldValue = record[fieldName];

          if (fieldValue != null) {
            await addToDeleteBuffer(
                tableName, indexName, fieldValue, storeIndexStr);
          }
        } else {
          // Composite index
          final compositeKey = _createIndexKey(record, index.fields);
          if (compositeKey != null) {
            await addToDeleteBuffer(
                tableName, indexName, compositeKey, storeIndexStr);
          }
        }
      }

      // 3. Handle special case for unique fields
      for (final field in schema.fields) {
        // Check if the field is set to unique=true
        if (field.unique) {
          // Check if the field already has a dedicated index
          bool hasExplicitIndex = schema.indexes.any((index) =>
              index.fields.length == 1 && index.fields.first == field.name);

          // If there is no explicit index, we need to remove from the auto-created unique index
          if (!hasExplicitIndex && field.name != primaryKey) {
            final fieldValue = record[field.name];
            if (fieldValue != null) {
              // Build unique index name
              final uniqueIndexName = 'uniq_${field.name}';
              await addToDeleteBuffer(
                  tableName, uniqueIndexName, fieldValue, storeIndexStr);
            }
          }
        }
      }
    } catch (e) {
      Logger.error('Failed to delete record from indexes: $e',
          label: 'IndexManager.deleteFromIndexes');
    }
  }

  /// reset all indexes
  Future<void> resetIndexes(String tableName) async {
    try {
      // Get table structure
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
        return;
      }

      // Clear index data
      final indexesToReset = <String>[];

      // 1. Add primary key index
      indexesToReset.add('pk_$tableName');

      // 2. Add other indexes
      for (final index in schema.indexes) {
        indexesToReset.add(index.actualIndexName);
      }

      for (final field in schema.fields) {
        // Check if the field is set to unique=true
        if (field.unique) {
          // If there is no explicit index, we need to remove from the auto-created unique index
          if (!indexesToReset.contains('uniq_${field.name}')) {
            indexesToReset.add('uniq_${field.name}');
          }
        }
      }

      // Clear index data
      for (final indexName in indexesToReset) {
        // Clear write buffer
        final cacheKey = _getIndexCacheKey(tableName, indexName);
        _writeBuffer.remove(cacheKey);
        _indexCache.remove(cacheKey);
        _indexFullyCached.remove(cacheKey);
        _deleteBuffer.remove(cacheKey);

        // Delete index file
        final meta = await _getIndexMeta(tableName, indexName);
        if (meta != null) {
          for (final partition in meta.partitions) {
            final partitionPath = await _dataStore.pathManager
                .getIndexPartitionPath(tableName, indexName, partition.index);
            await _dataStore.storage.deleteFile(partitionPath);
          }

          // Update index metadata
          final updatedMeta = meta.copyWith(
            partitions: [],
            timestamps: Timestamps(
              created: meta.timestamps.created,
              modified: DateTime.now(),
            ),
          );

          // Write updated index metadata
          final metaPath = await _dataStore.pathManager
              .getIndexMetaPath(tableName, indexName);
          await _dataStore.storage
              .writeAsString(metaPath, jsonEncode(updatedMeta.toJson()));

          // Update cache
          _indexMetaCache[cacheKey] = updatedMeta;
        }
      }

      // Rebuild indexes
      // 1. Rebuild primary key index
      await createPrimaryIndex(tableName, schema.primaryKey);

      // 2. Rebuild other indexes
      for (final indexSchema in schema.indexes) {
        await createIndex(tableName, indexSchema);
      }

      Logger.debug('Reset table indexes completed: $tableName',
          label: 'IndexManager.resetIndexes');
    } catch (e) {
      Logger.error('Failed to reset table indexes: $e',
          label: 'IndexManager.resetIndexes');
      rethrow;
    }
  }

  /// batch update indexes
  Future<void> batchUpdateIndexes(
    String tableName,
    List<Map<String, dynamic>> records,
  ) async {
    try {
      // Get table structure
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
        return;
      }
      final primaryKey = schema.primaryKey;

      // Collect all indexes to be updated
      final indexUpdates = <String, Map<dynamic, Set<dynamic>>>{};

      // Initialize primary key index
      final pkIndexName = 'pk_$tableName';
      indexUpdates[pkIndexName] = {};

      // Initialize other indexes
      for (final index in schema.indexes) {
        indexUpdates[index.actualIndexName] = {};
      }

      // Process each record
      for (final record in records) {
        final primaryValue = record[primaryKey];
        if (primaryValue == null) continue;

        // Get record pointer
        final storeIndex =
            await getStoreIndexByPrimaryKey(tableName, primaryValue);
        if (storeIndex == null) continue;

        final recordId = storeIndex.toString();

        // Update primary key index
        if (!indexUpdates[pkIndexName]!.containsKey(primaryValue)) {
          indexUpdates[pkIndexName]![primaryValue] = {};
        }
        indexUpdates[pkIndexName]![primaryValue]!.add(recordId);

        // Update other indexes
        for (final index in schema.indexes) {
          final indexName = index.actualIndexName;

          if (index.fields.length == 1) {
            // Single field index
            final fieldName = index.fields[0];
            final fieldValue = record[fieldName];

            if (fieldValue != null) {
              if (!indexUpdates[indexName]!.containsKey(fieldValue)) {
                indexUpdates[indexName]![fieldValue] = {};
              }
              indexUpdates[indexName]![fieldValue]!.add(recordId);
            }
          } else {
            // Composite index
            final compositeKey = _createIndexKey(record, index.fields);
            if (compositeKey != null) {
              if (!indexUpdates[indexName]!.containsKey(compositeKey)) {
                indexUpdates[indexName]![compositeKey] = {};
              }
              indexUpdates[indexName]![compositeKey]!.add(recordId);
            }
          }
        }
      }

      // Batch update write buffer
      for (final entry in indexUpdates.entries) {
        final indexName = entry.key;
        final updates = entry.value;

        if (updates.isEmpty) continue;

        final cacheKey = _getIndexCacheKey(tableName, indexName);

        // Initialize write buffer
        if (!_writeBuffer.containsKey(cacheKey)) {
          _writeBuffer[cacheKey] = <String, IndexBufferEntry>{};
        }

        // Merge updates
        for (final keyEntry in updates.entries) {
          final indexKey = keyEntry.key;
          final recordIds = keyEntry.value;

          for (final recordId in recordIds) {
            final storeIndex = StoreIndex.fromString(recordId);
            if (storeIndex == null) {
              Logger.error('Invalid StoreIndex format: $recordId',
                  label: 'IndexManager.batchUpdateIndexes');
              continue;
            }

            // Generate unique key for buffer entry
            final entryUniqueKey =
                IndexBufferEntry.createUniqueKey(indexKey, recordId);

            // Create IndexBufferEntry for insertion
            final bufferEntry = IndexBufferEntry.forInsert(
              indexKey: indexKey,
              recordPointer: storeIndex,
              timestamp: DateTime.now(),
            );

            // Add to buffer
            _writeBuffer[cacheKey]![entryUniqueKey] = bufferEntry;
          }
        }
        _indexLastWriteTime[cacheKey] = DateTime.now();

        // Update memory cache
        if (_indexCache.containsKey(cacheKey)) {
          final btree = _indexCache[cacheKey]!;

          for (final keyEntry in updates.entries) {
            final key = keyEntry.key;
            final values = keyEntry.value;

            for (final value in values) {
              await btree.insert(key, value);
            }
          }
        }
      }

      Logger.debug(
          'Batch update indexes completed: $tableName, ${records.length} records',
          label: 'IndexManager.batchUpdateIndexes');
    } catch (e) {
      Logger.error('Failed to batch update indexes: $e',
          label: 'IndexManager.batchUpdateIndexes');
    }
  }

  /// Check unique constraints
  Future<bool> checkUniqueConstraints(
      String tableName, Map<String, dynamic> data,
      {bool isUpdate = false}) async {
    try {
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
        return false;
      }
      final primaryKey = schema.primaryKey;
      final primaryValue = data[primaryKey];

      // 1. Check primary key uniqueness using primary index
      if (!isUpdate) {
        // Only check primary key uniqueness when adding records
        final pkIndex = await getIndex(tableName, 'pk_$tableName');
        if (pkIndex != null) {
          final existingIds = await pkIndex.search(primaryValue);
          if (existingIds.isNotEmpty) {
            Logger.warn('Primary key duplicate: $primaryValue',
                label: 'IndexManager.checkUniqueConstraints');
            return false;
          }
        } else {
          // Index is not available, fallback to querying write buffer
          final pendingData =
              _dataStore.tableDataManager.writeBuffer[tableName] ?? {};
          for (var record in pendingData.entries) {
            if (record.value.data[primaryKey] == primaryValue) {
              Logger.warn('Primary key duplicate in write queue: $primaryValue',
                  label: 'IndexManager.checkUniqueConstraints');
              return false;
            }
          }
        }
      }

      // 2. Check unique field constraints using indexes
      for (var field in schema.fields) {
        if (field.unique && field.name != primaryKey) {
          final value = data[field.name];
          if (value != null) {
            final tempSchema = IndexSchema(fields: [field.name], unique: true);
            final indexName = tempSchema.actualIndexName;

            final btIndex = await getIndex(tableName, indexName);
            if (btIndex != null) {
              final results = await btIndex.search(value);
              // For update operations, exclude the current record itself
              if (results.isNotEmpty &&
                  (!isUpdate || !results.contains(primaryValue.toString()))) {
                Logger.warn(
                    'Unique field constraint violation: ${field.name} = $value',
                    label: 'IndexManager.checkUniqueConstraints');
                return false;
              }
              // Index check passed, continue to the next field
              continue;
            }

            // Check if the same value exists in the write buffer
            final pendingData =
                _dataStore.tableDataManager.writeBuffer[tableName] ?? {};
            for (var record in pendingData.entries) {
              if (record.value.data[field.name] == value &&
                  (!isUpdate ||
                      record.value.data[primaryKey] != primaryValue)) {
                Logger.warn(
                    'Unique field constraint violation in write queue: ${field.name} = $value',
                    label: 'IndexManager.checkUniqueConstraints');
                return false;
              }
            }

            // Check if the table is fully cached, if so, check directly from cache
            if (await _dataStore.dataCacheManager
                .isTableFullyCached(tableName)) {
              final cachedRecords =
                  _dataStore.dataCacheManager.getEntireTable(tableName);
              if (cachedRecords != null) {
                for (var record in cachedRecords) {
                  if (record[field.name] == value &&
                      (!isUpdate || record[primaryKey] != primaryValue)) {
                    Logger.warn(
                        'Unique field constraint violation in cache: ${field.name} = $value',
                        label: 'IndexManager.checkUniqueConstraints');
                    return false;
                  }
                }
              }
              // No conflict in cache, return validation passed
              continue;
            }

            // If there is no full cache or the cache is empty, check existing records
            await for (var record
                in _dataStore.tableDataManager.streamRecords(tableName)) {
              if (record[field.name] == value &&
                  (!isUpdate || record[primaryKey] != primaryValue)) {
                Logger.warn(
                    'Unique field constraint violation: ${field.name} = $value',
                    label: 'IndexManager.checkUniqueConstraints');
                return false;
              }
            }
          }
        }
      }

      // 3. Check unique index
      for (var index in schema.indexes) {
        if (!index.unique) continue;
        // For composite indexes, need to construct index key value
        final indexKey = _createIndexKey(data, index.fields);
        if (indexKey == null) continue;

        // Get index name
        final indexName = index.actualIndexName;
        final btIndex = await getIndex(tableName, indexName);

        if (btIndex != null) {
          final results = await btIndex.search(indexKey);
          if (results.isNotEmpty &&
              (!isUpdate || !results.contains(primaryValue.toString()))) {
            Logger.warn(
                'Unique index constraint violation: ${index.fields.join("+")} = $indexKey',
                label: 'IndexManager.checkUniqueConstraints');
            return false;
          }
        }

        // Check write buffer first
        final pendingData =
            _dataStore.tableDataManager.writeBuffer[tableName] ?? {};
        for (var record in pendingData.entries) {
          final recordIndexKey =
              _createIndexKey(record.value.data, index.fields);
          if (recordIndexKey == indexKey &&
              (!isUpdate || record.value.data[primaryKey] != primaryValue)) {
            Logger.warn(
                'Unique index constraint violation in write queue: ${index.fields.join("+")} = $indexKey',
                label: 'IndexManager.checkUniqueConstraints');
            return false;
          }
        }

        // Check if the table is fully cached, if so, check directly from cache
        if (await _dataStore.dataCacheManager.isTableFullyCached(tableName)) {
          final cachedRecords =
              _dataStore.dataCacheManager.getEntireTable(tableName);
          if (cachedRecords != null) {
            for (var record in cachedRecords) {
              final recordIndexKey = _createIndexKey(record, index.fields);
              if (recordIndexKey == indexKey &&
                  (!isUpdate || record[primaryKey] != primaryValue)) {
                Logger.warn(
                    'Unique index constraint violation in cache: ${index.fields.join("+")} = $indexKey',
                    label: 'IndexManager.checkUniqueConstraints');
                return false;
              }
            }
          }
          return true;
        }

        // If there is no full cache or the cache is empty, scan the file
        await for (var record
            in _dataStore.tableDataManager.streamRecords(tableName)) {
          final recordIndexKey = _createIndexKey(record, index.fields);
          if (recordIndexKey == indexKey &&
              (!isUpdate || record[primaryKey] != primaryValue)) {
            Logger.warn(
                'Unique index constraint violation: ${index.fields.join("+")} = $indexKey',
                label: 'IndexManager.checkUniqueConstraints');
            return false;
          }
        }
      }

      return true;
    } catch (e) {
      Logger.error(
        'Failed to check unique constraints: $e',
        label: 'IndexManager.checkUniqueConstraints',
      );
      return false;
    }
  }

  /// handle Space path changed
  Future<void> onSpacePathChanged() async {
    // clear index cache
    _indexCache.clear();
    _indexMetaCache.clear();
    _indexFullyCached.clear();
    _indexAccessWeights.clear();

    // handle write buffer, only keep global table index
    final keysToCheck = <String>[..._writeBuffer.keys];
    final globalKeysToKeep = <String>[];

    // check each index key, determine which is global table
    for (final key in keysToCheck) {
      try {
        // extract table name from index key (format: tableName:indexName or tableName_indexName)
        final parts = key.split(':');
        final tableName = parts.length > 1 ? parts[0] : key.split('_')[0];

        // check if table is global table
        if (await _dataStore.schemaManager?.isTableGlobal(tableName) == true) {
          globalKeysToKeep.add(key);
        }
      } catch (e) {
        Logger.error('Error checking if index is global: $e',
            label: 'IndexManager.onSpacePathChanged');
      }
    }

    // only keep global table write buffer
    _writeBuffer.removeWhere((key, _) => !globalKeysToKeep.contains(key));

    // same as above, handle delete buffer
    final deleteKeysToCheck = <String>[..._deleteBuffer.keys];
    final globalDeleteKeysToKeep = <String>[];

    for (final key in deleteKeysToCheck) {
      try {
        final parts = key.split(':');
        final tableName = parts.length > 1 ? parts[0] : key.split('_')[0];
        if (await _dataStore.schemaManager?.isTableGlobal(tableName) == true) {
          globalDeleteKeysToKeep.add(key);
        }
      } catch (e) {
        Logger.error('Error checking if delete index is global: $e',
            label: 'IndexManager.onSpacePathChanged');
      }
    }

    _deleteBuffer
        .removeWhere((key, _) => !globalDeleteKeysToKeep.contains(key));

    // clear other related caches
    _indexWriting.removeWhere((key, _) => !globalKeysToKeep.contains(key));
    _indexLastWriteTime
        .removeWhere((key, _) => !globalKeysToKeep.contains(key));
  }

  /// get total size of all indexes
  Future<int> getTotalIndexSize() async {
    int totalSize = 0;

    try {
      // Get index size from cached metadata
      for (final meta in _indexMetaCache.values) {
        for (final partition in meta.partitions) {
          totalSize += partition.fileSizeInBytes;
        }
      }

      // If cache is empty, scan from file system
      if (totalSize == 0) {
        final schemaList =
            await _dataStore.schemaManager?.getAllTableSchemas() ?? [];

        for (final schemaData in schemaList) {
          try {
            final schema = Map<String, dynamic>.from(schemaData);
            final tableName = schema['name'] as String?;

            if (tableName != null) {
              final indexDirPath =
                  await _dataStore.pathManager.getIndexDirPath(tableName);

              if (await _dataStore.storage.existsDirectory(indexDirPath)) {
                final files =
                    await _dataStore.storage.listDirectory(indexDirPath);

                for (final filePath in files) {
                  if (filePath.endsWith('.${FileType.idx.ext}')) {
                    final size = await _dataStore.storage.getFileSize(filePath);
                    totalSize += size;
                  }
                }
              }
            }
          } catch (e) {
            // Skip invalid schema
            Logger.error('Failed to process table schema: $e',
                label: 'IndexManager.getTotalIndexSize');
          }
        }
      }

      return totalSize;
    } catch (e) {
      Logger.error('Failed to get total index size: $e',
          label: 'IndexManager.getTotalIndexSize');
      return 0;
    }
  }

  /// Invalidate index cache
  void invalidateCache(String tableName, String indexName) {
    final cacheKey = _getIndexCacheKey(tableName, indexName);
    _indexCache.remove(cacheKey);
    _indexMetaCache.remove(cacheKey);
    _indexFullyCached.remove(cacheKey);

    Logger.debug('Index cache invalidated: $tableName.$indexName',
        label: 'IndexManager.invalidateCache');
  }

  /// Get record storage index by primary key
  Future<StoreIndex?> getStoreIndexByPrimaryKey(
    String tableName,
    dynamic primaryKeyValue,
  ) async {
    try {
      final pkIndexName = 'pk_$tableName';
      final pkIndex = await getIndex(tableName, pkIndexName);
      if (pkIndex == null) return null;

      final results = await pkIndex.search(primaryKeyValue);
      if (results.isEmpty) return null;

      return StoreIndex.fromString(results.first.toString());
    } catch (e) {
      Logger.error(
        'Failed to get record storage index by primary key: $e',
        label: 'IndexManager.getStoreIndexByPrimaryKey',
      );
      return null;
    }
  }

  /// Process index partitions one by one with callback
  /// @param tableName Table name
  /// @param indexName Index name
  /// @param processor Function to process each partition, returns true to continue processing, false to stop processing more partitions
  /// @param updateMetadata Whether to update metadata after processing
  Future<bool> processIndexPartitions(
    String tableName,
    String indexName, {
    required Future<bool> Function(
            String partitionPath, IndexPartitionMeta meta, BPlusTree btree)
        processor,
    bool updateMetadata = true,
  }) async {
    try {
      // Get index metadata
      final meta = await _getIndexMeta(tableName, indexName);
      if (meta == null) {
        Logger.error('Index metadata not found: $tableName.$indexName',
            label: 'IndexManager.processIndexPartitions');
        return false;
      }

      // If no partitions, nothing to process
      if (meta.partitions.isEmpty) {
        return true;
      }

      // Track modified partitions for metadata update
      final modifiedPartitions = <IndexPartitionMeta>[];
      bool anyPartitionProcessed = false;

      // Process each partition one by one
      for (final partition in meta.partitions) {
        final partitionPath = await _dataStore.pathManager
            .getIndexPartitionPath(tableName, indexName, partition.index);

        if (!await _dataStore.storage.existsFile(partitionPath)) {
          Logger.warn('Partition file does not exist: $partitionPath',
              label: 'IndexManager.processIndexPartitions');
          continue;
        }

        // Read partition content
        final content =
            await _dataStore.storage.readAsString(partitionPath) ?? '';
        if (content.isEmpty) {
          continue;
        }

        // Initialize B+ tree from file content
        final btree = BPlusTree.fromString(
          content,
          order: meta.bTreeOrder,
          isUnique: meta.isUnique,
        );

        // Process this partition using the callback
        final shouldContinue = await processor(partitionPath, partition, btree);
        anyPartitionProcessed = true;

        // Serialize modified B+ tree back to file if needed
        final newContent = btree.toStringHandle();
        if (newContent != content) {
          // Write back to file
          await _dataStore.storage.writeAsString(partitionPath, newContent);

          // Calculate new checksum
          final checksum = _calculateChecksum(newContent);

          // Create updated partition metadata
          final updatedPartition = partition.copyWith(
            fileSizeInBytes: newContent.length,
            bTreeSize: newContent.length,
            entries: btree.count(),
            timestamps: Timestamps(
              created: partition.timestamps.created,
              modified: DateTime.now(),
            ),
            checksum: checksum,
          );

          // Add to modified partitions list
          modifiedPartitions.add(updatedPartition);
        }

        // If callback returns false, stop processing more partitions
        if (!shouldContinue) {
          break;
        }
      }

      // Update index metadata if needed
      if (updateMetadata && modifiedPartitions.isNotEmpty) {
        // Create updated partitions list
        final updatedPartitions = meta.partitions.map((p) {
          // Find if this partition was modified
          final modifiedPartition = modifiedPartitions.firstWhere(
            (mp) => mp.index == p.index,
            orElse: () => p,
          );
          return modifiedPartition;
        }).toList();

        // Create updated metadata
        final updatedMeta = meta.copyWith(
          partitions: updatedPartitions,
          timestamps: Timestamps(
            created: meta.timestamps.created,
            modified: DateTime.now(),
          ),
        );

        // Write updated metadata to file
        final metaPath =
            await _dataStore.pathManager.getIndexMetaPath(tableName, indexName);
        await _dataStore.storage
            .writeAsString(metaPath, jsonEncode(updatedMeta.toJson()));

        // Update metadata cache
        final cacheKey = _getIndexCacheKey(tableName, indexName);
        _indexMetaCache[cacheKey] = updatedMeta;

        // Clear index from memory cache to ensure it's reloaded with latest data next time
        if (_indexCache.containsKey(cacheKey)) {
          _indexCache.remove(cacheKey);
          _indexFullyCached.remove(cacheKey);
        }
      }

      return anyPartitionProcessed;
    } catch (e, stack) {
      Logger.error('Failed to process index partitions: $e\n$stack',
          label: 'IndexManager.processIndexPartitions');
      return false;
    }
  }

  /// Batch delete multiple records from all indexes
  /// @param tableName Table name
  /// @param records List of records to delete
  /// Note: For each record, this method fetches the StoreIndex associated with its primaryKey
  Future<void> batchDeleteFromIndexes(
    String tableName,
    List<Map<String, dynamic>> records,
  ) async {
    if (records.isEmpty) return;

    try {
      // Get table schema
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
        Logger.error('Table schema not found: $tableName',
            label: 'IndexManager.batchDeleteFromIndexes');
        return;
      }

      final primaryKey = schema.primaryKey;

      // Process each record and add to delete buffer
      for (final record in records) {
        final primaryKeyValue = record[primaryKey];
        if (primaryKeyValue == null) continue;

        // Get StoreIndex by primary key
        final storeIndex =
            await getStoreIndexByPrimaryKey(tableName, primaryKeyValue);
        if (storeIndex == null) continue;

        final storeIndexStr = storeIndex.toString();

        // 1. Delete from primary key index
        final pkIndexName = 'pk_$tableName';
        await addToDeleteBuffer(
            tableName, pkIndexName, primaryKeyValue, storeIndexStr);

        // 2. Delete from normal indexes and unique indexes
        for (final index in schema.indexes) {
          final indexName = index.actualIndexName;

          if (index.fields.length == 1) {
            // Single field index
            final fieldName = index.fields[0];
            final fieldValue = record[fieldName];

            if (fieldValue != null) {
              await addToDeleteBuffer(
                  tableName, indexName, fieldValue, storeIndexStr);
            }
          } else {
            // Composite index
            final compositeKey = _createIndexKey(record, index.fields);
            if (compositeKey != null) {
              await addToDeleteBuffer(
                  tableName, indexName, compositeKey, storeIndexStr);
            }
          }
        }

        // 3. Handle unique fields with auto-generated indexes
        for (final field in schema.fields) {
          if (field.unique && field.name != primaryKey) {
            // Check if the field already has a dedicated index
            bool hasExplicitIndex = schema.indexes.any((index) =>
                index.fields.length == 1 && index.fields.first == field.name);

            if (!hasExplicitIndex) {
              final fieldValue = record[field.name];
              if (fieldValue != null) {
                // Build unique index name
                final uniqueIndexName = 'uniq_${field.name}';
                await addToDeleteBuffer(
                    tableName, uniqueIndexName, fieldValue, storeIndexStr);
              }
            }
          }
        }
      }

      // Force buffer processing if the batch is large
      if (records.length > 1000) {
        await _processIndexWriteBuffer();
      }
    } catch (e, stack) {
      Logger.error('Failed to batch delete records from indexes: $e\n$stack',
          label: 'IndexManager.batchDeleteFromIndexes');
    }
  }

  /// Add index entry during migration
  /// @param tableName Table name
  /// @param indexName Index name
  /// @param value Index key value
  /// @param storeIndexStr String representation of StoreIndex pointer to the record
  Future<void> addIndexEntry(
    String tableName,
    String indexName,
    dynamic value,
    String storeIndexStr,
  ) async {
    try {
      // Add index entry using write buffer
      await _addToInsertBuffer(tableName, indexName, value, storeIndexStr);

      // Update index in memory (if loaded)
      final cacheKey = _getIndexCacheKey(tableName, indexName);
      if (_indexCache.containsKey(cacheKey)) {
        await _indexCache[cacheKey]!.insert(value, storeIndexStr);
      }
    } catch (e) {
      Logger.error(
        'Failed to add index entry: $e',
        label: 'IndexManager.addIndexEntry',
      );
      rethrow;
    }
  }

  /// Calculate the index value range, used for range queries of numeric indexes
  /// Supports different types of primary key values (int, bigInt, String, etc.)
  dynamic _calculateMinKey(List<dynamic> keys) {
    if (keys.isEmpty) return null;

    return keys.fold(keys.first, (min, key) {
      return ValueComparator.compare(key, min) < 0 ? key : min;
    });
  }

  /// Calculate the maximum key value
  dynamic _calculateMaxKey(List<dynamic> keys) {
    if (keys.isEmpty) return null;

    return keys.fold(keys.first, (max, key) {
      return ValueComparator.compare(key, max) > 0 ? key : max;
    });
  }

  /// Check if the primary key is an ordered type
  bool _isPrimaryKeyOrdered(TableSchema schema) {
    final pkConfig = schema.primaryKeyConfig;

    // If the isOrdered flag is explicitly set, return directly
    if (pkConfig.isOrdered != null) {
      return pkConfig.isOrdered!;
    }

    // Determine based on the primary key type
    switch (pkConfig.type) {
      case PrimaryKeyType.timestampBased:
      case PrimaryKeyType.datePrefixed:
      case PrimaryKeyType.shortCode:
      case PrimaryKeyType.sequential:
        // These types of primary keys are ordered
        return true;
      case PrimaryKeyType.none:
        // User-defined primary key, default认为无序
        return false;
    }
  }

  /// Set the closing state and wait for all write operations to complete
  Future<void> prepareForClose() async {
    if (_isClosing) return; // Avoid repeated calls

    _isClosing = true;

    // Disable fast processing mode when closing
    _disableFastProcessMode();

    // Get the current number of pending index entries
    final pendingEntries = _pendingEntriesCount;

    // If there are no pending writes, complete the Completer early
    if (_pendingWrites == 0) {
      if (!_allWritesCompleted.isCompleted) {
        _allWritesCompleted.complete();
      }
      return;
    }

    // Perform a flush operation once
    await flushIndexes();

    // If there are pending writes, wait for them to complete
    if (_pendingWrites > 0 && !_allWritesCompleted.isCompleted) {
      // Calculate the timeout based on the number of pending index entries
      // Base 60 seconds, add 60 seconds for each 10000 entries, up to 5 minutes
      int timeoutSeconds = 60 + (pendingEntries ~/ 10000) * 60;
      timeoutSeconds = timeoutSeconds.clamp(60, 300);

      try {
        // Set a timeout to prevent infinite waiting
        await _allWritesCompleted.future.timeout(
          Duration(seconds: timeoutSeconds),
          onTimeout: () {
            Logger.warn(
                'Waiting for index write operation timeout ($timeoutSeconds seconds), force close, remaining pending writes: $_pendingWrites',
                label: 'IndexManager.prepareForClose');
            if (!_allWritesCompleted.isCompleted) {
              _allWritesCompleted.complete();
            }
          },
        );
      } catch (e) {
        Logger.error('Error waiting for index write operation to complete: $e',
            label: 'IndexManager.prepareForClose');
        if (!_allWritesCompleted.isCompleted) {
          _allWritesCompleted.complete();
        }
      }
    }

    Logger.debug('Index manager close preparation completed',
        label: 'IndexManager.prepareForClose');
  }

  /// Add index entry to insert buffer
  /// Add index entry to insert buffer
  /// @param tableName Table name
  /// @param indexName Index name
  /// @param key Index key value
  /// @param storeIndexStr String representation of StoreIndex pointer to the record
  Future<void> _addToInsertBuffer(String tableName, String indexName,
      dynamic key, String storeIndexStr) async {
    try {
      final cacheKey = _getIndexCacheKey(tableName, indexName);

      // Parse StoreIndex from string
      final storeIndex = StoreIndex.fromString(storeIndexStr);
      if (storeIndex == null) {
        Logger.error('Invalid StoreIndex format: $storeIndexStr',
            label: 'IndexManager._addToInsertBuffer');
        return;
      }

      // Generate unique key for buffer entry
      final entryUniqueKey =
          IndexBufferEntry.createUniqueKey(key, storeIndexStr);

      // Check if the entry is in delete buffer - if so, cancel out the operations
      if (_deleteBuffer.containsKey(cacheKey) &&
          _deleteBuffer[cacheKey]!.containsKey(entryUniqueKey)) {
        // Entry is in delete buffer, remove it from there instead of adding to insert buffer
        _deleteBuffer[cacheKey]!.remove(entryUniqueKey);

        // Update last write time
        _indexLastWriteTime[cacheKey] = DateTime.now();

        return; // Operations cancel out, no need to add to insert buffer
      }

      // Initialize insert buffer for this table/index if not exists
      if (!_writeBuffer.containsKey(cacheKey)) {
        _writeBuffer[cacheKey] = <String, IndexBufferEntry>{};
      }

      // Create IndexBufferEntry for insertion
      final bufferEntry = IndexBufferEntry.forInsert(
        indexKey: key,
        recordPointer: storeIndex,
        timestamp: DateTime.now(),
      );

      // Add to buffer
      _writeBuffer[cacheKey]![entryUniqueKey] = bufferEntry;

      // Check buffer size, enable fast processing mode when buffer reaches threshold
      if (!_fastProcessEnabled &&
          _writeBuffer[cacheKey]!.length >= _fastProcessThreshold) {
        _enableFastProcessMode();
      }

      // Update index cache (if loaded)
      if (_indexCache.containsKey(cacheKey)) {
        try {
          await _indexCache[cacheKey]!.insert(key, storeIndexStr);
        } catch (e) {
          // Cache update error does not affect the main process
          Logger.warn('Failed to update memory cache: $e',
              label: 'IndexManager._addToInsertBuffer');
        }
      }

      // Record last write time
      _indexLastWriteTime[cacheKey] = DateTime.now();
    } catch (e, stack) {
      Logger.error('Failed to add index entry to insert buffer: $e\n$stack',
          label: 'IndexManager._addToInsertBuffer');
    }
  }

  /// Add index entry to delete buffer
  /// @param tableName Table name
  /// @param indexName Index name
  /// @param key Index key value
  /// @param storeIndexStr String representation of StoreIndex pointer to the record
  Future<void> addToDeleteBuffer(String tableName, String indexName,
      dynamic key, String storeIndexStr) async {
    try {
      final cacheKey = _getIndexCacheKey(tableName, indexName);

      // Parse StoreIndex from string
      final storeIndex = StoreIndex.fromString(storeIndexStr);
      if (storeIndex == null) {
        Logger.error('Invalid StoreIndex format: $storeIndexStr',
            label: 'IndexManager.addToDeleteBuffer');
        return;
      }

      // Generate unique key for buffer entry
      final entryUniqueKey =
          IndexBufferEntry.createUniqueKey(key, storeIndexStr);

      // Check if the entry is in insert buffer - if so, cancel out the operations
      if (_writeBuffer.containsKey(cacheKey) &&
          _writeBuffer[cacheKey]!.containsKey(entryUniqueKey)) {
        // Entry is in insert buffer, remove it from there instead of adding to delete buffer
        _writeBuffer[cacheKey]!.remove(entryUniqueKey);

        // Update last write time
        _indexLastWriteTime[cacheKey] = DateTime.now();

        // Also remove from memory cache if it exists
        if (_indexCache.containsKey(cacheKey)) {
          try {
            await _indexCache[cacheKey]!.delete(key, storeIndexStr);
          } catch (e) {
            // Ignore errors in memory cache update
          }
        }

        return; // Operations cancel out, no need to add to delete buffer
      }

      // Initialize delete buffer for this table/index if not exists
      if (!_deleteBuffer.containsKey(cacheKey)) {
        _deleteBuffer[cacheKey] = <String, IndexBufferEntry>{};
      }

      // Create IndexBufferEntry for deletion
      final bufferEntry = IndexBufferEntry.forDelete(
        indexKey: key,
        recordPointer: storeIndex,
        timestamp: DateTime.now(),
      );

      // Add to buffer
      _deleteBuffer[cacheKey]![entryUniqueKey] = bufferEntry;

      // Also remove from memory cache if it exists
      if (_indexCache.containsKey(cacheKey)) {
        try {
          await _indexCache[cacheKey]!.delete(key, storeIndexStr);
        } catch (e) {
          // Ignore errors in memory cache update
          Logger.warn('Failed to update memory cache for deletion: $e',
              label: 'IndexManager.addToDeleteBuffer');
        }
      }

      // Record last write time
      _indexLastWriteTime[cacheKey] = DateTime.now();
    } catch (e, stack) {
      Logger.error('Failed to add index entry to delete buffer: $e\n$stack',
          label: 'IndexManager.addToDeleteBuffer');
    }
  }

  /// Add index to table
  Future<void> addIndex(
    String tableName,
    IndexSchema index,
  ) async {
    try {
      // get table schema
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
        Logger.error('Failed to add index: table $tableName does not exist',
            label: 'IndexManager.addIndex');
        return;
      }

      // check if index already exists
      if (schema.indexes
          .any((i) => i.actualIndexName == index.actualIndexName)) {
        Logger.warn(
          'Index ${index.actualIndexName} already exists in table $tableName',
          label: 'IndexManager.addIndex',
        );
        return;
      }

      // validate index fields
      if (!schema.validateIndexFields(index)) {
        throw Exception('Index fields do not exist in table $tableName');
      }

      // create index file and build index
      await createIndex(tableName, index);

      // update table schema
      final newIndexes = [...schema.indexes, index];
      final newSchema = schema.copyWith(indexes: newIndexes);
      await _dataStore.updateTableSchema(tableName, newSchema);
    } catch (e) {
      Logger.error('Failed to add index: $e', label: 'IndexManager.addIndex');
      rethrow;
    }
  }

  /// modify index
  Future<void> modifyIndex(
    String tableName,
    String oldIndexName,
    IndexSchema newIndex,
  ) async {
    try {
      // 1. remove old index
      await removeIndex(tableName, indexName: oldIndexName);

      // 2. create new index
      await addIndex(tableName, newIndex);
    } catch (e) {
      Logger.error('Failed to modify index: $e',
          label: 'IndexManager.modifyIndex');
      rethrow;
    }
  }

  /// remove index from table
  /// @param tableName table name
  /// @param indexName index name
  /// @param fields field list (when indexName is not provided)
  Future<void> removeIndex(
    String tableName, {
    String? indexName,
    List<String>? fields,
  }) async {
    try {
      if (indexName == null && (fields == null || fields.isEmpty)) {
        throw ArgumentError('index name or field list is required');
      }

      // cannot remove primary key index
      if (indexName == 'pk_$tableName') {
        throw Exception('cannot remove primary key index');
      }

      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
        Logger.warn('table $tableName does not exist, cannot remove index',
            label: 'IndexManager.removeIndex');
        return;
      }

      // find matching index
      IndexSchema? targetIndex;

      // 1. if index name is provided, try to match by index name
      if (indexName != null) {
        // try to match by index name
        for (var index in schema.indexes) {
          if (index.indexName == indexName ||
              index.actualIndexName == indexName) {
            targetIndex = index;
            break;
          }
        }

        // if not found, try to match by index name generated by fields
        if (targetIndex == null) {
          // check if it is an auto-generated index name
          final autoGenPattern = RegExp(r'^' + tableName + r'_\w+');
          if (autoGenPattern.hasMatch(indexName)) {
            for (var index in schema.indexes) {
              if (index.actualIndexName == indexName) {
                targetIndex = index;
                break;
              }
            }
          }
        }
      }

      // 2. if fields list is provided, try to match by fields list
      if (targetIndex == null && fields != null && fields.isNotEmpty) {
        // sort fields list to ensure consistency
        final sortedFields = List<String>.from(fields)..sort();

        for (var index in schema.indexes) {
          // sort index fields
          final indexFields = List<String>.from(index.fields)..sort();

          // check if fields list matches
          if (_areFieldListsEqual(indexFields, sortedFields)) {
            targetIndex = index;
            break;
          }
        }
      }

      String? actualName;

      // if target index is found
      if (targetIndex != null) {
        actualName = targetIndex.actualIndexName;
      } else if (indexName != null) {
        // if index name is provided but no matching index is found, try to delete index file
        Logger.warn(
          'index $indexName not found, try to delete index file',
          label: 'IndexManager.removeIndex',
        );
        actualName = indexName;
      } else {
        // if only fields list is provided but no matching index is found, cannot continue
        Logger.warn(
          'no index found for fields [${fields!.join(", ")}]',
          label: 'IndexManager.removeIndex',
        );
        return;
      }

      // delete index file
      await _deleteIndexFiles(tableName, actualName);

      // if target index is found, remove it from table schema
      if (targetIndex != null) {
        final newIndexes =
            schema.indexes.where((i) => i != targetIndex).toList();
        final newSchema = schema.copyWith(indexes: newIndexes);

        // update table schema
        await _dataStore.updateTableSchema(tableName, newSchema);
      }
    } catch (e) {
      Logger.error('Failed to remove index: $e',
          label: 'IndexManager.removeIndex');
      rethrow;
    }
  }

  /// delete index file
  /// @param tableName table name
  /// @param indexName index name
  Future<void> _deleteIndexFiles(
    String tableName,
    String indexName,
  ) async {
    // create lock resource for index operation
    final lockResource = 'index:$tableName:$indexName';
    final operationId = 'delete_index_${DateTime.now().millisecondsSinceEpoch}';

    try {
      // get exclusive lock, ensure no other operation is accessing this index
      await _dataStore.lockManager
          ?.acquireExclusiveLock(lockResource, operationId);

      // clear memory cache
      invalidateCache(tableName, indexName);

      // clear write buffer
      final cacheKey = _getIndexCacheKey(tableName, indexName);
      _writeBuffer.remove(cacheKey);
      _deleteBuffer.remove(cacheKey);
      _indexWriting.remove(cacheKey);
      _indexLastWriteTime.remove(cacheKey);

      // get index directory path
      final indexDirPath =
          await _dataStore.pathManager.getIndexDirPath(tableName);
      final indexSubDirPath = pathJoin(indexDirPath, indexName);

      // if index specific subdirectory exists, delete the entire subdirectory
      if (await _dataStore.storage.existsDirectory(indexSubDirPath)) {
        await _dataStore.storage.deleteDirectory(indexSubDirPath);
      } else {
        // if not using new directory structure, need to find and delete partition files by meta file
        final meta = await _getIndexMeta(tableName, indexName);
        if (meta != null) {
          // delete all partition files
          for (final partition in meta.partitions) {
            try {
              final partitionPath = await _dataStore.pathManager
                  .getIndexPartitionPath(tableName, indexName, partition.index);

              if (await _dataStore.storage.existsFile(partitionPath)) {
                await _dataStore.storage.deleteFile(partitionPath);
              }
            } catch (e) {
              Logger.error('Failed to delete index partition file: $e',
                  label: 'IndexManager._deleteIndexFiles');
            }
          }
        }
      }

      // delete meta file
      final metaPath =
          await _dataStore.pathManager.getIndexMetaPath(tableName, indexName);
      if (await _dataStore.storage.existsFile(metaPath)) {
        await _dataStore.storage.deleteFile(metaPath);
      }
    } catch (e) {
      Logger.error('Failed to delete index file: $e',
          label: 'IndexManager._deleteIndexFiles');
      rethrow;
    } finally {
      // release exclusive lock
      _dataStore.lockManager?.releaseExclusiveLock(lockResource, operationId);
    }
  }

  /// compare two field lists (ignore order)
  bool _areFieldListsEqual(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    final setA = Set<String>.from(a);
    final setB = Set<String>.from(b);
    return setA.difference(setB).isEmpty;
  }
}
