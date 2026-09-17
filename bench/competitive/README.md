# Competitive benchmark suite

This directory builds and measures Chronotail, NanoTS, and SQLite in one C++ harness.

## Run

```bash
./bench/competitive/build.sh
python3 bench/competitive/run.py
```

A complete run takes substantial time and disk I/O. Results are written to a timestamped directory under `bench/results/`; `bench/results/LATEST` identifies the authoritative run.

Interrupted runs are resumable:

```bash
python3 bench/competitive/run.py --resume bench/results/<run-id>
```

`versions.env` pins NanoTS. `fetch.sh` verifies its checked-out commit. SQLite is built from NanoTS's pinned amalgamation, ensuring NanoTS and the standalone SQLite comparison use the same SQLite release. Chronotail is built locally with `ReleaseFast`.

The harness uses public APIs only, consumes query results, validates complete databases after every run, and emits one JSON object per measured result. `summarize.py` creates median tables, best/worst CSV columns, ratios, and dependency-free SVG charts. `scripts/generate-benchmark-assets.py <run-id>` regenerates the GitHub README charts from an archived summary.

See the root [`BENCHMARKS.md`](../../BENCHMARKS.md) for methodology, caveats, and current results.
