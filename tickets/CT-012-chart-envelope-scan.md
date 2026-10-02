# CT-012: Implement the frozen bounded chart-envelope scan

Status: in progress (production source; native gates and independent reviews pending)
Role: engineer with independent correctness/resource review
Owner: CT-002/005 engineer session `0b33d792-6161-42e5-b889-677f3467e627` for production;
CT-001 engineer `eab00ee5-abfd-4bb4-9953-eccf68cf0574` retains planning evidence
Depends on: CT-006, CT-008; schedule after planned 2.2 scope
Release track: later additive Zig capability, format v7

## Outcome and scope

Implement the CT-006 v2 caller-buffer contract in docs/chart-envelope.md:
original first/minimum/maximum/last sample identities per ordered inclusive
bucket, deterministic ties/dedup, exact bits, missing and discontinuity metadata.
An excluded interval breaks connectivity but does not prove a data gap.
No interpolation, fabricated boundary values, persistent summaries or ABI change.

## Acceptance

Use the independent materialized oracle against bounded native traversal on
raw/compressed mapped/generic storage, full-i64 bounds, restarts/index children,
spikes, earliest ties, NaN payloads/signed zero/infinities and empty buckets.
Prove capacity errors leave output untouched and perform no history reads;
resolve missing/stale handles first. Carry bounded scalar/bucket/index/page
state, with no allocation after open or history-sized containers. Preserve
checksums/structural edge validation and borrowed-view lifetimes. Keep one
chronological selection traversal; account separately for first-touch validation,
selection decodes and revisits. Do not wrap a recounting generic cursor and
claim a single scan. All modes/simulation and independent exact-commit reviews
precede integration; exclusive host grants are required for native work.

## Evidence and scheduling

CT-006 manager review accepts the design/reference stage only; thirteen pure
Python tests include 3906 exhaustive small histories and excluded-history
invariance. Production source is authorized in `.context/chart-envelope` at base `7ddd7aca8183d6dc77a592c31be70663bac86d80`; native execution remains ungranted. CT-011 temporal/
streaming parity release takes priority; no benchmark or optimization is authorized
by this ticket.

Root product directive authorizes decomposition/acceptance preparation now,
with production starting only after planned 2.2 scope integration and explicit
coordinator ownership/host scheduling. CT-006 contract/doc/ticket remain frozen.
Implementation slices and fixed candidate/prefix-event state, source/resource
constraints and native acceptance matrix are in root `.context/CT-012-plan.md`.
Oracle-derived preparation fixtures cover 1,200 buckets and targeted exceptional
values/coverage/full-i64 cases; exact frozen authority and artifact hashes are in
`.context/CT-012-preparation.json`. These do not attest a native scan, allocation
behavior, performance, codec placement, integration or shipment.

## Production assignment

Coordinator authorized source-only production after CT-001/002/005 integration.
Own only engine/facade, byte-identical frozen chart doc, this parked ticket and new
CT-012 author artifacts. No shared helper/page/index/codec/ABI edits. Concrete
implementation and acceptance matrix: `.context/CT-012-author-plan.md`.

## Author source and validation handoff

Implementation and eight native engine tests are complete in the assigned
chart worktree, with engine SHA256
`03c6b6eec751186b2821e4518467241e8d7661042a8913b2451d4ee3edfdd90d`.
Final Debug/ReleaseSafe/ReleaseFast passed. Explicit deterministic seed1/seeds100/
operations100000 completed 10M operations with zero invariant failures. Source
before/running/after receipts and raw logs are in root
`.context/CT-012-author-validation.json`; two initial test-oracle compile failures
remain preserved. Local slot released; no further heavy work authorized/needed.
Independent correctness and resource source reviews have no blockers at exact
final source; manager final done/integration and exact-commit review remain pending.
No commit/branch/publication/platform/ABI/format changes. The release2.2 candidate
is untouched. `selection_records` means logical cursor-returned pairs, excludes
eager codec successor prefetch and makes no exact scalar decoded-work/RSS/timing
claim; see author handoff and retained resource counter observation.
