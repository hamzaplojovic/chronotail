#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
source "$ROOT/bench/competitive/versions.env"
dir="$ROOT/bench/competitive/vendor/nanots"
if [[ ! -d "$dir/.git" ]]; then
  rm -rf "$dir"
  git clone "$NANOTS_REPOSITORY" "$dir"
fi
git -C "$dir" fetch --depth 1 origin "$NANOTS_COMMIT"
git -C "$dir" checkout --detach "$NANOTS_COMMIT"
test "$(git -C "$dir" rev-parse HEAD)" = "$NANOTS_COMMIT"
