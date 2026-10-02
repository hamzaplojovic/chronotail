# Python API

The Python package requires Python 3.10 or newer and C ABI v2. The validated
release target is macOS ARM64; the wheel bundles `libchronotail.dylib` and has no
third-party runtime package dependency.

Install the wheel from the extracted release archive:

```bash
python3 -m pip install python/chronotail-2.2.0-py3-none-macosx_11_0_arm64.whl
```

## Temporal lookup

Temporal lookup is included in the 2.2 package with its matching native library:
earlier 2.1 wheels do not expose this API.

```python
from chronotail import LookupMode

with chronotail.Reader("metrics.ctdb") as reader:
    point = reader.lookup("pressure", observed_at, LookupMode.PREDECESSOR,
                          max_distance=1000)
    if point is not None:
        sample_timestamp, pressure = point
        display_observation(sample_timestamp, pressure)
    else:
        display_missing()
```

`LookupMode.EXACT` requires equality; predecessor/successor mean at or
before/after. `NEAREST` chooses the closer original sample, with predecessor
winning ties. The optional distance is inclusive in caller-defined timestamp
units: `None` is unrestricted; zero requires equality. Missing is `None`,
while zero-valued samples return a tuple. No interpolation or filling occurs.

Require a `LookupMode` member, signed-64-bit integer timestamp and optional
unsigned-64-bit integer distance. Booleans, floats, invalid enums and out-of-range
integers raise `ValueError` before ctypes narrowing. The maximum distance is
`2**64 - 1`, including the full min/max-i64 span. Timestamp and binary64 value
bits remain exact; results survive reader refresh/close.

`prepared = reader.prepare("pressure")` resolves an owner-bound `SeriesHandle`;
`reader.lookup_prepared(prepared, timestamp, mode, max_distance=...)` has identical
selection. A changed refresh stales handles; unchanged/failed refresh retains
them. Closed/stale/wrong-reader requests raise `ChronotailError` before lookup.
Unknown series and database failures are errors, even with tolerance zero.

The two native lookup symbols form one optional complete capability, independent
of streaming's three cursor symbols. Earlier ABI-v2 libraries, including 2.0,
still import and support existing APIs and `Reader.prepare`. When either lookup
symbol is absent, valid lookup calls raise clear `NotImplementedError`; there is
no range or cursor fallback. Argument domains and handle lifetimes are validated
before capability availability. See the [shared contract](../temporal-lookup-clients.md).

## Development install

```bash
zig build -Doptimize=ReleaseFast
export CHRONOTAIL_LIBRARY="$PWD/zig-out/lib/libchronotail.dylib"
python3 -m pip install -e clients/python
```

`CHRONOTAIL_LIBRARY` selects an explicit native library. Without it, the binding
looks in its bundled `_native` directory, beside the package, and in the local
project `zig-out/lib` directory. Import fails if the native ABI is not exactly
version 2.

## Write batches

```python
from array import array
import chronotail

timestamps = array("q", [1_000, 1_001, 1_002])
values = array("d", [42.5, 43.1, 42.8])

with chronotail.Writer(
    "metrics.ctdb",
    batch_size=4096,
    codec="compressed",
) as writer:
    writer.prepare("cpu", len(timestamps))
    writer.append("cpu", timestamps, values)
    writer.checkpoint(fsync=True)
```

`Writer.append` accepts either one integer/float pair or iterable batches.
Writable, one-dimensional `array('q')`/`array('d')` inputs take the binding's
direct buffer path; other iterables are materialized into native batches.
Lengths must match and timestamps must be strictly increasing within the
series.

`batch_size` controls binding-side submission chunks. `prepare` declares the
maximum native points before the next checkpoint and enables the engine's
allocation-free prepared append path.

`checkpoint(fsync=False)` publishes to memory. `fsync=True` requests
data-sync-root-sync disk durability. Leaving a healthy writer context flushes
buffered values and closes the writer; use an explicit durable checkpoint before
acknowledging data that must survive power loss.

## Read a snapshot

```python
with chronotail.Reader("metrics.ctdb") as reader:
    points = reader.range("cpu", 1_000, 2_000)
    summary = reader.aggregate("cpu", 1_000, 2_000)

print(points)
print(summary.count, summary.minimum, summary.maximum, summary.sum)
```

`Reader.range` returns a list of `(timestamp, value)` tuples. It grows native
buffers when the initial 1,024-point capacity is insufficient.

### Stream an inclusive range

Chronotail 2.2 includes
`Reader.iter_range(series, start, end, *, batch_size=1024)`. It streams individual
`(timestamp, value)` tuples in strictly increasing timestamp order using the
existing C ABI v2 stateful cursor. Earlier 2.1 wheels do not expose this Python API.

Streaming requires all three native stateful cursor symbols:
`ct_cursor_state_create`, `ct_cursor_state_next`, and `ct_cursor_state_destroy`.
They are an optional capability within C ABI v2. Earlier ABI-v2 libraries,
including 2.0.0, still support importing this package and using its existing
reader/writer APIs. If any stateful symbol is absent, `iter_range()` raises
`NotImplementedError` when called, before allocating native cursor state.
There is no rescanning fallback.

```python
from contextlib import closing

with chronotail.Reader("metrics.ctdb") as reader:
    with closing(reader.iter_range("cpu", 1_000, 1_000_000, batch_size=1379)) as points:
        for timestamp, value in points:
            process(timestamp, value)
            if should_stop():
                break
```

Both bounds are inclusive. Existing series with no matching points, or with
`end < start`, yield nothing. Missing series raise `ChronotailError` during
iteration, including for reversed ranges. `range()` retains its list return
shape and behavior.

The iterator reuses one timestamp buffer and one value buffer, each bounded by
`batch_size`; it does not allocate proportional to the selected history.
`batch_size` must be a positive Python integer, excluding booleans, that fits
native buffer sizes. Invalid sizes raise `ValueError` at `iter_range()` call
time. Buffers and cursor state are created lazily on the first `next()`; a buffer
allocation can raise `MemoryError`. Collecting the iterator into a list uses
memory proportional to the collected points.

Bounds must be Python integers, excluding booleans, within `-2**63` through
`2**63 - 1`; invalid bounds raise `ValueError`. Timestamps remain exact Python
integers, including above `2**53`. Values retain their stored binary64 bits as
Python floats, including signed zero, subnormals, infinities, and NaNs.

An iterator belongs to the reader snapshot when `iter_range()` is called.
Publishing a newer checkpoint does not change it. Refresh returning `True`
invalidates both started and unstarted iterators. Their next read raises
`ChronotailError`, including when points are already buffered for yielding.
Refresh returning `False`, or a failed refresh, leaves them valid. Create a new
iterator after a changed refresh, and keep its reader open; reader close also
makes the next iterator read raise `ChronotailError`.

Exhaustion, an iteration error, and `points.close()` release native cursor
state. Close a retained iterator when stopping early: `break` alone does not
close it. `contextlib.closing` provides deterministic cleanup, as in the example.
Closing an unstarted iterator creates no native state. Readers and iterators
are not safe for concurrent method calls.

`Reader.aggregate` returns an `Aggregate(count, minimum, maximum, sum, first,
last)` named tuple. Empty ranges have count and sum zero; minimum, maximum,
first, and last are NaN.

The reader holds one immutable generation. Adopt a newer complete checkpoint
explicitly:

```python
if reader.refresh():
    points = reader.range("cpu", 1_000, 2_000)
```

## Convenience functions

These constructors are equivalent to the classes:

```python
writer = chronotail.open("metrics.ctdb", batch_size=1000, codec="compressed")
reader = chronotail.read("metrics.ctdb")
```

Prefer context managers so native handles always close.

## Errors and current surface

Native failures raise `chronotail.ChronotailError` with the C status text and
number. Closed-reader and stale-iterator reads also raise `ChronotailError` with
a Python lifetime message. Python argument-shape errors such as an invalid codec,
invalid streaming batch size or bounds, or mismatched iterable lengths raise
`ValueError`.
Requesting `iter_range` with an ABI-v2 library missing the complete native
stateful cursor capability raises `NotImplementedError` at call time.
Valid `lookup`/`lookup_prepared` calls similarly raise `NotImplementedError`
when their independent complete native lookup pair is unavailable. Invalid
lookup mode/timestamp/distance domains raise `ValueError`; closed, stale and
wrong-reader prepared handles raise `ChronotailError` before capability checks.

Bounded streaming reads are available through `Reader.iter_range`.
`Reader.prepare` creates Python
prepared handles for `lookup_prepared`. Borrowed raw-page views,
fixed-resolution aggregate windows, full-file verification, and v6 migration
remain Zig/C/CLI facilities.

Python objects are not documented as safe for concurrent method calls. Use
independent readers in independent threads and keep one writer owner.

## API reference

### Module functions and values

| API | Contract |
|---|---|
| `open(path, *, batch_size=1000, codec="compressed")` | Convenience constructor for `Writer`. |
| `read(path)` | Convenience constructor for `Reader`. |
| `ABI_VERSION` | Native ABI required by this package; currently `2`. |
| `ChronotailError` | Native failure with status text and numeric code. |
| `Aggregate` | Named tuple containing `count`, `minimum`, `maximum`, `sum`, `first`, and `last`. |
| `LookupMode` | Enum: `EXACT`, `PREDECESSOR`, `SUCCESSOR`, `NEAREST`; inclusive directions, predecessor ties. |
| `SeriesHandle` | Opaque owner/snapshot-bound prepared series created by `Reader.prepare`. |

### `Writer`

| API | Contract |
|---|---|
| `Writer(path, batch_size=1000, codec="compressed")` | Opens or creates a writer using `"raw"` or `"compressed"`. |
| `append(series, timestamp, value)` | Buffers one point and flushes at `batch_size`. |
| `append(series, timestamps, values)` | Alias of `append_many` for non-integer timestamp inputs. |
| `append_many(series, timestamps, values)` | Submits equal-length iterable batches; writable native arrays use the direct path. |
| `prepare(series, maximum_points_before_checkpoint)` | Reserves the bounded native append path. |
| `checkpoint(fsync=False)` | Flushes binding buffers and publishes with memory or disk durability. |
| `close()` | Flushes, publishes healthy state, and consumes the handle; repeated calls are harmless. |

`Writer` is a context manager. If an exception escapes the context, `close()`
still runs; explicitly checkpoint before acknowledging disk-durable data.

### `Reader`

| API | Contract |
|---|---|
| `Reader(path)` | Opens and validates one immutable committed snapshot. |
| `range(series, start, end)` | Returns all inclusive-range points as `(timestamp, value)` tuples. |
| `iter_range(series, start, end, *, batch_size=1024)` | Next additive release: yields inclusive-range points with bounded reusable buffers; requires all native stateful cursor symbols or raises `NotImplementedError`; explicitly close on early termination. |
| `aggregate(series, start, end)` | Returns an `Aggregate` without materializing points. |
| `prepare(series)` | Resolves an owner/snapshot-bound `SeriesHandle`; does not require lookup symbols. |
| `lookup(series, timestamp, mode, *, max_distance=None)` | Returns an original copied tuple or `None`, with an inclusive optional u64 distance. |
| `lookup_prepared(series, timestamp, mode, *, max_distance=None)` | Same selection through this reader's prepared handle; rejects wrong owner, closed or stale handles. |
| `refresh()` | Adopts a newer complete generation and returns whether it changed. |
| `close()` | Releases the native mapping; repeated calls are harmless. |

`Reader` is a context manager. `range` materializes a complete list;
`iter_range` controls streaming buffer capacity through `batch_size`. Keep the
reader open until iteration finishes, and discard old iterators after a changed
refresh.

See [durability and recovery](../durability.md) and the
[migration guide](../migration.md) for operational behavior outside the Python
API.
