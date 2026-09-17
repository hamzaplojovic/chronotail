# C client

The canonical C client is the stable ABI declared in
[`include/chronotail.h`](../../include/chronotail.h). Its implementation lives
in `src/c_api.zig`; this directory intentionally does not copy either file.

Build the native library with `zig build -Doptimize=ReleaseFast`, then follow
the [C guide and API reference](../../docs/clients/c.md).

Compile the included end-to-end example from the repository root:

```bash
clang -std=c11 clients/c/example.c \
  -Iinclude -Lzig-out/lib -lchronotail \
  -Wl,-rpath,"$PWD/zig-out/lib" \
  -o /tmp/chronotail-c-example
/tmp/chronotail-c-example
```
