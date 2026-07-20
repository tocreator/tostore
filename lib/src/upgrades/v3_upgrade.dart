import 'dart:convert';
import 'package:path/path.dart' as path;
import '../core/btree_page.dart';
import '../core/data_store_impl.dart';
import '../core/wal_manager.dart';
import '../handler/common.dart';
import '../handler/logger.dart';
import '../handler/meta_binary_codec.dart';
import '../model/db_exception.dart';
import '../model/global_config.dart';
import '../model/parallel_journal_entry.dart';
import '../model/result_type.dart';
import '../model/system_table.dart';
import '../model/table_schema.dart';
import '../model/table_identity.dart';
import '../model/table_meta.dart';
import '../model/meta_info.dart';
import '../model/ngh_index_meta.dart';
import '../handler/space_manifest_codec.dart';
import '../model/space_manifest.dart';
import '../model/id_generator.dart';
import 'legacy_model/legacy_schema_json.dart';
import 'transaction_log_migration.dart';

/// Version 3 upgrade:
/// - Bootstraps `_system_table_meta` + internal KV only; migrates 3.1.2 schema
///   partitions (user + existing system tables) into `TableMeta` rows, then
///   renames directories to stable UIDs (no SchemaMeta/routes rewrite).
/// - Restructures storage directory names from physical table/index names to stable UIDs.
/// - Reads legacy meta.json once, writes TableDataMeta/IndexMeta/NghIndexMeta into
///   partition-0 page0, then deletes the JSON files (no intermediate JSON rewrite).
/// - Writes `space_manifest.bin` deferred space metadata.
/// - Migrates pending parallel-batch `tablePlan` out of A/B journal into WalMeta,
///   then deletes `journal_a.log` / `journal_b.log`.
/// - Migrates legacy NDJSON transaction logs to binary ToTX.
/// - Bumps version config markers last (after format migrations) for crash resume.
/// - Cleans up legacy map properties.
class V3Upgrade {
  final DataStoreImpl _dataStore;

  /// Sampled once from legacy table/index meta.json during page0 migration.
  int? _discoveredPageSize;

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
    DateTime? legacySchemaMetaCreatedAt;

    if (await _dataStore.storage.existsFile(schemaMetaPath)) {
      final content = await _dataStore.storage.readAsString(schemaMetaPath);
      if (content != null && content.isNotEmpty) {
        final legacy = LegacySchemaMetaJson.tryParse(content);
        if (legacy != null) {
          tablePartitionMap = Map<String, int>.from(legacy.tablePartitionMap);
          partitionToDir = Map<int, int>.from(legacy.partitionToDir);
          userSchemaHash = legacy.userSchemaHash;
          systemSchemaHash = legacy.systemSchemaHash;
          legacySchemaMetaCreatedAt = legacy.createdAt;
        } else {
          Logger.warn('Failed to parse old schema meta in v3 upgrade');
        }
      }
      // Backup old schema_meta.json before mutating so we can recover on crash
      if (!await _dataStore.storage.existsFile(schemaMetaPathOld)) {
        await _dataStore.storage.copyFile(schemaMetaPath, schemaMetaPathOld);
      }
    }

    // Bootstrap only brand-new engine tables (not present in 3.1.2).
    await _ensureBootstrapSystemTables();

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

    // Seed from GlobalConfig (bootstrap createTable may already have advanced it).
    final seedCfg = await _dataStore.getGlobalConfig() ?? GlobalConfig();
    var lastGlobalDirIndex = seedCfg.lastGlobalDirIndex;
    var lastGlobalDirEntries = seedCfg.lastGlobalDirEntries;
    var lastNonGlobalDirIndex = seedCfg.lastNonGlobalDirIndex;
    var lastNonGlobalDirEntries = seedCfg.lastNonGlobalDirEntries;
    final maxPerDir = _dataStore.maxEntriesPerDir;

    int allocateDirIndex(bool isGlobal) {
      if (isGlobal) {
        if (lastGlobalDirEntries >= maxPerDir) {
          lastGlobalDirIndex += 1;
          lastGlobalDirEntries = 1;
        } else {
          lastGlobalDirEntries += 1;
        }
        return lastGlobalDirIndex;
      }
      if (lastNonGlobalDirEntries >= maxPerDir) {
        lastNonGlobalDirIndex += 1;
        lastNonGlobalDirEntries = 1;
      } else {
        lastNonGlobalDirEntries += 1;
      }
      return lastNonGlobalDirIndex;
    }

    final schemaMgr = _dataStore.tableMetaManager!;
    final schemaMetaCreatedAt = legacySchemaMetaCreatedAt;

    // 3. Ingest ALL legacy schema tables (user + existing system) into
    // `_system_table_meta`. Read each partition file once.
    final tablesByPartition = <int, List<String>>{};
    for (final tableName in tablePartitionMap.keys) {
      // Brand-new bootstrap tables are not in 3.1.2 partitions.
      if (SystemTable.isTableMetaTable(tableName) ||
          SystemTable.isInternalKeyValueTable(tableName)) {
        continue;
      }
      final partitionIndex = tablePartitionMap[tableName]!;
      tablesByPartition
          .putIfAbsent(partitionIndex, () => <String>[])
          .add(tableName);
    }

    for (final entry in tablesByPartition.entries) {
      final partitionIndex = entry.key;
      final tableNames = entry.value;
      final dirIndex = partitionToDir[partitionIndex] ??
          (partitionIndex ~/ _dataStore.maxEntriesPerDir);
      final partitionPath = _dataStore.pathManager
          .getSchemaPartitionFilePath(partitionIndex, dirIndex);

      if (!await _dataStore.storage.existsFile(partitionPath)) {
        continue;
      }
      final content = await _dataStore.storage.readAsString(partitionPath);
      if (content == null || content.isEmpty) {
        continue;
      }

      final partitionSnap = LegacySchemaPartitionJson.tryParse(content);
      if (partitionSnap == null) {
        continue;
      }
      final tableCreatedAt =
          partitionSnap.createdAt ?? schemaMetaCreatedAt ?? DateTime.now();

      for (final tableName in tableNames) {
        final schemaJson = partitionSnap.tableSchemas[tableName];
        if (schemaJson == null) {
          continue;
        }

        try {
          final schema = TableSchema.fromJson(schemaJson);
          final tableUid = TableUid(GlobalIdGenerator.generate('t'));
          tableUidMap[tableName] = tableUid.value;
          tableIsGlobalMap[tableName] = schema.isGlobal;

          final isSys = SystemTable.isSystemTable(tableName);
          var upgradedSchema = schema.generateAutoIndexes();
          upgradedSchema = upgradedSchema.copyWith(
            tableUid: tableUid,
            schemaVersion:
                schema.schemaVersion ?? GlobalIdGenerator.generate('s'),
            isSystemTable: isSys,
          );

          final idxUidMap = <String, String>{};
          for (final idx in upgradedSchema.getAllIndexes()) {
            if (idx.indexUid.isNotEmpty) {
              idxUidMap[idx.actualIndexName] = idx.indexUid;
            }
          }
          tableIndexUidMap[tableName] = idxUidMap;

          final finalDirIndex = allocateDirIndex(schema.isGlobal);
          tableDirIndexMap[tableName] = finalDirIndex;

          final layout =
              schemaMgr.evolveFieldStorageLayout(nextSchema: upgradedSchema);
          final now = DateTime.now();
          await schemaMgr.saveTableMeta(
            TableMeta(
              tableUid: tableUid,
              tableName: TableName(tableName),
              isGlobal: upgradedSchema.isGlobal,
              schema: upgradedSchema,
              fieldLayout: layout,
              dirIndex: finalDirIndex,
              createdAt: tableCreatedAt,
              updatedAt: now,
            ),
            dirIndex: finalDirIndex,
            layoutOverride: layout,
          );
        } catch (e) {
          Logger.error(
              'Failed to upgrade schema for table $tableName in v3 upgrade',
              rawError: e);
        }
      }
    }

    // Dir high-water is folded into the single GlobalConfig write below.
    final resolvedSystemHash = systemSchemaHash ??
        TableSchema.generateSchemasHash(SystemTable.gettableSchemas);

    // 4. Move physical folders; migrate legacy meta.json → partition-0 page0.
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

    final resolvedPageSize =
        _discoveredPageSize ?? InternalConfig.defaultPageSize;

    // 7. Delete old partition files and schema_meta only after everything succeeds
    for (final partitionIndex in tablePartitionMap.values.toSet()) {
      final dirIndex = partitionToDir[partitionIndex] ??
          (partitionIndex ~/ _dataStore.maxEntriesPerDir);
      final partitionPath = _dataStore.pathManager
          .getSchemaPartitionFilePath(partitionIndex, dirIndex);
      if (await _dataStore.storage.existsFile(partitionPath)) {
        await _dataStore.storage.deleteFile(partitionPath);
      }
    }

    if (await _dataStore.storage.existsFile(schemaMetaPath)) {
      await _dataStore.storage.deleteFile(schemaMetaPath);
    }
    if (await _dataStore.storage.existsFile(schemaMetaPathOld)) {
      await _dataStore.storage.deleteFile(schemaMetaPathOld);
    }

    // Migrate in-flight parallel batch plans from A/B journal into WalMeta,
    // then delete legacy journal files.
    for (final spaceName in spaces) {
      await _migrateParallelJournalIntoWalMeta(spaceName);
    }

    // Migrate legacy NDJSON transaction logs to binary ToTX format.
    // Must finish before version bump so crash mid-migration re-runs V3.
    await TransactionLogMigration(_dataStore).migrateAllSpaces(spaces);

    // Single GlobalConfig write: schema hashes + pageSize + dir high-water + version.
    var updatedGlobal = oldGlobalConfig.copyWith(
      userSchemaHash: userSchemaHash,
      systemSchemaHash: resolvedSystemHash,
      pageSize: resolvedPageSize,
      lastGlobalDirIndex: lastGlobalDirIndex,
      lastGlobalDirEntries: lastGlobalDirEntries,
      lastNonGlobalDirIndex: lastNonGlobalDirIndex,
      lastNonGlobalDirEntries: lastNonGlobalDirEntries,
    );
    if (!skipVersionBump) {
      for (final spaceName in spaces) {
        await _upgradeSpaceVersion(spaceName);
      }
      updatedGlobal = updatedGlobal.setVersion(InternalConfig.engineVersion);
    }
    await _dataStore.saveGlobalConfig(updatedGlobal);

    Logger.info(
      'Database upgrade to version 3 completed',
    );
  }

  /// Create `_system_table_meta` + engine-internal KV (space + global).
  Future<void> _ensureBootstrapSystemTables() async {
    for (final schema in [
      SystemTable.tableMetaTable(),
      SystemTable.internalKVTable(false),
      SystemTable.internalKVTable(true),
    ]) {
      if (await _dataStore.tableExists(schema.name)) continue;

      final result = await _dataStore.createTable(schema, isSystemTable: true);
      if (!result.hasErrors) continue;

      final fatal = result.statuses
          .where((s) =>
              s.type != ResultType.success &&
              s.type != ResultType.devSchemaTableExists)
          .toList();
      if (fatal.isNotEmpty) {
        throw DbException(fatal);
      }
    }
  }

  /// Lift `BatchStart.tablePlan` from remnant A/B journals into
  /// [PendingParallelBatch.tablePlans], then delete `journal_a/b.log`.
  ///
  /// Remnant-only: `journalFile` / `recoverStartOffset` are read from the raw
  /// WAL meta JSON (not fields on [PendingParallelBatch]). Paths are built
  /// under [PathManager.getPageRedoRootPath] — no A/B helpers in PathManager.
  Future<void> _migrateParallelJournalIntoWalMeta(String spaceName) async {
    final walMetaPath =
        _dataStore.pathManager.getWalMainMetaPath(spaceName: spaceName);
    WalMeta? meta;
    Map<String, dynamic>? metaJson;
    if (await _dataStore.storage.existsFile(walMetaPath)) {
      try {
        final content = await _dataStore.storage.readAsString(walMetaPath);
        if (content != null && content.isNotEmpty) {
          metaJson = jsonDecode(content) as Map<String, dynamic>;
          meta = WalMeta.fromJson(metaJson);
        }
      } catch (e) {
        Logger.warn('v3: failed to parse WAL meta for space $spaceName',
            rawError: e);
      }
    }

    if (meta != null && meta.pendingBatches.isNotEmpty) {
      final rawPending =
          (metaJson?['pendingBatches'] as List?) ?? const <dynamic>[];
      final legacyByBatchId = <String, Map<String, dynamic>>{};
      for (final item in rawPending) {
        if (item is! Map) continue;
        final raw = Map<String, dynamic>.from(item);
        final id = raw['batchId'] as String?;
        if (id != null && id.isNotEmpty) {
          legacyByBatchId[id] = raw;
        }
      }

      final migrated = <PendingParallelBatch>[];
      var changed = false;
      for (final batch in meta.pendingBatches) {
        var plans = Map<TableUid, BatchTablePlan>.from(batch.tablePlans);
        final raw = legacyByBatchId[batch.batchId];
        final journalFile = raw?['journalFile'] as String?;
        final recoverStartOffset =
            (raw?['recoverStartOffset'] as num?)?.toInt() ?? 0;
        final hadLegacyKeys = raw != null &&
            (raw.containsKey('journalFile') ||
                raw.containsKey('recoverStartOffset') ||
                raw.containsKey('tables') ||
                raw.containsKey('indexIds'));

        final needsPlan = plans.isEmpty ||
            plans.values.every((p) =>
                p.baseTotalRecords == null && p.baseTotalSizeInBytes == null);
        if (needsPlan && journalFile != null && journalFile.isNotEmpty) {
          final fromJournal = await _readLegacyBatchStartTablePlans(
            spaceName: spaceName,
            journalFile: journalFile,
            recoverStartOffset: recoverStartOffset,
            batchId: batch.batchId,
          );
          if (fromJournal.isNotEmpty) {
            plans = fromJournal;
            changed = true;
          }
        }
        if (hadLegacyKeys) changed = true;
        migrated.add(batch.copyWith(tablePlans: plans));
      }
      if (changed) {
        final updated = meta.copyWith(pendingBatches: migrated);
        try {
          await _dataStore.storage.writeAsString(
            walMetaPath,
            jsonEncode(updated.toJson()),
            flush: true,
          );
          Logger.info(
              'v3: migrated pending parallel batch tablePlans for space $spaceName');
        } catch (e) {
          Logger.warn(
              'v3: failed to write migrated WAL meta for space $spaceName',
              rawError: e);
        }
      }
    }

    // Remnant A/B files only — page_redo_* stays under the same root.
    final redoRoot =
        _dataStore.pathManager.getParallelJournalRootPath(spaceName: spaceName);
    try {
      for (final name in const ['journal_a.log', 'journal_b.log']) {
        final p = path.join(redoRoot, name);
        if (await _dataStore.storage.existsFile(p)) {
          await _dataStore.storage.deleteFile(p);
        }
      }
    } catch (e) {
      Logger.warn(
          'v3: failed to delete legacy parallel journals for space $spaceName',
          rawError: e);
    }
  }

  /// Remnant path: `parallel_journal/journal_a.log` or `journal_b.log`.
  String _legacyAbJournalPath(String spaceName, String journalFile) {
    final root =
        _dataStore.pathManager.getParallelJournalRootPath(spaceName: spaceName);
    final isB = journalFile == 'B' ||
        journalFile == 'journal_b.log' ||
        journalFile.endsWith('journal_b.log');
    return path.join(root, isB ? 'journal_b.log' : 'journal_a.log');
  }

  /// Parse remnant JSONL A/B journal for this batch's `batchStart.tablePlan`.
  Future<Map<TableUid, BatchTablePlan>> _readLegacyBatchStartTablePlans({
    required String spaceName,
    required String journalFile,
    required int recoverStartOffset,
    required String batchId,
  }) async {
    final journalPath = _legacyAbJournalPath(spaceName, journalFile);
    final result = <TableUid, BatchTablePlan>{};
    try {
      if (!await _dataStore.storage.existsFile(journalPath)) return result;
      final stream = _dataStore.storage
          .readLinesStream(journalPath, offset: recoverStartOffset);
      await for (final line in stream) {
        if (line.isEmpty) continue;
        try {
          final json = jsonDecode(line);
          if (json is! Map) continue;
          final map = json.cast<String, dynamic>();
          if (map['type'] != 'batchStart') continue;
          if ((map['batchId'] as String?) != batchId) continue;
          final rawPlan = (map['tablePlan'] as Map?) ??
              (map['tablePlans'] as Map?) ??
              const {};
          rawPlan.forEach((k, v) {
            result[TableUid(k.toString())] = BatchTablePlan.fromJson(
                ((v as Map?) ?? const {}).cast<String, dynamic>());
          });
          if (result.isNotEmpty) break;
        } catch (_) {}
      }
    } catch (e) {
      Logger.warn(
          'v3: failed to read legacy BatchStart tablePlan from $journalPath',
          rawError: e);
    }
    return result;
  }

  Future<void> _migrateTableDirectory(String oldPath, String newPath,
      String tableUid, Map<String, String> indexUidMap) async {
    final oldExists = await _dataStore.storage.existsDirectory(oldPath);
    final newExists = await _dataStore.storage.existsDirectory(newPath);
    if (!oldExists && !newExists) {
      return;
    }

    // Rename/move the table directory (name → stable tableUid).
    // Resume-safe: if already under [newPath], only finish meta migration.
    if (oldExists && !newExists) {
      await _dataStore.storage.moveDirectory(oldPath, newPath);
    } else if (oldExists && newExists) {
      // Partial prior run left both trees; keep [newPath], drop leftover [oldPath].
      await _dataStore.storage.deleteDirectory(oldPath);
    }

    final uid = TableUid(tableUid);
    final indexDirPath = path.join(newPath, 'index');

    // Rename index / mapping / NGH trees to stable indexUid — no JSON rewrite.
    // Meta is migrated once: legacy meta.json → partition-0 page0 → delete JSON.
    if (await _dataStore.storage.existsDirectory(indexDirPath)) {
      for (final indexName in indexUidMap.keys) {
        final indexUid = indexUidMap[indexName]!;
        final oldIndexFilePath = path.join(indexDirPath, indexName);
        final newIndexFilePath = path.join(indexDirPath, indexUid);
        final oldIdxExists =
            await _dataStore.storage.existsDirectory(oldIndexFilePath);
        final newIdxExists =
            await _dataStore.storage.existsDirectory(newIndexFilePath);

        if (oldIdxExists && !newIdxExists) {
          await _dataStore.storage
              .moveDirectory(oldIndexFilePath, newIndexFilePath);
        } else if (oldIdxExists && newIdxExists) {
          // Salvage NGH from the leftover logical-name tree before delete.
          await _ensureNghUnderStableIndexUid(
            indexDirPath: indexDirPath,
            indexUid: indexUid,
            legacyIndexName: indexName,
          );
          await _dataStore.storage.deleteDirectory(oldIndexFilePath);
        }

        for (final suffix in const ['__nid2pk', '__pk2nid']) {
          await _moveDirectoryIfNeeded(
            path.join(indexDirPath, '$indexName$suffix'),
            path.join(indexDirPath, '$indexUid$suffix'),
          );
        }

        await _ensureNghUnderStableIndexUid(
          indexDirPath: indexDirPath,
          indexUid: indexUid,
          legacyIndexName: indexName,
        );
      }
    }

    await _migrateTableTreeMetaToPage0(uid, tableRoot: newPath);
    await _migrateIndexMetasToPage0(
      tableUid: uid,
      indexDirPath: indexDirPath,
      tableRoot: newPath,
    );
  }

  Future<void> _moveDirectoryIfNeeded(String oldPath, String newPath) async {
    if (oldPath == newPath ||
        !await _dataStore.storage.existsDirectory(oldPath)) {
      return;
    }
    if (await _dataStore.storage.existsDirectory(newPath)) {
      await _dataStore.storage.deleteDirectory(oldPath);
      return;
    }
    await _dataStore.storage.moveDirectory(oldPath, newPath);
  }

  /// Move NGH files under `{indexUid}/ngh` when still on logical-name tree.
  Future<void> _ensureNghUnderStableIndexUid({
    required String indexDirPath,
    required String indexUid,
    required String legacyIndexName,
  }) async {
    if (legacyIndexName.isEmpty || legacyIndexName == indexUid) return;

    final nghMetaPath = path.join(indexDirPath, indexUid, 'ngh', 'meta.json');
    if (await _dataStore.storage.existsFile(nghMetaPath)) return;

    final legacyIndexDir = path.join(indexDirPath, legacyIndexName);
    final stableIndexDir = path.join(indexDirPath, indexUid);
    final legacyMetaPath = path.join(legacyIndexDir, 'ngh', 'meta.json');
    if (!await _dataStore.storage.existsFile(legacyMetaPath)) return;

    if (!await _dataStore.storage.existsDirectory(stableIndexDir)) {
      await _dataStore.storage.moveDirectory(legacyIndexDir, stableIndexDir);
      return;
    }

    final legacyNghDir = path.join(legacyIndexDir, 'ngh');
    final stableNghDir = path.join(stableIndexDir, 'ngh');
    if (await _dataStore.storage.existsDirectory(legacyNghDir) &&
        !await _dataStore.storage.existsDirectory(stableNghDir)) {
      await _dataStore.storage.moveDirectory(legacyNghDir, stableNghDir);
    }
  }

  int get _upgradePageSize =>
      _discoveredPageSize ??
      (_dataStore.hasConfiguredPageSize
          ? _dataStore.configuredPageSize
          : InternalConfig.defaultPageSize);

  String _tablePart0Path(String tableRoot) =>
      path.join(tableRoot, 'data', 'btree', 'dir_0', 'p0.dat');

  String _indexPart0Path(String tableRoot, String indexUid) => path.join(
        tableRoot,
        'index',
        indexUid,
        'btree',
        'dir_0',
        'p0.idx',
      );

  String _nghGraphPart0Path(String tableRoot, String indexUid) => path.join(
        tableRoot,
        'index',
        indexUid,
        'ngh',
        'graph',
        'dir_0',
        'p0.ngh',
      );

  Future<void> _migrateTableTreeMetaToPage0(
    TableUid tableUid, {
    required String tableRoot,
  }) async {
    final metaPath = path.join(tableRoot, 'data', 'meta.json');
    if (!await _dataStore.storage.existsFile(metaPath)) {
      return;
    }
    try {
      final content = await _dataStore.storage.readAsString(metaPath);
      if (content == null || content.isEmpty) return;
      final json = jsonDecode(content) as Map<String, dynamic>;
      if (_discoveredPageSize == null) {
        final sampled = (json['btreePageSize'] as num?)?.toInt();
        if (sampled != null && sampled > 0) {
          _discoveredPageSize = sampled;
        }
      }
      final meta = TableDataMeta.fromJson(
        json,
        tableUidFallback: tableUid,
      );

      // Only partition 0 page0 (global TableDataMeta + local). Other partitions
      // keep legacy page0; runtime tries TMP1 first, legacy only on magic miss.
      PartitionLocalStats local = PartitionLocalStats(partitionNo: 0);
      final part0Path = _tablePart0Path(tableRoot);
      if (await _dataStore.storage.existsFile(part0Path)) {
        local = await _dataStore.treeMetaPageService.readPartitionLocal(
              path: part0Path,
              partitionNo: 0,
              pageType: BTreePageType.meta,
            ) ??
            local;
      }

      await _dataStore.treeMetaPageService.writePartitionPage0(
        path: part0Path,
        pageSize: _upgradePageSize,
        partitionNo: 0,
        pageType: BTreePageType.meta,
        partitionLocal: local,
        treeGlobalMeta: TreeGlobalMetaBlobCodec.encode(
          TreeGlobalMetaKind.table,
          TableDataMetaCodec.encode(meta),
        ),
        flush: true,
      );
      await _dataStore.storage.deleteFile(metaPath);
    } catch (e) {
      Logger.warn('v3: failed to migrate table meta to page 0 for $tableUid',
          rawError: e);
    }
  }

  Future<void> _migrateIndexMetasToPage0({
    required TableUid tableUid,
    required String indexDirPath,
    required String tableRoot,
  }) async {
    if (!await _dataStore.storage.existsDirectory(indexDirPath)) {
      return;
    }
    final entries = await _dataStore.storage.listDirectory(indexDirPath);
    for (final entryPath in entries) {
      if (!await _dataStore.storage.existsDirectory(entryPath)) {
        continue;
      }
      final indexUid = IndexUid(path.basename(entryPath));
      final metaPath = path.join(entryPath, 'meta.json');
      if (!await _dataStore.storage.existsFile(metaPath)) {
        continue;
      }
      try {
        final content = await _dataStore.storage.readAsString(metaPath);
        if (content == null || content.isEmpty) continue;
        final json = jsonDecode(content) as Map<String, dynamic>;
        if (_discoveredPageSize == null) {
          final sampled = (json['btreePageSize'] as num?)?.toInt();
          if (sampled != null && sampled > 0) {
            _discoveredPageSize = sampled;
          }
        }
        final meta = IndexMeta.fromJson(
          json,
          tableUidFallback: tableUid,
          indexUidFallback: indexUid,
        );

        PartitionLocalStats local = PartitionLocalStats(partitionNo: 0);
        final part0Path = _indexPart0Path(tableRoot, indexUid.value);
        if (await _dataStore.storage.existsFile(part0Path)) {
          local = await _dataStore.treeMetaPageService.readPartitionLocal(
                path: part0Path,
                partitionNo: 0,
                pageType: BTreePageType.meta,
              ) ??
              local;
        }

        await _dataStore.treeMetaPageService.writePartitionPage0(
          path: part0Path,
          pageSize: _upgradePageSize,
          partitionNo: 0,
          pageType: BTreePageType.meta,
          partitionLocal: local,
          treeGlobalMeta: TreeGlobalMetaBlobCodec.encode(
            TreeGlobalMetaKind.indexTree,
            IndexMetaCodec.encode(meta),
          ),
          flush: true,
        );
        await _dataStore.storage.deleteFile(metaPath);

        final nghMetaPath = path.join(entryPath, 'ngh', 'meta.json');
        if (await _dataStore.storage.existsFile(nghMetaPath)) {
          await _migrateNghMetaToPage0(
            tableUid,
            indexUid,
            nghMetaPath,
            tableRoot: tableRoot,
          );
        }
      } catch (e) {
        Logger.warn('v3: failed to migrate index meta to page 0 for $indexUid',
            rawError: e);
      }
    }
  }

  Future<void> _migrateNghMetaToPage0(
    TableUid tableUid,
    IndexUid indexUid,
    String nghMetaPath, {
    required String tableRoot,
  }) async {
    try {
      final content = await _dataStore.storage.readAsString(nghMetaPath);
      if (content == null || content.isEmpty) return;
      var meta = NghIndexMeta.fromJson(
        jsonDecode(content) as Map<String, dynamic>,
      );
      // Rebind UIDs from directory rename (JSON may still hold tableName/indexName).
      final nid2pk = meta.nodeIdToPkMeta;
      final pk2nid = meta.pkToNodeIdMeta;
      meta = meta.copyWith(
        indexUid: indexUid,
        tableUid: tableUid,
        nodeIdToPkMeta: nid2pk?.copyWith(
          indexUid: IndexUid('${indexUid.value}__nid2pk'),
          tableUid: tableUid,
        ),
        pkToNodeIdMeta: pk2nid?.copyWith(
          indexUid: IndexUid('${indexUid.value}__pk2nid'),
          tableUid: tableUid,
        ),
      );

      PartitionLocalStats local =
          const PartitionLocalStats(partitionNo: 0, dataCategory: 0);
      final graphP0 = _nghGraphPart0Path(tableRoot, indexUid.value);
      if (await _dataStore.storage.existsFile(graphP0)) {
        local = await _dataStore.treeMetaPageService.readPartitionLocal(
              path: graphP0,
              partitionNo: 0,
              pageType: BTreePageType.nghMeta,
            ) ??
            local;
      }

      await _dataStore.treeMetaPageService.writePartitionPage0(
        path: graphP0,
        pageSize: _upgradePageSize,
        partitionNo: 0,
        pageType: BTreePageType.nghMeta,
        partitionLocal: local,
        treeGlobalMeta: TreeGlobalMetaBlobCodec.encode(
          TreeGlobalMetaKind.ngh,
          NghIndexMetaCodec.encode(meta),
        ),
        flush: true,
      );
      await _dataStore.storage.deleteFile(nghMetaPath);
    } catch (e) {
      Logger.warn('v3: failed to migrate NGH meta to page 0 for $indexUid',
          rawError: e);
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
