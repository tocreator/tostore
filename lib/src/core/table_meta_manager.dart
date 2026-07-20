import 'dart:async';

import 'package:path/path.dart' show dirname;

import '../handler/binary_schema_codec.dart';
import '../handler/logger.dart';
import '../handler/space_manifest_codec.dart';
import '../handler/table_meta_codec.dart';
import '../model/db_exception.dart';
import '../model/db_result.dart';
import '../model/global_config.dart';
import '../model/id_generator.dart';
import '../model/meta_info.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/space_manifest.dart';
import '../model/system_table.dart';
import '../model/table_context.dart';
import '../model/table_identity.dart';
import '../model/table_meta.dart';
import '../model/table_schema.dart';
import '../query/query_condition.dart';
import 'data_store_impl.dart';
import 'transaction_context.dart';
import 'tree_cache.dart';
import 'yield_controller.dart';

/// Table meta manager — stores metadata in `_system_table_meta`.
class TableMetaManager {
  final DataStoreImpl _dataStore;

  /// Hot [TableMeta] cache. Managed by ResourceManager: [MemoryQuotaType.schema].
  TreeCache<TableMeta>? _tableMetaCache;

  /// Hot schema cache (TableSchema) using [TreeCache].
  /// Managed by ResourceManager quota: [MemoryQuotaType.schema].
  TreeCache<TableSchema>? _tableSchemaCache;

  /// O(1) lookup of full [TableMeta] (not subject to TreeCache eviction).
  final Map<TableUid, TableMeta> _metaByUid = <TableUid, TableMeta>{};

  /// Per-table index cache derived from [TableSchema].
  final Map<TableUid, _IndexListCacheEntry> _indexListCache =
      <TableUid, _IndexListCacheEntry>{};

  /// Per-table stable storage layout cache (keyed by tableUid).
  final Map<TableUid, FieldStorageLayout> _tableFieldLayoutCache =
      <TableUid, FieldStorageLayout>{};

  /// Per-table cached storage field structure derived from layout + schema.
  final Map<TableUid, List<FieldStructure>> _storageFieldStructCache =
      <TableUid, List<FieldStructure>>{};

  /// Loading futures to prevent thundering herd on concurrent meta reads.
  final Map<TableUid, Future<TableMeta?>> _metaLoadingFutures = {};

  static const String _deletedSlotFieldPrefix = '_system_storage_deleted_slot_';

  /// Name→uid inventory for **all** tables in the database (not space-filtered).
  ///
  /// After [loadAllTableMetaAsync] completes this is the complete lightweight
  /// listing source and is **not** cleared by TreeCache eviction of full
  /// [TableMeta]. Before it is ready, lookups must point-query the system
  /// table (never block startup on full load). Current-space visibility is
  /// applied only when listing with [listAllTables] `onlyCurrentSpace: true`.
  final Map<TableName, TableUid> _uidByName = {};

  /// Uid→name reverse inventory (same scope / lifetime as [_uidByName]).
  final Map<TableUid, TableName> _nameByUid = {};

  /// Global table UIDs in the name inventory (never in space activeUids).
  /// Used so [onlyCurrentSpace] listings always include globals without
  /// depending on full [TableMeta] still being hot in memory.
  final Set<TableUid> _globalTableUids = {};

  /// True once startup [loadAllTableMetaAsync] finished building name maps.
  bool _nameInventoryReady = false;

  /// Single-flight handle for [loadAllTableMetaAsync] (startup / explicit).
  Future<void>? _loadAllMetaFuture;

  /// Under-capacity data-dir usage only (count < maxEntriesPerDir).
  final Map<int, int> _globalDirCounts = {};
  final Map<int, int> _nonGlobalDirCounts = {};

  /// Deferred per-space metadata (inventory). Loaded asynchronously.
  final Map<String, SpaceManifest> _manifestBySpace = {};

  /// Serializes [allocateDirIndex] against concurrent creates.
  Future<void> _dirAllocChain = Future.value();

  TableMetaManager(this._dataStore);

  /// True if any table meta is currently held in memory.
  bool get hasAnyTableMeta => _metaByUid.isNotEmpty;

  /// Whether the lightweight name↔uid inventory is complete for listing.
  bool get isNameInventoryReady => _nameInventoryReady;

  /// Mark name inventory complete (e.g. memory-mode startup after all schemas
  /// are registered via [registerTableSchemaInMemory]).
  void markNameInventoryReady() {
    _nameInventoryReady = true;
    _ensureTableMetaCache().setFullyCached('all', true);
  }

  /// Resolve tableUid from tableName (memory → fully-cached miss → system table).
  Future<TableUid?> getUidByName(TableName tableName) =>
      resolveTableUidFromName(tableName);

  /// Resolve tableName from tableUid via [getTableMeta] (system-table aware).
  Future<TableName?> getNameByUid(TableUid tableUid) async {
    if (tableUid.isEmpty) return null;
    final meta = await getTableMeta(tableUid);
    return meta?.tableName;
  }

  /// Memory-only name→uid peek. Do not use for existence / correctness.
  TableUid? _peekUidByName(TableName tableName) {
    if (tableName.isEmpty) return null;
    final cached = _uidByName[tableName];
    if (cached != null) return cached;
    final asUid = TableUid(tableName.value);
    if (_metaByUid.containsKey(asUid) || _tableMetaCache?.get(asUid) != null) {
      return asUid;
    }
    return null;
  }

  /// Memory-only uid→name peek (logs / best-effort display only).
  TableName? _peekNameByUid(TableUid tableUid) {
    if (tableUid.isEmpty) return null;
    return _nameByUid[tableUid] ?? _metaByUid[tableUid]?.tableName;
  }

  /// Normalize a persisted uid-or-name field to a stable map key (prefers uid).
  Future<String> normalizeTableFieldKey(String field) async {
    if (field.isEmpty) return field;
    if (await isActiveTableUidKey(field)) return field;
    final uid = await getUidByName(TableName(field));
    return uid?.value ?? field;
  }

  /// Whether [normalizedKey] is a known table uid (system-table aware).
  Future<bool> isActiveTableUidKey(String normalizedKey) async {
    if (normalizedKey.isEmpty) return false;
    return await getTableMeta(TableUid(normalizedKey)) != null;
  }

  /// Resolve user-visible table name from a persisted uid-or-name field.
  Future<TableName?> resolveTableNameFromField(String field) async {
    if (field.isEmpty) return null;
    final byUid = await getNameByUid(TableUid(field));
    if (byUid != null) return byUid;
    final uid = await getUidByName(TableName(field));
    if (uid != null) return TableName(field);
    return null;
  }

  /// Whether [field] refers to the same table as [tableUid] (legacy name aware).
  Future<bool> tableFieldMatches(String field, TableUid tableUid) async {
    if (field.isEmpty || tableUid.isEmpty) return false;
    if (field == tableUid.value) return true;
    final resolved = await getUidByName(TableName(field));
    return resolved == tableUid;
  }

  /// Memory peek only (no I/O). Prefer [getTableMeta] on engine paths.
  TableMeta? _peekTableMeta(TableUid tableUid) {
    return _metaByUid[tableUid] ?? _tableMetaCache?.get(tableUid);
  }

  TreeCache<TableSchema> _ensureTableSchemaCache() {
    final existing = _tableSchemaCache;
    if (existing != null) return existing;

    final int maxBytes =
        _dataStore.resourceManager?.getSchemaCacheSize() ?? (50 * 1024 * 1024);
    final int minBytes = 50 * 1024 * 1024;

    final cache = TreeCache<TableSchema>(
      sizeCalculator: _estimateTableSchemaSize,
      maxByteThreshold: maxBytes,
      minByteThreshold: minBytes,
      debugLabel: 'TableSchemaCache',
    );
    _tableSchemaCache = cache;
    return cache;
  }

  TreeCache<TableMeta> _ensureTableMetaCache() {
    final existing = _tableMetaCache;
    if (existing != null) return existing;

    final int maxBytes =
        _dataStore.resourceManager?.getSchemaCacheSize() ?? (50 * 1024 * 1024);
    final int minBytes = 50 * 1024 * 1024;

    final cache = TreeCache<TableMeta>(
      sizeCalculator: _estimateTableMetaSize,
      maxByteThreshold: maxBytes,
      minByteThreshold: minBytes,
      debugLabel: 'TableMetaCache',
      // Quota eviction clears per-uid group markers only; drop the global
      // "all metas loaded" bit so miss paths re-query `_system_table_meta`.
      onEvicted: (_) {
        _tableMetaCache?.setFullyCached('all', false);
      },
    );
    _tableMetaCache = cache;
    return cache;
  }

  /// Memory peek of [TableSchema] only (layout/struct identical checks).
  /// Correctness paths must use [getTableSchema] / [getTableMeta].
  TableSchema? _peekTableSchema(TableUid tableUid) {
    if (tableUid.isEmpty) return null;
    return _metaByUid[tableUid]?.schema ??
        _tableMetaCache?.get(tableUid)?.schema ??
        _tableSchemaCache?.get(tableUid);
  }

  /// Hotspot schema cache + derived index lists (called from [_cacheTableMeta]).
  void _cacheTableSchema(TableUid tableUid, TableSchema schema) {
    _ensureTableSchemaCache().put(tableUid, schema);
    _indexListCache[tableUid] = _buildIndexListCache(schema);
    _storageFieldStructCache.remove(tableUid);
    if (schema.schemaVersion != null) {
      _dataStore.migrationManager?.registerSchemaVersion(schema);
    }
  }

  void _cacheTableMeta(TableMeta meta) {
    _metaByUid[meta.tableUid] = meta;
    _ensureTableMetaCache().put(meta.tableUid, meta);
    _tableFieldLayoutCache[meta.tableUid] = meta.fieldLayout;
    _storageFieldStructCache.remove(meta.tableUid);
    _cacheTableSchema(meta.tableUid, meta.schema);
  }

  /// Register [schema] as a full in-memory [TableMeta] visible to [getTableMeta].
  ///
  /// Used by memory-mode startup and other callers that previously only wrote
  /// the schema TreeCache (which [getTableSchema] could not see).
  Future<TableMeta> registerTableSchemaInMemory(TableSchema schema) async {
    var resolved = schema;
    if (resolved.tableUid.isEmpty &&
        SystemTable.isTableMetaTable(resolved.name)) {
      resolved = resolved.copyWith(tableUid: SystemTable.tableMetaTableUid);
    }

    final uid = resolved.tableUid;
    final existing = uid.isNotEmpty ? _peekTableMeta(uid) : null;
    final layout = existing?.fieldLayout ??
        (uid.isNotEmpty ? _tableFieldLayoutCache[uid] : null) ??
        _createInitialFieldStorageLayout(resolved);
    final now = DateTime.now();
    final int? knownDirIndex = SystemTable.isTableMetaTable(resolved.name)
        ? SystemTable.tableMetaDirIndex
        : existing?.dirIndex;

    return saveTableMeta(
      TableMeta(
        tableUid: uid,
        tableName: TableName(resolved.name),
        isGlobal: resolved.isGlobal,
        schema: resolved,
        fieldLayout: layout,
        dirIndex: knownDirIndex ?? 0,
        createdAt: existing?.createdAt ?? now,
        updatedAt: now,
      ),
      memoryOnly: true,
      dirIndex: knownDirIndex,
      layoutOverride: layout,
    );
  }

  /// Hard-coded [TableContext] for `_system_table_meta` (no disk read).
  TableContext bootstrapTableMetaContext() {
    return TableContext(
      tableUid: SystemTable.tableMetaTableUid,
      tableName: TableName(SystemTable.tableMetaName),
      isGlobal: true,
      dirIndex: SystemTable.tableMetaDirIndex,
      schema: SystemTable.tableMetaTable(),
    );
  }

  TableMeta _buildBootstrapTableMeta() {
    final schema = SystemTable.tableMetaTable();
    final layout = _tableFieldLayoutCache[SystemTable.tableMetaTableUid] ??
        _createInitialFieldStorageLayout(schema);
    final now = DateTime.now();
    final existing = _metaByUid[SystemTable.tableMetaTableUid];
    return TableMeta(
      tableUid: SystemTable.tableMetaTableUid,
      tableName: TableName(SystemTable.tableMetaName),
      isGlobal: true,
      schema: schema,
      fieldLayout: layout,
      dirIndex: SystemTable.tableMetaDirIndex,
      extra: existing?.extra,
      createdAt: existing?.createdAt ?? now,
      updatedAt: existing?.updatedAt ?? now,
    );
  }

  /// Get [TableContext] by tableUid (asynchronous).
  ///
  /// Uses [getTableMeta]: memory → fully-cached miss = absent → else system table.
  Future<TableContext?> getTableContext(TableUid tableUid) async {
    if (tableUid.isEmpty) return null;
    var uid = tableUid;
    var meta = await getTableMeta(uid);
    if (meta == null) {
      final legacyUid = await getUidByName(TableName(uid.value));
      if (legacyUid != null && legacyUid != uid) {
        uid = legacyUid;
        meta = await getTableMeta(uid);
      }
    }
    if (meta == null) return null;
    return TableContext(
      tableUid: meta.tableUid,
      tableName: meta.tableName,
      isGlobal: meta.isGlobal,
      dirIndex: meta.dirIndex,
      schema: meta.schema,
    );
  }

  /// Get [TableContext] by schemaVersion (O(1) lookup in migrationManager).
  TableContext getTableContextByVersion(String schemaVersion) {
    final migrationMgr = _dataStore.migrationManager;
    final schema = migrationMgr?.getTableSchemaByVersion(schemaVersion);
    if (schema == null) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Table schema for version "$schemaVersion" not found in memory caches.',
        )
      ]);
    }
    final uid = schema.tableUid;
    if (uid.isEmpty) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'TableUid is empty for schema version "$schemaVersion".',
        )
      ]);
    }
    final meta = _peekTableMeta(uid);
    if (meta == null) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Table meta not found for table "${schema.name}" (schema version "$schemaVersion").',
        )
      ]);
    }
    return TableContext(
      tableUid: uid,
      tableName: meta.tableName,
      isGlobal: meta.isGlobal,
      dirIndex: meta.dirIndex,
      schema: schema,
    );
  }

  /// Remove cached schema / meta for [tableUid].
  void removeCachedTableSchema(TableUid tableUid) {
    _tableSchemaCache?.remove(tableUid);
    _tableMetaCache?.remove(tableUid);
    _indexListCache.remove(tableUid);
    _tableFieldLayoutCache.remove(tableUid);
    _storageFieldStructCache.remove(tableUid);
  }

  /// Current schema cache size in bytes (incremental tracked).
  int getCurrentSchemaCacheSize() {
    final schemaBytes = _tableSchemaCache?.estimatedTotalSizeBytes ?? 0;
    final metaBytes = _tableMetaCache?.estimatedTotalSizeBytes ?? 0;
    return schemaBytes + metaBytes;
  }

  /// Evict a ratio of schema cache entries under memory pressure.
  Future<void> evictSchemaCache({double ratio = 0.3}) async {
    final schemaCache = _tableSchemaCache;
    if (schemaCache != null) {
      await schemaCache.cleanup(removeRatio: ratio);
    }
    final metaCache = _tableMetaCache;
    if (metaCache != null) {
      await metaCache.cleanup(removeRatio: ratio);
    }
  }

  /// Load deferred space metadata from `space_manifest.bin`.
  Future<void> loadSpaceManifest(String spaceName) async {
    final path = _dataStore.pathManager.getSpaceManifestPath(spaceName);
    if (await _dataStore.storage.existsFile(path)) {
      final bytes = await _dataStore.storage.readAsBytes(path);
      _manifestBySpace[spaceName] = SpaceManifestCodec.decode(bytes);
      _rebuildNameLookups();
      return;
    }
    _manifestBySpace[spaceName] = SpaceManifest.empty;
    _rebuildNameLookups();
  }

  /// Get the deferred manifest for a space (lazy-loaded from disk).
  Future<SpaceManifest> getSpaceManifest(String spaceName) async {
    var manifest = _manifestBySpace[spaceName];
    if (manifest == null) {
      await loadSpaceManifest(spaceName);
      manifest = _manifestBySpace[spaceName];
    }
    return manifest ?? SpaceManifest.empty;
  }

  /// Visible table UIDs in [spaceName]: **all global tables** ∪ non-global
  /// UIDs from [SpaceManifest.activeTableUids].
  ///
  /// Globals are never stored in the space manifest — they are merged from
  /// [_globalTableUids] after the one-shot name inventory is ready (awaits
  /// [loadAllTableMetaAsync] if still building — never a second full scan).
  ///
  /// [onlyUserTables] hides `_system_*` (use `true` on user-facing paths such
  /// as [DataStoreImpl.getSpaceInfo]; engine paths keep the default `false`).
  Future<List<TableUid>> getActiveUidsForSpace(
    String spaceName, {
    bool onlyUserTables = false,
  }) async {
    await _ensureNameInventoryReady();
    await getSpaceManifest(spaceName);
    final nonGlobal = _activeUidsForSpace(spaceName);

    final seen = <TableUid>{};
    final out = <TableUid>[];
    void addAll(Iterable<TableUid> uids) {
      for (final uid in uids) {
        if (uid.isEmpty || !seen.add(uid)) continue;
        out.add(uid);
      }
    }

    addAll(_globalTableUids);
    addAll(nonGlobal);

    if (!onlyUserTables) return out;

    final filtered = <TableUid>[];
    for (final uid in out) {
      if (await _isSystemTableUid(uid)) continue;
      filtered.add(uid);
    }
    return filtered;
  }

  /// Wait for the startup name inventory (joins the existing single-flight
  /// [loadAllTableMetaAsync]; does not start a parallel full-table scan).
  Future<void> _ensureNameInventoryReady() async {
    if (_nameInventoryReady) return;
    await loadAllTableMetaAsync();
  }

  Future<bool> _isSystemTableUid(TableUid tableUid) async {
    final peeked = _peekNameByUid(tableUid);
    if (peeked != null) {
      return SystemTable.isSystemTable(peeked.value);
    }
    final meta = await getTableMeta(tableUid);
    if (meta == null) return false;
    return SystemTable.isSystemTable(meta.tableName.value);
  }

  /// Persist deferred space metadata to `space_manifest.bin`.
  Future<void> saveSpaceManifest(String spaceName) async {
    final path = _dataStore.pathManager.getSpaceManifestPath(spaceName);
    final manifest = _manifestBySpace[spaceName] ?? SpaceManifest.empty;
    final bytes = SpaceManifestCodec.encode(manifest);
    await _dataStore.storage.ensureDirectoryExists(dirname(path));
    await _dataStore.storage.writeAsBytes(path, bytes);
  }

  /// Raw non-global active UIDs from the space manifest (no globals).
  List<TableUid> _activeUidsForSpace(String spaceName) {
    return _manifestBySpace[spaceName]?.activeTableUids ?? const <TableUid>[];
  }

  Future<void> _updateActiveTableUids(
    String spaceName,
    void Function(List<TableUid> uids) mutate, {
    bool persist = true,
  }) async {
    final current = List<TableUid>.from(_activeUidsForSpace(spaceName));
    mutate(current);
    _manifestBySpace[spaceName] =
        (_manifestBySpace[spaceName] ?? SpaceManifest.empty)
            .copyWith(activeTableUids: current);
    if (persist) {
      await saveSpaceManifest(spaceName);
    }
  }

  /// Rebuild [_uidByName] / [_nameByUid] / [_globalTableUids] from [_metaByUid].
  void _rebuildNameLookups() {
    _uidByName.clear();
    _nameByUid.clear();
    _globalTableUids.clear();

    for (final meta in _metaByUid.values) {
      _uidByName[meta.tableName] = meta.tableUid;
      _nameByUid[meta.tableUid] = meta.tableName;
      if (meta.isGlobal) {
        _globalTableUids.add(meta.tableUid);
      }
    }
  }

  void _rebuildDirCountsFromMeta() {
    _globalDirCounts.clear();
    _nonGlobalDirCounts.clear();
    final max = _dataStore.maxEntriesPerDir;
    final globalRaw = <int, int>{};
    final nonGlobalRaw = <int, int>{};

    for (final meta in _metaByUid.values) {
      final map = meta.isGlobal ? globalRaw : nonGlobalRaw;
      map[meta.dirIndex] = (map[meta.dirIndex] ?? 0) + 1;
    }

    for (final e in globalRaw.entries) {
      if (e.value < max) {
        _globalDirCounts[e.key] = e.value;
      }
    }
    for (final e in nonGlobalRaw.entries) {
      if (e.value < max) {
        _nonGlobalDirCounts[e.key] = e.value;
      }
    }
  }

  void _incrementDirCount(bool isGlobal, int dirIndex) {
    final usage = isGlobal ? _globalDirCounts : _nonGlobalDirCounts;
    final max = _dataStore.maxEntriesPerDir;
    final next = (usage[dirIndex] ?? 0) + 1;
    if (next >= max) {
      usage.remove(dirIndex);
    } else {
      usage[dirIndex] = next;
    }
  }

  void _decrementDirCount(bool isGlobal, int dirIndex) {
    final usage = isGlobal ? _globalDirCounts : _nonGlobalDirCounts;
    final max = _dataStore.maxEntriesPerDir;
    if (!usage.containsKey(dirIndex)) {
      // Was at capacity (not tracked); freeing one slot brings it under capacity.
      usage[dirIndex] = max - 1;
      return;
    }
    final current = usage[dirIndex]!;
    if (current <= 1) {
      usage.remove(dirIndex);
    } else {
      usage[dirIndex] = current - 1;
    }
  }

  void _registerMetaInLookups(
    TableMeta meta, {
    bool skipDirCountIncrement = false,
  }) {
    final old = _metaByUid[meta.tableUid];
    if (old != null) {
      _unregisterMetaFromLookups(old);
    }

    _metaByUid[meta.tableUid] = meta;
    // Pre-counted only applies to brand-new registrations (allocateDirIndex
    // already bumped usage). Updates always re-count after unregister.
    if (!skipDirCountIncrement || old != null) {
      _incrementDirCount(meta.isGlobal, meta.dirIndex);
    }

    // Full-DB name inventory (space visibility is applied only at list time).
    _uidByName[meta.tableName] = meta.tableUid;
    _nameByUid[meta.tableUid] = meta.tableName;
    if (meta.isGlobal) {
      _globalTableUids.add(meta.tableUid);
    } else {
      _globalTableUids.remove(meta.tableUid);
    }
  }

  void _unregisterMetaFromLookups(TableMeta meta) {
    _metaByUid.remove(meta.tableUid);
    _decrementDirCount(meta.isGlobal, meta.dirIndex);
    _uidByName.remove(meta.tableName);
    _nameByUid.remove(meta.tableUid);
    _globalTableUids.remove(meta.tableUid);
  }

  /// Clear all in-memory caches and reset state.
  Future<void> dispose() async {
    if (_metaLoadingFutures.isNotEmpty) {
      try {
        await Future.wait(_metaLoadingFutures.values);
      } catch (_) {}
    }
    _tableSchemaCache?.clear();
    _tableMetaCache?.clear();
    _indexListCache.clear();
    _tableFieldLayoutCache.clear();
    _storageFieldStructCache.clear();
    _metaLoadingFutures.clear();
    _metaByUid.clear();
    _uidByName.clear();
    _nameByUid.clear();
    _globalTableUids.clear();
    _nameInventoryReady = false;
    _loadAllMetaFuture = null;
    _manifestBySpace.clear();
    _globalDirCounts.clear();
    _nonGlobalDirCounts.clear();
  }

  /// Invalidate meta caches (keeps space manifests).
  void invalidateCache() {
    _tableMetaCache?.clear();
    _tableSchemaCache?.clear();
    _metaByUid.clear();
    _uidByName.clear();
    _nameByUid.clear();
    _globalTableUids.clear();
    _nameInventoryReady = false;
    _loadAllMetaFuture = null;
    _tableMetaCache?.setFullyCached('all', false);
    _globalDirCounts.clear();
    _nonGlobalDirCounts.clear();
    _indexListCache.clear();
    _tableFieldLayoutCache.clear();
    _storageFieldStructCache.clear();
    _metaLoadingFutures.clear();
  }

  int _estimateTableSchemaSize(TableSchema schema) {
    int size = 256;
    size += schema.name.length * 2;
    size += schema.primaryKey.length * 2;
    size += 64;

    if (schema.fields.isNotEmpty) {
      size += schema.fields.length * 140;
      for (final f in schema.fields) {
        size += f.name.length * 2;
        size += 24;
      }
    }

    if (schema.indexes.isNotEmpty) {
      size += schema.indexes.length * 120;
      for (final idx in schema.indexes) {
        size += (idx.indexName?.length ?? 0) * 2;
        size += idx.fields.length * 24;
      }
    }
    if (schema.foreignKeys.isNotEmpty) {
      size += schema.foreignKeys.length * 180;
      for (final fk in schema.foreignKeys) {
        size += fk.actualName.length * 2;
        size += fk.referencedTable.length * 2;
        size += fk.referencedFields.length * 24;
      }
    }

    return size;
  }

  int _estimateFieldStorageLayoutSize(FieldStorageLayout layout) {
    return layout.slots.length * 64 + 16;
  }

  int _estimateTableMetaSize(TableMeta meta) {
    return _estimateTableSchemaSize(meta.schema) +
        _estimateFieldStorageLayoutSize(meta.fieldLayout) +
        128;
  }

  FieldStorageLayout _createInitialFieldStorageLayout(TableSchema schema) {
    final slots = <FieldStorageSlot>[];
    int nextSlotId = 0;
    for (final field in schema.fields) {
      slots.add(FieldStorageSlot(
        slotId: nextSlotId++,
        fieldName: field.name,
        typeIndex: field.type.index,
        deleted: false,
        fieldId: field.fieldId ?? field.name,
      ));
    }
    return FieldStorageLayout(nextSlotId: nextSlotId, slots: slots);
  }

  FieldStorageLayout evolveFieldStorageLayout({
    FieldStorageLayout? existingLayout,
    required TableSchema nextSchema,
    Map<String, String> renameHints = const <String, String>{},
  }) {
    if (existingLayout == null) {
      return _createInitialFieldStorageLayout(nextSchema);
    }

    final slots = <FieldStorageSlot>[...existingLayout.slots];
    int nextSlotId = existingLayout.nextSlotId;

    for (int i = 0; i < slots.length; i++) {
      slots[i] = slots[i].copyWith(deleted: true);
    }

    for (final field in nextSchema.fields) {
      int matchIdx = -1;

      if (field.fieldId != null && field.fieldId!.isNotEmpty) {
        matchIdx = slots.indexWhere((s) => s.fieldId == field.fieldId);
      }

      if (matchIdx == -1 && renameHints.isNotEmpty) {
        String oldName = '';
        String currentTarget = field.name;
        bool found = true;
        while (found) {
          final match = renameHints.entries.firstWhere(
            (e) => e.value == currentTarget,
            orElse: () => const MapEntry('', ''),
          );
          if (match.key.isNotEmpty) {
            oldName = match.key;
            currentTarget = match.key;
          } else {
            found = false;
          }
        }

        if (oldName.isNotEmpty) {
          matchIdx = slots.indexWhere((s) => s.fieldName == oldName);
        }
      }

      if (matchIdx == -1) {
        matchIdx = slots.indexWhere((s) => s.fieldName == field.name);
      }

      if (matchIdx != -1) {
        slots[matchIdx] = slots[matchIdx].copyWith(
          fieldName: field.name,
          fieldId: field.fieldId ?? slots[matchIdx].fieldId,
          typeIndex: field.type.index,
          deleted: false,
        );
      } else {
        slots.add(FieldStorageSlot(
          slotId: nextSlotId++,
          fieldName: field.name,
          typeIndex: field.type.index,
          deleted: false,
          fieldId: field.fieldId ?? field.name,
        ));
      }
    }

    return FieldStorageLayout(nextSlotId: nextSlotId, slots: slots);
  }

  bool _canReuseExistingFieldStorageLayout(
    FieldStorageLayout layout,
    TableSchema schema, {
    Map<String, String> renameHints = const <String, String>{},
  }) {
    if (renameHints.isNotEmpty) {
      return false;
    }

    if (schema.fields.isEmpty) {
      return true;
    }

    final activeSlots = <FieldStorageSlot>[
      for (final slot in layout.slots)
        if (!slot.deleted) slot,
    ];

    if (activeSlots.length != schema.fields.length) {
      return false;
    }

    final activeByName = <String, FieldStorageSlot>{};
    for (final slot in activeSlots) {
      if (!activeByName.containsKey(slot.fieldName)) {
        activeByName[slot.fieldName] = slot;
      }
    }

    for (final field in schema.fields) {
      final matched = activeByName[field.name];
      if (matched == null) {
        return false;
      }
      if (matched.fieldName != field.name ||
          matched.typeIndex != field.type.index) {
        return false;
      }
    }

    return true;
  }

  List<FieldStructure> _buildStorageFieldStructureFromLayout(
    FieldStorageLayout layout,
  ) {
    if (layout.slots.isEmpty) {
      return const <FieldStructure>[];
    }
    final out = <FieldStructure>[];
    for (final slot in layout.slots) {
      final name = slot.deleted
          ? '$_deletedSlotFieldPrefix${slot.slotId}'
          : slot.fieldName;
      out.add(FieldStructure(name: name, typeIndex: slot.typeIndex));
    }
    return List<FieldStructure>.unmodifiable(out);
  }

  /// Get stable storage field layout for a table.
  Future<FieldStorageLayout> getTableFieldLayout(
    TableUid tableUid, {
    TableSchema? schema,
  }) async {
    final cached = _tableFieldLayoutCache[tableUid];
    if (cached != null) {
      if (schema == null) {
        return cached;
      }
      final cachedSchema = _peekTableSchema(tableUid);
      if (cachedSchema != null && identical(cachedSchema, schema)) {
        return cached;
      }
    }

    final meta = await getTableMeta(tableUid);
    if (meta != null) {
      _tableFieldLayoutCache[tableUid] = meta.fieldLayout;
      return meta.fieldLayout;
    }

    final resolvedSchema = schema ?? await getTableSchema(tableUid);
    if (resolvedSchema == null) {
      return const FieldStorageLayout(
          nextSlotId: 0, slots: <FieldStorageSlot>[]);
    }

    final derived = _createInitialFieldStorageLayout(resolvedSchema);
    _tableFieldLayoutCache[tableUid] = derived;
    return derived;
  }

  /// Get stable storage field structure used by the record binary codec.
  Future<List<FieldStructure>> getStorageFieldStructure(
    TableUid tableUid, {
    TableSchema? schema,
    FieldStorageLayout? layoutOverride,
  }) async {
    if (layoutOverride != null) {
      return _buildStorageFieldStructureFromLayout(layoutOverride);
    }

    final resolvedSchema = schema ?? await getTableSchema(tableUid);
    if (resolvedSchema == null) {
      return const <FieldStructure>[];
    }

    final cachedSchema = _peekTableSchema(tableUid);
    final useCache = schema == null ||
        (cachedSchema != null && identical(cachedSchema, resolvedSchema));
    if (useCache) {
      final cached = _storageFieldStructCache[tableUid];
      if (cached != null) {
        return cached;
      }
    }

    final layout = await getTableFieldLayout(tableUid, schema: resolvedSchema);
    final struct = _buildStorageFieldStructureFromLayout(layout);
    if (useCache) {
      _storageFieldStructCache[tableUid] = struct;
    }
    return struct;
  }

  /// Persist only table field layout without modifying schema payload.
  Future<void> saveTableFieldLayout(
    TableUid tableUid,
    FieldStorageLayout layout, {
    TableSchema? schema,
  }) async {
    final existing = await getTableMeta(tableUid);
    final resolvedSchema = schema ?? existing?.schema;
    final name = _peekNameByUid(tableUid)?.value ?? resolvedSchema?.name;
    if (existing == null || resolvedSchema == null || name == null) {
      final logName = name ?? _peekNameByUid(tableUid)?.value ?? 'unknown';
      throw DbException([
        SchemaValidationStatus(
          type: ResultType.devTableNotFound,
          message: 'Table schema not found for table: $logName',
          tableName: logName,
        ),
      ]);
    }

    await updateTableMeta(
      tableUid,
      schema: resolvedSchema,
      fieldLayout: layout,
    );
  }

  /// Normalize a decoded record to user schema shape.
  Map<String, dynamic> normalizeRecordToSchema(
    TableSchema schema,
    Map<String, dynamic> record, {
    bool includePrimaryKey = true,
  }) {
    final out = <String, dynamic>{};
    if (includePrimaryKey && record.containsKey(schema.primaryKey)) {
      out[schema.primaryKey] = record[schema.primaryKey];
    }
    for (final field in schema.fields) {
      if (record.containsKey(field.name)) {
        out[field.name] = record[field.name];
      } else {
        out[field.name] = field.getDefaultValue();
      }
    }
    return out;
  }

  /// Get consolidated index list for a table (explicit + implicit).
  List<IndexSchema> getAllIndexesFor(TableSchema schema) {
    final cacheKey = schema.tableUid;
    final entry = _indexListCache[cacheKey] ?? _buildIndexListCache(schema);
    _indexListCache[cacheKey] = entry;
    return entry.allIndexes;
  }

  /// Get all unique indexes (including composite unique indexes) for a table.
  List<IndexSchema> getUniqueIndexesFor(TableSchema schema) {
    final cacheKey = schema.tableUid;
    final entry = _indexListCache[cacheKey] ?? _buildIndexListCache(schema);
    _indexListCache[cacheKey] = entry;
    return entry.uniqueIndexes;
  }

  /// Get all non-vector (B+Tree) indexes for a table.
  List<IndexSchema> getBtreeIndexesFor(TableSchema schema) {
    final cacheKey = schema.tableUid;
    final entry = _indexListCache[cacheKey] ?? _buildIndexListCache(schema);
    _indexListCache[cacheKey] = entry;
    return entry.btreeIndexes;
  }

  /// Get all vector indexes for a table.
  List<IndexSchema> getVectorIndexesFor(TableSchema schema) {
    final cacheKey = schema.tableUid;
    final entry = _indexListCache[cacheKey] ?? _buildIndexListCache(schema);
    _indexListCache[cacheKey] = entry;
    return entry.vectorIndexes;
  }

  /// Async helper by tableUid – mainly for management / background tasks.
  Future<List<IndexSchema>> getAllIndexesForTable(TableUid tableUid) async {
    final schema = await getTableSchema(tableUid);
    if (schema == null) return const <IndexSchema>[];
    return getAllIndexesFor(schema);
  }

  /// Async helper by tableUid – unique indexes only.
  Future<List<IndexSchema>> getUniqueIndexesForTable(TableUid tableUid) async {
    final schema = await getTableSchema(tableUid);
    if (schema == null) return const <IndexSchema>[];
    return getUniqueIndexesFor(schema);
  }

  /// Async helper by tableUid – vector indexes only.
  Future<List<IndexSchema>> getVectorIndexesForTable(TableUid tableUid) async {
    final schema = await getTableSchema(tableUid);
    if (schema == null) return const <IndexSchema>[];
    return getVectorIndexesFor(schema);
  }

  _IndexListCacheEntry _indexCacheEntryFor(TableSchema schema) {
    final cacheKey = schema.tableUid;
    final entry = _indexListCache[cacheKey] ?? _buildIndexListCache(schema);
    _indexListCache[cacheKey] = entry;
    return entry;
  }

  /// O(1) lookup of [IndexSchema] by stable [IndexUid].
  IndexSchema? findIndexSchemaByUid(TableSchema schema, IndexUid indexUid) {
    if (indexUid.isEmpty) return null;
    return _indexCacheEntryFor(schema).byUid[indexUid];
  }

  /// O(1) lookup by uid-or-legacy-name field (compat path only on alias miss).
  IndexSchema? findIndexSchemaByField(TableSchema schema, String field) {
    if (field.isEmpty) return null;
    final entry = _indexCacheEntryFor(schema);
    final byUid = entry.byUid[field];
    if (byUid != null) return byUid;
    return entry.byAlias[field];
  }

  /// Resolve a persisted uid-or-legacy-name field to a stable [IndexUid].
  IndexUid resolveIndexUidFromField(TableSchema schema, String field) {
    if (field.isEmpty) return IndexUid.empty;
    final entry = _indexCacheEntryFor(schema);
    if (entry.byUid.containsKey(field)) return IndexUid(field);
    final byAlias = entry.byAlias[field];
    if (byAlias != null && byAlias.indexUid.isNotEmpty) {
      return byAlias.indexUid;
    }
    return IndexUid(field);
  }

  /// Build [IndexContext] from a stable [IndexUid] (returns null if unknown).
  IndexContext? resolveIndexContext(TableContext table, IndexUid indexUid) {
    if (indexUid.isEmpty) return null;
    final idx = findIndexSchemaByUid(table.schema, indexUid);
    if (idx == null) return null;
    return IndexContext(
      indexUid: indexUid,
      indexName: IndexName(idx.indexName ?? idx.actualIndexName),
      schema: idx,
      table: table,
    );
  }

  /// Resolve [IndexContext] from uid-or-legacy-name (compat only on cache miss).
  IndexContext? resolveIndexContextFromField(
    TableContext table,
    String uidOrName,
  ) {
    if (uidOrName.isEmpty) return null;
    final indexUid = resolveIndexUidFromField(table.schema, uidOrName);
    return resolveIndexContext(table, indexUid) ??
        (findIndexSchemaByField(table.schema, uidOrName) == null
            ? null
            : IndexContext(
                indexUid: indexUid,
                indexName: IndexName(uidOrName),
                schema: findIndexSchemaByField(table.schema, uidOrName)!,
                table: table,
              ));
  }

  /// Allocate a data directory index for a new table.
  ///
  /// Prefers under-capacity dirs rebuilt after [loadAllTableMetaAsync].
  /// Otherwise advances [GlobalConfig] high-water
  /// (`last*DirIndex` / `last*DirEntries`) with no extra KV IO.
  Future<int> allocateDirIndex(bool isGlobal) {
    final done = Completer<int>();
    _dirAllocChain = _dirAllocChain.then((_) async {
      try {
        done.complete(await _allocateDirIndexUnlocked(isGlobal));
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  Future<int> _allocateDirIndexUnlocked(bool isGlobal) async {
    final usage = isGlobal ? _globalDirCounts : _nonGlobalDirCounts;
    final max = _dataStore.maxEntriesPerDir;

    int? selectedDir;
    var minCount = max;
    for (final e in usage.entries) {
      if (e.value < minCount) {
        selectedDir = e.key;
        minCount = e.value;
      }
    }

    if (selectedDir != null) {
      final next = minCount + 1;
      if (next >= max) {
        usage.remove(selectedDir);
      } else {
        usage[selectedDir] = next;
      }
      await _touchDirHighWater(
        isGlobal: isGlobal,
        dirIndex: selectedDir,
        entriesInDir: next > max ? max : next,
      );
      return selectedDir;
    }

    final config = await _dataStore.getGlobalConfig() ?? GlobalConfig();
    var index =
        isGlobal ? config.lastGlobalDirIndex : config.lastNonGlobalDirIndex;
    var entries =
        isGlobal ? config.lastGlobalDirEntries : config.lastNonGlobalDirEntries;

    if (entries >= max) {
      index += 1;
      entries = 1;
    } else {
      entries += 1;
    }

    final updated = isGlobal
        ? config.copyWith(
            lastGlobalDirIndex: index,
            lastGlobalDirEntries: entries,
          )
        : config.copyWith(
            lastNonGlobalDirIndex: index,
            lastNonGlobalDirEntries: entries,
          );
    await _dataStore.saveGlobalConfig(updated);

    if (entries < max) {
      usage[index] = entries;
    }
    return index;
  }

  /// Keep GlobalConfig high-water consistent when packing an existing dir.
  Future<void> _touchDirHighWater({
    required bool isGlobal,
    required int dirIndex,
    required int entriesInDir,
  }) async {
    final config = await _dataStore.getGlobalConfig() ?? GlobalConfig();
    final lastIndex =
        isGlobal ? config.lastGlobalDirIndex : config.lastNonGlobalDirIndex;
    final lastEntries =
        isGlobal ? config.lastGlobalDirEntries : config.lastNonGlobalDirEntries;

    if (dirIndex < lastIndex) return;
    if (dirIndex == lastIndex && entriesInDir <= lastEntries) return;

    final updated = isGlobal
        ? config.copyWith(
            lastGlobalDirIndex: dirIndex,
            lastGlobalDirEntries: entriesInDir,
          )
        : config.copyWith(
            lastNonGlobalDirIndex: dirIndex,
            lastNonGlobalDirEntries: entriesInDir,
          );
    await _dataStore.saveGlobalConfig(updated);
  }

  /// Load [TableMeta] by stable uid — the single entry for meta / routing.
  ///
  /// 1. Memory (`_metaByUid` / TreeCache)
  /// 2. If miss and [TreeCache.isFullyCached](`all`) → absent (`null`)
  /// 3. Else query `_system_table_meta` (covers cold start and eviction)
  Future<TableMeta?> getTableMeta(TableUid tableUid) async {
    if (tableUid.isEmpty) return null;

    // Self-row: never fabricate existence. Use [bootstrapTableMetaContext] for
    // QueryExecutor I/O; only return meta after save/load registered it.
    if (tableUid == SystemTable.tableMetaTableUid) {
      final cached = _metaByUid[tableUid] ?? _tableMetaCache?.get(tableUid);
      if (cached != null) return cached;
      if (_tableMetaCache?.isFullyCached('all') == true) {
        return null;
      }
      // Try disk self-row via bootstrap context (no recursive getTableMeta).
      final existing = _metaLoadingFutures[tableUid];
      if (existing != null) return existing;
      final loadFuture = _doLoadTableMeta(tableUid);
      _metaLoadingFutures[tableUid] = loadFuture;
      try {
        return await loadFuture;
      } finally {
        _metaLoadingFutures.remove(tableUid);
      }
    }

    final hot = _metaByUid[tableUid] ?? _tableMetaCache?.get(tableUid);
    if (hot != null) return hot;

    if (_tableMetaCache?.isFullyCached('all') == true) {
      return null;
    }

    final existing = _metaLoadingFutures[tableUid];
    if (existing != null) return existing;

    final loadFuture = _doLoadTableMeta(tableUid);
    _metaLoadingFutures[tableUid] = loadFuture;
    try {
      return await loadFuture;
    } finally {
      _metaLoadingFutures.remove(tableUid);
    }
  }

  Future<TableMeta?> _doLoadTableMeta(TableUid tableUid) async {
    try {
      final rows = await _dataStore.executeQuery(
        bootstrapTableMetaContext(),
        QueryCondition()
          ..where(SystemTable.tableMetaUidField, '=', tableUid.value),
        limit: 1,
      );
      if (rows.isEmpty) return null;

      final meta = TableMetaCodec.decodeRow(rows.first);
      _registerMetaInLookups(meta);
      _cacheTableMeta(meta);
      return meta;
    } catch (e) {
      final logTable = _peekNameByUid(tableUid)?.value ?? tableUid.value;
      Logger.error('Failed to load table meta: $logTable', rawError: e);
      return null;
    }
  }

  /// Load [TableMeta] by logical table name.
  Future<TableMeta?> getTableMetaByName(TableName tableName) async {
    final uid = await resolveTableUidFromName(tableName);
    if (uid == null) return null;
    return getTableMeta(uid);
  }

  /// Convenience: schema from [getTableMeta].
  Future<TableSchema?> getTableSchema(TableUid tableUid) async {
    final meta = await getTableMeta(tableUid);
    return meta?.schema;
  }

  /// Read table schema by logical table name.
  Future<TableSchema?> getTableSchemaByName(TableName tableName) async {
    final meta = await getTableMetaByName(tableName);
    return meta?.schema;
  }

  /// Resolve table uid by name, activating non-global tables in the current space.
  Future<TableUid?> resolveTableUidFromName(TableName tableName) async {
    if (tableName.isEmpty) return null;
    final cached = _peekUidByName(tableName);
    if (cached != null) return cached;

    // Loaded but not yet in name index (e.g. inactive in current space).
    for (final meta in _metaByUid.values) {
      if (meta.tableName == tableName) {
        if (meta.isGlobal) {
          _registerMetaInLookups(meta);
        } else {
          await _ensureActiveInCurrentSpace(meta.tableUid);
          _registerMetaInLookups(meta);
        }
        return meta.tableUid;
      }
    }

    if (_tableMetaCache?.isFullyCached('all') == true) {
      return null;
    }

    try {
      final rows = await _dataStore.executeQuery(
        bootstrapTableMetaContext(),
        QueryCondition()
          ..where(SystemTable.tableMetaNameField, '=', tableName.value),
        limit: 1,
      );
      if (rows.isEmpty) return null;

      final meta = TableMetaCodec.decodeRow(rows.first);
      if (!meta.isGlobal) {
        await _ensureActiveInCurrentSpace(meta.tableUid);
      }
      _registerMetaInLookups(meta);
      _cacheTableMeta(meta);
      return meta.tableUid;
    } catch (e) {
      Logger.error(
        'Failed to resolve table uid from name: ${tableName.value}',
        rawError: e,
      );
      return null;
    }
  }

  Future<void> _ensureActiveInCurrentSpace(
    TableUid tableUid, {
    bool persist = true,
  }) async {
    final currentSpace = _dataStore.currentSpaceName;
    final activeUids = _activeUidsForSpace(currentSpace);
    if (!activeUids.contains(tableUid)) {
      await _updateActiveTableUids(
        currentSpace,
        (uids) => uids.add(tableUid),
        persist: persist,
      );
    }
  }

  /// Patch an existing [TableMeta] row (schema / name / layout / extra).
  ///
  /// Loads current meta, applies only provided fields, then persists via
  /// [saveTableMeta]. Does not create tables; missing uid → [DbException].
  /// Does not change [TableMeta.dirIndex] (create/allocate only via save).
  Future<TableMeta> updateTableMeta(
    TableUid tableUid, {
    TableSchema? schema,
    TableName? tableName,
    FieldStorageLayout? fieldLayout,
    TableMetaExtra? extra,
    bool clearExtra = false,
    bool memoryOnly = false,
    Map<String, String> fieldRenameHints = const <String, String>{},
  }) async {
    if (tableUid.isEmpty) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'updateTableMeta requires a non-empty tableUid',
        ),
      ]);
    }

    final current = await getTableMeta(tableUid);
    if (current == null) {
      final logName = _peekNameByUid(tableUid)?.value ?? tableUid.value;
      throw DbException([
        SchemaValidationStatus(
          type: ResultType.devTableNotFound,
          message: 'Table meta not found for update: $logName',
          tableName: logName,
        ),
      ]);
    }

    final nextName = tableName ?? current.tableName;
    var nextSchema = schema ?? current.schema;
    if (nextSchema.tableUid != tableUid) {
      nextSchema = nextSchema.copyWith(tableUid: tableUid);
    }
    if (nextSchema.name != nextName.value) {
      nextSchema = nextSchema.copyWith(name: nextName.value);
    }

    return saveTableMeta(
      current.copyWith(
        tableName: nextName,
        schema: nextSchema,
        clearExtra: clearExtra,
        extra: clearExtra ? null : extra,
        updatedAt: DateTime.now(),
      ),
      memoryOnly: memoryOnly,
      fieldRenameHints: fieldRenameHints,
      layoutOverride: fieldLayout,
    );
  }

  /// Persist full [TableMeta] (create / upgrade ingest / bootstrap).
  ///
  /// Prefer [updateTableMeta] when patching an existing table.
  /// Returns the final saved meta (tableUid may be reallocated on collision).
  Future<TableMeta> saveTableMeta(
    TableMeta meta, {
    bool memoryOnly = false,
    Map<String, String> fieldRenameHints = const <String, String>{},
    FieldStorageLayout? layoutOverride,
    int? dirIndex,
  }) async {
    try {
      var schema = meta.schema;
      var tableUid = meta.tableUid.isNotEmpty
          ? meta.tableUid
          : (schema.tableUid.isNotEmpty ? schema.tableUid : TableUid.empty);

      // Resolve update vs create; reallocate tableUid on collision with another table.
      final preferredName =
          meta.tableName.isNotEmpty ? meta.tableName : TableName(schema.name);
      tableUid = await _resolveTableUidForSave(
        preferredUid: tableUid,
        tableName: preferredName,
      );
      if (schema.tableUid != tableUid) {
        schema = schema.copyWith(tableUid: tableUid);
      }

      final current = _metaByUid[tableUid] ?? await getTableMeta(tableUid);
      // Avoid recursive bootstrap for the meta table itself during first save.
      final currentSchema = current?.schema;
      schema = schema.generateAutoIndexes(oldSchema: currentSchema);

      if (schema.schemaVersion == null || schema.schemaVersion!.isEmpty) {
        final preserved = currentSchema?.schemaVersion;
        if (preserved != null && preserved.isNotEmpty) {
          schema = schema.copyWith(schemaVersion: preserved);
        } else {
          schema = schema.copyWith(
            schemaVersion: GlobalIdGenerator.generate('s'),
          );
        }
      }

      final existingLayout = layoutOverride ??
          current?.fieldLayout ??
          _tableFieldLayoutCache[tableUid];
      final resolvedLayout = layoutOverride ??
          ((existingLayout != null &&
                  _canReuseExistingFieldStorageLayout(
                    existingLayout,
                    schema,
                    renameHints: fieldRenameHints,
                  ))
              ? existingLayout
              : evolveFieldStorageLayout(
                  existingLayout: existingLayout,
                  nextSchema: schema,
                  renameHints: fieldRenameHints,
                ));

      // Dir index: keep existing, or allocate. Bootstrap table is fixed at 0.
      // allocateDirIndex / caller-supplied dirIndex already bump under-capacity
      // maps — skip a second increment in _registerMetaInLookups for new tables.
      final int resolvedDirIndex;
      final bool dirPreCounted;
      if (tableUid == SystemTable.tableMetaTableUid) {
        resolvedDirIndex = SystemTable.tableMetaDirIndex;
        dirPreCounted = false;
      } else if (current != null) {
        resolvedDirIndex = dirIndex ?? current.dirIndex;
        dirPreCounted = false;
      } else if (dirIndex != null) {
        resolvedDirIndex = dirIndex;
        dirPreCounted = true;
      } else {
        resolvedDirIndex = await allocateDirIndex(schema.isGlobal);
        dirPreCounted = true;
      }

      final now = DateTime.now();
      var saved = TableMeta(
        tableUid: tableUid,
        tableName: preferredName,
        isGlobal: schema.isGlobal,
        schema: schema,
        fieldLayout: resolvedLayout,
        dirIndex: resolvedDirIndex,
        extra: meta.extra,
        createdAt: current?.createdAt ?? meta.createdAt,
        updatedAt: now,
      );

      // Register lookups (handles dir-count delta vs old meta).
      _registerMetaInLookups(saved, skipDirCountIncrement: dirPreCounted);
      _cacheTableMeta(saved);

      if (!memoryOnly) {
        final beforeUid = saved.tableUid;
        saved = await _persistTableMetaRowWithUidRetry(saved);
        // Persist retry may have reallocated uid and unregistered the provisional.
        if (saved.tableUid != beforeUid) {
          _registerMetaInLookups(saved, skipDirCountIncrement: true);
          _cacheTableMeta(saved);
        }
      }

      if (!saved.isGlobal) {
        await _ensureActiveInCurrentSpace(
          saved.tableUid,
          persist: !memoryOnly,
        );
        // Re-apply name maps after space activation.
        _uidByName[saved.tableName] = saved.tableUid;
        _nameByUid[saved.tableUid] = saved.tableName;
      }

      _dataStore.upsertTtlPlanForSchema(saved.schema);
      return saved;
    } catch (e) {
      Logger.error(
        'Failed to save table meta: ${meta.tableUid} (${meta.tableName})',
        rawError: e,
      );
      throw DbException.wrap(e, fallbackMessage: 'Failed to save table meta');
    }
  }

  /// Resolve [preferredUid] for create/update; reallocates on collision with another table.
  Future<TableUid> _resolveTableUidForSave({
    required TableUid preferredUid,
    required TableName tableName,
  }) async {
    if (preferredUid == SystemTable.tableMetaTableUid ||
        tableName.value == SystemTable.tableMetaName) {
      return SystemTable.tableMetaTableUid;
    }

    if (preferredUid.isNotEmpty) {
      final localMeta = _metaByUid[preferredUid];
      if (localMeta != null) {
        return localMeta.tableName == tableName
            ? preferredUid
            : await _allocateUniqueTableUid();
      }
      if (_tableMetaCache?.isFullyCached('all') != true) {
        final disk = await _doLoadTableMeta(preferredUid);
        if (disk != null) {
          return disk.tableName == tableName
              ? preferredUid
              : await _allocateUniqueTableUid();
        }
      }
      return preferredUid;
    }

    return _allocateUniqueTableUid();
  }

  /// Allocate a free [TableUid], preferring [preferred] when unused.
  Future<TableUid> _allocateUniqueTableUid({TableUid? preferred}) async {
    const maxAttempts = 8;
    var candidate = (preferred != null &&
            preferred.isNotEmpty &&
            preferred != SystemTable.tableMetaTableUid)
        ? preferred
        : TableUid(GlobalIdGenerator.generate('t'));

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (candidate == SystemTable.tableMetaTableUid || candidate.isEmpty) {
        candidate = TableUid(GlobalIdGenerator.generate('t'));
        continue;
      }

      if (_metaByUid.containsKey(candidate)) {
        candidate = TableUid(GlobalIdGenerator.generate('t'));
        continue;
      }

      if (_tableMetaCache?.isFullyCached('all') == true) {
        return candidate;
      }

      final disk = await _doLoadTableMeta(candidate);
      if (disk == null) return candidate;

      candidate = TableUid(GlobalIdGenerator.generate('t'));
    }

    throw DbException([
      GeneralStatus(
        type: ResultType.engError,
        message:
            'Failed to allocate a unique tableUid after $maxAttempts attempts',
      ),
    ]);
  }

  bool _isPrimaryOrUniqueConflict(DbResult result) {
    for (final s in result.statuses) {
      if (s.type == ResultType.bizPrimaryKeyViolation ||
          s.type == ResultType.bizUniqueViolation) {
        return true;
      }
    }
    return false;
  }

  /// Upsert system-table row; on PK/unique conflict reallocate tableUid and retry.
  Future<TableMeta> _persistTableMetaRowWithUidRetry(TableMeta saved) async {
    const maxAttempts = 8;
    var current = saved;
    final originalUid = saved.tableUid;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final row = TableMetaCodec.encodeRow(current);
      final result = await TransactionContext.runAsSystemOperation(() async {
        return await _dataStore.upsert(SystemTable.tableMetaName, row);
      });

      if (!result.hasErrors) return current;

      if (!_isPrimaryOrUniqueConflict(result)) {
        throw DbException(result.statuses);
      }

      // Do not reallocate the bootstrap system table uid.
      if (current.tableUid == SystemTable.tableMetaTableUid) {
        throw DbException(result.statuses);
      }

      final newUid = await _allocateUniqueTableUid();
      Logger.warn(
        'tableUid collision on persist for ${current.tableName}; '
        'reallocating ${current.tableUid} → $newUid',
      );

      // Drop the colliding registration if we had provisionally registered it.
      if (attempt == 0 && originalUid != newUid) {
        final provisional = _metaByUid[originalUid];
        if (provisional != null && provisional.tableName == current.tableName) {
          _unregisterMetaFromLookups(provisional);
        }
      }

      current = current.copyWith(
        tableUid: newUid,
        schema: current.schema.copyWith(tableUid: newUid),
        updatedAt: DateTime.now(),
      );
    }

    throw DbException([
      GeneralStatus(
        type: ResultType.engError,
        message:
            'Failed to persist table meta after $maxAttempts tableUid collision retries',
      ),
    ]);
  }

  /// Delete table meta from caches and system table.
  Future<bool> deleteTableMeta(TableUid tableUid) async {
    try {
      final meta = _metaByUid[tableUid] ?? await getTableMeta(tableUid);
      if (meta == null) return false;

      final tableName = meta.tableName;
      final ctx = TableContext(
        tableUid: meta.tableUid,
        tableName: meta.tableName,
        isGlobal: meta.isGlobal,
        dirIndex: meta.dirIndex,
        schema: meta.schema,
      );

      _unregisterMetaFromLookups(meta);
      removeCachedTableSchema(tableUid);

      if (!meta.isGlobal) {
        final currentSpace = _dataStore.currentSpaceName;
        if (_activeUidsForSpace(currentSpace).contains(tableUid)) {
          await _updateActiveTableUids(currentSpace, (uids) {
            uids.remove(tableUid);
          });
        }
      }

      final result = await TransactionContext.runAsSystemOperation(() async {
        return await _dataStore.deleteInternal(
          bootstrapTableMetaContext(),
          QueryCondition()
            ..where(SystemTable.tableMetaUidField, '=', tableUid.value),
        );
      });
      if (result.hasErrors) {
        Logger.error(
          'Failed to delete table meta row: ${tableName.value}',
          rawError: result.message,
        );
        return false;
      }

      _dataStore.removeTtlPlanForTable(ctx);
      return true;
    } catch (e) {
      final logTable = _peekNameByUid(tableUid)?.value ?? tableUid.value;
      Logger.error('Failed to delete table meta: $logTable', rawError: e);
      return false;
    }
  }

  /// List table names.
  ///
  /// Default: **entire database** (all `_system_table_meta` rows).
  ///
  /// [onlyCurrentSpace] is a narrow view for cache prewarm / space UI:
  /// **always includes every global table** (`_globalTableUids` / `isGlobal`)
  /// plus non-global UIDs in [SpaceManifest.activeTableUids].
  ///
  /// Awaits the one-shot name inventory when cold (joins
  /// [loadAllTableMetaAsync]) — never starts a second full-table scan.
  Future<List<String>> listAllTables({
    bool onlyUserTables = false,
    bool onlyCurrentSpace = false,
  }) async {
    await _ensureNameInventoryReady();

    final List<String> names;
    if (onlyCurrentSpace) {
      names = await _filterNamesToCurrentSpace(
        _uidByName.keys.map((n) => n.value),
      );
    } else {
      names = _uidByName.keys.map((n) => n.value).toList(growable: false);
    }

    if (onlyUserTables) {
      return names
          .where((tableName) => !SystemTable.isSystemTable(tableName))
          .toList();
    }

    return names;
  }

  /// Current-space view: globals ∪ active non-globals (see [_globalTableUids]).
  Future<List<String>> _filterNamesToCurrentSpace(
    Iterable<String> names,
  ) async {
    await loadSpaceManifest(_dataStore.currentSpaceName);
    final active = _activeUidsForSpace(_dataStore.currentSpaceName).toSet();
    final out = <String>[];
    for (final name in names) {
      final uid = _uidByName[TableName(name)];
      if (uid == null) continue;
      if (_globalTableUids.contains(uid) || active.contains(uid)) {
        out.add(name);
      }
    }
    return out;
  }

  /// Whether the table is global (null if unknown).
  Future<bool?> isTableGlobal(TableUid tableUid) async {
    final meta = await getTableMeta(tableUid);
    return meta?.isGlobal;
  }

  bool _hasSchemaChanged(List<TableSchema> schemas, String? oldHash) {
    if (oldHash == null || oldHash.isEmpty) {
      return true;
    }
    final newHash = TableSchema.generateSchemasHash(schemas);
    return oldHash != newHash;
  }

  /// High-performance check if user-defined table schema has changed.
  Future<bool> isSchemaChanged(List<TableSchema> schemas) async {
    try {
      final config = await _dataStore.getGlobalConfig();
      return _hasSchemaChanged(schemas, config?.userSchemaHash);
    } catch (e) {
      Logger.error('Failed to judge table schema change', rawError: e);
      return true;
    }
  }

  /// Check if system table schema has changed.
  Future<bool> isSystemSchemaChanged(List<TableSchema> schemas) async {
    try {
      final config = await _dataStore.getGlobalConfig();
      return _hasSchemaChanged(schemas, config?.systemSchemaHash);
    } catch (e) {
      Logger.error('Failed to judge system schema change', rawError: e);
      return true;
    }
  }

  /// Update user-defined table schema hash in [GlobalConfig].
  Future<void> updateUserSchemaHash(List<TableSchema> schemas) async {
    if (schemas.isEmpty) return;
    try {
      final hash = TableSchema.generateSchemasHash(schemas);
      final existing = await _dataStore.getGlobalConfig() ?? GlobalConfig();
      await _dataStore.saveGlobalConfig(
        existing.copyWith(userSchemaHash: hash),
      );
    } catch (e) {
      Logger.error('Failed to update user schema hash', rawError: e);
    }
  }

  /// Update system table schema hash in [GlobalConfig].
  Future<void> updateSystemSchemaHash(List<TableSchema> schemas) async {
    if (schemas.isEmpty) return;
    try {
      final hash = TableSchema.generateSchemasHash(schemas);
      final existing = await _dataStore.getGlobalConfig() ?? GlobalConfig();
      await _dataStore.saveGlobalConfig(
        existing.copyWith(systemSchemaHash: hash),
      );
    } catch (e) {
      Logger.error('Failed to update system schema hash', rawError: e);
    }
  }

  /// Load all rows from `_system_table_meta` into memory (with yield).
  ///
  Future<void> loadAllTableMetaAsync() {
    final existing = _loadAllMetaFuture;
    if (existing != null) return existing;

    final future = _doLoadAllTableMetaAsync();
    _loadAllMetaFuture = future;
    return future.whenComplete(() {
      if (identical(_loadAllMetaFuture, future)) {
        _loadAllMetaFuture = null;
      }
    });
  }

  Future<void> _doLoadAllTableMetaAsync() async {
    final yieldController =
        YieldController('TableMetaManager.loadAllTableMetaAsync');
    try {
      // Ensure bootstrap meta is present without querying self.
      final bootstrap = _buildBootstrapTableMeta();
      if (!_metaByUid.containsKey(bootstrap.tableUid)) {
        _registerMetaInLookups(bootstrap);
        _cacheTableMeta(bootstrap);
      }

      final rows = await _dataStore.executeQuery(
        bootstrapTableMetaContext(),
        QueryCondition()..where(SystemTable.tableMetaUidField, '>=', ''),
      );

      for (final row in rows) {
        await yieldController.maybeYield();
        final meta = TableMetaCodec.decodeRow(row);
        if (meta.tableUid == SystemTable.tableMetaTableUid) {
          // Prefer disk row when present (preserves createdAt / layout).
          _registerMetaInLookups(meta);
          _cacheTableMeta(meta);
          continue;
        }
        _registerMetaInLookups(meta);
        _cacheTableMeta(meta);
      }

      _rebuildDirCountsFromMeta();
      await _reconcileDirHighWaterFromMeta();
      await loadSpaceManifest(_dataStore.currentSpaceName);
      _rebuildNameLookups();
      _nameInventoryReady = true;
      _ensureTableMetaCache().setFullyCached('all', true);
    } catch (e) {
      _nameInventoryReady = false;
      Logger.error('Failed to load all table meta', rawError: e);
      throw DbException.wrap(
        e,
        fallbackMessage: 'Failed to load all table meta',
      );
    }
  }

  /// Align GlobalConfig dir high-water with authoritative in-memory metas.
  Future<void> _reconcileDirHighWaterFromMeta() async {
    var maxGlobal = -1;
    var maxNonGlobal = -1;
    var globalAtMax = 0;
    var nonGlobalAtMax = 0;

    for (final meta in _metaByUid.values) {
      if (meta.isGlobal) {
        if (meta.dirIndex > maxGlobal) {
          maxGlobal = meta.dirIndex;
          globalAtMax = 1;
        } else if (meta.dirIndex == maxGlobal) {
          globalAtMax++;
        }
      } else {
        if (meta.dirIndex > maxNonGlobal) {
          maxNonGlobal = meta.dirIndex;
          nonGlobalAtMax = 1;
        } else if (meta.dirIndex == maxNonGlobal) {
          nonGlobalAtMax++;
        }
      }
    }

    final config = await _dataStore.getGlobalConfig() ?? GlobalConfig();
    final nextGlobalIndex = maxGlobal < 0 ? 0 : maxGlobal;
    final nextGlobalEntries = maxGlobal < 0 ? 0 : globalAtMax;
    final nextNonGlobalIndex = maxNonGlobal < 0 ? 0 : maxNonGlobal;
    final nextNonGlobalEntries = maxNonGlobal < 0 ? 0 : nonGlobalAtMax;

    if (config.lastGlobalDirIndex == nextGlobalIndex &&
        config.lastGlobalDirEntries == nextGlobalEntries &&
        config.lastNonGlobalDirIndex == nextNonGlobalIndex &&
        config.lastNonGlobalDirEntries == nextNonGlobalEntries) {
      return;
    }

    await _dataStore.saveGlobalConfig(
      config.copyWith(
        lastGlobalDirIndex: nextGlobalIndex,
        lastGlobalDirEntries: nextGlobalEntries,
        lastNonGlobalDirIndex: nextNonGlobalIndex,
        lastNonGlobalDirEntries: nextNonGlobalEntries,
      ),
    );
  }
}

/// Lightweight per-table index cache entry.
class _IndexListCacheEntry {
  final List<IndexSchema> allIndexes;
  final List<IndexSchema> uniqueIndexes;
  final List<IndexSchema> vectorIndexes;
  final List<IndexSchema> btreeIndexes;
  final Map<String, IndexSchema> byUid;
  final Map<String, IndexSchema> byAlias;

  const _IndexListCacheEntry({
    required this.allIndexes,
    required this.uniqueIndexes,
    required this.vectorIndexes,
    required this.btreeIndexes,
    required this.byUid,
    required this.byAlias,
  });
}

/// Build index cache entry from a [TableSchema].
_IndexListCacheEntry _buildIndexListCache(TableSchema schema) {
  final all = schema.getAllIndexes();
  if (all.isEmpty) {
    const emptyList = <IndexSchema>[];
    return const _IndexListCacheEntry(
      allIndexes: emptyList,
      uniqueIndexes: emptyList,
      vectorIndexes: emptyList,
      btreeIndexes: emptyList,
      byUid: {},
      byAlias: {},
    );
  }

  final unique = <IndexSchema>[];
  final vector = <IndexSchema>[];
  final btree = <IndexSchema>[];
  final byUid = <String, IndexSchema>{};
  final byAlias = <String, IndexSchema>{};

  for (final idx in all) {
    if (idx.unique) {
      unique.add(idx);
    }
    if (idx.type == IndexType.vector) {
      vector.add(idx);
    } else {
      btree.add(idx);
    }
    if (idx.indexUid.isNotEmpty) {
      byUid[idx.indexUid] = idx;
    }
    byAlias[idx.actualIndexName] = idx;
    final logicalName = idx.indexName;
    if (logicalName != null && logicalName.isNotEmpty) {
      byAlias[logicalName] = idx;
    }
  }

  return _IndexListCacheEntry(
    allIndexes: List<IndexSchema>.unmodifiable(all),
    uniqueIndexes: List<IndexSchema>.unmodifiable(unique),
    vectorIndexes: List<IndexSchema>.unmodifiable(vector),
    btreeIndexes: List<IndexSchema>.unmodifiable(btree),
    byUid: Map<String, IndexSchema>.unmodifiable(byUid),
    byAlias: Map<String, IndexSchema>.unmodifiable(byAlias),
  );
}
