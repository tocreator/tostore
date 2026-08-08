library;

import 'table_identity.dart';

/// Per-table plan captured at batch start for recovery (base totals + indexes).
class BatchTablePlan {
  final bool willUpdateTableDataMeta;
  final List<IndexUid> indexes;
  final bool willUpdateIndexMeta;
  final int? baseTotalRecordCount;
  final int? baseTotalSizeBytes;
  final Map<IndexUid, int>? baseIndexTotalEntryCount;
  final Map<IndexUid, int>? baseIndexTotalSizeBytes;

  const BatchTablePlan({
    required this.willUpdateTableDataMeta,
    required this.indexes,
    required this.willUpdateIndexMeta,
    this.baseTotalRecordCount,
    this.baseTotalSizeBytes,
    this.baseIndexTotalEntryCount,
    this.baseIndexTotalSizeBytes,
  });

  Map<String, dynamic> toJson() => {
        'willUpdateTableDataMeta': willUpdateTableDataMeta,
        'indexes': indexes.map((e) => e.value).toList(),
        'willUpdateIndexMeta': willUpdateIndexMeta,
        if (baseTotalRecordCount != null)
          'baseTotalRecordCount': baseTotalRecordCount,
        if (baseTotalSizeBytes != null)
          'baseTotalSizeBytes': baseTotalSizeBytes,
        if (baseIndexTotalEntryCount != null)
          'baseIndexTotalEntryCount':
              baseIndexTotalEntryCount!.map((k, v) => MapEntry(k.value, v)),
        if (baseIndexTotalSizeBytes != null)
          'baseIndexTotalSizeBytes':
              baseIndexTotalSizeBytes!.map((k, v) => MapEntry(k.value, v)),
      };

  static BatchTablePlan fromJson(Map<String, dynamic> json) {
    Map<IndexUid, int>? mapIndexTotals(Map? raw) {
      if (raw == null) return null;
      return raw.map(
        (k, v) => MapEntry(IndexUid(k.toString()), (v as num).toInt()),
      );
    }

    return BatchTablePlan(
      willUpdateTableDataMeta: json['willUpdateTableDataMeta'] as bool? ?? true,
      indexes: ((json['indexes'] as List?) ?? const <dynamic>[])
          .map((e) => IndexUid(e.toString()))
          .toList(),
      willUpdateIndexMeta: json['willUpdateIndexMeta'] as bool? ?? false,
      baseTotalRecordCount: (json['baseTotalRecordCount'] as int?) ??
          (json['baseTotalRecords'] as int?),
      baseTotalSizeBytes: (json['baseTotalSizeBytes'] as int?) ??
          (json['baseTotalSizeInBytes'] as int?),
      baseIndexTotalEntryCount: mapIndexTotals(
          (json['baseIndexTotalEntryCount'] ?? json['baseIndexTotalEntries'])
              as Map?),
      baseIndexTotalSizeBytes: mapIndexTotals(
          (json['baseIndexTotalSizeBytes'] ?? json['baseIndexTotalSizeInBytes'])
              as Map?),
    );
  }
}

/// Backward-compatible alias used by older call sites / upgrade parsers.
typedef TablePlan = BatchTablePlan;

/// Type-safe batch type enum for parallel flush / maintenance.
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

/// Batch context containing batch ID and type for journal / redo operations.
class BatchContext {
  final String batchId;
  final BatchType batchType;

  const BatchContext({
    required this.batchId,
    required this.batchType,
  });

  factory BatchContext.flush(String batchId) {
    return BatchContext(batchId: batchId, batchType: BatchType.flush);
  }

  factory BatchContext.maintenance(String batchId) {
    return BatchContext(batchId: batchId, batchType: BatchType.maintenance);
  }

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
