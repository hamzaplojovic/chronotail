# Temporal lookup client contract

Status: implemented and independently reviewed for 2.2; final native release
validation is a separate gate. These APIs are not part of the 2.1 release artifacts. Format v7,
C ABI version 2 and existing public layouts/symbols remain unchanged.
The frozen [Zig contract](temporal-lookup.md) is the semantic authority.

## Shared sample semantics

Exact requires equality. Predecessor is the greatest stored timestamp at or
before the target; successor is the least at or after it. Nearest minimizes
absolute distance, with predecessor winning ties. An exact point wins in every
mode. No interpolation, filling, timestamp-unit conversion or range scan is
performed. Missing and rejected-by-distance results are distinct from zero.

Timestamp is signed 64-bit; maximum distance is optional unsigned 64-bit in
the caller's timestamp units. The limit is inclusive and applied after mode/tie
selection. No limit accepts any distance; zero accepts only exact timestamps.
The distance between minimum and maximum signed 64-bit timestamps is the
maximum unsigned 64-bit value. Wrappers must not subtract in signed 64-bit,
narrow the limit to signed 64-bit, or convert timestamps through floating point.

Results copy the original timestamp and binary64 value bits, including signed
zero, subnormals, infinities and NaN payloads. A returned point remains usable
after refresh or close. Prepared series belong to the original reader snapshot;
successful changed refresh invalidates them. Unchanged/failed refresh does not.
Readers and prepared wrappers are not safe for concurrent method calls.

## Additive C API

```c
enum {
    CT_LOOKUP_EXACT = 0,
    CT_LOOKUP_PREDECESSOR = 1,
    CT_LOOKUP_SUCCESSOR = 2,
    CT_LOOKUP_NEAREST = 3
};

int ct_lookup(
    ct_handle *reader,
    const char *series, size_t series_len,
    int64_t timestamp,
    uint8_t mode,
    uint8_t has_limit, uint64_t max_distance,
    ct_point *out, uint8_t *found);

int ct_lookup_prepared(
    ct_handle *reader,
    ct_series_handle series,
    int64_t timestamp,
    uint8_t mode,
    uint8_t has_limit, uint64_t max_distance,
    ct_point *out, uint8_t *found);
```

`mode` accepts only 0 through 3; explicitly map these constants to the Zig enum
instead of depending on an internal enum's ordinal. `has_limit` accepts only
0 or 1. When zero, `max_distance` is ignored for every uint64 value (wrappers
pass zero canonically); when one, it is the inclusive bound. There is no
sentinel distance: maximum uint64 is a valid limit, not the no-limit tag.

The existing `ct_point` layout remains `int64_t timestamp; double value;`:
16 bytes, 8-byte alignment, offsets 0 and 8 on the existing native target.
The existing 16-byte `ct_series_handle` is passed by value, with its reserved
field required to be zero. Outputs are caller-owned, suitably aligned writable
objects and must not overlap each other or input storage. No allocation or
retained output pointer occurs in these C lookup calls.

Both output pointers are required, even for a missing result. If `found` is
non-null, set `*found = 0` before argument validation or engine work, including
when `out` is null. Leave `*out` completely unchanged on missing or any error;
write a complete copied point then `*found = 1` only after successful lookup.
Do not synthesize a zero point or expose partially written values.
Callers and wrappers must read `out` only when status is `CT_OK` and found is 1;
it may contain caller-provided sentinel or uninitialized bytes in every other
case. Output preservation does not make those bytes a result.

| Outcome | Status | `found` | `out` |
|---|---|---|---|
| Stored point accepted | `CT_OK` | 1 | Original copied point |
| No eligible point or outside limit | `CT_OK` | 0 | Unchanged |
| Invalid input, missing series, stale handle or engine failure | Existing negative status | 0 when pointer provided | Unchanged |

There is no buffer-capacity/count-query mode and no `CT_BUFFER_TOO_SMALL` result.
`CT_TIMESTAMP_NOT_FOUND` is not the missing-sample result for these symbols.

Validation order is deterministic: initialize available found output; validate
both outputs, mode, has_limit and prepared reserved/name pointer+length; then
validate non-null reader and reader kind; then resolve series and perform the
authenticated lookup. Invalid scalar/output inputs take precedence over a
missing/stale series. With valid scalar/output inputs, unknown/stale series
errors take precedence over missing/tolerance filtering, including limit zero.

| Trigger | C outcome |
|---|---|
| Null output, null reader, invalid mode/tag, nonzero prepared reserved | `CT_INVALID_ARGUMENT` |
| Null/empty name, or unknown named series | `CT_INVALID_ARGUMENT` (existing `SeriesNotFound` mapping) |
| Live writer supplied where reader required | `CT_WRONG_HANDLE` |
| Prepared generation/index no longer valid for supplied reader | `CT_STALE_SERIES` |
| Authentication/structural/storage failure | Existing status mapping, e.g. `CT_IO_ERROR`; never successful missing |

C cannot safely validate arbitrary or already-freed opaque pointers. After
`ct_close`, callers must discard the pointer and use null if making a subsequent
call; null yields `CT_INVALID_ARGUMENT`. Calling with a dangling pointer is
outside the existing handle contract. No handle registry or layout change is
proposed. Likewise existing prepared C handles encode index/generation, not
reader identity: use them only with the reader that prepared them. Another
reader with identical index/generation cannot be reliably distinguished without
changing that contract. Go/Python owner-bound wrappers enforce their identity.

## Go wrapper surface

```go
type LookupMode uint8
const (
    LookupExact LookupMode = 0
    LookupPredecessor LookupMode = 1
    LookupSuccessor LookupMode = 2
    LookupNearest LookupMode = 3
)

func (r *Reader) Lookup(series string, timestamp int64,
    mode LookupMode, maxDistance *uint64) (Point, bool, error)
func (r *Reader) LookupPrepared(series *Series, timestamp int64,
    mode LookupMode, maxDistance *uint64) (Point, bool, error)
func (s *Series) Lookup(timestamp int64,
    mode LookupMode, maxDistance *uint64) (Point, bool, error)
```

`nil` limit means unrestricted; a pointer to zero means equality only. The
value is copied during the synchronous call and the pointer is never retained.
Existing `Reader.PrepareSeries` creates `Series`; its idiomatic `Lookup` forwards
to its owner reader's `LookupPrepared`. Both naming forms match Zig/C semantics.
On success with found false, return `Point{}, false, nil` and require callers
to inspect found; on error return `Point{}, false, err` without reading C output.
Found true preserves `int64` timestamp and `math.Float64bits(value)` exactly.
Do not copy or inspect the C point when found is zero, even on `CT_OK`.

Closed/nil readers or series return existing `ErrClosed` before entering C;
stale epoch returns `ErrStaleSeries`; a prepared Series from another Reader
returns `ErrWrongHandle`. An empty name uses existing `ErrEmptySeries`; invalid
mode uses `ErrInvalidArgument`. Native status translation remains `StatusError`
with existing `errors.Is` sentinels. A sample's zero value is never missing.

Go currently uses direct cgo linking. This proposal preserves that model: the
new Go package requires a native library exporting both lookup symbols when
linked. Existing binaries/previous Go releases that reference only old symbols
remain compatible with a newer ABI-v2 library. New Go lookup source is not
promised to link against an older library merely because it also reports ABI 2.
Missing lookup symbols are a link/load capability error, documented with the
required additive native release. There is no dlsym/backend dispatch or new
runtime dependency. Optional Go symbol linking would need a separate reviewed
platform/linker contract; do not quietly add it during implementation. Existing
Go stateful-cursor references already prevent a general v2.0-library claim.

## Python wrapper surface

```python
class LookupMode(IntEnum):
    EXACT = 0
    PREDECESSOR = 1
    SUCCESSOR = 2
    NEAREST = 3

Reader.prepare(series: str) -> SeriesHandle
Reader.lookup(series: str, timestamp: int, mode: LookupMode,
              *, max_distance: int | None = None) -> tuple[int, float] | None
Reader.lookup_prepared(series: SeriesHandle, timestamp: int, mode: LookupMode,
                       *, max_distance: int | None = None) -> tuple[int, float] | None
```

`SeriesHandle` is an opaque owner/epoch-bound Python value around the existing C
prepared handle, created by Reader.prepare, with no native allocation or borrowed
page state. Existing Writer.prepare is unaffected. A closed owner or stale epoch
raises existing `ChronotailError` before entering native code; a foreign reader's
handle raises `ChronotailError` with a wrong-reader message. Invalid handle type
raises `ValueError`. Returned points retain the established Python tuple shape.

Require a LookupMode member, an integer timestamp in signed 64-bit range, and
None or integer distance in unsigned 64-bit range; reject booleans and floating
point numeric substitutes with `ValueError` before ctypes narrowing. Use
`ctypes.c_int64`, `c_uint64`, `c_uint8` and a matching `_CPoint` layout. Check C
status before examining found/output. Return None only for `CT_OK` and found 0;
unknown-series/native errors use existing `ChronotailError` status text/code.
Do not inspect `_CPoint` fields on missing or error; inspect them only for
successful found 1. A success with zero-valued sample still returns a tuple.

Bind `ct_lookup` and `ct_lookup_prepared` as one optional complete capability,
independent of the streaming cursor capability. If either is absent, package
import and existing APIs continue to work. Valid lookup/lookup_prepared requests
raise clear `NotImplementedError` at call time naming the missing native lookup
capability, before native lookup/output work. Do not emulate with `range`, cursor
iteration or repeated scans. Reader.prepare uses the existing `ct_prepare_series`
symbol present in released v2.0 ABI-v2; it does not itself require lookup symbols.
Existing ABI-version and loader policy are unchanged. Validate argument domains
first, then owner lifetime, then capability; do not mask closed/stale errors as
successful absence.

## Last-known-value example and parity

Python use, after the matching native/Python release is installed:

```python
point = reader.lookup("pressure", observed_at, LookupMode.PREDECESSOR,
                      max_distance=1_000)
if point is None:
    display_missing()
else:
    sample_timestamp, pressure = point
    display_observation(sample_timestamp, pressure)
```

The caller defines timestamp units; 1,000 has no implied unit. A stored pressure
of zero is accepted and displayed. No timestamp rewriting or carry-forward
sample is created. C found, Go found and Python None map to Zig optional Point.
Prepared requests see the same committed generation and same selection rules.

## Planned validation and implementation boundaries

The coordinator assigned C header/API/ABI consumers, Go/Python wrappers/tests/docs
and additive installed smoke checks to CT-005 in the isolated temporal-clients
worktree. Source and pure-stub checks are authorized; native validation requires
an exclusive coordinator slot. Core lookup and the reconciled CT-008 guard are
outside this implementation's ownership and remain unchanged.

Use an independent sorted-list oracle shared as input fixtures across languages:
all four modes; inclusive equality/tolerance; one less/equal/one greater limits;
nearest ties; first/last/single/no eligible samples; zero values; negative and
irregular sparse times; min/max signed timestamp and max unsigned distance;
page/index boundaries; raw/compressed pages; named/prepared parity; signed zero,
subnormal, infinity and representative NaN payload bits. Never compare NaNs with
ordinary equality or use float timestamps. Preserve any failing seed/fixture.

C tests cover every mode/tag byte, ignored no-limit distance, required/null
outputs, sentinel output preservation on errors/missing, found initialized zero,
reserved bits, null handle/live writer, unknown series, stale generation/index,
unchanged/failed/changed refresh and copied point after reader close. Do not
call freed C pointers as a negative test. Forge valid identities with invalid
edges to prove authentication cannot become a missing result, including cached
edge cases. Assert old symbol exports/layouts/statuses/ABI version unchanged and
new constants/prototypes/layouts work from C and C++.

Go/Python tests additionally cover closed owners, wrong-reader prepared wrappers,
invalid enum/domain conversion, result bits and synchronous copied limit. Python
stub tests use exact old released symbol sets and each missing lookup symbol,
with streaming capability independently present/absent; old APIs must work and
lookup must fail clearly with no materializing fallback. Go tests exercise its
documented matched-native linking boundary; a missing-symbol diagnostic is not
a new supported runtime fallback. Native calls must not retain caller storage.

Manager exclusively schedules fresh engine modes/simulation if engine code is
touched and native client/ABI suites for actual wrapper changes. Independent
client/correctness/resource review binds exact final commits. Existing CI and
prior native results do not certify a later release candidate.

Installed-artifact validation must use isolated extracted bundles outside the
checkout: compile a C/C++ consumer against packaged header/library, build/run
the packaged Go consumer with its documented library search setup, and install
the Python wheel into a clean environment using only its bundled native library.
Verify symbols, ABI 2, path/hash of loaded library, all four modes and missing/
bits/tolerance behavior. Load an actual old ABI-v2 library for Python compatibility
as well as pure stubs. Linux checks are development evidence; native macOS ARM64
bundles remain the release boundary. No new platform or benchmark claim follows.

The 2.1 release is published and its bytes remain frozen. The additive APIs
are integrated in main; final 2.2 native validation, installed compatibility,
matching tag and public assets remain release gates.
