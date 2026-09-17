# Python API v2

The v2 package requires Python 3.10 or newer and C ABI v2. The currently
validated release target remains macOS ARM64.

```python
from array import array
import chronotail

with chronotail.Writer("metrics.ctdb", codec="compressed") as writer:
    writer.prepare("cpu", 1_000_000)
    writer.append("cpu", array("q", [1, 2, 3]), array("d", [40.0, 41.0, 42.0]))
    writer.checkpoint(fsync=True)

with chronotail.Reader("metrics.ctdb") as reader:
    points = reader.range("cpu", 1, 3)
    summary = reader.aggregate("cpu", 1, 3)
```

`Writer.append` accepts one integer/float pair or iterable batches. Writable
`array('q')` and `array('d')` inputs use the zero-copy binding path. Buffered
values are flushed before `checkpoint`; `fsync=True` selects disk durability.
`Writer.prepare(series, maximum_points_before_checkpoint)` exposes v2's bounded
allocation-free append contract.

`Reader.range` returns `(timestamp, value)` tuples. `Reader.aggregate` returns
an `Aggregate(count, minimum, maximum, sum, first, last)` named tuple. Empty
ranges return count zero, sum zero, and NaN for the other fields. `refresh()`
returns `True` only when a newer complete generation is adopted. Both classes
are context managers.

Prepared reader handles, cursors, borrowed raw-page views, aggregate windows,
and v6 migration are currently Zig/C/CLI facilities rather than Python methods.
