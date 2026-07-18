import 'dart:convert';

import '../../model/table_identity.dart';
import '../../model/transaction_models.dart';

/// Legacy NDJSON parsers for pre-binary transaction logs (`tx_*.log`, `status.log`).
///
/// Used only by v3 blocking migration — keep out of hot-path models.
class LegacyTxnJson {
  LegacyTxnJson._();

  /// Parse one NDJSON status/plan line into a structured map.
  ///
  /// Returns null if the line is empty or not valid JSON.
  static Map<String, dynamic>? parseLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return null;
    try {
      final obj = jsonDecode(trimmed);
      if (obj is Map<String, dynamic>) return obj;
      if (obj is Map) return Map<String, dynamic>.from(obj);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Build [TransactionCommitPlan] from a legacy `plan` object.
  static TransactionCommitPlan commitPlanFromJson(Map<String, dynamic> json) {
    return TransactionCommitPlan(
      transactionId: json['transactionId'] as String,
      inserts: _tableRecordsMap(json['inserts']),
      updates: _tableRecordsMap(json['updates']),
      deletes: _tableRecordsMap(json['deletes']),
      heavyDeletes: (json['heavyDeletes'] as List?)
              ?.map((e) =>
                  heavyDeleteFromJson((e as Map).cast<String, dynamic>()))
              .toList() ??
          const <HeavyDeletePlan>[],
      heavyUpdates: (json['heavyUpdates'] as List?)
              ?.map((e) =>
                  heavyUpdateFromJson((e as Map).cast<String, dynamic>()))
              .toList() ??
          const <HeavyUpdatePlan>[],
    );
  }

  static HeavyDeletePlan heavyDeleteFromJson(Map<String, dynamic> json) {
    return HeavyDeletePlan(
      tableUid: TableUid((json['tableUid'] ?? json['tableName']) as String),
      condition: (json['condition'] as Map).cast<String, dynamic>(),
      orderBy: (json['orderBy'] as List?)?.cast<String>(),
      limit: (json['limit'] as num?)?.toInt(),
      offset: (json['offset'] as num?)?.toInt(),
    );
  }

  static HeavyUpdatePlan heavyUpdateFromJson(Map<String, dynamic> json) {
    return HeavyUpdatePlan(
      tableUid: TableUid((json['tableUid'] ?? json['tableName']) as String),
      condition: (json['condition'] as Map).cast<String, dynamic>(),
      updateData: (json['updateData'] as Map).cast<String, dynamic>(),
      orderBy: (json['orderBy'] as List?)?.cast<String>(),
      limit: (json['limit'] as num?)?.toInt(),
      offset: (json['offset'] as num?)?.toInt(),
    );
  }

  static Map<String, List<Map<String, dynamic>>> _tableRecordsMap(dynamic raw) {
    if (raw is! Map) return <String, List<Map<String, dynamic>>>{};
    return raw.map((k, v) => MapEntry(
          k.toString(),
          (v as List).map((e) => (e as Map).cast<String, dynamic>()).toList(),
        ));
  }

  /// Convert a legacy JSON event map into fields needed for binary rewrite.
  static ({
    String transactionId,
    TxnLogEventType event,
    int timestampMs,
    TransactionCommitPlan? plan,
    int? nextPartitionIndex,
    int? continuedTo,
    Map<String, int>? insertsApplied,
    Map<String, int>? updatesApplied,
    Map<String, int>? deletesApplied,
  })? eventFieldsFromJson(Map<String, dynamic> obj) {
    final txId = obj['transactionId'] as String?;
    final event = TxnLogEventType.fromWireName(obj['event'] as String?);
    if (txId == null || event == null) return null;

    int timestampMs = DateTime.now().millisecondsSinceEpoch;
    final ts = obj['timestamp'];
    if (ts is String) {
      try {
        timestampMs = DateTime.parse(ts).millisecondsSinceEpoch;
      } catch (_) {}
    } else if (ts is int) {
      timestampMs = ts;
    }

    TransactionCommitPlan? plan;
    if (event == TxnLogEventType.plan && obj['plan'] is Map) {
      plan = commitPlanFromJson((obj['plan'] as Map).cast<String, dynamic>());
    }

    Map<String, int>? asIntMap(dynamic raw) {
      if (raw is! Map) return null;
      return raw.map((k, v) => MapEntry(k.toString(), (v as num).toInt()));
    }

    return (
      transactionId: txId,
      event: event,
      timestampMs: timestampMs,
      plan: plan,
      nextPartitionIndex: (obj['nextPartitionIndex'] as num?)?.toInt(),
      continuedTo: (obj['continuedTo'] as num?)?.toInt(),
      insertsApplied: asIntMap(obj['insertsApplied']),
      updatesApplied: asIntMap(obj['updatesApplied']),
      deletesApplied: asIntMap(obj['deletesApplied']),
    );
  }
}
