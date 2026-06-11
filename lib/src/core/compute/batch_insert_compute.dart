import '../../model/db_exception.dart';
import '../../model/result_status.dart';
import '../../model/result_type.dart';
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
  final bool ignoreUnknownFields;

  BatchInsertPrepareRequest({
    required this.schema,
    required this.tableName,
    required this.records,
    required this.uniqueIndexes,
    required this.skipPrimaryKeyFormatChecks,
    this.ignoreUnknownFields = true,
  });
}

/// Prepared record result for batchInsert.
class BatchInsertPreparedRecord {
  final Map<String, dynamic>? validData;
  final Object? preparedPrimaryKeyValue;
  final List<PlannedUniqueKeyRef> plannedUniqueRefs;
  final List<String> validationErrors;
  final List<Map<String, dynamic>>? validationStatusesJson;

  BatchInsertPreparedRecord({
    required this.validData,
    required this.preparedPrimaryKeyValue,
    required this.plannedUniqueRefs,
    required this.validationErrors,
    this.validationStatusesJson,
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
    throw DbException([
      GeneralStatus(
        type: ResultType.engError,
        message:
            'prepareBatchInsertChunk length mismatch. Records length (${request.records.length}) does not match check list length (${request.skipPrimaryKeyFormatChecks.length}).',
      )
    ]);
  }

  final fieldMap = {
    for (final field in request.schema.fields) field.name: field
  };
  final results = <BatchInsertPreparedRecord>[];
  final yieldController = YieldController('Compute.batchInsert.prepare');

  for (int i = 0; i < request.records.length; i++) {
    await yieldController.maybeYield();
    final errors = <String>[];
    Map<String, dynamic>? validData;
    List<Map<String, dynamic>>? validationStatusesJson;
    try {
      validData = validateAndProcessRecordPure(
        schema: request.schema,
        data: request.records[i],
        tableName: request.tableName,
        skipPrimaryKeyFormatCheck: request.skipPrimaryKeyFormatChecks[i],
        validationErrors: errors,
        fieldMap: fieldMap,
        ignoreUnknownFields: request.ignoreUnknownFields,
      );
    } on DbException catch (e) {
      errors.addAll(e.statuses.map((s) => s.message));
      validationStatusesJson = e.statuses.map((s) => s.toJson()).toList();
    } catch (e) {
      errors.add(e.toString());
    }
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
        validationStatusesJson: validationStatusesJson,
      ),
    );
  }

  return BatchInsertPrepareResult(records: results);
}
