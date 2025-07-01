import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../model/index_search.dart';
import 'compute_manager.dart';
import '../handler/logger.dart';
import '../handler/common.dart';
import '../handler/platform_handler.dart';
import '../handler/value_comparator.dart';
import '../model/file_info.dart';
import '../model/store_index.dart';
import '../model/table_schema.dart';
import '../model/index_entry.dart';
import 'crontab_manager.dart';
import 'b_plus_tree.dart';
import 'data_store_impl.dart';
import 'compute_tasks.dart';
import 'memory_manager.dart';
import '../handler/parallel_processor.dart';
import '../model/system_table.dart';
import '../query/query_condition.dart';

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

  // Current index metadata cache total size (bytes)
  int _currentIndexMetaCacheSize = 0;

  // Current index cache total size (bytes)
  int _currentIndexCacheSize = 0;

  // Index metadata size cache - cache the size of each index metadata to avoid repeated calculation
  final Map<String, int> _indexMetaSizeCache = {};

  // Index cache size cache - cache the size of each index to avoid repeated calculation
  final Map<String, int> _indexSizeCache = {};

  /// Get current index cache size in bytes
  int getCurrentIndexCacheSize() {
    return _currentIndexCacheSize;
  }

  /// Get current index metadata cache size in bytes
  int getCurrentIndexMetaCacheSize() {
    return _currentIndexMetaCacheSize;
  }

  // Whether the cron task has been initialized
  bool _cronInitialized = false;

  // Whether the database is closing
  bool _isClosing = false;

  // Number of asynchronous write operations being processed
  int _pendingWrites = 0;

  // index order last check time mapping (milliseconds timestamp)
  final Map<String, int> _lastOrderCheckTime = {};

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
    _registerMemoryCallbacks();
  }

  /// Register memory callback function
  void _registerMemoryCallbacks() {
    final memoryManager = _dataStore.memoryManager;
    if (memoryManager != null) {
      // Register index cache cleanup callback
      memoryManager.registerCacheEvictionCallback(
          CacheType.indexData, _cleanupIndexCache);

      // Register index metadata cache cleanup callback
      memoryManager.registerCacheEvictionCallback(
          CacheType.indexMeta, _cleanupIndexMetaCache);
    }
  }

  /// Clean up index cache by evicting entire indexes based on LRU.
  Future<void> _cleanupIndexCache() async {
    try {
      if (_indexCache.isEmpty) return;

      final memoryManager = _dataStore.memoryManager;
      if (memoryManager == null) return;

      // Determine the target size to bring usage down to 70% of the limit.
      final cacheLimit = memoryManager.getIndexCacheSize();
      final targetCacheSize = (cacheLimit * 0.7).toInt();

      if (_currentIndexCacheSize <= targetCacheSize) {
        return;
      }

      final bytesToEvict = _currentIndexCacheSize - targetCacheSize;
      int bytesEvicted = 0;

      // 1. Get all candidate indexes, sorted by last access time (LRU).
      // Sorting the list of indexes itself should be fast.
      final evictableIndexes = _indexAccessWeights.entries.toList()
        ..sort((a, b) {
          final lastAccessA =
              a.value['lastAccess'] as DateTime? ?? DateTime(1970);
          final lastAccessB =
              b.value['lastAccess'] as DateTime? ?? DateTime(1970);
          return lastAccessA.compareTo(lastAccessB); // Oldest first
        });

      final indexesToRemove = <String>[];
      int processedCount = 0;

      // 2. Identify which entire indexes to evict.
      for (final entry in evictableIndexes) {
        if (bytesEvicted >= bytesToEvict) break;

        final key = entry.key;
        final index = _indexCache[key];
        if (index != null) {
          final size = _indexSizeCache[key] ?? _estimateIndexSize(index);
          bytesEvicted += size;
          indexesToRemove.add(key);
        }

        // Yield to the event loop to prevent UI jank if there are many indexes.
        processedCount++;
        if (processedCount % 20 == 0) {
          await Future.delayed(Duration.zero);
        }
      }

      // 3. Perform the actual eviction.
      for (final key in indexesToRemove) {
        final index = _indexCache.remove(key);
        if (index != null) {
          final size = _indexSizeCache.remove(key) ?? 0;
          _currentIndexCacheSize -= size;
          _indexFullyCached.remove(key);
          _indexAccessWeights.remove(key);
        }

        // Yield again during removal if the list is very large.
        processedCount++;
        if (processedCount % 20 == 0) {
          await Future.delayed(Duration.zero);
        }
      }

      if (bytesEvicted > 0) {
        Logger.debug(
            'Cache eviction: evicted ${indexesToRemove.length} entire indexes (${(bytesEvicted / 1024).toStringAsFixed(2)} KB) to free up memory.',
            label: 'IndexManager._cleanupIndexCache');
      }
    } catch (e) {
      Logger.error('Failed to clean up index cache: $e',
          label: 'IndexManager._cleanupIndexCache');
    }
  }

  /// Clean up index metadata cache
  Future<void> _cleanupIndexMetaCache() async {
    try {
      if (_indexMetaCache.isEmpty) return;

      // Calculate the ratio to be cleared
      final metaCacheLimit =
          _dataStore.memoryManager?.getIndexMetaCacheSize() ?? 10000;

      // If the cache is less than the limit, no need to clean up
      if (_currentIndexMetaCacheSize < metaCacheLimit * 0.9) return;

      // Calculate target size (70% of the limit)
      final targetSize = (metaCacheLimit * 0.7).toInt();
      final needToRemoveBytes = _currentIndexMetaCacheSize - targetSize;

      if (needToRemoveBytes <= 0) return;

      // Optimization: use a bucket approach to avoid full sorting
      // We'll divide time into buckets (e.g., by hour) and process oldest buckets first
      final buckets = <int, List<String>>{};
      int removedSize = 0;

      // Critical indexes to preserve (primary key and unique indexes)
      final criticalIndexes = <String>{};

      // System tables to preserve
      final systemTables = <String>{};

      // Single pass to categorize entries into time buckets
      // Use epoch hours as bucket keys (rough time division)
      // Use a standard indexed for-loop for safety
      final metaCacheEntries = _indexMetaCache.entries.toList();
      for (int i = 0; i < metaCacheEntries.length; i++) {
        final entry = metaCacheEntries[i];
        final indexName = entry.key;
        final meta = entry.value;

        // Identify critical indexes to preserve (primary key and unique indexes)
        if (indexName.startsWith('pk_') || meta.isUnique) {
          criticalIndexes.add(indexName);
          continue; // Critical indexes are not put into eviction buckets
        }

        // Identify system tables to preserve
        if (SystemTable.isSystemTable(meta.tableName)) {
          systemTables.add(indexName);
          continue;
        }

        // Get last access time, convert to bucket
        final lastModified = meta.timestamps.modified;
        // Use hours since epoch as bucket key (coarse-grained time division)
        final bucketKey = lastModified.millisecondsSinceEpoch ~/ 3600000;

        // Add to appropriate bucket
        buckets.putIfAbsent(bucketKey, () => <String>[]).add(indexName);
        if (i % 500 == 0) {
          await Future.delayed(Duration.zero);
        }
      }

      // Process buckets from oldest to newest
      final sortedBuckets = buckets.keys.toList()..sort();

      for (final bucketKey in sortedBuckets) {
        final indexesInBucket = buckets[bucketKey]!;
        // Use a standard indexed for-loop for safety
        final indexesToProcess = indexesInBucket.toList();
        for (int i = 0; i < indexesToProcess.length; i++) {
          final indexName = indexesToProcess[i];
          // Skip if we've removed enough already
          if (removedSize >= needToRemoveBytes) break;

          // Remove this entry if not a system table or a critical index
          if (!systemTables.contains(indexName) &&
              !criticalIndexes.contains(indexName)) {
            final metaSize = _indexMetaSizeCache[indexName] ?? 0;
            _indexMetaCache.remove(indexName);
            _indexMetaSizeCache.remove(indexName);

            removedSize += metaSize;
          }
          if (i % 500 == 0) {
            await Future.delayed(Duration.zero);
          }
        }

        // If we've removed enough, stop processing more buckets
        if (removedSize >= needToRemoveBytes) break;
      }

      // Update current cache size
      _currentIndexMetaCacheSize -= removedSize;
    } catch (e) {
      Logger.error('Failed to clean up index metadata cache: $e',
          label: 'IndexManager._cleanupIndexMetaCache');
    }
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

      await _processBatchIndexWrites(keysWithEntries, totalEntries);

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

  /// Process delete entries - remove entries from the B+ tree in the file
  Future<void> _processDeleteEntries(String tableName, String indexName,
      Map<String, IndexBufferEntry> entriesToDelete) async {
    try {
      if (entriesToDelete.isEmpty) return;

      final indexMeta = await _getIndexMeta(tableName, indexName);
      if (indexMeta == null) return;

      final isUniqueIndex = indexName == 'pk_$tableName' ||
          indexMeta.isUnique ||
          indexName.startsWith('uniq_');

      // If the number of partitions is 0, there are no index files present
      if (indexMeta.partitions.isEmpty) return;

      // Create a mutable copy of the key list for concurrency security
      final keysToDelete = List<String>.from(entriesToDelete.keys);

      // A specific resource name for locking the keysToDelete list for this operation.
      final listLockResource = 'internal:keysToDelete:$tableName:$indexName';

      // Collect updated partition metadata
      final List<IndexPartitionMeta> updatedPartitions = [];

      final tasks = <Future<void> Function()>[];

      // Process each partition concurrently
      for (final partition in indexMeta.partitions) {
        tasks.add(() async {
          if (isUniqueIndex && keysToDelete.isEmpty) {
            return;
          }
          try {
            final localKeysToProcess = List<String>.from(keysToDelete);
            if (localKeysToProcess.isEmpty) return;

            final partitionPath = await _dataStore.pathManager
                .getIndexPartitionPath(tableName, indexName, partition.index);

            if (!await _dataStore.storage.existsFile(partitionPath)) {
              return;
            }

            final content =
                await _dataStore.storage.readAsString(partitionPath);
            if (content == null || content.isEmpty) {
              return;
            }

            final request = IndexDeleteRequest(
                content: content,
                checksum: partition.checksum,
                isUnique: isUniqueIndex,
                keysToProcess: localKeysToProcess,
                entriesToDelete: Map.fromEntries(entriesToDelete.entries
                    .where((e) => localKeysToProcess.contains(e.key))));

            // Run CPU-intensive operations in isolate
            // Only use isolate if the content is large enough to justify the overhead
            final useIsolate =
                content.length > 500 * 1024 || localKeysToProcess.length > 1000;
            final result = await ComputeManager.run(processIndexDelete, request,
                useIsolate: useIsolate);

            // Process result back in main thread
            if (result.isModified) {
              // IO operation: Write file (keep in main thread)
              await _dataStore.storage
                  .writeAsString(partitionPath, result.newContent);

              // Update partition metadata
              final updatedPartition = partition.copyWith(
                fileSizeInBytes: result.newContent.length,
                bTreeSize: result.newContent.length,
                entries: result.entryCount,
                timestamps: Timestamps(
                  created: partition.timestamps.created,
                  modified: DateTime.now(),
                ),
                checksum: result.checksum,
              );

              // Add to updated partitions list, not update metadata immediately
              updatedPartitions.add(updatedPartition);
            }

            if (isUniqueIndex && result.processedKeys.isNotEmpty) {
              final opId =
                  'op-del-keys-${DateTime.now().microsecondsSinceEpoch}';
              try {
                await _dataStore.lockManager
                    ?.acquireExclusiveLock(listLockResource, opId);
                keysToDelete
                    .removeWhere((k) => result.processedKeys.contains(k));
              } finally {
                _dataStore.lockManager
                    ?.releaseExclusiveLock(listLockResource, opId);
              }
            }
          } catch (e, stack) {
            Logger.error(
                'Failed to process partition for delete entries: $e\n$stack',
                label: 'IndexManager._processDeleteEntries');
          }
        });
      }

      await ParallelProcessor.execute<void>(tasks,
          label: 'IndexManager._processDeleteEntries',
          timeout: ParallelProcessor.noTimeout);

      // After all partitions are processed, update the main metadata
      if (updatedPartitions.isNotEmpty) {
        // Create a new partition list, keeping original order
        final List<IndexPartitionMeta> finalPartitions =
            List.from(indexMeta.partitions);

        // Use mapping table to record index positions, avoid duplicate lookups
        final Map<int, int> indexPositionMap = {};
        for (int i = 0; i < finalPartitions.length; i++) {
          indexPositionMap[finalPartitions[i].index] = i;
        }

        // Replace updated partitions in the list, keeping original order
        for (var updatedPartition in updatedPartitions) {
          final position = indexPositionMap[updatedPartition.index];
          if (position != null) {
            finalPartitions[position] = updatedPartition;
          }
        }

        // Create updated main metadata, no need to sort again
        final totalSize =
            finalPartitions.fold<int>(0, (sum, p) => sum + p.bTreeSize);
        final totalEntries =
            finalPartitions.fold<int>(0, (sum, p) => sum + p.entries);
        final updatedMeta = indexMeta.copyWith(
          partitions: finalPartitions,
          timestamps: Timestamps(
            created: indexMeta.timestamps.created,
            modified: DateTime.now(),
          ),
          totalSizeInBytes: totalSize,
          totalEntries: totalEntries,
        );

        // Update main metadata
        await _updateIndexMetadata(
            tableName: tableName,
            indexName: indexName,
            updatedMeta: updatedMeta);
      }

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
    final tasks = <Future<void> Function()>[];
    for (final key in keys) {
      tasks.add(() async {
        if (_indexWriting[key] == true) return;

        try {
          _indexWriting[key] = true;

          final parts = key.split(':');
          if (parts.length != 2) {
            _indexWriting[key] = false;
            return;
          }

          final tableName = parts[0];
          final indexName = parts[1];
          final maxConcurrent = _dataStore.config.maxConcurrent;

          // Create lock resource identifier for index write operation
          final lockResource = 'index:$tableName:$indexName';
          final operationId =
              'batch_write_index_${DateTime.now().millisecondsSinceEpoch}';

          try {
            // Acquire exclusive lock to prevent concurrent writes to the same index file
            await _dataStore.lockManager
                ?.acquireExclusiveLock(lockResource, operationId);

            // Get index metadata
            final indexMeta = await _getIndexMeta(tableName, indexName);
            if (indexMeta == null) {
              _indexWriting[key] = false;
              return;
            }

            // Check if there's any data to process
            bool hasInserts =
                _writeBuffer.containsKey(key) && _writeBuffer[key]!.isNotEmpty;
            bool hasDeletes = _deleteBuffer.containsKey(key) &&
                _deleteBuffer[key]!.isNotEmpty;

            if (!hasInserts && !hasDeletes) {
              _indexWriting[key] = false;
              return;
            }

            // --- 1. Process Inserts Concurrently ---
            if (hasInserts) {
              final writeBuffer = _writeBuffer[key]!;
              final List<IndexBufferEntry> allEntries =
                  writeBuffer.values.toList();
              writeBuffer.clear(); // Clear buffer immediately

              // Check if this is a primary key index and table has ordered flag
              bool isPrimaryKeyIndex = indexName == 'pk_$tableName';
              bool isTableOrdered = false;

              // For primary key index, check table metadata ordered flag
              if (isPrimaryKeyIndex) {
                try {
                  final tableMeta = await _dataStore.tableDataManager
                      .getTableFileMeta(tableName);
                  isTableOrdered = tableMeta?.isOrdered == true;
                } catch (e) {
                  // Ignore error, proceed with default handling
                }
              }

              // --- Pre-allocation Step ---
              final List<PartitionWriteJob> jobs = [];
              if (allEntries.isNotEmpty) {
                final maxPartitionFileSize =
                    _dataStore.config.maxPartitionFileSize;
                int partitionIndex = indexMeta.partitions.isEmpty
                    ? 0
                    : indexMeta.partitions.last.index;
                int currentSize = indexMeta.partitions.isEmpty
                    ? 0
                    : indexMeta.partitions.last.fileSizeInBytes;

                List<IndexBufferEntry> currentJobEntries = [];
                dynamic minKey, maxKey;

                int processedCount = 0;
                for (final entry in allEntries) {
                  try {
                    final estimatedEntrySize = (entry.indexEntry.indexKey
                                .toString()
                                .length +
                            entry.indexEntry.recordPointer.toString().length +
                            2)
                        .toInt();

                    // Track min/max keys for primary key index when table is ordered
                    if (isPrimaryKeyIndex && isTableOrdered) {
                      final currentKey = entry.indexEntry.indexKey;
                      if (minKey == null ||
                          ValueComparator.compare(currentKey, minKey) < 0) {
                        minKey = currentKey;
                      }
                      if (maxKey == null ||
                          ValueComparator.compare(currentKey, maxKey) > 0) {
                        maxKey = currentKey;
                      }
                    }

                    if (currentSize + estimatedEntrySize >
                            maxPartitionFileSize &&
                        currentJobEntries.isNotEmpty) {
                      // Finalize current job and start a new one
                      final job = PartitionWriteJob(
                          partitionIndex: partitionIndex,
                          entries: currentJobEntries);

                      // Set min/max keys for primary key index when table is ordered
                      if (isPrimaryKeyIndex && isTableOrdered) {
                        job.minKey = minKey;
                        job.maxKey = maxKey;
                        // Reset for next partition
                        minKey = null;
                        maxKey = null;
                      }

                      jobs.add(job);
                      partitionIndex++;
                      currentSize = 0;
                      currentJobEntries = [];
                    }

                    currentJobEntries.add(entry);
                    currentSize += estimatedEntrySize;

                    processedCount++;
                    if (processedCount % 500 == 0) {
                      await Future.delayed(Duration.zero);
                    }
                  } catch (e) {
                    Logger.warn('Failed to estimate entry size: $e',
                        label: 'IndexManager._processBatchIndexWrites');
                  }
                }

                // Add the last job
                if (currentJobEntries.isNotEmpty) {
                  final job = PartitionWriteJob(
                      partitionIndex: partitionIndex,
                      entries: currentJobEntries);

                  // Set min/max keys for primary key index when table is ordered
                  if (isPrimaryKeyIndex && isTableOrdered) {
                    job.minKey = minKey;
                    job.maxKey = maxKey;
                  }

                  jobs.add(job);
                }
              }

              // --- Parallel Execution Step (Optimized) ---
              if (jobs.isNotEmpty) {
                final allNewOrUpdatedPartitions = <IndexPartitionMeta>[];

                for (int i = 0; i < jobs.length; i += maxConcurrent) {
                  final batchJobs =
                      jobs.sublist(i, min(i + maxConcurrent, jobs.length));

                  // Step 1 (for batch): Concurrently load content and start compute.
                  // Use a standard for-loop for clearer type inference.
                  final computeFutures = <Future<IndexProcessingResult>>[];
                  for (final job in batchJobs) {
                    final future = () async {
                      try {
                        final results = indexMeta.partitions
                            .where((p) => p.index == job.partitionIndex);
                        final existingPartition =
                            results.isEmpty ? null : results.first;

                        if (existingPartition != null) {
                          final path = await _dataStore.pathManager
                              .getIndexPartitionPath(
                                  tableName, indexName, job.partitionIndex);
                          if (await _dataStore.storage.existsFile(path)) {
                            job.existingContent =
                                await _dataStore.storage.readAsString(path);
                          }
                        }
                        final request = IndexProcessingRequest(
                          entries: job.entries,
                          existingPartitionContent: job.existingContent,
                          isUnique: indexMeta.isUnique,
                        );
                        return await ComputeManager.run(
                            processIndexPartition, request,
                            useIsolate: (job.existingContent?.length ?? 0) >
                                500 * 1024);
                      } catch (e, stack) {
                        Logger.error(
                            'Error preparing or running compute job for partition ${job.partitionIndex}: $e\n$stack',
                            label: 'IndexManager._processBatchIndexWrites');
                        return IndexProcessingResult.failed();
                      }
                    }(); // Immediately invoke the async closure
                    computeFutures.add(future);
                  }

                  // Step 2 (for batch): Await all compute tasks to finish.
                  final computeResults = await Future.wait(computeFutures);

                  // Step 3 (for batch): Assign results and concurrently write files.
                  final writeFutures = <Future>[];
                  for (int j = 0; j < batchJobs.length; j++) {
                    try {
                      final job = batchJobs[j];
                      final result = computeResults[j];
                      if (result.isFailed) continue; // Skip failed jobs

                      job.result = result; // Needed for metadata creation below

                      final partitionPath = await _dataStore.pathManager
                          .getIndexPartitionPath(
                              tableName, indexName, job.partitionIndex);
                      writeFutures.add(_dataStore.storage.writeAsString(
                          partitionPath, result.serializedBTree));
                    } catch (e, stack) {
                      Logger.error('Error writing partition file: $e\n$stack',
                          label: 'IndexManager._processBatchIndexWrites');
                    }
                  }
                  await Future.wait(writeFutures);

                  // Step 4 (for batch): Create metadata for the completed jobs.
                  for (final job in batchJobs) {
                    if (job.result == null || job.result!.isFailed) continue;
                    try {
                      final checksum =
                          _calculateChecksum(job.result!.serializedBTree);
                      final results = indexMeta.partitions
                          .where((p) => p.index == job.partitionIndex);
                      final existingPartition =
                          results.isEmpty ? null : results.first;

                      if (existingPartition != null) {
                        // Merge old and new key ranges for primary key indexes and ordered tables
                        dynamic finalMinKey = existingPartition.minKey;
                        dynamic finalMaxKey = existingPartition.maxKey;

                        if (isPrimaryKeyIndex && isTableOrdered) {
                          // If there is a newly written key range
                          if (job.minKey != null) {
                            // If there was no original range, or if the new minimum key is smaller than the original one
                            if (finalMinKey == null ||
                                ValueComparator.compare(
                                        job.minKey, finalMinKey) <
                                    0) {
                              finalMinKey = job.minKey;
                            }
                          }

                          if (job.maxKey != null) {
                            // If there was no original range, or if the new maximum key is larger than the original one
                            if (finalMaxKey == null ||
                                ValueComparator.compare(
                                        job.maxKey, finalMaxKey) >
                                    0) {
                              finalMaxKey = job.maxKey;
                            }
                          }
                        }

                        allNewOrUpdatedPartitions
                            .add(existingPartition.copyWith(
                          fileSizeInBytes: job.result!.newSize,
                          bTreeSize: job.result!.newSize,
                          entries: job.result!.entryCount,
                          minKey: finalMinKey,
                          maxKey: finalMaxKey,
                          timestamps: Timestamps(
                              created: existingPartition.timestamps.created,
                              modified: DateTime.now()),
                          checksum: checksum,
                        ));
                      } else {
                        allNewOrUpdatedPartitions.add(IndexPartitionMeta(
                          version: 1,
                          index: job.partitionIndex,
                          fileSizeInBytes: job.result!.newSize,
                          minKey:
                              job.minKey, // Use collected min key if available
                          maxKey:
                              job.maxKey, // Use collected max key if available
                          bTreeSize: job.result!.newSize,
                          entries: job.result!.entryCount,
                          timestamps: Timestamps(
                              created: DateTime.now(),
                              modified: DateTime.now()),
                          checksum: checksum,
                        ));
                      }
                    } catch (e, stack) {
                      Logger.error(
                          'Error creating partition metadata: $e\n$stack',
                          label: 'IndexManager._processBatchIndexWrites');
                    }
                  }
                }

                // --- Final Step: Update metadata once with all changes ---
                final partitionMap = {
                  for (var p in indexMeta.partitions) p.index: p
                };
                for (var p in allNewOrUpdatedPartitions) {
                  partitionMap[p.index] = p;
                }
                final finalPartitions = partitionMap.values.toList()
                  ..sort((a, b) => a.index.compareTo(b.index));

                final totalSize =
                    finalPartitions.fold<int>(0, (sum, p) => sum + p.bTreeSize);
                final totalEntries =
                    finalPartitions.fold<int>(0, (sum, p) => sum + p.entries);
                final updatedMeta = indexMeta.copyWith(
                  partitions: finalPartitions,
                  isOrdered: isTableOrdered,
                  timestamps: Timestamps(
                      created: indexMeta.timestamps.created,
                      modified: DateTime.now()),
                  totalSizeInBytes: totalSize,
                  totalEntries: totalEntries,
                );

                // Use unified method to update metadata
                await _updateIndexMetadata(
                    tableName: tableName,
                    indexName: indexName,
                    updatedMeta: updatedMeta);
              }
            }

            // --- 2. Process Deletes Sequentially ---
            if (hasDeletes) {
              final deleteBuffer = _deleteBuffer[key]!;
              _deleteBuffer.remove(key); // Clear buffer immediately

              if (deleteBuffer.isNotEmpty) {
                await _processDeleteEntries(tableName, indexName, deleteBuffer);
              }
            }

            // Update last write time
            _indexLastWriteTime[key] = DateTime.now();
          } catch (e, stack) {
            Logger.error('Failed to batch write index: $e\n$stack',
                label: 'IndexManager._processBatchIndexWrites');
          } finally {
            // Release lock resource, whether the operation succeeds or fails
            _dataStore.lockManager
                ?.releaseExclusiveLock(lockResource, operationId);
          }
        } catch (e, stack) {
          Logger.error('Failed to batch write index: $e\n$stack',
              label: 'IndexManager._processBatchIndexWrites');
        } finally {
          _indexWriting[key] = false;
        }
      });
    }
    await ParallelProcessor.execute<void>(tasks,
        label: 'IndexManager._processBatchIndexWrites',
        timeout: ParallelProcessor.noTimeout);
  }

  void dispose() {
    // Ensure fast processing mode is disabled
    _disableFastProcessMode();

    // Unregister memory callback
    _dataStore.memoryManager
        ?.unregisterCacheEvictionCallback(CacheType.indexData);
    _dataStore.memoryManager
        ?.unregisterCacheEvictionCallback(CacheType.indexMeta);

    _indexCache.clear();
    _indexMetaCache.clear();
    _indexFullyCached.clear();
    _indexAccessWeights.clear();
    _writeBuffer.clear();
    _indexWriting.clear();
    _indexLastWriteTime.clear();
    _deleteBuffer.clear();
    _indexMetaSizeCache.clear();
    _indexSizeCache.clear();
    _currentIndexMetaCacheSize = 0;
    _currentIndexCacheSize = 0;
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

      // If it's a new day, update the weight value
      final lastUpdate =
          weights['lastWeightUpdate'] as DateTime? ?? DateTime(1970);
      if (currentDate.isAfter(lastUpdate)) {
        // Get base weight increment
        int weightIncrement = 1;

        // Give higher weight to primary and unique indexes
        final parts = cacheKey.split(':');
        if (parts.length == 2) {
          final tableName = parts[0];
          final indexName = parts[1];

          // Primary key index gets 3x weight
          if (indexName == 'pk_$tableName') {
            weightIncrement = 3;
          }
          // Unique index gets 2x weight
          else if (indexName.startsWith('uniq_')) {
            weightIncrement = 2;
          }
        }

        // Apply weight increment
        weights['weight'] = (weights['weight'] as int? ?? 0) + weightIncrement;
        weights['lastWeightUpdate'] = currentDate;
      }

      // Update weight in memory
      _indexAccessWeights[cacheKey] = weights;

      // Check if cache needs to be cleaned
      _checkAndCleanupCache();
    } catch (e) {
      // Weight update exception
      Logger.error('Failed to update index access weight: $e',
          label: 'IndexManager._updateIndexAccessWeight');
    }
  }

  /// Check and clean cache
  void _checkAndCleanupCache() {
    try {
      final cacheSize = _indexCache.length;

      // Get index cache size limit using memory manager
      final memoryManager = _dataStore.memoryManager;

      // Estimate current index cache total size (in bytes)
      int currentIndexCacheSize = 0;
      _indexCache.forEach((key, index) {
        currentIndexCacheSize += _estimateIndexSize(index);
      });

      final maxSize = memoryManager != null
          ? memoryManager.getIndexCacheSize() // Limit in bytes
          : 10000;

      // If current index cache size is less than 90% of the limit, do not clean up
      if (currentIndexCacheSize <= maxSize * 0.9) return;

      // Need to clean up cache, calculate the ratio to be cleaned up
      final removeRatio = 1.0 - (maxSize * 0.7 / currentIndexCacheSize);
      final needToRemove = (cacheSize * removeRatio).ceil();

      // Sort by weight
      final weightEntries = _indexAccessWeights.entries.toList()
        ..sort((a, b) =>
            (a.value['weight'] as int).compareTo(b.value['weight'] as int));

      // Remove index with lowest weight, clean up to less than 70% capacity
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

  /// Estimate index size (in bytes)
  int _estimateIndexSize(BPlusTree index) {
    // Index base structure size
    int baseSize = 100;

    // Estimate size based on index entry count and complexity
    // Each index entry includes key and value list
    int keyValueSize = 0;

    try {
      // Get index entry count using count() method
      keyValueSize = index.count() * 40; // Average 40 bytes per index entry
    } catch (e) {
      // If size cannot be accessed, use default estimated value
      keyValueSize = 1000; // Default assume 25 index entries
    }

    return baseSize + keyValueSize;
  }

  /// Estimate index metadata size (bytes)
  int _estimateIndexMetaSize(IndexMeta meta) {
    // Base structure size
    int size = 100;

    // Field size
    size += meta.fields.length * 20;

    // Partition size
    size += meta.partitions.length * 100; // Each partition is about 100 bytes

    // String size
    size += meta.name.length * 2;
    size += meta.tableName.length * 2;

    return size;
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

      // Estimate metadata size
      final metaSize = _estimateIndexMetaSize(meta);

      // Check if the metadata cache exceeds the limit
      final metaCacheLimit =
          _dataStore.memoryManager?.getIndexMetaCacheSize() ?? 10000;
      if (_currentIndexMetaCacheSize + metaSize > metaCacheLimit) {
        // If the limit is exceeded, trigger metadata cache cleaning
        _cleanupIndexMetaCache();
      }

      // Update cache
      _indexMetaCache[cacheKey] = meta;
      _indexMetaSizeCache[cacheKey] = metaSize;
      _currentIndexMetaCacheSize += metaSize;

      return meta;
    } catch (e) {
      Logger.error('Failed to get index metadata: $e',
          label: 'IndexManager._getIndexMeta');
      return null;
    }
  }

  /// Determine if an index should be fully cached
  bool _shouldFullCacheIndex(
      String tableName, String indexName, IndexMeta meta) {
    try {
      // Always fully cache small indexes

      if (meta.partitions.length < 100) {
        return true;
      }

      // Get cache size limit
      final memoryManager = _dataStore.memoryManager;
      if (memoryManager == null) {
        return false; // No memory manager, conservative approach
      }

      final indexCacheLimit = memoryManager.getIndexCacheSize();

      // Use the accurate current cache size
      int currentUsage = _currentIndexCacheSize;

      // Estimate size of this index
      int estimatedIndexSize = meta.totalSizeInBytes;

      // Special handling for important indexes
      bool isPrimaryKey = indexName == 'pk_$tableName';
      bool isUniqueIndex = meta.isUnique;

      // If primary key or unique index, check if we're under 90% capacity
      if ((isPrimaryKey || isUniqueIndex) &&
          currentUsage + estimatedIndexSize < indexCacheLimit * 0.9) {
        return true;
      }

      // If cache is under 80% capacity, allow full caching
      if (currentUsage + estimatedIndexSize < indexCacheLimit * 0.8) {
        return true;
      }

      // Otherwise, don't fully cache
      return false;
    } catch (e) {
      Logger.error('Error determining cache status: $e',
          label: 'IndexManager._shouldFullCacheIndex');
      return false; // Conservative approach on error
    }
  }

  /// Load a selective index from file (only specific partition)
  Future<BPlusTree?> _loadSelectiveIndex(String tableName, String indexName,
      IndexMeta meta, int partitionIndex) async {
    try {
      // Get the specific partition
      final partition = meta.partitions[partitionIndex];
      final partitionPath = await _dataStore.pathManager
          .getIndexPartitionPath(tableName, indexName, partition.index);

      if (!await _dataStore.storage.existsFile(partitionPath)) {
        return BPlusTree(isUnique: meta.isUnique);
      }

      final content = await _dataStore.storage.readAsString(partitionPath);
      if (content == null || content.isEmpty) {
        return BPlusTree(isUnique: meta.isUnique);
      }

      // Build the B+ tree from the single partition content in a background isolate.
      final request = BuildTreeRequest(
          partitionsContent: [content], isUnique: meta.isUnique);

      final btree = await ComputeManager.run(
        buildTreeTask,
        request,
        useIsolate: true, // It's a heavy task.
      );

      return btree;
    } catch (e) {
      Logger.error('Failed to load selective index: $e',
          label: 'IndexManager._loadSelectiveIndex');
      return null;
    }
  }

  /// Check if a table has ordered primary key index
  /// Used for optimizing range queries
  Future<bool> isTablePrimaryKeyOrdered(String tableName) async {
    try {
      final pkIndexName = 'pk_$tableName';
      final meta = await _getIndexMeta(tableName, pkIndexName);

      // If metadata exists and isOrdered flag is set
      if (meta != null) {
        // Return the value if defined, otherwise default to false
        return meta.isOrdered ?? false;
      }

      return false;
    } catch (e) {
      Logger.error('Failed to check if primary key is ordered: $e',
          label: 'IndexManager.isTablePrimaryKeyOrdered');
      return false;
    }
  }

  /// Find partitions that may contain keys in a range
  /// Returns list of partition indexes
  Future<List<int>> findPartitionsForKeyRange(String tableName,
      String indexName, dynamic startKey, dynamic endKey) async {
    try {
      final meta = await _getIndexMeta(tableName, indexName);
      if (meta == null) return [];

      // only use range optimization when index is ordered
      if (meta.isOrdered == true) {
        try {
          // use IndexMeta method to find partitions
          final partitions = meta.findPartitionsForKeyRange(startKey, endKey);

          // if found partitions, return result
          if (partitions.isNotEmpty) {
            return partitions;
          }

          // if no partitions found but should have result, maybe order flag is wrong
          // async detect order, not block current query
          _detectAndUpdateIndexOrder(tableName, indexName);
        } catch (e) {
          Logger.debug(
              'Range partition finding failed, possibly incorrect order flag: $e',
              label: 'IndexManager.findPartitionsForKeyRange');

          // async detect order
          _detectAndUpdateIndexOrder(tableName, indexName);
        }
      }

      // if index is not ordered or range query failed, return all partitions
      return List.generate(meta.partitions.length, (i) => i);
    } catch (e) {
      Logger.error('Failed to find partitions for key range: $e',
          label: 'IndexManager.findPartitionsForKeyRange');
      return [];
    }
  }

  /// Load index entries from specific partitions
  /// Optimization for range queries - only loads data from relevant partitions
  Future<BPlusTree?> getPartialIndex(
      String tableName, String indexName, List<int> partitionIndices) async {
    try {
      final cacheKey = _getIndexCacheKey(tableName, indexName);

      // If index is fully cached, just return the cached instance
      if (_indexCache.containsKey(cacheKey) &&
          _indexFullyCached[cacheKey] == true) {
        _updateIndexAccessWeight(cacheKey);
        return _indexCache[cacheKey];
      }

      // Get metadata
      final meta = await _getIndexMeta(tableName, indexName);
      if (meta == null) return null;

      // 1. Read all required partition files in parallel.
      final tasks = <Future<String?> Function()>[];
      final partitionMap = {for (var p in meta.partitions) p.index: p};

      for (final partitionIndex in partitionIndices) {
        final partition = partitionMap[partitionIndex];
        if (partition == null) continue;

        tasks.add(() async {
          try {
            final partitionPath = await _dataStore.pathManager
                .getIndexPartitionPath(tableName, indexName, partition.index);
            if (!await _dataStore.storage.existsFile(partitionPath)) {
              return null;
            }
            return await _dataStore.storage.readAsString(partitionPath);
          } catch (e) {
            Logger.error(
                'Failed to read index partition ${partition.index}: $e',
                label: 'IndexManager.getPartialIndex');
            return null;
          }
        });
      }

      final partitionContents = await ParallelProcessor.execute<String?>(tasks,
          label: 'IndexManager.getPartialIndex.read');

      final validContents = partitionContents
          .whereType<String>()
          .where((s) => s.isNotEmpty)
          .toList();

      if (validContents.isEmpty) {
        return BPlusTree(isUnique: meta.isUnique);
      }

      // 2. Build the B+ tree from contents in a background isolate.
      final request = BuildTreeRequest(
          partitionsContent: validContents, isUnique: meta.isUnique);

      final btree = await ComputeManager.run(
        buildTreeTask,
        request,
        useIsolate: true, // Heavy task, always use isolate.
      );

      // If we're loading most partitions, consider caching the tree
      if (partitionIndices.length > meta.partitions.length * 0.7 &&
          _shouldFullCacheIndex(tableName, indexName, meta)) {
        // Worth caching, but not marked as fully cached
        _indexCache[cacheKey] = btree;
        _indexFullyCached[cacheKey] = false;
        _updateIndexAccessWeight(cacheKey);
      }

      return btree;
    } catch (e) {
      Logger.error('Failed to get partial index: $e',
          label: 'IndexManager.getPartialIndex');
      return null;
    }
  }

  /// Load index from file
  Future<BPlusTree?> _loadIndexFromFile(
      String tableName, String indexName, IndexMeta meta) async {
    try {
      // 1. Read all partition files in parallel.
      final tasks = <Future<String?> Function()>[];
      for (final partition in meta.partitions) {
        tasks.add(() async {
          try {
            final partitionPath = await _dataStore.pathManager
                .getIndexPartitionPath(tableName, indexName, partition.index);
            if (!await _dataStore.storage.existsFile(partitionPath)) {
              return null;
            }
            return await _dataStore.storage.readAsString(partitionPath);
          } catch (e) {
            Logger.error(
                'Failed to read index partition ${partition.index}: $e',
                label: 'IndexManager._loadIndexFromFile');
            return null;
          }
        });
      }
      final partitionContents = await ParallelProcessor.execute<String?>(tasks,
          label: 'IndexManager._loadIndexFromFile.read');

      final validContents = partitionContents
          .whereType<String>()
          .where((s) => s.isNotEmpty)
          .toList();

      if (validContents.isEmpty) {
        return BPlusTree(isUnique: meta.isUnique);
      }

      // 2. Build the B+ tree from contents in a background isolate.
      final request = BuildTreeRequest(
          partitionsContent: validContents, isUnique: meta.isUnique);

      final btree = await ComputeManager.run(
        buildTreeTask,
        request,
        useIsolate: true, // Heavy task, always use isolate.
      );

      return btree;
    } catch (e) {
      Logger.error('Failed to load index from file: $e',
          label: 'IndexManager._loadIndexFromFile');
      return null;
    }
  }

  /// Calculate content checksum
  String _calculateChecksum(String content) {
    // Use simple hash value as checksum
    final hash = content.hashCode;
    return hash.toRadixString(16).padLeft(8, '0');
  }

  /// Unified index metadata update method
  /// @param tableName Table name
  /// @param indexName Index name
  /// @param updatedMeta Updated metadata, if null, get from memory cache
  /// @param acquireLock Whether to acquire lock (default is true)
  /// @param updateCache Whether to update memory cache (default is true)
  /// @return Updated index metadata
  Future<IndexMeta?> _updateIndexMetadata({
    required String tableName,
    required String indexName,
    IndexMeta? updatedMeta,
    bool acquireLock = true,
    bool updateCache = true,
  }) async {
    final cacheKey = _getIndexCacheKey(tableName, indexName);

    // If no updated metadata is provided, try to get from cache
    final meta = updatedMeta ?? _indexMetaCache[cacheKey];
    if (meta == null) return null;

    // Create lock resource identifier
    final lockResource = 'index_meta:$tableName:$indexName';
    final operationId = 'update_meta_${DateTime.now().millisecondsSinceEpoch}';

    try {
      // Acquire lock (if needed)
      if (acquireLock) {
        await _dataStore.lockManager
            ?.acquireExclusiveLock(lockResource, operationId);
      }

      // Update metadata file
      final metaPath =
          await _dataStore.pathManager.getIndexMetaPath(tableName, indexName);
      await _dataStore.storage
          .writeAsString(metaPath, jsonEncode(meta.toJson()));

      // Update cache
      if (updateCache) {
        // Get previous metadata size (if exists)
        final oldSize = _indexMetaSizeCache[cacheKey] ?? 0;

        // Calculate new metadata size
        final newSize = _estimateIndexMetaSize(meta);

        // Update cache size count
        if (oldSize > 0) {
          _currentIndexMetaCacheSize =
              _currentIndexMetaCacheSize - oldSize + newSize;
        } else {
          _currentIndexMetaCacheSize += newSize;
        }

        // Update cache
        _indexMetaCache[cacheKey] = meta;
        _indexMetaSizeCache[cacheKey] = newSize;
      }

      return meta;
    } catch (e, stack) {
      Logger.error('Failed to update index metadata: $e\n$stack',
          label: 'IndexManager._updateIndexMetadata');
      return null;
    } finally {
      // Release lock (if acquired)
      if (acquireLock) {
        _dataStore.lockManager?.releaseExclusiveLock(lockResource, operationId);
      }
    }
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
              partitions: meta.partitions,
              timestamps: meta.timestamps,
              totalSizeInBytes: meta.totalSizeInBytes,
              totalEntries: meta.totalEntries,
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
                _indexCache[cacheKey] = BPlusTree(isUnique: true);
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
                  partitions: [],
                  timestamps: Timestamps(
                    created: DateTime.now(),
                    modified: DateTime.now(),
                  ),
                  totalSizeInBytes: 0,
                  totalEntries: 0,
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

      // Get table schema
      final tableSchema = await _dataStore.getTableSchema(tableName);
      if (tableSchema == null) {
        return;
      } else {
        // Use existing schema to rebuild
        await _rebuildTableIndexes(tableName, tableSchema, true, []);
      }
    } catch (e, stack) {
      Logger.error('Failed to create primary index: $e\n$stack',
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

      // Get table structure
      final tableSchema = await _dataStore.getTableSchema(tableName);
      if (tableSchema == null) {
        return;
      }

      final primaryKeyName = tableSchema.primaryKey;
      // Check if a redundant primary key index is created
      if (schema.fields.length == 1 &&
          schema.fields.first == primaryKeyName &&
          indexName != 'pk_$tableName') {
        Logger.warn(
          'Skipping creation of redundant primary key index: $indexName, primary key "$primaryKeyName" is automatically indexed as pk_$tableName',
          label: 'IndexManager.createIndex',
        );
        return; // Skip creation of redundant primary key index
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

      // Use optimized index building
      await _rebuildTableIndexes(tableName, tableSchema, false, [schema]);

      Logger.info('Created index for $tableName: $indexName',
          label: 'IndexManager.createIndex');
    } catch (e, stack) {
      Logger.error('Failed to create index: $e\n$stack',
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
        // Check unique field auto-created indexes
        if (field.unique) {
          final uniqueIndexName = 'uniq_${field.name}';
          if (!indexesToReset.contains(uniqueIndexName)) {
            indexesToReset.add(uniqueIndexName);
          }
        }
      }

      // Clear index data from memory and files
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
          int partitionCount = 0;
          for (final partition in meta.partitions.toList()) {
            final partitionPath = await _dataStore.pathManager
                .getIndexPartitionPath(tableName, indexName, partition.index);
            await _dataStore.storage.deleteFile(partitionPath);

            partitionCount++;
            // Add a small delay every 10 partitions to avoid blocking the UI thread
            if (partitionCount % 10 == 0) {
              await Future.delayed(Duration.zero);
            }
          }

          // Update index metadata
          final updatedMeta = meta.copyWith(
            partitions: [],
            timestamps: Timestamps(
              created: meta.timestamps.created,
              modified: DateTime.now(),
            ),
            totalSizeInBytes: 0,
            totalEntries: 0,
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

      // Collect all indexes to rebuild
      final indexesToBuild = <IndexSchema>[];

      // Add all normal indexes
      indexesToBuild.addAll(schema.indexes);

      // Add unique field indexes if they don't have an explicit index
      for (final field in schema.fields) {
        if (field.unique && field.name != schema.primaryKey) {
          bool hasExplicitIndex = schema.indexes.any((idx) =>
              idx.fields.length == 1 && idx.fields.first == field.name);

          if (!hasExplicitIndex) {
            indexesToBuild.add(IndexSchema(
              fields: [field.name],
              unique: true,
            ));
          }
        }
      }

      // Use optimized batch index building mechanism
      await _rebuildTableIndexes(tableName, schema, true, indexesToBuild);

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

      String? selfStoreIndexStr;
      if (isUpdate && primaryValue != null) {
        final selfStoreIndex =
            await getStoreIndexByPrimaryKey(tableName, primaryValue);
        selfStoreIndexStr = selfStoreIndex?.toString();
      }

      // 1. Consolidate all unique constraints to check.
      final constraints = <_UniqueConstraint>[];

      // Add primary key constraint (only for inserts)
      if (!isUpdate && primaryValue != null) {
        constraints.add(_UniqueConstraint(
            fields: [primaryKey],
            value: primaryValue,
            indexName: 'pk_$tableName'));
      }

      // Add all unique indexes from schema (single and composite)
      for (final index in schema.indexes) {
        if (index.unique) {
          final value = _createIndexKey(data, index.fields);
          if (value != null) {
            constraints.add(_UniqueConstraint(
                fields: index.fields,
                value: value,
                indexName: index.actualIndexName));
          }
        }
      }

      // Add unique fields that don't have an explicit index
      final indexedFields = schema.indexes
          .where((i) => i.fields.length == 1 && i.unique)
          .map((i) => i.fields.first)
          .toSet();
      for (final field in schema.fields) {
        if (field.unique &&
            field.name != primaryKey &&
            !indexedFields.contains(field.name)) {
          final value = data[field.name];
          if (value != null) {
            constraints.add(_UniqueConstraint(
                fields: [field.name],
                value: value,
                indexName: 'uniq_${field.name}'));
          }
        }
      }

      // 2. Iterate and check each constraint.
      for (final constraint in constraints) {
        try {
          // A. Check the index.
          final searchResult = await searchIndex(tableName,
              constraint.indexName, IndexCondition.equals(constraint.value));

          if (searchResult.requiresTableScan) {
            // B. Index not available, fall back to a direct query via QueryExecutor.
            // Handle both single and composite keys.
            final queryCondition = QueryCondition();
            for (final field in constraint.fields) {
              queryCondition.where(field, '=', data[field]);
            }

            final existingRecords = await _dataStore.executeQuery(
                tableName, queryCondition,
                limit: 2); // Limit 2 is enough to detect a collision

            if (existingRecords.isNotEmpty) {
              bool isCollision = false;
              if (!isUpdate) {
                // On insert, any result is a violation.
                isCollision = true;
              } else {
                // On update, it's a violation if we find a record that is not the one being updated.
                if (existingRecords
                    .any((rec) => rec[primaryKey] != primaryValue)) {
                  isCollision = true;
                }
              }

              if (isCollision) {
                Logger.warn(
                    'Unique constraint violation on ${constraint.fields.join(', ')} with value "${constraint.value}" (table scan).',
                    label: 'IndexManager.checkUniqueConstraints');
                return false;
              }
            }
          } else if (!searchResult.isEmpty) {
            // C. Index found potential duplicates.
            final allPointers =
                searchResult.pointersByPartition.values.expand((p) => p);

            bool isCollision = false;
            if (!isUpdate) {
              isCollision = true; // Any found pointer is a collision on insert.
            } else {
              // On update, it's a collision if the found pointer is not the record itself.
              if (selfStoreIndexStr != null) {
                if (allPointers.any((p) => p != selfStoreIndexStr)) {
                  isCollision = true;
                }
              } else if (allPointers.isNotEmpty) {
                // Cannot identify self, so any found pointer is a potential collision.
                isCollision = true;
              }
            }

            if (isCollision) {
              Logger.warn(
                  'Unique constraint violation on ${constraint.fields.join(', ')} with value "${constraint.value}" (index hit).',
                  label: 'IndexManager.checkUniqueConstraints');
              return false;
            }
          }
        } catch (e, stack) {
          Logger.error('Failed to check unique constraints: $e\n$stack',
              label: 'IndexManager.checkUniqueConstraints');
          return false; // Fail safe.
        }
      }

      return true; // All checks passed.
    } catch (e, stack) {
      Logger.error('Failed to check unique constraints: $e\n$stack',
          label: 'IndexManager.checkUniqueConstraints');
      return false; // Fail safe.
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

    int processedCount = 0;
    // check each index key, determine which is global table
    for (final key in keysToCheck.toList()) {
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
      processedCount++;
      if (processedCount % 50 == 0) {
        await Future.delayed(Duration.zero);
      }
    }

    // only keep global table write buffer
    _writeBuffer.removeWhere((key, _) => !globalKeysToKeep.contains(key));

    // same as above, handle delete buffer
    final deleteKeysToCheck = <String>[..._deleteBuffer.keys];
    final globalDeleteKeysToKeep = <String>[];

    processedCount = 0;
    for (final key in deleteKeysToCheck.toList()) {
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
      processedCount++;
      if (processedCount % 50 == 0) {
        await Future.delayed(Duration.zero);
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
      int processedCount = 0;
      for (final meta in _indexMetaCache.values.toList()) {
        for (final partition in meta.partitions.toList()) {
          totalSize += partition.fileSizeInBytes;
        }
        processedCount++;
        if (processedCount % 50 == 0) {
          await Future.delayed(Duration.zero);
        }
      }

      // If cache is empty, scan from file system
      if (totalSize == 0) {
        final schemaList =
            await _dataStore.schemaManager?.getAllTableSchemas() ?? [];

        processedCount = 0;
        for (final schemaData in schemaList.toList()) {
          try {
            final schema = Map<String, dynamic>.from(schemaData);
            final tableName = schema['name'] as String?;

            if (tableName != null) {
              final indexDirPath =
                  await _dataStore.pathManager.getIndexDirPath(tableName);

              if (await _dataStore.storage.existsDirectory(indexDirPath)) {
                final files =
                    await _dataStore.storage.listDirectory(indexDirPath);

                int fileCount = 0;
                for (final filePath in files) {
                  if (filePath.endsWith('.${FileType.idx.ext}')) {
                    final size = await _dataStore.storage.getFileSize(filePath);
                    totalSize += size;
                  }
                  fileCount++;
                  if (fileCount % 100 == 0) {
                    await Future.delayed(Duration.zero);
                  }
                }
              }
            }
          } catch (e) {
            // Skip invalid schema
            Logger.error('Failed to process table schema: $e',
                label: 'IndexManager.getTotalIndexSize');
          }
          processedCount++;
          if (processedCount % 10 == 0) {
            await Future.delayed(Duration.zero);
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

    // Remove index cache
    _indexCache.remove(cacheKey);
    _indexFullyCached.remove(cacheKey);

    // Update index metadata cache size
    final metaSize = _indexMetaSizeCache[cacheKey] ?? 0;
    if (metaSize > 0) {
      _currentIndexMetaCacheSize -= metaSize;
      _indexMetaSizeCache.remove(cacheKey);
    }

    // Remove index metadata cache
    _indexMetaCache.remove(cacheKey);

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
      final searchResult = await searchIndex(
          tableName, pkIndexName, IndexCondition.equals(primaryKeyValue));

      if (searchResult.isEmpty || searchResult.requiresTableScan) return null;

      final allPointers =
          searchResult.pointersByPartition.values.expand((p) => p).toList();
      if (allPointers.isEmpty) return null;

      return StoreIndex.fromString(allPointers.first.toString());
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
        final btree = await BPlusTree.fromString(
          content,
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
      final pkIndexName = 'pk_$tableName';

      // Step 1: Batch get all StoreIndex pointers for the primary keys.
      final primaryKeyValues =
          records.map((r) => r[primaryKey]).where((k) => k != null).toList();

      if (primaryKeyValues.isEmpty) return;

      final pkPointers =
          await batchSearchIndex(tableName, pkIndexName, primaryKeyValues);

      // Create a map for quick lookup: primaryKey -> record
      final recordMap = {
        for (var r in records)
          if (r[primaryKey] != null) r[primaryKey]: r
      };

      // Create a map for quick lookup: primaryKey -> StoreIndex string
      final Map<dynamic, String> storeIndexMap = {};
      pkPointers.forEach((key, pointers) {
        if (pointers.isNotEmpty) {
          // Assuming primary key is unique, so there's only one pointer.
          storeIndexMap[key] = pointers.first.toString();
        }
      });

      if (storeIndexMap.isEmpty) {
        Logger.warn('No records to delete found in the index for $tableName.',
            label: 'IndexManager.batchDeleteFromIndexes');
        return;
      }

      int processedCount = 0;
      // Step 2: Efficiently add all entries to the delete buffer.
      for (final pkEntry in storeIndexMap.entries) {
        final primaryKeyValue = pkEntry.key;
        final storeIndexStr = pkEntry.value;
        final record = recordMap[primaryKeyValue];

        if (record == null) continue;

        // 1. Delete from primary key index
        await addToDeleteBuffer(
            tableName, pkIndexName, primaryKeyValue, storeIndexStr);

        // 2. Delete from normal indexes and unique indexes
        for (final index in schema.indexes) {
          final indexName = index.actualIndexName;
          final indexKey = _createIndexKey(record, index.fields);
          if (indexKey != null) {
            await addToDeleteBuffer(
                tableName, indexName, indexKey, storeIndexStr);
          }
        }

        // 3. Handle unique fields with auto-generated indexes
        for (final field in schema.fields) {
          if (field.unique &&
              field.name != primaryKey &&
              !schema.indexes.any((i) =>
                  i.fields.length == 1 && i.fields.first == field.name)) {
            final fieldValue = record[field.name];
            if (fieldValue != null) {
              final uniqueIndexName = 'uniq_${field.name}';
              await addToDeleteBuffer(
                  tableName, uniqueIndexName, fieldValue, storeIndexStr);
            }
          }
        }

        processedCount++;
        if (processedCount % 500 == 0) {
          await Future.delayed(Duration.zero);
        }
      }

      // Force buffer processing if the batch is large
      if (records.length > 1000) {
        _processIndexWriteBuffer();
      }
    } catch (e, stack) {
      Logger.error('Failed to batch delete records from indexes: $e\n$stack',
          label: 'IndexManager.batchDeleteFromIndexes');
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

        // Also remove from memory cache if it exists, but don't wait for it.
        if (_indexCache.containsKey(cacheKey)) {
          // Fire-and-forget cache update to avoid blocking.
          _indexCache[cacheKey]!.delete(key, storeIndexStr);
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

      // Also remove from memory cache if it exists, but don't wait for it.
      if (_indexCache.containsKey(cacheKey)) {
        // Fire-and-forget cache update to avoid blocking.
        _indexCache[cacheKey]!.delete(key, storeIndexStr);
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

  /// Check and rebuild needed indexes for a table
  /// @param tableName Table name
  /// @param tableSchema Table schema
  Future<void> _checkAndRebuildTableIndexes(
      String tableName, TableSchema tableSchema) async {
    try {
      // Create lock resource identifier
      final lockResource = 'rebuild_indexes:$tableName';
      final operationId =
          'rebuild_indexes_${DateTime.now().millisecondsSinceEpoch}';

      try {
        // Try to acquire lock
        final lockAcquired = _dataStore.lockManager
            ?.tryAcquireExclusiveLock(lockResource, operationId);

        if (lockAcquired == false) {
          // If lock cannot be acquired, another thread is rebuilding
          Logger.info(
              'Another thread is rebuilding indexes for $tableName, skipping',
              label: 'IndexManager._checkAndRebuildTableIndexes');
          return;
        }

        // Check primary key index
        final pkIndexName = 'pk_$tableName';
        final pkIndexMeta = await _getIndexMeta(tableName, pkIndexName);
        final primaryKey = tableSchema.primaryKey;

        // Collect indexes to build
        final indexesToBuild = <IndexSchema>[];
        bool needRebuildPrimary = pkIndexMeta == null;

        // Check normal indexes
        for (final indexSchema in tableSchema.indexes) {
          final indexName = indexSchema.actualIndexName;
          final indexMeta = await _getIndexMeta(tableName, indexName);

          if (indexMeta == null) {
            indexesToBuild.add(indexSchema);
          }
        }

        // Check unique field auto-created indexes
        for (final field in tableSchema.fields) {
          if (field.unique && field.name != primaryKey) {
            // Check if an explicit index exists for this field
            bool hasExplicitIndex = tableSchema.indexes.any((idx) =>
                idx.fields.length == 1 && idx.fields.first == field.name);

            if (!hasExplicitIndex) {
              final uniqueIndexName = 'uniq_${field.name}';
              final indexMeta = await _getIndexMeta(tableName, uniqueIndexName);

              if (indexMeta == null) {
                // Add to indexes to build
                indexesToBuild.add(IndexSchema(
                  fields: [field.name],
                  unique: true,
                ));
              }
            }
          }
        }

        // If all indexes exist, no need to rebuild
        if (!needRebuildPrimary && indexesToBuild.isEmpty) {
          return;
        }

        Logger.info(
            'Rebuilding indexes for $tableName: primaryKey=$needRebuildPrimary, otherIndexes=${indexesToBuild.length}',
            label: 'IndexManager._checkAndRebuildTableIndexes');

        // Rebuild all needed indexes at once
        await _rebuildTableIndexes(
            tableName, tableSchema, needRebuildPrimary, indexesToBuild);
      } finally {
        // Release lock
        _dataStore.lockManager?.releaseExclusiveLock(lockResource, operationId);
      }
    } catch (e, stack) {
      Logger.error('Failed to check and rebuild indexes: $e\n$stack',
          label: 'IndexManager._checkAndRebuildTableIndexes');
    }
  }

  /// Rebuild table indexes efficiently
  /// @param tableName Table name
  /// @param tableSchema Table schema
  /// @param rebuildPrimary Whether to rebuild primary key index
  /// @param indexesToBuild List of indexes to build
  Future<void> _rebuildTableIndexes(String tableName, TableSchema tableSchema,
      bool rebuildPrimary, List<IndexSchema> indexesToBuild) async {
    try {
      final primaryKey = tableSchema.primaryKey;

      // Create index metadata (if needed)
      if (rebuildPrimary) {
        final pkIndexName = 'pk_$tableName';

        // Check if table has ordered flag
        bool? isOrdered;
        try {
          final tableMeta =
              await _dataStore.tableDataManager.getTableFileMeta(tableName);
          if (tableMeta?.isOrdered != null) {
            isOrdered = tableMeta!.isOrdered;
          }
        } catch (e) {
          // Ignore error, proceed with default handling
        }

        final pkMeta = IndexMeta(
          version: 1,
          name: pkIndexName,
          tableName: tableName,
          fields: [primaryKey],
          isUnique: true,
          partitions: [],
          isOrdered: isOrdered, // Inherit ordered flag from table metadata
          timestamps: Timestamps(
            created: DateTime.now(),
            modified: DateTime.now(),
          ),
          totalSizeInBytes: 0,
          totalEntries: 0,
        );

        // Use unified method to update metadata
        await _updateIndexMetadata(
            tableName: tableName, indexName: pkIndexName, updatedMeta: pkMeta);
      }

      // Create metadata for other indexes
      for (final indexSchema in indexesToBuild) {
        final indexName = indexSchema.actualIndexName;
        final indexMeta = IndexMeta(
          version: 1,
          name: indexName,
          tableName: tableName,
          fields: indexSchema.fields,
          isUnique: indexSchema.unique,
          partitions: [],
          timestamps: Timestamps(
            created: DateTime.now(),
            modified: DateTime.now(),
          ),
          totalSizeInBytes: 0,
          totalEntries: 0,
        );

        // Use unified method to update metadata
        await _updateIndexMetadata(
            tableName: tableName, indexName: indexName, updatedMeta: indexMeta);
      }

      // Store index entries by partition
      // Map<partitionId, Map<indexName, Map<indexKey, List<recordPointer>>>>
      final partitionIndexData =
          <int, Map<String, Map<dynamic, List<String>>>>{};

      // Maximum concurrent operations
      final maxConcurrent = _dataStore.config.maxConcurrent;

      // Record count for generating pointers
      int recordCount = 0;

      // Track which partitions have been processed
      final processedPartitions = <int>{};

      // Count total entries in write buffer for this table
      int getTableWriteBufferSize() {
        int size = 0;
        for (final key in _writeBuffer.keys) {
          if (key.startsWith('$tableName:') && _writeBuffer[key] != null) {
            size += _writeBuffer[key]!.length;
          }
        }
        return size;
      }

      // Calculate dynamic threshold based on available memory
      // Each index entry is estimated to consume about 100 bytes
      Future<int> getDynamicThreshold() async {
        try {
          // Get available memory in MB
          final availableMemoryMB =
              await PlatformHandler.getAvailableSystemMemoryMB();

          // Reserve 25% of available memory for index building
          // 1MB = 1024*1024 bytes, divide by 100 bytes per entry
          final maxEntriesInMemory =
              (availableMemoryMB * 1024 * 1024 * 0.25 / 100).toInt();

          // Minimum threshold to ensure reasonable batch size
          const minThreshold = _fastProcessThreshold;

          // Calculate a safe threshold, with upper and lower limits
          return maxEntriesInMemory.clamp(minThreshold, minThreshold * 20);
        } catch (e) {
          // Fallback to fixed threshold if memory query fails
          Logger.warn('Failed to get available memory, using default threshold',
              label: 'IndexManager._rebuildTableIndexes');
          return _fastProcessThreshold * 4;
        }
      }

      // Get initial threshold
      int dynamicThreshold = await getDynamicThreshold();

      // Process function for submitting a batch of partition index data
      Future<void> processPartitionBatch() async {
        if (processedPartitions.isEmpty) return;

        Logger.debug(
            'Processing index batch for table $tableName, partitions: $processedPartitions',
            label: 'IndexManager._rebuildTableIndexes');

        // Sort partitions for ordered processing
        final sortedPartitions = processedPartitions.toList()..sort();

        for (final partitionId in sortedPartitions) {
          final partitionData = partitionIndexData[partitionId];
          if (partitionData == null) continue;

          // Process each index in this partition
          for (final indexName in partitionData.keys) {
            final indexEntries = partitionData[indexName]!;

            // Add entries to index buffer
            for (final entry in indexEntries.entries) {
              final indexKey = entry.key;
              final pointers = entry.value;

              for (final pointer in pointers) {
                await _addToInsertBuffer(
                    tableName, indexName, indexKey, pointer);
              }
            }
          }

          // Remove processed partition data from memory
          partitionIndexData.remove(partitionId);
        }

        // Get current buffer size
        final currentBufferSize = getTableWriteBufferSize();

        // Check if buffer size exceeds threshold
        if (currentBufferSize > dynamicThreshold) {
          Logger.debug(
              'Index buffer size ($currentBufferSize) exceeds threshold ($dynamicThreshold), flushing for table $tableName',
              label: 'IndexManager._rebuildTableIndexes');

          // Flush write buffer
          await _processIndexWriteBuffer();

          // Sleep for a duration proportional to the buffer size
          // The larger the buffer, the longer the sleep to allow more time for processing
          final sleepDuration = Duration(
              milliseconds: (currentBufferSize / dynamicThreshold * 100)
                  .clamp(50, 500)
                  .toInt());
          await Future.delayed(sleepDuration);

          // Update dynamic threshold after flush
          dynamicThreshold = await getDynamicThreshold();
        }

        // Clear processed partitions set
        processedPartitions.clear();
      }

      // Scan table data and build all indexes
      await _dataStore.tableDataManager.processTablePartitions(
          tableName: tableName,
          onlyRead: true,
          maxConcurrent: maxConcurrent,
          processFunction: (records, partitionIndex, controller) async {
            // Create index data container for this partition
            if (!partitionIndexData.containsKey(partitionIndex)) {
              partitionIndexData[partitionIndex] = {};

              // Primary key index
              if (rebuildPrimary) {
                partitionIndexData[partitionIndex]!['pk_$tableName'] = {};
              }

              // Other indexes
              for (final indexSchema in indexesToBuild) {
                partitionIndexData[partitionIndex]![
                    indexSchema.actualIndexName] = {};
              }
            }

            // Process each record
            for (final record in records) {
              final primaryKeyValue = record[primaryKey];
              if (primaryKeyValue == null) {
                continue;
              }

              // Create record pointer
              final pointer = StoreIndex(
                  offset: recordCount,
                  partitionId: partitionIndex,
                  clusterId: _dataStore.config.distributedNodeConfig.clusterId,
                  nodeId: _dataStore.config.distributedNodeConfig.nodeId);

              final pointerStr = pointer.toString();

              // Add primary key index data
              if (rebuildPrimary) {
                final pkData =
                    partitionIndexData[partitionIndex]!['pk_$tableName']!;
                if (!pkData.containsKey(primaryKeyValue)) {
                  pkData[primaryKeyValue] = [];
                }
                pkData[primaryKeyValue]!.add(pointerStr);
              }

              // Add other index data
              for (final indexSchema in indexesToBuild) {
                final indexName = indexSchema.actualIndexName;
                final indexKey = _createIndexKey(record, indexSchema.fields);

                if (indexKey != null) {
                  final indexData =
                      partitionIndexData[partitionIndex]![indexName]!;
                  if (!indexData.containsKey(indexKey)) {
                    indexData[indexKey] = [];
                  }
                  indexData[indexKey]!.add(pointerStr);
                }
              }

              recordCount++;
            }

            // Mark this partition as processed
            processedPartitions.add(partitionIndex);

            // Check current buffer size before deciding whether to process or continue
            final currentPartitionCount = processedPartitions.length;
            final recordCountThreshold =
                recordCount % 10000 == 0 && recordCount > 0;

            if (currentPartitionCount >= maxConcurrent ||
                recordCountThreshold) {
              // Check if write buffer is getting too large
              final currentBufferSize = getTableWriteBufferSize();

              // If buffer is already approaching threshold, process now
              if (currentBufferSize > dynamicThreshold * 0.7) {
                await processPartitionBatch();
              } else {
                // Otherwise just call without awaiting to avoid blocking
                processPartitionBatch();
              }
            }

            return records; // Return original records, no modification
          });

      // Process any remaining partition data - make sure to await this call
      await processPartitionBatch();

      // Final flush of all buffers
      await _processIndexWriteBuffer();
    } catch (e, stack) {
      Logger.error('Failed to rebuild table indexes: $e\n$stack',
          label: 'IndexManager._rebuildTableIndexes');
      rethrow;
    }
  }

  /// Detect and update index order
  /// @param tableName table name
  /// @param indexName index name
  Future<void> _detectAndUpdateIndexOrder(
      String tableName, String indexName) async {
    try {
      // get index meta
      final meta = await _getIndexMeta(tableName, indexName);
      if (meta == null) return;

      // only process primary key index or index with isOrdered is true
      if (indexName != 'pk_$tableName' && meta.isOrdered != true) {
        return;
      }

      // check last check time, avoid frequent detection
      final lastCheckTime = _lastOrderCheckTime['$tableName:$indexName'] ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      const checkInterval = 1000 * 60 * 60; // 1 hour

      // if last check time is less than 1 hour, skip detection
      if (now - lastCheckTime < checkInterval) {
        return;
      }

      // for large index, use sampling detection
      final isOrdered = _checkPartitionsOrderBySampling(meta.partitions);

      // update meta
      final updatedMeta = meta.copyWith(isOrdered: isOrdered);
      await _updateIndexMetadata(
          tableName: tableName, indexName: indexName, updatedMeta: updatedMeta);

      // record last check time
      _lastOrderCheckTime['$tableName:$indexName'] = now;
    } catch (e, stack) {
      Logger.error('Failed to detect index order: $e\n$stack',
          label: 'IndexManager._detectAndUpdateIndexOrder');
    }
  }

  /// check partitions order by sampling
  bool _checkPartitionsOrderBySampling(List<IndexPartitionMeta> partitions) {
    if (partitions.isEmpty || partitions.length == 1) return true;

    // sample detection, check at most 10 uniformly distributed samples
    final maxSamples = min(partitions.length, 10);
    final step = (partitions.length / maxSamples).ceil();

    dynamic lastMaxKey;

    for (int i = 0; i < partitions.length; i += step) {
      if (i >= partitions.length) break;

      final partition = partitions[i];

      // first partition, only record max key
      if (lastMaxKey == null) {
        lastMaxKey = partition.maxKey;
        continue;
      }

      // check if current partition min key is greater than or equal to last partition max key
      if (lastMaxKey != null && partition.minKey != null) {
        if (ValueComparator.compare(partition.minKey, lastMaxKey) < 0) {
          // range overlap, not ordered
          return false;
        }
      } else if (partition.minKey == null) {
        // if min key is null, conservative handling as possible not ordered
        return false;
      }

      // update lastMaxKey
      lastMaxKey = partition.maxKey;
    }

    return true;
  }

  /// Searches an index using a structured condition, with optimizations for performance and memory.
  ///
  /// This method intelligently decides whether to load an entire index into memory
  /// or search it partition by partition based on the index size and query type.
  /// It supports equality and range queries with an optional limit to control result size.
  ///
  /// @param tableName The name of the table.
  /// @param indexName The name of the index to search.
  /// @param condition The structured IndexCondition for the search.
  /// @param limit An optional limit on the number of records to return.
  /// @return An IndexSearchResult containing the pointers to matching records.
  Future<IndexSearchResult> searchIndex(
    String tableName,
    String indexName,
    IndexCondition condition, {
    int? limit,
  }) async {
    try {
      // Handle 'IN' by decomposing into a batch search first
      if (condition.operator.toLowerCase() == 'in') {
        if (condition.value is! List || (condition.value as List).isEmpty) {
          return IndexSearchResult.empty();
        }
        final results = await batchSearchIndex(
            tableName, indexName, condition.value as List);
        final allPointers = results.values.expand((p) => p).toList();
        final Map<int, List<String>> grouped = {};
        for (final pointer in allPointers) {
          final storeIndex = StoreIndex.fromString(pointer.toString());
          if (storeIndex != null) {
            grouped
                .putIfAbsent(storeIndex.partitionId, () => [])
                .add(pointer.toString());
          }
        }
        return IndexSearchResult(pointersByPartition: grouped);
      }

      // 1. Metadata, Schema, and Comparator setup
      IndexMeta? meta = await _getIndexMeta(tableName, indexName);
      if (meta == null) {
        final tableSchemaOnDemand = await _dataStore.getTableSchema(tableName);
        if (tableSchemaOnDemand != null &&
            tableSchemaOnDemand.fields.isNotEmpty) {
          await _checkAndRebuildTableIndexes(tableName, tableSchemaOnDemand);
          meta = await _getIndexMeta(tableName, indexName); // Try again
          if (meta == null) {
            // If still not found after rebuild, fallback to table scan
            return IndexSearchResult.tableScan();
          }
        } else {
          return IndexSearchResult.tableScan();
        }
      }

      final tableSchema = await _dataStore.getTableSchema(tableName);
      if (tableSchema == null) return IndexSearchResult.tableScan();

      ComparatorFunction comparator = ValueComparator.compare;
      dynamic startValue = condition.value;
      dynamic endValue = condition.endValue;

      bool isPrimaryKeyIndex = indexName == 'pk_$tableName';
      if (isPrimaryKeyIndex) {
        comparator = ValueComparator.getPrimaryKeyComparator(
            tableSchema.primaryKeyConfig.type);
        startValue = startValue?.toString().trim();
        endValue = endValue?.toString().trim();
      } else {
        comparator = ValueComparator.compare; // Default
        if (meta.fields.length == 1) {
          final fieldSchema = tableSchema.fields
              .firstWhere((f) => f.name == meta?.fields.first);
          comparator = ValueComparator.getFieldComparator(fieldSchema.type);
          startValue = fieldSchema.convertValue(condition.value);
          endValue = fieldSchema.convertValue(condition.endValue);
        }
      }

      // A helper function to perform search on a btree instance and group results
      Future<Map<int, List<String>>> performBTreeSearchAndGroup(
          BPlusTree btree) async {
        List<dynamic> pointers = [];
        switch (condition.operator) {
          case '=':
            pointers = await btree.search(startValue, comparator: comparator);
            break;
          case '>':
            pointers = await btree.searchRange(startValue, null,
                includeStart: false, comparator: comparator);
            break;
          case '>=':
            pointers = await btree.searchRange(startValue, null,
                includeStart: true, comparator: comparator);
            break;
          case '<':
            pointers = await btree.searchRange(null, startValue,
                includeEnd: false, comparator: comparator);
            break;
          case '<=':
            pointers = await btree.searchRange(null, startValue,
                includeEnd: true, comparator: comparator);
            break;
          case 'between':
            pointers = await btree.searchRange(startValue, endValue,
                comparator: comparator);
            break;
          case 'like':
            if (startValue is String) {
              if (startValue.endsWith('%') && !startValue.startsWith('%')) {
                final prefix = startValue.substring(0, startValue.length - 1);
                pointers = await btree.searchRange(prefix, '$prefix\uffff',
                    comparator: comparator);
              } else {
                pointers = await btree.scanAndMatch(startValue);
              }
            }
            break;
        }
        final Map<int, List<String>> grouped = {};
        for (final pointer in pointers) {
          final storeIndex = StoreIndex.fromString(pointer.toString());
          if (storeIndex != null) {
            grouped
                .putIfAbsent(storeIndex.partitionId, () => [])
                .add(pointer.toString());
          }
        }
        return grouped;
      }

      // 2. Cache Check
      final cacheKey = _getIndexCacheKey(tableName, indexName);
      if (_indexCache.containsKey(cacheKey) &&
          _indexFullyCached[cacheKey] == true) {
        _updateIndexAccessWeight(cacheKey);
        final btree = _indexCache[cacheKey]!;
        final pointers = await performBTreeSearchAndGroup(btree);
        return IndexSearchResult(pointersByPartition: pointers);
      }

      // Priority: Check for full table cache.
      if (await _dataStore.dataCacheManager.isTableFullyCached(tableName)) {
        return IndexSearchResult.tableScan();
      }

      // 3. Decide on loading strategy
      if (_shouldFullCacheIndex(tableName, indexName, meta)) {
        final btree = await _loadIndexFromFile(tableName, indexName, meta);
        if (btree == null) return IndexSearchResult.tableScan();
        _updateIndexAccessWeight(cacheKey);
        _indexCache[cacheKey] = btree;
        _indexFullyCached[cacheKey] = true;
        _indexSizeCache[cacheKey] = _estimateIndexSize(btree);
        _currentIndexCacheSize += _indexSizeCache[cacheKey] ?? 0;
        final pointers = await performBTreeSearchAndGroup(btree);
        return IndexSearchResult(pointersByPartition: pointers);
      }

      // 4. Partition-by-partition search
      final Map<int, List<String>> allPointersByPartition = {};
      int totalFound = 0;

      bool addResults(Map<int, List<String>> pointers) {
        if (pointers.isNotEmpty) {
          pointers.forEach((partitionId, pointerList) {
            allPointersByPartition
                .putIfAbsent(partitionId, () => [])
                .addAll(pointerList);
            totalFound += pointerList.length;
          });
        }
        return limit != null && totalFound >= limit;
      }

      List<int> partitionIndices;
      bool isPrefixSearch = condition.operator == 'like' &&
          condition.value is String &&
          condition.value.endsWith('%') &&
          !condition.value.startsWith('%');

      if (meta.isOrdered == true) {
        if (condition.operator == '=') {
          // Optimization for equality check on an ordered index
          final partitionIndex = meta.findPartitionForKey(startValue);
          partitionIndices = partitionIndex != -1 ? [partitionIndex] : [];
        } else if (isPrefixSearch) {
          // Optimization for "like 'prefix%'" on an ordered index
          final prefix =
              condition.value.substring(0, condition.value.length - 1);
          partitionIndices = await findPartitionsForKeyRange(
              tableName, indexName, prefix, '$prefix\uffff');
        } else if (['>', '>=', '<', '<=', 'between']
            .contains(condition.operator)) {
          // Optimization for range queries on an ordered index
          partitionIndices = await findPartitionsForKeyRange(
              tableName, indexName, startValue, endValue);
        } else {
          // Fallback for other operators on an ordered index (e.g., like '%value%')
          partitionIndices = meta.partitions.map((p) => p.index).toList();
        }
      } else {
        // For non-ordered indexes, we must scan all partitions
        partitionIndices = meta.partitions.map((p) => p.index).toList();
      }

      for (final partitionIndex in partitionIndices) {
        final btree = await _loadSelectiveIndex(
            tableName, indexName, meta, partitionIndex);
        if (btree == null) continue;

        final pointers = await performBTreeSearchAndGroup(btree);
        if (addResults(pointers)) {
          break; // Limit reached
        }
      }

      return IndexSearchResult(pointersByPartition: allPointersByPartition);
    } catch (e, stack) {
      Logger.error('Failed to search index $tableName.$indexName: $e\n$stack',
          label: 'IndexManager.searchIndex');
      return IndexSearchResult.tableScan();
    }
  }

  /// Batch search an index for a given list of keys.
  Future<Map<dynamic, List<dynamic>>> batchSearchIndex(
      String tableName, String indexName, List<dynamic> keys) async {
    final Map<dynamic, List<dynamic>> allResults = {};
    if (keys.isEmpty) {
      return allResults;
    }

    try {
      final cacheKey = _getIndexCacheKey(tableName, indexName);

      // 1. Check cache first - if fully loaded, perform search in memory.
      if (_indexCache.containsKey(cacheKey) &&
          _indexFullyCached[cacheKey] == true) {
        _updateIndexAccessWeight(cacheKey);
        final btree = _indexCache[cacheKey]!;
        final tableSchema = await _dataStore.getTableSchema(tableName);
        final isPk = indexName == 'pk_$tableName';
        final pkType = tableSchema?.primaryKeyConfig.type;
        final comparator = isPk && pkType != null
            ? ValueComparator.getPrimaryKeyComparator(pkType)
            : ValueComparator.compare;

        for (final key in keys) {
          final results = await btree.search(key, comparator: comparator);
          if (results.isNotEmpty) {
            allResults[key] = results;
          }
        }
        return allResults;
      }

      final meta = await _getIndexMeta(tableName, indexName);
      if (meta == null) {
        return allResults; // No index, no results.
      }

      final tableSchema = await _dataStore.getTableSchema(tableName);
      final isPk = indexName == 'pk_$tableName';

      // Group keys by the partition they should reside in.
      final Map<int, List<dynamic>> partitionJobs = {};

      if (meta.isOrdered == true) {
        // For ordered indexes, we can find the exact partition for each key.
        for (final key in keys) {
          final partitionIndex = meta.findPartitionForKey(key);
          if (partitionIndex != -1) {
            partitionJobs.putIfAbsent(partitionIndex, () => []).add(key);
          }
          // Note: If key is out of range, it won't be found. This is expected.
        }
      } else {
        // For non-ordered indexes, every key must be checked against every partition.
        final allPartitions = meta.partitions.map((p) => p.index).toList();
        for (final partitionIndex in allPartitions) {
          partitionJobs.putIfAbsent(partitionIndex, () => []).addAll(keys);
        }
      }

      if (partitionJobs.isEmpty) {
        return allResults;
      }

      // Execute search tasks in parallel for each relevant partition.
      final tasks = <Future<BatchSearchTaskResult> Function()>[];
      final partitionMetas = {for (var p in meta.partitions) p.index: p};

      for (final jobEntry in partitionJobs.entries) {
        final partitionIndex = jobEntry.key;
        final keysForPartition = jobEntry.value;
        final partitionMeta = partitionMetas[partitionIndex];

        if (partitionMeta == null) continue;

        tasks.add(() async {
          try {
            final partitionPath = await _dataStore.pathManager
                .getIndexPartitionPath(tableName, indexName, partitionIndex);
            if (!await _dataStore.storage.existsFile(partitionPath)) {
              return BatchSearchTaskResult(found: {});
            }
            final content =
                await _dataStore.storage.readAsString(partitionPath);
            if (content == null || content.isEmpty) {
              return BatchSearchTaskResult(found: {});
            }

            DataType? dataType;
            if (tableSchema != null && !isPk && meta.fields.isNotEmpty) {
              final fieldSchema = tableSchema.fields
                  .firstWhere((f) => f.name == meta.fields.first);
              dataType = fieldSchema.type;
            }

            final request = BatchSearchTaskRequest(
              content: content,
              keys: keysForPartition,
              isUnique: meta.isUnique,
              keyType: dataType,
            );

            return await ComputeManager.run(
              batchSearchIndexPartitionTask,
              request,
              useIsolate:
                  content.length > 1024 * 10 || keysForPartition.length > 50,
            );
          } catch (e) {
            Logger.error(
                'Failed to batch search index partition $partitionIndex: $e',
                label: 'IndexManager.batchSearchIndex');
            return BatchSearchTaskResult(found: {});
          }
        });
      }

      final resultsFromPartitions =
          await ParallelProcessor.execute<BatchSearchTaskResult>(tasks,
              label: 'IndexManager.batchSearchIndex');

      // Merge results from all partitions.
      for (final result in resultsFromPartitions) {
        if (result != null) {
          result.found.forEach((key, value) {
            allResults.putIfAbsent(key, () => []).addAll(value);
          });
        }
      }

      return allResults;
    } catch (e) {
      Logger.error('Failed to batch search index $tableName.$indexName: $e',
          label: 'IndexManager.batchSearchIndex');
      return allResults;
    }
  }
}

class _UniqueConstraint {
  final List<String> fields;
  final dynamic value;
  final String indexName;

  _UniqueConstraint({
    required this.fields,
    required this.value,
    required this.indexName,
  });
}
