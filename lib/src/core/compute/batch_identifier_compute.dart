import '../../model/table_schema.dart';
import '../yield_controller.dart';
import 'record_compute.dart';

/// Pure-compute request for validating record identifiers in bulk.
class BatchIdentifierValidationRequest {
  final TableSchema schema;
  final List<Map<String, dynamic>> records;
  final List<IndexSchema> uniqueIndexes;
  final bool checkRequiredFields;

  BatchIdentifierValidationRequest({
    required this.schema,
    required this.records,
    required this.uniqueIndexes,
    required this.checkRequiredFields,
  });
}

/// Per-record identifier validation result.
class IdentifierValidationRecordResult {
  final String? error;

  const IdentifierValidationRecordResult({required this.error});
}

/// Result for a bulk identifier validation chunk.
class BatchIdentifierValidationResult {
  final List<IdentifierValidationRecordResult> records;

  const BatchIdentifierValidationResult({required this.records});
}

/// Validate a chunk of records for pk/unique identifier completeness.
Future<BatchIdentifierValidationResult> validateIdentifierChunk(
  BatchIdentifierValidationRequest request,
) async {
  final results = <IdentifierValidationRecordResult>[];
  final yieldController = YieldController(
    'Compute.identifier.validate',
  );

  for (final record in request.records) {
    await yieldController.maybeYield();
    results.add(
      IdentifierValidationRecordResult(
        error: validateRecordIdentifierPure(
          schema: request.schema,
          data: record,
          uniqueIndexes: request.uniqueIndexes,
          checkRequiredFields: request.checkRequiredFields,
        ),
      ),
    );
  }

  return BatchIdentifierValidationResult(records: results);
}
