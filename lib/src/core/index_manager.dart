import 'dart:async';
import 'dart:io';

import '../handler/logger.dart';

import '../model/business_error.dart';
import 'data_store_impl.dart';
import 'b_plus_tree.dart';
import '../model/row_pointer.dart';
import '../model/table_schema.dart';
import '../query/query_plan.dart';

/// index manager
class IndexManager {
  final DataStoreImpl _dataStore;
  final Map<String, BPlusTree> _indexes = {};
  final Map<String, List<Map<String, dynamic>>> _indexBatchQueue = {};
  final Map<String, File> _indexFiles = {};

  // add last update time record
  DateTime? _lastUpdateTime;
  Timer? _updateTimer;
  static const Duration _updateInterval = Duration(seconds: 10);

  IndexManager(this._dataStore) {
    // start timer to check update
    _startUpdateTimer();
  }

  void _startUpdateTimer() {
    _updateTimer = Timer.periodic(_updateInterval, (_) => _checkAndUpdate());
  }

  void dispose() {
    _updateTimer?.cancel();
    _updateTimer = null;
  }

  /// check and execute update
  Future<void> _checkAndUpdate() async {
    final now = DateTime.now();
    if (_lastUpdateTime == null ||
        now.difference(_lastUpdateTime!) >= _updateInterval) {
      // handle all tables update index
      for (var tableName in _indexBatchQueue.keys.toList()) {
        if (_indexBatchQueue[tableName]?.isNotEmpty ?? false) {
          final batch =
              List<Map<String, dynamic>>.from(_indexBatchQueue[tableName]!);
          _indexBatchQueue[tableName]!.clear();
          await batchUpdateIndexes(tableName, batch);
        }
      }
      _lastUpdateTime = DateTime.now();
    }
  }

  /// update index
  Future<void> updateIndexes(
    String tableName,
    Map<String, dynamic> record,
    RowPointer pointer,
  ) async {
    try {
      final schema = await _dataStore.getTableSchema(tableName);
      final primaryKeyValue = record[schema.primaryKey];

      // Update primary index
      final pkIndex = getIndex('pk_$tableName');
      if (pkIndex != null) {
        await pkIndex.insert(primaryKeyValue, pointer.toString());
      }

      // Update secondary indexes
      for (var index in schema.indexes) {
        final indexKey = await _extractIndexKey(index.actualIndexName, record);
        if (indexKey != null) {
          final btIndex = getIndex(index.actualIndexName);
          if (btIndex != null) {
            await btIndex.insert(indexKey, primaryKeyValue.toString());
          }
        }
      }
    } catch (e) {
      Logger.error(
        'Failed to update indexes: $e',
        label: 'IndexManager.updateIndexes',
      );
      rethrow;
    }
  }

  /// force execute all update index
  Future<void> flushIndexes() async {
    for (var tableName in _indexBatchQueue.keys.toList()) {
      if (_indexBatchQueue[tableName]?.isNotEmpty ?? false) {
        final batch =
            List<Map<String, dynamic>>.from(_indexBatchQueue[tableName]!);
        _indexBatchQueue[tableName]!.clear();
        await batchUpdateIndexes(tableName, batch);
      }
    }
  }

  /// create primary index
  Future<void> createPrimaryIndex(String tableName, String primaryKey) async {
    try {
      final indexName = 'pk_$tableName';
      // create B+ tree
      final tree = BPlusTree(
        order: _dataStore.config.bTreeOrder,
        isUnique: true,
      );

      // register index
      _indexes[indexName] = tree;

      // create index file
      final schema = await _dataStore.getTableSchema(tableName);
      final indexPath =
          _dataStore.config.getIndexPath(tableName, indexName, schema.isGlobal);
      final indexFile = File(indexPath);
      await indexFile.create(recursive: true);
      _indexFiles[indexName] = indexFile;
    } catch (e) {
      Logger.error('create primary index failed: $e',
          label: 'IndexManager.createPrimaryIndex');
      rethrow;
    }
  }

  /// create normal index
  Future<void> createIndex(String tableName, IndexSchema schema) async {
    try {
      final indexName = schema.actualIndexName;

      // create B+ tree
      final tree = BPlusTree(
        order: _dataStore.config.bTreeOrder,
        isUnique: schema.unique,
      );

      // register index
      _indexes[indexName] = tree;

      // create index file
      final tableSchema = await _dataStore.getTableSchema(tableName);
      final indexPath = _dataStore.config
          .getIndexPath(tableName, indexName, tableSchema.isGlobal);
      final indexFile = File(indexPath);
      await indexFile.create(recursive: true);
      _indexFiles[indexName] = indexFile;
    } catch (e) {
      Logger.error('create index failed: $e',
          label: 'IndexManager.createIndex');
      rethrow;
    }
  }

  /// get index
  BPlusTree? getIndex(String indexName) {
    final index = _indexes[indexName];
    return index;
  }

  /// extract index key
  dynamic _extractIndexKey(String indexName, Map<String, dynamic> data) async {
    try {
      // get index definition
      final index = _indexes[indexName];
      if (index == null) {
        return null;
      }

      // get index field value
      if (indexName.startsWith('pk_')) {
        // primary index - extract primary key field name from table name
        final tableName = indexName.substring(3); // remove 'pk_' prefix
        final schema = await _dataStore.getTableSchema(tableName);
        final primaryKeyValue = data[schema.primaryKey];
        return primaryKeyValue;
      } else {
        // normal index or unique index - extract field name from index name
        final fieldName = indexName.split('_')[1]; // get field name
        final value = data[fieldName];
        return value;
      }
    } catch (e) {
      Logger.error('extract index key failed: $e',
          label: 'IndexManager._extractIndexKey');
      return null;
    }
  }

  /// create query plan
  Future<QueryPlan> createQueryPlan(
    String tableName,
    Map<String, dynamic>? where,
  ) async {
    if (where == null || where.isEmpty) {
      return QueryPlan([
        QueryOperation(
          type: QueryOperationType.tableScan,
          value: tableName,
        ),
      ]);
    }

    // find best index
    final bestIndex = await _findBestIndex(tableName, where);
    if (bestIndex != null) {
      return QueryPlan([
        QueryOperation(
          type: QueryOperationType.indexScan,
          indexName: bestIndex,
          value: where,
        ),
      ]);
    }

    return QueryPlan([
      QueryOperation(
        type: QueryOperationType.tableScan,
        value: tableName,
      ),
      QueryOperation(
        type: QueryOperationType.filter,
        value: where,
      ),
    ]);
  }

  /// find best index
  Future<String?> _findBestIndex(
      String tableName, Map<String, dynamic> where) async {
    try {
      final schema = await _dataStore.getTableSchema(tableName);

      // first check primary index
      if (where.containsKey(schema.primaryKey)) {
        return 'pk_$tableName';
      }

      // then check normal index
      for (var index in schema.indexes) {
        // Check if any index field is in where clause
        if (index.fields.any((field) => where.containsKey(field))) {
          return index.actualIndexName;
        }
      }

      return null;
    } catch (e) {
      Logger.error(
        'Failed to find best index: $e',
        label: 'IndexManager._findBestIndex',
      );
      return null;
    }
  }

  /// delete record from all indexes
  Future<void> deleteFromIndexes(
    String tableName,
    Map<String, dynamic> record,
  ) async {
    try {
      final schema = await _dataStore.getTableSchema(tableName);
      final primaryKeyValue = record[schema.primaryKey];

      // Delete from primary index
      final pkIndex = getIndex('pk_$tableName');
      if (pkIndex != null) {
        await pkIndex.delete(primaryKeyValue, primaryKeyValue.toString());
      }

      // Delete from secondary indexes
      for (var index in schema.indexes) {
        final indexKey = await _extractIndexKey(index.actualIndexName, record);
        if (indexKey != null) {
          final btIndex = getIndex(index.actualIndexName);
          if (btIndex != null) {
            await btIndex.delete(indexKey, primaryKeyValue.toString());
          }
        }
      }
    } catch (e) {
      Logger.error(
        'Failed to delete from indexes: $e',
        label: 'IndexManager.deleteFromIndexes',
      );
      rethrow;
    }
  }

  /// reset all indexes
  Future<void> resetIndexes(String tableName) async {
    try {
      // get table schema
      final schema = await _dataStore.getTableSchema(tableName);

      // reset primary index
      await createPrimaryIndex(tableName, schema.primaryKey);

      // reset other indexes
      for (var index in schema.indexes) {
        await createIndex(tableName, index);
      }
    } catch (e) {
      Logger.error('reset indexes failed: $e',
          label: 'IndexManager.resetIndexes');
      rethrow;
    }
  }

  /// Check unique constraints
  Future<void> checkUniqueConstraints(
      String tableName, Map<String, dynamic> record,
      {bool isUpdate = false}) async {
    try {
      final schema = await _dataStore.getTableSchema(tableName);
      final primaryKeyValue = record[schema.primaryKey];

      // Check unique indexes
      for (var index in schema.indexes.where((i) => i.unique)) {
        final indexKey = _createIndexKey(record, index.fields);
        if (indexKey == null) continue;

        final btIndex = getIndex(index.actualIndexName);
        if (btIndex == null) continue;

        final existingIds = await btIndex.search(indexKey);
        if (existingIds.isNotEmpty &&
            !existingIds.contains(primaryKeyValue.toString())) {
          throw BusinessError(
            'Unique constraint violation: ${index.fields.join(",")} = $indexKey',
            type: BusinessErrorType.uniqueError,
          );
        }
      }
    } catch (e) {
      Logger.error(
        'Failed to check unique constraints: $e',
        label: 'IndexManager.checkUniqueConstraints',
      );
      rethrow;
    }
  }

  /// batch update indexes
  Future<void> batchUpdateIndexes(
    String tableName,
    List<Map<String, dynamic>> records,
  ) async {
    try {
      final schema = await _dataStore.getTableSchema(tableName);
      final primaryKey = schema.primaryKey;

      // collect primary index updates
      final pkUpdates = <dynamic, RowPointer>{};
      // collect secondary index updates
      final secondaryUpdates = <String, Map<dynamic, List<dynamic>>>{};

      // preprocess batch data
      for (var record in records) {
        final data = record['data'] as Map<String, dynamic>;
        final pointer = RowPointer.fromString(record['pointer'] as String);
        final primaryKeyValue = data[primaryKey];

        if (primaryKeyValue != null) {
          // collect primary index updates
          pkUpdates[primaryKeyValue] = pointer;

          // collect secondary index updates
          for (var index in schema.indexes) {
            final indexName = index.actualIndexName;
            final indexKey = _createIndexKey(data, index.fields);
            if (indexKey != null) {
              secondaryUpdates
                  .putIfAbsent(indexName, () => {})
                  .putIfAbsent(indexKey, () => [])
                  .add(primaryKeyValue);
            }
          }
        }
      }

      // batch update primary index
      final pkIndex = getIndex('pk_$tableName');
      if (pkIndex != null) {
        for (var entry in pkUpdates.entries) {
          await pkIndex.insert(entry.key, entry.value.toString());
        }
      }

      // batch update secondary indexes
      for (var index in schema.indexes) {
        final indexName = index.actualIndexName;
        final btIndex = getIndex(indexName);
        final updates = secondaryUpdates[indexName];

        if (btIndex != null && updates != null) {
          for (var entry in updates.entries) {
            await btIndex.insert(entry.key, entry.value);
          }
        }
      }
    } catch (e, stack) {
      Logger.error('''batch update indexes failed: 
        error: $e
        stack: $stack
      ''', label: 'IndexManager.batchUpdateIndexes');
    }
  }

  /// handle base path changed
  void onBasePathChanged() {
    // clear index cache
    _indexes.clear();
    _indexFiles.clear();
    _indexBatchQueue.clear();
  }

  /// async update indexes
  void updateIndexesAsync(
    String tableName,
    Map<String, dynamic> data,
    RowPointer pointer,
  ) {
    _indexBatchQueue.putIfAbsent(tableName, () => []).add({
      'data': data,
      'pointer': pointer.toString(),
    });
  }

  /// get total size of all indexes
  Future<int> getTotalIndexSize() async {
    int totalSize = 0;
    try {
      for (var entry in _indexFiles.entries) {
        final file = entry.value;
        if (await file.exists()) {
          totalSize += await file.length();
        }
      }
    } catch (e) {
      Logger.error('get total index size failed: $e',
          label: 'IndexManager.getTotalIndexSize');
    }
    return totalSize;
  }

  /// Add index entry during migration
  Future<void> addIndexEntry(
    String tableName,
    String indexName,
    dynamic value,
    String recordId,
  ) async {
    try {
      final btIndex = getIndex(indexName);
      if (btIndex != null) {
        await btIndex.insert(value, recordId);
      }
    } catch (e) {
      Logger.error(
        'Failed to add index entry: $e',
        label: 'IndexManager.addIndexEntry',
      );
      rethrow;
    }
  }

  /// Invalidate index cache
  void invalidateCache(String tableName, String indexName) {
    final indexKey = '${tableName}_$indexName';
    _indexes.remove(indexKey);
    _indexBatchQueue.remove(indexKey);
  }

  /// Drop index for table
  Future<void> removeIndex(
    String tableName,
    String indexName,
  ) async {
    try {
      // Remove index from memory
      final key = '${tableName}_$indexName';
      _indexes.remove(key);
      _indexBatchQueue.remove(key);
      _indexFiles.remove(key);

      // Remove index file
      final schema = await _dataStore.getTableSchema(tableName);
      final indexPath = _dataStore.config.getIndexPath(
        tableName,
        indexName,
        schema.isGlobal,
      );
      final indexFile = File(indexPath);

      if (await indexFile.exists()) {
        await indexFile.delete();
      }
    } catch (e) {
      Logger.error(
        'Failed to remove index: $e',
        label: 'IndexManager.removeIndex',
      );
      rethrow;
    }
  }

  /// Create index key
  dynamic _createIndexKey(Map<String, dynamic> record, List<String> fields) {
    dynamic key;
    for (var field in fields) {
      key = record[field];
      if (key != null) {
        break;
      }
    }
    return key;
  }

  Future<Map<String, dynamic>?> getRecordByIndex(
    String tableName,
    String indexName,
    dynamic indexValue,
  ) async {
    try {
      final btIndex = getIndex(indexName);
      if (btIndex == null) return null;

      final pointer = await btIndex.search(indexValue);
      final rowPointer = await _dataStore.getRowPointer(tableName, pointer);
      if (rowPointer == null) return null;

      return await _dataStore.getRecordByPointer(tableName, rowPointer);
    } catch (e) {
      Logger.error(
        'Failed to get record by index: $e',
        label: 'IndexManager.getRecordByIndex',
      );
      return null;
    }
  }
}
