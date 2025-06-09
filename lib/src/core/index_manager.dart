import 'dart:async';
import 'dart:convert';
import '../Interface/isolate_provider.dart';
import 'dart:math';

import '../handler/logger.dart';
import '../handler/common.dart';
import '../model/data_store_config.dart';
import '../model/file_info.dart';
import '../model/store_index.dart';
import '../model/table_schema.dart';
import '../handler/value_comparator.dart';
import 'crontab_manager.dart';
import 'b_plus_tree.dart';
import 'data_store_impl.dart';
import 'storage_adapter.dart';
import '../handler/encoder.dart';

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

  // Index write buffer - table name + index name -> {entries: Map<key value, Set<record ID>>, lastUpdate: last update time}
  final Map<String, Map<String, dynamic>> _indexWriteBuffer = {};

  // Index delete buffer - table name + index name -> {entries: Map<key value, Set<record ID>>, lastUpdate: last update time}
  final Map<String, Map<String, dynamic>> _indexDeleteBuffer = {};

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
    for (final key in _indexWriteBuffer.keys) {
      final entries = _indexWriteBuffer[key]?['entries'] as Map?;
      if (entries != null && entries.length >= _fastProcessThreshold) {
        hasLargeBuffer = true;
        keysToProcess.add(key);
      }
    }

    // Check delete buffer
    for (final key in _indexDeleteBuffer.keys) {
      final entries = _indexDeleteBuffer[key]?['entries'] as Map?;
      if (entries != null && entries.length >= _fastProcessThreshold) {
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
          if (_indexWriteBuffer.containsKey(key)) {
            final insertEntries = _indexWriteBuffer[key]?['entries'] as Map?;
            if (insertEntries != null && insertEntries.isNotEmpty) {
              entries += insertEntries.length;
            }
          }

          // Check delete buffer
          if (_indexDeleteBuffer.containsKey(key)) {
            final deleteEntries = _indexDeleteBuffer[key]?['entries'] as Map?;
            if (deleteEntries != null && deleteEntries.isNotEmpty) {
              entries += deleteEntries.length;
            }
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
    for (final key in _indexWriteBuffer.keys) {
      if (_indexWriteBuffer[key]?['entries'] != null &&
          (_indexWriteBuffer[key]?['entries'] as Map).isNotEmpty) {
        result.add(key);
      }
    }

    // Add keys from delete buffer
    for (final key in _indexDeleteBuffer.keys) {
      if (_indexDeleteBuffer[key]?['entries'] != null &&
          (_indexDeleteBuffer[key]?['entries'] as Map).isNotEmpty) {
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

        // Extract data from insert buffer
        final insertData = _indexWriteBuffer[key];
        // Extract data from delete buffer
        final deleteData = _indexDeleteBuffer[key];

        // Check if there's any data to process
        bool hasInserts = insertData != null &&
            (insertData['entries'] as Map?)?.isNotEmpty == true;
        bool hasDeletes = deleteData != null &&
            (deleteData['entries'] as Map?)?.isNotEmpty == true;

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

        // Process inserts and deletes
        if (hasInserts) {
          final insertEntries =
              insertData['entries'] as Map<dynamic, Set<dynamic>>;

          // Process inserts
          await _writeIndexToFile(tableName, indexName, insertEntries);

          // Clear insert buffer
          _indexWriteBuffer[key] = {
            'entries': {},
            'lastUpdate': DateTime.now()
          };
        }

        if (hasDeletes) {
          final deleteEntries =
              deleteData['entries'] as Map<dynamic, Set<dynamic>>;

          // Process deletes
          await _processDeleteEntries(tableName, indexName, deleteEntries);

          // Clear delete buffer
          _indexDeleteBuffer[key] = {
            'entries': {},
            'lastUpdate': DateTime.now()
          };
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
        for (final entry in entriesToDelete.entries) {
          final key = entry.key;
          final recordIds = entry.value;

          // Search for this key in the current partition
          final existingValues = await btree.search(key);

          // Remove matching record IDs
          for (final recordId in recordIds) {
            for (final existingValue in existingValues) {
              if (existingValue.toString() == recordId) {
                await btree.delete(key, recordId);

                // because these indexes only have one record per key, no need to continue processing
                if (isUniqueIndex) {
                  return false; // stop processing more partitions
                }

                break;
              }
            }
          }
        }

        // for regular indexes, need to continue checking other partitions, because entries may be spread across multiple partitions
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

        // Extract data from insert buffer
        final insertData = _indexWriteBuffer[key];
        // Extract data from delete buffer
        final deleteData = _indexDeleteBuffer[key];

        // Check if there's any data to process
        bool hasInserts = insertData != null &&
            (insertData['entries'] as Map?)?.isNotEmpty == true;
        bool hasDeletes = deleteData != null &&
            (deleteData['entries'] as Map?)?.isNotEmpty == true;

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
          final entryList = (insertData['entries'] as Map).entries.toList();

          for (int i = 0; i < entryList.length; i += batchSize) {
            final end = min(i + batchSize, entryList.length);

            // Create current batch entries map
            final batchEntries = <dynamic, Set<dynamic>>{};
            for (int j = i; j < end; j++) {
              final entry = entryList[j];
              batchEntries[entry.key] =
                  Set<dynamic>.from(entry.value as Set<dynamic>);
            }

            // Write current batch
            await _writeIndexToFile(tableName, indexName, batchEntries);

            // Small delay between batches to avoid blocking the main thread
            if (i + batchSize < entryList.length) {
              await Future.delayed(const Duration(milliseconds: 5));
            }
          }

          // Clear insert buffer
          _indexWriteBuffer[key] = {
            'entries': {},
            'lastUpdate': DateTime.now()
          };
        }

        // Process deletes (also in batch mode)
        if (hasDeletes) {
          final deleteEntries =
              deleteData['entries'] as Map<dynamic, Set<dynamic>>;

          // Process deletes in batches to avoid loading too many partitions at once
          final deleteKeysList = deleteEntries.keys.toList();
          for (int i = 0; i < deleteKeysList.length; i += batchSize) {
            final end = min(i + batchSize, deleteKeysList.length);

            // Create current batch delete map
            final batchDeletes = <dynamic, Set<dynamic>>{};
            for (int j = i; j < end; j++) {
              final key = deleteKeysList[j];
              batchDeletes[key] = Set<dynamic>.from(deleteEntries[key]!);
            }

            // Process this batch of deletes
            await _processDeleteEntries(tableName, indexName, batchDeletes);

            // Small delay between batches
            if (i + batchSize < deleteKeysList.length) {
              await Future.delayed(const Duration(milliseconds: 5));
            }
          }

          // Clear delete buffer
          _indexDeleteBuffer[key] = {
            'entries': {},
            'lastUpdate': DateTime.now()
          };
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
    _indexWriteBuffer.clear();
    _indexWriting.clear();
    _indexLastWriteTime.clear();
    _indexDeleteBuffer.clear();
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
      for (final key in _indexWriteBuffer.keys) {
        final entries = _indexWriteBuffer[key]?['entries'] as Map?;
        if (entries != null && entries.isNotEmpty) {
          hasChanges = true;
          break;
        }
      }

      // Check delete buffer if insert buffer has no changes
      if (!hasChanges) {
        for (final key in _indexDeleteBuffer.keys) {
          final entries = _indexDeleteBuffer[key]?['entries'] as Map?;
          if (entries != null && entries.isNotEmpty) {
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

      // If the current partition is close to the maximum size, create a new partition
      if (currentSize > _dataStore.config.maxPartitionFileSize) {
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
            await Future.delayed(const Duration(milliseconds: 2));
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
          // Calculation exception,不影响主流程
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
      await _buildIndexFromTableData(tableName, indexName, [primaryKey]);
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

      // Scan table data to create indexe data to create index
      await _buildIndexFromTableData(tableName, indexName, schema.fields);
    } catch (e) {
      Logger.error('Failed to create index: $e',
          label: 'IndexManager.createIndex');
      rethrow;
    }
  }

  /// Build index from table data
  Future<void> _buildIndexFromTableData(
      String tableName, String indexName, List<String> fields) async {
    try {
      // Create temporary B+ tree
      final meta = await _getIndexMeta(tableName, indexName);
      if (meta == null) {
        throw Exception('Index metadata does not exist: $indexName');
      }

      final btree = BPlusTree(
        order: meta.bTreeOrder,
        isUnique: meta.isUnique,
      );

      // Get table structure
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
        return;
      }
      final primaryKey = schema.primaryKey;
      final isGlobal = schema.isGlobal;

      // Check record count, use Isolate for concurrent processing if it exceeds a certain value
      bool useIsolate = false;
      final recordCount = await _estimateTableRecordCount(tableName);

      if (recordCount > 5000) {
        // Use Isolate for concurrent processing if it exceeds 5000 records
        useIsolate = true;
      }

      if (useIsolate) {
        // Only set the ordered flag for the primary key index
        if (indexName == 'pk_$tableName') {
          // Calculate if the primary key is ordered and update metadata
          final isPrimaryKeyOrdered = _isPrimaryKeyOrdered(schema);
          final updatedMeta = meta.copyWith(isOrdered: isPrimaryKeyOrdered);

          // Save updated metadata
          final metaPath = await _dataStore.pathManager
              .getIndexMetaPath(tableName, indexName);
          await _dataStore.storage
              .writeAsString(metaPath, jsonEncode(updatedMeta.toJson()));

          // Update cache
          final cacheKey = _getIndexCacheKey(tableName, indexName);
          _indexMetaCache[cacheKey] = updatedMeta;
        }

        await _buildIndexWithIsolate(tableName, indexName, fields, meta);
      } else {
        // Get table metadata
        final fileMeta =
            await _dataStore.tableDataManager.getTableFileMeta(tableName);

        int? clusterId;
        int? nodeId;
        if (_dataStore.config.distributedNodeConfig.enableDistributed) {
          clusterId = _dataStore.config.distributedNodeConfig.clusterId;
          nodeId = _dataStore.config.distributedNodeConfig.nodeId;
        }

        if (fileMeta != null &&
            fileMeta.partitions != null &&
            fileMeta.partitions!.isNotEmpty) {
          // Process all data in partition order
          for (final partition in fileMeta.partitions!) {
            // Read partition data
            final records = await _dataStore.tableDataManager
                .readRecordsFromPartition(
                    tableName, isGlobal, partition.index, primaryKey);

            // Process each record
            for (var i = 0; i < records.length; i++) {
              final record = records[i];
              final primaryValue = record[primaryKey];
              if (primaryValue == null) continue;

              // Create record pointer
              final recordPointer = await StoreIndex.create(
                offset: i, // Use the offset in the partition
                partitionId: partition.index, // Use the correct partition ID
                clusterId: clusterId,
                nodeId: nodeId,
              );

              final recordId = recordPointer.toString();

              // Process single field or composite field index
              if (fields.length == 1) {
                // Single field index
                final fieldName = fields[0];
                final fieldValue = record[fieldName];

                if (fieldValue != null) {
                  await btree.insert(fieldValue, recordId);
                }
              } else {
                // Composite index
                final compositeKey = _createIndexKey(record, fields);
                if (compositeKey != null) {
                  await btree.insert(compositeKey, recordId);
                }
              }
            }
          }
        } else {
          // When there is no partition data, read directly from the stream
          int recordIndex = 0;
          await for (final record
              in _dataStore.tableDataManager.streamRecords(tableName)) {
            final primaryValue = record[primaryKey];
            if (primaryValue == null) continue;

            // Create record pointer
            final recordPointer = await StoreIndex.create(
              offset: recordIndex,
              partitionId: 0, // Default partition
              clusterId: clusterId,
              nodeId: nodeId,
            );

            final recordId = recordPointer.toString();
            recordIndex++;

            // Process index logic, same as above
            if (fields.length == 1) {
              final fieldName = fields[0];
              final fieldValue = record[fieldName];

              if (fieldValue != null) {
                await btree.insert(fieldValue, recordId);
              }
            } else {
              final compositeKey = _createIndexKey(record, fields);
              if (compositeKey != null) {
                await btree.insert(compositeKey, recordId);
              }
            }
          }
        }

        // Serialize the B+ tree to a file
        final serialized = btree.toStringHandle();

        // Create partition directory
        final dirPath = await _dataStore.pathManager
            .getIndexPartitionDirPath(tableName, indexName, 0);
        await _dataStore.storage.ensureDirectoryExists(dirPath);

        // Write partition file
        final partitionPath = await _dataStore.pathManager
            .getIndexPartitionPath(tableName, indexName, 0);
        await _dataStore.storage.writeAsString(partitionPath, serialized);

        // Calculate checksum
        final checksum = _calculateChecksum(serialized);

        // Calculate index value range, used for range queries for numeric indexes
        dynamic minKey, maxKey;

        // Only calculate range for primary key index
        if (indexName == 'pk_$tableName') {
          // Get table structure, determine if the primary key is ordered
          final isPrimaryKeyOrdered = _isPrimaryKeyOrdered(schema);

          if (isPrimaryKeyOrdered) {
            // Only calculate range for primary key index and ordered
            final allValues = await btree.getKeys();
            if (allValues.isNotEmpty) {
              try {
                if (allValues.first is num) {
                  // Numeric type
                  minKey = allValues.fold(
                      allValues.first,
                      (min, key) =>
                          ValueComparator.compare(key, min) < 0 ? key : min);
                  maxKey = allValues.fold(
                      allValues.first,
                      (max, key) =>
                          ValueComparator.compare(key, max) > 0 ? key : max);
                } else if (allValues.first is BigInt) {
                  // BigInt type
                  minKey = allValues.fold(
                      allValues.first,
                      (min, key) =>
                          ValueComparator.compare(key, min) < 0 ? key : min);
                  maxKey = allValues.fold(
                      allValues.first,
                      (max, key) =>
                          ValueComparator.compare(key, max) > 0 ? key : max);
                } else if (allValues.first is String) {
                  // String type
                  minKey = allValues.fold(
                      allValues.first,
                      (min, key) =>
                          ValueComparator.compare(key, min) < 0 ? key : min);
                  maxKey = allValues.fold(
                      allValues.first,
                      (max, key) =>
                          ValueComparator.compare(key, max) > 0 ? key : max);
                }
              } catch (e) {
                Logger.debug(
                    'Failed to calculate index rangeo calculate index range: $e',
                    label: 'IndexManager._buildIndexFromTableData');
              }
            }
          }
        }
        // Normal index does not calculate any range

        // Update index metadata
        final newPartition = IndexPartitionMeta(
          version: 1,
          index: 0,
          fileSizeInBytes: serialized.length,
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

        // Set ordered flag for primary key index
        final bool? isOrderedFlag =
            indexName == 'pk_$tableName' ? _isPrimaryKeyOrdered(schema) : null;

        final updatedMeta = meta.copyWith(
          partitions: [newPartition],
          timestamps: Timestamps(
            created: meta.timestamps.created,
            modified: DateTime.now(),
          ),
          isOrdered: isOrderedFlag,
        );

        // Write updated index metadata
        final metaPath =
            await _dataStore.pathManager.getIndexMetaPath(tableName, indexName);
        await _dataStore.storage
            .writeAsString(metaPath, jsonEncode(updatedMeta.toJson()));

        // Update cache
        final cacheKey = _getIndexCacheKey(tableName, indexName);
        _indexMetaCache[cacheKey] = updatedMeta;
        _indexCache[cacheKey] = btree;
        _indexFullyCached[cacheKey] = true;
      }
    } catch (e) {
      Logger.error('Failed to build index from table data: $e',
          label: 'IndexManager._buildIndexFromTableData');
      rethrow;
    }
  }

  /// Estimate table record count
  Future<int> _estimateTableRecordCount(String tableName) async {
    try {
      final fileMeta =
          await _dataStore.tableDataManager.getTableFileMeta(tableName);
      return fileMeta?.totalRecords ?? 0;
    } catch (e) {
      Logger.error('Failed to estimate table record count: $e',
          label: 'IndexManager._estimateTableRecordCount');
      return 1000; // Default return 1000, avoid error when using Isolate
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

  /// Build index using Isolate (for large data)
  Future<void> _buildIndexWithIsolate(String tableName, String indexName,
      List<String> fields, IndexMeta meta) async {
    try {
      // For WASM platforms, use the main thread with smaller batches instead of Isolate
      if (isWasmPlatform) {
        Logger.info('Running on WASM platform, using main thread for indexing',
            label: 'IndexManager._buildIndexWithIsolate');

        // Use a more efficient approach for WASM without isolates
        await _buildIndexOnMainThread(tableName, indexName, fields, meta);
        return;
      }

      // Pre-calculate all required paths
      final tableDataDirPath =
          await _dataStore.pathManager.getDataDirPath(tableName);
      final dataIndexPath = await _getDataIndexPath(tableName);
      final dataMetaPath =
          await _dataStore.pathManager.getDataMetaPath(tableName);
      final indexMetaPath =
          await _dataStore.pathManager.getIndexMetaPath(tableName, indexName);
      final partitionDirPath = await _dataStore.pathManager
          .getIndexPartitionDirPath(tableName, indexName, 0);
      final partitionPath = await _dataStore.pathManager
          .getIndexPartitionPath(tableName, indexName, 0);

      // Get maxEntriesPerDir from configuration
      final maxEntriesPerDir = _dataStore.config.maxEntriesPerDir;
      // Get maximum partition file size
      final maxPartitionFileSize = _dataStore.config.maxPartitionFileSize;

      // Estimate record total to determine chunking strategy
      final recordCount = await _estimateTableRecordCount(tableName);
      final int chunkSize = _calculateOptimalChunkSize(recordCount);

      // Create progress report ReceivePort
      final progressPort = ReceivePort();

      // Pre-calculate primary key index ordered flag
      bool? isPrimaryKeyOrdered;
      if (indexName == 'pk_$tableName') {
        // Check if the ordered flag is already in the metadata
        if (meta.isOrdered != null) {
          isPrimaryKeyOrdered = meta.isOrdered;
        } else {
          // Calculate if the primary key is ordered
          final schema = await _dataStore.getTableSchema(tableName);
          if (schema == null) {
            return;
          }
          isPrimaryKeyOrdered = _isPrimaryKeyOrdered(schema);
        }
      }

      // Prepare data to be passed to Isolate
      final indexData = {
        'tableName': tableName,
        'indexName': indexName,
        'fields': fields,
        'order': meta.bTreeOrder,
        'isUnique': meta.isUnique,
        'tableDataDirPath': tableDataDirPath,
        'dataIndexPath': dataIndexPath,
        'dataMetaPath': dataMetaPath,
        'indexMetaPath': indexMetaPath,
        'partitionDirPath': partitionDirPath,
        'partitionPath': partitionPath,
        'metaJson': jsonEncode(meta.toJson()),
        'maxEntriesPerDir': maxEntriesPerDir,
        'maxPartitionFileSize':
            maxPartitionFileSize, // Add maximum partition file size parameter
        'chunkSize': chunkSize, // Chunk size
        'progressPort': progressPort.sendPort, // Progress report port
        // Pass primary key ordered flag directly, avoid repeating judgment in Isolate
        'isPrimaryKeyOrdered': isPrimaryKeyOrdered,
      };

      // Pass path related configuration before starting Isolate
      final pathConfig = {
        'partitionDirTemplate': pathJoin('partitions', 'dir_{dirIndex}'),
        'partitionFileTemplate': 'p{partitionId}.${FileType.data.ext}',
        'maxEntriesPerDir': _dataStore.config.maxEntriesPerDir,
      };
      indexData['pathConfig'] = pathConfig;

      // Create result communication port
      final receivePort = ReceivePort();
      final completer = Completer();

      // Set progress report listener
      var lastProgressReport = DateTime.now();
      progressPort.listen((message) {
        if (message is Map && message.containsKey('progress')) {
          final now = DateTime.now();
          // Output log every 3 seconds at most, avoid log flooding
          if (now.difference(lastProgressReport).inSeconds >= 3) {
            final progressMsg = message.containsKey('message')
                ? message['message']
                : '${message['progress']} records processed';

            Logger.info('Index build progress: $progressMsg',
                label: 'IndexManager._buildIndexWithIsolate');
            lastProgressReport = now;
          }
        }
      });

      // Listen for results
      receivePort.listen((message) {
        if (message is Map) {
          if (message.containsKey('error')) {
            Logger.error('Isolate index build failed: ${message['error']}',
                label: 'IndexManager._buildIndexWithIsolate');
            completer.completeError(message['error']);
          } else if (message.containsKey('success')) {
            completer.complete(message);
          }
        }
      });

      // Start Isolate
      await Isolate.spawn(
          _isolateIndexBuilder, [receivePort.sendPort, indexData]);

      // Wait for results
      final result = await completer.future;

      // Process results
      if (result is Map) {
        final serializedMeta = result['meta'] as String?;

        if (serializedMeta != null) {
          final updatedMeta = IndexMeta.fromJson(jsonDecode(serializedMeta));

          // Update cache
          final cacheKey = _getIndexCacheKey(tableName, indexName);
          _indexMetaCache[cacheKey] = updatedMeta;
          _indexCache.remove(cacheKey); // Remove cache, reload next time
          _indexFullyCached.remove(cacheKey);
        }
      }

      Logger.debug('Index build completed using Isolate: $indexName',
          label: 'IndexManager._buildIndexWithIsolate');
    } catch (e) {
      Logger.error('Failed to build index using Isolate: $e',
          label: 'IndexManager._buildIndexWithIsolate');
      rethrow;
    }
  }

  /// Calculate the optimal chunk size to avoid processing too much data in a single batch
  int _calculateOptimalChunkSize(int totalRecords) {
    // For large data, use a smaller chunk size
    if (totalRecords > 500000) return 500;
    if (totalRecords > 100000) return 1000;
    if (totalRecords > 50000) return 2000;
    if (totalRecords > 10000) return 5000;
    return 10000; // Default chunk size
  }

  /// Isolate processing function (static method) - Use pre-allocated partition strategy
  static void _isolateIndexBuilder(List message) async {
    final SendPort sendPort = message[0];
    final Map indexData = message[1];

    try {
      // Extract parameters from passed data
      final tableName = indexData['tableName'] as String;
      final indexName = indexData['indexName'] as String;
      final fields = List<String>.from(indexData['fields']);
      final order = indexData['order'] as int;
      final isUnique = indexData['isUnique'] as bool;
      final maxEntriesPerDir = indexData['maxEntriesPerDir'] as int? ??
          500; // Get the value passed in, set the default value
      final chunkSize =
          indexData['chunkSize'] as int? ?? 5000; // Batch size, default 5000
      final progressPort =
          indexData['progressPort'] as SendPort?; // Progress report port

      // Use the file path passed in directly, avoid creating PathManager
      final tableDataDirPath = indexData['tableDataDirPath'] as String;
      final dataIndexPath = indexData['dataIndexPath'] as String;
      final dataMetaPath = indexData['dataMetaPath'] as String;
      final indexMetaPath = indexData['indexMetaPath'] as String;
      final partitionDirPath = indexData['partitionDirPath'] as String;
      final partitionPath = indexData['partitionPath'] as String;
      final metaJson = indexData['metaJson'] as String;

      // Get the partition file size limit from the configuration
      final maxPartitionFileSize = indexData['maxPartitionFileSize'] as int? ??
          4 * 1024 * 1024; // Default 4MB

      // Use these path information in Isolate
      final pathConfig = indexData['pathConfig'] as Map<String, dynamic>;
      final dirTemplate = pathConfig['partitionDirTemplate'] as String;
      final fileTemplate = pathConfig['partitionFileTemplate'] as String;

      // Create StorageAdapter instance
      final storage = StorageAdapter(DataStoreConfig());

      // Read record index file
      if (!(await storage.existsFile(dataIndexPath))) {
        throw Exception('Table index file does not exist: $dataIndexPath');
      }

      // Read record index
      final indexContent = await storage.readAsString(dataIndexPath);
      if (indexContent == null || indexContent.isEmpty) {
        throw Exception('Table index content is empty');
      }

      // Parse record index
      final recordIndices = <StoreIndex>[];
      final lines = indexContent.split('\n');
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final storeIndex = StoreIndex.fromString(line);
          if (storeIndex == null) continue;
          recordIndices.add(storeIndex);
        } catch (e) {
          // Skip invalid lines
        }
      }

      // Read data file metadata
      if (!(await storage.existsFile(dataMetaPath))) {
        throw Exception('Table metadata file does not exist: $dataMetaPath');
      }

      final metaContent = await storage.readAsString(dataMetaPath);
      if (metaContent == null || metaContent.isEmpty) {
        throw Exception('Table metadata content is empty');
      }

      // Calculate total record count
      final totalRecords = recordIndices.length;
      final primaryKey = _extractPrimaryKey(tableName, fields, indexName);
      if (primaryKey == null) {
        throw Exception('Unable to determine primary key field');
      }

      // Progress report
      if (progressPort != null) {
        progressPort.send({
          'progress': 0,
          'message':
              'Start processing index: $tableName.$indexName, total records: $totalRecords'
        });
      }

      // Step 1: First preprocess some records to calculate the average record size
      const sampleSize = 100;
      final sampleCount = min(sampleSize, recordIndices.length);
      var totalSampleSize = 0;

      if (sampleCount > 0) {
        for (int i = 0; i < sampleCount; i++) {
          final storeIndex = recordIndices[i];
          try {
            // Extract record
            final record = await _extractRecord(storeIndex, storage,
                tableDataDirPath, dirTemplate, fileTemplate, maxEntriesPerDir);

            if (record != null) {
              // Estimate the serialized size of the index key
              dynamic indexKey;
              if (fields.length == 1) {
                indexKey = record[fields[0]];
              } else {
                final keyParts = <String>[];
                for (final field in fields) {
                  final value = record[field];
                  if (value != null) keyParts.add(value.toString());
                }
                indexKey = keyParts.join(':');
              }

              // Get record ID
              final recordId = storeIndex.toString();

              // Estimate serialized size
              final entrySize = _estimateEntrySize(indexKey, recordId);
              totalSampleSize += entrySize;
            }
          } catch (e) {
            // Skip invalid records
          }
        }
      }

      // Calculate average record size and adjust to safe value
      final avgEntrySize = sampleCount > 0
          ? (totalSampleSize / sampleCount).ceil()
          : 50; // Default 50 bytes

      // Add 20% safety margin
      final safeEntrySize = (avgEntrySize * 1.2).ceil();

      // Step 2: Calculate the number of required partitions
      // Estimate index total size = record count * average entry size
      final estimatedTotalSize = totalRecords * safeEntrySize;

      // Calculate the number of required partitions
      int partitionCount = (estimatedTotalSize / maxPartitionFileSize).ceil();

      // Use at least 1 partition
      partitionCount = max(1, partitionCount);

      // Use at most 8 partitions, avoid excessive parallelism
      partitionCount = min(8, partitionCount);

      // Create partition information list - use Map structure
      final partitions = List.generate(
          partitionCount,
          (index) => {
                'index': index,
                'records': <StoreIndex>[],
                'currentSize': 0,
                'processedCount': 0,
                'tree': BPlusTree(order: order, isUnique: isUnique)
              });

      // Progress report
      if (progressPort != null) {
        progressPort.send({
          'progress': 0,
          'message':
              'Create $partitionCount partitions, each partition size limit: ${maxPartitionFileSize / 1024 / 1024}MB, average record size: $safeEntrySize bytes'
        });
      }

      // Step 3: Extract and try to sort records by primary key

      // Create record processing function
      Future<Map<String, dynamic>?> processRecord(
          StoreIndex storeIndex, int index) async {
        try {
          // Extract record
          final record = await _extractRecord(storeIndex, storage,
              tableDataDirPath, dirTemplate, fileTemplate, maxEntriesPerDir);

          if (record == null) return null;

          // Extract index key
          dynamic key;
          if (fields.length == 1) {
            // Single field index
            final fieldName = fields[0];
            key = record[fieldName];
          } else {
            // Composite index
            final keyParts = <String>[];
            bool allFieldsPresent = true;

            for (final field in fields) {
              final value = record[field];
              if (value == null) {
                allFieldsPresent = false;
                break;
              }
              keyParts.add(value.toString());
            }

            if (allFieldsPresent) {
              key = keyParts.join(':');
            } else {
              return null;
            }
          }

          if (key == null) return null;

          // Record ID
          final recordId = storeIndex.toString();

          // Report progress every 5000 records
          if (progressPort != null && index % 5000 == 0) {
            progressPort.send({
              'progress': index,
              'message': 'Record pre-processing: $index/$totalRecords'
            });
          }

          return {'key': key, 'recordId': recordId};
        } catch (e) {
          // Return null when processing fails
          return null;
        }
      }

      // Batch process records
      final allRecordInfos = <Map<String, dynamic>>[];
      int totalProcessed = 0;

      // Batch load record information
      for (int i = 0; i < recordIndices.length; i += chunkSize) {
        final end = min(i + chunkSize, recordIndices.length);
        final batchIndices = recordIndices.sublist(i, end);

        // Process current batch records
        for (final storeIndex in batchIndices) {
          try {
            final result = await processRecord(storeIndex, totalProcessed);
            if (result != null) {
              // Calculate target partition
              final partitionIndex = totalProcessed % partitionCount;
              allRecordInfos.add({
                'index': storeIndex,
                'partitionIndex': partitionIndex,
                'key': result['key'],
                'recordId': result['recordId']
              });
            }
            totalProcessed++;
          } catch (e) {
            // Skip processing failed records
          }
        }

        // Delay between batches and progress report
        if (end < recordIndices.length && progressPort != null) {
          progressPort.send({
            'progress': totalProcessed,
            'message':
                'Record pre-processing progress: $totalProcessed/${recordIndices.length}'
          });
          await Future.delayed(const Duration(milliseconds: 10));
        }
      }

      // Group records by partition
      for (final recordInfo in allRecordInfos) {
        final partitionIndex = recordInfo['partitionIndex'] as int;
        final storeIndex = recordInfo['index'] as StoreIndex;
        (partitions[partitionIndex]['records'] as List<StoreIndex>)
            .add(storeIndex);
      }

      // Step 4: Process each partition in parallel
      final partitionFutures = <Future>[];
      for (int i = 0; i < partitions.length; i++) {
        final partition = partitions[i];
        // Process single partition
        final future = () async {
          final records = partition['records'] as List<StoreIndex>;
          final tree = partition['tree'] as BPlusTree;
          int processedCount = 0;

          // Process all records in the current partition
          for (int j = 0; j < records.length; j++) {
            final storeIndex = records[j];
            try {
              // Extract record
              final record = await _extractRecord(
                  storeIndex,
                  storage,
                  tableDataDirPath,
                  dirTemplate,
                  fileTemplate,
                  maxEntriesPerDir);

              if (record != null) {
                // Extract index key
                dynamic indexKey;
                if (fields.length == 1) {
                  // Single field index
                  final fieldName = fields[0];
                  indexKey = record[fieldName];
                } else {
                  // Composite index
                  final keyParts = <String>[];
                  bool allFieldsPresent = true;

                  for (final field in fields) {
                    final value = record[field];
                    if (value == null) {
                      allFieldsPresent = false;
                      break;
                    }
                    keyParts.add(value.toString());
                  }

                  if (allFieldsPresent) {
                    indexKey = keyParts.join(':');
                  }
                }

                if (indexKey != null) {
                  // Record ID
                  final recordId = storeIndex.toString();
                  // Insert into B+ tree
                  await tree.insert(indexKey, recordId);
                  processedCount++;
                  partition['processedCount'] = processedCount;

                  // Report progress every 500 records
                  if (processedCount % 500 == 0 && progressPort != null) {
                    final partitionIndex = partition['index'] as int;
                    progressPort.send({
                      'progress': totalProcessed,
                      'message':
                          'Partition ${partitionIndex + 1} processing progress: $processedCount/${records.length}'
                    });
                  }
                }
              }
            } catch (e) {
              // Skip failed records
            }
          }

          // Partition processing completed
          if (progressPort != null) {
            final partitionIndex = partition['index'] as int;
            progressPort.send({
              'progress': totalProcessed,
              'message':
                  'Partition ${partitionIndex + 1} processing completed: $processedCount records'
            });
          }
        }();

        partitionFutures.add(future);
      }

      // Wait for all partition processing to complete
      await Future.wait(partitionFutures);

      // Step 5: Merge all partitions in order
      final finalTree = BPlusTree(order: order, isUnique: isUnique);

      for (int i = 0; i < partitions.length; i++) {
        final partition = partitions[i];
        final tree = partition['tree'] as BPlusTree;

        // Get the leaf node of the partition tree
        BPlusTreeNode? leafNode = tree.root;
        while (leafNode != null && !leafNode.isLeaf) {
          if (leafNode.children.isEmpty) break;
          leafNode = leafNode.children[0];
        }

        // Merge in order
        while (leafNode != null) {
          for (int j = 0; j < leafNode.keys.length; j++) {
            if (j < leafNode.values.length) {
              final key = leafNode.keys[j];
              for (final value in leafNode.values[j]) {
                await finalTree.insert(key, value);
              }
            }
          }
          leafNode = leafNode.next;

          // Short delay to avoid blocking
          await Future.delayed(const Duration(milliseconds: 1));
        }

        // Report merge progress
        if (progressPort != null) {
          progressPort.send({
            'progress': totalProcessed,
            'message': 'Merge partition progress: ${i + 1}/${partitions.length}'
          });
        }
      }

      // Calculate index value range, for range queries of numeric indexes
      dynamic minKey, maxKey;
      // Primary key index mark whether it is ordered (only set for primary key indexes)
      bool? isPrimaryKeyOrdered;

      try {
        // Only calculate range for primary key indexes
        if (indexName == 'pk_$tableName') {
          final allKeys = await finalTree.getKeys();
          if (allKeys.isNotEmpty) {
            // First try to use the isPrimaryKeyOrdered value passed from the main thread
            if (indexData.containsKey('isPrimaryKeyOrdered')) {
              isPrimaryKeyOrdered = indexData['isPrimaryKeyOrdered'] as bool?;
            }

            // If not defined or empty, default to false
            isPrimaryKeyOrdered ??= false;

            // Only calculate range when primary key is ordered
            if (isPrimaryKeyOrdered == true) {
              if (allKeys.first is num) {
                // Numeric type
                minKey = allKeys.fold(
                    allKeys.first,
                    (min, key) =>
                        ValueComparator.compare(key, min) < 0 ? key : min);
                maxKey = allKeys.fold(
                    allKeys.first,
                    (max, key) =>
                        ValueComparator.compare(key, max) > 0 ? key : max);
              } else if (allKeys.first is BigInt) {
                // BigInt type
                minKey = allKeys.fold(
                    allKeys.first,
                    (min, key) =>
                        ValueComparator.compare(key, min) < 0 ? key : min);
                maxKey = allKeys.fold(
                    allKeys.first,
                    (max, key) =>
                        ValueComparator.compare(key, max) > 0 ? key : max);
              } else if (allKeys.first is String) {
                // String type
                minKey = allKeys.fold(
                    allKeys.first,
                    (min, key) =>
                        ValueComparator.compare(key, min) < 0 ? key : min);
                maxKey = allKeys.fold(
                    allKeys.first,
                    (max, key) =>
                        ValueComparator.compare(key, max) > 0 ? key : max);
              }
            }
          }
        }
        // Normal index does not calculate any range
      } catch (e) {
        // Calculation exception, does not affect the main process
        if (progressPort != null) {
          progressPort.send({
            'progress': totalProcessed,
            'message': 'Failed to calculate index range: $e'
          });
        }
      }

      // Serialize B+ tree to file
      final serialized = finalTree.toStringHandle();

      // Create partition directory
      await storage.ensureDirectoryExists(partitionDirPath);

      // Write to partition file
      await storage.writeAsString(partitionPath, serialized);

      // Calculate checksum
      final checksum = _calculateChecksumStatic(serialized);

      // Update index metadata
      final meta = IndexMeta.fromJson(jsonDecode(metaJson));

      final newPartition = IndexPartitionMeta(
        version: 1,
        index: 0,
        fileSizeInBytes: serialized.length,
        minKey: minKey,
        maxKey: maxKey,
        bTreeSize: serialized.length,
        entries: finalTree.count(),
        timestamps: Timestamps(
          created: DateTime.now(),
          modified: DateTime.now(),
        ),
        checksum: checksum,
      );

      final updatedMeta = meta.copyWith(
        partitions: [newPartition],
        timestamps: Timestamps(
          created: meta.timestamps.created,
          modified: DateTime.now(),
        ),
        // Only set ordered mark for primary key indexes
        isOrdered: indexName == 'pk_$tableName' ? isPrimaryKeyOrdered : null,
      );

      // Write updated index metadata
      await storage.writeAsString(
          indexMetaPath, jsonEncode(updatedMeta.toJson()));

      // Close storage adapter before exiting Isolate
      await storage.close();

      // Send success message and updated metadata
      sendPort.send({
        'success': true,
        'count': totalProcessed,
        'meta': jsonEncode(updatedMeta.toJson()),
      });
    } catch (e, stack) {
      // Send error message
      sendPort.send({
        'error': '$e\n$stack',
      });
    } finally {
      // Ensure resources are closed
      Isolate.exit(sendPort);
    }
  }

  /// Static checksum calculation method, for Isolate use
  static String _calculateChecksumStatic(String content) {
    // Use simple hash value as checksum
    final hash = content.hashCode;
    return hash.toRadixString(16).padLeft(8, '0');
  }

  /// Estimate the serialized size of index items
  static int _estimateEntrySize(dynamic key, String recordId) {
    // Key serialization size
    int keySize = 0;
    if (key == null) {
      keySize = 4; // null represents 4 bytes
    } else if (key is int) {
      keySize = 8; // Assuming integer is 8 bytes
    } else if (key is double) {
      keySize = 8; // double is 8 bytes
    } else if (key is String) {
      keySize =
          key.length * 2; // UTF-16 encoding, each character occupies 2 bytes
    } else {
      keySize = key.toString().length * 2; // Convert to string for processing
    }

    // recordId size
    final recordIdSize = recordId.length;

    // B+ tree internal data structure overhead estimate
    const overhead = 20;

    return keySize + recordIdSize + overhead;
  }

  /// Extract record from storage
  static Future<Map<String, dynamic>?> _extractRecord(
      StoreIndex storeIndex,
      StorageAdapter storage,
      String tableDataDirPath,
      String dirTemplate,
      String fileTemplate,
      int maxEntriesPerDir) async {
    try {
      // Build partition file path
      final partitionId = storeIndex.partitionId;
      final dirIndex = partitionId ~/ maxEntriesPerDir;
      final dirPath = dirTemplate.replaceAll('{dirIndex}', dirIndex.toString());
      final fileName =
          fileTemplate.replaceAll('{partitionId}', partitionId.toString());
      final recordPartitionPath = pathJoin(tableDataDirPath, dirPath, fileName);

      // Read partition file
      if (!(await storage.existsFile(recordPartitionPath))) {
        return null;
      }

      // Read and decode byte data
      final bytes = await storage.readAsBytes(recordPartitionPath);
      if (bytes.isEmpty) return null;

      final decodedString = await EncoderHandler.decode(bytes);
      if (decodedString.isEmpty) return null;

      // Parse JSON content
      Map<String, dynamic> partitionData;
      try {
        partitionData = jsonDecode(decodedString);
      } catch (e) {
        return null;
      }

      // Try to extract record
      Map<String, dynamic>? record;

      // Try to extract from PartitionInfo format
      if (partitionData.containsKey('data') && partitionData['data'] is List) {
        final recordsList = partitionData['data'] as List;
        if (storeIndex.offset < recordsList.length) {
          record = recordsList[storeIndex.offset] as Map<String, dynamic>;
        }
      }

      return record;
    } catch (e) {
      return null;
    }
  }

  /// Extract primary key field name (Isolate helper method)
  static String? _extractPrimaryKey(
      String tableName, List<String> fields, String indexName) {
    // For primary key index, return the field directly
    if (indexName == 'pk_$tableName' && fields.isNotEmpty) {
      return fields[0];
    }

    // Other cases, possibly need to get from configuration
    return 'id'; // Assuming default primary key is id
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
        _indexWriteBuffer.remove(cacheKey);
        _indexCache.remove(cacheKey);
        _indexFullyCached.remove(cacheKey);
        _indexDeleteBuffer.remove(cacheKey);

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
        if (!_indexWriteBuffer.containsKey(cacheKey)) {
          _indexWriteBuffer[cacheKey] = {
            'entries': <dynamic, Set<dynamic>>{},
            'lastUpdate': DateTime.now()
          };
        }

        // Merge updates
        final queueData = _indexWriteBuffer[cacheKey]!;
        final entries = queueData['entries'] as Map<dynamic, Set<dynamic>>;

        for (final keyEntry in updates.entries) {
          final key = keyEntry.key;
          final values = keyEntry.value;

          if (!entries.containsKey(key)) {
            entries[key] = {};
          }

          entries[key]!.addAll(values);
        }

        _indexWriteBuffer[cacheKey]!['lastUpdate'] = DateTime.now();
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
    final keysToCheck = <String>[..._indexWriteBuffer.keys];
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
    _indexWriteBuffer.removeWhere((key, _) => !globalKeysToKeep.contains(key));

    // same as above, handle delete buffer
    final deleteKeysToCheck = <String>[..._indexDeleteBuffer.keys];
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

    _indexDeleteBuffer
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

  /// Range query (only primary key index does range optimization)
  Future<List<String>> searchRange(
      String tableName, String indexName, dynamic startValue, dynamic endValue,
      {bool includeStart = true,
      bool includeEnd = true,
      int? limit,
      int? offset}) async {
    try {
      // Check if index metadata exists
      final meta = await _getIndexMeta(tableName, indexName);
      if (meta == null) {
        throw Exception('Index metadata does not exist');
      }

      // Only check type compatibility when it is a primary key index
      bool isPrimaryKey = indexName == 'pk_$tableName';
      if (isPrimaryKey && startValue != null && endValue != null) {
        // Check type compatibility
        bool isCompatible = false;

        // Numeric type comparison
        if ((startValue is num && endValue is num) ||
            (startValue is BigInt && endValue is BigInt)) {
          isCompatible = true;
        }
        // String type comparison
        else if (startValue is String && endValue is String) {
          isCompatible = true;
        }
        // Mixed type processing (convert to same type)
        else if ((startValue is int && endValue is BigInt) ||
            (startValue is BigInt && endValue is int)) {
          // int and BigInt can be compared
          isCompatible = true;
        }

        if (!isCompatible) {
          throw Exception(
              'Start and end value types are not compatible for range query');
        }
      }

      // Result collection
      final results = <String>{};

      // Determine the partitions to query
      final partitionsToSearch = <IndexPartitionMeta>[];

      if (isPrimaryKey) {
        // Primary key index - get ordered mark from metadata
        bool isOrdered;

        // 1. First check if the ordered mark is cached in metadata
        if (meta.isOrdered != null) {
          isOrdered = meta.isOrdered!;
        } else {
          // 2. If not cached, calculate if the primary key is ordered
          final tableSchema = await _dataStore.getTableSchema(tableName);
          if (tableSchema == null) {
            return [];
          }
          isOrdered = _isPrimaryKeyOrdered(tableSchema);

          // 3. Update metadata cache to avoid repeating calculations next time
          final updatedMeta = meta.copyWith(isOrdered: isOrdered);
          final metaPath = await _dataStore.pathManager
              .getIndexMetaPath(tableName, indexName);
          await _dataStore.storage
              .writeAsString(metaPath, jsonEncode(updatedMeta.toJson()));

          // Update cache
          final cacheKey = _getIndexCacheKey(tableName, indexName);
          _indexMetaCache[cacheKey] = updatedMeta;
        }

        // Only use range optimization for ordered primary key indexes
        if (isOrdered) {
          for (final partition in meta.partitions) {
            // Partitions without range information need to be scanned
            if (partition.minKey == null || partition.maxKey == null) {
              partitionsToSearch.add(partition);
              continue;
            }

            // Check if the partition is in the query range
            bool shouldSearchPartition =
                _isPartitionInRange(partition, startValue, endValue);
            if (shouldSearchPartition) {
              partitionsToSearch.add(partition);
            }
          }
        } else {
          // Unordered primary key index, need to scan all partitions
          partitionsToSearch.addAll(meta.partitions);
        }
      } else {
        // Normal index - completely unordered, must scan all partitions
        partitionsToSearch.addAll(meta.partitions);
      }

      // Scan each needed partition
      for (final partition in partitionsToSearch) {
        final partitionPath = await _dataStore.pathManager
            .getIndexPartitionPath(tableName, indexName, partition.index);

        if (!await _dataStore.storage.existsFile(partitionPath)) {
          continue;
        }

        // Check if the index is in the memory cache
        final cacheKey = _getIndexCacheKey(tableName, indexName);
        BPlusTree? btree = _indexCache[cacheKey];

        if (btree == null) {
          // Load the B+ tree of this partition from the file
          final content =
              await _dataStore.storage.readAsString(partitionPath) ?? '';
          if (content.isEmpty) continue;

          btree = BPlusTree.fromString(
            content,
            order: meta.bTreeOrder,
            isUnique: meta.isUnique,
          );
        }

        // Use B+ tree for range search
        final rangeResults = await btree.searchRange(
          startValue,
          endValue,
          includeStart: includeStart,
          includeEnd: includeEnd,
        );

        results.addAll(rangeResults.map((e) => e.toString()));
      }

      // Apply pagination limit
      final resultList = results.toList();

      if (offset != null && offset > 0) {
        if (offset >= resultList.length) {
          return [];
        }
        if (limit != null) {
          return resultList.sublist(
              offset, min(offset + limit, resultList.length));
        }
        return resultList.sublist(offset);
      }

      if (limit != null) {
        return resultList.take(limit).toList();
      }

      return resultList;
    } catch (e) {
      Logger.error('Range query failed: $e', label: 'IndexManager.searchRange');
      return [];
    }
  }

  /// Get data index file path
  Future<String> _getDataIndexPath(String tableName) async {
    final dataPath = await _dataStore.pathManager.getDataDirPath(tableName);
    return pathJoin(dataPath, 'index.dat');
  }

  /// Process weight decay calculation for all indexes
  /// Only executed once per day, using Isolate to avoid blocking the main thread
  Future<void> processIndexWeights() async {
    try {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);

      // Check last processing time, if today has been processed, skip
      final spaceConfig = await _dataStore.getSpaceConfig();
      final lastProcessTime = spaceConfig?.lastIndexWeightProcessTime;
      if (lastProcessTime != null) {
        final lastProcessDay = DateTime(
            lastProcessTime.year, lastProcessTime.month, lastProcessTime.day);

        if (lastProcessDay.isAtSameMomentAs(today)) {
          return; // Today has been processed, skip
        }
      }

      // Use Isolate to process weight calculation
      await _processWeightsWithIsolate();

      Logger.debug('Index weight processing completed',
          label: 'IndexManager.processIndexWeights');
    } catch (e) {
      Logger.error('Process index weight failed: $e',
          label: 'IndexManager.processIndexWeights');
    }
  }

  /// Use Isolate to process weight calculation
  Future<void> _processWeightsWithIsolate() async {
    if (_indexAccessWeights.length < 10) {
      await _calculateWeightsDecay();
      return;
    }

    // For WASM platforms, use the main thread instead of Isolate
    if (isWasmPlatform) {
      Logger.info(
          'Running on WASM platform, using main thread for weight processing',
          label: 'IndexManager._processWeightsWithIsolate');
      await _calculateWeightsDecay();
      return;
    }

    try {
      // Prepare data to pass to Isolate
      final weightsData = <String, Map<String, dynamic>>{};
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);

      // Only process existing weight data, no need to traverse all indexes
      for (final entry in _indexAccessWeights.entries) {
        // Ensure the weight data has the lastAccess field, if not use default value
        final lastAccess = entry.value['lastAccess'] as DateTime? ?? now;
        final lastWeightUpdate =
            entry.value['lastWeightUpdate'] as DateTime? ?? today;
        final weight = entry.value['weight'] as int? ?? 1;

        // Ensure the weight data is complete
        entry.value['lastAccess'] = lastAccess;
        entry.value['lastWeightUpdate'] = lastWeightUpdate;
        entry.value['weight'] = weight;

        weightsData[entry.key] = {
          'weight': weight,
          'lastAccess': lastAccess.toIso8601String(),
          'lastWeightUpdate': lastWeightUpdate.toIso8601String(),
        };
      }

      // Create send and receive ports
      final receivePort = ReceivePort();
      await Isolate.spawn(_weightsIsolate, {
        'weightsData': weightsData,
        'sendPort': receivePort.sendPort,
      });

      // Wait for Isolate to process results
      final updatedWeights =
          await receivePort.first as Map<String, Map<String, dynamic>>;

      // Update weight data
      for (final entry in updatedWeights.entries) {
        final key = entry.key;
        final data = entry.value;

        if (_indexAccessWeights.containsKey(key)) {
          _indexAccessWeights[key] = {
            'weight': data['weight'],
            'lastAccess': DateTime.parse(data['lastAccess']),
            'lastWeightUpdate': DateTime.parse(data['lastWeightUpdate']),
          };
        }
      }
    } catch (e) {
      Logger.error('Use Isolate to calculate weight failed: $e',
          label: 'IndexManager._processWeightsWithIsolate');
      // If Isolate fails, fall back to main thread calculation
      await _calculateWeightsDecay();
    }
  }

  /// Weight calculation Isolate static method
  static void _weightsIsolate(Map<String, dynamic> data) {
    final weightsData =
        data['weightsData'] as Map<String, Map<String, dynamic>>;
    final sendPort = data['sendPort'] as SendPort;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final results = <String, Map<String, dynamic>>{};

    // Batch process weight calculation
    const batchSize = 50; // Number of indexes processed per batch
    final keys = weightsData.keys.toList();

    for (var i = 0; i < keys.length; i += batchSize) {
      final end = (i + batchSize < keys.length) ? i + batchSize : keys.length;
      final batch = keys.sublist(i, end);

      for (final key in batch) {
        final weightData = weightsData[key]!;
        final lastAccess = DateTime.parse(weightData['lastAccess']);
        final currentWeight = weightData['weight'] as int;

        // Calculate time decay
        final daysSinceLastAccess = now.difference(lastAccess).inDays;

        // Weight decay strategy
        int newWeight = currentWeight;

        // Only decay if it has not been accessed for more than 2 days
        if (daysSinceLastAccess >= 2) {
          // Standard decay value: subtract 3 points each time
          int decayAmount = 3;

          // Apply fixed value decay
          newWeight = currentWeight - decayAmount;
        }

        newWeight = max(0, newWeight);

        results[key] = {
          'weight': newWeight,
          'lastAccess': lastAccess.toIso8601String(),
          'lastWeightUpdate': today.toIso8601String(),
        };
      }
    }

    sendPort.send(results);
  }

  /// Calculate weight decay in the main thread
  Future<void> _calculateWeightsDecay() async {
    try {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);

      // Batch process, avoid blocking the main thread
      const batchSize = 20;
      final keys = _indexAccessWeights.keys.toList();

      for (var i = 0; i < keys.length; i += batchSize) {
        final end = (i + batchSize < keys.length) ? i + batchSize : keys.length;
        final batch = keys.sublist(i, end);

        for (final key in batch) {
          final weightData = _indexAccessWeights[key]!;

          // Fix missing data as needed
          final lastAccess = weightData['lastAccess'] as DateTime? ?? now;
          final currentWeight = weightData['weight'] as int? ?? 1;

          // Update weight data to ensure completeness
          weightData['lastAccess'] = lastAccess;
          weightData['lastWeightUpdate'] =
              weightData['lastWeightUpdate'] ?? today;
          weightData['weight'] = currentWeight;

          // Calculate time decay
          final daysSinceLastAccess = now.difference(lastAccess).inDays;

          // Weight decay logic
          int newWeight = currentWeight;

          // Only decay if it has not been accessed for more than 2 days
          if (daysSinceLastAccess >= 2) {
            // Standard decay value: subtract 3 points each time
            int decayAmount = 3;

            newWeight = currentWeight - decayAmount;
          }

          newWeight = max(0, newWeight);

          _indexAccessWeights[key] = {
            'weight': newWeight,
            'lastAccess': lastAccess,
            'lastWeightUpdate': today,
          };
        }

        // Wait briefly after each batch to avoid long blocking
        await Future.delayed(const Duration(milliseconds: 5));
      }
    } catch (e) {
      Logger.error('Calculate weight decay in the main thread failed: $e',
          label: 'IndexManager._calculateWeightsDecay');
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

  /// Check if the partition is in the query range (only for primary key indexes)
  bool _isPartitionInRange(
      IndexPartitionMeta partition, dynamic startValue, dynamic endValue) {
    // Null value processing
    if (startValue == null && endValue == null) return true;

    try {
      // Get the range of the partition
      final minKey = partition.minKey;
      final maxKey = partition.maxKey;

      if (minKey == null || maxKey == null) {
        // If the partition has no range information, return true conservatively
        return true;
      }

      // All types of comparison logic
      if (endValue != null) {
        bool minKeyLessThanEnd = ValueComparator.compare(minKey, endValue) <= 0;
        if (!minKeyLessThanEnd) return false;
      }

      if (startValue != null) {
        bool maxKeyGreaterThanStart =
            ValueComparator.compare(maxKey, startValue) >= 0;
        if (!maxKeyGreaterThanStart) return false;
      }

      return true;
    } catch (e) {
      // If comparison fails, return true conservatively (includes this partition)
      return true;
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

  /// Build index on the main thread (for WASM platform or small data)
  Future<void> _buildIndexOnMainThread(String tableName, String indexName,
      List<String> fields, IndexMeta meta) async {
    try {
      Logger.debug('Building index on main thread: $tableName.$indexName',
          label: 'IndexManager._buildIndexOnMainThread');

      // Create B+ tree
      final btree = BPlusTree(
        order: meta.bTreeOrder,
        isUnique: meta.isUnique,
      );

      // Get table schema
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
        throw Exception('Table schema not found: $tableName');
      }

      final primaryKey = schema.primaryKey;
      final isGlobal = schema.isGlobal;

      // Process records in smaller batches
      int totalProcessed = 0;
      const chunkSize = 200; // Smaller batch size for WASM

      // Get table metadata
      final fileMeta =
          await _dataStore.tableDataManager.getTableFileMeta(tableName);

      int? clusterId;
      int? nodeId;
      if (_dataStore.config.distributedNodeConfig.enableDistributed) {
        clusterId = _dataStore.config.distributedNodeConfig.clusterId;
        nodeId = _dataStore.config.distributedNodeConfig.nodeId;
      }

      if (fileMeta != null &&
          fileMeta.partitions != null &&
          fileMeta.partitions!.isNotEmpty) {
        // Process all partitions
        for (final partition in fileMeta.partitions!) {
          // Report progress
          Logger.info('Processing partition ${partition.index}',
              label: 'IndexManager._buildIndexOnMainThread');

          // Read partition data in chunks
          int offset = 0;
          while (true) {
            // Read a chunk of records
            final records = await _dataStore.tableDataManager
                .readRecordsFromPartition(
                    tableName, isGlobal, partition.index, primaryKey);

            if (records.isEmpty) break;

            // Apply manual offset and limit as the method doesn't support them directly
            final startIndex = offset;
            final endIndex = min(offset + chunkSize, records.length);
            final chunkRecords = records.sublist(startIndex, endIndex);

            // Process records in this chunk
            for (var i = 0; i < chunkRecords.length; i++) {
              final record = chunkRecords[i];
              final primaryValue = record[primaryKey];
              if (primaryValue == null) continue;

              // Create record pointer
              final recordPointer = await StoreIndex.create(
                  offset: offset + i,
                  partitionId: partition.index,
                  clusterId: clusterId,
                  nodeId: nodeId);

              final recordId = recordPointer.toString();

              // Process fields
              if (fields.length == 1) {
                // Single field index
                final fieldName = fields[0];
                final fieldValue = record[fieldName];

                if (fieldValue != null) {
                  await btree.insert(fieldValue, recordId);
                }
              } else {
                // Composite index
                final compositeKey = _createIndexKey(record, fields);
                if (compositeKey != null) {
                  await btree.insert(compositeKey, recordId);
                }
              }

              totalProcessed++;
            }

            // Move to next chunk
            offset += records.length;

            // Report progress periodically
            if (totalProcessed % 1000 == 0) {
              Logger.info('Processed $totalProcessed records',
                  label: 'IndexManager._buildIndexOnMainThread');
            }

            // Add small delays between chunks to avoid blocking UI
            await Future.delayed(const Duration(milliseconds: 10));
          }
        }
      } else {
        // When there is no partition data, read directly using stream
        await for (final record
            in _dataStore.tableDataManager.streamRecords(tableName)) {
          final primaryValue = record[primaryKey];
          if (primaryValue == null) continue;

          // Create record pointer (approximate as we don't have position info)
          final recordPointer = await StoreIndex.create(
              offset: totalProcessed,
              partitionId: 0,
              clusterId: clusterId,
              nodeId: nodeId);

          final recordId = recordPointer.toString();

          // Process fields
          if (fields.length == 1) {
            // Single field index
            final fieldName = fields[0];
            final fieldValue = record[fieldName];

            if (fieldValue != null) {
              await btree.insert(fieldValue, recordId);
            }
          } else {
            // Composite index
            final compositeKey = _createIndexKey(record, fields);
            if (compositeKey != null) {
              await btree.insert(compositeKey, recordId);
            }
          }

          totalProcessed++;

          // Report progress periodically
          if (totalProcessed % 1000 == 0) {
            Logger.info('Processed $totalProcessed records',
                label: 'IndexManager._buildIndexOnMainThread');

            // Add small delays to avoid blocking UI
            await Future.delayed(const Duration(milliseconds: 5));
          }
        }
      }

      // Calculate index value range (for primary key indexes)
      dynamic minKey, maxKey;
      bool? isPrimaryKeyOrdered;

      if (indexName == 'pk_$tableName') {
        // For primary key index, check if ordered
        isPrimaryKeyOrdered = _isPrimaryKeyOrdered(schema);

        if (isPrimaryKeyOrdered) {
          try {
            final allKeys = await btree.getKeys();
            if (allKeys.isNotEmpty) {
              minKey = _calculateMinKey(allKeys);
              maxKey = _calculateMaxKey(allKeys);
            }
          } catch (e) {
            Logger.error('Failed to calculate index range: $e',
                label: 'IndexManager._buildIndexOnMainThread');
          }
        }
      }

      // Serialize B+ tree
      final serialized = btree.toStringHandle();

      // Create partition directory
      final partitionDirPath = await _dataStore.pathManager
          .getIndexPartitionDirPath(tableName, indexName, 0);
      await _dataStore.storage.ensureDirectoryExists(partitionDirPath);

      // Write partition file
      final partitionPath = await _dataStore.pathManager
          .getIndexPartitionPath(tableName, indexName, 0);
      await _dataStore.storage.writeAsString(partitionPath, serialized);

      // Calculate checksum
      final checksum = _calculateChecksum(serialized);

      // Create partition metadata
      final newPartition = IndexPartitionMeta(
        version: 1,
        index: 0,
        fileSizeInBytes: serialized.length,
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

      // Update index metadata
      final updatedMeta = meta.copyWith(
        partitions: [newPartition],
        timestamps: Timestamps(
          created: meta.timestamps.created,
          modified: DateTime.now(),
        ),
        isOrdered: indexName == 'pk_$tableName' ? isPrimaryKeyOrdered : null,
      );

      // Write metadata file
      final metaPath =
          await _dataStore.pathManager.getIndexMetaPath(tableName, indexName);
      await _dataStore.storage
          .writeAsString(metaPath, jsonEncode(updatedMeta.toJson()));

      // Update cache
      final cacheKey = _getIndexCacheKey(tableName, indexName);
      _indexMetaCache[cacheKey] = updatedMeta;
      _indexCache[cacheKey] = btree;
      _indexFullyCached[cacheKey] = true;

      Logger.info(
          'Index build on main thread completed: $totalProcessed records processed',
          label: 'IndexManager._buildIndexOnMainThread');
    } catch (e) {
      Logger.error('Failed to build index on main thread: $e',
          label: 'IndexManager._buildIndexOnMainThread');
      rethrow;
    }
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

      // Check if the entry is in delete buffer - if so, cancel out the operations
      if (_indexDeleteBuffer.containsKey(cacheKey)) {
        final deleteData = _indexDeleteBuffer[cacheKey]!;
        final deleteEntries =
            deleteData['entries'] as Map<dynamic, Set<dynamic>>?;

        if (deleteEntries != null && deleteEntries.containsKey(key)) {
          // Found matching key in delete buffer, check for matching record ID
          if (deleteEntries[key]!.contains(storeIndexStr)) {
            // Entry is in delete buffer, remove it from there instead of adding to insert buffer
            deleteEntries[key]!.remove(storeIndexStr);

            // If the key set is empty, remove the key
            if (deleteEntries[key]!.isEmpty) {
              deleteEntries.remove(key);
            }

            // Update last write time
            _indexDeleteBuffer[cacheKey]!['lastUpdate'] = DateTime.now();
            _indexLastWriteTime[cacheKey] = DateTime.now();

            return; // Operations cancel out, no need to add to insert buffer
          }
        }
      }

      // Initialize insert buffer
      if (!_indexWriteBuffer.containsKey(cacheKey)) {
        _indexWriteBuffer[cacheKey] = {
          'entries': <dynamic, Set<dynamic>>{},
          'lastUpdate': DateTime.now()
        };
      }

      final queueData = _indexWriteBuffer[cacheKey]!;

      Map<dynamic, Set<dynamic>> entries;
      try {
        if (queueData['entries'] == null ||
            (queueData['entries'] as Map).isEmpty) {
          queueData['entries'] = <dynamic, Set<dynamic>>{};
        }
        entries = queueData['entries'] as Map<dynamic, Set<dynamic>>;
      } catch (e) {
        Logger.error('Insert buffer data format error: $e',
            label: 'IndexManager._addToInsertBuffer');
        // Reset buffer
        _indexWriteBuffer[cacheKey] = {
          'entries': <dynamic, Set<dynamic>>{},
          'lastUpdate': DateTime.now()
        };
        entries = _indexWriteBuffer[cacheKey]!['entries']
            as Map<dynamic, Set<dynamic>>;
      }

      // Add entry
      if (!entries.containsKey(key)) {
        entries[key] = <dynamic>{};
      }

      if (!entries[key]!.contains(storeIndexStr)) {
        entries[key]!.add(storeIndexStr);
      }

      _indexWriteBuffer[cacheKey]!['lastUpdate'] = DateTime.now();

      // Check buffer size, enable fast processing mode when any buffer reaches the threshold
      if (!_fastProcessEnabled && entries.length >= _fastProcessThreshold) {
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

      // Check if the entry is in insert buffer - if so, cancel out the operations
      if (_indexWriteBuffer.containsKey(cacheKey)) {
        final insertData = _indexWriteBuffer[cacheKey]!;
        final insertEntries =
            insertData['entries'] as Map<dynamic, Set<dynamic>>?;

        if (insertEntries != null && insertEntries.containsKey(key)) {
          // Found matching key in insert buffer, check for matching record ID
          if (insertEntries[key]!.contains(storeIndexStr)) {
            // Entry is in insert buffer, remove it from there instead of adding to delete buffer
            insertEntries[key]!.remove(storeIndexStr);

            // If the key set is empty, remove the key
            if (insertEntries[key]!.isEmpty) {
              insertEntries.remove(key);
            }

            // Update last write time
            _indexWriteBuffer[cacheKey]!['lastUpdate'] = DateTime.now();
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
        }
      }

      // Initialize delete buffer
      if (!_indexDeleteBuffer.containsKey(cacheKey)) {
        _indexDeleteBuffer[cacheKey] = {
          'entries': <dynamic, Set<dynamic>>{},
          'lastUpdate': DateTime.now()
        };
      }

      final queueData = _indexDeleteBuffer[cacheKey]!;

      Map<dynamic, Set<dynamic>> entries;
      try {
        if (queueData['entries'] == null ||
            (queueData['entries'] as Map).isEmpty) {
          queueData['entries'] = <dynamic, Set<dynamic>>{};
        }
        entries = queueData['entries'] as Map<dynamic, Set<dynamic>>;
      } catch (e) {
        Logger.error('Delete buffer data format error: $e',
            label: 'IndexManager._addToDeleteBuffer');
        // Reset buffer
        _indexDeleteBuffer[cacheKey] = {
          'entries': <dynamic, Set<dynamic>>{},
          'lastUpdate': DateTime.now()
        };
        entries = _indexDeleteBuffer[cacheKey]!['entries']
            as Map<dynamic, Set<dynamic>>;
      }

      // Add entry
      if (!entries.containsKey(key)) {
        entries[key] = <dynamic>{};
      }

      if (!entries[key]!.contains(storeIndexStr)) {
        entries[key]!.add(storeIndexStr);
      }

      _indexDeleteBuffer[cacheKey]!['lastUpdate'] = DateTime.now();

      // Also remove from memory cache if it exists
      if (_indexCache.containsKey(cacheKey)) {
        try {
          await _indexCache[cacheKey]!.delete(key, storeIndexStr);
        } catch (e) {
          // Ignore errors in memory cache update
          Logger.warn('Failed to update memory cache for deletion: $e',
              label: 'IndexManager._addToDeleteBuffer');
        }
      }

      // Record last write time
      _indexLastWriteTime[cacheKey] = DateTime.now();
    } catch (e, stack) {
      Logger.error('Failed to add index entry to delete buffer: $e\n$stack',
          label: 'IndexManager._addToDeleteBuffer');
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
      _indexWriteBuffer.remove(cacheKey);
      _indexDeleteBuffer.remove(cacheKey);
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
