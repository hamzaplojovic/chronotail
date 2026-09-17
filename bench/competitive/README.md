# Competitive benchmark suite

The benchmark deliberately has only two implementation files:

- `competitive.cpp` calls the public Chronotail, NanoTS, and SQLite APIs in one native process. C++ is required because NanoTS exposes a C++ API.
- `bench.py` pins dependencies, builds the runner, executes or resumes the matrix, validates every expected result, reduces the raw data, renders SVG charts, and publishes an explicitly selected run.

No shell wrappers, duplicate chart generators, or separate reducer scripts are involved.

## Run the complete matrix

```bash
python3 bench/competitive/bench.py run --publish
```

The suite records 495 measurements: 99 engine/workload groups repeated five times. The original 45-group public suite runs first in its original order, followed by broader batch-append, copied-range, aggregate, concurrency, and storage-pattern coverage.

A run writes to a new timestamped directory under `bench/results/`. Publication happens only after the exact matrix validates; `bench/results/LATEST` then identifies the published run.

## Resume safely

```bash
python3 bench/competitive/bench.py run \
  --resume bench/results/<run-id> \
  --publish
```

Resume is rejected if the source, runner, public header, dependency commit, ABI, format, platform, or workload matrix differs from the interrupted run.

## Regenerate a report

```bash
python3 bench/competitive/bench.py report \
  bench/results/<run-id>
```

This updates only that archived run. Add `--publish` to replace the root report, current SVG assets, and `bench/results/LATEST` after full validation.

## What is measured

- Append: per-record, 4,096-point batch, eight-series, and two durability windows.
- Copied queries: point lookup and ranges of 10, 100, 1,000, and 10,000 points.
- Aggregates: count, minimum, maximum, sum, first, and last over 100 points, 10,000 points, and the full series.
- Concurrency: one, two, four, eight, 16, and 32 readers while one writer publishes.
- Storage: constant, smooth, spiky, and random values, including both Chronotail codecs.

The runner uses public APIs, consumes results, verifies complete databases, and emits newline-delimited JSON. The report preserves raw records, the exact matrix manifest, every command, host metadata, medians, min–max ranges, latency percentiles, checksums, and dependency-free dark-mode SVG charts.

See [`BENCHMARKS.md`](../../BENCHMARKS.md) for the published results, methodology, asymmetries, and losses.
