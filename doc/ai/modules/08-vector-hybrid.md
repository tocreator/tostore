---
id: tostore-ai-08-vector-hybrid
title: Vector, Text, and Hybrid Retrieval
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

# Vector, Text, and Hybrid Retrieval

## Purpose

Store dense embeddings, neural sparse vectors, and text; build `IndexType.vector` / `text` / `sparse` indexes; run lexical text, dense ANN, and neural sparse retrieval; fuse channels (and structured predicates) on one query chain.

## Schema

### Dense vector field + index

```dart
FieldSchema(
  name: 'embedding',
  type: DataType.vector,
  vectorConfig: VectorFieldConfig(
    dimensions: 128, // MUST match written vector length (1..65535)
  ),
)

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

### Text field + index

```dart
FieldSchema(name: 'content', type: DataType.text, nullable: false)

IndexSchema(fields: ['content'], type: IndexType.text)
```

### Neural sparse field + index

```dart
FieldSchema(name: 'features', type: DataType.sparse, nullable: false)

IndexSchema(fields: ['features'], type: IndexType.sparse)
```

Document-side sparse weights SHOULD fall in `(0, 1]`. Build values with `SparseVectorData(...)` / `SparseVectorData.fromMap(...)`.

### Search visibility

After insert/update success: btree, **text**, and **sparse** indexes are immediately searchable. **Vector** indexes are not built on the write path; call `await db.flush()` after the business batch before `matchVector` / `vectorSearch`.

### Distance and score semantics

Every retrieval channel (`vector`, `text`, `sparse`, and `weightedScore` multi-way fusion) outputs a unified **Normalized Relevance Score** (`score`) in **`0.0 ~ 1.0`** (`higher` = more relevant) so the same `minScore` bands stay meaningful across metrics, alongside the channel's unnormalized physical `rawScore` / `distance`:

| Metric / Channel | Physical `rawScore` | `distance` (`lower` = closer) | Normalized `score` |
| :--- | :--- | :--- | :--- |
| Vector `cosine` | Cosine similarity in `[-1.0, 1.0]` | `1 - cosine` in `[0.0, 2.0]` | `0.0 ~ 1.0` (`1.0` for exact match) |
| Vector `innerProduct` | Unclamped dot product in `(-∞, +∞)` | `-rawScore` | `0.0 ~ 1.0` (`1.0` for exact match) |
| Vector `l2` | Euclidean distance `>= 0.0` | Euclidean distance (`== rawScore`) | `0.0 ~ 1.0` (`1.0` for exact match) |
| `text` / `sparse` | Continuous match quality `>= 0.0` | — | `[0.0, 1.0)` (approaches `1.0`, never forced to `1.0`) |

Vector `score` is a relevance value in `0.0 ~ 1.0` (`higher` = more relevant; exact match → `1.0`). It tracks the channel’s physical similarity the same way for every dimension. Use `minScore` to keep strong hits; use `rawScore` / `distance` when you need the underlying metric.

#### Normalized Relevance Score (`score`) & Threshold Baseline

Applies to single-channel relevance and multi-way `weightedScore` (including channel `minScore`). Not for `rrf` fusion scores (rank-relative).

The baseline below is for typical embedding widths (**dimensions ≥ 128**). On lower-dimensional fields, weak / random neighbors can score high — raise `minScore` or rely on `rawScore` if you need stricter control.

| `score` Baseline | Meaning & Typical Scenarios |
| :--- | :--- |
| `>= 0.85` | Same-entity match (face verification, biometrics, exact deduplication) |
| `>= 0.70` | High-confidence semantic match (core facts, precise Q&A) |
| `>= 0.40` | Basic semantic relevance (general RAG, knowledge-base anti-hallucination) |
| `>= 0.30` | Broad initial recall (fuzzy discovery, pre-rerank candidate pool) |
| `< 0.30` | Weak association or background noise |


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

// Multi-way fusion: text + sparse + vector (default weightedScore)
await db.query('documents')
  .matchText('content', TextQuery.text('distributed storage'), weight: 0.4)
  .matchSparse('features', sparseQuery, weight: 0.3, minScore: 0.20)
  .matchVector('embedding', queryVector, weight: 0.6, minScore: 0.40)
  .limit(10);

// Opt into rank-only fusion
await db.query('documents')
  .matchText('content', TextQuery.text('distributed storage'), weight: 0.4)
  .matchVector('embedding', queryVector, weight: 0.6, minScore: 0.40)
  .fusionMethod(RetrievalFusionMethod.rrf)
  .limit(10);
```

### QueryResult.retrieval

- `data[i]` ↔ `retrieval.entries[i]` **1:1**
- With `.select([pk])`, `data` is PK-only; scores stay in `retrieval`
- **Single recall channel**: `entry.score` (`0.0 ~ 1.0`) is the normalized relevance score; `entry.rawScore` is the physical metric value; vector channels also carry `entry.meta['distance']`.
- **Multi-way recall** (two or more of `matchText` / `matchSparse` / `matchVector` / structured OR branches) — scores are fused. Configure with `.fusionMethod(...)`; default is `weightedScore`:

| `.fusionMethod(...)` | `entry.score` | `entry.rawScore` |
| :--- | :--- | :--- |
| `weightedScore` (default) | Absolute relevance: dominant-channel floor with bounded corroboration; a miss on another channel does not dilute a strong hit. Use with the threshold baseline / channel `minScore`. | Physical `rawScore` when matched by a single channel; `null` when fused across multiple channels (per-channel values in `entry.meta['channelContributions']`). |
| `rrf` | Rank-relative Reciprocal Rank Fusion score (not the absolute relevance bands). | Raw RRF sum. |


## Standalone ANN

```dart
Future<List<VectorSearchResult>> vectorSearch(
  String tableName, {
  required String fieldName,
  required VectorData queryVector,
  int topK = 10,
  int? searchDepth,
  double? distanceThreshold,
  double? minScore, // relevance floor (same as matchVector)
});
```

`minScore` filters on `score` (post-ANN); may return fewer than `topK`. Prefer `query().matchVector` when combining filters or multi-way fusion.

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

1. Dense vector dimensions MUST match field config.
2. Prefer chain `matchText` / `matchSparse` / `matchVector` + `limit` over inventing custom retrieval APIs.
3. Read scores from `retrieval`, not by guessing record fields.


## Text and neural sparse retrieval

Text and sparse channels share one Top-K kernel. `TextMatchOperator.or` ranks the union of terms. `TextMatchOperator.and` keeps a document only when every positive-weight term has impact, then ranks with the same additive integer score. A missing term yields an empty text channel. Phrase matching is not supported. Sparse retrieval stays disjunctive.

| Channel | Chain | Index | Field type | Query value |
| :--- | :--- | :--- | :--- | :--- |
| text | `matchText` / `orMatchText` | `IndexType.text` | `DataType.text` | `TextQuery.text(...)`, `TextQuery.terms(...)`, or `TextQuery.termsWeighted(...)` |
| sparse | `matchSparse` / `orMatchSparse` | `IndexType.sparse` | `DataType.sparse` | `SparseVectorData` |

```dart
QueryBuilder matchText(
  String field,
  TextQuery query, {
  TextMatchOperator operator = TextMatchOperator.or,
  double weight = 1.0,
  double? minScore,
});
QueryBuilder orMatchText(...); // same params, OR branch

QueryBuilder matchSparse(
  String field,
  SparseVectorData query, {
  double weight = 1.0,
  double? minScore,
});
QueryBuilder orMatchSparse(...); // same params, OR branch
```

```dart
// Lexical text only
await db.query('documents')
  .select(['id'])
  .matchText('content', TextQuery.text('distributed kernel storage'))
  .limit(5);

// Neural sparse only
await db.query('documents')
  .select(['id'])
  .matchSparse('features', sparseQuery, minScore: 0.30)
  .limit(5);

// Text + dense on one chain → multi-way fusion (default weightedScore)
final results = await db.query('documents')
  .select(['id'])
  .matchText(
    'content',
    TextQuery.text('distributed kernel storage'),
    weight: 0.4,
  )
  .matchVector('embedding', queryVector, weight: 0.6)
  .limit(10);
```

`TextQuery.text` is segmented by the engine. `TextQuery.terms(List<String>)` is pre-tokenized with weight 1 per term; repeated strings add weight. `TextQuery.termsWeighted(List<TextTerm>)` is pre-tokenized with an explicit weight on each `TextTerm` (`term`, `weight`); weights of the same term are summed, and non-positive weights are dropped. Pre-tokenized terms are matched exactly: the engine does not segment them, expand CJK bigrams, or change case. Built-in indexing lowercases Latin tokens, so a pre-tokenized query must use the same term strings that were indexed.

For `TextQuery.text`, a CJK single-character match is treated as a weak signal (typically `score` below ~0.40), while CJK bigrams and Latin words keep the strong exact-term band (~0.71 for one strong hit). Longer Chinese `OR` queries therefore lean on bigrams rather than stacking many unigrams. `TextQuery.terms` / `termsWeighted` do not apply that automatic softening — caller weights are used as given. `matchText` / `matchSparse` / `matchVector` on the same chain is multi-way fusion (default `weightedScore`). Opt into rank-only fusion with `.fusionMethod(RetrievalFusionMethod.rrf)`. A structured `where*` on that chain is a filter over the recalled records. Text and sparse inserts are searchable before flush. `limit` is topK. Scores are in `retrieval.entries`, aligned with `data` (see scoring tables above).
