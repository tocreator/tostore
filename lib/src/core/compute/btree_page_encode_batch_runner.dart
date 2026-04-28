import 'dart:typed_data';

import '../../model/data_store_config.dart';
import '../../model/encoder_config.dart';
import '../compute_manager.dart';
import '../compute_tasks.dart';
import 'compute_batch_planner.dart';

/// Shared dispatcher for pure B+Tree page encoding work.
///
/// This helper only splits page-encoding compute and merges results.
/// Callers keep redo persistence, file I/O, and orchestration on the main thread.
final class BTreePageEncodeBatchRunner {
  static int _estimateMinUsefulTaskItems(int? encryptionTypeIndex) {
    final encType = encryptionTypeIndex == null
        ? null
        : EncryptionTypeExtension.fromInt(encryptionTypeIndex);
    if (encType == EncryptionType.aes256Gcm ||
        encType == EncryptionType.chacha20Poly1305) {
      return 4;
    }
    if (encType == EncryptionType.xorObfuscation ||
        encType == EncryptionType.none) {
      return 16;
    }
    return 32;
  }

  static Future<BatchBTreePageEncodeResult> encode({
    required bool enableIsolate,
    required int pageSize,
    required int? encryptionTypeIndex,
    required EncoderConfig encoderConfig,
    Uint8List? customKey,
    int? customKeyId,
    required List<BTreePageEncodeItem> pages,
    int? pageRedoTreeKindIndex,
    String? pageRedoTableName,
    String? pageRedoIndexName,
  }) async {
    if (pages.isEmpty) {
      return const BatchBTreePageEncodeResult(<Uint8List>[]);
    }

    final minUsefulTaskItems = _estimateMinUsefulTaskItems(encryptionTypeIndex);
    final useIsolate = enableIsolate && pages.length >= minUsefulTaskItems;
    final dispatchTaskCount = useIsolate
        ? ComputeBatchPlanner.estimateDispatchTaskCount(
            maxSplittableTaskCount:
                ComputeBatchPlanner.estimateMaxSplittableTaskCount(
              itemCount: pages.length,
              minUsefulTaskItems: minUsefulTaskItems,
            ),
          )
        : 1;
    final actualTaskCount = useIsolate ? dispatchTaskCount : 1;

    final tasks = <ComputeTask<BatchBTreePageEncodeRequest,
        BatchBTreePageEncodeResult>>[];
    for (final range
        in ComputeBatchPlanner.splitRange(pages.length, actualTaskCount)) {
      tasks.add(
        ComputeTask(
          function: batchEncodeBTreePages,
          message: BatchBTreePageEncodeRequest(
            pageSize: pageSize,
            encryptionTypeIndex: encryptionTypeIndex,
            encoderConfig: encoderConfig,
            customKey: customKey,
            customKeyId: customKeyId,
            pages: pages.sublist(range.start, range.end),
            pageRedoTreeKindIndex: pageRedoTreeKindIndex,
            pageRedoTableName: pageRedoTableName,
            pageRedoIndexName: pageRedoIndexName,
          ),
        ),
      );
    }

    final results =
        await ComputeManager.computeBatch(tasks, enableIsolate: useIsolate);

    final pageBytes = <Uint8List>[];
    final redoChunks = <Uint8List>[];
    int totalRedoBytes = 0;

    for (final result in results) {
      pageBytes.addAll(result.pageBytes);
      final redoBytes = result.pageRedoBytes;
      if (redoBytes == null || redoBytes.isEmpty) continue;
      redoChunks.add(redoBytes);
      totalRedoBytes += redoBytes.length;
    }

    if (redoChunks.isEmpty) {
      return BatchBTreePageEncodeResult(pageBytes);
    }

    final mergedRedoBytes = Uint8List(totalRedoBytes);
    int offset = 0;
    for (final redoBytes in redoChunks) {
      mergedRedoBytes.setRange(offset, offset + redoBytes.length, redoBytes);
      offset += redoBytes.length;
    }

    return BatchBTreePageEncodeResult(pageBytes, mergedRedoBytes);
  }
}
