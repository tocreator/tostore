import 'dart:convert';
import 'package:path/path.dart' show dirname;
import '../model/file_info.dart';
import '../model/table_schema.dart';
import '../model/system_table.dart';
import '../handler/common.dart';
import '../handler/logger.dart';
import 'data_store_impl.dart';

/// table schema manager
class SchemaManager {
  final DataStoreImpl _dataStore;
  SchemaMeta? _schemaMeta; // Cache schema meta

  SchemaManager(this._dataStore);

  /// get database schema meta
  Future<SchemaMeta> getSchemaMeta() async {
    if (_schemaMeta != null) return _schemaMeta!;

    final path = _dataStore.pathManager.getSchemaMetaPath();
    if (await _dataStore.storage.existsFile(path)) {
      final content = await _dataStore.storage.readAsString(path);
      if (content != null && content.isNotEmpty) {
        try {
          _schemaMeta = SchemaMeta.fromJson(jsonDecode(content));
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

    await saveSchemaStructure();
    return _schemaMeta!;
  }

  /// save database schema meta
  Future<void> saveSchemaStructure() async {
    if (_schemaMeta == null) return;

    final path = _dataStore.pathManager.getSchemaMetaPath();
    await _dataStore.storage.ensureDirectoryExists(dirname(path));
    await _dataStore.storage
        .writeAsString(path, jsonEncode(_schemaMeta!.toJson()));
  }

  /// get table partitions
  Future<List<int>> getTablePartitions(String tableName) async {
    final meta = await getSchemaMeta();
    return meta.tablePartitionMap[tableName] ?? [];
  }

  /// find suitable partition
  Future<int> _findSuitablePartition(SchemaMeta meta, int contentSize) async {
    try {
      // check if table exists in a partition
      for (final entry in meta.tablePartitionMap.entries) {
        final partitionIndex = entry.value.first;
        final partitionMeta = await _loadPartitionMeta(partitionIndex);

        if (partitionMeta != null) {
          final newSize = partitionMeta.fileSizeInBytes + contentSize;
          if (newSize <= _dataStore.config.maxPartitionFileSize) {
            return partitionIndex;
          }
        }
      }

      // find partition with enough space
      final existingPartitions = meta.tablePartitionMap.values
          .expand((indices) => indices)
          .toSet()
          .toList();

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
      final existingPartitions = meta.tablePartitionMap.values
          .expand((indices) => indices)
          .toSet()
          .toList();
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

  /// load partition meta
  Future<SchemaPartitionMeta?> _loadPartitionMeta(int partitionIndex) async {
    final partitionPath =
        _dataStore.pathManager.getSchemaPartitionFilePath(partitionIndex);
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
  Future<void> saveTableSchema(String tableName, String schemaContent) async {
    try {
      final meta = await getSchemaMeta();
      final contentSize = calculateUtf8Length(schemaContent);

      // find suitable partition
      int targetPartition = await _findSuitablePartition(meta, contentSize);

      // read target partition meta
      final partitionPath =
          _dataStore.pathManager.getSchemaPartitionFilePath(targetPartition);
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
      final schemaObject = jsonDecode(schemaContent);
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
      meta.tablePartitionMap[tableName] = [targetPartition];
      await saveSchemaStructure();
    } catch (e) {
      Logger.error('Failed to save table schema: $tableName, $e',
          label: 'SchemaManager.saveTableSchema');
      throw Exception('Failed to save table schema: $e');
    }
  }

  /// read table schema
  Future<String?> readTableSchema(String tableName) async {
    try {
      final partitions = await getTablePartitions(tableName);
      if (partitions.isEmpty) return null;

      final partitionPath =
          _dataStore.pathManager.getSchemaPartitionFilePath(partitions.first);
      if (!await _dataStore.storage.existsFile(partitionPath)) return null;

      final content = await _dataStore.storage.readAsString(partitionPath);
      if (content == null) return null;

      try {
        final partitionMeta = SchemaPartitionMeta.fromJson(jsonDecode(content));
        if (!partitionMeta.tableSchemas.containsKey(tableName)) return null;

        return jsonEncode(partitionMeta.tableSchemas[tableName]);
      } catch (e) {
        Logger.error('Failed to read table schema: $e',
            label: 'SchemaManager.readTableSchema');
        return null;
      }
    } catch (e) {
      Logger.error(
        'Failed to read table schema: $tableName, $e',
        label: 'SchemaManager.readTableSchema',
      );
      return null;
    }
  }

  /// delete table schema
  Future<bool> deleteTableSchema(String tableName) async {
    try {
      final meta = await getSchemaMeta();
      final partitions = meta.tablePartitionMap[tableName] ?? [];

      if (partitions.isEmpty) return false;

      bool allSuccess = true;

      // delete table from all partitions
      for (final partitionIndex in partitions) {
        final success =
            await _removeTableFromPartition(tableName, partitionIndex);
        if (!success) {
          allSuccess = false;
        }
      }

      // if successfully delete table from all partitions, update meta
      if (allSuccess) {
        meta.tablePartitionMap.remove(tableName);
        await saveSchemaStructure();
      }

      return allSuccess;
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
    final partitionPath =
        _dataStore.pathManager.getSchemaPartitionFilePath(partitionIndex);
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
      final uniquePartitions = meta.tablePartitionMap.values
          .expand((indices) => indices)
          .toSet()
          .toList();

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
      final uniquePartitions = meta.tablePartitionMap.values
          .expand((indices) => indices)
          .toSet()
          .toList();

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
            final targetPartitionPath = _dataStore.pathManager
                .getSchemaPartitionFilePath(targetPartition);
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

            // save target partition fileget partition file
            await _dataStore.storage
                .ensureDirectoryExists(dirname(targetPartitionPath));
            await _dataStore.storage.writeAsString(
                targetPartitionPath, jsonEncode(updatedMeta.toJson()));

            // update main meta mapping relation
            meta.tablePartitionMap[tableName] = [targetPartition];

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
        final schemaStr = await readTableSchema(tableName);
        if (schemaStr != null) {
          try {
            final schema = jsonDecode(schemaStr);
            tableSchemas.add(schema);
          } catch (e) {
            Logger.error('Failed to parse table schema: $tableName, $e',
                label: 'SchemaManager.getAllTableSchemas');
          }
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
    final schema = await _dataStore.getTableSchema(tableName);
    if (schema == null) {
      return null;
    }
    return schema.isGlobal;
  }

  /// high performance check if table schema has changed, used for upgrade judgment
  /// [schemas] latest table schema list
  Future<bool> isSchemaChanged(List<TableSchema> schemas) async {
    try {
      final meta = await getSchemaMeta();
      final oldHash = meta.schemaHash;

      if (oldHash == null || oldHash.isEmpty) {
        Logger.debug(
          'Table schema has no old hash value',
          label: 'SchemaManager.isSchemaChanged',
        );
        return true;
      }

      // calculate current table schema hash
      final newHash = TableSchema.generateSchemasHash(schemas);

      // compare new and old hash values
      final changed = oldHash != newHash;

      return changed;
    } catch (e) {
      Logger.error(
        'Failed to judge table schema change: $e',
        label: 'SchemaManager.isSchemaChanged',
      );
      return true; // return true when error, for safety upgrade
    }
  }

  /// update database initial table schema hash
  Future<void> updateInitialSchemaHash() async {
    try {
      final schemasTemp = _dataStore.getInitialSchema();

      if (schemasTemp.isEmpty) return;

      // calculate hash
      final hash = TableSchema.generateSchemasHash(schemasTemp);

      // update meta
      final meta = await getSchemaMeta();
      _schemaMeta = meta.copyWith(schemaHash: hash);
      await saveSchemaStructure();
    } catch (e) {
      Logger.error(
        'Failed to update schema hash: $e',
        label: 'SchemaManager.updateSchemaHash',
      );
    }
  }
}
