import 'dart:math';

import '../../model/table_schema.dart';
import '../compute_manager.dart';
import '../yield_controller.dart';
import 'batch_match_compute.dart';
import 'compute_batch_planner.dart';

/// Shared batch matcher orchestrator that keeps pure matching work generic and reusable.
class ConditionBatchMatcher {
  static Future<BatchMatchResult> matchRecordIndices({
    required TableSchema schema,
    required String tableName,
    required Map<String, dynamic> condition,
    required List<Map<String, dynamic>> records,
    required int Function(Map<String, dynamic> record) estimateRecordBytes,
    int? maxMatchCount,
  }) async {
    if (records.isEmpty) {
      return const BatchMatchResult(
        matchedIndices: <int>[],
        liveRecordCount: 0,
        completedAllRecords: true,
      );
    }
    if (maxMatchCount != null && maxMatchCount <= 0) {
      return const BatchMatchResult(
        matchedIndices: <int>[],
        liveRecordCount: 0,
        completedAllRecords: false,
      );
    }

    final dispatchPlan = ComputeBatchPlanner.planTaskExecution(
      itemCount: records.length,
      estimateAverageItemBytes: () =>
          ComputeBatchPlanner.estimateAverageItemBytes(
        records,
        estimateRecordBytes,
      ),
    );
    final useIsolate = dispatchPlan.useIsolate;
    final workerTaskCount = dispatchPlan.actualTaskCount;

    if (maxMatchCount == null) {
      final ranges =
          ComputeBatchPlanner.splitRange(records.length, workerTaskCount);
      final results = await ComputeManager.computeBatch(
        _buildTasks(
          schema: schema,
          tableName: tableName,
          condition: condition,
          records: records,
          ranges: ranges,
        ),
        enableIsolate: useIsolate,
      );
      return _mergeResults(ranges, results);
    }

    final splitTaskCount = useIsolate
        ? max(
            workerTaskCount,
            ComputeBatchPlanner.estimateMaxSplittableTaskCount(
              itemCount: records.length,
            ),
          )
        : 1;
    final ranges =
        ComputeBatchPlanner.splitRange(records.length, splitTaskCount);
    final mergeYieldController =
        YieldController('ConditionBatchMatcher.matchRecordIndices');
    final matchedIndices = <int>[];
    int liveRecordCount = 0;
    bool completedAllRecords = true;

    for (int waveStart = 0;
        waveStart < ranges.length && matchedIndices.length < maxMatchCount;
        waveStart += workerTaskCount) {
      final waveEnd = min(waveStart + workerTaskCount, ranges.length);
      final waveRanges = ranges.sublist(waveStart, waveEnd);
      final bool isSingleRangeWave = waveRanges.length == 1;
      final int remainingMatchCount = maxMatchCount - matchedIndices.length;
      final results = await ComputeManager.computeBatch(
        _buildTasks(
          schema: schema,
          tableName: tableName,
          condition: condition,
          records: records,
          ranges: waveRanges,
          maxMatchCount: isSingleRangeWave ? remainingMatchCount : null,
        ),
        enableIsolate: useIsolate,
      );

      for (final result in results) {
        liveRecordCount += result.liveRecordCount;
        if (!result.completedAllRecords) {
          completedAllRecords = false;
        }
      }

      for (int i = 0;
          i < results.length && matchedIndices.length < maxMatchCount;
          i++) {
        final result = results[i];
        final range = waveRanges[i];
        final matchCountToTake = min(result.matchedIndices.length,
            maxMatchCount - matchedIndices.length);
        for (int j = 0; j < matchCountToTake; j++) {
          await mergeYieldController.maybeYield();
          matchedIndices.add(range.start + result.matchedIndices[j]);
        }
      }

      if (waveEnd < ranges.length && matchedIndices.length >= maxMatchCount) {
        completedAllRecords = false;
      }
    }

    return BatchMatchResult(
      matchedIndices: matchedIndices,
      liveRecordCount: liveRecordCount,
      completedAllRecords: completedAllRecords,
    );
  }

  static List<ComputeTask<BatchMatchRequest, BatchMatchResult>> _buildTasks({
    required TableSchema schema,
    required String tableName,
    required Map<String, dynamic> condition,
    required List<Map<String, dynamic>> records,
    required List<ComputeTaskRange> ranges,
    int? maxMatchCount,
  }) {
    final tasks = <ComputeTask<BatchMatchRequest, BatchMatchResult>>[];
    for (final range in ranges) {
      tasks.add(
        ComputeTask(
          function: matchConditionChunk,
          message: BatchMatchRequest(
            schema: schema,
            tableName: tableName,
            condition: condition,
            records: records.sublist(range.start, range.end),
            maxMatchCount: maxMatchCount,
          ),
        ),
      );
    }
    return tasks;
  }

  static Future<BatchMatchResult> _mergeResults(
    List<ComputeTaskRange> ranges,
    List<BatchMatchResult> results,
  ) async {
    final mergeYieldController =
        YieldController('ConditionBatchMatcher.matchRecordIndices');
    final matchedIndices = <int>[];
    int liveRecordCount = 0;
    bool completedAllRecords = true;
    for (int i = 0; i < results.length; i++) {
      final result = results[i];
      final range = ranges[i];
      liveRecordCount += result.liveRecordCount;
      if (!result.completedAllRecords) {
        completedAllRecords = false;
      }
      for (final matchedIndex in result.matchedIndices) {
        await mergeYieldController.maybeYield();
        matchedIndices.add(range.start + matchedIndex);
      }
    }

    return BatchMatchResult(
      matchedIndices: matchedIndices,
      liveRecordCount: liveRecordCount,
      completedAllRecords: completedAllRecords,
    );
  }
}
