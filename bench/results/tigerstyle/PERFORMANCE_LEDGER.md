# TigerStyle performance ledger

The unchanged competitive baseline is `20260916-213249`. Diagnostic experiments below are explicitly not changes to competitive methodology. Rates are medians unless noted; host background load caused substantial absolute variance, so paired/alternating A/B results and latency distributions carry more weight than isolated runs.

| Change | Mechanical hypothesis / resource | Before | After | Result | Decision |
|---|---|---:|---:|---:|---|
| Split reader and writer series types | Readers should not allocate or move writer-only 64 KiB buffers; separate mutable ownership | Shared `Series`: 65,624 B | `ReaderSeries`: 64 B initially; final prepared form 96 B | >680x smaller per-series object | Kept |
| Stable separately allocated writer block buffer | Keep writer metadata contiguous and prevent 64 KiB copies on series-array growth | `WriterSeries`: 65,624 B | 96 B | 8-series append diagnostic +2.5%; one-series result noisy, about -4% median | Kept for bounded ownership, stable addresses, and multi-series locality |
| Hot/cold block-index split | Binary search should touch only immutable query metadata | 56 B combined index | 40 B hot index + 24 B cold verification | Point A/B statistically neutral by itself; 29% smaller hot stride | Kept for safety and locality |
| Raw payload semantic validation on first checksum | A checksum proves bytes, not timestamp order; use the same pass to prove order and fixed step | Interior order unchecked by normal reader | Strict order/min/max checked once | New malicious-but-checksummed regression test; no warm cost | Kept |
| Fixed-step record mapping | Proven equal deltas imply exact arithmetic lower bound, eliminating ~12 dependent probes | 7.80M point queries/s | 18.83M/s | 2.41x | Kept |
| 128-bit division in fixed-step mapping | Straightforward overflow-proof arithmetic | 19.05M/s | — | `__udivti3` visible; unnecessary cost | Reworked |
| 64-bit checked fixed-step division | Timestamp span fits `u64`; avoid software 128-bit division | 17.94M/s | 20.29M/s | +13.1% | Kept |
| Unit-step specialization | The most common dense case needs subtraction, not division | 21.49M/s | 22.99M/s | +7.0% | Kept |
| Block arithmetic mapping using `u128` | Eliminate ~8 block-index probes for regular series | 19.05M/s | 17.94M/s | -5.8% | Rejected |
| Block arithmetic mapping using checked `u64` stride and guarded acceptance | Same idea without `__udivti3`; malformed/irregular geometry falls back | 20.15M/s | 28.43M/s | +41.1% | Kept |
| Irregular timestamp fallback | Prepared mapping must not punish arbitrary monotonic data | 4.43M/s | 4.77M/s | +7.7% in diagnostic; binary fallback retained | Kept |
| Series hash directory above four series | Bound repeated name lookup without penalizing the one-series case | 19.02M 8-series appends/s | 19.81M/s | +4.2% | Kept |
| Chunked batch append loop | Pay rollover and metadata costs per contiguous chunk rather than per record | Batch 64: 33.69M/s; batch 512: 34.27M/s | 37.24M/s; 36.25M/s | +10.5%; +5.8%; 4,096-point results noisy/mixed | Kept; simpler hot loop and natural block bound |
| Four-lane Zig vector timestamp validation | Compare adjacent batch timestamps four at a time | Python-default batch 1,000: 26.19M/s | 27.67M/s | +5.7% | Kept |
| Outline verification helper | Separate cold verification from range control flow | 18.55M point queries/s | — | About -18%; warm path paid a call | Reworked |
| Force-inline verification state check | Restore one folded warm path while retaining focused helper | 18.55M/s | 22.72M/s | +22.5%; symbol disappears | Kept |
| Force-inline series lookup | Remove a visible tiny hot call | 10.64M/s under loaded-host paired run | 11.30M/s | +6.3%; symbol disappears | Kept |
| Pre-plan footer size and reserve once | Remove checkpoint reallocations and prove footer count/size bounds before serialization | Incremental growth checks | One exact reserve | No isolated throughput claim; predictable allocation/error boundary | Kept for safety/predictability |
| Fixed 64-entry footer-chain array | v6 chain depth is statically bounded; dynamic allocation is unnecessary | Dynamic `ArrayList` growth at open | 64-entry stack array | Removes one control-plane allocation | Kept |
| Consolidated trailer-pointer validation | Two scanners duplicated overflow/bounds rules | Two implementations | One checked helper | No data-plane effect | Kept for safety |
| Compact verification cache pointer | Cached length is already authoritative in block metadata | Optional slice in cold state | Optional pointer + metadata length | Cold state 32 B -> 24 B | Kept |
| Forced `readVarint` inline (previous pass, rechecked architecturally) | Remove compressed decoder call | ~396k/s focused | ~365k/s | -8% | Rejected; code-size pressure |
| Remove block verification flag (previous pass) | Tighten index representation | Focused raw rate baseline | -7% | Regression | Rejected; formal state retained instead |

## Range-width diagnostics

Pre-TigerStyle:

| Width | Queries/s | Returned points/s |
|---:|---:|---:|
| 1 | 6.86M | 6.86M |
| 10 | 3.54M | 35.36M |
| 100 | 2.29M | 228.79M |
| 1,000 | 639.57k | 639.57M |
| 10,000 | 77.64k | 776.44M |
| 1,000,000 | 658 | 658.39M |

Prepared timestamp geometry diagnostic:

| Width | Queries/s | Returned points/s |
|---:|---:|---:|
| 1 | 21.40M | 21.40M |
| 10 | 13.94M | 139.44M |
| 100 | 5.75M | 574.83M |
| 1,000 | 1.08M | 1.08B |
| 10,000 | 113.75k | 1.14B |
| 1,000,000 | 930 | 929.94M |

The largest-width paths are near the useful memory-traffic ceiling; search removal mainly benefits widths 1–1,000.

## Final alternating A/B under shared host load

Absolute rates were suppressed by unrelated host load, but alternating the frozen pre-TigerStyle binary and final binary controls for that load better than comparing separate suite runs:

| Path | Pre-TigerStyle median | Final median | Change |
|---|---:|---:|---:|
| Single-series append | 12.49M/s | 14.09M/s | +12.8% |
| Eight-series append | 13.13M/s | 13.44M/s | +2.4% |
| Dense one-point query | 3.55M/s | 18.99M/s | 5.35× |
| Raw 100-point query | 1.34M/s | 2.92M/s | 2.18× |

Compressed A/B rates varied by more than the apparent change under load (roughly 120k–199k queries/s), so no final speedup claim is made for compressed decoding.

In a separate alternating writer/readers test, final reader p50 roughly halved and p99 improved by 33–36%. Faster readers consumed more shared machine resources: at eight readers, aggregate query throughput increased about 28% while writer throughput fell about 34%. The engine retains this tradeoff because total useful point work rises, read latency improves substantially, and throttling readers would be an application scheduling policy rather than a storage-engine optimization.
