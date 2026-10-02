#!/usr/bin/env python3
"""Validate internal performance JSONL evidence without timing thresholds.

The format-1 result schema comes from tests/performance/main.zig. By default,
harness metadata and complete matrix/repetition evidence are required. Use
--allow-partial explicitly for exploratory structural and allocator checks.
Old metadata omits the selected phase: assume a full run, or use --only to
describe a historical phase run. New metadata may include only,
expected_results (total rows), and expected_workloads (distinct identities).
Complete coverage uses the current format-v7 harness's exact workload-key
multiset, including pinned page geometry and clamped-width multiplicities.
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
# Pinned v7 geometry: internal/format.zig and internal/page.zig. Completeness
# must not infer records_per_block from an observed (possibly substituted) row.
RECORDS_PER_BLOCK = (64 * 1024 - 128) // 16
ONLY_CHOICES = ("all", "append", "checkpoint", "control", "query", "read-api", "lookup")
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


def expected_workloads(metadata: dict, scope: str = "all") -> Counter:
    """Exact format-1/current-v7 harness key multiset, independent of results.

    Mirror the harness's emitted identities and Result defaults, not historical
    report totals. Counter addition retains duplicate widths after clamping;
    counts are multiplied without iterating over the declared repetitions.
    """
    if metadata["engine_format"] != 7:
        raise ValidationError("complete matrix requires known format-v7 geometry; "
                              "use --allow-partial for other engine formats")
    points = metadata["points"]
    repetitions = metadata["repetitions"]
    quick = metadata["quick"]
    phases = {phase: Counter() for phase in (
        "append", "storage", "query", "read-api", "lookup", "aggregate",
        "checkpoint", "control", "allocation", "concurrency",
    )}

    def add(phase: str, group: str, name: str, **fields: object) -> None:
        row = dict.fromkeys(STRING_FIELDS, "none")
        row.update(group=group, name=name, series_count=0, batch_size=0, width=0, detail_a=0)
        row.update(fields)
        phases[phase][workload_key(row)] += repetitions

    codecs = ("raw", "compressed")
    cardinalities = (1, 4, 8, 64, 256)
    for codec in codecs:
        for batch_size in (1, 16, 64, 256, 1_000, RECORDS_PER_BLOCK, 4_096, 65_536):
            add("append", "append", "batch", codec=codec, timestamp_pattern="dense",
                value_pattern="smooth", series_count=1, batch_size=batch_size)
    for timestamp in ("dense", "sparse", "irregular"):
        for value in ("constant", "smooth", "spiky", "random"):
            patterns = dict(timestamp_pattern=timestamp, value_pattern=value)
            add("append", "append", "pattern", codec="compressed", **patterns,
                series_count=1, batch_size=points if quick else min(points, 500_000))
            for codec in codecs:
                add("storage", "storage", "encoding", codec=codec, **patterns)
    for count in cardinalities:
        add("append", "append", "series-cardinality", codec="raw", series_count=count, batch_size=1)
        for name in ("series-lookup-point", "prepared-series-point"):
            add("lookup", "query", name, codec="raw", series_count=count, width=1)
    for timestamp, value in (("dense", "smooth"), ("dense", "random"),
                             ("sparse", "spiky"), ("irregular", "smooth")):
        for codec in codecs:
            patterns = dict(codec=codec, timestamp_pattern=timestamp, value_pattern=value)
            add("query", "query-profile", "first-touch", **patterns, width=100)
            for width in (1, 10, 100, 1_000, 10_000, 100_000):
                add("query", "query", "range", **patterns, width=min(width, points))
            add("query", "query", "range-count-only", **patterns, width=100)
            add("query", "query", "full-scan-count", **patterns, width=points)
    checkpoint_batch = 256 if quick else 4_096
    for codec in codecs:
        for capacity in (16, 128, 1_024, 4_096):
            add("read-api", "query", "cursor-full-range", codec=codec, batch_size=capacity)
        for name in ("range-into-count-only", "text-full-range"):
            add("read-api", "query", name, codec=codec)
        for width in (100, 10_000, points):
            add("aggregate", "aggregate", "summary-tree", codec=codec, width=min(width, points))
        add("aggregate", "aggregate", "resolution-windows", codec=codec, width=points // 10)
        add("checkpoint", "checkpoint", "unsynced", codec=codec, batch_size=checkpoint_batch)
    add("read-api", "query", "borrow-raw-page", codec="raw")
    add("checkpoint", "checkpoint", "fsync", codec="raw", batch_size=checkpoint_batch)
    add("control", "control-plane", "reader-open", codec="compressed")
    for name in ("reader-open-many-series", "appender-open-many-series", "checkpoint-one-of-many-series"):
        add("control", "control-plane", name, codec="raw", series_count=1_024)
    for name in ("refresh-unchanged", "refresh-changed"):
        add("control", "control-plane", name)
    for codec in codecs:
        add("control", "control-plane", "verify", codec=codec)
    for size in (64 * 1024, 1024 * 1024, 16 * 1024 * 1024):
        add("control", "control-plane", "recover-trailing-data", detail_a=size)
    for name in ALLOCATION_NAMES:
        add("allocation", "allocation", name, codec="raw")
    for readers in (1, 2, 4, 8, 16, 32):
        add("concurrency", "concurrency", "parallel-readers", codec="raw", series_count=readers, width=100)

    expected = Counter()
    for phase in phases.values() if scope == "all" else (phases[scope],):
        expected.update(phase)
    return expected


FAMILIES = {key[:2] for key in expected_workloads(
    dict(engine_format=7, points=1_000_000, repetitions=1, quick=False),
)}


def validate(path: Path, only: str | None = None, *, allow_partial: bool = False) -> Summary:
    """Raise ValidationError with file/line context; never modify evidence."""
    metadata = None
    workloads: Counter = Counter()
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
        try:
            expected = expected_workloads(metadata, scope)
        except ValidationError as error:
            raise ValidationError(f"{path}: {error}") from error
        if workloads != expected:
            differences = [f"{'/'.join(map(str, key))}: got {workloads[key]}, expected {expected[key]}"
                           for key in sorted(workloads.keys() | expected.keys())
                           if workloads[key] != expected[key]]
            raise ValidationError(f"{path}: incomplete matrix/repetitions ({'; '.join(differences)})")
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
