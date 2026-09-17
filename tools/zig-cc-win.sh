#!/bin/sh
# C compiler wrapper used by Nelua to target Windows x64 (MinGW ABI) with Zig.
exec "${ZIG:-zig}" cc -target x86_64-windows-gnu "$@"
