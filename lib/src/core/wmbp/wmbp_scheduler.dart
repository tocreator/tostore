import 'dart:typed_data';

import '../compute/yield_controller.dart';
import 'wmbp_constants.dart';
import 'wmbp_score.dart';
import 'wmbp_swar.dart';
import 'wmbp_window.dart';

/// One compiled query term.
class WmbpQueryTerm {
  final int termId;
  final int weightMilli;

  const WmbpQueryTerm({required this.termId, required this.weightMilli});
}

/// One ranked hit. [score] is normalized against the best raw score in the set.
class WmbpHit {
  final String primaryKey;
  final int docId;
  final int rawUnits;
  final double score;

  const WmbpHit({
    required this.primaryKey,
    required this.docId,
    required this.rawUnits,
    required this.score,
  });
}

/// Chain-head elite posting.
class WmbpChampionPosting {
  final int docId;
  final int q8;

  const WmbpChampionPosting({required this.docId, required this.q8});

  /// Descending q8, then ascending docId (stable elite order).
  static int compareElite(WmbpChampionPosting a, WmbpChampionPosting b) {
    final int byQ = b.q8.compareTo(a.q8);
    if (byQ != 0) return byQ;
    return a.docId.compareTo(b.docId);
  }

  /// Inserts [docId]/[q8] into an ordered champion prefix (max
  /// [WmbpConstants.championPrefixSize]) via binary search — O(cap), not a
  /// full re-sort. Full `List.sort` on every push was pathologically slow on
  /// long-document seals (tens of millions of pushes).
  static void pushOrdered(List<WmbpChampionPosting> list, int docId, int q8) {
    final int cap = WmbpConstants.championPrefixSize;
    final posting = WmbpChampionPosting(docId: docId, q8: q8);
    // Drop when the current floor is already better or equal.
    if (list.length >= cap && compareElite(list.last, posting) <= 0) {
      return;
    }
    var lo = 0;
    var hi = list.length;
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (compareElite(list[mid], posting) <= 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (list.length < cap) {
      list.insert(lo, posting);
      return;
    }
    // Cap full and [posting] beats the floor ⇒ lo ∈ [0, cap).
    for (int i = cap - 1; i > lo; i--) {
      list[i] = list[i - 1];
    }
    list[lo] = posting;
  }

  /// One-shot top-[WmbpConstants.championPrefixSize] selection (sort once).
  /// Prefer this when sealing a brand-new term with all postings in hand.
  static List<WmbpChampionPosting> selectTop(
      List<WmbpChampionPosting> candidates) {
    if (candidates.isEmpty) return const <WmbpChampionPosting>[];
    candidates.sort(compareElite);
    final int cap = WmbpConstants.championPrefixSize;
    if (candidates.length <= cap) return candidates;
    return candidates.sublist(0, cap);
  }
}

/// Unsealed document still visible to retrieval.
class WmbpPendingView {
  final int docId;
  final String primaryKey;
  final Map<int, int> impacts;

  const WmbpPendingView({
    required this.docId,
    required this.primaryKey,
    required this.impacts,
  });
}

/// Read surface used by the scheduler.
abstract class WmbpPostingSource {
  int get activeDocCount;

  int dfOf(int termId);

  int maxImpact(int termId, int windowId);

  /// Flat window ids (loaded macros only for sealed terms). Prefer macro APIs.
  List<int> windowIdsOf(int termId);

  /// Number of macros in the sealed Root Head (0 when term is pending-only).
  int macroCountOf(int termId);

  /// Root `macroMaxImpact[m]` for Stage-2 macro leap (0 if unknown).
  int macroMaxImpactOf(int termId, int macroId);

  /// Window ids inside one loaded macro (empty until macro is resident).
  List<int> windowIdsOfMacro(int termId, int macroId);

  WmbpEncodedWindow? windowOf(int termId, int windowId);

  List<WmbpChampionPosting> championOf(int termId);

  bool isDocActive(int docId);

  /// ActiveMask view for [docId]: `true`/`false` when known, `null` when the
  /// sealed mask page is not loaded yet. Callers must not treat `null` as a
  /// confirmed ghost — that would pin [considered] and drop recall.
  bool? isDocActiveKnown(int docId);

  int activeCountOf(int windowId);

  String? primaryKeyOf(int docId);

  Future<String?> primaryKeyOfAsync(int docId);

  /// Latest in-memory docId for [primaryKey], if any (pending / local overlay).
  int? currentDocIdOf(String primaryKey);

  /// Latest sealed reverse-map docId for [primaryKey], if known without I/O.
  int? sealedDocIdOfSync(String primaryKey);

  /// Latest sealed reverse-map docId for [primaryKey] (may read rev pages).
  Future<int?> sealedDocIdOf(String primaryKey);

  /// True when [docId] is still resident in the local/pending corpus.
  bool isLocalDoc(int docId);

  /// True when [primaryKey] has a cold-rev pending deactivation.
  bool isPkPendingRemoval(String primaryKey);

  int impactOf(int docId, int termId);

  Iterable<WmbpPendingView> get pendingDocs;
}

class _Heap {
  int k;
  int count = 0;
  // Plain List<int>: Int32List truncates rare-term units past 2^31-1 into
  // negative rawScores; Int64List is unsupported on dart2js/web. Dart int on
  // the VM is arbitrary-precision; on web it is a JS Number (exact to 2^53),
  // which covers practical additive units and docIds.
  List<int> docIds;
  List<int> scores;

  _Heap(this.k)
      : docIds = List<int>.filled(k > 16 ? k : 16, 0),
        scores = List<int>.filled(k > 16 ? k : 16, 0);

  int get length => count;

  int get worstScore => scores[0];
  int get worstDocId => docIds[0];

  void reset(int newK) {
    k = newK;
    count = 0;
    if (docIds.length < k) {
      docIds = List<int>.filled(k, 0);
      scores = List<int>.filled(k, 0);
    }
  }

  void offer(int docId, int score) {
    if (k <= 0) return;
    if (count < k) {
      final idx = count++;
      docIds[idx] = docId;
      scores[idx] = score;
      _siftUp(idx);
      return;
    }
    if (_isBetter(docId, score, docIds[0], scores[0])) {
      docIds[0] = docId;
      scores[0] = score;
      _siftDown(0);
    }
  }

  /// Insert or raise an existing [docId] score (Champion soft-warm → full rescoring).
  void upsert(int docId, int score) {
    for (int i = 0; i < count; i++) {
      if (docIds[i] != docId) continue;
      if (score > scores[i]) {
        scores[i] = score;
        _siftUp(i);
        _siftDown(i);
      }
      return;
    }
    offer(docId, score);
  }

  void sortDescending() {
    for (int i = 0; i < count - 1; i++) {
      for (int j = i + 1; j < count; j++) {
        if (_isWorse(i, j)) {
          _swap(i, j);
        }
      }
    }
  }

  bool _isBetter(int aDocId, int aScore, int bDocId, int bScore) {
    if (aScore != bScore) return aScore > bScore;
    return aDocId < bDocId;
  }

  bool _isWorse(int i, int j) {
    final s1 = scores[i];
    final s2 = scores[j];
    if (s1 != s2) return s1 < s2;
    return docIds[i] > docIds[j];
  }

  bool _isChildWorseThanParent(int child, int parent) {
    final sc = scores[child];
    final sp = scores[parent];
    if (sc != sp) return sc < sp;
    return docIds[child] > docIds[parent];
  }

  void _swap(int i, int j) {
    final tmpDoc = docIds[i];
    docIds[i] = docIds[j];
    docIds[j] = tmpDoc;

    final tmpScore = scores[i];
    scores[i] = scores[j];
    scores[j] = tmpScore;
  }

  void _siftUp(int idx) {
    while (idx > 0) {
      final parent = (idx - 1) >> 1;
      if (!_isChildWorseThanParent(idx, parent)) break;
      _swap(idx, parent);
      idx = parent;
    }
  }

  void _siftDown(int idx) {
    final n = count;
    while (true) {
      final left = (idx << 1) + 1;
      if (left >= n) break;
      final right = left + 1;
      var worstChild = left;
      if (right < n && _isChildWorseThanParent(right, left)) {
        worstChild = right;
      }
      if (!_isChildWorseThanParent(worstChild, idx)) break;
      _swap(idx, worstChild);
      idx = worstChild;
    }
  }
}

/// Per-query scratch so async paged search cannot clobber another query.
class _WmbpSearchContext {
  final Uint32List seen = Uint32List(WmbpConstants.windowSize);
  int seenStamp = 0;
  final Set<int> considered = <int>{};
  final List<WmbpEncodedWindow?> localWindows =
      List<WmbpEncodedWindow?>.filled(64, null);
  final List<_CompiledTerm> orderBuffer = <_CompiledTerm>[];
  final _Heap heap = _Heap(10);
  final List<_CompiledTerm> compiled = <_CompiledTerm>[];
  final List<({int windowId, int bound})> windowBounds =
      <({int windowId, int bound})>[];
  final List<int> survivingMacrosScratch = <int>[];
  final List<int> expandedWindowsScratch = <int>[];
  final Set<int> seenWindowsScratch = <int>{};

  int nextStamp() {
    var stamp = ++seenStamp;
    if (stamp >= 0x7FFFFFFF) {
      seen.fillRange(0, seen.length, 0);
      seenStamp = 1;
      stamp = 1;
    }
    return stamp;
  }

  void prepare(int topK) {
    heap.reset(topK);
    considered.clear();
    compiled.clear();
    windowBounds.clear();
    orderBuffer.clear();
    survivingMacrosScratch.clear();
    expandedWindowsScratch.clear();
    seenWindowsScratch.clear();
  }
}

/// Small pool of search contexts (same-isolate concurrent async queries).
class _WmbpSearchContextPool {
  static final List<_WmbpSearchContext> _free = <_WmbpSearchContext>[];

  static _WmbpSearchContext acquire() {
    if (_free.isNotEmpty) return _free.removeLast();
    return _WmbpSearchContext();
  }

  static void release(_WmbpSearchContext ctx) {
    ctx.considered.clear();
    ctx.compiled.clear();
    ctx.windowBounds.clear();
    ctx.orderBuffer.clear();
    ctx.survivingMacrosScratch.clear();
    ctx.expandedWindowsScratch.clear();
    ctx.seenWindowsScratch.clear();
    if (_free.length < 8) _free.add(ctx);
  }
}

/// Lossless Top-K over a WMBP posting source.
///
/// Prune bounds use the same integer score as the heap, so a document that
/// belongs in the top-K is never discarded. Recall against a full scan of the
/// same model is 1.
List<WmbpHit> wmbpSearchTopK({
  required WmbpPostingSource source,
  required List<WmbpQueryTerm> terms,
  required int topK,
  required bool useIdf,
  bool conjunctive = false,
  WmbpSearchStats? stats,
  bool Function(int termId, int windowId)? ensureWindowSync,
  bool Function(int termId, int macroId)? ensureMacroSync,
}) {
  if (topK <= 0 || terms.isEmpty || source.activeDocCount <= 0) {
    return const <WmbpHit>[];
  }
  if (conjunctive && !_allTermsPresent(source, terms)) {
    return const <WmbpHit>[];
  }
  final ctx = _WmbpSearchContextPool.acquire();
  try {
    ctx.prepare(topK);
    final compiled = ctx.compiled;
    for (final term in terms) {
      if (term.weightMilli <= 0) continue;
      final int df = source.dfOf(term.termId);
      if (df <= 0) continue;
      final int idf =
          useIdf ? WmbpScore.idfMilli(df, source.activeDocCount) : 1;
      final int unit = idf * term.weightMilli;
      if (unit <= 0) continue;
      compiled.add(_CompiledTerm(term.termId, unit, compiled.length));
    }
    if (compiled.isEmpty) return const <WmbpHit>[];
    if (conjunctive && !_compiledCovers(terms, compiled.length)) {
      return const <WmbpHit>[];
    }

    final heap = ctx.heap;
    var stamp = ctx.nextStamp();
    final seen = ctx.seen;
    final considered = ctx.considered;
    int theta = 0;
    var coldWindowMiss = false;

    void consider(int docId, int score) {
      if (considered.contains(docId)) return;
      if (score <= 0) return;
      if (heap.length == topK) {
        final worst = heap.worstScore;
        if (score < worst) return;
        if (score == worst && docId >= heap.worstDocId) return;
      }
      final bool? active = source.isDocActiveKnown(docId);
      if (active == false) {
        considered.add(docId);
        stats?.ghostPrevented++;
        return;
      }
      // Cold ActiveMask: do not pin — window scan re-evaluates after load.
      if (active == null) return;
      considered.add(docId);
      heap.upsert(docId, score);
      if (heap.length == topK) theta = heap.worstScore;
    }

    int scoreDoc(int docId) {
      var sum = 0;
      for (final term in compiled) {
        final int q = source.impactOf(docId, term.termId);
        if (q <= 0) {
          if (conjunctive) return 0;
          continue;
        }
        sum += term.unit * q;
      }
      return sum;
    }

    // Champion Prefix: exact lower-bound warm without requiring window bodies.
    for (final term in compiled) {
      final champions = source.championOf(term.termId);
      for (int c = 0; c < champions.length; c++) {
        final posting = champions[c];
        final int partial = posting.q8 * term.unit;
        if (heap.length == topK && partial < theta) break;
        final int windowId = WmbpConstants.windowIdOf(posting.docId);
        final bool? active = source.isDocActiveKnown(posting.docId);
        if (active != true) {
          // false = ghost; null = cold mask — never raise θ without a
          // confirmed live bit (WMBP iron rule: no Ghost θ).
          if (active == false) stats?.ghostPrevented++;
          continue;
        }
        final bool fullReady = source.windowOf(term.termId, windowId) != null &&
            _scoreWindowsReady(source, compiled, windowId);
        if (fullReady) {
          consider(posting.docId, scoreDoc(posting.docId));
        } else if (partial > 0) {
          // Soft raise θ with a proven lower bound; do not pin [considered]
          // so a later full multi-term score can still replace it.
          heap.upsert(posting.docId, partial);
          if (heap.length == topK) theta = heap.worstScore;
        }
      }
    }

    Set<int>? pendingWindows;
    for (final pending in source.pendingDocs) {
      (pendingWindows ??= <int>{}).add(WmbpConstants.windowIdOf(pending.docId));
      consider(pending.docId, scoreDoc(pending.docId));
    }

    final survivingMacros = _survivingMacros(
      source: source,
      compiled: compiled,
      heap: heap,
      theta: theta,
      conjunctive: conjunctive,
      stats: stats,
      out: ctx.survivingMacrosScratch,
    );
    if (ensureMacroSync != null) {
      for (final macroId in survivingMacros) {
        for (final term in compiled) {
          if (source.macroMaxImpactOf(term.termId, macroId) <= 0) continue;
          if (!ensureMacroSync(term.termId, macroId)) {
            coldWindowMiss = true;
            break;
          }
        }
        if (coldWindowMiss) break;
      }
    }
    if (coldWindowMiss) {
      stats?.coldPrimaryKeyMisses++;
      return const <WmbpHit>[];
    }

    final windows = _expandWindowsViaMacroLeap(
      source: source,
      compiled: compiled,
      pendingWindows: pendingWindows,
      heap: heap,
      theta: theta,
      conjunctive: conjunctive,
      stats: stats,
      prefilteredMacros: survivingMacros,
      out: ctx.expandedWindowsScratch,
      seenScratch: ctx.seenWindowsScratch,
    );

    _collectWindowBounds(
      source: source,
      compiled: compiled,
      windows: windows,
      pendingWindows: pendingWindows,
      heap: heap,
      theta: theta,
      conjunctive: conjunctive,
      stats: stats,
      out: ctx.windowBounds,
    );

    for (final item in ctx.windowBounds) {
      final int windowId = item.windowId;
      final int bound = item.bound;
      if (heap.length == topK && bound < theta) {
        stats?.superWindowSkips++;
        continue;
      }
      if (ensureWindowSync != null) {
        for (final term in compiled) {
          if (source.maxImpact(term.termId, windowId) <= 0) continue;
          if (!ensureWindowSync(term.termId, windowId)) {
            coldWindowMiss = true;
            break;
          }
        }
        if (coldWindowMiss) {
          stats?.coldPrimaryKeyMisses++;
          break;
        }
      }
      _scanWindow(
        ctx: ctx,
        source: source,
        compiled: compiled,
        windowId: windowId,
        bound: bound,
        theta: heap.length == topK ? theta : 0,
        stamp: stamp,
        stats: stats,
        consider: consider,
        scoreDoc: scoreDoc,
        conjunctive: conjunctive,
      );
      stamp++;
      if (stamp == 0xFFFFFFFF) {
        seen.fillRange(0, seen.length, 0);
        stamp = 1;
        ctx.seenStamp = 1;
      }
    }

    heap.sortDescending();
    final int count = heap.count;
    if (count == 0) return const <WmbpHit>[];
    final hits = <WmbpHit>[];
    for (int i = 0; i < count; i++) {
      final docId = heap.docIds[i];
      final score = heap.scores[i];
      final pk = source.primaryKeyOf(docId);
      if (pk == null || pk.isEmpty) {
        stats?.coldPrimaryKeyMisses++;
        continue;
      }
      if (!_isLiveDocIdSync(source, pk, docId)) continue;
      hits.add(WmbpHit(
        primaryKey: pk,
        docId: docId,
        rawUnits: score,
        score: 0,
      ));
    }
    return _collapseHitsByPrimaryKey(hits);
  } finally {
    _WmbpSearchContextPool.release(ctx);
  }
}

Future<List<WmbpHit>> wmbpSearchTopKPaged({
  required WmbpPostingSource source,
  required List<WmbpQueryTerm> terms,
  required int topK,
  required bool useIdf,
  required Future<void> Function(int termId) ensureHead,
  bool Function(int termId)? ensureHeadSync,
  required Future<void> Function(int termId, int windowId) ensureWindow,
  bool Function(int termId, int windowId)? ensureWindowSync,
  Future<void> Function(int termId, int macroId)? ensureMacro,
  bool Function(int termId, int macroId)? ensureMacroSync,
  bool conjunctive = false,
  WmbpSearchStats? stats,
}) async {
  if (topK <= 0 || terms.isEmpty) return const <WmbpHit>[];
  if (ensureHeadSync != null) {
    for (final term in terms) {
      if (!ensureHeadSync(term.termId)) {
        await ensureHead(term.termId);
      }
    }
  } else {
    for (final term in terms) {
      await ensureHead(term.termId);
    }
  }
  if (conjunctive && !_allTermsPresent(source, terms)) {
    return const <WmbpHit>[];
  }
  if (source.activeDocCount <= 0) return const <WmbpHit>[];

  final ctx = _WmbpSearchContextPool.acquire();
  try {
    ctx.prepare(topK);
    final compiled = ctx.compiled;
    for (final term in terms) {
      if (term.weightMilli <= 0) continue;
      final int df = source.dfOf(term.termId);
      if (df <= 0) continue;
      final int idf =
          useIdf ? WmbpScore.idfMilli(df, source.activeDocCount) : 1;
      final int unit = idf * term.weightMilli;
      if (unit <= 0) continue;
      compiled.add(_CompiledTerm(term.termId, unit, compiled.length));
    }
    if (compiled.isEmpty) return const <WmbpHit>[];
    if (conjunctive && !_compiledCovers(terms, compiled.length)) {
      return const <WmbpHit>[];
    }

    final heap = ctx.heap;
    var stamp = ctx.nextStamp();
    final seen = ctx.seen;
    final considered = ctx.considered;
    int theta = 0;

    void consider(int docId, int score) {
      if (considered.contains(docId)) return;
      if (score <= 0) return;
      if (heap.length == topK) {
        final worst = heap.worstScore;
        if (score < worst) return;
        if (score == worst && docId >= heap.worstDocId) return;
      }
      final bool? active = source.isDocActiveKnown(docId);
      if (active == false) {
        considered.add(docId);
        stats?.ghostPrevented++;
        return;
      }
      // Cold ActiveMask: do not pin — ensureWindow below loads mask then scan.
      if (active == null) return;
      considered.add(docId);
      heap.upsert(docId, score);
      if (heap.length == topK) theta = heap.worstScore;
    }

    int scoreDoc(int docId) {
      var sum = 0;
      for (final term in compiled) {
        final int q = source.impactOf(docId, term.termId);
        if (q <= 0) {
          if (conjunctive) return 0;
          continue;
        }
        sum += term.unit * q;
      }
      return sum;
    }

    for (final term in compiled) {
      for (final posting in source.championOf(term.termId)) {
        final int partial = posting.q8 * term.unit;
        if (heap.length == topK && partial < theta) break;
        final int windowId = WmbpConstants.windowIdOf(posting.docId);
        final bool? active = source.isDocActiveKnown(posting.docId);
        if (active != true) {
          if (active == false) stats?.ghostPrevented++;
          continue;
        }
        final bool fullReady = source.windowOf(term.termId, windowId) != null &&
            _scoreWindowsReady(source, compiled, windowId);
        if (fullReady) {
          consider(posting.docId, scoreDoc(posting.docId));
        } else if (partial > 0) {
          heap.upsert(posting.docId, partial);
          if (heap.length == topK) theta = heap.worstScore;
        }
      }
    }

    final pendingWindows = <int>{};
    for (final pending in source.pendingDocs) {
      pendingWindows.add(WmbpConstants.windowIdOf(pending.docId));
      consider(pending.docId, scoreDoc(pending.docId));
    }

    // Stage-2a: leap macros using Root macroMaxImpact (no chunk I/O).
    final survivingMacros = _survivingMacros(
      source: source,
      compiled: compiled,
      heap: heap,
      theta: theta,
      conjunctive: conjunctive,
      stats: stats,
      out: ctx.survivingMacrosScratch,
    );
    // Stage-2b: load only surviving macro chunks (sync first, then bounded
    // parallel async). Cap in-flight I/O so seal/search share the disk without
    // unbounded fan-out; yield between batches for UI.
    if (ensureMacro != null && survivingMacros.isNotEmpty) {
      final jobs = <(int termId, int macroId)>[];
      for (final macroId in survivingMacros) {
        for (final term in compiled) {
          if (source.macroMaxImpactOf(term.termId, macroId) <= 0) continue;
          if (ensureMacroSync != null &&
              ensureMacroSync(term.termId, macroId)) {
            continue;
          }
          jobs.add((term.termId, macroId));
        }
      }
      if (jobs.isNotEmpty) {
        const batch = 8;
        final yc = YieldController(
          'wmbp_ensure_macro_batches',
          checkInterval: 1,
          minCheckInterval: 1,
        );
        for (int i = 0; i < jobs.length; i += batch) {
          final end = i + batch < jobs.length ? i + batch : jobs.length;
          await Future.wait([
            for (int j = i; j < end; j++) ensureMacro(jobs[j].$1, jobs[j].$2),
          ]);
          final y = yc.maybeYield();
          if (y != null) await y;
        }
      }
    }
    final windows = _expandWindowsViaMacroLeap(
      source: source,
      compiled: compiled,
      pendingWindows: pendingWindows,
      heap: heap,
      theta: theta,
      conjunctive: conjunctive,
      stats: stats,
      prefilteredMacros: survivingMacros,
      out: ctx.expandedWindowsScratch,
      seenScratch: ctx.seenWindowsScratch,
    );
    _collectWindowBounds(
      source: source,
      compiled: compiled,
      windows: windows,
      pendingWindows: pendingWindows,
      heap: heap,
      theta: theta,
      conjunctive: conjunctive,
      stats: stats,
      out: ctx.windowBounds,
    );

    // Coarse yield: cache-hit scans have no await; keep UI responsive on
    // long sparse leaps without yielding every posting.
    final windowYc = YieldController(
      'wmbp_search_window_bounds',
      checkInterval: 16,
      minCheckInterval: 8,
    );
    for (final item in ctx.windowBounds) {
      final y = windowYc.maybeYield();
      if (y != null) await y;
      final int windowId = item.windowId;
      final int bound = item.bound;
      if (heap.length == topK && bound < theta) {
        stats?.superWindowSkips++;
        continue;
      }
      for (final term in compiled) {
        if (source.maxImpact(term.termId, windowId) <= 0) continue;
        if (ensureWindowSync == null ||
            !ensureWindowSync(term.termId, windowId)) {
          await ensureWindow(term.termId, windowId);
        }
      }

      _scanWindow(
        ctx: ctx,
        source: source,
        compiled: compiled,
        windowId: windowId,
        bound: bound,
        theta: heap.length == topK ? theta : 0,
        stamp: stamp,
        stats: stats,
        consider: consider,
        scoreDoc: scoreDoc,
        conjunctive: conjunctive,
      );
      stamp++;
      if (stamp == 0xFFFFFFFF) {
        seen.fillRange(0, seen.length, 0);
        stamp = 1;
        ctx.seenStamp = 1;
      }
    }

    heap.sortDescending();
    final int count = heap.count;
    if (count == 0) return const <WmbpHit>[];
    final hits = <WmbpHit>[];
    for (int i = 0; i < count; i++) {
      final docId = heap.docIds[i];
      final score = heap.scores[i];
      var pk = source.primaryKeyOf(docId);
      if (pk == null || pk.isEmpty) {
        pk = await source.primaryKeyOfAsync(docId);
      }
      if (pk == null || pk.isEmpty) {
        continue;
      }
      if (!await _isLiveDocId(source, pk, docId)) continue;
      hits.add(WmbpHit(
        primaryKey: pk,
        docId: docId,
        rawUnits: score,
        score: 0,
      ));
    }
    return _collapseHitsByPrimaryKey(hits);
  } finally {
    _WmbpSearchContextPool.release(ctx);
  }
}

/// Drops superseded sealed docIds when the live mapping is already known.
///
/// When the sealed reverse-map cache misses, returns true so the sync search
/// path can escalate to async verification instead of dropping live hits.
bool _isLiveDocIdSync(WmbpPostingSource source, String pk, int docId) {
  if (source.isPkPendingRemoval(pk)) return false;
  final int? local = source.currentDocIdOf(pk);
  if (local != null) return local == docId;
  final int? sealed = source.sealedDocIdOfSync(pk);
  if (sealed != null) return sealed == docId;
  return true;
}

Future<bool> _isLiveDocId(
  WmbpPostingSource source,
  String pk,
  int docId,
) async {
  if (source.isPkPendingRemoval(pk)) return false;
  final int? local = source.currentDocIdOf(pk);
  if (local != null) return local == docId;
  // Bitmap-first: when no local overlay / pending removal and ActiveMask says
  // live, skip cold reverse-tree I/O.
  if (local == null &&
      !source.isPkPendingRemoval(pk) &&
      source.isDocActiveKnown(docId) == true) {
    final int? sealedSync = source.sealedDocIdOfSync(pk);
    if (sealedSync == null) return true;
    return sealedSync == docId;
  }
  final int? sealed =
      source.sealedDocIdOfSync(pk) ?? await source.sealedDocIdOf(pk);
  if (sealed != null) return sealed == docId;
  // No reverse-map entry and not a local/pending doc → orphan sealed ghost.
  return source.isLocalDoc(docId);
}

/// Keeps the highest-[rawUnits] hit per primary key (docId churn on upsert).
List<WmbpHit> _collapseHitsByPrimaryKey(List<WmbpHit> hits) {
  if (hits.length <= 1) {
    if (hits.isEmpty) return hits;
    final only = hits.first;
    return [
      WmbpHit(
        primaryKey: only.primaryKey,
        docId: only.docId,
        rawUnits: only.rawUnits,
        score: 1,
      ),
    ];
  }
  final best = <String, WmbpHit>{};
  var collapsed = false;
  for (final hit in hits) {
    final prev = best[hit.primaryKey];
    if (prev == null) {
      best[hit.primaryKey] = hit;
      continue;
    }
    collapsed = true;
    if (hit.rawUnits > prev.rawUnits ||
        (hit.rawUnits == prev.rawUnits && hit.docId < prev.docId)) {
      best[hit.primaryKey] = hit;
    }
  }
  final List<WmbpHit> ordered;
  if (!collapsed && best.length == hits.length) {
    ordered = hits;
  } else {
    ordered = best.values.toList()
      ..sort((a, b) {
        final int byScore = b.rawUnits.compareTo(a.rawUnits);
        if (byScore != 0) return byScore;
        return a.docId.compareTo(b.docId);
      });
  }
  final int bestUnits = ordered.first.rawUnits;
  return [
    for (final hit in ordered)
      WmbpHit(
        primaryKey: hit.primaryKey,
        docId: hit.docId,
        rawUnits: hit.rawUnits,
        score: bestUnits > 0 ? hit.rawUnits / bestUnits : 0,
      ),
  ];
}

class _CompiledTerm {
  final int termId;
  final int unit;

  /// Index into the compiled list — avoids [List.indexOf] in the scan hot path.
  final int slotIndex;
  const _CompiledTerm(this.termId, this.unit, this.slotIndex);
}

int _windowBound(
  WmbpPostingSource source,
  List<_CompiledTerm> terms,
  int windowId, {
  required bool conjunctive,
}) {
  var sum = 0;
  for (final term in terms) {
    final int maxQ = source.maxImpact(term.termId, windowId);
    if (maxQ <= 0) {
      if (conjunctive) return 0;
      continue;
    }
    sum += term.unit * maxQ;
  }
  return sum;
}

bool _allTermsPresent(WmbpPostingSource source, List<WmbpQueryTerm> terms) {
  var required = 0;
  for (final term in terms) {
    if (term.weightMilli <= 0) continue;
    required++;
    if (source.dfOf(term.termId) <= 0) return false;
  }
  return required > 0;
}

bool _compiledCovers(List<WmbpQueryTerm> terms, int compiledCount) {
  var required = 0;
  for (final term in terms) {
    if (term.weightMilli > 0) required++;
  }
  return compiledCount == required;
}

/// Root-level macro leap using [WmbpPostingSource.macroMaxImpactOf] only.
List<int> _survivingMacros({
  required WmbpPostingSource source,
  required List<_CompiledTerm> compiled,
  required _Heap heap,
  required int theta,
  required bool conjunctive,
  required WmbpSearchStats? stats,
  List<int>? out,
}) {
  var maxCount = 0;
  for (final term in compiled) {
    final int c = source.macroCountOf(term.termId);
    if (c > maxCount) maxCount = c;
  }
  final dest = out ?? <int>[];
  dest.clear();
  if (maxCount <= 0) return dest;
  for (int m = 0; m < maxCount; m++) {
    final int bound = _rootMacroBound(
      source,
      compiled,
      m,
      conjunctive: conjunctive,
    );
    if (bound <= 0) continue;
    if (heap.length == heap.k && bound < theta) {
      stats?.macroWindowSkips++;
      continue;
    }
    dest.add(m);
  }
  return dest;
}

int _rootMacroBound(
  WmbpPostingSource source,
  List<_CompiledTerm> terms,
  int macroId, {
  bool conjunctive = false,
}) {
  if (conjunctive) {
    var sum = 0;
    for (final term in terms) {
      final int q = source.macroMaxImpactOf(term.termId, macroId);
      if (q <= 0) return 0;
      sum += term.unit * q;
    }
    return sum;
  }
  var sum = 0;
  for (final term in terms) {
    final int q = source.macroMaxImpactOf(term.termId, macroId);
    if (q > 0) sum += term.unit * q;
  }
  return sum;
}

/// Expand surviving macros into sorted window ids (loaded slices + pending).
///
/// [prefilteredMacros] must not be the same list instance as [out].
List<int> _expandWindowsViaMacroLeap({
  required WmbpPostingSource source,
  required List<_CompiledTerm> compiled,
  required Set<int>? pendingWindows,
  required _Heap heap,
  required int theta,
  required bool conjunctive,
  required WmbpSearchStats? stats,
  List<int>? prefilteredMacros,
  List<int>? out,
  Set<int>? seenScratch,
}) {
  assert(
    prefilteredMacros == null ||
        out == null ||
        !identical(prefilteredMacros, out),
    'prefilteredMacros and out must be distinct lists',
  );
  final macros = prefilteredMacros ??
      _survivingMacros(
        source: source,
        compiled: compiled,
        heap: heap,
        theta: theta,
        conjunctive: conjunctive,
        stats: stats,
      );
  final dest = out ?? <int>[];
  dest.clear();
  seenScratch?.clear();
  if (macros.isEmpty && (pendingWindows == null || pendingWindows.isEmpty)) {
    return dest;
  }
  if (!conjunctive) {
    final seen = seenScratch ?? <int>{};
    seen.clear();
    for (int t = 0; t < compiled.length; t++) {
      final termId = compiled[t].termId;
      var added = false;
      for (int mi = 0; mi < macros.length; mi++) {
        final int m = macros[mi];
        if (source.macroMaxImpactOf(termId, m) <= 0) continue;
        final wins = source.windowIdsOfMacro(termId, m);
        for (int i = 0; i < wins.length; i++) {
          final w = wins[i];
          if (seen.add(w)) dest.add(w);
          added = true;
        }
      }
      if (!added && source.macroCountOf(termId) == 0) {
        final fallback = source.windowIdsOf(termId);
        for (int i = 0; i < fallback.length; i++) {
          final w = fallback[i];
          if (seen.add(w)) dest.add(w);
        }
      }
    }
    if (pendingWindows != null) {
      for (final pw in pendingWindows) {
        if (seen.add(pw)) dest.add(pw);
      }
    }
    if (dest.length > 1) {
      dest.sort();
    }
    return dest;
  }
  final termWindows = <List<int>>[];
  for (final term in compiled) {
    final ids = <int>[];
    for (final m in macros) {
      if (source.macroMaxImpactOf(term.termId, m) <= 0) continue;
      ids.addAll(source.windowIdsOfMacro(term.termId, m));
    }
    // Pending-only terms may have no sealed macros yet.
    if (ids.isEmpty) {
      final fallback = source.windowIdsOf(term.termId);
      if (fallback.isNotEmpty) ids.addAll(fallback);
    }
    if (ids.length > 1) ids.sort();
    termWindows.add(ids);
  }
  if (pendingWindows == null || pendingWindows.isEmpty) {
    return _sparseIntersect(termWindows, out: dest);
  }
  final pendingSorted = pendingWindows.toList()..sort();
  return _sparseIntersect(<List<int>>[
    ...termWindows,
    pendingSorted,
  ], out: dest);
}

/// Builds per-window bounds after macro leap has already filtered candidates.
void _collectWindowBounds({
  required WmbpPostingSource source,
  required List<_CompiledTerm> compiled,
  required List<int> windows,
  required Set<int>? pendingWindows,
  required _Heap heap,
  required int theta,
  required bool conjunctive,
  required WmbpSearchStats? stats,
  required List<({int windowId, int bound})> out,
}) {
  out.clear();
  if (windows.isEmpty) return;

  for (int i = 0; i < windows.length; i++) {
    final windowId = windows[i];
    if (source.activeCountOf(windowId) == 0 &&
        (pendingWindows == null || !pendingWindows.contains(windowId))) {
      stats?.superWindowSkips++;
      continue;
    }
    final int bound = _windowBound(
      source,
      compiled,
      windowId,
      conjunctive: conjunctive,
    );
    if (heap.length == heap.k && bound < theta) {
      stats?.superWindowSkips++;
      continue;
    }
    out.add((windowId: windowId, bound: bound));
  }
  if (out.length > 1) {
    out.sort((a, b) => b.bound.compareTo(a.bound));
  }
}

/// True when every compiled term that touches [windowId] has its window body
/// resident — required before durable [considered] pinning on the champion path.
bool _scoreWindowsReady(
  WmbpPostingSource source,
  List<_CompiledTerm> compiled,
  int windowId,
) {
  for (final term in compiled) {
    if (source.maxImpact(term.termId, windowId) <= 0) continue;
    if (source.windowOf(term.termId, windowId) == null) return false;
  }
  return true;
}

void _scanWindow({
  required _WmbpSearchContext ctx,
  required WmbpPostingSource source,
  required List<_CompiledTerm> compiled,
  required int windowId,
  required int bound,
  required int theta,
  required int stamp,
  required WmbpSearchStats? stats,
  required void Function(int docId, int score) consider,
  required int Function(int docId) scoreDoc,
  bool conjunctive = false,
}) {
  final seen = ctx.seen;
  final int numTerms = compiled.length;
  final List<WmbpEncodedWindow?> localWindows =
      numTerms <= ctx.localWindows.length
          ? ctx.localWindows
          : List<WmbpEncodedWindow?>.filled(numTerms, null);
  for (int i = 0; i < numTerms; i++) {
    localWindows[i] = source.windowOf(compiled[i].termId, windowId);
  }

  int split = 0;
  List<_CompiledTerm> essentialList;
  if (numTerms <= 1) {
    essentialList = compiled;
  } else if (numTerms == 2) {
    final a = compiled[0];
    final b = compiled[1];
    final int ba = a.unit * source.maxImpact(a.termId, windowId);
    final int bb = b.unit * source.maxImpact(b.termId, windowId);
    ctx.orderBuffer.clear();
    if (ba <= bb) {
      ctx.orderBuffer.add(a);
      ctx.orderBuffer.add(b);
      if (ba < theta) {
        split = (ba + bb < theta) ? 2 : 1;
      }
    } else {
      ctx.orderBuffer.add(b);
      ctx.orderBuffer.add(a);
      if (bb < theta) {
        split = (ba + bb < theta) ? 2 : 1;
      }
    }
    essentialList = ctx.orderBuffer;
  } else {
    ctx.orderBuffer
      ..clear()
      ..addAll(compiled);
    ctx.orderBuffer.sort((a, b) {
      final int ba = a.unit * source.maxImpact(a.termId, windowId);
      final int bb = b.unit * source.maxImpact(b.termId, windowId);
      return ba.compareTo(bb);
    });
    var prefix = 0;
    for (int i = 0; i < ctx.orderBuffer.length; i++) {
      final int piece = ctx.orderBuffer[i].unit *
          source.maxImpact(ctx.orderBuffer[i].termId, windowId);
      if (prefix + piece < theta) {
        prefix += piece;
        split = i + 1;
        continue;
      }
      break;
    }
    essentialList = ctx.orderBuffer;
  }
  if (split >= essentialList.length) return;

  for (int eIdx = split; eIdx < essentialList.length; eIdx++) {
    final term = essentialList[eIdx];
    final int termIndex = term.slotIndex;
    final window = termIndex >= 0 && termIndex < localWindows.length
        ? localWindows[termIndex]
        : source.windowOf(term.termId, windowId);
    if (window == null || window.df == 0) continue;
    final int maxQ = window.maxImpact;
    final int otherMax = bound - term.unit * maxQ;
    final int req = WmbpScore.minimumQ8(term.unit, theta - otherMax);
    if (req > 255) continue;

    final int state = window.state;
    // State 0 (OPEN_RAW) and state 1 share compact offset/impact arrays.
    if (state == 0 || state == 1) {
      final offsets = window.offsets;
      final impacts = window.impacts;
      final int df =
          impacts.length < offsets.length ? impacts.length : offsets.length;
      for (int i = 0; i < df; i++) {
        final int qSelf = impacts[i];
        if (qSelf >= req) {
          final int off = offsets[i];
          if (seen[off] == stamp) continue;
          seen[off] = stamp;
          final int docId = windowId * WmbpConstants.windowSize + off;

          if (numTerms == 1) {
            consider(docId, compiled[0].unit * qSelf);
            continue;
          }

          var sum = compiled[termIndex].unit * qSelf;
          bool zeroScore = false;
          for (int j = 0; j < numTerms; j++) {
            if (j == termIndex) continue;
            final win = localWindows[j];
            final int q = win != null ? win.impactAt(off) : 0;
            if (q <= 0) {
              if (conjunctive) {
                zeroScore = true;
                break;
              }
              continue;
            }
            sum += compiled[j].unit * q;
          }
          if (!zeroScore && sum > 0) {
            consider(docId, sum);
          }
        }
      }
    } else if (state == 2) {
      final blocks = window.blocks;
      final int numBlocks = blocks.length;
      for (int b = 0; b < numBlocks; b++) {
        final block = blocks[b];
        if (block.blockMaxImpact < req) continue;
        final int mask = WmbpSwar.evalMicroBlockMask(
          block.microMaxLo,
          block.microMaxHi,
          req,
        );
        if (mask == 0) {
          if (stats != null) {
            stats.microBlockSkips += WmbpSwar.microBlocksPerPhysBlock();
          }
          continue;
        }
        final int micros = WmbpSwar.microBlocksPerPhysBlock();
        for (int m = 0; m < micros; m++) {
          if (stats != null) stats.microBlocksSeen++;
          if ((mask & (1 << m)) == 0) {
            if (stats != null) stats.microBlockSkips++;
            continue;
          }
          final int begin = m * WmbpConstants.microBlockSize;
          var end = begin + WmbpConstants.microBlockSize;
          if (end > block.itemCount) end = block.itemCount;
          final bOffsets = block.offsets;
          final bImpacts = block.impacts;
          for (int i = begin; i < end; i++) {
            final int qSelf = bImpacts[i];
            if (qSelf >= req) {
              final int off = bOffsets[i];
              if (seen[off] == stamp) continue;
              seen[off] = stamp;
              final int docId = windowId * WmbpConstants.windowSize + off;

              if (numTerms == 1) {
                consider(docId, compiled[0].unit * qSelf);
                continue;
              }

              var sum = compiled[termIndex].unit * qSelf;
              bool zeroScore = false;
              for (int j = 0; j < numTerms; j++) {
                if (j == termIndex) continue;
                final win = localWindows[j];
                final int q = win != null ? win.impactAt(off) : 0;
                if (q <= 0) {
                  if (conjunctive) {
                    zeroScore = true;
                    break;
                  }
                  continue;
                }
                sum += compiled[j].unit * q;
              }
              if (!zeroScore && sum > 0) {
                consider(docId, sum);
              }
            }
          }
        }
      }
    } else {
      window.visitCandidates(req, (docOffset, qSelf) {
        if (seen[docOffset] == stamp) return;
        seen[docOffset] = stamp;
        final int docId = windowId * WmbpConstants.windowSize + docOffset;
        if (numTerms == 1) {
          if (qSelf > 0) consider(docId, compiled[0].unit * qSelf);
          return;
        }
        var sum = compiled[termIndex].unit * qSelf;
        for (int j = 0; j < numTerms; j++) {
          if (j == termIndex) continue;
          final win = localWindows[j];
          final int q = win?.impactAt(docOffset) ?? 0;
          if (q <= 0) {
            if (conjunctive) return;
            continue;
          }
          sum += compiled[j].unit * q;
        }
        if (sum > 0) {
          consider(docId, sum);
        }
      }, stats: stats);
    }
  }
}

List<int> _sparseIntersect(List<List<int>> lists, {List<int>? out}) {
  final dest = out ?? <int>[];
  dest.clear();
  if (lists.isEmpty) return dest;
  final cursors = List<int>.filled(lists.length, 0);
  while (cursors[0] < lists[0].length) {
    final int candidate = lists[0][cursors[0]];
    var ok = true;
    for (int i = 1; i < lists.length; i++) {
      final list = lists[i];
      while (cursors[i] < list.length && list[cursors[i]] < candidate) {
        cursors[i]++;
      }
      if (cursors[i] >= list.length || list[cursors[i]] != candidate) {
        ok = false;
        break;
      }
    }
    if (ok && (dest.isEmpty || dest.last != candidate)) dest.add(candidate);
    cursors[0]++;
  }
  return dest;
}
