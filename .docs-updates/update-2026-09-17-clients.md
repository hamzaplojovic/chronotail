# Documentation update summary — client layout and Go binding

## Scope and preservation

The client documentation, repository entry points, contributor workflow,
release notes, packaging scripts, and accepted design were reviewed against the
actual C ABI v2 header and live Go/Python bindings.

The architecture, durability, migration, benchmark methodology, historical
release records, TigerStyle rationale, and format-v6 compatibility warnings
were not rewritten. Existing Zig, C, and Python usage guidance was moved and
extended rather than replaced.

## Changes

- Added a client index under `clients/` and canonical documentation navigation
  under `docs/clients/`.
- Moved the Python package from `python/` to `clients/python/` while preserving
  package name, import name, wheel contents, ABI checks, and runtime behavior.
- Added a Go guide covering installation, linking, writing, snapshots, bounded
  reads, prepared series, cursors, borrowed raw pages, refresh invalidation,
  concurrency, errors, and the complete public API.
- Extended the Python, C, and Zig guides with explicit API reference tables and
  ownership/allocation guidance.
- Updated README, getting started, contributor commands, release scripts,
  release validation, and release notes for the new paths and Go client.
- Advanced package metadata to 2.1.0 unreleased so new artifacts cannot collide
  with the already-published 2.0.0 release.
- Recorded the root-module decision and rejected header-duplication approaches
  in `docs/plans/2026-09-17-client-layout-and-go-design.md`.

## Verified implementation mapping

- Go API declarations map only to symbols present in `include/chronotail.h`.
- Go native status values match C ABI v2 and support `errors.Is` matching.
- cgo includes the canonical header rather than a private copy.
- No Go pointer is retained by C; borrowed page slices point from Go into
  snapshot-owned native mappings with an explicit refresh/close lifetime.
- Python wheel construction reads from `clients/python` but retains the
  top-level `chronotail` import and bundled `_native` library.
- Release archives retain `include/`, add the root Go module and `clients/`, and
  smoke-test real Python and Go consumers.

## Validation results

- Go format, vet, unit, integration, and packaged-consumer tests passed.
- Python syntax, source import, standard-library integration, wheel build, and
  packaged round trip passed.
- The C example compiled with warnings as errors and ran both from the checkout
  and the extracted archive.
- Zig formatting and Debug, ReleaseSafe, and ReleaseFast tests passed.
- Release metadata, all 33 current-document links, artifact checksums, and the
  isolated 2.1.0 archive smoke test passed.

No persistence or engine implementation changes are part of this work, so a
new deterministic simulator campaign is not required by the contributor rules.
