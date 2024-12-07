import 'dart:async';
import 'dart:io';

import '../handler/logger.dart';

import 'data_store_impl.dart';
import 'b_plus_tree.dart';
import '../model/row_pointer.dart';
import '../model/table_schema.dart';
import '../query/query_plan.dart';

/// 索引管理器
class IndexManager {
  final DataStoreImpl _dataStore;
  final Map<String, BPlusTree> _indexes = {};
  final Map<String, List<Map<String, dynamic>>> _indexBatchQueue = {};
  final Map<String, File> _indexFiles = {};

  // 添加最后更新时间记录
  DateTime? _lastUpdateTime;
  Timer? _updateTimer;
  static const Duration _updateInterval = Duration(seconds: 10);

  IndexManager(this._dataStore) {
    // 启动定时器检查更新
    _startUpdateTimer();
  }

  void _startUpdateTimer() {
    _updateTimer = Timer.periodic(_updateInterval, (_) => _checkAndUpdate());
  }

  void dispose() {
    _updateTimer?.cancel();
    _updateTimer = null;
  }

  /// 检查并执行更新
  Future<void> _checkAndUpdate() async {
    final now = DateTime.now();
    if (_lastUpdateTime == null ||
        now.difference(_lastUpdateTime!) >= _updateInterval) {
      // 处理所有表的待更新索引
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

  /// 更新索引
  Future<void> updateIndexes(
    String tableName,
    Map<String, dynamic> data,
    RowPointer pointer,
  ) async {
    // 添加到批处理队列
    _indexBatchQueue.putIfAbsent(tableName, () => []).add({
      'data': data,
      'pointer': pointer.toString(),
    });
  }

  /// 强制执行所有待更新的索引
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

  /// 创建主键索引
  Future<void> createPrimaryIndex(String tableName, String primaryKey) async {
    try {
      final indexName = 'pk_$tableName';
      // 创建 B+ 树
      final tree = BPlusTree(
        order: _dataStore.config.bTreeOrder,
        isUnique: true,
      );

      // 注册索引
      _indexes[indexName] = tree;

      // 创建索引文件
      final schema = await _dataStore.getTableSchema(tableName);
      final indexPath =
          _dataStore.config.getIndexPath(tableName, indexName, schema.isGlobal);
      final indexFile = File(indexPath);
      await indexFile.create(recursive: true);
      _indexFiles[indexName] = indexFile;
    } catch (e) {
      Logger.error('创建主键索引失败: $e', label: 'IndexManager.createPrimaryIndex');
      rethrow;
    }
  }

  /// 创建普通索引
  Future<void> createIndex(String tableName, IndexSchema schema) async {
    try {
      final indexName = schema.actualIndexName;

      // 创建 B+ 树
      final tree = BPlusTree(
        order: _dataStore.config.bTreeOrder,
        isUnique: schema.unique,
      );

      // 注册索引
      _indexes[indexName] = tree;

      // 创建索引文件
      final tableSchema = await _dataStore.getTableSchema(tableName);
      final indexPath = _dataStore.config
          .getIndexPath(tableName, indexName, tableSchema.isGlobal);
      final indexFile = File(indexPath);
      await indexFile.create(recursive: true);
      _indexFiles[indexName] = indexFile;
    } catch (e) {
      Logger.error('创建索引失败: $e', label: 'IndexManager.createIndex');
      rethrow;
    }
  }

  /// 获取索引
  BPlusTree? getIndex(String indexName) {
    final index = _indexes[indexName];
    return index;
  }

  /// 提取索引键
  dynamic _extractIndexKey(String indexName, Map<String, dynamic> data) async {
    try {
      // 获取索引定义
      final index = _indexes[indexName];
      if (index == null) {
        Logger.warn('警告: 索引 $indexName 未找到');
        return null;
      }

      // 获取索引字段的值
      if (indexName.startsWith('pk_')) {
        // 主键索引 - 从表名中提取主键字段名
        final tableName = indexName.substring(3); // 去掉 'pk_' 前缀
        final schema = await _dataStore.getTableSchema(tableName);
        final primaryKeyValue = data[schema.primaryKey];
        return primaryKeyValue;
      } else {
        // 普通索引或唯一索引 - 直接从索引名提取字段名
        final fieldName = indexName.split('_')[1]; // 获取字段名部分
        final value = data[fieldName];
        return value;
      }
    } catch (e) {
      Logger.error('提取索引键失败: $e', label: 'IndexManager._extractIndexKey');
      return null;
    }
  }

  /// 创建查询计划
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

    // 查找最佳索引
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

  /// 查找最佳索引
  String? _findBestIndex(String tableName, Map<String, dynamic> where) {
    // 首先检查主键索引
    if (where.containsKey('id') && _indexes.containsKey('id_pk')) {
      return 'id_pk';
    }

    // 然后检查普通索引
    for (var key in where.keys) {
      final idxName = '${key}_idx';
      if (_indexes.containsKey(idxName)) {
        return idxName;
      }
    }

    return null;
  }

  /// 从所有索引中删除记录
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

  /// 重新初始化所有索引
  Future<void> resetIndexes(String tableName) async {
    try {
      // 获取表结构
      final schema = await _dataStore.getTableSchema(tableName);

      // 重新创建主键索引
      await createPrimaryIndex(tableName, schema.primaryKey);

      // 重新创建其他索引
      for (var index in schema.indexes) {
        await createIndex(tableName, index);
      }
    } catch (e) {
      Logger.error('重置索引失败: $e', label: 'IndexManager.resetIndexes');
      rethrow;
    }
  }

  /// 检查唯一约束
  Future<void> checkUniqueConstraints(
      String tableName, Map<String, dynamic> data) async {
    try {
      // 检查所有唯一索引约束
      for (var entry in _indexes.entries) {
        if (entry.value.isUnique) {
          final indexName = entry.key;
          final indexKey = await _extractIndexKey(indexName, data);
          if (indexKey != null) {
            final existingValues = await entry.value.search(indexKey);
            if (existingValues.isNotEmpty) {
              // 如果是更新操作，检查是否是同一条记录
              if (existingValues.first['id'] != data['id']) {
                // 如果是主键索引，抛出重复键错误
                if (indexName == 'id_pk') {
                  throw StateError('主键重复: ${data['id']}');
                }
                // 如果是唯一索引，抛出复值错误
                final fieldName = indexName.split('_')[0]; // 从索引名获取字段名
                Logger.warn('字段 $fieldName 的值 $indexKey 已存在');
                throw StateError('字段 $fieldName 的值 $indexKey 已存在');
              }
            }
          }
        }
      }
    } catch (e) {
      Logger.error('检查唯一约束失败: $e',
          label: 'IndexManager.checkUniqueConstraints');
      rethrow;
    }
  }

  /// 批量更新索引
  Future<void> batchUpdateIndexes(
      String tableName, List<Map<String, dynamic>> records) async {
    try {
      final schema = await _dataStore.getTableSchema(tableName);
      final primaryKey = schema.primaryKey;

      // 收集主键索引更新
      final pkUpdates = <dynamic, RowPointer>{};
      // 收集二级索引更新
      final secondaryUpdates = <String, Map<dynamic, List<dynamic>>>{};

      // 预处理批次数据
      for (var record in records) {
        final data = record['data'] as Map<String, dynamic>;
        final pointer = RowPointer.fromString(record['pointer'] as String);
        final primaryKeyValue = data[primaryKey];

        if (primaryKeyValue != null) {
          // 收集主键索引更新
          pkUpdates[primaryKeyValue] = pointer;

          // 收集二级索引更新
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

      // 批量更新主键索引
      final pkIndex = getIndex('pk_$tableName');
      if (pkIndex != null) {
        for (var entry in pkUpdates.entries) {
          await pkIndex.insert(entry.key, entry.value);
        }
      }

      // 批量更新二级索引
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
      Logger.error('''批量更新索引失败: 
        error: $e
        stack: $stack
      ''', label: 'IndexManager.batchUpdateIndexes');
    }
  }

  /// 处理基础空间变更
  void onBasePathChanged() {
    // 清理索引缓存
    _indexes.clear();
    _indexFiles.clear();
    _indexBatchQueue.clear();
  }

  /// 异步更新索引
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

  /// 获取所有索引的总大小
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
      Logger.error('获取索引大小失败: $e', label: 'IndexManager.getTotalIndexSize');
    }
    return totalSize;
  }
}
