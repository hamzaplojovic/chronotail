# Workload and failure coverage

Reuse the deterministic generators in `tests/performance/main.zig` and the
storage fault seam in `sim/main.zig`; do not maintain a second engine or random
dataset generator. Their inputs are repeatable without downloaded customer data.

| Dimension | Existing exercise | Next targeted investigation |
|---|---|---|
| Time geometry | Dense, sparse, irregular timestamps | i64 extremes, large gaps, page/restart boundaries |
| Values | Constant, smooth, spiky, random | Exceptional floats and numerically difficult aggregates |
| Ingestion | Scalar/batched, multiple series, codecs | Small commits and 10K mostly idle prepared series |
| Reads | Point/range widths, prepared access, cursors, borrowing | Unaligned generic scratch, cross-page truncation, stale lifetimes |
| Analysis | Count, six-field aggregates, fixed windows | Boundary/reference semantics before proposing new operators |
| Memory | alloc/resize/remap/free counters | Refresh peaks and per-series metadata slope |
| Publication | Roots, manifests, reopen/checkpoint | First publication, stale control observations, failed sync paths |
| Faults | Crash, short/failed write, truncate, corrupt | Preserve each newly discovered failing seed as a regression |
| Growth | Storage patterns and checkpoints | Long repeated commits and datasets larger than available RAM |

The quick suite is a smoke check; the full matrix and 100M-operation simulation
are endurance evidence. Warm/first-touch do not establish cold-disk performance.
Maximum scale is not yet proven by CI: larger-than-memory and high-cardinality
experiments require an explicitly sized host and recorded resource limits.

For each new feature, define a simple reference implementation, edge semantics,
bounded-buffer behavior, and failure model before adding optimized summaries.
Only freeze a new performance workload after correctness/reference behavior is
clear. Preserve the published competitive methodology and archives.
