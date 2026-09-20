#!/usr/bin/env bash
# Shared build helpers. Callers provide ROOT; this file does not change cwd.
# The C compiler is Zig through tools/zig-cc.sh: one pinned toolchain builds
# the Nelua compiler, the Lua objects and every Nelua target, host and
# Windows alike, and the build needs no system gcc. Set CC to override.
BUILD_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CC="${CC:-$BUILD_COMMON_DIR/zig-cc.sh}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 1)}"
case "$JOBS" in ''|*[!0-9]*|0) JOBS=1 ;; esac
require_linux_build_host() {
  [[ "$(uname -s)" == Linux ]] || {
    echo 'The full plugin build currently requires Linux. macOS agent support is experimental.' >&2
    return 2
  }
}
build_nelua() {
  # nelua is a tracked executable launcher, not evidence of a built compiler.
  command -v "$CC" >/dev/null || { echo "C compiler not found: $CC" >&2; return 127; }
  make -C "$ROOT/vendor/nelua-lang" -j"$JOBS" CC="$CC"
  [[ -x "$ROOT/vendor/nelua-lang/nelua-lua" ]] || {
    echo 'Nelua build did not produce nelua-lua.' >&2; return 1;
  }
}
