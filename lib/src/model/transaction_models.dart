import '../model/buffer_entry.dart';

/// Transaction status
enum TransactionStatus {
  pending,
  committed,
  rolledBack,
}

/// A single operation within a transaction, captured with before-image for rollback
class TransactionEntry {
  final String transactionId;
  final String tableName;
  final BufferOperationType operation;
  final String primaryKeyName;
  final dynamic primaryKeyValue;
  final Map<String, dynamic>? beforeRecord;
  final DateTime timestamp;

  const TransactionEntry({
    required this.transactionId,
    required this.tableName,
    required this.operation,
    required this.primaryKeyName,
    required this.primaryKeyValue,
    required this.beforeRecord,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() {
    return {
      'transactionId': transactionId,
      'tableName': tableName,
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
      tableName: json['tableName'] as String,
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
  final String tableName;
  final Map<String, dynamic> condition; // normalized QueryCondition.build()
  final List<String>? orderBy;
  final int? limit;
  final int? offset;

  const HeavyDeletePlan({
    required this.tableName,
    required this.condition,
    this.orderBy,
    this.limit,
    this.offset,
  });

  Map<String, dynamic> toJson() {
    return {
      'tableName': tableName,
      'condition': condition,
      if (orderBy != null) 'orderBy': orderBy,
      if (limit != null) 'limit': limit,
      if (offset != null) 'offset': offset,
    };
  }

  factory HeavyDeletePlan.fromJson(Map<String, dynamic> json) {
    return HeavyDeletePlan(
      tableName: json['tableName'] as String,
      condition: (json['condition'] as Map).cast<String, dynamic>(),
      orderBy: (json['orderBy'] as List?)?.cast<String>(),
      limit: (json['limit'] as num?)?.toInt(),
      offset: (json['offset'] as num?)?.toInt(),
    );
  }
}

/// Heavy update plan descriptor for deferred execution at commit time
class HeavyUpdatePlan {
  final String tableName;
  final Map<String, dynamic> condition; // normalized QueryCondition.build()
  final Map<String, dynamic> updateData; // data to update
  final List<String>? orderBy;
  final int? limit;
  final int? offset;

  const HeavyUpdatePlan({
    required this.tableName,
    required this.condition,
    required this.updateData,
    this.orderBy,
    this.limit,
    this.offset,
  });

  Map<String, dynamic> toJson() {
    return {
      'tableName': tableName,
      'condition': condition,
      'updateData': updateData,
      if (orderBy != null) 'orderBy': orderBy,
      if (limit != null) 'limit': limit,
      if (offset != null) 'offset': offset,
    };
  }

  factory HeavyUpdatePlan.fromJson(Map<String, dynamic> json) {
    return HeavyUpdatePlan(
      tableName: json['tableName'] as String,
      condition: (json['condition'] as Map).cast<String, dynamic>(),
      updateData: (json['updateData'] as Map).cast<String, dynamic>(),
      orderBy: (json['orderBy'] as List?)?.cast<String>(),
      limit: (json['limit'] as num?)?.toInt(),
      offset: (json['offset'] as num?)?.toInt(),
    );
  }
}

/// Compact commit plan persisted at commit time for crash recovery
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

  Map<String, dynamic> toJson() {
    return {
      'transactionId': transactionId,
      'inserts': inserts,
      'updates': updates,
      'deletes': deletes,
      if (heavyDeletes.isNotEmpty)
        'heavyDeletes': heavyDeletes.map((e) => e.toJson()).toList(),
      if (heavyUpdates.isNotEmpty)
        'heavyUpdates': heavyUpdates.map((e) => e.toJson()).toList(),
    };
  }

  factory TransactionCommitPlan.fromJson(Map<String, dynamic> json) {
    return TransactionCommitPlan(
      transactionId: json['transactionId'] as String,
      inserts: (json['inserts'] as Map<String, dynamic>?)?.map((k, v) =>
              MapEntry(k, (v as List).cast<Map<String, dynamic>>())) ??
          <String, List<Map<String, dynamic>>>{},
      updates: (json['updates'] as Map<String, dynamic>?)?.map((k, v) =>
              MapEntry(k, (v as List).cast<Map<String, dynamic>>())) ??
          <String, List<Map<String, dynamic>>>{},
      deletes: (json['deletes'] as Map<String, dynamic>?)?.map((k, v) =>
              MapEntry(k, (v as List).cast<Map<String, dynamic>>())) ??
          <String, List<Map<String, dynamic>>>{},
      heavyDeletes: (json['heavyDeletes'] as List?)
              ?.map((e) =>
                  HeavyDeletePlan.fromJson((e as Map).cast<String, dynamic>()))
              .toList() ??
          const <HeavyDeletePlan>[],
      heavyUpdates: (json['heavyUpdates'] as List?)
              ?.map((e) =>
                  HeavyUpdatePlan.fromJson((e as Map).cast<String, dynamic>()))
              .toList() ??
          const <HeavyUpdatePlan>[],
    );
  }
}
