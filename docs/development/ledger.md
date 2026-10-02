# Development ledger

Record a hypothesis, measured evidence, and disposition per experiment. Link
raw artifacts; separate supported native evidence from Linux development data.
Rejected changes remain visible. Never replace a failing/noisy run with a win.

## 2026-10-02 — development environment

Goal: reproducible autonomous maintenance with local/CI parity, specialized
review, resource validation, and deterministic fault campaigns.

Initial local Debug run exposed an interleaved-point range failure in generic
storage: `rawTimestamps()` required alignment although copied results should not.
The fix retains aligned bulk copies and falls back to existing allocation-free
byte-reading cursors for unaligned scratch. Borrowed views keep their alignment
restriction; persistent bytes and validation are unchanged.

New infrastructure evidence will be attached to the setup PR. Performance
numbers from this shared Linux VM are diagnostics, not published competitor
claims. Format v7/C ABI v2 and the macOS ARM64 release boundary remain in force.

Internal tests were absent from `zig build test`. Wiring them in revealed a
stale index-depth expectation: a full parent receiving a split leaf must grow
to depth three. The corrected test now covers both a parent with space and a
full parent; production index construction is unchanged.

Independent review also caught checkout-library leakage into release smoke,
mutable-source/mismatched-input profiling, and ambient simulator-budget
overrides. The setup now isolates the wheel loader, freezes both profiled
commits and the harness contract, and fixes full/release campaigns at 100M
operations. The owner chose reviewed CI merges without branch rules or
Conductor routines; the remaining observation-to-merge race is disclosed.

An interrupted full profile was retained locally as incomplete evidence; the
validator rejected it. It is not a timing or completeness claim. Final complete
validation and native GitHub CI results are recorded on the setup PR.
