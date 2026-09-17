# Zig API

Import `chronotail` and use the production `Appender` and `Reader` aliases.
They specialize the engine for `std.fs.File`; `AppenderFor(File)` and
`ReaderFor(File)` expose the compile-time storage seam used by simulation.

## Write a durable batch

```zig
const std = @import("std");
const chronotail = @import("chronotail");

pub fn write(allocator: std.mem.Allocator) !void {
    var writer = try chronotail.Appender.open(
        allocator,
        "metrics.ctdb",
        .compressed,
    );
    var closed = false;
    defer if (!closed) writer.abort();

    const timestamps = [_]i64{ 1_000, 1_001, 1_002 };
    const values = [_]f64{ 42.5, 43.1, 42.8 };

    try writer.prepareSeries("cpu", timestamps.len);
    try writer.appendBatch("cpu", &timestamps, &values);
    try writer.checkpointWithDurability(.disk);
    try writer.close();
    closed = true;
}
```

`Appender.create` requires a new path. `Appender.open` opens an existing v7
database or creates a new one. The writer holds an exclusive nonblocking file
lock; a second writer receives `error.WouldBlock`.

`appendBatch` validates equal lengths, the full batch's strict order, and the
existing series tail before mutation. Invalid input leaves the writer usable.
An operational failure during mutation poisons it; call `abort()` instead of
trying to checkpoint partial work.

`prepareSeries(name, maximum_points_before_checkpoint)` reserves the derived
page-descriptor bound. Appends to that prepared series allocate no heap memory
until the next checkpoint. Control-plane work such as new-series creation and
checkpoint construction may allocate.

## Read into caller-owned buffers

```zig
pub fn read(allocator: std.mem.Allocator) !void {
    var reader = try chronotail.Reader.open(allocator, "metrics.ctdb");
    defer reader.close();

    const cpu = try reader.prepare("cpu");
    var timestamps: [128]i64 = undefined;
    var values: [128]f64 = undefined;
    const required = try reader.rangePreparedInto(
        cpu,
        1_000,
        2_000,
        &timestamps,
        &values,
    );
    const copied = @min(required, timestamps.len);
    for (timestamps[0..copied], values[0..copied]) |timestamp, value| {
        std.debug.print("{d} {d}\n", .{ timestamp, value });
    }
    if (required > timestamps.len) return error.OutputTooSmall;
}
```

`rangeInto` resolves a series name on every call. `rangePreparedInto` accepts a
generation-bound `SeriesHandle`. Both copy the available prefix and return the
total required count; a return larger than the buffer length means the result
was truncated.

The timestamp and value buffers must have equal lengths. An inclusive range
with `end < start` is empty.

## Stream a large range

Use a persistent cursor when the result is intentionally processed in bounded
chunks:

```zig
var cursor = try reader.cursorPrepared(cpu, start, end);
var timestamps: [4096]i64 = undefined;
var values: [4096]f64 = undefined;

while (!cursor.complete) {
    const count = try reader.cursorNext(&cursor, &timestamps, &values);
    consume(timestamps[0..count], values[0..count]);
}
```

The cursor retains a fixed-height traversal stack and avoids repeating a
count-then-copy pass. It becomes stale after reader refresh.

## Borrow a raw page

```zig
const page = try reader.borrowRawPage(cpu, wanted_timestamp);
consume(page.timestamps, page.values);
```

Borrowing succeeds only when both page columns are raw, the host is
little-endian, and the reader uses a mapped production file. The slices are
owned by the reader snapshot and are valid only until `refresh()` or `close()`.
Handle `error.PageNotRaw`, `error.TimestampNotFound`, and
`error.BorrowedViewUnavailable` explicitly.

## Aggregate without copying points

```zig
const summary = try reader.aggregatePrepared(cpu, start, end);
std.debug.print("count={d} min={d} max={d} sum={d}\n", .{
    summary.count,
    summary.minimum,
    summary.maximum,
    summary.sum,
});
```

An `Aggregate` contains `count`, `minimum`, `maximum`, `sum`, `first`, and
`last`. Empty ranges have count and sum zero; the other fields are NaN.
Persistent tree summaries answer fully covered subtrees without decoding their
points.

For fixed timestamp windows:

```zig
var windows: [60]chronotail.Aggregate = undefined;
const required = try reader.aggregateWindowsPrepared(
    cpu,
    start,
    end,
    1_000, // timestamp units per window
    &windows,
);
```

The function fills the available prefix and returns the total required window
count. A zero resolution is invalid.

## Refresh a snapshot

```zig
if (try reader.refresh()) {
    // The previous handle, cursor, and borrowed slices are invalid now.
    cpu = try reader.prepare("cpu");
}
```

Prepared handles carry the reader generation and fail with
`error.StaleSeriesHandle` after refresh. `refresh()` returns `true` only after a
newer complete generation validates and is adopted.

## Inspect and verify

- `latestTimestamp(name)` returns the committed tail or `null` for an empty
  series.
- `codecCounts(name)` returns raw and encoded page counts.
- `profileRange(name, start, end)` exposes internal phase timings for local
  diagnosis, not a stable cross-machine benchmark.
- `verifyPath(allocator, path)` authenticates and semantically validates the
  complete committed object graph.
- `migrateV6(allocator, source, target, codec, durability)` verifies a v6
  snapshot while creating a separate v7 file.

See [durability and recovery](../durability.md) for checkpoint semantics and
[migration](../migration.md) for the operational format transition.

## API reference

### Writer

| API | Contract |
|---|---|
| `Appender.create` | Creates a new database and fails if the path exists. |
| `Appender.open` | Opens format v7 or creates a new database; v6 requires migration. |
| `prepareSeries` | Reserves bounded per-series append metadata until checkpoint. |
| `appendBatch` | Validates and appends equal-length ordered timestamp/value slices. |
| `checkpointWithDurability` | Publishes with `.memory` or `.disk`. |
| `close` | Publishes healthy pending state and releases the writer. |
| `abort` | Releases a poisoned or intentionally abandoned writer without publication. |

### Reader

| API | Contract |
|---|---|
| `Reader.open` | Opens and validates one immutable committed generation. |
| `prepare` | Returns a generation-bound `SeriesHandle`. |
| `rangeInto` / `rangePreparedInto` | Copies a prefix and returns total required points. |
| `cursor` / `cursorPrepared` / `cursorNext` | Performs bounded persistent range traversal. |
| `aggregate` / `aggregatePrepared` | Computes count/min/max/sum/first/last. |
| `aggregateWindowsPrepared` | Computes fixed-resolution inclusive windows. |
| `borrowRawPage` | Returns snapshot-owned raw slices when representation permits. |
| `refresh` | Adopts a newer complete generation and invalidates borrowed state. |
| `close` | Releases the snapshot and its mapping. |

### Administrative operations

| API | Contract |
|---|---|
| `verifyPath` | Authenticates and semantically validates the complete committed graph. |
| `migrateV6` | Creates and verifies a separate format-v7 file from format-v6 input. |
| `AppenderFor` / `ReaderFor` | Specializes the engine for an explicit compile-time storage implementation. |

The exported declarations in
[`src/chronotail.zig`](../../src/chronotail.zig) are authoritative for exact
types and error sets.
