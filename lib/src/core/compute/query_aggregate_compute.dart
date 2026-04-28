import '../../model/query_aggregation.dart';
import '../yield_controller.dart';

class QueryAggregateChunkRequest {
  final List<Map<String, dynamic>> records;
  final List<QueryAggregation> aggregations;
  final List<String>? groupBy;

  const QueryAggregateChunkRequest({
    required this.records,
    required this.aggregations,
    this.groupBy,
  });
}

Future<QueryAggregationPartial> aggregateQueryChunk(
  QueryAggregateChunkRequest request,
) async {
  final aggregator = QueryAggregator(
    request.aggregations,
    groupBy: request.groupBy,
  );
  final yieldController =
      YieldController('Compute.aggregateQueryChunk', checkInterval: 128);

  for (final record in request.records) {
    await yieldController.maybeYield();
    aggregator.accumulate(record);
  }

  return aggregator.snapshot();
}
