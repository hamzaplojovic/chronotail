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

## 2026-10-02 — maintenance release gates and cached edges

The first 2.1 candidate native workflow stopped in documentation fixtures:
macOS resolves `/tmp` through `/private/tmp`, but the test root was not
canonicalized. [PR #6](https://github.com/hamzaplojovic/chronotail/pull/6)
resolves that fixture root without changing checker behavior. Independent
exact-head review and all Required CI jobs passed before its reviewed-head
merge at `630c43c9d4b57a562c4fc55c0151a9e9fc0b0c3f`.

The [next native candidate run](https://github.com/hamzaplojovic/chronotail/actions/runs/37065246113)
at `eeb8881f5029fc2c1b0134944b1ec15807a7503d` passed 72 developer-tool tests,
client checks and 1,000 simulator seeds/100M operations with zero invariant
failures, then stopped before profiling: macOS Bash rejected an empty argument
array under `set -u`. [PR #7](https://github.com/hamzaplojovic/chronotail/pull/7)
uses positional arguments and tests exact full/quick dispatch with a stub tool.
Independent review and all Required CI jobs passed before the reviewed-head
merge at `b9bcb74d7504d381bd23cc48752f852d831c2f2f`. The failed candidate
did not complete the profile or artifact gates and did not publish a release.

A separate authenticated immutable-file regression exposed mapped-page cache
hits returning by pointer identity without rechecking the selected parent
entry's series and summary. Cold reads rejected the conflicting entry, but
after warming another edge, range/cursor returned zero and partial aggregate
returned empty instead of `InvalidDatabase`. CT-008 tracks the smallest
cache-hit edge-validation correction and its independent review; publication
is held until that concern and full final-candidate native gates are resolved.
The fixture re-signs the index, manifest and newest root before opening a
mapped reader; no mutation of mapped bytes or catalog injection is required.

The retained compressed-reader investigation remains unresolved: report rows,
storage/allocation fields and operation counts reconcile, while six dense/smooth
copied-range throughput deficits of roughly 4–12% recur in the two quick
captures. Generated-code/layout differences are a hypothesis, not attribution.
The all-phase page intervention and identical-binary baseline self-control are
planned separately. No production optimization, speedup or universal
non-regression claim is supported by this stage. Additive Python streaming and
Zig lookup remain on the next-release branch, outside the frozen 2.1 candidate.
