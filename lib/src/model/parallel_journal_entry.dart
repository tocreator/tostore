/// Typed journal entry models for parallel processing A/B journal.
/// Keep JSON schema compatible with existing map-based entries.

abstract class ParallelJournalEntry {
  String get type; // discriminator
  Map<String, dynamic> toJson();

  static ParallelJournalEntry? fromJson(Map<String, dynamic> json) {
    final t = json['type'] as String?;
    switch (t) {
      case 'batchStart':
        return BatchStartEntry.fromJson(json);
      case 'taskDone':
        return TaskDoneEntry.fromJson(json);
      case 'tablePartitionFlushed':
        return TablePartitionFlushedEntry.fromJson(json);
      case 'tableMetaUpdated':
        return TableMetaUpdatedEntry.fromJson(json);
      case 'indexPartitionFlushed':
        return IndexPartitionFlushedEntry.fromJson(json);
      case 'indexMetaUpdated':
        return IndexMetaUpdatedEntry.fromJson(json);
      case 'batchCompleted':
        return BatchCompletedEntry.fromJson(json);
      default:
        return null;
    }
  }
}

class WalPointerRef {
  final int partitionIndex;
  final int entrySeq;
  const WalPointerRef({required this.partitionIndex, required this.entrySeq});
  Map<String, dynamic> toJson() => {
        'partitionIndex': partitionIndex,
        'entrySeq': entrySeq,
      };
  static WalPointerRef fromJson(Map<String, dynamic> json) => WalPointerRef(
        partitionIndex: json['partitionIndex'] as int,
        entrySeq: json['entrySeq'] as int,
      );
}

class TablePlan {
  final bool willUpdateTableMeta;
  final List<String> indexes;
  final bool willUpdateIndexMeta;
  final int? baseTotalRecords;
  final int? baseTotalSizeInBytes;
  final Map<String, int>? baseIndexTotalEntries;
  final Map<String, int>? baseIndexTotalSizeInBytes;

  const TablePlan({
    required this.willUpdateTableMeta,
    required this.indexes,
    required this.willUpdateIndexMeta,
    this.baseTotalRecords,
    this.baseTotalSizeInBytes,
    this.baseIndexTotalEntries,
    this.baseIndexTotalSizeInBytes,
  });

  Map<String, dynamic> toJson() => {
        'willUpdateTableMeta': willUpdateTableMeta,
        'indexes': indexes,
        'willUpdateIndexMeta': willUpdateIndexMeta,
        if (baseTotalRecords != null) 'baseTotalRecords': baseTotalRecords,
        if (baseTotalSizeInBytes != null)
          'baseTotalSizeInBytes': baseTotalSizeInBytes,
        if (baseIndexTotalEntries != null)
          'baseIndexTotalEntries': baseIndexTotalEntries,
        if (baseIndexTotalSizeInBytes != null)
          'baseIndexTotalSizeInBytes': baseIndexTotalSizeInBytes,
      };

  static TablePlan fromJson(Map<String, dynamic> json) => TablePlan(
        willUpdateTableMeta: json['willUpdateTableMeta'] as bool? ?? true,
        indexes: ((json['indexes'] as List?) ?? const <dynamic>[])
            .map((e) => e.toString())
            .toList(),
        willUpdateIndexMeta: json['willUpdateIndexMeta'] as bool? ?? false,
        baseTotalRecords: json['baseTotalRecords'] as int?,
        baseTotalSizeInBytes: json['baseTotalSizeInBytes'] as int?,
        baseIndexTotalEntries: (json['baseIndexTotalEntries'] as Map?)
            ?.cast<String, int>()
            .map((k, v) => MapEntry(k, v)),
        baseIndexTotalSizeInBytes: (json['baseIndexTotalSizeInBytes'] as Map?)
            ?.cast<String, int>()
            .map((k, v) => MapEntry(k, v)),
      );
}

class BatchStartEntry extends ParallelJournalEntry {
  @override
  final String type = 'batchStart';
  final String at;
  final WalPointerRef start;
  final WalPointerRef end;
  final int size;
  final Map<String, Map<int, int>> plan; // table -> op.index -> count
  final Map<String, TablePlan> tablePlan;
  final String batchId;
  final BatchType batchType;
  BatchStartEntry({
    required this.at,
    required this.start,
    required this.end,
    required this.size,
    required this.plan,
    required this.tablePlan,
    required this.batchId,
    required this.batchType,
  });
  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'at': at,
        'start': start.toJson(),
        'end': end.toJson(),
        'size': size,
        'plan': plan.map(
          (table, byOp) => MapEntry(
            table,
            byOp.map(
              (opIdx, count) => MapEntry(opIdx.toString(), count),
            ),
          ),
        ),
        'tablePlan': tablePlan.map((k, v) => MapEntry(k, v.toJson())),
        'batchId': batchId,
        'batchType': batchType.value,
        // Keep backward-compatibility key
        'scope': batchType.value,
      };
  static BatchStartEntry fromJson(Map<String, dynamic> json) => BatchStartEntry(
        at: (json['at'] as String?) ?? '',
        start: WalPointerRef.fromJson(
            (json['start'] as Map).cast<String, dynamic>()),
        end: WalPointerRef.fromJson(
            (json['end'] as Map).cast<String, dynamic>()),
        size: json['size'] as int? ?? 0,
        plan: (json['plan'] as Map?)
                ?.map((k, v) => MapEntry(
                    k.toString(),
                    ((v as Map?) ?? const {}).map((ik, iv) => MapEntry(
                        int.parse(ik.toString()), (iv as num).toInt()))))
                .cast<String, Map<int, int>>() ??
            <String, Map<int, int>>{},
        tablePlan: (json['tablePlan'] as Map?)
                ?.map((k, v) => MapEntry(
                    k.toString(),
                    TablePlan.fromJson(
                        ((v as Map?) ?? const {}).cast<String, dynamic>())))
                .cast<String, TablePlan>() ??
            <String, TablePlan>{},
        batchId: (json['batchId'] as String?) ?? '',
        batchType: BatchType.fromStringOrFlush(
            (json['batchType'] as String?) ?? (json['scope'] as String?)),
      );
}

class TaskDoneEntry extends ParallelJournalEntry {
  @override
  final String type = 'taskDone';
  final String at;
  final String table;
  final int count;
  final String? batchId;
  final BatchType? batchType;
  TaskDoneEntry(
      {required this.at,
      required this.table,
      required this.count,
      this.batchId,
      this.batchType});
  @override
  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{
      'type': type,
      'at': at,
      'table': table,
      'count': count,
    };
    if (batchId != null) result['batchId'] = batchId;
    if (batchType != null) result['batchType'] = batchType!.value;
    return result;
  }

  static TaskDoneEntry fromJson(Map<String, dynamic> json) => TaskDoneEntry(
        at: (json['at'] as String?) ?? '',
        table: (json['table'] as String?) ?? '',
        count: (json['count'] as num?)?.toInt() ?? 0,
        batchId: (json['batchId'] as String?),
        batchType: BatchType.fromString(
            (json['batchType'] as String?) ?? (json['scope'] as String?)),
      );
}

class TablePartitionFlushedEntry extends ParallelJournalEntry {
  @override
  final String type = 'tablePartitionFlushed';
  final String table;
  final int partitionNo; // Physical partition number (0-based)
  final int? totalRecords; // Total records in table after this partition flush
  final int? totalSizeInBytes; // Total size in bytes after this partition flush
  final String batchId;
  final BatchType batchType;
  TablePartitionFlushedEntry({
    required this.table,
    required this.partitionNo,
    this.totalRecords, // New: complete table statistics
    this.totalSizeInBytes, // New: complete table statistics
    required this.batchId,
    required this.batchType,
  });
  @override
  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{
      'type': type,
      'table': table,
      'partitionNo': partitionNo,
      'batchId': batchId,
      'batchType': batchType.value,
    };
    // Include new fields if present
    if (totalRecords != null) result['totalRecords'] = totalRecords;
    if (totalSizeInBytes != null) result['totalSizeInBytes'] = totalSizeInBytes;
    return result;
  }

  static TablePartitionFlushedEntry fromJson(Map<String, dynamic> json) {
    // Backward compatibility: support old format with 'partition' and 'meta'
    int partitionNo = 0;

    if (json.containsKey('partitionNo')) {
      // New format
      partitionNo = (json['partitionNo'] as num?)?.toInt() ?? 0;
    }

    // New fields: complete table statistics (preferred for recovery)
    final totalRecords = (json['totalRecords'] as num?)?.toInt();
    final totalSizeInBytes = (json['totalSizeInBytes'] as num?)?.toInt();

    return TablePartitionFlushedEntry(
      table: (json['table'] as String?) ?? '',
      partitionNo: partitionNo,
      totalRecords: totalRecords,
      totalSizeInBytes: totalSizeInBytes,
      batchId: (json['batchId'] as String?) ?? '',
      batchType: BatchType.fromStringOrFlush(
          (json['batchType'] as String?) ?? (json['scope'] as String?)),
    );
  }
}

class TableMetaUpdatedEntry extends ParallelJournalEntry {
  @override
  final String type = 'tableMetaUpdated';
  final String table;
  final String? batchId;
  final BatchType? batchType;
  TableMetaUpdatedEntry({required this.table, this.batchId, this.batchType});
  @override
  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{
      'type': type,
      'table': table,
    };
    if (batchId != null) result['batchId'] = batchId;
    if (batchType != null) result['batchType'] = batchType!.value;
    return result;
  }

  static TableMetaUpdatedEntry fromJson(Map<String, dynamic> json) =>
      TableMetaUpdatedEntry(
        table: (json['table'] as String?) ?? '',
        batchId: (json['batchId'] as String?),
        batchType: BatchType.fromString(
            (json['batchType'] as String?) ?? (json['scope'] as String?)),
      );
}

class IndexPartitionFlushedEntry extends ParallelJournalEntry {
  @override
  final String type = 'indexPartitionFlushed';
  final String table;
  final String index;
  final int partitionNo; // Physical partition number (0-based)
  // New fields: complete index metadata statistics after this partition was flushed
  final int? totalEntries; // Total entries in index after this partition flush
  final int? totalSizeInBytes; // Total size in bytes after this partition flush
  final String batchId;
  final BatchType batchType;
  IndexPartitionFlushedEntry({
    required this.table,
    required this.index,
    required this.partitionNo,
    this.totalEntries, // New: complete index statistics
    this.totalSizeInBytes, // New: complete index statistics
    required this.batchId,
    required this.batchType,
  });
  @override
  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{
      'type': type,
      'table': table,
      'index': index,
      'partitionNo': partitionNo,
      'batchId': batchId,
      'batchType': batchType.value,
    };
    // Include new fields if present
    if (totalEntries != null) result['totalEntries'] = totalEntries;
    if (totalSizeInBytes != null) result['totalSizeInBytes'] = totalSizeInBytes;
    return result;
  }

  static IndexPartitionFlushedEntry fromJson(Map<String, dynamic> json) {
    // Backward compatibility: support old format with 'partition' and 'meta'
    int partitionNo = 0;

    if (json.containsKey('partitionNo')) {
      // New format
      partitionNo = (json['partitionNo'] as num?)?.toInt() ?? 0;
    }

    // New fields: complete index statistics (preferred for recovery)
    final totalEntries = (json['totalEntries'] as num?)?.toInt();
    final totalSizeInBytes = (json['totalSizeInBytes'] as num?)?.toInt();

    return IndexPartitionFlushedEntry(
      table: (json['table'] as String?) ?? '',
      index: (json['index'] as String?) ?? '',
      partitionNo: partitionNo,
      totalEntries: totalEntries,
      totalSizeInBytes: totalSizeInBytes,
      batchId: (json['batchId'] as String?) ?? '',
      batchType: BatchType.fromStringOrFlush(
          (json['batchType'] as String?) ?? (json['scope'] as String?)),
    );
  }
}

class IndexMetaUpdatedEntry extends ParallelJournalEntry {
  @override
  final String type = 'indexMetaUpdated';
  final String table;
  final String index;
  final String? batchId;
  final BatchType? batchType;
  IndexMetaUpdatedEntry(
      {required this.table, required this.index, this.batchId, this.batchType});
  @override
  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{
      'type': type,
      'table': table,
      'index': index,
    };
    if (batchId != null) result['batchId'] = batchId;
    if (batchType != null) result['batchType'] = batchType!.value;
    return result;
  }

  static IndexMetaUpdatedEntry fromJson(Map<String, dynamic> json) =>
      IndexMetaUpdatedEntry(
        table: (json['table'] as String?) ?? '',
        index: (json['index'] as String?) ?? '',
        batchId: (json['batchId'] as String?),
        batchType: BatchType.fromString(
            (json['batchType'] as String?) ?? (json['scope'] as String?)),
      );
}

class BatchCompletedEntry extends ParallelJournalEntry {
  @override
  final String type = 'batchCompleted';
  final String at;
  final String? batchId;
  final BatchType? batchType;
  BatchCompletedEntry({required this.at, this.batchId, this.batchType});
  @override
  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{
      'type': type,
      'at': at,
    };
    if (batchId != null) result['batchId'] = batchId;
    if (batchType != null) result['batchType'] = batchType!.value;
    return result;
  }

  static BatchCompletedEntry fromJson(Map<String, dynamic> json) =>
      BatchCompletedEntry(
        at: (json['at'] as String?) ?? '',
        batchId: (json['batchId'] as String?),
        batchType: BatchType.fromString(
            (json['batchType'] as String?) ?? (json['scope'] as String?)),
      );
}

/// Type-safe batch type enum for parallel journal entries.
enum BatchType {
  flush,
  maintenance;

  String get value => name;

  static BatchType? fromString(String? value) {
    if (value == null) return null;
    switch (value) {
      case 'flush':
        return BatchType.flush;
      case 'maintenance':
        return BatchType.maintenance;
      default:
        return null;
    }
  }

  static BatchType fromStringOrFlush(String? value) {
    return fromString(value) ?? BatchType.flush;
  }
}

/// Batch context containing batch ID and type for journal operations.
/// This model simplifies method signatures by bundling related batch information.
class BatchContext {
  final String batchId;
  final BatchType batchType;

  const BatchContext({
    required this.batchId,
    required this.batchType,
  });

  /// Create a flush batch context
  factory BatchContext.flush(String batchId) {
    return BatchContext(batchId: batchId, batchType: BatchType.flush);
  }

  /// Create a maintenance batch context
  factory BatchContext.maintenance(String batchId) {
    return BatchContext(batchId: batchId, batchType: BatchType.maintenance);
  }

  /// Convert to legacy string format for backward compatibility
  String get batchTypeString => batchType.value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BatchContext &&
          runtimeType == other.runtimeType &&
          batchId == other.batchId &&
          batchType == other.batchType;

  @override
  int get hashCode => batchId.hashCode ^ batchType.hashCode;

  @override
  String toString() =>
      'BatchContext(batchId: $batchId, batchType: ${batchType.value})';
}
