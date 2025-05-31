/// store index
class StoreIndex {
  final int offset; // Record offset within partition
  final int size; // Record size
  final int partitionId; // Partition identifier

  // Distributed location identifiers (optional fields)
  final int? clusterId; // Cluster identifier
  final int? nodeId; // Node identifier

  const StoreIndex({
    required this.offset,
    required this.size,
    required this.partitionId,
    this.clusterId,
    this.nodeId,
  });

  /// create from string
  factory StoreIndex.fromString(String value) {
    final parts = value.split(':');
    if (parts.length < 2) {
      throw ArgumentError('Invalid StoreIndex string format');
    }

    return StoreIndex(
      offset: int.parse(parts[0]),
      size: int.parse(parts[1]),
      partitionId: parts.length > 2 ? int.parse(parts[2]) : 0,
      clusterId: parts.length > 3 ? int.parse(parts[3]) : null,
      nodeId: parts.length > 5 ? int.parse(parts[5]) : null,
    );
  }

  /// convert to string
  @override
  String toString() {
    final base = '$offset:$size:$partitionId';

    if (clusterId != null && nodeId != null) {
      return '$base:$clusterId:$nodeId';
    }

    return base;
  }

  /// create new record store index
  static Future<StoreIndex> create(
    String content,
    int offset, {
    int partitionId = 0,
    int? clusterId,
    int? nodeId,
  }) async {
    return StoreIndex(
      offset: offset,
      size: content.length,
      partitionId: partitionId,
      clusterId: clusterId,
      nodeId: nodeId,
    );
  }
}
