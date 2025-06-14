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

/// Request data for processing index deletion in an isolate.
class IndexDeleteRequest {
  /// The content of the partition file to process
  final String content;
  
  /// The checksum of the partition file (optional)
  final String? checksum;
  
  /// The B+ tree order
  final int bTreeOrder;
  
  /// Whether the index is unique
  final bool isUnique;
  
  /// The keys to process for deletion
  final List<String> keysToProcess;
  
  /// The entries to delete mapped by key
  final Map<String, IndexBufferEntry> entriesToDelete;
  
  IndexDeleteRequest({
    required this.content,
    this.checksum,
    required this.bTreeOrder,
    required this.isUnique,
    required this.keysToProcess,
    required this.entriesToDelete,
  });
}

/// Result data from processing an index deletion in an isolate.
class IndexDeleteResult {
  /// Whether the B+ tree was modified
  final bool isModified;
  
  /// The new content of the B+ tree
  final String newContent;
  
  /// The number of entries in the B+ tree after processing
  final int entryCount;
  
  /// The keys that were successfully processed
  final List<String> processedKeys;
  
  /// The checksum of the new content
  final String checksum;
  
  IndexDeleteResult({
    required this.isModified,
    required this.newContent,
    required this.entryCount,
    required this.processedKeys,
    required this.checksum,
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

/// Process index deletion in an isolate
///
/// This function takes an [IndexDeleteRequest], processes the deletion of entries
/// from a B+ tree, and returns an [IndexDeleteResult].
Future<IndexDeleteResult> processIndexDelete(IndexDeleteRequest request) async {
  // Verify checksum if provided
  if (request.checksum != null && 
      !_verifyChecksum(request.content, request.checksum!)) {
    // Return empty result if checksum verification fails
    return IndexDeleteResult(
      isModified: false,
      newContent: request.content,
      entryCount: 0,
      processedKeys: [],
      checksum: request.checksum ?? '',
    );
  }
  
  // Initialize B+ tree from content
  final btree = BPlusTree.fromString(
    request.content,
    order: request.bTreeOrder,
    isUnique: request.isUnique,
  );
  
  // Track whether the B+ tree was modified
  bool isModified = false;
  
  // Track which keys were processed
  final processedKeys = <String>[];
  
  // Process each key to delete
  for (final key in request.keysToProcess) {
    final indexEntry = request.entriesToDelete[key];
    if (indexEntry == null) continue;
    
    final existingValues = await btree.search(key);
    if (existingValues.isEmpty) continue;
    
    final recordPointer = indexEntry.indexEntry.recordPointer.toString();
    if (existingValues.contains(recordPointer)) {
      await btree.delete(key, recordPointer);
      isModified = true;
      processedKeys.add(key);
      
      // For unique indexes, we can stop after finding the first match
      if (request.isUnique) break;
    }
  }
  
  // Serialize the B+ tree if modified
  final newContent = isModified ? btree.toStringHandle() : request.content;
  
  // Calculate checksum for the new content
  final checksum = _calculateChecksum(newContent);
  
  // Return the results
  return IndexDeleteResult(
    isModified: isModified,
    newContent: newContent,
    entryCount: btree.count(),
    processedKeys: processedKeys,
    checksum: checksum,
  );
}

/// Verify content checksum
bool _verifyChecksum(String content, String checksum) {
  if (checksum.isEmpty) return true; // Empty checksum is considered valid
  final calculatedChecksum = _calculateChecksum(content);
  return calculatedChecksum == checksum;
}

/// Calculate content checksum
String _calculateChecksum(String content) {
  // Use simple hash value as checksum
  final hash = content.hashCode;
  return hash.toRadixString(16).padLeft(8, '0');
} 
