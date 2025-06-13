import 'dart:async';

import '../core/b_plus_tree.dart';
import '../model/index_entry.dart';

/// Helper class for organizing parallel write jobs.
class PartitionWriteJob {
  final int partitionIndex;
  final List<IndexBufferEntry> entries;
  String? existingContent; // Loaded before sending to isolate
  Future<IndexProcessingResult>? future;
  IndexProcessingResult? result;

  PartitionWriteJob({required this.partitionIndex, required this.entries});
}

/// Request data for processing an index partition in an isolate.
class IndexProcessingRequest {
  /// A list of entries (insertions) to be processed for this partition.
  final List<IndexBufferEntry> entries;

  /// The string content of an existing partition file. Null for new partitions.
  final String? existingPartitionContent;

  /// The B+ tree order.
  final int bTreeOrder;

  /// Whether the index is unique.
  final bool isUnique;

  IndexProcessingRequest({
    required this.entries,
    this.existingPartitionContent,
    required this.bTreeOrder,
    required this.isUnique,
  });
}

/// Result data from processing an index partition in an isolate.
class IndexProcessingResult {
  /// The serialized B+ tree as a string, ready to be written to a file.
  final String serializedBTree;

  /// The size of the new serialized B+ tree.
  final int newSize;

  /// The total number of entries in the B+ tree after processing.
  final int entryCount;

  IndexProcessingResult({
    required this.serializedBTree,
    required this.newSize,
    required this.entryCount,
  });

  /// A factory for creating a failed result.
  factory IndexProcessingResult.failed() => IndexProcessingResult(
        serializedBTree: '',
        newSize: 0,
        entryCount: 0,
      );

  /// Check if the result indicates a failure.
  bool get isFailed => serializedBTree.isEmpty && newSize == 0;
}

/// A top-level function designed to be run in a separate isolate.
///
/// This function takes an [IndexProcessingRequest], processes the index entries
/// by inserting them into a B+ tree, and returns an [IndexProcessingResult].
Future<IndexProcessingResult> processIndexPartition(
    IndexProcessingRequest request) async {
  // Initialize B+ tree, either from existing content or as a new tree.
  final btree = (request.existingPartitionContent != null &&
          request.existingPartitionContent!.isNotEmpty)
      ? BPlusTree.fromString(
          request.existingPartitionContent!,
          order: request.bTreeOrder,
          isUnique: request.isUnique,
        )
      : BPlusTree(
          order: request.bTreeOrder,
          isUnique: request.isUnique,
        );

  // Insert each entry into the B+ tree.
  // This is the main CPU-intensive part.
  for (final bufferEntry in request.entries) {
    final entry = bufferEntry.indexEntry;
    await btree.insert(entry.indexKey, entry.recordPointer.toString());
  }

  // Serialize the final tree to a string.
  final serialized = btree.toStringHandle();

  // Return the results.
  return IndexProcessingResult(
    serializedBTree: serialized,
    newSize: serialized.length,
    entryCount: btree.count(),
  );
} 
