# Python API

The Python package requires Python 3.10 or newer and C ABI v2. The validated
release target is macOS ARM64; the wheel bundles `libchronotail.dylib` and has no
third-party runtime package dependency.

## Development install

```bash
zig build -Doptimize=ReleaseFast
export CHRONOTAIL_LIBRARY="$PWD/zig-out/lib/libchronotail.dylib"
python3 -m pip install -e python
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
number. Python argument-shape errors such as an invalid codec, nonpositive batch
size, or mismatched iterable lengths raise `ValueError`.

Prepared reader handles, persistent cursors, borrowed raw-page views,
fixed-resolution aggregate windows, full-file verification, and v6 migration
are currently Zig/C/CLI facilities. The Python surface intentionally stays
small until those ownership and buffer contracts have idiomatic bindings.

See [durability and recovery](../durability.md) and the
[migration guide](../migration.md) for operational behavior outside the Python
API.
