# Chronotail documentation

Chronotail is an embedded engine for strictly ordered timestamped data. It
stores named series in one `.ctdb` file, has no server or runtime dependencies,
and gives readers immutable committed snapshots while one writer appends.

## Start here

- [Getting started](getting-started.md) — build Chronotail, write a series, and
  query it from the CLI, Python, or Zig.
- [Architecture](architecture.md) — understand the persistent object graph,
  writer publication, reader snapshots, and recovery model.
- [Durability and recovery](durability.md) — choose memory or disk publication
  and understand what happens after interruption or corruption.
- [Migrating format-v6 files](migration.md) — create and verify a separate
  format-v7 database without modifying the source.
- [Competitive benchmarks](../BENCHMARKS.md) — current public evidence,
  methodology, raw records, caveats, and measured losses.

## API guides

- [Zig](api/zig.md) — complete native API, including prepared series, cursors,
  borrowed raw pages, aggregates, and verification.
- [C](api/c.md) — ABI v2 lifecycle, buffer sizing, errors, and ownership.
- [Python](api/python.md) — installation, batched writes, snapshots, ranges, and
  aggregates.
- [CLI](getting-started.md#command-line) — append, range, verify, inspect, and
  migrate from a terminal.

## Engineering references

- [Design rationale](design.md) — the whole-system redesign, TigerStyle lessons,
  rejected alternatives, tradeoffs, and future distribution seam.
- [Internal performance profile](performance/internal-profile.md) — the complete
  local profile against the saved pre-redesign baseline.
- [Optimization roadmap](performance/optimization-roadmap.md) — measured
  starting points and predicted targets for follow-up experiments.
- [Historical v1 machine model](performance/tigerstyle-machine-model.md) — the
  bottleneck analysis that motivated the current architecture.
- [Contributor guide](../CONTRIBUTING.md) — tests, simulation, benchmark rules,
  and pull-request evidence.
- [Release notes](../RELEASE_NOTES.md) — compatibility boundaries and validation
  status.

## Current compatibility

The current source version is 2.0.0, using portable file format v7 and C ABI v2.
Format v6 and C ABI v1 remain frozen release boundaries for Chronotail 1.x.
Current code recognizes v6 only as migration input and never rewrites a v6 file
in place. macOS ARM64 is the only release target validated so far.
