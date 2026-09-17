#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
zig build bench-append -Doptimize=ReleaseFast
zig build bench-checkpoint -Doptimize=ReleaseFast
zig build bench-native-batch -Doptimize=ReleaseFast
