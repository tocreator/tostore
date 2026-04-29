import 'dart:typed_data';

import '../../handler/binary_schema_codec.dart';
import '../yield_controller.dart';

/// Pure-compute request for encoding table records before B+Tree persistence.
class TableRecordEncodeRequest {
  final String primaryKeyField;
  final List<FieldStructure> fieldStructure;
  final List<Map<String, dynamic>> records;

  const TableRecordEncodeRequest({
    required this.primaryKeyField,
    required this.fieldStructure,
    required this.records,
  });
}

/// Encoded table record payloads, aligned with the input record order.
class TableRecordEncodeResult {
  final List<Uint8List> encodedRecords;

  const TableRecordEncodeResult({required this.encodedRecords});
}

/// Encode a chunk of table records using the mature BinarySchemaCodec path.
///
/// This intentionally preserves the existing write path behavior: the primary
/// key is removed before values-only encoding, and no storage state is touched.
Future<TableRecordEncodeResult> encodeTableRecordChunk(
  TableRecordEncodeRequest request,
) async {
  final encoded = <Uint8List>[];
  final yieldController = YieldController('Compute.tableRecord.encode');

  for (final record in request.records) {
    await yieldController.maybeYield();
    final valuesOnly = Map<String, dynamic>.from(record);
    valuesOnly.remove(request.primaryKeyField);
    encoded.add(BinarySchemaCodec.encodeRecord(
      valuesOnly,
      request.fieldStructure,
    ));
  }

  return TableRecordEncodeResult(encodedRecords: encoded);
}
