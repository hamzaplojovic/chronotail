# Plan Progress Report: Chronotail engine redesign

**Date:** 2026-09-17

**Plan file:** [`docs/plans/2026-09-17-engine-redesign.md`](../docs/plans/2026-09-17-engine-redesign.md)

**Status:** Completed

## Summary

- **Overall completion:** 100%
- **Plan steps complete:** 10/10
- **Partial:** 0
- **Not started:** 0
- **Critical issues:** 0
- **Original-request coverage:** 10/10 requirements, 100%

The format-v7 engine, migration boundary, APIs, deterministic simulator,
internal profiler, documentation, and release checks are complete on the `v2`
branch. The public competitive benchmark was kept out of the development
feedback loop, then run and published only after the engine and internal profile
were complete.

## Original request coverage

| # | Original requirement | Plan/implementation | Status |
|---:|---|---|---|
| 1 | Read the repository, README, and documentation for context. | Repository and documentation audit; architecture and API cross-check. | Done |
| 2 | Fetch and apply TigerBeetle's Tiger Style. | Official TigerStyle reviewed; bounded resources, static data plane, assertions, batching, deterministic simulation, and safety-first ordering applied. | Done |
| 3 | Produce a simple one-line v2 focus pitch list. | The product-focus list in `docs/design.md`. | Done |
| 4 | Produce a one-line optimization list with predicted from/to metrics. | `docs/performance/optimization-roadmap.md`, recalibrated against the final internal profile. | Done |
| 5 | Take a wide step back and rethink the entire architecture. | `docs/design.md` and the accepted engine design. | Done |
| 6 | Create full internal performance profiling under `tests/performance`. | 179-workload, three-pass candidate matrix covering append, storage, queries, new APIs, checkpoints, control plane, allocations, and concurrency. | Done |
| 7 | Capture the v1 baseline first and save results as untracked files. | Baseline committed only as harness support; `v1-baseline.jsonl` and all result runs are ignored locally. | Done |
| 8 | Create a `v2` branch from `main`. | Branch `v2` descends from `main` commit `659163b`. | Done |
| 9 | Edit the existing implementation in place, not under `v2/`. | Production sources replaced in `src/`; no `src/v2` or parallel engine tree exists. | Done |
| 10 | Finish v2, compare internally, and leave the public benchmark for handoff. | Internal comparison and release gates completed first; the later publication pass ran the expanded public suite separately. | Done |

## Progress by plan step

### 1. Authenticated bounded control plane — done

**Files:** `src/internal/format.zig`, `src/internal/engine.zig`,
`src/internal/checksum.zig`

Implemented the 64 KiB control region, authenticated empty generation, four
rotating roots, predecessor identity, fixed root election, fail-closed invalid
root handling, explicit persistent integer widths, and reserved-byte checks.

### 2. Immutable columnar pages — done

**Files:** `src/internal/page.zig`, `tests/format_v7_test.zig`

Implemented independently encoded timestamp/value columns, raw, base-step,
delta-varint, and XOR-varint modes, bounded restart groups, deterministic page
bytes, summaries, external identities, checksums, and semantic validation.

### 3. Persistent per-series indexes and manifests — done

**Files:** `src/internal/index.zig`, `src/internal/manifest.zig`

Implemented append-specialized copy-on-write trees, fixed maximum height,
right-spine publication, subtree summaries, immutable manifests, and coalesced
multi-node index-level writes.

### 4. Bounded writer data plane — done

**Files:** `src/internal/engine.zig`, `src/chronotail.zig`

Implemented whole-batch validation, caller-declared capacity, allocation-free
prepared append, deterministic page construction, writer poisoning, and
memory-versus-disk durability publication.

### 5. Bounded reader data plane — done

**Files:** `src/internal/engine.zig`, `src/chronotail.zig`

Implemented mapped immutable snapshots, fixed verification cache, prepared
series, bulk raw-column copies, count-only reads, persistent cursors, borrowed
raw pages, summary aggregates, and one-walk resolution windows.

### 6. Recovery and durability — done

**Files:** `src/internal/engine.zig`, `sim/main.zig`

Implemented objects-sync-root-sync disk publication, bounded recovery, older
root fallback, generation succession, and independent authentication. The
simulator found and drove the fix for unsafe generic-storage verification-cache
reuse after corruption; generic storage now reauthenticates every returned
object while immutable production file mappings retain the cache.

### 7. Compatibility, migration, and public APIs — done

**Files:** `src/internal/v6_reader.zig`, `src/c_api.zig`, `src/cli.zig`,
`include/chronotail.h`, `python/src/chronotail/__init__.py`

Implemented explicit v6 recognition and verified separate-file migration, C ABI
v2 with 18 symbols, Python 2.0 writer preparation and aggregates, and the
`migrate-v6` CLI. V1 binary ABI compatibility is not claimed; original C
operation names remain source-level conveniences.

### 8. Correctness tests and deterministic simulation — done

**Files:** `tests/engine_test.zig`, `tests/format_v7_test.zig`,
`tests/migration_test.zig`, `sim/main.zig`

Added deterministic bytes, malformed and checksummed-but-invalid structures,
multi-page aggregate windows, integer-overflow boundaries, raw/compressed v6
migration, and recovery cases. The final campaign passed 1,000 seeds and
100,000,000 operations with zero invariant failures.

### 9. Internal performance feedback loop — done

**Files:** `tests/performance/main.zig`, `tests/performance/compare.py`,
`tests/performance/README.md`, `docs/performance/internal-profile.md`

Captured the pre-change v1 baseline, implemented the full matrix before engine
work, repeated all 179 candidate workloads three times, proved zero allocation
activity across eight measured steady-state paths, kept intermediate/rejected
runs ignored, and documented both gains and regressions.

### 10. Documentation and release handoff — done

**Files:** README, documentation index, getting-started, architecture,
durability, migration, API, security, contributing, release notes, design,
optimization, performance, plan-status, and historical banners.

Updated current Chronotail behavior without creating parallel versioned docs or
overwriting the v1 benchmark record and machine-model analysis. Internal links,
release metadata, examples, bindings, and architecture assets were validated.

## Accepted implementation differences

These are deliberate, documented choices rather than incomplete work:

- Codecs are bounded delta-varint and XOR-varint, not claims of complete
  delta-of-delta or Gorilla compatibility.
- Reader refresh remaps the complete committed snapshot and invalidates prior
  handles/views; safe cross-refresh borrowing needs pinned snapshots and
  reclamation.
- Logical data pages are still written independently. Multi-node index writes
  are coalesced; physical data-page coalescing remains a measured optimization.

## Removal specification status

### Completed removals

- The format-v6 production writer/reader kernel was removed from
  `src/internal/engine.zig` and `src/internal/format.zig`.
- `tests/format_v6_test.zig` was replaced by `tests/format_v7_test.zig`.
- No alternate `src/v2` directory or duplicate production implementation
  remains.
- V6 parsing survives only in `src/internal/v6_reader.zig`, migration tests,
  compatibility messages, and preserved historical documentation.
- No runtime dispatch layer or third-party production runtime dependency was
  introduced.

### Pending removals

None.

## Quality assessment

### Passed

- Persistent widths, offsets, bounds, tree heights, restart intervals, and
  caller capacities are explicit.
- Prepared append and query data planes are allocation-free in the measured
  regions.
- Checksums, BLAKE3 identities, semantic validation, durability order, and
  simulator invariants were not weakened.
- Production and simulated engines share compile-time-specialized logic.
- The implementation stays dependency-free and macOS ARM64 remains the declared
  validation target.
- Performance regressions and discarded experiments are recorded rather than
  hidden.

### Issues found

None blocking completion. Measured optimization targets remain in
`docs/performance/optimization-roadmap.md`; they are follow-on performance work,
not missing v2 requirements.

## Files changed

### Planned implementation

- Build/version: `build.zig`, `build.zig.zon`.
- Engine: `src/chronotail.zig`, `src/internal/{checksum,engine,format,index,manifest,page,v6_reader}.zig`.
- Interfaces: `src/c_api.zig`, `src/cli.zig`, `include/chronotail.h`,
  `python/pyproject.toml`, `python/src/chronotail/__init__.py`.
- Verification: `sim/main.zig`, `tests/{engine,format_v7,main,migration}_test.zig`,
  and the complete `tests/performance/` suite.

### Necessary supporting changes

- `scripts/check-release.py` and `scripts/smoke-release.sh` were updated for
  format v7/ABI v2 release validation.
- README, contributor/security/release guidance, API/architecture docs, rendered
  architecture assets, and historical-document banners were synchronized.
- `tests/performance/compare.py` distinguishes each damaged-tail size and
  handles candidate-only APIs.

No unrelated product feature or production dependency was added.

## Validation status

| Gate | Result |
|---|---|
| `zig fmt --check build.zig src sim tests tools bench` | Pass |
| `zig build test` | Pass |
| `zig build test -Doptimize=ReleaseSafe` | Pass |
| `zig build test -Doptimize=ReleaseFast` | Pass |
| `zig build -Doptimize=ReleaseFast` | Pass |
| C header with `-Wall -Wextra -Werror` | Pass |
| C ABI link/runtime smoke | Pass |
| Exported ABI surface | Pass, exactly 18 expected `ct_*` symbols |
| Python compile and live format-v7 round trip | Pass |
| `scripts/check-release.py` | Pass |
| Isolated release archive smoke | Pass |
| Markdown internal-link validation | Pass, 42/42 local links |
| Internal profile | Pass, 179 workloads × 3 repetitions |
| Allocation profile | Pass, 24/24 rows with zero allocator activity |
| Extended simulator | Pass, 1,000 seeds/100,000,000 operations/0 failures |
| Public competitive benchmark | Pass, 99 groups × 5 repetitions = 495 measurements |

## Remaining work

No required implementation or evidence work remains. Optional optimizations are
separately ranked with predicted from/to metrics and must repeat the same
correctness and internal-profile gates if pursued.
