import 'dart:async';

import '../handler/binary_schema_codec.dart';
import '../handler/logger.dart';
import '../handler/table_meta_codec.dart';
import '../model/data_store_config.dart';
import '../model/db_exception.dart';
import '../model/db_result.dart';
import '../model/global_config.dart';
import '../model/id_generator.dart';
import '../model/meta_info.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
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

/// Table meta manager - stores metadata in `_system_table_meta`.
class TableMetaManager {
  final DataStoreImpl _dataStore;

  /// Hot [TableMeta] cache (LRU + quota). Managed by ResourceManager:
  /// [MemoryQuotaType.schema]. Full meta lives only here.
  ///
  /// [TreeCache.isFullyCached](`all`) means every inventoried meta is still
  /// hot. After eviction it is cleared; miss then re-queries the system table
  /// even when [_nameInventoryReady] is true.
  TreeCache<TableMeta>? _tableMetaCache;

  /// Hot schema cache (TableSchema) using [TreeCache].
  /// Managed by ResourceManager quota: [MemoryQuotaType.schema].
  TreeCache<TableSchema>? _tableSchemaCache;

  /// Per-table index cache derived from [TableSchema].
  final Map<TableUid, _IndexListCacheEntry> _indexListCache =
      <TableUid, _IndexListCacheEntry>{};

  /// Per-table stable storage layout cache (keyed by tableUid).
  final Map<TableUid, FieldStorageLayout> _tableFieldLayoutCache =
      <TableUid, FieldStorageLayout>{};

  /// Committed meta for `_system_table_meta` itself - survives TreeCache eviction.
  ///
  /// Never holds a bootstrap-only stub: only memoryOnly/disk [saveTableMeta] or
  /// a decoded self-row. Path IO uses [bootstrapTableMetaContext] / fixed uid.
  TableMeta? _pinnedMetaTableMeta;

  /// Per-table cached storage field structure derived from layout + schema.
  final Map<TableUid, List<FieldStructure>> _storageFieldStructCache =
      <TableUid, List<FieldStructure>>{};

  /// Loading futures to prevent thundering herd on concurrent meta reads.
  final Map<TableUid, Future<TableMeta?>> _metaLoadingFutures = {};

  static const String _deletedSlotFieldPrefix = '_system_storage_deleted_slot_';

  /// Name->UID inventory for **all** tables in the database.
  ///
  /// After [loadAllTableMetaAsync] completes this is the complete lightweight
  /// listing source and is **not** cleared by TreeCache eviction of full
  /// [TableMeta]. Before it is ready, lookups must point-query the system
  /// table (never block startup on full load). Non-global table *data* is
  /// still isolated per space via paths; schema inventory is database-wide.
  final Map<TableName, TableUid> _uidByName = {};

  /// UID->name reverse inventory (same scope / lifetime as [_uidByName]).
  final Map<TableUid, TableName> _nameByUid = {};

  /// Global table UIDs in the name inventory.
  /// Survives TreeCache eviction so [listAllTables] can filter by [isGlobal]
  /// without reloading full [TableMeta].
  final Set<TableUid> _globalTableUids = {};

  /// Dir index per tableUid (lightweight; survives TreeCache eviction).
  final Map<TableUid, int> _dirIndexByUid = {};

  /// True once startup [loadAllTableMetaAsync] (or memory-mode registration)
  /// finished building the **lightweight** name->UID inventory.
  ///
  /// This is **not** "all [TableMeta] are in TreeCache". After quota eviction the
  /// inventory stays complete while the cache may be partial - full-meta reads
  /// must still hit `_system_table_meta` on cache miss (see [getTableMeta]).
  bool _nameInventoryReady = false;

  /// Single-flight handle for [loadAllTableMetaAsync] (startup / explicit).
  Future<void>? _loadAllMetaFuture;

  /// Bumped on [invalidateCache] / [dispose] so in-flight meta loads do not
  /// repopulate a cleared inventory.
  int _cacheEpoch = 0;

  /// Under-capacity data-dir usage only (count < maxEntriesPerDir).
  final Map<int, int> _globalDirCounts = {};
  final Map<int, int> _nonGlobalDirCounts = {};

  /// Serializes [allocateDirIndex] against concurrent creates.
  Future<void> _dirAllocChain = Future.value();

  TableMetaManager(this._dataStore);

  /// Whether the lightweight name->UID inventory is complete for listing.
  bool get isNameInventoryReady => _nameInventoryReady;

  /// Mark name inventory complete (e.g. memory-mode startup after all schemas
  /// are registered via [registerTableSchemaInMemory]).
  void markNameInventoryReady() {
    _nameInventoryReady = true;
    _syncTableMetaFullyCachedFlag();
  }

  /// Set TreeCache `all` flag only when every inventoried uid is still hot.
  ///
  /// [_nameInventoryReady] may be true while this stays false (eviction left a
  /// partial cache) - miss paths must then query the system table.
  void _syncTableMetaFullyCachedFlag() {
    final cache = _ensureTableMetaCache();
    if (!_nameInventoryReady || _nameByUid.isEmpty) {
      cache.setFullyCached('all', false);
      return;
    }
    if (cache.length < _nameByUid.length) {
      cache.setFullyCached('all', false);
      return;
    }
    cache.setFullyCached('all', true);
  }

  /// Resolve tableUid from tableName (inventory - system table when cold).
  Future<TableUid?> getUidByName(TableName tableName) =>
      resolveTableUidFromName(tableName);

  /// Resolve tableName from tableUid (inventory first; cold - [getTableMeta]).
  Future<TableName?> getNameByUid(TableUid tableUid) async {
    if (tableUid.isEmpty) return null;
    final inv = _nameByUid[tableUid];
    if (inv != null) return inv;
    if (_nameInventoryReady) return null;
    final meta = await getTableMeta(tableUid);
    return meta?.tableName;
  }

  /// Memory-only name->UID peek. Do not use for existence / correctness.
  TableUid? _peekUidByName(TableName tableName) {
    if (tableName.isEmpty) return null;
    return _uidByName[tableName];
  }

  /// Synchronous memory-only table name to TableUid resolution.
  TableUid? getUidByNameSync(TableName tableName) {
    if (tableName.isEmpty) return null;
    if (tableName.value == SystemTable.tableMetaName) {
      return SystemTable.tableMetaTableUid;
    }
    return _uidByName[tableName];
  }

  /// Cached TableContext instances for zero-allocation synchronous lookups.
  final Map<TableUid, TableContext> _tableContextCache =
      <TableUid, TableContext>{};

  /// Synchronous zero-allocation TableContext retrieval by table name string.
  TableContext? getTableContextByNameSync(String tableName) {
    if (tableName.isEmpty) return null;
    final name = TableName(tableName);
    final tableUid = getUidByNameSync(name);
    if (tableUid == null) return null;
    return getTableContextSync(tableUid);
  }

  /// Synchronous memory-only TableContext retrieval.
  TableContext? getTableContextSync(TableUid tableUid) {
    if (tableUid.isEmpty) return null;
    final cached = _tableContextCache[tableUid];
    if (cached != null) return cached;
    final meta = _peekTableMeta(tableUid);
    if (meta != null) {
      final ctx = TableContext(
        tableUid: meta.tableUid,
        tableName: meta.tableName,
        isGlobal: meta.isGlobal,
        dirIndex: meta.dirIndex,
        schema: meta.schema,
      );
      _tableContextCache[tableUid] = ctx;
      return ctx;
    }
    // Fixed layout for `_system_table_meta` disk IO. Must not call [getTableMeta]
    // here: cold meta load queries this table and re-enters via [getTableDataMeta].
    if (tableUid == SystemTable.tableMetaTableUid) {
      return bootstrapTableMetaContext();
    }
    return null;
  }

  /// Memory-only UID->name peek (logs / best-effort display only).
  TableName? _peekNameByUid(TableUid tableUid) {
    if (tableUid.isEmpty) return null;
    return _nameByUid[tableUid] ?? _tableMetaCache?.peek(tableUid)?.tableName;
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
    if (tableUid == SystemTable.tableMetaTableUid) {
      return _pinnedMetaTableMeta ?? _tableMetaCache?.peek(tableUid);
    }
    return _tableMetaCache?.peek(tableUid);
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
    return _tableMetaCache?.peek(tableUid)?.schema ??
        _tableSchemaCache?.peek(tableUid);
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
    _ensureTableMetaCache().put(meta.tableUid, meta);
    _tableFieldLayoutCache[meta.tableUid] = meta.fieldLayout;
    _storageFieldStructCache.remove(meta.tableUid);
    _cacheTableSchema(meta.tableUid, meta.schema);
    final ctx = TableContext(
      tableUid: meta.tableUid,
      tableName: meta.tableName,
      isGlobal: meta.isGlobal,
      dirIndex: meta.dirIndex,
      schema: meta.schema,
    );
    _tableContextCache[meta.tableUid] = ctx;
    if (meta.tableUid == SystemTable.tableMetaTableUid ||
        meta.tableName.value == SystemTable.tableMetaName) {
      _pinnedMetaTableMeta = meta;
    }
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
    final pinned = _pinnedMetaTableMeta;
    if (pinned != null) {
      return TableContext(
        tableUid: pinned.tableUid,
        tableName: pinned.tableName,
        isGlobal: pinned.isGlobal,
        dirIndex: pinned.dirIndex,
        schema: pinned.schema,
      );
    }
    return TableContext(
      tableUid: SystemTable.tableMetaTableUid,
      tableName: TableName(SystemTable.tableMetaName),
      isGlobal: true,
      dirIndex: SystemTable.tableMetaDirIndex,
      schema: SystemTable.tableMetaTable(),
    );
  }

  /// Ensure physical layout for meta-table IO without registering the table as
  /// existing (stub - exists).
  void _ensureMetaTableIoLayout() {
    final uid = SystemTable.tableMetaTableUid;
    if (_tableFieldLayoutCache.containsKey(uid)) return;
    final pinned = _pinnedMetaTableMeta;
    if (pinned != null) {
      _tableFieldLayoutCache[uid] = pinned.fieldLayout;
      return;
    }
    _tableFieldLayoutCache[uid] =
        _createInitialFieldStorageLayout(SystemTable.tableMetaTable());
  }

  /// Get [TableContext] by tableUid (asynchronous).
  ///
  /// Uses [getTableMeta]: memory - fully-cached miss = absent - else system table.
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
    _tableContextCache.remove(tableUid);
    _indexListCache.remove(tableUid);
    _tableFieldLayoutCache.remove(tableUid);
    _storageFieldStructCache.remove(tableUid);
    if (tableUid == SystemTable.tableMetaTableUid) {
      _pinnedMetaTableMeta = null;
    }
    _dataStore.queryExecutor.invalidatePlanCacheForTable(tableUid);
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
    _tableContextCache.clear();
  }

  /// Wait for the startup name inventory (joins the existing single-flight
  /// [loadAllTableMetaAsync]; does not start a parallel full-table scan).
  Future<void> _ensureNameInventoryReady() async {
    if (_nameInventoryReady) return;
    await loadAllTableMetaAsync();
  }

  void _rebuildDirCountsFromMeta() {
    _globalDirCounts.clear();
    _nonGlobalDirCounts.clear();
    final max = _dataStore.maxEntriesPerDir;
    final globalRaw = <int, int>{};
    final nonGlobalRaw = <int, int>{};

    for (final e in _dirIndexByUid.entries) {
      final map = _globalTableUids.contains(e.key) ? globalRaw : nonGlobalRaw;
      map[e.value] = (map[e.value] ?? 0) + 1;
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
    bool updateDirCounts = true,
  }) {
    final uid = meta.tableUid;
    final oldName = _nameByUid[uid];
    final oldDir = _dirIndexByUid[uid];
    final existed = oldName != null || oldDir != null;
    final wasGlobal = _globalTableUids.contains(uid);

    if (updateDirCounts) {
      if (existed && oldDir != null) {
        _decrementDirCount(wasGlobal, oldDir);
      }
      // Pre-counted only applies to brand-new registrations (allocateDirIndex
      // already bumped usage). Updates always re-count after unregister.
      if (!skipDirCountIncrement || existed) {
        _incrementDirCount(meta.isGlobal, meta.dirIndex);
      }
    }

    if (oldName != null && oldName != meta.tableName) {
      _uidByName.remove(oldName);
    }

    _dirIndexByUid[uid] = meta.dirIndex;
    // Full-DB name inventory (non-global data remains space-isolated by path).
    _uidByName[meta.tableName] = uid;
    _nameByUid[uid] = meta.tableName;
    if (meta.isGlobal) {
      _globalTableUids.add(uid);
    } else {
      _globalTableUids.remove(uid);
    }
  }

  void _unregisterMetaFromLookups(TableMeta meta) {
    final uid = meta.tableUid;
    final dir = _dirIndexByUid.remove(uid) ?? meta.dirIndex;
    _decrementDirCount(meta.isGlobal, dir);
    _uidByName.remove(meta.tableName);
    _nameByUid.remove(uid);
    _globalTableUids.remove(uid);
    _tableContextCache.remove(uid);
  }

  /// Clear all in-memory caches and reset state.
  Future<void> dispose() async {
    _cacheEpoch++;
    if (_metaLoadingFutures.isNotEmpty) {
      try {
        await Future.wait(_metaLoadingFutures.values);
      } catch (_) {}
    }
    _tableSchemaCache?.clear();
    _tableMetaCache?.clear();
    _tableContextCache.clear();
    _indexListCache.clear();
    _tableFieldLayoutCache.clear();
    _storageFieldStructCache.clear();
    _pinnedMetaTableMeta = null;
    _metaLoadingFutures.clear();
    _uidByName.clear();
    _nameByUid.clear();
    _globalTableUids.clear();
    _dirIndexByUid.clear();
    _nameInventoryReady = false;
    _loadAllMetaFuture = null;
    _globalDirCounts.clear();
    _nonGlobalDirCounts.clear();
  }

  /// Invalidate meta caches (name inventory + TreeCache).
  ///
  /// Space switch uses [dispose] / re-init; do not rely on this alone for
  /// cross-space isolation (non-global *data* paths follow currentSpaceName).
  void invalidateCache() {
    _cacheEpoch++;
    _tableMetaCache?.clear();
    _tableSchemaCache?.clear();
    _tableContextCache.clear();
    _uidByName.clear();
    _nameByUid.clear();
    _globalTableUids.clear();
    _dirIndexByUid.clear();
    _nameInventoryReady = false;
    _loadAllMetaFuture = null;
    _tableMetaCache?.setFullyCached('all', false);
    _globalDirCounts.clear();
    _nonGlobalDirCounts.clear();
    _indexListCache.clear();
    _tableFieldLayoutCache.clear();
    _storageFieldStructCache.clear();
    _pinnedMetaTableMeta = null;
    _metaLoadingFutures.clear();
  }

  /// Drop partial name inventory after a failed full load (keep space manifest).
  void _clearNameInventoryAfterFailedLoad() {
    _cacheEpoch++;
    _tableMetaCache?.clear();
    _tableSchemaCache?.clear();
    _tableContextCache.clear();
    _uidByName.clear();
    _nameByUid.clear();
    _globalTableUids.clear();
    _dirIndexByUid.clear();
    _nameInventoryReady = false;
    _tableMetaCache?.setFullyCached('all', false);
    _globalDirCounts.clear();
    _nonGlobalDirCounts.clear();
    _indexListCache.clear();
    _tableFieldLayoutCache.clear();
    _storageFieldStructCache.clear();
    _pinnedMetaTableMeta = null;
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

  /// Evolve an **existing persisted** layout toward [nextSchema].
  ///
  /// - Matched fields keep their slot ids (rename/type update in place).
  /// - Unmatched previous slots remain as [FieldStorageSlot.deleted] markers.
  /// - Brand-new fields are appended with new slot ids.
  /// - When [existingLayout] is null (create table), builds an initial layout.
  ///
  /// Never call [_createInitialFieldStorageLayout] for an existing table that
  /// already has a stored layout - that drops deletion markers and slot ids.
  FieldStorageLayout evolveFieldStorageLayout({
    FieldStorageLayout? existingLayout,
    required TableSchema nextSchema,
    Map<String, String> renameHints = const <String, String>{},
  }) {
    if (existingLayout == null) {
      return _createInitialFieldStorageLayout(nextSchema);
    }

    final slots = <FieldStorageSlot>[
      for (final s in existingLayout.slots) s.copyWith(deleted: true),
    ];
    int nextSlotId = existingLayout.nextSlotId;

    // O(1) slot lookup maps (built once; deleted slots remain matchable).
    final byFieldId = <String, int>{};
    final byName = <String, int>{};
    for (var i = 0; i < slots.length; i++) {
      final slot = slots[i];
      final fid = slot.fieldId;
      if (fid != null && fid.isNotEmpty) {
        byFieldId.putIfAbsent(fid, () => i);
      }
      if (slot.fieldName.isNotEmpty) {
        byName.putIfAbsent(slot.fieldName, () => i);
      }
    }

    // renameHints: oldName -> newName; invert to newName -> oldName for match.
    final newToOld = _invertRenameHints(renameHints);

    for (final field in nextSchema.fields) {
      int? matchIdx;

      final fieldId = field.fieldId;
      if (fieldId != null && fieldId.isNotEmpty) {
        matchIdx = byFieldId[fieldId];
      }

      if (matchIdx == null && newToOld.isNotEmpty) {
        final oldName = _resolveOriginalFieldName(field.name, newToOld);
        if (oldName != null && oldName.isNotEmpty) {
          matchIdx = byName[oldName];
        }
      }

      matchIdx ??= byName[field.name];

      if (matchIdx != null) {
        final prev = slots[matchIdx];
        final nextFid = field.fieldId ?? prev.fieldId;
        slots[matchIdx] = prev.copyWith(
          fieldName: field.name,
          fieldId: nextFid,
          typeIndex: field.type.index,
          deleted: false,
        );
        // Keep maps coherent for subsequent fields in this evolve pass.
        if (prev.fieldName != field.name) {
          if (byName[prev.fieldName] == matchIdx) {
            byName.remove(prev.fieldName);
          }
          byName[field.name] = matchIdx;
        }
        if (nextFid != null && nextFid.isNotEmpty) {
          byFieldId[nextFid] = matchIdx;
        }
      } else {
        final newIdx = slots.length;
        final newFid = field.fieldId ?? field.name;
        slots.add(FieldStorageSlot(
          slotId: nextSlotId++,
          fieldName: field.name,
          typeIndex: field.type.index,
          deleted: false,
          fieldId: newFid,
        ));
        byName[field.name] = newIdx;
        if (newFid.isNotEmpty) {
          byFieldId[newFid] = newIdx;
        }
      }
    }

    return FieldStorageLayout(nextSlotId: nextSlotId, slots: slots);
  }

  /// Invert old->new rename hints to new->old (last write wins on duplicate new).
  static Map<String, String> _invertRenameHints(
    Map<String, String> renameHints,
  ) {
    if (renameHints.isEmpty) return const <String, String>{};
    final out = <String, String>{};
    for (final e in renameHints.entries) {
      if (e.key.isEmpty || e.value.isEmpty) continue;
      out[e.value] = e.key;
    }
    return out;
  }

  /// Walk new->old chain to the oldest name; stops on cycles.
  static String? _resolveOriginalFieldName(
    String fieldName,
    Map<String, String> newToOld,
  ) {
    if (newToOld.isEmpty) return null;
    var current = fieldName;
    String? oldest;
    final visited = <String>{};
    while (true) {
      final prev = newToOld[current];
      if (prev == null || prev.isEmpty) break;
      if (!visited.add(current)) break; // cycle
      current = prev;
      oldest = current;
    }
    return oldest;
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
      final fid = field.fieldId;
      if (fid != null &&
          fid.isNotEmpty &&
          matched.fieldId != null &&
          matched.fieldId!.isNotEmpty &&
          matched.fieldId != fid) {
        return false;
      }
    }

    return true;
  }

  /// Build codec field structure from a storage layout.
  ///
  /// Deleted slots use a synthetic name for in-memory decode maps only; on-disk
  /// records are nameless positional values. The real deletion marker is
  /// [FieldStorageSlot.deleted] in layout metadata.
  List<FieldStructure> buildStorageFieldStructureFromLayout(
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

  /// Get the **persisted** stable field storage layout for a table.
  ///
  /// Always loads from cache / table meta. Never rebuilds from [TableSchema]
  /// field lists - that would drop deleted-slot markers and break positional
  /// decode. Schema evolution must go through [evolveFieldStorageLayout] on the
  /// existing layout (or [layoutOverride] on save).
  Future<FieldStorageLayout> getTableFieldLayout(TableUid tableUid) async {
    final cached = _tableFieldLayoutCache[tableUid];
    if (cached != null) {
      return cached;
    }

    final meta = await getTableMeta(tableUid);
    if (meta != null) {
      _tableFieldLayoutCache[tableUid] = meta.fieldLayout;
      return meta.fieldLayout;
    }

    return const FieldStorageLayout(nextSlotId: 0, slots: <FieldStorageSlot>[]);
  }

  /// Synchronous peek at cached storage field structure (never loads from disk).
  List<FieldStructure>? peekStorageFieldStructure(TableUid tableUid) {
    return _storageFieldStructCache[tableUid];
  }

  /// Get stable storage field structure used by the record binary codec.
  ///
  /// Structure is derived from the **persisted** field layout (or
  /// [layoutOverride]), not by projecting the logical schema field list.
  Future<List<FieldStructure>> getStorageFieldStructure(
    TableUid tableUid, {
    TableSchema? schema,
    FieldStorageLayout? layoutOverride,
  }) async {
    if (layoutOverride != null) {
      return buildStorageFieldStructureFromLayout(layoutOverride);
    }

    final cachedSchema = _peekTableSchema(tableUid);
    final useCache = schema == null ||
        (cachedSchema != null && identical(cachedSchema, schema));
    if (useCache) {
      final cached = _storageFieldStructCache[tableUid];
      if (cached != null) {
        return cached;
      }
    }

    final layout = await getTableFieldLayout(tableUid);
    if (layout.slots.isEmpty) {
      return const <FieldStructure>[];
    }
    final struct = buildStorageFieldStructureFromLayout(layout);
    if (useCache) {
      _storageFieldStructCache[tableUid] = struct;
    }
    return struct;
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
    return _indexCacheEntryFor(schema).allIndexes;
  }

  /// Get all unique indexes (including composite unique indexes) for a table.
  List<IndexSchema> getUniqueIndexesFor(TableSchema schema) {
    return _indexCacheEntryFor(schema).uniqueIndexes;
  }

  /// Get all non-vector (B+Tree) indexes for a table.
  List<IndexSchema> getBtreeIndexesFor(TableSchema schema) {
    return _indexCacheEntryFor(schema).btreeIndexes;
  }

  /// Get all vector indexes for a table.
  List<IndexSchema> getVectorIndexesFor(TableSchema schema) {
    return _indexCacheEntryFor(schema).vectorIndexes;
  }

  /// Shared index lists are bound only to the **hot** schema instance
  /// ([_peekTableSchema]). Migration / foreign snapshots are built ephemerally
  /// and never written into [_indexListCache] (avoids pinning stale schemas).
  _IndexListCacheEntry _indexCacheEntryFor(TableSchema schema) {
    final cacheKey = schema.tableUid;
    final hot = _peekTableSchema(cacheKey);
    if (hot != null && identical(hot, schema)) {
      final existing = _indexListCache[cacheKey];
      if (existing != null) return existing;
      final entry = _buildIndexListCache(schema);
      _indexListCache[cacheKey] = entry;
      return entry;
    }
    return _buildIndexListCache(schema);
  }

  /// O(1) lookup of [IndexSchema] by stable [IndexUid].
  IndexSchema? findIndexSchemaByUid(TableSchema schema, IndexUid indexUid) {
    if (indexUid.isEmpty) return null;
    return _indexCacheEntryFor(schema).byUid[indexUid];
  }

  /// O(1) lookup of single-column unique index by field name.
  IndexSchema? findSingleFieldUniqueIndex(
      TableSchema schema, String fieldName) {
    if (fieldName.isEmpty) return null;
    return _indexCacheEntryFor(schema).uniqueBySingleField[fieldName];
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
    final byUid = resolveIndexContext(table, indexUid);
    if (byUid != null) return byUid;
    final idx = findIndexSchemaByField(table.schema, uidOrName);
    if (idx == null) return null;
    return IndexContext(
      indexUid: indexUid,
      indexName: IndexName(uidOrName),
      schema: idx,
      table: table,
    );
  }

  /// Allocate a data directory index for a new table.
  ///
  /// Prefers under-capacity dirs rebuilt after [loadAllTableMetaAsync].
  /// Otherwise advances [GlobalConfig] high-water
  /// (`last*DirIndex` / `last*DirEntries`) with no extra KV IO.
  /// [persist]: when false, updates in-memory GlobalConfig cache only to avoid
  /// redundant disk rewrites during batch table creation (flushed in updateSchemaHashes).
  Future<int> allocateDirIndex(bool isGlobal, {bool persist = true}) {
    final done = Completer<int>();
    _dirAllocChain = _dirAllocChain.then((_) async {
      try {
        done.complete(
            await _allocateDirIndexUnlocked(isGlobal, persist: persist));
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  Future<int> _allocateDirIndexUnlocked(
    bool isGlobal, {
    bool persist = true,
  }) async {
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
        persist: persist,
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
    await _dataStore.saveGlobalConfig(updated, persist: persist);

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
    bool persist = true,
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
    await _dataStore.saveGlobalConfig(updated, persist: persist);
  }

  /// Load [TableMeta] by stable uid - the single entry for meta / routing.
  ///
  /// 1. Hot [TreeCache] (default LRU eviction)
  /// 2. If [_nameInventoryReady] and uid absent from [_nameByUid] - absent
  /// 3. Else query `_system_table_meta` (cold start, partial inventory, or
  ///    inventory hit but cache miss after eviction)
  ///
  /// Note: [TreeCache.isFullyCached](`all`) alone is **not** used for the
  /// negative short-circuit - loadAll may set it after mid-load eviction left
  /// the TreeCache incomplete while the lightweight inventory is complete.
  Future<TableMeta?> getTableMeta(TableUid tableUid) async {
    if (tableUid.isEmpty) return null;

    // Self-row: never fabricate existence. Use [bootstrapTableMetaContext] for
    // QueryExecutor I/O; only return meta after save/load registered it.
    if (tableUid == SystemTable.tableMetaTableUid) {
      final pinned = _pinnedMetaTableMeta;
      if (pinned != null) return pinned;
      final cached = _tableMetaCache?.get(tableUid);
      if (cached != null) return cached;
      if (_tableMetaCache?.isFullyCached('all') == true) {
        return null;
      }
      if (_nameInventoryReady && !_nameByUid.containsKey(tableUid)) {
        return null;
      }
      return _loadTableMetaSingleFlight(tableUid);
    }

    final hot = _tableMetaCache?.get(tableUid);
    if (hot != null) return hot;

    // Partial / empty cache: inventory can only skip IO for unknown uids.
    // Known uids (in [_nameByUid]) with a cache miss must hit the system table.
    if (_nameInventoryReady && !_nameByUid.containsKey(tableUid)) {
      return null;
    }

    return _loadTableMetaSingleFlight(tableUid);
  }

  Future<TableMeta?> _loadTableMetaSingleFlight(TableUid tableUid) async {
    final existing = _metaLoadingFutures[tableUid];
    if (existing != null) return existing;

    final epoch = _cacheEpoch;
    final loadFuture = _doLoadTableMeta(tableUid, expectEpoch: epoch);
    _metaLoadingFutures[tableUid] = loadFuture;
    try {
      return await loadFuture;
    } finally {
      _metaLoadingFutures.remove(tableUid);
    }
  }

  /// Load one meta row from `_system_table_meta`.
  ///
  /// Empty result - `null`. IO/decode errors - [DbException].
  /// When [expectEpoch] mismatches [_cacheEpoch], the decoded meta is returned
  /// but not written into caches (invalidate/dispose raced the load).
  Future<TableMeta?> _doLoadTableMeta(
    TableUid tableUid, {
    int? expectEpoch,
  }) async {
    // Pure memory DBs have no durable meta table; treat miss as absent.
    if (_dataStore.config.persistenceMode == PersistenceMode.memory) {
      return null;
    }
    try {
      _ensureMetaTableIoLayout();
      final rows = (await _dataStore.queryExecutor.execute(
        bootstrapTableMetaContext(),
        condition: QueryCondition()
          ..where(SystemTable.tableMetaUidField, '=', tableUid.value),
        limit: 1,
      ))
          .records;
      if (rows.isEmpty) return null;

      final meta = TableMetaCodec.decodeRow(rows.first);
      if (expectEpoch != null && expectEpoch != _cacheEpoch) {
        return meta;
      }
      _registerMetaInLookups(meta);
      _cacheTableMeta(meta);
      return meta;
    } catch (e) {
      if (e is DbException) rethrow;
      final logTable = _peekNameByUid(tableUid)?.value ?? tableUid.value;
      Logger.error('Failed to load table meta: $logTable', rawError: e);
      throw DbException.wrap(
        e,
        fallbackMessage: 'Failed to load table meta: $logTable',
      );
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

  /// Resolve table uid by name (pure lookup - no space-manifest side effects).
  ///
  /// Cold path: one point query on `_system_table_meta`. Does **not** await
  /// full name inventory and does **not** activate non-global tables into the
  /// current space (activation is owned by [saveTableMeta] only).
  Future<TableUid?> resolveTableUidFromName(TableName tableName) async {
    if (tableName.isEmpty) return null;

    // Fixed identity - do not query self by name (bootstrap / cold path).
    if (tableName.value == SystemTable.tableMetaName) {
      return SystemTable.tableMetaTableUid;
    }

    final cached = _peekUidByName(tableName);
    if (cached != null) return cached;

    // Full inventory: name miss - table does not exist (no IO).
    if (_nameInventoryReady) return null;

    try {
      _ensureMetaTableIoLayout();
      final rows = (await _dataStore.queryExecutor.execute(
        bootstrapTableMetaContext(),
        condition: QueryCondition()
          ..where(SystemTable.tableMetaNameField, '=', tableName.value),
        limit: 1,
      ))
          .records;
      if (rows.isEmpty) return null;

      final meta = TableMetaCodec.decodeRow(rows.first);
      // Register before any further await so re-entrant name resolves
      // (e.g. internal KV -> getTableContext) hit memory.
      _registerMetaInLookups(meta);
      _cacheTableMeta(meta);
      return meta.tableUid;
    } catch (e) {
      if (e is DbException) rethrow;
      Logger.error(
        'Failed to resolve table uid from name: ${tableName.value}',
        rawError: e,
      );
      throw DbException.wrap(
        e,
        fallbackMessage:
            'Failed to resolve table uid from name: ${tableName.value}',
      );
    }
  }

  /// Patch an existing [TableMeta] row (schema / name / layout / extra).
  ///
  /// Loads current meta, applies only provided fields, then persists via
  /// [saveTableMeta]. Does not create tables; missing uid - [DbException].
  /// Does not change [TableMeta.dirIndex] (create/allocate only via save).
  Future<TableMeta> updateTableMeta(
    TableUid tableUid, {
    TableName? tableName,
    TableSchema? schema,
    FieldStorageLayout? layoutOverride,
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
      layoutOverride: layoutOverride,
    );
  }

  /// Persist full [TableMeta] (create / upgrade ingest / bootstrap).
  ///
  /// Prefer [updateTableMeta] when patching an existing table.
  /// Returns the final saved meta (tableUid may be reallocated on PK collision).
  ///
  /// Disk write succeeds first; memory inventory/cache is updated only after.
  /// Create path retries only on primary-key (`table_uid`) conflicts with a
  /// fresh uid - unique/name conflicts and other errors are not retried.
  Future<TableMeta> saveTableMeta(
    TableMeta meta, {
    bool memoryOnly = false,
    Map<String, String> fieldRenameHints = const <String, String>{},
    FieldStorageLayout? layoutOverride,
    int? dirIndex,
  }) async {
    var dirPreCounted = false;
    var resolvedDirIndex = 0;
    var resolvedIsGlobal = meta.isGlobal;
    var allocatedNewDir = false;
    var dirSlotCommitted = false;

    try {
      var schema = meta.schema;
      var tableUid = meta.tableUid.isNotEmpty
          ? meta.tableUid
          : (schema.tableUid.isNotEmpty ? schema.tableUid : TableUid.empty);

      // Resolve update vs create. Rename keeps the same tableUid; a new uid is
      // allocated only when creating a table without a preferred identity.
      final preferredName =
          meta.tableName.isNotEmpty ? meta.tableName : TableName(schema.name);
      tableUid = await _resolveTableUidForSave(
        preferredUid: tableUid,
        tableName: preferredName,
      );
      if (schema.tableUid != tableUid) {
        schema = schema.copyWith(tableUid: tableUid);
      }

      final current = _peekTableMeta(tableUid) ?? await getTableMeta(tableUid);
      // Avoid recursive bootstrap for the meta table itself during first save.
      final currentSchema = current?.schema;
      schema = schema.generateAutoIndexes(
        oldSchema: currentSchema,
        fieldRenames: fieldRenameHints,
      );

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
      // maps - skip a second increment in _registerMetaInLookups for new tables.
      if (tableUid == SystemTable.tableMetaTableUid) {
        resolvedDirIndex = SystemTable.tableMetaDirIndex;
        dirPreCounted = false;
      } else if (current != null) {
        resolvedDirIndex = dirIndex ?? current.dirIndex;
        dirPreCounted = false;
      } else if (dirIndex != null) {
        resolvedDirIndex = dirIndex;
        dirPreCounted = true;
        allocatedNewDir = true;
      } else {
        resolvedDirIndex = await allocateDirIndex(schema.isGlobal);
        dirPreCounted = true;
        allocatedNewDir = true;
      }
      resolvedIsGlobal = schema.isGlobal;

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

      if (memoryOnly) {
        _registerMetaInLookups(saved, skipDirCountIncrement: dirPreCounted);
        _cacheTableMeta(saved);
        dirSlotCommitted = true;
        _dataStore.upsertTtlPlanForSchema(saved.schema);
        return saved;
      }

      // Persist to system table first; only then commit memory caches.
      saved = await _persistTableMetaRowWithUidRetry(
        saved,
        allowUidRealloc: current == null,
      );

      _registerMetaInLookups(saved, skipDirCountIncrement: dirPreCounted);
      _cacheTableMeta(saved);
      dirSlotCommitted = true;

      _dataStore.upsertTtlPlanForSchema(saved.schema);
      return saved;
    } catch (e) {
      // Roll back dir slot reserved by allocateDirIndex / caller when create
      // never committed to memory lookups.
      if (allocatedNewDir && dirPreCounted && !dirSlotCommitted) {
        _decrementDirCount(resolvedIsGlobal, resolvedDirIndex);
      }
      Logger.error(
        'Failed to save table meta: ${meta.tableUid} (${meta.tableName})',
        rawError: e,
      );
      throw DbException.wrap(e, fallbackMessage: 'Failed to save table meta');
    }
  }

  /// Resolve [preferredUid] for create/update.
  ///
  /// Rename keeps the same [preferredUid] (stable identity). A new uid is
  /// allocated only on create when [preferredUid] is empty. If [tableName] is
  /// already owned by a *different* uid, throws [DbException].
  Future<TableUid> _resolveTableUidForSave({
    required TableUid preferredUid,
    required TableName tableName,
  }) async {
    if (preferredUid == SystemTable.tableMetaTableUid ||
        tableName.value == SystemTable.tableMetaName) {
      return SystemTable.tableMetaTableUid;
    }

    if (preferredUid.isNotEmpty) {
      await _ensureTableNameAvailableForUid(preferredUid, tableName);

      final invName = _nameByUid[preferredUid];
      if (invName != null) {
        // Same uid - including rename (invName != tableName).
        return preferredUid;
      }
      final localMeta = _peekTableMeta(preferredUid);
      if (localMeta != null) {
        return preferredUid;
      }
      // Inventory incomplete: probe disk. Ready + absent from [_nameByUid]
      // means the uid is free to claim.
      if (!_nameInventoryReady) {
        final disk = await _doLoadTableMeta(preferredUid);
        if (disk != null) {
          return preferredUid;
        }
      }
      return preferredUid;
    }

    await _ensureTableNameAvailableForUid(TableUid.empty, tableName);
    return _allocateUniqueTableUid();
  }

  /// Throws when [tableName] is already bound to a uid other than [ownerUid].
  ///
  /// Pass [TableUid.empty] for create paths (any existing binding is a conflict).
  Future<void> _ensureTableNameAvailableForUid(
    TableUid ownerUid,
    TableName tableName,
  ) async {
    if (tableName.isEmpty) return;

    TableUid? existing = _peekUidByName(tableName);
    if (existing == null && !_nameInventoryReady) {
      existing = await resolveTableUidFromName(tableName);
    }
    if (existing == null || existing.isEmpty) return;
    if (ownerUid.isNotEmpty && existing == ownerUid) return;

    throw DbException([
      SchemaValidationStatus(
        type: ResultType.devSchemaTableExists,
        message:
            'Cannot use table name [${tableName.value}]: already owned by another table.',
        tableName: tableName.value,
      ),
    ]);
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

      if (_nameByUid.containsKey(candidate) ||
          _peekTableMeta(candidate) != null) {
        candidate = TableUid(GlobalIdGenerator.generate('t'));
        continue;
      }

      // Inventory complete - candidate not listed is free. Otherwise probe disk.
      if (_nameInventoryReady) {
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

  bool _isPrimaryKeyConflict(DbResult result) {
    for (final s in result.statuses) {
      if (s.type == ResultType.bizPrimaryKeyViolation) {
        return true;
      }
    }
    return false;
  }

  /// Persist system-table row. Create uses [insert] so PK/name collisions
  /// surface as errors (upsert would rewrite an existing row). Update uses
  /// [upsert]. On create PK conflict only, reallocate tableUid and retry.
  Future<TableMeta> _persistTableMetaRowWithUidRetry(
    TableMeta saved, {
    required bool allowUidRealloc,
  }) async {
    const maxAttempts = 8;
    var current = saved;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final row = TableMetaCodec.encodeRow(current);
      final result = await TransactionContext.runAsSystemOperation(() async {
        if (allowUidRealloc) {
          // Create: insert must fail on colliding table_uid / table_name.
          return await _dataStore.insert(SystemTable.tableMetaName, row);
        }
        return await _dataStore.upsert(SystemTable.tableMetaName, row);
      });

      if (!result.hasErrors) return current;

      final canRetryPk = allowUidRealloc &&
          _isPrimaryKeyConflict(result) &&
          current.tableUid != SystemTable.tableMetaTableUid;
      if (!canRetryPk) {
        throw DbException(result.statuses);
      }

      final newUid = await _allocateUniqueTableUid();
      Logger.warn(
        'tableUid PK collision on persist for ${current.tableName}; '
        'reallocating ${current.tableUid} -> $newUid',
      );

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

  /// Delete table meta from system table, then caches / name inventory.
  Future<bool> deleteTableMeta(TableUid tableUid) async {
    try {
      final meta = _peekTableMeta(tableUid) ?? await getTableMeta(tableUid);
      if (meta == null) return false;

      final tableName = meta.tableName;
      final ctx = TableContext(
        tableUid: meta.tableUid,
        tableName: meta.tableName,
        isGlobal: meta.isGlobal,
        dirIndex: meta.dirIndex,
        schema: meta.schema,
      );

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

      // Disk succeeded - drop memory inventory / caches.
      _unregisterMetaFromLookups(meta);
      removeCachedTableSchema(tableUid);

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
  /// [isGlobal] filters by table scope (`true` = global only, `false` =
  /// non-global only, `null` = both). Non-global schemas are shared across
  /// spaces; only *data* is space-isolated.
  ///
  ///
  /// Awaits the one-shot name inventory when cold (joins
  /// [loadAllTableMetaAsync]) - never starts a second full-table scan.
  Future<List<String>> listAllTables({
    bool onlyUserTables = false,
    bool? isGlobal,
  }) async {
    await _ensureNameInventoryReady();

    Iterable<MapEntry<TableName, TableUid>> entries = _uidByName.entries;
    if (isGlobal != null) {
      entries = entries.where((e) {
        final global = _globalTableUids.contains(e.value);
        return isGlobal ? global : !global;
      });
    }

    var names = entries.map((e) => e.key.value).toList(growable: false);

    if (onlyUserTables) {
      return names
          .where((tableName) => !SystemTable.isSystemTable(tableName))
          .toList(growable: false);
    }

    return names;
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

  /// Persist system and/or user schema hashes in a single [GlobalConfig] write.
  Future<void> updateSchemaHashes({
    List<TableSchema>? systemSchemas,
    List<TableSchema>? userSchemas,
  }) async {
    final updateSystem = systemSchemas != null && systemSchemas.isNotEmpty;
    final updateUser = userSchemas != null && userSchemas.isNotEmpty;
    if (!updateSystem && !updateUser) return;

    try {
      final existing = await _dataStore.getGlobalConfig() ?? GlobalConfig();
      await _dataStore.saveGlobalConfig(
        existing.copyWith(
          systemSchemaHash: updateSystem
              ? TableSchema.generateSchemasHash(systemSchemas)
              : null,
          userSchemaHash:
              updateUser ? TableSchema.generateSchemasHash(userSchemas) : null,
        ),
      );
    } catch (e) {
      Logger.error('Failed to update schema hashes', rawError: e);
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
    if (_nameInventoryReady && _nameByUid.isNotEmpty) return;
    final yieldController =
        YieldController('TableMetaManager.loadAllTableMetaAsync');
    try {
      // Layout only - do not register bootstrap stub as "table exists".
      _ensureMetaTableIoLayout();

      final rows = (await _dataStore.queryExecutor.execute(
        bootstrapTableMetaContext(),
        condition: QueryCondition()
          ..where(SystemTable.tableMetaUidField, '>=', ''),
      ))
          .records;

      for (final row in rows) {
        final y1 = yieldController.maybeYield();
        if (y1 != null) await y1;
        final meta = TableMetaCodec.decodeRow(row);
        // Skip per-row dir increments; rebuild once after the scan.
        _registerMetaInLookups(meta, updateDirCounts: false);
        _cacheTableMeta(meta);
      }

      _rebuildDirCountsFromMeta();
      await _reconcileDirHighWaterFromMeta();
      _nameInventoryReady = true;
      // May stay false if mid-load eviction left TreeCache partial.
      _syncTableMetaFullyCachedFlag();
    } catch (e) {
      _clearNameInventoryAfterFailedLoad();
      Logger.error('Failed to load all table meta', rawError: e);
      throw DbException.wrap(
        e,
        fallbackMessage: 'Failed to load all table meta',
      );
    }
  }

  /// Align GlobalConfig dir high-water with lightweight inventory
  /// ([_dirIndexByUid] / [_globalTableUids]) - survives TreeCache eviction.
  Future<void> _reconcileDirHighWaterFromMeta() async {
    var maxGlobal = -1;
    var maxNonGlobal = -1;
    var globalAtMax = 0;
    var nonGlobalAtMax = 0;

    for (final e in _dirIndexByUid.entries) {
      final dirIndex = e.value;
      if (_globalTableUids.contains(e.key)) {
        if (dirIndex > maxGlobal) {
          maxGlobal = dirIndex;
          globalAtMax = 1;
        } else if (dirIndex == maxGlobal) {
          globalAtMax++;
        }
      } else {
        if (dirIndex > maxNonGlobal) {
          maxNonGlobal = dirIndex;
          nonGlobalAtMax = 1;
        } else if (dirIndex == maxNonGlobal) {
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
  final Map<String, IndexSchema> uniqueBySingleField;

  const _IndexListCacheEntry({
    required this.allIndexes,
    required this.uniqueIndexes,
    required this.vectorIndexes,
    required this.btreeIndexes,
    required this.byUid,
    required this.byAlias,
    required this.uniqueBySingleField,
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
      uniqueBySingleField: {},
    );
  }

  final unique = <IndexSchema>[];
  final vector = <IndexSchema>[];
  final btree = <IndexSchema>[];
  final byUid = <String, IndexSchema>{};
  final byAlias = <String, IndexSchema>{};
  final uniqueBySingleField = <String, IndexSchema>{};

  for (final idx in all) {
    if (idx.unique) {
      unique.add(idx);
      if (idx.fields.length == 1) {
        uniqueBySingleField[idx.fields.first] = idx;
      }
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
    uniqueBySingleField:
        Map<String, IndexSchema>.unmodifiable(uniqueBySingleField),
  );
}
