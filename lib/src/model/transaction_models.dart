import '../model/buffer_entry.dart';
import 'table_identity.dart';

/// Transaction status
enum TransactionStatus {
  pending,
  committed,
  rolledBack,
}

/// Append-only transaction log event kinds (`tx_*.log` / `status.log`).
///
/// [wireId] is the binary on-disk tag (stable; do not renumber).
/// [wireName] is only for legacy NDJSON migration.
enum TxnLogEventType {
  begin(1, 'begin'),
  commit(2, 'commit'),
  rollback(3, 'rollback'),
  plan(4, 'plan'),
  planPersisted(5, 'plan_persisted'),
  planProgress(6, 'plan_progress'),
  continueInNextPartition(7, 'continue_in_next_partition');

  const TxnLogEventType(this.wireId, this.wireName);

  /// Stable binary wire id (varint).
  final int wireId;

  /// Legacy NDJSON `event` string.
  final String wireName;

  static final Map<int, TxnLogEventType> _byWireId = {
    for (final e in TxnLogEventType.values) e.wireId: e,
  };

  static final Map<String, TxnLogEventType> _byWireName = {
    for (final e in TxnLogEventType.values) e.wireName: e,
  };

  static TxnLogEventType? fromWireId(int id) => _byWireId[id];

  static TxnLogEventType? fromWireName(String? name) {
    if (name == null || name.isEmpty) return null;
    return _byWireName[name] ?? _byWireName[name.toLowerCase()];
  }
}

/// A single operation within a transaction, captured with before-image for rollback
class TransactionEntry {
  final String transactionId;
  final TableUid tableUid;
  final BufferOperationType operation;
  final String primaryKeyName;
  final dynamic primaryKeyValue;
  final Map<String, dynamic>? beforeRecord;
  final DateTime timestamp;

  const TransactionEntry({
    required this.transactionId,
    required this.tableUid,
    required this.operation,
    required this.primaryKeyName,
    required this.primaryKeyValue,
    required this.beforeRecord,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() {
    return {
      'transactionId': transactionId,
      'tableUid': tableUid,
      'operation': operation.toString().split('.').last,
      'primaryKeyName': primaryKeyName,
      'primaryKeyValue': primaryKeyValue,
      'before': beforeRecord,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  factory TransactionEntry.fromJson(Map<String, dynamic> json) {
    final opStr = json['operation'] as String;
    final op = BufferOperationType.values.firstWhere(
        (e) => e.toString().split('.').last == opStr,
        orElse: () => BufferOperationType.insert);
    return TransactionEntry(
      transactionId: json['transactionId'] as String,
      tableUid: TableUid((json['tableUid'] ?? json['tableName']) as String),
      operation: op,
      primaryKeyName: json['primaryKeyName'] as String,
      primaryKeyValue: json['primaryKeyValue'],
      beforeRecord: json['before'] as Map<String, dynamic>?,
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }
}

/// Partition-level meta for transactions
class TransactionPartitionMeta {
  final int partitionIndex;
  int totalCount;
  int committedCount;
  int rolledBackCount;

  TransactionPartitionMeta({
    required this.partitionIndex,
    this.totalCount = 0,
    this.committedCount = 0,
    this.rolledBackCount = 0,
  });

  int get finishedCount => committedCount + rolledBackCount;

  TransactionPartitionMeta copyWith({
    int? partitionIndex,
    int? totalCount,
    int? committedCount,
    int? rolledBackCount,
  }) {
    return TransactionPartitionMeta(
      partitionIndex: partitionIndex ?? this.partitionIndex,
      totalCount: totalCount ?? this.totalCount,
      committedCount: committedCount ?? this.committedCount,
      rolledBackCount: rolledBackCount ?? this.rolledBackCount,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'partitionIndex': partitionIndex,
      'totalCount': totalCount,
      'committedCount': committedCount,
      'rolledBackCount': rolledBackCount,
    };
  }

  factory TransactionPartitionMeta.fromJson(Map<String, dynamic> json) {
    return TransactionPartitionMeta(
      partitionIndex: json['partitionIndex'] as int,
      totalCount: json['totalCount'] as int? ?? 0,
      committedCount: json['committedCount'] as int? ?? 0,
      rolledBackCount: json['rolledBackCount'] as int? ?? 0,
    );
  }
}

/// Space-level transaction main meta
class TransactionMainMeta {
  int currentPartitionIndex;
  final Set<int> activePartitions;

  TransactionMainMeta({
    this.currentPartitionIndex = 0,
    Set<int>? activePartitions,
  }) : activePartitions = activePartitions ?? <int>{0};

  TransactionMainMeta copyWith({
    int? currentPartitionIndex,
    Set<int>? activePartitions,
  }) {
    return TransactionMainMeta(
      currentPartitionIndex:
          currentPartitionIndex ?? this.currentPartitionIndex,
      activePartitions:
          activePartitions ?? Set<int>.from(this.activePartitions),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'currentPartitionIndex': currentPartitionIndex,
      'activePartitions': activePartitions.toList(),
    };
  }

  factory TransactionMainMeta.fromJson(Map<String, dynamic> json) {
    return TransactionMainMeta(
      currentPartitionIndex: json['currentPartitionIndex'] as int? ?? 0,
      activePartitions: (json['activePartitions'] as List<dynamic>?)
              ?.map((e) => e as int)
              .toSet() ??
          <int>{0},
    );
  }
}

/// Heavy delete plan descriptor for deferred execution at commit time
class HeavyDeletePlan {
  final TableUid tableUid;
  final Map<String, dynamic> condition; // normalized QueryCondition.build()
  final List<String>? orderBy;
  final int? limit;
  final int? offset;

  const HeavyDeletePlan({
    required this.tableUid,
    required this.condition,
    this.orderBy,
    this.limit,
    this.offset,
  });
}

/// Heavy update plan descriptor for deferred execution at commit time
class HeavyUpdatePlan {
  final TableUid tableUid;
  final Map<String, dynamic> condition; // normalized QueryCondition.build()
  final Map<String, dynamic> updateData; // data to update
  final List<String>? orderBy;
  final int? limit;
  final int? offset;

  const HeavyUpdatePlan({
    required this.tableUid,
    required this.condition,
    required this.updateData,
    this.orderBy,
    this.limit,
    this.offset,
  });
}

/// Compact commit plan persisted at commit time for crash recovery.
///
/// Disk encoding is binary ([TxnEncoder]); this model stays Map-based in memory.
class TransactionCommitPlan {
  final String transactionId;
  final Map<String, List<Map<String, dynamic>>>
      inserts; // table -> records (full)
  final Map<String, List<Map<String, dynamic>>>
      updates; // table -> records (full)
  final Map<String, List<Map<String, dynamic>>>
      deletes; // table -> records (full)
  final List<HeavyDeletePlan> heavyDeletes; // deferred heavy delete tasks
  final List<HeavyUpdatePlan> heavyUpdates; // deferred heavy update tasks

  TransactionCommitPlan({
    required this.transactionId,
    required this.inserts,
    required this.updates,
    required this.deletes,
    List<HeavyDeletePlan>? heavyDeletes,
    List<HeavyUpdatePlan>? heavyUpdates,
  })  : heavyDeletes = heavyDeletes ?? const <HeavyDeletePlan>[],
        heavyUpdates = heavyUpdates ?? const <HeavyUpdatePlan>[];
}
