#!/bin/sh
# C compiler wrapper used by Nelua for host builds (the agent, tests) with Zig.
exec "${ZIG:-zig}" cc "$@"
