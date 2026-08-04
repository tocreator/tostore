import '../../model/db_exception.dart';
import '../../model/result_status.dart';
import '../../model/result_type.dart';
import '../../model/table_identity.dart';
import '../../model/table_schema.dart';
import '../yield_controller.dart';
import 'record_compute.dart';
import 'unique_ref_compute.dart';

/// Pure-compute request for a batchInsert preparation chunk.
class BatchInsertPrepareRequest {
  final TableSchema schema;

  /// Display name only — avoids shipping the full [TableContext] across isolates.
  final TableName tableName;
  final List<Map<String, dynamic>> records;
  final List<IndexSchema> uniqueIndexes;
  final List<bool> skipPrimaryKeyFormatChecks;
  final bool ignoreUnknownFields;

  /// Shared wall-clock for currentTimestamp defaults across this chunk.
  final DateTime? batchTimestamp;

  BatchInsertPrepareRequest({
    required this.schema,
    required this.tableName,
    required this.records,
    required this.uniqueIndexes,
    required this.skipPrimaryKeyFormatChecks,
    this.ignoreUnknownFields = true,
    this.batchTimestamp,
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
  // Hoist constraint-schema scan once per chunk (not per record).
  var needsConstraintPass = false;
  for (final field in request.schema.fields) {
    if (field.maxLength != null ||
        field.minLength != null ||
        field.minValue != null ||
        field.maxValue != null) {
      needsConstraintPass = true;
      break;
    }
  }
  final results = <BatchInsertPreparedRecord>[];
  final yieldController = YieldController('Compute.batchInsert.prepare');
  // One clock reading for the whole chunk — defaults stay consistent and cheap.
  final batchTs = request.batchTimestamp ?? DateTime.now();

  for (int i = 0; i < request.records.length; i++) {
    final y = yieldController.maybeYieldSync();
    if (y != null) await y;
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
        batchTimestamp: batchTs,
        schemaNeedsConstraintPass: needsConstraintPass,
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
