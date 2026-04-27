import '../../model/expr.dart';
import '../../model/table_schema.dart';
import '../../handler/logger.dart';
import '../yield_controller.dart';
import 'record_compute.dart';
import 'unique_ref_compute.dart';

/// Pure-compute request for a batchUpdate preparation chunk.
class BatchUpdatePrepareRequest {
  final TableSchema schema;
  final String tableName;
  final List<Map<String, dynamic>> records;
  final List<Map<String, dynamic>?> existingRecords;
  final List<IndexSchema> uniqueIndexes;

  BatchUpdatePrepareRequest({
    required this.schema,
    required this.tableName,
    required this.records,
    required this.existingRecords,
    required this.uniqueIndexes,
  });
}

/// Prepared update record result for batchUpdate.
class BatchUpdatePreparedRecord {
  final bool missingExistingRecord;
  final bool validationFailed;
  final Map<String, dynamic>? updatedRecord;
  final List<String> changedFields;
  final List<PlannedUniqueKeyRef> reservationUniqueRefs;
  final List<PlannedUniqueKeyRef> currentUniqueRefs;
  final List<String> fieldConstraintErrors;

  BatchUpdatePreparedRecord({
    required this.missingExistingRecord,
    required this.validationFailed,
    required this.updatedRecord,
    required this.changedFields,
    required this.reservationUniqueRefs,
    required this.currentUniqueRefs,
    required this.fieldConstraintErrors,
  });
}

/// Result for a batchUpdate preparation chunk.
class BatchUpdatePrepareResult {
  final List<BatchUpdatePreparedRecord> records;

  BatchUpdatePrepareResult({required this.records});
}

/// Pure-compute request for updateInternal-style batch preparation where the
/// same validated update payload is applied to many existing records.
class UniformUpdatePrepareRequest {
  final TableSchema schema;
  final String tableName;
  final Map<String, dynamic> validData;
  final List<Map<String, dynamic>> existingRecords;

  UniformUpdatePrepareRequest({
    required this.schema,
    required this.tableName,
    required this.validData,
    required this.existingRecords,
  });
}

/// Prepared record result for updateInternal-style bulk updates.
class UniformUpdatePreparedRecord {
  final Map<String, dynamic> updatedRecord;

  const UniformUpdatePreparedRecord({required this.updatedRecord});
}

/// Result for updateInternal-style batch preparation.
class UniformUpdatePrepareResult {
  final List<UniformUpdatePreparedRecord> records;

  const UniformUpdatePrepareResult({required this.records});
}

/// Prepare a chunk of batchUpdate records using only pure computation.
Future<BatchUpdatePrepareResult> prepareBatchUpdateChunk(
  BatchUpdatePrepareRequest request,
) async {
  if (request.records.length != request.existingRecords.length) {
    throw ArgumentError(
      'prepareBatchUpdateChunk length mismatch: '
      'records=${request.records.length}, '
      'existingRecords=${request.existingRecords.length}',
    );
  }

  final primaryKey = request.schema.primaryKey;
  final fieldMap = {
    for (final field in request.schema.fields) field.name: field
  };
  final results = <BatchUpdatePreparedRecord>[];
  final yieldController = YieldController('Compute.batchUpdate.prepare');

  for (int i = 0; i < request.records.length; i++) {
    await yieldController.maybeYield();

    final record = request.records[i];
    final existingRecord = request.existingRecords[i];
    if (existingRecord == null) {
      results.add(
        BatchUpdatePreparedRecord(
          missingExistingRecord: true,
          validationFailed: false,
          updatedRecord: null,
          changedFields: const <String>[],
          reservationUniqueRefs: const <PlannedUniqueKeyRef>[],
          currentUniqueRefs: const <PlannedUniqueKeyRef>[],
          fieldConstraintErrors: const <String>[],
        ),
      );
      continue;
    }

    final validData = validateAndProcessUpdateDataPure(
      schema: request.schema,
      data: record,
      tableName: request.tableName,
    );
    if (validData == null || validData.isEmpty) {
      results.add(
        BatchUpdatePreparedRecord(
          missingExistingRecord: false,
          validationFailed: true,
          updatedRecord: null,
          changedFields: const <String>[],
          reservationUniqueRefs: const <PlannedUniqueKeyRef>[],
          currentUniqueRefs: const <PlannedUniqueKeyRef>[],
          fieldConstraintErrors: const <String>[],
        ),
      );
      continue;
    }

    final updatedRecord = <String, dynamic>{...existingRecord};
    final changedFields = <String>[];
    final fieldConstraintErrors = <String>[];

    for (final entry in validData.entries) {
      final fieldName = entry.key;
      final proposed = entry.value;

      if (proposed is ExprNode) {
        try {
          final result = evaluateExpressionForRecord(
            proposed,
            existingRecord,
            request.schema,
            isUpdate: true,
          );
          final field = fieldMap[fieldName];
          if (field == null || field.name == primaryKey) {
            continue;
          }

          final converted = field.convertValue(result);
          if (!field.validateUpdateValue(converted)) {
            fieldConstraintErrors.add(
              'Result of expression for $fieldName exceeds constraints: $converted',
            );
            continue;
          }

          var finalValue = converted;
          if (finalValue is String &&
              field.maxLength != null &&
              finalValue.length > field.maxLength!) {
            finalValue = finalValue.substring(0, field.maxLength!);
          }

          if (updatedRecord[fieldName] != finalValue) {
            updatedRecord[fieldName] = finalValue;
            changedFields.add(fieldName);
          }
        } catch (e) {
          // Preserve mature behavior: expression failures are logged and the
          // current field is skipped without failing the whole record.
          Logger.error(
            'Expression evaluation failed for $fieldName: $e',
            label: 'Compute.batchUpdate.prepare',
          );
        }
      } else {
        if (updatedRecord[fieldName] != proposed) {
          updatedRecord[fieldName] = proposed;
          changedFields.add(fieldName);
        }
      }
    }

    final reservationUniqueRefs = changedFields.isEmpty
        ? const <PlannedUniqueKeyRef>[]
        : planUpdateUniqueRefsPure(
            schema: request.schema,
            uniqueIndexes: request.uniqueIndexes,
            updatedRecord: updatedRecord,
            changedFields: changedFields,
            includePrimaryKey: false,
            changedOnly: true,
          );
    final currentUniqueRefs = changedFields.isEmpty
        ? const <PlannedUniqueKeyRef>[]
        : planUpdateUniqueRefsPure(
            schema: request.schema,
            uniqueIndexes: request.uniqueIndexes,
            updatedRecord: updatedRecord,
            changedFields: const <String>[],
            includePrimaryKey: true,
            changedOnly: false,
          );

    results.add(
      BatchUpdatePreparedRecord(
        missingExistingRecord: false,
        validationFailed: false,
        updatedRecord: updatedRecord,
        changedFields: changedFields,
        reservationUniqueRefs: reservationUniqueRefs,
        currentUniqueRefs: currentUniqueRefs,
        fieldConstraintErrors: fieldConstraintErrors,
      ),
    );
  }

  return BatchUpdatePrepareResult(records: results);
}

/// Prepare a chunk of updateInternal records using only pure computation.
///
/// This intentionally preserves the mature updateInternal semantics:
/// - the validated update payload is shared by all target records
/// - expression evaluation failures keep the original field value
/// - no extra post-expression validation or max-length trimming is added here
Future<UniformUpdatePrepareResult> prepareUniformUpdateChunk(
  UniformUpdatePrepareRequest request,
) async {
  final primaryKey = request.schema.primaryKey;
  final results = <UniformUpdatePreparedRecord>[];
  final yieldController = YieldController('Compute.updateInternal.prepare');

  for (final record in request.existingRecords) {
    await yieldController.maybeYield();

    final updatedRecord = <String, dynamic>{};
    updatedRecord[primaryKey] = record[primaryKey];

    for (final field in request.schema.fields) {
      if (field.name == primaryKey) {
        continue;
      }

      final fieldName = field.name;
      final proposed = request.validData.containsKey(fieldName)
          ? request.validData[fieldName]
          : null;

      if (proposed is ExprNode) {
        try {
          final result = evaluateExpressionForRecord(
            proposed,
            record,
            request.schema,
            isUpdate: true,
          );
          updatedRecord[fieldName] = field.convertValue(result);
        } catch (e) {
          Logger.error(
            'Failed to evaluate expression for field $fieldName: $e',
            label: 'Compute.updateInternal.prepare',
          );
          updatedRecord[fieldName] = record[fieldName];
        }
      } else if (request.validData.containsKey(fieldName)) {
        updatedRecord[fieldName] = proposed;
      } else {
        updatedRecord[fieldName] = record[fieldName];
      }
    }

    results.add(
      UniformUpdatePreparedRecord(updatedRecord: updatedRecord),
    );
  }

  return UniformUpdatePrepareResult(records: results);
}
