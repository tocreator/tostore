import 'dart:async';

import '../handler/logger.dart';
import '../model/table_statistics.dart';
import 'data_store_impl.dart';
import 'memory_manager.dart';

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
    final mm = _dataStore.memoryManager;
    if (mm == null) return;

    // Table data (hot records + B+Tree pages)
    mm.registerCacheEvictionCallback(MemoryQuotaType.tableData, () async {
      try {
        // Evict record cache first
        await _dataStore.tableDataManager.evictTableRecordCache(ratio: 0.3);
      } catch (e) {
        Logger.warn('Evict hot record cache failed: $e',
            label: 'CacheManager.tableData');
      }
      try {
        // Then evict page cache (B+Tree pages)
        await _dataStore.tableTreePartitionManager.evictPageCache(ratio: 0.3);
      } catch (e) {
        Logger.warn('Evict page cache failed: $e',
            label: 'CacheManager.tableData');
      }
    });

    // Index data (data cache + B+Tree pages)
    mm.registerCacheEvictionCallback(MemoryQuotaType.indexData, () async {
      try {
        // Then evict page cache (B+Tree pages)
        await _dataStore.indexTreePartitionManager.evictPageCache(ratio: 0.3);
      } catch (e) {
        Logger.warn('Evict index page cache failed: $e',
            label: 'CacheManager.indexData');
      }
    });

    // Query result cache (QueryExecutor + HotspotCache)
    mm.registerCacheEvictionCallback(MemoryQuotaType.queryResult, () async {
      try {
        await _dataStore.queryExecutor.evictQueryCache(ratio: 0.3);
      } catch (e) {
        Logger.warn('Evict query cache failed: $e',
            label: 'CacheManager.queryResult');
      }
    });

    // Schema cache (SchemaManager + HotspotCache)
    mm.registerCacheEvictionCallback(MemoryQuotaType.schema, () async {
      try {
        await _dataStore.schemaManager?.evictSchemaCache(ratio: 0.3);
      } catch (e) {
        Logger.warn('Evict schema cache failed: $e',
            label: 'CacheManager.schema');
      }
    });

    // Meta caches (table meta + index meta)
    mm.registerCacheEvictionCallback(MemoryQuotaType.meta, () async {
      try {
        await _dataStore.tableDataManager.evictTableMetaCache(ratio: 0.3);
      } catch (e) {
        Logger.warn('Evict table meta cache failed: $e',
            label: 'CacheManager.meta');
      }
      try {
        await _dataStore.indexManager?.evictIndexMetaCache(0.3);
      } catch (e) {
        Logger.warn('Evict index meta cache failed: $e',
            label: 'CacheManager.meta');
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
        _dataStore.tableTreePartitionManager.getCurrentPageCacheSize();
    return recordCacheSize + pageCacheSize;
  }

  void _markQueryCacheDirty(String tableName) {
    // Invalidate immediately for correctness (no stale window), but coalesce
    // repeated calls within the same microtask tick to avoid churn.
    final firstInTick = _pendingQueryInvalidations.add(tableName);
    if (firstInTick) {
      try {
        _dataStore.queryExecutor.invalidateQueryCacheForTable(tableName);
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

  void cacheStatistics(String tableName, TableStatistics stats) {
    _statsCache[tableName] = stats;
  }

  TableStatistics? getStatistics(String tableName) {
    return _statsCache[tableName];
  }

  // -------------------- Space / lifecycle --------------------

  /// Clear in-memory caches synchronously (used on close).
  void clear() {
    _statsCache.clear();

    try {
      _dataStore.queryExecutor.clearAllQueryCacheSync();
    } catch (_) {}

    try {
      _dataStore.tableDataManager.clearAllTableRecordCacheSync();
    } catch (_) {}

    try {
      _dataStore.tableDataManager.clearTableMetaCacheSync();
    } catch (_) {}

    try {
      _dataStore.tableTreePartitionManager.clearPageCacheSync();
    } catch (_) {}

    try {
      _dataStore.indexTreePartitionManager.clearPageCacheSync();
    } catch (_) {}

    try {
      _dataStore.schemaManager?.clearSchemaCacheSync();
    } catch (_) {}

    try {
      _dataStore.weightManager?.clearMemory();
    } catch (_) {}

    // Fire-and-forget async clears.
    Future(() async {
      try {
        await _dataStore.indexManager?.clearIndexMetaCache();
      } catch (_) {}
    });

    Logger.debug('Clear all cache', label: 'CacheManager.clear');
  }

  /// Handle base path / space change.
  Future<void> onBasePathChanged() async {
    try {
      _statsCache.clear();

      await _dataStore.queryExecutor.clearAllQueryCache();
      await _dataStore.tableDataManager.clearAllTableRecordCache();
      await _dataStore.tableDataManager.clearTableMetaCache();
      _dataStore.tableTreePartitionManager.clearPageCacheSync();
      _dataStore.indexTreePartitionManager.clearPageCacheSync();
      await _dataStore.schemaManager?.clearSchemaCache();
      await _dataStore.indexManager?.clearIndexMetaCache();
      _dataStore.weightManager?.clearMemory();

      Logger.debug('Base path change completed, caches cleared',
          label: 'CacheManager.onBasePathChanged');
    } catch (e) {
      Logger.error('Base path change handling failed: $e',
          label: 'CacheManager.onBasePathChanged');
      rethrow;
    }
  }

  /// Invalidate all caches of a table
  Future<void> invalidateCache(String tableName) async {
    try {
      _statsCache.remove(tableName);

      await _dataStore.tableDataManager.clearTableRecordsForTable(tableName);
      // Manually remove record count cache to force reload next time
      _dataStore.tableDataManager.removeRecordCountCache(tableName);
      _dataStore.tableDataManager.invalidateTableMetaCacheForTable(tableName);
      _dataStore.tableTreePartitionManager.clearPageCacheForTable(tableName);
      _dataStore.schemaManager?.removeCachedTableSchema(tableName);

      // Conservative: invalidate all queries on this table.
      _markQueryCacheDirty(tableName);

      // Best-effort: remove index meta cache (coarse-grained).
      await _dataStore.indexManager?.removeIndexMetaCacheForTable(tableName);
      _dataStore.indexTreePartitionManager.clearPageCacheForTable(tableName);
    } catch (e) {
      Logger.error(
        'Invalidate table cache failed: $e\n'
        'tableName: $tableName',
        label: 'CacheManager.invalidateCache',
      );
    }
  }

  int getCurrentQueryCacheSize() {
    return _dataStore.queryExecutor.getCurrentQueryCacheSizeBytes();
  }
}
