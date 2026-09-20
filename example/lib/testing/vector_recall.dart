import 'dart:math';
import 'dart:typed_data';

import 'package:tostore/tostore.dart';

/// Example embeddings with known nearest neighbors for Recall@K.
///
/// Consecutive [groupSize] records share a local neighborhood. Query vectors
/// are not stored. Sequential primary keys from the example insert path.
class ExampleVectorCorpus {
  ExampleVectorCorpus._();

  /// Neighbors per group. Covers industry-standard Recall@10 with headroom.
  static const int groupSize = 16;

  /// Ray spacing. 10th neighbor of the query is still well above random
  /// max-cosine at 5M / 128-d (≈ 0.49).
  static const double rayStep = 0.16;

  /// Query offset on the group ray. Members sit at t = ±0.08, ±0.24, …
  static const double queryT = -0.04;

  static const String labelPrefix = 'nghgt:';

  static const Set<String> stampFields = {
    'name',
    'label',
    'document_title',
    'title',
  };

  static int groupIdForIndex(int index) => (index - 1) ~/ groupSize;

  static int memberIdForIndex(int index) => (index - 1) % groupSize;

  static double memberT(int memberId) =>
      (memberId - (groupSize - 1) / 2.0) * rayStep;

  static String recordLabel(int index) {
    final g = groupIdForIndex(index);
    final m = memberIdForIndex(index);
    return '$labelPrefix'
        'g${g.toString().padLeft(8, '0')}:'
        'm${m.toString().padLeft(2, '0')}';
  }

  static bool isExampleLabel(String? value) => indexFromLabel(value) != null;

  /// 1-based generation index stamped in [recordLabel], or null.
  ///
  /// Batch-insert rounds and appends do not always start at index 1.
  /// Recall@K uses this stamp instead of assuming the minimum primary key
  /// is generation index 1.
  static int? indexFromLabel(String? value) {
    if (value == null || !value.startsWith(labelPrefix)) return null;
    final body = value.substring(labelPrefix.length);
    final sep = body.indexOf(':m');
    if (sep < 2 || !body.startsWith('g')) return null;
    final groupId = int.tryParse(body.substring(1, sep));
    final memberId = int.tryParse(body.substring(sep + 2));
    if (groupId == null || memberId == null) return null;
    if (groupId < 0 || memberId < 0 || memberId >= groupSize) return null;
    return groupId * groupSize + memberId + 1;
  }

  static String? labelFieldName(TableSchema schema) {
    for (final name in stampFields) {
      for (final field in schema.fields) {
        if (field.name == name && field.type == DataType.text) {
          return field.name;
        }
      }
    }
    return null;
  }

  /// Member ids nearest to the query first (unique nearest neighbor at member 7).
  static List<int> neighborMemberIds() {
    final ids = List<int>.generate(groupSize, (m) => m);
    ids.sort((a, b) {
      final c =
          (memberT(a) - queryT).abs().compareTo((memberT(b) - queryT).abs());
      if (c != 0) return c;
      return a.compareTo(b);
    });
    return ids;
  }

  static VectorData memberVector({
    required int index,
    required int dimensions,
  }) {
    final groupId = groupIdForIndex(index);
    final memberId = memberIdForIndex(index);
    final (center, dir) = _cachedFrame(groupId, dimensions);
    final t = memberT(memberId);
    final values = List<double>.generate(
      dimensions,
      (d) => center[d] + t * dir[d],
    );
    _normalizeInPlace(values);
    return VectorData(values);
  }

  /// Query for [groupId]: off-center on the group ray (not stored).
  static VectorData groupQuery(int groupId, int dimensions) {
    final (center, dir) = _cachedFrame(groupId, dimensions);
    final values = List<double>.generate(
      dimensions,
      (d) => center[d] + queryT * dir[d],
    );
    _normalizeInPlace(values);
    return VectorData(values);
  }

  /// Sequential dense PKs.
  ///
  /// Generation index `i` (1-based) maps to `minPk + i - originIndex`.
  /// [originIndex] is the generation index stored on the minimum primary key.
  static String pkForMember({
    required int minPk,
    required int groupId,
    required int memberId,
    int originIndex = 1,
  }) {
    final index = groupId * groupSize + memberId + 1;
    return (minPk + index - originIndex).toString();
  }

  static List<String> expectedPks({
    required int minPk,
    required int groupId,
    required int k,
    int originIndex = 1,
  }) {
    final members = neighborMemberIds();
    final n = min(k, members.length);
    return [
      for (var i = 0; i < n; i++)
        pkForMember(
          minPk: minPk,
          groupId: groupId,
          memberId: members[i],
          originIndex: originIndex,
        ),
    ];
  }

  /// Last orthonormal frame. Sequential inserts reuse one frame per group
  /// (16 members), so bulk generation does not redo the Gaussian basis.
  static int? _cachedFrameGroup;
  static int? _cachedFrameDims;
  static List<double>? _cachedCenter;
  static List<double>? _cachedDir;

  static (List<double>, List<double>) _cachedFrame(
    int groupId,
    int dimensions,
  ) {
    final center = _cachedCenter;
    final dir = _cachedDir;
    if (center != null &&
        dir != null &&
        _cachedFrameGroup == groupId &&
        _cachedFrameDims == dimensions) {
      return (center, dir);
    }
    final frame = _frame(groupId, dimensions);
    _cachedFrameGroup = groupId;
    _cachedFrameDims = dimensions;
    _cachedCenter = frame.$1;
    _cachedDir = frame.$2;
    return frame;
  }

  static (List<double>, List<double>) _frame(int groupId, int dimensions) {
    final rng = Random(groupId * 10007 + dimensions);
    final center = _gaussian(rng, dimensions);
    _normalizeInPlace(center);
    final dir = _gaussian(rng, dimensions);
    var dot = 0.0;
    for (var i = 0; i < dimensions; i++) {
      dot += center[i] * dir[i];
    }
    for (var i = 0; i < dimensions; i++) {
      dir[i] -= dot * center[i];
    }
    var nSq = 0.0;
    for (final x in dir) {
      nSq += x * x;
    }
    if (nSq < 1e-12) {
      for (var i = 0; i < dimensions; i++) {
        dir[i] = i == 0 ? 1.0 : 0.0;
      }
      var d2 = 0.0;
      for (var i = 0; i < dimensions; i++) {
        d2 += center[i] * dir[i];
      }
      for (var i = 0; i < dimensions; i++) {
        dir[i] -= d2 * center[i];
      }
      nSq = 0.0;
      for (final x in dir) {
        nSq += x * x;
      }
    }
    final n = sqrt(nSq);
    for (var i = 0; i < dimensions; i++) {
      dir[i] /= n;
    }
    return (center, dir);
  }

  static List<double> _gaussian(Random rng, int dimensions) {
    return List<double>.generate(dimensions, (_) {
      final u1 = rng.nextDouble().clamp(1e-10, 1.0);
      final u2 = rng.nextDouble();
      return sqrt(-2.0 * log(u1)) * cos(2.0 * pi * u2);
    });
  }

  static void _normalizeInPlace(List<double> values) {
    var nSq = 0.0;
    for (final v in values) {
      nSq += v * v;
    }
    final n = sqrt(nSq);
    if (n <= 0) return;
    for (var i = 0; i < values.length; i++) {
      values[i] /= n;
    }
  }
}

/// Recall@K harness for the example vector tables.
class VectorRecallHarness {
  VectorRecallHarness._();

  static int normalizeDepth(int? searchDepth) {
    final raw = searchDepth ?? VectorIndexConfig.defaultSearchDepth;
    return raw < 1 ? VectorIndexConfig.defaultSearchDepth : raw;
  }

  /// Short suite-table cell with measured Recall@K.
  static String suiteHighlight({
    required bool canScore,
    required double recallFraction,
    required int searchDepth,
  }) {
    if (!canScore) return 'n/a';
    return '${(recallFraction * 100).toStringAsFixed(0)}% @ $searchDepth';
  }

  static const int maxRecallQueries = 200;
  static const int maxIdentityProbes = 32;

  static int resolveQueryCount({
    required int requested,
    required int completeGroups,
  }) {
    if (requested <= 0 || completeGroups <= 0) return 0;
    return min(requested, min(maxRecallQueries, completeGroups));
  }

  /// Fraction of the K known neighbors that appear in the search result.
  static double overlapRecall({
    required List<String> annPks,
    required Set<String> gtPks,
    required int k,
  }) {
    if (k <= 0) return 0;
    var hits = 0;
    final n = min(k, annPks.length);
    for (var i = 0; i < n; i++) {
      if (gtPks.contains(annPks[i])) hits++;
    }
    return hits / k;
  }

  /// Score Recall@K at [searchDepth], then measure ANN latency.
  static Future<VectorRecallReport?> evaluate({
    required ToStore db,
    required String tableName,
    required int topK,
    required int searchDepth,
    required int requestedQueries,
    int querySeedOffset = 0,
    bool runIdentityDiagnostic = true,
    Future<void> Function()? yieldUi,
    void Function(String message)? onLog,
  }) async {
    final schema = await db.getTableSchema(tableName);
    if (schema == null) {
      onLog?.call('Recall failed: schema for "$tableName" not found.');
      return null;
    }

    FieldSchema? vectorField;
    for (final field in schema.fields) {
      if (field.type == DataType.vector) {
        vectorField = field;
        break;
      }
    }
    if (vectorField == null || vectorField.name.isEmpty) {
      onLog?.call('Recall failed: no vector field in "$tableName".');
      return null;
    }

    final dims = vectorField.vectorConfig?.dimensions ?? 0;
    if (dims <= 0) {
      onLog?.call(
          'Recall failed: vector dimensions not configured for "${vectorField.name}".');
      return null;
    }

    IndexSchema? vectorIndex;
    for (final idx in schema.indexes) {
      if (idx.type == IndexType.vector &&
          idx.fields.contains(vectorField.name)) {
        vectorIndex = idx;
        break;
      }
    }
    if (vectorIndex == null) {
      onLog?.call(
        'Warning: no vector index on "${vectorField.name}". '
        'Search will be slower and Recall@K will be low.',
      );
    }
    final metric = vectorIndex?.vectorConfig?.distanceMetric ??
        VectorDistanceMetric.cosine;

    final pkName = schema.primaryKeyConfig.name;
    final setupSw = Stopwatch()..start();
    final corpusSize = await db.query(tableName).count();
    if (corpusSize <= 0) {
      onLog?.call('Recall failed: table "$tableName" is empty.');
      return null;
    }

    final depth = normalizeDepth(searchDepth);
    final isSequentialPk =
        schema.primaryKeyConfig.type == PrimaryKeyType.sequential;

    int? minPk;
    int? maxPk;
    bool hasPkHoles = false;
    if (isSequentialPk) {
      final minRes = await db
          .query(tableName)
          .orderByAsc(pkName)
          .select([pkName]).limit(1);
      final maxRes = await db
          .query(tableName)
          .orderByDesc(pkName)
          .select([pkName]).limit(1);
      minPk = int.tryParse(
          (minRes.data.isEmpty ? null : minRes.data.first[pkName])
                  ?.toString() ??
              '');
      maxPk = int.tryParse(
          (maxRes.data.isEmpty ? null : maxRes.data.first[pkName])
                  ?.toString() ??
              '');
      if (minPk != null && maxPk != null && (maxPk - minPk + 1) != corpusSize) {
        hasPkHoles = true;
      }
    }

    // Stamped example rows (nghgt:g########:m##). The minimum PK is not
    // required to be generation index 1: vector batch-insert rounds use a
    // seed offset, and clear() restarts sequential ids at 1. Generation
    // index i maps to minPk + (i - originIndex). A mismatched end stamp
    // means the span is not one contiguous example corpus.
    int? originIndex;
    final labelField = ExampleVectorCorpus.labelFieldName(schema);
    if (isSequentialPk &&
        minPk != null &&
        maxPk != null &&
        labelField != null) {
      final probe = await db
          .query(tableName)
          .where(pkName, '=', minPk.toString())
          .select([labelField]).limit(1);
      final label =
          probe.data.isEmpty ? null : probe.data.first[labelField]?.toString();
      originIndex = ExampleVectorCorpus.indexFromLabel(label);
      if (originIndex != null && !hasPkHoles) {
        final endProbe = await db
            .query(tableName)
            .where(pkName, '=', maxPk.toString())
            .select([labelField]).limit(1);
        final endLabel = endProbe.data.isEmpty
            ? null
            : endProbe.data.first[labelField]?.toString();
        if (endLabel !=
            ExampleVectorCorpus.recordLabel(originIndex + corpusSize - 1)) {
          originIndex = null;
        }
      }
      // Holes plus a partial first group make PK ranges ambiguous.
      if (originIndex != null &&
          hasPkHoles &&
          ExampleVectorCorpus.memberIdForIndex(originIndex) != 0) {
        originIndex = null;
      }
    }

    if (originIndex == null) {
      onLog?.call(
        'Notice: "$tableName" does not have example vector data for Recall@K. '
        'Measuring latency and Self-Recall only.',
      );
      return _latencyFallback(
        db: db,
        tableName: tableName,
        pkName: pkName,
        vectorFieldName: vectorField.name,
        dims: dims,
        metric: metric,
        topK: topK,
        depth: depth,
        requestedQueries: requestedQueries,
        corpusSize: corpusSize,
        isSequentialPk: isSequentialPk,
        minPk: minPk,
        maxPk: maxPk,
        setupSw: setupSw,
        querySeedOffset: querySeedOffset,
        runIdentityDiagnostic: runIdentityDiagnostic,
        yieldUi: yieldUi,
        onLog: onLog,
      );
    }

    final originPk = minPk!;
    final stampedOrigin = originIndex;
    final originMember = ExampleVectorCorpus.memberIdForIndex(stampedOrigin);
    final lastIndex = hasPkHoles ? null : stampedOrigin + corpusSize - 1;
    final firstComplete = originMember == 0
        ? stampedOrigin
        : stampedOrigin + (ExampleVectorCorpus.groupSize - originMember);
    final lastComplete = lastIndex == null
        ? null
        : (lastIndex % ExampleVectorCorpus.groupSize == 0
            ? lastIndex
            : lastIndex - (lastIndex % ExampleVectorCorpus.groupSize));
    final completeGroupCount = hasPkHoles
        ? min(
            corpusSize ~/ ExampleVectorCorpus.groupSize,
            (maxPk! - originPk + 1) ~/ ExampleVectorCorpus.groupSize,
          )
        : (lastComplete == null || lastComplete < firstComplete
            ? 0
            : (lastComplete - firstComplete + 1) ~/
                ExampleVectorCorpus.groupSize);
    final startGroup = ExampleVectorCorpus.groupIdForIndex(firstComplete);
    if (completeGroupCount <= 0) {
      onLog?.call(
        'Recall failed: need at least ${ExampleVectorCorpus.groupSize} vectors '
        'to measure Recall@K.',
      );
      return null;
    }

    if (hasPkHoles) {
      onLog?.call(
        'Notice: some rows are missing from this table. '
        'Checking remaining data before scoring Recall@K...',
      );
    }

    final recallK = min(topK, ExampleVectorCorpus.groupSize);
    final queryCount = resolveQueryCount(
      requested: requestedQueries,
      completeGroups: completeGroupCount,
    );
    if (queryCount <= 0 || recallK <= 0) {
      onLog?.call('Recall failed: nothing to evaluate.');
      return null;
    }

    final rng = Random(6262 + querySeedOffset);
    final groupIds = <int>{};
    int attempts = 0;
    final maxAttempts = queryCount * 5;

    while (groupIds.length < queryCount && attempts < maxAttempts) {
      attempts++;
      final candidateGroup = startGroup + rng.nextInt(completeGroupCount);
      if (groupIds.contains(candidateGroup)) continue;

      if (hasPkHoles) {
        // Light check to ensure the sampled group has all 16 members.
        final groupStartPk = int.parse(ExampleVectorCorpus.pkForMember(
          minPk: originPk,
          groupId: candidateGroup,
          memberId: 0,
          originIndex: stampedOrigin,
        ));
        final groupEndPk = groupStartPk + ExampleVectorCorpus.groupSize - 1;
        final memberCount = await db
            .query(tableName)
            .where(pkName, '>=', groupStartPk.toString())
            .where(pkName, '<=', groupEndPk.toString())
            .count();
        if (memberCount != ExampleVectorCorpus.groupSize) {
          continue; // Skip damaged group
        }
      }
      groupIds.add(candidateGroup);
    }

    final groups = groupIds.toList(growable: false);
    if (groups.isEmpty) {
      onLog?.call(
        'Notice: not enough matching data remains to score Recall@K. '
        'Measuring latency and Self-Recall only.',
      );
      return _latencyFallback(
        db: db,
        tableName: tableName,
        pkName: pkName,
        vectorFieldName: vectorField.name,
        dims: dims,
        metric: metric,
        topK: topK,
        depth: depth,
        requestedQueries: requestedQueries,
        corpusSize: corpusSize,
        isSequentialPk: isSequentialPk,
        minPk: minPk,
        maxPk: maxPk,
        setupSw: setupSw,
        querySeedOffset: querySeedOffset,
        runIdentityDiagnostic: runIdentityDiagnostic,
        yieldUi: yieldUi,
        onLog: onLog,
      );
    }

    final queries = [
      for (final g in groups) ExampleVectorCorpus.groupQuery(g, dims),
    ];
    setupSw.stop();

    onLog?.call(
      'Scoring Recall@$recallK on ${groups.length} queries '
      '($corpusSize vectors, ${dims}D ${metric.name})...',
    );

    final annLatenciesMs = <double>[];
    var neighborHits = 0;
    var top1Hits = 0;
    final perQueryRecall = <double>[];

    for (var i = 0; i < groups.length; i++) {
      final querySw = Stopwatch()..start();
      final results = await db.vectorSearch(
        tableName,
        fieldName: vectorField.name,
        queryVector: queries[i],
        topK: topK,
        searchDepth: depth,
      );
      querySw.stop();
      annLatenciesMs.add(querySw.elapsedMicroseconds / 1000.0);

      final annPks = [for (final r in results) r.primaryKey];
      final gtPks = ExampleVectorCorpus.expectedPks(
        minPk: originPk,
        groupId: groups[i],
        k: recallK,
        originIndex: stampedOrigin,
      );
      final gtSet = gtPks.toSet();
      var hits = 0;
      final nAnn = min(topK, annPks.length);
      for (var r = 0; r < nAnn; r++) {
        if (gtSet.contains(annPks[r])) hits++;
      }
      neighborHits += hits;
      perQueryRecall.add(
        overlapRecall(annPks: annPks, gtPks: gtSet, k: recallK),
      );

      if (gtPks.isNotEmpty &&
          annPks.isNotEmpty &&
          annPks.first == gtPks.first) {
        top1Hits++;
      }

      if (groups.length >= 20 &&
          (i + 1) % max(1, groups.length ~/ 5) == 0 &&
          (i + 1) < groups.length) {
        onLog?.call('⏳ Recall@K: ${i + 1}/${groups.length}...');
        await yieldUi?.call();
      }
    }

    var identityHits = 0;
    var identityProbes = 0;
    final identityLatenciesMs = <double>[];
    if (runIdentityDiagnostic) {
      identityProbes = min(
        maxIdentityProbes,
        groups.length * ExampleVectorCorpus.groupSize,
      );
      onLog?.call(
        'Self-Recall: checking $identityProbes stored vectors...',
      );
      final idRng = Random(4242 + querySeedOffset);
      for (var i = 0; i < identityProbes; i++) {
        late final int groupId;
        late final int memberId;
        if (hasPkHoles) {
          groupId = groups[idRng.nextInt(groups.length)];
          memberId = idRng.nextInt(ExampleVectorCorpus.groupSize);
        } else {
          final index = stampedOrigin + idRng.nextInt(corpusSize);
          groupId = ExampleVectorCorpus.groupIdForIndex(index);
          memberId = ExampleVectorCorpus.memberIdForIndex(index);
        }
        final vec = ExampleVectorCorpus.memberVector(
          index: groupId * ExampleVectorCorpus.groupSize + memberId + 1,
          dimensions: dims,
        );
        final pk = ExampleVectorCorpus.pkForMember(
          minPk: originPk,
          groupId: groupId,
          memberId: memberId,
          originIndex: stampedOrigin,
        );
        final querySw = Stopwatch()..start();
        final results = await db.vectorSearch(
          tableName,
          fieldName: vectorField.name,
          queryVector: vec,
          topK: 1,
          searchDepth: depth,
        );
        querySw.stop();
        identityLatenciesMs.add(querySw.elapsedMicroseconds / 1000.0);
        if (results.isNotEmpty && results.first.primaryKey == pk) {
          identityHits++;
        }
      }
    }

    final evalQueryCount = groups.length;
    final recallAtK = evalQueryCount == 0
        ? 0.0
        : perQueryRecall.reduce((a, b) => a + b) / evalQueryCount;

    return VectorRecallReport(
      tableName: tableName,
      corpusSize: corpusSize,
      dimensions: dims,
      metric: metric,
      topK: recallK,
      requestedTopK: topK,
      searchDepth: depth,
      queryCount: evalQueryCount,
      requestedQueries: requestedQueries,
      recallAtK: recallAtK,
      top1HitRate: evalQueryCount == 0 ? 0.0 : top1Hits / evalQueryCount,
      neighborHits: neighborHits,
      neighborPossible: evalQueryCount * recallK,
      identityAt1: identityProbes == 0 ? null : identityHits / identityProbes,
      identityProbes: identityProbes,
      identityHits: identityHits,
      annLatenciesMs: annLatenciesMs,
      identityLatenciesMs: identityLatenciesMs,
      gtElapsedMs: setupSw.elapsedMilliseconds,
      queryVectors: queries,
      canScoreRecall: true,
      completeGroups: completeGroupCount,
    );
  }

  static VectorData? _vectorFromRaw(dynamic raw) {
    if (raw is VectorData) return raw;
    if (raw is Float32List) return VectorData(raw);
    if (raw is Float64List) {
      return VectorData(List<double>.from(raw, growable: false));
    }
    if (raw is Iterable) {
      final list = <double>[];
      for (final n in raw) {
        if (n is! num) return null;
        list.add(n.toDouble());
      }
      return VectorData(list);
    }
    return null;
  }

  static Future<VectorRecallReport> _latencyFallback({
    required ToStore db,
    required String tableName,
    required String pkName,
    required String vectorFieldName,
    required int dims,
    required VectorDistanceMetric metric,
    required int topK,
    required int depth,
    required int requestedQueries,
    required int corpusSize,
    required bool isSequentialPk,
    required int? minPk,
    required int? maxPk,
    required Stopwatch setupSw,
    required int querySeedOffset,
    required bool runIdentityDiagnostic,
    required Future<void> Function()? yieldUi,
    required void Function(String message)? onLog,
  }) async {
    final want = min(requestedQueries, maxRecallQueries);
    final rng = Random(querySeedOffset + 101);
    final sampleDocs = <Map<String, dynamic>>[];

    if (isSequentialPk && minPk != null && maxPk != null && maxPk >= minPk) {
      final span = maxPk - minPk + 1;
      var tries = 0;
      while (sampleDocs.length < want && tries < want * 8) {
        tries++;
        final pk = minPk + rng.nextInt(span);
        final res = await db
            .query(tableName)
            .where(pkName, '=', pk.toString())
            .select([pkName, vectorFieldName]).limit(1);
        if (res.data.isNotEmpty) {
          sampleDocs.add(res.data.first);
        }
      }
    } else {
      sampleDocs.addAll((await db
              .query(tableName)
              .select([pkName, vectorFieldName]).limit(want))
          .data);
    }

    final sampleQueries = <VectorData>[];
    for (final doc in sampleDocs) {
      final v = _vectorFromRaw(doc[vectorFieldName]);
      if (v != null) sampleQueries.add(v);
    }
    while (sampleQueries.length < want) {
      final g = List<double>.generate(dims, (_) {
        final u1 = rng.nextDouble().clamp(1e-10, 1.0);
        final u2 = rng.nextDouble();
        return sqrt(-2.0 * log(u1)) * cos(2.0 * pi * u2);
      });
      var nSq = 0.0;
      for (final x in g) {
        nSq += x * x;
      }
      final n = sqrt(nSq);
      if (n > 0) {
        for (var j = 0; j < dims; j++) {
          g[j] /= n;
        }
      }
      sampleQueries.add(VectorData(g));
    }

    setupSw.stop();
    final annLatenciesMs = <double>[];
    for (var i = 0; i < sampleQueries.length; i++) {
      final querySw = Stopwatch()..start();
      await db.vectorSearch(
        tableName,
        fieldName: vectorFieldName,
        queryVector: sampleQueries[i],
        topK: topK,
        searchDepth: depth,
      );
      querySw.stop();
      annLatenciesMs.add(querySw.elapsedMicroseconds / 1000.0);
      if (want >= 20 && (i + 1) % max(1, want ~/ 5) == 0 && (i + 1) < want) {
        onLog?.call('⏳ Vector searches: ${i + 1}/$want...');
        await yieldUi?.call();
      }
    }

    var identityHits = 0;
    var identityProbes = 0;
    final identityLatenciesMs = <double>[];
    if (runIdentityDiagnostic && sampleDocs.isNotEmpty) {
      identityProbes = min(maxIdentityProbes, sampleDocs.length);
      for (var i = 0; i < identityProbes; i++) {
        final doc = sampleDocs[i];
        final pk = doc[pkName]?.toString();
        final v = _vectorFromRaw(doc[vectorFieldName]);
        if (v == null || pk == null) continue;
        final querySw = Stopwatch()..start();
        final results = await db.vectorSearch(
          tableName,
          fieldName: vectorFieldName,
          queryVector: v,
          topK: 1,
          searchDepth: depth,
        );
        querySw.stop();
        identityLatenciesMs.add(querySw.elapsedMicroseconds / 1000.0);
        if (results.isNotEmpty && results.first.primaryKey == pk) {
          identityHits++;
        }
      }
    }

    return VectorRecallReport(
      tableName: tableName,
      corpusSize: corpusSize,
      dimensions: dims,
      metric: metric,
      topK: topK,
      requestedTopK: topK,
      searchDepth: depth,
      queryCount: sampleQueries.length,
      requestedQueries: requestedQueries,
      recallAtK: 0.0,
      top1HitRate: 0.0,
      neighborHits: 0,
      neighborPossible: 0,
      identityAt1: identityProbes == 0 ? null : identityHits / identityProbes,
      identityProbes: identityProbes,
      identityHits: identityHits,
      annLatenciesMs: annLatenciesMs,
      identityLatenciesMs: identityLatenciesMs,
      gtElapsedMs: setupSw.elapsedMilliseconds,
      queryVectors: sampleQueries,
      canScoreRecall: false,
      completeGroups: 0,
    );
  }
}

class VectorRecallReport {
  final String tableName;
  final int corpusSize;
  final int dimensions;
  final VectorDistanceMetric metric;
  final int topK;
  final int requestedTopK;
  final int searchDepth;
  final int queryCount;
  final int requestedQueries;
  final double recallAtK;
  final double top1HitRate;
  final int neighborHits;
  final int neighborPossible;
  final double? identityAt1;
  final int identityProbes;
  final int identityHits;
  final List<double> annLatenciesMs;
  final List<double> identityLatenciesMs;
  final int gtElapsedMs;
  final List<VectorData> queryVectors;
  final bool canScoreRecall;
  final int completeGroups;

  const VectorRecallReport({
    required this.tableName,
    required this.corpusSize,
    required this.dimensions,
    required this.metric,
    required this.topK,
    required this.requestedTopK,
    required this.searchDepth,
    required this.queryCount,
    required this.requestedQueries,
    required this.recallAtK,
    required this.top1HitRate,
    required this.neighborHits,
    required this.neighborPossible,
    required this.identityAt1,
    required this.identityProbes,
    required this.identityHits,
    required this.annLatenciesMs,
    required this.identityLatenciesMs,
    required this.gtElapsedMs,
    required this.queryVectors,
    this.canScoreRecall = true,
    this.completeGroups = 0,
  });

  String get metricLabel => switch (metric) {
        VectorDistanceMetric.cosine => 'Cosine',
        VectorDistanceMetric.l2 => 'L2',
        VectorDistanceMetric.innerProduct => 'InnerProduct',
      };

  /// Operating-point status for suite tables. Not a recall ceiling.
  String get compactHighlight => VectorRecallHarness.suiteHighlight(
        canScore: canScoreRecall,
        recallFraction: recallAtK,
        searchDepth: searchDepth,
      );

  String get operatingPointNote {
    final where = searchDepth == VectorIndexConfig.defaultSearchDepth
        ? 'default searchDepth=$searchDepth'
        : 'searchDepth=$searchDepth';
    return '$where. Larger searchDepth typically raises recall and latency.';
  }

  String get qualityNote {
    final self = identityAt1 == null
        ? 'Self-Recall=n/a'
        : 'Self-Recall=${(identityAt1! * 100).toStringAsFixed(1)}% '
            '($identityHits/$identityProbes)';
    if (!canScoreRecall) {
      return '$operatingPointNote '
          'Recall@$topK=n/a (example vector data required); $self; queries=$queryCount; corpus=$corpusSize';
    }
    return '$operatingPointNote '
        'Recall@$topK=${(recallAtK * 100).toStringAsFixed(1)}% '
        '($neighborHits/$neighborPossible); '
        'Top-1 Hit Rate=${(top1HitRate * 100).toStringAsFixed(1)}%; '
        '$self; queries=$queryCount; corpus=$corpusSize';
  }
}

/// Standard [searchDepth] points for recall-vs-latency sweeps.
const List<int> vectorSearchDepthSweepPoints = [
  1,
  10,
  20,
  30,
  40,
  50,
  60,
  70,
  80,
  90,
  100,
];

/// Latency stats plus the underlying [VectorRecallReport].
class VectorSearchBenchmarkResult {
  final VectorRecallReport recall;
  final double avgLatencyMs;
  final double p50LatencyMs;
  final double p95LatencyMs;
  final double p99LatencyMs;
  final double qps;
  final int totalSearches;

  const VectorSearchBenchmarkResult({
    required this.recall,
    required this.avgLatencyMs,
    required this.p50LatencyMs,
    required this.p95LatencyMs,
    required this.p99LatencyMs,
    required this.qps,
    required this.totalSearches,
  });

  static VectorSearchBenchmarkResult fromLatencies({
    required VectorRecallReport recall,
    required List<double> latenciesMs,
  }) {
    final sorted = List<double>.from(latenciesMs)..sort();
    final lastIdx = sorted.isEmpty ? 0 : sorted.length - 1;
    final avg =
        sorted.isEmpty ? 0.0 : sorted.reduce((a, b) => a + b) / sorted.length;
    final p50 = sorted.isEmpty
        ? 0.0
        : sorted[(sorted.length * 0.50).floor().clamp(0, lastIdx)];
    final p95 = sorted.isEmpty
        ? 0.0
        : sorted[(sorted.length * 0.95).floor().clamp(0, lastIdx)];
    final p99 = sorted.isEmpty
        ? 0.0
        : sorted[(sorted.length * 0.99).floor().clamp(0, lastIdx)];
    return VectorSearchBenchmarkResult(
      recall: recall,
      avgLatencyMs: avg,
      p50LatencyMs: p50,
      p95LatencyMs: p95,
      p99LatencyMs: p99,
      qps: avg > 0 ? 1000.0 / avg : 0.0,
      totalSearches: sorted.length,
    );
  }

  String _pct(double value) => '${(value * 100).toStringAsFixed(1)}%';

  String sweepTableRow() {
    final recallCol =
        recall.canScoreRecall ? _pct(recall.recallAtK).padLeft(7) : '    n/a';
    final top1Col = recall.canScoreRecall
        ? _pct(recall.top1HitRate).padLeft(8)
        : '     n/a';
    final selfCol = recall.identityAt1 == null
        ? '    n/a'
        : _pct(recall.identityAt1!).padLeft(7);
    return '${recall.searchDepth.toString().padLeft(11)} | '
        '$recallCol | '
        '$top1Col | '
        '$selfCol | '
        '${avgLatencyMs.toStringAsFixed(2).padLeft(6)} | '
        '${p95LatencyMs.toStringAsFixed(2).padLeft(6)} | '
        '${qps.toStringAsFixed(0).padLeft(4)}';
  }
}

/// One compact log block for a multi-depth recall sweep (easy to copy).
String formatVectorDepthSweepSummary({
  required String tableName,
  required int topK,
  required int iterations,
  required List<VectorSearchBenchmarkResult> rows,
}) {
  if (rows.isEmpty) {
    return '[Vector Depth Sweep] No results.';
  }

  final first = rows.first.recall;
  final canScore = rows.any((r) => r.recall.canScoreRecall);
  final depths = rows.map((r) => r.recall.searchDepth).join(',');

  final header = StringBuffer()
    ..writeln('[Vector Depth Sweep] table=$tableName '
        '${first.dimensions}D ${first.metricLabel}, '
        'corpus=${first.corpusSize}, topK=$topK, queries=$iterations')
    ..writeln('depths=$depths'
        '${canScore ? '' : ' (Recall@K n/a — need example vector rows)'}')
    ..writeln(
        'searchDepth | recall@$topK | top1_hit | self_rc | avg_ms | p95_ms | qps');

  for (final row in rows) {
    header.writeln(row.sweepTableRow());
  }

  header.writeln(
      '# top1_hit=true nearest at rank 1; self_rc=own vector returns itself first');

  return header.toString().trimRight();
}
