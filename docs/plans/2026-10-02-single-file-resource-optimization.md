# Chronotail 3.0.0: single-file time-series leadership

Status: ambitious proposal for review. No engine implementation has started.
Current source: 2.1.0. Proposed next major release: **3.0.0**.
This proposal replaces the earlier incremental optimization plan.

## Product goal

Make Chronotail the compelling default for exact, strictly ordered numeric
time-series storage inside an application: one database file, minimal CPU and
memory, excellent compression, fast ingestion, and efficient historical analysis.

Leadership must be demonstrated on a published workload suite. This is an
embedded ordered-data claim, not a claim to replace every SQL, monitoring, or
distributed database. Commercial adoption and market share are separate from
technical benchmark leadership.

One synchronous writer. Immutable readers. One `.ctdb` file. No runtime
dependencies, server, replication, sharding, or parallel ingestion workers.

## The domain advantage: make time-series questions native

Performance is the implementation advantage. The product advantage is answering
the questions an application actually asks about a measured signal, directly
from compressed history, with explicit time and numerical semantics.

The initial market is high-frequency application-owned numeric history:
machine/sensor telemetry, performance recordings, and market measurements.
Applications provide strictly ordered points per series. Chronotail owns exact
storage, durable publication, efficient temporal access, and bounded analysis.
This is a clear adoption wedge; generic remote observability and mutable
late-arrival analytics are different requirements.

The transferable TigerBeetle lesson is specialization around domain invariants
and correctness, not treating it as a competing time-series implementation.
Chronotail's leverage comes from increasing timestamps, immutable history,
numeric streams, explicit sample meaning, and queries bounded by time and
requested resolution. Existing snapshot publication and summary aggregates are
foundations, not new 3.0 features.

### Proposed 3.0 capabilities

| Capability | Application question | Concrete addition beyond v2 |
|---|---|---|
| Temporal lookup | What was the last known value at this time? | Exact/predecessor/successor/nearest lookup with tolerance and explicit missing results |
| Resolution-aware charts | Show this history at 1,200-pixel resolution | Bounded first/min/max/last envelopes with original sample timestamps and gap flags |
| Signal-aware analysis | What changed, what was the rate, and how long was the signal above a threshold? | Delta/rate and duration/time-weighted operators with declared gauge/counter and interpolation policies |
| Aligned multi-series reads | What did these channels show at the same times? | Bounded grid/as-of alignment across series within one committed generation |
| Exact counters | Can I store a counter greater than 2^53 without losing units? | Immutable per-series signed/unsigned 64-bit or float64 value type, with checked typed summaries |
| Recording batches | Did all channels from this acquisition publish together? | A cross-series batch API validated before mutation, using the existing atomic generation publication |
| Storage lifecycle | Keep this interval and reclaim unused file space | Explicit verified rewrite/retention into a replacement file; no automatic background maintenance |

These capabilities are proposed additions, not descriptions of current APIs.
All retain caller-bounded output and scratch. Series descriptors include stable
value type, timestamp unit/epoch, and declared sample kind where needed.

### Properties that make the capabilities trustworthy

- Preserve every stored timestamp/value bit. Float storage is lossless; float
  aggregates follow a documented accuracy/exceptional-value contract rather
  than promising exact real-number arithmetic. Integer sums use checked wider
  accumulators and explicit overflow results.
- Missing is distinct from zero. No implicit filling or interpolation. Define
  timestamp units, window edges, tie breaking, maximum accepted sample age,
  large gaps, and incomplete windows explicitly.
- Counter reset/wrap handling is a caller-declared policy, never an unqualified
  guess from a falling value. Irregular-sample rates use actual elapsed time.
- Time-weighted/duration results declare step or linear interpolation, endpoint
  coverage, and whether gaps make a result incomplete. Numerical approximations
  are labeled; interpolation is not a claim about unobserved reality.
- Chart envelopes preserve each bucket's actual extrema and their timestamps;
  they do not claim to preserve every intra-bucket event. Raw history is retained.
- Align related series against one immutable generation. Describe cross-series
  batch failure/poison behavior explicitly; do not imply general SQL transactions.
- A query returns a bounded result or an explicit capacity/progress outcome.
  CPU may still grow with inspected data. Summaries only skip data when they
  are sufficient for the requested operator.

### Where we aim to win

Win the complete workflow: record dense signals, durably commit, inspect history,
produce a faithful chart, compute rates/windows, and correlate channels inside
the host application. Benchmarks include client crossings and consumed output.

SQL engines can express many of these operations and other time-series systems
already implement several. The advantage must be their combination in a tiny
embedded engine, with bounded memory, exact history, and persistently accelerated
queries. API novelty alone is not a competitive claim.

Freeze three product demonstrations alongside the benchmark suite:

1. Chart a billion-point history into 1,200 buckets with exact bucket extrema and
   bounded working memory; measure how many pages must actually be inspected.
2. Read the latest values and aligned/rate windows across 1,000 related channels
   from one generation, preserving missing/reset/gap semantics.
3. Record large integer counters exactly, crash during publication or retention
   rewrite, reopen, and verify complete acknowledged state and numerical results.

Compare equivalent implementations and result semantics against current SQLite,
DuckDB, and relevant embedded time-series engines. Exact quantiles, arbitrary
joins, and general SQL are not implied by these demonstrations.

## Breakthrough targets

All improvement ratios compare against the current 2.1 source on the same
machine and frozen inputs. These are release ambitions, not measured results.
Select and freeze exact primary workload identities before implementation.
Do not select only favorable cells after experiments.

| Area | Proposed target | Measurement boundary |
|---|---|---|
| Ingestion | 2x geometric-mean throughput across the frozen ingestion suite; 3x on compressed large batches | Include encoding, index construction, and memory publication, not buffer filling alone |
| CPU | 3x less retired instruction work in selected bottleneck kernels | Same public operation and result; verify cycles and elapsed time too |
| Point and short-range reads | 3x geometric-mean query throughput across the frozen suite | Include irregular timestamps, random values, and first-touch workloads |
| Batched point access | 10x throughput versus individual prepared calls | New bounded batch API, identical requests/results; report batch latency separately |
| Windowed analysis | 5x throughput on page-spanning window workloads | Identical count/min/max/sum/first/last results under the documented numerical contract |
| Compressible storage | 2x smaller total files on smooth data; 4x smaller on constant/repeated data | Include indexes, catalogs, and root/control overhead |
| Small commits | 5x less write amplification | Total bytes written per committed point, including metadata |
| Many-series checkpoints | 10x lower p95 CPU-bound latency at 10K series with one dirty series | Keep publication/durability modes separate |
| Working memory | 2x less engine metadata/scratch on high-cardinality workloads | Account for reader/writer state and refresh peaks; measure resident mapped pages separately |

No universal compression ratio is promised for random bits. Random-value and
irregular-timestamp streams are explicit controls. Long raw scans should approach
at least 70% of an equivalent measured read-and-copy bandwidth probe, with useful
bytes and checksum work separately accounted for.

Durable throughput is measured separately at identical checkpoint cadence and
durability guarantees. Keep both sync barriers. Do not claim filesystem latency
can improve in proportion to CPU improvements.

## 1. Redesign the persistent layout around time-series patterns

Concrete candidates:

- Dense, compact timestamp search directories, separated from larger summaries
  and object identities, to increase index fanout and reduce dependent reads.
- An incrementally updated series catalog, so changing one series does not
  rewrite descriptions for all series.
- Independently seekable compressed groups, with geometry chosen from measured
  storage-versus-decode costs rather than inheriting v7's fixed restart interval.
- Exact repeated-value/run encodings and bit-packed delta/XOR candidates, in
  addition to raw fallbacks. Select encoding at page construction, with bounded
  codec-specific read kernels and no runtime storage backend dispatch.
- Typed numeric columns and compact boundary/extrema state sufficient for the
  accepted chart, counter, and temporal operators. Benchmark optional summaries
  against their additional storage, encoding, and verification cost.
- Smaller physical objects for small publications where geometry permits it,
  without weakening authentication or root fallback.

The format decision follows prototypes. Format v8 is the expected candidate if
these changes need new persistent structures. Each additional structure must pay
for its own bytes and CPU; no large decoded cache may disguise format costs.

Deliverable: a measured layout prototype and an explicit format specification.

## 2. Build a low-work ingestion pipeline

Validate the batch, then reuse that proven ordering. Fuse value encoding with
statistics, write directly from suitable caller/buffer layouts, and retain only
bounded append state. Existing v2 optimizations are the baseline, not new wins.

Make catalog/index publication proportional to modified series and newly
written objects. Reduce partial-page waste and avoid repeated right-spine
serialization where a new layout can safely remove it. Measure complete commit
cycles across batch sizes; ingestion speed that merely postpones work does not
count.

Add a bounded cross-series acquisition batch that validates every input before
mutation and publishes related channels in one generation. Operational failures
must prevent partial publication. Retain the single-writer model.

Deliverable: higher single-writer throughput with fewer instructions, copied
bytes, and persistent bytes per point.

## 3. Build search and decoding for real timestamp distributions

Use arithmetic mapping for exactly regular timestamps; compact search indexes
and bounded fallback for irregular streams. Locate the requested compressed
group without decoding preceding groups. Evaluate block decode and compile-time
SIMD only when it reduces total work on the supported native target.

Add a caller-buffered batch-point API that groups requests by page and returns
results in caller order. Include grouping/sorting and restoration in the measured
cost; bound scratch by the declared batch capacity. Improve independent lookups
as well, so the batch result cannot conceal a weak point-query path.

Deliverable: fast exact lookups and short ranges without a large memory cache.

## 4. Make time-window analysis a first-class fast path

Return count, minimum, maximum, sum, first, and last together. Use compact
sub-page summaries only where their query gains repay persistent overhead.
Traverse once for a complete fixed-resolution window request; skip covered
regions and decode partial boundaries. Evaluate fused requests for several
resolutions so clients do not repeatedly scan the same history.

Expose the useful bounded analysis paths consistently in Zig, C, Go, and
Python. Keep raw data exact. Floating-point summation order and exceptional
values require explicit tests and a documented numerical contract; never
silently change semantics to produce a benchmark win.

Implement temporal lookup, chart envelopes, explicit delta/rate semantics,
bounded multi-series alignment, and duration/time-weighted analysis under the
contracts above. Some can reuse summaries; others require bounded scans. Do
not claim a summary-only complexity for arbitrary rates or threshold queries.

Deliverable: practical historical/window analysis without full point scans or
client-side materialization when summaries suffice.

## 5. Make memory and long-running cost explicit

Separate hot search state from cold catalog/summary state. Bound writer buffers,
verification caches, batch scratch, and temporary checkpoint memory. Eliminate
full-catalog refresh copies where the new layout permits it, keeping current
explicit view lifetimes unless an API change is justified.

Measure repeated small commits and refreshes over long runs, including obsolete
metadata growth. Set an amplification budget from the chosen layout. Do not
claim permanently bounded file size: retaining all historical data necessarily
grows the file.

Add explicit offline maintenance: retain a chosen interval and/or rewrite only
reachable live objects into a separate verified replacement. It may temporarily
need space for both files. Quiesce the writer, define reader lifetimes, and use
a platform-validated durable replacement protocol. Fault simulation must prove
the old or new valid database survives each interruption, including directory
publication. Normal operation remains one database file with no worker thread.

Deliverable: low memory per series and published growth/cost curves as history
and checkpoint counts increase.

## Evidence and acceptance

1. Freeze the native v2.1 baseline and primary suite before optimization. Cover
   regular/irregular timestamps; constant/smooth/spiky/random values; scalar and
   batched ingestion; small commits; 1/1K/10K series; tiny ranges through full
   scans; first-touch and datasets larger than RAM.
2. Control and document cache state. First-touch is not automatically cold disk.
   Use native macOS ARM64 for release evidence; no new platform claim without
   native artifact validation.
3. Prototype layout, codec, and summary choices before committing to format v8.
   Compare total storage, CPU, latency, I/O, and memory together.
4. Run zig fmt, Debug, ReleaseSafe, ReleaseFast, relevant client/ABI checks, and
   deterministic crash/corruption simulation after engine/persistence changes.
   Complete at least the existing 1,000-seed/100M-operation campaign for release,
   including new format failure states and verified migration if applicable.
   Add semantic reference checks for time boundaries, missing samples, gaps,
   counter resets/wraps, integer overflow, exceptional floats, envelopes, aligned
   snapshots, cross-series admission failures, and interrupted maintenance.
5. Preserve the existing pinned competitive methodology. Add a separately
   specified modern comparison suite with current SQLite, NanoTS, and DuckDB
   where equivalent ingestion/range/window operations exist. Publish versions,
   configuration, hardware, durability boundaries, raw results, and uncertainty.
6. Require no unexplained regression above 5% beyond measured variability in
   primary workloads. Record every material tradeoff and rejected experiment.
   Allocation-free prepared paths, checksums, validation, and recovery are gates.

For the 3.0 resource-leadership claim, aim for at least 2x geometric-mean
throughput against each comparator on the common frozen embedded workload
subset, with no repeatable loss above 10% on an individual comparable workload.
Assess storage and memory separately: the speed lead must not depend on a larger
file or unbounded memory. Publish exceptions and avoid cross-suite or whole-market
claims. Durability rows only get ratios if guarantees are actually comparable.

Missing a target triggers redesign, explicit scope review, or a narrower release
claim. It never triggers quieter benchmarks or weaker safety checks.

## Compatibility and review order

Version 3 is permission to propose better structures, not permission to destroy
old files. Maintain the v2/v7 line. Any v8 migration produces a separate verified
file. Preserve C ABI v2 where additive changes suffice; separately version any
breaking API or ABI. Document numerical and snapshot-lifetime changes explicitly.

Review sequence:

1. Approve the domain promise, capability contracts, ambitious resource goals,
   and target suite direction.
2. Review baseline, resource ceilings, layout prototypes, and compatibility
   design before persistent-layout implementation.
3. Implement in dependency order: types/time contracts and baseline; layout and
   publication; codecs/temporal search; chart/window/signal operators; aligned
   batch/client APIs; verified lifecycle maintenance; final resource audit.
4. Review achieved results and gaps before release publication.

The release does not add distributed features, background workers, lossy data,
late-data insertion, SQL, automatic retention, or platform expansion. Engineering
scope is a complete embedded workflow for exact ordered numeric history, with
explicit analysis and lifecycle semantics and resource-efficient implementation.
