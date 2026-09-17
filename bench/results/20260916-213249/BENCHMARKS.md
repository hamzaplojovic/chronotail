# Chronotail competitive benchmarks

These are measured results, not copied vendor numbers. Raw output is in [`bench/results/20260916-213249/raw.jsonl`](bench/results/20260916-213249/raw.jsonl), the aggregate CSV is in [`summary.csv`](bench/results/20260916-213249/summary.csv), and every invocation is in [`commands.log`](bench/results/20260916-213249/commands.log).

The engine optimization analysis, profiles, attempted/reverted changes, and baseline comparison are in [`bench/results/performance-pass/REPORT.md`](bench/results/performance-pass/REPORT.md).

## Test machine

| Item | Value |
|---|---|
| CPU | Apple M1 (8 logical CPUs) |
| RAM | 8 GiB |
| OS | macOS 26.1 / arm64 |
| Filesystem | APFS, local internal SSD |
| Zig | 0.15.2 |
| Clang | Apple clang version 17.0.0 (clang-1700.3.19.1) |
| NanoTS | commit `d551210c8d521604a70a73f0f85fe2759c434c23` |
| SQLite | 3.38.5, NanoTS vendored amalgamation |
| Repetitions | 5; tables report medians |

All binaries use optimized release builds. Every engine receives the same deterministic `(i64 timestamp, f64 value)` points. All output is consumed and every database is fully scanned and checked after each workload. Databases are deleted between runs. Query results are warm OS-page-cache results; privileged global cache purging was not used.

## 1. Single-series sustained append

| Workload | Engine | Throughput | Logical MiB/s | p50 | p99 | File |
|---|---:|---:|---:|---:|---:|---:|
| append-A-none | chronotail | 26.83M/s | 409.45 | 0.000 µs | 0.042 µs | 152.78 MiB |
| append-A-none | nanots | 5.30M/s | 80.82 | 0.041 µs | 0.084 µs | 763.10 MiB |
| append-A-none | sqlite | 1.64M/s | 24.99 | 0.500 µs | 2.292 µs | 356.87 MiB |
| append-B-10MiB | chronotail | 23.98M/s | 365.96 | 0.000 µs | 0.042 µs | 152.78 MiB |
| append-B-10MiB | nanots | 4.38M/s | 66.88 | 0.041 µs | 0.125 µs | 801.10 MiB |
| append-B-10MiB | sqlite | 1.64M/s | 25.00 | 0.500 µs | 1.708 µs | 356.87 MiB |
| append-C-1MiB | chronotail | 24.64M/s | 376.03 | 0.000 µs | 0.042 µs | 152.90 MiB |
| append-C-1MiB | nanots | 3.99M/s | 60.86 | 0.041 µs | 0.125 µs | 774.68 MiB |
| append-C-1MiB | sqlite | 1.58M/s | 24.13 | 0.500 µs | 1.750 µs | 356.87 MiB |

![Append throughput](bench/results/20260916-213249/append-throughput.svg)

No cross-engine multiplier is claimed for append durability workloads. The logical durability windows match, but the public persistence primitives do not.

Durability caveat: Chronotail uses `checkpoint(fsync=true)` and SQLite commits a WAL transaction with `synchronous=FULL`. NanoTS has no public explicit checkpoint API; its block rollover performs synchronous `msync`, so its block capacity is calculated as exactly the requested number of 16-byte logical payloads. These are the closest public semantics, but macOS does not guarantee that `msync(MS_SYNC)`, `fsync`, and SQLite WAL FULL have identical power-loss behavior. The tables compare the requested logical windows, not identical persistence primitives.

## 2. Eight-series append

| Workload | Engine | Throughput | Logical MiB/s | p50 | p99 | File |
|---|---:|---:|---:|---:|---:|---:|
| append-8-series | chronotail | 15.91M/s | 242.77 | 0.042 µs | 0.084 µs | 15.28 MiB |
| append-8-series | nanots | 9.03M/s | 137.80 | 0.042 µs | 0.083 µs | 101.10 MiB |
| append-8-series | sqlite | 1.47M/s | 22.50 | 0.500 µs | 2.458 µs | 34.75 MiB |

No multiplier is claimed here because the engines expose different durability primitives.

One application thread feeds eight series round-robin. NanoTS block capacities are divided by eight so the aggregate logical durability window remains approximately 10 MiB.

## 3. Random point lookup

| Workload | Engine | Throughput | Logical MiB/s | p50 | p99 | File |
|---|---:|---:|---:|---:|---:|---:|
| point-lookup-warm | chronotail | 2.68M/s | 40.93 | 0.125 µs | 0.541 µs | 15.28 MiB |
| point-lookup-warm | nanots | 1.44M/s | 21.90 | 0.625 µs | 1.792 µs | 81.13 MiB |
| point-lookup-warm | sqlite | 374.53k/s | 5.71 | 2.625 µs | 3.542 µs | 34.30 MiB |

- Chronotail: **1.87× NanoTS**
- Chronotail: **7.16× SQLite**

Cold-cache numbers are intentionally omitted: reliable cache eviction on this macOS host requires a privileged system-wide `purge`, which would make unattended runs intrusive and less reproducible.

## 4. 100-point range query

| Workload | Engine | Throughput | Logical MiB/s | p50 | p99 | File |
|---|---:|---:|---:|---:|---:|---:|
| range-100-raw-warm | chronotail | 1.74M/s | 2650.75 | 0.292 µs | 0.958 µs | 15.28 MiB |
| range-100-raw-warm | nanots | 105.26k/s | 160.61 | 9.375 µs | 11.750 µs | 81.13 MiB |
| range-100-raw-warm | sqlite | 97.35k/s | 148.54 | 10.208 µs | 11.459 µs | 34.30 MiB |
| range-100-compressed-warm | chronotail | 329.07k/s | 502.11 | 2.875 µs | 4.084 µs | 6.85 MiB |

![Query throughput](bench/results/20260916-213249/query-throughput.svg)

Raw equivalent-workload ratios:

- Chronotail: **16.50× NanoTS**
- Chronotail: **17.85× SQLite**

Chronotail compressed is shown separately and is not used for ratios against raw NanoTS or SQLite.

## Where Chronotail loses

Chronotail has no measured cross-engine throughput or storage-efficiency loss in this run. It provides **1.87× NanoTS** on the point-lookup workload that it lost in the baseline run. Compressed Chronotail is 5.28× slower than raw Chronotail for 100-point ranges, an internal storage/CPU tradeoff rather than a competitor loss.

## 5. Writer plus readers

| Readers | Engine | Writer records/s | Reader queries/s | Reader p50 | Reader p99 |
|---:|---|---:|---:|---:|---:|
| 1 | chronotail | 14.68M | 2.32M | 0.333 µs | 1.042 µs |
| 1 | nanots | 2.58M | 95.09k | 9.875 µs | 14.417 µs |
| 1 | sqlite | 1.49M | 99.05k | 9.541 µs | 14.250 µs |
| 8 | chronotail | 8.23M | 8.39M | 0.375 µs | 1.334 µs |
| 8 | nanots | 2.58M | 64.82k | 101.125 µs | 435.583 µs |
| 8 | sqlite | 944.18k | 266.34k | 11.917 µs | 83.583 µs |
| 32 | chronotail | 7.90M | 8.61M | 0.375 µs | 1.333 µs |
| 32 | nanots | 2.57M | 53.74k | 200.417 µs | 2969.375 µs |
| 32 | sqlite | 494.71k | 355.41k | 13.667 µs | 1753.541 µs |


![Concurrent reader throughput](bench/results/20260916-213249/concurrent-readers.svg)

Writer and reader rates are deliberately not combined. Readers query the fixed initial one-million-point snapshot while the writer appends and durably rolls over/checkpoints at roughly 1 MiB logical boundaries. This avoids rewarding an engine for exposing uncommitted tail points.

## 6. Storage efficiency

| Dataset | Engine/mode | Total size | Bytes/point |
|---|---|---:|---:|
| smooth | Chronotail raw | 152.78 MiB | 16.020 |
| smooth | Chronotail compressed | 68.44 MiB | 7.176 |
| smooth | NanoTS normal | 763.10 MiB | 80.017 |
| smooth | SQLite normal | 356.87 MiB | 37.421 |
| random | Chronotail raw | 152.78 MiB | 16.020 |
| random | Chronotail compressed | 102.85 MiB | 10.785 |
| random | NanoTS normal | 763.10 MiB | 80.017 |
| random | SQLite normal | 356.87 MiB | 37.421 |


![Storage efficiency](bench/results/20260916-213249/storage-efficiency.svg)

Physical size includes persistent companion/catalog files whose basename begins with the database name. NanoTS preallocation is sized to exactly the required number of calculated blocks; no unused reserve blocks are added. SQLite is checkpointed and closed before measurement.

## Methodology details

- Logical record: exactly 16 bytes (`i64` timestamp plus `f64` value).
- Chronotail uses C ABI v1 over the public engine; no internal benchmark entry point.
- NanoTS stores that exact 16-byte struct as each frame payload. Its unavoidable frame/index overhead remains physical storage overhead.
- SQLite schema is the requested composite primary key and uses prepared statements, WAL, a 64 MiB cache, a 1 GiB mmap ceiling, and `synchronous=FULL` for durable runs. Workload A uses `synchronous=OFF` because it explicitly requests no durability synchronization.
- Append latency uses deterministic randomized sample intervals averaging one in 1,024 public append calls. This avoids periodic aliasing and prevents two clock reads from dominating every 16-byte operation. Sync/checkpoint time is tracked separately in raw output.
- Query latency times every query and includes result traversal/consumption.
- Smooth values are deterministic trend-plus-sine telemetry. Random values come from pinned SplitMix64 output.
- Setup is outside query timing. Process startup is never timed.
- Run order rotates among engines on each repetition to reduce order and thermal bias.
- No tuning decision is based on measured winners.

## Reproduce

```bash
./bench/competitive/build.sh
python3 bench/competitive/run.py
```

The suite pins NanoTS, builds all engines locally, captures machine metadata, preserves raw JSONL, and regenerates this report and dependency-free SVG charts.
