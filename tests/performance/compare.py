#!/usr/bin/env python3
"""Compare two Chronotail internal performance JSONL runs."""

from __future__ import annotations

import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path


def load(path: Path) -> dict[tuple, list[dict]]:
    groups: dict[tuple, list[dict]] = defaultdict(list)
    with path.open() as source:
        for line in source:
            row = json.loads(line)
            if row.get("type") != "result":
                continue
            key = (
                row["group"],
                row["name"],
                row["codec"],
                row["timestamp_pattern"],
                row["value_pattern"],
                row["series_count"],
                row["batch_size"],
                row["width"],
            )
            groups[key].append(row)
    return groups


def median(rows: list[dict], field: str) -> float:
    return statistics.median(row[field] for row in rows)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: compare.py BASELINE.jsonl CANDIDATE.jsonl")
    baseline = load(Path(sys.argv[1]))
    candidate = load(Path(sys.argv[2]))
    print("| Workload | Baseline | Candidate | Change |")
    print("|---|---:|---:|---:|")
    for key in sorted(baseline.keys() & candidate.keys()):
        before_rows = baseline[key]
        after_rows = candidate[key]
        rate_field = "points_per_second"
        before = median(before_rows, rate_field)
        after = median(after_rows, rate_field)
        if before == 0 or after == 0:
            rate_field = "operations_per_second"
            before = median(before_rows, rate_field)
            after = median(after_rows, rate_field)
        if before == 0 or after == 0:
            rate_field = "p50_ns"
            before = median(before_rows, rate_field)
            after = median(after_rows, rate_field)
            change = (before / after - 1) * 100 if after else 0
        else:
            change = (after / before - 1) * 100
        label = "/".join(str(part) for part in key if part not in (0, "none"))
        print(f"| {label} | {before:.3f} | {after:.3f} | {change:+.2f}% |")


if __name__ == "__main__":
    main()
