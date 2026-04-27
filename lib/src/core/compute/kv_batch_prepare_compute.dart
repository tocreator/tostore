import 'dart:convert';

import '../yield_controller.dart';

/// Sendable item payload for bulk key-value preparation.
class KeyValueBatchItem {
  final String key;
  final dynamic value;

  const KeyValueBatchItem({
    required this.key,
    required this.value,
  });
}

/// Pure-compute request for building key-value records in bulk.
class KeyValueBatchPrepareRequest {
  final List<KeyValueBatchItem> items;
  final String keyField;
  final String valueField;
  final String updatedAtField;
  final String expiresAtField;
  final String nowIso;
  final String? expiresAtIso;

  KeyValueBatchPrepareRequest({
    required this.items,
    required this.keyField,
    required this.valueField,
    required this.updatedAtField,
    required this.expiresAtField,
    required this.nowIso,
    required this.expiresAtIso,
  });
}

/// Result for a key-value batch preparation chunk.
class KeyValueBatchPrepareResult {
  final List<Map<String, dynamic>> records;

  const KeyValueBatchPrepareResult({required this.records});
}

/// Build a chunk of KV upsert records using only pure computation.
Future<KeyValueBatchPrepareResult> prepareKeyValueBatchChunk(
  KeyValueBatchPrepareRequest request,
) async {
  final records = <Map<String, dynamic>>[];
  final yieldController = YieldController('Compute.kv.prepare');

  for (final item in request.items) {
    await yieldController.maybeYield();
    records.add({
      request.keyField: item.key,
      request.valueField: jsonEncode(item.value),
      request.updatedAtField: request.nowIso,
      request.expiresAtField: request.expiresAtIso,
    });
  }

  return KeyValueBatchPrepareResult(records: records);
}
