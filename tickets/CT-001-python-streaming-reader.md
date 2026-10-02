# CT-001: Bounded Python streaming reads

Status: in progress
Role: engineer
Owner: Conductor session `eab00ee5-abfd-4bb4-9953-eccf68cf0574`
Release track: additive client capability on the v2/format-v7 line

## Problem

Python Reader.range materializes all selected points and repeats the native range
call after learning that the initial buffer is too small. Applications need a
bounded streaming option for large histories, early termination, and controlled memory.

## Ownership and implementation

Own only clients/python/src/chronotail/__init__.py,
clients/python/tests/test_client.py, clients/python/README.md,
docs/clients/python.md (manager expansion), and this ticket.
Implement an additive Reader.iter_range API using the existing C ABI v2 stateful
cursor functions. Preserve Reader.range behavior and return shape. Bound native
buffers by an explicit positive batch_size with a sensible default; do not allocate
proportional to total history. Destroy cursor state in a finally block, including
early generator close and native failure. Reader close/refresh must reject stale
iteration rather than use invalid native state. Use existing ABI symbols/layouts;
no C, Go, engine, or persistent-format changes belong to this ticket.

## Acceptance

Document inclusive bounds, empty/reversed ranges, missing series, batch size,
snapshot/refresh lifetime, iterator close, and exact timestamp/value behavior.
Test multiple batches across pages, batch sizes 1 and a larger non-page multiple,
early close, reader close/refresh during iteration, native failure cleanup, invalid
batch sizes, i64 boundaries, and agreement with existing range. Avoid tests that
merely mirror the implementation. Run focused client checks only when the manager
has confirmed the native build and host slot. Source work and lightweight tests may
start immediately. Record commands/results and limitations; independent client review
is required before integration. No commits, branch changes, PRs, or publication.

## Evidence

Source implementation and integration regressions prepared in the owned Python
files. `Reader.range` stays unchanged. Iteration captures a Python snapshot epoch
at creation, allocates two fixed batch buffers only on first advance, uses the
existing ABI v2 stateful cursor, checks lifetime before each buffered yield, and
destroys native state in `finally`. Changed refresh invalidates iterators; failed
and unchanged refresh preserve them.

Manager source review found that v2.0.0 shares C ABI v2 but lacks stateful cursor
symbols. Stateful bindings are now optional and require all three symbols.
Existing reader/writer APIs retain import and operation availability with that
exact old symbol set. `iter_range` raises clear `NotImplementedError` at call
time if any required cursor symbol is missing, before buffers/cursor allocation;
there is no rescanning fallback. Independent client review must include this fix.

Coverage includes both codecs, 9,000 points crossing format-v7 pages, batch sizes
1 and 1,379, agreement with `range`, empty/reversed/missing queries, exact i64 and
binary64 edges, explicit early close, stale started/unstarted iterators,
injected cursor-create/advance errors, and input validation before native calls.

Pure Python checks passed: syntax compilation of both owned Python modules;
three unittests with a stubbed library loader (input validation, exact old ABI-v2
symbol import/existing-operation compatibility, and each incomplete stateful
capability; no native library loaded); documentation links across 56 Markdown
files; and scoped
`git diff --check`. Manager expanded ownership to docs/clients/python.md for
next-release streaming documentation; the guide and README now distinguish the
development API from the frozen 2.1.0 wheel. Native checks await manager's ABI-v2
build/focused Python run after CT-002 releases the exclusive host slot.
Independent client review by CT-002's engineer follows that validation.
Progress, commands, and limitations are recorded in
`.context/CT-001-progress.md`. This targets the next additive release; the frozen
v2.1 release candidate is untouched. The manager makes the final done decision.
No builds, installs, commits, branch changes, PRs, or publication performed by
this engineer.

Manager expanded client-guide ownership and requested independent read-only
CT-002 correctness review. CT-002 currently holds the local validation slot;
Python native integration follows its release. Frozen 2.1.0 worktree is unaffected.
