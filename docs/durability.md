# Durability and recovery

Chronotail separates snapshot publication from power-loss durability. Both
modes publish only complete, authenticated generations; the difference is when
the operating system is required to make those bytes durable.

## Publication modes

| Mode | Zig | C | Python | Guarantee |
|---|---|---|---|---|
| Memory | `.memory` | `CT_DURABILITY_MEMORY` or `ct_checkpoint(..., 0)` | `checkpoint(fsync=False)` | Visible to newly opened or refreshed readers after a successful call; no power-loss promise. |
| Disk | `.disk` | `CT_DURABILITY_DISK` or `ct_checkpoint(..., 1)` | `checkpoint(fsync=True)` | Immutable objects are synced before root publication, then the root is synced. |

The durable publication order is:

```text
data pages + copied index nodes + manifest
                    |
                  sync
                    |
             next root slot
                    |
                  sync
```

The root is the only publication point. Readers never infer a snapshot from an
arbitrary file tail.

## What interruption leaves behind

The first 64 KiB of a format-v7 file contains four independent root slots. Each
valid root names a committed extent, manifest, generation, predecessor, and
external identity. Recovery examines this fixed candidate set and chooses the
newest complete generation whose graph validates.

An interruption can therefore leave:

- bytes beyond the committed extent, which readers ignore;
- an incomplete new object, which no valid root names;
- a torn or invalid newest root, which permits fallback to an older valid root;
- an operationally failed writer, which is poisoned and cannot publish further
  data until it is aborted.

Chronotail fails closed when nonzero root slots exist but no candidate is valid.
It does not reinterpret a damaged database as empty.

## Reader snapshots

A reader maps one committed extent and keeps that immutable generation until
`refresh()` succeeds. Refresh validates the new generation before replacing the
old mapping. It then invalidates prepared series handles, cursors, and borrowed
raw-page views from the old generation.

```zig
const changed = try reader.refresh();
if (changed) {
    // Prepare new generation-bound handles here.
    cpu = try reader.prepare("cpu");
}
```

Do not use borrowed slices after refresh or reader close. The current reader
remaps the complete committed extent; cross-refresh view retention would need a
separate pinned-snapshot API and explicit reclamation.

## Verification

Object identities prove exact bytes, not semantic correctness. Full
verification additionally checks pointer bounds and kinds, reserved fields,
index ordering, summaries, codecs, root succession, strict timestamp order,
and overlapping physical ranges.

```bash
chronotail verify metrics.ctdb
```

Use verification after copying untrusted files, before migration, and during
incident investigation. Applications should still control database paths and
the native library they load.

## Operational guidance

- Group points into bounded batches and checkpoint at a business-defined
  durability window.
- Call disk durability before acknowledging data that must survive power loss.
- Keep the writer's failure path explicit: close on success, abort on error.
- Refresh long-lived readers only when they are ready to discard generation-
  bound handles and borrowed views.
- Treat storage-device and filesystem guarantees as part of the deployment.
  A successful `fsync` cannot repair hardware that violates its contract.

Competitive benchmark durability rows match logical checkpoint windows, but
they do not claim identical power-loss semantics for Chronotail `fsync`,
NanoTS `msync`, and SQLite WAL `synchronous=FULL`.
