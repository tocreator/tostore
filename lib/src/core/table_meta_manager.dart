import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' show dirname;

import '../handler/binary_schema_codec.dart';
import '../handler/common.dart';
import '../handler/logger.dart';
import '../model/space_manifest.dart';
import '../handler/space_manifest_codec.dart';
import '../model/db_exception.dart';
import '../model/id_generator.dart';
import '../model/meta_info.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/system_table.dart';
import '../model/table_context.dart';
import '../model/table_identity.dart';
import '../model/table_schema.dart';
import 'data_store_impl.dart';
import 'tree_cache.dart';

/// Table meta manager.
class TableMetaManager {
  final DataStoreImpl _dataStore;
  SchemaMeta? _schemaMeta; // Cache schema meta

  /// Hot schema cache (TableSchema) using [TreeCache].
  /// Managed by ResourceManager quota: [MemoryQuotaType.schema].
  TreeCache<TableSchema>? _tableSchemaCache;

  /// Per-table index cache derived from [TableSchema].
  final Map<TableUid, _IndexListCacheEntry> _indexListCache =
      <TableUid, _IndexListCacheEntry>{};

  /// Per-table stable storage layout cache (keyed by tableUid).
  final Map<TableUid, FieldStorageLayout> _tableFieldLayoutCache =
      <TableUid, FieldStorageLayout>{};

  /// Per-table cached storage field structure derived from layout + schema (keyed by tableUid).
  final Map<TableUid, List<FieldStructure>> _storageFieldStructCache =
      <TableUid, List<FieldStructure>>{};

  // Loading futures to prevent thundering herd on concurrent schema reads (keyed by tableUid)
  final Map<TableUid, Future<TableSchema?>> _schemaLoadingFutures = {};

  static const String _deletedSlotFieldPrefix = '_system_storage_deleted_slot_';

  // --- Dynamic O(1) Memory Lookups ---
  /// Mapping from tableUid to its Schema Route Entry
  final Map<TableUid, TableSchemaRouteEntry> routeByUid = {};

  /// Mapping from tableName to tableUid (active + global tables only)
  final Map<TableName, TableUid> uidByName = {};

  /// Mapping from tableUid to tableName (active + global tables only)
  final Map<TableUid, TableName> nameByUid = {};

  // --- In-Memory Pre-Aggregated Sharding Counts ---
  final Map<int, int> _globalDirCounts = {};
  final Map<int, int> _nonGlobalDirCounts = {};

  // --- In-Memory Pre-Aggregated Partition Mappings & Sizes ---
  final Map<int, int> _partitionDirIndexMap = {};
  final Map<int, Set<int>> _dirPartitions = {};
  final Map<int, int> _partitionSizes = {};

  /// Deferred per-space metadata (inventory, large stats). Loaded asynchronously.
  final Map<String, SpaceManifest> _manifestBySpace = {};

  TableMetaManager(this._dataStore);

  /// Get tableUid by tableName
  TableUid? getUidByName(TableName tableName) {
    return uidByName[tableName];
  }

  /// Get tableName by tableUid
  TableName? getNameByUid(TableUid tableUid) {
    return nameByUid[tableUid];
  }

  /// Normalize a persisted uid-or-name field to a stable map key (prefers uid).
  String normalizeTableFieldKey(String field) {
    if (field.isEmpty) return field;
    if (routeByUid.containsKey(TableUid(field))) return field;
    return getUidByName(TableName(field))?.value ?? field;
  }

  /// Whether [normalizedKey] is an active table uid in the route map (O(1)).
  bool isActiveTableUidKey(String normalizedKey) {
    return normalizedKey.isNotEmpty &&
        routeByUid.containsKey(TableUid(normalizedKey));
  }

  /// Resolve user-visible table name from a persisted uid-or-name field.
  TableName? resolveTableNameFromField(String field) {
    if (field.isEmpty) return null;
    final byUid = getNameByUid(TableUid(field));
    if (byUid != null) return byUid;
    if (uidByName.containsKey(TableName(field))) return TableName(field);
    return null;
  }

  /// Whether [field] refers to the same table as [tableUid] (legacy name aware).
  bool tableFieldMatches(String field, TableUid tableUid) {
    if (field == tableUid.value) return true;
    return getUidByName(TableName(field)) == tableUid;
  }

  /// Resolve key used in schema partition maps (uid preferred, legacy name fallback).
  TableUid? _resolvePartitionTableKey(
    SchemaPartitionMeta meta,
    TableUid tableUid,
  ) {
    if (meta.tableSchemas.containsKey(tableUid)) return tableUid;
    final name = getNameByUid(tableUid);
    if (name != null) {
      final legacyKey = TableUid(name.value);
      if (meta.tableSchemas.containsKey(legacyKey)) return legacyKey;
    }
    return null;
  }

  /// Get TableSchemaRouteEntry by tableUid
  TableSchemaRouteEntry? getRouteByUid(TableUid tableUid) {
    return routeByUid[tableUid];
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
    );
    _tableSchemaCache = cache;
    return cache;
  }

  /// Get cached [TableSchema] if present (O(1)).
  TableSchema? getCachedTableSchema(TableUid tableUid) {
    return _tableSchemaCache?.get(tableUid);
  }

  /// Cache [TableSchema] into hotspot cache.
  void cacheTableSchema(TableUid tableUid, TableSchema schema) {
    _ensureTableSchemaCache().put(tableUid, schema);
    _indexListCache[tableUid] = _buildIndexListCache(schema);
    _storageFieldStructCache.remove(tableUid);
    if (schema.schemaVersion != null) {
      _dataStore.migrationManager?.registerSchemaVersion(schema);
    }
  }

  /// Get TableContext by tableUid (asynchronous).
  ///
  /// When [tableUid] is a legacy logical table name stored in older metadata,
  /// falls back to name lookup only if route resolution fails.
  Future<TableContext?> getTableContext(TableUid tableUid) async {
    if (tableUid.isEmpty) return null;
    var uid = tableUid;
    var route = getRouteByUid(uid);
    if (route == null) {
      final legacyUid = getUidByName(TableName(uid));
      if (legacyUid == null) return null;
      uid = legacyUid;
      route = getRouteByUid(uid);
      if (route == null) return null;
    }
    final schema = await getTableSchema(uid);
    if (schema == null) return null;
    return TableContext(
      tableUid: uid,
      tableName: route.tableName,
      isGlobal: route.isGlobal,
      dataDirIndex: route.dataDirIndex,
      schema: schema,
    );
  }

  /// Get TableContext by tableUid (synchronous, checks memory cache).
  TableContext? getTableContextSync(TableUid tableUid) {
    if (tableUid.isEmpty) return null;
    var uid = tableUid;
    var route = getRouteByUid(uid);
    if (route == null) {
      final legacyUid = getUidByName(TableName(uid));
      if (legacyUid == null) return null;
      uid = legacyUid;
      route = getRouteByUid(uid);
      if (route == null) return null;
    }
    final schema = getCachedTableSchema(uid);
    if (schema == null) return null;
    return TableContext(
      tableUid: uid,
      tableName: route.tableName,
      isGlobal: route.isGlobal,
      dataDirIndex: route.dataDirIndex,
      schema: schema,
    );
  }

  /// Get TableContext by schemaVersion (O(1) lookup in migrationManager)
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
    final route = getRouteByUid(uid);
    if (route == null) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Route entry not found for table "${schema.name}" (schema version "$schemaVersion").',
        )
      ]);
    }
    return TableContext(
      tableUid: uid,
      tableName: route.tableName,
      isGlobal: route.isGlobal,
      dataDirIndex: route.dataDirIndex,
      schema: schema,
    );
  }

  /// Remove cached schema for [tableUid].
  void removeCachedTableSchema(TableUid tableUid) {
    _tableSchemaCache?.remove(tableUid);
    _indexListCache.remove(tableUid);
    _tableFieldLayoutCache.remove(tableUid);
    _storageFieldStructCache.remove(tableUid);
  }

  /// Current schema cache size in bytes (incremental tracked).
  int getCurrentSchemaCacheSize() {
    return _tableSchemaCache?.estimatedTotalSizeBytes ?? 0;
  }

  /// Evict a ratio of schema cache entries under memory pressure.
  Future<void> evictSchemaCache({double ratio = 0.3}) async {
    final cache = _tableSchemaCache;
    if (cache == null) return;
    await cache.cleanup(removeRatio: ratio);
  }

  /// Load deferred space metadata from `space_manifest.bin`.
  Future<void> loadSpaceManifest(String spaceName) async {
    final path = _dataStore.pathManager.getSpaceManifestPath(spaceName);
    if (await _dataStore.storage.existsFile(path)) {
      final bytes = await _dataStore.storage.readAsBytes(path);
      _manifestBySpace[spaceName] = SpaceManifestCodec.decode(bytes);
      _rebuildLookups();
      return;
    }
    _manifestBySpace[spaceName] = SpaceManifest.empty;
    _rebuildLookups();
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

  /// Active non-global table UIDs for a space.
  Future<List<TableUid>> getActiveUidsForSpace(String spaceName) async {
    final manifest = await getSpaceManifest(spaceName);
    return manifest.activeTableUids;
  }

  /// Persist deferred space metadata to `space_manifest.bin`.
  Future<void> saveSpaceManifest(String spaceName) async {
    final path = _dataStore.pathManager.getSpaceManifestPath(spaceName);
    final manifest = _manifestBySpace[spaceName] ?? SpaceManifest.empty;
    final bytes = SpaceManifestCodec.encode(manifest);
    await _dataStore.storage.ensureDirectoryExists(dirname(path));
    await _dataStore.storage.writeAsBytes(path, bytes);
  }

  List<TableUid> _activeUidsForSpace(String spaceName) {
    return _manifestBySpace[spaceName]?.activeTableUids ?? const <TableUid>[];
  }

  Future<void> _updateActiveTableUids(
    String spaceName,
    void Function(List<TableUid> uids) mutate,
  ) async {
    final current = List<TableUid>.from(_activeUidsForSpace(spaceName));
    mutate(current);
    _manifestBySpace[spaceName] =
        (_manifestBySpace[spaceName] ?? SpaceManifest.empty)
            .copyWith(activeTableUids: current);
    await saveSpaceManifest(spaceName);
  }

  /// Rebuild fast-path lookup maps in memory based on current schemaMeta and active space tables.
  void _rebuildLookups() {
    routeByUid.clear();
    uidByName.clear();
    nameByUid.clear();
    _globalDirCounts.clear();
    _nonGlobalDirCounts.clear();
    _partitionDirIndexMap.clear();
    _dirPartitions.clear();

    if (_schemaMeta != null) {
      for (final route in _schemaMeta!.routes) {
        routeByUid[route.tableUid] = route;
        final counts = route.isGlobal ? _globalDirCounts : _nonGlobalDirCounts;
        counts[route.dataDirIndex] = (counts[route.dataDirIndex] ?? 0) + 1;

        _partitionDirIndexMap[route.partitionIndex] = route.dirIndex;
        _dirPartitions
            .putIfAbsent(route.dirIndex, () => {})
            .add(route.partitionIndex);

        if (route.isGlobal) {
          uidByName[route.tableName] = route.tableUid;
          nameByUid[route.tableUid] = route.tableName;
        }
      }
    }

    final activeSpace = _dataStore.currentSpaceName;
    final activeUids = _activeUidsForSpace(activeSpace);
    for (final uid in activeUids) {
      final route = getRouteByUid(uid);
      if (route != null && !route.isGlobal) {
        uidByName[route.tableName] = route.tableUid;
        nameByUid[route.tableUid] = route.tableName;
      }
    }
  }

  void _registerRouteInLookups(TableSchemaRouteEntry route) {
    final oldRoute = routeByUid[route.tableUid];
    if (oldRoute != null) {
      _unregisterRouteFromLookups(oldRoute);
    }

    routeByUid[route.tableUid] = route;
    final counts = route.isGlobal ? _globalDirCounts : _nonGlobalDirCounts;
    counts[route.dataDirIndex] = (counts[route.dataDirIndex] ?? 0) + 1;

    _partitionDirIndexMap[route.partitionIndex] = route.dirIndex;
    _dirPartitions
        .putIfAbsent(route.dirIndex, () => {})
        .add(route.partitionIndex);

    final activeSpace = _dataStore.currentSpaceName;
    final isActive = route.isGlobal ||
        _activeUidsForSpace(activeSpace).contains(route.tableUid);

    if (isActive) {
      uidByName[route.tableName] = route.tableUid;
      nameByUid[route.tableUid] = route.tableName;
    }
  }

  void _unregisterRouteFromLookups(TableSchemaRouteEntry route) {
    routeByUid.remove(route.tableUid);
    final counts = route.isGlobal ? _globalDirCounts : _nonGlobalDirCounts;
    final currentCount = counts[route.dataDirIndex] ?? 0;
    if (currentCount > 1) {
      counts[route.dataDirIndex] = currentCount - 1;
    } else {
      counts.remove(route.dataDirIndex);
    }

    bool partitionInUse = false;
    for (final r in routeByUid.values) {
      if (r.partitionIndex == route.partitionIndex) {
        partitionInUse = true;
        break;
      }
    }
    if (!partitionInUse) {
      _partitionDirIndexMap.remove(route.partitionIndex);
      final set = _dirPartitions[route.dirIndex];
      if (set != null) {
        set.remove(route.partitionIndex);
        if (set.isEmpty) {
          _dirPartitions.remove(route.dirIndex);
        }
      }
    }

    uidByName.remove(route.tableName);
    nameByUid.remove(route.tableUid);
  }

  /// Clear all in-memory caches and reset state.
  Future<void> dispose() async {
    if (_schemaLoadingFutures.isNotEmpty) {
      try {
        await Future.wait(_schemaLoadingFutures.values);
      } catch (_) {}
    }
    _tableSchemaCache?.clear();
    _indexListCache.clear();
    _tableFieldLayoutCache.clear();
    _storageFieldStructCache.clear();
    _schemaMeta = null;
    _schemaLoadingFutures.clear();
    routeByUid.clear();
    uidByName.clear();
    nameByUid.clear();
    _manifestBySpace.clear();
    _globalDirCounts.clear();
    _nonGlobalDirCounts.clear();
    _partitionDirIndexMap.clear();
    _dirPartitions.clear();
    _partitionSizes.clear();
  }

  /// Invalidate schema metadata cache
  void invalidateCache() {
    _schemaMeta = null;
    routeByUid.clear();
    uidByName.clear();
    nameByUid.clear();
    _globalDirCounts.clear();
    _nonGlobalDirCounts.clear();
    _partitionDirIndexMap.clear();
    _dirPartitions.clear();
    _partitionSizes.clear();
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

  FieldStorageLayout? _tryParseFieldStorageLayout(dynamic raw) {
    if (raw == null) return null;
    try {
      if (raw is Map<String, dynamic>) {
        return FieldStorageLayout.fromJson(raw);
      } else if (raw is Map) {
        return FieldStorageLayout.fromJson(Map<String, dynamic>.from(raw));
      } else if (raw is String) {
        return FieldStorageLayout.fromJson(
            jsonDecode(raw) as Map<String, dynamic>);
      }
    } catch (_) {}
    return null;
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

    // Mark all slots as deleted initially, then reactivate matched ones
    for (int i = 0; i < slots.length; i++) {
      slots[i] = slots[i].copyWith(deleted: true);
    }

    for (final field in nextSchema.fields) {
      int matchIdx = -1;

      // 1. Prioritize matching by stable fieldId if available
      if (field.fieldId != null && field.fieldId!.isNotEmpty) {
        matchIdx = slots.indexWhere((s) => s.fieldId == field.fieldId);
      }

      // 2. Fallback to chain-tracing matching via renameHints if fieldId matching fails
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
            currentTarget =
                match.key; // Trace chain recursively (e.g. a -> b -> c)
          } else {
            found = false;
          }
        }

        if (oldName.isNotEmpty) {
          matchIdx = slots.indexWhere((s) => s.fieldName == oldName);
        }
      }

      // 3. Fallback to direct name matching (unchanged fields)
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

    final activeByFieldId = <String, FieldStorageSlot>{};
    final activeByName = <String, FieldStorageSlot>{};
    for (final slot in activeSlots) {
      final fieldId = slot.fieldId;
      if (fieldId != null &&
          fieldId.isNotEmpty &&
          !activeByFieldId.containsKey(fieldId)) {
        activeByFieldId[fieldId] = slot;
      }
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
      final cachedSchema = getCachedTableSchema(tableUid);
      if (cachedSchema != null && identical(cachedSchema, schema)) {
        return cached;
      }
    }

    final partitionIndex = getTableSchemaPartitionIndex(tableUid);
    final dirIndex = getTableSchemaDirIndex(tableUid);
    if (partitionIndex != null && dirIndex != null) {
      final partitionMeta = await _loadPartitionMeta(partitionIndex);
      if (partitionMeta != null) {
        final raw = partitionMeta.tableFieldLayouts[tableUid];
        final parsed = _tryParseFieldStorageLayout(raw);
        if (parsed != null) {
          _tableFieldLayoutCache[tableUid] = parsed;
          return parsed;
        }
      }
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

    final cachedSchema = getCachedTableSchema(tableUid);
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
    final resolvedSchema = schema ?? await getTableSchema(tableUid);

    final name = getNameByUid(tableUid)?.value ?? resolvedSchema?.name;
    if (resolvedSchema == null || name == null) {
      final logName = name ?? getNameByUid(tableUid)?.value ?? 'unknown';
      throw DbException([
        SchemaValidationStatus(
          type: ResultType.devTableNotFound,
          message: 'Table schema not found for table: $logName',
          tableName: logName,
        ),
      ]);
    }
    final tableContext = getTableContextSync(tableUid);
    if (tableContext == null) {
      throw DbException([
        SchemaValidationStatus(
          type: ResultType.devTableNotFound,
          message: 'Table context not found for table: $name',
          tableName: name,
        ),
      ]);
    }
    await saveTableSchema(
      tableContext,
      resolvedSchema,
      layoutOverride: layout,
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
  ///
  /// Fast path: O(1) via per-table index cache. When [field] is not found in
  /// schema indexes, returns [IndexUid(field)] so callers can still access
  /// pre-migration on-disk artifacts keyed by legacy names.
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

  /// get database schema meta
  Future<SchemaMeta> getSchemaMeta() async {
    if (_schemaMeta != null) {
      return _schemaMeta!;
    }

    final path = _dataStore.pathManager.getSchemaMetaPath();
    if (await _dataStore.storage.existsFile(path)) {
      final content = await _dataStore.storage.readAsString(path);
      if (content != null && content.isNotEmpty) {
        try {
          _schemaMeta = SchemaMeta.fromJson(jsonDecode(content));
          loadSpaceManifest(_dataStore.currentSpaceName);
          return _schemaMeta!;
        } catch (e) {
          Logger.error('Failed to load schema meta', rawError: e);
        }
      }
    }

    // Create new structure meta
    _schemaMeta = SchemaMeta(
      routes: [],
      timestamps: Timestamps(
        created: DateTime.now(),
        modified: DateTime.now(),
      ),
    );
    await saveSchemaStructure();
    loadSpaceManifest(_dataStore.currentSpaceName);
    return _schemaMeta!;
  }

  /// save database schema meta
  Future<void> saveSchemaStructure() async {
    if (_schemaMeta == null) return;

    final path = _dataStore.pathManager.getSchemaMetaPath();
    await _dataStore.storage.ensureDirectoryExists(dirname(path));
    await _dataStore.storage
        .writeAsString(path, jsonEncode(_schemaMeta!.toJson()));
  }

  /// get table schema metadata partition index
  int? getTableSchemaPartitionIndex(TableUid tableUid) {
    final route = getRouteByUid(tableUid);
    return route?.partitionIndex;
  }

  /// get table schema metadata directory index
  int? getTableSchemaDirIndex(TableUid tableUid) {
    final route = getRouteByUid(tableUid);
    return route?.dirIndex;
  }

  /// allocate data directory index for a table
  int allocateDataDirIndex(bool isGlobal) {
    final usage = isGlobal ? _globalDirCounts : _nonGlobalDirCounts;
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

    // Optimistically update count to prevent race conditions during batch creates
    usage[selectedDir] = (usage[selectedDir] ?? 0) + 1;
    return selectedDir;
  }

  /// get or allocate directory index for a partition index
  int getOrCreatePartitionDirIndex(int partitionIndex) {
    final cached = _partitionDirIndexMap[partitionIndex];
    if (cached != null) return cached;

    int maxDir = 0;
    for (final dir in _dirPartitions.keys) {
      if (dir > maxDir) maxDir = dir;
    }

    final count = _dirPartitions[maxDir]?.length ?? 0;
    final allocatedDir =
        (count < _dataStore.maxEntriesPerDir) ? maxDir : maxDir + 1;

    // Optimistically update memory mappings
    _partitionDirIndexMap[partitionIndex] = allocatedDir;
    _dirPartitions.putIfAbsent(allocatedDir, () => {}).add(partitionIndex);

    return allocatedDir;
  }

  /// find suitable partition for schema storage
  Future<int> _findSuitablePartition(
      SchemaMeta meta, TableUid tableUid, int contentSize) async {
    try {
      final existingRoute = getRouteByUid(tableUid);
      if (existingRoute != null) {
        return existingRoute.partitionIndex;
      }

      final existingPartitions = _partitionDirIndexMap.keys.toList()..sort();
      for (final partitionIndex in existingPartitions) {
        int? size = _partitionSizes[partitionIndex];
        if (size == null) {
          final partitionMeta = await _loadPartitionMeta(partitionIndex);
          if (partitionMeta != null) {
            size = partitionMeta.fileSizeInBytes;
            _partitionSizes[partitionIndex] = size;
          }
        }
        if (size != null && size + contentSize <= schemaMaxPartitionFileSize) {
          return partitionIndex;
        }
      }

      return existingPartitions.isEmpty ? 0 : existingPartitions.last + 1;
    } catch (e) {
      Logger.error('Failed to find suitable partition', rawError: e);
      final existingPartitions = _partitionDirIndexMap.keys.toList()..sort();
      return existingPartitions.isEmpty ? 0 : existingPartitions.last + 1;
    }
  }

  /// create new partition meta
  SchemaPartitionMeta _createNewPartitionMeta(int index, int dirIndex) {
    return SchemaPartitionMeta(
      version: 1,
      index: index,
      fileSizeInBytes: 0,
      tableUids: [],
      tableSizes: {},
      tableSchemas: {},
      tableFieldLayouts: {},
      timestamps: Timestamps(
        created: DateTime.now(),
        modified: DateTime.now(),
      ),
      dirIndex: dirIndex,
    );
  }

  /// load partition meta
  Future<SchemaPartitionMeta?> _loadPartitionMeta(int partitionIndex) async {
    final dirIndex = getOrCreatePartitionDirIndex(partitionIndex);
    final partitionPath = _dataStore.pathManager
        .getSchemaPartitionFilePath(partitionIndex, dirIndex);
    if (!await _dataStore.storage.existsFile(partitionPath)) return null;

    final content = await _dataStore.storage.readAsString(partitionPath);
    if (content == null) return null;

    try {
      final meta = SchemaPartitionMeta.fromJson(jsonDecode(content));
      _partitionSizes[partitionIndex] = meta.fileSizeInBytes;
      return meta;
    } catch (e) {
      Logger.error('Failed to load partition meta', rawError: e);
      return null;
    }
  }

  /// save table schema, auto manage partitions
  Future<void> saveTableSchema(
    TableContext table,
    TableSchema schema, {
    FieldStorageLayout? layoutOverride,
    Map<String, String> fieldRenameHints = const <String, String>{},
    int? dataDirIndex,
  }) async {
    final tableUid = table.tableUid;
    final tableName = table.tableName;
    try {
      if (schema.tableUid.isEmpty) {
        var targetUid = tableUid.isNotEmpty
            ? tableUid
            : TableUid(GlobalIdGenerator.generate("t"));
        schema = schema.copyWith(tableUid: targetUid);
      }

      final currentSchema = await getTableSchema(schema.tableUid);
      schema = schema.generateAutoIndexes(oldSchema: currentSchema);

      // schemaVersion bumps are owned by migration tasks (or explicit createTable
      // initialization). Incidental saves preserve the persisted version.
      if (schema.schemaVersion == null || schema.schemaVersion!.isEmpty) {
        final preserved = currentSchema?.schemaVersion;
        if (preserved != null && preserved.isNotEmpty) {
          schema = schema.copyWith(schemaVersion: preserved);
        } else {
          schema = schema.copyWith(
            schemaVersion: GlobalIdGenerator.generate("s"),
          );
        }
      }

      final meta = await getSchemaMeta();
      var contentSize = _estimateTableSchemaSize(schema);

      int targetPartition =
          await _findSuitablePartition(meta, tableUid, contentSize);
      final dirIndex = getOrCreatePartitionDirIndex(targetPartition);

      final partitionPath = _dataStore.pathManager
          .getSchemaPartitionFilePath(targetPartition, dirIndex);
      SchemaPartitionMeta partitionMeta;

      if (await _dataStore.storage.existsFile(partitionPath)) {
        final content = await _dataStore.storage.readAsString(partitionPath);
        if (content != null) {
          partitionMeta = SchemaPartitionMeta.fromJson(jsonDecode(content));
        } else {
          partitionMeta = _createNewPartitionMeta(targetPartition, dirIndex);
        }
      } else {
        partitionMeta = _createNewPartitionMeta(targetPartition, dirIndex);
      }

      final schemaObject = schema.toJson();
      final existingLayout = _tryParseFieldStorageLayout(
          partitionMeta.tableFieldLayouts[tableUid]);
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
      final layoutObject = resolvedLayout.toJson();
      contentSize += _estimateFieldStorageLayoutSize(resolvedLayout);

      final oldSize = partitionMeta.tableSizes[tableUid] ?? 0;
      final newSizeChange = partitionMeta.tableUids.contains(tableUid)
          ? contentSize - oldSize
          : contentSize;

      final updatedMeta = partitionMeta.copyWith(
        fileSizeInBytes: partitionMeta.fileSizeInBytes + newSizeChange,
        tableUids: partitionMeta.tableUids.contains(tableUid)
            ? partitionMeta.tableUids
            : [...partitionMeta.tableUids, tableUid],
        tableSizes: {
          ...partitionMeta.tableSizes,
          tableUid: contentSize,
        },
        tableSchemas: {
          ...partitionMeta.tableSchemas,
          tableUid: schemaObject,
        },
        tableFieldLayouts: {
          ...partitionMeta.tableFieldLayouts,
          tableUid: layoutObject,
        },
        timestamps: Timestamps(
          created: partitionMeta.timestamps.created,
          modified: DateTime.now(),
        ),
      );

      await _dataStore.storage.ensureDirectoryExists(dirname(partitionPath));
      await _dataStore.storage
          .writeAsString(partitionPath, jsonEncode(updatedMeta.toJson()));
      _partitionSizes[targetPartition] = updatedMeta.fileSizeInBytes;

      final oldRoute = routeByUid[tableUid];
      int finalDataDirIndex = dataDirIndex ??
          (oldRoute != null
              ? oldRoute.dataDirIndex
              : allocateDataDirIndex(schema.isGlobal));

      final routeEntry = TableSchemaRouteEntry(
        tableUid: tableUid,
        tableName: tableName,
        dirIndex: dirIndex,
        partitionIndex: targetPartition,
        dataDirIndex: finalDataDirIndex,
        isGlobal: schema.isGlobal,
      );

      int idx = meta.routes.indexWhere((r) => r.tableUid == tableUid);
      if (idx >= 0) {
        meta.routes[idx] = routeEntry;
      } else {
        meta.routes.add(routeEntry);
      }
      await saveSchemaStructure();

      if (!schema.isGlobal) {
        final currentSpace = _dataStore.currentSpaceName;
        final activeUids = _activeUidsForSpace(currentSpace);
        if (!activeUids.contains(tableUid)) {
          await _updateActiveTableUids(currentSpace, (uids) {
            uids.add(tableUid);
          });
        }
      }

      _registerRouteInLookups(routeEntry);

      cacheTableSchema(tableUid, schema);
      _tableFieldLayoutCache[tableUid] = resolvedLayout;
      _storageFieldStructCache.remove(tableUid);

      _dataStore.upsertTtlPlanForSchema(schema);
    } catch (e) {
      Logger.error('Failed to save table schema: $tableUid ($tableName), ',
          rawError: e);
      throw DbException.wrap(e, fallbackMessage: 'Failed to save table schema');
    }
  }

  /// read table schema by stable uid
  Future<TableSchema?> getTableSchema(TableUid tableUid) async {
    if (tableUid.isEmpty) return null;

    // 1. Hot cached path: O(1) memory lookup with zero extra overhead
    final cached = getCachedTableSchema(tableUid);
    if (cached != null) return cached;

    // 2. Slow path: Check route and resolve legacy tableName fallbacks
    var targetUid = tableUid;
    var route = getRouteByUid(targetUid);
    if (route == null) {
      final resolvedUid =
          await resolveTableUidFromName(TableName(tableUid.value));
      if (resolvedUid != null) {
        targetUid = resolvedUid;
        final realCached = getCachedTableSchema(targetUid);
        if (realCached != null) return realCached;
      }
    }

    final existing = _schemaLoadingFutures[targetUid];
    if (existing != null) {
      return existing;
    }

    final loadFuture = _doLoadTableSchema(targetUid);
    _schemaLoadingFutures[targetUid] = loadFuture;
    try {
      return await loadFuture;
    } finally {
      _schemaLoadingFutures.remove(targetUid);
    }
  }

  /// read table schema by logical table name (user-facing / FK DSL)
  Future<TableSchema?> getTableSchemaByName(TableName tableName) async {
    final tableUid = await resolveTableUidFromName(tableName);
    if (tableUid == null) return null;
    return getTableSchema(tableUid);
  }

  /// Resolve table uid by name, lazily activating the table in the current space when needed.
  Future<TableUid?> resolveTableUidFromName(TableName tableName) async {
    final cached = getUidByName(tableName);
    if (cached != null) return cached;

    await getSchemaMeta();

    TableSchemaRouteEntry? route;
    for (final r in routeByUid.values) {
      if (r.tableName == tableName) {
        route = r;
        break;
      }
    }
    if (route == null) return null;

    if (route.isGlobal) {
      _registerRouteInLookups(route);
    } else {
      final currentSpace = _dataStore.currentSpaceName;
      final tableUid = route.tableUid;
      final activeUids = _activeUidsForSpace(currentSpace);
      if (!activeUids.contains(tableUid)) {
        await _updateActiveTableUids(currentSpace, (uids) {
          uids.add(tableUid);
        });
      }
      _registerRouteInLookups(route);
    }
    return route.tableUid;
  }

  /// Internal helper to actually load schema from file.
  Future<TableSchema?> _doLoadTableSchema(TableUid tableUid) async {
    try {
      final route = getRouteByUid(tableUid);
      if (route == null) return null;

      final partitionPath = _dataStore.pathManager
          .getSchemaPartitionFilePath(route.partitionIndex, route.dirIndex);
      if (!await _dataStore.storage.existsFile(partitionPath)) return null;

      final content = await _dataStore.storage.readAsString(partitionPath);
      if (content == null) return null;

      try {
        final partitionMeta = SchemaPartitionMeta.fromJson(jsonDecode(content));
        final partitionKey = _resolvePartitionTableKey(partitionMeta, tableUid);
        if (partitionKey == null) {
          return null;
        }

        final raw = partitionMeta.tableSchemas[partitionKey];
        Map<String, dynamic>? schemaMap;
        if (raw is Map<String, dynamic>) {
          schemaMap = raw;
        } else if (raw is Map) {
          schemaMap = Map<String, dynamic>.from(raw);
        } else if (raw is String) {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) {
            schemaMap = decoded;
          } else if (decoded is Map) {
            schemaMap = Map<String, dynamic>.from(decoded);
          }
        }
        if (schemaMap == null) return null;

        final schema = TableSchema.fromJson(schemaMap);
        var normalized = schema;
        if (normalized.getAllIndexes().any((idx) => idx.indexUid.isEmpty)) {
          normalized = normalized.generateAutoIndexes();
          unawaited(() async {
            try {
              final route = getRouteByUid(tableUid);
              if (route == null) return;
              await saveTableSchema(
                TableContext(
                  tableUid: tableUid,
                  tableName: route.tableName,
                  isGlobal: route.isGlobal,
                  dataDirIndex: route.dataDirIndex,
                  schema: normalized,
                ),
                normalized,
              );
            } catch (e) {
              Logger.warn(
                'Failed to persist indexUid repair for table $tableUid',
                rawError: e,
              );
            }
          }());
        }
        cacheTableSchema(tableUid, normalized);
        final layoutRaw = partitionMeta.tableFieldLayouts[partitionKey] ??
            partitionMeta.tableFieldLayouts[tableUid];
        final parsedLayout = _tryParseFieldStorageLayout(layoutRaw);
        if (parsedLayout != null) {
          _tableFieldLayoutCache[tableUid] = parsedLayout;
          _storageFieldStructCache.remove(tableUid);
        }
        return normalized;
      } catch (e) {
        final logTable = getNameByUid(tableUid)?.value ?? 'unknown';
        Logger.error('Failed to parse table schema: $logTable, ', rawError: e);
        return null;
      }
    } catch (e) {
      final logTable = getNameByUid(tableUid)?.value ?? 'unknown';
      Logger.error('Failed to get table schema: $logTable, ', rawError: e);
      return null;
    }
  }

  /// delete table schema
  Future<bool> deleteTableSchema(TableUid tableUid) async {
    try {
      final meta = await getSchemaMeta();
      int routeIdx = meta.routes.indexWhere((r) => r.tableUid == tableUid);
      if (routeIdx < 0) return false;

      final route = meta.routes[routeIdx];
      final success = await _removeTableFromPartition(
          tableUid, route.partitionIndex, route.dirIndex);

      if (success) {
        meta.routes.removeAt(routeIdx);
        await saveSchemaStructure();

        if (!route.isGlobal) {
          final currentSpace = _dataStore.currentSpaceName;
          if (_activeUidsForSpace(currentSpace).contains(tableUid)) {
            await _updateActiveTableUids(currentSpace, (uids) {
              uids.remove(tableUid);
            });
          }
        }

        final tableName = getNameByUid(tableUid);
        _unregisterRouteFromLookups(route);
        removeCachedTableSchema(tableUid);

        if (tableName != null && tableName.isNotEmpty) {
          _dataStore.removeTtlPlanForTable(getTableContextSync(tableUid)!);
        }
      }

      return success;
    } catch (e) {
      final logTable = getNameByUid(tableUid)?.value ?? 'unknown';
      Logger.error('Failed to delete table schema: $logTable, ', rawError: e);
      return false;
    }
  }

  /// remove table from partition
  Future<bool> _removeTableFromPartition(
      TableUid tableUid, int partitionIndex, int dirIndex) async {
    final partitionPath = _dataStore.pathManager
        .getSchemaPartitionFilePath(partitionIndex, dirIndex);
    if (!await _dataStore.storage.existsFile(partitionPath)) return false;

    final content = await _dataStore.storage.readAsString(partitionPath);
    if (content == null) return false;

    try {
      final partitionMeta = SchemaPartitionMeta.fromJson(jsonDecode(content));
      if (!partitionMeta.tableSchemas.containsKey(tableUid)) return false;

      final oldSize = partitionMeta.tableSizes[tableUid] ?? 0;
      final newSize = partitionMeta.fileSizeInBytes - oldSize;

      final updatedMeta = partitionMeta.copyWith(
        fileSizeInBytes: newSize,
        tableUids:
            partitionMeta.tableUids.where((uid) => uid != tableUid).toList(),
        tableSizes: Map.from(partitionMeta.tableSizes)..remove(tableUid),
        tableSchemas: Map.from(partitionMeta.tableSchemas)..remove(tableUid),
        tableFieldLayouts: Map.from(partitionMeta.tableFieldLayouts)
          ..remove(tableUid),
        timestamps: Timestamps(
          created: partitionMeta.timestamps.created,
          modified: DateTime.now(),
        ),
      );

      await _dataStore.storage
          .writeAsString(partitionPath, jsonEncode(updatedMeta.toJson()));
      _partitionSizes[partitionIndex] = updatedMeta.fileSizeInBytes;

      return true;
    } catch (e) {
      Logger.error('Failed to delete table schema from partition', rawError: e);
      return false;
    }
  }

  /// list all table names visible in current context
  Future<List<String>> listAllTables({bool onlyUserTables = false}) async {
    await getSchemaMeta();
    final names = uidByName.keys.map((n) => n.value).toList();

    if (onlyUserTables) {
      return names
          .where((tableName) => !SystemTable.isSystemTable(tableName))
          .toList();
    }

    return names;
  }

  /// get partition status, for monitoring and management
  Future<Map<String, dynamic>> getPartitionStats() async {
    try {
      final meta = await getSchemaMeta();
      final uniquePartitions = _partitionDirIndexMap.keys.toList();

      final result = <String, dynamic>{
        'totalTables': meta.routes.length,
        'partitionDetails': <Map<String, dynamic>>[],
      };

      if (uniquePartitions.isEmpty) {
        return result;
      }

      final partitionDetails = <Map<String, dynamic>>[];

      for (final partitionIndex in uniquePartitions) {
        final partitionMeta = await _loadPartitionMeta(partitionIndex);
        if (partitionMeta != null) {
          partitionDetails.add({
            'index': partitionMeta.index,
            'version': partitionMeta.version,
            'currentSize': partitionMeta.fileSizeInBytes,
            'maxSize': schemaMaxPartitionFileSize,
            'usagePercentage': (partitionMeta.fileSizeInBytes /
                    schemaMaxPartitionFileSize *
                    100)
                .toStringAsFixed(2),
            'tableCount': partitionMeta.tableUids.length,
            'lastModified': partitionMeta.timestamps.modified.toIso8601String(),
          });
        }
      }

      result['partitionDetails'] = partitionDetails;
      return result;
    } catch (e) {
      Logger.error('Failed to get partition stats', rawError: e);
      return {'error': '$e', 'totalTables': 0, 'partitionDetails': []};
    }
  }

  /// optimize partitions, reassign tables to balance storage
  Future<bool> optimizePartitions() async {
    try {
      final startTime = DateTime.now();
      Logger.debug('Start partition optimization...');

      final meta = await getSchemaMeta();
      if (meta.routes.isEmpty) {
        Logger.debug('No table info, skip optimization');
        return true;
      }

      final uniquePartitions = _partitionDirIndexMap.keys.toList();

      if (uniquePartitions.isEmpty) {
        Logger.debug('No partition info, skip optimization');
        return true;
      }

      int totalSize = 0;
      final partitionMetas = <int, SchemaPartitionMeta>{};

      for (final partitionIndex in uniquePartitions) {
        final partitionMeta = await _loadPartitionMeta(partitionIndex);
        if (partitionMeta != null) {
          totalSize += partitionMeta.fileSizeInBytes;
          partitionMetas[partitionIndex] = partitionMeta;
        }
      }

      if (partitionMetas.isEmpty) {
        Logger.debug('No valid partition meta, skip optimization');
        return true;
      }

      final averageSize = totalSize / partitionMetas.length;
      const threshold = 0.2; // 20% difference threshold

      final overloadedPartitions = <int>[];
      final underutilizedPartitions = <int>[];

      for (final entry in partitionMetas.entries) {
        final partitionMeta = entry.value;
        if (partitionMeta.fileSizeInBytes > averageSize * (1 + threshold)) {
          overloadedPartitions.add(entry.key);
        } else if (partitionMeta.fileSizeInBytes <
                averageSize * (1 - threshold) &&
            partitionMeta.fileSizeInBytes + averageSize * threshold <
                schemaMaxPartitionFileSize) {
          underutilizedPartitions.add(entry.key);
        }
      }

      if (overloadedPartitions.isEmpty) {
        Logger.debug(
          'No partitions need optimization, all partitions are balanced',
        );
        return true;
      }

      final tablesMovedCount = <TableUid>[];

      for (final overloadedIndex in overloadedPartitions) {
        if (underutilizedPartitions.isEmpty) break;

        final overloadedMeta = await _loadPartitionMeta(overloadedIndex);
        if (overloadedMeta == null) continue;

        final tablesToMove = <TableUid>[];

        for (final tableUid in overloadedMeta.tableUids) {
          final tableSize = overloadedMeta.tableSizes[tableUid] ?? 0;
          if (tableSize > 0 && tableSize < schemaMaxPartitionFileSize * 0.5) {
            tablesToMove.add(tableUid);
            if (overloadedMeta.fileSizeInBytes - tableSize <= averageSize) {
              break;
            }
          }
        }

        for (final tableUid in tablesToMove) {
          if (underutilizedPartitions.isEmpty) break;

          final tableSize = overloadedMeta.tableSizes[tableUid] ?? 0;
          int targetPartition = -1;

          for (final underIndex in underutilizedPartitions) {
            final underMeta = partitionMetas[underIndex];
            if (underMeta != null &&
                underMeta.fileSizeInBytes + tableSize <=
                    schemaMaxPartitionFileSize) {
              targetPartition = underIndex;
              break;
            }
          }

          if (targetPartition == -1) continue;

          final schema = overloadedMeta.tableSchemas[tableUid];
          if (schema == null) continue;
          final fieldLayout = overloadedMeta.tableFieldLayouts[tableUid];

          Logger.debug(
            'Moving table $tableUid from partition $overloadedIndex to partition $targetPartition (size: $tableSize bytes)',
          );

          final success = await _removeTableFromPartition(tableUid,
              overloadedIndex, getOrCreatePartitionDirIndex(overloadedIndex));
          if (success) {
            final targetDirIndex =
                getOrCreatePartitionDirIndex(targetPartition);
            final targetPartitionPath = _dataStore.pathManager
                .getSchemaPartitionFilePath(targetPartition, targetDirIndex);
            SchemaPartitionMeta targetPartitionMeta;

            if (await _dataStore.storage.existsFile(targetPartitionPath)) {
              final content =
                  await _dataStore.storage.readAsString(targetPartitionPath);
              if (content != null) {
                targetPartitionMeta =
                    SchemaPartitionMeta.fromJson(jsonDecode(content));
              } else {
                targetPartitionMeta =
                    _createNewPartitionMeta(targetPartition, targetDirIndex);
              }
            } else {
              targetPartitionMeta =
                  _createNewPartitionMeta(targetPartition, targetDirIndex);
            }

            final updatedMeta = targetPartitionMeta.copyWith(
              fileSizeInBytes: targetPartitionMeta.fileSizeInBytes + tableSize,
              tableUids: [...targetPartitionMeta.tableUids, tableUid],
              tableSizes: {
                ...targetPartitionMeta.tableSizes,
                tableUid: tableSize,
              },
              tableSchemas: {
                ...targetPartitionMeta.tableSchemas,
                tableUid: schema,
              },
              tableFieldLayouts: {
                ...targetPartitionMeta.tableFieldLayouts,
                if (fieldLayout != null) tableUid: fieldLayout,
              },
              timestamps: Timestamps(
                created: targetPartitionMeta.timestamps.created,
                modified: DateTime.now(),
              ),
            );

            await _dataStore.storage
                .ensureDirectoryExists(dirname(targetPartitionPath));
            await _dataStore.storage.writeAsString(
                targetPartitionPath, jsonEncode(updatedMeta.toJson()));

            int rIdx = meta.routes.indexWhere((r) => r.tableUid == tableUid);
            if (rIdx >= 0) {
              final r = meta.routes[rIdx];
              meta.routes[rIdx] = TableSchemaRouteEntry(
                tableUid: r.tableUid,
                tableName: r.tableName,
                dirIndex: targetDirIndex,
                partitionIndex: targetPartition,
                dataDirIndex: r.dataDirIndex,
                isGlobal: r.isGlobal,
              );
            }

            tablesMovedCount.add(tableUid);
          }

          final updatedMeta = await _loadPartitionMeta(targetPartition);
          if (updatedMeta != null &&
              updatedMeta.fileSizeInBytes > averageSize) {
            underutilizedPartitions.remove(targetPartition);
          }
        }
      }

      await saveSchemaStructure();
      _rebuildLookups();

      final duration = DateTime.now().difference(startTime);
      Logger.debug(
        'Partition optimization completed: moved ${tablesMovedCount.length} tables, time taken ${duration.inMilliseconds}ms',
      );

      return true;
    } catch (e) {
      Logger.error('Partition optimization failed', rawError: e);
      return false;
    }
  }

  /// get table is global table
  Future<bool?> isTableGlobal(TableUid tableUid) async {
    final schema = await getTableSchema(tableUid);
    if (schema == null) {
      return null;
    }
    return schema.isGlobal;
  }

  bool _hasSchemaChanged(List<TableSchema> schemas, String? oldHash) {
    if (oldHash == null || oldHash.isEmpty) {
      return true;
    }

    final newHash = TableSchema.generateSchemasHash(schemas);
    return oldHash != newHash;
  }

  /// High-performance check if user-defined table schema has changed
  Future<bool> isSchemaChanged(List<TableSchema> schemas) async {
    try {
      final meta = await getSchemaMeta();
      final oldHash = meta.userSchemaHash;

      return _hasSchemaChanged(
        schemas,
        oldHash,
      );
    } catch (e) {
      Logger.error('Failed to judge table schema change', rawError: e);
      return true; // return true when error, for safety upgrade
    }
  }

  /// Check if system table schema has changed
  Future<bool> isSystemSchemaChanged(List<TableSchema> schemas) async {
    try {
      final meta = await getSchemaMeta();
      final oldHash = meta.systemSchemaHash;

      return _hasSchemaChanged(
        schemas,
        oldHash,
      );
    } catch (e) {
      Logger.error('Failed to judge system schema change', rawError: e);
      return true;
    }
  }

  /// Update user-defined table schema hash
  Future<void> updateUserSchemaHash(List<TableSchema> schemas) async {
    if (schemas.isEmpty) return;
    try {
      final hash = TableSchema.generateSchemasHash(schemas);
      final meta = await getSchemaMeta();
      _schemaMeta = meta.copyWith(userSchemaHash: hash);
      await saveSchemaStructure();
    } catch (e) {
      Logger.error('Failed to update user schema hash', rawError: e);
    }
  }

  /// Update system table schema hash
  Future<void> updateSystemSchemaHash(List<TableSchema> schemas) async {
    if (schemas.isEmpty) return;
    try {
      final hash = TableSchema.generateSchemasHash(schemas);
      final meta = await getSchemaMeta();
      _schemaMeta = meta.copyWith(systemSchemaHash: hash);
      await saveSchemaStructure();
    } catch (e) {
      Logger.error('Failed to update system schema hash', rawError: e);
    }
  }
}

/// Lightweight per-table index cache entry.
///
/// All lists are immutable views to avoid accidental modification on hot paths.
class _IndexListCacheEntry {
  final List<IndexSchema> allIndexes;
  final List<IndexSchema> uniqueIndexes;
  final List<IndexSchema> vectorIndexes;

  /// All non-vector indexes (btree).
  final List<IndexSchema> btreeIndexes;

  /// Stable uid -> schema (O(1) hot-path lookup).
  final Map<String, IndexSchema> byUid;

  /// Legacy alias -> schema (actualIndexName / indexName; compat only).
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
///
/// This is the only place that calls the relatively expensive
/// [TableSchema.getAllIndexes], ensuring we pay the cost only when
/// table structure actually changes, not per-record.
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

  // Use unmodifiable views to guard against accidental mutation.
  return _IndexListCacheEntry(
    allIndexes: List<IndexSchema>.unmodifiable(all),
    uniqueIndexes: List<IndexSchema>.unmodifiable(unique),
    vectorIndexes: List<IndexSchema>.unmodifiable(vector),
    btreeIndexes: List<IndexSchema>.unmodifiable(btree),
    byUid: Map<String, IndexSchema>.unmodifiable(byUid),
    byAlias: Map<String, IndexSchema>.unmodifiable(byAlias),
  );
}
