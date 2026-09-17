# Chronotail

**A small embedded time-series engine for ordered timestamped data.**

Chronotail stores multiple named series in one portable `.ctdb` file. It has no server, SQL layer, background threads, or runtime dependencies. One writer appends data while readers query immutable committed snapshots.

> **v2.0.0 development branch** · file format **v7** · C ABI **v2** · macOS ARM64

<p align="center"><img src="docs/assets/architecture.png" alt="Chronotail architecture" width="900"></p>

## Why Chronotail

- **Predictable storage:** immutable 64 KiB columnar pages, copy-on-write indexes, and bounded root election.
- **Fast reads:** mmap snapshots, prepared series, persistent cursors, raw-page views, and summary aggregates.
- **Safe failure model:** BLAKE3 identities, strict semantic validation, rotating roots, and independent verification.
- **Concurrent snapshots:** one writer and any number of readers without reader/writer locking.
- **Small integration surface:** native Zig API, C ABI v2, Python bindings, a CLI, and no runtime dependencies.
- **Portable database files:** format v7 uses explicit little-endian integer domains and no native structs.

## Install

Chronotail v2 is under development on this branch. Build it with Zig 0.15.2:

```bash
zig build -Doptimize=ReleaseFast
zig build test
```

The released v1.0.0 artifacts remain available for users who need the frozen
format-v6/C-ABI-v1 line. V2 never rewrites a v6 database in place; use
`chronotail migrate-v6 old.ctdb new.ctdb` to create and verify a separate v7 file.

## Quick start

```bash
chronotail append metrics.ctdb cpu 1000 42.5
chronotail append metrics.ctdb cpu 1001 43.1
chronotail range metrics.ctdb cpu 0 2000
chronotail verify metrics.ctdb
chronotail inspect metrics.ctdb
```

```text
1000 42.5
1001 43.1
OK: committed state valid
```

Python batches can use `array` for a zero-copy binding path:

```python
from array import array
import chronotail

with chronotail.Writer("metrics.ctdb", codec="compressed") as db:
    db.append("cpu", array("q", [1002, 1003]), array("d", [43.4, 43.8]))
    db.checkpoint(fsync=True)

with chronotail.Reader("metrics.ctdb") as db:
    print(db.range("cpu", 0, 2000))
```

## V1 performance baseline

These numbers are the immutable v1/format-v6 baseline, not v2 claims. The
unchanged public competitive suite will be rerun only after the v2 internal
profiling and release gates pass.

The canonical v1 suite contains 225 measurements across Chronotail, NanoTS, and SQLite: 45 workload/engine groups, five repetitions each. All engines receive identical points, public APIs only are timed, results are consumed, and complete databases are validated.

| Workload | Chronotail | vs NanoTS | vs SQLite |
|---|---:|---:|---:|
| Warm random point lookup | 1.88M queries/s | 2.14× | 8.96× |
| Warm raw 100-point range | 1.23M queries/s | 23.32× | 27.47× |
| 32-reader aggregate while writing | 8.34M queries/s | 189.85× | 37.31× |
| Eight-series append | 14.37M records/s | 2.16× | 20.06× |

The benchmark host carried unrelated background load. Same-run competitor ratios are valid; absolute rates are not a clean comparison with older runs. Append durability primitives also differ, so the project does not claim equivalent power-loss semantics across Chronotail `fsync`, NanoTS `msync`, and SQLite WAL FULL. See [BENCHMARKS.md](BENCHMARKS.md) for complete tables, latency distributions, storage results, methodology, and caveats.

### Append throughput

<p align="center"><img src="docs/assets/benchmark-append.png" alt="Append throughput comparison" width="900"></p>

### Query throughput

<p align="center"><img src="docs/assets/benchmark-query.png" alt="Query throughput comparison" width="900"></p>

### Concurrent readers

<p align="center"><img src="docs/assets/benchmark-concurrency.png" alt="Concurrent reader throughput comparison" width="900"></p>

<p align="center"><img src="docs/assets/benchmark-concurrent-writer.png" alt="Writer throughput under reader load" width="900"></p>

### Storage efficiency

<p align="center"><img src="docs/assets/benchmark-storage.png" alt="Storage efficiency comparison" width="900"></p>

## Durability and snapshots

Chronotail is single-writer/multiple-reader. A checkpoint writes immutable data
pages, copy-on-write index nodes, and a manifest before publishing one of four
checksummed root slots. Disk durability adds a sync before root publication and
a second sync after it. A reader sees one immutable generation until
`refresh()` adopts a newer complete root. Interrupted writes leave an older root
readable, and recovery examines a fixed 64 KiB control region rather than an
arbitrary file tail.

External 128-bit BLAKE3 identities detect damaged or misdirected immutable
objects. Verification also checks bounds, object kinds, index ordering,
statistics, codecs, root succession, and strict timestamp order. A checksum
establishes byte identity; it never replaces semantic validation.

## APIs

- [Zig API](docs/api/zig.md)
- [C ABI v2](docs/api/c.md)
- [Python API](docs/api/python.md)
- [Architecture](docs/architecture.md)
- [V2 design and status](docs/plans/2026-09-17-v2-engine-design.md)
- [V2 one-line pitch](docs/v2-pitch.md)
- [V2 rethink report](docs/v2-rethink-report.md)
- [V2 internal performance report](docs/v2-performance-report.md)
- [Further optimization targets](docs/v2-optimization-opportunities.md)
- [V1 machine-model baseline](docs/performance/tigerstyle-machine-model.md)
- [Release notes](RELEASE_NOTES.md)

CLI commands:

```text
chronotail append  <file.ctdb> <series> <timestamp> <value> [raw|compressed]
chronotail range   <file.ctdb> <series> <start> <end>
chronotail verify  <file.ctdb>
chronotail inspect <file.ctdb>
chronotail migrate-v6 <source.ctdb> <target.ctdb> [raw|compressed]
```

`append` defaults to adaptive compression. The library APIs provide efficient batch append and caller-owned query buffers.

## Build, test, and release

```bash
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build simulator -Doptimize=ReleaseFast
./tools/benchmark.sh
./scripts/build-release.sh
```

The deterministic simulator injects crashes, short writes, failed writes,
truncation, and corruption into the same compile-time-specialized engine used
in production. The final v2 campaign executed 100,000,000 operations over 1,000
seeds with 1,934 crashes, 1,876 short writes, 1,877 failed writes, 5,970
truncations, 5,961 corruptions, 58,623 checkpoint/reopen cycles, and zero
invariant failures.

The release matrix is declared in `scripts/targets.sh`. V2 remains validated on
macOS ARM64 until additional target gates are completed.

## Scope

Chronotail is deliberately not a distributed database, server, query language,
mutable key/value store, or general analytics engine. Format v7 gives immutable
objects stable identities that a future replication layer can transfer and
repair, but v2 itself remains an embedded local engine.

## License

[MIT](LICENSE)
