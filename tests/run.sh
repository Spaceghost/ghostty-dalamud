#!/usr/bin/env bash
# Host-side tests: the Python source suites, the shipped per-platform policy,
# libghostty binding, renderer (fake ImGui), selection, Lua policy, and the agent
# end to end. Needs tools/build.sh (or at least its host parts:
# SKIP_WIN=1 SKIP_SHIM=1). Non-interactive; exits non-zero on the first failure
# and prints ALL OK at the end.
#
# Environment: GHOSTTY_TEST_PORT (loopback port for the agent test; default
# derived from the PID), GHOSTTY_TEST_CJK_FONT (a CJK font file for
# test_glyphfb to check the host CJK font of the fallback chain against a real
# one, for example Dalamud's UIRes/NotoSansCJK-Regular.ttc; the checks are
# skipped when it is unset, since no CJK font is small enough to ship here).
# Reads only this checkout (vendor/, build/) and, when set, that font.
#
# SAN=asan|ubsan|asan,ubsan|valgrind|1 builds and runs everything under that
# sanitizer instead (tools/sanitize.sh): a separate compiler, a separate Nelua
# cache and separate binaries, so a sanitizer run never touches the normal
# build. LeakSanitizer then also makes every test binary fail on an allocation
# it never frees. GHOSTTY_HEAP_ITERS raises the repeat count of every
# heap_stable loop (tests/heapcheck.nelua) for a soak. ONLY=agent runs just the
# agent end-to-end tests (the threaded part; for SAN=tsan, helgrind and drd).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# The tests are a heavy build too: place them like one (docs/BUILD_PLACEMENT.md).
if [[ "${BUILD_PLACEMENT:-1}" != 0 && -z "${CI:-}" && ! -d /cache \
      && -x "$ROOT/tools/run-placed.sh" ]]; then
  exec "$ROOT/tools/run-placed.sh" --name test --project "$ROOT" \
    --local "tests/run.sh${*:+ $*}" \
    --remote "tools/test-remote.sh"
fi

NELUA="$ROOT/vendor/nelua-lang/nelua"
export ZIG="${ZIG:-zig}" # tools/zig-cc.sh compiles every host build
CC="$ROOT/tools/zig-cc.sh"
SAN_SUFFIX=""
SAN_PREFIX=()
if [[ -n "${SAN:-}" ]]; then
  # shellcheck source=tools/sanitize.sh
  source "$ROOT/tools/sanitize.sh"
  CC="$ROOT/tools/san-cc.sh"
  # the Wayland compositor test drives a real GTK3 client; under a sanitizer it
  # reports that toolkit, not this code, so it is off unless asked for
  SKIP_WAYLAND="${SKIP_WAYLAND:-1}"
fi
NCACHE="build/nelua-cache$SAN_SUFFIX"
INC="-I$ROOT/vendor/ghostty/include -I$ROOT/vendor/gc-cimgui -I$ROOT/vendor/lua/src -I$ROOT/vendor/stb"
LIBS="-L$ROOT/build/ghostty-vt-linux/lib -L$ROOT/build/lua-linux -lm"
# The optional iroh staticlib (docs/IROH.md). Every host link here shares $LIBS,
# including core/host.nelua below, so this is the only place it is named. The
# guard is the built artifact: no crate, no build/lib, no change.
if [[ "${IROH:-0}" == 1 && -f "$ROOT/build/lib/libghostty_iroh.a" ]]; then
  LIBS="$LIBS -L$ROOT/build/lib -lghostty_iroh -lpthread -ldl -lm -lunwind"
fi
export LD_LIBRARY_PATH="$ROOT/build/ghostty-vt-linux/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# wait for an agent to listen (valgrind takes seconds to get there), or for it to die
wait_port() { # port pid
  for _ in $(seq 1 300); do
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && return 0
    kill -0 "$2" 2>/dev/null || return 1
    sleep 0.1
  done
  return 1
}
only_agent() { [[ "${ONLY:-}" == agent ]]; }
HEAP=""; getconf GNU_LIBC_VERSION >/dev/null 2>&1 && HEAP="-P glibc_heap" # heap accounting needs glibc's mallinfo2
# AddressSanitizer and valgrind replace malloc, so mallinfo2 no longer sees the
# program's own heap: those runs drop the accounting and let the sanitizer's own
# leak report be the check instead
case ",${SAN:-}," in *,asan,* | *,valgrind,*) HEAP="" ;; esac
# without the per-thread cache and fast bins, freed memory stops counting as in use
HEAP_ENV="glibc.malloc.tcache_count=0:glibc.malloc.mxfast=0"

run() { only_agent && return 0; echo "--- $1"; "$NELUA" --cc "$CC" -P nogc --cflags="$INC $LIBS" --cache-dir "$NCACHE" -L . -b "tests/$1.nelua"; "${SAN_PREFIX[@]}" "$NCACHE/$1" "${@:2}"; }

# Source checks first: they need no toolchain, so a portability or defaults
# mistake is reported in seconds instead of after the whole native build.
echo "--- python suites (portability, identity tooling)"
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*.py'
echo "--- test_defaults (shipped per-platform policy)"
"$ROOT/vendor/nelua-lang/nelua-lua" tests/test_defaults.lua
echo "--- test_world_spread (panels keeping off each other on screen)"
"$ROOT/vendor/nelua-lang/nelua-lua" tests/test_world_spread.lua
echo "--- test_motion (springs, bob and squash, pets keeping off walls, panels and characters)"
"$ROOT/vendor/nelua-lang/nelua-lua" tests/test_motion.lua
echo "--- test_ask_rich (the /ask answer: markdown, links, layout, drawing)"
GHOSTTY_TEST_SCRATCH="$ROOT/build/test-scratch/ask-rich" "$ROOT/vendor/nelua-lang/nelua-lua" tests/test_ask_rich.lua "$ROOT"
if [[ "${SKIP_SHIM:-0}" != 1 ]] && command -v dotnet >/dev/null; then
  echo "--- native cache isolation (C#, no game)"
  DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 dotnet run --project tests/cache/CacheTests.csproj -c Release
else
  echo "--- native cache isolation skipped (no dotnet, or SKIP_SHIM=1)"
fi

rm -f "$ROOT/animation-reset-done" "$ROOT/world-state.lua" "$ROOT/window-state.lua" "$ROOT/settings.lua" "$ROOT/adopted.lua" "$ROOT/ask-state.lua" "$ROOT/native-state.lua" # state files the Lua modules write next to lua/
unset UMBRA_GHOSTTY_HOME GHOSTTY_HOME # the migration and config home read these
rm -rf build/test-scratch && mkdir -p build/test-scratch/surface/config
run test_ghostty
run test_wincodec
run test_wg_crypto # the embedded WireGuard's primitives against published vectors
run test_wg        # the WireGuard protocol: two devices, a fake network and a fake clock
run test_wg_netstack # TCP and UDP through two tunnels and lwIP to loopback sockets, with back-pressure
mkdir -p build/test-scratch/wg
run test_wg_config "$ROOT/build/test-scratch/wg" # wireguard.conf, and a live service following it
run test_pngenc
run test_capture
run test_capture_win32
# shellcheck source=tools/wayland-flags.sh
source "$ROOT/tools/wayland-flags.sh" # the agent's Wayland compositor, when vendor/wayland-sdk is there
# shellcheck source=tools/netlab-flags.sh
source "$ROOT/tools/netlab-flags.sh" # the agent's netlab (moq over iroh), when vendor/moq-iroh is there
wlrun() { only_agent && return 0; echo "--- $1"; "$NELUA" --cc "$CC" -P nogc "${WAYLAND_DEFINE[@]}" --cflags="$INC $LIBS $WAYLAND_CFLAGS" --cache-dir "$NCACHE" -L . -b "tests/$1.nelua"; "${SAN_PREFIX[@]}" "$NCACHE/$1" "${@:2}"; }
# a test whose heap must not grow: compiled with mallinfo2 accounting and run
# with the allocator caches off (tests/heapcheck.nelua)
# shellcheck disable=SC2086 # HEAP is one optional flag
hrun() { only_agent && return 0; echo "--- $1"; "$NELUA" --cc "$CC" -P nogc $HEAP --cflags="$INC $LIBS" --cache-dir "$NCACHE" -L . -b "tests/$1.nelua"; GLIBC_TUNABLES=$HEAP_ENV "${SAN_PREFIX[@]}" "$NCACHE/$1" "${@:2}"; }
if [[ ${#WAYLAND_DEFINE[@]} -gt 0 ]]; then wlrun test_capture_wayland; else echo "--- test_capture_wayland skipped (no vendor/wayland-sdk or libwlroots-0.20)"; fi
run test_capture_mac
run test_desktop_entries "$ROOT/build/test-scratch"
run test_agent_browser
run test_render
hrun test_glyphfb "$ROOT" "${GHOSTTY_TEST_CJK_FONT:-}"
run test_session
run test_procpipe
run test_dualsense
run test_selection
run test_bell "$ROOT"
run test_rain "$ROOT"
run test_policy "$ROOT"
run test_world "$ROOT"
run test_worldpanel "$ROOT"
run test_fullflight
run test_worlddrag "$ROOT"
run test_worldhud "$ROOT"
run test_remotewin "$ROOT"
run test_adopt "$ROOT" "$ROOT/build/test-scratch"
run test_hudmask
run test_nativewin
run test_adopt_app "$ROOT"
run test_ipc "$ROOT"
run test_host "$ROOT"

hrun test_pending "$ROOT"
run test_lights "$ROOT"
run test_occluders "$ROOT"
run test_desk "$ROOT"
run test_lakitu "$ROOT"
run test_chrome "$ROOT"
run test_themes "$ROOT" "$ROOT/build/test-scratch"
run test_migrate "$ROOT" "$ROOT/build/test-scratch"
run test_vote "$ROOT" "$ROOT/build/test-scratch"
run test_gallery "$ROOT" "$ROOT/build/test-scratch"
# the clip encoder on the host: a stand-in for ffmpeg, in a scratch folder of its own
mkdir -p build/test-scratch/clips
GHOSTTY_CLIP_DIR="$ROOT/build/test-scratch/clips" GHOSTTY_FFMPEG="$ROOT/build/test-scratch/clips/fake-ffmpeg" \
  run test_clips "$ROOT/build/test-scratch/clips"
run test_platform "$ROOT" "$ROOT/build/test-scratch"
run test_winpath "$ROOT" "$ROOT/build/test-scratch"
run test_assistant "$ROOT"
mkdir -p build/test-scratch/ask
run test_ask "$ROOT" "$ROOT/build/test-scratch/ask"
run test_ask_draw "$ROOT"
run test_hostsurface "$ROOT" "$ROOT/build/test-scratch/surface"
run test_native_app "$ROOT"
run test_depthpass "$ROOT"
run test_selftest
# randomized VT streams, wire frames and agent strings; the seed makes a
# failure replayable (tests/fuzz.nelua)
hrun fuzz "${GHOSTTY_FUZZ_SEED:-20260919}" "${GHOSTTY_FUZZ_ITERS:-48}"
mkdir -p build/test-scratch/selftest
run test_selftest_run "$ROOT" "$ROOT/build/test-scratch/selftest"

hrun test_reinit "$ROOT"

run test_agent_logic

# netlab (docs/NETLAB.md): without moq_iroh every call says so; with it, a window
# over real iroh connections in this process. The Rust library is not
# instrumented, so sanitizer runs keep to the first.
nlrun() { only_agent && return 0; echo "--- $1 (netlab)"; "$NELUA" --cc "$CC" -P nogc "${NETLAB_DEFINE[@]}" --cflags="$INC $LIBS $NETLAB_CFLAGS" --cache-dir "$NCACHE-netlab" -L . -b "tests/$1.nelua"; "${SAN_PREFIX[@]}" "$NCACHE-netlab/$1" "${@:2}"; }
run test_netlab
if [[ ${#NETLAB_DEFINE[@]} -gt 0 && -z "${SAN:-}" ]]; then nlrun test_netlab; else echo "--- test_netlab (netlab) skipped (no vendor/moq-iroh, or a sanitizer run)"; fi

echo "--- test_agent"
"$NELUA" --cc "$CC" -P nogc "${AGENT_NELUA[@]}" --cache-dir "$NCACHE" -L . -o "build/ghostty-agent$SAN_SUFFIX" -b agent/agent.nelua
"$NELUA" --cc "$CC" -P nogc --cache-dir "$NCACHE" -L . -b tests/test_agent.nelua
echo "testtoken123" > build/agent-token
# a port per run, so test runs at the same time never share an agent
PORT="${GHOSTTY_TEST_PORT:-$((20000 + $$ % 20000))}"
"${SAN_PREFIX[@]}" "build/ghostty-agent$SAN_SUFFIX" --listen "127.0.0.1:$PORT" --token-file build/agent-token --clipboard-file build/agent-clipboard --windows off >build/agent.log 2>&1 &
AGENT=$!
trap 'kill $AGENT 2>/dev/null || true' EXIT
wait_port "$PORT" "$AGENT" || { cat build/agent.log; exit 1; }
"${SAN_PREFIX[@]}" "$NCACHE"/test_agent "$PORT" testtoken123 "$AGENT"

echo "--- test_wg_cli"
# `ghostty-agent wg`, the QR code, Tailscale detection and the listen rule, on the agent just built
"$NELUA" --cc "$CC" -P nogc --cache-dir "$NCACHE" -L . -b tests/test_wg_cli.nelua
rm -rf build/test-scratch/wgcli && mkdir -p build/test-scratch/wgcli
"${SAN_PREFIX[@]}" "$NCACHE"/test_wg_cli "$ROOT/build/ghostty-agent$SAN_SUFFIX" "$ROOT/build/test-scratch/wgcli"

echo "--- test_jobs"
"$NELUA" --cc "$ROOT/tools/zig-cc.sh" -P nogc --cache-dir build/nelua-cache -L . -b tests/test_jobs.nelua
build/nelua-cache/test_jobs "$PORT" testtoken123 "$AGENT"

echo "--- test_jobclient"
"$NELUA" --cc "$ROOT/tools/zig-cc.sh" -P nogc --cache-dir build/nelua-cache -L . -b tests/test_jobclient.nelua
build/nelua-cache/test_jobclient "$PORT" testtoken123

echo "--- test_agent_windows"
"$NELUA" --cc "$CC" -P nogc --cache-dir "$NCACHE" -L . -b tests/test_agent_windows.nelua
WPORT=$((PORT + 1))
"${SAN_PREFIX[@]}" "build/ghostty-agent$SAN_SUFFIX" --listen "127.0.0.1:$WPORT" --token-file build/agent-token --windows test >build/agent-windows.log 2>&1 &
WAGENT=$!
trap 'kill $AGENT $WAGENT 2>/dev/null || true' EXIT
wait_port "$WPORT" "$WAGENT" || { cat build/agent-windows.log; exit 1; }
# the first agent runs --windows off: window requests are refused with the reason
"${SAN_PREFIX[@]}" "$NCACHE"/test_agent_windows "$WPORT" testtoken123 "$PORT"

echo "--- test_netlab_agent"
"$NELUA" --cc "$CC" -P nogc --cache-dir "$NCACHE" -L . -b tests/test_netlab_agent.nelua
if [[ ${#NETLAB_DEFINE[@]} -gt 0 ]]; then NL_BUILT=1; else NL_BUILT=0; fi
"${SAN_PREFIX[@]}" "$NCACHE"/test_netlab_agent "$WPORT" testtoken123 "$NL_BUILT" "$PORT" || { tail -20 build/agent-windows.log; exit 1; }

if [[ ${#WAYLAND_DEFINE[@]} -gt 0 ]]; then
  # a real Wayland client (yad, GTK3) in the agent's compositor; frames land in build/test-scratch/wayland
  mkdir -p build/test-scratch/wayland
  wlrun test_wayland_compositor "$ROOT/build/test-scratch/wayland"
  echo "--- test_e2e_wayland"
  # the plugin's agent client against a real agent that is the compositor
  "$NELUA" --cc "$CC" -P nogc "${WAYLAND_DEFINE[@]}" --cflags="$WAYLAND_CFLAGS" --cache-dir "$NCACHE" -L . -o "build/ghostty-agent-wayland$SAN_SUFFIX" -b agent/agent.nelua
  "$NELUA" --cc "$CC" -P nogc --cache-dir "$NCACHE" -L . -b tests/test_e2e_wayland.nelua
  LPORT=$((PORT + 2)); LSOCK="ghostty-test-$$"; LTITLE="ghostty-e2e-$$"
  rm -f build/agent-wayland-clipboard
  env -u DISPLAY "build/ghostty-agent-wayland$SAN_SUFFIX" --listen "127.0.0.1:$LPORT" --token-file build/agent-token --windows wayland \
    --clipboard-file build/agent-wayland-clipboard \
    --wayland-socket "$LSOCK" >build/agent-wayland.log 2>&1 &
  LAGENT=$!
  sleep 0.5
  kill -0 "$LAGENT" || { cat build/agent-wayland.log; exit 1; }
  "${SAN_PREFIX[@]}" "$NCACHE"/test_e2e_wayland "$LPORT" testtoken123 "$ROOT/build/test-scratch/wayland" "$LTITLE" "$ROOT/build/agent-wayland-clipboard" || { cat build/agent-wayland.log; kill "$LAGENT"; exit 1; }
  # stopping the agent ends the app it launched (SIGTERM -> capture_wayland_shutdown)
  kill -TERM "$LAGENT"; wait "$LAGENT" || true
  sleep 0.3
  if pgrep -f -- "--title=$LTITLE" >/dev/null; then echo "an app outlived the agent"; pkill -f -- "--title=$LTITLE"; exit 1; fi
  grep -q stopping build/agent-wayland.log || { echo "the agent did not stop cleanly"; exit 1; }
  echo "agent stop ended the app OK"
else
  echo "--- test_wayland_compositor skipped (no vendor/wayland-sdk or libwlroots-0.20)"
fi

if [[ "${ONLY:-}" == agent ]]; then echo "ALL OK (agent only)"; exit 0; fi

echo "--- host module compiles natively"
"$NELUA" --cc "$CC" -P nogc -P noentrypoint --cflags="$INC $LIBS" --cache-dir "$NCACHE" -L . -H -o "build/libghostty_umbra_host$SAN_SUFFIX.so" core/host.nelua

echo "--- test_loader"
rm -rf "build/loader-test$SAN_SUFFIX" && mkdir -p "build/loader-test$SAN_SUFFIX" build/test-scratch/loader
"$NELUA" --cc "$CC" -P nogc -P noentrypoint --cache-dir "$NCACHE" -L . -H -o "build/loader-test$SAN_SUFFIX/libghostty_loader.so" core/loader.nelua
mv "build/loader-test$SAN_SUFFIX/libghostty_loader.so" "build/loader-test$SAN_SUFFIX/ghostty_loader.dll"
cp "build/libghostty_umbra_host$SAN_SUFFIX.so" "build/loader-test$SAN_SUFFIX/ghostty_core.dll"
"$NELUA" --cc "$CC" -P nogc --cache-dir "$NCACHE" -L . -b tests/test_loader.nelua
"${SAN_PREFIX[@]}" "$NCACHE"/test_loader "$ROOT/build/loader-test$SAN_SUFFIX" "$ROOT" "$ROOT/build/test-scratch/loader" "$ROOT/build/libghostty_umbra_host$SAN_SUFFIX.so"
echo "ALL OK"
