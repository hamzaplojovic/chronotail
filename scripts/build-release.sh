#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=$(awk -F'"' '/\.version =/ { print $2; exit }' "$ROOT/build.zig.zon")
source "$ROOT/scripts/targets.sh"
python3 "$ROOT/scripts/check-release.py"
rm -rf "$ROOT/dist" "$ROOT/.release"
mkdir -p "$ROOT/dist" "$ROOT/.release"

for target_spec in "${CHRONOTAIL_RELEASE_TARGETS[@]}"; do
  IFS='|' read -r release_name zig_target wheel_platform shared_library <<<"$target_spec"
  prefix="$ROOT/.release/$release_name/prefix"
  package="$ROOT/.release/$release_name/chronotail"

  zig build --build-file "$ROOT/build.zig" \
    -Dtarget="$zig_target" -Doptimize=ReleaseFast --prefix "$prefix"

  mkdir -p "$package/bin" "$package/lib" "$package/include" "$package/python" "$package/docs"
  cp "$prefix/bin/chronotail" "$package/bin/"
  cp "$prefix/lib/libchronotail.a" "$package/lib/"
  cp "$prefix/lib/$shared_library" "$package/lib/"
  cp "$ROOT/include/chronotail.h" "$package/include/"
  cp \
    "$ROOT/README.md" \
    "$ROOT/BENCHMARKS.md" \
    "$ROOT/LICENSE" \
    "$ROOT/RELEASE_NOTES.md" \
    "$package/"
  cp -R "$ROOT/docs/." "$package/docs/"
  mkdir -p "$package/clients/python/src/chronotail" "$package/clients/python/tests"
  cp "$ROOT/clients/README.md" "$package/clients/"
  cp -R "$ROOT/clients/c" "$ROOT/clients/go" "$ROOT/clients/zig" "$package/clients/"
  cp \
    "$ROOT/clients/python/MANIFEST.in" \
    "$ROOT/clients/python/README.md" \
    "$ROOT/clients/python/pyproject.toml" \
    "$package/clients/python/"
  cp \
    "$ROOT/clients/python/src/chronotail/__init__.py" \
    "$package/clients/python/src/chronotail/"
  cp \
    "$ROOT/clients/python/tests/test_client.py" \
    "$package/clients/python/tests/"
  cp "$ROOT/go.mod" "$package/"
  cp "$ROOT/scripts/smoke-release.sh" "$package/smoke-test.sh"

  python3 "$ROOT/scripts/build-wheel.py" \
    "$prefix/lib/$shared_library" "$wheel_platform" "$package/python"

  (
    cd "$package"
    shasum -a 256 bin/chronotail lib/* include/chronotail.h python/*.whl > SHA256SUMS
  )

  archive="$ROOT/dist/chronotail-$VERSION-$release_name.tar.gz"
  COPYFILE_DISABLE=1 tar -C "$(dirname "$package")" -czf "$archive" "$(basename "$package")"
  "$ROOT/scripts/smoke-release.sh" "$archive"
done

(cd "$ROOT/dist" && shasum -a 256 *.tar.gz > SHA256SUMS)
printf 'Built Chronotail %s release matrix in %s\n' "$VERSION" "$ROOT/dist"
