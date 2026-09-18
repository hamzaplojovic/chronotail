# Optimization roadmap

These are engineering predictions, not benchmark claims. “From” values are
rounded anchors from the final three-pass internal profile or explicitly
identified development prototypes on the same machine. Each experiment must
keep correctness gates and be rejected if the measured result disagrees.

Completed on `perf/cpu-perfection`: verified root/leaf/page reuse, restart-aware
delta lower bounds, compile-time range sinks, root/subtree count summaries,
stateful additive C cursors, transactional writer right-spine reuse, and
single-pass writer manifest construction, direct interleaved Go ranges, direct
index encoding, and bounded page-write coalescing. Measurements and rejected
variants are in the [experiment ledger](../../bench/results/cpu-perfection/README.md).

- Add a bounded parallel compressed-page builder with deterministic output ordering: **about 58M -> 150–250M compressed appended points/s** on four performance cores when batches contain many pages.
- Replace full-snapshot refresh remapping with pinned segment maps and explicit reclamation: **about 4.1K -> 50–200K changed refreshes/s** for small appended generations while preserving old borrowed views.
- Shard or persist the series manifest as a copy-on-write directory: **O(series) -> O(log series) checkpoint metadata**, targeting **10× lower checkpoint latency at 10K mostly-idle series**.
- Add SIMD timestamp lower-bound probes for irregular raw pages: **about 2.1M -> 6–12M irregular point queries/s** without weakening the binary-search fallback.
- Vectorize restart-group XOR decode and specialize smooth-value runs: **about 106–195M -> 220–350M compressed range points/s** for 100–1,000-point smooth ranges.
- Add a prepared batch-query API that sorts page-local requests and restores caller order: **about 2.4–6.6M -> 30–80M random point lookups/s** by amortizing tree and page verification over a batch.
- Prefetch the selected index child and data page after root lookup: **about 375ns -> 250–300ns warm raw point p50** when the working set exceeds private cache.
- Encode aggregate summaries with optional compensated sum state: **same query rate with materially lower long-series sum error**, trading 8–16 bytes per index entry for numerical quality.
- Introduce a pinned snapshot object rather than retaining mappings inside Reader: **one remap per refresh -> zero invalidated views**, with memory bounded by the caller’s explicit live-snapshot limit.
- Reduce small-checkpoint metadata amplification with bounded root/manifest packing: **roughly 44 bytes/point at 256-point checkpoints -> below 25 bytes/point**, while retaining four-root fallback and two-sync durability.
- Replace Python’s two-pass range allocation with a native cursor growth policy: **one count pass plus one copy -> one streaming pass**, targeting **1.5–3× lower latency** for large Python ranges.
