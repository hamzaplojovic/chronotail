# CPU optimization progress

Last updated: 2026-09-18  
Branch: `perf/cpu-perfection`  
Base: `origin/main` at `07234b5`  
Status: paused intentionally; continue from this branch.

## Goal and non-negotiable constraints

Minimize CPU work per public operation while simplifying the implementation.
Retired instructions per logical operation are the preferred metric; repeated
ReleaseFast latency/throughput, generated ARM64, bytes moved, syscalls,
allocations, and hot-path code shape are the available proxies.

Keep format v7, C ABI v2, Zig/C/Python/Go/CLI behavior, checksums, validation,
durability, recovery, deterministic simulation, and allocation-free prepared
data paths unchanged. Do not add runtime dispatch or production dependencies.
Every experiment must be measured, and rejected experiments stay documented.

The detailed design is in
`docs/plans/2026-09-18-cpu-perfection-design.md`. The complete measurement and
rejection ledger is in `bench/results/cpu-perfection/README.md`.

## Retained work

- Removed redundant index rereads by returning root summaries directly from
  append construction and deriving index summaries while encoding.
- Added verified mapped-reader root, leaf, and page reuse; exact/restart-aware
  searches; reused decoded boundary timestamps; and summary-only count paths.
- Compile-time-specialized count, column, point, file, and profiling sinks so
  unused modes disappear from generated loops.
- Fused compressed encoding with statistics and compressed validation with its
  statistics pass; folded index decode and summary validation into one pass.
- Replaced heap scratch with bounded stack scratch where it improved the path;
  consolidated manifest names and reopened writer columns into slabs; reduced
  series-directory construction to one probe.
- Buffered text output instead of issuing per-point writes. This was roughly a
  21x win in the measured text-range workload.
- Added exact-full-page direct append and four-page production write
  coalescing. The latter improved a 65,536-point batch by 14.2% raw and 9.1%
  compressed; compressed 500,000-point patterns improved 5.3-16.1%.
- Made refresh load a successful snapshot once and fixed publication races.
- Added a transactional writer right-spine cache, exact-capacity in-place
  updates, and direct final-slot writes. The successive retained changes cut
  checkpoint p50 by several percent; the final direct write removed a full
  roughly-8-KiB node copy and improved p50 another 1.0% raw / 1.5% compressed.
- Added known-size, direct writer-manifest encoding and direct index-entry
  encoding, avoiding temporary object materialization and copies.
- Track dirty series explicitly so checkpoint work scales with touched series.
- Added an additive opaque C cursor and switched Go cursors to it. Depending on
  chunk size, measured Go cursor gains were roughly 2-35%.
- Added direct interleaved `ct_point` materialization for C/Go. Go 100,000-point
  range median fell 55.5% raw and 24.9% compressed; allocation fell from about
  3.21 MB/5 allocations to 1.61 MB/3 allocations.
- Consolidated each new writer series name and both staging columns into one
  aligned ownership slab, reducing three persistent allocations/frees to one.
- Added focused performance modes and allocation/remap counters to the internal
  benchmark harness.

## Correctness hardening found by the optimization review

- Prevented maximum-height index growth from indexing beyond fixed arrays.
- Kept prepared-but-empty series unpublished until their first append while
  separately bounding eventual catalog geometry.
- Reserved dirty-list capacity against all prepared series; a 128-series test
  covers making every prepared series dirty before one checkpoint.
- Fixed refresh observation when root publication does not grow the file.
- Made an empty Go cursor complete immediately.
- Bound opaque C cursor state to both its reader address and a monotonically
  unique handle token, preventing stale mapped views after allocator reuse.
- Hardened cached-spine validation against oversized counts and invalid levels.
- Added C ABI layout assertions and format-v7 golden database hashes.

## Important rejected experiments

- Writer-only ordering/partial page clearing: LLVM already removed the work.
- Fixed-window mapped traversal, persistent Zig page decoders, broad page
  caching, incremental aggregate buckets, manual/base-step specializations,
  duplicate trusted decoders, and vectored raw serialization: neutral or worse.
- Python interleaved ctypes points: about 2.2x slower; Python keeps primitive
  timestamp/value arrays.
- Reader last-series cache: helped one-series lookup but regressed 8-series by
  about 6% and 64-series by about 18%.
- Reserving the maximum spine depth: rejected because 1,024 touched series
  could retain about 64 MiB.
- Splitting cached/uncached spine functions cut the ReleaseFast checkpoint stack
  frame from 121,664 to about 49,520 bytes but regressed unsynced throughput
  17.9% raw and 32.5% compressed. The faster unified path is retained.

See the ledger for every rejected micro-experiment and exact context.

## Resume here on Monday

1. Rerun the raw/raw full-page end-bound experiment in isolation. The proposed
   change was to use `statistics.count` when `end >= timestamp_max` instead of
   doing a second binary search. It was reverted before this checkpoint because
   the candidate run showed machine-wide drift in unrelated compressed rows.
2. Profile public prepared point/range queries with stable CPU conditions.
   Consider a dedicated single-point traversal only if it deletes generic frame
   work without duplicating validation.
3. Explore vectorized irregular raw timestamp lower-bound probes, comparing
   retired instructions or ARM64 code as well as elapsed time.
4. Prototype batched prepared lookups that group requests by page, authenticate
   each page once, and restore caller order. This is the highest-confidence
   large query-side architectural win.
5. Treat parallel page building separately: it can reduce latency but increases
   total CPU work, so it is not automatically a win under the current metric.
6. Longer-horizon structural candidates remain copy-on-write/sharded manifests
   for mostly-idle high-cardinality checkpoints and pinned snapshot mappings for
   cheap refresh. Both require explicit format/lifetime designs before code.

Before retaining any new result, use at least three identical ReleaseFast runs,
check generated ARM64 when code shape matters, update the experiment ledger,
then run the full verification below.

## Verification checkpoint

The pause commit passed all of the following on 2026-09-18:

```sh
zig fmt --check build.zig src tests sim
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build -Doptimize=ReleaseFast
CHRONOTAIL_LIBRARY="$PWD/zig-out/lib/libchronotail.dylib" \
  PYTHONPATH="$PWD/clients/python/src" \
  python3 -m unittest discover -s clients/python/tests -p 'test_*.py'
CGO_LDFLAGS="-L$PWD/zig-out/lib" \
  DYLD_LIBRARY_PATH="$PWD/zig-out/lib" \
  go test -count=1 ./clients/go
zig build simulator -Doptimize=ReleaseSafe
zig-out/bin/chronotail-sim --seeds 100 --operations 10000
git diff --check
```

The simulator completed 1,000,000 operations across 100 seeds with 17 simulated
crashes, 12 short writes, 15 failed writes, 60 truncations, 49 corruptions, 536
checkpoint/reopen cycles, and zero invariant failures. Python passed 3 tests;
the uncached Go integration suite passed. The linker emitted only a local SDK
warning because the library was built for macOS 26.1 while the link target was
macOS 26.0.

Benchmark files used during development live under `/tmp/ct-*` and are not part
of the repository. Reproduce results through `zig build performance
-Doptimize=ReleaseFast -- ...`; do not rely on `/tmp` surviving until Monday.
