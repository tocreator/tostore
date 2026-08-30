import '../handler/common.dart';
import 'meta_info.dart';
import 'table_identity.dart';
import 'table_schema.dart';

// ============================================================================
// NGH (Node-Graph Hybrid) Vector Index Metadata
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

  /// Storage precision for raw vectors.
  final VectorPrecision precision;

  /// Creation / last-modified timestamps.
  final Timestamps timestamps;

  // ===================== Graph Parameters =====================

  /// Maximum out-degree per graph node (R).
  final int maxDegree;

  /// Search expansion factor (ef_search).
  final int efSearch;

  /// Expansion factor for construction (ef_construction).
  final int constructionEf;

  /// Diversity parameter for Robust Prune (alpha >= 1.0).
  final double pruneAlpha;

  // ===================== Runtime Statistics ====================

  /// Total number of live vectors (excluding tombstoned).
  final int totalVectors;

  /// Number of tombstoned (logically deleted) vectors.
  final int deletedCount;

  /// Entry-point node for greedy search (medoid of the dataset).
  final int medoidNodeId;

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

  /// Number of centroids currently in the navigating graph.
  final int centroidCount;

  // ===================== Constructor ===========================

  NghIndexMeta({
    int? version,
    required this.indexUid,
    required this.tableUid,
    required this.dimensions,
    required this.distanceMetric,
    required this.precision,
    required this.timestamps,
    this.maxDegree = 64,
    this.efSearch = 64,
    this.constructionEf = 128,
    this.pruneAlpha = 1.2,
    this.totalVectors = 0,
    this.deletedCount = 0,
    this.medoidNodeId = -1,
    this.nextNodeId = 0,
    this.totalSizeBytes = 0,
    this.isBuilding = false,
    this.centroidCount = 0,
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
    VectorPrecision precision = VectorPrecision.float32,
    int? maxDegree,
    int? efSearch,
    int? constructionEf,
    double? pruneAlpha,
    DateTime? now,
    bool isBuilding = false,
  }) {
    final ts = now ?? DateTime.now();
    return NghIndexMeta(
      indexUid: indexUid,
      tableUid: tableUid,
      dimensions: dimensions,
      distanceMetric: distanceMetric,
      precision: precision,
      timestamps: Timestamps(created: ts, modified: ts),
      maxDegree: maxDegree ?? 64,
      efSearch: efSearch ?? 64,
      constructionEf: constructionEf ?? 128,
      pruneAlpha: pruneAlpha ?? 1.2,
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
    VectorPrecision? precision,
    Timestamps? timestamps,
    int? maxDegree,
    int? efSearch,
    int? constructionEf,
    double? pruneAlpha,
    int? totalVectors,
    int? deletedCount,
    int? medoidNodeId,
    int? nextNodeId,
    int? totalSizeBytes,
    bool? isBuilding,
    int? centroidCount,
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
      precision: precision ?? this.precision,
      timestamps: timestamps ?? this.timestamps,
      maxDegree: maxDegree ?? this.maxDegree,
      efSearch: efSearch ?? this.efSearch,
      constructionEf: constructionEf ?? this.constructionEf,
      pruneAlpha: pruneAlpha ?? this.pruneAlpha,
      totalVectors: totalVectors ?? this.totalVectors,
      deletedCount: deletedCount ?? this.deletedCount,
      medoidNodeId: medoidNodeId ?? this.medoidNodeId,
      nextNodeId: nextNodeId ?? this.nextNodeId,
      totalSizeBytes: totalSizeBytes ?? this.totalSizeBytes,
      isBuilding: isBuilding ?? this.isBuilding,
      centroidCount: centroidCount ?? this.centroidCount,
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
      precision: _parsePrecision(json['precision'] as String?),
      timestamps:
          Timestamps.fromJson(json['timestamps'] as Map<String, dynamic>),
      maxDegree: (json['maxDegree'] as num?)?.toInt() ?? 64,
      efSearch: (json['efSearch'] as num?)?.toInt() ?? 64,
      constructionEf: (json['constructionEf'] as num?)?.toInt() ?? 128,
      pruneAlpha: (json['pruneAlpha'] as num?)?.toDouble() ?? 1.2,
      totalVectors: (json['totalVectors'] as num?)?.toInt() ?? 0,
      deletedCount: (json['deletedCount'] as num?)?.toInt() ?? 0,
      medoidNodeId: (json['medoidNodeId'] as num?)?.toInt() ?? -1,
      nextNodeId: (json['nextNodeId'] as num?)?.toInt() ?? 0,
      totalSizeBytes:
          ((json['totalSizeBytes'] ?? json['totalSizeInBytes']) as num?)
                  ?.toInt() ??
              0,
      isBuilding: (json['isBuilding'] as bool?) ?? false,
      centroidCount: (json['centroidCount'] as num?)?.toInt() ?? 0,
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
      'precision': precision.name,
      'timestamps': timestamps.toJson(),
      'maxDegree': maxDegree,
      'efSearch': efSearch,
      'constructionEf': constructionEf,
      'pruneAlpha': pruneAlpha,
      'totalVectors': totalVectors,
      'deletedCount': deletedCount,
      'medoidNodeId': medoidNodeId,
      'nextNodeId': nextNodeId,
      'totalSizeBytes': totalSizeBytes,
      'isBuilding': isBuilding,
      'centroidCount': centroidCount,
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

  static VectorPrecision _parsePrecision(String? s) {
    switch (s) {
      case 'float64':
        return VectorPrecision.float64;
      case 'int8':
        return VectorPrecision.int8;
      default:
        return VectorPrecision.float32;
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
      'deleted: $deletedCount, postingPartitions: $postingPartitionCount, '
      'centroids: $centroidCount, medoid: $medoidNodeId)';
}
