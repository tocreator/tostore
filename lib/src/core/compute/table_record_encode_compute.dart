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
/// Primary key is nullified during encode (stored separately as the B+Tree
/// key) without copying each record map.
Future<TableRecordEncodeResult> encodeTableRecordChunk(
  TableRecordEncodeRequest request,
) async {
  final encoded = <Uint8List>[];
  final yieldController = YieldController('Compute.tableRecord.encode');

  for (final record in request.records) {
    final y1 = yieldController.maybeYield();
    if (y1 != null) await y1;
    encoded.add(BinarySchemaCodec.encodeRecord(
      record,
      request.fieldStructure,
      nullifyField: request.primaryKeyField,
    ));
  }

  return TableRecordEncodeResult(encodedRecords: encoded);
}
