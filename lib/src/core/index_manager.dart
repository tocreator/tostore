import 'dart:async';
import 'dart:io';

import '../handler/logger.dart';

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
    Map<String, dynamic> data,
    RowPointer pointer,
  ) async {
    // add to batch queue
    _indexBatchQueue.putIfAbsent(tableName, () => []).add({
      'data': data,
      'pointer': pointer.toString(),
    });
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
        Logger.warn('警告: 索引 $indexName 未找到');
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
    final bestIndex = _findBestIndex(tableName, where);
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
  String? _findBestIndex(String tableName, Map<String, dynamic> where) {
    // first check primary index
    if (where.containsKey('id') && _indexes.containsKey('id_pk')) {
      return 'id_pk';
    }

    // then check normal index
    for (var key in where.keys) {
      final idxName = '${key}_idx';
      if (_indexes.containsKey(idxName)) {
        return idxName;
      }
    }

    return null;
  }

  /// delete record from all indexes
  Future<void> deleteFromIndexes(
      String tableName, Map<String, dynamic> record) async {
    for (var entry in _indexes.entries) {
      final indexName = entry.key;
      final indexKey = await _extractIndexKey(indexName, record);
      if (indexKey != null) {
        await entry.value.delete(indexKey, record);
      }
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

  /// check unique constraints
  Future<void> checkUniqueConstraints(
      String tableName, Map<String, dynamic> data) async {
    try {
      // check all unique index constraints
      for (var entry in _indexes.entries) {
        if (entry.value.isUnique) {
          final indexName = entry.key;
          final indexKey = await _extractIndexKey(indexName, data);
          if (indexKey != null) {
            final existingValues = await entry.value.search(indexKey);
            if (existingValues.isNotEmpty) {
              // if update operation, check if it is the same record
              if (existingValues.first['id'] != data['id']) {
                // if primary index, throw duplicate key error
                if (indexName == 'id_pk') {
                  throw StateError('duplicate primary key: ${data['id']}');
                }
                // if unique index, throw duplicate value error
                final fieldName =
                    indexName.split('_')[0]; // get field name from index name
                Logger.warn('field $fieldName value $indexKey already exists');
                throw StateError(
                    'field $fieldName value $indexKey already exists');
              }
            }
          }
        }
      }
    } catch (e) {
      Logger.error('check unique constraints failed: $e',
          label: 'IndexManager.checkUniqueConstraints');
      rethrow;
    }
  }

  /// batch update indexes
  Future<void> batchUpdateIndexes(
      String tableName, List<Map<String, dynamic>> records) async {
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
            final indexValue = data[index.fields.first];
            if (indexValue != null) {
              secondaryUpdates
                  .putIfAbsent(indexName, () => {})
                  .putIfAbsent(indexValue, () => [])
                  .add(primaryKeyValue);
            }
          }
        }
      }

      // batch update primary index
      final pkIndex = getIndex('pk_$tableName');
      if (pkIndex != null) {
        for (var entry in pkUpdates.entries) {
          await pkIndex.insert(entry.key, entry.value);
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
}
