#!/usr/bin/env bash
# Source from Bash; keep this workspace's tools isolated from the user's shell.
CHRONOTAIL_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export PATH="$CHRONOTAIL_ROOT/.tools/bin:$PATH"
export CGO_ENABLED=1
export GOTOOLCHAIN=local
export CGO_LDFLAGS="-L$CHRONOTAIL_ROOT/zig-out/lib${CGO_LDFLAGS:+ $CGO_LDFLAGS}"
export LD_LIBRARY_PATH="$CHRONOTAIL_ROOT/zig-out/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export DYLD_LIBRARY_PATH="$CHRONOTAIL_ROOT/zig-out/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
export PYTHONPATH="$CHRONOTAIL_ROOT/clients/python/src${PYTHONPATH:+:$PYTHONPATH}"
case "$(uname -s)" in
  Darwin) export CHRONOTAIL_LIBRARY="$CHRONOTAIL_ROOT/zig-out/lib/libchronotail.dylib" ;;
  Linux) export CHRONOTAIL_LIBRARY="$CHRONOTAIL_ROOT/zig-out/lib/libchronotail.so" ;;
esac
