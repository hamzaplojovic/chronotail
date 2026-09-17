#!/usr/bin/env python3
"""Generate dependency-free README benchmark charts from an archived summary."""

from __future__ import annotations

import csv
import html
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESULTS = ROOT / "bench/results"
ASSETS = ROOT / "docs/assets"
COLORS = {
    "chronotail": "#2563eb",
    "nanots": "#ea580c",
    "sqlite": "#16a34a",
}


def rate(value: float) -> str:
    if value >= 1_000_000:
        return f"{value / 1_000_000:.2f}M"
    if value >= 1_000:
        return f"{value / 1_000:.2f}k"
    return f"{value:.2f}"


def chart(
    filename: str,
    title: str,
    subtitle: str,
    items: list[tuple[str, str, float, str]],
) -> None:
    width = 1080
    label_width = 390
    bar_width = 540
    row_height = 42
    height = 105 + row_height * len(items)
    maximum = max(value for _, _, value, _ in items)
    rows: list[str] = []
    for index, (label, engine, value, rendered) in enumerate(items):
        y = 88 + index * row_height
        fill = COLORS[engine]
        measured = max(2.0, bar_width * value / maximum)
        rows.extend(
            [
                f'<text class="label" x="20" y="{y + 18}">{html.escape(label)}</text>',
                f'<rect x="{label_width}" y="{y}" width="{measured:.1f}" '
                f'height="24" rx="4" fill="{fill}"/>',
                f'<text class="value" x="{label_width + measured + 10:.1f}" '
                f'y="{y + 18}">{html.escape(rendered)}</text>',
            ]
        )
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}"
 viewBox="0 0 {width} {height}" role="img" aria-label="{html.escape(title)}">
<style>
 text {{ font-family: ui-sans-serif, system-ui, sans-serif; fill: #172033; }}
 .title {{ font-size: 22px; font-weight: 700; }}
 .subtitle {{ font-size: 13px; fill: #59667d; }}
 .label {{ font-size: 13px; }}
 .value {{ font-size: 13px; font-weight: 650; }}
</style>
<text class="title" x="20" y="30">{html.escape(title)}</text>
<text class="subtitle" x="20" y="53">{html.escape(subtitle)}</text>
{''.join(rows)}
</svg>
'''
    (ASSETS / filename).write_text(svg)


def main() -> None:
    run_id = sys.argv[1] if len(sys.argv) == 2 else (RESULTS / "LATEST").read_text().strip()
    summary_path = RESULTS / run_id / "summary.csv"
    rows = list(csv.DictReader(summary_path.open()))
    values = {(row["workload"], row["engine"]): row for row in rows}

    def ops(workload: str, engine: str) -> float:
        return float(values[workload, engine]["operations_per_sec"])

    append_items = []
    for workload, name in (
        ("append-A-none", "No sync"),
        ("append-B-10MiB", "10 MiB durability window"),
        ("append-C-1MiB", "1 MiB durability window"),
        ("append-8-series", "Eight series"),
    ):
        for engine in ("chronotail", "nanots", "sqlite"):
            value = ops(workload, engine)
            append_items.append((f"{name} · {engine}", engine, value, f"{rate(value)} records/s"))
    chart(
        "benchmark-append.svg",
        "Append throughput",
        "Median of five runs; durability primitives differ between engines",
        append_items,
    )

    query_items = []
    for workload, name, engines in (
        ("point-lookup-warm", "Warm random point", ("chronotail", "nanots", "sqlite")),
        ("range-100-raw-warm", "Warm raw 100-point range", ("chronotail", "nanots", "sqlite")),
        ("range-100-compressed-warm", "Warm compressed 100-point range", ("chronotail",)),
    ):
        for engine in engines:
            value = ops(workload, engine)
            query_items.append((f"{name} · {engine}", engine, value, f"{rate(value)} queries/s"))
    chart(
        "benchmark-query.svg",
        "Query throughput",
        "Warm OS page cache; every result is traversed and consumed",
        query_items,
    )

    reader_items = []
    writer_items = []
    for readers in (1, 8, 32):
        for engine in ("chronotail", "nanots", "sqlite"):
            reader_value = ops(f"concurrent-{readers}-readers", engine)
            writer_value = ops(f"concurrent-{readers}-writer", engine)
            reader_items.append(
                (f"{readers} readers · {engine}", engine, reader_value, f"{rate(reader_value)} queries/s")
            )
            writer_items.append(
                (f"{readers} readers · {engine}", engine, writer_value, f"{rate(writer_value)} records/s")
            )
    chart(
        "benchmark-concurrency.svg",
        "Aggregate reader throughput while writing",
        "Readers query a fixed committed snapshot",
        reader_items,
    )
    chart(
        "benchmark-concurrent-writer.svg",
        "Writer throughput under reader load",
        "Reported separately from reader throughput",
        writer_items,
    )

    storage_items = []
    for pattern in ("smooth", "random"):
        specs = (
            (f"storage-{pattern}-raw", "chronotail", "Chronotail raw"),
            (f"storage-{pattern}-compressed", "chronotail", "Chronotail compressed"),
            (f"storage-{pattern}", "nanots", "NanoTS"),
            (f"storage-{pattern}", "sqlite", "SQLite"),
        )
        for workload, engine, name in specs:
            value = float(values[workload, engine]["bytes_per_point"])
            storage_items.append((f"{pattern} · {name}", engine, value, f"{value:.2f} bytes/point"))
    chart(
        "benchmark-storage.svg",
        "Storage efficiency — lower is better",
        "Physical database and companion-file size after close",
        storage_items,
    )
    print(f"Generated benchmark assets from {run_id}")


if __name__ == "__main__":
    main()
