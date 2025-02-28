/// file meta model
class FileMeta {
  final int version;
  final String type;
  final String name;
  final int size;
  final int records;
  final Timestamps timestamps;
  final ChunkInfo? chunks;

  const FileMeta({
    required this.version,
    required this.type,
    required this.name,
    required this.size,
    required this.records,
    required this.timestamps,
    this.chunks,
  });

  /// deserialize from json
  factory FileMeta.fromJson(Map<String, dynamic> json) {
    return FileMeta(
      version: json['version'] as int,
      type: json['type'] as String,
      name: json['name'] as String,
      size: json['size'] as int,
      records: json['records'] as int,
      timestamps:
          Timestamps.fromJson(json['timestamps'] as Map<String, dynamic>),
      chunks: json['chunks'] != null
          ? ChunkInfo.fromJson(json['chunks'] as Map<String, dynamic>)
          : null,
    );
  }

  /// serialize to json
  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'type': type,
      'name': name,
      'size': size,
      'records': records,
      'timestamps': timestamps.toJson(),
      'chunks': chunks?.toJson(),
    };
  }
}

/// timestamp info
class Timestamps {
  final DateTime created;
  final DateTime modified;
  final DateTime accessed;

  Timestamps({
    required this.created,
    required this.modified,
    required this.accessed,
  });

  factory Timestamps.fromJson(Map<String, dynamic> json) {
    return Timestamps(
      created: DateTime.parse(json['created'] as String),
      modified: DateTime.parse(json['modified'] as String),
      accessed: DateTime.parse(json['accessed'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'created': created.toIso8601String(),
      'modified': modified.toIso8601String(),
      'accessed': accessed.toIso8601String(),
    };
  }
}

/// chunk info
class ChunkInfo {
  final int total;
  final int size;
  final List<int> indexes;
  final int index;

  const ChunkInfo({
    required this.total,
    required this.size,
    required this.indexes,
    required this.index,
  });

  factory ChunkInfo.fromJson(Map<String, dynamic> json) {
    return ChunkInfo(
      total: json['total'] as int,
      size: json['size'] as int,
      indexes: (json['indexes'] as List).cast<int>(),
      index: json['index'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'total': total,
      'size': size,
      'indexes': indexes,
      'index': index,
    };
  }
}
