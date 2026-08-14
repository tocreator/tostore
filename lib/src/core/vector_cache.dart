import 'dart:typed_data';

import '../model/ngh_index_meta.dart';
import '../model/table_context.dart';
import '../model/table_identity.dart';
import 'tree_cache.dart';
import 'vector_quantizer.dart';

// ============================================================================
// Vector Cache -- Hot PQ Codes, Codebooks, and Prefetch Queue
//
// Tier 1 of the cold/hot separation:
//   - PQ codes: compact (M bytes/vector), always-resident for ADC search
//   - Codebooks: small, loaded once at index open
//   - Graph/raw pages: managed by NghPartitionManager's TreeCache instances
//
// This cache is separate from page caches because PQ codes need random access
// by nodeId (not by page) and are tiny enough to store per-vector.
// ============================================================================

/// Hot cache for PQ codes and codebooks, keyed by [tableUid, indexUid].
class VectorCache {
  /// PQ code cache: key = [tableUid, indexUid, nodeId], value = Uint8List (M bytes).
  /// This is the most performance-critical cache -- every ADC distance check
  /// does a lookup here instead of reading a full page from disk.
  late final TreeCache<Uint8List> _pqCodeCache;

  /// Codebook cache: key = [tableUid, indexUid], value = PqCodebook.
  /// Uses TreeCache with groupDepth=1 (tableUid) for O(1) prefix removal.
  late final TreeCache<PqCodebook> _codebookCache;

  /// NghIndexMeta cache: key = [tableUid, indexUid], value = NghIndexMeta.
  late final TreeCache<NghIndexMeta> _metaCache;

  VectorCache({int pqCodeBudgetBytes = 64 * 1024 * 1024}) {
    _pqCodeCache = TreeCache<Uint8List>(
      sizeCalculator: (code) => code.length + 16, // overhead
      maxByteThreshold: pqCodeBudgetBytes,
      minByteThreshold: (pqCodeBudgetBytes * 0.7).round(),
      groupDepth: 2, // [tableUid, indexUid]
      debugLabel: 'VectorPqCodeCache',
    );

    _codebookCache = TreeCache<PqCodebook>(
      sizeCalculator: (cb) => cb.data.lengthInBytes + 64,
      maxByteThreshold: 64 * 1024 * 1024, // 64MB -- codebooks are small
      minByteThreshold: 32 * 1024 * 1024,
      groupDepth: 1, // [tableUid]
      debugLabel: 'VectorCodebookCache',
    );

    _metaCache = TreeCache<NghIndexMeta>(
      sizeCalculator: (_) => 512, // small fixed-size
      maxByteThreshold: 64 * 1024 * 1024, // 64MB -- codebooks are small
      minByteThreshold: 32 * 1024 * 1024,
      groupDepth: 1, // [tableUid]
      debugLabel: 'VectorMetaCache',
    );
  }

  // =====================================================================
  // PQ Code Cache -- Per-Vector Fast Access
  // =====================================================================

  /// Get cached PQ code for a node.
  Uint8List? getPqCode(TableContext table, IndexUid indexUid, int nodeId) {
    return _pqCodeCache.get([table.tableUid, indexUid, nodeId]);
  }

  /// Cache a PQ code for a node.
  void putPqCode(
      TableContext table, IndexUid indexUid, int nodeId, Uint8List code) {
    _pqCodeCache.put([table.tableUid, indexUid, nodeId], code);
  }

  /// Batch-cache PQ codes for a range of nodes (e.g. after reading a PQ page).
  void putPqCodeBatch(TableContext table, IndexUid indexUid, int startNodeId,
      List<Uint8List> codes) {
    for (int i = 0; i < codes.length; i++) {
      _pqCodeCache.put([table.tableUid, indexUid, startNodeId + i], codes[i]);
    }
  }

  // =====================================================================
  // Codebook Cache -- Per-Index
  // =====================================================================

  /// Get cached codebook for an index.
  PqCodebook? getCodebook(TableContext table, IndexUid indexUid) {
    return _codebookCache.get([table.tableUid, indexUid]);
  }

  /// Cache a codebook for an index.
  void putCodebook(TableContext table, IndexUid indexUid, PqCodebook codebook) {
    _codebookCache.put([table.tableUid, indexUid], codebook);
  }

  /// Remove cached codebook (e.g. after retraining).
  void removeCodebook(TableContext table, IndexUid indexUid) {
    _codebookCache.remove([table.tableUid, indexUid]);
  }

  // =====================================================================
  // Meta Cache -- Per-Index
  // =====================================================================

  /// Get cached NghIndexMeta.
  NghIndexMeta? getMeta(TableContext table, IndexUid indexUid) {
    return _metaCache.get([table.tableUid, indexUid]);
  }

  /// Cache NghIndexMeta.
  void putMeta(TableContext table, IndexUid indexUid, NghIndexMeta meta) {
    _metaCache.put([table.tableUid, indexUid], meta);
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
  void clearForTable(TableUid tableUid) {
    _pqCodeCache.remove([tableUid]);
    _codebookCache.remove([tableUid]);
    _metaCache.remove([tableUid]);
  }

  /// Clear all caches for a specific index.
  void clearForIndex(TableUid tableUid, IndexUid indexUid) {
    _pqCodeCache.remove([tableUid, indexUid]);
    _codebookCache.remove([tableUid, indexUid]);
    _metaCache.remove([tableUid, indexUid]);
  }

  /// Clear all vector caches.
  void clear() {
    _pqCodeCache.clear();
    _codebookCache.clear();
    _metaCache.clear();
  }
}
