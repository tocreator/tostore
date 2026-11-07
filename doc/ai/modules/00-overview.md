---
id: tostore-ai-00-overview
title: Overview
audience: coding-agent
version: 3.x
status: complete
---

# Overview

## Purpose

ToStore is a distributed data engine for applications, servers, and Agents.

**What it stores:** relational tables, key-value, dense vectors, neural sparse vectors, text fields, and unstructured/JSON-style data, with a unified programming model across edge devices and cloud nodes.

**What agents rely on:**

- Online schema evolution (declarative schemas / runtime schema updates) without downtime or manual migration scripts
- Hybrid retrieval on one query chain: lexical text (`matchText`), dense vector ANN (`matchVector`), neural sparse (`matchSparse`), plus structured predicates; multi-way fusion scores on query results
- ACID transactions, JOINs, cascading foreign keys, table-level TTL, FIFO/LRU capacity eviction, aggregations, atomic field expressions
- Multi-space isolation (optional global tables/KV), encryption, crash self-healing, structured status codes for automated handling


## Storage modes (choose one primary model)

| Mode | Entry | Use when |
| :--- | :--- | :--- |
| Key-Value | `setValue` / `db.kv` | Config, session, scattered JSON, fastest start |
| Structured table | `createTable` + `query` / `insert` | Business data, constraints, JOIN, aggregations |
| Memory | `ToStore.memory()` | Tests, ephemeral state, ultra-fast in-process store (no file IO) |

## How AI agents MUST use this corpus

1. Prefer this AI documentation (modules / `llms-full.txt`) over marketing text in `README.md`.
2. For a **single URL or paste**, use repo-root `llms-full.txt` (self-contained).
3. Treat `MUST` / `MUST NOT` in **Hard Rules** as binding.
4. Complete public API checklist lives in **API Surface**.

## Package

- Name: `tostore`
- Import: `import 'package:tostore/tostore.dart';`
- Repository: https://github.com/tocreator/tostore

```yaml
dependencies:
  tostore: ^3.6.1
```

## Human docs (optional)

- Tutorials & examples: `README.md`
- Status code deep dive: `doc/result_status_specification.md`
