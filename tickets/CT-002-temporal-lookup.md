# CT-002: Temporal lookup contract and additive Zig API

Status: in progress
Role: engineer
Owner: Conductor session `0b33d792-6161-42e5-b889-677f3467e627`
Release track: v2 additive API first; foundation for the 3.0 temporal capability

## Problem

Applications can read exact ranges but lack a direct bounded answer to the last,
next, or nearest stored sample around a timestamp. Implementing that in clients
materializes or scans history and risks inconsistent tie/missing semantics.

## Ownership and implementation

Own only src/internal/engine.zig, src/chronotail.zig, docs/temporal-lookup.md,
and this ticket. Put initial contract/approach notes in .context/CT-002-plan.md.
Read the 3.0 proposal and existing reader/index/page invariants. Specify and
implement additive named/prepared Zig lookup entry points returning ?Point for
exact, predecessor (at or before), successor (at or after), and nearest modes.
Nearest ties choose the predecessor. Optional maximum distance is an inclusive
unsigned timestamp distance; compute safely across the full i64 domain. Missing
is null, not zero; unknown series and stale handles retain existing errors.
Use authenticated index/page traversal and existing bounded scratch/cursors;
no full-history scan/materialization, allocation after open, format, ABI, writer,
checksum, recovery, or borrowed-view change. Do not edit page.zig, index.zig,
clients, build wiring, or another engineer's files. Ask the manager for an internal
ownership adjustment if a necessary helper lies outside the assigned files.

Freeze the contract in the ticket/doc before implementation; the manager will
review it while you inspect the implementation. Proceed with independent source
work; send contract decisions for manager review before finalizing public names.

## Acceptance

Use a simple independent sorted-list reference to cover all modes, tolerance
boundaries, ties, absent results, i64 min/max, sparse/irregular timestamps, first/last
and cross-page/index boundaries, raw/compressed encodings, prepared/name parity,
stale refresh handles, and generic unaligned storage. Retain structural validation
and allocation-free prepared paths. Engine tests in all three modes and deterministic
simulation must be scheduled exclusively by the manager; do not start them on your
own. Deliver a complete scoped implementation/tests/docs and exact validation needs.
Independent correctness/resource review precedes integration. No commits, branch
changes, PRs, or publication.

## Evidence

Contract frozen before implementation in [temporal lookup](../docs/temporal-lookup.md)
and `.context/CT-002-plan.md`; manager approved public names and semantics:
`LookupMode`, `Reader.lookup`, and `Reader.lookupPrepared`. Both return `!?Point`
and take `(name/handle, timestamp: i64, mode: LookupMode, max_distance: ?u64)`.
Inclusive direction/tolerance semantics, predecessor ties, full-domain unsigned
distance, existing missing/name/stale errors and snapshot behavior are fixed.
Scoped implementation and five sorted-list reference/regression tests are written.
Owned Zig formatting, `python3 scripts/check-docs.py` (56 Markdown files), and
`git diff --check` pass. Final Debug, ReleaseSafe and ReleaseFast each passed;
deterministic simulation (seed 1, 100 seeds, 100,000 operations per seed) passed
10,000,000 operations with zero invariant failures. Exclusive local host slot
released. Exact logs/configuration/source-stability hashes are in
`.context/CT-002-validation.json` and coverage in `.context/CT-002-handoff.md`.
An authenticated cached-page edge regression failed before the scoped lookup
fix and passed after it; both logs are retained. Independent correctness/resource
source review at matching final hashes reports no blocking findings in
`.context/CT-001-review-CT002.json` (source only, no runtime certification). The manager
tracks old shared-helper exposure separately as CT-008 and retains the final
done decision.
