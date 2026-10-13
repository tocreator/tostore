# ToStore Benchmarks

Quantitative results from the built-in benchmark suite. For product overview and APIs, see the [README](../README.md).

## 100K suite

**Device**: ThinkPad W530 · **Scale**: 100000 records · **Iterations**: 3 rounds · **Durability**: standard · **Date**: 2026-10-08

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/tostore_benchmark_results.png" alt="ToStore Benchmark Results" width="920" />
</p>

### Results

| Model | Operation | Scale | Avg Time | Throughput | Avg Latency | Min / Max |
| :--- | :--- | :---: | :---: | :---: | :---: | :---: |
| Simple | Batch Insert | 100000 | 170.00 ms | **588235 ops/s** | 1.70 μs/op | 115.8 / 307.5 ms |
| Simple | Single Insert | 10000 | 305.05 ms | **32782 ops/s** | 30.51 μs/op | 282.2 / 338.3 ms |
| Simple | Batch Update | 100000 | 605.07 ms | **165270 ops/s** | 6.05 μs/op | 528.0 / 730.5 ms |
| Simple | Single Update | 10000 | 388.33 ms | **25751 ops/s** | 38.83 μs/op | 326.3 / 389.7 ms |
| Simple | Batch Upsert | 100000 | 236.76 ms | **422369 ops/s** | 2.37 μs/op | 206.3 / 252.7 ms |
| Simple | Batch Delete | 100000 | 407.04 ms | **245676 ops/s** | 4.07 μs/op | 367.5 / 438.7 ms |
| Simple | Single Delete | 10000 | 376.61 ms | **26553 ops/s** | 37.66 μs/op | 339.8 / 416.2 ms |
| Simple | PK Read (Hot Cache) | 100000 | 22.02 ms | **4541326 ops/s** | 0.22 μs/op | 17.5 / 25.9 ms |
| Simple | PK Read (Random) | 100000 | 230.49 ms | **433858 ops/s** | 2.30 μs/op | 226.1 / 234.6 ms |
| Simple | Range Scan (Hot Cache) | 100000 | 306.77 ms | **325977 ops/s** | 3.07 μs/op | 277.0 / 330.1 ms |
| Simple | Range Scan (Random) | 10000 | 612.55 ms | **16325 ops/s** | 61.26 μs/op | 572.7 / 663.9 ms |
| Simple | Pagination (Hot Cache) | 100000 | 172.76 ms | **578838 ops/s** | 1.73 μs/op | 141.9 / 217.8 ms |
| Simple | Pagination (Random) | 10000 | 715.25 ms | **13981 ops/s** | 71.53 μs/op | 618.2 / 770.0 ms |
| Simple | Count Verification | 100000 | 130.79 ms | **764584 ops/s** | 1.31 μs/op | 119.1 / 152.3 ms |
| Indexed | Indexed Seek (Hot Cache) | 100000 | 191.17 ms | **523095 ops/s** | 1.91 μs/op | 160.1 / 225.5 ms |
| Indexed | Indexed Seek (Random) | 100000 | 554.02 ms | **180499 ops/s** | 5.54 μs/op | 518.9 / 597.5 ms |
| Vector | Vector Batch Insert | 10000 | 73.79 ms | **135520 ops/s** | 7.38 μs/op | 63.5 / 118.1 ms |
| Vector | ANN @ depth 1 (~91%) | 10000 | 274.27 ms | **36460 ops/s** | 27.43 μs/op | 215.0 / 360.2 ms |
| Vector | ANN @ depth 50 (~95%) | 10000 | 416.14 ms | **24030 ops/s** | 41.61 μs/op | 362.3 / 493.0 ms |
| Vector | Vector Hybrid Search | 10000 | 1231.63 ms | **8119 ops/s** | 123.16 μs/op | 1217.0 / 1250.7 ms |

### How to reproduce

Run the benchmark suite from the `example` app. Prefer **release** builds — debug mode is not representative.

---

## Large-scale edge validation

Separate from the 100K suite above. Edge runs at **1e9**-record scale; cold start stays **~35 ms** regardless of data scale.

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.gif" alt="ToStore large-scale edge demo" width="320" />
</p>

- Full video: <a href="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.mp4" target="_blank" rel="noopener">basic-demo.mp4</a> — startup, paging, and retrieval on ordinary devices under very large datasets.

## Disaster recovery

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.gif" alt="ToStore Disaster Recovery Stress Test" width="320" />
</p>

- Full video: <a href="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.mp4" target="_blank" rel="noopener">disaster-recovery.mp4</a> — under high-frequency writes, intentional crash/power-loss interruptions still recover quickly.
