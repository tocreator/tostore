import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../core/b_plus_tree.dart';
import '../model/index_entry.dart';
import '../model/file_info.dart';
import '../handler/encoder.dart';
import '../handler/value_comparator.dart';
import '../handler/logger.dart';


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
  try {
    // Initialize B+ tree, either from existing content or as a new tree.
    BPlusTree btree;
    try {
      if (request.existingPartitionContent != null &&
          request.existingPartitionContent!.isNotEmpty) {
        btree = BPlusTree.fromString(
          request.existingPartitionContent!,
          order: request.bTreeOrder,
          isUnique: request.isUnique,
        );
      } else {
        btree = BPlusTree(
          order: request.bTreeOrder,
          isUnique: request.isUnique,
        );
      }
    } catch (treeInitError) {
      Logger.error(
        'Failed to initialize B+ tree: $treeInitError', 
        label: 'processIndexPartition'
      );
      return IndexProcessingResult.failed();
    }

    // Insert each entry into the B+ tree.
    // This is the main CPU-intensive part.
    int failedCount = 0;
    for (final bufferEntry in request.entries) {
      try {
        final entry = bufferEntry.indexEntry;
        await btree.insert(entry.indexKey, entry.recordPointer.toString());
      } catch (insertError) {
        failedCount++;
        Logger.warn(
          'Failed to insert entry: $insertError', 
          label: 'processIndexPartition'
        );
        // Continue with next entry
        continue;
      }
    }
    
    if (failedCount > 0) {
      Logger.warn(
        'Failed to insert $failedCount entries out of ${request.entries.length}', 
        label: 'processIndexPartition'
      );
    }

    // Serialize the final tree to a string.
    String serialized;
    try {
      serialized = btree.toStringHandle();
    } catch (serializeError) {
      Logger.error(
        'Failed to serialize B+ tree: $serializeError', 
        label: 'processIndexPartition'
      );
      return IndexProcessingResult.failed();
    }

    // Return the results.
    return IndexProcessingResult(
      serializedBTree: serialized,
      newSize: serialized.length,
      entryCount: btree.count(),
    );
  } catch (e) {
    Logger.error(
      'Failed to process index partition: $e', 
      label: 'processIndexPartition'
    );
    return IndexProcessingResult.failed();
  }
} 

/// Process index deletion in an isolate
///
/// This function takes an [IndexDeleteRequest], processes the deletion of entries
/// from a B+ tree, and returns an [IndexDeleteResult].
Future<IndexDeleteResult> processIndexDelete(IndexDeleteRequest request) async {
  try {
    // Verify checksum if provided
    if (request.checksum != null && 
        !_verifyChecksum(request.content, request.checksum!)) {
      Logger.warn(
        'Checksum verification failed for index delete operation', 
        label: 'processIndexDelete'
      );
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
    BPlusTree btree;
    try {
      btree = BPlusTree.fromString(
        request.content,
        order: request.bTreeOrder,
        isUnique: request.isUnique,
      );
    } catch (treeError) {
      Logger.error('Failed to initialize B+ tree: $treeError', label: 'processIndexDelete');
      // Return unmodified content as fallback
      return IndexDeleteResult(
        isModified: false,
        newContent: request.content,
        entryCount: 0,
        processedKeys: [],
        checksum: request.checksum ?? _calculateChecksum(request.content),
      );
    }
    
    // Track whether the B+ tree was modified
    bool isModified = false;
    
    // Track which keys were processed
    final processedKeys = <String>[];
    
    // Process each key to delete
    for (final key in request.keysToProcess) {
      try {
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
      } catch (keyError) {
        Logger.warn(
          'Failed to process delete for key $key: $keyError', 
          label: 'processIndexDelete'
        );
        // Continue with next key
        continue;
      }
    }
    
    String newContent;
    try {
      // Serialize the B+ tree if modified
      newContent = isModified ? btree.toStringHandle() : request.content;
    } catch (serializeError) {
      Logger.error(
        'Failed to serialize B+ tree: $serializeError', 
        label: 'processIndexDelete'
      );
      // Use original content as fallback
      newContent = request.content;
      isModified = false;
    }
    
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
  } catch (e) {
    Logger.error('Failed to process index delete operation: $e', label: 'processIndexDelete');
    // Return unmodified content as fallback
    return IndexDeleteResult(
      isModified: false,
      newContent: request.content,
      entryCount: 0,
      processedKeys: [],
      checksum: request.checksum ?? _calculateChecksum(request.content),
    );
  }
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

/// Request data for decoding partition data in an isolate.
class DecodePartitionRequest {
  /// The bytes to decode
  final Uint8List bytes;
  
  /// Optional custom encryption key
  final List<int>? encryptionKey;
  
  /// Optional encryption key ID
  final int? encryptionKeyId;
  
  DecodePartitionRequest({
    required this.bytes,
    this.encryptionKey,
    this.encryptionKeyId,
  });
}

/// Request data for encoding partition data in an isolate.
class EncodePartitionRequest {
  /// The records to encode
  final List<Map<String, dynamic>> records;
  
  /// The partition index
  final int partitionIndex;
  
  /// The primary key field name
  final String primaryKey;
  
  /// Optional minimum primary key value
  final dynamic minPk;
  
  /// Optional maximum primary key value
  final dynamic maxPk;
  
  /// The partition path
  final String partitionPath;
  
  /// The parent path
  final String parentPath;
  
  /// The timestamps
  final Timestamps timestamps;
  
  /// Optional custom encryption key
  final List<int>? encryptionKey;
  
  /// Optional encryption key ID
  final int? encryptionKeyId;
  
  EncodePartitionRequest({
    required this.records,
    required this.partitionIndex,
    required this.primaryKey,
    this.minPk,
    this.maxPk,
    required this.partitionPath,
    required this.parentPath,
    required this.timestamps,
    this.encryptionKey,
    this.encryptionKeyId,
  });
}

/// Result data from encoding partition data in an isolate.
class EncodedPartitionResult {
  /// The encoded data
  final Uint8List encodedData;
  
  /// The updated partition meta
  final PartitionMeta partitionMeta;
  
  /// The number of non-empty records
  final int nonEmptyRecordCount;
  
  EncodedPartitionResult({
    required this.encodedData,
    required this.partitionMeta,
    required this.nonEmptyRecordCount,
  });
}

/// Request data for analyzing partition key range in an isolate.
class PartitionRangeAnalysisRequest {
  /// The records to analyze
  final List<Map<String, dynamic>> records;
  
  /// The primary key field name
  final String primaryKey;
  
  /// The partition index (optional)
  final int partitionIndex;
  
  /// The existing partitions (optional)
  final List<PartitionMeta>? existingPartitions;
  
  PartitionRangeAnalysisRequest({
    required this.records,
    required this.primaryKey,
    this.partitionIndex = 0,
    this.existingPartitions,
  });
}

/// Result data from analyzing partition key range in an isolate.
class PartitionRangeAnalysisResult {
  /// The minimum primary key value
  final dynamic minPk;
  
  /// The maximum primary key value
  final dynamic maxPk;
  
  /// The total number of records
  final int recordCount;
  
  /// Whether the partition order is maintained
  final bool isOrdered;
  
  PartitionRangeAnalysisResult({
    this.minPk,
    this.maxPk,
    required this.recordCount,
    this.isOrdered = true,
  });
}

/// A top-level function designed to be run in a separate isolate.
///
/// This function takes a [DecodePartitionRequest], decodes the partition data,
/// and returns a list of records.
Future<List<Map<String, dynamic>>> decodePartitionData(
  DecodePartitionRequest request) async {
  try {
    // decode data
    final decodedString = await EncoderHandler.decode(
      request.bytes,
      customKey: request.encryptionKey,
      keyId: request.encryptionKeyId,
    );
    
    if (decodedString.isEmpty) {
      Logger.warn('Decoded string is empty', label: 'decodePartitionData');
      return [];
    }
    
    // parse JSON
    try {
      final jsonData = jsonDecode(decodedString) as Map<String, dynamic>;
      final partitionInfo = PartitionInfo.fromJson(jsonData);
      
      return partitionInfo.data.cast<Map<String, dynamic>>().toList();
    } catch (jsonError) {
      Logger.error('Failed to parse JSON data: $jsonError', label: 'decodePartitionData');
      // Return empty list as fallback instead of throwing exception
      return [];
    }
  } catch (e) {
    Logger.error('Failed to decode partition data: $e', label: 'decodePartitionData');
    // Return empty list as fallback instead of throwing exception
    return [];
  }
}

/// A top-level function designed to be run in a separate isolate.
///
/// This function takes an [EncodePartitionRequest], encodes the partition data,
/// and returns an [EncodedPartitionResult].
Future<EncodedPartitionResult> encodePartitionData(
  EncodePartitionRequest request) async {
  try {
    // count non-empty records
    final nonEmptyRecords = request.records.where((r) => r.isNotEmpty).toList();
    
    // calculate partition checksum
    Uint8List allRecordsData;
    String partitionChecksum;
    try {
      allRecordsData = Uint8List.fromList(utf8.encode(jsonEncode(request.records)));
      partitionChecksum = allRecordsData.hashCode.toString();
    } catch (jsonError) {
      Logger.error('Failed to encode records to JSON: $jsonError', label: 'encodePartitionData');
      // Create a fallback checksum
      partitionChecksum = DateTime.now().microsecondsSinceEpoch.toString();
    }
    
    // create partition meta
    final partitionMeta = PartitionMeta(
      version: 1,
      index: request.partitionIndex,
      totalRecords: nonEmptyRecords.length,
      fileSizeInBytes: 0, // will be updated later
      minPrimaryKey: request.minPk,
      maxPrimaryKey: request.maxPk,
      checksum: partitionChecksum,
      timestamps: request.timestamps,
      parentPath: request.parentPath,
    );
    
    // create partition info
    final partitionInfo = PartitionInfo(
      path: request.partitionPath,
      meta: partitionMeta,
      data: request.records,
    );
    
    // encode data
    Uint8List encodedData;
    try {
      encodedData = EncoderHandler.encode(
        jsonEncode(partitionInfo.toJson()),
        customKey: request.encryptionKey,
        keyId: request.encryptionKeyId,
      );
    } catch (encodeError) {
      Logger.error('Failed to encode partition info: $encodeError', label: 'encodePartitionData');
      // Create empty data as fallback
      encodedData = Uint8List(0);
    }
    
    // update size and return result
    return EncodedPartitionResult(
      encodedData: encodedData,
      partitionMeta: partitionMeta.copyWith(fileSizeInBytes: encodedData.length),
      nonEmptyRecordCount: nonEmptyRecords.length,
    );
  } catch (e) {
    Logger.error('Failed to encode partition data: $e', label: 'encodePartitionData');
    // Return a minimal valid result instead of throwing exception
    final emptyMeta = PartitionMeta(
      version: 1,
      index: request.partitionIndex,
      totalRecords: 0,
      fileSizeInBytes: 0,
      minPrimaryKey: null,
      maxPrimaryKey: null,
      checksum: "",
      timestamps: request.timestamps,
      parentPath: request.parentPath,
    );
    return EncodedPartitionResult(
      encodedData: Uint8List(0),
      partitionMeta: emptyMeta,
      nonEmptyRecordCount: 0,
    );
  }
}

/// A top-level function designed to be run in a separate isolate.
///
/// This function takes a [PartitionRangeAnalysisRequest], analyzes the partition key range,
/// and returns a [PartitionRangeAnalysisResult].
Future<PartitionRangeAnalysisResult> analyzePartitionKeyRange(
  PartitionRangeAnalysisRequest request) async {
  try {
    if (request.records.isEmpty) {
      return PartitionRangeAnalysisResult(recordCount: 0);
    }
    
    final nonEmptyRecords = request.records.where((r) => r.isNotEmpty).toList();
    if (nonEmptyRecords.isEmpty) {
      return PartitionRangeAnalysisResult(recordCount: 0);
    }
    
    // Check if primary key exists in first record
    if (!nonEmptyRecords.first.containsKey(request.primaryKey)) {
      Logger.warn(
        'Primary key "${request.primaryKey}" not found in records', 
        label: 'analyzePartitionKeyRange'
      );
      return PartitionRangeAnalysisResult(recordCount: nonEmptyRecords.length);
    }
    
    // initialize with the primary key value of the first record
    dynamic minPk = nonEmptyRecords.first[request.primaryKey];
    dynamic maxPk = minPk;
    
    // iterate through all records to find the minimum and maximum values
    for (final record in nonEmptyRecords) {
      final pk = record[request.primaryKey];
      if (pk != null) {
        try {
          if (_compareKeyValues(pk, minPk) < 0) minPk = pk;
          if (_compareKeyValues(pk, maxPk) > 0) maxPk = pk;
        } catch (compareError) {
          // If comparison fails for a specific record, log and continue
          Logger.warn(
            'Failed to compare key values: $compareError, key=$pk', 
            label: 'analyzePartitionKeyRange'
          );
        }
      }
    }
    
    // Check partition order when existingPartitions is provided
    bool isOrdered = true;
    if (request.existingPartitions != null && 
        request.existingPartitions!.isNotEmpty && 
        minPk != null && 
        maxPk != null) {
      
      // 1. Find the existing partition with max index
      PartitionMeta? maxIdxPartition;
      // 2. Find the partition itself for comparing internal ordered
      PartitionMeta? existingPartition;
      
      // Single traversal to find required partitions
      for (var partition in request.existingPartitions!) {
        // Skip empty partition
        if (partition.totalRecords <= 0 ||
            partition.minPrimaryKey == null ||
            partition.maxPrimaryKey == null) {
          continue;
        }
        
        // Find current partition
        if (partition.index == request.partitionIndex) {
          existingPartition = partition;
        }
        // Find the partition with max index
        else if (maxIdxPartition == null ||
            partition.index > maxIdxPartition.index) {
          maxIdxPartition = partition;
        }
      }
      
      // Check 1: Existing partition internal ordered check
      if (existingPartition != null && existingPartition.totalRecords > 0) {
        // If new data range is completely separated from existing range, mark as non-ordered
        if (_compareKeyValues(minPk, existingPartition.maxPrimaryKey) > 0 ||
            _compareKeyValues(maxPk, existingPartition.minPrimaryKey) < 0) {
          isOrdered = false;
        }
      }
      
      // Check 2: Relation with max index partition
      if (maxIdxPartition != null && maxIdxPartition.index != request.partitionIndex) {
        // If current partition index is greater than max index partition
        if (request.partitionIndex > maxIdxPartition.index) {
          if (_compareKeyValues(minPk, maxIdxPartition.maxPrimaryKey) <= 0) {
            isOrdered = false;
          }
        }
        // If current partition index is less than max index partition
        else if (request.partitionIndex < maxIdxPartition.index) {
          if (_compareKeyValues(maxPk, maxIdxPartition.minPrimaryKey) >= 0) {
            isOrdered = false;
          }
        }
      }
    }
    
    return PartitionRangeAnalysisResult(
      minPk: minPk,
      maxPk: maxPk,
      recordCount: nonEmptyRecords.length,
      isOrdered: isOrdered,
    );
  } catch (e) {
    Logger.error('Failed to analyze partition key range: $e', label: 'analyzePartitionKeyRange');
    // Return a valid result with just the record count
    return PartitionRangeAnalysisResult(
      recordCount: request.records.where((r) => r.isNotEmpty).length,
      isOrdered: false, // Conservative approach on error
    );
  }
}

/// Primary key value comparison function
int _compareKeyValues(dynamic a, dynamic b) {
  return ValueComparator.compare(a, b);
}

/// Request data for assigning records to partitions in an isolate.
class PartitionAssignmentRequest {
  /// The records to assign
  final List<Map<String, dynamic>> records;
  
  /// The partition size limit (bytes)
  final int partitionSizeLimit;
  
  /// The current partition index
  final int currentPartitionIndex;
  
  /// The current partition used size
  final int currentPartitionSize;
  
  PartitionAssignmentRequest({
    required this.records,
    required this.partitionSizeLimit,
    required this.currentPartitionIndex,
    required this.currentPartitionSize,
  });
}

/// Result data from assigning records to partitions in an isolate.
class PartitionAssignmentResult {
  /// The records assigned to partitions, Map<partition index, record list>
  final Map<int, List<Map<String, dynamic>>> partitionRecords;
  
  /// The estimated total data size
  final int estimatedTotalSize;
  
  /// The average record size
  final double averageRecordSize;
  
  PartitionAssignmentResult({
    required this.partitionRecords,
    required this.estimatedTotalSize,
    required this.averageRecordSize,
  });
}

/// A top-level function designed to be run in a separate isolate.
///
/// This function takes a [PartitionAssignmentRequest], assigns records to partitions,
/// and returns a [PartitionAssignmentResult].
Future<PartitionAssignmentResult> assignRecordsToPartitions(
    PartitionAssignmentRequest request) async {
  try {
    final result = <int, List<Map<String, dynamic>>>{};
    int currentPartitionIndex = request.currentPartitionIndex;
    int currentPartitionSize = request.currentPartitionSize;
    final partitionSizeLimit = request.partitionSizeLimit;
    final records = request.records;
    
    // estimate average record size
    int totalDataSize = 0;
    double averageRecordSize = 0;
    
    if (records.isNotEmpty) {
      try {
        // sample at most 10 records to calculate average size
        final sampleSize = records.length > 10 ? 10 : records.length;
        for (int i = 0; i < sampleSize; i++) {
          try {
            totalDataSize += jsonEncode(records[i]).length;
          } catch (jsonError) {
            Logger.warn(
              'Failed to encode record for size estimation: $jsonError', 
              label: 'assignRecordsToPartitions'
            );
            // Use a reasonable default size estimate
            totalDataSize += 100;
          }
        }
        averageRecordSize = totalDataSize / sampleSize;
        
        // estimate total data size
        totalDataSize = (averageRecordSize * records.length).toInt();
      } catch (estimationError) {
        Logger.warn(
          'Failed to estimate record sizes: $estimationError', 
          label: 'assignRecordsToPartitions'
        );
        // Use reasonable defaults
        averageRecordSize = 100.0;
        totalDataSize = 100 * records.length;
      }
    }
    
    // process records in order, assign all records to partitions
    for (var record in records) {
      int recordSize;
      try {
        // calculate record size
        recordSize = jsonEncode(record).length;
      } catch (sizeError) {
        Logger.warn(
          'Failed to calculate record size: $sizeError', 
          label: 'assignRecordsToPartitions'
        );
        // Use average size as fallback
        recordSize = averageRecordSize.toInt();
      }
      
      // if current partition is full, create new partition
      if (currentPartitionSize + recordSize > partitionSizeLimit) {
        currentPartitionIndex++; // create new partition
        currentPartitionSize = 0; // reset partition size
      }
      
      // update partition size
      currentPartitionSize += recordSize;
      
      // add record to corresponding partition
      if (!result.containsKey(currentPartitionIndex)) {
        result[currentPartitionIndex] = [];
      }
      result[currentPartitionIndex]!.add(record);
    }
    
    return PartitionAssignmentResult(
      partitionRecords: result,
      estimatedTotalSize: totalDataSize,
      averageRecordSize: averageRecordSize,
    );
  } catch (e) {
    Logger.error('Failed to assign records to partitions: $e', label: 'assignRecordsToPartitions');
    
    // Return fallback result instead of throwing exception
    // Put all records in a single partition
    final fallbackResult = <int, List<Map<String, dynamic>>>{};
    fallbackResult[request.currentPartitionIndex] = List.from(request.records);
    
    return PartitionAssignmentResult(
      partitionRecords: fallbackResult,
      estimatedTotalSize: 0,
      averageRecordSize: 0.0,
    );
  }
} 
