import 'dart:convert';

import '../../core/data_store_impl.dart';
import '../../handler/common.dart';
import '../../handler/logger.dart';
import '../../handler/weight_snapshot_codec.dart';
import '../../model/global_config.dart';
import '../../model/space_config.dart';
import '../../model/table_identity.dart';
import '../../model/transaction_models.dart';
import '../../model/weight_data.dart';

/// On-disk formats retired by the engine **v3** blocking upgrade.
///
/// ## Naming convention (`legacy_model/`)
/// - Keep this directory; do **not** scatter one-off parsers across upgrades/.
/// - One file per *source* era that a major upgrade must still read:
///   - [pre_v3.dart] — formats before engineVersion 3 (JSON configs, schema
///     partitions, NDJSON txn logs, cache_weights.json). Consumed by `V3Upgrade`
///     / format migrations.
///   - Future: `pre_v4.dart`, `pre_v7.dart`, … when that upgrade lands.
/// - Prefer `pre_vN` over open ranges (`v3_to_v6`): each major upgrade owns
///   exactly the formats it retires. If v6 must read v3-era TOBF that v6
///   itself replaces, put those parsers in `pre_v6.dart`.
/// - Not part of the public package API (`lib/src` only).
///
/// Hot path must never depend on these types for steady-state IO.

// ---------------------------------------------------------------------------
// Config paths + bootstrap (global_config.json / space_config.json)
// ---------------------------------------------------------------------------

/// Legacy JSON config filenames — construct paths only inside upgrades/.
abstract final class LegacyConfigPaths {
  LegacyConfigPaths._();

  static const String globalFileName = 'global_config.json';
  static const String spaceFileName = 'space_config.json';

  static String globalJson(String instancePath) =>
      pathJoin(instancePath, globalFileName);

  static String spaceJson(String instancePath, String spaceName) =>
      pathJoin(instancePath, 'spaces', spaceName, spaceFileName);
}

/// Read-only loaders for pre-TOBF JSON configs.
///
/// Used by the hot path **only** when `*.tobf` is absent (pre-v3 databases),
/// and by V3 to consume `tableDirectoryMap` before JSON is deleted.
/// Never writes TOBF and never deletes JSON (except explicit delete helpers
/// called from V3 finalize).
final class LegacyConfigBootstrap {
  LegacyConfigBootstrap._();

  static Future<GlobalConfig?> readGlobalConfig(DataStoreImpl dataStore) async {
    final root = dataStore.instancePath;
    if (root == null) return null;
    final jsonPath = LegacyConfigPaths.globalJson(root);
    if (!await dataStore.storage.existsFile(jsonPath)) return null;
    final content = await dataStore.storage.readAsString(jsonPath);
    return LegacyGlobalConfigJson.tryParse(content ?? '');
  }

  static Future<SpaceConfig?> readSpaceConfig(
    DataStoreImpl dataStore, {
    required String spaceName,
  }) async {
    final root = dataStore.instancePath;
    if (root == null) return null;
    final jsonPath = LegacyConfigPaths.spaceJson(root, spaceName);
    if (!await dataStore.storage.existsFile(jsonPath)) return null;
    final content = await dataStore.storage.readAsString(jsonPath);
    return LegacySpaceConfigJson.tryParse(content ?? '');
  }

  /// Raw JSON map (preserves `tableDirectoryMap` / `directoryUsageMap`).
  static Future<Map<String, dynamic>?> readGlobalJsonMap(
    DataStoreImpl dataStore,
  ) async {
    final root = dataStore.instancePath;
    if (root == null) return null;
    final jsonPath = LegacyConfigPaths.globalJson(root);
    if (!await dataStore.storage.existsFile(jsonPath)) return null;
    final content = await dataStore.storage.readAsString(jsonPath);
    return LegacyGlobalConfigJson.tryParseMap(content ?? '');
  }

  /// Raw JSON map (preserves `tableDirectoryMap` / `directoryUsageMap`).
  static Future<Map<String, dynamic>?> readSpaceJsonMap(
    DataStoreImpl dataStore, {
    required String spaceName,
  }) async {
    final root = dataStore.instancePath;
    if (root == null) return null;
    final jsonPath = LegacyConfigPaths.spaceJson(root, spaceName);
    if (!await dataStore.storage.existsFile(jsonPath)) return null;
    final content = await dataStore.storage.readAsString(jsonPath);
    return LegacySpaceConfigJson.tryParseMap(content ?? '');
  }

  static Future<void> deleteGlobalJson(DataStoreImpl dataStore) async {
    final root = dataStore.instancePath;
    if (root == null) return;
    final jsonPath = LegacyConfigPaths.globalJson(root);
    if (await dataStore.storage.existsFile(jsonPath)) {
      await dataStore.storage.deleteFile(jsonPath);
      Logger.info('Deleted legacy $jsonPath after TOBF finalize');
    }
  }

  static Future<void> deleteSpaceJson(
    DataStoreImpl dataStore, {
    required String spaceName,
  }) async {
    final root = dataStore.instancePath;
    if (root == null) return;
    final jsonPath = LegacyConfigPaths.spaceJson(root, spaceName);
    if (await dataStore.storage.existsFile(jsonPath)) {
      await dataStore.storage.deleteFile(jsonPath);
      Logger.info('Deleted legacy $jsonPath after TOBF finalize');
    }
  }
}

/// Legacy JSON parser for pre-TOBF `global_config.json`.
final class LegacyGlobalConfigJson {
  LegacyGlobalConfigJson._();

  static GlobalConfig? tryParse(String content) {
    final map = tryParseMap(content);
    if (map == null) return null;
    try {
      return fromMap(map);
    } catch (_) {
      return null;
    }
  }

  /// Raw map so V3 can read `tableDirectoryMap` (dropped from the live model).
  static Map<String, dynamic>? tryParseMap(String content) {
    if (content.isEmpty) return null;
    try {
      final decoded = jsonDecode(content);
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  static GlobalConfig fromMap(Map<String, dynamic> json) {
    final rawPageSize = json['pageSize'];
    return GlobalConfig(
      version: resolveVersionValue(
          json['version'], InternalConfig.legacyEngineVersion),
      userVersion: resolveVersionValue(json['userVersion'], 0),
      maxEntriesPerDir: resolveVersionValue(
          json['maxEntriesPerDir'], InternalConfig.defaultMaxEntriesPerDir),
      // Missing key → 0 (unset), must NOT default here or v3 loses the signal
      // to sample page size from existing table meta.
      pageSize: rawPageSize == null ? 0 : (rawPageSize as num).toInt(),
      spaceNames: (json['spaceNames'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toSet() ??
          {'default'},
      activeSpace: json['activeSpace'] as String? ?? 'default',
      hasMigrationTask: json['hasMigrationTask'] as bool? ?? false,
      userSchemaHash: json['userSchemaHash'] as String?,
      systemSchemaHash: json['systemSchemaHash'] as String?,
      lastGlobalDirIndex: (json['lastGlobalDirIndex'] as num?)?.toInt() ?? 0,
      lastGlobalDirEntries:
          (json['lastGlobalDirEntries'] as num?)?.toInt() ?? 0,
      lastNonGlobalDirIndex:
          (json['lastNonGlobalDirIndex'] as num?)?.toInt() ?? 0,
      lastNonGlobalDirEntries:
          (json['lastNonGlobalDirEntries'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Legacy JSON parser for pre-TOBF `space_config.json`.
final class LegacySpaceConfigJson {
  LegacySpaceConfigJson._();

  static SpaceConfig? tryParse(String content) {
    final map = tryParseMap(content);
    if (map == null) return null;
    try {
      return fromMap(map);
    } catch (_) {
      return null;
    }
  }

  /// Raw map so V3 can read `tableDirectoryMap` (dropped from the live model).
  static Map<String, dynamic>? tryParseMap(String content) {
    if (content.isEmpty) return null;
    try {
      final decoded = jsonDecode(content);
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  static SpaceConfig fromMap(Map<String, dynamic> json) {
    return SpaceConfig(
      current:
          EncryptionKeyInfo.fromJson(json['current'] as Map<String, dynamic>),
      previous: json['previous'] != null
          ? EncryptionKeyInfo.fromJson(json['previous'] as Map<String, dynamic>)
          : null,
      historyKeys: json['historyKeys'] != null
          ? (json['historyKeys'] as List<dynamic>)
              .map((e) => EncryptionKeyInfo.fromJson(e as Map<String, dynamic>))
              .toList()
          : null,
      version: resolveVersionValue(
          json['version'], InternalConfig.legacyEngineVersion),
      totalTableCount: json['totalTableCount'] as int? ?? 0,
      totalRecordCount: json['totalRecordCount'] as int? ?? 0,
      totalDataSizeBytes: json['totalDataSizeBytes'] as int? ?? 0,
      lastStatisticsTime: json['lastStatisticsTime'] != null
          ? DateTime.parse(json['lastStatisticsTime'] as String)
          : null,
    );
  }
}

// ---------------------------------------------------------------------------
// Schema meta / partitions (schema_meta.json, schema_pN.json)
// ---------------------------------------------------------------------------

/// Hand-parsers for 3.1.2-era schema JSON (`schema_meta.json` + partition files).
///
/// Do **not** use current SchemaMeta.fromJson — the on-disk shape used
/// `tablePartitionMap` / `directoryMapping` / `tableSchemas` keyed by tableName.
final class LegacySchemaMetaJson {
  LegacySchemaMetaJson._();

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
final class LegacySchemaPartitionJson {
  LegacySchemaPartitionJson._();

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

// ---------------------------------------------------------------------------
// Transaction logs (NDJSON tx_*.log / status.log)
// ---------------------------------------------------------------------------

/// Legacy NDJSON parsers for pre-binary transaction logs.
final class LegacyTxnJson {
  LegacyTxnJson._();

  static Map<String, dynamic>? parseLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return null;
    try {
      final obj = jsonDecode(trimmed);
      if (obj is Map<String, dynamic>) return obj;
      if (obj is Map) return Map<String, dynamic>.from(obj);
      return null;
    } catch (_) {
      return null;
    }
  }

  static TransactionCommitPlan commitPlanFromJson(Map<String, dynamic> json) {
    return TransactionCommitPlan(
      transactionId: json['transactionId'] as String,
      inserts: _tableRecordsMap(json['inserts']),
      updates: _tableRecordsMap(json['updates']),
      deletes: _tableRecordsMap(json['deletes']),
      heavyDeletes: (json['heavyDeletes'] as List?)
              ?.map((e) =>
                  heavyDeleteFromJson((e as Map).cast<String, dynamic>()))
              .toList() ??
          const <HeavyDeletePlan>[],
      heavyUpdates: (json['heavyUpdates'] as List?)
              ?.map((e) =>
                  heavyUpdateFromJson((e as Map).cast<String, dynamic>()))
              .toList() ??
          const <HeavyUpdatePlan>[],
    );
  }

  static HeavyDeletePlan heavyDeleteFromJson(Map<String, dynamic> json) {
    return HeavyDeletePlan(
      tableUid: TableUid((json['tableUid'] ?? json['tableName']) as String),
      condition: (json['condition'] as Map).cast<String, dynamic>(),
      orderBy: (json['orderBy'] as List?)?.cast<String>(),
      limit: (json['limit'] as num?)?.toInt(),
      offset: (json['offset'] as num?)?.toInt(),
    );
  }

  static HeavyUpdatePlan heavyUpdateFromJson(Map<String, dynamic> json) {
    return HeavyUpdatePlan(
      tableUid: TableUid((json['tableUid'] ?? json['tableName']) as String),
      condition: (json['condition'] as Map).cast<String, dynamic>(),
      updateData: (json['updateData'] as Map).cast<String, dynamic>(),
      orderBy: (json['orderBy'] as List?)?.cast<String>(),
      limit: (json['limit'] as num?)?.toInt(),
      offset: (json['offset'] as num?)?.toInt(),
    );
  }

  static Map<String, List<Map<String, dynamic>>> _tableRecordsMap(dynamic raw) {
    if (raw is! Map) return <String, List<Map<String, dynamic>>>{};
    return raw.map((k, v) => MapEntry(
          k.toString(),
          (v as List).map((e) => (e as Map).cast<String, dynamic>()).toList(),
        ));
  }

  static ({
    String transactionId,
    TxnLogEventType event,
    int timestampMs,
    TransactionCommitPlan? plan,
    int? nextPartitionIndex,
    int? continuedTo,
    Map<String, int>? insertsApplied,
    Map<String, int>? updatesApplied,
    Map<String, int>? deletesApplied,
  })? eventFieldsFromJson(Map<String, dynamic> obj) {
    final txId = obj['transactionId'] as String?;
    final event = TxnLogEventType.fromWireName(obj['event'] as String?);
    if (txId == null || event == null) return null;

    int timestampMs = DateTime.now().millisecondsSinceEpoch;
    final ts = obj['timestamp'];
    if (ts is String) {
      try {
        timestampMs = DateTime.parse(ts).millisecondsSinceEpoch;
      } catch (_) {}
    } else if (ts is int) {
      timestampMs = ts;
    }

    TransactionCommitPlan? plan;
    if (event == TxnLogEventType.plan && obj['plan'] is Map) {
      plan = commitPlanFromJson((obj['plan'] as Map).cast<String, dynamic>());
    }

    Map<String, int>? asIntMap(dynamic raw) {
      if (raw is! Map) return null;
      return raw.map((k, v) => MapEntry(k.toString(), (v as num).toInt()));
    }

    return (
      transactionId: txId,
      event: event,
      timestampMs: timestampMs,
      plan: plan,
      nextPartitionIndex: (obj['nextPartitionIndex'] as num?)?.toInt(),
      continuedTo: (obj['continuedTo'] as num?)?.toInt(),
      insertsApplied: asIntMap(obj['insertsApplied']),
      updatesApplied: asIntMap(obj['updatesApplied']),
      deletesApplied: asIntMap(obj['deletesApplied']),
    );
  }
}

// ---------------------------------------------------------------------------
// Cache weights (cache_weights.json → internal KV)
// ---------------------------------------------------------------------------

/// Legacy weight JSON path — construct only inside upgrades/.
abstract final class LegacyWeightPaths {
  LegacyWeightPaths._();

  static const String fileName = 'cache_weights.json';

  static String spaceJson(String instancePath, String spaceName) =>
      pathJoin(instancePath, 'spaces', spaceName, fileName);
}

/// Parser for pre-KV `cache_weights.json` (consumed only by [WeightFormatMigration]).
final class LegacyCacheWeightsJson {
  LegacyCacheWeightsJson._();

  static WeightSnapshot? tryParse(String content) {
    if (content.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(content);
      if (decoded is! Map) return null;
      return fromMap(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }

  static WeightSnapshot fromMap(Map<String, dynamic> json) {
    final tableRecord = <TableUid, WeightData>{};
    final rawTables = json['tableRecord'];
    if (rawTables is Map) {
      rawTables.forEach((key, value) {
        if (key is! String) return;
        final entry = _weightDataFromJson(value);
        if (entry != null) tableRecord[TableUid(key)] = entry;
      });
    }

    final indexData = <String, WeightData>{};
    final rawIndexes = json['indexData'];
    if (rawIndexes is Map) {
      rawIndexes.forEach((key, value) {
        if (key is! String) return;
        final entry = _weightDataFromJson(value);
        if (entry != null) indexData[key] = entry;
      });
    }

    return WeightSnapshot(
      tableRecord: tableRecord,
      indexData: indexData,
      lastDecayTime: (json['lastDecayTime'] as num?)?.toInt() ?? 0,
      indexDataKeyFormatIsUid: json['indexDataKeyFormat'] == 'indexUid',
    );
  }

  static WeightData? _weightDataFromJson(dynamic value) {
    Map<String, dynamic>? map;
    if (value is Map<String, dynamic>) {
      map = value;
    } else if (value is Map) {
      map = Map<String, dynamic>.from(value);
    }
    if (map == null) return null;
    return WeightData(
      weight: (map['weight'] as num?)?.toInt() ?? 0,
      accessCount: (map['accessCount'] as num?)?.toInt() ?? 0,
      lastUpdateTime: (map['lastUpdateTime'] as num?)?.toInt() ?? 0,
      neverDecay: map['neverDecay'] as bool? ?? false,
      customWeight: (map['customWeight'] as num?)?.toInt(),
    );
  }
}
