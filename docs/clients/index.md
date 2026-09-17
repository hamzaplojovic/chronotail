# Client guides

Chronotail exposes the same format-v7 engine through four language surfaces.
Choose the client that matches the host application; database files are shared
and no client introduces a server or network protocol.

| Client | Best fit | Memory model | Guide and API reference |
|---|---|---|---|
| Go | Go services and embedded tools | Idiomatic slices plus bounded `RangeInto` and cursors | [Go](go.md) |
| Python | Scripts, notebooks, and Python applications | Lists for reads; direct writable buffers for batch writes | [Python](python.md) |
| C | FFI hosts and native applications | Caller-owned buffers and explicit handles | [C](c.md) |
| Zig | Native applications and engine extensions | Allocator-explicit facade and compile-time storage specialization | [Zig](zig.md) |

## Shared guarantees

- One writer may append while independent readers hold immutable committed
  snapshots.
- Timestamps are strictly increasing within each named series.
- Memory publication and disk publication are explicit durability choices.
- Format v7 and C ABI v2 are the current major boundaries.
- Go, Python, and C use the same native C ABI; Zig calls the engine facade
  directly.
- macOS ARM64 is the only artifact target currently validated.

Read [durability and recovery](../durability.md) before acknowledging writes,
and [migration](../migration.md) before opening format-v6 data with current
code.
