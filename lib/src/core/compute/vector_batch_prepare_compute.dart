import 'dart:math';
import 'dart:typed_data';

import '../../model/table_schema.dart';
import '../yield_controller.dart';

/// Pure-compute request for preparing a vector batch chunk.
class VectorBatchPrepareRequest {
  final List<Map<String, dynamic>> records;
  final String fieldName;
  final String? primaryKeyField;
  final int dimensions;

  VectorBatchPrepareRequest({
    required this.records,
    required this.fieldName,
    required this.primaryKeyField,
    required this.dimensions,
  });
}

/// Prepared vector chunk output.
class VectorBatchPrepareResult {
  final List<Float32List> vectors;
  final List<String> primaryKeys;

  const VectorBatchPrepareResult({
    required this.vectors,
    required this.primaryKeys,
  });
}

/// Extract vectors and optional primary keys for a record chunk.
Future<VectorBatchPrepareResult> prepareVectorBatchChunk(
  VectorBatchPrepareRequest request,
) async {
  final vectors = <Float32List>[];
  final primaryKeys = <String>[];
  final yieldController = YieldController(
    'Compute.vector.prepare',
  );

  for (final record in request.records) {
    await yieldController.maybeYield();

    final values = _extractVectorValues(record[request.fieldName]);
    if (values == null) continue;

    String? primaryKey;
    if (request.primaryKeyField != null) {
      primaryKey = record[request.primaryKeyField!]?.toString();
      if (primaryKey == null || primaryKey.isEmpty) {
        continue;
      }
    }

    vectors.add(_toFloat32(values, request.dimensions));
    if (primaryKey != null) {
      primaryKeys.add(primaryKey);
    }
  }

  return VectorBatchPrepareResult(
    vectors: vectors,
    primaryKeys: primaryKeys,
  );
}

List<double>? _extractVectorValues(dynamic value) {
  if (value == null) return null;
  if (value is VectorData) return value.values;
  if (value is List<double>) return value;
  if (value is List<num>) {
    return value.map((v) => v.toDouble()).toList(growable: false);
  }
  return null;
}

Float32List _toFloat32(List<double> values, int dimensions) {
  final output = Float32List(dimensions);
  final copyLength = min(values.length, dimensions);
  for (int i = 0; i < copyLength; i++) {
    output[i] = values[i];
  }
  return output;
}
