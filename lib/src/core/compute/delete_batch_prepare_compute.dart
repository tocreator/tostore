import '../../handler/logger.dart';
import '../yield_controller.dart';

/// Pure-compute request for trimming delete-buffer records.
class DeleteBatchPrepareRequest {
  final String tableName;
  final String primaryKeyField;
  final List<String> requiredFields;
  final List<Map<String, dynamic>> records;

  DeleteBatchPrepareRequest({
    required this.tableName,
    required this.primaryKeyField,
    required this.requiredFields,
    required this.records,
  });
}

/// Prepared delete-buffer chunk output.
class DeleteBatchPrepareResult {
  final List<Map<String, dynamic>> trimmedRecords;

  const DeleteBatchPrepareResult({
    required this.trimmedRecords,
  });
}

/// Trim a chunk of records down to the fields needed for delete buffering.
Future<DeleteBatchPrepareResult> prepareDeleteBatchChunk(
  DeleteBatchPrepareRequest request,
) async {
  final trimmedRecords = <Map<String, dynamic>>[];
  final yieldController = YieldController(
    'Compute.delete.prepare',
  );

  for (final record in request.records) {
    await yieldController.maybeYield();
    final recordId = record[request.primaryKeyField]?.toString();
    if (recordId == null) {
      Logger.warn(
        'Record in table ${request.tableName} does not have a primary key value, skipping',
        label: 'TableDataManager.addToDeleteBuffer',
      );
      continue;
    }

    final trimmed = <String, dynamic>{};
    for (final fieldName in request.requiredFields) {
      if (record.containsKey(fieldName)) {
        trimmed[fieldName] = record[fieldName];
      }
    }
    trimmedRecords.add(trimmed);
  }

  return DeleteBatchPrepareResult(trimmedRecords: trimmedRecords);
}
