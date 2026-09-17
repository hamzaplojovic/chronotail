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
export DYLD_LIBRARY_PATH="$release/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
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
import chronotail

with chronotail.Writer("python.ctdb", batch_size=100, codec="compressed") as db:
    db.prepare("cpu", 3)
    db.append("cpu", array("q", [1000, 1001, 1002]), array("d", [42.5, 43.5, 44.5]))
    db.checkpoint()

with chronotail.Reader("python.ctdb") as db:
    assert db.range("cpu", 0, 2000) == [(1000, 42.5), (1001, 43.5), (1002, 44.5)]
    assert db.aggregate("cpu", 0, 2000).count == 3
PY

chronotail verify python.ctdb | grep -q 'records: 3'
printf 'SMOKE TEST PASSED: %s\n' "$(basename "$archive")"
