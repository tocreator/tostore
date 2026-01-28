import '../handler/common.dart';

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
      throw ArgumentError('Missing required fields for FileInfo');
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
      throw ArgumentError('Missing required fields for FileMeta');
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
  final String name;
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
    required this.name,
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
  /// [name] - The table name.
  /// [pageSize] - Page size in bytes (default: 16KB).
  /// [partitionCount] - Initial partition count (default: 1).
  /// [now] - Optional timestamp override; uses current time if not provided.
  ///
  /// This is the canonical way to create an initial [TableMeta] when:
  /// - Creating a new table
  /// - Clearing an existing table (with optional preserved pageSize/partitionCount)
  static TableMeta createEmpty({
    required String name,
    int pageSize = defaultPageSize,
    int partitionCount = 1,
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now();
    return TableMeta(
      name: name,
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
    String? name,
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
      name: name ?? this.name,
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
    if (json['name'] == null ||
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
      throw ArgumentError('Missing required fields for TableMeta (v2+)');
    }

    return TableMeta(
      version:
          resolveVersionValue(json['version'], InternalConfig.tableDataVersion),
      name: json['name'] as String,
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
      'name': name,
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
      'TableMeta(version: $version, name: $name, totalSizeInBytes: $totalSizeInBytes, totalRecords: $totalRecords, btreePartitionCount: $btreePartitionCount, btreeHeight: $btreeHeight, btreeRoot: $btreeRoot)';
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
      throw ArgumentError('Missing required fields for Timestamps');
    }
    return Timestamps(
      created: DateTime.tryParse(json['created'] as String) ??
          (throw ArgumentError('Invalid created timestamp')),
      modified: DateTime.tryParse(json['modified'] as String) ??
          (throw ArgumentError('Invalid modified timestamp')),
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
      'timestamps': timestamps.toJson(),
      if (dirIndex != null) 'dirIndex': dirIndex,
    };
  }

  @override
  String toString() {
    return 'SchemaPartitionMeta(version: $version, index: $index, fileSizeInBytes: $fileSizeInBytes, tableNames: $tableNames, tableSizes: $tableSizes, timestamps: $timestamps)';
  }
}

/// table directory info
class TableDirectoryInfo {
  /// whether the table is global
  final bool isGlobal;

  /// directory index
  final int dirIndex;

  TableDirectoryInfo({
    required this.isGlobal,
    required this.dirIndex,
  });

  factory TableDirectoryInfo.fromJson(Map<String, dynamic> json) {
    return TableDirectoryInfo(
      isGlobal: json['isGlobal'] as bool,
      dirIndex: json['dirIndex'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'isGlobal': isGlobal,
      'dirIndex': dirIndex,
    };
  }

  @override
  String toString() =>
      'TableDirectoryInfo(isGlobal: $isGlobal, dirIndex: $dirIndex)';
}

/// database schema meta
class SchemaMeta {
  /// database version
  final int version;

  /// table and partition mapping - key is table name, value is partition index containing the table
  /// Note: Each table schema should be stored in a single partition file to avoid decoding issues
  final Map<String, int> tablePartitionMap;

  /// timestamps
  final Timestamps timestamps;

  /// user-defined table schema hash (Tostore(schemas: []))
  final String? userSchemaHash;

  /// system table schema hash
  final String? systemSchemaHash;

  /// Directory mapping for schema partitions.
  /// Maintains partition index -> directory index mapping and directory file counts.
  final DirectoryMapping? directoryMapping;

  SchemaMeta({
    int? version,
    required this.tablePartitionMap,
    required this.timestamps,
    this.userSchemaHash,
    this.systemSchemaHash,
    this.directoryMapping,
  }) : version = version ?? InternalConfig.schemaVersion;

  SchemaMeta copyWith({
    int? version,
    Map<String, int>? tablePartitionMap,
    Timestamps? timestamps,
    String? userSchemaHash,
    String? systemSchemaHash,
    DirectoryMapping? directoryMapping,
  }) {
    return SchemaMeta(
      version: version ?? this.version,
      tablePartitionMap: tablePartitionMap ?? Map.from(this.tablePartitionMap),
      timestamps: timestamps ?? this.timestamps,
      userSchemaHash: userSchemaHash ?? this.userSchemaHash,
      systemSchemaHash: systemSchemaHash ?? this.systemSchemaHash,
      directoryMapping: directoryMapping ?? this.directoryMapping,
    );
  }

  factory SchemaMeta.fromJson(Map<String, dynamic> json) {
    // Handle backward compatibility: old format had Map<String, List<int>>
    Map<String, int> tablePartitionMap;
    final rawTablePartitionMap = json['tablePartitionMap'];

    if (rawTablePartitionMap is Map<String, dynamic>) {
      tablePartitionMap = <String, int>{};

      for (final entry in rawTablePartitionMap.entries) {
        final key = entry.key;
        final value = entry.value;

        if (value is List) {
          // Old format: Map<String, List<int>> - take the first partition index
          if (value.isNotEmpty && value.first is int) {
            tablePartitionMap[key] = value.first as int;
          }
        } else if (value is int) {
          // New format: Map<String, int>
          tablePartitionMap[key] = value;
        }
      }
    } else {
      tablePartitionMap = <String, int>{};
    }

    DirectoryMapping? directoryMapping;
    if (json['directoryMapping'] != null) {
      directoryMapping = DirectoryMapping.fromJson(
          json['directoryMapping'] as Map<String, dynamic>);
    }

    final legacySchemaHash = json['schemaHash'] as String?;
    final parsedUserSchemaHash =
        json['userSchemaHash'] as String? ?? legacySchemaHash;
    final parsedSystemSchemaHash = json['systemSchemaHash'] as String?;

    return SchemaMeta(
      version: resolveVersionValue(
          json['version'], InternalConfig.legacySchemaVersion),
      tablePartitionMap: tablePartitionMap,
      timestamps:
          Timestamps.fromJson(json['timestamps'] as Map<String, dynamic>),
      userSchemaHash: parsedUserSchemaHash,
      systemSchemaHash: parsedSystemSchemaHash,
      directoryMapping: directoryMapping,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'tablePartitionMap': tablePartitionMap,
      'timestamps': timestamps.toJson(),
      if (userSchemaHash != null) 'userSchemaHash': userSchemaHash,
      if (systemSchemaHash != null) 'systemSchemaHash': systemSchemaHash,
      if (directoryMapping != null)
        'directoryMapping': directoryMapping!.toJson(),
    };
  }

  @override
  String toString() {
    return 'SchemaMeta(version: $version, tablePartitionMap: $tablePartitionMap, timestamps: $timestamps, userSchemaHash: $userSchemaHash, systemSchemaHash: $systemSchemaHash)';
  }
}

/// index meta
class IndexMeta {
  /// index version
  final int version;

  /// index name
  final String name;

  /// table name
  final String tableName;

  /// index fields
  final List<String> fields;

  /// whether the index is unique
  final bool isUnique;

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
    required this.name,
    required this.tableName,
    required this.fields,
    required this.isUnique,
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
  /// [name] - The index name.
  /// [tableName] - The table name this index belongs to.
  /// [fields] - The indexed field names.
  /// [isUnique] - Whether this is a unique index.
  /// [pageSize] - Page size in bytes (default: 16KB).
  /// [partitionCount] - Initial partition count (default: 1).
  /// [now] - Optional timestamp override; uses current time if not provided.
  ///
  /// This is the canonical way to create an initial [IndexMeta] when:
  /// - Creating a new index
  /// - Rebuilding an existing index
  static IndexMeta createEmpty({
    required String name,
    required String tableName,
    required List<String> fields,
    required bool isUnique,
    int pageSize = defaultPageSize,
    int partitionCount = 1,
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now();
    return IndexMeta(
      name: name,
      tableName: tableName,
      fields: fields,
      isUnique: isUnique,
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
    String? name,
    String? tableName,
    List<String>? fields,
    bool? isUnique,
    int? bTreeOrder,
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
      name: name ?? this.name,
      tableName: tableName ?? this.tableName,
      fields: fields ?? List.from(this.fields),
      isUnique: isUnique ?? this.isUnique,
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
    if (json['name'] == null ||
        json['tableName'] == null ||
        json['fields'] == null ||
        json['isUnique'] == null ||
        json['timestamps'] == null ||
        json['btreePageSize'] == null ||
        json['btreeNextPageNo'] == null ||
        json['btreePartitionCount'] == null ||
        json['btreeRoot'] == null ||
        json['btreeFirstLeaf'] == null ||
        json['btreeLastLeaf'] == null ||
        json['btreeHeight'] == null) {
      throw ArgumentError('Missing required fields for IndexMeta (v2+)');
    }

    return IndexMeta(
      version:
          resolveVersionValue(json['version'], InternalConfig.indexVersion),
      name: json['name'] as String,
      tableName: json['tableName'] as String,
      fields: (json['fields'] as List).map((e) => e as String).toList(),
      isUnique: json['isUnique'] as bool,
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
      'name': name,
      'tableName': tableName,
      'fields': fields,
      'isUnique': isUnique,
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
    return 'IndexMeta(version: $version, name: $name, tableName: $tableName, totalSizeInBytes: $totalSizeInBytes, totalEntries: $totalEntries, btreePartitionCount: $btreePartitionCount, btreeHeight: $btreeHeight, btreeRoot: $btreeRoot)';
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
