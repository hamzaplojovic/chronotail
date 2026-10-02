# Development and autonomous maintenance

The engine remains synchronous, embedded, and dependency-free. Development
automation lives outside production paths. Repository instructions and skills
are shared across workspaces; no personal shell setup or persistent cloud VM is
required.

## Reproduce the environment

Install Python 3.9+, a C/C++ compiler, Git, tar, and xz. Linux cloud machines can
use `sudo dnf install -y gcc gcc-c++ clang`; GitHub runners already provide them.
Run `./scripts/setup-dev.sh` (it installs the C toolchain on a fresh Amazon
Linux cloud workspace). Zig and Go are pinned by SHA-256 in
`scripts/dev/toolchains.json` and installed under ignored `.tools/`.

| Command | Purpose |
|---|---|
| `./scripts/dev.sh quick` | Hygiene, Debug, clients, ten seeds, quick resource matrix |
| `./scripts/dev.sh full` | Three test modes, clients, 1,000 seeds/100M operations, full profile |
| `./scripts/dev.sh simulate` | 100 deterministic seeds; override CHRONOTAIL_SIM_SEED/SEEDS/OPERATIONS |
| `./scripts/dev.sh profile full` | Three-pass internal resource matrix and zero-allocation validation |
| `python3 scripts/profile-pair.py origin/main` | Alternating baseline/candidate quick matrices on one host |
| `./scripts/dev.sh release` | Native macOS ARM64 full gates and isolated artifact smoke |

Local tools are selected automatically by `dev.sh`. For standalone commands,
`source scripts/dev-env.sh`. Conductor setup and run buttons call these same
commands. Linux is a development/testing host, not a newly supported release.

## Continuous checks

- CI runs on every PR and main push: formatting, local documentation links,
  release metadata/checksums, developer-tool tests, all three Zig modes on Linux
  and native macOS, C/Python/Go clients, simulation, allocation checks, and native
  release bundle smoke tests. `Required CI` aggregates every required job.
- Endurance runs nightly: 1,000 deterministic seeds/100M operations per host and
  the full native resource profile. Each run advances the seed range; exact
  seed/operation settings are saved for reproduction. Logs, raw JSONL, and host/source metadata
  are uploaded even on failure. Failures must be reproduced before optimization.
- Release validation checks tags against source and finalized release notes,
  runs full native gates, and uploads checksummed candidates. A validated version
  tag also publishes the matching GitHub release with notes and native bundles.
  Manual dispatch builds candidates without publishing a release.
- Hosted timing measurements are diagnostic. Allocation invariants and evidence
  completeness are hard gates; unstable timing thresholds are not.

This project uses the merge helper and review discipline without provisioning
branch-protection rules. It rechecks the reviewed head/base and CI immediately
before merging. GitHub atomically checks the head SHA; there is still a narrow
race if CI or the base changes after the final observation. This is the owner's
chosen lightweight workflow, not a claim of server-enforced CI protection.

## Specialist agents and skills

Codex project agents live in `.codex/agents`; skills live in `.agents/skills`.
Model/effort settings inherit the running session. Agent configuration does not
grant credentials or merge permissions. Conductor sessions can use the same
roles via their instruction files when native custom agents are unavailable.

- Correctness reviewer: ordering, bounds, authentication, recovery, lifetimes.
- Resource reviewer: CPU work, allocation, write amplification, fair experiments.
- Fault investigator: failing seeds, minimal regressions, smallest fixes.
- Client reviewer: ABI, loaders, caller buffers, artifact-only usability.
- Release strategist: independent challenge of domain value and release scope.

Use independent reviewers and disjoint implementation ownership. Debate must
end in evidence or a decisive experiment; multiple agents agreeing is not proof.
Do not run timing experiments concurrently on the same host.

## Autonomous work loop

1. Inspect failed CI/endurance runs, open PRs, and the development ledger.
2. Reproduce the smallest failure; otherwise choose one measured bottleneck or
   one capability contract from the proposed 3.0 plan.
3. Write the hypothesis/invariant and acceptance command before editing.
4. Implement one small concern; run matching gates and retain raw evidence.
5. Request independent correctness and, where relevant, resource/client review.
6. Open a PR. An authorized merge uses `scripts/merge-pr.py PR --review FILE
   --execute` only after `Required CI` is green at the reviewed head SHA.
7. Record outcome, rejected variants, and the next evidence-driven step.

Review JSON contains `reviewed_sha`, nonempty `reviewers`, and
`blocking_findings: []`. These are process records, not cryptographic proof of
independence. Never bypass checks,
manufacture review evidence, or self-approve a change.

Agents work during active sessions. GitHub runs CI and nightly endurance without
an active agent. No Conductor routine or webhook is needed. Continue from the
ledger and actual CI evidence in the next active session; do not claim resident
24/7 agent execution when no session is running.

## Complete a public release

Finalize notes and version metadata in a scoped release PR, with updated public
docs and compatibility evidence. After its reviewed merge, create the matching
annotated version tag at that merge commit and push it. The tag workflow reruns
full native validation and publishes the GitHub release with checksummed bundles
and the version's notes. Verify workflow success, release assets, and the tag's
commit before reporting shipment. A failed publish is unfinished work; retry
the failed workflow after fixing its cause. Never overwrite an existing release
with different bytes. Routine maintenance PRs do not tag or publish releases.

## Evidence and next release

See [the ledger](ledger.md) and [workload map](workloads.md). Prioritize actual
failures and unexplained resource regressions. The 3.0 proposal is a hypothesis
set, not shipped functionality or permission to claim format-v8 compatibility.
Persistent-layout changes get a documented design and separate-file migration.
