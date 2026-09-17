# Chronotail contributor guidance

Chronotail is a dependency-free embedded time-series engine for strictly ordered timestamped data.

## Version boundaries

- Preserve `.ctdb` format v6 and C ABI v1 on the v1 maintenance line.
- V2 uses format v7 and C ABI v2 on the `v2` branch; v6 is read only through
  explicit migration and is never rewritten in place.
- Preserve public Zig, C, Python, and CLI behavior within each stable major line.
- Do not weaken checksums, structural validation, durability, recovery, or simulator invariants.
- Do not add runtime dispatch or third-party runtime dependencies to production paths.
- Version 1.0.0 supports macOS ARM64 only; v2 adds no platform claim without
  native artifact validation.

## Engineering rules

- Prefer removing work over making work more complicated.
- Keep data-plane append and query paths allocation-free after open.
- Derive bounds from format widths, file size, block geometry, or caller-provided buffers.
- Keep integer domains explicit at persistent boundaries.
- Run `zig fmt` and all three test modes before release work.
- Run deterministic simulation after engine or persistence changes.
- Benchmark through public APIs and preserve the pinned competitive methodology.
- Record rejected performance experiments; never keep a regression hidden.
