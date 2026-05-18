import 'dart:convert';

import 'package:path/path.dart' show dirname;

import '../handler/binary_schema_codec.dart';
import '../handler/logger.dart';
import '../model/meta_info.dart';
import '../model/system_table.dart';
import '../model/table_schema.dart';
import 'data_store_impl.dart';
import 'tree_cache.dart';

/// table schema manager
class SchemaManager {
  final DataStoreImpl _dataStore;
  SchemaMeta? _schemaMeta; // Cache schema meta

  /// Hot schema cache (TableSchema) using [TreeCache].
  /// Managed by ResourceManager quota: [MemoryQuotaType.schema].
  TreeCache<TableSchema>? _tableSchemaCache;

  /// Per-table index cache derived from [TableSchema].
  ///
  /// Responsibilities:
  /// - Provide O(1) access to:
  ///   - all indexes (explicit + implicit unique + FK)
  ///   - unique indexes (including composite unique)
  ///   - vector indexes
  /// - Avoid repeated traversal of fields / foreign keys on hot paths
  ///
  /// Lifecycle:
  /// - Populated when a schema is cached or first requested via getter.
  /// - Cleared together with schema cache on:
  ///   - explicit table cache invalidation
  ///   - schema cache clear / eviction
  final Map<String, _IndexListCacheEntry> _indexListCache =
      <String, _IndexListCacheEntry>{};

  /// Per-table stable storage layout cache.
  final Map<String, FieldStorageLayout> _tableFieldLayoutCache =
      <String, FieldStorageLayout>{};

  /// Per-table cached storage field structure derived from layout + schema.
  final Map<String, List<FieldStructure>> _storageFieldStructCache =
      <String, List<FieldStructure>>{};

  // Directory mapping cache for schema partitions
  DirectoryMapping? _directoryMapping;
  int _currentPartitionDirIndex = 0;

  // Loading futures to prevent thundering herd on concurrent schema reads
  final Map<String, Future<TableSchema?>> _schemaLoadingFutures = {};

  static const String _deletedSlotFieldPrefix = '_system_storage_deleted_slot_';

  SchemaManager(this._dataStore);

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
  TableSchema? getCachedTableSchema(String tableName) {
    return _tableSchemaCache?.get(tableName);
  }

  /// Cache [TableSchema] into hotspot cache.
  void cacheTableSchema(String tableName, TableSchema schema) {
    _ensureTableSchemaCache().put(tableName, schema);
    // Rebuild index cache for this table in O(indexCount) time.
    _indexListCache[tableName] = _buildIndexListCache(schema);
    _storageFieldStructCache.remove(tableName);
  }

  /// Remove cached schema for [tableName].
  void removeCachedTableSchema(String tableName) {
    _tableSchemaCache?.remove(tableName);
    _indexListCache.remove(tableName);
    _tableFieldLayoutCache.remove(tableName);
    _storageFieldStructCache.remove(tableName);
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

  /// Clear all in-memory caches and reset state.
  Future<void> dispose() async {
    // Wait for all ongoing schema loading
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
    _directoryMapping = null;
    _schemaLoadingFutures.clear();
    _currentPartitionDirIndex = 0;
  }

  int _estimateTableSchemaSize(TableSchema schema) {
    // Lightweight approximation (avoid jsonEncode for hot paths).
    int size = 256;
    size += schema.name.length * 2;
    size += schema.primaryKey.length * 2;
    size += 64;

    // Fields
    if (schema.fields.isNotEmpty) {
      size += schema.fields.length * 140;
      for (final f in schema.fields) {
        size += f.name.length * 2;
        size += 24;
      }
    }

    // Indexes / FKs
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
    int size = 96;
    size += layout.slots.length * 64;
    for (final slot in layout.slots) {
      size += slot.fieldName.length * 2;
      size += (slot.fieldId?.length ?? 0) * 2;
    }
    return size;
  }

  String? _normalizeFieldId(FieldSchema field) {
    final id = field.fieldId;
    if (id == null) return null;
    final trimmed = id.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  FieldStorageLayout _createInitialFieldStorageLayout(TableSchema schema) {
    // NOTE: the Primary Key is stored in the physical B-Tree key
    // and is NOT included in the data slots (Value portion) by default to save space
    // back into the decoded record Map during read operations.
    final slots = <FieldStorageSlot>[];
    for (int i = 0; i < schema.fields.length; i++) {
      final field = schema.fields[i];
      slots.add(FieldStorageSlot(
        slotId: i,
        fieldId: _normalizeFieldId(field),
        fieldName: field.name,
        typeIndex: field.type.index,
        deleted: false,
      ));
    }
    return FieldStorageLayout(nextSlotId: slots.length, slots: slots);
  }

  FieldStorageLayout? _tryParseFieldStorageLayout(dynamic raw) {
    if (raw is Map<String, dynamic>) {
      return FieldStorageLayout.fromJson(raw);
    }
    if (raw is Map) {
      return FieldStorageLayout.fromJson(Map<String, dynamic>.from(raw));
    }
    return null;
  }

  FieldStorageLayout _evolveFieldStorageLayout({
    required FieldStorageLayout? existingLayout,
    required TableSchema nextSchema,
    Map<String, String> renameHints = const <String, String>{},
  }) {
    if (existingLayout == null || existingLayout.slots.isEmpty) {
      return _createInitialFieldStorageLayout(nextSchema);
    }

    final slots = List<FieldStorageSlot>.from(existingLayout.slots);
    var nextSlotId = existingLayout.nextSlotId;

    final activeBySlotId = <int, FieldStorageSlot>{};
    final activeByFieldId = <String, FieldStorageSlot>{};
    final activeByFieldName = <String, FieldStorageSlot>{};
    for (final slot in slots) {
      if (slot.deleted) continue;
      activeBySlotId[slot.slotId] = slot;
      final slotFieldId = slot.fieldId;
      if (slotFieldId != null &&
          slotFieldId.isNotEmpty &&
          !activeByFieldId.containsKey(slotFieldId)) {
        activeByFieldId[slotFieldId] = slot;
      }
      if (!activeByFieldName.containsKey(slot.fieldName)) {
        activeByFieldName[slot.fieldName] = slot;
      }
    }

    final matchedSlotIds = <int>{};
    final updatesBySlotId = <int, FieldStorageSlot>{};
    final appended = <FieldStorageSlot>[];

    for (final field in nextSchema.fields) {
      FieldStorageSlot? matched;
      final fieldId = _normalizeFieldId(field);
      if (fieldId != null) {
        matched = activeByFieldId[fieldId];
      }

      if (matched == null) {
        final hintedOldName = renameHints[field.name];
        if (hintedOldName != null && hintedOldName.isNotEmpty) {
          matched = activeByFieldName[hintedOldName];
        }
      }

      matched ??= activeByFieldName[field.name];

      if (matched != null) {
        matchedSlotIds.add(matched.slotId);
        updatesBySlotId[matched.slotId] = matched.copyWith(
          fieldId: fieldId ?? matched.fieldId,
          fieldName: field.name,
          typeIndex: field.type.index,
          deleted: false,
        );
        continue;
      }

      appended.add(FieldStorageSlot(
        slotId: nextSlotId,
        fieldId: fieldId,
        fieldName: field.name,
        typeIndex: field.type.index,
        deleted: false,
      ));
      nextSlotId++;
    }

    final evolved = <FieldStorageSlot>[];
    for (final slot in slots) {
      final updated = updatesBySlotId[slot.slotId];
      if (updated != null) {
        evolved.add(updated);
        continue;
      }
      if (!slot.deleted && !matchedSlotIds.contains(slot.slotId)) {
        evolved.add(slot.copyWith(deleted: true));
      } else {
        evolved.add(slot);
      }
    }
    evolved.addAll(appended);

    return FieldStorageLayout(
      version: existingLayout.version,
      nextSlotId: nextSlotId,
      slots: evolved,
    );
  }

  bool _canReuseExistingFieldStorageLayout(
    FieldStorageLayout layout,
    TableSchema schema, {
    Map<String, String> renameHints = const <String, String>{},
  }) {
    // Rename hints mean caller expects logical name remap; recompute is required.
    if (renameHints.isNotEmpty) {
      return false;
    }

    if (schema.fields.isEmpty) {
      // Reuse as-is: empty logical fields can coexist with deleted historical slots.
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
      final fieldId = _normalizeFieldId(field);
      final matched = (fieldId != null ? activeByFieldId[fieldId] : null) ??
          activeByName[field.name];
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
  ///
  /// Falls back to schema-derived layout for legacy metadata that does not have
  /// persisted layout information yet.
  Future<FieldStorageLayout> getTableFieldLayout(
    String tableName, {
    TableSchema? schema,
  }) async {
    final cached = _tableFieldLayoutCache[tableName];
    if (cached != null) {
      if (schema == null) {
        return cached;
      }
      final cachedSchema = getCachedTableSchema(tableName);
      if (cachedSchema != null && identical(cachedSchema, schema)) {
        return cached;
      }
    }

    final partitionIndex = await getTablePartition(tableName);
    if (partitionIndex != null) {
      final partitionMeta = await _loadPartitionMeta(partitionIndex);
      if (partitionMeta != null) {
        final raw = partitionMeta.tableFieldLayouts[tableName];
        final parsed = _tryParseFieldStorageLayout(raw);
        if (parsed != null) {
          _tableFieldLayoutCache[tableName] = parsed;
          return parsed;
        }
      }
    }

    final resolvedSchema = schema ?? await getTableSchema(tableName);
    if (resolvedSchema == null) {
      return const FieldStorageLayout(
          nextSlotId: 0, slots: <FieldStorageSlot>[]);
    }

    final derived = _createInitialFieldStorageLayout(resolvedSchema);
    _tableFieldLayoutCache[tableName] = derived;
    return derived;
  }

  /// Get stable storage field structure used by the record binary codec.
  Future<List<FieldStructure>> getStorageFieldStructure(
    String tableName, {
    TableSchema? schema,
    FieldStorageLayout? layoutOverride,
  }) async {
    if (layoutOverride != null) {
      return _buildStorageFieldStructureFromLayout(layoutOverride);
    }

    final resolvedSchema = schema ?? await getTableSchema(tableName);
    if (resolvedSchema == null) {
      return const <FieldStructure>[];
    }

    final cachedSchema = getCachedTableSchema(tableName);
    final useCache = schema == null ||
        (cachedSchema != null && identical(cachedSchema, resolvedSchema));
    if (useCache) {
      final cached = _storageFieldStructCache[tableName];
      if (cached != null) {
        return cached;
      }
    }

    final layout = await getTableFieldLayout(tableName, schema: resolvedSchema);
    final struct = _buildStorageFieldStructureFromLayout(layout);
    if (useCache) {
      _storageFieldStructCache[tableName] = struct;
    }
    return struct;
  }

  /// Persist only table field layout without modifying schema payload.
  Future<void> saveTableFieldLayout(
    String tableName,
    FieldStorageLayout layout, {
    TableSchema? schema,
  }) async {
    final resolvedSchema = schema ?? await getTableSchema(tableName);
    if (resolvedSchema == null) {
      throw StateError('Table schema not found: $tableName');
    }
    await saveTableSchema(
      tableName,
      resolvedSchema,
      layoutOverride: layout,
    );
  }

  /// Normalize a decoded record to user schema shape:
  /// - drop unknown/internal storage fields
  /// - fill missing fields with default values
  /// - output in schema field order
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
  ///
  /// This is an O(1) operation on hot path – it uses a lightweight cache
  /// derived from [TableSchema.getAllIndexes] and is rebuilt only when:
  /// - a new schema is saved for the table, or
  /// - the schema/index cache is explicitly cleared.
  List<IndexSchema> getAllIndexesFor(TableSchema schema) {
    final entry = _indexListCache[schema.name] ?? _buildIndexListCache(schema);
    _indexListCache[schema.name] = entry;
    return entry.allIndexes;
  }

  /// Get all unique indexes (including composite unique indexes) for a table.
  List<IndexSchema> getUniqueIndexesFor(TableSchema schema) {
    final entry = _indexListCache[schema.name] ?? _buildIndexListCache(schema);
    _indexListCache[schema.name] = entry;
    return entry.uniqueIndexes;
  }

  /// Get all non-vector (B+Tree) indexes for a table.
  ///
  /// Use this instead of [getAllIndexesFor] when the caller assumes
  /// B+Tree-compatible index operations (create, rebuild, write, integrity check).
  List<IndexSchema> getBtreeIndexesFor(TableSchema schema) {
    final entry = _indexListCache[schema.name] ?? _buildIndexListCache(schema);
    _indexListCache[schema.name] = entry;
    return entry.btreeIndexes;
  }

  /// Get all vector indexes for a table.
  ///
  /// When a table has no vector index, this returns an empty list and
  /// avoids any additional traversal in hot write/read paths.
  List<IndexSchema> getVectorIndexesFor(TableSchema schema) {
    final entry = _indexListCache[schema.name] ?? _buildIndexListCache(schema);
    _indexListCache[schema.name] = entry;
    return entry.vectorIndexes;
  }

  /// Async helper by table name – mainly for management / background tasks.
  Future<List<IndexSchema>> getAllIndexesForTable(String tableName) async {
    final schema = await getTableSchema(tableName);
    if (schema == null) return const <IndexSchema>[];
    return getAllIndexesFor(schema);
  }

  /// Async helper by table name – unique indexes only.
  Future<List<IndexSchema>> getUniqueIndexesForTable(String tableName) async {
    final schema = await getTableSchema(tableName);
    if (schema == null) return const <IndexSchema>[];
    return getUniqueIndexesFor(schema);
  }

  /// Async helper by table name – vector indexes only.
  Future<List<IndexSchema>> getVectorIndexesForTable(String tableName) async {
    final schema = await getTableSchema(tableName);
    if (schema == null) return const <IndexSchema>[];
    return getVectorIndexesFor(schema);
  }

  /// get database schema meta
  Future<SchemaMeta> getSchemaMeta() async {
    if (_schemaMeta != null) {
      // Warm cache if needed
      if (_directoryMapping == null && _schemaMeta!.directoryMapping != null) {
        _directoryMapping = _schemaMeta!.directoryMapping;
        if (_directoryMapping!.dirToFileCount.isNotEmpty) {
          _currentPartitionDirIndex = _directoryMapping!.dirToFileCount.keys
              .reduce((a, b) => a > b ? a : b);
        }
      }
      return _schemaMeta!;
    }

    final path = _dataStore.pathManager.getSchemaMetaPath();
    if (await _dataStore.storage.existsFile(path)) {
      final content = await _dataStore.storage.readAsString(path);
      if (content != null && content.isNotEmpty) {
        try {
          _schemaMeta = SchemaMeta.fromJson(jsonDecode(content));
          // Warm cache
          if (_schemaMeta!.directoryMapping != null) {
            _directoryMapping = _schemaMeta!.directoryMapping;
            if (_directoryMapping!.dirToFileCount.isNotEmpty) {
              _currentPartitionDirIndex = _directoryMapping!.dirToFileCount.keys
                  .reduce((a, b) => a > b ? a : b);
            }
          } else {
            _directoryMapping = DirectoryMapping();
          }
          return _schemaMeta!;
        } catch (e) {
          Logger.error('Failed to load schema meta: $e',
              label: 'SchemaManager.loadSchemaMeta');
        }
      }
    }

    // Create new structure meta
    _schemaMeta = SchemaMeta(
      version: 1,
      tablePartitionMap: {},
      timestamps: Timestamps(
        created: DateTime.now(),
        modified: DateTime.now(),
      ),
    );
    _directoryMapping = DirectoryMapping();

    await saveSchemaStructure();
    return _schemaMeta!;
  }

  /// save database schema meta
  Future<void> saveSchemaStructure() async {
    if (_schemaMeta == null) return;

    // Update directory mapping in meta if cache exists
    if (_directoryMapping != null) {
      _schemaMeta = _schemaMeta!.copyWith(directoryMapping: _directoryMapping);
    }

    final path = _dataStore.pathManager.getSchemaMetaPath();
    await _dataStore.storage.ensureDirectoryExists(dirname(path));
    await _dataStore.storage
        .writeAsString(path, jsonEncode(_schemaMeta!.toJson()));
  }

  /// get table partition index
  Future<int?> getTablePartition(String tableName) async {
    final meta = await getSchemaMeta();
    return meta.tablePartitionMap[tableName];
  }

  /// find suitable partition
  Future<int> _findSuitablePartition(SchemaMeta meta, int contentSize) async {
    try {
      // check if table exists in a partition
      for (final entry in meta.tablePartitionMap.entries) {
        final partitionIndex = entry.value; // Now it's int, not List<int>
        final partitionMeta = await _loadPartitionMeta(partitionIndex);

        if (partitionMeta != null) {
          final newSize = partitionMeta.fileSizeInBytes + contentSize;
          if (newSize <= _dataStore.config.maxPartitionFileSize) {
            return partitionIndex;
          }
        }
      }

      // find partition with enough space
      final existingPartitions = meta.tablePartitionMap.values.toSet().toList();

      for (final partitionIndex in existingPartitions) {
        final partitionMeta = await _loadPartitionMeta(partitionIndex);

        if (partitionMeta != null &&
            partitionMeta.fileSizeInBytes + contentSize <=
                _dataStore.config.maxPartitionFileSize) {
          return partitionIndex;
        }
      }

      // create new partition
      return existingPartitions.isEmpty ? 0 : existingPartitions.last + 1;
    } catch (e) {
      Logger.error(
        'Failed to find suitable partition: $e',
        label: 'SchemaManager._findSuitablePartition',
      );
      // create new partition when error
      final existingPartitions = meta.tablePartitionMap.values.toSet().toList();
      return existingPartitions.isEmpty ? 0 : existingPartitions.last + 1;
    }
  }

  /// create new partition meta
  SchemaPartitionMeta _createNewPartitionMeta(int index) {
    return SchemaPartitionMeta(
      version: 1,
      index: index,
      fileSizeInBytes: 0,
      tableNames: [],
      tableSizes: {},
      tableSchemas: {},
      tableFieldLayouts: {},
      timestamps: Timestamps(
        created: DateTime.now(),
        modified: DateTime.now(),
      ),
    );
  }

  /// Get or load directory mapping from cache or metadata.
  Future<DirectoryMapping> _getOrLoadDirectoryMapping() async {
    if (_directoryMapping != null) return _directoryMapping!;

    final meta = await getSchemaMeta();
    if (meta.directoryMapping != null) {
      _directoryMapping = meta.directoryMapping;
      if (_directoryMapping!.dirToFileCount.isNotEmpty) {
        _currentPartitionDirIndex = _directoryMapping!.dirToFileCount.keys
            .reduce((a, b) => a > b ? a : b);
      }
      return _directoryMapping!;
    }

    _directoryMapping = DirectoryMapping();
    return _directoryMapping!;
  }

  /// Get directory index for an existing partition.
  Future<int?> _getPartitionDirIndexForExistingPartition(
      int partitionIndex) async {
    final mapping = await _getOrLoadDirectoryMapping();
    final d = mapping.getDirIndex(partitionIndex);
    if (d != null) return d;

    // Fallback: try to load from partition meta (legacy support)
    final legacyDirIndex = partitionIndex ~/ _dataStore.maxEntriesPerDir;
    final partitionPath = _dataStore.pathManager
        .getSchemaPartitionFilePath(partitionIndex, legacyDirIndex);
    if (await _dataStore.storage.existsFile(partitionPath)) {
      final content = await _dataStore.storage.readAsString(partitionPath);
      if (content != null) {
        try {
          final meta = SchemaPartitionMeta.fromJson(jsonDecode(content));
          return meta.dirIndex;
        } catch (_) {}
      }
    }
    return null;
  }

  /// Get or allocate directory index for a partition.
  Future<int> _getOrAllocateDirIndexForPartition(int partitionIndex) async {
    final mapping = await _getOrLoadDirectoryMapping();

    // Existing mapping
    final existing = mapping.getDirIndex(partitionIndex);
    if (existing != null) return existing;

    // Allocate for new partition
    int currentDir = _currentPartitionDirIndex;
    int currentCount = mapping.getFileCount(currentDir);

    if (currentCount >= _dataStore.maxEntriesPerDir) {
      if (mapping.dirToFileCount.isNotEmpty) {
        currentDir =
            mapping.dirToFileCount.keys.reduce((a, b) => a > b ? a : b) + 1;
      } else {
        currentDir = 0;
      }
      currentCount = 0;
    }

    // Update mapping
    _directoryMapping = mapping.withPartitionAndDirCount(
        partitionIndex, currentDir, currentCount + 1);
    _currentPartitionDirIndex = currentDir;

    return currentDir;
  }

  /// load partition meta
  Future<SchemaPartitionMeta?> _loadPartitionMeta(int partitionIndex) async {
    final dirIndex =
        await _getPartitionDirIndexForExistingPartition(partitionIndex);
    if (dirIndex == null) {
      return null;
    }

    final partitionPath = _dataStore.pathManager
        .getSchemaPartitionFilePath(partitionIndex, dirIndex);
    if (!await _dataStore.storage.existsFile(partitionPath)) return null;

    final content = await _dataStore.storage.readAsString(partitionPath);
    if (content == null) return null;

    try {
      return SchemaPartitionMeta.fromJson(jsonDecode(content));
    } catch (e) {
      Logger.error('Failed to load partition meta: $e',
          label: 'SchemaPartitionManager._loadPartitionMeta');
      return null;
    }
  }

  /// save table schema, auto manage partitions
  Future<void> saveTableSchema(
    String tableName,
    TableSchema schema, {
    FieldStorageLayout? layoutOverride,
    Map<String, String> fieldRenameHints = const <String, String>{},
  }) async {
    try {
      final meta = await getSchemaMeta();
      var contentSize = _estimateTableSchemaSize(schema);

      // find suitable partition
      int targetPartition = await _findSuitablePartition(meta, contentSize);

      // Get or allocate directory index for this partition
      final dirIndex =
          await _getOrAllocateDirIndexForPartition(targetPartition);

      // read target partition meta
      final partitionPath = _dataStore.pathManager
          .getSchemaPartitionFilePath(targetPartition, dirIndex);
      SchemaPartitionMeta partitionMeta;

      if (await _dataStore.storage.existsFile(partitionPath)) {
        final content = await _dataStore.storage.readAsString(partitionPath);
        if (content != null) {
          partitionMeta = SchemaPartitionMeta.fromJson(jsonDecode(content));
        } else {
          partitionMeta = _createNewPartitionMeta(targetPartition);
        }
      } else {
        partitionMeta = _createNewPartitionMeta(targetPartition);
      }

      // update partition meta
      final schemaObject = schema.toJson();
      final existingLayout = _tryParseFieldStorageLayout(
          partitionMeta.tableFieldLayouts[tableName]);
      final resolvedLayout = layoutOverride ??
          ((existingLayout != null &&
                  _canReuseExistingFieldStorageLayout(
                    existingLayout,
                    schema,
                    renameHints: fieldRenameHints,
                  ))
              ? existingLayout
              : _evolveFieldStorageLayout(
                  existingLayout: existingLayout,
                  nextSchema: schema,
                  renameHints: fieldRenameHints,
                ));
      final layoutObject = resolvedLayout.toJson();
      contentSize += _estimateFieldStorageLayoutSize(resolvedLayout);

      final oldSize = partitionMeta.tableSizes[tableName] ?? 0;

      // calculate new partition size (if update, subtract old size)
      final newSizeChange = partitionMeta.tableNames.contains(tableName)
          ? contentSize - oldSize
          : contentSize;

      final updatedMeta = partitionMeta.copyWith(
        fileSizeInBytes: partitionMeta.fileSizeInBytes + newSizeChange,
        tableNames: partitionMeta.tableNames.contains(tableName)
            ? partitionMeta.tableNames
            : [...partitionMeta.tableNames, tableName],
        tableSizes: {
          ...partitionMeta.tableSizes,
          tableName: contentSize,
        },
        tableSchemas: {
          ...partitionMeta.tableSchemas,
          tableName: schemaObject,
        },
        tableFieldLayouts: {
          ...partitionMeta.tableFieldLayouts,
          tableName: layoutObject,
        },
        timestamps: Timestamps(
          created: partitionMeta.timestamps.created,
          modified: DateTime.now(),
        ),
      );

      // save partition file
      await _dataStore.storage.ensureDirectoryExists(dirname(partitionPath));
      await _dataStore.storage
          .writeAsString(partitionPath, jsonEncode(updatedMeta.toJson()));

      // update main meta mapping relation
      meta.tablePartitionMap[tableName] = targetPartition;
      await saveSchemaStructure();

      // Cache the new schema
      cacheTableSchema(tableName, schema);
      _tableFieldLayoutCache[tableName] = resolvedLayout;
      _storageFieldStructCache.remove(tableName);

      // Precise TTL cache update (no global invalidate).
      _dataStore.upsertTtlPlanForSchema(schema);
    } catch (e) {
      Logger.error('Failed to save table schema: $tableName, $e',
          label: 'SchemaManager.saveTableSchema');
      throw Exception('Failed to save table schema: $e');
    }
  }

  /// read table schema
  Future<TableSchema?> getTableSchema(String tableName) async {
    // Fast path: check in-memory cache
    final cached = getCachedTableSchema(tableName);
    if (cached != null) return cached;

    // Check if another call is already loading this schema
    final existing = _schemaLoadingFutures[tableName];
    if (existing != null) {
      return existing;
    }

    // Start loading and register the future
    final loadFuture = _doLoadTableSchema(tableName);
    _schemaLoadingFutures[tableName] = loadFuture;
    try {
      return await loadFuture;
    } finally {
      _schemaLoadingFutures.remove(tableName);
    }
  }

  /// Internal helper to actually load schema from file.
  Future<TableSchema?> _doLoadTableSchema(String tableName) async {
    try {
      final partitionIndex = await getTablePartition(tableName);
      if (partitionIndex == null) return null;

      final dirIndex =
          await _getPartitionDirIndexForExistingPartition(partitionIndex);
      if (dirIndex == null) {
        return null;
      }

      final partitionPath = _dataStore.pathManager
          .getSchemaPartitionFilePath(partitionIndex, dirIndex);
      if (!await _dataStore.storage.existsFile(partitionPath)) return null;

      final content = await _dataStore.storage.readAsString(partitionPath);
      if (content == null) return null;

      try {
        final partitionMeta = SchemaPartitionMeta.fromJson(jsonDecode(content));
        if (!partitionMeta.tableSchemas.containsKey(tableName)) return null;

        final raw = partitionMeta.tableSchemas[tableName];
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
        cacheTableSchema(tableName, schema);
        final layoutRaw = partitionMeta.tableFieldLayouts[tableName];
        final parsedLayout = _tryParseFieldStorageLayout(layoutRaw);
        if (parsedLayout != null) {
          _tableFieldLayoutCache[tableName] = parsedLayout;
          _storageFieldStructCache.remove(tableName);
        }
        return schema;
      } catch (e) {
        Logger.error('Failed to parse table schema: $tableName, $e',
            label: 'SchemaManager.getTableSchema');
        return null;
      }
    } catch (e) {
      Logger.error(
        'Failed to get table schema: $tableName, $e',
        label: 'SchemaManager.getTableSchema',
      );
      return null;
    }
  }

  /// delete table schema
  Future<bool> deleteTableSchema(String tableName) async {
    try {
      final meta = await getSchemaMeta();
      final partitionIndex = meta.tablePartitionMap[tableName];

      if (partitionIndex == null) return false;

      final success =
          await _removeTableFromPartition(tableName, partitionIndex);

      // if successfully delete table from all partitions, update meta
      if (success) {
        meta.tablePartitionMap.remove(tableName);
        await saveSchemaStructure();
        removeCachedTableSchema(tableName);

        // Precise TTL cache delete for dropped schema.
        _dataStore.removeTtlPlanForTable(tableName);
      }

      return success;
    } catch (e) {
      Logger.error(
        'Failed to delete table schema: $tableName, $e',
        label: 'SchemaManager.deleteTableSchema',
      );
      return false;
    }
  }

  /// Rename an existing table schema in place while preserving the partition.
  Future<void> renameTableSchema(
    String oldTableName,
    TableSchema newSchema,
  ) async {
    final newTableName = newSchema.name;
    if (oldTableName == newTableName) {
      await saveTableSchema(newTableName, newSchema);
      return;
    }

    try {
      final meta = await getSchemaMeta();
      final oldPartitionIndex = meta.tablePartitionMap[oldTableName];
      final existingNewPartitionIndex = meta.tablePartitionMap[newTableName];

      if (oldPartitionIndex == null) {
        if (existingNewPartitionIndex != null) {
          cacheTableSchema(newTableName, newSchema);
          removeCachedTableSchema(oldTableName);
          _dataStore.removeTtlPlanForTable(oldTableName);
          _dataStore.upsertTtlPlanForSchema(newSchema);
          return;
        }
        throw StateError('Schema for table $oldTableName does not exist');
      }

      if (existingNewPartitionIndex != null &&
          existingNewPartitionIndex != oldPartitionIndex) {
        throw StateError(
          'Schema for table $newTableName already exists in another partition',
        );
      }

      final dirIndex =
          await _getPartitionDirIndexForExistingPartition(oldPartitionIndex);
      if (dirIndex == null) {
        throw StateError(
          'Schema partition directory not found for table $oldTableName',
        );
      }

      final partitionPath = _dataStore.pathManager
          .getSchemaPartitionFilePath(oldPartitionIndex, dirIndex);
      if (!await _dataStore.storage.existsFile(partitionPath)) {
        throw StateError(
          'Schema partition file not found for table $oldTableName',
        );
      }

      final content = await _dataStore.storage.readAsString(partitionPath);
      if (content == null || content.isEmpty) {
        throw StateError(
          'Schema partition file is empty for table $oldTableName',
        );
      }

      final partitionMeta = SchemaPartitionMeta.fromJson(jsonDecode(content));
      if (!partitionMeta.tableSchemas.containsKey(oldTableName)) {
        if (partitionMeta.tableSchemas.containsKey(newTableName)) {
          meta.tablePartitionMap.remove(oldTableName);
          meta.tablePartitionMap[newTableName] = oldPartitionIndex;
          await saveSchemaStructure();
          removeCachedTableSchema(oldTableName);
          cacheTableSchema(newTableName, newSchema);
          _dataStore.removeTtlPlanForTable(oldTableName);
          _dataStore.upsertTtlPlanForSchema(newSchema);
          return;
        }
        throw StateError(
          'Schema payload not found for table $oldTableName in partition $oldPartitionIndex',
        );
      }

      final oldLayout = _tryParseFieldStorageLayout(
              partitionMeta.tableFieldLayouts[oldTableName]) ??
          _tableFieldLayoutCache[oldTableName] ??
          _createInitialFieldStorageLayout(newSchema);
      final newLayout = _evolveFieldStorageLayout(
        existingLayout: oldLayout,
        nextSchema: newSchema,
      );

      final newSize = _estimateTableSchemaSize(newSchema) +
          _estimateFieldStorageLayoutSize(newLayout);
      final oldSize = partitionMeta.tableSizes[oldTableName] ?? 0;
      final tableNames = <String>[];
      var inserted = false;
      for (final tableName in partitionMeta.tableNames) {
        if (tableName == oldTableName) {
          if (!inserted) {
            tableNames.add(newTableName);
            inserted = true;
          }
          continue;
        }
        if (tableName == newTableName) {
          inserted = true;
        }
        tableNames.add(tableName);
      }
      if (!inserted) {
        tableNames.add(newTableName);
      }

      final updatedTableSizes = Map<String, int>.from(partitionMeta.tableSizes)
        ..remove(oldTableName)
        ..[newTableName] = newSize;
      final updatedTableSchemas =
          Map<String, dynamic>.from(partitionMeta.tableSchemas)
            ..remove(oldTableName)
            ..[newTableName] = newSchema.toJson();
      final updatedTableLayouts =
          Map<String, dynamic>.from(partitionMeta.tableFieldLayouts)
            ..remove(oldTableName)
            ..[newTableName] = newLayout.toJson();

      final updatedPartitionMeta = partitionMeta.copyWith(
        fileSizeInBytes: partitionMeta.fileSizeInBytes + newSize - oldSize,
        tableNames: tableNames,
        tableSizes: updatedTableSizes,
        tableSchemas: updatedTableSchemas,
        tableFieldLayouts: updatedTableLayouts,
        timestamps: Timestamps(
          created: partitionMeta.timestamps.created,
          modified: DateTime.now(),
        ),
      );

      await _dataStore.storage.writeAsString(
          partitionPath, jsonEncode(updatedPartitionMeta.toJson()));

      meta.tablePartitionMap.remove(oldTableName);
      meta.tablePartitionMap[newTableName] = oldPartitionIndex;
      await saveSchemaStructure();

      removeCachedTableSchema(oldTableName);
      cacheTableSchema(newTableName, newSchema);
      _tableFieldLayoutCache[newTableName] = newLayout;
      _tableFieldLayoutCache.remove(oldTableName);
      _storageFieldStructCache.remove(newTableName);
      _dataStore.removeTtlPlanForTable(oldTableName);
      _dataStore.upsertTtlPlanForSchema(newSchema);
    } catch (e) {
      Logger.error(
        'Failed to rename table schema: $oldTableName -> $newTableName, $e',
        label: 'SchemaManager.renameTableSchema',
      );
      rethrow;
    }
  }

  /// remove table from partition
  Future<bool> _removeTableFromPartition(
      String tableName, int partitionIndex) async {
    final dirIndex =
        await _getPartitionDirIndexForExistingPartition(partitionIndex);
    if (dirIndex == null) {
      return false;
    }

    final partitionPath = _dataStore.pathManager
        .getSchemaPartitionFilePath(partitionIndex, dirIndex);
    if (!await _dataStore.storage.existsFile(partitionPath)) return false;

    final content = await _dataStore.storage.readAsString(partitionPath);
    if (content == null) return false;

    try {
      final partitionMeta = SchemaPartitionMeta.fromJson(jsonDecode(content));
      if (!partitionMeta.tableSchemas.containsKey(tableName)) return false;

      // calculate new size after deletion
      final oldSize = partitionMeta.tableSizes[tableName] ?? 0;
      final newSize = partitionMeta.fileSizeInBytes - oldSize;

      // create updated partition meta
      final updatedMeta = partitionMeta.copyWith(
        fileSizeInBytes: newSize,
        tableNames: partitionMeta.tableNames
            .where((name) => name != tableName)
            .toList(),
        tableSizes: Map.from(partitionMeta.tableSizes)..remove(tableName),
        tableSchemas: Map.from(partitionMeta.tableSchemas)..remove(tableName),
        tableFieldLayouts: Map.from(partitionMeta.tableFieldLayouts)
          ..remove(tableName),
        timestamps: Timestamps(
          created: partitionMeta.timestamps.created,
          modified: DateTime.now(),
        ),
      );

      // save updated partition file
      await _dataStore.storage
          .writeAsString(partitionPath, jsonEncode(updatedMeta.toJson()));

      return true;
    } catch (e) {
      Logger.error('Failed to delete table schema: $e',
          label: 'SchemaPartitionManager.deleteTableSchema');
      return false;
    }
  }

  /// list all table names
  /// [onlyUserTables] When true, filters out system tables (like key-value store tables)
  Future<List<String>> listAllTables({bool onlyUserTables = false}) async {
    final meta = await getSchemaMeta();
    final tables = meta.tablePartitionMap.keys.toList();

    if (onlyUserTables) {
      // Filter out system tables using the SystemTable.isSystemTable method
      return tables
          .where((tableName) => !SystemTable.isSystemTable(tableName))
          .toList();
    }

    return tables;
  }

  /// get partition status, for monitoring and management
  Future<Map<String, dynamic>> getPartitionStats() async {
    try {
      // get partition basic info
      final meta = await getSchemaMeta();
      final uniquePartitions = meta.tablePartitionMap.values.toSet().toList();

      final result = <String, dynamic>{
        'totalTables': meta.tablePartitionMap.length,
        'partitionDetails': <Map<String, dynamic>>[],
      };

      if (uniquePartitions.isEmpty) {
        return result;
      }

      // collect all partition details
      final partitionDetails = <Map<String, dynamic>>[];

      for (final partitionIndex in uniquePartitions) {
        final partitionMeta = await _loadPartitionMeta(partitionIndex);
        if (partitionMeta != null) {
          partitionDetails.add({
            'index': partitionMeta.index,
            'version': partitionMeta.version,
            'currentSize': partitionMeta.fileSizeInBytes,
            'maxSize': _dataStore.config.maxPartitionFileSize,
            'usagePercentage': (partitionMeta.fileSizeInBytes /
                    _dataStore.config.maxPartitionFileSize *
                    100)
                .toStringAsFixed(2),
            'tableCount': partitionMeta.tableNames.length,
            'lastModified': partitionMeta.timestamps.modified.toIso8601String(),
          });
        }
      }

      result['partitionDetails'] = partitionDetails;
      return result;
    } catch (e) {
      Logger.error(
        'Failed to get partition stats: $e',
        label: 'SchemaManager.getPartitionStats',
      );
      return {'error': '$e', 'totalTables': 0, 'partitionDetails': []};
    }
  }

  /// optimize partitions, reassign tables to balance storage
  Future<bool> optimizePartitions() async {
    try {
      final startTime = DateTime.now();
      Logger.debug('Start partition optimization...',
          label: 'SchemaManager.optimizePartitions');

      // get meta
      final meta = await getSchemaMeta();
      if (meta.tablePartitionMap.isEmpty) {
        Logger.debug('No table info, skip optimization',
            label: 'SchemaManager.optimizePartitions');
        return true;
      }

      // get all partition info
      final uniquePartitions = meta.tablePartitionMap.values.toSet().toList();

      if (uniquePartitions.isEmpty) {
        Logger.debug('No partition info, skip optimization',
            label: 'SchemaManager.optimizePartitions');
        return true;
      }

      // collect all partition info
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
        Logger.debug('No valid partition meta, skip optimization',
            label: 'SchemaManager.optimizePartitions');
        return true;
      }

      final averageSize = totalSize / partitionMetas.length;
      const threshold = 0.2; // 20% difference threshold

      // find partitions need optimization
      final overloadedPartitions = <int>[];
      final underutilizedPartitions = <int>[];

      for (final entry in partitionMetas.entries) {
        final partitionMeta = entry.value;
        if (partitionMeta.fileSizeInBytes > averageSize * (1 + threshold)) {
          overloadedPartitions.add(entry.key);
        } else if (partitionMeta.fileSizeInBytes <
                averageSize * (1 - threshold) &&
            partitionMeta.fileSizeInBytes + averageSize * threshold <
                _dataStore.config.maxPartitionFileSize) {
          underutilizedPartitions.add(entry.key);
        }
      }

      // if no partitions need optimization, return directly
      if (overloadedPartitions.isEmpty) {
        Logger.debug(
          'No partitions need optimization, all partitions are balanced',
          label: 'SchemaManager.optimizePartitions',
        );
        return true;
      }

      // start optimization process
      final tablesMovedCount = <String>[];

      // handle overloaded partitions
      for (final overloadedIndex in overloadedPartitions) {
        if (underutilizedPartitions.isEmpty) break;

        // reload to get latest status
        final overloadedMeta = await _loadPartitionMeta(overloadedIndex);
        if (overloadedMeta == null) continue;

        final tablesToMove = <String>[];

        // select tables to move
        for (final tableName in overloadedMeta.tableNames) {
          final tableSize = overloadedMeta.tableSizes[tableName] ?? 0;
          if (tableSize > 0 &&
              tableSize < _dataStore.config.maxPartitionFileSize * 0.5) {
            tablesToMove.add(tableName);
            if (overloadedMeta.fileSizeInBytes - tableSize <= averageSize) {
              break;
            }
          }
        }

        // move tables to underutilized partitions
        for (final tableName in tablesToMove) {
          if (underutilizedPartitions.isEmpty) break;

          final tableSize = overloadedMeta.tableSizes[tableName] ?? 0;
          int targetPartition = -1;

          // find suitable target partition
          for (final underIndex in underutilizedPartitions) {
            final underMeta = partitionMetas[underIndex];
            if (underMeta != null &&
                underMeta.fileSizeInBytes + tableSize <=
                    _dataStore.config.maxPartitionFileSize) {
              targetPartition = underIndex;
              break;
            }
          }

          if (targetPartition == -1) continue;

          // get table schema
          final schema = overloadedMeta.tableSchemas[tableName];
          if (schema == null) continue;
          final fieldLayout = overloadedMeta.tableFieldLayouts[tableName];

          Logger.debug(
            'Moving table $tableName from partition $overloadedIndex to partition $targetPartition (size: $tableSize bytes)',
            label: 'SchemaManager.optimizePartitions',
          );

          // delete table from source partition
          final success =
              await _removeTableFromPartition(tableName, overloadedIndex);
          if (success) {
            // read target partition meta
            final targetDirIndex =
                await _getOrAllocateDirIndexForPartition(targetPartition);
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
                targetPartitionMeta = _createNewPartitionMeta(targetPartition);
              }
            } else {
              targetPartitionMeta = _createNewPartitionMeta(targetPartition);
            }

            // update target partition meta
            final updatedMeta = targetPartitionMeta.copyWith(
              fileSizeInBytes: targetPartitionMeta.fileSizeInBytes + tableSize,
              tableNames: [...targetPartitionMeta.tableNames, tableName],
              tableSizes: {
                ...targetPartitionMeta.tableSizes,
                tableName: tableSize,
              },
              tableSchemas: {
                ...targetPartitionMeta.tableSchemas,
                tableName: schema,
              },
              tableFieldLayouts: {
                ...targetPartitionMeta.tableFieldLayouts,
                if (fieldLayout != null) tableName: fieldLayout,
              },
              timestamps: Timestamps(
                created: targetPartitionMeta.timestamps.created,
                modified: DateTime.now(),
              ),
            );

            // save target partition file
            await _dataStore.storage
                .ensureDirectoryExists(dirname(targetPartitionPath));
            await _dataStore.storage.writeAsString(
                targetPartitionPath, jsonEncode(updatedMeta.toJson()));

            // update main meta mapping relation
            meta.tablePartitionMap[tableName] = targetPartition;

            tablesMovedCount.add(tableName);
          }

          // if target partition is full, remove from candidate list
          final updatedMeta = await _loadPartitionMeta(targetPartition);
          if (updatedMeta != null &&
              updatedMeta.fileSizeInBytes > averageSize) {
            underutilizedPartitions.remove(targetPartition);
          }
        }
      }

      // save updated meta
      await saveSchemaStructure();

      final duration = DateTime.now().difference(startTime);
      Logger.debug(
        'Partition optimization completed: moved ${tablesMovedCount.length} tables, time taken ${duration.inMilliseconds}ms',
        label: 'SchemaManager.optimizePartitions',
      );

      return true;
    } catch (e) {
      Logger.error(
        'Partition optimization failed: $e',
        label: 'SchemaManager.optimizePartitions',
      );
      return false;
    }
  }

  /// get all table schemas
  Future<List<dynamic>> getAllTableSchemas() async {
    try {
      // get all table names
      final meta = await getSchemaMeta();
      final tableNames = meta.tablePartitionMap.keys.toList();

      if (tableNames.isEmpty) return [];

      // read all table schemas
      final tableSchemas = <dynamic>[];

      // read all table schemas
      for (final tableName in tableNames) {
        final schema = await getTableSchema(tableName);
        if (schema != null) {
          tableSchemas.add(schema);
        }
      }

      return tableSchemas;
    } catch (e) {
      Logger.error(
        'Failed to get all table schemas: $e',
        label: 'SchemaManager.getAllTableSchemas',
      );
      return [];
    }
  }

  /// get table is global table
  Future<bool?> isTableGlobal(String tableName) async {
    final schema = await getTableSchema(tableName);
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

  /// High-performance check if user-defined table schema has changed (based on ToStore(schemas: []))
  Future<bool> isSchemaChanged(List<TableSchema> schemas) async {
    try {
      final meta = await getSchemaMeta();
      final oldHash = meta.userSchemaHash;

      return _hasSchemaChanged(
        schemas,
        oldHash,
      );
    } catch (e) {
      Logger.error(
        'Failed to judge table schema change: $e',
        label: 'SchemaManager.isSchemaChanged',
      );
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
      Logger.error(
        'Failed to judge system schema change: $e',
        label: 'SchemaManager.isSystemSchemaChanged',
      );
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
      Logger.error(
        'Failed to update user schema hash: $e',
        label: 'SchemaManager.updateUserSchemaHash',
      );
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
      Logger.error(
        'Failed to update system schema hash: $e',
        label: 'SchemaManager.updateSystemSchemaHash',
      );
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

  const _IndexListCacheEntry({
    required this.allIndexes,
    required this.uniqueIndexes,
    required this.vectorIndexes,
    required this.btreeIndexes,
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
    );
  }

  final unique = <IndexSchema>[];
  final vector = <IndexSchema>[];
  final btree = <IndexSchema>[];

  for (final idx in all) {
    if (idx.unique) {
      unique.add(idx);
    }
    if (idx.type == IndexType.vector) {
      vector.add(idx);
    } else {
      btree.add(idx);
    }
  }

  // Use unmodifiable views to guard against accidental mutation.
  return _IndexListCacheEntry(
    allIndexes: List<IndexSchema>.unmodifiable(all),
    uniqueIndexes: List<IndexSchema>.unmodifiable(unique),
    vectorIndexes: List<IndexSchema>.unmodifiable(vector),
    btreeIndexes: List<IndexSchema>.unmodifiable(btree),
  );
}
