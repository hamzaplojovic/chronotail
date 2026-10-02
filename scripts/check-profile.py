#!/usr/bin/env python3
"""Validate internal performance JSONL evidence without timing thresholds.

The format-1 result schema comes from tests/performance/main.zig. By default,
harness metadata and complete matrix/repetition evidence are required. Use
--allow-partial explicitly for exploratory structural and allocator checks.
Old metadata omits the selected phase: assume a full run, or use --only to
describe a historical phase run. New metadata may include only,
expected_results (total rows), and expected_workloads (distinct identities).
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path


STRING_FIELDS = ("group", "name", "codec", "timestamp_pattern", "value_pattern")
INTEGER_FIELDS = (
    "series_count", "batch_size", "width", "operations", "points", "elapsed_ns",
    "p50_ns", "p95_ns", "p99_ns", "max_ns", "file_size", "raw_blocks",
    "compressed_blocks", "allocation_calls", "resize_calls", "remap_calls",
    "free_calls", "allocated_bytes", "live_bytes", "peak_live_bytes",
    "detail_a", "detail_b",
)
FLOAT_FIELDS = ("operations_per_second", "points_per_second", "bytes_per_point")
ACTIVITY_FIELDS = (
    "allocation_calls", "resize_calls", "remap_calls", "free_calls", "allocated_bytes",
)
ALLOCATION_NAMES = (
    "append-after-create", "warm-query", "prepared-query", "persistent-cursor",
    "borrow-raw-page", "aggregate-summary", "aggregate-windows", "unchanged-refresh",
)
# Emissions per repetition, including widths which can collapse at small --points.
# Keep aligned with the format-1 harness, rather than the historical profile report.
PHASES = {
    "append": {("append", "batch"): 16, ("append", "pattern"): 12,
               ("append", "series-cardinality"): 5},
    "storage": {("storage", "encoding"): 24},
    "query": {("query-profile", "first-touch"): 8, ("query", "range"): 48,
              ("query", "range-count-only"): 8, ("query", "full-scan-count"): 8},
    "read-api": {("query", "cursor-full-range"): 8,
                 ("query", "range-into-count-only"): 2,
                 ("query", "text-full-range"): 2, ("query", "borrow-raw-page"): 1},
    "lookup": {("query", "series-lookup-point"): 5,
               ("query", "prepared-series-point"): 5},
    "aggregate": {("aggregate", "summary-tree"): 6,
                  ("aggregate", "resolution-windows"): 2},
    "checkpoint": {("checkpoint", "unsynced"): 2, ("checkpoint", "fsync"): 1},
    "control": {("control-plane", "reader-open"): 1,
                ("control-plane", "reader-open-many-series"): 1,
                ("control-plane", "appender-open-many-series"): 1,
                ("control-plane", "checkpoint-one-of-many-series"): 1,
                ("control-plane", "refresh-unchanged"): 1,
                ("control-plane", "verify"): 2,
                ("control-plane", "refresh-changed"): 1,
                ("control-plane", "recover-trailing-data"): 3},
    "allocation": {("allocation", name): 1 for name in ALLOCATION_NAMES},
    "concurrency": {("concurrency", "parallel-readers"): 6},
}
ONLY_CHOICES = ("all", "append", "checkpoint", "control", "query", "read-api", "lookup")
FAMILIES = {family for phase in PHASES.values() for family in phase}
U64_MAX = (1 << 64) - 1


class ValidationError(ValueError):
    """Invalid or incomplete resource evidence."""


@dataclass(frozen=True)
class Summary:
    results: int
    workloads: int
    allocation_results: int
    completeness_checked: bool


def _integer(row: dict, field: str, minimum: int = 0, maximum: int = U64_MAX) -> int:
    value = row.get(field)
    if type(value) is not int or not minimum <= value <= maximum:
        raise ValidationError(f"{field} must be an integer in [{minimum}, {maximum}]")
    return value


def _string(row: dict, field: str) -> str:
    value = row.get(field)
    if not isinstance(value, str) or not value.strip():
        raise ValidationError(f"{field} must be a nonempty string")
    return value


def _finite(value: object) -> None:
    # Check extension fields too, including exponent overflow (1e999).
    if isinstance(value, float) and not math.isfinite(value):
        raise ValidationError("nonfinite number")
    if isinstance(value, dict):
        for item in value.values():
            _finite(item)
    elif isinstance(value, list):
        for item in value:
            _finite(item)


def _object(pairs: list[tuple[str, object]]) -> dict:
    row = {}
    for key, value in pairs:
        if key in row:
            raise ValidationError(f"duplicate JSON key: {key}")
        row[key] = value
    return row


def _constant(value: str) -> None:
    raise ValidationError(f"nonfinite JSON number: {value}")


def _metadata(row: dict) -> None:
    if _integer(row, "format", 1) != 1:
        raise ValidationError("unsupported profile format (expected 1)")
    _integer(row, "engine_format", 1, 255)
    for field in ("zig", "os", "arch"):
        _string(row, field)
    _integer(row, "points", 10_000)
    _integer(row, "repetitions", 1)
    if type(row.get("quick")) is not bool:
        raise ValidationError("quick must be a boolean")
    # profile-pair.py combines quick runs and updates repetitions. Quick still
    # describes each workload's inputs, not the number of combined matrices.
    if row["quick"] and row["points"] != 100_000:
        raise ValidationError("quick metadata must use 100000 points")
    if "only" in row and row["only"] not in (*ONLY_CHOICES, "read_api"):
        raise ValidationError("unknown metadata only phase")
    for field in ("expected_results", "expected_workloads"):
        if field in row:
            _integer(row, field, 1)


def _result(row: dict) -> None:
    for field in STRING_FIELDS:
        _string(row, field)
    for field in INTEGER_FIELDS:
        _integer(row, field)
    for field in FLOAT_FIELDS:
        value = row.get(field)
        if type(value) not in (int, float) or value < 0:
            raise ValidationError(f"{field} must be a finite nonnegative number")
        try:
            finite = math.isfinite(value)
        except OverflowError:
            finite = False
        if not finite:
            raise ValidationError(f"{field} must be a finite nonnegative number")
    if (row["group"], row["name"]) not in FAMILIES:
        raise ValidationError(f"unknown workload: {row['group']}/{row['name']}")
    for field, choices in (
        ("codec", ("none", "raw", "compressed")),
        ("timestamp_pattern", ("none", "dense", "sparse", "irregular")),
        ("value_pattern", ("none", "constant", "smooth", "spiky", "random")),
    ):
        if row[field] not in choices:
            raise ValidationError(f"unknown {field}: {row[field]}")
    if not row["p50_ns"] <= row["p95_ns"] <= row["p99_ns"] <= row["max_ns"]:
        raise ValidationError("latency percentiles must be ordered")
    if row["peak_live_bytes"] < row["live_bytes"]:
        raise ValidationError("peak_live_bytes is below live_bytes")
    if row["group"] == "allocation":
        for field in ACTIVITY_FIELDS:
            if row[field] != 0:
                raise ValidationError(f"allocator activity: {field}={row[field]} (expected 0)")
        # Setup allocations remain live across resetMeasurements(). Neither live
        # nor peak is activity; with zero mutations the two must stay equal.
        if row["peak_live_bytes"] != row["live_bytes"]:
            raise ValidationError("allocator activity: peak_live_bytes exceeds live_bytes")
        if row["operations"] == 0:
            raise ValidationError("allocation measured region has no operations")
    elif row["group"] == "storage":
        if not all(row[field] > 0 for field in ("points", "file_size", "bytes_per_point")):
            raise ValidationError("storage result has no measured data")
        if row["raw_blocks"] + row["compressed_blocks"] == 0:
            raise ValidationError("storage result has no blocks")
    elif row["group"] == "query-profile":
        if row["detail_a"] == row["detail_b"] == 0:
            raise ValidationError("first-touch result has no measurements")
    elif row["operations"] == 0 or (row["elapsed_ns"] == 0 and row["max_ns"] == 0):
        raise ValidationError("result has no measured operations or time")


def workload_key(row: dict) -> tuple:
    """Match compare.py; damaged-tail size distinguishes recovery workloads."""
    return tuple(row[field] for field in STRING_FIELDS + ("series_count", "batch_size", "width")) + (
        row["detail_a"] if (row["group"], row["name"]) ==
        ("control-plane", "recover-trailing-data") else 0,
    )


def _multiplicity(key: tuple, points: int) -> int:
    if key[:2] == ("query", "range"):
        return sum(min(width, points) == key[7] for width in (1, 10, 100, 1_000, 10_000, 100_000))
    if key[:2] == ("aggregate", "summary-tree"):
        return sum(min(width, points) == key[7] for width in (100, 10_000, points))
    return 1


def validate(path: Path, only: str | None = None, *, allow_partial: bool = False) -> Summary:
    """Raise ValidationError with file/line context; never modify evidence."""
    metadata = None
    workloads: Counter = Counter()
    families: Counter = Counter()
    results = allocation_results = 0
    try:
        with path.open(encoding="utf-8") as source:
            for line_number, line in enumerate(source, 1):
                try:
                    if not line.endswith("\n"):
                        raise ValidationError("unterminated JSONL record (possibly truncated)")
                    if not line.strip():
                        raise ValidationError("empty JSONL record")
                    row = json.loads(line, object_pairs_hook=_object, parse_constant=_constant)
                    if not isinstance(row, dict):
                        raise ValidationError("record must be a JSON object")
                    _finite(row)
                    if row.get("type") == "metadata":
                        if metadata is not None or results:
                            raise ValidationError("metadata must occur once, before results")
                        _metadata(row)
                        metadata = row
                    elif row.get("type") == "result":
                        _result(row)
                        workloads[workload_key(row)] += 1
                        families[(row["group"], row["name"])] += 1
                        results += 1
                        allocation_results += row["group"] == "allocation"
                    else:
                        raise ValidationError("record type must be metadata or result")
                except (ValidationError, ValueError, RecursionError) as error:
                    raise ValidationError(f"{path}:{line_number}: {error}") from error
    except (OSError, UnicodeError) as error:
        raise ValidationError(f"{path}: {error}") from error
    if not results:
        raise ValidationError(f"{path}: no result records")
    if only is not None and only not in ONLY_CHOICES:
        raise ValidationError(f"{path}: unknown only phase: {only}")
    if only is not None and allow_partial:
        raise ValidationError(f"{path}: --only cannot be combined with --allow-partial")
    if metadata is None and not allow_partial:
        raise ValidationError(f"{path}: missing harness metadata; use --allow-partial for exploratory files")
    if metadata is not None and not allow_partial:
        recorded_only = metadata.get("only")
        if recorded_only == "read_api":
            recorded_only = "read-api"
        if only is not None and recorded_only is not None and only != recorded_only:
            raise ValidationError(f"{path}: --only conflicts with metadata only")
        scope = only or recorded_only or "all"
        repetitions = metadata["repetitions"]
        expected = Counter({family: count * repetitions
                            for phase in (PHASES.values() if scope == "all" else (PHASES[scope],))
                            for family, count in phase.items()})
        if families != expected:
            differences = [f"{'/'.join(family)}: got {families[family]}, expected {expected[family]}"
                           for family in sorted(families.keys() | expected.keys())
                           if families[family] != expected[family]]
            raise ValidationError(f"{path}: incomplete matrix ({'; '.join(differences)})")
        for key, count in workloads.items():
            expected_count = repetitions * _multiplicity(key, metadata["points"])
            if count != expected_count:
                raise ValidationError(f"{path}: {'/'.join(map(str, key))}: got {count} repetitions, "
                                      f"expected {expected_count}")
        for field, actual in (("expected_results", results), ("expected_workloads", len(workloads))):
            if field in metadata and metadata[field] != actual:
                raise ValidationError(f"{path}: {field}={metadata[field]}, got {actual}")
    return Summary(results, len(workloads), allocation_results, not allow_partial)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Validate internal performance JSONL structure, completeness, and zero allocator activity.",
        epilog="No speed, latency, or storage thresholds. Default validation requires harness metadata "
               "and a complete matrix. Exploratory --allow-partial skips completeness checks, but still "
               "rejects malformed records and allocator activity. Exit 0: valid, 1: invalid, 2: usage error.",
    )
    parser.add_argument("profiles", nargs="+", type=Path, metavar="PROFILE.jsonl",
                        help="one or more evidence files (read only)")
    scope = parser.add_mutually_exclusive_group()
    scope.add_argument("--only", choices=ONLY_CHOICES,
                       help="phase for older metadata lacking 'only' (default: all); must match newer metadata")
    scope.add_argument("--allow-partial", action="store_true",
                       help="exploratory files only: allow missing metadata or incomplete matrices; "
                            "keep structural and allocator checks")
    args = parser.parse_args(argv)
    failed = False
    for path in args.profiles:
        try:
            summary = validate(path, args.only, allow_partial=args.allow_partial)
        except ValidationError as error:
            print(f"error: {error}", file=sys.stderr)
            failed = True
        else:
            coverage = "complete matrix" if summary.completeness_checked else "completeness unverified: --allow-partial"
            print(f"{path}: valid; {summary.results} results, {summary.workloads} workloads, "
                  f"{summary.allocation_results} allocation measurements; {coverage}")
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
