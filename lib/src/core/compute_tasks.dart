import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';

import 'b_plus_tree.dart';
import '../model/index_entry.dart';
import '../model/file_info.dart';
import '../model/table_schema.dart';
import '../model/data_store_config.dart';
import '../model/migration_task.dart';
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
      Logger.error('Failed to initialize B+ tree: $treeInitError',
          label: 'processIndexPartition');
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
        Logger.warn('Failed to insert entry: $insertError',
            label: 'processIndexPartition');
        // Continue with next entry
        continue;
      }
    }

    if (failedCount > 0) {
      Logger.warn(
          'Failed to insert $failedCount entries out of ${request.entries.length}',
          label: 'processIndexPartition');
    }

    // Serialize the final tree to a string.
    String serialized;
    try {
      serialized = btree.toStringHandle();
    } catch (serializeError) {
      Logger.error('Failed to serialize B+ tree: $serializeError',
          label: 'processIndexPartition');
      return IndexProcessingResult.failed();
    }

    // Return the results.
    return IndexProcessingResult(
      serializedBTree: serialized,
      newSize: serialized.length,
      entryCount: btree.count(),
    );
  } catch (e) {
    Logger.error('Failed to process index partition: $e',
        label: 'processIndexPartition');
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
      Logger.warn('Checksum verification failed for index delete operation',
          label: 'processIndexDelete');
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
      Logger.error('Failed to initialize B+ tree: $treeError',
          label: 'processIndexDelete');
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
        Logger.warn('Failed to process delete for key $key: $keyError',
            label: 'processIndexDelete');
        // Continue with next key
        continue;
      }
    }

    String newContent;
    try {
      // Serialize the B+ tree if modified
      newContent = isModified ? btree.toStringHandle() : request.content;
    } catch (serializeError) {
      Logger.error('Failed to serialize B+ tree: $serializeError',
          label: 'processIndexDelete');
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
    Logger.error('Failed to process index delete operation: $e',
        label: 'processIndexDelete');
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

  /// Optional encoder state for isolate execution
  final Map<String, dynamic>? encoderState;

  DecodePartitionRequest({
    required this.bytes,
    this.encryptionKey,
    this.encryptionKeyId,
    this.encoderState,
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

  /// Optional encoder state for isolate execution
  final Map<String, dynamic>? encoderState;

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
    this.encoderState,
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

  /// Create a copy with some fields replaced
  PartitionRangeAnalysisResult copyWith({
    dynamic minPk,
    dynamic maxPk,
    int? recordCount,
    bool? isOrdered,
  }) {
    return PartitionRangeAnalysisResult(
      minPk: minPk ?? this.minPk,
      maxPk: maxPk ?? this.maxPk,
      recordCount: recordCount ?? this.recordCount,
      isOrdered: isOrdered ?? this.isOrdered,
    );
  }

  /// Convert to a map for serialization
  Map<String, dynamic> toJson() {
    return {
      'minPk': minPk,
      'maxPk': maxPk,
      'recordCount': recordCount,
      'isOrdered': isOrdered,
    };
  }

  /// Create from a map after deserialization
  factory PartitionRangeAnalysisResult.fromJson(Map<String, dynamic> json) {
    try {
      return PartitionRangeAnalysisResult(
        minPk: json['minPk'],
        maxPk: json['maxPk'],
        recordCount: json['recordCount'] is int
            ? json['recordCount']
            : int.tryParse(json['recordCount'].toString()) ?? 0,
        isOrdered: json['isOrdered'] is bool
            ? json['isOrdered']
            : json['isOrdered'].toString().toLowerCase() == 'true',
      );
    } catch (e) {
      Logger.error('Failed to parse PartitionRangeAnalysisResult: $e',
          label: 'PartitionRangeAnalysisResult.fromJson');
      return PartitionRangeAnalysisResult(recordCount: 0, isOrdered: false);
    }
  }
}

/// A top-level function designed to be run in a separate isolate.
///
/// This function takes a [DecodePartitionRequest], decodes the partition data,
/// and returns a list of records.
Future<List<Map<String, dynamic>>> decodePartitionData(
    DecodePartitionRequest request) async {
  try {
    // if encoder state is provided, apply it
    // ONLY apply encoder state if no specific encryption key/keyId is provided
    if (request.encoderState != null &&
        request.encryptionKey == null &&
        request.encryptionKeyId == null) {
      EncoderHandler.setEncodingState(request.encoderState!);
    }

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
      Logger.error('Failed to parse JSON data: $jsonError',
          label: 'decodePartitionData');
      // Return empty list as fallback instead of throwing exception
      return [];
    }
  } catch (e) {
    Logger.error('Failed to decode partition data: $e',
        label: 'decodePartitionData');
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
    // if encoder state is provided, apply it
    // ONLY apply encoder state if no specific encryption key/keyId is provided
    if (request.encoderState != null &&
        request.encryptionKey == null &&
        request.encryptionKeyId == null) {
      EncoderHandler.setEncodingState(request.encoderState!);
    }

    // count non-empty records
    final nonEmptyRecords = request.records.where((r) => r.isNotEmpty).toList();

    // calculate partition checksum
    Uint8List allRecordsData;
    String partitionChecksum;
    try {
      allRecordsData =
          Uint8List.fromList(utf8.encode(jsonEncode(request.records)));
      partitionChecksum = allRecordsData.hashCode.toString();
    } catch (jsonError) {
      Logger.error('Failed to encode records to JSON: $jsonError',
          label: 'encodePartitionData');
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
      Logger.error('Failed to encode partition info: $encodeError',
          label: 'encodePartitionData');
      // Create empty data as fallback
      encodedData = Uint8List(0);
    }

    // update size and return result
    return EncodedPartitionResult(
      encodedData: encodedData,
      partitionMeta:
          partitionMeta.copyWith(fileSizeInBytes: encodedData.length),
      nonEmptyRecordCount: nonEmptyRecords.length,
    );
  } catch (e) {
    Logger.error('Failed to encode partition data: $e',
        label: 'encodePartitionData');
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
      Logger.warn('Primary key "${request.primaryKey}" not found in records',
          label: 'analyzePartitionKeyRange');
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
          Logger.warn('Failed to compare key values: $compareError, key=$pk',
              label: 'analyzePartitionKeyRange');
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
        try {
          // If new data range is completely separated from existing range, mark as non-ordered
          if (_compareKeyValues(minPk, existingPartition.maxPrimaryKey) > 0 ||
              _compareKeyValues(maxPk, existingPartition.minPrimaryKey) < 0) {
            isOrdered = false;
          }
        } catch (compareError) {
          Logger.warn(
              'Failed to compare key values for existing partition: $compareError',
              label: 'analyzePartitionKeyRange');
          isOrdered = false; // Conservative approach on comparison error
        }
      }

      // Check 2: Relation with max index partition
      if (maxIdxPartition != null &&
          maxIdxPartition.index != request.partitionIndex) {
        try {
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
        } catch (compareError) {
          Logger.warn(
              'Failed to compare key values with max index partition: $compareError',
              label: 'analyzePartitionKeyRange');
          isOrdered = false; // Conservative approach on comparison error
        }
      }
    }

    // Ensure the return value is always of type PartitionRangeAnalysisResult
    final result = PartitionRangeAnalysisResult(
      minPk: minPk,
      maxPk: maxPk,
      recordCount: nonEmptyRecords.length,
      isOrdered: isOrdered,
    );

    return result;
  } catch (e) {
    Logger.error('Failed to analyze partition key range: $e',
        label: 'analyzePartitionKeyRange');

    // Even in case of error, ensure the return type is correct
    try {
      return PartitionRangeAnalysisResult(
        recordCount: request.records.where((r) => r.isNotEmpty).length,
        isOrdered: false, // Conservative approach on error
      );
    } catch (innerError) {
      // Last defense mechanism: return a basic valid object
      Logger.error('Critical error in partition analysis: $innerError',
          label: 'analyzePartitionKeyRange');
      return PartitionRangeAnalysisResult(recordCount: 0, isOrdered: false);
    }
  }
}

/// Primary key value comparison function
int _compareKeyValues(dynamic a, dynamic b) {
  try {
    return ValueComparator.compare(a, b);
  } catch (e) {
    Logger.warn('Value comparison error: $e', label: '_compareKeyValues');
    // Default comparison fallback
    return a.toString().compareTo(b.toString());
  }
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
  /// The records assigned to partitions
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
                label: 'assignRecordsToPartitions');
            // Use a reasonable default size estimate
            totalDataSize += 100;
          }
        }
        averageRecordSize = totalDataSize / sampleSize;

        // estimate total data size
        totalDataSize = (averageRecordSize * records.length).toInt();
      } catch (estimationError) {
        Logger.warn('Failed to estimate record sizes: $estimationError',
            label: 'assignRecordsToPartitions');
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
        Logger.warn('Failed to calculate record size: $sizeError',
            label: 'assignRecordsToPartitions');
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
    Logger.error('Failed to assign records to partitions: $e',
        label: 'assignRecordsToPartitions');

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

/// Table similarity calculation request
class TableSimilarityRequest {
  /// Old table schema
  final TableSchema oldSchema;

  /// New table schema
  final TableSchema newSchema;

  /// Old table index
  final int oldTableIndex;

  /// New table index
  final int newTableIndex;

  /// Old table count
  final int oldTablesCount;

  /// New table count
  final int newTablesCount;

  TableSimilarityRequest({
    required this.oldSchema,
    required this.newSchema,
    required this.oldTableIndex,
    required this.newTableIndex,
    required this.oldTablesCount,
    required this.newTablesCount,
  });
}

/// Table similarity calculation result
class TableSimilarityResult {
  /// Old table name
  final String oldTableName;

  /// New table schema
  final TableSchema newSchema;

  /// Similarity (0-1)
  final double similarity;

  TableSimilarityResult({
    required this.oldTableName,
    required this.newSchema,
    required this.similarity,
  });
}

/// Table similarity batch calculation request
class BatchTableSimilarityRequest {
  /// List of similarity requests to process
  final List<TableSimilarityRequest> requests;

  BatchTableSimilarityRequest({
    required this.requests,
  });
}

/// Table similarity batch calculation result
class BatchTableSimilarityResult {
  /// List of similarity results
  final List<TableSimilarityResult> results;

  BatchTableSimilarityResult({
    required this.results,
  });
}

/// Field similarity calculation request
class FieldSimilarityRequest {
  /// Old field
  final FieldSchema oldField;

  /// New field
  final FieldSchema newField;

  /// Old field index
  final int oldFieldIndex;

  /// New field index
  final int newFieldIndex;

  /// Old table field count
  final int oldFieldsCount;

  /// New table field count
  final int newFieldsCount;

  /// Old table schema
  final TableSchema oldSchema;

  /// New table schema
  final TableSchema newSchema;

  FieldSimilarityRequest({
    required this.oldField,
    required this.newField,
    required this.oldFieldIndex,
    required this.newFieldIndex,
    required this.oldFieldsCount,
    required this.newFieldsCount,
    required this.oldSchema,
    required this.newSchema,
  });
}

/// Field similarity calculation result
class FieldSimilarityResult {
  /// Old field name
  final String oldFieldName;

  /// New field
  final FieldSchema newField;

  /// Similarity (0-1)
  final double similarity;

  FieldSimilarityResult({
    required this.oldFieldName,
    required this.newField,
    required this.similarity,
  });
}

/// Field similarity batch calculation request
class BatchFieldSimilarityRequest {
  /// List of similarity requests to process
  final List<FieldSimilarityRequest> requests;

  BatchFieldSimilarityRequest({
    required this.requests,
  });
}

/// Field similarity batch calculation result
class BatchFieldSimilarityResult {
  /// List of similarity results
  final List<FieldSimilarityResult> results;

  BatchFieldSimilarityResult({
    required this.results,
  });
}

/// Calculate similarity between two tables
Future<TableSimilarityResult> calculateTableSimilarity(
    TableSimilarityRequest request) async {
  double score = 0.0;
  double totalWeight = 0.0;

  // 1. First check table name similarity (medium weight)
  const nameWeight = 10.0;
  totalWeight += nameWeight;
  double nameScore =
      _calculateNameSimilarity(request.oldSchema.name, request.newSchema.name);
  score += nameWeight * nameScore;

  // 2. Check primary key (high weight)
  const primaryKeyWeight = 20.0;
  totalWeight += primaryKeyWeight;
  if (request.oldSchema.primaryKey == request.newSchema.primaryKey) {
    score += primaryKeyWeight;
  } else {
    // Primary key mismatch is a strong negative signal
    score -= primaryKeyWeight * 0.5;
  }

  // 3. Check isGlobal property (medium weight)
  const globalWeight = 10.0;
  totalWeight += globalWeight;
  if (request.oldSchema.isGlobal == request.newSchema.isGlobal) {
    score += globalWeight;
  } else {
    // isGlobal mismatch is an important signal
    score -= globalWeight * 0.3;
  }

  // 4. Check field matching (highest weight)
  const fieldsWeight = 50.0;
  totalWeight += fieldsWeight;

  // 4.1 Field count comparison
  double fieldsScore = 0.0;
  if (request.oldSchema.fields.isEmpty || request.newSchema.fields.isEmpty) {
    fieldsScore = 0.0;
  } else {
    // Check common field count
    int matchingFields = 0;
    Set<String> oldFieldNames =
        request.oldSchema.fields.map((f) => f.name).toSet();
    Set<String> newFieldNames =
        request.newSchema.fields.map((f) => f.name).toSet();

    // Calculate common field count
    for (final name in oldFieldNames) {
      if (newFieldNames.contains(name)) {
        matchingFields++;
      }
    }

    // Calculate field match rate
    final matchingFieldsRatio = request.oldSchema.fields.isEmpty ||
            request.newSchema.fields.isEmpty
        ? 0.0
        : (2 * matchingFields) / (oldFieldNames.length + newFieldNames.length);

    fieldsScore = matchingFieldsRatio;
  }

  score += fieldsWeight * fieldsScore;

  // 5. Index match rate (medium weight)
  const indexWeight = 15.0;
  totalWeight += indexWeight;

  double indexScore = 0.0;
  if (request.oldSchema.indexes.isEmpty && request.newSchema.indexes.isEmpty) {
    // Both have no indexes, perfect match
    indexScore = 1.0;
  } else if (request.oldSchema.indexes.isEmpty ||
      request.newSchema.indexes.isEmpty) {
    // One has index, one doesn't, not a good match
    indexScore = 0.1;
  } else {
    // Check index field matching
    int matchingIndexes = 0;

    for (final oldIndex in request.oldSchema.indexes) {
      for (final newIndex in request.newSchema.indexes) {
        if (_areFieldListsEqual(oldIndex.fields, newIndex.fields)) {
          matchingIndexes++;
          break;
        }
      }
    }

    // Calculate index match rate
    final totalIndexes =
        request.oldSchema.indexes.length + request.newSchema.indexes.length;
    indexScore = totalIndexes > 0 ? (2 * matchingIndexes) / totalIndexes : 0.0;
  }

  score += indexWeight * indexScore;

  // 6. Table position matching (low weight)
  const positionWeight = 5.0;
  totalWeight += positionWeight;

  // Calculate relative position difference
  double positionDiff;
  if (request.oldTablesCount <= 1 || request.newTablesCount <= 1) {
    positionDiff = 0;
  } else {
    positionDiff = (request.oldTableIndex / (request.oldTablesCount - 1) -
            request.newTableIndex / (request.newTablesCount - 1))
        .abs();
  }

  score += positionWeight * (1 - positionDiff);

  // Calculate final score
  double finalScore = totalWeight > 0 ? score / totalWeight : 0.0;

  return TableSimilarityResult(
    oldTableName: request.oldSchema.name,
    newSchema: request.newSchema,
    similarity: finalScore,
  );
}

/// Batch calculate table similarity
Future<BatchTableSimilarityResult> calculateBatchTableSimilarity(
    BatchTableSimilarityRequest request) async {
  final results = <TableSimilarityResult>[];

  for (final req in request.requests) {
    final result = await calculateTableSimilarity(req);
    results.add(result);
  }

  return BatchTableSimilarityResult(results: results);
}

/// Calculate similarity between two fields
Future<FieldSimilarityResult> calculateFieldSimilarity(
    FieldSimilarityRequest request) async {
  double score = 0.0;
  double totalWeight = 0.0;

  // 1. Basic type matching (high weight)
  const typeWeight = 20.0;
  totalWeight += typeWeight;
  if (request.oldField.type == request.newField.type) {
    score += typeWeight;
  } else {
    // Type mismatch, reduce some weight
    score -= typeWeight * 0.7;
  }

  // 2. Default value matching (if not basic empty value)
  const defaultValueWeight = 15.0;
  totalWeight += defaultValueWeight;
  if (request.oldField.defaultValue != null &&
      request.newField.defaultValue != null) {
    if (request.oldField.defaultValue == request.newField.defaultValue) {
      score += defaultValueWeight;
    } else {
      // Default value mismatch is a strong negative signal
      score -= defaultValueWeight * 0.5;
    }
  } else if (request.oldField.defaultValue == null &&
      request.newField.defaultValue == null) {
    // Both are empty, also considered partial match
    score += defaultValueWeight * 0.5;
  }

  // 3. Comment matching (high weight for non-empty and meaningful comments)
  const commentWeight = 20.0;
  if (request.oldField.comment != null &&
      request.newField.comment != null &&
      request.oldField.comment!.length > 1 &&
      request.newField.comment!.length > 1) {
    totalWeight += commentWeight;
    if (request.oldField.comment == request.newField.comment) {
      score += commentWeight;
    } else {
      // Different meaningful comments are strong negative signals
      score -= commentWeight * 0.5;
    }
  }

  // 4. Nullable and unique property matching
  const nullableWeight = 10.0;
  totalWeight += nullableWeight;
  if (request.oldField.nullable == request.newField.nullable) {
    score += nullableWeight;
  } else {
    // Nullable mismatch is a negative signal
    score -= nullableWeight * 0.3;
  }

  const uniqueWeight = 10.0;
  totalWeight += uniqueWeight;
  if (request.oldField.unique == request.newField.unique) {
    score += uniqueWeight;
  } else {
    // Unique mismatch is a negative signal
    score -= uniqueWeight * 0.3;
  }

  // 5. Length and value range constraint matching
  const constraintWeight = 5.0;
  double constraintsChecked = 0;
  double constraintsMatched = 0;

  // maxLength check
  if (request.oldField.maxLength != null ||
      request.newField.maxLength != null) {
    constraintsChecked++;
    if (request.oldField.maxLength == request.newField.maxLength) {
      constraintsMatched++;
    }
  }

  // minLength check
  if (request.oldField.minLength != null ||
      request.newField.minLength != null) {
    constraintsChecked++;
    if (request.oldField.minLength == request.newField.minLength) {
      constraintsMatched++;
    }
  }

  // minValue check
  if (request.oldField.minValue != null || request.newField.minValue != null) {
    constraintsChecked++;
    if (request.oldField.minValue == request.newField.minValue) {
      constraintsMatched++;
    }
  }

  // maxValue check
  if (request.oldField.maxValue != null || request.newField.maxValue != null) {
    constraintsChecked++;
    if (request.oldField.maxValue == request.newField.maxValue) {
      constraintsMatched++;
    }
  }

  if (constraintsChecked > 0) {
    totalWeight += constraintWeight;
    score += (constraintsMatched / constraintsChecked) * constraintWeight;
  }

  // 6. Field position matching (high weight)
  const positionWeight = 25.0;
  totalWeight += positionWeight;

  // Calculate relative position difference (0-1 value, 0 means perfect match)
  double positionDiff;
  if (request.oldFieldsCount == 1 || request.newFieldsCount == 1) {
    // If there is only one field, position is not important
    positionDiff = 0;
  } else {
    // Normalize position difference to 0-1
    positionDiff = (request.oldFieldIndex / (request.oldFieldsCount - 1) -
            request.newFieldIndex / (request.newFieldsCount - 1))
        .abs();
  }

  // The closer the position, the higher the score
  score += positionWeight * (1 - positionDiff);

  // 7. Field name similarity check
  const nameWeight = 15.0;
  totalWeight += nameWeight;

  // Field name string similarity
  double nameScore =
      _calculateNameSimilarity(request.oldField.name, request.newField.name);
  score += nameWeight * nameScore;

  // 8. Index position check
  const indexWeight = 5.0;
  bool oldFieldInIndex =
      _isFieldInIndex(request.oldField.name, request.oldSchema.indexes);
  bool newFieldInIndex =
      _isFieldInIndex(request.newField.name, request.newSchema.indexes);

  if (oldFieldInIndex && newFieldInIndex) {
    totalWeight += indexWeight;
    score += indexWeight;
  } else if (!oldFieldInIndex && !newFieldInIndex) {
    // Both are not in index, also considered match
    totalWeight += indexWeight;
    score += indexWeight * 0.5;
  }

  // 9. Field count similarity (extra factor)
  if (request.oldFieldsCount == request.newFieldsCount) {
    // Field count is consistent, add a small extra score
    score += 5.0;
    totalWeight += 5.0;
  }

  // Calculate final percentage score (0-1)
  double finalScore = totalWeight > 0 ? score / totalWeight : 0.0;

  return FieldSimilarityResult(
    oldFieldName: request.oldField.name,
    newField: request.newField,
    similarity: finalScore,
  );
}

/// Batch calculate field similarity
Future<BatchFieldSimilarityResult> calculateBatchFieldSimilarity(
    BatchFieldSimilarityRequest request) async {
  final results = <FieldSimilarityResult>[];

  for (final req in request.requests) {
    final result = await calculateFieldSimilarity(req);
    results.add(result);
  }

  return BatchFieldSimilarityResult(results: results);
}

/// Check if field is in any index
bool _isFieldInIndex(String fieldName, List<IndexSchema> indexes) {
  for (var index in indexes) {
    if (index.fields.contains(fieldName)) {
      return true;
    }
  }
  return false;
}

/// Calculate if two lists contain the same elements, ignoring order
bool _areFieldListsEqual(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  final setA = Set<String>.from(a);
  final setB = Set<String>.from(b);
  return setA.difference(setB).isEmpty;
}

/// Calculate similarity between two names
double _calculateNameSimilarity(String oldName, String newName) {
  // 1. Normalize processing: convert to lowercase
  final oldNameLower = oldName.toLowerCase();
  final newNameLower = newName.toLowerCase();

  if (oldNameLower == newNameLower) {
    return 1.0; // Perfect match
  }

  // 2. Camel case and underscore conversion comparison
  String oldNameNormalized = _normalizeFieldName(oldNameLower);
  String newNameNormalized = _normalizeFieldName(newNameLower);

  if (oldNameNormalized == newNameNormalized) {
    return 0.9; // Very close
  }

  // 3. Calculate longest common subsequence
  int lcsLength =
      _getLongestCommonSubsequenceLength(oldNameNormalized, newNameNormalized);
  int maxLength = oldNameNormalized.length > newNameNormalized.length
      ? oldNameNormalized.length
      : newNameNormalized.length;

  // Return similarity score between 0 and 1
  return maxLength > 0 ? lcsLength / maxLength : 0.0;
}

/// Normalize field name: handle camel case and underscore
String _normalizeFieldName(String name) {
  // Camel case to underscore
  String result = name.replaceAllMapped(
      RegExp(r'[A-Z]'), (match) => '_${match.group(0)!.toLowerCase()}');

  // Handle consecutive underscores
  result = result.replaceAll(RegExp(r'_+'), '_');

  // Delete leading underscore
  if (result.startsWith('_')) {
    result = result.substring(1);
  }

  return result;
}

/// Get longest common subsequence length
int _getLongestCommonSubsequenceLength(String a, String b) {
  if (a.isEmpty || b.isEmpty) return 0;

  List<List<int>> dp =
      List.generate(a.length + 1, (_) => List.filled(b.length + 1, 0));

  for (int i = 1; i <= a.length; i++) {
    for (int j = 1; j <= b.length; j++) {
      if (a[i - 1] == b[j - 1]) {
        dp[i][j] = dp[i - 1][j - 1] + 1;
      } else {
        dp[i][j] = dp[i - 1][j] > dp[i][j - 1] ? dp[i - 1][j] : dp[i][j - 1];
      }
    }
  }

  return dp[a.length][b.length];
}

/// Table record migration processing request
class MigrationRecordProcessRequest {
  /// Records to migrate
  final List<Map<String, dynamic>> records;

  /// Table operations
  final List<MigrationOperation> operations;

  /// Old table schema (optional)
  final TableSchema? oldSchema;

  MigrationRecordProcessRequest({
    required this.records,
    required this.operations,
    this.oldSchema,
  });
}

/// Table record migration processing result
class MigrationRecordProcessResult {
  /// Processed records
  final List<Map<String, dynamic>> migratedRecords;

  /// Processing result status
  final bool success;

  /// Error message (if any)
  final String? errorMessage;

  MigrationRecordProcessResult({
    required this.migratedRecords,
    this.success = true,
    this.errorMessage,
  });
}

/// Process record migration
Future<MigrationRecordProcessResult> processMigrationRecords(
    MigrationRecordProcessRequest request) async {
  try {
    if (request.records.isEmpty || request.operations.isEmpty) {
      return MigrationRecordProcessResult(
        migratedRecords: request.records,
        success: true,
      );
    }

    var modifiedRecords = List<Map<String, dynamic>>.from(request.records);

    // Use sorted operations, no need to reorder
    for (var operation in request.operations) {
      switch (operation.type) {
        case MigrationType.addField:
          final field = operation.field!;
          modifiedRecords = modifiedRecords.map((record) {
            if (!record.containsKey(field.name)) {
              record[field.name] = field.getDefaultValue();
            }
            return record;
          }).toList();
          break;

        case MigrationType.removeField:
          final fieldName = operation.fieldName!;
          modifiedRecords = modifiedRecords.map((record) {
            record.remove(fieldName);
            return record;
          }).toList();
          break;

        case MigrationType.renameField:
          final oldName = operation.fieldName!;
          final newName = operation.newName!;
          modifiedRecords = modifiedRecords.map((record) {
            if (record.containsKey(oldName)) {
              record[newName] = record[oldName];
              record.remove(oldName);
            }
            return record;
          }).toList();
          break;

        case MigrationType.modifyField:
          final fieldUpdate = operation.fieldUpdate!;
          // Get old field information
          FieldSchema? oldFieldSchema;
          if (request.oldSchema != null) {
            try {
              oldFieldSchema = request.oldSchema!.fields
                  .firstWhere((f) => f.name == fieldUpdate.name);
            } catch (e) {
              oldFieldSchema = null;
            }
          }
          modifiedRecords = modifiedRecords.map((record) {
            if (record.containsKey(fieldUpdate.name)) {
              // Call the method to process field modification, pass old field information
              record = _applyFieldModification(record, fieldUpdate,
                  oldFieldSchema: oldFieldSchema);
            }
            return record;
          }).toList();
          break;

        case MigrationType.addIndex:
          // Index operation does not affect record data
          break;

        case MigrationType.removeIndex:
          break;

        case MigrationType.modifyIndex:
          break;

        case MigrationType.renameTable:
          // Table rename operation does not affect current record data, but needs to be handled at a higher level
          break;

        case MigrationType.dropTable:
          // Delete table operation does not affect record data
          break;

        case MigrationType.setPrimaryKeyConfig:
          // Process primary key configuration changes, especially handle primary key name changes and data type changes
          if (operation.oldPrimaryKeyConfig != null &&
              operation.primaryKeyConfig != null) {
            final oldConfig = operation.oldPrimaryKeyConfig!;
            final newConfig = operation.primaryKeyConfig!;

            // Process primary key name changes
            if (oldConfig.name != newConfig.name) {
              modifiedRecords = modifiedRecords.map((record) {
                if (record.containsKey(oldConfig.name)) {
                  // Copy old primary key field value to new primary key field
                  record[newConfig.name] = record[oldConfig.name];
                  // Delete old primary key field
                  record.remove(oldConfig.name);
                }
                return record;
              }).toList();
            }
          }
          break;
      }
    }

    return MigrationRecordProcessResult(
      migratedRecords: modifiedRecords,
      success: true,
    );
  } catch (e) {
    Logger.error('Failed to process migration records: $e',
        label: 'processMigrationRecords');
    return MigrationRecordProcessResult(
      migratedRecords: request.records,
      success: false,
      errorMessage: e.toString(),
    );
  }
}

/// Apply field modification to a single record
Map<String, dynamic> _applyFieldModification(
    Map<String, dynamic> record, FieldSchemaUpdate fieldUpdate,
    {FieldSchema? oldFieldSchema}) {
  // Create field schema for validation and get default value
  final fieldSchema = FieldSchema(
    name: fieldUpdate.name,
    type: fieldUpdate.type ?? (oldFieldSchema?.type ?? DataType.text),
    nullable: fieldUpdate.nullable ?? (oldFieldSchema?.nullable ?? true),
    defaultValue: fieldUpdate.defaultValue ?? oldFieldSchema?.defaultValue,
    unique: fieldUpdate.unique ?? (oldFieldSchema?.unique ?? false),
    maxLength: fieldUpdate.maxLength ?? oldFieldSchema?.maxLength,
    minLength: fieldUpdate.minLength ?? oldFieldSchema?.minLength,
    minValue: fieldUpdate.minValue ?? oldFieldSchema?.minValue,
    maxValue: fieldUpdate.maxValue ?? oldFieldSchema?.maxValue,
    comment: fieldUpdate.comment ?? oldFieldSchema?.comment,
  );

  // 1. Process type changes
  if (fieldUpdate.type != null) {
    try {
      record[fieldUpdate.name] = fieldSchema.convertValue(
        value: record[fieldUpdate.name],
      );
    } catch (e) {
      record[fieldUpdate.name] = fieldSchema.getDefaultValue();
      Logger.warn(
        'Failed to convert field ${fieldUpdate.name} to type ${fieldUpdate.type}, using default value: $e',
        label: 'processMigrationRecords._applyFieldModification',
      );
    }
  }

  // 2. Process null constraint changes
  if (fieldUpdate.nullable != null &&
      !fieldUpdate.nullable! &&
      record[fieldUpdate.name] == null) {
    record[fieldUpdate.name] = fieldSchema.getDefaultValue();
    Logger.debug(
      'Field ${fieldUpdate.name} is now non-nullable, applied default value',
      label: 'processMigrationRecords._applyFieldModification',
    );
  }

  // 3. Process default value changes
  if (fieldUpdate.defaultValue != null && record[fieldUpdate.name] == null) {
    record[fieldUpdate.name] = fieldUpdate.defaultValue;
    Logger.debug(
      'Field ${fieldUpdate.name} has new default value, applied to null value',
      label: 'processMigrationRecords._applyFieldModification',
    );
  }

  // 4. Process unique constraint changes (only log, do not directly process data itself)
  if (fieldUpdate.unique != null && fieldUpdate.unique!) {
    Logger.debug(
      'Field ${fieldUpdate.name} now has unique constraint, further validation may be needed',
      label: 'processMigrationRecords._applyFieldModification',
    );
  }

  // 5. Process length constraint changes (only log, do not directly process data itself)
  if ((fieldUpdate.maxLength != null || fieldUpdate.minLength != null) &&
      record[fieldUpdate.name] is String) {
    String value = record[fieldUpdate.name];
    if (fieldUpdate.maxLength != null &&
        value.length > fieldUpdate.maxLength!) {
      record[fieldUpdate.name] = value.substring(0, fieldUpdate.maxLength!);
      Logger.warn(
        'Field ${fieldUpdate.name} exceeds max length of ${fieldUpdate.maxLength}, truncated',
        label: 'processMigrationRecords._applyFieldModification',
      );
    }
    if (fieldUpdate.minLength != null &&
        value.length < fieldUpdate.minLength!) {
      record[fieldUpdate.name] = fieldSchema.getDefaultValue();
      Logger.warn(
        'Field ${fieldUpdate.name} is shorter than min length of ${fieldUpdate.minLength}, using default value',
        label: 'processMigrationRecords._applyFieldModification',
      );
    }
  }

  // 6. Process value range constraint changes (only log, do not directly process data itself)
  if ((fieldUpdate.minValue != null || fieldUpdate.maxValue != null) &&
      record[fieldUpdate.name] is num) {
    num value = record[fieldUpdate.name];

    if (fieldUpdate.minValue != null && value < fieldUpdate.minValue!) {
      record[fieldUpdate.name] = fieldUpdate.minValue;
      Logger.warn(
        'Field ${fieldUpdate.name} below min value of ${fieldUpdate.minValue}, set to min',
        label: 'processMigrationRecords._applyFieldModification',
      );
    }

    if (fieldUpdate.maxValue != null && value > fieldUpdate.maxValue!) {
      record[fieldUpdate.name] = fieldUpdate.maxValue;
      Logger.warn(
        'Field ${fieldUpdate.name} exceeds max value of ${fieldUpdate.maxValue}, set to max',
        label: 'processMigrationRecords._applyFieldModification',
      );
    }
  }

  // 7. Final validation
  if (!fieldSchema.validateValue(record[fieldUpdate.name])) {
    record[fieldUpdate.name] = fieldSchema.getDefaultValue();
    Logger.warn(
      'Field ${fieldUpdate.name} value does not meet constraints after updates, using default value',
      label: 'processMigrationRecords._applyFieldModification',
    );
  }

  return record;
}

/// Time-based ID generation request (for isolate)
class TimeBasedIdGenerateRequest {
  /// ID type
  final PrimaryKeyType keyType;

  /// Node configuration
  final DistributedNodeConfig nodeConfig;

  /// Table name
  final String tableName;

  /// Generation count
  final int count;

  /// Start time or date value
  final dynamic startValue;

  /// Start sequence number
  final int startSequence;

  /// Whether to use new timestamp
  final bool useNewTimestamp;

  /// Whether to use random step
  final bool useRandomStep;

  /// 高生成模式
  final bool isHighGeneration;

  TimeBasedIdGenerateRequest({
    required this.keyType,
    required this.nodeConfig,
    required this.tableName,
    required this.count,
    required this.startValue,
    required this.startSequence,
    this.useNewTimestamp = false,
    this.useRandomStep = false,
    this.isHighGeneration = false,
  });
}

/// Time-based ID generation result (isolate return)
class TimeBasedIdGenerateResult {
  /// List of generated IDs
  final List<String> ids;

  /// Latest time value
  final dynamic lastValue;

  /// Latest sequence number
  final int lastSequence;

  /// Whether generation is successful
  final bool success;

  /// Error message
  final String? errorMessage;

  TimeBasedIdGenerateResult({
    required this.ids,
    required this.lastValue,
    required this.lastSequence,
    this.success = true,
    this.errorMessage,
  });
}

/// Base62 encoder copied to avoid class reference issues in isolate
class _IsolateBase62Encoder {
  static const String _charset =
      '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

  /// Encode BigInt to Base62 string
  static String encode(BigInt value) {
    if (value < BigInt.zero) {
      throw ArgumentError('Base62 encoding does not support negative numbers');
    }
    if (value == BigInt.zero) {
      return '0';
    }

    String result = '';
    BigInt base = BigInt.from(62);
    BigInt remainder;

    while (value > BigInt.zero) {
      remainder = value % base;
      value = value ~/ base;
      result = _charset[remainder.toInt()] + result;
    }

    return result;
  }
}

/// Generate timestamp or date prefixed ID in isolate
Future<TimeBasedIdGenerateResult> generateTimeBasedIds(
    TimeBasedIdGenerateRequest request) async {
  try {
    // Create new random number seed for Random
    final random = Random(DateTime.now().millisecondsSinceEpoch);

    // Initialize basic parameters
    final List<String> result = [];
    final List<BigInt> numericIds = [];

    // Set current state
    dynamic currentValue = request.startValue;
    int sequence = request.startSequence;
    dynamic workingValue = currentValue;

    // Create necessary constants and caches
    const int maxSequence = 99999; // Sequence number limit
    const int epochStartSeconds = 441763200; // Timestamp start point

    // Calculate nodeId digits
    int nodeIdDigits = 1;
    if (request.nodeConfig.nodeId > 0) {
      int temp = request.nodeConfig.nodeId;
      nodeIdDigits = 0;
      while (temp > 0) {
        temp ~/= 10;
        nodeIdDigits++;
      }
    }

    // Precompute commonly used BigInt values
    final sequenceFactor = BigInt.from(100000); // 10^5
    BigInt powerFactor;
    BigInt? nodeIdBig;

    if (request.nodeConfig.enableDistributed) {
      powerFactor = BigInt.from(10).pow(nodeIdDigits + 5);
      final nodeId =
          request.nodeConfig.nodeId > 0 ? request.nodeConfig.nodeId : 1;
      nodeIdBig = BigInt.from(nodeId);
    } else {
      powerFactor = sequenceFactor; // Use 10^5 in non-distributed mode
      nodeIdBig = BigInt.from(1);
    }

    // Select different generation logic based on ID type
    if (request.keyType == PrimaryKeyType.timestampBased ||
        request.keyType == PrimaryKeyType.shortCode) {
      // Timestamp ID generation or short code ID generation

      // Efficient generation strategy: generate all IDs in order when sequence number space is sufficient
      if (request.isHighGeneration && sequence + request.count <= maxSequence) {
        // Efficient batch generation method
        for (int i = 0; i < request.count; i++) {
          sequence += 1;

          // Calculate timestamp ID
          final BigInt timestampBig = BigInt.from(workingValue);
          final BigInt sequenceBig = BigInt.from(sequence);

          BigInt idValue;
          if (request.nodeConfig.enableDistributed) {
            // Algorithm with node ID: timestamp * 10^(nodeIdDigits+5) + nodeId * 10^5 + sequence
            idValue = timestampBig * powerFactor +
                nodeIdBig * sequenceFactor +
                sequenceBig;
          } else {
            // Simplified algorithm: timestamp * 10^5 + sequence
            idValue = timestampBig * sequenceFactor + sequenceBig;
          }

          numericIds.add(idValue);
        }
      } else {
        // Regular generation method: consider step and sequence number limit
        int step = 1;
        if (!request.isHighGeneration) {
          // Calculate average step
          step = maxSequence ~/ max(request.count, 100);
        } else if (request.useNewTimestamp) {
          // If new timestamp is used, reset sequence number
          sequence = random.nextInt(1000) + 1;
        }

        // Generate ID
        for (int i = 0; i < request.count; i++) {
          // Increase sequence number
          sequence +=
              request.useRandomStep && step > 1 ? random.nextInt(step) + 1 : 1;

          // Check if sequence number exceeds limit
          if (sequence > maxSequence) {
            // Sequence number insufficient, wait for next timestamp
            workingValue = (DateTime.now().millisecondsSinceEpoch ~/ 1000) -
                epochStartSeconds;
            sequence = random.nextInt(1000) + 1;
          }

          // Calculate ID
          final BigInt timestampBig = BigInt.from(workingValue);
          final BigInt sequenceBig = BigInt.from(sequence);

          BigInt idValue;
          if (request.nodeConfig.enableDistributed) {
            // Algorithm with node ID
            idValue = timestampBig * powerFactor +
                nodeIdBig * sequenceFactor +
                sequenceBig;
          } else {
            // Simplified algorithm
            idValue = timestampBig * sequenceFactor + sequenceBig;
          }

          numericIds.add(idValue);
        }
      }
    } else if (request.keyType == PrimaryKeyType.datePrefixed) {
      // Date prefixed ID generation logic
      String dateString = workingValue as String;

      // Efficient generation strategy
      if (request.isHighGeneration && sequence + request.count <= maxSequence) {
        // Efficient batch generation method
        for (int i = 0; i < request.count; i++) {
          sequence += 1;

          // Calculate date prefixed ID
          BigInt dateValue;
          try {
            dateValue = BigInt.parse(dateString);
          } catch (e) {
            // Use timestamp as fallback
            dateValue = BigInt.from(
                (DateTime.now().millisecondsSinceEpoch ~/ 1000) % 10000000000);
          }

          final BigInt sequenceBig = BigInt.from(sequence);
          BigInt idValue;

          if (request.nodeConfig.enableDistributed) {
            // Algorithm with node ID
            idValue = dateValue * powerFactor +
                nodeIdBig * sequenceFactor +
                sequenceBig;
          } else {
            // Simplified algorithm
            idValue = dateValue * sequenceFactor + sequenceBig;
          }

          numericIds.add(idValue);
        }
      } else {
        // Regular generation method
        int step = 1;
        if (!request.isHighGeneration) {
          // Calculate average step
          step = maxSequence ~/ max(request.count, 100);
        } else if (request.useNewTimestamp) {
          // If new date is used, reset sequence number
          sequence = random.nextInt(1000) + 1;
        }

        // Generate ID
        for (int i = 0; i < request.count; i++) {
          // Increase sequence number
          sequence +=
              request.useRandomStep && step > 1 ? random.nextInt(step) + 1 : 1;

          // Check if sequence number exceeds limit
          if (sequence > maxSequence) {
            // Sequence number insufficient, use current date
            final now = DateTime.now();
            dateString = '${now.year}'
                '${now.month.toString().padLeft(2, '0')}'
                '${now.day.toString().padLeft(2, '0')}'
                '${now.hour.toString().padLeft(2, '0')}'
                '${now.minute.toString().padLeft(2, '0')}'
                '${now.second.toString().padLeft(2, '0')}';
            sequence = random.nextInt(1000) + 1;
          }

          // Calculate ID
          BigInt dateValue;
          try {
            dateValue = BigInt.parse(dateString);
          } catch (e) {
            // Use timestamp as fallback
            dateValue = BigInt.from(
                (DateTime.now().millisecondsSinceEpoch ~/ 1000) % 10000000000);
          }

          final BigInt sequenceBig = BigInt.from(sequence);
          BigInt idValue;

          if (request.nodeConfig.enableDistributed) {
            // Algorithm with node ID
            idValue = dateValue * powerFactor +
                nodeIdBig * sequenceFactor +
                sequenceBig;
          } else {
            // Simplified algorithm
            idValue = dateValue * sequenceFactor + sequenceBig;
          }

          numericIds.add(idValue);
        }
      }

      // Update current value
      currentValue = dateString;
    }

    // Format ID (based on ID type)
    if (request.keyType == PrimaryKeyType.shortCode) {
      // Short code ID needs Base62 encoding
      for (final numericId in numericIds) {
        result.add(_IsolateBase62Encoder.encode(numericId));
      }
    } else {
      // Timestamp ID and date prefixed ID directly converted to string
      for (final numericId in numericIds) {
        result.add(numericId.toString());
      }
    }

    // Return generation result
    return TimeBasedIdGenerateResult(
      ids: result,
      lastValue: currentValue,
      lastSequence: sequence,
      success: true,
    );
  } catch (e) {
    // Record error and return empty result
    return TimeBasedIdGenerateResult(
      ids: [],
      lastValue: request.startValue,
      lastSequence: request.startSequence,
      success: false,
      errorMessage: 'ID generation failed: $e',
    );
  }
}
