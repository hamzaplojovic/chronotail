#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
C="$ROOT/bench/competitive"
"$C/fetch.sh"
rm -rf "$C/build"
mkdir -p "$C/build/chronotail" "$C/build/nanots"
cd "$ROOT"
zig build -Doptimize=ReleaseFast --prefix "$C/build/chronotail"
cmake -S "$C/vendor/nanots" -B "$C/build/nanots" -DCMAKE_BUILD_TYPE=Release
cmake --build "$C/build/nanots" --config Release -j "$(sysctl -n hw.ncpu 2>/dev/null || nproc)" --target nanots
# Standalone SQLite uses the exact same amalgamation as NanoTS, but its own symbols.
clang -O3 -DNDEBUG -c "$C/vendor/nanots/sqlite3.c" -o "$C/build/nanots/sqlite-benchmark.o"
clang++ -std=c++20 -O3 -DNDEBUG \
  -I"$ROOT/include" -I"$C/vendor/nanots" \
  "$C/competitive.cpp" "$C/build/nanots/sqlite-benchmark.o" \
  -L"$C/build/nanots" -lnanots -L"$C/build/chronotail/lib" -lchronotail \
  -Wl,-rpath,"$C/build/chronotail/lib" -Wl,-rpath,"$C/build/nanots" \
  -framework CoreFoundation -framework Security \
  -o "$C/build/competitive"
test "$("$C/build/competitive" 2>&1 || true)" = "ERROR: missing command"
echo "Built $C/build/competitive"
