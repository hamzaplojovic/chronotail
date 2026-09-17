# Chronotail performance engineering log

Baseline competitive run: `bench/results/20260916-200732`

Final competitive run: `bench/results/20260916-213249`

Instruments `xctrace` is installed but unusable because the active developer directory contains Command Line Tools rather than full Xcode. Profiling therefore used macOS `sample`, internal stage timers, `/usr/bin/time`, syscall stacks, and ARM64 disassembly. Hardware cycles/cache-miss counters were unavailable and are not estimated.

| # | Optimization | Focused workload | Before | After | Delta | Decision |
|---:|---|---|---:|---:|---:|---|
| 1 | Binary lower-bound inside raw blocks | raw 100-point query | 0.845M/s | 1.193M/s | +41% | kept |
| 2 | Skip repeated header decode/validation after verified cache hit | raw 100-point query | 1.193M/s | 1.417M/s | +19% | kept |
| 3 | Reservoir-based bit reader replacing per-bit loop | compressed 100-point query | 0.173M/s | 0.379M/s | 2.19x | kept |
| 4 | Reservoir-based bit writer replacing per-bit loop | smooth compressed append | 7.37M/s | 27.60M/s | 3.75x | kept |
| 5 | Single writer-series lookup instead of two linear scans | raw append | 28.89M/s | 33.76M/s | +17% | kept |
| 6 | Remove `verified` byte from `BlockIndex` | raw query | 1.308M/s | 1.213M/s | -7% | reverted; layout size did not shrink usefully |
| 7 | Shared read-only whole-file mmap for production readers | raw query | 1.308M/s | 2.100M/s | +61% | kept |
| 8 | Force-inline timestamp varint decoder | compressed query | 0.396M/s | 0.365M/s | -8% | reverted; code growth hurt the loop |
| 9 | Validate compressed checkpoint table once per block | compressed query | 0.396M/s | 0.403M/s | +1.7% | kept |
| 10 | File-size fast rejection for unchanged `Reader.refresh()` | 2M unchanged refreshes | 29.13s | 0.79s | 36.9x | kept |
| 11 | Reuse footer serialization allocation | checkpoint p99 | 0.195ms | 0.130ms | -33% | kept |
| 12 | Write raw records directly from the final block buffer | raw append | 31.55M/s | 33.54M/s | +6% | kept |
| 13 | Dedicated single-point append validation path | C ABI append | 22.80M/s | 25.94M/s | +14% | kept |
| 14 | Sink-specialized raw scan loops | C ABI raw range | included below | included below | removes optional work per record | kept |
| 15 | Combine compressed timestamp/value decode into one operation | compressed C ABI range | 0.308M/s | 0.326M/s | +6% | kept |
| 16 | Sink-specialized compressed scan loop | compressed C ABI range | 0.326M/s | 0.331M/s | +1.4% | kept |
| 17 | Prefetch/SIMD review | search/codec | — | — | not implemented | dependent binary-search loads and variable-width Gorilla codes offered no justified insertion point; avoided speculative complexity |

Focused experiment logs were consolidated into this ledger and the final report during repository cleanup. Retained changes were judged again by the complete competitive matrix rather than by probes alone.
