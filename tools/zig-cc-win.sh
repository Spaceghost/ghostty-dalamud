#!/bin/sh
# C compiler wrapper used by Nelua to target Windows x64 (MinGW ABI) with Zig.
# GHOSTTY_SCCACHE=1: see tools/zig-cc.sh.
if [ "${GHOSTTY_SCCACHE:-0}" = 1 ] && [ -z "${GHOSTTY_SCCACHE_INNER:-}" ]; then
  GHOSTTY_SCCACHE_INNER=1 export GHOSTTY_SCCACHE_INNER
  exec sccache "$0" "$@"
fi
exec "${ZIG:-zig}" cc -target x86_64-windows-gnu "$@"
