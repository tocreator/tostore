import 'dart:convert';
import 'package:path/path.dart' as path;
import '../core/data_store_impl.dart';
import '../handler/common.dart';
import '../handler/logger.dart';
import '../model/global_config.dart';
import '../model/table_schema.dart';
import '../model/table_context.dart';
import '../model/table_identity.dart';
import '../model/meta_info.dart';
import '../handler/space_manifest_codec.dart';
import '../model/space_manifest.dart';
import '../model/id_generator.dart';

/// Version 3 upgrade:
/// - Restructures storage directory names from physical table/index names to stable UIDs.
/// - Migrates TableMeta/IndexMeta files on disk.
/// - Writes `space_manifest.bin` deferred space metadata.
/// - Bumps version config markers and cleans up legacy map properties.
class V3Upgrade {
  final DataStoreImpl _dataStore;

  V3Upgrade(this._dataStore);

  Future<void> execute(GlobalConfig oldGlobalConfig,
      {bool skipVersionBump = false}) async {
    Logger.info(
      'Starting database upgrade to version 3',
    );

    final schemaMetaPath = _dataStore.pathManager.getSchemaMetaPath();
    final schemaMetaPathOld = '$schemaMetaPath.old';

    // Recovery from previous crash: restore old schema_meta if present
    if (await _dataStore.storage.existsFile(schemaMetaPathOld)) {
      Logger.info(
          'Recovering schema metadata from previous crashed v3 upgrade run');
      if (await _dataStore.storage.existsFile(schemaMetaPath)) {
        await _dataStore.storage.deleteFile(schemaMetaPath);
      }
      await _dataStore.storage.copyFile(schemaMetaPathOld, schemaMetaPath);
    }

    Map<String, int> tablePartitionMap = {};
    Map<int, int> partitionToDir = {};
    String? userSchemaHash;
    String? systemSchemaHash;
    DateTime createdTime = DateTime.now();

    if (await _dataStore.storage.existsFile(schemaMetaPath)) {
      final content = await _dataStore.storage.readAsString(schemaMetaPath);
      if (content != null && content.isNotEmpty) {
        try {
          final json = jsonDecode(content) as Map<String, dynamic>;
          if (json.containsKey('tablePartitionMap')) {
            final map = json['tablePartitionMap'] as Map<String, dynamic>;
            tablePartitionMap = map.map((k, v) => MapEntry(k, v as int));
          }
          if (json.containsKey('directoryMapping')) {
            final dm = json['directoryMapping'] as Map<String, dynamic>;
            if (dm.containsKey('partitionToDir')) {
              final p2d = dm['partitionToDir'] as Map<String, dynamic>;
              partitionToDir =
                  p2d.map((k, v) => MapEntry(int.parse(k), v as int));
            }
          }
          userSchemaHash = json['userSchemaHash'] as String?;
          systemSchemaHash = json['systemSchemaHash'] as String?;
          if (json['timestamps'] != null &&
              json['timestamps']['created'] != null) {
            createdTime =
                DateTime.parse(json['timestamps']['created'] as String);
          }
        } catch (e) {
          Logger.warn('Failed to parse old schema meta in v3 upgrade',
              rawError: e);
        }
      }
      // Backup old schema_meta.json before modifying it so we can recover on crash
      if (!await _dataStore.storage.existsFile(schemaMetaPathOld)) {
        await _dataStore.storage.copyFile(schemaMetaPath, schemaMetaPathOld);
      }

      // Construct a new, empty-routes SchemaMeta in the new format but preserving hashes/timestamps
      final emptySchemaMeta = SchemaMeta(
        version: InternalConfig.schemaVersion,
        routes: const [],
        userSchemaHash: userSchemaHash,
        systemSchemaHash: systemSchemaHash,
        timestamps: Timestamps(
          created: createdTime,
          modified: DateTime.now(),
        ),
      );

      // Overwrite schema_meta.json with the empty new-format layout
      await _dataStore.storage
          .writeAsString(schemaMetaPath, jsonEncode(emptySchemaMeta.toJson()));

      // Invalidate the cache inside schemaManager so it loads the new file on next read
      _dataStore.schemaManager?.invalidateCache();
    }

    // 2. Read legacy global config mapping
    final globalConfigPath = _dataStore.pathManager.getGlobalConfigPath();
    Map<String, dynamic>? globalJson;
    if (await _dataStore.storage.existsFile(globalConfigPath)) {
      final content = await _dataStore.storage.readAsString(globalConfigPath);
      if (content != null && content.isNotEmpty) {
        globalJson = jsonDecode(content) as Map<String, dynamic>?;
      }
    }
    final globalTableDirMap = globalJson != null
        ? (globalJson['tableDirectoryMap'] as Map<String, dynamic>?)
        : null;

    final spaces = oldGlobalConfig.spaceNames.isNotEmpty
        ? oldGlobalConfig.spaceNames.toList()
        : <String>['default'];

    // Read legacy space configs directory mappings
    final spaceTableDirMaps = <String, Map<String, dynamic>>{};
    for (final spaceName in spaces) {
      final spaceConfigPath =
          _dataStore.pathManager.getSpaceConfigPath(spaceName: spaceName);
      if (await _dataStore.storage.existsFile(spaceConfigPath)) {
        final content = await _dataStore.storage.readAsString(spaceConfigPath);
        if (content != null && content.isNotEmpty) {
          final spaceJson = jsonDecode(content) as Map<String, dynamic>;
          if (spaceJson.containsKey('tableDirectoryMap')) {
            spaceTableDirMaps[spaceName] =
                spaceJson['tableDirectoryMap'] as Map<String, dynamic>;
          }
        }
      }
    }

    // Map to keep track of generated tableUid and indexUids per tableName
    final tableUidMap = <String, String>{};
    final tableIndexUidMap = <String, Map<String, String>>{};
    final tableIsGlobalMap = <String, bool>{};
    final tableDirIndexMap = <String, int>{};
    final nonGlobalUsage = <int, int>{};
    final globalUsage = <int, int>{};

    int allocateDirIndex(bool isGlobal) {
      final usage = isGlobal ? globalUsage : nonGlobalUsage;
      int selectedDir = 0;
      int minCount = _dataStore.maxEntriesPerDir + 1;

      for (final dir in usage.keys) {
        final count = usage[dir] ?? 0;
        if (count < minCount && count < _dataStore.maxEntriesPerDir) {
          selectedDir = dir;
          minCount = count;
        }
      }

      if (minCount >= _dataStore.maxEntriesPerDir) {
        int maxDir = -1;
        for (final dir in usage.keys) {
          if (dir > maxDir) maxDir = dir;
        }
        selectedDir = maxDir + 1;
      }

      usage[selectedDir] = (usage[selectedDir] ?? 0) + 1;
      return selectedDir;
    }

    // 3. Upgrade table schemas
    for (final tableName in tablePartitionMap.keys) {
      final partitionIndex = tablePartitionMap[tableName]!;
      final dirIndex = partitionToDir[partitionIndex] ??
          (partitionIndex ~/ _dataStore.maxEntriesPerDir);
      final partitionPath = _dataStore.pathManager
          .getSchemaPartitionFilePath(partitionIndex, dirIndex);

      if (await _dataStore.storage.existsFile(partitionPath)) {
        final content = await _dataStore.storage.readAsString(partitionPath);
        if (content != null && content.isNotEmpty) {
          try {
            final json = jsonDecode(content) as Map<String, dynamic>;
            final tableSchemas = json['tableSchemas'] as Map<String, dynamic>?;
            if (tableSchemas != null && tableSchemas.containsKey(tableName)) {
              final schemaJson =
                  tableSchemas[tableName] as Map<String, dynamic>;
              final schema = TableSchema.fromJson(schemaJson);

              // Generate stable tableUid
              final tableUid = TableUid(GlobalIdGenerator.generate("t"));
              tableUidMap[tableName] = tableUid.value;
              tableIsGlobalMap[tableName] = schema.isGlobal;

              // Generate autoIndexes and populate indexes with stable UIDs
              var upgradedSchema = schema.generateAutoIndexes();
              upgradedSchema = upgradedSchema.copyWith(
                tableUid: tableUid,
                schemaVersion:
                    schema.schemaVersion ?? GlobalIdGenerator.generate("s"),
              );

              // Map generated indexUids for directory rename
              final idxUidMap = <String, String>{};
              for (final idx in upgradedSchema.getAllIndexes()) {
                if (idx.indexUid.isNotEmpty) {
                  idxUidMap[idx.actualIndexName] = idx.indexUid;
                }
              }
              tableIndexUidMap[tableName] = idxUidMap;

              final finalDirIndex = allocateDirIndex(schema.isGlobal);
              tableDirIndexMap[tableName] = finalDirIndex;

              final tableCtx = TableContext(
                tableUid: TableUid(tableUid),
                tableName: TableName(tableName),
                isGlobal: upgradedSchema.isGlobal,
                dataDirIndex: finalDirIndex,
                schema: upgradedSchema,
              );

              // Save the upgraded schema via the new schema manager
              await _dataStore.schemaManager!.saveTableSchema(
                tableCtx,
                upgradedSchema,
                dataDirIndex: finalDirIndex,
              );
            }
          } catch (e) {
            Logger.error(
                'Failed to upgrade schema for table $tableName in v3 upgrade',
                rawError: e);
          }
        }
      }
    }

    // 4. Move physical folders and rewrite metadata files for tables
    for (final tableName in tableUidMap.keys) {
      final tableUid = tableUidMap[tableName]!;
      final isGlobal = tableIsGlobalMap[tableName] ?? false;
      final finalDirIndex = tableDirIndexMap[tableName] ?? 0;
      final indexUidMap = tableIndexUidMap[tableName] ?? {};

      if (isGlobal) {
        // Move global table directory
        int? oldGlobalDirIndex;
        if (globalTableDirMap != null) {
          final entry = globalTableDirMap['global:$tableName'];
          if (entry is Map<String, dynamic>) {
            oldGlobalDirIndex = entry['dirIndex'] as int?;
          }
        }
        final actualOldGlobalDirIndex = oldGlobalDirIndex ?? 0;

        final oldGlobalPath = path.join(
            _dataStore.config.dbPath!,
            _dataStore.config.dbName,
            'tables_$actualOldGlobalDirIndex',
            tableName);
        final newGlobalPath = path.join(_dataStore.config.dbPath!,
            _dataStore.config.dbName, 'tables_$finalDirIndex', tableUid);
        await _migrateTableDirectory(
            oldGlobalPath, newGlobalPath, tableUid, indexUidMap);
      } else {
        // Move space table directories across all spaces
        for (final spaceName in spaces) {
          final spaceTableDirMap = spaceTableDirMaps[spaceName];
          int? oldSpaceDirIndex;
          if (spaceTableDirMap != null) {
            final entry = spaceTableDirMap['$spaceName:$tableName'];
            if (entry is Map<String, dynamic>) {
              oldSpaceDirIndex = entry['dirIndex'] as int?;
            }
          }
          final actualOldDirIndex = oldSpaceDirIndex ?? 0;

          final oldSpacePath = path.join(
              _dataStore.config.dbPath!,
              _dataStore.config.dbName,
              'spaces',
              spaceName,
              'tables_$actualOldDirIndex',
              tableName);
          final newSpacePath = path.join(
              _dataStore.config.dbPath!,
              _dataStore.config.dbName,
              'spaces',
              spaceName,
              'tables_$finalDirIndex',
              tableUid);
          await _migrateTableDirectory(
              oldSpacePath, newSpacePath, tableUid, indexUidMap);
        }
      }
    }

    // 5. Construct and write space_manifest.bin per space
    for (final spaceName in spaces) {
      final spaceTableUids = <TableUid>[];
      final map = spaceTableDirMaps[spaceName];
      if (map != null) {
        for (final key in map.keys) {
          final prefix = '$spaceName:';
          if (!key.startsWith(prefix)) continue;
          final tableName = key.substring(prefix.length);
          final isGlobal = tableIsGlobalMap[tableName] ?? false;
          if (isGlobal) {
            continue; // global tables are excluded from space statistics
          }
          final tableUid = tableUidMap[tableName];
          if (tableUid != null) {
            spaceTableUids.add(TableUid(tableUid));
          }
        }
      }
      final manifestPath =
          _dataStore.pathManager.getSpaceManifestPath(spaceName);
      await _dataStore.storage
          .ensureDirectoryExists(path.dirname(manifestPath));
      await _dataStore.storage.writeAsBytes(
          manifestPath,
          SpaceManifestCodec.encode(
              SpaceManifest(activeTableUids: spaceTableUids)));
    }

    if (!skipVersionBump) {
      // 6. Bump config versions and remove legacy mapping fields
      for (final spaceName in spaces) {
        await _upgradeSpaceVersion(spaceName);
      }

      final updatedGlobal =
          oldGlobalConfig.setVersion(InternalConfig.engineVersion);
      await _dataStore.saveGlobalConfig(updatedGlobal);
    }

    // 7. Delete old partition files and backup schema meta only after everything succeeds
    for (final partitionIndex in tablePartitionMap.values.toSet()) {
      final dirIndex = partitionToDir[partitionIndex] ??
          (partitionIndex ~/ _dataStore.maxEntriesPerDir);
      final partitionPath = _dataStore.pathManager
          .getSchemaPartitionFilePath(partitionIndex, dirIndex);
      if (await _dataStore.storage.existsFile(partitionPath)) {
        await _dataStore.storage.deleteFile(partitionPath);
      }
    }

    if (await _dataStore.storage.existsFile(schemaMetaPathOld)) {
      await _dataStore.storage.deleteFile(schemaMetaPathOld);
    }

    Logger.info(
      'Database upgrade to version 3 completed',
    );
  }

  Future<void> _migrateTableDirectory(String oldPath, String newPath,
      String tableUid, Map<String, String> indexUidMap) async {
    if (!await _dataStore.storage.existsDirectory(oldPath)) {
      return;
    }
    // Rename/move the table directory
    await _dataStore.storage.moveDirectory(oldPath, newPath);

    // Update table metadata: data/meta.json
    final metaFilePath = path.join(newPath, 'data', 'meta.json');
    if (await _dataStore.storage.existsFile(metaFilePath)) {
      try {
        final content = await _dataStore.storage.readAsString(metaFilePath);
        if (content != null && content.isNotEmpty) {
          final json = jsonDecode(content) as Map<String, dynamic>;
          json['tableUid'] = tableUid;
          json.remove('tableName');
          await _dataStore.storage
              .writeAsString(metaFilePath, jsonEncode(json));
        }
      } catch (e) {
        Logger.warn('Failed to update table metadata tableUid in v3 upgrade',
            rawError: e);
      }
    }

    // Update user-defined indexes: move directory to indexUid and update index meta.json
    final indexDirPath = path.join(newPath, 'index');
    if (await _dataStore.storage.existsDirectory(indexDirPath)) {
      for (final indexName in indexUidMap.keys) {
        final indexUid = indexUidMap[indexName]!;
        final oldIndexFilePath = path.join(indexDirPath, indexName);
        final newIndexFilePath = path.join(indexDirPath, indexUid);
        if (await _dataStore.storage.existsDirectory(oldIndexFilePath)) {
          if (await _dataStore.storage.existsDirectory(newIndexFilePath)) {
            await _dataStore.storage.deleteDirectory(oldIndexFilePath);
          } else {
            await _dataStore.storage
                .moveDirectory(oldIndexFilePath, newIndexFilePath);
          }
          await _rewriteIndexMetaJson(
            path.join(newIndexFilePath, 'meta.json'),
            tableUid: tableUid,
            indexUid: indexUid,
          );
        }

        // Vector mapping B+Trees are sibling dirs ({name}__nid2pk / __pk2nid), not
        // under the main index tree — migrate them separately.
        for (final suffix in const ['__nid2pk', '__pk2nid']) {
          await _migrateMappingIndexDirectory(
            indexDirPath: indexDirPath,
            legacyBaseName: indexName,
            stableIndexUid: indexUid,
            tableUid: tableUid,
            suffix: suffix,
          );
        }

        // Rewrite NGH vector meta at stable and/or legacy paths.
        await _rewriteNghMetaJson(
          indexDirPath: indexDirPath,
          indexUid: indexUid,
          tableUid: tableUid,
          legacyIndexName: indexName,
        );
      }
    }
  }

  Future<void> _rewriteIndexMetaJson(
    String metaFilePath, {
    required String tableUid,
    required String indexUid,
  }) async {
    if (!await _dataStore.storage.existsFile(metaFilePath)) {
      return;
    }
    try {
      final content = await _dataStore.storage.readAsString(metaFilePath);
      if (content == null || content.isEmpty) return;
      final json = jsonDecode(content) as Map<String, dynamic>;
      json['tableUid'] = tableUid;
      json['indexUid'] = indexUid;
      json.remove('tableName');
      json.remove('indexName');
      await _dataStore.storage.writeAsString(metaFilePath, jsonEncode(json));
    } catch (e) {
      Logger.warn('Failed to update index metadata in v3 upgrade', rawError: e);
    }
  }

  Future<void> _migrateMappingIndexDirectory({
    required String indexDirPath,
    required String legacyBaseName,
    required String stableIndexUid,
    required String tableUid,
    required String suffix,
  }) async {
    final oldPath = path.join(indexDirPath, '$legacyBaseName$suffix');
    final newPath = path.join(indexDirPath, '$stableIndexUid$suffix');
    if (oldPath == newPath ||
        !await _dataStore.storage.existsDirectory(oldPath)) {
      return;
    }

    if (await _dataStore.storage.existsDirectory(newPath)) {
      await _dataStore.storage.deleteDirectory(oldPath);
    } else {
      await _dataStore.storage.moveDirectory(oldPath, newPath);
    }

    await _rewriteIndexMetaJson(
      path.join(newPath, 'meta.json'),
      tableUid: tableUid,
      indexUid: '$stableIndexUid$suffix',
    );
  }

  Future<void> _rewriteNghMetaJson({
    required String indexDirPath,
    required String indexUid,
    required String tableUid,
    String? legacyIndexName,
  }) async {
    final stableMetaPath =
        path.join(indexDirPath, indexUid, 'ngh', 'meta.json');
    if (await _dataStore.storage.existsFile(stableMetaPath)) {
      await _rewriteNghMetaJsonFile(stableMetaPath, indexUid, tableUid);
      return;
    }

    if (legacyIndexName == null ||
        legacyIndexName.isEmpty ||
        legacyIndexName == indexUid) {
      return;
    }

    final legacyIndexDir = path.join(indexDirPath, legacyIndexName);
    final stableIndexDir = path.join(indexDirPath, indexUid);
    final legacyMetaPath = path.join(legacyIndexDir, 'ngh', 'meta.json');
    if (!await _dataStore.storage.existsFile(legacyMetaPath)) {
      return;
    }

    // NGH still under logical-name tree while stable uid tree is absent/incomplete.
    if (!await _dataStore.storage.existsDirectory(stableIndexDir)) {
      await _dataStore.storage.moveDirectory(legacyIndexDir, stableIndexDir);
    } else if (!await _dataStore.storage.existsFile(stableMetaPath)) {
      final legacyNghDir = path.join(legacyIndexDir, 'ngh');
      final stableNghDir = path.join(stableIndexDir, 'ngh');
      if (await _dataStore.storage.existsDirectory(legacyNghDir)) {
        await _dataStore.storage.moveDirectory(legacyNghDir, stableNghDir);
      }
    }

    final rewrittenPath = path.join(indexDirPath, indexUid, 'ngh', 'meta.json');
    if (await _dataStore.storage.existsFile(rewrittenPath)) {
      await _rewriteNghMetaJsonFile(rewrittenPath, indexUid, tableUid);
    } else {
      await _rewriteNghMetaJsonFile(legacyMetaPath, indexUid, tableUid);
    }
  }

  Future<void> _rewriteNghMetaJsonFile(
    String metaFilePath,
    String indexUid,
    String tableUid,
  ) async {
    try {
      final content = await _dataStore.storage.readAsString(metaFilePath);
      if (content == null || content.isEmpty) return;
      final json = jsonDecode(content) as Map<String, dynamic>;
      json['indexUid'] = indexUid;
      json['tableUid'] = tableUid;
      json.remove('tableName');
      json.remove('name');
      json.remove('fieldName');

      for (final key in ['nodeIdToPkMeta', 'pkToNodeIdMeta']) {
        final nested = json[key];
        if (nested is! Map<String, dynamic>) continue;
        final suffix = key == 'pkToNodeIdMeta' ? '__pk2nid' : '__nid2pk';
        nested['indexUid'] = '$indexUid$suffix';
        nested['tableUid'] = tableUid;
        nested.remove('tableName');
        nested.remove('indexName');
      }

      await _dataStore.storage.writeAsString(metaFilePath, jsonEncode(json));
    } catch (e) {
      Logger.warn('Failed to update NGH metadata in v3 upgrade', rawError: e);
    }
  }

  Future<void> _upgradeSpaceVersion(String spaceName) async {
    final config = await _dataStore.getSpaceConfig(spaceName: spaceName);
    if (config == null) {
      return;
    }

    try {
      if (config.version >= InternalConfig.engineVersion) {
        return;
      }
      await _dataStore.saveSpaceConfigToFile(
        config.copyWith(version: InternalConfig.engineVersion),
        spaceName: spaceName,
      );
    } catch (e) {
      Logger.warn('Skip upgrading space [$spaceName] config to v3',
          rawError: e);
    }
  }
}
