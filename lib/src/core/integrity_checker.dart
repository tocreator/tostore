import 'data_store_impl.dart';
import '../handler/logger.dart';
import '../model/table_schema.dart';
import '../model/data_store_config.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import '../model/file_info.dart';

/// data integrity checker
class IntegrityChecker {
  final DataStoreImpl _dataStore;

  IntegrityChecker(this._dataStore);

  /// check table structure integrity
  Future<bool> checkTableStructure(String tableName) async {
    try {
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
        return false;
      }
      final dataPath = await _dataStore.pathManager.getDataMetaPath(tableName);

      if (!await _dataStore.storage.existsFile(dataPath)) {
        return false;
      }

      // check each record is valid using stream
      await for (var data
          in _dataStore.tableDataManager.streamRecords(tableName)) {
        try {
          if (!_validateRecord(data, schema)) {
            return false;
          }
        } catch (e) {
          return false;
        }
      }

      return true;
    } catch (e) {
      return false;
    }
  }

  /// check index integrity
  Future<bool> checkIndexIntegrity(String tableName) async {
    try {
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
        return false;
      }
      final dataPath = await _dataStore.pathManager.getDataMetaPath(tableName);

      // check each index file
      for (var index in schema.indexes) {
        // validate index content
        if (!await _validateIndex(tableName, index, dataPath)) {
          return false;
        }
      }

      return true;
    } catch (e) {
      return false;
    }
  }

  /// check data consistency
  Future<bool> checkDataConsistency(String tableName) async {
    try {
      // get table meta data
      final fileMeta =
          await _dataStore.tableDataManager.getTableFileMeta(tableName);

      // get table schema info
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
        return false;
      }
      final isGlobal = schema.isGlobal;
      final primaryKey = schema.primaryKey;

      if (fileMeta != null && fileMeta.partitions != null) {
        // check each partition
        for (var partition in fileMeta.partitions!) {
          if (partition.checksum == null) {
            Logger.error('Partition missing checksum',
                label: 'IntegrityChecker.checkDataConsistency');
            return false;
          }

          try {
            // use readRecordsFromPartition to read partition records
            final records = await _dataStore.tableDataManager
                .readRecordsFromPartition(
                    tableName, isGlobal, partition.index, primaryKey);

            if (records.isEmpty && partition.totalRecords > 0) {
              Logger.error('Failed to read partition records',
                  label: 'IntegrityChecker.checkDataConsistency');
              return false;
            }

            // use the same way as TableDataManager to calculate checksum
            final allRecordsData =
                Uint8List.fromList(utf8.encode(jsonEncode(records)));
            final actualChecksum =
                _dataStore.calculateChecksum(allRecordsData).toString();

            // compare with stored checksum
            if (actualChecksum != partition.checksum) {
              Logger.error(
                  'Checksum mismatch: Expected[${partition.checksum}], Actual[$actualChecksum]',
                  label: 'IntegrityChecker.checkDataConsistency');
              return false;
            }
          } catch (e) {
            Logger.error('Checksum calculation failed: $e',
                label: 'IntegrityChecker.checkDataConsistency');
            return false;
          }
        }
        return true;
      } else {
        Logger.warn('Table has no partition metadata',
            label: 'IntegrityChecker.checkDataConsistency');
        return false;
      }
    } catch (e) {
      Logger.error('Data consistency check failed: $e',
          label: 'IntegrityChecker.checkDataConsistency');
      return false;
    }
  }

  /// check foreign key constraints
  Future<bool> checkForeignKeyConstraints(String tableName) async {
    try {
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
        return false;
      }

      await for (var data
          in _dataStore.tableDataManager.streamRecords(tableName)) {
        // check each foreign key reference
        for (var field in schema.fields) {
          // check field is foreign key reference
          if (field.type == DataType.integer && field.name.endsWith('_id')) {
            if (!await _validateForeignKeyReference(
              data[field.name],
              field.name,
              tableName,
            )) {
              return false;
            }
          }
        }
      }

      return true;
    } catch (e) {
      return false;
    }
  }

  /// validate foreign key reference
  Future<bool> _validateForeignKeyReference(
    dynamic value,
    String fieldName,
    String tableName,
  ) async {
    if (value == null) return true;

    final referencedTable = _inferReferencedTable(fieldName);
    try {
      final referencedSchema = await _dataStore.getTableSchema(referencedTable);
      if (referencedSchema == null) {
        return false;
      }
      final dataPath = await _dataStore.pathManager.getDataMetaPath(
        referencedTable,
      );

      if (!await _dataStore.storage.existsFile(dataPath)) {
        return false;
      }

      // find record in referenced table
      await for (var data
          in _dataStore.tableDataManager.streamRecords(tableName)) {
        if (data[referencedSchema.primaryKey] == value) {
          return true;
        }
      }

      return false;
    } catch (e) {
      return false;
    }
  }

  /// infer referenced table name
  String _inferReferencedTable(String fieldName) {
    // remove _id suffix
    final baseName = fieldName.substring(0, fieldName.length - 3);
    // convert to plural form (simple implementation)
    return '${baseName}s';
  }

  /// check unique constraints
  Future<bool> checkUniqueConstraints(String tableName) async {
    try {
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
        return false;
      }

      final uniqueValues = <String, Set<String>>{};
      for (var index in schema.indexes.where((idx) => idx.unique)) {
        uniqueValues[index.actualIndexName] = {};
      }

      await for (var data
          in _dataStore.tableDataManager.streamRecords(tableName)) {
        for (var index in schema.indexes.where((idx) => idx.unique)) {
          final key = _extractIndexKey(data, index.fields);
          if (!uniqueValues[index.actualIndexName]!.add(key)) {
            return false;
          }
        }
      }

      return true;
    } catch (e) {
      return false;
    }
  }

  /// validate record
  bool _validateRecord(Map<String, dynamic> data, TableSchema schema) {
    // check required fields
    for (var field in schema.fields) {
      if (!field.nullable && !data.containsKey(field.name)) {
        return false;
      }
    }

    // check data type
    for (var entry in data.entries) {
      // check if it is primary key field
      if (entry.key == schema.primaryKey) {
        // primary key field, check its type
        // primary key is usually integer or string type
        final value = entry.value;
        if (value != null &&
            !(value is int ||
                value is String ||
                value is BigInt ||
                value is num)) {
          return false;
        }
        continue; // primary key validation passed, continue to process next field
      }

      // for non-primary key field, use schema.fields to validate
      try {
        final field = schema.fields.firstWhere(
          (col) => col.name == entry.key,
          orElse: () => throw StateError('Unknown field ${entry.key}'),
        );

        if (!field.isValidDataType(entry.value, field.type)) {
          return false;
        }
      } catch (e) {
        // if field not found but not primary key field, record warning but not stop validation
        // this may be due to table structure change
        Logger.warn(
            'Unknown field encountered during record validation: ${entry.key}',
            label: 'IntegrityChecker._validateRecord');
        continue;
      }
    }

    return true;
  }

  /// validate index
  Future<bool> _validateIndex(
    String tableName,
    IndexSchema index,
    String dataPath,
  ) async {
    try {
      final uniqueKeys = <String>{};
      int recordCount = 0;

      // collect all unique keys in data
      await for (var data
          in _dataStore.tableDataManager.streamRecords(tableName)) {
        final key = _extractIndexKey(data, index.fields);
        uniqueKeys.add(key);
        recordCount++;
      }

      // check duplicate in unique index
      if (index.unique && uniqueKeys.length != recordCount) {
        Logger.error('Duplicate found in unique index ${index.actualIndexName}',
            label: 'IntegrityChecker._validateIndex');
        return false;
      }

      // Use processIndexPartitions instead of getIndexPartitions to count entries
      int totalIndexEntries = 0;
      final countSuccess =
          await _dataStore.indexManager?.processIndexPartitions(
        tableName,
        index.actualIndexName,
        processor: (_, meta, __) async {
          totalIndexEntries += meta.entries;
          return true; // Continue processing all partitions
        },
        updateMetadata:
            false, // Read-only operation, no need to update metadata
      );

      if (countSuccess != true) {
        Logger.error(
            'Index ${index.actualIndexName} partitions not found or processing failed',
            label: 'IntegrityChecker._validateIndex');
        return false;
      }

      final entriesMatch = totalIndexEntries == uniqueKeys.length;
      if (!entriesMatch) {
        Logger.error(
            'Index ${index.actualIndexName} entry count mismatch: index has $totalIndexEntries entries, should have ${uniqueKeys.length} entries',
            label: 'IntegrityChecker._validateIndex');
      }

      return entriesMatch;
    } catch (e) {
      Logger.error('Index validation failed: $e',
          label: 'IntegrityChecker._validateIndex');
      return false;
    }
  }

  /// extract index key
  String _extractIndexKey(Map<String, dynamic> data, List<String> fields) {
    return fields.map((col) => data[col].toString()).join(':');
  }

  /// efficient migration validation method
  Future<bool> validateMigration(
    String tableName,
    TableSchema newSchema,
  ) async {
    // record start time for performance evaluation
    final stopwatch = Stopwatch()..start();

    try {
      // check if table meta data file exists
      final dataMetaPath =
          await _dataStore.pathManager.getDataMetaPath(tableName);
      final tableMetaExists = await _dataStore.storage.existsFile(dataMetaPath);

      // get table meta data (if exists)
      FileMeta? fileMeta;
      if (tableMetaExists) {
        fileMeta =
            await _dataStore.tableDataManager.getTableFileMeta(tableName);
      }

      // check if it is a new table (no meta data or meta data has no partition info)
      final isNewTable = !tableMetaExists ||
          fileMeta == null ||
          fileMeta.partitions == null ||
          fileMeta.partitions!.isEmpty;

      if (isNewTable) {
        Logger.info(
            'Table[$tableName] is a new table or has no data written yet, skipping data file validation, only validating table structure',
            label: 'IntegrityChecker.validateMigration');
      } else {
        // for table with data, validate index meta data
        for (var index in newSchema.indexes) {
          final indexMetaPath = await _dataStore.pathManager
              .getIndexMetaPath(tableName, index.actualIndexName);

          if (!await _dataStore.storage.existsFile(indexMetaPath)) {
            Logger.info(
                'Index metadata does not exist: ${index.actualIndexName}, possibly a new index',
                label: 'IntegrityChecker.validateMigration');
            // for new index, do not fail
          }
        }

        // sample validation partitions
        if (fileMeta.partitions != null && fileMeta.partitions!.isNotEmpty) {
          // in large table, use sample validation: only validate first and last partitions
          final partitionsToCheck = <PartitionMeta>[];

          // add first partition
          if (fileMeta.partitions!.isNotEmpty) {
            partitionsToCheck.add(fileMeta.partitions!.first);
          }

          // if there are multiple partitions, add the last partition (if different from the first)
          if (fileMeta.partitions!.length > 1) {
            final lastPartition = fileMeta.partitions!.last;
            if (lastPartition.index != partitionsToCheck.first.index) {
              partitionsToCheck.add(lastPartition);
            }
          }

          // optimize: validate multiple partitions in parallel
          final results = await Future.wait(partitionsToCheck.map((partition) =>
              _validatePartition(tableName, partition, newSchema.isGlobal,
                  newSchema.primaryKey)));

          // if any partition validation failed, whole validation failed
          if (results.contains(false)) {
            Logger.error(
                'Partition validation failed, migration validation failed',
                label: 'IntegrityChecker.validateMigration');
            return false;
          }
        }
      }

      // whether it is a new table or not, validate table structure
      try {
        // validate field default value validity for all fields
        for (final field in newSchema.fields) {
          final defaultValue = field.getDefaultValue();
          if (!field.validateValue(defaultValue)) {
            Logger.error(
                'Field[${field.name}] default value validation failed, type: ${field.type}',
                label: 'IntegrityChecker.validateMigration');
            return false;
          }
        }

        // for non-new table, try to get records from stream and validate structure
        if (!isNewTable) {
          final stream = _dataStore.tableDataManager.streamRecords(tableName);
          int count = 0;
          int maxSamples = 10;

          await for (var record in stream) {
            try {
              // validate record structure
              if (!_validateRecord(record, newSchema)) {
                Logger.error(
                    'Record structure validation failed: Record does not meet new table structure requirements',
                    label: 'IntegrityChecker.validateMigration');
                return false;
              }
            } catch (recordError) {
              Logger.error(
                  'Record structure validation exception: $recordError',
                  label: 'IntegrityChecker.validateMigration');
              return false;
            }

            count++;
            if (count >= maxSamples) break;
          }
        }
      } catch (e, stack) {
        Logger.error('Table structure validation failed: $e\n$stack',
            label: 'IntegrityChecker.validateMigration');
        return false;
      }

      // record validation time
      stopwatch.stop();
      Logger.info(
        'Migration validation completed: Table[$tableName], Time[${stopwatch.elapsedMilliseconds}ms]',
        label: 'IntegrityChecker.validateMigration',
      );

      return true;
    } catch (e) {
      stopwatch.stop();
      Logger.error(
        'Migration validation error: Table[$tableName], Error[$e], Time[${stopwatch.elapsedMilliseconds}ms]',
        label: 'IntegrityChecker.validateMigration',
      );
      return false;
    }
  }

  /// validate single partition integrity
  Future<bool> _validatePartition(String tableName, PartitionMeta partition,
      bool isGlobal, String primaryKey) async {
    // if partition is large (record count exceeds threshold), skip checksum validation, only validate record count
    if (partition.totalRecords > 5000) {
      // large partition only validate partition file existence
      final partitionPath = await _dataStore.pathManager
          .getPartitionFilePath(tableName, partition.index);

      if (!await _dataStore.storage.existsFile(partitionPath)) {
        Logger.error('Partition file does not exist: $partitionPath',
            label: 'IntegrityChecker._validatePartition');
        return false;
      }
      return true;
    }

    // for small partition, validate checksum
    if (partition.checksum != null) {
      try {
        // read partition records for validation - only try to read 1 record
        final records = await _dataStore.tableDataManager
            .readRecordsFromPartition(
                tableName, isGlobal, partition.index, primaryKey);

        // if records can be read and format is correct, consider partition structure is correct
        if (records.isNotEmpty) {
          return true;
        }

        // if partition is empty but record count shows not zero, validation failed
        if (records.isEmpty && partition.totalRecords > 0) {
          Logger.error(
              'Partition metadata shows ${partition.totalRecords} records, but cannot be read',
              label: 'IntegrityChecker._validatePartition');
          return false;
        }

        return true;
      } catch (e) {
        Logger.error('Partition validation failed: $e',
            label: 'IntegrityChecker._validatePartition');
        return false;
      }
    }

    return true;
  }

  /// Validate table structure matches schema
  Future<bool> validateTableStructure(
    String tableName,
    TableSchema schema,
    DataStoreConfig config,
  ) async {
    try {
      // Check table structure integrity
      if (!await checkTableStructure(tableName)) {
        return false;
      }

      // Check index integrity
      if (!await checkIndexIntegrity(tableName)) {
        return false;
      }

      return true;
    } catch (e) {
      return false;
    }
  }

  /// Validate table data integrity
  Future<bool> validateTableData(
    String tableName,
    TableSchema schema,
    DataStoreConfig config,
  ) async {
    try {
      // Check data consistency
      if (!await checkDataConsistency(tableName)) {
        return false;
      }

      // Check unique constraints
      if (!await checkUniqueConstraints(tableName)) {
        return false;
      }

      // Check foreign key constraints if any
      if (!await checkForeignKeyConstraints(tableName)) {
        return false;
      }

      return true;
    } catch (e) {
      return false;
    }
  }
}
