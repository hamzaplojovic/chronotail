# Chronotail competitive benchmarks

These are measured results, not copied vendor numbers. Raw output is in [`bench/results/20260916-200732/raw.jsonl`](bench/results/20260916-200732/raw.jsonl), the aggregate CSV is in [`summary.csv`](bench/results/20260916-200732/summary.csv), and every invocation is in [`commands.log`](bench/results/20260916-200732/commands.log).

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
| append-A-none | chronotail | 21.44M/s | 327.12 | 0.041 µs | 0.083 µs | 152.78 MiB |
| append-A-none | nanots | 5.15M/s | 78.53 | 0.041 µs | 0.084 µs | 763.10 MiB |
| append-A-none | sqlite | 808.63k/s | 12.34 | 0.875 µs | 5.250 µs | 356.87 MiB |
| append-B-10MiB | chronotail | 23.35M/s | 356.33 | 0.041 µs | 0.042 µs | 152.78 MiB |
| append-B-10MiB | nanots | 4.08M/s | 62.23 | 0.041 µs | 0.125 µs | 801.10 MiB |
| append-B-10MiB | sqlite | 841.25k/s | 12.84 | 0.875 µs | 3.750 µs | 356.87 MiB |
| append-C-1MiB | chronotail | 21.60M/s | 329.61 | 0.041 µs | 0.042 µs | 152.90 MiB |
| append-C-1MiB | nanots | 3.29M/s | 50.16 | 0.041 µs | 0.125 µs | 774.68 MiB |
| append-C-1MiB | sqlite | 890.12k/s | 13.58 | 0.875 µs | 3.292 µs | 356.87 MiB |

![Append throughput](bench/results/20260916-200732/append-throughput.svg)

No cross-engine multiplier is claimed for append durability workloads. The logical durability windows match, but the public persistence primitives do not.

Durability caveat: Chronotail uses `checkpoint(fsync=true)` and SQLite commits a WAL transaction with `synchronous=FULL`. NanoTS has no public explicit checkpoint API; its block rollover performs synchronous `msync`, so its block capacity is calculated as exactly the requested number of 16-byte logical payloads. These are the closest public semantics, but macOS does not guarantee that `msync(MS_SYNC)`, `fsync`, and SQLite WAL FULL have identical power-loss behavior. The tables compare the requested logical windows, not identical persistence primitives.

## 2. Eight-series append

| Workload | Engine | Throughput | Logical MiB/s | p50 | p99 | File |
|---|---:|---:|---:|---:|---:|---:|
| append-8-series | chronotail | 13.02M/s | 198.68 | 0.042 µs | 0.084 µs | 15.28 MiB |
| append-8-series | nanots | 8.83M/s | 134.68 | 0.041 µs | 0.084 µs | 101.10 MiB |
| append-8-series | sqlite | 817.78k/s | 12.48 | 0.875 µs | 4.083 µs | 34.75 MiB |

No multiplier is claimed here because the engines expose different durability primitives.

One application thread feeds eight series round-robin. NanoTS block capacities are divided by eight so the aggregate logical durability window remains approximately 10 MiB.

## 3. Random point lookup

| Workload | Engine | Throughput | Logical MiB/s | p50 | p99 | File |
|---|---:|---:|---:|---:|---:|---:|
| point-lookup-warm | chronotail | 852.79k/s | 13.01 | 0.916 µs | 2.000 µs | 15.28 MiB |
| point-lookup-warm | nanots | 1.40M/s | 21.33 | 0.667 µs | 1.917 µs | 81.13 MiB |
| point-lookup-warm | sqlite | 208.62k/s | 3.18 | 4.250 µs | 7.333 µs | 34.30 MiB |

- Chronotail: **1.64× slower than NanoTS**
- Chronotail: **4.09× SQLite**

Cold-cache numbers are intentionally omitted: reliable cache eviction on this macOS host requires a privileged system-wide `purge`, which would make unattended runs intrusive and less reproducible.

## 4. 100-point range query

| Workload | Engine | Throughput | Logical MiB/s | p50 | p99 | File |
|---|---:|---:|---:|---:|---:|---:|
| range-100-raw-warm | chronotail | 783.12k/s | 1194.94 | 1.000 µs | 2.167 µs | 15.28 MiB |
| range-100-raw-warm | nanots | 106.01k/s | 161.76 | 9.334 µs | 11.209 µs | 81.13 MiB |
| range-100-raw-warm | sqlite | 55.02k/s | 83.96 | 16.791 µs | 30.625 µs | 34.30 MiB |
| range-100-compressed-warm | chronotail | 174.46k/s | 266.20 | 5.584 µs | 7.916 µs | 6.85 MiB |

![Query throughput](bench/results/20260916-200732/query-throughput.svg)

Raw equivalent-workload ratios:

- Chronotail: **7.39× NanoTS**
- Chronotail: **14.23× SQLite**

Chronotail compressed is shown separately and is not used for ratios against raw NanoTS or SQLite.

## Where Chronotail loses

Chronotail loses the warm random point lookup workload to NanoTS: **1.64× slower**. NanoTS provides 1.40M lookups/s versus Chronotail's 852.79k. Chronotail does not lose another measured cross-engine throughput or storage-efficiency row. Compressed Chronotail is also 4.49× slower than raw Chronotail for 100-point ranges, an internal storage/CPU tradeoff rather than a competitor loss.

## 5. Writer plus readers

| Readers | Engine | Writer records/s | Reader queries/s | Reader p50 | Reader p99 |
|---:|---|---:|---:|---:|---:|
| 1 | chronotail | 8.24M | 474.38k | 1.875 µs | 4.417 µs |
| 1 | nanots | 2.25M | 49.59k | 17.167 µs | 66.917 µs |
| 1 | sqlite | 740.77k | 47.88k | 18.792 µs | 33.709 µs |
| 8 | chronotail | 4.11M | 1.16M | 2.917 µs | 8.208 µs |
| 8 | nanots | 2.53M | 48.45k | 110.917 µs | 1105.042 µs |
| 8 | sqlite | 479.18k | 145.68k | 21.417 µs | 261.458 µs |
| 32 | chronotail | 3.01M | 1.26M | 3.583 µs | 10.625 µs |
| 32 | nanots | 2.22M | 42.14k | 248.458 µs | 5088.750 µs |
| 32 | sqlite | 186.42k | 244.39k | 22.167 µs | 2588.833 µs |


![Concurrent reader throughput](bench/results/20260916-200732/concurrent-readers.svg)

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


![Storage efficiency](bench/results/20260916-200732/storage-efficiency.svg)

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
