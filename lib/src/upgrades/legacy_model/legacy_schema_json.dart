import 'dart:convert';

/// Hand-parsers for 3.1.2-era schema JSON (`schema_meta.json` + partition files).
///
/// Do **not** use current [SchemaMeta.fromJson] — the on-disk shape used
/// `tablePartitionMap` / `directoryMapping` / `tableSchemas` keyed by tableName,
/// with no `routes` or `tableFieldLayouts`.
class LegacySchemaMetaJson {
  LegacySchemaMetaJson._();

  /// Parse `schemas/schema_meta.json` content. Returns null if empty/invalid.
  static LegacySchemaMetaSnapshot? tryParse(String content) {
    if (content.isEmpty) return null;
    try {
      final json = jsonDecode(content);
      if (json is! Map) return null;
      return fromMap(Map<String, dynamic>.from(json));
    } catch (_) {
      return null;
    }
  }

  static LegacySchemaMetaSnapshot fromMap(Map<String, dynamic> json) {
    final tablePartitionMap = <String, int>{};
    final rawMap = json['tablePartitionMap'];
    if (rawMap is Map) {
      for (final entry in rawMap.entries) {
        final key = entry.key.toString();
        final value = entry.value;
        if (value is int) {
          tablePartitionMap[key] = value;
        } else if (value is List && value.isNotEmpty && value.first is int) {
          // Very old format: Map<String, List<int>>
          tablePartitionMap[key] = value.first as int;
        } else if (value is num) {
          tablePartitionMap[key] = value.toInt();
        }
      }
    }

    final partitionToDir = <int, int>{};
    final dm = json['directoryMapping'];
    if (dm is Map) {
      final p2d = dm['partitionToDir'];
      if (p2d is Map) {
        for (final e in p2d.entries) {
          final p = int.tryParse(e.key.toString());
          final d = e.value;
          if (p != null && d is num) {
            partitionToDir[p] = d.toInt();
          }
        }
      }
    }

    DateTime? createdAt;
    final timestamps = json['timestamps'];
    if (timestamps is Map && timestamps['created'] != null) {
      try {
        createdAt = DateTime.parse(timestamps['created'].toString());
      } catch (_) {}
    }

    return LegacySchemaMetaSnapshot(
      version: (json['version'] as num?)?.toInt(),
      tablePartitionMap: tablePartitionMap,
      partitionToDir: partitionToDir,
      userSchemaHash: json['userSchemaHash'] as String?,
      systemSchemaHash: json['systemSchemaHash'] as String?,
      createdAt: createdAt,
    );
  }
}

/// Snapshot of 3.1.2 `schema_meta.json` fields needed by v3 upgrade.
class LegacySchemaMetaSnapshot {
  final int? version;
  final Map<String, int> tablePartitionMap;
  final Map<int, int> partitionToDir;
  final String? userSchemaHash;
  final String? systemSchemaHash;
  final DateTime? createdAt;

  const LegacySchemaMetaSnapshot({
    this.version,
    required this.tablePartitionMap,
    required this.partitionToDir,
    this.userSchemaHash,
    this.systemSchemaHash,
    this.createdAt,
  });
}

/// Hand-parser for a single schema partition file (`schema_pN.json`).
class LegacySchemaPartitionJson {
  LegacySchemaPartitionJson._();

  /// Parse partition content. Null if empty/invalid.
  static LegacySchemaPartitionSnapshot? tryParse(String content) {
    if (content.isEmpty) return null;
    try {
      final json = jsonDecode(content);
      if (json is! Map) return null;
      final map = Map<String, dynamic>.from(json);
      final raw = map['tableSchemas'];
      final out = <String, Map<String, dynamic>>{};
      if (raw is Map) {
        for (final e in raw.entries) {
          final v = e.value;
          if (v is Map) {
            out[e.key.toString()] = Map<String, dynamic>.from(v);
          }
        }
      }
      DateTime? createdAt;
      final timestamps = map['timestamps'];
      if (timestamps is Map && timestamps['created'] != null) {
        try {
          createdAt = DateTime.parse(timestamps['created'].toString());
        } catch (_) {}
      }
      return LegacySchemaPartitionSnapshot(
        tableSchemas: out,
        createdAt: createdAt,
      );
    } catch (_) {
      return null;
    }
  }

  /// Returns tableName → raw schema JSON map. Null if empty/invalid.
  static Map<String, Map<String, dynamic>>? tryParseTableSchemas(
      String content) {
    return tryParse(content)?.tableSchemas;
  }
}

/// Snapshot of one 3.1.2 schema partition file.
class LegacySchemaPartitionSnapshot {
  final Map<String, Map<String, dynamic>> tableSchemas;
  final DateTime? createdAt;

  const LegacySchemaPartitionSnapshot({
    required this.tableSchemas,
    this.createdAt,
  });
}
