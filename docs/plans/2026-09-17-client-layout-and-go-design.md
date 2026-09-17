# Client layout and Go binding design

## Goal

Give Chronotail one obvious home for language clients, add an idiomatic Go
client over C ABI v2, and publish complete usage and API documentation for Zig,
C, Python, and Go without changing the storage engine or file format.

## Repository layout

```text
clients/
├── README.md
├── go/
│   ├── README.md
│   ├── chronotail.go
│   ├── errors.go
│   ├── native.go
│   └── chronotail_test.go
├── python/
│   ├── README.md
│   ├── pyproject.toml
│   └── src/chronotail/
├── c/README.md
└── zig/README.md

docs/clients/
├── index.md
├── go.md
├── python.md
├── c.md
└── zig.md
```

The root `go.mod` makes `github.com/hamzaplojovic/chronotail/clients/go` a
normal import path and keeps the canonical `include/chronotail.h` inside the Go
module. The Python package moves as a unit from `python/` to `clients/python/`.
C and Zig keep their canonical implementation paths; their `clients/`
directories are navigation entry points rather than duplicate sources.

## Go API

The package name is `chronotail`. `OpenWriter` returns a `Writer` configured
with an explicit `Codec`. `Prepare`, `Append`, `Checkpoint`, and idempotent
`Close` map directly to bounded C ABI operations. `OpenReader` returns a stable
snapshot with `Refresh`, `Range`, `RangeInto`, `Aggregate`, `PrepareSeries`,
`Cursor`, and `BorrowRawPage`.

`Range` is the ergonomic allocating operation. `RangeInto` and cursor iteration
are the bounded alternatives and report required or copied counts explicitly.
A prepared `Series`, `Cursor`, or `RawPage` retains its owning reader and becomes
invalid when that reader refreshes or closes. The native library also validates
the generation. Borrowed slices alias mapped native memory and are read-only by
contract.

The package creates no goroutines and adds no third-party dependency. Handles
are not safe for concurrent method calls. Multiple independent readers may be
used concurrently, matching the engine's single-writer/multiple-reader model.

## Errors and validation

Native failures become `*StatusError` with the stable numeric C status and
native message. `errors.Is` can match exported status sentinels. Go-side shape
errors cover invalid codecs or durability values, empty paths/series names,
unequal batch or output buffer lengths, nonpositive preparation bounds, and
use-after-close. `CT_BUFFER_TOO_SMALL` is a sizing result in `RangeInto`, not a
failure.

The wrapper checks sizes before converting Go lengths to C `size_t`, keeps Go
slices alive across cgo calls, and never lets C retain a Go pointer. `Close`
consumes the native handle even if native teardown reports an error.

## Build and distribution

Development builds use the repository's canonical header and a ReleaseFast
`libchronotail`. Consumers must make that native library visible to the linker
and dynamic loader; the validated target remains macOS ARM64. The release
archive includes the Go source/module alongside the header and native
libraries, while Python continues to ship as a self-contained wheel.

Release scripts and smoke tests will build and execute a standalone Go program
from the packaged artifact. Python build paths will be updated atomically with
the source move so wheel contents and import names remain unchanged.

## Documentation

Each client guide includes installation, a complete write/read example,
ownership and close behavior, durability, concurrency, error handling,
allocation behavior, compatibility, and an API reference. Client-local READMEs
provide short setup instructions and point to the canonical guides under
`docs/clients/`.

## Verification

- `go test ./clients/go` against the freshly built native library.
- Python syntax, wheel, and live C-ABI round-trip after the directory move.
- Header compile/link smoke test and packaged Go consumer smoke test.
- Zig formatting plus Debug, ReleaseSafe, and ReleaseFast tests.
- Release policy, documentation-link, checksum, and isolated artifact checks.
- Deterministic simulation only if implementation or persistence code changes;
  this design intentionally changes neither.

## Alternatives rejected

- A nested Go module under `clients/go` cannot consume the repository's sibling
  canonical header when downloaded as a module without copying ABI declarations.
- Copying or generating a private Go header creates another synchronization
  boundary for C ABI v2.
- Moving `include/` or production Zig sources under `clients/` confuses public
  language packages with the engine and destabilizes existing native builds.
