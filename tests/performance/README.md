# Internal performance profiling

This suite is the development feedback loop for Chronotail's engine. It is
separate from `bench/competitive`, whose job is to support public comparative
claims with a pinned methodology.

The profiling matrix covers:

- scalar and batched append across batch sizes, codecs, data patterns, and
  series cardinalities;
- checkpoint throughput and latency, including the format-v6 snapshot boundary;
- dense, sparse, and irregular timestamp geometry;
- constant, smooth, spiky, and random values;
- point and range widths from one point through full-series scans;
- first-touch verification and warm mapped reads;
- reader open, unchanged refresh, changed refresh, verification, and corrupt
  trailing-data recovery;
- storage bytes per point and raw/compressed block selection;
- allocator activity in steady append and query paths;
- parallel immutable readers.

Run the full matrix in ReleaseFast and save JSON Lines output:

```bash
mkdir -p tests/performance/results
zig build performance -Doptimize=ReleaseFast -- \
  --output tests/performance/results/v1-baseline.jsonl
```

Results are deliberately ignored by git. Preserve the baseline locally and
compare experiments on the same machine with alternating runs. The harness
prints progress to stderr and writes one self-describing result per line so a
partial run remains useful if interrupted.

For a short correctness/smoke pass:

```bash
zig build performance -Doptimize=ReleaseFast -- \
  --quick --output tests/performance/results/smoke.jsonl
```

No performance threshold is encoded as a test assertion. Measurements are
evidence for engineering decisions, not stable unit-test expectations.

Compare two runs by their median matching workloads:

```bash
python3 tests/performance/compare.py \
  tests/performance/results/v1-baseline.jsonl \
  tests/performance/results/v2-candidate.jsonl
```
