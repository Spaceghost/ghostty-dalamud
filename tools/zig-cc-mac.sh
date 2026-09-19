#!/bin/sh
# C compiler wrapper used by Nelua to cross-compile ghostty-agent for macOS
# (Apple silicon) with Zig. No SDK: libc headers and libSystem stubs only, so
# frameworks are dlopened (agent/capture_mac.nelua).
exec "${ZIG:-zig}" cc -target aarch64-macos "$@"
