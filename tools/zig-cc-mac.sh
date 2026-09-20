#!/bin/sh
# C compiler wrapper used by Nelua to cross-compile ghostty-agent for macOS
# (Apple silicon) with Zig. No SDK: libc headers and libSystem stubs only, so
# frameworks are dlopened (agent/capture_mac.nelua).
# GHOSTTY_SCCACHE=1: see tools/zig-cc.sh.
if [ "${GHOSTTY_SCCACHE:-0}" = 1 ] && [ -z "${GHOSTTY_SCCACHE_INNER:-}" ]; then
  GHOSTTY_SCCACHE_INNER=1 export GHOSTTY_SCCACHE_INNER
  exec sccache "$0" "$@"
fi
exec "${ZIG:-zig}" cc -target aarch64-macos "$@"
