# Chronotail Python

Python bindings for Chronotail's frozen C ABI v1. The macOS ARM64 wheel bundles `libchronotail.dylib` and requires no third-party runtime package.

```python
from array import array
import chronotail

with chronotail.Writer("metrics.ctdb", codec="compressed") as writer:
    writer.append("cpu", array("q", [1, 2, 3]), array("d", [40.0, 41.0, 42.0]))
    writer.checkpoint(fsync=True)

with chronotail.Reader("metrics.ctdb") as reader:
    print(reader.range("cpu", 1, 3))
```

See [`docs/api/python.md`](../docs/api/python.md) for API details and the project [`README.md`](../README.md) for installation and support policy.
