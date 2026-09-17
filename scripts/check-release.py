#!/usr/bin/env python3
"""Validate release metadata, frozen sources, and canonical benchmark evidence."""

from __future__ import annotations

import collections
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def version_from(path: Path) -> str:
    match = re.search(r'\.version\s*=\s*"([^"]+)"', path.read_text())
    if match is None:
        raise AssertionError(f"version missing from {path}")
    return match.group(1)


def check_frozen_sources() -> None:
    manifest = ROOT / "docs/releases/v1.0.0-engine.sha256"
    for line in manifest.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        expected, relative = line.split(maxsplit=1)
        actual = hashlib.sha256((ROOT / relative).read_bytes()).hexdigest()
        assert actual == expected, f"frozen source changed: {relative}"


def check_benchmarks() -> str:
    run_id = (ROOT / "bench/results/LATEST").read_text().strip()
    raw_path = ROOT / "bench/results" / run_id / "raw.jsonl"
    records = [json.loads(line) for line in raw_path.read_text().splitlines()]
    groups = collections.Counter((row["workload"], row["engine"]) for row in records)
    assert len(records) == 225, "canonical run must contain 225 measurements"
    assert len(groups) == 45, "canonical run must contain 45 groups"
    assert set(groups.values()) == {5}, "every canonical group must contain five runs"
    return run_id


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
    if version.startswith("1."):
        check_frozen_sources()
    else:
        assert 'pub const version: u8 = 7;' in (
            ROOT / "src/internal/format.zig"
        ).read_text()
        assert "ABI_VERSION = 2" in (
            ROOT / "python/src/chronotail/__init__.py"
        ).read_text()
    run_id = check_benchmarks()
    expected_assets = (
        "architecture.svg",
        "benchmark-append.svg",
        "benchmark-query.svg",
        "benchmark-concurrency.svg",
        "benchmark-concurrent-writer.svg",
        "benchmark-storage.svg",
    )
    for name in expected_assets:
        svg = ROOT / "docs/assets" / name
        png = svg.with_suffix(".png")
        assert svg.is_file(), f"missing asset: {name}"
        assert png.is_file(), f"missing rendered asset: {png.name}"
    print(f"release metadata valid: v{version}, macOS ARM64, v1 benchmark {run_id}")


if __name__ == "__main__":
    main()
