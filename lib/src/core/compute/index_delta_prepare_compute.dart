import 'dart:convert';
import 'dart:typed_data';

import '../../handler/memcomparable.dart';
import '../../model/data_block_entry.dart';
import '../../model/index_entry.dart';
import '../../model/system_table.dart';
import '../../model/table_schema.dart';
import '../yield_controller.dart';

/// Operation kind for batched B+Tree index delta preparation.
enum IndexDeltaOperationKind {
  insert,
  delete,
  update,
}

/// Pure-compute request for preparing index write deltas.
class IndexDeltaPrepareRequest {
  final TableSchema schema;
  final String tableName;
  final String indexName;
  final String primaryKeyField;
  final List<String> fields;
  final bool isUnique;
  final bool isInternalKvExpiryIndex;
  final bool isInternalTtlIndex;
  final String? batchIngestIso;
  final IndexDeltaOperationKind operationKind;
  final List<Map<String, dynamic>> records;
  final List<IndexRecordUpdate> updates;

  IndexDeltaPrepareRequest({
    required this.schema,
    required this.tableName,
    required this.indexName,
    required this.primaryKeyField,
    required this.fields,
    required this.isUnique,
    required this.isInternalKvExpiryIndex,
    required this.isInternalTtlIndex,
    required this.batchIngestIso,
    required this.operationKind,
    required this.records,
    required this.updates,
  });
}

/// Prepared index delta batch result.
class IndexDeltaPrepareResult {
  final List<DataBlockEntry> deltas;

  const IndexDeltaPrepareResult({required this.deltas});
}

/// Prepare a chunk of B+Tree index deltas using only pure computation.
Future<IndexDeltaPrepareResult> prepareIndexDeltaChunk(
  IndexDeltaPrepareRequest request,
) async {
  final deltas = <DataBlockEntry>[];
  final yieldController = YieldController('Compute.indexDelta.prepare');

  switch (request.operationKind) {
    case IndexDeltaOperationKind.insert:
      for (final record in request.records) {
        await yieldController.maybeYield();
        final pk = record[request.primaryKeyField]?.toString();
        if (pk == null || pk.isEmpty) continue;

        final key = _encodeIndexKey(
          request: request,
          record: record,
          pkValue: pk,
          forInsert: true,
        );
        if (key == null || key.isEmpty) continue;

        deltas.add(
          DataBlockEntry(
            key,
            request.isUnique
                ? _encodeUniquePutValue(pk)
                : _encodeNonUniquePutValue(),
          ),
        );
      }
      break;

    case IndexDeltaOperationKind.delete:
      for (final record in request.records) {
        await yieldController.maybeYield();
        final pk = record[request.primaryKeyField]?.toString();
        if (pk == null || pk.isEmpty) continue;

        final key = _encodeIndexKey(
          request: request,
          record: record,
          pkValue: pk,
          forInsert: false,
        );
        if (key == null || key.isEmpty) continue;

        deltas.add(DataBlockEntry(key, _encodeDeleteValue()));
      }
      break;

    case IndexDeltaOperationKind.update:
      final indexedFields = request.fields.toSet();
      for (final update in request.updates) {
        await yieldController.maybeYield();
        final pk = update.primaryKey.toString();
        if (pk.isEmpty) continue;

        final oldValues = update.oldValues;
        if (oldValues == null) {
          throw StateError(
            'Index update requires oldValues for '
            '${request.tableName}.${request.indexName} (pk=$pk)',
          );
        }

        final oldRecord = Map<String, dynamic>.from(update.newValues);
        oldRecord.addAll(oldValues);
        oldRecord[request.primaryKeyField] = pk;

        final newRecord = Map<String, dynamic>.from(update.newValues);
        newRecord[request.primaryKeyField] = pk;

        try {
          if (!update.affectsIndexedFields(indexedFields)) {
            continue;
          }
        } catch (_) {}

        final oldKey = _encodeIndexKey(
          request: request,
          record: oldRecord,
          pkValue: pk,
          forInsert: false,
        );
        final newKey = _encodeIndexKey(
          request: request,
          record: newRecord,
          pkValue: pk,
          forInsert: false,
        );

        if (oldKey != null &&
            newKey != null &&
            MemComparableKey.compare(oldKey, newKey) == 0) {
          continue;
        }

        if (oldKey != null && oldKey.isNotEmpty) {
          deltas.add(DataBlockEntry(oldKey, _encodeDeleteValue()));
        }
        if (newKey != null && newKey.isNotEmpty) {
          deltas.add(
            DataBlockEntry(
              newKey,
              request.isUnique
                  ? _encodeUniquePutValue(pk)
                  : _encodeNonUniquePutValue(),
            ),
          );
        }
      }
      break;
  }

  return IndexDeltaPrepareResult(deltas: deltas);
}

Uint8List _encodeUniquePutValue(String pk) {
  final bytes = utf8.encode(pk);
  final output = Uint8List(1 + bytes.length);
  output[0] = 0;
  output.setRange(1, output.length, bytes);
  return output;
}

Uint8List _encodeNonUniquePutValue() => Uint8List.fromList(const <int>[0]);

Uint8List _encodeDeleteValue() => Uint8List.fromList(const <int>[1]);

Uint8List? _encodeIndexKey({
  required IndexDeltaPrepareRequest request,
  required Map<String, dynamic> record,
  required String pkValue,
  required bool forInsert,
}) {
  if (request.isInternalKvExpiryIndex) {
    return _encodeInternalKvExpiryIndexKey(
      request.schema,
      record[SystemTable.keyValueExpiresAtField],
      pkValue,
    );
  }

  if (request.isInternalTtlIndex) {
    if (!forInsert || request.batchIngestIso == null) {
      return null;
    }

    final ttlComponent = request.schema.encodeFieldComponentToMemComparable(
      TableSchema.internalTtlIngestTsMsField,
      request.batchIngestIso,
      truncateText: false,
    );
    if (ttlComponent == null) return null;

    final components = <Uint8List>[ttlComponent];
    if (!request.isUnique) {
      components.add(request.schema.encodePrimaryKeyComponent(pkValue));
    }
    return MemComparableKey.encodeTuple(components);
  }

  return _encodeStandardIndexKey(
    schema: request.schema,
    fields: request.fields,
    isUnique: request.isUnique,
    record: record,
    pkValue: pkValue,
  );
}

Uint8List? _encodeInternalKvExpiryIndexKey(
  TableSchema schema,
  dynamic expiresAt,
  String pkValue,
) {
  final expiresAtComponent = schema.encodeFieldComponentToMemComparable(
    SystemTable.keyValueExpiresAtField,
    expiresAt,
    truncateText: false,
  );
  if (expiresAtComponent == null) return null;

  return MemComparableKey.encodeTuple(<Uint8List>[
    expiresAtComponent,
    schema.encodePrimaryKeyComponent(pkValue),
  ]);
}

Uint8List? _encodeStandardIndexKey({
  required TableSchema schema,
  required List<String> fields,
  required bool isUnique,
  required Map<String, dynamic> record,
  required String pkValue,
}) {
  final components = <Uint8List>[];
  final truncateText = !isUnique;

  for (final fieldName in fields) {
    final component = schema.encodeFieldComponentToMemComparable(
      fieldName,
      record[fieldName],
      truncateText: truncateText,
    );
    if (component == null) return null;
    components.add(component);
  }

  if (!isUnique) {
    components.add(schema.encodePrimaryKeyComponent(pkValue));
  }
  return MemComparableKey.encodeTuple(components);
}
