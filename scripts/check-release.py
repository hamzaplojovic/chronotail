#!/usr/bin/env python3
"""Validate release metadata, compatibility evidence, and published benchmarks."""

from __future__ import annotations

import collections
import csv
import hashlib
import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESULTS = ROOT / "bench" / "results"
HISTORICAL_V1_RUN = "20260917-105244"
BENCHMARK_CHARTS = (
    "benchmark-overview.svg",
    "benchmark-append.svg",
    "benchmark-query.svg",
    "benchmark-query-latency.svg",
    "benchmark-aggregate.svg",
    "benchmark-concurrency.svg",
    "benchmark-concurrent-writer.svg",
    "benchmark-storage.svg",
    "benchmark-durability.svg",
)


def version_from(path: Path) -> str:
    match = re.search(r'\.version\s*=\s*"([^"]+)"', path.read_text())
    if match is None:
        raise AssertionError(f"version missing from {path}")
    return match.group(1)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def records(path: Path) -> list[dict[str, object]]:
    return [json.loads(line) for line in path.read_text().splitlines() if line]


def check_frozen_sources() -> None:
    manifest = ROOT / "docs/releases/v1.0.0-engine.sha256"
    for line in manifest.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        expected, relative = line.split(maxsplit=1)
        actual = digest(ROOT / relative)
        assert actual == expected, f"frozen source changed: {relative}"


def check_historical_benchmark() -> None:
    archive = RESULTS / HISTORICAL_V1_RUN / "raw.jsonl"
    rows = records(archive)
    groups = collections.Counter((row["workload"], row["engine"]) for row in rows)
    assert len(rows) == 225, "historical v1 run must contain 225 measurements"
    assert len(groups) == 45, "historical v1 run must contain 45 groups"
    assert set(groups.values()) == {5}, "every historical group must contain five runs"


def check_checksums(directory: Path) -> None:
    expected_names = {
        "raw.jsonl",
        "summary.csv",
        "matrix.json",
        "environment.json",
        "commands.log",
        "BENCHMARKS.md",
        *BENCHMARK_CHARTS,
    }
    declared: dict[str, str] = {}
    for line in (directory / "SHA256SUMS").read_text().splitlines():
        checksum, name = line.split(maxsplit=1)
        declared[name] = checksum
    assert set(declared) == expected_names, "benchmark checksum manifest is incomplete"
    for name, expected in declared.items():
        assert digest(directory / name) == expected, f"benchmark checksum mismatch: {name}"


def check_current_benchmark() -> str:
    run_id = (RESULTS / "LATEST").read_text().strip()
    directory = RESULTS / run_id
    manifest = json.loads((directory / "matrix.json").read_text())
    assert manifest["schema"] == 2
    assert manifest["repetitions"] == 5
    assert manifest["group_count"] == 99
    assert manifest["result_count"] == 495

    expected_groups = {
        (entry["workload"], entry["engine"]) for entry in manifest["groups"]
    }
    assert len(expected_groups) == 99, "benchmark manifest contains duplicate groups"

    rows = records(directory / "raw.jsonl")
    identities = [(row["workload"], row["engine"], row["run"]) for row in rows]
    assert len(rows) == 495, "published run must contain 495 measurements"
    assert len(set(identities)) == 495, "published run contains duplicate results"
    assert {row["schema"] for row in rows} == {2}
    groups = collections.Counter((row["workload"], row["engine"]) for row in rows)
    assert set(groups) == expected_groups, "published results do not match matrix manifest"
    assert set(groups.values()) == {5}, "every published group must contain five runs"

    with (directory / "summary.csv").open(newline="") as source:
        summary = list(csv.DictReader(source))
    assert len(summary) == 99, "summary must contain one row per benchmark group"
    assert {(row["workload"], row["engine"]) for row in summary} == expected_groups

    environment = json.loads((directory / "environment.json").read_text())
    assert environment["group_count"] == 99
    assert environment["result_count"] == 495
    assert environment["run_count"] == 5
    assert environment["chronotail_format"] == 7
    assert environment["chronotail_abi"] == 2

    check_checksums(directory)
    assert run_id in (ROOT / "BENCHMARKS.md").read_text(), (
        "root BENCHMARKS.md does not identify the published run"
    )
    return run_id


def check_assets() -> None:
    names = ("architecture.svg", *BENCHMARK_CHARTS)
    for name in names:
        path = ROOT / "docs" / "assets" / name
        assert path.is_file(), f"missing asset: {name}"
        ET.parse(path)
    pngs = sorted((ROOT / "docs" / "assets").glob("*.png"))
    assert not pngs, f"PNG mirrors are not published: {[path.name for path in pngs]}"


def main() -> None:
    version = version_from(ROOT / "build.zig.zon")
    pyproject = (ROOT / "python/pyproject.toml").read_text()
    release_notes = (ROOT / "RELEASE_NOTES.md").read_text()
    assert f'version = "{version}"' in pyproject
    assert f"Chronotail {version}" in release_notes

    targets = [
        line
        for line in (ROOT / "scripts/targets.sh").read_text().splitlines()
        if line.strip().startswith('"')
    ]
    assert targets == [
        '  "macos-aarch64|aarch64-macos|macosx_11_0_arm64|libchronotail.dylib"'
    ]

    check_historical_benchmark()
    if version.startswith("1."):
        check_frozen_sources()
    else:
        assert "pub const version: u8 = 7;" in (
            ROOT / "src/internal/format.zig"
        ).read_text()
        assert "ABI_VERSION = 2" in (
            ROOT / "python/src/chronotail/__init__.py"
        ).read_text()

    run_id = check_current_benchmark()
    check_assets()
    print(
        f"release metadata valid: v{version}, macOS ARM64, "
        f"benchmark {run_id}, historical v1 preserved"
    )


if __name__ == "__main__":
    main()
