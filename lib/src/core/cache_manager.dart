import 'dart:async';

import '../handler/logger.dart';
import '../model/data_store_config.dart';
import '../model/table_context.dart';
import 'data_store_impl.dart';
import 'resource_manager.dart';

/// Central cache facade.
///
final class CacheManager {
  final DataStoreImpl _dataStore;

  // Coalesced query-cache invalidation (generation bump in QueryExecutor).
  final Set<String> _pendingQueryInvalidations = <String>{};
  bool _queryInvalidationScheduled = false;

  CacheManager(this._dataStore) {
    _registerMemoryCallbacks();
  }

  void _registerMemoryCallbacks() {
    final mm = _dataStore.resourceManager;
    if (mm == null) return;

    final bool isMemoryMode =
        _dataStore.config.persistenceMode == PersistenceMode.memory;

    // Table data (hot records + B+Tree pages)
    mm.registerCacheEvictionCallback(MemoryQuotaType.tableData, (
        {int? oneShotNeedFreeMB}) async {
      if (isMemoryMode) return;
      final recordRatio =
          mm.getRecordCacheEvictionRatio(oneShotNeedFreeMB: oneShotNeedFreeMB);
      final pageRatio =
          mm.getPageCacheEvictionRatio(oneShotNeedFreeMB: oneShotNeedFreeMB);
      try {
        // Evict record cache first (heap-heavy row maps)
        await _dataStore.tableDataManager
            .evictTableRecordCache(ratio: recordRatio);
      } catch (e) {
        Logger.warn('Evict hot record cache failed', rawError: e);
      }
      try {
        // Then evict page cache (B+Tree pages) with conservative page ratio to protect flush IO
        await _dataStore.tableTreePartitionManager
            ?.evictPageCache(ratio: pageRatio);
      } catch (e) {
        Logger.warn('Evict page cache failed', rawError: e);
      }
      try {
        // Evict overflow page cache
        await _dataStore.overflowManager.evictPageCache(ratio: pageRatio);
      } catch (e) {
        Logger.warn('Evict overflow page cache failed', rawError: e);
      }
    });

    // Structured B+Tree index pages (not vector ANN — that is vectorIndex).
    mm.registerCacheEvictionCallback(MemoryQuotaType.indexData, (
        {int? oneShotNeedFreeMB}) async {
      if (isMemoryMode) return;
      final ratio =
          mm.getPageCacheEvictionRatio(oneShotNeedFreeMB: oneShotNeedFreeMB);
      try {
        // Evict B+Tree page cache conservatively
        await _dataStore.indexTreePartitionManager
            ?.evictPageCache(ratio: ratio);
      } catch (e) {
        Logger.warn('Evict index page cache failed', rawError: e);
      }
    });

    mm.registerCacheEvictionCallback(MemoryQuotaType.vectorIndex, (
        {int? oneShotNeedFreeMB}) async {
      if (isMemoryMode) return;
      final ratio = mm.getEvictionRatio(MemoryQuotaType.vectorIndex,
          oneShotNeedFreeMB: oneShotNeedFreeMB);
      try {
        // Evict NGH vector index caches
        await _dataStore.vectorIndexManager?.evictCache(ratio: ratio);
      } catch (e) {
        Logger.warn('Evict vector index cache failed', rawError: e);
      }
    });

    // Query result cache (QueryExecutor + HotspotCache)
    mm.registerCacheEvictionCallback(MemoryQuotaType.queryResult, (
        {int? oneShotNeedFreeMB}) async {
      final ratio = mm.getEvictionRatio(MemoryQuotaType.queryResult,
          oneShotNeedFreeMB: oneShotNeedFreeMB);
      try {
        await _dataStore.queryExecutor.evictQueryCache(ratio: ratio);
      } catch (e) {
        Logger.warn('Evict query cache failed', rawError: e);
      }
    });

    // Schema cache (tableMetaManager + HotspotCache)
    mm.registerCacheEvictionCallback(MemoryQuotaType.schema, (
        {int? oneShotNeedFreeMB}) async {
      final ratio = mm.getEvictionRatio(MemoryQuotaType.tableData,
          oneShotNeedFreeMB: oneShotNeedFreeMB);
      try {
        await _dataStore.tableMetaManager?.evictSchemaCache(ratio: ratio);
      } catch (e) {
        Logger.warn('Evict schema cache failed', rawError: e);
      }
    });

    // Meta caches (table data meta + index meta)
    mm.registerCacheEvictionCallback(MemoryQuotaType.meta, (
        {int? oneShotNeedFreeMB}) async {
      final ratio = mm.getEvictionRatio(MemoryQuotaType.tableData,
          oneShotNeedFreeMB: oneShotNeedFreeMB);
      try {
        await _dataStore.tableDataManager.evictTableDataMetaCache(ratio: ratio);
      } catch (e) {
        Logger.warn('Evict table data meta cache failed', rawError: e);
      }
      try {
        await _dataStore.indexManager?.evictIndexMetaCache(ratio);
      } catch (e) {
        Logger.warn('Evict index meta cache failed', rawError: e);
      }
    });
  }

  int getCurrentSchemaCacheSize() {
    return _dataStore.tableMetaManager?.getCurrentSchemaCacheSize() ?? 0;
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
    final firstInTick = _pendingQueryInvalidations.add(table.tableUid.value);
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

  // -------------------- Space / lifecycle --------------------

  /// Clear in-memory caches synchronously (used on close).
  ///
  /// [flush]: when true (default), managers may persist runtime metadata before
  /// clearing; when false, discard and clear only.
  Future<void> dispose({bool includeSchema = true, bool flush = true}) async {
    // Batch wait for multiple asynchronous tasks
    await Future.wait([
      _dataStore.tableMetaManager?.dispose() ?? Future.value(),
      _dataStore.tableDataManager.dispose(flush: flush),
      _dataStore.indexManager?.dispose() ?? Future.value(),
      _dataStore.vectorIndexManager?.dispose() ?? Future.value(),
    ]);

    _dataStore.queryExecutor.clearAllQueryCacheSync();
    _dataStore.queryExecutor.clearAllPlanCache();
    _dataStore.tableTreePartitionManager?.clearPageCacheSync();
    _dataStore.indexTreePartitionManager?.clearPageCacheSync();
    _dataStore.weightManager?.clearMemory();
    _dataStore.clearAllTtlPlanCache();

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
        _dataStore.tableMetaManager?.removeCachedTableSchema(table.tableUid);
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
