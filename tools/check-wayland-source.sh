#!/usr/bin/env bash
# Analyze the actual Wayland-enabled agent and generate C, without substituting
# the default build that omits the compositor when host libraries are absent.
# This does not compile/link C or verify wlroots ABI/runtime behavior.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
mkdir -p build
vendor/nelua-lang/nelua -D WAYLAND -P nogc --cache-dir build/nelua-cache -L . \
  --print-code agent/agent.nelua > build/wayland-votes-typecheck.c
test -s build/wayland-votes-typecheck.c
printf 'Wayland-enabled Nelua analysis and C generation passed; native compilation remains separate.\n'
