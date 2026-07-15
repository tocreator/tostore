library;

import 'table_identity.dart';

/// Per-table plan captured at batch start for recovery (base totals + indexes).
class BatchTablePlan {
  final bool willUpdateTableDataMeta;
  final List<IndexUid> indexes;
  final bool willUpdateIndexMeta;
  final int? baseTotalRecords;
  final int? baseTotalSizeInBytes;
  final Map<IndexUid, int>? baseIndexTotalEntries;
  final Map<IndexUid, int>? baseIndexTotalSizeInBytes;

  const BatchTablePlan({
    required this.willUpdateTableDataMeta,
    required this.indexes,
    required this.willUpdateIndexMeta,
    this.baseTotalRecords,
    this.baseTotalSizeInBytes,
    this.baseIndexTotalEntries,
    this.baseIndexTotalSizeInBytes,
  });

  Map<String, dynamic> toJson() => {
        'willUpdateTableDataMeta': willUpdateTableDataMeta,
        'indexes': indexes.map((e) => e.value).toList(),
        'willUpdateIndexMeta': willUpdateIndexMeta,
        if (baseTotalRecords != null) 'baseTotalRecords': baseTotalRecords,
        if (baseTotalSizeInBytes != null)
          'baseTotalSizeInBytes': baseTotalSizeInBytes,
        if (baseIndexTotalEntries != null)
          'baseIndexTotalEntries':
              baseIndexTotalEntries!.map((k, v) => MapEntry(k.value, v)),
        if (baseIndexTotalSizeInBytes != null)
          'baseIndexTotalSizeInBytes':
              baseIndexTotalSizeInBytes!.map((k, v) => MapEntry(k.value, v)),
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
      baseTotalRecords: json['baseTotalRecords'] as int?,
      baseTotalSizeInBytes: json['baseTotalSizeInBytes'] as int?,
      baseIndexTotalEntries:
          mapIndexTotals(json['baseIndexTotalEntries'] as Map?),
      baseIndexTotalSizeInBytes:
          mapIndexTotals(json['baseIndexTotalSizeInBytes'] as Map?),
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
