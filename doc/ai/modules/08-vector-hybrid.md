---
id: tostore-ai-08-vector-hybrid
title: Vector Fields and Hybrid Retrieval
audience: coding-agent
source_apis:
  - ToStore.vectorSearch
  - QueryBuilder.matchVector
  - QueryBuilder.orMatchVector
  - QueryBuilder.matchText
  - QueryBuilder.orMatchText
  - QueryBuilder.matchSparse
  - QueryBuilder.orMatchSparse
  - QueryBuilder.fusionMethod
  - RetrievalFusionMethod
  - VectorData
  - SparseVectorData
  - TextQuery
  - TextTerm
  - TextMatchOperator
  - TextSearchMode
  - VectorFieldConfig
  - VectorIndexConfig
version: 3.x
status: complete
---

# Vector Fields and Hybrid Retrieval

## Purpose

Store embeddings, build vector indexes, run ANN search, and fuse vector + structured recall on one query chain.

## Schema

### Vector field

```dart
FieldSchema(
  name: 'embedding',
  type: DataType.vector,
  vectorConfig: VectorFieldConfig(
    dimensions: 128, // MUST match written vector length (1..65535)
  ),
)
```

### Vector index

```dart
IndexSchema(
  fields: ['embedding'],
  type: IndexType.vector,
  vectorConfig: VectorIndexConfig(
    indexType: VectorIndexType.ngh, // ToStore built-in proprietary dense index
    distanceMetric: VectorDistanceMetric.cosine, // l2 | cosine | innerProduct
  ),
)
```

| Config | Meaning |
| :--- | :--- |
| `dimensions` | On `VectorFieldConfig`: embedding width **1..65535** (must match writes/queries). |
| `indexType` | Opaque dense algorithm id; currently `ngh` (ToStore proprietary).  |
| `distanceMetric` | Similarity metric for **insert and search**; changing it requires rebuild |

### Distance semantics (ANN path)

Engine ranks by a **distance** (lower = closer):

| Metric | ANN distance | Public `score` / `rawScore` |
| :--- | :--- | :--- |
| `l2` | **squared** L2 (query norm + vector norm - 2 * dot) | `1 - distance / 2` clamped to `[0, 1]`. For unit-length vectors this equals cosine. Squared distance ≥ 2 scores 0. |
| `innerProduct` | **negated** IP | Recovered IP clamped to `[0, 1]`. Engine does **not** auto-normalize; after caller-side normalization this matches cosine. IP above 1 saturates at 1. |
| `cosine` | `1 - cosine` | `1 - distance` clamped to `[0, 1]`. Engine auto-normalizes. |

Build query vectors with `VectorData(...)` / `VectorData.fromList(...)` (same type as `vectorSearch`).

## Preferred: chained hybrid retrieval

```dart
QueryBuilder matchVector(
  String field,
  VectorData queryVector, {
  double weight = 1.0,
  int? searchDepth, // default VectorIndexConfig.defaultSearchDepth (50)
  double? distanceThreshold,
  double? minScore,
});
QueryBuilder orMatchVector(...); // same params, OR branch
```

| Param | Meaning |
| :--- | :--- |
| `weight` | Multi-way fusion weight (default 1.0) |
| `searchDepth` | Per-query search depth (`>= 1`, **no max**); omit → default `50`. Larger values typically raise recall and latency. Best-effort ANN — **not** a guaranteed recall@K |
| `minScore` | Normalized similarity floor `[0,1]` |
| `distanceThreshold` | Distance ceiling |
| chain `limit` | Acts as topK |

```dart
// Pure ANN (default searchDepth 50). Prefer .select([pk]) for PK + score
// only — skips full-record hydration (large embeddings hurt throughput).
final result = await db.query('embeddings')
  .select(['id'])
  .matchVector('embedding', queryVector)
  .limit(5);

// Explicit depth override
await db.query('embeddings')
  .matchVector('embedding', queryVector, searchDepth: 40)
  .limit(5);

// Structured AND vector
await db.query('embeddings')
  .whereEqual('category', 'tech')
  .matchVector('embedding', queryVector)
  .limit(5);

// Multi-way fusion (typically RRF)
await db.query('embeddings')
  .matchVector('embedding', v1, weight: 1.0)
  .orMatchVector('embedding', v2, weight: 0.6, minScore: 0.2)
  .or()
  .whereEqual('category', 'tech')
  .limit(10);
```

### QueryResult.retrieval

- `data[i]` ↔ `retrieval.entries[i]` **1:1**
- With `.select([pk])`, `data` is PK-only; scores stay in `retrieval`

**One recall channel** — `entry.score` / `entry.rawScore` are that channel's scores (`higher` = better):

| Channel | `score` | `rawScore` | Notes |
| :--- | :--- | :--- | :--- |
| text / sparse | `[0,1)` from `raw / (raw + 2)` | continuous match quality | Same discard band as cosine. One strong text term and one saturated sparse feature (query weight 1, full stored impact) both land near raw 5 → ~0.71. raw ≈ 1 → ~0.33, raw ≈ 30 → ~0.94. Short text queries commonly `rawScore` `0..30`. Top hit is not forced to `1.0`. |
| vector | similarity in `[0,1]` | same as `score` | Cosine, normalized inner product, and unit-length L2 share that band. ANN distance in `meta['distance']`. |

**Multi-way recall** (two or more of `matchText` / `matchSparse` / `matchVector` / structured OR branches) — scores are fused. Configure with `.fusionMethod(...)`; default is `weightedScore`:

| `.fusionMethod(...)` | Scoring |
| :--- | :--- |
| `weightedScore` (default) | Sum of `weight × channel score`, divided by the total weight of every vector, text, and sparse channel in the query. A miss contributes 0, so a second hit raises the score. Weights mix already aligned scores; they do not rescale a channel. Higher = better. |
| `rrf` | Relative score from ranks inside each channel's result set (Reciprocal Rank Fusion). |

## Standalone ANN

```dart
Future<List<VectorSearchResult>> vectorSearch(
  String tableName, {
  required String fieldName,
  required VectorData queryVector,
  int topK = 10,
  int? searchDepth,
  double? distanceThreshold,
});
```

Prefer `query().matchVector` when combining filters or multi-way fusion.

## searchDepth guidance

`searchDepth` is the per-query recall-intent knob (`>= 1`, **no hard maximum**). Omit it to use `50`.

Intent anchors (best-effort Recall@K, not a hard guarantee):

| searchDepth | Target recall | Allowed deviation |
| :--- | :--- | :--- |
| `1` | ~91% | ±5 percentage points |
| `50` (default) | ~95% | ±3 percentage points (strict) |
| `100` | ~98% | ±5 percentage points (99% is not the interactive ceiling) |
| `>100` | continues above ~98% toward saturation | **same average Δbudget/Δdepth as the 50→100 band** (not steeper) |

Larger depth typically raises both recall and latency. Prefer the anchors above; raise past `100` only when a large corpus still needs more recall. ANN remains approximate — not a guaranteed recall@K.

## Rules

1. Dimensions MUST match field config.
2. Prefer chain `matchVector` + `limit` over inventing custom ANN APIs.
3. Read scores from `retrieval`, not by guessing record fields.

## Text and neural sparse retrieval

Text and sparse channels share one Top-K kernel. `TextMatchOperator.or` ranks the union of terms. `TextMatchOperator.and` keeps a document only when every positive-weight term has impact, then ranks with the same additive integer score. A missing term yields an empty text channel. Phrase matching is not supported. Sparse retrieval stays disjunctive.

| Channel | Chain | Index | Field type | Query value |
| :--- | :--- | :--- | :--- | :--- |
| text | `matchText` / `orMatchText` | `IndexType.text` | `DataType.text` | `TextQuery.text(...)`, `TextQuery.terms(...)`, or `TextQuery.termsWeighted(...)` |
| sparse | `matchSparse` / `orMatchSparse` | `IndexType.sparse` | `DataType.sparse` | `SparseVectorData` |

```dart
final results = await db.query('articles')
  .select(['id'])
  .matchText(
    'body',
    TextQuery.text('distributed kernel storage'),
    weight: 0.4,
  )
  .matchVector('embedding', queryVector, weight: 0.6)
  .limit(10);
```

`TextQuery.text` is segmented by the engine. `TextQuery.terms(List<String>)` is pre-tokenized with weight 1 per term; repeated strings add weight. `TextQuery.termsWeighted(List<TextTerm>)` is pre-tokenized with an explicit weight on each `TextTerm` (`term`, `weight`); weights of the same term are summed, and non-positive weights are dropped. Pre-tokenized terms are matched exactly: the engine does not segment them, expand CJK bigrams, or change case. Built-in indexing lowercases Latin tokens, so a pre-tokenized query must use the same term strings that were indexed.

For `TextQuery.text`, a CJK single-character match is treated as a weak signal (typically `score` below ~0.40), while CJK bigrams and Latin words keep the strong exact-term band (~0.71 for one strong hit). Longer Chinese `OR` queries therefore lean on bigrams rather than stacking many unigrams. `TextQuery.terms` / `termsWeighted` do not apply that automatic softening — caller weights are used as given. `matchText` followed by `matchVector` on the same chain is multi-way fusion (default `weightedScore`). Opt into rank-only fusion with `.fusionMethod(RetrievalFusionMethod.rrf)`. A structured `where*` on that chain is a filter over the recalled records. Inserts are searchable before flush. `limit` is topK. Scores are in `retrieval.entries`, aligned with `data` (see scoring tables above).
