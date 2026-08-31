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
  nullable: false,
  vectorConfig: VectorFieldConfig(
    dimensions: 128, // MUST match write/query width
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
| `dimensions` | On `VectorFieldConfig`: embedding width (must match writes/queries) |
| `indexType` | Opaque dense algorithm id; currently `ngh` (ToStore proprietary).  |
| `distanceMetric` | Similarity metric for **insert and search**; changing it requires rebuild |

### Distance semantics (ANN path)

Engine ranks by a **distance** (lower = closer):

| Metric | ANN distance | Notes |
| :--- | :--- | :--- |
| `l2` | **squared** L2 | No square-root |
| `innerProduct` | **negated** IP | Engine does **not** auto-normalize; normalize caller-side for semantic IP |
| `cosine` | `1 - cosine` | Engine auto-normalizes |

`VectorData.fromList(...)` (or `List<num>` / `Float32List`) for query vectors.

## Preferred: chained hybrid retrieval

```dart
QueryBuilder matchVector(
  String field,
  dynamic vector, {
  double weight = 1.0,
  int? searchDepth, // 1..100; default VectorIndexConfig.defaultSearchDepth (80)
  double? distanceThreshold,
  double? minScore,
});
QueryBuilder orMatchVector(...); // same params, OR branch
```

| Param | Meaning |
| :--- | :--- |
| `weight` | Multi-way fusion weight (default 1.0) |
| `searchDepth` | Per-query thoroughness `[1, 100]`; higher ≈ better recall intent + higher latency; omit → engine default `80` |
| `minScore` | Normalized similarity floor `[0,1]` |
| `distanceThreshold` | Distance ceiling |
| chain `limit` | Acts as topK |

```dart
// Pure ANN (uses default searchDepth 80)
final result = await db.query('embeddings')
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

| Depth | Intent |
| :--- | :--- |
| `40` | Fast / latency-first (lower recall intent) |
| `80` | Default quality-first |
| `100` | Max engine probe budget for this corpus (highest recall intent, highest cost) |

Higher `searchDepth` usually improves recall *intent* and increases latency; lower values are faster but may miss neighbors. It is **not** a recall% SLA (`80` ≠ 80% recall; `100` does not promise 100% recall). Resolution: `query searchDepth ?? 80`. The engine maps depth to an internal probe budget and caps that budget on large corpora.

## Rules

1. Dimensions MUST match field config.
2. Prefer chain `matchVector` + `limit` over inventing custom ANN APIs.
3. Read scores from `retrieval`, not by guessing row fields.
