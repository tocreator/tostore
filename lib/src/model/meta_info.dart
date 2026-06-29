import '../handler/common.dart';
import 'db_exception.dart';
import 'result_status.dart';
import 'result_type.dart';

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
  final FileType type;
  final String name;
  final int fileSizeInBytes;
  final Timestamps timestamps;

  FileMeta({
    int? version,
    required this.type,
    required this.name,
    required this.fileSizeInBytes,
    required this.timestamps,
  }) : version = version ?? InternalConfig.tableDataVersion;

  FileMeta copyWith({
    int? version,
    FileType? type,
    String? name,
    int? fileSizeInBytes,
    Timestamps? timestamps,
  }) {
    return FileMeta(
      version: version ?? this.version,
      type: type ?? this.type,
      name: name ?? this.name,
      fileSizeInBytes: fileSizeInBytes ?? this.fileSizeInBytes,
      timestamps: timestamps ?? this.timestamps,
    );
  }

  /// deserialize from json
  factory FileMeta.fromJson(Map<String, dynamic> json) {
    if (json['type'] == null ||
        json['name'] == null ||
        json['fileSizeInBytes'] == null ||
        json['timestamps'] == null) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'Missing required fields for FileMeta. Missing fields: ${[
            if (json['type'] == null) 'type',
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
      type: FileType.fromString(json['type'] as String),
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
      'type': type.key,
      'name': name,
      'fileSizeInBytes': fileSizeInBytes,
      'timestamps': timestamps.toJson(),
    };
  }

  @override
  String toString() =>
      'FileMeta(version: $version, type: ${type.key}, name: $name, fileSizeInBytes: $fileSizeInBytes, timestamps: $timestamps)';
}

/// table meta model
class TableMeta {
  final int version;
  final String tableUid;
  final int totalSizeInBytes;
  final int totalRecords;
  final Timestamps timestamps;

  /// Maximum auto-increment primary key value for sequential primary key tables.
  /// Stored as string to support large integers and custom formats.
  /// null for non-sequential primary key tables or when not yet initialized.
  final String? maxAutoIncrementId;

  // ==================== B+Tree Fields ====================
  // partitionNo = physical partition file number (0..btreePartitionCount-1).

  /// Page size in bytes for B+Tree pages.
  final int btreePageSize;

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

  TableMeta({
    int? version,
    required this.tableUid,
    required this.totalSizeInBytes,
    required this.totalRecords,
    required this.timestamps,
    this.maxAutoIncrementId,
    required this.btreePageSize,
    required this.btreeNextPageNo,
    required this.btreePartitionCount,
    required this.btreeRoot,
    required this.btreeFirstLeaf,
    required this.btreeLastLeaf,
    required this.btreeHeight,
  }) : version = version ?? InternalConfig.tableDataVersion;

  /// Default page size for B+Tree pages (16KB).
  static const int defaultPageSize = 16 * 1024;

  /// First data page number (pageNo=0 is reserved for [PartitionMetaPage]).
  static const int firstDataPageNo = 1;

  /// Creates an initial empty [TableMeta] with default B+Tree configuration.
  ///
  /// [tableUid] - The table unique identifier.
  /// [pageSize] - Page size in bytes (default: 16KB).
  /// [partitionCount] - Initial partition count (default: 1).
  /// [now] - Optional timestamp override; uses current time if not provided.
  ///
  /// This is the canonical way to create an initial [TableMeta] when:
  /// - Creating a new table
  /// - Clearing an existing table (with optional preserved pageSize/partitionCount)
  static TableMeta createEmpty({
    required String tableUid,
    int pageSize = defaultPageSize,
    int partitionCount = 1,
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now();
    return TableMeta(
      tableUid: tableUid,
      totalSizeInBytes: 0,
      totalRecords: 0,
      timestamps: Timestamps(created: timestamp, modified: timestamp),
      btreePageSize: pageSize,
      btreeNextPageNo: firstDataPageNo,
      btreePartitionCount: partitionCount,
      btreeRoot: TreePagePtr.nullPtr,
      btreeFirstLeaf: TreePagePtr.nullPtr,
      btreeLastLeaf: TreePagePtr.nullPtr,
      btreeHeight: 0,
    );
  }

  TableMeta copyWith({
    int? version,
    String? tableUid,
    int? totalSizeInBytes,
    int? totalRecords,
    Timestamps? timestamps,
    String? maxAutoIncrementId,
    int? btreePageSize,
    int? btreeNextPageNo,
    int? btreePartitionCount,
    TreePagePtr? btreeRoot,
    TreePagePtr? btreeFirstLeaf,
    TreePagePtr? btreeLastLeaf,
    int? btreeHeight,
  }) {
    return TableMeta(
      version: version ?? this.version,
      tableUid: tableUid ?? this.tableUid,
      totalSizeInBytes: totalSizeInBytes ?? this.totalSizeInBytes,
      totalRecords: totalRecords ?? this.totalRecords,
      timestamps: timestamps ?? this.timestamps,
      maxAutoIncrementId: maxAutoIncrementId ?? this.maxAutoIncrementId,
      btreePageSize: btreePageSize ?? this.btreePageSize,
      btreeNextPageNo: btreeNextPageNo ?? this.btreeNextPageNo,
      btreePartitionCount: btreePartitionCount ?? this.btreePartitionCount,
      btreeRoot: btreeRoot ?? this.btreeRoot,
      btreeFirstLeaf: btreeFirstLeaf ?? this.btreeFirstLeaf,
      btreeLastLeaf: btreeLastLeaf ?? this.btreeLastLeaf,
      btreeHeight: btreeHeight ?? this.btreeHeight,
    );
  }

  /// deserialize from json
  factory TableMeta.fromJson(Map<String, dynamic> json) {
    final loadedUid = (json['tableUid'] ?? json['name']) as String?;
    if (loadedUid == null ||
        json['totalSizeInBytes'] == null ||
        json['totalRecords'] == null ||
        json['timestamps'] == null ||
        json['btreePageSize'] == null ||
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
              'Missing required fields for TableMeta. Missing fields: ${[
            if (loadedUid == null) 'tableUid',
            if (json['totalSizeInBytes'] == null) 'totalSizeInBytes',
            if (json['totalRecords'] == null) 'totalRecords',
            if (json['timestamps'] == null) 'timestamps',
            if (json['btreePageSize'] == null) 'btreePageSize',
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

    return TableMeta(
      version:
          resolveVersionValue(json['version'], InternalConfig.tableDataVersion),
      tableUid: loadedUid,
      totalSizeInBytes: json['totalSizeInBytes'] is int
          ? json['totalSizeInBytes'] as int
          : int.parse('${json['totalSizeInBytes']}'),
      totalRecords: json['totalRecords'] is int
          ? json['totalRecords'] as int
          : int.parse('${json['totalRecords']}'),
      timestamps:
          Timestamps.fromJson(json['timestamps'] as Map<String, dynamic>),
      maxAutoIncrementId: json['maxAutoIncrementId'] as String?,
      btreePageSize: (json['btreePageSize'] as num).toInt(),
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
      'totalSizeInBytes': totalSizeInBytes,
      'totalRecords': totalRecords,
      'timestamps': timestamps.toJson(),
      if (maxAutoIncrementId != null) 'maxAutoIncrementId': maxAutoIncrementId,
      'btreePageSize': btreePageSize,
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
      'TableMeta(version: $version, tableUid: $tableUid, totalSizeInBytes: $totalSizeInBytes, totalRecords: $totalRecords, btreePartitionCount: $btreePartitionCount, btreeHeight: $btreeHeight, btreeRoot: $btreeRoot)';
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

enum FileType {
  data("data", "dat"),
  schema("schema", "json"),
  idx("index", "idx"),
  log("log", "log"),
  other("other", "txt");

  final String key;
  final String ext;
  const FileType(this.key, this.ext);

  static FileType fromString(String value) {
    for (final e in FileType.values) {
      if (e.key == value) return e;
    }
    return FileType.other;
  }

  @override
  String toString() => key;
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

  /// table names in the partition
  final List<String> tableNames;

  /// table size mapping
  final Map<String, int> tableSizes;

  /// table schema data
  final Map<String, dynamic> tableSchemas;

  /// stable field storage layout per table
  final Map<String, dynamic> tableFieldLayouts;

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
    required this.tableNames,
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
    List<String>? tableNames,
    Map<String, int>? tableSizes,
    Map<String, dynamic>? tableSchemas,
    Map<String, dynamic>? tableFieldLayouts,
    Timestamps? timestamps,
    int? dirIndex,
  }) {
    return SchemaPartitionMeta(
      version: version ?? this.version,
      index: index ?? this.index,
      fileSizeInBytes: fileSizeInBytes ?? this.fileSizeInBytes,
      tableNames: tableNames ?? List.from(this.tableNames),
      tableSizes: tableSizes ?? Map.from(this.tableSizes),
      tableSchemas: tableSchemas ?? Map.from(this.tableSchemas),
      tableFieldLayouts: tableFieldLayouts ?? Map.from(this.tableFieldLayouts),
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
      tableNames: List<String>.from(json['tableNames'] as List),
      tableSizes: Map<String, int>.from(json['tableSizes'] as Map),
      tableSchemas: Map<String, dynamic>.from(json['tableSchemas'] as Map),
      tableFieldLayouts: json['tableFieldLayouts'] is Map
          ? Map<String, dynamic>.from(json['tableFieldLayouts'] as Map)
          : <String, dynamic>{},
      timestamps:
          Timestamps.fromJson(json['timestamps'] as Map<String, dynamic>),
      dirIndex: json['dirIndex'] as int?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'index': index,
      'fileSizeInBytes': fileSizeInBytes,
      'tableNames': tableNames,
      'tableSizes': tableSizes,
      'tableSchemas': tableSchemas,
      'tableFieldLayouts': tableFieldLayouts,
      'timestamps': timestamps.toJson(),
      if (dirIndex != null) 'dirIndex': dirIndex,
    };
  }

  @override
  String toString() {
    return 'SchemaPartitionMeta(version: $version, index: $index, fileSizeInBytes: $fileSizeInBytes, tableNames: $tableNames, tableSizes: $tableSizes, timestamps: $timestamps)';
  }
}

/// stable table schema route entry
class TableSchemaRouteEntry {
  final String tableUid;
  final String tableName;
  final int dirIndex;
  final int partitionIndex;
  final int dataDirIndex;
  final bool isGlobal;

  TableSchemaRouteEntry({
    required this.tableUid,
    required this.tableName,
    required this.dirIndex,
    required this.partitionIndex,
    required this.dataDirIndex,
    required this.isGlobal,
  });

  factory TableSchemaRouteEntry.fromJson(Map<String, dynamic> json) {
    return TableSchemaRouteEntry(
      tableUid: json['tableUid'] as String,
      tableName: json['tableName'] as String,
      dirIndex: json['dirIndex'] as int,
      partitionIndex: json['partitionIndex'] as int,
      dataDirIndex: json['dataDirIndex'] as int,
      isGlobal: json['isGlobal'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'tableUid': tableUid,
      'tableName': tableName,
      'dirIndex': dirIndex,
      'partitionIndex': partitionIndex,
      'dataDirIndex': dataDirIndex,
      'isGlobal': isGlobal,
    };
  }
}

/// database schema meta
class SchemaMeta {
  /// database version
  final int version;

  /// table schema route entries
  final List<TableSchemaRouteEntry> routes;

  /// timestamps
  final Timestamps timestamps;

  /// user-defined table schema hash (ToStore(schemas: []))
  final String? userSchemaHash;

  /// system table schema hash
  final String? systemSchemaHash;

  SchemaMeta({
    int? version,
    required this.routes,
    required this.timestamps,
    this.userSchemaHash,
    this.systemSchemaHash,
  }) : version = version ?? InternalConfig.schemaVersion;

  SchemaMeta copyWith({
    int? version,
    List<TableSchemaRouteEntry>? routes,
    Timestamps? timestamps,
    String? userSchemaHash,
    String? systemSchemaHash,
  }) {
    return SchemaMeta(
      version: version ?? this.version,
      routes: routes ?? List<TableSchemaRouteEntry>.from(this.routes),
      timestamps: timestamps ?? this.timestamps,
      userSchemaHash: userSchemaHash ?? this.userSchemaHash,
      systemSchemaHash: systemSchemaHash ?? this.systemSchemaHash,
    );
  }

  factory SchemaMeta.fromJson(Map<String, dynamic> json) {
    return SchemaMeta(
      version: resolveVersionValue(
          json['version'], InternalConfig.schemaVersion),
      routes: (json['routes'] as List<dynamic>?)
              ?.map((e) => TableSchemaRouteEntry.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      timestamps:
          Timestamps.fromJson(json['timestamps'] as Map<String, dynamic>),
      userSchemaHash: json['userSchemaHash'] as String?,
      systemSchemaHash: json['systemSchemaHash'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'routes': routes.map((e) => e.toJson()).toList(),
      'timestamps': timestamps.toJson(),
      if (userSchemaHash != null) 'userSchemaHash': userSchemaHash,
      if (systemSchemaHash != null) 'systemSchemaHash': systemSchemaHash,
    };
  }

  @override
  String toString() {
    return 'SchemaMeta(version: $version, routesCount: ${routes.length}, timestamps: $timestamps, userSchemaHash: $userSchemaHash, systemSchemaHash: $systemSchemaHash)';
  }
}

/// index meta
class IndexMeta {
  /// index version
  final int version;

  /// index unique identifier
  final String indexUid;

  /// table unique identifier
  final String tableUid;

  /// whether the index is unique
  final bool isUnique;

  /// whether the index is still being backfilled
  final bool isBuilding;

  /// total size of all partitions in bytes
  final int totalSizeInBytes;

  /// total number of entries in the index
  final int totalEntries;

  /// timestamps
  final Timestamps timestamps;

  // ==================== B+Tree Fields ====================
  // partitionNo = physical partition file number (0..btreePartitionCount-1).

  /// Page size in bytes for B+Tree pages.
  final int btreePageSize;

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
    this.totalSizeInBytes = 0,
    this.totalEntries = 0,
    required this.btreePageSize,
    required this.btreeNextPageNo,
    required this.btreePartitionCount,
    required this.btreeRoot,
    required this.btreeFirstLeaf,
    required this.btreeLastLeaf,
    required this.btreeHeight,
  }) : version = version ?? InternalConfig.indexVersion;

  /// Default page size for B+Tree pages (16KB).
  static const int defaultPageSize = 16 * 1024;

  /// First data page number (pageNo=0 is reserved for [PartitionMetaPage]).
  static const int firstDataPageNo = 1;

  /// Creates an initial empty [IndexMeta] with default B+Tree configuration.
  ///
  /// [indexUid] - The index unique identifier.
  /// [tableUid] - The table unique identifier.
  /// [isUnique] - Whether this is a unique index.
  /// [pageSize] - Page size in bytes (default: 16KB).
  /// [partitionCount] - Initial partition count (default: 1).
  /// [now] - Optional timestamp override; uses current time if not provided.
  static IndexMeta createEmpty({
    required String indexUid,
    required String tableUid,
    required bool isUnique,
    bool isBuilding = false,
    int pageSize = defaultPageSize,
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
      totalSizeInBytes: 0,
      totalEntries: 0,
      btreePageSize: pageSize,
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
    String? indexUid,
    String? tableUid,
    bool? isUnique,
    bool? isBuilding,
    Timestamps? timestamps,
    int? totalSizeInBytes,
    int? totalEntries,
    int? btreePageSize,
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
      totalSizeInBytes: totalSizeInBytes ?? this.totalSizeInBytes,
      totalEntries: totalEntries ?? this.totalEntries,
      btreePageSize: btreePageSize ?? this.btreePageSize,
      btreeNextPageNo: btreeNextPageNo ?? this.btreeNextPageNo,
      btreePartitionCount: btreePartitionCount ?? this.btreePartitionCount,
      btreeRoot: btreeRoot ?? this.btreeRoot,
      btreeFirstLeaf: btreeFirstLeaf ?? this.btreeFirstLeaf,
      btreeLastLeaf: btreeLastLeaf ?? this.btreeLastLeaf,
      btreeHeight: btreeHeight ?? this.btreeHeight,
    );
  }

  factory IndexMeta.fromJson(Map<String, dynamic> json) {
    final loadedIndexUid = (json['indexUid'] ?? json['name']) as String?;
    final loadedTableUid = (json['tableUid'] ?? json['tableName']) as String?;

    if (loadedIndexUid == null ||
        loadedTableUid == null ||
        json['isUnique'] == null ||
        json['timestamps'] == null ||
        json['btreePageSize'] == null ||
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
              'Missing required fields for IndexMeta. Missing fields: ${[
            if (loadedIndexUid == null) 'indexUid',
            if (loadedTableUid == null) 'tableUid',
            if (json['isUnique'] == null) 'isUnique',
            if (json['timestamps'] == null) 'timestamps',
            if (json['btreePageSize'] == null) 'btreePageSize',
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
      indexUid: loadedIndexUid,
      tableUid: loadedTableUid,
      isUnique: json['isUnique'] as bool,
      isBuilding: json['isBuilding'] as bool? ?? false,
      timestamps:
          Timestamps.fromJson(json['timestamps'] as Map<String, dynamic>),
      totalSizeInBytes: (json['totalSizeInBytes'] as num?)?.toInt() ?? 0,
      totalEntries: (json['totalEntries'] as num?)?.toInt() ?? 0,
      btreePageSize: (json['btreePageSize'] as num).toInt(),
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
      'totalSizeInBytes': totalSizeInBytes,
      'totalEntries': totalEntries,
      'timestamps': timestamps.toJson(),
      'btreePageSize': btreePageSize,
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
    return 'IndexMeta(version: $version, indexUid: $indexUid, tableUid: $tableUid, isBuilding: $isBuilding, totalSizeInBytes: $totalSizeInBytes, totalEntries: $totalEntries, btreePartitionCount: $btreePartitionCount, btreeHeight: $btreeHeight, btreeRoot: $btreeRoot)';
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
