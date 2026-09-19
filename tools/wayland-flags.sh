#!/usr/bin/env bash
# Sourced by tools/build.sh and tests/run.sh: when vendor/wayland-sdk (pinned
# headers, tools/fetch-vendor.sh) and the host's libwlroots-0.20 are both
# present, WAYLAND_NELUA holds the Nelua flags that compile the agent's
# Wayland compositor backend (agent/capture_wayland.nelua) in (for builds that
# pass no --cflags of their own; the others combine WAYLAND_DEFINE and
# WAYLAND_CFLAGS); otherwise all three are empty and the agent builds without it. build/wayland-libs gets
# unversioned symlinks to the host libraries for the linker.
# shellcheck disable=SC2034 # used by the scripts that source this
WAYLAND_NELUA=()
WAYLAND_DEFINE=()
WAYLAND_CFLAGS=""
wayland_sdk="$ROOT/vendor/wayland-sdk/include"
if [[ "$(uname -s)" == Linux && -f "$ROOT/vendor/wayland-sdk/.pinned" && "${SKIP_WAYLAND:-0}" != 1 ]]; then
  wayland_libdir=""
  for d in /usr/lib64 /usr/lib/x86_64-linux-gnu /usr/lib; do
    if [[ -e "$d/libwlroots-0.20.so" ]]; then wayland_libdir="$d"; break; fi
  done
  if [[ -n "$wayland_libdir" ]]; then
    mkdir -p "$ROOT/build/wayland-libs"
    ln -sfn "$wayland_libdir/libwlroots-0.20.so" "$ROOT/build/wayland-libs/libwlroots-0.20.so"
    for l in wayland-server xkbcommon pixman-1; do
      ln -sfn "$wayland_libdir/lib$l.so.0" "$ROOT/build/wayland-libs/lib$l.so"
    done
    # shellcheck disable=SC2034
    WAYLAND_DEFINE=(-D WAYLAND)
    WAYLAND_CFLAGS="-I$wayland_sdk -I$wayland_sdk/wlroots-0.20 -I$wayland_sdk/pixman-1 -L$ROOT/build/wayland-libs"
    # shellcheck disable=SC2034
    WAYLAND_NELUA=(-D WAYLAND "--cflags=$WAYLAND_CFLAGS")
  else
    echo "note: no libwlroots-0.20.so on this host; the agent builds without the Wayland compositor"
  fi
fi
