#!/bin/sh
# C compiler wrapper used by Nelua for host builds (the agent, tests) with Zig.
# GHOSTTY_SCCACHE=1 (the Incus build container sets it) compiles through
# sccache and the shared cache. sccache cannot drive `zig` itself -- it probes
# a compiler with `-E`, which zig only understands after `cc` -- but it can
# drive this script, so the script re-execs itself under sccache once.
if [ "${GHOSTTY_SCCACHE:-0}" = 1 ] && [ -z "${GHOSTTY_SCCACHE_INNER:-}" ]; then
  GHOSTTY_SCCACHE_INNER=1 export GHOSTTY_SCCACHE_INNER
  exec sccache "$0" "$@"
fi
# -mcpu=baseline: zig cc otherwise targets the CPU it runs on, and CI caches what
# this builds (vendor/nelua-lang/nelua-lua) across runners, so a compiler built
# on one runner died with "Illegal instruction" on the next. A caller's own
# -mcpu/-march comes later and wins.
exec "${ZIG:-zig}" cc -mcpu=baseline "$@"
