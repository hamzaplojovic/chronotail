#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v cc >/dev/null; then
  if [[ "$(uname -s)" == Linux ]] && command -v dnf >/dev/null; then
    sudo dnf install -y gcc gcc-c++ clang
  else
    echo 'Install a C/C++ toolchain (Xcode Command Line Tools on macOS), then retry.' >&2
    exit 1
  fi
fi
python3 scripts/setup-dev.py
