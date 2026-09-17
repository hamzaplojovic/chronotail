#!/usr/bin/env python3
"""Build, run, validate, report, and publish Chronotail benchmarks."""

from __future__ import annotations

import argparse
import csv
import ctypes
import datetime as dt
import hashlib
import html
import json
import math
import os
import pathlib
import platform
import re
import shutil
import statistics
import subprocess
import sys
import time
from collections import defaultdict
from dataclasses import dataclass

ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = ROOT / "bench" / "competitive"
BUILD = HERE / "build"
VENDOR = HERE / "vendor" / "nanots"
WORK = HERE / "work"
RESULTS = ROOT / "bench" / "results"
ASSETS = ROOT / "docs" / "assets"
RUNNER = BUILD / "competitive"

NANOTS_REPOSITORY = "https://github.com/dicroce/nanots.git"
NANOTS_COMMIT = "d551210c8d521604a70a73f0f85fe2759c434c23"
RUNS = 5
APPEND_POINTS = 10_000_000
MULTI_POINTS = 1_000_000
QUERY_POINTS = 1_000_000
QUERIES = 100_000
SYNC_10_MIB = 10 * 1024 * 1024 // 16
SYNC_1_MIB = 1024 * 1024 // 16
ENGINES = ("chronotail", "nanots", "sqlite")
COLORS = {
    "chronotail": "#c9ff4a",
    "nanots": "#b89cff",
    "sqlite": "#51e1e8",
}
CHARTS = (
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


@dataclass(frozen=True)
class Invocation:
    args: tuple[str, ...]
    expected: tuple[tuple[str, str, int], ...]


def command_output(command: list[str]) -> str:
    return subprocess.check_output(
        command, text=True, stderr=subprocess.STDOUT
    ).strip()


def run_checked(command: list[str], *, cwd: pathlib.Path = ROOT) -> None:
    subprocess.run(command, cwd=cwd, check=True)


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def maybe(command: list[str]) -> str:
    try:
        return command_output(command)
    except Exception as error:
        return f"unavailable: {error}"


def format_version() -> int:
    text = (ROOT / "src" / "internal" / "format.zig").read_text()
    match = re.search(r"pub const version: u8 = (\d+);", text)
    if match is None:
        raise RuntimeError("Chronotail format version not found")
    return int(match.group(1))


def abi_version() -> int:
    library = ctypes.CDLL(str(BUILD / "chronotail" / "lib" / "libchronotail.dylib"))
    library.ct_abi_version.restype = ctypes.c_uint32
    return int(library.ct_abi_version())


def fetch_and_build() -> None:
    if not (VENDOR / ".git").is_dir():
        if VENDOR.exists():
            shutil.rmtree(VENDOR)
        VENDOR.parent.mkdir(parents=True, exist_ok=True)
        run_checked(["git", "clone", NANOTS_REPOSITORY, str(VENDOR)])
    run_checked(["git", "-C", str(VENDOR), "fetch", "--depth", "1", "origin", NANOTS_COMMIT])
    run_checked(["git", "-C", str(VENDOR), "checkout", "--detach", NANOTS_COMMIT])
    if command_output(["git", "-C", str(VENDOR), "rev-parse", "HEAD"]) != NANOTS_COMMIT:
        raise RuntimeError("NanoTS checkout does not match pinned commit")

    if BUILD.exists():
        shutil.rmtree(BUILD)
    (BUILD / "chronotail").mkdir(parents=True)
    (BUILD / "nanots").mkdir(parents=True)
    run_checked(
        [
            "zig",
            "build",
            "-Doptimize=ReleaseFast",
            "--prefix",
            str(BUILD / "chronotail"),
        ]
    )
    run_checked(
        [
            "cmake",
            "-S",
            str(VENDOR),
            "-B",
            str(BUILD / "nanots"),
            "-DCMAKE_BUILD_TYPE=Release",
        ]
    )
    run_checked(
        [
            "cmake",
            "--build",
            str(BUILD / "nanots"),
            "--config",
            "Release",
            "-j",
            str(os.cpu_count() or 1),
            "--target",
            "nanots",
        ]
    )
    sqlite_object = BUILD / "nanots" / "sqlite-benchmark.o"
    run_checked(
        [
            "clang",
            "-O3",
            "-DNDEBUG",
            "-c",
            str(VENDOR / "sqlite3.c"),
            "-o",
            str(sqlite_object),
        ]
    )
    run_checked(
        [
            "clang++",
            "-std=c++20",
            "-O3",
            "-DNDEBUG",
            "-I",
            str(ROOT / "include"),
            "-I",
            str(VENDOR),
            str(HERE / "competitive.cpp"),
            str(sqlite_object),
            "-L",
            str(BUILD / "nanots"),
            "-lnanots",
            "-L",
            str(BUILD / "chronotail" / "lib"),
            "-lchronotail",
            f"-Wl,-rpath,{BUILD / 'chronotail' / 'lib'}",
            f"-Wl,-rpath,{BUILD / 'nanots'}",
            "-framework",
            "CoreFoundation",
            "-framework",
            "Security",
            "-o",
            str(RUNNER),
        ]
    )
    probe = subprocess.run([str(RUNNER)], text=True, capture_output=True)
    if probe.returncode == 0 or probe.stderr.strip() != "ERROR: missing command":
        raise RuntimeError("competitive runner probe failed")


def database_path(engine: str, label: str) -> str:
    safe = re.sub(r"[^a-zA-Z0-9-]", "-", label)
    return str(WORK / f"{safe}-{engine}.db")


def invocation(command: str, engine: str, run: int, label: str, *args: object) -> Invocation:
    expected = (
        ((label + "-writer", engine, run), (label + "-readers", engine, run))
        if command == "concurrent"
        else ((label, engine, run),)
    )
    values = (command, engine, database_path(engine, label), *(str(value) for value in args))
    return Invocation(tuple(values), expected)


def matrix() -> list[Invocation]:
    calls: list[Invocation] = []
    for run in range(1, RUNS + 1):
        offset = (run - 1) % len(ENGINES)
        order = ENGINES[offset:] + ENGINES[:offset]

        # Frozen public matrix, in its original order.
        for label, boundary in (
            ("append-A-none", 0),
            ("append-B-10MiB", SYNC_10_MIB),
            ("append-C-1MiB", SYNC_1_MIB),
        ):
            for engine in order:
                calls.append(invocation("append", engine, run, label, APPEND_POINTS, 1, boundary, "raw", "smooth", 1, run, label))
        for engine in order:
            calls.append(invocation("append", engine, run, "append-8-series", MULTI_POINTS, 8, SYNC_10_MIB, "raw", "smooth", 1, run, "append-8-series"))
        for engine in order:
            calls.append(invocation("query", engine, run, "point-lookup-warm", QUERY_POINTS, QUERIES, 1, "raw", run, "point-lookup-warm", 4242 + run))
        for engine in order:
            calls.append(invocation("query", engine, run, "range-100-raw-warm", QUERY_POINTS, QUERIES, 100, "raw", run, "range-100-raw-warm", 5252 + run))
        calls.append(invocation("query", "chronotail", run, "range-100-compressed-warm", QUERY_POINTS, QUERIES, 100, "compressed", run, "range-100-compressed-warm", 5252 + run))
        for readers in (1, 8, 32):
            label = f"concurrent-{readers}"
            for engine in order:
                calls.append(invocation("concurrent", engine, run, label, readers, 10, run, label))
        for pattern in ("smooth", "random"):
            specs = (
                ("chronotail", "raw", f"storage-{pattern}-raw"),
                ("chronotail", "compressed", f"storage-{pattern}-compressed"),
                ("nanots", "raw", f"storage-{pattern}"),
                ("sqlite", "raw", f"storage-{pattern}"),
            )
            for engine, codec, label in specs:
                calls.append(invocation("append", engine, run, label, APPEND_POINTS, 1, 0, codec, pattern, 1, run, label))

        # Expanded coverage runs after the frozen matrix to preserve its order.
        for engine in order:
            label = "append-batch-4096"
            calls.append(invocation("append", engine, run, label, APPEND_POINTS, 1, 0, "raw", "smooth", 4096, run, label))
        calls.append(invocation("query", "chronotail", run, "point-lookup-compressed-warm", QUERY_POINTS, QUERIES, 1, "compressed", run, "point-lookup-compressed-warm", 4242 + run))
        for width, query_count in ((10, QUERIES), (1000, QUERIES), (10_000, 10_000)):
            raw_label = f"range-{width}-raw-warm"
            compressed_label = f"range-{width}-compressed-warm"
            for engine in order:
                calls.append(invocation("query", engine, run, raw_label, QUERY_POINTS, query_count, width, "raw", run, raw_label, 6252 + run + width))
            calls.append(invocation("query", "chronotail", run, compressed_label, QUERY_POINTS, query_count, width, "compressed", run, compressed_label, 6252 + run + width))
        for width, query_count, width_label in (
            (100, QUERIES, "100"),
            (10_000, 10_000, "10000"),
            (QUERY_POINTS, 100, "full"),
        ):
            raw_label = f"aggregate-{width_label}-raw-warm"
            compressed_label = f"aggregate-{width_label}-compressed-warm"
            for engine in order:
                calls.append(invocation("aggregate", engine, run, raw_label, QUERY_POINTS, query_count, width, "raw", run, raw_label, 7252 + run + width))
            calls.append(invocation("aggregate", "chronotail", run, compressed_label, QUERY_POINTS, query_count, width, "compressed", run, compressed_label, 7252 + run + width))
        for readers in (2, 4, 16):
            label = f"concurrent-{readers}"
            for engine in order:
                calls.append(invocation("concurrent", engine, run, label, readers, 10, run, label))
        for pattern in ("constant", "spiky"):
            specs = (
                ("chronotail", "raw", f"storage-{pattern}-raw"),
                ("chronotail", "compressed", f"storage-{pattern}-compressed"),
                ("nanots", "raw", f"storage-{pattern}"),
                ("sqlite", "raw", f"storage-{pattern}"),
            )
            for engine, codec, label in specs:
                calls.append(invocation("append", engine, run, label, APPEND_POINTS, 1, 0, codec, pattern, 1, run, label))
    return calls


def expected_groups(calls: list[Invocation]) -> list[tuple[str, str]]:
    return sorted({(workload, engine) for call in calls for workload, engine, _ in call.expected})


def fingerprint() -> dict[str, object]:
    payload: dict[str, object] = {
        "git_commit": command_output(["git", "rev-parse", "HEAD"]),
        "competitive_cpp_sha256": sha256(HERE / "competitive.cpp"),
        "bench_py_sha256": sha256(HERE / "bench.py"),
        "chronotail_header_sha256": sha256(ROOT / "include" / "chronotail.h"),
        "nanots_commit": NANOTS_COMMIT,
        "platform": platform.platform(),
        "format": format_version(),
        "abi": abi_version(),
    }
    encoded = json.dumps(payload, sort_keys=True).encode()
    payload["identity"] = hashlib.sha256(encoded).hexdigest()
    return payload


def machine(groups: list[tuple[str, str]], identity: dict[str, object]) -> dict[str, object]:
    return {
        "schema": 2,
        "started_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "platform": platform.platform(),
        "uname": maybe(["uname", "-a"]),
        "macos": maybe(["sw_vers"]),
        "cpu": maybe(["sysctl", "-n", "machdep.cpu.brand_string"]),
        "logical_cpus": maybe(["sysctl", "-n", "hw.ncpu"]),
        "ram_bytes": maybe(["sysctl", "-n", "hw.memsize"]),
        "filesystem": maybe(["diskutil", "info", "/"]),
        "zig": maybe(["zig", "version"]),
        "clang": maybe(["clang", "--version"]),
        "cmake": maybe(["cmake", "--version"]),
        "python": sys.version,
        "nanots_commit": NANOTS_COMMIT,
        "sqlite_header_version": next(
            line
            for line in (VENDOR / "sqlite3.h").read_text(errors="ignore").splitlines()
            if line.startswith("#define SQLITE_VERSION ")
        ),
        "chronotail_abi": identity["abi"],
        "chronotail_format": identity["format"],
        "run_count": RUNS,
        "group_count": len(groups),
        "result_count": len(groups) * RUNS,
        "load_average_start": os.getloadavg(),
        "fingerprint": identity,
        "latency_sampling": (
            "append: deterministic randomized intervals averaging 1/1024 records; "
            "queries and aggregates: every call; concurrency: every 256th aggregate query"
        ),
        "cache_policy": (
            "warm OS page cache; cold cache omitted because reliable macOS eviction "
            "requires privileged global purge"
        ),
    }


def read_rows(path: pathlib.Path) -> list[dict[str, object]]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line]


def write_manifest(out: pathlib.Path, groups: list[tuple[str, str]]) -> None:
    manifest = {
        "schema": 2,
        "repetitions": RUNS,
        "group_count": len(groups),
        "result_count": len(groups) * RUNS,
        "groups": [
            {"workload": workload, "engine": engine} for workload, engine in groups
        ],
    }
    (out / "matrix.json").write_text(json.dumps(manifest, indent=2) + "\n")


def validate_results(out: pathlib.Path) -> list[dict[str, object]]:
    manifest = json.loads((out / "matrix.json").read_text())
    rows = read_rows(out / "raw.jsonl")
    expected = {
        (group["workload"], group["engine"], run)
        for group in manifest["groups"]
        for run in range(1, manifest["repetitions"] + 1)
    }
    actual = [(row["workload"], row["engine"], row["run"]) for row in rows]
    if len(actual) != len(set(actual)):
        raise RuntimeError("duplicate benchmark result identity")
    if set(actual) != expected:
        missing = sorted(expected - set(actual))
        extra = sorted(set(actual) - expected)
        raise RuntimeError(f"incomplete matrix: missing={missing[:5]} extra={extra[:5]}")
    for row in rows:
        if row.get("schema") != 2:
            raise RuntimeError("unexpected benchmark record schema")
        for field in ("seconds", "operations", "points"):
            value = float(row[field])
            if not math.isfinite(value) or value <= 0:
                raise RuntimeError(f"invalid {field} in {row['workload']}/{row['engine']}")
    return rows


def run_matrix(resume: pathlib.Path | None, publish: bool) -> pathlib.Path:
    fetch_and_build()
    calls = matrix()
    groups = expected_groups(calls)
    current_fingerprint = fingerprint()
    if resume is None:
        run_id = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        out = RESULTS / run_id
        out.mkdir(parents=True)
        write_manifest(out, groups)
        environment = machine(groups, current_fingerprint)
        (out / "environment.json").write_text(json.dumps(environment, indent=2) + "\n")
    else:
        out = resume.resolve()
        environment = json.loads((out / "environment.json").read_text())
        if environment["fingerprint"]["identity"] != current_fingerprint["identity"]:
            raise RuntimeError("resume fingerprint differs from the original run")
        saved_manifest = json.loads((out / "matrix.json").read_text())
        if saved_manifest["groups"] != json.loads(
            json.dumps([{"workload": w, "engine": e} for w, e in groups])
        ):
            raise RuntimeError("resume matrix differs from the original run")

    previous = read_rows(out / "raw.jsonl")
    identities = [(row["workload"], row["engine"], row["run"]) for row in previous]
    if len(identities) != len(set(identities)):
        raise RuntimeError("raw results already contain duplicates")
    complete = set(identities)
    WORK.mkdir(parents=True, exist_ok=True)
    raw = (out / "raw.jsonl").open("a", buffering=1)
    commands = (out / "commands.log").open("a", buffering=1)
    started = time.time()
    try:
        for index, call in enumerate(calls, 1):
            present = set(call.expected) & complete
            if present == set(call.expected):
                commands.write("SKIP completed: " + " ".join(call.args) + "\n")
                continue
            if present:
                raise RuntimeError(f"partial multi-record invocation: {present}")
            full_command = [str(RUNNER), *call.args]
            commands.write(" ".join(full_command) + "\n")
            commands.flush()
            print(f"[{index}/{len(calls)}] {'/'.join(call.expected[0][:2])}", flush=True)
            wall_started = time.time()
            process = subprocess.run(full_command, text=True, capture_output=True)
            commands.write(process.stderr)
            if process.returncode:
                raise RuntimeError(
                    f"benchmark failed ({process.returncode}): {' '.join(full_command)}\n"
                    f"{process.stderr}"
                )
            emitted = [json.loads(line) for line in process.stdout.splitlines() if line]
            emitted_keys = {
                (row["workload"], row["engine"], row["run"]) for row in emitted
            }
            if emitted_keys != set(call.expected):
                raise RuntimeError(
                    f"runner emitted {sorted(emitted_keys)}, expected {sorted(call.expected)}"
                )
            for row in emitted:
                row["wall_started_unix"] = wall_started
                raw.write(json.dumps(row, separators=(",", ":")) + "\n")
                complete.add((row["workload"], row["engine"], row["run"]))
            shutil.rmtree(WORK)
            WORK.mkdir()
            time.sleep(1)
    finally:
        raw.close()
        commands.close()

    validate_results(out)
    environment["completed_utc"] = dt.datetime.now(dt.timezone.utc).isoformat()
    environment["elapsed_seconds"] = time.time() - started
    environment["load_average_end"] = os.getloadavg()
    (out / "environment.json").write_text(json.dumps(environment, indent=2) + "\n")
    report(out, publish=publish)
    print(out)
    return out


SUMMARY_FIELDS = (
    "workload",
    "engine",
    "runs",
    "operations_per_sec",
    "best_operations_per_sec",
    "worst_operations_per_sec",
    "points_per_sec",
    "best_points_per_sec",
    "worst_points_per_sec",
    "logical_mib_per_sec",
    "p50_us",
    "p95_us",
    "p99_us",
    "max_us",
    "sync_p50_ms",
    "sync_p95_ms",
    "sync_p99_ms",
    "sync_max_ms",
    "file_bytes",
    "bytes_per_point",
    "latency_scope",
)


def reduce_rows(rows: list[dict[str, object]]) -> list[dict[str, object]]:
    groups: dict[tuple[str, str], list[dict[str, object]]] = defaultdict(list)
    for row in rows:
        groups[row["workload"], row["engine"]].append(row)
    summary: list[dict[str, object]] = []
    for (workload, engine), samples in sorted(groups.items()):
        def median(field: str) -> float:
            return statistics.median(float(sample[field]) for sample in samples)

        rates = [float(sample["operations"]) / float(sample["seconds"]) for sample in samples]
        point_rates = [float(sample["points"]) / float(sample["seconds"]) for sample in samples]
        points = median("points")
        file_bytes = median("file_bytes")
        scopes = {str(sample["latency_scope"]) for sample in samples}
        if len(scopes) != 1:
            raise RuntimeError(f"latency scope mismatch for {workload}/{engine}")
        summary.append(
            {
                "workload": workload,
                "engine": engine,
                "runs": len(samples),
                "operations_per_sec": statistics.median(rates),
                "best_operations_per_sec": max(rates),
                "worst_operations_per_sec": min(rates),
                "points_per_sec": statistics.median(point_rates),
                "best_points_per_sec": max(point_rates),
                "worst_points_per_sec": min(point_rates),
                "logical_mib_per_sec": statistics.median(point_rates) * 16 / 1048576,
                "p50_us": median("p50_ns") / 1000,
                "p95_us": median("p95_ns") / 1000,
                "p99_us": median("p99_ns") / 1000,
                "max_us": median("max_ns") / 1000,
                "sync_p50_ms": median("sync_p50_ns") / 1_000_000,
                "sync_p95_ms": median("sync_p95_ns") / 1_000_000,
                "sync_p99_ms": median("sync_p99_ns") / 1_000_000,
                "sync_max_ms": median("sync_max_ns") / 1_000_000,
                "file_bytes": file_bytes,
                "bytes_per_point": file_bytes / points if file_bytes else 0,
                "latency_scope": scopes.pop(),
            }
        )
    return summary


def format_rate(value: float) -> str:
    if value >= 1_000_000_000:
        return f"{value / 1_000_000_000:.2f}B"
    if value >= 1_000_000:
        return f"{value / 1_000_000:.2f}M"
    if value >= 1_000:
        return f"{value / 1_000:.2f}k"
    return f"{value:.2f}"


def format_duration_us(value: float) -> str:
    if value >= 1000:
        return f"{value / 1000:.2f} ms"
    return f"{value:.3f} µs"


def format_bytes(value: float) -> str:
    return f"{value / 1048576:.2f} MiB"


def svg_document(title: str, description: str, height: int, body: str) -> str:
    safe_title = html.escape(title)
    safe_description = html.escape(description)
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1240" height="{height}"
 viewBox="0 0 1240 {height}" role="img" aria-labelledby="title desc">
<title id="title">{safe_title}</title>
<desc id="desc">{safe_description}</desc>
<defs>
 <linearGradient id="accent" x1="0" x2="1"><stop stop-color="#ff6ac1"/><stop offset="0.48" stop-color="#b89cff"/><stop offset="1" stop-color="#c9ff4a"/></linearGradient>
</defs>
<rect width="1240" height="{height}" rx="18" fill="#1d1027"/>
<rect width="1240" height="5" rx="2.5" fill="url(#accent)"/>
<style>
 text {{ font-family: Inter, ui-sans-serif, system-ui, -apple-system, sans-serif; fill: #fbf8ff; }}
 .title {{ font-size: 27px; font-weight: 750; letter-spacing: -.4px; }}
 .subtitle {{ font-size: 14px; fill: #cdbfd8; }}
 .group {{ font-size: 15px; font-weight: 720; fill: #fbf8ff; }}
 .label {{ font-size: 13px; fill: #e9e0ef; }}
 .value {{ font-size: 13px; font-weight: 700; fill: #fbf8ff; }}
 .range {{ font-size: 11px; fill: #a997b8; }}
 .footer {{ font-size: 11px; fill: #a997b8; letter-spacing: .2px; }}
</style>
{body}
</svg>
'''


def grouped_chart(
    path: pathlib.Path,
    title: str,
    subtitle: str,
    groups: list[tuple[str, list[tuple[str, str, float, float, float]]]],
    formatter,
    footer: str,
) -> None:
    row_height = 32
    group_gap = 24
    group_header = 27
    height = 116 + sum(group_header + row_height * len(items) + group_gap for _, items in groups)
    parts = [
        f'<text class="title" x="32" y="40">{html.escape(title)}</text>',
        f'<text class="subtitle" x="32" y="66">{html.escape(subtitle)}</text>',
    ]
    y = 98
    for group_name, items in groups:
        maximum = max(high for _, _, _, _, high in items) or 1
        parts.append(f'<text class="group" x="32" y="{y}">{html.escape(group_name)}</text>')
        y += group_header
        for label, engine, value, low, high in items:
            bar_x = 300
            bar_width = 650
            median_width = max(3.0, bar_width * value / maximum)
            low_x = bar_x + bar_width * low / maximum
            high_x = bar_x + bar_width * high / maximum
            color = COLORS[engine]
            parts.extend(
                [
                    f'<text class="label" x="48" y="{y + 18}">{html.escape(label)}</text>',
                    f'<rect x="{bar_x}" y="{y}" width="650" height="23" rx="5" fill="#2c1938" stroke="#4b315a"/>',
                    f'<rect x="{bar_x}" y="{y}" width="{median_width:.2f}" height="23" rx="5" fill="{color}" fill-opacity=".78"/>',
                    f'<line x1="{low_x:.2f}" y1="{y + 11.5}" x2="{high_x:.2f}" y2="{y + 11.5}" stroke="#fbf8ff" stroke-width="2" opacity=".72"/>',
                    f'<circle cx="{bar_x + bar_width * value / maximum:.2f}" cy="{y + 11.5}" r="4" fill="#fbf8ff"/>',
                    f'<text class="value" x="972" y="{y + 18}">{html.escape(formatter(value))}</text>',
                    f'<text class="range" x="1196" y="{y + 18}" text-anchor="end">{html.escape(formatter(low))}–{html.escape(formatter(high))}</text>',
                ]
            )
            y += row_height
        y += group_gap
    parts.append(f'<text class="footer" x="32" y="{height - 22}">{html.escape(footer)}</text>')
    path.write_text(svg_document(title, subtitle, height, "\n".join(parts)))


def overview_chart(path: pathlib.Path, summary: dict[tuple[str, str], dict[str, object]], run_id: str) -> None:
    cards = []

    def rate_card(title: str, workload: str, suffix: str) -> None:
        current = float(summary[workload, "chronotail"]["operations_per_sec"])
        alternatives = [float(summary[workload, engine]["operations_per_sec"]) for engine in ("nanots", "sqlite")]
        cards.append((title, format_rate(current) + suffix, f"{current / max(alternatives):.2f}× fastest alternative"))

    rate_card("BATCH APPEND", "append-batch-4096", " records/s")
    rate_card("RANDOM POINT", "point-lookup-warm", " queries/s")
    rate_card("100-POINT RANGE", "range-100-raw-warm", " queries/s")
    rate_card("FULL AGGREGATE", "aggregate-full-raw-warm", " queries/s")
    rate_card("32 READERS", "concurrent-32-readers", " queries/s")
    storage = float(summary["storage-smooth-compressed", "chronotail"]["bytes_per_point"])
    cards.append(("COMPRESSED STORAGE", f"{storage:.2f} bytes/point", "smooth telemetry"))

    parts = [
        '<text class="title" x="32" y="42">Chronotail performance at a glance</text>',
        '<text class="subtitle" x="32" y="68">Same-machine medians; five runs; exact methodology and losses remain in BENCHMARKS.md</text>',
    ]
    for index, (title, value, note) in enumerate(cards):
        column = index % 2
        row = index // 2
        x = 32 + column * 592
        y = 100 + row * 142
        parts.extend(
            [
                f'<rect x="{x}" y="{y}" width="568" height="118" rx="14" fill="#2a1735" stroke="#523461"/>',
                f'<text x="{x + 22}" y="{y + 29}" font-size="12" font-weight="750" fill="#c9ff4a" letter-spacing="1.2">{html.escape(title)}</text>',
                f'<text x="{x + 22}" y="{y + 69}" font-size="27" font-weight="760">{html.escape(value)}</text>',
                f'<text class="subtitle" x="{x + 22}" y="{y + 94}">{html.escape(note)}</text>',
            ]
        )
    parts.append(f'<text class="footer" x="32" y="548">Run {html.escape(run_id)} · Apple M1 · format v7 · C ABI v2</text>')
    path.write_text(svg_document("Chronotail benchmark overview", "Six headline metrics from the current competitive benchmark.", 572, "\n".join(parts)))


def summary_table(summary: dict[tuple[str, str], dict[str, object]], workloads: list[str], engines: tuple[str, ...] = ENGINES) -> str:
    lines = [
        "| Workload | Engine | Throughput | Run range | p50 | p95 | p99 |",
        "|---|---|---:|---:|---:|---:|---:|",
    ]
    for workload in workloads:
        for engine in engines:
            row = summary.get((workload, engine))
            if row is None:
                continue
            lines.append(
                f"| `{workload}` | {engine} | {format_rate(float(row['operations_per_sec']))}/s "
                f"| {format_rate(float(row['worst_operations_per_sec']))}–{format_rate(float(row['best_operations_per_sec']))}/s "
                f"| {format_duration_us(float(row['p50_us']))} | {format_duration_us(float(row['p95_us']))} "
                f"| {format_duration_us(float(row['p99_us']))} |"
            )
    return "\n".join(lines)


def ratio_text(summary: dict[tuple[str, str], dict[str, object]], workload: str) -> str:
    current = float(summary[workload, "chronotail"]["operations_per_sec"])
    parts = []
    for engine, name in (("nanots", "NanoTS"), ("sqlite", "SQLite")):
        other = float(summary[workload, engine]["operations_per_sec"])
        parts.append(f"{current / other:.2f}× {name}" if current >= other else f"{other / current:.2f}× slower than {name}")
    return ", ".join(parts)


def render_report(out: pathlib.Path, prefix: str, summary_rows: list[dict[str, object]]) -> str:
    summary = {(str(row["workload"]), str(row["engine"])): row for row in summary_rows}
    environment = json.loads((out / "environment.json").read_text())
    run_id = out.name
    append_workloads = ["append-A-none", "append-B-10MiB", "append-C-1MiB", "append-8-series", "append-batch-4096"]
    query_workloads = [
        "point-lookup-warm", "point-lookup-compressed-warm",
        "range-10-raw-warm", "range-10-compressed-warm",
        "range-100-raw-warm", "range-100-compressed-warm",
        "range-1000-raw-warm", "range-1000-compressed-warm",
        "range-10000-raw-warm", "range-10000-compressed-warm",
    ]
    aggregate_workloads = [
        "aggregate-100-raw-warm", "aggregate-100-compressed-warm",
        "aggregate-10000-raw-warm", "aggregate-10000-compressed-warm",
        "aggregate-full-raw-warm", "aggregate-full-compressed-warm",
    ]

    losses = []
    comparable = [
        "point-lookup-warm", "range-10-raw-warm", "range-100-raw-warm",
        "range-1000-raw-warm", "range-10000-raw-warm",
        "aggregate-100-raw-warm", "aggregate-10000-raw-warm",
        "aggregate-full-raw-warm",
    ] + [f"concurrent-{count}-{kind}" for count in (1, 2, 4, 8, 16, 32) for kind in ("writer", "readers")]
    for workload in comparable:
        current = float(summary[workload, "chronotail"]["operations_per_sec"])
        winner = max(("nanots", "sqlite"), key=lambda engine: float(summary[workload, engine]["operations_per_sec"]))
        winner_rate = float(summary[workload, winner]["operations_per_sec"])
        if winner_rate > current:
            losses.append(f"- `{workload}`: {winner} is **{winner_rate / current:.2f}× faster** ({format_rate(winner_rate)}/s versus {format_rate(current)}/s).")
    loss_text = "\n".join(losses) if losses else "Chronotail has no measured loss in the comparable query, aggregate, or concurrency workloads."

    variability = sorted(
        summary_rows,
        key=lambda row: (float(row["best_operations_per_sec"]) - float(row["worst_operations_per_sec"])) / float(row["operations_per_sec"]),
        reverse=True,
    )[:8]
    variability_rows = "\n".join(
        f"| `{row['workload']}` | {row['engine']} | {format_rate(float(row['worst_operations_per_sec']))}/s | {format_rate(float(row['operations_per_sec']))}/s | {format_rate(float(row['best_operations_per_sec']))}/s | {100 * (float(row['best_operations_per_sec']) - float(row['worst_operations_per_sec'])) / float(row['operations_per_sec']):.1f}% |"
        for row in variability
    )

    macos = str(environment["macos"]).splitlines()[1].split(":", 1)[1].strip()
    return f"""# Chronotail competitive benchmarks

> Current format-v{environment['chronotail_format']} / C-ABI-v{environment['chronotail_abi']} evidence. Run `{run_id}` contains {environment['result_count']} measurements across {environment['group_count']} engine/workload groups and five repetitions.

![Benchmark overview]({prefix}benchmark-overview.svg)

## Result in one minute

- **Batch append:** {format_rate(float(summary['append-batch-4096','chronotail']['operations_per_sec']))} records/s; {ratio_text(summary, 'append-batch-4096')} under the no-sync workload.
- **Random point lookup:** {format_rate(float(summary['point-lookup-warm','chronotail']['operations_per_sec']))} queries/s; {ratio_text(summary, 'point-lookup-warm')}.
- **Raw 100-point range:** {format_rate(float(summary['range-100-raw-warm','chronotail']['operations_per_sec']))} queries/s; {ratio_text(summary, 'range-100-raw-warm')}.
- **Full-series aggregate:** {format_rate(float(summary['aggregate-full-raw-warm','chronotail']['operations_per_sec']))} queries/s; {ratio_text(summary, 'aggregate-full-raw-warm')}.
- **32-reader throughput while writing:** {format_rate(float(summary['concurrent-32-readers','chronotail']['operations_per_sec']))} queries/s; {ratio_text(summary, 'concurrent-32-readers')}.
- **Compressed smooth storage:** {float(summary['storage-smooth-compressed','chronotail']['bytes_per_point']):.3f} bytes/point.

These are same-run comparisons, not copied vendor numbers. Raw records are in [`raw.jsonl`]({prefix}raw.jsonl), exact medians and run ranges are in [`summary.csv`]({prefix}summary.csv), the workload identity contract is in [`matrix.json`]({prefix}matrix.json), and every command is in [`commands.log`]({prefix}commands.log).

## Test machine

| Item | Value |
|---|---|
| CPU | {environment['cpu']} ({environment['logical_cpus']} logical CPUs) |
| RAM | {int(environment['ram_bytes']) / 1073741824:.0f} GiB |
| OS | macOS {macos} / arm64 |
| Filesystem | APFS, local internal SSD |
| Zig | {environment['zig']} |
| Clang | {str(environment['clang']).splitlines()[0]} |
| NanoTS | commit `{environment['nanots_commit']}` |
| SQLite | {str(environment['sqlite_header_version']).split('"')[1]}, NanoTS vendored amalgamation |
| Repetitions | {environment['run_count']}; all tables report medians and min–max run ranges |

## Append

![Append throughput]({prefix}benchmark-append.svg)

{summary_table(summary, append_workloads)}

The 4,096-point batch row uses each engine's best available public ingestion path: Chronotail submits one batch, while NanoTS and SQLite expose record-at-a-time calls inside their existing writer/transaction context. Batch-call latency is therefore not compared across engines; throughput is.

No multiplier is claimed for the durability-window rows. Chronotail publishes with `fsync`, NanoTS rollover uses synchronous `msync`, and SQLite uses WAL with `synchronous=FULL`. The logical windows match; macOS does not promise identical power-loss semantics for those primitives.

![Checkpoint latency]({prefix}benchmark-durability.svg)

## Copied queries

![Query throughput]({prefix}benchmark-query.svg)

{summary_table(summary, query_workloads)}

![Query latency]({prefix}benchmark-query-latency.svg)

Raw rows are equivalent cross-engine workloads. Chronotail compressed rows are an internal storage/CPU choice and are never used to compute competitor ratios. Queries use deterministic random starts against a one-million-point database in the warm OS page cache.

## Aggregates

![Aggregate throughput]({prefix}benchmark-aggregate.svg)

{summary_table(summary, aggregate_workloads)}

Every engine computes count, minimum, maximum, sum, first, and last over the same inclusive range. Chronotail uses its public persisted-summary API, SQLite uses public SQL aggregates plus indexed first/last subqueries, and NanoTS scans its public iterator.

## Concurrent readers and writer

![Concurrent reader throughput]({prefix}benchmark-concurrency.svg)

![Writer throughput under reader load]({prefix}benchmark-concurrent-writer.svg)

| Readers | Engine | Writer records/s | Reader queries/s | Reader p50 | Reader p99 |
|---:|---|---:|---:|---:|---:|
""" + "\n".join(
        f"| {count} | {engine} | {format_rate(float(summary[f'concurrent-{count}-writer',engine]['operations_per_sec']))} | {format_rate(float(summary[f'concurrent-{count}-readers',engine]['operations_per_sec']))} | {format_duration_us(float(summary[f'concurrent-{count}-readers',engine]['p50_us']))} | {format_duration_us(float(summary[f'concurrent-{count}-readers',engine]['p99_us']))} |"
        for count in (1, 2, 4, 8, 16, 32)
        for engine in ENGINES
    ) + f"""

Writer and reader rates are deliberately separate. Readers query the fixed initial one-million-point snapshot while the writer appends and durably publishes around 1 MiB logical boundaries. This avoids rewarding an engine for exposing uncommitted tail points.

## Storage

![Storage efficiency]({prefix}benchmark-storage.svg)

| Pattern | Engine/mode | Total size | Bytes/point |
|---|---|---:|---:|
""" + "\n".join(
        f"| {pattern} | {label} | {format_bytes(float(summary[workload,engine]['file_bytes']))} | {float(summary[workload,engine]['bytes_per_point']):.3f} |"
        for pattern in ("constant", "smooth", "spiky", "random")
        for workload, engine, label in (
            (f"storage-{pattern}-raw", "chronotail", "Chronotail raw"),
            (f"storage-{pattern}-compressed", "chronotail", "Chronotail compressed"),
            (f"storage-{pattern}", "nanots", "NanoTS"),
            (f"storage-{pattern}", "sqlite", "SQLite"),
        )
    ) + f"""

Physical size includes persistent companion/catalog files whose basename begins with the database name. NanoTS preallocation matches the calculated capacity; SQLite is checkpointed and closed before measurement.

## Where Chronotail loses

{loss_text}

This section is generated from every comparable query, aggregate, and concurrent reader/writer group. It is intentionally not a winner-only summary.

## Run variability

The SVG whiskers show min–max rates around the five-run median. The widest relative spreads were:

| Workload | Engine | Worst | Median | Best | Best–worst / median |
|---|---|---:|---:|---:|---:|
{variability_rows}

Run-to-run spread is evidence about the host as well as the engine. Same-run ratios are more reliable than comparing these absolute rates with older runs taken under different background load.

## Methodology and limits

- Logical point: exactly 16 bytes (`i64` timestamp plus `f64` value).
- All engines use optimized local builds, deterministic data, deterministic query seeds, public APIs, consumed results, and complete database validation.
- The original 45-group suite runs first and unchanged; expanded workloads run afterward. Engine order rotates by repetition for the comparable append, query, aggregate, and concurrency loops.
- Query setup and process startup are outside timing. Queries use the warm OS page cache. Cold-cache numbers are omitted because reliable eviction on this macOS host requires privileged global `purge`.
- Append latency uses deterministic randomized sampling averaging one in 1,024 records. Query and aggregate latency times every call. Concurrent readers sample every 256th aggregate query.
- Historical query latency has an unavoidable sink asymmetry: Chronotail materializes caller buffers inside the bracket and hashes them after it, while NanoTS/SQLite consume iterator/row values inside the bracket. Total throughput includes consumption for every engine.
- Append setup is not perfectly symmetric: Chronotail open and NanoTS allocation occur before timing, while SQLite open/schema creation is inside its append interval. This is retained and disclosed so the original public workloads remain comparable with the archived baseline.
- Competitor winners do not drive production tuning. Internal profiling and safety gates remain separate from public evidence.

## Reproduce

```bash
python3 bench/competitive/bench.py run --publish
```

Resume an interrupted run with the same source and machine fingerprint:

```bash
python3 bench/competitive/bench.py run \\
  --resume bench/results/{run_id} \\
  --publish
```

Regenerate and explicitly publish an already-complete run:

```bash
python3 bench/competitive/bench.py report \\
  bench/results/{run_id} \\
  --publish
```

The tool fetches the pinned NanoTS commit, builds all engines, validates the exact matrix before publication, and emits only dependency-free SVG charts.
"""


def chart_groups(summary: dict[tuple[str, str], dict[str, object]], specs, metric: str):
    groups = []
    for group_name, rows in specs:
        items = []
        for label, workload, engine in rows:
            row = summary[workload, engine]
            value = float(row[metric])
            if metric == "operations_per_sec":
                low = float(row["worst_operations_per_sec"])
                high = float(row["best_operations_per_sec"])
            elif metric == "points_per_sec":
                low = float(row["worst_points_per_sec"])
                high = float(row["best_points_per_sec"])
            else:
                low = high = value
            items.append((label, engine, value, low, high))
        groups.append((group_name, items))
    return groups


def render_charts(out: pathlib.Path, summary_rows: list[dict[str, object]]) -> None:
    summary = {(str(row["workload"]), str(row["engine"])): row for row in summary_rows}
    run_id = out.name
    footer = f"Run {run_id} · median bar · min–max whisker · five repetitions"
    overview_chart(out / "benchmark-overview.svg", summary, run_id)

    append_specs = []
    for workload, title in (
        ("append-A-none", "No sync"),
        ("append-B-10MiB", "10 MiB durability window"),
        ("append-C-1MiB", "1 MiB durability window"),
        ("append-8-series", "Eight series"),
        ("append-batch-4096", "4,096-point application batch"),
    ):
        append_specs.append((title, [(engine, workload, engine) for engine in ENGINES]))
    grouped_chart(out / "benchmark-append.svg", "Append throughput", "Each workload has its own scale; higher is better", chart_groups(summary, append_specs, "operations_per_sec"), lambda value: f"{format_rate(value)} records/s", footer)

    query_specs = []
    for width, raw, compressed in (
        (1, "point-lookup-warm", "point-lookup-compressed-warm"),
        (10, "range-10-raw-warm", "range-10-compressed-warm"),
        (100, "range-100-raw-warm", "range-100-compressed-warm"),
        (1000, "range-1000-raw-warm", "range-1000-compressed-warm"),
        (10000, "range-10000-raw-warm", "range-10000-compressed-warm"),
    ):
        rows = [(engine, raw, engine) for engine in ENGINES]
        rows.append(("chronotail compressed", compressed, "chronotail"))
        query_specs.append((f"{width:,}-point copied range", rows))
    grouped_chart(out / "benchmark-query.svg", "Warm copied-query throughput", "Each width has its own scale; higher is better", chart_groups(summary, query_specs, "operations_per_sec"), lambda value: f"{format_rate(value)} queries/s", footer)

    latency_specs = []
    for width, raw in ((1, "point-lookup-warm"), (100, "range-100-raw-warm"), (10000, "range-10000-raw-warm")):
        latency_specs.append((f"{width:,}-point raw range · p50", [(engine, raw, engine) for engine in ENGINES]))
        latency_specs.append((f"{width:,}-point raw range · p99", [(engine, raw, engine) for engine in ENGINES]))
    latency_groups = []
    for index, (name, rows) in enumerate(latency_specs):
        metric = "p50_us" if name.endswith("p50") else "p99_us"
        latency_groups.append((name, [(label, engine, float(summary[workload,engine][metric]), float(summary[workload,engine][metric]), float(summary[workload,engine][metric])) for label, workload, engine in rows]))
    grouped_chart(out / "benchmark-query-latency.svg", "Warm query latency", "p50 and p99 call latency; lower is better", latency_groups, format_duration_us, f"Run {run_id} · five-run median latency")

    aggregate_specs = []
    for width, raw, compressed in (
        ("100 points", "aggregate-100-raw-warm", "aggregate-100-compressed-warm"),
        ("10,000 points", "aggregate-10000-raw-warm", "aggregate-10000-compressed-warm"),
        ("full series", "aggregate-full-raw-warm", "aggregate-full-compressed-warm"),
    ):
        rows = [(engine, raw, engine) for engine in ENGINES]
        rows.append(("chronotail compressed", compressed, "chronotail"))
        aggregate_specs.append((width, rows))
    grouped_chart(out / "benchmark-aggregate.svg", "Aggregate throughput", "count/min/max/sum/first/last; each width has its own scale", chart_groups(summary, aggregate_specs, "operations_per_sec"), lambda value: f"{format_rate(value)} queries/s", footer)

    for kind, filename, title, unit in (
        ("readers", "benchmark-concurrency.svg", "Reader throughput while writing", "queries/s"),
        ("writer", "benchmark-concurrent-writer.svg", "Writer throughput under reader load", "records/s"),
    ):
        specs = [(f"{count} reader{'s' if count != 1 else ''}", [(engine, f"concurrent-{count}-{kind}", engine) for engine in ENGINES]) for count in (1,2,4,8,16,32)]
        grouped_chart(out / filename, title, "Reader and writer rates are never combined; higher is better", chart_groups(summary, specs, "operations_per_sec"), lambda value, unit=unit: f"{format_rate(value)} {unit}", footer)

    storage_specs = []
    for pattern in ("constant", "smooth", "spiky", "random"):
        storage_specs.append((pattern.capitalize(), [
            ("chronotail raw", f"storage-{pattern}-raw", "chronotail"),
            ("chronotail compressed", f"storage-{pattern}-compressed", "chronotail"),
            ("nanots", f"storage-{pattern}", "nanots"),
            ("sqlite", f"storage-{pattern}", "sqlite"),
        ]))
    grouped_chart(out / "benchmark-storage.svg", "Storage efficiency", "Physical bytes per logical point; lower is better", chart_groups(summary, storage_specs, "bytes_per_point"), lambda value: f"{value:.2f} bytes/point", f"Run {run_id} · database and companion files after close")

    durability_groups = []
    for label, workload in (("10 MiB window", "append-B-10MiB"), ("1 MiB window", "append-C-1MiB")):
        for metric, suffix in (("sync_p50_ms", "p50"), ("sync_p99_ms", "p99")):
            durability_groups.append((f"{label} · {suffix}", [(engine, engine, float(summary[workload,engine][metric]), float(summary[workload,engine][metric]), float(summary[workload,engine][metric])) for engine in ENGINES]))
    grouped_chart(out / "benchmark-durability.svg", "Checkpoint / commit latency", "Different public durability primitives; lower is better", durability_groups, lambda value: f"{value:.2f} ms", f"Run {run_id} · logical windows match; power-loss semantics differ")


def write_checksums(out: pathlib.Path) -> None:
    names = ["raw.jsonl", "summary.csv", "matrix.json", "environment.json", "BENCHMARKS.md", *CHARTS]
    lines = [f"{sha256(out / name)}  {name}" for name in names]
    (out / "SHA256SUMS").write_text("\n".join(lines) + "\n")


def report(out: pathlib.Path, publish: bool) -> None:
    rows = validate_results(out)
    summary_rows = reduce_rows(rows)
    with (out / "summary.csv").open("w", newline="") as target:
        writer = csv.DictWriter(target, fieldnames=SUMMARY_FIELDS)
        writer.writeheader()
        writer.writerows(summary_rows)
    render_charts(out, summary_rows)
    archived = render_report(out, "", summary_rows)
    (out / "BENCHMARKS.md").write_text(archived)
    write_checksums(out)
    if publish:
        root_report = render_report(out, f"bench/results/{out.name}/", summary_rows)
        (ROOT / "BENCHMARKS.md").write_text(root_report)
        ASSETS.mkdir(parents=True, exist_ok=True)
        for name in CHARTS:
            shutil.copy2(out / name, ASSETS / name)
        (RESULTS / "LATEST").write_text(out.name + "\n")
        print(f"published benchmark run {out.name}")
    else:
        print(f"generated archived report for {out.name}; publication unchanged")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    run_parser = subparsers.add_parser("run", help="build and run the complete matrix")
    run_parser.add_argument("--resume", type=pathlib.Path)
    run_parser.add_argument("--publish", action="store_true")
    report_parser = subparsers.add_parser("report", help="regenerate a completed run")
    report_parser.add_argument("result", type=pathlib.Path)
    report_parser.add_argument("--publish", action="store_true")
    return parser.parse_args()


def main() -> None:
    arguments = parse_args()
    if arguments.command == "run":
        run_matrix(arguments.resume, arguments.publish)
    else:
        report(arguments.result.resolve(), arguments.publish)


if __name__ == "__main__":
    main()
