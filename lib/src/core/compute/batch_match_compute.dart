import '../../handler/value_matcher.dart';
import '../../model/table_schema.dart';
import '../../query/query_condition.dart';
import '../yield_controller.dart';

/// Pure-compute request for matching a condition against a batch of records.
class BatchMatchRequest {
  final TableSchema schema;
  final String tableName;
  final Map<String, dynamic> condition;
  final List<Map<String, dynamic>> records;
  final int? maxMatchCount;

  BatchMatchRequest({
    required this.schema,
    required this.tableName,
    required this.condition,
    required this.records,
    this.maxMatchCount,
  });
}

/// Match result for a batch of records.
class BatchMatchResult {
  final List<int> matchedIndices;
  final int liveRecordCount;
  final bool completedAllRecords;

  const BatchMatchResult({
    required this.matchedIndices,
    required this.liveRecordCount,
    required this.completedAllRecords,
  });
}

/// Match a condition against a chunk using only pure computation.
Future<BatchMatchResult> matchConditionChunk(
  BatchMatchRequest request,
) async {
  final queryCondition = request.condition.isEmpty
      ? QueryCondition()
      : QueryCondition.fromMap(request.condition);
  final matcher = ConditionRecordMatcher.prepare(
    queryCondition,
    {request.tableName: request.schema},
    request.tableName,
  );

  final matchedIndices = <int>[];
  int liveRecordCount = 0;
  bool completedAllRecords = true;
  final yieldController = YieldController(
    'Compute.batchMatch',
  );

  for (int i = 0; i < request.records.length; i++) {
    await yieldController.maybeYield();
    final record = request.records[i];
    if (_isDeletedRecordPure(record)) {
      continue;
    }

    liveRecordCount++;
    if (matcher.matches(record)) {
      matchedIndices.add(i);
      if (request.maxMatchCount != null &&
          matchedIndices.length >= request.maxMatchCount!) {
        if (i + 1 < request.records.length) {
          completedAllRecords = false;
          break;
        }
      }
    }
  }

  return BatchMatchResult(
    matchedIndices: matchedIndices,
    liveRecordCount: liveRecordCount,
    completedAllRecords: completedAllRecords,
  );
}

bool _isDeletedRecordPure(Map<String, dynamic> record) {
  if (record['_deleted_'] == true) {
    return true;
  }
  return record.isEmpty;
}
