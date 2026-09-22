#!/usr/bin/env bash
# Sourced by tools/build.sh, tools/build-agent.sh and tests/run.sh: when both a
# set of wlroots 0.20 headers and the host's libwlroots-0.20 are present,
# WAYLAND_NELUA holds the Nelua flags that compile the agent's Wayland
# compositor backend (agent/capture_wayland.nelua) in (for builds that pass no
# --cflags of their own; the others combine WAYLAND_DEFINE and WAYLAND_CFLAGS);
# otherwise all three are empty and the agent builds without it.
#
# The headers come from one of two places, in this order:
#   vendor/wayland-sdk   the pinned Fedora 44 -devel headers (tools/fetch-vendor.sh).
#                        Preferred, because the gaming PC's binary is built here
#                        and must match the ABI it will run against.
#   pkg-config           this system's own wlroots-0.20, wayland-server, xkbcommon
#                        and pixman-1. This is what makes an RPM build, or a
#                        player's `tools/build-agent.sh` on Fedora, work with
#                        nothing vendored.
#
# build/wayland-libs gets unversioned symlinks to the host libraries for the linker.
# shellcheck disable=SC2034 # used by the scripts that source this
WAYLAND_NELUA=()
WAYLAND_DEFINE=()
WAYLAND_CFLAGS=""
wayland_sdk="$ROOT/vendor/wayland-sdk/include"
if [[ "$(uname -s)" == Linux && "${SKIP_WAYLAND:-0}" != 1 ]]; then
  wayland_inc=""
  wayland_src=""
  if [[ -f "$ROOT/vendor/wayland-sdk/.pinned" ]]; then
    wayland_inc="-I$wayland_sdk -I$wayland_sdk/wlroots-0.20 -I$wayland_sdk/pixman-1"
    wayland_src="the pinned vendor/wayland-sdk headers"
  elif command -v pkg-config >/dev/null &&
       pkg-config --exists wlroots-0.20 wayland-server xkbcommon pixman-1; then
    wayland_inc="$(pkg-config --cflags wlroots-0.20 wayland-server xkbcommon pixman-1)"
    wayland_src="this system's wlroots-0.20 headers"
  fi
  wayland_libdir=""
  for d in /usr/lib64 /usr/lib/x86_64-linux-gnu /usr/lib; do
    if [[ -e "$d/libwlroots-0.20.so" ]]; then wayland_libdir="$d"; break; fi
  done
  if [[ -n "$wayland_inc" && -n "$wayland_libdir" ]]; then
    mkdir -p "$ROOT/build/wayland-libs"
    ln -sfn "$wayland_libdir/libwlroots-0.20.so" "$ROOT/build/wayland-libs/libwlroots-0.20.so"
    for l in wayland-server xkbcommon pixman-1; do
      ln -sfn "$wayland_libdir/lib$l.so.0" "$ROOT/build/wayland-libs/lib$l.so"
    done
    # shellcheck disable=SC2034
    WAYLAND_DEFINE=(-D WAYLAND)
    WAYLAND_CFLAGS="$wayland_inc -L$ROOT/build/wayland-libs"
    # shellcheck disable=SC2034
    WAYLAND_NELUA=(-D WAYLAND "--cflags=$WAYLAND_CFLAGS")
    echo "note: Wayland compositor from $wayland_src"
  elif [[ -z "$wayland_libdir" ]]; then
    echo "note: no libwlroots-0.20.so on this host; the agent builds without the Wayland compositor"
  else
    echo "note: no wlroots 0.20 headers (install wlroots-devel wayland-devel wayland-protocols-devel libxkbcommon-devel pixman-devel, or run tools/fetch-vendor.sh); the agent builds without remote windows"
  fi
fi
