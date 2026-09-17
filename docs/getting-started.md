# Getting started

This guide takes a fresh checkout through a durable write and a snapshot read.
Chronotail currently targets macOS ARM64 and requires Zig 0.15.2 to build from
source.

## Build

```bash
git clone https://github.com/hamzaplojovic/chronotail.git
cd chronotail
zig build -Doptimize=ReleaseFast
zig build test -Doptimize=ReleaseFast
```

The build installs these local artifacts:

```text
zig-out/bin/chronotail
zig-out/lib/libchronotail.a
zig-out/lib/libchronotail.dylib
zig-out/include/chronotail.h
```

## Command line

Append creates the database when needed. The default codec is adaptive
compression; pass `raw` when direct raw-page borrowing matters more than space.

```bash
./zig-out/bin/chronotail append metrics.ctdb cpu 1000 42.5
./zig-out/bin/chronotail append metrics.ctdb cpu 1001 43.1
./zig-out/bin/chronotail range metrics.ctdb cpu 0 2000
```

Expected range output:

```text
1000 42.5
1001 43.1
```

Inspect the committed snapshot and then run full structural verification:

```bash
./zig-out/bin/chronotail inspect metrics.ctdb
./zig-out/bin/chronotail verify metrics.ctdb
```

`inspect` reports series, records, pages, checkpoints, codec use, sizes, and
timestamp bounds. `verify` authenticates and semantically validates every
reachable object; success starts with `OK: committed state valid`.

## Python

Build the native library first, then point the binding at it while developing:

```bash
export CHRONOTAIL_LIBRARY="$PWD/zig-out/lib/libchronotail.dylib"
python3 -m pip install -e clients/python
```

Write arrays in batches and request disk durability explicitly:

```python
from array import array
import chronotail

timestamps = array("q", [1000, 1001, 1002])
values = array("d", [42.5, 43.1, 42.8])

with chronotail.Writer("metrics.ctdb", codec="compressed") as writer:
    writer.prepare("cpu", len(timestamps))
    writer.append("cpu", timestamps, values)
    writer.checkpoint(fsync=True)

with chronotail.Reader("metrics.ctdb") as reader:
    print(reader.range("cpu", 1000, 1002))
    print(reader.aggregate("cpu", 1000, 1002))
```

The writable `array('q')` and `array('d')` inputs take the binding's direct
buffer path. Other iterables are accepted and converted into native batches.

## Go

The Go client requires cgo and links the native library built above:

```bash
export CGO_LDFLAGS="-L$PWD/zig-out/lib"
export DYLD_LIBRARY_PATH="$PWD/zig-out/lib"
go test ./clients/go/...
```

Import the major-version-2 module path and use explicit durability:

```go
package main

import (
    "log"

    chronotail "github.com/hamzaplojovic/chronotail/v2/clients/go"
)

func main() {
    writer, err := chronotail.OpenWriter("metrics.ctdb", chronotail.CodecCompressed)
    if err != nil {
        log.Fatal(err)
    }
    if err := writer.Prepare("cpu", 3); err != nil {
        log.Fatal(err)
    }
    if err := writer.Append("cpu", []int64{1000, 1001, 1002}, []float64{42.5, 43.1, 42.8}); err != nil {
        log.Fatal(err)
    }
    if err := writer.Checkpoint(chronotail.DurabilityDisk); err != nil {
        log.Fatal(err)
    }
    if err := writer.Close(); err != nil {
        log.Fatal(err)
    }

    reader, err := chronotail.OpenReader("metrics.ctdb")
    if err != nil {
        log.Fatal(err)
    }
    defer reader.Close()
    points, err := reader.Range("cpu", 1000, 1002)
    if err != nil {
        log.Fatal(err)
    }
    log.Print(points)
}
```

Use `RangeInto` or `Cursor` instead of `Range` when query memory must be
caller-bounded.

## Zig

Import the `chronotail` module from `build.zig`, then use caller-owned buffers
for predictable query memory:

```zig
const std = @import("std");
const chronotail = @import("chronotail");

pub fn example(allocator: std.mem.Allocator) !void {
    var writer = try chronotail.Appender.open(
        allocator,
        "metrics.ctdb",
        .compressed,
    );
    var writer_closed = false;
    defer if (!writer_closed) writer.abort();

    try writer.prepareSeries("cpu", 3);
    try writer.appendBatch(
        "cpu",
        &.{ 1000, 1001, 1002 },
        &.{ 42.5, 43.1, 42.8 },
    );
    try writer.checkpointWithDurability(.disk);
    try writer.close();
    writer_closed = true;

    var reader = try chronotail.Reader.open(allocator, "metrics.ctdb");
    defer reader.close();
    const cpu = try reader.prepare("cpu");
    var timestamps: [16]i64 = undefined;
    var values: [16]f64 = undefined;
    const count = try reader.rangePreparedInto(
        cpu,
        1000,
        1002,
        &timestamps,
        &values,
    );
    std.debug.assert(count == 3);
}
```

Use `Appender.create` when the target must not already exist. `Appender.open`
opens or creates an append target according to the engine's normal file rules.

## Core rules

- Timestamps must be strictly increasing within each series.
- Exactly one writer may own a database; any number of readers may hold
  committed snapshots.
- Readers do not see new checkpoints until `refresh()` adopts a newer complete
  generation.
- Closing a healthy writer publishes pending data with memory durability. Call
  a disk-durable checkpoint when power-loss persistence is required.
- Chronotail has no update, delete, retention, SQL, server, or replication
  layer.

Continue with [durability and recovery](durability.md), then choose the
[Go](clients/go.md), [Python](clients/python.md), [C](clients/c.md), or
[Zig](clients/zig.md) client guide.
