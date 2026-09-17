# Zig API

Import the `chronotail` module and use `Appender` and `Reader`.

```zig
var writer = try chronotail.Appender.create(allocator, path, .compressed);
try writer.appendBatch("cpu", timestamps, values);
try writer.checkpoint(true);
try writer.close();

var reader = try chronotail.Reader.open(allocator, path);
defer reader.close();
const count = try reader.rangeInto("cpu", start, end, timestamps_out, values_out);
```

`AppenderFor(File)` and `ReaderFor(File)` are internal extension seams used by deterministic storage simulation. Production aliases remain specialized to `std.fs.File`.
