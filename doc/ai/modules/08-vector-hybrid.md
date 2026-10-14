---
id: tostore-ai-08-vector-hybrid
title: Vector Fields and Hybrid Retrieval
audience: coding-agent
source_apis:
  - ToStore.vectorSearch
  - QueryBuilder.matchVector
  - QueryBuilder.orMatchVector
  - VectorData
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

| Metric | ANN distance | Notes |
| :--- | :--- | :--- |
| `l2` | **squared** L2 | No square-root |
| `innerProduct` | **negated** IP | Engine does **not** auto-normalize; normalize caller-side for semantic IP |
| `cosine` | `1 - cosine` | Engine auto-normalizes |

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
// only — skips full-row hydration (large embeddings hurt throughput).
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
- `entry.score` — normalized / fused score (higher ≈ better)
- `entry.meta['distance']` — raw distance on vector channel
- `retrieval.fusionMethod` — `single` or typically `rrf` for multi-way

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
3. Read scores from `retrieval`, not by guessing row fields.
