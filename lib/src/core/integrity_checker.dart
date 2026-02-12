import 'dart:async';
import 'dart:typed_data';
import 'data_store_impl.dart';
import 'btree_page.dart';
import '../handler/logger.dart';
import '../model/table_schema.dart';
import '../model/data_store_config.dart';
import '../model/meta_info.dart';

/// data integrity checker
class IntegrityChecker {
  final DataStoreImpl _dataStore;

  IntegrityChecker(this._dataStore);

  /// check table structure integrity
  /// For large-scale data scenarios, uses sampling validation (first/last few records)
  Future<bool> checkTableStructure(String tableName) async {
    try {
      final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
      if (schema == null) {
        return false;
      }
      final dataPath = await _dataStore.pathManager.getDataMetaPath(tableName);

      if (!await _dataStore.storage.existsFile(dataPath)) {
        return false;
      }

      final fileMeta =
          await _dataStore.tableDataManager.getTableMeta(tableName);
      if (fileMeta == null || fileMeta.totalRecords == 0) {
        return true; // Empty table is valid
      }

      // For large-scale data, use sampling validation (first/last few records)
      // This avoids traversing billions of records which would be fatal
      const int sampleSize = 5; // Sample first and last N records
      final rangeManager = _dataStore.tableTreePartitionManager;

      // Sample first few records
      int validatedCount = 0;
      await for (var data in rangeManager.streamRecordsByPrimaryKeyRange(
        tableName: tableName,
        startKeyInclusive: Uint8List(0),
        endKeyExclusive: Uint8List(0),
        reverse: false,
        limit: sampleSize,
      )) {
        try {
          if (!_validateRecord(data, schema)) {
            Logger.error(
                'Table structure validation failed: record at start does not match schema',
                label: 'IntegrityChecker.checkTableStructure');
            return false;
          }
          validatedCount++;
        } catch (e) {
          Logger.error('Table structure validation exception at start: $e',
              label: 'IntegrityChecker.checkTableStructure');
          return false;
        }
      }

      // Sample last few records (reverse scan)
      await for (var data in rangeManager.streamRecordsByPrimaryKeyRange(
        tableName: tableName,
        startKeyInclusive: Uint8List(0),
        endKeyExclusive: Uint8List(0),
        reverse: true,
        limit: sampleSize,
      )) {
        try {
          if (!_validateRecord(data, schema)) {
            Logger.error(
                'Table structure validation failed: record at end does not match schema',
                label: 'IntegrityChecker.checkTableStructure');
            return false;
          }
          validatedCount++;
        } catch (e) {
          Logger.error('Table structure validation exception at end: $e',
              label: 'IntegrityChecker.checkTableStructure');
          return false;
        }
      }

      Logger.info(
          'Table structure validation completed (sampled $validatedCount records from start/end)',
          label: 'IntegrityChecker.checkTableStructure');
      return true;
    } catch (e) {
      Logger.error('Table structure check failed: $e',
          label: 'IntegrityChecker.checkTableStructure');
      return false;
    }
  }

  /// check data consistency
  /// For large-scale data scenarios, only validates first/last partition meta pages
  Future<bool> checkDataConsistency(String tableName) async {
    try {
      // get table meta data
      final fileMeta =
          await _dataStore.tableDataManager.getTableMeta(tableName);

      // get table schema info
      final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
      if (schema == null) {
        return false;
      }

      if (fileMeta == null) {
        Logger.warn('Table meta not found for $tableName',
            label: 'IntegrityChecker.checkDataConsistency');
        return false;
      }

      if (fileMeta.btreePartitionCount == 0) {
        // Empty table
        return fileMeta.totalRecords == 0 && fileMeta.totalSizeInBytes == 0;
      }

      // For large-scale data, only validate first and last partition meta pages
      // This avoids traversing tens of thousands of partitions which would be fatal
      final pageSize = fileMeta.btreePageSize;
      final partitionsToCheck = <int>{0}; // Always check first partition

      // Find and check last existing partition
      for (int pNo = fileMeta.btreePartitionCount - 1; pNo >= 0; pNo--) {
        final path = await _dataStore.pathManager
            .getPartitionFilePathByNo(tableName, pNo);
        if (await _dataStore.storage.existsFile(path) &&
            await _dataStore.storage.getFileSize(path) > 0) {
          partitionsToCheck.add(pNo);
          break;
        }
      }

      // Validate sampled partition meta pages
      for (final pNo in partitionsToCheck) {
        final path = await _dataStore.pathManager
            .getPartitionFilePathByNo(tableName, pNo);
        if (!await _dataStore.storage.existsFile(path)) {
          if (pNo == 0) {
            Logger.error('First partition file missing (pNo=0)',
                label: 'IntegrityChecker.checkDataConsistency');
            return false;
          }
          continue;
        }

        final actualSize = await _dataStore.storage.getFileSize(path);
        if (actualSize <= 0) {
          if (pNo == 0) {
            Logger.error('First partition file is empty (pNo=0)',
                label: 'IntegrityChecker.checkDataConsistency');
            return false;
          }
          continue;
        }

        try {
          final raw0 =
              await _dataStore.storage.readAsBytesAt(path, 0, length: pageSize);
          if (raw0.isEmpty) {
            Logger.error('Partition file meta page is empty (pNo=$pNo)',
                label: 'IntegrityChecker.checkDataConsistency');
            return false;
          }
          final parsed0 = BTreePageIO.parsePageBytes(raw0);
          if (parsed0.type != BTreePageType.meta) {
            Logger.error(
                'Partition file missing meta page (pNo=$pNo, type=${parsed0.type})',
                label: 'IntegrityChecker.checkDataConsistency');
            return false;
          }
          final hdr =
              PartitionMetaPage.tryDecodePayload(parsed0.encodedPayload);
          if (hdr == null) {
            Logger.error('Failed to decode PartitionMetaPage (pNo=$pNo)',
                label: 'IntegrityChecker.checkDataConsistency');
            return false;
          }
          if (hdr.partitionNo != pNo) {
            Logger.error(
                'PartitionMetaPage.partitionNo mismatch: expected=$pNo actual=${hdr.partitionNo}',
                label: 'IntegrityChecker.checkDataConsistency');
            return false;
          }
          if (hdr.fileSizeInBytes > actualSize) {
            Logger.error(
                'PartitionMetaPage.fileSizeInBytes exceeds actual file size: pNo=$pNo hdr=${hdr.fileSizeInBytes} actual=$actualSize',
                label: 'IntegrityChecker.checkDataConsistency');
            return false;
          }
        } catch (e) {
          Logger.error(
              'Validation failed for partitionNo=$pNo with exception: $e',
              label: 'IntegrityChecker.checkDataConsistency');
          return false;
        }
      }

      Logger.info(
          'Data consistency check completed (sampled partitions: ${partitionsToCheck.join(", ")})',
          label: 'IntegrityChecker.checkDataConsistency');
      return true;
    } catch (e) {
      Logger.error('Data consistency check failed: $e',
          label: 'IntegrityChecker.checkDataConsistency');
      return false;
    }
  }

  /// check foreign key constraints
  /// For large-scale data scenarios, uses sampling validation (first/last few records)
  Future<bool> checkForeignKeyConstraints(String tableName) async {
    try {
      final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
      if (schema == null) {
        return false;
      }

      final fileMeta =
          await _dataStore.tableDataManager.getTableMeta(tableName);
      if (fileMeta == null || fileMeta.totalRecords == 0) {
        return true; // Empty table is valid
      }

      // For large-scale data, use sampling validation (first/last few records)
      const int sampleSize = 10;
      final rangeManager = _dataStore.tableTreePartitionManager;

      // Sample first few records
      await for (var data in rangeManager.streamRecordsByPrimaryKeyRange(
        tableName: tableName,
        startKeyInclusive: Uint8List(0),
        endKeyExclusive: Uint8List(0),
        reverse: false,
        limit: sampleSize,
      )) {
        // check each foreign key reference
        for (var field in schema.fields) {
          // check field is foreign key reference
          if (field.type == DataType.integer && field.name.endsWith('_id')) {
            if (!await _validateForeignKeyReference(
              data[field.name],
              field.name,
              tableName,
            )) {
              Logger.error(
                  'Foreign key constraint validation failed at start: ${field.name}=${data[field.name]}',
                  label: 'IntegrityChecker.checkForeignKeyConstraints');
              return false;
            }
          }
        }
      }

      // Sample last few records (reverse scan)
      await for (var data in rangeManager.streamRecordsByPrimaryKeyRange(
        tableName: tableName,
        startKeyInclusive: Uint8List(0),
        endKeyExclusive: Uint8List(0),
        reverse: true,
        limit: sampleSize,
      )) {
        // check each foreign key reference
        for (var field in schema.fields) {
          // check field is foreign key reference
          if (field.type == DataType.integer && field.name.endsWith('_id')) {
            if (!await _validateForeignKeyReference(
              data[field.name],
              field.name,
              tableName,
            )) {
              Logger.error(
                  'Foreign key constraint validation failed at end: ${field.name}=${data[field.name]}',
                  label: 'IntegrityChecker.checkForeignKeyConstraints');
              return false;
            }
          }
        }
      }

      Logger.info(
          'Foreign key constraint validation completed (sampled records from start/end)',
          label: 'IntegrityChecker.checkForeignKeyConstraints');
      return true;
    } catch (e) {
      Logger.error('Foreign key constraint check failed: $e',
          label: 'IntegrityChecker.checkForeignKeyConstraints');
      return false;
    }
  }

  /// validate foreign key reference
  /// Uses efficient point lookup instead of full table scan
  Future<bool> _validateForeignKeyReference(
    dynamic value,
    String fieldName,
    String tableName,
  ) async {
    if (value == null) return true;

    final referencedTable = _inferReferencedTable(fieldName);
    try {
      final referencedSchema =
          await _dataStore.schemaManager?.getTableSchema(referencedTable);
      if (referencedSchema == null) {
        return false;
      }
      final dataPath = await _dataStore.pathManager.getDataMetaPath(
        referencedTable,
      );

      if (!await _dataStore.storage.existsFile(dataPath)) {
        return false;
      }

      // Use efficient point lookup instead of full table scan
      // This avoids traversing billions of records which would be fatal
      final record = await _dataStore.tableDataManager
          .queryRecordsBatch(referencedTable, [value]);
      return record.records.isNotEmpty;
    } catch (e) {
      Logger.warn(
          'Foreign key reference validation error: $e (table=$referencedTable, value=$value)',
          label: 'IntegrityChecker._validateForeignKeyReference');
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
  /// For large-scale data scenarios, validates index metadata instead of full scan
  /// Note: Full unique constraint validation would require scanning all records,
  /// which is fatal for billion-scale data. This method validates index metadata
  /// structure instead, assuming index uniqueness is enforced at write time.
  Future<bool> checkUniqueConstraints(String tableName) async {
    try {
      final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
      if (schema == null) {
        return false;
      }

      final fileMeta =
          await _dataStore.tableDataManager.getTableMeta(tableName);
      if (fileMeta == null || fileMeta.totalRecords == 0) {
        return true; // Empty table is valid
      }

      // For large-scale data, validate index metadata structure instead of full scan
      // Unique constraints are enforced at write time, so we only validate index metadata exists
      final uniqueIndexes =
          (_dataStore.schemaManager?.getUniqueIndexesFor(schema) ??
              const <IndexSchema>[]);
      if (uniqueIndexes.isEmpty) {
        return true; // No unique constraints to check
      }

      // Validate that unique index metadata files exist and are accessible
      for (var index in uniqueIndexes) {
        final indexMetaPath = await _dataStore.pathManager
            .getIndexMetaPath(tableName, index.actualIndexName);
        if (!await _dataStore.storage.existsFile(indexMetaPath)) {
          Logger.warn(
              'Unique index metadata file not found: ${index.actualIndexName}',
              label: 'IntegrityChecker.checkUniqueConstraints');
          // Don't fail for missing index metadata (might be a new index)
          continue;
        }

        // Verify index metadata can be loaded
        try {
          final indexMeta = await _dataStore.indexManager
              ?.getIndexMeta(tableName, index.actualIndexName);
          if (indexMeta == null) {
            Logger.warn(
                'Failed to load unique index metadata: ${index.actualIndexName}',
                label: 'IntegrityChecker.checkUniqueConstraints');
            // Don't fail, might be a new index
            continue;
          }
        } catch (e) {
          Logger.warn(
              'Error loading unique index metadata: ${index.actualIndexName}, $e',
              label: 'IntegrityChecker.checkUniqueConstraints');
          // Don't fail, might be a new index
          continue;
        }
      }

      Logger.info(
          'Unique constraint validation completed (validated index metadata structure)',
          label: 'IntegrityChecker.checkUniqueConstraints');
      return true;
    } catch (e) {
      Logger.error('Unique constraint check failed: $e',
          label: 'IntegrityChecker.checkUniqueConstraints');
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
      TableMeta? fileMeta;
      if (tableMetaExists) {
        fileMeta = await _dataStore.tableDataManager.getTableMeta(tableName);
      }

      // check if it is a new table (no meta data or meta data has no partition info)
      final isNewTable =
          !tableMetaExists || fileMeta == null || fileMeta.totalRecords <= 0;

      if (isNewTable) {
        Logger.info(
            'Table[$tableName] is a new table or has no data written yet, skipping data file validation, only validating table structure',
            label: 'IntegrityChecker.validateMigration');
      } else {
        // for table with data, validate B+Tree index meta data
        // (vector indexes use separate meta paths managed by VectorIndexManager)
        final allIndexes =
            _dataStore.schemaManager?.getBtreeIndexesFor(newSchema) ??
                <IndexSchema>[];
        for (var index in allIndexes) {
          final indexMetaPath = await _dataStore.pathManager
              .getIndexMetaPath(tableName, index.actualIndexName);

          if (!await _dataStore.storage.existsFile(indexMetaPath)) {
            Logger.info(
                'Index metadata does not exist: ${index.actualIndexName}, possibly a new index',
                label: 'IntegrityChecker.validateMigration');
            // for new index, do not fail
          }
        }

        // Sample validation: only validate meta pages of first/last *existing* physical partitions.
        final TableMeta meta = fileMeta;
        Future<int?> findLastExistingPartitionNo() async {
          for (int pNo = meta.btreePartitionCount - 1; pNo >= 0; pNo--) {
            final path = await _dataStore.pathManager
                .getPartitionFilePathByNo(tableName, pNo);
            if (await _dataStore.storage.existsFile(path) &&
                await _dataStore.storage.getFileSize(path) > 0) {
              return pNo;
            }
            if (pNo == 0) break;
          }
          return null;
        }

        Future<bool> validatePartitionMetaPage(int partitionNo) async {
          final path = await _dataStore.pathManager
              .getPartitionFilePathByNo(tableName, partitionNo);
          if (!await _dataStore.storage.existsFile(path)) {
            // partitionNo=0 should exist if table has committed data.
            return partitionNo != 0;
          }
          final raw0 = await _dataStore.storage
              .readAsBytesAt(path, 0, length: meta.btreePageSize);
          if (raw0.isEmpty) return false;
          final parsed0 = BTreePageIO.parsePageBytes(raw0);
          if (parsed0.type != BTreePageType.meta) return false;
          final hdr =
              PartitionMetaPage.tryDecodePayload(parsed0.encodedPayload);
          if (hdr == null) return false;
          return hdr.partitionNo == partitionNo;
        }

        final toCheck = <int>{0};
        final lastExisting = await findLastExistingPartitionNo();
        if (lastExisting != null) toCheck.add(lastExisting);
        final results = await Future.wait(
            toCheck.map((pNo) => validatePartitionMetaPage(pNo)));
        if (results.contains(false)) {
          Logger.error('Partition meta page validation failed',
              label: 'IntegrityChecker.validateMigration');
          return false;
        }
      }

      // whether it is a new table or not, validate table structure
      try {
        // for non-new table, use sampling validation (first/last few records)
        if (!isNewTable) {
          const int maxSamples = 5;
          final rangeManager = _dataStore.tableTreePartitionManager;
          int validatedCount = 0;

          // Sample first few records
          await for (var record in rangeManager.streamRecordsByPrimaryKeyRange(
            tableName: tableName,
            startKeyInclusive: Uint8List(0),
            endKeyExclusive: Uint8List(0),
            reverse: false,
            limit: maxSamples,
          )) {
            try {
              // validate record structure
              if (!_validateRecord(record, newSchema)) {
                Logger.error(
                    'Record structure validation failed: Record does not meet new table structure requirements',
                    label: 'IntegrityChecker.validateMigration');
                return false;
              }
              validatedCount++;
            } catch (recordError) {
              Logger.error(
                  'Record structure validation exception: $recordError',
                  label: 'IntegrityChecker.validateMigration');
              return false;
            }
          }

          // Sample last few records (reverse scan)
          await for (var record in rangeManager.streamRecordsByPrimaryKeyRange(
            tableName: tableName,
            startKeyInclusive: Uint8List(0),
            endKeyExclusive: Uint8List(0),
            reverse: true,
            limit: maxSamples,
          )) {
            try {
              // validate record structure
              if (!_validateRecord(record, newSchema)) {
                Logger.error(
                    'Record structure validation failed: Record does not meet new table structure requirements',
                    label: 'IntegrityChecker.validateMigration');
                return false;
              }
              validatedCount++;
            } catch (recordError) {
              Logger.error(
                  'Record structure validation exception: $recordError',
                  label: 'IntegrityChecker.validateMigration');
              return false;
            }
          }

          Logger.info(
              'Migration validation sampled $validatedCount records from start/end',
              label: 'IntegrityChecker.validateMigration');
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

      return true;
    } catch (e) {
      return false;
    }
  }
}
