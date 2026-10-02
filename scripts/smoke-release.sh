#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <chronotail-release.tar.gz>" >&2
  exit 2
fi

archive=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

tar -xzf "$archive" -C "$work"
release="$work/chronotail"
export PATH="$release/bin:$PATH"
unset CHRONOTAIL_LIBRARY PYTHONPATH LD_LIBRARY_PATH
export DYLD_LIBRARY_PATH="$release/lib"
cd "$work"

if [[ "$(uname -s)-$(uname -m)" != "Darwin-arm64" ]]; then
  echo "this release artifact supports macOS ARM64 only" >&2
  exit 1
fi

chronotail append metrics.ctdb cpu 1000 42.5
chronotail append metrics.ctdb cpu 1001 43.5
test "$(chronotail range metrics.ctdb cpu 0 2000)" = $'1000 42.5\n1001 43.5'
chronotail verify metrics.ctdb | grep -q 'OK: committed state valid'
chronotail inspect metrics.ctdb | grep -q 'Chronotail v7'

python3 -m pip install --quiet --no-index --target "$work/site" "$release"/python/*.whl
PYTHONPATH="$work/site" python3 - <<'PY'
from array import array
from pathlib import Path
from contextlib import closing
import struct
import chronotail

assert Path(chronotail._lib._name).resolve().parent == Path(chronotail.__file__).resolve().parent / "_native", "wheel did not load its packaged native library"

with chronotail.Writer("python.ctdb", batch_size=100, codec="compressed") as db:
    db.prepare("cpu", 3)
    db.append("cpu", array("q", [1000, 1001, 1002]), array("d", [42.5, 43.5, 44.5]))
    db.checkpoint()

with chronotail.Writer("telemetry.ctdb", batch_size=1024, codec="compressed") as db:
    db.append("pressure", array("q", [1000, 1010, 1030]),
              array("d", [0.0, -0.0, struct.unpack("=d", struct.pack("=Q", 0x7ff8000000000123))[0]]))
    db.append("limits", -(1 << 63), struct.unpack("=d", struct.pack("=Q", 1))[0])
    db.append("history", array("q", (i * 7 + i % 5 for i in range(20_000))),
              array("d", (float(i) for i in range(20_000))))
    db.checkpoint()

with chronotail.Reader("telemetry.ctdb") as db:
    pressure = db.prepare("pressure")
    for mode, target, expected_timestamp, expected_bits in (
        (chronotail.LookupMode.EXACT, 1010, 1010, 0x8000000000000000),
        (chronotail.LookupMode.PREDECESSOR, 1020, 1010, 0x8000000000000000),
        (chronotail.LookupMode.SUCCESSOR, 1020, 1030, 0x7ff8000000000123),
        (chronotail.LookupMode.NEAREST, 1020, 1010, 0x8000000000000000),
    ):
        named = db.lookup("pressure", target, mode, max_distance=10)
        prepared = db.lookup_prepared(pressure, target, mode, max_distance=10)
        for point in (named, prepared):
            assert point is not None and point[0] == expected_timestamp
            assert struct.unpack("=Q", struct.pack("=d", point[1]))[0] == expected_bits
    assert db.lookup("pressure", 1020, chronotail.LookupMode.PREDECESSOR, max_distance=9) is None
    assert db.lookup("pressure", 1000, chronotail.LookupMode.EXACT, max_distance=0) == (1000, 0.0)
    point = db.lookup("limits", (1 << 63) - 1, chronotail.LookupMode.NEAREST, max_distance=(1 << 64) - 1)
    assert point[0] == -(1 << 63) and struct.unpack("=Q", struct.pack("=d", point[1]))[0] == 1
    assert db.lookup("limits", (1 << 63) - 1, chronotail.LookupMode.NEAREST, max_distance=(1 << 64) - 2) is None
    count = 0
    with closing(db.iter_range("history", 0, (1 << 63) - 1, batch_size=137)) as points:
        for timestamp, value in points:
            assert timestamp == count * 7 + count % 5 and value == count
            count += 1
    assert count == 20_000

with chronotail.Reader("python.ctdb") as db:
    assert db.range("cpu", 0, 2000) == [(1000, 42.5), (1001, 43.5), (1002, 44.5)]
    assert db.aggregate("cpu", 0, 2000).count == 3
PY

chronotail verify python.ctdb | grep -q 'records: 3'

clang -std=c11 "$release/clients/c/example.c" \
  -I"$release/include" \
  -L"$release/lib" -lchronotail \
  -Wl,-rpath,"$release/lib" \
  -o "$work/c-client-smoke"
"$work/c-client-smoke"

clang -std=c11 -Wall -Wextra -Werror "$release/clients/c/lookup_test.c" \
  -I"$release/include" -L"$release/lib" -lchronotail \
  -Wl,-rpath,"$release/lib" -o "$work/c-lookup-smoke"
"$work/c-lookup-smoke"
clang++ -std=c++17 -Wall -Wextra -Werror "$release/clients/c/lookup_header_test.cpp" \
  -I"$release/include" -L"$release/lib" -lchronotail \
  -Wl,-rpath,"$release/lib" -o "$work/c-lookup-header-smoke"
"$work/c-lookup-header-smoke"

(
  cd "$release"
  CGO_LDFLAGS="-L$release/lib" go run ./clients/go/cmd/smoke
)
printf 'SMOKE TEST PASSED: %s\n' "$(basename "$archive")"
