#!/usr/bin/env bash
# A heap profile to look at, not a pass/fail check: tests/fuzz.nelua and the
# core's init/shutdown loop (tests/test_reinit.nelua) under valgrind massif.
# build/massif/*.txt is ms_print's picture of the heap over time. Needs the
# host parts of tools/build.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
OUT="$ROOT/build/massif"; mkdir -p "$OUT"
INC="-I$ROOT/vendor/ghostty/include -I$ROOT/vendor/gc-cimgui -I$ROOT/vendor/lua/src -I$ROOT/vendor/stb"
LIBS="-L$ROOT/build/ghostty-vt-linux/lib -L$ROOT/build/lua-linux -lm"
export LD_LIBRARY_PATH="$ROOT/build/ghostty-vt-linux/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export SAN_CC="${SAN_CC:-gcc}" SAN_CFLAGS="-g -O1 -fno-omit-frame-pointer"
profile() { # name args...
  local name="$1"; shift
  "$ROOT/vendor/nelua-lang/nelua" --cc "$ROOT/tools/san-cc.sh" -P nogc --cflags="$INC $LIBS" --cache-dir build/nelua-cache-vg -L . -b "tests/$name.nelua"
  valgrind --quiet --tool=massif "--massif-out-file=$OUT/$name.massif" "build/nelua-cache-vg/$name" "$@" >/dev/null
  ms_print "$OUT/$name.massif" >"$OUT/$name.txt"
  echo "massif $name: peak $(grep -oE 'mem_heap_B=[0-9]+' "$OUT/$name.massif" | cut -d= -f2 | sort -n | tail -1) bytes"
}
profile fuzz 20260919 "${FUZZ_ITERS:-100}"
GHOSTTY_HEAP_ITERS="${GHOSTTY_HEAP_ITERS:-30}" profile test_reinit "$ROOT"
