import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../handler/logger.dart';
import '../handler/memcomparable.dart';
import '../model/data_block_entry.dart';
import '../model/meta_info.dart';
import '../model/ngh_index_meta.dart';
import '../model/parallel_journal_entry.dart';
import '../model/query_result.dart';
import '../model/table_schema.dart';
import '../model/table_context.dart';
import '../model/db_exception.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import 'compute/compute_batch_planner.dart';
import 'compute/vector_batch_prepare_compute.dart';
import 'compute_manager.dart';
import 'compute_tasks.dart';
import 'data_store_impl.dart';
import 'ngh_graph_engine.dart';
import 'ngh_page.dart';
import 'ngh_partition_manager.dart';
import 'vector_cache.dart';
import 'vector_quantizer.dart';
import 'workload_scheduler.dart';
import 'yield_controller.dart';
import '../model/table_identity.dart';

/// Manages all NGH vector indexes for the data store.
class VectorIndexManager {
  final DataStoreImpl _dataStore;

  late final NghPartitionManager _partitionManager;
  late final NghGraphEngine _graphEngine;
  late final VectorCache _vectorCache;

  /// In-flight meta loads — prevents parallel readers from each hitting disk.
  /// Key: "$tableUid/$indexUid", value: the single in-progress Future.
  final Map<String, Future<NghIndexMeta?>> _metaLoadingFutures = {};

  VectorIndexManager(this._dataStore) {
    _partitionManager = NghPartitionManager(_dataStore);
    _graphEngine = NghGraphEngine(_partitionManager);
    _vectorCache = VectorCache();
  }

  int _estimateVectorPrepareRecordBytes(
    Map<String, dynamic> record,
    String fieldName,
    String? primaryKeyField,
    int dimensions,
  ) {
    int size = 64;

    if (primaryKeyField != null) {
      final primaryKey = record[primaryKeyField];
      if (primaryKey != null) {
        size += primaryKey.toString().length * 2;
      }
    }

    final value = record[fieldName];
    if (value is VectorData) {
      size += min(value.values.length, dimensions) * 8;
    } else if (value is List) {
      size += min(value.length, dimensions) * 8;
    } else {
      size += dimensions * 4;
    }

    return size;
  }

  int _estimateMinUsefulVectorTaskItems(int dimensions) {
    if (dimensions >= 1024) return 64;
    if (dimensions >= 512) return 128;
    return ComputeBatchPlanner.minUsefulTaskItems;
  }

  Future<({List<Float32List> vectors, List<String> primaryKeys})>
      _prepareInsertVectorsBatch({
    required List<Map<String, dynamic>> records,
    required String fieldName,
    required String primaryKeyField,
    required int dimensions,
  }) async {
    if (records.isEmpty) {
      return (vectors: const <Float32List>[], primaryKeys: const <String>[]);
    }

    final minUsefulVectorTaskItems =
        _estimateMinUsefulVectorTaskItems(dimensions);
    final dispatchPlan = ComputeBatchPlanner.planTaskExecution(
      itemCount: records.length,
      minUsefulTaskItems: minUsefulVectorTaskItems,
      estimateAverageItemBytes: () =>
          ComputeBatchPlanner.estimateAverageItemBytes(
        records,
        (record) => _estimateVectorPrepareRecordBytes(
          record,
          fieldName,
          primaryKeyField,
          dimensions,
        ),
      ),
    );
    final useIsolate = dispatchPlan.useIsolate;
    final actualTaskCount = dispatchPlan.actualTaskCount;

    final tasks =
        <ComputeTask<VectorBatchPrepareRequest, VectorBatchPrepareResult>>[];
    for (final range
        in ComputeBatchPlanner.splitRange(records.length, actualTaskCount)) {
      tasks.add(
        ComputeTask(
          function: prepareVectorBatchChunk,
          message: VectorBatchPrepareRequest(
            records: records.sublist(range.start, range.end),
            fieldName: fieldName,
            primaryKeyField: primaryKeyField,
            dimensions: dimensions,
          ),
        ),
      );
    }

    final results =
        await ComputeManager.computeBatch(tasks, enableIsolate: useIsolate);

    final vectors = <Float32List>[];
    final primaryKeys = <String>[];
    final mergeYield = YieldController(
      'VectorIndexManager._prepareInsertVectorsBatch',
    );
    for (final result in results) {
      if (result.vectors.length != result.primaryKeys.length) {
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message: 'Vector prepare result length mismatch: '
                'vectors=${result.vectors.length}, '
                'primaryKeys=${result.primaryKeys.length}',
          ),
        ]);
      }

      for (int i = 0; i < result.vectors.length; i++) {
        final y1 = mergeYield.maybeYield();
        if (y1 != null) await y1;
        vectors.add(result.vectors[i]);
        primaryKeys.add(result.primaryKeys[i]);
      }
    }

    return (vectors: vectors, primaryKeys: primaryKeys);
  }

  Future<List<Uint8List>> _quantizeVectorsBatch({
    required VectorQuantizer quantizer,
    required List<Float32List> vectors,
  }) async {
    if (vectors.isEmpty) return const <Uint8List>[];

    final minUsefulVectorTaskItems =
        _estimateMinUsefulVectorTaskItems(quantizer.dimensions);
    final dispatchPlan = ComputeBatchPlanner.planTaskExecution(
      itemCount: vectors.length,
      minUsefulTaskItems: minUsefulVectorTaskItems,
      estimateAverageItemBytes: () =>
          max(1, quantizer.dimensions * 4 + quantizer.subspaces),
    );
    final useIsolate = dispatchPlan.useIsolate;
    final actualTaskCount = dispatchPlan.actualTaskCount;

    final tasks = <ComputeTask<BatchPqEncodeRequest, BatchPqEncodeResult>>[];
    for (final range
        in ComputeBatchPlanner.splitRange(vectors.length, actualTaskCount)) {
      tasks.add(
        ComputeTask(
          function: batchPqEncode,
          message: BatchPqEncodeRequest(
            vectors: vectors.sublist(range.start, range.end),
            codebookData: quantizer.codebook.data,
            subspaces: quantizer.subspaces,
            centroids: quantizer.centroids,
            subDimensions: quantizer.subDimensions,
          ),
        ),
      );
    }

    final results =
        await ComputeManager.computeBatch(tasks, enableIsolate: useIsolate);

    final pqCodes = <Uint8List>[];
    final mergeYield = YieldController(
      'VectorIndexManager._quantizeVectorsBatch',
      checkInterval: 128,
      budgetMs: 30,
    );
    for (final result in results) {
      for (final code in result.codes) {
        final y2 = mergeYield.maybeYield();
        if (y2 != null) await y2;
        pqCodes.add(code);
      }
    }
    return pqCodes;
  }

  Future<List<Float32List>> _collectTrainingSamplesBatch({
    required List<Map<String, dynamic>> inserts,
    required String fieldName,
    required int dimensions,
    int maxSamples = 2500,
  }) async {
    if (inserts.isEmpty || maxSamples <= 0) {
      return const <Float32List>[];
    }

    final minUsefulVectorTaskItems =
        _estimateMinUsefulVectorTaskItems(dimensions);
    final dispatchPlan = ComputeBatchPlanner.planTaskExecution(
      itemCount: inserts.length,
      minUsefulTaskItems: minUsefulVectorTaskItems,
      estimateAverageItemBytes: () =>
          ComputeBatchPlanner.estimateAverageItemBytes(
        inserts,
        (record) => _estimateVectorPrepareRecordBytes(
          record,
          fieldName,
          null,
          dimensions,
        ),
      ),
    );
    final useIsolate = dispatchPlan.useIsolate;
    final actualTaskCount = dispatchPlan.actualTaskCount;

    final samples = <Float32List>[];
    final mergeYield = YieldController(
      'VectorIndexManager._collectTrainingSamplesBatch',
      checkInterval: 64,
      budgetMs: 30,
    );
    final waveItemCount = max(
      maxSamples * 2,
      actualTaskCount * minUsefulVectorTaskItems,
    );

    int start = 0;
    while (start < inserts.length && samples.length < maxSamples) {
      final end = min(start + waveItemCount, inserts.length);
      final waveRecords = inserts.sublist(start, end);
      final waveTaskCount =
          useIsolate ? min(actualTaskCount, waveRecords.length) : 1;

      final tasks =
          <ComputeTask<VectorBatchPrepareRequest, VectorBatchPrepareResult>>[];
      for (final range in ComputeBatchPlanner.splitRange(
          waveRecords.length, waveTaskCount)) {
        tasks.add(
          ComputeTask(
            function: prepareVectorBatchChunk,
            message: VectorBatchPrepareRequest(
              records: waveRecords.sublist(range.start, range.end),
              fieldName: fieldName,
              primaryKeyField: null,
              dimensions: dimensions,
            ),
          ),
        );
      }

      final results =
          await ComputeManager.computeBatch(tasks, enableIsolate: useIsolate);
      for (final result in results) {
        for (final sample in result.vectors) {
          final y3 = mergeYield.maybeYield();
          if (y3 != null) await y3;
          samples.add(sample);
          if (samples.length >= maxSamples) {
            break;
          }
        }
        if (samples.length >= maxSamples) {
          break;
        }
      }

      start = end;
    }

    return samples;
  }

  // =====================================================================
  // Write Changes — Called by ParallelJournalManager during flush
  // =====================================================================

  /// Apply vector index changes for a table during the flush pipeline.
  ///
  /// Extracts vector fields from records, encodes them, inserts into the
  /// NGH graph, and flushes dirty pages to disk — all batched.
  Future<void> writeChanges({
    required TableContext table,
    List<Map<String, dynamic>> inserts = const [],
    List<Map<String, dynamic>> deletes = const [],
    BatchContext? batchContext,
    int? concurrency,
    TableSchema? schemaOverride,
    List<IndexSchema>? targetIndexesOverride,
  }) async {
    final schema = schemaOverride ??
        await _dataStore.tableMetaManager?.getTableSchema(table.tableUid);
    if (schema == null) return;

    final vectorIndexes = List<IndexSchema>.from(
      targetIndexesOverride?.where((index) => index.type == IndexType.vector) ??
          (_dataStore.tableMetaManager?.getVectorIndexesFor(schema) ??
              const <IndexSchema>[]),
    );
    if (vectorIndexes.isEmpty) return;
    final pkName = schema.primaryKey;

    final yc = YieldController(
      'VectorIndexManager.writeChanges',
      checkInterval: 30,
      budgetMs: 50,
    );

    for (final idx in vectorIndexes) {
      final y4 = yc.maybeYield();
      if (y4 != null) await y4;
      final indexUid = idx.indexUid;
      final fieldName = idx.fields.first; // vector index is single-field
      FieldSchema? fieldSchema;
      try {
        fieldSchema = schema.fields.firstWhere((f) => f.name == fieldName);
      } catch (_) {
        continue;
      }

      // Load or create meta
      var meta =
          await _getOrCreateMeta(table, indexUid, fieldName, fieldSchema, idx);

      // Load or train quantizer
      var quantizer =
          await _getOrTrainQuantizer(table, indexUid, meta, inserts, fieldName);
      if (quantizer == null) continue; // not enough data yet

      // Ensure mapping B+Tree metas are initialised
      meta = _ensureMappingMetas(meta, table);

      // ── Process inserts ──
      if (inserts.isNotEmpty) {
        final preparedVectors = await _prepareInsertVectorsBatch(
          records: inserts,
          fieldName: fieldName,
          primaryKeyField: pkName,
          dimensions: meta.dimensions,
        );
        final vectors = preparedVectors.vectors;
        final pks = preparedVectors.primaryKeys;

        if (vectors.isNotEmpty) {
          final startNodeId = meta.nextNodeId;

          // Isolate: PQ encode only (no file I/O). Graph insert + flush on main.
          final pqCodes = await _quantizeVectorsBatch(
            quantizer: quantizer,
            vectors: vectors,
          );

          // Main isolate: graph insert + flush (all NGH file read/write here)
          final insertResult = await _graphEngine.insertBatch(
            table: table,
            indexUid: indexUid,
            meta: meta,
            quantizer: quantizer,
            vectors: vectors,
            pqCodes: pqCodes,
            yieldBudgetMs: 100,
          );
          meta = insertResult.meta;
          meta = await _partitionManager.writeChanges(
            table: table,
            indexUid: indexUid,
            meta: meta,
            dirtyGraphPages: insertResult.dirtyGraphPages,
            dirtyPqCodePages: insertResult.dirtyPqCodePages,
            dirtyRawVectorPages: insertResult.dirtyRawVectorPages,
            vectorsDelta: insertResult.insertedCount,
            concurrency: concurrency,
          );

          // Write nodeId ↔ PK dual B+Tree mappings (persistent, not in memory)
          meta = await _writeMappings(
            table: table,
            meta: meta,
            startNodeId: startNodeId,
            pks: pks,
            isDelete: false,
            batchContext: batchContext,
            concurrency: concurrency,
          );

          // Persist updated meta
          await _persistMeta(table, indexUid, meta);
        }
      }

      // ── Process deletes ──
      if (deletes.isNotEmpty) {
        final nodeIdsToDelete = <int>[];
        final deletePks = <String>[];

        // Reverse lookup: PK → nodeId via B+Tree (disk, no memory map)
        final delYc = YieldController(
          'VectorIndexManager.writeChanges.deletes',
          checkInterval: 20,
          budgetMs: 30,
        );
        for (var di = 0; di < deletes.length; di++) {
          final y5 = delYc.maybeYield();
          if (y5 != null) await y5;
          final record = deletes[di];
          final pk = record[pkName]?.toString();
          if (pk == null) continue;
          final nodeId = await _lookupNodeIdByPk(table, meta, pk);
          if (nodeId != null) {
            nodeIdsToDelete.add(nodeId);
            deletePks.add(pk);
          }
        }

        if (nodeIdsToDelete.isNotEmpty) {
          final result = await _graphEngine.deleteBatch(
            table: table,
            indexUid: indexUid,
            meta: meta,
            nodeIds: nodeIdsToDelete,
          );

          // Remove mappings from both B+Trees
          meta = await _writeMappings(
            table: table,
            meta: meta,
            startNodeId: -1,
            pks: deletePks,
            isDelete: true,
            deleteNodeIds: nodeIdsToDelete,
            batchContext: batchContext,
            concurrency: concurrency,
          );

          meta = await _partitionManager.writeChanges(
            table: table,
            indexUid: indexUid,
            meta: meta,
            dirtyGraphPages: result.dirtyGraphPages,
            dirtyPqCodePages: const {},
            dirtyRawVectorPages: const {},
            deletedDelta: result.deletedCount,
            batchContext: batchContext,
            concurrency: concurrency,
          );
        }
      }

      // Persist updated meta
      await _persistMeta(table, indexUid, meta);
      _vectorCache.putMeta(table, indexUid, meta);
    }
  }

  // =====================================================================
  // vectorSearch — Public Search API
  // =====================================================================

  /// Perform approximate nearest neighbor search on a vector field.
  ///
  /// Returns the top-[topK] most similar records, sorted by similarity.
  Future<List<VectorSearchResult>> vectorSearch({
    required TableContext table,
    required String fieldName,
    required VectorData queryVector,
    int topK = 10,
    int? efSearch,
    double? distanceThreshold,
  }) async {
    // Find the vector index for this field
    final schema =
        await _dataStore.tableMetaManager?.getTableSchema(table.tableUid);
    if (schema == null) return const [];

    final vectorIndexes =
        _dataStore.tableMetaManager?.getVectorIndexesFor(schema) ??
            const <IndexSchema>[];
    IndexSchema? targetIdx;
    for (final idx in vectorIndexes) {
      if (idx.fields.contains(fieldName)) {
        targetIdx = idx;
        break;
      }
    }
    if (targetIdx == null) return const [];

    final indexUid = targetIdx.indexUid;

    // Load meta
    var meta = _vectorCache.getMeta(table, indexUid);
    meta ??= await _loadMeta(table, indexUid);
    if (meta == null || meta.totalVectors == 0) return const [];

    // Load quantizer
    final quantizer = await _getQuantizer(table, indexUid, meta);
    if (quantizer == null) return const [];

    // Lazy full-cache preload in background (maintenance); does not block query
    _partitionManager.preloadForVectorSearch(table, indexUid, meta);

    // Prepare query vector
    final queryF32 = _toFloat32(queryVector.values, meta.dimensions);

    // Normalise for cosine metric
    Float32List searchQuery = queryF32;
    if (meta.distanceMetric == VectorDistanceMetric.cosine) {
      searchQuery = _normalizeFloat32(queryF32);
    }

    // Acquire query workload lease for parallel I/O (flush has priority; query shares capacity).
    WorkloadLease? lease;
    try {
      lease = await _dataStore.workloadScheduler.acquire(
        WorkloadType.query,
        requestedTokens:
            _dataStore.workloadScheduler.capacityTokens(WorkloadType.query),
        minTokens: 1,
        label: 'VectorIndexManager.vectorSearch',
      );
    } catch (_) {
      lease = null;
    }

    List<NghSearchResult> results;
    try {
      results = await _graphEngine.search(
        table: table,
        indexUid: indexUid,
        meta: meta,
        quantizer: quantizer,
        query: searchQuery,
        topK: topK,
        efSearch: efSearch,
        distanceThreshold: distanceThreshold,
        workloadLease: lease,
      );
    } finally {
      lease?.release();
    }

    // Map nodeId → PK via persistent B+Tree (batch lookup to reduce leaf reads).
    if (results.isEmpty) return const [];
    // Sort by nodeId to exploit B+Tree leaf locality for batch lookup.
    final sortedByNode = List<NghSearchResult>.from(results)
      ..sort((a, b) => a.nodeId.compareTo(b.nodeId));
    final keys = [for (final r in sortedByNode) _encodeNodeIdKey(r.nodeId)];
    final nid2pk = meta.nodeIdToPkMeta;
    final pks = (nid2pk == null || nid2pk.btreeFirstLeaf.isNull)
        ? List<String?>.filled(sortedByNode.length, null, growable: false)
        : await _dataStore.indexTreePartitionManager
                ?.lookupUniquePrimaryKeysBatch(
              table: table,
              indexUid: nid2pk.indexUid,
              meta: nid2pk,
              uniqueKeys: keys,
            ) ??
            <String>[];
    final entries = <VectorSearchResult>[];
    final searchYc = YieldController(
      'VectorIndexManager.vectorSearch.lookupPk',
      checkInterval: 25,
      budgetMs: 40,
    );
    for (int i = 0; i < sortedByNode.length; i++) {
      final y6 = searchYc.maybeYield();
      if (y6 != null) await y6;
      final pk = pks[i];
      if (pk == null) continue;
      entries.add(VectorSearchResult(
        primaryKey: pk,
        distance: sortedByNode[i].distance,
        score: _distanceToScore(sortedByNode[i].distance, meta.distanceMetric),
      ));
    }
    // Re-sort by distance for final output
    entries.sort((a, b) => a.distance.compareTo(b.distance));
    return entries;
  }

  // =====================================================================
  // Meta Persistence
  // =====================================================================

  /// Public read of NGH index meta (coalesced disk load).
  Future<NghIndexMeta?> getNghIndexMeta(
          TableContext table, IndexUid indexUid) =>
      _loadMeta(table, indexUid);

  /// Load meta from disk with coalesce: concurrent callers share a single I/O.
  Future<NghIndexMeta?> _loadMeta(TableContext table, IndexUid indexUid) {
    final loadKey = '${table.tableUid}/$indexUid';
    final existing = _metaLoadingFutures[loadKey];
    if (existing != null) return existing;

    final future = _doLoadMeta(table, indexUid).whenComplete(() {
      _metaLoadingFutures.remove(loadKey);
    });
    _metaLoadingFutures[loadKey] = future;
    return future;
  }

  Future<NghIndexMeta?> _doLoadMeta(
      TableContext table, IndexUid indexUid) async {
    try {
      // Hot path: read stable uid layout only (single I/O).
      var diskLoad = await _readNghMetaFromDisk(table, indexUid);
      var loadedFromLegacyPath = false;

      if (diskLoad == null) {
        // Stable data meta missing — fall back to deprecated logical-name directory.
        final idx = _dataStore.tableMetaManager
            ?.findIndexSchemaByUid(table.schema, indexUid);
        final schemaLegacyName = idx?.actualIndexName;
        if (schemaLegacyName != null &&
            schemaLegacyName.isNotEmpty &&
            schemaLegacyName != indexUid.value) {
          diskLoad =
              await _readNghMetaFromDisk(table, IndexUid(schemaLegacyName));
          loadedFromLegacyPath = diskLoad != null;
        }
      }

      if (diskLoad == null) return null;

      final needsRepair = loadedFromLegacyPath ||
          NghIndexMeta.needsOnDiskRepair(
            meta: diskLoad.meta,
            expectedIndexUid: indexUid,
            hadLegacyDisplayFields: diskLoad.hadLegacyDisplayFields,
          );

      if (needsRepair) {
        var legacyLogicalName = NghIndexMeta.inferLegacyLogicalName(
          meta: diskLoad.meta,
          expectedIndexUid: indexUid,
          legacyNameFromJson: diskLoad.legacyLogicalNameFromJson,
        );
        if (loadedFromLegacyPath &&
            (legacyLogicalName == null || legacyLogicalName.isEmpty)) {
          legacyLogicalName = _dataStore.tableMetaManager
              ?.findIndexSchemaByUid(table.schema, indexUid)
              ?.actualIndexName;
        }
        if (legacyLogicalName != null &&
            legacyLogicalName.isNotEmpty &&
            legacyLogicalName != indexUid.value) {
          await _dataStore.indexManager?.ensureStableIndexLayoutOnLoad(
            table,
            indexUid: indexUid,
            legacyLogicalName: legacyLogicalName,
          );
          if (loadedFromLegacyPath) {
            diskLoad = await _readNghMetaFromDisk(table, indexUid) ?? diskLoad;
          }
        }
      }

      final reconciled = _reconcileLoadedNghMeta(diskLoad.meta, indexUid);
      if (reconciled != diskLoad.meta || diskLoad.hadLegacyDisplayFields) {
        await _persistMeta(table, indexUid, reconciled);
      }
      _vectorCache.putMeta(table, indexUid, reconciled);
      return reconciled;
    } catch (e) {
      Logger.warn('Failed to load NGH meta for $indexUid', rawError: e);
      return null;
    }
  }

  Future<
      ({
        NghIndexMeta meta,
        String? legacyLogicalNameFromJson,
        bool hadLegacyDisplayFields,
      })?> _readNghMetaFromDisk(TableContext table, IndexUid pathKey) async {
    final meta = await _dataStore.treeMetaPageService.readNghGlobalMeta(
      table.tableUid,
      pathKey,
    );
    if (meta == null) return null;
    return (
      meta: meta,
      legacyLogicalNameFromJson: null,
      hadLegacyDisplayFields: false,
    );
  }

  /// Align in-memory meta with stable [pathKey] and derived mapping uids.
  NghIndexMeta _reconcileLoadedNghMeta(NghIndexMeta meta, IndexUid pathKey) {
    var reconciled = meta;
    if (pathKey.isNotEmpty && reconciled.indexUid != pathKey) {
      reconciled = reconciled.copyWith(indexUid: pathKey);
    }

    IndexMeta? nid2pk = reconciled.nodeIdToPkMeta;
    IndexMeta? pk2nid = reconciled.pkToNodeIdMeta;
    final expectedNid2pk = reconciled.nid2pkIndexUid;
    final expectedPk2nid = reconciled.pk2nidIndexUid;

    if (nid2pk != null && nid2pk.indexUid != expectedNid2pk) {
      nid2pk = nid2pk.copyWith(
        indexUid: expectedNid2pk,
        tableUid: reconciled.tableUid,
      );
    }
    if (pk2nid != null && pk2nid.indexUid != expectedPk2nid) {
      pk2nid = pk2nid.copyWith(
        indexUid: expectedPk2nid,
        tableUid: reconciled.tableUid,
      );
    }

    if (nid2pk != reconciled.nodeIdToPkMeta ||
        pk2nid != reconciled.pkToNodeIdMeta) {
      reconciled = reconciled.copyWith(
        nodeIdToPkMeta: nid2pk,
        pkToNodeIdMeta: pk2nid,
      );
    }
    return reconciled;
  }

  Future<void> _persistMeta(
      TableContext table, IndexUid indexUid, NghIndexMeta meta) async {
    try {
      await _dataStore.treeMetaPageService.persistNghGlobalMeta(
        tableUid: table.tableUid,
        indexUid: indexUid,
        meta: meta,
        flush: false,
      );
    } catch (e) {
      Logger.error('Failed to persist NGH meta', rawError: e);
    }
  }

  Future<NghIndexMeta> _getOrCreateMeta(
    TableContext table,
    IndexUid indexUid,
    String fieldName,
    FieldSchema fieldSchema,
    IndexSchema idx,
  ) async {
    // Check cache
    var meta = _vectorCache.getMeta(table, indexUid);
    if (meta != null) return meta;

    // Try load from disk
    meta = await _loadMeta(table, indexUid);
    if (meta != null) {
      _vectorCache.putMeta(table, indexUid, meta);
      return meta;
    }

    // Create new
    final dims = fieldSchema.vectorConfig?.dimensions ?? 128;
    final vc = idx.vectorConfig;

    meta = NghIndexMeta.createEmpty(
      indexUid: indexUid,
      tableUid: table.tableUid,
      dimensions: dims,
      distanceMetric: vc?.distanceMetric ?? VectorDistanceMetric.cosine,
      precision: fieldSchema.vectorConfig?.precision ?? VectorPrecision.float32,
      maxDegree: vc?.maxDegree ?? 64,
      efSearch: vc?.efSearch ?? 64,
      constructionEf: vc?.constructionEf ?? 128,
      pruneAlpha: vc?.pruneAlpha ?? 1.2,
      pqSubspaces: vc?.pqSubspaces ?? NghIndexMeta.autoPqSubspaces(dims),
      maxPartitionFileSize: _dataStore.config.maxPartitionFileSize,
    );

    _vectorCache.putMeta(table, indexUid, meta);
    return meta;
  }

  // =====================================================================
  // Quantizer Management
  // =====================================================================

  Future<VectorQuantizer?> _getQuantizer(
      TableContext table, IndexUid indexUid, NghIndexMeta meta) async {
    // Check codebook cache
    var pqCodebook = _vectorCache.getCodebook(table, indexUid);

    if (pqCodebook == null) {
      // Load from disk
      final cbPage = await _partitionManager.readCodebook(
          table, indexUid, _dataStore.configuredPageSize);
      if (cbPage == null) return null;

      pqCodebook = PqCodebook(
        subspaces: cbPage.subspaceCount,
        centroids: cbPage.centroidsPerSubspace,
        subDimensions: cbPage.subspaceDimensions,
        data: cbPage.centroids,
      );
      _vectorCache.putCodebook(table, indexUid, pqCodebook);
    }

    final quantizer = VectorQuantizer(pqCodebook);
    // Consistency check: ensure loaded quantizer matches current meta
    if (quantizer.subspaces == meta.pqSubspaces &&
        quantizer.dimensions == meta.dimensions) {
      return quantizer;
    }

    Logger.warn('Existing quantizer mismatch for $indexUid: '
        'loaded(${quantizer.dimensions}d, ${quantizer.subspaces}m) != '
        'meta(${meta.dimensions}d, ${meta.pqSubspaces}m). '
        'Retraining might be required.');

    return null;
  }

  Future<VectorQuantizer?> _getOrTrainQuantizer(
    TableContext table,
    IndexUid indexUid,
    NghIndexMeta meta,
    List<Map<String, dynamic>> inserts,
    String fieldName,
  ) async {
    // Try cached/loaded first (returns null on mismatch)
    final existing = await _getQuantizer(table, indexUid, meta);
    if (existing != null) {
      return existing;
    }

    // Need to train — collect sample vectors from inserts
    final samples = await _collectTrainingSamplesBatch(
      inserts: inserts,
      fieldName: fieldName,
      dimensions: meta.dimensions,
      maxSamples: 2500,
    );

    if (samples.isEmpty) return null;

    // Train codebook
    final PqCodebook codebook;
    if (samples.length >= 100) {
      // Flatten data for isolate transfer
      final n = samples.length;
      final dim = meta.dimensions;
      final flatSamples = Float32List(n * dim);
      final flatYc = YieldController(
        'VectorIndexManager._getOrTrainQuantizer.flat',
        checkInterval: 200,
        budgetMs: 20,
      );
      for (int i = 0; i < n; i++) {
        final y7 = flatYc.maybeYield();
        if (y7 != null) await y7;
        flatSamples.setRange(i * dim, (i + 1) * dim, samples[i]);
      }
      // Acquire flush workload lease (flush has priority in scheduler)
      WorkloadLease? lease;
      try {
        lease = await _dataStore.workloadScheduler.acquire(
          WorkloadType.flush,
          label: 'VectorIndexManager.PQ.train',
        );
      } catch (e) {
        // Fallback if scheduler not available or error
        Logger.warn('Failed to acquire workload lease, proceeding without',
            rawError: e);
      }

      try {
        final subspaces = meta.pqSubspaces;
        final subDim = dim ~/ subspaces;
        final k = min(256, n);
        final tasks = <ComputeTask<PqTrainSubspaceRequest, PqSubspaceResult>>[];

        final subYc = YieldController(
          'VectorIndexManager._getOrTrainQuantizer.subSamples',
          checkInterval: 100,
          budgetMs: 15,
        );
        for (int m = 0; m < subspaces; m++) {
          final y8 = subYc.maybeYield();
          if (y8 != null) await y8;
          // Extract the specific column (sub-vectors) for this subspace
          final subSamples = Float32List(n * subDim);
          final subStart = m * subDim;
          for (int i = 0; i < n; i++) {
            final srcOff = i * dim + subStart;
            final dstOff = i * subDim;
            for (int d = 0; d < subDim; d++) {
              subSamples[dstOff + d] = flatSamples[srcOff + d];
            }
          }

          tasks.add(
            ComputeTask<PqTrainSubspaceRequest, PqSubspaceResult>(
              function: trainPqSubspace,
              message: PqTrainSubspaceRequest(
                subSamples: subSamples,
                n: n,
                subDim: subDim,
                k: k,
                iterations: 10,
                subspaceIndex: m,
              ),
            ),
          );
        }

        final workerTaskCount =
            max(1, ComputeManager.clampTaskCount(tasks.length));
        final results = <PqSubspaceResult>[];
        for (int start = 0; start < tasks.length; start += workerTaskCount) {
          final end = min(start + workerTaskCount, tasks.length);
          results.addAll(
            await ComputeManager.computeBatch(
              tasks.sublist(start, end),
              enableIsolate: true,
            ),
          );
        }

        final fullData = Float32List(subspaces * k * subDim);
        for (final res in results) {
          final m = res.subspaceIndex;
          // Copy centroids: [m * k * subDim ... ]
          final centerSrc = res.centroids;
          final centerDstOff = m * k * subDim;
          for (int i = 0; i < centerSrc.length; i++) {
            fullData[centerDstOff + i] = centerSrc[i];
          }
        }

        codebook = PqCodebook(
          subspaces: subspaces,
          centroids: k,
          subDimensions: subDim,
          data: fullData,
        );
      } finally {
        lease?.release();
      }
    } else {
      codebook = await VectorQuantizer.train(
        samples: samples,
        dimensions: meta.dimensions,
        subspaces: meta.pqSubspaces,
        numCentroids: min(256, samples.length),
        iterations: 10,
      );
    }

    // Persist codebook
    final subDim = meta.dimensions ~/ meta.pqSubspaces;
    final cbPage = NghCodebookPage(
      subspaceStart: 0,
      subspaceCount: codebook.subspaces,
      centroidsPerSubspace: codebook.centroids,
      subspaceDimensions: subDim,
      centroids: codebook.data,
    );
    await _partitionManager.writeCodebook(
        table, indexUid, cbPage, _dataStore.configuredPageSize);

    _vectorCache.putCodebook(table, indexUid, codebook);
    return VectorQuantizer(codebook);
  }

  // =====================================================================
  // Background Maintenance
  // =====================================================================

  /// Run background tombstone compaction for all vector indexes in a table.
  ///
  /// Repairs graph edges around deleted nodes and reclaims tombstone slots.
  /// Should be called periodically by the compaction manager, using
  /// [WorkloadType.maintenance] tokens.
  Future<void> compactTombstones(TableContext table,
      {int maxVisitedPages = 100}) async {
    final vectorIndexes =
        _dataStore.tableMetaManager?.getVectorIndexesFor(table.schema);
    if (vectorIndexes == null || vectorIndexes.isEmpty) return;

    final yc = YieldController(
      'VectorIndexManager.compactTombstones',
      checkInterval: 20,
      budgetMs: 40,
    );
    for (final idx in vectorIndexes) {
      final y9 = yc.maybeYield();
      if (y9 != null) await y9;
      final indexUid = idx.indexUid;
      var meta = _vectorCache.getMeta(table, indexUid);
      meta ??= await _loadMeta(table, indexUid);
      if (meta == null) continue;

      // Skip if deletion ratio is low (< 10%)
      if (meta.totalVectors == 0 ||
          meta.deletedCount / meta.totalVectors < 0.1) {
        continue;
      }

      final result = await _graphEngine.compactTombstones(
        table: table,
        indexUid: indexUid,
        meta: meta,
        maxVisitedPages: maxVisitedPages,
      );

      if (result.dirtyGraphPages.isNotEmpty) {
        meta = await _partitionManager.writeChanges(
          table: table,
          indexUid: indexUid,
          meta: meta,
          dirtyGraphPages: result.dirtyGraphPages,
          dirtyPqCodePages: const {},
          dirtyRawVectorPages: const {},
          deletedDelta: -result.compactedCount,
        );
        await _persistMeta(table, indexUid, meta);
        _vectorCache.putMeta(table, indexUid, meta);
      }
    }
  }

  /// Reorder graph nodes by BFS traversal from medoid for access locality.
  ///
  /// Nodes visited in the same search neighbourhood are placed on the same
  /// or adjacent pages, dramatically improving disk I/O during beam search.
  /// This is a heavyweight maintenance operation — run it infrequently
  /// (e.g. after large bulk imports) using [WorkloadType.maintenance] tokens.
  ///
  /// Returns `true` if reordering was performed.
  Future<bool> reorderByLocality(TableContext table, IndexUid indexUid) async {
    var meta = _vectorCache.getMeta(table, indexUid);
    meta ??= await _loadMeta(table, indexUid);
    if (meta == null || meta.totalVectors < 2 || meta.medoidNodeId < 0) {
      return false;
    }

    // Phase 1: BFS from medoid to determine visit order.
    // Uses Uint8List bitmap (128MB for 10^9 nodes) instead of List<bool> (1GB).
    final totalNodes = meta.nextNodeId;
    final bitmapBytes = (totalNodes + 7) >> 3;
    final visitedBits = Uint8List(bitmapBytes);

    void markVisited(int id) {
      visitedBits[id >> 3] |= (1 << (id & 7));
    }

    bool isVisited(int id) {
      return (visitedBits[id >> 3] & (1 << (id & 7))) != 0;
    }

    final bfsOrder = <int>[];
    // Use ListQueue for O(1) dequeue instead of List.removeAt(0) which is O(n).
    final queue = ListQueue<int>();
    queue.add(meta.medoidNodeId);
    markVisited(meta.medoidNodeId);
    final yc = YieldController('VectorIndexManager.reorder', checkInterval: 50);

    while (queue.isNotEmpty) {
      final y10 = yc.maybeYield();
      if (y10 != null) await y10;
      final current = queue.removeFirst();
      bfsOrder.add(current);

      final neighbors =
          await _loadNeighborsForReorder(table, indexUid, meta, current);
      if (neighbors == null) continue;
      for (int i = 0; i < neighbors.length; i++) {
        final nId = neighbors[i];
        if (nId < totalNodes && !isVisited(nId)) {
          markVisited(nId);
          queue.add(nId);
        }
      }
    }

    // Add any unvisited nodes (disconnected components)
    for (int i = 0; i < totalNodes; i++) {
      if (i > 0 && i % 50000 == 0) {
        final y11 = yc.maybeYield();
        if (y11 != null) await y11;
      }
      if (!isVisited(i)) bfsOrder.add(i);
    }

    // Phase 2: Build old→new ID mapping (Int32List: 4GB for 10^9 nodes)
    final oldToNew = Int32List(totalNodes);
    for (int i = 0; i < totalNodes; i++) {
      if (i > 0 && i % 50000 == 0) {
        final y12 = yc.maybeYield();
        if (y12 != null) await y12;
      }
      oldToNew[i] = -1;
    }
    for (int newId = 0; newId < bfsOrder.length; newId++) {
      if (newId > 0 && newId % 50000 == 0) {
        final y13 = yc.maybeYield();
        if (y13 != null) await y13;
      }
      oldToNew[bfsOrder[newId]] = newId;
    }

    // Phase 3: Rebuild all pages with new IDs
    final dirtyGraph = <NghPagePtr, NghGraphPage>{};
    final dirtyPq = <NghPagePtr, NghPqCodePage>{};
    final dirtyRaw = <NghPagePtr, NghRawVectorPage>{};
    final localGraphCache = <int, NghGraphPage>{};
    final localPqCache = <int, NghPqCodePage>{};
    final localRawCache = <int, NghRawVectorPage>{};

    for (int newId = 0; newId < bfsOrder.length; newId++) {
      final y14 = yc.maybeYield();
      if (y14 != null) await y14;
      final oldId = bfsOrder[newId];

      // Read old graph node
      final oldPartition =
          meta.graphPartitionForNode(oldId, _dataStore.configuredPageSize);
      final oldPage =
          meta.graphLocalPageForNode(oldId, _dataStore.configuredPageSize);
      final oldSlot =
          meta.graphSlotForNode(oldId, _dataStore.configuredPageSize);
      final oldGraphPage = await _partitionManager.readGraphPage(
          table, indexUid, meta, oldPartition, oldPage,
          localCache: localGraphCache);

      final node = oldSlot < oldGraphPage.slots.length
          ? oldGraphPage.slots[oldSlot]
          : null;
      if (node == null || node.isDeleted) continue;

      // Remap neighbor IDs
      final remappedNeighbors = Uint32List(meta.maxDegree);
      int degree = 0;
      for (int j = 0; j < node.actualDegree; j++) {
        final nOldId = node.neighbors[j];
        if (nOldId < totalNodes && oldToNew[nOldId] >= 0) {
          remappedNeighbors[degree++] = oldToNew[nOldId];
        }
      }

      // Write to new position
      final newPartition =
          meta.graphPartitionForNode(newId, _dataStore.configuredPageSize);
      final newPage =
          meta.graphLocalPageForNode(newId, _dataStore.configuredPageSize);
      final newSlot =
          meta.graphSlotForNode(newId, _dataStore.configuredPageSize);
      final newGraphPageKey = newPartition << 20 | newPage;

      var targetPage = localGraphCache[newGraphPageKey];
      targetPage ??= NghGraphPage.empty(
          maxDegree: meta.maxDegree,
          slotCount: meta.nodesPerGraphPage(_dataStore.configuredPageSize));

      if (newSlot < targetPage.slots.length) {
        targetPage.slots[newSlot].flags = node.flags;
        targetPage.slots[newSlot].actualDegree = degree;
        targetPage.slots[newSlot].neighbors.setAll(0, remappedNeighbors);
      }
      localGraphCache[newGraphPageKey] = targetPage;
      dirtyGraph[NghPagePtr(NghDataCategory.graph, newPartition, newPage)] =
          targetPage;

      // Copy PQ code: old slot → new slot
      final oldPqPartition =
          meta.pqPartitionForNode(oldId, _dataStore.configuredPageSize);
      final oldPqPage =
          meta.pqLocalPageForNode(oldId, _dataStore.configuredPageSize);
      final oldPqSlot =
          meta.pqSlotForNode(oldId, _dataStore.configuredPageSize);
      final oldPqCodePage = await _partitionManager.readPqCodePage(
          table, indexUid, meta, oldPqPartition, oldPqPage,
          localCache: localPqCache);
      final pqCode = oldPqCodePage.getCode(oldPqSlot);

      final newPqPartition =
          meta.pqPartitionForNode(newId, _dataStore.configuredPageSize);
      final newPqPage =
          meta.pqLocalPageForNode(newId, _dataStore.configuredPageSize);
      final newPqSlot =
          meta.pqSlotForNode(newId, _dataStore.configuredPageSize);
      final newPqKey = newPqPartition << 20 | newPqPage;
      var targetPq = localPqCache[newPqKey];
      targetPq ??= NghPqCodePage.empty(
          pqSubspaces: meta.pqSubspaces,
          capacity: meta.vectorsPerPqPage(_dataStore.configuredPageSize));
      targetPq.setCode(newPqSlot, pqCode);
      localPqCache[newPqKey] = targetPq;
      dirtyPq[NghPagePtr(NghDataCategory.pqCode, newPqPartition, newPqPage)] =
          targetPq;

      // Copy raw vector: old slot → new slot
      final oldRawPartition =
          meta.rawVectorPartitionForNode(oldId, _dataStore.configuredPageSize);
      final oldRawPage =
          meta.rawVectorLocalPageForNode(oldId, _dataStore.configuredPageSize);
      final oldRawSlot =
          meta.rawVectorSlotForNode(oldId, _dataStore.configuredPageSize);
      final oldRawVecPage = await _partitionManager.readRawVectorPage(
          table, indexUid, meta, oldRawPartition, oldRawPage);
      final rawVec = oldRawVecPage.getVectorAsFloat32(oldRawSlot);

      final newRawPartition =
          meta.rawVectorPartitionForNode(newId, _dataStore.configuredPageSize);
      final newRawPage =
          meta.rawVectorLocalPageForNode(newId, _dataStore.configuredPageSize);
      final newRawSlot =
          meta.rawVectorSlotForNode(newId, _dataStore.configuredPageSize);
      final newRawKey = newRawPartition << 20 | newRawPage;

      var targetRaw = localRawCache[newRawKey];
      targetRaw ??= NghRawVectorPage.empty(
          dimensions: meta.dimensions,
          precisionIndex: meta.precision.index,
          capacity: meta.vectorsPerRawPage(_dataStore.configuredPageSize));

      targetRaw.setVectorFromFloat32(newRawSlot, rawVec);
      localRawCache[newRawKey] = targetRaw;
      dirtyRaw[NghPagePtr(
          NghDataCategory.rawVector, newRawPartition, newRawPage)] = targetRaw;
    }

    // Phase 4: Flush and update meta
    final newMedoid = oldToNew[meta.medoidNodeId];
    meta = meta.copyWith(
      medoidNodeId: newMedoid >= 0 ? newMedoid : 0,
      nextNodeId: bfsOrder.length,
      deletedCount: 0, // compacted all tombstones during reorder
    );

    meta = await _partitionManager.writeChanges(
      table: table,
      indexUid: indexUid,
      meta: meta,
      dirtyGraphPages: dirtyGraph,
      dirtyPqCodePages: dirtyPq,
      dirtyRawVectorPages: dirtyRaw,
    );

    // Phase 5: Rebuild nodeId ↔ PK mapping with new IDs
    // Requires reading old mappings and writing new ones
    meta = _ensureMappingMetas(meta, table);
    final nid2pkDeltas = <DataBlockEntry>[];
    final pk2nidDeltas = <DataBlockEntry>[];

    for (int newId = 0; newId < bfsOrder.length; newId++) {
      final y15 = yc.maybeYield();
      if (y15 != null) await y15;
      final oldId = bfsOrder[newId];
      if (oldToNew[oldId] < 0) continue;

      // Read old PK
      final pk = await _lookupPkByNodeId(table, meta, oldId);
      if (pk == null) continue;

      // Delete old mappings
      nid2pkDeltas.add(
          DataBlockEntry(_encodeNodeIdKey(oldId), Uint8List.fromList([1])));
      pk2nidDeltas.add(DataBlockEntry(
          Uint8List.fromList(utf8.encode(pk)), Uint8List.fromList([1])));

      // Insert new mappings
      nid2pkDeltas
          .add(DataBlockEntry(_encodeNodeIdKey(newId), _encodeUniqueValue(pk)));
      pk2nidDeltas.add(DataBlockEntry(Uint8List.fromList(utf8.encode(pk)),
          _encodeUniqueValue(newId.toString())));
    }

    if (nid2pkDeltas.isNotEmpty) {
      await _dataStore.indexTreePartitionManager?.writeChanges(
        table: table,
        indexUid: meta.nodeIdToPkMeta!.indexUid,
        indexMeta: meta.nodeIdToPkMeta!,
        deltas: nid2pkDeltas,
      );
      await _dataStore.indexTreePartitionManager?.writeChanges(
        table: table,
        indexUid: meta.pkToNodeIdMeta!.indexUid,
        indexMeta: meta.pkToNodeIdMeta!,
        deltas: pk2nidDeltas,
      );
    }

    await _persistMeta(table, indexUid, meta);
    _vectorCache.putMeta(table, indexUid, meta);
    _partitionManager.clearFullyCachedForIndex(table.tableUid, indexUid);
    _partitionManager.clearPageCacheForIndex(table.tableUid, indexUid);
    return true;
  }

  /// Helper: load neighbors for reorder (bypasses deletion check).
  Future<Uint32List?> _loadNeighborsForReorder(TableContext table,
      IndexUid indexUid, NghIndexMeta meta, int nodeId) async {
    final partitionNo =
        meta.graphPartitionForNode(nodeId, _dataStore.configuredPageSize);
    final pageNo =
        meta.graphLocalPageForNode(nodeId, _dataStore.configuredPageSize);
    final slot = meta.graphSlotForNode(nodeId, _dataStore.configuredPageSize);
    final page = await _partitionManager.readGraphPage(
        table, indexUid, meta, partitionNo, pageNo);
    if (slot >= page.slots.length) return null;
    final node = page.slots[slot];
    if (node.isDeleted || node.actualDegree == 0) return null;
    return node.neighbors.sublist(0, node.actualDegree);
  }

  // =====================================================================
  // Cache Management
  // =====================================================================

  /// Total estimated cache size (bytes).
  int getCurrentCacheSize() {
    return _vectorCache.estimatedSizeBytes +
        _partitionManager.getCurrentPageCacheSize();
  }

  /// Evict caches under memory pressure.
  Future<void> evictCache({double ratio = 0.3}) async {
    await _vectorCache.evict(ratio: ratio);
    await _partitionManager.evictPageCache(ratio: ratio);
  }

  /// Clear all caches for a table.
  void clearCacheForTable(TableUid tableUid) {
    _vectorCache.clearForTable(tableUid);
    _partitionManager.clearPageCacheForTable(tableUid);
  }

  /// Clear all caches for a specific index.
  void clearCacheForIndex(TableUid tableUid, IndexUid indexUid) {
    _vectorCache.clearForIndex(tableUid, indexUid);
    _partitionManager.clearFullyCachedForIndex(tableUid, indexUid);
    _partitionManager.clearPageCacheForIndex(tableUid, indexUid);
  }

  /// Clear all caches.
  Future<void> dispose() async {
    // Wait for all ongoing metadata loading
    if (_metaLoadingFutures.isNotEmpty) {
      try {
        await Future.wait(_metaLoadingFutures.values);
      } catch (_) {}
    }
    await _partitionManager.dispose();
    _metaLoadingFutures.clear();
    _vectorCache.clear();
    _partitionManager.clearPageCacheSync();
  }

  // =====================================================================
  // nodeId ↔ PK Persistent B+Tree Mapping
  // =====================================================================

  /// Ensure mapping B+Tree IndexMeta objects exist in [meta].
  NghIndexMeta _ensureMappingMetas(NghIndexMeta meta, TableContext table) {
    bool changed = false;
    IndexMeta? nid2pk = meta.nodeIdToPkMeta;
    IndexMeta? pk2nid = meta.pkToNodeIdMeta;
    final tableUid = table.tableUid;

    if (nid2pk == null) {
      nid2pk = IndexMeta.createEmpty(
        indexUid: meta.nid2pkIndexUid,
        tableUid: tableUid,
        isUnique: true,
      );
      changed = true;
    }
    if (pk2nid == null) {
      pk2nid = IndexMeta.createEmpty(
        indexUid: meta.pk2nidIndexUid,
        tableUid: tableUid,
        isUnique: true,
      );
      changed = true;
    }
    if (changed) {
      meta = meta.copyWith(nodeIdToPkMeta: nid2pk, pkToNodeIdMeta: pk2nid);
    }
    return meta;
  }

  /// Batch-write nodeId ↔ PK mappings to dual B+Trees.
  ///
  /// For inserts: [startNodeId] is the first allocated nodeId, [pks] aligned.
  /// For deletes: [deleteNodeIds] and [pks] aligned; [startNodeId] is ignored.
  Future<NghIndexMeta> _writeMappings({
    required TableContext table,
    required NghIndexMeta meta,
    required int startNodeId,
    required List<String> pks,
    required bool isDelete,
    List<int>? deleteNodeIds,
    BatchContext? batchContext,
    int? concurrency,
  }) async {
    if (pks.isEmpty) return meta;

    final nid2pkDeltas = <DataBlockEntry>[];
    final pk2nidDeltas = <DataBlockEntry>[];
    final mapYc = YieldController(
      'VectorIndexManager._writeMappings',
      checkInterval: 100,
      budgetMs: 30,
    );

    for (int i = 0; i < pks.length; i++) {
      final y16 = mapYc.maybeYield();
      if (y16 != null) await y16;
      final nodeId = isDelete ? deleteNodeIds![i] : startNodeId + i;
      final pk = pks[i];
      final nodeIdKey = _encodeNodeIdKey(nodeId);
      final pkKey = MemComparableKey.encodeTextLex(pk);

      if (isDelete) {
        // Tombstone marker: [1]
        final deleteVal = Uint8List.fromList([1]);
        nid2pkDeltas.add(DataBlockEntry(nodeIdKey, deleteVal));
        pk2nidDeltas.add(DataBlockEntry(pkKey, deleteVal));
      } else {
        // Insert value: [0][utf8(value)] — compatible with lookupUniquePrimaryKey
        nid2pkDeltas.add(DataBlockEntry(nodeIdKey, _encodeUniqueValue(pk)));
        pk2nidDeltas
            .add(DataBlockEntry(pkKey, _encodeUniqueValue(nodeId.toString())));
      }
    }

    // Write both mappings in parallel — no data dependency between them.
    var nid2pkMeta = meta.nodeIdToPkMeta!;
    var pk2nidMeta = meta.pkToNodeIdMeta!;

    await Future.wait([
      _dataStore.indexTreePartitionManager?.writeChanges(
            table: table,
            indexUid: nid2pkMeta.indexUid,
            indexMeta: nid2pkMeta,
            deltas: nid2pkDeltas,
            batchContext: batchContext,
            concurrency: concurrency,
          ) ??
          Future.value(),
      _dataStore.indexTreePartitionManager?.writeChanges(
            table: table,
            indexUid: pk2nidMeta.indexUid,
            indexMeta: pk2nidMeta,
            deltas: pk2nidDeltas,
            batchContext: batchContext,
            concurrency: concurrency,
          ) ??
          Future.value(),
    ]);

    // Re-read the updated metas in parallel
    final metaResults = await Future.wait([
      _dataStore.indexManager
              ?.getIndexMeta(table.tableUid, meta.nid2pkIndexUid) ??
          Future.value(nid2pkMeta),
      _dataStore.indexManager
              ?.getIndexMeta(table.tableUid, meta.pk2nidIndexUid) ??
          Future.value(pk2nidMeta),
    ]);
    nid2pkMeta = metaResults[0] ?? nid2pkMeta;
    pk2nidMeta = metaResults[1] ?? pk2nidMeta;

    return meta.copyWith(
        nodeIdToPkMeta: nid2pkMeta, pkToNodeIdMeta: pk2nidMeta);
  }

  Future<String?> _lookupPkByNodeId(
      TableContext table, NghIndexMeta meta, int nodeId) async {
    final nid2pk = meta.nodeIdToPkMeta;
    if (nid2pk == null || nid2pk.btreeFirstLeaf.isNull) return null;
    final pk =
        await _dataStore.indexTreePartitionManager?.lookupUniquePrimaryKey(
      table: table,
      indexUid: nid2pk.indexUid,
      meta: nid2pk,
      uniqueKey: _encodeNodeIdKey(nodeId),
    );
    return pk;
  }

  /// Look up nodeId by PK via the reverse B+Tree (disk, with LRU page cache).
  Future<int?> _lookupNodeIdByPk(
      TableContext table, NghIndexMeta meta, String pk) async {
    final pk2nid = meta.pkToNodeIdMeta;
    if (pk2nid == null || pk2nid.btreeFirstLeaf.isNull) return null;
    final result =
        await _dataStore.indexTreePartitionManager?.lookupUniquePrimaryKey(
      table: table,
      indexUid: pk2nid.indexUid,
      meta: pk2nid,
      uniqueKey: MemComparableKey.encodeTextLex(pk),
    );
    if (result == null) return null;
    return int.tryParse(result);
  }

  /// Encode nodeId as 4-byte big-endian (naturally memcomparable for unsigned).
  Uint8List _encodeNodeIdKey(int nodeId) {
    return MemComparableKey.encodeInt64(nodeId);
  }

  /// Encode a unique-index value: [0x00][utf8(value)].
  /// Compatible with [IndexTreePartitionManager.lookupUniquePrimaryKey].
  Uint8List _encodeUniqueValue(String value) {
    final encoded = utf8.encode(value);
    final result = Uint8List(1 + encoded.length);
    result[0] = 0; // exists marker
    result.setRange(1, result.length, encoded);
    return result;
  }

  // =====================================================================
  // Private Helpers
  // =====================================================================

  /// Convert double list to Float32List, ensuring correct dimensions.
  Float32List _toFloat32(List<double> values, int dimensions) {
    final f32 = Float32List(dimensions);
    final len = min(values.length, dimensions);
    for (int i = 0; i < len; i++) {
      f32[i] = values[i];
    }
    return f32;
  }

  /// Normalise a float32 vector to unit length.
  Float32List _normalizeFloat32(Float32List v) {
    double mag = 0;
    for (int i = 0; i < v.length; i++) {
      mag += v[i] * v[i];
    }
    mag = sqrt(mag);
    if (mag == 0) return v;
    final result = Float32List(v.length);
    final inv = 1.0 / mag;
    for (int i = 0; i < v.length; i++) {
      result[i] = v[i] * inv;
    }
    return result;
  }

  /// Convert distance to similarity score in [0, 1].
  double _distanceToScore(double distance, VectorDistanceMetric metric) {
    switch (metric) {
      case VectorDistanceMetric.l2:
        // L2 distance → score: 1 / (1 + distance)
        return 1.0 / (1.0 + distance);
      case VectorDistanceMetric.innerProduct:
        // Inner product was negated for min-heap; negate back and sigmoid
        return 1.0 / (1.0 + exp(-(-distance)));
      case VectorDistanceMetric.cosine:
        // Cosine distance = 1 - similarity → score = 1 - distance
        return (1.0 - distance).clamp(0.0, 1.0);
    }
  }
}
