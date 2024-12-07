import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import '../handler/logger.dart';
import 'data_store_impl.dart';

/// 事务管理器
class TransactionManager {
  final DataStoreImpl _dataStore;
  final Map<String, Transaction> _activeTransactions = {};
  final Map<String, List<Map<String, dynamic>>> _transactionBatches = {};
  final Queue<String> _completedTransactions = Queue();
  static const int _maxCompletedTransactions = 1000;

  TransactionManager(this._dataStore);

  /// 记录操作日志
  Future<void> logOperation(
    String operation,
    String tableName,
    dynamic data,
  ) async {
    final logEntry = {
      'timestamp': DateTime.now().toIso8601String(),
      'operation': operation,
      'table': tableName,
      'data': data,
    };

    final logPath = await _dataStore.getTablePath(tableName);
    final logFile = File('$logPath.transaction.log');
    await logFile.writeAsString(
      '${jsonEncode(logEntry)}\n',
      mode: FileMode.append,
    );
  }

  /// 开始事务
  Future<Transaction> beginTransaction() async {
    final transaction = Transaction(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      startTime: DateTime.now(),
    );
    _activeTransactions[transaction.id] = transaction;
    _transactionBatches[transaction.id] = [];
    return transaction;
  }

  /// 提交事务
  Future<void> commit(Transaction? transaction) async {
    if (transaction == null) return;

    try {
      // 批量处理事务操作
      final batch = _transactionBatches[transaction.id];
      if (batch != null && batch.isNotEmpty) {
        await _processBatch(batch);
      }

      // 记录已完成事务
      _completedTransactions.addFirst(transaction.id);
      if (_completedTransactions.length > _maxCompletedTransactions) {
        _completedTransactions.removeLast();
      }

      // 清理事务数据
      _activeTransactions.remove(transaction.id);
      _transactionBatches.remove(transaction.id);
    } catch (e) {
      Logger.error('提交事务失败: $e', label: 'TransactionManager.commit');
      await rollback(transaction);
      rethrow;
    }
  }

  /// 回滚事务
  Future<void> rollback(Transaction? transaction) async {
    if (transaction == null) return;

    try {
      // 清理事务数据
      _activeTransactions.remove(transaction.id);
      _transactionBatches.remove(transaction.id);
    } catch (e) {
      Logger.error('回滚事务失败: $e', label: 'TransactionManager.rollback');
      rethrow;
    }
  }

  /// 添加操作到事务批处理
  void addToBatch(String transactionId, Map<String, dynamic> operation) {
    _transactionBatches[transactionId]?.add(operation);
  }

  /// 处理批处理操作
  Future<void> _processBatch(List<Map<String, dynamic>> batch) async {
    for (var operation in batch) {
      await _processOperation(operation);
    }
  }

  /// 处理单个操作
  Future<void> _processOperation(Map<String, dynamic> operation) async {
    final tableName = operation['table'] as String;
    final dataPath = await _dataStore.getTablePath(tableName);
    final dataFile = File('$dataPath.dat');

    switch (operation['type']) {
      case 'insert':
        await dataFile.writeAsString(
          '${jsonEncode(operation['data'])}\n',
          mode: FileMode.append,
        );
        break;
      // ... 其他操作类型处理 ...
    }
  }

  /// 检查事务状态
  bool isTransactionActive(String transactionId) {
    return _activeTransactions.containsKey(transactionId);
  }

  /// 获取活跃事务数量
  int get activeTransactionCount => _activeTransactions.length;

  /// 清理过期事务
  Future<void> cleanupExpiredTransactions() async {
    final now = DateTime.now();
    final expiredIds = _activeTransactions.entries
        .where((entry) => now.difference(entry.value.startTime).inMinutes > 5)
        .map((entry) => entry.key)
        .toList();

    for (var id in expiredIds) {
      await rollback(_activeTransactions[id]);
    }
  }
}

/// 事务类
class Transaction {
  final String id;
  final DateTime startTime;
  bool isCommitted = false;
  bool isRolledBack = false;
  static const Duration _timeout = Duration(minutes: 5);

  Transaction({
    required this.id,
    required this.startTime,
  });

  /// 检查事务是否过期
  bool get isExpired => DateTime.now().difference(startTime) > _timeout;
}
