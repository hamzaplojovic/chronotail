#!/usr/bin/env python3
"""Run the complete, pinned competitive benchmark matrix."""
from __future__ import annotations
import datetime as dt
import json
import os
import pathlib
import platform
import shutil
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
C = ROOT / "bench/competitive"
BINARY = C / "build/competitive"
WORK = C / "work"
RESULTS = ROOT / "bench/results"
RUNS = 5
APPEND_POINTS = 10_000_000
MULTI_POINTS = 1_000_000
QUERY_POINTS = 1_000_000
QUERIES = 100_000
SYNC_10M = 10 * 1024 * 1024 // 16
SYNC_1M = 1024 * 1024 // 16

def output(cmd: list[str]) -> str:
    return subprocess.check_output(cmd, text=True, stderr=subprocess.STDOUT).strip()

def machine() -> dict:
    def maybe(cmd):
        try: return output(cmd)
        except Exception as e: return f"unavailable: {e}"
    return {
        "started_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "platform": platform.platform(),
        "uname": maybe(["uname", "-a"]),
        "macos": maybe(["sw_vers"]),
        "cpu": maybe(["sysctl", "-n", "machdep.cpu.brand_string"]),
        "logical_cpus": maybe(["sysctl", "-n", "hw.ncpu"]),
        "ram_bytes": maybe(["sysctl", "-n", "hw.memsize"]),
        "filesystem": maybe(["diskutil", "info", "/"]),
        "zig": maybe(["zig", "version"]),
        "clang": maybe(["clang", "--version"]),
        "cmake": maybe(["cmake", "--version"]),
        "python": sys.version,
        "nanots_commit": output(["git", "-C", str(C/"vendor/nanots"), "rev-parse", "HEAD"]),
        "sqlite_header_version": next(x for x in (C/"vendor/nanots/sqlite3.h").read_text(errors="ignore").splitlines() if x.startswith("#define SQLITE_VERSION ")),
        "chronotail_abi": 1,
        "chronotail_format": 6,
        "run_count": RUNS,
        "latency_sampling": "append: deterministic randomized intervals averaging 1/1024 calls; queries: every call; concurrency readers: every 256th aggregate query",
        "cache_policy": "warm OS page cache; cold cache not run because macOS cache eviction requires privileged global purge",
    }

def main() -> None:
    subprocess.run([str(C/"build.sh")], check=True)
    if len(sys.argv)==3 and sys.argv[1]=="--resume":
        outdir=pathlib.Path(sys.argv[2]).resolve();run_id=outdir.name
    else:
        run_id = dt.datetime.now().strftime("%Y%m%d-%H%M%S");outdir = RESULTS / run_id;outdir.mkdir(parents=True)
    WORK.mkdir(parents=True, exist_ok=True)
    if not (outdir/"environment.json").exists():(outdir/"environment.json").write_text(json.dumps(machine(), indent=2)+"\n")
    previous=[json.loads(x) for x in (outdir/"raw.jsonl").read_text().splitlines()] if (outdir/"raw.jsonl").exists() else []
    complete={(x["workload"],x["engine"],x["run"]) for x in previous}
    raw = (outdir/"raw.jsonl").open("a", buffering=1)
    commands = (outdir/"commands.log").open("a", buffering=1)

    def run(args: list[str]):
        if args[0] in ("append","query"): expected={(str(args[-1] if args[0]=="append" else args[-2]),str(args[1]),int(args[-2] if args[0]=="append" else args[-3]))}
        else: expected={(str(args[-1])+suffix,str(args[1]),int(args[-2])) for suffix in ("-writer","-readers")}
        if expected <= complete:
            commands.write("SKIP completed: "+" ".join(map(str,args))+"\n");return
        cmd = [str(BINARY), *map(str,args)]
        commands.write(" ".join(cmd)+"\n")
        started=time.time()
        proc=subprocess.run(cmd,text=True,capture_output=True)
        commands.write(proc.stderr)
        if proc.returncode: raise RuntimeError(f"failed ({proc.returncode}): {' '.join(cmd)}\n{proc.stderr}")
        for line in proc.stdout.splitlines():
            record=json.loads(line);record["wall_started_unix"]=started;raw.write(json.dumps(record,separators=(",",":"))+"\n");complete.add((record["workload"],record["engine"],record["run"]))
        # Avoid retaining the largest files and give background writeback a chance.
        shutil.rmtree(WORK, ignore_errors=True);WORK.mkdir()
        time.sleep(1)

    engines=("chronotail","nanots","sqlite")
    for rep in range(1,RUNS+1):
        # Rotate order each repetition to reduce systematic thermal/order bias.
        order=engines[(rep-1)%3:]+engines[:(rep-1)%3]
        for label,boundary in (("append-A-none",0),("append-B-10MiB",SYNC_10M),("append-C-1MiB",SYNC_1M)):
            for e in order: run(["append",e,WORK/f"{e}.db",APPEND_POINTS,1,boundary,"raw","smooth",rep,label])
        for e in order: run(["append",e,WORK/f"{e}.db",MULTI_POINTS,8,SYNC_10M,"raw","smooth",rep,"append-8-series"])

        for e in order: run(["query",e,WORK/f"{e}.db",QUERY_POINTS,QUERIES,1,"raw",rep,"point-lookup-warm",4242+rep])
        for e in order: run(["query",e,WORK/f"{e}.db",QUERY_POINTS,QUERIES,100,"raw",rep,"range-100-raw-warm",5252+rep])
        run(["query","chronotail",WORK/"chronotail.db",QUERY_POINTS,QUERIES,100,"compressed",rep,"range-100-compressed-warm",5252+rep])

        for readers in (1,8,32):
            for e in order: run(["concurrent",e,WORK/f"{e}.db",readers,10,rep,f"concurrent-{readers}"])

        for pattern in ("smooth","random"):
            run(["append","chronotail",WORK/"ct-raw.db",APPEND_POINTS,1,0,"raw",pattern,rep,f"storage-{pattern}-raw"])
            run(["append","chronotail",WORK/"ct-compressed.db",APPEND_POINTS,1,0,"compressed",pattern,rep,f"storage-{pattern}-compressed"])
            run(["append","nanots",WORK/"nanots.db",APPEND_POINTS,1,0,"raw",pattern,rep,f"storage-{pattern}"])
            run(["append","sqlite",WORK/"sqlite.db",APPEND_POINTS,1,0,"raw",pattern,rep,f"storage-{pattern}"])

    raw.close();commands.close()
    subprocess.run([sys.executable,str(C/"summarize.py"),str(outdir)],check=True)
    (RESULTS/"LATEST").write_text(run_id+"\n")
    print(outdir)

if __name__ == "__main__": main()
