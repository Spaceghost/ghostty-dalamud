#!/usr/bin/env bash
# Build the native Windows core/loader, Linux host agent/tests, and C# shims.
# Run tools/fetch-vendor.sh first. Outputs land in build/dist/.
# Optional overrides: ZIG, DOTNET, CC, JOBS, DALAMUD_LIB_PATH, UMBRA_LIB_PATH.
# SKIP_SHIM=1, SKIP_UMBRA=1, SKIP_WIN=1 and SKIP_DEPS=1 support developer rebuilds.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/toolchain.env"
source "$ROOT/tools/build-common.sh"
cd "$ROOT"
require_linux_build_host

ZIG="${ZIG:-zig}"
DOTNET="${DOTNET:-dotnet}"
NELUA="$ROOT/vendor/nelua-lang/nelua"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$HOME/.cache/zig-global}"
mkdir -p build/dist build/win/lib build/win/cache build/lua-win build/lua-linux build/nelua-cache

if ! command -v "$ZIG" >/dev/null; then echo "zig $ZIG_VERSION is required (set ZIG=/path/to/zig)" >&2; exit 127; fi
if [[ "$("$ZIG" version)" != "$ZIG_VERSION" ]]; then echo "error: this build requires Zig $ZIG_VERSION; set ZIG to the matching binary" >&2; exit 2; fi

if [[ "${SKIP_DEPS:-0}" != 1 ]]; then
  echo '== nelua'
  build_nelua
  "$NELUA" --version | sed -n 1p

  echo '== libghostty-vt (host)'
  ( cd vendor/ghostty && "$ZIG" build -Demit-lib-vt -Dapp-runtime=none -Doptimize=ReleaseFast \
      --cache-dir "$ROOT/build/zig-cache-linux" --prefix "$ROOT/build/ghostty-vt-linux" )
  ( cd build/ghostty-vt-linux/lib && for f in libghostty-vt.so.[0-9]*; do [[ -e "$f" ]] || continue; ln -sf "$f" libghostty-vt.so; break; done )
  if [[ "${SKIP_WIN:-0}" != 1 ]]; then
    echo '== libghostty-vt (windows x64)'
    ( cd vendor/ghostty && "$ZIG" build -Demit-lib-vt -Dapp-runtime=none -Doptimize=ReleaseFast -Dtarget=x86_64-windows-gnu \
        --cache-dir "$ROOT/build/zig-cache-win" --prefix "$ROOT/build/ghostty-vt-windows" )
    cp build/ghostty-vt-windows/lib/ghostty-vt-static.lib build/win/lib/libghostty-vt.a
  fi

  echo '== lua (host)'
  ( cd build/lua-linux && for f in ../../vendor/lua/src/*.c; do b=$(basename "$f" .c)
      case $b in lua|luac) continue;; esac; "$CC" -O2 -fPIC -c "$f" -o "$b.o"; done; ar rcs liblua.a ./*.o )
  if [[ "${SKIP_WIN:-0}" != 1 ]]; then
    echo '== lua (windows x64)'
    ( cd build/lua-win && for f in ../../vendor/lua/src/*.c; do b=$(basename "$f" .c)
        case $b in lua|luac) continue;; esac; "$ZIG" cc -target x86_64-windows-gnu -O2 -c "$f" -o "$b.o"; done
      "$ZIG" ar rcs liblua.a ./*.o )
  fi
fi

[[ -x "$ROOT/vendor/nelua-lang/nelua-lua" ]] || { echo 'Nelua is not built; rerun without SKIP_DEPS=1' >&2; exit 1; }
INC="-I\"$ROOT/vendor/ghostty/include\" -I\"$ROOT/vendor/gc-cimgui\" -I\"$ROOT/vendor/lua/src\""

echo '== ghostty-agent (host)'
"$NELUA" --cc "$CC" -P nogc --cache-dir build/nelua-cache -L . -o build/dist/ghostty-agent -b agent/agent.nelua
mkdir -p build/dist/lua && cp lua/*.lua build/dist/lua/

if [[ "${SKIP_WIN:-0}" != 1 ]]; then
  echo '== ghostty_core.dll (windows x64)'
  rm -f build/dist/ghostty_umbra.dll build/dist/ghostty_umbra.pdb
  ZIG="$ZIG" "$NELUA" --cc "$ROOT/tools/zig-cc-win.sh" -P nogc -P noentrypoint -P "writestderr='hooked'" -P "abort='hooked'" \
    --cflags="-O2 $INC -L\"$ROOT/build/win/lib\" -L\"$ROOT/build/lua-win\"" \
    --cache-dir build/win/cache -L . -H -o build/dist/ghostty_core.dll core/host.nelua
  echo '== ghostty_loader.dll (windows x64)'
  ZIG="$ZIG" "$NELUA" --cc "$ROOT/tools/zig-cc-win.sh" -P nogc -P noentrypoint -P "writestderr='hooked'" -P "abort='hooked'" \
    --cflags="-O2 $INC -L\"$ROOT/build/win/lib\" -L\"$ROOT/build/lua-win\"" \
    --cache-dir build/win/cache -L . -H -o build/dist/ghostty_loader.dll core/loader.nelua
fi

# Reference assemblies must not shadow the runtime supplied by the host.
forbid_host_assemblies() {
  local found
  found="$(find "$@" -maxdepth 1 \( -name 'Dalamud*.dll' -o -name 'Umbra.dll' -o -name 'Umbra.Common.dll' -o -name 'Umbra.Game.dll' \
    -o -name 'Una.Drawing.dll' -o -name 'FFXIVClientStructs.dll' -o -name 'InteropGenerator*.dll' -o -name 'Lumina*.dll' \) -print)"
  if [[ -n "$found" ]]; then echo 'error: host assemblies in the output:' >&2; echo "$found" >&2; exit 1; fi
}

if [[ "${SKIP_SHIM:-0}" != 1 ]]; then
  DD="${DALAMUD_LIB_PATH:-$ROOT/vendor/dalamud}"
  [[ -f "$DD/Dalamud.dll" ]] || { echo 'Missing Dalamud references; run tools/fetch-vendor.sh' >&2; exit 1; }
  if [[ "${SKIP_UMBRA:-0}" != 1 ]]; then
    echo '== Umbra.Ghostty.dll (Umbra toolbar widget)'
    DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 "$DOTNET" build shim/Umbra.Ghostty/Umbra.Ghostty.csproj -c Release \
      "-p:DalamudLibPath=$DD/" "-p:UmbraLibPath=${UMBRA_LIB_PATH:-$ROOT/vendor/umbra-dist/dist}/" -v quiet
    forbid_host_assemblies build/shim
    cp build/shim/Umbra.Ghostty.dll build/dist/
    [[ -f build/shim/Umbra.Ghostty.pdb ]] && cp build/shim/Umbra.Ghostty.pdb build/dist/ || true
  fi

  echo '== GhosttyDalamud.dll (Dalamud plugin)'
  DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 "$DOTNET" build shim/GhosttyDalamud/GhosttyDalamud.csproj -c Release \
    "-p:DalamudLibPath=$DD/" -v quiet
  forbid_host_assemblies build/plugin/GhosttyDalamud

  if [[ -f build/dist/ghostty_core.dll && -f build/dist/ghostty_loader.dll ]]; then
    echo '== build/dist/GhosttyDalamud (plugin folder)'
    P=build/dist/GhosttyDalamud
    rm -rf "$P.tmp" && mkdir -p "$P.tmp/lua"
    cp build/plugin/GhosttyDalamud/GhosttyDalamud.dll build/plugin/GhosttyDalamud/GhosttyDalamud.json "$P.tmp/"
    [[ -f build/plugin/GhosttyDalamud/GhosttyDalamud.pdb ]] && cp build/plugin/GhosttyDalamud/GhosttyDalamud.pdb "$P.tmp/" || true
    cp build/dist/ghostty_core.dll build/dist/ghostty_loader.dll "$P.tmp/"
    cp lua/*.lua "$P.tmp/lua/"
    for f in GhosttyDalamud.dll GhosttyDalamud.json ghostty_core.dll ghostty_loader.dll lua/init.lua lua/migrate.lua; do
      [[ -f "$P.tmp/$f" ]] || { echo "error: $f missing from the plugin folder" >&2; exit 1; }
    done
    forbid_host_assemblies "$P.tmp"
    rm -rf "$P" && mv "$P.tmp" "$P"
  fi
elif [[ -f build/dist/GhosttyDalamud/GhosttyDalamud.dll && "${SKIP_WIN:-0}" != 1 ]]; then
  echo '== build/dist/GhosttyDalamud (native and lua/ only)'
  P=build/dist/GhosttyDalamud
  cp build/dist/ghostty_core.dll build/dist/ghostty_loader.dll "$P/"
  rm -rf "$P/lua.tmp" && mkdir -p "$P/lua.tmp" && cp lua/*.lua "$P/lua.tmp/"
  rm -rf "$P/lua" && mv "$P/lua.tmp" "$P/lua"
fi

rm -f build/dist/host.lib
echo '== done: build/dist'
ls -la build/dist
