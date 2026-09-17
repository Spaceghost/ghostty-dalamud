#!/usr/bin/env bash
# Produce a private testing artifact, not a public release or an upstream PR.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export SKIP_UMBRA=1
# Never accept development shortcut flags for a candidate package.
export SKIP_DEPS=0 SKIP_WIN=0 SKIP_SHIM=0
source "$ROOT/toolchain.env"
ZIG="${ZIG:-zig}"
[[ "$("$ZIG" version)" == "$ZIG_VERSION" ]] || {
  echo "Release candidates require Zig $ZIG_VERSION exactly." >&2; exit 1;
}
tools/fetch-vendor.sh
tools/build.sh
ZIP=build/plugin/GhosttyDalamud/GhosttyDalamud/latest.zip
mkdir -p build/release
python3 tools/release.py check --package "$ZIP" --output build/release/package-report.json
cp "$ZIP" build/release/GhosttyDalamud.zip
cp build/plugin/GhosttyDalamud/GhosttyDalamud.json build/release/GhosttyDalamud.json
# No repo.json is published automatically. See docs/PUBLISHING.md.
echo 'Testing artifact: build/release/GhosttyDalamud.zip'
