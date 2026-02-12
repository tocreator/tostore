import 'dart:typed_data';

import '../model/ngh_index_meta.dart';
import 'tree_cache.dart';
import 'vector_quantizer.dart';

// ============================================================================
// Vector Cache — Hot PQ Codes, Codebooks, and Prefetch Queue
//
// Tier 1 of the cold/hot separation:
//   - PQ codes: compact (M bytes/vector), always-resident for ADC search
//   - Codebooks: small, loaded once at index open
//   - Graph/raw pages: managed by NghPartitionManager's TreeCache instances
//
// This cache is separate from page caches because PQ codes need random access
// by nodeId (not by page) and are tiny enough to store per-vector.
// ============================================================================

/// Hot cache for PQ codes and codebooks, keyed by [tableName, indexName].
class VectorCache {
  /// PQ code cache: key = [tableName, indexName, nodeId], value = Uint8List (M bytes).
  /// This is the most performance-critical cache — every ADC distance check
  /// does a lookup here instead of reading a full page from disk.
  late final TreeCache<Uint8List> _pqCodeCache;

  /// Codebook cache: key = [tableName, indexName], value = PqCodebook.
  /// Uses TreeCache with groupDepth=1 (tableName) for O(1) prefix removal.
  late final TreeCache<PqCodebook> _codebookCache;

  /// NghIndexMeta cache: key = [tableName, indexName], value = NghIndexMeta.
  late final TreeCache<NghIndexMeta> _metaCache;

  VectorCache({int pqCodeBudgetBytes = 64 * 1024 * 1024}) {
    _pqCodeCache = TreeCache<Uint8List>(
      sizeCalculator: (code) => code.length + 16, // overhead
      maxByteThreshold: pqCodeBudgetBytes,
      minByteThreshold: (pqCodeBudgetBytes * 0.7).round(),
      groupDepth: 2, // [tableName, indexName]
      debugLabel: 'VectorPqCodeCache',
    );

    _codebookCache = TreeCache<PqCodebook>(
      sizeCalculator: (cb) => cb.data.lengthInBytes + 64,
      maxByteThreshold: 64 * 1024 * 1024, // 64MB — codebooks are small
      minByteThreshold: 32 * 1024 * 1024,
      groupDepth: 1, // [tableName]
      debugLabel: 'VectorCodebookCache',
    );

    _metaCache = TreeCache<NghIndexMeta>(
      sizeCalculator: (_) => 512, // small fixed-size
      maxByteThreshold: 64 * 1024 * 1024, // 64MB — codebooks are small
      minByteThreshold: 32 * 1024 * 1024,
      groupDepth: 1, // [tableName]
      debugLabel: 'VectorMetaCache',
    );
  }

  // =====================================================================
  // PQ Code Cache — Per-Vector Fast Access
  // =====================================================================

  /// Get cached PQ code for a node.
  Uint8List? getPqCode(String tableName, String indexName, int nodeId) {
    return _pqCodeCache.get([tableName, indexName, nodeId]);
  }

  /// Cache a PQ code for a node.
  void putPqCode(
      String tableName, String indexName, int nodeId, Uint8List code) {
    _pqCodeCache.put([tableName, indexName, nodeId], code);
  }

  /// Batch-cache PQ codes for a range of nodes (e.g. after reading a PQ page).
  void putPqCodeBatch(String tableName, String indexName, int startNodeId,
      List<Uint8List> codes) {
    for (int i = 0; i < codes.length; i++) {
      _pqCodeCache.put([tableName, indexName, startNodeId + i], codes[i]);
    }
  }

  // =====================================================================
  // Codebook Cache — Per-Index
  // =====================================================================

  /// Get cached codebook for an index.
  PqCodebook? getCodebook(String tableName, String indexName) {
    return _codebookCache.get([tableName, indexName]);
  }

  /// Cache a codebook for an index.
  void putCodebook(String tableName, String indexName, PqCodebook codebook) {
    _codebookCache.put([tableName, indexName], codebook);
  }

  /// Remove cached codebook (e.g. after retraining).
  void removeCodebook(String tableName, String indexName) {
    _codebookCache.remove([tableName, indexName]);
  }

  // =====================================================================
  // Meta Cache — Per-Index
  // =====================================================================

  /// Get cached NghIndexMeta.
  NghIndexMeta? getMeta(String tableName, String indexName) {
    return _metaCache.get([tableName, indexName]);
  }

  /// Cache NghIndexMeta.
  void putMeta(String tableName, String indexName, NghIndexMeta meta) {
    _metaCache.put([tableName, indexName], meta);
  }

  // =====================================================================
  // Cache Management
  // =====================================================================

  /// Estimated total memory usage of vector caches.
  int get estimatedSizeBytes {
    return _pqCodeCache.estimatedTotalSizeBytes +
        _codebookCache.estimatedTotalSizeBytes +
        _metaCache.estimatedTotalSizeBytes;
  }

  /// Evict a ratio of all vector caches (called by MemoryManager).
  Future<void> evict({double ratio = 0.3}) async {
    await _pqCodeCache.cleanup(removeRatio: ratio);
    await _codebookCache.cleanup(removeRatio: ratio);
  }

  /// Clear all caches for a specific table (O(1) via TreeCache group prefix).
  void clearForTable(String tableName) {
    _pqCodeCache.remove([tableName]);
    _codebookCache.remove([tableName]);
    _metaCache.remove([tableName]);
  }

  /// Clear all caches for a specific index.
  void clearForIndex(String tableName, String indexName) {
    _pqCodeCache.remove([tableName, indexName]);
    _codebookCache.remove([tableName, indexName]);
    _metaCache.remove([tableName, indexName]);
  }

  /// Clear all vector caches.
  void clear() {
    _pqCodeCache.clear();
    _codebookCache.clear();
    _metaCache.clear();
  }
}
