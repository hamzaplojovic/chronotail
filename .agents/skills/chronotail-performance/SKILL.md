---
name: chronotail-performance
description: Profile Chronotail resource costs and run matched experiments without weakening correctness or the pinned public methodology.
---

Read AGENTS.md, tests/performance/README.md, and the affected experiment ledger.
Use the current source as baseline. Freeze workload identities and timing
boundaries before edits. Profile the largest measured cost; propose the work
an invariant makes removable. Keep one independently reversible hypothesis.

Run scripts/dev.sh profile quick/full; validate with scripts/check-profile.py.
For comparisons use scripts/profile-pair.py BASE_REF, on an otherwise idle
machine. It alternates baseline/candidate on one host. Inspect min/max and
individual regressions, not just aggregate medians. Hosted-runner timings are
diagnostic, not stable acceptance thresholds or public competitive evidence.

Track allocations, resident versus mapped memory, bytes stored/written, decode
work, syscalls, and checkpoint cadence alongside throughput. Use tools/profile.sh
when native profiling permissions permit; never represent a fallback run as CPU
counter evidence. Record rejected experiments. Publish competitor claims only
through the pinned competitive runner and its explicit publication step.
