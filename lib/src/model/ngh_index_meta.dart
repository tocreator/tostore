import '../handler/common.dart';
import 'meta_info.dart';
import 'table_identity.dart';
import 'table_schema.dart';

// ============================================================================
// NGH Vector Index Metadata
// ============================================================================

/// Metadata for an NGH vector index instance.
///
class NghIndexMeta {
  /// Metadata format version for forward-compatibility.
  final int version;

  /// Stable index uid for NGH paths and caches.
  final IndexUid indexUid;

  /// Owning table unique identifier.
  final TableUid tableUid;

  /// Vector dimensionality (128--4096).
  final int dimensions;

  /// Distance metric used for similarity computation.
  final VectorDistanceMetric distanceMetric;

  /// Creation / last-modified timestamps.
  final Timestamps timestamps;

  // ===================== Runtime Statistics ====================

  /// Total number of live vectors (excluding tombstoned).
  final int totalVectors;

  /// Number of tombstoned (logically deleted) vectors.
  final int deletedCount;

  /// Next node ID to allocate (monotonically increasing).
  final int nextNodeId;

  // ===================== Partition Layout ======================

  /// Number of posting partition files.
  final int postingPartitionCount;

  /// Next page number in the active posting partition.
  final int postingNextPageNo;

  /// Posting partition free-list heads.
  final Map<int, int> postingFreeListHeads;

  /// Total size of all partition files in bytes (best-effort).
  final int totalSizeBytes;

  /// Whether this index is currently being built by a background migration task.
  final bool isBuilding;

  // ===================== Constructor ===========================

  NghIndexMeta({
    int? version,
    required this.indexUid,
    required this.tableUid,
    required this.dimensions,
    required this.distanceMetric,
    required this.timestamps,
    this.totalVectors = 0,
    this.deletedCount = 0,
    this.nextNodeId = 0,
    this.totalSizeBytes = 0,
    this.isBuilding = false,
    this.postingPartitionCount = 1,
    this.postingNextPageNo = firstDataPageNo,
    Map<int, int>? postingFreeListHeads,
  })  : version = version ?? InternalConfig.indexVersion,
        postingFreeListHeads = postingFreeListHeads ?? const {};

  // ===================== Defaults ==============================

  /// First data page number (pageNo=0 reserved for per-file meta).
  static const int firstDataPageNo = 1;

  // ===================== Factory ===============================

  /// Create an initial empty [NghIndexMeta] with sane defaults.
  static NghIndexMeta createEmpty({
    required IndexUid indexUid,
    required TableUid tableUid,
    required int dimensions,
    VectorDistanceMetric distanceMetric = VectorDistanceMetric.cosine,
    DateTime? now,
    bool isBuilding = false,
  }) {
    final ts = now ?? DateTime.now();
    return NghIndexMeta(
      indexUid: indexUid,
      tableUid: tableUid,
      dimensions: dimensions,
      distanceMetric: distanceMetric,
      timestamps: Timestamps(created: ts, modified: ts),
      isBuilding: isBuilding,
    );
  }

  // ===================== copyWith ==============================

  NghIndexMeta copyWith({
    int? version,
    IndexUid? indexUid,
    TableUid? tableUid,
    int? dimensions,
    VectorDistanceMetric? distanceMetric,
    Timestamps? timestamps,
    int? totalVectors,
    int? deletedCount,
    int? nextNodeId,
    int? totalSizeBytes,
    bool? isBuilding,
    int? postingPartitionCount,
    int? postingNextPageNo,
    Map<int, int>? postingFreeListHeads,
  }) {
    return NghIndexMeta(
      version: version ?? this.version,
      indexUid: indexUid ?? this.indexUid,
      tableUid: tableUid ?? this.tableUid,
      dimensions: dimensions ?? this.dimensions,
      distanceMetric: distanceMetric ?? this.distanceMetric,
      timestamps: timestamps ?? this.timestamps,
      totalVectors: totalVectors ?? this.totalVectors,
      deletedCount: deletedCount ?? this.deletedCount,
      nextNodeId: nextNodeId ?? this.nextNodeId,
      totalSizeBytes: totalSizeBytes ?? this.totalSizeBytes,
      isBuilding: isBuilding ?? this.isBuilding,
      postingPartitionCount:
          postingPartitionCount ?? this.postingPartitionCount,
      postingNextPageNo: postingNextPageNo ?? this.postingNextPageNo,
      postingFreeListHeads: postingFreeListHeads ?? this.postingFreeListHeads,
    );
  }

  // ===================== Serialization =========================

  factory NghIndexMeta.fromJson(Map<String, dynamic> json) {
    return NghIndexMeta(
      version: (json['version'] as num?)?.toInt(),
      indexUid:
          IndexUid.tryParse(json['indexUid'] as String?) ?? IndexUid.empty,
      tableUid: TableUid((json['tableUid'] ?? json['tableName']) as String),
      dimensions: (json['dimensions'] as num).toInt(),
      distanceMetric: _parseDistanceMetric(json['distanceMetric'] as String?),
      timestamps:
          Timestamps.fromJson(json['timestamps'] as Map<String, dynamic>),
      totalVectors: (json['totalVectors'] as num?)?.toInt() ?? 0,
      deletedCount: (json['deletedCount'] as num?)?.toInt() ?? 0,
      nextNodeId: (json['nextNodeId'] as num?)?.toInt() ?? 0,
      totalSizeBytes:
          ((json['totalSizeBytes'] ?? json['totalSizeInBytes']) as num?)
                  ?.toInt() ??
              0,
      isBuilding: (json['isBuilding'] as bool?) ?? false,
      postingPartitionCount:
          (json['postingPartitionCount'] as num?)?.toInt() ?? 1,
      postingNextPageNo:
          (json['postingNextPageNo'] as num?)?.toInt() ?? firstDataPageNo,
      postingFreeListHeads: _parseIntIntMap(json['postingFreeListHeads']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'indexUid': indexUid,
      'tableUid': tableUid,
      'dimensions': dimensions,
      'distanceMetric': distanceMetric.name,
      'timestamps': timestamps.toJson(),
      'totalVectors': totalVectors,
      'deletedCount': deletedCount,
      'nextNodeId': nextNodeId,
      'totalSizeBytes': totalSizeBytes,
      'isBuilding': isBuilding,
      'postingPartitionCount': postingPartitionCount,
      'postingNextPageNo': postingNextPageNo,
      'postingFreeListHeads': _serializeIntIntMap(postingFreeListHeads),
    };
  }

  // ===================== Private Helpers =======================

  static VectorDistanceMetric _parseDistanceMetric(String? s) {
    switch (s) {
      case 'l2':
        return VectorDistanceMetric.l2;
      case 'innerProduct':
        return VectorDistanceMetric.innerProduct;
      default:
        return VectorDistanceMetric.cosine;
    }
  }

  static Map<int, int> _parseIntIntMap(dynamic raw) {
    if (raw == null) return {};
    if (raw is Map) {
      return raw.map((k, v) =>
          MapEntry(k is int ? k : int.parse(k.toString()), (v as num).toInt()));
    }
    return {};
  }

  static Map<String, int> _serializeIntIntMap(Map<int, int> m) {
    return m.map((k, v) => MapEntry(k.toString(), v));
  }

  @override
  String toString() => 'NghIndexMeta(uid: $indexUid, table: $tableUid, '
      'dim: $dimensions, vectors: $totalVectors, '
      'deleted: $deletedCount, postingPartitions: $postingPartitionCount)';
}
