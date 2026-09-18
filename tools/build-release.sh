#!/usr/bin/env bash
# Build and test a private candidate. No upload, public release or upstream PR.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source toolchain.env
source tools/build-common.sh
require_linux_build_host
ZIG="${ZIG:-zig}"
DOTNET="${DOTNET:-dotnet}"
for tool in git make "$CC" ar curl python3 "$ZIG" "$DOTNET"; do
  command -v "$tool" >/dev/null || { printf 'Missing build prerequisite: %s\n' "$tool" >&2; exit 127; }
done
python3 -c 'import sys; assert sys.version_info >= (3, 11), "Python 3.11+ is required"'
[[ "$("$ZIG" version)" == "$ZIG_VERSION" ]] || { echo "Use Zig $ZIG_VERSION exactly." >&2; exit 2; }
[[ "$("$DOTNET" --version)" == 10.* ]] || { echo 'Use the .NET 10 SDK.' >&2; exit 2; }
export SKIP_UMBRA=1 SKIP_DEPS=0 SKIP_WIN=0 SKIP_SHIM=0
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 PYTHONDONTWRITEBYTECODE=1
python3 -m unittest discover -s tests -p 'test_*.py' -v
"$DOTNET" run --project tests/cache/CacheTests.csproj -c Release
"$DOTNET" run --project tests/NativeCache.Tests/NativeCache.Tests.csproj -c Release
tools/fetch-vendor.sh
SKIP_SHIM=1 tools/build.sh
DD="${DALAMUD_LIB_PATH:-$ROOT/vendor/dalamud}"
project=shim/GhosttyDalamud/GhosttyDalamud.csproj
lock=shim/GhosttyDalamud/packages.lock.json
restore=(--use-lock-file)
if git ls-files --error-unmatch "$lock" >/dev/null 2>&1; then
  restore+=(--locked-mode)
else
  echo 'First restore will generate packages.lock.json. Review/commit it, then rebuild before submission.' >&2
fi
"$DOTNET" restore "$project" "${restore[@]}" "-p:DalamudLibPath=$DD/"
"$DOTNET" build "$project" --no-restore -c Release "-p:DalamudLibPath=$DD/" -v minimal
vendor/nelua-lang/nelua-lua tests/test_defaults.lua
tests/run.sh
ZIP=build/plugin/GhosttyDalamud/GhosttyDalamud/latest.zip
mkdir -p build/release
python3 tools/release.py check --package "$ZIP" --output build/release/package-report.json
cp "$ZIP" build/release/GhosttyDalamud.zip
cp build/plugin/GhosttyDalamud/GhosttyDalamud.json build/release/GhosttyDalamud.json
echo 'Candidate built and host-tested: build/release/GhosttyDalamud.zip'
echo 'Windows/Wine in-game tests, public-source privacy and D17 review are still required.'
