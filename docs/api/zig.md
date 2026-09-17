# Zig API v2

Import `chronotail` and use the production `Appender` and `Reader` aliases.

```zig
var writer = try chronotail.Appender.create(allocator, path, .compressed);
try writer.prepareSeries("cpu", 1_000_000);
try writer.appendBatch("cpu", timestamps, values);
try writer.checkpointWithDurability(.disk);
try writer.close();

var reader = try chronotail.Reader.open(allocator, path);
defer reader.close();
const cpu = try reader.prepare("cpu");
const count = try reader.rangePreparedInto(cpu, start, end, timestamps_out, values_out);
```

`appendBatch` validates the complete batch before mutation. Timestamps must be
strictly increasing within a series and later than its prior timestamp.
`prepareSeries(name, maximum_points_before_checkpoint)` declares the bound used
to reserve page descriptors, making existing-series append allocation-free
until the next checkpoint. Control-plane checkpoint work may allocate.

`checkpoint(bool)` remains a source-compatible convenience wrapper.
`checkpointWithDurability(.memory)` publishes without a power-loss guarantee;
`.disk` syncs immutable objects before the root and syncs again after root
publication. Any operational write failure poisons the appender until `abort()`.

Reader choices are:

- `rangeInto` and `rangePreparedInto` copy into caller-owned equal-length buffers
  and return the required count; a return larger than capacity means the prefix
  was copied.
- `cursor`/`cursorPrepared` plus `cursorNext` retain a fixed-height traversal and
  make bounded incremental progress without count-then-copy repetition.
- `borrowRawPage` returns zero-copy timestamp/value slices only when both columns
  are raw; the view is valid until reader refresh or close.
- `aggregate`/`aggregatePrepared` return count, min, max, sum, first, and last.
- `aggregateWindowsPrepared` groups the inclusive range into fixed timestamp-unit
  windows and uses persistent subtree summaries where possible; it fills the
  available prefix and returns the total required window count.
- `latestTimestamp`, `codecCounts`, `profileRange`, and `verifyPath` expose
  inspection and verification support.

`SeriesHandle` includes the reader generation. Refresh invalidates prepared
handles and cursors with `StaleSeriesHandle`; borrowed slices must not be used
after refresh. Empty aggregates have count zero, sum zero, and NaN min/max/first/last.

`AppenderFor(File)` and `ReaderFor(File)` are the compile-time storage seam used
by deterministic simulation. Production aliases specialize to `std.fs.File`,
with no runtime dispatch.

Use `migrateV6(allocator, source, target, codec, durability)` or the CLI to read
a verified committed v6 snapshot into a distinct v7 file. Source and target may
not be the same path.
