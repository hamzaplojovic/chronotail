from __future__ import annotations

import os
import time
from array import array

import chronotail

COUNT = 1_000_000
BATCH_SIZES = (1, 100, 1_000, 10_000)
TIMESTAMPS = array("q", range(COUNT))
VALUES = array("d", [42.5]) * COUNT

for batch_size in BATCH_SIZES:
    path = f"python-batch-{batch_size}.ctdb"
    try:
        os.remove(path)
    except FileNotFoundError:
        pass

    start = time.perf_counter()
    with chronotail.open(path, batch_size=batch_size, codec="raw") as db:
        db.append_many("telemetry", TIMESTAMPS, VALUES)
        db.checkpoint()
    elapsed = time.perf_counter() - start
    print(
        f"batch={batch_size} elapsed={elapsed:.6f}s "
        f"writes/sec={COUNT / elapsed:.0f}"
    )
