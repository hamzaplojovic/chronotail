# Migrating format-v6 databases

Chronotail never rewrites a format-v6 database in place. Migration reads the
last valid committed v6 snapshot and creates a separate format-v7 target, so the
source remains available for rollback and independent comparison.

## Before you begin

1. Stop the v1 writer and retain an untouched backup of the source file.
2. Choose a different target path on storage with enough free space.
3. Decide whether the target should prefer adaptive compression or raw pages.
4. Build the current `chronotail` CLI with Zig 0.15.2.

Source and target paths must differ.

## Migrate

Adaptive compression is the default:

```bash
chronotail migrate-v6 telemetry-v6.ctdb telemetry-v7.ctdb
```

Select the raw codec explicitly when zero-copy raw-page borrowing is required:

```bash
chronotail migrate-v6 telemetry-v6.ctdb telemetry-v7.ctdb raw
```

Migration validates the v6 header, committed footer chain, checksums, series,
blocks, strict timestamp order, and record counts while writing a new v7 object
graph. The target is disk-durably published before the command succeeds.

## Verify and compare

```bash
chronotail verify telemetry-v7.ctdb
chronotail inspect telemetry-v7.ctdb
chronotail range telemetry-v7.ctdb cpu 0 9223372036854775807
```

For production data, compare per-series counts, timestamp bounds, and an
application-level digest or aggregate between the old reader and the new file.
Only switch the application path after those checks pass.

## Zig API

```zig
try chronotail.migrateV6(
    allocator,
    "telemetry-v6.ctdb",
    "telemetry-v7.ctdb",
    .compressed,
    .disk,
);
```

There is no C or Python migration entry point. Use the CLI or Zig API so the
major-format transition stays deliberate and operationally visible.

## Failure handling

- A migration failure does not modify the source.
- Do not replace the source with a partial target.
- Remove or quarantine a failed target before retrying with the same path.
- Preserve the source until the new file has passed verification, application
  checks, backup, and at least one restore exercise.
