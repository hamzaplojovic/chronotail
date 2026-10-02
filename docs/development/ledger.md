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

Completed evidence for [PR #5](https://github.com/hamzaplojovic/chronotail/pull/5):
all 39 Zig tests passed in Debug, ReleaseSafe, and ReleaseFast; C/Python/Go
clients passed, including Go race detection. The forced full simulator campaign
(`CHRONOTAIL_SIM_SEED=1 CHRONOTAIL_SIM_SEEDS=1000
CHRONOTAIL_SIM_OPERATIONS=100000 ./scripts/dev.sh simulate`) completed 100M
operations with 1,934 crashes, 1,876 short writes, 1,877 failed writes, 5,970
truncations, 5,961 corruptions, and zero invariant failures. Its seed
configuration and raw log are retained in `.dev-results/`.

At `85f68cc42b24c5ff39555092cdc959a79bea6ee3`,
`./scripts/dev.sh profile full` completed all three passes: 564 results across
188 workload identities and 24 allocation measurements. The strict validator
accepted the complete matrix. Native macOS ARM64 artifact smoke and every
GitHub CI job passed at that commit. These are correctness/resource-gate
results, not evidence of a speedup or a new release platform.

Review also exposed workload substitution that preserved family totals, and
literal Markdown comment text masking later links. The gates now require exact
workload identities and distinguish inline code from comments; failing
synthetic cases are retained as developer-tool regressions. The next step is
to choose a frozen 3.0 capability contract or measured bottleneck, rather than
infer an optimization win from successful infrastructure checks.
