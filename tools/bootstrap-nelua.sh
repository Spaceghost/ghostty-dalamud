#!/usr/bin/env bash
# The checked-in `nelua` launcher is executable even on a fresh clone.
# Build its interpreter, not the launcher. An incremental make also rebuilds
# the interpreter after updating the pinned Nelua source revision.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -f "$ROOT/vendor/nelua-lang/Makefile" ]]; then
  echo 'Nelua sources missing; run tools/fetch-vendor.sh first.' >&2
  exit 1
fi
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')}"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo 'JOBS must be a positive integer.' >&2; exit 1; }
make -C "$ROOT/vendor/nelua-lang" -j"$JOBS" nelua-lua
"$ROOT/vendor/nelua-lang/nelua" --version
