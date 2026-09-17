#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
profile=${1:-raw-range}
case "$profile" in
  append|raw-point|raw-range|compressed-range|checkpoint|refresh) ;;
  *) echo "usage: $0 [append|raw-point|raw-range|compressed-range|checkpoint|refresh]" >&2; exit 2 ;;
esac

mkdir -p "$ROOT/.profile"
executable="$ROOT/.profile/perf-probe"
cd "$ROOT"
zig build-exe -O ReleaseFast -fno-strip --dep chronotail \
  -Mroot=tools/perf_probe.zig -Mchronotail=src/chronotail.zig \
  -femit-bin="$executable"

if command -v xctrace >/dev/null 2>&1 && xctrace version >/dev/null 2>&1; then
  output="$ROOT/.profile/$profile.trace"
  rm -rf "$output"
  xctrace record --template 'Time Profiler' --output "$output" --launch -- "$executable" "$profile"
  echo "profile written to $output"
elif command -v perf >/dev/null 2>&1; then
  perf record -g --output="$ROOT/.profile/$profile.perf.data" -- "$executable" "$profile"
  echo "profile written to .profile/$profile.perf.data"
elif command -v sample >/dev/null 2>&1; then
  "$executable" "$profile" &
  pid=$!
  sleep 0.05
  sample "$pid" 1 -file "$ROOT/.profile/$profile.sample.txt" || true
  wait "$pid"
  echo "profile written to .profile/$profile.sample.txt"
else
  echo "No supported system profiler found; running probe directly."
  "$executable" "$profile"
fi
