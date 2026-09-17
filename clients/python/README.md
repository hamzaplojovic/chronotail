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

Run the standard-library integration suite against a development build:

```bash
CHRONOTAIL_LIBRARY="$PWD/zig-out/lib/libchronotail.dylib" \
PYTHONPATH="$PWD/clients/python/src" \
python3 -m unittest discover clients/python/tests
```

For installation, batching, errors, library discovery, and exact API contracts,
read the [Python API guide](../../docs/clients/python.md). The project
[getting-started guide](../../docs/getting-started.md) includes the native build.
