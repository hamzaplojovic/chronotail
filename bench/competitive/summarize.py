#!/usr/bin/env python3
from __future__ import annotations
import csv,json,statistics,sys
from collections import defaultdict
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
out=Path(sys.argv[1]); rows=[json.loads(x) for x in (out/"raw.jsonl").read_text().splitlines()]
groups=defaultdict(list)
for r in rows: groups[(r["workload"],r["engine"])].append(r)
summary=[]
for (w,e),rs in sorted(groups.items()):
    def med(key): return statistics.median(r[key] for r in rs)
    rates=[r["operations"]/r["seconds"] for r in rs]
    point_rates=[r["points"]/r["seconds"] for r in rs]
    summary.append({"workload":w,"engine":e,"runs":len(rs),"operations_per_sec":statistics.median(rates),"best_operations_per_sec":max(rates),"worst_operations_per_sec":min(rates),"points_per_sec":statistics.median(point_rates),"logical_mib_per_sec":statistics.median(point_rates)*16/1048576,"p50_us":med("p50_ns")/1000,"p99_us":med("p99_ns")/1000,"sync_p50_ms":med("sync_p50_ns")/1e6,"sync_p99_ms":med("sync_p99_ns")/1e6,"file_bytes":med("file_bytes"),"bytes_per_point":med("file_bytes")/med("points") if med("file_bytes") else 0})
with (out/"summary.csv").open("w",newline="") as f:
    wr=csv.DictWriter(f,fieldnames=summary[0]);wr.writeheader();wr.writerows(summary)
S={(r["workload"],r["engine"]):r for r in summary}

def fmt(x):
    if x>=1e6:return f"{x/1e6:.2f}M"
    if x>=1e3:return f"{x/1e3:.2f}k"
    return f"{x:.2f}"
def table(workloads, engines, kind="rate"):
    lines=["| Workload | Engine | Throughput | Logical MiB/s | p50 | p99 | File |", "|---|---:|---:|---:|---:|---:|---:|"]
    for w in workloads:
      for e in engines:
       if (w,e) in S:
        r=S[w,e];lines.append(f"| {w} | {e} | {fmt(r['operations_per_sec'])}/s | {r['logical_mib_per_sec']:.2f} | {r['p50_us']:.3f} µs | {r['p99_us']:.3f} µs | {r['file_bytes']/1048576:.2f} MiB |")
    return "\n".join(lines)
def ratios(workload):
    if (workload,"chronotail") not in S:return ""
    c=S[workload,"chronotail"]["operations_per_sec"];lines=[]
    for e in ("nanots","sqlite"):
      if (workload,e) in S:
       x=S[workload,e]["operations_per_sec"]
       name={"nanots":"NanoTS","sqlite":"SQLite"}[e]
       lines.append(f"- Chronotail: **{c/x:.2f}× {name}**" if c>=x else f"- Chronotail: **{x/c:.2f}× slower than {name}**")
    return "\n".join(lines)

def svg_bar(name,title,items,unit):
    W,H=900,100+55*len(items);mx=max(v for _,v in items) or 1
    parts=[f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">','<style>text{font-family:system-ui,sans-serif;font-size:14px}.title{font-size:20px;font-weight:600}.value{font-weight:600}</style>',f'<text class="title" x="20" y="30">{title}</text>']
    colors={"chronotail":"#2563eb","nanots":"#ea580c","sqlite":"#16a34a"}
    for i,(label,v) in enumerate(items):
      y=60+i*55;eng=next((x for x in colors if x in label.lower()),"");width=620*v/mx
      parts += [f'<text x="20" y="{y+20}">{label}</text>',f'<rect x="210" y="{y}" width="{width:.1f}" height="28" rx="3" fill="{colors.get(eng,"#64748b")}"/>',f'<text class="value" x="{220+width:.1f}" y="{y+20}">{v:.2f} {unit}</text>']
    parts.append('</svg>');(out/name).write_text("\n".join(parts))

svg_bar("append-throughput.svg","Single-series append throughput (median)",[(f"{w.removeprefix('append-')} / {e}",S[w,e]["operations_per_sec"]/1e6) for w in ("append-A-none","append-B-10MiB","append-C-1MiB") for e in ("chronotail","nanots","sqlite")],"M records/s")
svg_bar("query-throughput.svg","Warm query throughput (median)",[(f"{w} / {e}",S[w,e]["operations_per_sec"]/1000) for w in ("point-lookup-warm","range-100-raw-warm") for e in ("chronotail","nanots","sqlite")]+[("range compressed / chronotail",S["range-100-compressed-warm","chronotail"]["operations_per_sec"]/1000)],"k queries/s")
storage=[]
for pattern in ("smooth","random"):
 for w,e,label in ((f"storage-{pattern}-raw","chronotail","Chronotail raw"),(f"storage-{pattern}-compressed","chronotail","Chronotail compressed"),(f"storage-{pattern}","nanots","NanoTS"),(f"storage-{pattern}","sqlite","SQLite")):storage.append((f"{pattern} / {label}",S[w,e]["bytes_per_point"]))
svg_bar("storage-efficiency.svg","Storage efficiency (lower is better)",storage,"bytes/point")
con=[]
for n in (1,8,32):
 for e in ("chronotail","nanots","sqlite"):con.append((f"{n} readers / {e}",S[f"concurrent-{n}-readers",e]["operations_per_sec"]/1000))
svg_bar("concurrent-readers.svg","Aggregate reader throughput while writing",con,"k queries/s")

env=json.loads((out/"environment.json").read_text()); rid=out.name
point_chrono=S['point-lookup-warm','chronotail']['operations_per_sec'];point_nano=S['point-lookup-warm','nanots']['operations_per_sec']
comparable=['point-lookup-warm','range-100-raw-warm']+[f'concurrent-{n}-{kind}' for n in (1,8,32) for kind in ('writer','readers')]
losses=[]
for workload in comparable:
    chrono=S[workload,'chronotail']['operations_per_sec']
    winner=max(('nanots','sqlite'),key=lambda engine:S[workload,engine]['operations_per_sec'])
    winner_rate=S[workload,winner]['operations_per_sec']
    if winner_rate>chrono:
        losses.append(f"- `{workload}`: {winner} is **{winner_rate/chrono:.2f}× faster** ({fmt(winner_rate)} versus {fmt(chrono)}).")
if losses:
    loss_text="Measured cross-engine throughput losses:\n\n"+"\n".join(losses)
else:
    loss_text=(f"Chronotail has no measured cross-engine throughput loss in the comparable query/concurrency workloads in this run. It provides **{point_chrono/point_nano:.2f}× NanoTS** on the point-lookup workload that it lost in the original baseline run.")
md=f"""# Chronotail competitive benchmarks

These are measured results, not copied vendor numbers. Raw output is in [`bench/results/{rid}/raw.jsonl`](bench/results/{rid}/raw.jsonl), the aggregate CSV is in [`summary.csv`](bench/results/{rid}/summary.csv), and every invocation is in [`commands.log`](bench/results/{rid}/commands.log).

The TigerStyle mechanical model, architectural analysis, experiments, and safety evidence are in [`bench/results/tigerstyle/REPORT.md`](bench/results/tigerstyle/REPORT.md). The preceding profiler-guided pass remains archived under `bench/results/performance-pass/`.

## Test machine

| Item | Value |
|---|---|
| CPU | {env['cpu']} ({env['logical_cpus']} logical CPUs) |
| RAM | {int(env['ram_bytes'])/1073741824:.0f} GiB |
| OS | macOS {env['macos'].splitlines()[1].split(':',1)[1].strip()} / arm64 |
| Filesystem | APFS, local internal SSD |
| Zig | {env['zig']} |
| Clang | {env['clang'].splitlines()[0]} |
| NanoTS | commit `{env['nanots_commit']}` |
| SQLite | {env['sqlite_header_version'].split('"')[1]}, NanoTS vendored amalgamation |
| Repetitions | {env['run_count']}; tables report medians |

All binaries use optimized release builds. Every engine receives the same deterministic `(i64 timestamp, f64 value)` points. All output is consumed and every database is fully scanned and checked after each workload. Databases are deleted between runs. Query results are warm OS-page-cache results; privileged global cache purging was not used.

## 1. Single-series sustained append

{table(['append-A-none','append-B-10MiB','append-C-1MiB'],['chronotail','nanots','sqlite'])}

![Append throughput](bench/results/{rid}/append-throughput.svg)

No cross-engine multiplier is claimed for append durability workloads. The logical durability windows match, but the public persistence primitives do not.

Durability caveat: Chronotail uses `checkpoint(fsync=true)` and SQLite commits a WAL transaction with `synchronous=FULL`. NanoTS has no public explicit checkpoint API; its block rollover performs synchronous `msync`, so its block capacity is calculated as exactly the requested number of 16-byte logical payloads. These are the closest public semantics, but macOS does not guarantee that `msync(MS_SYNC)`, `fsync`, and SQLite WAL FULL have identical power-loss behavior. The tables compare the requested logical windows, not identical persistence primitives.

## 2. Eight-series append

{table(['append-8-series'],['chronotail','nanots','sqlite'])}

No multiplier is claimed here because the engines expose different durability primitives.

One application thread feeds eight series round-robin. NanoTS block capacities are divided by eight so the aggregate logical durability window remains approximately 10 MiB.

## 3. Random point lookup

{table(['point-lookup-warm'],['chronotail','nanots','sqlite'])}

{ratios('point-lookup-warm')}

Cold-cache numbers are intentionally omitted: reliable cache eviction on this macOS host requires a privileged system-wide `purge`, which would make unattended runs intrusive and less reproducible.

## 4. 100-point range query

{table(['range-100-raw-warm','range-100-compressed-warm'],['chronotail','nanots','sqlite'])}

![Query throughput](bench/results/{rid}/query-throughput.svg)

Raw equivalent-workload ratios:

{ratios('range-100-raw-warm')}

Chronotail compressed is shown separately and is not used for ratios against raw NanoTS or SQLite.

## Where Chronotail loses

{loss_text}

Compressed Chronotail is {S['range-100-raw-warm','chronotail']['operations_per_sec']/S['range-100-compressed-warm','chronotail']['operations_per_sec']:.2f}× slower than raw Chronotail for 100-point ranges, an internal storage/CPU tradeoff rather than a competitor loss.

## 5. Writer plus readers

| Readers | Engine | Writer records/s | Reader queries/s | Reader p50 | Reader p99 |
|---:|---|---:|---:|---:|---:|
"""
for n in (1,8,32):
 for e in ("chronotail","nanots","sqlite"):
  w=S[f"concurrent-{n}-writer",e];r=S[f"concurrent-{n}-readers",e]
  md+=f"| {n} | {e} | {fmt(w['operations_per_sec'])} | {fmt(r['operations_per_sec'])} | {r['p50_us']:.3f} µs | {r['p99_us']:.3f} µs |\n"
md+=f"""

![Concurrent reader throughput](bench/results/{rid}/concurrent-readers.svg)

Writer and reader rates are deliberately not combined. Readers query the fixed initial one-million-point snapshot while the writer appends and durably rolls over/checkpoints at roughly 1 MiB logical boundaries. This avoids rewarding an engine for exposing uncommitted tail points.

## 6. Storage efficiency

| Dataset | Engine/mode | Total size | Bytes/point |
|---|---|---:|---:|
"""
for pattern in ("smooth","random"):
 for w,e,label in ((f"storage-{pattern}-raw","chronotail","Chronotail raw"),(f"storage-{pattern}-compressed","chronotail","Chronotail compressed"),(f"storage-{pattern}","nanots","NanoTS normal"),(f"storage-{pattern}","sqlite","SQLite normal")):
  r=S[w,e];md+=f"| {pattern} | {label} | {r['file_bytes']/1048576:.2f} MiB | {r['bytes_per_point']:.3f} |\n"
md+=f"""

![Storage efficiency](bench/results/{rid}/storage-efficiency.svg)

Physical size includes persistent companion/catalog files whose basename begins with the database name. NanoTS preallocation is sized to exactly the required number of calculated blocks; no unused reserve blocks are added. SQLite is checkpointed and closed before measurement.

## Methodology details

- Logical record: exactly 16 bytes (`i64` timestamp plus `f64` value).
- Chronotail uses C ABI v1 over the public engine; no internal benchmark entry point.
- NanoTS stores that exact 16-byte struct as each frame payload. Its unavoidable frame/index overhead remains physical storage overhead.
- SQLite schema is the requested composite primary key and uses prepared statements, WAL, a 64 MiB cache, a 1 GiB mmap ceiling, and `synchronous=FULL` for durable runs. Workload A uses `synchronous=OFF` because it explicitly requests no durability synchronization.
- Append latency uses deterministic randomized sample intervals averaging one in 1,024 public append calls. This avoids periodic aliasing and prevents two clock reads from dominating every 16-byte operation. Sync/checkpoint time is tracked separately in raw output.
- Query latency times every query and includes result traversal/consumption.
- Smooth values are deterministic trend-plus-sine telemetry. Random values come from pinned SplitMix64 output.
- Setup is outside query timing. Process startup is never timed.
- Run order rotates among engines on each repetition to reduce order and thermal bias.
- No tuning decision is based on measured winners.

## Reproduce

```bash
./bench/competitive/build.sh
python3 bench/competitive/run.py
```

The suite pins NanoTS, builds all engines locally, captures machine metadata, preserves raw JSONL, and regenerates this report and dependency-free SVG charts.
"""
(ROOT/"BENCHMARKS.md").write_text(md)
(out/"BENCHMARKS.md").write_text(md)
print(ROOT/"BENCHMARKS.md")
