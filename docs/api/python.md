# Python API

The v1.0.0 wheel supports CPython 3.10 or newer on macOS ARM64 and bundles the frozen C ABI v1 dynamic library.

```python
chronotail.Writer(path, batch_size=1000, codec="compressed")
chronotail.Reader(path)
```

`Writer.append(series, timestamps, values)` accepts either one integer/float pair or iterable batches. Writable `array('q')` and `array('d')` values use the zero-copy binding path. `checkpoint(fsync=False)` publishes buffered writes.

`Reader.range(series, start, end)` returns `(timestamp, value)` tuples. `refresh()` returns `True` when a newer checkpoint was adopted. Both classes are context managers.
