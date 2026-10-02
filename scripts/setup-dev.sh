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
if ! python3 -c 'import sys; raise SystemExit(sys.version_info < (3, 10))'; then
  if [[ "$(uname -s)" == Linux ]] && command -v dnf >/dev/null; then
    sudo dnf install -y python3.11 python3.11-pip
    mkdir -p .tools/bin
    ln -sf "$(command -v python3.11)" .tools/bin/python3
    export PATH="$PWD/.tools/bin:$PATH"
  else
    echo 'Python 3.10+ is required for the client/wheel gates.' >&2
    exit 1
  fi
fi
python3 scripts/setup-dev.py
