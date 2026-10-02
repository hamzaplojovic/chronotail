# CT-005: Temporal lookup across C, Go, and Python

Status: in progress (frozen contract; source implementation, native checks/review pending)
Role: engineer
Owner: CT-002 engineer, Conductor session `0b33d792-6161-42e5-b889-677f3467e627`
Depends on: CT-002
Release track: 2.2 additive API

## Scope

Expose the frozen CT-002 temporal contract consistently through additive C ABI v2
symbols and Go/Python wrappers without changing existing symbols or layouts.
Define explicit missing results, full-i64/tolerance semantics, caller ownership,
error translation, stale lifetimes, and exact timestamp/value conversion.
Coordinator assigned exclusive client/ABI ownership after freezing CT-001.

## Acceptance

Native ABI/client contract tests and installed-artifact smoke validate all modes,
missing/ties/overflow/tolerance and snapshot lifetimes. Docs/examples describe a
real last-known-value workflow and parity limits. Independent client/correctness
review and native validation precede the new release. Preserve format v7.

## Evidence

Manager-frozen contract: [temporal lookup clients](../docs/temporal-lookup-clients.md).
Add `ct_lookup`/`ct_lookup_prepared` in C ABI v2 using existing `ct_point` and
`ct_series_handle` layouts, explicit mode/limit tags and found output. No new
status codes or existing-symbol changes. Go/Python named/prepared wrappers
preserve CT-002 semantics and copied exact point bits.

Design records output initialization, null/error behavior, full-domain distance,
unknown/stale/closed/wrong handles, optional Python capability detection, Go link
requirements, old-symbol compatibility limits and validation/artifact plan.
Implementation worktree: `.context/temporal-clients`, branch
`feature/temporal-clients`, assigned base
`568b9358a3e7f373abcc9ac4870e3cdcd9f7ec4c`. Coordinator reconciled original
feature source against main, retained the merged CT-008 guard/test tail and
froze all four CT-001 files before this client delta. No core edits by CT-005.

Named/prepared C/Go/Python source and consumers are implemented. Tests use an
independent sorted-list model with min/max timestamps, full-u64/inclusive
tolerance, ties, exact bits, absent/error distinctions, named/prepared parity,
raw/compressed data, 44 committed pages and stale/closed/wrong-owner checks.
Python pure compatibility tests cover the optional lookup pair crossed with
every cursor-triple presence mask, the exact old 18-symbol set, lifetimes and
noninspection of missing/error output. Existing CT-001 streaming source/tests
are preserved. Installed smoke exercises last-known pressure plus bounded
20,000-point Python history, and C/C++/Go native parity.

Pure-stub and docs/fmt checks are allowed; native/Go/client builds, integration,
simulation and timings require an exclusive coordinator slot. Actual old native
compatibility is a separate required artifact gate, not certified by stubs.
Independent client reviewer: `eab00ee5-abfd-4bb4-9953-eccf68cf0574`; ABI/resource
reviewer: `41e3b930-5050-4b33-b081-ab75f1b69aa1`. Keep in progress until exact
source review and manager-owned validation/disposition. No commit/branch change,
push, PR or publication by author. Release 2.1 publication precedes integration.
