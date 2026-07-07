import 'dart:async';

import '../handler/logger.dart';
import '../model/table_context.dart';
import '../model/table_statistics.dart';
import 'data_store_impl.dart';
import 'resource_manager.dart';

/// Central cache facade.
///
final class CacheManager {
  final DataStoreImpl _dataStore;

  // Lightweight stats cache
  final Map<String, TableStatistics> _statsCache = <String, TableStatistics>{};

  // Coalesced query-cache invalidation (generation bump in QueryExecutor).
  final Set<String> _pendingQueryInvalidations = <String>{};
  bool _queryInvalidationScheduled = false;

  CacheManager(this._dataStore) {
    _registerMemoryCallbacks();
  }

  void _registerMemoryCallbacks() {
    final mm = _dataStore.resourceManager;
    if (mm == null) return;

    // Table data (hot records + B+Tree pages)
    mm.registerCacheEvictionCallback(MemoryQuotaType.tableData, () async {
      try {
        // Evict record cache first
        await _dataStore.tableDataManager.evictTableRecordCache(ratio: 0.3);
      } catch (e) {
        Logger.warn('Evict hot record cache failed', rawError: e);
      }
      try {
        // Then evict page cache (B+Tree pages)
        await _dataStore.tableTreePartitionManager?.evictPageCache(ratio: 0.3);
      } catch (e) {
        Logger.warn('Evict page cache failed', rawError: e);
      }
    });

    // Index data (data cache + B+Tree pages + NGH vector pages)
    mm.registerCacheEvictionCallback(MemoryQuotaType.indexData, () async {
      try {
        // Evict B+Tree page cache
        await _dataStore.indexTreePartitionManager?.evictPageCache(ratio: 0.3);
      } catch (e) {
        Logger.warn('Evict index page cache failed', rawError: e);
      }
      try {
        // Evict NGH vector index caches
        await _dataStore.vectorIndexManager?.evictCache(ratio: 0.3);
      } catch (e) {
        Logger.warn('Evict vector index cache failed', rawError: e);
      }
    });

    // Query result cache (QueryExecutor + HotspotCache)
    mm.registerCacheEvictionCallback(MemoryQuotaType.queryResult, () async {
      try {
        await _dataStore.queryExecutor.evictQueryCache(ratio: 0.3);
      } catch (e) {
        Logger.warn('Evict query cache failed', rawError: e);
      }
    });

    // Schema cache (SchemaManager + HotspotCache)
    mm.registerCacheEvictionCallback(MemoryQuotaType.schema, () async {
      try {
        await _dataStore.schemaManager?.evictSchemaCache(ratio: 0.3);
      } catch (e) {
        Logger.warn('Evict schema cache failed', rawError: e);
      }
    });

    // Meta caches (table data meta + index meta)
    mm.registerCacheEvictionCallback(MemoryQuotaType.meta, () async {
      try {
        await _dataStore.tableDataManager.evictTableDataMetaCache(ratio: 0.3);
      } catch (e) {
        Logger.warn('Evict table data meta cache failed', rawError: e);
      }
      try {
        await _dataStore.indexManager?.evictIndexMetaCache(0.3);
      } catch (e) {
        Logger.warn('Evict index meta cache failed', rawError: e);
      }
    });
  }

  int getCurrentSchemaCacheSize() {
    return _dataStore.schemaManager?.getCurrentSchemaCacheSize() ?? 0;
  }

  int getCurrentTableDataCacheSize() {
    // Include both record cache and page cache (B+Tree pages)
    final recordCacheSize =
        _dataStore.tableDataManager.getCurrentTableRecordCacheSize();
    final pageCacheSize =
        _dataStore.tableTreePartitionManager?.getCurrentPageCacheSize() ?? 0;
    return recordCacheSize + pageCacheSize;
  }

  void _markQueryCacheDirty(TableContext table) {
    // Invalidate immediately for correctness (no stale window), but coalesce
    // repeated calls within the same microtask tick to avoid churn.
    final firstInTick = _pendingQueryInvalidations.add(table.tableUid);
    if (firstInTick) {
      try {
        _dataStore.queryExecutor.invalidateQueryCacheForTable(table);
      } catch (_) {}
    }

    if (_queryInvalidationScheduled) return;
    _queryInvalidationScheduled = true;
    scheduleMicrotask(() {
      _pendingQueryInvalidations.clear();
      _queryInvalidationScheduled = false;
    });
  }

  // -------------------- Statistics cache --------------------

  void cacheStatistics(TableContext table, TableStatistics stats) {
    _statsCache[table.tableUid] = stats;
  }

  TableStatistics? getStatistics(TableContext table) {
    return _statsCache[table.tableUid];
  }

  // -------------------- Space / lifecycle --------------------

  /// Clear in-memory caches synchronously (used on close).
  Future<void> dispose({bool includeSchema = true}) async {
    // Batch wait for multiple asynchronous tasks
    await Future.wait([
      _dataStore.schemaManager?.dispose() ?? Future.value(),
      _dataStore.tableDataManager.dispose(),
      _dataStore.indexManager?.dispose() ?? Future.value(),
      _dataStore.vectorIndexManager?.dispose() ?? Future.value(),
    ]);

    _dataStore.queryExecutor.clearAllQueryCacheSync();
    _dataStore.tableTreePartitionManager?.clearPageCacheSync();
    _dataStore.indexTreePartitionManager?.clearPageCacheSync();
    _dataStore.weightManager?.clearMemory();
    _dataStore.clearAllTtlPlanCache();
    _statsCache.clear();

    Logger.debug('Clear all cache');
  }

  /// Invalidate all caches of a table
  Future<void> invalidateCache(
    TableContext table, {
    bool invalidateSchema = true,
    bool invalidateQuery = true,
    bool invalidateRecords = true,
    bool invalidateRecordCount = true,
    bool invalidateTableDataMeta = true,
    bool invalidateTablePages = true,
    bool invalidateIndexData = true,
    bool invalidateIndexMeta = true,
    bool invalidateIndexPages = true,
    bool invalidateVectorCache = true,
    bool invalidateForeignKey = true,
    bool invalidateCompactionHints = true,
    bool removeTableState = false,
  }) async {
    final tableName = table.tableName;
    try {
      _statsCache.remove(table.tableUid);

      if (invalidateRecords) {
        await _dataStore.tableDataManager.clearTableRecordsForTable(table);
      } else if (invalidateRecordCount) {
        // Record count cache may need refresh even when hot records are kept.
        _dataStore.tableDataManager.removeRecordCountCache(table);
      }
      if (invalidateTableDataMeta) {
        _dataStore.tableDataManager.invalidateTableDataMetaCacheForTable(table);
      }
      if (invalidateTablePages) {
        _dataStore.tableTreePartitionManager?.clearPageCacheForTable(table);
      }
      if (invalidateSchema) {
        _dataStore.schemaManager?.removeCachedTableSchema(table.tableUid);
      }

      if (invalidateQuery) {
        _markQueryCacheDirty(table);
      }

      if (invalidateIndexData) {
        await _dataStore.indexManager?.removeFullIndexCacheForTable(table);
      }
      if (invalidateIndexMeta) {
        await _dataStore.indexManager?.removeIndexMetaCacheForTable(table);
      }
      if (invalidateIndexPages) {
        _dataStore.indexTreePartitionManager?.clearPageCacheForTable(table);
      }

      if (invalidateVectorCache) {
        _dataStore.vectorIndexManager?.clearCacheForTable(table.tableUid);
      }

      if (invalidateForeignKey) {
        _dataStore.foreignKeyManager?.invalidateCache();
      }

      if (invalidateCompactionHints) {
        _dataStore.compactionManager.clearHintsForTable(table);
      }

      _dataStore.weightManager?.clearWeightsForTable(table);

      if (removeTableState) {
        await _dataStore.tableDataManager.removeTable(table);
      }
    } catch (e) {
      Logger.error(
          'Invalidate table cache failed\n'
          'tableName: $tableName',
          rawError: e);
    }
  }

  int getCurrentQueryCacheSize() {
    return _dataStore.queryExecutor.getCurrentQueryCacheSizeBytes();
  }
}
