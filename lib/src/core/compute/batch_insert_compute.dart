import '../../model/table_schema.dart';
import '../yield_controller.dart';
import 'record_compute.dart';
import 'unique_ref_compute.dart';

/// Pure-compute request for a batchInsert preparation chunk.
class BatchInsertPrepareRequest {
  final TableSchema schema;
  final String tableName;
  final List<Map<String, dynamic>> records;
  final List<IndexSchema> uniqueIndexes;
  final List<bool> skipPrimaryKeyFormatChecks;

  BatchInsertPrepareRequest({
    required this.schema,
    required this.tableName,
    required this.records,
    required this.uniqueIndexes,
    required this.skipPrimaryKeyFormatChecks,
  });
}

/// Prepared record result for batchInsert.
class BatchInsertPreparedRecord {
  final Map<String, dynamic>? validData;
  final Object? preparedPrimaryKeyValue;
  final List<PlannedUniqueKeyRef> plannedUniqueRefs;
  final List<String> validationErrors;

  BatchInsertPreparedRecord({
    required this.validData,
    required this.preparedPrimaryKeyValue,
    required this.plannedUniqueRefs,
    required this.validationErrors,
  });
}

/// Result for a batchInsert preparation chunk.
class BatchInsertPrepareResult {
  final List<BatchInsertPreparedRecord> records;

  BatchInsertPrepareResult({required this.records});
}

/// Prepare a chunk of batchInsert records using only pure computation.
Future<BatchInsertPrepareResult> prepareBatchInsertChunk(
  BatchInsertPrepareRequest request,
) async {
  if (request.records.length != request.skipPrimaryKeyFormatChecks.length) {
    throw ArgumentError(
      'prepareBatchInsertChunk length mismatch: '
      'records=${request.records.length}, '
      'skipPrimaryKeyFormatChecks=${request.skipPrimaryKeyFormatChecks.length}',
    );
  }

  final fieldMap = {
    for (final field in request.schema.fields) field.name: field
  };
  final results = <BatchInsertPreparedRecord>[];
  final yieldController = YieldController('Compute.batchInsert.prepare');

  for (int i = 0; i < request.records.length; i++) {
    await yieldController.maybeYield();
    final errors = <String>[];
    final validData = validateAndProcessRecordPure(
      schema: request.schema,
      data: request.records[i],
      tableName: request.tableName,
      skipPrimaryKeyFormatCheck: request.skipPrimaryKeyFormatChecks[i],
      validationErrors: errors,
      fieldMap: fieldMap,
    );
    final plannedUniqueRefs = validData == null
        ? const <PlannedUniqueKeyRef>[]
        : planInsertUniqueRefsPure(
            schema: request.schema,
            uniqueIndexes: request.uniqueIndexes,
            data: validData,
          );
    results.add(
      BatchInsertPreparedRecord(
        validData: validData,
        preparedPrimaryKeyValue:
            validData == null ? null : validData[request.schema.primaryKey],
        plannedUniqueRefs: plannedUniqueRefs,
        validationErrors: errors,
      ),
    );
  }

  return BatchInsertPrepareResult(records: results);
}
