# CPU-work minimization design

Status: active on `perf/cpu-perfection`.

## Objective and measurement

Chronotail will minimize CPU work per public operation without changing format
v7, C ABI v2, public behavior, durability, recovery, validation, allocation, or
deterministic-simulation guarantees. The primary metric is retired instructions
per logical operation. Until Apple CPU counters are available locally, static
ARM64 instruction inspection and repeated ReleaseFast timings are proxies;
cycles, bytes moved, branches, syscalls, hot text size, and allocations remain
guardrails. Throughput alone is insufficient because parallelism can improve
elapsed time while increasing total work.

Every change follows the same loop: identify redundant work from profiles and
disassembly, express the invariant that makes it removable, change one concern,
run correctness gates, compare repeated public-API benchmarks, and retain only
neutral or improved candidates. Rejected experiments are recorded with their
reason. No optimization may replace bounded validation with trust at a public or
persistent boundary.

## Architecture direction

The work proceeds from eliminated computation to specialized hot paths, then to
layout changes that preserve the file format. Writer admission becomes the sole
ordering boundary for buffered appends, so page flushes consume an already
proved ordered buffer. Encoders initialize only bytes included in deterministic
persistent output. Index construction carries forward summaries it has already
computed instead of rereading newly written nodes.

On production mmap readers, authenticated immutable objects become verified
runtime state: prepared series retain the active root, leaf, and page view until
a query crosses their range or refresh invalidates the snapshot. Generic and
simulated storage continues authenticating every read because its bytes may
change between accesses. Range, count, copy, aggregate, and text-output modes
are compile-time-specialized behind shared traversal primitives so unused modes
do not inflate the hot loop. Compressed timestamp search first locates a restart
group from its anchors, then decodes only that bounded group. One-point ranges
perform one lower-bound search.

Changes will be small and independently reversible. Floating-point summary
order, checksums, zero padding, object identities, error precedence, and on-disk
bytes are explicit compatibility constraints.

## Verification

Each retained engine change must pass formatting, Debug, ReleaseSafe, and
ReleaseFast tests plus deterministic simulation. Relevant benchmarks run in
multiple repetitions with identical pre-generated inputs; medians and material
tail changes are compared. Storage bytes and identities are checked whenever an
encoder changes. The final pass audits generated ARM64 code for accidental hot
code growth, division, redundant scans, and missed bulk operations, then runs
the complete public benchmark methodology before any release claim.
