/// store index
class StoreIndex {
  final int offset; // Record offset within partition
  final int partitionId; // Partition identifier

  // Distributed location identifiers (optional fields)
  final int? clusterId; // Cluster identifier
  final int? nodeId; // Node identifier

  const StoreIndex({
    required this.offset,
    required this.partitionId,
    this.clusterId,
    this.nodeId,
  });

  /// create from string
  static StoreIndex? fromString(String value) {
    final parts = value.split(':');
    if (parts.length < 2) {
      return null; // return null instead of throwing an exception, to improve robustness
    }

    try {
      // compatible with old format (offset:size:partitionId)
      if (parts.length == 3) {
        return StoreIndex(
          offset: int.parse(parts[0]),
          // size field is ignored (parts[1])
          partitionId: int.parse(parts[2]),
          clusterId: parts.length > 3 ? int.parse(parts[3]) : null,
          nodeId: parts.length > 4 ? int.parse(parts[4]) : null,
        );
      }
      // new format (offset:partitionId) or (offset:partitionId:clusterId:nodeId)
      else {
        return StoreIndex(
          offset: int.parse(parts[0]),
          partitionId: int.parse(parts[1]),
          clusterId: parts.length > 2 ? int.parse(parts[2]) : null,
          nodeId: parts.length > 3 ? int.parse(parts[3]) : null,
        );
      }
    } catch (e) {
      return null; // parse error, return null
    }
  }

  /// convert to string
  @override
  String toString() {
    final base = '$offset:$partitionId';

    if (clusterId != null && nodeId != null) {
      return '$base:$clusterId:$nodeId';
    }

    return base;
  }

  /// create new record store index
  static Future<StoreIndex> create({
    required int offset,
    required int partitionId,
    int? clusterId,
    int? nodeId,
  }) async {
    return StoreIndex(
      offset: offset,
      partitionId: partitionId,
      clusterId: clusterId,
      nodeId: nodeId,
    );
  }
}
