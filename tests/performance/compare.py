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


METRICS = (
    ("points_per_second", True),
    ("operations_per_second", True),
    ("p50_ns", False),
    ("bytes_per_point", False),
    ("detail_b", False),
    ("file_size", False),
    ("allocated_bytes", False),
    ("allocation_calls", False),
    ("elapsed_ns", False),
)


def metric(rows: list[dict]) -> tuple[str, float, bool]:
    """Return (field, median, higher_is_better) for one workload."""
    for field, higher_is_better in METRICS:
        value = median(rows, field)
        if value != 0:
            return field, value, higher_is_better
    return "zero", 0.0, True


def paired_metric(
    before_rows: list[dict], after_rows: list[dict]
) -> tuple[str, float, float, bool]:
    """Select the first meaningful field even when one side improved to zero."""
    for field, higher_is_better in METRICS:
        before = median(before_rows, field)
        after = median(after_rows, field)
        if before != 0 or after != 0:
            return field, before, after, higher_is_better
    return "zero", 0.0, 0.0, True


def label(key: tuple) -> str:
    return "/".join(str(part) for part in key if part not in (0, "none"))


def print_unmatched(title: str, keys: set[tuple], groups: dict[tuple, list[dict]]) -> None:
    if not keys:
        return
    print(f"\n## {title}\n")
    print("| Workload | Metric | Value |")
    print("|---|---|---:|")
    for key in sorted(keys):
        field, value, _ = metric(groups[key])
        print(f"| {label(key)} | {field} | {value:.3f} |")


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: compare.py BASELINE.jsonl CANDIDATE.jsonl")
    baseline = load(Path(sys.argv[1]))
    candidate = load(Path(sys.argv[2]))
    print("| Workload | Metric | Baseline | Candidate | Improvement |")
    print("|---|---|---:|---:|---:|")
    for key in sorted(baseline.keys() & candidate.keys()):
        before_rows = baseline[key]
        after_rows = candidate[key]
        field, before, after, higher_is_better = paired_metric(before_rows, after_rows)
        if before == 0:
            change = 0.0 if after == 0 else float("inf")
        elif after == 0:
            change = float("inf") if not higher_is_better else -100.0
        elif higher_is_better:
            change = (after / before - 1) * 100
        else:
            change = (before / after - 1) * 100
        print(f"| {label(key)} | {field} | {before:.3f} | {after:.3f} | {change:+.2f}% |")

    print_unmatched("Candidate-only workloads", candidate.keys() - baseline.keys(), candidate)
    print_unmatched("Baseline-only workloads", baseline.keys() - candidate.keys(), baseline)


if __name__ == "__main__":
    main()
