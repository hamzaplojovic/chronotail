# Benchmark and documentation redesign

Status: accepted for implementation on the `v2` branch.

## Goal

Publish a fresh, broader Chronotail 2.0 benchmark without changing production
code, collapse the benchmark toolchain to the minimum useful pieces, replace
raster chart mirrors with accessible dark SVGs, and rewrite the documentation
as one coherent current product rather than separate v1/v2 narratives.

## Tooling architecture

The benchmark keeps only three files in `bench/competitive/`:

1. `competitive.cpp` calls Chronotail, NanoTS, and SQLite in the same process,
   consumes results, validates databases, and emits JSON records.
2. `bench.py` fetches pinned sources, builds the runner, executes/resumes the
   matrix, validates exact completeness, reduces statistics, renders Markdown
   and SVG, and explicitly publishes a completed run.
3. `README.md` explains fairness, commands, outputs, and recovery.

This removes the separate fetch/build/run/summarize/compare shell and Python
layers, the environment version file, and the duplicate root asset generator.
Python remains because resumability, statistics, evidence validation, Markdown,
and SVG generation are orchestration tasks; C++ remains because NanoTS exposes
a C++ API and all three engines must be timed from one native runner.

## Expanded matrix

The original 45 workload/engine groups remain unchanged and comparable. The
matrix expands to 99 groups and 495 measurements across five repetitions:

- scalar append at the three existing durability windows and eight-series
  append, plus a public-API 4,096-point batch workload;
- warm copied queries at widths 1, 10, 100, 1,000, and 10,000 for every engine,
  plus Chronotail compressed equivalents;
- equivalent count/min/max/sum/first/last aggregates at widths 100, 10,000, and
  full-series for every engine, plus Chronotail compressed equivalents;
- concurrent reader/writer scaling at 1, 2, 4, 8, 16, and 32 readers;
- raw/compressed storage across constant, smooth, spiky, and random values.

All original timing boundaries, seeds, data, durability caveats, warm-cache
policy, public APIs, result consumption, verification, and engine-order rotation
remain. New workloads are labeled explicitly. Chronotail-only compressed rows
are never used for raw competitor ratios.

## Publication and visuals

Publication occurs only after the exact matrix, run IDs, finite metrics, and
result uniqueness validate. Each archived run contains environment and source
fingerprints, commands, raw JSONL, summary CSV, a self-contained report, and
source SVG charts. `LATEST`, root `BENCHMARKS.md`, README assets, and README
numbers update only through explicit publish.

Charts use a dark Astral-inspired system: deep aubergine background, off-white
text, chartreuse Chronotail, violet NanoTS, cyan SQLite, subtle grid lines,
fixed value gutters, visible units, min–max whiskers, and accessible
`title`/`desc` metadata. The report adds latency, durability, scaling,
variability, and measured-loss views without hiding exact tables. PNG assets and
their generation/checks disappear.

## Documentation architecture

README becomes a short product entrance with runnable examples, current public
results, and a documentation map. New task-oriented guides cover getting
started, durability/recovery, and v6 migration. API documents gain complete
lifecycle, buffer, ownership, error, and build examples. Architecture explains
the persistent graph and read/write paths. The pitch/rethink/profile/optimization
material is consolidated into current design and performance-engineering guides.
Version 1 remains only where history, migration, or archived evidence requires
it; release history and raw historical benchmark directories remain untouched.

## Boundaries

- No changes under `src/`, `include/`, or `python/src/`.
- No production behavior, format, ABI, or dependency changes.
- No deletion or rewriting of historical results or rejected experiments.
- No claim that Chronotail fsync, NanoTS msync, and SQLite WAL FULL have identical
  power-loss semantics.
- No v1-to-v2 speedup claim from differently loaded, non-alternating runs.
