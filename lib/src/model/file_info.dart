/// file info model
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
  final int totalRecords;
  final Timestamps timestamps;
  final List<PartitionMeta>? partitions;

  /// whether the range is ordered, for query optimization
  /// true: the primary key is ordered in the partition and the range does not overlap between partitions
  /// false: the partition is not ordered or the range overlaps
  /// null: not determined, need to detect
  final bool? isOrdered;

  FileMeta({
    required this.version,
    required this.type,
    required this.name,
    required this.fileSizeInBytes,
    required this.totalRecords,
    required this.timestamps,
    this.partitions,
    this.isOrdered,
  });

  FileMeta copyWith({
    int? version,
    FileType? type,
    String? name,
    int? fileSizeInBytes,
    int? totalRecords,
    Timestamps? timestamps,
    List<PartitionMeta>? partitions,
    bool? isOrdered,
  }) {
    return FileMeta(
      version: version ?? this.version,
      type: type ?? this.type,
      name: name ?? this.name,
      fileSizeInBytes: fileSizeInBytes ?? this.fileSizeInBytes,
      totalRecords: totalRecords ?? this.totalRecords,
      timestamps: timestamps ?? this.timestamps,
      partitions: partitions ?? this.partitions,
      isOrdered: isOrdered ?? this.isOrdered,
    );
  }

  /// deserialize from json
  factory FileMeta.fromJson(Map<String, dynamic> json) {
    if (json['version'] == null ||
        json['type'] == null ||
        json['name'] == null ||
        json['fileSizeInBytes'] == null ||
        json['totalRecords'] == null ||
        json['timestamps'] == null) {
      throw ArgumentError('Missing required fields for FileMeta');
    }
    return FileMeta(
      version: json['version'] is int
          ? json['version'] as int
          : int.parse('${json['version']}'),
      type: FileType.fromString(json['type'] as String),
      name: json['name'] as String,
      fileSizeInBytes: json['fileSizeInBytes'] is int
          ? json['fileSizeInBytes'] as int
          : int.parse('${json['fileSizeInBytes']}'),
      totalRecords: json['totalRecords'] is int
          ? json['totalRecords'] as int
          : int.parse('${json['totalRecords']}'),
      timestamps:
          Timestamps.fromJson(json['timestamps'] as Map<String, dynamic>),
      partitions: json['partitions'] != null
          ? (json['partitions'] as List)
              .map((e) => PartitionMeta.fromJson(e as Map<String, dynamic>))
              .toList()
          : null,
      isOrdered: json['isOrdered'] as bool?,
    );
  }

  /// serialize to json
  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'type': type.key,
      'name': name,
      'fileSizeInBytes': fileSizeInBytes,
      'totalRecords': totalRecords,
      'timestamps': timestamps.toJson(),
      'partitions': partitions?.map((e) => e.toJson()).toList(),
      if (isOrdered != null) 'isOrdered': isOrdered,
    };
  }

  @override
  String toString() =>
      'FileMeta(version: $version, type: ${type.key}, name: $name, fileSizeInBytes: $fileSizeInBytes, totalRecords: $totalRecords, timestamps: $timestamps, partitions: $partitions, isOrdered: $isOrdered)';
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

/// partition file info, including its meta and the actual data records.
class PartitionInfo {
  final String path;
  final PartitionMeta meta;
  final List<dynamic> data;

  PartitionInfo({
    required this.path,
    required this.meta,
    required this.data,
  });

  PartitionInfo copyWith({
    String? path,
    PartitionMeta? meta,
    List<dynamic>? data,
  }) {
    return PartitionInfo(
      path: path ?? this.path,
      meta: meta ?? this.meta,
      data: data ?? this.data,
    );
  }

  factory PartitionInfo.fromJson(Map<String, dynamic> json) {
    if (json['path'] == null || json['meta'] == null || json['data'] == null) {
      throw ArgumentError('Missing required fields for PartitionInfo');
    }
    return PartitionInfo(
      path: json['path'] as String,
      meta: PartitionMeta.fromJson(json['meta'] as Map<String, dynamic>),
      data: json['data'] as List<dynamic>,
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
  String toString() => 'PartitionInfo(path: $path, meta: $meta, data: $data)';
}

class PartitionMeta {
  // The version of the partition meta
  final int version;
  // The index of the partition in the file
  final int index;
  // The number of records stored in this partition file
  final int totalRecords;
  // Size of the data portion of the partition (in bytes)
  final int fileSizeInBytes;
  // The minimum primary key value in this partition
  final dynamic minPrimaryKey;
  // The maximum primary key value in this partition
  final dynamic maxPrimaryKey;
  // Optional checksum for verifying data integrity
  final String? checksum;
  // Timestamps for the partition: created, modified, and accessed (if needed) encapsulated in Timestamps
  final Timestamps timestamps;
  // The parent path of the partition
  final String parentPath;

  PartitionMeta({
    required this.version,
    required this.index,
    required this.totalRecords,
    required this.fileSizeInBytes,
    required this.minPrimaryKey,
    required this.maxPrimaryKey,
    this.checksum,
    required this.timestamps,
    required this.parentPath,
  });

  PartitionMeta copyWith({
    int? version,
    int? index,
    int? totalRecords,
    int? fileSizeInBytes,
    dynamic minPrimaryKey,
    dynamic maxPrimaryKey,
    String? checksum,
    Timestamps? timestamps,
    String? parentPath,
  }) {
    return PartitionMeta(
      version: version ?? this.version,
      index: index ?? this.index,
      totalRecords: totalRecords ?? this.totalRecords,
      fileSizeInBytes: fileSizeInBytes ?? this.fileSizeInBytes,
      minPrimaryKey: minPrimaryKey ?? this.minPrimaryKey,
      maxPrimaryKey: maxPrimaryKey ?? this.maxPrimaryKey,
      checksum: checksum ?? this.checksum,
      timestamps: timestamps ?? this.timestamps,
      parentPath: parentPath ?? this.parentPath,
    );
  }

  factory PartitionMeta.fromJson(Map<String, dynamic> json) {
    if (json['version'] == null ||
        json['index'] == null ||
        json['totalRecords'] == null ||
        json['fileSizeInBytes'] == null ||
        json['timestamps'] == null ||
        json['parentPath'] == null) {
      throw ArgumentError('Missing required fields for ChunkMeta');
    }
    return PartitionMeta(
      version: json['version'] is int
          ? json['version'] as int
          : int.parse('${json['version']}'),
      index: json['index'] is int
          ? json['index'] as int
          : int.parse('${json['index']}'),
      totalRecords: json['totalRecords'] is int
          ? json['totalRecords'] as int
          : int.parse('${json['totalRecords']}'),
      fileSizeInBytes: json['fileSizeInBytes'] is int
          ? json['fileSizeInBytes'] as int
          : int.parse('${json['fileSizeInBytes']}'),
      minPrimaryKey: json['minPrimaryKey'],
      maxPrimaryKey: json['maxPrimaryKey'],
      checksum: json['checksum'] as String?,
      timestamps:
          Timestamps.fromJson(json['timestamps'] as Map<String, dynamic>),
      parentPath: json['parentPath'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'index': index,
      'totalRecords': totalRecords,
      'fileSizeInBytes': fileSizeInBytes,
      'minPrimaryKey': minPrimaryKey,
      'maxPrimaryKey': maxPrimaryKey,
      'checksum': checksum,
      'timestamps': timestamps.toJson(),
      'parentPath': parentPath,
    };
  }

  @override
  String toString() {
    return 'ChunkMeta(version: $version, index: $index, totalRecords: $totalRecords, fileSizeInBytes: $fileSizeInBytes, minPrimaryKey: $minPrimaryKey, maxPrimaryKey: $maxPrimaryKey, checksum: $checksum, timestamps: $timestamps, parentPath: $parentPath)';
  }
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

  /// checksum
  final String? checksum;

  SchemaPartitionMeta({
    required this.version,
    required this.index,
    required this.fileSizeInBytes,
    required this.tableNames,
    required this.tableSizes,
    required this.tableSchemas,
    required this.timestamps,
    this.checksum,
  });

  SchemaPartitionMeta copyWith({
    int? version,
    int? index,
    int? fileSizeInBytes,
    List<String>? tableNames,
    Map<String, int>? tableSizes,
    Map<String, dynamic>? tableSchemas,
    Timestamps? timestamps,
    String? checksum,
  }) {
    return SchemaPartitionMeta(
      version: version ?? this.version,
      index: index ?? this.index,
      fileSizeInBytes: fileSizeInBytes ?? this.fileSizeInBytes,
      tableNames: tableNames ?? List.from(this.tableNames),
      tableSizes: tableSizes ?? Map.from(this.tableSizes),
      tableSchemas: tableSchemas ?? Map.from(this.tableSchemas),
      timestamps: timestamps ?? this.timestamps,
      checksum: checksum ?? this.checksum,
    );
  }

  factory SchemaPartitionMeta.fromJson(Map<String, dynamic> json) {
    return SchemaPartitionMeta(
      version: json['version'] as int,
      index: json['index'] as int,
      fileSizeInBytes: json['fileSizeInBytes'] as int,
      tableNames: List<String>.from(json['tableNames'] as List),
      tableSizes: Map<String, int>.from(json['tableSizes'] as Map),
      tableSchemas: Map<String, dynamic>.from(json['tableSchemas'] as Map),
      timestamps:
          Timestamps.fromJson(json['timestamps'] as Map<String, dynamic>),
      checksum: json['checksum'] as String?,
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
      'checksum': checksum,
    };
  }

  @override
  String toString() {
    return 'SchemaPartitionMeta(version: $version, index: $index, fileSizeInBytes: $fileSizeInBytes, tableNames: $tableNames, tableSizes: $tableSizes, timestamps: $timestamps, checksum: $checksum)';
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

  /// table and partition mapping - key is table name, value is list of partition indexes containing the table
  final Map<String, List<int>> tablePartitionMap;

  /// timestamps
  final Timestamps timestamps;

  /// table schema hash - for automatic structure change detection
  final String? schemaHash;

  SchemaMeta({
    required this.version,
    required this.tablePartitionMap,
    required this.timestamps,
    this.schemaHash,
  });

  SchemaMeta copyWith({
    int? version,
    Map<String, List<int>>? tablePartitionMap,
    Timestamps? timestamps,
    String? schemaHash,
  }) {
    return SchemaMeta(
      version: version ?? this.version,
      tablePartitionMap: tablePartitionMap ?? Map.from(this.tablePartitionMap),
      timestamps: timestamps ?? this.timestamps,
      schemaHash: schemaHash ?? this.schemaHash,
    );
  }

  factory SchemaMeta.fromJson(Map<String, dynamic> json) {
    return SchemaMeta(
      version: json['version'] as int,
      tablePartitionMap:
          (json['tablePartitionMap'] as Map<String, dynamic>).map(
        (key, value) => MapEntry(
          key,
          List<int>.from(value as List),
        ),
      ),
      timestamps:
          Timestamps.fromJson(json['timestamps'] as Map<String, dynamic>),
      schemaHash: json['schemaHash'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'tablePartitionMap': tablePartitionMap,
      'timestamps': timestamps.toJson(),
      if (schemaHash != null) 'schemaHash': schemaHash,
    };
  }

  @override
  String toString() {
    return 'SchemaMeta(version: $version, tablePartitionMap: $tablePartitionMap, timestamps: $timestamps, schemaHash: $schemaHash)';
  }
}

/// index partition meta
class IndexPartitionMeta {
  /// partition version
  final int version;

  /// partition index
  final int index;

  /// current partition file size
  final int fileSizeInBytes;

  /// minimum key value
  final dynamic minKey;

  /// maximum key value
  final dynamic maxKey;

  /// B+tree serialized data size
  final int bTreeSize;

  /// index entries count
  final int entries;

  /// timestamps
  final Timestamps timestamps;

  /// checksum
  final String? checksum;

  IndexPartitionMeta({
    required this.version,
    required this.index,
    required this.fileSizeInBytes,
    required this.minKey,
    required this.maxKey,
    required this.bTreeSize,
    required this.entries,
    required this.timestamps,
    this.checksum,
  });

  IndexPartitionMeta copyWith({
    int? version,
    int? index,
    int? fileSizeInBytes,
    dynamic minKey,
    dynamic maxKey,
    int? bTreeSize,
    int? entries,
    Timestamps? timestamps,
    String? checksum,
  }) {
    return IndexPartitionMeta(
      version: version ?? this.version,
      index: index ?? this.index,
      fileSizeInBytes: fileSizeInBytes ?? this.fileSizeInBytes,
      minKey: minKey ?? this.minKey,
      maxKey: maxKey ?? this.maxKey,
      bTreeSize: bTreeSize ?? this.bTreeSize,
      entries: entries ?? this.entries,
      timestamps: timestamps ?? this.timestamps,
      checksum: checksum ?? this.checksum,
    );
  }

  factory IndexPartitionMeta.fromJson(Map<String, dynamic> json) {
    return IndexPartitionMeta(
      version: json['version'] as int,
      index: json['index'] as int,
      fileSizeInBytes: json['fileSizeInBytes'] as int,
      minKey: json['minKey'],
      maxKey: json['maxKey'],
      bTreeSize: json['bTreeSize'] as int,
      entries: json['entries'] as int,
      timestamps:
          Timestamps.fromJson(json['timestamps'] as Map<String, dynamic>),
      checksum: json['checksum'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'index': index,
      'fileSizeInBytes': fileSizeInBytes,
      'minKey': minKey,
      'maxKey': maxKey,
      'bTreeSize': bTreeSize,
      'entries': entries,
      'timestamps': timestamps.toJson(),
      'checksum': checksum,
    };
  }

  @override
  String toString() {
    return 'IndexPartitionMeta(version: $version, index: $index, fileSizeInBytes: $fileSizeInBytes, minKey: $minKey, maxKey: $maxKey, bTreeSize: $bTreeSize, entries: $entries, timestamps: $timestamps, checksum: $checksum)';
  }
}

/// index partition info
class IndexPartitionInfo {
  final String path;
  final IndexPartitionMeta meta;
  final String bTreeData;

  IndexPartitionInfo({
    required this.path,
    required this.meta,
    required this.bTreeData,
  });

  IndexPartitionInfo copyWith({
    String? path,
    IndexPartitionMeta? meta,
    String? bTreeData,
  }) {
    return IndexPartitionInfo(
      path: path ?? this.path,
      meta: meta ?? this.meta,
      bTreeData: bTreeData ?? this.bTreeData,
    );
  }

  factory IndexPartitionInfo.fromJson(Map<String, dynamic> json) {
    return IndexPartitionInfo(
      path: json['path'] as String,
      meta: IndexPartitionMeta.fromJson(json['meta'] as Map<String, dynamic>),
      bTreeData: json['bTreeData'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'path': path,
      'meta': meta.toJson(),
      'bTreeData': bTreeData,
    };
  }

  @override
  String toString() {
    return 'IndexPartitionInfo(path: $path, meta: $meta, bTreeData: $bTreeData)';
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

  /// B+tree order
  final int bTreeOrder;

  /// partition list
  final List<IndexPartitionMeta> partitions;

  /// timestamps
  final Timestamps timestamps;

  /// whether the index is ordered, for range query optimization
  final bool? isOrdered;

  IndexMeta({
    required this.version,
    required this.name,
    required this.tableName,
    required this.fields,
    required this.isUnique,
    required this.bTreeOrder,
    required this.partitions,
    required this.timestamps,
    this.isOrdered,
  });

  IndexMeta copyWith({
    int? version,
    String? name,
    String? tableName,
    List<String>? fields,
    bool? isUnique,
    int? bTreeOrder,
    List<IndexPartitionMeta>? partitions,
    Timestamps? timestamps,
    bool? isOrdered,
  }) {
    return IndexMeta(
      version: version ?? this.version,
      name: name ?? this.name,
      tableName: tableName ?? this.tableName,
      fields: fields ?? List.from(this.fields),
      isUnique: isUnique ?? this.isUnique,
      bTreeOrder: bTreeOrder ?? this.bTreeOrder,
      partitions: partitions ?? List.from(this.partitions),
      timestamps: timestamps ?? this.timestamps,
      isOrdered: isOrdered ?? this.isOrdered,
    );
  }

  factory IndexMeta.fromJson(Map<String, dynamic> json) {
    return IndexMeta(
      version: json['version'] as int,
      name: json['name'] as String,
      tableName: json['tableName'] as String,
      fields: (json['fields'] as List).map((e) => e as String).toList(),
      isUnique: json['isUnique'] as bool,
      bTreeOrder: json['bTreeOrder'] as int,
      partitions: (json['partitions'] as List)
          .map((e) => IndexPartitionMeta.fromJson(e as Map<String, dynamic>))
          .toList(),
      timestamps:
          Timestamps.fromJson(json['timestamps'] as Map<String, dynamic>),
      isOrdered: json['isOrdered'] as bool?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'name': name,
      'tableName': tableName,
      'fields': fields,
      'isUnique': isUnique,
      'bTreeOrder': bTreeOrder,
      'partitions': partitions.map((e) => e.toJson()).toList(),
      'timestamps': timestamps.toJson(),
      if (isOrdered != null) 'isOrdered': isOrdered,
    };
  }

  @override
  String toString() {
    return 'IndexMeta(version: $version, name: $name, tableName: $tableName, fields: $fields, isUnique: $isUnique, bTreeOrder: $bTreeOrder, partitions: $partitions, timestamps: $timestamps, isOrdered: $isOrdered)';
  }
}
