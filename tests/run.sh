#!/usr/bin/env bash
# Host-side tests: libghostty binding, renderer (fake ImGui), selection, Lua policy,
# platform defaults, and the agent end to end. Needs tools/build.sh (or at
# least its host parts: SKIP_WIN=1 SKIP_SHIM=1). Non-interactive; exits
# non-zero on the first failure and prints ALL OK at the end.
#
# Environment: GHOSTTY_TEST_PORT (loopback port for the agent test; default
# derived from the PID). Reads only this checkout (vendor/, build/).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
NELUA="$ROOT/vendor/nelua-lang/nelua"
export ZIG="${ZIG:-zig}" # tools/zig-cc.sh compiles every host build
INC="-I$ROOT/vendor/ghostty/include -I$ROOT/vendor/gc-cimgui -I$ROOT/vendor/lua/src"
LIBS="-L$ROOT/build/ghostty-vt-linux/lib -L$ROOT/build/lua-linux -lm"
export LD_LIBRARY_PATH="$ROOT/build/ghostty-vt-linux/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
run() { echo "--- $1"; "$NELUA" --cc "$ROOT/tools/zig-cc.sh" -P nogc --cflags="$INC $LIBS" --cache-dir build/nelua-cache -L . -b "tests/$1.nelua"; "build/nelua-cache/$1" "${@:2}"; }

rm -f "$ROOT/animation-reset-done" "$ROOT/world-state.lua" "$ROOT/settings.lua" "$ROOT/adopted.lua" # state files the Lua modules write next to lua/
unset UMBRA_GHOSTTY_HOME GHOSTTY_HOME # the migration and config home read these
rm -rf build/test-scratch && mkdir -p build/test-scratch/surface/config
run test_ghostty
run test_wincodec
run test_capture_win32
# shellcheck source=tools/wayland-flags.sh
source "$ROOT/tools/wayland-flags.sh" # the agent's Wayland compositor, when vendor/wayland-sdk is there
wlrun() { echo "--- $1"; "$NELUA" --cc "$ROOT/tools/zig-cc.sh" -P nogc "${WAYLAND_DEFINE[@]}" --cflags="$INC $LIBS $WAYLAND_CFLAGS" --cache-dir build/nelua-cache -L . -b "tests/$1.nelua"; "build/nelua-cache/$1" "${@:2}"; }
if [[ ${#WAYLAND_DEFINE[@]} -gt 0 ]]; then wlrun test_capture_wayland; else echo "--- test_capture_wayland skipped (no vendor/wayland-sdk or libwlroots-0.20)"; fi
run test_capture_mac
run test_desktop_entries "$ROOT/build/test-scratch"
run test_render
run test_session
run test_dualsense
run test_selection
run test_bell "$ROOT"
run test_rain "$ROOT"
run test_policy "$ROOT"
run test_world "$ROOT"
run test_worldpanel "$ROOT"
run test_worlddrag "$ROOT"
run test_remotewin "$ROOT"
run test_adopt "$ROOT" "$ROOT/build/test-scratch"
run test_adopt_app "$ROOT"
run test_ipc "$ROOT"
run test_host "$ROOT"

HEAP=""; getconf GNU_LIBC_VERSION >/dev/null 2>&1 && HEAP="-P glibc_heap" # heap accounting needs glibc's mallinfo2
# without the per-thread cache and fast bins, freed memory stops counting as in use
HEAP_ENV="glibc.malloc.tcache_count=0:glibc.malloc.mxfast=0"
echo "--- test_pending"
# shellcheck disable=SC2086
"$NELUA" --cc "$ROOT/tools/zig-cc.sh" -P nogc $HEAP --cflags="$INC $LIBS" --cache-dir build/nelua-cache -L . -b tests/test_pending.nelua
GLIBC_TUNABLES=$HEAP_ENV build/nelua-cache/test_pending "$ROOT"
run test_lights "$ROOT"
run test_occluders "$ROOT"
run test_chrome "$ROOT"
run test_themes "$ROOT" "$ROOT/build/test-scratch"
run test_migrate "$ROOT" "$ROOT/build/test-scratch"
run test_vote "$ROOT" "$ROOT/build/test-scratch"
run test_platform "$ROOT" "$ROOT/build/test-scratch"
run test_assistant "$ROOT"
run test_hostsurface "$ROOT" "$ROOT/build/test-scratch/surface"
run test_depthpass "$ROOT"
run test_selftest
mkdir -p build/test-scratch/selftest
run test_selftest_run "$ROOT" "$ROOT/build/test-scratch/selftest"

echo "--- test_reinit"
# shellcheck disable=SC2086
"$NELUA" --cc "$ROOT/tools/zig-cc.sh" -P nogc $HEAP --cflags="$INC $LIBS" --cache-dir build/nelua-cache -L . -b tests/test_reinit.nelua
GLIBC_TUNABLES=$HEAP_ENV build/nelua-cache/test_reinit "$ROOT"

run test_agent_logic

echo "--- test_agent"
"$NELUA" --cc "$ROOT/tools/zig-cc.sh" -P nogc "${WAYLAND_NELUA[@]}" --cache-dir build/nelua-cache -L . -o build/ghostty-agent -b agent/agent.nelua
"$NELUA" --cc "$ROOT/tools/zig-cc.sh" -P nogc --cache-dir build/nelua-cache -L . -b tests/test_agent.nelua
echo "testtoken123" > build/agent-token
# a port per run, so test runs at the same time never share an agent
PORT="${GHOSTTY_TEST_PORT:-$((20000 + $$ % 20000))}"
build/ghostty-agent --listen "127.0.0.1:$PORT" --token-file build/agent-token --clipboard-file build/agent-clipboard --windows off >build/agent.log 2>&1 &
AGENT=$!
trap 'kill $AGENT 2>/dev/null || true' EXIT
sleep 0.5
kill -0 "$AGENT" || { cat build/agent.log; exit 1; }
build/nelua-cache/test_agent "$PORT" testtoken123 "$AGENT"

echo "--- test_agent_windows"
"$NELUA" --cc "$ROOT/tools/zig-cc.sh" -P nogc --cache-dir build/nelua-cache -L . -b tests/test_agent_windows.nelua
WPORT=$((PORT + 1))
build/ghostty-agent --listen "127.0.0.1:$WPORT" --token-file build/agent-token --windows test >build/agent-windows.log 2>&1 &
WAGENT=$!
trap 'kill $AGENT $WAGENT 2>/dev/null || true' EXIT
sleep 0.5
kill -0 "$WAGENT" || { cat build/agent-windows.log; exit 1; }
# the first agent runs --windows off: window requests are refused with the reason
build/nelua-cache/test_agent_windows "$WPORT" testtoken123 "$PORT"

if [[ ${#WAYLAND_DEFINE[@]} -gt 0 ]]; then
  # a real Wayland client (yad, GTK3) in the agent's compositor; frames land in build/test-scratch/wayland
  mkdir -p build/test-scratch/wayland
  wlrun test_wayland_compositor "$ROOT/build/test-scratch/wayland"
  echo "--- test_e2e_wayland"
  # the plugin's agent client against a real agent that is the compositor
  "$NELUA" --cc "$ROOT/tools/zig-cc.sh" -P nogc "${WAYLAND_DEFINE[@]}" --cflags="$WAYLAND_CFLAGS" --cache-dir build/nelua-cache -L . -o build/ghostty-agent-wayland -b agent/agent.nelua
  "$NELUA" --cc "$ROOT/tools/zig-cc.sh" -P nogc --cache-dir build/nelua-cache -L . -b tests/test_e2e_wayland.nelua
  LPORT=$((PORT + 2)); LSOCK="ghostty-test-$$"; LTITLE="ghostty-e2e-$$"
  rm -f build/agent-wayland-clipboard
  env -u DISPLAY build/ghostty-agent-wayland --listen "127.0.0.1:$LPORT" --token-file build/agent-token --windows wayland \
    --clipboard-file build/agent-wayland-clipboard \
    --wayland-socket "$LSOCK" >build/agent-wayland.log 2>&1 &
  LAGENT=$!
  sleep 0.5
  kill -0 "$LAGENT" || { cat build/agent-wayland.log; exit 1; }
  build/nelua-cache/test_e2e_wayland "$LPORT" testtoken123 "$ROOT/build/test-scratch/wayland" "$LTITLE" "$ROOT/build/agent-wayland-clipboard" || { cat build/agent-wayland.log; kill "$LAGENT"; exit 1; }
  # stopping the agent ends the app it launched (SIGTERM -> capture_wayland_shutdown)
  kill -TERM "$LAGENT"; wait "$LAGENT" || true
  sleep 0.3
  if pgrep -f -- "--title=$LTITLE" >/dev/null; then echo "an app outlived the agent"; pkill -f -- "--title=$LTITLE"; exit 1; fi
  grep -q stopping build/agent-wayland.log || { echo "the agent did not stop cleanly"; exit 1; }
  echo "agent stop ended the app OK"
else
  echo "--- test_wayland_compositor skipped (no vendor/wayland-sdk or libwlroots-0.20)"
fi

echo "--- host module compiles natively"
"$NELUA" --cc "$ROOT/tools/zig-cc.sh" -P nogc -P noentrypoint --cflags="$INC $LIBS" --cache-dir build/nelua-cache -L . -H -o build/libghostty_umbra_host.so core/host.nelua

echo "--- test_loader"
rm -rf build/loader-test && mkdir -p build/loader-test build/test-scratch/loader
"$NELUA" --cc "$ROOT/tools/zig-cc.sh" -P nogc -P noentrypoint --cache-dir build/nelua-cache -L . -H -o build/loader-test/libghostty_loader.so core/loader.nelua
mv build/loader-test/libghostty_loader.so build/loader-test/ghostty_loader.dll
cp build/libghostty_umbra_host.so build/loader-test/ghostty_core.dll
"$NELUA" --cc "$ROOT/tools/zig-cc.sh" -P nogc --cache-dir build/nelua-cache -L . -b tests/test_loader.nelua
build/nelua-cache/test_loader "$ROOT/build/loader-test" "$ROOT" "$ROOT/build/test-scratch/loader" "$ROOT/build/libghostty_umbra_host.so"
echo "ALL OK"
