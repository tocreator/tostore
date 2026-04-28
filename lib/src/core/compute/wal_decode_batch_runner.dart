import 'dart:math';
import 'dart:typed_data';

import '../../handler/encoder.dart';
import '../../handler/platform_handler.dart';
import '../../handler/wal_encoder.dart';
import '../../model/encoder_config.dart';
import '../compute_manager.dart';
import 'compute_batch_planner.dart';

final class WalDecodeChunkRange {
  final int startOffset;
  final int endOffset;
  final int recordCount;

  const WalDecodeChunkRange({
    required this.startOffset,
    required this.endOffset,
    required this.recordCount,
  });

  int get byteLength => endOffset - startOffset;
}

final class WalDecodeFilePlan {
  final int recordCount;
  final int averageRecordBytes;
  final int validEndOffset;
  final bool useIsolate;
  final int dispatchTaskCount;
  final List<WalDecodeChunkRange> ranges;

  const WalDecodeFilePlan({
    required this.recordCount,
    required this.averageRecordBytes,
    required this.validEndOffset,
    required this.useIsolate,
    required this.dispatchTaskCount,
    required this.ranges,
  });
}

final class WalDecodeChunkRequest {
  final Uint8List chunkBytes;
  final int partitionIndex;
  final EncoderConfig encoderConfig;

  const WalDecodeChunkRequest({
    required this.chunkBytes,
    required this.partitionIndex,
    required this.encoderConfig,
  });
}

Future<List<Map<String, dynamic>>> decodeWalChunk(
  WalDecodeChunkRequest request,
) async {
  EncoderHandler.setEncodingState(request.encoderConfig);
  return WalEncoder.decodeFile(request.chunkBytes, request.partitionIndex);
}

/// Shared dispatcher for large WAL file decoding.
///
/// Only length-prefix scanning and record decode are handled here.
/// File I/O and recovery orchestration stay on the caller side.
final class WalDecodeBatchRunner {
  static const int _maxRecordSize = 10 * 1024 * 1024;

  static WalDecodeFilePlan planFile({
    required Uint8List fileBytes,
    int minUsefulTaskItems = ComputeBatchPlanner.minUsefulTaskItems,
  }) {
    final scanResult = _scanFile(fileBytes);
    if (scanResult.recordCount <= 0) {
      return const WalDecodeFilePlan(
        recordCount: 0,
        averageRecordBytes: 0,
        validEndOffset: 0,
        useIsolate: false,
        dispatchTaskCount: 1,
        ranges: <WalDecodeChunkRange>[],
      );
    }

    final useIsolate = ComputeBatchPlanner.shouldUseIsolate(
      itemCount: scanResult.recordCount,
      averageItemBytes: scanResult.averageRecordBytes,
      minUsefulTaskItems: minUsefulTaskItems,
    );
    final dispatchTaskCount = useIsolate
        ? ComputeBatchPlanner.estimateDispatchTaskCount(
            maxSplittableTaskCount:
                ComputeBatchPlanner.estimateMaxSplittableTaskCount(
              itemCount: scanResult.recordCount,
              minUsefulTaskItems: minUsefulTaskItems,
            ),
          )
        : 1;

    return WalDecodeFilePlan(
      recordCount: scanResult.recordCount,
      averageRecordBytes: scanResult.averageRecordBytes,
      validEndOffset: scanResult.validEndOffset,
      useIsolate: useIsolate,
      dispatchTaskCount: dispatchTaskCount,
      ranges: _buildRanges(
        scanResult: scanResult,
        dispatchTaskCount: dispatchTaskCount,
      ),
    );
  }

  static Future<List<Map<String, dynamic>>> decodeFile({
    required Uint8List fileBytes,
    required int partitionIndex,
    required EncoderConfig encoderConfig,
    int minUsefulTaskItems = ComputeBatchPlanner.minUsefulTaskItems,
  }) async {
    final plan = planFile(
      fileBytes: fileBytes,
      minUsefulTaskItems: minUsefulTaskItems,
    );
    if (plan.recordCount <= 0 || plan.ranges.isEmpty) {
      return const <Map<String, dynamic>>[];
    }

    final tasks =
        <ComputeTask<WalDecodeChunkRequest, List<Map<String, dynamic>>>>[];
    for (final range in plan.ranges) {
      tasks.add(
        ComputeTask(
          function: decodeWalChunk,
          message: WalDecodeChunkRequest(
            chunkBytes: Uint8List.sublistView(
              fileBytes,
              range.startOffset,
              range.endOffset,
            ),
            partitionIndex: partitionIndex,
            encoderConfig: encoderConfig,
          ),
        ),
      );
    }

    final results = await ComputeManager.computeBatch(
      tasks,
      enableIsolate: plan.useIsolate,
    );

    final entries = <Map<String, dynamic>>[];
    for (final batch in results) {
      entries.addAll(batch);
    }
    return entries;
  }

  static _WalDecodeScanResult _scanFile(Uint8List fileBytes) {
    final maxBoundaryTaskCount = max(1, PlatformHandler.recommendedConcurrency);
    final boundarySnapshotsByTaskCount = <int, List<_WalChunkBoundarySnapshot>>{
      for (int taskCount = 2; taskCount <= maxBoundaryTaskCount; taskCount++)
        taskCount: <_WalChunkBoundarySnapshot>[],
    };
    final nextBoundaryIndexByTaskCount = List<int>.filled(
      maxBoundaryTaskCount + 1,
      1,
      growable: false,
    );

    int offset = 0;
    int recordCount = 0;
    int validBytes = 0;

    while (offset < fileBytes.length) {
      if (offset + 4 > fileBytes.length) break;

      final recordLength = ByteData.sublistView(
        fileBytes,
        offset,
        offset + 4,
      ).getUint32(0, Endian.little);
      offset += 4;

      if (recordLength == 0 ||
          recordLength > _maxRecordSize ||
          offset + recordLength > fileBytes.length) {
        break;
      }

      offset += recordLength;
      validBytes = offset;
      recordCount++;

      if (maxBoundaryTaskCount <= 1) {
        continue;
      }

      for (int taskCount = 2; taskCount <= maxBoundaryTaskCount; taskCount++) {
        var boundaryIndex = nextBoundaryIndexByTaskCount[taskCount];
        if (boundaryIndex >= taskCount) continue;

        while (boundaryIndex < taskCount &&
            validBytes >=
                ((fileBytes.length * boundaryIndex) / taskCount).ceil()) {
          boundarySnapshotsByTaskCount[taskCount]!.add(
            _WalChunkBoundarySnapshot(
              endOffset: validBytes,
              cumulativeRecordCount: recordCount,
            ),
          );
          boundaryIndex++;
        }
        nextBoundaryIndexByTaskCount[taskCount] = boundaryIndex;
      }
    }

    return _WalDecodeScanResult(
      recordCount: recordCount,
      averageRecordBytes:
          recordCount <= 0 ? 0 : max(1, (validBytes / recordCount).ceil()),
      validEndOffset: validBytes,
      boundarySnapshotsByTaskCount: boundarySnapshotsByTaskCount,
    );
  }

  static List<WalDecodeChunkRange> _buildRanges({
    required _WalDecodeScanResult scanResult,
    required int dispatchTaskCount,
  }) {
    if (scanResult.recordCount <= 0) return const <WalDecodeChunkRange>[];

    final safeTaskCount =
        max(1, min(dispatchTaskCount, scanResult.recordCount));
    if (safeTaskCount == 1) {
      return <WalDecodeChunkRange>[
        WalDecodeChunkRange(
          startOffset: 0,
          endOffset: scanResult.validEndOffset,
          recordCount: scanResult.recordCount,
        ),
      ];
    }

    final snapshots = scanResult.boundarySnapshotsByTaskCount[safeTaskCount] ??
        const <_WalChunkBoundarySnapshot>[];
    final ranges = <WalDecodeChunkRange>[];
    int startOffset = 0;
    int previousRecordCount = 0;

    for (final snapshot in snapshots) {
      final chunkRecordCount =
          snapshot.cumulativeRecordCount - previousRecordCount;
      if (snapshot.endOffset <= startOffset || chunkRecordCount <= 0) {
        continue;
      }
      ranges.add(
        WalDecodeChunkRange(
          startOffset: startOffset,
          endOffset: snapshot.endOffset,
          recordCount: chunkRecordCount,
        ),
      );
      startOffset = snapshot.endOffset;
      previousRecordCount = snapshot.cumulativeRecordCount;
    }

    final remainingRecordCount = scanResult.recordCount - previousRecordCount;
    if (scanResult.validEndOffset > startOffset && remainingRecordCount > 0) {
      ranges.add(
        WalDecodeChunkRange(
          startOffset: startOffset,
          endOffset: scanResult.validEndOffset,
          recordCount: remainingRecordCount,
        ),
      );
    }

    return ranges;
  }
}

final class _WalChunkBoundarySnapshot {
  final int endOffset;
  final int cumulativeRecordCount;

  const _WalChunkBoundarySnapshot({
    required this.endOffset,
    required this.cumulativeRecordCount,
  });
}

final class _WalDecodeScanResult {
  final int recordCount;
  final int averageRecordBytes;
  final int validEndOffset;
  final Map<int, List<_WalChunkBoundarySnapshot>> boundarySnapshotsByTaskCount;

  const _WalDecodeScanResult({
    required this.recordCount,
    required this.averageRecordBytes,
    required this.validEndOffset,
    required this.boundarySnapshotsByTaskCount,
  });
}
