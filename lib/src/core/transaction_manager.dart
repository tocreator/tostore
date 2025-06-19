import 'dart:collection';
import 'dart:convert';

import '../handler/logger.dart';
import 'data_store_impl.dart';

/// Transaction Manager
/// Handles database transaction lifecycle and ensures ACID properties
class TransactionManager {
  final DataStoreImpl _dataStore;
  final Map<String, Transaction> _activeTransactions = {};
  final Map<String, List<Map<String, dynamic>>> _transactionBatches = {};
  final Queue<String> _completedTransactions = Queue();
  static const int _maxCompletedTransactions = 1000;

  TransactionManager(this._dataStore);

  /// Log operation details
  /// [operation] Operation type
  /// [tableName] Target table name
  /// [data] Operation data
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

    final logPath =
        await _dataStore.pathManager.getTransactionLogPath(tableName);

    await _dataStore.storage.writeAsString(
      logPath,
      '${jsonEncode(logEntry)}\n',
      append: true,
    );
  }

  /// Begin a new transaction
  /// Returns transaction instance with unique ID
  Future<Transaction> beginTransaction() async {
    final transaction = Transaction(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      startTime: DateTime.now(),
    );
    _activeTransactions[transaction.id] = transaction;
    _transactionBatches[transaction.id] = [];
    return transaction;
  }

  /// Commit transaction
  /// [transaction] Transaction to commit
  Future<void> commit(Transaction? transaction) async {
    if (transaction == null) return;

    try {
      // Process batch operations
      final batch = _transactionBatches[transaction.id];
      if (batch != null && batch.isNotEmpty) {
        await _processBatch(batch);
      }

      // Mark transaction as committed
      transaction.isCommitted = true;

      // Record completed transaction
      _completedTransactions.addFirst(transaction.id);
      if (_completedTransactions.length > _maxCompletedTransactions) {
        _completedTransactions.removeLast();
      }

      // Clean up transaction data
      _activeTransactions.remove(transaction.id);
      _transactionBatches.remove(transaction.id);
    } catch (e) {
      Logger.error('Transaction commit failed: $e',
          label: 'TransactionManager.commit');
      await rollback(transaction);
      rethrow;
    }
  }

  /// Rollback transaction
  /// [transaction] Transaction to rollback
  Future<void> rollback(Transaction? transaction) async {
    if (transaction == null) return;

    try {
      // Mark transaction as rolled back
      transaction.isCommitted = false;

      // Clean up transaction data
      _activeTransactions.remove(transaction.id);
      _transactionBatches.remove(transaction.id);
    } catch (e) {
      Logger.error('Transaction rollback failed: $e',
          label: 'TransactionManager.rollback');
      rethrow;
    }
  }

  /// Add operation to transaction batch
  /// [transactionId] Target transaction ID
  /// [operation] Operation details
  void addToBatch(String transactionId, Map<String, dynamic> operation) {
    _transactionBatches[transactionId]?.add(operation);
  }

  /// Process batch operations
  Future<void> _processBatch(List<Map<String, dynamic>> batch) async {
    for (var operation in batch) {
      try {
        await _processOperation(operation);
        await logOperation(
            operation['type'], operation['table'], operation['data']);
      } catch (e) {
        Logger.error('Processing operation failed: $e',
            label: 'TransactionManager._processBatch');
        rethrow;
      }
    }
  }

  /// Process single operation
  Future<void> _processOperation(Map<String, dynamic> operation) async {
    final tableName = operation['table'] as String;
    final tableDataManager = _dataStore.tableDataManager;

    switch (operation['type']) {
      case 'insert':
        await tableDataManager.addToWriteBuffer(tableName, operation['data'],
            isUpdate: false);
        break;
      case 'update':
        await tableDataManager.processTablePartitions(
          tableName: tableName,
          processFunction:
              (List<Map<String, dynamic>> records, int partitionIndex) async {
            return records
                .map<Map<String, dynamic>>((Map<String, dynamic> record) {
              if (record['id'] == operation['data']['id']) {
                return {...record, ...operation['data']};
              }
              return record;
            }).toList();
          },
        );
        break;
      case 'delete':
        await tableDataManager.processTablePartitions(
          tableName: tableName,
          processFunction:
              (List<Map<String, dynamic>> records, int partitionIndex) async {
            return records
                .where((Map<String, dynamic> record) =>
                    record['id'] != operation['data']['id'])
                .toList()
                .cast<Map<String, dynamic>>();
          },
        );
        break;
    }
  }

  /// Check if transaction is active
  bool isTransactionActive(String transactionId) {
    return _activeTransactions.containsKey(transactionId);
  }

  /// Get count of active transactions
  int get activeTransactionCount => _activeTransactions.length;

  /// Clean up expired transactions
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

/// Transaction class
/// Represents a database transaction with lifecycle management
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

  /// Check if transaction has expired
  bool get isExpired => DateTime.now().difference(startTime) > _timeout;
}
