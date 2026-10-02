---
name: chronotail-maintain
description: Maintain Chronotail through reproducible local/CI gates, scoped PRs, independent review, and the development ledger.
---

Read AGENTS.md and docs/development/maintenance.md. Inspect git status, current
CI/endurance failures, and the ledger before choosing work. Establish whether
the task authorizes commits, GitHub writes, and merging; this skill does not
grant authorization. Start from a reproduced failure or measured hypothesis.

Use python3 scripts/setup-dev.py and scripts/dev.sh. Assign disjoint edits to
fault/client agents; request independent correctness/resource review as needed.
Keep timing runs sequential. Record the commit, exact command, failing seed or
workload, result, and next step. Preserve raw evidence in .dev-results or GitHub
artifacts. Create one reviewable PR per concern. If merging is authorized, use
scripts/merge-pr.py with independent review evidence; a CI failure stops merge.

When an external permission blocks a step, finish independent local work and
report that exact capability. Do not turn missing access into fabricated
completion or bypass repository policy. Secrets never enter logs or commits.
