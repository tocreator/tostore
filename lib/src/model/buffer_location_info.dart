import '../model/buffer_entry.dart';

/// Stores the location of a record within the in-memory buffers.
class BufferLocationInfo {
  /// The type of operation buffer (insert, update, delete).
  final BufferOperationType operationType;

  /// The partition index within the specific operation buffer.
  final int partitionIndex;

  BufferLocationInfo({
    required this.operationType,
    required this.partitionIndex,
  });
}
