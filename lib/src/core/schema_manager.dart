import 'dart:convert';
import 'package:path/path.dart' show dirname;
import '../model/meta_info.dart';
import '../model/table_schema.dart';
import '../model/system_table.dart';
import '../handler/logger.dart';
import 'data_store_impl.dart';
import 'tree_cache.dart';

/// table schema manager
class SchemaManager {
  final DataStoreImpl _dataStore;
  SchemaMeta? _schemaMeta; // Cache schema meta

  /// Hot schema cache (TableSchema) using [TreeCache].
  /// Managed by MemoryManager quota: [MemoryQuotaType.schema].
  TreeCache<TableSchema>? _tableSchemaCache;

  // Directory mapping cache for schema partitions
  DirectoryMapping? _directoryMapping;
  int _currentPartitionDirIndex = 0;

  // Loading futures to prevent thundering herd on concurrent schema reads
  final Map<String, Future<TableSchema?>> _schemaLoadingFutures = {};

  SchemaManager(this._dataStore);

  TreeCache<TableSchema> _ensureTableSchemaCache() {
    final existing = _tableSchemaCache;
    if (existing != null) return existing;

    final int maxBytes =
        _dataStore.memoryManager?.getSchemaCacheSize() ?? (50 * 1024 * 1024);
    final int minBytes = 50 * 1024 * 1024;

    final cache = TreeCache<TableSchema>(
      sizeCalculator: _estimateTableSchemaSize,
      maxByteThreshold: maxBytes,
      minByteThreshold: minBytes,
    );
    _tableSchemaCache = cache;
    return cache;
  }

  /// Get cached [TableSchema] if present (O(1)).
  TableSchema? getCachedTableSchema(String tableName) {
    return _tableSchemaCache?.get(tableName);
  }

  /// Cache [TableSchema] into hotspot cache.
  void cacheTableSchema(String tableName, TableSchema schema) {
    _ensureTableSchemaCache().put(tableName, schema);
  }

  /// Remove cached schema for [tableName].
  void removeCachedTableSchema(String tableName) {
    _tableSchemaCache?.remove(tableName);
  }

  /// Current schema cache size in bytes (incremental tracked).
  int getCurrentSchemaCacheSize() {
    return _tableSchemaCache?.estimatedTotalSizeBytes ?? 0;
  }

  /// Evict a ratio of schema cache entries under memory pressure.
  Future<void> evictSchemaCache({double ratio = 0.3}) async {
    final cache = _tableSchemaCache;
    if (cache == null) return;
    await cache.cleanup(removeRatio: ratio);
  }

  /// Clear all schema cache entries.
  Future<void> clearSchemaCache() async {
    _tableSchemaCache?.clear();
  }

  /// Clear all schema cache entries synchronously (used on shutdown).
  void clearSchemaCacheSync() {
    _tableSchemaCache?.clear();
  }

  int _estimateTableSchemaSize(TableSchema schema) {
    // Lightweight approximation (avoid jsonEncode for hot paths).
    int size = 256;
    size += schema.name.length * 2;
    size += schema.primaryKey.length * 2;
    size += 64;

    // Fields
    if (schema.fields.isNotEmpty) {
      size += schema.fields.length * 140;
      for (final f in schema.fields) {
        size += f.name.length * 2;
        size += 24;
      }
    }

    // Indexes / FKs
    if (schema.indexes.isNotEmpty) {
      size += schema.indexes.length * 120;
      for (final idx in schema.indexes) {
        size += (idx.indexName?.length ?? 0) * 2;
        size += idx.fields.length * 24;
      }
    }
    if (schema.foreignKeys.isNotEmpty) {
      size += schema.foreignKeys.length * 180;
      for (final fk in schema.foreignKeys) {
        size += fk.actualName.length * 2;
        size += fk.referencedTable.length * 2;
        size += fk.referencedFields.length * 24;
      }
    }

    return size;
  }

  /// get database schema meta
  Future<SchemaMeta> getSchemaMeta() async {
    if (_schemaMeta != null) {
      // Warm cache if needed
      if (_directoryMapping == null && _schemaMeta!.directoryMapping != null) {
        _directoryMapping = _schemaMeta!.directoryMapping;
        if (_directoryMapping!.dirToFileCount.isNotEmpty) {
          _currentPartitionDirIndex = _directoryMapping!.dirToFileCount.keys
              .reduce((a, b) => a > b ? a : b);
        }
      }
      return _schemaMeta!;
    }

    final path = _dataStore.pathManager.getSchemaMetaPath();
    if (await _dataStore.storage.existsFile(path)) {
      final content = await _dataStore.storage.readAsString(path);
      if (content != null && content.isNotEmpty) {
        try {
          _schemaMeta = SchemaMeta.fromJson(jsonDecode(content));
          // Warm cache
          if (_schemaMeta!.directoryMapping != null) {
            _directoryMapping = _schemaMeta!.directoryMapping;
            if (_directoryMapping!.dirToFileCount.isNotEmpty) {
              _currentPartitionDirIndex = _directoryMapping!.dirToFileCount.keys
                  .reduce((a, b) => a > b ? a : b);
            }
          } else {
            _directoryMapping = DirectoryMapping();
          }
          return _schemaMeta!;
        } catch (e) {
          Logger.error('Failed to load schema meta: $e',
              label: 'SchemaManager.loadSchemaMeta');
        }
      }
    }

    // Create new structure meta
    _schemaMeta = SchemaMeta(
      version: 1,
      tablePartitionMap: {},
      timestamps: Timestamps(
        created: DateTime.now(),
        modified: DateTime.now(),
      ),
    );
    _directoryMapping = DirectoryMapping();

    await saveSchemaStructure();
    return _schemaMeta!;
  }

  /// save database schema meta
  Future<void> saveSchemaStructure() async {
    if (_schemaMeta == null) return;

    // Update directory mapping in meta if cache exists
    if (_directoryMapping != null) {
      _schemaMeta = _schemaMeta!.copyWith(directoryMapping: _directoryMapping);
    }

    final path = _dataStore.pathManager.getSchemaMetaPath();
    await _dataStore.storage.ensureDirectoryExists(dirname(path));
    await _dataStore.storage
        .writeAsString(path, jsonEncode(_schemaMeta!.toJson()));
  }

  /// get table partition index
  Future<int?> getTablePartition(String tableName) async {
    final meta = await getSchemaMeta();
    return meta.tablePartitionMap[tableName];
  }

  /// find suitable partition
  Future<int> _findSuitablePartition(SchemaMeta meta, int contentSize) async {
    try {
      // check if table exists in a partition
      for (final entry in meta.tablePartitionMap.entries) {
        final partitionIndex = entry.value; // Now it's int, not List<int>
        final partitionMeta = await _loadPartitionMeta(partitionIndex);

        if (partitionMeta != null) {
          final newSize = partitionMeta.fileSizeInBytes + contentSize;
          if (newSize <= _dataStore.config.maxPartitionFileSize) {
            return partitionIndex;
          }
        }
      }

      // find partition with enough space
      final existingPartitions = meta.tablePartitionMap.values.toSet().toList();

      for (final partitionIndex in existingPartitions) {
        final partitionMeta = await _loadPartitionMeta(partitionIndex);

        if (partitionMeta != null &&
            partitionMeta.fileSizeInBytes + contentSize <=
                _dataStore.config.maxPartitionFileSize) {
          return partitionIndex;
        }
      }

      // create new partition
      return existingPartitions.isEmpty ? 0 : existingPartitions.last + 1;
    } catch (e) {
      Logger.error(
        'Failed to find suitable partition: $e',
        label: 'SchemaManager._findSuitablePartition',
      );
      // create new partition when error
      final existingPartitions = meta.tablePartitionMap.values.toSet().toList();
      return existingPartitions.isEmpty ? 0 : existingPartitions.last + 1;
    }
  }

  /// create new partition meta
  SchemaPartitionMeta _createNewPartitionMeta(int index) {
    return SchemaPartitionMeta(
      version: 1,
      index: index,
      fileSizeInBytes: 0,
      tableNames: [],
      tableSizes: {},
      tableSchemas: {},
      timestamps: Timestamps(
        created: DateTime.now(),
        modified: DateTime.now(),
      ),
    );
  }

  /// Get or load directory mapping from cache or metadata.
  Future<DirectoryMapping> _getOrLoadDirectoryMapping() async {
    if (_directoryMapping != null) return _directoryMapping!;

    final meta = await getSchemaMeta();
    if (meta.directoryMapping != null) {
      _directoryMapping = meta.directoryMapping;
      if (_directoryMapping!.dirToFileCount.isNotEmpty) {
        _currentPartitionDirIndex = _directoryMapping!.dirToFileCount.keys
            .reduce((a, b) => a > b ? a : b);
      }
      return _directoryMapping!;
    }

    _directoryMapping = DirectoryMapping();
    return _directoryMapping!;
  }

  /// Get directory index for an existing partition.
  Future<int?> _getPartitionDirIndexForExistingPartition(
      int partitionIndex) async {
    final mapping = await _getOrLoadDirectoryMapping();
    final d = mapping.getDirIndex(partitionIndex);
    if (d != null) return d;

    // Fallback: try to load from partition meta (legacy support)
    final legacyDirIndex = partitionIndex ~/ _dataStore.maxEntriesPerDir;
    final partitionPath = _dataStore.pathManager
        .getSchemaPartitionFilePath(partitionIndex, legacyDirIndex);
    if (await _dataStore.storage.existsFile(partitionPath)) {
      final content = await _dataStore.storage.readAsString(partitionPath);
      if (content != null) {
        try {
          final meta = SchemaPartitionMeta.fromJson(jsonDecode(content));
          return meta.dirIndex;
        } catch (_) {}
      }
    }
    return null;
  }

  /// Get or allocate directory index for a partition.
  Future<int> _getOrAllocateDirIndexForPartition(int partitionIndex) async {
    final mapping = await _getOrLoadDirectoryMapping();

    // Existing mapping
    final existing = mapping.getDirIndex(partitionIndex);
    if (existing != null) return existing;

    // Allocate for new partition
    int currentDir = _currentPartitionDirIndex;
    int currentCount = mapping.getFileCount(currentDir);

    if (currentCount >= _dataStore.maxEntriesPerDir) {
      if (mapping.dirToFileCount.isNotEmpty) {
        currentDir =
            mapping.dirToFileCount.keys.reduce((a, b) => a > b ? a : b) + 1;
      } else {
        currentDir = 0;
      }
      currentCount = 0;
    }

    // Update mapping
    _directoryMapping = mapping.withPartitionAndDirCount(
        partitionIndex, currentDir, currentCount + 1);
    _currentPartitionDirIndex = currentDir;

    return currentDir;
  }

  /// load partition meta
  Future<SchemaPartitionMeta?> _loadPartitionMeta(int partitionIndex) async {
    final dirIndex =
        await _getPartitionDirIndexForExistingPartition(partitionIndex);
    if (dirIndex == null) {
      return null;
    }

    final partitionPath = _dataStore.pathManager
        .getSchemaPartitionFilePath(partitionIndex, dirIndex);
    if (!await _dataStore.storage.existsFile(partitionPath)) return null;

    final content = await _dataStore.storage.readAsString(partitionPath);
    if (content == null) return null;

    try {
      return SchemaPartitionMeta.fromJson(jsonDecode(content));
    } catch (e) {
      Logger.error('Failed to load partition meta: $e',
          label: 'SchemaPartitionManager._loadPartitionMeta');
      return null;
    }
  }

  /// save table schema, auto manage partitions
  Future<void> saveTableSchema(String tableName, TableSchema schema) async {
    try {
      final meta = await getSchemaMeta();
      final contentSize = _estimateTableSchemaSize(schema);

      // find suitable partition
      int targetPartition = await _findSuitablePartition(meta, contentSize);

      // Get or allocate directory index for this partition
      final dirIndex =
          await _getOrAllocateDirIndexForPartition(targetPartition);

      // read target partition meta
      final partitionPath = _dataStore.pathManager
          .getSchemaPartitionFilePath(targetPartition, dirIndex);
      SchemaPartitionMeta partitionMeta;

      if (await _dataStore.storage.existsFile(partitionPath)) {
        final content = await _dataStore.storage.readAsString(partitionPath);
        if (content != null) {
          partitionMeta = SchemaPartitionMeta.fromJson(jsonDecode(content));
        } else {
          partitionMeta = _createNewPartitionMeta(targetPartition);
        }
      } else {
        partitionMeta = _createNewPartitionMeta(targetPartition);
      }

      // update partition meta
      final schemaObject = schema.toJson();
      final oldSize = partitionMeta.tableSizes[tableName] ?? 0;

      // calculate new partition size (if update, subtract old size)
      final newSizeChange = partitionMeta.tableNames.contains(tableName)
          ? contentSize - oldSize
          : contentSize;

      final updatedMeta = partitionMeta.copyWith(
        fileSizeInBytes: partitionMeta.fileSizeInBytes + newSizeChange,
        tableNames: partitionMeta.tableNames.contains(tableName)
            ? partitionMeta.tableNames
            : [...partitionMeta.tableNames, tableName],
        tableSizes: {
          ...partitionMeta.tableSizes,
          tableName: contentSize,
        },
        tableSchemas: {
          ...partitionMeta.tableSchemas,
          tableName: schemaObject,
        },
        timestamps: Timestamps(
          created: partitionMeta.timestamps.created,
          modified: DateTime.now(),
        ),
      );

      // save partition file
      await _dataStore.storage.ensureDirectoryExists(dirname(partitionPath));
      await _dataStore.storage
          .writeAsString(partitionPath, jsonEncode(updatedMeta.toJson()));

      // update main meta mapping relation
      meta.tablePartitionMap[tableName] = targetPartition;
      await saveSchemaStructure();

      // Cache the new schema
      cacheTableSchema(tableName, schema);
    } catch (e) {
      Logger.error('Failed to save table schema: $tableName, $e',
          label: 'SchemaManager.saveTableSchema');
      throw Exception('Failed to save table schema: $e');
    }
  }

  /// read table schema
  Future<TableSchema?> getTableSchema(String tableName) async {
    // Fast path: check in-memory cache
    final cached = getCachedTableSchema(tableName);
    if (cached != null) return cached;

    // Check if another call is already loading this schema
    final existing = _schemaLoadingFutures[tableName];
    if (existing != null) {
      return existing;
    }

    // Start loading and register the future
    final loadFuture = _doLoadTableSchema(tableName);
    _schemaLoadingFutures[tableName] = loadFuture;
    try {
      return await loadFuture;
    } finally {
      _schemaLoadingFutures.remove(tableName);
    }
  }

  /// Internal helper to actually load schema from file.
  Future<TableSchema?> _doLoadTableSchema(String tableName) async {
    try {
      final partitionIndex = await getTablePartition(tableName);
      if (partitionIndex == null) return null;

      final dirIndex =
          await _getPartitionDirIndexForExistingPartition(partitionIndex);
      if (dirIndex == null) {
        return null;
      }

      final partitionPath = _dataStore.pathManager
          .getSchemaPartitionFilePath(partitionIndex, dirIndex);
      if (!await _dataStore.storage.existsFile(partitionPath)) return null;

      final content = await _dataStore.storage.readAsString(partitionPath);
      if (content == null) return null;

      try {
        final partitionMeta = SchemaPartitionMeta.fromJson(jsonDecode(content));
        if (!partitionMeta.tableSchemas.containsKey(tableName)) return null;

        final raw = partitionMeta.tableSchemas[tableName];
        Map<String, dynamic>? schemaMap;
        if (raw is Map<String, dynamic>) {
          schemaMap = raw;
        } else if (raw is Map) {
          schemaMap = Map<String, dynamic>.from(raw);
        } else if (raw is String) {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) {
            schemaMap = decoded;
          } else if (decoded is Map) {
            schemaMap = Map<String, dynamic>.from(decoded);
          }
        }
        if (schemaMap == null) return null;

        final schema = TableSchema.fromJson(schemaMap);
        cacheTableSchema(tableName, schema);
        return schema;
      } catch (e) {
        Logger.error('Failed to parse table schema: $tableName, $e',
            label: 'SchemaManager.getTableSchema');
        return null;
      }
    } catch (e) {
      Logger.error(
        'Failed to get table schema: $tableName, $e',
        label: 'SchemaManager.getTableSchema',
      );
      return null;
    }
  }

  /// delete table schema
  Future<bool> deleteTableSchema(String tableName) async {
    try {
      final meta = await getSchemaMeta();
      final partitionIndex = meta.tablePartitionMap[tableName];

      if (partitionIndex == null) return false;

      final success =
          await _removeTableFromPartition(tableName, partitionIndex);

      // if successfully delete table from all partitions, update meta
      if (success) {
        meta.tablePartitionMap.remove(tableName);
        await saveSchemaStructure();
        removeCachedTableSchema(tableName);
      }

      return success;
    } catch (e) {
      Logger.error(
        'Failed to delete table schema: $tableName, $e',
        label: 'SchemaManager.deleteTableSchema',
      );
      return false;
    }
  }

  /// remove table from partition
  Future<bool> _removeTableFromPartition(
      String tableName, int partitionIndex) async {
    final dirIndex =
        await _getPartitionDirIndexForExistingPartition(partitionIndex);
    if (dirIndex == null) {
      return false;
    }

    final partitionPath = _dataStore.pathManager
        .getSchemaPartitionFilePath(partitionIndex, dirIndex);
    if (!await _dataStore.storage.existsFile(partitionPath)) return false;

    final content = await _dataStore.storage.readAsString(partitionPath);
    if (content == null) return false;

    try {
      final partitionMeta = SchemaPartitionMeta.fromJson(jsonDecode(content));
      if (!partitionMeta.tableSchemas.containsKey(tableName)) return false;

      // calculate new size after deletion
      final oldSize = partitionMeta.tableSizes[tableName] ?? 0;
      final newSize = partitionMeta.fileSizeInBytes - oldSize;

      // create updated partition meta
      final updatedMeta = partitionMeta.copyWith(
        fileSizeInBytes: newSize,
        tableNames: partitionMeta.tableNames
            .where((name) => name != tableName)
            .toList(),
        tableSizes: Map.from(partitionMeta.tableSizes)..remove(tableName),
        tableSchemas: Map.from(partitionMeta.tableSchemas)..remove(tableName),
        timestamps: Timestamps(
          created: partitionMeta.timestamps.created,
          modified: DateTime.now(),
        ),
      );

      // save updated partition file
      await _dataStore.storage
          .writeAsString(partitionPath, jsonEncode(updatedMeta.toJson()));

      return true;
    } catch (e) {
      Logger.error('Failed to delete table schema: $e',
          label: 'SchemaPartitionManager.deleteTableSchema');
      return false;
    }
  }

  /// list all table names
  /// [onlyUserTables] When true, filters out system tables (like key-value store tables)
  Future<List<String>> listAllTables({bool onlyUserTables = false}) async {
    final meta = await getSchemaMeta();
    final tables = meta.tablePartitionMap.keys.toList();

    if (onlyUserTables) {
      // Filter out system tables using the SystemTable.isSystemTable method
      return tables
          .where((tableName) => !SystemTable.isSystemTable(tableName))
          .toList();
    }

    return tables;
  }

  /// get partition status, for monitoring and management
  Future<Map<String, dynamic>> getPartitionStats() async {
    try {
      // get partition basic info
      final meta = await getSchemaMeta();
      final uniquePartitions = meta.tablePartitionMap.values.toSet().toList();

      final result = <String, dynamic>{
        'totalTables': meta.tablePartitionMap.length,
        'partitionDetails': <Map<String, dynamic>>[],
      };

      if (uniquePartitions.isEmpty) {
        return result;
      }

      // collect all partition details
      final partitionDetails = <Map<String, dynamic>>[];

      for (final partitionIndex in uniquePartitions) {
        final partitionMeta = await _loadPartitionMeta(partitionIndex);
        if (partitionMeta != null) {
          partitionDetails.add({
            'index': partitionMeta.index,
            'version': partitionMeta.version,
            'currentSize': partitionMeta.fileSizeInBytes,
            'maxSize': _dataStore.config.maxPartitionFileSize,
            'usagePercentage': (partitionMeta.fileSizeInBytes /
                    _dataStore.config.maxPartitionFileSize *
                    100)
                .toStringAsFixed(2),
            'tableCount': partitionMeta.tableNames.length,
            'lastModified': partitionMeta.timestamps.modified.toIso8601String(),
          });
        }
      }

      result['partitionDetails'] = partitionDetails;
      return result;
    } catch (e) {
      Logger.error(
        'Failed to get partition stats: $e',
        label: 'SchemaManager.getPartitionStats',
      );
      return {'error': '$e', 'totalTables': 0, 'partitionDetails': []};
    }
  }

  /// optimize partitions, reassign tables to balance storage
  Future<bool> optimizePartitions() async {
    try {
      final startTime = DateTime.now();
      Logger.debug('Start partition optimization...',
          label: 'SchemaManager.optimizePartitions');

      // get meta
      final meta = await getSchemaMeta();
      if (meta.tablePartitionMap.isEmpty) {
        Logger.debug('No table info, skip optimization',
            label: 'SchemaManager.optimizePartitions');
        return true;
      }

      // get all partition info
      final uniquePartitions = meta.tablePartitionMap.values.toSet().toList();

      if (uniquePartitions.isEmpty) {
        Logger.debug('No partition info, skip optimization',
            label: 'SchemaManager.optimizePartitions');
        return true;
      }

      // collect all partition info
      int totalSize = 0;
      final partitionMetas = <int, SchemaPartitionMeta>{};

      for (final partitionIndex in uniquePartitions) {
        final partitionMeta = await _loadPartitionMeta(partitionIndex);
        if (partitionMeta != null) {
          totalSize += partitionMeta.fileSizeInBytes;
          partitionMetas[partitionIndex] = partitionMeta;
        }
      }

      if (partitionMetas.isEmpty) {
        Logger.debug('No valid partition meta, skip optimization',
            label: 'SchemaManager.optimizePartitions');
        return true;
      }

      final averageSize = totalSize / partitionMetas.length;
      const threshold = 0.2; // 20% difference threshold

      // find partitions need optimization
      final overloadedPartitions = <int>[];
      final underutilizedPartitions = <int>[];

      for (final entry in partitionMetas.entries) {
        final partitionMeta = entry.value;
        if (partitionMeta.fileSizeInBytes > averageSize * (1 + threshold)) {
          overloadedPartitions.add(entry.key);
        } else if (partitionMeta.fileSizeInBytes <
                averageSize * (1 - threshold) &&
            partitionMeta.fileSizeInBytes + averageSize * threshold <
                _dataStore.config.maxPartitionFileSize) {
          underutilizedPartitions.add(entry.key);
        }
      }

      // if no partitions need optimization, return directly
      if (overloadedPartitions.isEmpty) {
        Logger.debug(
          'No partitions need optimization, all partitions are balanced',
          label: 'SchemaManager.optimizePartitions',
        );
        return true;
      }

      // start optimization process
      final tablesMovedCount = <String>[];

      // handle overloaded partitions
      for (final overloadedIndex in overloadedPartitions) {
        if (underutilizedPartitions.isEmpty) break;

        // reload to get latest status
        final overloadedMeta = await _loadPartitionMeta(overloadedIndex);
        if (overloadedMeta == null) continue;

        final tablesToMove = <String>[];

        // select tables to move
        for (final tableName in overloadedMeta.tableNames) {
          final tableSize = overloadedMeta.tableSizes[tableName] ?? 0;
          if (tableSize > 0 &&
              tableSize < _dataStore.config.maxPartitionFileSize * 0.5) {
            tablesToMove.add(tableName);
            if (overloadedMeta.fileSizeInBytes - tableSize <= averageSize) {
              break;
            }
          }
        }

        // move tables to underutilized partitions
        for (final tableName in tablesToMove) {
          if (underutilizedPartitions.isEmpty) break;

          final tableSize = overloadedMeta.tableSizes[tableName] ?? 0;
          int targetPartition = -1;

          // find suitable target partition
          for (final underIndex in underutilizedPartitions) {
            final underMeta = partitionMetas[underIndex];
            if (underMeta != null &&
                underMeta.fileSizeInBytes + tableSize <=
                    _dataStore.config.maxPartitionFileSize) {
              targetPartition = underIndex;
              break;
            }
          }

          if (targetPartition == -1) continue;

          // get table schema
          final schema = overloadedMeta.tableSchemas[tableName];
          if (schema == null) continue;

          Logger.debug(
            'Moving table $tableName from partition $overloadedIndex to partition $targetPartition (size: $tableSize bytes)',
            label: 'SchemaManager.optimizePartitions',
          );

          // delete table from source partition
          final success =
              await _removeTableFromPartition(tableName, overloadedIndex);
          if (success) {
            // read target partition meta
            final targetDirIndex =
                await _getOrAllocateDirIndexForPartition(targetPartition);
            final targetPartitionPath = _dataStore.pathManager
                .getSchemaPartitionFilePath(targetPartition, targetDirIndex);
            SchemaPartitionMeta targetPartitionMeta;

            if (await _dataStore.storage.existsFile(targetPartitionPath)) {
              final content =
                  await _dataStore.storage.readAsString(targetPartitionPath);
              if (content != null) {
                targetPartitionMeta =
                    SchemaPartitionMeta.fromJson(jsonDecode(content));
              } else {
                targetPartitionMeta = _createNewPartitionMeta(targetPartition);
              }
            } else {
              targetPartitionMeta = _createNewPartitionMeta(targetPartition);
            }

            // update target partition meta
            final updatedMeta = targetPartitionMeta.copyWith(
              fileSizeInBytes: targetPartitionMeta.fileSizeInBytes + tableSize,
              tableNames: [...targetPartitionMeta.tableNames, tableName],
              tableSizes: {
                ...targetPartitionMeta.tableSizes,
                tableName: tableSize,
              },
              tableSchemas: {
                ...targetPartitionMeta.tableSchemas,
                tableName: schema,
              },
              timestamps: Timestamps(
                created: targetPartitionMeta.timestamps.created,
                modified: DateTime.now(),
              ),
            );

            // save target partition file
            await _dataStore.storage
                .ensureDirectoryExists(dirname(targetPartitionPath));
            await _dataStore.storage.writeAsString(
                targetPartitionPath, jsonEncode(updatedMeta.toJson()));

            // update main meta mapping relation
            meta.tablePartitionMap[tableName] = targetPartition;

            tablesMovedCount.add(tableName);
          }

          // if target partition is full, remove from candidate list
          final updatedMeta = await _loadPartitionMeta(targetPartition);
          if (updatedMeta != null &&
              updatedMeta.fileSizeInBytes > averageSize) {
            underutilizedPartitions.remove(targetPartition);
          }
        }
      }

      // save updated meta
      await saveSchemaStructure();

      final duration = DateTime.now().difference(startTime);
      Logger.debug(
        'Partition optimization completed: moved ${tablesMovedCount.length} tables, time taken ${duration.inMilliseconds}ms',
        label: 'SchemaManager.optimizePartitions',
      );

      return true;
    } catch (e) {
      Logger.error(
        'Partition optimization failed: $e',
        label: 'SchemaManager.optimizePartitions',
      );
      return false;
    }
  }

  /// get all table schemas
  Future<List<dynamic>> getAllTableSchemas() async {
    try {
      // get all table names
      final meta = await getSchemaMeta();
      final tableNames = meta.tablePartitionMap.keys.toList();

      if (tableNames.isEmpty) return [];

      // read all table schemas
      final tableSchemas = <dynamic>[];

      // read all table schemas
      for (final tableName in tableNames) {
        final schema = await getTableSchema(tableName);
        if (schema != null) {
          tableSchemas.add(schema);
        }
      }

      return tableSchemas;
    } catch (e) {
      Logger.error(
        'Failed to get all table schemas: $e',
        label: 'SchemaManager.getAllTableSchemas',
      );
      return [];
    }
  }

  /// get table is global table
  Future<bool?> isTableGlobal(String tableName) async {
    final schema = await getTableSchema(tableName);
    if (schema == null) {
      return null;
    }
    return schema.isGlobal;
  }

  bool _hasSchemaChanged(List<TableSchema> schemas, String? oldHash) {
    if (oldHash == null || oldHash.isEmpty) {
      return true;
    }

    final newHash = TableSchema.generateSchemasHash(schemas);
    return oldHash != newHash;
  }

  /// High-performance check if user-defined table schema has changed (based on Tostore(schemas: []))
  Future<bool> isSchemaChanged(List<TableSchema> schemas) async {
    try {
      final meta = await getSchemaMeta();
      final oldHash = meta.userSchemaHash;

      return _hasSchemaChanged(
        schemas,
        oldHash,
      );
    } catch (e) {
      Logger.error(
        'Failed to judge table schema change: $e',
        label: 'SchemaManager.isSchemaChanged',
      );
      return true; // return true when error, for safety upgrade
    }
  }

  /// Check if system table schema has changed
  Future<bool> isSystemSchemaChanged(List<TableSchema> schemas) async {
    try {
      final meta = await getSchemaMeta();
      final oldHash = meta.systemSchemaHash;

      return _hasSchemaChanged(
        schemas,
        oldHash,
      );
    } catch (e) {
      Logger.error(
        'Failed to judge system schema change: $e',
        label: 'SchemaManager.isSystemSchemaChanged',
      );
      return true;
    }
  }

  /// Update user-defined table schema hash
  Future<void> updateUserSchemaHash(List<TableSchema> schemas) async {
    if (schemas.isEmpty) return;
    try {
      final hash = TableSchema.generateSchemasHash(schemas);
      final meta = await getSchemaMeta();
      _schemaMeta = meta.copyWith(userSchemaHash: hash);
      await saveSchemaStructure();
    } catch (e) {
      Logger.error(
        'Failed to update user schema hash: $e',
        label: 'SchemaManager.updateUserSchemaHash',
      );
    }
  }

  /// Update system table schema hash
  Future<void> updateSystemSchemaHash(List<TableSchema> schemas) async {
    if (schemas.isEmpty) return;
    try {
      final hash = TableSchema.generateSchemasHash(schemas);
      final meta = await getSchemaMeta();
      _schemaMeta = meta.copyWith(systemSchemaHash: hash);
      await saveSchemaStructure();
    } catch (e) {
      Logger.error(
        'Failed to update system schema hash: $e',
        label: 'SchemaManager.updateSystemSchemaHash',
      );
    }
  }
}
