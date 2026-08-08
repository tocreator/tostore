import '../handler/common.dart';
import 'db_exception.dart';
import 'result_status.dart';
import 'result_type.dart';
import 'table_identity.dart';

// ============================================================================
// B+Tree Paged Storage Metadata
// ============================================================================

/// Global page pointer for cross-partition B+Tree leaf chain.
///
/// Uses dense int [partitionNo] in pages for compactness.
/// [partitionNo] maps directly to the physical B+Tree partition file number.
final class TreePagePtr {
  /// Partition file number (dense, 0..N-1).
  final int partitionNo;

  /// Page number within the partition file.
  final int pageNo;

  const TreePagePtr(this.partitionNo, this.pageNo);

  /// Null pointer constant (represents no page).
  static const TreePagePtr nullPtr = TreePagePtr(-1, -1);

  /// Whether this pointer is null (invalid).
  bool get isNull => partitionNo < 0 || pageNo < 0;

  /// Compact JSON serialization.
  Map<String, dynamic> toJson() => {'p': partitionNo, 'g': pageNo};

  /// Deserialize from compact JSON.
  static TreePagePtr fromJson(Map<String, dynamic>? json) {
    if (json == null) return nullPtr;
    return TreePagePtr(
      (json['p'] as num?)?.toInt() ?? -1,
      (json['g'] as num?)?.toInt() ?? -1,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TreePagePtr &&
          partitionNo == other.partitionNo &&
          pageNo == other.pageNo;

  @override
  int get hashCode => partitionNo.hashCode ^ pageNo.hashCode;

  @override
  String toString() =>
      isNull ? 'TreePagePtr.null' : 'TreePagePtr($partitionNo:$pageNo)';
}

// ============================================================================
// Core File/Table/Index Metadata
// ============================================================================

class FileInfo {
  final String path;
  final FileMeta meta;
  final List<dynamic>? data;

  FileInfo({
    required this.path,
    required this.meta,
    this.data,
  });

  FileInfo copyWith({
    String? path,
    FileMeta? meta,
    List<dynamic>? data,
  }) {
    return FileInfo(
      path: path ?? this.path,
      meta: meta ?? this.meta,
      data: data ?? this.data,
    );
  }

  factory FileInfo.fromJson(Map<String, dynamic> json) {
    if (json['path'] == null || json['meta'] == null) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Missing required fields for FileInfo. Details: path is ${json['path'] == null ? 'NULL' : 'present'}, meta is ${json['meta'] == null ? 'NULL' : 'present'}. ',
        )
      ]);
    }
    return FileInfo(
      path: json['path'] as String,
      meta: FileMeta.fromJson(json['meta'] as Map<String, dynamic>),
      data: json['data'] != null
          ? (json['data'] as List).map((e) => e as dynamic).toList()
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'path': path,
      'meta': meta.toJson(),
      'data': data,
    };
  }

  @override
  String toString() => 'FileInfo(path: $path, meta: $meta, data: $data)';
}

/// file meta model
class FileMeta {
  final int version;
  final String name;
  final int fileSizeInBytes;
  final Timestamps timestamps;

  FileMeta({
    int? version,
    required this.name,
    required this.fileSizeInBytes,
    required this.timestamps,
  }) : version = version ?? InternalConfig.tableDataVersion;

  FileMeta copyWith({
    int? version,
    String? name,
    int? fileSizeInBytes,
    Timestamps? timestamps,
  }) {
    return FileMeta(
      version: version ?? this.version,
      name: name ?? this.name,
      fileSizeInBytes: fileSizeInBytes ?? this.fileSizeInBytes,
      timestamps: timestamps ?? this.timestamps,
    );
  }

  /// deserialize from json
  factory FileMeta.fromJson(Map<String, dynamic> json) {
    if (json['name'] == null ||
        json['fileSizeInBytes'] == null ||
        json['timestamps'] == null) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'Missing required fields for FileMeta. Missing fields: ${[
            if (json['name'] == null) 'name',
            if (json['fileSizeInBytes'] == null) 'fileSizeInBytes',
            if (json['timestamps'] == null) 'timestamps'
          ].join(', ')}.',
        )
      ]);
    }
    return FileMeta(
      version: resolveVersionValue(
          json['version'], InternalConfig.legacyTableDataVersion),
      name: json['name'] as String,
      fileSizeInBytes: json['fileSizeInBytes'] is int
          ? json['fileSizeInBytes'] as int
          : int.parse('${json['fileSizeInBytes']}'),
      timestamps:
          Timestamps.fromJson(json['timestamps'] as Map<String, dynamic>),
    );
  }

  /// serialize to json
  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'name': name,
      'fileSizeInBytes': fileSizeInBytes,
      'timestamps': timestamps.toJson(),
    };
  }

  @override
  String toString() =>
      'FileMeta(version: $version, name: $name, fileSizeInBytes: $fileSizeInBytes, timestamps: $timestamps)';
}

/// table data meta model
class TableDataMeta {
  final int version;
  final TableUid tableUid;
  final int totalSizeBytes;
  final int totalRecordCount;
  final Timestamps timestamps;

  /// Maximum auto-increment primary key value for sequential primary key tables.
  /// Stored as string to support large integers and custom formats.
  /// null for non-sequential primary key tables or when not yet initialized.
  final String? maxAutoIncrementId;

  // ==================== B+Tree Fields ====================
  // partitionNo = physical partition file number (0..btreePartitionCount-1).

  /// Next page number in the active partition (last partition).
  ///
  /// NOTE: pageNo=0 is reserved for `PartitionMetaPage`, so valid data pages start at 1.
  final int btreeNextPageNo;

  /// Number of B+Tree partition files for this table.
  final int btreePartitionCount;

  /// B+Tree root pointer.
  final TreePagePtr btreeRoot;

  /// Global leaf chain first leaf pointer.
  final TreePagePtr btreeFirstLeaf;

  /// Global leaf chain last leaf pointer.
  final TreePagePtr btreeLastLeaf;

  /// B+Tree height (0 = root is leaf).
  final int btreeHeight;

  TableDataMeta({
    int? version,
    required this.tableUid,
    required this.totalSizeBytes,
    required this.totalRecordCount,
    required this.timestamps,
    this.maxAutoIncrementId,
    required this.btreeNextPageNo,
    required this.btreePartitionCount,
    required this.btreeRoot,
    required this.btreeFirstLeaf,
    required this.btreeLastLeaf,
    required this.btreeHeight,
  }) : version = version ?? InternalConfig.tableDataVersion;

  /// First data page number (pageNo=0 is reserved for [PartitionMetaPage]).
  static const int firstDataPageNo = 1;

  /// Creates an initial empty [TableDataMeta] with default B+Tree configuration.
  ///
  /// [tableUid] - The table unique identifier.
  /// [partitionCount] - Initial partition count (default: 1).
  /// [now] - Optional timestamp override; uses current time if not provided.
  ///
  static TableDataMeta createEmpty({
    required TableUid tableUid,
    int partitionCount = 1,
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now();
    return TableDataMeta(
      tableUid: tableUid,
      totalSizeBytes: 0,
      totalRecordCount: 0,
      timestamps: Timestamps(created: timestamp, modified: timestamp),
      btreeNextPageNo: firstDataPageNo,
      btreePartitionCount: partitionCount,
      btreeRoot: TreePagePtr.nullPtr,
      btreeFirstLeaf: TreePagePtr.nullPtr,
      btreeLastLeaf: TreePagePtr.nullPtr,
      btreeHeight: 0,
    );
  }

  TableDataMeta copyWith({
    int? version,
    TableUid? tableUid,
    int? totalSizeBytes,
    int? totalRecordCount,
    Timestamps? timestamps,
    String? maxAutoIncrementId,
    int? btreeNextPageNo,
    int? btreePartitionCount,
    TreePagePtr? btreeRoot,
    TreePagePtr? btreeFirstLeaf,
    TreePagePtr? btreeLastLeaf,
    int? btreeHeight,
  }) {
    return TableDataMeta(
      version: version ?? this.version,
      tableUid: tableUid ?? this.tableUid,
      totalSizeBytes: totalSizeBytes ?? this.totalSizeBytes,
      totalRecordCount: totalRecordCount ?? this.totalRecordCount,
      timestamps: timestamps ?? this.timestamps,
      maxAutoIncrementId: maxAutoIncrementId ?? this.maxAutoIncrementId,
      btreeNextPageNo: btreeNextPageNo ?? this.btreeNextPageNo,
      btreePartitionCount: btreePartitionCount ?? this.btreePartitionCount,
      btreeRoot: btreeRoot ?? this.btreeRoot,
      btreeFirstLeaf: btreeFirstLeaf ?? this.btreeFirstLeaf,
      btreeLastLeaf: btreeLastLeaf ?? this.btreeLastLeaf,
      btreeHeight: btreeHeight ?? this.btreeHeight,
    );
  }

  /// deserialize from json
  ///
  /// [tableUidFallback] supplies the uid when legacy meta files omit or leave
  /// [tableUid] empty (e.g. loaded from a uid-based directory path).
  factory TableDataMeta.fromJson(
    Map<String, dynamic> json, {
    TableUid? tableUidFallback,
  }) {
    final resolvedUid = _resolveTableUidFromJson(json, tableUidFallback);
    final totalSizeRaw = json['totalSizeBytes'] ?? json['totalSizeInBytes'];
    final totalRecordRaw = json['totalRecordCount'] ?? json['totalRecords'];
    if (resolvedUid == null ||
        totalSizeRaw == null ||
        totalRecordRaw == null ||
        json['timestamps'] == null ||
        json['btreeNextPageNo'] == null ||
        json['btreePartitionCount'] == null ||
        json['btreeRoot'] == null ||
        json['btreeFirstLeaf'] == null ||
        json['btreeLastLeaf'] == null ||
        json['btreeHeight'] == null) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Missing required fields for TableDataMeta. Missing fields: ${[
            if (resolvedUid == null) 'tableUid',
            if (totalSizeRaw == null) 'totalSizeBytes',
            if (totalRecordRaw == null) 'totalRecordCount',
            if (json['timestamps'] == null) 'timestamps',
            if (json['btreeNextPageNo'] == null) 'btreeNextPageNo',
            if (json['btreePartitionCount'] == null) 'btreePartitionCount',
            if (json['btreeRoot'] == null) 'btreeRoot',
            if (json['btreeFirstLeaf'] == null) 'btreeFirstLeaf',
            if (json['btreeLastLeaf'] == null) 'btreeLastLeaf',
            if (json['btreeHeight'] == null) 'btreeHeight'
          ].join(', ')}.',
        )
      ]);
    }

    return TableDataMeta(
      version:
          resolveVersionValue(json['version'], InternalConfig.tableDataVersion),
      tableUid: TableUid.parse(resolvedUid),
      totalSizeBytes:
          totalSizeRaw is int ? totalSizeRaw : int.parse('$totalSizeRaw'),
      totalRecordCount:
          totalRecordRaw is int ? totalRecordRaw : int.parse('$totalRecordRaw'),
      timestamps:
          Timestamps.fromJson(json['timestamps'] as Map<String, dynamic>),
      maxAutoIncrementId: json['maxAutoIncrementId'] as String?,
      btreeNextPageNo: (json['btreeNextPageNo'] as num).toInt(),
      btreePartitionCount: (json['btreePartitionCount'] as num).toInt(),
      btreeRoot:
          TreePagePtr.fromJson(json['btreeRoot'] as Map<String, dynamic>),
      btreeFirstLeaf:
          TreePagePtr.fromJson(json['btreeFirstLeaf'] as Map<String, dynamic>),
      btreeLastLeaf:
          TreePagePtr.fromJson(json['btreeLastLeaf'] as Map<String, dynamic>),
      btreeHeight: (json['btreeHeight'] as num).toInt(),
    );
  }

  /// serialize to json
  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'tableUid': tableUid,
      'totalSizeBytes': totalSizeBytes,
      'totalRecordCount': totalRecordCount,
      'timestamps': timestamps.toJson(),
      if (maxAutoIncrementId != null) 'maxAutoIncrementId': maxAutoIncrementId,
      'btreeNextPageNo': btreeNextPageNo,
      'btreePartitionCount': btreePartitionCount,
      'btreeRoot': btreeRoot.toJson(),
      'btreeFirstLeaf': btreeFirstLeaf.toJson(),
      'btreeLastLeaf': btreeLastLeaf.toJson(),
      'btreeHeight': btreeHeight,
    };
  }

  @override
  String toString() =>
      'TableDataMeta(version: $version, tableUid: $tableUid, totalSizeBytes: $totalSizeBytes, totalRecordCount: $totalRecordCount, btreePartitionCount: $btreePartitionCount, btreeHeight: $btreeHeight, btreeRoot: $btreeRoot)';
}

/// timestamp info
class Timestamps {
  final DateTime created;
  final DateTime modified;

  Timestamps({
    required this.created,
    required this.modified,
  });

  Timestamps copyWith({
    DateTime? created,
    DateTime? modified,
  }) {
    return Timestamps(
      created: created ?? this.created,
      modified: modified ?? this.modified,
    );
  }

  factory Timestamps.fromJson(Map<String, dynamic> json) {
    if (json['created'] == null || json['modified'] == null) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Missing required fields for Timestamps. Details: created is ${json['created'] == null ? 'NULL' : 'present'}, modified is ${json['modified'] == null ? 'NULL' : 'present'}.',
        )
      ]);
    }
    return Timestamps(
      created: DateTime.tryParse(json['created'] as String) ??
          (throw DbException([
            GeneralStatus(
              type: ResultType.engError,
              message:
                  'Invalid created timestamp: Cannot parse value of type ${json['created'].runtimeType} into DateTime.',
            )
          ])),
      modified: DateTime.tryParse(json['modified'] as String) ??
          (throw DbException([
            GeneralStatus(
              type: ResultType.engError,
              message:
                  'Invalid modified timestamp: Cannot parse value of type ${json['modified'].runtimeType} into DateTime.',
            )
          ])),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'created': created.toIso8601String(),
      'modified': modified.toIso8601String(),
    };
  }

  @override
  String toString() =>
      'Timestamps(created: ${created.toIso8601String()}, modified: ${modified.toIso8601String()})';
}

/// Stable storage slot metadata for a table field.
///
/// Slots are append-only identifiers for physical value ordering in record
/// payloads. Logical schema field order can change independently.
class FieldStorageSlot {
  /// Stable slot id (monotonic in one table).
  final int slotId;

  /// Stable field id from schema, when available.
  final String? fieldId;

  /// Latest logical field name mapped to this slot.
  final String fieldName;

  /// DataType enum index persisted at the slot layer.
  final int typeIndex;

  /// Whether this slot is logically deleted.
  final bool deleted;

  const FieldStorageSlot({
    required this.slotId,
    this.fieldId,
    required this.fieldName,
    required this.typeIndex,
    this.deleted = false,
  });

  FieldStorageSlot copyWith({
    int? slotId,
    String? fieldId,
    String? fieldName,
    int? typeIndex,
    bool? deleted,
  }) {
    return FieldStorageSlot(
      slotId: slotId ?? this.slotId,
      fieldId: fieldId ?? this.fieldId,
      fieldName: fieldName ?? this.fieldName,
      typeIndex: typeIndex ?? this.typeIndex,
      deleted: deleted ?? this.deleted,
    );
  }

  factory FieldStorageSlot.fromJson(Map<String, dynamic> json) {
    return FieldStorageSlot(
      slotId: (json['slotId'] as num?)?.toInt() ?? 0,
      fieldId: json['fieldId'] as String?,
      fieldName: (json['fieldName'] as String?) ?? '',
      typeIndex: (json['typeIndex'] as num?)?.toInt() ?? 0,
      deleted: json['deleted'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'slotId': slotId,
      if (fieldId != null) 'fieldId': fieldId,
      'fieldName': fieldName,
      'typeIndex': typeIndex,
      if (deleted) 'deleted': true,
    };
  }
}

/// Stable field storage layout metadata for a table.
class FieldStorageLayout {
  /// Layout metadata version (not table schema version).
  final int version;

  /// Next allocatable slot id for append-only growth.
  final int nextSlotId;

  /// Ordered storage slots.
  final List<FieldStorageSlot> slots;

  const FieldStorageLayout({
    this.version = 1,
    required this.nextSlotId,
    required this.slots,
  });

  FieldStorageLayout copyWith({
    int? version,
    int? nextSlotId,
    List<FieldStorageSlot>? slots,
  }) {
    return FieldStorageLayout(
      version: version ?? this.version,
      nextSlotId: nextSlotId ?? this.nextSlotId,
      slots: slots ?? List<FieldStorageSlot>.from(this.slots),
    );
  }

  int get totalSlots => slots.length;

  int get deletedSlotsCount {
    var count = 0;
    for (final slot in slots) {
      if (slot.deleted) count++;
    }
    return count;
  }

  double get deletedSlotsRatio {
    if (slots.isEmpty) return 0.0;
    return deletedSlotsCount / slots.length;
  }

  FieldStorageLayout compactDeletedSlots() {
    final active = slots.where((slot) => !slot.deleted).toList(growable: false);
    final compacted = <FieldStorageSlot>[];
    for (int i = 0; i < active.length; i++) {
      compacted.add(active[i].copyWith(slotId: i));
    }
    return FieldStorageLayout(
      version: version,
      nextSlotId: compacted.length,
      slots: compacted,
    );
  }

  factory FieldStorageLayout.fromJson(Map<String, dynamic> json) {
    final rawSlots = json['slots'];
    final slots = <FieldStorageSlot>[];
    if (rawSlots is List) {
      for (final raw in rawSlots) {
        if (raw is Map<String, dynamic>) {
          slots.add(FieldStorageSlot.fromJson(raw));
        } else if (raw is Map) {
          slots.add(FieldStorageSlot.fromJson(Map<String, dynamic>.from(raw)));
        }
      }
    }

    int maxSlotId = -1;
    for (final slot in slots) {
      if (slot.slotId > maxSlotId) maxSlotId = slot.slotId;
    }

    return FieldStorageLayout(
      version: (json['version'] as num?)?.toInt() ?? 1,
      nextSlotId: (json['nextSlotId'] as num?)?.toInt() ?? (maxSlotId + 1),
      slots: slots,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'nextSlotId': nextSlotId,
      'slots': slots.map((slot) => slot.toJson()).toList(growable: false),
    };
  }
}

/// table schema partition file meta
class SchemaPartitionMeta {
  /// partition version
  final int version;

  /// partition index
  final int index;

  /// current partition file size
  final int fileSizeInBytes;

  /// table uids in the partition
  final List<TableUid> tableUids;

  /// table size mapping (stable uid keys; legacy name keys normalized on load)
  final Map<TableUid, int> tableSizes;

  /// table schema payload keyed by stable [TableUid]
  final Map<TableUid, dynamic> tableSchemas;

  /// stable field storage layout per table
  final Map<TableUid, dynamic> tableFieldLayouts;

  /// timestamps
  final Timestamps timestamps;

  /// Directory index (shard) where this partition file is stored.
  /// Legacy-only: new layout uses `dirIndex = partitionIndex ~/ GlobalConfig.maxEntriesPerDir`.
  /// Nullable for legacy data; populated during version upgrade.
  final int? dirIndex;

  SchemaPartitionMeta({
    int? version,
    required this.index,
    required this.fileSizeInBytes,
    required this.tableUids,
    required this.tableSizes,
    required this.tableSchemas,
    required this.tableFieldLayouts,
    required this.timestamps,
    this.dirIndex,
  }) : version = version ?? InternalConfig.schemaVersion;

  SchemaPartitionMeta copyWith({
    int? version,
    int? index,
    int? fileSizeInBytes,
    List<TableUid>? tableUids,
    Map<TableUid, int>? tableSizes,
    Map<TableUid, dynamic>? tableSchemas,
    Map<TableUid, dynamic>? tableFieldLayouts,
    Timestamps? timestamps,
    int? dirIndex,
  }) {
    return SchemaPartitionMeta(
      version: version ?? this.version,
      index: index ?? this.index,
      fileSizeInBytes: fileSizeInBytes ?? this.fileSizeInBytes,
      tableUids: tableUids ?? List<TableUid>.from(this.tableUids),
      tableSizes: tableSizes ?? Map<TableUid, int>.from(this.tableSizes),
      tableSchemas:
          tableSchemas ?? Map<TableUid, dynamic>.from(this.tableSchemas),
      tableFieldLayouts: tableFieldLayouts ??
          Map<TableUid, dynamic>.from(this.tableFieldLayouts),
      timestamps: timestamps ?? this.timestamps,
      dirIndex: dirIndex ?? this.dirIndex,
    );
  }

  factory SchemaPartitionMeta.fromJson(Map<String, dynamic> json) {
    return SchemaPartitionMeta(
      version: resolveVersionValue(
          json['version'], InternalConfig.legacySchemaVersion),
      index: json['index'] as int,
      fileSizeInBytes: json['fileSizeInBytes'] as int,
      tableUids: _tableUidListFromJson(json['tableUids'] ?? json['tableNames']),
      tableSizes: _tableUidIntMapFromJson(json['tableSizes'] as Map),
      tableSchemas: _tableUidDynamicMapFromJson(json['tableSchemas'] as Map),
      tableFieldLayouts: json['tableFieldLayouts'] is Map
          ? _tableUidDynamicMapFromJson(json['tableFieldLayouts'] as Map)
          : <TableUid, dynamic>{},
      timestamps:
          Timestamps.fromJson(json['timestamps'] as Map<String, dynamic>),
      dirIndex: json['dirIndex'] as int?,
    );
  }

  static List<TableUid> _tableUidListFromJson(dynamic raw) {
    if (raw is! List) return const <TableUid>[];
    return raw.map((e) => TableUid(e as String)).toList();
  }

  static Map<TableUid, int> _tableUidIntMapFromJson(Map raw) {
    return Map<TableUid, int>.fromEntries(
      raw.entries.map(
        (e) => MapEntry(TableUid(e.key as String), (e.value as num).toInt()),
      ),
    );
  }

  static Map<TableUid, dynamic> _tableUidDynamicMapFromJson(Map raw) {
    return Map<TableUid, dynamic>.fromEntries(
      raw.entries.map(
        (e) => MapEntry(TableUid(e.key as String), e.value),
      ),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'index': index,
      'fileSizeInBytes': fileSizeInBytes,
      'tableUids': tableUids.map((u) => u.value).toList(),
      'tableSizes': tableSizes.map((k, v) => MapEntry(k.value, v)),
      'tableSchemas': tableSchemas.map((k, v) => MapEntry(k.value, v)),
      'tableFieldLayouts':
          tableFieldLayouts.map((k, v) => MapEntry(k.value, v)),
      'timestamps': timestamps.toJson(),
      if (dirIndex != null) 'dirIndex': dirIndex,
    };
  }

  @override
  String toString() {
    return 'SchemaPartitionMeta(version: $version, index: $index, fileSizeInBytes: $fileSizeInBytes, tableUids: $tableUids, tableSizes: $tableSizes, timestamps: $timestamps)';
  }
}

/// index meta
class IndexMeta {
  /// index version
  final int version;

  /// index unique identifier
  final IndexUid indexUid;

  /// table unique identifier
  final TableUid tableUid;

  /// whether the index is unique
  final bool isUnique;

  /// whether the index is still being backfilled
  final bool isBuilding;

  /// total size of all partitions in bytes
  final int totalSizeBytes;

  /// total number of entries in the index
  final int totalEntryCount;

  /// timestamps
  final Timestamps timestamps;

  // ==================== B+Tree Fields ====================
  // partitionNo = physical partition file number (0..btreePartitionCount-1).

  /// Next page number in the active partition (last partition).
  ///
  /// NOTE: pageNo=0 is reserved for `PartitionMetaPage`, so valid data pages start at 1.
  final int btreeNextPageNo;

  /// Number of B+Tree partition files for this index.
  final int btreePartitionCount;

  /// B+Tree root pointer.
  final TreePagePtr btreeRoot;

  /// Global leaf chain first leaf pointer.
  final TreePagePtr btreeFirstLeaf;

  /// Global leaf chain last leaf pointer.
  final TreePagePtr btreeLastLeaf;

  /// B+Tree height (0 = root is leaf).
  final int btreeHeight;

  IndexMeta({
    int? version,
    required this.indexUid,
    required this.tableUid,
    required this.isUnique,
    this.isBuilding = false,
    required this.timestamps,
    this.totalSizeBytes = 0,
    this.totalEntryCount = 0,
    required this.btreeNextPageNo,
    required this.btreePartitionCount,
    required this.btreeRoot,
    required this.btreeFirstLeaf,
    required this.btreeLastLeaf,
    required this.btreeHeight,
  }) : version = version ?? InternalConfig.indexVersion;

  /// First data page number (pageNo=0 is reserved for [PartitionMetaPage]).
  static const int firstDataPageNo = 1;

  /// Creates an initial empty [IndexMeta] with default B+Tree configuration.
  ///
  static IndexMeta createEmpty({
    required IndexUid indexUid,
    required TableUid tableUid,
    required bool isUnique,
    bool isBuilding = false,
    int partitionCount = 1,
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now();
    return IndexMeta(
      indexUid: indexUid,
      tableUid: tableUid,
      isUnique: isUnique,
      isBuilding: isBuilding,
      timestamps: Timestamps(created: timestamp, modified: timestamp),
      totalSizeBytes: 0,
      totalEntryCount: 0,
      btreeNextPageNo: firstDataPageNo,
      btreePartitionCount: partitionCount,
      btreeRoot: TreePagePtr.nullPtr,
      btreeFirstLeaf: TreePagePtr.nullPtr,
      btreeLastLeaf: TreePagePtr.nullPtr,
      btreeHeight: 0,
    );
  }

  IndexMeta copyWith({
    int? version,
    IndexUid? indexUid,
    TableUid? tableUid,
    bool? isUnique,
    bool? isBuilding,
    Timestamps? timestamps,
    int? totalSizeBytes,
    int? totalEntryCount,
    int? btreeNextPageNo,
    int? btreePartitionCount,
    TreePagePtr? btreeRoot,
    TreePagePtr? btreeFirstLeaf,
    TreePagePtr? btreeLastLeaf,
    int? btreeHeight,
  }) {
    return IndexMeta(
      version: version ?? this.version,
      indexUid: indexUid ?? this.indexUid,
      tableUid: tableUid ?? this.tableUid,
      isUnique: isUnique ?? this.isUnique,
      isBuilding: isBuilding ?? this.isBuilding,
      timestamps: timestamps ?? this.timestamps,
      totalSizeBytes: totalSizeBytes ?? this.totalSizeBytes,
      totalEntryCount: totalEntryCount ?? this.totalEntryCount,
      btreeNextPageNo: btreeNextPageNo ?? this.btreeNextPageNo,
      btreePartitionCount: btreePartitionCount ?? this.btreePartitionCount,
      btreeRoot: btreeRoot ?? this.btreeRoot,
      btreeFirstLeaf: btreeFirstLeaf ?? this.btreeFirstLeaf,
      btreeLastLeaf: btreeLastLeaf ?? this.btreeLastLeaf,
      btreeHeight: btreeHeight ?? this.btreeHeight,
    );
  }

  factory IndexMeta.fromJson(
    Map<String, dynamic> json, {
    TableUid? tableUidFallback,
    IndexUid? indexUidFallback,
  }) {
    final resolvedIndexUid = _resolveIndexUidFromJson(json, indexUidFallback);
    final resolvedTableUid =
        _resolveIndexTableUidFromJson(json, tableUidFallback);

    if (resolvedIndexUid == null ||
        resolvedTableUid == null ||
        json['isUnique'] == null ||
        json['timestamps'] == null ||
        json['btreeNextPageNo'] == null ||
        json['btreePartitionCount'] == null ||
        json['btreeRoot'] == null ||
        json['btreeFirstLeaf'] == null ||
        json['btreeLastLeaf'] == null ||
        json['btreeHeight'] == null) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'Missing required fields for IndexMeta. Missing fields: ${[
            if (resolvedIndexUid == null) 'indexUid',
            if (resolvedTableUid == null) 'tableUid',
            if (json['isUnique'] == null) 'isUnique',
            if (json['timestamps'] == null) 'timestamps',
            if (json['btreeNextPageNo'] == null) 'btreeNextPageNo',
            if (json['btreePartitionCount'] == null) 'btreePartitionCount',
            if (json['btreeRoot'] == null) 'btreeRoot',
            if (json['btreeFirstLeaf'] == null) 'btreeFirstLeaf',
            if (json['btreeLastLeaf'] == null) 'btreeLastLeaf',
            if (json['btreeHeight'] == null) 'btreeHeight'
          ].join(', ')}.',
        )
      ]);
    }

    return IndexMeta(
      version:
          resolveVersionValue(json['version'], InternalConfig.indexVersion),
      indexUid: IndexUid.parse(resolvedIndexUid),
      tableUid: TableUid.parse(resolvedTableUid),
      isUnique: json['isUnique'] as bool,
      isBuilding: json['isBuilding'] as bool? ?? false,
      timestamps:
          Timestamps.fromJson(json['timestamps'] as Map<String, dynamic>),
      totalSizeBytes:
          ((json['totalSizeBytes'] ?? json['totalSizeInBytes']) as num?)
                  ?.toInt() ??
              0,
      totalEntryCount:
          ((json['totalEntryCount'] ?? json['totalEntries']) as num?)
                  ?.toInt() ??
              0,
      btreeNextPageNo: (json['btreeNextPageNo'] as num).toInt(),
      btreePartitionCount: (json['btreePartitionCount'] as num).toInt(),
      btreeRoot:
          TreePagePtr.fromJson(json['btreeRoot'] as Map<String, dynamic>),
      btreeFirstLeaf:
          TreePagePtr.fromJson(json['btreeFirstLeaf'] as Map<String, dynamic>),
      btreeLastLeaf:
          TreePagePtr.fromJson(json['btreeLastLeaf'] as Map<String, dynamic>),
      btreeHeight: (json['btreeHeight'] as num).toInt(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'indexUid': indexUid,
      'tableUid': tableUid,
      'isUnique': isUnique,
      'isBuilding': isBuilding,
      'totalSizeBytes': totalSizeBytes,
      'totalEntryCount': totalEntryCount,
      'timestamps': timestamps.toJson(),
      'btreeNextPageNo': btreeNextPageNo,
      'btreePartitionCount': btreePartitionCount,
      'btreeRoot': btreeRoot.toJson(),
      'btreeFirstLeaf': btreeFirstLeaf.toJson(),
      'btreeLastLeaf': btreeLastLeaf.toJson(),
      'btreeHeight': btreeHeight,
    };
  }

  @override
  String toString() {
    return 'IndexMeta(version: $version, indexUid: $indexUid, tableUid: $tableUid, isBuilding: $isBuilding, totalSizeBytes: $totalSizeBytes, totalEntryCount: $totalEntryCount, btreePartitionCount: $btreePartitionCount, btreeHeight: $btreeHeight, btreeRoot: $btreeRoot)';
  }
}

/// Directory mapping for table partitions.
/// Maintains:
/// - partitionIndex -> dirIndex mapping
/// - dirIndex -> fileCount mapping
class DirectoryMapping {
  /// Map from partition index to directory index.
  /// Keys are partition indices, values are directory indices.
  final Map<int, int> partitionToDir;

  /// Map from directory index to number of partition files stored in that directory.
  final Map<int, int> dirToFileCount;

  DirectoryMapping({
    Map<int, int>? partitionToDir,
    Map<int, int>? dirToFileCount,
  })  : partitionToDir = partitionToDir ?? <int, int>{},
        dirToFileCount = dirToFileCount ?? <int, int>{};

  factory DirectoryMapping.fromJson(Map<String, dynamic> json) {
    final Map<int, int> p2d = <int, int>{};
    final rawP2d = json['partitionToDir'];
    if (rawP2d is Map<String, dynamic>) {
      rawP2d.forEach((key, value) {
        final idx = int.tryParse(key);
        if (idx != null && value is int) {
          p2d[idx] = value;
        }
      });
    }

    final Map<int, int> d2c = <int, int>{};
    final rawD2c = json['dirToFileCount'];
    if (rawD2c is Map<String, dynamic>) {
      rawD2c.forEach((key, value) {
        final idx = int.tryParse(key);
        if (idx != null && value is int) {
          d2c[idx] = value;
        }
      });
    }

    return DirectoryMapping(
      partitionToDir: p2d,
      dirToFileCount: d2c,
    );
  }

  Map<String, dynamic> toJson() {
    final Map<String, int> p2d = <String, int>{};
    partitionToDir.forEach((key, value) {
      p2d[key.toString()] = value;
    });

    final Map<String, int> d2c = <String, int>{};
    dirToFileCount.forEach((key, value) {
      d2c[key.toString()] = value;
    });

    return {
      'partitionToDir': p2d,
      'dirToFileCount': d2c,
    };
  }

  /// Get directory index for a given partition index.
  int? getDirIndex(int partitionIndex) => partitionToDir[partitionIndex];

  /// Get file count for a given directory index.
  int getFileCount(int dirIndex) => dirToFileCount[dirIndex] ?? 0;

  /// Create a copy with modified mappings.
  DirectoryMapping copyWith({
    Map<int, int>? partitionToDir,
    Map<int, int>? dirToFileCount,
  }) {
    return DirectoryMapping(
      partitionToDir: partitionToDir ?? Map<int, int>.from(this.partitionToDir),
      dirToFileCount: dirToFileCount ?? Map<int, int>.from(this.dirToFileCount),
    );
  }

  /// Create a copy with a single partition-to-dir mapping added/updated.
  DirectoryMapping withPartitionDir(int partitionIndex, int dirIndex) {
    final newPartitionToDir = Map<int, int>.from(partitionToDir);
    newPartitionToDir[partitionIndex] = dirIndex;
    return copyWith(partitionToDir: newPartitionToDir);
  }

  /// Create a copy with directory file count updated.
  DirectoryMapping withDirFileCount(int dirIndex, int fileCount) {
    final newDirToFileCount = Map<int, int>.from(dirToFileCount);
    newDirToFileCount[dirIndex] = fileCount;
    return copyWith(dirToFileCount: newDirToFileCount);
  }

  /// Create a copy with both partition-to-dir and dir file count updated.
  DirectoryMapping withPartitionAndDirCount(
      int partitionIndex, int dirIndex, int fileCount) {
    final newPartitionToDir = Map<int, int>.from(partitionToDir);
    newPartitionToDir[partitionIndex] = dirIndex;
    final newDirToFileCount = Map<int, int>.from(dirToFileCount);
    newDirToFileCount[dirIndex] = fileCount;
    return copyWith(
        partitionToDir: newPartitionToDir, dirToFileCount: newDirToFileCount);
  }

  @override
  String toString() =>
      'DirectoryMapping(partitionToDir: $partitionToDir, dirToFileCount: $dirToFileCount)';
}

/// Directory mapping for string-keyed partitions (e.g., migration tasks).
/// Maintains:
/// - taskId/partitionId (String) -> dirIndex mapping
/// - dirIndex -> fileCount mapping
class DirectoryMappingString {
  /// Map from task/partition ID (String) to directory index.
  /// Keys are task IDs or partition IDs (as strings), values are directory indices.
  final Map<String, int> idToDir;

  /// Map from directory index to number of files stored in that directory.
  final Map<int, int> dirToFileCount;

  DirectoryMappingString({
    Map<String, int>? idToDir,
    Map<int, int>? dirToFileCount,
  })  : idToDir = idToDir ?? <String, int>{},
        dirToFileCount = dirToFileCount ?? <int, int>{};

  factory DirectoryMappingString.fromJson(Map<String, dynamic> json) {
    final Map<String, int> i2d = <String, int>{};
    final rawI2d = json['idToDir'];
    if (rawI2d is Map<String, dynamic>) {
      rawI2d.forEach((key, value) {
        if (value is int) {
          i2d[key] = value;
        }
      });
    }

    final Map<int, int> d2c = <int, int>{};
    final rawD2c = json['dirToFileCount'];
    if (rawD2c is Map<String, dynamic>) {
      rawD2c.forEach((key, value) {
        final idx = int.tryParse(key);
        if (idx != null && value is int) {
          d2c[idx] = value;
        }
      });
    }

    return DirectoryMappingString(
      idToDir: i2d,
      dirToFileCount: d2c,
    );
  }

  Map<String, dynamic> toJson() {
    final Map<String, int> i2d = <String, int>{};
    idToDir.forEach((key, value) {
      i2d[key] = value;
    });

    final Map<String, int> d2c = <String, int>{};
    dirToFileCount.forEach((key, value) {
      d2c[key.toString()] = value;
    });

    return {
      'idToDir': i2d,
      'dirToFileCount': d2c,
    };
  }

  /// Get directory index for a given task/partition ID.
  int? getDirIndex(String id) => idToDir[id];

  /// Get file count for a given directory index.
  int getFileCount(int dirIndex) => dirToFileCount[dirIndex] ?? 0;

  /// Create a copy with modified mappings.
  DirectoryMappingString copyWith({
    Map<String, int>? idToDir,
    Map<int, int>? dirToFileCount,
  }) {
    return DirectoryMappingString(
      idToDir: idToDir ?? Map<String, int>.from(this.idToDir),
      dirToFileCount: dirToFileCount ?? Map<int, int>.from(this.dirToFileCount),
    );
  }

  /// Create a copy with a single ID-to-dir mapping added/updated.
  DirectoryMappingString withIdDir(String id, int dirIndex) {
    final newIdToDir = Map<String, int>.from(idToDir);
    newIdToDir[id] = dirIndex;
    return copyWith(idToDir: newIdToDir);
  }

  /// Create a copy with directory file count updated.
  DirectoryMappingString withDirFileCount(int dirIndex, int fileCount) {
    final newDirToFileCount = Map<int, int>.from(dirToFileCount);
    newDirToFileCount[dirIndex] = fileCount;
    return copyWith(dirToFileCount: newDirToFileCount);
  }

  /// Create a copy with both ID-to-dir and dir file count updated.
  DirectoryMappingString withIdAndDirCount(
      String id, int dirIndex, int fileCount) {
    final newIdToDir = Map<String, int>.from(idToDir);
    newIdToDir[id] = dirIndex;
    final newDirToFileCount = Map<int, int>.from(dirToFileCount);
    newDirToFileCount[dirIndex] = fileCount;
    return copyWith(idToDir: newIdToDir, dirToFileCount: newDirToFileCount);
  }

  /// Remove an ID from the mapping and update directory file count.
  /// If directory count reaches 0, remove it from dirToFileCount to avoid orphaned mappings.
  DirectoryMappingString removeId(String id) {
    final dirIndex = idToDir[id];
    final newIdToDir = Map<String, int>.from(idToDir);
    newIdToDir.remove(id);

    final newDirToFileCount = Map<int, int>.from(dirToFileCount);
    if (dirIndex != null) {
      final currentCount = newDirToFileCount[dirIndex] ?? 0;
      if (currentCount > 1) {
        newDirToFileCount[dirIndex] = currentCount - 1;
      } else {
        // Remove directory from mapping when count reaches 0
        newDirToFileCount.remove(dirIndex);
      }
    }

    return copyWith(idToDir: newIdToDir, dirToFileCount: newDirToFileCount);
  }

  @override
  String toString() =>
      'DirectoryMappingString(idToDir: $idToDir, dirToFileCount: $dirToFileCount)';
}

String? _nonEmptyString(dynamic raw) {
  if (raw is! String || raw.isEmpty) return null;
  return raw;
}

/// Resolve table uid from persisted meta, preferring explicit [tableUid] then
/// caller [fallback], then legacy [name].
String? _resolveTableUidFromJson(
  Map<String, dynamic> json,
  TableUid? fallback,
) {
  return _nonEmptyString(json['tableUid']) ??
      (fallback != null && fallback.isNotEmpty ? fallback.value : null) ??
      _nonEmptyString(json['name']);
}

/// Resolve index uid from persisted meta, preferring explicit [indexUid] then
/// caller [fallback], then legacy [name].
String? _resolveIndexUidFromJson(
  Map<String, dynamic> json,
  IndexUid? fallback,
) {
  return _nonEmptyString(json['indexUid']) ??
      (fallback != null && fallback.isNotEmpty ? fallback.value : null) ??
      _nonEmptyString(json['name']);
}

/// Resolve owning table uid for index meta.
String? _resolveIndexTableUidFromJson(
  Map<String, dynamic> json,
  TableUid? fallback,
) {
  return _nonEmptyString(json['tableUid']) ??
      (fallback != null && fallback.isNotEmpty ? fallback.value : null) ??
      _nonEmptyString(json['tableName']);
}
