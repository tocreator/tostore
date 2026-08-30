import '../model/ngh_index_meta.dart';
import '../model/table_context.dart';
import '../model/table_identity.dart';
import 'tree_cache.dart';

// ============================================================================
// Vector Cache -- In-Memory Fast Metadata Cache
// ============================================================================

/// Hot cache for NghIndexMeta, keyed by [tableUid, indexUid].
class VectorCache {
  /// NghIndexMeta cache: key = [tableUid, indexUid], value = NghIndexMeta.
  late final TreeCache<NghIndexMeta> _metaCache;

  VectorCache() {
    _metaCache = TreeCache<NghIndexMeta>(
      sizeCalculator: (_) => 512, // small fixed-size
      maxByteThreshold: 32 * 1024 * 1024,
      minByteThreshold: 16 * 1024 * 1024,
      groupDepth: 1, // [tableUid]
      debugLabel: 'VectorMetaCache',
    );
  }

  // =====================================================================
  // Meta Cache -- Per-Index
  // =====================================================================

  /// Get cached NghIndexMeta.
  NghIndexMeta? getMeta(TableContext table, IndexUid indexUid) {
    return _metaCache.getPoint2(table.tableUid, indexUid);
  }

  /// Cache NghIndexMeta.
  void putMeta(TableContext table, IndexUid indexUid, NghIndexMeta meta) {
    _metaCache.putPoint2(table.tableUid, indexUid, meta);
  }

  // =====================================================================
  // Cache Management
  // =====================================================================

  /// Estimated total memory usage of vector caches.
  int get estimatedSizeBytes => _metaCache.estimatedTotalSizeBytes;

  /// Evict a ratio of all vector caches (called by MemoryManager).
  Future<void> evict({double ratio = 0.3}) async {
    await _metaCache.cleanup(removeRatio: ratio);
  }

  /// Clear all caches for a specific table (O(1) via TreeCache group prefix).
  void clearForTable(TableUid tableUid) {
    _metaCache.remove([tableUid]);
  }

  /// Clear all caches for a specific index.
  void clearForIndex(TableUid tableUid, IndexUid indexUid) {
    _metaCache.remove([tableUid, indexUid]);
  }

  /// Clear all vector caches.
  void clear() {
    _metaCache.clear();
  }
}
