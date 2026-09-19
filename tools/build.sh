#!/usr/bin/env bash
# Build everything:
#   1. Nelua compiler (the project's fork, NELUA_REPOSITORY in toolchain.env)
#   2. libghostty-vt for the host (tests) and for Windows (plugin) with Zig
#   3. Lua 5.4 static libs for host and Windows
#   4. ghostty_core.dll   (Nelua core, Windows x64) and ghostty_loader.dll
#      (Nelua, loads a copy of the core and swaps it when the file changes)
#   5. ghostty-agent      (Nelua, host Linux/macOS PTY server) and
#      ghostty-agent.exe  (the same agent for Windows: ConPTY, Winsock)
#   6. GhosttyDalamud.dll (Dalamud plugin shim) and Umbra.Ghostty.dll (Umbra
#      toolbar widget), both C#, need dotnet 10
# Output lands in build/dist/ (fixed paths); build/dist/GhosttyDalamud/ is the
# loadable plugin folder (tools/install-dev.sh stages it, tools/package.sh
# zips it). Non-interactive; exits non-zero when any step fails. Needs
# vendor/ (tools/fetch-vendor.sh) and nothing else outside this checkout.
#
# Environment overrides: ZIG (zig binary), DOTNET (dotnet binary),
# DALAMUD_LIB_PATH (Dalamud dev assemblies, default ~/.cache/dalamud-dev),
# UMBRA_LIB_PATH (Umbra assemblies, default vendor/umbra-dist/dist),
# ZIG_GLOBAL_CACHE_DIR (default ~/.cache/zig-global),
# BUILD_COMMIT (default: `git rev-parse HEAD`, plus "-dirty" when core/,
# lua/ or agent/ have uncommitted changes), BUILD_ID (default:
# <UTC time>-<commit, 12>-<6 random hex>); both are stamped into
# ghostty_core.dll (core/buildinfo.nelua, `/term selftest`, gu_version) and
# written to build/dist/build-info.json,
# SKIP_WAYLAND=1 (agent without the Wayland compositor), SKIP_SHIM=1 (no C#; refreshes only the native files and lua/ of an existing
# build/dist/GhosttyDalamud), SKIP_UMBRA=1 (no widget), SKIP_WIN=1 (no
# Windows core, loader or agent), SKIP_DEPS=1 (reuse the Nelua,
# libghostty-vt and Lua builds already in build/), MAC=1 (also cross-compile
# ghostty-agent for macOS arm64 and x86_64; untested on a Mac).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/toolchain.env"
cd "$ROOT"

export ZIG="${ZIG:-zig}"
DOTNET="${DOTNET:-dotnet}"
NELUA="$ROOT/vendor/nelua-lang/nelua"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$HOME/.cache/zig-global}"
mkdir -p build/dist build/win/lib build/win/cache build/lua-win build/lua-linux build/nelua-cache

if ! command -v "$ZIG" >/dev/null; then echo "zig $ZIG_VERSION is required (set ZIG=/path/to/zig)"; exit 127; fi
if [[ "$("$ZIG" version)" != "$ZIG_VERSION" ]]; then echo "warning: zig $("$ZIG" version) found, toolchain.env pins $ZIG_VERSION"; fi

if [[ "${SKIP_DEPS:-0}" != 1 ]]; then
  echo "== nelua"
  [[ -x "$NELUA" ]] || make -C vendor/nelua-lang -j"$(nproc)" >/dev/null
  "$NELUA" --version | sed -n 1p

  echo "== libghostty-vt (host)"
  ( cd vendor/ghostty && "$ZIG" build -Demit-lib-vt -Dapp-runtime=none -Doptimize=ReleaseFast \
      --cache-dir "$ROOT/build/zig-cache-linux" --prefix "$ROOT/build/ghostty-vt-linux" )
  ( cd build/ghostty-vt-linux/lib && for f in libghostty-vt.so.[0-9]*; do ln -sf "$f" libghostty-vt.so; break; done )
  if [[ "${SKIP_WIN:-0}" != 1 ]]; then
    echo "== libghostty-vt (windows x64)"
    ( cd vendor/ghostty && "$ZIG" build -Demit-lib-vt -Dapp-runtime=none -Doptimize=ReleaseFast -Dtarget=x86_64-windows-gnu \
        --cache-dir "$ROOT/build/zig-cache-win" --prefix "$ROOT/build/ghostty-vt-windows" )
    cp build/ghostty-vt-windows/lib/ghostty-vt-static.lib build/win/lib/libghostty-vt.a
  fi

  echo "== lua (host)"
  ( cd build/lua-linux && for f in ../../vendor/lua/src/*.c; do b=$(basename "$f" .c)
      case $b in lua|luac) continue;; esac; cc -O2 -fPIC -c "$f" -o "$b.o"; done; ar rcs liblua.a ./*.o )
  if [[ "${SKIP_WIN:-0}" != 1 ]]; then
    echo "== lua (windows x64)"
    ( cd build/lua-win && for f in ../../vendor/lua/src/*.c; do b=$(basename "$f" .c)
        case $b in lua|luac) continue;; esac; "$ZIG" cc -target x86_64-windows-gnu -O2 -c "$f" -o "$b.o"; done
      "$ZIG" ar rcs liblua.a ./*.o )
  fi
fi

# Build stamp: which commit this core is, and which build (docs/CI.md, "In-game tests")
if [[ -z "${BUILD_COMMIT:-}" ]]; then
  BUILD_COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
  if [[ "$BUILD_COMMIT" != unknown ]] && ! git -C "$ROOT" diff --quiet HEAD -- core lua agent 2>/dev/null; then
    BUILD_COMMIT="$BUILD_COMMIT-dirty"
  fi
fi
BUILD_ID="${BUILD_ID:-$(date -u +%Y%m%dT%H%M%SZ)-${BUILD_COMMIT:0:12}-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')}"
for v in "$BUILD_COMMIT" "$BUILD_ID"; do
  [[ "$v" =~ ^[A-Za-z0-9._-]{1,96}$ ]] || { echo "error: build stamp '$v' must be [A-Za-z0-9._-], at most 96 characters"; exit 1; }
done
STAMP=(-P "build_commit='$BUILD_COMMIT'" -P "build_id='$BUILD_ID'")
echo "== build stamp: commit $BUILD_COMMIT, build $BUILD_ID"

INC="-I$ROOT/vendor/ghostty/include -I$ROOT/vendor/gc-cimgui -I$ROOT/vendor/lua/src -I$ROOT/vendor/stb"

echo "== ghostty-agent (host)"
# shellcheck source=tools/wayland-flags.sh
source "$ROOT/tools/wayland-flags.sh" # the Wayland compositor backend when its SDK is there
[[ ${#WAYLAND_NELUA[@]} -gt 0 ]] && echo "with the Wayland compositor (wlroots 0.20)"
"$NELUA" --cc "$ROOT/tools/zig-cc.sh" -P nogc "${WAYLAND_NELUA[@]}" --cache-dir build/nelua-cache -L . -o build/dist/ghostty-agent -b agent/agent.nelua
mkdir -p build/dist/lua && cp lua/*.lua build/dist/lua/
mkdir -p build/dist/themes && cp themes/*.theme build/dist/themes/

if [[ "${SKIP_WIN:-0}" != 1 ]]; then
  echo "== ghostty_core.dll (windows x64)"
  rm -f build/dist/ghostty_umbra.dll build/dist/ghostty_umbra.pdb # the name before the standalone plugin
  ZIG="$ZIG" "$NELUA" --cc "$ROOT/tools/zig-cc-win.sh" -P nogc -P noentrypoint -P "writestderr='hooked'" -P "abort='hooked'" "${STAMP[@]}" \
    --cflags="-O2 $INC -L$ROOT/build/win/lib -L$ROOT/build/lua-win" \
    --cache-dir build/win/cache -L . -H -o build/dist/ghostty_core.dll core/host.nelua
  printf '{"commit":"%s","build_id":"%s"}\n' "$BUILD_COMMIT" "$BUILD_ID" >build/dist/build-info.json
  echo "== ghostty_loader.dll (windows x64)"
  ZIG="$ZIG" "$NELUA" --cc "$ROOT/tools/zig-cc-win.sh" -P nogc -P noentrypoint -P "writestderr='hooked'" -P "abort='hooked'" \
    --cflags="-O2 $INC -L$ROOT/build/win/lib -L$ROOT/build/lua-win" \
    --cache-dir build/win/cache -L . -H -o build/dist/ghostty_loader.dll core/loader.nelua
  echo "== ghostty-agent.exe (windows x64)"
  ZIG="$ZIG" "$NELUA" --cc "$ROOT/tools/zig-cc-win.sh" -P nogc --cflags="-O2" \
    --cache-dir build/win/cache-agent -L . -o build/dist/ghostty-agent.exe agent/agent.nelua
fi

if [[ "${MAC:-0}" == 1 ]]; then
  # cross-compiled only: never run on a Mac from this build (docs/REMOTE_WINDOWS.md)
  for arch in arm64 x86_64; do
    echo "== ghostty-agent (macos $arch)"
    cc="$ROOT/tools/zig-cc-mac.sh"; [[ $arch == x86_64 ]] && cc="$ROOT/tools/zig-cc-mac-x64.sh"
    ZIG="$ZIG" "$NELUA" --cc "$cc" -P nogc --cflags="-O2" \
      --cache-dir "build/mac-cache-$arch" -L . -o "build/dist/ghostty-agent-macos-$arch" agent/agent.nelua
  done
fi

# Game and Dalamud assemblies are referenced, never shipped: a copy beside the
# plugin would shadow the ones Dalamud loads.
forbid_host_assemblies() {
  local found
  found="$(find "$@" -maxdepth 1 \( -name 'Dalamud*.dll' -o -name 'Umbra.dll' -o -name 'Umbra.Common.dll' -o -name 'Umbra.Game.dll' \
    -o -name 'Una.Drawing.dll' -o -name 'FFXIVClientStructs.dll' -o -name 'InteropGenerator*.dll' -o -name 'Lumina*.dll' \) -print)"
  if [[ -n "$found" ]]; then echo "error: host assemblies in the output:"; echo "$found"; exit 1; fi
}

if [[ "${SKIP_SHIM:-0}" != 1 ]]; then
  DD="${DALAMUD_LIB_PATH:-$HOME/.cache/dalamud-dev}"
  if [[ "${SKIP_UMBRA:-0}" != 1 ]]; then
    echo "== Umbra.Ghostty.dll (Umbra toolbar widget)"
    DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 "$DOTNET" build shim/Umbra.Ghostty/Umbra.Ghostty.csproj -c Release \
      "-p:DalamudLibPath=$DD/" "-p:UmbraLibPath=${UMBRA_LIB_PATH:-$ROOT/vendor/umbra-dist/dist}/" -v quiet
    forbid_host_assemblies build/shim
    cp build/shim/Umbra.Ghostty.dll build/dist/
    [[ -f build/shim/Umbra.Ghostty.pdb ]] && cp build/shim/Umbra.Ghostty.pdb build/dist/ || true
  fi

  echo "== GhosttyDalamud.dll (Dalamud plugin)"
  DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 "$DOTNET" build shim/GhosttyDalamud/GhosttyDalamud.csproj -c Release \
    "-p:DalamudLibPath=$DD/" -v quiet
  forbid_host_assemblies build/plugin/GhosttyDalamud

  if [[ -f build/dist/ghostty_core.dll && -f build/dist/ghostty_loader.dll ]]; then
    echo "== build/dist/GhosttyDalamud (plugin folder)"
    P=build/dist/GhosttyDalamud
    rm -rf "$P.tmp" && mkdir -p "$P.tmp/lua" "$P.tmp/themes" "$P.tmp/fonts"
    cp build/plugin/GhosttyDalamud/GhosttyDalamud.dll build/plugin/GhosttyDalamud/GhosttyDalamud.json "$P.tmp/"
    [[ -f build/plugin/GhosttyDalamud/GhosttyDalamud.pdb ]] && cp build/plugin/GhosttyDalamud/GhosttyDalamud.pdb "$P.tmp/" || true
    cp build/dist/ghostty_core.dll build/dist/ghostty_loader.dll "$P.tmp/"
    cp lua/*.lua "$P.tmp/lua/"
    cp themes/*.theme "$P.tmp/themes/"
    cp fonts/*.ttf fonts/LICENSE-* "$P.tmp/fonts/"
    for f in GhosttyDalamud.dll GhosttyDalamud.json ghostty_core.dll ghostty_loader.dll lua/init.lua lua/migrate.lua themes/spaceghost.theme fonts/SymbolsNerdFontMono-Regular.ttf; do
      [[ -f "$P.tmp/$f" ]] || { echo "error: $f missing from the plugin folder"; exit 1; }
    done
    forbid_host_assemblies "$P.tmp"
    rm -rf "$P" && mv "$P.tmp" "$P"
  fi
elif [[ -f build/dist/GhosttyDalamud/GhosttyDalamud.dll && "${SKIP_WIN:-0}" != 1 ]]; then
  # core and Lua changes need no dotnet: refresh the native files and lua/ of
  # the plugin folder a full build made, keep its managed files
  echo "== build/dist/GhosttyDalamud (native and lua/ only)"
  P=build/dist/GhosttyDalamud
  cp build/dist/ghostty_core.dll build/dist/ghostty_loader.dll "$P/"
  rm -rf "$P/lua.tmp" && mkdir -p "$P/lua.tmp" && cp lua/*.lua "$P/lua.tmp/"
  rm -rf "$P/lua" && mv "$P/lua.tmp" "$P/lua"
fi

rm -f build/dist/host.lib
echo "== done: build/dist"
ls -la build/dist
