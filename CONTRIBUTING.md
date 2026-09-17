# Contributing

Chronotail keeps a deliberately small scope: one embedded engine, one writer,
immutable reader snapshots, and no production runtime dependencies. Start with
the [documentation map](docs/index.md), [architecture](docs/architecture.md),
and the API guide for the surface you plan to change.

## Development setup

The validated development host is macOS ARM64 with Zig 0.15.2.

```bash
zig version
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
```

Before handing off a change, verify formatting:

```bash
zig fmt --check build.zig src sim tests tools bench
```

## Correctness gates

Add the smallest focused regression test that proves the new behavior. Changes
to the engine, format, recovery, checksums, or durability must also exercise the
deterministic simulator:

```bash
zig build simulator -Doptimize=ReleaseFast
./zig-out/bin/chronotail-sim --seeds 100
```

Use 1,000 seeds before release work. The simulator injects crashes, short and
failed writes, truncation, and corruption through the same compile-time engine
used by production.

Interface changes require their matching checks:

```bash
zig build -Doptimize=ReleaseFast
python3 -m py_compile clients/python/src/chronotail/__init__.py
CHRONOTAIL_LIBRARY="$PWD/zig-out/lib/libchronotail.dylib" \
PYTHONPATH="$PWD/clients/python/src" \
python3 -m unittest discover clients/python/tests
export CGO_LDFLAGS="-L$PWD/zig-out/lib"
export DYLD_LIBRARY_PATH="$PWD/zig-out/lib"
go vet ./clients/go/...
go test ./clients/go/...
python3 scripts/check-release.py
```

Run `./scripts/build-release.sh` only when the complete release artifact and its
isolated smoke test are in scope.

## Engineering policy

- Treat format v7 and C ABI v2 as the current major boundaries. Format v6 and
  C ABI v1 remain frozen on the 1.x maintenance line.
- Keep v6 support read-only and migration-only; never rewrite a v6 source file
  in place.
- Do not weaken authentication, semantic validation, durability order, bounded
  recovery, or simulator invariants.
- Derive limits from format widths, file size, page geometry, or caller-owned
  buffers. Avoid hidden unbounded work.
- Keep prepared append and query paths allocation-free after setup.
- Prefer removing work to adding caching, dispatch, or background state.
- Keep production runtime dependencies at zero.
- Keep generated databases, vendor trees, profiles, build output, and local
  benchmark results out of version control unless they are an intentional
  published evidence archive.

## Performance work

Use the internal profiler while developing:

```bash
zig build performance -Doptimize=ReleaseFast -- \
  --output tests/performance/results/candidate.jsonl
python3 tests/performance/compare.py \
  tests/performance/results/v1-baseline.jsonl \
  tests/performance/results/candidate.jsonl
```

Record rejected experiments and disclosed regressions. A speedup does not
justify weaker invariants, less validation, or a new production dependency.

The competitive suite is publication evidence, not the inner development loop:

```bash
python3 bench/competitive/bench.py run --publish
```

It must use public APIs, pinned dependencies, the declared matrix, complete
result consumption, and post-run database verification. Do not silently change
historical workloads, timing boundaries, durability caveats, or archived runs.

## Pull requests

Explain the responsibility or invariant being changed, list exact verification
commands and results, and include focused before/after evidence when performance
is affected. Keep behavior changes separate from unrelated documentation,
packaging, and cleanup whenever practical.
