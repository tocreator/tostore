# ToStore Benchmarks

Quantitative results from the built-in benchmark suite. For product overview and APIs, see the [README](../README.md).

## 100K suite

**Device**: ThinkPad W530 · **Scale**: 100000 records · **Iterations**: 3 rounds · **Date**: 2026-08-29

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/tostore_benchmark_results.png" alt="ToStore Benchmark Results" width="920" />
</p>

### Results

| Model | Operation | Scale | Avg Time | Throughput | Avg Latency | Min / Max |
| :--- | :--- | :---: | :---: | :---: | :---: | :---: |
| Simple | Batch Insert | 100000 | 184.87 ms | **540929 ops/s** | 1.85 μs/op | 155.3 / 234.7 ms |
| Simple | Single Insert | 10000 | 338.33 ms | **29557 ops/s** | 33.83 μs/op | 336.0 / 342.3 ms |
| Simple | Batch Update | 100000 | 1036.44 ms | **96484 ops/s** | 10.36 μs/op | 955.6 / 1091.9 ms |
| Simple | Single Update | 10000 | 632.56 ms | **15809 ops/s** | 63.26 μs/op | 628.5 / 699.2 ms |
| Simple | Batch Upsert | 100000 | 445.35 ms | **224542 ops/s** | 4.45 μs/op | 403.5 / 509.6 ms |
| Simple | Batch Delete | 100000 | 450.07 ms | **222189 ops/s** | 4.50 μs/op | 429.2 / 485.6 ms |
| Simple | Single Delete | 10000 | 392.61 ms | **25471 ops/s** | 39.26 μs/op | 332.9 / 432.1 ms |
| Simple | PK Read (Hot Cache) | 100000 | 22.09 ms | **4525911 ops/s** | 0.22 μs/op | 19.7 / 26.3 ms |
| Simple | PK Read (Random) | 100000 | 252.68 ms | **395756 ops/s** | 2.53 μs/op | 227.5 / 283.7 ms |
| Simple | Range Scan (Hot Cache) | 100000 | 347.42 ms | **287839 ops/s** | 3.47 μs/op | 326.9 / 387.7 ms |
| Simple | Range Scan (Random) | 10000 | 849.58 ms | **11771 ops/s** | 84.96 μs/op | 801.2 / 899.5 ms |
| Simple | Pagination (Hot Cache) | 100000 | 165.49 ms | **604281 ops/s** | 1.65 μs/op | 132.8 / 223.8 ms |
| Simple | Pagination (Random) | 10000 | 891.27 ms | **11220 ops/s** | 89.13 μs/op | 881.8 / 903.6 ms |
| Simple | Count Verification | 100000 | 114.98 ms | **869724 ops/s** | 1.15 μs/op | 114.6 / 115.4 ms |
| Indexed | Indexed Seek (Hot Cache) | 100000 | 254.40 ms | **393086 ops/s** | 2.54 μs/op | 241.1 / 267.5 ms |
| Indexed | Indexed Seek (Random) | 100000 | 711.76 ms | **140497 ops/s** | 7.12 μs/op | 664.9 / 763.5 ms |
| Vector | Vector Batch Insert | 10000 | 133.60 ms | **74852 ops/s** | 13.36 μs/op | 123.1 / 149.7 ms |
| Vector | Vector ANN Search | 1000 | 583.07 ms | **1715 ops/s** | 583.07 μs/op | 575.0 / 598.0 ms |
| Vector | Vector Hybrid Search | 1000 | 808.12 ms | **1237 ops/s** | 808.12 μs/op | 701.6 / 1017.6 ms |
| Vector | Vector Recall Check | 100 | — | **100% / 100% / 100%** | — | — |

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
