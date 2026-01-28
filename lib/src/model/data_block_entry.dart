import 'dart:typed_data';

/// A compact key-value delta entry used for index/table persistence batches.
///
/// - [key]   : MemComparableKey encoded bytes (order-preserving).
/// - [value] : Engine-specific value bytes. The first byte is typically a flag:
///             0 = put/upsert, 1 = delete/tombstone.
final class DataBlockEntry {
  final Uint8List key;
  final Uint8List value;
  const DataBlockEntry(this.key, this.value);
}
