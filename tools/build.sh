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
# Environment overrides: ZIG (zig binary), DOTNET (dotnet binary), CC (host C
# compiler for the Lua objects), JOBS (parallel make jobs for the Nelua build),
# DALAMUD_LIB_PATH (Dalamud reference assemblies, default vendor/dalamud from
# tools/fetch-vendor.sh),
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
# ghostty-agent for macOS arm64 and x86_64; untested on a Mac),
# IROH=1 (also build and link the optional Rust staticlib crates/ghostty-iroh;
# off by default, and a checkout without that crate is unaffected either way --
# docs/IROH.md, docs/iroh-build-wiring.md).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/toolchain.env"
source "$ROOT/tools/build-common.sh"
cd "$ROOT"
require_linux_build_host

# Where does this build belong? Unless something has already answered that
# (BUILD_PLACEMENT=0: inside the build container, under CI, or under a wrapper
# that decided), tools/run-placed.sh decides — and moves the build to the build
# host if the game starts while it runs. See docs/BUILD_PLACEMENT.md.
if [[ "${BUILD_PLACEMENT:-1}" != 0 && -z "${CI:-}" && ! -d "$BUILD_CONTAINER_CACHE" \
      && -x "$ROOT/tools/run-placed.sh" ]]; then
  exec "$ROOT/tools/run-placed.sh" --name build --project "$ROOT" \
    --local "tools/build.sh${*:+ $*}" \
    --remote "tools/build-remote.sh build"
fi

export ZIG="${ZIG:-zig}"
DOTNET="${DOTNET:-dotnet}"
NELUA="$ROOT/vendor/nelua-lang/nelua"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$HOME/.cache/zig-global}"
mkdir -p build/dist build/win/lib build/win/cache build/lua-win build/lua-linux build/nelua-cache
# Optional Rust transport staticlib. Leaves every variable below empty, and so
# every flag it contributes empty, unless IROH=1 and the crate is present.
iroh_probe

# GHOSTTY_SCCACHE=1 (the Incus build container, docs/BUILDING.md) routes every
# plain -c compile through the shared sccache: tools/zig-cc*.sh re-exec
# themselves under it. Nelua compiles and links in one invocation, which
# sccache does not cache; those reuse the shared Zig and Nelua caches instead.

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
  # absolute source paths: build/lua-* may be a symlink into a shared cache
  ( cd build/lua-linux && for f in "$ROOT"/vendor/lua/src/*.c; do b=$(basename "$f" .c)
      case $b in lua|luac) continue;; esac; "$CC" -O2 -fPIC -c "$f" -o "$b.o"; done; ar rcs liblua.a ./*.o )
  if [[ "${SKIP_WIN:-0}" != 1 ]]; then
    echo '== lua (windows x64)'
    ( cd build/lua-win && for f in "$ROOT"/vendor/lua/src/*.c; do b=$(basename "$f" .c)
        case $b in lua|luac) continue;; esac; "$ROOT/tools/zig-cc-win.sh" -O2 -c "$f" -o "$b.o"; done
      "$ZIG" ar rcs liblua.a ./*.o )
  fi
  # No-op unless iroh_probe enabled it; respects SKIP_WIN the same way.
  build_iroh
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

[[ -x "$ROOT/vendor/nelua-lang/nelua-lua" ]] || { echo 'Nelua is not built; rerun without SKIP_DEPS=1' >&2; exit 1; }
# Quoted so a checkout path with spaces still compiles (tests/test_portability.py).
INC="-I\"$ROOT/vendor/ghostty/include\" -I\"$ROOT/vendor/gc-cimgui\" -I\"$ROOT/vendor/lua/src\" -I\"$ROOT/vendor/stb\""

echo "== ghostty-agent (host)"
# shellcheck source=tools/wayland-flags.sh
source "$ROOT/tools/wayland-flags.sh" # the Wayland compositor backend when its SDK is there
[[ ${#WAYLAND_NELUA[@]} -gt 0 ]] && echo "with the Wayland compositor (wlroots 0.20)"
# ONE --cflags. Nelua keeps the last it is given, so passing a second here
# silently dropped every Wayland link flag and the agent failed to find
# xkbcommon, wayland-server and pixman-1.
AGENT_CFLAGS="$WAYLAND_CFLAGS"
AGENT_NELUA=("${WAYLAND_DEFINE[@]}")
[[ -n "$(iroh_host_ldflags)" ]] && AGENT_NELUA+=(-D IROH)
[[ -n "$AGENT_CFLAGS" ]] && AGENT_NELUA+=("--cflags=$AGENT_CFLAGS")
[[ -n "$(iroh_host_ldflags)" ]] && AGENT_NELUA+=("--ldflags=$(iroh_host_ldflags)")
"$NELUA" --cc "$ROOT/tools/zig-cc.sh" -P nogc "${AGENT_NELUA[@]}" --cache-dir build/nelua-cache -L . -o build/dist/ghostty-agent -b agent/agent.nelua
mkdir -p build/dist/lua && cp lua/*.lua build/dist/lua/
mkdir -p build/dist/themes && cp themes/*.theme build/dist/themes/

if [[ "${SKIP_WIN:-0}" != 1 ]]; then
  # -D IROH must ride along with the link flags: without it net.nelua compiles
  # its iroh half out, the linker has nothing to pull, and the build succeeds
  # while producing a core with no iroh in it.
  IROH_WIN_DEF=()
  [[ -n "$(iroh_win_ldflags)" ]] && IROH_WIN_DEF=(-D IROH)
  echo "== ghostty_core.dll (windows x64)"
  rm -f build/dist/ghostty_umbra.dll build/dist/ghostty_umbra.pdb # the name before the standalone plugin
  ZIG="$ZIG" "$NELUA" --cc "$ROOT/tools/zig-cc-win.sh" -P nogc -P noentrypoint -P "writestderr='hooked'" -P "abort='hooked'" "${STAMP[@]}" "${IROH_WIN_DEF[@]}" \
    --cflags="-O2 $INC -L\"$ROOT/build/win/lib\" -L\"$ROOT/build/lua-win\"" --ldflags="$(iroh_win_ldflags)" \
    --cache-dir build/win/cache -L . -H -o build/dist/ghostty_core.dll core/host.nelua
  printf '{"commit":"%s","build_id":"%s"}\n' "$BUILD_COMMIT" "$BUILD_ID" >build/dist/build-info.json
  echo "== ghostty_loader.dll (windows x64)"
  ZIG="$ZIG" "$NELUA" --cc "$ROOT/tools/zig-cc-win.sh" -P nogc -P noentrypoint -P "writestderr='hooked'" -P "abort='hooked'" "${IROH_WIN_DEF[@]}" \
    --cflags="-O2 $INC -L\"$ROOT/build/win/lib\" -L\"$ROOT/build/lua-win\"" --ldflags="$(iroh_win_ldflags)" \
    --cache-dir build/win/cache -L . -H -o build/dist/ghostty_loader.dll core/loader.nelua
  echo "== ghostty-agent.exe (windows x64)"
  ZIG="$ZIG" "$NELUA" --cc "$ROOT/tools/zig-cc-win.sh" -P nogc "${IROH_WIN_DEF[@]}" --cflags="-O2" --ldflags="$(iroh_win_ldflags)" \
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
    rm -rf "$P.tmp" && mkdir -p "$P.tmp/lua" "$P.tmp/themes" "$P.tmp/fonts"
    cp build/plugin/GhosttyDalamud/GhosttyDalamud.dll build/plugin/GhosttyDalamud/GhosttyDalamud.json "$P.tmp/"
    # KamiToolKit (game windows, docs/NATIVE_UI.md) loads from beside the plugin
    cp build/plugin/GhosttyDalamud/KamiToolKit.dll "$P.tmp/"
    [[ -d build/plugin/GhosttyDalamud/Assets ]] && cp -r build/plugin/GhosttyDalamud/Assets "$P.tmp/" || true
    [[ -f build/plugin/GhosttyDalamud/GhosttyDalamud.pdb ]] && cp build/plugin/GhosttyDalamud/GhosttyDalamud.pdb "$P.tmp/" || true
    cp build/dist/ghostty_core.dll build/dist/ghostty_loader.dll "$P.tmp/"
    cp lua/*.lua "$P.tmp/lua/"
    cp themes/*.theme "$P.tmp/themes/"
    cp fonts/*.ttf fonts/LICENSE-* "$P.tmp/fonts/"
    for f in GhosttyDalamud.dll GhosttyDalamud.json KamiToolKit.dll ghostty_core.dll ghostty_loader.dll lua/init.lua lua/migrate.lua themes/spaceghost.theme fonts/SymbolsNerdFontMono-Regular.ttf 'fonts/NotoEmoji[wght].ttf'; do
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
