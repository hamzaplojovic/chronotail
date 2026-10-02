---
name: chronotail-correctness
description: Review or investigate Chronotail persistent-format, recovery, ordering, snapshot ownership, and ABI invariants.
---

Read AGENTS.md, docs/durability.md, and the affected implementation. Track
pointer identity AND structural validity separately. Check file/width-derived
bounds, strict ordering, summary consistency, batch admission, poison states,
root succession/fallback, sync ordering, and borrowed-view lifetimes.

Run all three test modes and deterministic simulation for engine changes.
Preserve failing seeds; reproduce with explicit --seed and --operations.
Use forged-valid-checksum semantic cases when corruption validation changes.
Generic simulated bytes may mutate: immutable production verification-cache
assumptions cannot be applied to that storage. Interleaved/copy reads must not
inherit alignment requirements that belong only to borrowed raw views.

Report each blocking finding as trigger, file/line, violated invariant, and
minimal reproducer. Separate proven failures from hypotheses and untested paths.
