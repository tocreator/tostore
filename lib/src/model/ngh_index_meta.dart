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
  /// Metadata format version for forward-compatibility (shared indexVersion).
  final int version;

  /// On-disk NGH layout. 1 = leftover nav_graph.ngh (read-only after engine v4); 2 = paged nav/pdir/pkmap (the only write path).
  final int layoutVersion;

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

  /// Number of centroid nodes in the navigating graph.
  final int centroidCount;

  // ===================== Partition Layout ======================

  /// Number of posting partition files.
  final int postingPartitionCount;

  /// Next page number in the active posting partition.
  final int postingNextPageNo;

  /// Posting partition free-list heads.
  final Map<int, int> postingFreeListHeads;

  final int navPartitionCount;
  final int navNextPageNo;
  final Map<int, int> navFreeListHeads;

  final int pdirPartitionCount;
  final int pdirNextPageNo;
  final Map<int, int> pdirFreeListHeads;

  final int pkmapPartitionCount;
  final int pkmapNextPageNo;
  final Map<int, int> pkmapFreeListHeads;
  final int pkmapRootPartition;
  final int pkmapRootPage;
  final int pkmapHeight;

  /// True when every live posting slot has a PK locator (new indexes start true).
  final bool hasPkLocator;

  /// Backfill cursor (posting partition / page). Page 0 is meta.
  final int pkBackfillPartition;
  final int pkBackfillPage;

  /// Total size of all partition files in bytes (best-effort).
  final int totalSizeBytes;

  /// Whether this index is currently being built by a background migration task.
  final bool isBuilding;

  // ===================== Constructor ===========================

  NghIndexMeta({
    int? version,
    this.layoutVersion = layoutLegacy,
    required this.indexUid,
    required this.tableUid,
    required this.dimensions,
    required this.distanceMetric,
    required this.timestamps,
    this.totalVectors = 0,
    this.deletedCount = 0,
    this.nextNodeId = 0,
    this.centroidCount = 0,
    this.totalSizeBytes = 0,
    this.isBuilding = false,
    this.postingPartitionCount = 1,
    this.postingNextPageNo = firstDataPageNo,
    Map<int, int>? postingFreeListHeads,
    this.navPartitionCount = 1,
    this.navNextPageNo = firstDataPageNo,
    Map<int, int>? navFreeListHeads,
    this.pdirPartitionCount = 1,
    this.pdirNextPageNo = firstDataPageNo,
    Map<int, int>? pdirFreeListHeads,
    this.pkmapPartitionCount = 1,
    this.pkmapNextPageNo = firstDataPageNo,
    Map<int, int>? pkmapFreeListHeads,
    this.pkmapRootPartition = -1,
    this.pkmapRootPage = -1,
    this.pkmapHeight = 0,
    this.hasPkLocator = false,
    this.pkBackfillPartition = 0,
    this.pkBackfillPage = 0,
  })  : version = version ?? InternalConfig.indexVersion,
        postingFreeListHeads = postingFreeListHeads ?? const {},
        navFreeListHeads = navFreeListHeads ?? const {},
        pdirFreeListHeads = pdirFreeListHeads ?? const {},
        pkmapFreeListHeads = pkmapFreeListHeads ?? const {};

  // ===================== Defaults ==============================

  /// First data page number (pageNo=0 reserved for per-file meta).
  static const int firstDataPageNo = 1;

  /// Legacy whole-file `nav_graph.ngh`.
  static const int layoutLegacy = 1;

  /// Paged nav + posting directory + PK map sidecars.
  static const int layoutPaged = 2;

  bool get isPagedLayout => layoutVersion >= layoutPaged;

  bool get pkmapRootIsNull => pkmapRootPartition < 0 || pkmapRootPage <= 0;

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
      layoutVersion: layoutPaged,
      indexUid: indexUid,
      tableUid: tableUid,
      dimensions: dimensions,
      distanceMetric: distanceMetric,
      timestamps: Timestamps(created: ts, modified: ts),
      isBuilding: isBuilding,
      hasPkLocator: true,
    );
  }

  // ===================== copyWith ==============================

  NghIndexMeta copyWith({
    int? version,
    int? layoutVersion,
    IndexUid? indexUid,
    TableUid? tableUid,
    int? dimensions,
    VectorDistanceMetric? distanceMetric,
    Timestamps? timestamps,
    int? totalVectors,
    int? deletedCount,
    int? nextNodeId,
    int? centroidCount,
    int? totalSizeBytes,
    bool? isBuilding,
    int? postingPartitionCount,
    int? postingNextPageNo,
    Map<int, int>? postingFreeListHeads,
    int? navPartitionCount,
    int? navNextPageNo,
    Map<int, int>? navFreeListHeads,
    int? pdirPartitionCount,
    int? pdirNextPageNo,
    Map<int, int>? pdirFreeListHeads,
    int? pkmapPartitionCount,
    int? pkmapNextPageNo,
    Map<int, int>? pkmapFreeListHeads,
    int? pkmapRootPartition,
    int? pkmapRootPage,
    int? pkmapHeight,
    bool? hasPkLocator,
    int? pkBackfillPartition,
    int? pkBackfillPage,
  }) {
    return NghIndexMeta(
      version: version ?? this.version,
      layoutVersion: layoutVersion ?? this.layoutVersion,
      indexUid: indexUid ?? this.indexUid,
      tableUid: tableUid ?? this.tableUid,
      dimensions: dimensions ?? this.dimensions,
      distanceMetric: distanceMetric ?? this.distanceMetric,
      timestamps: timestamps ?? this.timestamps,
      totalVectors: totalVectors ?? this.totalVectors,
      deletedCount: deletedCount ?? this.deletedCount,
      nextNodeId: nextNodeId ?? this.nextNodeId,
      centroidCount: centroidCount ?? this.centroidCount,
      totalSizeBytes: totalSizeBytes ?? this.totalSizeBytes,
      isBuilding: isBuilding ?? this.isBuilding,
      postingPartitionCount:
          postingPartitionCount ?? this.postingPartitionCount,
      postingNextPageNo: postingNextPageNo ?? this.postingNextPageNo,
      postingFreeListHeads: postingFreeListHeads ?? this.postingFreeListHeads,
      navPartitionCount: navPartitionCount ?? this.navPartitionCount,
      navNextPageNo: navNextPageNo ?? this.navNextPageNo,
      navFreeListHeads: navFreeListHeads ?? this.navFreeListHeads,
      pdirPartitionCount: pdirPartitionCount ?? this.pdirPartitionCount,
      pdirNextPageNo: pdirNextPageNo ?? this.pdirNextPageNo,
      pdirFreeListHeads: pdirFreeListHeads ?? this.pdirFreeListHeads,
      pkmapPartitionCount: pkmapPartitionCount ?? this.pkmapPartitionCount,
      pkmapNextPageNo: pkmapNextPageNo ?? this.pkmapNextPageNo,
      pkmapFreeListHeads: pkmapFreeListHeads ?? this.pkmapFreeListHeads,
      pkmapRootPartition: pkmapRootPartition ?? this.pkmapRootPartition,
      pkmapRootPage: pkmapRootPage ?? this.pkmapRootPage,
      pkmapHeight: pkmapHeight ?? this.pkmapHeight,
      hasPkLocator: hasPkLocator ?? this.hasPkLocator,
      pkBackfillPartition: pkBackfillPartition ?? this.pkBackfillPartition,
      pkBackfillPage: pkBackfillPage ?? this.pkBackfillPage,
    );
  }

  // ===================== Serialization =========================

  factory NghIndexMeta.fromJson(Map<String, dynamic> json) {
    return NghIndexMeta(
      version: (json['version'] as num?)?.toInt(),
      layoutVersion: (json['layoutVersion'] as num?)?.toInt() ?? layoutLegacy,
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
      centroidCount: (json['centroidCount'] as num?)?.toInt() ?? 0,
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
      navPartitionCount: (json['navPartitionCount'] as num?)?.toInt() ?? 1,
      navNextPageNo:
          (json['navNextPageNo'] as num?)?.toInt() ?? firstDataPageNo,
      navFreeListHeads: _parseIntIntMap(json['navFreeListHeads']),
      pdirPartitionCount: (json['pdirPartitionCount'] as num?)?.toInt() ?? 1,
      pdirNextPageNo:
          (json['pdirNextPageNo'] as num?)?.toInt() ?? firstDataPageNo,
      pdirFreeListHeads: _parseIntIntMap(json['pdirFreeListHeads']),
      pkmapPartitionCount: (json['pkmapPartitionCount'] as num?)?.toInt() ?? 1,
      pkmapNextPageNo:
          (json['pkmapNextPageNo'] as num?)?.toInt() ?? firstDataPageNo,
      pkmapFreeListHeads: _parseIntIntMap(json['pkmapFreeListHeads']),
      pkmapRootPartition: (json['pkmapRootPartition'] as num?)?.toInt() ?? -1,
      pkmapRootPage: (json['pkmapRootPage'] as num?)?.toInt() ?? -1,
      pkmapHeight: (json['pkmapHeight'] as num?)?.toInt() ?? 0,
      hasPkLocator: (json['hasPkLocator'] as bool?) ?? false,
      pkBackfillPartition: (json['pkBackfillPartition'] as num?)?.toInt() ?? 0,
      pkBackfillPage: (json['pkBackfillPage'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'layoutVersion': layoutVersion,
      'indexUid': indexUid,
      'tableUid': tableUid,
      'dimensions': dimensions,
      'distanceMetric': distanceMetric.name,
      'timestamps': timestamps.toJson(),
      'totalVectors': totalVectors,
      'deletedCount': deletedCount,
      'nextNodeId': nextNodeId,
      'centroidCount': centroidCount,
      'totalSizeBytes': totalSizeBytes,
      'isBuilding': isBuilding,
      'postingPartitionCount': postingPartitionCount,
      'postingNextPageNo': postingNextPageNo,
      'postingFreeListHeads': _serializeIntIntMap(postingFreeListHeads),
      'navPartitionCount': navPartitionCount,
      'navNextPageNo': navNextPageNo,
      'navFreeListHeads': _serializeIntIntMap(navFreeListHeads),
      'pdirPartitionCount': pdirPartitionCount,
      'pdirNextPageNo': pdirNextPageNo,
      'pdirFreeListHeads': _serializeIntIntMap(pdirFreeListHeads),
      'pkmapPartitionCount': pkmapPartitionCount,
      'pkmapNextPageNo': pkmapNextPageNo,
      'pkmapFreeListHeads': _serializeIntIntMap(pkmapFreeListHeads),
      'pkmapRootPartition': pkmapRootPartition,
      'pkmapRootPage': pkmapRootPage,
      'pkmapHeight': pkmapHeight,
      'hasPkLocator': hasPkLocator,
      'pkBackfillPartition': pkBackfillPartition,
      'pkBackfillPage': pkBackfillPage,
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
      'deleted: $deletedCount, layout: $layoutVersion, '
      'postingPartitions: $postingPartitionCount)';
}
