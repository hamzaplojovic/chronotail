# Chronotail for Python

The package binds Chronotail C ABI v2 with the Python standard library only.
The validated macOS ARM64 wheel bundles `libchronotail.dylib`; no third-party
runtime package is required.

From an extracted release archive:

```bash
python3 -m pip install python/chronotail-2.1.0-py3-none-macosx_11_0_arm64.whl
```

## Quick start

```python
from array import array
import chronotail

timestamps = array("q", [1, 2, 3])
values = array("d", [40.0, 41.0, 42.0])

with chronotail.Writer("metrics.ctdb", codec="compressed") as writer:
    writer.prepare("cpu", len(timestamps))
    writer.append("cpu", timestamps, values)
    writer.checkpoint(fsync=True)

with chronotail.Reader("metrics.ctdb") as reader:
    print(reader.range("cpu", 1, 3))
    print(reader.aggregate("cpu", 1, 3))
```

Writable `array('q')` and `array('d')` values use the direct buffer path.
Readers hold immutable snapshots and adopt newer complete checkpoints only when
`refresh()` is called.

## Last-known values in 2.2 development

```python
from chronotail import LookupMode

with chronotail.Reader("metrics.ctdb") as reader:
    point = reader.lookup("cpu", 4, LookupMode.PREDECESSOR, max_distance=1)
    print(point)  # (3, 42.0); None when no sample meets the inclusive age limit.
    cpu = reader.prepare("cpu")
    print(reader.lookup_prepared(cpu, 2, LookupMode.NEAREST))
```

`EXACT`, `PREDECESSOR`, `SUCCESSOR` and `NEAREST` return original copied tuples;
directions are inclusive and nearest ties choose the earlier point. Optional
distance is an inclusive unsigned integer in your timestamp units. Missing is
`None`, distinct from zero; timestamp/value bits remain exact. Prepared handles
belong to their reader snapshot; changed refresh, close and wrong owner produce
errors. Lookup requires a matching library exporting both new symbols; Python
imports and existing APIs still work on older ABI2 libraries, with clear
call-time `NotImplementedError` for unsupported lookup and no scanning fallback.
The 2.1 wheel above does not contain this development surface.

## Stream a bounded range

This API targets the next additive release and is available in development
source checkouts. The frozen 2.1.0 wheel shown above does not include it.
Streaming also requires a native ABI-v2 library exporting all three
`ct_cursor_state_create`, `ct_cursor_state_next`, and `ct_cursor_state_destroy`
symbols. Earlier ABI-v2 libraries, including 2.0.0, remain usable for existing
Python APIs; requesting `iter_range()` raises `NotImplementedError` immediately
when this capability is incomplete. Streaming has no rescanning fallback.

`Reader.iter_range(series, start, end, *, batch_size=1024)` yields individual
`(timestamp, value)` tuples in strictly increasing timestamp order. Both bounds
are inclusive. An existing series with no matching points, or `end < start`,
yields nothing. A missing series raises `ChronotailError`, including for a
reversed range. `Reader.range()` continues to return its complete list.

```python
from contextlib import closing

with chronotail.Reader("metrics.ctdb") as reader:
    with closing(reader.iter_range("cpu", 1, 1_000_000, batch_size=1379)) as points:
        for timestamp, value in points:
            print(timestamp, value)
            if value > 90.0:
                break
```

The iterator reuses two native buffers of at most `batch_size` points each;
its memory use does not grow with the selected history. `batch_size` must be a
positive Python integer (booleans are rejected), small enough to fit native
buffer sizes. Invalid sizes raise `ValueError` when `iter_range()` is called;
an allocation that cannot fit available memory can raise `MemoryError` when
iteration starts. Accumulating results yourself, for example with `list()`,
uses memory proportional to those results.

`start` and `end` must be Python integers within signed 64-bit bounds
(`-2**63` through `2**63 - 1`); invalid bounds raise `ValueError`. Timestamps
remain exact integers, including values above `2**53`. Values retain their
stored binary64 bits as Python floats, including signed zero, infinities,
and NaNs; the binding performs no timestamp-to-float or value rounding conversion.

An iterator belongs to the reader snapshot at the time `iter_range()` is
called. Native cursor creation and reading begin on the first `next()` call,
so native errors, including missing series, arise during iteration. Publishing
a checkpoint does not change that snapshot. A successful `reader.refresh()`
that returns `True` invalidates existing iterators, including unstarted ones
and points already buffered for yielding. The next read raises
`ChronotailError`; create a new iterator after refresh. A refresh returning
`False`, or a failed refresh, keeps the iterator valid.

Keep the reader open while iterating. Closing it makes the next iterator read
raise `ChronotailError`. Exhaustion, a native failure, and `points.close()`
release native cursor state. When stopping early, explicitly call
`points.close()` or use `contextlib.closing` as above: `break` alone does not
close a retained generator. Closing an unstarted iterator allocates no native
cursor. Reader objects and their iterators are not safe for concurrent method
calls; use independent readers in independent threads.

Run the standard-library integration suite against a development build:

```bash
CHRONOTAIL_LIBRARY="$PWD/zig-out/lib/libchronotail.dylib" \
PYTHONPATH="$PWD/clients/python/src" \
python3 -m unittest discover clients/python/tests
```

For installation, batching, errors, library discovery, and exact API contracts,
read the [Python API guide](../../docs/clients/python.md). The project
[getting-started guide](../../docs/getting-started.md) includes the native build.
