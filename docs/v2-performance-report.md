# Chronotail v2 internal performance report

Status: complete internal development profile for the `v2` branch on
2026-09-17. This is not the public competitive benchmark and makes no claim
against NanoTS or SQLite.

## Evidence and method

- Host: Apple M1, macOS 26.1, ARM64, Zig 0.15.2.
- Build: `ReleaseFast`; dataset: 1,000,000 points per full workload.
- Baseline: ignored `tests/performance/results/v1-baseline.jsonl`, format v6,
  183 result rows and 155 distinct workloads. The historical harness repeated
  append workloads three times and most other workloads once.
- Candidate: ignored `tests/performance/results/v2-final.jsonl`, format v7,
  537 result rows, 179 distinct workloads, and exactly three repetitions of
  every workload.
- Reduction: medians of matching workload identities; candidate ranges quoted
  below are minimum to maximum across its three samples.
- Isolation: a run taken while unrelated Python workers saturated the host was
  rejected as timing evidence and retained as
  `tests/performance/results/v2-loaded-host.jsonl` rather than overwritten.
- Scope: public Chronotail APIs drive the workloads, while the allocation phase
  wraps the allocator to observe post-setup data-plane activity.

The raw files are intentionally untracked because results are machine evidence,
not portable source. Reproduce the comparison with:

```bash
zig build performance -Doptimize=ReleaseFast -- \
  --output tests/performance/results/v2-final.jsonl
python3 tests/performance/compare.py \
  tests/performance/results/v1-baseline.jsonl \
  tests/performance/results/v2-final.jsonl
```

## Coverage

The candidate matrix contains 179 unique workloads and 537 measurements:

| Phase | Unique workloads | Coverage |
|---|---:|---|
| Append | 31 | Seven batch sizes per codec, 12 compressed data-pattern combinations, and five series cardinalities. |
| Storage | 24 | Raw and compressed bytes/point over three timestamp and four value patterns. |
| Copied query | 64 | Eight codec/pattern datasets across six widths, plus count-only and full-count paths. |
| First touch | 8 | Initial authenticated page access and warm latency detail for every query dataset. |
| Bounded read APIs | 10 | Four cursor capacities, raw-page borrowing, and five prepared-series cardinalities. |
| Aggregates | 8 | Raw/compressed summary queries at three widths and fixed-resolution windows. |
| Checkpoint | 7 | Raw/compressed unsynced and legacy boundary labels plus raw disk-sync throughput. |
| Control plane | 8 | Open, changed/unchanged refresh, raw/compressed verification, and three corrupt-tail sizes. |
| Allocation | 8 | Prepared append, string/prepared reads, cursor, borrow, summary, windows, and unchanged refresh. |
| Concurrency | 6 | 1, 2, 4, 8, 16, and 32 immutable readers. |

Across the 155 workloads shared with v1, the median comparator reports 88
improvements, three ties, and 64 regressions. Twenty-four workloads are new v2
APIs with no v1 equivalent. Counts alone are not a quality score: a 1.1% raw
space cost and a point-query regression each count once, while new constant-time
summary paths have no baseline row.

## Append results

Rates are million points/second. V2 compressed append is faster at every batch
size. Raw scalar append gives up 8.2%, while raw batches of 16 or more improve
except for the small 4.5% gain at batch 1,000.

| Codec | Batch | V1 | V2 median | Change |
|---|---:|---:|---:|---:|
| Raw | 1 | 26.66 | 24.46 | -8.2% |
| Raw | 16 | 26.94 | 32.65 | +21.2% |
| Raw | 64 | 24.37 | 31.35 | +28.6% |
| Raw | 256 | 26.00 | 31.68 | +21.9% |
| Raw | 1,000 | 28.87 | 30.18 | +4.5% |
| Raw | 4,096 | 20.71 | 32.48 | +56.8% |
| Raw | 65,536 | 21.75 | 33.37 | +53.4% |
| Compressed | 1 | 16.96 | 35.76 | +110.8% |
| Compressed | 16 | 11.46 | 55.07 | +380.7% |
| Compressed | 64 | 10.47 | 58.61 | +459.7% |
| Compressed | 256 | 9.25 | 55.40 | +499.0% |
| Compressed | 1,000 | 27.29 | 56.73 | +107.9% |
| Compressed | 4,096 | 23.88 | 57.92 | +142.6% |
| Compressed | 65,536 | 23.54 | 57.86 | +145.8% |

All 12 compressed pattern-appends improve, from +9.9% for irregular/random to
175.5% for sparse/spiky. Scalar multi-series append changes by +46.4%, -17.4%,
+14.7%, -3.6%, and +117.3% at 1, 4, 8, 64, and 256 series respectively.

## Copied queries

The table gives throughput change at every measured copied-range width. It
shows the intended shape clearly: v2 bulk column copies dominate large raw
ranges, bounded compressed decoding dominates smooth/spiky ranges, and the
extra authenticated-tree traversal is still visible in tiny raw and random
queries.

| Codec/pattern | 1 | 10 | 100 | 1K | 10K | 100K |
|---|---:|---:|---:|---:|---:|---:|
| raw/dense/smooth | -36.0% | -35.0% | -22.3% | -2.9% | +117.6% | +154.7% |
| raw/dense/random | -65.0% | -66.1% | -58.9% | -26.6% | +103.6% | +124.0% |
| raw/sparse/spiky | -63.0% | -65.9% | -54.5% | -8.4% | +127.7% | +154.8% |
| raw/irregular/smooth | -2.4% | -13.7% | +58.0% | +17.7% | +118.6% | +157.8% |
| compressed/dense/smooth | +103.4% | +106.2% | +156.1% | +181.7% | +210.3% | +181.3% |
| compressed/dense/random | -48.8% | -39.4% | -21.8% | -0.1% | +21.6% | +22.7% |
| compressed/sparse/spiky | +69.9% | +61.7% | +106.2% | +181.1% | +205.8% | +211.7% |
| compressed/irregular/smooth | -26.7% | -4.9% | +35.2% | +168.7% | +203.6% | +213.4% |

Representative absolute results:

| Workload | V1 | V2 median | V2 three-run range |
|---|---:|---:|---:|
| Raw smooth point | 3.19M points/s | 2.04M | 1.50–2.04M |
| Raw smooth 100 | 189.06M points/s | 146.92M | 140.38–151.71M |
| Raw smooth 10K | 719.89M points/s | 1.57B | 1.48–1.70B |
| Raw smooth 100K | 712.17M points/s | 1.81B | 1.59–1.84B |
| Compressed smooth point | 0.83M points/s | 1.68M | 1.05–1.88M |
| Compressed smooth 100 | 41.31M points/s | 105.79M | 88.24–111.12M |
| Compressed smooth 10K | 74.26M points/s | 230.47M | 218.49–237.37M |

At width 100, count-only changes are +42.3% raw dense/smooth, -43.9% raw
dense/random, -32.3% raw sparse/spiky, +79.0% raw irregular/smooth, +1,010.6%
compressed dense/smooth, -32.5% compressed dense/random, +346.6% compressed
sparse/spiky, and +129.0% compressed irregular/smooth.

Full-series count consumes authenticated index summaries rather than values.
The dense/smooth medians are 615.38B logical points/s raw and 621.77B
compressed, versus 2.23B and 74.12M in v1. These are logical coverage rates for
an almost constant-time metadata operation, not memory bandwidth; their large
ratios are timer-sensitive and should be read structurally, not literally.

## New bounded read and aggregate APIs

| Workload | V2 median | Three-run range |
|---|---:|---:|
| Cursor, 16-point buffer | 217.38M points/s | 198.33–218.23M |
| Cursor, 128-point buffer | 562.80M points/s | 534.08–578.84M |
| Cursor, 1,024-point buffer | 583.14M points/s | 489.38–591.58M |
| Cursor, 4,096-point buffer | 598.25M points/s | 499.70–601.59M |
| Borrow raw page | 5.19M acquisitions/s | 3.19–6.71M |
| Prepared point, 256 series | 6.57M points/s | 4.53–8.47M |
| Aggregate 100 raw/compressed | 36.11M / 32.87M logical points/s | 34.24–37.34M / 30.33–35.35M |
| Aggregate 10K raw/compressed | 894.34M / 431.18M logical points/s | 889.38–944.34M / 407.66–505.95M |
| Ten 100K resolution windows, raw/compressed | 4.83B / 4.68B logical points/s | 4.75–4.96B / 4.52–4.99B |

The full-range aggregate is another summary lookup and therefore timer-limited:
100T logical points/s raw and 48.08T compressed at the median. It proves the
O(1)-with-tree-height path but is not useful as a hardware throughput claim.

Prepared handles improve the v2 256-series point path from 4.29M to 6.57M
queries/s, but v1 string lookup was 14.06M. The missing active-leaf/page cache
is therefore a measured optimization target, not a hidden regression.

## Storage

Raw format-v7 storage is 16.196 bytes/point across the matrix versus 16.020 in
v1, a 1.1% cost for v7 object/index metadata. Compressed results are:

| Timestamp/value pattern | V1 bytes/point | V2 bytes/point | Size change |
|---|---:|---:|---:|
| dense/constant | 1.389 | 1.288 | -7.3% |
| dense/random | 16.020 | 8.200 | -48.8% |
| dense/smooth | 7.639 | 6.282 | -17.8% |
| dense/spiky | 1.396 | 1.303 | -6.7% |
| irregular/constant | 1.516 | 2.372 | +56.5% |
| irregular/random | 16.020 | 9.284 | -42.0% |
| irregular/smooth | 7.766 | 7.366 | -5.2% |
| irregular/spiky | 1.524 | 2.387 | +56.7% |
| sparse/constant | 1.396 | 1.288 | -7.8% |
| sparse/random | 16.020 | 8.200 | -48.8% |
| sparse/smooth | 7.646 | 6.282 | -17.8% |
| sparse/spiky | 1.404 | 1.303 | -7.2% |

Independent timestamp/value codec selection is the main win for random values.
Irregular constant and spiky streams expose the inverse tradeoff: restart and
timestamp metadata dominate data that v1 encoded exceptionally compactly.

## Checkpoint, control plane, and concurrency

The immutable publication model makes recovery and verification faster but
makes small checkpoints more metadata-heavy.

| Workload | V1 | V2 median | Change |
|---|---:|---:|---:|
| Unsynced raw, 4,096 points | 36.40M points/s | 22.61M | -37.9% |
| Unsynced compressed, 4,096 points | 29.05M points/s | 31.03M | +6.8% |
| Snapshot-label raw p50 | 22.46 us | 64.13 us | +185.5% latency |
| Snapshot-label compressed p50 | 21.83 us | 62.38 us | +185.7% latency |
| Delta-label raw p50 | 4.71 us | 63.42 us | +1,247.0% latency |
| Delta-label compressed p50 | 5.50 us | 62.67 us | +1,039.4% latency |
| Raw disk-sync | 61.25M points/s | 32.05M | -47.7% |
| Reader open p50 | 81.13 us | 93.88 us | +15.7% latency |
| Unchanged refresh | 2.62M/s | 2.45M/s | -6.4% |
| Changed refresh | 5.48K/s | 4.13K/s | -24.7% |
| Raw verification | 29.62M points/s | 35.18M | +18.7% |
| Compressed verification | 30.34M points/s | 50.40M | +66.1% |
| Recover 64 KiB damaged tail | 5.85K/s | 8.10K/s | +38.5% |
| Recover 1 MiB damaged tail | 838/s | 3.44K/s | +310.1% |
| Recover 16 MiB damaged tail | 69/s | 668/s | +865.4% |

The three recovery sizes are separate identities in the comparator. The growing
advantage demonstrates the v7 goal: root election is bounded while v1 scans and
validates more damaged tail.

Parallel 100-point read throughput regresses at every tested reader count:
159.58M, 304.26M, 523.49M, 576.96M, 534.75M, and 350.68M points/s at 1, 2, 4,
8, 16, and 32 readers, respectively. Relative to v1 those are -64.6%, -65.7%,
-57.6%, -50.3%, -41.1%, and -35.1%. Authentication/tree traversal is not free;
prepared page-local batching and caching are the next route to recovering this
throughput without weakening verification.

## Allocation result

All three repetitions of all eight allocation workloads report zero alloc,
resize, remap, free, and allocated bytes inside the measured region: prepared
append, warm string query, prepared query, persistent cursor, borrowed raw page,
summary aggregate, resolution windows, and unchanged refresh. That is 24/24
zero-activity rows. Setup memory remains live by design and is outside the
steady-state assertion.

## Complete regression ledger

No measured regression is omitted:

- raw scalar append is -8.2%; 4-series and 64-series scalar append are -17.4%
  and -3.6%; every other append comparison improves;
- copied raw ranges usually regress below 1,000 points and improve strongly at
  10,000 and 100,000 points; irregular/smooth turns positive at width 100;
- compressed dense/random regresses through width 1,000, and compressed
  irregular/smooth regresses at widths 1 and 10; other measured compressed
  range families improve;
- count-only dense/random and raw sparse/spiky regress by 32–44%, while the
  summary-friendly count families improve;
- string-resolved point lookup regresses 67–88% across 1–256 series, and the
  prepared path does not yet recover the v1 rate;
- four of eight first-touch detail comparisons regress, including three small
  raw-page cases and compressed dense/random;
- raw storage grows 1.1%; compressed irregular constant and spiky grow about
  56.5%; the other ten compressed storage cases shrink;
- six of seven checkpoint comparisons regress; compressed unsynced throughput
  is the exception;
- open and refresh regress while verification and corrupt-tail recovery improve;
- all six parallel-reader comparisons regress.

These are accepted v2 tradeoffs only in the sense that they are visible and the
redesign's safety/structural goals are complete. They remain concrete inputs to
the optimization list rather than being relabeled as wins.

## Reworked and rejected experiments

- The first cursor implementation re-walked the tree for every chunk and
  delivered roughly 0.1M points/s at 16-point capacity and 1M at 128; it was
  replaced with retained bounded traversal/page state, reaching 217M and 563M
  in the final run.
- The first resolution-window wrapper called aggregate once per bucket. A
  single bounded walk replaced it. Tiny windows initially obscured summary
  skipping, so the profile now uses ten page-spanning windows and reports both
  logical coverage and output count.
- The CPU-saturated full run was rejected for timing comparison and preserved
  under the explicit `v2-loaded-host` name; structural storage/allocation data
  agreed, but CPU-sensitive rates did not.
- Coalescing physical data-page writes was not smuggled into the release after
  the fact. Only multi-node index writes are coalesced; page coalescing remains
  a separately measurable opportunity.

## Correctness evidence adjacent to performance

Profiling never substitutes for correctness. The final deterministic simulator
campaign completed 1,000 seeds and 100,000,000 operations with 1,934 crashes,
1,876 short writes, 1,877 failed writes, 5,970 truncations, 5,961 corruptions,
58,623 checkpoint/reopen cycles, and zero invariant failures.

That campaign found one real issue before the final profile: generic simulated
storage could reuse a verification-cache identity after an in-place corruption
mutation. Generic storage now reauthenticates returned objects; production
read-only file mappings retain the identity cache. The reproducing seed and the
complete campaign passed after the fix.

## Interpretation

V2 succeeds at the architectural bets that require a format change: bounded
recovery, immutable authenticated structure, much faster compressed ingest,
smaller random-value storage, multi-gigapoint bulk reads, summary-backed count
and aggregate queries, persistent cursors, and a demonstrably allocation-free
prepared data plane. It does not yet win tiny raw reads, small checkpoint
latency, series-name lookup, or parallel 100-point reads. Those limits define
the next optimization work; they do not justify weakening v7 validation.

The public competitive benchmark has deliberately not been run. It is the next
separate evidence run after this branch is handed back, exactly as requested.
