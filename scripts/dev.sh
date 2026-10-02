#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/dev-env.sh"
cd "$CHRONOTAIL_ROOT"
mkdir -p .dev-results

require_tools() {
  command -v zig >/dev/null || { echo 'Run python3 scripts/setup-dev.py first' >&2; exit 1; }
  test "$(zig version)" = 0.15.2
}

metadata() {
  python3 scripts/dev/metadata.py .dev-results/environment.json
}

lint() {
  require_tools
  zig fmt --check build.zig src sim tests tools bench
  python3 scripts/check-docs.py
  python3 scripts/check-release.py
  python3 -m unittest discover -s tests/dev -p 'test_*.py'
  python3 -m py_compile scripts/*.py scripts/dev/*.py clients/python/src/chronotail/__init__.py
  for script in scripts/*.sh tools/*.sh; do bash -n "$script"; done
  command -v gofmt >/dev/null
  local unformatted
  unformatted=$(gofmt -l clients/go)
  test -z "$unformatted" || { echo "$unformatted" >&2; return 1; }
  git diff --check
}

clients() {
  require_tools
  zig build -Doptimize=ReleaseFast
  python3 -m unittest discover -s clients/python/tests
  go vet ./clients/go/...
  go test -race ./clients/go/...
  local compiler=${CC:-cc}
  "$compiler" -std=c11 -Wall -Wextra -Werror clients/c/example.c \
    -Iinclude -Lzig-out/lib -lchronotail -o .dev-results/c-client
  local work
  work=$(mktemp -d "$CHRONOTAIL_ROOT/.dev-results/c-smoke.XXXXXX")
  (cd "$work"; "$CHRONOTAIL_ROOT/.dev-results/c-client")
  rm -rf "$work"
}

simulate() {
  require_tools
  metadata
  python3 - <<'PY'
import json, os
from pathlib import Path
config = {name: int(os.environ.get('CHRONOTAIL_SIM_' + name.upper(), default))
          for name, default in [('seed', '1'), ('seeds', '100'), ('operations', '100000')]}
assert 0 <= config['seed'] < 2**64
assert config['seeds'] > 0 and config['operations'] > 0
assert config['seed'] + config['seeds'] - 1 < 2**64
Path('.dev-results/simulator-config.json').write_text(json.dumps(config, indent=2) + '\n')
print('Simulator reproduction:', config, flush=True)
PY
  zig build simulator -Doptimize=ReleaseFast
  ./zig-out/bin/chronotail-sim --seed "${CHRONOTAIL_SIM_SEED:-1}" \
    --seeds "${CHRONOTAIL_SIM_SEEDS:-100}" \
    --operations "${CHRONOTAIL_SIM_OPERATIONS:-100000}" \
    2>&1 | tee .dev-results/simulator.txt
}

profile() {
  require_tools
  metadata
  local args=()
  if [[ "${1:-quick}" == quick ]]; then args+=(--quick); fi
  zig build performance -Doptimize=ReleaseFast -- \
    "${args[@]}" --output .dev-results/profile.jsonl \
    2>&1 | tee .dev-results/profile.log
  python3 scripts/check-profile.py .dev-results/profile.jsonl
}

case "${1:-quick}" in
  lint) lint ;;
  test) require_tools; zig build test "-Doptimize=${2:-Debug}" ;;
  clients) clients ;;
  simulate) simulate ;;
  profile) profile "${2:-quick}" ;;
  quick) lint; zig build test; clients; CHRONOTAIL_SIM_SEEDS=10 simulate; profile quick ;;
  full)
    lint
    for mode in Debug ReleaseSafe ReleaseFast; do zig build test "-Doptimize=$mode"; done
    clients
    CHRONOTAIL_SIM_SEED=1 CHRONOTAIL_SIM_SEEDS=1000 CHRONOTAIL_SIM_OPERATIONS=100000 simulate
    profile full
    ;;
  release)
    [[ "$(uname -s)-$(uname -m)" == Darwin-arm64 ]] || { echo 'Release validation requires native macOS ARM64' >&2; exit 1; }
    "$0" full
    ./scripts/build-release.sh
    ;;
  *) echo 'usage: scripts/dev.sh [quick|lint|test [MODE]|clients|simulate|profile [quick|full]|full|release]' >&2; exit 2 ;;
esac
