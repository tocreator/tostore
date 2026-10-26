import 'dart:typed_data';

import '../model/sparse_vector_data.dart';
import '../model/text_query.dart';
import '../model/wal_pointer.dart';
import 'wmbp_constants.dart';
import 'wmbp_scheduler.dart';
import 'wmbp_score.dart';
import 'wmbp_store.dart';
import 'wmbp_tokenizer.dart';
import 'wmbp_window.dart';
import 'yield_controller.dart';

/// In-memory WMBP corpus: pending read cache plus sealed tri-state windows.
class WmbpCorpus implements WmbpPostingSource {
  int _nextDocId = 0;
  int _activeDocs = 0;

  /// Newly minted term ids not yet durable on sealed dict (id → name).
  final Map<int, String> _pendingTermNames = <int, String>{};

  /// Reverse of [_pendingTermNames] for assign / compile.
  final Map<String, int> _pendingTermIds = <String, int>{};

  /// Bounded overlay for sealed-resolved names (avoids reminting after cache miss).
  final Map<String, int> _hotTermIds = <String, int>{};
  static const int _hotTermCap = 65536;
  int _nextTermId = 1;
  final Map<String, int> _pkToDoc = <String, int>{};
  final Map<String, int> _pkSig = <String, int>{};
  final Map<int, _Doc> _docs = <int, _Doc>{};
  final Map<int, _TermChain> _terms = <int, _TermChain>{};
  final Map<int, Uint32List> _masks = <int, Uint32List>{};
  final Map<int, int> _activeCount = <int, int>{};
  final Map<int, _Doc> _pending = <int, _Doc>{};
  final Set<int> _inactive = <int>{};
  final Map<int, WalPointer> _deleteMarks = <int, WalPointer>{};
  int _deleteSeq = 1;
  final Map<int, int> _inactiveWindows = <int, int>{};
  final Set<String> _removedPks = <String>{};

  /// Cold-rev DML deactivations deferred until commit (zero await on DML path).
  final Map<String, WalPointer?> _pendingDeactivatePks =
      <String, WalPointer?>{};
  final Map<String, int> _countsBuffer = <String, int>{};
  final Set<String> _missingTerms = <String>{};
  final Map<Object, ({List<WmbpQueryTerm> terms, int missing})>
      _queryPlanCache = <Object, ({List<WmbpQueryTerm> terms, int missing})>{};
  WmbpSealedView? _sealed;

  /// Sealed already counts these local docs during chunked `_evictFlushed`.
  int _handoffLocalDocs = 0;

  /// Sealed already subtracted these; they may still sit in [_inactive].
  int _handoffInactiveExtra = 0;

  /// Local df still includes these term credits that sealed already published.
  Map<int, int>? _handoffDfCredit;

  static const int _queryPlanCacheCap = 8192;

  WmbpSearchStats lastStats = WmbpSearchStats();

  int get nextDocId => _nextDocId;

  int get residentDocCount => _docs.length;

  bool get prefersPagedSearch => _sealed != null;

  WmbpSealedView? get sealedView => _sealed;

  void attachSealed(WmbpSealedView view) {
    _sealed = view;
    if (view.nextDocId > _nextDocId) _nextDocId = view.nextDocId;
    if (view.nextTermId > _nextTermId) _nextTermId = view.nextTermId;
  }

  @override
  int get activeDocCount {
    final int sealed = _sealed?.activeDocs ?? 0;
    final int total = _activeDocs +
        sealed -
        _inactive.length -
        _handoffLocalDocs +
        _handoffInactiveExtra;
    return total < 0 ? 0 : total;
  }

  static const int _docHashInitialCap = 8192;
  int _docHashCap = _docHashInitialCap;
  int _docHashMask = _docHashInitialCap - 1;
  Int32List _docHashTermIds = Int32List(_docHashInitialCap);
  Uint8List _docHashTfs = Uint8List(_docHashInitialCap);
  Int32List _docHashStamps = Int32List(_docHashInitialCap);
  Int32List _docHashSlots = Int32List(_docHashInitialCap);
  int _docHashStamp = 0;

  void _growDocHash(int stamp) {
    final int oldCap = _docHashCap;
    final oldTermIds = _docHashTermIds;
    final oldTfs = _docHashTfs;
    final oldStamps = _docHashStamps;
    final int newCap = oldCap << 1;
    final newTermIds = Int32List(newCap);
    final newTfs = Uint8List(newCap);
    final newStamps = Int32List(newCap);
    final int newMask = newCap - 1;
    for (int i = 0; i < oldCap; i++) {
      if (oldStamps[i] != stamp) continue;
      final int id = oldTermIds[i];
      var slot = (id * 2654435761) & newMask;
      while (newStamps[slot] == stamp) {
        slot = (slot + 1) & newMask;
      }
      newStamps[slot] = stamp;
      newTermIds[slot] = id;
      newTfs[slot] = oldTfs[i];
    }
    _docHashCap = newCap;
    _docHashMask = newMask;
    _docHashTermIds = newTermIds;
    _docHashTfs = newTfs;
    _docHashStamps = newStamps;
    _docHashSlots = Int32List(newCap);
  }

  void upsertText(String primaryKey, String? text) {
    if (text == null || text.isEmpty) {
      remove(primaryKey);
      return;
    }
    final units = text.codeUnits;
    final int len = units.length;
    var wordStart = -1;
    var hasUpper = false;
    // Streaming CJK: emit unigram/bigram per char (O(1) scratch).
    var prevCjk = -1;

    _docHashStamp++;
    if (_docHashStamp >= 0x7FFFFFFF) {
      _docHashStamps.fillRange(0, _docHashCap, 0);
      _docHashStamp = 1;
    }
    final int stamp = _docHashStamp;
    var docTermCount = 0;

    void addTerm(String key) {
      final int id = _termId(key);
      // Grow before insert so unique-term count never fills the table
      // (linear probing would otherwise spin forever).
      if (docTermCount >= (_docHashCap * 3) ~/ 4) {
        _growDocHash(stamp);
        // Rebuild slot index after rehash.
        docTermCount = 0;
        final stamps = _docHashStamps;
        final slots = _docHashSlots;
        for (int i = 0; i < _docHashCap; i++) {
          if (stamps[i] == stamp) {
            slots[docTermCount++] = i;
          }
        }
      }
      final stamps = _docHashStamps;
      final termIds = _docHashTermIds;
      final tfs = _docHashTfs;
      final slots = _docHashSlots;
      final int mask = _docHashMask;
      var slot = (id * 2654435761) & mask;
      while (stamps[slot] == stamp) {
        if (termIds[slot] == id) {
          if (tfs[slot] < 255) tfs[slot]++;
          return;
        }
        slot = (slot + 1) & mask;
      }
      stamps[slot] = stamp;
      termIds[slot] = id;
      tfs[slot] = 1;
      slots[docTermCount++] = slot;
    }

    void emitCjk(int cu) {
      addTerm(String.fromCharCode(cu));
      if (prevCjk >= 0) {
        addTerm(String.fromCharCodes(<int>[prevCjk, cu]));
      }
      prevCjk = cu;
    }

    for (int i = 0; i < len; i++) {
      final int cu = units[i];
      if (cu > 0x7F) {
        if (WmbpTokenizer.isCjk(cu)) {
          if (wordStart >= 0) {
            final w = text.substring(wordStart, i);
            addTerm(hasUpper ? w.toLowerCase() : w);
            wordStart = -1;
            hasUpper = false;
          }
          emitCjk(cu);
          continue;
        }
        prevCjk = -1;
        if (WmbpTokenizer.isWordUnit(cu)) {
          if (wordStart < 0) {
            wordStart = i;
            hasUpper = false;
          }
        } else if (wordStart >= 0) {
          final w = text.substring(wordStart, i);
          addTerm(hasUpper ? w.toLowerCase() : w);
          wordStart = -1;
          hasUpper = false;
        }
        continue;
      }

      // Fast ASCII path — breaks any open CJK bigram chain.
      prevCjk = -1;
      final bool isWord = (cu >= 0x30 && cu <= 0x39) ||
          (cu >= 0x41 && cu <= 0x5A) ||
          (cu >= 0x61 && cu <= 0x7A) ||
          (cu == 0x5F);
      if (isWord) {
        if (wordStart < 0) {
          wordStart = i;
          hasUpper = cu >= 0x41 && cu <= 0x5A;
        } else if (cu >= 0x41 && cu <= 0x5A) {
          hasUpper = true;
        }
      } else if (wordStart >= 0) {
        final w = text.substring(wordStart, i);
        addTerm(hasUpper ? w.toLowerCase() : w);
        wordStart = -1;
        hasUpper = false;
      }
    }
    if (wordStart >= 0) {
      final w = text.substring(wordStart, len);
      addTerm(hasUpper ? w.toLowerCase() : w);
    }

    if (docTermCount == 0) {
      remove(primaryKey);
      return;
    }

    final impacts = <int, int>{};
    var sig = 0;
    final termIds = _docHashTermIds;
    final tfs = _docHashTfs;
    final slots = _docHashSlots;
    for (int t = 0; t < docTermCount; t++) {
      final int slot = slots[t];
      final int id = termIds[slot];
      final int q = WmbpScore.quantizeTermFrequency(tfs[slot]);
      if (q <= 0) continue;
      impacts[id] = q;
      sig = (sig * 31 + id * 101 + q) & 0x7FFFFFFF;
    }
    _upsertWithSig(primaryKey, impacts, sig);
  }

  void upsertWeightedTerms(String primaryKey, Map<String, double> terms) {
    final impacts = <int, int>{};
    for (final entry in terms.entries) {
      final int q = WmbpScore.quantizePositive(entry.value);
      if (q <= 0) continue;
      impacts[_termId(entry.key)] = q;
    }
    if (impacts.isEmpty) {
      remove(primaryKey);
      return;
    }
    _upsert(primaryKey, impacts);
  }

  void upsertSparse(String primaryKey, SparseVectorData data) {
    final impacts = <int, int>{};
    final int n = data.nnz;
    var maxDim = -1;
    for (int i = 0; i < n; i++) {
      final int q = WmbpScore.quantizePositive(data.values[i]);
      if (q <= 0) continue;
      final int dim = data.indices[i];
      impacts[dim] = q;
      if (dim > maxDim) maxDim = dim;
    }
    if (impacts.isEmpty) {
      remove(primaryKey);
      return;
    }
    // Sparse dimensions are raw termIds; keep nextTermId above the high-water
    // so meta / allocation bounds stay consistent across flushes.
    if (maxDim >= _nextTermId) _nextTermId = maxDim + 1;
    _upsert(primaryKey, impacts);
  }

  void remove(String primaryKey) {
    final int? docId = _pkToDoc.remove(primaryKey);
    if (docId == null) return;
    _pkSig.remove(primaryKey);
    final doc = _docs.remove(docId);
    _pending.remove(docId);
    if (doc == null) return;
    _subDf(doc.impacts);
    if (doc.sealed) {
      _setActiveBit(docId, false);
      final int windowId = WmbpConstants.windowIdOf(docId);
      final int left = (_activeCount[windowId] ?? 1) - 1;
      if (left <= 0) {
        _activeCount.remove(windowId);
      } else {
        _activeCount[windowId] = left;
      }
    }
    if (_activeDocs > 0) _activeDocs--;
  }

  /// Moves every pending document into sealed windows.
  void sealAll() {
    if (_pending.isEmpty) return;
    final docs = _pending.values.toList();
    _pending.clear();
    for (final doc in docs) {
      _installSealed(doc);
    }
  }

  /// Seals one primary key when it is still pending.
  void sealPrimaryKey(String primaryKey) {
    final int? docId = _pkToDoc[primaryKey];
    if (docId == null) return;
    final doc = _pending.remove(docId);
    if (doc == null) return;
    _installSealed(doc);
  }

  List<WmbpHit> searchText(
    TextQuery query, {
    required int topK,
    TextMatchOperator operator = TextMatchOperator.or,
    bool exhaustive = false,
  }) {
    final compiled = _compileText(query);
    if (operator == TextMatchOperator.and && compiled.missing > 0) {
      return const <WmbpHit>[];
    }
    return _search(
      compiled.terms,
      topK: topK,
      useIdf: true,
      exhaustive: exhaustive,
      conjunctive: operator == TextMatchOperator.and,
    );
  }

  List<WmbpHit> searchSparse(
    SparseVectorData query, {
    required int topK,
    bool exhaustive = false,
  }) {
    final terms = <WmbpQueryTerm>[];
    for (int i = 0; i < query.nnz; i++) {
      final int milli = WmbpScore.weightMilli(query.values[i]);
      if (milli <= 0) continue;
      terms.add(WmbpQueryTerm(termId: query.indices[i], weightMilli: milli));
    }
    return _search(terms, topK: topK, useIdf: false, exhaustive: exhaustive);
  }

  /// Sync sparse path mirroring [searchTextSync] (heads resident + prune-then-ensure).
  List<WmbpHit>? searchSparseSync(
    SparseVectorData query, {
    required int topK,
  }) {
    final view = _sealed;
    if (view == null) return null;
    final terms = <WmbpQueryTerm>[];
    for (int i = 0; i < query.nnz; i++) {
      final int milli = WmbpScore.weightMilli(query.values[i]);
      if (milli <= 0) continue;
      final int termId = query.indices[i];
      if (!view.ensureHeadSync(termId)) return null;
      terms.add(WmbpQueryTerm(termId: termId, weightMilli: milli));
    }
    if (terms.isEmpty) return const <WmbpHit>[];
    final stats = WmbpSearchStats();
    lastStats = stats;
    final hits = wmbpSearchTopK(
      source: this,
      terms: terms,
      topK: topK,
      useIdf: false,
      stats: stats,
      ensureWindowSync: view.ensureWindowSync,
      ensureMacroSync: view.ensureMacroSync,
    );
    if (stats.coldPrimaryKeyMisses > 0) return null;
    for (final hit in hits) {
      if (currentDocIdOf(hit.primaryKey) == null &&
          sealedDocIdOfSync(hit.primaryKey) == null &&
          !isLocalDoc(hit.docId)) {
        return null;
      }
    }
    return hits;
  }

  bool hasLocalPk(String primaryKey) => _pkToDoc.containsKey(primaryKey);

  Future<void> deactivatePrimaryKey(
    String primaryKey, {
    WalPointer? flushedAt,
  }) async {
    // Drop any local/pending doc first, then still retire the sealed reverse
    // mapping. A prior upsert-without-deactivate can leave the old sealed
    // docId live while `_pkToDoc` already points at a newer local docId;
    // returning early here used to strand that ghost posting.
    if (_pkToDoc.containsKey(primaryKey)) {
      remove(primaryKey);
    }
    final sealed = _sealed;
    if (sealed == null) return;
    int docId = sealed.lookupPkResident(primaryKey);
    if (docId == WmbpSealedView.revLookupNeedsIo) {
      docId = await sealed.lookupPk(primaryKey) ?? -1;
    }
    if (docId < 0 || !_inactive.add(docId)) return;
    _deleteMarks[docId] =
        flushedAt ?? WalPointer(partitionIndex: 0, entrySeq: _deleteSeq++);
    final int windowId = WmbpConstants.windowIdOf(docId);
    _inactiveWindows[windowId] = (_inactiveWindows[windowId] ?? 0) + 1;
    _removedPks.add(primaryKey);
  }

  /// Resident-only fast path for [deactivatePrimaryKey]. Returns `true` when
  /// handled synchronously. Cold rev misses are recorded in
  /// [_pendingDeactivatePks] so DML never awaits.
  bool tryDeactivatePrimaryKeySync(
    String primaryKey, {
    WalPointer? flushedAt,
  }) {
    if (_pkToDoc.containsKey(primaryKey)) {
      remove(primaryKey);
    }
    final sealed = _sealed;
    if (sealed == null) return true;
    final int docId = sealed.lookupPkResident(primaryKey);
    if (docId == WmbpSealedView.revLookupNeedsIo) {
      _pendingDeactivatePks[primaryKey] = flushedAt;
      _removedPks.add(primaryKey);
      return true;
    }
    if (docId >= 0 && _inactive.add(docId)) {
      _deleteMarks[docId] =
          flushedAt ?? WalPointer(partitionIndex: 0, entrySeq: _deleteSeq++);
      final int windowId = WmbpConstants.windowIdOf(docId);
      _inactiveWindows[windowId] = (_inactiveWindows[windowId] ?? 0) + 1;
      _removedPks.add(primaryKey);
    }
    return true;
  }

  @override
  bool isPkPendingRemoval(String primaryKey) =>
      _pendingDeactivatePks.containsKey(primaryKey);

  /// Resolve cold-rev pending deactivations during seal (batch I/O).
  Future<void> resolvePendingDeactivations() async {
    if (_pendingDeactivatePks.isEmpty) return;
    final pending = Map<String, WalPointer?>.of(_pendingDeactivatePks);
    _pendingDeactivatePks.clear();
    final yc = YieldController(
      'wmbp_resolve_pending_deactivations',
      checkInterval: 128,
      minCheckInterval: 64,
    );
    for (final entry in pending.entries) {
      final y = yc.maybeYield();
      if (y != null) await y;
      // A live local upsert for this PK already superseded the queued retire.
      if (_pkToDoc.containsKey(entry.key)) continue;
      await deactivatePrimaryKey(entry.key, flushedAt: entry.value);
    }
  }

  /// Remap reminted pending term ids onto sealed dictionary ids (async I/O).
  Future<void> _canonicalizePendingTerms() async {
    final view = _sealed;
    if (view == null || _pendingTermNames.isEmpty) return;
    final pending = Map<int, String>.of(_pendingTermNames);
    final folds = <int, int>{};
    final yc = YieldController(
      'wmbp_canonicalize_pending_terms',
      checkInterval: 64,
      minCheckInterval: 32,
    );
    for (final entry in pending.entries) {
      final y = yc.maybeYield();
      if (y != null) await y;
      // Dropped while we awaited — already folded or sealed away.
      if (!_pendingTermNames.containsKey(entry.key)) continue;
      final int? found = await view.lookupName(entry.value);
      if (found != null && found != entry.key) {
        folds[entry.key] = found;
      }
    }
    if (folds.isEmpty) return;
    // One pass over pending docs + chain merges (never M×N full scans).
    _foldTermIds(folds);
  }

  Future<void> commitDurable() async {
    final view = _sealed;
    if (view == null) return;
    await resolvePendingDeactivations();
    // Fold any reminted pending term ids onto durable dictionary ids before
    // seal. Sync upserts can mint duplicates when name pages are cold; sealing
    // those ids would overwrite the dict and orphan the historical chain.
    await _canonicalizePendingTerms();
    final batch = _peekBatch();
    if (batch.added.isEmpty &&
        batch.deactivated.isEmpty &&
        batch.removedPks.isEmpty) {
      return;
    }
    await view.commit(
      batch,
      handoff: ({
        required List<int> deactivated,
        required void Function() publish,
      }) async {
        // Compensation first, then O(1)/O(windows) publish, then chunked evict
        // with yields — search stays correct across the handoff.
        await _beginPublishHandoff(batch, deactivated);
        publish();
        try {
          await _evictFlushed(batch);
        } finally {
          _clearPublishHandoff();
        }
        await view.drainPublishOverlay();
      },
    );
  }

  ({List<WmbpQueryTerm> terms, int missing})? _compileTextSync(
      TextQuery query) {
    final cachedPlan = _queryPlanCache[query];
    if (cachedPlan != null) return cachedPlan;
    final weights = <int, int>{};
    var missing = 0;
    if (query.weightedTerms != null) {
      for (final entry in query.weightedTerms!.entries) {
        final int milli = WmbpScore.weightMilli(entry.value);
        if (milli <= 0) continue;
        final String term = entry.key;
        if (_missingTerms.contains(term)) {
          missing++;
          continue;
        }
        final int? id = _resolvedTermIdSync(term);
        if (id == null) return null;
        weights[id] = milli;
      }
    } else {
      _countsBuffer.clear();
      WmbpTokenizer.tokenizeCounts(query.text ?? '', _countsBuffer);
      final bool hasCjkBigram = _countsHaveCjkBigram(_countsBuffer.keys);
      for (final entry in _countsBuffer.entries) {
        final String term = entry.key;
        final int milli = _engineTextTokenMilli(
          term,
          entry.value,
          hasCjkBigram: hasCjkBigram,
        );
        if (milli <= 0) continue;
        if (_missingTerms.contains(term)) {
          missing++;
          continue;
        }
        final int? id = _resolvedTermIdSync(term);
        if (id == null) return null;
        weights[id] = milli;
      }
    }
    final compiled = (
      terms: [
        for (final entry in weights.entries)
          WmbpQueryTerm(termId: entry.key, weightMilli: entry.value),
      ],
      missing: missing,
    );
    _storeQueryPlan(query, compiled);
    return compiled;
  }

  /// Warms the synchronous Top-K search context pool and scoring hot path.
  void prewarmSearchContext() {
    final view = _sealed;
    if (view == null) return;
    final int? termId = view.firstWarmTermId;
    if (termId == null) return;
    final stats = WmbpSearchStats();
    final hits = wmbpSearchTopK(
      source: this,
      terms: <WmbpQueryTerm>[WmbpQueryTerm(termId: termId, weightMilli: 1000)],
      topK: 1,
      useIdf: true,
      stats: stats,
      ensureWindowSync: view.ensureWindowSync,
      ensureMacroSync: view.ensureMacroSync,
    );
    for (final hit in hits) {
      sealedDocIdOfSync(hit.primaryKey);
    }
  }

  List<WmbpHit>? searchTextSync(
    TextQuery query, {
    required int topK,
    TextMatchOperator operator = TextMatchOperator.or,
  }) {
    final view = _sealed;
    if (view == null) return null;
    final compiled = _compileTextSync(query);
    if (compiled == null) return null;
    if (operator == TextMatchOperator.and && compiled.missing > 0) {
      return const <WmbpHit>[];
    }
    final terms = compiled.terms;
    for (final term in terms) {
      if (!view.ensureHeadSync(term.termId)) return null;
    }
    // Window bodies are ensured lazily after Stage-2 prune inside the
    // scheduler — do not pre-touch every cold window here.
    final stats = WmbpSearchStats();
    lastStats = stats;
    final hits = wmbpSearchTopK(
      source: this,
      terms: terms,
      topK: topK,
      useIdf: true,
      conjunctive: operator == TextMatchOperator.and,
      stats: stats,
      ensureWindowSync: view.ensureWindowSync,
      ensureMacroSync: view.ensureMacroSync,
    );
    if (stats.coldPrimaryKeyMisses > 0) {
      return null;
    }
    // Sync path can only retire superseded docIds when the rev PK / node cache
    // is warm. Escalate so orphan sealed ghosts are filtered via lookupPk.
    for (final hit in hits) {
      if (currentDocIdOf(hit.primaryKey) == null &&
          sealedDocIdOfSync(hit.primaryKey) == null &&
          !isLocalDoc(hit.docId)) {
        return null;
      }
    }
    return hits;
  }

  Future<List<WmbpHit>> searchTextPaged(
    TextQuery query, {
    required int topK,
    TextMatchOperator operator = TextMatchOperator.or,
    bool exhaustive = false,
  }) async {
    if (_sealed == null) {
      return searchText(query,
          topK: topK, operator: operator, exhaustive: exhaustive);
    }
    final compiled = await _compileTextPaged(query);
    if (operator == TextMatchOperator.and && compiled.missing > 0) {
      return const <WmbpHit>[];
    }
    return _searchPaged(
      compiled.terms,
      topK: topK,
      useIdf: true,
      exhaustive: exhaustive,
      conjunctive: operator == TextMatchOperator.and,
    );
  }

  Future<List<WmbpHit>> searchSparsePaged(
    SparseVectorData query, {
    required int topK,
    bool exhaustive = false,
  }) async {
    if (_sealed == null) {
      return searchSparse(query, topK: topK, exhaustive: exhaustive);
    }
    final terms = <WmbpQueryTerm>[];
    for (int i = 0; i < query.nnz; i++) {
      final int milli = WmbpScore.weightMilli(query.values[i]);
      if (milli <= 0) continue;
      terms.add(WmbpQueryTerm(termId: query.indices[i], weightMilli: milli));
    }
    return _searchPaged(terms,
        topK: topK, useIdf: false, exhaustive: exhaustive);
  }

  List<WmbpHit> _search(
    List<WmbpQueryTerm> terms, {
    required int topK,
    required bool useIdf,
    required bool exhaustive,
    bool conjunctive = false,
  }) {
    lastStats = WmbpSearchStats();
    // [exhaustive] previously scanned only the local overlay with the wrong
    // IDF denominator; the shared Top-K scheduler is already lossless for the
    // same scoring model, so both flags share that path.
    if (exhaustive) {
      // Same path — flag retained for call-site compatibility.
    }
    return wmbpSearchTopK(
      source: this,
      terms: terms,
      topK: topK,
      useIdf: useIdf,
      conjunctive: conjunctive,
      stats: lastStats,
    );
  }

  ({List<WmbpQueryTerm> terms, int missing}) _compileText(TextQuery query) {
    final weights = <int, int>{};
    var missing = 0;
    if (query.weightedTerms != null) {
      for (final entry in query.weightedTerms!.entries) {
        final int milli = WmbpScore.weightMilli(entry.value);
        if (milli <= 0) continue;
        final int? id = _resolvedTermIdSync(entry.key);
        if (id == null) {
          missing++;
          continue;
        }
        weights[id] = milli;
      }
    } else {
      final counts = <String, int>{};
      for (final token in WmbpTokenizer.tokenize(query.text ?? '')) {
        counts[token] = (counts[token] ?? 0) + 1;
      }
      final bool hasCjkBigram = _countsHaveCjkBigram(counts.keys);
      for (final entry in counts.entries) {
        final int milli = _engineTextTokenMilli(
          entry.key,
          entry.value,
          hasCjkBigram: hasCjkBigram,
        );
        if (milli <= 0) continue;
        final int? id = _resolvedTermIdSync(entry.key);
        if (id == null) {
          missing++;
          continue;
        }
        weights[id] = milli;
      }
    }
    return (
      terms: [
        for (final entry in weights.entries)
          WmbpQueryTerm(termId: entry.key, weightMilli: entry.value),
      ],
      missing: missing,
    );
  }

  /// Query-compile weight for [TextQuery.text] tokens (scan path untouched).
  static int _engineTextTokenMilli(
    String term,
    int tf, {
    required bool hasCjkBigram,
  }) {
    return WmbpScore.applyCjkUnigramQueryScale(
      WmbpScore.weightMilli(tf),
      isCjkUnigram: WmbpTokenizer.isCjkUnigram(term),
      queryHasCjkBigram: hasCjkBigram,
    );
  }

  static bool _countsHaveCjkBigram(Iterable<String> terms) {
    for (final term in terms) {
      if (WmbpTokenizer.isCjkBigram(term)) return true;
    }
    return false;
  }

  void _upsert(String primaryKey, Map<int, int> impacts) {
    _upsertWithSig(primaryKey, impacts, _signature(impacts));
  }

  void _upsertWithSig(String primaryKey, Map<int, int> impacts, int sig) {
    final oldDocId = _pkToDoc[primaryKey];
    if (oldDocId != null) {
      if (_pkSig[primaryKey] == sig) return;
      remove(primaryKey);
    }
    if (impacts.isEmpty) return;
    // Update path: deactivatePrimaryKey then upsert same PK. Cancel the pending
    // rev-map delete so a later seal of a *different* PK cannot forget this one.
    // Also drop cold-rev [_pendingDeactivatePks]: tryDeactivatePrimaryKeySync may
    // have queued this PK on a cache miss *before* the upsert; resolving that at
    // seal would remove(primaryKey) and empty the commit batch (doc lost).
    _removedPks.remove(primaryKey);
    _pendingDeactivatePks.remove(primaryKey);
    final int docId = _nextDocId++;
    final doc = _Doc(
      docId: docId,
      primaryKey: primaryKey,
      impacts: impacts,
      sealed: false,
    );
    _docs[docId] = doc;
    _pending[docId] = doc;
    _pkToDoc[primaryKey] = docId;
    _pkSig[primaryKey] = sig;
    for (final termId in impacts.keys) {
      final chain = _terms[termId] ?? (_terms[termId] = _TermChain());
      chain.df++;
    }
    _activeDocs++;
  }

  void _installSealed(_Doc doc) {
    doc.sealed = true;
    final int windowId = WmbpConstants.windowIdOf(doc.docId);
    final int offset = WmbpConstants.docOffsetOf(doc.docId);
    _activeCount[windowId] = (_activeCount[windowId] ?? 0) + 1;
    final mask = _masks[windowId];
    if (mask != null) {
      mask[offset >> 5] |= 1 << (offset & 31);
    }
    for (final entry in doc.impacts.entries) {
      final chain = _terms[entry.key] ?? (_terms[entry.key] = _TermChain());
      final wins = chain.windows ??= <int, _WindowAcc>{};
      final window = wins.putIfAbsent(windowId, _WindowAcc.new);
      window.offsets.add(offset);
      window.impacts.add(entry.value);
      if (entry.value > window.maxImpact) window.maxImpact = entry.value;
      window.encoded = null;
      chain.sortedWindowIds = null;
      _pushChampion(chain, doc.docId, entry.value);
    }
  }

  void _pushChampion(_TermChain chain, int docId, int q8) {
    final list = chain.champion ??= <WmbpChampionPosting>[];
    WmbpChampionPosting.pushOrdered(list, docId, q8);
  }

  int? _localTermId(String term) {
    return _pendingTermIds[term] ??
        _hotTermIds[term] ??
        _sealed?.cachedName(term);
  }

  /// Sync compile/search: prefer durable dict id over a reminted pending/hot id.
  int? _resolvedTermIdSync(String term) {
    final int? durable = _sealed?.lookupNameSync(term);
    if (durable != null) {
      final int? pending = _pendingTermIds[term];
      if (pending != null && pending != durable) {
        _foldTermId(pending, durable);
      }
      _rememberHot(term, durable);
      return durable;
    }
    return _localTermId(term);
  }

  void _rememberHot(String term, int id) {
    if (_hotTermIds.length >= _hotTermCap && !_hotTermIds.containsKey(term)) {
      _hotTermIds.remove(_hotTermIds.keys.first);
    }
    _hotTermIds[term] = id;
  }

  int _termId(String term) {
    final int? existing = _localTermId(term);
    if (existing != null) {
      // Upsert racing an in-flight miss lookup can re-mark the term missing
      // after we already assigned it; clear that on every hit.
      _clearMissingTerm(term);
      if (!_pendingTermIds.containsKey(term)) {
        _rememberHot(term, existing);
      }
      return existing;
    }
    // A prior miss may have cached an empty query plan; drop it when the term
    // becomes real so later matchText does not keep returning no hits.
    _clearMissingTerm(term);
    // Never mint a parallel id for a name that already has a durable posting
    // chain. Cold name/hot LRU misses at multi-million scale used to remint,
    // then overwrite the dict entry on seal — after which only the updated
    // (and later) docs remained searchable under that term.
    final sealed = _sealed;
    if (sealed != null) {
      final int? durable = sealed.lookupNameSync(term);
      if (durable != null) {
        _rememberHot(term, durable);
        if (durable >= _nextTermId) _nextTermId = durable + 1;
        return durable;
      }
    }
    final int id = _nextTermId++;
    _pendingTermIds[term] = id;
    _pendingTermNames[id] = term;
    return id;
  }

  Future<int?> _resolveTerm(String term, {required bool assign}) async {
    if (_missingTerms.contains(term) && _localTermId(term) == null) {
      return null;
    }
    // Prefer the durable dictionary id over a reminted pending/hot id so a
    // cold-cache remint cannot hide the historical posting chain from search.
    final int? found = await _sealed?.lookupName(term);
    if (found != null) {
      final int? pending = _pendingTermIds[term];
      if (pending != null && pending != found) {
        _foldTermId(pending, found);
      }
      _rememberHot(term, found);
      if (found >= _nextTermId) _nextTermId = found + 1;
      return found;
    }
    final int? local = _localTermId(term);
    if (local != null) {
      if (!_pendingTermIds.containsKey(term)) _rememberHot(term, local);
      return local;
    }
    if (!assign) {
      _rememberMissing(term);
      return null;
    }
    return _termId(term);
  }

  /// Collapse a reminted pending term id onto the durable dictionary id.
  void _foldTermId(int fromId, int toId) {
    if (fromId == toId) return;
    _foldTermIds(<int, int>{fromId: toId});
  }

  /// Batch remint collapse: one doc scan + per-from chain merge.
  void _foldTermIds(Map<int, int> folds) {
    if (folds.isEmpty) return;
    final resolved = <int, int>{};
    for (final entry in folds.entries) {
      if (entry.key == entry.value) continue;
      resolved[entry.key] = entry.value;
    }
    if (resolved.isEmpty) return;
    for (final entry in resolved.entries) {
      final name = _pendingTermNames.remove(entry.key);
      if (name != null) {
        if (_pendingTermIds[name] == entry.key) {
          _pendingTermIds.remove(name);
        }
        _rememberHot(name, entry.value);
      }
    }
    for (final doc in _docs.values) {
      // Avoid allocating keys.toList() on every doc: only remap hits.
      var hit = false;
      for (final fromId in resolved.keys) {
        if (doc.impacts.containsKey(fromId)) {
          hit = true;
          break;
        }
      }
      if (!hit) continue;
      for (final entry in resolved.entries) {
        final int? q = doc.impacts.remove(entry.key);
        if (q == null) continue;
        final int toId = entry.value;
        final int prev = doc.impacts[toId] ?? 0;
        doc.impacts[toId] = q > prev ? q : prev;
      }
    }
    for (final entry in resolved.entries) {
      final fromChain = _terms.remove(entry.key);
      if (fromChain == null) continue;
      final toChain = _terms.putIfAbsent(entry.value, _TermChain.new);
      toChain.df += fromChain.df;
      final fromWins = fromChain.windows;
      if (fromWins != null && fromWins.isNotEmpty) {
        final dest = toChain.windows ??= <int, _WindowAcc>{};
        dest.addAll(fromWins);
        toChain.sortedWindowIds = null;
      }
      final fromChamp = fromChain.champion;
      if (fromChamp != null && fromChamp.isNotEmpty) {
        final dest = toChain.champion ??= <WmbpChampionPosting>[];
        for (final p in fromChamp) {
          WmbpChampionPosting.pushOrdered(dest, p.docId, p.q8);
        }
      }
    }
    _queryPlanCache.clear();
  }

  void _clearMissingTerm(String term) {
    if (!_missingTerms.remove(term)) return;
    _queryPlanCache.clear();
  }

  void _rememberMissing(String term) {
    if (_localTermId(term) != null || _missingTerms.contains(term)) return;
    while (_missingTerms.length >= WmbpConstants.missingTermsCacheCap) {
      _missingTerms.remove(_missingTerms.first);
    }
    _missingTerms.add(term);
  }

  void _storeQueryPlan(
    Object query,
    ({List<WmbpQueryTerm> terms, int missing}) compiled,
  ) {
    if (_queryPlanCache.length >= _queryPlanCacheCap) {
      _queryPlanCache.remove(_queryPlanCache.keys.first);
    }
    _queryPlanCache[query] = compiled;
  }

  /// Memory-pressure trim for overlay caches; sealed pages go through the view.
  Future<void> evictCaches({required double ratio}) async {
    if (ratio <= 0.0) return;
    _pruneHotTermIds(ratio);
    _dropSetRatio(_missingTerms, ratio);
    _dropMapRatio(_queryPlanCache, ratio);
    await _sealed?.evictCaches(ratio: ratio);
  }

  /// Drop sealed-resolved hot names not referenced by resident docs.
  void _pruneHotTermIds(double ratio) {
    if (_hotTermIds.isEmpty || ratio <= 0.0) return;
    final liveIds = <int>{};
    for (final doc in _docs.values) {
      liveIds.addAll(doc.impacts.keys);
    }
    final candidates = <String>[];
    for (final entry in _hotTermIds.entries) {
      if (liveIds.contains(entry.value)) continue;
      candidates.add(entry.key);
    }
    final int drop = (candidates.length * ratio).ceil();
    for (int i = 0; i < drop; i++) {
      _hotTermIds.remove(candidates[i]);
    }
  }

  static void _dropSetRatio(Set<String> set, double ratio) {
    final int drop = (set.length * ratio).ceil();
    if (drop <= 0) return;
    final keys = set.take(drop).toList();
    for (final k in keys) {
      set.remove(k);
    }
  }

  static void _dropMapRatio<K, V>(Map<K, V> map, double ratio) {
    final int drop = (map.length * ratio).ceil();
    if (drop <= 0) return;
    final keys = map.keys.take(drop).toList();
    for (final k in keys) {
      map.remove(k);
    }
  }

  Future<({List<WmbpQueryTerm> terms, int missing})> _compileTextPaged(
    TextQuery query,
  ) async {
    final cachedPlan = _queryPlanCache[query];
    if (cachedPlan != null) return cachedPlan;
    final weights = <int, int>{};
    var missing = 0;
    if (query.weightedTerms != null) {
      for (final entry in query.weightedTerms!.entries) {
        final int milli = WmbpScore.weightMilli(entry.value);
        if (milli <= 0) continue;
        final String term = entry.key;
        if (_missingTerms.contains(term)) {
          missing++;
          continue;
        }
        // Always go through [_resolveTerm] so a reminted pending/hot id cannot
        // hide the durable posting chain after a cold name-cache miss.
        final int? id = await _resolveTerm(term, assign: false);
        if (id == null) {
          missing++;
          continue;
        }
        weights[id] = milli;
      }
    } else {
      _countsBuffer.clear();
      WmbpTokenizer.tokenizeCounts(query.text ?? '', _countsBuffer);
      final bool hasCjkBigram = _countsHaveCjkBigram(_countsBuffer.keys);
      for (final entry in _countsBuffer.entries) {
        final String term = entry.key;
        final int milli = _engineTextTokenMilli(
          term,
          entry.value,
          hasCjkBigram: hasCjkBigram,
        );
        if (milli <= 0) continue;
        if (_missingTerms.contains(term)) {
          missing++;
          continue;
        }
        final int? id = await _resolveTerm(term, assign: false);
        if (id == null) {
          missing++;
          continue;
        }
        weights[id] = milli;
      }
    }
    final compiled = (
      terms: [
        for (final entry in weights.entries)
          WmbpQueryTerm(termId: entry.key, weightMilli: entry.value),
      ],
      missing: missing,
    );
    _storeQueryPlan(query, compiled);
    return compiled;
  }

  Future<List<WmbpHit>> _searchPaged(
    List<WmbpQueryTerm> terms, {
    required int topK,
    required bool useIdf,
    required bool exhaustive,
    bool conjunctive = false,
  }) async {
    final view = _sealed;
    if (view == null) {
      return _search(
        terms,
        topK: topK,
        useIdf: useIdf,
        exhaustive: exhaustive,
        conjunctive: conjunctive,
      );
    }
    lastStats = WmbpSearchStats();
    // Must use the async searcher: sync wmbpSearchTopK only resolves PKs from
    // the fwd cache; overflow / unwarmed PKs need [_lookupFwd] via paged path.
    return wmbpSearchTopKPaged(
      source: this,
      terms: terms,
      topK: topK,
      useIdf: useIdf,
      conjunctive: conjunctive,
      stats: lastStats,
      ensureHead: view.loadHead,
      ensureHeadSync: view.ensureHeadSync,
      ensureWindow: view.ensureWindow,
      ensureWindowSync: view.ensureWindowSync,
      ensureMacro: view.ensureMacroForTerm,
      ensureMacroSync: view.ensureMacroSync,
    );
  }

  WmbpCommitBatch _peekBatch() {
    // Share impact maps: commit only reads them, then [_evictFlushed] drops
    // the docs. Copying every map dominated long-document seal CPU.
    final added = <WmbpSealDoc>[
      for (final doc in _docs.values)
        WmbpSealDoc(
          docId: doc.docId,
          primaryKey: doc.primaryKey,
          impacts: doc.impacts,
        ),
    ];
    final addedPks = <String>{for (final doc in added) doc.primaryKey};
    WalPointer? flushedDelete;
    final deactivated = <int>[];
    for (final id in _inactive) {
      final mark = _deleteMarks[id];
      if (mark == null) continue;
      deactivated.add(id);
      if (flushedDelete == null || mark.isNewerThan(flushedDelete, 1 << 30)) {
        flushedDelete = mark;
      }
    }
    // Only newly minted names still waiting for durable dict write.
    final termNames = Map<int, String>.of(_pendingTermNames);
    return WmbpCommitBatch(
      nextDocId: _nextDocId,
      nextTermId: _nextTermId,
      added: added,
      termNames: termNames,
      deactivated: deactivated,
      removedPks: [
        for (final pk in _removedPks)
          if (!addedPks.contains(pk)) pk,
      ],
      flushedDelete: flushedDelete,
    );
  }

  Future<void> _beginPublishHandoff(
    WmbpCommitBatch batch,
    List<int> deactivated,
  ) async {
    final yc = YieldController(
      'wmbp_begin_publish_handoff',
      checkInterval: 256,
      minCheckInterval: 64,
    );
    var localDocs = 0;
    final credit = <int, int>{};
    for (final sealDoc in batch.added) {
      final y = yc.maybeYield();
      if (y != null) await y;
      final doc = _docs[sealDoc.docId];
      if (doc == null) continue;
      localDocs++;
      for (final termId in doc.impacts.keys) {
        credit[termId] = (credit[termId] ?? 0) + 1;
      }
    }
    var inactiveExtra = 0;
    for (final id in deactivated) {
      final y = yc.maybeYield();
      if (y != null) await y;
      if (_inactive.contains(id)) inactiveExtra++;
    }
    _handoffLocalDocs = localDocs;
    _handoffInactiveExtra = inactiveExtra;
    _handoffDfCredit = credit;
    // Keep window prune bounds correct once sealed counters publish: drop the
    // soon-to-clear inactive credits from [_inactiveWindows] now (full rebuild
    // still runs at the end of [_evictFlushed]).
    for (final id in deactivated) {
      final y = yc.maybeYield();
      if (y != null) await y;
      if (!_inactive.contains(id)) continue;
      final int wid = WmbpConstants.windowIdOf(id);
      final int? cur = _inactiveWindows[wid];
      if (cur == null) continue;
      if (cur <= 1) {
        _inactiveWindows.remove(wid);
      } else {
        _inactiveWindows[wid] = cur - 1;
      }
    }
  }

  void _clearPublishHandoff() {
    _handoffLocalDocs = 0;
    _handoffInactiveExtra = 0;
    _handoffDfCredit = null;
  }

  Future<void> _evictFlushed(WmbpCommitBatch batch) async {
    // High-water eviction: drop exactly the sealed batch prefix and subtract
    // their term dfs in place — do not clear+rebuild _terms for survivors.
    // Yields are safe: [_handoffLocalDocs] / [_handoffDfCredit] keep search
    // counters correct while sealed is already published.
    final yc = YieldController(
      'wmbp_evict_flushed',
      checkInterval: 256,
      minCheckInterval: 64,
    );
    var flushedMaxDocId = -1;
    for (final sealDoc in batch.added) {
      final y = yc.maybeYield();
      if (y != null) await y;
      final int id = sealDoc.docId;
      if (id > flushedMaxDocId) flushedMaxDocId = id;
      final doc = _docs.remove(id);
      _pending.remove(id);
      if (doc == null) continue;
      _subDf(doc.impacts);
      final credit = _handoffDfCredit;
      if (credit != null) {
        for (final termId in doc.impacts.keys) {
          final int left = (credit[termId] ?? 0) - 1;
          if (left <= 0) {
            credit.remove(termId);
          } else {
            credit[termId] = left;
          }
        }
      }
      if (_handoffLocalDocs > 0) _handoffLocalDocs--;
      if (_pkToDoc[doc.primaryKey] == id) {
        _pkToDoc.remove(doc.primaryKey);
        _pkSig.remove(doc.primaryKey);
      }
      if (_activeDocs > 0) _activeDocs--;
    }
    final flushedMark = batch.flushedDelete;
    if (flushedMark != null) {
      final drop = <int>[];
      for (final entry in _deleteMarks.entries) {
        final y = yc.maybeYield();
        if (y != null) await y;
        if (!entry.value.isNewerThan(flushedMark, 1 << 30)) {
          drop.add(entry.key);
        }
      }
      for (final id in drop) {
        final y = yc.maybeYield();
        if (y != null) await y;
        if (_inactive.remove(id) && _handoffInactiveExtra > 0) {
          _handoffInactiveExtra--;
        }
        _deleteMarks.remove(id);
      }
    }
    final settledPks = <String>{
      ...batch.removedPks,
      for (final doc in batch.added) doc.primaryKey,
    };
    if (settledPks.isNotEmpty) {
      _removedPks.removeWhere(settledPks.contains);
    }
    _inactiveWindows.clear();
    for (final id in _inactive) {
      final y = yc.maybeYield();
      if (y != null) await y;
      final int windowId = WmbpConstants.windowIdOf(id);
      _inactiveWindows[windowId] = (_inactiveWindows[windowId] ?? 0) + 1;
    }
    // Drop sealed window masks / active counts for windows fully below the
    // high-water (survivors keep their pending overlays).
    if (flushedMaxDocId >= 0) {
      final int sealedThrough = WmbpConstants.windowIdOf(flushedMaxDocId);
      _masks.removeWhere((windowId, _) => windowId < sealedThrough);
      _activeCount.removeWhere((windowId, _) => windowId < sealedThrough);
    }
    // Re-home survivors into pending without clearing term dfs.
    _pending.clear();
    for (final entry in batch.termNames.entries) {
      final y = yc.maybeYield();
      if (y != null) await y;
      _pendingTermNames.remove(entry.key);
      _pendingTermIds.remove(entry.value);
      _rememberHot(entry.value, entry.key);
    }
    for (final doc in _docs.values) {
      final y = yc.maybeYield();
      if (y != null) await y;
      doc.sealed = false;
      _pending[doc.docId] = doc;
    }
  }

  List<int> _sparseUnionIds(List<int> left, List<int> right) {
    final out = <int>[];
    var i = 0;
    var j = 0;
    while (i < left.length || j < right.length) {
      final int? a = i < left.length ? left[i] : null;
      final int? b = j < right.length ? right[j] : null;
      late final int pick;
      if (a == null) {
        pick = b!;
        j++;
      } else if (b == null || a < b) {
        pick = a;
        i++;
      } else if (b < a) {
        pick = b;
        j++;
      } else {
        pick = a;
        i++;
        j++;
      }
      if (out.isEmpty || out.last != pick) out.add(pick);
    }
    return out;
  }

  void _subDf(Map<int, int> impacts) {
    for (final termId in impacts.keys) {
      final chain = _terms[termId];
      if (chain == null) continue;
      if (chain.df > 0) chain.df--;
    }
  }

  void _setActiveBit(int docId, bool active) {
    final int windowId = WmbpConstants.windowIdOf(docId);
    final int offset = WmbpConstants.docOffsetOf(docId);
    final mask = _masks.putIfAbsent(windowId, () {
      final words = Uint32List(WmbpConstants.activeMaskWords);
      for (int i = 0; i < words.length; i++) {
        words[i] = 0xFFFFFFFF;
      }
      return words;
    });
    final int word = offset >> 5;
    final int bit = 1 << (offset & 31);
    if (active) {
      mask[word] |= bit;
    } else {
      mask[word] = (mask[word] & ~bit) & 0xFFFFFFFF;
    }
  }

  static int _signature(Map<int, int> impacts) {
    var h = 0;
    for (final entry in impacts.entries) {
      h = (h * 31 + entry.key * 101 + entry.value) & 0x7FFFFFFF;
    }
    return h;
  }

  @override
  int dfOf(int termId) {
    final int local = _terms[termId]?.df ?? 0;
    final int sealed = _sealed?.loadedDf(termId) ?? 0;
    final int credit = _handoffDfCredit?[termId] ?? 0;
    final int total = local + sealed - credit;
    return total < 0 ? 0 : total;
  }

  @override
  int maxImpact(int termId, int windowId) {
    final int local = _terms[termId]?.windows?[windowId]?.maxImpact ?? 0;
    final int remote = _sealed?.loadedMaxImpact(termId, windowId) ?? 0;
    return local > remote ? local : remote;
  }

  @override
  int macroCountOf(int termId) {
    final int sealed = _sealed?.loadedMacroCount(termId) ?? 0;
    final chain = _terms[termId];
    if (chain?.windows == null || chain!.windows!.isEmpty) return sealed;
    var maxM = -1;
    for (final w in chain.windows!.keys) {
      final int m = WmbpConstants.macroIdOfWindow(w);
      if (m > maxM) maxM = m;
    }
    final int local = maxM + 1;
    return local > sealed ? local : sealed;
  }

  @override
  int macroMaxImpactOf(int termId, int macroId) {
    final int sealed = _sealed?.loadedMacroMaxImpact(termId, macroId) ?? 0;
    final chain = _terms[termId];
    if (chain?.windows == null) return sealed;
    var local = 0;
    for (final entry in chain!.windows!.entries) {
      if (WmbpConstants.macroIdOfWindow(entry.key) != macroId) continue;
      final int q = entry.value.maxImpact;
      if (q > local) local = q;
    }
    return local > sealed ? local : sealed;
  }

  @override
  List<int> windowIdsOfMacro(int termId, int macroId) {
    final remote =
        _sealed?.loadedWindowIdsOfMacro(termId, macroId) ?? const <int>[];
    final chain = _terms[termId];
    if (chain?.windows == null || chain!.windows!.isEmpty) return remote;
    final local = <int>[];
    for (final w in chain.windows!.keys) {
      if (WmbpConstants.macroIdOfWindow(w) == macroId) local.add(w);
    }
    if (local.isEmpty) return remote;
    local.sort();
    if (remote.isEmpty) return local;
    return _sparseUnionIds(local, remote);
  }

  @override
  List<int> windowIdsOf(int termId) {
    final chain = _terms[termId];
    List<int> local = const <int>[];
    if (chain != null && chain.windows != null) {
      final cached = chain.sortedWindowIds;
      if (cached != null) {
        local = cached;
      } else {
        local = chain.windows!.keys.toList()..sort();
        chain.sortedWindowIds = local;
      }
    }
    final remote = _sealed?.loadedWindowIds(termId) ?? const <int>[];
    if (remote.isEmpty) return local;
    if (local.isEmpty) return remote;
    return _sparseUnionIds(local, remote);
  }

  @override
  WmbpEncodedWindow? windowOf(int termId, int windowId) {
    final window = _terms[termId]?.windows?[windowId];
    final local = window == null || window.offsets.isEmpty
        ? null
        : (window.encoded ??=
            WmbpEncodedWindow.encode(window.offsets, window.impacts));
    final remote = _sealed?.loadedWindow(termId, windowId);
    if (local == null) return remote;
    if (remote == null) return local;
    return WmbpEncodedWindow.encode(
      <int>[...local.offsets, ...remote.offsets],
      <int>[...local.impacts, ...remote.impacts],
    );
  }

  @override
  List<WmbpChampionPosting> championOf(int termId) {
    final local = _terms[termId]?.champion ?? const <WmbpChampionPosting>[];
    final remote =
        _sealed?.loadedChampions(termId) ?? const <WmbpChampionPosting>[];
    if (local.isEmpty) return remote;
    if (remote.isEmpty) return local;
    final merged = <WmbpChampionPosting>[...local, ...remote];
    merged.sort((a, b) {
      final int byQ = b.q8.compareTo(a.q8);
      if (byQ != 0) return byQ;
      return a.docId.compareTo(b.docId);
    });
    if (merged.length > WmbpConstants.championPrefixSize) {
      merged.removeRange(WmbpConstants.championPrefixSize, merged.length);
    }
    return merged;
  }

  @override
  bool isDocActive(int docId) => isDocActiveKnown(docId) ?? false;

  @override
  bool? isDocActiveKnown(int docId) {
    if (_inactive.contains(docId)) return false;
    // A newer local doc for the same PK supersedes any older sealed docId.
    // Covers upsert-without-deactivate until commit rewrites the reverse map.
    final String? pk =
        _docs[docId]?.primaryKey ?? _sealed?.loadedPrimaryKey(docId);
    if (pk != null) {
      final int? current = _pkToDoc[pk];
      if (current != null && current != docId) return false;
    }
    final doc = _docs[docId];
    if (doc != null && !doc.sealed) return true;
    if (doc != null) {
      final mask = _masks[WmbpConstants.windowIdOf(docId)];
      if (mask == null) return true;
      final int offset = WmbpConstants.docOffsetOf(docId);
      return (mask[offset >> 5] & (1 << (offset & 31))) != 0;
    }
    // Sealed-only: null means ActiveMask page not in cache yet.
    return _sealed?.loadedActiveBit(docId);
  }

  @override
  int activeCountOf(int windowId) {
    final int total = (_activeCount[windowId] ?? 0) +
        (_sealed?.sealedActiveCount(windowId) ?? 0) -
        (_inactiveWindows[windowId] ?? 0);
    return total < 0 ? 0 : total;
  }

  @override
  String? primaryKeyOf(int docId) =>
      _docs[docId]?.primaryKey ?? _sealed?.loadedPrimaryKey(docId);

  @override
  int? currentDocIdOf(String primaryKey) => _pkToDoc[primaryKey];

  @override
  int? sealedDocIdOfSync(String primaryKey) {
    final view = _sealed;
    if (view == null) return null;
    final int docId = view.lookupPkResident(primaryKey);
    return docId >= 0 ? docId : null;
  }

  @override
  Future<int?> sealedDocIdOf(String primaryKey) async =>
      _sealed?.lookupPk(primaryKey);

  @override
  bool isLocalDoc(int docId) => _docs.containsKey(docId);

  @override
  Future<String?> primaryKeyOfAsync(int docId) async {
    final local = _docs[docId]?.primaryKey;
    if (local != null) return local;
    final cached = _sealed?.loadedPrimaryKey(docId);
    if (cached != null) return cached;
    return _sealed?.lookupFwd(docId);
  }

  @override
  int impactOf(int docId, int termId) {
    final doc = _docs[docId];
    if (doc != null) return doc.impacts[termId] ?? 0;
    final window = windowOf(termId, WmbpConstants.windowIdOf(docId));
    return window?.impactAt(WmbpConstants.docOffsetOf(docId)) ?? 0;
  }

  @override
  Iterable<WmbpPendingView> get pendingDocs => _pending.values.map(
        (doc) => WmbpPendingView(
          docId: doc.docId,
          primaryKey: doc.primaryKey,
          impacts: doc.impacts,
        ),
      );
}

class _Doc {
  final int docId;
  final String primaryKey;
  final Map<int, int> impacts;
  bool sealed;

  _Doc({
    required this.docId,
    required this.primaryKey,
    required this.impacts,
    required this.sealed,
  });
}

class _WindowAcc {
  final List<int> offsets = <int>[];
  final List<int> impacts = <int>[];
  int maxImpact = 0;
  WmbpEncodedWindow? encoded;
}

class _TermChain {
  int df = 0;
  List<WmbpChampionPosting>? champion;
  Map<int, _WindowAcc>? windows;
  List<int>? sortedWindowIds;
}
