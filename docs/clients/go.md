# Go client

The Go client is an idiomatic, dependency-free wrapper over Chronotail C ABI
v2. It starts no goroutines and keeps native ownership explicit. The validated
target is macOS ARM64 with cgo enabled.

## Install and link

Import the package from the repository module:

```bash
go get github.com/hamzaplojovic/chronotail/v2@v2.1.0
```

```go
import chronotail "github.com/hamzaplojovic/chronotail/v2/clients/go"
```

The canonical C header ships in the module, while `libchronotail` is a native
release artifact. During repository development:

```bash
zig build -Doptimize=ReleaseFast
CGO_LDFLAGS="-L$PWD/zig-out/lib" \
DYLD_LIBRARY_PATH="$PWD/zig-out/lib" \
go test ./clients/go
```

For the 2.1.0 release archive, add its `lib/` directory to `CGO_LDFLAGS` at
build time and to `DYLD_LIBRARY_PATH` at execution time. The module contains
the canonical header; the archive contains the native library. The package
checks `ct_abi_version() == 2` before opening a handle.

## Write ordered batches

```go
package main

import (
    "log"

    chronotail "github.com/hamzaplojovic/chronotail/v2/clients/go"
)

func main() {
    writer, err := chronotail.OpenWriter(
        "metrics.ctdb",
        chronotail.CodecCompressed,
    )
    if err != nil {
        log.Fatal(err)
    }
    defer writer.Close()

    timestamps := []int64{1_000, 1_001, 1_002}
    values := []float64{42.5, 43.1, 42.8}

    if err := writer.Prepare("cpu", len(timestamps)); err != nil {
        log.Fatal(err)
    }
    if err := writer.Append("cpu", timestamps, values); err != nil {
        log.Fatal(err)
    }
    if err := writer.Checkpoint(chronotail.DurabilityDisk); err != nil {
        log.Fatal(err)
    }
}
```

`Prepare` declares the maximum points for that series before the next
checkpoint and keeps the engine append path allocation-free within the bound.
`Append` validates the complete batch before mutation. Equal nonzero slice
lengths and strict per-series timestamp order are required.

`DurabilityMemory` publishes to new readers without promising a power-loss
boundary. `DurabilityDisk` performs ordered data-sync-root-sync publication.
`Close` publishes healthy pending state, consumes the native handle, and is
idempotent. Explicitly checkpoint before acknowledging durable writes.

## Read a snapshot

```go
reader, err := chronotail.OpenReader("metrics.ctdb")
if err != nil {
    log.Fatal(err)
}
defer reader.Close()

points, err := reader.Range("cpu", 1_000, 2_000)
if err != nil {
    log.Fatal(err)
}
summary, err := reader.Aggregate("cpu", 1_000, 2_000)
if err != nil {
    log.Fatal(err)
}

for _, point := range points {
    log.Printf("%d %.2f", point.Timestamp, point.Value)
}
log.Printf("count=%d min=%f max=%f sum=%f", summary.Count,
    summary.Minimum, summary.Maximum, summary.Sum)
```

`Range` allocates exactly sized timestamp, value, and point slices. Aggregates
return count, minimum, maximum, sum, first, and last without materializing
points. Empty aggregates have count and sum zero and NaN for the other values.

## Bounded reads

Use equal-length caller buffers when allocations must be bounded:

```go
timestamps := make([]int64, 4096)
values := make([]float64, 4096)
required, err := reader.RangeInto("cpu", start, end, timestamps, values)
if err != nil {
    log.Fatal(err)
}
copied := min(required, len(timestamps))
consume(timestamps[:copied], values[:copied])
if required > len(timestamps) {
    log.Printf("range truncated: need %d points", required)
}
```

For progressive bounded work, create a cursor:

```go
cursor, err := reader.Cursor("cpu", start, end)
if err != nil {
    log.Fatal(err)
}
timestamps := make([]int64, 4096)
values := make([]float64, 4096)
for !cursor.Complete() {
    count, _, err := cursor.NextInto(timestamps, values)
    if err != nil {
        log.Fatal(err)
    }
    consume(timestamps[:count], values[:count])
}
```

## Prepared series and raw pages

Resolve a name once for repeated queries:

```go
cpu, err := reader.PrepareSeries("cpu")
if err != nil {
    log.Fatal(err)
}
summary, err := cpu.Aggregate(start, end)
points, err := cpu.Range(start, end)
```

`Series.BorrowRawPage` exposes zero-copy slices only when both stored columns
are raw:

```go
page, err := cpu.BorrowRawPage(timestamp)
if errors.Is(err, chronotail.ErrPageNotRaw) {
    // Fall back to Range or RangeInto.
}
```

Borrowed slices alias immutable mapped memory. Treat them as read-only and
discard them before `Reader.Refresh` or `Reader.Close`. The Go runtime cannot
revoke a slice already copied by application code.

## Refresh and concurrency

Readers retain one immutable generation until explicitly refreshed:

```go
changed, err := reader.Refresh()
if changed {
    cpu, err = reader.PrepareSeries("cpu")
}
```

A changed refresh invalidates prepared `Series`, `Cursor`, and `RawPage`
values. The wrapper detects stale series and cursors before entering C; the
native generation check remains authoritative.

One writer and multiple independent readers may operate concurrently. A single
`Writer`, `Reader`, `Series`, or `Cursor` is not safe for concurrent method
calls. The client adds no locks or background goroutines.

## Error handling

Native failures are `*chronotail.StatusError` values with stable numeric ABI
codes. Match exported sentinels through `errors.Is`:

```go
if err := writer.Append("cpu", timestamps, values); err != nil {
    switch {
    case errors.Is(err, chronotail.ErrTimestampOrder):
        // Correct the input; validation errors do not poison the writer.
    case errors.Is(err, chronotail.ErrPoisonedWriter):
        // Close/abort this writer and investigate the operational failure.
    default:
        return err
    }
}
```

Go-side validation errors such as `ErrMismatchedLengths`, `ErrInvalidCodec`,
and `ErrClosed` do not enter the native library.

## API reference

### Package

| API | Contract |
|---|---|
| `ABIVersion() uint32` | Returns the loaded native C ABI version. |
| `OpenWriter(path, codec)` | Opens or creates a writer; fails if another writer owns the file lock. |
| `OpenReader(path)` | Opens and validates the newest complete snapshot. |

### Writer

| Method | Contract |
|---|---|
| `Prepare(series, maximum)` | Reserves a bounded append path until checkpoint. |
| `Append(series, timestamps, values)` | Submits one fully validated ordered batch without retaining Go memory. |
| `Checkpoint(durability)` | Publishes pending points with memory or disk durability. |
| `Close()` | Publishes healthy state, consumes the handle, and is idempotent. |

### Reader

| Method | Contract |
|---|---|
| `Range(series, start, end)` | Returns allocated `[]Point` for an inclusive range. |
| `RangeInto(series, start, end, timestamps, values)` | Copies a prefix and returns total required capacity. |
| `Aggregate(series, start, end)` | Returns `Aggregate` without copying points. |
| `PrepareSeries(series)` | Returns a generation-bound `Series`. |
| `Cursor(series, start, end)` | Returns a bounded persistent range cursor. |
| `Refresh()` | Adopts a newer complete generation and reports whether it changed. |
| `Close()` | Releases the mapping and invalidates borrowed state. |

### Series and cursor

| Method | Contract |
|---|---|
| `Series.Range` / `RangeInto` | Prepared equivalents of reader range operations. |
| `Series.Aggregate` | Prepared aggregate lookup. |
| `Series.BorrowRawPage` | Returns snapshot-owned read-only slices or a typed status error. |
| `Cursor.NextInto` | Copies the next bounded chunk and reports completion. |
| `Cursor.Complete` | Reports whether iteration has ended. |

### Values

- `CodecRaw`, `CodecCompressed`
- `DurabilityMemory`, `DurabilityDisk`
- `Point{Timestamp, Value}`
- `Aggregate{Count, Minimum, Maximum, Sum, First, Last}`
- `RawPage{Timestamps, Values, TimestampMin, TimestampMax}`
- `StatusError{Code, Message}` and the exported `Err…` sentinels

Go does not currently expose full-file verification or format-v6 migration;
use the Chronotail CLI or Zig API for those administrative operations.
