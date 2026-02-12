import '../handler/common.dart';
import '../core/ngh_page.dart';
import 'meta_info.dart';
import 'table_schema.dart';

// ============================================================================
// NGH (Node-Graph Hybrid) Vector Index Metadata
// ============================================================================

/// Metadata for an NGH vector index instance.
///
/// Tracks all structural parameters, page layout constants, and runtime
/// statistics for a single vector index. Persisted as JSON alongside the
/// index partition files and rebuilt/updated atomically during flush.
class NghIndexMeta {
  /// Metadata format version for forward-compatibility.
  final int version;

  /// Index name (matches [IndexSchema.actualIndexName]).
  final String name;

  /// Owning table name.
  final String tableName;

  /// The vector field this index covers.
  final String fieldName;

  /// Vector dimensionality (128–4096).
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

  /// Diversity parameter for Robust Prune (α ≥ 1.0).
  final double pruneAlpha;

  // ===================== PQ Parameters ========================

  /// Number of PQ sub-spaces (M). Each sub-vector is quantised independently.
  final int pqSubspaces;

  /// Centroids per sub-space (K). Fixed at 256 → 1 byte per sub-code.
  final int pqCentroids;

  /// Whether the PQ codebook has been trained.
  final bool pqTrained;

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

  /// Page size in bytes for all NGH page types.
  final int nghPageSize;

  /// Number of graph partition files.
  final int graphPartitionCount;

  /// Next page number in the active graph partition.
  final int graphNextPageNo;

  /// Number of PQ-code partition files.
  final int pqCodePartitionCount;

  /// Next page number in the active PQ-code partition.
  final int pqCodeNextPageNo;

  /// Number of raw-vector partition files.
  final int rawVectorPartitionCount;

  /// Next page number in the active raw-vector partition.
  final int rawVectorNextPageNo;

  /// Total size of all partition files in bytes (best-effort).
  final int totalSizeInBytes;

  // ===================== nodeId ↔ PK B+Tree Mapping ============

  /// B+Tree index meta for nodeId → PK forward lookup.
  /// Stored as a standard B+Tree index under virtual name `{name}__nid2pk`.
  final IndexMeta? nodeIdToPkMeta;

  /// B+Tree index meta for PK → nodeId reverse lookup.
  /// Stored as a standard B+Tree index under virtual name `{name}__pk2nid`.
  final IndexMeta? pkToNodeIdMeta;

  /// Virtual index name for forward mapping B+Tree.
  String get nid2pkIndexName => '${name}__nid2pk';

  /// Virtual index name for reverse mapping B+Tree.
  String get pk2nidIndexName => '${name}__pk2nid';

  // ===================== Free-List State ======================

  /// Graph partition free-list heads (partitionNo → headPageNo, -1 = empty).
  final Map<int, int> graphFreeListHeads;

  /// PQ-code partition free-list heads.
  final Map<int, int> pqCodeFreeListHeads;

  /// Raw-vector partition free-list heads.
  final Map<int, int> rawVectorFreeListHeads;

  // ===================== Derived Constants ====================
  // Computed once from (dimensions, maxDegree, pqSubspaces, nghPageSize).

  /// Bytes per graph node slot: 1(flags) + 1(degree) + maxDegree*4(neighbors).
  int get graphNodeSlotSize => 2 + maxDegree * 4;

  /// Number of node slots that fit in one graph page.
  int get nodesPerGraphPage =>
      NghPageSizer.nodesPerGraphPage(nghPageSize, maxDegree);

  /// Bytes per PQ code entry.
  int get pqCodeEntrySize => pqSubspaces;

  /// Number of PQ entries that fit in one PQ-code page.
  int get vectorsPerPqPage =>
      NghPageSizer.vectorsPerPqPage(nghPageSize, pqSubspaces);

  /// Bytes per raw vector: dimensions × bytesPerElement.
  int get rawVectorEntrySize => dimensions * _bytesPerElement;

  /// Number of raw vectors that fit in one raw-vector page.
  int get vectorsPerRawPage =>
      NghPageSizer.vectorsPerRawPage(nghPageSize, dimensions, _bytesPerElement);

  /// Maximum logical graph pages per partition file.
  int get graphPagesPerPartition => _maxPagesPerPartitionFile;

  /// Maximum logical PQ-code pages per partition file.
  int get pqCodePagesPerPartition => _maxPagesPerPartitionFile;

  /// Maximum logical raw-vector pages per partition file.
  int get rawVectorPagesPerPartition => _maxPagesPerPartitionFile;

  // ===================== Private Helpers =======================

  int get _bytesPerElement {
    switch (precision) {
      case VectorPrecision.float32:
        return 4;
      case VectorPrecision.float64:
        return 8;
      case VectorPrecision.int8:
        return 1;
    }
  }

  int get _maxPagesPerPartitionFile => _maxPartitionFileSize ~/ nghPageSize;

  /// Placeholder — the actual limit is injected from [DataStoreConfig].
  /// We store a snapshot so the meta is self-contained.
  final int _maxPartitionFileSize;

  // ===================== Constructor ===========================

  NghIndexMeta({
    int? version,
    required this.name,
    required this.tableName,
    required this.fieldName,
    required this.dimensions,
    required this.distanceMetric,
    required this.precision,
    required this.timestamps,
    this.maxDegree = 64,
    this.efSearch = 64,
    this.constructionEf = 128,
    this.pruneAlpha = 1.2,
    this.pqSubspaces = 16,
    this.pqCentroids = 256,
    this.pqTrained = false,
    this.totalVectors = 0,
    this.deletedCount = 0,
    this.medoidNodeId = -1,
    this.nextNodeId = 0,
    this.nghPageSize = defaultPageSize,
    this.graphPartitionCount = 1,
    this.graphNextPageNo = firstDataPageNo,
    this.pqCodePartitionCount = 1,
    this.pqCodeNextPageNo = firstDataPageNo,
    this.rawVectorPartitionCount = 1,
    this.rawVectorNextPageNo = firstDataPageNo,
    this.totalSizeInBytes = 0,
    this.nodeIdToPkMeta,
    this.pkToNodeIdMeta,
    Map<int, int>? graphFreeListHeads,
    Map<int, int>? pqCodeFreeListHeads,
    Map<int, int>? rawVectorFreeListHeads,
    int maxPartitionFileSize = 16 * 1024 * 1024,
  })  : version = version ?? InternalConfig.indexVersion,
        graphFreeListHeads = graphFreeListHeads ?? const {},
        pqCodeFreeListHeads = pqCodeFreeListHeads ?? const {},
        rawVectorFreeListHeads = rawVectorFreeListHeads ?? const {},
        _maxPartitionFileSize = maxPartitionFileSize;

  // ===================== Defaults ==============================

  /// Default page size for NGH pages (16 KB).
  static const int defaultPageSize = 16 * 1024;

  /// First data page number (pageNo=0 reserved for per-file meta).
  static const int firstDataPageNo = 1;

  /// Auto-select PQ sub-spaces from vector dimensionality.
  ///
  /// Keeps each sub-vector at 8 dimensions when possible, clamped to [8, 128].
  static int autoPqSubspaces(int dimensions) {
    final m = dimensions ~/ 8;
    return m.clamp(8, 128);
  }

  // ===================== Factory ===============================

  /// Create an initial empty [NghIndexMeta] with sane defaults.
  static NghIndexMeta createEmpty({
    required String name,
    required String tableName,
    required String fieldName,
    required int dimensions,
    VectorDistanceMetric distanceMetric = VectorDistanceMetric.cosine,
    VectorPrecision precision = VectorPrecision.float32,
    int? maxDegree,
    int? efSearch,
    int? constructionEf,
    double? pruneAlpha,
    int? pqSubspaces,
    int pageSize = defaultPageSize,
    int maxPartitionFileSize = 16 * 1024 * 1024,
    DateTime? now,
  }) {
    final ts = now ?? DateTime.now();
    final m = pqSubspaces ?? autoPqSubspaces(dimensions);
    return NghIndexMeta(
      name: name,
      tableName: tableName,
      fieldName: fieldName,
      dimensions: dimensions,
      distanceMetric: distanceMetric,
      precision: precision,
      timestamps: Timestamps(created: ts, modified: ts),
      maxDegree: maxDegree ?? 64,
      efSearch: efSearch ?? 64,
      constructionEf: constructionEf ?? 128,
      pruneAlpha: pruneAlpha ?? 1.2,
      pqSubspaces: m,
      nghPageSize: pageSize,
      maxPartitionFileSize: maxPartitionFileSize,
    );
  }

  // ===================== copyWith ==============================

  NghIndexMeta copyWith({
    int? version,
    String? name,
    String? tableName,
    String? fieldName,
    int? dimensions,
    VectorDistanceMetric? distanceMetric,
    VectorPrecision? precision,
    Timestamps? timestamps,
    int? maxDegree,
    int? efSearch,
    int? constructionEf,
    double? pruneAlpha,
    int? pqSubspaces,
    int? pqCentroids,
    bool? pqTrained,
    int? totalVectors,
    int? deletedCount,
    int? medoidNodeId,
    int? nextNodeId,
    int? nghPageSize,
    int? graphPartitionCount,
    int? graphNextPageNo,
    int? pqCodePartitionCount,
    int? pqCodeNextPageNo,
    int? rawVectorPartitionCount,
    int? rawVectorNextPageNo,
    int? totalSizeInBytes,
    IndexMeta? nodeIdToPkMeta,
    IndexMeta? pkToNodeIdMeta,
    Map<int, int>? graphFreeListHeads,
    Map<int, int>? pqCodeFreeListHeads,
    Map<int, int>? rawVectorFreeListHeads,
    int? maxPartitionFileSize,
  }) {
    return NghIndexMeta(
      version: version ?? this.version,
      name: name ?? this.name,
      tableName: tableName ?? this.tableName,
      fieldName: fieldName ?? this.fieldName,
      dimensions: dimensions ?? this.dimensions,
      distanceMetric: distanceMetric ?? this.distanceMetric,
      precision: precision ?? this.precision,
      timestamps: timestamps ?? this.timestamps,
      maxDegree: maxDegree ?? this.maxDegree,
      efSearch: efSearch ?? this.efSearch,
      constructionEf: constructionEf ?? this.constructionEf,
      pruneAlpha: pruneAlpha ?? this.pruneAlpha,
      pqSubspaces: pqSubspaces ?? this.pqSubspaces,
      pqCentroids: pqCentroids ?? this.pqCentroids,
      pqTrained: pqTrained ?? this.pqTrained,
      totalVectors: totalVectors ?? this.totalVectors,
      deletedCount: deletedCount ?? this.deletedCount,
      medoidNodeId: medoidNodeId ?? this.medoidNodeId,
      nextNodeId: nextNodeId ?? this.nextNodeId,
      nghPageSize: nghPageSize ?? this.nghPageSize,
      graphPartitionCount: graphPartitionCount ?? this.graphPartitionCount,
      graphNextPageNo: graphNextPageNo ?? this.graphNextPageNo,
      pqCodePartitionCount: pqCodePartitionCount ?? this.pqCodePartitionCount,
      pqCodeNextPageNo: pqCodeNextPageNo ?? this.pqCodeNextPageNo,
      rawVectorPartitionCount:
          rawVectorPartitionCount ?? this.rawVectorPartitionCount,
      rawVectorNextPageNo: rawVectorNextPageNo ?? this.rawVectorNextPageNo,
      totalSizeInBytes: totalSizeInBytes ?? this.totalSizeInBytes,
      nodeIdToPkMeta: nodeIdToPkMeta ?? this.nodeIdToPkMeta,
      pkToNodeIdMeta: pkToNodeIdMeta ?? this.pkToNodeIdMeta,
      graphFreeListHeads: graphFreeListHeads ?? this.graphFreeListHeads,
      pqCodeFreeListHeads: pqCodeFreeListHeads ?? this.pqCodeFreeListHeads,
      rawVectorFreeListHeads:
          rawVectorFreeListHeads ?? this.rawVectorFreeListHeads,
      maxPartitionFileSize: maxPartitionFileSize ?? _maxPartitionFileSize,
    );
  }

  // ===================== Serialization =========================

  factory NghIndexMeta.fromJson(Map<String, dynamic> json) {
    return NghIndexMeta(
      version: (json['version'] as num?)?.toInt(),
      name: json['name'] as String,
      tableName: json['tableName'] as String,
      fieldName: json['fieldName'] as String,
      dimensions: (json['dimensions'] as num).toInt(),
      distanceMetric: _parseDistanceMetric(json['distanceMetric'] as String?),
      precision: _parsePrecision(json['precision'] as String?),
      timestamps:
          Timestamps.fromJson(json['timestamps'] as Map<String, dynamic>),
      maxDegree: (json['maxDegree'] as num?)?.toInt() ?? 64,
      efSearch: (json['efSearch'] as num?)?.toInt() ?? 64,
      constructionEf: (json['constructionEf'] as num?)?.toInt() ?? 128,
      pruneAlpha: (json['pruneAlpha'] as num?)?.toDouble() ?? 1.2,
      pqSubspaces: (json['pqSubspaces'] as num?)?.toInt() ??
          NghIndexMeta.autoPqSubspaces((json['dimensions'] as num).toInt()),
      pqCentroids: (json['pqCentroids'] as num?)?.toInt() ?? 256,
      pqTrained: json['pqTrained'] as bool? ?? false,
      totalVectors: (json['totalVectors'] as num?)?.toInt() ?? 0,
      deletedCount: (json['deletedCount'] as num?)?.toInt() ?? 0,
      medoidNodeId: (json['medoidNodeId'] as num?)?.toInt() ?? -1,
      nextNodeId: (json['nextNodeId'] as num?)?.toInt() ?? 0,
      nghPageSize: (json['nghPageSize'] as num?)?.toInt() ??
          NghIndexMeta.defaultPageSize,
      graphPartitionCount: (json['graphPartitionCount'] as num?)?.toInt() ?? 1,
      graphNextPageNo:
          (json['graphNextPageNo'] as num?)?.toInt() ?? firstDataPageNo,
      pqCodePartitionCount:
          (json['pqCodePartitionCount'] as num?)?.toInt() ?? 1,
      pqCodeNextPageNo:
          (json['pqCodeNextPageNo'] as num?)?.toInt() ?? firstDataPageNo,
      rawVectorPartitionCount:
          (json['rawVectorPartitionCount'] as num?)?.toInt() ?? 1,
      rawVectorNextPageNo:
          (json['rawVectorNextPageNo'] as num?)?.toInt() ?? firstDataPageNo,
      totalSizeInBytes: (json['totalSizeInBytes'] as num?)?.toInt() ?? 0,
      nodeIdToPkMeta: json['nodeIdToPkMeta'] != null
          ? IndexMeta.fromJson(json['nodeIdToPkMeta'] as Map<String, dynamic>)
          : null,
      pkToNodeIdMeta: json['pkToNodeIdMeta'] != null
          ? IndexMeta.fromJson(json['pkToNodeIdMeta'] as Map<String, dynamic>)
          : null,
      graphFreeListHeads: _parseIntIntMap(json['graphFreeListHeads']),
      pqCodeFreeListHeads: _parseIntIntMap(json['pqCodeFreeListHeads']),
      rawVectorFreeListHeads: _parseIntIntMap(json['rawVectorFreeListHeads']),
      maxPartitionFileSize:
          (json['maxPartitionFileSize'] as num?)?.toInt() ?? 16 * 1024 * 1024,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'name': name,
      'tableName': tableName,
      'fieldName': fieldName,
      'dimensions': dimensions,
      'distanceMetric': distanceMetric.name,
      'precision': precision.name,
      'timestamps': timestamps.toJson(),
      'maxDegree': maxDegree,
      'efSearch': efSearch,
      'constructionEf': constructionEf,
      'pruneAlpha': pruneAlpha,
      'pqSubspaces': pqSubspaces,
      'pqCentroids': pqCentroids,
      'pqTrained': pqTrained,
      'totalVectors': totalVectors,
      'deletedCount': deletedCount,
      'medoidNodeId': medoidNodeId,
      'nextNodeId': nextNodeId,
      'nghPageSize': nghPageSize,
      'graphPartitionCount': graphPartitionCount,
      'graphNextPageNo': graphNextPageNo,
      'pqCodePartitionCount': pqCodePartitionCount,
      'pqCodeNextPageNo': pqCodeNextPageNo,
      'rawVectorPartitionCount': rawVectorPartitionCount,
      'rawVectorNextPageNo': rawVectorNextPageNo,
      'totalSizeInBytes': totalSizeInBytes,
      if (nodeIdToPkMeta != null) 'nodeIdToPkMeta': nodeIdToPkMeta!.toJson(),
      if (pkToNodeIdMeta != null) 'pkToNodeIdMeta': pkToNodeIdMeta!.toJson(),
      'graphFreeListHeads': _serializeIntIntMap(graphFreeListHeads),
      'pqCodeFreeListHeads': _serializeIntIntMap(pqCodeFreeListHeads),
      'rawVectorFreeListHeads': _serializeIntIntMap(rawVectorFreeListHeads),
      'maxPartitionFileSize': _maxPartitionFileSize,
    };
  }

  // ===================== Node → Page Mapping ===================

  /// Compute the graph partition file number for a given [nodeId].
  int graphPartitionForNode(int nodeId) {
    final logicalPage = nodeId ~/ nodesPerGraphPage;
    return logicalPage ~/ graphPagesPerPartition;
  }

  /// Compute the local page number within its graph partition for [nodeId].
  int graphLocalPageForNode(int nodeId) {
    final logicalPage = nodeId ~/ nodesPerGraphPage;
    // +1 because pageNo=0 is meta page in each partition file
    return firstDataPageNo + (logicalPage % graphPagesPerPartition);
  }

  /// Compute the slot index within its graph page for [nodeId].
  int graphSlotForNode(int nodeId) => nodeId % nodesPerGraphPage;

  /// Compute the PQ-code partition and local page for [nodeId].
  int pqPartitionForNode(int nodeId) {
    final logicalPage = nodeId ~/ vectorsPerPqPage;
    return logicalPage ~/ pqCodePagesPerPartition;
  }

  int pqLocalPageForNode(int nodeId) {
    final logicalPage = nodeId ~/ vectorsPerPqPage;
    return firstDataPageNo + (logicalPage % pqCodePagesPerPartition);
  }

  int pqSlotForNode(int nodeId) => nodeId % vectorsPerPqPage;

  /// Compute the raw-vector partition and local page for [nodeId].
  int rawVectorPartitionForNode(int nodeId) {
    final logicalPage = nodeId ~/ vectorsPerRawPage;
    return logicalPage ~/ rawVectorPagesPerPartition;
  }

  int rawVectorLocalPageForNode(int nodeId) {
    final logicalPage = nodeId ~/ vectorsPerRawPage;
    return firstDataPageNo + (logicalPage % rawVectorPagesPerPartition);
  }

  int rawVectorSlotForNode(int nodeId) => nodeId % vectorsPerRawPage;

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
  String toString() =>
      'NghIndexMeta(name: $name, table: $tableName, field: $fieldName, '
      'dim: $dimensions, vectors: $totalVectors, deleted: $deletedCount, '
      'graphPartitions: $graphPartitionCount, '
      'pqTrained: $pqTrained, medoid: $medoidNodeId)';
}
