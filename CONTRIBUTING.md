# Contributing

Chronotail keeps a deliberately small scope and a frozen v1 storage/ABI boundary. Start with `AGENTS.md`, `docs/architecture.md`, and the relevant API document.

## Development setup

Install Zig 0.15.2 on macOS ARM64, then run:

```bash
zig fmt --check build.zig src sim tests tools bench
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
```

Engine, format, recovery, or persistence changes also require deterministic simulation:

```bash
zig build simulator -Doptimize=ReleaseFast
./zig-out/bin/chronotail-sim --seeds 100
```

Use 1,000 seeds before a release.

## Change policy

- Do not change format v6 or C ABI v1 in a normal v1 contribution.
- Add a corruption or regression test before changing validation or recovery.
- Keep production runtime dependencies at zero.
- Keep benchmark datasets, timing boundaries, and competitor settings unchanged.
- Include focused before/after evidence for performance changes and retain changes only when correctness and measurement agree.
- Keep generated databases, build output, profiles, vendor trees, and caches out of the repository.

## Pull requests

Explain the invariant or responsibility being changed, list exact verification commands, and include relevant benchmark evidence. Separate behavior changes from documentation, packaging, and cleanup whenever possible.
