# Chronotail 1.0.0

Chronotail 1.0.0 is the first stable release of the embedded, append-only time-series engine.

## Stable boundaries

- `.ctdb` file format v6 is frozen and portable across supported architectures.
- C ABI v1 is frozen and exports nine `ct_*` symbols.
- The Zig facade, CLI behavior, and Python API are stable for the v1 series.
- Existing v6 databases written by the development releases remain readable and writable.

The frozen source manifest is recorded in
[`docs/releases/v1.0.0-engine.sha256`](docs/releases/v1.0.0-engine.sha256).

## Release artifacts

The v1 release supports macOS ARM64 only. `chronotail-1.0.0-macos-aarch64.tar.gz` contains checksums, the native CLI, static and dynamic C libraries, the public header, API documentation, and a `macosx_11_0_arm64` dependency-free wheel.

## What ships

- Multiple named series in one `.ctdb` file.
- Raw and adaptive Gorilla-style block encoding.
- Batched timestamp/value appends.
- Durable append-only checkpoints with optional `fsync`.
- Immutable reader snapshots and explicit refresh.
- Checksummed blocks, structural validation, recovery from incomplete tails, and an independent verifier.
- Dependency-free C and Python runtime bindings.
- Deterministic crash, short-write, failed-write, truncation, and corruption simulation.

## Validation

The release candidate passed Debug, ReleaseSafe, and ReleaseFast tests; C and Python integration tests; artifact-only smoke tests; byte-identical v6 format checks; and 1,000 deterministic simulator seeds covering 100,000,000 operations with zero invariant failures.

The canonical competitive matrix contains 225 measurements across 45 engine/workload groups with five repetitions each. It is archived under `bench/results/20260917-105244/`. The host carried unrelated background load, which is disclosed in `BENCHMARKS.md`; use same-run competitor ratios rather than comparing its absolute rates with older runs.

## Known limitations

- One writer is allowed per database; readers are concurrent and lock-free against committed snapshots.
- Timestamps within a series must be strictly increasing.
- There is no in-place update, delete, retention policy, replication, or network server.
- Compressed queries trade CPU for storage efficiency.
- Platforms other than macOS ARM64 are not supported in v1.0.0.
- Cold-cache benchmark numbers are omitted because reliable eviction on the benchmark macOS host requires privileged global cache purging.
