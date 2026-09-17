# Chronotail clients

Chronotail has one native engine and four supported integration surfaces. They
share format-v7 semantics, but their ownership and allocation APIs follow each
language rather than imitating one another.

| Client | Source | Canonical guide | Runtime model |
|---|---|---|---|
| Go | [`go/`](go/) | [Go guide](../docs/clients/go.md) | cgo over C ABI v2 |
| Python | [`python/`](python/) | [Python guide](../docs/clients/python.md) | `ctypes` over C ABI v2 |
| C | [`../include/chronotail.h`](../include/chronotail.h) | [C guide](../docs/clients/c.md) | native C ABI v2 |
| Zig | [`../src/chronotail.zig`](../src/chronotail.zig) | [Zig guide](../docs/clients/zig.md) | direct engine facade |

The validated release target is macOS ARM64. Go and C consumers link
`libchronotail`; the released Python wheel bundles it. None of the clients adds
a third-party runtime dependency or a background service.

Start with the [client documentation index](../docs/clients/index.md) to choose
between convenient allocating operations and bounded caller-buffer APIs.
