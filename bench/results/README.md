# Benchmark result archives

`LATEST` names the authoritative completed public benchmark run. Each published
run is immutable evidence: keep its raw records, matrix, environment, command
log, generated report, charts, and checksum manifest together.

- `20260917-190855/` — current format-v7/C-ABI-v2 suite: 99 engine/workload
  groups, five repetitions, 495 raw measurements, and nine SVG charts. This is
  the source for the root `BENCHMARKS.md` and `docs/assets/benchmark-*.svg`.
- `20260917-105244/` — canonical format-v6/C-ABI-v1 public baseline: the
  original 45 groups, five repetitions, and 225 raw measurements. It remains a
  historical release record; background host load is disclosed in its report.
- `20260916-213249/` — valid pre-TigerStyle optimized matrix retained as a
  structural comparison point.
- `20260916-200732/` — valid original optimization baseline.
- `tigerstyle/` — machine-model experiments, paired A/B evidence, simulator
  results, performance ledger, and final engineering report.
- `performance-pass/` — preceding profiles, experiments, comparisons,
  simulator evidence, and engineering report.

Exploratory and incomplete runs are not publication evidence. Generate or
resume a run through `bench/competitive/bench.py`; only its validation and
publish step may update `LATEST`, the root report, and the documentation SVGs.
