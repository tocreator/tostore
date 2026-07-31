import 'dart:async';
import 'dart:convert';
import 'package:path/path.dart' as path;
import '../core/btree_page.dart';
import '../core/data_store_impl.dart';
import '../core/wal_manager.dart';
import '../handler/common.dart';
import '../handler/logger.dart';
import '../handler/meta_binary_codec.dart';
import '../handler/table_meta_codec.dart';
import '../model/db_exception.dart';
import '../model/global_config.dart';
import '../model/parallel_journal_entry.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/system_table.dart';
import '../model/table_schema.dart';
import '../model/table_identity.dart';
import '../model/table_meta.dart';
import '../model/table_context.dart';
import '../model/meta_info.dart';
import '../model/ngh_index_meta.dart';
import '../model/id_generator.dart';
import 'config_format_migration.dart';
import 'applied_encryption_bootstrap.dart';
import 'legacy_model/pre_v3.dart';
import 'meta_format_migration.dart';
import 'migration_format_migration.dart';
import 'transaction_log_migration.dart';
import 'weight_format_migration.dart';

/// Version 3 upgrade:
/// - Bootstraps `_system_table_meta` + internal KV + `_system_fk_references` +
///   `_system_key_migration`; migrates 3.1.2 schema partitions (user + existing
///   system tables) into `TableMeta` rows via memory + durable writeChanges,
///   then renames directories to stable UIDs (no SchemaMeta/routes rewrite).
/// - Restructures storage directory names from physical table/index names to stable UIDs.
/// - Primes [GlobalConfig.pageSize] (sample legacy meta.json / default) before
///   bootstrap so index page0 writes never see pageSize=0.
/// - Reads legacy meta.json once, writes TableDataMeta/IndexMeta/NghIndexMeta into
///   partition-0 page0, then deletes the JSON files (no intermediate JSON rewrite).
/// - Migrates pending parallel-batch `tablePlan` out of A/B journal into WalMeta,
///   then deletes `journal_a.log` / `journal_b.log` (interim JSON; converted below).
/// - Migrates legacy NDJSON transaction logs to binary ToTX.
/// - Blocking [MetaFormatMigration]: WAL/Txn `meta.json` → `meta.tobf` (same V3
///   pass, before version bump; KeyManager primed for EncryptionScope.full).
/// - Blocking [MigrationFormatMigration]: `migration_meta` / `task_*` JSON →
///   `.tobf` (after WAL/Txn meta; before version bump; accepts v1 dirUsage/taskIndex
///   via [MigrationMeta.fromJson]).
/// - Bumps version config markers last (after format migrations) for crash resume.
/// - Async [WeightFormatMigration]: `cache_weights.json` → `access_weights.tobf`
///   (non-blocking; loss acceptable; not WAL-backed).
/// - Cleans up legacy map properties.
class V3Upgrade {
  final DataStoreImpl _dataStore;

  /// Sampled once from legacy table/index meta.json during page0 migration.
  int? _discoveredPageSize;

  /// Legacy artifact paths removed after upgrade completes (non-blocking).
  final List<String> _pendingLegacyFileDeletes = [];
  final List<String> _pendingLegacyDirectoryDeletes = [];

  V3Upgrade(this._dataStore);

  void _scheduleLegacyFileDelete(String filePath) {
    if (filePath.isEmpty) return;
    _pendingLegacyFileDeletes.add(filePath);
  }

  void _scheduleLegacyDirectoryDelete(String dirPath) {
    if (dirPath.isEmpty) return;
    _pendingLegacyDirectoryDeletes.add(dirPath);
  }

  Future<void> _runLegacyArtifactCleanupAsync() async {
    for (final filePath in _pendingLegacyFileDeletes) {
      try {
        if (await _dataStore.storage.existsFile(filePath)) {
          await _dataStore.storage.deleteFile(filePath);
        }
      } catch (e) {
        Logger.warn(
          'v3: async legacy file cleanup failed: $filePath',
          rawError: e,
        );
      }
    }
    for (final dirPath in _pendingLegacyDirectoryDeletes) {
      try {
        if (await _dataStore.storage.existsDirectory(dirPath)) {
          await _dataStore.storage.deleteDirectory(dirPath);
        }
      } catch (e) {
        Logger.warn(
          'v3: async legacy directory cleanup failed: $dirPath',
          rawError: e,
        );
      }
    }
    _pendingLegacyFileDeletes.clear();
    _pendingLegacyDirectoryDeletes.clear();
  }

  String _getLegacySchemaMetaPath(String instancePath) {
    return pathJoin(instancePath, 'schemas', 'schema_meta.json');
  }

  String _getLegacySchemaPartitionFilePath(
      String instancePath, int partitionIndex, int dirIndex) {
    return pathJoin(instancePath, 'schemas', 'dir_$dirIndex',
        'schema_p$partitionIndex.json');
  }

  Future<void> execute(GlobalConfig oldGlobalConfig,
      {bool skipVersionBump = false}) async {
    Logger.info(
      'Starting database upgrade to version 3',
    );

    final schemaMetaPath = _getLegacySchemaMetaPath(_dataStore.instancePath!);
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

    // Read legacy JSON config mappings before bootstrap (needed to sample
    // btreePageSize). Maps must stay on disk until finalize.
    // Hot-path GlobalConfig model no longer carries tableDirectoryMap — read raw JSON.
    final globalJson =
        await LegacyConfigBootstrap.readGlobalJsonMap(_dataStore);
    final globalTableDirMap = globalJson != null
        ? (globalJson['tableDirectoryMap'] as Map<String, dynamic>?)
        : null;

    final spaces = oldGlobalConfig.spaceNames.isNotEmpty
        ? oldGlobalConfig.spaceNames.toList()
        : <String>['default'];

    final spaceTableDirMaps = <String, Map<String, dynamic>>{};
    for (final spaceName in spaces) {
      final spaceJson = await LegacyConfigBootstrap.readSpaceJsonMap(
        _dataStore,
        spaceName: spaceName,
      );
      if (spaceJson != null && spaceJson.containsKey('tableDirectoryMap')) {
        spaceTableDirMaps[spaceName] =
            spaceJson['tableDirectoryMap'] as Map<String, dynamic>;
      }
    }

    // Lock pageSize before createTable writes system-table index page0.
    // Legacy GlobalConfig.pageSize is 0 (unset); configuredPageSize alone would
    // fall back to default, but custom btreePageSize must be sampled first.
    await _primePageSizeBeforeBootstrap(
      oldGlobalConfig: oldGlobalConfig,
      globalTableDirMap: globalTableDirMap,
      spaceTableDirMaps: spaceTableDirMaps,
      spaces: spaces,
    );

    // Bootstrap only brand-new engine tables (not present in 3.1.2).
    await _ensureBootstrapSystemTables();

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
          SystemTable.isInternalKeyValueTable(tableName) ||
          SystemTable.isFkReferencesTable(tableName) ||
          tableName == SystemTable.keyMigrationProgressTableName) {
        continue;
      }
      final partitionIndex = tablePartitionMap[tableName]!;
      tablesByPartition
          .putIfAbsent(partitionIndex, () => <String>[])
          .add(tableName);
    }

    final pendingIngestMetas = <TableMeta>[];
    for (final entry in tablesByPartition.entries) {
      final partitionIndex = entry.key;
      final tableNames = entry.value;
      final dirIndex = partitionToDir[partitionIndex] ??
          (partitionIndex ~/ _dataStore.maxEntriesPerDir);
      final partitionPath = _getLegacySchemaPartitionFilePath(
          _dataStore.instancePath!, partitionIndex, dirIndex);

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
          final saved = await schemaMgr.saveTableMeta(
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
            memoryOnly: true,
            dirIndex: finalDirIndex,
            layoutOverride: layout,
          );
          pendingIngestMetas.add(saved);
        } catch (e) {
          Logger.error(
              'Failed to upgrade schema for table $tableName in v3 upgrade',
              rawError: e);
        }
      }
    }
    await _durablyPersistTableMetaRows(pendingIngestMetas);

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
          oldGlobalDirIndex =
              _legacyDirIndex(globalTableDirMap['global:$tableName']);
        }
        final actualOldGlobalDirIndex = oldGlobalDirIndex ?? 0;

        await _migrateTableDirectory(
          _globalTableRoot(actualOldGlobalDirIndex, tableName),
          _globalTableRoot(finalDirIndex, tableUid),
          tableUid,
          indexUidMap,
        );
      } else {
        // Move space table directories across all spaces
        for (final spaceName in spaces) {
          final spaceTableDirMap = spaceTableDirMaps[spaceName];
          int? oldSpaceDirIndex;
          if (spaceTableDirMap != null) {
            oldSpaceDirIndex =
                _legacyDirIndex(spaceTableDirMap['$spaceName:$tableName']);
          }
          final actualOldDirIndex = oldSpaceDirIndex ?? 0;

          await _migrateTableDirectory(
            _spaceTableRoot(spaceName, actualOldDirIndex, tableName),
            _spaceTableRoot(spaceName, finalDirIndex, tableUid),
            tableUid,
            indexUidMap,
          );
        }
      }
    }

    final resolvedPageSize =
        _discoveredPageSize ?? _dataStore.configuredPageSize;

    // 5. Schedule legacy schema artifact cleanup (async after version bump).
    for (final partitionIndex in tablePartitionMap.values.toSet()) {
      final dirIndex = partitionToDir[partitionIndex] ??
          (partitionIndex ~/ _dataStore.maxEntriesPerDir);
      _scheduleLegacyFileDelete(_getLegacySchemaPartitionFilePath(
          _dataStore.instancePath!, partitionIndex, dirIndex));
    }

    _scheduleLegacyFileDelete(schemaMetaPath);
    _scheduleLegacyFileDelete(schemaMetaPathOld);
    _scheduleLegacyDirectoryDelete(
        pathJoin(_dataStore.instancePath!, 'schemas'));

    // Migrate in-flight parallel batch plans from A/B journal into WalMeta,
    // then delete legacy journal files.
    for (final spaceName in spaces) {
      await _migrateParallelJournalIntoWalMeta(spaceName);
    }

    // Migrate legacy NDJSON transaction logs to binary ToTX format.
    // Must finish before version bump so crash mid-migration re-runs V3.
    await TransactionLogMigration(_dataStore).migrateAllSpaces(spaces);

    // Harvest SpaceConfig keyrings into GlobalConfig.appliedEncryption before
    // KeyManager init / JSON deletion (deviceBinding path KEK tried as fallback).
    await AppliedEncryptionBootstrap.ensureAppliedEncryption(_dataStore);

    // WAL/Txn meta JSON → TOBF (blocking, before version bump).
    // KeyManager must be primed so EncryptionScope.full uses EncryptionManager.
    await _dataStore.keyManager.initialize();
    await MetaFormatMigration.migrateAllSpaces(
      _dataStore,
      spaceNames: spaces,
    );

    // Migration meta / tasks JSON → TOBF (blocking, before version bump).
    await MigrationFormatMigration.migrate(_dataStore);

    // Single GlobalConfig write: schema hashes + pageSize + dir high-water + version.
    final applied = (await _dataStore.getGlobalConfig())?.appliedEncryption;
    var updatedGlobal = oldGlobalConfig.copyWith(
      userSchemaHash: userSchemaHash,
      systemSchemaHash: resolvedSystemHash,
      pageSize: resolvedPageSize,
      lastGlobalDirIndex: lastGlobalDirIndex,
      lastGlobalDirEntries: lastGlobalDirEntries,
      lastNonGlobalDirIndex: lastNonGlobalDirIndex,
      lastNonGlobalDirEntries: lastNonGlobalDirEntries,
      appliedEncryption: applied,
    );
    if (!skipVersionBump) {
      updatedGlobal = updatedGlobal.setVersion(InternalConfig.engineVersion);
    }
    await _dataStore.saveGlobalConfig(
      updatedGlobal,
      propagateErrors: true,
    );

    // After tableDirectoryMap has been consumed: verify GlobalConfig TOBF,
    // then delete legacy space JSON (stats move to InternalKv post-init).
    await ConfigFormatMigration.finalizeTobfAndDeleteJson(
      _dataStore,
      spaceNames: spaces,
    );

    Logger.info(
      'Database upgrade to version 3 completed',
    );

    // Non-blocking: legacy weight JSON → internal KV (formal path never reads JSON).
    unawaited(
      WeightFormatMigration.migrateAsync(
        _dataStore,
        spaceNames: spaces,
      ).catchError((Object e) {
        Logger.warn('WeightFormatMigration async failed', rawError: e);
      }),
    );

    // Non-blocking: schemas/, schema partitions, per-table maxid.txt, etc.
    unawaited(
      _runLegacyArtifactCleanupAsync().catchError((Object e) {
        Logger.warn('v3: legacy artifact async cleanup failed', rawError: e);
      }),
    );
  }

  /// Create engine bootstrap system tables that must exist before remaining
  /// system/user tables (meta store, internal KV, FK reverse index, key migration).
  Future<void> _ensureBootstrapSystemTables() async {
    await _dataStore.keyManager.initialize();

    final pendingDurable = <TableMeta>[];
    for (final schema in [
      SystemTable.tableMetaTable(),
      SystemTable.internalKVTable(false),
      SystemTable.internalKVTable(true),
      SystemTable.fkReferencesTable(),
      SystemTable.keyMigrationProgressTable(),
    ]) {
      final created = await _bootstrapSystemTableMemoryAndShells(schema);
      if (created != null) {
        pendingDurable.add(created);
      }
    }

    await _durablyPersistTableMetaRows(pendingDurable);
  }

  /// Memory-only [TableMeta] + empty index page0. Returns meta when newly
  /// created in this pass (caller must durably write); `null` if already exists.
  Future<TableMeta?> _bootstrapSystemTableMemoryAndShells(
    TableSchema schema,
  ) async {
    if (await _dataStore.tableExists(schema.name)) {
      return null;
    }

    final schemaMgr = _dataStore.tableMetaManager;
    if (schemaMgr == null) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'tableMetaManager unavailable during v3 bootstrap',
        ),
      ]);
    }

    final tableSchema = schema.materializeForCreate(isSystemTable: true);
    final isTableMeta = SystemTable.isTableMetaTable(tableSchema.name);
    final dirIndex = isTableMeta
        ? SystemTable.tableMetaDirIndex
        : await schemaMgr.allocateDirIndex(tableSchema.isGlobal);
    final layout = schemaMgr.evolveFieldStorageLayout(nextSchema: tableSchema);
    final now = DateTime.now();
    final saved = await schemaMgr.saveTableMeta(
      TableMeta(
        tableUid: tableSchema.tableUid,
        tableName: TableName(tableSchema.name),
        isGlobal: tableSchema.isGlobal,
        schema: tableSchema,
        fieldLayout: layout,
        dirIndex: dirIndex,
        createdAt: now,
        updatedAt: now,
      ),
      memoryOnly: true,
      dirIndex: dirIndex,
      layoutOverride: layout,
    );

    final tableCtx = TableContext(
      tableUid: saved.tableUid,
      tableName: saved.tableName,
      isGlobal: saved.isGlobal,
      dirIndex: saved.dirIndex,
      schema: saved.schema,
    );
    // Index files/meta are created lazily on first write via writeChanges.
    _dataStore.tableDataManager.tableCreated(tableCtx);
    return saved;
  }

  /// Insert missing `_system_table_meta` rows (+ secondary indexes) on disk.
  ///
  /// Idempotent: skips UIDs already present in partition files (crash resume).
  /// Does not touch WriteBuffer (avoids double-apply after journal starts).
  Future<void> _durablyPersistTableMetaRows(List<TableMeta> metas) async {
    if (metas.isEmpty) return;

    final schemaMgr = _dataStore.tableMetaManager;
    if (schemaMgr == null) return;

    final ctx = schemaMgr.bootstrapTableMetaContext();
    final pks = metas.map((m) => m.tableUid.value).toList(growable: false);
    final existing = await _dataStore.tableDataManager.queryRecordsBatch(
      ctx,
      pks,
      readFromFileOnly: true,
    );
    final existingKeys = <String>{};
    for (final row in existing.records) {
      final uid = row[SystemTable.tableMetaUidField]?.toString();
      if (uid != null && uid.isNotEmpty) {
        existingKeys.add(uid);
      }
    }

    final inserts = <Map<String, dynamic>>[];
    for (final meta in metas) {
      if (existingKeys.contains(meta.tableUid.value)) continue;
      inserts.add(TableMetaCodec.encodeRow(meta));
    }
    if (inserts.isEmpty) return;

    await _dataStore.tableDataManager.writeChanges(
      table: ctx,
      inserts: inserts,
      recordCountInsertDelta: inserts.length,
    );
    await _dataStore.indexManager?.writeChanges(
      table: ctx,
      inserts: inserts,
    );
  }

  /// Lift `BatchStart.tablePlan` from remnant A/B journals into
  /// [PendingParallelBatch.tablePlans], then delete `journal_a/b.log`.
  ///
  /// Remnant-only: `journalFile` / `recoverStartOffset` are read from the raw
  /// WAL meta JSON (not fields on [PendingParallelBatch]). Paths are built
  /// under [PathManager.getPageRedoRootPath] — no A/B helpers in PathManager.
  Future<void> _migrateParallelJournalIntoWalMeta(String spaceName) async {
    // V3 mid-upgrade still writes legacy JSON WAL meta; MetaFormatMigration
    // converts to .tobf later in the same V3 pass (before version bump).
    final walRoot = _dataStore.pathManager.getWalRootPath(spaceName: spaceName);
    final walMetaPath = path.join(walRoot, 'meta.json');
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
      indexUidMap: indexUidMap,
    );

    // Legacy sidecar unused by btree maxAutoIncrementId — async delete after bump.
    _scheduleLegacyFileDelete(path.join(newPath, 'maxid.txt'));
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

  /// Resolve and persist [GlobalConfig.pageSize] before bootstrap createTable.
  ///
  /// Order: already-configured cache → [oldGlobalConfig] → sample legacy
  /// meta.json (rename-前 paths via directory maps) → [InternalConfig.defaultPageSize].
  /// Persists only while unset (`copyWith` refuses to change a set pageSize).
  Future<void> _primePageSizeBeforeBootstrap({
    required GlobalConfig oldGlobalConfig,
    required Map<String, dynamic>? globalTableDirMap,
    required Map<String, Map<String, dynamic>> spaceTableDirMaps,
    required List<String> spaces,
  }) async {
    if (_dataStore.hasConfiguredPageSize) {
      _discoveredPageSize = _dataStore.configuredPageSize;
      return;
    }

    int? sampled;
    if (oldGlobalConfig.hasConfiguredPageSize) {
      sampled = oldGlobalConfig.pageSize;
    } else {
      sampled = await _samplePageSizeFromLegacyMeta(
        globalTableDirMap: globalTableDirMap,
        spaceTableDirMaps: spaceTableDirMaps,
        spaces: spaces,
      );
    }

    final resolved = sampled ?? InternalConfig.defaultPageSize;
    _discoveredPageSize = resolved;

    final cfg = await _dataStore.getGlobalConfig() ?? oldGlobalConfig;
    if (!cfg.hasConfiguredPageSize) {
      await _dataStore.saveGlobalConfig(
        cfg.copyWith(pageSize: resolved),
        propagateErrors: true,
      );
      Logger.info(
          'v3: primed GlobalConfig.pageSize=$resolved before bootstrap');
    }
  }

  /// Sample btreePageSize from the first available legacy table/index meta.json.
  /// Map-driven only (no full FS walk); stops at first valid value.
  Future<int?> _samplePageSizeFromLegacyMeta({
    required Map<String, dynamic>? globalTableDirMap,
    required Map<String, Map<String, dynamic>> spaceTableDirMaps,
    required List<String> spaces,
  }) async {
    if (_dataStore.instancePath == null) return null;

    if (globalTableDirMap != null) {
      for (final entry in globalTableDirMap.entries) {
        final key = entry.key;
        if (!key.startsWith('global:')) continue;
        final tableName = key.substring('global:'.length);
        if (tableName.isEmpty) continue;
        final dirIndex = _legacyDirIndex(entry.value) ?? 0;
        final sampled = await _samplePageSizeFromTableRoot(
          _globalTableRoot(dirIndex, tableName),
        );
        if (sampled != null) return sampled;
      }
    }

    for (final spaceName in spaces) {
      final map = spaceTableDirMaps[spaceName];
      if (map == null) continue;
      final prefix = '$spaceName:';
      for (final entry in map.entries) {
        final key = entry.key;
        if (!key.startsWith(prefix)) continue;
        final tableName = key.substring(prefix.length);
        if (tableName.isEmpty) continue;
        final dirIndex = _legacyDirIndex(entry.value) ?? 0;
        final sampled = await _samplePageSizeFromTableRoot(
          _spaceTableRoot(spaceName, dirIndex, tableName),
        );
        if (sampled != null) return sampled;
      }
    }
    return null;
  }

  String _globalTableRoot(int dirIndex, String leaf) {
    return pathJoin(
      _dataStore.instancePath!,
      'global',
      'tables_$dirIndex',
      leaf,
    );
  }

  String _spaceTableRoot(String spaceName, int dirIndex, String leaf) {
    return pathJoin(
      _dataStore.instancePath!,
      'spaces',
      spaceName,
      'tables_$dirIndex',
      leaf,
    );
  }

  Future<int?> _samplePageSizeFromTableRoot(String tableRoot) async {
    final fromData = await _readBtreePageSizeFromMetaJson(
      path.join(tableRoot, 'data', 'meta.json'),
    );
    if (fromData != null) return fromData;

    final indexDir = path.join(tableRoot, 'index');
    if (!await _dataStore.storage.existsDirectory(indexDir)) return null;

    final children =
        await _dataStore.storage.listDirectory(indexDir, recursive: false);
    for (final child in children) {
      final indexName = path.basename(child);
      if (indexName.isEmpty || indexName.startsWith('.')) continue;
      final fromIndex = await _readBtreePageSizeFromMetaJson(
        path.join(indexDir, indexName, 'meta.json'),
      );
      if (fromIndex != null) return fromIndex;
    }
    return null;
  }

  Future<int?> _readBtreePageSizeFromMetaJson(String metaPath) async {
    if (!await _dataStore.storage.existsFile(metaPath)) return null;
    try {
      final content = await _dataStore.storage.readAsString(metaPath);
      if (content == null || content.isEmpty) return null;
      final json = jsonDecode(content);
      if (json is! Map) return null;
      final sampled = (json['btreePageSize'] as num?)?.toInt();
      if (sampled != null && sampled > 0) return sampled;
    } catch (_) {
      // Ignore corrupt / unreadable meta during sampling.
    }
    return null;
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
    required Map<String, String> indexUidMap,
  }) async {
    if (indexUidMap.isEmpty ||
        !await _dataStore.storage.existsDirectory(indexDirPath)) {
      return;
    }
    for (final entry in indexUidMap.entries) {
      final legacyIndexName = entry.key;
      final indexUid = IndexUid(entry.value);

      var indexSubDir = path.join(indexDirPath, indexUid.value);
      var metaPath = path.join(indexSubDir, 'meta.json');

      if (!await _dataStore.storage.existsFile(metaPath)) {
        final legacySubDir = path.join(indexDirPath, legacyIndexName);
        final legacyMetaPath = path.join(legacySubDir, 'meta.json');
        if (await _dataStore.storage.existsFile(legacyMetaPath)) {
          indexSubDir = legacySubDir;
          metaPath = legacyMetaPath;
        } else {
          continue;
        }
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

        final nghMetaPath = path.join(indexSubDir, 'ngh', 'meta.json');
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

  /// Parse `TableDirectoryInfo.dirIndex` from legacy JSON map values.
  ///
  /// jsonDecode nested maps are often `Map<dynamic, dynamic>`, so a strict
  /// `is Map<String, dynamic>` check would miss valid entries and fall back
  /// to dirIndex 0 — looking up the wrong table directory.
  static int? _legacyDirIndex(dynamic entry) {
    if (entry is! Map) return null;
    final raw = entry['dirIndex'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return null;
  }
}
