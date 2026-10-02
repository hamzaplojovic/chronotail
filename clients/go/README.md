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

## Temporal lookup in 2.2 development

`Reader.Lookup`, `Reader.LookupPrepared` and `Series.Lookup` return a copied
`Point`, a found boolean and an error. Choose `LookupExact`,
`LookupPredecessor` (last known at or before), `LookupSuccessor` (at or after)
or `LookupNearest` (earlier sample wins ties). Pass `nil` for unrestricted
distance or `*uint64` for an inclusive age limit in your timestamp units.
Missing is found false; a zero value is found true. Timestamps and f64 bits
remain exact across the full signed/unsigned domains.

This source requires the matching 2.2 development header and native library
exporting `ct_lookup` and `ct_lookup_prepared`; it does not link against the
2.1 archive shown above. C ABI stays 2, but new optional symbols are not
guaranteed by the ABI number. Go uses direct cgo linking with no fallback.
