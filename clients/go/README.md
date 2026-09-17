# Chronotail for Go

The Go package wraps Chronotail C ABI v2 with no third-party Go dependency and
no hidden goroutine. It is currently validated on macOS ARM64.

## Development

Build the native library, make it visible to cgo and the dynamic loader, then
run the integration tests:

```bash
zig build -Doptimize=ReleaseFast
CGO_LDFLAGS="-L$PWD/zig-out/lib" \
DYLD_LIBRARY_PATH="$PWD/zig-out/lib" \
go test ./clients/go
```

Import the package as:

```bash
go get github.com/hamzaplojovic/chronotail/v2@v2.1.0
```

```go
import chronotail "github.com/hamzaplojovic/chronotail/v2/clients/go"
```

```go
writer, err := chronotail.OpenWriter("metrics.ctdb", chronotail.CodecCompressed)
if err != nil {
    log.Fatal(err)
}
defer writer.Close()

if err := writer.Prepare("cpu", 3); err != nil {
    log.Fatal(err)
}
if err := writer.Append("cpu", []int64{1000, 1001, 1002}, []float64{42.5, 43.1, 42.8}); err != nil {
    log.Fatal(err)
}
if err := writer.Checkpoint(chronotail.DurabilityDisk); err != nil {
    log.Fatal(err)
}
```

The [complete Go guide and API reference](../../docs/clients/go.md) covers
linking, snapshots, bounded buffers, prepared series, cursors, borrowed raw
pages, error matching, durability, concurrency, and ownership.
