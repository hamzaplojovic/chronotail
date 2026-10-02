# Temporal lookup

Temporal lookup returns one stored sample around a timestamp without
materializing its history. This is an additive Zig API on format v7; it does
not change the persistent format or C ABI v2.

```zig
pub const LookupMode = enum { exact, predecessor, successor, nearest };

const point = try reader.lookup("cpu", timestamp, .predecessor, 1000);
const handle = try reader.prepare("cpu");
const prepared_point = try reader.lookupPrepared(handle, timestamp, .nearest, null);
```

Both methods return `!?Point`. A point contains the original stored timestamp
and value; a missing result is `null`, distinct from a sample whose value is
zero. Lookup never fills gaps or interpolates values.

| Mode | Result |
|---|---|
| `exact` | Sample whose timestamp equals the requested timestamp. |
| `predecessor` | Greatest stored timestamp at or before the requested timestamp. |
| `successor` | Least stored timestamp at or after the requested timestamp. |
| `nearest` | Sample with the smallest absolute timestamp distance; ties choose the predecessor. |

An exact sample wins in every mode. At the first or last sample, a direction
without a sample returns `null`; nearest uses the available direction.

The final argument, `max_distance: ?u64`, is an inclusive maximum distance in
the same units as the caller's timestamps. `null` accepts any distance; zero
accepts only an exact timestamp. Distance is computed safely across the full
signed 64-bit timestamp domain: the distance from `minInt(i64)` to
`maxInt(i64)` is `maxInt(u64)`. A selected sample beyond the bound returns
`null`. Selection and tie breaking occur before applying the bound.

Unknown series names return `SeriesNotFound`. Invalid or stale prepared handles
return `StaleSeriesHandle`, including when a lookup would otherwise be missing.
Authentication and structural validation errors propagate. A reader sees one
committed generation; a successful refresh invalidates old prepared handles.
The returned `Point` is copied and remains usable after refresh or reader close.

Lookup authenticates the index path and selected page using the existing
reader validation and immutable snapshot caches. It checks series identity,
child level and summary consistency. Generic storage is reauthenticated on
every read. Exact, predecessor and successor each traverse one index path and
at most one page; nearest traverses at most two paths and pages. Timestamp and
value decoding use the existing bounded restart cursors. First access may
validate all records of a selected page, bounded by page geometry; lookup does
not scan other history. Named and prepared calls allocate no memory after open.

This API makes no new supported-platform or benchmark claim. C, Go, Python,
batch lookup and interpolation are separate work.
