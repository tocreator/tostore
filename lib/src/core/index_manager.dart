import 'dart:async';

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../handler/parallel_processor.dart';
import '../handler/memcomparable.dart';
import '../handler/value_matcher.dart';
import '../model/data_block_entry.dart';
import '../model/index_search.dart';
import 'package:tostore/src/core/yield_controller.dart';

import '../handler/logger.dart';
import '../handler/common.dart';
import '../model/meta_info.dart';

import '../model/unique_violation.dart';
import '../model/parallel_journal_entry.dart';
import '../model/table_schema.dart';
import 'data_store_impl.dart';

import '../model/system_table.dart';
import 'table_data_manager.dart';
import '../model/id_generator.dart';
import 'tree_cache.dart';
import '../model/index_entry.dart';
import 'io_concurrency_planner.dart';
import 'transaction_context.dart';
import 'weight_manager.dart';

/// Index Manager
/// Responsible for index creation, update, deletion, and query operations
class IndexManager {
  final DataStoreImpl _dataStore;

  // Index Cache
  // - unique:     Key: [tableName, indexName, ...indexFields]      Value: PK (String)
  // - non-unique: Key: [tableName, indexName, ...indexFields, pk]  Value: true (bool marker)
  //
  // This avoids the old "bucket Set<PK>" read/modify/write amplification for non-unique indexes.
  late final TreeCache<dynamic> _indexDataCache;

  // Index Field Matchers: Map<"tableName:indexName", List<MatcherFunction>>
  // Stores ordered matchers for each indexed field to ensure correct TreeCache path comparison.
  final Map<String, List<MatcherFunction>> _indexFieldMatchers = {};

  // Index metadata cache using TreeCache
  late final TreeCache<IndexMeta> _indexMetaCache;

  // Loading futures to prevent thundering herd on concurrent meta loads
  final Map<String, Future<IndexMeta?>> _metaLoadingFutures = {};

  String _getMetaLoadingKey(String tableName, String indexName) =>
      '$tableName#$indexName';

  IndexManager(this._dataStore) {
    final memoryManager = _dataStore.memoryManager;
    final indexCacheSize = memoryManager?.getIndexCacheSize() ??
        100 * 1024 * 1024; // Default 100MB
    final metaCacheSize =
        memoryManager?.getMetaCacheSize() ?? 100 * 1024 * 1024; // Default 100MB
    final indexMetaCacheSize =
        (metaCacheSize * 0.25).toInt(); // 25% of meta cache

    // Initialize index data cache
    _indexDataCache = TreeCache<dynamic>(
      sizeCalculator: _estimateIndexDataSize,
      maxByteThreshold: (indexCacheSize * 0.70).toInt(),
      minByteThreshold: 150 * 1024 * 1024,
      groupDepth: 2,
      comparatorFactory: _indexComparatorFactory,
      weightQueryCallback: _queryIndexDataWeight,
      debugLabel: 'IndexDataCache',
    );

    _indexMetaCache = TreeCache<IndexMeta>(
      sizeCalculator: _estimateIndexMetaSize,
      maxByteThreshold: indexMetaCacheSize,
      minByteThreshold: 50 * 1024 * 1024,
      debugLabel: 'IndexMetaCache',
    );
  }

  /// Query weight for index data cache entry
  /// Path format: [tableName, indexName, ...indexFields]
  /// Weight object is the indexName (second element)
  Future<int?> _queryIndexDataWeight(List<dynamic> path) async {
    if (path.length < 2) return null;
    final tableName = path[0]?.toString();
    final indexName = path[1]?.toString();
    if (tableName == null ||
        tableName.isEmpty ||
        indexName == null ||
        indexName.isEmpty) {
      return null;
    }

    try {
      final weightManager = _dataStore.weightManager;
      if (weightManager == null) return null;

      // Use tableName:indexName as index identifier
      final indexKey = '$tableName:$indexName';
      return await weightManager.getWeight(
        WeightType.indexData,
        indexKey,
      );
    } catch (e) {
      Logger.warn(
        'Failed to query index data weight for $tableName:$indexName: $e',
        label: 'IndexManager._queryIndexDataWeight',
      );
      return null;
    }
  }

  /// Estimate size of index data cache entries
  int _estimateIndexDataSize(dynamic value) {
    if (value is String) return value.length; // Unique index PK
    if (value is bool) return 1; // Non-unique marker (PK is in key)
    return 8; // Fallback
  }

  /// Estimate index metadata size (bytes)
  int _estimateIndexMetaSize(IndexMeta meta) {
    // v2+ IndexMeta is fixed-shape (no partition list / directory mapping).
    return 220 +
        meta.name.length * 2 +
        meta.tableName.length * 2 +
        meta.fields.length * 20;
  }

  /// Evict index metadata cache
  Future<void> evictIndexMetaCache(double ratio) async {
    if (ratio <= 0 || ratio > 1) return;
    try {
      await _indexMetaCache.cleanup(removeRatio: ratio);
      Logger.info(
        'Evicted ${(ratio * 100).toStringAsFixed(0)}% index meta cache due to memory pressure',
        label: 'IndexManager.evictIndexMetaCache',
      );
    } catch (e) {
      Logger.error('Failed to evict index meta cache: $e',
          label: 'IndexManager.evictIndexMetaCache');
    }
  }

  /// Update full index cache based on record changes
  Future<void> updateIndexDataCache(String tableName, String pk,
      Map<String, dynamic>? oldData, Map<String, dynamic>? newData,
      {bool force = false}) async {
    try {
      final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
      if (schema == null) return;
      final indexes = schema.getAllIndexes();
      if (indexes.isEmpty) return;

      for (final index in indexes) {
        if (index.type == IndexType.vector) continue;
        final indexName = index.actualIndexName;

        // Ensure comparator is registered
        _registerIndexComparator(tableName, indexName, schema);

        // Remove old
        if (oldData != null) {
          final fields = <dynamic>[];
          bool success = true;
          for (final f in index.fields) {
            // Check existence first
            if (!oldData.containsKey(f)) {
              success = false;
              break;
            }
            // Use raw value
            fields.add(oldData[f]);
          }

          if (success) {
            final compositeKey = <dynamic>[
              tableName,
              indexName,
              ...fields,
            ]; // Raw Native Keys

            final dynamic removeKey =
                index.unique ? compositeKey : <dynamic>[...compositeKey, pk];
            if (_indexDataCache.containsKey(removeKey) ||
                force ||
                _dataStore.isGlobalPrewarming) {
              _indexDataCache.remove(removeKey);
            }
          }
        }

        // Add new
        if (newData != null) {
          final fields = <dynamic>[];
          bool success = true;
          for (final f in index.fields) {
            final v = newData[f];
            if (v == null) {
              success = false;
              break;
            }
            fields.add(v);
          }

          if (success) {
            final compositeKey = <dynamic>[tableName, indexName, ...fields];

            if (index.unique) {
              // Unique: key is index fields; value is PK.
              if (_indexDataCache.containsKey(compositeKey) ||
                  force ||
                  _dataStore.isGlobalPrewarming) {
                _indexDataCache.put(compositeKey, pk);
              }
            } else {
              // Non-unique: key includes PK; value is a bool marker.
              final fullKey = <dynamic>[...compositeKey, pk];
              if (_indexDataCache.containsKey(fullKey) ||
                  force ||
                  _dataStore.isGlobalPrewarming) {
                _indexDataCache.put(fullKey, true, size: pk.length + 1);
              }
            }
          }
        }
      }
    } catch (e) {
      Logger.warn('Failed to update index cache: $e',
          label: 'IndexManager.updateFullIndexCache');
    }
  }

  /// Factory to provide comparators for TreeCache based on path
  Comparator<dynamic> _indexComparatorFactory(List<dynamic> path) {
    // Path structure: [tableName, indexName, field1, field2, ..., pk]
    if (path.length < 2) return TreeCache.compareNative;

    final tableName = path.isNotEmpty ? path[0]?.toString() ?? '' : '';
    final indexName = path.length > 1 ? path[1]?.toString() ?? '' : '';
    final matchers = _indexFieldMatchers['$tableName:$indexName'];

    if (matchers != null) {
      // path.length == 2: We are at [tableName, indexName], next element to compare is field1
      // path.length == 3: Next is field2, etc.
      final fieldIndex = path.length - 2;
      if (fieldIndex < matchers.length) {
        final matcher = matchers[fieldIndex];
        return (a, b) => matcher(a, b);
      }
    }

    // Default: compareNative (strings, numbers, etc. using standard Dart comparison)
    // This is used for tableName, indexName, and trailing PKs in non-unique indexes.
    return TreeCache.compareNative;
  }

  /// Register field comparators for a specific index to ensure TreeCache works correctly.
  void _registerIndexComparator(
      String tableName, String indexName, TableSchema schema) {
    final key = '$tableName:$indexName';
    if (_indexFieldMatchers.containsKey(key)) return;

    final indexSchema = schema.indexes.firstWhere(
        (i) => i.actualIndexName == indexName,
        orElse: () => IndexSchema(indexName: '', fields: []));

    if (indexSchema.fields.isEmpty) return;

    final matchers = <MatcherFunction>[];
    for (final field in indexSchema.fields) {
      final mt = schema.getFieldMatcherType(field);
      matchers.add(ValueMatcher.getMatcher(mt));
    }
    _indexFieldMatchers[key] = matchers;
  }

  /// Get index metadata
  /// First tries to get from cache, if not found, loads from file and caches it
  Future<IndexMeta?> getIndexMeta(String tableName, String indexName) async {
    // Try to get from cache first
    final cached = _indexMetaCache.get([tableName, indexName]);
    if (cached != null) {
      return cached;
    }

    // Check for ongoing load
    final loadingKey = _getMetaLoadingKey(tableName, indexName);
    final existingFuture = _metaLoadingFutures[loadingKey];
    if (existingFuture != null) {
      return existingFuture;
    }

    // Load from disk with future tracking
    final loadFuture = _doLoadIndexMeta(tableName, indexName);
    _metaLoadingFutures[loadingKey] = loadFuture;

    try {
      return await loadFuture;
    } finally {
      // Clean up future after completion
      if (_metaLoadingFutures[loadingKey] == loadFuture) {
        _metaLoadingFutures.remove(loadingKey);
      }
    }
  }

  /// Internal method to perform the actual file load
  Future<IndexMeta?> _doLoadIndexMeta(
      String tableName, String indexName) async {
    try {
      // Cache miss, load from file
      final metaPath =
          await _dataStore.pathManager.getIndexMetaPath(tableName, indexName);
      if (!await _dataStore.storage.existsFile(metaPath)) {
        return null;
      }

      final content = await _dataStore.storage.readAsString(metaPath);
      if (content == null || content.isEmpty) {
        return null;
      }

      // Parse index metadata
      final json = jsonDecode(content);
      final meta = IndexMeta.fromJson(json);

      // Cache the loaded metadata
      _indexMetaCache.put([tableName, indexName], meta);

      return meta;
    } catch (e) {
      Logger.error('Failed to get index metadata: $e',
          label: 'IndexManager._doLoadIndexMeta');
      return null;
    }
  }

  /// Unified index metadata update method
  /// @param tableName Table name
  /// @param indexName Index name
  /// @param updatedMeta Updated metadata
  /// @param acquireLock Whether to acquire lock (default is true)
  /// @param flush Whether to immediately flush to disk (default is true)
  /// @return Updated index metadata
  Future<IndexMeta?> updateIndexMeta({
    required String tableName,
    required String indexName,
    IndexMeta? updatedMeta,
    bool acquireLock = true,
    bool flush = true,
  }) async {
    final meta = updatedMeta;
    if (meta == null) return null;

    // Create lock resource identifier
    final lockResource = 'index_meta:$tableName:$indexName';
    final operationId = GlobalIdGenerator.generate('update_meta_');

    bool lockAcquired = false;
    try {
      // Acquire lock (if needed)
      if (acquireLock) {
        lockAcquired = await (_dataStore.lockManager
                ?.acquireExclusiveLock(lockResource, operationId) ??
            false);
        if (!lockAcquired) {
          return null;
        }
      }

      // Update metadata file
      final metaPath =
          await _dataStore.pathManager.getIndexMetaPath(tableName, indexName);
      await _dataStore.storage
          .writeAsString(metaPath, jsonEncode(meta.toJson()), flush: flush);

      // Update cache after successful file write
      _indexMetaCache.put([tableName, indexName], meta);

      return meta;
    } catch (e, stack) {
      Logger.error('Failed to update index metadata: $e\n$stack',
          label: 'IndexManager.updateIndexMeta');
      return null;
    } finally {
      // Release lock (if acquired)
      if (acquireLock && lockAcquired) {
        _dataStore.lockManager?.releaseExclusiveLock(lockResource, operationId);
      }
    }
  }

  /// create index
  Future<void> createIndex(String tableName, IndexSchema schema) async {
    try {
      final indexName = schema.actualIndexName;

      // Check if the index exists
      final meta = await getIndexMeta(tableName, indexName);
      if (meta != null) {
        Logger.debug('Index already exists: $indexName',
            label: 'IndexManager.createIndex');
        return;
      }

      // Get table structure
      final tableSchema =
          await _dataStore.schemaManager?.getTableSchema(tableName);
      if (tableSchema == null) {
        return;
      }

      final primaryKeyName = tableSchema.primaryKey;
      // Check if a redundant primary key index is created
      if (schema.fields.length == 1 && schema.fields.first == primaryKeyName) {
        Logger.warn(
          'Skipping creation of redundant primary key index: $indexName, primary key "$primaryKeyName" is already range-partitioned in table data',
          label: 'IndexManager.createIndex',
        );
        return; // Skip creation of redundant primary key index
      }

      // Check if this index would duplicate an auto-created unique field index
      if (schema.fields.length == 1 && schema.unique) {
        final fieldName = schema.fields[0];
        final autoUniqueIndexName = 'uniq_$fieldName';

        // Check if the auto-created unique index exists
        final autoIndexMeta =
            await getIndexMeta(tableName, autoUniqueIndexName);

        if (autoIndexMeta != null && indexName != autoUniqueIndexName) {
          Logger.warn(
            'Detected redundant unique index creation: $indexName would duplicate the auto-created unique index "$autoUniqueIndexName". Removing auto-created index and proceeding with explicit index.',
            label: 'IndexManager.createIndex',
          );

          // Remove the auto-created unique index before creating the explicit one
          await removeIndex(tableName, indexName: autoUniqueIndexName);
        }
      }

      // Use optimized index building
      await _rebuildTableIndexes(tableName, tableSchema, [schema]);

      if (!SystemTable.isSystemTable(tableName)) {
        Logger.info('Created index for $tableName: $indexName',
            label: 'IndexManager.createIndex');
      }
    } catch (e, stack) {
      Logger.error('Failed to create index: $e\n$stack',
          label: 'IndexManager.createIndex');
      rethrow;
    }
  }

  /// Check if running in a WASM environment
  static bool get isWasmPlatform {
    try {
      // In Dart 3 with WASM support, you can detect WASM with this:
      return const bool.fromEnvironment('dart.library.wasm',
          defaultValue: false);
    } catch (e) {
      return false;
    }
  }

  /// reset all indexes
  Future<void> resetIndexes(String tableName) async {
    try {
      // Get table structure
      final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
      if (schema == null) {
        return;
      }

      // Clear index data
      final indexesToReset =
          schema.getAllIndexes().map((i) => i.actualIndexName).toList();

      // Clear index data from memory and files
      final yieldController = YieldController('IndexManager.resetIndexes');
      for (final indexName in indexesToReset) {
        // Remove from cache
        _indexMetaCache.remove([tableName, indexName]);
        _indexDataCache.remove([tableName, indexName]);

        // v2+ layout: delete entire index directory (fast & deterministic).
        await yieldController.maybeYield();
        try {
          final indexPath =
              await _dataStore.pathManager.getIndexPath(tableName, indexName);
          if (await _dataStore.storage.existsDirectory(indexPath)) {
            await _dataStore.storage.deleteDirectory(indexPath);
          }
        } catch (e) {
          Logger.warn('Failed to delete index directory for $indexName: $e',
              label: 'IndexManager.resetIndexes');
        }
      }

      // Collect all indexes to rebuild
      final indexesToBuild = schema.getAllIndexes();

      // Use optimized batch index building mechanism
      await _rebuildTableIndexes(tableName, schema, indexesToBuild);

      Logger.debug('Reset table indexes completed: $tableName',
          label: 'IndexManager.resetIndexes');
    } catch (e) {
      Logger.error('Failed to reset indexes: $e',
          label: 'IndexManager.resetIndexes');
      rethrow;
    }
  }

  /// Check unique constraints
  /// Returns UniqueViolation if a conflict is found, null otherwise
  Future<UniqueViolation?> checkUniqueConstraints(
      String tableName, Map<String, dynamic> data,
      {bool isUpdate = false,
      String? txId,
      TableSchema? schemaOverride}) async {
    try {
      final schema = schemaOverride ??
          await _dataStore.schemaManager?.getTableSchema(tableName);
      if (schema == null) {
        return null;
      }

      final primaryKey = schema.primaryKey;
      final primaryValue = data[primaryKey];

      // Prepare write buffer overlay for fast-path uniqueness in current batch
      final writeBuf = _dataStore.writeBufferManager;
      final String? currentTxId =
          txId ?? TransactionContext.getCurrentTransactionId();

      dynamic valueForFields(List<String> fields) {
        if (fields.isEmpty) return null;
        if (fields.length == 1) return data[fields.first];
        final values = <dynamic>[];
        for (final f in fields) {
          final v = data[f];
          if (v == null) return null;
          values.add(v);
        }
        return values;
      }

      // 1. Consolidate all unique constraints to check.
      final constraints = <_UniqueConstraint>[];

      // Primary key uniqueness (only for inserts).
      // New architecture: no standalone pk index; validate via table range partition directly.
      if (!isUpdate && primaryValue != null) {
        final pkStr = primaryValue.toString();
        // 0) Fast-path: check pending in-memory reservations (buffer overlay)
        try {
          final conflict = writeBuf.hasUniqueKeyOwnedByOther(
            tableName,
            'pk',
            pkStr,
            pkStr, // Self ID is the PK itself
            transactionId: currentTxId,
          );
          if (conflict) {
            Logger.warn(
              "[Unique Constraint Violation] Table '$tableName' Field(s) [$primaryKey] already contain value '$primaryValue'",
              label: 'IndexManager.checkUniqueConstraints',
            );
            return UniqueViolation(
              tableName: tableName,
              fields: [primaryKey],
              value: primaryValue,
              indexName: 'pk',
            );
          }
        } catch (_) {}

        // 1) Persisted check: use tree-partitioned table data.
        try {
          final exists = await _dataStore.tableTreePartitionManager
              .existsPrimaryKey(tableName, pkStr);
          if (exists) {
            Logger.warn(
              "[Unique Constraint Violation] Table '$tableName' Field(s) [$primaryKey] already contain value '$primaryValue'",
              label: 'IndexManager.checkUniqueConstraints',
            );
            return UniqueViolation(
              tableName: tableName,
              fields: [primaryKey],
              value: primaryValue,
              indexName: 'pk',
            );
          }
        } catch (e) {
          Logger.warn(
            'Primary key unique check failed for pk=$pkStr, error: $e',
            label: 'IndexManager.checkUniqueConstraints',
          );
          // Still treat as violation for safety, but with error info
          return UniqueViolation(
            tableName: tableName,
            fields: [primaryKey],
            value: primaryValue,
            indexName: 'pk',
          );
        }
      }

      // Add all unique indexes from schema (single and composite)
      for (final index in schema.getAllIndexes()) {
        if (!index.unique) continue;
        final v = valueForFields(index.fields);
        if (v == null) continue;

        // Increment index weight for uniqueness check
        _dataStore.weightManager?.incrementAccess(
          WeightType.indexData,
          '$tableName:${index.actualIndexName}',
          spaceName: _dataStore.currentSpaceName,
        );

        constraints.add(_UniqueConstraint(
          fields: index.fields,
          value: v,
          indexName: index.actualIndexName,
          canonicalKey: schema.createCanonicalIndexKey(index.fields, data),
        ));
      }

      if (constraints.isEmpty) {
        return null;
      }

      String? selfStoreIndexStr;
      if (isUpdate && primaryValue != null) {
        selfStoreIndexStr = primaryValue.toString();
      }

      // Helper to check buffer for conflicts
      UniqueViolation? checkInBuffer(_UniqueConstraint constraint,
          {bool transactionOnly = false}) {
        try {
          final compositeKey = constraint.canonicalKey;
          if (compositeKey != null) {
            final selfId = primaryValue?.toString();
            final bool conflict;
            if (transactionOnly) {
              conflict = writeBuf.hasUniqueKeyOwnedByOtherTransaction(
                tableName,
                constraint.indexName,
                compositeKey,
                selfId,
                transactionId: currentTxId,
              );
            } else {
              conflict = writeBuf.hasUniqueKeyOwnedByOther(
                tableName,
                constraint.indexName,
                compositeKey,
                selfId,
                transactionId: currentTxId,
              );
            }
            if (conflict) {
              Logger.warn(
                  "[Unique Constraint Violation] Table '$tableName' Field(s) [${constraint.fields.join(', ')}] already contain value '${constraint.value}' (buffer/reservation)",
                  label: 'IndexManager.checkUniqueConstraints');
              return UniqueViolation(
                tableName: tableName,
                fields: constraint.fields,
                value: constraint.value,
                indexName: constraint.indexName,
              );
            }
          }
        } catch (_) {}
        return null;
      }

      // 2. Separate checks into fast-path (in-memory/buffer) and slow-path (disk/index).
      final constraintsToCheckOnDisk = <_UniqueConstraint>[];

      for (final constraint in constraints) {
        // Fast-path: check pending in-memory unique keys first
        final violation = checkInBuffer(constraint);
        if (violation != null) return violation;

        // If passed fast path, queue for disk check
        constraintsToCheckOnDisk.add(constraint);
      }

      if (constraintsToCheckOnDisk.isEmpty) return null;

      // 3. Execute disk checks using existsUniqueKeysBatch (fast BinaryFuseFilter + grouped I/O)
      try {
        // Group constraints by index name for batch processing
        final constraintsByIndex = <String, List<_UniqueConstraint>>{};
        for (final constraint in constraintsToCheckOnDisk) {
          constraintsByIndex
              .putIfAbsent(constraint.indexName, () => [])
              .add(constraint);
        }

        // Check each index group
        for (final entry in constraintsByIndex.entries) {
          final indexName = entry.key;
          final indexConstraints = entry.value;

          // Get index metadata
          final meta = await getIndexMeta(tableName, indexName);
          if (meta == null || meta.totalEntries <= 0) {
            // Fallback: index not available, skip (conservative: no violation)
            continue;
          }

          // Encode all constraint values to MemComparable keys
          final keyBytes = <Uint8List>[];
          final constraintIndices = <int>[];
          for (int i = 0; i < indexConstraints.length; i++) {
            final constraint = indexConstraints[i];
            final comps = <Uint8List>[];
            bool ok = true;
            for (final f in constraint.fields) {
              final v = constraint.value;
              dynamic fieldVal;
              if (constraint.fields.length == 1) {
                fieldVal = v;
              } else if (v is List && v.length == constraint.fields.length) {
                fieldVal = v[constraint.fields.indexOf(f)];
              } else {
                ok = false;
                break;
              }
              final c = schema.encodeFieldComponentToMemComparable(
                f,
                fieldVal,
                truncateText: false,
              );
              if (c == null) {
                ok = false;
                break;
              }
              comps.add(c);
            }
            if (ok && comps.isNotEmpty) {
              keyBytes.add(MemComparableKey.encodeTuple(comps));
              constraintIndices.add(i);
            }
          }

          if (keyBytes.isEmpty) continue;

          // Batch check existence using BinaryFuseFilter + grouped I/O
          final exists =
              await _dataStore.indexTreePartitionManager.existsUniqueKeysBatch(
            tableName: tableName,
            indexName: indexName,
            meta: meta,
            uniqueKeys: keyBytes,
          );

          // Check results
          for (int j = 0; j < exists.length; j++) {
            if (!exists[j]) continue;
            final constraintIdx = constraintIndices[j];
            if (constraintIdx < 0 || constraintIdx >= indexConstraints.length) {
              continue;
            }
            final constraint = indexConstraints[constraintIdx];

            // For updates, we need to verify it's not the same record
            if (isUpdate && selfStoreIndexStr != null) {
              // Use lookupUniquePrimaryKey to get the actual PK owning this unique key.
              // If the PK matches the current record's PK, it's not a violation (self-update).
              try {
                final existingPk = await _dataStore.indexTreePartitionManager
                    .lookupUniquePrimaryKey(
                  tableName: tableName,
                  indexName: indexName,
                  meta: meta,
                  uniqueKey: keyBytes[j],
                );
                if (existingPk != null && existingPk == selfStoreIndexStr) {
                  // Same record, not a violation - skip this constraint
                  continue;
                }
              } catch (e) {
                Logger.warn(
                  'Failed to lookup unique PK for update check: $e',
                  label: 'IndexManager.checkUniqueConstraints',
                );
                // On error, conservatively treat as violation
              }
            }

            Logger.warn(
                "[Unique Constraint Violation] Table '$tableName' Field(s) [${constraint.fields.join(', ')}] already contain value '${constraint.value}' (disk check)",
                label: 'IndexManager.checkUniqueConstraints');
            return UniqueViolation(
              tableName: tableName,
              fields: constraint.fields,
              value: constraint.value,
              indexName: constraint.indexName,
            );
          }
        }
      } catch (e) {
        Logger.error('Batch unique constraint disk check failed: $e',
            label: 'IndexManager.checkUniqueConstraints');
        rethrow;
      }

      return null; // No violations found
    } catch (e, stack) {
      Logger.error('Failed to check unique constraints: $e\n$stack',
          label: 'IndexManager.checkUniqueConstraints');
      return UniqueViolation(
        tableName: tableName,
        fields: const [],
        value: null,
      );
    }
  }

  /// Batch unique check for INSERTs.
  ///
  /// Returns a list aligned with [records], where each entry is either null (no violation)
  /// or a [UniqueViolation] describing the first detected conflict for that record.
  Future<List<UniqueViolation?>> checkUniqueConstraintsBatchForInsert(
    String tableName,
    List<Map<String, dynamic>> records, {
    TableSchema? schemaOverride,
    String? transactionId,
  }) async {
    if (records.isEmpty) return const <UniqueViolation?>[];

    final yieldController =
        YieldController('IndexManager.checkUniqueConstraintsBatchForInsert');

    final schema = schemaOverride ??
        await _dataStore.schemaManager?.getTableSchema(tableName);
    if (schema == null) {
      return List<UniqueViolation?>.filled(records.length, null,
          growable: false);
    }

    final primaryKey = schema.primaryKey;
    final String? txId =
        transactionId ?? TransactionContext.getCurrentTransactionId();
    final writeBuf = _dataStore.writeBufferManager;
    final violations =
        List<UniqueViolation?>.filled(records.length, null, growable: false);

    // 1) Primary key uniqueness (only for custom PK inserts).
    if (schema.primaryKeyConfig.type == PrimaryKeyType.none) {
      final pkList = <String>[];
      for (int i = 0; i < records.length; i++) {
        final r = records[i];
        await yieldController.maybeYield();
        final pk = r[primaryKey]?.toString();
        if (pk != null && pk.isNotEmpty) {
          pkList.add(pk);
          final conflict = writeBuf.hasUniqueKeyOwnedByOther(
            tableName,
            'pk',
            pk,
            pk,
            transactionId: txId,
          );
          if (conflict) {
            violations[i] = UniqueViolation(
              tableName: tableName,
              fields: [primaryKey],
              value: pk,
              indexName: 'pk',
            );
          }
        }
      }

      if (pkList.isNotEmpty) {
        final existing =
            await _dataStore.tableTreePartitionManager.existingPrimaryKeysBatch(
          tableName,
          pkList,
        );

        if (existing.isNotEmpty) {
          for (int i = 0; i < records.length; i++) {
            await yieldController.maybeYield();
            if (violations[i] != null) continue;
            final pk = records[i][primaryKey]?.toString();
            if (pk == null || pk.isEmpty) continue;
            if (existing.contains(pk)) {
              violations[i] = UniqueViolation(
                tableName: tableName,
                fields: [primaryKey],
                value: pk,
                indexName: 'pk',
              );
            }
          }
        }
      }
    }

    // 2) Unique indexes
    final uniqueIndexes = schema
        .getAllIndexes()
        .where((i) => i.unique && i.type != IndexType.vector)
        .toList(growable: false);
    if (uniqueIndexes.isEmpty) return violations;

    for (final idx in uniqueIndexes) {
      // Increment index weight for uniqueness check
      _dataStore.weightManager?.incrementAccess(
        WeightType.indexData,
        '$tableName:${idx.actualIndexName}',
        spaceName: _dataStore.currentSpaceName,
      );

      final indexName = idx.actualIndexName;
      if (indexName.isEmpty) continue;

      // Skip records already known to violate earlier constraints.
      bool hasCandidate = false;
      for (int i = 0; i < records.length; i++) {
        if (violations[i] == null) {
          hasCandidate = true;
          break;
        }
      }
      if (!hasCandidate) break;

      for (int i = 0; i < records.length; i++) {
        await yieldController.maybeYield();
        if (violations[i] != null) continue;

        final r = records[i];
        final recordId = r[primaryKey]?.toString();
        if (recordId == null || recordId.isEmpty) continue;

        final canKey = schema.createCanonicalIndexKey(idx.fields, r);
        if (canKey == null) continue;

        final conflict = writeBuf.hasUniqueKeyOwnedByOther(
          tableName,
          indexName,
          canKey,
          recordId,
          transactionId: txId,
        );
        if (conflict) {
          violations[i] = UniqueViolation(
            tableName: tableName,
            fields: idx.fields,
            value: canKey,
            indexName: indexName,
          );
        }
      }

      // 2.2 Disk path using BinaryFuseFilter + grouped point lookups (existence-only).
      final meta = await getIndexMeta(tableName, indexName);
      if (meta == null || meta.totalEntries <= 0) {
        // Fallback: without meta we cannot safely batch-check this unique constraint.
        // Keep null -> caller may choose other strategies. For safety we conservatively
        // do nothing here (performance-first path).
        continue;
      }

      final recordIdxs = <int>[];
      final keyBytes = <Uint8List>[];

      for (int i = 0; i < records.length; i++) {
        await yieldController.maybeYield();
        if (violations[i] != null) continue;
        final r = records[i];

        final comps = <Uint8List>[];
        bool ok = true;
        for (final f in idx.fields) {
          final v = r[f];
          if (v == null) {
            ok = false;
            break;
          }
          final c = schema.encodeFieldComponentToMemComparable(
            f,
            v,
            truncateText: false,
          );
          if (c == null) {
            ok = false;
            break;
          }
          comps.add(c);
        }
        if (!ok || comps.isEmpty) continue;

        keyBytes.add(MemComparableKey.encodeTuple(comps));
        recordIdxs.add(i);
      }

      if (keyBytes.isEmpty) continue;

      final exists =
          await _dataStore.indexTreePartitionManager.existsUniqueKeysBatch(
        tableName: tableName,
        indexName: indexName,
        meta: meta,
        uniqueKeys: keyBytes,
      );

      for (int j = 0; j < exists.length; j++) {
        if (!exists[j]) continue;
        final i = recordIdxs[j];
        if (i < 0 || i >= violations.length) continue;
        if (violations[i] != null) continue;

        final r = records[i];
        final vals = idx.fields.map((f) => r[f]).toList(growable: false);
        violations[i] = UniqueViolation(
          tableName: tableName,
          fields: idx.fields,
          value: (idx.fields.length == 1) ? vals.first : vals,
          indexName: indexName,
        );
      }
    }

    return violations;
  }

  /// Add index to table
  Future<void> addIndex(
    String tableName,
    IndexSchema index,
  ) async {
    try {
      // get table schema
      final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
      if (schema == null) {
        Logger.error('Failed to add index: table $tableName does not exist',
            label: 'IndexManager.addIndex');
        return;
      }

      // check if index already exists
      if (schema
          .getAllIndexes()
          .any((i) => i.actualIndexName == index.actualIndexName)) {
        Logger.warn(
          'Index ${index.actualIndexName} already exists in table $tableName',
          label: 'IndexManager.addIndex',
        );
        return;
      }

      // validate index fields
      if (!schema.validateIndexFields(index)) {
        throw Exception('Index fields do not exist in table $tableName');
      }

      // create index file and build index
      await createIndex(tableName, index);

      // update table schema
      final newIndexes = [...schema.indexes, index];
      final newSchema = schema.copyWith(indexes: newIndexes);
      await _dataStore.schemaManager!.saveTableSchema(tableName, newSchema);
    } catch (e) {
      Logger.error('Failed to add index: $e', label: 'IndexManager.addIndex');
      rethrow;
    }
  }

  /// modify index
  Future<void> modifyIndex(
    String tableName,
    String oldIndexName,
    IndexSchema newIndex,
  ) async {
    try {
      // 1. remove old index
      await removeIndex(tableName, indexName: oldIndexName);

      // 2. create new index
      await addIndex(tableName, newIndex);
    } catch (e) {
      Logger.error('Failed to modify index: $e',
          label: 'IndexManager.modifyIndex');
      rethrow;
    }
  }

  /// remove index from table
  /// @param tableName table name
  /// @param indexName index name
  /// @param fields field list (when indexName is not provided)
  Future<void> removeIndex(
    String tableName, {
    String? indexName,
    List<String>? fields,
  }) async {
    try {
      if (indexName == null && (fields == null || fields.isEmpty)) {
        throw ArgumentError('index name or field list is required');
      }

      final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
      if (schema == null) {
        Logger.warn('table $tableName does not exist, cannot remove index',
            label: 'IndexManager.removeIndex');
        return;
      }

      // find matching index
      IndexSchema? targetIndex;

      // 1. if index name is provided, try to match by index name
      if (indexName != null) {
        // try to match by index name
        for (var index in schema.getAllIndexes()) {
          if (index.indexName == indexName ||
              index.actualIndexName == indexName) {
            targetIndex = index;
            break;
          }
        }

        // if not found, try to match by index name generated by fields
        if (targetIndex == null) {
          // check if it is an auto-generated index name
          final autoGenPattern = RegExp(r'^' + tableName + r'_\w+');
          if (autoGenPattern.hasMatch(indexName)) {
            for (var index in schema.getAllIndexes()) {
              if (index.actualIndexName == indexName) {
                targetIndex = index;
                break;
              }
            }
          }
        }
      }

      // 2. if fields list is provided, try to match by fields list
      if (targetIndex == null && fields != null && fields.isNotEmpty) {
        // sort fields list to ensure consistency
        final sortedFields = List<String>.from(fields)..sort();

        for (var index in schema.getAllIndexes()) {
          // sort index fields
          final indexFields = List<String>.from(index.fields)..sort();

          // check if fields list matches
          if (_areFieldListsEqual(indexFields, sortedFields)) {
            targetIndex = index;
            break;
          }
        }
      }

      String? actualName;

      // if target index is found
      if (targetIndex != null) {
        actualName = targetIndex.actualIndexName;
      } else if (indexName != null) {
        // if index name is provided but no matching index is found, try to delete index file
        Logger.warn(
          'index $indexName not found, try to delete index file',
          label: 'IndexManager.removeIndex',
        );
        actualName = indexName;
      } else {
        return;
      }

      // delete index file
      await _deleteIndexFiles(tableName, actualName);

      // if target index is found, remove it from table schema
      if (targetIndex != null) {
        final newIndexes =
            schema.indexes.where((i) => i != targetIndex).toList();
        final newSchema = schema.copyWith(indexes: newIndexes);

        // update table schema
        await _dataStore.schemaManager!.saveTableSchema(tableName, newSchema);
      }
    } catch (e) {
      Logger.error('Failed to remove index: $e',
          label: 'IndexManager.removeIndex');
      rethrow;
    }
  }

  /// delete index file
  /// @param tableName table name
  /// @param indexName index name
  Future<void> _deleteIndexFiles(
    String tableName,
    String indexName,
  ) async {
    // create lock resource for index operation
    final lockResource = 'index:$tableName:$indexName';
    final operationId = GlobalIdGenerator.generate('delete_index_');

    bool lockAcquired = false;
    try {
      // get exclusive lock, ensure no other operation is accessing this index
      lockAcquired = await (_dataStore.lockManager
              ?.acquireExclusiveLock(lockResource, operationId) ??
          false);
      if (!lockAcquired) {
        return;
      }

      // get index directory path
      final indexDirPath =
          await _dataStore.pathManager.getIndexDirPath(tableName);
      final indexSubDirPath = pathJoin(indexDirPath, indexName);

      // if index specific subdirectory exists, delete the entire subdirectory
      if (await _dataStore.storage.existsDirectory(indexSubDirPath)) {
        await _dataStore.storage.deleteDirectory(indexSubDirPath);
      }

      // delete meta file
      final metaPath =
          await _dataStore.pathManager.getIndexMetaPath(tableName, indexName);
      if (await _dataStore.storage.existsFile(metaPath)) {
        await _dataStore.storage.deleteFile(metaPath);
      }

      // Remove from cache
      _indexMetaCache.remove([tableName, indexName]);
      _indexDataCache.remove([tableName, indexName]);
    } catch (e) {
      Logger.error('Failed to delete index file: $e',
          label: 'IndexManager._deleteIndexFiles');
      rethrow;
    } finally {
      // release exclusive lock
      if (lockAcquired) {
        _dataStore.lockManager?.releaseExclusiveLock(lockResource, operationId);
      }
    }
  }

  /// compare two field lists (ignore order)
  bool _areFieldListsEqual(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    final setA = Set<String>.from(a);
    final setB = Set<String>.from(b);
    return setA.difference(setB).isEmpty;
  }

  /// Rebuild table indexes efficiently
  /// @param tableName Table name
  /// @param tableSchema Table schema
  /// @param rebuildPrimary Whether to rebuild primary key index
  /// @param indexesToBuild List of indexes to build
  Future<void> _rebuildTableIndexes(String tableName, TableSchema tableSchema,
      List<IndexSchema> indexesToBuild) async {
    try {
      final primaryKey = tableSchema.primaryKey;

      for (final indexSchema in indexesToBuild) {
        final indexName = indexSchema.actualIndexName;
        final indexMeta = IndexMeta.createEmpty(
          name: indexName,
          tableName: tableName,
          fields: indexSchema.fields,
          isUnique: indexSchema.unique,
        );
        await updateIndexMeta(
            tableName: tableName, indexName: indexName, updatedMeta: indexMeta);
      }

      // 2) Scan table partitions and build indexes via applyIndexInserts
      await _dataStore.tableDataManager.processTablePartitions(
        tableName: tableName,
        onlyRead: true,
        processFunction: (records, partitionIndex, controller) async {
          // Only write the entire partition at once, avoiding cutting the aligned partition data into multiple pieces and improving throughput.
          final Map<dynamic, Map<String, dynamic>> newByPk = {};
          final int maxConcurrency = _dataStore.config.maxConcurrency;
          final yieldControl =
              YieldController('IndexManager.processTablePartitions');

          for (int i = 0; i < records.length; i++) {
            await yieldControl.maybeYield();
            final rec = records[i];
            if (isDeletedRecord(rec)) continue;
            final pk = rec[primaryKey];
            if (pk == null) continue;
            newByPk[pk] = rec;
          }

          if (newByPk.isNotEmpty) {
            await _dataStore.indexManager?.writeChanges(
              tableName: tableName,
              inserts: newByPk.values.toList(growable: false),
              concurrency: maxConcurrency > 0 ? maxConcurrency : null,
            );
            await Future.delayed(Duration.zero);
          }
          return records;
        },
      );
    } catch (e, stack) {
      Logger.error('Failed to rebuild table indexes: $e\n$stack',
          label: 'IndexManager._rebuildTableIndexes');
      rethrow;
    }
  }

  /// Helper to encode index key from record
  Uint8List? encodeIndexKeyFromRecord({
    required TableSchema schema,
    required IndexMeta meta,
    required Map<String, dynamic> record,
    required String pkValue,
  }) {
    final fields = meta.fields;
    final isUnique = meta.isUnique;
    final truncateText = !isUnique;
    final comps = <Uint8List>[];
    for (final f in fields) {
      final v = record[f];
      final c = schema.encodeFieldComponentToMemComparable(
        f,
        v,
        truncateText: truncateText,
      );
      if (c == null) return null;
      comps.add(c);
    }
    if (!isUnique) {
      comps.add(schema.encodePrimaryKeyComponent(pkValue));
    }
    return MemComparableKey.encodeTuple(comps);
  }

  /// Write index changes (inserts, updates, deletes) to index partition files
  ///
  /// [skipIndexes] - Optional set of index names to skip processing.
  /// Used during recovery to skip indexes that have already been fully flushed.
  Future<void> writeChanges({
    required String tableName,
    List<Map<String, dynamic>> inserts = const [],
    List<IndexRecordUpdate> updates = const [],
    List<Map<String, dynamic>> deletes = const [],
    BatchContext? batchContext,
    int? concurrency,
    Uint8List? encryptionKey,
    int? encryptionKeyId,
    Set<String>? skipIndexes,
  }) async {
    // Snapshot inputs to allow yielding and avoid concurrent modification
    final insertsCopy = List<Map<String, dynamic>>.from(inserts);
    final updatesCopy = List<IndexRecordUpdate>.from(updates);
    final deletesCopy = List<Map<String, dynamic>>.from(deletes);
    final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
    if (schema == null) return;
    final pkName = schema.primaryKey;

    // Build index targets: explicit indexes + auto-unique single-field + foreign keys (excluding PK).
    final targets = schema.getAllIndexes().toList();

    // Skip redundant PK-only indexes (table data is already range-partitioned by PK).
    targets
        .removeWhere((i) => i.fields.length == 1 && i.fields.first == pkName);
    if (targets.isEmpty) return;

    // Compute per-index deltas.
    final idxTasks = <Future<void> Function()>[];
    final bool hasExplicitBudget = (concurrency != null && concurrency > 0);
    final IndexWriteBudget? budget = hasExplicitBudget
        ? IoConcurrencyPlanner.planIndexWriteBudget(
            budgetTokens: concurrency,
            indexCount: targets.length,
            // Non-unique indexes are far more likely to touch many partitions; avoid per-index=1.
            minPartitionTokensPerIndex: targets.any((i) => !i.unique) ? 2 : 1,
          )
        : null;

    for (final idx in targets) {
      final indexName = idx.actualIndexName;
      // Skip indexes that are already fully flushed (used during recovery)
      if (skipIndexes != null && skipIndexes.contains(indexName)) {
        continue;
      }
      idxTasks.add(() async {
        var meta = await getIndexMeta(tableName, indexName);
        // If index metadata doesn't exist, create it in memory only (avoid extra IO)
        if (meta == null) {
          meta = IndexMeta.createEmpty(
            name: indexName,
            tableName: tableName,
            fields: idx.fields,
            isUnique: idx.unique,
          );
          // Only cache in memory, don't write to file yet to avoid extra IO
          _indexMetaCache.put([tableName, indexName], meta);
        }

        final bool isUnique = meta.isUnique;
        final fields = meta.fields;

        Uint8List encodeUniquePutValue(String pk) {
          final b = utf8.encode(pk);
          final out = Uint8List(1 + b.length);
          out[0] = 0;
          out.setRange(1, out.length, b);
          return out;
        }

        Uint8List encodeNonUniquePutValue() => Uint8List.fromList(const [0]);

        Uint8List encodeDeleteValue() => Uint8List.fromList(const [1]);

        Uint8List? encodeIdxKey(
          Map<String, dynamic> record,
          String pkValue,
        ) =>
            encodeIndexKeyFromRecord(
                schema: schema, meta: meta!, record: record, pkValue: pkValue);

        final deltas = <DataBlockEntry>[];

        // Inserts - snapshot verified by caller? `inserts` is List<Map>
        // Assuming inserts/updates/deletes are safe to iterate directly if local
        final yieldControl = YieldController('IndexManager.writeChanges');

        for (final r in insertsCopy) {
          await yieldControl.maybeYield();
          final pk = r[pkName]?.toString();
          if (pk == null || pk.isEmpty) continue;
          final k = encodeIdxKey(r, pk);
          if (k == null || k.isEmpty) continue;
          final v =
              isUnique ? encodeUniquePutValue(pk) : encodeNonUniquePutValue();
          deltas.add(DataBlockEntry(k, v));
        }

        // Deletes (record holds old values)
        for (final r in deletesCopy) {
          await yieldControl.maybeYield();
          final pk = r[pkName]?.toString();
          if (pk == null || pk.isEmpty) continue;
          final k = encodeIdxKey(r, pk);
          if (k == null || k.isEmpty) continue;
          deltas.add(DataBlockEntry(k, encodeDeleteValue()));
        }

        // Updates
        for (final u in updatesCopy) {
          await yieldControl.maybeYield();
          final pk = u.primaryKey.toString();
          if (pk.isEmpty) continue;

          // Reconstruct old record by overlaying oldValues onto newValues.
          // This assumes missing keys in oldValues are unchanged.
          final oldValues = u.oldValues;
          if (oldValues == null) {
            // Strict mode: cannot safely maintain indexes without old values.
            throw StateError(
                'Index update requires oldValues for $tableName.$indexName (pk=$pk)');
          }

          final oldRecord = Map<String, dynamic>.from(u.newValues);
          oldRecord.addAll(oldValues);
          oldRecord[pkName] = pk;
          final newRecord = Map<String, dynamic>.from(u.newValues);
          newRecord[pkName] = pk;

          // If no indexed field changed, skip.
          try {
            if (!u.affectsIndexedFields(fields.toSet())) continue;
          } catch (_) {}

          final oldKey = encodeIdxKey(oldRecord, pk);
          final newKey = encodeIdxKey(newRecord, pk);

          if (oldKey != null &&
              newKey != null &&
              MemComparableKey.compare(oldKey, newKey) == 0) {
            continue;
          }
          if (oldKey != null && oldKey.isNotEmpty) {
            deltas.add(DataBlockEntry(oldKey, encodeDeleteValue()));
          }
          if (newKey != null && newKey.isNotEmpty) {
            final v =
                isUnique ? encodeUniquePutValue(pk) : encodeNonUniquePutValue();
            deltas.add(DataBlockEntry(newKey, v));
          }
        }

        if (deltas.isEmpty) {
          return;
        }
        await _dataStore.indexTreePartitionManager.writeChanges(
          tableName: tableName,
          indexName: indexName,
          indexMeta: meta,
          deltas: deltas,
          batchContext: batchContext,
          // If caller provided a total token budget, we pass a per-index token cap.
          // Otherwise, let partition manager auto-acquire based on actual touched partitions.
          concurrency:
              hasExplicitBudget ? budget!.partitionTokensPerIndex : null,
          encryptionKey: encryptionKey,
          encryptionKeyId: encryptionKeyId,
        );
      });
    }

    if (idxTasks.isEmpty) return;

    // Execute per-index tasks. If caller provides a token budget, we use a balanced
    // index-level concurrency to preserve partition-level parallelism.
    final int idxLevelConcurrency =
        hasExplicitBudget ? min(targets.length, budget!.indexConcurrency) : 1;

    // Calculate a dynamic timeout based on writeBatchSize AND maxPartitionFileSize.
    final int batchSize = _dataStore.config.writeBatchSize;
    final int maxFileSize = _dataStore.config.maxPartitionFileSize;

    final int batchSeconds = (batchSize / 50).ceil();
    final int ioSeconds = (maxFileSize / (100 * 1024)).ceil();

    final timeout = Duration(seconds: 30 + batchSeconds + ioSeconds);

    if (InternalConfig.showLoggerInternalLabel) {
      Logger.debug(
        'Index persistence: table=$tableName, totalIndexes=${idxTasks.length}, concurrency=$idxLevelConcurrency, timeout=$timeout',
        label: 'IndexManager',
      );
    }

    await ParallelProcessor.execute<void>(
      idxTasks,
      concurrency: idxLevelConcurrency,
      label: 'IndexManager.writeChanges',
      continueOnError: false,
      timeout: timeout,
    );
  }

  /// Searches an index using a structured condition, with optimizations for performance and memory.
  ///
  /// This method intelligently decides whether to load an entire index into memory
  /// or search it partition by partition based on the index size and query type.
  /// It supports equality and range queries with an optional limit to control result size.
  ///
  /// @param tableName The name of the table.
  /// @param indexName The name of the index to search.
  /// @param condition The structured IndexCondition for the search.
  /// @param limit An optional limit on the number of records to return.
  /// @param offset An optional offset to skip the first N records.
  /// @param startAfterKey Optional: keyset cursor (exclusive) for the index key bytes.
  /// @param reverse When true, scan in descending index-key order.
  /// @param orderBy An optional list of fields to order by.
  /// @param bypassCache When true, skip in-memory index caches (safer for large-range scans).
  /// @return An IndexSearchResult containing the pointers to matching records.
  Future<IndexSearchResult> searchIndex(
    String tableName,
    String indexName,
    IndexCondition condition, {
    int? limit,
    int? offset,
    Uint8List? startAfterKey,
    bool reverse = false,
    List<String>? orderBy,
  }) async {
    // Increment index access weight for caching optimization
    _dataStore.weightManager?.incrementAccess(
      WeightType.indexData,
      '$tableName:$indexName',
      spaceName: _dataStore.currentSpaceName,
    );
    try {
      final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
      if (schema == null) return IndexSearchResult.tableScan();

      // Ensure comparator is registered before cache access
      _registerIndexComparator(tableName, indexName, schema);

      final meta = await getIndexMeta(tableName, indexName);
      if (meta == null) return IndexSearchResult.tableScan();
      if (meta.totalEntries <= 0 || meta.btreeFirstLeaf.isNull) {
        return IndexSearchResult.empty();
      }

      Uint8List upperBoundExclusiveForPrefix(Uint8List prefix) {
        final out = Uint8List(prefix.length + 1 + 4);
        out.setRange(0, prefix.length, prefix);
        out[prefix.length] = 0xFF;
        return out;
      }

      final fields = meta.fields;
      final bool isUnique = meta.isUnique;
      final bool truncateText = !isUnique;

      List<dynamic>? normalizeValues(dynamic v, int n) {
        if (n <= 0) return const [];
        if (n == 1) return <dynamic>[v];
        if (v is List && v.length == n) return v;
        return null;
      }

      Uint8List? encodePrefix(dynamic raw) {
        final vals = normalizeValues(raw, fields.length);
        if (vals == null) return null;
        final comps = <Uint8List>[];
        for (int i = 0; i < fields.length; i++) {
          final c = schema.encodeFieldComponentToMemComparable(
            fields[i],
            vals[i],
            truncateText: truncateText,
          );
          if (c == null) return null;
          comps.add(c);
        }
        return MemComparableKey.encodeTuple(comps);
      }

      // Cursor Logic
      final bool hasCursorKey =
          startAfterKey != null && startAfterKey.isNotEmpty;

      // Local helper for nextKey (exclusive -> inclusive switch)
      Uint8List nextKey(Uint8List key) {
        final out = Uint8List(key.length + 1);
        out.setAll(0, key);
        out[key.length] = 0;
        return out;
      }

      final int? effectiveOffset = hasCursorKey ? null : offset;

      // Helper to apply cursor lower bound (Forward scan start)
      Uint8List applyCursorStart(Uint8List originalStart) {
        if (!hasCursorKey) return originalStart;
        if (reverse) return originalStart; // Reverse uses cursor as end bound

        // We want strictly AFTER cursor.
        // startInclusive = nextKey(cursor).
        // If cursor >= originalStart, we need to bump originalStart to cursor+1.
        final cursorNext = nextKey(startAfterKey);
        if (originalStart.isEmpty ||
            MemComparableKey.compare(cursorNext, originalStart) > 0) {
          return cursorNext;
        }
        return originalStart;
      }

      // Helper to apply cursor upper bound (Reverse scan end)
      Uint8List applyCursorEnd(Uint8List originalEnd) {
        if (!hasCursorKey) return originalEnd;
        if (!reverse) return originalEnd; // Forward uses cursor as start bound

        // Reverse scan: scan < limit.
        // We want strictly BEFORE cursor.
        // Limit (exclusive) = cursor.
        if (originalEnd.isEmpty ||
            MemComparableKey.compare(startAfterKey, originalEnd) < 0) {
          return startAfterKey;
        }
        return originalEnd;
      }

      final opUpper = condition.operator.toUpperCase();

      // Cache Check Helper
      // Returns null if cache not available or not applicable
      // Returns IndexSearchResult if cache used (empty or populated)
      Future<IndexSearchResult?> checkCache(
          dynamic prefix, dynamic start, dynamic end) async {
        // Equality/Point Lookup
        if (prefix != null && start == null && end == null) {
          if (hasCursorKey && isUnique) {
            return IndexSearchResult.empty();
          }

          final List<dynamic> comps = prefix is List ? prefix : [prefix];
          final compositePrefix = <dynamic>[tableName, indexName, ...comps];

          if (isUnique) {
            final val = _indexDataCache.get(compositePrefix);
            if (val == null) {
              return null;
            }
            if (val is String) {
              return IndexSearchResult(primaryKeys: [val]);
            }
            return IndexSearchResult.empty();
          }
        }

        return null;
      }

      // Equality
      if (opUpper == '=') {
        final List<dynamic>? nativeVal =
            normalizeValues(condition.value, fields.length);
        if (nativeVal == null) return IndexSearchResult.empty();

        // Check Cache with Native Key
        // Equality Cache Optimization:
        final cacheResult = await checkCache(nativeVal, null, null);

        if (cacheResult != null) {
          if (!hasCursorKey) {
            return cacheResult;
          }
          // Cache Hit with Cursor: Filter in-memory
          if (isUnique) {
            // Unique index result is a single PK.
          } else {
            final List<String> cachedPks = cacheResult.primaryKeys;

            final List<String> pks = List.of(cachedPks);
            // Sort PKs naturally (lexicographical for strings/encoded)
            pks.sort();
            if (reverse) {
              pks.sort((a, b) => b.compareTo(a));
            }

            final out = <String>[];
            final localPrefix = encodePrefix(condition.value);

            if (localPrefix != null) {
              for (final pk in pks) {
                final encodedRecordKey = schema.encodePrimaryKeyComponent(pk);
                final fullKey =
                    Uint8List(localPrefix.length + encodedRecordKey.length);
                fullKey.setAll(0, localPrefix);
                fullKey.setAll(localPrefix.length, encodedRecordKey);

                // Comparison
                bool include = false;
                if (reverse) {
                  // strictly BEFORE cursor
                  if (MemComparableKey.compare(fullKey, startAfterKey) < 0) {
                    include = true;
                  }
                } else {
                  // strictly AFTER cursor
                  if (MemComparableKey.compare(fullKey, startAfterKey) > 0) {
                    include = true;
                  }
                }
                if (include) out.add(pk);
              }
              return IndexSearchResult(primaryKeys: out);
            }
          }
        }
        final prefix = encodePrefix(condition.value);
        if (prefix == null) return IndexSearchResult.empty();

        if (isUnique) {
          if (hasCursorKey) return IndexSearchResult.empty();
          final pk =
              await _dataStore.indexTreePartitionManager.lookupUniquePrimaryKey(
            tableName: tableName,
            indexName: indexName,
            meta: meta,
            uniqueKey: prefix,
          );
          if (pk == null) return IndexSearchResult.empty();

          // Hotspot populate: Use Native Key (if not disabled)
          if (!(_dataStore.memoryManager?.isLowMemoryMode ?? false)) {
            _indexDataCache.put([tableName, indexName, ...nativeVal], pk);
          }

          return IndexSearchResult(primaryKeys: <String>[pk]);
        }

        final end = upperBoundExclusiveForPrefix(prefix);
        final start = applyCursorStart(prefix);
        final endEffective = applyCursorEnd(end);

        if (endEffective.isNotEmpty &&
            MemComparableKey.compare(start, endEffective) >= 0) {
          return IndexSearchResult.empty();
        }
        final res = await _dataStore.indexTreePartitionManager.searchByKeyRange(
          tableName: tableName,
          indexName: indexName,
          meta: meta,
          startKeyInclusive: start,
          endKeyExclusive: endEffective,
          reverse: reverse,
          limit: limit,
          offset: effectiveOffset,
        );

        if (!isUnique && limit == null && offset == null && !hasCursorKey) {
          // Hotspot populate (non-unique): cache one entry per PK.
          if (!(_dataStore.memoryManager?.isLowMemoryMode ?? false)) {
            final prefixKey = <dynamic>[tableName, indexName, ...nativeVal];
            final yc = YieldController('IndexManager.hotspotPopulateNonUnique');
            for (final pk in res.primaryKeys) {
              await yc.maybeYield();
              _indexDataCache.put(
                <dynamic>[...prefixKey, pk],
                true,
                size: pk.length + 1,
              );
            }
          }
        }
        return res;
      }

      // BETWEEN (inclusive).
      if (opUpper == 'BETWEEN') {
        final startPrefix = encodePrefix(condition.value);
        final endPrefix = encodePrefix(condition.endValue);
        if (startPrefix == null || endPrefix == null) {
          return IndexSearchResult.empty();
        }
        final endExclusive = upperBoundExclusiveForPrefix(endPrefix);
        final start = applyCursorStart(startPrefix);
        final endEffective = applyCursorEnd(endExclusive);

        if (endEffective.isNotEmpty &&
            MemComparableKey.compare(start, endEffective) >= 0) {
          return IndexSearchResult.empty();
        }
        return _dataStore.indexTreePartitionManager.searchByKeyRange(
          tableName: tableName,
          indexName: indexName,
          meta: meta,
          startKeyInclusive: start,
          endKeyExclusive: endEffective,
          reverse: reverse,
          limit: limit,
          offset: effectiveOffset,
        );
      }

      // Range comparisons
      if (opUpper == '>' ||
          opUpper == '>=' ||
          opUpper == '<' ||
          opUpper == '<=') {
        // Similar to BETWEEN, skip native cache for complex open ranges for now.
        // Focus on removing explicit MemComparableKey usages.
        final prefix = encodePrefix(condition.value);
        if (prefix == null) return IndexSearchResult.empty();

        Uint8List startBound, endBound;
        bool isLower = (opUpper == '>' || opUpper == '>=');

        if (isLower) {
          startBound =
              (opUpper == '>') ? upperBoundExclusiveForPrefix(prefix) : prefix;
          endBound = Uint8List(0);
        } else {
          startBound = Uint8List(0);
          endBound =
              (opUpper == '<=') ? upperBoundExclusiveForPrefix(prefix) : prefix;
        }

        // Apply cursors
        final start = applyCursorStart(startBound);
        final endEffective = applyCursorEnd(endBound);

        if (endEffective.isNotEmpty &&
            MemComparableKey.compare(start, endEffective) >= 0) {
          return IndexSearchResult.empty();
        }

        return _dataStore.indexTreePartitionManager.searchByKeyRange(
          tableName: tableName,
          indexName: indexName,
          meta: meta,
          startKeyInclusive: start,
          endKeyExclusive: endEffective,
          reverse: reverse,
          limit: limit,
          offset: effectiveOffset,
        );
      }

      // Full Index Scan (SCAN)
      if (opUpper == 'SCAN') {
        final start = applyCursorStart(Uint8List(0));
        final end = applyCursorEnd(Uint8List(0));

        if (end.isNotEmpty && MemComparableKey.compare(start, end) >= 0) {
          return IndexSearchResult.empty();
        }

        return await _dataStore.indexTreePartitionManager.searchByKeyRange(
          tableName: tableName,
          indexName: indexName,
          meta: meta,
          startKeyInclusive: start,
          endKeyExclusive: end,
          reverse: reverse,
          limit: limit,
          offset: effectiveOffset,
        );
      }

      if (opUpper == 'LIKE' && condition.value is String) {
        final pattern = condition.value as String;

        // Find the effective prefix (stop at first wildcard)
        int wildcardIndex = -1;
        final firstPercent = pattern.indexOf('%');
        final firstUnderscore = pattern.indexOf('_');

        if (firstPercent != -1 && firstUnderscore != -1) {
          wildcardIndex = min(firstPercent, firstUnderscore);
        } else if (firstPercent != -1) {
          wildcardIndex = firstPercent;
        } else {
          wildcardIndex = firstUnderscore;
        }

        // If there is ANY valid prefix before the wildcard, we can use it for range scan
        if (wildcardIndex > 0 || (wildcardIndex == -1 && pattern.isNotEmpty)) {
          final prefix = (wildcardIndex != -1)
              ? pattern.substring(0, wildcardIndex)
              : pattern;

          // Helper to increment the last character of a string to find upper bound
          String? incrementString(String s) {
            if (s.isEmpty) return null;
            final codeUnits = List<int>.from(s.codeUnits);
            for (int i = codeUnits.length - 1; i >= 0; i--) {
              if (codeUnits[i] < 0xFFFF) {
                codeUnits[i]++;
                return String.fromCharCodes(codeUnits);
              }
              codeUnits.removeLast();
            }
            return null;
          }

          final startBytes = encodePrefix(prefix);

          Uint8List? endBytes;
          if (prefix.isNotEmpty) {
            final nextPrefix = incrementString(prefix);
            if (nextPrefix != null) {
              endBytes = encodePrefix(nextPrefix);
            }
          }

          if (startBytes != null) {
            final start = applyCursorStart(startBytes);
            // If endBytes is null (meaning prefix empty or overflow), use empty (unbounded)
            final end = applyCursorEnd(endBytes ?? Uint8List(0));

            // Valid range check
            if (end.isNotEmpty && MemComparableKey.compare(start, end) >= 0) {
              return IndexSearchResult.empty();
            }

            return await _dataStore.indexTreePartitionManager.searchByKeyRange(
              tableName: tableName,
              indexName: indexName,
              meta: meta,
              startKeyInclusive: start,
              endKeyExclusive: end,
              reverse: reverse,
              limit: limit,
              offset: effectiveOffset,
            );
          }
        }
        return IndexSearchResult.tableScan();
      }

      if (opUpper == 'IN' && condition.value is List) {
        // Prepare (value, prefix) pairs
        final items = <(dynamic, Uint8List)>[];
        for (final v in (condition.value as List)) {
          final prefix = encodePrefix(v);
          if (prefix != null) {
            items.add((v, prefix));
          }
        }

        // Sort based on index order (forward or reverse)
        // This ensures meaningful cursor traversal across the IN-list buckets.
        items.sort((a, b) {
          final cmp = MemComparableKey.compare(a.$2, b.$2);
          return reverse ? -cmp : cmp;
        });

        // Unique values only (consecutive)
        if (items.isNotEmpty) {
          final uniqueItems = <(dynamic, Uint8List)>[];
          for (int i = 0; i < items.length; i++) {
            if (i == 0 ||
                MemComparableKey.compare(items[i].$2, items[i - 1].$2) != 0) {
              uniqueItems.add(items[i]);
            }
          }
          items.clear();
          items.addAll(uniqueItems);
        }

        final out = <String>[];
        final int need = (limit == null) ? -1 : max(0, limit);
        int remaining = need;
        final yieldController = YieldController('index_search_in');

        for (final item in items) {
          final v = item.$1;
          final prefix = item.$2;

          await yieldController.maybeYield();
          if (remaining == 0) break;

          final endBound = upperBoundExclusiveForPrefix(prefix);
          final start = applyCursorStart(prefix);
          final end = applyCursorEnd(endBound);

          // If range is invalid (fully behind cursor), skip
          if (end.isNotEmpty && MemComparableKey.compare(start, end) >= 0) {
            continue;
          }

          final List<dynamic>? nativeVal = normalizeValues(v, fields.length);
          bool usedCache = false;

          // Try Cache with Native Key (ONLY if full bucket scan is requested)
          // i.e., start == prefix AND end == endBound (no cursor slicing in this bucket)
          if (nativeVal != null &&
              MemComparableKey.compare(start, prefix) == 0 &&
              MemComparableKey.compare(end, endBound) == 0) {
            final cacheRes = await checkCache(nativeVal, null, null);
            if (cacheRes != null) {
              out.addAll(cacheRes.primaryKeys);
              usedCache = true;
            }
          }

          if (!usedCache) {
            if (isUnique) {
              // For unique index, if cursor > prefix, 'start' will be > 'prefix', so we skip.
              if (MemComparableKey.compare(start, prefix) > 0) continue;

              final pk = await _dataStore.indexTreePartitionManager
                  .lookupUniquePrimaryKey(
                tableName: tableName,
                indexName: indexName,
                meta: meta,
                uniqueKey: prefix,
              );
              if (pk != null) {
                out.add(pk);
                if (nativeVal != null) {
                  final compositeKey = [tableName, indexName, ...nativeVal];
                  _indexDataCache.put(compositeKey, pk);
                }
              }
            } else {
              // Range Scan
              final res =
                  await _dataStore.indexTreePartitionManager.searchByKeyRange(
                tableName: tableName,
                indexName: indexName,
                meta: meta,
                startKeyInclusive: start,
                endKeyExclusive: end,
                reverse: reverse,
                limit: remaining > 0 ? remaining : null,
                offset: null, // Offset is handled globally for IN
              );

              // Hotspot populate: Populate cache if we did a full bucket scan (no cursor)
              if (!usedCache &&
                  nativeVal != null &&
                  !hasCursorKey &&
                  !(_dataStore.memoryManager?.isLowMemoryMode ?? false)) {
                if (isUnique) {
                  if (res.primaryKeys.isNotEmpty) {
                    _indexDataCache.put([tableName, indexName, ...nativeVal],
                        res.primaryKeys.first);
                  }
                } else {
                  final prefixKey = <dynamic>[
                    tableName,
                    indexName,
                    ...nativeVal
                  ];
                  final yc = YieldController(
                      'IndexManager.hotspotPopulateNonUniqueIn');
                  for (final pk in res.primaryKeys) {
                    await yc.maybeYield();
                    _indexDataCache.put(
                      <dynamic>[...prefixKey, pk],
                      true,
                      size: pk.length + 1,
                    );
                  }
                }
              }

              out.addAll(res.primaryKeys);
              if (remaining > 0) {
                remaining -= res.primaryKeys.length;
                if (remaining <= 0) break;
              }
            }
          }

          if (remaining > 0) {
            remaining = max(0, need - out.length);
          }
        }

        // Final Filter
        List<String> finalPks = out;
        if (effectiveOffset != null && effectiveOffset > 0) {
          if (effectiveOffset >= finalPks.length) {
            return IndexSearchResult.empty();
          }
          finalPks = finalPks.sublist(effectiveOffset);
        }
        if (limit != null && finalPks.length > limit) {
          finalPks = finalPks.sublist(0, limit);
        }

        if (finalPks.isEmpty) return IndexSearchResult.empty();
        return IndexSearchResult(primaryKeys: finalPks);
      }

      // LIKE / != / others: fallback to table scan for correctness.
      return IndexSearchResult.tableScan();
    } catch (e, s) {
      Logger.error('searchIndex failed: $e\n$s',
          label: 'IndexManager.searchIndex');
      return IndexSearchResult.tableScan();
    }
  }

  /// Get current index data cache size in bytes (Data Partition + Range Partition Data + B+Tree pages)
  Future<int> getCurrentIndexDataCacheSize() async {
    // Include both data cache and page cache (B+Tree pages)
    final dataCacheSize = _indexDataCache.estimatedTotalSizeBytes;
    final pageCacheSize =
        _dataStore.indexTreePartitionManager.getCurrentPageCacheSize();
    return dataCacheSize + pageCacheSize;
  }

  /// Get current index metadata cache size in bytes (Schema/Directories)
  Future<int> getCurrentIndexMetaCacheSize() async {
    return _indexMetaCache.estimatedTotalSizeBytes;
  }

  /// Get TOTAL index cache size (Data + Meta)
  Future<int> getCurrentIndexCacheSize() async {
    return (await getCurrentIndexMetaCacheSize()) +
        (await getCurrentIndexDataCacheSize());
  }

  /// Remove full index cache for a specific table
  Future<void> removeFullIndexCacheForTable(String tableName) async {
    _indexDataCache.remove([tableName]);
  }

  /// Remove index meta cache for table
  Future<void> removeIndexMetaCacheForTable(String tableName) async {
    if (tableName.isEmpty) return;

    // Remove from TreeCache using hierarchical prefix
    _indexMetaCache.remove([tableName]);
  }

  /// Clear all index metadata cache
  Future<void> clearIndexMetaCache() async {
    _indexMetaCache.clear();
  }
}

class _UniqueConstraint {
  final List<String> fields;
  final dynamic value;
  final String indexName;
  // fast-path canonical key for write buffer check (raw value or List)
  final dynamic canonicalKey;

  _UniqueConstraint({
    required this.fields,
    required this.value,
    required this.indexName,
    this.canonicalKey,
  });
}
